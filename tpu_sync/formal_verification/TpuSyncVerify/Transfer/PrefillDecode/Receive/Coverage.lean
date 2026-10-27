import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Traces

/-! # `Recv`: branch coverage of `step` by the replayed tests

Part of `TpuSyncVerify.Transfer.PrefillDecode.Receive`.

`step` is a small decision tree per event. A **branch** is one leaf of that tree
(`Leaf`) together with what the step did to the lifecycle (`Effect`: started
draining, settled, recorded the first error). `stepT` is `step` with the leaf
attached; `stepT_step` proves it is the same function, so coverage is measured
on the proved `step` and never on a second transcription.

The denominator is the set of branches reachable from `initPush`/`initLoad`
(`reachableBranches`, an exhaustive search); the numerator is the set of branches
along the traces that replay an upstream C++ test (`paired` in `Traces.lean`).
A branch no replayed test reaches is either a missing upstream test or a
transition only the environment can cause; each is listed and classified in
`#guard`s at the end so a new branch, a dropped trace or a new test fails
`lake build`. -/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)

namespace Recv

/-- One leaf of `step`'s decision tree per event. Names follow the C++ path
they stand for; the docstring of the event's `def` in `Model.lean` quotes it. -/
inductive Leaf
  /-- `TryBeginRecvOp` accepted a push. -/
  | pushBegin
  /-- `EndRecvOp` for a push. -/
  | pushEnd
  /-- `on_response` with an OK pull status. -/
  | pullReplyOk
  /-- `on_response` with a failed pull status: `FinishLocked(pull_status)`. -/
  | pullReplyFail
  /-- `ExecuteLayerH2d` took an op. -/
  | h2dBegin
  /-- `ExecuteLayerH2d`'s second `if (done_ || draining_)` fired: op released, no copy. -/
  | h2dIssueReleased
  /-- `H2dSyncDispatch` succeeded; future pushed. -/
  | h2dIssueOk
  /-- `H2dSyncDispatch` failed: `FinishLocked(status, kH2dPhase)`. -/
  | h2dIssueFail
  /-- A dispatched copy's future became ready. -/
  | h2dReady
  /-- Callback on a retired session (`if (self->done_)`, `LOG(DFATAL)`). -/
  | h2dDoneRetired
  /-- Callback OK, more layers to come. -/
  | h2dDoneOk
  /-- Callback OK for the last layer, session not draining: `FinishLocked()`. -/
  | h2dDoneLast
  /-- Callback OK for the last layer while already draining: no `FinishLocked()`
  (the poll or an error got there first). -/
  | h2dDoneLastDraining
  /-- Callback with an error: `FinishLocked(status, kH2dPhase)`. -/
  | h2dDoneFail
  /-- `OnBlockShardsReceived` accounted a layer; more to come or copies pending. -/
  | netAccountPartial
  /-- `OnBlockShardsReceived` completed the network side with every layer
  copied: `RecordNetworkCompleteLocked` → `FinishLocked()`. -/
  | netAccountCompletes
  /-- The poll saw `IsReadyToComplete` and called `Finish()`. -/
  | pollReady
  /-- `Finish(error)` from outside. -/
  | cancel
  /-- The poll published a settled session. -/
  | publish
  deriving Repr, DecidableEq

/-- What a step did to the lifecycle, read off the two states. -/
structure Effect where
  /-- `draining_` went `false → true`. -/
  drains : Bool
  /-- `done_` went `false → true` (staging released). -/
  settles : Bool
  /-- `status_` went OK → error. -/
  errors : Bool
  deriving Repr, DecidableEq

def effect (s s' : Recv) : Effect :=
  { drains := !s.life.draining && s'.life.draining,
    settles := !s.life.done && s'.life.done,
    errors := s.life.statusOk && !s'.life.statusOk }

abbrev Branch := Leaf × Effect

/-- `step` with the leaf it took. The decision tree is copied from the event
functions in `Model.lean` leaf for leaf; `stepT_step` is the check. -/
def stepT (s : Recv) : Ev → Option (Recv × Leaf)
  | .pushBegin => (s.pushBegin).map (·, .pushBegin)
  | .pushEnd => (s.pushEnd).map (·, .pushEnd)
  | .pullReply ok => (s.pullReply ok).map (·, if ok then .pullReplyOk else .pullReplyFail)
  | .h2dBegin => (s.h2dBegin).map (·, .h2dBegin)
  | .h2dIssue ok =>
    (s.h2dIssue ok).map (·,
      if s.life.done = true ∨ s.life.draining = true then .h2dIssueReleased
      else if ok then .h2dIssueOk else .h2dIssueFail)
  | .h2dReady => (s.h2dReady).map (·, .h2dReady)
  | .h2dDone ok =>
    (s.h2dDone ok).map (·,
      if s.life.done = true then .h2dDoneRetired
      else if ok then
        if s.completed + 1 = s.numLayers then
          if s.life.draining = false then .h2dDoneLast else .h2dDoneLastDraining
        else .h2dDoneOk
      else .h2dDoneFail)
  | .netAccount =>
    (s.netAccount).map (·,
      if s.layersAccounted + 1 = s.numLayers ∧ s.completed = s.numLayers
      then .netAccountCompletes else .netAccountPartial)
  | .pollReady => (s.pollReady).map (·, .pollReady)
  | .cancel => (s.cancel).map (·, .cancel)
  | .publish => (s.publish).map (·, .publish)

/-- `stepT` is `step` with a tag: same enabledness, same post-state. -/
theorem stepT_step (s : Recv) (e : Ev) : (stepT s e).map (·.1) = step s e := by
  cases e <;> simp [stepT, step, Option.map_map, Function.comp_def]

/-! ## Running with branches -/

/-- Replay `tr` from `s`, collecting the branch of every step; stops at the
first refused event (its branches so far are still reported). -/
def runT (s : Recv) : List Ev → List Branch
  | [] => []
  | e :: es =>
    match stepT s e with
    | none => []
    | some (s', l) => (l, effect s s') :: runT s' es

private def insertNew (acc : List Branch) (b : Branch) : List Branch :=
  if acc.contains b then acc else b :: acc

/-- Union of branches along a list of (initial state, trace) pairs. -/
def coveredBy (runs : List (Recv × List Ev)) : List Branch :=
  (runs.flatMap fun (s, tr) => runT s tr).foldl insertNew []

/-- Every branch reachable from `init`, by breadth-first search over states
(the same search as `ModelCheck.check`, collecting branches instead of looking
for a bad state). States with more than `maxPushes` open push leases are not
expanded: a third concurrent push adds states but no branch (`pushes` only
matters as `0`, `1` or "another one is open"), and with it the state space is
finite. Returns `none` if `fuel` ran out before the search exhausted it. -/
def reachableBranches (init : Recv) (events : List Ev) (fuel : Nat) (maxPushes : Nat := 2) :
    Option (List Branch) :=
  go [init] [init] [] fuel
where
  go (frontier seen : List Recv) (acc : List Branch) : Nat → Option (List Branch)
    | 0 => none
    | fuel + 1 =>
      let next := frontier.flatMap fun s =>
        events.filterMap fun e =>
          (stepT s e).bind fun (s', l) =>
            if s'.pushes ≤ maxPushes then some (s', (l, effect s s')) else none
      let acc := next.foldl (fun acc p => insertNew acc p.2) acc
      let fresh := (next.map (·.1)).foldl
        (fun (fr : List Recv) s' => if seen.contains s' ∨ fr.contains s' then fr else s' :: fr) []
      if fresh.isEmpty then some acc else go fresh (seen ++ fresh) acc fuel

/-- Shortest trace from `init` whose last step takes branch `b`. -/
def witness (init : Recv) (events : List Ev) (b : Branch) (fuel : Nat := 16) :
    Option (List Ev) :=
  go [(init, [])] [init] fuel
where
  go (frontier : List (Recv × List Ev)) (seen : List Recv) : Nat → Option (List Ev)
    | 0 => none
    | fuel + 1 =>
      let next := frontier.flatMap fun (s, tr) =>
        events.filterMap fun e =>
          (stepT s e).map fun (s', l) => (s', e :: tr, (l, effect s s'))
      match next.find? (fun p => p.2.2 = b) with
      | some (_, tr, _) => some tr.reverse
      | none =>
        let fresh := next.foldl
          (fun (fr : List (Recv × List Ev)) (s', tr, _) =>
            if s'.pushes > 2 ∨ seen.contains s' ∨ fr.any (·.1 = s') then fr else (s', tr) :: fr) []
        if fresh.isEmpty then none else go fresh (seen ++ fresh.map (·.1)) fuel

/-- The four systems the traces run on, and the union of their reachable
branches (`none` if any search did not exhaust its state space). -/
def inits : List Recv := [initPush 1, initPush 2, initLoad 1, initLoad 2]

def allBranches (fuel : Nat := 64) : Option (List Branch) :=
  inits.foldlM (fun acc i => (reachableBranches i events fuel).map (·.foldl insertNew acc)) []

/-! ## Result

Every search below exhausts its state space, so `allBranches` is exact for
one- and two-layer receives with at most two open push leases: **37 branches**.
Two leaves of `Leaf` are in no reachable branch:

* `h2dDoneRetired` — a callback on a settled session; excluded by
  `NoRetiredCallback` (`done → retired = issued`). The C++ `LOG(DFATAL)` is an
  assertion.
* `netAccountCompletes` — `RecordNetworkCompleteLocked`'s `FinishLocked()`
  arm, taken when the network completes after every layer was copied. The
  callback that copies the last layer calls `FinishLocked()` itself unless
  `draining_`, and `OnBlockShardsReceived` returns at `if (done_ || draining_)`
  once it has; so by the time the network side could complete with
  `num_completed_layers_ == total_layers`, the session is always draining. The
  arm is dead in the C++ for the same reason (`num_completed_layers_` is
  incremented nowhere else; at `total_layers == 0` the per-shard target is `0`,
  so with `num_shards() ≥ 1` no shard ever newly completes — a base with zero
  shards and zero layers would reach it, and nothing constructs one).

The 20 upstream tests in `paired` (13 named traces) reach **18 of 37**; the
four `modelOnly` traces add 4 more. The 19 the tests miss, each with the
shortest schedule that reaches it (`witness`) and what it would take:

| Branch | Shortest schedule | Class |
|---|---|---|
| `h2dIssueFail` drains settles errors | push 1: `h2dBegin, h2dIssue false` | **test**: no upstream test fails `H2dSyncDispatch`; `RecvTestManager::RecvBase::H2dSyncDispatch` could be made to return an error, or `hooks::kTransferRecvSessionH2dDispatch` |
| `h2dIssueFail` drains errors | push 1: `h2dBegin, pushBegin, h2dIssue false` | **test**: same, with a push lease open (`BeginIncomingPush`) |
| `cancel` (no effect) | push 1: `cancel, cancel` | **test**: second `Finish(error)` on a failed session (`FailRecv` twice); reached unasserted at teardown of `IncomingPushLeasePinsStagingDuringWriteAndRejectsWhenDraining`, whose settled session `~KVCacheManagerWithTransfer` still `Finish(CancelledError)`es |
| `cancel` errors | push 1: `h2dBegin, h2dIssue true, h2dReady, h2dDone true, cancel` | **test**: `Finish(error)` after the session settled OK flips `status_` (§"Late errors" in `Receive.lean`); `FailRecv` after `FinishCopy(ok)` and before the poll reaches it directly, production only through the sweep's and `UnregisterActivePlan`'s check-then-`Finish` |
| `pushEnd` (no effect) | push 1: `pushBegin, pushEnd` | **test**: a push lease that closes while the receive continues (`tr_normal`; the four lease tests all close theirs on a draining session) |
| `pullReplyOk` (no effect) | load 1: `pullReply true` | **test (stub)**: no consumer-side unit test completes a handshake — `RegisteredPullIsAcknowledged` is producer-side, and the control-plane tests' producers hold, drop or reject; needs a producer stub that answers (`tr_deadline_during_copy`, end-to-end tests) |
| `pullReplyOk` settles | load 1: `cancel, pullReply true` | **test (stub)**: deadline during the handshake, then the producer accepts (`ExpiredReceiveKeepsStagingUntilHandshakeEnds` drops the client; `SilentProducer` cannot answer) |
| `pullReplyFail` drains errors | load 1: `h2dBegin, pullReply false` | **ordering**: a layer dispatched before the pull reply arrives, then the reply fails |
| `pullReplyFail` settles errors | load 1: `h2dBegin, h2dIssue true, h2dReady, h2dDone true, pullReply false` | **ordering**: every layer copied before the reply arrives, then it fails: the complete receive is published failed |
| `pullReplyFail` errors | load 1: `h2dBegin, h2dIssue true, netAccount, h2dReady, pollReady, pullReply false` | **ordering** + window: the poll finishes the receive before the reply arrives, then it fails |
| `pullReplyFail` (no effect) | load 1: `pushBegin, cancel, pullReply false` | **ordering**: already failed with a push open |
| `h2dIssueReleased` settles | push 1: `h2dBegin, cancel, h2dIssue true` | **window**: `Finish` between the two locks of `ExecuteLayerH2d` (`tr_finish_between_locks`); `BlockH2dDispatch` blocks inside `H2dSyncDispatch`, after the re-check, so no harness point reaches it |
| `h2dIssueReleased` (no effect) | push 1: `h2dBegin, pushBegin, cancel, h2dIssue true` | **window**: same, with a push lease open |
| `pollReady` drains | push 1: `h2dBegin, h2dIssue true, netAccount, h2dReady, pollReady` | **window**: the poll between a future's readiness and its callback (`tr_poll_before_callbacks`, `ReceivePoll.lean`); no harness point sits between `FinishCopy` making the future ready and the callback it runs |
| `h2dDoneFail` settles errors | push 1: `h2dBegin, h2dIssue true, netAccount, h2dReady, pollReady, h2dDone false` | **window**: poll first, then the callback fails |
| `h2dDoneFail` settles | push 1: `h2dBegin, h2dIssue true, cancel, h2dReady, h2dDone false` | **test**: cancelled receive whose only copy then fails (`ExpiredReceiveKeepsStagingUntilH2dEnds` completes it OK) |
| `h2dDoneFail` (no effect) | push 1: `h2dBegin, h2dIssue true, pushBegin, cancel, h2dReady, h2dDone false` | **test**: same, with a push lease open |
| `h2dDoneFail` errors | push 1: `h2dBegin, h2dIssue true, h2dReady, pushBegin, netAccount, pollReady, h2dDone false` | **window**: poll first, callback fails, push lease open |
| `h2dDoneLastDraining` (no effect) | push 1: `h2dBegin, h2dIssue true, pushBegin, cancel, h2dReady, h2dDone true` | **test**: cancelled receive whose last copy completes OK while a push lease is open (`ExpiredReceiveKeepsStagingUntilH2dEnds` without the lease) |

**ordering** branches (4) need a layer to arrive before the pull reply is
processed. That is possible: the producer's `HandlePullStream` starts the
`StartPush` thread before it returns its response, and data travels on the
data connections while the reply comes back on the control path, so the model
leaves the two unordered. What is not in this model is whether a reply can
*fail* after its data landed (a control-path deadline or reset); if it can,
the complete receive is published as failed. **window** branches (5) need an
interleaving the test harness has no hook for. **test** branches (10) are
schedules `RecvTestManager` can drive today (8), or could with a control-plane
producer stub that answers on command (2). -/

/-- `(leaf, drains, settles, errors)`. -/
def br (l : Leaf) (drains settles errors : Bool) : Branch := (l, ⟨drains, settles, errors⟩)

def coveredByPaired : List Branch := coveredBy (paired.map fun (_, s, tr) => (s, tr))
def coveredByAll : List Branch := coveredBy ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

/-- The table above, as the `#guard`s check it. -/
def expectedUncovered : List Branch :=
  [br .h2dIssueFail true true true, br .h2dIssueFail true false true,
   br .cancel false false false, br .cancel false false true,
   br .pushEnd false false false,
   br .pullReplyOk false false false, br .pullReplyOk false true false,
   br .pullReplyFail true false true, br .pullReplyFail false true true,
   br .pullReplyFail false false true, br .pullReplyFail false false false,
   br .h2dIssueReleased false true false, br .h2dIssueReleased false false false,
   br .pollReady true false false,
   br .h2dDoneFail false true true, br .h2dDoneFail false true false,
   br .h2dDoneFail false false false, br .h2dDoneFail false false true,
   br .h2dDoneLastDraining false false false]

private def sameSet (a b : List Branch) : Bool := a.all b.contains ∧ b.all a.contains

/-- Leaves in no reachable branch: a C++ assertion and a dead arm (see above). -/
def unreachableLeaves : List Leaf := [.h2dDoneRetired, .netAccountCompletes]

def liveLeaves : List Leaf :=
  [.pushBegin, .pushEnd, .pullReplyOk, .pullReplyFail, .h2dBegin, .h2dIssueReleased,
   .h2dIssueOk, .h2dIssueFail, .h2dReady, .h2dDoneOk, .h2dDoneLast, .h2dDoneLastDraining,
   .h2dDoneFail, .netAccountPartial, .pollReady, .cancel, .publish]

/-- One search, every check (a `#guard` per line would redo the search each
time): the state space is exhausted; 37 branches; 18 reached by paired
traces, 22 with `modelOnly`; the uncovered set is the table; the two
unreachable leaves never fire and every other leaf does; every table row has a
witness schedule. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let uncoveredPaired := univ.filter (fun b => !coveredByPaired.contains b)
    let uncoveredAll := univ.filter (fun b => !coveredByAll.contains b)
    univ.length = 37 ∧ coveredByPaired.length = 18 ∧ coveredByAll.length = 22 ∧
    sameSet uncoveredPaired expectedUncovered ∧
    sameSet uncoveredAll (expectedUncovered.filter fun b =>
      b ∉ [br .pushEnd false false false, br .pullReplyOk false false false,
           br .h2dIssueReleased false true false, br .pollReady true false false]) ∧
    univ.all (fun b => !unreachableLeaves.contains b.1) ∧
    liveLeaves.all (fun l => univ.any (·.1 = l)) ∧
    expectedUncovered.all (fun b => inits.any fun i => (witness i events b).isSome)

#guard coverageChecks

end Recv

end TpuSyncVerify.Transfer.PrefillDecode
