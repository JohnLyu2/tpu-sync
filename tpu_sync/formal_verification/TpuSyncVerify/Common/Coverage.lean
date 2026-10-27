import Std.Data.HashSet
import TpuSyncVerify.Common.System

/-!
# Branch coverage

How much of a model's `step` a set of traces exercises. A model instruments
its `step` as `stepT : S → Ev → Option (S × L)` — the same function with a
leaf tag `L` naming the branch of the event's decision tree that was taken —
and proves `(stepT s e).map (·.1) = step s e`, so coverage is measured on the
proved `step` and never on a second transcription. An `effect : S → S → E`
read off the before/after states adds what the step did to the lifecycle; a
**branch** is the pair `L × E`.

`reachableBranches` collects every branch over the reachable states (an
exhaustive search when the state space is finite, `none` if the fuel ran out
first), `coveredBy` the branches along given traces, and `witness` the
shortest trace reaching a branch — the schedule of the test that is missing.
-/

namespace TpuSyncVerify.Coverage

/-- What a step did to a session lifecycle, read off the two states. -/
structure Effect where
  /-- `draining_` went `false → true`. -/
  drains : Bool
  /-- `done_` went `false → true` (staging released). -/
  settles : Bool
  /-- `status_` went OK → error. -/
  errors : Bool
  deriving Repr, DecidableEq

/-- `Effect` from the three lifecycle bits before and after. -/
def Effect.of (draining done statusOk draining' done' statusOk' : Bool) : Effect :=
  { drains := !draining && draining', settles := !done && done', errors := statusOk && !statusOk' }

/-- An instrumented model: `stepT` with leaf tags, `effect` on the states,
and `keep` to prune states that add no branch (keeps the search finite). A
successor that `keep` rejects is dropped together with the branch that led to
it in `reachableBranches`; `witnessP` tests the predicate before pruning, so
it can find a branch that only leads into pruned states. -/
structure Instr (S Ev L E : Type) where
  stepT : S → Ev → Option (S × L)
  effect : S → S → E
  keep : S → Bool := fun _ => true

variable {S Ev L E : Type} [DecidableEq S] [Hashable S] [DecidableEq L] [DecidableEq E]

def insertNew (acc : List (L × E)) (b : L × E) : List (L × E) :=
  if acc.contains b then acc else b :: acc

def sameSet (a b : List (L × E)) : Bool := a.all b.contains ∧ b.all a.contains

/-- Replay `tr` from `s`, collecting the branch of every step; stops at the
first refused event (its branches so far are still reported). -/
def runT (m : Instr S Ev L E) (s : S) : List Ev → List (L × E)
  | [] => []
  | e :: es =>
    match m.stepT s e with
    | none => []
    | some (s', l) => (l, m.effect s s') :: runT m s' es

/-- Union of branches along a list of (initial state, trace) pairs. -/
def coveredBy (m : Instr S Ev L E) (runs : List (S × List Ev)) : List (L × E) :=
  (runs.flatMap fun (s, tr) => runT m s tr).foldl insertNew []

/-- Every branch reachable from `init` through kept states, by breadth-first
search (the same search as `ModelCheck.check`, collecting branches instead of
looking for a bad state). `none` if `fuel` ran out before the search exhausted
the state space. -/
def reachableBranches (m : Instr S Ev L E) (init : S) (events : List Ev) (fuel : Nat) :
    Option (List (L × E)) :=
  go [init] (Std.HashSet.emptyWithCapacity.insert init) [] fuel
where
  go (frontier : List S) (seen : Std.HashSet S) (acc : List (L × E)) :
      Nat → Option (List (L × E))
    | 0 => none
    | fuel + 1 =>
      let next := frontier.flatMap fun s =>
        events.filterMap fun e =>
          (m.stepT s e).bind fun (s', l) =>
            if m.keep s' then some (s', (l, m.effect s s')) else none
      let acc := next.foldl (fun acc p => insertNew acc p.2) acc
      let (fresh, seen) := next.foldl
        (fun (p : List S × Std.HashSet S) q =>
          if p.2.contains q.1 then p else (q.1 :: p.1, p.2.insert q.1)) ([], seen)
      if fresh.isEmpty then some acc else go fresh seen acc fuel

/-- Shortest trace from `init` whose last step takes a branch satisfying `p`. -/
def witnessP (m : Instr S Ev L E) (init : S) (events : List Ev) (p : L × E → Bool)
    (fuel : Nat := 16) : Option (List Ev) :=
  go [(init, [])] (Std.HashSet.emptyWithCapacity.insert init) fuel
where
  go (frontier : List (S × List Ev)) (seen : Std.HashSet S) : Nat → Option (List Ev)
    | 0 => none
    | fuel + 1 =>
      let next := frontier.flatMap fun (s, tr) =>
        events.filterMap fun e =>
          (m.stepT s e).map fun (s', l) => (s', e :: tr, (l, m.effect s s'))
      match next.find? (fun q => p q.2.2) with
      | some (_, tr, _) => some tr.reverse
      | none =>
        let (fresh, seen) := next.foldl
          (fun (p : List (S × List Ev) × Std.HashSet S) (s', tr, _) =>
            if !m.keep s' ∨ p.2.contains s' then p else ((s', tr) :: p.1, p.2.insert s'))
          ([], seen)
        if fresh.isEmpty then none else go fresh seen fuel

/-- Shortest trace from `init` whose last step takes branch `b`. -/
def witness (m : Instr S Ev L E) (init : S) (events : List Ev) (b : L × E) (fuel : Nat := 16) :
    Option (List Ev) :=
  witnessP m init events (· = b) fuel

/-- Union over several initial states; `none` if any search did not exhaust. -/
def allBranches (m : Instr S Ev L E) (inits : List S) (events : List Ev) (fuel : Nat := 64) :
    Option (List (L × E)) :=
  inits.foldlM (fun acc i => (reachableBranches m i events fuel).map (·.foldl insertNew acc)) []

end TpuSyncVerify.Coverage
