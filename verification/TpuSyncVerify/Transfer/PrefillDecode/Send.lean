import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.Session

/-!
# Send session

Producer side of the prefill-to-decode model: one `TransferSendSession` on the
prefill (producer) side and the slice of `KVCacheManagerWithTransfer` that
drives it. The sender stages each layer's device blocks into host staging
(D2H), pushes the staging to the consumer (H2H) layer by layer, and must not
let the engine reuse the device blocks, or the allocator reseat the staging,
while any copy or push is still running. Memory contents are in `Pipeline.lean`.

Citations are to the baseline commit in `verification/README.md` §Status.
`send.h`/`send.cc` are `tpu_sync/kv_cache/transfer_send_session.{h,cc}`;
`mgr.cc` is `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`; `bt.cc` is
`tpu_sync/transport/block_transport.cc`. Exact line ranges for every symbol,
sub-block, and test are in the generated `## Source map` table below.

## How a send runs

`StartPush` runs once on a worker thread spawned by the
consumer's pull request (`HandlePullStream`'s `std::thread`). It acquires staging
(`AcquireStagingWithRetry`), then issues one D2H copy per layer in a loop
(`for (size_t l = 0; l < total_layers; ++l)`), each counted in `in_flight_` from
before its dispatch until its future's `layer_future.OnReady` callback ends the
op (`self->EndSendOp()`). After the loop it calls `SendNextLayer(0)`.

`SendNextLayer(l)` takes an op (`layer_future = d2h_layer_futures_[l]; ++in_flight_`)
and waits on layer `l`'s D2H future. When it is ready (`layer_future->OnReady`)
the layer is handed to the push pool (`self->base_->push_pool()->Schedule`),
whose task takes a second op (`++self->in_flight_`) for the H2H push,
issues it (`H2hWriteDirectAsync`), calls `SendNextLayer(l + 1)`, and only then
releases the first op via its `absl::Cleanup end_op`. The push's callback
releases the second op and, when the last layer's push completes
(`remaining_h2h_layers_.fetch_sub(1) == 1`), finishes the session OK
(`self->Finish()`).

So two chains run against the same `in_flight_`: the D2H copies, all issued up
front, and the pushes, strictly one layer after another. The session settles
when both have drained after a `Finish`.

## State

The settle protocol is `Transfer.Lifecycle`. On top of it:

| Field        | C++                                             | Role |
|--------------|-------------------------------------------------|------|
| `numLayers`  | `base_->num_layers()`                           | fixed |
| `pullStarted`| `pull_started_` (`TransferSendSession`)         | `ValidateAndBeginPull` claimed the offer |
| `started`    | `StartPush` passed its locked section (`host_block_ids.assign` .. `dst_ints_.assign`) | staging acquired, copies may start |
| `d2hPending` | ghost                                           | the D2H loop is between `++in_flight_` and `D2hSyncDispatch`'s outcome |
| `d2hIssued`  | `d2h_layer_futures_.size()` (`TransferSendSession`) | copies handed to the device |
| `d2hReady`   | futures with `IsReady()`                        | copies finished |
| `d2hRetired` | ghost                                           | copies whose `layer_future.OnReady` in `StartPush` has ended their op |
| `queued`     | ghost                                           | `SendNextLayer(l)` calls that took their op (`++in_flight_`) |
| `woken`      | ghost                                           | of those, the future callback (`layer_future->OnReady`) has run |
| `pooled`     | ghost                                           | layers scheduled on `push_pool()->Schedule` whose task has not run |
| `h2hIssued`  | ghost                                           | pushes handed to the transport (`H2hWriteDirectAsync`) |
| `chaining`   | ghost                                           | pool tasks that issued their push and still hold the `SendNextLayer` op (`H2hWriteDirectAsync` .. `SendNextLayer(l + 1)`) |
| `h2hRetired` | ghost                                           | push callbacks (`H2hWriteDirectAsync` callback) that have run |
| `h2hOk`      | `num_layers - remaining_h2h_layers_` (`TransferSendSession`) | pushes that completed OK |
| `published`  | membership in `done_sending_` / `failed_recving_` (`CompleteReadWithDetails`) | what `poll_stats()` shows the engine |
| `underflow`  | —                                               | `EndSendOpLocked` ran with `in_flight_ == 0` |

Ghost fields record where each unit of `in_flight_` came from, which is what
`Accounted` is about. `underflow` exists because `EndSendOpLocked`
decrements `--in_flight_` without a guard; the model records the event
instead of silently saturating so that `NoUnderflow` is a theorem.

## Events

| Event          | C++ |
|----------------|-----|
| `beginPull`    | `ValidateAndBeginPull` (called from `HandlePullStream`): rejects if `deadline_ <= now` (modelled together with pre-pull cancellation via `draining`/`done`) or `pull_started_` is already set, otherwise sets `pull_started_ = true` |
| `start`        | `StartPush` from the acquisition (`AcquireStagingWithRetry`) through its locked section, spawned after `ValidateAndBeginPull`: a zero-layer send (`total_layers == 0`) calls `FinishLocked(absl::OkStatus())` at once |
| `d2hBegin`     | one iteration of `StartPush`'s D2H loop up to `++in_flight_` (`if (draining_) return; ++in_flight_;`) |
| `d2hIssue ok`  | the dispatch (`D2hSyncDispatch`): failure finishes the session and ends the op (`FinishLocked(future.status()); EndSendOpLocked()`); success records the future (`d2h_layer_futures_.push_back(layer_future)`). For the last layer, `SendNextLayer(0)` (up to its lock) is attempted as part of the event |
| `d2hReady`     | the device finishes a copy: its future becomes `IsReady()` |
| `d2hEnd`       | the copy's `layer_future.OnReady` in `StartPush` ends its op via `EndSendOp` (see the lock-window note below) |
| `wake ok`      | `SendNextLayer`'s `layer_future->OnReady` callback: a failed copy finishes the session (`self->FinishLocked(status_or.status(), kD2hPhase)`); a draining session drops the layer (`if (self->draining_) return;`); otherwise the layer is scheduled on `push_pool()->Schedule` and `std::move(end_op).Cancel()` carries the op over |
| `h2hIssue`     | the `push_pool` task up to the push: a draining session (`if (self->draining_) return;`) drops the layer and ends the op via `absl::Cleanup end_op`; otherwise a second op is taken (`++self->in_flight_`) and the push issued (`H2hWriteDirectAsync` → `BlockTransport::AsyncPush`, which fans a layer out into one stream group per source NUMA node via `AsyncPushShards` and joins them via `tsl::JoinFutures` into this one callback; the callback may even run inline on an argument error) |
| `sendNext`     | the pool task's `SendNextLayer(l + 1)` followed by the release of the carried-over op (`absl::Cleanup end_op`) |
| `h2hDone ok`   | the `H2hWriteDirectAsync` push callback: failure finishes the session (`self->FinishLocked(push_res.status(), kPushPhase)`); the last OK push (`remaining_h2h_layers_.fetch_sub(1) == 1`) finishes it OK (`self->Finish()`); the op ends either way |
| `cancel`       | any `Finish(error)` from outside the data path: deadline (`CompleteReadWithDetails`), shutdown (`~KVCacheManagerWithTransfer`), pull-worker spawn failure (`HandlePullStream`'s `counter_cleanup`), staging acquisition failure (`!acquire_status.ok()`), bad arguments in `StartPush` (`src_block_ids.empty() || ...`), pull-worker exceptions (`HandlePullStream`'s `catch`) |
| `publish`      | `CompleteReadWithDetails` / `CompleteReadRaw` moves a settled session (`session->Done()`) into `done_sending_` or `failed_recving_` by its status and erases it from `send_sessions_` |

## Assumptions

* **A1 (at-most-once `StartPush`).** `ValidateAndBeginPull`
  rejects a duplicate pull or an expired offer and sets `pull_started_ = true`;
  the model's `beginPull` does the same and gates `start`
  (`PullClaimed`), so a second `StartPush` on one session is unreachable.
* **A2 (sequential loop).** The D2H loop is one thread, so at most one
  dispatch is between its `++in_flight_` and its outcome: `d2hPending` is a
  `Bool`.
* **A3 (layers are interchangeable).** The model counts copies and pushes
  rather than naming layers. `SendNextLayer` is chained in layer order
  (`0, 1, …`), so when `SendNextLayer(k)`'s callback wakes in C++, layers
  `0 … k-1` have already woken and layer `k`'s future is ready — hence at
  least `k + 1` futures are ready (`woken < d2hReady`), even if later layers'
  D2H copies finished earlier. Since no event's effect on the counters depends
  on which layer finished, any real interleaving maps onto one the model
  admits.
* **A4 (no double end).** Each op ends once: every op-ending event is guarded
  by the ghost counter that opened it.
* **A5 (no consumer Ack).** `HandleAck → AckSend → session->Finish()`
  would finish a send OK from outside. No code in the repository
  sends an Ack (`SendAck` has only test callers), so it is not an
  event; nor is the ack-first path of `NotifyForRead`, which reports
  `done_sending` without registering the session when `pending_acks_.erase(uuid) > 0`
  (filled only by `AckSend` when `it == send_sessions_.end()`). With it,
  `Publication` below would read "the consumer acked", not "every layer was
  pushed".
* **A6 (fold of `SendNextLayer(0)`).** Between recording the last future
  (`d2h_layer_futures_.push_back(layer_future)`) and `SendNextLayer(0)`'s lock,
  only a `Finish` can change the outcome of the attempt, and it has the same
  effect ordered before the event; the two are one event.

* **A7 (connection release window).** `EndSendOp`
  is modelled as the atomic `endOp`. Under `TPU_RAIDEN_DATA_CONN_REUSE=per_transfer`
  (default `pooled`, which never enters this branch) the last op of a draining
  send first drops `mu_` to close the idle data connections to the consumer
  (`ReleaseDataConnectionsAfterSend`; the branch `release_due` also needs
  `!remote_data_endpoints_.empty()` and `!connections_released_`) and only then
  runs `EndSendOpLocked`. In that window `in_flight_ == 1`, `draining_` and
  `!done_` hold: no new op can begin (`beginOp` refuses while `draining_` in
  `StartPush` and `SendNextLayer`), no other op can end (this is the only one,
  A3), `FinishLocked` returns at `if (draining_ || done_) return;`,
  `ValidateAndBeginPull` throws on `if (pull_started_)`, and the poll cannot
  publish (`Done()` is false), so no modelled variable changes between the
  check and the decrement; `connections_released_` only stops a second pass.
  The direct `EndSendOpLocked()` on a copy that could not be issued in
  `StartPush` bypasses the window, but no push exists then. The window delays
  `done_`, which every trace already allows between events.

## Properties

All proved on every reachable state (`reachable_safe`):

* **Settle safety.** `done → inFlight = 0`.
* **Drained.** `done →` no copy is pending or unretired, no `SendNextLayer`
  callback, pool task or push is outstanding. In particular no D2H copy still
  reads the device blocks (so the engine may reuse them) or writes the staging,
  and no push still reads the staging (so the allocator may reseat it). This is
  what the comments on `in_flight_` (`TransferSendSession`) and the
  send-deadline loop in `CompleteReadWithDetails` promise.
* **Staging integrity.** `hasStaging = !done`: staging, once acquired, is held
  exactly until the session settles.
* **Prompt settle.** `draining → inFlight = 0 → done`.
* **No underflow.** `EndSendOpLocked` never runs on an idle session.
* **Publication.** `published = some true → h2hOk = numLayers`: when the
  engine is told `done_sending`, every layer's push completed OK. Counter-level
  form of *publication correctness* for the producer.
* **Counters.** The two chains are ordered:
  `d2hRetired ≤ d2hReady ≤ d2hIssued ≤ numLayers`,
  `woken ≤ queued ≤ d2hIssued`, `woken ≤ d2hReady`,
  `pooled + h2hIssued ≤ woken`, `h2hOk ≤ h2hRetired ≤ h2hIssued`.
* **Pull claim (`PullClaimed`).** `(started → pullStarted) ∧ ((d2hPending ∨ 0 < d2hIssued) → started)`:
  `StartPush` never runs unless `ValidateAndBeginPull` claimed `pull_started_`,
  and no D2H copy is pending or issued unless `StartPush` started.
* **No op leak.** `0 < inFlight →` some event in `drainEvents` is enabled:
  every accounted unit of `in_flight_` has an owner that can advance or retire
  it (`NoOpLeak`), and every reachable state can drain to `done = true` and
  release its staging in a finite number of steps (`reachable_can_settle`).

Correspondence notes. (1) The sender's `FinishLocked` ignores every call after
the first (`Lifecycle.finishOnceLocked`), unlike the receiver's. An OK finish
happens inside the last push callback while D2H `OnReady`s may still be
outstanding, so a shutdown or deadline in that window leaves the status OK
(`trace_cancel_after_ok_finish`); harmless, since the send did complete.
(2) A failed send is reported in `failed_recving_` (`CompleteReadWithDetails`),
there is no `failed_sending_`. (3) The D2H loop's `if (draining_) return;` in
`StartPush` also skips `SendNextLayer(0)`, which is fine because every later
`SendNextLayer` re-checks `draining_`.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `send.h` | `TransferSendSession` (`bool pull_started_` .. `std::atomic<size_t> remaining_h2h_layers_`) | `:211-227` |
| `send.cc` | `*` (`constexpr absl::string_view kAwaitPullPhase` .. `constexpr absl::string_view kPushPhase`) | `:55-58` |
| `send.cc` | `TransferSendSession::ValidateAndBeginPull` | `:142-156` |
| `send.cc` | `TransferSendSession::FinishLocked` | `:193-206` |
| `send.cc` | `TransferSendSession::Finish` | `:208-217` |
| `send.cc` | `TransferSendSession::Details` | `:225-241` |
| `send.cc` | `TransferSendSession::CurrentPhaseLocked` | `:243-251` |
| `send.cc` | `TransferSendSession::EndSendOpLocked` | `:253-260` |
| `send.cc` | `TransferSendSession::EndSendOp` | `:262-289` |
| `send.cc` | `TransferSendSession::AcquireStagingWithRetry` | `:322-356` |
| `send.cc` | `TransferSendSession::StartPush` | `:358-457` |
| `send.cc` | `TransferSendSession::StartPush` (`if (src_block_ids.empty()`) | `:369-374` |
| `send.cc` | `TransferSendSession::StartPush` (`absl::Status acquire_status =` .. `dst_ints_.assign`) | `:380-403` |
| `send.cc` | `TransferSendSession::StartPush` (`for (size_t l = 0; l < total_layers; ++l)`) | `:417-454` |
| `send.cc` | `TransferSendSession::StartPush` (`layer_future.OnReady`) | `:450-453` |
| `send.cc` | `TransferSendSession::SendNextLayer` | `:459-547` |
| `send.cc` | `TransferSendSession::SendNextLayer` (`if (l >= base_->num_layers())` .. `++in_flight_;`) | `:462-474` |
| `send.cc` | `TransferSendSession::SendNextLayer` (`layer_future->OnReady`) | `:477-546` |
| `send.cc` | `TransferSendSession::SendNextLayer` (`self->base_->push_pool()->Schedule`) | `:500-545` |
| `send.cc` | `TransferSendSession::SendNextLayer` (`self->base_->H2hWriteDirectAsync`) | `:518-540` |
| `mgr.cc` | `KVCacheManagerWithTransfer::~KVCacheManagerWithTransfer` (`for (const auto& [uuid, session] : send_sessions_)`) | `:376-380` |
| `mgr.cc` | `KVCacheManagerWithTransfer::NotifyForRead` | `:462-509` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`for (auto it = send_sessions_.begin();`) | `:964-986` |
| `mgr.cc` | `KVCacheManagerWithTransfer::HandlePullStream` | `:1236-1362` |
| `mgr.cc` | `KVCacheManagerWithTransfer::HandlePullStream` (`absl::Cleanup counter_cleanup` .. `std::move(counter_cleanup).Cancel();`) | `:1321-1344` |
| `mgr.cc` | `KVCacheManagerWithTransfer::HandleAck` | `:1364-1367` |
| `mgr.cc` | `KVCacheManagerWithTransfer::AckSend` | `:1430-1453` |
| `bt.cc` | `BlockTransport::AsyncPush` | `:959-991` |
| `send_drain_test.cc` | `SendDrainTest.ExpiredSendKeepsItsStagingUntilTheCopyEnds` | `:324-348` |
| `send_drain_test.cc` | `SendDrainTest.SendNobodyPulledFailsAtItsDeadline` | `:370-379` |
| `send_drain_test.cc` | `SendDrainTest.FailedLayerWaitsForTheOtherLayersCopies` | `:350-368` |
| `send_drain_test.cc` | `SendLifecycleTest.FailedSendWithoutWorkSettlesImmediately` | `:435-445` |
| `send_drain_test.cc` | `SendLifecycleTest.FailureCannotOverrideAnEarlierSuccess` | `:467-479` |
| `send_drain_test.cc` | `SendLifecycleTest.SuccessCannotOverrideAnEarlierFailure` | `:481-493` |
| `send_drain_test.cc` | `SendLifecycleTest.DetailsSayAnUnpulledSendTimedOutAwaitingItsPull` | `:513-534` |
| `send_drain_test.cc` | `SendDrainTest.DetailsSayAnExpiredSendWasStillCopying` | `:536-553` |
| `send_drain_test.cc` | `SendDrainTest.DetailsCarryTheErrorOfAFailedCopy` | `:555-568` |
| `send_drain_test.cc` | `SendDrainTest.DetailsSayAFailedPushFailedInPushWhileCopiesRun` | `:570-597` |
| `pool_reshard_test.cc` | `SendDeadlineTest.ExpiredSendSessionFailsInsteadOfReportingDone` | `:369-378` |
| `control_test.cc` | `ControlHandshakeTest.PullAfterRegistrationDeadlineIsRejected` | `:311-333` |
| `control_test.cc` | `ControlHandshakeTest.DuplicatePullIsRejectedBeforeAcknowledgement` | `:370-382` |
| `transfer_send_session_test.cc` | `FakeSendBase::CompleteH2h` | `:82-89` |
| `transfer_send_session_test.cc` | `TransferSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsBeforeDone` | `:189-212` |
| `transfer_send_session_test.cc` | `TransferSendSessionTest.PooledPolicyKeepsIdlePeerConnections` | `:214-234` |
| `transfer_send_session_test.cc` | `TransferSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsWhenCancelledMidPush` | `:236-268` |
| `transfer_send_session_test.cc` | `TransferSendSessionTest.PooledPolicyKeepsIdlePeerConnectionsWhenCancelledMidPush` | `:270-296` |
| `transfer_send_session_test.cc` | `TransferSendSessionTest.CreateRejectsUnknownDataConnReuseValue` | `:298-313` |
| `transfer_send_session_test.cc` | `TransferSendSessionTest.SendSessionImplementsTransferSessionInterface` | `:315-345` |
| `transfer_send_session_test.cc` | `TransferSendSessionTest.CancelledWhileWaitingForStagingExitsWithoutShuttingDownAllocator` | `:380-423` |
| `transfer_send_session_test.cc` | `TransferSendSessionTest.FinishBeforeStartPushDoesNotAcquireStagingOrAccessHbm` | `:425-452` |
| `transfer_send_session_test.cc` | `TransferSendSessionTest.DoneGuaranteesAllResourcesReleasedAndNoHbmOrTransportAccessAfterDone` | `:454-511` |
| `transfer_send_session_test.cc` | `TransferSendSessionTest.ZeroLayerSessionCompletesAndReleasesStagingWithoutHang` | `:550-569` |
| `transfer_send_session_test.cc` | `TransferSendSessionTest.StatusIsFrozenOnceSessionIsDrainingOrDone` | `:592-622` |
<!-- source-map:end -->
-/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)

structure Send where
  numLayers : Nat
  life : Lifecycle := {}
  pullStarted : Bool := false
  started : Bool := false
  d2hPending : Bool := false
  d2hIssued : Nat := 0
  d2hReady : Nat := 0
  d2hRetired : Nat := 0
  queued : Nat := 0
  woken : Nat := 0
  pooled : Nat := 0
  h2hIssued : Nat := 0
  chaining : Nat := 0
  h2hRetired : Nat := 0
  h2hOk : Nat := 0
  published : Option Bool := none
  underflow : Bool := false
  deriving Repr, DecidableEq

namespace Send

/-- A registered send (`NotifyForRead`) that nobody has
pulled yet. -/
def init (numLayers : Nat) : Send := { numLayers }

/-- `EndSendOpLocked`: `--in_flight_` and settle. The C++ has
no underflow check; the model records one instead of ignoring it. -/
def endOp (s : Send) : Send :=
  if s.life.inFlight = 0 then { s with underflow := true }
  else { s with life := s.life.endOpLocked }

/-- `Finish(status)` / `FinishLocked(status)`. -/
def finish (ok : Bool) (s : Send) : Send := { s with life := s.life.finishOnceLocked ok }

/-- `SendNextLayer(l)` up to its lock (`if (l >= base_->num_layers())` .. `++in_flight_;`)
for `l = queued`: takes an op unless the session is draining or layer `l`'s copy
was never issued. -/
def trySendNext (s : Send) : Send :=
  if s.queued < s.d2hIssued then
    match s.life.beginOp with
    | some l => { s with life := l, queued := s.queued + 1 }
    | none => s
  else s

inductive Ev where
  | beginPull
  | start
  | d2hBegin
  | d2hIssue (ok : Bool)
  | d2hReady
  | d2hEnd
  | wake (ok : Bool)
  | h2hIssue
  | sendNext
  | h2hDone (ok : Bool)
  | cancel
  | publish
  deriving Repr, DecidableEq

/-- `ValidateAndBeginPull`: rejects an expired offer
(`deadline_ <= now`; modelled together with pre-pull
cancellation via `draining`/`done`; the deadline is the only lifecycle check
`ValidateAndBeginPull` itself makes — `draining_`/`done_` are not read there,
but under A5 an unpulled send only drains by deadline or by shutdown, which
`HandlePullStream` rejects first via `stopping_.load()`) or a
duplicate pull (`if (pull_started_)`), and otherwise claims `pull_started_ = true`
before `HandlePullStream` spawns the `StartPush` worker thread. -/
def beginPull (s : Send) : Option Send :=
  if s.pullStarted = true ∨ s.life.draining = true ∨ s.life.done = true then none
  else some { s with pullStarted := true }

/-- `StartPush` with staging acquired, spawned after
`ValidateAndBeginPull` claimed `pull_started_` in `HandlePullStream`. A failed
acquisition (`!acquire_status.ok()`) or worker spawn failure (`HandlePullStream`'s
`counter_cleanup`) is `Finish(error)` with nothing in flight, i.e. `cancel`. On
a session that finished meanwhile the call returns (`if (draining_ || done_) return;`)
and nothing changes. -/
def start (s : Send) : Option Send :=
  if s.pullStarted = false ∨ s.started = true ∨ s.life.draining = true ∨ s.life.done = true then none
  else if s.numLayers = 0 then some (s.finish true)
  else some { s with started := true }

/-- One iteration of `StartPush`'s D2H loop up to `++in_flight_`. -/
def d2hBegin (s : Send) : Option Send :=
  if s.started = true ∧ s.d2hPending = false ∧ s.d2hIssued < s.numLayers then
    s.life.beginOp.map fun l => { s with life := l, d2hPending := true }
  else none

/-- The dispatch's outcome in `StartPush`. Failure: `FinishLocked(future.status()); EndSendOpLocked()`.
Success: the future is recorded (`d2h_layer_futures_.push_back(layer_future)`),
and after the last layer `SendNextLayer(0)` is attempted (A6). -/
def d2hIssue (ok : Bool) (s : Send) : Option Send :=
  if s.d2hPending = false then none
  else
    let s := { s with d2hPending := false }
    if ok then
      let s := { s with d2hIssued := s.d2hIssued + 1 }
      some (if s.d2hIssued = s.numLayers then s.trySendNext else s)
    else some (s.finish false).endOp

/-- A dispatched copy finishes on the device; its future becomes ready. -/
def markD2hReady (s : Send) : Option Send :=
  if s.d2hReady < s.d2hIssued then some { s with d2hReady := s.d2hReady + 1 } else none

/-- The copy's `layer_future.OnReady` in `StartPush` ends its op (`self->EndSendOp()`). -/
def d2hEnd (s : Send) : Option Send :=
  if s.d2hRetired < s.d2hReady then some { s with d2hRetired := s.d2hRetired + 1 }.endOp
  else none

/-- `SendNextLayer`'s `layer_future->OnReady` callback for layer `woken`, which
needs its copy ready. -/
def wake (ok : Bool) (s : Send) : Option Send :=
  if s.woken < s.queued ∧ s.woken < s.d2hReady then
    let s := { s with woken := s.woken + 1 }
    if ok = false then some (s.finish false).endOp
    else if s.life.draining = true then some s.endOp
    else some { s with pooled := s.pooled + 1 }
  else none

/-- The `push_pool()->Schedule` task in `SendNextLayer` up to and including `H2hWriteDirectAsync`. -/
def h2hIssue (s : Send) : Option Send :=
  if s.pooled = 0 then none
  else
    let s := { s with pooled := s.pooled - 1 }
    match s.life.beginOp with
    | some l => some { s with life := l, h2hIssued := s.h2hIssued + 1, chaining := s.chaining + 1 }
    | none => some s.endOp

/-- The pool task's tail in `SendNextLayer`: `self->SendNextLayer(l + 1)`, then
`absl::Cleanup end_op` ends the op it carried. -/
def sendNext (s : Send) : Option Send :=
  if s.chaining = 0 then none
  else some { s with chaining := s.chaining - 1 }.trySendNext.endOp

/-- The `H2hWriteDirectAsync` push callback in `SendNextLayer`. -/
def h2hDone (ok : Bool) (s : Send) : Option Send :=
  if s.h2hRetired < s.h2hIssued then
    let s := { s with h2hRetired := s.h2hRetired + 1 }
    if ok then
      let s := { s with h2hOk := s.h2hOk + 1 }
      some (if s.h2hOk = s.numLayers then (s.finish true).endOp else s.endOp)
    else some (s.finish false).endOp
  else none

/-- `Finish(error)` from outside the data path; enabled at any time. -/
def cancel (s : Send) : Option Send := some (s.finish false)

/-- `CompleteReadWithDetails` / `CompleteReadRaw` publishes a settled session
(`if (session->Done())`). -/
def publish (s : Send) : Option Send :=
  if s.life.done = true ∧ s.published = none then
    some { s with published := some s.life.statusOk }
  else none

def step (s : Send) : Ev → Option Send
  | .beginPull => s.beginPull
  | .start => s.start
  | .d2hBegin => s.d2hBegin
  | .d2hIssue ok => s.d2hIssue ok
  | .d2hReady => s.markD2hReady
  | .d2hEnd => s.d2hEnd
  | .wake ok => s.wake ok
  | .h2hIssue => s.h2hIssue
  | .sendNext => s.sendNext
  | .h2hDone ok => s.h2hDone ok
  | .cancel => s.cancel
  | .publish => s.publish

/-- A registered send with `n` layers. -/
def sys (n : Nat) : System Send Ev := ⟨init n, step⟩

/-! ## Properties -/

def SettleSafe (s : Send) : Prop := s.life.done = true → s.life.inFlight = 0

/-- A settled send has no copy, callback, pool task or push outstanding. -/
def Drained (s : Send) : Prop :=
  s.life.done = true →
    s.d2hPending = false ∧ s.d2hRetired = s.d2hIssued ∧ s.woken = s.queued ∧
      s.pooled = 0 ∧ s.chaining = 0 ∧ s.h2hRetired = s.h2hIssued

def StagingIntegrity (s : Send) : Prop := s.life.hasStaging = !s.life.done

def SettlesPromptly (s : Send) : Prop :=
  s.life.draining = true → s.life.inFlight = 0 → s.life.done = true

def NoUnderflow (s : Send) : Prop := s.underflow = false

def Publication (s : Send) : Prop := s.published = some true → s.h2hOk = s.numLayers

def CountersOrdered (s : Send) : Prop :=
  s.d2hRetired ≤ s.d2hReady ∧ s.d2hReady ≤ s.d2hIssued ∧
    s.d2hIssued + (if s.d2hPending then 1 else 0) ≤ s.numLayers ∧
    s.woken ≤ s.queued ∧ s.queued ≤ s.d2hIssued ∧ s.woken ≤ s.d2hReady ∧
    s.pooled + s.h2hIssued ≤ s.woken ∧
    s.h2hRetired ≤ s.h2hIssued ∧ s.h2hOk ≤ s.h2hRetired

/-- `StartPush` (`started = true`) only runs after `ValidateAndBeginPull`
claimed `pull_started_` (`pullStarted = true`), and no D2H copy is pending or
issued before `StartPush` starts. -/
def PullClaimed (s : Send) : Prop :=
  (s.started = true → s.pullStarted = true) ∧
  ((s.d2hPending = true ∨ 0 < s.d2hIssued) → s.started = true)

/-- Events that advance or retire an in-flight operation. -/
def drainEvents : List Ev :=
  [.d2hIssue true, .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext, .h2hDone true]

/-- Every unit of `in_flight_` has an owner that can advance or retire it:
while `inFlight > 0`, some event in `drainEvents` is enabled. -/
def NoOpLeak (s : Send) : Prop :=
  0 < s.life.inFlight → ∃ e ∈ drainEvents, (step s e).isSome = true

/-- Everything we want to know about a reachable send session. -/
def Safe (s : Send) : Prop :=
  SettleSafe s ∧ Drained s ∧ StagingIntegrity s ∧ SettlesPromptly s ∧ NoUnderflow s ∧
    Publication s ∧ CountersOrdered s ∧ NoOpLeak s ∧ PullClaimed s

/-! ## Inductive invariant -/

/-- Where every unit of `in_flight_` comes from: a dispatch in progress, a copy
whose `OnReady` has not ended it, a `SendNextLayer` waiting on its future, a
layer waiting for the pool, a pool task that has not released its op, or a
push whose callback has not run. -/
def Accounted (s : Send) : Prop :=
  s.life.inFlight =
    (if s.d2hPending then 1 else 0) + (s.d2hIssued - s.d2hRetired) + (s.queued - s.woken) +
      s.pooled + s.chaining + (s.h2hIssued - s.h2hRetired)

structure Inv (s : Send) : Prop where
  life : s.life.Consistent
  accounted : Accounted s
  no_underflow : s.underflow = false
  counters : CountersOrdered s
  pull_claimed : PullClaimed s
  /-- A send that started draining without an error had pushed every layer. -/
  ok_draining : s.life.statusOk = true → s.life.draining = true → s.h2hOk = s.numLayers
  /-- Only settled sessions are published. -/
  published_done : ∀ b, s.published = some b → s.life.done = true
  /-- Once published as done, every layer had been pushed (and still has). -/
  published_ok : s.published = some true → s.h2hOk = s.numLayers

theorem inv_init (n : Nat) : Inv (init n) := by
  refine ⟨Lifecycle.consistent_init, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    simp [init, Accounted, CountersOrdered, PullClaimed]

theorem inv_noOpLeak {s : Send} (h : Inv s) : NoOpLeak s := by
  intro hif
  have hacc := h.accounted
  have hcnt := h.counters
  unfold Accounted at hacc
  unfold CountersOrdered at hcnt
  by_cases hp : s.d2hPending = true
  · exact ⟨.d2hIssue true, by simp [drainEvents], by simp [step, d2hIssue, hp]⟩
  · by_cases hrd : s.d2hReady < s.d2hIssued
    · exact ⟨.d2hReady, by simp [drainEvents], by simp [step, markD2hReady, hrd]⟩
    · by_cases hret : s.d2hRetired < s.d2hReady
      · exact ⟨.d2hEnd, by simp [drainEvents], by simp [step, d2hEnd, hret]⟩
      · by_cases hwk : s.woken < s.queued
        · have hwr : s.woken < s.d2hReady := by omega
          refine ⟨.wake true, by simp [drainEvents], ?_⟩
          simp only [step, wake, hwk, hwr, and_self, ↓reduceIte, Bool.true_eq_false]
          split <;> rfl
        · by_cases hpool : 0 < s.pooled
          · have hne : s.pooled ≠ 0 := by omega
            refine ⟨.h2hIssue, by simp [drainEvents], ?_⟩
            simp only [step, h2hIssue, hne, ↓reduceIte]
            split <;> rfl
          · by_cases hch : 0 < s.chaining
            · exact ⟨.sendNext, by simp [drainEvents], by simp [step, sendNext]; omega⟩
            · have hh2h : s.h2hRetired < s.h2hIssued := by
                cases hdp : s.d2hPending <;> simp_all <;> omega
              exact ⟨.h2hDone true, by simp [drainEvents], by simp [step, h2hDone, hh2h]⟩

theorem inv_safe {s : Send} (h : Inv s) : Safe s := by
  have hnl := inv_noOpLeak h
  obtain ⟨hl, hacc, hu, hcnt, hpc, _, _, hpub⟩ := h
  unfold Accounted at hacc
  unfold CountersOrdered at hcnt
  refine ⟨hl.done_idle, ?_, hl.staging, hl.prompt, hu, hpub, hcnt, hnl, hpc⟩
  intro hd
  have h0 := hl.done_idle hd
  cases hp : s.d2hPending <;> simp [hp] at hacc ⊢ <;> omega

/-! ### Helpers for the step proof -/

theorem endOp_eq {s : Send} (h : 0 < s.life.inFlight) :
    s.endOp = { s with life := s.life.endOpLocked } := by
  unfold endOp
  split
  · omega
  · rfl

theorem trySendNext_cases (s : Send) :
    s.trySendNext = s ∨
    (s.queued < s.d2hIssued ∧ s.life.draining = false ∧ s.life.done = false ∧
      s.trySendNext = { s with life := { s.life with inFlight := s.life.inFlight + 1 },
                               queued := s.queued + 1 }) := by
  unfold trySendNext
  split
  · rename_i hlt
    split
    · rename_i l hb
      right
      obtain ⟨hd, hdr⟩ := Lifecycle.beginOp_active hb
      refine ⟨hlt, hdr, hd, ?_⟩
      unfold Lifecycle.beginOp at hb
      split at hb
      · cases hb
      · cases hb; rfl
    · left; rfl
  · left; rfl

/-- Each event preserves the invariant. -/
theorem step_inv {s s' : Send} {e : Ev} (h : Inv s) (hs : step s e = some s') : Inv s' := by
  obtain ⟨hl, hacc, hu, hcnt, hpc, hdr, hpd, hpub⟩ := h
  unfold Accounted at hacc
  unfold CountersOrdered at hcnt
  cases e with
  | beginPull =>
    simp only [step, beginPull] at hs
    split at hs
    · cases hs
    · cases hs
      refine ⟨hl, by unfold Accounted; simpa using hacc, hu,
        by unfold CountersOrdered; simpa using hcnt,
        ⟨fun _ => rfl, hpc.2⟩, hdr, hpd, hpub⟩
  | start =>
    simp only [step, start] at hs
    split at hs
    · cases hs
    · rename_i hng
      have hpulled : s.pullStarted = true := by
        cases hps : s.pullStarted
        · exact absurd (Or.inl hps) hng
        · rfl
      split at hs
      · cases hs
        dsimp only [finish]
        refine ⟨Lifecycle.finishOnceLocked_consistent true hl,
          by unfold Accounted; simpa using hacc, hu, hcnt, hpc,
          by intro _ _; simp; omega,
          fun b hp => Lifecycle.finishOnceLocked_done_mono true (hpd b hp), hpub⟩
      · cases hs
        exact ⟨hl, by unfold Accounted; simpa using hacc, hu,
          by unfold CountersOrdered; simpa using hcnt,
          ⟨fun _ => hpulled, fun _ => rfl⟩, hdr, hpd, hpub⟩
  | d2hBegin =>
    simp only [step, d2hBegin] at hs
    split at hs
    · rename_i hg
      obtain ⟨hst, hp, _⟩ := hg
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨l, hb, rfl⟩ := hs
      have := Lifecycle.beginOp_inFlight hb
      have hact := Lifecycle.beginOp_active hb
      have hdr' := Lifecycle.beginOp_draining hb
      refine ⟨Lifecycle.beginOp_consistent hl hb, ?_, hu, ?_, ⟨hpc.1, fun _ => hst⟩, ?_, ?_, hpub⟩
      · unfold Accounted; simp [hp] at hacc; simp; omega
      · unfold CountersOrdered; simp [hp] at hcnt; simp; omega
      · simp [hdr']
      · intro b hq
        have := hpd b hq
        simp [hact.1] at this
    · cases hs
  | d2hIssue ok =>
    simp only [step, d2hIssue] at hs
    split at hs
    · cases hs
    · rename_i hp
      have hp' : s.d2hPending = true := by
        cases hq : s.d2hPending
        · exact absurd hq hp
        · rfl
      have hst : s.started = true := hpc.2 (Or.inl hp')
      simp [hp'] at hacc hcnt
      split at hs
      · cases hs
        -- success: the copy is counted already; maybe `SendNextLayer(0)`
        split
        · rcases trySendNext_cases { s with d2hPending := false, d2hIssued := s.d2hIssued + 1 }
            with heq | ⟨hlt, hdr', hd', heq⟩
          · rw [heq]
            refine ⟨hl, ?_, hu, ?_, ⟨hpc.1, fun _ => hst⟩, hdr, hpd, hpub⟩
            · unfold Accounted; simp; omega
            · unfold CountersOrdered; simp; omega
          · rw [heq]
            simp at hlt hdr' hd'
            refine ⟨Lifecycle.consistent_incr hl hdr', ?_, hu, ?_, ⟨hpc.1, fun _ => hst⟩, ?_, ?_, hpub⟩
            · unfold Accounted; simp; omega
            · unfold CountersOrdered; simp; omega
            · simp [hdr']
            · intro b hq
              have := hpd b hq
              simp [hd'] at this
        · refine ⟨hl, ?_, hu, ?_, ⟨hpc.1, fun _ => hst⟩, hdr, hpd, hpub⟩
          · unfold Accounted; simp; omega
          · unfold CountersOrdered; simp; omega
      · cases hs
        dsimp only [finish]
        rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishOnceLocked_consistent false hl),
          ?_, hu, ?_, ⟨hpc.1, fun _ => hst⟩, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · intro hok _
          obtain ⟨h1, h2⟩ := hl.finishOnceLocked_false_statusOk (by simpa using hok)
          exact hdr h1 h2
        · exact fun b hq =>
            Lifecycle.endOpLocked_done_mono (Lifecycle.finishOnceLocked_done_mono false (hpd b hq))
  | d2hReady =>
    simp only [step, markD2hReady] at hs
    split at hs
    · cases hs
      exact ⟨hl, by unfold Accounted; simpa using hacc, hu,
        by unfold CountersOrdered; simp; omega, hpc, hdr, hpd, hpub⟩
    · cases hs
  | d2hEnd =>
    simp only [step, d2hEnd] at hs
    split at hs
    · cases hs
      rw [endOp_eq (by simp; omega)]
      refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, hpc, ?_, ?_, hpub⟩
      · unfold Accounted; simp; omega
      · unfold CountersOrdered; simp; omega
      · simpa using hdr
      · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
    · cases hs
  | wake ok =>
    simp only [step, wake] at hs
    split at hs
    · split at hs
      · -- the copy failed: Finish(error), then the cleanup ends the op
        cases hs
        dsimp only [finish]
        rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishOnceLocked_consistent false hl),
          ?_, hu, ?_, hpc, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · intro hok _
          obtain ⟨h1, h2⟩ := hl.finishOnceLocked_false_statusOk (by simpa using hok)
          exact hdr h1 h2
        · exact fun b hq =>
            Lifecycle.endOpLocked_done_mono (Lifecycle.finishOnceLocked_done_mono false (hpd b hq))
      · split at hs
        · -- draining: the layer is dropped, the op ends
          cases hs
          rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, hpc, ?_, ?_, hpub⟩
          · unfold Accounted; simp; omega
          · unfold CountersOrdered; simp; omega
          · simpa using hdr
          · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
        · -- scheduled on the push pool; the op is carried over
          cases hs
          refine ⟨hl, ?_, hu, ?_, hpc, hdr, hpd, hpub⟩
          · unfold Accounted; simp; omega
          · unfold CountersOrdered; simp; omega
    · cases hs
  | h2hIssue =>
    simp only [step, h2hIssue] at hs
    split at hs
    · cases hs
    · split at hs
      · rename_i l hb
        cases hs
        have := Lifecycle.beginOp_inFlight hb
        have hact := Lifecycle.beginOp_active hb
        have hdr' := Lifecycle.beginOp_draining hb
        refine ⟨Lifecycle.beginOp_consistent hl hb, ?_, hu, ?_, hpc, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · simp [hdr']
        · intro b hq
          have := hpd b hq
          simp [hact.1] at this
      · cases hs
        rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, hpc, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · simpa using hdr
        · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
  | sendNext =>
    simp only [step, sendNext] at hs
    split at hs
    · cases hs
    · cases hs
      rcases trySendNext_cases { s with chaining := s.chaining - 1 }
        with heq | ⟨hlt, hdr', hd', heq⟩ <;> rw [heq]
      · rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, hpc, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · simpa using hdr
        · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
      · simp at hlt hdr' hd'
        rw [endOp_eq (by simp)]
        refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.consistent_incr hl hdr'), ?_, hu, ?_,
          hpc, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · simp [hdr']
        · intro b hq
          have := hpd b hq
          simp [hd'] at this
  | h2hDone ok =>
    simp only [step, h2hDone] at hs
    split at hs
    · -- a push is outstanding, so the session is not settled, so not published
      have hnp : s.published = none := by
        cases hq : s.published with
        | none => rfl
        | some b =>
          have := hl.done_idle (hpd b hq)
          omega
      split at hs
      · cases hs
        split
        · -- the last push: Finish() then the cleanup ends the op
          dsimp only [finish]
          rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishOnceLocked_consistent true hl),
            ?_, hu, ?_, hpc, ?_, ?_, ?_⟩
          · unfold Accounted; simp; omega
          · unfold CountersOrdered; simp; omega
          · intro _ _; simp; omega
          · simp [hnp]
          · simp [hnp]
        · rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, hpc, ?_, ?_, ?_⟩
          · unfold Accounted; simp; omega
          · unfold CountersOrdered; simp; omega
          · intro h1 h2
            simp at h1 h2
            have := hdr h1 h2
            simp; omega
          · simp [hnp]
          · simp [hnp]
      · cases hs
        dsimp only [finish]
        rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishOnceLocked_consistent false hl),
          ?_, hu, ?_, hpc, ?_, ?_, ?_⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · intro hok _
          obtain ⟨h1, h2⟩ := hl.finishOnceLocked_false_statusOk (by simpa using hok)
          exact hdr h1 h2
        · simp [hnp]
        · simp [hnp]
    · cases hs
  | cancel =>
    simp only [step, cancel] at hs
    cases hs
    dsimp only [finish]
    refine ⟨Lifecycle.finishOnceLocked_consistent false hl,
      by unfold Accounted; simpa using hacc, hu,
      by unfold CountersOrdered; simpa using hcnt, hpc, ?_,
      fun b hq => Lifecycle.finishOnceLocked_done_mono false (hpd b hq), hpub⟩
    intro hok _
    obtain ⟨h1, h2⟩ := hl.finishOnceLocked_false_statusOk (by simpa using hok)
    exact hdr h1 h2
  | publish =>
    simp only [step, publish] at hs
    split at hs
    · rename_i hd
      obtain ⟨hdone, _⟩ := hd
      cases hs
      refine ⟨hl, by unfold Accounted; simpa using hacc, hu,
        by unfold CountersOrdered; simpa using hcnt, hpc, hdr, fun _ _ => hdone, ?_⟩
      simp
      intro hst
      exact hdr hst (hl.done_draining hdone)
    · cases hs

theorem reachable_inv {n : Nat} {s : Send} (h : (sys n).Reachable s) : Inv s :=
  (sys n).reachable_induction (inv_init n) (fun _ _ _ hi hs => step_inv hi hs) h

/-- Main result: every reachable send session satisfies all the properties. -/
theorem reachable_safe {n : Nat} {s : Send} (h : (sys n).Reachable s) : Safe s :=
  inv_safe (reachable_inv h)

/-! ### Progress and eventual settlement -/

/-- Remaining steps needed to drain all in-flight operations once draining. -/
def drainRank (s : Send) : Nat :=
  3 * (if s.d2hPending then 1 else 0) + (s.d2hIssued - s.d2hReady) +
    (s.d2hIssued - s.d2hRetired) + (s.queued - s.woken) +
    s.pooled + s.chaining + (s.h2hIssued - s.h2hRetired)

theorem trySendNext_of_draining {s : Send} (hdr : s.life.draining = true) :
    s.trySendNext = s := by
  unfold trySendNext; split <;> simp [Lifecycle.beginOp_of_draining hdr]

@[simp] theorem endOp_draining (s : Send) :
    s.endOp.life.draining = s.life.draining := by
  unfold endOp; split <;> simp

theorem finish_of_draining (ok : Bool) {s : Send} (hdr : s.life.draining = true) :
    s.finish ok = s := by
  simp [finish, Lifecycle.finishOnceLocked_decided ok (Or.inl hdr)]

theorem drainRank_endOp (s : Send) : drainRank s.endOp = drainRank s := by
  unfold endOp; split <;> rfl

/-- While draining and not yet settled, some event in `drainEvents` is enabled,
preserves `draining`, and strictly decreases `drainRank`. -/
theorem drain_step {s : Send} (h : Inv s) (hdr : s.life.draining = true)
    (hnd : s.life.done = false) :
    ∃ e s', step s e = some s' ∧ s'.life.draining = true ∧ drainRank s' < drainRank s := by
  have hif : 0 < s.life.inFlight := by
    cases h0 : s.life.inFlight
    · have := h.life.prompt hdr h0; simp [hnd] at this
    · omega
  have hacc := h.accounted
  have hcnt := h.counters
  unfold Accounted at hacc
  unfold CountersOrdered at hcnt
  by_cases hp : s.d2hPending = true
  · have hs₁ : step s (.d2hIssue true) = some { s with d2hPending := false, d2hIssued := s.d2hIssued + 1 } := by
      simp [step, d2hIssue, hp, trySendNext_of_draining (s := { s with d2hPending := false, d2hIssued := s.d2hIssued + 1 }) hdr]
    exact ⟨.d2hIssue true, _, hs₁, by simp [hdr], by simp [drainRank, hp]; omega⟩
  · by_cases hrd : s.d2hReady < s.d2hIssued
    · have hs₁ : step s .d2hReady = some { s with d2hReady := s.d2hReady + 1 } := by
        simp [step, markD2hReady, hrd]
      exact ⟨.d2hReady, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩
    · by_cases hret : s.d2hRetired < s.d2hReady
      · have hs₁ : step s .d2hEnd = some { s with d2hRetired := s.d2hRetired + 1 }.endOp := by
          simp [step, d2hEnd, hret]
        exact ⟨.d2hEnd, _, hs₁, by simp [hdr], by rw [drainRank_endOp]; simp [drainRank]; omega⟩
      · by_cases hwk : s.woken < s.queued
        · have hwr : s.woken < s.d2hReady := by omega
          have hs₁ : step s (.wake true) = some { s with woken := s.woken + 1 }.endOp := by
            simp [step, wake, hwk, hwr, hdr]
          exact ⟨.wake true, _, hs₁, by simp [hdr], by rw [drainRank_endOp]; simp [drainRank]; omega⟩
        · by_cases hpool : 0 < s.pooled
          · have hs₁ : step s .h2hIssue = some { s with pooled := s.pooled - 1 }.endOp := by
              simp [step, h2hIssue, Lifecycle.beginOp_of_draining hdr]; omega
            exact ⟨.h2hIssue, _, hs₁, by simp [hdr], by rw [drainRank_endOp]; simp [drainRank]; omega⟩
          · by_cases hch : 0 < s.chaining
            · have hs₁ : step s .sendNext = some { s with chaining := s.chaining - 1 }.endOp := by
                simp [step, sendNext, trySendNext_of_draining (s := { s with chaining := s.chaining - 1 }) hdr]
                omega
              exact ⟨.sendNext, _, hs₁, by simp [hdr], by rw [drainRank_endOp]; simp [drainRank]; omega⟩
            · have hh2h : s.h2hRetired < s.h2hIssued := by
                cases hdp : s.d2hPending <;> simp_all <;> omega
              have hs₁ : step s (.h2hDone true) =
                  some { s with h2hRetired := s.h2hRetired + 1, h2hOk := s.h2hOk + 1 }.endOp := by
                simp [step, h2hDone, hh2h,
                  finish_of_draining true (s := { s with h2hRetired := s.h2hRetired + 1, h2hOk := s.h2hOk + 1 }) hdr]
              exact ⟨.h2hDone true, _, hs₁, by simp [hdr], by rw [drainRank_endOp]; simp [drainRank]; omega⟩

theorem draining_can_settle_aux (n : Nat) :
    ∀ (k : Nat) {s : Send}, drainRank s ≤ k → Inv s → s.life.draining = true →
      ∃ evs s', (sys n).runFrom s evs = some s' ∧
        s'.life.done = true ∧ s'.life.hasStaging = false
  | 0, s, hk, h, hdr => by
    have hacc := h.accounted
    unfold Accounted at hacc
    unfold drainRank at hk
    have hd : s.life.done = true := h.life.prompt hdr (by omega)
    have hst : s.life.hasStaging = false := by rw [h.life.staging, hd]; rfl
    exact ⟨[], s, rfl, hd, hst⟩
  | k + 1, s, hk, h, hdr => by
    cases hnd : s.life.done
    · obtain ⟨e, s₁, hs₁, hdr₁, hlt⟩ := drain_step h hdr hnd
      obtain ⟨evs, s', hrun, hd', hst'⟩ :=
        draining_can_settle_aux n k (by omega) (step_inv h hs₁) hdr₁
      refine ⟨e :: evs, s', ?_, hd', hst'⟩
      simp only [System.runFrom, sys, List.foldlM_cons, hs₁]
      exact hrun
    · have hst : s.life.hasStaging = false := by rw [h.life.staging, hnd]; rfl
      exact ⟨[], s, rfl, hnd, hst⟩

/-- Every reachable send session can settle and release its staging buffer in a
finite number of steps. -/
theorem reachable_can_settle {n : Nat} {s : Send} (h : (sys n).Reachable s) :
    ∃ evs s', (sys n).runFrom s evs = some s' ∧
      s'.life.done = true ∧ s'.life.hasStaging = false := by
  have hinv := reachable_inv h
  have hcancel : step s .cancel = some (s.finish false) := rfl
  have hinv₁ := step_inv hinv hcancel
  have hdr₁ : (s.finish false).life.draining = true :=
    hinv.life.finishOnceLocked_draining false
  obtain ⟨evs, s', hrun, hd', hst'⟩ :=
    draining_can_settle_aux n (drainRank (s.finish false)) (Nat.le_refl _) hinv₁ hdr₁
  refine ⟨.cancel :: evs, s', ?_, hd', hst'⟩
  simp only [System.runFrom, sys, List.foldlM_cons, hcancel]
  exact hrun

/-! ## Frame lemmas

What each event leaves alone, and specs for the events the composed transfer
model (`Pipeline.lean`) attaches memory effects or layer guards to. -/

/-- Unfold `step` for a known event and split every branch. -/
macro "send_cases" hs:ident : tactic =>
  `(tactic| (simp only [step, beginPull, start, d2hBegin, d2hIssue, markD2hReady, d2hEnd, wake, h2hIssue,
      sendNext, h2hDone, cancel, publish] at $hs:ident <;> (repeat' split at $hs:ident)))

theorem step_numLayers {s s' : Send} {e : Ev} (hs : step s e = some s') :
    s'.numLayers = s.numLayers := by
  cases e <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> rfl)

theorem step_pullStarted_mono {s s' : Send} {e : Ev} (hs : step s e = some s')
    (hp : s.pullStarted = true) : s'.pullStarted = true := by
  cases e <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; simpa using hp)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> simp_all)

theorem step_pullStarted_of_ne_beginPull {s s' : Send} {e : Ev} (hs : step s e = some s')
    (he : e ≠ .beginPull) : s'.pullStarted = s.pullStarted := by
  cases e <;> (try exact absurd rfl he) <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> rfl)

theorem step_done_mono {s s' : Send} {e : Ev} (hs : step s e = some s') (hd : s.life.done = true) :
    s'.life.done = true := by
  cases e <;> simp only [step, beginPull, start, d2hBegin, d2hIssue, markD2hReady, d2hEnd, wake, h2hIssue,
      sendNext, h2hDone, cancel, publish, endOp, finish, trySendNext,
      Lifecycle.finishOnceLocked_inFlight, Lifecycle.beginOp_of_done hd, Option.map_none] at hs <;>
    (repeat' split at hs) <;> cases hs <;>
    simp [hd, Lifecycle.endOpLocked_done_mono, Lifecycle.finishOnceLocked_done_mono]

theorem step_published_mono {s s' : Send} {e : Ev} {b : Bool} (hs : step s e = some s')
    (hp : s.published = some b) : s'.published = some b := by
  cases e <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; simpa using hp)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> simp_all)

/-- Only `d2hReady` increments `d2hReady`. -/
theorem step_d2hReady {s s' : Send} {e : Ev} (hs : step s e = some s') (he : e ≠ .d2hReady) :
    s'.d2hReady = s.d2hReady := by
  cases e <;> (try exact absurd rfl he) <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> rfl)

theorem d2hReady_spec {s s' : Send} (hs : step s .d2hReady = some s') :
    s.d2hReady < s.d2hIssued ∧ s' = { s with d2hReady := s.d2hReady + 1 } := by
  simp only [step, markD2hReady] at hs
  split at hs
  · cases hs; exact ⟨‹_›, rfl⟩
  · cases hs

/-- Only `wake` consumes a layer's future. -/
theorem step_woken {s s' : Send} {e : Ev} (hs : step s e = some s') (he : ∀ ok, e ≠ .wake ok) :
    s'.woken = s.woken := by
  cases e <;> (try exact absurd rfl (he _)) <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> rfl)

/-- `wake` consumes exactly the next one. -/
theorem wake_woken {s s' : Send} {ok : Bool} (hs : step s (.wake ok) = some s') :
    s'.woken = s.woken + 1 := by
  simp only [step, wake] at hs
  split at hs
  · (repeat' split at hs) <;> cases hs <;>
       simp only [endOp, finish, Lifecycle.finishOnceLocked_inFlight] <;> (repeat' split) <;> rfl
  · cases hs

theorem h2hDone_guard {s s' : Send} {ok : Bool} (hs : step s (.h2hDone ok) = some s') :
    s.h2hRetired < s.h2hIssued := by
  simp only [step, h2hDone] at hs
  split at hs
  · assumption
  · cases hs

theorem step_d2hIssued_le {s s' : Send} {e : Ev} (hs : step s e = some s') :
    s.d2hIssued ≤ s'.d2hIssued := by
  cases e <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; exact Nat.le_refl _)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> simp)

theorem step_h2hRetired {s s' : Send} {e : Ev} (hs : step s e = some s')
    (he : ∀ ok, e ≠ .h2hDone ok) : s'.h2hRetired = s.h2hRetired := by
  cases e <;> (try exact absurd rfl (he _)) <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> rfl)

theorem h2hDone_h2hRetired {s s' : Send} {ok : Bool} (hs : step s (.h2hDone ok) = some s') :
    s'.h2hRetired = s.h2hRetired + 1 := by
  simp only [step, h2hDone] at hs
  split at hs
  · (repeat' split at hs) <;> cases hs <;>
      simp only [endOp, finish, Lifecycle.finishOnceLocked_inFlight] <;> (repeat' split) <;> rfl
  · cases hs

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

/-- Executable negation of `Safe`. -/
def violates (s : Send) : Bool :=
  (s.life.done && s.life.inFlight != 0) ||
  (s.life.done && (s.d2hPending || s.d2hRetired != s.d2hIssued || s.woken != s.queued ||
    s.pooled != 0 || s.chaining != 0 || s.h2hRetired != s.h2hIssued)) ||
  (s.life.hasStaging != !s.life.done) ||
  (s.life.draining && s.life.inFlight == 0 && !s.life.done) ||
  s.underflow ||
  (s.published == some true && s.h2hOk != s.numLayers) ||
  !(s.d2hRetired ≤ s.d2hReady && s.d2hReady ≤ s.d2hIssued &&
    s.d2hIssued + (if s.d2hPending then 1 else 0) ≤ s.numLayers &&
    s.woken ≤ s.queued && s.queued ≤ s.d2hIssued && s.woken ≤ s.d2hReady &&
    s.pooled + s.h2hIssued ≤ s.woken && s.h2hRetired ≤ s.h2hIssued && s.h2hOk ≤ s.h2hRetired) ||
  (0 < s.life.inFlight && !(drainEvents.any fun e => (step s e).isSome)) ||
  (s.started && !s.pullStarted) ||
  ((s.d2hPending || 0 < s.d2hIssued) && !s.started)

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
