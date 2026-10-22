import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.Session

/-!
# Reshard receive session

One `ReshardReceiveSession` on the destination (consumer) side and the slice of
`KVCacheManagerWithTransfer` that drives it (`PoolReshardRegisterRecv`,
`OnPoolReceived`, `begin_incoming_push`, `end_incoming_push`,
`MaybeUnregisterSettledReshardRecv`, and the `CompleteReadWithDetails` poll).
Sender sessions, multi-sender stream counting, and aliased-page memory contents
are modelled in `Reshard/Send.lean` and `Reshard/Pipeline.lean`.

Citations are to tpu-sync `2ed6f8f`. Unqualified `.h`/`.cc` are
`tpu_sync/kv_cache/reshard_receive_session.{h,cc}`; `mgr.cc` is
`tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`; `bt.cc` is
`tpu_sync/transport/block_transport.cc`; `utils.h` is
`tpu_sync/core/utils.h`.

## How a reshard receive runs

`PoolReshardRegisterRecv` (`mgr.cc:679-715`) creates a `ReshardReceiveSession`
(`.cc:351-418`), claiming the active plan (`RegisterActivePlanDirect`,
`.cc:376-377`), acquiring bounded per-UUID `PoolStagingLease`s across the
plan's destination storages (`AcquireStagingLeases`, `.cc:381-388, 420-459`),
and inserting the session into `active_pool_reshard_recvs_` (`mgr.cc:710-713`).
Each transferred pool in `expected_pool_indices_` (`.h:181`) has an order rank
in `pool_order_ranks_` (`.h:189`, `.cc:406-417`).

As incoming push streams arrive at `BlockTransport::HandleIncomingPush`
(`bt.cc:496-794`), each stream takes a receive op via `begin_incoming_push`
(`TryBeginRecvOp`, `mgr.cc:224-249`) and releases it in `end_incoming_push`
(`EndRecvOp`, `mgr.cc:250-296`). When all `expected_pushes` streams for a pool
have landed, the transport fires `OnPoolReceived(pool_idx)` (`bt.cc:788`,
`mgr.cc:180-202`, `.cc:600-612`), which records the pool in
`started_pool_indices_` (`.cc:541-552`) and calls `ExecuteEligiblePoolH2ds`
(`.cc:614-666`).

`ExecuteEligiblePoolH2ds` selects under `mu_` every started, unlaunched pool
whose strictly lower-rank prerequisite pools are all in
`completed_pool_indices_` (`CollectEligiblePoolH2dsLocked`, `.cc:554-583`),
marks them in `h2d_launched_pools_`, and adds `to_launch.size()` to `in_flight_`
(`.cc:622-623`). Outside `mu_`, it loops over `to_launch`: for each pool it
re-checks `done_ || draining_` under `mu_` (`.cc:633-638`, calling
`EndRecvOpLocked()` and skipping the upload if the session finished in the
window), dispatches `base_->H2dPoolBlocks` (`.cc:639-640`), pushes the future
into `h2d_futures_` (`.cc:651-653`), and attaches `FinishPoolH2d` +
`EndRecvOp` + `MaybeUnregisterSettledReshardRecv` to `future.OnReady`
(`.cc:654-664`).

When a pool's H2D finishes, `FinishPoolH2d` (`.cc:668-706`) calls
`RecordPoolH2dResultLocked` (`.cc:585-598`). On an intermediate OK completion
(`!finished && status.ok()`, `.cc:679-681`), it calls `ExecuteEligiblePoolH2ds`
to launch the next rank wave before the outer callback's `EndRecvOp()` releases
the completed pool's op (`.cc:659`). On the first error or when
`completed_pool_indices_ == expected_pool_indices_`, `reshard_finalizing_` is
set (`finished = true`), `network_completed_` and `should_record_duration` are
latched on success (`.cc:695-698`), and `Finish(terminal_status)` drains the
session (`.cc:700`).

## State

The settle protocol itself is `Transfer.Lifecycle` (`in_flight_`, `draining_`,
`done_`, `status_.ok()`, and `!staging_released_`). On top of it, each expected
pool is a `Pool := ⟨rank, stage⟩` in `pools : List Pool`:

| Pool stage   | C++ membership (`reshard_receive_session.h:180-190`) | Holds op in `in_flight_` |
|--------------|------------------------------------------------------|--------------------------|
| `.waiting`   | in `expected_pool_indices_`, not yet in `started_pool_indices_` | no |
| `.received`  | in `started_pool_indices_`, not yet in `h2d_launched_pools_` | no |
| `.queued`    | in `h2d_launched_pools_` after `in_flight_ += to_launch.size()` (`.cc:574, 623`), before the per-pool re-check lock (`.cc:633`) | yes |
| `.issued`    | `H2dPoolBlocks` succeeded; future in `h2d_futures_` (`.cc:652`) with `!IsReady()` | yes |
| `.ready`     | future in `h2d_futures_` has `IsReady()`, `OnReady` callback not yet completed | yes |
| `.completed` | in `completed_pool_indices_` (`.cc:592`) and `EndRecvOp` ran (`.cc:659`) | no |
| `.aborted`   | op ended without completing: skipped at re-check (`.cc:635`), or `H2dPoolBlocks`/`OnReady` failed or saw `reshard_finalizing_` | no |

Session-level fields:

| Field              | C++                                                                 | Role |
|--------------------|---------------------------------------------------------------------|------|
| `pools`            | `expected_pool_indices_`, `pool_order_ranks_`, `started_pool_indices_`, `h2d_launched_pools_`, `h2d_futures_`, `completed_pool_indices_` | per-pool state |
| `life`             | `in_flight_`, `draining_`, `done_`, `status_`, `!staging_released_` (`.h:172-177`) | `Transfer.Lifecycle` |
| `finalizing`       | `reshard_finalizing_` (`.h:178`)                                    | stops further H2D launches and results after first error or full completion |
| `networkCompleted` | `network_completed_` (`.h:173`, set at `.cc:697`)                   | latched on final pool H2D success |
| `planUnregistered` | `!unregister_on_settle_` (`.h:179`, claimed in `TakePendingUnregister` `.cc:512-520`) | active plan unregistered on settle |
| `durationRecorded` | ghost (`should_record_duration` / `RecordTransferDuration`, `.cc:696, 702-705`) | end-of-transfer latency histogram recorded |
| `published`        | membership in `done_recving_` / `failed_recving_` (`mgr.cc:1059-1060`) | what `poll_stats()` shows the engine |
| `pushes`           | ghost                                                               | incoming pushes between `TryBeginRecvOp` (`mgr.cc:245`) and `EndRecvOp` (`mgr.cc:285`) |

## Events

| Event               | C++ |
|---------------------|-----|
| `pushBegin`         | `TryBeginRecvOp` (`.h:100-105`) from `begin_incoming_push` (`mgr.cc:224-249`), called at `bt.cc:508` |
| `pushEnd ok`        | `end_incoming_push` (`mgr.cc:250-296`), called at `bt.cc:510-516, 633`. Parameterized by `PushEndPolicy`: `.finishOnError` (shipping since `fdeebcd`) calls `Finish(status)` before `EndRecvOp()` on `ok = false` (`mgr.cc:282-285`, matching `TransferReceiveSession`, `mgr.cc:267-271`), whereas `.endOpOnly` (pre-`fdeebcd`) ran `EndRecvOp()` unconditionally |
| `onPoolReceived p`  | `OnPoolReceived(pool_idx)` (`.cc:600-612`) + `ExecuteEligiblePoolH2ds` first lock (`.cc:618-624`): records `p` in `started_pool_indices_` and batch-queues every eligible started pool |
| `h2dIssue p ok`     | `ExecuteEligiblePoolH2ds` loop body for queued pool `p` (`.cc:625-665`): re-checks `done_ \|\| draining_` under `mu_` (`.cc:633-638`), otherwise dispatches `H2dPoolBlocks` |
| `h2dReady p`        | device finishes pool `p`'s H2D copy: its future in `h2d_futures_` becomes `IsReady()` |
| `h2dDone p ok`      | `future.OnReady` callback (`.cc:654-664`) calling `FinishPoolH2d` (`.cc:668-706`), `EndRecvOp`, and `MaybeUnregisterSettledReshardRecv` |
| `pollReady`         | `CompleteReadWithDetails` sees `!IsDraining() && IsReadyToComplete()` and calls `Finish()` (`mgr.cc:1047-1052`) |
| `cancel`            | external `Finish(error)`: deadline (`mgr.cc:1052-1055`), shutdown (`mgr.cc:391-395`), or `UnregisterActivePlan` (`mgr.cc:747-753`) |
| `publish`           | `CompleteReadWithDetails` moves a settled session into `done_recving_` or `failed_recving_`, claims `TakePendingUnregister`, and erases it (`mgr.cc:1058-1069`) |

## Assumptions

* **A1 (at-most-once `OnPoolReceived` per declared pool).** `BlockTransport`
  fires `OnPoolReceived(l, uuid)` only when `plan_pushes == expected_chunks`
  (`bt.cc:687-788`), and `RecordPoolReceivedLocked` rejects undeclared or
  duplicate pool indices (`.cc:541-552`). Encoded as the `onPoolReceived p`
  guard `pool.stage == .waiting`. (Discharged in `Reshard/Pipeline.lean`
  by explicit stream counting.)
* **A2 (registration before visibility).** `RegisterActivePlanDirect`
  (`.cc:376-377`) and `AcquireStagingLeases` (`.cc:381-388, 420-459`) succeed
  before the session is inserted into `active_pool_reshard_recvs_`
  (`mgr.cc:710-713`). If `AcquireStagingLeases` fails, `Create` releases the
  lease and rolls back `UnregisterActivePlanDirect` (`.cc:385-386`) before any
  hook can find the session.
* **A3 (no double end).** Each push and each H2D op ends at most once: `pushEnd`
  requires `pushes > 0`, `h2dIssue p` requires `stage == .queued`, and
  `h2dDone p` requires `stage == .ready`.
* **A4 (fold of `RecordPoolReceivedLocked` / `RecordPoolH2dResultLocked` with
  `ExecuteEligiblePoolH2ds` first lock).** Between unlocking `mu_` after
  recording a pool (`.cc:609` or `.cc:678`) and locking `mu_` in
  `ExecuteEligiblePoolH2ds` (`.cc:618`), an external `Finish` has the same
  effect as one arriving either before the event (where `.cc:619` skips
  `CollectEligiblePoolH2dsLocked`) or immediately after `.cc:624` (where the
  per-pool re-check at `.cc:634` aborts each queued pool and releases its op).

## Properties

All proved on every reachable state (`reachable_safe`), under both
`PushEndPolicy.finishOnError` (shipping) and `PushEndPolicy.endOpOnly`:

* **Settle safety (`SettleSafe`).** `done → inFlight = 0`: a settled session
  owns no in-flight push or H2D copy, as required by `.cc:630-632` and
  `.cc:685-688`.
* **No retired callback (`NoRetiredCallback`).** `done → poolOps pools = 0`:
  no pool is `.queued`, `.issued`, or `.ready` once settled, so the early return
  `if (done_) return;` in `FinishPoolH2d` (`.cc:674`) is unreachable.
* **Staging integrity (`StagingIntegrity`).** `hasStaging = !done`: the bounded
  `PoolStagingLease` is held exactly until the session settles.
* **Plan integrity (`PlanIntegrity`).** `(planUnregistered → done) ∧
  (published ≠ none → planUnregistered)`: the active transfer plan is never
  unregistered while any push or H2D copy can still resolve through it
  (`.cc:685-688`, `mgr.cc:733-740, 782-788`), and is always unregistered once
  published.
* **Prompt settle (`SettlesPromptly`).** `draining → inFlight = 0 → done`.
* **Rank-wave ordering (`RankWaveOrder`).** For every pair of pools `p, q ∈ pools`,
  if `p` has launched (`p.stage.launched = true`) and `q.rank < p.rank`, then
  `q.stage = .completed`: no higher-rank pool is ever queued, issued, or
  completed before every strictly lower-rank pool has completed its H2D upload
  (`.h:184-188`, `.cc:562-573`).
* **Readiness soundness (`ReadinessSound`).** `isReadyToComplete → allCompleted pools`:
  when `IsReadyToComplete()` holds, every expected pool has completed its H2D
  upload. Moreover, at callback granularity `pollReady` is never enabled on any
  reachable state (`reachable_pollReady_disabled`), because `FinishPoolH2d` sets
  `network_completed_ = true` at `.cc:697` immediately before calling `Finish`
  at `.cc:700` (and after latching `should_record_duration` at `.cc:696`).
* **Publication (`Publication`).** `published = some true → allCompleted pools ∧
  durationRecorded`: when `poll_stats()` reports `done_recving`, every expected
  pool has completed its H2D upload and the transfer duration metric has been
  recorded.
* **No op leak & termination (`NoOpLeak`, `reachable_can_settle`).** While
  `0 < inFlight`, some event in `drainEvents` is enabled, and every reachable
  state can drain to `done = true ∧ hasStaging = false` in a finite number of
  steps.
-/

namespace TpuSyncVerify.Transfer.Reshard

open TpuSyncVerify.Transfer (Lifecycle)

inductive PoolStage where
  | waiting
  | received
  | queued
  | issued
  | ready
  | completed
  | aborted
  deriving Repr, DecidableEq

namespace PoolStage

/-- Stages that hold one unit of `in_flight_` (from `in_flight_ += to_launch.size()`
at `.cc:623` until `EndRecvOpLocked` at `.cc:635` or `EndRecvOp` at `.cc:643, 659`). -/
def holdsOp : PoolStage → Bool
  | .queued | .issued | .ready => true
  | _ => false

/-- Stages in `h2d_launched_pools_` (`.h:190`, inserted at `.cc:574`). -/
def launched : PoolStage → Bool
  | .waiting | .received => false
  | _ => true

/-- Remaining drain steps needed for a single pool to release its in-flight op. -/
def drainSteps : PoolStage → Nat
  | .queued => 1
  | .issued => 2
  | .ready => 1
  | _ => 0

@[simp] theorem bne_self (s : PoolStage) : (s != s) = false := by cases s <;> rfl
@[simp] theorem beq_self (s : PoolStage) : (s == s) = true := by cases s <;> rfl

end PoolStage

structure Pool where
  rank : Nat
  stage : PoolStage := .waiting
  deriving Repr, DecidableEq

/-- Policy for `end_incoming_push` on `ReshardReceiveSession` (`mgr.cc:279-295`):
`finishOnError`, the shipping code since `fdeebcd` (2026-10-16, the fix for
finding F7 / R1), mirrors the `TransferReceiveSession` branch (`mgr.cc:267-271`)
by calling `Finish(status)` before `EndRecvOp()` when the incoming push failed
(`mgr.cc:282-285`); `endOpOnly` is the pre-`fdeebcd` hook, which called
`EndRecvOp()` unconditionally. Kept so `trace_r1_failed_incoming_push` still
witnesses the defect. -/
inductive PushEndPolicy where
  | finishOnError
  | endOpOnly
  deriving Repr, DecidableEq

structure Recv where
  pools : List Pool
  life : Lifecycle := {}
  finalizing : Bool := false
  networkCompleted : Bool := false
  planUnregistered : Bool := false
  durationRecorded : Bool := false
  published : Option Bool := none
  pushes : Nat := 0
  deriving Repr, DecidableEq

namespace Recv

/-- Number of pools currently holding an `in_flight_` op. -/
def poolOps : List Pool → Nat
  | [] => 0
  | p :: ps => (if p.stage.holdsOp then 1 else 0) + poolOps ps

/-- Total remaining pool drain steps across `pools`. -/
def poolDrainSteps : List Pool → Nat
  | [] => 0
  | p :: ps => p.stage.drainSteps + poolDrainSteps ps

/-- `completed_pool_indices_ == expected_pool_indices_` (`.cc:593`). -/
def allCompleted (pools : List Pool) : Bool :=
  pools.all fun p => p.stage == .completed

/-- `AllH2dDoneLocked` (`.cc:522-527`): every future pushed into `h2d_futures_`
(`.cc:652`, stage `.issued`) has become `IsReady()`. -/
def allH2dDone (pools : List Pool) : Bool :=
  pools.all fun p => p.stage != .issued

/-- Every expected pool of order rank strictly below `r` has completed its H2D
upload (`.cc:562-573`). -/
def prereqsCompleted (pools : List Pool) (r : Nat) : Bool :=
  pools.all fun q => !(q.rank < r) || q.stage == .completed

/-- Executable form of `RankWaveOrder`: every launched pool has all strictly
lower-rank pools completed. -/
def rankWaveOrder (pools : List Pool) : Bool :=
  pools.all fun p => !p.stage.launched || prereqsCompleted pools p.rank

/-- `CollectEligiblePoolH2dsLocked` pass (`.cc:554-583`): transitions every
`.received` pool satisfying `canLaunch p.rank` to `.queued` and counts how many
were launched. -/
def launchPass (canLaunch : Nat → Bool) : List Pool → List Pool × Nat
  | [] => ([], 0)
  | p :: ps =>
    let (ps', n) := launchPass canLaunch ps
    if p.stage == .received && canLaunch p.rank then
      ({ p with stage := .queued } :: ps', n + 1)
    else
      (p :: ps', n)

/-- Initial receiver armed for a plan whose transferred pools have order ranks
`ranks` (`.cc:392-418`). -/
def init (ranks : List Nat) : Recv :=
  { pools := ranks.map fun r => { rank := r, stage := .waiting } }

/-- `IsReadyToComplete` (`.cc:529-532`). -/
def isReadyToComplete (s : Recv) : Bool :=
  s.networkCompleted && allH2dDone s.pools

/-- `MaybeUnregisterSettledReshardRecv` (`mgr.cc:782-788`, `.cc:512-520`): once
`done_` is set, claims `unregister_on_settle_` and unregisters the plan. -/
def maybeUnregisterSettled (s : Recv) : Recv :=
  if s.life.done = true then { s with planUnregistered := true } else s

/-- First critical section of `ExecuteEligiblePoolH2ds` (`.cc:618-624`): if not
done, draining, or finalizing, launches all eligible `.received` pools and adds
`to_launch.size()` to `in_flight_`. -/
def launchEligible (s : Recv) : Recv :=
  if s.life.done = true ∨ s.life.draining = true ∨ s.finalizing = true then s
  else
    let (pools', k) := launchPass (prereqsCompleted s.pools) s.pools
    { s with pools := pools', life := { s.life with inFlight := s.life.inFlight + k } }

inductive Ev where
  | pushBegin
  | pushEnd (ok : Bool)
  | onPoolReceived (p : Nat)
  | h2dIssue (p : Nat) (ok : Bool)
  | h2dReady (p : Nat)
  | h2dDone (p : Nat) (ok : Bool)
  | pollReady
  | cancel
  | publish
  deriving Repr, DecidableEq

/-- `TryBeginRecvOp` (`.h:100-105`) from `begin_incoming_push` (`mgr.cc:224-249`). -/
def pushBegin (s : Recv) : Option Recv :=
  s.life.beginOp.map fun l => { s with life := l, pushes := s.pushes + 1 }

/-- `end_incoming_push` (`mgr.cc:250-296`). Under `.finishOnError` (shipping), a
failed push calls `Finish(status)` before `EndRecvOp()` (`mgr.cc:282-285`);
under `.endOpOnly` (pre-`fdeebcd`), only `EndRecvOp()` ran. If the session is now
settled, `TakePendingUnregister` unregisters the plan (`mgr.cc:287-290`). -/
def pushEnd (pol : PushEndPolicy) (ok : Bool) (s : Recv) : Option Recv :=
  if s.pushes = 0 then none
  else
    let l := if pol == .finishOnError && !ok then s.life.finishLocked false else s.life
    some (maybeUnregisterSettled { s with life := l.endOpLocked, pushes := s.pushes - 1 })

/-- `OnPoolReceived(pool_idx)` (`.cc:600-612`): records `p` in
`started_pool_indices_` (`.cc:541-552`) and calls `ExecuteEligiblePoolH2ds`. -/
def onPoolReceived (p : Nat) (s : Recv) : Option Recv :=
  match s.pools[p]? with
  | some pool =>
    if s.life.done = true ∨ pool.stage != .waiting then none
    else
      let s₁ := { s with pools := s.pools.set p { pool with stage := .received } }
      some (launchEligible s₁)
  | none => none

/-- Per-pool body of `ExecuteEligiblePoolH2ds` (`.cc:625-665`). Re-checks
`done_ || draining_` under `mu_` (`.cc:633-638`); if set, calls
`EndRecvOpLocked()` and skips the upload. Otherwise dispatches `H2dPoolBlocks`:
on synchronous failure calls `FinishPoolH2d`, `EndRecvOp`, and
`MaybeUnregisterSettledReshardRecv` (`.cc:641-647`); on success pushes the
future into `h2d_futures_` (`.cc:651-653`). -/
def h2dIssue (p : Nat) (ok : Bool) (s : Recv) : Option Recv :=
  match s.pools[p]? with
  | some pool =>
    if pool.stage != .queued then none
    else if s.life.done = true ∨ s.life.draining = true then
      some { s with
        pools := s.pools.set p { pool with stage := .aborted }
        life := s.life.endOpLocked }
    else if ok then
      some { s with pools := s.pools.set p { pool with stage := .issued } }
    else
      let l := if s.finalizing then s.life else s.life.finishLocked false
      some (maybeUnregisterSettled { s with
        pools := s.pools.set p { pool with stage := .aborted }
        finalizing := true
        life := l.endOpLocked })
  | none => none

/-- Device finishes pool `p`'s H2D copy; its future in `h2d_futures_` becomes
`IsReady()`. -/
def h2dReady (p : Nat) (s : Recv) : Option Recv :=
  match s.pools[p]? with
  | some pool =>
    if pool.stage == .issued then
      some { s with pools := s.pools.set p { pool with stage := .ready } }
    else none
  | none => none

/-- `future.OnReady` callback (`.cc:654-664`) calling `FinishPoolH2d`
(`.cc:668-706`), `EndRecvOp` (`.cc:659`), and `MaybeUnregisterSettledReshardRecv`
(`.cc:662`). -/
def h2dDone (p : Nat) (ok : Bool) (s : Recv) : Option Recv :=
  match s.pools[p]? with
  | some pool =>
    if pool.stage != .ready then none
    else if s.life.done = true then
      some (maybeUnregisterSettled { s with
        pools := s.pools.set p { pool with stage := .aborted }
        life := s.life.endOpLocked })
    else if s.finalizing = true then
      some (maybeUnregisterSettled { s with
        pools := s.pools.set p { pool with stage := .aborted }
        life := s.life.endOpLocked })
    else if !ok then
      some (maybeUnregisterSettled { s with
        pools := s.pools.set p { pool with stage := .aborted }
        finalizing := true
        life := (s.life.finishLocked false).endOpLocked })
    else
      let pools₁ := s.pools.set p { pool with stage := .completed }
      if allCompleted pools₁ then
        some (maybeUnregisterSettled { s with
          pools := pools₁
          finalizing := true
          networkCompleted := true
          durationRecorded := true
          life := (s.life.finishLocked true).endOpLocked })
      else
        let s₁ := launchEligible { s with pools := pools₁ }
        some (maybeUnregisterSettled { s₁ with life := s₁.life.endOpLocked })
  | none => none

/-- `CompleteReadWithDetails` polls a non-draining session and sees
`IsReadyToComplete()` (`mgr.cc:1047-1052`). -/
def pollReady (s : Recv) : Option Recv :=
  if s.life.draining = false ∧ isReadyToComplete s = true then
    some { s with life := s.life.finishLocked true }
  else none

/-- External `Finish(error)` (`mgr.cc:391-395, 747-753, 1052-1055`). -/
def cancel (s : Recv) : Option Recv :=
  some { s with life := s.life.finishLocked false }

/-- `CompleteReadWithDetails` publishes a settled session (`mgr.cc:1058-1069`). -/
def publish (s : Recv) : Option Recv :=
  if s.life.done = true ∧ s.published = none then
    some { s with published := some s.life.statusOk, planUnregistered := true }
  else none

def step (pol : PushEndPolicy := .finishOnError) (s : Recv) : Ev → Option Recv
  | .pushBegin => s.pushBegin
  | .pushEnd ok => s.pushEnd pol ok
  | .onPoolReceived p => s.onPoolReceived p
  | .h2dIssue p ok => s.h2dIssue p ok
  | .h2dReady p => s.h2dReady p
  | .h2dDone p ok => s.h2dDone p ok
  | .pollReady => s.pollReady
  | .cancel => s.cancel
  | .publish => s.publish

/-- System for a reshard receiver with pool order ranks `ranks` under `pol`. -/
def sys (ranks : List Nat) (pol : PushEndPolicy := .finishOnError) : System Recv Ev :=
  ⟨init ranks, step pol⟩

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

/-! ## Properties -/

def SettleSafe (s : Recv) : Prop := s.life.done = true → s.life.inFlight = 0

def NoRetiredCallback (s : Recv) : Prop := s.life.done = true → poolOps s.pools = 0

def StagingIntegrity (s : Recv) : Prop := s.life.hasStaging = !s.life.done

def PlanIntegrity (s : Recv) : Prop :=
  (s.planUnregistered = true → s.life.done = true) ∧
  (∀ b, s.published = some b → s.planUnregistered = true)

def SettlesPromptly (s : Recv) : Prop :=
  s.life.draining = true → s.life.inFlight = 0 → s.life.done = true

/-- Every launched pool has all strictly lower-rank pools completed (`.h:184-188`,
`.cc:562-573`). -/
def RankWaveOrder (s : Recv) : Prop := rankWaveOrder s.pools = true

theorem rankWaveOrder_iff {s : Recv} :
    RankWaveOrder s ↔
      ∀ p ∈ s.pools, ∀ q ∈ s.pools,
        p.stage.launched = true → q.rank < p.rank → q.stage = .completed := by
  unfold RankWaveOrder rankWaveOrder prereqsCompleted
  simp only [List.all_eq_true, Bool.or_eq_true, Bool.not_eq_true', decide_eq_false_iff_not,
    Nat.not_lt, beq_iff_eq]
  constructor
  · intro h p hp q hq hl hlt
    rcases h p hp with hnl | hpre
    · rw [hl] at hnl; cases hnl
    · rcases hpre q hq with hge | hcomp
      · omega
      · exact hcomp
  · intro h p hp
    cases hl : p.stage.launched
    · exact Or.inl rfl
    · right
      intro q hq
      by_cases hlt : q.rank < p.rank
      · exact Or.inr (h p hp q hq hl hlt)
      · exact Or.inl (by omega)

def ReadinessSound (s : Recv) : Prop :=
  isReadyToComplete s = true → allCompleted s.pools = true

def Publication (s : Recv) : Prop :=
  s.published = some true → allCompleted s.pools = true ∧ s.durationRecorded = true

/-- Events that advance or retire an in-flight operation for a receiver with `n`
pools. -/
def drainEvents (n : Nat) : List Ev :=
  [.pushEnd true] ++
  (List.range n).flatMap fun p => [.h2dIssue p true, .h2dReady p, .h2dDone p true]

def NoOpLeak (pol : PushEndPolicy) (s : Recv) : Prop :=
  0 < s.life.inFlight → ∃ e ∈ drainEvents s.pools.length, (step pol s e).isSome = true

def Safe (pol : PushEndPolicy) (s : Recv) : Prop :=
  SettleSafe s ∧ NoRetiredCallback s ∧ StagingIntegrity s ∧ PlanIntegrity s ∧
    SettlesPromptly s ∧ RankWaveOrder s ∧ ReadinessSound s ∧ Publication s ∧ NoOpLeak pol s

/-! ## Inductive invariant -/

/-- Every unit of `in_flight_` comes from an active incoming push or a pool in
`.queued`, `.issued`, or `.ready`. -/
def Accounted (s : Recv) : Prop :=
  s.life.inFlight = s.pushes + poolOps s.pools

structure Inv (s : Recv) : Prop where
  life : s.life.Consistent
  accounted : Accounted s
  rankWave : rankWaveOrder s.pools = true
  net_completed : s.networkCompleted = true →
    allCompleted s.pools = true ∧ s.durationRecorded = true ∧ s.life.draining = true
  ok_draining : s.life.statusOk = true → s.life.draining = true →
    allCompleted s.pools = true ∧ s.durationRecorded = true
  plan_done : s.planUnregistered = true → s.life.done = true
  published_done : ∀ b, s.published = some b →
    s.life.done = true ∧ s.planUnregistered = true
  published_ok : s.published = some true →
    allCompleted s.pools = true ∧ s.durationRecorded = true

theorem poolOps_init : ∀ ranks : List Nat,
    poolOps (ranks.map fun r => { rank := r, stage := .waiting }) = 0
  | [] => rfl
  | _ :: rs => by simp [poolOps, PoolStage.holdsOp, poolOps_init rs]

theorem rankWaveOrder_init (ranks : List Nat) :
    rankWaveOrder (ranks.map fun r => { rank := r, stage := .waiting }) = true := by
  unfold rankWaveOrder
  rw [List.all_eq_true]
  intro p hp
  rw [List.mem_map] at hp
  obtain ⟨r, _, rfl⟩ := hp
  rfl

theorem inv_init (ranks : List Nat) : Inv (init ranks) := by
  refine ⟨Lifecycle.consistent_init, ?_, rankWaveOrder_init ranks, ?_, ?_, ?_, ?_, ?_⟩ <;>
    simp [init, Accounted, poolOps_init]

theorem exists_holdsOp_of_poolOps_pos : ∀ {ps : List Pool}, 0 < poolOps ps →
    ∃ p < ps.length, ∃ pool, ps[p]? = some pool ∧ pool.stage.holdsOp = true
  | [], h => by simp [poolOps] at h
  | pool :: ps, h => by
    by_cases hh : pool.stage.holdsOp = true
    · exact ⟨0, by simp, pool, rfl, hh⟩
    · simp only [poolOps, hh, Bool.false_eq_true, ↓reduceIte, Nat.zero_add] at h
      obtain ⟨p, hp, pool', hget, hh'⟩ := exists_holdsOp_of_poolOps_pos h
      exact ⟨p + 1, by simp; omega, pool', hget, hh'⟩

theorem mem_drainEvents_issue {n p : Nat} (hp : p < n) :
    Ev.h2dIssue p true ∈ drainEvents n := by
  simp only [drainEvents, List.mem_append, List.mem_flatMap, List.mem_range]
  exact Or.inr ⟨p, hp, by simp⟩

theorem mem_drainEvents_ready {n p : Nat} (hp : p < n) :
    Ev.h2dReady p ∈ drainEvents n := by
  simp only [drainEvents, List.mem_append, List.mem_flatMap, List.mem_range]
  exact Or.inr ⟨p, hp, by simp⟩

theorem mem_drainEvents_done {n p : Nat} (hp : p < n) :
    Ev.h2dDone p true ∈ drainEvents n := by
  simp only [drainEvents, List.mem_append, List.mem_flatMap, List.mem_range]
  exact Or.inr ⟨p, hp, by simp⟩

theorem inv_noOpLeak (pol : PushEndPolicy) {s : Recv} (h : Inv s) : NoOpLeak pol s := by
  intro hif
  have hacc := h.accounted
  unfold Accounted at hacc
  by_cases hp : 0 < s.pushes
  · refine ⟨.pushEnd true, by simp [drainEvents], ?_⟩
    have hne : s.pushes ≠ 0 := by omega
    simp [step, pushEnd, hne]
  · have hpo : 0 < poolOps s.pools := by omega
    obtain ⟨p, hlt, pool, hget, hh⟩ := exists_holdsOp_of_poolOps_pos hpo
    cases hst : pool.stage with
    | queued =>
      refine ⟨.h2dIssue p true, mem_drainEvents_issue hlt, ?_⟩
      simp only [step, h2dIssue, hget, hst, PoolStage.bne_self, Bool.false_eq_true, ↓reduceIte]
      split <;> rfl
    | issued =>
      refine ⟨.h2dReady p, mem_drainEvents_ready hlt, ?_⟩
      simp [step, h2dReady, hget, hst]
    | ready =>
      refine ⟨.h2dDone p true, mem_drainEvents_done hlt, ?_⟩
      simp only [step, h2dDone, hget, hst, PoolStage.bne_self, Bool.false_eq_true, ↓reduceIte,
        Bool.not_true]
      split <;> try rfl
      split <;> try rfl
      split <;> rfl
    | waiting | received | completed | aborted =>
      simp [hst, PoolStage.holdsOp] at hh

theorem inv_safe (pol : PushEndPolicy) {s : Recv} (h : Inv s) : Safe pol s := by
  have hnl := inv_noOpLeak pol h
  have hacc := h.accounted
  unfold Accounted at hacc
  refine ⟨h.life.done_idle, ?_, h.life.staging,
    ⟨h.plan_done, fun b hb => (h.published_done b hb).2⟩,
    h.life.prompt, h.rankWave, ?_, h.published_ok, hnl⟩
  · intro hd
    have := h.life.done_idle hd
    omega
  · intro hrd
    simp only [isReadyToComplete, Bool.and_eq_true] at hrd
    exact (h.net_completed hrd.1).1

theorem consistent_add_inFlight {l : Lifecycle} (h : l.Consistent) (hdr : l.draining = false)
    (k : Nat) : Lifecycle.Consistent { l with inFlight := l.inFlight + k } := by
  have hnd := h.not_done hdr
  constructor <;> simp [hdr, hnd, h.staging]

theorem launchEligible_inv {s : Recv} (h : Inv s) : Inv (launchEligible s) := by
  unfold launchEligible
  split
  · exact h
  · rename_i hact
    simp only [not_or, Bool.not_eq_true] at hact
    obtain ⟨hnd, hdr, hnf⟩ := hact
    refine ⟨consistent_add_inFlight h.life hdr _, ?_,
      launchPass_preserves_rankWaveOrder s.pools h.rankWave, ?_, ?_, ?_, ?_, ?_⟩
    · unfold Accounted
      have hacc := h.accounted; unfold Accounted at hacc
      have hpo := launchPass_poolOps (prereqsCompleted s.pools) s.pools
      simp only; omega
    · intro hnet
      have ⟨_, _, hdr'⟩ := h.net_completed hnet
      simp [hdr] at hdr'
    · intro _ hdr'
      simp [hdr] at hdr'
    · intro hp
      have := h.plan_done hp
      simp [hnd] at this
    · intro b hb
      have ⟨hd, _⟩ := h.published_done b hb
      simp [hnd] at hd
    · intro hpub
      have ⟨hd, _⟩ := h.published_done true hpub
      simp [hnd] at hd

theorem maybeUnregisterSettled_inv {s : Recv} (h : Inv s) : Inv (maybeUnregisterSettled s) := by
  unfold maybeUnregisterSettled
  split
  · rename_i hd
    refine ⟨h.life, h.accounted, h.rankWave, h.net_completed, h.ok_draining,
      fun _ => hd, fun b hb => ⟨(h.published_done b hb).1, rfl⟩, h.published_ok⟩
  · exact h

theorem step_inv (pol : PushEndPolicy) {s s' : Recv} {e : Ev}
    (h : Inv s) (hs : step pol s e = some s') : Inv s' := by
  cases e with
  | pushBegin =>
    simp only [step, pushBegin, Option.map_eq_some_iff] at hs
    obtain ⟨l, hb, rfl⟩ := hs
    have hif := Lifecycle.beginOp_inFlight hb
    have hact := Lifecycle.beginOp_active hb
    have hok := Lifecycle.beginOp_statusOk hb
    have hdr := Lifecycle.beginOp_draining hb
    have hacc := h.accounted; unfold Accounted at hacc
    refine ⟨Lifecycle.beginOp_consistent h.life hb, ?_, h.rankWave, ?_, ?_, ?_, ?_, h.published_ok⟩
    · unfold Accounted; simp; omega
    · intro hnet
      have ⟨_, _, hdr'⟩ := h.net_completed hnet
      simp [hact.2] at hdr'
    · simp [hdr]
    · intro hp
      have := h.plan_done hp
      simp [hact.1] at this
    · intro b hb'
      have ⟨hd, _⟩ := h.published_done b hb'
      simp [hact.1] at hd
  | pushEnd ok =>
    simp only [step, pushEnd] at hs
    split at hs
    · cases hs
    · rename_i hne
      cases hs
      apply maybeUnregisterSettled_inv
      have hacc := h.accounted; unfold Accounted at hacc
      refine ⟨?_, ?_, h.rankWave, ?_, ?_, ?_, ?_, h.published_ok⟩
      · apply Lifecycle.endOpLocked_consistent
        split
        · exact Lifecycle.finishLocked_consistent false h.life
        · exact h.life
      · unfold Accounted
        split <;> simp <;> omega
      · intro hnet
        have ⟨hc, hd, hdr⟩ := h.net_completed hnet
        refine ⟨hc, hd, ?_⟩
        split <;> simp [hdr]
      · dsimp only
        split
        · simp
        · simp only [Lifecycle.endOpLocked_statusOk, Lifecycle.endOpLocked_draining]
          exact h.ok_draining
      · intro hp
        have hd := h.plan_done hp
        apply Lifecycle.endOpLocked_done_mono
        split <;> simp [hd, Lifecycle.finishLocked_done_mono]
      · intro b hb
        have ⟨hd, hp⟩ := h.published_done b hb
        refine ⟨?_, hp⟩
        apply Lifecycle.endOpLocked_done_mono
        split <;> simp [hd, Lifecycle.finishLocked_done_mono]
  | onPoolReceived p =>
    simp only [step, onPoolReceived] at hs
    split at hs
    · rename_i pool hget
      split at hs
      · cases hs
      · rename_i hact
        cases hs
        simp only [not_or, Bool.not_eq_true, bne_iff_ne, ne_eq, Decidable.not_not] at hact
        obtain ⟨hnd, hwait⟩ := hact
        apply launchEligible_inv
        have hne : pool.stage ≠ .completed := by simp [hwait]
        have hall_false := allCompleted_eq_false_of_ne hget hne
        refine ⟨h.life, ?_, ?_, ?_, ?_, h.plan_done, h.published_done, ?_⟩
        · unfold Accounted
          have hacc := h.accounted; unfold Accounted at hacc
          have hpo := poolOps_set_eq hget (p' := { pool with stage := .received })
            (by rw [hwait]; rfl)
          simp [hpo, hacc]
        · dsimp only
          rw [rankWaveOrder_set_same hget (by rw [hwait]; rfl) (by rw [hwait]; rfl)]
          exact h.rankWave
        · intro hnet
          have ⟨hc, _⟩ := h.net_completed hnet
          simp [hall_false] at hc
        · intro hok hdr
          have ⟨hc, _⟩ := h.ok_draining hok hdr
          simp [hall_false] at hc
        · intro hpub
          have ⟨hc, _⟩ := h.published_ok hpub
          simp [hall_false] at hc
    · cases hs
  | h2dIssue p ok =>
    simp only [step, h2dIssue] at hs
    split at hs
    · rename_i pool hget
      split at hs
      · cases hs
      · rename_i hq
        simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hq
        have hne : pool.stage ≠ .completed := by simp [hq]
        have hall_false := allCompleted_eq_false_of_ne hget hne
        have hacc := h.accounted; unfold Accounted at hacc
        split at hs
        · cases hs
          have ⟨hpo, hpos⟩ := poolOps_set_drop hget (p' := { pool with stage := .aborted })
            (by rw [hq]; rfl) rfl
          refine ⟨Lifecycle.endOpLocked_consistent h.life, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
          · unfold Accounted; simp; omega
          · dsimp only
            rw [rankWaveOrder_set_same hget (by rw [hq]; rfl) (by rw [hq]; rfl)]
            exact h.rankWave
          · intro hnet; have ⟨hc, _⟩ := h.net_completed hnet; simp [hall_false] at hc
          · dsimp only
            simp only [Lifecycle.endOpLocked_statusOk, Lifecycle.endOpLocked_draining]
            intro hok hdr; have ⟨hc, _⟩ := h.ok_draining hok hdr; simp [hall_false] at hc
          · exact fun hp => Lifecycle.endOpLocked_done_mono (h.plan_done hp)
          · exact fun b hb => ⟨Lifecycle.endOpLocked_done_mono (h.published_done b hb).1,
              (h.published_done b hb).2⟩
          · intro hpub; have ⟨hc, _⟩ := h.published_ok hpub; simp [hall_false] at hc
        · rename_i hact
          simp only [not_or, Bool.not_eq_true] at hact
          obtain ⟨hnd, hdr⟩ := hact
          split at hs
          · cases hs
            have hpo := poolOps_set_eq hget (p' := { pool with stage := .issued })
              (by rw [hq]; rfl)
            refine ⟨h.life, ?_, ?_, ?_, ?_, h.plan_done, h.published_done, ?_⟩
            · unfold Accounted; simp [hpo, hacc]
            · dsimp only
              rw [rankWaveOrder_set_same hget (by rw [hq]; rfl) (by rw [hq]; rfl)]
              exact h.rankWave
            · intro hnet; have ⟨hc, _⟩ := h.net_completed hnet; simp [hall_false] at hc
            · intro _ hdr'; simp [hdr] at hdr'
            · intro hpub; have ⟨hc, _⟩ := h.published_ok hpub; simp [hall_false] at hc
          · cases hs
            apply maybeUnregisterSettled_inv
            have ⟨hpo, hpos⟩ := poolOps_set_drop hget (p' := { pool with stage := .aborted })
              (by rw [hq]; rfl) rfl
            refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
            · apply Lifecycle.endOpLocked_consistent
              split
              · exact h.life
              · exact Lifecycle.finishLocked_consistent false h.life
            · unfold Accounted; split <;> simp <;> omega
            · dsimp only
              rw [rankWaveOrder_set_same hget (by rw [hq]; rfl) (by rw [hq]; rfl)]
              exact h.rankWave
            · intro hnet; have ⟨hc, _⟩ := h.net_completed hnet; simp [hall_false] at hc
            · split
              · intro _ hdr'; simp [hdr] at hdr'
              · simp
            · intro hp; have := h.plan_done hp; simp [hnd] at this
            · intro b hb; have ⟨hd, _⟩ := h.published_done b hb; simp [hnd] at hd
            · intro hpub; have ⟨hc, _⟩ := h.published_ok hpub; simp [hall_false] at hc
    · cases hs
  | h2dReady p =>
    simp only [step, h2dReady] at hs
    split at hs
    · rename_i pool hget
      split at hs
      · rename_i his
        cases hs
        simp only [beq_iff_eq] at his
        have hne : pool.stage ≠ .completed := by simp [his]
        have hall_false := allCompleted_eq_false_of_ne hget hne
        have hacc := h.accounted; unfold Accounted at hacc
        have hpo := poolOps_set_eq hget (p' := { pool with stage := .ready })
          (by rw [his]; rfl)
        refine ⟨h.life, ?_, ?_, ?_, ?_, h.plan_done, h.published_done, ?_⟩
        · unfold Accounted; simp [hpo, hacc]
        · dsimp only
          rw [rankWaveOrder_set_same hget (by rw [his]; rfl) (by rw [his]; rfl)]
          exact h.rankWave
        · intro hnet; have ⟨hc, _⟩ := h.net_completed hnet; simp [hall_false] at hc
        · intro hok hdr; have ⟨hc, _⟩ := h.ok_draining hok hdr; simp [hall_false] at hc
        · intro hpub; have ⟨hc, _⟩ := h.published_ok hpub; simp [hall_false] at hc
      · cases hs
    · cases hs
  | h2dDone p ok =>
    simp only [step, h2dDone] at hs
    split at hs
    · rename_i pool hget
      split at hs
      · cases hs
      · rename_i hrd
        simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hrd
        have hne : pool.stage ≠ .completed := by simp [hrd]
        have hall_false := allCompleted_eq_false_of_ne hget hne
        have hacc := h.accounted; unfold Accounted at hacc
        have ⟨hpo, hpos⟩ := poolOps_set_drop hget (p' := { pool with stage := .aborted })
          (by rw [hrd]; rfl) rfl
        split at hs
        · rename_i hd
          have h0 := h.life.done_idle hd
          omega
        · rename_i hnd
          simp only [Bool.not_eq_true] at hnd
          split at hs
          · cases hs
            apply maybeUnregisterSettled_inv
            refine ⟨Lifecycle.endOpLocked_consistent h.life, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
            · unfold Accounted; simp; omega
            · dsimp only
              rw [rankWaveOrder_set_same hget (by rw [hrd]; rfl) (by rw [hrd]; rfl)]
              exact h.rankWave
            · intro hnet; have ⟨hc, _⟩ := h.net_completed hnet; simp [hall_false] at hc
            · dsimp only
              simp only [Lifecycle.endOpLocked_statusOk, Lifecycle.endOpLocked_draining]
              intro hok hdr; have ⟨hc, _⟩ := h.ok_draining hok hdr; simp [hall_false] at hc
            · intro hp; have := h.plan_done hp; simp [hnd] at this
            · intro b hb; have ⟨hd, _⟩ := h.published_done b hb; simp [hnd] at hd
            · intro hpub; have ⟨hc, _⟩ := h.published_ok hpub; simp [hall_false] at hc
          · rename_i hnf
            simp only [Bool.not_eq_true] at hnf
            split at hs
            · cases hs
              apply maybeUnregisterSettled_inv
              refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishLocked_consistent false h.life),
                ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
              · unfold Accounted; simp; omega
              · dsimp only
                rw [rankWaveOrder_set_same hget (by rw [hrd]; rfl) (by rw [hrd]; rfl)]
                exact h.rankWave
              · intro hnet; have ⟨hc, _⟩ := h.net_completed hnet; simp [hall_false] at hc
              · simp
              · intro hp; have := h.plan_done hp; simp [hnd] at this
              · intro b hb; have ⟨hd, _⟩ := h.published_done b hb; simp [hnd] at hd
              · intro hpub; have ⟨hc, _⟩ := h.published_ok hpub; simp [hall_false] at hc
            · have ⟨hpo_c, _⟩ := poolOps_set_drop hget (p' := { pool with stage := .completed })
                (by simp [hrd, PoolStage.holdsOp]) rfl
              have hrw_c := rankWaveOrder_set_completed hget (by simp [hrd, PoolStage.launched])
                h.rankWave
              split at hs
              · rename_i hall_c
                cases hs
                apply maybeUnregisterSettled_inv
                refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishLocked_consistent true h.life),
                  ?_, hrw_c, ?_, ?_, ?_, ?_, ?_⟩
                · unfold Accounted; simp; omega
                · intro _; exact ⟨hall_c, rfl, by simp⟩
                · intro _ _; exact ⟨hall_c, rfl⟩
                · intro hp; have := h.plan_done hp; simp [hnd] at this
                · intro b hb; have ⟨hd, _⟩ := h.published_done b hb; simp [hnd] at hd
                · intro hpub; have ⟨hc, _⟩ := h.published_ok hpub; simp [hall_false] at hc
              · rename_i hnot_all
                cases hs
                simp only [Bool.not_eq_true] at hnot_all
                apply maybeUnregisterSettled_inv
                unfold launchEligible
                split
                · rename_i hact
                  refine ⟨Lifecycle.endOpLocked_consistent h.life, ?_, hrw_c, ?_, ?_, ?_, ?_, ?_⟩
                  · unfold Accounted; simp; omega
                  · intro hnet; have ⟨hc, _⟩ := h.net_completed hnet; simp [hall_false] at hc
                  · dsimp only
                    simp only [Lifecycle.endOpLocked_statusOk, Lifecycle.endOpLocked_draining]
                    intro hok hdr; have ⟨hc, _⟩ := h.ok_draining hok hdr; simp [hall_false] at hc
                  · intro hp; have := h.plan_done hp; simp [hnd] at this
                  · intro b hb; have ⟨hd, _⟩ := h.published_done b hb; simp [hnd] at hd
                  · intro hpub; have ⟨hc, _⟩ := h.published_ok hpub; simp [hall_false] at hc
                · rename_i hact
                  simp only [not_or, Bool.not_eq_true] at hact
                  obtain ⟨_, hdr, _⟩ := hact
                  have hpo_l := launchPass_poolOps
                    (prereqsCompleted (s.pools.set p { pool with stage := .completed }))
                    (s.pools.set p { pool with stage := .completed })
                  have hrw_l := launchPass_preserves_rankWaveOrder
                    (s.pools.set p { pool with stage := .completed }) hrw_c
                  refine ⟨Lifecycle.endOpLocked_consistent
                      (consistent_add_inFlight h.life hdr _),
                    ?_, hrw_l, ?_, ?_, ?_, ?_, ?_⟩
                  · unfold Accounted; dsimp only; simp only [Lifecycle.endOpLocked_inFlight]; omega
                  · intro hnet; have ⟨hc, _⟩ := h.net_completed hnet; simp [hall_false] at hc
                  · intro _ hdr'; simp [hdr] at hdr'
                  · intro hp; have := h.plan_done hp; simp [hnd] at this
                  · intro b hb; have ⟨hd, _⟩ := h.published_done b hb; simp [hnd] at hd
                  · intro hpub; have ⟨hc, _⟩ := h.published_ok hpub; simp [hall_false] at hc
    · cases hs
  | pollReady =>
    simp only [step, pollReady] at hs
    split at hs
    · rename_i hrd
      obtain ⟨hdr, hready⟩ := hrd
      simp only [isReadyToComplete, Bool.and_eq_true] at hready
      have ⟨_, _, hdr'⟩ := h.net_completed hready.1
      simp [hdr] at hdr'
    · cases hs
  | cancel =>
    simp only [step, cancel] at hs
    cases hs
    have hacc := h.accounted; unfold Accounted at hacc
    refine ⟨Lifecycle.finishLocked_consistent false h.life, ?_, h.rankWave, ?_, ?_, ?_, ?_,
      h.published_ok⟩
    · unfold Accounted; simpa using hacc
    · intro hnet
      have ⟨hc, hd, _⟩ := h.net_completed hnet
      exact ⟨hc, hd, by simp⟩
    · simp
    · exact fun hp => Lifecycle.finishLocked_done_mono false (h.plan_done hp)
    · exact fun b hb => ⟨Lifecycle.finishLocked_done_mono false (h.published_done b hb).1,
        (h.published_done b hb).2⟩
  | publish =>
    simp only [step, publish] at hs
    split at hs
    · rename_i hd
      obtain ⟨hdone, _⟩ := hd
      cases hs
      refine ⟨h.life, h.accounted, h.rankWave, h.net_completed, h.ok_draining,
        fun _ => hdone, fun _ _ => ⟨hdone, rfl⟩, ?_⟩
      simp only [Option.some.injEq]
      intro hok
      exact h.ok_draining hok (h.life.done_draining hdone)
    · cases hs

theorem reachable_inv {ranks : List Nat} {pol : PushEndPolicy} {s : Recv}
    (h : (sys ranks pol).Reachable s) : Inv s :=
  (sys ranks pol).reachable_induction (inv_init ranks) (fun _ _ _ hi hs => step_inv pol hi hs) h

/-- Main result: every reachable reshard receive session satisfies all safety
properties under both `PushEndPolicy.finishOnError` and `PushEndPolicy.endOpOnly`. -/
theorem reachable_safe {ranks : List Nat} {pol : PushEndPolicy} {s : Recv}
    (h : (sys ranks pol).Reachable s) : Safe pol s :=
  inv_safe pol (reachable_inv h)

/-- Audit R3: at callback granularity `pollReady` (`IsReadyToComplete` in
`CompleteReadWithDetails`, `mgr.cc:1047-1052`) is disabled on every reachable
state, because `FinishPoolH2d` sets `network_completed_ = true` (`.cc:697`)
immediately before `Finish` (`.cc:700`). -/
theorem reachable_pollReady_disabled {ranks : List Nat} {pol : PushEndPolicy} {s : Recv}
    (h : (sys ranks pol).Reachable s) : step pol s .pollReady = none := by
  have hinv := reachable_inv h
  simp only [step, pollReady]
  split
  · rename_i hrd
    obtain ⟨hdr, hready⟩ := hrd
    simp only [isReadyToComplete, Bool.and_eq_true] at hready
    have ⟨_, _, hdr'⟩ := hinv.net_completed hready.1
    simp [hdr] at hdr'
  · rfl

/-! ### Progress and eventual settlement -/

def drainRank (s : Recv) : Nat :=
  s.pushes + poolDrainSteps s.pools

theorem poolDrainSteps_set_lt {ps : List Pool} {idx : Nat} {p p' : Pool}
    (hget : ps[idx]? = some p) (hlt : p'.stage.drainSteps < p.stage.drainSteps) :
    poolDrainSteps (ps.set idx p') < poolDrainSteps ps := by
  induction ps generalizing idx with
  | nil => simp at hget
  | cons q qs ih =>
    cases idx with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at hget
      subst hget
      simp only [List.set_cons_zero, poolDrainSteps]
      omega
    | succ idx =>
      simp only [List.getElem?_cons_succ] at hget
      have := ih hget
      simp only [List.set_cons_succ, poolDrainSteps]
      omega

@[simp] theorem maybeUnregisterSettled_life (s : Recv) :
    (maybeUnregisterSettled s).life = s.life := by
  unfold maybeUnregisterSettled; split <;> rfl

@[simp] theorem maybeUnregisterSettled_pushes (s : Recv) :
    (maybeUnregisterSettled s).pushes = s.pushes := by
  unfold maybeUnregisterSettled; split <;> rfl

@[simp] theorem maybeUnregisterSettled_pools (s : Recv) :
    (maybeUnregisterSettled s).pools = s.pools := by
  unfold maybeUnregisterSettled; split <;> rfl

theorem poolOps_le_poolDrainSteps : ∀ ps : List Pool, poolOps ps ≤ poolDrainSteps ps
  | [] => Nat.le_refl 0
  | q :: qs => by
    have ih := poolOps_le_poolDrainSteps qs
    cases hq : q.stage <;>
      simp only [poolOps, poolDrainSteps, hq, PoolStage.holdsOp, PoolStage.drainSteps,
        Bool.false_eq_true, ↓reduceIte] <;> omega

theorem drain_step (pol : PushEndPolicy) {s : Recv} (h : Inv s)
    (hdr : s.life.draining = true) (hnd : s.life.done = false) :
    ∃ e s', step pol s e = some s' ∧ s'.life.draining = true ∧ drainRank s' < drainRank s := by
  have hif : 0 < s.life.inFlight := by
    cases h0 : s.life.inFlight
    · have := h.life.prompt hdr h0; simp [hnd] at this
    · omega
  have hacc := h.accounted; unfold Accounted at hacc
  by_cases hp : 0 < s.pushes
  · have hne : s.pushes ≠ 0 := by omega
    have hs₁ : step pol s (.pushEnd true) =
        some (maybeUnregisterSettled { s with life := s.life.endOpLocked, pushes := s.pushes - 1 }) := by
      simp [step, pushEnd, hne]
    exact ⟨.pushEnd true, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩
  · have hpo : 0 < poolOps s.pools := by omega
    obtain ⟨p, _, pool, hget, hh⟩ := exists_holdsOp_of_poolOps_pos hpo
    cases hst : pool.stage with
    | queued =>
      have hs₁ : step pol s (.h2dIssue p true) =
          some { s with pools := s.pools.set p { pool with stage := .aborted },
                        life := s.life.endOpLocked } := by
        simp [step, h2dIssue, hget, hst, hdr]
      have hlt := poolDrainSteps_set_lt hget (p' := { pool with stage := .aborted })
        (by simp [hst, PoolStage.drainSteps])
      exact ⟨.h2dIssue p true, _, hs₁, by simp [hdr], by simp only [drainRank]; omega⟩
    | issued =>
      have hs₁ : step pol s (.h2dReady p) =
          some { s with pools := s.pools.set p { pool with stage := .ready } } := by
        simp [step, h2dReady, hget, hst]
      have hlt := poolDrainSteps_set_lt hget (p' := { pool with stage := .ready })
        (by simp [hst, PoolStage.drainSteps])
      exact ⟨.h2dReady p, _, hs₁, hdr, by simp only [drainRank]; omega⟩
    | ready =>
      have hlt_ab := poolDrainSteps_set_lt hget (p' := { pool with stage := .aborted })
        (by simp [hst, PoolStage.drainSteps])
      have hlt_co := poolDrainSteps_set_lt hget (p' := { pool with stage := .completed })
        (by simp [hst, PoolStage.drainSteps])
      by_cases hfin : s.finalizing = true
      · have hs₁ : step pol s (.h2dDone p true) =
            some (maybeUnregisterSettled { s with
              pools := s.pools.set p { pool with stage := .aborted },
              life := s.life.endOpLocked }) := by
          simp [step, h2dDone, hget, hst, hnd, hfin]
        exact ⟨.h2dDone p true, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩
      · simp only [Bool.not_eq_true] at hfin
        by_cases hall : allCompleted (s.pools.set p { pool with stage := .completed }) = true
        · have hs₁ : step pol s (.h2dDone p true) =
              some (maybeUnregisterSettled { s with
                pools := s.pools.set p { pool with stage := .completed },
                finalizing := true,
                networkCompleted := true,
                durationRecorded := true,
                life := (s.life.finishLocked true).endOpLocked }) := by
            simp [step, h2dDone, hget, hst, hnd, hfin, hall]
          exact ⟨.h2dDone p true, _, hs₁, by simp, by simp [drainRank]; omega⟩
        · simp only [Bool.not_eq_true] at hall
          have hs₁ : step pol s (.h2dDone p true) =
              some (maybeUnregisterSettled { s with
                pools := s.pools.set p { pool with stage := .completed },
                life := s.life.endOpLocked }) := by
            simp [step, h2dDone, hget, hst, hnd, hfin, hall, launchEligible, hdr]
          exact ⟨.h2dDone p true, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩
    | waiting | received | completed | aborted =>
      simp [hst, PoolStage.holdsOp] at hh

theorem draining_can_settle_aux (ranks : List Nat) (pol : PushEndPolicy) :
    ∀ (k : Nat) {s : Recv}, drainRank s ≤ k → Inv s → s.life.draining = true →
      ∃ evs s', (sys ranks pol).runFrom s evs = some s' ∧
        s'.life.done = true ∧ s'.life.hasStaging = false
  | 0, s, hk, h, hdr => by
    have hacc := h.accounted; unfold Accounted at hacc
    unfold drainRank at hk
    have := poolOps_le_poolDrainSteps s.pools
    have hd : s.life.done = true := h.life.prompt hdr (by omega)
    have hst : s.life.hasStaging = false := by rw [h.life.staging, hd]; rfl
    exact ⟨[], s, rfl, hd, hst⟩
  | k + 1, s, hk, h, hdr => by
    cases hnd : s.life.done
    · obtain ⟨e, s₁, hs₁, hdr₁, hlt⟩ := drain_step pol h hdr hnd
      obtain ⟨evs, s', hrun, hd', hst'⟩ :=
        draining_can_settle_aux ranks pol k (by omega) (step_inv pol h hs₁) hdr₁
      refine ⟨e :: evs, s', ?_, hd', hst'⟩
      simp only [System.runFrom, sys, List.foldlM_cons, hs₁]
      exact hrun
    · have hst : s.life.hasStaging = false := by rw [h.life.staging, hnd]; rfl
      exact ⟨[], s, rfl, hnd, hst⟩

/-- Every reachable reshard receive session can drain to `done = true` and
release its bounded `PoolStagingLease` in finitely many steps. -/
theorem reachable_can_settle {ranks : List Nat} {pol : PushEndPolicy} {s : Recv}
    (h : (sys ranks pol).Reachable s) :
    ∃ evs s', (sys ranks pol).runFrom s evs = some s' ∧
      s'.life.done = true ∧ s'.life.hasStaging = false := by
  have hinv := reachable_inv h
  have hcancel : step pol s .cancel = some { s with life := s.life.finishLocked false } := rfl
  have hinv₁ := step_inv pol hinv hcancel
  have hdr₁ : ({ s with life := s.life.finishLocked false } : Recv).life.draining = true := by simp
  obtain ⟨evs, s', hrun, hd', hst'⟩ :=
    draining_can_settle_aux ranks pol (drainRank { s with life := s.life.finishLocked false })
      (Nat.le_refl _) hinv₁ hdr₁
  refine ⟨.cancel :: evs, s', ?_, hd', hst'⟩
  simp only [System.runFrom, sys, List.foldlM_cons, hcancel]
  exact hrun

/-! ## Replay and bounded search

Concrete traces, checked by `decide`, covering rank-wave ordering when a
higher-rank pool arrives over the network before a lower-rank pool, batch H2D
launch across same-rank pools, cancellation between the two locks of
`ExecuteEligiblePoolH2ds`, `ReshardReceiveSessionTest` plan/execution scenarios
(`reshard_receive_session_test.cc:137-198, 405-439`), duration metric recording
(`FinishPoolReshardRecv*` in
`kv_cache_manager_with_transfer_pool_reshard_test.cc:327-367`), and the R1
comparison between `PushEndPolicy.endOpOnly` and `PushEndPolicy.finishOnError`. -/

/-- Two pools with order ranks `[0, 1]` (FA at rank 0, state class at rank 1 on
aliased arena pages, `.h:184-188`): pool 1 finishes arriving on the wire first
(`onPoolReceived 1`), but stays in `.received` without taking an H2D op until
pool 0 arrives (`onPoolReceived 0`), issues, completes its H2D copy, and its
callback (`h2dDone 0 true`) chains `ExecuteEligiblePoolH2ds` to queue pool 1. -/
theorem trace_rank1_arrives_before_rank0 :
    let s := sys [0, 1]
    -- Pool 1 (rank 1) arrives first: recorded in `started_pool_indices_`, not launched.
    (s.run [.pushBegin, .onPoolReceived 1, .pushEnd true]).map
      (fun r => (r.pools.map Pool.stage, r.life.inFlight)) =
      some ([.waiting, .received], 0) ∧
    -- Pool 1 cannot issue an H2D copy yet.
    s.run [.pushBegin, .onPoolReceived 1, .pushEnd true, .h2dIssue 1 true] = none ∧
    -- Pool 0 (rank 0) arrives: only pool 0 is queued (`inFlight = 1`).
    (s.run [.pushBegin, .onPoolReceived 1, .pushEnd true,
            .pushBegin, .onPoolReceived 0, .pushEnd true]).map
      (fun r => (r.pools.map Pool.stage, r.life.inFlight)) =
      some ([.queued, .received], 1) ∧
    -- Pool 0's H2D completes: `FinishPoolH2d(0, OK)` queues pool 1 before releasing pool 0's op.
    (s.run [.pushBegin, .onPoolReceived 1, .pushEnd true,
            .pushBegin, .onPoolReceived 0, .pushEnd true,
            .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true]).map
      (fun r => (r.pools.map Pool.stage, r.life.inFlight, r.life.done)) =
      some ([.completed, .queued], 1, false) ∧
    -- Pool 1 now issues, finishes, settles, unregisters the plan, and publishes `done_recving`.
    (s.run [.pushBegin, .onPoolReceived 1, .pushEnd true,
            .pushBegin, .onPoolReceived 0, .pushEnd true,
            .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true,
            .h2dIssue 1 true, .h2dReady 1, .h2dDone 1 true, .publish]).map
      (fun r => (r.life.done, r.life.hasStaging, r.planUnregistered,
                 r.durationRecorded, r.published)) =
      some (true, false, true, true, some true) := by
  decide

/-- Batch H2D launch across multiple pools of the same higher rank (`[0, 1, 1]`):
both rank-1 pools arrive while rank 0 is still uploading; when rank 0 completes
(`h2dDone 0 true`), `ExecuteEligiblePoolH2ds` queues both rank-1 pools in one
batch (`in_flight_ += 2`, then `- 1` for pool 0 = `2`). -/
theorem trace_batch_launch_on_rank_wave :
    let s := sys [0, 1, 1]
    let pre := [.onPoolReceived 0, .h2dIssue 0 true, .onPoolReceived 1, .onPoolReceived 2,
                .h2dReady 0, .h2dDone 0 true]
    (s.run pre).map (fun r => (r.pools.map Pool.stage, r.life.inFlight, r.life.done)) =
      some ([.completed, .queued, .queued], 2, false) ∧
    (s.run (pre ++ [.h2dIssue 1 true, .h2dIssue 2 true, .h2dReady 1, .h2dDone 1 true,
                    .h2dReady 2, .h2dDone 2 true, .publish])).map
      (fun r => (r.life.done, r.published, r.durationRecorded)) =
      some (true, some true, true) := by
  decide

/-- The race closed by the per-pool re-check at `.cc:633-638`: two rank-0 pools
are queued (`inFlight = 2`), the first issues its H2D copy, and `cancel` fires
before the loop reaches the second pool's re-check lock. The second pool aborts
and drops its op without starting an upload, while the first pool's in-flight
copy keeps the session and its staging lease alive until its callback runs. -/
theorem trace_cancel_between_batch_queue_and_issue :
    let s := sys [0, 0]
    let pre := [.onPoolReceived 0, .onPoolReceived 1, .h2dIssue 0 true, .cancel, .h2dIssue 1 true]
    (s.run pre).map
      (fun r => (r.pools.map Pool.stage, r.life.inFlight, r.life.done, r.life.hasStaging)) =
      some ([.issued, .aborted], 1, false, true) ∧
    (s.run (pre ++ [.h2dReady 0, .h2dDone 0 true, .publish])).map
      (fun r => (r.life.done, r.life.hasStaging, r.planUnregistered,
                 r.durationRecorded, r.published)) =
      some (true, false, true, false, some false) := by
  decide

/-- Receiver plan identity/pool validation (`ValidatePlan`,
`reshard_receive_session.cc:67-144`, `ValidateCommonPoolReshardPlan` and
`ValidatePoolBlockBounds`, `utils.h:353-489`, tested at
`reshard_receive_session_test.cc:166-225, 257-276`, and
`DeviceOnlyRejectionAtPublicEntryPoints` at
`kv_cache_manager_with_transfer_pool_reshard_test.cc:271-287`):
- Rejects `enableHostStaging = false` (`reshard_receive_session.cc:364-368`,
  `kv_cache_manager_with_transfer_pool_reshard_test.cc:271-287`),
- Registers the plan with `isSender = false` (`reshard_receive_session.cc:376-377`)
  and rejects empty `ranks` (`utils.h:367-370`),
- Rejects out-of-range, duplicate, or dtype-mismatched pool indices
  (`utils.h:382-386, 396-425`, `reshard_receive_session_test.cc:200-225`), and
- Rejects destination `blockId ≥ numBlocks` (`utils.h:473-489`, called at
  `reshard_receive_session.cc:94`, `reshard_receive_session_test.cc:257-276`). -/
def validPlan (isSender : Bool) (ranks : List Nat) : Bool :=
  !isSender && !ranks.isEmpty

def validPlanPoolsAndBlocks (enableHostStaging : Bool) (numPools numBlocks : Nat)
    (poolIndices : List Nat) (dtypeMatches : Bool) (dstBlockIds : List Nat) : Bool :=
  enableHostStaging &&
  !poolIndices.isEmpty &&
  dtypeMatches &&
  decide poolIndices.Nodup &&
  poolIndices.all (fun p => decide (p < numPools)) &&
  !dstBlockIds.isEmpty &&
  dstBlockIds.all (fun b => decide (b < numBlocks))

/-- Replay of `ReshardReceiveSessionTest.AcceptsCanonicalPlanOnExplicitPools`
(`reshard_receive_session_test.cc:137-145`), `AcceptsImplicitPools` (`:147-154`),
`HasNoTagPolicy` (`:156-164`), `RejectsMissingIdentityAndPoolFields` (`:166-198`),
`RejectsOutOfRangeDuplicateAndDtypeMismatch` (`:200-225`),
`RejectsBlockIdsOutsideDeclaredPool` (`:257-276`),
`GroupScopesDestinationBlocks` (`:405-439`), and
`PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints`
(`kv_cache_manager_with_transfer_pool_reshard_test.cc:271-287`):
1. `DeviceOnlyRejectionAtPublicEntryPoints` (`:271-287`): `enableHostStaging = false`
   is rejected (`false`).
2. `RejectsMissingIdentityAndPoolFields` (`reshard_receive_session_test.cc:166-198`):
   non-receiver registration (`isSender = true`) or empty `transfer_pool_indices`
   (`ranks = []`, `:181-185`) is rejected.
3. `RejectsOutOfRangeDuplicateAndDtypeMismatch` (`:200-225`): out-of-range pool
   index (`:204-208`, modeled with `[99]` on `numPools = 2`), duplicate pool
   indices `[0, 0]` (`:210-214`), or dtype mismatch (`dtypeMatches = false`,
   `:216-219`) is rejected.
4. `RejectsBlockIdsOutsideDeclaredPool` (`:257-276`): destination block outside
   the declared pool (`[16]` on `numBlocks = 16`) is rejected (`false`), whereas
   in-range blocks (`[1, 2]`) are accepted (`true`).
5. A canonical 1-pool plan (`ranks = [0]`, `:137-154`) and a 2-group plan
   (`ranks = [0, 0]`, `:156-164, 405-439`) execute H2D, release staging leases,
   unregister the active plan, and publish `done_recving`. -/
theorem trace_reshard_receive_session_test_parity :
    validPlanPoolsAndBlocks false 2 16 [0] true [1] = false ∧
    validPlan true [0] = false ∧
    validPlan false [] = false ∧
    validPlan false [0] = true ∧
    validPlanPoolsAndBlocks true 2 16 [99] true [1] = false ∧
    validPlanPoolsAndBlocks true 2 16 [0, 0] true [1] = false ∧
    validPlanPoolsAndBlocks true 2 16 [0] false [1] = false ∧
    validPlanPoolsAndBlocks true 2 16 [0] true [16] = false ∧
    validPlanPoolsAndBlocks true 2 16 [0] true [1, 2] = true ∧
    ((sys [0]).run
      [.pushBegin, .onPoolReceived 0, .pushEnd true,
       .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true, .publish]).map
      (fun r => (r.life.done, r.life.hasStaging, r.planUnregistered, r.published)) =
      some (true, false, true, some true) ∧
    ((sys [0, 0]).run
      [.pushBegin, .onPoolReceived 0, .pushEnd true,
       .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true,
       .pushBegin, .onPoolReceived 1, .pushEnd true,
       .h2dIssue 1 true, .h2dReady 1, .h2dDone 1 true, .publish]).map
      (fun r => (r.pools.map Pool.stage, r.life.done, r.life.hasStaging,
                 r.planUnregistered, r.published)) =
      some ([.completed, .completed], true, false, true, some true) := by
  decide

/-- `FinishPoolReshardRecvRecordsDurationMetric` and
`FinishPoolReshardRecvDoesNotRecordMetricOnFailure`
(`kv_cache_manager_with_transfer_pool_reshard_test.cc:327-367`): duration is
recorded when the final pool's H2D completes OK (`:327-347`), and is not
recorded when a pool's H2D fails (`:349-367`). -/
theorem trace_duration_metric_on_success_and_failure :
    let s := sys [0]
    ((s.run [.onPoolReceived 0, .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 true, .publish]).map
      (fun r => (r.published, r.durationRecorded, r.planUnregistered)) =
      some (some true, true, true)) ∧
    ((s.run [.onPoolReceived 0, .h2dIssue 0 true, .h2dReady 0, .h2dDone 0 false, .publish]).map
      (fun r => (r.published, r.durationRecorded, r.planUnregistered)) =
      some (some false, false, true)) := by
  decide

/-- Finding F7 / R1 (pre-`fdeebcd` `mgr.cc` hook vs. the `TransferReceiveSession`
branch at `:267-271`): when an incoming push fails (`pushEnd false`), the old
hook (`.endOpOnly`) ended the op without finishing the session, leaving
`draining = false`, `done = false`, `hasStaging = true`, and
`planUnregistered = false` until the external deadline (`cancel`). Under
`PushEndPolicy.finishOnError` — the shipping code since `fdeebcd`, whose
regression test is `PoolReshardRecvTest.FailedIncomingPushReleasesStagingLeaseBeforeDeadline`
(`kv_cache_manager_with_transfer_pool_reshard_test.cc:766-802`) — `pushEnd false`
immediately drains and settles the session, releasing the pool staging lease
and unregistering the plan. -/
theorem trace_r1_failed_incoming_push :
    -- Pre-`fdeebcd` (`.endOpOnly`): after `[.pushBegin, .pushEnd false]`, session is still open and holds staging/plan.
    ((sys [0] .endOpOnly).run [.pushBegin, .pushEnd false]).map
      (fun r => (r.life.draining, r.life.done, r.life.hasStaging, r.planUnregistered)) =
      some (false, false, true, false) ∧
    (sys [0] .endOpOnly).run [.pushBegin, .pushEnd false, .publish] = none ∧
    -- Fix (`finishOnError`): `[.pushBegin, .pushEnd false]` settles at once and publishes failure.
    ((sys [0] .finishOnError).run [.pushBegin, .pushEnd false, .publish]).map
      (fun r => (r.life.done, r.life.hasStaging, r.planUnregistered, r.published)) =
      some (true, false, true, some false) := by
  decide

def events (numPools : Nat) : List Ev :=
  [.pushBegin, .pushEnd true, .pushEnd false, .pollReady, .cancel, .publish] ++
  (List.range numPools).flatMap fun p =>
    [.onPoolReceived p, .h2dIssue p true, .h2dIssue p false,
     .h2dReady p, .h2dDone p true, .h2dDone p false]

/-- Executable negation of `Safe`. -/
def violates (pol : PushEndPolicy) (s : Recv) : Bool :=
  (s.life.done && s.life.inFlight != 0) ||
  (s.life.done && poolOps s.pools != 0) ||
  (s.life.hasStaging != !s.life.done) ||
  (s.planUnregistered && !s.life.done) ||
  (s.published.isSome && !s.planUnregistered) ||
  (s.life.draining && s.life.inFlight == 0 && !s.life.done) ||
  !rankWaveOrder s.pools ||
  (isReadyToComplete s && !allCompleted s.pools) ||
  (s.published == some true && !(allCompleted s.pools && s.durationRecorded)) ||
  (0 < s.life.inFlight && !(drainEvents s.pools.length).any fun e => (step pol s e).isSome)

#guard ModelCheck.check (sys [0, 1] .endOpOnly) (events 2) (violates .endOpOnly) 8 = .outOfFuel
#guard ModelCheck.check (sys [0, 1] .finishOnError) (events 2) (violates .finishOnError) 8 = .outOfFuel

/-- Mutant 1 (`onPoolReceivedIgnoringRank`): `CollectEligiblePoolH2dsLocked`
ignores `pool_order_ranks_` (`.cc:562-573`) and launches every started pool
immediately. When pool 1 (rank 1) arrives before pool 0 (rank 0), pool 1
launches while pool 0 is still `.waiting`, violating `RankWaveOrder`. -/
def onPoolReceivedIgnoringRank (p : Nat) (s : Recv) : Option Recv :=
  match s.pools[p]? with
  | some pool =>
    if s.life.done = true ∨ pool.stage != .waiting then none
    else
      let pools₁ := s.pools.set p { pool with stage := .received }
      if s.life.done = true ∨ s.life.draining = true ∨ s.finalizing = true then
        some { s with pools := pools₁ }
      else
        let (pools', k) := launchPass (fun _ => true) pools₁
        some { s with pools := pools', life := { s.life with inFlight := s.life.inFlight + k } }
  | none => none

#guard (match ModelCheck.check ⟨init [0, 1], fun s e => match e with
          | .onPoolReceived p => onPoolReceivedIgnoringRank p s
          | e => step .finishOnError s e⟩ (events 2) (violates .finishOnError) 4 with
        | .counterexample _ => true
        | _ => false)

/-- Mutant 2 (`h2dIssueLeak`): the re-check in `ExecuteEligiblePoolH2ds`
(`.cc:633-637`) skips the upload on `done_ || draining_` without calling
`EndRecvOpLocked()`. A cancellation between queuing and issuing leaks the op,
caught by `NoOpLeak`. -/
def h2dIssueLeak (p : Nat) (ok : Bool) (s : Recv) : Option Recv :=
  match s.pools[p]? with
  | some pool =>
    if pool.stage != .queued then none
    else if s.life.done = true ∨ s.life.draining = true then
      some { s with pools := s.pools.set p { pool with stage := .aborted } }
    else s.h2dIssue p ok
  | none => none

#guard (match ModelCheck.check ⟨init [0], fun s e => match e with
          | .h2dIssue p ok => h2dIssueLeak p ok s
          | e => step .finishOnError s e⟩ (events 1) (violates .finishOnError) 5 with
        | .counterexample _ => true
        | _ => false)

/-- Mutant 3 (`cancelUnregisterEarly`): external cancellation unregisters the
active plan immediately when `Finish` sets `draining_` (`mgr.cc:747-753`),
instead of deferring unregistration to `MaybeUnregisterSettledReshardRecv`
(`mgr.cc:782-788`, `.cc:512-520`) after open incoming pushes (`pushes > 0`) drain,
violating `PlanIntegrity`. -/
def cancelUnregisterEarly (s : Recv) : Option Recv :=
  some { s with life := s.life.finishLocked false, planUnregistered := true }

#guard (match ModelCheck.check ⟨init [0], fun s e => match e with
          | .cancel => cancelUnregisterEarly s
          | e => step .finishOnError s e⟩ (events 1) (violates .finishOnError) 4 with
        | .counterexample _ => true
        | _ => false)

end Recv

end TpuSyncVerify.Transfer.Reshard
