# Bug-hunt findings

Defects found while modelling tpu-sync, with the evidence for each. Line
numbers are for tpu-sync `1fa06d1` unless a block of test output says
otherwise; the F1–F4 tests were run on `b68161a` and re-run on `d16701e`, the
F5 tests on `50b0774`.

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
| `candidate_fixes.patch` | fixes for F1 and F2 (naive, shape A only); the F4 hunk was dropped when upstream fixed F4 (`72255dd`); see "Fix validation" |
| `per_peer_staging_admission.patch` | fix for F5 (per-peer staging admission at `StartRead`), the owners' parked acceptance test re-enabled, two allocator unit tests; see "F5" |
| [`filed_bugs.md`](filed_bugs.md) | verbatim write-ups of bugs filed upstream |

To run F1–F4: copy the two `.cc` files next to the code they test
(`tpu_sync/core/controller/`, `tpu_sync/kv_cache/`), `git apply
verification/findings/build_targets.patch`, then
`bazel test //tpu_sync/core/controller:raiden_controller_bughunt_test
//tpu_sync/kv_cache:kv_cache_store_pin_race_test`. F5 needs no repro file:
its test is already in the tree as `DISABLED_`; `git apply
verification/findings/per_peer_staging_admission.patch` re-enables it, then
`bazel test --config=oss //tpu_sync/kv_cache:kv_cache_manager_with_transfer_control_test
//tpu_sync/kv_cache:transfer_send_session_test`. All three patches apply cleanly
at `1fa06d1` (the F5 patch and its tests moved with the sources to
`tpu_sync/kv_cache/`).

## Summary

| # | Finding | Status | Reachable from production? |
|---|---|---|---|
| F1 | `ValidateAndPinHostBlocks` can return a host block id that no longer holds the hash | CONFIRMED (test) | only via the `ReadRemote` API (no in-tree caller) |
| F2 | Remote read keeps DMA-ing into destination blocks after it settled with a deadline error | CONFIRMED (test) for shape A; proved in Lean for shapes A and B | same |
| F3 | Data race on `RemoteReadState::lease_id` | CONFIRMED (read) | same |
| F4 | `TransferBuffers` leaks auto-allocated staging on every early error, and can return an error after some workers were dispatched ([filed](filed_bugs.md#1-raidencontrollertransferbuffers-error-path-defects-f4), fix: [PR #1105](https://github.com/google/tpu-sync/pull/1105)) | CONFIRMED (test) at `50b0774`; **FIXED upstream** in `72255dd` | leak: no in-tree trigger; orphaned copies: yes, via Fetch / WriteRemote on a node_id mismatch |
| F5 | One unresponsive producer pins every host staging slot; `StartRead` then rejects reads from every other producer (no per-peer admission; owner-acknowledged, fix: `per_peer_staging_admission.patch`) | CONFIRMED (test), with the owners' own parked test | yes: every consumer `StartRead`, given one producer that accepts and never answers |

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
- **Where:** `tpu_sync/kv_cache/kv_cache_store.cc:1672-1700`
  (`KVCacheStore::ValidateAndPinHostBlocks`).
- **Defect:** The function calls `backend()->Lookup(hashes)` with default
  options (`:1675`; `pin_found = false` by default,
  `kv_cache_store_backend.h:104`), copies `host_block_id`, and only then calls
  `backend()->Pin(hashes)` (`kv_cache_store.cc:1694`). The backend mutex is
  released between the two calls. The only lock held across them is
  `KVCacheStore::mutex_`, and neither of the following takes it:
  - `KVCacheStore::Evict` (`:1857`). The comment at `:1861-1863` says "We do
    not hold store mutex_". It is called from `SweepOnce` and
    `AllocateBlockIds`.
  - `KVCacheStore::Insert` (`:1065`).
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
    (`kv_cache_store_service.cc:444-456`).
  - The header promises "the authoritative source host_block_ids (re-derived
    from the LRU)" (`kv_cache_store.h:388-389`).
- **Reachability:**
  - The source side runs whenever a peer calls `AcquireReadLease` on this
    controller; the hook is registered at `kv_cache_store.cc:1659-1669`.
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
- **Where:** `tpu_sync/core/controller/raiden_controller.cc:1051-1139`
  (acquire callback and deadline thread), `:1144-1246` (`PullAndRelease`).
- **Defect:** A detached deadline thread calls `Settle(DeadlineExceeded)`
  (`:1119-1139`). Neither the acquire callback (`:1053-1112`) nor
  `PullAndRelease` (`:1196-1197`) checks `state->settled` before calling
  `TransferBuffers`, and an in-flight transfer is never cancelled.
  - If the acquire response arrives after the deadline, the pull **starts**
    after the caller has been told the read failed (shape A).
  - If the deadline fires during the pull, the caller is told the read
    failed while the DMA continues (shape B).
  - The comment in `PullAndRelease` says the host staging blocks are returned
    to the pool "once the read settles, success or failure" (`:1169-1173`; see
    also `raiden_controller.h:180-182`). A late pull
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
  - `uint64_t lease_id` is a plain field, not under `mu` (`:932`; `settled`
    at `:934` is guarded, `lease_id` is not).
  - Written on the gRPC callback thread at `:1069`.
  - Read on the detached deadline thread at `:1125`, `:1130`, `:1136` with no
    synchronisation.
- **Practical effect:** If the deadline thread reads 0, it skips the early
  release and the source keeps its pins for the full lease TTL.
- **Fix:** `std::atomic<uint64_t>`, or guard it with `mu`.

## F4. `TransferBuffers` leaks auto-allocated staging blocks on every early error

- **Status:** **CONFIRMED (test)** at `50b0774`, both halves; **FIXED upstream
  in `72255dd`** (2026-10-07, "Validate all workers before dispatching in
  `RaidenController::TransferBuffers` and release auto-allocated staging on
  error", the shape proposed in PR #1105). At `1fa06d1` every worker is matched
  (`raiden_controller.cc:702-740`) before staging is auto-allocated
  (`:772-784`) and before any request is built (`:787-803`; a build failure
  frees the staging at `:798`); dispatch starts at `:805` and has no early
  return after it. Three upstream tests cover it
  (`TransferBuffersUnmatchedNodeIdDispatchesNoWorker`,
  `TransferBuffersUnmatchedNodeIdDoesNotLeakAutoStaging`,
  `TransferBuffersRequestBuildFailureReleasesAutoStaging` in
  `raiden_controller_test.cc`). The F4 hunk of `candidate_fixes.patch` is
  therefore obsolete. Evidence below is from the unfixed code, verbatim:
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
- **Where (at `50b0774`, before the fix):** `RaidenController::TransferBuffers`
  (broadcast overload), `raiden_controller.cc:573-793`. When the transfer is
  cross-node and touches local HBM with no staging supplied, it allocates
  staging itself (`:639-656`).
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
    (`kv_cache_store_service.cc:525`, DRAM → remote DRAM), WriteRemote
    (`:773`, remote DRAM → DRAM), `host_offload_backend.cc:1219`, `:1311`
    (local DRAM → HBM), `:1393` (local HBM → DRAM). No Python binding or
    vllm-torchtpu code calls `TransferBuffers` directly.
  - **Orphaned-copy half: reachable from production.** Fetch and WriteRemote
    pass remote worker endpoints, so they go through the node_id matching
    loop. If some workers match and a later one does not,
    `raiden_controller.cc:722` / `:737` (at `50b0774`)
    return after the earlier workers were dispatched. Fetch then awaits the
    error, unpins its source blocks (`unpin_cleanup`,
    `kv_cache_store_service.cc:473`) and fails the RPC; the client's
    `LoadRemoteBlocks` frees `dst_host_block_ids`
    (`host_offload_backend.cc:1182-1193`). Meanwhile the dispatched worker
    copy may still be reading the source and writing the destination.
  - **Trigger:** the two sides disagree about which node_ids exist
    (config/topology mismatch). How likely that is in real deployments is
    not established.
- **Fix:** the cleaner shape — resolve and match every worker *before*
  allocating or dispatching anything
  ([google/tpu-sync#1105](https://github.com/google/tpu-sync/pull/1105)) — is
  what landed upstream as `72255dd`. The earlier `candidate_fixes.patch` hunk
  (route every error return through a helper that frees the staging after
  joining already-dispatched futures) was dropped from the patch on 2026-10-10.

---

## F5. One unresponsive producer pins every host staging slot; `StartRead` then rejects reads from every other producer

- **Status:** **CONFIRMED (test)**, owner-acknowledged. The test is the
  owners' own, parked as `DISABLED_` in `63da027` ("the written-down
  acceptance criteria for the per-peer admission work"). Run on unmodified
  `50b0774` with `--gtest_also_run_disabled_tests`, verbatim:
  ```
  [ RUN      ] ControlHandshakeTest.DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer
  E0000 00:00:1791391218.831497      12 transfer_receive_session.cc:233] StartRead: cannot stage 1 blocks for req_id=healthy0 (dynamic=false, free_host_blocks=0, free_slots=0, max_blocks=8)
  tpu_sync/kv_cache/kv_cache_manager_with_transfer_control_test.cc:1065: Failure
  Value of: consumer.has_recv(900)
    Actual: false
  Expected: true
  the read to the healthy peer was rejected outright because an unresponsive peer holds all 8 staging slots; no request to a healthy producer can even be attempted while another producer is wedged
  tpu_sync/kv_cache/kv_cache_manager_with_transfer_control_test.cc:1076: Failure
  Value of: failed_recving
  Expected: doesn't contain any element that is equal to "healthy0"
    Actual: { "healthy0" }, whose element #0 matches
  the healthy read failed immediately rather than being served
  [  FAILED  ] ControlHandshakeTest.DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer (48 ms)
  ```
- **Where:** `KVCacheManagerWithTransfer::StartRead` →
  `TransferReceiveSession::Create` → `AllocateStagingForLoad` →
  `StagingBlockAllocator::Acquire`, non-blocking and first-come-first-served
  (`kv_cache_manager_with_transfer.cc:865-873`,
  `transfer_receive_session.cc:215-242`,
  `kv_cache_manager_with_transfer.cc:1202-1203`).
  - The slot is taken *before* the handshake because the pull request
    carries the allocated host block ids (`transfer_receive_session.cc:504`);
    lazy allocation after the peer answers is not an option.
  - It is released only in `FinishLocked()` / `EndRecvOpLocked()` via
    `ReleaseStagingLocked()` once no copy or push is in flight
    (`Lifecycle.settleLocked` / the `inFlight = 0` rule of the Lean model), so
    cancelling a read to a dead peer does not return its slot before the
    deadline.
  - On `ResourceExhausted`, `StartRead` puts the request in `failed_recving_`
    and returns (`kv_cache_manager_with_transfer.cc:870-872`). No queueing: the
    read is rejected, not delayed.
  - Nothing bounds how many slots one peer may hold. The September changes
    bound how *long*: control-plane deadline (`430089c`, PR #1010, the
    thread-pool half of issue #888), per-read socket timeouts (`e7c933f`,
    `61b6c76`), release on a broken push stream (`4efb0dd`).
- **Reachability:** production path, every consumer `StartRead`. Trigger:
  one producer that accepts connections and never answers (crash without
  RST, partition, hung device) while the scheduler keeps routing reads to
  it; its reads then hold every slot for a deadline at a time and the decode
  host refuses KV transfers from the whole prefill fleet. Availability only,
  no memory-safety component.
- **Lean:** `PeerIsolation.trace_sick_peer_starves_staging_slots` is this
  test as a `decide` trace under `unboundedPerPeer` (`freeSlots = 0` even
  after `.cancel`, next healthy `StartRead` refused).
  `PeerIsolation.reachable_sick_staging_le_quota` and
  `PeerIsolation.reachable_quota_admits_healthy` state what the fix below
  guarantees over all reachable states: under `perPeerQuota c` the sick peer
  holds at most `c` slots, and a healthy peer holding fewer than `c` is
  admitted whenever `c + (slots healthy peers hold) < numSlots`. In words,
  cap `c` reserves `numSlots − c` slots for everyone else. It does not share
  fairly among many peers, it does not queue, and `c = numSlots` guarantees
  nothing (which is why the default is a no-op).
- **Fix in `per_peer_staging_admission.patch`:** `StagingBlockAllocator`
  keeps a count of live allocations per peer key.
  `Acquire(num_blocks, peer_key)` refuses with `kResourceExhausted` once the
  peer already holds `max_staged_reads_per_peer` allocations, even while
  slots are free; the charge is taken only on a successful allocation and
  dropped in `Allocation`'s RAII release under the same lock acquisition that
  returns the slot or the dynamic blocks, so count and pool cannot disagree.
  Keyless acquisitions (send side, incoming-push leases) are never capped.
  `StartRead` passes `remote_endpoint` as the key through
  `TransferReceiveSession::Create` / `AllocateStagingForLoad`; its failure
  path is unchanged and the log now names the peer and the reason. Knob:
  `TPU_RAIDEN_MAX_STAGED_READS_PER_PEER` (same pattern as
  `TPU_RAIDEN_DYNAMIC_HOST_STAGING`) plus an explicit `Create()` argument;
  unset or `0` leaves admission exactly as it is. The parked test is
  re-enabled under cap `kSlots − 1` with the owners' two healthy-peer
  assertions verbatim, plus assertions that the excess sick read is refused
  up front and that every per-peer charge is returned on settle; two
  `StagingBlockAllocatorTest` unit tests cover the allocator alone (cap
  refuses only the peer at cap, and only while it is at cap; no cap leaves
  admission unchanged).
- **Validation (2026-10-07, on `50b0774`, OSS build):** patch applied,
  tests run, upstream files restored. The re-enabled test alone, verbatim
  (log lines not about admission omitted):
  ```
  [ RUN      ] ControlHandshakeTest.SickPeerStarvesStagingSlotsForHealthyPeer
  I0000 00:00:1791391420.582191      12 kv_cache_manager_with_transfer.cc:1132] StagingBlockAllocator: capping staged reads per peer at 7 (num_slots=8)
  E0000 00:00:1791391420.583945      12 transfer_receive_session.cc:235] StartRead: cannot stage 1 blocks for req_id=sick7 from peer=127.0.0.1:46081: Peer 127.0.0.1:46081 already holds 7 staged reads (cap 7); refusing to stage more (dynamic=false, free_host_blocks=0, free_slots=1, held_by_peer=7, max_blocks=8)
  I0000 00:00:1791391420.584110      12 kv_cache_manager_with_transfer.cc:826] StartRead (initiate): req_id=healthy0, uuid=900, numa=-1
  I0000 00:00:1791391420.584206      12 transfer_receive_session.cc:517] StartRead (connecting): req_id=healthy0, uuid=900, numa=-1
  [       OK ] ControlHandshakeTest.SickPeerStarvesStagingSlotsForHealthyPeer (48 ms)
  ```
  The full targets (the two that carry the new tests plus every other
  hardware-free test that links the allocator), verbatim:
  ```
  //tpu_sync/core:kv_cache_manager_with_transfer_ip_test          (cached) PASSED in 0.1s
  //tpu_sync/core:kv_cache_manager_with_transfer_control_test              PASSED in 47.8s
  //tpu_sync/core:kv_cache_manager_with_transfer_pool_reshard_test         PASSED in 22.6s
  //tpu_sync/core:kv_cache_manager_with_transfer_send_drain_test           PASSED in 43.6s
  //tpu_sync/core:transfer_send_session_test                               PASSED in 22.4s

  Executed 4 out of 5 tests: 5 tests pass.
  ```
  (23 tests in the control target, the 22 existing plus the re-enabled one;
  12 in `transfer_send_session_test`, 10 plus the two new
  `StagingBlockAllocatorTest` cases.) `kv_cache_manager_with_transfer_test`
  is `no_oss` / `requires-jellyfish` (TPU hardware) and was not run. The OSS
  build needs a compiler the `.bazelrc` `oss` config can find; here
  `--action_env=CC=clang-21 --action_env=CXX=clang++-21 --repo_env=CC=clang-21`.
- **Open design choices for the owners:** refuse at the cap (as patched,
  matching today's `StartRead` contract and the proof) vs. wait; env knob vs.
  a constructor / Python parameter. A self-sizing share (cap derived from the
  number of peers currently holding staging) is a natural follow-up and would
  need its own proof.

---

## Refuted or closed

### R-A. Premature completion in `TransferReceiveSession::IsReadyToComplete()`: REFUTED

The transport dispatches a layer before counting its blocks
(`block_transport.cc:789` then `:629-630`); the receiver counts per shard
and across senders; the `network_completed_` disjunct is an intentional fast path. The
receive-session model proves readiness sound under this ordering
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

`DeadlineLoop` (`kv_cache_store_service.cc:1040`) marks the op failed but
does **not** free the landing blocks. They are freed only when the transfer
future resolves (`CompleteWriteRemote`, `:832-872`, → `ReleaseLandingBlocks`
`:572`); a leak warning is logged if the transfer never resolves
(`:1068-1079`). This is the `deferSettleWhilePullInFlight` design from the
Lean model. `ReadRemote` (F2) lacks it, which suggests F2 is an oversight
rather than a design choice.

### R-E. Local `KVCacheStore::Load` reads host blocks that could be evicted mid-copy: REFUTED (read)

Both `Load` overloads require that the caller already holds a pin on every
hash; eviction skips pinned entries (`host_offload_backend.cc:665, 813`,
`lru_cache.h:258-294`).

### R-F. Fetch-source (production remote load) unpins before the pull finishes: REFUTED (read)

It matches and pins atomically (`pin_found = true`,
`kv_cache_store_service.cc:444-456`); the pins are released by a scope cleanup
after `transfer_future.Await()` returns (`:473`, `:525`).

### Open / not yet checked

- `KVCacheStoreClient::Fetch` sets no RPC deadline
  (`kv_cache_store_client.cc:61-125`). If the RPC fails with a transport error
  while the source's workers are still writing, `LoadRemoteBlocks` frees
  `dst_host_block_ids` immediately (`host_offload_backend.cc:1182-1193`). Same
  shape as F2 but in the production path. Whether in-flight source DMA can
  outlive a failed Fetch RPC depends on worker and transport teardown, not
  established. **PLAUSIBLE.**
- ReadRemote hooks capture a raw `this`, and `ClearReadRemoteHooks` is not
  called in `~KVCacheStore`. The controller is owned by the store and is
  destroyed first among the members that matter, so this is probably safe.
  Not verified.

## Observations on the prefill-to-decode path (non-bugs at `1fa06d1`)

Behaviours that looked like defects during the prefill-to-decode model work and
turned out to be intended, dead, or proved unreachable. Kept here so they are not
re-investigated; the Lean names in the last column are the proofs. Short names
as in the Lean preambles: `recv.cc` = `tpu_sync/kv_cache/transfer_receive_session.cc`,
`send.cc` = `tpu_sync/kv_cache/transfer_send_session.cc`,
`mgr.cc` = `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`,
`bt.cc` = `tpu_sync/transport/block_transport.cc`.

| Observation | Where (`1fa06d1`) | Note |
|---|---|---|
| client-side `SendAck` has no non-test caller; the server-side `OnAck → HandleAck → AckSend → Finish()` handler is wired but never triggered in-repo | `grpc_control_plane_backend.cc:373`, `tcp_control_plane_backend.cc:662`; `mgr.cc:1376-1378, 1553-1556, 1619-1630` | dead path; excluded (`Send` A5) |
| a failed **send** is reported in `failed_recving_` | `mgr.cc:929-930` | naming/semantics quirk visible through `poll_stats()` |
| first `Finish` wins on the send side; a later cancel is ignored | `send.cc:167-176` | intended; `trace_cancel_after_ok_finish` |
| `IsReadyToComplete` can be true before all H2D callbacks ran | `recv.cc:431-437` | `done` still waits for every callback through `in_flight_` (`pollReady_no_settle`), so the outcome and its timing are unchanged. But when the poll wins that window the last callback finds `draining_` and skips `RecordTransferDuration`/`RecordH2dComplete`/`RecordEnd` (`recv.cc:699-705, 719-729`) — the transfer's metrics record keeps default times (`trace_poll_skips_metrics`). With `num_layers() > 0` the `num_completed_layers_ == total_layers` disjunct and the `if (all_complete)` finish in `OnBlockShardsReceived` (`RecordNetworkCompleteLocked`) are dead (`reachable_callbackFinishes`, `netAccount_frame`); only a zero-layer receive needs the poll (`noPoll_zero_layers_never_succeeds`). Removing the poll (design alternative `stepM false` in `ReceivePoll.lean`) keeps every proved property and settlement (`noPoll_safe`, `noPoll_can_settle`) and makes `published = some true → metrics` an invariant (`noPoll_metrics_on_success`). |
| `EndSendOpLocked` has no underflow guard, `EndRecvOpLocked` does | `send.cc:189-196` vs `recv.cc:388-391` | underflow proved unreachable (`NoUnderflow`) |
| `LOG(DFATAL) "H2D callback for retired receive"` is unreachable | `recv.cc:691-693` | proved (`NoRetiredCallback`) |
| `done_` is redundant in six lifecycle guards | `recv.cc:369, 393, 578, 622, 648`, `recv.h:118` (send side: `send.cc:168, 191, 238, 252, 299`) | `done → draining` and `done → in_flight_ == 0` are `Lifecycle.Consistent`, which every model keeps in its invariant (`Inv.life`); the guards without `done_` are the same functions on consistent states (`finishLocked'_eq`, `endOpLocked'_eq`, `beginOp'_eq`, `Consistent.done_or_draining`). Defensive code, not a bug. The two `LOG(DFATAL)` branches (`recv.cc:388-391`, `691-693`) are assertions — unreachable by `Accounted` / `NoRetiredCallback` — and stay. `Session.lean` |
| a failed incoming push reaches the session as a flat `InternalError("Incoming push failed")` | `bt.cc:509-516` → `mgr.cc:241-244` (`4efb0dd`) | the actual cause (read timeout, size mismatch, `OnLayerReceived` error) is only in the transport log, so `failed_recving` cannot tell them apart. Observability, not correctness; the model does not distinguish error statuses. |

---

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
- 2026-10-06: upstream `50b0774` merged into `experimental` (`77eeec8`).
  Re-checked by diff: `raiden_controller.cc` byte-identical to `01ffa3d`
  (F2, F3, F4 numbers hold); the F1 regions of `kv_cache_store.cc`
  (`ValidateAndPinHostBlocks`, `Evict`/`Insert`) unchanged, lines moved by
  +11 (1655–1683 at `01ffa3d` → `kv_cache_store.cc:1666-1694`); F4 fix PR #1105 still open, not merged.
  No finding fixed. Line numbers in this file and in `filed_bugs.md`
  re-pinned to `50b0774`; both patches still apply cleanly.
- 2026-10-07: F5 added. Confirmed on `50b0774` by running the owners' parked
  `DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`; fix written, tested
  and shipped as `per_peer_staging_admission.patch` (output above). Upstream
  `main` checked at `ebcc7af` (three commits past `50b0774`: `93e09ee`,
  `a29649c`, `ebcc7af`): none touches `StartRead` admission or the
  allocator, the test is still `DISABLED_`, and no issue or PR proposes a
  per-peer cap.
- 2026-10-10: upstream `1fa06d1` (38 commits past `50b0774`). **F4 fixed
  upstream** by `72255dd` (2026-10-07; the PR #1105 shape, three new tests);
  its hunk dropped from `candidate_fixes.patch`. F1, F2, F3, F5 unchanged
  (`kv_cache_store.cc` F1 regions moved +6 since `50b0774`; `ReadRemote` region of
  `raiden_controller.cc` moved +35, byte-identical; `StartRead` admission and
  the allocator untouched, `DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`
  still disabled). Sessions and manager moved to `tpu_sync/kv_cache/`
  (`5afe1ef`); `per_peer_staging_admission.patch` re-based onto the new paths,
  all three patches apply cleanly. Tests not re-run.
