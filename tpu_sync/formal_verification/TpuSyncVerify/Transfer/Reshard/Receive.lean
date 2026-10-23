import TpuSyncVerify.Transfer.Reshard.Receive.Model
import TpuSyncVerify.Transfer.Reshard.Receive.Lemmas
import TpuSyncVerify.Transfer.Reshard.Receive.Invariant
import TpuSyncVerify.Transfer.Reshard.Receive.Progress
import TpuSyncVerify.Transfer.Reshard.Receive.Traces

/-!
# Reshard receive session

One `ReshardReceiveSession` on the destination (consumer) side and the slice of
`KVCacheManagerWithTransfer` that drives it (`PoolReshardRegisterRecv`,
`OnPoolReceived`, `begin_incoming_push`, `end_incoming_push`,
`MaybeUnregisterSettledReshardRecv`, and the `CompleteReadWithDetails` poll).
Sender sessions, multi-sender stream counting, and aliased-page memory contents
are modelled in `Reshard/Send.lean` and `Reshard/Pipeline.lean`.

Citations are to the baseline commit in `tpu_sync/formal_verification/README.md` §Status.
`reshard_recv.h`/`reshard_recv.cc` are
`tpu_sync/kv_cache/reshard_receive_session.{h,cc}`; `mgr.cc` is
`tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`; `bt.cc` is
`tpu_sync/transport/block_transport.cc`; `utils.h` is
`tpu_sync/core/utils.h`. Exact line ranges for every symbol, sub-block, and test
are in the generated `## Source map` table below.

## How a reshard receive runs

`KVCacheManagerWithTransfer::PoolReshardRegisterRecv` creates a
`ReshardReceiveSession` (`ReshardReceiveSession::Create`,
`ReshardReceiveSession::ReshardReceiveSession`), claiming the active plan
(`base->RegisterActivePlanDirect(plan.uuid(), plan, /*is_sender=*/false)`),
acquiring bounded per-UUID `PoolStagingLease`s across the plan's destination
storages (`ReshardReceiveSession::AcquireStagingLeases`), and inserting the
session into `active_pool_reshard_recvs_`
(`active_pool_reshard_recvs_[plan.uuid()] = std::move(recv_session)`). Each
transferred pool in `expected_pool_indices_` has an order rank in
`pool_order_ranks_` (`pool_order_ranks_[static_cast<size_t>(pool_idx)] = group.order_rank()`
in `ReshardReceiveSession::ReshardReceiveSession`).

As incoming push streams arrive at `BlockTransport::HandleIncomingPush` /
`BlockTransport::CompleteIncomingPush`, each stream takes a receive op via
`hooks.begin_incoming_push` (`ReshardReceiveSession::TryBeginRecvOp`) and
releases it in `hooks.end_incoming_push` (`ReshardReceiveSession::EndRecvOp`).
When all `expected_pushes` streams for a pool have landed, the transport fires
`block_delegate_->OnPoolReceived(l, uuid)` (`hooks.on_pool_received` →
`ReshardReceiveSession::OnPoolReceived`), which records the pool in
`started_pool_indices_` (`ReshardReceiveSession::RecordPoolReceivedLocked`) and
calls `ReshardReceiveSession::ExecuteEligiblePoolH2ds`.

`ExecuteEligiblePoolH2ds` selects under `mu_` every started, unlaunched pool
whose strictly lower-rank prerequisite pools are all in
`completed_pool_indices_` (`ReshardReceiveSession::CollectEligiblePoolH2dsLocked`),
marks them in `h2d_launched_pools_`, and adds `to_launch.size()` to `in_flight_`
(`in_flight_ += static_cast<int32_t>(to_launch.size())`). Outside `mu_`, it
loops over `to_launch`: for each pool it re-checks `if (done_ || draining_)`
under `mu_` (calling `EndRecvOpLocked()` and skipping the upload if the session
finished in the window), dispatches `base_->H2dPoolBlocks`, pushes the future
into `h2d_futures_` (`h2d_futures_.push_back(future)`), and attaches
`FinishPoolH2d` + `EndRecvOp` + `MaybeUnregisterSettledReshardRecv` to
`future.OnReady`.

When a pool's H2D finishes, `ReshardReceiveSession::FinishPoolH2d` calls
`ReshardReceiveSession::RecordPoolH2dResultLocked`. On an intermediate OK
completion (`if (!finished && status.ok())`), it calls
`ExecuteEligiblePoolH2ds(manager)` to launch the next rank wave before the outer
`future.OnReady` callback's `self->EndRecvOp()` releases the completed pool's
op. On the first error or when `completed_pool_indices_ == expected_pool_indices_`,
`reshard_finalizing_` is set (`finished = true`), `network_completed_ = true`
and `should_record_duration = true` are latched on success, and
`Finish(terminal_status)` drains the session.

## State

The settle protocol itself is `Transfer.Lifecycle` (`in_flight_`, `draining_`,
`done_`, `status_.ok()`, and `!staging_released_`). On top of it, each expected
pool is a `Pool := ⟨rank, stage⟩` in `pools : List Pool`:

| Pool stage   | C++ membership (`ReshardReceiveSession`)             | Holds op in `in_flight_` |
|--------------|------------------------------------------------------|--------------------------|
| `.waiting`   | in `expected_pool_indices_`, not yet in `started_pool_indices_` | no |
| `.received`  | in `started_pool_indices_`, not yet in `h2d_launched_pools_` | no |
| `.queued`    | in `h2d_launched_pools_` after `in_flight_ += static_cast<int32_t>(to_launch.size())` (`CollectEligiblePoolH2dsLocked`, `ExecuteEligiblePoolH2ds`), before the per-pool re-check lock (`if (done_ || draining_)`) | yes |
| `.issued`    | `H2dPoolBlocks` succeeded; future in `h2d_futures_` (`h2d_futures_.push_back(future)`) with `!IsReady()` | yes |
| `.ready`     | future in `h2d_futures_` has `IsReady()`, `OnReady` callback not yet completed | yes |
| `.completed` | in `completed_pool_indices_` (`RecordPoolH2dResultLocked`) and `self->EndRecvOp()` ran (`ExecuteEligiblePoolH2ds`'s `future.OnReady`) | no |
| `.aborted`   | op ended without completing: skipped at re-check (`EndRecvOpLocked()`), or `H2dPoolBlocks`/`OnReady` failed or saw `reshard_finalizing_` | no |

Session-level fields:

| Field              | C++                                                                 | Role |
|--------------------|---------------------------------------------------------------------|------|
| `pools`            | `expected_pool_indices_`, `pool_order_ranks_`, `started_pool_indices_`, `h2d_launched_pools_`, `h2d_futures_`, `completed_pool_indices_` | per-pool state |
| `life`             | `in_flight_`, `draining_`, `done_`, `status_`, `!staging_released_` (`ReshardReceiveSession`) | `Transfer.Lifecycle` |
| `finalizing`       | `reshard_finalizing_` (`ReshardReceiveSession`)                     | stops further H2D launches and results after first error or full completion |
| `networkCompleted` | `network_completed_` (set in `FinishPoolH2d`)                       | latched on final pool H2D success |
| `planUnregistered` | `!unregister_on_settle_` (claimed in `ReshardReceiveSession::TakePendingUnregister`) | active plan unregistered on settle |
| `durationRecorded` | ghost (`should_record_duration` / `RecordTransferDuration` in `FinishPoolH2d`) | end-of-transfer latency histogram recorded |
| `published`        | membership in `done_recving_` / `failed_recving_` (`CompleteReadWithDetails`) | what `poll_stats()` shows the engine |
| `pushes`           | ghost                                                               | incoming pushes between `TryBeginRecvOp` (`hooks.begin_incoming_push`) and `EndRecvOp` (`hooks.end_incoming_push`) |

## Events

| Event               | C++ |
|---------------------|-----|
| `pushBegin`         | `ReshardReceiveSession::TryBeginRecvOp` from `hooks.begin_incoming_push`, called in `BlockTransport::HandleIncomingPush` (`block_delegate_->BeginIncomingPush(header.uuid)`) |
| `pushEnd ok`        | `hooks.end_incoming_push`, called in `BlockTransport::HandleIncomingPush` (`block_delegate_->EndIncomingPush`). Parameterized by `PushEndPolicy`: `.finishOnError` (shipping) calls `reshard_session->Finish(status)` before `reshard_session->EndRecvOp()` on `ok = false` (matching the `TransferReceiveSession` branch), whereas `.endOpOnly` (mutant) runs `EndRecvOp()` unconditionally |
| `onPoolReceived p`  | `ReshardReceiveSession::OnPoolReceived` + `ExecuteEligiblePoolH2ds` first lock (`to_launch = CollectEligiblePoolH2dsLocked()`): records `p` in `started_pool_indices_` and batch-queues every eligible started pool |
| `h2dIssue p ok`     | `ExecuteEligiblePoolH2ds` loop body (`for (auto& [pool_idx, dst_chip_block_ids] : to_launch)`): re-checks `if (done_ \|\| draining_)` under `mu_`, otherwise dispatches `base_->H2dPoolBlocks` |
| `h2dReady p`        | device finishes pool `p`'s H2D copy: its future in `h2d_futures_` becomes `IsReady()` |
| `h2dDone p ok`      | `ExecuteEligiblePoolH2ds`'s `future.OnReady` callback calling `FinishPoolH2d`, `EndRecvOp`, and `MaybeUnregisterSettledReshardRecv` |
| `pollReady`         | `CompleteReadWithDetails` sees `!session->IsDraining()` and `session->IsReadyToComplete()` and calls `session->Finish()` |
| `cancel`            | external `Finish(error)`: deadline (`CompleteReadWithDetails`), shutdown (`~KVCacheManagerWithTransfer`), or `UnregisterActivePlan` |
| `publish`           | `CompleteReadWithDetails` moves a settled session (`session->Done()`) into `done_recving_` or `failed_recving_`, claims `session->TakePendingUnregister(&generation)`, and erases it from `active_pool_reshard_recvs_` |

## Assumptions

* **A1 (at-most-once `OnPoolReceived` per declared pool).**
  `BlockTransport::CompleteIncomingPush` fires `block_delegate_->OnPoolReceived(l, uuid)`
  only when `plan_pushes == expected_chunks`, and
  `ReshardReceiveSession::RecordPoolReceivedLocked` rejects undeclared or
  duplicate pool indices. Encoded as the `onPoolReceived p` guard
  `pool.stage == .waiting`. (Discharged in `Reshard/Pipeline.lean` by explicit
  stream counting.)
* **A2 (registration before visibility).**
  `base->RegisterActivePlanDirect(plan.uuid(), plan, /*is_sender=*/false)` and
  `AcquireStagingLeases` in `ReshardReceiveSession::Create` succeed before the
  session is inserted into `active_pool_reshard_recvs_` in
  `PoolReshardRegisterRecv`. If `AcquireStagingLeases` fails, `Create` calls
  `session->ReleaseStaging()` and rolls back
  `base->UnregisterActivePlanDirect(plan.uuid())` before any hook can find the
  session.
* **A3 (no double end).** Each push and each H2D op ends at most once: `pushEnd`
  requires `pushes > 0`, `h2dIssue p` requires `stage == .queued`, and
  `h2dDone p` requires `stage == .ready`.
* **A4 (fold of `RecordPoolReceivedLocked` / `RecordPoolH2dResultLocked` with
  `ExecuteEligiblePoolH2ds` first lock).** Between unlocking `mu_` after
  recording a pool (`RecordPoolReceivedLocked(pool_idx)` in `OnPoolReceived` or
  `RecordPoolH2dResultLocked(pool_idx, status)` in `FinishPoolH2d`) and locking
  `mu_` in `ExecuteEligiblePoolH2ds`, an external `Finish` has the same effect
  as one arriving either before the event (where `if (done_ || draining_) return;`
  skips `CollectEligiblePoolH2dsLocked`) or immediately after
  `in_flight_ += static_cast<int32_t>(to_launch.size())` (where the per-pool
  re-check `if (done_ || draining_) { EndRecvOpLocked(); continue; }` aborts
  each queued pool and releases its op).

## Properties

All proved on every reachable state (`reachable_safe`), under both
`PushEndPolicy.finishOnError` (shipping) and `PushEndPolicy.endOpOnly`:

* **Settle safety (`SettleSafe`).** `done → inFlight = 0`: a settled session
  owns no in-flight push or H2D copy, as required by the comments in
  `ExecuteEligiblePoolH2ds` and `FinishPoolH2d`.
* **No retired callback (`NoRetiredCallback`).** `done → poolOps pools = 0`:
  no pool is `.queued`, `.issued`, or `.ready` once settled, so the early return
  `if (done_) return;` in `FinishPoolH2d` is unreachable.
* **Staging integrity (`StagingIntegrity`).** `hasStaging = !done`: the bounded
  `PoolStagingLease` is held exactly until the session settles.
* **Plan integrity (`PlanIntegrity`).** `(planUnregistered → done) ∧
  (published ≠ none → planUnregistered)`: the active transfer plan is never
  unregistered while any push or H2D copy can still resolve through it
  (`FinishPoolH2d`, `UnregisterActivePlan`, `MaybeUnregisterSettledReshardRecv`),
  and is always unregistered once published.
* **Prompt settle (`SettlesPromptly`).** `draining → inFlight = 0 → done`.
* **Rank-wave ordering (`RankWaveOrder`).** For every pair of pools `p, q ∈ pools`,
  if `p` has launched (`p.stage.launched = true`) and `q.rank < p.rank`, then
  `q.stage = .completed`: no higher-rank pool is ever queued, issued, or
  completed before every strictly lower-rank pool has completed its H2D upload
  (`pool_order_ranks_` comment in `ReshardReceiveSession`,
  `CollectEligiblePoolH2dsLocked`).
* **Readiness soundness (`ReadinessSound`).** `isReadyToComplete → allCompleted pools`:
  when `IsReadyToComplete()` holds, every expected pool has completed its H2D
  upload. Moreover, at callback granularity `pollReady` is never enabled on any
  reachable state (`reachable_pollReady_disabled`), because `FinishPoolH2d` sets
  `network_completed_ = true` immediately before calling
  `Finish(terminal_status)` (and after latching `should_record_duration = true`).
* **Publication (`Publication`).** `published = some true → allCompleted pools ∧
  durationRecorded`: when `poll_stats()` reports `done_recving`, every expected
  pool has completed its H2D upload and the transfer duration metric has been
  recorded.
* **No op leak & termination (`NoOpLeak`, `reachable_can_settle`).** While
  `0 < inFlight`, some event in `drainEvents` is enabled, and every reachable
  state can drain to `done = true ∧ hasStaging = false` in a finite number of
  steps.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `reshard_recv.h` | `ReshardReceiveSession::TryBeginRecvOp` | `:100-105` |
| `reshard_recv.h` | `ReshardReceiveSession` (`bool staging_released_` .. `absl::flat_hash_set<size_t> h2d_launched_pools_`) | `:172-190` |
| `reshard_recv.cc` | `RecordTransferDuration` | `:60-63` |
| `reshard_recv.cc` | `ReshardReceiveSession::ValidatePlan` | `:67-144` |
| `reshard_recv.cc` | `ReshardReceiveSession::Create` | `:351-390` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReshardReceiveSession` | `:392-418` |
| `reshard_recv.cc` | `ReshardReceiveSession::AcquireStagingLeases` | `:420-459` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishLocked` | `:472-482` |
| `reshard_recv.cc` | `ReshardReceiveSession::EndRecvOpLocked` | `:495-505` |
| `reshard_recv.cc` | `ReshardReceiveSession::TakePendingUnregister` | `:512-520` |
| `reshard_recv.cc` | `ReshardReceiveSession::AllH2dDoneLocked` | `:522-527` |
| `reshard_recv.cc` | `ReshardReceiveSession::IsReadyToComplete` | `:529-532` |
| `reshard_recv.cc` | `ReshardReceiveSession::RecordPoolReceivedLocked` | `:541-552` |
| `reshard_recv.cc` | `ReshardReceiveSession::CollectEligiblePoolH2dsLocked` | `:554-583` |
| `reshard_recv.cc` | `ReshardReceiveSession::RecordPoolH2dResultLocked` | `:585-598` |
| `reshard_recv.cc` | `ReshardReceiveSession::OnPoolReceived` | `:600-612` |
| `reshard_recv.cc` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` | `:614-666` |
| `reshard_recv.cc` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` (`to_launch = CollectEligiblePoolH2dsLocked();` .. `in_flight_ += static_cast<int32_t>(to_launch.size());`) | `:622-623` |
| `reshard_recv.cc` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` (`EndRecvOpLocked();`) | `:635` |
| `reshard_recv.cc` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` (`future.OnReady`) | `:654-664` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishPoolH2d` | `:668-706` |
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` (`hooks.on_pool_received =`) | `:180-202` |
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` (`hooks.begin_incoming_push =`) | `:224-249` |
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` (`hooks.end_incoming_push =`) | `:250-296` |
| `mgr.cc` | `KVCacheManagerWithTransfer::~KVCacheManagerWithTransfer` (`for (const auto& [uuid, session] : active_pool_reshard_recvs_)`) | `:391-395` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` | `:679-715` |
| `mgr.cc` | `KVCacheManagerWithTransfer::UnregisterActivePlan` | `:717-754` |
| `mgr.cc` | `KVCacheManagerWithTransfer::MaybeUnregisterSettledReshardRecv` | `:782-788` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`for (auto it = active_pool_reshard_recvs_.begin();`) | `:1043-1073` |
| `bt.cc` | `BlockTransport::HandleIncomingPush` | `:496-639` |
| `bt.cc` | `BlockTransport::CompleteIncomingPush` | `:641-794` |
| `utils.h` | `ValidateCommonPoolReshardPlan` | `:353-469` |
| `utils.h` | `ValidatePoolBlockBounds` | `:473-489` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.AcceptsCanonicalPlanOnExplicitPools` | `:137-145` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.AcceptsImplicitPools` | `:147-154` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.HasNoTagPolicy` | `:156-164` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.RejectsMissingIdentityAndPoolFields` | `:166-198` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.RejectsOutOfRangeDuplicateAndDtypeMismatch` | `:200-225` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.RejectsBlockIdsOutsideDeclaredPool` | `:257-276` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.GroupScopesDestinationBlocks` | `:405-439` |
| `pool_reshard_test.cc` | `PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints` | `:271-287` |
| `pool_reshard_test.cc` | `PoolReshardRecvTest.FinishPoolReshardRecvRecordsDurationMetric` | `:327-347` |
| `pool_reshard_test.cc` | `PoolReshardRecvTest.FinishPoolReshardRecvDoesNotRecordMetricOnFailure` | `:349-367` |
| `pool_reshard_test.cc` | `PoolReshardRecvTest.FailedIncomingPushReleasesStagingLeaseBeforeDeadline` | `:766-802` |
<!-- source-map:end -->
-/
