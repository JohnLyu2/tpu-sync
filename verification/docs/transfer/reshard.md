# Pool-reshard transfer: plan, model and results

Verification plan and living results document for the pool-addressed resharding
transfer path under `TpuSyncVerify/Transfer/Reshard/`, sibling to
[prefill_decode.md](prefill_decode.md). Citations in the Lean files and in this
document are to tpu-sync **`0ac16d1`**.

> **Living plan — amendable throughout implementation.** The stage breakdown,
> module boundaries, state fields, and theorem statements below record the design
> going into Stage 1. They are expected to be revised as each stage's Lean
> proofs and C++ trace replays expose which intermediate states are
> load-bearing, which events can be folded without losing bugs, and which
> candidate hazards reproduce in C++. As modules land, the planned rows below are
> replaced in place by the proved theorems and correspondence tables.

## Scope and relationship to `PrefillDecode/`

`Transfer/PrefillDecode/` is unchanged. Both tracks share `Common/` (`System`,
`ModelCheck`, `ListAux`) and `Transfer/Session.lean` (`Lifecycle`, whose
`finishLocked` / `endOpLocked` / `beginOp` already transcribe
`ReshardReceiveSession::FinishLocked`, `EndRecvOpLocked`, and `TryBeginRecvOp`
at `tpu_sync/kv_cache/reshard_receive_session.cc:472-510`). All reshard models live
under `TpuSyncVerify/Transfer/Reshard/` in namespace
`TpuSyncVerify.Transfer.Reshard`.

What is qualitatively new relative to prefill-to-decode:

1. **Rank-ordered pool H2D waves on aliased device pages**
   (`ReshardReceiveSession`, `reshard_receive_session.{h,cc}`): pools carry a
   `rank` (e.g. full-attention at rank 0, state classes at rank 1 on shared
   hybrid-model arena pages, `.h:184-188`), and a pool's H2D copy may launch
   only after every expected pool of strictly lower rank has *completed* its H2D
   callback (`CollectEligiblePoolH2dsLocked`, `.cc:554-583`), even when
   higher-rank pools finish arriving over the network first.
2. **Multi-sender fan-in and per-(pool, peer) push slots**
   (`ReshardSendSession`, `reshard_send_session.{h,cc}`;
   `CountPoolReshardSendSlots`, `pool_reshard_send_slots.{h,cc}`;
   `BlockTransport::HandleIncomingPush` plan-declared progress,
   `block_transport.cc:640-793`): `N` senders push disjoint sub-block slices into
   one receiver pool; the transport counts completed streams per `(uuid, pool)`
   against `expected_pushes` before firing `OnPoolReceived(pool_idx)` once
   (`block_transport.cc:787`).
3. **Two-phase Arm-then-Dispatch coordination and block registry claims**
   (`ReshardCoordinator`, `reshard_coordinator.{h,cc}`; `RequestBlockRegistry`,
   `request_block_registry.{h,cc}`): the source controller claims producer
   blocks, arms every destination receiver (`PoolReshardRegisterRecv`) and
   collects their pool host addresses before dispatching any sender
   (`PoolReshardPush`), and retires producer blocks only when every source unit
   votes `Complete`.
4. **Bounded per-UUID pool host-staging leases** (`PoolStagingStorage`,
   `kv_cache_manager_base.cc:2075-2162, 3250-3303`): both sessions lease bounded
   staging slots per `(storage_idx, uuid)` up front and release them by `uuid`
   on settle or destruction.

## Ultimate theorem goals

1. **Resharded publication & aliased-page safety (`PublicationCorrect`,
   `RankWaveOrder`, `attention_safe`).** When `poll_stats()` publishes
   `done_recving` for a reshard request, every transferred pool's H2D copy has
   completed in non-decreasing `rank` order after all `expected_pushes` streams
   for that pool landed, so on aliased device pages higher-rank pool bytes
   Deterministically overwrite lower-rank padding regardless of network arrival
   order, and no in-flight H2D copy or late callback can write to destination
   HBM afterwards.
2. **Progress, drain-to-settle & resource cleanup (`NoOpLeak`,
   `reachable_can_settle`, `StagingIntegrity`, `PlanUnregistered`).** From any
   reachable state (normal completion, H2D failure, push failure, or external
   cancel/deadline), every in-flight op has an enabled drain step and the
   session settles in finitely many steps, releasing its `PoolStagingLease` and
   unregistering its active transfer plan at most once.
3. **Multi-party coordination & registry claim safety (`NoUnarmedPush`,
   `ClaimSafety`).** Under the coordinator protocol, no sender pushes to an
   unarmed receiver; registered producer blocks are neither overwritten nor
   retired while claimed by an in-flight reshard plan.

## Staged roadmap (amendable)

| Stage | Module(s) | Scope | Target theorems & checks |
|---|---|---|---|
| **1 (proved)** | `Reshard/Receive.lean`, `Reshard/Send.lean` | Single `ReshardReceiveSession` (rank-gated `ExecuteEligiblePoolH2ds`, batch `in_flight_ += to_launch.size()`, `reshard_finalizing_`, `FinishPoolH2d`, `IsReadyToComplete` poll audit, `PushEndPolicy` `shipping` vs. `finishOnError`) and single `ReshardSendSession` (`ExecutePush` per-pool D2H, `StartPoolPush` per-peer `AsyncPush`, `CountPoolReshardSendSlots` / `remaining_pool_peer_pushes_`, `UnregisterPolicy` `shipping` vs. `onSettle`) on top of `Session.Lifecycle`. | `Recv.reachable_safe` (`SettleSafe`, `NoRetiredCallback`, `StagingIntegrity`, `PlanIntegrity`, `SettlesPromptly`, `RankWaveOrder`, `ReadinessSound`, `Publication`, `NoOpLeak`), `Recv.rankWaveOrder_iff`, `Recv.reachable_pollReady_disabled`, `Recv.reachable_can_settle`; `Send.reachable_safe` (`SettleSafe`, `NoRetiredCallback`, `StagingIntegrity`, `SettlesPromptly`, `ActiveOrDraining`, `PlanIntegrity`, `Publication`, `NoOpLeak`), `Send.reachable_onSettle_plan_iff_done`, `Send.reachable_can_settle`; 10 `decide` traces + `#guard` + 6 mutants. |
| **2 (proved)** | `Reshard/Pipeline.lean` | Composed reshard pipeline: `Send` + `Recv` + per-pool transport stream counters (`sentStreams`, `landedStreams`, `landedStreams p = peerCounts p → onPoolReceived p`) + five explicit memories (`srcHbm`, `srcStaging`, `wire`, `dstStaging`, `dstHbm`) + aliased-page overwrite (`writePoolHbm` / `clobberHigherRanks`) + Arm-then-Dispatch barrier (`armed`, `init` vs. `initUnarmed`). | `Pipeline.reachable_safe` and `Pipeline.reachable_unarmed_safe` (`PublicationCorrect`, `AliasedPageCorrect`, `DstHbmSafe`, `SrcHbmSafe`, `StagingSafe`, `StreamAccountingSafe`, `NoUnarmedPush`, `NoOpLeak`); quietness (`dstHbm_quiet`, `srcHbm_quiet`, `srcStaging_quiet`, `dstStaging_quiet`) and temporal post-publication safety (`attention_safe`); progress (`reachable_can_settle`, `reachable_unarmed_can_settle`); 2 `decide` traces + `#guard` + 3 mutants. |
| **3 (proved)** | `Reshard/Coverage.lean`, `Reshard/PoolStaging.lean` | Horizontal data-plane refinements: (a) sender stream count (`Σ_senders min(parallelism, |pairs|)`) equals receiver `expected_pushes` (`pool_reshard_planner.cc:1134-1142`, `reshard_receive_session.cc:319-323`), `DefaultTransferStreams` (`pool_reshard_planner.cc:576-594, 908-922`), and `ValidateReceiverCoverage` interval partition implies full sub-block reconstruction (`CoveragePipeline.step_pipe` simulation over `Pipeline`); (b) `PoolStagingStorage` per-`(storage, uuid)` slot conservation, idempotent re-acquire, cross-UUID disjointness, and three-phase registration lease-collision hazard (R5 / F6: `.reserveBeforeLease` shipping vs. `.leaseBeforeReserve` mutant). | `Coverage.stream_count_matches`, `Coverage.senderStreams_pos_iff`, `Coverage.partition_reconstructs_block`, `Coverage.partition_reconstructs_perm`, `CoveragePipeline.reachable_safe`; `PoolStaging.acquireLease_idempotent`, `PoolStaging.no_slot_aliasing_between_distinct_uuids`, `PoolStaging.trace_r5_duplicate_uuid_frees_survivor_lease_and_aliases_slot`, `PoolStaging.reachable_reserveBeforeLease_safe`, `PoolStaging.trace_pool_staging_recv_registration_tests`; 13 `decide` traces + 5 mutants. |
| **4 (proved)** | `Reshard/Registry.lean`, `Reshard/Coordinator.lean` | Control-plane state machines: `RequestBlockRegistry` (`Register`, multi-owner `LookupAndClaim`, `AbandonClaim`, `Complete` full-set voting, `CancelIfUnclaimed` tombstone, TTL expiration, Observations R7 & R8) and `ReshardCoordinator::ExecutePoolReshard` multi-destination arm-before-dispatch (`reshard_coordinator.cc:415-592`, `CleanupPolicy.shipping` vs. `disarmAndAbandonOnFailure`). | `Registry.reachable_safe` (`ClaimOwnersConsistent`, `TombstoneClean`, `RetiredClean`, `PartialVotesNotAllVoted`), `Registry.tombstone_blocks_register_and_claim`, `Registry.claimed_blocks_register_and_cancel`, `Registry.abandonClaim_preserves_when_other_owner_present`, `Registry.complete_retires_iff_all_claimed_voted`, `Registry.purgeExpiredAll_inv`, `Registry.trace_r7_single_stage_votes_retire_multi_owner_claim`, `Registry.trace_r8_split_ttl_purges_request_blocks_while_claim_active`; `Coordinator.reachable_coord_inv`, `Coordinator.no_push_before_all_armed`, `Coordinator.claimed_while_arming`, `Coordinator.reachable_disarmAndAbandon_no_orphans`, `Coordinator.trace_r2a_partial_arm_orphans_armed_receiver`, `Coordinator.trace_r2b_dispatch_failure_orphans_receivers_and_claim`; 13 `decide` / `rfl` traces + 3 mutants. |

### Stated preconditions and out-of-scope components

* **Disjoint source and destination units (`src_units ∩ dst_units = ∅`).**
  `BuildStartTransferForTarget` (`reshard_coordinator.cc:110-127`) marks a unit in
  both lists with `is_sender = true`, which `WorkerServiceImpl` dispatches only
  to `PoolReshardPush` (`worker_service_impl.cc:544-554`). We treat disjointness
  as a caller/planner precondition rather than modelling dual-role units.
* **Planner geometry & transfer-program lowering (out of scope).**
  `tpu_sync/kv_cache/reshard/pool_reshard_planner.cc` (1,241 LOC, differential-tested against Python in
  `reshard_service_test.cc`) and `tpu_sync/core/transfer_program_reshard.cc` (338 LOC,
  bijection-tested in `transfer_program_reshard_test.cc`) are pure compilers into
  `StartTransferRequest`; Stage 3 models their output contract
  (`ValidatePlan` / `ValidateReceiverCoverage` / `CountPoolReshardSendSlots` /
  `DefaultTransferStreams`), not the planner arithmetic itself.
* **`weight_sync/` reshard planner (out of scope).** Separate subsystem for
  model weights, unrelated to KV-cache session transfer.

## Stage 1 results: `Receive.lean` and `Send.lean`

### `TpuSyncVerify/Transfer/Reshard/Receive.lean` (`ReshardReceiveSession`)

Models `tpu_sync/kv_cache/reshard_receive_session.{h,cc}` together with the reshard
branches of `KVCacheManagerWithTransfer` (`kv_cache_manager_with_transfer.cc:180-290,
673-782, 1037-1066`), parameterized by a `ranks : List Nat` pool schedule and
`PushEndPolicy` (`shipping` vs. `finishOnError`).

* **Rank-wave invariant (`RankWaveOrder` and `rankWaveOrder_iff`).** Every pool
  starts at `PoolStage.waiting`, transitions to `received` when
  `OnPoolReceived(pool_idx)` fires, is admitted to `queued` by
  `CollectEligiblePoolH2dsLocked` (`.cc:554-583`) only when every pool with
  strictly lower `rank` is already `completed`, transitions to `issued` when its
  slice of `ExecuteEligiblePoolH2ds` issues `H2dPoolBlocks` (`.cc:614-666`), and
  reaches `completed` in `FinishPoolH2d` (`.cc:668-706`). `RankWaveOrder` proves
  that no pool is in `queued`, `issued`, `ready`, or `completed` while any
  lower-rank pool is not yet `completed` (`rankWaveOrder_iff` states this in
  universal form across pool indices).
* **Batch H2D launch and `in_flight_` accounting (`Accounted`).**
  `CollectEligiblePoolH2dsLocked` increments `in_flight_ += to_launch.size()` in
  one critical section before `ExecuteEligiblePoolH2ds` iterates over the batch
  outside `mu_`. If external cancellation or an earlier pool's H2D failure sets
  `draining_ = true` mid-batch, each remaining queued pool takes the early exit
  at `.cc:633-638` (`h2dIssue p false`) and calls `EndRecvOpLocked()`, preserving
  `inFlight = pushes + poolOps pools`.
* **Deferred plan unregistration (`PlanIntegrity`).** `unregister_on_settle_` is
  initialized to `true` (`.h:179`), and `MaybeUnregisterSettledReshardRecv`
  (`mgr.cc:776-782`) claims `TakePendingUnregister` (`.cc:512-520`) only after
  `Done()` holds (`.cc:478-481, 501-504, 644-646, 661-663`), so `planUnregistered = true →
  done = true` holds in all reachable states.
* **Poll-finish audit (`reachable_pollReady_disabled`, R3).** Because
  `FinishPoolH2d` sets `network_completed_ = true` (`.cc:697`) immediately before
  calling `Finish` (`.cc:700`) under the same last-H2D transition and
  `ValidateCommonPoolReshardPlan` forbids zero transferred pools (`utils.h:367-370`,
  called at `.cc:71`), `pollReady` (`IsReadyToComplete() && !IsDraining()`,
  `mgr.cc:1041-1046`) is disabled in every reachable state (`step pol s .pollReady = none`),
  and end-of-transfer metrics (`durationRecorded`) are latched on success.
* **Traces and mutants.** Six `decide` traces (`trace_rank1_arrives_before_rank0`,
  `trace_batch_launch_on_rank_wave`, `trace_cancel_between_batch_queue_and_issue`,
  `trace_reshard_receive_session_test_parity` for
  `reshard_receive_session_test.cc:137-198, 405-439`,
  `trace_duration_metric_on_success_and_failure` for
  `kv_cache_manager_with_transfer_pool_reshard_test.cc:327-367`, and
  `trace_r1_failed_incoming_push`), `#guard` bounded searches under both
  `PushEndPolicy` modes, and three mutants (`onPoolReceivedIgnoringRank`,
  `h2dIssueLeak`, `cancelUnregisterEarly`).

### `TpuSyncVerify/Transfer/Reshard/Send.lean` (`ReshardSendSession`)

Models `tpu_sync/kv_cache/reshard_send_session.{h,cc}`,
`tpu_sync/core/pool_reshard_send_slots.{h,cc}`, and the sender hooks in
`kv_cache_manager_with_transfer.cc:634-671, 981-1000`, parameterized by per-pool
peer counts `peerCounts : List Nat` and `UnregisterPolicy` (`shipping` vs.
`onSettle`).

* **`Session.Lifecycle` reuse.** `(in_flight_, finalizing_, done_, status_.ok(),
  !leases_released_)` is an exact instance of `Transfer.Lifecycle` (`IsDraining()`
  returns `finalizing_` at `reshard_send_session.h:81-84`), reusing `Lifecycle.Consistent` directly.
  Assumption A4 folds the per-transfer idle connection-release window in `EndOp`
  (`reshard_send_session.cc:449-467`, under `DataConnectionReuse::kPerTransfer`) into `endOp`.
* **Slot-counting invariant (`CountPoolReshardSendSlots`, `ActiveOrDraining`,
  `Publication`).** Each active pool starts with `remainingSlots = peers > 0`,
  and `remaining_pool_peer_pushes_` equals `∑_p p.remainingSlots` while
  `!finalizing_`. Because `ExecutePush` holds its own caller op (`execActive`)
  until every pool has issued its D2H copy (`allIssued`), `draining = false`
  implies `0 < inFlight` (`ActiveOrDraining`: the session never drops to
  `in_flight_ == 0` before `finalizing_` is latched). When the last peer push
  succeeds (`remainingPushes ≤ 1`), `sumRemainingSlots = 0` with `noAborted`,
  proving `allPushed pools = true` before `done_sending` can be published.
* **Dual `UnregisterActivePlan` (`UnregisterPolicy.shipping` vs. `onSettle`).**
  `RecordPushCompletion` (`reshard_send_session.cc:360-384`) unregisters the active plan as soon as
  `finalizing_` is latched, whereas `EndOp()` (`reshard_send_session.cc:428-440`) unregisters on
  settle (`in_flight_ == 1 && finalizing_`). Both policies satisfy
  `done = true → planUnregistered = true` (`PlanIntegrity`); under `onSettle`,
  `planUnregistered = s.life.done` (`reachable_onSettle_plan_iff_done`), whereas
  under `shipping`, a partial failure unregisters the plan while sibling pools
  are still in flight (`trace_early_unregister_on_error_vs_onSettle`).
* **Traces and mutants.** Four `decide` traces
  (`trace_reshard_send_session_test_parity` for
  `reshard_send_session_test.cc:151-277` and
  `kv_cache_manager_with_transfer_pool_reshard_test.cc:302-325`,
  `trace_multi_pool_multi_peer_send`, `trace_cancel_unregisters_on_last_endOp`
  for `reshard_send_session_test.cc:364-404`, and
  `trace_early_unregister_on_error_vs_onSettle`, plus a section note on the
  remaining `TPU_RAIDEN_DATA_CONN_REUSE` tests at
  `reshard_send_session_test.cc:322-453`), `#guard` bounded searches under
  both policies, and three mutants (`initOvercountedSlots` reproducing the
  pre-#744 slot overcount at `reshard_send_session.cc:131-133`, `stepWithoutEndOpUnregister`, and
  `d2hDoneLeakOnDraining`).

## Stage 2 results: `Pipeline.lean`

### `TpuSyncVerify/Transfer/Reshard/Pipeline.lean` (composed end-to-end reshard pipeline)

Composes `Reshard.Send`, `Reshard.Receive`, the per-pool `BlockTransport` stream
counter (`tpu_sync/transport/block_transport.cc:640-793`), the coordinator's
two-phase Arm-then-Dispatch barrier (`tpu_sync/kv_cache/reshard/reshard_coordinator.cc:429-544`),
and five explicit pool-indexed memories (`srcHbm`, `srcStaging`, `wire`,
`dstStaging`, `dstHbm`) with aliased-page overwrite semantics
(`tpu_sync/kv_cache/reshard_receive_session.h:184-188`, `kv_cache_manager_base.h:688-691`).

* **End-to-end data & aliased-page correctness (`PublicationCorrect`,
  `AliasedPageCorrect`, `reachable_safe`, `reachable_unarmed_safe`).** When pool
  `p` completes its H2D copy (`h2dDone p true`), `writePoolHbm` writes
  `dstStaging[p]` to `dstHbm[p]` and clobbers every pool slot `q` with
  `pool_q.rank > pool_p.rank` to `.junk` (`clobberHigherRanks`), modelling
  lower-rank full-attention H2D waves overwriting padding across aliased device
  pages. The inductive invariant `Inv.done_intact` uses `Recv.rankWaveOrder_iff`
  to show that no pool `p` in `.ready` can have `pool_p.rank < pool_q.rank` for an
  already-`.completed` pool `q`, so completed higher-rank slots are never
  clobbered. When `recv.published = some true` (`done_recving`),
  `dstHbm = good numPools` (`[kv 0, …, kv (numPools - 1)]`).
* **Quietness & temporal post-publication safety (`dstHbm_quiet`, `srcHbm_quiet`,
  `srcStaging_quiet`, `dstStaging_quiet`, `attention_safe`).** Once `done_recving`
  is published, no subsequent pipeline event — including `reclaim` (source HBM
  retirement), `reseatSrcStaging` / `reseatDstStaging` (`PoolStagingLease` reuse),
  and late drain or cancellation steps — can modify `dstHbm` or `recv.published`
  (`attention_safe`). Dually, `srcHbm_quiet` proves producer HBM is untouched
  while `send.published = none`, and `srcStaging_quiet` / `dstStaging_quiet`
  prove released `PoolStagingLease` buffers are never read or written by the
  retired session.
* **Two-phase Arm-then-Dispatch (`NoUnarmedPush`, `initUnarmed`, `armRecv`).**
  Starting from `initUnarmed` (`armed = false`), no sender pool can enter `.d2h`
  or `.pushing`, no stream can land (`landedStreams[p] = 0`), and no receiver
  pool can leave `.waiting` until `armRecv` (`PoolReshardRegisterRecv`) completes.
* **Progress (`reachable_can_settle`, `reachable_unarmed_can_settle`).** From any
  reachable state, cancelling both sessions and draining via the combined measure
  `drainRank s = s.send.life.inFlight + Recv.drainRank s.recv` settles both
  sessions (`send.life.done = true ∧ recv.life.done = true ∧
  send.life.inFlight = 0 ∧ recv.life.inFlight = 0`).
* **Traces and mutants.** Two `decide` traces
  (`trace_aliased_page_out_of_order_arrival` where rank-1 streams arrive before
  rank-0 on a 2-pool aliased page yet `dstHbm = [kv 0, kv 1]`, and
  `trace_arm_before_dispatch` from `initUnarmed`), `#guard` bounded searches over
  multi-rank / multi-peer schedules, and three mutants
  (`mutant_ignoring_rank_corrupts_aliased_page` where `dstHbm = [kv 0, junk]`,
  `mutant_onPoolReceived_before_all_streams`, and
  `mutant_reclaim_before_publish_corrupts_dstHbm`).

## Stage 3 results: `Coverage.lean` and `PoolStaging.lean`

### `TpuSyncVerify/Transfer/Reshard/Coverage.lean` (sub-block byte coverage & multi-sender stream accounting)

Refines `Reshard.Pipeline` along the data plane (`reshard_receive_session.cc:67-349`,
`pool_reshard_planner.cc:315-572, 576-594, 908-922, 1117-1153`,
`reshard_send_session.cc:204-225, 292-348`,
`pool_reshard_send_slots.cc:23-54`, `block_transport.cc:651-762, 1010-1046`):

* **Multi-sender stream count conservation (`stream_count_matches`,
  `senderStreams_pos_iff`).** Each sender `s` deduplicates its scheduled
  `(src_block_id, dst_block_id)` pairs (`senderPairs`) for a pool group and opens
  `min(parallelism, |pairs_s|)` TCP push streams (`block_transport.cc:1020-1025`,
  `reshard_send_session.cc:293-341`). `ValidateReceiverCoverage`
  (`reshard_receive_session.cc:314-324`) verifies that the receiver's
  `expected_pushes` equals $\sum_s \min(\text{parallelism}, |\text{pairs}_s|)$,
  matching the planner (`pool_reshard_planner.cc:1134-1142`), and a sender with
  zero scheduled pairs opens zero streams (`reshard_send_session.cc:217-224`).
* **Exact sub-block byte reconstruction under out-of-order stream arrival
  (`checkContiguous_covers`, `checkContiguous_head_disjoint`,
  `writeInterval_comm`, `partition_reconstructs_block`,
  `partition_reconstructs_perm`).** `ValidateReceiverCoverage` sorts the logical
  live-byte intervals `[start_bytes, end_bytes)` targeting a destination block and
  checks that they partition `[0, extent)` without gaps or overlaps
  (`reshard_receive_session.cc:325-346`). We prove that any interval list accepted
  by `validBlockCoverage` is pairwise disjoint and covers every byte `b < extent`,
  so landing the intervals in *any* network permutation reconstructs `good extent`
  (`[kv 0, …, kv (extent - 1)]`).
* **Refinement coupling (`CoveragePipeline.step_pipe`,
  `CoveragePipeline.reachable_safe`).** `CoveragePipeline` refines
  `Reshard.Pipeline` by replacing each pool's scalar stream counter with a queue
  of sub-block intervals and a byte-addressed staging buffer. Every
  `CoveragePipeline` step projects to a `Pipeline.step`, lifting all Stage 2
  pipeline invariants together with byte-level destination reconstruction (`good
  extent` on every pool's staging buffer and `good numPools` on `dstHbm`).
* **Traces and mutants.** Six `decide` traces (`trace_tp4_to_tp2_subblock_merge`,
  `trace_multi_sender_stream_count`, `trace_coverage_pipeline_end_to_end`,
  `trace_reshard_receive_coverage_test_parity` for
  `reshard_receive_session_test.cc:227-403`,
  `trace_expected_push_senders_test_parity` for
  `kv_cache_manager_with_transfer_pool_reshard_test.cc:222-269`, and
  `trace_default_transfer_streams_test_parity` for
  `pool_reshard_planner_streams_test.cc:59-103` and
  `reshard_service_test.cc:1818-1896`) and three
  mutants (`mutant_gap_in_coverage_leaves_unwritten_byte`,
  `mutant_overlap_in_coverage_rejected`,
  `mutant_mismatched_expected_pushes_rejected`).

### `TpuSyncVerify/Transfer/Reshard/PoolStaging.lean` (bounded `PoolStagingStorage` & per-UUID lease lifecycle)

Models `KVCacheManagerBase::PoolStagingStorage`
(`tpu_sync/kv_cache/kv_cache_manager_base.h:984-996`,
`tpu_sync/kv_cache/kv_cache_manager_base.cc:1963-2162`) and the receive
registration lifecycle in `PoolReshardRegisterRecv`
(`tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc:673-709`,
`tpu_sync/kv_cache/reshard_receive_session.cc:373-390, 420-470`):

* **Idempotent per-UUID lease acquisition (`acquireLease_idempotent`,
  `acquireLease_resolves_all`).** Re-acquiring a subset of already-leased block
  IDs for the same `uuid` is a no-op (`kv_cache_manager_base.cc:2108-2113`), so
  multiple pools sharing a physical storage (`storage_index`) share one page lease
  without double-consuming arena slots, and any successful `acquireLease` maps
  every requested block ID to an allocated slot.
* **Slot conservation & cross-UUID disjointness (`allocateMissing_slot_sum`,
  `init_inv`, `no_slot_aliasing_between_distinct_uuids`,
  `acquireLease_preserves_other_resolve`,
  `releaseLease_preserves_other_resolve`).** In any well-formed arena
  (`ArenaInv`), distinct UUIDs `u₁ ≠ u₂` hold disjoint slot lists and never
  resolve any block IDs to the same physical staging slot.
* **Receive registration lifecycle & Risk R5 / Finding F6
  (`RegistrationPolicy.reserveBeforeLease` vs. `.leaseBeforeReserve`,
  `trace_r5_duplicate_uuid_frees_survivor_lease_and_aliases_slot`,
  `reachable_reserveBeforeLease_safe`).** Proves both the inductive safety
  theorem `reachable_reserveBeforeLease_safe` for the shipping
  `RegistrationPolicy.reserveBeforeLease` order (`reshard_receive_session.cc:376-388`,
  where `ReshardReceiveSession::Create` claims `uuid` via
  `RegisterActivePlanDirect` before constructing the session and acquiring
  staging, guaranteeing `ActiveSessionsHoldLeases` in every reachable state) and
  the constructive R5 counterexample under `.leaseBeforeReserve` (the pre-`8653373`
  order where a rejected duplicate-UUID arm's destructor frees the surviving
  session's lease and a third session `uuid = 8` is allocated the survivor's
  physical slot `0`).
* **Traces and mutants.** Parity `decide` traces replaying all six
  `pool_staging_test.cc` unit tests (`trace_bounded_arena_leases_and_addressing`
  for `pool_staging_test.cc:115-208`,
  `trace_fallback_to_full_mirror_and_stride_mismatch` for `:212-301`,
  `trace_shared_storage_pools_share_lease` for `:252-279`,
  `trace_sender_raddr_and_pool_host_base_addrs` for `:306-521`, and
  `trace_reserveBeforeLease_end_to_end`) plus
  `trace_pool_staging_recv_registration_tests` replaying
  `PoolStagingRecvRegistrationTest`
  (`kv_cache_manager_with_transfer_pool_reshard_test.cc:624-764`) and two mutants
  (`mutant_non_idempotent_acquire_exhausts_shared_storage`,
  `mutant_leaking_release_breaks_conservation_and_starves`).

## Stage 4 results: `Registry.lean` and `Coordinator.lean`

### `TpuSyncVerify/Transfer/Reshard/Registry.lean` (`RequestBlockRegistry` generation lifecycle)

Models `RequestBlockRegistry` (`tpu_sync/kv_cache/reshard/request_block_registry.h:51-155`,
`tpu_sync/kv_cache/reshard/request_block_registry.cc:98-509`), tracking per-unit
producer registrations, multi-owner planning claims (`claimed_owners_`),
per-unit completion voting (`completed_units_`), retirement (`RetireLocked`),
and unclaimed cancellation tombstones (`cancelled_`):

* **Inductive registry invariants (`Inv`, `reachable_safe`).** Across all
  reachable states:
  1. `ClaimOwnersConsistent`: `claimedUnits.isSome ↔ claimOwners ≠ []`, and every
     claimed unit `u ∈ units` is registered in `registeredUnits`.
  2. `TombstoneClean` & `tombstone_blocks_register_and_claim`: when
     `cancelled = true` (`request_block_registry.cc:373-405`),
     `registeredUnits = []`, `claimedUnits = none`, and `claimOwners = []`, and
     any subsequent `register` (`:276-280`) or `lookupAndClaim` (`:448-452`) is
     rejected.
  3. `claimed_blocks_register_and_cancel`: while `claimedUnits = some units`,
     `register` is rejected (`:281-285`) and `cancelIfUnclaimed` is a no-op
     (`:388-390`) that leaves registered blocks and claims intact.
  4. `abandonClaim_preserves_when_other_owner_present`: when two distinct
     pipelined owners `o₁ ≠ o₂` hold claims on the same generation
     (`request_block_registry.h:144-147`), `abandonClaim o₁`
     (`request_block_registry.cc:493-509`) preserves `claimedUnits` and `o₂`'s
     membership in `claimOwners`.
  5. `complete_retires_iff_all_claimed_voted`: when `claimedUnits = some expected`,
     a `complete` step for `unit ∈ expected` retires the generation via
     `RetireLocked` (`:98-116, 358-368`) if and only if every `u ∈ expected` has
     voted in `completedUnits`.
* **Traces, Observations R7 & R8, and mutants.** Eight `decide` traces replaying
  `reshard_service_test.cc` registry tests (`trace_registry_multi_owner_and_voting`,
  `trace_partial_vote_does_not_retire` for `reshard_service_test.cc:1029-1052`,
  `trace_tombstone_blocks_late_register_and_claim` for `:933-961`,
  `trace_request_block_status_probe_lifecycle` for `:963-1027`,
  `trace_pipelined_stages_claim_and_abandon` for `:1278-1361`,
  `trace_ttl_purges_expired_registrations_and_tombstones` for `:1023-1027, 1054-1062`,
  `trace_r7_single_stage_votes_retire_multi_owner_claim`, and
  `trace_r8_split_ttl_purges_request_blocks_while_claim_active`) plus
  `purgeExpiredAll_inv` and two mutants
  (`mutant_premature_complete_retires_while_peer_active`,
  `mutant_unconditional_abandon_exposes_sibling_owner_to_cancel`).

### `TpuSyncVerify/Transfer/Reshard/Coordinator.lean` (two-stage `ReshardCoordinator::ExecutePoolReshard` & Risk R2a/R2b)

Composes `ReshardCoordinator::ExecutePoolReshard`
(`tpu_sync/kv_cache/reshard/reshard_coordinator.h:45-129`,
`tpu_sync/kv_cache/reshard/reshard_coordinator.cc:415-592`) with
`RequestBlockRegistry` (`Registry.lean`) and per-destination-unit receiver
sessions (`kv_cache_listener.cc:138-172`,
`kv_cache_manager_with_transfer.cc:673-709`,
`reshard_receive_session.cc:373-390, 420-470`), parameterized by
`CleanupPolicy` (`shipping` vs. `disarmAndAbandonOnFailure`):

* **Universal protocol guarantees (`CoordInv`, `reachable_coord_inv`,
  `no_push_before_all_armed`, `claimed_while_arming`).** Proves inductively for
  both cleanup policies that:
  1. `Registry.Inv s.reg` holds at every reachable state.
  2. `NoPushBeforeAllArmed` (`reshard_coordinator.cc:457-480`): while the
     coordinator is in `.idle` or `.arming`, no sender is dispatched
     (`sendResults = []`) and no destination unit receives any push.
  3. `AllArmedInDispatching` (`reshard_coordinator.cc:457-475`): entering
     `.dispatching` requires `armFailed = false` and all `dstUnits` reported in
     `armResults`.
  4. `ClaimedWhileArming` (`reshard_coordinator.cc:418-463`): throughout `.arming`,
     `s.reg.claimedUnits = some s.srcUnits` and `s.reg.claimOwners = [s.claimOwner]`,
     so `CancelIfUnclaimed` and duplicate `Register` are blocked.
  5. `LeaseMatchesSession`: every destination unit holds a `PoolStagingLease` if
     and only if its `ReshardReceiveSession` is currently armed.
* **Risk R2a & R2b counterexample traces, `reshard_service_test.cc` parity, and
  hardened cleanup theorem (`trace_r2a_partial_arm_orphans_armed_receiver`,
  `trace_r2b_dispatch_failure_orphans_receivers_and_claim`,
  `trace_coordinator_happy_path`, `trace_arm_failure_abandons_claim_and_skips_senders`,
  `reachable_disarmAndAbandon_no_orphans`).** Replays
  `FullPoolReshardFlowEmitsArmThenDispatch` (`reshard_service_test.cc:677-751`),
  `MissingRegistrationKeepsContractString` (`:903-913`),
  `ArmFailureAbandonsClaimAndSkipsSenders` (`:915-931`), and
  `TwoDestinationsArmEachThenDispatchSendersOnce` (`:1065-1135`), witnesses both
  partial-arm receiver orphaning at `reshard_coordinator.cc:458-463` (R2a) and
  sender-dispatch failure orphaning both receivers and the
  `RequestBlockRegistry` claim at `reshard_coordinator.cc:542-544` (R2b), and
  proves inductively that under `CleanupPolicy.disarmAndAbandonOnFailure`, every
  reachable `.aborted` state has zero armed receiver sessions, zero held staging
  leases, and `s.reg.claimedUnits = none ∧ s.reg.claimOwners = []`.

## Candidate observations and hypotheses under investigation

Tracked here across the Stage 1–4 models; items marked **[HYP]** require a
hardware-free C++ reproduction test before being promoted to `findings/`.

* **R1 [HYP — Stage 1 `Receive.lean`] Failed incoming push on a reshard receiver
  does not finish the session.** In `KVCacheManagerWithTransfer`'s
  `end_incoming_push` hook (`kv_cache_manager_with_transfer.cc:250-290`), the
  `TransferReceiveSession` branch calls `DeferUnregisterOnSettle();
  Finish(status)` when `!status.ok()` (`:267-270`), whereas the
  `ReshardReceiveSession` branch (`:279-289`) only calls `EndRecvOp()`, ignoring
  `status`. Because `ReshardSendSession::RecordPushCompletion` marks the sender
  `finalizing_` on the first failed push without retrying
  (`reshard_send_session.cc:360-367`), the missing stream never arrives and the
  reshard receiver (plus its bounded `PoolStagingLease` and active plan) stays
  pinned until `timeout_s_`. Modeled via `PushEndPolicy` (`shipping` vs.
  `finishOnError`) and witnessed by `trace_r1_failed_incoming_push` in
  `Receive.lean`.
* **R2 [HYP / Code audit — Stage 4 `Coordinator.lean`] Coordinator Stage 1 and
  Stage 2 barrier failures orphan armed receivers and (in Stage 2) leak the
  `RequestBlockRegistry` claim (`R2a` & `R2b`).**
  - **R2a (Stage 1 partial-arm failure, `reshard_coordinator.cc:433-463`):**
    `ReshardCoordinator::ExecutePoolReshard` arms all `dst_units` in parallel
    threads; if `dst_unit 10` succeeds (creating an active `ReshardReceiveSession`
    holding a `PoolStagingLease` and active plan) and `dst_unit 11` fails, the
    coordinator calls `registry_->AbandonClaim` and returns `arm_status` without
    disarming `dst_unit 10` (and no cancel/unregister control-pipe command exists
    in `raiden_service.proto:284-292` or `kv_cache_listener.cc:103-229`), leaving
    `dst_unit 10`'s session and staging lease orphaned until `timeout_s_`.
    Witnessed by `trace_r2a_partial_arm_orphans_armed_receiver` in
    `Coordinator.lean`.
  - **R2b (Stage 2 sender-dispatch failure omits `AbandonClaim` and disarm,
    `reshard_coordinator.cc:481-544`):** When any sender RPC fails during Stage 2
    (`!sender_status.ok()`), `ExecutePoolReshard` returns `sender_status` at
    `reshard_coordinator.cc:542-544` without disarming `dst_units` **and**
    (unlike lines 422, 460, and 484) without calling
    `registry_->AbandonClaim(args.req_id, args.uuid, claim_owner)`. Because
    `Complete` (`reshard_service.cc:291-303`, `request_block_registry.cc:317-371`)
    is only invoked for sender transfers that succeed (`reshard_coordinator.cc:494-544`), both the
    armed `dst_units` remain orphaned until `timeout_s_` and
    `claimed_[(req_id, uuid)]` remains pinned in `RequestBlockRegistry` until
    `ttl_s_` (default 300s, `request_block_registry.cc:72-96`), blocking
    `CancelIfUnclaimed` (`:388-390`) and re-registration (`:281-285`). Witnessed
    by `trace_r2b_dispatch_failure_orphans_receivers_and_claim` and proved
    absent under `CleanupPolicy.disarmAndAbandonOnFailure` by
    `reachable_disarmAndAbandon_no_orphans` in `Coordinator.lean`.
* **R3 [Code audit — Stage 1 `Receive.lean`] `IsReadyToComplete` poll finish on
  `ReshardReceiveSession` is redundant.** Unlike `TransferReceiveSession`,
  `ReshardReceiveSession::FinishPoolH2d` sets `network_completed_ = true` at
  `reshard_receive_session.cc:697` immediately before calling `Finish` at `:700`
  (outside `mu_`), after latching end-of-transfer metrics at `:696`, and
  `ValidateCommonPoolReshardPlan` forbids zero transferred pools
  (`utils.h:367-370`, called at `reshard_receive_session.cc:71`). Thus the poll's
  `IsReadyToComplete()` branch (`kv_cache_manager_with_transfer.cc:1041-1046`)
  is reachable only in the two-line window `reshard_receive_session.cc:697-700`
  and produces the exact same state transition without skipping metrics
  (`reachable_pollReady_disabled` in `Receive.lean`).
* **R4 [Design invariant — Stage 1–2 `Receive.lean` / `Pipeline.lean`]
  Rank-ordered H2D waves protect aliased device pages.** Documented at
  `reshard_receive_session.h:184-188` and `kv_cache_manager_base.h:688-691`;
  verified as `RankWaveOrder` (`rankWaveOrder_iff`) in Stage 1 and
  `AliasedPageCorrect` in Stage 2.
* **R5 [Fixed upstream in `8653373` (Finding F6) — Stage 1/3 `PoolStaging.lean`]
  Per-UUID staging lease key collision across three-phase registration in
  `PoolReshardRegisterRecv`.**
  `PoolStagingStorage` keys leases by `uuid` alone
  (`kv_cache_manager_base.cc:2100, 2151`), and `~ReshardReceiveSession` calls
  `ReleasePoolStagingLeases(uuid_)` (`reshard_receive_session.h:71`). Under the
  pre-`8653373` registration order (`RegistrationPolicy.leaseBeforeReserve`),
  `ReshardReceiveSession::Create` acquired `st.leases[uuid]` with
  `staging_released_ = false` *before* `RegisterActivePlanDirect` enforced `uuid`
  uniqueness in `active_plans_`, so a rejected duplicate or racing
  `PoolReshardRegisterRecv` destroyed its session and freed the active session's
  staging lease (witnessed by
  `trace_r5_duplicate_uuid_frees_survivor_lease_and_aliases_slot`). Fixed in
  `8653373` (`RegistrationPolicy.reserveBeforeLease`,
  `reshard_receive_session.cc:376-388`, tested at
  `kv_cache_manager_with_transfer_pool_reshard_test.cc:624-764`): `Create` claims
  `uuid` via `RegisterActivePlanDirect` before constructing the session and
  acquiring staging, releasing any partial lease while `uuid` is still claimed
  and rolling back `UnregisterActivePlanDirect` on `AcquireStagingLeases`
  failure. Proved safe by `reachable_reserveBeforeLease_safe` and replayed by
  `trace_pool_staging_recv_registration_tests` in `PoolStaging.lean`. See
  [findings/README.md §F6](../../findings/README.md).
* **R6 [HYP / Code audit — Stage 1–2 `Send.lean` / `Pipeline.lean`]
  `RecordPushCompletion` unregisters the active plan on partial error while
  sibling pools/peers are still in flight.** In
  `ReshardSendSession::RecordPushCompletion` (`reshard_send_session.cc:360-384`),
  the first failed D2H or peer push latches `finalizing_ = true` and immediately
  calls `UnregisterActivePlan` even when `in_flight_ > 1`, whereas `EndOp()`
  (`reshard_send_session.cc:428-440`) already unregisters the plan at settle
  (`in_flight_ == 1 && finalizing_`). Because `StartPoolPush`
  (`reshard_send_session.cc:313-348`) checks `finalizing_` once under `mu_`,
  increments `in_flight_ += transfers_by_peer.size()`, and then loops over peers
  outside `mu_` calling `AsyncPush` $\to$ `BuildBlockRequests`
  (`block_transport.cc:1040-1046`) $\to$ `GetBlockChunks`
  (`kv_cache_manager_base.cc:3298-3325`), a concurrent or subsequent peer push
  in the same session can invoke `GetBlockChunks` after `uuid_` has been erased
  from `active_plans_`: on bounded staging (`staging_bounded == true`) it
  returns `{}` (`:3299-3303`), while on full-mirror staging
  (`staging_bounded == false`, `explicit_pools_ == true`) it silently falls back
  to full-block un-sliced extents (`:3306-3325`) instead of the plan's sub-block
  slices. Modeled via `UnregisterPolicy` (`shipping` vs. `onSettle`), proved safe
  under `onSettle` by `reachable_onSettle_plan_iff_done`, and witnessed by
  `trace_early_unregister_on_error_vs_onSettle` in `Send.lean`.
* **R7 [HYP / Code audit — Stage 4 `Registry.lean`] Multi-owner pipelined claims
  share a single owner-unscoped `completed_units_` set.**
  `RequestBlockRegistry::claimed_owners_` (`request_block_registry.h:144-147`)
  explicitly supports multiple pipelined destination stages claiming the same
  source snapshot `(req_id, uuid)` under distinct `claim_owner` tokens so that
  one stage's `AbandonClaim` does not release another stage's claim
  (`request_block_registry.cc:493-509`). However,
  `completed_units_[(req_id, uuid)].units` (`request_block_registry.h:124, 149`)
  is keyed only by `(req_id, uuid)` (not `(req_id, uuid, claim_owner)`), and
  `RequestBlockRegistry::Complete` (`request_block_registry.cc:358-368`) calls
  `RetireLocked` as soon as every unit in `claimed_units_` has voted once —
  erasing `request_blocks_`, `claimed_`, `claimed_units_`, and `claimed_owners_`
  even when a second pipelined `claim_owner` is still registered. Furthermore,
  `AbandonClaim` (`:503-507`) does not clear `completed_units_`. Witnessed by
  `trace_r7_single_stage_votes_retire_multi_owner_claim` in `Registry.lean`.
* **R8 [HYP / Code audit — Stage 4 `Registry.lean`] Split TTL expiration between
  `request_blocks_` and `claimed_` purges registered blocks while a claim is
  still active.** `RequestBlockRegistry::Register` (`request_block_registry.cc:263`)
  sets `registration.expires_at = t_0 + ttl_s_` on `request_blocks_[(req_id, unit)]`,
  whereas `LookupAndClaim` at time $t_1 > t_0$ sets
  `claimed_[(req_id, uuid)] = t_1 + ttl_s_` (`:473`) **without** refreshing
  `registration.expires_at` on the claimed `request_blocks_` entries (and
  `CancelIfUnclaimed` at `:384` calls `PurgeExpiredLifecycleLocked` without
  `PurgeExpiredRequestBlocksLocked`). In the window $[t_0 + \text{ttl}, t_1 + \text{ttl})$,
  `PurgeExpiredRequestBlocksLocked` (`:61-69`) erases `request_blocks_[(req_id, unit)]`
  while `claimed_[(req_id, uuid)]` is still active, violating
  `ClaimOwnersConsistent` (`∀ u ∈ claimedUnits, (lookupUnit u).isSome`) and
  causing a second pipelined stage calling `LookupAndClaim` in that window to
  fail with `"Missing producer block registration"` (`:463-468`). Witnessed by
  `trace_r8_split_ttl_purges_request_blocks_while_claim_active` in `Registry.lean`.
