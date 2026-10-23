import TpuSyncVerify.Transfer.Reshard.Receive.Model

/-! # `Recv`: structural lemmas on `List Pool`

Part of `TpuSyncVerify.Transfer.Reshard.Receive`. -/

namespace TpuSyncVerify.Transfer.Reshard

open TpuSyncVerify.Transfer (Lifecycle)

namespace Recv

/-! ## Structural lemmas on `List Pool` -/

theorem launchPass_poolOps (canLaunch : Nat → Bool) :
    ∀ ps : List Pool, poolOps (launchPass canLaunch ps).1 = poolOps ps + (launchPass canLaunch ps).2
  | [] => rfl
  | p :: ps => by
    have ih := launchPass_poolOps canLaunch ps
    simp only [launchPass]
    split
    · rename_i h
      have hst : p.stage = .received := by
        simp only [Bool.and_eq_true, beq_iff_eq] at h; exact h.1
      simp only [poolOps, hst, PoolStage.holdsOp, Bool.false_eq_true, ↓reduceIte]
      omega
    · simp only [poolOps]
      omega

theorem launchPass_completed_eq (canLaunch : Nat → Bool) (ps : List Pool) (r : Nat) :
    prereqsCompleted (launchPass canLaunch ps).1 r = prereqsCompleted ps r := by
  induction ps with
  | nil => rfl
  | cons p ps ih =>
    simp only [launchPass]
    split
    · rename_i h
      have hst : p.stage = .received := by
        simp only [Bool.and_eq_true, beq_iff_eq] at h; exact h.1
      simp only [prereqsCompleted, List.all_cons, hst] at ih ⊢
      rw [ih]; rfl
    · simp only [prereqsCompleted, List.all_cons] at ih ⊢
      rw [ih]

theorem launchPass_allCompleted_false (canLaunch : Nat → Bool) :
    ∀ ps : List Pool, allCompleted ps = false → allCompleted (launchPass canLaunch ps).1 = false
  | [], h => by simp [allCompleted] at h
  | p :: ps, h => by
    simp only [allCompleted, List.all_cons, Bool.and_eq_false_imp] at h
    simp only [launchPass]
    split
    · simp [allCompleted]
    · simp only [allCompleted, List.all_cons, Bool.and_eq_false_imp]
      intro hp
      exact launchPass_allCompleted_false canLaunch ps (h hp)

theorem launchPass_rankWave (canLaunch : Nat → Bool) (full : List Pool)
    (hcan : ∀ r, canLaunch r = prereqsCompleted full r) :
    ∀ ps : List Pool,
      (ps.all fun p => !p.stage.launched || prereqsCompleted full p.rank) = true →
      ((launchPass canLaunch ps).1.all fun p =>
        !p.stage.launched || prereqsCompleted (launchPass canLaunch full).1 p.rank) = true
  | [], _ => rfl
  | p :: ps, h => by
    simp only [List.all_cons, Bool.and_eq_true] at h
    have ih := launchPass_rankWave canLaunch full hcan ps h.2
    simp only [launchPass]
    split
    · rename_i hc
      simp only [Bool.and_eq_true, beq_iff_eq] at hc
      have hln : ({ p with stage := .queued } : Pool).stage.launched = true := rfl
      simp only [List.all_cons, Bool.and_eq_true, launchPass_completed_eq, hln,
        Bool.not_true, Bool.false_or]
      rw [← hcan p.rank]
      exact ⟨hc.2, by simpa [launchPass_completed_eq] using ih⟩
    · simp only [List.all_cons, Bool.and_eq_true, launchPass_completed_eq]
      exact ⟨h.1, by simpa [launchPass_completed_eq] using ih⟩

theorem launchPass_preserves_rankWaveOrder (ps : List Pool) (h : rankWaveOrder ps = true) :
    rankWaveOrder (launchPass (prereqsCompleted ps) ps).1 = true := by
  unfold rankWaveOrder at h ⊢
  exact launchPass_rankWave (prereqsCompleted ps) ps (fun _ => rfl) ps h

theorem poolOps_set_eq {ps : List Pool} {idx : Nat} {p p' : Pool}
    (hget : ps[idx]? = some p) (hh : p'.stage.holdsOp = p.stage.holdsOp) :
    poolOps (ps.set idx p') = poolOps ps := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst hget
      simp [List.set_cons_zero, poolOps, hh]
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      simp [List.set_cons_succ, poolOps, ih hget]

theorem poolOps_set_drop {ps : List Pool} {idx : Nat} {p p' : Pool}
    (hget : ps[idx]? = some p) (hh : p.stage.holdsOp = true) (hh' : p'.stage.holdsOp = false) :
    poolOps (ps.set idx p') + 1 = poolOps ps ∧ 0 < poolOps ps := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst hget
      simp only [List.set_cons_zero, poolOps, hh, hh', Bool.false_eq_true, ↓reduceIte]
      omega
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      have ⟨heq, hpos⟩ := ih hget
      simp only [List.set_cons_succ, poolOps]
      omega

theorem allCompleted_eq_false_of_ne {ps : List Pool} {idx : Nat} {p : Pool}
    (hget : ps[idx]? = some p) (hne : p.stage ≠ .completed) :
    allCompleted ps = false := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst q
      have hbeq : (p.stage == .completed) = false := beq_false_of_ne hne
      simp [allCompleted, hbeq]
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      unfold allCompleted at ih ⊢
      simp [ih hget]

theorem prereqsCompleted_set_same {ps : List Pool} {idx : Nat} {p p' : Pool}
    (hget : ps[idx]? = some p) (hr : p'.rank = p.rank)
    (hc : (p'.stage == .completed) = (p.stage == .completed)) (r : Nat) :
    prereqsCompleted (ps.set idx p') r = prereqsCompleted ps r := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst hget
      simp [List.set_cons_zero, prereqsCompleted, hr, hc]
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      unfold prereqsCompleted at ih ⊢
      simp only [List.set_cons_succ, List.all_cons, ih hget]

theorem rankWaveOrder_set_same {ps : List Pool} {idx : Nat} {p : Pool} {st : PoolStage}
    (hget : ps[idx]? = some p)
    (hl : st.launched = p.stage.launched)
    (hc : (st == .completed) = (p.stage == .completed)) :
    rankWaveOrder (ps.set idx { p with stage := st }) = rankWaveOrder ps := by
  have hpre : ∀ r, prereqsCompleted (ps.set idx { p with stage := st }) r = prereqsCompleted ps r :=
    prereqsCompleted_set_same hget rfl hc
  unfold rankWaveOrder
  have key : ∀ (xs : List Pool) (i : Nat), xs[i]? = some p →
      ((xs.set i { p with stage := st }).all fun q =>
        !q.stage.launched || prereqsCompleted (ps.set idx { p with stage := st }) q.rank) =
      (xs.all fun q => !q.stage.launched || prereqsCompleted ps q.rank) := by
    intro xs i hi
    induction xs generalizing i with
    | nil => simp at hi
    | cons q qs ih =>
      cases i with
      | zero =>
        simp only [List.getElem?_cons_zero, Option.some.injEq] at hi
        subst hi
        simp only [List.set_cons_zero, List.all_cons, hl, hpre]
      | succ i =>
        simp only [List.getElem?_cons_succ] at hi
        simp only [List.set_cons_succ, List.all_cons]
        rw [ih i hi, hpre]
  exact key ps idx hget

theorem prereqsCompleted_set_completed {ps : List Pool} {idx : Nat} {p : Pool}
    (hget : ps[idx]? = some p) (r : Nat) (h : prereqsCompleted ps r = true) :
    prereqsCompleted (ps.set idx { p with stage := .completed }) r = true := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    simp only [prereqsCompleted, List.all_cons, Bool.and_eq_true] at h
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst hget
      simp [List.set_cons_zero, prereqsCompleted, h.2]
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      simp only [List.set_cons_succ, prereqsCompleted, List.all_cons, Bool.and_eq_true]
      exact ⟨h.1, ih hget h.2⟩

theorem rankWaveOrder_set_completed {ps : List Pool} {idx : Nat} {p : Pool}
    (hget : ps[idx]? = some p) (hl : p.stage.launched = true) (h : rankWaveOrder ps = true) :
    rankWaveOrder (ps.set idx { p with stage := .completed }) = true := by
  unfold rankWaveOrder at h ⊢
  have key : ∀ (xs : List Pool) (i : Nat), xs[i]? = some p →
      (xs.all fun q => !q.stage.launched || prereqsCompleted ps q.rank) = true →
      ((xs.set i { p with stage := .completed }).all fun q =>
        !q.stage.launched || prereqsCompleted (ps.set idx { p with stage := .completed }) q.rank) = true := by
    intro xs i hi hxs
    induction xs generalizing i with
    | nil => simp at hi
    | cons q qs ih =>
      simp only [List.all_cons, Bool.and_eq_true] at hxs
      have hmono : ∀ q' : Pool,
          (!q'.stage.launched || prereqsCompleted ps q'.rank) = true →
          (!q'.stage.launched ||
            prereqsCompleted (ps.set idx { p with stage := .completed }) q'.rank) = true := by
        intro q' hq'
        simp only [Bool.or_eq_true] at hq' ⊢
        rcases hq' with hq' | hq'
        · exact Or.inl hq'
        · exact Or.inr (prereqsCompleted_set_completed hget q'.rank hq')
      cases i with
      | zero =>
        simp only [List.getElem?_cons_zero, Option.some.injEq] at hi
        subst q
        simp only [List.set_cons_zero, List.all_cons, Bool.and_eq_true]
        have hp : (!({ p with stage := .completed } : Pool).stage.launched ||
            prereqsCompleted (ps.set idx { p with stage := .completed }) p.rank) = true := by
          have h1 := hmono p hxs.1
          rw [hl] at h1
          exact h1
        refine ⟨hp, ?_⟩
        rw [List.all_eq_true]
        intro q' hq'
        exact hmono q' (List.all_eq_true.mp hxs.2 q' hq')
      | succ i =>
        simp only [List.getElem?_cons_succ] at hi
        simp only [List.set_cons_succ, List.all_cons, Bool.and_eq_true]
        exact ⟨hmono q hxs.1, ih i hi hxs.2⟩
  exact key ps idx hget h

end Recv

end TpuSyncVerify.Transfer.Reshard
