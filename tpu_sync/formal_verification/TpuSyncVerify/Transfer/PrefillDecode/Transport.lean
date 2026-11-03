import TpuSyncVerify.Transfer.PrefillDecode.Transport.Model
import TpuSyncVerify.Transfer.PrefillDecode.Transport.Lemmas
import TpuSyncVerify.Transfer.PrefillDecode.Transport.Invariant
import TpuSyncVerify.Transfer.PrefillDecode.Transport.Traces

/-!
# Receiver-side stream accounting in `BlockTransport`

Models the per-uuid layer progress table the transport keeps for incoming
pushes (`BlockTransportServerPushSession::layer_progress_`) and the two
receiver counters of `TransferReceiveSession` it feeds, to discharge the
assumption `Receive.lean` calls **A1** ("one dispatch per layer") and the
coarsening behind **A4** ("a layer's blocks are accounted once its copy is
issued"), and to state exactly what they rest on.

Abbreviations: `bt.cc` = `tpu_sync/transport/block_transport.cc`, `bt.h` =
`tpu_sync/transport/block_transport.h`, `bts.cc` =
`tpu_sync/transport/block_transport_session.cc`, `bts.h` =
`tpu_sync/transport/block_transport_session.h`, `recv.cc` =
`tpu_sync/kv_cache/transfer_receive_session.cc`, `mgr.cc` =
`tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`, `send.cc` =
`tpu_sync/kv_cache/transfer_send_session.cc`, `base.cc` =
`tpu_sync/kv_cache/kv_cache_manager_base.cc`, `coord.cc` =
`tpu_sync/kv_cache/reshard/reshard_coordinator.cc`, `planner.cc` =
`tpu_sync/kv_cache/reshard/pool_reshard_planner.cc`, `block_transport_session_test.cc` =
`tpu_sync/transport/block_transport_session_test.cc`, `block_transport_test.cc` =
`tpu_sync/transport/block_transport_test.cc`. Exact line ranges for every
symbol and sub-block are in the generated `## Source map` table below.

## What is modelled

One receive (`uuid`) with `numLayers` block arrays, each pushed by
`numSenders` senders that each declare `numStreams` streams per layer
(`header.reserved` passed as `num_streams` to `CompleteIncomingPush`) carrying
`blocksPerStream` blocks. `BlockTransport` keeps one
`BlockTransportServerPushSession` per uuid in `active_push_sessions_`
(`BlockTransport::GetOrCreatePushSession`, under `server_sessions_mu_`); the
session owns the uuid's progress table `layer_progress_` (keyed by layer,
guarded by the session's own `mu_`), so the one-uuid view taken here is the
structure of the C++, not an abstraction of a shared table. A stream is
`BlockTransport::HandleIncomingPush` → `GetOrCreatePushSession(header.uuid)` →
`BlockTransportServerPushSession::StartStream` from the admission gate to the
final ack, collapsed into one event: the progress-table update is one
critical section of the push session's `mu_` in
`BlockTransportServerPushSession::CompleteIncomingPush`
(`auto& progress = layer_progress_[l]`) and the two delegate callbacks that
follow run on the same reader thread, so interleaving other streams between
them changes nothing the properties here observe. The sender always names one
layer per stream (`TransferSendSession::SendNextLayer`'s `H2hWriteDirectAsync`
→ `BlockTransport::BuildBlockRequests`'s `header_layer_idx`), so the
all-layers form `local_id == 0xFFFFFFFF` in `ResolveIncomingPushSpec` and
`CompleteIncomingPush` does not arise and `l` ranges over `0 .. numLayers - 1`.

Two of the four completion contracts of
`BlockTransportServerPushSession::CompleteIncomingPush` are modelled, selected
by `Cfg.declared`:

* **chunk-count** (`expected_senders = nullopt`,
  `array_complete = progress.completed_chunks == expected_chunks`): the layer
  completes when `completed_chunks == num_streams`. This is the contract of
  the prefill-to-decode path whenever no receiver plan with
  `shard_push_schedules` is registered (`KVCacheManagerBase::ExpectedPushSenders`)
  — in particular always on the `StartRead` pull path, which registers no plan
  (`KVCacheManagerWithTransfer::StartRead(remote_endpoint)`).
* **sender-declared** (`expected_senders = some n`,
  `else if (expected_senders.has_value())`): per sender `landed`/`declared`,
  `senders_complete`, and three rejections (`AlreadyExists` when a sender lands
  more than it declared or more senders than expected appear,
  `FailedPrecondition` when a sender re-declares).

The plan-declared contract (`if (plan_declared)` in `CompleteIncomingPush`, pool
resharding) is out of scope; see `Reshard/`. So is the Peregrine contract
(`else if (is_peregrine)`): it is reached only from
`BlockTransportServerPushSession::OnPeregrinePostComplete`, the receiver side of
the Peregrine data plane, whose only entry point `BlockTransport::OnRecvComplete`
nothing outside the transport's own tests calls yet (the sender side,
`BlockTransport::AsyncPush` routing a push to the Peregrine adapter when
`config_.backend_for(op) == TransportBackend::kPeregrine`, is likewise outside
the model; the socket path `StartStream` is what every production push takes
and it leaves `is_peregrine` at its default). On the receive session
`network_completed_` has two setters: the block report
(`RecordBlockShardsReceivedLocked`, `networkCompleted` here) and, once every
layer's copy has been issued, `TransferReceiveSession::ExecuteLayerH2d`
(`dispatched_layers_.insert(layer_idx)` reaching `num_layers()` on a receive
that is neither done nor draining), which `Receive.lean` models as `netIssued`.
The second setter is not state here: it fires only after every layer was
dispatched, so `NetworkSound` holds for it by construction, and in every state
where it would make `publish` enabled — all layers dispatched, no copy pending,
not draining — every callback has already run OK and `completedLayers =
numLayers` enables `publish` already.

The session side is `Transfer/Session.lean`'s `Lifecycle`, transcribed as
`Receive.lean` does: the push lease is `beginOp` (`TransferReceiveSession::TryBeginOp`,
called by `BeginIncomingPush` in `block_transport_session.cc` on the session
`delegate_->GetSession(uuid)` returns) and is returned inside the same event
(`TransferReceiveSession::EndOp` via `EndIncomingPush`, from `StartStream`);
the H2D callback and the poll finish through `finishLocked`/`endOpLocked`
(`TransferReceiveSession::FinishLocked`, `EndRecvOpLocked`). `inFlight` counts
only H2D copies whose callback has not run.

## State

| Field | C++ | Role |
|---|---|---|
| `Layer.entry` | `layer_progress_[l]` of the uuid's push session (`BlockTransportServerPushSession::LayerProgress`, `layer_progress_`) | `none` = no entry (never created, or cleared by retirement) |
| `Progress.completedChunks` | `LayerProgress::completed_chunks` | chunk-count contract |
| `Progress.landed` | `SenderStreams::landed` per sender | sender-declared contract |
| `Progress.sendersComplete` | `LayerProgress::senders_complete` | sender-declared contract |
| `Progress.called` | `LayerProgress::on_layer_received_called` | the once-latch |
| `Layer.sent` | ghost | streams accepted per sender for this layer |
| `Layer.dispatched` | ghost | `OnLayerReceived` → `KVCacheManagerBase::OnLayerReceived` → `OnDataReceived` → `ExecuteLayerH2d` entries for this layer |
| `Layer.pending` | subset of `h2d_futures_` (`ExecuteLayerH2d`: `h2d_futures_.push_back(future)`) | copies issued for this layer whose callback has not run |
| `blocks` | `blocks_received_per_shard_` collapsed to one shard (`RecordBlockShardsReceivedLocked`) | block units reported by `OnBlockShardsReceived` → `OnDataReceived` → `RecordBlockShards` |
| `completedLayers` | `num_completed_layers_` (`ExecuteLayerH2d`: `self->num_completed_layers_++`) | H2D callbacks that ran OK |
| `life` | `in_flight_`, `draining_`, `done_`, `status_`, staging (`Lifecycle`) | settle protocol |

The shard dimension is collapsed: every shard shares the one target
`total_blocks_ * num_layers` (`RecordBlockShardsReceivedLocked`:
`const int64_t per_shard_target = total_blocks_ * num_layers`) and a stream adds
its block count to every shard it carries, so one counter against
`numSenders * numStreams * blocksPerStream * numLayers` has the same
completion behaviour (A4 in `Receive.lean` restates this over shards).

## Events

| Event | C++ |
|---|---|
| `stream l s` | `HandleIncomingPush` → `GetOrCreatePushSession` → `StartStream`: `BeginIncomingPush` → `delegate_->GetSession(uuid)` → `TryBeginOp` (refuses once `done_`/`draining_`, and always on a send session), payload, `CompleteIncomingPush`, on completion `OnLayerReceived` → `KVCacheManagerBase::OnLayerReceived` → `OnDataReceived(layer_idx, {}, {})` → `ExecuteLayerH2d` (`++in_flight_`), then `OnBlockShardsReceived` → `OnDataReceived(0, block_ids, shard_ids)` → `RecordBlockShards`, `EndIncomingPush` → `EndOp`. A rejection inside `CompleteIncomingPush` returns early and `absl::Cleanup end_incoming_push` ends the push with `InternalError("Incoming push failed")`, which `EndIncomingPush` turns into `Finish(status)` then `EndOp()`. |
| `h2dDone l ok` | the `future.OnReady` callback of a layer's copy in `ExecuteLayerH2d`: on OK `num_completed_layers_++` and, at `num_layers()` while not draining, the success `FinishLocked()`; on error `FinishLocked(status_or.status(), kH2dPhase)`; then `absl::Cleanup end_op`'s `EndOp()` |
| `publish` | `CompleteReadWithDetails`: a receive that is not draining and `IsReadyToComplete()` (`network_completed_ || num_completed_layers_ == num_layers`, and every issued future ready) is `Finish()`ed. "Every future ready" is taken as "every callback has run"; the window between the two is `ReceivePoll.lean`'s subject (`pollReady`) and changes no property here. |
| `cancel` | the deadline sweep in `CompleteReadWithDetails` (`else if (session->deadline() <= now)`) or any other `Finish(error)` on a receive that is not yet draining |

`published` (`life.done && life.statusOk`) is what the poll reports in
`done_recving_` (`CompleteReadWithDetails`).

## Lock scopes

Four mutexes meet on the push thread: `BlockTransport::server_sessions_mu_`
(the uuid → push-session map `active_push_sessions_`), the manager's
`KVCacheManagerWithTransfer::mu_` (the uuid → `TransferSession` map `sessions_`
read by `GetSession`), the push session's `BlockTransportServerPushSession::mu_`
(its `layer_progress_` and `done_`), and the receive session's
`TransferReceiveSession::mu_`. `stream` is the one deliberately coarse event in
the prefill-to-decode models: it spans all four. In order on the push thread:
`GetOrCreatePushSession` (`server_sessions_mu_`, creating the session on the
uuid's first stream), `BeginIncomingPush` = `delegate_->GetSession(uuid)`
(manager `mu_`, returning the `shared_ptr` the rest of the stream holds) then
`TryBeginOp` (receive-session `mu_`), the payload write (unlocked; under
bounded host layer staging each chunk's `GetBlockChunks` also runs
`TransferReceiveSession::AcquireStagingSlot`, audited in `Receive.lean`), the
`expected_senders` lookup (push-session `mu_`), the unlocked
`ExpectedPushSenders` check (A2), the `layer_progress_` update with the
once-latch and retirement (push-session `mu_`, A1), then `OnLayerReceived` →
`KVCacheManagerBase::OnLayerReceived` (`GetSession`, manager `mu_`) →
`OnDataReceived` → `ExecuteLayerH2d` (receive-session `mu_` scopes, audited in
`Receive.lean`), `OnBlockShardsReceived` → `KVCacheManagerBase::OnBlockShardsReceived`
(`GetSession`, manager `mu_`) → `OnDataReceived` → `RecordBlockShards`
(receive-session `mu_`), and `EndIncomingPush` → `EndOp` (receive-session
`mu_`, plus `GetStatus()`); back in `HandleIncomingPush`, `DeletePushSession`
(`server_sessions_mu_`) if the push session `IsDone()`. If
`CompleteIncomingPush` rejects the push, the `absl::Cleanup end_incoming_push`
runs `EndIncomingPush(session, InternalError(...))`, which calls
`Finish(status)` before `EndOp()`. `h2dDone`, `publish` and `cancel` are
`Receive.lean`'s `h2dDone`, `pollReady` and `cancel`.

| Event | Scopes | Between them |
|---|---|---|
| `stream l s` | `server_sessions_mu_`, manager `mu_`, push-session `mu_` and receive-session `mu_` scopes above | concurrent streams of one uuid share one push session (`GetOrCreatePushSession` returns the existing entry) and serialize their `layer_progress_` updates on its `mu_` in the order of the model's `stream` events; streams of other uuids touch other sessions. Their receive-session calls are covered by `Receive.lean`; the `shared_ptr` from `GetSession` keeps the receive session alive for the stream even if the manager retires it from `sessions_` meanwhile. If `Finish(error)` lands after `TryBeginOp` and before the delegate calls finish, `ExecuteLayerH2d` and `RecordBlockShards` return at `if (done_ || draining_ || total_blocks_ == 0)` and `EndOp` releases the lease while `layer_progress_` keeps its latch; `Safe` still holds (`OnceDispatched` by the latch, `NetworkSound` vacuously because `blocks < c.target`, and `published = false`). Likewise, if an OK `Finish()` lands before `OnBlockShardsReceived`, every layer has already been dispatched and completed its H2D copy (`CompleteOnSuccess`), and `blocks < c.target` keeps `NetworkSound` vacuous |
| `h2dDone l ok` | 2 (`Receive.lean`) | an `EndOp` tail (`Receive.lean`) |
| `publish` | `IsDraining()`, `IsReadyToComplete()`, `Finish()` (`Receive.lean`, `pollReady`) | monotone readiness; an OK `Finish()` on a draining session is a no-op |
| `cancel` | 1: `Finish(error)` | guarded here by `!draining`; a stale sweep is a no-op |

Retirement (`if (all_layers_called)` in `CompleteIncomingPush`) runs
`layer_progress_.clear()` and sets the push session's `done_` in the same
critical section as the latch; the session is dropped from
`active_push_sessions_` by `HandleIncomingPush`'s `DeletePushSession` once
`StartStream` has returned (after the delegate callbacks, `EndIncomingPush` and
the ack). `StartStream` and `CompleteIncomingPush` never test `done_`, so a
stream that reaches the retired session in between starts a fresh entry in its
cleared table (dropped with the session), and a later stream creates a fresh
session with a fresh entry: `Layer.entry = none` covers both.
`BlockTransport::ForgetPushProgress` removes the uuid's session from
`active_push_sessions_` (under `server_sessions_mu_`) and `Cancel()`s it, from
`KVCacheManagerWithTransfer::CompleteReadWithDetails` (for each uuid
`RetireSettledSessionLocked` retired with `retired_push_progress`: a settled
receive, or a failed send), `UnregisterActivePlan` (only once `Done()`) and
`RegisterActivePlan` (when it retires a settled incumbent); no stream passes
`TryBeginOp` on a settled receive, and a stream already past the gate that
recreates an entry finds the receive session draining. It is not an event.

## Assumptions

* **A1 (one lock).** All progress-table mutation is under the push session's
  `mu_` in `CompleteIncomingPush`, and a session holds exactly one uuid's
  table; the latch is set in the same critical section that decides completion
  (`if (array_complete && !progress.on_layer_received_called)`).
  Encoded by making the table update one step.
* **A2 (stable expectation).** `ExpectedPushSenders(uuid)` is read outside
  the lock and latched on the layer's first stream (`if (!progress.expected_senders_resolved)`),
  so the contract a layer runs under is whatever the first stream saw. Encoded as
  the fixed `Cfg.declared`. `KVCacheManagerBase::ExpectedPushSenders` reads the
  plan of the uuid's session (`GetTransferPlan` → `GetSession(uuid)->plan()` →
  `TransferPlan::ExpectedPushSenders`) and returns `std::nullopt` when no
  receiver plan is registered (`StartRead`, `KVCacheStore` /
  `WorkerServiceImpl::TransferBuffers`, and `WeightSynchronizerBase`), when
  `pool_groups_size() > 0` (pool reshard via `ReshardCoordinator::RunSubPlan`,
  which takes the `GetPoolPushProgressSpec` branch in `CompleteIncomingPush`),
  and when `shard_push_schedules_size() == 0` (including primary
  `StageBroadcastGroup` hops in `BroadcastEngine.execute_slice_broadcast_pipeline`
  (`_dispatch_hop`) in
  `tpu_sync/weight_sync/manager/broadcast_engine.py`), so the sender-declared
  contract (`sender_streams`) is entered only on non-pool receiver
  `RegisterActivePlan` plans (`pool_groups_size() == 0` with
  `shard_push_schedules_size() > 0`). Inside
  `KVCacheManagerWithTransfer::RegisterActivePlan` the receive session carries
  its plan from construction (`TransferReceiveSession::CreateFromActivePlan`)
  and is seated in `sessions_` (`EmplaceRecvSessionLocked`) under the manager's
  `mu_`, which is the one `GetSession` takes, so the plan becomes visible to
  `ExpectedPushSenders` and to `TryBeginOp` in the same step, and `A2` holds
  whenever senders are dispatched only after `RegisterActivePlan` has returned
  (whereas a push arriving before or concurrently with `RegisterActivePlan`
  could latch chunk-count on a sender-declared plan, `trace_chunk_two_senders`). Every
  in-repo controller hop that populates receiver `shard_push_schedules` on a
  non-pool plan (`BroadcastEngine.execute_slice_broadcast_pipeline`
  (`_run_single_transfer`) in
  `tpu_sync/weight_sync/manager/broadcast_engine.py`, invoked from
  `RaidenController.start_transfer` in `tpu_sync/rpc/raiden_controller.py`, and
  remote destination preparation via
  `RaidenControllerClientFacade.register_transfer_schedule` in
  `tpu_sync/weight_sync/manager/controller_rpc_service.py`) awaits the
  destination `COMMAND_START_TRANSFER` RPC (`KVCacheListener::HandleControlRequest`
  runs `register_active_plan` synchronously before replying) before dispatching
  any sender; `A2` therefore remains an external ordering assumption only against
  callers that dispatch pushes before `RegisterActivePlan` returns.
* **A3 (uniform declaration, one node per schedule).** Every sender declares
  the same `numStreams`, and no sender outside the expected set appears; the
  `FailedPrecondition` and "more senders" rejections in `CompleteIncomingPush`
  (`else if (streams.declared != num_streams)` and
  `if (progress.sender_streams.size() > *expected_senders)`) are
  therefore never taken and are not modelled. Senders are told apart by
  `header.remote_id = node_id()` (`BuildBlockRequests`:
  `remote_id = static_cast<uint32_t>(block_delegate_->node_id())`), which also
  keys the plan's chunk lookup in `GetBlockChunks` →
  `TransferPlan::ResolvePlanBlockChunks` (`if (sender_node_id != -1)`), while
  `expected_senders` counts `shard_push_schedules` on non-pool plans
  (`StartTransferRequest.shard_push_schedules`). Pool reshard checks unique
  contiguous `transfer_rank`s in `BuildPoolReshardPlan` (`Source transfer_rank
  values must be unique`) and bypasses `ExpectedPushSenders`, and `KVCacheStore`
  startup checks dense `[0, N)` `node_id`s in
  `HostOffloadBackend::ComposeKVTransferSpec` when `expected_worker_count > 0`
  with a global registry (`WorkerRegistry::RegisterWorker` exempts
  `node_id == 0`, and store transfers bypass `RegisterActivePlan`). On
  legacy non-pool `RegisterActivePlan` plans (`KVCacheManagerWithTransfer` and
  its `KVCacheManager` bindings default `node_id` to `0`, while
  `KVCacheManagerBase::node_id()` defaults to `-1`, and
  `JobEntity.encode_start_transfer` in `tpu_sync/weight_sync/manager/job_entity.py`
  keys receiver `shard_push_schedules` per source shard when `num_src_shards > 1`),
  neither `KVCacheManagerBase` / `KVCacheManagerWithTransfer` nor
  `RegisterActivePlan` checks that pushing workers carry distinct `node_id`s
  matching one `shard_push_schedules` entry each.
* **A4 (honest senders) — `Cfg.honest`.** Every sender sends at most the
  streams it declared for each layer, for the life of the receive. Encoded as
  a guard on `stream`: a stream beyond the declaration is not enabled. This
  is the assumption the C++ does **not** enforce on the chunk-count contract,
  nor on any contract after the table entries are retired
  (`if (all_layers_called)` in `CompleteIncomingPush`); the traces at the end drop it.

## Properties

* **`OnceDispatched`** — `ExecuteLayerH2d` runs at most once per layer. This
  is `Receive.lean` A1 and what its guard `issued + pending < numLayers`
  encodes.
* **`NetworkSound`** — when the block count reaches its target, every layer's
  copy has been issued. This is the coarsening behind `Receive.lean` A4
  (`netAccount` guarded by `layersAccounted < issued`).
* **`CompleteOnSuccess`** — a receive published as successful issued every
  layer's copy exactly once and no copy is still in flight. This is what the
  engine reads out of `done_recving`.

`reachable_safe`: under A4 both contracts satisfy all three, for any
positive `numLayers`, `numSenders`, `numStreams`, `blocksPerStream`.

Without A4 (`Cfg.honest = false`) the traces at the end show what one extra
stream does: on the chunk-count contract before retirement the receive is
published with a layer never copied; on either contract after retirement the
layer is copied twice (the session's `in_flight_` still holds `done_` off
until both copies return, and a failing duplicate copy fails the receive).

Three transport unit tests replay on `step` (`paired` in `Transport/Traces.lean`):
`BlockTransportTest.LayerCompletesOnlyAfterEveryDeclaredSender` (sender-declared,
either arrival order, then reuse after retirement),
`BlockTransportTest.SenderOverDeliveryIsRejected` (the `streams.landed >
streams.declared` rejection) and
`BlockTransportTest.UndeclaredUuidKeepsHeaderDeclaredCompletion` (the chunk-count
contract on two senders, `Cfg.WF.chunkSingle`'s excluded instance); the
chunk-count retirement of one layer by two streams is `modelOnly`
(`tr_session_two_streams_complete`). Sibling push-progress tests that vary
declarations per sender (outside A3), call `Cancel` / `ForgetPushProgress`, or
exercise the plan-declared pool or Peregrine branches
(`BlockTransportServerPushSessionTest.LifecycleAndPostCompletion` drives
`OnPeregrinePostComplete`) are listed in `notReplayable`.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `bts.h` | `BlockTransportServerPushSession` (`struct LayerProgress` .. `absl::flat_hash_map<int, LayerProgress> layer_progress_ ABSL_GUARDED_BY(mu_);`) | `:143-167` |
| `bt.h` | `BlockTransport` (`absl::Mutex server_sessions_mu_;` .. `active_push_sessions_ ABSL_GUARDED_BY(server_sessions_mu_);`) | `:284-287` |
| `bts.cc` | `ResolveIncomingPushSpec` | `:229-284` |
| `bt.cc` | `BlockTransport::GetOrCreatePushSession` | `:444-454` |
| `bt.cc` | `BlockTransport::HandleIncomingPush` | `:466-475` |
| `bt.cc` | `BlockTransport::DeletePushSession` | `:456-459` |
| `bt.cc` | `BlockTransport::OnRecvComplete` | `:480-490` |
| `bt.cc` | `BlockTransport::AsyncPush` (`if (config_.backend_for(op) == TransportBackend::kPeregrine)`) | `:523-536` |
| `bts.cc` | `BlockTransportServerPushSession::StartStream` | `:345-478` |
| `bts.cc` | `BlockTransportServerPushSession::OnPeregrinePostComplete` | `:483-515` |
| `bts.cc` | `BlockTransportServerPushSession::CompleteIncomingPush` | `:526-695` |
| `bts.cc` | `BlockTransportServerPushSession::StartStream` (`absl::Cleanup end_incoming_push`) | `:359-364` |
| `bts.cc` | `BeginIncomingPush` | `:286-300` |
| `bts.cc` | `EndIncomingPush` | `:302-315` |
| `bts.cc` | `BlockTransportServerPushSession::CompleteIncomingPush` (`std::optional<size_t> expected_senders;` .. `expected_senders = delegate_->ExpectedPushSenders(uuid_);`) | `:543-555` |
| `bts.cc` | `BlockTransportServerPushSession::Cancel` | `:338-343` |
| `bt.cc` | `BlockTransport::ForgetPushProgress` | `:1023-1037` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`transport->ForgetPushProgress(uuid);`) | `:1063` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RetireSettledSessionLocked` (`if (auto recv =` .. `transfer_details_[recv->req_id()] = recv->Details();`) | `:441-449` |
| `bts.cc` | `BlockTransportServerPushSession::CompleteIncomingPush` (`bool array_complete = false;` .. `array_complete = progress.completed_chunks == expected_chunks;`) | `:574-650` |
| `bts.cc` | `BlockTransportServerPushSession::CompleteIncomingPush` (`bool all_layers_called = true;` .. `done_ = true;`) | `:668-679` |
| `bt.cc` | `BlockTransport::BuildBlockRequests` (`const uint32_t remote_id =` .. `static_cast<uint32_t>(header_layer_idx);`) | `:743-749` |
| `recv.h` | `TransferReceiveSession::Done` | `:101-104` |
| `recv.h` | `TransferReceiveSession::IsDraining` | `:118-121` |
| `recv.cc` | `TransferReceiveSession::TryBeginOp` | `:533-544` |
| `recv.cc` | `TransferReceiveSession::FinishLocked` | `:469-484` |
| `recv.cc` | `TransferReceiveSession::Finish` | `:486-489` |
| `recv.cc` | `TransferReceiveSession::EndRecvOpLocked` | `:520-531` |
| `recv.cc` | `TransferReceiveSession::EndOp` | `:546-549` |
| `recv.cc` | `TransferReceiveSession::IsReadyToComplete` | `:558-564` |
| `recv.cc` | `TransferReceiveSession::RecordBlockShardsReceivedLocked` | `:573-598` |
| `recv.cc` | `TransferReceiveSession::RecordBlockShards` | `:703-753` |
| `recv.cc` | `TransferReceiveSession::OnDataReceived` | `:796-811` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`dispatched_layers_.insert(layer_idx);`) | `:938` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` | `:813-947` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`future.OnReady`) | `:883-932` |
| `block_transport_session_test.cc` | `MockSessionDelegate` | `:44-149` |
| `block_transport_session_test.cc` | `BlockTransportServerPushSessionTest.LifecycleAndPostCompletion` | `:151-189` |
| `block_transport_session_test.cc` | `BlockTransportServerPushSessionTest.Cancel` | `:191-202` |
| `block_transport_test.cc` | `MockDelegate` | `:196-387` |
| `block_transport_test.cc` | `MultiSenderReceiverDelegate` | `:431-450` |
| `block_transport_test.cc` | `BlockTransportTest.PushSplitBySourceNumaCompletesPlanDeclaredPool` | `:857-887` |
| `block_transport_test.cc` | `BlockTransportTest.LayerCompletesOnlyAfterEveryDeclaredSender` | `:1066-1112` |
| `block_transport_test.cc` | `BlockTransportTest.DeclaredSendersEachCompleteTheirOwnParallelism` | `:1114-1150` |
| `block_transport_test.cc` | `BlockTransportTest.SenderOverDeliveryIsRejected` | `:1152-1189` |
| `block_transport_test.cc` | `BlockTransportTest.SenderChangingDeclaredStreamCountIsRejected` | `:1191-1224` |
| `block_transport_test.cc` | `BlockTransportTest.UndeclaredUuidKeepsHeaderDeclaredCompletion` | `:1226-1260` |
| `block_transport_test.cc` | `BlockTransportTest.ForgetPushProgressAllowsUuidReuse` | `:1262-1294` |
| `block_transport_test.cc` | `BlockTransportTest.PoolProgressWaitsForEveryStreamOfEveryDeclaredPoolAndRetires` | `:1296-1335` |
| `block_transport_test.cc` | `BlockTransportTest.ForgetPushProgressResetsPartialPoolGeneration` | `:1337-1364` |
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` (`hooks.get_session =`) | `:276` |
| `mgr.cc` | `KVCacheManagerWithTransfer::GetSession` | `:280-287` |
| `base.cc` | `KVCacheManagerBase::GetSession` | `:2716-2722` |
| `base.cc` | `KVCacheManagerBase::GetTransferPlan` | `:2724-2734` |
| `base.cc` | `KVCacheManagerBase::OnLayerReceived` | `:3009-3018` |
| `base.cc` | `KVCacheManagerBase::OnBlockShardsReceived` | `:2987-3005` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RegisterActivePlan` | `:587-658` |
| `mgr.cc` | `KVCacheManagerWithTransfer::UnregisterActivePlan` | `:776-822` |
| `mgr.cc` | `KVCacheManagerWithTransfer::StartRead(remote_descriptors)` | `:858-882` |
| `mgr.cc` | `KVCacheManagerWithTransfer::StartRead(remote_endpoint)` | `:884-989` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`} else if (auto recv =` .. `absl::DeadlineExceededError("Receive session timed out"));`) | `:1018-1027` |
| `send.cc` | `TransferSendSession::SendNextLayer` (`self->base_->H2hWriteDirectAsync`) | `:677-705` |
| `base.cc` | `KVCacheManagerBase::ExpectedPushSenders` | `:2747-2755` |
| `tpu_sync/kv_cache/transfer_plan.cc` | `TransferPlan::ExpectedPushSenders` | `:273-279` |
| `tpu_sync/kv_cache/transfer_plan.cc` | `TransferPlan::ResolvePlanBlockChunks` (`if (sender_node_id != -1) {` .. `auto schedule_found_it = sender_node_id != -1`) | `:407-428` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` (`std::vector<absl::Status> arm_status` .. `for (std::thread& t : armers) t.join();`) | `:743-776` |
| `planner.cc` | `BuildPoolReshardPlan` (`std::map<int64_t, RaidenId> ranks;` .. `++expected_rank;`) | `:966-981` |
| `tpu_sync/core/controller/worker_registry.cc` | `WorkerRegistry::RegisterWorker` (`if (entry.node_id != 0)`) | `:63-73` |
| `tpu_sync/kv_cache/host_offload_backend.cc` | `HostOffloadBackend::ComposeKVTransferSpec` | `:1420-1463` |
| `tpu_sync/kv_cache/kv_cache_listener.cc` | `KVCacheListener::HandleControlRequest` (`absl::Status status = callbacks_.register_active_plan(` .. `(*resp->mutable_receiver_pool_addrs())[static_cast<int32_t>(l)] =`) | `:188-201` |
| `tpu_sync/rpc/raiden_service.proto` | `StartTransferRequest` (`map<int32, ShardPushScheduleProto> shard_push_schedules`) | `:180` |
<!-- source-map:end -->
-/
