import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Transfer.Reshard.SubPlanChain.Traces

/-! # `SubPlanChain`: branch coverage of `WorkerState.step` and `CoordChainState.step` by the replayed tests

Part of `TpuSyncVerify.Transfer.Reshard.SubPlanChain`. Built like
`Reshard/Coordinator/Coverage.lean`: a `Leaf` per arm of each event's decision
tree, `stepT` as `step` with the leaf attached (`stepT_step`), and an effect
read off the states before and after. The worker's `poll` visits one arm of
`RecordPoolReshardTerminalLocked` per settled session and one of
`SweepSubPlanChainsLocked`; its leaf is the set of arms visited, computed by
the same `recordTerminal` and `sweepStalledChain` the step runs. -/

namespace TpuSyncVerify.Transfer.Reshard.SubPlanChain

open TpuSyncVerify.Coverage (Instr insertNew sameSet)
open TpuSyncVerify.Transfer.Reshard.Coordinator (CoordPhase)
open TpuSyncVerify.Transfer.Reshard.Registry (RegGen)

/-! ## Worker -/

namespace WorkerCov

inductive PollArmTag
  | singleDone | singleFailed | superseded | alreadyFailed | settledPartial | chainDone | chainFailed
  deriving Repr, DecidableEq

/-- Arms of `RecordPoolReshardTerminalLocked` visited by one `CompleteReadWithDetails`. -/
structure PollArms where
  /-- `sub_plan_count <= 1`, `status.ok()`. -/
  singleDone : Bool := false
  /-- `sub_plan_count <= 1`, `!status.ok()`. -/
  singleFailed : Bool := false
  /-- `anchored && !plan_uuids.contains(uuid)`. -/
  superseded : Bool := false
  /-- `if (progress.failed) return;` -/
  alreadyFailed : Bool := false
  /-- `settled.insert(sub_plan_index)` short of `count`. -/
  settledPartial : Bool := false
  /-- `done.insert(req_id); chains.erase(req_id)`. -/
  chainDone : Bool := false
  /-- `progress.failed = true; failed_recving_.insert(req_id)`. -/
  chainFailed : Bool := false
  deriving Repr, DecidableEq

def PollArms.mark (a : PollArms) (s : SubSession) (t : Terminal) : PollArms :=
  if s.count <= 1 then
    match t with
    | .done _ _ => { a with singleDone := true }
    | _ => { a with singleFailed := true }
  else
    match t with
    | .supersededIgnored => { a with superseded := true }
    | .failedIgnored => { a with alreadyFailed := true }
    | .settledPartial => { a with settledPartial := true }
    | .done _ _ => { a with chainDone := true }
    | .failed => { a with chainFailed := true }

/-- The arms one poll visits, by the same fold as `WorkerState.recordAll`. -/
def pollArms (c : ChainProgress) (settled : List SubSession) : PollArms :=
  (settled.foldl (fun (acc : ChainProgress × PollArms) s =>
    let (c', t) := recordTerminal acc.1 s
    (c', acc.2.mark s t)) (c, {})).2

inductive Leaf
  | register (arm : RegisterArm)
  | settle (ok : Bool)
  | poll (arms : PollArms) (sweep : SweepOutcome)
  deriving Repr, DecidableEq

/-- `chains_[req_id]` as the tests observe it. -/
inductive Entry
  | absent
  | live (anchored : Bool)
  | failed
  deriving Repr, DecidableEq

def entry (c : ChainProgress) : Entry :=
  if !c.present then .absent else if c.failed then .failed else .live c.anchored

structure Effect where
  before : Entry
  after : Entry
  /-- `done_*.insert(req_id)` happened. -/
  reportsDone : Bool
  /-- `failed_recving_.insert(req_id)` happened. -/
  reportsFailed : Bool
  deriving Repr, DecidableEq

def effect (w w' : WorkerState) : Effect :=
  { before := entry w.chain, after := entry w'.chain,
    reportsDone := w'.doneReports > w.doneReports,
    reportsFailed := w'.failReports > w.failReports }

abbrev Branch := Leaf × Effect

/-- One arm of one C++ decision tree, the unit coverage is counted in: a `poll`
leaf carries the set of arms it visited. -/
inductive Arm
  | register (arm : RegisterArm)
  | settle (ok : Bool)
  | record (arm : PollArmTag)
  | sweep (outcome : SweepOutcome)
  deriving Repr, DecidableEq

def armsOfLeaf : Leaf → List Arm
  | .register a => [.register a]
  | .settle ok => [.settle ok]
  | .poll a sw =>
    (if a.singleDone then [.record .singleDone] else []) ++
    (if a.singleFailed then [.record .singleFailed] else []) ++
    (if a.superseded then [.record .superseded] else []) ++
    (if a.alreadyFailed then [.record .alreadyFailed] else []) ++
    (if a.settledPartial then [.record .settledPartial] else []) ++
    (if a.chainDone then [.record .chainDone] else []) ++
    (if a.chainFailed then [.record .chainFailed] else []) ++
    [.sweep sw]

def armsOf (bs : List Branch) : List Arm :=
  (bs.flatMap fun b => armsOfLeaf b.1).foldl (fun acc a => if acc.contains a then acc else acc ++ [a]) []

def stepT (w : WorkerState) : WorkerEv → Option (WorkerState × Leaf)
  | .registerSubPlan u i c =>
    (WorkerState.step w (.registerSubPlan u i c)).map
      (·, .register (noteSubPlanRegistered w.chain u i c).2)
  | .settleSession u ok => (WorkerState.step w (.settleSession u ok)).map (·, .settle ok)
  | .poll stalled =>
    (WorkerState.step w (.poll stalled)).map fun w' =>
      let settledNow := w.active.filter (·.done)
      let stillActive := w.active.filter (!·.done)
      let c1 := (WorkerState.recordAll w.chain settledNow).1
      let sweep := if stalled then (sweepStalledChain c1 stillActive).2 else .notSwept
      (w', .poll (pollArms w.chain settledNow) sweep)

theorem stepT_step (w : WorkerState) (e : WorkerEv) :
    (stepT w e).map (·.1) = WorkerState.step w e := by
  cases e <;> simp [stepT, Option.map_map, Function.comp_def]

def instr : Instr WorkerState WorkerEv Leaf Effect := { stepT, effect }

/-- A single-plan request, settling either way. -/
def singleEvents : List WorkerEv :=
  [.registerSubPlan 20 0 1, .settleSession 20 true, .settleSession 20 false, .poll false, .poll true]

def inits : List (WorkerState × List WorkerEv) :=
  [(WorkerState.init, workerCheckEvents), (WorkerState.init, singleEvents)]

def allBranches : Option (List Branch) :=
  inits.foldlM (fun acc (i, evs) =>
    (Coverage.reachableBranches instr i evs 64).map (·.foldl insertNew acc)) []

/-! ### Traces -/

def tr_waits_for_last : List WorkerEv :=
  [ .registerSubPlan 5001 0 3, .settleSession 5001 true, .poll false,
    .registerSubPlan 5003 2 3, .settleSession 5003 true, .poll false,
    .registerSubPlan 5002 1 3, .settleSession 5002 true, .poll false, .poll false ]
def tr_first_failure_once : List WorkerEv :=
  [ .registerSubPlan 5011 0 2, .settleSession 5011 false, .poll false,
    .registerSubPlan 5012 1 2, .settleSession 5012 true, .poll false ]
def tr_retry_new_chain : List WorkerEv :=
  [ .registerSubPlan 6001 0 2, .settleSession 6001 false, .poll false,
    .registerSubPlan 6002 1 2, .registerSubPlan 7001 0 2,
    .settleSession 6002 true, .poll false, .settleSession 7001 true, .poll false,
    .registerSubPlan 7002 1 2, .settleSession 7002 true, .poll false ]
def tr_stalled : List WorkerEv :=
  [ .registerSubPlan 5021 0 2, .settleSession 5021 true, .poll false, .poll true ]
def tr_single : List WorkerEv :=
  [ .registerSubPlan 5031 0 1, .settleSession 5031 true, .poll false ]

def tr_sender_first_window_only : List WorkerEv :=
  [ .registerSubPlan 9000 0 2, .settleSession 9000 true, .poll false, .poll true ]
def tr_sender_last_window_only : List WorkerEv :=
  [ .registerSubPlan 9001 1 2, .settleSession 9001 true, .poll false, .poll true ]
def tr_failure_while_sibling_active : List WorkerEv :=
  [ .registerSubPlan 7100 0 2, .registerSubPlan 7101 1 2, .settleSession 7100 false, .poll false ]
def tr_late_sub_plan_twice : List WorkerEv :=
  [ .registerSubPlan 7300 0 2, .settleSession 7300 false, .poll false, .poll true,
    .registerSubPlan 7301 1 2, .settleSession 7301 true, .poll false, .poll true ]

/-- The `SubPlanChainTest` cases of `pool_reshard_test.cc`, each with the trace
of `Traces.lean` that replays it. -/
def paired : List (String × List WorkerEv) :=
  [("SubPlanChainTest.ReceiveTerminalWaitsForTheLastSubPlan", tr_waits_for_last),
   ("SubPlanChainTest.FirstSubPlanFailureFailsTheRequestOnce", tr_first_failure_once),
   ("SubPlanChainTest.RetryUnderTheSameReqIdIsTrackedAsANewChain", tr_retry_new_chain),
   ("SubPlanChainTest.StalledChainFailsAfterTheTransferTimeout", tr_stalled),
   ("SubPlanChainTest.SinglePlanRequestsReportAtOnce", tr_single)]

/-- Shipping behaviours shown only by `Traces.lean`. -/
def modelOnly : List (String × List WorkerEv) :=
  [("trace_sender_in_first_window_only", tr_sender_first_window_only),
   ("trace_sender_in_last_window_only", tr_sender_last_window_only),
   ("trace_first_failure_reports_while_sibling_active", tr_failure_while_sibling_active),
   ("trace_late_sub_plan_after_sweep_reports_failure_twice", tr_late_sub_plan_twice)]

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, tr) => (WorkerState.init, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, tr) => (WorkerState.init, tr))

end WorkerCov

/-! ## Coordinator -/

namespace CoordCov

inductive Leaf
  | registerProducer
  | startChain
  /-- `LookupAndClaim` refused: abort before planning. -/
  | planClaimRefused
  | planOk
  /-- `BuildPoolReshardPlan` refused. -/
  | planFailed
  | armOk
  | armRefusedBusy
  | armFailed
  /-- `retry = true`: re-arm the unarmed destinations. -/
  | rearm
  | armBarrierDispatch
  /-- `return arm_status[i]` at `index == 0`: `AbandonClaim`. -/
  | armBarrierAbortAbandons
  /-- `return arm_status[i]` at `index >= 1`: claim kept. -/
  | armBarrierAbortKeepsClaim
  | sendOk
  | sendFail
  | sendBarrierAbort
  | sendBarrierNextWindow
  | sendBarrierCompleted
  | recvSettles
  | voteKeepsClaim
  | voteRetires
  /-- `CancelIfUnclaimed` on a claimed generation: `false`, no change. -/
  | cancelRefused
  | cancelTombstones
  deriving Repr, DecidableEq

structure Effect where
  before : CoordPhase
  after : CoordPhase
  status : TransferStatus
  claimHeld : Bool
  deriving Repr, DecidableEq

def effect (s s' : CoordChainState) : Effect :=
  { before := s.winPhase, after := s'.winPhase, status := s'.transferStatus,
    claimHeld := s'.reg.claimedUnits.isSome }

abbrev Branch := Leaf × Effect

def stepT (s : CoordChainState) : ChainEv → Option (CoordChainState × Leaf)
  | .registerProducer u => (CoordChainState.step s (.registerProducer u)).map (·, .registerProducer)
  | .startChainCoordination => (CoordChainState.step s .startChainCoordination).map (·, .startChain)
  | .startWindowPlan ok =>
    (CoordChainState.step s (.startWindowPlan ok)).map
      (·, if (RegGen.step s.reg (.lookupAndClaim s.claimOwner s.allSrcUnits)).isNone then .planClaimRefused
          else if ok then .planOk else .planFailed)
  | .armDstResult d o =>
    (CoordChainState.step s (.armDstResult d o)).map
      (·, match o with | .ok => .armOk | .refusedBusy => .armRefusedBusy | .failed => .armFailed)
  | .retryBusyArm => (CoordChainState.step s .retryBusyArm).map (·, .rearm)
  | .finishWindowArm =>
    (CoordChainState.step s .finishWindowArm).map
      (·, if !anyArmFailed s.armResults then .armBarrierDispatch
          else if s.winIdx == 0 then .armBarrierAbortAbandons else .armBarrierAbortKeepsClaim)
  | .sendSrcResult u ok =>
    (CoordChainState.step s (.sendSrcResult u ok)).map (·, if ok then .sendOk else .sendFail)
  | .finishWindowSend =>
    (CoordChainState.step s .finishWindowSend).map
      (·, if anySendFailed s.sendResults then .sendBarrierAbort
          else if s.winIdx + 1 < s.winSrcUnits.length then .sendBarrierNextWindow
          else .sendBarrierCompleted)
  | .settleDispatchedRecv d => (CoordChainState.step s (.settleDispatchedRecv d)).map (·, .recvSettles)
  | .senderVoteComplete u =>
    (CoordChainState.step s (.senderVoteComplete u)).map fun s' =>
      (s', if s'.reg.retired && !s.reg.retired then .voteRetires else .voteKeepsClaim)
  | .cancelIfUnclaimed =>
    (CoordChainState.step s .cancelIfUnclaimed).map fun s' =>
      (s', if s'.reg.cancelled && !s.reg.cancelled then .cancelTombstones else .cancelRefused)

theorem stepT_step (s : CoordChainState) (e : ChainEv) :
    (stepT s e).map (·.1) = CoordChainState.step s e := by
  cases e <;> simp [stepT, Option.map_map, Function.comp_def]

def instr : Instr CoordChainState ChainEv Leaf Effect := { stepT, effect }

def inits : List (CoordChainState × List ChainEv) :=
  [(CoordChainState.init [0, 1] [[0], [1]] [10] 1, coordCheckEvents),
   (CoordChainState.init [0, 1] [[0, 1], [1]] [10] 1, coordCheckEvents)]

def allBranches : Option (List Branch) :=
  inits.foldlM (fun acc (i, evs) =>
    (Coverage.reachableBranches instr i evs 64).map (·.foldl insertNew acc)) []

/-! ### Traces -/

def tr_four_windows : List ChainEv :=
  [ .registerProducer 0, .registerProducer 1, .startChainCoordination,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 0 true, .finishWindowSend, .settleDispatchedRecv 10,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 0 true, .finishWindowSend, .settleDispatchedRecv 10,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 1 true, .finishWindowSend, .settleDispatchedRecv 10,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 1 true, .finishWindowSend ]
def tr_straddling : List ChainEv :=
  [ .registerProducer 0, .registerProducer 1, .startChainCoordination,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 0 true, .sendSrcResult 1 true, .finishWindowSend, .settleDispatchedRecv 10,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 1 true, .finishWindowSend ]
def tr_prefix_clip : List ChainEv :=
  [ .registerProducer 0, .registerProducer 1, .startChainCoordination,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 0 true, .sendSrcResult 1 true, .finishWindowSend,
    .settleDispatchedRecv 10, .senderVoteComplete 0,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 1 true, .finishWindowSend, .senderVoteComplete 1 ]
def tr_busy_retries : List ChainEv :=
  [ .registerProducer 0, .registerProducer 1, .startChainCoordination,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 0 true, .finishWindowSend,
    .startWindowPlan true, .armDstResult 10 .refusedBusy, .retryBusyArm,
    .armDstResult 10 .refusedBusy, .retryBusyArm, .settleDispatchedRecv 10,
    .armDstResult 10 .ok, .finishWindowArm, .sendSrcResult 1 true, .finishWindowSend ]
def tr_stays_in_progress : List ChainEv :=
  [ .registerProducer 0, .registerProducer 1, .startChainCoordination,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 0 true, .finishWindowSend, .settleDispatchedRecv 10,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 1 true, .finishWindowSend ]
def tr_arm_failure_window1 : List ChainEv :=
  [ .registerProducer 0, .registerProducer 1, .startChainCoordination,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 0 true, .finishWindowSend, .settleDispatchedRecv 10,
    .startWindowPlan true, .armDstResult 10 .failed, .finishWindowArm ]
def tr_busy_exhausts : List ChainEv :=
  [ .registerProducer 0, .registerProducer 1, .startChainCoordination,
    .startWindowPlan true, .armDstResult 10 .ok, .finishWindowArm,
    .sendSrcResult 0 true, .finishWindowSend,
    .startWindowPlan true, .armDstResult 10 .refusedBusy, .retryBusyArm,
    .armDstResult 10 .refusedBusy, .finishWindowArm ]
def tr_claim_past_vote : List ChainEv :=
  tr_arm_failure_window1 ++ [ .senderVoteComplete 0, .cancelIfUnclaimed ]

/-- The windowed `ReshardStackTest` cases of `reshard_service_test.cc`. -/
def paired : List (String × CoordChainState × List ChainEv) :=
  [("ReshardStackTest.WindowedRequestChainsOneSubTransferPerWindow",
      CoordChainState.init [0, 1] [[0], [0], [1], [1]] [10] 1, tr_four_windows),
   ("ReshardStackTest.WindowClipsStraddlingSpansAtWindowBoundaries",
      CoordChainState.init [0, 1] [[0, 1], [1]] [10] 1, tr_straddling),
   ("ReshardStackTest.WindowComposesWithPrefixClip",
      CoordChainState.init [0, 1] [[0, 1], [1]] [10] 1, tr_prefix_clip),
   ("ReshardStackTest.ChainedArmRetriesWhileReceiverStagingIsBusy",
      CoordChainState.init [0, 1] [[0], [1]] [10] 1 4, tr_busy_retries),
   ("ReshardStackTest.ChainedRequestStaysInProgressUntilTheChainEnds",
      CoordChainState.init [0, 1] [[0], [1]] [10] 1, tr_stays_in_progress),
   ("ReshardStackTest.ChainedArmFailureMarksTheTransferFailed",
      CoordChainState.init [0, 1] [[0], [1]] [10] 1, tr_arm_failure_window1)]

/-- Replayed as theorems about the planner functions rather than as traces. -/
def notReplayable : List (String × String) :=
  [("PlanSubTransfersTest.* (5 tests)", "pure `planSubTransfers` checks; `trace_plan_*` in Traces.lean"),
   ("SubPlanUuidTest.DerivedUuidsArePositiveAndDistinct",
      "pure `subPlanUuid` check; `trace_sub_plan_uuid_positive_and_distinct`")]

def modelOnly : List (String × CoordChainState × List ChainEv) :=
  [("trace_busy_refusals_exhaust_arm_attempts",
      CoordChainState.init [0, 1] [[0], [1]] [10] 1, tr_busy_exhausts),
   ("trace_chained_arm_failure_keeps_claim_past_last_vote",
      CoordChainState.init [0, 1] [[0], [1]] [10] 1, tr_claim_past_vote)]

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, s, tr) => (s, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

end CoordCov

/-! ## Result

Both searches exhaust their state spaces. Coverage is counted per **arm** of
the C++ decision trees (a worker `poll` visits several; the coordinator's
environment events — `settleDispatchedRecv`, `senderVoteComplete`,
`cancelIfUnclaimed` — are enabled in every phase, so counting `Leaf × Effect`
would repeat each of them once per phase).

**Worker** (`NoteSubPlanRegisteredLocked`, `RecordPoolReshardTerminalLocked`,
`SweepSubPlanChainsLocked`): **17 arms**, every constructor reachable. The 5
`SubPlanChainTest` cases reach **13**; the four `modelOnly` traces reach two
more. The four the tests miss:

| Arm | Schedule | What it would take |
|---|---|---|
| `register unanchored` | `registerSubPlan 11 1 2` first | a sub-plan `index >= 1` seated before sub-plan 0 (a sender absent from window 0; `trace_sender_in_last_window_only`) |
| `record singleFailed` | `registerSubPlan 20 0 1, settleSession 20 false, poll` | a failing single-plan session through `CompleteReadWithDetails` |
| `sweep activeKeeps` | `registerSubPlan 10 0 2, poll true` | the stall sweep while a session of the request is still active |
| `sweep erasedFailed` | `…, settleSession 10 false, poll false, poll true` | advancing the clock past `timeout_s_` after a reported failure (`trace_late_sub_plan_after_sweep_reports_failure_twice`) |

**Coordinator** (`StartPoolReshard`, `RunSubPlan` over `StartChain`): **22
leaves**, every constructor reachable. The 6 windowed `ReshardStackTest` cases
reach **15**; the two `modelOnly` traces reach one more. The seven the tests
miss:

| Leaf | Schedule | What it would take |
|---|---|---|
| `planClaimRefused`, `planFailed` | `…, finishWindowSend, startWindowPlan false` | a planner or `LookupAndClaim` refusal at window `>= 1` (window 0's are the single-window cases in `Coordinator/Coverage.lean`) |
| `armBarrierAbortAbandons` | `startWindowPlan true, armDstResult 10 .failed, finishWindowArm` | a window-0 arm failure; the single-window `ReshardStackTest` arm-failure cases replayed in `Coordinator/Coverage.lean` |
| `sendFail`, `sendBarrierAbort` | `…, finishWindowArm, sendSrcResult 0 false, finishWindowSend` | `transport_.FailFor` on a source rank after the arms succeed (the same gap as `Coordinator/Coverage.lean`) |
| `cancelRefused`, `cancelTombstones` | `cancelIfUnclaimed` in any phase | the producer's `CancelIfUnclaimed`; replayed against the registry in `Registry/Coverage.lean` (`trace_chained_arm_failure_keeps_claim_past_last_vote` reaches `cancelRefused`) |
-/

namespace WorkerCov

def gaps : List Arm :=
  [.register .unanchored, .record .singleFailed, .sweep .activeKeeps, .sweep .erasedFailed]

def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let arms := armsOf univ
    let covered := armsOf coveredByPaired
    let uncovered := arms.filter (fun a => !covered.contains a)
    arms.length = 17 ∧ covered.length = 13 ∧ (armsOf coveredByAll).length = 15 ∧
    covered.all arms.contains ∧
    uncovered.all gaps.contains ∧ gaps.all uncovered.contains ∧
    gaps.all (fun a => inits.any fun (i, evs) =>
      (Coverage.witnessP instr i evs (fun b => (armsOfLeaf b.1).contains a)).isSome) ∧
    (paired ++ modelOnly).all (fun (_, tr) => (WorkerState.sys.run tr).isSome)

#guard coverageChecks

end WorkerCov

namespace CoordCov

def gaps : List Leaf :=
  [.planClaimRefused, .planFailed, .armBarrierAbortAbandons, .sendFail, .sendBarrierAbort,
   .cancelRefused, .cancelTombstones]

def leavesOf (bs : List Branch) : List Leaf := (bs.map (·.1)).eraseDups

def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let leaves := leavesOf univ
    let covered := leavesOf coveredByPaired
    let uncovered := leaves.filter (fun l => !covered.contains l)
    leaves.length = 22 ∧ covered.length = 15 ∧ (leavesOf coveredByAll).length = 16 ∧
    covered.all leaves.contains ∧
    uncovered.all gaps.contains ∧ gaps.all uncovered.contains ∧
    gaps.all (fun l => inits.any fun (i, evs) =>
      (Coverage.witnessP instr i evs (fun b => b.1 = l)).isSome) ∧
    (paired ++ modelOnly).all (fun (_, s, tr) =>
      ((CoordChainState.sys s.allSrcUnits s.winSrcUnits s.dstUnits s.claimOwner s.maxArmAttempts).run tr).isSome)

#guard coverageChecks

end CoordCov

end TpuSyncVerify.Transfer.Reshard.SubPlanChain
