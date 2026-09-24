# Code correspondence: TPU Sync remote-read path

Pinned revision: **`b68161a16beb9e5244b7d606fa14c4676744d246`** (`github.com/google/tpu-sync`, 2026-09-22).
All paths below are relative to that tree; permalinks:
`https://github.com/google/tpu-sync/blob/b68161a16beb9e5244b7d606fa14c4676744d246/<path>#L<line>`.

This document records what the implementation actually does, so the Lean model in
`TpuSyncFormal/` can be checked against it rather than against the prose in
`proposal.md`. Every claim cites a file and line. Statements marked **hypothesis**
are readings of the code, not reproduced failures.

## 0. Scope: there are two remote-read paths

Only one of them has leases. The model covers path A.

| | A. Lease path | B. Fetch path |
| --- | --- | --- |
| Entry | `RaidenController::ReadRemote`, `core/controller/raiden_controller.cc:912` | `KVCacheStoreClient::Fetch`, `kv_cache/host_offload_backend.cc:1124` |
| Direction | receiver-initiated pull | receiver asks source to push |
| Safety mechanism | lease + pin + verdict | pin held for the duration of the RPC |
| Source handler | `core/controller/controller_service.cc:149/264/296` | `kv_cache/kv_cache_store_service.cc:393` |

> [!IMPORTANT]
> Path A has **no non-test production caller** in the open-source tree.
> `KVCacheStore::ReadRemote` (`kv_cache/kv_cache_store.cc:1703`) forwards to `Load`,
> which takes path B. `KVCacheStore` participates in the lease protocol only as the
> **source**, by registering pin/unpin hooks (`kv_cache/kv_cache_store.cc:1657-1668`).
> The machinery is fully implemented, not stubbed; its destination-side callers are
> `core/controller/raiden_controller_test.cc` and `store_node/kv_cache_evict_e2e_test.cc:260`.

## 1. The protocol in three phases

Wire contract: `proto/controller_service.proto:27-46` — `AcquireReadLease`,
`RenewReadLease`, `ReleaseReadLease`, with
`enum LeaseVerdict { UNSPECIFIED=0, LEASE_HELD=1, LEASE_REVOKED=2, LEASE_UNKNOWN=3 }`
(`:51-61`). The proto comment states the design intent directly: *"The TTL is garbage
collection, not safety."*

```mermaid
sequenceDiagram
    participant D as Destination (RaidenController)
    participant S as Source service
    participant St as Source store (pins)
    participant W as Worker (data plane)
    D->>S: AcquireReadLease(hashes, ttl_ms)
    S->>St: ValidateAndPinHostBlocks
    St-->>S: src_host_block_ids (pinned)
    S-->>D: lease_id, block ids, granted_ttl_ms
    D->>W: TransferBuffers (per worker, blocking)
    Note over S: sweeper may expire the lease here
    W-->>D: transfer future resolves
    D->>S: ReleaseReadLease(lease_id)
    S-->>D: verdict
    Note over D: HELD -> accept; REVOKED/UNKNOWN -> reject
```

## 2. Lease lifecycle (source side)

`struct ReadLease`, `core/controller/controller_service.h:169-179`:
`block_hashes`, `requester_key`, `expiration`, `live`, `revoked`, `retire_at`;
held in `read_leases_` (`:201`) under `mutex_`.

- **Identity**: fresh random `uint64_t` per grant, `0` reserved, redrawn on collision
  (`controller_service.cc:210-212`).
- **Grant** (`controller_service.cc:149-262`): empty hash list rejected (`:153`);
  pins taken via the validate hook (`:178`); a `pin_guard` unpins if the record is
  never inserted (`:190-195`); TTL clamped to `[MinLeaseTtl, MaxLeaseTtl]` (`:197-200`);
  record inserted with `expiration = now + ttl`, `retire_at = InfiniteFuture` (`:214-225`).
- **Expiry is a reaper, not a predicate.** `SweeperLoop` (`:371-388`) waits on
  `sweeper_cv_` until `min(expiration | live, retire_at | !live)`; `RunSweepOnce`
  (`:390-424`) moves expired leases out of `live` with `revoked=true` and unpins
  **after dropping the lock** (`:421-423`).
- **Release** (`:296-324`): no record → `UNKNOWN`; `revoked` → `REVOKED`; else `HELD`
  plus `TransitionOutOfLive(revoked=false)`. Idempotent — a second release still
  answers `HELD` and unpins nothing.
- **Retention**: `TransitionOutOfLive` (`:326-334`) sets
  `retire_at = now + RevokedLeaseRetention()` so a late release sees `REVOKED`
  rather than `UNKNOWN` (rationale at `controller_service.h:72-76`).

> [!WARNING]
> Neither `RenewReadLease` (`:279-285`) nor `ReleaseReadLease` (`:309-316`) compares
> `expiration` against `now`; they read the `live`/`revoked` flags only. The model must
> therefore **not** encode "expired ⇒ REVOKED" — expiry is an asynchronous step that
> may lag arbitrarily behind the deadline.

`RenewReadLease` is implemented but called only from tests.

## 3. Pins

A pin protects an LRU entry keyed by **block hash**, and transitively the host DRAM
slot (`host_block_id`) that entry names.

- Acquire: `KVCacheStore::ValidateAndPinHostBlocks`, `kv_cache/kv_cache_store.cc:1670-1697`
  — `Lookup` (`:1673`), status must be `HOST`/`HOST_AND_HBM` (`:1683-1688`),
  `backend()->Pin(...)` (`:1692`), returns authoritative ids (`:1689`).
- Release: `UnpinHostBlocks` (`:1699-1701`) → `backend()->Release(...)`.
- Backend: `HostOffloadBackend::Pin` is all-or-nothing with rollback
  (`kv_cache/host_offload_backend.cc:519-530`); `Release` (`:532-540`).
- Refcounts, not booleans: `kv_cache/lru_cache.h:197-241`. Two readers of the same
  hashes hold independent leases over independent counts — leases must not be deduped
  by hash set (`controller_service.h:77-80`).

While pinned: eviction skips `pinned_list_` (`lru_cache.h:260-277`), `Erase` refuses
(`:282-286`), and `HostOffloadBackend::Evict` will not reclaim the block id
(`host_offload_backend.cc:655-692`, gate at `:666`).
**Not** prevented: replacing the value for an existing hash (`lru_cache.h:100-106`),
or a writer that already holds the slot DMA-ing over the bytes.

A lease-authorised pull carries `kLeaseAuthorizedPullUuid`
(`kv_cache/kv_cache_manager_base.h:81`), which makes the source **skip its D2H
readiness gate** — `core/kv_cache_manager_with_transfer.cc:1238-1248` says the pin is
what replaces the gate. The pin is therefore load-bearing for data validity, not just
for liveness.

## 4. Copy lifecycle and the verdict

1. Acquire callback → `PullAndRelease` (`raiden_controller.cc:1076`, called under
   `lifetime->mu` at `:1059`).
2. `TransferBuffers` (`:1161-1162`) fans out one request per registered worker, pairing
   by `node_id`, never broadcasting (`:714-773`), joined with `tsl::JoinFutures` (`:780`).
3. The worker handler is **synchronous and serialised**: `absl::MutexLock` at
   `core/controller/worker_service_impl.cc:141`, then `future_or->Await()` at `:340`.
   The copy is not cancellable through this interface.
4. Completion: `transfer.OnReady(...)` (`raiden_controller.cc:1169`) on a gRPC callback
   thread; it issues `ReleaseReadLease` and the verdict is consumed in *that* callback.

Decision branch, `raiden_controller.cc:1179-1208`: accept requires
**transfer OK ∧ `LEASE_HELD`** (`:1195-1197`); `LEASE_REVOKED` (`:1198-1202`) and
anything else (`:1203-1207`) reject; an RPC failure yields "verdict unknown" (`:1184`).

## 5. Publication point

Promise fulfilment, not a map insert — `RemoteReadState::Settle`
(`raiden_controller.cc:902-909`), reached at `:1196`:

```cpp
void Settle(absl::Status status) {
  { absl::MutexLock lock(&mu); if (settled) return; settled = true; }
  promise->Set(std::move(status));
}
```

The bytes were already DMA'd into the caller's blocks *before* the verdict was known.
`raiden_controller.h:193-198` makes this explicit: *"the caller's device blocks are
written before the verdict is known, so a discarded read leaves them holding undefined
bytes... Treat supplied device blocks as scratch until the read reports success."*

> [!IMPORTANT]
> Consequence for the model: **reject does not roll back the write.** Publication
> correctness is a statement about what the *caller is told*, plus the caller's
> obligation to treat its blocks as scratch until told success. The nothing-points-at-them
> argument is the real safety property, and it depends on destination block ownership
> (§7 R1), not on the verdict alone.

## 6. Deadlines

- `RemoteReadDeadline()` — `raiden_controller.cc:111-130`, env
  `RAIDEN_REMOTE_READ_DEADLINE_S`, default `DefaultLeaseTtl() + 30s`, read once into a
  function-local `static`.
- Enforcement is a **detached `std::thread` per read** that sleeps the full duration
  (`:1084-1104`), then, if unsettled, fires a best-effort `ReleaseReadLease` (`:1098`)
  and settles `DeadlineExceeded` (`:1102`). **It cancels nothing** — no
  `ClientContext::TryCancel`, no token to the workers; in-flight copies keep writing.
- Source knobs (`controller_service.cc:121-147`): `DefaultLeaseTtl` 120 s (env
  `RAIDEN_REMOTE_LOCK_TTL_S`), `MinLeaseTtl` 30 s, `MaxLeaseTtl` 600 s,
  `RevokedLeaseRetention` TTL + 3 min.
- Intended invariant `retention > deadline > ttl` is only **logged**, not enforced, by
  `CheckTimingTripleOnce()` (`raiden_controller.cc:155-172`, called at `:924`). It spans
  two clocks and assumes bounded rate skew — an explicit modelling assumption.
- The four lease-path `grpc::ClientContext`s (`:1003, 1063, 1093, 1172`) set no deadline.

## 7. Races to model (hypotheses from reading)

| # | Race | Evidence |
| --- | --- | --- |
| R1 | Deadline settles the read; the caller frees its landing blocks; the uncancelled copy is still writing into them. Nothing refcounts a destination block against an in-flight pull. | `raiden_controller.cc:1084-1104`; caller pattern `store_node/kv_cache_evict_e2e_test.cc:266-268`; `raiden_controller.h:179-183` |
| R2 | Expired-but-unswept lease answers `HELD`. Conservative (pins not yet dropped) but forbids "expired ⇒ REVOKED" in the model. | `controller_service.cc:309-316` vs `:401-402`, lazy sweeper start `:366-369` |
| R3 | `state->lease_id` written on the acquire-callback thread (`:1034`), read by the deadline thread (`:1090, 1095`) with no lock and no atomic. Deadline may read `0`, skip the release, and leave pins held for the full TTL. | `raiden_controller.cc:1034, 1090, 1095` |
| R4 | Deadline-triggered release unpins the **source** while the pull is still reading it; source blocks become evictable and reusable mid-read. Harmless only because the read was already failed and `Settle` is idempotent. | `:1098` + `controller_service.cc:317-322` |
| R5 | Rejected read leaves undefined bytes in caller buffers; nothing scrubs them. Documented as by design. | `:1198-1207`, `raiden_controller.h:193-198` |
| R6 | `ValidateAndPinHostBlocks` does `Lookup` then `Pin` as two backend critical sections while eviction does **not** take the store mutex. An evict + re-insert in the window pins the *new* entry while the returned ids name the *old* slot — wrong bytes, verdict `HELD`. Path B closes exactly this window with `pin_found = true`, which makes the asymmetry look unintentional. | `kv_cache_store.cc:1673, 1689, 1692` vs `:1748-1752`; contrast `kv_cache/kv_cache_store_service.cc:451-458` |
| R7 | 64-bit lease-id collision after a source restart returns `HELD` for unpinned bytes. Acknowledged in-code. | `controller_service.cc:206-209` |
| R8 | Pin/unpin hooks capture raw `this`; `ClearReadRemoteHooks` has no caller in `KVCacheStore` teardown, while the sweeper and the service destructor can invoke them later. | `kv_cache_store.cc:1661-1667`; `controller_service.cc:426-430, 445-455` |

R6 and R1 are the two most interesting for publication safety: R6 can publish **wrong
bytes with a `HELD` verdict** (a genuine violation of §2 of the proposal, if real), and
R1 corrupts buffers after a *rejected* read.

## 8. Locks

| Lock | Guards | Where |
| --- | --- | --- |
| `RaidenControllerServiceImpl::mutex_` | `read_leases_`, hooks, worker registry, id generator | `controller_service.h:195-208` |
| `KVCacheStore::mutex_` | Lookup/pin sequencing | `kv_cache_store.cc:1672` |
| `HostOffloadBackend::mutex_` | `lru_cache_`, registry client | `host_offload_backend.cc:519, 533, 663` |
| `RemoteReadState::mu` | `settled` only (**not** `lease_id`) | `raiden_controller.cc:898-899` |
| `Lifetime::mu` | `ctrl` pointer, teardown fence | `raiden_controller.h:213-216` |
| `WorkerServiceImpl::mutex_` | held across the whole blocking transfer | `worker_service_impl.cc:141, 340` |

Deliberate lock drops: the unpin hook is always invoked outside `mutex_`
(`controller_service.cc:320-322, 421-423, 453-455`; rationale `controller_service.h:181-189`)
to avoid a store↔service lock cycle. "Mark first, unpin later" is what makes a renew
landing in the gap answer `REVOKED` rather than `HELD`.

## 9. Testability (input to §3.3 of the proposal)

Existing seams, all in-tree:

- `ForceExpireForTest(lease_id)` — `controller_service.h:96-100`, impl `.cc:336-347`.
  Drives the exact sweeper transition. The header states the reason it exists: the 30 s
  TTL floor is longer than any unit test and **there is no injectable clock**.
- `SetLeaseGrantedHookForTest` — `controller_service.h:106-110`, fired outside the mutex
  at `.cc:227-232`: a synchronous interleaving point between grant and pull.
- `SetReadRemoteHooks(validate_and_pin, unpin)` — `controller_service.h:132-145`: full
  injection of source pin/unpin behaviour, so buffer reuse can be scripted.
- `MockTransferManager` / `ShardAwareMockTransferManager` —
  `core/controller/test_util.h:50-329`; injected via `SetTransferManager`
  (`raiden_controller_test.cc:634`). Its bodies run synchronously on the worker RPC
  thread, so blocking inside one is a precise "copy in progress" barrier.
- In-process real gRPC servers — `test_util.h:349-411`.
- Precedent test: `RevokedVerdictFailsTheRead`, `raiden_controller_test.cc:833-853`.

What is **not** injectable: the lease sweeper thread, the deadline thread
(`absl::SleepFor`, `raiden_controller.cc:1084`), gRPC callback threads, and the
process-wide 4-thread `CompletionExecutor` singleton
(`kv_cache/completion_executor.h:34-50`). The only injectable clock in the repo is
unrelated — `RequestBlockRegistry::Clock`, `kv_cache/reshard/request_block_registry.h:47`
— but it is the right precedent for a lease clock seam.

Build/CI facts that matter: bazel 8.6.0 + bzlmod, XLA/JAX pinned by `git_override`
(`MODULE.bazel:25-52`); the lease suite runs on CPU (no tags,
`core/controller/BUILD:244-300`) but is **outside** the default CI scope, since
`ci/run_unit_tests.sh:62` queries `//tpu_sync/core:all //tpu_sync/kv_cache:all ...`
and `:all` is not recursive.

### Consequence for repository layout

- A deterministic **lease-expiry-during-copy** test and a **source buffer-reuse** test
  can be written today with zero production changes — but only as a new `cc_test`
  *inside* the tree.
- A **deadline-race** test or any virtual-time test requires new seams: an injectable
  clock on the service, and an injectable timer/executor replacing the detached
  `SleepFor` thread.
- Nothing on this path is reachable from the Python surface: `read_remote` /
  `poll_remote_read_status` (`frameworks/jax/kv_cache_store.pyi:172-182`) expose no lease
  ids, verdicts, or hooks. An external test repo is therefore **not** viable.

So §3.3's implementation tests imply a fork of TPU Sync (added here as a submodule, or
tracked as patches), not a pinned dependency. See `README.md`.
