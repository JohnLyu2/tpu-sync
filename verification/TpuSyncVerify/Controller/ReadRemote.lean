import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck

/-!
# `ReadRemote`: destination-side settle protocol

The destination half of `RaidenController::ReadRemote`
(`tpu_sync/core/controller/raiden_controller.cc`, tpu-sync `01ffa3d`; the
cited regions are unchanged since `b68161a`, where this was first found) as a
finite transition system, checked exhaustively. Seven booleans, every event
fires at most once, so `ModelCheck.check` visits the *whole* reachable state
space: `.safe` here is a verification result, not a bounded one.

This is the model behind finding **F2** in `findings/README.md`: a remote
read can keep DMA-ing into the caller's destination blocks after the caller
has been told the read failed.

## How a read runs

`ReadRemote` (`:912-1107`) acquires a lease at the source (`AcquireReadLease`,
`:1016`). The reply callback (`:1018-1077`) settles on an RPC error
(`:1020-1033`), settles with `Cancelled` if the controller was torn down
meanwhile (`:1059-1075`), and otherwise calls `PullAndRelease` (`:1076`),
which issues the pull — `TransferBuffers` into the caller's destination
blocks (`:1161-1162`) — and, when it completes, releases the lease and
settles with the verdict (`:1169-1210`). A detached deadline thread
(`:1084-1104`) settles with `DeadlineExceeded` unless already settled.
`Settle` is idempotent (`:902-909`): the first call sets the promise.

The caller treats a settled promise as "no copy touches my blocks any more":
the header comment at `:1134-1138` says the staging blocks go back to the
pool once the read settles, success or failure, and the device blocks are
the caller's to refill.

## State and events

| Field           | C++ |
|-----------------|-----|
| `acquired`      | the acquire callback has run |
| `pullIssued`    | `TransferBuffers` was called (`:1162`) |
| `pullDone`      | the transfer future resolved (`:1169`) |
| `settled`       | `RemoteReadState::settled` (`:899`) |
| `deadlineFired` | the deadline thread woke (`:1085`) |
| `shutdown`      | `lifetime->ctrl == nullptr` (`:1060`) |
| `reused`        | ghost: the caller has reused the destination blocks |

| Event              | C++ |
|--------------------|-----|
| `acquireReply ok`  | the acquire callback, with an OK or failed RPC status |
| `shutdown`         | controller teardown detaches in-flight reads (`:318`) |
| `deadline`         | the deadline thread (`:1084-1104`) |
| `pullDone`         | `transfer.OnReady` → release → `Settle(verdict)` (`:1169-1210`) |
| `callerReuse`      | the caller reuses the destination blocks after the future settled |

`Impl` selects the implementation of the acquire callback and the deadline:

* `shipping` — the code at `01ffa3d`: nothing checks `settled` before
  `TransferBuffers`, and the deadline settles regardless of an in-flight pull;
* `checkSettledBeforePull` — the naive fix: skip the pull if already settled
  (`findings/candidate_fixes.patch` does this);
* `deferSettleWhilePullInFlight` — the naive fix plus: the deadline does not
  settle while a pull is in flight; the pull's completion settles. This is
  what the sibling `WriteRemote` path already does
  (`kv_cache_store_service.cc` `DeadlineLoop`, finding R-D).

## Property

`NoWriteAfterRelease`: the caller never reuses the destination blocks while a
pull into them is in flight (issued and not done).

## Results

* Shipping code violates it two ways. **Shape A** (late issue): the deadline
  settles, the caller takes its blocks back, the acquire reply arrives
  afterwards and the pull is issued into them anyway. **Shape B** (in flight): the pull is
  issued, the deadline settles while it runs, the caller reuses the blocks
  under the DMA. Shape A is confirmed by a C++ test (`findings/`); shape B is
  the case the deadline exists for.
* The naive fix closes A and not B.
* Deferring the deadline's settle while a pull is in flight has no violation
  anywhere in the reachable state space (`deferred_settle_is_safe`). Its cost:
  a hung pull holds the caller until it resolves. A complete fix needs
  cancellation, or settle-with-error while the blocks stay quarantined.
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

/-- The acquire callback (`:1018-1077`). -/
def acquireReply (impl : Impl) (ok : Bool) (s : S) : Option S :=
  if s.acquired then none
  else if !ok || s.shutdown then
    -- `:1028` / `:1072`: settle, no pull.
    some { s with acquired := true, settled := true }
  else
    let issue := match impl with
      | .shipping => true
      | .checkSettledBeforePull | .deferSettleWhilePullInFlight => !s.settled
    some { s with acquired := true, pullIssued := issue }

/-- Controller teardown detaches in-flight reads (`:318`). -/
def shutdownCtrl (s : S) : Option S :=
  if s.shutdown then none else some { s with shutdown := true }

/-- The deadline thread (`:1084-1104`). -/
def deadline (impl : Impl) (s : S) : Option S :=
  if s.deadlineFired then none
  else
    let settleNow := match impl with
      | .deferSettleWhilePullInFlight => !s.pullInFlight
      | _ => true
    some { s with deadlineFired := true, settled := s.settled || settleNow }

/-- `transfer.OnReady` → `ReleaseReadLease` → `Settle(verdict)` (`:1169-1210`). -/
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

end TpuSyncVerify.Controller.ReadRemote
