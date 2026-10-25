import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.PrefillDecode.Send.Progress
import TpuSyncVerify.Transfer.PrefillDecode.Send.Frame

/-! # `Send`: replay of upstream tests, bounded searches, failure phase

Part of `TpuSyncVerify.Transfer.PrefillDecode.Send`. -/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)

namespace Send

/-! ## Replay and bounded search

Concrete traces, checked by `decide`, that document the behaviours the model
admits; and a bounded search confirming that no `Safe` violation is reachable
within a few events. The inductive proof above is the actual guarantee; the
search guards against a modelling slip making the proof vacuous. -/

/-- A two-layer send that completes and is published as `done_sending`. Note
the push chain: layer 1's push is only issued after layer 0's, and
`sendNext` after the last layer takes no op. -/
theorem trace_normal :
    ((sys 2).run
      [.beginPull, .start, .d2hBegin, .d2hIssue true, .d2hBegin, .d2hIssue true,
       .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext,
       .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext,
       .h2hDone true, .h2hDone true, .publish]).map
      (fun s => (s.life.done, s.published, s.h2hOk, s.life.inFlight)) =
      some (true, some true, 2, 0) := by
  decide

/-- "One nobody pulled is reported now" (`CompleteReadWithDetails`;
`SendDrainTest.SendNobodyPulledFailsAtItsDeadline` and
`SendDeadlineTest.ExpiredSendSessionFailsInsteadOfReportingDone`): before the
deadline an unpulled send holds its `Lifecycle` staging token (`hasStaging = true`
by the `Session.lean` convention) and cannot be published; once the deadline
fires on the idle send it settles at once (`hasStaging = false`), publishes
failure (`some false`), and the model also checks that any late `.beginPull`
(`ControlHandshakeTest.PullAfterRegistrationDeadlineIsRejected`) or `.start` is
rejected. The `[.cancel, .publish]` conjunct is also
`SendLifecycleTest.FailedSendWithoutWorkSettlesImmediately`
(a synthetic send with `in_flight = 0` failed via `Decide(failed = true)` settles,
releases staging and is reported in `failed_recving` at once). -/
theorem trace_never_pulled :
    ((sys 2).run []).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (false, true, none) ∧
    (sys 2).run [.publish] = none ∧
    (sys 2).run [.start] = none ∧
    ((sys 2).run [.cancel, .publish]).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) ∧
    (sys 2).run [.cancel, .beginPull] = none ∧
    (sys 2).run [.cancel, .start] = none := by
  decide

/-- `ControlHandshakeTest.DuplicatePullIsRejectedBeforeAcknowledgement`: once
`ValidateAndBeginPull` (`.beginPull`) has claimed `pull_started_ = true`, any
duplicate pull is rejected both before and after `StartPush` (`.start`) begins
(the C++ test sets `pull_started_` through the `MarkPullStarted` hook and checks
only the pre-`StartPush` duplicate; the post-`StartPush` conjunct is
model-only). -/
theorem trace_duplicate_pull_rejected :
    ((sys 1).run [.beginPull]).map (fun s => (s.pullStarted, s.started)) = some (true, false) ∧
    (sys 1).run [.beginPull, .beginPull] = none ∧
    (sys 1).run [.beginPull, .start, .beginPull] = none := by
  decide

/-- `HandlePullStream` worker spawn failure (`hooks::kKvCacheManagerPullSpawn`):
if `ValidateAndBeginPull` (`.beginPull`) succeeds but spawning the `StartPush`
thread fails, `counter_cleanup` calls `session->Finish(InternalError)`
(`.cancel`), which settles the session at once, releases staging, reports
failure, and blocks any late `.start`
(`TransferSendSessionTest.FinishBeforeStartPushDoesNotAcquireStagingOrAccessHbm`). -/
theorem trace_pull_spawn_failure_cleanup :
    ((sys 1).run [.beginPull, .cancel, .publish]).map
      (fun s => (s.pullStarted, s.started, s.life.done, s.life.hasStaging, s.published)) =
      some (true, false, true, false, some false) ∧
    (sys 1).run [.beginPull, .cancel, .start] = none := by
  decide

/-- The deadline fires while a copy runs: the send drains, keeps its staging,
issues nothing more, and settles when the copy's `OnReady` ends the op
(`SendDrainTest.ExpiredSendKeepsItsStagingUntilTheCopyEnds`;
analogous `TransferSendSessionTest.SendSessionImplementsTransferSessionInterface`:
one layer, `Finish(error)` with a D2H in flight while `SendNextLayer(0)`'s op
also drains). -/
theorem trace_deadline_during_copy :
    ((sys 2).run [.beginPull, .start, .d2hBegin, .d2hIssue true, .cancel]).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    (sys 2).run [.beginPull, .start, .d2hBegin, .d2hIssue true, .cancel, .d2hBegin] = none ∧
    ((sys 2).run [.beginPull, .start, .d2hBegin, .d2hIssue true, .cancel, .d2hReady, .d2hEnd, .publish]).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) := by
  decide

/-- A push fails: the session drains, the layer still waiting in the chain is
dropped by `h2hIssue`'s re-check, and the send is published as failed. No C++
test exercises this "both copies done, next layer queued" shape:
`FakeSendBase::CompleteH2h(i, error)`
accepts an error status but every caller passes success; the one test that does
fail a push, `SendDrainTest.DetailsSayAFailedPushFailedInPushWhileCopiesRun`,
is the "copy still running" shape replayed by
`trace_details_failed_push_while_copies_run`. -/
theorem trace_push_fails :
    ((sys 2).run
      [.beginPull, .start, .d2hBegin, .d2hIssue true, .d2hBegin, .d2hIssue true,
       .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext,
       .d2hReady, .d2hEnd, .wake true, .h2hDone false, .h2hIssue, .publish]).map
      (fun s => (s.life.done, s.h2hIssued, s.published)) = some (true, 1, some false) := by
  decide

/-- Correspondence note (1): the OK finish happens in the last push callback
while a D2H `OnReady` may still be outstanding; a `Finish(error)` in that
window is ignored (`SendLifecycleTest.FailureCannotOverrideAnEarlierSuccess`;
analogous `TransferSendSessionTest.StatusIsFrozenOnceSessionIsDrainingOrDone`,
where the OK finish is an external `Finish(OkStatus())`). -/
theorem trace_cancel_after_ok_finish :
    ((sys 1).run
      [.beginPull, .start, .d2hBegin, .d2hIssue true, .d2hReady, .wake true, .h2hIssue, .sendNext,
       .h2hDone true, .cancel, .d2hEnd, .publish]).map
      (fun s => (s.life.statusOk, s.published)) = some (true, some true) := by
  decide

/-- A zero-layer send finishes OK inside `StartPush`
(`TransferSendSessionTest.ZeroLayerSessionCompletesAndReleasesStagingWithoutHang`). -/
theorem trace_zero_layers :
    ((sys 0).run [.beginPull, .start, .publish]).map (fun s => s.published) = some (some true) := by
  decide

/-- `TransferSendSessionTest.DoneGuaranteesAllResourcesReleasedAndNoHbmOrTransportAccessAfterDone`:
two layers; layer 0's H2H push and layer 1's D2H copy are both in flight when
`Finish(DeadlineExceeded)` fires; layer 0's H2H completes first (`done` stays
`false`, `hasStaging` stays `true`); when layer 1's D2H completes, `wake` sees
`draining`, drops layer 1's H2H (`h2hIssued = 1`), and settles (`done = true`,
`hasStaging = false`), after which `.start` is rejected. -/
theorem trace_drain_h2h_and_d2h :
    let pre := [.beginPull, .start, .d2hBegin, .d2hIssue true, .d2hBegin, .d2hIssue true,
                .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext,
                .cancel, .h2hDone true]
    ((sys 2).run pre).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    ((sys 2).run (pre ++ [.d2hReady, .d2hEnd, .wake true, .publish])).map
      (fun s => (s.life.done, s.life.hasStaging, s.h2hIssued, s.published)) =
      some (true, false, 1, some false) ∧
    (sys 2).run (pre ++ [.d2hReady, .d2hEnd, .wake true, .start]) = none := by
  decide

/-- `SendDrainTest.FailedLayerWaitsForTheOtherLayersCopies`: two layers; layer 0's
D2H copy fails while layer 1's D2H copy is still running; the failure and
staging slot are held back until layer 1's copy finishes. -/
theorem trace_failed_d2h_waits_for_other_layer :
    let pre := [.beginPull, .start, .d2hBegin, .d2hIssue true, .d2hBegin, .d2hIssue true,
                .d2hReady, .wake false, .d2hEnd]
    ((sys 2).run pre).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    (sys 2).run (pre ++ [.publish]) = none ∧
    ((sys 2).run (pre ++ [.d2hReady, .d2hEnd, .publish])).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) := by
  decide

/-- `SendLifecycleTest.SuccessCannotOverrideAnEarlierFailure` (the C++ test calls
`Decide(true)` then `Decide(false)` while a D2H copy is in flight, which this
trace exercises via `.cancel` followed by `.h2hDone true`), and the lifecycle
assertion of `TransferSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsWhenCancelledMidPush`
and `TransferSendSessionTest.PooledPolicyKeepsIdlePeerConnectionsWhenCancelledMidPush`:
dual of `trace_cancel_after_ok_finish`. If `Finish(error)` runs while the last
push is in flight, a subsequent OK push completion (`h2hDone true` calling
`finish true`) cannot override the earlier failure. -/
theorem trace_ok_after_cancel_keeps_failure :
    ((sys 1).run
      [.beginPull, .start, .d2hBegin, .d2hIssue true, .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext,
       .cancel, .h2hDone true, .publish]).map
      (fun s => (s.life.done, s.life.statusOk, s.published)) = some (true, false, some false) := by
  decide

def events : List Ev :=
  [.beginPull, .start, .d2hBegin, .d2hIssue true, .d2hIssue false, .d2hReady, .d2hEnd,
   .wake true, .wake false, .h2hIssue, .sendNext, .h2hDone true, .h2hDone false,
   .cancel, .publish]

instance (s : Send) : Decidable (Safe s) := by
  unfold Safe SettleSafe Drained StagingIntegrity SettlesPromptly NoUnderflow Publication CountersOrdered NoOpLeak PullClaimed
  infer_instance

/-- Executable negation of `Safe`, by construction: the bounded searches and the
`reachable_safe` theorem check the same predicate. -/
def violates (s : Send) : Bool := !decide (Safe s)

theorem violates_iff (s : Send) : violates s = false ↔ Safe s := by
  simp [violates]

/-- Sanity check on the search itself: a `Finish` that settles at once, ignoring
in-flight work, must be caught. -/
def cancelEager (s : Send) : Option Send :=
  some { s with life := { s.life with draining := true, done := true, hasStaging := false } }

#guard (match ModelCheck.check ⟨init 1, fun s e => match e with
          | .cancel => cancelEager s
          | e => step s e⟩ events violates 8 with
        | .counterexample _ => true
        | _ => false)

/-- And the point of the op `SendNextLayer` takes (`++in_flight_`): without it a
send whose copies have all ended settles under a `Finish`, and the pool task
that then runs ends an op the session no longer owns. -/
def trySendNextUncounted (s : Send) : Send :=
  if s.queued < s.d2hIssued ∧ s.life.draining = false then { s with queued := s.queued + 1 } else s

def sendNextUncounted (s : Send) : Option Send :=
  if s.chaining = 0 then none
  else some { s with chaining := s.chaining - 1 }.trySendNextUncounted.endOp

def d2hIssueUncounted (ok : Bool) (s : Send) : Option Send :=
  if s.d2hPending = false then none
  else
    let s := { s with d2hPending := false }
    if ok then
      let s := { s with d2hIssued := s.d2hIssued + 1 }
      some (if s.d2hIssued = s.numLayers then s.trySendNextUncounted else s)
    else some (s.finish false).endOp

#guard (match ModelCheck.check ⟨init 1, fun s e => match e with
          | .sendNext => sendNextUncounted s
          | .d2hIssue ok => d2hIssueUncounted ok s
          | e => step s e⟩ events violates 9 with
        | .counterexample _ => true
        | _ => false)

/-- Mutant for `NoOpLeak`: `SendNextLayer(l)` omits the
`l >= base_->num_layers()` / `l >= d2h_layer_futures_.size()`
bounds checks and takes an op unconditionally. After the last
layer's pool task calls `SendNextLayer(numLayers)`, that call claims
an op for a non-existent layer whose D2H future never becomes ready, leaking the
session and its staging forever (`SettleSafe` holds vacuously, `NoOpLeak`
catches it). -/
def trySendNextUnbounded (s : Send) : Send :=
  match s.life.beginOp with
  | some l => { s with life := l, queued := s.queued + 1 }
  | none => s

def sendNextUnbounded (s : Send) : Option Send :=
  if s.chaining = 0 then none
  else some { s with chaining := s.chaining - 1 }.trySendNextUnbounded.endOp

#guard (match ModelCheck.check ⟨init 1, fun s e => match e with
          | .sendNext => sendNextUnbounded s
          | e => step s e⟩ events violates 9 with
        | .counterexample _ => true
        | _ => false)

/-! ## Failure phase (`TransferDetails`)

A failed session records the phase it failed in:
`FinishLocked(status, phase)` latches `failed_phase_` from the
explicit `phase` argument when the failing step knows it (`kD2hPhase` in
`SendNextLayer`'s `layer_future->OnReady`, `kPushPhase` in
`H2hWriteDirectAsync`'s callback) and otherwise from `CurrentPhaseLocked`,
and `Details()` reports it to
`CompleteReadWithDetails` (`transfer_details_[session->req_id()] = session->Details()`).
Nothing in the lifecycle reads it, so
it is not state here; `phase` below is `CurrentPhaseLocked` evaluated on the
model, and `failedPhase s e` is the value `FinishLocked` latches when event `e`
fails in state `s`. Inside `StartPush` before its locked section the model
has one state (`pullStarted ∧ ¬started`) where C++ has three phases —
`await_pull` before the endpoints are recorded (`remote_data_endpoints_ = remote_data_endpoints`),
`staging` while `AcquireStagingWithRetry` runs (the shape of
`TransferSendSessionTest.CancelledWhileWaitingForStagingExitsWithoutShuttingDownAllocator`),
`d2h` between `staging_ = *std::move(acquired)` and the `if (draining_ || done_)`
re-check — because `start` is atomic; `phase` reports
`awaitPull` for all three. No replayed test evaluates a phase in that window;
the `trace_details_*` theorems only read `phase` in states where the two agree. -/

/-- The four phases of `TransferSendSession::CurrentPhaseLocked` (`kAwaitPullPhase` .. `kPushPhase`). -/
inductive Phase
  | awaitPull | staging | d2h | push
  deriving Repr, DecidableEq

/-- `CurrentPhaseLocked`: no endpoints yet (`remote_data_endpoints_.empty()`, set at
`StartPush` entry, i.e. `started = false`) → `awaitPull`; some
D2H future missing or not ready (`d2h_layer_futures_.size() < base_->num_layers()`
or `!future.IsReady()`) → `d2h`; otherwise `push`.
The `staging_.empty()` branch (`staging`) is folded into `awaitPull`
because `start` is atomic (see above). -/
def phase (s : Send) : Phase :=
  if s.started = false then .awaitPull
  else if s.d2hIssued < s.numLayers ∨ s.d2hReady < s.d2hIssued then .d2h
  else .push

/-- The phase `FinishLocked` latches when `e` fails in `s`: the D2H completion
callback passes `kD2hPhase`, the push callback `kPushPhase`;
every other failure (`Finish(error)` from the deadline, shutdown,
spawn failure, or a copy that could not be issued in `StartPush`) takes the current
phase (`CurrentPhaseLocked()`). -/
def failedPhase (s : Send) : Ev → Phase
  | .wake false => .d2h
  | .h2hDone false => .push
  | _ => phase s

/-- `SendLifecycleTest.DetailsSayAnUnpulledSendTimedOutAwaitingItsPull`: a registered send
that nobody pulled expires in `await_pull` and is reported failed. -/
theorem trace_details_unpulled_send_awaits_pull :
    ((sys 1).run []).map (fun s => (phase s, failedPhase s .cancel)) =
      some (.awaitPull, .awaitPull) ∧
    ((sys 1).run [.cancel, .publish]).map (fun s => s.published) = some (some false) := by
  decide

/-- `SendDrainTest.DetailsSayAnExpiredSendWasStillCopying`: the deadline fires
with a D2H copy in flight; the failure is latched in `d2h`, and the send still
waits for the copy before it settles and is reported. -/
theorem trace_details_expired_while_copying :
    let pre := [.beginPull, .start, .d2hBegin, .d2hIssue true]
    ((sys 1).run pre).map (fun s => failedPhase s .cancel) = some .d2h ∧
    ((sys 1).run (pre ++ [.cancel])).map (fun s => (s.life.draining, s.life.done)) =
      some (true, false) ∧
    ((sys 1).run (pre ++ [.cancel, .d2hReady, .d2hEnd, .wake true, .publish])).map
      (fun s => (s.life.done, s.published)) = some (true, some false) := by
  decide

/-- `SendDrainTest.DetailsCarryTheErrorOfAFailedCopy`: a D2H copy
completes with an error; the completion callback latches `d2h` explicitly
(`self->FinishLocked(status_or.status(), kD2hPhase)`) and the send is reported failed. -/
theorem trace_details_failed_copy :
    let pre := [.beginPull, .start, .d2hBegin, .d2hIssue true, .d2hReady]
    ((sys 1).run pre).map (fun s => failedPhase s (.wake false)) = some .d2h ∧
    ((sys 1).run (pre ++ [.wake false, .d2hEnd, .publish])).map
      (fun s => (s.life.done, s.published)) = some (true, some false) := by
  decide

/-- `SendDrainTest.DetailsSayAFailedPushFailedInPushWhileCopiesRun`: two layers; layer
0's push fails while layer 1's copy is still running. `CurrentPhaseLocked` would
say `d2h` (a future is not ready), but the push callback passes `kPushPhase`
(`self->FinishLocked(push_res.status(), kPushPhase)`), so the failure is reported in `push`; the send still drains layer
1's copy before it settles. -/
theorem trace_details_failed_push_while_copies_run :
    let pre := [.beginPull, .start, .d2hBegin, .d2hIssue true, .d2hBegin, .d2hIssue true,
                .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext]
    ((sys 2).run pre).map (fun s => (phase s, failedPhase s (.h2hDone false))) =
      some (.d2h, .push) ∧
    ((sys 2).run (pre ++ [.h2hDone false])).map
      (fun s => (s.life.draining, s.life.done)) = some (true, false) ∧
    ((sys 2).run (pre ++ [.h2hDone false, .d2hReady, .d2hEnd, .wake true, .publish])).map
      (fun s => (s.life.done, s.published)) = some (true, some false) := by
  decide

/-! The five data-connection-policy tests
(`TransferSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsBeforeDone`,
`TransferSendSessionTest.PooledPolicyKeepsIdlePeerConnections`,
`TransferSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsWhenCancelledMidPush`,
`TransferSendSessionTest.PooledPolicyKeepsIdlePeerConnectionsWhenCancelledMidPush`,
`TransferSendSessionTest.CreateRejectsUnknownDataConnReuseValue`) exercise
`TPU_RAIDEN_DATA_CONN_REUSE` parsing and the transport's idle-connection
counts, which are unmodelled: under `per_transfer` the last `EndSendOp` of a
draining send closes connections in a window where `in_flight_ == 1`,
`draining_` and `!done_` are all fixed (`ReleaseDataConnectionsAfterSend`, A7),
so the model's atomic `endOp` is unchanged. Their lifecycle content is already
replayed: the two `…CancelledMidPush` tests (`Finish(Cancelled)` with a push in
flight keeps `Done()` false until the push completes, then the status stays
`kCancelled`) are `trace_ok_after_cancel_keeps_failure`; `…BeforeDone` is a
one-layer `trace_normal`. -/


end Send

end TpuSyncVerify.Transfer.PrefillDecode
