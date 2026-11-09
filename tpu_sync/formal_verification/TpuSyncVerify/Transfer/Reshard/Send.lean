import TpuSyncVerify.Transfer.Reshard.Send.Model
import TpuSyncVerify.Transfer.Reshard.Send.Lemmas
import TpuSyncVerify.Transfer.Reshard.Send.Invariant
import TpuSyncVerify.Transfer.Reshard.Send.Progress
import TpuSyncVerify.Transfer.Reshard.Send.Traces
import TpuSyncVerify.Transfer.Reshard.Send.Coverage

/-!
# Reshard send session

One `ReshardSendSession` on the producer side and the slice of
`KVCacheManagerWithTransfer` that drives it (`PoolReshardPush`,
`CountPoolReshardSendSlots`, and the `CompleteReadWithDetails` poll). Receiver
sessions live in `Reshard/Receive.lean`; multi-sender stream counting and
aliased-page contents compose both in `Reshard/Pipeline.lean`.

In the source-map table below, `reshard_send.cc` is
`tpu_sync/kv_cache/reshard_send_session.cc` (which holds the class
`ReshardSendSession` behind the factory `CreateReshardSendSession` declared in
`tpu_sync/kv_cache/reshard_send_session.h`); `reshard_recv.cc` is
`tpu_sync/kv_cache/reshard_receive_session.cc`; `session.h` is
`tpu_sync/kv_cache/transfer_session.h` (`StagingLayerManager`) and
`tpu_sync/transport/transfer_session.h` is the `TransferSession` interface;
`slots.cc` is `tpu_sync/core/pool_reshard_send_slots.cc`; `mgr.cc` is
`tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`; `base.h` and `base.cc`
are `tpu_sync/kv_cache/kv_cache_manager_base.{h,cc}`; `raw_core.h` is
`tpu_sync/core/raw_transfer_core.h`; `bt.cc` is
`tpu_sync/transport/block_transport.cc`; `utils.h` is
`tpu_sync/core/utils.h`; `pool_layout.cc` is `tpu_sync/kv_cache/pool_layout.cc`;
`reshard_send_test.cc` is `tpu_sync/kv_cache/reshard_send_session_test.cc`; and
`pool_reshard_test.cc` is
`tpu_sync/kv_cache/kv_cache_manager_with_transfer_pool_reshard_test.cc`.

## How a reshard send runs

`KVCacheManagerWithTransfer::PoolReshardPush` first looks the plan's uuid up in
the manager's single `sessions_` map: an incumbent that is `Done()` is retired
(`RetireSettledSessionLocked`, which reports it through
`RecordPoolReshardTerminalLocked` and erases it), one that is not is refused
(`AlreadyExistsError`). It then creates a `ReshardSendSession`
(`CreateReshardSendSession`), which validates the plan
(`ReshardSendSession::ValidatePlan`), computes
`remaining_pool_peer_pushes_ = CountPoolReshardSendSlots(plan, schedule)` and
builds the session's `TransferPlan`; inserts the session into `sessions_` as a
`SessionEntry` carrying the plan's `req_id` and `SessionRole::kPoolReshardSend`
(recording it in the request's `sub_plan_chains_` entry,
`NoteSubPlanRegisteredLocked`, when the plan is a sub-plan of a chain); and
calls `state->Start()`. The model is one such session — one plan `uuid`, which
for a windowed request is one sub-plan of its chain (`Pipeline.lean` §"Scope:
one plan"; multi-window chaining and worker terminal folding are modelled in
`Reshard/SubPlanChain.lean`).

`ReshardSendSession::Start` takes the caller op (`++in_flight_;`, refused with
the session's status once `done_ || finalizing_`), checks the preconditions
that need no waiting (`ValidatePushPreconditions`: a running transport server,
`num_host_layers() > 0`, every transfer pool index resolving) and detaches a
pipeline thread that runs `ExecutePushPipeline(src_ids)` and then `EndOp()`.
A precondition failure, or a `std::system_error` from `std::thread`, is
reported synchronously: `RecordPushCompletion(status)` latches `finalizing_`,
the `absl::Cleanup` `EndOp()` settles the send, and `Start` returns the error
(`startFail`).

`ReshardSendSession::ExecutePushPipeline` orders the plan's
`transfer_pool_indices()` by their group's `order_rank` (`std::stable_sort`) and
iterates:
* Pools whose group has no entries on this sender are skipped
  (`if (pool_src_block_ids.empty())`), matching `CountPoolReshardSendSlots`
  (`if (it == peers_by_group.end()) continue;`).
* For each active pool it leases a host staging buffer
  (`AcquireStagingSlot(pool_idx)`, §"Bounded host layer staging"), re-checks
  `done_ || finalizing_` under `mu_` (returning the buffer and the loop if set),
  acquires a per-UUID `PoolStagingLease` on the pool's storage
  (`AcquirePoolStagingLease`) and issues `base_->D2hPoolBlocks` into that
  buffer. On a synchronous failure of any step it calls
  `RecordPushCompletion(status)` and returns from the loop; the thread's
  `EndOp()` then ends the caller op.
* On success it pushes the D2H future to `d2h_futures_`, increments
  `++in_flight_` under `mu_`, and attaches `StartPoolPush` + `EndOp` to
  `pool_future.OnReady`.
* When the loop completes, the pipeline thread releases its caller op via
  `EndOp()`.

When a pool's D2H copy completes, `ReshardSendSession::StartPoolPush` checks
`done_ || finalizing_` under `mu_`, adds `transfers_by_peer.size()` (the number
of distinct destination peers for the pool's group) to `in_flight_`, and
dispatches one `BlockTransport::AsyncPush` per peer, whose `OnReady` callback
calls `RecordPushCompletion` and `EndOp` (the last callback of the pool also
returns the pool's staging buffer).

`ReshardSendSession::RecordPushCompletion` returns early if
`done_ || finalizing_`. Otherwise, on the first error (`!status.ok()`) or when
`--remaining_pool_peer_pushes_ == 0`, it latches `finalizing_ = true` (and
wakes any staging wait: `cancelled_`, `staging_layer_manager_.Shutdown()`).
When `EndOp()` decrements `in_flight_` to `0` while `finalizing_`,
`ReshardSendSession::SettleLocked` releases the pool staging leases and host
buffers (`ReleaseLeasesLocked`) and sets `done_ = true`.

**Plan lifetime.** The plan is the session's own `transfer_plan_`:
`ReshardSendSession::plan()` returns it until `Done()` and `absl::nullopt`
afterwards, and the manager resolves it only through `GetSession(uuid)`
(`KVCacheManagerBase::GetTransferPlan`, `GetBlockChunks`'s
`return plan->ResolvePlanBlockChunks(`). So the plan is visible exactly while
the session is in `sessions_` and not settled; there is no separate
unregistration step. `KVCacheManagerWithTransfer::UnregisterActivePlan` on a
reshard send only calls `Finish(Cancelled)` if it is not `Done()` (`cancel`);
the session leaves `sessions_` when `RetireSettledSessionLocked` reports it
(`publish`). `~KVCacheManagerWithTransfer` calls `Finish(Cancelled)` on every
session under `mu_`, then `AwaitForDone()` on each.

## State

The settle protocol `(in_flight_, finalizing_, done_, status_.ok(), !leases_released_)`
is an exact instance of `Transfer.Lifecycle` (`ReshardSendSession::IsDraining`
returns `finalizing_`). Each active pool with `peers > 0` scheduled peer pushes
is a `SendPool := ⟨peers, stage⟩`:

| Pool stage    | C++ (`ReshardSendSession::ExecutePushPipeline`, `StartPoolPush`)     | Holds ops in `in_flight_` | Remaining push slots |
|---------------|----------------------------------------------------------------------|---------------------------|----------------------|
| `.pending`    | not yet reached by the pipeline loop (`for (size_t pool_idx : ordered_pools)`) | `0` | `peers` |
| `.d2h`        | `D2hPoolBlocks` succeeded (`++in_flight_`); `OnReady` not yet finished | `1`          | `peers`              |
| `.pushing k`  | `StartPoolPush` added `peers` ops (`in_flight_ += static_cast<int>(transfers_by_peer.size());`) and released the D2H op; `k` peer `AsyncPush` callbacks remain in flight | `k` | `k` |
| `.aborted`    | staging, lease or D2H failed, or `StartPoolPush` returned early on `done_ || finalizing_` | `0`                   | `0`                  |

Session-level fields:

| Field              | C++ (`ReshardSendSession`, `KVCacheManagerWithTransfer`)            | Role |
|--------------------|---------------------------------------------------------------------|------|
| `pools`            | active pools in `transfer_pool_indices()` and their D2H/push state  | per-pool state |
| `life`             | `in_flight_`, `finalizing_`, `done_`, `status_`, `!leases_released_` | `Transfer.Lifecycle` |
| `execActive`       | the caller op between `Start`'s `++in_flight_;` and the pipeline thread's (or `Start`'s `absl::Cleanup`) `EndOp()` | caller op active |
| `remainingPushes`  | `remaining_pool_peer_pushes_`                                       | remaining `(pool, peer)` completions |
| `published`        | the session's terminal as `RetireSettledSessionLocked` hands it to `RecordPoolReshardTerminalLocked` (with the `req_id` of its `SessionEntry`): membership in `done_sending_` / `failed_recving_` for a single-plan request (`sub_plan_count <= 1`), or the sub-plan's entry in the request's `sub_plan_chains_` record | what `poll_stats()` shows the engine |

## Events

| Event              | C++ |
|--------------------|-----|
| `startFail`        | `Start` failing before the pipeline thread runs (`ValidatePushPreconditions` error, or `std::thread` throwing): `RecordPushCompletion(status)` + the `absl::Cleanup` `EndOp()` |
| `d2hIssue p ok`    | `ExecutePushPipeline` loop body for pool `p` (`AcquireStagingSlot` .. `pool_future.OnReady`): leases a host buffer and a `PoolStagingLease`, calls `D2hPoolBlocks`; on failure calls `RecordPushCompletion` and returns, the thread's `EndOp()` following |
| `execFinish`       | the pipeline thread's `EndOp()` after `ExecutePushPipeline` finished its pool loop |
| `d2hDone p ok`     | `pool_future.OnReady` callback + `StartPoolPush` + `EndOp()` |
| `pushDone p ok`    | one peer's `AsyncPush(...).OnReady` callback for pool `p`: calls `RecordPushCompletion` + `EndOp()` |
| `cancel`           | external `Finish(error)`: deadline (`CompleteReadWithDetails`, `session->deadline() <= now`), shutdown (`~KVCacheManagerWithTransfer`) or `UnregisterActivePlan`; a no-op once `done_ || finalizing_` |
| `publish`          | `CompleteReadWithDetails` retires a settled session (`RetireSettledSessionLocked`, on the entry's `SessionRole::kPoolReshardSend`) through `RecordPoolReshardTerminalLocked` (into `done_sending_` or `failed_recving_` for a single-plan request; into the request's `sub_plan_chains_` entry for a sub-plan of a chain, which reaches `done_sending_` when the last sub-plan settles and `failed_recving_` at the first failed sub-plan) and erases it from `sessions_` |

## Lock scopes

Every mutable field of `ReshardSendSession` is `ABSL_GUARDED_BY(mu_)` except
`staging_layer_manager_` (its own mutex) and the atomic `cancelled_`; `base_`,
`src_block_ids_`, `parallelism_`, `deadline_`, `dst_peers_`,
`data_connection_reuse_`, and `transfer_plan_` (whose request supplies the
uuid and plan) are `const`. `ReshardSendSession::EndOp` is one `mu_`
scope, the `while (true)` decrement/settle scope — two under `kPerTransfer`
when `release_due` holds (A4).

| Event | `mu_` scopes | Between them |
|---|---|---|
| `startFail` | 2–3 in `ReshardSendSession::Start`: `++in_flight_;` was `init`; after the unlocked `ValidatePushPreconditions` (or the failed `std::thread` construction), `RecordPushCompletion` (1 scope) then the `absl::Cleanup` `EndOp()` (1–2 scopes) | the caller op keeps `in_flight_ >= 1` throughout |
| `d2hIssue p ok` | 2–6 in `ReshardSendSession::ExecutePushPipeline`: `AcquireStagingSlot` (0–2 scopes around the unlocked `StagingLayerManager::Acquire`), the re-check `if (done_ || finalizing_)` (1 scope), then after the unlocked `AcquirePoolStagingLease` and `D2hPoolBlocks`: on `ok = true`, 1 scope (`d2h_futures_.push_back(pool_future); ++in_flight_;`) before `pool_future.OnReady`; on `ok = false`, `RecordPushCompletion` (1 scope) and the thread's `EndOp()` (1–2 scopes) after the early return (`execActive = false`) | the caller op keeps `in_flight_ >= 1` throughout the pipeline; the re-check does not close the window, below |
| `execFinish` | 1–2: the pipeline thread's `EndOp()` after `ReshardSendSession::ExecutePushPipeline` returns | `EndOp` tail, below |
| `d2hDone p ok` | 2–5 in `pool_future.OnReady`: on `ok = false` (or `transport_srv == nullptr`), `RecordPushCompletion` (1 scope) + `absl::Cleanup` `EndOp()` (1–2 scopes); on `ok = true`, `StartPoolPush` checks `if (done_ || finalizing_)` on entry and again when adding `in_flight_ += static_cast<int>(transfers_by_peer.size());` (1–2 scopes, folded by A3), dispatches `AsyncPush` per peer outside `mu_`, and runs `EndOp()` (1–2 scopes) | the D2H op and (on `ok = true`) the added peer ops keep `in_flight_ >= 1` until `EndOp()`; `EndOp` tail, below |
| `pushDone p ok` | 2–3 in `StartPoolPush`'s `AsyncPush(...).OnReady` callback: `RecordPushCompletion` (1 scope) followed by `absl::Cleanup` `EndOp()` (1–2 scopes) | the peer op keeps `in_flight_ >= 1` until `EndOp()`; `EndOp` tail, below |
| `cancel` | 1–2: `ReshardSendSession::Finish(error)`, called from `~KVCacheManagerWithTransfer` (1 scope, under the manager's `mu_`), `UnregisterActivePlan` (after an unlocked `session->Done()`), or after `!session->IsDraining()` and `session->deadline() <= now` in `CompleteReadWithDetails` (2 scopes) | `Finish` returns at `if (done_ || finalizing_) return;` before touching `status_`, so an interleaved finalize makes it the identity, matching `cancel` (`Lifecycle.finishOnceLocked`) |
| `publish` | 2 in `RetireSettledSessionLocked` (under manager `mu_`): `reshard->Done()` and `reshard->GetStatus()` (`const absl::Status status = reshard->GetStatus();`, passed to `RecordPoolReshardTerminalLocked`) before `sessions_.erase(it)` | on a settled session nothing changes (`Finish` and `RecordPushCompletion` both return at `done_`) |

**Caller and callback ops hold `in_flight_ >= 1` until `EndOp()`.** Throughout
`Start`, `ExecutePushPipeline`, `StartPoolPush`, and `RecordPushCompletion`, the
running caller or callback holds its own op in `in_flight_` (and `StartPoolPush`
adds `transfers_by_peer.size()` before dropping `mu_` to call `AsyncPush` and
`EndOp()`), so `done_` cannot become `true` before `EndOp()`'s decrement scope.

**The pipeline's re-check does not close the window.** `ExecutePushPipeline`
re-checks `done_ || finalizing_` after `AcquireStagingSlot` (and
`AcquireStagingSlot` itself refuses a draining session), but
`AcquirePoolStagingLease`, `D2hPoolBlocks` and the `++in_flight_` scope run
after it outside `mu_`. If an external `Finish(error)` or an earlier pool's
`RecordPushCompletion` sets `finalizing_ = true` in that gap, a D2H future is
still queued (`d2hIssue p true` while draining); the caller op keeps
`in_flight_ >= 1` so `SettleLocked()` cannot release leases while the pipeline
is still acquiring them, and the queued future aborts at `StartPoolPush`'s
entry check (`d2hDone p true` when draining). When the re-check does fire, the
loop returns without `RecordPushCompletion` (`d2hIssue p false` on a draining
session, where `RecordPushCompletion` would return at its first line anyway).

**`EndOp()` tail.** When `EndOp()` is the last op (`in_flight_ == 1 &&
finalizing_ && !done_`), under `kPerTransfer` its pre-decrement scope sets
`connections_released_ = true` (A4). Because `finalizing_ == true` and
`in_flight_ == 1` (owned by this `EndOp()` call), `execActive = false` and
`poolOps = 0`: no other op can run, `publish` is disabled (`done_ == false`),
and an interleaved `Finish(error)` is the identity (`cancel` after `EndOp()`).

**Bounded host layer staging.** The model omits host layer buffer leases: each
active pool's D2H and pushes proceed without slot contention, corresponding to
`KVCacheManagerBase::num_host_layers()` being at least the sender's active pool
count (for one pool per storage, the default
`num_host_layers() == num_layers()` mirror; `num_staging_layers` bounds
`num_host_layers()`, and a multi-tag plan whose pools share storages can exceed
`num_layers()` even on the full mirror). In C++, the send leases one buffer per
pool index from its `StagingLayerManager` (`session.h`) unconditionally:
`ExecutePushPipeline` calls `AcquireStagingSlot(pool_idx)` before the pool's
`AcquirePoolStagingLease` and `D2hPoolBlocks`, which refuses a draining session
with its status, waits in `StagingLayerManager::Acquire` until a buffer is
free, the pool already holds one, `deadline_` passes or `cancelled_` is set
(`RecordPushCompletion`, `Finish` and `SettleLocked` all set `cancelled_` and
call `staging_layer_manager_.Shutdown()` to wake waiters), and returns a buffer
won by a session that finalized meanwhile. The D2H copy is issued into that
buffer (`*host_slot` as `host_layer_idx`), the incoming pull of the pushed
bytes addresses it through `ResolveStagingSlot` → `LookupStagingSlot`, and the
buffer is returned on every early return, by the D2H callback on error, by the
pool's last `AsyncPush` callback (`last_for_pool`), and wholesale at settle
(`ReleaseAll()` in `ReleaseLeasesLocked`). Nothing proved here changes under
that mode: the wait sits inside `d2hIssue p _` on the pipeline thread while the
caller op already holds `in_flight_ >= 1`, so every settle decision is the one
the model makes; a timeout or a cancelled wait is `d2hIssue p false`
(`RecordPushCompletion(host_slot.status())`, the first error latching
`finalizing_`, as `ReshardSendSessionTest.PipelineSlotWaitTimeoutSettlesSendOutOfBand`
shows); and `LookupStagingSlot` fails only for a pool whose lease was already
returned, that is after the pool's pushes ended or the session settled. Pools
beyond the buffer count serialize behind earlier pools' pushes, which the
model does not track: `ReshardSendSessionTest.BoundedStagingSlotAcquisitionAndRelease`
drives three pools through one buffer (its second pool waits until the first
pool's push returns the buffer, its third pool's wait is woken by `Finish`) and
replays in `Coverage.lean` as one of the interleavings the slot-free model
admits.

## Assumptions

* **A1 (non-empty schedule with positive peer counts per active pool).**
  `CreateReshardSendSession` rejects plans with `remaining_pool_peer_pushes <= 0`,
  and `ExecutePushPipeline` skips any pool whose group has no entries on this
  sender (`if (pool_src_block_ids.empty())`), matching
  `CountPoolReshardSendSlots` (`if (it == peers_by_group.end()) continue;`).
  Modeled by `validPools (init peerCounts).pools = true` (`peerCounts ≠ []` and
  `∀ n ∈ peerCounts, 0 < n`).
* **A2 (`Start` runs before external `Finish`).** `PoolReshardPush` inserts the
  session into `sessions_` and immediately invokes `Start`, which increments
  `++in_flight_`. `init` starts at the end of that opening lock with
  `execActive = true` and `inFlight = 1`. (A `Finish` in the gap makes `Start`
  return the status without an op; the session is then already settled —
  `Finish` with `in_flight_ == 0` calls `SettleLocked()` — and outside the model.)
* **A3 (single `StartPoolPush` lock step).** `StartPoolPush` checks
  `done_ || finalizing_` on entry and again when adding
  `transfers_by_peer.size()` to `in_flight_`. Since the intermediate lines only
  inspect immutable plan fields and `base_->transport_server()`, the two checks
  fold into `d2hDone`.
* **A4 (per-transfer connection-release window in `EndOp`).** Under
  `DataConnectionReuse::kPerTransfer`, the `while (true)` loop in `EndOp`
  checks `in_flight_ == 1 && finalizing_ && !done_ && !connections_released_`,
  latches `connections_released_ = true`, drops `mu_` to call
  `ReleaseDataConnectionsAfterSend(base_->transport_server(), dst_peers_, uuid())`,
  and re-locks `mu_` to run `--in_flight_` and `SettleLocked()`. Because
  `finalizing_` is already `true` and `in_flight_` is `1` (held by this caller),
  no other op is in flight (`execActive = false` and `poolOps = 0`), no new op
  can be started, and a concurrent `Finish(error)` on a finalizing session is
  the identity, so the next loop iteration is guaranteed to reach
  `--in_flight_ == 0` and `SettleLocked()` with no observable change to any
  other modelled variable.

## Properties

All proved on every reachable state (`reachable_safe`) for any valid schedule
(`validSchedule peerCounts = true`):

* **Settle safety (`SettleSafe`).** `done → inFlight = 0`.
* **No retired callback (`NoRetiredCallback`).** `done → execActive = false ∧
  poolOps pools = 0`: once settled, the pipeline thread has returned and no D2H
  or peer push callback remains in flight.
* **Staging integrity (`StagingIntegrity`).** `hasStaging = !done`: the
  sender's `PoolStagingLease`s are released (`ReleaseLeasesLocked`) if and only
  if the session has settled (`SettleLocked`).
* **Prompt settle (`SettlesPromptly`).** `draining → inFlight = 0 → done`.
* **No non-draining idle state (`ActiveOrDraining`).** `draining = false →
  0 < inFlight`: the session never drops to `in_flight_ == 0` before
  `finalizing_` is set.
* **Slot accounting & publication (`Publication`).** `published = some true →
  remainingPushes = 0 ∧ allPushed pools = true`: `done_sending` is published
  only when `CountPoolReshardSendSlots` has counted down to `0` and every active
  pool has completed its D2H copy and all of its scheduled peer pushes.
* **No op leak & termination (`NoOpLeak`, `reachable_can_settle`).** While
  `0 < inFlight`, some event in `drainEvents` is enabled, and every reachable
  state can drain to `done = true ∧ hasStaging = false` in finitely many steps.

Plan visibility follows from these without state of its own: `plan()` has a
value exactly while `!done`, and `SettleSafe` with `NoRetiredCallback` says
that no push or D2H callback — nothing that resolves chunks or staging slots
through the plan — is in flight once it is gone
(`trace_partial_failure_keeps_plan`).

## Source map

Line ranges are populated and checked by `tpu_sync/formal_verification/tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `tpu_sync/transport/transfer_session.h` | `TransferSession` | `:36-115` |
| `session.h` | `StagingLayerManager` | `:40-75` |
| `reshard_send.cc` | `ReshardSendSession::Done` | `:94-97` |
| `reshard_send.cc` | `ReshardSendSession::TryBeginOp` | `:101` |
| `reshard_send.cc` | `ReshardSendSession::GetStatus` | `:108-111` |
| `reshard_send.cc` | `ReshardSendSession::IsDraining` | `:115-118` |
| `reshard_send.cc` | `ReshardSendSession::deadline` | `:120-122` |
| `reshard_send.cc` | `ReshardSendSession::ResolveStagingSlot` | `:133-135` |
| `reshard_send.cc` | `ReshardSendSession::plan` | `:148-153` |
| `reshard_send.cc` | `ReshardSendSession` (`int remaining_pool_peer_pushes_` .. `std::atomic<bool> cancelled_`) | `:198-208` |
| `reshard_send.cc` | `ReshardSendSession::ValidatePlan` | `:213-251` |
| `reshard_send.cc` | `CreateReshardSendSession` | `:253-315` |
| `reshard_send.cc` | `ReshardSendSession::AcquireStagingSlot` | `:339-361` |
| `reshard_send.cc` | `ReshardSendSession::LookupStagingSlot` | `:363-381` |
| `reshard_send.cc` | `ReshardSendSession::ValidatePushPreconditions` | `:383-399` |
| `reshard_send.cc` | `ReshardSendSession::Start` | `:401-438` |
| `reshard_send.cc` | `ReshardSendSession::Start` (`++in_flight_;`) | `:408` |
| `reshard_send.cc` | `ReshardSendSession::Start` (`absl::Cleanup end_op = [this]() { EndOp(); };`) | `:410` |
| `reshard_send.cc` | `ReshardSendSession::Start` (`} catch (const std::system_error& e) {`) | `:427-435` |
| `reshard_send.cc` | `ReshardSendSession::ExecutePushPipeline` | `:440-554` |
| `reshard_send.cc` | `ReshardSendSession::ExecutePushPipeline` (`for (size_t pool_idx : ordered_pools)`) | `:480-553` |
| `reshard_send.cc` | `ReshardSendSession::ExecutePushPipeline` (`absl::StatusOr<size_t> host_slot = AcquireStagingSlot(pool_idx);`) | `:502` |
| `reshard_send.cc` | `ReshardSendSession::ExecutePushPipeline` (`d2h_futures_.push_back(pool_future);` .. `++in_flight_;`) | `:540-541` |
| `reshard_send.cc` | `ReshardSendSession::ExecutePushPipeline` (`pool_future.OnReady`) | `:543-552` |
| `reshard_send.cc` | `ReshardSendSession::StartPoolPush` | `:556-659` |
| `reshard_send.cc` | `ReshardSendSession::StartPoolPush` (`in_flight_ += static_cast<int>(transfers_by_peer.size());`) | `:617` |
| `reshard_send.cc` | `ReshardSendSession::StartPoolPush` (`for (const auto& [peer, transfers] : transfers_by_peer)`) | `:629-658` |
| `reshard_send.cc` | `ReshardSendSession::RecordPushCompletion` | `:661-680` |
| `reshard_send.cc` | `ReshardSendSession::Finish` | `:682-700` |
| `reshard_send.cc` | `ReshardSendSession::OnDataReceived` | `:708-714` |
| `reshard_send.cc` | `ReshardSendSession::EndOp` | `:716-744` |
| `reshard_send.cc` | `ReshardSendSession::EndOp` (`while (true)`) | `:726-743` |
| `reshard_send.cc` | `ReshardSendSession::ReleaseLeasesLocked` | `:746-751` |
| `reshard_send.cc` | `ReshardSendSession::SettleLocked` | `:753-760` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishPoolH2d` | `:857-893` |
| `slots.cc` | `CountPoolReshardSendSlots` | `:27-51` |
| `mgr.cc` | `KVCacheManagerWithTransfer::~KVCacheManagerWithTransfer` (`for (const auto& [uuid, entry] : sessions_)`) | `:398-402` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RetireSettledSessionLocked` | `:470-529` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardPush` | `:732-774` |
| `mgr.cc` | `KVCacheManagerWithTransfer::UnregisterActivePlan` | `:827-873` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`} else if (session->deadline() <= now) {` .. `absl::DeadlineExceededError("Transfer session timed out"));`) | `:1089-1095` |
| `base.h` | `KVCacheManagerBase::AttachPlaceholderDeviceHoldForTest` | `:762` |
| `base.cc` | `KVCacheManagerBase::GetTransferPlan` | `:3078-3088` |
| `base.cc` | `KVCacheManagerBase::CopyPoolBlocks` | `:2906-3047` |
| `base.cc` | `KVCacheManagerBase::D2hPoolBlocks` | `:3049-3055` |
| `base.cc` | `KVCacheManagerBase::GetBlockChunks` | `:3388-3560` |
| `base.cc` | `KVCacheManagerBase::GetBlockChunks` (`return plan->ResolvePlanBlockChunks(`) | `:3557-3559` |
| `raw_core.h` | `PjRtCopyFuture::OnReady` | `:514-568` |
| `raw_core.h` | `IssueD2hShard` | `:657-685` |
| `bt.cc` | `BlockTransport::AsyncPush` | `:503-552` |
| `utils.h` | `StridedSpanFitsBlock` | `:322-333` |
| `utils.h` | `StridedSpanFitsRegions` | `:335-349` |
| `pool_layout.cc` | `RegionCoversOffset` | `:66-87` |
| `pool_layout.cc` | `RegionsCoverRange` | `:257-274` |
| `reshard_send_test.cc` | `StubRecvSession` | `:66-93` |
| `reshard_send_test.cc` | `MakeTestBase` | `:95-101` |
| `reshard_send_test.cc` | `CreateStatus` | `:169-179` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.AcceptsCanonicalPlanOnExplicitPools` | `:181-187` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.AcceptsImplicitPools` | `:189-194` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.RejectsMissingIdentityAndPoolFields` | `:196-222` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.RejectsOverflowingSenderSpan` | `:224-237` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.RejectsSenderSpanBetweenPackedTokenRegionsInAliasedStorage` | `:239-270` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.IgnoresReceiverCoverageGap` | `:272-291` |
| `reshard_send_test.cc` | `FakeD2hBase` | `:339-415` |
| `reshard_send_test.cc` | `RouteSessionLookups` | `:419-429` |
| `reshard_send_test.cc` | `AcceptPushes` | `:432-441` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsBeforeSettling` | `:463-502` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsWhenCancelledMidCopy` | `:504-548` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.PooledPolicyKeepsIdlePeerConnections` | `:550-581` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.CreateRejectsUnknownDataConnReuseValue` | `:583-600` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.BoundedStagingSlotAcquisitionAndRelease` | `:602-696` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.StartFailsFastWithoutTransportServer` | `:701-726` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.PipelineSlotWaitTimeoutSettlesSendOutOfBand` | `:732-781` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.StagingSlotReleasedAfterLastPeerPush` | `:785-827` |
| `reshard_send_test.cc` | `RecordingH2dReceiverBase` | `:829-886` |
| `reshard_send_test.cc` | `ReshardSendSessionTest.PoolOrderInvertedFromStorageOrderPassesTransportValidateChunks` | `:888-948` |
| `pool_reshard_test.cc` | `PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints` | `:359-375` |
| `pool_reshard_test.cc` | `PoolReshardSendTest.SenderWithNoBytesForAnyTransferredPoolRefusedUpFront` | `:390-413` |
| `pool_reshard_test.cc` | `TestManager::AddPoolReshardSend` | `:131-147` |
| `pool_reshard_test.cc` | `SubPlanChainTest.SendTerminalWaitsForTheLastSubPlan` | `:1060-1088` |
| `pool_reshard_test.cc` | `PoolReshardSessionLookupTest.GetSessionResolvesActiveReshardSendUntilRetired` | `:1124-1155` |
| `pool_reshard_test.cc` | `DeviceBackedTestBase` | `:685-698` |
<!-- source-map:end -->
-/
