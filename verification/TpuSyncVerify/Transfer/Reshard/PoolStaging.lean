import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Common.ListAux

/-!
# Bounded pool host staging and per-UUID lease lifecycle

Formal model and proofs of bounded host staging (`PoolStagingStorage`) and
per-UUID page-lease lifecycle in `KVCacheManagerBase` and
`KVCacheManagerWithTransfer`.

Citations are to the baseline commit in `verification/README.md` §Status.
`base.h`/`base.cc` are `tpu_sync/kv_cache/kv_cache_manager_base.{h,cc}`;
`mgr.cc` is `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`;
`reshard_recv.h`/`reshard_recv.cc` are
`tpu_sync/kv_cache/reshard_receive_session.{h,cc}`; `pool_reshard_test.cc` is
`tpu_sync/kv_cache/kv_cache_manager_with_transfer_pool_reshard_test.cc`. Exact
line ranges for every symbol, sub-block, and test are in the generated
`## Source map` table below.

  ## C++ anchorage

  1. **Bounded staging arena (`PoolStagingStorage` in `base.h`,
     `KVCacheManagerBase::ConfigurePoolStaging` in `base.cc`):**
     When a storage's pools declare `staging_blocks_per_request > 0` and
     `staging_leases > 0` such that `num_slots = staging_leases *
     blocks_per_lease < max_pool_blocks`, `ConfigurePoolStaging` allocates a
     bounded host arena of `num_slots` page slots (`free_slots = [num_slots-1,
     ..., 0]`, so `.back()` pops `0, 1, ...` in order).

  2. **Idempotent per-UUID lease acquisition (`KVCacheManagerBase::AcquirePoolStagingLease` in `base.cc`):**
     Filters `block_ids` down to `missing` — deduplicated block IDs not already
     present in `st.leases[uuid]->slot_by_block` (`if (cur != nullptr && cur->slot_by_block.contains(block_id)) continue;`). Multiple pools
     sharing a physical storage (`storage_index`) therefore share one page lease
     under the same `uuid` without double-allocating slots. If
     `missing.size() > st.num_slots` or `st.free_slots.size() < missing.size()`,
     acquisition fails with `ResourceExhausted` (`if (static_cast<int64_t>(missing.size()) > st.num_slots)` and `while (st.free_slots.size() < missing.size())`). Otherwise it
     pops `missing.size()` slots from `free_slots` and records `block_id ↦ slot`
     in `st.leases[uuid]` (`for (int64_t block_id : missing)` through `st.leases[uuid] = std::move(lease)`).

  3. **Lease release (`KVCacheManagerBase::ReleasePoolStagingLeases` in `base.cc`):**
     Looks up `st.leases.find(uuid)`, pushes every `slot ∈ lease->slots` back
     onto `st.free_slots`, and erases `uuid` from `st.leases`.

  4. **Receive registration lifecycle & Risk R5 (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv` in `mgr.cc`,
     `ReshardReceiveSession::Create`, `ReshardReceiveSession::AcquireStagingLeases`, `ReshardReceiveSession::ReleaseStaging` in `reshard_recv.cc`):**
     `PoolReshardRegisterRecv` executes in three steps:
     - Phase 1 (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv` checking `active_pool_reshard_recvs_`,
       `ReshardReceiveSession::Create` claiming `plan.uuid()`): checks `active_pool_reshard_recvs_`
       under `mu_` and claims `plan.uuid()` via
       `base->RegisterActivePlanDirect(plan.uuid(), plan, /*is_sender=*/false)`
       before constructing any `ReshardReceiveSession` object.
     - Phase 2 (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv` calling `ReshardReceiveSession::Create` and `ReshardReceiveSession::AcquireStagingLeases`): constructs `ReshardReceiveSession`
       and calls `AcquireStagingLeases(plan)`,
       which sets `staging_released_ = false` and calls
       `base_->AcquirePoolStagingLease(uuid_, ...)`. On failure,
       `Create` calls `session->ReleaseStaging()` (`ReleaseStagingLocked`) while
       `uuid` is still claimed and rolls back
       `base->UnregisterActivePlanDirect(plan.uuid())`.
     - Phase 3 (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv`, `active_pool_reshard_recvs_[plan.uuid()] = std::move(recv_session);` under `mu_`):
       inserts the session into `active_pool_reshard_recvs_`.
     Under the unreserved mutant (`RegistrationPolicy.leaseBeforeReserve`,
     Finding F6 / Risk R5), if Phase 2 ran before `RegisterActivePlanDirect`
     claimed `uuid`, two concurrent or duplicate `PoolReshardRegisterRecv`
     calls with the same `uuid` would share `st.leases[uuid]` in Phase 2; when
     `RegisterActivePlanDirect` rejected the second call (`AlreadyExistsError`),
     destroying its `ReshardReceiveSession` would run
     `~ReshardReceiveSession() -> ReleaseStaging() -> ReleasePoolStagingLeases(uuid)`
     (`ReshardReceiveSession::~ReshardReceiveSession` in `reshard_recv.h`, `ReshardReceiveSession::ReleaseStagingLocked` and `ReshardReceiveSession::ReleaseStaging` in `reshard_recv.cc`),
     erasing `st.leases[uuid]` and returning the surviving session's slots to
     `free_slots` while the surviving session is still active.

  ## Main results

  - `missingBlocksAux_empty_of_covered` & `acquireLease_idempotent`: re-acquiring
    a subset of already-leased block IDs for the same `uuid` is a no-op
    (`KVCacheManagerBase::AcquirePoolStagingLease`: `if (cur != nullptr && cur->slot_by_block.contains(block_id)) continue;` and `if (missing.empty()) return absl::OkStatus();`).
  - `ArenaInv.conservation` & `allocateMissing_slot_sum`:
    total slots across `freeSlots` and all active leases equals `numSlots`.
  - `no_slot_aliasing_between_distinct_uuids`: when active leases hold disjoint
    slot lists (`ArenaInv.nodupSlots` / `leases_disjoint_of_nodup`), distinct
    `uuid`s never resolve any block ID to the same host staging slot.
  - `reachable_reserveBeforeLease_safe`: under the shipping `reserveBeforeLease`
    protocol (claiming `uuid` before acquiring staging leases), every reachable
    state keeps active session leases live and pairwise slot-disjoint.
  - `trace_r5_duplicate_uuid_frees_survivor_lease_and_aliases_slot`: constructive
    counterexample trace under the `leaseBeforeReserve` mutant (Finding F6 /
    Risk R5) showing a rejected duplicate-UUID arm freeing the survivor's lease
    and a third session (`uuid = 8`) receiving the same physical slot `0`.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `base.h` | `PoolStagingLease` | `:984-987` |
| `base.h` | `PoolStagingStorage` | `:988-996` |
| `base.cc` | `RemoteAddress` | `:154-175` |
| `base.cc` | `KVCacheManagerBase::ConfigurePoolStaging` | `:1964-2067` |
| `base.cc` | `KVCacheManagerBase::PoolStagingLeaseSnapshot` | `:2075-2086` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` | `:2088-2145` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` (`std::vector<int64_t> missing;` .. `if (missing.empty())`) | `:2099-2113` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` (`if (static_cast<int64_t>(missing.size()) > st.num_slots)` .. `while (st.free_slots.size() < missing.size())`) | `:2116-2124` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` (`auto lease = std::make_shared<PoolStagingLease>();` .. `st.leases[uuid] = std::move(lease);`) | `:2133-2143` |
| `base.cc` | `KVCacheManagerBase::ReleasePoolStagingLeases` | `:2147-2163` |
| `base.cc` | `KVCacheManagerBase::PoolBlockHostBase` | `:2187-2232` |
| `base.cc` | `KVCacheManagerBase::PoolHostBaseAddrs` | `:2364-2411` |
| `base.cc` | `KVCacheManagerBase::CopyPoolBlocks` (`std::shared_ptr<const PoolStagingLease> lease;` .. `auto slot_it = lease->slot_by_block.find(block_id);`) | `:2501-2532` |
| `base.cc` | `KVCacheManagerBase::RegisterActivePlan(host_block_of)` (`if (auto [it, inserted] = active_plans_.try_emplace(`) | `:3158-3165` |
| `base.cc` | `KVCacheManagerBase::GetBlockChunks` (`std::shared_ptr<const PoolStagingLease> staging_lease;` .. `const auto block_host_base =`) | `:3255-3287` |
| `base.cc` | `KVCacheManagerBase::GetBlockChunks` (`.raddr = RemoteAddress(dst_addrs, entry.dst_shard_idx(),`) | `:3428-3430` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` | `:679-715` |
| `reshard_recv.h` | `ReshardReceiveSession` (`~ReshardReceiveSession() override`) | `:71` |
| `reshard_recv.cc` | `ReshardReceiveSession::Create` | `:351-390` |
| `reshard_recv.cc` | `ReshardReceiveSession::Create` (`ABSL_RETURN_IF_ERROR(` .. `return session;`) | `:376-389` |
| `reshard_recv.cc` | `ReshardReceiveSession::AcquireStagingLeases` | `:420-459` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReleaseStagingLocked` | `:461-465` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReleaseStaging` | `:467-470` |
| `pool_staging_test.cc` | `PoolStagingTest.BoundedArenaLeasesAndAddressing` | `:115-208` |
| `pool_staging_test.cc` | `PoolStagingTest.FallsBackToFullMirrorWithoutHintsOrLeases` | `:212-235` |
| `pool_staging_test.cc` | `PoolStagingTest.SmallPoolIdentitySharedStorageAndStrideMismatch` | `:240-301` |
| `pool_staging_test.cc` | `PoolStagingTest.SenderRaddrMatchesReceiverPointer` | `:306-416` |
| `pool_staging_test.cc` | `PoolStagingTest.SenderRaddrUsesReceiverLeaseSlot` | `:419-484` |
| `pool_staging_test.cc` | `PoolStagingTest.PoolHostBaseAddrs` | `:489-521` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.DuplicatePoolRecvRegistrationKeepsOriginalStagingLease` | `:624-674` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.ConcurrentDuplicatePoolRecvRegistrationKeepsWinnerStagingLease` | `:676-732` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.StagingAcquireFailureReleasesUuidClaim` | `:734-764` |
<!-- source-map:end -->
-/

namespace TpuSyncVerify.Transfer.Reshard.PoolStaging

open TpuSyncVerify

/-! ## Part I — Bounded Staging Arena (`PoolStagingStorage`) -/

/-- One UUID's staging lease on a bounded storage
(`KVCacheManagerBase::PoolStagingLease` in `base.h`).
`slotByBlock` maps `blockId ↦ slot`; `slots` records the leased slot indices in
allocation order. -/
structure Lease where
  slotByBlock : List (Nat × Nat)
  slots : List Nat
  deriving DecidableEq, Repr

/-- Look up the arena slot assigned to `blockId` in `lease`
(`cur->slot_by_block.contains(block_id)` in `KVCacheManagerBase::AcquirePoolStagingLease`,
`lease->slot_by_block.find(block_id)` in `KVCacheManagerBase::PoolBlockHostBase` and
`KVCacheManagerBase::CopyPoolBlocks`, and `staging_lease->slot_by_block.find(block_id)` in
`KVCacheManagerBase::GetBlockChunks`). -/
def Lease.lookupSlot (l : Lease) (blockId : Nat) : Option Nat :=
  (l.slotByBlock.find? (fun p => p.1 == blockId)).map Prod.snd

/-- One physical storage's bounded staging arena
(`KVCacheManagerBase::PoolStagingStorage` in `base.h`).
`freeSlots` is modeled with its top-of-stack (`back()` in C++) at the head of
the list so popping one slot is `freeSlots.head?` / `freeSlots.tail`. -/
structure Arena where
  numSlots : Nat
  freeSlots : List Nat
  leases : List (Nat × Lease)
  deriving DecidableEq, Repr

/-- Initial arena with `numSlots` free slots `[0, 1, ..., numSlots - 1]` in pop
order (`KVCacheManagerBase::ConfigurePoolStaging`: C++ pushes
`num_slots - 1` down to `0` so `free_slots.back()` pops `0, 1, ...`). -/
def Arena.init (numSlots : Nat) : Arena :=
  { numSlots := numSlots
  , freeSlots := List.range numSlots
  , leases := [] }

/-- Look up `uuid`'s current lease on `a` (`leases.find(uuid)` in
`KVCacheManagerBase::PoolStagingLeaseSnapshot` and `st.leases.find(uuid)` in
`KVCacheManagerBase::AcquirePoolStagingLease`). -/
def Arena.lookupLease (a : Arena) (uuid : Nat) : Option Lease :=
  (a.leases.find? (fun p => p.1 == uuid)).map Prod.snd

/-- Look up the slot assigned to `(uuid, blockId)` on `a`
(`KVCacheManagerBase::PoolBlockHostBase` / `KVCacheManagerBase::CopyPoolBlocks` /
`KVCacheManagerBase::GetBlockChunks`). -/
def Arena.resolveBlockSlot (a : Arena) (uuid blockId : Nat) : Option Nat :=
  match a.lookupLease uuid with
  | none => none
  | some l => l.lookupSlot blockId

/-- Whether `blockId` is already mapped in `cur` (`cur != nullptr &&
cur->slot_by_block.contains(block_id)` in
`KVCacheManagerBase::AcquirePoolStagingLease`). -/
def alreadyLeased (cur : Option Lease) (blockId : Nat) : Bool :=
  match cur with
  | none => false
  | some l => (l.lookupSlot blockId).isSome

/-- Deduplicate `blockIds` in first-seen order while filtering out blocks
already mapped in `cur` (`std::vector<int64_t> missing;` loop in `KVCacheManagerBase::AcquirePoolStagingLease`). -/
def missingBlocksAux (cur : Option Lease) : List Nat → List Nat → List Nat
  | [], _ => []
  | b :: rest, seen =>
    if alreadyLeased cur b || seen.contains b then
      missingBlocksAux cur rest seen
    else
      b :: missingBlocksAux cur rest (b :: seen)

def missingBlocks (cur : Option Lease) (blockIds : List Nat) : List Nat :=
  missingBlocksAux cur blockIds []

/-- Assign the next `missing.length` slots from `freeSlots` to `missing` block
IDs, extending `cur` (`for (int64_t block_id : missing)` in `KVCacheManagerBase::AcquirePoolStagingLease`). -/
def allocateMissing : List Nat → List Nat → Lease → Option (List Nat × Lease)
  | [], free, acc => some (free, acc)
  | b :: bs, s :: free, acc =>
    allocateMissing bs free
      { slotByBlock := acc.slotByBlock ++ [(b, s)]
      , slots := acc.slots ++ [s] }
  | _ :: _, [], _ => none

/-- Update or insert `(uuid, l)` in `leases`, preserving key uniqueness
(`st.leases[uuid] = std::move(lease)` in
`KVCacheManagerBase::AcquirePoolStagingLease`). -/
def upsertLease : List (Nat × Lease) → Nat → Lease → List (Nat × Lease)
  | [], uuid, l => [(uuid, l)]
  | (u, old) :: rest, uuid, l =>
    if u = uuid then
      (uuid, l) :: rest
    else
      (u, old) :: upsertLease rest uuid l

/-- `KVCacheManagerBase::AcquirePoolStagingLease`.
Returns `some a'` on `OkStatus` and `none` on `ResourceExhausted`. -/
def Arena.acquireLease (a : Arena) (uuid : Nat) (blockIds : List Nat) : Option Arena :=
  let cur := a.lookupLease uuid
  let missing := missingBlocks cur blockIds
  if missing.isEmpty then
    some a
  else if missing.length > a.numSlots || a.freeSlots.length < missing.length then
    none
  else
    let baseLease := cur.getD ⟨[], []⟩
    match allocateMissing missing a.freeSlots baseLease with
    | none => none
    | some (free', lease') =>
      some { a with
        freeSlots := free'
        leases := upsertLease a.leases uuid lease' }

/-- `KVCacheManagerBase::ReleasePoolStagingLeases`.
Pushes `uuid`'s leased slots back onto the top of `freeSlots` (`push_back` in
C++, where `back()` is the head of `freeSlots`) and removes `uuid` from
`leases`. -/
def Arena.releaseLease (a : Arena) (uuid : Nat) : Arena :=
  match a.lookupLease uuid with
  | none => a
  | some l =>
    { a with
      freeSlots := l.slots.reverse ++ a.freeSlots
      leases := a.leases.filter (fun p => p.1 != uuid) }

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

/-! ## Part III — Receive Registration Lifecycle & Risk R5 (`PoolReshardRegisterRecv`)

We now model the interaction between `KVCacheManagerWithTransfer::PoolReshardRegisterRecv`,
`ReshardReceiveSession` (`ReshardReceiveSession::Create`,
`ReshardReceiveSession::AcquireStagingLeases`, `ReshardReceiveSession::ReleaseStaging`),
and `PoolStagingStorage` across two registration policies:
- `RegistrationPolicy.reserveBeforeLease` (shipping): `ReshardReceiveSession::Create`
  claims `uuid` via `base->RegisterActivePlanDirect(plan.uuid(), plan, /*is_sender=*/false)`
  before constructing the session and calling `AcquirePoolStagingLease`, rolling
  back the claim on lease failure (`session->ReleaseStaging(); base->UnregisterActivePlanDirect(plan.uuid()).IgnoreError();`).
- `RegistrationPolicy.leaseBeforeReserve` (Finding F6 / Risk R5 mutant):
  `AcquirePoolStagingLease` runs before `RegisterActivePlanDirect` claims `uuid`,
  so a rejected duplicate registration's destructor releases the active session's
  staging lease. -/

inductive RegistrationPolicy where
  | reserveBeforeLease
  | leaseBeforeReserve
  deriving DecidableEq, Repr

/-- A pending `PoolReshardRegisterRecv` call that has passed Phase 1 (the initial
`active_pool_reshard_recvs_` check and, under `reserveBeforeLease`,
`RegisterActivePlanDirect`) and is currently executing Phase 2
(`AcquireStagingLeases`) or Phase 3 (`active_pool_reshard_recvs_` insertion). -/
structure InFlightArm where
  callId : Nat
  uuid : Nat
  blocks : List Nat
  leasedInPhase2 : Bool
  deriving DecidableEq, Repr

/-- State of the receive-registration + bounded-staging subsystem. -/
structure RegState where
  arena : Arena
  /-- UUIDs currently registered in `active_pool_reshard_recvs_` and
  `RegisterActivePlanDirect`, paired with their required destination block IDs. -/
  activeSessions : List (Nat × List Nat)
  /-- Concurrent `PoolReshardRegisterRecv` calls in flight between Phase 1 and
  Phase 3. -/
  inFlightArms : List InFlightArm
  deriving DecidableEq, Repr

inductive RegEv where
  /-- Phase 1 (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv`,
  `ReshardReceiveSession::Create`): check if `uuid` is already active;
  under `.reserveBeforeLease`, also claim `uuid` via `RegisterActivePlanDirect`
  against concurrent arms immediately. -/
  | beginArm (callId uuid : Nat) (blocks : List Nat)
  /-- Phase 2 (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv`,
  `ReshardReceiveSession::Create`, `ReshardReceiveSession::AcquireStagingLeases`): call
  `AcquirePoolStagingLease(uuid, blocks)` outside `mu_`. -/
  | acquireArmLease (callId : Nat)
  /-- Phase 3 (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv`): finish registration
  and insert into `active_pool_reshard_recvs_`. Under `.leaseBeforeReserve`, if
  `uuid` is already in `activeSessions`, `RegisterActivePlanDirect` returns
  `AlreadyExistsError` and the temporary `ReshardReceiveSession` destructor runs
  `ReleasePoolStagingLeases(uuid)` (`ReshardReceiveSession::~ReshardReceiveSession`,
  `ReshardReceiveSession::ReleaseStagingLocked`). -/
  | finishArm (callId : Nat)
  /-- Normal session completion (`FinishPoolH2d` / `UnregisterActivePlan`):
  releases `uuid`'s staging lease and removes `uuid` from `activeSessions`. -/
  | settleSession (uuid : Nat)
  deriving DecidableEq, Repr

def RegState.init (numSlots : Nat) : RegState :=
  { arena := Arena.init numSlots
  , activeSessions := []
  , inFlightArms := [] }

def RegState.hasActiveUuid (s : RegState) (uuid : Nat) : Bool :=
  s.activeSessions.any (fun p => p.1 == uuid)

def RegState.hasInFlightUuid (s : RegState) (uuid : Nat) : Bool :=
  s.inFlightArms.any (fun a => a.uuid == uuid)

def RegState.findArm (s : RegState) (callId : Nat) : Option InFlightArm :=
  s.inFlightArms.find? (fun a => a.callId == callId)

def RegState.removeArm (s : RegState) (callId : Nat) : List InFlightArm :=
  s.inFlightArms.filter (fun a => a.callId != callId)

def RegState.step (policy : RegistrationPolicy) (s : RegState) (e : RegEv) : Option RegState :=
  match e with
  | .beginArm callId uuid blocks =>
    if (s.findArm callId).isSome then none
    else if s.hasActiveUuid uuid then none
    else if policy == .reserveBeforeLease && s.hasInFlightUuid uuid then none
    else
      some { s with
        inFlightArms := s.inFlightArms ++ [⟨callId, uuid, blocks, false⟩] }
  | .acquireArmLease callId =>
    match s.findArm callId with
    | none => none
    | some arm =>
      if arm.leasedInPhase2 then none
      else
        match s.arena.acquireLease arm.uuid arm.blocks with
        | none =>
          -- Phase 2 `AcquireStagingLeases` failed (`ResourceExhausted`):
          -- `ReshardReceiveSession::Create` releases any partial lease and
          -- rolls back `UnregisterActivePlanDirect`
          -- (`ReshardReceiveSession::Create`, `ReshardReceiveSession::AcquireStagingLeases`, `ReshardReceiveSession::ReleaseStagingLocked`).
          some { s with
            arena := s.arena.releaseLease arm.uuid
            inFlightArms := s.removeArm callId }
        | some arena' =>
          some { s with
            arena := arena'
            inFlightArms := s.inFlightArms.map (fun a =>
              if a.callId == callId then { a with leasedInPhase2 := true } else a) }
  | .finishArm callId =>
    match s.findArm callId with
    | none => none
    | some arm =>
      if !arm.leasedInPhase2 then none
      else if s.hasActiveUuid arm.uuid then
        -- Under `.leaseBeforeReserve`, `RegisterActivePlanDirect` returns
        -- `AlreadyExistsError` (`active_plans_.try_emplace` in `KVCacheManagerBase::RegisterActivePlan`) after
        -- `Create` already acquired the lease, and the temporary
        -- `ReshardReceiveSession` destructor calls
        -- `ReleasePoolStagingLeases(arm.uuid)`.
        some { s with
          arena := s.arena.releaseLease arm.uuid
          inFlightArms := s.removeArm callId }
      else
        some { s with
          activeSessions := s.activeSessions ++ [(arm.uuid, arm.blocks)]
          inFlightArms := s.removeArm callId }
  | .settleSession uuid =>
    if !s.hasActiveUuid uuid then none
    else if policy == .reserveBeforeLease && s.hasInFlightUuid uuid then none
    else
      some { s with
        arena := s.arena.releaseLease uuid
        activeSessions := s.activeSessions.filter (fun p => p.1 != uuid) }

def RegState.sys (policy : RegistrationPolicy) (numSlots : Nat) :
    System RegState RegEv where
  init := RegState.init numSlots
  step := RegState.step policy

/-- **Safety Predicate (`ActiveSessionsHoldLeases`)**:
Every registered active session `(uuid, blocks) ∈ s.activeSessions` holds a
live lease in `s.arena.leases` that maps every block `b ∈ blocks` to an
allocated staging slot (`(s.arena.resolveBlockSlot uuid b).isSome`). -/
def ActiveSessionsHoldLeases (s : RegState) : Bool :=
  s.activeSessions.all (fun (uuid, blocks) =>
    blocks.all (fun b => (s.arena.resolveBlockSlot uuid b).isSome))

/-- **Risk R5 / Finding F6 Constructive Counterexample Trace
(`KVCacheManagerWithTransfer::PoolReshardRegisterRecv`, `ReshardReceiveSession::Create`, `ReshardReceiveSession::ReleaseStagingLocked`)**:
Under the unreserved mutant `.leaseBeforeReserve`:
1. Call 1 (`uuid = 7`, `blocks = [5]`) and Call 2 (duplicate `uuid = 7`,
   `blocks = [5]`) both pass Phase 1 (`beginArm`) before either reaches Phase 3.
2. Call 1 acquires slot `0` for `(uuid = 7, block = 5)` in Phase 2 and completes
   Phase 3 (`finishArm 1`), becoming an active receive session.
3. Call 2 executes Phase 2 (`acquireArmLease 2`), which succeeds idempotently on
   `uuid = 7`'s existing lease (`KVCacheManagerBase::AcquirePoolStagingLease`), and then
   reaches Phase 3 (`finishArm 2`). `RegisterActivePlanDirect` rejects Call 2
   with `AlreadyExistsError`, and Call 2's `~ReshardReceiveSession` runs
   `ReleasePoolStagingLeases(7)` — freeing Call 1's slot `0` back to `freeSlots`
   while Call 1 (`uuid = 7`) is still in `activeSessions`!
4. Call 3 (`uuid = 8`, `blocks = [12]`) then arms and acquires **slot 0**, the
   exact physical staging slot that Call 1 (`uuid = 7`) was using. -/
def r5CounterexampleEvents : List RegEv :=
  [ .beginArm 1 7 [5]
  , .beginArm 2 7 [5]
  , .acquireArmLease 1
  , .finishArm 1
  , .acquireArmLease 2
  , .finishArm 2
  , .beginArm 3 8 [12]
  , .acquireArmLease 3
  , .finishArm 3 ]

theorem trace_r5_duplicate_uuid_frees_survivor_lease_and_aliases_slot :
    ((RegState.sys .leaseBeforeReserve 2).run r5CounterexampleEvents).map
      (fun s =>
        ( s.hasActiveUuid 7
        , s.arena.lookupLease 7
        , ActiveSessionsHoldLeases s
        , s.arena.resolveBlockSlot 8 12 )) =
      some (true, none, false, some 0) := by
  decide

/-- Under `RegistrationPolicy.reserveBeforeLease`
(`PoolStagingRecvRegistrationTest.ConcurrentDuplicatePoolRecvRegistrationKeepsWinnerStagingLease`),
the R5 duplicate-UUID race is rejected at step 2 (`.beginArm 2 7 [5]`) because
`uuid = 7` is already claimed by Call 1. -/
theorem r5_blocked_by_reserveBeforeLease :
    (RegState.sys .reserveBeforeLease 2).run r5CounterexampleEvents = none := by
  decide

/-! ## Part IV — Inductive Safety of `reserveBeforeLease` and Cross-UUID Frame Lemmas

We prove that:
1. `releaseLease` and `acquireLease` on `uuid` leave `lookupLease uuid'` and
   `resolveBlockSlot uuid' b` unchanged for every `uuid' ≠ uuid`.
2. Whenever `a.acquireLease uuid blockIds = some a'`, every `b ∈ blockIds`
   resolves to `some slot` under `a'.resolveBlockSlot uuid b`.
3. Consequently, in every state where active sessions have no concurrent
   in-flight arm with the same `uuid`, any step for another `uuid'` preserves
   every active session's lease resolution. -/

/-- Disjointness of `releaseLease` from any other `uuid' ≠ uuid`: releasing
`uuid` preserves `lookupLease uuid'`. -/
theorem lookupLease_filter_ne (leases : List (Nat × Lease)) {uuid uuid' : Nat}
    (hne : uuid' ≠ uuid) :
    ((leases.filter (fun p => p.1 != uuid)).find? (fun p => p.1 == uuid')).map Prod.snd =
      (leases.find? (fun p => p.1 == uuid')).map Prod.snd := by
  induction leases with
  | nil => rfl
  | cons hd tl ih =>
    rcases hd with ⟨u, l⟩
    simp only [List.filter_cons]
    by_cases hu : u = uuid
    · subst hu
      have hne' : (u == uuid') = false := beq_eq_false_iff_ne.mpr (Ne.symm hne)
      simp only [bne_self_eq_false, Bool.false_eq_true, ↓reduceIte, List.find?_cons, hne', ih]
    · have hne_u : (u != uuid) = true := bne_iff_ne.mpr hu
      simp only [hne_u, ↓reduceIte, List.find?_cons]
      by_cases hu' : u = uuid'
      · subst hu'; simp
      · have hne'' : (u == uuid') = false := beq_eq_false_iff_ne.mpr hu'
        simp only [hne'', ih]

/-- Releasing `uuid` leaves `lookupLease uuid'` and `resolveBlockSlot uuid' b`
unchanged for every `uuid' ≠ uuid`. -/
theorem releaseLease_preserves_other_uuid (a : Arena) {uuid uuid' : Nat}
    (hne : uuid' ≠ uuid) :
    (a.releaseLease uuid).lookupLease uuid' = a.lookupLease uuid' := by
  unfold Arena.releaseLease
  cases a.lookupLease uuid with
  | none => rfl
  | some l =>
    unfold Arena.lookupLease
    exact lookupLease_filter_ne a.leases hne

theorem releaseLease_preserves_other_resolve (a : Arena) {uuid uuid' b : Nat}
    (hne : uuid' ≠ uuid) :
    (a.releaseLease uuid).resolveBlockSlot uuid' b = a.resolveBlockSlot uuid' b := by
  unfold Arena.resolveBlockSlot
  rw [releaseLease_preserves_other_uuid a hne]

/-- Upserting `uuid`'s lease leaves `lookupLease uuid'` unchanged for every
`uuid' ≠ uuid`. -/
theorem lookupLease_upsert_ne (leases : List (Nat × Lease)) (uuid : Nat) (l : Lease)
    {uuid' : Nat} (hne : uuid' ≠ uuid) :
    ((upsertLease leases uuid l).find? (fun p => p.1 == uuid')).map Prod.snd =
      (leases.find? (fun p => p.1 == uuid')).map Prod.snd := by
  induction leases with
  | nil =>
    have hne' : (uuid == uuid') = false := beq_eq_false_iff_ne.mpr (Ne.symm hne)
    simp [upsertLease, hne']
  | cons hd tl ih =>
    rcases hd with ⟨u, old⟩
    simp only [upsertLease]
    by_cases hu : u = uuid
    · subst hu
      have hne' : (u == uuid') = false := beq_eq_false_iff_ne.mpr (Ne.symm hne)
      simp [hne']
    · simp only [hu, ↓reduceIte, List.find?_cons]
      by_cases hu' : u = uuid'
      · subst hu'; simp
      · have hne' : (u == uuid') = false := beq_eq_false_iff_ne.mpr hu'
        simp [hne', ih]

/-- Upserting `uuid`'s lease makes `lookupLease uuid` return `some l`. -/
theorem lookupLease_upsert_self (leases : List (Nat × Lease)) (uuid : Nat) (l : Lease) :
    ((upsertLease leases uuid l).find? (fun p => p.1 == uuid)).map Prod.snd = some l := by
  induction leases with
  | nil => simp [upsertLease]
  | cons hd tl ih =>
    rcases hd with ⟨u, old⟩
    simp only [upsertLease]
    by_cases hu : u = uuid
    · subst hu; simp
    · simp only [hu, ↓reduceIte, List.find?_cons]
      have hne : (u == uuid) = false := beq_eq_false_iff_ne.mpr hu
      simp [hne, ih]

/-- Acquiring a lease for `uuid` preserves `lookupLease uuid'` and
`resolveBlockSlot uuid' b` for every `uuid' ≠ uuid`. -/
theorem acquireLease_preserves_other_uuid {a a' : Arena} {uuid uuid' : Nat}
    {blockIds : List Nat}
    (hacq : a.acquireLease uuid blockIds = some a')
    (hne : uuid' ≠ uuid) :
    a'.lookupLease uuid' = a.lookupLease uuid' := by
  dsimp only [Arena.acquireLease] at hacq
  split at hacq
  · injection hacq with h; subst h; rfl
  · split at hacq
    · cases hacq
    · cases halloc : allocateMissing (missingBlocks (a.lookupLease uuid) blockIds)
          a.freeSlots ((a.lookupLease uuid).getD ⟨[], []⟩) with
      | none => simp [halloc] at hacq
      | some pair =>
        rcases pair with ⟨free', lease'⟩
        simp only [halloc, Option.some.injEq] at hacq
        subst hacq
        unfold Arena.lookupLease
        exact lookupLease_upsert_ne a.leases uuid lease' hne

theorem acquireLease_preserves_other_resolve {a a' : Arena} {uuid uuid' b : Nat}
    {blockIds : List Nat}
    (hacq : a.acquireLease uuid blockIds = some a')
    (hne : uuid' ≠ uuid) :
    a'.resolveBlockSlot uuid' b = a.resolveBlockSlot uuid' b := by
  unfold Arena.resolveBlockSlot
  rw [acquireLease_preserves_other_uuid hacq hne]

/-- Extending `slotByBlock` on the right preserves any existing `lookupSlot`
hit. -/
theorem lookupSlot_append_isSome_left (l : Lease) (extra : List (Nat × Nat))
    (slots' : List Nat) {b : Nat} (h : (l.lookupSlot b).isSome = true) :
    ((Lease.mk (l.slotByBlock ++ extra) slots').lookupSlot b).isSome = true := by
  unfold Lease.lookupSlot at h ⊢
  rw [List.find?_append]
  cases hfind : l.slotByBlock.find? (fun p => p.1 == b) with
  | none => simp [hfind] at h
  | some p => simp

/-- Appending `(b, s)` to `slotByBlock` ensures `lookupSlot b` is `some`. -/
theorem lookupSlot_snoc_self (xs : List (Nat × Nat)) (slots' : List Nat) (b s : Nat) :
    ((Lease.mk (xs ++ [(b, s)]) slots').lookupSlot b).isSome = true := by
  unfold Lease.lookupSlot
  rw [List.find?_append]
  cases xs.find? (fun p => p.1 == b) <;> simp

/-- `allocateMissing` preserves existing block mappings in `base` and adds a
mapping for every block in `missing`. -/
theorem allocateMissing_covers {missing free free' : List Nat} {base lease' : Lease}
    (halloc : allocateMissing missing free base = some (free', lease')) :
    (∀ b, (base.lookupSlot b).isSome = true → (lease'.lookupSlot b).isSome = true) ∧
    (∀ b ∈ missing, (lease'.lookupSlot b).isSome = true) := by
  induction missing generalizing free base with
  | nil =>
    simp only [allocateMissing, Option.some.injEq, Prod.mk.injEq] at halloc
    rcases halloc with ⟨_, rfl⟩
    exact ⟨fun _ h => h, fun _ h => by cases h⟩
  | cons m ms ih =>
    cases free with
    | nil => simp [allocateMissing] at halloc
    | cons s rest =>
      simp only [allocateMissing] at halloc
      obtain ⟨hpres, hmem⟩ := ih halloc
      refine ⟨?_, ?_⟩
      · intro b hb
        exact hpres b (lookupSlot_append_isSome_left base [(m, s)] (base.slots ++ [s]) hb)
      · intro b hb
        rcases List.mem_cons.mp hb with rfl | hb_ms
        · exact hpres b (lookupSlot_snoc_self base.slotByBlock (base.slots ++ [s]) b s)
        · exact hmem b hb_ms

/-- Every block `b ∈ blockIds` is either already mapped in `cur`, already in
`seen`, or included in `missingBlocksAux cur blockIds seen`. -/
theorem mem_missingBlocksAux (cur : Option Lease) (blockIds seen : List Nat)
    {b : Nat} (hb : b ∈ blockIds) :
    alreadyLeased cur b = true ∨
    seen.contains b = true ∨
    b ∈ missingBlocksAux cur blockIds seen := by
  induction blockIds generalizing seen with
  | nil => cases hb
  | cons hd tl ih =>
    simp only [missingBlocksAux]
    rcases List.mem_cons.mp hb with rfl | hb_tl
    · split
      · rename_i hcond
        rcases Bool.or_eq_true_iff.mp hcond with h1 | h2
        · exact Or.inl h1
        · exact Or.inr (Or.inl h2)
      · exact Or.inr (Or.inr List.mem_cons_self)
    · split
      · exact ih seen hb_tl
      · rcases ih (hd :: seen) hb_tl with h1 | h2 | h3
        · exact Or.inl h1
        · simp only [List.contains_cons, Bool.or_eq_true, beq_iff_eq] at h2
          rcases h2 with rfl | h2
          · exact Or.inr (Or.inr List.mem_cons_self)
          · exact Or.inr (Or.inl h2)
        · exact Or.inr (Or.inr (List.mem_cons_of_mem hd h3))

/-- **Postcondition of `acquireLease` (`KVCacheManagerBase::AcquirePoolStagingLease`)**:
Whenever `a.acquireLease uuid blockIds = some a'`, every `b ∈ blockIds`
resolves to `some slot` under `a'.resolveBlockSlot uuid b`. -/
theorem acquireLease_resolves_all {a a' : Arena} {uuid : Nat} {blockIds : List Nat}
    (hacq : a.acquireLease uuid blockIds = some a')
    {b : Nat} (hb : b ∈ blockIds) :
    (a'.resolveBlockSlot uuid b).isSome = true := by
  have hcov := mem_missingBlocksAux (a.lookupLease uuid) blockIds [] hb
  dsimp only [Arena.acquireLease] at hacq
  split at hacq
  · rename_i hempty
    injection hacq with h; subst h
    have hnil : missingBlocks (a.lookupLease uuid) blockIds = [] :=
      List.isEmpty_iff.mp hempty
    unfold missingBlocks at hnil
    rw [hnil] at hcov
    rcases hcov with hcur | hseen | hmem
    · unfold Arena.resolveBlockSlot alreadyLeased at *
      cases hopt : a.lookupLease uuid with
      | none => simp [hopt] at hcur
      | some l => simp [hopt] at hcur ⊢; exact hcur
    · simp at hseen
    · cases hmem
  · split at hacq
    · cases hacq
    · cases halloc : allocateMissing (missingBlocks (a.lookupLease uuid) blockIds)
          a.freeSlots ((a.lookupLease uuid).getD ⟨[], []⟩) with
      | none => simp [halloc] at hacq
      | some pair =>
        rcases pair with ⟨free', lease'⟩
        simp only [halloc, Option.some.injEq] at hacq
        subst hacq
        obtain ⟨hpres, hmem⟩ := allocateMissing_covers halloc
        unfold Arena.resolveBlockSlot Arena.lookupLease
        rw [lookupLease_upsert_self]
        rcases hcov with hcur | hseen | hmiss
        · apply hpres
          unfold alreadyLeased at hcur
          cases hopt : a.lookupLease uuid with
          | none => simp [hopt] at hcur
          | some l => simp [hopt] at hcur ⊢; exact hcur
        · simp at hseen
        · exact hmem b hmiss

/-- Inductive invariant for `RegState.sys .reserveBeforeLease numSlots`:
1. Every active session `(uuid, blocks) ∈ s.activeSessions` resolves every
   `b ∈ blocks` to an allocated staging slot.
2. Every in-flight arm that has completed Phase 2 (`leasedInPhase2 = true`)
   resolves every `b ∈ arm.blocks` to an allocated staging slot.
3. No in-flight arm shares a `uuid` with any active session.
4. Any two in-flight arms with the same `uuid` have the same `callId`.
5. Any two in-flight arms with the same `callId` have the same `uuid` and
   `blocks`. -/
structure ReserveBeforeLeaseInv (s : RegState) : Prop where
  activeValid :
    ∀ p ∈ s.activeSessions, ∀ b ∈ p.2,
      (s.arena.resolveBlockSlot p.1 b).isSome = true
  leasedArmsValid :
    ∀ arm ∈ s.inFlightArms, arm.leasedInPhase2 = true →
      ∀ b ∈ arm.blocks, (s.arena.resolveBlockSlot arm.uuid b).isSome = true
  activeDisjointArms :
    ∀ p ∈ s.activeSessions, ∀ arm ∈ s.inFlightArms, arm.uuid ≠ p.1
  armsSameUuidSameCall :
    ∀ a₁ ∈ s.inFlightArms, ∀ a₂ ∈ s.inFlightArms,
      a₁.uuid = a₂.uuid → a₁.callId = a₂.callId
  armsSameCallSameSpec :
    ∀ a₁ ∈ s.inFlightArms, ∀ a₂ ∈ s.inFlightArms,
      a₁.callId = a₂.callId → a₁.uuid = a₂.uuid ∧ a₁.blocks = a₂.blocks

theorem init_reserveBeforeLease_inv (numSlots : Nat) :
    ReserveBeforeLeaseInv (RegState.init numSlots) where
  activeValid := by intro p hp; cases hp
  leasedArmsValid := by intro arm harm; cases harm
  activeDisjointArms := by intro p hp; cases hp
  armsSameUuidSameCall := by intro a₁ ha₁; cases ha₁
  armsSameCallSameSpec := by intro a₁ ha₁; cases ha₁

theorem findArm_mem_and_callId {s : RegState} {callId : Nat} {arm : InFlightArm}
    (h : s.findArm callId = some arm) :
    arm ∈ s.inFlightArms ∧ arm.callId = callId := by
  unfold RegState.findArm at h
  refine ⟨List.mem_of_find?_eq_some h, ?_⟩
  have := List.find?_some h
  simpa using this

theorem not_findArm_isSome {s : RegState} {callId : Nat}
    (h : (s.findArm callId).isSome = false) :
    ∀ a ∈ s.inFlightArms, a.callId ≠ callId := by
  unfold RegState.findArm at h
  intro a ha heq
  cases hfind : s.inFlightArms.find? (fun x => x.callId == callId) with
  | none =>
    have := List.find?_eq_none.mp hfind a ha
    simp [heq] at this
  | some x =>
    simp [hfind] at h

theorem mem_removeArm_iff {s : RegState} {callId : Nat} {a : InFlightArm} :
    a ∈ s.removeArm callId ↔ a ∈ s.inFlightArms ∧ a.callId ≠ callId := by
  unfold RegState.removeArm
  simp [List.mem_filter, bne_iff_ne]

theorem not_hasInFlightUuid_of_false {s : RegState} {uuid : Nat}
    (h : s.hasInFlightUuid uuid = false) :
    ∀ a ∈ s.inFlightArms, a.uuid ≠ uuid := by
  unfold RegState.hasInFlightUuid at h
  intro a ha heq
  have : s.inFlightArms.any (fun x => x.uuid == uuid) = true :=
    List.any_eq_true.mpr ⟨a, ha, beq_iff_eq.mpr heq⟩
  rw [h] at this
  cases this

theorem step_reserveBeforeLease_inv {s s' : RegState} {e : RegEv}
    (hinv : ReserveBeforeLeaseInv s)
    (hstep : RegState.step .reserveBeforeLease s e = some s') :
    ReserveBeforeLeaseInv s' := by
  cases e with
  | beginArm callId uuid blocks =>
    dsimp only [RegState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hno_call
    split at hstep
    · cases hstep
    rename_i hno_act
    split at hstep
    · cases hstep
    rename_i hno_flt
    injection hstep with hs'; subst hs'
    simp only [beq_self_eq_true, Bool.true_and, Bool.not_eq_true] at hno_call hno_act hno_flt
    have hcid_ne : ∀ a ∈ s.inFlightArms, a.callId ≠ callId :=
      not_findArm_isSome hno_call
    have hact_ne : ∀ p ∈ s.activeSessions, p.1 ≠ uuid := by
      intro p hp heq
      have : s.hasActiveUuid uuid = true :=
        List.any_eq_true.mpr ⟨p, hp, beq_iff_eq.mpr heq⟩
      rw [hno_act] at this; cases this
    have hflt_ne : ∀ a ∈ s.inFlightArms, a.uuid ≠ uuid :=
      not_hasInFlightUuid_of_false hno_flt
    refine ⟨hinv.activeValid, ?_, ?_, ?_, ?_⟩
    · intro arm harm hleased
      rcases List.mem_append.mp harm with harm | harm
      · exact hinv.leasedArmsValid arm harm hleased
      · rcases List.mem_singleton.mp harm with rfl
        cases hleased
    · intro p hp arm harm
      rcases List.mem_append.mp harm with harm | harm
      · exact hinv.activeDisjointArms p hp arm harm
      · rcases List.mem_singleton.mp harm with rfl
        exact Ne.symm (hact_ne p hp)
    · intro a₁ ha₁ a₂ ha₂ hu
      rcases List.mem_append.mp ha₁ with ha₁ | ha₁ <;>
        rcases List.mem_append.mp ha₂ with ha₂ | ha₂
      · exact hinv.armsSameUuidSameCall a₁ ha₁ a₂ ha₂ hu
      · rcases List.mem_singleton.mp ha₂ with rfl
        exact absurd hu (hflt_ne a₁ ha₁)
      · rcases List.mem_singleton.mp ha₁ with rfl
        exact absurd hu.symm (hflt_ne a₂ ha₂)
      · rcases List.mem_singleton.mp ha₁ with rfl
        rcases List.mem_singleton.mp ha₂ with rfl
        rfl
    · intro a₁ ha₁ a₂ ha₂ hcid
      rcases List.mem_append.mp ha₁ with ha₁ | ha₁ <;>
        rcases List.mem_append.mp ha₂ with ha₂ | ha₂
      · exact hinv.armsSameCallSameSpec a₁ ha₁ a₂ ha₂ hcid
      · rcases List.mem_singleton.mp ha₂ with rfl
        exact absurd hcid (hcid_ne a₁ ha₁)
      · rcases List.mem_singleton.mp ha₁ with rfl
        exact absurd hcid.symm (hcid_ne a₂ ha₂)
      · rcases List.mem_singleton.mp ha₁ with rfl
        rcases List.mem_singleton.mp ha₂ with rfl
        exact ⟨rfl, rfl⟩
  | acquireArmLease callId =>
    dsimp only [RegState.step] at hstep
    cases hfind : s.findArm callId with
    | none => simp [hfind] at hstep
    | some arm =>
      simp only [hfind] at hstep
      obtain ⟨harm_mem, harm_cid⟩ := findArm_mem_and_callId hfind
      split at hstep
      · cases hstep
      cases hacq : s.arena.acquireLease arm.uuid arm.blocks with
      | none =>
        simp only [hacq, Option.some.injEq] at hstep
        subst hstep
        refine ⟨?_, ?_, ?_, ?_, ?_⟩
        · intro p hp b hb
          have hne : p.1 ≠ arm.uuid := Ne.symm (hinv.activeDisjointArms p hp arm harm_mem)
          rw [releaseLease_preserves_other_resolve s.arena hne]
          exact hinv.activeValid p hp b hb
        · intro a ha hleased b hb
          obtain ⟨ha_mem, ha_ne⟩ := mem_removeArm_iff.mp ha
          have hu_ne : a.uuid ≠ arm.uuid := by
            intro heq
            exact ha_ne (by rw [hinv.armsSameUuidSameCall a ha_mem arm harm_mem heq, harm_cid])
          rw [releaseLease_preserves_other_resolve s.arena hu_ne]
          exact hinv.leasedArmsValid a ha_mem hleased b hb
        · intro p hp a ha
          exact hinv.activeDisjointArms p hp a (mem_removeArm_iff.mp ha).1
        · intro a₁ ha₁ a₂ ha₂ hu
          exact hinv.armsSameUuidSameCall
            a₁ (mem_removeArm_iff.mp ha₁).1 a₂ (mem_removeArm_iff.mp ha₂).1 hu
        · intro a₁ ha₁ a₂ ha₂ hc
          exact hinv.armsSameCallSameSpec
            a₁ (mem_removeArm_iff.mp ha₁).1 a₂ (mem_removeArm_iff.mp ha₂).1 hc
      | some arena' =>
        simp only [hacq, Option.some.injEq] at hstep
        subst hstep
        have hmap_fields : ∀ a' ∈ s.inFlightArms.map (fun a =>
            if a.callId == callId then { a with leasedInPhase2 := true } else a),
            ∃ a ∈ s.inFlightArms,
              a'.callId = a.callId ∧ a'.uuid = a.uuid ∧ a'.blocks = a.blocks ∧
              (a.callId = callId ∨ a' = a) := by
          intro a' ha'
          rcases List.mem_map.mp ha' with ⟨a, ha_mem, ha_eq⟩
          refine ⟨a, ha_mem, ?_⟩
          by_cases hc : a.callId = callId
          · have hbeq : (a.callId == callId) = true := beq_iff_eq.mpr hc
            simp only [hbeq, ↓reduceIte] at ha_eq
            subst ha_eq
            exact ⟨rfl, rfl, rfl, Or.inl hc⟩
          · have hbeq : (a.callId == callId) = false := beq_eq_false_iff_ne.mpr hc
            simp only [hbeq, Bool.false_eq_true, ↓reduceIte] at ha_eq
            subst ha_eq
            exact ⟨rfl, rfl, rfl, Or.inr rfl⟩
        refine ⟨?_, ?_, ?_, ?_, ?_⟩
        · intro p hp b hb
          have hne : p.1 ≠ arm.uuid := Ne.symm (hinv.activeDisjointArms p hp arm harm_mem)
          rw [acquireLease_preserves_other_resolve hacq hne]
          exact hinv.activeValid p hp b hb
        · intro a' ha' hleased b hb
          obtain ⟨a, ha_mem, hcid_eq, hu_eq, hblk_eq, hcases⟩ := hmap_fields a' ha'
          rcases hcases with hc | rfl
          · have ⟨hu_arm, hblk_arm⟩ :=
              hinv.armsSameCallSameSpec a ha_mem arm harm_mem (hc.trans harm_cid.symm)
            rw [hu_eq, hu_arm]
            rw [hblk_eq, hblk_arm] at hb
            exact acquireLease_resolves_all hacq hb
          · by_cases hu : a'.uuid = arm.uuid
            · have hc := hinv.armsSameUuidSameCall a' ha_mem arm harm_mem hu
              have ⟨hu_arm, hblk_arm⟩ :=
                hinv.armsSameCallSameSpec a' ha_mem arm harm_mem hc
              rw [hu_arm]
              rw [hblk_arm] at hb
              exact acquireLease_resolves_all hacq hb
            · rw [acquireLease_preserves_other_resolve hacq hu]
              exact hinv.leasedArmsValid a' ha_mem hleased b hb
        · intro p hp a' ha'
          obtain ⟨a, ha_mem, _, hu_eq, _, _⟩ := hmap_fields a' ha'
          rw [hu_eq]
          exact hinv.activeDisjointArms p hp a ha_mem
        · intro a₁ ha₁ a₂ ha₂ hu
          obtain ⟨x₁, hx₁, hc₁, hu₁, _, _⟩ := hmap_fields a₁ ha₁
          obtain ⟨x₂, hx₂, hc₂, hu₂, _, _⟩ := hmap_fields a₂ ha₂
          rw [hc₁, hc₂]
          exact hinv.armsSameUuidSameCall x₁ hx₁ x₂ hx₂ (by omega)
        · intro a₁ ha₁ a₂ ha₂ hc
          obtain ⟨x₁, hx₁, hc₁, hu₁, hb₁, _⟩ := hmap_fields a₁ ha₁
          obtain ⟨x₂, hx₂, hc₂, hu₂, hb₂, _⟩ := hmap_fields a₂ ha₂
          rw [hu₁, hu₂, hb₁, hb₂]
          exact hinv.armsSameCallSameSpec x₁ hx₁ x₂ hx₂ (by omega)
  | finishArm callId =>
    dsimp only [RegState.step] at hstep
    cases hfind : s.findArm callId with
    | none => simp [hfind] at hstep
    | some arm =>
      simp only [hfind] at hstep
      obtain ⟨harm_mem, harm_cid⟩ := findArm_mem_and_callId hfind
      split at hstep
      · cases hstep
      rename_i hnot_unleased
      have hleased : arm.leasedInPhase2 = true := by
        cases h : arm.leasedInPhase2 <;> simp [h] at hnot_unleased <;> rfl
      split at hstep
      · rename_i hact_true
        unfold RegState.hasActiveUuid at hact_true
        obtain ⟨p, hp, hp_eq⟩ := List.any_eq_true.mp hact_true
        have hu_eq : p.1 = arm.uuid := beq_iff_eq.mp hp_eq
        exact absurd hu_eq.symm (hinv.activeDisjointArms p hp arm harm_mem)
      · injection hstep with hs'; subst hs'
        refine ⟨?_, ?_, ?_, ?_, ?_⟩
        · intro p hp b hb
          rcases List.mem_append.mp hp with hp | hp
          · exact hinv.activeValid p hp b hb
          · rcases List.mem_singleton.mp hp with rfl
            exact hinv.leasedArmsValid arm harm_mem hleased b hb
        · intro a ha hleased_a b hb
          exact hinv.leasedArmsValid a (mem_removeArm_iff.mp ha).1 hleased_a b hb
        · intro p hp a ha
          obtain ⟨ha_mem, ha_ne⟩ := mem_removeArm_iff.mp ha
          rcases List.mem_append.mp hp with hp | hp
          · exact hinv.activeDisjointArms p hp a ha_mem
          · rcases List.mem_singleton.mp hp with rfl
            intro heq
            exact ha_ne (by rw [hinv.armsSameUuidSameCall a ha_mem arm harm_mem heq, harm_cid])
        · intro a₁ ha₁ a₂ ha₂ hu
          exact hinv.armsSameUuidSameCall
            a₁ (mem_removeArm_iff.mp ha₁).1 a₂ (mem_removeArm_iff.mp ha₂).1 hu
        · intro a₁ ha₁ a₂ ha₂ hc
          exact hinv.armsSameCallSameSpec
            a₁ (mem_removeArm_iff.mp ha₁).1 a₂ (mem_removeArm_iff.mp ha₂).1 hc
  | settleSession uuid =>
    dsimp only [RegState.step] at hstep
    split at hstep
    · cases hstep
    split at hstep
    · cases hstep
    rename_i hno_flt
    injection hstep with hs'; subst hs'
    simp only [beq_self_eq_true, Bool.true_and, Bool.not_eq_true] at hno_flt
    have hflt_ne : ∀ a ∈ s.inFlightArms, a.uuid ≠ uuid :=
      not_hasInFlightUuid_of_false hno_flt
    refine ⟨?_, ?_, ?_, hinv.armsSameUuidSameCall, hinv.armsSameCallSameSpec⟩
    · intro p hp b hb
      simp only [List.mem_filter, bne_iff_ne] at hp
      rw [releaseLease_preserves_other_resolve s.arena hp.2]
      exact hinv.activeValid p hp.1 b hb
    · intro a ha hleased b hb
      rw [releaseLease_preserves_other_resolve s.arena (hflt_ne a ha)]
      exact hinv.leasedArmsValid a ha hleased b hb
    · intro p hp a ha
      simp only [List.mem_filter, bne_iff_ne] at hp
      exact hinv.activeDisjointArms p hp.1 a ha

theorem reachable_reserveBeforeLease_inv {numSlots : Nat} {s : RegState}
    (hr : (RegState.sys .reserveBeforeLease numSlots).Reachable s) :
    ReserveBeforeLeaseInv s := by
  induction hr with
  | init => exact init_reserveBeforeLease_inv numSlots
  | step _ hstep ih => exact step_reserveBeforeLease_inv ih hstep

/-- **Inductive Safety Theorem for `reserveBeforeLease`**:
In every reachable state of `RegState.sys .reserveBeforeLease numSlots`,
`ActiveSessionsHoldLeases s = true`: every registered active receive session
holds a live lease in `PoolStagingStorage` covering all of its destination
blocks. -/
theorem reachable_reserveBeforeLease_safe {numSlots : Nat} {s : RegState}
    (hr : (RegState.sys .reserveBeforeLease numSlots).Reachable s) :
    ActiveSessionsHoldLeases s = true := by
  have hinv := reachable_reserveBeforeLease_inv hr
  unfold ActiveSessionsHoldLeases
  rw [List.all_eq_true]
  intro ⟨uuid, blocks⟩ hp
  rw [List.all_eq_true]
  intro b hb
  exact hinv.activeValid (uuid, blocks) hp b hb

/-! ## Part V — Concrete `decide` Traces (`pool_staging_test.cc` Parity) and Mutants -/

structure BoundedScenarioSummary where
  freeAfterA2 : Nat
  slot5 : Option Nat
  slot9 : Option Nat
  slot11 : Option Nat
  slot4 : Option Nat
  uuid8WhileFull : Bool
  uuid9TooLarge : Bool
  freeAfterRelease : Nat
  freeAfterUuid8 : Nat
  uuid8Slot1 : Option Nat
  uuid8Slot2 : Option Nat
  deriving DecidableEq, Repr

/-- Helper executing the `PoolStagingTest.BoundedArenaLeasesAndAddressing` scenario. -/
def runBoundedArenaScenario : Option BoundedScenarioSummary :=
  match (Arena.init 4).acquireLease 7 [5, 9] with
  | none => none
  | some a1 =>
    match a1.acquireLease 7 [9, 11] with
    | none => none
    | some a2 =>
      let a3 := a2.releaseLease 7
      match a3.acquireLease 8 [1, 2] with
      | none => none
      | some a4 =>
        some { freeAfterA2 := a2.freeSlots.length
             , slot5 := a2.resolveBlockSlot 7 5
             , slot9 := a2.resolveBlockSlot 7 9
             , slot11 := a2.resolveBlockSlot 7 11
             , slot4 := a2.resolveBlockSlot 7 4
             , uuid8WhileFull := (a2.acquireLease 8 [1, 2]).isNone
             , uuid9TooLarge := (a2.acquireLease 9 [1, 2, 3, 4, 6]).isNone
             , freeAfterRelease := a3.freeSlots.length
             , freeAfterUuid8 := a4.freeSlots.length
             , uuid8Slot1 := a4.resolveBlockSlot 8 1
             , uuid8Slot2 := a4.resolveBlockSlot 8 2 }

/-- Replay of `PoolStagingTest.BoundedArenaLeasesAndAddressing`:
1. 4-slot bounded arena (`Arena.init 4`).
2. `uuid = 7` leases blocks `[5, 9]` → mapped to slots `0` and `1` (2 free slots).
3. `uuid = 7` re-leases `[9, 11]` → block `9` stays at slot `1` (idempotent),
   block `11` takes slot `2` (1 free slot left).
4. Unleased block `4` resolves to `none`.
5. `uuid = 8` requesting `[1, 2]` (2 slots > 1 free) fails (`none`,
   `ResourceExhausted`).
6. `uuid = 9` requesting 5 blocks `[1, 2, 3, 4, 6]` (> 4 total slots) fails
   (`none`, `ResourceExhausted`).
7. Releasing `uuid = 7` returns all 3 leased slots (`[2, 1, 0, 3]`, 4 free slots),
   after which `uuid = 8` requesting `[1, 2]` succeeds with 2 free slots remaining. -/
theorem trace_bounded_arena_leases_and_addressing :
    runBoundedArenaScenario =
      some ⟨1, some 0, some 1, some 2, none, true, true, 4, 2, some 2, some 1⟩ := by
  decide

/-- Replay of `PoolStagingTest.SmallPoolIdentitySharedStorageAndStrideMismatch`:
Two pools (`gdn.conv` and `gdn.ssm`) sharing storage 0 acquire leases under the
same `uuid = 42` for overlapping block sets `[10, 20]` and `[10, 20]`. Because
`AcquirePoolStagingLease` is idempotent per `uuid`, the second pool's call
consumes 0 additional slots and shares the exact same page-slot mapping. -/
theorem trace_shared_storage_pools_share_lease :
    ((Arena.init 3).acquireLease 42 [10, 20]).map
      (fun a1 =>
        ( a1.acquireLease 42 [10, 20] == some a1
        , a1.freeSlots.length
        , a1.resolveBlockSlot 42 10
        , a1.resolveBlockSlot 42 20 )) =
      some (true, 1, some 0, some 1) := by
  decide

/-- Bounded vs. full-mirror storage configuration
(`KVCacheManagerBase::ConfigurePoolStaging` in `base.cc`):
allocates a bounded arena of `blocksPerLease * leases` slots (`some numSlots`)
if and only if `0 < blocksPerLease`, `0 < leases`, all pools sharing the
storage have equal `block_stride_bytes` (`stridesEqual`), and
`blocksPerLease * leases < maxPoolBlocks`; otherwise falls back to full-mirror
identity addressing (`none`). -/
def configureStorageBounded (blocksPerLease leases maxPoolBlocks : Nat)
    (stridesEqual : Bool) : Option Nat :=
  let numSlots := blocksPerLease * leases
  if 0 < blocksPerLease && 0 < leases && stridesEqual && numSlots < maxPoolBlocks then
    some numSlots
  else
    none

/-- Reported staging capacity (`KVCacheManagerBase::PoolHostBaseAddrs`,
`PoolStagingTest.PoolHostBaseAddrs`):
returns `numSlots` when the pool's storage is bounded and `maxPoolBlocks` on a
full-mirror storage. -/
def poolStagingCapacity (maxPoolBlocks : Nat) (boundedSlots : Option Nat) : Nat :=
  boundedSlots.getD maxPoolBlocks

/-- Remote address (`raddr`) resolution on sender `KVCacheManagerBase::GetBlockChunks`
(`RemoteAddress`) vs. receiver `KVCacheManagerBase::PoolBlockHostBase`
(`PoolStagingTest.SenderRaddrMatchesReceiverPointer`,
`PoolStagingTest.SenderRaddrUsesReceiverLeaseSlot`):
- On full-mirror storage (`arena = none`), `dstBlock < numBlocks` resolves to
  `some (baseAddr + dstBlock * stride + dstOffset)` (identity slot).
- On bounded storage (`arena = some a`), `dstBlock` is translated through
  `a.resolveBlockSlot uuid dstBlock` (`slot * stride + dstOffset`), returning
  `none` if `uuid` has no lease for `dstBlock`. -/
def resolveRemoteAddr (baseAddr stride numBlocks : Nat) (arena : Option Arena)
    (uuid dstBlock dstOffset : Nat) : Option Nat :=
  if dstBlock ≥ numBlocks then none
  else
    match arena with
    | none => some (baseAddr + dstBlock * stride + dstOffset)
    | some a =>
      (a.resolveBlockSlot uuid dstBlock).map (fun slot => baseAddr + slot * stride + dstOffset)

/-- Replay of `PoolStagingTest.FallsBackToFullMirrorWithoutHintsOrLeases` and
`PoolStagingTest.SmallPoolIdentitySharedStorageAndStrideMismatch`:
1. Zero hints (`blocks = 0, leases = 0, maxBlocks = 16`) or zero
   leases (`blocks = 2, leases = 0, maxBlocks = 16`) falls back to
   full mirror (`none`).
2. Small pool (`blocks = 2, leases = 2, maxBlocks = 3`, `4 ≥ 3`)
   falls back to full mirror (`none`).
3. Shared storage with matching strides (`blocks = 3, leases = 1, maxBlocks = 64`)
   configures a bounded arena of `some 3` slots.
4. Shared storage with mismatched strides (`stridesEqual = false`)
   falls back to full mirror (`none`). -/
theorem trace_fallback_to_full_mirror_and_stride_mismatch :
    configureStorageBounded 0 0 16 true = none ∧
    configureStorageBounded 2 0 16 true = none ∧
    configureStorageBounded 2 2 3 true = none ∧
    configureStorageBounded 3 1 64 true = some 3 ∧
    configureStorageBounded 2 2 64 false = none := by
  decide

/-- Replay of `PoolStagingTest.SenderRaddrMatchesReceiverPointer`,
`PoolStagingTest.SenderRaddrUsesReceiverLeaseSlot`, and
`PoolStagingTest.PoolHostBaseAddrs`:
1. Full-mirror receiver (`baseAddr = 10000, stride = 64, numBlocks = 8`):
   `(dstBlock = 3, dstOffset = 0)` resolves to `10000 + 3 * 64 = 10192`,
   `(dstBlock = 3, dstOffset = 32)` to `10224`, and `(dstBlock = 5, dstOffset = 16)`
   to `10336`.
2. Bounded receiver (`baseAddr = 20000, stride = 64, numBlocks = 64, numSlots = 2`):
   `uuid = 99` leases `[7, 42]` (mapped to slots `0` and `1`), so
   `(dstBlock = 42, dstOffset = 32)` resolves to `20000 + 1 * 64 + 32 = 20096`
   (using slot `1`, not `42 * 64`), while unleased `dstBlock = 10`
   resolves to `none`.
3. `PoolStagingTest.PoolHostBaseAddrs`: full-mirror pool reports `num_blocks = 8`,
   while bounded pool (`2 * 2 = 4 < 64`) reports `num_blocks = 4`. -/
theorem trace_sender_raddr_and_pool_host_base_addrs :
    resolveRemoteAddr 10000 64 8 none 77 3 0 = some 10192 ∧
    resolveRemoteAddr 10000 64 8 none 77 3 32 = some 10224 ∧
    resolveRemoteAddr 10000 64 8 none 77 5 16 = some 10336 ∧
    (((Arena.init 2).acquireLease 99 [7, 42]).map
      (fun a =>
        ( resolveRemoteAddr 20000 64 64 (some a) 99 42 32
        , resolveRemoteAddr 20000 64 64 (some a) 99 10 0 )) =
      some (some 20096, none)) ∧
    poolStagingCapacity 8 (configureStorageBounded 0 0 8 true) = 8 ∧
    poolStagingCapacity 64 (configureStorageBounded 2 2 64 true) = 4 := by
  decide

/-- End-to-end trace under `RegistrationPolicy.reserveBeforeLease` showing two
sessions (`uuid = 7` and `uuid = 8`) arming, leasing disjoint slots, settling,
and recycling slots while preserving `ActiveSessionsHoldLeases`. -/
def reserveBeforeLeaseTrace : List RegEv :=
  [ .beginArm 1 7 [5, 9]
  , .acquireArmLease 1
  , .finishArm 1
  , .beginArm 2 8 [5, 12]
  , .acquireArmLease 2
  , .finishArm 2
  , .settleSession 7
  , .settleSession 8 ]

theorem trace_reserveBeforeLease_end_to_end :
    ((RegState.sys .reserveBeforeLease 4).run reserveBeforeLeaseTrace).map
      (fun s => (ActiveSessionsHoldLeases s, s.activeSessions, s.arena.freeSlots.length)) =
      some (true, [], 4) := by
  decide

/-- Replay of `PoolStagingRecvRegistrationTest.DuplicatePoolRecvRegistrationKeepsOriginalStagingLease`
and `PoolStagingRecvRegistrationTest.StagingAcquireFailureReleasesUuidClaim`:
1. `PoolStagingRecvRegistrationTest.DuplicatePoolRecvRegistrationKeepsOriginalStagingLease`: on a
   2-slot bounded arena, `uuid = 4001` arms `[0]` (taking slot `0`, 1 free slot
   left); a duplicate `beginArm 2 4001 [0]` is rejected (`none`,
   `AlreadyExistsError`) without touching `4001`'s lease, and `uuid = 4002`
   arming `[5]` receives slot `1` (`≠ slot 0`).
2. `PoolStagingRecvRegistrationTest.StagingAcquireFailureReleasesUuidClaim`: on a 2-slot bounded
   arena, an oversized registration for `uuid = 4001` (`blocks = [0, 1, 2]`)
   claims `4001` in Phase 1 (`beginArm 1 4001 [0, 1, 2]`), fails in Phase 2
   (`acquireArmLease 1`, `ResourceExhausted`), and rolls back the claim leaving
   `2` free slots and `inFlightArms = []`; a subsequent valid registration for
   the same `uuid = 4001` (`blocks = [0]`) then succeeds and takes slot `0`. -/
theorem trace_pool_staging_recv_registration_tests :
    let sys2 := RegState.sys .reserveBeforeLease 2
    let arm4001 := [.beginArm 1 4001 [0], .acquireArmLease 1, .finishArm 1]
    (sys2.run (arm4001 ++ [.beginArm 2 4001 [0]]) = none) ∧
    ((sys2.run (arm4001 ++ [.beginArm 3 4002 [5], .acquireArmLease 3, .finishArm 3])).map
      (fun s => (s.arena.resolveBlockSlot 4001 0, s.arena.resolveBlockSlot 4002 5,
                 ActiveSessionsHoldLeases s, s.arena.freeSlots.length)) =
      some (some 0, some 1, true, 0)) ∧
    ((sys2.run [.beginArm 1 4001 [0, 1, 2], .acquireArmLease 1]).map
      (fun s => (s.hasActiveUuid 4001, s.hasInFlightUuid 4001, s.arena.freeSlots.length)) =
      some (false, false, 2)) ∧
    ((sys2.run [.beginArm 1 4001 [0, 1, 2], .acquireArmLease 1,
                .beginArm 2 4001 [0], .acquireArmLease 2, .finishArm 2]).map
      (fun s => (s.hasActiveUuid 4001, s.arena.resolveBlockSlot 4001 0,
                 s.arena.freeSlots.length)) =
      some (true, some 0, 1)) := by
  decide

/-- Mutant 1: If `AcquirePoolStagingLease` did not deduplicate/skip blocks
already leased to the same `uuid` (`if (cur != nullptr && cur->slot_by_block.contains(block_id)) continue;` in `KVCacheManagerBase::AcquirePoolStagingLease`), two pools
sharing a 3-slot storage and each needing 2 blocks `[10, 20]` would require
`2 + 2 = 4 > 3` slots and fail with `ResourceExhausted`. -/
def acquireLeaseWithoutIdempotence (a : Arena) (uuid : Nat) (blockIds : List Nat) : Option Arena :=
  if blockIds.length > a.numSlots || a.freeSlots.length < blockIds.length then
    none
  else
    let baseLease := (a.lookupLease uuid).getD ⟨[], []⟩
    match allocateMissing blockIds a.freeSlots baseLease with
    | none => none
    | some (free', lease') =>
      some { a with
        freeSlots := free'
        leases := upsertLease a.leases uuid lease' }

theorem mutant_non_idempotent_acquire_exhausts_shared_storage :
    (acquireLeaseWithoutIdempotence (Arena.init 3) 42 [10, 20]).bind
      (fun a1 => acquireLeaseWithoutIdempotence a1 42 [10, 20]) = none := by
  decide

/-- Mutant 2: If `ReleasePoolStagingLeases` erased `uuid` from `leases` without
returning `lease.slots` to `free_slots` (`for (int32_t slot : it->second->slots) { st.free_slots.push_back(slot); }` in `KVCacheManagerBase::ReleasePoolStagingLeases`),
total slots would shrink and subsequent sessions would starve with
`ResourceExhausted`. -/
def releaseLeaseLeakingSlots (a : Arena) (uuid : Nat) : Arena :=
  { a with leases := a.leases.filter (fun p => p.1 != uuid) }

theorem mutant_leaking_release_breaks_conservation_and_starves :
    ((Arena.init 2).acquireLease 7 [5, 9]).map
      (fun a1 =>
        let a2 := releaseLeaseLeakingSlots a1 7
        (decide (a2.totalSlots < a2.numSlots), a2.acquireLease 8 [1])) =
      some (true, none) := by
  decide

/-- Candidate registration events over two call IDs (`1, 2`), two UUIDs (`7, 8`),
and block `[5]`. -/
def checkEvents : List RegEv :=
  [ .beginArm 1 7 [5], .acquireArmLease 1, .finishArm 1
  , .beginArm 2 7 [5], .acquireArmLease 2, .finishArm 2
  , .beginArm 2 8 [5]
  , .settleSession 7, .settleSession 8 ]

def violatesHoldLeases (s : RegState) : Bool :=
  !ActiveSessionsHoldLeases s || (s.arena.totalSlots != s.arena.numSlots)

#guard (match ModelCheck.check (RegState.sys .leaseBeforeReserve 2) checkEvents violatesHoldLeases 8 with
  | .counterexample _ => true | _ => false)

end TpuSyncVerify.Transfer.Reshard.PoolStaging
