import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Transfer.Reshard.Receive.Traces

/-! # `Recv`: branch coverage of `step` by the replayed tests

Part of `TpuSyncVerify.Transfer.Reshard.Receive`. Built like
`PrefillDecode/Receive/Coverage.lean` (machinery in `Common/Coverage.lean`):
`Leaf` names one leaf of an event's decision tree, `stepT` is `step` under the
shipping `PushEndPolicy.finishOnError` with the leaf attached, and `stepT_step`
proves it is the same function. Not to be confused with `Reshard/Coverage.lean`,
the model of sub-block byte coverage. -/

namespace TpuSyncVerify.Transfer.Reshard

open TpuSyncVerify.Transfer (Lifecycle)
open TpuSyncVerify.Coverage (Effect Instr insertNew sameSet)

namespace Recv

/-- One leaf of `step`'s decision tree per event. -/
inductive Leaf
  /-- `TryBeginRecvOp` accepted an incoming push (`hooks.begin_incoming_push`). -/
  | pushBegin
  /-- `hooks.end_incoming_push` with an OK push: `EndRecvOp()` only. -/
  | pushEndOk
  /-- `hooks.end_incoming_push` with a failed push: `Finish(status)`, then
  `EndRecvOp()`. -/
  | pushEndFail
  /-- `OnPoolReceived`; `ExecuteEligiblePoolH2ds` launched at least one pool. -/
  | poolReceivedLaunches
  /-- `OnPoolReceived`; the rank gate in `CollectEligiblePoolH2dsLocked` held
  every started pool back (`if (!prerequisites_uploaded) continue;`). -/
  | poolReceivedGated
  /-- `OnPoolReceived` on a draining or finalizing session: recorded, nothing
  launched (`if (done_ || draining_) return;` or `if (reshard_finalizing_)`). -/
  | poolReceivedQuiesced
  /-- The per-pool `if (done_ || draining_)` re-check in
  `ExecuteEligiblePoolH2ds` fired: `EndRecvOpLocked()`, no upload. -/
  | h2dIssueReleased
  /-- `H2dPoolBlocks` returned a future; pushed into `h2d_futures_`. -/
  | h2dIssueOk
  /-- `H2dPoolBlocks` failed: `FinishPoolH2d` → `Finish(status)`. -/
  | h2dIssueFail
  /-- `H2dPoolBlocks` failed on an already finalizing session:
  `RecordPoolH2dResultLocked` returns `false`, no `Finish`. -/
  | h2dIssueFailFinalizing
  /-- A pool's H2D future became ready. -/
  | h2dReady
  /-- `FinishPoolH2d` on a settled session (`if (done_) return;`). -/
  | h2dDoneRetired
  /-- `FinishPoolH2d` on a finalizing session: result ignored, op ends. -/
  | h2dDoneFinalizing
  /-- `FinishPoolH2d` with an error: `Finish(status)`. -/
  | h2dDoneFail
  /-- `FinishPoolH2d` OK for the last pool: `network_completed_ = true`,
  `Finish(OkStatus())`, duration recorded. -/
  | h2dDoneLast
  /-- `FinishPoolH2d` OK, not the last pool; the chained
  `ExecuteEligiblePoolH2ds` launched the next rank wave. -/
  | h2dDoneChains
  /-- `FinishPoolH2d` OK, not the last pool; nothing new to launch. -/
  | h2dDoneMore
  /-- The poll saw `IsReadyToComplete() && !IsDraining()`. -/
  | pollReady
  /-- `Finish(error)` from outside (deadline sweep, `UnregisterActivePlan`,
  manager teardown). -/
  | cancel
  /-- The poll published a settled session. -/
  | publish
  deriving Repr, DecidableEq

def effect (s s' : Recv) : Effect :=
  Effect.of s.life.draining s.life.done s.life.statusOk
    s'.life.draining s'.life.done s'.life.statusOk

abbrev Branch := Leaf × Effect

/-- The leaf `OnPoolReceived` took, read off the states before and after. -/
def poolReceivedLeaf (p : Nat) (s s' : Recv) : Leaf :=
  if s.life.draining = true ∨ s.finalizing = true then .poolReceivedQuiesced
  else
    match s.pools[p]? with
    | some pool =>
      if s'.pools != s.pools.set p { pool with stage := .received } then .poolReceivedLaunches
      else .poolReceivedGated
    | none => .poolReceivedGated

/-- The leaf `FinishPoolH2d` + `EndRecvOp` took for pool `p`. -/
def h2dDoneLeaf (p : Nat) (ok : Bool) (s s' : Recv) : Leaf :=
  if s.life.done = true then .h2dDoneRetired
  else if s.finalizing = true then .h2dDoneFinalizing
  else if !ok then .h2dDoneFail
  else
    match s.pools[p]? with
    | some pool =>
      let pools₁ := s.pools.set p { pool with stage := .completed }
      if allCompleted pools₁ then .h2dDoneLast
      else if s'.pools != pools₁ then .h2dDoneChains
      else .h2dDoneMore
    | none => .h2dDoneMore

/-- `step .finishOnError` with the leaf it took. -/
def stepT (s : Recv) : Ev → Option (Recv × Leaf)
  | .pushBegin => (s.pushBegin).map (·, .pushBegin)
  | .pushEnd ok =>
    (s.pushEnd .finishOnError ok).map (·, if ok then .pushEndOk else .pushEndFail)
  | .onPoolReceived p => (s.onPoolReceived p).map fun s' => (s', poolReceivedLeaf p s s')
  | .h2dIssue p ok =>
    (s.h2dIssue p ok).map (·,
      if s.life.done = true ∨ s.life.draining = true then .h2dIssueReleased
      else if ok then .h2dIssueOk
      else if s.finalizing = true then .h2dIssueFailFinalizing
      else .h2dIssueFail)
  | .h2dReady p => (s.h2dReady p).map (·, .h2dReady)
  | .h2dDone p ok => (s.h2dDone p ok).map fun s' => (s', h2dDoneLeaf p ok s s')
  | .pollReady => (s.pollReady).map (·, .pollReady)
  | .cancel => (s.cancel).map (·, .cancel)
  | .publish => (s.publish).map (·, .publish)

/-- `stepT` is `step .finishOnError` with a tag. -/
theorem stepT_step (s : Recv) (e : Ev) :
    (stepT s e).map (·.1) = step .finishOnError s e := by
  cases e <;> simp [stepT, step, Option.map_map, Function.comp_def]

/-- A third concurrent push adds states but no branch, so states with more than
two open pushes are not expanded. -/
def instr : Instr Recv Ev Leaf Effect := { stepT, effect, keep := fun s => s.pushes ≤ 2 }

/-- One pool; two pools of one rank (a batch); two pools of ranks `[0, 1]`
(a rank wave). -/
def inits : List (Recv × List Ev) :=
  [(init [0], events 1), (init [0, 0], events 2), (init [0, 1], events 2)]

def allBranches : Option (List Branch) :=
  inits.foldlM (fun acc (i, evs) =>
    (Coverage.reachableBranches instr i evs 64).map (·.foldl insertNew acc)) []

/-! ## Traces

`paired` lists the upstream tests that drive a `ReshardReceiveSession` through
events of this model, with the trace each one replays. `modelOnly` holds the
traces in `Traces.lean` that no upstream test drives (the rank wave, the batch
launch, cancellation between the locks, and the full-pipeline halves of the
validation and duration traces). -/

/-- `(upstream test, initial state, trace)`. -/
def paired : List (String × Recv × List Ev) :=
  [("PoolReshardRecvTest.FailedIncomingPushReleasesStagingLeaseBeforeDeadline",
      init [0], tr_failed_incoming_push),
   -- `UnregisterActivePlan(3998)` / `(3999)` on the two idle blocker receivers:
   -- `Finish(CancelledError)` settles each at once and frees its staging slot.
   ("PoolStagingRecvRegistrationTest.ConcurrentDuplicatePoolRecvRegistrationKeepsWinnerStagingLease",
      init [0], [.cancel])]

def modelOnly : List (String × Recv × List Ev) :=
  [("trace_rank1_arrives_before_rank0", init [0, 1], tr_rank1_arrives_before_rank0),
   ("trace_batch_launch_on_rank_wave", init [0, 1, 1], tr_batch_launch_on_rank_wave),
   ("trace_cancel_between_batch_queue_and_issue", init [0, 0],
      tr_cancel_between_batch_queue_and_issue),
   ("trace_reshard_receive_session_test_parity (1 pool)", init [0], tr_parity_1pool),
   ("trace_reshard_receive_session_test_parity (2 pools)", init [0, 0], tr_parity_2pool),
   ("trace_duration_metric_on_success_and_failure (ok)", init [0], tr_duration_ok),
   ("trace_duration_metric_on_success_and_failure (fail)", init [0], tr_duration_fail)]

/-- Upstream tests on this C++ whose stimulus is not an event of the model. -/
def notReplayable : List (String × String) :=
  [("PoolReshardRecvTest.FinishPoolReshardRecvRecordsDurationMetric",
      "calls FinishPoolH2d(OK) through PoolReshardRecvTestPeer on a pool that was never received, launched or issued (no op held); exercises h2dDoneLast's FinishPoolH2d body without its EndRecvOp"),
   ("PoolReshardRecvTest.FinishPoolReshardRecvDoesNotRecordMetricOnFailure",
      "same, with an error status (h2dDoneFail's FinishPoolH2d body)"),
   ("SubPlanChainTest.ReceiveTerminalWaitsForTheLastSubPlan", "same synthetic FinishPoolH2d; asserts chain terminal aggregation, outside this model"),
   ("SubPlanChainTest.FirstSubPlanFailureFailsTheRequestOnce", "same"),
   ("SubPlanChainTest.RetryUnderTheSameReqIdIsTrackedAsANewChain", "same"),
   ("SubPlanChainTest.StalledChainFailsAfterTheTransferTimeout", "same"),
   ("SubPlanChainTest.SinglePlanRequestsReportAtOnce", "same"),
   ("PoolStagingRecvRegistrationTest.DuplicatePoolRecvRegistrationKeepsOriginalStagingLease",
      "registration and staging leases only (PoolStaging.lean); its sessions are cancelled unasserted at manager teardown"),
   ("PoolStagingRecvRegistrationTest.StagingAcquireFailureReleasesUuidClaim",
      "ReshardReceiveSession::Create rollback (PoolStaging.lean)"),
   ("PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints",
      "Create's has_device_buffers() rejection; no session exists"),
   ("ReshardReceiveSessionTest.* (16 tests)",
      "ValidatePlan / ValidateReceiverCoverage only (validPlan, validPlanPoolsAndBlocks, Coverage.lean); no session runs")]

/-! ## Result

Every search exhausts its state space, so `allBranches` is exact for receivers
of one pool, two pools of one rank, and two pools of ranks `[0, 1]`, with at
most two open push leases: **36 branches**. Three leaves of `Leaf` are in no
reachable branch:

* `h2dDoneRetired` — `FinishPoolH2d`'s `if (done_) return;` on a pool callback.
  A `.ready` pool holds an op and `done → inFlight = 0` (`SettleSafe`), so the
  callback never sees a settled session; the C++ early return is dead.
* `h2dIssueFailFinalizing` — a failed `H2dPoolBlocks` on a finalizing session.
  Every path that sets `reshard_finalizing_` (`h2dIssue` or `h2dDone` failing,
  the last pool completing) calls `Finish` in the same step, so a finalizing
  session is draining and the per-pool re-check releases the op first.
* `pollReady` — `Recv.reachable_pollReady_disabled`: `FinishPoolH2d` sets
  `network_completed_` and calls `Finish` together, so the poll never sees
  `IsReadyToComplete() && !IsDraining()`.

The two upstream tests in `paired` reach **4 of 36**: `pushBegin`,
`pushEndFail` (drains, settles, errors), `cancel` (drains, settles, errors) and
`publish`. The `modelOnly` traces add 12 more. Of the 32 the tests miss:

| Class | Count | Branches | What it would take |
|---|---|---|---|
| **test** | 21 | `pushEndOk` (no effect; settles), `pushEndFail` (all five other effects: settles; drains+errors; no effect; settles+errors; errors), `cancel` (drains+errors with a push open; no effect; errors after an OK settle), `poolReceivedLaunches`, `poolReceivedGated`, `poolReceivedQuiesced`, `h2dIssueFail` (drains+settles+errors; drains+errors), `h2dIssueOk`, `h2dReady`, `h2dDoneLast` (drains+settles; drains with a push open), `h2dDoneChains`, `h2dDoneMore` (no effect) | `BoundedPoolTestManager` (`DeviceBackedTestBase`) in `pool_reshard_test.cc`: its default-constructed `RaidenBufferHandle` (`!hold.is_common_buffer && hold.c_hold == nullptr`) makes `raiden::IssueH2dShard` return an empty `PjRtCopyFuture` whose `OnReady` runs synchronously with `OkStatus()` after `ExecuteEligiblePoolH2ds` drops `mu_`, so calling `KVCacheManagerBase::OnPoolReceived` alongside `BeginIncomingPush` / `EndIncomingPush` / `UnregisterActivePlan` drives synchronous uploads, rank waves, and (`device_size = 0` or `host_blocks = 0`, not a bare `AttachPlaceholderDeviceHoldForTest` whose empty `holds` vector cannot be indexed) synchronous `H2dPoolBlocks` failures on CPU |
| **future (stub)** | 9 | `h2dDoneLast` (settles; no effect — both already draining), `h2dDoneMore` (settles), `h2dDoneFail` (all four effects), `h2dDoneFinalizing` (no effect; settles) | a controllable `PjRtCopyFuture` fake (a `RawBuffer` / `PJRT_RawBuffer_Extension` test stub backed by `xla::Promise<>`) so an issued H2D copy can stay pending across `Finish` or resolve `OnReady` with an error on CPU |
| **window** | 2 | `h2dIssueReleased` (no effect; settles) | `Finish` between `ExecuteEligiblePoolH2ds`'s opening lock and its per-pool `if (done_ \|\| draining_)` re-check on a 1–2 pool plan (a 3-pool `[0, 1, 1]` plan whose first rank-1 pool fails `H2dPoolBlocks` synchronously reaches the no-effect arm deterministically on the second rank-1 pool) |

So no upstream test exercises `OnPoolReceived`, the rank-wave gate, the batch
launch, an upload or its callback: `BoundedPoolTestManager` already carries the
null-hold `DeviceBackedTestBase` setup that runs `IssueH2dShard` synchronously
on CPU, but existing tests only use it for registration, staging leases, and
incoming-push failure (`docs/transfer/reshard.md` §"C++ branch coverage of the
anchored spans"). -/

/-- `(leaf, drains, settles, errors)`. -/
def br (l : Leaf) (drains settles errors : Bool) : Branch := (l, ⟨drains, settles, errors⟩)

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, s, tr) => (s, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

inductive Gap where
  | test
  | futureStub
  | window
  deriving Repr, DecidableEq

/-- The table above, as the `#guard`s check it. -/
def gaps : List (Branch × Gap) :=
  [(br .pushEndOk false false false, .test), (br .pushEndOk false true false, .test),
   (br .pushEndFail false true false, .test), (br .pushEndFail true false true, .test),
   (br .pushEndFail false false false, .test),
   (br .cancel true false true, .test), (br .cancel false false false, .test),
   (br .poolReceivedLaunches false false false, .test),
   (br .poolReceivedGated false false false, .test),
   (br .poolReceivedQuiesced false false false, .test),
   (br .h2dIssueFail true true true, .test), (br .h2dIssueFail true false true, .test),
   (br .h2dIssueOk false false false, .test), (br .h2dReady false false false, .test),
   (br .h2dDoneLast true true false, .test), (br .h2dDoneLast true false false, .test),
   (br .h2dDoneChains false false false, .test),
   (br .h2dDoneMore false false false, .test),
   (br .cancel false false true, .test),
   (br .pushEndFail false true true, .test), (br .pushEndFail false false true, .test),
   (br .h2dDoneLast false true false, .futureStub),
   (br .h2dDoneLast false false false, .futureStub),
   (br .h2dDoneMore false true false, .futureStub),
   (br .h2dDoneFail true true true, .futureStub), (br .h2dDoneFail false true false, .futureStub),
   (br .h2dDoneFail true false true, .futureStub), (br .h2dDoneFail false false false, .futureStub),
   (br .h2dDoneFinalizing false false false, .futureStub),
   (br .h2dDoneFinalizing false true false, .futureStub),
   (br .h2dIssueReleased false false false, .window),
   (br .h2dIssueReleased false true false, .window)]

def unreachableLeaves : List Leaf := [.h2dDoneRetired, .h2dIssueFailFinalizing, .pollReady]

def liveLeaves : List Leaf :=
  [.pushBegin, .pushEndOk, .pushEndFail, .poolReceivedLaunches, .poolReceivedGated,
   .poolReceivedQuiesced, .h2dIssueReleased, .h2dIssueOk, .h2dIssueFail, .h2dReady,
   .h2dDoneFinalizing, .h2dDoneFail, .h2dDoneLast, .h2dDoneChains, .h2dDoneMore,
   .cancel, .publish]

def countGap (g : Gap) : Nat := (gaps.filter (·.2 = g)).length

/-- One search, every check: the state space is exhausted; 36 branches; 4
reached by paired traces, 16 with `modelOnly` (all within the universe, every
trace running to completion); the uncovered set is the table (21 test, 9
future-stub, 2 window); the unreachable leaves never fire and every other leaf
does; every gap has a witness schedule. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let uncoveredPaired := univ.filter (fun b => !coveredByPaired.contains b)
    univ.length = 36 ∧ coveredByPaired.length = 4 ∧ coveredByAll.length = 16 ∧
    coveredByPaired.all univ.contains ∧ coveredByAll.all univ.contains ∧
    sameSet uncoveredPaired (gaps.map (·.1)) ∧ gaps.length = 32 ∧
    countGap .test = 21 ∧ countGap .futureStub = 9 ∧ countGap .window = 2 ∧
    univ.all (fun b => !unreachableLeaves.contains b.1) ∧
    liveLeaves.all (fun l => univ.any (·.1 = l)) ∧
    (paired ++ modelOnly).all (fun (_, s, tr) =>
      ((⟨s, step .finishOnError⟩ : System Recv Ev).run tr).isSome) ∧
    gaps.all (fun (b, _) => inits.any fun (i, evs) => (Coverage.witness instr i evs b).isSome)

#guard coverageChecks

end Recv

end TpuSyncVerify.Transfer.Reshard
