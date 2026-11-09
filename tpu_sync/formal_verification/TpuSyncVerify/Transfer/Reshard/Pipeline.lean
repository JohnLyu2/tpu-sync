import TpuSyncVerify.Transfer.Reshard.Pipeline.Model
import TpuSyncVerify.Transfer.Reshard.Pipeline.Lemmas
import TpuSyncVerify.Transfer.Reshard.Pipeline.Invariant
import TpuSyncVerify.Transfer.Reshard.Pipeline.Preservation
import TpuSyncVerify.Transfer.Reshard.Pipeline.Progress
import TpuSyncVerify.Transfer.Reshard.Pipeline.Traces
import TpuSyncVerify.Transfer.Reshard.Pipeline.Coverage

/-!
# Pool-reshard transfer pipeline

End-to-end pool-addressed resharding model (`docs/transfer/reshard.md`):
composes `Reshard.Send` (`ReshardSendSession`, `Send.lean`), `Reshard.Recv`
(`ReshardReceiveSession`, `Receive.lean`), the plan-declared stream progress in
the per-uuid `BlockTransportServerPushSession` (`StartStream`, reached from
`BlockTransport::HandleIncomingPush`, and `CompleteIncomingPush`), the
Arm-then-Dispatch coordination barrier in `ReshardCoordinator::RunSubPlan`, and
the five memories KV data moves
through between source and destination HBM — including **aliased device pages**
shared across pool ranks (`pool_order_ranks_` in `ReshardReceiveSession`,
`D2hPoolBlocks` / `H2dPoolBlocks` in `KVCacheManagerBase`).

File aliases used in the source map below:
* `reshard_send.cc` — `tpu_sync/kv_cache/reshard_send_session.cc`
* `slots.cc` — `tpu_sync/core/pool_reshard_send_slots.cc`
* `reshard_recv.cc` — `tpu_sync/kv_cache/reshard_receive_session.cc`
* `bt.cc` — `tpu_sync/transport/block_transport.cc`
* `bts.cc` — `tpu_sync/transport/block_transport_session.cc`
* `mgr.cc` — `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`
* `base.h` / `base.cc` — `tpu_sync/kv_cache/kv_cache_manager_base.{h,cc}`
* `coord.cc` — `tpu_sync/kv_cache/reshard/reshard_coordinator.cc`
* `utils.h` — `tpu_sync/core/utils.h`

## Scope: one plan

The model is one transfer plan — one engine `uuid` with one
`ReshardSendSession` per source unit, one `ReshardReceiveSession` per
destination unit, and one `BlockTransportServerPushSession` per receiving
transport. A request whose destination lists are windowed
(`dst_window_blocks`) is coordinated as a chain of such plans
(`ReshardCoordinator::PlanSubTransfers`, `ReshardCoordinator::StartChain`):
each sub-plan carries its own plan uuid (`SubPlanUuid`), is armed and
dispatched by its own `ReshardCoordinator::RunSubPlan` call, and lands in its
own staging leases, so everything below applies to each sub-plan in turn. How
a worker folds the sub-plans' settlements into the request's single
`done_sending` / `done_recving` / `failed_recving` entry
(`KVCacheManagerWithTransfer::NoteSubPlanRegisteredLocked`,
`RecordPoolReshardTerminalLocked`, `SweepSubPlanChainsLocked`) is modelled in
`Reshard/SubPlanChain.lean`; `send.published` and `recv.published` here are the
session's own terminal as `CompleteReadWithDetails` hands it to that
bookkeeping.

## Memories and aliased device pages

A memory is a list indexed by pool `p < numPools`. A `Cell` is `.kv p` (pool
`p`'s resharded KV data), `.junk` (stale/reclaimed memory or lower-rank coarse
padding on an aliased page), or `.blank` (never written on the wire).

| Memory       | Role | Written by |
|--------------|------|------------|
| `srcHbm`     | producer KV cache in source HBM | `reclaim` (after `send.published ≠ none`) |
| `srcStaging` | sender `PoolStagingStorage` (`ReshardSendSession::ExecutePushPipeline`) | `send (.d2hDone p true)`, `reseatSrcStaging` |
| `wire`       | bytes delivered by sender peer pushes (`ReshardSendSession::StartPoolPush`) | `send (.pushDone p true)` |
| `dstStaging` | receiver `PoolStagingStorage` (`ReshardReceiveSession::AcquireStagingLeases`) | `landStream p` (`BlockTransportServerPushSession::StartStream`), `reseatDstStaging` |
| `dstHbm`     | consumer KV cache in destination HBM (`ReshardReceiveSession::ExecuteEligiblePoolH2ds` / `FinishPoolH2d`) | `recv (.h2dDone p true)` via `writePoolHbm` |

### Modelling aliased device pages (`writePoolHbm`)

On hybrid attention + state arenas (`D2hPoolBlocks` / `H2dPoolBlocks` in
`KVCacheManagerBase`, `pool_order_ranks_` in `ReshardReceiveSession`), pools of
different ranks can share physical HBM pages: a lower-rank pool's coarse H2D
copy writes across the page (clobbering bytes belonging to higher-rank pools),
and higher-rank H2D waves are meant to run afterwards to overwrite those bytes
with the true higher-rank pool data.

We model this pessimistic page aliasing directly on `dstHbm`: when pool `p`
completes its H2D copy (`recv (.h2dDone p true)`), `writePoolHbm` writes
`dstStaging[p]` to `dstHbm[p]` **and** clobbers `dstHbm[q] := .junk` for every
pool `q` of strictly higher rank (`pool_p.rank < pool_q.rank`). Because
`Recv.RankWaveOrder` guarantees that no higher-rank pool `q` has entered
`queued`, `issued`, `ready`, or `completed` when a lower-rank pool `p` is in
`ready`, this clobbering never overwrites a completed higher-rank pool
(`AliasedPageCorrect`), so `dstHbm = good numPools` holds when `done_recving`
is published (`PublicationCorrect`). Conversely, a mutant that omits the rank
gate allows pool 1 (rank 1) to finish H2D before pool 0 (rank 0), and pool 0's
subsequent H2D clobbers `dstHbm[1]` to `.junk`.

## Lock scopes

Sender events (`send e`) and receiver events (`recv e`) inherit the
`ReshardSendSession::mu_` and `ReshardReceiveSession::mu_` scopes from
`Send.lean` and `Receive.lean`. The pipeline-level events and cross-component
guards map to C++ synchronization as follows:

| Event | Scopes | Between them |
|---|---|---|
| `armRecv` | 2 `KVCacheManagerWithTransfer::mu_` scopes in `PoolReshardRegisterRecv`: incumbent check and the `pending_pool_reshard_recvs_` claim, then `CreateReshardReceiveSession` (`AcquireStagingLeases`) outside manager `mu_`, then insertion into `sessions_` as a `SessionEntry` with `SessionRole::kPoolReshardReceive` (dropping the claim, and `NoteSubPlanRegisteredLocked`) | Stage 1's `for (std::thread& t : armers) t.join();` barrier in `RunSubPlan` completes before Stage 2 dispatches any sender (`send (.d2hIssue p true)`), so no push arrives before `sessions_` holds the receiver (`recv .pushBegin` requires `armed = true`; `BeginIncomingPush` fails `GetSession` otherwise) |
| `landStream p` | unlocked socket read into staging (`if (expected_size > 0)`, `ReadVExact`) in `BlockTransportServerPushSession::StartStream` while holding a `pushBegin` op (`pushes > 0`; the chunk addresses come from `GetBlockChunks` → `ResolveStagingSlot`, `Receive.lean` §"Bounded host layer staging"), followed by 1 `BlockTransportServerPushSession::mu_` scope in `CompleteIncomingPush` (`if (plan_declared)`; `layer_progress_` is per push session, i.e. per uuid, keyed by pool) | the `pushBegin` op keeps `in_flight_ > 0` on the receive session so `dstStaging` cannot be released (`reseatDstStaging` is disabled) during the read; when `plan_pushes` reaches `expected_chunks`, the same `mu_` scope latches `trigger_completion = true` before `session->OnDataReceived(l, {}, {})` on the session whose op the stream holds — `ReshardReceiveSession::OnDataReceived`, which forwards a pool completion to `OnPoolReceived(pool_idx)` (`recv (.onPoolReceived p)`) — and `EndIncomingPush` (`pushEnd`) run |
| `reclaim`, `reseatSrcStaging`, `reseatDstStaging` | 0 (caller engine or `KVCacheManagerBase::staging_mu_`, outside session `mu_`) | enabled only after `send.published ≠ none` or `hasStaging = false`, which `Send.lean` and `Receive.lean` establish under their session locks |

## Source map

Line ranges are populated and checked by `tpu_sync/formal_verification/tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `reshard_send.cc` | `ReshardSendSession::Start` | `:401-438` |
| `reshard_send.cc` | `ReshardSendSession::ExecutePushPipeline` | `:440-554` |
| `reshard_send.cc` | `ReshardSendSession::StartPoolPush` | `:556-659` |
| `reshard_send.cc` | `ReshardSendSession::EndOp` | `:716-744` |
| `reshard_send.cc` | `ReshardSendSession::SettleLocked` | `:753-760` |
| `slots.cc` | `CountPoolReshardSendSlots` | `:27-51` |
| `reshard_recv.cc` | `ReshardReceiveSession` (`absl::flat_hash_map<size_t, int> pool_order_ranks_`) | `:213` |
| `reshard_recv.cc` | `ReshardReceiveSession::OnDataReceived` | `:127-134` |
| `reshard_recv.cc` | `CreateReshardReceiveSession` | `:519-553` |
| `reshard_recv.cc` | `ReshardReceiveSession::AcquireStagingLeases` | `:581-620` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReleaseStagingLocked` | `:622-627` |
| `reshard_recv.cc` | `ReshardReceiveSession::RecordPoolReceivedLocked` | `:719-730` |
| `reshard_recv.cc` | `ReshardReceiveSession::CollectEligiblePoolH2dsLocked` | `:732-761` |
| `reshard_recv.cc` | `ReshardReceiveSession::OnPoolReceived` | `:778-789` |
| `reshard_recv.cc` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` | `:791-855` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishPoolH2d` | `:857-893` |
| `bt.cc` | `BlockTransport::HandleIncomingPush` | `:443-452` |
| `bts.cc` | `BlockTransportServerPushSession::StartStream` (`if (expected_size > 0)`) | `:467-471` |
| `bts.cc` | `BlockTransportServerPushSession::CompleteIncomingPush` | `:718-887` |
| `bts.cc` | `BlockTransportServerPushSession::CompleteIncomingPush` (`progress.completed_chunks++;` .. `if (trigger_completion)`) | `:766-876` |
| `bts.cc` | `BeginIncomingPush` | `:242-256` |
| `bts.cc` | `EndIncomingPush` | `:258-271` |
| `mgr.cc` | `KVCacheManagerWithTransfer::GetSession` | `:310-317` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RetireSettledSessionLocked` | `:470-529` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardPush` | `:732-774` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` | `:776-825` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`for (auto it = sessions_.begin(); it != sessions_.end();)` .. `SweepSubPlanChainsLocked(now);`) | `:1079-1105` |
| `base.h` | `KVCacheManagerBase` (`absl::StatusOr<raiden::PjRtCopyFuture> D2hPoolBlocks` .. `absl::StatusOr<raiden::PjRtCopyFuture> H2dPoolBlocks`) | `:638-647` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` (`const int64_t receiver_arm_start_ns = MonotonicNs();` .. `if (!status.ok()) return status;`) | `:741-877` |
| `utils.h` | `ValidateCommonPoolReshardPlan` (`if (plan.transfer_pool_indices().empty())` .. `if (group.expected_pushes() <= 0)`) | `:367-377` |
<!-- source-map:end -->
-/
