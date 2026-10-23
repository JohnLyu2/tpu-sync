import TpuSyncVerify.Transfer.Reshard.PoolStaging.Arena

/-! # `PoolStaging`: idempotence, conservation, and disjointness proofs

Part of `TpuSyncVerify.Transfer.Reshard.PoolStaging`. -/

namespace TpuSyncVerify.Transfer.Reshard.PoolStaging

open TpuSyncVerify

/-! ## Part II — Idempotence, Conservation, and Disjointness Proofs -/

/-- If every block in `blockIds` is already present in `cur` or `seen`,
`missingBlocksAux` returns `[]`. -/
theorem missingBlocksAux_empty_of_covered (cur : Option Lease) (blockIds seen : List Nat)
    (hcov : ∀ b ∈ blockIds,
      alreadyLeased cur b = true ∨ seen.contains b = true) :
    missingBlocksAux cur blockIds seen = [] := by
  induction blockIds generalizing seen with
  | nil => rfl
  | cons b rest ih =>
    simp only [missingBlocksAux]
    have hb := hcov b List.mem_cons_self
    have hcond : (alreadyLeased cur b || seen.contains b) = true :=
      Bool.or_eq_true_iff.mpr hb
    simp only [hcond, ↓reduceIte]
    exact ih seen (fun b' hb' => hcov b' (List.mem_cons_of_mem b hb'))

/-- **Idempotent Re-Acquisition Lemma (`KVCacheManagerBase::AcquirePoolStagingLease`, `if (missing.empty()) return absl::OkStatus();`)**:
if every block in `blockIds` is already leased to `uuid`, `missingBlocks` is
empty and `acquireLease` returns `some a` without touching `freeSlots` or
`leases`. -/
theorem acquireLease_idempotent (a : Arena) (uuid : Nat) (l : Lease)
    (blockIds : List Nat)
    (hcur : a.lookupLease uuid = some l)
    (hsub : ∀ b ∈ blockIds, (l.lookupSlot b).isSome = true) :
    a.acquireLease uuid blockIds = some a := by
  unfold Arena.acquireLease
  rw [hcur]
  have hempty : missingBlocks (some l) blockIds = [] := by
    unfold missingBlocks
    apply missingBlocksAux_empty_of_covered
    intro b hb
    exact Or.inl (hsub b hb)
  simp [hempty]

/-- `allocateMissing` conservation: when `free.length ≥ missing.length`,
`allocateMissing` succeeds and `free'.length + lease'.slots.length =
free.length + base.slots.length`. -/
theorem allocateMissing_slot_sum (missing free : List Nat) (base : Lease)
    (hlen : missing.length ≤ free.length) :
    ∃ free' lease',
      allocateMissing missing free base = some (free', lease') ∧
      free'.length + lease'.slots.length = free.length + base.slots.length ∧
      free' ++ lease'.slots = free.drop missing.length ++ base.slots ++ free.take missing.length := by
  induction missing generalizing free base with
  | nil =>
    refine ⟨free, base, rfl, rfl, ?_⟩
    simp
  | cons b bs ih =>
    cases free with
    | nil =>
      simp at hlen
    | cons s rest =>
      simp only [List.length_cons, Nat.add_le_add_iff_right] at hlen
      simp only [allocateMissing]
      obtain ⟨free', lease', halloc, hsum, hperm⟩ :=
        ih rest ⟨base.slotByBlock ++ [(b, s)], base.slots ++ [s]⟩ hlen
      refine ⟨free', lease', halloc, ?_, ?_⟩
      · simp only [List.length_append, List.length_cons, List.length_nil] at hsum ⊢
        omega
      · rw [hperm]
        simp [List.drop_succ_cons, List.take_succ_cons, List.append_assoc]

/-- Sum of leased slot counts across a lease table. -/
def leasedSlotCount (leases : List (Nat × Lease)) : Nat :=
  (leases.map (fun p => p.2.slots.length)).sum

/-- Total slots tracked by an arena (`freeSlots` + all active leases). -/
def Arena.totalSlots (a : Arena) : Nat :=
  a.freeSlots.length + leasedSlotCount a.leases

/-- All slot indices currently present in `a` (`freeSlots` followed by all
leased slot lists). -/
def Arena.allSlots (a : Arena) : List Nat :=
  a.freeSlots ++ (a.leases.map (fun p => p.2.slots)).flatten

/-- Well-formedness of a single `Lease`: every `(b, s)` in `slotByBlock` takes
its slot `s` from `l.slots`. -/
def LeaseWf (l : Lease) : Prop :=
  ∀ b s, (b, s) ∈ l.slotByBlock → s ∈ l.slots

theorem lookupSlot_mem_slots {l : Lease} (hwf : LeaseWf l) {b s : Nat}
    (h : l.lookupSlot b = some s) :
    s ∈ l.slots := by
  unfold Lease.lookupSlot at h
  cases hfind : l.slotByBlock.find? (fun p => p.1 == b) with
  | none => simp [hfind] at h
  | some p =>
    simp only [hfind, Option.map_some, Option.some.injEq] at h
    have hmem := List.mem_of_find?_eq_some hfind
    have hp1 : p.1 = b := by
      have := List.find?_some hfind
      simpa using this
    rcases p with ⟨b', s'⟩
    simp only at h hp1
    subst h hp1
    exact hwf b' s' hmem

/-- Pairwise disjointness and conservation predicate on an `Arena`:
1. `totalSlots = numSlots` (no slots leaked or fabricated),
2. `allSlots.Nodup` (no slot is simultaneously free and leased, or leased to
   two distinct entries in `leases`),
3. `(leases.map Prod.fst).Nodup` (at most one lease entry per `uuid`),
4. Every active lease satisfies `LeaseWf`. -/
structure ArenaInv (a : Arena) : Prop where
  conservation : a.totalSlots = a.numSlots
  nodupSlots : a.allSlots.Nodup
  nodupUuids : (a.leases.map Prod.fst).Nodup
  leasesWf : ∀ u l, (u, l) ∈ a.leases → LeaseWf l

theorem init_inv (numSlots : Nat) : ArenaInv (Arena.init numSlots) where
  conservation := by
    simp [Arena.init, Arena.totalSlots, leasedSlotCount]
  nodupSlots := by
    simp [Arena.init, Arena.allSlots, List.nodup_range]
  nodupUuids := by
    simp [Arena.init]
  leasesWf := by
    intro u l hmem
    simp [Arena.init] at hmem

/-- Helper: if `(leases.map (·.2.slots)).flatten.Nodup`, then two elements
`(u₁, l₁) ∈ leases` and `(u₂, l₂) ∈ leases` with `u₁ ≠ u₂` appear at distinct
positions and therefore have disjoint slot lists. -/
theorem leases_disjoint_of_nodup {leases : List (Nat × Lease)}
    (hslots : (leases.map (fun p => p.2.slots)).flatten.Nodup)
    {u₁ u₂ : Nat} {l₁ l₂ : Lease}
    (hm₁ : (u₁, l₁) ∈ leases) (hm₂ : (u₂, l₂) ∈ leases) (hne : u₁ ≠ u₂) :
    ∀ s, s ∈ l₁.slots → s ∈ l₂.slots → False := by
  induction leases with
  | nil => cases hm₁
  | cons hd tl ih =>
    simp only [List.map_cons, List.flatten_cons, List.nodup_append] at hslots
    obtain ⟨_, hslots_tl, hdisj_hd⟩ := hslots
    rcases List.mem_cons.mp hm₁ with rfl | hm₁_tl
    · rcases List.mem_cons.mp hm₂ with h_eq | hm₂_tl
      · cases h_eq; exact absurd rfl hne
      · intro s hs₁ hs₂
        have hmem_flat : s ∈ (tl.map (fun p => p.2.slots)).flatten :=
          List.mem_flatten.mpr ⟨l₂.slots, List.mem_map.mpr ⟨(u₂, l₂), hm₂_tl, rfl⟩, hs₂⟩
        exact hdisj_hd s hs₁ s hmem_flat rfl
    · rcases List.mem_cons.mp hm₂ with rfl | hm₂_tl
      · intro s hs₁ hs₂
        have hmem_flat : s ∈ (tl.map (fun p => p.2.slots)).flatten :=
          List.mem_flatten.mpr ⟨l₁.slots, List.mem_map.mpr ⟨(u₁, l₁), hm₁_tl, rfl⟩, hs₁⟩
        exact hdisj_hd s hs₂ s hmem_flat rfl
      · exact ih hslots_tl hm₁_tl hm₂_tl

theorem lookupLease_mem {a : Arena} {uuid : Nat} {l : Lease}
    (h : a.lookupLease uuid = some l) :
    (uuid, l) ∈ a.leases := by
  unfold Arena.lookupLease at h
  cases hfind : a.leases.find? (fun p => p.1 == uuid) with
  | none => simp [hfind] at h
  | some p =>
    simp only [hfind, Option.map_some, Option.some.injEq] at h
    have hmem := List.mem_of_find?_eq_some hfind
    have hp1 : p.1 = uuid := by
      have := List.find?_some hfind
      simpa using this
    rcases p with ⟨u', l'⟩
    simp only at h hp1
    subst h hp1
    exact hmem

/-- **No Slot Aliasing Theorem (`KVCacheManagerBase::AcquirePoolStagingLease`, `KVCacheManagerBase::ReleasePoolStagingLeases`)**:
In any arena satisfying `ArenaInv`, two distinct UUIDs `u₁ ≠ u₂` never resolve
any block IDs `b₁, b₂` (even identical device block IDs on two concurrent
sessions) to the same host staging slot. -/
theorem no_slot_aliasing_between_distinct_uuids {a : Arena} (hinv : ArenaInv a)
    {u₁ u₂ b₁ b₂ s₁ s₂ : Nat} (hne : u₁ ≠ u₂)
    (hr₁ : a.resolveBlockSlot u₁ b₁ = some s₁)
    (hr₂ : a.resolveBlockSlot u₂ b₂ = some s₂) :
    s₁ ≠ s₂ := by
  unfold Arena.resolveBlockSlot at hr₁ hr₂
  cases hl₁ : a.lookupLease u₁ with
  | none => simp [hl₁] at hr₁
  | some l₁ =>
    cases hl₂ : a.lookupLease u₂ with
    | none => simp [hl₂] at hr₂
    | some l₂ =>
      simp only [hl₁, hl₂] at hr₁ hr₂
      have hm₁ := lookupLease_mem hl₁
      have hm₂ := lookupLease_mem hl₂
      have hs₁ := lookupSlot_mem_slots (hinv.leasesWf u₁ l₁ hm₁) hr₁
      have hs₂ := lookupSlot_mem_slots (hinv.leasesWf u₂ l₂ hm₂) hr₂
      have hflat : (a.leases.map (fun p => p.2.slots)).flatten.Nodup := by
        have h := hinv.nodupSlots
        unfold Arena.allSlots at h
        exact (List.nodup_append.mp h).2.1
      have hdisj := leases_disjoint_of_nodup hflat hm₁ hm₂ hne
      intro heq
      subst heq
      exact hdisj s₁ hs₁ hs₂


end TpuSyncVerify.Transfer.Reshard.PoolStaging
