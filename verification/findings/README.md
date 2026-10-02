# Bug-hunt findings

Defects found while modelling tpu-sync, with the evidence for each. Line
numbers are for tpu-sync `01ffa3d` (the commit this tree is based on) unless
a block of test output says otherwise; the tests were run on `b68161a` and
re-run on `d16701e`, and the cited code is unchanged at `01ffa3d` (checked by
reading; `raiden_controller.cc` is identical in the cited regions,
`kv_cache_store.cc` only moved).

Caller checked: `vllm-torchtpu` @ `6a9132a84`.

## Evidence levels

| Level | Meaning |
|---|---|
| **CONFIRMED (test)** | A real C++ test on unmodified production code fails and shows the wrong behaviour. |
| **CONFIRMED (read)** | The defect is unambiguous in the code, but no test has run. |
| **PLAUSIBLE** | Reachability depends on something not yet established. |
| **REFUTED** | Checked and not a bug. Kept so nobody re-investigates it. |

Nothing is promoted to CONFIRMED (test) without real, unedited output pasted
here.

## Method

1. **Extract.** Read the C++ and write down the state and transitions, each
   with a `file:line` citation.
2. **Hypothesise.** Use a Lean model or a bounded search to find a property
   violation (`TpuSyncVerify/Controller/ReadRemote.lean` for F2).
3. **Reachability.** Check the violating order against the real threading and
   lock structure and against real callers.
4. **Confirm.** Write a deterministic gtest that drives the real code into
   that order. The tests live here, not in the tree; `build_targets.patch`
   adds their targets.

## Files

| File | What |
|---|---|
| `raiden_controller_bughunt_test.cc` | F2 (shape A) and F4 (both halves) |
| `kv_cache_store_pin_race_test.cc` | F1 |
| `build_targets.patch` | `cc_test` targets for the two files above |
| `candidate_fixes.patch` | fixes for F1, F2 (naive, shape A only) and F4; see "Fix validation" |
| [`filed_bugs.md`](filed_bugs.md) | verbatim write-ups of bugs filed upstream |

To run: copy the two `.cc` files next to the code they test
(`tpu_sync/core/controller/`, `tpu_sync/kv_cache/`), `git apply
verification/findings/build_targets.patch`, then
`bazel test //tpu_sync/core/controller:raiden_controller_bughunt_test
//tpu_sync/kv_cache:kv_cache_store_pin_race_test`. Both patches apply
cleanly at `01ffa3d`.

## Summary

| # | Finding | Status | Reachable from production? |
|---|---|---|---|
| F1 | `ValidateAndPinHostBlocks` can return a host block id that no longer holds the hash | CONFIRMED (test) | only via the `ReadRemote` API (no in-tree caller) |
| F2 | Remote read keeps DMA-ing into destination blocks after it settled with a deadline error | CONFIRMED (test) for shape A; proved in Lean for shapes A and B | same |
| F3 | Data race on `RemoteReadState::lease_id` | CONFIRMED (read) | same |
| F4 | `TransferBuffers` leaks auto-allocated staging on every early error, and can return an error after some workers were dispatched ([filed](filed_bugs.md#1-raidencontrollertransferbuffers-error-path-defects-f4), fix: [PR #1105](https://github.com/google/tpu-sync/pull/1105)) | CONFIRMED (test), both halves | leak: no in-tree trigger; orphaned copies: yes, via Fetch / WriteRemote on a node_id mismatch |

---

## F1. `ValidateAndPinHostBlocks` can return a host block id that no longer holds the hash

- **Status:** **CONFIRMED (test)**, 2026-09-24, on unmodified `b68161a`;
  re-run on `d16701e` with the same result. Output, verbatim:
  ```
  [ RUN      ] KVCacheStorePinRaceTest.EvictAndReinsertBetweenLookupAndPinReturnsStaleHostBlockId
  tpu_sync/kv_cache/kv_cache_store_pin_race_test.cc:161: Failure
  Expected equality of these values:
    (*ids)[0]
      Which is: 5
    live_block
      Which is: 9
  ValidateAndPinHostBlocks returned host block 5 but h0 now lives at 9; the returned block holds hash 'other'. The pin protects block 9, not the block the reader will pull.
  [  FAILED  ] KVCacheStorePinRaceTest.EvictAndReinsertBetweenLookupAndPinReturnsStaleHostBlockId (10 ms)
  ```
- **Where:** `tpu_sync/kv_cache/kv_cache_store.cc:1655-1683`
  (`KVCacheStore::ValidateAndPinHostBlocks`).
- **Defect:** The function calls `backend()->Lookup(hashes)` with default
  options (`:1658`; `pin_found = false` by default,
  `kv_cache_store_backend.h:104`), copies `host_block_id`, and only then calls
  `backend()->Pin(hashes)` (`:1677`). The backend mutex is released between
  the two calls. The only lock held across them is `KVCacheStore::mutex_`,
  and neither of the following takes it:
  - `KVCacheStore::Evict` (`:1840`). The comment at `:1843-1845` says "We do
    not hold store mutex_". It is called from `SweepOnce` and
    `AllocateBlockIds`.
  - `KVCacheStore::Insert` (`:1053`).
- **Bad interleaving:**
  1. T1 runs `Lookup(h)` and gets host block 5.
  2. T2 evicts `h`; block 5 goes back to the pool.
  3. Block 5 is reused for another hash.
  4. T3 re-inserts `h` at block 9.
  5. T1's `Pin(h)` succeeds because pins are keyed by hash, and the function
     returns **5**.
  6. The reader pulls block 5, which holds another hash's bytes, while the pin
     protects block 9. The lease verdict is still `HELD`, so the wrong bytes
     are accepted silently.
- **Evidence that this is unintended:**
  - The Fetch path closes the same window with `pin_found = true` and a
    comment describing exactly this failure
    (`kv_cache_store_service.cc:446-458`).
  - The header promises "the authoritative source host_block_ids (re-derived
    from the LRU)" (`kv_cache_store.h:388-389`).
- **Reachability:**
  - The source side runs whenever a peer calls `AcquireReadLease` on this
    controller; the hook is registered at `kv_cache_store.cc:1642-1652`.
  - The only initiator of that RPC in this tree is
    `RaidenController::ReadRemote`, which has **no production C++ caller**.
    `KVCacheStore::Load`'s remote branch uses `backend()->Load`. So in this
    snapshot the path is reachable only through the API and tests.
  - The race needs an evict **and** a re-insert of the same hash between two
    adjacent statements. Narrow, but real.
- **Fix:** `LookupOptions{.enable_global = false, .pin_found = true}` and drop
  the separate `Pin`, mirroring the Fetch path. This also removes a blocking
  registry RPC made while `mutex_` is held. In `candidate_fixes.patch`.
- **Repro:** `kv_cache_store_pin_race_test.cc`. A delegating backend runs the
  other threads' exact backend calls inside the window.

## F2. Remote read keeps DMA-ing into destination blocks after it has already failed with a deadline error

- **Status:** **CONFIRMED (test)** for shape A, 2026-09-24. **Proved in
  Lean** for shapes A and B (`TpuSyncVerify/Controller/ReadRemote.lean`,
  exhaustive over the reachable state space).
- **C++ test output** (unmodified code, verbatim):
  ```
  [F2] settled after 1.002259414s with: ReadRemote exceeded the destination deadline (1s)
  [F2] pulls issued at settle: 0, pulls issued 4s later: 1
  raiden_controller_bughunt_test.cc:111: Failure
    pulls_after  Which is: 1
  A pull into dst host block 20 was issued AFTER ReadRemote settled with DeadlineExceeded.
  ```
  The test sets `RAIDEN_REMOTE_READ_DEADLINE_S=1` and delays the source's
  `AcquireReadLease` by 2.5 s with the existing `SetLeaseGrantedHookForTest`
  seam (`controller_service.h:106`). That configuration only makes the test
  fast. With defaults the deadline is the lease TTL plus 30 s
  (`raiden_controller.cc:107-130`), so shape A needs an acquire that takes
  longer than that (a hung source). Shape B needs a pull that outlives the
  deadline, which is the case the deadline exists for.
- **Where:** `tpu_sync/core/controller/raiden_controller.cc:1016-1104`
  (acquire callback and deadline thread), `:1109-1211` (`PullAndRelease`).
- **Defect:** A detached deadline thread calls `Settle(DeadlineExceeded)`
  (`:1084-1104`). Neither the acquire callback (`:1018-1077`) nor
  `PullAndRelease` (`:1161-1162`) checks `state->settled` before calling
  `TransferBuffers`, and an in-flight transfer is never cancelled.
  - If the acquire response arrives after the deadline, the pull **starts**
    after the caller has been told the read failed (shape A).
  - If the deadline fires during the pull, the caller is told the read
    failed while the DMA continues (shape B).
  - The header says the host staging blocks are returned to the pool "once
    the read settles, success or failure" (`:1134-1138`). A late pull
    therefore writes into staging blocks that were freed and reallocated,
    and into device blocks the caller may already be refilling.
- **Lean results:**
  - `shipping_counterexample`: shape A — `deadline, callerReuse,
    acquireReply true`.
  - The naive fix (check `settled` before the pull) closes A and not B
    (`naive_fix_counterexample`).
  - Deferring the deadline's settle while a pull is in flight has no
    violation anywhere in the state space (`deferred_settle_is_safe`). This
    is what the sibling `WriteRemote` path already does (R-D). Trade-off: a
    hung pull then holds the caller until it resolves. A complete fix needs
    cancellation, or settle-with-error while the blocks stay quarantined.
- **Reachability:** as F1: `ReadRemote` has no production caller in this
  tree.
- **Fix in `candidate_fixes.patch`:** the **naive** fix only (skip the pull if
  already settled; still release the lease). It closes shape A and is
  validated below; it does not close shape B.

## F3. Data race on `RemoteReadState::lease_id`

- **Status:** CONFIRMED (read). Undefined behaviour under the C++ memory
  model. Not tested; it needs a TSan build.
- **Where:** `raiden_controller.cc`
  - `uint64_t lease_id` is a plain field, not under `mu` (`:897`; `settled`
    at `:899` is guarded, `lease_id` is not).
  - Written on the gRPC callback thread at `:1034`.
  - Read on the detached deadline thread at `:1090`, `:1095`, `:1101` with no
    synchronisation.
- **Practical effect:** If the deadline thread reads 0, it skips the early
  release and the source keeps its pins for the full lease TTL.
- **Fix:** `std::atomic<uint64_t>`, or guard it with `mu`.

## F4. `TransferBuffers` leaks auto-allocated staging blocks on every early error

- **Status:** **CONFIRMED (test)**, both halves. Unmodified code, verbatim:
  ```
  [F4] locked host blocks before: 0, after 3 failed TransferBuffers: 3
  raiden_controller_bughunt_test.cc:143: Failure
    locked_after  Which is: 3
    locked_before Which is: 0
  Each failed TransferBuffers leaked its auto-allocated staging block.
  ```
  ```
  [F4-P2] copy jobs workers received for this failed transfer: worker_0=1 worker_1=0
  ```
  (the second after `TransferBuffers` returned `no destination worker group
  with node_id 1 ...`; `BugHuntTest.TransferBuffersDispatchesNoWorkerWhenAnyWorkerIsUnmatched`, on `d16701e`).
- **Where:** `RaidenController::TransferBuffers` (broadcast overload),
  `raiden_controller.cc:573-793`. When the transfer is cross-node and touches
  local HBM with no staging supplied, it allocates staging itself
  (`:639-656`).
  - Only the success path frees it (`:780-790`).
  - The error returns at `:673` (no workers), `:722` / `:737` (node_id
    mismatch), `:768` (request build) and `:776` (no client) never free it.
  - Worse, `:722` / `:737` / `:768` can return **after** earlier workers were
    already dispatched (`:771`). Those transfers keep running un-awaited
    against the staging blocks and, on the destination side, against its
    buffers, while the caller already sees the error.
- **Reachability:**
  - **Leak half: no in-tree production trigger.** Auto-allocation needs a
    cross-node transfer that touches *local HBM* with no staging supplied.
    The production callers of the broadcast overload never do that: Fetch
    (`kv_cache_store_service.cc:527`, DRAM → remote DRAM), WriteRemote
    (`:775`, remote DRAM → DRAM), `host_offload_backend.cc:1221`, `:1313`
    (local DRAM → HBM), `:1395` (local HBM → DRAM). No Python binding or
    vllm-torchtpu code calls `TransferBuffers` directly.
  - **Orphaned-copy half: reachable from production.** Fetch and WriteRemote
    pass remote worker endpoints, so they go through the node_id matching
    loop. If some workers match and a later one does not, `:722` / `:737`
    return after the earlier workers were dispatched. Fetch then awaits the
    error, unpins its source blocks (`unpin_cleanup`,
    `kv_cache_store_service.cc:475`) and fails the RPC; the client's
    `LoadRemoteBlocks` frees `dst_host_block_ids`
    (`host_offload_backend.cc:1184-1195`). Meanwhile the dispatched worker
    copy may still be reading the source and writing the destination.
  - **Trigger:** the two sides disagree about which node_ids exist
    (config/topology mismatch). How likely that is in real deployments is
    not established.
- **Fix in `candidate_fixes.patch`:** route every error return through a
  helper that frees the auto-allocated staging, and, if some workers were
  already dispatched, only after joining their futures. A cleaner fix
  resolves and matches every worker *before* allocating or dispatching
  anything ([google/tpu-sync#1105](https://github.com/google/tpu-sync/pull/1105)).

---

## Refuted or closed

### R-A. Premature completion in `TransferReceiveSession::IsReadyToComplete()`: REFUTED

The transport dispatches a layer before counting its blocks
(`block_transport.cc:576` then `:584`); `total_blocks_` is summed across
senders; the `network_completed_` disjunct is an intentional fast path. The
stage-2 model proves readiness sound under this ordering
(`Transfer/PrefillDecode/Receive.lean`, assumption A4, `ReadinessSound`).

### R-B. Stale push after a same-uuid retry: not reachable from vLLM

The receive session counts blocks without de-duplication and the chunk header
has no generation, so a push from an old attempt could count toward a new
attempt's session. vLLM never re-arms a uuid: the uuid is fresh per send
(`tpu_connector.py:5607`); a request is loaded once (`_remote_kv_processed`);
a failed load is recomputed, not pulled again; the only same-uuid retry is on
`"Missing producer block registration"`, which comes from `LookupAndClaim`
(`request_block_registry.cc:440-466`) and runs before any receiver is armed.
This remains an **API hazard** for other callers, since the headers allow
same-uuid re-registration.

### R-C. `RequestBlockRegistry` lifecycle: no defect found (read)

Claims are owner-scoped; a cancel tombstone blocks later registration and
claims; an early completion vote is allowed only for an empty `block_ids`
registration. TTL-based edge cases (claim or tombstone expiring after 600 s by
default) need a transfer or rank to be more than 600 s late. Design limits,
not bugs.

### R-D. `WriteRemote` landing blocks freed at the deadline while the DMA is still writing: REFUTED (read)

`DeadlineLoop` (`kv_cache_store_service.cc:1042`) marks the op failed but
does **not** free the landing blocks. They are freed only when the transfer
future resolves (`CompleteWriteRemote`, `:834-874`, → `ReleaseLandingBlocks`
`:574`); a leak warning is logged if the transfer never resolves
(`:1070-1081`). This is the `deferSettleWhilePullInFlight` design from the
Lean model. `ReadRemote` (F2) lacks it, which suggests F2 is an oversight
rather than a design choice.

### R-E. Local `KVCacheStore::Load` reads host blocks that could be evicted mid-copy: REFUTED (read)

Both `Load` overloads require that the caller already holds a pin on every
hash; eviction skips pinned entries (`host_offload_backend.cc:815`).

### R-F. Fetch-source (production remote load) unpins before the pull finishes: REFUTED (read)

It matches and pins atomically (`pin_found = true`,
`kv_cache_store_service.cc:446-458`); the pins are released by a scope cleanup
after `transfer_future.Await()` returns (`:475`, `:527`).

### Open / not yet checked

- `KVCacheStoreClient::Fetch` sets no RPC deadline
  (`kv_cache_store_client.cc:61-125`). If the RPC fails with a transport error
  while the source's workers are still writing, `LoadRemoteBlocks` frees
  `dst_host_block_ids` immediately (`host_offload_backend.cc:1184-1195`). Same
  shape as F2 but in the production path. Whether in-flight source DMA can
  outlive a failed Fetch RPC depends on worker and transport teardown, not
  established. **PLAUSIBLE.**
- ReadRemote hooks capture a raw `this`, and `ClearReadRemoteHooks` is not
  called in `~KVCacheStore`. The controller is owned by the store and is
  destroyed first among the members that matter, so this is probably safe.
  Not verified.

## Fix validation (2026-09-24, on `b68161a`)

`candidate_fixes.patch` was applied to a scratch clone, the tests run, and the
clone reset. Results, verbatim:

```
[F2] pulls issued at settle: 0, pulls issued 4s later: 0
[F4] locked host blocks before: 0, after 3 failed TransferBuffers: 0
//tpu_sync/core/controller:raiden_controller_bughunt_test   PASSED
//tpu_sync/core/controller:raiden_controller_test           PASSED   (59 existing tests, no regressions)
//tpu_sync/kv_cache:kv_cache_store_pin_race_test            PASSED
```

- **F1 fix:** with it, the eviction inside the window is refused because
  `h0` is pinned. For this run the test hook was changed to "skip the
  reinsert if the eviction is refused"; it still fails on the unfixed code,
  where the eviction succeeds.
- **F2 fix:** the naive fix only; closes shape A, not shape B.
- **F4 fix:** every error return frees the auto-allocated staging, after
  joining any already-dispatched worker futures.
- `kv_cache_store_test` was not run (`no_oss`, needs a gRPC registry
  environment).

## History

- 2026-09-24: found and confirmed on `b68161a`; re-run on `d16701e` (F1, F2,
  F4 still fail; `raiden_controller.cc` unchanged; F1 test adapted to the
  `Evict(hashes, evicted_hashes*)` signature from `e767161`).
- 2026-10-01: ported into `verification/`; citations re-checked against
  `01ffa3d` by reading (cited `raiden_controller.cc` regions identical;
  `kv_cache_store.cc` lines moved by −15); both patches re-based and apply
  cleanly. Tests not re-run.
