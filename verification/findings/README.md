# Bug-hunt findings

Defects found while modelling tpu-sync, with the evidence for each. Line
numbers are for tpu-sync `0ac16d1` unless a block of test output says
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
| `reshard_bughunt_test.cc` | R7a, R7b, R8, R2b of `docs/transfer/reshard.md` (registry / coordinator claim lifecycle; all four pass, not yet filed) |
| `reshard_send_session_bughunt_test.cc` | F10 (R6 of `docs/transfer/reshard.md`): the sender's early plan unregister and the uuid-keyed staging lease it hands to a retry |
| `build_targets.patch` | `cc_test` targets for the four files above |
| `candidate_fixes.patch` | fixes for F1 and F2 (naive, shape A only); the F4 hunk was dropped when upstream fixed F4 (`72255dd`); see "Fix validation" |
| [`filed_bugs.md`](filed_bugs.md) | verbatim write-ups of bugs filed upstream |

To run F1–F4: copy the two `.cc` files next to the code they test
(`tpu_sync/core/controller/`, `tpu_sync/kv_cache/`), `git apply
verification/findings/build_targets.patch`, then
`bazel test //tpu_sync/core/controller:raiden_controller_bughunt_test
//tpu_sync/kv_cache:kv_cache_store_pin_race_test`. F5 needs no repro file:
its test is already in the tree as `DISABLED_`
(`bazel test --config=oss //tpu_sync/kv_cache:kv_cache_manager_with_transfer_control_test
--test_arg=--gtest_also_run_disabled_tests`); the fix patch that re-enabled it
was retired on 2026-10-16 (see F5). Both patches apply cleanly at `0ac16d1`.

## Summary

| # | Finding | Status | Reachable from production? |
|---|---|---|---|
| F1 | `ValidateAndPinHostBlocks` can return a host block id that no longer holds the hash ([filed](filed_bugs.md#4-kvcachestorevalidateandpinhostblocks-check-then-act-window-between-lookup-and-pin-can-return-a-stale-host_block_id-f1) 2026-10-19) | CONFIRMED (test); filed upstream, fix pending | only via the `ReadRemote` API (no in-tree caller) |
| F2 | Remote read keeps DMA-ing into destination blocks after it settled with a deadline error | CONFIRMED (test) for shapes A and B (B added 2026-10-20, on upstream `449b591`); proved in Lean for both | same |
| F3 | Data race on `RemoteReadState::lease_id` | CONFIRMED (read) | same |
| F4 | `TransferBuffers` leaks auto-allocated staging on every early error, and can return an error after some workers were dispatched ([filed](filed_bugs.md#1-raidencontrollertransferbuffers-error-path-defects-f4), fix: [PR #1105](https://github.com/google/tpu-sync/pull/1105)) | CONFIRMED (test) on `b68161a` / `d16701e`, code unchanged through `50b0774`; **FIXED upstream** by PR #1105 = `72255dd` (2026-10-07) | leak: no in-tree trigger; orphaned copies: yes, via Fetch / WriteRemote on a node_id mismatch |
| F5 | One unresponsive producer pins every host staging slot; `StartRead` then rejects reads from every other producer (no per-peer admission; owner-acknowledged, fix designed and validated on `50b0774`, patch retired 2026-10-16) | CONFIRMED (test), with the owners' own parked test | yes: every consumer `StartRead`, given one producer that accepts and never answers |
| F6 | `PoolReshardRegisterRecv`: a rejected duplicate (or racing) registration for an active `uuid` destroys a session object whose destructor releases the **active** session's host-staging lease ([filed](filed_bugs.md#2-poolreshardregisterrecv-duplicate-registration-frees-the-active-sessions-staging-lease-f6)) | CONFIRMED (read) at `1fa06d1`; reproduced by the reporter; **FIXED upstream** in `8653373` (2026-10-13) | yes: any pool-reshard receiver with bounded host staging (`RegisterPools(..., staging_leases > 0)`), on a duplicate or concurrent register for the same `uuid` |
| F7 | `end_incoming_push` hook: a failed incoming push on a `ReshardReceiveSession` is not turned into `Finish(status)` (the `TransferReceiveSession` branch does), so the session, its staging lease and plan claim stay pinned until the deadline sweep, which reports `DEADLINE_EXCEEDED` instead of the push error ([filed](filed_bugs.md#3-reshardreceivesession-ignores-a-failed-endincomingpush-and-pins-poolstagingstorage-until-timeout-r1); R1 in `docs/transfer/reshard.md`) | CONFIRMED (read) at `0ac16d1`, witnessed in Lean (`Receive.lean`); **FIXED upstream** in `fdeebcd` (2026-10-16) | yes: any pool-reshard receiver whose sender's push fails mid-transfer (socket timeout / disconnect) |
| F8 | `ReshardCoordinator::ExecutePoolReshard`: the sender-dispatch error return omits `registry_->AbandonClaim(...)` (the plan-build, receiver-arm and null-controller returns all call it), so the request stays `STATUS_CLAIMED` until `ttl_s_`, refusing `CancelIfUnclaimed` and re-registration ([filed](filed_bugs.md#5-reshardcoordinatorexecutepoolreshard-sender-dispatch-failure-returns-without-calling-abandonclaim-leaking-the-registry-claim-r2b) 2026-10-19; R2b in `docs/transfer/reshard.md`) | CONFIRMED (test) at `0ac16d1` (`reshard_bughunt_test.cc`); filed upstream, fix pending | yes: any pool reshard whose sender `StartTransfer` RPC fails after the receivers were armed |
| F9 | `RequestBlockRegistry::LookupAndClaim` refreshes the `claimed_` TTL but not `expires_at` on the claimed `request_blocks_` rows, so in `[t_reg + ttl, t_claim + ttl)` the producer registrations are purged while the claim is live: `Status` says `STATUS_CLAIMED`, `CancelIfUnclaimed` refuses, and a sibling stage or retry fails with `"Missing producer block registration"` ([filed](filed_bugs.md#6-requestblockregistrylookupandclaim-claiming-a-request-does-not-refresh-request_blocks_-ttl-evicting-producer-registrations-while-the-claim-is-active-r8) 2026-10-19; R8 in `docs/transfer/reshard.md`) | CONFIRMED (test) at `0ac16d1` (`reshard_bughunt_test.cc`); filed upstream, fix pending | yes: any multi-stage pool reshard (or a retry) whose later claim lands more than `ttl_s_` after registration but before the first claim expires |
| F10 | `ReshardSendSession::RecordPushCompletion` unregisters the sender's plan on the **first** failed push while sibling pushes are still in flight (`EndOp` would do it at settle). Siblings then resolve no chunks, and — the sharp half — a retry of the same `uuid` is accepted by `Create` while the failed session drains, shares its uuid-keyed staging lease, and loses that staging when the old session settles; a third transfer is then leased the same slot (the F6 shape, reopened on the sender) (R6 in `docs/transfer/reshard.md`) | CONFIRMED (test) 2026-10-20 (`reshard_send_session_bughunt_test.cc`, against the `1fa06d1` build; the code involved is unchanged through `449b591`); not yet filed | yes: any pool-reshard sender with bounded host staging whose first failing push has siblings in flight and whose transfer is retried under the same `uuid` before the old session drains |

---

## F1. `ValidateAndPinHostBlocks` can return a host block id that no longer holds the hash

- **Status:** **CONFIRMED (test)**, 2026-09-24, on unmodified `b68161a`;
  re-run on `d16701e` with the same result. Filed upstream 2026-10-19
  ([write-up](filed_bugs.md#4-kvcachestorevalidateandpinhostblocks-check-then-act-window-between-lookup-and-pin-can-return-a-stale-host_block_id-f1)),
  code unchanged through `0ac16d1`; fix pending. Output, verbatim:
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
- **Where:** `tpu_sync/kv_cache/kv_cache_store.cc:1615-1642`
  (`KVCacheStore::ValidateAndPinHostBlocks`).
- **Defect:** The function calls `backend()->Lookup(hashes)` with default
  options (`:1618`; `pin_found = false` by default,
  `kv_cache_store_backend.h:104`), copies `host_block_id`, and only then calls
  `backend()->Pin(hashes)` (`kv_cache_store.cc:1637`). The backend mutex is
  released between the two calls. The only lock held across them is
  `KVCacheStore::mutex_`, and neither of the following takes it:
  - `KVCacheStore::Evict` (`:1800`). The comment at `:1804-1806` says "We do
    not hold store mutex_". It is called from `SweepOnce` and
    `AllocateBlockIds`.
  - `KVCacheStore::Insert` (`:1008`).
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
    controller; the hook is registered at `kv_cache_store.cc:1602-1612`.
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

- **Status:** **CONFIRMED (test)** for shapes A and B. Shape A first on
  `b68161a` (2026-09-24); both shapes on 2026-10-20 against upstream `main`
  `449b591` (controller sources rebuilt from `449b591`, leaf libraries from
  the `0ac16d1` OSS build; `raiden_controller.cc`'s `ReadRemote` region is
  unchanged between the two). **Proved in Lean** for shapes A and B
  (`TpuSyncVerify/Controller/ReadRemote.lean`, exhaustive over the reachable
  state space).
- **C++ test output** (unmodified code, verbatim, 2026-10-20 run; the tests
  are written so that a failure shows the defect):
  ```
  [ RUN      ] BugHuntTest.ReadRemoteDoesNotStartPullAfterDeadlineSettled
  [F2] settled after 1.001596645s with: ReadRemote exceeded the destination deadline (1s)
  [F2] pulls issued at settle: 0, pulls issued 4s later: 1
  raiden_controller_bughunt_test.cc:119: Failure
    pulls_after  Which is: 1
  A pull into dst host block 20 was issued AFTER ReadRemote settled with DeadlineExceeded.
  [ RUN      ] BugHuntTest.ReadRemoteSettlesDeadlineWhilePullStillInFlight
  [F2-B] settled after 1.002245805s with: ReadRemote exceeded the destination deadline (1s)
  [F2-B] at settle: pull started=1, pull finished=0
  [F2-B] pull finished 2.004212569s AFTER the caller was told the read failed
  raiden_controller_bughunt_test.cc:206: Failure
  Expected: (finished_after) <= (absl::ToUnixNanos(settled_at)), actual: 1792516287098830194 vs 1792516285094617625
  The DMA into dst host block 20 was still running when ReadRemote settled with DeadlineExceeded, and finished afterwards.
  ```
  Both set `RAIDEN_REMOTE_READ_DEADLINE_S=1`. Shape A delays the source's
  `AcquireReadLease` by 2.5 s with the existing `SetLeaseGrantedHookForTest`
  seam (`controller_service.h:106`). Shape B answers the acquire immediately
  and makes the worker's `H2hReadExplicit` take 3 s (`SlowReadMock`), so the
  deadline fires while the pull is in flight. That configuration only makes
  the tests fast. With defaults the deadline is the lease TTL plus 30 s
  (`raiden_controller.cc:107-130`), so shape A needs an acquire that takes
  longer than that (a hung source) and shape B a pull that outlives the
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

- **Status:** **CONFIRMED (test)** on `b68161a` / `d16701e` (code unchanged through `50b0774`), both halves; **FIXED upstream
  in `72255dd`** (2026-10-07, "Validate all workers before dispatching in
  `RaidenController::TransferBuffers` and release auto-allocated staging on
  error" = [PR #1105](https://github.com/google/tpu-sync/pull/1105), merged
  via copybara). At `0ac16d1` (unchanged since `1fa06d1`) every worker is matched
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
    (`:773`, remote DRAM → DRAM), `host_offload_backend.cc:1151`, `:1243`
    (local DRAM → HBM), `:1325` (local HBM → DRAM). No Python binding or
    vllm-torchtpu code calls `TransferBuffers` directly.
  - **Orphaned-copy half: reachable from production.** Fetch and WriteRemote
    pass remote worker endpoints, so they go through the node_id matching
    loop. If some workers match and a later one does not,
    `raiden_controller.cc:722` / `:737` (at `50b0774`)
    return after the earlier workers were dispatched. Fetch then awaits the
    error, unpins its source blocks (`unpin_cleanup`,
    `kv_cache_store_service.cc:473`) and fails the RPC; the client's
    `LoadRemoteBlocks` frees `dst_host_block_ids`
    (`host_offload_backend.cc:1114-1125`). Meanwhile the dispatched worker
    copy may still be reading the source and writing the destination.
  - **Trigger:** the two sides disagree about which node_ids exist
    (config/topology mismatch). How likely that is in real deployments is
    not established.
- **Fix:** the cleaner shape — resolve and match every worker *before*
  allocating or dispatching anything
  ([google/tpu-sync#1105](https://github.com/google/tpu-sync/pull/1105)) —
  landed upstream as `72255dd` (the PR's copybara merge). The earlier `candidate_fixes.patch` hunk
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
  E0000 00:00:1791391218.831497      12 transfer_receive_session.cc:226] StartRead: cannot stage 1 blocks for req_id=healthy0 (dynamic=false, free_host_blocks=0, free_slots=0, max_blocks=8)
  tpu_sync/kv_cache/kv_cache_manager_with_transfer_control_test.cc:1126: Failure
  Value of: consumer.has_recv(900)
    Actual: false
  Expected: true
  the read to the healthy peer was rejected outright because an unresponsive peer holds all 8 staging slots; no request to a healthy producer can even be attempted while another producer is wedged
  tpu_sync/kv_cache/kv_cache_manager_with_transfer_control_test.cc:1137: Failure
  Value of: failed_recving
  Expected: doesn't contain any element that is equal to "healthy0"
    Actual: { "healthy0" }, whose element #0 matches
  the healthy read failed immediately rather than being served
  [  FAILED  ] ControlHandshakeTest.DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer (48 ms)
  ```
- **Where:** `KVCacheManagerWithTransfer::StartRead` →
  `TransferReceiveSession::Create` → `AllocateStagingForLoad` →
  `StagingBlockAllocator::Acquire`, non-blocking and first-come-first-served
  (`kv_cache_manager_with_transfer.cc:903-912`,
  `transfer_receive_session.cc:208-235`,
  `tpu_sync/core/staging_arena.cc:514-518`, slot pop `:494-499`; the allocator moved
  there from `kv_cache_manager_with_transfer.cc` in `fc8cff9`).
  - The slot is taken *before* the handshake because the pull request
    carries the allocated host block ids (`transfer_receive_session.cc:523`);
    lazy allocation after the peer answers is not an option.
  - It is released only in `FinishLocked()` / `EndRecvOpLocked()` via
    `ReleaseStagingLocked()` once no copy or push is in flight
    (`Lifecycle.settleLocked` / the `inFlight = 0` rule of the Lean model), so
    cancelling a read to a dead peer does not return its slot before the
    deadline.
  - On `ResourceExhausted`, `StartRead` puts the request in `failed_recving_`
    and returns (`kv_cache_manager_with_transfer.cc:908-911`). No queueing: the
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
- **Fix (proposed; the patch `per_peer_staging_admission.patch` was validated on
  `50b0774`, re-based onto `1fa06d1`, and retired on 2026-10-16 when upstream
  moved `StagingBlockAllocator` to `tpu_sync/core/staging_arena.{h,cc}` in
  `fc8cff9` — the design and the proof stand, the diff is in the git history at
  tag `upstream-main-2026-10-10`):** `StagingBlockAllocator`
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
  E0000 00:00:1791391420.583945      12 transfer_receive_session.cc:228] StartRead: cannot stage 1 blocks for req_id=sick7 from peer=127.0.0.1:46081: Peer 127.0.0.1:46081 already holds 7 staged reads (cap 7); refusing to stage more (dynamic=false, free_host_blocks=0, free_slots=1, held_by_peer=7, max_blocks=8)
  I0000 00:00:1791391420.584110      12 kv_cache_manager_with_transfer.cc:858] StartRead (initiate): req_id=healthy0, uuid=900, numa=-1
  I0000 00:00:1791391420.584206      12 transfer_receive_session.cc:537] StartRead (connecting): req_id=healthy0, uuid=900, numa=-1
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

## F6. `PoolReshardRegisterRecv`: duplicate registration frees the active session's staging lease

- **Status:** **CONFIRMED (read)** at `1fa06d1`; reproduced by the reporter
  on a bounded-staging receiver (`RegisterPools(..., staging_leases=2)`),
  output not pasted here. Found during the Lean formalization of the pool
  reshard receive path. Filed upstream 2026-10-13 ([write-up](filed_bugs.md#2-poolreshardregisterrecv-duplicate-registration-frees-the-active-sessions-staging-lease-f6));
  **FIXED upstream in `8653373`** (2026-10-13): `ReshardReceiveSession::Create`
  now claims the `uuid` with `RegisterActivePlanDirect` before constructing the
  session and acquiring staging, and rolls the claim back with
  `UnregisterActivePlanDirect` when `AcquireStagingLeases` fails
  (`reshard_receive_session.cc:376-388` at `0ac16d1`); the pool-lease
  forwarders left `StagingBlockAllocator`. Three regression tests:
  `PoolStagingRecvRegistrationTest.DuplicatePoolRecvRegistrationKeepsOriginalStagingLease`,
  `…ConcurrentDuplicatePoolRecvRegistrationKeepsWinnerStagingLease`,
  `…StagingAcquireFailureReleasesUuidClaim` in
  `kv_cache_manager_with_transfer_pool_reshard_test.cc`. The description
  below is of the unfixed code at `1fa06d1`.
- **Where (at `1fa06d1`, before the fix):** two layers disagree about who owns a staging lease.
  1. The per-storage lease table is keyed by `uuid` only, not by session
     instance: `KVCacheManagerBase::AcquirePoolStagingLease`
     (`kv_cache_manager_base.cc:2086-2143`) is idempotent per `uuid` — it
     returns `OK` when `pool_staging_[s].leases[uuid]` already covers the
     requested blocks (`:2095-2113`) — and `ReleasePoolStagingLeases(uuid)`
     (`:2145-2161`) unconditionally erases `leases[uuid]` and returns all of
     its slots to `free_slots` (`:2150-2156`). `StagingBlockAllocator`
     forwards both (`kv_cache_manager_with_transfer.cc:1261-1275`).
  2. `ReshardReceiveSession` is a per-call heap object that acquires staging
     *before* `uuid` uniqueness is enforced. `PoolReshardRegisterRecv`
     (`kv_cache_manager_with_transfer.cc:642-677`) checks
     `active_pool_reshard_recvs_` under `mu_` (`:649-663`), but that table
     only holds sessions whose registration already completed (`:672-675`).
     `mu_` is released while `ReshardReceiveSession::Create`
     (`reshard_receive_session.cc:351-377`) constructs the object (`:372-374`)
     and calls `AcquireStagingLeases` (`:375` → `:407-444`), which sets
     `staging_released_ = false` (`:419`) and leases per storage (`:437-438`,
     possibly blocking on `staging_cv_` for free slots,
     `kv_cache_manager_base.cc:2121-2130`) — all before
     `RegisterActivePlanDirect(uuid)` claims the `uuid` in `active_plans_`
     (`kv_cache_manager_with_transfer.cc:670-671`).
     (`ReshardSendSession::Create` does it the other way round and claims the
     `uuid` first, `reshard_send_session.cc:138-139`.)
- **Sequence** (two `PoolReshardRegisterRecv` calls for the same `uuid = U`
  overlapping in that window, or one call for a `U` already in
  `active_plans_`):
  1. Session S1 acquires `leases[U]`, `staging_released_ = false`.
  2. Session S2, a distinct object for the same `U`, also passes `Create`:
     `AcquirePoolStagingLease(U)` finds `leases[U]` populated and returns
     `OK`; S2 sets `staging_released_ = false`.
  3. S2 is rejected: `RegisterActivePlanDirect(U)` returns `ALREADY_EXISTS`.
  4. S2 goes out of scope: `~ReshardReceiveSession` → `ReleaseStaging()`
     (`reshard_receive_session.h:71`, `.cc:446-455`) →
     `ReleasePoolStagingLeases(U)` erases `leases[U]` and frees S1's slots
     while S1 is still active.
- **Impact:**
  - the active session fails: incoming pushes for `U` can no longer resolve
    their host staging buffer (`GetBlockChunks(uuid = U)` returns no chunks);
  - **silent host-buffer aliasing:** `U`'s physical slots are back in
    `free_slots`, so the next transfer `U2` is leased the same host memory
    while `U` is still active, with no error raised.
- **Reachability:** production path, every bounded-staging pool-reshard
  receiver. Trigger: a duplicate `PoolReshardRegisterRecv` (coordinator retry)
  for an active `uuid`, or two concurrent registrations for the same `uuid`
  while both wait on staging slots — one returns `OK`, the loser returns
  `ALREADY_EXISTS` and its destructor erases the winner's lease.
- **Reporter's observations** (bounded receiver with `staging_leases=2`):
  with `uuid=4001` holding a lease and registered in `active_plans_`, a
  rejected `PoolReshardRegisterRecv(4001)` moves `free_slots` from 1 back to
  2, `GetBlockChunks(uuid=4001)` returns 0 chunks, and a following
  `PoolReshardRegisterRecv(4002)` receives the same physical slot pointer as
  `4001`; with two threads calling `PoolReshardRegisterRecv(4001)`
  concurrently while waiting on slots, one returns `OK`, one
  `ALREADY_EXISTS`, and `free_slots` becomes 2 with `GetBlockChunks(4001)`
  empty.
- **Fix (proposed, in preparation):** claim the `uuid` via
  `RegisterActivePlanDirect` in `ReshardReceiveSession::Create` before
  constructing the session and acquiring staging, rolling back with
  `UnregisterActivePlanDirect` if `AcquireStagingLeases` fails — the order
  `ReshardSendSession::Create` already uses.
- **Lean:** the pool-reshard path is outside the prefill-to-decode model
  (`docs/transfer/prefill_decode.md` §Boundaries, row 1); `Transfer/Session.lean`
  covers only the per-session settle protocol, whose `hasStaging` token is
  per *instance* — exactly the property the shared `uuid`-keyed lease table
  breaks. A `UuidTable`-style model of `active_plans_` + `pool_staging_`
  would make this a one-step counterexample (`registerRecv` of a live uuid
  followed by the loser's `release`); not written.

---

## F7. `end_incoming_push`: a failed push on a `ReshardReceiveSession` is not finished, pinning staging until the deadline

- **Status:** **CONFIRMED (read)** at `0ac16d1`; witnessed in Lean as R1
  (`trace_r1_failed_incoming_push` in `TpuSyncVerify/Transfer/Reshard/Receive.lean`,
  tracked as R1 in `docs/transfer/reshard.md`). Filed upstream 2026-10-16
  ([write-up](filed_bugs.md#3-reshardreceivesession-ignores-a-failed-endincomingpush-and-pins-poolstagingstorage-until-timeout-r1));
  **FIXED upstream in `fdeebcd`** (2026-10-16): the reshard branch of the hook
  now calls `reshard_session->Finish(status)` when `!status.ok()` before
  `EndRecvOp()`, with one regression test,
  `PoolReshardRecvTest.FailedIncomingPushReleasesStagingLeaseBeforeDeadline`
  in `kv_cache_manager_with_transfer_pool_reshard_test.cc`. The description
  below is of the unfixed code at `0ac16d1`.
- **Where (at `0ac16d1`, before the fix):** `KVCacheManagerWithTransfer::InitializeBaseHooks()`
  (`kv_cache_manager_with_transfer.cc:250-290`). The `TransferReceiveSession`
  branch calls `DeferUnregisterOnSettle(); Finish(status)` on a failed push
  before `EndRecvOp()` (`:266-271`); the `ReshardReceiveSession` branch calls
  `EndRecvOp()` only and ignores `status` (`:279-289`).
- **Sequence:** the sender does not retry a failed push
  (`ReshardSendSession::RecordPushCompletion`, `reshard_send_session.cc:351-373`,
  latches `finalizing_` on the first error), and
  `ReshardReceiveSession::EndRecvOpLocked` (`reshard_receive_session.cc:495-505`)
  settles only when `draining_ && in_flight_ == 0`. So a failed push drops
  `in_flight_` to 0 with `draining_ == false` and `status_ == OK`; `Done()` is
  false, `UnregisterSettledPlan` is skipped, and the hook returns `OK`.
- **Impact:** the session's `PoolStagingLease` keeps its bounded slots and
  `active_plans_[uuid]` stays registered until the deadline sweep
  (`kv_cache_manager_with_transfer.cc:1037-1066`) fires at `timeout_s_`
  (default 120 s) and reports `DEADLINE_EXCEEDED: Pool reshard receive timed
  out`, masking the original error; meanwhile later pool reshards wait on
  `AcquirePoolStagingLease` up to `pool_staging_lease_timeout()` (10 s) and
  fail with `RESOURCE_EXHAUSTED`.
- **Fix:** `if (!status.ok()) reshard_session->Finish(status);` before
  `reshard_session->EndRecvOp()` — as landed in `fdeebcd`.

---

## F8. `ExecutePoolReshard`: sender-dispatch failure leaks the registry claim

- **Status:** **CONFIRMED (test)** at `0ac16d1`, 2026-10-17, by
  `ReshardBughuntTest.R2b_SenderDispatchFailureOrphansRegistryClaimAndArmedReceiver`
  in `reshard_bughunt_test.cc` (tracked as R2b in `docs/transfer/reshard.md`,
  witnessed in Lean by `trace_r2b_dispatch_failure_orphans_receivers_and_claim`
  in `Coordinator.lean`). Filed upstream 2026-10-19
  ([write-up](filed_bugs.md#5-reshardcoordinatorexecutepoolreshard-sender-dispatch-failure-returns-without-calling-abandonclaim-leaking-the-registry-claim-r2b));
  fix pending. Output, verbatim (built against the warm OSS Bazel outputs with
  the recipe in `notes/empirical/oss-bazel-test-recipe.md`; all four tests in
  the file pass):
  ```
  [ RUN      ] ReshardBughuntTest.R2b_SenderDispatchFailureOrphansRegistryClaimAndArmedReceiver
  [       OK ] ReshardBughuntTest.R2b_SenderDispatchFailureOrphansRegistryClaimAndArmedReceiver (0 ms)
  ```
  (The test asserts the defect: after the injected sender failure,
  `GetRequestBlockStatus` is `STATUS_CLAIMED` and `CancelIfUnclaimed` returns
  `"false"`; it passes on unmodified code and would fail once the fix lands.)
- **Where (at `0ac16d1`):** `ReshardCoordinator::ExecutePoolReshard`
  (`reshard_coordinator.cc:415-544`). `BuildPoolReshardPlan` claims
  `(req_id, uuid)` under a fresh `claim_owner` (`:417-420`). The three error
  returns that follow — plan build (`:421-424`), receiver arm (`:458-463`),
  null controller (`:483-487`) — call `registry_->AbandonClaim(args.req_id,
  uuid, claim_owner)`. The sender-dispatch return (`:542-544`) does not.
- **Impact:** the sender never started, so no `Complete` vote will arrive; the
  claim stays in `claimed_owners_` and the request reads `STATUS_CLAIMED` until
  `ttl_s_`. In that window `CancelIfUnclaimed`
  (`request_block_registry.cc:388-390`) returns `false` and `Register` for the
  same `(req_id, uuid)` is refused (`:281-285`). The receivers armed in the
  previous step are left waiting for pushes that never come until their own
  `timeout_s_` (that half is R2a, not filed).
- **Fix (proposed):** call `registry_->AbandonClaim(args.req_id, uuid,
  claim_owner);` before `return status;` at `:542-544`, matching the other
  three paths.
- **Sibling candidates, same file family, confirmed by the same test file but
  not filed:** R7b (`AbandonClaim` leaves `completed_units_` behind), R7a
  (owner-unscoped `completed_units_` in `Complete`). See
  `docs/transfer/reshard.md`. R8 is filed as F9 below.

---

## F9. `LookupAndClaim`: claim TTL and registration TTL diverge, purging claimed rows

- **Status:** **CONFIRMED (test)** at `0ac16d1`, 2026-10-17, by
  `ReshardBughuntTest.R8_SplitTtlEvictsRequestBlocksWhileClaimIsStillActive`
  in `reshard_bughunt_test.cc` (R8 in `docs/transfer/reshard.md`, witnessed in
  Lean by `trace_r8_split_ttl_purges_request_blocks_while_claim_active` in
  `Registry.lean`). Filed upstream 2026-10-19
  ([write-up](filed_bugs.md#6-requestblockregistrylookupandclaim-claiming-a-request-does-not-refresh-request_blocks_-ttl-evicting-producer-registrations-while-the-claim-is-active-r8));
  fix pending. Output, verbatim (same run as F8):
  ```
  [ RUN      ] ReshardBughuntTest.R8_SplitTtlEvictsRequestBlocksWhileClaimIsStillActive
  [       OK ] ReshardBughuntTest.R8_SplitTtlEvictsRequestBlocksWhileClaimIsStillActive (1 ms)
  ```
  (With `ttl_s = 60`: register at `t = 1000`, stage 0 claims at `t = 1040`,
  at `t = 1070` the status probe still reads `STATUS_CLAIMED` while stage 1's
  `CoordinateTransfer` fails with `"Missing producer block registration"`.)
- **Where (at `0ac16d1`):** `request_block_registry.cc`. `Register` stamps
  `expires_at = now + ttl_s_` on each `request_blocks_` row (`:263`).
  `LookupAndClaim` (`:440-491`) reads those rows (`:462-470`), then sets
  `claimed_[key] = now + ttl_s_` (`:473`) and refreshes `completed_units_`
  (`:478`) but never touches the rows' `expires_at`.
  `PurgeExpiredRequestBlocksLocked` (`:61-69`) runs at the top of every
  operation and erases rows with `expires_at <= now` regardless of `claimed_`.
- **Impact:** in `[t_reg + ttl, t_claim + ttl)` the request is claimed with no
  backing registration. `Status` (`:421-423`) reports `STATUS_CLAIMED`,
  `CancelIfUnclaimed` (`:388-390`) refuses, and any further `LookupAndClaim`
  (`:464-468`) — a sibling pipelined stage, or the retry in upstream's own
  `AbandonedStageLeavesTheSiblingClaimInPlace` — fails. With the default
  `ttl_s_ = 600` this needs a claim that lands more than ten minutes after
  registration; with shorter TTLs (tests use 60) it is a narrow queueing delay.
- **Fix (proposed):** in `LookupAndClaim`, set `it->second.expires_at = now +
  ttl_s_` on each claimed row when setting `claimed_[key]`; or make
  `PurgeExpiredRequestBlocksLocked` skip rows whose `(req_id, uuid)` is in
  `claimed_`.

---

## F10. `ReshardSendSession`: the first failed push unregisters the plan while siblings are in flight, and hands the uuid's staging lease to a retry

- **Status:** **CONFIRMED (test)** 2026-10-20 by
  `ReshardSendSessionBughuntTest.R6_FirstFailedPushUnregistersPlanWhileSiblingInFlightAndReopensF6`
  in `reshard_send_session_bughunt_test.cc` (R6 in `docs/transfer/reshard.md`,
  witnessed in Lean by `trace_early_unregister_on_error_vs_onSettle` in
  `Send.lean`). Built against the `1fa06d1` OSS outputs and headers (the warm
  build on this machine); `RecordPushCompletion`, `Create`'s
  register-before-lease order, `AcquirePoolStagingLease` /
  `ReleasePoolStagingLeases` and `UnregisterActivePlanDirect` are unchanged
  through upstream `449b591` (the session's later diffs are data-connection
  reuse and the `StagingBlockAllocator` → `KVCacheManagerBase` forwarding move).
  Not yet filed. Output, verbatim (the test asserts the defect, so it passes
  on unmodified code):
  ```
  [ RUN      ] ReshardSendSessionBughuntTest.R6_FirstFailedPushUnregistersPlanWhileSiblingInFlightAndReopensF6
  E0000 ... reshard_send_session.cc:351] Pool reshard send failed uuid=6001 req_id=pool_reshard_req_6001: UNAVAILABLE: peer 1 refused
  [       OK ] ReshardSendSessionBughuntTest.R6_FirstFailedPushUnregistersPlanWhileSiblingInFlightAndReopensF6 (7 ms)
  ```
  The test drives the session's op accounting through upstream's own
  `ReshardSendSessionTestPeer` friend seam (`reshard_send_session.h`), because
  `ExecutePush` needs real D2H copies.
- **Where (at `0ac16d1`):** `ReshardSendSession::RecordPushCompletion`
  (`reshard_send_session.cc:351-392`). On the first `!status.ok()` it latches
  `finalizing_` and calls `manager.UnregisterActivePlan(uuid_)` (`:366-367`,
  `:383`) regardless of `in_flight_`. `EndOp` (`:418-440`) already unregisters
  when the last op of a finalizing send is counted out, so the early call is
  redundant on the success path and only differs when siblings are in flight.
- **Sequence shown by the test** (bounded staging, `staging_leases = 2`,
  one source block, two destination peers so `remaining_pool_peer_pushes = 2`):
  1. Session A: `Create` registers plan `uuid`; its lease takes one slot
     (`free_slots` 2 → 1); the push to peer 1 resolves one chunk at slot `P`.
  2. Peer 1's push fails; peer 2's is still in flight. `in_flight_ == 1`,
     `!Done()`, and **`HasActivePlan(uuid) == false`**.
  3. A sibling resolving its chunks now gets none (`GetBlockChunks(uuid)`
     empty). On a full-mirror storage the same call falls back to un-sliced
     full-block extents instead (`kv_cache_manager_base.cc:3306-3325`).
  4. A retry `Create` for the same `uuid` **succeeds** (it would be
     `ALREADY_EXISTS` while the plan is registered — the guard `8653373` relies
     on for the receiver). Its `AcquirePoolStagingLease(uuid)` is idempotent
     per uuid, so it shares A's slot: `free_slots` stays 1, the retry's chunk
     is `P`.
  5. Peer 2's push returns; A settles; `ReleaseLeasesLocked` →
     `ReleasePoolStagingLeases(uuid)` frees the shared slot: `free_slots`
     back to 2 while the retry is live, and the retry's `GetBlockChunks(uuid)`
     is now empty.
  6. A third transfer (`uuid + 1`) leases the same slot `P` — the F6
     aliasing, on the sender.
- **Impact:** a send that fails on one peer with others in flight drops its
  plan early; with a same-uuid retry arriving before it drains (the
  coordinator's own tests retry under the same uuid), the retry's host staging
  is released under it and reallocated to an unrelated transfer, silently.
  Without the retry the harm is limited: later chunk resolution in the failed
  session fails (bounded) or falls back to whole blocks (full mirror), and the
  socket adapter's per-uuid failure latch cancels the sibling posts anyway.
- **Fix (proposed):** drop the early `UnregisterActivePlan` in
  `RecordPushCompletion` (keep `finalizing_`); let `EndOp` unregister at
  settle, as it already does for sends finished from outside. Alternatively
  make `AcquirePoolStagingLease` refuse a uuid whose lease is held by a
  session that has not settled.

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


**Sharpened 2026-10-20 (`0ac16d1`), `Transfer/PrefillDecode/Transport.lean`.**
The hazard is narrower and the consequence more specific than the 2026-09
wording:

- Of the three completion contracts in `BlockTransport::CompleteIncomingPush`
  (`block_transport.cc:640-793`), the sender-declared (`:732-736`) and
  plan-declared (`:704-708`) ones reject a stream beyond the declared count and
  fail the receive; the chunk-count contract (`:739-741`) — the one the
  prefill-to-decode path uses whenever the receive plan has no
  `shard_push_schedules` (`kv_cache_manager_base.cc:2687-2703`) — accepts it
  silently. The duplicate is not dispatched (`completed_chunks ≠ num_streams`)
  but is still reported through `OnBlockShardsReceived` (`:629-630`), so
  `network_completed_` is reached with another layer's blocks never received,
  and `IsReadyToComplete` (`transfer_receive_session.cc:450-455`) reports
  success with that layer never copied
  (`Transport.trace_dup_chunk_publishes_missing_layer`).
- On **either** contract, once every layer has been called the transport
  erases the uuid's `layer_progress_` entries (`:764-778`) while the receive is
  still live (its H2D copies are in flight), and `ExecuteLayerH2d` has no
  once-latch of its own (`transfer_receive_session.cc:642-700`). A later stream
  for that uuid starts a fresh entry, fires `OnLayerReceived` again and issues
  a second copy of the same layer while the first may still run. The session
  is *not* fooled about settlement — `in_flight_` holds `done_` off until both
  copies return (`:412-416`) — but the two callbacks bring
  `num_completed_layers_` to `num_layers()` (`:725-731`) with another layer's
  copy still pending, and a failing duplicate copy fails the whole receive,
  because `FinishLocked` records the first error even when already draining
  (`:359-363`) (`Transport.trace_dup_after_retirement`,
  `trace_dup_copy_fails_late`). A redundant DMA and a spurious failure, not a
  wrong publication.
- In both cases the duplicate stream's payload read (`:604`) rewrites the
  layer's host staging while the first H2D copy of that layer may still be
  reading it; harmless only if the duplicate carries the same bytes.
- With honest senders (at most the declared streams per layer, for the life of
  the receive) none of this is reachable on either contract:
  `Transport.reachable_safe` (`OnceDispatched`, `NetworkSound`,
  `CompleteOnSuccess`), for any positive layer, sender, stream and block
  counts. The model rests on two further assumptions it names but does not
  prove (`Transport` A2, A3): the contract a layer runs under is latched by
  its first stream (`:661-683`), and the receiver seats the session before it
  publishes the plan (`kv_cache_manager_with_transfer.cc:549-567` vs
  `:596-599`), so a push landing in that window would latch chunk-count on a
  sender-declared plan; and the sender-declared contract counts distinct
  `remote_id = node_id()` (`:1168`) against `shard_push_schedules`, which are
  keyed by source shard, so it presumes one source shard per node.

Still not reachable from the in-repo callers for the reason above (fresh uuid
per send, no retry into an armed receiver), and no in-repo sender path opens
more streams than it declares (`header.reserved`), so this stays an **API
hazard** rather than a numbered finding. Two local changes close it without
touching honest behaviour — reject `completed_chunks > num_streams` in the
chunk-count branch, mirroring the other two, and keep a per-layer once-latch in
`ExecuteLayerH2d` (`Transport.stepHardened`: bounded searches find no
violation, honest traces unchanged). Worth doing if the transport is ever
exposed to a sender it does not control.

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
hash; eviction skips pinned entries (`host_offload_backend.cc:607, 745`,
`lru_cache.h:258-294`).

### R-F. Fetch-source (production remote load) unpins before the pull finishes: REFUTED (read)

It matches and pins atomically (`pin_found = true`,
`kv_cache_store_service.cc:444-456`); the pins are released by a scope cleanup
after `transfer_future.Await()` returns (`:473`, `:525`).

### Open / not yet checked

- `KVCacheStoreClient::Fetch` sets no RPC deadline
  (`kv_cache_store_client.cc:61-125`). If the RPC fails with a transport error
  while the source's workers are still writing, `LoadRemoteBlocks` frees
  `dst_host_block_ids` immediately (`host_offload_backend.cc:1114-1125`). Same
  shape as F2 but in the production path. Whether in-flight source DMA can
  outlive a failed Fetch RPC depends on worker and transport teardown, not
  established. **PLAUSIBLE.**
- ReadRemote hooks capture a raw `this`, and `ClearReadRemoteHooks` is not
  called in `~KVCacheStore`. The controller is owned by the store and is
  destroyed first among the members that matter, so this is probably safe.
  Not verified.

## Observations on the prefill-to-decode path (non-bugs at `0ac16d1`)

Behaviours that looked like defects during the prefill-to-decode model work and
turned out to be intended, dead, or proved unreachable. Kept here so they are not
re-investigated; the Lean names in the last column are the proofs. Short names
as in the Lean preambles: `recv.cc` = `tpu_sync/kv_cache/transfer_receive_session.cc`,
`send.cc` = `tpu_sync/kv_cache/transfer_send_session.cc`,
`mgr.cc` = `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`,
`bt.cc` = `tpu_sync/transport/block_transport.cc`.

| Observation | Where (`0ac16d1`) | Note |
|---|---|---|
| client-side `SendAck` has no non-test caller; the server-side `OnAck → HandleAck → AckSend → Finish()` handler is wired but never triggered in-repo | `grpc_control_plane_backend.cc:373`, `tcp_control_plane_backend.cc:662`; `mgr.cc:1181-1183, 1358-1361, 1424-1435` | dead path; excluded (`Send` A5) |
| a failed **send** is reported in `failed_recving_` | `mgr.cc:969-970` | naming/semantics quirk visible through `poll_stats()` |
| first `Finish` wins on the send side; a later cancel is ignored | `send.cc:193-206` | intended; `trace_cancel_after_ok_finish` |
| `IsReadyToComplete` can be true before all H2D callbacks ran | `recv.cc:450-456` | `done` still waits for every callback through `in_flight_` (`pollReady_no_settle`), so the outcome and its timing are unchanged. But when the poll wins that window the last callback finds `draining_` and skips `RecordTransferDuration`/`RecordH2dComplete`/`RecordEnd` (`recv.cc:726-732, 746-756`) — the transfer's metrics record keeps default times (`trace_poll_skips_metrics`). With `num_layers() > 0` the `num_completed_layers_ == total_layers` disjunct and the `if (all_complete)` finish in `OnBlockShardsReceived` (`RecordNetworkCompleteLocked`) are dead (`reachable_callbackFinishes`, `netAccount_frame`); only a zero-layer receive needs the poll (`noPoll_zero_layers_never_succeeds`). Removing the poll (design alternative `stepM false` in `ReceivePoll.lean`) keeps every proved property and settlement (`noPoll_safe`, `noPoll_can_settle`) and makes `published = some true → metrics` an invariant (`noPoll_metrics_on_success`). |
| `EndSendOpLocked` has no underflow guard, `EndRecvOpLocked` does | `send.cc:253-260` vs `recv.cc:407-410` | underflow proved unreachable (`NoUnderflow`) |
| `LOG(DFATAL) "H2D callback for retired receive"` is unreachable | `recv.cc:718-720` | proved (`NoRetiredCallback`) |
| `done_` is redundant in six lifecycle guards | `recv.cc:365, 412, 605, 649, 675`, `recv.h:119` (send side: `send.cc:195, 255, 326, 340, 391`) | `done → draining` and `done → in_flight_ == 0` are `Lifecycle.Consistent`, which every model keeps in its invariant (`Inv.life`); the guards without `done_` are the same functions on consistent states (`finishLocked'_eq`, `endOpLocked'_eq`, `beginOp'_eq`, `Consistent.done_or_draining`). Defensive code, not a bug. The two `LOG(DFATAL)` branches (`recv.cc:407-410`, `718-720`) are assertions — unreachable by `Accounted` / `NoRetiredCallback` — and stay. `Session.lean` |
| a failed incoming push reaches the session as a flat `InternalError("Incoming push failed")` | `bt.cc:509-516` → `mgr.cc:267-270` | the actual cause (read timeout, size mismatch, `OnLayerReceived` error) is only in the transport log, so `failed_recving` cannot tell them apart. Observability, not correctness; the model does not distinguish error statuses. |
| `TransferSendSession::EndSendOp` drops `mu_` inside the last op of a draining send under `TPU_RAIDEN_DATA_CONN_REUSE=per_transfer` | `send.cc:262-289` (window `:284-287`) | closes idle data connections before `EndSendOpLocked`; `in_flight_ == 1`, `draining_`, `!done_` are fixed across the window (no new op, `FinishLocked` returns early, the poll sees `Done() == false`), so the model's atomic `endOp` is exact and only `done_` is delayed. Default `pooled` never enters the branch. `Send.lean` A7. |
| the chunk-count completion contract has no over-count rejection; retirement erases the `OnLayerReceived` once-latch while the receive is live | `bt.cc:739-741` vs `:704-708, 732-736`; `:764-778`; `recv.cc:642-700` | sound for honest senders (`Transport.reachable_safe`); what one extra stream does, the two unproved assumptions (plan-publication window `mgr.cc:567-598`, `remote_id` vs `shard_push_schedules` identity) and a candidate hardening are under R-B above. `Transport.lean` |

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
  upstream** by `72255dd` (2026-10-07; PR #1105 merged via copybara, three new tests);
  its hunk dropped from `candidate_fixes.patch`. F1, F2, F3, F5 unchanged
  (`kv_cache_store.cc` F1 regions moved +6 since `50b0774`; `ReadRemote` region of
  `raiden_controller.cc` moved +35, byte-identical; `StartRead` admission and
  the allocator untouched, `DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`
  still disabled). Sessions and manager moved to `tpu_sync/kv_cache/`
  (`5afe1ef`); `per_peer_staging_admission.patch` re-based onto the new paths,
  all three patches apply cleanly. Tests not re-run.
- 2026-10-13: F6 added (pool-reshard receiver: a rejected duplicate
  `PoolReshardRegisterRecv` destroys a session whose destructor releases the
  active session's `uuid`-keyed staging lease), read-confirmed at `1fa06d1`
  and reproduced by the reporter; filed upstream, fix with regression tests
  to follow. Upstream `main` checked 10 commits past `1fa06d1`: no fix yet;
  `fc8cff9` moves `StagingBlockAllocator` to `tpu_sync/core/staging_arena.h`
  (re-pin note for the next sync).
- 2026-10-16: upstream `0ac16d1` (48 commits past `1fa06d1`). **F6 fixed
  upstream** by `8653373` (2026-10-13, three regression tests). F1, F2, F3
  unchanged (`raiden_controller.cc` and the `kv_cache_store.cc` F1 regions
  untouched). F5 still open (`DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`
  at `control_test.cc:1103-1151`, still disabled); `StagingBlockAllocator`
  moved to `tpu_sync/core/staging_arena.{h,cc}` (`fc8cff9`), so
  `per_peer_staging_admission.patch` no longer applies and was retired rather
  than re-based (decision: keep the proof and the write-up). `NotifyForRead`
  now throws on an invalid registration instead of returning 0 (`80e2c52`);
  `TransferDetails` reports the failed phase (`5a73483`). Two patches remain
  and apply cleanly. Tests not re-run.
- 2026-10-19: F7 added (pool-reshard receiver: the `end_incoming_push` hook
  does not `Finish(status)` a `ReshardReceiveSession` on a failed push, so
  staging lease and plan claim stay pinned until the deadline sweep; R1 of
  `docs/transfer/reshard.md`). Filed upstream 2026-10-16 and **fixed upstream**
  by `fdeebcd` (2026-10-16, one regression test). Upstream `main` is at
  `2a97685` (5 commits past `0ac16d1`); not yet merged into the fork, so
  line numbers in this file stay pinned to `0ac16d1`. Separately, four
  hardware-free reproducers for the reshard registry/coordinator candidates
  R7a, R7b, R8 and R2b were written and pass (`reshard_bughunt_test.cc`,
  target in `build_targets.patch`); they remain tracked in `reshard.md` until
  filed.
- 2026-10-19 (later): **F1 filed upstream** (write-up as bug 4 in
  `filed_bugs.md`, pinned to `0ac16d1`); `ValidateAndPinHostBlocks` region
  verified unchanged at `0ac16d1` (`kv_cache_store.cc:1615-1642`). Fix pending.
- 2026-10-19 (later): **F8 filed upstream** (R2b: `ExecutePoolReshard`
  sender-dispatch return omits `AbandonClaim`; write-up as bug 5 in
  `filed_bugs.md`, pinned to `0ac16d1`; reproducer
  `ReshardBughuntTest.R2b_…` in `reshard_bughunt_test.cc`). Fix pending.
- 2026-10-19 (later): **F9 filed upstream** (R8: `LookupAndClaim` refreshes
  the claim TTL but not the claimed `request_blocks_` rows; write-up as bug 6
  in `filed_bugs.md`, pinned to `0ac16d1`; reproducer `ReshardBughuntTest.R8_…`).
  Fix pending. Remaining unfiled reshard candidates with reproducers: R7b, R7a.
- 2026-10-20: **F2 shape B confirmed by a C++ test**
  (`BugHuntTest.ReadRemoteSettlesDeadlineWhilePullStillInFlight`, added to
  `raiden_controller_bughunt_test.cc`; a `SlowReadMock` makes the worker's
  read outlive the 1 s deadline). Both F2 tests run against upstream `main`
  `449b591` (2026-10-20; 15 commits past `0ac16d1`): controller sources
  (`raiden_controller.cc`, `controller_service.cc`, `worker_service_impl.cc`,
  …, `logical_block_manager.cc`) compiled from `449b591`, everything else
  linked from the `0ac16d1` OSS build. `ReadRemote` / `PullAndRelease` are
  byte-identical between `0ac16d1` and `449b591` (the only controller change
  is a `num_free_blocks()` accessor, `9ac3d3e`). F1, F3 regions also
  unchanged at `449b591`.
- 2026-10-20 (later): **F10 added** (R6: `ReshardSendSession::RecordPushCompletion`
  unregisters the plan on the first failed push while siblings are in flight;
  a same-uuid retry then shares, and loses, the uuid-keyed staging lease — the
  F6 shape on the sender). Confirmed by
  `reshard_send_session_bughunt_test.cc` using upstream's
  `ReshardSendSessionTestPeer` seam, against the `1fa06d1` warm build (the
  only OSS outputs on this machine; the involved code is unchanged through
  `449b591`). Correction to the 2026-10-20 F2 entry above: the "leaf
  libraries" used for the F2 run are from that same `1fa06d1` build, not
  `0ac16d1`; the controller sources were compiled from `449b591` as stated.
  Not yet filed.
