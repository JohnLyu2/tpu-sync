# Prefill-to-decode transfer: model and results

The reference map from the prefill-to-decode KV-cache transfer C++ to its Lean
models under `TpuSyncVerify/Transfer/`.

Each module's docstring owns its state table, event table, assumptions,
properties and `## Source map`; this page routes between them. It says what is
proved and where, lists the modules, draws the three boundaries of the model,
tabulates the assumptions and how each is discharged, sets the shipping code
beside the design alternatives modelled next to it, lists the mutants, and ends
with the per-symbol C++ → Lean index. Each `trace_*` theorem's docstring names
the C++ or end-to-end test it replays, so `grep -rn <TestName> TpuSyncVerify`
answers "is test X modelled".

File aliases: `recv.{h,cc}` = `tpu_sync/kv_cache/transfer_receive_session.{h,cc}`,
`send.{h,cc}` = `tpu_sync/kv_cache/transfer_send_session.{h,cc}`,
`session.h` = `tpu_sync/kv_cache/transfer_session.h` (`StagingLayerManager`),
`tpu_sync/transport/transfer_session.h` (the `TransferSession` interface, cited by
its full path),
`mgr.cc` = `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`,
`bt.{h,cc}` = `tpu_sync/transport/block_transport.{h,cc}`,
`bts.{h,cc}` = `tpu_sync/transport/block_transport_session.{h,cc}`,
`base.cc` = `tpu_sync/kv_cache/kv_cache_manager_base.cc`,
`tcp_control_plane_backend.cc` = `tpu_sync/core/tcp_control_plane_backend.cc`,
`grpc_control_plane_backend.cc` = `tpu_sync/core/grpc_control_plane_backend.cc`.

## What is proved

Every theorem below is proved on every reachable state of its model; the
statement column is the one-line form, the module docstring has the exact one.

| Property | Theorems | Statement |
|---|---|---|
| Data correctness and attention safety across requests | `Pipeline.system_data_correct`, `Pipeline.system_attention_safe` | In any reachable state of `multiSys` (concurrent, overlapped and recycled requests), a request that publishes `done_recving` has `decodeHbm = good n` and keeps it across every later transition. |
| Progress across requests | `Pipeline.system_progress` | From any reachable state, any request can settle, return both staging buffers and publish both outcomes (`HandedOff`) in finitely many steps. |
| Publication correctness, one request | `Pipeline.reachable_safe` (`PublicationCorrect`), `LayerStaging.reachable_safe` (`PublicationCorrect`) | `recv.published = some true → decodeHbm = good n` (both on the full host mirror and when cycling arbitrarily few `numSendSlots`, `numRecvSlots` host layer buffers under `num_staging_layers`). |
| Bounded host layer staging (`num_staging_layers`) | `StagingLayerManager.lookup_injective`, `LayerStaging.reachable_safe`, `LayerStaging.sendLookupStagingSlot_active`, `LayerStaging.recvLookupStagingSlot_active`, `LayerStaging.reachable_can_settle`, `LayerStaging.no_slots_cannot_publish_ok`, `LayerStaging.exists_complete_trace` | Host layer slots are conserved (`free.length + leases.length = numSlots`), mutually exclusive across layers (`sendLookupStagingSlot_injective`, `recvLookupStagingSlot_injective`), always resolve a live in-bounds `.kv l` buffer on every active producer lookup and open-stream consumer `ExecuteLayerH2d` precheck (`slotFault = false`), and are returned in full on settlement (`done → leases = []`); `0` slots on either side cannot publish `done_recving` for `n > 0`, whereas `1` slot on each side suffices for arbitrary `n` and every reachable state drains to settlement without deadlock. |
| Within-layer blocks: gather, reordering, coalescing, custom staging | `BlockOrdering.execCoalesced_buildCoalescedSpec`, `BlockOrdering.landStage_get_requested`, `BlockOrdering.h2dStage_get_requested`, `BlockOrdering.BlockPipeline.reachable_safe` | Coalesced DMA equals elementwise copy; the two permutations of `BuildLoadCopyPlan` (`remote_order`, `local_order`) cancel, so on `done_recving` every requested block `t` of layer `l` holds `.kv l t.remote` and unrequested blocks stay blank; custom host staging holds the same until reseated. |
| Decode HBM safety and quietness | `Recv.PublishedQuiet`, `Pipeline.DecodeHbmSafe`, `decodeHbm_quiet`, `attention_safe` | Once the receive is published no H2D copy is pending or unretired, so `decodeHbm` never changes afterwards. |
| Prefill HBM safety and quietness | `Send.PublishedQuiet`, `Pipeline.PrefillHbmSafe`, `prefillHbm_quiet` | Once the send is published no D2H copy is pending or unretired, so the caller may reclaim prefill HBM. |
| Staging integrity and quietness | `Recv.StagingIntegrity`, `Send.StagingIntegrity`, `Pipeline.StagingSafe`, `wroteReleased_eq_false` | `hasStaging = !done`; released staging is neither written nor read by the session that held it. |
| Handshake rendezvous and single pull claim | `Send.PullClaimed`, `Pipeline.HandshakeSafe`, `Pipeline.reachable_unregistered_safe`, `BlockOrdering.validateRegistration_iff`, `BlockOrdering.validateRequestedBlocks_iff` | `StartPush` and all data movement need `NotifyForRead`'s registration and `ValidateAndBeginPull`'s claim of a non-empty, duplicate-free subset of the registered blocks; while `HandlePullStream` waits, the pull stays pending and unclaimed. |
| Termination | `Recv.NoOpLeak`, `Send.NoOpLeak`, `Pipeline.NoOpLeak`, `Recv.reachable_can_settle`, `Send.reachable_can_settle`, `Pipeline.reachable_can_settle` | Every unit of `in_flight_` has an enabled step that advances or retires it, and every reachable state drains to `done ∧ ¬hasStaging` and publishes. |
| Per-side counters | `Recv.Publication`, `Send.Publication`, `Recv.ReadinessSound`, `Recv.SettleSafe`, `Send.SettleSafe`, `Send.NoUnderflow` | `done_recving → every H2D callback ran OK`; `done_sending → every push completed OK`; `IsReadyToComplete → ready = numLayers`; `done → inFlight = 0`; `EndSendOpLocked` never underflows. |
| Transport accounting | `Transport.reachable_safe` (`OnceDispatched`, `NetworkSound`, `CompleteOnSuccess`) | With honest senders, `OnLayerReceived` fires once per layer, the block target is reached only after every layer was dispatched, and a successful receive copied every layer exactly once. |
| Engine caller contract (single-worker, multi-worker, and intra-worker NUMA sub-managers) | `Caller.contract_safe`, `Caller.mw_contract_safe`, `Caller.numa_settledCounts_safe`, `Caller.numa_settledCounts_maps_clean`, `Caller.leakP_absorbing`, `Caller.leakD_absorbing`, `Caller.mwLeakP_absorbing`, `Caller.mwLeakD_absorbing` | A connector that forwards every publication leaks no held block on either node, never frees HBM while a worker or sub-manager on that node is still in flight (`mwEarlyFree = false`, `numaEarlyFree = false` under `NumaPolicy.settledCounts` across `req_id` reuse), and never lets decode read unwritten KV; a missed publication is unrecoverable by any later engine action. |
| Peer isolation and uuid tables | `PeerIsolation.reachable_safe`, `PeerIsolation.tcp_healthy_blocked_when_pool_full`, `PeerIsolation.grpc_healthy_can_complete`, `UuidTable.reachable_inv` | Host staging slots and `push_pool_` workers are conserved across peers. On the blocking TCP control plane a wedged pull holds a `push_pool_` worker, so `poolSize` pulls to a sick peer stop every further handshake, healthy peers included; on the gRPC backend a waiting pull holds no worker and a healthy peer completes once admitted (while `numSlots` wedged reads still exhaust the shared staging pool). A uuid is refused until its draining incumbent has settled, so staging slots are conserved. |

## Modules

Higher modules compose the lower `step` functions as-is: `Pipeline` = `Send.step` +
`Recv.step` + per-layer memories and guards; `LayerStaging` refines `Pipeline`
(`LayerStaging.step_pipe_steps` is a lockstep simulation over `Pipeline.step`)
by multiplexing `numLayers` layers over `numSendSlots` and `numRecvSlots` host
layer buffers through `StagingLayerManager`; `BlockOrdering` refines `Pipeline`'s
layer cell into a block array (`BlockPipeline.step_pipe` is a lockstep
simulation over `Pipeline.step`); `MultiRequest` runs `reqs : List Pipeline`
over the four shared buffers.

| Module | Scope | Main theorems |
|---|---|---|
| `Common/ListAux.lean` | `List` indexing / `countTrue` pigeonhole helpers | `all_true_of_countTrue_eq_length`, `exists_false_lt` |
| `Transfer/Session.lean` | settle protocol (`in_flight_`, `draining_`, `done_`, staging) shared by all session classes | `Lifecycle.Consistent` preserved by `beginOp` / `finish*` / `endOpLocked` |
| `Transfer/LayerStaging.lean` | `StagingLayerManager` FIFO free queue, active leases, idempotent re-acquire, `Shutdown`, `ReleaseAll`, `ResolveNumStagingLayers` | `StagingLayerManager.acquire_inv`, `release_inv`, `releaseAll_inv`, `lookup_injective`, `lookup_lt`, `acquire_idempotent`, `shutdown_cancels` |
| `PrefillDecode/Receive.lean` | one `TransferReceiveSession` + manager poll/publication | `Recv.reachable_safe`, `Recv.reachable_can_settle` |
| `PrefillDecode/ReceivePoll.lean` | the poll-side `IsReadyToComplete` finish, with (`stepM true`, shipping) and without (`stepM false`) it; `metrics` ghost | `Recv.reachable_callbackFinishes`, `Recv.pollReady_window`, `Recv.noPoll_safe`, `Recv.noPoll_metrics_on_success`, `Recv.noPoll_zero_layers_never_succeeds` |
| `PrefillDecode/Send.lean` | one `TransferSendSession`: pull claim, `StartPush`, D2H loop, H2H chain | `Send.reachable_safe` (`PullClaimed`), `Send.reachable_can_settle` |
| `PrefillDecode/Pipeline.lean` | single request: handshake rendezvous + five layer-indexed memories, reclaim, reseat, handoff | `Pipeline.reachable_safe`, `Pipeline.reachable_unregistered_safe`, `Pipeline.attention_safe`, `Pipeline.reachable_can_settle`, `Pipeline.handedOff_quiet`, `Pipeline.inv_can_handoff` |
| `PrefillDecode/LayerStaging.lean` | bounded host layer staging (`num_staging_layers`): `BoundedPipeline` over `numSendSlots` / `numRecvSlots` host buffers, unlocked `AcquireStagingSlot` gaps, 4 paired GTests, 3 mutants, branch coverage | `LayerStaging.reachable_safe`, `reachable_unregistered_safe`, `sendLookupStagingSlot_injective`, `recvLookupStagingSlot_injective`, `reachable_can_settle`, `no_slots_cannot_publish_ok`, `exists_complete_trace` |
| `PrefillDecode/MultiRequest.lean` | `multiSys`: concurrent/overlapped requests, read- and write-after-release checks (`wroteReleased`) | `Pipeline.system_data_correct`, `Pipeline.system_attention_safe`, `Pipeline.system_progress` |
| `PrefillDecode/PeerIsolation.lean` | one consumer, `Peer.sick` / `Peer.healthy` producers, `StagingBlockAllocator` slots, `push_pool_` (`tcpBlocking` vs `grpcAsync`) | `PeerIsolation.reachable_safe`, `PeerIsolation.reachable_inv`, `tcp_healthy_blocked_when_pool_full`, `grpc_healthy_can_complete`, `trace_sick_peer_starves_staging_slots` |
| `PrefillDecode/UuidTable.lean` | the manager's `sessions_` table (`SessionEntry{session, req_id, role}` holding a `TransferReceiveSession` or `TransferSendSession` under one uuid key), drain-before-reuse, `req_id` idempotency (the entry's `req_id`), `RetireSettledSessionLocked` and the `CompleteReadWithDetails` sweep | `UuidTable.reachable_inv`, `active_recv_preserved`, `active_send_preserved` |
| `PrefillDecode/BlockOrdering.lean` | within-layer blocks: `PopulateRegisteredBlocks`, `ValidateRequestedBlocksLocked`, `BuildCoalescedCopySpec`, `BuildLoadCopyPlan` (`remote_order` / `local_order`), custom host staging, `BlockPipeline` | `execCoalesced_buildCoalescedSpec`, `landStage_get_requested`, `h2dStage_get_requested`, `BlockPipeline.step_pipe`, `BlockPipeline.reachable_safe` |
| `PrefillDecode/PipelineChecks.lean` | `Pipeline` / `multiSys` traces, `#guard` searches, mutants | `Pipeline.trace_normal`, `trace_layers_out_of_order`, `trace_pull_ahead_of_registration`, `trace_multi_request`, `trace_overlapped_requests` |
| `PrefillDecode/Transport.lean` | `BlockTransport` receiver-side stream accounting (the per-uuid `BlockTransportServerPushSession`: `layer_progress_`, chunk-count and sender-declared contracts, once-latch, retirement) feeding the receiver's block and layer counters; discharges `Receive` A1 and the A4 coarsening under one explicit assumption (honest senders) and shows what one extra stream does without it | `Transport.reachable_safe`, `trace_dup_chunk_publishes_missing_layer`, `trace_dup_after_retirement`, `trace_dup_declared_rejected`, bounded `searchHardened`; three `block_transport{,_session}_test` cases replayed (`Transport.paired`) and the two-stream chunk-count retirement as a model-only trace (`Transport.modelOnly`) |
| `Transfer/Caller.lean` | the engine above `poll_stats()` shared by both transfer paths (tpu-inference `tpu_raiden_connector.py` and vllm-torchtpu `tpu_connector.py` on vLLM): intra-worker NUMA sub-manager aggregation in `NumaAwareKVCacheManager::CompleteReadRaw` (`NumaBarrier.lean`: `NumaPolicy.eagerFailSet` vs `NumaPolicy.settledCounts` across `req_id` reuse), the worker-side connector as a `Connector` (`connectorTwoChannel` and three counterfactual mutants `connectorDropFailed`, `connectorNaive`, `connectorLoadErrorOnly`), `KVOutputAggregator` multi-worker counting over both `AggChannel.latchedReq` (`_failed_recving_pending`) and `AggChannel.eagerBlock` (`invalid_block_ids`) (`MultiWorker.lean`), and the scheduler's block lifecycle under both `kv_load_failure_policy` values; the other direction of `Pipeline` A4 (`Contract`, `mwEarlyFree = false`, `numaEarlyFree = false`) | `Caller.contract_safe`, `Caller.mw_contract_safe`, `Caller.numa_settledCounts_safe`, `Caller.numa_settledCounts_maps_clean`, `Caller.numaProcessSettled_expected_numSubs_eq_none`, `twoChannel_contract`, `applyRecv_eager_eq_latched`, `earlyLoadError_fail_eq_finish`, `earlyLoadError_fail_holds_blocks`, `leakP_absorbing`, `leakD_absorbing`, `mwLeakP_absorbing`, `mwLeakD_absorbing`, `trace_twoChannel_*`, `trace_mw_latched_*`, `trace_settledCounts_*`, `trace_eagerFailSet_*`, `trace_dropFailed_*`, `trace_mw_dropFailed_partial_failure_leaks`, `trace_naive_decodes`, `trace_loadErrorOnly_*`, exhaustive `search`, `mwSearch`, and `numaSearch` per configuration |

## Boundaries

The model sits between three boundaries. Each side names the module that owns
it; the arguments are in those modules.

### Subsystem boundary

In scope is the prefill-to-decode ("symmetric") transfer: producer
registration (`NotifyForRead` / `register_read`), consumer pull and load
(`StartRead` / `start_read`), the D2H → H2H → H2D pipeline in
`TransferSendSession` / `TransferReceiveSession`, and outcome polling
(`CompleteReadWithDetails` / `poll_stats()`).

Out of scope: pool resharding (`ReshardSendSession` / `ReshardReceiveSession`,
which share the manager's `sessions_` map and poll loop) — see
[reshard.md](reshard.md); and `RaidenController`, `kv_cache_store`, and
`host_offload_backend`.

Host-memory source and destination (`BlockLocation::kHost`, the `source` of
`NotifyForRead` / `TransferSendSession::Create` and the `destination` of
`StartRead` / `TransferReceiveSession::Create`) are a documented boundary: the
models take the default `BlockLocation::kDevice` on both sides. On a `kHost`
send the registered ids are host-pool blocks and `StartPush` skips staging and
the D2H loop (every `d2h_layer_futures_` entry is seeded already OK and
`SendNextLayer(0)` runs at once), so what remains is the modelled H2H chain and
settle protocol with no D2H op — `Send.lean` §"Host-resident source" shows the
host send is the device-source model after the prefix `beginPull, start,
(d2hBegin, d2hIssue true, d2hReady, d2hEnd)^numLayers`
(`Send.trace_host_source_prefix`), so every `Send` property carries over
(`TransferSendSessionTest.HostSource*` and two `HostMemoryTransferTest`s are
replayed from that state); on a `kHost` receive `StartRead` names
`local_block_ids` as the host blocks (`local_host_block_ids`, no staging lease)
and `OnDataReceived` routes a layer completion to `SettleHostLayer` instead of
`ExecuteLayerH2d`, which counts `num_completed_layers_` and, on the last layer,
closes the network phase and finishes through
`RecordNetworkCompleteLocked(/*all_complete=*/true)` — the only caller of that
function's finish arm, inside the push lease that delivered the layer — so no
H2D op is ever taken and `decodeHbm` is never written (the host blocks are the
final destination; `Pipeline.lean` §"Host-memory source and destination").
`in_flight_` is then held only by the handshake and incoming pushes, and
`Transfer/Session.lean`'s settle protocol applies unchanged. `CheckHostMemoryTransferSupported` admits either
only on a manager with one host buffer per layer (no `num_staging_layers`
bound) whose host pool nothing stages through, so the bounded-staging models
(`LayerStaging`) never meet a `kHost` transfer.

### Engine boundary (above `poll_stats()`)

Modelled: the API the engine sees (`NotifyForRead`, `StartRead`,
`CompleteReadWithDetails` → `done_sending` / `done_recving` / `failed_recving`)
and both directions of the contract across it. What tpu-sync owes the engine
is proved as HBM and staging safety (§What is proved); when the engine may
recycle is `MultiRequest.lean` (`.recyclePrefill` only after the send is
published, `.nextRequest` only after the receive is; `wroteReleased` catches a
premature recycle). What the engine owes a publication is `Caller.lean`, for
the production caller pair tpu-inference `tpu_raiden_connector.py` on vLLM
(both for a single worker and across workers aggregated by `KVOutputAggregator`
over `AggChannel.latchedReq` and `AggChannel.eagerBlock` in
`Caller/MultiWorker.lean`): a two-channel connector (`connectorTwoChannel`) that
forwards every outcome and reports a failed receive on both the completion and
load-failure channels never frees HBM while a worker on that node is still in
flight (`mwEarlyFree = false`), leaks no held block, and never decodes on
unwritten KV (`Caller.contract_safe`, `Caller.mw_contract_safe`); dropping
`failed_recving` or omitting either channel on failure violates safety
(`trace_dropFailed_*`, `trace_mw_dropFailed_partial_failure_leaks`,
`trace_naive_decodes`, `trace_loadErrorOnly_*`). Below the connector, a worker
built with `ENABLE_MULTI_NUMA=1` runs one `KVCacheManagerWithTransfer`
per NUMA node under `NumaAwareKVCacheManager`, whose `CompleteReadRaw` folds the
sub-managers' reports into one worker-level publication: `process_completion`
counts `done_sending_counts_`, `done_recving_counts_` and
`failed_recving_counts_` per `req_id`, emits nothing until the three sum to
`req_expected_counts_` (or the number of sub-managers), publishes
`failed_recving` if any sub-manager failed, and erases all four map entries
(`Caller/NumaBarrier.lean`, `NumaPolicy.settledCounts`:
`Caller.numa_settledCounts_safe`, `Caller.numa_settledCounts_maps_clean`).

Not modelled: the Python orchestration itself (bootstrap and proxy servers,
scheduler queues, external block allocators, engine-side timeouts). An engine
that frees HBM before `poll_stats()` publishes violates `Pipeline` A4, which
`wroteReleased` makes visible. tpu-sync has no caller-invoked cancel on this
path: a session ends only on its own deadline, a transport error, manager
shutdown or plan unregister. `Caller.lean` leaves out (its B2–B3) partial-prefix
load failures and preemption, prefix caching and chunked prefill.

### Transport boundary (below the session callbacks)

Modelled: the session–transport protocol behind the `TransferSession`
interface (`tpu_sync/transport/transfer_session.h`), which the transport reaches
through `KVCacheManagerBase::GetSession(uuid)` (one manager hook,
`hooks.get_session`, answered from `KVCacheManagerWithTransfer::sessions_`) — the
incoming-push op (`BeginIncomingPush` = `GetSession` + `TryBeginOp`,
`EndIncomingPush` = `Finish(status)` on error then `EndOp`, both free functions
in `bts.cc` called from `StartStream`) that pins staging across session expiry
(a send session's `TryBeginOp` returns `false`, so a push aimed at it is
`Cancelled`), bounded host layer staging (`ResolveStagingSlot` in
`GetBlockChunks` and in `ValidateChunks` via `GetBlockArrayHostSpan` →
`ResolveBlockArrayHostLayer` → `TransferReceiveSession::AcquireStagingSlot` /
`TransferSendSession::LookupStagingSlot`, plus `StagingLayerManager` in
`PrefillDecode/LayerStaging.lean` and `Transfer/LayerStaging.lean`), the two
forms of `OnDataReceived` — a layer completion
(`KVCacheManagerBase::OnLayerReceived` → `ExecuteLayerH2d`) before the block
report (`KVCacheManagerBase::OnBlockShardsReceived` → `RecordBlockShards`) on the
stream that completes a layer (Receive A4), the within-layer block plans
(`BlockOrdering.lean`), the control-plane worker pool (`PeerIsolation.lean`),
and `BlockTransport`'s receiver-side stream accounting (`Transport.lean`: the
per-uuid `BlockTransportServerPushSession` that
`BlockTransport::HandleIncomingPush` delegates each stream to and deletes once
`IsDone()`; it discharges Receive A1 and the coarsening behind A4 under one
named assumption, honest senders). `ExecuteLayerH2d` also closes the network
phase itself: once every layer's copy has been issued (`dispatched_layers_`
reaches `num_layers()` on a receive that is neither done nor draining) it sets
`network_completed_`, so `IsReadyToComplete` needs no transport ordering to
become true through that setter (`Recv.netIssued`); A4 backs only the
block-accounting setter in `RecordBlockShardsReceivedLocked`.
The per-layer D2H readiness a `BlockTransportServerPullSession::TriggerNextSendStep`
waits on before serving a pulled block is `GetDataReadyFuture(l)` on the session
`delegate_->GetSession(uuid_)` returns (an unknown or `Done()` session is ready
at once). Pool completions take the same `OnDataReceived` entry: on a
plan-declared push `CompleteIncomingPush` calls `session->OnDataReceived(l, {}, {})`
on the session `BeginIncomingPush` returned, which a `TransferReceiveSession`
armed on a pool plan refuses with `FailedPrecondition`
(`PoolReshardSessionLookupTest.PoolCompletionOnLegacyArmedReceiverFailsWithoutH2d`).

Not modelled: raw socket I/O and wire framing (`ReadExact` / `WriteExact` and
their timeouts, headers, length checks, connection pooling, `memcpy`),
collapsed into the atomic `land l`, `h2hDone l ok` and `cancel` + `pushEnd`;
and the opt-in Peregrine data plane (`BlockTransport::AsyncPush` when
`TPU_RAIDEN_ENABLE_PEREGRINE` selects `TransportBackend::kPeregrine`, default
off, and the receive path `BlockTransport::ResolveRecvBuffer` /
`BlockTransport::OnRecvComplete` wired via
`PeregrineTransportAdapter::RecvHooks` →
`BlockTransportServerPushSession::OnPeregrinePostComplete`, `is_peregrine`,
which reaches the session through `BeginIncomingPush` / `EndIncomingPush` held
across a `kBlockPushExplicit` Post as a `PostLease`). Read
`block_transport.cc` and `block_transport_session.cc` directly for wire
behaviour.

## Assumptions and how each is discharged

Every module numbers its assumptions (`Receive` A1–A4, `Send` A1–A8, `Pipeline`
A1–A4, `LayerStaging` LS1–LS2, `Transport` A1–A5, `Caller` B1–B3); the full statements and arguments
are in the module docstrings. This table is the index: what each one says in a
line, and whether it is discharged by another Lean module, enforced by C++
control flow, or an external contract.

| Assumption | One-line statement | Status |
|---|---|---|
| Pipeline A4 — engine contract | Decode reads destination HBM only after `done_recving`; prefill frees source HBM only after every registered transfer settled. | External contract; encoded as the guards of `.recyclePrefill` / `.nextRequest` in `MultiRequest.lean`. The other direction is `Caller.lean`. |
| Receive A4 / Pipeline A3 — transport ordering, one sender per layer | For the stream that completes a layer, the layer completion (`OnLayerReceived` → `OnDataReceived` → `ExecuteLayerH2d`) runs before the block report (`OnBlockShardsReceived` → `OnDataReceived` → `RecordBlockShards`) on the same thread; a layer's blocks are accounted once its copy is issued. | Ordering: C++ control flow in `BlockTransportServerPushSession::StartStream` (`CompleteIncomingPush` before `delegate_->OnBlockShardsReceived`). Coarsening: discharged by `Transport.NetworkSound` under `Transport` A4 (honest senders); mutant `Recv.netAccountUnordered` shows what breaks without it. Needed only for the block-accounting setter of `network_completed_`: the setter in `ExecuteLayerH2d` (`dispatched_layers_.size() == num_layers()`, `Recv.netIssued`) is this thread's own, so readiness through it needs no ordering. |
| Receive A1 — one dispatch per layer | `CompleteIncomingPush` fires `OnLayerReceived` once per layer (`on_layer_received_called`), marks the push session `done_` on `all_layers_called`, and `BlockTransport::HandleIncomingPush` drops it (`DeletePushSession(session)`), so a later push to the uuid gets a fresh table from `GetOrCreatePushSession`. | Discharged by `Transport.OnceDispatched` under `Transport` A2 (a layer's contract is latched by its first stream), A4 (honest senders), A5 (single transfer generation per `uuid`) and `Cfg.WF.chunkSingle`; `trace_dup_after_retirement` and `trace_chunk_two_senders` are the exceptions. |
| Receive A2 — registration | External `ReleaseStaging()` runs only on registration failure, before the plan is published. | C++ init discipline; the tables are `UuidTable.lean`. |
| Receive A3 / Send A4 — no double end | Each `in_flight_` op ends at most once. | C++ callback and RAII discipline. |
| Send A1 — at-most-once `StartPush` | After `NotifyForRead` registration and the `pull_started_` claim in `ValidateAndBeginPull`. | Discharged: `Send.PullClaimed`, `Pipeline.HandshakeSafe`, `BlockOrdering.validateRequestedBlocks_iff`. |
| Send A2, A6 — sequential D2H loop, `SendNextLayer(0)` fold | One thread creates every layer's D2H future, calls `SendNextLayer(0)`, then issues the copies in layer order. | C++ control flow (`TransferSendSession::StartPush`). |
| Send A3 — layers interchangeable | `Send.lean` counts copies and pushes without layer indices. | Discharged: `Pipeline.lean` indexes every memory event by layer. |
| Send A5 — no consumer Ack | `SendAck` has no non-test caller, so `HandleAck → AckSend → Finish()` is excluded. | Dead path. |
| Send A7 — connection-release window | Under `TPU_RAIDEN_DATA_CONN_REUSE=per_transfer` the last `TransferSendSession::EndOp` drops `mu_` before `EndSendOpLocked`; nothing modelled changes in the window. | Soundness argument in `Send.lean`. |
| Send A8 — no incoming push on a send | `TransferSendSession::TryBeginOp` returns `false` unconditionally (`BeginIncomingPush` refuses with `CancelledError`), and `TransferSendSession::OnDataReceived` returns `FailedPreconditionError`. | Enforced by C++ (`TransferSendSession`). |
| Pipeline A1 — whole-layer cells | A layer moves as one unit. | Discharged: `BlockOrdering.BlockPipeline.step_pipe` (lockstep simulation over blocks). |
| Pipeline A2 — delivery after the push callback | The model lands a layer at or after its push callback; C++ lands it before the ack. Sound because the push pins staging. | Soundness argument in `Pipeline.lean`. |
| LayerStaging LS1–LS2 — pre-land consumer `AcquireStagingSlot` touches; `Shutdown` before `Release` on error callbacks | Under `Pipeline` A3, `GetBlockChunks(l)` and `ValidateChunks` (`GetBlockArrayHostSpan` → `ResolveBlockArrayHostLayer`) run only before `CompleteIncomingPush` marks `l` landed (possibly repeatedly across chunks/shards); on callback error `FinishLocked` sets `shutdown_ = true` monotonically before `Release(l)` wakes waiters. | LS1 follows from `Pipeline` A3 (`StartStream` payload loop precedes `CompleteIncomingPush`); LS2 enforced by C++ call order in `TransferSendSession` and `TransferReceiveSession`. |
| Transport A1–A5 — one lock, contract latched by the first stream, uniform declaration, honest senders, single transfer generation per `uuid` | `Transport.lean` §Assumptions. | Stated there: `ExpectedPushSenders` enters `sender_streams` only on non-pool receiver `RegisterActivePlan` plans (`pool_groups_size() == 0` with `shard_push_schedules_size() > 0`); A2 holds whenever senders are dispatched after `RegisterActivePlan` returns (as on in-repo controller hops that arm receivers before dispatching senders) and is assumed only against concurrent or pre-registration pushes; A3 is bypassed on pool reshard (which checks unique contiguous `transfer_rank`s) and store transfers, and is unchecked on legacy non-pool `RegisterActivePlan` plans; A4 is the one the C++ does not enforce and the traces drop; A5 assumes a fresh `uuid` per transfer generation (`init` starts with `entry = none` and no concurrent unlocked `ForgetPushProgress(uuid)` runs from a prior retired plan or session on the same `uuid`). |
| Caller B1–B3 — multi-worker `KVOutputAggregator` threshold (`expectedP = 2`, `expectedD = 2`) with one settled outcome per worker (`ENABLE_MULTI_NUMA=0`), whole-transfer failure, no preemption/prefix caching/chunked prefill | `Caller.lean` §Assumptions. | B1's `KVOutputAggregator` combining step is modelled directly for both `AggChannel.latchedReq` (`_failed_recving_pending`) and `AggChannel.eagerBlock` (`invalid_block_ids`) in `Caller/MultiWorker.lean` (`mw_contract_safe`, `applyRecv_eager_eq_latched`, `applyRecv_staggered_eq_batch`; `trace_mw_overcounted_expected_leaks` shows what breaks when `get_finished_count()` exceeds participating workers), and `Caller/NumaBarrier.lean` models the intra-worker `NumaAwareKVCacheManager::CompleteReadRaw` barrier (`process_completion` over `done_sending_counts_` / `done_recving_counts_` / `failed_recving_counts_`; assuming one report per sub-manager, its N1, and proving `NumaPolicy.settledCounts` aggregates them into one worker-level publication under `ENABLE_MULTI_NUMA=1` and `req_id` reuse); B2 matches single-outcome `CompleteReadWithDetails` publication; B3 does not change which event frees a transfer-held block. |

## Shipping C++ vs. modelled design alternatives

Two modules parameterize both the **shipping C++ behavior** and a
**non-shipping alternative** so both can be compared formally (`stepM` in
`ReceivePoll.lean`, a design alternative; `NumaPolicy` in
`Caller/NumaBarrier.lean`, whose alternative is a mutant that drops the barrier). Every other
module has one shipping `step` (`Backend.tcpBlocking` and `Backend.grpcAsync` in
`PeerIsolation.lean` are both shipping C++ control-plane backends); where a
trace shows what the shipping code leaves open, an alternative `step` at the end
of the module or in `Traces.lean` records the candidate change —
`PeerIsolation.stepPerPeerQuota` (a per-peer staging cap on `StartRead` for
`DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`) and
`Transport.stepHardened` (chunk-count over-count rejection and a session-side
per-layer once-latch) — without parameterizing the main model or its inductive
theorems.

| Module | Parameter | Shipping C++ behavior | Modelled alternative (not in shipping C++) |
|---|---|---|---|
| `PrefillDecode/ReceivePoll.lean` | `stepM (poll : Bool)` | **`stepM true`**: the poll in `CompleteReadWithDetails` finishes a session whose `IsReadyToComplete()` holds. Safe, but when it fires between the last future becoming ready and the last callback running, that callback sees `draining_` and skips the end-of-transfer metrics (`trace_poll_skips_metrics`). | **`stepM false`**: only the last H2D callback finishes a session with layers (a zero-layer receive would have to finish at creation, as a zero-layer send does). Keeps every safety and settlement property (`noPoll_safe`, `noPoll_can_settle`) and guarantees metrics on success (`noPoll_metrics_on_success`). |
| `Caller/NumaBarrier.lean` | `NumaPolicy` | **`settledCounts`**: `NumaAwareKVCacheManager::CompleteReadRaw`'s `process_completion` counts `done_sending_counts_`, `done_recving_counts_` and `failed_recving_counts_` per `req_id`, withholds emission until the three sum to `req_expected_counts_` (or the number of sub-managers), publishes `failed_recving` if any sub-manager failed and `done_recving` / `done_sending` only when every one reported that outcome, and erases all four per-request map entries (`numa_settledCounts_safe`, `numa_settledCounts_maps_clean`, `numaProcessSettled_expected_numSubs_eq_none`; `KVCacheManagerWrapperTest.FailureWaitsForSiblingSubManagersBeforeEmittingFailedRecving`, `FailureWhenAllSubManagersFailEmitsFailedRecvingOnce`, `RecvFirstThenFailureWaitsForSubManagersAndEmitsFailure`, `SendFailureWaitsForSiblingSubManagersBeforeEmittingFailedRecving`, `SingleSubManagerFailureEmitsImmediatelyAndCleansUp`). | **`eagerFailSet`** (mutant): emits `failed_recving` on the first failing sub-manager through a `failed_recving_set_` that is cleared only when `done_recving_counts_` reaches `expected`, freeing HBM while a sibling sub-manager's DMA is still in flight at `num_subs = 2` (`trace_eagerFailSet_recv_early_free`, `trace_eagerFailSet_send_early_free`) and leaving entries behind that poison a later transfer reusing the `req_id` (`trace_eagerFailSet_single_sub_reuse_leaks`, `trace_eagerFailSet_partial_fail_desync_premature_doneRecving`; vLLM randomizes request ids unless `VLLM_DISABLE_REQUEST_ID_RANDOMIZATION=1`, so there the entries grow without bound instead). |

## Counterfactual mutants

Each mutant removes a specific C++ guard or ordering constraint and yields a
`.counterexample` (or refutation trace) in `TpuSyncVerify`:

| Mutant | C++ guard / invariant removed | Property violated |
|---|---|---|
| `Recv.cancelEager`, `Send.cancelEager` | `FinishLocked` / `EndRecvOpLocked` / `EndSendOpLocked` settle only when `in_flight_ == 0`, and `CompleteReadWithDetails` publishes only once `Done()` | Settle safety (`done → inFlight = 0`), no retired callback (`NoRetiredCallback`) / drained before settle (`Drained`), staging & HBM safety |
| `Recv.netAccountUnordered` | the layer completion (`ExecuteLayerH2d`) runs before the block report (`RecordBlockShards`) on the same thread in `BlockTransportServerPushSession::StartStream` (Receive A4) | Readiness soundness (`IsReadyToComplete → ready = numLayers`) |
| `Send.trySendNextUncounted` (`Send.sendNextUncounted` / `Send.startUncounted`) | `++in_flight_` op taken by `SendNextLayer`, called both from `StartPush` before its D2H loop (`SendNextLayer(0)`, folded into `start`) and from the H2H pool task (`SendNextLayer(l+1)`) | No underflow (`NoUnderflow`) / drained before settle (`Drained`: the pool task still ends the uncounted op via `absl::Cleanup end_op`, so `inFlight` hits 0 early) |
| `Send.stepWithoutFailUnissued` (`Send.trace_without_fail_unissued_leaks`) | `absl::Cleanup fail_unissued_layers` in `StartPush` resolves unissued layers' `d2h_promises` when the D2H loop exits early while `draining_` | No op leak (`NoOpLeak`: an armed `SendNextLayer` callback on an unissued layer hangs with `in_flight_ > 0` forever) |
| `Recv.h2dIssueLeak` | `EndRecvOpLocked()` on the `if (done_ \|\| draining_)` early return under the second lock in `ExecuteLayerH2d` | No op leak (`NoOpLeak`; leaked `in_flight_` prevents `done_` forever) |
| `Send.sendNextUnbounded` | `l >= base_->num_layers()` and `l >= d2h_layer_futures_.size()` bounds checks in `SendNextLayer` | No op leak (`NoOpLeak`; `SendNextLayer(numLayers)` takes an op whose future never exists) |
| `Pipeline.dispatchEarly` (`trace_dispatch_early`) | `ExecuteLayerH2d(l)` only dispatched after layer `l` landed in `CompleteIncomingPush` | Publication correctness (`decodeHbm` receives `.junk`) |
| `Pipeline.h2dReadyByRank` (`trace_h2d_by_rank`) | H2D copy for layer `l` reads staging slot `l` rather than a completion-counter index | Publication correctness (out-of-order landing produces `[kv 1, junk]`) |
| `Pipeline.reseatAtFinish` (`trace_reseat_at_finish`) | Prefill staging released only when settling (`done_ = true`, `in_flight_ == 0`), not immediately on `FinishLocked` (`draining_ = true`) | Publication correctness / staging safety |
| `LayerStaging.sysEarlySendRelease` (`mutant_early_send_release_corrupts_hbm`) | Producer host slot released inside `H2hWriteDirectAsync` completion callback (`h2hDone`), not at `H2hWriteDirectAsync` dispatch (`sendH2hIssue`) | Publication correctness under bounded staging (`decodeHbmB` receives `[.kv 1, .kv 1]` when layer 1's D2H overwrites slot 0 mid-push) |
| `LayerStaging.sysEarlyRecvRelease` (`mutant_early_recv_release_corrupts_hbm`) | Consumer host slot released inside `ExecuteLayerH2d` `future.OnReady` (`h2dDone`), not immediately after `H2dSyncDispatch` (`h2dIssue`) | Publication correctness under bounded staging (`decodeHbmB` receives `[.kv 1, .kv 1]` when layer 1's `land` overwrites slot 0 mid-H2D) |
| `LayerStaging.sysNoReleaseAll` (`mutant_missing_release_all_leaks_slot`) | `ReleaseStagingLocked()` / `ReleaseStagingBlocksLocked()` call `staging_layer_manager_.ReleaseAll()` when `done_` flips `false → true` | Wholesale slot cleanup (`SettledSlotsFree`: an aborted incoming push after `GetBlockChunks` leased slot 0 settles with `leases = [(0, 0)]` leaked) |
| `UuidTable.stepOverwriteDraining` | `EmplaceRecvSessionLocked` retires an incumbent only once `RetireSettledSessionLocked` finds it `Done()` and rejects a duplicate UUID while an expired incumbent is still draining (`draining = true, done = false`) rather than overwriting it | Staging slot conservation (`freeSlots + activeStaging = numSlots`) |
| `PeerIsolation.stepReleaseOnCancel` | `TransferReceiveSession` releases its `StagingBlockAllocator` slot only on `Lifecycle.settleLocked` (`in_flight_ == 0`), not on `.cancel` while the pull handshake (`inFlight = 1`) is still outstanding | Staging slot conservation (`PeerIsolation.Safe`: `freeSlots + activeStaging = numSlots`) |
| `PeerIsolation.stepPerPeerQuota` (candidate fix, not a mutant) | adds a per-peer cap `peerStaging peer < maxPerPeer` on `StartRead` staging admission (`DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`) | none within the search depth (`= .outOfFuel`), where shipping `step` hits `starvesFirstHealthy` at depth 3 (`trace_per_peer_quota_admits_healthy`) |
| `BlockOrdering.trace_mutant_mismatched_transport_order` (`buildBuggyCopyPlan`) | `BuildLoadCopyPlan` applies `remote_order` to `producer_remote_block_ids` **and** to `transport_host_block_ids`; the mutant keeps `h2hPairs` in the unsorted request order | Within-layer block publication correctness: on `test_host_reordering` (`remote = [1, 0]`, `local = [0, 1]`) `h2dStage` yields `[.kv 0 0, .kv 0 1]` instead of the correct `[.kv 0 1, .kv 0 0]` |
| `Transport` with `Cfg.honest = false` (`trace_dup_chunk_publishes_missing_layer`, `trace_dup_after_retirement`) | `Transport` A4, honest senders: the chunk-count contract has no over-count rejection, every accepted stream is counted, and retirement (`if (all_layers_called)` in `CompleteIncomingPush` sets the push session's `done_`; `GetOrCreatePushSession` then seats a fresh `BlockTransportServerPushSession` for the uuid's next stream while the receive is live) hands later streams an empty table | `NetworkSound` / `CompleteOnSuccess`: success published with a layer never copied (chunk-count, before retirement); `OnceDispatched`: a layer copied twice after retirement on either contract (`trace_dup_copy_fails_late`: a failing duplicate fails the receive) |
| `Transport.stepHardened` (candidate fix, not a mutant) | adds the missing over-count rejection to the chunk-count contract and a per-layer once-latch in `ExecuteLayerH2d` | none within the search depth on the dishonest instances (`searchHardened … = .outOfFuel`); honest traces unchanged (`trace_hardened_honest`) |
| `Caller.connectorDropFailed`, `Caller.connectorNaive`, `Caller.connectorLoadErrorOnly` | `connectorTwoChannel` (`TPUConnectorWorker.get_transfer_results` / `TPURaidenConnectorWorker.get_finished`) forwards `failed_recving` on both P (`finished_sending`) and D (`finished_recving` + load-failure channel) | `connectorDropFailed` leaks held blocks on both nodes (`trace_dropFailed_*`, `trace_mw_dropFailed_partial_failure_leaks`); `connectorNaive` (including `get_finished()` without `get_block_ids_with_load_errors`) decodes on unwritten KV (`trace_naive_decodes`); `connectorLoadErrorOnly` leaks D blocks (`trace_loadErrorOnly_*`, `trace_mw_latched_loadErrorOnly_never_emits`) |

## Branch coverage by the replayed tests

How much of each model's `step` the upstream tests exercise
([conventions.md](../conventions.md) §Coverage; one `#guard` per model pins
the numbers). A branch is a leaf of an event's decision tree with the step's
effect on the lifecycle; the denominator is the exhaustive reachable set of
the small instances; the numerator is the branches along traces paired with
an upstream test. Each module's `Coverage.lean` tabulates its gaps with a
schedule reaching each and a class: **test** (a harness can drive it — a
missing upstream test), **window** (an interleaving no harness hook reaches),
**ordering** (left open by the model), or a stub the harness lacks.

| Model | Instances | Branches | Reached by paired tests | Gaps | Of which |
|---|---|---|---|---|---|
| `Receive` | 1–2 layers, push and `StartRead` | 35 (+2 unreachable leaves: the retired-callback assertion, and the `FinishLocked()` arm of `RecordNetworkCompleteLocked`, dead on a device-destination receive and live only through `SettleHostLayer` on a `BlockLocation::kHost` one) | 24 (32 tests) | 11 | 4 test, 5 window, 2 ordering |
| `Send` | 0–2 layers | 40 (every leaf live) | 31 (40 tests, including the `BlockLocation::kHost` cases `TransferSendSessionTest.HostSource*` and two `HostMemoryTransferTest`s replayed after the host-source prefix; 12 more tests not replayable here: external `Finish(OkStatus())`, pulls rejected before the claim, and the 2 bounded-layer-staging tests replayed in `LayerStaging`) | 9 | 2 test, 5 window, 2 ordering |
| `Pipeline` | 1 layer, registered and unregistered (two paired two-layer rows reach 3 branches outside it) | 72; every memory move writes the right layer's KV | 25 (13 end-to-end and control-plane tests) | 47 | 3 environment (`reclaim`, reseats), 24 covered by session unit tests, 20 in the session gap tables (9 `Send`, 11 `Receive`), none unaccounted |
| `LayerStaging` | 1 layer, registered/unregistered 1-slot and zero-slot bounds (9 paired 3-/4-layer traces reach 7 multi-layer branches outside it) | 93; every memory move writes `.kvRight` and `.slotFault` is unreachable | 39 (46 along `paired`; all 4 bounded-staging GTests — `{Recv,Send}LifecycleTest.BoundedLayerStagingFailureModesSettleAndReleaseStagingBlock` and `{Recv,Send}LifecycleTest.StagingLayerManagerCyclesHostLayerBuffers` — and their 7 failure subcases) | 54 | 5 environment/handshake, 18 covered by session unit tests, 19 in session gap tables, 6 zero-slot defense-in-depth, 6 lock-gap windows (`expectedStagingWindows`), none unaccounted |
| `MultiRequest` | — (unbounded; new leaves only) | 3 new: `recyclePrefill`, `nextRequest`, and the write-after-release corruption arm, dead by `not_isRecycleEv_and_wroteReleased_eq_false` | 0 | 2 | both reached only by the two traces replaying `examples/single_host_disagg/run_all.sh`, a script, not a test: no upstream test overwrites a buffer an earlier request released while that request is still observable |

What the tests miss, in one sentence per model: no upstream test fails an
H2D dispatch while a push lease is open or a consumer-side push mid-copy; on the
sender, no upstream test fails a D2H copy after the send has already expired or fails an H2H push callback as the last op of a live device send; the end-to-end tests
exercise exactly the happy paths and the handshake rejections, every failure or
window branch being accounted for at the session level; no test in the suite
recycles a released buffer under an earlier request.

## C++ branch coverage of the anchored spans

The converse check ([conventions.md](../conventions.md) §Coverage):
`tools/resolve_anchors.py --coverage` intersects `llvm-cov` branch records from
every OSS-buildable CPU unit-test binary with the C++ spans in each module's
source map (the spans overlap where `ExecuteLayerH2d`, `StartStream` and
`CompleteIncomingPush` are cited by both `Receive.lean` and `Pipeline.lean`).
Branches expanded from `RETURN_IF_ERROR` / `ASSIGN_OR_RETURN` are not counted,
so error returns written that way are outside this check. `--coverage -v` lists
every one-sided or unreached branch; across the current CPU test suite they fall
into these groups:

* **Model gaps confirmed in C++:** in `TransferReceiveSession`, `!f.IsReady()`
  in `AllH2dDoneLocked` is never false (`AllH2dDoneLocked` returns `true` only
  with an empty `h2d_futures_`, never after an H2D future has become ready), and
  the second-lock `if (done_ || draining_)` re-check in `ExecuteLayerH2d` is
  never taken; in `TransferSendSession`, the per-layer `if (draining_)` exit in
  `StartPush` is never taken (and `fail_unissued_layers` only runs after an
  error finish where `!status_.ok()`).
* **Proved invariants and dead C++ arms (the dead side is never taken):** in
  `TransferSendSession`, `done_` is never true when `draining_` is false in
  `if (draining_ || done_)` (`FinishLocked`, `AcquireStagingWithRetry`,
  `StartPush`); `!done_` is never false in
  `if (draining_ && in_flight_ == 0 && !done_)` (`EndSendOpLocked`,
  `EndRecvOpLocked`) nor in `TransferReceiveSession::FinishLocked`'s
  `if (in_flight_ == 0 && !done_)`; all three match `Lifecycle.Consistent`.
  `if (self->done_)` in `ExecuteLayerH2d`'s callback (`NoRetiredCallback`) is
  never entered (whereas `RecordNetworkCompleteLocked`'s `FinishLocked()` arm,
  never entered from `RecordBlockShards` on a device destination, is exercised
  on CPU through `SettleHostLayer` in `HostMemoryTransferTest`). In
  `TransferSendSession`, `l >= d2h_layer_futures_.size()` in `SendNextLayer`
  (after `l >= base_->num_layers()`) and
  `d2h_layer_futures_.size() < base_->num_layers()` in `CurrentPhaseLocked` are
  never true because `StartPush` pre-populates every layer's future before
  `SendNextLayer(0)`.
* **Assumed, not proved:** `if (in_flight_ <= 0)` in `EndRecvOpLocked` is never
  entered, consistent with Receive A3 (no double end).
* **The rest:** lock-gap early-drain windows under bounded layer staging
  (`AcquireStagingSlot` / `LookupStagingSlot`, including the nested
  `!status_.ok()` ternaries inside `TransferSendSession`'s untaken
  `done_ || draining_` guards and the bounded-staging arm of
  `ResolveBlockArrayHostLayer`, since the bounded-staging CPU tests stub
  `H2hWriteDirectAsync` rather than running over `BlockTransport`; classified in
  `LayerStaging.expectedStagingWindows`), documented boundaries
  (`AcquireStagingWithRetry`'s non-`ResourceExhausted` and deadline loop exits,
  unused `AckSend`, the opt-in Peregrine `OnPeregrinePostComplete` path), the
  `!Done()` conjunct of the `transfer_plan_->request().pool_groups_size() > 0 && !Done()`
  misuse check in `OnDataReceived`, input-validation and setup guards
  (`InitFromActivePlan`, `NotifyForRead`, `HandlePullStream`), unused
  fault-injection and metrics hooks, and bookkeeping arms the tests drive one
  way only (the `RetireSettledSessionLocked` arms for session kinds a given test
  never registers).

## C++ → Lean routing index

Per C++ symbol: the Lean module that owns it, the model events or definitions
it becomes, and the theorems to open first. The `Lines` column is generated by
`tools/resolve_anchors.py`.

### Receive session and slot manager (`session.h`, `recv.{h,cc}`)

<!-- source-map:begin -->
| File | Symbol / anchor | Lines | Lean module | Model events / definitions | Key theorems / mutants |
|---|---|---|---|---|---|
| `session.h` | `StagingLayerManager` | `:40-75` | `Transfer/LayerStaging.lean`, `PrefillDecode/LayerStaging.lean` | `StagingLayerManager` (`free`, `leases`, `shutdown`, `acquire`, `lookup`, `release`, `releaseAll`, `doShutdown`) | `StagingLayerManager.lookup_injective`, `lookup_lt`, `acquire_idempotent`, `shutdown_cancels`, `LayerStaging.reachable_safe` |
| `tpu_sync/transport/transfer_session.h` | `TransferSession` | `:36-115` | `Transfer/Session.lean` | the interface every session class implements: `Start`, `Done`, `Finish`, `TryBeginOp` / `EndOp` (`Lifecycle.beginOp` / `endOpLocked`), `IsDraining`, `ResolveStagingSlot`, `OnDataReceived`, `GetDataReadyFuture`, `plan()`, `deadline()` (the one timeout the manager's sweep reads for every session kind) | `Lifecycle.Consistent` |
| `recv.cc` | `TransferReceiveSession::TryBeginOp` | `:541-552` | `Transfer/Session.lean`, `PrefillDecode/Receive.lean` | `Lifecycle.beginOp`, `Recv.pushBegin` (`BeginIncomingPush` in `bts.cc`) | `Lifecycle.Consistent`, `Recv.reachable_safe` |
| `recv.cc` | `TransferReceiveSession::EndOp` | `:554-557` | `Transfer/Session.lean`, `PrefillDecode/Receive.lean` | `Recv.pushEnd` (`EndIncomingPush` in `bts.cc`: `Finish(status)` on error, then `EndOp`) | `Recv.StagingIntegrity`, `Recv.trace_push_lease_pins_staging_on_cancel` |
| `recv.h` | `TransferReceiveSession` (`std::vector<int64_t> blocks_received_per_shard_` .. `std::vector<raiden::PjRtCopyFuture> h2d_futures_`) | `:328-356` | `Transfer/Session.lean`, `PrefillDecode/Receive.lean` | `in_flight_`, `draining_`, `done_`, `failed_phase_`, `handshake_pending_`, `blocks_received_per_shard_`, `num_completed_shards_`, `num_completed_layers_`, `network_completed_`, `h2d_futures_` | `Recv.reachable_safe` (`SettleSafe`, `StagingIntegrity`, `SettlesPromptly`) |
| `recv.cc` | `TransferReceiveSession::Create(remote_block_ids)` | `:166-208` | `PrefillDecode/Receive.lean`, `PrefillDecode/BlockOrdering.lean` | `Recv.initLoad` (`destination` is `BlockLocation::kDevice`; `kHost` requires `local_host_block_ids` and is §Boundaries) | `BlockOrdering.landStage_get_requested` |
| `recv.cc` | `TransferReceiveSession::Create(total_blocks)` | `:210-222` | `PrefillDecode/Receive.lean` | `Recv.initPush` | `Recv.reachable_safe` |
| `recv.cc` | `TransferReceiveSession::InitFromActivePlan` | `:276-328` | `PrefillDecode/Receive.lean` | `Recv.initPush` (`handshake_pending_ = false`, `in_flight_ = 0`) | `Recv.reachable_safe`, `Recv.trace_normal`, `Recv.trace_push_lease_pins_staging_on_cancel` |
| `recv.cc` | `TransferReceiveSession::AllocateStagingForLoad` | `:330-379` | `PrefillDecode/BlockOrdering.lean` | custom vs. dynamic host staging | `BlockOrdering.CustomHostStagingCorrect` |
| `recv.cc` | `TransferReceiveSession::BuildLoadCopyPlan` | `:381-449` | `PrefillDecode/BlockOrdering.lean` | `buildCopyPlanFromTriples` (`CopyPlan.remoteSorted`, `.producerRemoteBlocks`, `.transportHostBlocks`, `.localSorted`, `.h2dPairs`) | `BlockOrdering.landStage_get_requested`, `BlockOrdering.h2dStage_get_requested`, mutant `trace_mutant_mismatched_transport_order` |
| `recv.cc` | `TransferReceiveSession::InitFromLoadPlan` | `:451-463` | `PrefillDecode/Receive.lean` | `Recv.initLoad` (`handshake_pending_ = true`, `in_flight_ = 1`) | `Recv.reachable_safe` |
| `recv.cc` | `TransferReceiveSession::ReleaseStagingLocked` | `:465-468` | `Transfer/Session.lean`, `PrefillDecode/LayerStaging.lean` | `Lifecycle.settleLocked`, `LayerStaging.syncMgr` (`releaseAll`) | `Recv.StagingIntegrity`, `LayerStaging.SettledSlotsFree`, mutant `mutant_missing_release_all_leaks_slot` |
| `recv.cc` | `TransferReceiveSession::FinishLocked` | `:475-490` | `Transfer/Session.lean`, `PrefillDecode/Receive.lean`, `PrefillDecode/LayerStaging.lean` | `Lifecycle.finishLocked`, `Recv.failedPhase`, `LayerStaging.syncMgr` (`doShutdown`) | `Recv.reachable_safe`, `LayerStaging.DrainingShutsDown`, `Recv.trace_details_*`, mutant `Recv.cancelEager` |
| `recv.cc` | `TransferReceiveSession::Details` | `:503-519` | `PrefillDecode/Receive.lean` | `TransferDetails` reporting | `Recv.trace_details_*` |
| `recv.cc` | `TransferReceiveSession::CurrentPhaseLocked` | `:521-526` | `PrefillDecode/Receive.lean` | `Recv.Phase`, `Recv.phase` | `Recv.trace_details_*` |
| `recv.cc` | `TransferReceiveSession::EndRecvOpLocked` | `:528-539` | `Transfer/Session.lean`, `PrefillDecode/Receive.lean` | `Lifecycle.endOpLocked` | `Recv.SettleSafe`, `Recv.SettlesPromptly` |
| `recv.cc` | `TransferReceiveSession::AllH2dDoneLocked` | `:559-564` | `PrefillDecode/Receive.lean` | `Recv.allH2dDone` | `Recv.ReadinessSound` |
| `recv.cc` | `TransferReceiveSession::IsReadyToComplete` | `:566-572` | `PrefillDecode/Receive.lean`, `PrefillDecode/ReceivePoll.lean` | `Recv.isReadyToComplete`, `stepM poll` | `Recv.ReadinessSound`, `Recv.pollReady_window`, `Recv.trace_poll_skips_metrics` |
| `recv.cc` | `TransferReceiveSession::RecordBlockShardsReceivedLocked` | `:581-606` | `PrefillDecode/Receive.lean`, `PrefillDecode/Transport.lean` | `Recv.networkCompleted`, `Recv.Ev.netAccount` | `Recv.ReadinessSound`, mutant `Recv.netAccountUnordered` |
| `recv.cc` | `TransferReceiveSession::RecordNetworkCompleteLocked` | `:608-624` | `PrefillDecode/Receive.lean`, `PrefillDecode/ReceivePoll.lean` | `Recv.Ev.netAccount` finish & metrics | `Recv.reachable_callbackFinishes` |
| `recv.cc` | `TransferReceiveSession::Start` | `:626-710` | `PrefillDecode/Receive.lean`, `PrefillDecode/PeerIsolation.lean` | the pull handshake (`SendPullRequest` from `push_pool_`; `on_response` runs `FinishLocked(pull_status)` only `if (!pull_status.ok() && !self->draining_)` — a receive that settled before its pull reply keeps its verdict, and `pullReply false` on a draining session only ends the handshake op — then `EndOp`): `Recv.Ev.pullReply`, `PeerIsolation.Ev.dispatchPull`, `PeerIsolation.Ev.sessStep idx (.pullReply ok)`; a no-op (`pull_manager_ == nullptr`) for push receives | `Recv.trace_deadline_during_handshake`, `Recv.trace_details_rejected_pull`, `PeerIsolation.trace_consumer_gives_up_and_drains` |
| `recv.cc` | `TransferReceiveSession::RecordBlockShards` | `:712-761` | `PrefillDecode/Receive.lean`, `PrefillDecode/ReceivePoll.lean` | `Recv.Ev.netAccount` (the block report of `OnDataReceived`) | `Recv.netAccount_frame`, `Recv.trace_late_net_account_after_retire` |
| `recv.cc` | `TransferReceiveSession::OnDataReceived` | `:804-823` | `PrefillDecode/Receive.lean` | routes a block report (`minor_dimension_indices` non-empty) to `RecordBlockShards` and a layer completion to `ExecuteLayerH2d` (or, on a `BlockLocation::kHost` destination, to `SettleHostLayer`; §Boundaries) | `Recv.ReadinessSound` |
| `recv.cc` | `TransferReceiveSession::SettleHostLayer` | `:825-852` | `Transfer/Session.lean`, `PrefillDecode/Receive.lean` | `BlockLocation::kHost` layer completion (`if (done_ \|\| draining_)`, `num_completed_layers_`, `RecordNetworkCompleteLocked` on the last layer; §Boundaries) | `Lifecycle.Consistent.done_or_draining` |
| `recv.cc` | `TransferReceiveSession::AcquireStagingSlot` | `:763-792` | `PrefillDecode/LayerStaging.lean` | `recvAcquireBegin`, `recvAcquireWait`, `recvAcquireFinish` | `LayerStaging.reachable_safe`, `recvLookupStagingSlot_injective`, `reachable_can_settle`, `trace_recv_cycles_host_layer_buffers`, `trace_recv_fail_*` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` | `:854-986` | `PrefillDecode/Receive.lean`, `PrefillDecode/Pipeline.lean`, `PrefillDecode/LayerStaging.lean` | `h2dBegin`, `h2dIssue` (its third `mu_` scope inserts `dispatched_layers_` and sets `network_completed_` on the last layer: `Recv.netIssued`), `h2dReady`, `h2dDone`, `recvLookupStagingSlot` | `Recv.NoOpLeak`, `Recv.NoRetiredCallback`, `Pipeline.DecodeHbmSafe`, `LayerStaging.PublicationCorrect`, mutants `Recv.h2dIssueLeak`, `mutant_early_recv_release_corrupts_hbm` |
<!-- source-map:end -->

### Send session (`send.{h,cc}`)

<!-- source-map:begin -->
| File | Symbol / anchor | Lines | Lean module | Model events / definitions | Key theorems / mutants |
|---|---|---|---|---|---|
| `send.h` | `TransferSendSession` (`absl::string_view failed_phase_` .. `bool done_`) | `:235-243` | `Transfer/Session.lean`, `PrefillDecode/Send.lean` | `failed_phase_`, `in_flight_`, `draining_`, `done_` | `Send.reachable_safe` (`SettleSafe`, `Drained`, `StagingIntegrity`, `NoUnderflow`) |
| `send.cc` | `TransferSendSession::Create` | `:64-90` | `PrefillDecode/Send.lean` | `Send.init` (`source` is `BlockLocation::kDevice`; `kHost` is §Boundaries) | `Send.reachable_safe` |
| `send.cc` | `TransferSendSession::PopulateRegisteredBlocks` | `:162-178` | `PrefillDecode/BlockOrdering.lean` | `validateRegistration` | `BlockOrdering.validateRegistration_iff` |
| `send.cc` | `TransferSendSession::ValidateRequestedBlocksLocked` | `:180-197` | `PrefillDecode/BlockOrdering.lean` | `validateRequestedBlocks` | `BlockOrdering.validateRequestedBlocks_iff` |
| `send.cc` | `TransferSendSession::ValidateAndBeginPull` | `:199-213` | `PrefillDecode/Send.lean`, `PrefillDecode/Pipeline.lean` | `Send.Ev.beginPull` (`pull_started_` claim) | `Send.PullClaimed`, `Pipeline.HandshakeSafe` |
| `send.cc` | `TransferSendSession::ReleaseStagingBlocksLocked` | `:224-228` | `Transfer/Session.lean`, `PrefillDecode/LayerStaging.lean` | `Lifecycle.settleLocked`, `LayerStaging.syncMgr` (`releaseAll`) | `Send.StagingIntegrity`, `LayerStaging.SettledSlotsFree` |
| `send.cc` | `TransferSendSession::AcquireStagingSlot` | `:235-264` | `PrefillDecode/LayerStaging.lean` | `sendAcquireBegin`, `sendAcquireDone`, `sendD2hBegin` | `LayerStaging.reachable_safe`, `reachable_can_settle`, `trace_send_cycles_host_layer_buffers`, `trace_send_fail_*` |
| `send.cc` | `TransferSendSession::LookupStagingSlot` | `:266-285` | `PrefillDecode/LayerStaging.lean` | `sendLookupStagingSlot` | `LayerStaging.sendLookupStagingSlot_injective`, `NoSlotFault` |
| `send.cc` | `TransferSendSession::FinishLocked` | `:287-302` | `Transfer/Session.lean`, `PrefillDecode/Send.lean`, `PrefillDecode/LayerStaging.lean` | `Lifecycle.finishOnceLocked`, `Send.Ev.cancel`, `LayerStaging.syncMgr` (`doShutdown`) | `Lifecycle.finishOnceLocked_decided`, `LayerStaging.DrainingShutsDown`, `Send.trace_cancel_after_ok_finish`, mutant `Send.cancelEager` |
| `send.cc` | `TransferSendSession::Details` | `:329-345` | `PrefillDecode/Send.lean` | `TransferDetails` reporting | `Send.trace_details_*` |
| `send.cc` | `TransferSendSession::CurrentPhaseLocked` | `:347-357` | `PrefillDecode/Send.lean` | `Send.Phase`, `Send.phase`, `Send.failedPhase` | `Send.trace_details_*` |
| `send.cc` | `TransferSendSession::EndSendOpLocked` | `:359-366` | `Transfer/Session.lean`, `PrefillDecode/Send.lean` | `Lifecycle.endOpLocked` | `Send.SettleSafe`, `Send.Drained` |
| `send.cc` | `TransferSendSession::EndOp` | `:368-395` | `PrefillDecode/Send.lean` | `EndOp` (`TPU_RAIDEN_DATA_CONN_REUSE=per_transfer` connection-close window, Send A7) | `Send.reachable_safe` |
| `send.cc` | `TransferSendSession::GetDataReadyFuture` | `:215-222` | `PrefillDecode/Send.lean` | the per-layer D2H future a `BlockTransportServerPullSession::TriggerNextSendStep` waits on before serving a pulled block (`d2hReady`); on a `BlockLocation::kHost` source `StartPush` seeds every layer's future already OK | `Send.reachable_can_settle` |
| `send.cc` | `TransferSendSession::BuildCoalescedCopySpec` | `:397-426` | `PrefillDecode/BlockOrdering.lean` | `buildCoalescedSpec` | `BlockOrdering.execCoalesced_buildCoalescedSpec` |
| `send.cc` | `TransferSendSession::StartPush` | `:464-635` | `PrefillDecode/Send.lean`, `PrefillDecode/Pipeline.lean`, `PrefillDecode/LayerStaging.lean` | `start` (pre-creates `d2h_promises` and calls `SendNextLayer(0)` before the D2H loop; the `BlockLocation::kHost` arm seeds every layer's future already OK and calls `SendNextLayer(0)` at once, §Boundaries), `sendAcquireBegin`, `sendAcquireDone`, `sendD2hBegin`, `d2hIssue`, `d2hReady`, `d2hEnd`, `fail_unissued_layers` | `Send.reachable_safe`, `Pipeline.PrefillHbmSafe`, `LayerStaging.exists_complete_trace`, mutants `Send.startUncounted`, `Send.stepWithoutFailUnissued` |
| `send.cc` | `TransferSendSession::SendNextLayer` | `:637-736` | `PrefillDecode/Send.lean`, `PrefillDecode/Pipeline.lean`, `PrefillDecode/LayerStaging.lean` | `wake`, `h2hIssue`, `sendNext`, `h2hDone` | `Send.reachable_can_settle`, `LayerStaging.PublicationCorrect`, mutants `Send.sendNextUncounted`, `Send.sendNextUnbounded`, `mutant_early_send_release_corrupts_hbm` |
<!-- source-map:end -->

### Manager (`mgr.cc`, `base.cc`)

<!-- source-map:begin -->
| File | Symbol / anchor | Lines | Lean module | Model events / definitions | Key theorems / mutants |
|---|---|---|---|---|---|
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` | `:304-308` | `PrefillDecode/Receive.lean`, `PrefillDecode/UuidTable.lean` | the one manager hook, `hooks.get_session` | — |
| `mgr.cc` | `KVCacheManagerWithTransfer::GetSession` | `:310-317` | `PrefillDecode/UuidTable.lean`, `PrefillDecode/Receive.lean` | `sessions_.find(uuid)` under `mu_` (the entry's `SessionEntry::session`); `NotFound` for an unknown uuid | `UuidTable.reachable_inv` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RetireSettledSessionLocked` | `:470-529` | `PrefillDecode/UuidTable.lean`, `PrefillDecode/Receive.lean`, `PrefillDecode/Send.lean`, `Transfer/Caller.lean` | `publish`, `sweepSend`, `sweepRecv`: a `Done()` session is published under its entry's `SessionEntry::req_id` into `done_sending_` / `done_recving_` / `failed_recving_` (+ `transfer_details_`) and erased from `sessions_` (the pool-reshard roles are told apart by `SessionEntry::role`); a live one is left in place | `Recv.Publication`, `Send.Publication`, `UuidTable.trace_duplicate_uuid_rejected_until_drained` |
| `base.cc` | `KVCacheManagerBase::GetSession` | `:3071-3077` | `PrefillDecode/Receive.lean` | the transport delegate's session lookup (`transfer_hooks_.get_session`) | — |
| `base.cc` | `KVCacheManagerBase::OnLayerReceived` | `:3335-3344` | `PrefillDecode/Receive.lean`, `PrefillDecode/Pipeline.lean` | `h2dBegin l` (`OnDataReceived(layer_idx, {}, {})`; a uuid with no session succeeds) | `Pipeline.dispatchEarly` |
| `base.cc` | `KVCacheManagerBase::OnBlockShardsReceived` | `:3313-3331` | `PrefillDecode/Receive.lean` | `netAccount` (`OnDataReceived(0, block_ids, shard_ids)`; an empty report is dropped before it can read as a layer completion) | `Recv.ReadinessSound` |
| `bts.cc` | `BlockTransportServerPullSession::TriggerNextSendStep` | `:1055-1151` | `PrefillDecode/Send.lean` | the pull server's per-block readiness wait: `delegate_->GetSession(uuid_)` then `GetDataReadyFuture(l).OnReady(on_ready)` (`d2hReady`); an unknown (`NotFound` / `Unimplemented`), null or `Done()` session is ready at once | — |
| `mgr.cc` | `KVCacheManagerWithTransfer::NotifyForRead` | `:531-602` | `PrefillDecode/UuidTable.lean`, `PrefillDecode/Pipeline.lean`, `PrefillDecode/BlockOrdering.lean` | `UuidTable.Ev.notifyForRead`, `Pipeline.Ev.notifyForRead`, `validateRegistration`; `try_emplace(uuid, SessionEntry{session, req_id, SessionRole::kTransfer})` after `TransferSendSession::Create(..., source)`; `source == BlockLocation::kHost` registers host-pool blocks (§Boundaries) | `UuidTable.active_send_preserved`, `UuidTable.trace_duplicate_send_cannot_replace_live_offer`, `BlockOrdering.validateRegistration_iff` |
| `mgr.cc` | `KVCacheManagerWithTransfer::EmplaceRecvSessionLocked` | `:604-625` | `PrefillDecode/UuidTable.lean` | drain-before-reuse on `sessions_[uuid]` (`RetireSettledSessionLocked` on the incumbent, then `try_emplace` of `SessionEntry{session, req_id, SessionRole::kTransfer}`) | `UuidTable.active_recv_preserved`, `UuidTable.trace_duplicate_uuid_rejected_until_drained`, mutant `UuidTable.stepOverwriteDraining` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RegisterActivePlan` | `:627-706` | `PrefillDecode/UuidTable.lean`, `PrefillDecode/Receive.lean` | `UuidTable.Ev.registerRecv`, Receive A2 | `UuidTable.reachable_inv` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RegisterRecv` | `:708-730` | `PrefillDecode/UuidTable.lean`, `PrefillDecode/Receive.lean` | `UuidTable.Ev.registerRecv` | `UuidTable.reachable_inv` |
| `mgr.cc` | `KVCacheManagerWithTransfer::StartRead(remote_endpoint)` | `:937-1069` | `PrefillDecode/UuidTable.lean`, `PrefillDecode/PeerIsolation.lean`, `PrefillDecode/Receive.lean` | `UuidTable.Ev.startRead`, `PeerIsolation.Ev.startRead peer`, `stepPerPeerQuota`; the duplicate-uuid check compares the incumbent's `SessionEntry::req_id`; `destination == BlockLocation::kHost` names `local_block_ids` as the host blocks (`local_host_block_ids`) and `TransferReceiveSession::Create(..., destination)` lands there (§Boundaries) | `UuidTable.trace_duplicate_receive_different_req_id`, `UuidTable.trace_repeated_receive_same_req_id_idempotent`, `PeerIsolation.trace_sick_peer_starves_staging_slots` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` | `:1071-1134` | `PrefillDecode/Send.lean`, `PrefillDecode/Receive.lean`, `PrefillDecode/Pipeline.lean`, `PrefillDecode/UuidTable.lean`, `Transfer/Caller.lean` | one sweep over `sessions_`: for a non-draining session, `pollReady` (a `TransferReceiveSession` whose `IsReadyToComplete()` holds is `Finish()`ed) else `cancel` (`session->deadline() <= now` → `Finish(DeadlineExceeded("Transfer session timed out"))`, one arm for every session kind), then `RetireSettledSessionLocked` (`publish`, `sweepSend`, `sweepRecv`), `Caller.Ev.pOutcome`, `Caller.Ev.dOutcome` | `Send.trace_deadline_during_copy`, `Recv.trace_deadline_during_copy`, `Pipeline.PrefillHbmSafe`, `Pipeline.DecodeHbmSafe`, `Pipeline.StagingSafe`, `Caller.contract_safe` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadRaw` | `:1137-1142` | `PrefillDecode/Receive.lean` | `CompleteReadRaw` wrapper around `CompleteReadWithDetails` | `Recv.ReadinessSound` |
| `mgr.cc` | `KVCacheManagerWithTransfer::HandlePullStream` | `:1224-1349` | `PrefillDecode/Pipeline.lean`, `PrefillDecode/PipelineChecks.lean`, `PrefillDecode/Send.lean` | `Pipeline.Ev.pullWait`, `Send.Ev.beginPull`, `Send.Ev.cancel` | `Pipeline.HandshakeSafe`, `Pipeline.reachable_unregistered_safe`, `Pipeline.trace_pull_ahead_of_registration`, `Pipeline.trace_unregistered_pull_rejected`, `Send.trace_pull_spawn_failure_cleanup` |
| `base.cc` | `ResolveNumStagingLayers(std::optional<int> num_staging_layers)` | `:717-734` | `Transfer/LayerStaging.lean` | `Transfer.resolveNumStagingLayers` (the `num_staging_layers` constructor parameter: `none` is the full mirror, a value outside `[1, num_layers]` is the `std::invalid_argument` throw) | `Transfer.resolveNumStagingLayers_bounds` |
| `base.cc` | `KVCacheManagerBase::ExpectedPushSenders` | `:3102-3110` | `PrefillDecode/Transport.lean` | sender-declared vs. chunk-count contract | `Transport.trace_chunk_two_senders`, `Transport.trace_dup_declared_rejected` |
| `base.cc` | `KVCacheManagerBase::ResolveBlockArrayHostLayer` | `:2134-2192` | `PrefillDecode/LayerStaging.lean` | resolves `host_layer_idx` via `GetSession(uuid)` → `session->ResolveStagingSlot(block_array_idx)` for `GetBlockArrayHostSpan` | `LayerStaging.reachable_safe`, `NoSlotFault` |
| `base.cc` | `KVCacheManagerBase::GetBlockArrayHostSpan` | `:2194-2256` | `PrefillDecode/LayerStaging.lean` | host buffer span lookup called per chunk by `ValidateChunks` | `LayerStaging.reachable_safe`, `NoSlotFault` |
| `base.cc` | `KVCacheManagerBase::GetBlockChunks` (`size_t host_layer_idx = layer_idx;` .. `base_host_ptr = GetHostPointer(host_layer_idx, shard_idx);`) | `:3480-3491` | `PrefillDecode/LayerStaging.lean` | `session->ResolveStagingSlot(layer_idx)`: `sendLookupStagingSlot`, `recvAcquireBegin` / `recvAcquireWait` / `recvAcquireFinish` | `LayerStaging.reachable_safe`, `NoSlotFault`, `trace_recv_cycles_host_layer_buffers`, `trace_send_cycles_host_layer_buffers` |
| `tpu_sync/frameworks/jax/kv_cache_manager.h` | `NumaAwareKVCacheManager` (`std::map<std::string, int> done_sending_counts_;` .. `std::map<std::string, int> req_expected_counts_;`) | `:298-301` | `Transfer/Caller.lean` | `NumaMgr` (`doneSendingCounts`, `doneRecvingCounts`, `failedRecvingCounts`, `reqExpected`) | `Caller.numa_settledCounts_maps_clean` |
| `tpu_sync/frameworks/jax/kv_cache_manager.cc` | `NumaAwareKVCacheManager::StartRead(remote_descriptors)` | `:598-642` | `Transfer/Caller.lean` | `NumaCfg.setExpected = true`, `numaInitDExpected` | `Caller.numaProcessSettled_expected_numSubs_eq_none`, `Caller.numa_settledCounts_safe` |
| `tpu_sync/frameworks/jax/kv_cache_manager.cc` | `NumaAwareKVCacheManager::StartRead(remote_endpoint)` | `:644-659` | `Transfer/Caller.lean` | `NumaCfg.setExpected = false`, `numaInitDExpected` | `Caller.numaProcessSettled_expected_numSubs_eq_none`, `Caller.numa_settledCounts_safe` |
| `tpu_sync/frameworks/jax/kv_cache_manager.cc` | `NumaAwareKVCacheManager::CompleteReadRaw` | `:662-724` | `Transfer/Caller.lean` | `NumaPolicy.settledCounts` (`process_completion`: emit once `s_count + r_count + f_count >= expected`, erase all four maps), `numaStepSend`, `numaStepRecv`, `NumaEv.pSub`, `NumaEv.dSub`; mutant `NumaPolicy.eagerFailSet` | `Caller.numa_settledCounts_safe`, `Caller.numa_settledCounts_maps_clean`, `Caller.trace_settledCounts_*`, mutants `Caller.trace_eagerFailSet_*` |
<!-- source-map:end -->

### Transport (`bt.{h,cc}`, `bts.{h,cc}`)

<!-- source-map:begin -->
| File | Symbol / anchor | Lines | Lean module | Model events / definitions | Key theorems / mutants |
|---|---|---|---|---|---|
| `bts.h` | `BlockTransportServerPushSession` (`struct LayerProgress` .. `absl::flat_hash_map<int, LayerProgress> layer_progress_ ABSL_GUARDED_BY(mu_);`) | `:158-201` | `PrefillDecode/Transport.lean` | `LayerProgress` / `layer_progress_` / `done_` under the push session's `mu_`, one session per uuid | `Transport.reachable_safe` |
| `bts.cc` | `BeginIncomingPush` | `:242-256` | `PrefillDecode/Receive.lean`, `PrefillDecode/Pipeline.lean` | `pushBegin`: `delegate->GetSession(uuid)` then `TryBeginOp()`; `false` (draining, done, or a send session) is `Cancelled`; uuid 0 holds no op | `Recv.StagingIntegrity`, `Recv.trace_push_lease_pins_staging_on_cancel`, `Recv.trace_push_lease_outlives_h2d`, `Pipeline.StagingSafe` |
| `bts.cc` | `EndIncomingPush` | `:258-271` | `PrefillDecode/Receive.lean`, `PrefillDecode/Pipeline.lean` | `pushEnd`: `Finish(status)` when `!status.ok()`, then `EndOp()` | `Recv.StagingIntegrity`, `Recv.trace_push_lease_pins_staging_on_cancel`, `Pipeline.StagingSafe` |
| `bts.cc` | `ValidateChunks` | `:275-310` | `PrefillDecode/LayerStaging.lean`, `PrefillDecode/Transport.lean` | per-chunk span check after `GetBlockChunks` (`GetBlockArrayHostSpan` → `ResolveBlockArrayHostLayer` → `ResolveStagingSlot`) | `LayerStaging.reachable_safe`, `NoSlotFault` |
| `bt.h` | `BlockTransport` (`absl::Mutex server_sessions_mu_;` .. `active_push_sessions_ ABSL_GUARDED_BY(server_sessions_mu_);`) | `:304-307` | `PrefillDecode/Transport.lean` | the uuid → push-session map (`GetOrCreatePushSession`, `ForgetPushProgress`) | — |
| `bt.cc` | `BlockTransport::GetOrCreatePushSession` | `:431-442` | `PrefillDecode/Transport.lean` | first stream of a uuid creates its session; later streams share it while it is live (`!IsDone()`, or `HasAdmittedPosts()` on the Peregrine path); a stream after retirement gets a fresh session | `Transport.reachable_safe` |
| `bt.cc` | `BlockTransport::HandleIncomingPush` | `:459-468` | `PrefillDecode/Receive.lean`, `PrefillDecode/Pipeline.lean`, `PrefillDecode/Transport.lean` | entry point of a stream: looks the uuid's push session up (`GetOrCreatePushSession`), delegates to `StartStream`, and drops that session (`DeletePushSession(session)`) once `IsDone()` | — |
| `bts.cc` | `BlockTransportServerPushSession::StartStream` | `:371-505` | `PrefillDecode/Receive.lean`, `PrefillDecode/Pipeline.lean`, `PrefillDecode/Transport.lean` | `pushBegin` (`BeginIncomingPush`), `land l`, `h2dBegin l` (`CompleteIncomingPush`), `netAccount` (`delegate_->OnBlockShardsReceived`), `pushEnd` (`EndIncomingPush`, also from the `absl::Cleanup` on any early error return); `Transport.Ev.stream l s` | `Recv.StagingIntegrity`, `Pipeline.StagingSafe` |
| `bt.cc` | `BlockTransport::OnRecvComplete` | `:484-496` | `PrefillDecode/Transport.lean` | Peregrine receive entry point (→ `OnPeregrinePostComplete` with the Post's `post_status`, unmodelled) | — |
| `bts.cc` | `BlockTransportServerPushSession::OnPeregrinePostComplete` | `:663-713` | `PrefillDecode/Transport.lean` | Peregrine receive path: takes the op either from the `PostLease` admitted earlier by `ResolveRecvBuffer` or from `BeginIncomingPush` here, then `CompleteIncomingPush(..., /*is_peregrine=*/true)` and `EndIncomingPush` (unmodelled) | — |
| `bts.cc` | `BlockTransportServerPushSession::CompleteIncomingPush` | `:724-893` | `PrefillDecode/Transport.lean`, `PrefillDecode/Receive.lean` | `Transport.Ev.stream l s`, `completePush`, `retire`, `nextLayer`; on a layer's completion a plan-declared push calls `session->OnDataReceived(l, {}, {})` on the session `BeginIncomingPush` returned, a header-declared one `delegate_->OnLayerReceived(l, uuid_)` | `Transport.reachable_safe` (`OnceDispatched`, `NetworkSound`, `CompleteOnSuccess`), `trace_dup_chunk_publishes_missing_layer`, `trace_dup_after_retirement`, `stepHardened` |
| `bt.cc` | `BlockTransport::ForgetPushProgress` | `:1044-1058` | `PrefillDecode/Transport.lean` | plan/session retirement erases and `Cancel()`s `active_push_sessions_[uuid]` outside manager `mu_`; outside single-uuid-generation scope under `Transport` A5 | — |
<!-- source-map:end -->

### Control plane

<!-- source-map:begin -->
| File | Symbol / anchor | Lines | Lean module | Model events / definitions | Key theorems / mutants |
|---|---|---|---|---|---|
| `tcp_control_plane_backend.cc` | `TcpControlPlaneBackend::SendPullRequestBlocking` | `:592-660` | `PrefillDecode/PeerIsolation.lean` | `Backend.tcpBlocking` | `PeerIsolation.tcp_healthy_blocked_when_pool_full` |
| `grpc_control_plane_backend.cc` | `GrpcControlPlaneBackend::SendPullRequest` | `:306-334` | `PrefillDecode/PeerIsolation.lean` | `Backend.grpcAsync` | `PeerIsolation.grpc_healthy_can_complete`, `PeerIsolation.grpc_freeWorkers_eq_poolSize` |
<!-- source-map:end -->

*External, the production caller pair (`Transfer/Caller.lean`):*
tpu-inference `tpu_inference/distributed/tpu_raiden_connector.py`,
vLLM `vllm/distributed/kv_transfer/kv_connector/utils.py`, and
vLLM `vllm/v1/core/sched/scheduler.py` (`TPUConnectorWorker.get_transfer_results`,
`get_finished`, `TPUConnectorScheduler.request_finished`,
`update_state_after_alloc`, `get_finished_count`; `KVOutputAggregator.aggregate`;
scheduler `_handle_invalid_blocks`, `_handle_failed_recving`,
`_update_from_kv_xfer_finished`, `finish_requests`,
`_update_waiting_for_remote_kv`, `kv_load_failure_policy`) →
`Caller.contract_safe`, `Caller.mw_contract_safe`,
`Caller.twoChannel_contract`, `Caller.applyRecv_eager_eq_latched`,
`Caller.applyRecv_staggered_eq_batch`, `Caller.leakP_absorbing`,
`Caller.leakD_absorbing`, `Caller.mwLeakP_absorbing`, `Caller.mwLeakD_absorbing`,
`trace_twoChannel_*`, `trace_mw_latched_*`, `trace_mw_staggered_*`,
`trace_dropFailed_*`, `trace_mw_dropFailed_partial_failure_leaks`,
`trace_naive_decodes`, `trace_loadErrorOnly_*`,
`trace_mw_overcounted_expected_leaks`.

## Where the rest lives

| Content | File |
|---|---|
| `trace_*` witnesses and the tests they replay; `#guard` bounded searches | the theorem docstrings and `#guard` lines in the Lean modules (`grep -rn "theorem trace_\|#guard" TpuSyncVerify/Transfer`) |
| how the models are written (one executable `step`, ghost fields, replay, mutants) | [conventions.md](../conventions.md) |
