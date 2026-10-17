import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.Session

/-!
# Reshard send session

Stage 1 of the pool-reshard model: one `ReshardSendSession` on the producer
side and the slice of `KVCacheManagerWithTransfer` that drives it
(`PoolReshardPush`, `CountPoolReshardSendSlots`, and the
`CompleteReadWithDetails` poll). Receiver sessions live in
`Reshard/Receive.lean`; multi-sender stream counting and aliased-page contents
compose both in Stage 2 (`Reshard/Pipeline.lean`).

Citations are to tpu-sync `0ac16d1`. Unqualified `.h`/`.cc` are
`tpu_sync/kv_cache/reshard_send_session.{h,cc}`; `slots.cc` is
`tpu_sync/core/pool_reshard_send_slots.cc`; `mgr.cc` is
`tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`; `base.cc` is
`tpu_sync/kv_cache/kv_cache_manager_base.cc`.

## How a reshard send runs

`PoolReshardPush` (`mgr.cc:634-671`) creates a `ReshardSendSession`
(`.cc:92-151`), which validates the plan, computes
`remaining_pool_peer_pushes_ = CountPoolReshardSendSlots(plan, schedule)`
(`.cc:134-138`, `slots.cc:27-51`), registers the active plan
(`RegisterActivePlanDirect`, `.cc:142`), and inserts the session into
`active_pool_reshard_sends_` (`mgr.cc:667`). It then calls
`ExecutePush(*this, src_block_ids)` (`mgr.cc:670`, `.cc:177-265`).

`ExecutePush` takes its own caller op (`++in_flight_; manager_ = &manager;`,
`.cc:180-184`) and iterates over `plan_.transfer_pool_indices()` (`.cc:204`):
* Pools whose group has no entries on this sender are skipped (`.cc:217-224`),
  matching `CountPoolReshardSendSlots` (`slots.cc:46-48`).
* For each active pool, `ExecutePush` acquires a per-UUID `PoolStagingLease`
  on the pool's storage (`AcquirePoolStagingLease`, `.cc:229-239`) and issues
  `base_->D2hPoolBlocks` (`.cc:240-246`). On synchronous failure of either
  step, it calls `RecordPushCompletion(manager, status)` and `EndOp()` and
  returns early (`.cc:234-238, 242-246`).
* On success, it pushes the D2H future to `d2h_futures_`, increments
  `++in_flight_` under `mu_` (`.cc:249-252`), and attaches `StartPoolPush` +
  `EndOp` to `pool_future.OnReady` (`.cc:253-261`).
* After the loop, `ExecutePush` releases its caller op via `EndOp()` (`.cc:263`).

When a pool's D2H copy completes, `StartPoolPush` (`.cc:267-349`) checks
`done_ || finalizing_` under `mu_` (`.cc:274, 315`), adds
`transfers_by_peer.size()` (the number of distinct destination peers for the
pool's group) to `in_flight_` (`.cc:318`), and dispatches one
`BlockTransport::AsyncPush` per peer (`.cc:329-348`), whose `OnReady` callback
calls `RecordPushCompletion` and `EndOp` (`.cc:342-347`).

`RecordPushCompletion` (`.cc:351-392`) returns early if `done_ || finalizing_`.
Otherwise, on the first error (`!status.ok()`) or when
`--remaining_pool_peer_pushes_ == 0`, it latches `finalizing_ = true`.
In shipping C++, `RecordPushCompletion` also sets `plan_unregistered_ = true`
and calls `manager.UnregisterActivePlan(uuid_)` immediately (`.cc:367-383`),
whereas an external `Finish(error)` (`.cc:394-410`) leaves unregistration to
`EndOp()` when `in_flight_ == 1 && finalizing_ && !done_ && !plan_unregistered_`
(`.cc:428-440`). When `EndOp()` decrements `in_flight_` to `0` while
`finalizing_`, `SettleLocked()` releases the pool staging leases and sets
`done_ = true` (`.cc:449-481`).

## State

The settle protocol `(in_flight_, finalizing_, done_, status_.ok(), !leases_released_)`
is an exact instance of `Transfer.Lifecycle` (`IsDraining()` returns
`finalizing_`, `.h:81-84`). Each active pool with `peers > 0` scheduled peer
pushes is a `SendPool := ⟨peers, stage⟩`:

| Pool stage    | C++ (`.cc:204-349`)                                                  | Holds ops in `in_flight_` | Remaining push slots |
|---------------|----------------------------------------------------------------------|---------------------------|----------------------|
| `.pending`    | not yet reached by the `ExecutePush` loop (`.cc:204`)                | `0`                       | `peers`              |
| `.d2h`        | `D2hPoolBlocks` succeeded (`++in_flight_`, `.cc:251`); `OnReady` not yet finished | `1`          | `peers`              |
| `.pushing k`  | `StartPoolPush` added `peers` ops (`.cc:318`) and released the D2H op; `k` peer `AsyncPush` callbacks remain in flight | `k` | `k` |
| `.aborted`    | D2H failed or `StartPoolPush` returned early on `done_ \|\| finalizing_` | `0`                   | `0`                  |

Session-level fields:

| Field              | C++                                                                 | Role |
|--------------------|---------------------------------------------------------------------|------|
| `pools`            | active pools in `plan_.transfer_pool_indices()` and their D2H/push state | per-pool state |
| `life`             | `in_flight_`, `finalizing_`, `done_`, `status_`, `!leases_released_` (`.h:139-148`) | `Transfer.Lifecycle` |
| `execActive`       | `ExecutePush` caller op between `++in_flight_` (`.cc:182`) and `EndOp()` (`.cc:236, 244, 263`) | caller op active |
| `remainingPushes`  | `remaining_pool_peer_pushes_` (`.h:138`)                            | remaining `(pool, peer)` completions |
| `planUnregistered` | `plan_unregistered_` (`.h:149`)                                     | active plan unregistered |
| `published`        | membership in `done_sending_` / `failed_recving_` (`mgr.cc:990`)    | what `poll_stats()` shows the engine |

## Events

| Event              | C++ |
|--------------------|-----|
| `d2hIssue p ok`    | `ExecutePush` loop body for pool `p` (`.cc:229-261`): acquires lease and calls `D2hPoolBlocks`; on failure calls `RecordPushCompletion` + `EndOp` and returns early |
| `execFinish`       | `ExecutePush` finishes its pool loop and calls `EndOp()` (`.cc:263`) |
| `d2hDone p ok`     | `pool_future.OnReady` callback (`.cc:253-261`) + `StartPoolPush` (`.cc:267-349`) + `EndOp()` (`.cc:255`) |
| `pushDone p ok`    | one peer's `AsyncPush(...).OnReady` callback for pool `p` (`.cc:342-347`): calls `RecordPushCompletion` + `EndOp()` |
| `cancel`           | external `Finish(error)`: deadline (`mgr.cc:984-987`) or shutdown (`mgr.cc:380-384`) |
| `publish`          | `CompleteReadWithDetails` moves a settled session into `done_sending_` or `failed_recving_` and erases it (`mgr.cc:988-996`) |

## Assumptions

* **A1 (non-empty schedule with positive peer counts per active pool).**
  `Create` rejects plans with `remaining_pool_peer_pushes <= 0` (`.cc:134-138`),
  and `ExecutePush` skips any pool whose group has no entries on this sender
  (`.cc:217-224`), matching `CountPoolReshardSendSlots` (`slots.cc:46-48`).
  Modeled by `validPools (init peerCounts).pools = true` (`peerCounts ≠ []` and
  `∀ n ∈ peerCounts, 0 < n`).
* **A2 (`ExecutePush` starts before external `Finish`).** `PoolReshardPush`
  inserts the session into `active_pool_reshard_sends_` (`mgr.cc:667`) and
  immediately invokes `ExecutePush` (`mgr.cc:670`), which increments
  `++in_flight_` and sets `manager_ = &manager` (`.cc:180-184`). `init` starts
  at `.cc:184` with `execActive = true` and `inFlight = 1`.
* **A3 (single `StartPoolPush` lock step).** `StartPoolPush` checks
  `done_ || finalizing_` at `.cc:274` and again at `.cc:315` when adding
  `transfers_by_peer.size()` to `in_flight_`. Since `.cc:279-311` only inspect
  immutable plan fields and `base_->transport_server()`, the two checks fold
  into `d2hDone`.
* **A4 (per-transfer connection-release window in `EndOp`).** Under
  `DataConnectionReuse::kPerTransfer`, the loop in `EndOp` (`.cc:449-467`)
  checks `in_flight_ == 1 && finalizing_ && !done_ && !connections_released_ &&
  manager_ != nullptr && !manager_->IsShuttingDown()`, latches
  `connections_released_ = true`, drops `mu_` to call
  `ReleaseDataConnectionsAfterSend(base_->transport_server(), dst_peers_, uuid_)`
  (`.cc:465-466`), and re-locks `mu_` to run `--in_flight_` and `SettleLocked()`
  (`.cc:457-461`). Because `finalizing_` is already `true` and `in_flight_` is
  `1` (held by this caller), no other op is in flight (`execActive = false` and
  `poolOps = 0`), no new op can be started, and a concurrent `Finish(error)` on
  a session with `finalizing_ == true` is a no-op (`.cc:397`), so the next loop
  iteration is guaranteed to reach `--in_flight_ == 0` and `SettleLocked()`
  with no observable change to any modelled variable.

## Properties

All proved on every reachable state (`reachable_safe`) for any valid schedule
(`validSchedule peerCounts = true`):

* **Settle safety (`SettleSafe`).** `done → inFlight = 0`.
* **No retired callback (`NoRetiredCallback`).** `done → execActive = false ∧
  poolOps pools = 0`: once settled, `ExecutePush` has returned and no D2H or
  peer push callback remains in flight.
* **Staging integrity (`StagingIntegrity`).** `hasStaging = !done`: the
  sender's `PoolStagingLease`s are released if and only if the session has
  settled (`.cc:470-481`).
* **Prompt settle (`SettlesPromptly`).** `draining → inFlight = 0 → done`.
* **No non-draining idle state (`ActiveOrDraining`).** `draining = false →
  0 < inFlight`: the session never drops to `in_flight_ == 0` before
  `finalizing_` is set.
* **Plan unregistration (`PlanIntegrity`).** `done → planUnregistered` and
  `planUnregistered → draining` under both policies; under
  `UnregisterPolicy.onSettle`, `planUnregistered = done` (`reachable_onSettle_plan_iff_done`),
  so the active plan is never torn down while sibling pools or peer pushes are
  still resolving chunks through `GetBlockChunks` (`base.cc:3222-3506`, sender
  active-plan path `:3229-3296, 3346-3433`).
* **Slot accounting & publication (`Publication`).** `published = some true →
  remainingPushes = 0 ∧ allPushed pools = true`: `done_sending` is published
  only when `CountPoolReshardSendSlots` has counted down to `0` and every active
  pool has completed its D2H copy and all of its scheduled peer pushes.
* **No op leak & termination (`NoOpLeak`, `reachable_can_settle`).** While
  `0 < inFlight`, some event in `drainEvents` is enabled, and every reachable
  state can drain to `done = true ∧ hasStaging = false ∧ planUnregistered = true`
  in finitely many steps.
-/

namespace TpuSyncVerify.Transfer.Reshard

open TpuSyncVerify.Transfer (Lifecycle)

/-- Policy for when `ReshardSendSession` unregisters its active plan:
`shipping` unregisters immediately inside `RecordPushCompletion` when
`finalizing_` is latched (`.cc:367-383`) and in `EndOp` when an externally
finished session drains its last op (`.cc:428-440`); `onSettle` always defers
unregistration to `EndOp` when `in_flight_ == 1 && finalizing_` (matching
`ReshardReceiveSession`, `reshard_receive_session.cc:685-688`). -/
inductive UnregisterPolicy where
  | shipping
  | onSettle
  deriving Repr, DecidableEq

inductive SendStage where
  | pending
  | d2h
  | pushing (active : Nat)
  | aborted
  deriving Repr, DecidableEq

namespace SendStage

/-- Number of `in_flight_` ops held by a pool in this stage. -/
def opCount : SendStage → Nat
  | .pending => 0
  | .d2h => 1
  | .pushing k => k
  | .aborted => 0

@[simp] theorem bne_self (s : SendStage) : (s != s) = false := by cases s <;> simp
@[simp] theorem beq_self (s : SendStage) : (s == s) = true := by cases s <;> simp

end SendStage

structure SendPool where
  peers : Nat
  stage : SendStage := .pending
  deriving Repr, DecidableEq

namespace SendPool

/-- Number of `(pool, peer)` completions still expected from this pool on a
non-failing run. -/
def remainingSlots (p : SendPool) : Nat :=
  match p.stage with
  | .pending | .d2h => p.peers
  | .pushing k => k
  | .aborted => 0

end SendPool

structure Send where
  pools : List SendPool
  life : Lifecycle := { inFlight := 1 }
  execActive : Bool := true
  remainingPushes : Nat
  planUnregistered : Bool := false
  published : Option Bool := none
  deriving Repr, DecidableEq

namespace Send

def sumPeers : List Nat → Nat
  | [] => 0
  | n :: ns => n + sumPeers ns

def poolOps : List SendPool → Nat
  | [] => 0
  | p :: ps => p.stage.opCount + poolOps ps

def sumRemainingSlots : List SendPool → Nat
  | [] => 0
  | p :: ps => p.remainingSlots + sumRemainingSlots ps

/-- Every pool in `pools` has positive peer count (`slots.cc:46-48`,
`.cc:134-138, 217-224`). -/
def allPosPeers (pools : List SendPool) : Bool :=
  pools.all fun p => decide (0 < p.peers)

def validPools (pools : List SendPool) : Bool :=
  !pools.isEmpty && allPosPeers pools

def validSchedule (peerCounts : List Nat) : Bool :=
  !peerCounts.isEmpty && peerCounts.all fun n => decide (0 < n)

/-- Every pool has been issued by the `ExecutePush` loop (`.cc:204-262`). -/
def allIssued (pools : List SendPool) : Bool :=
  pools.all fun p => p.stage != .pending

/-- No pool has aborted its D2H or peer push launch. -/
def noAborted (pools : List SendPool) : Bool :=
  pools.all fun p => p.stage != .aborted

/-- Every pool launched its peer pushes and all of them completed (`stage == .pushing 0`). -/
def allPushed (pools : List SendPool) : Bool :=
  pools.all fun p => p.stage == .pushing 0

/-- Initial state after `Create` (`.cc:92-151`) and the opening lock of
`ExecutePush` (`++in_flight_; manager_ = &manager;`, `.cc:180-184`). -/
def init (peerCounts : List Nat) : Send :=
  { pools := peerCounts.map fun n => { peers := n, stage := .pending }
    life := { inFlight := 1 }
    execActive := true
    remainingPushes := sumPeers peerCounts }

/-- `EndOp()` (`.cc:418-468`): if this is the last op (`in_flight_ == 1`) of a
finalizing session, unregisters the active plan before decrementing `in_flight_`
and calling `SettleLocked()`. -/
def endOp (s : Send) : Send :=
  let unreg :=
    if s.life.inFlight == 1 && s.life.draining && !s.life.done then true
    else s.planUnregistered
  { s with
    life := s.life.endOpLocked
    planUnregistered := unreg }

/-- `RecordPushCompletion` (`.cc:351-392`): on the first error or when
`--remaining_pool_peer_pushes_ == 0`, latches `finalizing_ = true` (and under
`UnregisterPolicy.shipping`, unregisters the active plan immediately). -/
def recordPushCompletion (pol : UnregisterPolicy) (ok : Bool) (s : Send) : Send :=
  if s.life.done = true ∨ s.life.draining = true then s
  else if !ok then
    { s with
      life := s.life.finishLocked false
      planUnregistered := if pol == .shipping then true else s.planUnregistered }
  else if s.remainingPushes <= 1 then
    { s with
      remainingPushes := 0
      life := s.life.finishLocked true
      planUnregistered := if pol == .shipping then true else s.planUnregistered }
  else
    { s with remainingPushes := s.remainingPushes - 1 }

inductive Ev where
  | d2hIssue (p : Nat) (ok : Bool)
  | execFinish
  | d2hDone (p : Nat) (ok : Bool)
  | pushDone (p : Nat) (ok : Bool)
  | cancel
  | publish
  deriving Repr, DecidableEq

/-- Per-pool body of `ExecutePush` (`.cc:229-261`). -/
def d2hIssue (pol : UnregisterPolicy) (p : Nat) (ok : Bool) (s : Send) : Option Send :=
  if !s.execActive then none
  else match s.pools[p]? with
  | some pool =>
    if pool.stage != .pending then none
    else if ok then
      some { s with
        pools := s.pools.set p { pool with stage := .d2h }
        life := { s.life with inFlight := s.life.inFlight + 1 } }
    else
      let s₁ := recordPushCompletion pol false
        { s with
          pools := s.pools.set p { pool with stage := .aborted }
          execActive := false }
      some (endOp s₁)
  | none => none

/-- Final `EndOp()` of `ExecutePush` after the pool loop completes (`.cc:263`). -/
def execFinish (s : Send) : Option Send :=
  if s.execActive = true ∧ allIssued s.pools = true then
    some (endOp { s with execActive := false })
  else none

/-- `pool_future.OnReady` callback (`.cc:253-261`) + `StartPoolPush`
(`.cc:267-349`) + `EndOp()` (`.cc:255`). -/
def d2hDone (pol : UnregisterPolicy) (p : Nat) (ok : Bool) (s : Send) : Option Send :=
  match s.pools[p]? with
  | some pool =>
    if pool.stage != .d2h then none
    else if !ok then
      let s₁ := recordPushCompletion pol false
        { s with pools := s.pools.set p { pool with stage := .aborted } }
      some (endOp s₁)
    else if s.life.done = true ∨ s.life.draining = true then
      some (endOp { s with pools := s.pools.set p { pool with stage := .aborted } })
    else
      some (endOp { s with
        pools := s.pools.set p { pool with stage := .pushing pool.peers }
        life := { s.life with inFlight := s.life.inFlight + pool.peers } })
  | none => none

/-- `AsyncPush(...).OnReady` callback for one peer of pool `p` (`.cc:342-347`). -/
def pushDone (pol : UnregisterPolicy) (p : Nat) (ok : Bool) (s : Send) : Option Send :=
  match s.pools[p]? with
  | some pool =>
    match pool.stage with
    | .pushing (k + 1) =>
      let s₁ := recordPushCompletion pol ok
        { s with pools := s.pools.set p { pool with stage := .pushing k } }
      some (endOp s₁)
    | _ => none
  | none => none

/-- External `Finish(error)` (`.cc:394-410`, `mgr.cc:380-384, 984-987`). -/
def cancel (s : Send) : Option Send :=
  some { s with life := s.life.finishLocked false }

/-- `CompleteReadWithDetails` publishes a settled session (`mgr.cc:988-996`). -/
def publish (s : Send) : Option Send :=
  if s.life.done = true ∧ s.published = none then
    some { s with published := some s.life.statusOk }
  else none

def step (pol : UnregisterPolicy := .shipping) (s : Send) : Ev → Option Send
  | .d2hIssue p ok => s.d2hIssue pol p ok
  | .execFinish => s.execFinish
  | .d2hDone p ok => s.d2hDone pol p ok
  | .pushDone p ok => s.pushDone pol p ok
  | .cancel => s.cancel
  | .publish => s.publish

def sys (peerCounts : List Nat) (pol : UnregisterPolicy := .shipping) : System Send Ev :=
  ⟨init peerCounts, step pol⟩

/-! ## Structural lemmas on `List SendPool` -/

theorem poolOps_init : ∀ ns : List Nat,
    poolOps (ns.map fun n => { peers := n, stage := .pending }) = 0
  | [] => rfl
  | _ :: ns => by simp [poolOps, SendStage.opCount, poolOps_init ns]

theorem sumRemainingSlots_init : ∀ ns : List Nat,
    sumRemainingSlots (ns.map fun n => { peers := n, stage := .pending }) = sumPeers ns
  | [] => rfl
  | n :: ns => by simp [sumRemainingSlots, SendPool.remainingSlots, sumPeers, sumRemainingSlots_init ns]

theorem noAborted_init : ∀ ns : List Nat,
    noAborted (ns.map fun n => { peers := n, stage := .pending }) = true
  | [] => rfl
  | _ :: _ => by simp [noAborted]

theorem validPools_init {ns : List Nat} (h : validSchedule ns = true) :
    validPools (ns.map fun n => { peers := n, stage := .pending }) = true := by
  unfold validSchedule at h
  unfold validPools allPosPeers
  rcases ns with _ | ⟨n, ns⟩
  · simp at h
  · simp only [List.isEmpty_cons, Bool.not_false, List.all_cons, Bool.true_and] at h
    simp only [List.map_cons, List.isEmpty_cons, Bool.not_false, List.all_cons, Bool.true_and,
      List.all_map]
    exact h

theorem sumPeers_pos_of_validSchedule {ns : List Nat} (h : validSchedule ns = true) :
    0 < sumPeers ns := by
  rcases ns with _ | ⟨n, ns⟩
  · simp [validSchedule] at h
  · simp only [validSchedule, List.isEmpty_cons, Bool.not_false, List.all_cons, Bool.true_and,
       Bool.and_eq_true, decide_eq_true_eq] at h
    simp only [sumPeers]
    omega

theorem allPosPeers_set {ps : List SendPool} {idx : Nat} {p : SendPool} (st : SendStage)
    (hget : ps[idx]? = some p) :
    allPosPeers (ps.set idx { p with stage := st }) = allPosPeers ps := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst q
      rfl
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      unfold allPosPeers at ih ⊢
      simp only [List.set_cons_succ, List.all_cons, ih hget]

theorem validPools_set {ps : List SendPool} {idx : Nat} {p : SendPool} (st : SendStage)
    (hget : ps[idx]? = some p) :
    validPools (ps.set idx { p with stage := st }) = validPools ps := by
  unfold validPools
  rw [allPosPeers_set st hget]
  cases ps <;> cases idx <;> rfl

theorem peers_pos_of_allPosPeers {ps : List SendPool} {idx : Nat} {p : SendPool}
    (hall : allPosPeers ps = true) (hget : ps[idx]? = some p) : 0 < p.peers := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    simp only [allPosPeers, List.all_cons, Bool.and_eq_true, decide_eq_true_eq] at hall
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst q
      exact hall.1
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      exact ih hall.2 hget

theorem poolOps_set {ps : List SendPool} {idx : Nat} {p : SendPool} (st : SendStage)
    (hget : ps[idx]? = some p) :
    poolOps (ps.set idx { p with stage := st }) + p.stage.opCount =
      poolOps ps + st.opCount ∧ p.stage.opCount ≤ poolOps ps := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst q
      simp only [List.set_cons_zero, poolOps]
      omega
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      have ⟨heq, hle⟩ := ih hget
      simp only [List.set_cons_succ, poolOps]
      omega

theorem sumRemainingSlots_set {ps : List SendPool} {idx : Nat} {p : SendPool} (st : SendStage)
    (hget : ps[idx]? = some p) :
    sumRemainingSlots (ps.set idx { p with stage := st }) + p.remainingSlots =
      sumRemainingSlots ps + ({ p with stage := st } : SendPool).remainingSlots ∧
    p.remainingSlots ≤ sumRemainingSlots ps := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst q
      simp only [List.set_cons_zero, sumRemainingSlots]
      omega
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      have ⟨heq, hle⟩ := ih hget
      simp only [List.set_cons_succ, sumRemainingSlots]
      omega

theorem allIssued_set_of_ne_pending {ps : List SendPool} {idx : Nat} {p : SendPool} {st : SendStage}
    (hget : ps[idx]? = some p) (hst : st ≠ .pending) (h : allIssued ps = true) :
    allIssued (ps.set idx { p with stage := st }) = true := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    simp only [allIssued, List.all_cons, Bool.and_eq_true] at h
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst q
      simp [allIssued, hst, h.2]
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      simp only [allIssued, List.set_cons_succ, List.all_cons, Bool.and_eq_true]
      exact ⟨h.1, ih hget h.2⟩

theorem noAborted_set_of_ne_aborted {ps : List SendPool} {idx : Nat} {p : SendPool} {st : SendStage}
    (hget : ps[idx]? = some p) (hst : st ≠ .aborted) (h : noAborted ps = true) :
    noAborted (ps.set idx { p with stage := st }) = true := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    simp only [noAborted, List.all_cons, Bool.and_eq_true] at h
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst q
      simp [noAborted, hst, h.2]
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      simp only [noAborted, List.set_cons_succ, List.all_cons, Bool.and_eq_true]
      exact ⟨h.1, ih hget h.2⟩

theorem allPushed_eq_false_of_ne {ps : List SendPool} {idx : Nat} {p : SendPool}
    (hget : ps[idx]? = some p) (hne : p.stage ≠ .pushing 0) :
    allPushed ps = false := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst q
      have hbeq : (p.stage == .pushing 0) = false := beq_false_of_ne hne
      simp [allPushed, hbeq]
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      unfold allPushed at ih ⊢
      simp [ih hget]

theorem poolOps_pos_of_sumRemainingSlots_pos :
    ∀ {ps : List SendPool}, allIssued ps = true → 0 < sumRemainingSlots ps → 0 < poolOps ps
  | [], _, h => by simp [sumRemainingSlots] at h
  | p :: ps, hiss, hsum => by
    simp only [allIssued, List.all_cons, Bool.and_eq_true, bne_iff_ne, ne_eq] at hiss
    cases hst : p.stage with
    | pending => exact absurd hst hiss.1
    | d2h => simp only [poolOps, hst, SendStage.opCount]; omega
    | pushing k =>
      cases k with
      | zero =>
        simp only [sumRemainingSlots, SendPool.remainingSlots, hst, Nat.zero_add] at hsum
        have ih := poolOps_pos_of_sumRemainingSlots_pos hiss.2 hsum
        simp only [poolOps]; omega
      | succ k =>
        simp only [poolOps, hst, SendStage.opCount]; omega
    | aborted =>
      simp only [sumRemainingSlots, SendPool.remainingSlots, hst, Nat.zero_add] at hsum
      have ih := poolOps_pos_of_sumRemainingSlots_pos hiss.2 hsum
      simp only [poolOps]; omega

theorem allPushed_of_sumRemainingSlots_zero :
    ∀ {ps : List SendPool},
      allPosPeers ps = true →
      noAborted ps = true →
      sumRemainingSlots ps = 0 →
      allPushed ps = true
  | [], _, _, _ => rfl
  | p :: ps, hpos, hno, hsum => by
    simp only [allPosPeers, List.all_cons, Bool.and_eq_true, decide_eq_true_eq] at hpos
    simp only [noAborted, List.all_cons, Bool.and_eq_true, bne_iff_ne, ne_eq] at hno
    simp only [sumRemainingSlots] at hsum
    have hp0 : p.remainingSlots = 0 := by omega
    have hps0 : sumRemainingSlots ps = 0 := by omega
    have ih := allPushed_of_sumRemainingSlots_zero hpos.2 hno.2 hps0
    cases hst : p.stage with
    | pending =>
      simp only [SendPool.remainingSlots, hst] at hp0
      omega
    | d2h =>
      simp only [SendPool.remainingSlots, hst] at hp0
      omega
    | pushing k =>
      simp only [SendPool.remainingSlots, hst] at hp0
      subst hp0
      unfold allPushed at ih ⊢
      simp [hst, ih]
    | aborted =>
      exact absurd hst hno.1

theorem exists_pending_of_allIssued_false :
    ∀ {ps : List SendPool}, allIssued ps = false →
      ∃ p < ps.length, ∃ pool, ps[p]? = some pool ∧ pool.stage = .pending
  | [], h => by simp [allIssued] at h
  | pool :: ps, h => by
    by_cases hp : pool.stage = .pending
    · exact ⟨0, by simp, pool, rfl, hp⟩
    · have hne : (pool.stage != .pending) = true := bne_iff_ne.mpr hp
      simp only [allIssued, List.all_cons, hne, Bool.true_and] at h
      obtain ⟨p, hlt, pool', hget, hp'⟩ := exists_pending_of_allIssued_false h
      exact ⟨p + 1, by simp; omega, pool', hget, hp'⟩

theorem exists_op_of_poolOps_pos :
    ∀ {ps : List SendPool}, 0 < poolOps ps →
      ∃ p < ps.length, ∃ pool, ps[p]? = some pool ∧ 0 < pool.stage.opCount
  | [], h => by simp [poolOps] at h
  | pool :: ps, h => by
    by_cases hp : 0 < pool.stage.opCount
    · exact ⟨0, by simp, pool, rfl, hp⟩
    · simp only [poolOps] at h
      have hps : 0 < poolOps ps := by omega
      obtain ⟨p, hlt, pool', hget, hp'⟩ := exists_op_of_poolOps_pos hps
      exact ⟨p + 1, by simp; omega, pool', hget, hp'⟩

/-! ## Properties -/

def SettleSafe (s : Send) : Prop := s.life.done = true → s.life.inFlight = 0

def NoRetiredCallback (s : Send) : Prop :=
  s.life.done = true → s.execActive = false ∧ poolOps s.pools = 0

def StagingIntegrity (s : Send) : Prop := s.life.hasStaging = !s.life.done

def SettlesPromptly (s : Send) : Prop :=
  s.life.draining = true → s.life.inFlight = 0 → s.life.done = true

def ActiveOrDraining (s : Send) : Prop :=
  s.life.draining = false → 0 < s.life.inFlight

def PlanIntegrity (pol : UnregisterPolicy) (s : Send) : Prop :=
  (s.life.done = true → s.planUnregistered = true) ∧
  (s.planUnregistered = true → s.life.draining = true) ∧
  (pol = .onSettle → s.planUnregistered = true → s.life.done = true)

def Publication (s : Send) : Prop :=
  s.published = some true → s.remainingPushes = 0 ∧ allPushed s.pools = true

def drainEvents (n : Nat) : List Ev :=
  [.execFinish] ++
  (List.range n).flatMap fun p => [.d2hIssue p false, .d2hDone p true, .pushDone p true]

def NoOpLeak (pol : UnregisterPolicy) (s : Send) : Prop :=
  0 < s.life.inFlight → ∃ e ∈ drainEvents s.pools.length, (step pol s e).isSome = true

def Safe (pol : UnregisterPolicy) (s : Send) : Prop :=
  SettleSafe s ∧ NoRetiredCallback s ∧ StagingIntegrity s ∧ SettlesPromptly s ∧
    ActiveOrDraining s ∧ PlanIntegrity pol s ∧ Publication s ∧ NoOpLeak pol s

/-! ## Inductive invariant -/

def Accounted (s : Send) : Prop :=
  s.life.inFlight = (if s.execActive then 1 else 0) + poolOps s.pools

structure Inv (pol : UnregisterPolicy) (s : Send) : Prop where
  valid : validPools s.pools = true
  life : s.life.Consistent
  accounted : Accounted s
  exec_pending : s.execActive = false → s.life.draining = false → allIssued s.pools = true
  not_draining : s.life.draining = false →
    s.remainingPushes = sumRemainingSlots s.pools ∧ 0 < s.remainingPushes ∧ noAborted s.pools = true
  ok_draining : s.life.statusOk = true → s.life.draining = true →
    s.remainingPushes = 0 ∧ allPushed s.pools = true
  plan_draining : s.planUnregistered = true → s.life.draining = true
  plan_onSettle : pol = .onSettle → s.planUnregistered = true → s.life.done = true
  done_plan : s.life.done = true → s.planUnregistered = true
  published_done : ∀ b, s.published = some b → s.life.done = true
  published_ok : s.published = some true → s.remainingPushes = 0 ∧ allPushed s.pools = true

theorem inv_init (pol : UnregisterPolicy) {ns : List Nat} (h : validSchedule ns = true) :
    Inv pol (init ns) := by
  refine ⟨validPools_init h, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · constructor <;> simp [init]
  · simp [init, Accounted, poolOps_init]
  · simp [init]
  · intro _
    exact ⟨(sumRemainingSlots_init ns).symm, sumPeers_pos_of_validSchedule h, noAborted_init ns⟩
  · simp [init]
  · simp [init]
  · simp [init]
  · simp [init]
  · simp [init]
  · simp [init]

theorem inv_activeOrDraining {pol : UnregisterPolicy} {s : Send} (h : Inv pol s) :
    ActiveOrDraining s := by
  intro hdr
  have hacc := h.accounted; unfold Accounted at hacc
  cases hex : s.execActive
  · have hiss := h.exec_pending hex hdr
    have ⟨hrem, hpos, _⟩ := h.not_draining hdr
    have hpo := poolOps_pos_of_sumRemainingSlots_pos hiss (by omega)
    simp [hex] at hacc
    omega
  · simp [hex] at hacc
    omega

theorem mem_drainEvents_d2hIssue {n p : Nat} (hp : p < n) :
    Ev.d2hIssue p false ∈ drainEvents n := by
  simp only [drainEvents, List.mem_append, List.mem_flatMap, List.mem_range]
  exact Or.inr ⟨p, hp, by simp⟩

theorem mem_drainEvents_d2hDone {n p : Nat} (hp : p < n) :
    Ev.d2hDone p true ∈ drainEvents n := by
  simp only [drainEvents, List.mem_append, List.mem_flatMap, List.mem_range]
  exact Or.inr ⟨p, hp, by simp⟩

theorem mem_drainEvents_pushDone {n p : Nat} (hp : p < n) :
    Ev.pushDone p true ∈ drainEvents n := by
  simp only [drainEvents, List.mem_append, List.mem_flatMap, List.mem_range]
  exact Or.inr ⟨p, hp, by simp⟩

theorem inv_noOpLeak {pol : UnregisterPolicy} {s : Send} (h : Inv pol s) : NoOpLeak pol s := by
  intro hif
  have hacc := h.accounted; unfold Accounted at hacc
  cases hex : s.execActive
  · simp only [hex, Bool.false_eq_true, ↓reduceIte, Nat.zero_add] at hacc
    obtain ⟨p, hlt, pool, hget, hop⟩ := exists_op_of_poolOps_pos (ps := s.pools) (by omega)
    cases hst : pool.stage with
    | pending | aborted => simp [hst, SendStage.opCount] at hop
    | d2h =>
      refine ⟨.d2hDone p true, mem_drainEvents_d2hDone hlt, ?_⟩
      simp only [step, d2hDone, hget, hst, SendStage.bne_self, Bool.false_eq_true, ↓reduceIte,
        Bool.not_true]
      split <;> rfl
    | pushing k =>
      cases k with
      | zero => simp [hst, SendStage.opCount] at hop
      | succ k =>
        refine ⟨.pushDone p true, mem_drainEvents_pushDone hlt, ?_⟩
        simp [step, pushDone, hget, hst]
  · cases hiss : allIssued s.pools
    · obtain ⟨p, hlt, pool, hget, hp⟩ := exists_pending_of_allIssued_false hiss
      refine ⟨.d2hIssue p false, mem_drainEvents_d2hIssue hlt, ?_⟩
      simp [step, d2hIssue, hex, hget, hp]
    · refine ⟨.execFinish, by simp [drainEvents], ?_⟩
      simp [step, execFinish, hex, hiss]

theorem inv_safe {pol : UnregisterPolicy} {s : Send} (h : Inv pol s) : Safe pol s := by
  have hacc := h.accounted; unfold Accounted at hacc
  refine ⟨h.life.done_idle, ?_, h.life.staging, h.life.prompt,
    inv_activeOrDraining h, ⟨h.done_plan, h.plan_draining, h.plan_onSettle⟩,
    h.published_ok, inv_noOpLeak h⟩
  intro hd
  have h0 := h.life.done_idle hd
  cases hex : s.execActive
  · simp only [hex, Bool.false_eq_true, ↓reduceIte] at hacc
    exact ⟨rfl, by omega⟩
  · simp only [hex, ↓reduceIte] at hacc
    omega

theorem consistent_add_inFlight_of_pos {l : Lifecycle} (h : l.Consistent)
    (hpos : 0 < l.inFlight) (k : Nat) :
    Lifecycle.Consistent { l with inFlight := l.inFlight + k } := by
  have hnd : l.done = false := by
    cases hd : l.done
    · rfl
    · have := h.done_idle hd; omega
  constructor <;> simp [hnd, h.staging]
  intro _ h0; omega

theorem endOp_inv {pol : UnregisterPolicy} {s : Send}
    (hvalid : validPools s.pools = true)
    (hlife : s.life.Consistent)
    (hpos : 0 < s.life.inFlight)
    (hacc : s.life.inFlight = (if s.execActive then 1 else 0) + poolOps s.pools + 1)
    (hex : s.execActive = false → s.life.draining = false → allIssued s.pools = true)
    (hndrain : s.life.draining = false →
      s.remainingPushes = sumRemainingSlots s.pools ∧ 0 < s.remainingPushes ∧ noAborted s.pools = true)
    (hok : s.life.statusOk = true → s.life.draining = true →
      s.remainingPushes = 0 ∧ allPushed s.pools = true)
    (hplan_dr : s.planUnregistered = true → s.life.draining = true)
    (hplan_os : pol = .onSettle → s.planUnregistered = true → s.life.done = true)
    (_hdone_pl : s.life.done = true → s.planUnregistered = true)
    (hpub_d : ∀ b, s.published = some b → s.life.done = true)
    (hpub_ok : s.published = some true → s.remainingPushes = 0 ∧ allPushed s.pools = true) :
    Inv pol (endOp s) := by
  have hnd : s.life.done = false := by
    cases hd : s.life.done
    · rfl
    · have := hlife.done_idle hd; omega
  unfold endOp
  refine ⟨hvalid, Lifecycle.endOpLocked_consistent hlife, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, hpub_ok⟩
  · unfold Accounted
    simp only [Lifecycle.endOpLocked_inFlight]
    omega
  · dsimp only
    simp only [Lifecycle.endOpLocked_draining]
    exact hex
  · dsimp only
    simp only [Lifecycle.endOpLocked_draining]
    exact hndrain
  · dsimp only
    simp only [Lifecycle.endOpLocked_statusOk, Lifecycle.endOpLocked_draining]
    exact hok
  · dsimp only
    simp only [Lifecycle.endOpLocked_draining]
    split
    · rename_i hc
      simp only [Bool.and_eq_true] at hc
      intro _; exact hc.1.2
    · exact hplan_dr
  · intro hpol
    dsimp only
    split
    · rename_i hc
      simp only [Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true'] at hc
      intro _
      unfold Lifecycle.endOpLocked
      simp [Lifecycle.settleLocked, hc.1.1, hc.1.2, hc.2]
    · intro hp
      exact Lifecycle.endOpLocked_done_mono (hplan_os hpol hp)
  · dsimp only
    split
    · intro _; rfl
    · rename_i hc
      intro hd
      unfold Lifecycle.endOpLocked Lifecycle.settleLocked at hd
      split at hd
      · simp [hnd] at hd
      · split at hd
        · rename_i hne0 hc'
          dsimp only at hc'
          exfalso
          apply hc
          simp only [Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true']
          exact ⟨⟨by omega, hc'.1⟩, hnd⟩
        · simp [hnd] at hd
  · intro b hb
    exact Lifecycle.endOpLocked_done_mono (hpub_d b hb)

theorem step_inv (pol : UnregisterPolicy) {s s' : Send} {e : Ev}
    (h : Inv pol s) (hs : step pol s e = some s') : Inv pol s' := by
  have hacc := h.accounted; unfold Accounted at hacc
  have hallPos : allPosPeers s.pools = true := by
    have hv := h.valid; unfold validPools at hv
    simp only [Bool.and_eq_true] at hv; exact hv.2
  cases e with
  | d2hIssue p ok =>
    simp only [step, d2hIssue] at hs
    split at hs
    · cases hs
    · rename_i hex
      have hex_t : s.execActive = true := by revert hex; cases s.execActive <;> simp
      have hif_pos : 0 < s.life.inFlight := by simp [hex_t] at hacc; omega
      have hnd : s.life.done = false := by
        cases hd : s.life.done
        · rfl
        · have := h.life.done_idle hd; omega
      split at hs
      · rename_i pool hget
        split at hs
        · cases hs
        · rename_i hpend
          simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hpend
          have hne_push : pool.stage ≠ .pushing 0 := by simp [hpend]
          have hallPushed_f := allPushed_eq_false_of_ne hget hne_push
          have hvalid' : validPools (s.pools.set p { pool with stage := .d2h }) = true := by
            rw [validPools_set _ hget]; exact h.valid
          have hvalid_ab : validPools (s.pools.set p { pool with stage := .aborted }) = true := by
            rw [validPools_set _ hget]; exact h.valid
          have ⟨hpo_d2h, _⟩ := poolOps_set .d2h hget
          have ⟨hpo_ab, _⟩ := poolOps_set .aborted hget
          have ⟨hrem_d2h, _⟩ := sumRemainingSlots_set .d2h hget
          split at hs
          · cases hs
            refine ⟨hvalid', consistent_add_inFlight_of_pos h.life hif_pos 1,
              ?_, ?_, ?_, ?_, h.plan_draining, h.plan_onSettle, h.done_plan,
              h.published_done, ?_⟩
            · unfold Accounted
              simp only [hex_t, ↓reduceIte] at hacc ⊢
              simp only [hpend, SendStage.opCount] at hpo_d2h
              omega
            · simp [hex_t]
            · intro hdr
              have ⟨hr, hpos, hno⟩ := h.not_draining hdr
              simp only [SendPool.remainingSlots, hpend] at hrem_d2h
              dsimp only
              exact ⟨by omega, hpos, noAborted_set_of_ne_aborted hget (by decide) hno⟩
            · intro hok hdr
              have ⟨_, hpushed⟩ := h.ok_draining hok hdr
              simp [hallPushed_f] at hpushed
            · intro hpub
              have ⟨_, hpushed⟩ := h.published_ok hpub
              simp [hallPushed_f] at hpushed
          · cases hs
            unfold recordPushCompletion
            dsimp only
            split
            · rename_i hact
              rcases hact with hd | hdr
              · simp [hnd] at hd
              · refine endOp_inv hvalid_ab h.life hif_pos ?_ ?_ ?_ ?_
                  h.plan_draining h.plan_onSettle h.done_plan h.published_done ?_
                · simp only [hex_t, ↓reduceIte] at hacc
                  simp only [hpend, SendStage.opCount] at hpo_ab
                  simp; omega
                · intro _ hdr'; dsimp only at hdr'; simp [hdr] at hdr'
                · intro hdr'; dsimp only at hdr'; simp [hdr] at hdr'
                · intro hok _
                  have ⟨_, hpushed⟩ := h.ok_draining hok hdr
                  simp [hallPushed_f] at hpushed
                · intro hpub
                  have ⟨_, hpushed⟩ := h.published_ok hpub
                  simp [hallPushed_f] at hpushed
            · rename_i hact
              simp only [not_or, Bool.not_eq_true] at hact
              obtain ⟨_, hdr⟩ := hact
              refine endOp_inv hvalid_ab (Lifecycle.finishLocked_consistent false h.life)
                ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_
              · simp [Lifecycle.finishLocked_inFlight, hif_pos]
              · simp only [hex_t, ↓reduceIte] at hacc
                simp only [hpend, SendStage.opCount] at hpo_ab
                simp [Lifecycle.finishLocked_inFlight]; omega
              · simp
              · simp
              · simp
              · simp
              · intro hpol
                simp only [hpol, beq_iff_eq, reduceCtorEq, ↓reduceIte]
                intro hp
                have hd := h.plan_onSettle hpol hp
                simp [hnd] at hd
              · intro hd
                simp only [Bool.not_false, ↓reduceIte] at hd
                rw [Lifecycle.finishLocked_done_of_inFlight _ (Nat.ne_of_gt hif_pos)] at hd
                simp [hnd] at hd
              · intro b hb
                have hd := h.published_done b hb
                simp [hnd] at hd
              · intro hpub
                have hd := h.published_done true hpub
                simp [hnd] at hd
      · cases hs
  | execFinish =>
    simp only [step, execFinish] at hs
    split at hs
    · rename_i hc
      obtain ⟨hex, hiss⟩ := hc
      cases hs
      have hif_pos : 0 < s.life.inFlight := by simp [hex] at hacc; omega
      refine endOp_inv h.valid h.life hif_pos ?_ ?_ h.not_draining h.ok_draining
        h.plan_draining h.plan_onSettle h.done_plan h.published_done h.published_ok
      · simp [hex] at hacc; simp; omega
      · intro _ _; exact hiss
    · cases hs
  | d2hDone p ok =>
    simp only [step, d2hDone] at hs
    split at hs
    · rename_i pool hget
      split at hs
      · cases hs
      · rename_i hd2h
        simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hd2h
        have hne_push : pool.stage ≠ .pushing 0 := by simp [hd2h]
        have hallPushed_f := allPushed_eq_false_of_ne hget hne_push
        have ⟨hpo_ab, hle_po⟩ := poolOps_set .aborted hget
        have ⟨hpo_pu, _⟩ := poolOps_set (.pushing pool.peers) hget
        have ⟨hrem_pu, _⟩ := sumRemainingSlots_set (.pushing pool.peers) hget
        simp only [hd2h, SendStage.opCount] at hpo_ab hpo_pu hle_po
        have hif_pos : 0 < s.life.inFlight := by omega
        have hnd : s.life.done = false := by
          cases hd : s.life.done
          · rfl
          · have := h.life.done_idle hd; omega
        have hvalid_ab : validPools (s.pools.set p { pool with stage := .aborted }) = true := by
          rw [validPools_set _ hget]; exact h.valid
        have hvalid_pu : validPools (s.pools.set p { pool with stage := .pushing pool.peers }) = true := by
          rw [validPools_set _ hget]; exact h.valid
        split at hs
        · cases hs
          unfold recordPushCompletion
          dsimp only
          split
          · rename_i hact
            rcases hact with hd | hdr
            · simp [hnd] at hd
            · refine endOp_inv hvalid_ab h.life hif_pos (by dsimp only; omega) ?_ ?_ ?_
                h.plan_draining h.plan_onSettle h.done_plan h.published_done ?_
              · intro _ hdr'; dsimp only at hdr'; simp [hdr] at hdr'
              · intro hdr'; dsimp only at hdr'; simp [hdr] at hdr'
              · intro hok _; have ⟨_, hp⟩ := h.ok_draining hok hdr; simp [hallPushed_f] at hp
              · intro hpub; have ⟨_, hp⟩ := h.published_ok hpub; simp [hallPushed_f] at hp
          · rename_i hact
            simp only [not_or, Bool.not_eq_true] at hact
            refine endOp_inv hvalid_ab (Lifecycle.finishLocked_consistent false h.life)
              ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_
            · simp [Lifecycle.finishLocked_inFlight, hif_pos]
            · simp [Lifecycle.finishLocked_inFlight]; omega
            · simp
            · simp
            · simp
            · simp
            · intro hpol
              simp only [hpol, beq_iff_eq, reduceCtorEq, ↓reduceIte]
              intro hp; have hd := h.plan_onSettle hpol hp; simp [hnd] at hd
            · intro hd
              simp only [Bool.not_false, ↓reduceIte] at hd
              rw [Lifecycle.finishLocked_done_of_inFlight _ (Nat.ne_of_gt hif_pos)] at hd
              simp [hnd] at hd
            · intro b hb; have hd := h.published_done b hb; simp [hnd] at hd
            · intro hpub; have hd := h.published_done true hpub; simp [hnd] at hd
        · split at hs
          · rename_i hact
            cases hs
            rcases hact with hd | hdr
            · simp [hnd] at hd
            · refine endOp_inv hvalid_ab h.life hif_pos (by dsimp only; omega) ?_ ?_ ?_
                h.plan_draining h.plan_onSettle h.done_plan h.published_done ?_
              · intro _ hdr'; dsimp only at hdr'; simp [hdr] at hdr'
              · intro hdr'; dsimp only at hdr'; simp [hdr] at hdr'
              · intro hok _; have ⟨_, hp⟩ := h.ok_draining hok hdr; simp [hallPushed_f] at hp
              · intro hpub; have ⟨_, hp⟩ := h.published_ok hpub; simp [hallPushed_f] at hp
          · rename_i hact
            cases hs
            simp only [not_or, Bool.not_eq_true] at hact
            obtain ⟨_, hdr⟩ := hact
            have hp_pos := peers_pos_of_allPosPeers hallPos hget
            refine endOp_inv hvalid_pu (consistent_add_inFlight_of_pos h.life hif_pos pool.peers)
              ?_ ?_ ?_ ?_ ?_ h.plan_draining h.plan_onSettle ?_ ?_ ?_
            · dsimp only; omega
            · dsimp only; omega
            · intro hex hdr'
              exact allIssued_set_of_ne_pending hget (by simp) (h.exec_pending hex hdr')
            · intro _
              have ⟨hr, hpos, hno⟩ := h.not_draining hdr
              simp only [SendPool.remainingSlots, hd2h] at hrem_pu
              dsimp only
              exact ⟨by omega, hpos, noAborted_set_of_ne_aborted hget (by simp) hno⟩
            · intro _ hdr'; dsimp only at hdr'; simp [hdr] at hdr'
            · intro hd; simp [hnd] at hd
            · intro b hb; have hd := h.published_done b hb; simp [hnd] at hd
            · intro hpub; have hd := h.published_done true hpub; simp [hnd] at hd
    · cases hs
  | pushDone p ok =>
    simp only [step, pushDone] at hs
    split at hs
    · rename_i pool hget
      split at hs
      · rename_i k hpush
        cases hs
        have hne_push : pool.stage ≠ .pushing 0 := by simp [hpush]
        have hallPushed_f := allPushed_eq_false_of_ne hget hne_push
        have ⟨hpo, hle_po⟩ := poolOps_set (.pushing k) hget
        have ⟨hrem, hle_rem⟩ := sumRemainingSlots_set (.pushing k) hget
        simp only [hpush, SendStage.opCount] at hpo hle_po
        simp only [SendPool.remainingSlots, hpush] at hrem hle_rem
        have hif_pos : 0 < s.life.inFlight := by omega
        have hnd : s.life.done = false := by
          cases hd : s.life.done
          · rfl
          · have := h.life.done_idle hd; omega
        have hvalid' : validPools (s.pools.set p { pool with stage := .pushing k }) = true := by
          rw [validPools_set _ hget]; exact h.valid
        have hallPos' : allPosPeers (s.pools.set p { pool with stage := .pushing k }) = true := by
          rw [allPosPeers_set _ hget]; exact hallPos
        unfold recordPushCompletion
        dsimp only
        split
        · rename_i hact
          rcases hact with hd | hdr
          · simp [hnd] at hd
          · refine endOp_inv hvalid' h.life hif_pos (by dsimp only; omega) ?_ ?_ ?_
              h.plan_draining h.plan_onSettle h.done_plan h.published_done ?_
            · intro _ hdr'; dsimp only at hdr'; simp [hdr] at hdr'
            · intro hdr'; dsimp only at hdr'; simp [hdr] at hdr'
            · intro hok _; have ⟨_, hp⟩ := h.ok_draining hok hdr; simp [hallPushed_f] at hp
            · intro hpub; have ⟨_, hp⟩ := h.published_ok hpub; simp [hallPushed_f] at hp
        · rename_i hact
          simp only [not_or, Bool.not_eq_true] at hact
          obtain ⟨_, hdr⟩ := hact
          have ⟨hr_eq, hr_pos, hno⟩ := h.not_draining hdr
          have hno' := noAborted_set_of_ne_aborted hget (st := .pushing k) (by simp) hno
          split
          · cases ok
            · refine endOp_inv hvalid' (Lifecycle.finishLocked_consistent false h.life)
                ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_
              · simp [Lifecycle.finishLocked_inFlight, hif_pos]
              · dsimp only; simp [Lifecycle.finishLocked_inFlight]; omega
              · simp
              · simp
              · simp
              · simp
              · intro hpol
                simp only [hpol, beq_iff_eq, reduceCtorEq, ↓reduceIte]
                intro hp; have hd := h.plan_onSettle hpol hp; simp [hnd] at hd
              · intro hd
                dsimp only at hd
                rw [Lifecycle.finishLocked_done_of_inFlight _ (Nat.ne_of_gt hif_pos)] at hd
                simp [hnd] at hd
              · intro b hb; have hd := h.published_done b hb; simp [hnd] at hd
              · intro hpub; have hd := h.published_done true hpub; simp [hnd] at hd
            · rename_i hfalse; simp at hfalse
          · split
            · rename_i hle1
              have hsum0 : sumRemainingSlots (s.pools.set p { pool with stage := .pushing k }) = 0 := by
                omega
              have hallPushed' := allPushed_of_sumRemainingSlots_zero hallPos' hno' hsum0
              refine endOp_inv hvalid' (Lifecycle.finishLocked_consistent true h.life)
                ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_ ?_
              · simp [Lifecycle.finishLocked_inFlight, hif_pos]
              · dsimp only; simp [Lifecycle.finishLocked_inFlight]; omega
              · simp
              · simp
              · intro _ _; exact ⟨rfl, hallPushed'⟩
              · simp
              · intro hpol
                simp only [hpol, beq_iff_eq, reduceCtorEq, ↓reduceIte]
                intro hp; have hd := h.plan_onSettle hpol hp; simp [hnd] at hd
              · intro hd
                dsimp only at hd
                rw [Lifecycle.finishLocked_done_of_inFlight _ (Nat.ne_of_gt hif_pos)] at hd
                simp [hnd] at hd
              · intro b hb; have hd := h.published_done b hb; simp [hnd] at hd
              · intro hpub; have hd := h.published_done true hpub; simp [hnd] at hd
            · rename_i hgt1
              refine endOp_inv hvalid' h.life hif_pos ?_ ?_ ?_ ?_
                h.plan_draining h.plan_onSettle h.done_plan h.published_done ?_
              · dsimp only; omega
              · intro hex _
                exact allIssued_set_of_ne_pending hget (by simp) (h.exec_pending hex hdr)
              · intro _
                dsimp only
                exact ⟨by omega, by omega, hno'⟩
              · intro _ hdr'; dsimp only at hdr'; simp [hdr] at hdr'
              · intro hpub; have hd := h.published_done true hpub; simp [hnd] at hd
      · cases hs
    · cases hs
  | cancel =>
    simp only [step, cancel] at hs
    cases hs
    refine ⟨h.valid, Lifecycle.finishLocked_consistent false h.life, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_,
      h.published_ok⟩
    · unfold Accounted; simpa using hacc
    · simp
    · simp
    · simp
    · simp
    · intro hpol hp
      exact Lifecycle.finishLocked_done_mono false (h.plan_onSettle hpol hp)
    · intro hd
      dsimp only at hd
      by_cases hdone : s.life.done = true
      · exact h.done_plan hdone
      · simp only [Bool.not_eq_true] at hdone
        have hif_pos : 0 < s.life.inFlight := by
          by_cases hdr : s.life.draining = true
          · cases h0 : s.life.inFlight
            · have := h.life.prompt hdr h0; simp [hdone] at this
            · omega
          · simp only [Bool.not_eq_true] at hdr
            exact inv_activeOrDraining h hdr
        rw [Lifecycle.finishLocked_done_of_inFlight _ (Nat.ne_of_gt hif_pos)] at hd
        simp [hdone] at hd
    · intro b hb
      exact Lifecycle.finishLocked_done_mono false (h.published_done b hb)
  | publish =>
    simp only [step, publish] at hs
    split at hs
    · rename_i hc
      obtain ⟨hdone, _⟩ := hc
      cases hs
      refine ⟨h.valid, h.life, h.accounted, h.exec_pending, h.not_draining, h.ok_draining,
        h.plan_draining, h.plan_onSettle, h.done_plan, fun _ _ => hdone, ?_⟩
      simp only [Option.some.injEq]
      intro hok
      exact h.ok_draining hok (h.life.done_draining hdone)
    · cases hs

theorem reachable_inv {ns : List Nat} {pol : UnregisterPolicy} {s : Send}
    (hvalid : validSchedule ns = true) (h : (sys ns pol).Reachable s) : Inv pol s :=
  (sys ns pol).reachable_induction (inv_init pol hvalid) (fun _ _ _ hi hs => step_inv pol hi hs) h

/-- Main result: every reachable reshard send session on a valid schedule
satisfies all safety properties under both `UnregisterPolicy.shipping` and
`UnregisterPolicy.onSettle`. -/
theorem reachable_safe {ns : List Nat} {pol : UnregisterPolicy} {s : Send}
    (hvalid : validSchedule ns = true) (h : (sys ns pol).Reachable s) : Safe pol s :=
  inv_safe (reachable_inv hvalid h)

/-- Under `UnregisterPolicy.onSettle`, the active plan is unregistered if and
only if the session has settled (`done = true`). -/
theorem reachable_onSettle_plan_iff_done {ns : List Nat} {s : Send}
    (hvalid : validSchedule ns = true) (h : (sys ns .onSettle).Reachable s) :
    s.planUnregistered = s.life.done := by
  have hinv := reachable_inv hvalid h
  cases hp : s.planUnregistered <;> cases hd : s.life.done
  · rfl
  · have := hinv.done_plan hd; simp [hp] at this
  · have := hinv.plan_onSettle rfl hp; simp [hd] at this
  · rfl

/-! ### Progress and eventual settlement -/

theorem drain_step (pol : UnregisterPolicy) {s : Send} (h : Inv pol s)
    (hdr : s.life.draining = true) (hnd : s.life.done = false) :
    ∃ e s', step pol s e = some s' ∧ s'.life.draining = true ∧ s'.life.inFlight < s.life.inFlight := by
  have hif : 0 < s.life.inFlight := by
    cases h0 : s.life.inFlight
    · have := h.life.prompt hdr h0; simp [hnd] at this
    · omega
  have hacc := h.accounted; unfold Accounted at hacc
  cases hex : s.execActive
  · simp only [hex, Bool.false_eq_true, ↓reduceIte, Nat.zero_add] at hacc
    obtain ⟨p, _, pool, hget, hop⟩ := exists_op_of_poolOps_pos (ps := s.pools) (by omega)
    cases hst : pool.stage with
    | pending | aborted => simp [hst, SendStage.opCount] at hop
    | d2h =>
      have hs₁ : step pol s (.d2hDone p true) =
          some (endOp { s with pools := s.pools.set p { pool with stage := .aborted } }) := by
        simp [step, d2hDone, hget, hst, hdr]
      exact ⟨.d2hDone p true, _, hs₁, by simp [endOp, hdr], by simp [endOp]; omega⟩
    | pushing k =>
      cases k with
      | zero => simp [hst, SendStage.opCount] at hop
      | succ k =>
        have hs₁ : step pol s (.pushDone p true) =
            some (endOp { s with pools := s.pools.set p { pool with stage := .pushing k } }) := by
          simp [step, pushDone, hget, hst, recordPushCompletion, hdr]
        exact ⟨.pushDone p true, _, hs₁, by simp [endOp, hdr], by simp [endOp]; omega⟩
  · cases hiss : allIssued s.pools
    · obtain ⟨p, _, pool, hget, hp⟩ := exists_pending_of_allIssued_false hiss
      have hs₁ : step pol s (.d2hIssue p false) =
          some (endOp { s with pools := s.pools.set p { pool with stage := .aborted },
                               execActive := false }) := by
        simp [step, d2hIssue, hex, hget, hp, recordPushCompletion, hdr]
      exact ⟨.d2hIssue p false, _, hs₁, by simp [endOp, hdr], by simp [endOp]; omega⟩
    · have hs₁ : step pol s .execFinish =
          some (endOp { s with execActive := false }) := by
        simp [step, execFinish, hex, hiss]
      exact ⟨.execFinish, _, hs₁, by simp [endOp, hdr], by simp [endOp]; omega⟩

theorem draining_can_settle_aux (ns : List Nat) (pol : UnregisterPolicy) :
    ∀ (k : Nat) {s : Send}, s.life.inFlight ≤ k → Inv pol s → s.life.draining = true →
      ∃ evs s', (sys ns pol).runFrom s evs = some s' ∧
        s'.life.done = true ∧ s'.life.hasStaging = false ∧ s'.planUnregistered = true
  | 0, s, hk, h, hdr => by
    have hd : s.life.done = true := h.life.prompt hdr (by omega)
    have hst : s.life.hasStaging = false := by rw [h.life.staging, hd]; rfl
    exact ⟨[], s, rfl, hd, hst, h.done_plan hd⟩
  | k + 1, s, hk, h, hdr => by
    cases hnd : s.life.done
    · obtain ⟨e, s₁, hs₁, hdr₁, hlt⟩ := drain_step pol h hdr hnd
      obtain ⟨evs, s', hrun, hd', hst', hpl'⟩ :=
        draining_can_settle_aux ns pol k (by omega) (step_inv pol h hs₁) hdr₁
      refine ⟨e :: evs, s', ?_, hd', hst', hpl'⟩
      simp only [System.runFrom, sys, List.foldlM_cons, hs₁]
      exact hrun
    · have hst : s.life.hasStaging = false := by rw [h.life.staging, hnd]; rfl
      exact ⟨[], s, rfl, hnd, hst, h.done_plan hnd⟩

/-- Every reachable reshard send session on a valid schedule can drain to
`done = true`, release its `PoolStagingLease`s (`hasStaging = false`), and
unregister its active plan (`planUnregistered = true`) in finitely many steps. -/
theorem reachable_can_settle {ns : List Nat} {pol : UnregisterPolicy} {s : Send}
    (hvalid : validSchedule ns = true) (h : (sys ns pol).Reachable s) :
    ∃ evs s', (sys ns pol).runFrom s evs = some s' ∧
      s'.life.done = true ∧ s'.life.hasStaging = false ∧ s'.planUnregistered = true := by
  have hinv := reachable_inv hvalid h
  have hcancel : step pol s .cancel = some { s with life := s.life.finishLocked false } := rfl
  have hinv₁ := step_inv pol hinv hcancel
  have hdr₁ : ({ s with life := s.life.finishLocked false } : Send).life.draining = true := by simp
  obtain ⟨evs, s', hrun, hd', hst', hpl'⟩ :=
    draining_can_settle_aux ns pol
      ({ s with life := s.life.finishLocked false } : Send).life.inFlight
      (Nat.le_refl _) hinv₁ hdr₁
  refine ⟨.cancel :: evs, s', ?_, hd', hst', hpl'⟩
  simp only [System.runFrom, sys, List.foldlM_cons, hcancel]
  exact hrun

/-! ## Replay and bounded search

Concrete traces, checked by `decide`, covering multi-pool multi-peer slot
counting (`CountPoolReshardSendSlots` in `slots.cc:27-51`),
`ReshardSendSessionTest` and `PoolReshardSendTest` parity
(`reshard_send_session_test.cc:151-277, 322-453`,
`kv_cache_manager_with_transfer_pool_reshard_test.cc:302-325`), external deadline
or cancellation unregistration in `EndOp()` (`.cc:418-468`), and the contrast
between `UnregisterPolicy.shipping` and `UnregisterPolicy.onSettle` when one
pool fails while a sibling pool is still in flight. -/

/-- Sender source-span validation (`ReshardSendSession::ValidatePlan`,
`.cc:52-90`, invoked by `ReshardSendSession::Create` at `.cc:103`;
`StridedSpanFitsRegions` in `tpu_sync/core/utils.h:322-349` and
`RegionsCoverRange` in `tpu_sync/kv_cache/pool_layout.cc:66-87, 257-274`):
- If `tokenStride = 0` or `tokenLive = 0` (flat pool), requires `0 < size` and
  `offset + size ≤ liveBytes`.
- If `0 < tokenStride` and `0 < tokenLive` (packed token-strided pool in aliased
  storage, `tpu_sync/kv_cache/pool_layout.cc:66-87`), requires `0 < size`,
  `offset + size ≤ blockStride`,
  `offset / tokenStride = (offset + size - 1) / tokenStride` (cannot cross a
  token boundary), and `(offset % tokenStride) + size ≤ tokenLive` (must lie
  within the token's live sub-region). -/
def validSenderSpan (blockStride liveBytes tokenStride tokenLive offset size : Nat) : Bool :=
  if size = 0 then false
  else if tokenStride = 0 ∨ tokenLive = 0 then
    decide (offset + size ≤ liveBytes)
  else
    decide (offset + size ≤ blockStride) &&
    decide (offset / tokenStride = (offset + size - 1) / tokenStride) &&
    decide (offset % tokenStride + size ≤ tokenLive)

/-- Replay of `ReshardSendSessionTest` (`reshard_send_session_test.cc:151-277`)
and `PoolReshardSendTest.SenderWithNoBytesForAnyTransferredPoolRefusedUpFront`
(`kv_cache_manager_with_transfer_pool_reshard_test.cc:302-325`):
1. `SenderWithNoBytesForAnyTransferredPoolRefusedUpFront`
   (`kv_cache_manager_with_transfer_pool_reshard_test.cc:302-325`) and
   `RejectsMissingIdentityAndPoolFields` (`reshard_send_session_test.cc:170-202`):
   when `CountPoolReshardSendSlots` is `0` (`ns = []` or `ns = [0]`, because the
   sender's only schedule entry targets a non-transferred pool group),
   `validSchedule` rejects the session up front (`validSchedule [0] = false`,
   `.cc:135-138`).
2. `RejectsOverflowingSenderSpan` (`reshard_send_session_test.cc:204-218`):
   an overflowing source span (modeled with `offset = 64, size = 64` on
   `liveBytes = 96`, `64 + 64 > 96`) is rejected (`false`).
3. `RejectsSenderSpanBetweenPackedTokenRegionsInAliasedStorage`
   (`reshard_send_session_test.cc:220-254`): on a token-strided pool
   (modeled with `blockStride = 256, liveBytes = 128, tokenStride = 64,
   tokenLive = 32`), span `[16, 48)` (`offset = 16, size = 32`) straddles into
   the non-live gap `[32, 64)` and is rejected (`false`), whereas `[64, 96)`
   (`offset = 64, size = 32`, token 1's live region) is accepted (`true`).
4. `AcceptsCanonicalPlanOnExplicitPools` (`reshard_send_session_test.cc:151-159`),
   `AcceptsImplicitPools` (`:161-168`), and `IgnoresReceiverCoverageGap`
   (`:256-277`): a 1-pool, 1-peer sender schedule (`ns = [1]`) is accepted
   (`validSchedule [1] = true`) and completes D2H + push to settle with
   `published = some true`. -/
theorem trace_reshard_send_session_test_parity :
    validSchedule [] = false ∧
    validSchedule [0] = false ∧
    validSenderSpan 128 96 0 0 64 64 = false ∧
    validSenderSpan 256 128 64 32 16 32 = false ∧
    validSenderSpan 256 128 64 32 64 32 = true ∧
    validSchedule [1] = true ∧
    ((sys [1]).run
      [.d2hIssue 0 true, .execFinish, .d2hDone 0 true, .pushDone 0 true, .publish]).map
      (fun r => (r.life.done, r.life.hasStaging, r.planUnregistered, r.published)) =
      some (true, false, true, some true) := by
  decide

/-- Two active pools with peer counts `[2, 1]` (`CountPoolReshardSendSlots = 3`,
e.g. an attention group pushing to 2 peers and a state group pushing to 1 peer,
`.cc:131-138`, `slots.cc:27-51`): `ExecutePush` issues both D2H copies and drops
its caller op (`execFinish`), each pool's `StartPoolPush` fans out to its
group's peers, and the session settles only when all 3 `(pool, peer)` pushes
have completed. -/
theorem trace_multi_pool_multi_peer_send :
    let s := sys [2, 1]
    -- ExecutePush issues D2H for pool 0 and pool 1, then calls EndOp (`inFlight = 2`).
    (s.run [.d2hIssue 0 true, .d2hIssue 1 true, .execFinish]).map
      (fun r => (r.pools.map SendPool.stage, r.life.inFlight, r.remainingPushes, r.life.done)) =
      some ([.d2h, .d2h], 2, 3, false) ∧
    -- Pool 0's D2H completes (`StartPoolPush` adds 2 peer ops and releases 1 D2H op: `inFlight = 3`).
    (s.run [.d2hIssue 0 true, .d2hIssue 1 true, .execFinish, .d2hDone 0 true]).map
      (fun r => (r.pools.map SendPool.stage, r.life.inFlight, r.remainingPushes)) =
      some ([.pushing 2, .d2h], 3, 3) ∧
    -- Pool 0's two peer pushes and pool 1's D2H complete (`remainingPushes = 1`, still not done).
    (s.run [.d2hIssue 0 true, .d2hIssue 1 true, .execFinish, .d2hDone 0 true,
            .pushDone 0 true, .pushDone 0 true, .d2hDone 1 true]).map
      (fun r => (r.pools.map SendPool.stage, r.life.inFlight, r.remainingPushes, r.life.done)) =
      some ([.pushing 0, .pushing 1], 1, 1, false) ∧
    -- Pool 1's peer push completes: `remainingPushes` hits 0, session settles and publishes `done_sending`.
    (s.run [.d2hIssue 0 true, .d2hIssue 1 true, .execFinish, .d2hDone 0 true,
            .pushDone 0 true, .pushDone 0 true, .d2hDone 1 true,
            .pushDone 1 true, .publish]).map
      (fun r => (r.life.done, r.life.hasStaging, r.planUnregistered, r.published)) =
      some (true, false, true, some true) := by
  decide

/-- External deadline or cancellation (`cancel` at `mgr.cc:984-987`, `.cc:394-410`)
while peer pushes are in flight (`ReshardSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsWhenCancelledMidPush`,
`reshard_send_session_test.cc:364-404`): `Finish(error)` sets `finalizing_ = true`
without unregistering the plan while `in_flight_ == 2`; the first peer push to
finish decrements `in_flight_` to `1` without unregistering; the last peer
push's `EndOp()` (`.cc:428-440`) unregisters the plan, releases the staging
leases, and settles the session. -/
theorem trace_cancel_unregisters_on_last_endOp :
    let s := sys [2]
    let pre := [.d2hIssue 0 true, .execFinish, .d2hDone 0 true, .cancel]
    -- After cancel with 2 peer pushes in flight: draining, but plan still registered and staging held.
    (s.run pre).map
      (fun r => (r.life.draining, r.life.done, r.life.inFlight, r.planUnregistered)) =
      some (true, false, 2, false) ∧
    -- First peer push finishes (`inFlight = 1`): still not done, plan still registered.
    (s.run (pre ++ [.pushDone 0 true])).map
      (fun r => (r.life.done, r.life.inFlight, r.planUnregistered, r.life.hasStaging)) =
      some (false, 1, false, true) ∧
    -- Second peer push finishes (`inFlight = 0`): `EndOp` unregisters the plan and settles.
    (s.run (pre ++ [.pushDone 0 true, .pushDone 0 true, .publish])).map
      (fun r => (r.life.done, r.planUnregistered, r.life.hasStaging, r.published)) =
      some (true, true, false, some false) := by
  decide

/-! `ReshardSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsBeforeSettling`
(`reshard_send_session_test.cc:322-362`),
`PerTransferPolicyClosesIdlePeerConnectionsWhenCancelledMidPush` (`:364-404`),
`PooledPolicyKeepsIdlePeerConnections` (`:406-435`), and
`CreateRejectsUnknownDataConnReuseValue` (`:437-453`): TCP data-connection
pooling (`TPU_RAIDEN_DATA_CONN_REUSE`,
`tpu_sync/kv_cache/data_connection_policy.{h,cc}`, `.cc:101-102, 449-467`) is
orthogonal to the session state machine; Assumption A4 above justifies folding
the per-transfer connection-release window in `EndOp` (`.cc:449-467`) into the
atomic `endOp` transition. -/

/-- Early plan unregistration on partial failure (`.cc:360-384` vs. `.cc:428-440`):
when pool 0's push fails (`pushDone 0 false`) while pool 1's push is still in
flight, `UnregisterPolicy.shipping` unregisters the active plan immediately
(`planUnregistered = true` while `done = false` and `inFlight = 1`). Under
`UnregisterPolicy.onSettle`, the plan remains registered until pool 1's op also
finishes (`planUnregistered = false` until `done = true`). -/
theorem trace_early_unregister_on_error_vs_onSettle :
    let evs := [.d2hIssue 0 true, .d2hIssue 1 true, .execFinish,
                .d2hDone 0 true, .d2hDone 1 true, .pushDone 0 false]
    -- Shipping: planUnregistered is already true while pool 1 still has 1 push in flight (`done = false`).
    ((sys [1, 1] .shipping).run evs).map
      (fun r => (r.life.done, r.life.inFlight, r.planUnregistered)) =
      some (false, 1, true) ∧
    -- onSettle: plan stays registered while pool 1 is in flight, and unregisters when pool 1 finishes.
    ((sys [1, 1] .onSettle).run evs).map
      (fun r => (r.life.done, r.life.inFlight, r.planUnregistered)) =
      some (false, 1, false) ∧
    ((sys [1, 1] .onSettle).run (evs ++ [.pushDone 1 true])).map
      (fun r => (r.life.done, r.life.inFlight, r.planUnregistered)) =
      some (true, 0, true) := by
  decide

def events (numPools : Nat) : List Ev :=
  [.execFinish, .cancel, .publish] ++
  (List.range numPools).flatMap fun p =>
    [.d2hIssue p true, .d2hIssue p false,
     .d2hDone p true, .d2hDone p false,
     .pushDone p true, .pushDone p false]

/-- Executable negation of `Safe`. -/
def violates (pol : UnregisterPolicy) (s : Send) : Bool :=
  (s.life.done && s.life.inFlight != 0) ||
  (s.life.done && (s.execActive || poolOps s.pools != 0)) ||
  (s.life.hasStaging != !s.life.done) ||
  (s.life.draining && s.life.inFlight == 0 && !s.life.done) ||
  (!s.life.draining && s.life.inFlight == 0) ||
  (s.life.done && !s.planUnregistered) ||
  (s.planUnregistered && !s.life.draining) ||
  (pol == .onSettle && s.planUnregistered && !s.life.done) ||
  (s.published == some true && !(s.remainingPushes == 0 && allPushed s.pools)) ||
  (0 < s.life.inFlight && !(drainEvents s.pools.length).any fun e => (step pol s e).isSome)

#guard ModelCheck.check (sys [2, 1] .shipping) (events 2) (violates .shipping) 8 = .outOfFuel
#guard ModelCheck.check (sys [2, 1] .onSettle) (events 2) (violates .onSettle) 8 = .outOfFuel

/-- Mutant 1 (`initOvercountedSlots`, cf. `.cc:131-133`):
initializing `remaining_pool_peer_pushes_` to `pools.size() * total_peers` (4
instead of `2 + 1 = 3`) leaves the session open with `in_flight_ == 0` and
`finalizing_ == false` after all 3 scheduled pushes complete, violating
`ActiveOrDraining`. -/
def initOvercountedSlots : Send :=
  { (init [2, 1]) with remainingPushes := 4 }

#guard (match ModelCheck.check ⟨initOvercountedSlots, step .shipping⟩
          (events 2) (violates .shipping) 9 with
        | .counterexample _ => true
        | _ => false)

/-- Mutant 2 (`endOpWithoutUnregister` / `stepWithoutEndOpUnregister`): omitting
the settle-time plan unregistration in `EndOp()` (`.cc:428-440`) leaves
`plan_unregistered_ == false` when an externally cancelled session (`cancel`)
finishes draining, violating `PlanIntegrity`. -/
def endOpWithoutUnregister (s : Send) : Send :=
  { s with life := s.life.endOpLocked }

def stepWithoutEndOpUnregister (s : Send) : Ev → Option Send
  | .execFinish =>
    if s.execActive = true ∧ allIssued s.pools = true then
      some (endOpWithoutUnregister { s with execActive := false })
    else none
  | e => step .shipping s e

#guard (match ModelCheck.check ⟨init [1], stepWithoutEndOpUnregister⟩
          (events 1) (violates .shipping) 4 with
        | .counterexample _ => true
        | _ => false)

/-- Mutant 3 (`d2hDoneLeakOnDraining`): `pool_future.OnReady` (`.cc:253-261`)
omits `EndOp()` (`.cc:255`) when `StartPoolPush` returns early on
`done_ || finalizing_` (`.cc:274, 315`), leaking the D2H op (caught by
`NoOpLeak`). -/
def d2hDoneLeakOnDraining (p : Nat) (ok : Bool) (s : Send) : Option Send :=
  match s.pools[p]? with
  | some pool =>
    if pool.stage != .d2h then none
    else if ok && (s.life.done || s.life.draining) then
      some { s with pools := s.pools.set p { pool with stage := .aborted } }
    else s.d2hDone .shipping p ok
  | none => none

#guard (match ModelCheck.check ⟨init [1], fun s e => match e with
          | .d2hDone p ok => d2hDoneLeakOnDraining p ok s
          | e => step .shipping s e⟩ (events 1) (violates .shipping) 5 with
        | .counterexample _ => true
        | _ => false)

end Send

end TpuSyncVerify.Transfer.Reshard
