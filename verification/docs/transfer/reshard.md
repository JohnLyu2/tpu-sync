# Pool-reshard transfer: plan, model and results

Verification plan and living results document for the pool-addressed resharding
transfer path under `TpuSyncVerify/Transfer/Reshard/`, sibling to
[prefill_decode.md](prefill_decode.md). Citations in the Lean files and in this
document are to tpu-sync **`50b0774`**.

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
at `tpu_sync/core/reshard_receive_session.cc:458-496`). All reshard models live
under `TpuSyncVerify/Transfer/Reshard/` in namespace
`TpuSyncVerify.Transfer.Reshard`.

What is qualitatively new relative to prefill-to-decode:

1. **Rank-ordered pool H2D waves on aliased device pages**
   (`ReshardReceiveSession`, `reshard_receive_session.{h,cc}`): pools carry a
   `rank` (e.g. full-attention at rank 0, state classes at rank 1 on shared
   hybrid-model arena pages, `.h:180-184`), and a pool's H2D copy may launch
   only after every expected pool of strictly lower rank has *completed* its H2D
   callback (`CollectEligiblePoolH2dsLocked`, `.cc:540-569`), even when
   higher-rank pools finish arriving over the network first.
2. **Multi-sender fan-in and per-(pool, peer) push slots**
   (`ReshardSendSession`, `reshard_send_session.{h,cc}`;
   `CountPoolReshardSendSlots`, `pool_reshard_send_slots.{h,cc}`;
   `BlockTransport::HandleIncomingPush` plan-declared progress,
   `block_transport.cc:478-622`): `N` senders push disjoint sub-block slices into
   one receiver pool; the transport counts completed streams per `(uuid, pool)`
   against `expected_pushes` before firing `OnPoolReceived(pool_idx)` once
   (`block_transport.cc:605`).
3. **Two-phase Arm-then-Dispatch coordination and block registry claims**
   (`ReshardCoordinator`, `reshard_coordinator.{h,cc}`; `RequestBlockRegistry`,
   `request_block_registry.{h,cc}`): the source controller claims producer
   blocks, arms every destination receiver (`PoolReshardRegisterRecv`) and
   collects their pool host addresses before dispatching any sender
   (`PoolReshardPush`), and retires producer blocks only when every source unit
   votes `Complete`.
4. **Bounded per-UUID pool host-staging leases** (`PoolStagingStorage`,
   `kv_cache_manager_base.cc:2068-2155, 3242-3295`): both sessions lease bounded
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
| **1 (proved)** | `Reshard/Receive.lean`, `Reshard/Send.lean` | Single `ReshardReceiveSession` (rank-gated `ExecuteEligiblePoolH2ds`, batch `in_flight_ += to_launch.size()`, `reshard_finalizing_`, `FinishPoolH2d`, `IsReadyToComplete` poll audit, `PushEndPolicy` `shipping` vs. `finishOnError`) and single `ReshardSendSession` (`ExecutePush` per-pool D2H, `StartPoolPush` per-peer `AsyncPush`, `CountPoolReshardSendSlots` / `remaining_pool_peer_pushes_`, `UnregisterPolicy` `shipping` vs. `onSettle`) on top of `Session.Lifecycle`. | `Recv.reachable_safe` (`SettleSafe`, `NoRetiredCallback`, `StagingIntegrity`, `PlanIntegrity`, `SettlesPromptly`, `RankWaveOrder`, `ReadinessSound`, `Publication`, `NoOpLeak`), `Recv.rankWaveOrder_iff`, `Recv.reachable_pollReady_disabled`, `Recv.reachable_can_settle`; `Send.reachable_safe` (`SettleSafe`, `NoRetiredCallback`, `StagingIntegrity`, `SettlesPromptly`, `ActiveOrDraining`, `PlanIntegrity`, `Publication`, `NoOpLeak`), `Send.reachable_onSettle_plan_iff_done`, `Send.reachable_can_settle`; 8 `decide` traces + `#guard` + 6 mutants. |
| **2 (proved)** | `Reshard/Pipeline.lean` | Composed reshard pipeline: `Send` + `Recv` + per-pool transport stream counters (`sentStreams`, `landedStreams`, `landedStreams p = peerCounts p → onPoolReceived p`) + five explicit memories (`srcHbm`, `srcStaging`, `wire`, `dstStaging`, `dstHbm`) + aliased-page overwrite (`writePoolHbm` / `clobberHigherRanks`) + Arm-then-Dispatch barrier (`armed`, `init` vs. `initUnarmed`). | `Pipeline.reachable_safe` and `Pipeline.reachable_unarmed_safe` (`PublicationCorrect`, `AliasedPageCorrect`, `DstHbmSafe`, `SrcHbmSafe`, `StagingSafe`, `StreamAccountingSafe`, `NoUnarmedPush`, `NoOpLeak`); quietness (`dstHbm_quiet`, `srcHbm_quiet`, `srcStaging_quiet`, `dstStaging_quiet`) and temporal post-publication safety (`attention_safe`); progress (`reachable_can_settle`, `reachable_unarmed_can_settle`); 2 `decide` traces + `#guard` + 3 mutants. |
| **3 (planned)** | `Reshard/Coverage.lean`, `Reshard/PoolStaging.lean` | Horizontal data-plane refinements: (a) sender stream count (`Σ_senders min(parallelism, |pairs|)`) equals receiver `expected_pushes` (`pool_reshard_planner.cc:1108-1116`, `reshard_receive_session.cc:319-323`) and `ValidateReceiverCoverage` interval partition implies full sub-block reconstruction (`step_pipe` simulation over `Pipeline`); (b) `PoolStagingStorage` per-`(storage, uuid)` slot conservation, idempotent re-acquire, and same-UUID lease-collision hazard. | `Coverage.stream_count_matches`, `Coverage.partition_reconstructs_block`, `PoolStaging.slot_conservation`, `PoolStaging.trace_duplicate_uuid_releases_survivor_lease` (replaying `pool_staging_test.cc`). |
| **4 (planned)** | `Reshard/Registry.lean`, `Reshard/Coordinator.lean` | Control-plane state machines: `RequestBlockRegistry` (`Register`, multi-owner `LookupAndClaim`, `AbandonClaim`, `Complete` full-set voting, `CancelIfUnclaimed` tombstone) and `ReshardCoordinator` multi-destination arm-before-dispatch (`reshard_coordinator.cc:414-530`). | `Registry.reachable_safe` (`ClaimedNotRetired`, `TombstoneBlocksLateRegister`, `CompleteRequiresFullVotingSet`), `Coordinator.no_push_before_all_armed`, partial-arm-failure orphan trace (R2), replaying `reshard_service_test.cc`. |

### Stated preconditions and out-of-scope components

* **Disjoint source and destination units (`src_units ∩ dst_units = ∅`).**
  `BuildStartTransferForTarget` (`reshard_coordinator.cc:95-112`) marks a unit in
  both lists with `is_sender = true`, which `WorkerServiceImpl` dispatches only
  to `PoolReshardPush` (`worker_service_impl.cc:548-558`). We treat disjointness
  as a caller/planner precondition rather than modelling dual-role units.
* **Planner geometry & transfer-program lowering (out of scope).**
  `pool_reshard_planner.cc` (1,363 LOC, differential-tested against Python in
  `reshard_service_test.cc`) and `transfer_program_reshard.cc` (413 LOC,
  bijection-tested in `transfer_program_reshard_test.cc`) are pure compilers into
  `StartTransferRequest`; Stage 3 models their output contract
  (`ValidatePlan` / `ValidateReceiverCoverage` / `CountPoolReshardSendSlots`),
  not the planner arithmetic itself.
* **`weight_sync/` reshard planner (out of scope).** Separate subsystem for
  model weights, unrelated to KV-cache session transfer.

## Stage 1 results: `Receive.lean` and `Send.lean`

### `TpuSyncVerify/Transfer/Reshard/Receive.lean` (`ReshardReceiveSession`)

Models `tpu_sync/core/reshard_receive_session.{h,cc}` together with the reshard
branches of `KVCacheManagerWithTransfer` (`kv_cache_manager_with_transfer.cc:154-262,
640-748, 995-1037`), parameterized by a `ranks : List Nat` pool schedule and
`PushEndPolicy` (`shipping` vs. `finishOnError`).

* **Rank-wave invariant (`RankWaveOrder` and `rankWaveOrder_iff`).** Every pool
   starts at `RecvStage.waiting`, transitions to `received` when
  `OnPoolReceived(pool_idx)` fires, is admitted to `queued` by
  `CollectEligiblePoolH2dsLocked` (`.cc:540-569`) only when every pool with
  strictly lower `rank` is already `done`, transitions to `h2d` when its slice of
  `ExecuteEligiblePoolH2ds` issues `CopyFromHostToDevice` (`.cc:572-641`), and
  reaches `done` in `FinishPoolH2d` (`.cc:643-695`). `RankWaveOrder` proves that
  no pool is in `queued`, `h2d`, or `done` while any lower-rank pool is not yet
  `done` (`rankWaveOrder_iff` states this in universal form across pool indices).
* **Batch H2D launch and `in_flight_` accounting (`Accounted`).**
  `CollectEligiblePoolH2dsLocked` increments `in_flight_ += to_launch.size()` in
  one critical section before `ExecuteEligiblePoolH2ds` iterates over the batch
  outside `mu_`. If `TryCancelIfTimedOut` or an earlier pool's H2D failure sets
  `draining_ = true` mid-batch, each remaining queued pool takes the early exit
  at `.cc:583-586` (`h2dIssue p false`) and calls `EndRecvOp()`, preserving
  `inFlight = activePushes + poolOps pools`.
* **Deferred plan unregistration (`PlanIntegrity`).** On normal completion in
  `FinishPoolH2d` (`.cc:684`), `in_flight_ == 1` so `UnregisterActivePlan` runs
  as the last op finishes; on `cancel` (`TryCancelIfTimedOut`, `.cc:442-454`) or
  under `PushEndPolicy.finishOnError`, `DeferUnregisterOnSettle()` defers
  `UnregisterActivePlan()` to `EndRecvOpLocked` when `in_flight_` reaches `0`, so
  `planUnregistered = true → done = true` holds in all reachable states.
* **Poll-finish audit (`reachable_pollReady_disabled`, R3).** Because
  `FinishPoolH2d` sets `network_completed_ = true` (`.cc:683`) immediately before
  calling `Finish` (`.cc:686`) under the same last-H2D transition and
  `ValidatePlan` forbids zero transferred pools (`.cc:138-140`), `pollReady`
  (`IsReadyToComplete() && !IsDraining()`, `mgr.cc:1005-1009`) is disabled in
  every reachable state (`step pol s .pollReady = none`), and end-of-transfer
  metrics (`metricsRecorded`) are latched on both success and failure.
* **Traces and mutants.** Five `decide` traces (`trace_rank1_arrives_before_rank0`,
  `trace_batch_launch_on_rank_wave`, `trace_cancel_between_batch_queue_and_issue`,
  `trace_duration_metric_on_success_and_failure`, `trace_r1_failed_incoming_push`),
  `#guard` bounded searches under both `PushEndPolicy` modes, and three mutants
  (`onPoolReceivedIgnoringRank`, `h2dIssueLeak`, `cancelUnregisterEarly`).

### `TpuSyncVerify/Transfer/Reshard/Send.lean` (`ReshardSendSession`)

Models `tpu_sync/core/reshard_send_session.{h,cc}`,
`tpu_sync/core/pool_reshard_send_slots.{h,cc}`, and the sender hooks in
`kv_cache_manager_with_transfer.cc:605-638, 940-957`, parameterized by per-pool
peer counts `peerCounts : List Nat` and `UnregisterPolicy` (`shipping` vs.
`onSettle`).

* **`Session.Lifecycle` reuse.** `(in_flight_, finalizing_, done_, status_.ok(),
  !leases_released_)` is an exact instance of `Transfer.Lifecycle` (`IsDraining()`
  returns `finalizing_` at `.h:79-82`), reusing `Lifecycle.Consistent` directly.
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
  `RecordPushCompletion` (`.cc:350-374`) unregisters the active plan as soon as
  `finalizing_` is latched, whereas `EndOp()` (`.cc:412-424`) unregisters on
  settle (`in_flight_ == 1 && finalizing_`). Both policies satisfy
  `done = true → planUnregistered = true` (`PlanIntegrity`); under `onSettle`,
  `planUnregistered = s.life.done` (`reachable_onSettle_plan_iff_done`), whereas
  under `shipping`, a partial failure unregisters the plan while sibling pools
  are still in flight (`trace_early_unregister_on_error_vs_onSettle`).
* **Traces and mutants.** Three `decide` traces (`trace_multi_pool_multi_peer_send`,
  `trace_cancel_unregisters_on_last_endOp`,
  `trace_early_unregister_on_error_vs_onSettle`), `#guard` bounded searches under
  both policies, and three mutants (`initOvercountedSlots` reproducing the
  pre-#744 slot overcount at `.cc:128-130`, `stepWithoutEndOpUnregister`, and
  `d2hDoneLeakOnDraining`).

## Stage 2 results: `Pipeline.lean`

### `TpuSyncVerify/Transfer/Reshard/Pipeline.lean` (composed end-to-end reshard pipeline)

Composes `Reshard.Send`, `Reshard.Receive`, the per-pool `BlockTransport` stream
counter (`tpu_sync/transport/block_transport.cc:467-622`), the coordinator's
two-phase Arm-then-Dispatch barrier (`tpu_sync/core/reshard_coordinator.cc:414-530`),
and five explicit pool-indexed memories (`srcHbm`, `srcStaging`, `wire`,
`dstStaging`, `dstHbm`) with aliased-page overwrite semantics
(`tpu_sync/core/reshard_receive_session.h:180-184`, `kv_cache_manager_base.h:667-670`).

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

## Candidate observations and hypotheses under investigation

Tracked here as we build the Stage 1–4 models; items marked **[HYP]** require a
hardware-free C++ reproduction test before being promoted to `findings/`.

* **R1 [HYP — Stage 1 `Receive.lean`] Failed incoming push on a reshard receiver
  does not finish the session.** In `KVCacheManagerWithTransfer`'s
  `end_incoming_push` hook (`kv_cache_manager_with_transfer.cc:222-262`), the
  `TransferReceiveSession` branch calls `DeferUnregisterOnSettle();
  Finish(status)` when `!status.ok()` (`4efb0dd`, `:239-242`), whereas the
  `ReshardReceiveSession` branch (`:251-261`) only calls `EndRecvOp()`, ignoring
  `status`. Because `ReshardSendSession::RecordPushCompletion` marks the sender
  `finalizing_` on the first failed push without retrying
  (`reshard_send_session.cc:350-357`), the missing stream never arrives and the
  reshard receiver (plus its bounded `PoolStagingLease` and active plan) stays
  pinned until `timeout_s_`. Modeled via `PushEndPolicy` (`shipping` vs.
  `finishOnError`) and witnessed by `trace_r1_failed_incoming_push` in
  `Receive.lean`.
* **R2 [HYP — Stage 4 `Coordinator.lean`] Multi-destination partial arm failure
  leaves already-armed receivers orphaned until deadline.**
  `ReshardCoordinator::ExecutePoolReshard` (`reshard_coordinator.cc:418-448`)
  arms all `dst_units` in parallel threads; if unit 0 succeeds and unit 1 fails,
  the coordinator calls `AbandonClaim` and returns without disarming unit 0
  (and no cancel/unregister control-pipe command exists in `utils.h:367-370` or
  `kv_cache_listener.cc:33-53`). Same if sender dispatch fails after arming
  (`reshard_coordinator.cc:523-525`).
* **R3 [Code audit — Stage 1 `Receive.lean`] `IsReadyToComplete` poll finish on
  `ReshardReceiveSession` is redundant.** Unlike `TransferReceiveSession`,
  `ReshardReceiveSession::FinishPoolH2d` sets `network_completed_ = true` at
  `reshard_receive_session.cc:683` immediately before calling `Finish` at `:686`
  (outside `mu_`), after latching end-of-transfer metrics at `:665-672`, and
  `ValidatePlan` forbids zero transferred pools (`.cc:138-140`). Thus the poll's
  `IsReadyToComplete()` branch (`kv_cache_manager_with_transfer.cc:1005-1009`)
  is reachable only in the two-line window `reshard_receive_session.cc:683-686`
  and produces the exact same state transition without skipping metrics
  (`reachable_pollReady_disabled` in `Receive.lean`).
* **R4 [Design invariant — Stage 1–2 `Receive.lean` / `Pipeline.lean`]
  Rank-ordered H2D waves protect aliased device pages.** Documented at
  `reshard_receive_session.h:180-184` and `kv_cache_manager_base.h:667-670`;
  verified as `RankWaveOrder` (`rankWaveOrder_iff`) in Stage 1 and
  `AliasedPageCorrect` in Stage 2.
* **R5 [HYP — Stage 1/3 `PoolStaging.lean`] Per-UUID staging lease key collision
  across two-lock registration.** `PoolStagingStorage` keys leases by `uuid`
  alone (`kv_cache_manager_base.cc:2093, 2144`), and
  `~ReshardReceiveSession` calls `ReleasePoolStagingLeases(uuid_)`
  (`reshard_receive_session.h:67`). Because `PoolReshardRegisterRecv` checks
  `active_pool_reshard_recvs_`, calls `ReshardReceiveSession::Create` (which
  acquires leases and may block on `staging_cv_`), and inserts into
  `active_pool_reshard_recvs_` in two separate `mu_` scopes
  (`kv_cache_manager_with_transfer.cc:647-675`), two concurrent arms with the
  same `uuid` would share a lease and the overwritten session's destructor would
  free the survivor's staging slots.
* **R6 [HYP / Code audit — Stage 1–2 `Send.lean` / `Pipeline.lean`]
  `RecordPushCompletion` unregisters the active plan on partial error while
  sibling pools/peers are still in flight.** In
  `ReshardSendSession::RecordPushCompletion` (`reshard_send_session.cc:350-374`),
  the first failed D2H or peer push latches `finalizing_ = true` and immediately
  calls `UnregisterActivePlan` even when `in_flight_ > 1`, whereas `EndOp()`
  (`reshard_send_session.cc:412-424`) already unregisters the plan at settle
  (`in_flight_ == 1 && finalizing_`). Because `StartPoolPush`
  (`reshard_send_session.cc:303-338`) checks `finalizing_` once under `mu_`,
  increments `in_flight_ += transfers_by_peer.size()`, and then loops over peers
  outside `mu_` calling `AsyncPush` $\to$ `BuildBlockRequests`
  (`block_transport.cc:821-827`) $\to$ `GetBlockChunks`
  (`kv_cache_manager_base.cc:3290-3317`), a concurrent or subsequent peer push
  in the same session can invoke `GetBlockChunks` after `uuid_` has been erased
  from `active_plans_`: on bounded staging (`staging_bounded == true`) it
  returns `{}` (`:3291-3295`), while on full-mirror staging
  (`staging_bounded == false`, `explicit_pools_ == true`) it silently falls back
  to full-block un-sliced extents (`:3298-3317`) instead of the plan's sub-block
  slices. Modeled via `UnregisterPolicy` (`shipping` vs. `onSettle`), proved safe
  under `onSettle` by `reachable_onSettle_plan_iff_done`, and witnessed by
  `trace_early_unregister_on_error_vs_onSettle` in `Send.lean`.
