import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck

/-!
# `ReadRemote`: destination-side settle protocol

The destination half of `RaidenController::ReadRemote`
(`tpu_sync/core/controller/raiden_controller.cc`) as a finite transition
system, checked exhaustively. Seven booleans, every event fires at most once,
so `ModelCheck.check` visits the *whole* reachable state space: `.safe` here is
a verification result, not a bounded one.

File aliases used in the source map below:
`ctrl.h` (`tpu_sync/core/controller/raiden_controller.h`),
`ctrl.cc` (`tpu_sync/core/controller/raiden_controller.cc`),
`ctrl_test.cc` (`tpu_sync/core/controller/raiden_controller_test.cc`).

The model shows that a remote read can keep DMA-ing into the caller's
destination blocks after the caller has been told the read failed.

## How a read runs

`RaidenController::ReadRemote` acquires a lease at the source
(`stub->async()->AcquireReadLease(...)`). The reply callback settles on an RPC
error (`if (!status.ok())`), settles with `Cancelled` if the controller was
torn down meanwhile (`if (lifetime->ctrl == nullptr)`), and otherwise calls
`RaidenController::PullAndRelease` (`lifetime->ctrl->PullAndRelease(...)`), which
issues the pull — `TransferBuffers` into the caller's destination blocks
(`tsl::Future<> transfer = TransferBuffers(...)`) — and, when it completes, releases the lease and
settles with the verdict (`transfer.OnReady`). A detached deadline thread
(`std::thread([state, deadline = RemoteReadDeadline()] { ... })`) settles with
`DeadlineExceeded` unless already settled. `RemoteReadState::Settle` is
idempotent: the first call sets the promise.

The caller treats a settled promise as "no copy touches my blocks any more":
the comment in `RaidenController::PullAndRelease` says the staging blocks go
back to the pool once the read settles, success or failure, and the device
blocks are the caller's to refill.

## State and events

| Field           | C++ |
|-----------------|-----|
| `acquired`      | the acquire callback has run |
| `pullIssued`    | `TransferBuffers` was called (`RaidenController::PullAndRelease` `tsl::Future<> transfer = TransferBuffers(...)`) |
| `pullDone`      | the transfer future resolved (`RaidenController::PullAndRelease` `transfer.OnReady`) |
| `settled`       | `RemoteReadState::settled` (`RemoteReadState`) |
| `deadlineFired` | the deadline thread woke (`RaidenController::ReadRemote` `std::thread([state, deadline = RemoteReadDeadline()] { ... })`) |
| `shutdown`      | `lifetime->ctrl == nullptr` (`RaidenController::ReadRemote` `if (lifetime->ctrl == nullptr)`) |
| `reused`        | ghost: the caller has reused the destination blocks |

| Event              | C++ |
|--------------------|-----|
| `acquireReply ok`  | the acquire callback, with an OK or failed RPC status |
| `shutdown`         | controller teardown detaches in-flight reads (`RaidenController::Cleanup` `lifetime_->ctrl = nullptr;`) |
| `deadline`         | the deadline thread (`RaidenController::ReadRemote` `std::thread([state, deadline = RemoteReadDeadline()] { ... })`) |
| `pullDone`         | `transfer.OnReady` → release → `Settle(verdict)` (`RaidenController::PullAndRelease` `transfer.OnReady`) |
| `callerReuse`      | the caller reuses the destination blocks after the future settled |

`Impl` selects the implementation of the acquire callback and the deadline:

* `shipping` — the shipping code: nothing checks `settled` before
  `TransferBuffers`, and the deadline settles regardless of an in-flight pull;
* `checkSettledBeforePull` — the naive fix: skip the pull if already settled;
* `deferSettleWhilePullInFlight` — the naive fix plus: the deadline does not
  settle while a pull is in flight; the pull's completion settles. This is
  what the sibling `WriteRemote` path already does
  (`kv_cache_store_service.cc` `DeadlineLoop`).

## Lock scopes

Two mutexes participate in the post-launch protocol:
`Lifetime::mu` (`lifetime->mu`), guarding `Lifetime::ctrl` (`ABSL_GUARDED_BY(mu)`),
and `RemoteReadState::mu` (`state->mu`), guarding only `RemoteReadState::settled`
(`ABSL_GUARDED_BY(mu)`). The five setup fields of `RemoteReadState`
(`src_controller_address`, `stub`, `promise`, `dst_host_block_ids`,
`dst_device_block_ids`) are populated in `ReadRemote` before `AcquireReadLease`
or the deadline thread starts and are not mutated afterwards (`promise->Set` is
called outside `state->mu` in `Settle`, at most once because only the caller
that flips `settled` from `false` to `true` under `state->mu` reaches it).
`RemoteReadState::lease_id` (`uint64_t lease_id = 0`) is plain and unguarded:
the acquire callback writes `state->lease_id = acquire_resp->lease_id()` before
acquiring `lifetime->mu`, `PullAndRelease`'s `transfer.OnReady` callback reads it
without a lock on the same thread after `acquireReply` to send the commit
`ReleaseReadLease` RPC, and the deadline thread reads `state->lease_id`
without a lock after releasing `state->mu` (`if (state->lease_id != 0)`).
`lease_id` is not in `S` (on `pullDone`, `S.settled : Bool` abstracts the
commit verdict status; on `deadline`, `state->Settle(DeadlineExceededError(...))`
runs unconditionally regardless of `lease_id`).

| Event | Scopes | Between them |
|---|---|---|
| `acquireReply ok` | `ok = false`: one `state->mu` scope in `Settle`; `ok = true` with `lifetime->ctrl == nullptr`: one `lifetime->mu` scope containing `Settle`'s `state->mu` scope; `ok = true` with `lifetime->ctrl != nullptr` (`shipping`): one `lifetime->mu` scope around `PullAndRelease`, and **no `state->mu` scope** (`settled` is not read before `TransferBuffers`) | the missing `state->mu` check on the `ok = true`, live-controller branch is why `shipping` sets `pullIssued = true` unconditionally and why Shape A (`lateIssue`) is reachable. `checkSettledBeforePull` and `deferSettleWhilePullInFlight` add a `state->mu` check of `settled` before issuing the pull |
| `shutdown` | one `lifetime_->mu` scope in `RaidenController::Cleanup` (`lifetime_->ctrl = nullptr;`) | serialised with `acquireReply true` by `lifetime->mu` |
| `deadline` | 1–2 `state->mu` scopes on the detached thread (`if (state->settled) return;`, 1 scope when already settled; otherwise followed by `state->Settle(DeadlineExceededError(...))`), with the unguarded `state->lease_id` reads and fire-and-forget `ReleaseReadLease` between them; neither scope reads whether a pull is in flight (`RemoteReadState` has no in-flight counter) | on `state->mu`, only `settled` is guarded (monotonic `false → true`), and `Settle` re-checks `if (settled) return;` in the second scope; any event (`acquireReply`, `shutdown`, or `pullDone`) interleaved between the two scopes orders before the second scope (`settled := s.settled || settleNow`) |
| `pullDone` | `transfer.OnReady` resolves when the pull finishes on the workers, issues `ReleaseReadLease`, and in its gRPC callback runs one `state->mu` scope (`state->Settle(...)`) on every path | between `transfer.OnReady` and `Settle`, the DMA into destination blocks has already ended (`pullInFlight = false`), so a `deadline` or `callerReuse` in that gap cannot violate `NoWriteAfterRelease` (it is equivalent to `pullDone` followed by `deadline`) |
| `callerReuse` | none (caller, after `promise->Set` resolves `future`) | `promise->Set` runs immediately after the single transition `settled : false → true` in `Settle` |

## Property

`NoWriteAfterRelease`: the caller never reuses the destination blocks while a
pull into them is in flight (issued and not done).

## Results

* Shipping code violates it two ways. **Shape A** (late issue): the deadline
  settles, the caller takes its blocks back, the acquire reply arrives
  afterwards and the pull is issued into them anyway. **Shape B** (in flight): the pull is
  issued, the deadline settles while it runs, the caller reuses the blocks
  under the DMA. Shape A is deterministic (delay the acquire reply past the
  deadline); shape B is the case the deadline exists for.
* The naive fix closes A and not B.
* Deferring the deadline's settle while a pull is in flight has no violation
  anywhere in the reachable state space (`deferred_settle_is_safe`). Its cost:
  a hung pull holds the caller until it resolves. A complete fix needs
  cancellation, or settle-with-error while the blocks stay quarantined.

## Source map

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|------|-----------------|-------|
| `ctrl.h` | `Lifetime` | `:213-216` |
| `ctrl.cc` | `RaidenController::Cleanup` (`// Detach in-flight reads FIRST.` .. `lifetime_->ctrl = nullptr;`) | `:319-325` |
| `ctrl.cc` | `RemoteReadState` | `:932-951` |
| `ctrl.cc` | `RemoteReadState::Settle` | `:943-950` |
| `ctrl.cc` | `RaidenController::ReadRemote` | `:953-1148` |
| `ctrl.cc` | `RaidenController::ReadRemote` (`stub->async()->AcquireReadLease(`) | `:1057-1118` |
| `ctrl.cc` | `RaidenController::ReadRemote` (`if (!status.ok())`) | `:1061-1074` |
| `ctrl.cc` | `RaidenController::ReadRemote` (`state->lease_id = acquire_resp->lease_id();`) | `:1075` |
| `ctrl.cc` | `RaidenController::ReadRemote` (`absl::MutexLock lock(&lifetime->mu);` .. `lifetime->ctrl->PullAndRelease`) | `:1100-1117` |
| `ctrl.cc` | `RaidenController::ReadRemote` (`if (lifetime->ctrl == nullptr)`) | `:1101-1116` |
| `ctrl.cc` | `RaidenController::ReadRemote` (`std::thread([state, deadline = RemoteReadDeadline()]`) | `:1125-1145` |
| `ctrl.cc` | `RaidenController::ReadRemote` (`if (state->settled) return;`) | `:1129` |
| `ctrl.cc` | `RaidenController::ReadRemote` (`if (state->lease_id != 0)`) | `:1131-1141` |
| `ctrl.cc` | `RaidenController::PullAndRelease` | `:1150-1252` |
| `ctrl.cc` | `RaidenController::PullAndRelease` (`// remote host src -> local host staging -> local device dst.` .. `// the read's only product.`) | `:1175-1179` |
| `ctrl.cc` | `RaidenController::PullAndRelease` (`tsl::Future<> transfer =`) | `:1202-1203` |
| `ctrl.cc` | `RaidenController::PullAndRelease` (`transfer.OnReady`) | `:1210-1251` |
| `ctrl_test.cc` | `ReadRemotePullTest.FullSuccessPathUsesAuthoritativeIdsAndSrcEndpoints` | `:634-661` |
| `ctrl_test.cc` | `ReadRemotePullTest.HbmModeBuildsStagingPlusDeviceDst` | `:663-686` |
| `ctrl_test.cc` | `ReadRemotePullTest.HostModeBuildsDramDstWithNoStaging` | `:688-703` |
| `ctrl_test.cc` | `ReadRemotePullTest.AcquireNotFoundFailsFastWithoutTransfer` | `:797-815` |
| `ctrl_test.cc` | `ReadRemotePullTest.TransferFailureStillReleasesTheLease` | `:817-833` |
| `ctrl_test.cc` | `ReadRemotePullTest.RevokedVerdictFailsTheRead` | `:835-855` |
| `ctrl_test.cc` | `ReadRemotePullTest.ControllerTeardownMidReadIsSafe` | `:857-882` |
<!-- source-map:end -->
-/

namespace TpuSyncVerify.Controller.ReadRemote

structure S where
  acquired : Bool := false
  pullIssued : Bool := false
  pullDone : Bool := false
  settled : Bool := false
  deadlineFired : Bool := false
  shutdown : Bool := false
  reused : Bool := false
  deriving Repr, DecidableEq

inductive Ev where
  | acquireReply (ok : Bool)
  | shutdown
  | deadline
  | pullDone
  | callerReuse
  deriving Repr, DecidableEq

/-- Which implementation of the acquire callback and the deadline. -/
inductive Impl where
  | shipping
  | checkSettledBeforePull
  | deferSettleWhilePullInFlight
  deriving Repr, DecidableEq

/-- A pull was issued and its future has not resolved. -/
def S.pullInFlight (s : S) : Bool := s.pullIssued && !s.pullDone

/-- The acquire callback (`RaidenController::ReadRemote`
`stub->async()->AcquireReadLease(...)`). -/
def acquireReply (impl : Impl) (ok : Bool) (s : S) : Option S :=
  if s.acquired then none
  else if !ok || s.shutdown then
    -- `if (!status.ok())` / `if (lifetime->ctrl == nullptr)`: settle, no pull.
    some { s with acquired := true, settled := true }
  else
    let issue := match impl with
      | .shipping => true
      | .checkSettledBeforePull | .deferSettleWhilePullInFlight => !s.settled
    some { s with acquired := true, pullIssued := issue }

/-- Controller teardown detaches in-flight reads (`RaidenController::Cleanup`
`lifetime_->ctrl = nullptr;`). -/
def shutdownCtrl (s : S) : Option S :=
  if s.shutdown then none else some { s with shutdown := true }

/-- The deadline thread (`RaidenController::ReadRemote`
`std::thread([state, deadline = RemoteReadDeadline()] { ... })`). -/
def deadline (impl : Impl) (s : S) : Option S :=
  if s.deadlineFired then none
  else
    let settleNow := match impl with
      | .deferSettleWhilePullInFlight => !s.pullInFlight
      | _ => true
    some { s with deadlineFired := true, settled := s.settled || settleNow }

/-- `transfer.OnReady` → `ReleaseReadLease` → `Settle(verdict)`
(`RaidenController::PullAndRelease` `transfer.OnReady`). -/
def completePull (s : S) : Option S :=
  if s.pullInFlight then some { s with pullDone := true, settled := true } else none

/-- The caller reuses its blocks once the future is settled. -/
def callerReuse (s : S) : Option S :=
  if s.settled && !s.reused then some { s with reused := true } else none

def step (impl : Impl) (s : S) : Ev → Option S
  | .acquireReply ok => acquireReply impl ok s
  | .shutdown => shutdownCtrl s
  | .deadline => deadline impl s
  | .pullDone => completePull s
  | .callerReuse => callerReuse s

def sys (impl : Impl) : System S Ev := ⟨{}, step impl⟩

/-! ## Property -/

def NoWriteAfterRelease (s : S) : Prop := s.reused = true → s.pullInFlight = false

/-- Executable negation of `NoWriteAfterRelease`. -/
def violates (s : S) : Bool := s.reused && s.pullInFlight

def events : List Ev :=
  [.acquireReply true, .acquireReply false, .shutdown, .deadline, .pullDone, .callerReuse]

/-! ## Results -/

/-- Shape A: the deadline settles and the caller takes its blocks back; the
acquire reply arrives afterwards and the shipping code issues the pull into
them anyway. -/
def lateIssue : List Ev := [.deadline, .callerReuse, .acquireReply true]

/-- Shape B: the deadline settles while the pull is running. -/
def inFlight : List Ev := [.acquireReply true, .deadline, .callerReuse]

theorem shipping_lateIssue :
    ((sys .shipping).run lateIssue).map violates = some true := by decide

theorem shipping_inFlight :
    ((sys .shipping).run inFlight).map violates = some true := by decide

/-- The naive fix closes shape A … -/
theorem naive_fix_closes_lateIssue :
    ((sys .checkSettledBeforePull).run lateIssue).map violates = some false := by decide

/-- … and not shape B. -/
theorem naive_fix_keeps_inFlight :
    ((sys .checkSettledBeforePull).run inFlight).map violates = some true := by decide

/-- Exhaustive search finds shape A first … -/
theorem shipping_counterexample :
    ModelCheck.check (sys .shipping) events violates = .counterexample lateIssue := by decide

theorem naive_fix_counterexample :
    ModelCheck.check (sys .checkSettledBeforePull) events violates = .counterexample inFlight := by
  decide

/-- Deferring the deadline's settle while a pull is in flight removes every
violation. The state space is exhausted, so this is a proof of
`NoWriteAfterRelease` for that implementation. -/
theorem deferred_settle_is_safe :
    ModelCheck.check (sys .deferSettleWhilePullInFlight) events violates = .safe := by decide

/-- The deferred-settle design still settles every read whose pull resolves:
a deadline during the pull is followed by the pull's own settle. -/
theorem deferred_settle_settles :
    ((sys .deferSettleWhilePullInFlight).run [.acquireReply true, .deadline, .pullDone]).map
      (fun s => (s.settled, s.deadlineFired)) = some (true, true) ∧
    ((sys .deferSettleWhilePullInFlight).run [.acquireReply true, .deadline]).map
      (fun s => s.settled) = some false := by
  decide

/-! ## C++ unit test correspondence (`ReadRemotePullTest` in `raiden_controller_test.cc`) -/

/-- `ReadRemotePullTest.FullSuccessPathUsesAuthoritativeIdsAndSrcEndpoints`
(`raiden_controller_test.cc`, plus
`ReadRemotePullTest.HbmModeBuildsStagingPlusDeviceDst`,
`ReadRemotePullTest.HostModeBuildsDramDstWithNoStaging`,
`ReadRemotePullTest.TransferFailureStillReleasesTheLease`, and
`ReadRemotePullTest.RevokedVerdictFailsTheRead`): `AcquireReadLease` succeeds,
`PullAndRelease` issues and completes the pull, releases the lease, and settles
the promise before the caller reuses the destination blocks. -/
theorem trace_full_success (impl : Impl) :
    ((sys impl).run [.acquireReply true, .pullDone, .callerReuse]).map
      (fun s => (s.pullIssued, s.pullDone, s.settled, s.reused, violates s)) =
    some (true, true, true, true, false) := by
  cases impl <;> decide

/-- `ReadRemotePullTest.AcquireNotFoundFailsFastWithoutTransfer`
(`raiden_controller_test.cc`): `AcquireReadLease` fails at the source
(`ok = false`); the acquire callback settles immediately without issuing a pull,
and the caller safely reuses its destination blocks. -/
theorem trace_acquire_fails_fast (impl : Impl) :
    ((sys impl).run [.acquireReply false, .callerReuse]).map
      (fun s => (s.pullIssued, s.settled, s.reused, violates s)) =
    some (false, true, true, false) := by
  cases impl <;> decide

/-- `ReadRemotePullTest.ControllerTeardownMidReadIsSafe`
(`raiden_controller_test.cc`, teardown before the acquire reply):
the controller is destroyed (`shutdown`) while `AcquireReadLease` is in flight;
when the reply arrives, the callback sees `lifetime->ctrl == nullptr`, settles
with `Cancelled` without issuing a pull, and the caller safely reuses its
destination blocks. -/
theorem trace_teardown_before_acquire (impl : Impl) :
    ((sys impl).run [.shutdown, .acquireReply true, .callerReuse]).map
      (fun s => (s.pullIssued, s.settled, s.reused, violates s)) =
    some (false, true, true, false) := by
  cases impl <;> decide

/-- `ReadRemotePullTest.ControllerTeardownMidReadIsSafe`
(`raiden_controller_test.cc`, teardown after the pull was issued):
the controller is destroyed while the pull is in flight; the shared-state
continuation completes the pull, releases the lease, and settles cleanly. -/
theorem trace_teardown_during_pull (impl : Impl) :
    ((sys impl).run [.acquireReply true, .shutdown, .pullDone, .callerReuse]).map
      (fun s => (s.pullIssued, s.pullDone, s.settled, s.reused, violates s)) =
    some (true, true, true, true, false) := by
  cases impl <;> decide

end TpuSyncVerify.Controller.ReadRemote

