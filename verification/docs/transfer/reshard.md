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
| **1** | `Reshard/Receive.lean`, `Reshard/Send.lean` | Single `ReshardReceiveSession` (rank-gated `ExecuteEligiblePoolH2ds`, batch `in_flight_ += to_launch.size()`, `reshard_finalizing_`, `FinishPoolH2d`, `IsReadyToComplete` poll audit, shipping vs. fixed `end_incoming_push` failure handling) and single `ReshardSendSession` (`ExecutePush` per-pool D2H, `StartPoolPush` per-peer `AsyncPush`, `remaining_pool_peer_pushes_`, dual `UnregisterActivePlan` in `RecordPushCompletion` and `EndOp`) on top of `Session.Lifecycle`. | `Recv.reachable_safe` (`SettleSafe`, `RankWaveOrder`, `ReadinessSound`, `Publication`, `StagingIntegrity`, `NoOpLeak`), `Recv.reachable_can_settle`, poll-redundancy lemmas; `Send.reachable_safe` (`SettleSafe`, `Drained`, `PlanUnregisteredOnce`, `Publication`, `NoOpLeak`), `Send.reachable_can_settle`; `decide` traces + `#guard` + mutants (`launchIgnoringRank`, `batchInFlightDrop`, `unregisterTwice`). |
| **2** | `Reshard/Pipeline.lean` | Composed reshard pipeline: `N` senders + per-pool transport stream counter (`landedStreams p = expectedPushes p → OnPoolReceived p`) + 1 receiver + Arm-then-Dispatch barrier bit + 2-slot aliased-page memory (rank-0 vs. rank-1 on a shared page). | `Pipeline.reachable_safe` (`PublicationCorrect`, `AliasedPageCorrect`, `DecodeHbmSafe`, `StagingSafe`, `NoUnarmedPush`), `Pipeline.attention_safe`, `Pipeline.reachable_can_settle`; out-of-order network arrival trace where rank-1 lands before rank-0 (`trace_rank1_lands_first`); mutant without rank gate corrupts the aliased page. |
| **3** | `Reshard/Coverage.lean`, `Reshard/PoolStaging.lean` | Horizontal data-plane refinements: (a) sender stream count (`Σ_senders min(parallelism, |pairs|)`) equals receiver `expected_pushes` (`pool_reshard_planner.cc:1108-1116`, `reshard_receive_session.cc:319-323`) and `ValidateReceiverCoverage` interval partition implies full sub-block reconstruction (`step_pipe` simulation over `Pipeline`); (b) `PoolStagingStorage` per-`(storage, uuid)` slot conservation, idempotent re-acquire, and same-UUID lease-collision hazard. | `Coverage.stream_count_matches`, `Coverage.partition_reconstructs_block`, `PoolStaging.slot_conservation`, `PoolStaging.trace_duplicate_uuid_releases_survivor_lease` (replaying `pool_staging_test.cc`). |
| **4** | `Reshard/Registry.lean`, `Reshard/Coordinator.lean` | Control-plane state machines: `RequestBlockRegistry` (`Register`, multi-owner `LookupAndClaim`, `AbandonClaim`, `Complete` full-set voting, `CancelIfUnclaimed` tombstone) and `ReshardCoordinator` multi-destination arm-before-dispatch (`reshard_coordinator.cc:414-530`). | `Registry.reachable_safe` (`ClaimedNotRetired`, `TombstoneBlocksLateRegister`, `CompleteRequiresFullVotingSet`), `Coordinator.no_push_before_all_armed`, partial-arm-failure orphan trace (R2), replaying `reshard_service_test.cc`. |

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
  pinned until `timeout_s_`. Modeled via an `endPush (ok : Bool)` policy toggle
  comparing shipping vs. fixed behavior.
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
  and produces the exact same state transition without skipping metrics.
* **R4 [Design invariant — Stage 1–2 `Receive.lean` / `Pipeline.lean`]
  Rank-ordered H2D waves protect aliased device pages.** Documented at
  `reshard_receive_session.h:180-184` and `kv_cache_manager_base.h:667-670`;
  verified as `RankWaveOrder` in Stage 1 and `AliasedPageCorrect` in Stage 2.
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
