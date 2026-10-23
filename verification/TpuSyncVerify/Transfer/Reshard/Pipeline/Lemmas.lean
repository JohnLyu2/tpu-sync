import TpuSyncVerify.Transfer.Reshard.Pipeline.Model

/-! # `Pipeline`: structural lemmas on `good`, `clobberHigherRanks`, and `writePoolHbm`

Part of `TpuSyncVerify.Transfer.Reshard.Pipeline`. -/

namespace TpuSyncVerify.Transfer.Reshard

open TpuSyncVerify.Transfer (Lifecycle)

namespace Pipeline

/-! ## Structural lemmas on `good`, `clobberHigherRanks`, and `writePoolHbm` -/

@[simp] theorem getElem?_replicate_getD {α : Type} (n p : Nat) (x : α) :
    (List.replicate n x)[p]?.getD x = x := by
  rw [List.getElem?_replicate]
  split <;> rfl

@[simp] theorem getD_replicate_self {α : Type} (n p : Nat) (x : α) :
    (List.replicate n x).getD p x = x := by
  rw [List.getD_eq_getElem?_getD, getElem?_replicate_getD]

theorem getD_set_self {α : Type} {l : List α} {p : Nat} {v d : α} (hp : p < l.length) :
    (l.set p v).getD p d = v := by
  rw [List.getD_eq_getElem?_getD, List.getElem?_set_self hp]; rfl

theorem getD_set_ne {α : Type} {l : List α} {p q : Nat} {v d : α} (hne : p ≠ q) :
    (l.set p v).getD q d = l.getD q d := by
  rw [List.getD_eq_getElem?_getD, List.getD_eq_getElem?_getD, List.getElem?_set_ne hne]

theorem exists_getElem?_of_mem {α : Type} {l : List α} {x : α} (h : x ∈ l) :
    ∃ p < l.length, l[p]? = some x := by
  obtain ⟨p, hp, rfl⟩ := List.getElem_of_mem h
  exact ⟨p, hp, List.getElem?_eq_getElem hp⟩

@[simp] theorem length_good (n : Nat) : (good n).length = n := by
  simp [good]

theorem getElem?_good {n p : Nat} (hp : p < n) :
    (good n)[p]? = some (.kv p) := by
  simp [good, hp]

theorem getD_good {n p : Nat} (hp : p < n) (d : Cell) :
    (good n).getD p d = .kv p := by
  rw [List.getD_eq_getElem?_getD, getElem?_good hp]; rfl

theorem eq_good_of_getElem? {xs : List Cell} {n : Nat}
    (hlen : xs.length = n) (h : ∀ p < n, xs[p]? = some (.kv p)) :
    xs = good n := by
  apply List.ext_getElem?
  intro p
  by_cases hp : p < n
  · rw [h p hp, getElem?_good hp]
  · have h₁ : xs[p]? = none := List.getElem?_eq_none (by omega)
    have h₂ : (good n)[p]? = none := List.getElem?_eq_none (by simp; omega)
    rw [h₁, h₂]

@[simp] theorem length_clobberHigherRanks (pools : List Pool) (r : Nat) (hbm : List Cell) :
    (clobberHigherRanks pools r hbm).length = min pools.length hbm.length := by
  simp [clobberHigherRanks]

@[simp] theorem length_writePoolHbm (pools : List Pool) (p r : Nat) (val : Cell) (hbm : List Cell) :
    (writePoolHbm pools p r val hbm).length = min pools.length hbm.length := by
  simp [writePoolHbm]

theorem getElem?_clobberHigherRanks_of_not_lt {pools : List Pool} {hbm : List Cell}
    {r q : Nat} {pool : Pool} (hpool : pools[q]? = some pool) (hnlt : ¬(r < pool.rank)) :
    (clobberHigherRanks pools r hbm)[q]? = hbm[q]? := by
  unfold clobberHigherRanks
  rw [List.getElem?_zipWith, hpool]
  cases hbm[q]? <;> simp [hnlt]

theorem getElem?_writePoolHbm_self {pools : List Pool} {hbm : List Cell}
    {p r : Nat} {val : Cell} (hp : p < min pools.length hbm.length) :
    (writePoolHbm pools p r val hbm)[p]? = some val := by
  unfold writePoolHbm
  apply List.getElem?_set_self
  simp [hp]

theorem getElem?_writePoolHbm_of_ne_of_not_lt {pools : List Pool} {hbm : List Cell}
    {p q r : Nat} {val : Cell} {pool : Pool}
    (hne : p ≠ q) (hpool : pools[q]? = some pool) (hnlt : ¬(r < pool.rank)) :
    (writePoolHbm pools p r val hbm)[q]? = hbm[q]? := by
  unfold writePoolHbm
  rw [List.getElem?_set_ne hne]
  exact getElem?_clobberHigherRanks_of_not_lt hpool hnlt


end Pipeline

end TpuSyncVerify.Transfer.Reshard
