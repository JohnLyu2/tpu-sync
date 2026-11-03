import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Transfer.PrefillDecode.Pipeline.Coverage
import TpuSyncVerify.Transfer.PrefillDecode.LayerStaging.Traces

/-! # `LayerStaging`: branch coverage of `step` by the replayed tests

Part of `TpuSyncVerify.Transfer.PrefillDecode.LayerStaging`. Instruments `step`
with decision-tree leaves (`Leaf`) and lifecycle effects, proves `stepT_step`,
and verifies via `#guard` across the 95-branch 1-layer universe that every
memory move writes `.kvRight`, `.slotFault` is unreachable, and all 56 branches
outside `paired` partition with `0` unaccounted. -/

namespace TpuSyncVerify.Transfer.PrefillDecode.LayerStaging

open TpuSyncVerify.Coverage (Effect Instr insertNew sameSet)

inductive Leaf where
  | notifyForRead | pullWait
  | send (l : Send.Leaf) | recv (l : Recv.Leaf)
  | sendAcquireDraining | sendAcquireEnter
  | sendAcquireLeased | sendAcquireNoSlots | sendAcquireTimedOut | sendAcquireCancelled
  | sendD2hBeginDraining | sendD2hBeginOk
  | recvAcquireFirst | recvAcquireRepeat
  | recvAcquireLeased | recvAcquireIdempotent
  | recvAcquireNoSlots | recvAcquireTimedOut | recvAcquireCancelled
  | recvAcquireFinishDraining | recvAcquireFinishOk
  | h2dBeginDrainingSkip
  | d2hReady (m : Pipeline.Moved)
  | h2hDone (l : Send.Leaf) (m : Option Pipeline.Moved)
  | land (m : Pipeline.Moved)
  | h2dReady (m : Pipeline.Moved)
  | slotFault
  | reclaim | reseatPrefillStaging | reseatDecodeStaging
  deriving Repr, DecidableEq

def ofPipeLeaf : Pipeline.Leaf → Leaf
  | .notifyForRead => .notifyForRead | .pullWait => .pullWait
  | .send l => .send l | .recv l => .recv l
  | .d2hReady m => .d2hReady m | .h2hDone l m => .h2hDone l m
  | .h2dReady m => .h2dReady m | .land m => .land m
  | .reclaim => .reclaim
  | .reseatPrefillStaging => .reseatPrefillStaging
  | .reseatDecodeStaging => .reseatDecodeStaging

def effect (s s' : BoundedPipeline) : Effect :=
  Pipeline.effect s.pipe s'.pipe

abbrev Branch := Leaf × Effect

def slotLeaf {α : Type} (mgr : TpuSyncVerify.Transfer.StagingLayerManager)
    (slots : List α) (l : Nat) (k : Nat → Leaf) : Leaf :=
  match mgr.lookup l with
  | some slot => if slot < slots.length then k slot else .slotFault
  | none => .slotFault

def pipeStepT (s : BoundedPipeline) : Pipeline.Ev → Option (BoundedPipeline × Leaf)
  | .send .d2hBegin =>
    (sendD2hBegin s).map (·,
      if s.pipe.send.life.done || s.pipe.send.life.draining then .sendD2hBeginDraining
      else .sendD2hBeginOk)
  | .send (.d2hIssue ok) =>
    (Send.stepT s.pipe.send (.d2hIssue ok)).bind fun (_, sl) =>
      (sendD2hIssue s ok).map (·, .send sl)
  | .send (.wake ok) =>
    (Send.stepT s.pipe.send (.wake ok)).bind fun (_, sl) =>
      (sendWake s ok).map (·, .send sl)
  | .send .h2hIssue =>
    (Send.stepT s.pipe.send .h2hIssue).bind fun (_, sl) =>
      (sendH2hIssue s).map (·,
        if s.pipe.send.life.draining = true then .send sl
        else slotLeaf s.sendMgr s.prefillSlots s.pipe.send.h2hIssued fun _ => .send sl)
  | .d2hReady l =>
    (d2hReady s l).map (·, slotLeaf s.sendMgr s.prefillSlots l fun _ =>
      .d2hReady (Pipeline.moved (s.pipe.prefillHbm.getD l .junk) l))
  | .h2hDone l ok =>
    (Send.stepT s.pipe.send (.h2hDone ok)).bind fun (_, sl) =>
      (h2hDone s l ok).map (·,
        if ok then slotLeaf s.sendMgr s.prefillSlots l fun slot =>
          .h2hDone sl (some (Pipeline.moved (s.prefillSlots.getD slot .junk) l))
        else .h2hDone sl none)
  | .recv .pushBegin =>
    (Recv.stepT s.pipe.recv .pushBegin).bind fun (_, rl) =>
      (recvPushBegin s).map (·, .recv rl)
  | .recv .pushEnd =>
    (Recv.stepT s.pipe.recv .pushEnd).bind fun (_, rl) =>
      (recvPushEnd s).map (·, .recv rl)
  | .recv (.h2dDone _) => none
  | .land l =>
    (land s l).map (·, slotLeaf s.recvMgr s.decodeSlots l fun _ =>
      .land (Pipeline.moved (s.wireB.getD l .junk) l))
  | .h2dBegin l =>
    (h2dBegin s l).map (·, slotLeaf s.recvMgr s.decodeSlots l fun _ =>
      if s.pipe.recv.life.done || s.pipe.recv.life.draining then .h2dBeginDrainingSkip
      else .recv .h2dBegin)
  | .h2dIssue l ok =>
    (Recv.stepT s.pipe.recv (.h2dIssue ok)).bind fun (_, rl) =>
      (h2dIssue s l ok).map (·, .recv rl)
  | .h2dReady l =>
    (h2dReady s l).map (·, slotLeaf s.recvMgr s.decodeSlots l fun slot =>
      .h2dReady (Pipeline.moved (s.decodeSlots.getD slot .junk) l))
  | .reseatPrefillStaging => (pipeStep s .reseatPrefillStaging).map (·, .reseatPrefillStaging)
  | .reseatDecodeStaging => (pipeStep s .reseatDecodeStaging).map (·, .reseatDecodeStaging)
  | pe => (Pipeline.stepT s.pipe pe).map fun (p, pl) => (syncPipe s p, ofPipeLeaf pl)

def stepT (s : BoundedPipeline) : Ev → Option (BoundedPipeline × Leaf)
  | .pipe pe => pipeStepT s pe
  | .sendAcquireBegin =>
    (sendAcquireBegin s).map (·,
      if s.pipe.send.life.done || s.pipe.send.life.draining then .sendAcquireDraining
      else .sendAcquireEnter)
  | .sendAcquireDone timedOut =>
    (sendAcquireDone s timedOut).map (·,
      match s.sendMgr.acquire s.pipe.send.d2hIssued s.pipe.send.life.draining timedOut with
      | some (.leased _ _) => .sendAcquireLeased
      | some .noSlots => .sendAcquireNoSlots
      | some .timedOut => .sendAcquireTimedOut
      | _ => .sendAcquireCancelled)
  | .recvAcquireBegin l =>
    (recvAcquireBegin s l).map (·,
      if s.recvPhaseL[l]? = some .idle then .recvAcquireFirst else .recvAcquireRepeat)
  | .recvAcquireWait l timedOut =>
    (recvAcquireWait s l timedOut).map (·,
      match s.recvPhaseL[l]?, s.recvMgr.acquire l s.pipe.recv.life.draining timedOut with
      | some (.waiting true), some (.leased _ _) => .recvAcquireIdempotent
      | _, some (.leased _ _) => .recvAcquireLeased
      | _, some .noSlots => .recvAcquireNoSlots
      | _, some .timedOut => .recvAcquireTimedOut
      | _, _ => .recvAcquireCancelled)
  | .recvAcquireFinish l =>
    (recvAcquireFinish s l).map (·,
      if s.pipe.recv.life.done || s.pipe.recv.life.draining then .recvAcquireFinishDraining
      else .recvAcquireFinishOk)
  | .h2dDone l ok =>
    (Recv.stepT s.pipe.recv (.h2dDone ok)).bind fun (_, rl) =>
      (h2dDone s l ok).map (·, .recv rl)

private theorem bind_map_fst {α β γ : Type} (o : Option α) (f : Option β) (g : α → γ)
    (h : o = none → f = none) :
    (o.bind fun a => f.map (·, g a)).map (·.1) = f := by
  cases o with
  | none => simp [h rfl]
  | some _ => simp [Option.map_map, Function.comp_def]

private theorem send_none_of_stepT {t : Send} {e : Send.Ev} (h : Send.stepT t e = none) :
    Send.step t e = none := by rw [← Send.stepT_step, h]; rfl

private theorem recv_none_of_stepT {t : Recv} {e : Recv.Ev} (h : Recv.stepT t e = none) :
    Recv.step t e = none := by rw [← Recv.stepT_step, h]; rfl

/-- `stepT` is `step` with a tag: same enabledness, same post-state. -/
theorem stepT_step (s : BoundedPipeline) (e : Ev) : (stepT s e).map (·.1) = step s e := by
  cases e with
  | sendAcquireBegin | sendAcquireDone _ | recvAcquireBegin _ | recvAcquireWait _ _
  | recvAcquireFinish _ => simp [stepT, step, Option.map_map, Function.comp_def]
  | h2dDone l ok =>
    exact bind_map_fst _ _ _ fun h => by
      simp [h2dDone, Pipeline.step, Pipeline.recvStep_none s.pipe _ (recv_none_of_stepT h)]
  | pipe pe =>
    cases pe with
    | send se =>
      cases se with
      | d2hBegin => simp [stepT, pipeStepT, step, pipeStep, Option.map_map, Function.comp_def]
      | d2hIssue ok =>
        exact bind_map_fst _ _ _ fun h => by
          simp [sendD2hIssue, Pipeline.step, Pipeline.sendStep_none s.pipe _ (send_none_of_stepT h)]
      | wake ok =>
        exact bind_map_fst _ _ _ fun h => by
          simp [sendWake, Pipeline.step, Pipeline.sendStep_none s.pipe _ (send_none_of_stepT h)]
      | h2hIssue =>
        exact bind_map_fst _ _ _ fun h => by
          simp [sendH2hIssue, Pipeline.step, Pipeline.sendStep_none s.pipe _ (send_none_of_stepT h)]
      | _ => simp [stepT, pipeStepT, step, pipeStep, ← Pipeline.stepT_step, Option.map_map, Function.comp_def]
    | recv re =>
      cases re with
      | pushBegin =>
        exact bind_map_fst _ _ _ fun h => by
          simp [recvPushBegin, Pipeline.step, Pipeline.recvStep_none s.pipe _ (recv_none_of_stepT h)]
      | pushEnd =>
        exact bind_map_fst _ _ _ fun h => by
          simp [recvPushEnd, Pipeline.step, Pipeline.recvStep_none s.pipe _ (recv_none_of_stepT h)]
      | h2dDone _ => rfl
      | _ => simp [stepT, pipeStepT, step, pipeStep, ← Pipeline.stepT_step, Option.map_map, Function.comp_def]
    | h2hDone l ok =>
      exact bind_map_fst _ _ _ fun h => by
        simp [h2hDone, Pipeline.step, Pipeline.h2hDone_none s.pipe l ok (send_none_of_stepT h)]
    | h2dIssue l ok =>
      exact bind_map_fst _ _ _ fun h => by
        simp [h2dIssue, Pipeline.step, Pipeline.h2dIssue_none s.pipe l ok (recv_none_of_stepT h)]
    | d2hReady _ | land _ | h2dBegin _ | h2dReady _ | reseatPrefillStaging | reseatDecodeStaging =>
      simp [stepT, pipeStepT, step, pipeStep, Option.map_map, Function.comp_def]
    | _ =>
      simp [stepT, pipeStepT, step, pipeStep, ← Pipeline.stepT_step, Option.map_map, Function.comp_def]

def instr : Instr BoundedPipeline Ev Leaf Effect :=
  { stepT, effect, keep := fun s => s.activeStreams ≤ 1 ∧ s.pipe.recv.pushes ≤ 2 }

def inits : List BoundedPipeline :=
  [init 1 1 1, initUnregistered 1 1 1, init 1 0 1, init 1 1 0]

def allBranches : Option (List Branch) := Coverage.allBranches instr inits (events 1)

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, s, tr) => (s, tr))

def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

def movedOf : Leaf → Option Pipeline.Moved
  | .d2hReady m | .h2dReady m | .land m => some m
  | .h2hDone _ m => m
  | _ => none

def br (l : Leaf) (drains settles errors : Bool) : Branch :=
  (l, ⟨drains, settles, errors⟩)

def expectedStagingWindows : List Branch :=
  [br .sendAcquireDraining false false false,
   br .sendD2hBeginDraining false false false,
   br .recvAcquireCancelled false true false,
   br .recvAcquireFinishDraining false false false,
   br .recvAcquireFinishDraining false true false,
   br .h2dBeginDrainingSkip false false false]

inductive GapClass where
  | envOrHandshake | sessionCovered | sessionGap | zeroSlots | stagingWindow | unaccounted
  deriving Repr, DecidableEq

def gapClass (b : Branch) : GapClass :=
  match b.1 with
  | .reclaim | .reseatPrefillStaging | .reseatDecodeStaging
  | .notifyForRead | .pullWait => .envOrHandshake
  | .sendAcquireNoSlots | .recvAcquireNoSlots => .zeroSlots
  | .send sl | .h2hDone sl _ =>
    if Send.coveredByPaired.contains (sl, b.2) then .sessionCovered
    else if Send.expectedUncovered.contains (sl, b.2) then .sessionGap
    else .unaccounted
  | .recv rl =>
    if Recv.coveredByPaired.contains (rl, b.2) then .sessionCovered
    else if Recv.expectedUncovered.contains (rl, b.2) then .sessionGap
    else .unaccounted
  | _ =>
    if expectedStagingWindows.contains b then .stagingWindow else .unaccounted

def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let gaps := univ.filter (!coveredByPaired.contains ·)
    let count (c : GapClass) := (gaps.filter (gapClass · = c)).length
    univ.length = 95 ∧
    (univ.filter coveredByPaired.contains).length = 39 ∧
    coveredByPaired.length = 46 ∧
    (univ.filter coveredByAll.contains).length = 54 ∧
    coveredByAll.length = 61 ∧
    univ.all (fun b => (movedOf b.1).all (· = .kvRight)) ∧
    univ.all (fun b => b.1 != .slotFault) ∧
    count .envOrHandshake = 5 ∧
    count .sessionCovered = 18 ∧
    count .sessionGap = 21 ∧
    count .zeroSlots = 6 ∧
    count .stagingWindow = 6 ∧
    count .unaccounted = 0 ∧
    paired.all (fun (_, s, tr) => ((⟨s, step⟩ : System BoundedPipeline Ev).run tr).isSome) ∧
    modelOnly.all (fun (_, s, tr) => ((⟨s, step⟩ : System BoundedPipeline Ev).run tr).isSome)

#guard coverageChecks

end TpuSyncVerify.Transfer.PrefillDecode.LayerStaging
