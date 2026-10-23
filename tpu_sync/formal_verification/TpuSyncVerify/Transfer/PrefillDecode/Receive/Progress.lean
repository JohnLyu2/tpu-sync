import TpuSyncVerify.Transfer.PrefillDecode.Receive.Invariant

/-! # `Recv`: progress and eventual settlement

Part of `TpuSyncVerify.Transfer.PrefillDecode.Receive`. -/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)

namespace Recv

/-! ### Progress and eventual settlement -/

/-- Remaining steps needed to drain all in-flight operations once draining. -/
def drainRank (s : Recv) : Nat :=
  s.pushes + (if s.pullPending then 1 else 0) + s.pending +
    (s.issued - s.ready) + (s.issued - s.retired)

/-- While draining and not yet settled, some event in `drainEvents` is enabled,
preserves `draining`, and strictly decreases `drainRank`. -/
theorem drain_step {s : Recv} (h : Inv s) (hdr : s.life.draining = true)
    (hnd : s.life.done = false) :
    ∃ e s', step s e = some s' ∧ s'.life.draining = true ∧ drainRank s' < drainRank s := by
  have hif : 0 < s.life.inFlight := by
    cases h0 : s.life.inFlight
    · have := h.life.prompt hdr h0; simp [hnd] at this
    · omega
  have hacc := h.accounted
  unfold Accounted at hacc
  have hr := h.retired_le
  have hy := h.ready_le
  by_cases hp : 0 < s.pushes
  · have hs₁ : step s .pushEnd = some { s with life := s.life.endOpLocked, pushes := s.pushes - 1 } := by
      simp [step, pushEnd]; omega
    exact ⟨.pushEnd, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩
  · by_cases hq : s.pullPending = true
    · have hs₁ : step s (.pullReply true) = some { s with life := s.life.endOpLocked, pullPending := false } := by
        simp [step, pullReply, hq]
      exact ⟨.pullReply true, _, hs₁, by simp [hdr], by simp [drainRank, hq]⟩
    · by_cases hpend : 0 < s.pending
      · have hs₁ : step s (.h2dIssue true) = some { s with pending := s.pending - 1, life := s.life.endOpLocked } := by
          simp [step, h2dIssue, hdr]; omega
        exact ⟨.h2dIssue true, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩
      · by_cases hrd : s.ready < s.issued
        · have hs₁ : step s .h2dReady = some { s with ready := s.ready + 1 } := by
            simp [step, h2dReady, hrd]
          exact ⟨.h2dReady, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩
        · have hret : s.retired < s.ready := by
            cases hqp : s.pullPending <;> simp_all <;> omega
          have hs₁ : step s (.h2dDone true) =
              some { s with retired := s.retired + 1, completed := s.completed + 1, life := s.life.endOpLocked } := by
            simp [step, h2dDone, hret, hnd, hdr]
          exact ⟨.h2dDone true, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩

/-- Every reachable receive session can settle and release its staging buffer
in a finite number of steps (`System.settles_of_rank` over `drainRank`, with
`drain_step` as the one-step argument). -/
theorem reachable_can_settle {n : Nat} {s : Recv}
    (h : (sysPush n).Reachable s ∨ (sysLoad n).Reachable s) :
    ∃ evs s', (sysPush n).runFrom s evs = some s' ∧
      s'.life.done = true ∧ s'.life.hasStaging = false := by
  have hinv := h.elim reachable_inv_push reachable_inv_load
  have hcancel : step s .cancel = some { s with life := s.life.finishLocked false } := rfl
  have hinv₁ := step_inv hinv hcancel
  obtain ⟨evs, s', hrun, ⟨hinv', _⟩, hd'⟩ :=
    (sysPush n).settles_of_rank (Inv := fun s => Inv s ∧ s.life.draining = true)
      (Done := fun s => s.life.done = true) drainRank
      (fun s ⟨hi, hdr⟩ hnd => by
        obtain ⟨e, s₁, hs₁, hdr₁, hlt⟩ := drain_step hi hdr (by simpa using hnd)
        exact ⟨e, s₁, hs₁, ⟨step_inv hi hs₁, hdr₁⟩, hlt⟩)
      ⟨hinv₁, by simp⟩
  refine ⟨.cancel :: evs, s', ?_, hd', by rw [hinv'.life.staging, hd']; rfl⟩
  simp only [System.runFrom, sysPush, List.foldlM_cons, hcancel]
  exact hrun


end Recv

end TpuSyncVerify.Transfer.PrefillDecode
