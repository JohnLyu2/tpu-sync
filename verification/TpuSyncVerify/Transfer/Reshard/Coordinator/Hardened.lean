import TpuSyncVerify.Transfer.Reshard.Coordinator.Invariant

/-! # `Coordinator`: hardened cleanup policy guarantee (`NoOrphansWhenAborted`)

Part of `TpuSyncVerify.Transfer.Reshard.Coordinator`. -/

namespace TpuSyncVerify.Transfer.Reshard.Coordinator

open TpuSyncVerify

open TpuSyncVerify.Transfer.Reshard.Registry

/-! ## Part IV — Hardened Cleanup Policy Guarantee (`NoOrphansWhenAborted`) -/

/-- **No Orphaned Sessions, Staging Leases, or Registry Claims on Abort
(`NoOrphansWhenAborted`)**:
When `s.phase = .aborted`, every destination unit is disarmed (`sessionArmed = false`)
and holds no staging lease (`stagingLeaseHeld = false`), and the registry claim
is released (`s.reg.claimedUnits = none ∧ s.reg.claimOwners = []`). -/
def NoOrphansWhenAborted (s : CoordState) : Prop :=
  s.phase = .aborted →
    (∀ d ∈ s.dstStates, d.sessionArmed = false ∧ d.stagingLeaseHeld = false) ∧
    s.reg.claimedUnits = none ∧
    s.reg.claimOwners = []

theorem step_disarmAndAbandon_preserves_noOrphans {s s' : CoordState} {e : Ev}
    (hcoord : CoordInv s)
    (hstep : CoordState.step .disarmAndAbandonOnFailure s e = some s') :
    NoOrphansWhenAborted s' := by
  cases e with
  | registerProducer srcUnit =>
    dsimp only [CoordState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hphase
    simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hphase
    cases hreg : RegGen.step s.reg (.register srcUnit true) with
    | none => simp [hreg] at hstep
    | some reg' =>
      simp only [hreg, Option.some.injEq] at hstep
      subst hstep
      intro hab; rw [hphase] at hab; contradiction

  | startPlan planOk =>
    dsimp only [CoordState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hphase
    simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hphase
    cases hreg : RegGen.step s.reg (.lookupAndClaim s.claimOwner s.srcUnits) with
    | none => simp [hreg] at hstep
    | some regClaimed =>
      simp only [hreg] at hstep
      obtain ⟨_, ho, hcomp, hdst⟩ := hcoord.idleShape hphase
      obtain ⟨hc', ho', _⟩ :=
        lookupAndClaim_from_idle_shape s.reg regClaimed s.claimOwner s.srcUnits ho hcomp hreg
      split at hstep
      · injection hstep with h; subst h
        intro hab; contradiction
      · injection hstep with h; subst h
        intro _
        refine ⟨hdst, ?_⟩
        exact abandonIfClaimed_clears_single_owner regClaimed s.srcUnits s.claimOwner
          (Or.inl ⟨hc', ho'⟩)

  | armDstResult dstUnit ok =>
    dsimp only [CoordState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hphase
    simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hphase
    split at hstep
    · cases hstep
    injection hstep with h; subst h
    intro hab; rw [hphase] at hab; contradiction

  | finishArmBarrier =>
    dsimp only [CoordState.step] at hstep
    split at hstep
    · cases hstep
    rename_i h1
    simp only [Bool.or_eq_true, not_or, bne_iff_ne, ne_eq, Decidable.not_not] at h1
    obtain ⟨hphase, _⟩ := h1
    split at hstep
    · injection hstep with h; subst h
      intro hab; contradiction
    · injection hstep with h; subst h
      intro _
      obtain ⟨hc, ho, _⟩ := hcoord.claimedArming hphase
      refine ⟨?_, abandonIfClaimed_clears_single_owner s.reg s.srcUnits s.claimOwner (Or.inl ⟨hc, ho⟩)⟩
      intro d hd
      simp only [List.mem_map] at hd
      obtain ⟨d0, _, rfl⟩ := hd
      exact ⟨rfl, rfl⟩

  | sendSrcResult srcUnit ok =>
    dsimp only [CoordState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hphase
    simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hphase
    split at hstep
    · cases hstep
    split at hstep <;>
    · injection hstep with h; subst h
      intro hab; rw [hphase] at hab; contradiction

  | finishSendBarrier =>
    dsimp only [CoordState.step] at hstep
    split at hstep
    · cases hstep
    rename_i h1
    simp only [Bool.or_eq_true, not_or, bne_iff_ne, ne_eq, Decidable.not_not] at h1
    obtain ⟨hphase, _⟩ := h1
    split at hstep
    · injection hstep with h; subst h
      intro hab; contradiction
    · injection hstep with h; subst h
      intro _
      refine ⟨?_, abandonIfClaimed_clears_single_owner s.reg s.srcUnits s.claimOwner (hcoord.dispatchingShape hphase)⟩
      intro d hd
      simp only [List.mem_map] at hd
      obtain ⟨d0, _, rfl⟩ := hd
      exact ⟨rfl, rfl⟩

/-- **Main Theorem for Hardened Cleanup Policy (`reachable_disarmAndAbandon_no_orphans`)**:
Under `CleanupPolicy.disarmAndAbandonOnFailure`, every reachable state satisfies
`NoOrphansWhenAborted`: if the coordinator aborts at any stage, zero destination
units are left with armed `ReshardReceiveSession`s or held `PoolStagingLease`s,
and the `RequestBlockRegistry` claim is released. -/
theorem reachable_disarmAndAbandon_no_orphans {srcUnits dstUnits : List Nat}
    {claimOwner : Nat} {s : CoordState}
    (hr : (CoordState.sys .disarmAndAbandonOnFailure srcUnits dstUnits claimOwner).Reachable s) :
    NoOrphansWhenAborted s := by
  induction hr with
  | init => intro h; contradiction
  | @step s₁ s₂ e hr₁ hstep _ =>
    exact step_disarmAndAbandon_preserves_noOrphans (reachable_coord_inv hr₁) hstep


end TpuSyncVerify.Transfer.Reshard.Coordinator
