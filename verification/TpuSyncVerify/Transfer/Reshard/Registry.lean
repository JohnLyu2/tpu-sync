import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Common.ListAux

/-!
# Request block registry generation lifecycle

Formal model and proofs of `RequestBlockRegistry`
(`tpu_sync/kv_cache/reshard/request_block_registry.{h,cc}`), the controller-side
state machine that manages `(req_id, uuid)` producer block generations across
registration, multi-owner planning claims, claim abandonment, per-unit
completion voting, and unclaimed cancellation tombstones.

Pinned to upstream commit `2ed6f8f`.

  ## C++ anchorage

  1. **Per-unit producer registration (`RequestBlockRegistry::Register`,
     `tpu_sync/kv_cache/reshard/request_block_registry.cc:118-300`):**
     Records `request_blocks_[(req_id, unit)]` with `uuid` and normalized
     `block_ids` / `pool_spans`. Rejects if:
     - `cancelled_` contains `(req_id, uuid)` (`:276-280`),
     - `claimed_` contains `(req_id, uuid)` (`:281-285`), or
     - `request_blocks_[(req_id, unit)]` already exists with a different payload
       (`:286-294`; identical re-registration is an idempotent TTL refresh,
       `:295-298`).

  2. **Claim linearization (`RequestBlockRegistry::LookupAndClaim`,
     `tpu_sync/kv_cache/reshard/request_block_registry.cc:440-491`):**
     Rejects if `cancelled_` contains `(req_id, uuid)` (`:448-452`), if
     `claimed_units_` already holds a different source unit set (`:454-460`), or
     if any requested `unit ∈ units` is missing from `request_blocks_` or has a
     different `uuid` (`:462-470`). Otherwise marks `claimed_[(req_id, uuid)]`,
     sets `claimed_units_[(req_id, uuid)] = units`, and inserts `claim_owner`
     into `claimed_owners_[(req_id, uuid)]` (`:473-475`). If all `units` have
     already voted in `completed_units_`, calls `RetireLocked` (`:476-489`).

  3. **Owner-scoped claim rollback (`RequestBlockRegistry::AbandonClaim`,
     `tpu_sync/kv_cache/reshard/request_block_registry.cc:493-509`):**
     Removes `claim_owner` from `claimed_owners_[(req_id, uuid)]`; only when
     `claimed_owners_` becomes empty does it erase `claimed_`, `claimed_units_`,
     and `claimed_owners_` (`:503-507`), allowing pipelined destination stages to
     share one source snapshot claim (`request_block_registry.h:144-147`).

  4. **Full-set completion voting (`RequestBlockRegistry::Complete`,
     `tpu_sync/kv_cache/reshard/request_block_registry.cc:317-371`):**
     Rejects pre-claim completion of a non-empty registration (`:335-341`).
     Otherwise inserts `unit` into `completed_units_[(req_id, uuid)].units`
     (`:356`), and when `claimed_units_` is present and every expected unit has
     voted (`all_voted`, `:358-368`), calls `RetireLocked` (`:98-116`) to erase
     all `request_blocks_` rows and lifecycle maps for `(req_id, uuid)`.

  5. **Cancellation tombstone (`RequestBlockRegistry::CancelIfUnclaimed`,
     `tpu_sync/kv_cache/reshard/request_block_registry.cc:373-405`):**
     Returns `true` immediately if already in `cancelled_` (`:385-387`), returns
     `false` without modifying state if `claimed_` contains `(req_id, uuid)`
     (`:388-390`), and otherwise records a tombstone in `cancelled_` while
     erasing any unclaimed `request_blocks_` and lifecycle entries (`:391-404`).

  6. **TTL expiration (`PurgeExpiredRequestBlocksLocked` /
     `PurgeExpiredLifecycleLocked`,
     `tpu_sync/kv_cache/reshard/request_block_registry.cc:61-96`):**
     Sweeps expired registrations, claims, and tombstones (Part V,
     `purgeExpiredAll_inv`, and Observations R7 & R8).

  ## Main results

  - `reachable_safe` (`Inv`): proves inductively across all reachable registry
    states that:
    1. `ClaimOwnersConsistent`: `claimedUnits.isSome ↔ claimOwners ≠ []`, and
       every claimed unit is registered in `registeredUnits`.
    2. `TombstoneClean` & `tombstone_blocks_register_and_claim`: when
       `cancelled = true`, `registeredUnits = []`, `claimedUnits = none`, and
       `claimOwners = []`, and any subsequent `register` or `lookupAndClaim`
       is rejected.
    3. `claimed_blocks_register_and_cancel`: while `claimedUnits = some units`,
       `register` is rejected and `cancelIfUnclaimed` cannot cancel or erase the
       registered producer blocks.
    4. `RetiredClean` & `PartialVotesNotAllVoted`: once `retired = true`,
       `registeredUnits = []`, `claimedUnits = none`, and `claimOwners = []`;
       while `claimedUnits = some expected`, `allVoted expected completedUnits = false`,
       and `Complete` retires the generation only when every unit in `claimedUnits`
       has voted (`complete_retires_iff_all_claimed_voted`).
  - `purgeExpiredAll_inv` & Observations R7 (`trace_r7_single_stage_votes_retire_multi_owner_claim`)
    and R8 (`trace_r8_split_ttl_purges_request_blocks_while_claim_active`).
-/

namespace TpuSyncVerify.Transfer.Reshard.Registry

open TpuSyncVerify

/-! ## Part I — Registry Generation State Machine (`RequestBlockRegistry`) -/

/--Read-only status returned by `RequestBlockRegistry::Status`
(`tpu_sync/kv_cache/reshard/request_block_registry.h:82-87`,
`tpu_sync/kv_cache/reshard/request_block_registry.cc:407-436`). -/
inductive BlockStatus where
  | unknown
  | registered
  | claimed
  | cancelled
  deriving DecidableEq, Repr

/-- Per-`(req_id, uuid)` lifecycle state in `RequestBlockRegistry`
(`tpu_sync/kv_cache/reshard/request_block_registry.h:139-150`). -/
structure RegGen where
  /-- Registered producer units `(unit, nonEmptyBlocks)` in `request_blocks_`
  for this `(req_id, uuid)` (`request_block_registry.cc:260-299`). -/
  registeredUnits : List (Nat × Bool)
  /-- Claimed source unit set `claimed_units_[(req_id, uuid)]` when `claimed_`
  is present (`request_block_registry.cc:473-474`). -/
  claimedUnits : Option (List Nat)
  /-- Active planning owners `claimed_owners_[(req_id, uuid)]`
  (`request_block_registry.h:144-148`, `request_block_registry.cc:475`). -/
  claimOwners : List Nat
  /-- Producer units that have cast a terminal vote in
  `completed_units_[(req_id, uuid)]` (`request_block_registry.cc:351-357`). -/
  completedUnits : List Nat
  /-- Whether `cancelled_` holds a tombstone for `(req_id, uuid)`
  (`request_block_registry.cc:385-391`). -/
  cancelled : Bool
  /-- Monotonic flag recording whether `RetireLocked` (`request_block_registry.cc:98-116`)
  has fired to retire the generation. -/
  retired : Bool
  deriving DecidableEq, Repr

/-- Initial empty state for a `(req_id, uuid)` generation. -/
def RegGen.init : RegGen :=
  { registeredUnits := []
  , claimedUnits := none
  , claimOwners := []
  , completedUnits := []
  , cancelled := false
  , retired := false }

/-- Look up `unit`'s registration (`request_blocks_.find({req_id, unit})`,
`tpu_sync/kv_cache/reshard/request_block_registry.cc:286, 333, 463`). -/
def RegGen.lookupUnit (s : RegGen) (unit : Nat) : Option Bool :=
  (s.registeredUnits.find? (fun p => p.1 == unit)).map Prod.snd

/-- `RequestBlockRegistry::Status` precedence:
`cancelled > claimed > registered > unknown`
(`tpu_sync/kv_cache/reshard/request_block_registry.cc:417-434`). -/
def RegGen.status (s : RegGen) : BlockStatus :=
  if s.cancelled then .cancelled
  else if s.claimedUnits.isSome then .claimed
  else if !s.registeredUnits.isEmpty then .registered
  else .unknown

/-- `RequestBlockRegistry::RetireLocked`
(`tpu_sync/kv_cache/reshard/request_block_registry.cc:98-116`):
erases `request_blocks_`, `claimed_`, `claimed_units_`, `claimed_owners_`,
`completed_units_`, and `cancelled_`. -/
def RegGen.retireLocked (_s : RegGen) : RegGen :=
  { registeredUnits := []
  , claimedUnits := none
  , claimOwners := []
  , completedUnits := []
  , cancelled := false
  , retired := true }

/-- Whether every unit in `expected` has voted in `completed`
(`all_voted`, `tpu_sync/kv_cache/reshard/request_block_registry.cc:359-365, 479-485`). -/
def allVoted (expected completed : List Nat) : Bool :=
  expected.all (fun u => completed.contains u)

/-- Insert `x` into `xs` if not already present (set semantics). -/
def insertNodup (x : Nat) (xs : List Nat) : List Nat :=
  if xs.contains x then xs else xs ++ [x]

/-- Whether `cur` is either unclaimed or already claimed for the exact same
source unit set `units` (`tpu_sync/kv_cache/reshard/request_block_registry.cc:454-460`). -/
def compatibleClaim (cur : Option (List Nat)) (units : List Nat) : Bool :=
  match cur with
  | none => true
  | some existing => existing == units

/-- Whether `unit` is in the claimed unit set `cur`
(`tpu_sync/kv_cache/reshard/request_block_registry.cc:344-345`). -/
def inClaimedUnits (cur : Option (List Nat)) (unit : Nat) : Bool :=
  match cur with
  | none => false
  | some expected => expected.contains unit

/-- Events of `RequestBlockRegistry` for a `(req_id, uuid)` generation. -/
inductive Ev where
  /-- `Register(req_id, uuid, unit, block_ids, pool_spans)`
  (`request_block_registry.cc:118-300`). -/
  | register (unit : Nat) (nonEmpty : Bool)
  /-- `LookupAndClaim(req_id, uuid, units, claim_owner)`
  (`request_block_registry.cc:440-491`). -/
  | lookupAndClaim (owner : Nat) (units : List Nat)
  /-- `AbandonClaim(req_id, uuid, claim_owner)`
  (`request_block_registry.cc:493-509`). -/
  | abandonClaim (owner : Nat)
  /-- `Complete(req_id, uuid, unit)`
  (`request_block_registry.cc:317-371`). -/
  | complete (unit : Nat)
  /-- `CancelIfUnclaimed(req_id, uuid)`
  (`request_block_registry.cc:373-405`). -/
  | cancelIfUnclaimed
  /-- `Release(req_id, uuid)` (`request_block_registry.cc:302-315`). -/
  | release
  deriving DecidableEq, Repr

/-- Transition function of `RequestBlockRegistry`
(`tpu_sync/kv_cache/reshard/request_block_registry.cc:98-509`). -/
def RegGen.step (s : RegGen) (e : Ev) : Option RegGen :=
  match e with
  | .register unit nonEmpty =>
    -- Rejects if cancelled (`:276-280`) or already claimed (`:281-285`), or if
    -- generation was already retired.
    if s.cancelled || s.claimedUnits.isSome || s.retired then
      none
    else
      match s.lookupUnit unit with
      | some curNonEmpty =>
        -- Conflicting payload is rejected (`:289-294`); identical payload is an
        -- idempotent refresh (`:295-298`).
        if curNonEmpty != nonEmpty then none else some s
      | none =>
        some { s with registeredUnits := s.registeredUnits ++ [(unit, nonEmpty)] }
  | .lookupAndClaim owner units =>
    if s.cancelled || units.isEmpty then
      none
    else if !compatibleClaim s.claimedUnits units then
      -- `:454-460`: already claimed for a different source unit set.
      none
    else if !units.all (fun u => (s.lookupUnit u).isSome) then
      -- `:462-470`: missing producer block registration for a requested unit.
      none
    else
      let owners' := insertNodup owner s.claimOwners
      if allVoted units s.completedUnits then
        -- `:476-489`: all claimed units had already voted (e.g. empty blocks).
        some s.retireLocked
      else
        some { s with
          claimedUnits := some units
          claimOwners := owners' }
  | .abandonClaim owner =>
    if !s.claimOwners.contains owner then
      none
    else
      let owners' := s.claimOwners.filter (fun o => o != owner)
      if owners'.isEmpty then
        -- `:503-507`: last owner abandoned; drop claim.
        some { s with
          claimedUnits := none
          claimOwners := [] }
      else
        some { s with claimOwners := owners' }
  | .complete unit =>
    let regOpt := s.lookupUnit unit
    let hasExpected := s.claimedUnits.isSome
    -- `:335-341`: non-empty producer registration cannot complete before claim.
    if !hasExpected && regOpt == some true then
      none
    else if regOpt.isNone && !inClaimedUnits s.claimedUnits unit then
      -- `:346-350`: idempotent no-op after retirement or for unknown unit.
      some s
    else
      let completed' := insertNodup unit s.completedUnits
      match s.claimedUnits with
      | some expected =>
        if allVoted expected completed' then
          -- `:358-368`: full claimed set has voted -> RetireLocked.
          some s.retireLocked
        else
          some { s with completedUnits := completed' }
      | none =>
        some { s with completedUnits := completed' }
  | .cancelIfUnclaimed =>
    if s.cancelled then
      -- `:385-387`: already cancelled -> returns true (idempotent).
      some s
    else if s.claimedUnits.isSome then
      -- `:388-390`: already claimed -> returns false without modifying state.
      some s
    else
      -- `:391-404`: record tombstone and erase unclaimed registrations.
      some { s with
        registeredUnits := []
        claimedUnits := none
        claimOwners := []
        completedUnits := []
        cancelled := true }
  | .release =>
    some s.retireLocked

def RegGen.sys : System RegGen Ev where
  init := RegGen.init
  step := RegGen.step

/-! ## Part II — Core Safety Predicates and Inductive Invariant -/

/-- **Safety Property 1 (`ClaimOwnersConsistent`,
`request_block_registry.cc:473-475, 503-507`)**:
`claimedUnits` is `some units` if and only if `claimOwners` is non-empty, and
every unit in `units` is registered in `registeredUnits`. -/
def ClaimOwnersConsistent (s : RegGen) : Prop :=
  (s.claimedUnits.isSome = !s.claimOwners.isEmpty) ∧
  ∀ units, s.claimedUnits = some units →
    units ≠ [] ∧ ∀ u ∈ units, (s.lookupUnit u).isSome = true

/-- **Safety Property 2 (`TombstoneClean`,
`request_block_registry.cc:276-280, 391-404, 448-452`)**:
Whenever `s.cancelled = true`, all registration and claim tables are empty
(`registeredUnits = []`, `claimedUnits = none`, `claimOwners = []`,
`completedUnits = []`). -/
def TombstoneClean (s : RegGen) : Prop :=
  s.cancelled = true →
    s.registeredUnits = [] ∧
    s.claimedUnits = none ∧
    s.claimOwners = [] ∧
    s.completedUnits = []

/-- **Safety Property 3 (`RetiredClean`,
`request_block_registry.cc:98-116`)**:
Whenever `s.retired = true`, `registeredUnits = []` and `claimedUnits = none`
and `claimOwners = []`. -/
def RetiredClean (s : RegGen) : Prop :=
  s.retired = true →
    s.registeredUnits = [] ∧
    s.claimedUnits = none ∧
    s.claimOwners = []

/-- **Safety Property 4 (`PartialVotesNotAllVoted`,
`request_block_registry.cc:358-368, 479-488`)**:
While a claim `s.claimedUnits = some expected` is active (not yet retired),
`allVoted expected s.completedUnits = false`. -/
def PartialVotesNotAllVoted (s : RegGen) : Prop :=
  ∀ expected, s.claimedUnits = some expected →
    allVoted expected s.completedUnits = false

/-- Combined inductive invariant of `RegGen`. -/
structure Inv (s : RegGen) : Prop where
  claimConsistent : ClaimOwnersConsistent s
  tombstoneClean : TombstoneClean s
  retiredClean : RetiredClean s
  partialVotes : PartialVotesNotAllVoted s

theorem init_inv : Inv RegGen.init where
  claimConsistent := ⟨rfl, by intro units h; cases h⟩
  tombstoneClean := by intro h; cases h
  retiredClean := by intro h; cases h
  partialVotes := by intro expected h; cases h

theorem retireLocked_inv (s : RegGen) : Inv s.retireLocked where
  claimConsistent := ⟨rfl, by intro units h; cases h⟩
  tombstoneClean := by intro h; cases h
  retiredClean := by intro _; exact ⟨rfl, rfl, rfl⟩
  partialVotes := by intro expected h; cases h

theorem insertNodup_nonEmpty (x : Nat) (xs : List Nat) :
    (insertNodup x xs).isEmpty = false := by
  unfold insertNodup
  split
  · rename_i h
    cases xs with
    | nil => simp at h
    | cons _ _ => rfl
  · simp

theorem step_preserves_inv {s s' : RegGen} {e : Ev}
    (hinv : Inv s) (hstep : RegGen.step s e = some s') :
    Inv s' := by
  cases e with
  | register unit nonEmpty =>
    dsimp only [RegGen.step] at hstep
    split at hstep
    · cases hstep
    rename_i hflags
    simp only [Bool.or_eq_true, not_or, Bool.not_eq_true] at hflags
    obtain ⟨⟨hcanc, hclaim⟩, hret⟩ := hflags
    cases hlook : s.lookupUnit unit with
    | some cur =>
      simp only [hlook] at hstep
      split at hstep
      · cases hstep
      · injection hstep with h; subst h; exact hinv
    | none =>
      simp only [hlook, Option.some.injEq] at hstep
      subst hstep
      have hclaim_none : s.claimedUnits = none := by
        cases h : s.claimedUnits <;> simp_all
      have howners_empty : s.claimOwners.isEmpty = true := by
        have h := hinv.claimConsistent.1
        rw [hclaim_none] at h
        cases h1 : s.claimOwners.isEmpty with
        | true => rfl
        | false => simp [h1] at h
      refine ⟨⟨?_, ?_⟩, ?_, ?_, ?_⟩
      · simp [hclaim_none, howners_empty]
      · intro units h; simp [hclaim_none] at h
      · intro h; simp [hcanc] at h
      · intro h; simp [hret] at h
      · intro expected h; simp [hclaim_none] at h
  | lookupAndClaim owner units =>
    dsimp only [RegGen.step] at hstep
    split at hstep
    · cases hstep
    rename_i h1
    simp only [Bool.or_eq_true, not_or, Bool.not_eq_true] at h1
    obtain ⟨hcanc, hunits_ne⟩ := h1
    split at hstep
    · cases hstep
    split at hstep
    · cases hstep
    rename_i hall_reg
    simp only [Bool.not_eq_true, Bool.not_eq_false'] at hall_reg
    split at hstep
    · injection hstep with h; subst h
      exact retireLocked_inv s
    · rename_i hnot_voted
      injection hstep with h; subst h
      simp only [Bool.not_eq_true] at hnot_voted
      refine ⟨⟨?_, ?_⟩, ?_, ?_, ?_⟩
      · simp [insertNodup_nonEmpty]
      · intro u' hu'
        injection hu' with hu'; subst hu'
        refine ⟨List.isEmpty_eq_false_iff.mp hunits_ne, ?_⟩
        exact List.all_eq_true.mp hall_reg
      · intro h; simp [hcanc] at h
      · intro hret
        have hreg_empty := (hinv.retiredClean hret).1
        cases units with
        | nil => simp at hunits_ne
        | cons u0 _ =>
          have hu0 := List.all_eq_true.mp hall_reg u0 List.mem_cons_self
          unfold RegGen.lookupUnit at hu0
          simp [hreg_empty] at hu0
      · intro expected hexp
        injection hexp with hexp; subst hexp
        exact hnot_voted
  | abandonClaim owner =>
    dsimp only [RegGen.step] at hstep
    split at hstep
    · cases hstep
    split at hstep
    · rename_i hemp
      injection hstep with h; subst h
      refine ⟨⟨rfl, by intro u h; cases h⟩, ?_, ?_, by intro e h; cases h⟩
      · intro hc
        obtain ⟨h1, _, _, h4⟩ := hinv.tombstoneClean hc
        exact ⟨h1, rfl, rfl, h4⟩
      · intro hr
        obtain ⟨h1, _, _⟩ := hinv.retiredClean hr
        exact ⟨h1, rfl, rfl⟩
    · rename_i hnot_emp
      injection hstep with h; subst h
      simp only [Bool.not_eq_true] at hnot_emp
      have hclaim_some : s.claimedUnits.isSome = true := by
        cases h : s.claimOwners with
        | nil => simp [h] at hnot_emp
        | cons _ _ =>
          have hc := hinv.claimConsistent.1
          simp [h] at hc
          exact hc
      refine ⟨⟨?_, hinv.claimConsistent.2⟩, ?_, ?_, hinv.partialVotes⟩
      · simp [hclaim_some, hnot_emp]
      · intro hc
        obtain ⟨_, h2, _⟩ := hinv.tombstoneClean hc
        simp [h2] at hclaim_some
      · intro hr
        obtain ⟨_, h2, _⟩ := hinv.retiredClean hr
        simp [h2] at hclaim_some
  | complete unit =>
    dsimp only [RegGen.step] at hstep
    split at hstep
    · cases hstep
    split at hstep
    · injection hstep with h; subst h; exact hinv
    rename_i hrel
    cases hclaim : s.claimedUnits with
    | some expected =>
      simp only [hclaim] at hstep
      split at hstep
      · injection hstep with h; subst h
        exact retireLocked_inv s
      · rename_i hnot_all
        injection hstep with h; subst h
        simp only [Bool.not_eq_true] at hnot_all
        refine ⟨?_, ?_, ?_, ?_⟩
        · refine ⟨?_, ?_⟩
          · have hc := hinv.claimConsistent.1
            simpa [hclaim] using hc
          · intro u hu
            exact hinv.claimConsistent.2 u (by simpa [hclaim] using hu)
        · intro hc
          obtain ⟨_, h2, _⟩ := hinv.tombstoneClean hc
          simp [hclaim] at h2
        · intro hr
          obtain ⟨_, h2, _⟩ := hinv.retiredClean hr
          simp [hclaim] at h2
        · intro exp hexp
          injection hexp with hexp; subst hexp
          exact hnot_all
    | none =>
      simp only [hclaim] at hstep
      injection hstep with h; subst h
      have howners : s.claimOwners.isEmpty = true := by
        have hc := hinv.claimConsistent.1
        rw [hclaim] at hc
        cases h1 : s.claimOwners.isEmpty with
        | true => rfl
        | false => simp [h1] at hc
      refine ⟨⟨by simp [howners], by intro u h; cases h⟩, ?_, ?_, by intro e h; cases h⟩
      · intro hc
        obtain ⟨h1, _, _⟩ := hinv.tombstoneClean hc
        unfold RegGen.lookupUnit inClaimedUnits at hrel
        simp [hclaim, h1] at hrel
      · intro hr
        obtain ⟨h1, _, h3⟩ := hinv.retiredClean hr
        exact ⟨h1, rfl, h3⟩
  | cancelIfUnclaimed =>
    dsimp only [RegGen.step] at hstep
    split at hstep
    · injection hstep with h; subst h; exact hinv
    split at hstep
    · injection hstep with h; subst h; exact hinv
    injection hstep with h; subst h
    refine ⟨⟨rfl, by intro u h; cases h⟩, ?_, ?_, by intro e h; cases h⟩
    · intro _; exact ⟨rfl, rfl, rfl, rfl⟩
    · intro _; exact ⟨rfl, rfl, rfl⟩
  | release =>
    dsimp only [RegGen.step] at hstep
    injection hstep with h; subst h
    exact retireLocked_inv s

/-- **Main Reachability Theorem for `RequestBlockRegistry` (`reachable_safe`)**:
Every reachable state of `RegGen.sys` satisfies `Inv`. -/
theorem reachable_safe {s : RegGen} (hr : RegGen.sys.Reachable s) : Inv s := by
  induction hr with
  | init => exact init_inv
  | step _ hstep ih => exact step_preserves_inv ih hstep

/-! ## Part III — Named Protocol Guarantees -/

/-- **Tombstone Blocks Late Registration & Claim (`TombstoneBlocksLateRegister`,
`request_block_registry.cc:276-280, 448-452`)**:
Once a generation is cancelled (`s.cancelled = true`), both `register` and
`lookupAndClaim` are unconditionally rejected (`none`). -/
theorem tombstone_blocks_register_and_claim (s : RegGen) (hc : s.cancelled = true)
    (unit : Nat) (nonEmpty : Bool) (owner : Nat) (units : List Nat) :
    RegGen.step s (.register unit nonEmpty) = none ∧
    RegGen.step s (.lookupAndClaim owner units) = none := by
  simp [RegGen.step, hc]

/-- **Active Claim Blocks Cancellation & Registration (`ClaimedNotCancelled`,
`request_block_registry.cc:281-285, 388-390`)**:
While `s.claimedUnits = some units`, `register` is rejected and
`cancelIfUnclaimed` is a no-op that leaves `s` (and all its registered blocks
and claims) unchanged. -/
theorem claimed_blocks_register_and_cancel {s : RegGen} {units : List Nat}
    (hinv : Inv s) (hclaim : s.claimedUnits = some units)
    (unit : Nat) (nonEmpty : Bool) :
    RegGen.step s (.register unit nonEmpty) = none ∧
    RegGen.step s .cancelIfUnclaimed = some s := by
  have hnc : s.cancelled = false := by
    cases hc : s.cancelled with
    | false => rfl
    | true =>
      have h2 := (hinv.tombstoneClean hc).2.1
      simp [hclaim] at h2
  simp [RegGen.step, hclaim, hnc]

/-- **Multi-Owner Claim Survival (`MultiOwnerSurvival`,
`request_block_registry.h:144-147`, `request_block_registry.cc:493-509`)**:
If two distinct planning owners `o₁ ≠ o₂` hold claims on `s`, then
`abandonClaim o₁` preserves `s'.claimedUnits = s.claimedUnits` (`o₂`'s claim
survives). -/
theorem abandonClaim_preserves_when_other_owner_present {s : RegGen}
    {o₁ o₂ : Nat} (hne : o₂ ≠ o₁)
    (ho₁ : s.claimOwners.contains o₁ = true)
    (ho₂ : s.claimOwners.contains o₂ = true) :
    ∃ s', RegGen.step s (.abandonClaim o₁) = some s' ∧
      s'.claimedUnits = s.claimedUnits ∧
      s'.claimOwners.contains o₂ = true := by
  dsimp only [RegGen.step]
  simp only [ho₁, Bool.not_true, Bool.false_eq_true, ↓reduceIte]
  have hmem₂ : o₂ ∈ s.claimOwners.filter (fun o => o != o₁) := by
    rw [List.mem_filter]
    exact ⟨List.contains_iff_mem.mp ho₂, bne_iff_ne.mpr hne⟩
  have hnot_emp : (s.claimOwners.filter (fun o => o != o₁)).isEmpty = false :=
    List.isEmpty_eq_false_iff.mpr (List.ne_nil_of_mem hmem₂)
  simp only [hnot_emp, Bool.false_eq_true, ↓reduceIte]
  refine ⟨_, rfl, rfl, List.contains_iff_mem.mpr hmem₂⟩

/-- **Full-Set Voting Required to Retire Claimed Generation
(`CompleteRequiresFullVotingSet`, `request_block_registry.cc:358-369`)**:
When `s.claimedUnits = some expected` (and `s.retired = false`), a `complete`
step for an expected unit `unit ∈ expected` transitions to `s'.retired = true`
if and only if every unit `u ∈ expected` has voted in
`insertNodup unit s.completedUnits`. -/
theorem complete_retires_iff_all_claimed_voted {s s' : RegGen} {expected : List Nat}
    {unit : Nat}
    (hclaim : s.claimedUnits = some expected)
    (hmem : expected.contains unit = true)
    (hnot_ret : s.retired = false)
    (hstep : RegGen.step s (.complete unit) = some s') :
    s'.retired = true ↔
      allVoted expected (insertNodup unit s.completedUnits) = true := by
  dsimp only [RegGen.step] at hstep
  simp only [hclaim, inClaimedUnits, hmem, Option.isSome_some, Bool.not_true,
    Bool.false_and, Bool.and_false, Bool.false_eq_true, ↓reduceIte] at hstep
  split at hstep
  · rename_i hall
    injection hstep with h; subst h
    simp [RegGen.retireLocked, hall]
  · rename_i hnot_all
    injection hstep with h; subst h
    simp only [Bool.not_eq_true] at hnot_all
    simp [hnot_ret, hnot_all]

/-! ## Part IV — Concrete `decide` Traces (`reshard_service_test.cc` Parity) and Mutants -/

/-- Happy-path 2-unit producer registration, multi-owner pipelined claim,
single-owner abandon (claim survives), and 2-unit completion voting that retires
only on the second vote (`request_block_registry.cc:260-509`,
`reshard_service_test.cc:1029-1052, 1278-1332`). -/
def registryHappyTrace : List Ev :=
  [ .register 0 true
  , .register 1 true
  , .lookupAndClaim 101 [0, 1]
  , .lookupAndClaim 102 [0, 1]
  , .abandonClaim 101
  , .complete 0
  , .complete 1 ]

theorem trace_registry_multi_owner_and_voting :
    (RegGen.sys.run registryHappyTrace).map
      (fun s => (s.status, s.claimedUnits, s.registeredUnits, s.retired)) =
      some (.unknown, none, [], true) := by
  decide

/-- Replay of `ReshardStackTest.CompletionVotesRetireAfterClaim`
(`tpu_sync/kv_cache/reshard/reshard_service_test.cc:1029-1052`):
After the first of two claimed units votes (`complete 0`, `:1046-1048`), the
generation is still `.claimed` and `retired = false` (`"0"` rows retired); when
the second unit votes (`complete 1`, `:1049-1051`), `RetireLocked` fires
(`retired = true`, `registeredUnits = []`, `"2"` rows retired). -/
theorem trace_partial_vote_does_not_retire :
    (RegGen.sys.run (registryHappyTrace.take 6)).map
      (fun s => (s.status, s.claimedUnits, s.completedUnits, s.retired)) =
      some (.claimed, some [0, 1], [0], false) := by
  decide

/-- Replay of `ReshardStackTest.CancelTombstoneBlocksLateRegistration`
(`tpu_sync/kv_cache/reshard/reshard_service_test.cc:933-961`) and
`request_block_registry.cc:276-280, 385-404, 448-452`:
1. Cancelling an unclaimed generation before any producer registers (`:936-945`)
   or after partial registration (`:1004-1010`) records a `.cancelled` tombstone.
2. Any late producer `register` (`:947-961`) or `lookupAndClaim` (`:1357-1361`)
   against the cancelled `(req_id, uuid)` is rejected (`none`). -/
theorem trace_tombstone_blocks_late_register_and_claim :
    ((RegGen.sys.run [.cancelIfUnclaimed]).map
      (fun s => (s.status, RegGen.step s (.register 0 true))) =
      some (.cancelled, none)) ∧
    ((RegGen.sys.run [.register 0 true, .cancelIfUnclaimed]).map
      (fun s =>
        ( s.status
        , s.registeredUnits
        , RegGen.step s (.register 1 true)
        , RegGen.step s (.lookupAndClaim 101 [0]) )) =
      some (.cancelled, [], none, none)) := by
  decide

/-- Replay of `ReshardStackTest.RequestBlockStatusProbeTracksLifecycle`
(`tpu_sync/kv_cache/reshard/reshard_service_test.cc:963-1027`):
1. Never registered (`RegGen.init`, `:995-997`) reads as `.unknown`.
2. Registered and unclaimed (`[.register 0 true]`, `:999-1002`) reads as
   `.registered`.
3. Release-only cancel (`[.register 0 true, .cancelIfUnclaimed]`, `:1004-1010`)
   erases the row and reads as `.cancelled`.
4. Claimed registration (`[.register 0 true, .register 1 true,
   .lookupAndClaim 101 [0, 1]]`, `:1012-1021`) reads as `.claimed` and refuses
   cancellation (staying `.claimed` with `cancelled = false`). -/
theorem trace_request_block_status_probe_lifecycle :
    RegGen.init.status = .unknown ∧
    (RegGen.sys.run [.register 0 true]).map RegGen.status = some .registered ∧
    (RegGen.sys.run [.register 0 true, .cancelIfUnclaimed]).map RegGen.status =
      some .cancelled ∧
    (RegGen.sys.run
      [.register 0 true, .register 1 true, .lookupAndClaim 101 [0, 1],
       .cancelIfUnclaimed]).map
      (fun s => (s.status, s.cancelled)) = some (.claimed, false) := by
  decide

/-- Replay of `ReshardStackTest.PipelinedDestinationStagesShareOneRequestClaim`
(`tpu_sync/kv_cache/reshard/reshard_service_test.cc:1278-1303`),
`AbandonedStageLeavesTheSiblingClaimInPlace` (`:1305-1332`), and
`AbandoningTheLastStageFreesTheClaim` (`:1334-1361`):
1. Stage 0 (`100`) and Stage 1 (`101`) share one request claim on `[0, 1]`; when
   Stage 1 abandons its claim (`abandonClaim 101`, `:1310-1326`), Stage 0's
   claim remains in place (`status = .claimed`, `cancelIfUnclaimed` refused with
   `cancelled = false`), and Stage 1 can rejoin (`lookupAndClaim 101 [0, 1]`,
   `:1327-1331`).
2. When both Stage 0 (`100`) and Stage 1 (`101`) abandon their claims
   (`:1339-1350`), the last stage leaving frees the claim (`status = .registered`),
   allowing `cancelIfUnclaimed` to succeed (`status = .cancelled`) and blocking
   a late Stage 0 retry (`:1351-1361`). -/
theorem trace_pipelined_stages_claim_and_abandon :
    ((RegGen.sys.run
      [ .register 0 true, .register 1 true
      , .lookupAndClaim 100 [0, 1], .lookupAndClaim 101 [0, 1]
      , .abandonClaim 101, .cancelIfUnclaimed
      , .lookupAndClaim 101 [0, 1] ]).map
      (fun s => (s.status, s.cancelled, s.claimOwners)) =
      some (.claimed, false, [100, 101])) ∧
    ((RegGen.sys.run
      [ .register 0 true, .register 1 true
      , .lookupAndClaim 100 [0, 1], .abandonClaim 100
      , .lookupAndClaim 101 [0, 1], .abandonClaim 101 ]).map
      (fun s =>
        ( s.status
        , (RegGen.step s .cancelIfUnclaimed).map
            (fun s_canc => (s_canc.status, RegGen.step s_canc (.lookupAndClaim 100 [0, 1]))) )) =
      some (.registered, some (.cancelled, none))) := by
  decide

/-- Mutant 1: If `Complete` retired on the *first* unit vote instead of checking
`all_voted` across `claimed_units_` (`request_block_registry.cc:359-368`),
`unit 0` finishing its push would prematurely retire `unit 1`'s registered
producer blocks while `unit 1` is still transferring. -/
def stepCompletePremature (s : RegGen) (unit : Nat) : RegGen :=
  let _ := unit
  s.retireLocked

theorem mutant_premature_complete_retires_while_peer_active :
    (RegGen.sys.run [.register 0 true, .register 1 true, .lookupAndClaim 101 [0, 1]]).map
      (fun s =>
        let s_good := RegGen.step s (.complete 0)
        let s_bad := stepCompletePremature s 0
        (s_good.map (fun x => x.retired), s_bad.retired, s_bad.registeredUnits)) =
      some (some false, true, []) := by
  decide

/-- Mutant 2: If `AbandonClaim` erased `claimed_` unconditionally without
checking `claimed_owners_.empty()` (`request_block_registry.cc:503-507`), one
pipelined stage abandoning its claim would strip the claim out from under a
concurrent stage `owner = 102`, allowing `CancelIfUnclaimed` to cancel the
blocks mid-transfer. -/
def stepAbandonUnconditional (s : RegGen) (owner : Nat) : RegGen :=
  { s with
    claimedUnits := none
    claimOwners := s.claimOwners.filter (fun o => o != owner) }

theorem mutant_unconditional_abandon_exposes_sibling_owner_to_cancel :
    (RegGen.sys.run
      [.register 0 true, .lookupAndClaim 101 [0], .lookupAndClaim 102 [0]]).bind
      (fun s =>
        let s_bad := stepAbandonUnconditional s 101
        (RegGen.step s_bad .cancelIfUnclaimed).map (fun x => x.cancelled)) =
      some true := by
  decide

/-- **Observation R7 (`request_block_registry.h:124, 144-149`,
`request_block_registry.cc:358-368`)**:
Although `claimed_owners_` tracks multiple pipelined `claim_owner` strings for a
shared source snapshot, `completed_units_[(req_id, uuid)].units` is keyed only
by `(req_id, uuid)` (not `(req_id, uuid, claim_owner)`), and `Complete` calls
`RetireLocked` as soon as every unit in `claimed_units_` votes once. Thus when
stage `101` and stage `102` both hold active claims (`claimOwners = [102, 101]`),
stage `101`'s source units voting `.complete 0` and `.complete 1` immediately
retires the generation and erases `102`'s claim and source blocks. -/
theorem trace_r7_single_stage_votes_retire_multi_owner_claim :
    (RegGen.sys.run
      [ .register 0 true
      , .register 1 true
      , .lookupAndClaim 101 [0, 1]
      , .lookupAndClaim 102 [0, 1]
      , .complete 0
      , .complete 1 ]).map
      (fun s => (s.retired, s.claimedUnits, s.claimOwners, s.registeredUnits)) =
      some (true, none, [], []) := by
  decide

/-! ## Part V — Wall-Clock TTL Expiration (`PurgeExpired*`) and Observation R8 -/

/-- `RequestBlockRegistry::PurgeExpiredRequestBlocksLocked`
(`tpu_sync/kv_cache/reshard/request_block_registry.cc:61-69`):
erases `request_blocks_` entries whose `registration.expires_at <= now` (set to
`t_reg + ttl_s_` at `Register`, `:263`). -/
def RegGen.purgeExpiredRequestBlocks (s : RegGen) : RegGen :=
  { s with registeredUnits := [] }

/-- `RequestBlockRegistry::PurgeExpiredLifecycleLocked`
(`tpu_sync/kv_cache/reshard/request_block_registry.cc:71-96`):
erases `claimed_`, `cancelled_`, `completed_units_`, `claimed_owners_`, and
`claimed_units_` entries whose lifecycle `expires_at <= now`. -/
def RegGen.purgeExpiredLifecycle (s : RegGen) : RegGen :=
  { s with
    claimedUnits := none
    claimOwners := []
    completedUnits := []
    cancelled := false }

/-- Combined TTL purge when `now` advances past both `registration.expires_at`
and lifecycle `expires_at` (`request_block_registry.cc:61-96`,
`reshard_service_test.cc:1023-1027, 1054-1062`). -/
def RegGen.purgeExpiredAll (s : RegGen) : RegGen :=
  s.purgeExpiredRequestBlocks.purgeExpiredLifecycle

theorem purgeExpiredAll_inv (s : RegGen) : Inv s.purgeExpiredAll where
  claimConsistent := ⟨rfl, by intro units h; cases h⟩
  tombstoneClean := by intro h; cases h
  retiredClean := by intro _; exact ⟨rfl, rfl, rfl⟩
  partialVotes := by intro expected h; cases h

/-- Replay of `ReshardStackTest.TtlPurgesExpiredRegistrations`
(`tpu_sync/kv_cache/reshard/reshard_service_test.cc:1054-1062`) and the TTL
tombstone lapse in `ReshardStackTest.RequestBlockStatusProbeTracksLifecycle`
(`:1023-1027`):
1. `TtlPurgesExpiredRegistrations` (`:1054-1062`): unit `0` registers, `now_`
   advances past the 600 s TTL (`purgeExpiredAll`), and a subsequent
   `lookupAndClaim 101 [0]` fails (`none`, `"Missing producer block registration"`).
2. `RequestBlockStatusProbeTracksLifecycle` (`:1023-1027`): after
   `cancelIfUnclaimed` records a `.cancelled` tombstone, advancing `now_` past
   the TTL (`purgeExpiredAll`) purges the tombstone so `status` reads as
   `.unknown`. -/
theorem trace_ttl_purges_expired_registrations_and_tombstones :
    ((RegGen.sys.run [.register 0 true]).map
      (fun s =>
        let s_exp := s.purgeExpiredAll
        (s_exp.status, RegGen.step s_exp (.lookupAndClaim 101 [0]))) =
      some (.unknown, none)) ∧
    ((RegGen.sys.run [.register 0 true, .cancelIfUnclaimed]).map
      (fun s => (s.status, s.purgeExpiredAll.status)) =
      some (.cancelled, .unknown)) := by
  decide

/-- **Observation R8 (`request_block_registry.cc:61-69, 263, 473`)**:
`Register` at time `t_0` sets `registration.expires_at = t_0 + ttl_s_` on
`request_blocks_[(req_id, unit)]` (`:263`), whereas `LookupAndClaim` at time
`t_1 > t_0` sets `claimed_[(req_id, uuid)] = t_1 + ttl_s_` (`:473`) **without**
refreshing `registration.expires_at` on the claimed `request_blocks_` rows.
In the window `[t_0 + ttl_s_, t_1 + ttl_s_)`, `PurgeExpiredRequestBlocksLocked`
(`:61-69`) erases `request_blocks_[(req_id, unit)]` while `claimed_` is still
active (`s_split = s.purgeExpiredRequestBlocks`):
1. `s_split.status` still reports `.claimed` (`claimedUnits = some [0]`), but
   `s_split.registeredUnits = []` (violating `ClaimOwnersConsistent`), and
2. A second pipelined stage calling `lookupAndClaim 102 [0]` in that window fails
   (`none`) with `"Missing producer block registration"` (`:463-468`). -/
theorem trace_r8_split_ttl_purges_request_blocks_while_claim_active :
    ((RegGen.sys.run [.register 0 true, .lookupAndClaim 101 [0]]).map
      (fun s =>
        let s_split := s.purgeExpiredRequestBlocks
        ( s_split.status
        , s_split.claimedUnits
        , s_split.registeredUnits
        , (RegGen.step s_split (.lookupAndClaim 102 [0])).isNone )) =
      some (.claimed, some [0], [], true)) := by
  decide

/-- Candidate registry events over two producer units (`0, 1`) and two pipelined
claim owners (`100, 101`). -/
def checkEvents : List Ev :=
  [ .register 0 true, .register 1 true, .register 0 false
  , .lookupAndClaim 100 [0, 1], .lookupAndClaim 101 [0, 1], .lookupAndClaim 100 [0]
  , .abandonClaim 100, .abandonClaim 101
  , .complete 0, .complete 1
  , .cancelIfUnclaimed, .release ]

/-- Executable negation of `Inv`. -/
def violates (s : RegGen) : Bool :=
  (s.claimedUnits.isSome != !s.claimOwners.isEmpty) ||
  (match s.claimedUnits with
   | none => false
   | some units =>
     units.isEmpty ||
     units.any (fun u => !(s.lookupUnit u).isSome) ||
     allVoted units s.completedUnits) ||
  (s.cancelled && (!s.registeredUnits.isEmpty || s.claimedUnits.isSome ||
                   !s.claimOwners.isEmpty || !s.completedUnits.isEmpty)) ||
  (s.retired && (!s.registeredUnits.isEmpty || s.claimedUnits.isSome || !s.claimOwners.isEmpty))

#guard ModelCheck.check RegGen.sys checkEvents violates 12 = .safe

end TpuSyncVerify.Transfer.Reshard.Registry

