import TpuSyncVerify.Transfer.PrefillDecode.LayerStaging.Model
import TpuSyncVerify.Transfer.PrefillDecode.LayerStaging.Lemmas
import TpuSyncVerify.Transfer.PrefillDecode.LayerStaging.SendInv
import TpuSyncVerify.Transfer.PrefillDecode.LayerStaging.RecvInv
import TpuSyncVerify.Transfer.PrefillDecode.LayerStaging.Invariant
import TpuSyncVerify.Transfer.PrefillDecode.LayerStaging.Progress
import TpuSyncVerify.Transfer.PrefillDecode.LayerStaging.SlotBounds
import TpuSyncVerify.Transfer.PrefillDecode.LayerStaging.Traces
import TpuSyncVerify.Transfer.PrefillDecode.LayerStaging.Coverage

/-!
# Prefill-to-decode transfer under bounded host layer staging

End-to-end single-request prefill-to-decode model when fewer host layer buffers
are allocated than device layers (the `num_staging_layers` constructor
parameter, `ResolveNumStagingLayers` in `base.cc`;
`KVCacheManagerBase::num_host_layers() < num_layers()`). Refines `Pipeline.lean`
by replacing the full per-layer host mirrors with `numSendSlots` physical
producer host layer buffers (`prefillSlots`) and `numRecvSlots` physical
consumer host layer buffers (`decodeSlots`), arbitrated independently by each
session's `StagingLayerManager` (`TpuSyncVerify/Transfer/LayerStaging.lean`).

* **Producer (`TransferSendSession`).** Before each iteration `l` of `StartPush`'s
  D2H loop takes `++in_flight_`, `AcquireStagingSlot(l)` checks `done_ || draining_`
  under `mu_`, blocks in `StagingLayerManager::Acquire(l, deadline_, &cancelled_)`
  until a host buffer is free, `deadline_` expires or `cancelled_` / `Shutdown()`
  wakes it, calls `FinishLocked(slot.status(), kStagingPhase)` on a non-cancelled
  error, and re-checks `done_ || draining_` under `mu_` (releasing `l` if the
  session started draining in the unlocked gap). Once `D2hSyncDispatch` runs,
  layer `l` owns its slot across D2H completion (`d2hReady l`), `SendNextLayer`'s
  `push_pool` task (`LookupStagingSlot(l)`, reached as
  `TransferSendSession::ResolveStagingSlot` from
  `KVCacheManagerBase::GetBlockChunks` in `BlockTransport::BuildBlockRequests`),
  and `H2hWriteDirectAsync`, releasing it only inside the H2H
  completion callback (`h2hDone l ok`), on an earlier error/draining exit
  (`sendD2hBegin`, `sendD2hIssue false`, `sendWake`, `sendH2hIssue`), or
  wholesale at settle (`ReleaseAll()` in `ReleaseStagingBlocksLocked`). Because
  `StartPush` arms `SendNextLayer(0)` *before* entering the D2H loop, earlier
  layers' H2H pushes complete and return host buffers while the D2H loop is
  blocked in `AcquireStagingSlot` for a later layer.
* **Consumer (`TransferReceiveSession`).** When an incoming push stream addresses
  layer `l`'s host memory in `KVCacheManagerBase::GetBlockChunks`
  (`GetSession(uuid)`, then `session->ResolveStagingSlot(layer_idx)` =
  `TransferReceiveSession::AcquireStagingSlot`),
  `AcquireStagingSlot(l)` refuses if `done_ || draining_`, takes an `in_flight_`
  op, waits in `StagingLayerManager::Acquire(l, deadline, &cancelled_)` (returning
  the existing slot immediately on additional chunks/shards of an already-leased
  layer), fails the session on timeout or zero-slot error, releases `l` if the
  session started draining in the unlocked gap, and ends its `in_flight_` op.
  (On a full host mirror both `ResolveStagingSlot`s return `NotFound` and
  `GetBlockChunks` addresses the layer's own buffer.)
  `ForEachPayload` lands layer `l` into `decodeSlots[slot]` inside the outer
  `BeginIncomingPush` .. `EndIncomingPush` lease (`GetSession` + `TryBeginOp`,
  `EndOp`); still inside that stream lease,
  `CompleteIncomingPush` → `KVCacheManagerBase::OnLayerReceived(l)` →
  `OnDataReceived(l, {}, {})` → `ExecuteLayerH2d(l)` first
  resolves `Lookup(l)` (`recv.cc`), then acquires `mu_` and either releases `l`
  without dispatching if `done_ || draining_ || total_blocks_ == 0` (the last
  disjunct never holds here: zero-block reads are finished by `StartRead`
  without a pull) or dispatches `H2dSyncDispatch`
  from `decodeSlots[slot]` into `decodeHbmB[l]`, releasing `l` inside
  `future.OnReady` (`h2dDone l ok`) or wholesale at settle (`ReleaseAll()` in
  `ReleaseStagingLocked`).

`session.h` is `tpu_sync/kv_cache/transfer_session.h`; `send.h`/`send.cc` are
`tpu_sync/kv_cache/transfer_send_session.{h,cc}`; `recv.h`/`recv.cc` are
`tpu_sync/kv_cache/transfer_receive_session.{h,cc}`; `mgr.cc` is
`tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`; `base.cc` is
`tpu_sync/kv_cache/kv_cache_manager_base.cc`; `bt.cc` is
`tpu_sync/transport/block_transport.cc`; `bts.cc` is
`tpu_sync/transport/block_transport_session.cc`. Exact line ranges for every
symbol, sub-block, and test are in the generated `## Source map` table below.

## State and lock scopes

`BoundedPipeline` embeds `pipe : Pipeline` (preserving every session counter,
lifecycle bit, and handshake step via the lockstep simulation `step_pipe_steps`)
and adds:

| Field | C++ | Role |
|---|---|---|
| `sendMgr` | `TransferSendSession::staging_layer_manager_` | producer `StagingLayerManager(numSendSlots)` |
| `recvMgr` | `TransferReceiveSession::staging_layer_manager_` | consumer `StagingLayerManager(numRecvSlots)` |
| `prefillSlots` | `GetHostPointer(0..numSendSlots-1, shard)` on producer | producer's physical host layer buffers |
| `wireB` | payload delivered onto the wire from `prefillSlots[slot]` | layer-indexed wire cells |
| `decodeSlots` | `GetHostPointer(0..numRecvSlots-1, shard)` on consumer | consumer's physical host layer buffers |
| `decodeHbmB` | decode HBM written from `decodeSlots[slot]` | consumer's `numLayers` HBM layers |
| `sendLoop` | control pc of `StartPush`'s D2H loop (`SendLoopPhase`) | `.nextIter`, `.acquiring`, `.leasedBeforeD2h`, `.exited` |
| `recvPhaseL` | per-layer consumer lease state (`RecvLayerPhase`) | `.idle`, `.waiting hadLease`, `.leasedInAcquire`, `.leasedForStream`, `.h2dPending`, `.h2dRunning`, `.h2dRetired`, `.aborted` |
| `activeStreams` | open `BeginIncomingPush` .. `EndIncomingPush` streams | separates stream leases from `AcquireStagingSlot`'s transient `in_flight_` op |
| `slotFault` | ghost fault latch | set if any D2H, H2H, stream land, or H2D step sees `Lookup = none` or `slot ≥ numSlots` |

**Unlocked gaps around `StagingLayerManager::Acquire`.** Both `AcquireStagingSlot`
implementations drop session `mu_` before calling `StagingLayerManager::Acquire`
and re-acquire session `mu_` afterwards. Splitting producer acquisition into
`sendAcquireBegin` → `sendAcquireDone` → `sendD2hBegin` (via `.acquiring` and
`.leasedBeforeD2h`) and consumer acquisition into `recvAcquireBegin` →
`recvAcquireWait` → `recvAcquireFinish` (via `.waiting hadLease` and
`.leasedInAcquire`) admits arbitrary concurrent session callbacks and external
`Finish(error)` calls in both unlocked gaps. On callback error (`sendWake false`,
`h2hDone l false`, `h2dDone l false`), `FinishLocked` calls
`staging_layer_manager_.Shutdown()` *before* `Release(l)` (`releaseSync`;
`doShutdown_release` proves both orders yield the identical `StagingLayerManager`),
so a thread blocked in `Acquire` wakes with `Cancelled` instead of claiming the
freed slot on a failing session.

## Assumptions

Inherits `Pipeline` A1–A4 (`Pipeline.lean` §Assumptions), plus:

* **LS1 (single stream / monotonic pre-land touches per consumer layer).** Under
  `Pipeline` A3 (one sender stream per layer), `GetBlockChunks(l)` is called
  only before `CompleteIncomingPush` marks layer `l` landed (`landedL[l] = false`),
  and at most one thread calls `AcquireStagingSlot(l)` for a given `l` at a time.
  Multiple chunks or shards of layer `l` within that stream may call
  `AcquireStagingSlot(l)` repeatedly (`recvAcquireBegin` from `.leasedForStream`,
  exercised in `trace_recv_cycles_host_layer_buffers`).
* **LS2 (`StagingLayerManager::mu_` ordering on error callbacks).** In C++,
  `FinishLocked` (`Shutdown()`) and `Release(l)` acquire `StagingLayerManager::mu_`
  in separate scopes; because `Shutdown()` runs first and sets `shutdown_ = true`
  monotonically (`doShutdown_release`), any waiter woken by `Shutdown()` or
  `Release(l)` observes `shutdown_ == true` under `StagingLayerManager::mu_` and
  returns `Cancelled`, matching atomic `releaseSync`.

## Main theorems

* **Safety (`reachable_safe`, `reachable_unregistered_safe`).** Every state
  reachable from `init n numSendSlots numRecvSlots` or
  `initUnregistered n numSendSlots numRecvSlots` (for *any* `n, numSendSlots,
  numRecvSlots : Nat`, including `1` slot or `0` slots) satisfies `Safe`:
  - `Pipeline.Safe s.pipe` (decode/prefill HBM quietness, staging lifetime,
    handshake rendezvous, `NoOpLeak`);
  - `PublicationCorrect`: `s.pipe.recv.published = some true → s.decodeHbmB = Pipeline.good n`
    — multiplexing `n` layers over arbitrarily few host buffers never aliases or
    corrupts another layer's KV data;
  - `NoSlotFault`: `s.slotFault = false` — every active D2H write, `GetBlockChunks`
    send lookup, H2H read, stream landing, `ExecuteLayerH2d` lookup, and H2D read
    finds a live in-bounds physical host slot;
  - `SlotManagersValid`: `free.length + leases.length = numSlots` and `allSlots.Nodup`
    on both sessions' `StagingLayerManager`s;
  - `SettledSlotsFree`: `done = true → leases = [] ∧ numFree = numSlots` on both
    sessions;
  - `DrainingShutsDown`: `draining = true → shutdown = true` on both sessions.
* **Lookup resolution & exclusivity (`sendLookupStagingSlot_active`,
  `recvLookupStagingSlot_active`, `sendLookupStagingSlot_injective`,
  `recvLookupStagingSlot_injective`).** Every active non-draining `GetBlockChunks`
  producer lookup and every open-stream `ExecuteLayerH2d` consumer precheck (even
  on a concurrently draining session) resolves an in-bounds physical host slot
  holding `.kv l`, and distinct live layers never alias to the same physical slot.
* **Eventual settlement (`reachable_can_settle`).** From every reachable state
  (registered or unregistered, for any `n, numSendSlots, numRecvSlots`), there
  exists a finite trace reaching a fully settled, published state where both
  sessions have `done = true`, `hasStaging = false`, `leases = []`, and
  `numFree = numSlots` — bounded host staging introduces no deadlock even when
  `numSendSlots < n`, `numRecvSlots < n`, or `0`.
* **Necessary and sufficient slot bounds (`no_slots_cannot_publish_ok`,
  `exists_complete_trace`).** For `0 < n`, if `numSendSlots = 0` or
  `numRecvSlots = 0` then `recv.published = some true` is unreachable; conversely,
  whenever `n = 0` or (`0 < numSendSlots ∧ 0 < numRecvSlots`), there exists an
  explicit finite trace (`completeTrace n`) publishing `done_sending`,
  `done_recving`, and `decodeHbmB = Pipeline.good n` — **1 host layer buffer on
  each side suffices for arbitrary `n`**.

## Replay traces, mutants, and branch coverage

* `LayerStaging/Traces.lean` replays all four bounded-staging GTests in
  `send_drain_test.cc` (including all seven failure subcases of
  `StagingLayerManagerReleasesAllResourcesAcrossFailureModes`), lock-gap
  cancellation races, zero-slot rejection, unregistered handshake + poll +
  recycle, and refutes three mutants (`mutant_early_send_release_corrupts_hbm`,
  `mutant_early_recv_release_corrupts_hbm`, `mutant_missing_release_all_leaks_slot`).
* `LayerStaging/Coverage.lean` proves `stepT_step` and checks via `#guard` across
  the 95-branch 1-layer universe that every memory move writes `.kvRight`,
  `.slotFault` is unreachable, and all 56 branches outside `paired` partition
  with `0` unaccounted.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `session.h` | `StagingLayerManager` | `:40-75` |
| `recv.cc` | `StagingLayerManager::Acquire` | `:95-124` |
| `recv.cc` | `StagingLayerManager::Lookup` | `:126-133` |
| `recv.cc` | `StagingLayerManager::Release` | `:135-145` |
| `recv.cc` | `StagingLayerManager::ReleaseAll` | `:147-154` |
| `recv.cc` | `StagingLayerManager::Shutdown` | `:156-159` |
| `recv.cc` | `TransferReceiveSession::ReleaseStagingLocked` | `:459-462` |
| `recv.cc` | `TransferReceiveSession::FinishLocked` | `:469-484` |
| `recv.cc` | `TransferReceiveSession::AcquireStagingSlot` | `:755-784` |
| `recv.cc` | `TransferReceiveSession::ExecuteLayerH2d` (`if (base_->num_host_layers() < base_->num_layers())` .. `self->staging_layer_manager_.Release(layer_idx);`) | `:818-920` |
| `send.cc` | `TransferSendSession::ReleaseStagingBlocksLocked` | `:226-230` |
| `send.cc` | `TransferSendSession::AcquireStagingSlot` | `:237-266` |
| `send.cc` | `TransferSendSession::LookupStagingSlot` | `:268-287` |
| `send.cc` | `TransferSendSession::FinishLocked` | `:289-304` |
| `send.cc` | `TransferSendSession::StartPush` (`absl::StatusOr<size_t> host_layer_idx = AcquireStagingSlot(l);` .. `next_layer = l + 1;`) | `:560-609` |
| `send.cc` | `TransferSendSession::SendNextLayer` | `:613-712` |
| `send.h` | `TransferSendSession::ResolveStagingSlot` | `:149-151` |
| `recv.h` | `TransferReceiveSession::ResolveStagingSlot` | `:155-157` |
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` (`hooks.get_session =`) | `:276` |
| `mgr.cc` | `KVCacheManagerWithTransfer::GetSession` | `:280-287` |
| `base.cc` | `KVCacheManagerBase::GetBlockChunks` (`size_t host_layer_idx = layer_idx;` .. `base_host_ptr = GetHostPointer(host_layer_idx, shard_idx);`) | `:3167-3178` |
| `base.cc` | `KVCacheManagerBase::OnLayerReceived` | `:3009-3018` |
| `base.cc` | `*` (`size_t ResolveNumStagingLayers(size_t num_layers,` .. `return requested;`) | `:429-445` |
| `bt.cc` | `BlockTransport::BuildBlockRequests` (`std::vector<BlockChunk> chunks = block_delegate_->GetBlockChunks(`) | `:814-817` |
| `bts.cc` | `BeginIncomingPush` | `:286-300` |
| `bts.cc` | `EndIncomingPush` | `:302-315` |
| `send_drain_test.cc` | `RecvLifecycleTest.StagingLayerManagerCyclesHostLayerBuffers` | `:1726-1810` |
| `send_drain_test.cc` | `RecvLifecycleTest.StagingLayerManagerReleasesAllResourcesAcrossFailureModes` | `:1812-1922` |
| `send_drain_test.cc` | `SendLifecycleTest.StagingLayerManagerCyclesHostLayerBuffers` | `:1929-2026` |
| `send_drain_test.cc` | `SendLifecycleTest.StagingLayerManagerReleasesAllResourcesAcrossFailureModes` | `:2028-2175` |
<!-- source-map:end -->
-/
