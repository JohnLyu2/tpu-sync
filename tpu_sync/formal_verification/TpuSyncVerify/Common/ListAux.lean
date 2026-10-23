/-!
# List and boolean-set helpers

Generic helper lemmas on `List` indexing, `List.set`, and `countTrue` used by
the layer-indexed transfer pipeline and multi-request models.
-/

namespace TpuSyncVerify

/-- Number of `true`s in a boolean list. -/
def countTrue : List Bool → Nat
  | [] => 0
  | b :: bs => (if b then 1 else 0) + countTrue bs

theorem lt_length_of_getElem?_eq {α : Type} {l : List α} {i : Nat} {a : α}
    (h : l[i]? = some a) : i < l.length :=
  (List.getElem?_eq_some_iff.mp h).1

theorem mem_set_cases {α : Type} {l : List α} {i : Nat} {x y : α}
    (h : y ∈ l.set i x) : y = x ∨ y ∈ l := by
  induction l generalizing i with
  | nil => simp at h
  | cons a as ih =>
    cases i with
    | zero =>
      simp only [List.set_cons_zero, List.mem_cons] at h
      rcases h with rfl | h
      · exact Or.inl rfl
      · exact Or.inr (List.mem_cons_of_mem a h)
    | succ i =>
      simp only [List.set_cons_succ, List.mem_cons] at h
      rcases h with rfl | h
      · exact Or.inr List.mem_cons_self
      · rcases ih h with rfl | h
        · exact Or.inl rfl
        · exact Or.inr (List.mem_cons_of_mem a h)

theorem getElem?_mem {α : Type} {l : List α} {i : Nat} {x : α}
    (h : l[i]? = some x) : x ∈ l := by
  induction l generalizing i with
  | nil => simp at h
  | cons a as ih =>
    cases i with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at h
      subst h; exact List.mem_cons_self
    | succ i =>
      simp only [List.getElem?_cons_succ] at h
      exact List.mem_cons_of_mem a (ih h)

/-- Adding `i` to a set: membership afterwards is `i` or membership before. -/
theorem mem_of_set_true {L : List Bool} {i j : Nat} (h : (L.set i true)[j]? = some true) :
    j = i ∨ L[j]? = some true := by
  by_cases hji : j = i
  · exact Or.inl hji
  · right; rwa [List.getElem?_set_ne (Ne.symm hji)] at h

/-- Removing `i` from a set: membership afterwards implies membership before. -/
theorem mem_of_set_false {L : List Bool} {i j : Nat} (h : (L.set i false)[j]? = some true) :
    L[j]? = some true := by
  by_cases hji : j = i
  · subst hji
    by_cases hi : j < L.length
    · rw [List.getElem?_set_self hi] at h; cases h
    · rw [List.getElem?_eq_none (by rw [List.length_set]; omega)] at h; cases h
  · rwa [List.getElem?_set_ne (Ne.symm hji)] at h

theorem mem_of_set_false_ne {L : List Bool} {i j : Nat} (h : (L.set i false)[j]? = some true) :
    j ≠ i := by
  intro rfl
  by_cases hi : j < L.length
  · rw [List.getElem?_set_self hi] at h; cases h
  · rw [List.getElem?_eq_none (by rw [List.length_set]; omega)] at h; cases h

theorem set_true_self {L : List Bool} {i : Nat} (hi : L[i]? = some false) :
    (L.set i true)[i]? = some true :=
  List.getElem?_set_self (lt_length_of_getElem?_eq hi)

theorem set_true_of_mem {L : List Bool} {i j : Nat} (hi : L[i]? = some false)
    (hj : L[j]? = some true) : (L.set i true)[j]? = some true := by
  by_cases hji : j = i
  · subst hji; rw [hi] at hj; cases hj
  · rw [List.getElem?_set_ne (Ne.symm hji)]; exact hj

theorem false_of_not_true {l₁ l₂ : List Bool} {i : Nat} (hlen : l₁.length = l₂.length)
    (hi : l₁[i]? = some false) (himp : l₂[i]? = some true → False) : l₂[i]? = some false := by
  have hlt : i < l₂.length := by have := lt_length_of_getElem?_eq hi; omega
  have heq := List.getElem?_eq_getElem hlt
  cases hb : l₂[i]
  · rw [heq, hb]
  · rw [hb] at heq; exact (himp heq).elim

/-- No layer is in an empty set. -/
theorem not_mem_replicate_false {n i : Nat} (h : (List.replicate n false)[i]? = some true) :
    False := by
  simp only [List.getElem?_replicate] at h
  split at h <;> cases h

theorem countTrue_replicate_false : ∀ n, countTrue (List.replicate n false) = 0
  | 0 => rfl
  | n + 1 => by simp [List.replicate_succ, countTrue, countTrue_replicate_false n]

theorem countTrue_le_length : ∀ l : List Bool, countTrue l ≤ l.length
  | [] => Nat.le_refl _
  | b :: bs => by
    have := countTrue_le_length bs
    simp only [countTrue, List.length_cons]; split <;> omega

theorem countTrue_set_true : ∀ {l : List Bool} {i : Nat}, l[i]? = some false →
    countTrue (l.set i true) = countTrue l + 1
  | [], i, h => by simp at h
  | b :: bs, 0, h => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h
    subst h; simp [countTrue]; omega
  | b :: bs, i + 1, h => by
    simp only [List.getElem?_cons_succ] at h
    simp only [List.set_cons_succ, countTrue, countTrue_set_true h]; omega

theorem countTrue_set_false : ∀ {l : List Bool} {i : Nat}, l[i]? = some true →
    countTrue (l.set i false) + 1 = countTrue l
  | [], i, h => by simp at h
  | b :: bs, 0, h => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h
    subst h; simp [countTrue]; omega
  | b :: bs, i + 1, h => by
    simp only [List.getElem?_cons_succ] at h
    have ih := countTrue_set_false h
    simp only [List.set_cons_succ, countTrue]; omega

/-- A set with as many members as slots is full. -/
theorem all_true_of_countTrue_eq_length : ∀ {l : List Bool}, countTrue l = l.length →
    ∀ i, i < l.length → l[i]? = some true
  | [], _, i, hi => by simp at hi
  | b :: bs, h, i, hi => by
    have hle := countTrue_le_length bs
    simp only [countTrue, List.length_cons] at h
    cases b with
    | false => simp at h; omega
    | true =>
      cases i with
      | zero => simp
      | succ i =>
        simp only [List.getElem?_cons_succ]
        exact all_true_of_countTrue_eq_length (by simp at h; omega) i (by simp at hi; omega)

theorem exists_true_of_countTrue_pos : ∀ {l : List Bool}, 0 < countTrue l →
    ∃ i < l.length, l[i]? = some true
  | [], h => by simp [countTrue] at h
  | true :: bs, _ => ⟨0, by simp, rfl⟩
  | false :: bs, h => by
    simp [countTrue] at h
    obtain ⟨i, hi, hget⟩ := exists_true_of_countTrue_pos h
    exact ⟨i + 1, by simp; omega, hget⟩

theorem exists_false_lt : ∀ {l : List Bool} {k : Nat},
    k ≤ l.length → countTrue l < k → ∃ i < k, l[i]? = some false
  | _, 0, _, hcnt => by omega
  | [], k + 1, hk, _ => by simp at hk
  | false :: bs, k + 1, _, _ => ⟨0, by omega, rfl⟩
  | true :: bs, k + 1, hk, hcnt => by
    simp [countTrue] at hk hcnt
    obtain ⟨i, hi, hget⟩ := @exists_false_lt bs k (by omega) (by omega)
    exact ⟨i + 1, by omega, hget⟩

theorem exists_diff_of_countTrue_lt : ∀ {l₁ l₂ : List Bool},
    l₁.length = l₂.length → countTrue l₁ < countTrue l₂ →
    ∃ i < l₁.length, l₁[i]? = some false ∧ l₂[i]? = some true
  | [], [], _, hcnt => by simp [countTrue] at hcnt
  | [], _ :: _, hlen, _ => by simp at hlen
  | _ :: _, [], hlen, _ => by simp at hlen
  | b₁ :: bs₁, b₂ :: bs₂, hlen, hcnt => by
    by_cases hb : b₁ = false ∧ b₂ = true
    · obtain ⟨rfl, rfl⟩ := hb; exact ⟨0, by simp, rfl, rfl⟩
    · simp only [List.length_cons, countTrue] at hlen hcnt
      have hlt : countTrue bs₁ < countTrue bs₂ := by
        cases b₁ <;> cases b₂ <;> simp_all <;> omega
      obtain ⟨i, hi, h₁, h₂⟩ := exists_diff_of_countTrue_lt (by omega) hlt
      exact ⟨i + 1, by simp; omega, h₁, h₂⟩

theorem countTrue_le_of_bound : ∀ {l : List Bool} {k : Nat},
    (∀ i, l[i]? = some true → i < k) → countTrue l ≤ k
  | [], _, _ => by simp [countTrue]
  | false :: bs, k, hb => by
    have hb' : ∀ i, bs[i]? = some true → i < k := fun i hi =>
      Nat.lt_of_succ_lt (hb (i + 1) hi)
    simpa [countTrue] using countTrue_le_of_bound hb'
  | true :: bs, 0, hb => by have := hb 0 rfl; omega
  | true :: bs, k + 1, hb => by
    have hb' : ∀ i, bs[i]? = some true → i < k := fun i hi =>
      Nat.lt_of_succ_lt_succ (hb (i + 1) hi)
    have := countTrue_le_of_bound hb'
    simp only [countTrue, ↓reduceIte]; omega

theorem all_true_lt_of_countTrue : ∀ {l : List Bool} {k : Nat},
    (∀ i, l[i]? = some true → i < k) → k ≤ countTrue l →
    ∀ i < k, l[i]? = some true
  | _, 0, _, _, _, hi => by omega
  | [], k + 1, _, hcnt, _, _ => by simp [countTrue] at hcnt
  | false :: bs, k + 1, hb, hcnt, _, _ => by
    have hb' : ∀ i, bs[i]? = some true → i < k := fun i hi =>
      Nat.lt_of_succ_lt_succ (hb (i + 1) hi)
    have := countTrue_le_of_bound hb'
    simp [countTrue] at hcnt; omega
  | true :: bs, k + 1, _, _, 0, _ => rfl
  | true :: bs, k + 1, hb, hcnt, i + 1, hi => by
    have hb' : ∀ j, bs[j]? = some true → j < k := fun j hj =>
      Nat.lt_of_succ_lt_succ (hb (j + 1) hj)
    simp [countTrue] at hcnt
    exact all_true_lt_of_countTrue hb' (by omega) i (by omega)

end TpuSyncVerify
