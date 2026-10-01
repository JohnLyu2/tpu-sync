import TpuSyncVerify.Common.System

/-!
# Bounded model checking

Breadth-first search over a `System` for a state satisfying `bad`, keeping one
witness trace per state. Used as a cheap sanity check on a model (does the
scenario we expect to be bad actually show up? does a candidate fix remove it?)
before investing in an inductive proof, and as the proof method for models
whose state space is small enough to exhaust.

The result distinguishes an exhausted state space (`safe`) from a search that
ran out of depth (`outOfFuel`): only the former is a verification result.
-/

namespace TpuSyncVerify.ModelCheck

/-- Outcome of a bounded search. -/
inductive Result (Ev : Type) where
  /-- Every reachable state was visited and none is bad. -/
  | safe
  /-- No bad state within the depth bound; the state space was not exhausted. -/
  | outOfFuel
  /-- A trace from the initial state to a bad state. -/
  | counterexample (trace : List Ev)
  deriving Repr, DecidableEq

variable {S Ev : Type} [DecidableEq S]

private def dedupe (seen : List S) (fresh : List (S × List Ev)) : List (S × List Ev) :=
  (fresh.foldl (fun (acc : List S × List (S × List Ev)) p =>
    if acc.1.contains p.1 then acc else (p.1 :: acc.1, p :: acc.2)) (seen, [])).2

private def search (step : S → Ev → Option S) (events : List Ev) (bad : S → Bool) :
    Nat → List (S × List Ev) → List S → Result Ev
  | 0, _, _ => .outOfFuel
  | fuel + 1, frontier, seen =>
    match frontier.find? (fun p => bad p.1) with
    | some (_, tr) => .counterexample tr.reverse
    | none =>
      let next := frontier.flatMap fun (s, tr) =>
        events.filterMap fun e => (step s e).map fun s' => (s', e :: tr)
      let fresh := dedupe seen next
      if fresh.isEmpty then .safe
      else search step events bad fuel fresh (seen ++ fresh.map (·.1))

/-- Search `sys` for a state satisfying `bad`, trying every event in `events`
at every state, to a depth of `fuel` events. -/
def check (sys : System S Ev) (events : List Ev) (bad : S → Bool) (fuel : Nat := 32) :
    Result Ev :=
  search sys.step events bad fuel [(sys.init, [])] [sys.init]

end TpuSyncVerify.ModelCheck
