import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.PrefillDecode.Pipeline

/-!
# Within-Layer Block-Index Gather, Reordering, Subset Validation & Custom Host Staging

Citations are to tpu-sync `1fa06d1`;
`send.cc`, `recv.cc`, `bt.cc` and `mgr.cc` abbreviate as in `Pipeline.lean`.

Stage 4 (spatial block refinement) of the prefill-to-decode model: refines
`Pipeline`'s one-`Cell`-per-layer abstraction (`Pipeline` Assumption A1) down to
per-block arrays `Layer → BlockId → BlockCell`, modelling:

1. **Producer block registration & pull validation** (`send.cc:60-66, 82-130`):
   - `PopulateRegisteredBlocks` (`send.cc:82-95`): `NotifyForRead` rejects
     duplicate block IDs in `registered_block_ids_`.
   - `ValidateRequestedBlocksLocked` (`send.cc:97-114`): `ValidateAndBeginPull`
     rejects empty requests, rejects any block ID not in
     `registered_block_set_` (allowing strict subset pulls), and rejects
     duplicate producer block IDs.
2. **Contiguous-run DMA coalescing** (`BuildCoalescedCopySpec`, `send.cc:203-232`):
   - Merges adjacent `(src_block_ids[k], dst_block_ids[k])` pairs with
     `src[k] == src[k-1] + 1 && dst[k] == dst[k-1] + 1` into contiguous
     `(src_offset, dst_offset, size)` DMA runs (`CopyRun`).
   - Proves `execCoalesced_buildCoalescedSpec`: executing the coalesced DMA runs
     is extensionally identical on every memory state to executing elementwise
     block-by-block copies (`execElementwise`).
3. **Consumer staging allocation & custom host staging blocks**
   (`AllocateStagingForLoad`, `recv.cc:215-261`):
   - Supports both caller-supplied custom host block IDs
     (`local_host_block_ids.has_value()`, `recv.cc:220-223`, tested in
     `LocalOrchestratedTransferToCustomHostBlock`) and allocator-backed host
     staging (`staging_allocator_->Acquire(unique_local_bids.size())`,
     `recv.cc:228-260`).
4. **Dual-permutation `BuildLoadCopyPlan`** (`recv.cc:263-331`, `send.cc:270-320`):
   - **Transport order (`remote_order`, `recv.cc:281-297`):** stable-sorts
     request indices by `remote_block_ids` so both `producer_remote_block_ids`
     (staged into producer host slots `0 … k-1` by `StartPush`) and
     `transport_host_block_ids` (where `BlockTransport` lands incoming blocks on
     the consumer host) are permuted by the same permutation $\pi_{\text{remote}}$.
   - **H2D order (`local_order`, `recv.cc:299-328`):** stable-sorts request
     indices by `local_block_ids`, deduplicates identical `(local_bid, host_bid)`
     pairs, and coalesces contiguous `(h2d_host_block_ids, h2d_local_block_ids)`
     runs via `BuildCoalescedCopySpec`.
   - Proves that $\pi_{\text{remote}}$ and $\pi_{\text{local}}$ cancel across the
     3-stage copy chain (`d2hStage` → `landStage` → `h2dStage`), routing every
     requested `remote_block_ids[i]` into `decodeStaging[local_host_block_ids[i]]`
     and `decodeHbm[local_block_ids[i]]` while leaving all non-targeted host and
     device blocks untouched.
5. **Multi-layer asynchronous `BlockPipeline` integration**:
   - Couples the dual-permutation `CopyPlan` and coalesced DMA specs with
     `Pipeline`'s asynchronous layer-indexed state machine (`d2hReady l`,
     `h2hDone l ok`, `land l`, `h2dReady l`, `reclaim`, `reseatPrefillStaging`,
     `reseatDecodeStaging`).
   - Proves `BlockPipeline.reachable_safe`: on every reachable state, all
     temporal session/buffer/handshake properties (`Pipeline.Safe`) hold together
     with `BlockValidationSafe`, `BlockPublicationCorrect`, and
     `CustomHostStagingCorrect`.
-/

namespace TpuSyncVerify.Transfer.PrefillDecode

namespace BlockOrdering

/-! ## 1. Producer Registration & Pull Validation (`send.cc:82-130`) -/

/-- Decidable list duplicate check (`PopulateRegisteredBlocks`, `send.cc:82-95`). -/
def noDuplicates : List Nat → Bool
  | [] => true
  | x :: xs => (!xs.contains x) && noDuplicates xs

theorem noDuplicates_iff_nodup (xs : List Nat) :
    noDuplicates xs = true ↔ xs.Nodup := by
  induction xs with
  | nil => simp [noDuplicates]
  | cons x xs ih =>
    simp [noDuplicates, List.nodup_cons, ih]

/-- `PopulateRegisteredBlocks` (`send.cc:60-66, 82-95`): `NotifyForRead`
accepts `registered_block_ids` iff it contains no duplicate block ID. -/
def validateRegistration (registered : List Nat) : Bool :=
  noDuplicates registered

theorem validateRegistration_iff (registered : List Nat) :
    validateRegistration registered = true ↔ registered.Nodup :=
  noDuplicates_iff_nodup registered

/-- `ValidateRequestedBlocksLocked` (`send.cc:97-114`): `ValidateAndBeginPull`
accepts `requested_block_ids` iff:
1. `!requested_block_ids.empty()` (`send.cc:99-102`),
2. every requested block is in `registered_block_set_` (`send.cc:105-108`), and
3. `requested_block_ids` has no duplicate producer block IDs (`send.cc:109-112`). -/
def validateRequestedBlocks (registered requested : List Nat) : Bool :=
  (!requested.isEmpty) && requested.all (fun b => registered.contains b) &&
    noDuplicates requested

theorem validateRequestedBlocks_iff (registered requested : List Nat) :
    validateRequestedBlocks registered requested = true ↔
      requested ≠ [] ∧ (∀ b ∈ requested, b ∈ registered) ∧ requested.Nodup := by
  simp [validateRequestedBlocks, Bool.and_eq_true,
    List.all_eq_true, noDuplicates_iff_nodup, and_assoc]

/-! ## 2. Contiguous-Run DMA Coalescing (`BuildCoalescedCopySpec`, `send.cc:203-232`) -/

/-- One contiguous `(src_offset, dst_offset, size)` DMA copy chunk produced by
`TransferSendSession::BuildCoalescedCopySpec` (`send.cc:203-232`). -/
structure CopyRun where
  srcOffset : Nat
  dstOffset : Nat
  size : Nat
  deriving Repr, DecidableEq

/-- Inner coalescing loop (`send.cc:219-230`): extends `cur` by 1 whenever the
next `(s, d)` pair continues both contiguous runs (`s = cur.srcOffset + cur.size`
and `d = cur.dstOffset + cur.size`), and starts a new run otherwise. -/
def coalesceAux (cur : CopyRun) : List (Nat × Nat) → List CopyRun
  | [] => [cur]
  | (s, d) :: rest =>
    if s = cur.srcOffset + cur.size ∧ d = cur.dstOffset + cur.size then
      coalesceAux { cur with size := cur.size + 1 } rest
    else
      cur :: coalesceAux { srcOffset := s, dstOffset := d, size := 1 } rest

/-- `TransferSendSession::BuildCoalescedCopySpec` (`send.cc:203-232`). -/
def buildCoalescedSpec : List (Nat × Nat) → List CopyRun
  | [] => []
  | (s, d) :: rest => coalesceAux { srcOffset := s, dstOffset := d, size := 1 } rest

/-- Execute a single contiguous DMA run of `sz` blocks from `src[srcOff ..]`
into `dst[dstOff ..]`. -/
def execRun (default : α) (src dst : List α) (srcOff dstOff : Nat) : Nat → List α
  | 0 => dst
  | sz + 1 =>
    execRun default src (dst.set dstOff (src.getD srcOff default))
      (srcOff + 1) (dstOff + 1) sz

/-- Execute a coalesced `CopySpec` (`List CopyRun`) sequentially. -/
def execCoalesced (default : α) (src dst : List α) : List CopyRun → List α
  | [] => dst
  | r :: rs =>
    execCoalesced default src (execRun default src dst r.srcOffset r.dstOffset r.size) rs

/-- Execute an uncoalesced list of `(src_block, dst_block)` pairs one block at a time. -/
def execElementwise (default : α) (src dst : List α) : List (Nat × Nat) → List α
  | [] => dst
  | (s, d) :: rest =>
    execElementwise default src (dst.set d (src.getD s default)) rest

/-- Extending a contiguous DMA run by 1 block at the end equals running the
`sz`-block DMA run followed by setting `(srcOff + sz, dstOff + sz)`. -/
theorem execRun_succ_right (default : α) (src dst : List α) (srcOff dstOff sz : Nat) :
    execRun default src dst srcOff dstOff (sz + 1) =
      (execRun default src dst srcOff dstOff sz).set (dstOff + sz)
        (src.getD (srcOff + sz) default) := by
  induction sz generalizing dst srcOff dstOff with
  | zero => simp [execRun]
  | succ n ih =>
    rw [execRun, ih]
    have h1 : dstOff + 1 + n = dstOff + (n + 1) := by omega
    have h2 : srcOff + 1 + n = srcOff + (n + 1) := by omega
    rw [h1, h2]
    rfl

theorem execCoalesced_coalesceAux (default : α) (src dst : List α)
    (cur : CopyRun) (rest : List (Nat × Nat)) :
    execCoalesced default src dst (coalesceAux cur rest) =
      execElementwise default src
        (execRun default src dst cur.srcOffset cur.dstOffset cur.size) rest := by
  induction rest generalizing dst cur with
  | nil => rfl
  | cons p tail ih =>
    rcases p with ⟨s, d⟩
    simp only [coalesceAux]
    split
    · rename_i hcontig
      rcases hcontig with ⟨hs, hd⟩
      rw [ih]
      simp only [execRun_succ_right, ← hs, ← hd, execElementwise]
    · simp only [execCoalesced, ih, execRun, execElementwise]

/-- **Coalescing equivalence (`send.cc:203-232`):** executing the coalesced DMA
runs produced by `buildCoalescedSpec` is extensionally identical on every source
and destination buffer to executing block-by-block elementwise copies. -/
theorem execCoalesced_buildCoalescedSpec (default : α) (src dst : List α)
    (pairs : List (Nat × Nat)) :
    execCoalesced default src dst (buildCoalescedSpec pairs) =
      execElementwise default src dst pairs := by
  cases pairs with
  | nil => rfl
  | cons p rest =>
    rcases p with ⟨s, d⟩
    simp only [buildCoalescedSpec, execCoalesced_coalesceAux, execRun, execElementwise]

/-! ### Fundamental lemmas for `execElementwise` -/

theorem length_execElementwise (default : α) (src dst : List α)
    (pairs : List (Nat × Nat)) :
    (execElementwise default src dst pairs).length = dst.length := by
  induction pairs generalizing dst with
  | nil => rfl
  | cons p rest ih =>
    rcases p with ⟨s, d⟩
    simp only [execElementwise, ih, List.length_set]

theorem length_execCoalesced (default : α) (src dst : List α)
    (pairs : List (Nat × Nat)) :
    (execCoalesced default src dst (buildCoalescedSpec pairs)).length = dst.length := by
  rw [execCoalesced_buildCoalescedSpec, length_execElementwise]

/-- Frame lemma: any destination block `b` not targeted by `pairs` retains its
initial value across `execElementwise`. -/
theorem getElem?_execElementwise_of_not_mem (default : α) (src dst : List α)
    (pairs : List (Nat × Nat)) (b : Nat) (hb : ∀ p ∈ pairs, p.2 ≠ b) :
    (execElementwise default src dst pairs)[b]? = dst[b]? := by
  induction pairs generalizing dst with
  | nil => rfl
  | cons p rest ih =>
    rcases p with ⟨s, d⟩
    simp only [execElementwise]
    rw [ih]
    · have hne : d ≠ b := hb (s, d) (.head _)
      exact List.getElem?_set_ne hne
    · intro q hq
      exact hb q (.tail _ hq)

/-- Target read-back lemma: if `(s, d) ∈ pairs`, `d < dst.length`, and every
pair in `pairs` targeting `d` has source `s`, then `execElementwise` writes
`src.getD s default` at destination block `d`. -/
theorem getElem?_execElementwise_of_mem (default : α) (src dst : List α)
    (pairs : List (Nat × Nat)) (s d : Nat)
    (hmem : (s, d) ∈ pairs) (hd : d < dst.length)
    (huniq : ∀ p ∈ pairs, p.2 = d → p.1 = s) :
    (execElementwise default src dst pairs)[d]? = some (src.getD s default) := by
  induction pairs generalizing dst with
  | nil => cases hmem
  | cons p rest ih =>
    rcases p with ⟨s₀, d₀⟩
    simp only [execElementwise]
    by_cases hrest : (s, d) ∈ rest
    · apply ih (dst.set d₀ (src.getD s₀ default)) hrest
      · rw [List.length_set]; exact hd
      · intro q hq hqd
        exact huniq q (.tail _ hq) hqd
    · rcases List.mem_cons.mp hmem with heq | hmem'
      · cases heq
        rw [getElem?_execElementwise_of_not_mem]
        · exact List.getElem?_set_self hd
        · intro q hq hqd
          have hqs : q.1 = s := huniq q (.tail _ hq) hqd
          rcases q with ⟨qs, qd⟩
          subst hqs hqd
          exact hrest hq
      · exact (hrest hmem').elim

/-! ## 3. Consumer Staging Allocation & Dual-Permutation `CopyPlan` (`recv.cc:215-331`) -/

/-- How consumer host staging blocks are chosen in `AllocateStagingForLoad`
(`recv.cc:215-261`):
- `allocator stagedBlocks`: deduplicates `local_block_ids` and assigns blocks
  drawn from `staging_allocator_->Acquire` (`recv.cc:228-260`).
- `customHost hostBlocks`: uses caller-specified `local_host_block_ids` directly
  without touching `staging_allocator_` (`recv.cc:220-223`). -/
inductive StagingMode where
  | allocator (stagedBlocks : List Nat)
  | customHost (hostBlocks : List Nat)
  deriving Repr, DecidableEq

/-- Look up or assign a host block for each local block ID, matching the
`local_to_host` loop in `AllocateStagingForLoad` (`recv.cc:244-259`). -/
def assignHostBlocksAux (stagedBlocks : List Nat) :
    List Nat → List (Nat × Nat) → Nat → Option (List Nat)
  | [], _, _ => some []
  | localBid :: rest, map, nextIdx =>
    match map.lookup localBid with
    | some hostBid =>
      (assignHostBlocksAux stagedBlocks rest map nextIdx).map (hostBid :: ·)
    | none =>
      match stagedBlocks[nextIdx]? with
      | some hostBid =>
        (assignHostBlocksAux stagedBlocks rest ((localBid, hostBid) :: map) (nextIdx + 1)).map
          (hostBid :: ·)
      | none => none

/-- `TransferReceiveSession::AllocateStagingForLoad` (`recv.cc:215-261`). -/
def allocateStagingForLoad (localBlocks : List Nat) : StagingMode → Option (List Nat)
  | .customHost hostBlocks =>
    if hostBlocks.length = localBlocks.length then some hostBlocks else none
  | .allocator stagedBlocks =>
    assignHostBlocksAux stagedBlocks localBlocks [] 0

/-- A requested `(remote_block_id, local_block_id, local_host_block_id)` triple
at one position in `StartRead`. -/
structure BlockTriple where
  remote : Nat
  local_ : Nat
  host : Nat
  deriving Repr, DecidableEq

/-- Stable insertion sort helper (`std::stable_sort` in `BuildLoadCopyPlan`,
`recv.cc:286-289, 304-307`). -/
def insertBy (le : α → α → Bool) (x : α) : List α → List α
  | [] => [x]
  | y :: ys => if le x y then x :: y :: ys else y :: insertBy le x ys

def sortBy (le : α → α → Bool) : List α → List α
  | [] => []
  | x :: xs => insertBy le x (sortBy le xs)

theorem mem_insertBy (le : α → α → Bool) (x z : α) (ys : List α) :
    z ∈ insertBy le x ys ↔ z = x ∨ z ∈ ys := by
  induction ys with
  | nil => simp [insertBy]
  | cons y ys ih =>
    simp only [insertBy]
    split
    · simp [List.mem_cons]
    · simp only [List.mem_cons, ih]
      exact ⟨fun h => h.elim (fun h1 => Or.inr (Or.inl h1)) (fun h2 => h2.elim Or.inl (fun h3 => Or.inr (Or.inr h3))),
             fun h => h.elim (fun h1 => Or.inr (Or.inl h1)) (fun h2 => h2.elim Or.inl (fun h3 => Or.inr (Or.inr h3)))⟩

theorem mem_sortBy (le : α → α → Bool) (z : α) (xs : List α) :
    z ∈ sortBy le xs ↔ z ∈ xs := by
  induction xs with
  | nil => simp [sortBy]
  | cons x xs ih =>
    simp [sortBy, mem_insertBy, ih]

theorem length_insertBy (le : α → α → Bool) (x : α) (ys : List α) :
    (insertBy le x ys).length = ys.length + 1 := by
  induction ys with
  | nil => rfl
  | cons y ys ih =>
    simp only [insertBy]
    split <;> simp [ih]

theorem length_sortBy (le : α → α → Bool) (xs : List α) :
    (sortBy le xs).length = xs.length := by
  induction xs with
  | nil => rfl
  | cons x xs ih =>
    simp [sortBy, length_insertBy, ih]

theorem nodup_insertBy {le : α → α → Bool} {x : α} {ys : List α}
    (hx : x ∉ ys) (hnd : ys.Nodup) : (insertBy le x ys).Nodup := by
  induction ys with
  | nil => simp [insertBy]
  | cons y ys ih =>
    rw [List.nodup_cons] at hnd
    have hxy : x ≠ y := fun h => hx (by simp [h])
    have hxys : x ∉ ys := fun h => hx (by simp [h])
    simp only [insertBy]
    split
    · rw [List.nodup_cons, List.nodup_cons]
      exact ⟨by simp [hxy, hxys], hnd⟩
    · rw [List.nodup_cons, mem_insertBy]
      refine ⟨?_, ih hxys hnd.2⟩
      rintro (rfl | hy)
      · exact hxy rfl
      · exact hnd.1 hy

theorem nodup_sortBy {le : α → α → Bool} {xs : List α} (hnd : xs.Nodup) :
    (sortBy le xs).Nodup := by
  induction xs with
  | nil => simp [sortBy]
  | cons x xs ih =>
    rw [List.nodup_cons] at hnd
    apply nodup_insertBy _ (ih hnd.2)
    rw [mem_sortBy]
    exact hnd.1

/-- Enumerate a list starting from index `idx` (`(x₀, idx), (x₁, idx + 1), …`). -/
def enumFrom (idx : Nat) : List α → List (α × Nat)
  | [] => []
  | x :: xs => (x, idx) :: enumFrom (idx + 1) xs

theorem length_enumFrom (idx : Nat) (xs : List α) :
    (enumFrom idx xs).length = xs.length := by
  induction xs generalizing idx with
  | nil => rfl
  | cons x xs ih => simp [enumFrom, ih]

theorem snd_ge_of_mem_enumFrom {x : α} {j idx : Nat} {xs : List α}
    (h : (x, j) ∈ enumFrom idx xs) : idx ≤ j := by
  induction xs generalizing idx with
  | nil => cases h
  | cons y ys ih =>
    rcases List.mem_cons.mp h with heq | htail
    · cases heq; exact Nat.le_refl _
    · have := ih htail; omega

theorem snd_lt_of_mem_enumFrom {x : α} {j idx : Nat} {xs : List α}
    (h : (x, j) ∈ enumFrom idx xs) : j < idx + xs.length := by
  induction xs generalizing idx with
  | nil => cases h
  | cons y ys ih =>
    rcases List.mem_cons.mp h with heq | htail
    · cases heq; simp
    · have := ih htail; simp; omega

theorem fst_mem_of_mem_enumFrom {x : α} {j idx : Nat} {xs : List α}
    (h : (x, j) ∈ enumFrom idx xs) : x ∈ xs := by
  induction xs generalizing idx with
  | nil => cases h
  | cons y ys ih =>
    rcases List.mem_cons.mp h with heq | htail
    · cases heq; exact .head _
    · exact .tail _ (ih htail)

theorem exists_mem_enumFrom {x : α} {xs : List α} (idx : Nat) (hx : x ∈ xs) :
    ∃ j, (x, j) ∈ enumFrom idx xs := by
  induction xs generalizing idx with
  | nil => cases hx
  | cons y ys ih =>
    rcases List.mem_cons.mp hx with rfl | htail
    · exact ⟨idx, .head _⟩
    · obtain ⟨j, hj⟩ := ih (idx + 1) htail
      exact ⟨j, .tail _ hj⟩

theorem enumFrom_snd_inj {x₁ x₂ : α} {j idx : Nat} {xs : List α}
    (h₁ : (x₁, j) ∈ enumFrom idx xs) (h₂ : (x₂, j) ∈ enumFrom idx xs) :
    x₁ = x₂ := by
  induction xs generalizing idx with
  | nil => cases h₁
  | cons y ys ih =>
    rcases List.mem_cons.mp h₁ with heq₁ | htail₁ <;>
      rcases List.mem_cons.mp h₂ with heq₂ | htail₂
    · cases heq₁; cases heq₂; rfl
    · cases heq₁
      have := snd_ge_of_mem_enumFrom htail₂
      omega
    · cases heq₂
      have := snd_ge_of_mem_enumFrom htail₁
      omega
    · exact ih htail₁ htail₂

theorem enumFrom_fst_inj [DecidableEq α] {x : α} {j₁ j₂ idx : Nat} {xs : List α}
    (hnd : xs.Nodup)
    (h₁ : (x, j₁) ∈ enumFrom idx xs) (h₂ : (x, j₂) ∈ enumFrom idx xs) :
    j₁ = j₂ := by
  induction xs generalizing idx with
  | nil => cases h₁
  | cons y ys ih =>
    rw [List.nodup_cons] at hnd
    rcases List.mem_cons.mp h₁ with heq₁ | htail₁ <;>
      rcases List.mem_cons.mp h₂ with heq₂ | htail₂
    · cases heq₁; cases heq₂; rfl
    · cases heq₁
      exact (hnd.1 (fst_mem_of_mem_enumFrom htail₂)).elim
    · cases heq₂
      exact (hnd.1 (fst_mem_of_mem_enumFrom htail₁)).elim
    · exact ih hnd.2 htail₁ htail₂

/-- Deduplicate adjacent equal pairs (`recv.cc:315-324` in `BuildLoadCopyPlan`). -/
def dedupAdj [DecidableEq α] : List α → List α
  | [] => []
  | [x] => [x]
  | x :: y :: xs => if x = y then dedupAdj (y :: xs) else x :: dedupAdj (y :: xs)

theorem mem_dedupAdj [DecidableEq α] (z : α) (xs : List α) :
    z ∈ dedupAdj xs ↔ z ∈ xs := by
  induction xs with
  | nil => rfl
  | cons x rest ih =>
    cases rest with
    | nil => rfl
    | cons y ys =>
      simp only [dedupAdj]
      split
      · rename_i hxy
        subst hxy
        rw [ih]
        simp [List.mem_cons]
      · simp [List.mem_cons, ih]

/-- Zip three equal-length block lists into `List BlockTriple`. -/
def zipTriples : List Nat → List Nat → List Nat → List BlockTriple
  | r :: rs, d :: ds, h :: hs => ⟨r, d, h⟩ :: zipTriples rs ds hs
  | _, _, _ => []

/-- The compiled dual-permutation copy plan (`CopyPlan` in `recv.cc:263-331`
coupled with producer `StartPush` staging in `send.cc:306-320`). -/
structure CopyPlan where
  triples : List BlockTriple
  /-- `remote_order` (`recv.cc:281-297`): `triples` sorted by `remote_block_ids`. -/
  remoteSorted : List BlockTriple
  /-- `local_order` (`recv.cc:299-307`): `triples` sorted by `local_block_ids`. -/
  localSorted : List BlockTriple
  /-- `producer_remote_block_ids` sent in `PullStream` (`recv.cc:295`). -/
  producerRemoteBlocks : List Nat
  /-- `transport_host_block_ids` where `BlockTransport` lands blocks (`recv.cc:296`). -/
  transportHostBlocks : List Nat
  /-- Producer D2H pairs `(producer_remote_block_ids[j], j)` (`send.cc:306-320`). -/
  d2hPairs : List (Nat × Nat)
  /-- Network H2H pairs `(j, transport_host_block_ids[j])` (`send.cc:311-312`). -/
  h2hPairs : List (Nat × Nat)
  /-- Consumer H2D pairs `(h2d_host_block_ids[j], h2d_local_block_ids[j])` (`recv.cc:311-325`). -/
  h2dPairs : List (Nat × Nat)
  /-- Coalesced producer D2H `CopySpec` (`send.cc:320`). -/
  d2hSpec : List CopyRun
  /-- Coalesced consumer H2D `CopySpec` (`recv.cc:327-328`). -/
  h2dSpec : List CopyRun
  deriving Repr, DecidableEq

namespace CopyPlan

def numBlocks (p : CopyPlan) : Nat := p.triples.length

end CopyPlan

/-- Build a `CopyPlan` from `triples`, executing the exact dual-permutation
sorting and run-coalescing of `TransferReceiveSession::BuildLoadCopyPlan`
(`recv.cc:263-331`) and `TransferSendSession::StartPush` (`send.cc:306-320`). -/
def buildCopyPlanFromTriples (triples : List BlockTriple) : CopyPlan :=
  let remoteSorted := sortBy (fun a b => a.remote ≤ b.remote) triples
  let localSorted := sortBy (fun a b => a.local_ ≤ b.local_) triples
  let enumRemote := enumFrom 0 remoteSorted
  let d2hPairs := enumRemote.map (fun (t, j) => (t.remote, j))
  let h2hPairs := enumRemote.map (fun (t, j) => (j, t.host))
  let h2dRaw := localSorted.map (fun t => (t.host, t.local_))
  let h2dPairs := dedupAdj h2dRaw
  { triples := triples,
    remoteSorted := remoteSorted,
    localSorted := localSorted,
    producerRemoteBlocks := remoteSorted.map (·.remote),
    transportHostBlocks := remoteSorted.map (·.host),
    d2hPairs := d2hPairs,
    h2hPairs := h2hPairs,
    h2dPairs := h2dPairs,
    d2hSpec := buildCoalescedSpec d2hPairs,
    h2dSpec := buildCoalescedSpec h2dPairs }

/-- `TransferReceiveSession::BuildLoadCopyPlan` (`recv.cc:263-331`). -/
def buildLoadCopyPlan (remoteBlocks localBlocks hostBlocks : List Nat) : CopyPlan :=
  buildCopyPlanFromTriples (zipTriples remoteBlocks localBlocks hostBlocks)

/-! ## 4. Algebraic Dual-Permutation Cancellation (`d2hStage` → `landStage` → `h2dStage`) -/

/-- A single KV block cell at `(layer, block)`. -/
inductive BlockCell where
  | blank
  | kv (layer : Nat) (block : Nat)
  | junk
  deriving Repr, DecidableEq

/-- Layer `l` of prefill HBM with `numBlocks` blocks `[.kv l 0, …, .kv l (numBlocks - 1)]`. -/
def goodBlockLayer (numBlocks l : Nat) : List BlockCell :=
  (List.range numBlocks).map (BlockCell.kv l)

def blankBlockLayer (n : Nat) : List BlockCell :=
  List.replicate n .blank

def junkBlockLayer (n : Nat) : List BlockCell :=
  List.replicate n .junk

theorem length_goodBlockLayer (numBlocks l : Nat) :
    (goodBlockLayer numBlocks l).length = numBlocks := by
  simp [goodBlockLayer]

theorem getD_goodBlockLayer {numBlocks l b : Nat} (hb : b < numBlocks) :
    (goodBlockLayer numBlocks l).getD b .junk = .kv l b := by
  simp [List.getD_eq_getElem?_getD, goodBlockLayer, hb]

theorem getElem?_blankBlockLayer {n b : Nat} (hb : b < n) :
    (blankBlockLayer n)[b]? = some .blank := by
  simp [blankBlockLayer, hb]

/-- Stage 1 (Producer D2H): coalesced gather from `goodBlockLayer numBlocks l`
into contiguous producer host staging `0 … k-1` (`send.cc:320-343`). -/
def d2hStage (l numBlocks : Nat) (plan : CopyPlan) : List BlockCell :=
  execCoalesced .junk (goodBlockLayer numBlocks l) (junkBlockLayer plan.numBlocks) plan.d2hSpec

/-- Stage 2 (Network H2H landing): `BlockTransport` lands producer host blocks
`0 … k-1` into consumer `transport_host_block_ids` (`bt.cc:555-609`). -/
def landStage (l numBlocks numHostBlocks : Nat) (plan : CopyPlan) : List BlockCell :=
  execElementwise .junk (d2hStage l numBlocks plan) (blankBlockLayer numHostBlocks) plan.h2hPairs

/-- Stage 3 (Consumer H2D): coalesced scatter from consumer `h2d_host_block_ids`
into consumer device `h2d_local_block_ids` (`recv.cc:327-328, 655-660`). -/
def h2dStage (l numBlocks numHostBlocks : Nat) (plan : CopyPlan) : List BlockCell :=
  execCoalesced .junk (landStage l numBlocks numHostBlocks plan) (blankBlockLayer numBlocks) plan.h2dSpec

/-- Well-formedness of `triples` for an `(numBlocks, numHostBlocks)` transfer:
1. All remote and local block IDs are in `< numBlocks`, and all host block IDs
   are in `< numHostBlocks`.
2. `triples.Nodup` (satisfied whenever remote block IDs are distinct, as checked
   by `ValidateRequestedBlocksLocked` at `send.cc:109-112`).
3. Host block assignment is injective on distinct triples (`AllocateStagingForLoad`
   assigns distinct staged blocks to distinct local blocks, and requested pairs
   are distinct).
4. Duplicate local block IDs map to the same host block ID (`recv.cc:320-323`). -/
structure ValidTriples (numBlocks numHostBlocks : Nat) (triples : List BlockTriple) : Prop where
  remote_lt : ∀ t ∈ triples, t.remote < numBlocks
  local_lt : ∀ t ∈ triples, t.local_ < numBlocks
  host_lt : ∀ t ∈ triples, t.host < numHostBlocks
  nodup : triples.Nodup
  host_inj : ∀ t₁ ∈ triples, ∀ t₂ ∈ triples, t₁.host = t₂.host → t₁ = t₂
  local_consistent : ∀ t₁ ∈ triples, ∀ t₂ ∈ triples, t₁.local_ = t₂.local_ → t₁.host = t₂.host

/-- Stage 1 correctness: for every `(t, j) ∈ enumFrom 0 plan.remoteSorted`,
producer staging slot `j` receives `.kv l t.remote`. -/
theorem d2hStage_get_enum {l numBlocks : Nat} {triples : List BlockTriple}
    (hv : ValidTriples numBlocks numHostBlocks triples)
    {t : BlockTriple} {j : Nat}
    (hj : (t, j) ∈ enumFrom 0 (buildCopyPlanFromTriples triples).remoteSorted) :
    (d2hStage l numBlocks (buildCopyPlanFromTriples triples))[j]? =
      some (.kv l t.remote) := by
  let plan := buildCopyPlanFromTriples triples
  have hspec : plan.d2hSpec = buildCoalescedSpec plan.d2hPairs := rfl
  change (execCoalesced .junk (goodBlockLayer numBlocks l) (junkBlockLayer plan.numBlocks) plan.d2hSpec)[j]? = _
  rw [hspec, execCoalesced_buildCoalescedSpec]
  have ht_mem : t ∈ triples := by
    have := fst_mem_of_mem_enumFrom hj
    exact (mem_sortBy _ _ _).mp this
  have hj_lt : j < (junkBlockLayer plan.numBlocks).length := by
    have hlt := snd_lt_of_mem_enumFrom hj
    simp only [junkBlockLayer, List.length_replicate, CopyPlan.numBlocks, plan,
      buildCopyPlanFromTriples, length_sortBy] at hlt ⊢
    omega
  have hmem_pair : (t.remote, j) ∈ plan.d2hPairs := by
    simp only [plan, buildCopyPlanFromTriples, List.mem_map]
    exact ⟨(t, j), hj, rfl⟩
  rw [getElem?_execElementwise_of_mem .junk _ _ plan.d2hPairs t.remote j hmem_pair hj_lt]
  · rw [getD_goodBlockLayer (hv.remote_lt t ht_mem)]
  · intro p hp hp2
    simp only [plan, buildCopyPlanFromTriples, List.mem_map] at hp
    rcases hp with ⟨⟨t', j'⟩, hj', rfl⟩
    simp only at hp2
    subst hp2
    have heq := enumFrom_snd_inj hj' hj
    subst heq
    rfl

/-- Stage 2 correctness (requested host block): for every `t ∈ triples`,
consumer host block `t.host` receives `.kv l t.remote`. -/
theorem landStage_get_requested {l numBlocks numHostBlocks : Nat}
    {triples : List BlockTriple}
    (hv : ValidTriples numBlocks numHostBlocks triples)
    {t : BlockTriple} (ht : t ∈ triples) :
    (landStage l numBlocks numHostBlocks (buildCopyPlanFromTriples triples))[t.host]? =
      some (.kv l t.remote) := by
  let plan := buildCopyPlanFromTriples triples
  have ht_sorted : t ∈ plan.remoteSorted := by
    simp only [plan, buildCopyPlanFromTriples, mem_sortBy]
    exact ht
  obtain ⟨j, hj⟩ := exists_mem_enumFrom 0 ht_sorted
  have hmem_pair : (j, t.host) ∈ plan.h2hPairs := by
    simp only [plan, buildCopyPlanFromTriples, List.mem_map]
    exact ⟨(t, j), hj, rfl⟩
  have hhost_lt : t.host < (blankBlockLayer numHostBlocks).length := by
    simp only [blankBlockLayer, List.length_replicate]
    exact hv.host_lt t ht
  change (execElementwise .junk (d2hStage l numBlocks plan) (blankBlockLayer numHostBlocks) plan.h2hPairs)[t.host]? = _
  rw [getElem?_execElementwise_of_mem .junk _ _ plan.h2hPairs j t.host hmem_pair hhost_lt]
  · rw [List.getD_eq_getElem?_getD, d2hStage_get_enum hv hj]
    rfl
  · intro p hp hp2
    simp only [plan, buildCopyPlanFromTriples, List.mem_map] at hp
    rcases hp with ⟨⟨t', j'⟩, hj', rfl⟩
    simp only at hp2
    have ht'_mem : t' ∈ triples :=
      (mem_sortBy _ _ _).mp (fst_mem_of_mem_enumFrom hj')
    have hteq : t' = t := hv.host_inj t' ht'_mem t ht hp2
    subst hteq
    have hnd_sorted : plan.remoteSorted.Nodup := nodup_sortBy hv.nodup
    exact enumFrom_fst_inj hnd_sorted hj' hj

/-- Stage 2 frame (untouched host block): any consumer host block `h < numHostBlocks`
not in `triples.map (·.host)` remains `.blank` (`LocalOrchestratedTransferToCustomHostBlock`,
`kv_cache_manager_with_transfer_test.cc:434-437`). -/
theorem landStage_get_untouched {l numBlocks numHostBlocks : Nat}
    {triples : List BlockTriple} {h : Nat} (hh : h < numHostBlocks)
    (huntouched : ∀ t ∈ triples, t.host ≠ h) :
    (landStage l numBlocks numHostBlocks (buildCopyPlanFromTriples triples))[h]? =
      some .blank := by
  let plan := buildCopyPlanFromTriples triples
  change (execElementwise .junk (d2hStage l numBlocks plan) (blankBlockLayer numHostBlocks) plan.h2hPairs)[h]? = _
  rw [getElem?_execElementwise_of_not_mem]
  · exact getElem?_blankBlockLayer hh
  · intro p hp
    simp only [plan, buildCopyPlanFromTriples, List.mem_map] at hp
    rcases hp with ⟨⟨t', j'⟩, hj', rfl⟩
    have ht'_mem : t' ∈ triples :=
      (mem_sortBy _ _ _).mp (fst_mem_of_mem_enumFrom hj')
    exact huntouched t' ht'_mem

/-- **Stage 3 end-to-end correctness (requested local block):** for every
`t ∈ triples`, consumer device block `t.local_` receives `.kv l t.remote`,
cancelling the intermediate $\pi_{\text{remote}}$ and $\pi_{\text{local}}$
permutations and contiguous-run coalescing. -/
theorem h2dStage_get_requested {l numBlocks numHostBlocks : Nat}
    {triples : List BlockTriple}
    (hv : ValidTriples numBlocks numHostBlocks triples)
    {t : BlockTriple} (ht : t ∈ triples) :
    (h2dStage l numBlocks numHostBlocks (buildCopyPlanFromTriples triples))[t.local_]? =
      some (.kv l t.remote) := by
  let plan := buildCopyPlanFromTriples triples
  have hspec : plan.h2dSpec = buildCoalescedSpec plan.h2dPairs := rfl
  change (execCoalesced .junk (landStage l numBlocks numHostBlocks plan) (blankBlockLayer numBlocks) plan.h2dSpec)[t.local_]? = _
  rw [hspec, execCoalesced_buildCoalescedSpec]
  have hmem_pair : (t.host, t.local_) ∈ plan.h2dPairs := by
    simp only [plan, buildCopyPlanFromTriples, mem_dedupAdj, List.mem_map, mem_sortBy]
    exact ⟨t, ht, rfl⟩
  have hlocal_lt : t.local_ < (blankBlockLayer numBlocks).length := by
    simp only [blankBlockLayer, List.length_replicate]
    exact hv.local_lt t ht
  rw [getElem?_execElementwise_of_mem .junk _ _ plan.h2dPairs t.host t.local_ hmem_pair hlocal_lt]
  · rw [List.getD_eq_getElem?_getD, landStage_get_requested hv ht]
    rfl
  · intro p hp hp2
    simp only [plan, buildCopyPlanFromTriples, mem_dedupAdj, List.mem_map, mem_sortBy] at hp
    rcases hp with ⟨t', ht', rfl⟩
    exact hv.local_consistent t' ht' t ht hp2

/-- **Stage 3 frame (untouched local block):** any consumer device block
`b < numBlocks` not in `triples.map (·.local_)` remains `.blank`
(`LocalOrchestratedTransfer`, `test_non_contiguous_blocks`,
`test_large_complex_non_contiguous_and_reorder`). -/
theorem h2dStage_get_untouched {l numBlocks numHostBlocks : Nat}
    {triples : List BlockTriple} {b : Nat} (hb : b < numBlocks)
    (huntouched : ∀ t ∈ triples, t.local_ ≠ b) :
    (h2dStage l numBlocks numHostBlocks (buildCopyPlanFromTriples triples))[b]? =
      some .blank := by
  let plan := buildCopyPlanFromTriples triples
  have hspec : plan.h2dSpec = buildCoalescedSpec plan.h2dPairs := rfl
  change (execCoalesced .junk (landStage l numBlocks numHostBlocks plan) (blankBlockLayer numBlocks) plan.h2dSpec)[b]? = _
  rw [hspec, execCoalesced_buildCoalescedSpec, getElem?_execElementwise_of_not_mem]
  · exact getElem?_blankBlockLayer hb
  · intro p hp
    simp only [plan, buildCopyPlanFromTriples, mem_dedupAdj, List.mem_map, mem_sortBy] at hp
    rcases hp with ⟨t', ht', rfl⟩
    exact huntouched t' ht'

/-! ## 5. Multi-Layer Asynchronous `BlockPipeline` Integration -/

/-- A multi-layer prefill-to-decode transfer pipeline refined to 2D
`(layer, block)` memories (`List (List BlockCell)`), coupling `Pipeline` with
`validateRegistration`, `validateRequestedBlocks`, `CopyPlan`, and coalesced
D2H / H2H / H2D block execution. -/
structure BlockPipeline where
  pipe : Pipeline
  numBlocks : Nat
  numHostBlocks : Nat
  registeredBlocks : List Nat
  plan : CopyPlan
  prefillHbmB : List (List BlockCell)
  prefillStagingB : List (List BlockCell)
  wireB : List (Option (List BlockCell))
  decodeStagingB : List (List BlockCell)
  decodeHbmB : List (List BlockCell)
  prefillStagingReseated : Bool := false
  decodeStagingReseated : Bool := false
  deriving Repr, DecidableEq

namespace BlockPipeline

/-- Initial 2D prefill HBM (`numLayers × numBlocks`), where layer `l`, block `b`
holds `.kv l b`. -/
def initPrefillHbmB (numLayers numBlocks : Nat) : List (List BlockCell) :=
  (List.range numLayers).map (goodBlockLayer numBlocks)

/-- Construct an `n`-layer `BlockPipeline` for a given `registeredBlocks` and
`triples` specification. -/
def init (numLayers numBlocks numHostBlocks : Nat)
    (registeredBlocks : List Nat) (triples : List BlockTriple) : BlockPipeline :=
  let plan := buildCopyPlanFromTriples triples
  { pipe := Pipeline.init numLayers,
    numBlocks := numBlocks,
    numHostBlocks := numHostBlocks,
    registeredBlocks := registeredBlocks,
    plan := plan,
    prefillHbmB := initPrefillHbmB numLayers numBlocks,
    prefillStagingB := List.replicate numLayers (junkBlockLayer plan.numBlocks),
    wireB := List.replicate numLayers none,
    decodeStagingB := List.replicate numLayers (blankBlockLayer numHostBlocks),
    decodeHbmB := List.replicate numLayers (blankBlockLayer numBlocks) }

/-- Step function of `BlockPipeline`:
- `.send .beginPull` (`ValidateAndBeginPull`, `send.cc:116-130`) additionally
  checks `validateRequestedBlocks s.registeredBlocks s.plan.producerRemoteBlocks = true`.
- `.d2hReady l` executes the coalesced D2H `CopySpec` (`s.plan.d2hSpec`) on layer `l`.
- `.h2hDone l true` places layer `l`'s staged producer blocks on the wire.
- `.land l` lands the wire blocks into `decodeStagingB[l]` using `s.plan.h2hPairs`.
- `.h2dReady l` executes the coalesced H2D `CopySpec` (`s.plan.h2dSpec`) on layer `l`.
- `.reclaim`, `.reseatPrefillStaging`, and `.reseatDecodeStaging` overwrite the
  corresponding 2D block buffers with `.junk`. -/
def step (s : BlockPipeline) (e : Pipeline.Ev) : Option BlockPipeline :=
  match e with
  | .send .beginPull =>
    if validateRequestedBlocks s.registeredBlocks s.plan.producerRemoteBlocks = true then
      (Pipeline.step s.pipe (.send .beginPull)).map fun p => { s with pipe := p }
    else none
  | .d2hReady l =>
    (Pipeline.step s.pipe (.d2hReady l)).map fun p =>
      let srcLayer := s.prefillHbmB.getD l []
      let dstLayer := s.prefillStagingB.getD l []
      let staged := execCoalesced .junk srcLayer dstLayer s.plan.d2hSpec
      { s with pipe := p, prefillStagingB := s.prefillStagingB.set l staged }
  | .h2hDone l ok =>
    (Pipeline.step s.pipe (.h2hDone l ok)).map fun p =>
      if ok then
        { s with pipe := p, wireB := s.wireB.set l (some (s.prefillStagingB.getD l [])) }
      else
        { s with pipe := p }
  | .land l =>
    (Pipeline.step s.pipe (.land l)).map fun p =>
      let wireLayer := (s.wireB.getD l none).getD []
      let dstLayer := s.decodeStagingB.getD l []
      let landed := execElementwise .junk wireLayer dstLayer s.plan.h2hPairs
      { s with pipe := p, decodeStagingB := s.decodeStagingB.set l landed }
  | .h2dReady l =>
    (Pipeline.step s.pipe (.h2dReady l)).map fun p =>
      let srcLayer := s.decodeStagingB.getD l []
      let dstLayer := s.decodeHbmB.getD l []
      let copied := execCoalesced .junk srcLayer dstLayer s.plan.h2dSpec
      { s with pipe := p, decodeHbmB := s.decodeHbmB.set l copied }
  | .reclaim =>
    (Pipeline.step s.pipe .reclaim).map fun p =>
      { s with pipe := p,
               prefillHbmB := List.replicate s.pipe.numLayers (junkBlockLayer s.numBlocks) }
  | .reseatPrefillStaging =>
    (Pipeline.step s.pipe .reseatPrefillStaging).map fun p =>
      { s with pipe := p,
               prefillStagingB := List.replicate s.pipe.numLayers (junkBlockLayer s.plan.numBlocks),
               prefillStagingReseated := true }
  | .reseatDecodeStaging =>
    (Pipeline.step s.pipe .reseatDecodeStaging).map fun p =>
      { s with pipe := p,
               decodeStagingB := List.replicate s.pipe.numLayers (junkBlockLayer s.numHostBlocks),
               decodeStagingReseated := true }
  | e =>
    (Pipeline.step s.pipe e).map fun p => { s with pipe := p }

def sys (numLayers numBlocks numHostBlocks : Nat)
    (registeredBlocks : List Nat) (triples : List BlockTriple) :
    System BlockPipeline Pipeline.Ev :=
  ⟨init numLayers numBlocks numHostBlocks registeredBlocks triples, step⟩

/-- Projection lemma: every `BlockPipeline` step refines a `Pipeline` step. -/
theorem step_pipe {s s' : BlockPipeline} {e : Pipeline.Ev}
    (hs : step s e = some s') : Pipeline.step s.pipe e = some s'.pipe := by
  cases e with
  | send se =>
    cases se <;> simp only [step] at hs
    case beginPull =>
      split at hs
      · simp only [Option.map_eq_some_iff] at hs
        rcases hs with ⟨p, hp, rfl⟩
        exact hp
      · cases hs
    all_goals
      simp only [Option.map_eq_some_iff] at hs
      rcases hs with ⟨p, hp, rfl⟩
      exact hp
  | h2hDone l ok =>
    simp only [step, Option.map_eq_some_iff] at hs
    rcases hs with ⟨p, hp, rfl⟩
    split <;> exact hp
  | _ =>
    simp only [step, Option.map_eq_some_iff] at hs
    rcases hs with ⟨p, hp, rfl⟩
    exact hp

/-! ### Block-level Safety Properties -/

/-- `ValidateRequestedBlocksLocked` safety (`send.cc:97-130`): whenever
`pull_started_` is claimed (`s.pipe.send.pullStarted = true`), the requested
`producerRemoteBlocks` passed non-empty, subset, and no-duplicate validation
against `s.registeredBlocks`. -/
def BlockValidationSafe (s : BlockPipeline) : Prop :=
  s.pipe.send.pullStarted = true →
    s.plan.producerRemoteBlocks ≠ [] ∧
    (∀ b ∈ s.plan.producerRemoteBlocks, b ∈ s.registeredBlocks) ∧
    s.plan.producerRemoteBlocks.Nodup

/-- **Within-layer & across-layer publication correctness:** when `poll_stats()`
reports `done_recving` (`s.pipe.recv.published = some true`), for every layer
`l < s.pipe.numLayers`, `s.decodeHbmB[l]` equals `h2dStage l s.numBlocks s.numHostBlocks s.plan`
— which by `h2dStage_get_requested` and `h2dStage_get_untouched` holds
`some (.kv l t.remote)` at every `t.local_` and `some .blank` at every untouched
block `b < s.numBlocks`. -/
def BlockPublicationCorrect (s : BlockPipeline) : Prop :=
  s.pipe.recv.published = some true →
    ∀ l < s.pipe.numLayers,
      s.decodeHbmB[l]? = some (h2dStage l s.numBlocks s.numHostBlocks s.plan)

/-- **Custom host staging block correctness (`LocalOrchestratedTransferToCustomHostBlock`,
`kv_cache_manager_with_transfer_test.cc:324-438`):** as long as consumer host
staging has not been reseated (`s.decodeStagingReseated = false`), every landed
layer `l` in `s.decodeStagingB[l]` equals `landStage l s.numBlocks s.numHostBlocks s.plan`
— which by `landStage_get_requested` and `landStage_get_untouched` holds
`some (.kv l t.remote)` at every `t.host` and `some .blank` at every untouched
host block `h < s.numHostBlocks`. -/
def CustomHostStagingCorrect (s : BlockPipeline) : Prop :=
  s.decodeStagingReseated = false →
    ∀ l : Nat, s.pipe.landedL[l]? = some true →
      s.decodeStagingB[l]? = some (landStage l s.numBlocks s.numHostBlocks s.plan)

def Safe (s : BlockPipeline) : Prop :=
  s.pipe.Safe ∧ BlockValidationSafe s ∧ BlockPublicationCorrect s ∧
    CustomHostStagingCorrect s

/-! ### Inductive Invariant of `BlockPipeline` -/

structure Inv (s : BlockPipeline) : Prop where
  pipe : s.pipe.Inv
  len_phbmB : s.prefillHbmB.length = s.pipe.numLayers
  len_pstagingB : s.prefillStagingB.length = s.pipe.numLayers
  len_wireB : s.wireB.length = s.pipe.numLayers
  len_dstagingB : s.decodeStagingB.length = s.pipe.numLayers
  len_dhbmB : s.decodeHbmB.length = s.pipe.numLayers
  pull_validated : s.pipe.send.pullStarted = true →
    validateRequestedBlocks s.registeredBlocks s.plan.producerRemoteBlocks = true
  pstg_reseated_done : s.prefillStagingReseated = true → s.pipe.send.life.done = true
  dstg_reseated_done : s.decodeStagingReseated = true → s.pipe.recv.life.done = true
  phbmB_good : s.pipe.reclaimed = false →
    ∀ l < s.pipe.numLayers, s.prefillHbmB[l]? = some (goodBlockLayer s.numBlocks l)
  pstagingB_unwritten : s.prefillStagingReseated = false →
    ∀ l < s.pipe.numLayers, s.pipe.d2hReadyL[l]? = some false →
      s.prefillStagingB[l]? = some (junkBlockLayer s.plan.numBlocks)
  pstagingB_good : s.prefillStagingReseated = false →
    ∀ l : Nat, s.pipe.d2hReadyL[l]? = some true →
      s.prefillStagingB[l]? = some (d2hStage l s.numBlocks s.plan)
  wireB_some_iff : ∀ l < s.pipe.numLayers,
    s.pipe.wire[l]? = some (.kv l) →
      s.wireB[l]? = some (some (d2hStage l s.numBlocks s.plan))
  dstagingB_unwritten : s.decodeStagingReseated = false →
    ∀ l < s.pipe.numLayers, s.pipe.landedL[l]? = some false →
      s.decodeStagingB[l]? = some (blankBlockLayer s.numHostBlocks)
  dstagingB_good : s.decodeStagingReseated = false →
    ∀ l : Nat, s.pipe.landedL[l]? = some true →
      s.decodeStagingB[l]? = some (landStage l s.numBlocks s.numHostBlocks s.plan)
  dhbmB_unwritten : ∀ l < s.pipe.numLayers, s.pipe.h2dReadyL[l]? = some false →
    s.decodeHbmB[l]? = some (blankBlockLayer s.numBlocks)
  dhbmB_good : ∀ l : Nat, s.pipe.h2dReadyL[l]? = some true →
    s.decodeHbmB[l]? = some (h2dStage l s.numBlocks s.numHostBlocks s.plan)

theorem inv_init (numLayers numBlocks numHostBlocks : Nat)
    (registeredBlocks : List Nat) (triples : List BlockTriple) :
    Inv (init numLayers numBlocks numHostBlocks registeredBlocks triples) := by
  refine ⟨Pipeline.inv_init numLayers,
    by simp [init, initPrefillHbmB, Pipeline.init],
    by simp [init, Pipeline.init],
    by simp [init, Pipeline.init],
    by simp [init, Pipeline.init],
    by simp [init, Pipeline.init],
    nofun, nofun, nofun,
    ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro _ l hl
    simp only [init, initPrefillHbmB, Pipeline.init] at hl ⊢
    simp [hl]
  · intro _ l hl _
    simp only [init, Pipeline.init] at hl ⊢
    simp [hl]
  · intro _ l h
    simp only [init, Pipeline.init] at h
    exact (not_mem_replicate_false h).elim
  · intro l _ h
    simp only [init, Pipeline.init, List.getElem?_replicate] at h
    split at h <;> cases h
  · intro _ l hl _
    simp only [init, Pipeline.init] at hl ⊢
    simp [hl]
  · intro _ l h
    simp only [init, Pipeline.init] at h
    exact (not_mem_replicate_false h).elim
  · intro l hl _
    simp only [init, Pipeline.init] at hl ⊢
    simp [hl]
  · intro l h
    simp only [init, Pipeline.init] at h
    exact (not_mem_replicate_false h).elim

theorem inv_safe {s : BlockPipeline} (h : Inv s) : Safe s := by
  refine ⟨Pipeline.inv_safe h.pipe, ?_, ?_, h.dstagingB_good⟩
  · intro hps
    exact (validateRequestedBlocks_iff _ _).mp (h.pull_validated hps)
  · intro hpub l hl
    apply h.dhbmB_good
    have hready : s.pipe.recv.ready = s.pipe.numLayers := by
      have := h.pipe.recv.published_ok hpub
      have := h.pipe.recv.completed_le
      have := h.pipe.recv.retired_le
      have := h.pipe.recv.ready_le
      have := h.pipe.recv.issued_le
      have := h.pipe.n_recv
      omega
    apply all_true_of_countTrue_eq_length
    · rw [h.pipe.cnt_h2dReady, hready, h.pipe.len_h2dReadyL]
    · rw [h.pipe.len_h2dReadyL]; exact hl

/-- Combined spatial + temporal theorem at `done_recving`: when `s` is reachable
with `ValidTriples s.numBlocks s.numHostBlocks triples` and `s.pipe.recv.published = some true`,
every layer `l < s.pipe.numLayers` has `.kv l t.remote` at `t.local_` for every
`t ∈ triples` and `.blank` at every untouched block `b < s.numBlocks`. -/
theorem inv_decodeHbm_requested {s : BlockPipeline} {triples : List BlockTriple}
    (h : Inv s) (hplan : s.plan = buildCopyPlanFromTriples triples)
    (hv : ValidTriples s.numBlocks s.numHostBlocks triples)
    (hpub : s.pipe.recv.published = some true)
    {l : Nat} (hl : l < s.pipe.numLayers)
    {t : BlockTriple} (ht : t ∈ triples) :
    (s.decodeHbmB.getD l [])[t.local_]? = some (.kv l t.remote) := by
  have hlayer := (inv_safe h).2.2.1 hpub l hl
  rw [List.getD_eq_getElem?_getD, hlayer, Option.getD_some, hplan]
  exact h2dStage_get_requested hv ht

theorem inv_decodeHbm_untouched {s : BlockPipeline} {triples : List BlockTriple}
    (h : Inv s) (hplan : s.plan = buildCopyPlanFromTriples triples)
    (hpub : s.pipe.recv.published = some true)
    {l : Nat} (hl : l < s.pipe.numLayers)
    {b : Nat} (hb : b < s.numBlocks) (huntouched : ∀ t ∈ triples, t.local_ ≠ b) :
    (s.decodeHbmB.getD l [])[b]? = some .blank := by
  have hlayer := (inv_safe h).2.2.1 hpub l hl
  rw [List.getD_eq_getElem?_getD, hlayer, Option.getD_some, hplan]
  exact h2dStage_get_untouched hb huntouched

/-- Frame lemma for `BlockPipeline` transitions that only update `pipe` without
modifying `numLayers`, `reclaimed`, `d2hReadyL`, `wire`, `landedL`, `h2dReadyL`,
or the 2D block memories. -/
theorem Inv.frame_no_mem {s : BlockPipeline} {p : Pipeline} (h : Inv s)
    (hp : p.Inv)
    (hn : p.numLayers = s.pipe.numLayers)
    (hrec : p.reclaimed = s.pipe.reclaimed)
    (hd2h : p.d2hReadyL = s.pipe.d2hReadyL)
    (hwire : p.wire = s.pipe.wire)
    (hland : p.landedL = s.pipe.landedL)
    (hh2d : p.h2dReadyL = s.pipe.h2dReadyL)
    (hs_done : s.pipe.send.life.done = true → p.send.life.done = true)
    (hr_done : s.pipe.recv.life.done = true → p.recv.life.done = true)
    (hpull : p.send.pullStarted = true →
      validateRequestedBlocks s.registeredBlocks s.plan.producerRemoteBlocks = true) :
    Inv { s with pipe := p } := by
  refine ⟨hp,
    by rw [hn]; exact h.len_phbmB,
    by rw [hn]; exact h.len_pstagingB,
    by rw [hn]; exact h.len_wireB,
    by rw [hn]; exact h.len_dstagingB,
    by rw [hn]; exact h.len_dhbmB,
    hpull,
    fun hpr => hs_done (h.pstg_reseated_done hpr),
    fun hdr => hr_done (h.dstg_reseated_done hdr),
    by rw [hrec, hn]; exact h.phbmB_good,
    by rw [hn, hd2h]; exact h.pstagingB_unwritten,
    by rw [hd2h]; exact h.pstagingB_good,
    by rw [hn, hwire]; exact h.wireB_some_iff,
    by rw [hn, hland]; exact h.dstagingB_unwritten,
    by rw [hland]; exact h.dstagingB_good,
    by rw [hn, hh2d]; exact h.dhbmB_unwritten,
    by rw [hh2d]; exact h.dhbmB_good⟩

theorem step_inv {s s' : BlockPipeline} {e : Pipeline.Ev}
    (h : Inv s) (hs : step s e = some s') : Inv s' := by
  have hp_inv : s'.pipe.Inv := Pipeline.step_inv h.pipe (step_pipe hs)
  cases e with
  | notifyForRead =>
    simp only [step, Pipeline.step, Pipeline.notifyForRead] at hs
    split at hs
    · simp only [Option.map_eq_some_iff, Option.some.injEq] at hs
      rcases hs with ⟨_, rfl, rfl⟩
      exact h.frame_no_mem hp_inv rfl rfl rfl rfl rfl rfl id id h.pull_validated
    · cases hs
  | pullWait =>
    simp only [step, Pipeline.step, Pipeline.pullWait] at hs
    split at hs
    · simp only [Option.map_eq_some_iff, Option.some.injEq] at hs
      rcases hs with ⟨_, rfl, rfl⟩
      exact h.frame_no_mem hp_inv rfl rfl rfl rfl rfl rfl id id h.pull_validated
    · cases hs
  | send se =>
    cases se with
    | d2hReady =>
      simp only [step, Pipeline.step, Pipeline.sendStep] at hs; cases hs
    | h2hDone ok =>
      simp only [step, Pipeline.step, Pipeline.sendStep] at hs; cases hs
    | beginPull =>
      simp only [step] at hs
      split at hs
      · rename_i hval
        simp only [Option.map_eq_some_iff, Pipeline.step, Pipeline.sendStep] at hs
        rcases hs with ⟨p, hp, rfl⟩
        split at hp
        · simp only [Option.map_eq_some_iff] at hp
          rcases hp with ⟨snd, hsnd, rfl⟩
          exact h.frame_no_mem hp_inv rfl rfl rfl rfl rfl rfl
            (Send.step_done_mono hsnd) id (fun _ => hval)
        · cases hp
      · cases hs
    | wake ok =>
      simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.sendStep] at hs
      rcases hs with ⟨p, hp, rfl⟩
      split at hp
      · simp only [Option.map_eq_some_iff] at hp
        rcases hp with ⟨snd, hsnd, rfl⟩
        exact h.frame_no_mem hp_inv rfl rfl rfl rfl rfl rfl
          (Send.step_done_mono hsnd) id
          (by rw [Send.step_pullStarted_of_ne_beginPull hsnd nofun]; exact h.pull_validated)
      · cases hp
    | start | d2hBegin | d2hIssue _ | d2hEnd | h2hIssue | sendNext | cancel | publish =>
      simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.sendStep] at hs
      rcases hs with ⟨p, ⟨snd, hsnd, rfl⟩, rfl⟩
      exact h.frame_no_mem hp_inv rfl rfl rfl rfl rfl rfl
        (Send.step_done_mono hsnd) id
        (by rw [Send.step_pullStarted_of_ne_beginPull hsnd nofun]; exact h.pull_validated)
  | recv re =>
    cases re with
    | h2dBegin | h2dIssue _ | h2dReady =>
      simp only [step, Pipeline.step, Pipeline.recvStep] at hs; cases hs
    | pullReply ok =>
      simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.recvStep] at hs
      rcases hs with ⟨p, hp, rfl⟩
      split at hp
      · simp only [Option.map_eq_some_iff] at hp
        rcases hp with ⟨rcv, hrcv, rfl⟩
        exact h.frame_no_mem hp_inv rfl rfl rfl rfl rfl rfl
          id (Recv.step_done_mono hrcv) h.pull_validated
      · cases hp
    | pushBegin | pushEnd | h2dDone _ | netAccount | pollReady | cancel | publish =>
      simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.recvStep] at hs
      rcases hs with ⟨p, ⟨rcv, hrcv, rfl⟩, rfl⟩
      exact h.frame_no_mem hp_inv rfl rfl rfl rfl rfl rfl
        id (Recv.step_done_mono hrcv) h.pull_validated
  | h2dBegin l =>
    simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.h2dBegin] at hs
    rcases hs with ⟨p, hp, rfl⟩
    split at hp
    · simp only [Option.map_eq_some_iff] at hp
      rcases hp with ⟨rcv, hrcv, rfl⟩
      exact h.frame_no_mem hp_inv rfl rfl rfl rfl rfl rfl
        id (Recv.step_done_mono hrcv) h.pull_validated
    · cases hp
  | h2dIssue l ok =>
    simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.h2dIssue] at hs
    rcases hs with ⟨p, hp, rfl⟩
    split at hp
    · simp only [Option.map_eq_some_iff] at hp
      rcases hp with ⟨rcv, hrcv, rfl⟩
      exact h.frame_no_mem hp_inv rfl rfl rfl rfl rfl rfl
        id (Recv.step_done_mono hrcv) h.pull_validated
    · cases hp
  | d2hReady l =>
    simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.d2hReady] at hs
    rcases hs with ⟨p, hp, rfl⟩
    split at hp
    · rename_i hg
      rcases hg with ⟨hl_iss, hf⟩
      simp only [Option.map_eq_some_iff] at hp
      rcases hp with ⟨snd, hsnd, rfl⟩
      obtain ⟨hlt, rfl⟩ := Send.d2hReady_spec hsnd
      have hd : s.pipe.send.life.done = false :=
        Pipeline.send_not_done_of_outstanding h.pipe.send (Or.inl hlt)
      have hnr : s.pipe.reclaimed = false := by
        cases hr : s.pipe.reclaimed
        · rfl
        · have := h.pipe.reclaimed_done hr; rw [hd] at this; cases this
      have hnpr : s.prefillStagingReseated = false := by
        cases hpr : s.prefillStagingReseated
        · rfl
        · have := h.pstg_reseated_done hpr; rw [hd] at this; cases this
      have hk : l < s.pipe.numLayers := by
        have := lt_length_of_getElem?_eq hf
        rw [h.pipe.len_d2hReadyL] at this
        exact this
      have hsrc : s.prefillHbmB.getD l [] = goodBlockLayer s.numBlocks l := by
        rw [List.getD_eq_getElem?_getD, h.phbmB_good hnr l hk]; rfl
      have hdst : s.prefillStagingB.getD l [] = junkBlockLayer s.plan.numBlocks := by
        rw [List.getD_eq_getElem?_getD, h.pstagingB_unwritten hnpr l hk hf]; rfl
      rw [hsrc, hdst]
      refine ⟨hp_inv, h.len_phbmB, ?_, h.len_wireB, h.len_dstagingB, h.len_dhbmB,
        h.pull_validated, h.pstg_reseated_done, h.dstg_reseated_done,
        h.phbmB_good, ?_, ?_, h.wireB_some_iff, h.dstagingB_unwritten,
        h.dstagingB_good, h.dhbmB_unwritten, h.dhbmB_good⟩
      · rw [List.length_set]; exact h.len_pstagingB
      · intro hpr j hj hjf
        have hjl : j ≠ l := by
          intro heq; subst heq
          rw [List.getElem?_set_self (by rw [h.pipe.len_d2hReadyL]; exact hk)] at hjf
          cases hjf
        rw [List.getElem?_set_ne (Ne.symm hjl)] at hjf ⊢
        exact h.pstagingB_unwritten hpr j hj hjf
      · intro hpr j hj
        by_cases hjl : j = l
        · subst hjl
          exact List.getElem?_set_self (by rw [h.len_pstagingB]; exact hk)
        · rw [List.getElem?_set_ne (Ne.symm hjl)] at hj ⊢
          exact h.pstagingB_good hpr j hj
    · cases hp
  | h2hDone l ok =>
    simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.h2hDone] at hs
    rcases hs with ⟨p, hp, rfl⟩
    split at hp
    · rename_i hg
      rcases hg with ⟨hl_iss, hf⟩
      simp only [Option.map_eq_some_iff] at hp
      rcases hp with ⟨snd, hsnd, rfl⟩
      cases ok with
      | false =>
        simp only [Bool.false_eq_true, ↓reduceIte]
        exact h.frame_no_mem hp_inv rfl rfl rfl rfl rfl rfl
          (Send.step_done_mono hsnd) id
          (by rw [Send.step_pullStarted_of_ne_beginPull hsnd nofun]; exact h.pull_validated)
      | true =>
        simp only [↓reduceIte]
        have hlt := Send.h2hDone_guard hsnd
        have hcnt := h.pipe.send.counters
        unfold Send.CountersOrdered at hcnt
        have hd : s.pipe.send.life.done = false :=
          Pipeline.send_not_done_of_outstanding h.pipe.send (Or.inr hlt)
        have hnpr : s.prefillStagingReseated = false := by
          cases hpr : s.prefillStagingReseated
          · rfl
          · have := h.pstg_reseated_done hpr; rw [hd] at this; cases this
        have hk : l < s.pipe.numLayers := by have := h.pipe.n_send; omega
        have hdl : s.pipe.d2hReadyL[l]? = some true := h.pipe.woken_d2hReady l (by omega)
        have hsrc : s.prefillStagingB.getD l [] = d2hStage l s.numBlocks s.plan := by
          rw [List.getD_eq_getElem?_getD, h.pstagingB_good hnpr l hdl]; rfl
        rw [hsrc]
        refine ⟨hp_inv, h.len_phbmB, h.len_pstagingB, ?_, h.len_dstagingB, h.len_dhbmB,
          by rw [Send.step_pullStarted_of_ne_beginPull hsnd nofun]; exact h.pull_validated,
          fun hpr => Send.step_done_mono hsnd (h.pstg_reseated_done hpr),
          h.dstg_reseated_done, h.phbmB_good, h.pstagingB_unwritten, h.pstagingB_good,
          ?_, h.dstagingB_unwritten, h.dstagingB_good, h.dhbmB_unwritten, h.dhbmB_good⟩
        · rw [List.length_set]; exact h.len_wireB
        · intro j hj hjw
          by_cases hjl : j = l
          · subst hjl
            exact List.getElem?_set_self (by rw [h.len_wireB]; exact hk)
          · rw [List.getElem?_set_ne (Ne.symm hjl)] at hjw ⊢
            exact h.wireB_some_iff j hj hjw
    · cases hp
  | land l =>
    simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.land] at hs
    rcases hs with ⟨p, hp, rfl⟩
    split at hp
    · rename_i hg
      rcases hg with ⟨hpush, hf⟩
      split at hp
      · rename_i c hc
        split at hp
        · cases hp
        · rename_i hcb
          cases hp
          have hkv : c = .kv l := (h.pipe.wire_good l c hc).resolve_left hcb
          subst hkv
          have hk : l < s.pipe.numLayers := by
            have := lt_length_of_getElem?_eq hc
            rw [h.pipe.len_wire] at this
            exact this
          have hd : s.pipe.recv.life.done = false := by
            cases hd : s.pipe.recv.life.done
            · rfl
            · have := h.pipe.recv.life.done_idle hd
              have := h.pipe.recv.accounted
              unfold Recv.Accounted at this
              omega
          have hndr : s.decodeStagingReseated = false := by
            cases hdr : s.decodeStagingReseated
            · rfl
            · have := h.dstg_reseated_done hdr; rw [hd] at this; cases this
          have hwire : (s.wireB.getD l none).getD [] = d2hStage l s.numBlocks s.plan := by
            rw [List.getD_eq_getElem?_getD, h.wireB_some_iff l hk hc]; rfl
          have hdst : s.decodeStagingB.getD l [] = blankBlockLayer s.numHostBlocks := by
            rw [List.getD_eq_getElem?_getD, h.dstagingB_unwritten hndr l hk hf]; rfl
          rw [hwire, hdst]
          refine ⟨hp_inv, h.len_phbmB, h.len_pstagingB, h.len_wireB, ?_, h.len_dhbmB,
            h.pull_validated, h.pstg_reseated_done, h.dstg_reseated_done,
            h.phbmB_good, h.pstagingB_unwritten, h.pstagingB_good, h.wireB_some_iff,
            ?_, ?_, h.dhbmB_unwritten, h.dhbmB_good⟩
          · rw [List.length_set]; exact h.len_dstagingB
          · intro hdr j hj hjf
            have hjl : j ≠ l := by
              intro heq; subst heq
              rw [List.getElem?_set_self (lt_length_of_getElem?_eq hf)] at hjf
              cases hjf
            rw [List.getElem?_set_ne (Ne.symm hjl)] at hjf ⊢
            exact h.dstagingB_unwritten hdr j hj hjf
          · intro hdr j hj
            by_cases hjl : j = l
            · subst hjl
              exact List.getElem?_set_self (by rw [h.len_dstagingB]; exact hk)
            · rw [List.getElem?_set_ne (Ne.symm hjl)] at hj ⊢
              exact h.dstagingB_good hdr j hj
      · cases hp
    · cases hp
  | h2dReady l =>
    simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.h2dReady] at hs
    rcases hs with ⟨p, hp, rfl⟩
    split at hp
    · rename_i hg
      rcases hg with ⟨hiss, hf⟩
      simp only [Option.map_eq_some_iff] at hp
      rcases hp with ⟨rcv, hrcv, rfl⟩
      obtain ⟨hlt, rfl⟩ := Recv.h2dReady_spec hrcv
      have hd : s.pipe.recv.life.done = false := by
        cases hd : s.pipe.recv.life.done
        · rfl
        · have := (Recv.inv_safe h.pipe.recv).2.1 hd
          have := h.pipe.recv.retired_le
          omega
      have hndr : s.decodeStagingReseated = false := by
        cases hdr : s.decodeStagingReseated
        · rfl
        · have := h.dstg_reseated_done hdr; rw [hd] at this; cases this
      have hk : l < s.pipe.numLayers := by
        have := lt_length_of_getElem?_eq hf
        rw [h.pipe.len_h2dReadyL] at this
        exact this
      have hland : s.pipe.landedL[l]? = some true := h.pipe.issued_landed l hiss
      have hsrc : s.decodeStagingB.getD l [] = landStage l s.numBlocks s.numHostBlocks s.plan := by
        rw [List.getD_eq_getElem?_getD, h.dstagingB_good hndr l hland]; rfl
      have hdst : s.decodeHbmB.getD l [] = blankBlockLayer s.numBlocks := by
        rw [List.getD_eq_getElem?_getD, h.dhbmB_unwritten l hk hf]; rfl
      rw [hsrc, hdst]
      refine ⟨hp_inv, h.len_phbmB, h.len_pstagingB, h.len_wireB, h.len_dstagingB, ?_,
        h.pull_validated, h.pstg_reseated_done, h.dstg_reseated_done,
        h.phbmB_good, h.pstagingB_unwritten, h.pstagingB_good, h.wireB_some_iff,
        h.dstagingB_unwritten, h.dstagingB_good, ?_, ?_⟩
      · rw [List.length_set]; exact h.len_dhbmB
      · intro j hj hjf
        have hjl : j ≠ l := by
          intro heq; subst heq
          rw [List.getElem?_set_self (by rw [h.pipe.len_h2dReadyL]; exact hk)] at hjf
          cases hjf
        rw [List.getElem?_set_ne (Ne.symm hjl)] at hjf ⊢
        exact h.dhbmB_unwritten j hj hjf
      · intro j hj
        by_cases hjl : j = l
        · subst hjl
          exact List.getElem?_set_self (by rw [h.len_dhbmB]; exact hk)
        · rw [List.getElem?_set_ne (Ne.symm hjl)] at hj ⊢
          exact h.dhbmB_good j hj
    · cases hp
  | reclaim =>
    simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.reclaim] at hs
    rcases hs with ⟨p, hp, rfl⟩
    split at hp
    · cases hp
      refine ⟨hp_inv, by simp, h.len_pstagingB, h.len_wireB, h.len_dstagingB, h.len_dhbmB,
        h.pull_validated, h.pstg_reseated_done, h.dstg_reseated_done,
        nofun, h.pstagingB_unwritten, h.pstagingB_good, h.wireB_some_iff,
        h.dstagingB_unwritten, h.dstagingB_good, h.dhbmB_unwritten, h.dhbmB_good⟩
    · cases hp
  | reseatPrefillStaging =>
    simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.reseatPrefillStaging] at hs
    rcases hs with ⟨p, hp, rfl⟩
    split at hp
    · rename_i hrel
      cases hp
      have hd : s.pipe.send.life.done = true := h.pipe.send.life.done_of_released hrel
      refine ⟨hp_inv, h.len_phbmB, by simp, h.len_wireB, h.len_dstagingB, h.len_dhbmB,
        h.pull_validated, fun _ => hd, h.dstg_reseated_done,
        h.phbmB_good, nofun, nofun, h.wireB_some_iff,
        h.dstagingB_unwritten, h.dstagingB_good, h.dhbmB_unwritten, h.dhbmB_good⟩
    · cases hp
  | reseatDecodeStaging =>
    simp only [step, Option.map_eq_some_iff, Pipeline.step, Pipeline.reseatDecodeStaging] at hs
    rcases hs with ⟨p, hp, rfl⟩
    split at hp
    · rename_i hrel
      cases hp
      have hd : s.pipe.recv.life.done = true := h.pipe.recv.life.done_of_released hrel
      refine ⟨hp_inv, h.len_phbmB, h.len_pstagingB, h.len_wireB, by simp, h.len_dhbmB,
        h.pull_validated, h.pstg_reseated_done, fun _ => hd,
        h.phbmB_good, h.pstagingB_unwritten, h.pstagingB_good, h.wireB_some_iff,
        nofun, nofun, h.dhbmB_unwritten, h.dhbmB_good⟩
    · cases hp

theorem reachable_inv {numLayers numBlocks numHostBlocks : Nat}
    {registeredBlocks : List Nat} {triples : List BlockTriple} {s : BlockPipeline}
    (hr : (sys numLayers numBlocks numHostBlocks registeredBlocks triples).Reachable s) :
    Inv s :=
  (sys numLayers numBlocks numHostBlocks registeredBlocks triples).reachable_induction
    (inv_init numLayers numBlocks numHostBlocks registeredBlocks triples)
    (fun _ _ _ h hs => step_inv h hs) hr

/-- **Main theorem of `BlockPipeline`:** every reachable state satisfies
`Pipeline.Safe`, `BlockValidationSafe`, `BlockPublicationCorrect`, and
`CustomHostStagingCorrect`. -/
theorem reachable_safe {numLayers numBlocks numHostBlocks : Nat}
    {registeredBlocks : List Nat} {triples : List BlockTriple} {s : BlockPipeline}
    (hr : (sys numLayers numBlocks numHostBlocks registeredBlocks triples).Reachable s) :
    Safe s :=
  inv_safe (reachable_inv hr)

end BlockPipeline

/-! ## 6. Concrete Traces & Regression Checks (`decide`) -/

section Checks

open Pipeline (Ev)

/-- 1-layer end-to-end trace helper (producer D2H → H2H → consumer land → H2D → publish). -/
def trace1Layer : List Ev :=
  [.send .beginPull, .send .start, .send .d2hBegin, .send (.d2hIssue true),
   .d2hReady 0, .send .d2hEnd, .send (.wake true), .send .h2hIssue,
   .send .sendNext, .h2hDone 0 true, .send .publish,
   .recv (.pullReply true), .recv .pushBegin, .land 0, .h2dBegin 0,
   .h2dIssue 0 true, .recv .netAccount, .recv .pushEnd, .h2dReady 0,
   .recv (.h2dDone true), .recv .publish]

/-- 2-layer out-of-order end-to-end trace helper (D2H finishes 1 then 0, pushes
complete 1 then 0, layer 1 lands and finishes H2D before layer 0). -/
def trace2LayersOutOfOrder : List Ev :=
  [.send .beginPull, .send .start, .send .d2hBegin, .send (.d2hIssue true),
   .send .d2hBegin, .send (.d2hIssue true),
   .d2hReady 1, .d2hReady 0, .send .d2hEnd, .send .d2hEnd,
   .send (.wake true), .send .h2hIssue, .send .sendNext,
   .send (.wake true), .send .h2hIssue, .send .sendNext,
   .h2hDone 1 true, .h2hDone 0 true, .send .publish,
   .recv (.pullReply true),
   .recv .pushBegin, .land 1, .h2dBegin 1, .h2dIssue 1 true, .recv .netAccount, .recv .pushEnd,
   .recv .pushBegin, .land 0, .h2dBegin 0, .h2dIssue 0 true, .recv .netAccount, .recv .pushEnd,
   .h2dReady 1, .h2dReady 0, .recv (.h2dDone true), .recv (.h2dDone true), .recv .publish]

/-- **Trace 1 (`DuplicateBlocksAreRejectedAtRegistration`,
`kv_cache_manager_with_transfer_send_drain_test.cc:387-396`):**
`PopulateRegisteredBlocks` rejects `{0, 0}` at `NotifyForRead` while accepting
`{0, 1, 2}`. -/
theorem trace_duplicate_registration_rejected :
    validateRegistration [0, 0] = false ∧
    validateRegistration [0, 1, 2] = true := by decide

/-- **Trace 2 (`UniqueRegisteredSubsetIsAcknowledged`,
`kv_cache_manager_with_transfer_control_test.cc:354-366`):**
`NotifyForRead` registers `{0, 1, 2}`; `PullStream` requests the reordered
subset `source_blocks = {2, 0}` into `destination_blocks = {6, 7}`.
`ValidateAndBeginPull` accepts the subset (the test asserts the handshake
`status == 0`); model-only beyond the test, the transfer delivers
`decodeHbm[0][6] = .kv 0 2` and `decodeHbm[0][7] = .kv 0 0`. -/
theorem trace_subset_pull_acknowledged :
    ((BlockPipeline.sys 1 8 2 [0, 1, 2] [⟨2, 6, 0⟩, ⟨0, 7, 1⟩]).run trace1Layer).map
      (fun s => (s.pipe.recv.published,
                 (s.decodeHbmB.getD 0 [])[6]?,
                 (s.decodeHbmB.getD 0 [])[7]?,
                 (s.decodeHbmB.getD 0 [])[1]?)) =
    some (some true, some (BlockCell.kv 0 2), some (BlockCell.kv 0 0), some BlockCell.blank) := by
  decide

/-- **Trace 3 (`PullOfUnregisteredBlockIsRejected`,
`kv_cache_manager_with_transfer_control_test.cc:382-395`):**
`NotifyForRead` registers `{0, 1}`; `PullStream` requests `{0, 2}`.
`ValidateAndBeginPull` (`.send .beginPull`) is rejected (`none`) — the test
checks the producer's response — and, model-only, the consumer's pull fails
(`.recv (.pullReply false)`) with `pullStarted = false`. -/
theorem trace_unregistered_block_rejected :
    let sys := BlockPipeline.sys 1 4 2 [0, 1] [⟨0, 0, 0⟩, ⟨2, 1, 1⟩]
    sys.run [.send .beginPull] = none ∧
    (sys.run [.recv (.pullReply false), .recv .publish]).map
      (fun s => (s.pipe.send.pullStarted, s.pipe.recv.published)) =
    some (false, some false) := by
  decide

/-- **Trace 4 (`PullWithDuplicateSourceBlockIsRejected`,
`kv_cache_manager_with_transfer_control_test.cc:397-410`):**
`NotifyForRead` registers `{0, 1}`; `PullStream` requests duplicate source
blocks `{0, 0}`. `ValidateAndBeginPull` (`.send .beginPull`) is rejected. -/
theorem trace_duplicate_source_block_rejected :
    (BlockPipeline.sys 1 4 2 [0, 1] [⟨0, 0, 0⟩, ⟨0, 1, 1⟩]).run [.send .beginPull] = none := by
  decide

/-- **Trace 5 (`EmptyPullIsRejected`,
`kv_cache_manager_with_transfer_control_test.cc:412-424`):**
`NotifyForRead` registers `{0}`; `PullStream` requests `{}`.
`ValidateAndBeginPull` (`.send .beginPull`) is rejected. -/
theorem trace_empty_pull_rejected :
    (BlockPipeline.sys 1 4 2 [0] []).run [.send .beginPull] = none := by
  decide

/-- **Trace 6 (`LocalOrchestratedTransfer`,
`kv_cache_manager_with_transfer_test.cc:111-290`):**
Pull remote block `0` into local device block `1`: `decodeHbmB[0][1] = .kv 0 0`
while local device block `0` remains untouched (`.blank`). -/
theorem trace_local_orchestrated_transfer :
    ((BlockPipeline.sys 1 2 2 [0] [⟨0, 1, 0⟩]).run trace1Layer).map
      (fun s => (s.pipe.recv.published, s.decodeHbmB)) =
    some (some true, [[BlockCell.blank, BlockCell.kv 0 0]]) := by
  decide

/-- **Trace 7 (`LocalOrchestratedTransferToCustomHostBlock`,
`kv_cache_manager_with_transfer_test.cc:324-438`):**
Pull remote block `0` into local device block `1` using custom host block `4`
out of `6` host blocks (`allocateStagingForLoad [1] (.customHost [4]) = some [4]`):
- Device block `1` receives `.kv 0 0` while device block `0` stays `.blank`.
- Custom host block `4` receives `.kv 0 0` while host block `5` stays `.blank`. -/
theorem trace_custom_host_block_transfer :
    allocateStagingForLoad [1] (.customHost [4]) = some [4] ∧
    ((BlockPipeline.sys 1 2 6 [0] [⟨0, 1, 4⟩]).run trace1Layer).map
      (fun s => (s.pipe.recv.published,
                 s.decodeHbmB,
                 (s.decodeStagingB.getD 0 [])[4]?,
                 (s.decodeStagingB.getD 0 [])[5]?)) =
    some (some true, [[BlockCell.blank, BlockCell.kv 0 0]],
          some (BlockCell.kv 0 0), some BlockCell.blank) := by
  decide

/-- **Trace 8 (`test_non_contiguous_blocks`,
`tpu_sync/api/jax/kv_cache_manager_transfer_test.py:187-271`,
`tpu_sync/api/torch/kv_cache_manager_transfer_test.py:176-206`):**
2 layers completing out of order; `registered = [0, 2]`, `remote = [0, 2]`,
`local = [0, 1]` out of `3` blocks. For both layers `l ∈ {0, 1}`,
`decodeHbmB[l] = [.kv l 0, .kv l 2, .blank]` (local block `2` stays untouched). -/
theorem trace_non_contiguous_blocks :
    ((BlockPipeline.sys 2 3 2 [0, 2] [⟨0, 0, 0⟩, ⟨2, 1, 1⟩]).run trace2LayersOutOfOrder).map
      (fun s => (s.pipe.recv.published, s.decodeHbmB)) =
    some (some true, [[BlockCell.kv 0 0, BlockCell.kv 0 2, BlockCell.blank],
                      [BlockCell.kv 1 0, BlockCell.kv 1 2, BlockCell.blank]]) := by
  decide

/-- **Trace 9 (`test_host_reordering`,
`tpu_sync/api/jax/kv_cache_manager_transfer_test.py:274-356`,
`tpu_sync/api/torch/kv_cache_manager_transfer_test.py:209-237`):**
2 layers completing out of order; `registered = [0, 1]`, `remote = [1, 0]`
(reversed), `local = [0, 1]`. Both layers deliver `[.kv l 1, .kv l 0]` in
`decodeHbmB[l]` (`local[0] ← remote[1]`, `local[1] ← remote[0]`). -/
theorem trace_host_reordering :
    ((BlockPipeline.sys 2 2 2 [0, 1] [⟨1, 0, 0⟩, ⟨0, 1, 1⟩]).run trace2LayersOutOfOrder).map
      (fun s => (s.pipe.recv.published, s.decodeHbmB)) =
    some (some true, [[BlockCell.kv 0 1, BlockCell.kv 0 0],
                      [BlockCell.kv 1 1, BlockCell.kv 1 0]]) := by
  decide

/-- The 10-block non-contiguous reversed transfer configuration from
`test_large_complex_non_contiguous_and_reorder`
(`tpu_sync/api/jax/kv_cache_manager_transfer_test.py:359-448`,
`tpu_sync/api/torch/kv_cache_manager_transfer_test.py:240-282`). -/
def largeComplexRegistered : List Nat := [0, 2, 3, 5, 6, 7, 9, 11, 12, 14]
def largeComplexRemote : List Nat := largeComplexRegistered.reverse
def largeComplexLocal : List Nat := List.range 10
def largeComplexHost : List Nat := List.range 10

/-- **Trace 10 (`test_large_complex_non_contiguous_and_reorder`,
`tpu_sync/api/jax/kv_cache_manager_transfer_test.py:359-448`,
`tpu_sync/api/torch/kv_cache_manager_transfer_test.py:240-282`):**
16 blocks per layer, 2 layers completing out of order; `registered = [0, 2, 3, 5, 6, 7, 9, 11, 12, 14]`,
`remote = reversed(registered)`, `local = [0..9]`.
- `BuildCoalescedCopySpec` compresses the 10 sorted producer D2H blocks into 6
  contiguous DMA runs (`[0]`, `[2, 3]`, `[5, 6, 7]`, `[9]`, `[11, 12]`, `[14]`).
- For every layer `l ∈ {0, 1}`, local blocks `0..9` receive `.kv l remote[i]`
  and untouched local blocks `10..15` remain `.blank`. -/
theorem trace_large_complex_non_contiguous_and_reorder :
    let plan := buildLoadCopyPlan largeComplexRemote largeComplexLocal largeComplexHost
    let triples := zipTriples largeComplexRemote largeComplexLocal largeComplexHost
    plan.d2hSpec.length = 6 ∧
    ((BlockPipeline.sys 2 16 10 largeComplexRegistered triples).run trace2LayersOutOfOrder).map
      (fun s => (s.pipe.recv.published, s.decodeHbmB)) =
    some (some true,
          [(largeComplexRemote.map (BlockCell.kv 0)) ++ List.replicate 6 BlockCell.blank,
           (largeComplexRemote.map (BlockCell.kv 1)) ++ List.replicate 6 BlockCell.blank]) := by
  decide

/-! ### Mutant: Mismatched Transport Order (`recv.cc:296`)

If `BuildLoadCopyPlan` sorted `producer_remote_block_ids` by `remote_order`
(`recv.cc:295`) without applying the same `remote_order` permutation to
`transport_host_block_ids` (`recv.cc:296`), then on `test_host_reordering`
(`remote = [1, 0], local = [0, 1]`), `decodeHbm` silently receives the
un-permuted blocks `[.kv 0 0, .kv 0 1]` instead of `[.kv 0 1, .kv 0 0]`. -/

def buildBuggyCopyPlan (triples : List BlockTriple) : CopyPlan :=
  let base := buildCopyPlanFromTriples triples
  -- Bug: `h2hPairs` uses unsorted `triples` instead of `remoteSorted`.
  let buggyH2hPairs := (enumFrom 0 triples).map (fun (t, j) => (j, t.host))
  { base with h2hPairs := buggyH2hPairs }

theorem trace_mutant_mismatched_transport_order :
    let triples : List BlockTriple := [⟨1, 0, 0⟩, ⟨0, 1, 1⟩]
    let goodHbm := h2dStage 0 2 2 (buildCopyPlanFromTriples triples)
    let buggyHbm := h2dStage 0 2 2 (buildBuggyCopyPlan triples)
    goodHbm = [BlockCell.kv 0 1, BlockCell.kv 0 0] ∧
    buggyHbm = [BlockCell.kv 0 0, BlockCell.kv 0 1] ∧
    buggyHbm ≠ goodHbm := by decide

end Checks

end BlockOrdering

end TpuSyncVerify.Transfer.PrefillDecode
