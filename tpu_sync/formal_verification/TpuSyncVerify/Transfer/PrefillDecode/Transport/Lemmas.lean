import TpuSyncVerify.Transfer.PrefillDecode.Transport.Model

/-! # `Transport`: arithmetic over `natSum`

Part of `TpuSyncVerify.Transfer.PrefillDecode.Transport`. -/

namespace TpuSyncVerify.Transfer.PrefillDecode.Transport

open TpuSyncVerify TpuSyncVerify.Transfer

/-! ## Arithmetic over `natSum` -/

theorem natSum_append : ∀ (l₁ l₂ : List Nat), natSum (l₁ ++ l₂) = natSum l₁ + natSum l₂
  | [], _ => by simp [natSum]
  | n :: ns, l₂ => by simp [natSum, natSum_append ns l₂, Nat.add_assoc]

theorem le_natSum_of_mem : ∀ {l : List Nat} {a : Nat}, a ∈ l → a ≤ natSum l
  | n :: ns, a, h => by
    simp only [natSum]
    rcases List.mem_cons.mp h with rfl | h
    · exact Nat.le_add_right _ _
    · exact Nat.le_trans (le_natSum_of_mem h) (Nat.le_add_left _ _)

theorem natSum_le_length_mul : ∀ {l : List Nat} {k : Nat}, (∀ n ∈ l, n ≤ k) →
    natSum l ≤ l.length * k
  | [], _, _ => by simp [natSum]
  | n :: ns, k, h => by
    simp only [natSum, List.length_cons, Nat.succ_mul]
    have hn := h n (List.mem_cons_self ..)
    have hns := natSum_le_length_mul (fun m hm => h m (List.mem_cons_of_mem _ hm))
    omega

theorem all_eq_of_natSum_ge : ∀ {l : List Nat} {k : Nat}, (∀ n ∈ l, n ≤ k) →
    l.length * k ≤ natSum l → ∀ n ∈ l, n = k
  | [], _, _, _, _, h => by simp at h
  | n :: ns, k, hle, hsum, m, hm => by
    simp only [natSum, List.length_cons, Nat.succ_mul] at hsum
    have hn := hle n (List.mem_cons_self ..)
    have hns := natSum_le_length_mul (fun m hm => hle m (List.mem_cons_of_mem _ hm))
    rcases List.mem_cons.mp hm with rfl | hm
    · omega
    · exact all_eq_of_natSum_ge (fun m hm => hle m (List.mem_cons_of_mem _ hm))
        (by omega) m hm

theorem eq_zero_of_natSum_eq_zero {l : List Nat} (h : natSum l = 0) : ∀ m ∈ l, m = 0 :=
  fun _ hm => Nat.le_zero.mp (h ▸ le_natSum_of_mem hm)

theorem natSum_replicate_zero : ∀ n, natSum (List.replicate n 0) = 0
  | 0 => rfl
  | n + 1 => by simp [List.replicate_succ, natSum, natSum_replicate_zero n]

theorem natSum_set : ∀ {l : List Nat} {i a x : Nat}, l[i]? = some a →
    natSum (l.set i x) + a = natSum l + x
  | [], i, _, _, h => by simp at h
  | n :: ns, 0, a, x, h => by
    simp at h; subst h; simp [natSum, Nat.add_comm, Nat.add_left_comm]
  | n :: ns, i + 1, a, x, h => by
    simp only [List.getElem?_cons_succ] at h
    simp only [List.set_cons_succ, natSum]
    have := natSum_set (x := x) h
    omega

theorem natSum_map_set {α : Type} (f : α → Nat) {l : List α} {i : Nat} {a x : α}
    (h : l[i]? = some a) :
    natSum ((l.set i x).map f) + f a = natSum (l.map f) + f x := by
  rw [List.map_set]
  exact natSum_set (by simp [h])

def countEq (k : Nat) : List Nat → Nat
  | [] => 0
  | n :: ns => (if n = k then 1 else 0) + countEq k ns

theorem countEq_le_length (k : Nat) : ∀ l : List Nat, countEq k l ≤ l.length
  | [] => Nat.le_refl _
  | n :: ns => by
    simp only [countEq, List.length_cons]
    have := countEq_le_length k ns
    split <;> omega

theorem countEq_eq_length_iff (k : Nat) : ∀ l : List Nat,
    countEq k l = l.length ↔ ∀ n ∈ l, n = k
  | [] => by simp [countEq]
  | n :: ns => by
    simp only [countEq, List.length_cons, List.mem_cons, forall_eq_or_imp]
    have hle := countEq_le_length k ns
    have ih := countEq_eq_length_iff k ns
    constructor
    · intro h
      split at h
      · exact ⟨‹_›, ih.mp (by omega)⟩
      · omega
    · rintro ⟨rfl, h⟩
      simp [ih.mpr h]; omega

theorem countEq_set : ∀ {l : List Nat} {i a x k : Nat}, l[i]? = some a → a ≠ k →
    countEq k (l.set i x) = countEq k l + (if x = k then 1 else 0)
  | [], i, _, _, _, h, _ => by simp at h
  | n :: ns, 0, a, x, k, h, hne => by
    simp at h; subst h; simp [countEq, hne]; omega
  | n :: ns, i + 1, a, x, k, h, hne => by
    simp only [List.getElem?_cons_succ] at h
    simp only [List.set_cons_succ, countEq, countEq_set h hne]
    omega

theorem getD_eq_of_getElem? : ∀ {l : List Nat} {i a d : Nat}, l[i]? = some a → l.getD i d = a
  | [], _, _, _, h => by simp at h
  | n :: ns, 0, a, d, h => by simp at h; subst h; rfl
  | n :: ns, i + 1, a, d, h => by
    simp only [List.getElem?_cons_succ] at h
    simp only [List.getD_cons_succ]
    exact getD_eq_of_getElem? h


end TpuSyncVerify.Transfer.PrefillDecode.Transport
