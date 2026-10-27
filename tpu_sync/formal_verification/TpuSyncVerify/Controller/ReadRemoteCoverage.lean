import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Controller.ReadRemote

/-! # `ReadRemote`: branch coverage of `step` by the replayed tests

Same construction as `Transfer/PrefillDecode/Receive/Coverage.lean`
(machinery in `Common/Coverage.lean`), on the `shipping` implementation: a
`Leaf` per leaf of each event's decision tree, `stepT` = `step .shipping`
with the leaf attached and `stepT_step` proving they agree, the reachable
branch set by exhaustive search (seven booleans; the whole space), the
branches the traces paired with `ReadRemotePullTest` reach, and the
difference classified. The model has no session lifecycle; the effect
recorded with a leaf is whether the step settled the read. -/

namespace TpuSyncVerify.Controller.ReadRemote

open TpuSyncVerify.Coverage (Instr insertNew sameSet)

/-- One leaf of `step .shipping`'s decision tree per event. -/
inductive Leaf
  /-- The acquire RPC failed: `if (!status.ok())`, settle, no pull. -/
  | acquireFailed
  /-- The controller was torn down first: `if (lifetime->ctrl == nullptr)`, settle, no pull. -/
  | acquireAfterShutdown
  /-- Live controller: `PullAndRelease` issues the pull (shipping: without reading `settled`). -/
  | acquireIssuesPull
  /-- `Cleanup`: `lifetime_->ctrl = nullptr`. -/
  | shutdown
  /-- The deadline thread settles the read. -/
  | deadlineSettles
  /-- The deadline thread finds the read already settled (`if (state->settled) return;`). -/
  | deadlineLate
  /-- `transfer.OnReady` → `ReleaseReadLease` → `Settle(verdict)`. -/
  | pullDone
  /-- The caller reuses its destination blocks. -/
  | callerReuse
  deriving Repr, DecidableEq, Hashable

/-- Whether the step flipped `settled`. -/
structure Effect where
  settles : Bool
  deriving Repr, DecidableEq, Hashable

abbrev Branch := Leaf × Effect

def effect (s s' : S) : Effect := ⟨!s.settled && s'.settled⟩

/-- `step .shipping` with the leaf it took; `stepT_step` is the check. -/
def stepT (s : S) : Ev → Option (S × Leaf)
  | .acquireReply ok =>
    (acquireReply .shipping ok s).map (·,
      if !ok then .acquireFailed else if s.shutdown then .acquireAfterShutdown
      else .acquireIssuesPull)
  | .shutdown => (shutdownCtrl s).map (·, .shutdown)
  | .deadline => (deadline .shipping s).map (·, if s.settled then .deadlineLate else .deadlineSettles)
  | .pullDone => (completePull s).map (·, .pullDone)
  | .callerReuse => (callerReuse s).map (·, .callerReuse)

theorem stepT_step (s : S) (e : Ev) : (stepT s e).map (·.1) = step .shipping s e := by
  cases e <;> simp [stepT, step, Option.map_map, Function.comp_def]

def instr : Instr S Ev Leaf Effect := { stepT, effect }

def allBranches : Option (List Branch) := Coverage.allBranches instr [{}] events

/-! ## Which traces stand for an upstream test

The traces of the `## C++ unit test correspondence` section without their
final `callerReuse`, with the `ReadRemotePullTest` cases each replays.
`callerReuse` is a ghost — the caller touching its destination blocks after
the future settled — and no test touches them after `Await()` (the block ids
are plain integers), so the tests establish the state in which it is
enabled, not the step; it is not paired. `ControllerTeardownMidReadIsSafe`
destroys the controller with the read in flight and accepts success or
`Cancelled`, i.e. any of the three traces below that end settled; all three
are paired with it. No upstream test drives the deadline thread:
`RemoteReadDeadline()` (default 150 s) is long against every test's RPCs,
and no test delays the source or the worker. -/

def tr_full_success : List Ev := [.acquireReply true, .pullDone]
def tr_acquire_fails_fast : List Ev := [.acquireReply false]
def tr_teardown_before_acquire : List Ev := [.shutdown, .acquireReply true]
def tr_teardown_during_pull : List Ev := [.acquireReply true, .shutdown, .pullDone]

def paired : List (String × List Ev) :=
  [("ReadRemotePullTest.FullSuccessPathUsesAuthoritativeIdsAndSrcEndpoints", tr_full_success),
   ("ReadRemotePullTest.HbmModeBuildsStagingPlusDeviceDst", tr_full_success),
   ("ReadRemotePullTest.HostModeBuildsDramDstWithNoStaging", tr_full_success),
   ("ReadRemotePullTest.TransferFailureStillReleasesTheLease", tr_full_success),
   ("ReadRemotePullTest.RevokedVerdictFailsTheRead", tr_full_success),
   ("ReadRemotePullTest.AcquireNotFoundFailsFastWithoutTransfer", tr_acquire_fails_fast),
   ("ReadRemotePullTest.ControllerTeardownMidReadIsSafe", tr_full_success),
   ("ReadRemotePullTest.ControllerTeardownMidReadIsSafe", tr_teardown_before_acquire),
   ("ReadRemotePullTest.ControllerTeardownMidReadIsSafe", tr_teardown_during_pull)]

/-- Traces no upstream test replays: the two `NoWriteAfterRelease`
counterexamples. -/
def modelOnly : List (String × List Ev) :=
  [("shape A: late issue", lateIssue), ("shape B: deadline during the pull", inFlight)]

/-! ## Result

The whole state space of `sys .shipping` (seven booleans, each event at most
once): **11 branches**. The 9 paired rows (7 upstream tests, 4 traces) reach
**5**; the two counterexample traces add 2 (7). The 6 the tests miss:

| Branch | Shortest schedule | Class |
|---|---|---|
| `deadlineSettles` settles | `deadline` | **test**: no test lets `RemoteReadDeadline()` expire; a source that answers `AcquireReadLease` after a short `RAIDEN_REMOTE_READ_DEADLINE_S` (integer seconds, read once per process) drives it, and then shape A: `lateIssue` (`deadline, callerReuse, acquireReply true`) |
| `acquireFailed` (no effect) | `deadline, acquireReply false` | **test**: a failed acquire landing after the deadline settled (a slowed source hook) |
| `acquireAfterShutdown` (no effect) | `deadline, shutdown, acquireReply true` | **test**: teardown and the acquire reply both after the deadline settled |
| `deadlineLate` | `acquireReply false, deadline` | **test**: the deadline thread waking on a settled read. Every test ends and tears the controller down within seconds, and the detached thread (asleep 150 s, holding `state`) is still asleep when the test binary exits, so it never wakes; with a short deadline it would, unobserved |
| `pullDone` (no effect) | `deadline, acquireReply true, pullDone` | **test**: a pull completing after the deadline settled — shape A's or shape B's tail (`inFlight ++ [pullDone]`) |
| `callerReuse` | `acquireReply false, callerReuse` | **ghost**: the caller's reuse of its blocks is not a stimulus the unit tests apply (above); a test that wrote the destination blocks after `Await()` and checked them against a late DMA would be shape B's reproducer |

Five of the six need the deadline to fire: the model has no lock windows —
every event is one `state->mu` scope or none (`Lock scopes` above) — so every
branch is drivable, and the one stimulus the upstream suite never applies is
time. `acquireIssuesPull` is one branch whether or not the read has settled
(the shipping code does not read `settled`, and issuing does not settle), so
shape A's issuing step is the paired branch; what distinguishes shape A is the
state it is taken in, which `Effect` does not record — a finer effect
(`issued after settled`) would split it into a twelfth branch that only
`lateIssue` reaches. That is what `NoWriteAfterRelease` and the exhaustive
search are for. The two shapes are reproducible with a `ReadRemotePullTest`
fixture whose source or worker is slowed past a short deadline. -/

def br (l : Leaf) (settles : Bool) : Branch := (l, ⟨settles⟩)

def coveredByPaired : List Branch := Coverage.coveredBy instr (paired.map fun (_, tr) => ({}, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, tr) => ({}, tr))

def expectedUncovered : List Branch :=
  [br .deadlineSettles true, br .acquireFailed false, br .acquireAfterShutdown false,
   br .deadlineLate false, br .pullDone false, br .callerReuse false]

def allLeaves : List Leaf :=
  [.acquireFailed, .acquireAfterShutdown, .acquireIssuesPull, .shutdown, .deadlineSettles,
   .deadlineLate, .pullDone, .callerReuse]

/-- One search, every check: exhausted; 11 branches; 5 reached by paired
traces, 7 with the counterexamples; the uncovered set is the table; every
leaf fires; every paired trace runs to its end; every table row has a
witness. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let uncoveredPaired := univ.filter (fun b => !coveredByPaired.contains b)
    univ.length = 11 ∧ coveredByPaired.length = 5 ∧ coveredByAll.length = 7 ∧
    sameSet uncoveredPaired expectedUncovered ∧
    allLeaves.all (fun l => univ.any (·.1 = l)) ∧
    paired.all (fun (_, tr) => ((sys .shipping).run tr).isSome) ∧
    expectedUncovered.all (fun b => (Coverage.witness instr {} events b).isSome)

#guard coverageChecks

end TpuSyncVerify.Controller.ReadRemote
