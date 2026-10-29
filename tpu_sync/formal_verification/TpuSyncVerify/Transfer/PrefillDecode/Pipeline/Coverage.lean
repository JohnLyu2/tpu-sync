import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Coverage
import TpuSyncVerify.Transfer.PrefillDecode.Send.Coverage
import TpuSyncVerify.Transfer.PrefillDecode.PipelineChecks

/-! # `Pipeline`: branch coverage of `step` by the replayed tests

Part of `TpuSyncVerify.Transfer.PrefillDecode.Pipeline`; imports the traces in
`PipelineChecks.lean`, so it is not re-exported by `Pipeline.lean`. Same
construction as `Receive/Coverage.lean` (machinery in `Common/Coverage.lean`).

`Pipeline.step` wraps the two session steps and adds the per-layer memories.
Its leaves are therefore the session leaves where a session step is taken
(`Send.Leaf`, `Recv.Leaf`, through `Send.stepT` / `Recv.stepT`), plus what the
memory events moved: for each copy or landing, whether the cell written was
the right layer's KV, another layer's, junk, or blank (`Moved`). `Effect` is
the lifecycle effect of whichever session the step touched. -/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)
open TpuSyncVerify.Coverage (Effect Instr insertNew sameSet)

namespace Pipeline

/-- What a memory event wrote into slot `l`. -/
inductive Moved
  | kvRight | kvWrong | junk | blank
  deriving Repr, DecidableEq

def moved (c : Cell) (l : Nat) : Moved :=
  match c with
  | .kv k => if k = l then .kvRight else .kvWrong
  | .junk => .junk
  | .blank => .blank

inductive Leaf
  | notifyForRead
  | pullWait
  /-- A send event, with the session leaf `Send.stepT` attached. -/
  | send (l : Send.Leaf)
  /-- A receive event, with the session leaf `Recv.stepT` attached. -/
  | recv (l : Recv.Leaf)
  /-- `prefillStaging[l] := prefillHbm[l]`. -/
  | d2hReady (m : Moved)
  /-- A push callback; on success `wire[l] := prefillStaging[l]`. -/
  | h2hDone (l : Send.Leaf) (m : Option Moved)
  /-- `decodeHbm[l] := decodeStaging[l]`. -/
  | h2dReady (m : Moved)
  /-- `decodeStaging[l] := wire[l]`. -/
  | land (m : Moved)
  | reclaim
  | reseatPrefillStaging
  | reseatDecodeStaging
  deriving Repr, DecidableEq

def effect (s s' : Pipeline) : Effect :=
  let es := Send.effect s.send s'.send
  let er := Recv.effect s.recv s'.recv
  { drains := es.drains || er.drains, settles := es.settles || er.settles,
    errors := es.errors || er.errors }

abbrev Branch := Leaf × Effect

/-- `step` with the leaf it took; the session leaf comes from the session's own
`stepT`, so a pipeline branch names the session branch inside it. -/
def stepT (s : Pipeline) : Ev → Option (Pipeline × Leaf)
  | .notifyForRead => (s.notifyForRead).map (·, .notifyForRead)
  | .pullWait => (s.pullWait).map (·, .pullWait)
  | .send e =>
    (Send.stepT s.send e).bind fun (_, sl) => (s.sendStep e).map (·, .send sl)
  | .d2hReady l => (s.d2hReady l).map (·, .d2hReady (moved (s.prefillHbm.getD l .junk) l))
  | .h2hDone l ok =>
    (Send.stepT s.send (.h2hDone ok)).bind fun (_, sl) =>
      (s.h2hDone l ok).map (·,
        .h2hDone sl (if ok then some (moved (s.prefillStaging.getD l .junk) l) else none))
  | .recv e =>
    (Recv.stepT s.recv e).bind fun (_, rl) => (s.recvStep e).map (·, .recv rl)
  | .h2dBegin l =>
    (Recv.stepT s.recv .h2dBegin).bind fun (_, rl) => (s.h2dBegin l).map (·, .recv rl)
  | .h2dIssue l ok =>
    (Recv.stepT s.recv (.h2dIssue ok)).bind fun (_, rl) => (s.h2dIssue l ok).map (·, .recv rl)
  | .h2dReady l => (s.h2dReady l).map (·, .h2dReady (moved (s.decodeStaging.getD l .junk) l))
  | .land l => (s.land l).map (·, .land (moved (s.wire.getD l .junk) l))
  | .reclaim => (s.reclaim).map (·, .reclaim)
  | .reseatPrefillStaging => (s.reseatPrefillStaging).map (·, .reseatPrefillStaging)
  | .reseatDecodeStaging => (s.reseatDecodeStaging).map (·, .reseatDecodeStaging)

/-- A pipeline event that takes a session step is enabled only if that step is. -/
theorem sendStep_none (s : Pipeline) (e : Send.Ev) (h : Send.step s.send e = none) :
    s.sendStep e = none := by
  cases e <;> simp [sendStep, h]

theorem recvStep_none (s : Pipeline) (e : Recv.Ev) (h : Recv.step s.recv e = none) :
    s.recvStep e = none := by
  cases e <;> simp [recvStep, h]

theorem h2hDone_none (s : Pipeline) (l : Nat) (ok : Bool)
    (h : Send.step s.send (.h2hDone ok) = none) : s.h2hDone l ok = none := by
  simp [h2hDone, h]

theorem h2dBegin_none (s : Pipeline) (l : Nat) (h : Recv.step s.recv .h2dBegin = none) :
    s.h2dBegin l = none := by
  simp [h2dBegin, h]

theorem h2dIssue_none (s : Pipeline) (l : Nat) (ok : Bool)
    (h : Recv.step s.recv (.h2dIssue ok) = none) : s.h2dIssue l ok = none := by
  simp [h2dIssue, h]

private theorem bind_map_fst {α β γ : Type} (o : Option α) (f : Option β) (g : α → γ)
    (h : o = none → f = none) :
    (o.bind fun a => f.map (·, g a)).map (·.1) = f := by
  cases o with
  | none => simp [h rfl]
  | some a => simp [Option.map_map, Function.comp_def]

private theorem send_none_of_stepT {t : Send} {e : Send.Ev} (h : Send.stepT t e = none) :
    Send.step t e = none := by
  rw [← Send.stepT_step, h]; rfl

private theorem recv_none_of_stepT {t : Recv} {e : Recv.Ev} (h : Recv.stepT t e = none) :
    Recv.step t e = none := by
  rw [← Recv.stepT_step, h]; rfl

/-- `stepT` is `step` with a tag: same enabledness, same post-state. -/
theorem stepT_step (s : Pipeline) (e : Ev) : (stepT s e).map (·.1) = step s e := by
  cases e with
  | send e =>
    exact bind_map_fst _ _ _ fun h => sendStep_none s e (send_none_of_stepT h)
  | h2hDone l ok =>
    exact bind_map_fst _ _ _ fun h => h2hDone_none s l ok (send_none_of_stepT h)
  | recv e =>
    exact bind_map_fst _ _ _ fun h => recvStep_none s e (recv_none_of_stepT h)
  | h2dBegin l =>
    exact bind_map_fst _ _ _ fun h => h2dBegin_none s l (recv_none_of_stepT h)
  | h2dIssue l ok =>
    exact bind_map_fst _ _ _ fun h => h2dIssue_none s l ok (recv_none_of_stepT h)
  | _ => simp [stepT, step, Option.map_map, Function.comp_def]

/-- The instrumented model; as in `Receive`, more than two open push leases add
states but no branch. -/
def instr : Instr Pipeline Ev Leaf Effect :=
  { stepT, effect, keep := fun s => s.recv.pushes ≤ 2 }

/-- The systems the search runs on: one layer, registered and unregistered.
Two `paired` rows run on `init 2`; the two-layer universe is discussed below,
not searched here. -/
def inits : List Pipeline := [init 1, initUnregistered 1]

def allBranches : Option (List Branch) := Coverage.allBranches instr inits (events 1)

/-! ## Result

Exhaustive for one layer (registered and unregistered starts): **74
branches**. Every memory move in them writes the right layer's KV
(`moved = .kvRight` for every `d2hReady`, `h2hDone … (some _)`, `h2dReady`,
`land`): `PublicationCorrect` read off the branch set — junk, a wrong layer
or a blank wire slot never moves in the proved system. The `dispatchEarly`
mutant of `PipelineChecks.lean` reaches `h2dReady junk` (checked below).

The 11 `paired` rows (13 upstream tests: three C++ end-to-end, four Python,
six control-plane; seven distinct runs; see `PipelineChecks.lean` for how
weak those pairings are) reach **25 of the 74**; the two two-layer rows take
three more branches outside the one-layer universe (below), 28 along the
traces in all. The five `modelOnly` traces add 5 (30 of 74). The 49 the tests
miss partition as:

* **environment** (3): `reclaim`, `reseatPrefillStaging`, `reseatDecodeStaging`
  — the engine freeing prefill HBM and the allocator handing a released slot
  to the next request. No single-request test does either; the multi-request
  end-to-end (`examples/single_host_disagg/run_all.sh`) does, and
  `MultiRequest.lean` models it (`MultiRequestCoverage.lean`: no test
  reaches either recycle).
* **covered at session level** (18: 10 `Send`, 8 `Recv`): the session branch
  inside the pipeline branch is reached by a session unit test
  (`Send.coveredByPaired` / `Recv.coveredByPaired`). The pipeline adds no C++
  to them — a failed copy, a cancelled receive — only the memory effect, which
  the session tests cannot observe.
* **in the session gap tables** (28: 11 `Send`, 17 `Recv`): `Send.expectedUncovered`
  / `Recv.expectedUncovered`, classified there. (The four `pullReplyFail` rows
  also clear the pipeline's `pullWaiting`, `HandlePullStream`'s grace wait —
  control-plane code the session tables do not see; the C++ is the same
  `on_response`.)

Nothing falls between the tables: the `#guard` checks that every pipeline gap
is one of the three. So at the pipeline level the end-to-end tests exercise
exactly the happy paths and the handshake rejections, and every failure or
window branch is accounted for by the session modules.

Two layers add 8 branches (an `init 2` search, ~20 s, too slow for a
`#guard`; re-run with `tools/run_lean.sh`): `send (S.sendNextChained)`,
`h2hDone (S.h2hDoneOk) kvRight` and `recv (R.h2dDoneOk)` — the three reached
by the two-layer end-to-end traces — and `recv (R.h2dDoneOk)` settles,
`h2hDone (S.h2hDoneOk) kvRight` settles, `send (S.sendNextRefused)` (± settles)
and `send (S.d2hIssueFail)` settles, all accounted for at session level
(`recv (R.h2dDoneOk)` settles, `send (S.sendNextRefused)` no effect and
`send (S.d2hIssueFail)` settles are covered by session tests; the other two
are in `Send.expectedUncovered`). -/

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, s, tr) => (s, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

/-- Where a pipeline gap is accounted for. -/
inductive GapClass
  | env | sessionCovered | sessionGap | unaccounted
  deriving Repr, DecidableEq

def gapClass (b : Branch) : GapClass :=
  match b.1 with
  | .send sl | .h2hDone sl _ =>
    if Send.coveredByPaired.contains (sl, b.2) then .sessionCovered
    else if Send.expectedUncovered.contains (sl, b.2) then .sessionGap else .unaccounted
  | .recv rl =>
    if Recv.coveredByPaired.contains (rl, b.2) then .sessionCovered
    else if Recv.expectedUncovered.contains (rl, b.2) then .sessionGap else .unaccounted
  | .reclaim | .reseatPrefillStaging | .reseatDecodeStaging => .env
  | _ => .unaccounted

def movedOf : Leaf → Option Moved
  | .d2hReady m | .h2dReady m | .land m => some m
  | .h2hDone _ m => m
  | _ => none

/-- One search, every check: exhausted; 74 branches; 25 reached by the paired
traces within the universe (28 along them, the other 3 two-layer), 30 with
`modelOnly`; every move is `kvRight`; the gaps partition into 3 environment,
18 session-covered, 28 session-gap, none unaccounted; every paired trace runs
to its end; the `dispatchEarly` mutant moves junk into decode HBM (the mutant
system borrows `stepT`'s tag where the original step is also enabled, which
it is at that point; elsewhere the tag is a placeholder). -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let gaps := univ.filter (fun b => !coveredByPaired.contains b)
    let count (c : GapClass) := (gaps.filter (gapClass · = c)).length
    univ.length = 74 ∧ (univ.filter coveredByPaired.contains).length = 25 ∧
    coveredByPaired.length = 28 ∧ (univ.filter coveredByAll.contains).length = 30 ∧
    univ.all (fun b => (movedOf b.1).all (· = .kvRight)) ∧
    count .env = 3 ∧ count .sessionCovered = 18 ∧ count .sessionGap = 28 ∧
    count .unaccounted = 0 ∧
    paired.all (fun (_, s, tr) => ((⟨s, step⟩ : System Pipeline Ev).run tr).isSome) ∧
    (Coverage.witnessP { instr with stepT := fun s e =>
        (sysDispatchEarly.step s e).map fun s' => (s', ((stepT s e).map (·.2)).getD .reclaim) }
      (init 1) (events 1) (fun b => b.1 = .h2dReady .junk)).isSome

#guard coverageChecks

end Pipeline

end TpuSyncVerify.Transfer.PrefillDecode
