/-!
# Transition systems

A model in this library is a *guarded, executable* step function: `step s e`
is `some s'` when event `e` is enabled in state `s`, and `none` otherwise. One
definition then serves three purposes:

* **replay** — `run` checks a concrete trace, so a scenario can be confirmed
  or refuted by `decide`;
* **search** — `TpuSyncVerify.ModelCheck` explores small instances exhaustively;
* **proof** — `Reachable` and `reachable_induction` give the induction
  principle for proving an invariant on every reachable state.

Keeping the relation definitional in the step function means the guards used
by proofs are exactly the guards used by replay and search; they cannot drift
apart.
-/

namespace TpuSyncVerify

/-- A transition system: an initial state and a guarded step function. -/
structure System (S Ev : Type) where
  init : S
  step : S → Ev → Option S

namespace System

variable {S Ev : Type} (sys : System S Ev)

/-- Replay `evs` from `s`; `none` if some event along the way is disabled. -/
def runFrom (s : S) (evs : List Ev) : Option S :=
  evs.foldlM sys.step s

/-- Replay `evs` from the initial state. -/
def run (evs : List Ev) : Option S :=
  sys.runFrom sys.init evs

/-- States reachable from the initial state through enabled events. -/
inductive Reachable : S → Prop
  | init : Reachable sys.init
  | step {s s' : S} {e : Ev} : Reachable s → sys.step s e = some s' → Reachable s'

/-- An invariant holds on every reachable state once it holds initially and is
preserved by every enabled event. -/
theorem reachable_induction {P : S → Prop}
    (hinit : P sys.init)
    (hstep : ∀ s e s', P s → sys.step s e = some s' → P s')
    {s : S} (h : sys.Reachable s) : P s := by
  induction h with
  | init => exact hinit
  | step _ hse ih => exact hstep _ _ _ ih hse

/-- Replay never leaves the reachable states. -/
theorem runFrom_reachable {s : S} (hs : sys.Reachable s) :
    ∀ (evs : List Ev) {s' : S}, sys.runFrom s evs = some s' → sys.Reachable s' := by
  intro evs
  induction evs generalizing s with
  | nil =>
    intro s' h
    simp [runFrom] at h
    exact h ▸ hs
  | cons e evs ih =>
    intro s' h
    simp only [runFrom, List.foldlM_cons] at h
    cases hse : sys.step s e with
    | none => simp [hse] at h
    | some s₁ =>
      simp only [hse] at h
      exact ih (Reachable.step hs hse) h

/-- The end state of a successful replay from the initial state is reachable. -/
theorem run_reachable {evs : List Ev} {s : S} (h : sys.run evs = some s) :
    sys.Reachable s :=
  sys.runFrom_reachable Reachable.init evs h

/-- Replaying `evs₁ ++ evs₂` is the same as replaying `evs₁` then `evs₂`. -/
theorem runFrom_append :
    ∀ (evs₁ evs₂ : List Ev) {s s₁ s₂ : S},
      sys.runFrom s evs₁ = some s₁ →
      sys.runFrom s₁ evs₂ = some s₂ →
      sys.runFrom s (evs₁ ++ evs₂) = some s₂
  | [], evs₂, _, _, _, h₁, h₂ => by
    simp [runFrom] at h₁; subst h₁; exact h₂
  | e :: evs₁, evs₂, s, _, _, h₁, h₂ => by
    simp only [runFrom, List.cons_append, List.foldlM_cons] at h₁ ⊢
    cases hse : sys.step s e with
    | none => simp [hse] at h₁
    | some s' =>
      simp only [hse] at h₁ ⊢
      exact runFrom_append evs₁ evs₂ h₁ h₂

end System

end TpuSyncVerify
