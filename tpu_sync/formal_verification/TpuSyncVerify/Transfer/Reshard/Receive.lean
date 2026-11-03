import TpuSyncVerify.Transfer.Reshard.Receive.Model
import TpuSyncVerify.Transfer.Reshard.Receive.Lemmas
import TpuSyncVerify.Transfer.Reshard.Receive.Invariant
import TpuSyncVerify.Transfer.Reshard.Receive.Progress
import TpuSyncVerify.Transfer.Reshard.Receive.Traces
import TpuSyncVerify.Transfer.Reshard.Receive.Coverage

/-!
# Reshard receive session

One `ReshardReceiveSession` on the destination (consumer) side and the slice of
`KVCacheManagerWithTransfer` and the transport that drives it
(`PoolReshardRegisterRecv`, `GetSession`, `BeginIncomingPush` /
`EndIncomingPush`, `KVCacheManagerBase::OnPoolReceived`, and the
`CompleteReadWithDetails` poll). Sender sessions, multi-sender stream counting,
and aliased-page memory contents are modelled in `Reshard/Send.lean` and
`Reshard/Pipeline.lean`.

`reshard_recv.h`/`reshard_recv.cc` are
`tpu_sync/kv_cache/reshard_receive_session.{h,cc}`; `session.h` is
`tpu_sync/kv_cache/transfer_session.h` (`StagingLayerManager`) and
`tpu_sync/transport/transfer_session.h` is the `TransferSession` interface;
`mgr.cc` is `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`;
`base.h`/`base.cc` are `tpu_sync/kv_cache/kv_cache_manager_base.{h,cc}`;
`raw_core.h` is `tpu_sync/core/raw_transfer_core.h`; `bt.cc` and `bts.cc` are
`tpu_sync/transport/block_transport.cc` and
`tpu_sync/transport/block_transport_session.cc`; `utils.h` is
`tpu_sync/core/utils.h`; `reshard_recv_test.cc` is
`tpu_sync/kv_cache/reshard_receive_session_test.cc`; and `pool_reshard_test.cc`
is `tpu_sync/kv_cache/kv_cache_manager_with_transfer_pool_reshard_test.cc`.
Exact line ranges for every symbol, sub-block, and test are in the generated
`## Source map` table below.

## How a reshard receive runs

`KVCacheManagerWithTransfer::PoolReshardRegisterRecv` first looks the plan's
uuid up in the manager's single `sessions_` map — an incumbent that is `Done()`
is retired (`RetireSettledSessionLocked`), one that is not is refused — and
claims the uuid in `pending_pool_reshard_recvs_` (a second registration racing
`Create` is refused with `AlreadyExistsError`, `Reshard/PoolStaging.lean`). It
then creates a `ReshardReceiveSession` (`ReshardReceiveSession::Create`,
`ReshardReceiveSession::ReshardReceiveSession`), which builds the receiver's
`TransferPlan` and acquires bounded per-UUID `PoolStagingLease`s across the
plan's destination storages (`ReshardReceiveSession::AcquireStagingLeases`),
inserts the session into `sessions_` (`sessions_[plan.uuid()] = recv_session;`,
dropping the pending claim in the same lock) and calls `Start()`, which for a
receive does nothing. Each transferred pool in `expected_pool_indices_` has an
order rank in `pool_order_ranks_`
(`pool_order_ranks_[static_cast<size_t>(pool_idx)] = group.order_rank()` in
`ReshardReceiveSession::ReshardReceiveSession`).

As incoming push streams arrive at the destination's per-uuid
`BlockTransportServerPushSession` (`StartStream`, reached from
`BlockTransport::HandleIncomingPush`, then `CompleteIncomingPush`), each stream
takes a receive op through `BeginIncomingPush` (`delegate->GetSession(uuid)`
then `ReshardReceiveSession::TryBeginOp`) and releases it through
`EndIncomingPush` (`ReshardReceiveSession::EndOp`, preceded by
`session->Finish(status)` when the stream failed). When all `expected_pushes`
streams for a pool have landed, the push session fires
`delegate_->OnPoolReceived(l, uuid_)` → `KVCacheManagerBase::OnPoolReceived`,
which resolves the uuid's session (`GetSession`, `kNotFound` if there is none)
and calls `OnDataReceived(pool_idx, {}, {})` →
`ReshardReceiveSession::OnPoolReceived`, which records the pool in
`started_pool_indices_` (`ReshardReceiveSession::RecordPoolReceivedLocked`) and
calls `ReshardReceiveSession::ExecuteEligiblePoolH2ds`.

`ExecuteEligiblePoolH2ds` selects under `mu_` every started, unlaunched pool
whose strictly lower-rank prerequisite pools are all in
`completed_pool_indices_` (`ReshardReceiveSession::CollectEligiblePoolH2dsLocked`),
marks them in `h2d_launched_pools_`, and adds `to_launch.size()` to `in_flight_`
(`in_flight_ += static_cast<int32_t>(to_launch.size())`). Outside `mu_`, it
loops over `to_launch`: for each pool it re-checks `if (done_ || draining_)`
under `mu_` (calling `EndRecvOpLocked()` and skipping the upload if the session
finished in the window), resolves the pool's host buffer
(`LookupStagingSlot`, §"Bounded host layer staging"), dispatches
`base_->H2dPoolBlocks` into it, and attaches `FinishPoolH2d` + `EndOp` to
`future.OnReady`; an empty destination list, a missing buffer or a synchronous
`H2dPoolBlocks` error runs `FinishPoolH2d(pool_idx, status)` and `EndOp()`
inline.

When a pool's H2D finishes, `ReshardReceiveSession::FinishPoolH2d` calls
`ReshardReceiveSession::RecordPoolH2dResultLocked`. On an intermediate OK
completion (`if (!finished && status.ok())`), it calls
`ExecuteEligiblePoolH2ds()` to launch the next rank wave before the outer
`future.OnReady` callback's `self->EndOp()` releases the completed pool's op.
On the first error or when `completed_pool_indices_ == expected_pool_indices_`,
`reshard_finalizing_` is set (`finished = true`), `should_record_duration = true`
is latched on success, and `Finish(terminal_status)` drains the session.

**Plan lifetime.** The plan is the session's own `transfer_plan_`:
`ReshardReceiveSession::plan()` returns it until `Done()` and `absl::nullopt`
afterwards, and the manager resolves it only through `GetSession(uuid)`
(`KVCacheManagerBase::GetTransferPlan`, `GetBlockChunks`). So the plan is
visible exactly while the session is in `sessions_` and not settled, and it
goes with the staging in the same `mu_` scope (`FinishLocked` /
`EndRecvOpLocked` setting `done_`); there is no separate unregistration step.
`KVCacheManagerWithTransfer::UnregisterActivePlan` on a reshard receive calls
`Finish(Cancelled)` if it is not `Done()` (`cancel`) and leaves it in
`sessions_` for the poll; `RetireSettledSessionLocked` erases a `Done()`
session when it reports it (`publish`). `~KVCacheManagerWithTransfer` calls
`Finish(Cancelled)` on every session under `mu_`, then `AwaitForDone()` on each.

## State

The settle protocol itself is `Transfer.Lifecycle` (`in_flight_`, `draining_`,
`done_`, `status_.ok()`, and `!staging_released_`). On top of it, each expected
pool is a `Pool := ⟨rank, stage⟩` in `pools : List Pool`:

| Pool stage   | C++ membership (`ReshardReceiveSession`)             | Holds op in `in_flight_` |
|--------------|------------------------------------------------------|--------------------------|
| `.waiting`   | in `expected_pool_indices_`, not yet in `started_pool_indices_` | no |
| `.received`  | in `started_pool_indices_`, not yet in `h2d_launched_pools_` | no |
| `.queued`    | in `h2d_launched_pools_` after `in_flight_ += static_cast<int32_t>(to_launch.size())` (`CollectEligiblePoolH2dsLocked`, `ExecuteEligiblePoolH2ds`), before the per-pool re-check lock (`if (done_ || draining_)`) | yes |
| `.issued`    | `H2dPoolBlocks` succeeded; the copy is running on the device (`future.OnReady` attached) | yes |
| `.ready`     | the copy finished; the `OnReady` continuation has not run yet | yes |
| `.completed` | in `completed_pool_indices_` (`RecordPoolH2dResultLocked`) and `self->EndOp()` ran (`ExecuteEligiblePoolH2ds`'s `future.OnReady`) | no |
| `.aborted`   | op ended without completing: skipped at re-check (`EndRecvOpLocked()`), or `LookupStagingSlot`/`H2dPoolBlocks`/`OnReady` failed or saw `reshard_finalizing_` | no |

Session-level fields:

| Field              | C++                                                                 | Role |
|--------------------|---------------------------------------------------------------------|------|
| `pools`            | `expected_pool_indices_`, `pool_order_ranks_`, `started_pool_indices_`, `h2d_launched_pools_`, `completed_pool_indices_` and the pending `OnReady` continuations | per-pool state |
| `life`             | `in_flight_`, `draining_`, `done_`, `status_`, `!staging_released_` (`ReshardReceiveSession`) | `Transfer.Lifecycle` |
| `finalizing`       | `reshard_finalizing_` (`ReshardReceiveSession`)                     | stops further H2D launches and results after first error or full completion |
| `durationRecorded` | ghost (`should_record_duration` / `RecordTransferDuration` in `FinishPoolH2d`) | end-of-transfer latency histogram recorded |
| `published`        | the session's terminal as `RetireSettledSessionLocked` hands it to `RecordPoolReshardTerminalLocked`: membership in `done_recving_` / `failed_recving_` for a single-plan request (`sub_plan_count <= 1`), or the sub-plan's entry in the request's `recv_chains_` record | what `poll_stats()` shows the engine |
| `pushes`           | ghost                                                               | incoming pushes between `TryBeginOp` (`BeginIncomingPush`) and `EndOp` (`EndIncomingPush`) |

## Events

| Event               | C++ |
|---------------------|-----|
| `pushBegin`         | `ReshardReceiveSession::TryBeginOp` from `BeginIncomingPush` (`delegate->GetSession(uuid)`, then `session->TryBeginOp()`), called in `BlockTransportServerPushSession::StartStream` (`BeginIncomingPush(delegate_, header.uuid)`) and `HandlePeregrinePost` |
| `pushEnd ok`        | `EndIncomingPush(session, status)`, called in `BlockTransportServerPushSession::StartStream` (directly on success, or from the `end_incoming_push` cleanup with `InternalError("Incoming push failed")`). Parameterized by `PushEndPolicy`: `.finishOnError` (shipping) calls `session->Finish(status)` before `session->EndOp()` on `ok = false` (`if (!status.ok())`, the same for every session type), whereas `.endOpOnly` (mutant) runs `EndOp()` unconditionally |
| `onPoolReceived p`  | `ReshardReceiveSession::OnPoolReceived` (via `KVCacheManagerBase::OnPoolReceived` → `OnDataReceived`) + `ExecuteEligiblePoolH2ds` first lock (`to_launch = CollectEligiblePoolH2dsLocked()`): records `p` in `started_pool_indices_` and batch-queues every eligible started pool |
| `h2dIssue p ok`     | `ExecuteEligiblePoolH2ds` loop body (`for (auto& [pool_idx, dst_chip_block_ids] : to_launch)`): re-checks `if (done_ || draining_)` under `mu_`, otherwise resolves the host buffer and dispatches `base_->H2dPoolBlocks` |
| `h2dReady p`        | device finishes pool `p`'s H2D copy; its `OnReady` continuation is pending |
| `h2dDone p ok`      | `ExecuteEligiblePoolH2ds`'s `future.OnReady` callback calling `FinishPoolH2d` and `EndOp` (and returning the pool's host buffer, `staging_layer_manager_.Release(pool_idx)`) |
| `cancel`            | external `Finish(error)`: deadline (`CompleteReadWithDetails`), shutdown (`~KVCacheManagerWithTransfer`), `UnregisterActivePlan`, or a staging wait that timed out (`FinishLocked(slot.status())` in `AcquireStagingSlot`) |
| `publish`           | `CompleteReadWithDetails` retires a settled session (`RetireSettledSessionLocked`: `reshard_recv->Done()`) through `RecordPoolReshardTerminalLocked` — into `done_recving_` or `failed_recving_` for a single-plan request, or into the request's `recv_chains_` entry for a sub-plan of a chain (the request reaches `done_recving_` when its last sub-plan settles and `failed_recving_` at its first failed sub-plan) — and erases it from `sessions_`; after the manager lock the poll drops the uuid's push progress and any remaining pool staging leases (`ForgetPushProgress`, `ReleasePoolStagingLeases`) |

## Lock scopes

Every mutable field of `ReshardReceiveSession` is `ABSL_GUARDED_BY(mu_)`
except `staging_layer_manager_` (its own mutex) and the atomic `cancelled_`;
`base_`, `deadline_`, `start_time_`, and `transfer_plan_` (whose request
supplies the uuid and req_id) are `const`.

| Event | `mu_` scopes | Between them |
|---|---|---|
| `pushBegin` | 1: `ReshardReceiveSession::TryBeginOp` (`if (done_ || draining_) return false; ++in_flight_;`), after `GetSession` looked the uuid up in `sessions_` under manager `mu_` | — |
| `pushEnd ok` | 2–4 in `EndIncomingPush`: on `ok = false` under `.finishOnError`, `session->Finish(status)`; then `session->EndOp()`; followed by `0–1` read-only `GetStatus()` scopes for the return value | `EndOp` tail, below |
| `onPoolReceived p` | 2: `ReshardReceiveSession::OnPoolReceived` checks `if (done_)` and calls `RecordPoolReceivedLocked(pool_idx)`, then `ExecuteEligiblePoolH2ds` checks `if (done_ || draining_)` and runs `to_launch = CollectEligiblePoolH2dsLocked(); in_flight_ += static_cast<int32_t>(to_launch.size());` | folded into one event by A4 |
| `h2dIssue p ok` | 1–6 in `ExecuteEligiblePoolH2ds`: re-check lock (`if (done_ || draining_) { ... EndRecvOpLocked(); continue; }`, 1 scope when draining), then `LookupStagingSlot` (1 read-only scope) and the unlocked `base_->H2dPoolBlocks`; on `ok = true`, nothing more before `future.OnReady` is attached; on `ok = false`, `FinishPoolH2d` (1 or 3 scopes) and `EndOp()` (1 scope) | pool `p`'s op in `in_flight_` is already counted before `H2dPoolBlocks`; on `ok = false`, the `reshard_finalizing_` latch and `EndOp` tail below apply |
| `h2dReady p` | 0 (device) | — |
| `h2dDone p ok` | 2–5 in `ExecuteEligiblePoolH2ds`'s `future.OnReady` callback: `FinishPoolH2d` locks `mu_` once for `if (done_) return;` and `finished = RecordPoolH2dResultLocked(pool_idx, status);`; on `!finished && status.ok()` it runs `ExecuteEligiblePoolH2ds`'s opening lock (1 scope, folded by A4), on `finished` it latches `terminal_status` or `should_record_duration = true;` and calls `Finish(terminal_status)` (2 scopes), and on `!finished && !status.ok()` (when `reshard_finalizing_` was already set) neither branch runs; then `self->EndOp()` (1 scope) | see the `reshard_finalizing_` latch, wave launch, and `EndOp` tail notes below |
| `cancel` | 1–3: `ReshardReceiveSession::Finish(error)` (`FinishLocked`), called directly in `~KVCacheManagerWithTransfer` (1 scope, under manager `mu_`), after `!session->IsDraining()` and `reshard_recv->deadline() <= now` in `CompleteReadWithDetails` (2 scopes), after an unlocked `session->Done()` in `UnregisterActivePlan` (2–3 scopes), or as `FinishLocked(slot.status())` inside `AcquireStagingSlot`'s closing scope | `cancel` has no `!draining` guard, admitting every interleaving; late errors, below |
| `publish` | 2 in `RetireSettledSessionLocked` (under manager `mu_`): `reshard_recv->Done()` and `reshard_recv->GetStatus()` (passed to `RecordPoolReshardTerminalLocked`) before `sessions_.erase(it)` | on a settled session only `status_` can still change; late errors, below |

**`reshard_finalizing_` latch in `FinishPoolH2d`.** When `RecordPoolH2dResultLocked`
returns `finished == true`, it has already set `reshard_finalizing_ = true`
under the first `mu_` scope. Any concurrent `FinishPoolH2d` or
`CollectEligiblePoolH2dsLocked` before `Finish(terminal_status)` sees
`reshard_finalizing_ == true` and is a no-op, while the caller's pool op keeps
`in_flight_ >= 1` until `self->EndOp()`.

**Wave launch inside `FinishPoolH2d` before `self->EndOp()`.** On an
intermediate OK completion (`!finished && status.ok()`), `FinishPoolH2d` calls
`ExecuteEligiblePoolH2ds()` before returning to the outer callback's
`self->EndOp()`. In `h2dDone p true`, `launchEligible` folds the opening
lock of `ExecuteEligiblePoolH2ds` (which adds `to_launch.size()` to `in_flight_`)
with pool `p`'s `self->EndOp()`, leaving the per-pool `to_launch` loop to
subsequent `h2dIssue` steps: while that loop runs, pool `p`'s unreleased op only
keeps `in_flight_` higher by 1 until `self->EndOp()`, commuting with
`h2dIssue` for the same reason as any `EndOp` tail.

**`EndOp` tail.** Before `EndOp()`, the caller's op keeps `in_flight_ >= 1` and
`done_ = false`, so `EndOp()` commutes with any interleaved step; when it is
the last op of a draining session, `EndRecvOpLocked` releases the staging and
sets `done_` (after which `plan()` is empty) in the same scope.

**Late error after settle.** `ReshardReceiveSession::FinishLocked` updates
`if (!status.ok() && status_.ok()) status_ = status;` before
`if (draining_) return;`, so a late `Finish(error)` after an OK settle still
flips `status_` to the error (`cancel` has no `!draining` guard).

**Bounded host layer staging.** The model omits host layer buffer leases: each
declared pool transitions independently, corresponding to
`KVCacheManagerBase::num_host_layers()` being at least the plan's transferred
pool count (for one pool per storage, the default
`num_host_layers() == num_layers()` mirror; `num_staging_layers` bounds
`num_host_layers()`, and a multi-tag plan whose pools share storages can exceed
`num_layers()` even on the full mirror). In C++, `ReshardReceiveSession`
constructs its `StagingLayerManager` (`session.h`) with `num_host_layers()`
slots and leases one buffer per pool index unconditionally: each incoming push
chunk's `KVCacheManagerBase::GetBlockChunks` (inside the push's op, from
`StartStream`'s payload loop) calls `session->ResolveStagingSlot(layer_idx)` →
`ReshardReceiveSession::AcquireStagingSlot`, which takes an op of its own
(`if (done_ || draining_)` refusal, `++in_flight_`, the pattern of
`TryBeginOp`), waits in `StagingLayerManager::Acquire` until a buffer is free,
the pool already holds one, `deadline_` passes or `cancelled_` is set
(`FinishLocked` sets `cancelled_` and calls
`staging_layer_manager_.Shutdown()` to wake waiters), then under `mu_` fails
the receive on a timeout (`FinishLocked(slot.status())`), returns a buffer won
by a draining session, and ends its op (`EndRecvOpLocked()`).
`ExecuteEligiblePoolH2ds` reads the leased buffer (`LookupStagingSlot`, failing
with `FailedPrecondition` if the pool holds none and `Cancelled` on a draining
session) and dispatches with it as `host_layer_idx`; the buffer is returned on
each early return, by the H2D callback (`staging_layer_manager_.Release(pool_idx)`
around `FinishPoolH2d`), and wholesale at settle (`ReleaseStagingLocked` →
`ReleaseAll()`). None of the safety invariants (`Safe`) changes when pools
outnumber `num_host_layers()`: the extra op is nested inside the push's op on
the push thread (taken after `pushBegin`, ended before the stream's
`CompleteIncomingPush` and `EndIncomingPush`), so `in_flight_` is transiently
one higher while `pushes > 0` already holds and every settle decision is the
one the model makes; a timeout fails the receive, which is `cancel` before
`pushEnd` (the unguarded `cancel` admits it), and a cancelled wait or a failed
`Lookup` fails the stream or the upload on a session that is already draining
(`pushEnd false`, `h2dIssue p false` with `reshard_finalizing_` or the re-check
first). Progress without hitting `deadline_` is narrower when transferred pools
exceed `num_host_layers()`: on a single `order_rank`, later pools wait behind
earlier pools' uploads, whereas across multiple `order_rank`s, gated
higher-rank pools whose first chunks arrive early can hold every buffer while a
lower-rank pool's push thread blocks in `StagingLayerManager::Acquire` until
`deadline_` fails the receive (`FinishLocked(slot.status())`), which the
slot-free model does not express (`ReshardReceiveSessionTest.BoundedStagingSlotAcquisitionAndRelease`
drives the wait, the cancel and the timeout through
`ReshardReceiveSessionTestPeer`; `Coverage.lean` pairs its session-level
effects).

## Assumptions

* **A1 (at-most-once `OnPoolReceived` per declared pool).**
  `BlockTransportServerPushSession::CompleteIncomingPush` fires `delegate_->OnPoolReceived(l, uuid_)`
  only when `plan_pushes == expected_chunks` (under the push session's own
  `mu_`, with `layer_progress_` per uuid), and
  `ReshardReceiveSession::RecordPoolReceivedLocked` rejects undeclared or
  duplicate pool indices. Encoded as the `onPoolReceived p` guard
  `pool.stage == .waiting`. (Discharged in `Reshard/Pipeline.lean` by explicit
  stream counting.)
* **A2 (registration before visibility).** `PoolReshardRegisterRecv` claims the
  uuid in `pending_pool_reshard_recvs_` before `ReshardReceiveSession::Create`
  runs `AcquireStagingLeases`, and inserts the session into `sessions_` (where
  `GetSession` can find it) only after `Create` succeeded. If
  `AcquireStagingLeases` fails, `Create` calls `session->ReleaseStaging()` and
  the `absl::Cleanup` drops the pending claim before any push can find the
  uuid.
* **A3 (no double end).** Each push and each H2D op ends at most once: `pushEnd`
  requires `pushes > 0`, `h2dIssue p` requires `stage == .queued`, and
  `h2dDone p` requires `stage == .ready`.
* **A4 (fold of `RecordPoolReceivedLocked` / `RecordPoolH2dResultLocked` with
  `ExecuteEligiblePoolH2ds` first lock).** Between unlocking `mu_` after
  recording a pool (`RecordPoolReceivedLocked(pool_idx)` in `OnPoolReceived` or
  `RecordPoolH2dResultLocked(pool_idx, status)` in `FinishPoolH2d`) and locking
  `mu_` in `ExecuteEligiblePoolH2ds`, an external `Finish` produces the same
  state as `cancel` arriving before the event (`draining_ = true` causes
  `if (done_ || draining_) return;` to skip `CollectEligiblePoolH2dsLocked`,
  leaving eligible pools in `.received`), whereas a `Finish` arriving after
  `in_flight_ += static_cast<int32_t>(to_launch.size())` is `cancel` after the
  event (where the per-pool re-check `if (done_ || draining_) { ... EndRecvOpLocked(); continue; }`
  aborts each queued pool and releases its op).

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
* **Prompt settle (`SettlesPromptly`).** `draining → inFlight = 0 → done`.
* **Rank-wave ordering (`RankWaveOrder`).** For every pair of pools `p, q ∈ pools`,
  if `p` has launched (`p.stage.launched = true`) and `q.rank < p.rank`, then
  `q.stage = .completed`: no higher-rank pool is ever queued, issued, or
  completed before every strictly lower-rank pool has completed its H2D upload
  (`pool_order_ranks_` comment in `ReshardReceiveSession`,
  `CollectEligiblePoolH2dsLocked`).
* **Publication (`Publication`).** `published = some true → allCompleted pools ∧
  durationRecorded`: when `poll_stats()` reports `done_recving`, every expected
  pool has completed its H2D upload and the transfer duration metric has been
  recorded.
* **No op leak & termination (`NoOpLeak`, `reachable_can_settle`).** While
  `0 < inFlight`, some event in `drainEvents` is enabled, and every reachable
  state can drain to `done = true ∧ hasStaging = false` in a finite number of
  steps.

Plan visibility follows from these without state of its own: `plan()` has a
value exactly while `!done`, so `SettleSafe` says no push or upload — nothing
that resolves chunks or staging slots through the plan — is in flight once the
plan is gone, and `publish` (which erases the session from `sessions_`)
requires `done`.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `tpu_sync/transport/transfer_session.h` | `TransferSession` | `:35-109` |
| `session.h` | `StagingLayerManager` | `:40-75` |
| `reshard_recv.h` | `ReshardReceiveSession::Done` | `:73-76` |
| `reshard_recv.h` | `ReshardReceiveSession::Start` | `:79` |
| `reshard_recv.h` | `ReshardReceiveSession::TryBeginOp` | `:83-88` |
| `reshard_recv.h` | `ReshardReceiveSession::GetStatus` | `:91-94` |
| `reshard_recv.h` | `ReshardReceiveSession::IsDraining` | `:98-101` |
| `reshard_recv.h` | `ReshardReceiveSession::deadline` | `:104` |
| `reshard_recv.h` | `ReshardReceiveSession::OnDataReceived` | `:113-120` |
| `reshard_recv.h` | `ReshardReceiveSession::ResolveStagingSlot` | `:128-130` |
| `reshard_recv.h` | `ReshardReceiveSession::plan` | `:132-137` |
| `reshard_recv.h` | `ReshardReceiveSession` (`bool staging_released_` .. `std::atomic<bool> cancelled_`) | `:201-222` |
| `reshard_recv.cc` | `RecordTransferDuration` | `:62-65` |
| `reshard_recv.cc` | `ReshardReceiveSession::ValidatePlan` | `:69-146` |
| `reshard_recv.cc` | `ReshardReceiveSession::Create` | `:353-387` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReshardReceiveSession` | `:389-413` |
| `reshard_recv.cc` | `ReshardReceiveSession::AcquireStagingLeases` | `:415-454` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReleaseStagingLocked` | `:456-461` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReleaseStaging` | `:463-466` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishLocked` | `:468-480` |
| `reshard_recv.cc` | `ReshardReceiveSession::AcquireStagingSlot` | `:482-506` |
| `reshard_recv.cc` | `ReshardReceiveSession::LookupStagingSlot` | `:508-523` |
| `reshard_recv.cc` | `ReshardReceiveSession::Finish` | `:525-528` |
| `reshard_recv.cc` | `ReshardReceiveSession::EndRecvOpLocked` | `:536-546` |
| `reshard_recv.cc` | `ReshardReceiveSession::EndOp` | `:548-551` |
| `reshard_recv.cc` | `ReshardReceiveSession::RecordPoolReceivedLocked` | `:553-564` |
| `reshard_recv.cc` | `ReshardReceiveSession::CollectEligiblePoolH2dsLocked` | `:566-595` |
| `reshard_recv.cc` | `ReshardReceiveSession::RecordPoolH2dResultLocked` | `:597-610` |
| `reshard_recv.cc` | `ReshardReceiveSession::OnPoolReceived` | `:612-623` |
| `reshard_recv.cc` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` | `:625-689` |
| `reshard_recv.cc` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` (`to_launch = CollectEligiblePoolH2dsLocked();` .. `in_flight_ += static_cast<int32_t>(to_launch.size());`) | `:632-633` |
| `reshard_recv.cc` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` (`EndRecvOpLocked();`) | `:646` |
| `reshard_recv.cc` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` (`absl::StatusOr<size_t> slot = LookupStagingSlot(pool_idx);`) | `:660` |
| `reshard_recv.cc` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` (`future.OnReady`) | `:677-687` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishPoolH2d` | `:691-727` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishPoolH2d` (`finished = RecordPoolH2dResultLocked(pool_idx, status);`) | `:699` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishPoolH2d` (`should_record_duration = true;` .. `Finish(terminal_status);`) | `:718-721` |
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` | `:274-278` |
| `mgr.cc` | `KVCacheManagerWithTransfer::GetSession` | `:280-287` |
| `mgr.cc` | `KVCacheManagerWithTransfer::~KVCacheManagerWithTransfer` (`for (const auto& [uuid, session] : sessions_)`) | `:368-372` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RetireSettledSessionLocked` | `:436-511` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` | `:726-774` |
| `mgr.cc` | `KVCacheManagerWithTransfer::UnregisterActivePlan` | `:776-822` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`} else if (auto reshard_recv =` .. `absl::DeadlineExceededError("Pool reshard receive timed out"));`) | `:1029-1034` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`for (uint64_t uuid : retired_uuids)` .. `base_->ReleasePoolStagingLeases(uuid);`) | `:1061-1065` |
| `base.h` | `KVCacheManagerBase::AttachPlaceholderDeviceHoldForTest` | `:763` |
| `base.cc` | `KVCacheManagerBase::GetTransferPlan` | `:2724-2734` |
| `base.cc` | `KVCacheManagerBase::CopyPoolBlocks` | `:2552-2693` |
| `base.cc` | `KVCacheManagerBase::H2dPoolBlocks` | `:2703-2709` |
| `base.cc` | `KVCacheManagerBase::OnPoolReceived` | `:3022-3032` |
| `base.cc` | `KVCacheManagerBase::GetBlockChunks` (`absl::StatusOr<size_t> slot = absl::NotFoundError("session not found");` .. `} else if (!absl::IsNotFound(slot.status()) ||`) | `:3138-3144` |
| `raw_core.h` | `PjRtCopyFuture::OnReady` | `:514-568` |
| `raw_core.h` | `IssueH2dShard` | `:687-715` |
| `bt.cc` | `BlockTransport::HandleIncomingPush` | `:466-475` |
| `bts.cc` | `BeginIncomingPush` | `:286-300` |
| `bts.cc` | `EndIncomingPush` | `:302-315` |
| `bts.cc` | `BlockTransportServerPushSession::StartStream` | `:345-478` |
| `bts.cc` | `BlockTransportServerPushSession::CompleteIncomingPush` | `:526-695` |
| `utils.h` | `ValidateCommonPoolReshardPlan` | `:353-469` |
| `utils.h` | `ValidatePoolBlockBounds` | `:473-489` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.AcceptsCanonicalPlanOnExplicitPools` | `:158-166` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.AcceptsImplicitPools` | `:168-175` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.HasNoTagPolicy` | `:177-185` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.RejectsMissingIdentityAndPoolFields` | `:187-219` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.RejectsOutOfRangeDuplicateAndDtypeMismatch` | `:221-246` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.RejectsBlockIdsOutsideDeclaredPool` | `:278-297` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.GroupScopesDestinationBlocks` | `:426-460` |
| `reshard_recv_test.cc` | `ReshardReceiveSessionTest.BoundedStagingSlotAcquisitionAndRelease` | `:462-540` |
| `pool_reshard_test.cc` | `PoolReshardRecvTestPeer` | `:52-57` |
| `pool_reshard_test.cc` | `PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints` | `:317-333` |
| `pool_reshard_test.cc` | `PoolReshardRecvTest.FinishPoolReshardRecvRecordsDurationMetric` | `:373-393` |
| `pool_reshard_test.cc` | `PoolReshardRecvTest.FinishPoolReshardRecvDoesNotRecordMetricOnFailure` | `:395-413` |
| `pool_reshard_test.cc` | `DeviceBackedTestBase` | `:643-656` |
| `pool_reshard_test.cc` | `BoundedPoolTestManager` | `:658-669` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.DuplicatePoolRecvRegistrationKeepsOriginalStagingLease` | `:671-721` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.ConcurrentDuplicatePoolRecvRegistrationKeepsWinnerStagingLease` | `:723-779` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.StagingAcquireFailureReleasesUuidClaim` | `:781-811` |
| `pool_reshard_test.cc` | `PoolReshardRecvTest.FailedIncomingPushReleasesStagingLeaseBeforeDeadline` | `:813-851` |
| `pool_reshard_test.cc` | `SubPlanChainTest.ReceiveTerminalWaitsForTheLastSubPlan` | `:872-908` |
| `pool_reshard_test.cc` | `SubPlanChainTest.FirstSubPlanFailureFailsTheRequestOnce` | `:910-933` |
| `pool_reshard_test.cc` | `SubPlanChainTest.RetryUnderTheSameReqIdIsTrackedAsANewChain` | `:935-978` |
| `pool_reshard_test.cc` | `SubPlanChainTest.StalledChainFailsAfterTheTransferTimeout` | `:980-1002` |
| `pool_reshard_test.cc` | `SubPlanChainTest.SinglePlanRequestsReportAtOnce` | `:1004-1016` |
| `pool_reshard_test.cc` | `PoolReshardSessionLookupTest.GetSessionResolvesActiveReshardRecvUntilRetired` | `:1018-1050` |
| `pool_reshard_test.cc` | `PoolReshardSessionLookupTest.PoolCompletionWithoutReceiverIsNotFound` | `:1088-1103` |
| `pool_reshard_test.cc` | `PoolReshardSessionLookupTest.PoolCompletionOnLegacyArmedReceiverFailsWithoutH2d` | `:1108-1129` |
<!-- source-map:end -->
-/
