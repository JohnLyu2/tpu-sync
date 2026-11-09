import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Transfer.Reshard.Coordinator.Traces

/-! # `Coordinator`: branch coverage of `CoordState.step` by the replayed tests

Part of `TpuSyncVerify.Transfer.Reshard.Coordinator`. Built like
`Reshard/Registry/Coverage.lean`: `Leaf` names one leaf of an event's decision
tree, `stepT` is `step` with the leaf attached, `stepT_step` proves it is the same function, and the effect read
off a step is the coordinator phase before and after plus what an abort leaves
behind (`CoordEffect`). -/

namespace TpuSyncVerify.Transfer.Reshard.Coordinator

open TpuSyncVerify.Coverage (Instr insertNew sameSet)
open TpuSyncVerify.Transfer.Reshard.Registry

/-- One leaf of `step`'s decision tree per event. -/
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

/-- `step` with the leaf it took. -/
def stepT (s : CoordState) : Ev → Option (CoordState × Leaf)
  | .registerProducer u => (CoordState.step s (.registerProducer u)).map (·, .registerProducer)
  | .startPlan ok =>
    (CoordState.step s (.startPlan ok)).map (·, if ok then .startPlanOk else .startPlanFailed)
  | .armDstResult d ok =>
    (CoordState.step s (.armDstResult d ok)).map (·, if ok then .armOk else .armFail)
  | .finishArmBarrier =>
    (CoordState.step s .finishArmBarrier).map
      (·, if s.armFailed then .armBarrierAbort else .armBarrierDispatch)
  | .sendSrcResult u ok =>
    (CoordState.step s (.sendSrcResult u ok)).map fun s' =>
      (s', if !ok then .sendFail
           else if completedCount s' > completedCount s then .sendOkCompletes
           else .sendOk)
  | .finishSendBarrier =>
    (CoordState.step s .finishSendBarrier).map
      (·, if s.sendFailed then .sendBarrierAbort else .sendBarrierSucceeds)

/-- `stepT` is `step` with a tag. -/
theorem stepT_step (s : CoordState) (e : Ev) :
    (stepT s e).map (·.1) = CoordState.step s e := by
  cases e <;> simp [stepT, Option.map_map, Function.comp_def]

def instr : Instr CoordState Ev Leaf CoordEffect := { stepT, effect }

/-- Events for a one-source, one-destination sub-plan. -/
def checkEvents1 : List Ev :=
  [.registerProducer 0, .startPlan true, .startPlan false,
   .armDstResult 10 true, .armDstResult 10 false, .finishArmBarrier,
   .sendSrcResult 0 true, .sendSrcResult 0 false, .finishSendBarrier]

/-- Events for one source and two destinations. -/
def checkEvents12 : List Ev :=
  [.registerProducer 0, .startPlan true, .startPlan false,
   .armDstResult 10 true, .armDstResult 10 false,
   .armDstResult 11 true, .armDstResult 11 false, .finishArmBarrier,
   .sendSrcResult 0 true, .sendSrcResult 0 false, .finishSendBarrier]

/-- Events for two sources and one destination (the `FullPoolReshardFlow` shape). -/
def checkEvents21 : List Ev :=
  [.registerProducer 0, .registerProducer 1, .startPlan true, .startPlan false,
   .armDstResult 10 true, .armDstResult 10 false, .finishArmBarrier,
   .sendSrcResult 0 true, .sendSrcResult 0 false, .sendSrcResult 1 true, .sendSrcResult 1 false,
   .finishSendBarrier]

/-- The 1×1, 1×2, 2×1 and 2×2 sub-plans, each searched over its own events. -/
def inits : List (CoordState × List Ev) :=
  [(CoordState.init [0] [10] 101, checkEvents1),
   (CoordState.init [0] [10, 11] 101, checkEvents12),
   (CoordState.init [0, 1] [10] 101, checkEvents21),
   (CoordState.init [0, 1] [10, 11] 101, checkEvents)]

def allBranches : Option (List Branch) :=
  inits.foldlM (fun acc (i, evs) =>
    (Coverage.reachableBranches instr i evs 64).map (·.foldl insertNew acc)) []

/-! ## Traces

`paired` lists every `ReshardStackTest` case in `reshard_service_test.cc` that
drives a single `RunSubPlan` within scope (`index == 0`, `plan.src_units =
request.src_units`), with the sub-plan shape and the trace each replays. The
tests run `ReshardService` over a fake control transport: an arm or dispatch
RPC succeeds or is refused by `transport_.FailFor`, and no worker ever votes
`Complete` during `Coordinate`, whereas `sendSrcResult _ true` folds the
worker's vote in (the coordinator model's abstraction of the data plane); the
pairing is at the coordinator's own transitions. `refused` lists the pre-claim
refusal asserted, and `notReplayable` accounts for the remaining tests in
`reshard_service_test.cc`. -/

def tr_full_flow_1x1 : List Ev :=
  [.registerProducer 0, .startPlan true, .armDstResult 10 true, .finishArmBarrier,
   .sendSrcResult 0 true, .finishSendBarrier]
def tr_full_flow_1x2 : List Ev :=
  [.registerProducer 0, .startPlan true, .armDstResult 10 true, .armDstResult 11 true,
   .finishArmBarrier, .sendSrcResult 0 true, .finishSendBarrier]
def tr_full_flow_2x1 : List Ev :=
  [.registerProducer 0, .registerProducer 1, .startPlan true, .armDstResult 10 true,
   .finishArmBarrier, .sendSrcResult 0 true, .sendSrcResult 1 true, .finishSendBarrier]
def tr_arm_failure_1x1 : List Ev :=
  [.registerProducer 0, .startPlan true, .armDstResult 10 false, .finishArmBarrier]
def tr_arm_failure_2x1 : List Ev :=
  [.registerProducer 0, .registerProducer 1, .startPlan true, .armDstResult 10 false,
   .finishArmBarrier]
def tr_plan_refused_1x1 : List Ev := [.registerProducer 0, .startPlan false]
def tr_plan_refused_1x2 : List Ev := [.registerProducer 0, .startPlan false]
def tr_plan_refused_2x2 : List Ev := [.registerProducer 0, .registerProducer 1, .startPlan false]
def tr_send_failure_2x1 : List Ev :=
  [.registerProducer 0, .registerProducer 1, .startPlan true, .armDstResult 10 true,
   .finishArmBarrier, .sendSrcResult 0 false, .sendSrcResult 1 true, .finishSendBarrier]

/-- `(upstream test, initial state, trace)`. -/
def paired : List (String × CoordState × List Ev) :=
  [("ReshardStackTest.FullPoolReshardFlowEmitsArmThenDispatch", CoordState.init [0, 1] [10] 101,
     tr_full_flow_2x1),
   ("ReshardStackTest.GlobalSpaceSpansSplitAtPageBoundaries", CoordState.init [0, 1] [10] 101,
     tr_full_flow_2x1),
   ("ReshardStackTest.ClipDropsTrimsAndRebasesGlobalSpans", CoordState.init [0, 1] [10] 101,
     tr_full_flow_2x1),
   -- 3rd call (`SplitGlobalSpaceSpans` removing the entire tag after `LookupAndClaim`)
   -- abandons the claim; 4th call (`dst_skip = {0}`) coordinates 1×1 end-to-end.
   ("ReshardStackTest.ClipValidationFailsClosed", CoordState.init [0] [10] 101,
     tr_plan_refused_1x1),
   ("ReshardStackTest.ClipValidationFailsClosed", CoordState.init [0] [10] 101,
     tr_full_flow_1x1),
   ("ReshardStackTest.ClipRejectsPageIndexedDeclarations", CoordState.init [0] [10] 101,
     tr_plan_refused_1x1),
   ("ReshardStackTest.ArmFailureAbandonsClaimAndSkipsSenders", CoordState.init [0] [10] 101,
     tr_arm_failure_1x1),
   ("ReshardStackTest.ArmFailureAbandonsClaimAndSkipsSenders", CoordState.init [0] [10] 101,
     tr_full_flow_1x1),
   ("ReshardStackTest.RequestBlockStatusProbeTracksLifecycle", CoordState.init [0, 1] [10] 101,
     tr_full_flow_2x1),
   ("ReshardStackTest.CompletionVotesRetireAfterClaim", CoordState.init [0, 1] [10] 101,
     tr_full_flow_2x1),
   ("ReshardStackTest.TwoDestinationsArmEachThenDispatchSendersOnce",
     CoordState.init [0, 1] [10, 11] 101, coordinatorHappyTrace),
   ("ReshardStackTest.SubsetSourceManifestsPairPoolsByTag", CoordState.init [0, 1] [10] 101,
     tr_full_flow_2x1),
   ("ReshardStackTest.SourceTagsAbsentOnTheDestinationAreIgnored", CoordState.init [0] [10] 101,
     tr_full_flow_1x1),
   -- 3rd call (`unique_peers` duplicate endpoint check after `LookupAndClaim`)
   -- abandons the claim; 4th call coordinates 1×2 end-to-end.
   ("ReshardStackTest.MismatchedDestinationsFailClosed", CoordState.init [0] [10, 11] 101,
     tr_plan_refused_1x2),
   ("ReshardStackTest.MismatchedDestinationsFailClosed", CoordState.init [0] [10, 11] 101,
     tr_full_flow_1x2),
   ("ReshardStackTest.TwoDestinationsShardedSpansRouteBytesPerReceiver",
     CoordState.init [0, 1] [10, 11] 101, coordinatorHappyTrace),
   ("ReshardStackTest.StridedGlobalSpansStayOneEntryPerDestination",
     CoordState.init [0, 1] [10, 11] 101, coordinatorHappyTrace),
   ("ReshardStackTest.StridedGlobalSpansMustStayInsideOnePage",
     CoordState.init [0] [10, 11] 101, tr_plan_refused_1x2),
   -- `ValidateSpanCoverage` refuses the plan after `LookupAndClaim`; no arm is
   -- sent (`transport_.calls_.empty()`).
   ("ReshardStackTest.ShardedDestinationWithoutCoverageFailsClosed",
     CoordState.init [0, 1] [10, 11] 101, tr_plan_refused_2x2),
   ("ReshardStackTest.ShardedSpanOrdinalOutOfRangeFailsClosed",
     CoordState.init [0, 1] [10, 11] 101, tr_plan_refused_2x2),
   ("ReshardStackTest.ShardedNonUniformExtentsFailClosed",
     CoordState.init [0, 1] [10, 11] 101, tr_plan_refused_2x2),
   ("ReshardStackTest.ReplicatedAndRoutedSpansCombine",
     CoordState.init [0, 1] [10, 11] 101, coordinatorHappyTrace),
   ("ReshardStackTest.UnsetTransferStreamsPlansOneStreamPerSourceRank",
     CoordState.init [0, 1] [10] 101, tr_full_flow_2x1),
   ("ReshardStackTest.TransferStreamsEnvCapsPlanStreamsAndExpectedPushes",
     CoordState.init [0, 1] [10] 101, tr_full_flow_2x1),
   ("ReshardStackTest.DuplicateRegistrationRefreshesTtlWhileConflictsAndPostClaimWritesFail",
     CoordState.init [0] [10] 101, tr_full_flow_1x1),
   ("ReshardStackTest.CompletionNoOpsAndPreClaimGuard", CoordState.init [0] [10] 101,
     tr_full_flow_1x1),
   ("ReshardStackTest.ForcedReleaseClearsEveryLifecycleState", CoordState.init [0] [10] 101,
     tr_full_flow_1x1),
   -- Destination 11 (`10.0.0.2:9601`) refuses while 10 arms; the arms are joined
   -- before the verdict and their order is unspecified (the other order reaches
   -- `armFail` before any destination is armed). The retry, after the abandoned
   -- claim, coordinates 2×2 end-to-end.
   ("ReshardStackTest.TwoDestinationsOneArmRefusalAbandonsClaimAndSkipsSenders",
     CoordState.init [0, 1] [10, 11] 101, partialArmFailureTrace),
   ("ReshardStackTest.TwoDestinationsOneArmRefusalAbandonsClaimAndSkipsSenders",
     CoordState.init [0, 1] [10, 11] 101, coordinatorHappyTrace),
   -- Sender 0 (`10.0.0.1:9100`) fails after the one arm; both dispatches are
   -- joined before the first failure is reported.
   ("ReshardStackTest.SenderDispatchFailurePropagatesErrorAfterReceiverArm",
     CoordState.init [0, 1] [10] 101, tr_send_failure_2x1)]

/-- `(upstream test, initial state, trace, refused event)`:
`ReshardStackTest.MissingRegistrationKeepsContractString` plans with no producer
registered, and `LookupAndClaim` refuses the claim before anything else happens. -/
def refused : List (String × CoordState × List Ev × Ev) :=
  [("ReshardStackTest.MissingRegistrationKeepsContractString", CoordState.init [0] [10] 101, [],
     .startPlan true)]

/-- Remaining tests in `reshard_service_test.cc` outside the single-`RunSubPlan`
(`index == 0`, `plan.src_units = request.src_units`) coordinator scope. -/
def notReplayable : List (String × String) :=
  [("ReshardStackTest.WindowedRequestChainsOneSubTransferPerWindow",
      "multi-window chain (chain.count = 4, StartChain); registry claim replayed in Registry/Coverage.lean"),
   ("ReshardStackTest.WindowClipsStraddlingSpansAtWindowBoundaries",
      "multi-window chain (chain.count = 2, StartChain); registry claim replayed in Registry/Coverage.lean"),
   ("ReshardStackTest.WindowComposesWithPrefixClip",
      "multi-window chain (chain.count = 2, StartChain); registry claim replayed in Registry/Coverage.lean"),
   ("ReshardStackTest.ChainedArmRetriesWhileReceiverStagingIsBusy",
      "multi-window chain (index > 0 arm-busy retry loop); registry claim replayed in Registry/Coverage.lean"),
   ("ReshardStackTest.ChainedRequestStaysInProgressUntilTheChainEnds",
      "multi-window chain (StartChain transfer_status_ lifecycle); registry claim replayed in Registry/Coverage.lean"),
   ("ReshardStackTest.ChainedArmFailureMarksTheTransferFailed",
      "multi-window chain (index > 0 arm failure without AbandonClaim); registry claim replayed in Registry/Coverage.lean"),
   ("ReshardStackTest.PipelinedDestinationStagesShareOneRequestClaim",
      "pipelined stage filters plan.src_units to 1 of 2 claimed request.src_units; shared claim replayed in Registry/Coverage.lean"),
   ("ReshardStackTest.AbandonedStageLeavesTheSiblingClaimInPlace",
      "same pipelined plan.src_units ⊊ request.src_units filter on stage 0 and stage 1's retry; multi-owner claim rollback replayed in Registry/Coverage.lean"),
   ("ReshardStackTest.AbandoningTheLastStageFreesTheClaim",
      "same pipelined plan.src_units ⊊ request.src_units filter on both refused stages; last-owner claim release replayed in Registry/Coverage.lean"),
   ("ReshardStackTest.StridedGlobalSpansClipByWholePages",
      "prefix clip drops rank 0's page whole so plan.src_units ⊊ request.src_units; registry claim replayed in Registry/Coverage.lean"),
   ("ReshardStackTest.ExplicitPlanParallelismOverridesTransferStreamsEnv",
      "calls BuildPoolReshardPlan directly without ReshardCoordinator (Reshard/Coverage.lean, Registry/Coverage.lean)"),
   ("ReshardStackTest.InvalidTransferStreamsEnvFailsThePlan",
      "calls BuildPoolReshardPlan directly and fails in DefaultTransferStreams before LookupAndClaim (Reshard/Coverage.lean)"),
   ("ReshardStackTest.CancelTombstoneBlocksLateRegistration",
      "registry controller commands only; no Coordinate call (Registry/Coverage.lean)"),
   ("ReshardStackTest.TtlPurgesExpiredRegistrations",
      "advances clock past TTL before Coordinate (purgeExpiredAll in Registry/Coverage.lean)"),
   ("ReshardStackTest.SpansForAnUnregisteredTagAreRefusedAtRegistration",
      "registration-time input validation only; no Coordinate call"),
   ("ReshardStackTest.NegativeOrdinalRejectedAtRegistration",
      "registration-time input validation only; no Coordinate call"),
   ("ReshardStackTest.LegacyCommandsFailClosed",
      "controller-side retired inter-controller COMMAND_REGISTER_TRANSFER_SCHEDULE rejection; no Coordinate call"),
   ("ReshardStackTest.IncompatibleClaimUnitSetAndNonOwnerAbandonPreserveClaim",
      "RequestBlockRegistry::LookupAndClaim / AbandonClaim called directly; no Coordinate call (Registry/Coverage.lean)"),
   ("ReshardStackTest.EmptyRegistrationCompletesBeforeClaimAndRetiresOnClaim",
      "registry controller commands and a direct LookupAndClaim; no Coordinate call (Registry/Coverage.lean)"),
   ("ReshardControlPipeTest.* (3 tests)", "control-pipe transport round-trip only"),
   ("PlanSubTransfersTest.* (5 tests)", "pure PlanSubTransfers window-splitting unit tests"),
   ("SubPlanUuidTest.DerivedUuidsArePositiveAndDistinct", "pure SubPlanUuid helper unit test")]

/-- The trace no upstream test drives: the 2×2 sender-dispatch failure of
`Traces.lean` (its 2×1 form is
`ReshardStackTest.SenderDispatchFailurePropagatesErrorAfterReceiverArm`). -/
def modelOnly : List (String × CoordState × List Ev) :=
  [("dispatchFailureTrace", CoordState.init [0, 1] [10, 11] 101, dispatchFailureTrace)]

-- Every paired trace runs to its end; the refusal is refused.
#guard paired.all fun (_, s, tr) => ((CoordState.sys s.srcUnits s.dstUnits s.claimOwner).run tr).isSome
#guard refused.all fun (_, s, tr, e) =>
  ((CoordState.sys s.srcUnits s.dstUnits s.claimOwner).run tr).bind
    (fun s' => CoordState.step s' e) == none

/-! ## Result

The four searches exhaust their state spaces: **14 branches**, every leaf of
`Leaf` reachable. The 26 tests in `paired` (30 traces) reach **all 14**: the
two failure-cleanup counterexamples of `Traces.lean` are driven by
`ReshardStackTest.TwoDestinationsOneArmRefusalAbandonsClaimAndSkipsSenders`
(`transport_.FailFor` on the second destination's control address: `armFail`
beside an armed destination and `armBarrierAbort` leaving it armed) and
`ReshardStackTest.SenderDispatchFailurePropagatesErrorAfterReceiverArm` (a
failed sender reply after the arm: `sendFail` and `sendBarrierAbort`, the
registry still claimed). -/

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, s, tr) => (s, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

/-- Branches of the universe no paired trace reaches: none. -/
def gaps : List Branch := []

def allLeaves : List Leaf :=
  [.registerProducer, .startPlanOk, .startPlanFailed, .armOk, .armFail, .armBarrierDispatch,
   .armBarrierAbort, .sendOk, .sendOkCompletes, .sendFail, .sendBarrierSucceeds, .sendBarrierAbort]

/-- One search, every check: the state spaces are exhausted; 14 branches, all
reached by paired traces; every leaf fires. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let uncovered := univ.filter (fun b => !coveredByPaired.contains b)
    univ.length = 14 ∧ coveredByPaired.length = 14 ∧ coveredByAll.length = 14 ∧
    coveredByPaired.all univ.contains ∧
    sameSet uncovered gaps ∧
    allLeaves.all (fun l => univ.any (·.1 = l)) ∧
    modelOnly.all (fun (_, s, tr) => ((CoordState.sys s.srcUnits s.dstUnits s.claimOwner).run tr).isSome)

#guard coverageChecks

end TpuSyncVerify.Transfer.Reshard.Coordinator
