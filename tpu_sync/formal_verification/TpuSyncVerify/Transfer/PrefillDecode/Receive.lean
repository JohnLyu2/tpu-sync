import TpuSyncVerify.Transfer.PrefillDecode.Receive.Model
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Invariant
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Progress
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Frame
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Traces
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Coverage
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Guards

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
`mgr.cc` is `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`; `base.cc`
is `tpu_sync/kv_cache/kv_cache_manager_base.cc`; `bt.cc` is
`tpu_sync/transport/block_transport.cc`; `bts.cc` is
`tpu_sync/transport/block_transport_session.cc`;
`tpu_sync/transport/transfer_session.h` is the `TransferSession` interface
(`TryBeginOp`, `EndOp`, `Finish`, `Done`, `OnDataReceived`, `Start`, …) that
`TransferReceiveSession` implements and through which the transport and
`KVCacheManagerBase` reach it. Exact line ranges for every symbol, sub-block,
and test are in the generated `## Source map` table below.

## State

The settle protocol itself is `Transfer.Lifecycle`. On top of it:

| Field             | C++                                        | Role |
|-------------------|--------------------------------------------|------|
| `numLayers`       | `base_->num_layers()`                      | fixed |
| `issued`          | `h2d_futures_.size()`, and by A1 `dispatched_layers_.size()` | H2D copies handed to the device |
| `ready`           | futures in `h2d_futures_` with `IsReady()` | copies finished on the device |
| `completed`       | `num_completed_layers_`                    | callbacks that ran with an OK status |
| `layersAccounted` | layers' worth of the per-shard threshold `total_blocks_ * num_layers` absorbed by the counters `blocks_received_per_shard_` (`RecordBlockShardsReceivedLocked`) | layers whose blocks the transport has reported |
| `netIssued`       | `network_completed_` as set by `ExecuteLayerH2d`'s last scope (`dispatched_layers_.size() == base_->num_layers()`) | every layer's copy has been issued |
| `published`       | membership in `done_recving_` / `failed_recving_` (`RetireSettledSessionLocked`, from `CompleteReadWithDetails`; a settled incumbent is also retired when displaced in `EmplaceRecvSessionLocked`, `RegisterActivePlan` and `StartRead`) | what `poll_stats()` shows the engine |
| `pushes`          | ghost                                      | incoming pushes between `TryBeginOp` and `EndOp` |
| `pullPending`     | `handshake_pending_` (set in `InitFromLoadPlan`, cleared in `Start`'s `on_response`) | the StartRead pull handshake still holds its op |
| `pending`         | ghost                                      | `ExecuteLayerH2d` calls between their first and second lock |
| `retired`         | ghost                                      | H2D callbacks that have run, OK or not |

Ghost fields have no single C++ variable. They record where each unit of
`in_flight_` came from, which is what `Accounted` is about.

`network_completed_` has two setters and is `networkCompleted`,
`layersAccounted = numLayers ∨ netIssued`. The block-accounting setter is
`RecordBlockShardsReceivedLocked`: the C++ counts per shard
(`blocks_received_per_shard_[s]`, one `int64_t` per shard), each incoming push
stream adds its block count to every shard it carries
(`received += static_cast<int64_t>(block_ids.size())`), a shard completes at
`total_blocks_ * total_layers`, and `network_completed_` is set when every
shard has (`num_completed_shards_ == static_cast<int32_t>(blocks_received_per_shard_.size())`).
The model keeps the per-layer view: one `netAccount` per layer, which is the
coarsening A4 justifies. The dispatch setter is the last `mu_` scope of
`ExecuteLayerH2d`: after `h2d_futures_.push_back(future)` the layer joins
`dispatched_layers_`, and when that set holds every layer and the receive is
neither done nor draining, `network_completed_ = true` — the only setter a
receive fed by Peregrine posts (no block reports) ever sees. Under A1 the set's
size is `issued`, so `netIssued` is set by the `h2dIssue true` that makes
`issued = numLayers` (`Inv.netIssued_issued`).

Not state: `any_blocks_received_` (first-packet timing, set by the first
`TryBeginOp` or the first `RecordBlockShards`), `tracks_completion_` (`true`
for every receive here; `InitFromActivePlan` clears it for a receiver with no
blocks or a non-HBM destination, which `RetireSettledSessionLocked` then
erases without reporting), and `pull_manager_` / `pull_endpoint_` (set by the
pulled-receive `Create` so that `Start` knows which manager's control backend
to send the pull through).

## Events

| Event          | C++ |
|----------------|-----|
| `pushBegin`    | `TryBeginOp` from `BeginIncomingPush` in `bts.cc` (`delegate->GetSession(uuid)` then `session->TryBeginOp()`; a `false` becomes `CancelledError`), called in `BlockTransportServerPushSession::StartStream` — the stream's entry point is `BlockTransport::HandleIncomingPush`, which looks the uuid's push session up and delegates to it |
| `pushEnd`      | `EndOp` from `EndIncomingPush` in `bts.cc`, called at the end of `StartStream` and from its `absl::Cleanup end_incoming_push` on any early return. `EndIncomingPush` takes the push's status and, when it is not OK, runs `session->Finish(status)` before `session->EndOp()` (the cleanup passes `InternalError("Incoming push failed")`) — in the model, `cancel` followed by `pushEnd`, see `trace_push_lease_pins_staging_on_cancel` |
| `pullReply ok` | `on_response` of `Start`: a transport failure keeps its status code, a producer rejection (`response->status != 0`) becomes `FailedPrecondition`; under `mu_` the error runs `FinishLocked(pull_status)` and clears `handshake_pending_ = false`, then the `absl::Cleanup end_op` ends the op. Also the fault-injected `session->Finish(status); session->EndOp();` in `StartRead` (`kKvCacheManagerApiStartReadSubmitPull`) |
| `h2dBegin`     | `ExecuteLayerH2d`, first critical section (`++in_flight_`), from `OnDataReceived` with no block ids (`KVCacheManagerBase::OnLayerReceived` → `session->OnDataReceived(layer_idx, {}, {})`, called from `BlockTransportServerPushSession::CompleteIncomingPush` → `delegate_->OnLayerReceived`) |
| `h2dIssue ok`  | `ExecuteLayerH2d` from the `done_ \|\| draining_` re-check through `H2dSyncDispatch`, `h2d_futures_.push_back(future)` and the `dispatched_layers_` scope that may set `network_completed_` |
| `h2dReady`     | the device finishes a copy: its future becomes `IsReady()` |
| `h2dDone ok`   | `ExecuteLayerH2d`'s `future.OnReady` H2D completion callback |
| `netAccount`   | `RecordBlockShards` from `OnDataReceived` with block ids (`KVCacheManagerBase::OnBlockShardsReceived` → `session->OnDataReceived(0, block_ids, shard_ids)`, called from `StartStream` after `CompleteIncomingPush`): accounts a stream's blocks per shard (`RecordBlockShardsReceivedLocked`), may set `network_completed_`, and finishes the session if every layer is also complete (`RecordNetworkCompleteLocked`) |
| `pollReady`    | `CompleteReadWithDetails` / `CompleteReadRaw` sees `IsReadyToComplete()` and calls `Finish()` |
| `cancel`       | any `Finish(error)` from outside the session: deadline (`CompleteReadWithDetails`), shutdown (`~KVCacheManagerWithTransfer` finishes every session in `sessions_` with `CancelledError` and then `AwaitForDone()`s each), plan unregister (`UnregisterActivePlan`), a failed push (`EndIncomingPush`), and a ready incumbent being finished so that a new registration can retire it (`EmplaceRecvSessionLocked` / `RegisterActivePlan`: `recv->Finish()` if `!recv->IsDraining() && recv->IsReadyToComplete()` — an OK finish, which is `pollReady` from the poll window) |
| `publish`      | `RetireSettledSessionLocked` moves a settled session (`if (!recv->Done()) return false;`) into `done_recving_` or `failed_recving_` by its status, stores its `Details()` in `transfer_details_`, and erases it from `sessions_`; called for every entry by `CompleteReadWithDetails` / `CompleteReadRaw`, and for a displaced incumbent by `StartRead`, `EmplaceRecvSessionLocked` and `RegisterActivePlan` |

## Lock scopes

Every mutable field of `TransferReceiveSession` is `ABSL_GUARDED_BY(mu_)`
except two that serve the bounded-staging wait below: `staging_layer_manager_`
(a `StagingLayerManager` with its own `mu_`) and the atomic `cancelled_`, a
mirror of `draining_` written only by `FinishLocked`
(`cancelled_.store(true, std::memory_order_relaxed)`). `base_`, `uuid_`,
`staging_allocator_`, `metrics_collector_`, `transfer_plan_`, `pull_manager_`
and `pull_endpoint_` are set before the session is shared and never written
again, and they (with `base_` / manager configuration getters) are the only
other state an event reads outside `mu_`.

| Event          | `mu_` scopes | Between them |
|----------------|--------------|--------------|
| `pushBegin`    | 1: `TryBeginOp` | preceded by `BeginIncomingPush`'s `delegate->GetSession(uuid)` (`KVCacheManagerBase::GetSession` → `hooks.get_session` → `KVCacheManagerWithTransfer::GetSession`, a `sessions_` lookup under manager `mu_`); a session retired in between is `done_` and refuses the op (`none`); a send session seated under the uuid refuses it too (`TransferSendSession::TryBeginOp` returns `false`) and is not a state of this model |
| `pushEnd`      | 1: `EndOp` (`EndRecvOpLocked`), plus one read-only `GetStatus()` scope in `EndIncomingPush` for its return value | on a failed push, `EndIncomingPush`'s `session->Finish(status)` is an earlier scope (`cancel` before `pushEnd`) |
| `pullReply`    | 2: `on_response`'s `absl::MutexLock lock(self->mu_)` (`FinishLocked(pull_status)` on failure, `handshake_pending_ = false`), then `EndOp()` from `absl::Cleanup end_op` after `lock` is released (`Start` also takes an initial `mu_` scope before scheduling to read `load_plan_` and set `peer_endpoint_`; the fault-injected `session->Finish(status); session->EndOp();` in `StartRead`, and the same pair after a `Start()` that returns an error — which `Start` never does — are the same two scopes without `on_response`, leaving `handshake_pending_ = true` on a settled session) | an `EndOp` tail, below |
| `h2dBegin`     | 1: first scope of `ExecuteLayerH2d` (after the unlocked `LookupStagingSlot` under bounded staging, below) | — |
| `h2dIssue`     | 1–3 in `ExecuteLayerH2d`: the `done_ \|\| draining_` re-check (`EndRecvOpLocked()` and return in 1 scope when draining); then `h2d_futures_.push_back(future)` after the unlocked `H2dSyncDispatch` (or, on dispatch failure, `FinishLocked(future_or.status(), kH2dPhase); EndRecvOpLocked()`); then, after `future.OnReady` is registered, `dispatched_layers_.insert(layer_idx)` and `network_completed_ = true` if the set is full and `!network_completed_ && !done_ && !draining_` | during `H2dSyncDispatch` the copy is not yet in `h2d_futures_`, so `AllH2dDoneLocked` does not see it. Harmless by A4: this thread calls `RecordBlockShards` only after `ExecuteLayerH2d` returns, so `network_completed_` cannot be set in the gap, and `num_completed_layers_ == total_layers` is false while a layer is unissued, keeping `IsReadyToComplete` false. A `Finish(error)` before the re-check is `cancel` then `h2dIssue` (`trace_finish_between_locks`); one during the dispatch finds the op `h2dBegin` took, cannot settle, and commutes with `push_back`, i.e. `h2dIssue true` then `cancel` (`trace_deadline_during_copy`, `RecvDrainTest.TimeoutDuringH2dDispatchKeepsStaging`). Between `push_back` and the third scope a `cancel`, or the copy's own `h2dDone` (the future may already be ready), finds exactly the model's state after `h2dIssue true`: the copy counted in `h2d_futures_` and `in_flight_`. The one thing the third scope then does differently is to leave `network_completed_` false (`!done_ && !draining_` fails) where the model has set `netIssued`; a draining session's flag is read by nothing the model tracks — `RecordBlockShards` and `TryBeginOp` refuse, `IsReadyToComplete` is consulted only behind `!IsDraining()` (`CompleteReadWithDetails`, `EmplaceRecvSessionLocked`, `RegisterActivePlan`), and `CurrentPhaseLocked` reads it only for `Details()` — so `h2dIssue true` followed by that `cancel` / `h2dDone` reaches the same lifecycle state with the same enabled events, and folding the third scope into `h2dIssue true` is exact for everything proved (`ReadinessSound` holds from `netIssued` through `Inv.netIssued_issued`, independently of the flag's timing) |
| `h2dReady`     | 0 (device) | — |
| `h2dDone`      | 2: the callback's `absl::MutexLock lock(self->mu_)` (`done_` check, `num_completed_layers_++`, `FinishLocked`), then `EndOp()` from `absl::Cleanup end_op` | an `EndOp` tail, below (the callback also returns the layer's host buffer lease, `self->staging_layer_manager_.Release(layer_idx)`, in the gap) |
| `netAccount`   | 1: `RecordBlockShards` (`RecordBlockShardsReceivedLocked`, `RecordNetworkCompleteLocked`, `FinishLocked`), preceded by `KVCacheManagerBase::OnBlockShardsReceived`'s `GetSession` lookup under manager `mu_` (an empty block list returns before any session: `if (block_ids.empty())`) | — |
| `pollReady`    | on the poll thread under manager `mu_`: `IsDraining()`, `IsReadyToComplete()`, `req_id()` (for the log), `Finish()` | the poll, below |
| `cancel`       | 1: `Finish(error)`, after its condition was checked in earlier scopes (`!IsDraining()` and `deadline() <= now` under manager `mu_` for the sweep; `plan().has_value()` under manager `mu_` and then `!session->Done()` with no lock for `UnregisterActivePlan`; none for `~KVCacheManagerWithTransfer` and `EndIncomingPush`) | `cancel` has no guard in the model, so it admits every such interleaving; late errors, below |
| `publish`      | under manager `mu_` in `RetireSettledSessionLocked`: `Done()`, `tracks_completion()`, `GetStatus()`, `req_id()`, `Details()`, then `sessions_.erase(it)` | on a settled session only `status_` can still change; late errors, below |

**`EndOp` tails.** `pullReply` and `h2dDone` run their decision under `mu_`
and then call `EndOp` in a second scope. Between the two scopes, `in_flight_`
still counts the op. Because only the settle checks in `FinishLocked` and
`EndRecvOpLocked` inspect `in_flight_`, any interleaved step makes the same
decision as it would after `EndOp`, except that an interleaved `Finish`
leaves the final settle to `EndOp` with the same resulting `draining_`,
`done_` and `status_`. Every such interleaving therefore reaches the same state
as running the whole event first, which is why the ghost `pending` and `retired`
counters need no intermediate state for the tail.

**The poll.** `pollReady` checks `IsDraining()` and `IsReadyToComplete()`, reads
`req_id()`, and calls `Finish()`. Once `IsReadyToComplete()` is true it stays
true: when `network_completed_ || num_completed_layers_ == total_layers` holds,
`issued = numLayers` (`CountersOrdered` with A1, or `Inv.netIssued_issued`), so
no new future can join `h2d_futures_` and each ingredient of
`IsReadyToComplete` is monotone. If `Finish(error)` runs between the check and
`Finish()`, the session is already draining when the poll's OK `Finish()` runs,
so `FinishLocked` returns at `if (draining_) return;` without touching
`status_` — matching `pollReady` being disabled after `cancel`.

**Late errors.** `FinishLocked` records a non-OK status before testing
`draining_`, so a `Finish(error)` after an OK settle still flips `status_`;
`Lifecycle.finishLocked` does the same, which is why `cancel` is unguarded and
a subsequent `publish` reports `some false`. Three callers can do this: the
deadline sweep's `Finish(DeadlineExceeded)` if the last H2D callback settled the
session after `IsReadyToComplete()` returned false; `UnregisterActivePlan`,
whose `!session->Done()` check and `Finish(CancelledError)` both run after it
released manager `mu_`; and `~KVCacheManagerWithTransfer`, which finishes every
seated session unconditionally. In the second case, `Finish(CancelledError)`
can land during `RetireSettledSessionLocked` between the `GetStatus()` that
selects `done_recving_` and the `Details()` stored in `transfer_details_`,
producing a `done_recving_` entry whose details carry an error
(`transfer_details_` is outside the model's state; on the modelled fields every
interleaving is `cancel` before or after `publish`).

**Bounded host layer staging.** The model is the full host mirror, one host
layer buffer per layer (`KVCacheManagerBase::num_host_layers() == num_layers()`,
the default; the `num_staging_layers` constructor argument, checked by
`ResolveNumStagingLayers`, bounds it). When fewer buffers than layers exist, a
layer's payload is written into a buffer leased from the session's
`StagingLayerManager`: each chunk's `KVCacheManagerBase::GetBlockChunks`
(inside the push lease, from `StartStream`'s payload loop) calls
`session->ResolveStagingSlot(layer_idx)` →
`TransferReceiveSession::AcquireStagingSlot` (on a full mirror it returns
`NotFound`, "no bounded host staging", and the chunk addresses the layer's own
buffer), which takes an op (`if (done_ || draining_)` refusal, `++in_flight_`,
the pattern of `TryBeginOp`), waits in `StagingLayerManager::Acquire` until a
buffer is free, the layer already holds one, the session's `deadline_` passes
or `cancelled_` is set (`FinishLocked` also calls
`staging_layer_manager_.Shutdown()` to wake waiters), then under `mu_` fails
the receive on a timeout (`FinishLocked(slot.status(), kReceivePhase)`),
returns a lease won by a draining session, and ends the op
(`EndRecvOpLocked()`). `ExecuteLayerH2d` then reads the leased buffer
(`LookupStagingSlot`, before its first lock, failing with `FailedPrecondition`
if the lease is gone) and dispatches with it as `host_layer_idx`; the lease is
returned on each early return, by the H2D callback after its `FinishLocked`
(`self->staging_layer_manager_.Release(layer_idx)`), and wholesale at settle
(`ReleaseAll()` in `ReleaseStagingLocked`). Nothing proved here changes under
that mode: the extra op is nested inside the push lease on the push thread
(taken after `pushBegin`, ended before the stream's `CompleteIncomingPush`), so
`in_flight_` is transiently one higher while `pushes > 0` already holds and
every settle decision is the one the model makes; a timeout, a cancelled wait
or a failed `LookupStagingSlot` fails the stream, which is `cancel` before
`pushEnd` (the unguarded `cancel` admits it), and a lookup can only fail on a
draining session (its lease was released by an early return or `ReleaseAll`).
`PrefillDecode/LayerStaging.lean` (with `Transfer/LayerStaging.lean`) models
`StagingLayerManager`, `TransferReceiveSession::AcquireStagingSlot`,
`decodeSlots` reuse across layers, and the unlocked gaps around `Acquire`,
proving publication correctness, slot conservation/exclusivity,
drain-to-settle termination, and the necessary and sufficient `1`-slot bound
(`LayerStaging.reachable_safe`, `LayerStaging.reachable_can_settle`,
`LayerStaging.no_slots_cannot_publish_ok`, `LayerStaging.exists_complete_trace`).

## Assumptions

* **A1 (one dispatch per layer).** `BlockTransportServerPushSession::CompleteIncomingPush`
  fires `OnLayerReceived` once per layer
  (`if (array_complete && !progress.on_layer_received_called)`), so
  `ExecuteLayerH2d` is entered at most `numLayers` times. Encoded as the
  `h2dBegin` guard `issued + pending < numLayers`. The once-latch lives in the
  layer's entry of the uuid's push-session table `layer_progress_`, which
  `CompleteIncomingPush` clears once every layer has been called
  (`if (all_layers_called)`); A1 therefore also assumes no sender re-pushes a
  uuid after its entries were retired while the receive is still live.
  `Transport.lean` models the table and proves A1 (`Transport.OnceDispatched`)
  from exactly that assumption (its A4, honest senders);
  `Transport.trace_dup_after_retirement` is the re-push. The session itself
  keeps the network phase honest against a re-delivered layer
  (`dispatched_layers_` is a set, so a duplicate does not complete it —
  `RecvLifecycleTest.RedeliveredLayerDoesNotCompleteNetworkPhase`), but still
  issues the duplicate's copy, so A1 remains what bounds `issued`.
* **A2 (registration).** The session has blocks to receive
  (`total_blocks_ > 0`, which is also what the `total_blocks_ == 0` disjuncts
  of the first checks in `ExecuteLayerH2d` and `RecordBlockShards` test) and is
  seated in `sessions_`. `ReleaseStaging()` is called only by the destructor
  (`~TransferReceiveSession`): a candidate that `EmplaceRecvSessionLocked`
  rejects (`try_emplace` fails; from `StartRead`, `RegisterRecv` or
  `RegisterActivePlan`) is dropped by its creator before it was ever shared, so
  its release is not an event here.
* **A3 (no double end).** Every op ends at most once, so `in_flight_` never
  underflows: `h2dDone` is only enabled while a callback is outstanding,
  `pushEnd` only while a push is open.
* **A4 (transport ordering).** For the request that completes a layer,
  `BlockTransportServerPushSession::StartStream` (reached from
  `BlockTransport::HandleIncomingPush`, dispatched from `HandleCustomRequest`)
  calls `CompleteIncomingPush` → `delegate_->OnLayerReceived` →
  `KVCacheManagerBase::OnLayerReceived` → `session->OnDataReceived` →
  `ExecuteLayerH2d` before `delegate_->OnBlockShardsReceived` →
  `KVCacheManagerBase::OnBlockShardsReceived` → `session->OnDataReceived` →
  `RecordBlockShards`, on the same thread, and `ExecuteLayerH2d` pushes the
  future into `h2d_futures_` (`h2d_futures_.push_back(future)`) before
  returning. A layer's blocks are accounted as one event once its copy is
  issued: guard `layersAccounted < issued`. With several streams per layer
  (several senders, or one sender's push split by source NUMA node into shard
  groups, each stream reporting only the shards it carried) the per-shard
  counters grow before `OnLayerReceived`, but every shard can only *reach*
  `total_blocks_ * num_layers` in `RecordBlockShardsReceivedLocked` once every
  stream has reported, so the call that sets `network_completed_` runs after
  every layer's completing stream has reported, and each such report follows
  that stream's own `OnLayerReceived` on the same thread; lumping each layer's
  accounting into that event is sound for everything proved here. This relies
  on streams reporting exactly their planned block count once (the counters in
  `RecordBlockShardsReceivedLocked` are plain sums compared with
  `received >= per_shard_target`): over-reporting would complete a shard
  early, which is precisely the `netAccountUnordered` mutant. `Transport.lean`
  proves the coarsening (`Transport.NetworkSound`) from honest senders and
  shows the over-report (`Transport.trace_dup_chunk_publishes_missing_layer`).

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
  *and* has finished on the device. For the dispatch setter of
  `network_completed_` this holds directly: `netIssued` is set only by the
  issue that makes `issued = numLayers` (`Inv.netIssued_issued`), and
  `AllH2dDoneLocked` then says `ready = issued`. For the block-accounting
  setter it is sound only because of A4 (the mutant `netAccountUnordered` below
  shows what breaks without it).
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
* **Published is quiet (`PublishedQuiet`).** `published ≠ none → pending = 0 ∧ retired = issued`:
  once `poll_stats()` has reported the receive, as `done_recving` or as
  `failed_recving`, no H2D copy is dispatching or still writing decode HBM, so
  the engine may reuse it. The receiver's promise to the engine at the session
  level (the pipeline restates it as `DecodeHbmSafe`); added when the guard
  inventory (`Guards.lean`) found that dropping `Done()` before publishing a
  *failed* receive violated nothing the module stated.

Note on the readiness predicate. One might expect `IsReadyToComplete` to
coincide with "every layer's callback has run OK"; it does not.
`IsReadyToComplete` tests futures (`ready`), and callbacks (`retired`,
`completed`) can lag behind, so the shipping predicate can be true before
`num_completed_layers_` reaches `numLayers` (`trace_poll_before_callbacks`).
That is harmless — `done` still waits for every callback through `in_flight_`
— and the publication property above is the one that matters.

## Coverage and guards

`Coverage.lean` measures how much of `step` the replayed upstream tests
exercise. A branch is a leaf of an event's decision tree together with its
effect on the lifecycle (`draining`, `done`, first error); `stepT_step` proves
coverage is measured on the proved `step`. On 1–2 layers (push and `StartRead`),
`step` has 37 reachable branches (plus 2 unreachable leaves: the
retired-callback assertion and the dead `FinishLocked()` arm of
`RecordNetworkCompleteLocked`); the 32 paired upstream tests reach 24, and the
remaining 13 are classified into missing upstream tests (4, each a replayed
test plus an open push lease or a late `FailRecv`), lock-gap windows no
harness hook reaches (5), or a data-before-reply ordering the model leaves open
(4). The `#guard` at the end of `Coverage.lean` fails if a branch, a trace or a
classification changes.

`Guards.lean` asks the other question: which of the C++ checks `step`
transcribes do the properties need? Each is dropped or weakened and searched
exhaustively against `Safe` without the ghost-counter equations. Five are
load-bearing (`TryBeginOp`'s refusal, `ExecuteLayerH2d`'s first check,
`Done()` before publishing in `RetireSettledSessionLocked` — whose
failed-receive half survived the `Safe` the module had, `PublishedQuiet` being
the property that was missing — `draining_` in `EndRecvOpLocked`'s settle
condition, `in_flight_ == 0` in `FinishLocked`); five survive — the
`draining_` half of the first check and the whole re-check in
`ExecuteLayerH2d` (wasted DMA, not safety), the `!draining_` on the last
layer's finish and the `done_ || draining_` in `RecordBlockShards` (metrics and
accounting), and the poll's `!IsDraining()` (a no-op without it). The
`!network_completed_ && !done_ && !draining_` of the dispatch setter is
idempotence and the lock-scope argument above, not a mutant.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `recv.h` | `TransferReceiveSession::~TransferReceiveSession` | `:94` |
| `recv.h` | `TransferReceiveSession::Done` | `:101-104` |
| `recv.h` | `TransferReceiveSession::GetStatus` | `:108-111` |
| `recv.h` | `TransferReceiveSession::IsDraining` | `:118-121` |
| `recv.h` | `TransferReceiveSession` (`bool TryBeginOp() override;` .. `void EndOp() override;`) | `:132-133` |
| `recv.h` | `TransferReceiveSession` (`absl::Status OnDataReceived(size_t major_dimension_idx,` .. `absl::Span<const int> shard_ids) override;`) | `:145-147` |
| `recv.h` | `TransferReceiveSession::ResolveStagingSlot` | `:155-157` |
| `recv.h` | `TransferReceiveSession::req_id` | `:163-166` |
| `recv.h` | `TransferReceiveSession::tracks_completion` | `:171-174` |
| `recv.h` | `TransferReceiveSession::deadline` | `:179-182` |
| `recv.h` | `TransferReceiveSession` (`std::vector<int64_t> blocks_received_per_shard_` .. `std::vector<raiden::PjRtCopyFuture> h2d_futures_`) | `:325-353` |
| `recv.h` | `TransferReceiveSession` (`mutable absl::Mutex mu_;` .. `std::atomic<bool> cancelled_{false};`) | `:307-358` |
| `recv.h` | `TransferReceiveSession` (`absl::StatusOr<size_t> AcquireStagingSlot(size_t layer_idx);`) | `:205` |
| `recv.cc` | `TransferReceiveSession::InitFromActivePlan` | `:268-323` |
| `recv.cc` | `TransferReceiveSession::InitFromLoadPlan` | `:443-457` |
| `recv.cc` | `TransferReceiveSession::ReleaseStaging` | `:464-467` |
| `recv.cc` | `TransferReceiveSession::FinishLocked` | `:469-484` |
| `recv.cc` | `TransferReceiveSession::FinishLocked` (`if (!status.ok() && status_.ok())`) | `:471-474` |
| `recv.cc` | `TransferReceiveSession::Finish` | `:486-489` |
| `recv.cc` | `TransferReceiveSession::AwaitForDone` | `:491-495` |
| `recv.cc` | `TransferReceiveSession::Details` | `:497-513` |
| `recv.cc` | `TransferReceiveSession::CurrentPhaseLocked` | `:515-518` |
| `recv.cc` | `TransferReceiveSession::EndRecvOpLocked` | `:520-531` |
| `recv.cc` | `TransferReceiveSession::TryBeginOp` | `:533-544` |
| `recv.cc` | `TransferReceiveSession::EndOp` | `:546-549` |
| `recv.cc` | `TransferReceiveSession::AllH2dDoneLocked` | `:551-556` |
| `recv.cc` | `TransferReceiveSession::IsReadyToComplete` | `:558-564` |
| `recv.cc` | `TransferReceiveSession::RecordBlockShardsReceivedLocked` | `:573-598` |
| `recv.cc` | `TransferReceiveSession::RecordNetworkCompleteLocked` | `:600-617` |
| `recv.cc` | `TransferReceiveSession::Start` | `:619-701` |
| `recv.cc` | `TransferReceiveSession::Start` (`auto on_response =`) | `:646-682` |
| `recv.cc` | `TransferReceiveSession::Start` (`absl::Cleanup end_op`) | `:648` |
| `recv.cc` | `TransferReceiveSession::Start` (`absl::MutexLock lock(self->mu_);` .. `self->handshake_pending_ = false;`) | `:677-681` |
| `recv.cc` | `TransferReceiveSession::RecordBlockShards` | `:703-753` |
| `recv.cc` | `TransferReceiveSession::RecordBlockShards` (`if (done_ || draining_ || total_blocks_ == 0)`) | `:719-721` |
| `recv.cc` | `TransferReceiveSession::AcquireStagingSlot` | `:755-784` |
| `recv.cc` | `TransferReceiveSession::LookupStagingSlot` | `:786-794` |
| `recv.cc` | `TransferReceiveSession::OnDataReceived` | `:796-811` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` | `:813-947` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`ABSL_ASSIGN_OR_RETURN(host_layer_idx, LookupStagingSlot(layer_idx));`) | `:819` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`if (done_ || draining_ || total_blocks_ == 0)` .. `trigger_enqueue = true;`) | `:826-835` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`// The receive may have been finished` .. `h2d_futures_.push_back(future);`) | `:847-879` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`if (!future_or.ok())`) | `:868-874` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`future.OnReady`) | `:883-932` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`absl::Cleanup end_op`) | `:890` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`absl::MutexLock lock(self->mu_);` .. `self->FinishLocked(status_or.status(), kH2dPhase);`) | `:894-914` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`dispatched_layers_.insert(layer_idx);` .. `network_completed_ = true;`) | `:938-941` |
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` | `:274-278` |
| `mgr.cc` | `KVCacheManagerWithTransfer::GetSession` | `:280-287` |
| `mgr.cc` | `KVCacheManagerWithTransfer::~KVCacheManagerWithTransfer` (`for (const auto& [uuid, session] : sessions_)` .. `session->AwaitForDone().IgnoreError();`) | `:368-383` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RetireSettledSessionLocked` | `:436-511` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RetireSettledSessionLocked` (`if (auto recv =` .. `transfer_details_[recv->req_id()] = recv->Details();`) | `:441-449` |
| `mgr.cc` | `KVCacheManagerWithTransfer::EmplaceRecvSessionLocked` | `:568-585` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RegisterActivePlan` | `:587-658` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RegisterRecv` | `:660-681` |
| `mgr.cc` | `KVCacheManagerWithTransfer::UnregisterActivePlan` | `:776-822` |
| `mgr.cc` | `KVCacheManagerWithTransfer::UnregisterActivePlan` (`session->Finish(absl::CancelledError("receive plan unregistered"));`) | `:806` |
| `mgr.cc` | `KVCacheManagerWithTransfer::StartRead(remote_endpoint)` | `:884-989` |
| `mgr.cc` | `KVCacheManagerWithTransfer::StartRead(remote_endpoint)` (`FaultInjectStatus(hooks::kKvCacheManagerApiStartReadSubmitPull);` .. `session->Finish(started);`) | `:976-986` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`for (auto it = sessions_.begin();`) | `:999-1044` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`} else if (auto recv =` .. `absl::DeadlineExceededError("Receive session timed out"));`) | `:1018-1027` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`auto current = it++;` .. `retired_uuids.push_back(uuid);`) | `:1038-1042` |
| `base.cc` | `KVCacheManagerBase::GetSession` | `:2716-2722` |
| `base.cc` | `KVCacheManagerBase::OnBlockShardsReceived` | `:2987-3005` |
| `base.cc` | `KVCacheManagerBase::OnLayerReceived` | `:3009-3018` |
| `base.cc` | `*` (`size_t ResolveNumStagingLayers(size_t num_layers,` .. `return requested;`) | `:429-445` |
| `base.cc` | `KVCacheManagerBase::GetBlockChunks` (`absl::StatusOr<size_t> slot = session->ResolveStagingSlot(layer_idx);`) | `:3172` |
| `bt.cc` | `BlockTransport::HandleCustomRequest` | `:419-442` |
| `bt.cc` | `BlockTransport::HandleIncomingPush` | `:466-475` |
| `bts.cc` | `BeginIncomingPush` | `:286-300` |
| `bts.cc` | `EndIncomingPush` | `:302-315` |
| `bts.cc` | `BlockTransportServerPushSession::StartStream` | `:345-478` |
| `bts.cc` | `BlockTransportServerPushSession::StartStream` (`absl::Cleanup end_incoming_push`) | `:359-364` |
| `bts.cc` | `BlockTransportServerPushSession::CompleteIncomingPush` | `:526-695` |
| `send_drain_test.cc` | `RecvLifecycleTest.OutOfOrderLayersSettleAfterEveryH2d` | `:968-987` |
| `send_drain_test.cc` | `RecvLifecycleTest.DetailsReportWhenTheLastH2dLanded` | `:883-898` |
| `send_drain_test.cc` | `RecvLifecycleTest.DetailsSayAReceiveTimedOutWaitingForData` | `:900-913` |
| `send_drain_test.cc` | `RecvLifecycleTest.DetailsSayAFailedUploadFailedInH2dWhileDataArrives` | `:915-929` |
| `send_drain_test.cc` | `RecvLifecycleTest.SingleFailedH2dReportsFailureAndReturnsStaging` | `:989-1000` |
| `send_drain_test.cc` | `RecvLifecycleTest.NetworkCompletionWaitsForH2d` | `:843-861` |
| `send_drain_test.cc` | `RecvLifecycleTest.EmptyBlockReportIssuesNoH2d` | `:863-881` |
| `send_drain_test.cc` | `RecvLifecycleTest.LateBlockAccountingAfterRetirementIsANoOp` | `:944-966` |
| `send_drain_test.cc` | `RecvLifecycleTest.SessionRemainsValidAcrossAsyncH2dCallbacksAfterCallerDropsPtr` | `:1240-1268` |
| `send_drain_test.cc` | `RecvLifecycleTest.ReceiveWithoutTrafficFailsAtItsDeadline` | `:1002-1013` |
| `send_drain_test.cc` | `RecvDrainTest.ExpiredReceiveKeepsStagingUntilH2dEnds` | `:1015-1042` |
| `send_drain_test.cc` | `RecvDrainTest.FailedLayerWaitsForOtherH2dCopies` | `:1152-1178` |
| `send_drain_test.cc` | `RecvDrainTest.TimeoutDuringH2dDispatchKeepsStaging` | `:1180-1216` |
| `send_drain_test.cc` | `RecvLifecycleTest.IncomingPushLeasePinsStagingDuringWriteAndRejectsWhenDraining` | `:1270-1294` |
| `send_drain_test.cc` | `RecvLifecycleTest.IncomingPushLeaseSpansLayerH2dAndBlockAccountingBeforeReleasing` | `:1597-1625` |
| `send_drain_test.cc` | `RecvLifecycleTest.FailedIncomingPushImmediatelyFailsSessionAndReleasesStagingBeforeDeadline` | `:1627-1656` |
| `send_drain_test.cc` | `RecvLifecycleTest.FirstAdmittedPushRecordsFirstPacketOnce` | `:1296-1327` |
| `send_drain_test.cc` | `RecvLifecycleTest.AdmissionRejectedByDoneSessionRecordsNoFirstPacket` | `:1329-1361` |
| `send_drain_test.cc` | `RecvLifecycleTest.AdmissionRejectedByDrainingSessionRecordsNoFirstPacket` | `:1363-1404` |
| `send_drain_test.cc` | `RecvLifecycleTest.PeregrineLayerCompletionsRecordLastPacketOnceAndFinishAfterH2d` | `:1423-1463` |
| `send_drain_test.cc` | `RecvLifecycleTest.TcpLastLayerThenItsBlockReportRecordLastPacketOnceAndFinishOnce` | `:1465-1511` |
| `send_drain_test.cc` | `RecvLifecycleTest.TcpH2dFinishingBeforeLastBlockReportRecordsLastPacketAndFinishesOnce` | `:1513-1557` |
| `send_drain_test.cc` | `RecvLifecycleTest.RedeliveredLayerDoesNotCompleteNetworkPhase` | `:1559-1595` |
| `send_drain_test.cc` | `RecvLifecycleTest.RedeliveredStartReadLeavesAReadyReceiveToCompleteRead` | `:1095-1124` |
| `send_drain_test.cc` | `RecvLifecycleTest.RegisterRecvFinishesAReadyIncumbentBeforeReplacingIt` | `:1126-1150` |
| `send_drain_test.cc` | `RecvLifecycleTest.StagingLayerManagerCyclesHostLayerBuffers` | `:1726-1810` |
| `send_drain_test.cc` | `RecvLifecycleTest.StagingLayerManagerReleasesAllResourcesAcrossFailureModes` | `:1812-1922` |
| `send_drain_test.cc` | `RecvLifecycleTest.GetSessionResolvesActiveRecvAndReturnsNotFoundAfterRetirement` | `:2206-2231` |
| `send_drain_test.cc` | `RecvLifecycleTest.FailedH2dDispatchFailsAndSettlesTheReceive` | `:2236-2255` |
| `send_drain_test.cc` | `RecvLifecycleTest.SecondFinishOnAFailedReceiveIsANoOp` | `:2259-2275` |
| `send_drain_test.cc` | `RecvLifecycleTest.PushLeaseClosingBeforeTheCopyEndsDoesNotSettle` | `:2281-2299` |
| `send_drain_test.cc` | `RecvDrainTest.CancelledReceiveWhoseCopyThenFailsStaysCancelled` | `:2304-2317` |
| `control_test.cc` | `ControlHandshakeTest.ExpiredReceiveKeepsStagingUntilHandshakeEnds` | `:813-853` |
| `control_test.cc` | `ControlHandshakeTest.AcceptedPullAdvancesReceivePhaseAndReleasesHandshakeOp` | `:892-925` |
| `control_test.cc` | `ControlHandshakeTest.AcceptedPullAfterDeadlineSweepSettlesExpiredReceive` | `:927-968` |
| `control_test.cc` | `ControlHandshakeTest.RejectedPullReportsWhyAndWhichProducerRejectedIt` | `:982-1000` |
| `control_test.cc` | `ControlHandshakeTest.RefusedConnectionKeepsItsStatusCode` | `:1002-1027` |
| `pool_reshard_test.cc` | `DemandStagingTest.UnregisteringIdleReceiverReleasesPlanAtOnce` | `:486-511` |
| `pool_reshard_test.cc` | `DemandStagingTest.UnregisteringInFlightReceiverDefersUntilItSettles` | `:513-554` |
| `pool_reshard_test.cc` | `DemandStagingTest.DemandStagedReceiverPlanUnregistersWhenItSettles` | `:616-639` |
<!-- source-map:end -->
-/
