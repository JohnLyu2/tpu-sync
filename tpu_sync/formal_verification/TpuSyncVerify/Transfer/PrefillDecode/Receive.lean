import TpuSyncVerify.Transfer.PrefillDecode.Receive.Model
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Invariant
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Progress
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Frame
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Traces
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Coverage

/-!
# Receive session

Consumer side of the prefill-to-decode model: one `TransferReceiveSession` on
the decode (consumer) side and the slice of `KVCacheManagerWithTransfer` that
drives it. Models the session lifecycle — how in-flight work is counted,
how the session drains and settles, when its host staging is released — along
with the transport's block accounting, the readiness predicate
`IsReadyToComplete`, and the manager's poll that publishes `done_recving` /
`failed_recving`. Layer data, memory contents and the producer are modelled in
`Send.lean` and `Pipeline.lean`.

`recv.h`/`recv.cc` are `tpu_sync/kv_cache/transfer_receive_session.{h,cc}`;
`mgr.cc` is `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`; `bt.cc` is
`tpu_sync/transport/block_transport.cc`. Exact line ranges for every symbol,
sub-block, and test are in the generated `## Source map` table below.

## State

The settle protocol itself is `Transfer.Lifecycle`. On top of it:

| Field             | C++                                        | Role |
|-------------------|--------------------------------------------|------|
| `numLayers`       | `base_->num_layers()`                      | fixed |
| `issued`          | `h2d_futures_.size()`                      | H2D copies handed to the device |
| `ready`           | futures in `h2d_futures_` with `IsReady()` | copies finished on the device |
| `completed`       | `num_completed_layers_`                    | callbacks that ran with an OK status |
| `layersAccounted` | layers' worth of the per-shard threshold `total_blocks_ * num_layers` absorbed by the counters `blocks_received_per_shard_` (`RecordBlockShardsReceivedLocked`) | layers whose blocks the transport has reported |
| `published`       | membership in `done_recving_` / `failed_recving_` (`CompleteReadWithDetails`; a settled incumbent is also reported when displaced in `EmplaceRecvSessionLocked` and `StartRead`) | what `poll_stats()` shows the engine |
| `pushes`          | ghost                                      | incoming pushes between `TryBeginRecvOp` and `EndRecvOp` |
| `pullPending`     | `handshake_pending_` (set in `InitFromLoadPlan`, cleared in `ExecutePullRequest`'s `on_response`) | the StartRead pull handshake still holds its op |
| `pending`         | ghost                                      | `ExecuteLayerH2d` calls between their first and second lock |
| `retired`         | ghost                                      | H2D callbacks that have run, OK or not |

Ghost fields have no single C++ variable. They record where each unit of
`in_flight_` came from, which is what `Accounted` is about.

`network_completed_` is not stored: it is exactly
`layersAccounted = numLayers` (`networkCompleted`), see
`RecordBlockShardsReceivedLocked`. The C++ counts per shard
(`blocks_received_per_shard_[s]`, one `int64_t` per shard): each incoming push
stream adds its block count to every shard it carries
(`received += static_cast<int64_t>(block_ids.size())`), a shard completes at
`total_blocks_ * total_layers`, and `network_completed_` is set when every
shard has (`num_completed_shards_ == static_cast<int32_t>(blocks_received_per_shard_.size())`).
The model keeps the per-layer view: one `netAccount` per layer, which is the
coarsening A4 justifies. (`TransferReceiveSession::OnRecvNetworkComplete` is a
second setter of `network_completed_`, reached only through the Peregrine
receive path of `BlockTransport::CompleteIncomingPush`, which is out of scope;
see `Transport.lean`.)

## Events

| Event          | C++ |
|----------------|-----|
| `pushBegin`    | `TryBeginRecvOp` from `hooks.begin_incoming_push`, called in `BlockTransport::HandleIncomingPush` (`BeginIncomingPush`) |
| `pushEnd`      | `EndRecvOp` from `hooks.end_incoming_push`, called in `BlockTransport::HandleIncomingPush` (`EndIncomingPush`). The hook takes the push's status and, when it is not OK, runs `DeferUnregisterOnSettle(); recv_session->Finish(status)` before `EndRecvOp()` (the transport's `absl::Cleanup end_incoming_push` passes `InternalError("Incoming push failed")` on any early return) — in the model, `cancel` followed by `pushEnd`, see `trace_push_lease_pins_staging_on_cancel` |
| `pullReply ok` | `on_response` of `ExecutePullRequest`: a transport failure keeps its status code, a producer rejection (`response->status != 0`) becomes `FailedPrecondition`; under `mu_` the error runs `FinishLocked(pull_status)` and clears `handshake_pending_ = false`, then the `absl::Cleanup end_op` ends the op. Also the fault-injected `Finish(status); EndRecvOp()` in `StartRead` (`kKvCacheManagerApiStartReadSubmitPull`) |
| `h2dBegin`     | `ExecuteLayerH2d`, first critical section (`++in_flight_`), from `hooks.on_layer_received` (`BlockTransport::CompleteIncomingPush` → `OnLayerReceived`) |
| `h2dIssue ok`  | `ExecuteLayerH2d` from the `done_ || draining_` re-check through `H2dSyncDispatch` and `h2d_futures_.push_back(future)` |
| `h2dReady`     | the device finishes a copy: its future becomes `IsReady()` |
| `h2dDone ok`   | `ExecuteLayerH2d`'s `future.OnReady` H2D completion callback |
| `netAccount`   | `OnBlockShardsReceived` via `BlockTransport::HandleIncomingPush` / `KVCacheManagerWithTransfer::OnBlockShardsReceived`: accounts a stream's blocks per shard (`RecordBlockShardsReceivedLocked`), may set `network_completed_`, and finishes the session if every layer is also complete (`RecordNetworkCompleteLocked`) |
| `pollReady`    | `CompleteReadWithDetails` / `CompleteReadRaw` sees `IsReadyToComplete()` and calls `Finish()` |
| `cancel`       | any `Finish(error)` from outside the session: deadline (`CompleteReadWithDetails`), shutdown (`~KVCacheManagerWithTransfer`), plan unregister (`UnregisterActivePlan`) |
| `publish`      | `CompleteReadWithDetails` / `CompleteReadRaw` moves a settled session (`session->Done()`) into `done_recving_` or `failed_recving_` by its status and erases it from `active_recv_sessions_` |

## Lock scopes

`step` applies each event atomically. The C++ has no events, only critical
sections of the session's `mu_`, so the model is faithful only if every
interleaving the C++ allows between the scopes of one event reaches a state
some sequence of model steps also reaches. Every mutable field of
`TransferReceiveSession` is `ABSL_GUARDED_BY(mu_)`; `base_`, `uuid_` and
`staging_allocator_` are set in the constructor and never written again, and
they, with `base_->num_layers()`, are the only session state an event reads
outside `mu_`. Scopes per event:

| Event          | `mu_` scopes | Between them |
|----------------|--------------|--------------|
| `pushBegin`    | one, `TryBeginRecvOp` | the hook's lookup of the session in `active_recv_sessions_` under the manager's `mu_` precedes it; a session published in between is `done_` and refuses the op, the `none` case |
| `pushEnd`      | one, `EndRecvOp` | on a failed push the hook's `DeferUnregisterOnSettle()` and `Finish(status)` are their own scopes, the model's `cancel` before `pushEnd`; `unregister_on_settle_` is not modelled |
| `pullReply`    | two: `on_response`'s `absl::MutexLock lock(self->mu_)` (`FinishLocked(pull_status)` on failure, `handshake_pending_ = false`), then `EndRecvOp()` from the `absl::Cleanup end_op`, which was declared before the lock and so runs after it is released; the fault-injected `Finish(status); EndRecvOp()` in `StartRead` is the same two scopes | an `EndRecvOp` tail, below |
| `h2dBegin`     | one, the first scope of `ExecuteLayerH2d` | — |
| `h2dIssue`     | two: the `done_ || draining_` re-check, then `h2d_futures_.push_back(future)` after the unlocked `H2dSyncDispatch` (or, when the dispatch fails, `FinishLocked(future_or.status(), kH2dPhase); EndRecvOpLocked()`) | the copy is dispatched but not yet in `h2d_futures_`, so `AllH2dDoneLocked` does not see it. Harmless by A4: the stream that completed this layer is on this thread and calls `OnBlockShardsReceived` only after `ExecuteLayerH2d` returns, so `network_completed_` cannot be set in the gap, and `num_completed_layers_ == total_layers` is impossible while a layer is unissued, so `IsReadyToComplete` is false throughout. A `Finish(error)` before the re-check is `cancel` then `h2dIssue` (`trace_finish_between_locks`); one during the dispatch finds the op `h2dBegin` took, cannot settle, and commutes with `push_back` (which does not check `draining_`, while `FinishLocked` does not read `h2d_futures_`), i.e. `h2dIssue true` then `cancel` (`trace_deadline_during_copy`, `RecvDrainTest.TimeoutDuringH2dDispatchKeepsStaging`) |
| `h2dReady`     | none (device) | — |
| `h2dDone`      | two: the callback's `absl::MutexLock lock(self->mu_)` (the `done_` check, `num_completed_layers_++`, `FinishLocked`), then `EndRecvOp()` from its `absl::Cleanup end_op` | an `EndRecvOp` tail, below. The unmodelled `UnregisterSettledPlan` also runs in this gap when the callback is the last op of a draining session (`self->in_flight_ == 1 && self->unregister_on_settle_`): the plan is dropped one scope before `done_` is set, with no op left that could use it |
| `netAccount`   | one, `OnBlockShardsReceived` (`RecordBlockShardsReceivedLocked`, `RecordNetworkCompleteLocked`, `FinishLocked`) | — |
| `pollReady`    | on the poll thread under the manager's `mu_`: `IsDraining()`, `IsReadyToComplete()`, `Finish()` (`req_id()` for the log is read-only) | the poll, below |
| `cancel`       | one, `Finish(error)`; its condition was decided in an earlier scope (`!IsDraining()` and `deadline() <= now` for the sweep, `!Done()` under the manager's `mu_` for `UnregisterActivePlan`) | the model's `cancel` has no guard, so it admits every such interleaving; late errors, below |
| `publish`      | `Done()`, then `GetStatus()` for the set, `Details()`, `TakePendingUnregister()` | on a settled session only `status_` can still change; late errors, below |

**`EndRecvOp` tails.** `pullReply` and `h2dDone` are a scope that decides,
then `EndRecvOp` in a scope of its own. Between the two the C++ state differs
from the model's post-state in one way: `in_flight_` still counts the op. The
only decisions that read `in_flight_` are the settle checks in `FinishLocked`
and `EndRecvOpLocked` (and the callback's own unregister pre-claim, outside the
model), so any step taken in the gap — a `Finish`, a `TryBeginRecvOp`,
the poll, an accounting — decides as it would after the whole event, except
that a `Finish` in the gap leaves the settle to the tail instead of performing
it, with the same `draining_`, `done_` and `status_` at the end (`FinishLocked`
records an error before it tests `draining_`). Every such interleaving
therefore ends in the state the model reaches by taking the event and then the
other step; this is what makes the ghost `pending` and `retired` counters
sound.

**The poll.** `pollReady` reads `IsDraining()`, `IsReadyToComplete()` and
calls `Finish()` in three scopes. Readiness is stable once true: when
`network_completed_ || num_completed_layers_ == total_layers` holds,
`issued = numLayers` (`CountersOrdered` with A1), so no future can join
`h2d_futures_`, and each ingredient of `IsReadyToComplete` only grows. A
`Finish(error)` between the scopes makes the session draining, and the poll's
`Finish()` with an OK status then changes nothing (`FinishLocked` returns at
`if (draining_) return;` with `status_` untouched) — the model's `pollReady`
refused after `cancel`.

**Late errors.** `FinishLocked` records a non-OK status before it tests
`draining_`, so a `Finish(error)` that lands after the session settled with an
OK status flips `status_`; `Lifecycle.finishLocked` does the same, which is
why `cancel` is enabled in every state and `publish` then reports `some false`.
Two in-tree sources: the deadline sweep's `Finish(DeadlineExceeded)` after its
own `IsReadyToComplete()` returned false, which reports a receive whose last
H2D callback settled it in that gap in `failed_recving_`; and
`UnregisterActivePlan`, whose `!Done()` test is under the manager's `mu_` but
whose `Finish(CancelledError)` is not, so it can run while
`CompleteReadWithDetails` publishes — between the `GetStatus()` that picks the
set and the `Details()` stored in `transfer_details_`. That is the only gap
found here where the C++ can produce an outcome (a `done_recving_`
entry whose details carry an error) that no interleaving of `cancel` and
`publish` produces; `transfer_details_` is outside the model's state, and
within it every such interleaving is a `cancel` before or after `publish`.

## Assumptions

* **A1 (one dispatch per layer).** `BlockTransport::CompleteIncomingPush` fires
  `OnLayerReceived` once per layer (`if (array_complete && !progress.on_layer_received_called)`),
  so `ExecuteLayerH2d` is entered at most `numLayers` times. Encoded as the
  `h2dBegin` guard `issued + pending < numLayers`. The once-latch lives in the
  `{uuid, layer}` entry of `layer_progress_`, which `CompleteIncomingPush` erases
  once every layer has been called (`if (all_layers_called)`); A1 therefore also
  assumes no sender re-pushes a uuid after its entries were retired while the
  receive is still live. `Transport.lean` models the table and proves A1
  (`Transport.OnceDispatched`) from exactly that assumption (its A4, honest
  senders); `Transport.trace_dup_after_retirement` is the re-push.
* **A2 (registration).** The session has blocks to receive and is registered.
  `ReleaseStaging()` is only called from outside on registration failure:
  in `RegisterActivePlan` and `StartRead` when `EmplaceRecvSessionLocked` fails
  before the session is seated, and in `RegisterActivePlan` if
  `base_->RegisterActivePlan` (called under `plan_lifecycle_mu_` after the
  session was seated in `active_recv_sessions_` under an earlier `mu_` lock in
  `if (hbm_receiver)`) fails, where the cleanup `mu_` critical section
  (`if (!registered.ok())`) calls `ReleaseStaging()` and
  `active_recv_sessions_.erase(recv)` together before the plan is published, so
  it is not an event here.
* **A3 (no double end).** Every op ends at most once, so `in_flight_` never
  underflows: `h2dDone` is only enabled while a callback is outstanding,
  `pushEnd` only while a push is open.
* **A4 (transport ordering).** For the request that completes a layer,
  `HandleIncomingPush` (dispatched from `HandleCustomRequest`) calls
  `CompleteIncomingPush` → `OnLayerReceived` before `OnBlockShardsReceived`, on
  the same thread, and `ExecuteLayerH2d` pushes the future into `h2d_futures_`
  (`h2d_futures_.push_back(future)`) before returning. A layer's blocks are
  accounted as one event once its copy is issued: guard
  `layersAccounted < issued`. With several streams per layer (several senders,
  or one sender's push split by source NUMA node into shard groups, each stream
  reporting only the shards it carried) the per-shard counters grow before
  `OnLayerReceived`, but every shard can only *reach* `total_blocks_ * num_layers`
  in `RecordBlockShardsReceivedLocked` once every stream has reported, so the
  call that sets `network_completed_` runs after every layer's completing stream
  has reported, and each such report follows that stream's own `OnLayerReceived`
  on the same thread; lumping each layer's accounting into that event is sound
  for everything proved here. This relies on streams reporting exactly their
  planned block count once (the counters in `RecordBlockShardsReceivedLocked`
  are plain sums compared with `received >= per_shard_target`): over-reporting
  would complete a shard early, which is precisely the `netAccountUnordered`
  mutant. `Transport.lean` proves the coarsening (`Transport.NetworkSound`)
  from honest senders and shows the over-report
  (`Transport.trace_dup_chunk_publishes_missing_layer`).

## Properties

All proved on every reachable state (`reachable_safe`):

* **Settle safety.** `done → inFlight = 0`: a settled session owns no work, so
  its blocks and staging can be reused. This is what the comment in
  `ExecuteLayerH2d` relies on ("A copy already handed to the device cannot be
  revoked; its in-flight count keeps the receive -- and its blocks -- owned
  until the copy ends").
* **No retired callback.** `done → retired = issued`: the
  `LOG(DFATAL) << "H2D callback for retired receive"` in `ExecuteLayerH2d`'s
  `future.OnReady` callback is unreachable.
* **Staging integrity.** `hasStaging = !done`.
* **Prompt settle.** `draining → inFlight = 0 → done`.
* **Readiness is sound.** `IsReadyToComplete → ready = numLayers`: when the
  poll decides the receive is complete, every layer's copy has been issued
  *and* has finished on the device. The `network_completed_` disjunct is
  sound only because of A4 (the mutant `netAccountUnordered` below shows what
  breaks without it).
* **Publication.** `published = some true → completed = numLayers`: when the
  engine is told `done_recving`, every layer's H2D callback has run with an
  OK status. Counter-level form of *publication correctness*;
  `Pipeline.lean` adds the memory contents.
* **Counters.** `completed ≤ retired ≤ ready ≤ issued ≤ numLayers` and
  `layersAccounted ≤ issued`.
* **No op leak.** `0 < inFlight →` some event in `drainEvents` is enabled:
  every accounted unit of `in_flight_` has an owner that can advance or retire
  it (`NoOpLeak`), and every reachable state can drain to `done = true` and
  release its staging in a finite number of steps (`reachable_can_settle`).

Note on the readiness predicate. One might expect `IsReadyToComplete` to
coincide with "every layer's callback has run OK"; it does not.
`IsReadyToComplete` tests futures (`ready`), and callbacks (`retired`,
`completed`) can lag behind, so the shipping predicate can be true before
`num_completed_layers_` reaches `numLayers` (`trace_poll_before_callbacks`).
That is harmless — `done` still waits for every callback through `in_flight_`
— and the publication property above is the one that matters.

## Coverage

`Coverage.lean` measures how much of `step` the replayed upstream tests
exercise. A branch is a leaf of an event's decision tree together with its
effect on the lifecycle (drains / settles / records the first error); the
reachable set is computed by exhausting the one- and two-layer state spaces
(37 branches; two further leaves are unreachable — the retired-callback
`LOG(DFATAL)`, an assertion the invariant discharges, and the `FinishLocked()`
arm of `RecordNetworkCompleteLocked`, dead because the last H2D callback always
finishes first). The 20 upstream tests paired with traces (13 named) reach 18
of the 37; the 19 they miss
are tabulated there with the shortest schedule reaching each and classified as
a missing upstream test (10 — 8 drivable by `RecvTestManager` today, among
them every `H2dSyncDispatch` failure, 2 needing a control-plane producer stub
that answers), a lock-window or poll-timing interleaving no harness hook
reaches (5), or a data-before-reply ordering the model leaves open (4). The
`#guard` at the end of `Coverage.lean`
fails if a branch, a trace or a classification changes.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `recv.h` | `TransferReceiveSession::TryBeginRecvOp` | `:117-122` |
| `recv.h` | `TransferReceiveSession` (`std::vector<int64_t> blocks_received_per_shard_` .. `std::vector<raiden::PjRtCopyFuture> h2d_futures_`) | `:281-304` |
| `recv.h` | `TransferReceiveSession` (`mutable absl::Mutex mu_;` .. `uint64_t plan_generation_ ABSL_GUARDED_BY(mu_) = 0;`) | `:266-313` |
| `recv.cc` | `TransferReceiveSession::InitFromActivePlan` | `:136-206` |
| `recv.cc` | `TransferReceiveSession::InitFromLoadPlan` | `:326-346` |
| `recv.cc` | `TransferReceiveSession::FinishLocked` | `:357-370` |
| `recv.cc` | `TransferReceiveSession::FinishLocked` (`if (!status.ok() && status_.ok())`) | `:359-362` |
| `recv.cc` | `TransferReceiveSession::Details` | `:383-399` |
| `recv.cc` | `TransferReceiveSession::CurrentPhaseLocked` | `:401-404` |
| `recv.cc` | `TransferReceiveSession::EndRecvOpLocked` | `:406-417` |
| `recv.cc` | `TransferReceiveSession::AllH2dDoneLocked` | `:443-448` |
| `recv.cc` | `TransferReceiveSession::IsReadyToComplete` | `:450-456` |
| `recv.cc` | `TransferReceiveSession::RecordBlockShardsReceivedLocked` | `:465-492` |
| `recv.cc` | `TransferReceiveSession::RecordNetworkCompleteLocked` | `:494-512` |
| `recv.cc` | `TransferReceiveSession::ExecutePullRequest` | `:514-590` |
| `recv.cc` | `TransferReceiveSession::ExecutePullRequest` (`auto on_response =`) | `:536-572` |
| `recv.cc` | `TransferReceiveSession::ExecutePullRequest` (`absl::Cleanup end_op`) | `:538` |
| `recv.cc` | `TransferReceiveSession::ExecutePullRequest` (`absl::MutexLock lock(self->mu_);` .. `self->handshake_pending_ = false;`) | `:567-571` |
| `recv.cc` | `TransferReceiveSession::OnRecvNetworkComplete` | `:608-620` |
| `recv.cc` | `TransferReceiveSession::OnBlockShardsReceived` | `:622-670` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` | `:672-793` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`++in_flight_;` .. `trigger_enqueue = true;`) | `:682-687` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`// The receive may have been finished` .. `h2d_futures_.push_back(future);`) | `:699-728` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`if (!future_or.ok())`) | `:718-723` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`future.OnReady`) | `:732-790` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`absl::Cleanup end_op`) | `:741` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`absl::MutexLock lock(self->mu_);` .. `should_unregister = true;`) | `:747-773` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`if (should_unregister && !manager.IsShuttingDown())`) | `:787-789` |
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` (`hooks.on_layer_received =`) | `:163-179` |
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` (`hooks.begin_incoming_push =`) | `:224-249` |
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` (`hooks.end_incoming_push =`) | `:250-296` |
| `mgr.cc` | `KVCacheManagerWithTransfer::~KVCacheManagerWithTransfer` (`for (const auto& [uuid, session] : active_recv_sessions_)`) | `:405-409` |
| `mgr.cc` | `KVCacheManagerWithTransfer::EmplaceRecvSessionLocked` | `:535-551` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RegisterActivePlan` | `:553-641` |
| `mgr.cc` | `KVCacheManagerWithTransfer::UnregisterActivePlan` | `:741-778` |
| `mgr.cc` | `KVCacheManagerWithTransfer::UnregisterActivePlan` (`if (recv != nullptr)`) | `:765-771` |
| `mgr.cc` | `KVCacheManagerWithTransfer::StartRead(remote_endpoint)` | `:874-978` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`for (auto it = active_recv_sessions_.begin();`) | `:1035-1066` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`// Reclaim recv sessions whose transfer never completed` .. `absl::DeadlineExceededError("Receive session timed out"));`) | `:1031-1050` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`absl::DeadlineExceededError("Receive session timed out"));` .. `active_recv_sessions_.erase(it++);`) | `:1050-1062` |
| `mgr.cc` | `KVCacheManagerWithTransfer::OnBlockShardsReceived` | `:1497-1521` |
| `bt.cc` | `BlockTransport::HandleCustomRequest` | `:471-494` |
| `bt.cc` | `BlockTransport::HandleIncomingPush` | `:496-639` |
| `bt.cc` | `BlockTransport::CompleteIncomingPush` | `:691-887` |
| `send_drain_test.cc` | `RecvLifecycleTest.DetailsSayAReceiveTimedOutWaitingForData` | `:636-649` |
| `send_drain_test.cc` | `RecvLifecycleTest.DetailsSayAFailedUploadFailedInH2dWhileDataArrives` | `:651-665` |
| `send_drain_test.cc` | `RecvLifecycleTest.SingleFailedH2dReportsFailureAndReturnsStaging` | `:725-736` |
| `send_drain_test.cc` | `RecvLifecycleTest.NetworkCompletionWaitsForH2d` | `:599-617` |
| `send_drain_test.cc` | `RecvLifecycleTest.LateBlockAccountingAfterRetirementIsANoOp` | `:680-702` |
| `send_drain_test.cc` | `RecvLifecycleTest.ReceiveWithoutTrafficFailsAtItsDeadline` | `:738-749` |
| `send_drain_test.cc` | `RecvDrainTest.ExpiredReceiveKeepsStagingUntilH2dEnds` | `:751-778` |
| `send_drain_test.cc` | `RecvDrainTest.FailedLayerWaitsForOtherH2dCopies` | `:831-857` |
| `send_drain_test.cc` | `RecvDrainTest.TimeoutDuringH2dDispatchKeepsStaging` | `:859-895` |
| `send_drain_test.cc` | `RecvLifecycleTest.IncomingPushLeasePinsStagingDuringWriteAndRejectsWhenDraining` | `:948-971` |
| `send_drain_test.cc` | `RecvLifecycleTest.IncomingPushLeaseSpansLayerH2dAndBlockAccountingBeforeReleasing` | `:973-1000` |
| `send_drain_test.cc` | `RecvLifecycleTest.FailedIncomingPushImmediatelyFailsSessionAndReleasesStagingBeforeDeadline` | `:1002-1030` |
| `control_test.cc` | `ControlHandshakeTest.ExpiredReceiveKeepsStagingUntilHandshakeEnds` | `:795-835` |
| `control_test.cc` | `ControlHandshakeTest.RejectedPullReportsWhyAndWhichProducerRejectedIt` | `:849-867` |
| `control_test.cc` | `ControlHandshakeTest.RefusedConnectionKeepsItsStatusCode` | `:869-894` |
| `pool_reshard_test.cc` | `DemandStagingTest.UnregisteringIdleReceiverReleasesPlanAtOnce` | `:440-465` |
| `pool_reshard_test.cc` | `DemandStagingTest.UnregisteringInFlightReceiverDefersUntilItSettles` | `:467-507` |
| `pool_reshard_test.cc` | `DemandStagingTest.DemandStagedReceiverPlanUnregistersWhenItSettles` | `:569-592` |
<!-- source-map:end -->
-/
