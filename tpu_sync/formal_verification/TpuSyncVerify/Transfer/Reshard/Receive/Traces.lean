import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.Reshard.Receive.Progress

/-! # `Recv`: replay of upstream tests, bounded searches, mutants

Part of `TpuSyncVerify.Transfer.Reshard.Receive`. -/

namespace TpuSyncVerify.Transfer.Reshard

open TpuSyncVerify.Transfer (Lifecycle)

namespace Recv

/-! ## Replay and bounded search

Concrete traces, checked by `decide`, covering rank-wave ordering when a
higher-rank pool arrives over the network before a lower-rank pool, batch H2D
launch across same-rank pools, cancellation between the two locks of
`ExecuteEligiblePoolH2ds`, `ReshardReceiveSessionTest` plan/execution scenarios,
duration metric recording
(`PoolReshardRecvTest.FinishPoolReshardRecvRecordsDurationMetric` /
`PoolReshardRecvTest.FinishPoolReshardRecvDoesNotRecordMetricOnFailure`), and
the comparison between `PushEndPolicy.endOpOnly` and
`PushEndPolicy.finishOnError`. -/

/-- Two pools with order ranks `[0, 1]` (FA at rank 0, state class at rank 1 on
aliased arena pages, `pool_order_ranks_` in `ReshardReceiveSession`): pool 1
finishes arriving on the wire first (`onPoolReceived 1`), but stays in
`.received` without taking an H2D op until pool 0 arrives (`onPoolReceived 0`),
issues, completes its H2D copy, and its callback (`h2dDone 0 true`) chains
`ExecuteEligiblePoolH2ds` to queue pool 1. -/
theorem trace_rank1_arrives_before_rank0 :
    let s := sys [0, 1]
    -- Pool 1 (rank 1) arrives first: recorded in `started_pool_indices_`, not launched.
    (s.run [.pushBegin, .onPoolReceived 1, .pushEnd true]).map
      (fun r => (r.pools.map Pool.stage, r.life.inFlight)) =
      some ([.waiting, .received], 0) ∧
    -- Pool 1 cannot issue an H2D copy yet.
    s.run [.pushBegin, .onPoolReceived 1, .pushEnd true, .h2dIssue 1 true] = none ∧
    -- Pool 0 (rank 0) arrives: only pool 0 is queued (`inFlight = 1`).
    (s.run [.pushBegin, .onPoolReceived 1, .pushEnd true,
            .pushBegin, .onPoolReceived 0, .pushEnd true]).map
      (fun r => (r.pools.map Pool.stage, r.life.inFlight)) =
      some ([.queued, .received], 1) ∧
    -- Pool 0's H2D completes: `FinishPoolH2d(0, OK)` queues pool 1 before releasing pool 0's op.
    (s.run [.pushBegin, .onPoolReceived 1, .pushEnd true,
            .pushBegin, .onPoolReceived 0, .pushEnd true,
            .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true]).map
      (fun r => (r.pools.map Pool.stage, r.life.inFlight, r.life.done)) =
      some ([.completed, .queued], 1, false) ∧
    -- Pool 1 now issues, finishes, settles, unregisters the plan, and publishes `done_recving`.
    (s.run [.pushBegin, .onPoolReceived 1, .pushEnd true,
            .pushBegin, .onPoolReceived 0, .pushEnd true,
            .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true,
            .h2dIssue 1 true, .h2dReady 1, .h2dDone 1 true, .publish]).map
      (fun r => (r.life.done, r.life.hasStaging, r.planUnregistered,
                 r.durationRecorded, r.published)) =
      some (true, false, true, true, some true) := by
  decide

/-- Batch H2D launch across multiple pools of the same higher rank (`[0, 1, 1]`):
both rank-1 pools arrive while rank 0 is still uploading; when rank 0 completes
(`h2dDone 0 true`), `ExecuteEligiblePoolH2ds` queues both rank-1 pools in one
batch (`in_flight_ += 2`, then `- 1` for pool 0 = `2`). -/
theorem trace_batch_launch_on_rank_wave :
    let s := sys [0, 1, 1]
    let pre := [.onPoolReceived 0, .h2dIssue 0 true, .onPoolReceived 1, .onPoolReceived 2,
                .h2dReady 0, .h2dDone 0 true]
    (s.run pre).map (fun r => (r.pools.map Pool.stage, r.life.inFlight, r.life.done)) =
      some ([.completed, .queued, .queued], 2, false) ∧
    (s.run (pre ++ [.h2dIssue 1 true, .h2dIssue 2 true, .h2dReady 1, .h2dDone 1 true,
                    .h2dReady 2, .h2dDone 2 true, .publish])).map
      (fun r => (r.life.done, r.published, r.durationRecorded)) =
      some (true, some true, true) := by
  decide

/-- The race closed by the per-pool `if (done_ || draining_)` re-check in
`ExecuteEligiblePoolH2ds`: two rank-0 pools are queued (`inFlight = 2`), the
first issues its H2D copy, and `cancel` fires before the loop reaches the second
pool's re-check lock. The second pool aborts and drops its op without starting
an upload, while the first pool's in-flight copy keeps the session and its
staging lease alive until its callback runs. -/
theorem trace_cancel_between_batch_queue_and_issue :
    let s := sys [0, 0]
    let pre := [.onPoolReceived 0, .onPoolReceived 1, .h2dIssue 0 true, .cancel, .h2dIssue 1 true]
    (s.run pre).map
      (fun r => (r.pools.map Pool.stage, r.life.inFlight, r.life.done, r.life.hasStaging)) =
      some ([.issued, .aborted], 1, false, true) ∧
    (s.run (pre ++ [.h2dReady 0, .h2dDone 0 true, .publish])).map
      (fun r => (r.life.done, r.life.hasStaging, r.planUnregistered,
                 r.durationRecorded, r.published)) =
      some (true, false, true, false, some false) := by
  decide

/-- Receiver plan identity/pool validation (`ReshardReceiveSession::ValidatePlan`,
`ValidateCommonPoolReshardPlan` and `ValidatePoolBlockBounds`, tested by
`ReshardReceiveSessionTest.RejectsMissingIdentityAndPoolFields`,
`ReshardReceiveSessionTest.RejectsOutOfRangeDuplicateAndDtypeMismatch`,
`ReshardReceiveSessionTest.RejectsBlockIdsOutsideDeclaredPool`, and
`PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints`):
- Rejects `enableHostStaging = false` (`!base->has_device_buffers()` in
  `ReshardReceiveSession::Create`,
  `PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints`),
- Registers the plan with `isSender = false`
  (`base->RegisterActivePlanDirect(plan.uuid(), plan, /*is_sender=*/false)` in
  `ReshardReceiveSession::Create`) and rejects empty `ranks`
  (`if (plan.transfer_pool_indices().empty())` in
  `ValidateCommonPoolReshardPlan`),
- Rejects out-of-range, duplicate, or dtype-mismatched pool indices
  (`if (plan.pool_dtype_tags_size() != static_cast<int>(base->num_pools()))` and
  `for (int32_t encoded_pool_idx : plan.transfer_pool_indices())` in
  `ValidateCommonPoolReshardPlan`,
  `ReshardReceiveSessionTest.RejectsOutOfRangeDuplicateAndDtypeMismatch`), and
- Rejects destination `blockId ≥ numBlocks` (`ValidatePoolBlockBounds`, called
  in `ReshardReceiveSession::ValidatePlan`,
  `ReshardReceiveSessionTest.RejectsBlockIdsOutsideDeclaredPool`). -/
def validPlan (isSender : Bool) (ranks : List Nat) : Bool :=
  !isSender && !ranks.isEmpty

def validPlanPoolsAndBlocks (enableHostStaging : Bool) (numPools numBlocks : Nat)
    (poolIndices : List Nat) (dtypeMatches : Bool) (dstBlockIds : List Nat) : Bool :=
  enableHostStaging &&
  !poolIndices.isEmpty &&
  dtypeMatches &&
  decide poolIndices.Nodup &&
  poolIndices.all (fun p => decide (p < numPools)) &&
  !dstBlockIds.isEmpty &&
  dstBlockIds.all (fun b => decide (b < numBlocks))

/-- Replay of `ReshardReceiveSessionTest.AcceptsCanonicalPlanOnExplicitPools`,
`ReshardReceiveSessionTest.AcceptsImplicitPools`,
`ReshardReceiveSessionTest.HasNoTagPolicy`,
`ReshardReceiveSessionTest.RejectsMissingIdentityAndPoolFields`,
`ReshardReceiveSessionTest.RejectsOutOfRangeDuplicateAndDtypeMismatch`,
`ReshardReceiveSessionTest.RejectsBlockIdsOutsideDeclaredPool`,
`ReshardReceiveSessionTest.GroupScopesDestinationBlocks`, and
`PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints`:
1. `PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints`:
   `enableHostStaging = false` is rejected (`false`).
2. `ReshardReceiveSessionTest.RejectsMissingIdentityAndPoolFields`:
   non-receiver registration (`isSender = true`) or empty `transfer_pool_indices`
   (`ranks = []`, `plan.clear_transfer_pool_indices()`) is rejected.
3. `ReshardReceiveSessionTest.RejectsOutOfRangeDuplicateAndDtypeMismatch`:
   out-of-range pool index (`/*transferred_pools=*/{1}`, modeled with `[99]` on
   `numPools = 2`), duplicate pool indices `[0, 0]` (`/*transferred_pools=*/{0, 0}`),
   or dtype mismatch (`dtypeMatches = false`, `/*dtype_tags=*/{"fp8"}`) is
   rejected.
4. `ReshardReceiveSessionTest.RejectsBlockIdsOutsideDeclaredPool`: destination
   block outside the declared pool (`[16]` on `numBlocks = 16`) is rejected
   (`false`), whereas in-range blocks (`[1, 2]`) are accepted (`true`).
5. A canonical 1-pool plan (`ranks = [0]`,
   `ReshardReceiveSessionTest.AcceptsCanonicalPlanOnExplicitPools` /
   `ReshardReceiveSessionTest.AcceptsImplicitPools`) and a 2-group plan
   (`ranks = [0, 0]`, `ReshardReceiveSessionTest.HasNoTagPolicy` /
   `ReshardReceiveSessionTest.GroupScopesDestinationBlocks`) execute H2D,
   release staging leases, unregister the active plan, and publish
   `done_recving`. -/
theorem trace_reshard_receive_session_test_parity :
    validPlanPoolsAndBlocks false 2 16 [0] true [1] = false ∧
    validPlan true [0] = false ∧
    validPlan false [] = false ∧
    validPlan false [0] = true ∧
    validPlanPoolsAndBlocks true 2 16 [99] true [1] = false ∧
    validPlanPoolsAndBlocks true 2 16 [0, 0] true [1] = false ∧
    validPlanPoolsAndBlocks true 2 16 [0] false [1] = false ∧
    validPlanPoolsAndBlocks true 2 16 [0] true [16] = false ∧
    validPlanPoolsAndBlocks true 2 16 [0] true [1, 2] = true ∧
    ((sys [0]).run
      [.pushBegin, .onPoolReceived 0, .pushEnd true,
       .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true, .publish]).map
      (fun r => (r.life.done, r.life.hasStaging, r.planUnregistered, r.published)) =
      some (true, false, true, some true) ∧
    ((sys [0, 0]).run
      [.pushBegin, .onPoolReceived 0, .pushEnd true,
       .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true,
       .pushBegin, .onPoolReceived 1, .pushEnd true,
       .h2dIssue 1 true, .h2dReady 1, .h2dDone 1 true, .publish]).map
      (fun r => (r.pools.map Pool.stage, r.life.done, r.life.hasStaging,
                 r.planUnregistered, r.published)) =
      some ([.completed, .completed], true, false, true, some true) := by
  decide

/-- `PoolReshardRecvTest.FinishPoolReshardRecvRecordsDurationMetric` and
`PoolReshardRecvTest.FinishPoolReshardRecvDoesNotRecordMetricOnFailure`:
duration is recorded when the final pool's H2D completes OK
(`FinishPoolReshardRecvRecordsDurationMetric`), and is not recorded when a
pool's H2D fails (`FinishPoolReshardRecvDoesNotRecordMetricOnFailure`). -/
theorem trace_duration_metric_on_success_and_failure :
    let s := sys [0]
    ((s.run [.onPoolReceived 0, .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true, .publish]).map
      (fun r => (r.published, r.durationRecorded, r.planUnregistered)) =
      some (some true, true, true)) ∧
    ((s.run [.onPoolReceived 0, .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 false, .publish]).map
      (fun r => (r.published, r.durationRecorded, r.planUnregistered)) =
      some (some false, false, true)) := by
  decide

/-- `hooks.end_incoming_push` on a failed push
(`KVCacheManagerWithTransfer::InitializeBaseHooks`). Under the `.endOpOnly`
mutant the hook ends the op without finishing the session, leaving
`draining = false`, `done = false`, `hasStaging = true`, and
`planUnregistered = false` until the external deadline (`cancel`). Under
`PushEndPolicy.finishOnError` — the shipping code, replaying
`PoolReshardRecvTest.FailedIncomingPushReleasesStagingLeaseBeforeDeadline` —
`pushEnd false` immediately drains and settles the session, releasing the pool
staging lease and unregistering the plan. -/
theorem trace_r1_failed_incoming_push :
    -- `.endOpOnly` mutant: after `[.pushBegin, .pushEnd false]`, session is still open and holds staging/plan.
    ((sys [0] .endOpOnly).run [.pushBegin, .pushEnd false]).map
      (fun r => (r.life.draining, r.life.done, r.life.hasStaging, r.planUnregistered)) =
      some (false, false, true, false) ∧
    (sys [0] .endOpOnly).run [.pushBegin, .pushEnd false, .publish] = none ∧
    -- Shipping (`finishOnError`): `[.pushBegin, .pushEnd false]` settles at once and publishes failure.
    ((sys [0] .finishOnError).run [.pushBegin, .pushEnd false, .publish]).map
      (fun r => (r.life.done, r.life.hasStaging, r.planUnregistered, r.published)) =
      some (true, false, true, some false) := by
  decide

def events (numPools : Nat) : List Ev :=
  [.pushBegin, .pushEnd true, .pushEnd false, .pollReady, .cancel, .publish] ++
  (List.range numPools).flatMap fun p =>
    [.onPoolReceived p, .h2dIssue p true, .h2dIssue p false,
     .h2dReady p, .h2dDone p true, .h2dDone p false]

instance (pol : PushEndPolicy) (s : Recv) : Decidable (Safe pol s) := by
  unfold Safe SettleSafe NoRetiredCallback StagingIntegrity PlanIntegrity SettlesPromptly RankWaveOrder ReadinessSound Publication NoOpLeak
  infer_instance

/-- Executable negation of `Safe`, by construction: the bounded searches and the
`reachable_safe` theorem check the same predicate. -/
def violates (pol : PushEndPolicy) (s : Recv) : Bool := !decide (Safe pol s)

theorem violates_iff (pol : PushEndPolicy) (s : Recv) : violates pol s = false ↔ Safe pol s := by
  simp [violates]


/-- Mutant 1 (`onPoolReceivedIgnoringRank`): `CollectEligiblePoolH2dsLocked`
ignores `pool_order_ranks_` and launches every started pool immediately. When
pool 1 (rank 1) arrives before pool 0 (rank 0), pool 1 launches while pool 0 is
still `.waiting`, violating `RankWaveOrder`. -/
def onPoolReceivedIgnoringRank (p : Nat) (s : Recv) : Option Recv :=
  match s.pools[p]? with
  | some pool =>
    if s.life.done = true ∨ pool.stage != .waiting then none
    else
      let pools₁ := s.pools.set p { pool with stage := .received }
      if s.life.done = true ∨ s.life.draining = true ∨ s.finalizing = true then
        some { s with pools := pools₁ }
      else
        let (pools', k) := launchPass (fun _ => true) pools₁
        some { s with pools := pools', life := { s.life with inFlight := s.life.inFlight + k } }
  | none => none

#guard (match ModelCheck.check ⟨init [0, 1], fun s e => match e with
          | .onPoolReceived p => onPoolReceivedIgnoringRank p s
          | e => step .finishOnError s e⟩ (events 2) (violates .finishOnError) 4 with
        | .counterexample _ => true
        | _ => false)

/-- Mutant 2 (`h2dIssueLeak`): the `if (done_ || draining_)` re-check in
`ExecuteEligiblePoolH2ds` skips the upload without calling `EndRecvOpLocked()`.
A cancellation between queuing and issuing leaks the op, caught by `NoOpLeak`. -/
def h2dIssueLeak (p : Nat) (ok : Bool) (s : Recv) : Option Recv :=
  match s.pools[p]? with
  | some pool =>
    if pool.stage != .queued then none
    else if s.life.done = true ∨ s.life.draining = true then
      some { s with pools := s.pools.set p { pool with stage := .aborted } }
    else s.h2dIssue p ok
  | none => none

#guard (match ModelCheck.check ⟨init [0], fun s e => match e with
          | .h2dIssue p ok => h2dIssueLeak p ok s
          | e => step .finishOnError s e⟩ (events 1) (violates .finishOnError) 5 with
        | .counterexample _ => true
        | _ => false)

/-- Mutant 3 (`cancelUnregisterEarly`): external cancellation unregisters the
active plan immediately when `Finish` sets `draining_` (`UnregisterActivePlan`),
instead of deferring unregistration to `MaybeUnregisterSettledReshardRecv`
(`TakePendingUnregister`) after open incoming pushes (`pushes > 0`) drain,
violating `PlanIntegrity`. -/
def cancelUnregisterEarly (s : Recv) : Option Recv :=
  some { s with life := s.life.finishLocked false, planUnregistered := true }

#guard (match ModelCheck.check ⟨init [0], fun s e => match e with
          | .cancel => cancelUnregisterEarly s
          | e => step .finishOnError s e⟩ (events 1) (violates .finishOnError) 4 with
        | .counterexample _ => true
        | _ => false)

end Recv

end TpuSyncVerify.Transfer.Reshard
