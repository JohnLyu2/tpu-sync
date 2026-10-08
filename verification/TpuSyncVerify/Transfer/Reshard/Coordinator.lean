/-
  TpuSyncVerify/Transfer/Reshard/Coordinator.lean

  Formal model of Stage 4b: two-stage `ReshardCoordinator::ExecutePoolReshard`
  orchestration (`tpu_sync/kv_cache/reshard/reshard_coordinator.{h,cc}`)
  composed with `RequestBlockRegistry` (`TpuSyncVerify.Transfer.Reshard.Registry`).

  C++ source under analysis:
  * `tpu_sync/kv_cache/reshard/reshard_coordinator.h:59-165`
  * `tpu_sync/kv_cache/reshard/reshard_coordinator.cc:400-526`
  * `tpu_sync/core/kv_cache_listener.cc:217-244` (`PoolReshardRegisterRecv` control-pipe handler)
  * `tpu_sync/core/kv_cache_manager_with_transfer.cc:640-675`
    (`PoolReshardRegisterRecv`: `ReshardReceiveSession::Create` + `RegisterActivePlanDirect`)
  * `tpu_sync/core/reshard_receive_session.cc:373-378, 408-456`
    (`AcquireStagingLeases` + `ReleaseStagingLeases`)

  What this file proves:
  1. **Universal Protocol Guarantees (`CoordInv`, `reachable_coord_inv`)**:
     Across all reachable states (under both shipping and hardened cleanup
     policies):
     * `Registry.Inv s.reg` holds at every step.
     * `NoPushBeforeAllArmed` (`reshard_coordinator.cc:442-461`): No sender
       is dispatched (`s.sendResults = []`) and no receiver receives any push
       while `s.phase = .idle ∨ s.phase = .arming`.
     * `AllArmedInDispatching` (`reshard_coordinator.cc:442-456`): Entering
       `.dispatching` requires `s.armFailed = false` and all `dstUnits`
       reported in `s.armResults`.
     * `ClaimedWhileArming` (`reshard_coordinator.cc:403-448`): Throughout
       `.arming`, the source snapshot remains claimed in `RequestBlockRegistry`
       (`s.reg.claimedUnits = some s.srcUnits` and `s.reg.claimOwners = [s.claimOwner]`),
       preventing `CancelIfUnclaimed` and conflicting `Register` calls.
     * `LeaseMatchesSession`: Every destination unit holds a `PoolStagingLease`
       if and only if its `ReshardReceiveSession` is currently armed.
  2. **Risk R2a & R2b Constructive Counterexamples under `.shipping`**:
     * `trace_r2a_partial_arm_orphans_armed_receiver`
       (`reshard_coordinator.cc:443-448`): When `dst_unit 10` succeeds in arming
       and `dst_unit 11` fails, `ExecutePoolReshard` calls `AbandonClaim` and
       aborts without disarming `dst_unit 10`, leaving `dst_unit 10`'s
       `ReshardReceiveSession` and `PoolStagingLease` orphaned until
       `timeout_s_`.
     * `trace_r2b_dispatch_failure_orphans_receivers_and_claim`
       (`reshard_coordinator.cc:523-525`): When all `dst_units` arm and
       `src_unit 0` succeeds but `src_unit 1` fails during Stage 2 dispatch,
       `ExecutePoolReshard` returns `sender_status` without disarming
       `dst_units` AND without calling `registry_->AbandonClaim(...)`. Both
       `dst_units` remain orphaned with active sessions/leases AND
       `claimed_[(req_id, uuid)]` remains pinned in `RequestBlockRegistry`
       until `ttl_s_`.
  3. **Hardened Cleanup Policy Proof (`reachable_disarmAndAbandon_no_orphans`)**:
     Under `CleanupPolicy.disarmAndAbandonOnFailure`, every reachable `.aborted`
     state has zero armed receiver sessions, zero held staging leases, and
     `s.reg.claimedUnits = none ∧ s.reg.claimOwners = []`.

  Pinned upstream commit: `50b0774`
-/
import TpuSyncVerify.Common.System
import TpuSyncVerify.Transfer.Reshard.Registry

namespace TpuSyncVerify.Transfer.Reshard.Coordinator

open TpuSyncVerify
open TpuSyncVerify.Transfer.Reshard.Registry

/-! ## Part I — Coordinator, Receiver-Arming, and Cleanup Policy State Machine -/

/-- Coordinator failure cleanup policy comparing the shipping implementation
(`reshard_coordinator.cc:443-448, 523-525`) against a hardened policy that
disarms armed receivers and abandons the registry claim on any barrier failure. -/
inductive CleanupPolicy where
  /-- Shipping C++ behavior:
      * Arm failure (`reshard_coordinator.cc:443-448`): calls `AbandonClaim`,
        does not disarm already-armed `dst_units`.
      * Send failure (`reshard_coordinator.cc:523-525`): neither disarms
        `dst_units` nor calls `AbandonClaim`. -/
  | shipping
  /-- Hardened cleanup behavior: on either arm-barrier failure or send-barrier
      failure, disarms all currently armed `dst_units` (releasing their
      `ReshardReceiveSession` and `PoolStagingLease`) and calls `AbandonClaim`
      on `RequestBlockRegistry`. -/
  | disarmAndAbandonOnFailure
  deriving DecidableEq, Repr

/-- Lifecycle phase of `ReshardCoordinator::ExecutePoolReshard`
(`reshard_coordinator.cc:400-526`). -/
inductive CoordPhase where
  /-- Before `ExecutePoolReshard` claims the source snapshot. -/
  | idle
  /-- Stage 1 (`reshard_coordinator.cc:418-442`): `BuildPoolReshardPlan`
      claimed the source snapshot in `RequestBlockRegistry`; concurrent
      `PoolReshardRegisterRecv` RPCs to `dst_units` are in flight. -/
  | arming
  /-- Stage 2 (`reshard_coordinator.cc:461-522`): all `dst_units` armed with
      `arm_status.ok()`; concurrent `PoolReshardSend` RPCs to `src_units` are
      in flight. -/
  | dispatching
  /-- Both stages completed with `absl::OkStatus()` (`reshard_coordinator.cc:526`). -/
  | succeeded
  /-- `ExecutePoolReshard` returned a non-OK `absl::Status`
      (`reshard_coordinator.cc:405-410, 443-448, 523-525`). -/
  | aborted
  deriving DecidableEq, Repr

/-- Per-destination-unit receiver state (`kv_cache_listener.cc:217-244`,
`kv_cache_manager_with_transfer.cc:640-675`,
`reshard_receive_session.cc:373-378, 408-456`). -/
structure DstUnitState where
  /-- Destination unit ID (`UnitKey`). -/
  unit : Nat
  /-- True while `ReshardReceiveSession` is registered in
      `active_pool_reshard_recvs_` with an armed plan in `active_plans_`. -/
  sessionArmed : Bool
  /-- True while the `PoolStagingLease` acquired by `AcquireStagingLeases`
      (`reshard_receive_session.cc:376, 408-445`) is held. -/
  stagingLeaseHeld : Bool
  /-- Set of `src_unit` IDs whose `PoolReshardPush` has arrived. -/
  pushesReceived : List Nat
  /-- True once all `src_units` have pushed and the session has settled and
      released its staging lease (`reshard_receive_session.cc:447-456`). -/
  completed : Bool
  deriving DecidableEq, Repr

namespace DstUnitState

/-- Initial unarmed destination unit state. -/
def init (unit : Nat) : DstUnitState :=
  { unit := unit
    sessionArmed := false
    stagingLeaseHeld := false
    pushesReceived := []
    completed := false }

/-- Arm this destination unit via `PoolReshardRegisterRecv`
(`kv_cache_manager_with_transfer.cc:640-675`,
`reshard_receive_session.cc:373-378`). -/
def arm (d : DstUnitState) : DstUnitState :=
  { d with
    sessionArmed := true
    stagingLeaseHeld := true }

/-- Explicitly disarm this destination unit on coordinator abort, releasing its
active `ReshardReceiveSession` and `PoolStagingLease`. -/
def disarm (d : DstUnitState) : DstUnitState :=
  { d with
    sessionArmed := false
    stagingLeaseHeld := false }

/-- Deliver a sender push from `srcUnit` to an armed destination unit; if all
`srcUnits` have now contributed (`reshard_receive_session.cc:621-688`), complete
the session and release its staging lease (`reshard_receive_session.cc:447-456`). -/
def receivePush (d : DstUnitState) (srcUnits : List Nat) (srcUnit : Nat) : DstUnitState :=
  if !d.sessionArmed then
    d
  else
    let pushed := insertNodup srcUnit d.pushesReceived
    if allVoted srcUnits pushed then
      { d with
        sessionArmed := false
        stagingLeaseHeld := false
        pushesReceived := pushed
        completed := true }
    else
      { d with pushesReceived := pushed }

end DstUnitState

/-- Combined state of `ReshardCoordinator::ExecutePoolReshard`, the destination
units' `ReshardReceiveSession`s, and the shared `RequestBlockRegistry` generation. -/
structure CoordState where
  /-- Source unit IDs (`plan.src_units`). -/
  srcUnits : List Nat
  /-- Destination unit IDs (`plan.dst_units`). -/
  dstUnits : List Nat
  /-- Coordinator's unique `claim_owner` token (`MakePlanClaimOwner`,
      `reshard_coordinator.cc:50-56, 402`). -/
  claimOwner : Nat
  /-- Current coordinator lifecycle phase. -/
  phase : CoordPhase
  /-- Per-destination-unit state. -/
  dstStates : List DstUnitState
  /-- Completed `PoolReshardRegisterRecv` RPC results `(dstUnit, ok)` collected
      during Stage 1 (`reshard_coordinator.cc:423-442`). -/
  armResults : List (Nat × Bool)
  /-- `true` if `!arm_status.ok()` during Stage 1 (`reshard_coordinator.cc:421, 434-436`). -/
  armFailed : Bool
  /-- Completed `PoolReshardSend` RPC results `(srcUnit, ok)` collected during
      Stage 2 (`reshard_coordinator.cc:471-522`). -/
  sendResults : List (Nat × Bool)
  /-- `true` if `!sender_status.ok()` during Stage 2 (`reshard_coordinator.cc:472, 500-503`). -/
  sendFailed : Bool
  /-- Underlying `RequestBlockRegistry` state for `(args.req_id, args.uuid)`. -/
  reg : RegGen
  deriving DecidableEq, Repr

/-- Events of the two-stage coordinator + registry composition. -/
inductive Ev where
  /-- Producer unit registers its source blocks in `RequestBlockRegistry`
      before reshard planning (`request_block_registry.cc:260-299`). -/
  | registerProducer (srcUnit : Nat)
  /-- `BuildPoolReshardPlan(args, claim_owner)` (`reshard_coordinator.cc:403-411`):
      claims `srcUnits` in `RequestBlockRegistry` (`LookupAndClaim`), and then
      either succeeds (`planOk = true` -> `.arming`) or fails after claiming
      (`planOk = false` -> `AbandonClaim` + `.aborted`). -/
  | startPlan (planOk : Bool)
  /-- Stage 1 worker RPC `PoolReshardRegisterRecv` finishes for `dstUnit`
      (`reshard_coordinator.cc:424-440`). -/
  | armDstResult (dstUnit : Nat) (ok : Bool)
  /-- Stage 1 join barrier `for (auto& t : arm_threads) t.join()` and
      `if (!arm_status.ok())` check (`reshard_coordinator.cc:442-456`). -/
  | finishArmBarrier
  /-- Stage 2 worker RPC `PoolReshardSend` finishes for `srcUnit`
      (`reshard_coordinator.cc:474-518`). -/
  | sendSrcResult (srcUnit : Nat) (ok : Bool)
  /-- Stage 2 join barrier `for (auto& t : send_threads) t.join()` and
      `if (!sender_status.ok())` check (`reshard_coordinator.cc:522-526`). -/
  | finishSendBarrier
  deriving DecidableEq, Repr

/-- Helper: check if `unit` already has an RPC result in `results`. -/
def hasResult (results : List (Nat × Bool)) (unit : Nat) : Bool :=
  results.any (fun (u, _) => u == unit)

/-- Helper: check if every unit in `units` has reported an RPC result. -/
def allReported (units : List Nat) (results : List (Nat × Bool)) : Bool :=
  units.all (fun u => hasResult results u)

/-- Helper: abandon `claimOwner` in `reg` if currently claimed by `claimOwner`
(`RequestBlockRegistry::AbandonClaim`, `request_block_registry.cc:493-509`). -/
def abandonIfClaimed (reg : RegGen) (claimOwner : Nat) : RegGen :=
  match RegGen.step reg (.abandonClaim claimOwner) with
  | some reg' => reg'
  | none => reg

namespace CoordState

/-- Initial coordinator + registry state for a given `(srcUnits, dstUnits, claimOwner)`
configuration. -/
def init (srcUnits dstUnits : List Nat) (claimOwner : Nat) : CoordState :=
  { srcUnits := srcUnits
    dstUnits := dstUnits
    claimOwner := claimOwner
    phase := .idle
    dstStates := dstUnits.map DstUnitState.init
    armResults := []
    armFailed := false
    sendResults := []
    sendFailed := false
    reg := RegGen.init }

/-- Small-step transition relation of `ReshardCoordinator::ExecutePoolReshard`
parameterized by `CleanupPolicy` (`reshard_coordinator.cc:400-526`). -/
def step (policy : CleanupPolicy) (s : CoordState) (e : Ev) : Option CoordState :=
  match e with
  | .registerProducer srcUnit =>
    if s.phase != .idle then
      none
    else
      match RegGen.step s.reg (.register srcUnit true) with
      | some reg' => some { s with reg := reg' }
      | none => none

  | .startPlan planOk =>
    if s.phase != .idle then
      none
    else
      -- `BuildPoolReshardPlan` calls `LookupAndClaim(req_id, uuid, srcUnits, claim_owner)`
      -- (`reshard_coordinator.cc:154-160, 403-411`).
      match RegGen.step s.reg (.lookupAndClaim s.claimOwner s.srcUnits) with
      | none => none
      | some regClaimed =>
        if planOk then
          some { s with phase := .arming, reg := regClaimed }
        else
          -- `reshard_coordinator.cc:405-410`: on plan failure, calls `AbandonClaim`
          -- and returns error.
          some
            { s with
              phase := .aborted
              reg := abandonIfClaimed regClaimed s.claimOwner }

  | .armDstResult dstUnit ok =>
    if s.phase != .arming then
      none
    else if !s.dstUnits.contains dstUnit || hasResult s.armResults dstUnit then
      none
    else
      let dstStates' :=
        if ok then
          s.dstStates.map (fun d => if d.unit == dstUnit then d.arm else d)
        else
          s.dstStates
      some
        { s with
          dstStates := dstStates'
          armResults := (dstUnit, ok) :: s.armResults
          armFailed := s.armFailed || !ok }

  | .finishArmBarrier =>
    if s.phase != .arming || !allReported s.dstUnits s.armResults then
      none
    else if !s.armFailed then
      -- All `dst_units` armed with `arm_status.ok()` (`reshard_coordinator.cc:442-456`).
      some { s with phase := .dispatching }
    else
      -- `!arm_status.ok()` (`reshard_coordinator.cc:443-448`):
      match policy with
      | .shipping =>
        -- Shipping code calls `AbandonClaim` (`:445`) and returns `arm_status`
        -- WITHOUT disarming `dst_units` that already armed!
        some
          { s with
            phase := .aborted
            reg := abandonIfClaimed s.reg s.claimOwner }
      | .disarmAndAbandonOnFailure =>
        some
          { s with
            phase := .aborted
            dstStates := s.dstStates.map DstUnitState.disarm
            reg := abandonIfClaimed s.reg s.claimOwner }

  | .sendSrcResult srcUnit ok =>
    if s.phase != .dispatching then
      none
    else if !s.srcUnits.contains srcUnit || hasResult s.sendResults srcUnit then
      none
    else if ok then
      -- `PoolReshardSend` succeeded (`reshard_coordinator.cc:474-515`):
      -- pushes sub-blocks to armed `dst_units` and votes `registry_->Complete`.
      let dstStates' :=
        s.dstStates.map (fun d => d.receivePush s.srcUnits srcUnit)
      let reg' :=
        match RegGen.step s.reg (.complete srcUnit) with
        | some r => r
        | none => s.reg
      some
        { s with
          dstStates := dstStates'
          sendResults := (srcUnit, true) :: s.sendResults
          reg := reg' }
    else
      -- `!status.ok()` (`reshard_coordinator.cc:499-504`):
      -- records `sender_status = status`; does NOT call `registry_->Complete`.
      some
        { s with
          sendResults := (srcUnit, false) :: s.sendResults
          sendFailed := true }

  | .finishSendBarrier =>
    if s.phase != .dispatching || !allReported s.srcUnits s.sendResults then
      none
    else if !s.sendFailed then
      -- All senders succeeded (`reshard_coordinator.cc:523-526`).
      some { s with phase := .succeeded }
    else
      -- `!sender_status.ok()` (`reshard_coordinator.cc:523-525`):
      match policy with
      | .shipping =>
        -- Shipping code returns `sender_status` directly WITHOUT disarming
        -- `dst_units` AND WITHOUT calling `registry_->AbandonClaim`!
        some { s with phase := .aborted }
      | .disarmAndAbandonOnFailure =>
        some
          { s with
            phase := .aborted
            dstStates := s.dstStates.map DstUnitState.disarm
            reg := abandonIfClaimed s.reg s.claimOwner }

/-- System wrapper for a given `(policy, srcUnits, dstUnits, claimOwner)`. -/
def sys (policy : CleanupPolicy) (srcUnits dstUnits : List Nat) (claimOwner : Nat) :
    System CoordState Ev where
  init := init srcUnits dstUnits claimOwner
  step := step policy

end CoordState

/-! ## Part II — Structural Helper Lemmas -/

/-- `abandonIfClaimed` preserves `Registry.Inv`. -/
theorem abandonIfClaimed_inv (reg : RegGen) (owner : Nat) (hinv : Registry.Inv reg) :
    Registry.Inv (abandonIfClaimed reg owner) := by
  unfold abandonIfClaimed
  cases h : RegGen.step reg (.abandonClaim owner) with
  | none => exact hinv
  | some reg' => exact Registry.step_preserves_inv hinv h

/-- When `reg` has at most the single coordinator owner `owner`, `abandonIfClaimed`
guarantees `claimedUnits = none` and `claimOwners = []`. -/
theorem abandonIfClaimed_clears_single_owner (reg : RegGen) (units : List Nat) (owner : Nat)
    (h : (reg.claimedUnits = some units ∧ reg.claimOwners = [owner]) ∨
         (reg.claimedUnits = none ∧ reg.claimOwners = [])) :
    (abandonIfClaimed reg owner).claimedUnits = none ∧
    (abandonIfClaimed reg owner).claimOwners = [] := by
  rcases h with ⟨hc, ho⟩ | ⟨hc, ho⟩
  · unfold abandonIfClaimed RegGen.step
    simp [ho]
  · unfold abandonIfClaimed RegGen.step
    simp [ho, hc]

/-- `register` in `.idle` preserves `claimedUnits = none`, `claimOwners = []`,
and `completedUnits = []`. -/
theorem register_preserves_idle_reg (reg reg' : RegGen) (unit : Nat)
    (hc : reg.claimedUnits = none)
    (ho : reg.claimOwners = [])
    (hcomp : reg.completedUnits = [])
    (hstep : RegGen.step reg (.register unit true) = some reg') :
    reg'.claimedUnits = none ∧
    reg'.claimOwners = [] ∧
    reg'.completedUnits = [] := by
  dsimp only [RegGen.step] at hstep
  split at hstep
  · cases hstep
  cases hlook : reg.lookupUnit unit with
  | some cur =>
    simp only [hlook] at hstep
    split at hstep
    · cases hstep
    · injection hstep with h; subst h; exact ⟨hc, ho, hcomp⟩
  | none =>
    simp only [hlook, Option.some.injEq] at hstep
    subst hstep
    exact ⟨hc, ho, hcomp⟩

/-- `lookupAndClaim` from an `.idle` registry state (`claimedUnits = none`,
`claimOwners = []`, `completedUnits = []`) transitions to
`claimedUnits = some units`, `claimOwners = [owner]`, `completedUnits = []`. -/
theorem lookupAndClaim_from_idle_shape (reg reg' : RegGen) (owner : Nat) (units : List Nat)
    (howners : reg.claimOwners = [])
    (hcomp : reg.completedUnits = [])
    (hstep : RegGen.step reg (.lookupAndClaim owner units) = some reg') :
    reg'.claimedUnits = some units ∧
    reg'.claimOwners = [owner] ∧
    reg'.completedUnits = [] := by
  dsimp only [RegGen.step] at hstep
  split at hstep
  · cases hstep
  rename_i h1
  simp only [Bool.or_eq_true, not_or, Bool.not_eq_true] at h1
  obtain ⟨_, hunits_ne⟩ := h1
  split at hstep
  · cases hstep
  split at hstep
  · cases hstep
  have hall_false : allVoted units reg.completedUnits = false := by
    cases units with
    | nil => simp at hunits_ne
    | cons u0 us => simp [allVoted, hcomp]
  simp only [hall_false, Bool.false_eq_true, ↓reduceIte, Option.some.injEq] at hstep
  subst hstep
  simp [howners, hcomp, insertNodup]

/-- `complete` preserves the single-owner claim shape disjunction: either the
claim `(some units, [owner])` remains active or `retireLocked` clears it to
`(none, [])`. -/
theorem complete_preserves_claim_shape (reg reg' : RegGen) (unit : Nat)
    (units : List Nat) (owner : Nat)
    (h : (reg.claimedUnits = some units ∧ reg.claimOwners = [owner]) ∨
         (reg.claimedUnits = none ∧ reg.claimOwners = []))
    (hstep : RegGen.step reg (.complete unit) = some reg') :
    (reg'.claimedUnits = some units ∧ reg'.claimOwners = [owner]) ∨
    (reg'.claimedUnits = none ∧ reg'.claimOwners = []) := by
  dsimp only [RegGen.step] at hstep
  split at hstep
  · cases hstep
  split at hstep
  · injection hstep with h'; subst h'; exact h
  cases hclaim : reg.claimedUnits with
  | some expected =>
    simp only [hclaim] at hstep
    split at hstep
    · injection hstep with h'; subst h'
      exact Or.inr ⟨rfl, rfl⟩
    · injection hstep with h'; subst h'
      rcases h with ⟨hc, ho⟩ | ⟨hc, _⟩
      · rw [hclaim] at hc; injection hc with hc; subst hc
        exact Or.inl ⟨rfl, ho⟩
      · simp [hclaim] at hc
  | none =>
    simp only [hclaim] at hstep
    injection hstep with h'; subst h'
    rcases h with ⟨hc, _⟩ | ⟨_, ho⟩
    · simp [hclaim] at hc
    · exact Or.inr ⟨rfl, ho⟩

/-- `DstUnitState.receivePush` preserves `stagingLeaseHeld = sessionArmed`. -/
theorem receivePush_leaseMatches (d : DstUnitState) (srcUnits : List Nat) (srcUnit : Nat)
    (h : d.stagingLeaseHeld = d.sessionArmed) :
    (d.receivePush srcUnits srcUnit).stagingLeaseHeld =
    (d.receivePush srcUnits srcUnit).sessionArmed := by
  dsimp only [DstUnitState.receivePush]
  split
  · exact h
  · split <;> simp [h]

/-! ## Part III — Universal Protocol Invariants (Both Policies) -/

/-- In `.idle`, the registry has no active claim or completion votes, and all
destination units are unarmed. -/
def IdleShape (s : CoordState) : Prop :=
  s.phase = .idle →
    s.reg.claimedUnits = none ∧
    s.reg.claimOwners = [] ∧
    s.reg.completedUnits = [] ∧
    ∀ d ∈ s.dstStates, d.sessionArmed = false ∧ d.stagingLeaseHeld = false

/-- **Source Snapshot Claimed Throughout Stage 1 Arming (`ClaimedWhileArming`,
`reshard_coordinator.cc:403-448`)**:
While `s.phase = .arming`, the source snapshot is actively claimed in
`RequestBlockRegistry` (`s.reg.claimedUnits = some s.srcUnits` and
`s.reg.claimOwners = [s.claimOwner]`). -/
def ClaimedWhileArming (s : CoordState) : Prop :=
  s.phase = .arming →
    s.reg.claimedUnits = some s.srcUnits ∧
    s.reg.claimOwners = [s.claimOwner] ∧
    s.reg.completedUnits = []

/-- During `.dispatching`, the registry claim is either still held by
`s.claimOwner` or has been cleanly retired by `Complete` once all `srcUnits`
voted. -/
def DispatchingShape (s : CoordState) : Prop :=
  s.phase = .dispatching →
    (s.reg.claimedUnits = some s.srcUnits ∧ s.reg.claimOwners = [s.claimOwner]) ∨
    (s.reg.claimedUnits = none ∧ s.reg.claimOwners = [])

/-- **No Push Before All Armed (`NoPushBeforeAllArmed`,
`reshard_coordinator.cc:442-461`)**:
While the coordinator is in `.idle` or `.arming`, no sender has been dispatched
(`s.sendResults = []`) and no destination unit has received any push
(`∀ d ∈ s.dstStates, d.pushesReceived = []`). -/
def NoPushBeforeAllArmed (s : CoordState) : Prop :=
  (s.phase = .idle ∨ s.phase = .arming) →
    s.sendResults = [] ∧ ∀ d ∈ s.dstStates, d.pushesReceived = []

/-- **All Armed In Dispatching (`AllArmedInDispatching`,
`reshard_coordinator.cc:442-456`)**:
Whenever the coordinator is in `.dispatching` or `.succeeded`, the Stage 1
arming barrier succeeded (`s.armFailed = false` and `allReported s.dstUnits s.armResults = true`). -/
def AllArmedInDispatching (s : CoordState) : Prop :=
  (s.phase = .dispatching ∨ s.phase = .succeeded) →
    s.armFailed = false ∧ allReported s.dstUnits s.armResults = true

/-- **Staging Lease Matches Session Armed (`LeaseMatchesSession`,
`kv_cache_manager_with_transfer.cc:640-675`,
`reshard_receive_session.cc:373-378, 408-456`)**:
For every destination unit, its `PoolStagingLease` is held if and only if its
`ReshardReceiveSession` is currently armed. -/
def LeaseMatchesSession (s : CoordState) : Prop :=
  ∀ d ∈ s.dstStates, d.stagingLeaseHeld = d.sessionArmed

/-- Combined universal invariant of `CoordState` (holds for both `.shipping` and
`.disarmAndAbandonOnFailure`). -/
structure CoordInv (s : CoordState) : Prop where
  regInv : Registry.Inv s.reg
  idleShape : IdleShape s
  claimedArming : ClaimedWhileArming s
  dispatchingShape : DispatchingShape s
  noPushEarly : NoPushBeforeAllArmed s
  allArmedDispatch : AllArmedInDispatching s
  leaseMatches : LeaseMatchesSession s

theorem init_coordInv (srcUnits dstUnits : List Nat) (claimOwner : Nat) :
    CoordInv (CoordState.init srcUnits dstUnits claimOwner) := by
  refine ⟨Registry.init_inv, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro _
    refine ⟨rfl, rfl, rfl, ?_⟩
    intro d hd
    simp only [CoordState.init, List.mem_map] at hd
    obtain ⟨u, _, rfl⟩ := hd
    exact ⟨rfl, rfl⟩
  · intro h; contradiction
  · intro h; contradiction
  · intro _
    refine ⟨rfl, ?_⟩
    intro d hd
    simp only [CoordState.init, List.mem_map] at hd
    obtain ⟨u, _, rfl⟩ := hd
    rfl
  · intro h; cases h <;> contradiction
  · intro d hd
    simp only [CoordState.init, List.mem_map] at hd
    obtain ⟨u, _, rfl⟩ := hd
    rfl

theorem step_preserves_coordInv {policy : CleanupPolicy} {s s' : CoordState} {e : Ev}
    (hinv : CoordInv s) (hstep : CoordState.step policy s e = some s') :
    CoordInv s' := by
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
      obtain ⟨hc, ho, hcomp, hdst⟩ := hinv.idleShape hphase
      obtain ⟨hc', ho', hcomp'⟩ := register_preserves_idle_reg s.reg reg' srcUnit hc ho hcomp hreg
      refine ⟨Registry.step_preserves_inv hinv.regInv hreg, ?_, ?_, ?_, ?_, ?_, hinv.leaseMatches⟩
      · intro _; exact ⟨hc', ho', hcomp', hdst⟩
      · intro h; rw [hphase] at h; contradiction
      · intro h; rw [hphase] at h; contradiction
      · intro _; exact hinv.noPushEarly (Or.inl hphase)
      · intro h; cases h with
        | inl h => rw [hphase] at h; contradiction
        | inr h => rw [hphase] at h; contradiction

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
      have hregClaimed_inv : Registry.Inv regClaimed :=
        Registry.step_preserves_inv hinv.regInv hreg
      obtain ⟨_, ho, hcomp, _⟩ := hinv.idleShape hphase
      have hclaimed := lookupAndClaim_from_idle_shape s.reg regClaimed s.claimOwner s.srcUnits ho hcomp hreg
      split at hstep
      · injection hstep with h; subst h
        refine ⟨hregClaimed_inv, ?_, ?_, ?_, ?_, ?_, hinv.leaseMatches⟩
        · intro h; contradiction
        · intro _; exact hclaimed
        · intro h; contradiction
        · intro _; exact hinv.noPushEarly (Or.inl hphase)
        · intro h; cases h <;> contradiction
      · injection hstep with h; subst h
        refine ⟨abandonIfClaimed_inv regClaimed s.claimOwner hregClaimed_inv,
          ?_, ?_, ?_, ?_, ?_, hinv.leaseMatches⟩
        · intro h; contradiction
        · intro h; contradiction
        · intro h; contradiction
        · intro h; cases h <;> contradiction
        · intro h; cases h <;> contradiction

  | armDstResult dstUnit ok =>
    dsimp only [CoordState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hphase
    simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hphase
    split at hstep
    · cases hstep
    injection hstep with h; subst h
    refine ⟨hinv.regInv, ?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro h; rw [hphase] at h; contradiction
    · intro _; exact hinv.claimedArming hphase
    · intro h; rw [hphase] at h; contradiction
    · intro _
      obtain ⟨hsend, hpush⟩ := hinv.noPushEarly (Or.inr hphase)
      refine ⟨hsend, ?_⟩
      intro d hd
      split at hd
      · simp only [List.mem_map] at hd
        obtain ⟨d0, hd0, rfl⟩ := hd
        split
        · simp [DstUnitState.arm, hpush d0 hd0]
        · exact hpush d0 hd0
      · exact hpush d hd
    · intro h; cases h with
      | inl h => rw [hphase] at h; contradiction
      | inr h => rw [hphase] at h; contradiction
    · intro d hd
      split at hd
      · simp only [List.mem_map] at hd
        obtain ⟨d0, hd0, rfl⟩ := hd
        split
        · rfl
        · exact hinv.leaseMatches d0 hd0
      · exact hinv.leaseMatches d hd

  | finishArmBarrier =>
    dsimp only [CoordState.step] at hstep
    split at hstep
    · cases hstep
    rename_i h1
    simp only [Bool.or_eq_true, not_or, bne_iff_ne, ne_eq, Decidable.not_not,
      Bool.not_eq_true, Bool.not_eq_false'] at h1
    obtain ⟨hphase, hall_rep⟩ := h1
    split at hstep
    · rename_i hno_fail
      simp only [Bool.not_eq_true'] at hno_fail
      injection hstep with h; subst h
      obtain ⟨hc, ho, _⟩ := hinv.claimedArming hphase
      refine ⟨hinv.regInv, ?_, ?_, ?_, ?_, ?_, hinv.leaseMatches⟩
      · intro h; contradiction
      · intro h; contradiction
      · intro _; exact Or.inl ⟨hc, ho⟩
      · intro h; cases h <;> contradiction
      · intro _; exact ⟨hno_fail, hall_rep⟩
    · cases policy with
      | shipping =>
        injection hstep with h; subst h
        refine ⟨abandonIfClaimed_inv s.reg s.claimOwner hinv.regInv,
          ?_, ?_, ?_, ?_, ?_, hinv.leaseMatches⟩
        · intro h; contradiction
        · intro h; contradiction
        · intro h; contradiction
        · intro h; cases h <;> contradiction
        · intro h; cases h <;> contradiction
      | disarmAndAbandonOnFailure =>
        injection hstep with h; subst h
        refine ⟨abandonIfClaimed_inv s.reg s.claimOwner hinv.regInv,
          ?_, ?_, ?_, ?_, ?_, ?_⟩
        · intro h; contradiction
        · intro h; contradiction
        · intro h; contradiction
        · intro h; cases h <;> contradiction
        · intro h; cases h <;> contradiction
        · intro d hd
          simp only [List.mem_map] at hd
          obtain ⟨d0, _, rfl⟩ := hd
          rfl

  | sendSrcResult srcUnit ok =>
    dsimp only [CoordState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hphase
    simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hphase
    split at hstep
    · cases hstep
    split at hstep
    · injection hstep with h; subst h
      have hreg_inv : Registry.Inv (match RegGen.step s.reg (.complete srcUnit) with | some r => r | none => s.reg) := by
        cases h : RegGen.step s.reg (.complete srcUnit) with
        | none => exact hinv.regInv
        | some r => exact Registry.step_preserves_inv hinv.regInv h
      have hdisp_shape :
          (let r := match RegGen.step s.reg (.complete srcUnit) with | some r => r | none => s.reg
           (r.claimedUnits = some s.srcUnits ∧ r.claimOwners = [s.claimOwner]) ∨
           (r.claimedUnits = none ∧ r.claimOwners = [])) := by
        cases h : RegGen.step s.reg (.complete srcUnit) with
        | none => exact hinv.dispatchingShape hphase
        | some r =>
          exact complete_preserves_claim_shape s.reg r srcUnit s.srcUnits s.claimOwner
            (hinv.dispatchingShape hphase) h
      refine ⟨hreg_inv, ?_, ?_, ?_, ?_, ?_, ?_⟩
      · intro h; rw [hphase] at h; contradiction
      · intro h; rw [hphase] at h; contradiction
      · intro _; exact hdisp_shape
      · intro h; cases h with
        | inl h => rw [hphase] at h; contradiction
        | inr h => rw [hphase] at h; contradiction
      · intro _; exact hinv.allArmedDispatch (Or.inl hphase)
      · intro d hd
        simp only [List.mem_map] at hd
        obtain ⟨d0, hd0, rfl⟩ := hd
        exact receivePush_leaseMatches d0 s.srcUnits srcUnit (hinv.leaseMatches d0 hd0)
    · injection hstep with h; subst h
      refine ⟨hinv.regInv, ?_, ?_, ?_, ?_, ?_, hinv.leaseMatches⟩
      · intro h; rw [hphase] at h; contradiction
      · intro h; rw [hphase] at h; contradiction
      · intro _; exact hinv.dispatchingShape hphase
      · intro h; cases h with
        | inl h => rw [hphase] at h; contradiction
        | inr h => rw [hphase] at h; contradiction
      · intro _; exact hinv.allArmedDispatch (Or.inl hphase)

  | finishSendBarrier =>
    dsimp only [CoordState.step] at hstep
    split at hstep
    · cases hstep
    rename_i h1
    simp only [Bool.or_eq_true, not_or, bne_iff_ne, ne_eq, Decidable.not_not] at h1
    obtain ⟨hphase, _⟩ := h1
    split at hstep
    · injection hstep with h; subst h
      refine ⟨hinv.regInv, ?_, ?_, ?_, ?_, ?_, hinv.leaseMatches⟩
      · intro h; contradiction
      · intro h; contradiction
      · intro h; contradiction
      · intro h; cases h <;> contradiction
      · intro _; exact hinv.allArmedDispatch (Or.inl hphase)
    · cases policy with
      | shipping =>
        injection hstep with h; subst h
        refine ⟨hinv.regInv, ?_, ?_, ?_, ?_, ?_, hinv.leaseMatches⟩
        · intro h; contradiction
        · intro h; contradiction
        · intro h; contradiction
        · intro h; cases h <;> contradiction
        · intro h; cases h <;> contradiction
      | disarmAndAbandonOnFailure =>
        injection hstep with h; subst h
        refine ⟨abandonIfClaimed_inv s.reg s.claimOwner hinv.regInv,
          ?_, ?_, ?_, ?_, ?_, ?_⟩
        · intro h; contradiction
        · intro h; contradiction
        · intro h; contradiction
        · intro h; cases h <;> contradiction
        · intro h; cases h <;> contradiction
        · intro d hd
          simp only [List.mem_map] at hd
          obtain ⟨d0, _, rfl⟩ := hd
          rfl

/-- **Main Universal Reachability Theorem (`reachable_coord_inv`)**:
Every reachable state of `CoordState.sys` (under either `.shipping` or
`.disarmAndAbandonOnFailure`) satisfies `CoordInv`. -/
theorem reachable_coord_inv {policy : CleanupPolicy} {srcUnits dstUnits : List Nat}
    {claimOwner : Nat} {s : CoordState}
    (hr : (CoordState.sys policy srcUnits dstUnits claimOwner).Reachable s) :
    CoordInv s := by
  induction hr with
  | init => exact init_coordInv srcUnits dstUnits claimOwner
  | step _ hstep ih => exact step_preserves_coordInv ih hstep

/-- **Corollary (`no_push_before_all_armed`)**:
In any reachable state, while the coordinator is in `.idle` or `.arming`, no
sender has been dispatched and no destination unit has received any push. -/
theorem no_push_before_all_armed {policy : CleanupPolicy} {srcUnits dstUnits : List Nat}
    {claimOwner : Nat} {s : CoordState}
    (hr : (CoordState.sys policy srcUnits dstUnits claimOwner).Reachable s) :
    NoPushBeforeAllArmed s :=
  (reachable_coord_inv hr).noPushEarly

/-- **Corollary (`claimed_while_arming`)**:
In any reachable state, while the coordinator is in `.arming`, the source
snapshot is claimed in `RequestBlockRegistry` (`s.reg.claimedUnits = some s.srcUnits`),
and therefore `CancelIfUnclaimed` and late `Register` calls are blocked. -/
theorem claimed_while_arming {policy : CleanupPolicy} {srcUnits dstUnits : List Nat}
    {claimOwner : Nat} {s : CoordState}
    (hr : (CoordState.sys policy srcUnits dstUnits claimOwner).Reachable s)
    (harm : s.phase = .arming) :
    s.reg.claimedUnits = some s.srcUnits ∧
    RegGen.step s.reg .cancelIfUnclaimed = some s.reg := by
  have hinv := reachable_coord_inv hr
  obtain ⟨hclaim, _, _⟩ := hinv.claimedArming harm
  refine ⟨hclaim, ?_⟩
  exact (Registry.claimed_blocks_register_and_cancel hinv.regInv hclaim 0 true).2

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

/-! ## Part V — Risk R2a & R2b Counterexamples, Happy-Path Trace, and Mutants -/

/-- **Risk R2a Counterexample Trace (`reshard_coordinator.cc:443-448`)**:
Two source units `[0, 1]` and two destination units `[10, 11]`.
During Stage 1 (receiver arming), `dst_unit 10` succeeds (`armDstResult 10 true`),
creating an active `ReshardReceiveSession` holding a `PoolStagingLease`, while
`dst_unit 11` fails (`armDstResult 11 false`).
At `finishArmBarrier`, the shipping coordinator calls `AbandonClaim` and returns
`arm_status` (`.aborted`) **without disarming `dst_unit 10`**. -/
def r2aPartialArmFailureTrace : List Ev :=
  [ .registerProducer 0
  , .registerProducer 1
  , .startPlan true
  , .armDstResult 10 true
  , .armDstResult 11 false
  , .finishArmBarrier ]

/-- Under `.shipping`, `r2aPartialArmFailureTrace` ends in `.aborted` with
`dst_unit 10` still holding `sessionArmed = true` and `stagingLeaseHeld = true`
(orphaned until `timeout_s_`). -/
theorem trace_r2a_partial_arm_orphans_armed_receiver :
    ((CoordState.sys .shipping [0, 1] [10, 11] 101).run r2aPartialArmFailureTrace).map
      (fun s =>
        ( s.phase
        , s.dstStates.map (fun d => (d.unit, d.sessionArmed, d.stagingLeaseHeld))
        , s.reg.claimedUnits )) =
      some (.aborted, [(10, true, true), (11, false, false)], none) := by
  decide

/-- **Risk R2b Counterexample Trace (`reshard_coordinator.cc:523-525`)**:
Two source units `[0, 1]` and two destination units `[10, 11]`.
Both `dst_unit 10` and `dst_unit 11` arm in Stage 1 (`finishArmBarrier` transitions
to `.dispatching`). During Stage 2 (sender dispatch), `src_unit 0` succeeds
(`sendSrcResult 0 true`), pushing to `10` and `11` and voting `Complete(0)` in
`RequestBlockRegistry`, while `src_unit 1` fails (`sendSrcResult 1 false`).
At `finishSendBarrier`, the shipping coordinator returns `sender_status`
(`.aborted`) **without disarming `dst_units` AND without calling
`registry_->AbandonClaim(args.req_id, uuid, claim_owner)`**! -/
def r2bDispatchFailureTrace : List Ev :=
  [ .registerProducer 0
  , .registerProducer 1
  , .startPlan true
  , .armDstResult 10 true
  , .armDstResult 11 true
  , .finishArmBarrier
  , .sendSrcResult 0 true
  , .sendSrcResult 1 false
  , .finishSendBarrier ]

/-- Under `.shipping`, `r2bDispatchFailureTrace` ends in `.aborted` with:
1. Both `dst_unit 10` and `dst_unit 11` orphaned with `sessionArmed = true` and
   `stagingLeaseHeld = true` (waiting for `src_unit 1`'s push until `timeout_s_`);
2. `s.reg.claimedUnits = some [0, 1]` and `s.reg.claimOwners = [101]` leaked in
   `RequestBlockRegistry` (blocking `CancelIfUnclaimed` until `ttl_s_`). -/
theorem trace_r2b_dispatch_failure_orphans_receivers_and_claim :
    ((CoordState.sys .shipping [0, 1] [10, 11] 101).run r2bDispatchFailureTrace).map
      (fun s =>
        ( s.phase
        , s.dstStates.map (fun d => (d.unit, d.sessionArmed, d.stagingLeaseHeld))
        , s.reg.claimedUnits
        , s.reg.claimOwners
        , (RegGen.step s.reg .cancelIfUnclaimed).map (fun r => r.cancelled) )) =
      some (.aborted, [(10, true, true), (11, true, true)], some [0, 1], [101], some false) := by
  rfl

/-- Under `.disarmAndAbandonOnFailure`, both `r2aPartialArmFailureTrace` and
`r2bDispatchFailureTrace` clean up all receiver sessions, staging leases, and
registry claims on abort. -/
theorem trace_r2_hardened_policy_cleans_up_both_r2a_and_r2b :
    (((CoordState.sys .disarmAndAbandonOnFailure [0, 1] [10, 11] 101).run
        r2aPartialArmFailureTrace).map
      (fun s =>
        ( s.phase
        , s.dstStates.map (fun d => (d.sessionArmed, d.stagingLeaseHeld))
        , s.reg.claimedUnits )) =
      some (.aborted, [(false, false), (false, false)], none)) ∧
    (((CoordState.sys .disarmAndAbandonOnFailure [0, 1] [10, 11] 101).run
        r2bDispatchFailureTrace).map
      (fun s =>
        ( s.phase
        , s.dstStates.map (fun d => (d.sessionArmed, d.stagingLeaseHeld))
        , s.reg.claimedUnits
        , s.reg.claimOwners )) =
      some (.aborted, [(false, false), (false, false)], none, [])) := by
  exact ⟨rfl, rfl⟩

/-- Happy-path 2x2 reshard execution trace (`reshard_coordinator.cc:400-526`):
both producers register, coordinator claims the plan, both receivers arm,
both senders push and vote `Complete`, both receivers complete and release their
staging leases, and `RequestBlockRegistry` retires the generation. -/
def coordinatorHappyTrace : List Ev :=
  [ .registerProducer 0
  , .registerProducer 1
  , .startPlan true
  , .armDstResult 10 true
  , .armDstResult 11 true
  , .finishArmBarrier
  , .sendSrcResult 0 true
  , .sendSrcResult 1 true
  , .finishSendBarrier ]

theorem trace_coordinator_happy_path :
    ((CoordState.sys .shipping [0, 1] [10, 11] 101).run coordinatorHappyTrace).map
      (fun s =>
        ( s.phase
        , s.dstStates.map (fun d => (d.unit, d.completed, d.sessionArmed, d.stagingLeaseHeld))
        , s.reg.retired
        , s.reg.claimedUnits
        , s.reg.registeredUnits )) =
      some (.succeeded, [(10, true, false, false), (11, true, false, false)], true, none, []) := by
  rfl

/-- Mutant: If Stage 2 dispatched senders without waiting for the Stage 1 join
barrier (`reshard_coordinator.cc:442-448`), a sender push arriving before
`dst_unit 11` has armed would be dropped (`d.sessionArmed = false`), leaving
`dst_unit 11` incomplete even after all senders finish. -/
def stepSendWithoutArmBarrier (s : CoordState) (srcUnit : Nat) : CoordState :=
  { s with
    dstStates := s.dstStates.map (fun d => d.receivePush s.srcUnits srcUnit)
    sendResults := (srcUnit, true) :: s.sendResults }

theorem mutant_dispatch_without_arm_barrier_drops_push :
    ((CoordState.sys .shipping [0] [10, 11] 101).run
      [.registerProducer 0, .startPlan true, .armDstResult 10 true]).map
      (fun s =>
        let s_premature := stepSendWithoutArmBarrier s 0
        s_premature.dstStates.map (fun d => (d.unit, d.completed, d.pushesReceived))) =
      some [(10, true, [0]), (11, false, [])] := by
  decide

end TpuSyncVerify.Transfer.Reshard.Coordinator
