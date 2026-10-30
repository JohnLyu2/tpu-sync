import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Transfer.Reshard.Coordinator.Traces

/-! # `Coordinator`: branch coverage of `CoordState.step .shipping` by the replayed tests

Part of `TpuSyncVerify.Transfer.Reshard.Coordinator`. Built like
`Reshard/Registry/Coverage.lean`: `Leaf` names one leaf of an event's decision
tree under the shipping cleanup policy, `stepT` is `step .shipping` with the
leaf attached, `stepT_step` proves it is the same function, and the effect read
off a step is the coordinator phase before and after plus what an abort leaves
behind (`CoordEffect`). -/

namespace TpuSyncVerify.Transfer.Reshard.Coordinator

open TpuSyncVerify.Coverage (Instr insertNew sameSet)
open TpuSyncVerify.Transfer.Reshard.Registry

/-- One leaf of `step .shipping`'s decision tree per event. -/
inductive Leaf
  /-- `RequestBlockRegistry::Register` for a producer, before planning. -/
  | registerProducer
  /-- `BuildPoolReshardPlan`: claim taken, plan built; Stage 1 begins. -/
  | startPlanOk
  /-- `BuildPoolReshardPlan`: claim taken, plan refused (`if (!plan_or.ok())`);
  the claim is abandoned (`if (index == 0)`) and the call returns. -/
  | startPlanFailed
  /-- A `PoolReshardRegisterRecv` RPC returned OK: the destination is armed. -/
  | armOk
  /-- A `PoolReshardRegisterRecv` RPC failed (`arm_status[i]`). -/
  | armFail
  /-- Stage 1 join with every destination armed: Stage 2 begins. -/
  | armBarrierDispatch
  /-- Stage 1 join with a refused arm: `AbandonClaim`, `return arm_status[i];`,
  armed destinations left in place. -/
  | armBarrierAbort
  /-- A `PoolReshardPush` RPC returned OK, the sender voted `Complete`, and no
  destination completed on this push. -/
  | sendOk
  /-- Same, and at least one destination received its last push and released
  its staging lease. -/
  | sendOkCompletes
  /-- A `PoolReshardPush` RPC failed (`sender_status[i]`); no vote. -/
  | sendFail
  /-- Stage 2 join with every sender OK: `return absl::OkStatus()`. -/
  | sendBarrierSucceeds
  /-- Stage 2 join with a failed sender: `return status;` with neither disarm
  nor `AbandonClaim`. -/
  | sendBarrierAbort
  deriving Repr, DecidableEq

/-- What a step did to the sub-plan: its phase before and after, and, after the
step, whether the registry claim is still held and whether a destination is
still armed. -/
structure CoordEffect where
  before : CoordPhase
  after : CoordPhase
  claimHeld : Bool
  armedLeft : Bool
  deriving Repr, DecidableEq

def effect (s s' : CoordState) : CoordEffect :=
  { before := s.phase, after := s'.phase,
    claimHeld := s'.reg.claimedUnits.isSome,
    armedLeft := s'.dstStates.any (·.sessionArmed) }

abbrev Branch := Leaf × CoordEffect

def completedCount (s : CoordState) : Nat := (s.dstStates.filter (·.completed)).length

/-- `step .shipping` with the leaf it took. -/
def stepT (s : CoordState) : Ev → Option (CoordState × Leaf)
  | .registerProducer u => (CoordState.step .shipping s (.registerProducer u)).map (·, .registerProducer)
  | .startPlan ok =>
    (CoordState.step .shipping s (.startPlan ok)).map (·, if ok then .startPlanOk else .startPlanFailed)
  | .armDstResult d ok =>
    (CoordState.step .shipping s (.armDstResult d ok)).map (·, if ok then .armOk else .armFail)
  | .finishArmBarrier =>
    (CoordState.step .shipping s .finishArmBarrier).map
      (·, if s.armFailed then .armBarrierAbort else .armBarrierDispatch)
  | .sendSrcResult u ok =>
    (CoordState.step .shipping s (.sendSrcResult u ok)).map fun s' =>
      (s', if !ok then .sendFail
           else if completedCount s' > completedCount s then .sendOkCompletes
           else .sendOk)
  | .finishSendBarrier =>
    (CoordState.step .shipping s .finishSendBarrier).map
      (·, if s.sendFailed then .sendBarrierAbort else .sendBarrierSucceeds)

/-- `stepT` is `step .shipping` with a tag. -/
theorem stepT_step (s : CoordState) (e : Ev) :
    (stepT s e).map (·.1) = CoordState.step .shipping s e := by
  cases e <;> simp [stepT, Option.map_map, Function.comp_def]

def instr : Instr CoordState Ev Leaf CoordEffect := { stepT, effect }

/-- Events for a one-source, one-destination sub-plan. -/
def checkEvents1 : List Ev :=
  [.registerProducer 0, .startPlan true, .startPlan false,
   .armDstResult 10 true, .armDstResult 10 false, .finishArmBarrier,
   .sendSrcResult 0 true, .sendSrcResult 0 false, .finishSendBarrier]

/-- Events for two sources and one destination (the `FullPoolReshardFlow` shape). -/
def checkEvents21 : List Ev :=
  [.registerProducer 0, .registerProducer 1, .startPlan true, .startPlan false,
   .armDstResult 10 true, .armDstResult 10 false, .finishArmBarrier,
   .sendSrcResult 0 true, .sendSrcResult 0 false, .sendSrcResult 1 true, .sendSrcResult 1 false,
   .finishSendBarrier]

/-- The 1×1, 2×1 and 2×2 sub-plans, each searched over its own events. -/
def inits : List (CoordState × List Ev) :=
  [(CoordState.init [0] [10] 101, checkEvents1),
   (CoordState.init [0, 1] [10] 101, checkEvents21),
   (CoordState.init [0, 1] [10, 11] 101, checkEvents)]

def allBranches : Option (List Branch) :=
  inits.foldlM (fun acc (i, evs) =>
    (Coverage.reachableBranches instr i evs 64).map (·.foldl insertNew acc)) []

/-! ## Traces

`paired` lists the `ReshardStackTest` cases that drive one `RunSubPlan` through
events of this model, with the sub-plan shape and the trace each replays. The
tests run `ReshardService` over a fake control transport: an arm or dispatch
RPC succeeds or is refused by `transport_.FailFor`, and no worker ever votes
`Complete`, whereas `sendSrcResult _ true` folds the worker's vote in (the
coordinator model's abstraction of the data plane); the pairing is at the
coordinator's own transitions. `refused` lists the one refusal asserted. -/

def tr_full_flow_2x1 : List Ev :=
  [.registerProducer 0, .registerProducer 1, .startPlan true, .armDstResult 10 true,
   .finishArmBarrier, .sendSrcResult 0 true, .sendSrcResult 1 true, .finishSendBarrier]
def tr_arm_failure_1x1 : List Ev :=
  [.registerProducer 0, .startPlan true, .armDstResult 10 false, .finishArmBarrier]
def tr_arm_failure_2x1 : List Ev :=
  [.registerProducer 0, .registerProducer 1, .startPlan true, .armDstResult 10 false,
   .finishArmBarrier]
def tr_plan_refused_2x2 : List Ev := [.registerProducer 0, .registerProducer 1, .startPlan false]

/-- `(upstream test, initial state, trace)`. -/
def paired : List (String × CoordState × List Ev) :=
  [("ReshardStackTest.FullPoolReshardFlowEmitsArmThenDispatch", CoordState.init [0, 1] [10] 101,
     tr_full_flow_2x1),
   ("ReshardStackTest.TwoDestinationsArmEachThenDispatchSendersOnce",
     CoordState.init [0, 1] [10, 11] 101, coordinatorHappyTrace),
   ("ReshardStackTest.TwoDestinationsShardedSpansRouteBytesPerReceiver",
     CoordState.init [0, 1] [10, 11] 101, coordinatorHappyTrace),
   ("ReshardStackTest.ReplicatedAndRoutedSpansCombine",
     CoordState.init [0, 1] [10, 11] 101, coordinatorHappyTrace),
   ("ReshardStackTest.ArmFailureAbandonsClaimAndSkipsSenders", CoordState.init [0] [10] 101,
     tr_arm_failure_1x1),
   -- stage 0 of `req-pp4`: its single receiver refuses the arm, the claim is
   -- abandoned, and the request reads as registered.
   ("ReshardStackTest.AbandoningTheLastStageFreesTheClaim", CoordState.init [0, 1] [10] 101,
     tr_arm_failure_2x1),
   -- `ValidateSpanCoverage` refuses the plan after `LookupAndClaim`; no arm is
   -- sent (`transport_.calls_.empty()`).
   ("ReshardStackTest.ShardedDestinationWithoutCoverageFailsClosed",
     CoordState.init [0, 1] [10, 11] 101, tr_plan_refused_2x2),
   ("ReshardStackTest.ShardedSpanOrdinalOutOfRangeFailsClosed",
     CoordState.init [0, 1] [10, 11] 101, tr_plan_refused_2x2),
   ("ReshardStackTest.ShardedNonUniformExtentsFailClosed",
     CoordState.init [0, 1] [10, 11] 101, tr_plan_refused_2x2)]

/-- `(upstream test, initial state, trace, refused event)`:
`ReshardStackTest.MissingRegistrationKeepsContractString` plans with no producer
registered, and `LookupAndClaim` refuses the claim before anything else happens. -/
def refused : List (String × CoordState × List Ev × Ev) :=
  [("ReshardStackTest.MissingRegistrationKeepsContractString", CoordState.init [0] [10] 101, [],
     .startPlan true)]

/-- The traces no upstream test drives: the two failure-cleanup counterexamples
of `Traces.lean`. -/
def modelOnly : List (String × CoordState × List Ev) :=
  [("partialArmFailureTrace", CoordState.init [0, 1] [10, 11] 101, partialArmFailureTrace),
   ("dispatchFailureTrace", CoordState.init [0, 1] [10, 11] 101, dispatchFailureTrace)]

-- Every paired trace runs to its end; the refusal is refused.
#guard paired.all fun (_, s, tr) => ((CoordState.sys .shipping s.srcUnits s.dstUnits s.claimOwner).run tr).isSome
#guard refused.all fun (_, s, tr, e) =>
  ((CoordState.sys .shipping s.srcUnits s.dstUnits s.claimOwner).run tr).bind
    (fun s' => CoordState.step .shipping s' e) == none

/-! ## Result

The three searches exhaust their state spaces: **14 branches**, every leaf of
`Leaf` reachable. The nine tests in `paired` reach **10 of 14**; the two
`modelOnly` counterexample traces reach the other four. The four the tests miss,
all schedules `ReshardStackTest`'s fake transport can drive with
`transport_.FailFor` on the right endpoint:

| Branch | Schedule | What it would take |
|---|---|---|
| `armFail` with another destination already armed | 2×2: `armDstResult 10 true, armDstResult 11 false` | `FailFor` on the second destination's control address in a two-destination `Coordinate` |
| `armBarrierAbort` leaving a destination armed | the same, then `finishArmBarrier` | the same test, asserting the surviving receiver (`partialArmFailureTrace`: the armed receiver holds its staging lease until its deadline) |
| `sendFail` | `…, finishArmBarrier, sendSrcResult 0 false` | `FailFor` on a source rank's control address after the arms succeeded |
| `sendBarrierAbort` | the same, then `finishSendBarrier` | the same test, asserting the registry still reads claimed and `CancelIfUnclaimed` returns `false` (`dispatchFailureTrace`) |

Every `ReshardStackTest` failure injection today is on a destination (an arm
refusal) or in the planner; none fails a sender dispatch. -/

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, s, tr) => (s, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

def br (l : Leaf) (b a : CoordPhase) (claimHeld armedLeft : Bool) : Branch :=
  (l, ⟨b, a, claimHeld, armedLeft⟩)

def gaps : List Branch :=
  [br .armFail .arming .arming true true,
   br .armBarrierAbort .arming .aborted false true,
   br .sendFail .dispatching .dispatching true true,
   br .sendBarrierAbort .dispatching .aborted true true]

def allLeaves : List Leaf :=
  [.registerProducer, .startPlanOk, .startPlanFailed, .armOk, .armFail, .armBarrierDispatch,
   .armBarrierAbort, .sendOk, .sendOkCompletes, .sendFail, .sendBarrierSucceeds, .sendBarrierAbort]

/-- One search, every check: the state spaces are exhausted; 14 branches; 10
reached by paired traces, all 14 with `modelOnly`; the uncovered set is the
table; every leaf fires; every gap has a witness schedule. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let uncovered := univ.filter (fun b => !coveredByPaired.contains b)
    univ.length = 14 ∧ coveredByPaired.length = 10 ∧ coveredByAll.length = 14 ∧
    coveredByPaired.all univ.contains ∧
    sameSet uncovered gaps ∧
    allLeaves.all (fun l => univ.any (·.1 = l)) ∧
    gaps.all (fun b => inits.any fun (i, evs) => (Coverage.witness instr i evs b).isSome)

#guard coverageChecks

end TpuSyncVerify.Transfer.Reshard.Coordinator
