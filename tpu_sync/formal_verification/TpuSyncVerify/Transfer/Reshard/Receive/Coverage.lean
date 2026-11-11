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
  /-- `TryBeginOp` accepted an incoming push (`BeginIncomingPush` in
  `block_transport_session.cc`). -/
  | pushBegin
  /-- `EndIncomingPush` with an OK push: `EndOp()` only. -/
  | pushEndOk
  /-- `EndIncomingPush` with a failed push: `Finish(status)`, then `EndOp()`. -/
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
  /-- `H2dPoolBlocks` returned a future; its `OnReady` continuation attached. -/
  | h2dIssueOk
  /-- No destination blocks, `LookupStagingSlot` or `H2dPoolBlocks` failed:
  `FinishPoolH2d` → `Finish(status)`. -/
  | h2dIssueFail
  /-- Same, on an already finalizing session:
  `RecordPoolH2dResultLocked` returns `false`, no `Finish`. -/
  | h2dIssueFailFinalizing
  /-- A pool's H2D copy finished on the device; its continuation has not run. -/
  | h2dReady
  /-- `FinishPoolH2d` on a settled session (`if (done_) return;`). -/
  | h2dDoneRetired
  /-- `FinishPoolH2d` on a finalizing session: result ignored, op ends. -/
  | h2dDoneFinalizing
  /-- `FinishPoolH2d` with an error: `Finish(status)`. -/
  | h2dDoneFail
  /-- `FinishPoolH2d` OK for the last pool: `Finish(OkStatus())`, duration
  recorded. -/
  | h2dDoneLast
  /-- `FinishPoolH2d` OK, not the last pool; the chained
  `ExecuteEligiblePoolH2ds` launched the next rank wave. -/
  | h2dDoneChains
  /-- `FinishPoolH2d` OK, not the last pool; nothing new to launch. -/
  | h2dDoneMore
  /-- `Finish(error)` from outside (deadline sweep, `UnregisterActivePlan`,
  manager teardown, a staging wait that timed out). -/
  | cancel
  /-- The poll retired a settled session (`RetireSettledSessionLocked`). -/
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

/-- The leaf `FinishPoolH2d` + `EndOp` took for pool `p`. -/
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
events of this model, with the trace each one replays. Two fixtures make the
upload path run on CPU: `FakeH2dBase` in `reshard_receive_session_test.cc`
(every `H2dPoolBlocks` returns a future that is already OK) and `FakeH2dBase`
in `kv_cache_manager_with_transfer_pool_reshard_test.cc`, whose
`TestManager::FinishPoolReshardRecvPool` resolves the pool's buffer
(`ResolveStagingSlot`, the pool's own storage on this full host mirror; the
helper also tolerates `NotFound`), calls `OnDataReceived(pool_idx, {}, {})` and
returns a future already resolved with the status armed by `ArmPoolUpload`. A
ready future runs `future.OnReady` inline, so `h2dReady p` and `h2dDone p _`
follow `h2dIssue p true` at once. `modelOnly` holds the traces in `Traces.lean`
that no upstream test drives (the rank wave, the batch launch, cancellation
between the locks, and the push-framed halves of the validation traces). -/

/-- One pool landed and uploaded OK through `FinishPoolReshardRecvPool`. -/
def tr_pool_upload_ok : List Ev := tr_duration_ok.take 4

/-- One pool landed, its upload failing through `FinishPoolReshardRecvPool`
(`ArmPoolUpload(pool_idx, error)`). -/
def tr_pool_upload_fail : List Ev := tr_duration_fail.take 4

/-- `(upstream test, initial state, trace)`. -/
def paired : List (String × Recv × List Ev) :=
  [("PoolReshardRecvTest.FailedIncomingPushReleasesStagingLeaseBeforeDeadline",
      init [0], tr_failed_incoming_push),
   -- `UnregisterActivePlan(3998)` / `(3999)` on the two idle blocker receivers:
   -- `Finish(CancelledError)` settles each at once and frees its staging slot.
   ("PoolStagingRecvRegistrationTest.ConcurrentDuplicatePoolRecvRegistrationKeepsWinnerStagingLease",
      init [0], [.cancel]),
   -- Pool 0 leases the only buffer; `OnDataReceived(0)` uploads it at once
   -- (`FakeH2dBase`), returning the buffer to pool 1's waiting
   -- `ResolveStagingSlot`; `cancel_waiter` then blocks in `AcquireStagingSlot`
   -- for pool 0 (`in_flight_ == 1`) while `Finish(Cancelled)` drains the
   -- session and wakes the waiter to settle via `EndRecvOpLocked()` (the
   -- slot-wait ops are projected away in this slot-free model per
   -- `Receive.lean` §"Bounded host layer staging").
   ("ReshardReceiveSessionTest.BoundedStagingSlotAcquisitionAndRelease",
      init [0, 0], [.onPoolReceived 0, .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true, .cancel]),
   -- `timeout_session`'s `ResolveStagingSlot(1)` times out inside
   -- `AcquireStagingSlot` while holding its slot-wait op (`in_flight_ == 1`),
   -- calling `FinishLocked(slot.status())` and `EndRecvOpLocked()` (likewise
   -- projected to `.cancel` per `Receive.lean` §"Bounded host layer staging").
   ("ReshardReceiveSessionTest.BoundedStagingSlotAcquisitionAndRelease (timeout_session)",
      init [0, 0], [.cancel]),
   -- Pool 1 lands and uploads before pool 0 (both rank 0).
   ("ReshardReceiveSessionTest.OutOfOrderPoolArrivalResolvesLeasedHostBufferForValidation",
      init [0, 0], [.onPoolReceived 1, .h2dIssue 1 true, .h2dReady 1, .h2dDone 1 true,
                    .onPoolReceived 0, .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true]),
   ("ReshardReceiveSessionTest.FullHostMirrorAddressesPoolsInPlace",
      init [0, 0], [.onPoolReceived 1, .h2dIssue 1 true, .h2dReady 1, .h2dDone 1 true,
                    .onPoolReceived 0, .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true]),
   -- A real two-pool reshard over TCP: each pool's only push stream lands it
   -- (`CompleteIncomingPush` → `OnDataReceived`) and `RecordingH2dReceiverBase`
   -- uploads it inline, still inside the stream's op.
   ("ReshardSendSessionTest.PoolOrderInvertedFromStorageOrderPassesTransportValidateChunks",
      init [0, 0], [.pushBegin, .onPoolReceived 0, .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true,
                    .pushEnd true,
                    .pushBegin, .onPoolReceived 1, .h2dIssue 1 true, .h2dReady 1, .h2dDone 1 true,
                    .pushEnd true]),
   ("PoolReshardRecvTest.FinishPoolReshardRecvRecordsDurationMetric",
      init [0], tr_pool_upload_ok),
   ("PoolReshardRecvTest.FinishPoolReshardRecvDoesNotRecordMetricOnFailure",
      init [0], tr_pool_upload_fail),
   ("SubPlanChainTest.SinglePlanRequestsReportAtOnce", init [0], tr_duration_ok),
   ("PoolReshardSessionLookupTest.GetSessionResolvesActiveReshardRecvUntilRetired",
      init [0], tr_duration_ok),
   -- Each sub-plan of a chain is one such session; the chain's aggregation
   -- into one terminal per request is `SubPlanChain.lean`.
   ("SubPlanChainTest.ReceiveTerminalWaitsForTheLastSubPlan (per sub-plan)",
      init [0], tr_duration_ok),
   ("SubPlanChainTest.FirstSubPlanFailureFailsTheRequestOnce (sub-plan 0)",
      init [0], tr_duration_fail),
   ("SubPlanChainTest.RetryUnderTheSameReqIdIsTrackedAsANewChain (sub-plan 0)",
      init [0], tr_duration_fail),
   ("SubPlanChainTest.StalledChainFailsAfterTheTransferTimeout (sub-plan 0)",
      init [0], tr_duration_ok)]

def modelOnly : List (String × Recv × List Ev) :=
  [("trace_rank1_arrives_before_rank0", init [0, 1], tr_rank1_arrives_before_rank0),
   ("trace_batch_launch_on_rank_wave", init [0, 1, 1], tr_batch_launch_on_rank_wave),
   ("trace_cancel_between_batch_queue_and_issue", init [0, 0],
      tr_cancel_between_batch_queue_and_issue),
   ("trace_reshard_receive_session_test_parity (1 pool)", init [0], tr_parity_1pool),
   ("trace_reshard_receive_session_test_parity (2 pools)", init [0, 0], tr_parity_2pool)]

/-- Upstream tests on this C++ whose stimulus is not an event of the model. -/
def notReplayable : List (String × String) :=
  [("PoolStagingRecvRegistrationTest.DuplicatePoolRecvRegistrationKeepsOriginalStagingLease",
      "registration and staging leases only (PoolStaging.lean); its sessions are cancelled unasserted at manager teardown"),
   ("PoolStagingRecvRegistrationTest.StagingAcquireFailureReleasesUuidClaim",
      "CreateReshardReceiveSession rollback (PoolStaging.lean)"),
   ("PoolReshardSessionLookupTest.PoolCompletionOnLegacyArmedReceiverFailsWithoutH2d",
      "OnDataReceived on a TransferReceiveSession armed by RegisterActivePlan; no ReshardReceiveSession exists"),
   ("PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints",
      "CreateReshardReceiveSession's has_device_buffers() rejection; no session exists"),
   ("ReshardReceiveSessionTest.* (16 ValidatePlan tests)",
      "CreateReshardReceiveSession's ValidatePlan / ValidateReceiverCoverage only (validPlan, validPlanPoolsAndBlocks, Coverage.lean); no session runs")]

/-! ## Result

Every search exhausts its state space, so `allBranches` is exact for receivers
of one pool, two pools of one rank, and two pools of ranks `[0, 1]`, with at
most two open push leases: **36 branches**. Two leaves of `Leaf` are in no
reachable branch:

* `h2dDoneRetired` — `FinishPoolH2d`'s `if (done_) return;` on a pool callback.
  A `.ready` pool holds an op and `done → inFlight = 0` (`SettleSafe`), so the
  callback never sees a settled session; the C++ early return is dead.
* `h2dIssueFailFinalizing` — a failed `H2dPoolBlocks` on a finalizing session.
  Every path that sets `reshard_finalizing_` (`h2dIssue` or `h2dDone` failing,
  the last pool completing) calls `Finish` in the same step, so a finalizing
  session is draining and the per-pool re-check releases the op first.

The fifteen upstream traces in `paired` reach **13 of 36**: `pushBegin`,
`pushEndOk` (no effect; settles), `pushEndFail` (drains, settles, errors),
`poolReceivedLaunches`, `h2dIssueOk`, `h2dReady`, `h2dDoneMore` (no effect),
`h2dDoneLast` (drains, settles; drains with a push open), `h2dDoneFail`
(drains, settles, errors), `cancel` (drains, settles, errors) and `publish`.
The `modelOnly` traces add 5 more. Of the 23 the tests miss:

| Class | Count | Branches | What it would take |
|---|---|---|---|
| **test** | 14 | `pushEndFail` (settles; drains+errors; no effect; settles+errors; errors), `cancel` (drains+errors with a push open; no effect; errors after an OK settle), `poolReceivedGated`, `poolReceivedQuiesced`, `h2dDoneChains`, `h2dIssueFail` (drains+settles+errors; drains+errors), `h2dDoneFail` (drains+errors with a push open) | the existing fixtures combined: `TryBeginOp` / `EndIncomingPush` or `Finish` on the session around `TestManager::FinishPoolReshardRecvPool` (a push open while the armed upload fails or the last pool completes, two pushes open when one fails, `OnDataReceived` after `Finish`, `Finish(error)` on a settled session), a two-group plan with `order_rank`s `[0, 1]` landing pool 1 first on `FakeH2dBase` (`poolReceivedGated`, then `h2dDoneChains`), and an `H2dPoolBlocks` override returning an error status (`h2dIssueFail`) |
| **test (held upload)** | 7 | `h2dDoneLast` (settles; no effect — both already draining), `h2dDoneMore` (settles), `h2dDoneFail` (settles; no effect — already draining and failed), `h2dDoneFinalizing` (no effect; settles) | an `H2dPoolBlocks` fake that parks its promise until the test releases it (as `FakeD2hBase::HoldNextCopy` / `CompleteCopy` do for sends in `reshard_send_session_test.cc`), so an issued upload is still counted when `Finish` or another pool's failure arrives |
| **window** | 2 | `h2dIssueReleased` (no effect; settles) | `Finish` between `ExecuteEligiblePoolH2ds`'s opening lock and its per-pool `if (done_ \|\| draining_)` re-check on a 1–2 pool plan (a 3-pool `[0, 1, 1]` plan whose first rank-1 pool fails `H2dPoolBlocks` synchronously reaches the no-effect arm deterministically on the second rank-1 pool) |

So the upstream tests now drive `OnPoolReceived`, an upload and its callback
with both outcomes, and a pool landing inside a real push stream, but every
upload they issue resolves before `OnReady` is attached: no test observes a
copy still running when the session is finished, and none builds a plan with
two order ranks (`docs/transfer/reshard.md` §"C++ branch coverage of the
anchored spans"). -/

/-- `(leaf, drains, settles, errors)`. -/
def br (l : Leaf) (drains settles errors : Bool) : Branch := (l, ⟨drains, settles, errors⟩)

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, s, tr) => (s, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

inductive Gap where
  | test
  | heldUpload
  | window
  deriving Repr, DecidableEq

/-- The table above, as the `#guard`s check it. -/
def gaps : List (Branch × Gap) :=
  [(br .pushEndFail false true false, .test), (br .pushEndFail true false true, .test),
   (br .pushEndFail false false false, .test),
   (br .pushEndFail false true true, .test), (br .pushEndFail false false true, .test),
   (br .cancel true false true, .test), (br .cancel false false false, .test),
   (br .cancel false false true, .test),
   (br .poolReceivedGated false false false, .test),
   (br .poolReceivedQuiesced false false false, .test),
   (br .h2dDoneChains false false false, .test),
   (br .h2dIssueFail true true true, .test), (br .h2dIssueFail true false true, .test),
   (br .h2dDoneFail true false true, .test),
   (br .h2dDoneLast false true false, .heldUpload),
   (br .h2dDoneLast false false false, .heldUpload),
   (br .h2dDoneMore false true false, .heldUpload),
   (br .h2dDoneFail false true false, .heldUpload),
   (br .h2dDoneFail false false false, .heldUpload),
   (br .h2dDoneFinalizing false false false, .heldUpload),
   (br .h2dDoneFinalizing false true false, .heldUpload),
   (br .h2dIssueReleased false false false, .window),
   (br .h2dIssueReleased false true false, .window)]

def unreachableLeaves : List Leaf := [.h2dDoneRetired, .h2dIssueFailFinalizing]

def liveLeaves : List Leaf :=
  [.pushBegin, .pushEndOk, .pushEndFail, .poolReceivedLaunches, .poolReceivedGated,
   .poolReceivedQuiesced, .h2dIssueReleased, .h2dIssueOk, .h2dIssueFail, .h2dReady,
   .h2dDoneFinalizing, .h2dDoneFail, .h2dDoneLast, .h2dDoneChains, .h2dDoneMore,
   .cancel, .publish]

def countGap (g : Gap) : Nat := (gaps.filter (·.2 = g)).length

/-- One search, every check: the state space is exhausted; 36 branches; 13
reached by paired traces, 18 with `modelOnly` (all within the universe, every
trace running to completion); the uncovered set is the table (14 test, 7
held-upload, 2 window); the unreachable leaves never fire and every other leaf
does; every gap has a witness schedule. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let uncoveredPaired := univ.filter (fun b => !coveredByPaired.contains b)
    univ.length = 36 ∧ coveredByPaired.length = 13 ∧ coveredByAll.length = 18 ∧
    coveredByPaired.all univ.contains ∧ coveredByAll.all univ.contains ∧
    sameSet uncoveredPaired (gaps.map (·.1)) ∧ gaps.length = 23 ∧
    countGap .test = 14 ∧ countGap .heldUpload = 7 ∧ countGap .window = 2 ∧
    univ.all (fun b => !unreachableLeaves.contains b.1) ∧
    liveLeaves.all (fun l => univ.any (·.1 = l)) ∧
    (paired ++ modelOnly).all (fun (_, s, tr) =>
      ((⟨s, step .finishOnError⟩ : System Recv Ev).run tr).isSome) ∧
    gaps.all (fun (b, _) => inits.any fun (i, evs) => (Coverage.witness instr i evs b).isSome)

#guard coverageChecks

end Recv

end TpuSyncVerify.Transfer.Reshard
