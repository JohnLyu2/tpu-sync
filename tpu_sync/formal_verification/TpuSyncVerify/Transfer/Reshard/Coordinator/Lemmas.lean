import TpuSyncVerify.Transfer.Reshard.Coordinator.Model

/-! # `Coordinator`: structural helper lemmas

Part of `TpuSyncVerify.Transfer.Reshard.Coordinator`. -/

namespace TpuSyncVerify.Transfer.Reshard.Coordinator

open TpuSyncVerify

open TpuSyncVerify.Transfer.Reshard.Registry

/-! ## Part II — Structural Helper Lemmas -/

/-- `abandonIfClaimed` preserves `Registry.Inv`. -/
theorem abandonIfClaimed_inv (reg : RegGen) (owner : Nat) (hinv : Registry.Inv reg) :
    Registry.Inv (abandonIfClaimed reg owner) := by
  unfold abandonIfClaimed
  cases h : RegGen.step reg (.abandonClaim owner) with
  | none => exact hinv
  | some reg' => exact Registry.step_preserves_inv hinv h

/-- When `reg` has at most the single coordinator owner `owner`, `abandonIfClaimed`
guarantees `claimedUnits = none` and `claimOwners = []`. -/
theorem abandonIfClaimed_clears_single_owner (reg : RegGen) (units : List Nat) (owner : Nat)
    (h : (reg.claimedUnits = some units ∧ reg.claimOwners = [owner]) ∨
         (reg.claimedUnits = none ∧ reg.claimOwners = [])) :
    (abandonIfClaimed reg owner).claimedUnits = none ∧
    (abandonIfClaimed reg owner).claimOwners = [] := by
  rcases h with ⟨hc, ho⟩ | ⟨hc, ho⟩
  · unfold abandonIfClaimed RegGen.step
    simp [ho]
  · unfold abandonIfClaimed RegGen.step
    simp [ho, hc]

/-- `register` in `.idle` preserves `claimedUnits = none`, `claimOwners = []`,
and `completedUnits = []`. -/
theorem register_preserves_idle_reg (reg reg' : RegGen) (unit : Nat)
    (hc : reg.claimedUnits = none)
    (ho : reg.claimOwners = [])
    (hcomp : reg.completedUnits = [])
    (hstep : RegGen.step reg (.register unit true) = some reg') :
    reg'.claimedUnits = none ∧
    reg'.claimOwners = [] ∧
    reg'.completedUnits = [] := by
  dsimp only [RegGen.step] at hstep
  split at hstep
  · cases hstep
  cases hlook : reg.lookupUnit unit with
  | some cur =>
    simp only [hlook] at hstep
    split at hstep
    · cases hstep
    · injection hstep with h; subst h; exact ⟨hc, ho, hcomp⟩
  | none =>
    simp only [hlook, Option.some.injEq] at hstep
    subst hstep
    exact ⟨hc, ho, hcomp⟩

/-- `lookupAndClaim` from an `.idle` registry state (`claimedUnits = none`,
`claimOwners = []`, `completedUnits = []`) transitions to
`claimedUnits = some units`, `claimOwners = [owner]`, `completedUnits = []`. -/
theorem lookupAndClaim_from_idle_shape (reg reg' : RegGen) (owner : Nat) (units : List Nat)
    (howners : reg.claimOwners = [])
    (hcomp : reg.completedUnits = [])
    (hstep : RegGen.step reg (.lookupAndClaim owner units) = some reg') :
    reg'.claimedUnits = some units ∧
    reg'.claimOwners = [owner] ∧
    reg'.completedUnits = [] := by
  dsimp only [RegGen.step] at hstep
  split at hstep
  · cases hstep
  rename_i h1
  simp only [Bool.or_eq_true, not_or, Bool.not_eq_true] at h1
  obtain ⟨_, hunits_ne⟩ := h1
  split at hstep
  · cases hstep
  split at hstep
  · cases hstep
  have hall_false : allVoted units reg.completedUnits = false := by
    cases units with
    | nil => simp at hunits_ne
    | cons u0 us => simp [allVoted, hcomp]
  simp only [hall_false, Bool.false_eq_true, ↓reduceIte, Option.some.injEq] at hstep
  subst hstep
  simp [howners, hcomp, insertNodup]

/-- `complete` preserves the single-owner claim shape disjunction: either the
claim `(some units, [owner])` remains active or `retireLocked` clears it to
`(none, [])`. -/
theorem complete_preserves_claim_shape (reg reg' : RegGen) (unit : Nat)
    (units : List Nat) (owner : Nat)
    (h : (reg.claimedUnits = some units ∧ reg.claimOwners = [owner]) ∨
         (reg.claimedUnits = none ∧ reg.claimOwners = []))
    (hstep : RegGen.step reg (.complete unit) = some reg') :
    (reg'.claimedUnits = some units ∧ reg'.claimOwners = [owner]) ∨
    (reg'.claimedUnits = none ∧ reg'.claimOwners = []) := by
  dsimp only [RegGen.step] at hstep
  split at hstep
  · cases hstep
  split at hstep
  · injection hstep with h'; subst h'; exact h
  cases hclaim : reg.claimedUnits with
  | some expected =>
    simp only [hclaim] at hstep
    split at hstep
    · injection hstep with h'; subst h'
      exact Or.inr ⟨rfl, rfl⟩
    · injection hstep with h'; subst h'
      rcases h with ⟨hc, ho⟩ | ⟨hc, _⟩
      · rw [hclaim] at hc; injection hc with hc; subst hc
        exact Or.inl ⟨rfl, ho⟩
      · simp [hclaim] at hc
  | none =>
    simp only [hclaim] at hstep
    injection hstep with h'; subst h'
    rcases h with ⟨hc, _⟩ | ⟨_, ho⟩
    · simp [hclaim] at hc
    · exact Or.inr ⟨rfl, ho⟩

/-- `DstUnitState.receivePush` preserves `stagingLeaseHeld = sessionArmed`. -/
theorem receivePush_leaseMatches (d : DstUnitState) (srcUnits : List Nat) (srcUnit : Nat)
    (h : d.stagingLeaseHeld = d.sessionArmed) :
    (d.receivePush srcUnits srcUnit).stagingLeaseHeld =
    (d.receivePush srcUnits srcUnit).sessionArmed := by
  dsimp only [DstUnitState.receivePush]
  split
  · exact h
  · split <;> simp [h]


end TpuSyncVerify.Transfer.Reshard.Coordinator
