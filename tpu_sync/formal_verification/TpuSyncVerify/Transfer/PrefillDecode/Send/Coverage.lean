import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Transfer.PrefillDecode.Send.Traces

/-! # `Send`: branch coverage of `step` by the replayed tests

Part of `TpuSyncVerify.Transfer.PrefillDecode.Send`. Same construction as
`Receive/Coverage.lean` (the template; machinery in `Common/Coverage.lean`):
a `Leaf` per leaf of each event's decision tree, `stepT` = `step` with the
leaf attached and `stepT_step` proving they agree, the reachable branch set
by exhaustive search, the branches the traces paired with upstream tests
reach, and the difference classified. -/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)
open TpuSyncVerify.Coverage (Effect Instr insertNew sameSet)

namespace Send

/-- One leaf of `step`'s decision tree per event, named for the C++ path it
stands for (the event's `def` in `Model.lean` quotes it). -/
inductive Leaf
  /-- `ValidateAndBeginPull` claimed `pull_started_`. -/
  | beginPull
  /-- `StartPush` on a zero-layer send: `FinishLocked()` at once. -/
  | startZeroLayers
  /-- `StartPush` armed `SendNextLayer(0)` and entered its D2H loop. -/
  | start
  /-- One D2H loop iteration took its op. -/
  | d2hBegin
  /-- `D2hSyncDispatch` succeeded; copy `OnReady` registered on the layer's promise. -/
  | d2hIssueOk
  /-- `D2hSyncDispatch` failed: `FinishLocked(status); EndSendOp()`. -/
  | d2hIssueFail
  /-- A copy's future became ready (`promise.Set`). -/
  | d2hReady
  /-- The copy's `OnReady` in `StartPush` ended its op. -/
  | d2hEnd
  /-- `SendNextLayer`'s `OnReady` with a failed or unissued copy: `FinishLocked(status, kD2hPhase)`. -/
  | wakeFail
  /-- `SendNextLayer`'s `OnReady` on a draining send: op released, no push. -/
  | wakeDraining
  /-- `SendNextLayer`'s `OnReady` scheduled the push task. -/
  | wakeOk
  /-- The pool task took its op and called `H2hWriteDirectAsync`. -/
  | h2hIssued
  /-- The pool task found the send draining: op released, no push. -/
  | h2hIssueRefused
  /-- The task tail: `SendNextLayer(l + 1)` took its op. -/
  | sendNextChained
  /-- The task tail: `SendNextLayer(l + 1)` returned at `l + 1 >= num_layers()`. -/
  | sendNextLast
  /-- The task tail: `SendNextLayer(l + 1)` returned at `if (draining_ ...)`. -/
  | sendNextRefused
  /-- Push callback OK, more pushes to come. -/
  | h2hDoneOk
  /-- Push callback OK for the last layer: `FinishLocked()`. -/
  | h2hDoneLast
  /-- Push callback with an error: `FinishLocked(status, kPushPhase)`. -/
  | h2hDoneFail
  /-- `Finish(error)` from outside the data path. -/
  | cancel
  /-- The poll published a settled session. -/
  | publish
  deriving Repr, DecidableEq

def effect (s s' : Send) : Effect :=
  Effect.of s.life.draining s.life.done s.life.statusOk
    s'.life.draining s'.life.done s'.life.statusOk

abbrev Branch := Leaf × Effect

/-- Which way `trySendNext` went, from the state it is applied to. -/
def sendNextLeaf (s : Send) (chained last refused : Leaf) : Leaf :=
  if s.queued < s.numLayers then
    if s.life.done = true ∨ s.life.draining = true then refused else chained
  else last

/-- `step` with the leaf it took; `stepT_step` is the check. -/
def stepT (s : Send) : Ev → Option (Send × Leaf)
  | .beginPull => (s.beginPull).map (·, .beginPull)
  | .start => (s.start).map (·, if s.numLayers = 0 then .startZeroLayers else .start)
  | .d2hBegin => (s.d2hBegin).map (·, .d2hBegin)
  | .d2hIssue ok =>
    (s.d2hIssue ok).map (·, if !ok then .d2hIssueFail else .d2hIssueOk)
  | .d2hReady => (s.markD2hReady).map (·, .d2hReady)
  | .d2hEnd => (s.d2hEnd).map (·, .d2hEnd)
  | .wake ok =>
    (s.wake ok).map (·,
      if !ok then .wakeFail else if s.life.draining = true then .wakeDraining else .wakeOk)
  | .h2hIssue =>
    (s.h2hIssue).map (·,
      if s.life.done = true ∨ s.life.draining = true then .h2hIssueRefused else .h2hIssued)
  | .sendNext =>
    (s.sendNext).map (·,
      sendNextLeaf { s with chaining := s.chaining - 1 } .sendNextChained .sendNextLast .sendNextRefused)
  | .h2hDone ok =>
    (s.h2hDone ok).map (·,
      if !ok then .h2hDoneFail else if s.h2hOk + 1 = s.numLayers then .h2hDoneLast else .h2hDoneOk)
  | .cancel => (s.cancel).map (·, .cancel)
  | .publish => (s.publish).map (·, .publish)

/-- `stepT` is `step` with a tag: same enabledness, same post-state. -/
theorem stepT_step (s : Send) (e : Ev) : (stepT s e).map (·.1) = step s e := by
  cases e <;> simp [stepT, step, Option.map_map, Function.comp_def]

/-- The instrumented model. Nothing in `Send` is unbounded (every counter is
capped by `numLayers`), so no pruning is needed. -/
def instr : Instr Send Ev Leaf Effect := { stepT, effect }

/-- The systems the search runs on (the two 3-layer paired traces take no branch
outside the 0/1/2-layer universe, checked in `coverageChecks`). -/
def inits : List Send := [init 0, init 1, init 2]

def allBranches : Option (List Branch) := Coverage.allBranches instr inits events

/-! ## Result

The searches exhaust the zero-, one- and two-layer state spaces: **40
branches**, and every `Leaf` is in some reachable branch (unlike `Receive`,
`Send` has no dead arm: `endOp`'s underflow is excluded by `NoUnderflow` but
is not a leaf; `d2hIssueFail` cannot both start draining and settle in one step
because `SendNextLayer(0)` is armed before any copy is issued). The 31 upstream
tests in `paired` (17 distinct traces) reach **27 of 40**; the five `modelOnly`
traces add 1 more. Eleven further send-lifecycle tests are `notReplayable`. The
13 the tests miss, each with a schedule reaching it (the shortest,
`Coverage.witness`, or a drivable one where the shortest is not) and what it
would take:

| Branch | Schedule | Class |
|---|---|---|
| `d2hIssueFail` (no effect) | 1: `beginPull, start, d2hBegin, cancel, d2hIssue false` | **window**: `Finish` inside a loop iteration of `StartPush`, between `++in_flight_` and the dispatch, while another op (`SendNextLayer(0)` before `fail_unissued_layers`) keeps the send unsettled (`PerTransferPolicyClosesIdlePeerConnectionsWhenFailedDispatchEndsSend` covers the `settles` counterpart) |
| `wakeFail` drains settles errors | 1: `…, d2hIssue true, d2hReady, d2hEnd, wake false` | **ordering**: `StartPush` arms `SendNextLayer(0)` before the D2H loop and the copy's `OnReady` calls `promise.Set` (`wake`) before `self->EndSendOp()` (`d2hEnd`), while for `l ≥ 1` an already-ready future runs `wake` inside `SendNextLayer(l)` before the caller pool task's `end_op` (`sendNext`) |
| `wakeDraining` settles | 1: `…, d2hIssue true, d2hReady, cancel, d2hEnd, wake true` | **ordering**: same (`promise.Set` runs `wake` before `d2hEnd`) |
| `wakeFail` (no effect) | 1: `…, d2hIssue true, cancel, d2hReady, wake false` | **test**: an expired send whose copy then fails (`ExpiredSendKeepsItsStagingUntilTheCopyEnds` with `FinishCopy(0, error)`; `wake` runs first inside `promise.Set`, so this row, then `d2hEnd` settles) |
| `wakeFail` settles | 1: `beginPull, start, d2hBegin, d2hIssue false, wake false` | **test**: layer 0's dispatch fails (`FailD2hDispatchAtLayer(0, error)`), draining the send on `d2hIssue false`, and `fail_unissued_layers` resolves layer 0's promise (`wake false`) to settle it (`D2hDispatchFailureFailsUnissuedLayersAndDrainsIssuedCopies` fails layer 1 instead) |
| `h2hIssueRefused` (no effect) | 1: `…, d2hReady, wake true, cancel, h2hIssue` | **window**: `Finish` between `SendNextLayer`'s `OnReady` scheduling the pool task and the task's lock; `WaitForH2hCalls` returns only after that lock |
| `h2hIssueRefused` settles | 1: `…, wake true, cancel, d2hEnd, h2hIssue` | **window**: same (`tr_push_fails`) |
| `sendNextRefused` settles | 2: `…, d2hIssue true, d2hReady, wake true, h2hIssue, h2hDone false, d2hEnd, sendNext` | **window**: the push fails and the copy's `EndSendOp` finishes inside the pool task between `H2hWriteDirectAsync` and `SendNextLayer(l + 1)` (`DetailsSayAFailedPushFailedInPushWhileCopiesRun` reaches the no-effect row with layer 1's copy still running) |
| `h2hDoneOk` settles | 2: `…, h2hIssue, sendNext, cancel, d2hReady, wake true, d2hEnd, h2hDone true` | **test**: `DoneGuaranteesAllResourcesReleased…` with `CompleteD2h(1)` before `CompleteH2h(0)`: layer 0's push is the last op to end |
| `h2hDoneLast` (no effect) | 1: `…, wake true, h2hIssue, cancel, h2hDone true` | **window**: `Finish` and the push completion both before the task tail; `…CancelledMidPush` can reach it by chance (`WaitForH2hCalls` returns before the tail) but cannot force it |
| `h2hDoneFail` (no effect) | 1: `…, wake true, h2hIssue, cancel, h2hDone false` | **window**: same, with an error |
| `h2hDoneFail` drains settles errors | 1: `…, h2hIssue, sendNext, d2hEnd, h2hDone false` | **test**: the only push fails (`CompleteH2h(0, error)`; every caller passes success) |
| `h2hDoneFail` settles | 1: `…, h2hIssue, sendNext, d2hEnd, cancel, h2hDone false` | **test**: `…CancelledMidPush` with `CompleteH2h(0, error)` |

**window** branches (6) need a `Finish` to land inside `StartPush`'s loop
iteration or inside the push-pool task, or a copy's `EndSendOp` to complete
there; neither harness has a hook at those points. **ordering** branches (2)
need `StartPush`'s `self->EndSendOp()` (`d2hEnd`) to precede the `OnReady`
callback that `promise.Set` (`d2hReady`) runs inline. **test** branches (5) are
schedules `FakeSendBase` / `TestManager` can drive today — layer 0's D2H
dispatch failure, the expired-then-failed copy, the two failed-push shapes, and
the `DoneGuarantees…` completions in the other order. -/

/-- `(leaf, drains, settles, errors)`. -/
def br (l : Leaf) (drains settles errors : Bool) : Branch := (l, ⟨drains, settles, errors⟩)

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, s, tr) => (s, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

/-- The table above, as the `#guard` checks it. -/
def expectedUncovered : List Branch :=
  [br .d2hIssueFail false false false,
   br .wakeFail true true true, br .wakeDraining false true false,
   br .wakeFail false false false, br .wakeFail false true false,
   br .h2hIssueRefused false false false, br .h2hIssueRefused false true false,
   br .sendNextRefused false true false,
   br .h2hDoneOk false true false,
   br .h2hDoneLast false false false, br .h2hDoneFail false false false,
   br .h2hDoneFail true true true, br .h2hDoneFail false true false]

def allLeaves : List Leaf :=
  [.beginPull, .startZeroLayers, .start, .d2hBegin, .d2hIssueOk,
   .d2hIssueFail, .d2hReady, .d2hEnd, .wakeFail, .wakeDraining, .wakeOk,
   .h2hIssued, .h2hIssueRefused, .sendNextChained, .sendNextLast, .sendNextRefused, .h2hDoneOk,
   .h2hDoneLast, .h2hDoneFail, .cancel, .publish]

/-- One search, every check: the state spaces are exhausted; 40 branches; 27
reached by paired traces (all within the 0/1/2-layer universe), 28 with
`modelOnly`; the uncovered set is the table; every leaf fires; every paired
trace runs to its end; every table row has a witness schedule. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let uncoveredPaired := univ.filter (fun b => !coveredByPaired.contains b)
    let uncoveredAll := univ.filter (fun b => !coveredByAll.contains b)
    univ.length = 40 ∧ coveredByPaired.length = 27 ∧ coveredByAll.length = 28 ∧
    coveredByPaired.all univ.contains ∧
    sameSet uncoveredPaired expectedUncovered ∧
    sameSet uncoveredAll (expectedUncovered.filter fun b =>
      b ∉ [br .h2hIssueRefused false true false]) ∧
    allLeaves.all (fun l => univ.any (·.1 = l)) ∧
    paired.all (fun (_, s, tr) => ((sys s.numLayers).run tr).isSome) ∧
    expectedUncovered.all (fun b => inits.any fun i => (Coverage.witness instr i events b).isSome)

#guard coverageChecks

end Send

end TpuSyncVerify.Transfer.PrefillDecode
