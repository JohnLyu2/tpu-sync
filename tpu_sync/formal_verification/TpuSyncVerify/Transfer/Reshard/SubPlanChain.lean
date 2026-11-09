import TpuSyncVerify.Transfer.Reshard.SubPlanChain.Model
import TpuSyncVerify.Transfer.Reshard.SubPlanChain.Invariant
import TpuSyncVerify.Transfer.Reshard.SubPlanChain.Traces
import TpuSyncVerify.Transfer.Reshard.SubPlanChain.Coverage

/-!
# Reshard sub-plan chains (`PlanSubTransfers`, `StartChain`, `SubPlanChainProgress`)

A pool reshard whose destination has less staging than the request
(`dst_window_blocks`) runs as a chain of sub-plans, one per window. This module
models the three places that know about the chain:
1. **The planner** — `PlanSubTransfers` and `SubPlanUuid` in `coord.cc`: how
   a request's destination block lists are split by window, how shorter and
   unwindowed tags are right-aligned into the last sub-transfers, when a
   windowed tag that shares destination block IDs with another tag disables
   windowing, and how `index >= 1` sub-plans get their UUIDs.
2. **The worker** — `KVCacheManagerWithTransfer::SubPlanChainProgress`,
   `NoteSubPlanRegisteredLocked`, `RecordPoolReshardTerminalLocked`, and
   `SweepSubPlanChainsLocked` in `mgr.{h,cc}`: how one worker folds the
   terminals of a request's sub-plan sessions into the single `done_recving` /
   `done_sending` / `failed_recving` that `CompleteReadWithDetails` publishes.
3. **The coordinator** — `ReshardCoordinator::StartPoolReshard`,
   `ExecutePoolReshard`, `StartChain`, and `RunSubPlan(ctx, 0 .. K - 1)` in
   `coord.cc`, composed with the request's `RequestBlockRegistry` generation
   (`Reshard/Registry.lean`): one claim across the windows, each window's
   arm-then-dispatch over the per-window `plan.src_units`, the
   `ArmRefusedForBusyStaging` re-arm loop, and when `transfer_status_` reads
   `kCompleted` or `kFailed`.

One sub-plan on its own — its two-stage barrier, its receiver and sender
sessions — is `Reshard/Coordinator.lean`, `Reshard/Receive.lean`,
`Reshard/Send.lean`, and `Reshard/Pipeline.lean`; this module takes those as
given and models what the chain adds.

`coord.h`/`coord.cc` are `tpu_sync/kv_cache/reshard/reshard_coordinator.{h,cc}`;
`mgr.h`/`mgr.cc` are `tpu_sync/kv_cache/kv_cache_manager_with_transfer.{h,cc}`;
`reshard_send.cc` is `tpu_sync/kv_cache/reshard_send_session.cc`;
`reshard_recv.cc` is `tpu_sync/kv_cache/reshard_receive_session.cc`;
`planner.cc` is `tpu_sync/kv_cache/reshard/pool_reshard_planner.cc`;
`reg.cc` is `tpu_sync/kv_cache/reshard/request_block_registry.cc`;
`pool_reshard_test.cc` is
`tpu_sync/kv_cache/kv_cache_manager_with_transfer_pool_reshard_test.cc`; and
`reshard_service_test.cc` is
`tpu_sync/kv_cache/reshard/reshard_service_test.cc`. Exact line ranges for
every symbol, sub-block, and test are in the generated `## Source map` table
below.

## State

### Worker (`WorkerState`, one worker, one `req_id`)

| Field | C++ | Role |
|---|---|---|
| `chain` | `sub_plan_chains_[req_id]` (`SubPlanChainProgress`: `sub_sessions`, `completed`, `failed`, `anchored`) | `present = false` is absence from the map; sender workers (`SessionRole::kPoolReshardSend`) and receiver workers (`SessionRole::kPoolReshardReceive`) use the same per-`req_id` map |
| `sessions` | the pool-reshard `SessionEntry`s (`SessionRole::kPoolReshardSend` / `kPoolReshardReceive`) registered for `req_id`, with `(sub_plan_index, sub_plan_count)`, `IsDraining()` (`draining_` / `finalizing_`), `in_flight_ > 0` (`inFlight`), `Done()`, and `GetStatus().ok()` | `retired` marks erasure from `sessions_` by `RetireSettledSessionLocked`; the chain entry keeps its `shared_ptr` (`active` is the unretired ones) |
| `doneReports`, `failReports` | insertions of `req_id` into `done_recving_` / `done_sending_` and into `failed_recving_` | what `CompleteReadWithDetails` publishes |
| `doneLog` (ghost) | — | for each `done` insertion, `sub_sessions.size()` and the settled slots at that moment (`DoneAfterAllSubPlans`) |
| `seenUuids` (ghost) | — | UUIDs registered so far (A2) |

### Coordinator (`CoordChainState`, one request)

| Field | C++ | Role |
|---|---|---|
| `allSrcUnits`, `winSrcUnits`, `dstUnits` | `args.src_units`; per-window `plan.src_units` (`BuildPoolReshardPlan` keeps the ranks with spans in the window); `args.dst_units` | the topology; `winSrcUnits[w] ⊆ allSrcUnits` |
| `transferStatus` | `transfer_status_[req_id]` | `notStarted`, `inProgress`, `completed`, `failed` |
| `winIdx`, `winPhase`, `armAttempts` | the running `RunSubPlan(ctx, index)`, its stage, and `attempt` of the re-arm loop | `RunSubPlan(ctx, 0)` runs inline, `1 .. K - 1` on `StartChain`'s thread |
| `maxArmAttempts` | `kChainArmAttempts` | `attempts = index == 0 ? 1 : kChainArmAttempts` |
| `armResults`, `sendResults` | `arm_status[i]` / `armed[i]`, `sender_status[i]` of the running window | an arm result is `ok`, `refusedBusy` (`ArmRefusedForBusyStaging`), or `failed` |
| `dstStates` | per destination: an earlier window's `ReshardReceiveSession` still holding its `PoolStagingLease` (`prevSessionActive`), the running window's receiver armed (`curWinArmed`) | a busy destination refuses the arm |
| `activeSenders` | ranks with a dispatched `ReshardSendSession` that have not voted `Complete` | — |
| `activeSenderExposed` (ghost) | — | latched if a rank in `activeSenders` is left without a registry claim (`NoSenderExposed`) |
| `reg` | the request's `RequestBlockRegistry` generation (`Registry.RegGen`) | shared by all windows through `ctx->claim_owner` |

## Events

| System | Event | C++ |
|---|---|---|
| worker | `registerSubPlan uuid index count` | `PoolReshardRegisterRecv` / `PoolReshardPush` seating the session and calling `NoteSubPlanRegisteredLocked` |
| worker | `beginOp uuid` | `TryBeginOp` / `Start` / `ExecuteEligiblePoolH2ds` entering `in_flight_ > 0` |
| worker | `latchDrain uuid ok` | `FinishPoolH2d` / `RecordPushCompletion` / `Finish` latching `draining_` / `finalizing_` while `in_flight_ > 0` (`!Done()`) |
| worker | `settleSession uuid ok` | `EndOp` / `EndRecvOpLocked` settling a draining session (`ok = true` preserves `s.ok`; `ok = false` models a late `Finish(error)` before `EndOp` in `ReshardReceiveSession::FinishLocked`, over-approximating `ReshardSendSession::Finish`), or `Finish` settling an idle (`in_flight_ == 0`) session synchronously |
| worker | `poll stalled`, `pollMidSettle stalled midSettle` | `CompleteReadWithDetails`: the `if (!session->IsDraining())` `session->deadline() <= now` arm, `RecordPoolReshardTerminalLocked` for each `Done()` session (from `RetireSettledSessionLocked`), optional `EndOp` settlements `midSettle` in the `session->mu_` gap before the sweep, then `SweepSubPlanChainsLocked(now)`; `stalled` is `now - progress.last_activity > stall` |
| coordinator | `registerProducer srcUnit` | `RequestBlockRegistry::Register` |
| coordinator | `startChainCoordination` | `StartPoolReshard` setting `kInProgress` |
| coordinator | `startWindowPlan planOk` | `RunSubPlan` Stage 0: `LookupAndClaim`, `BuildPoolReshardPlan` |
| coordinator | `armDstResult dstUnit outcome` | one Stage 1 `PoolReshardRegisterRecv` RPC returning |
| coordinator | `retryBusyArm` | the Stage 1 join setting `retry = true` and re-arming the unarmed destinations |
| coordinator | `finishWindowArm` | the Stage 1 join dispatching, or `return arm_status[i]` |
| coordinator | `sendSrcResult srcUnit ok` | one Stage 2 `PoolReshardPush` RPC returning |
| coordinator | `finishWindowSend` | the Stage 2 join: next window, final status, or `return status` |
| coordinator | `settleDispatchedRecv dstUnit` | a dispatched window's receiver settling and releasing its lease |
| coordinator | `senderVoteComplete srcUnit` | the producer calling `RequestBlockRegistry::Complete` for a rank that reported `done_sending` |
| coordinator | `cancelIfUnclaimed` | the producer calling `RequestBlockRegistry::CancelIfUnclaimed` |

## Lock scopes

| Event | Lock scopes |
|---|---|
| `registerSubPlan` | one `mu_` scope of `PoolReshardRegisterRecv` / `PoolReshardPush`: insert into `sessions_`, `NoteSubPlanRegisteredLocked` |
| `beginOp`, `latchDrain`, `settleSession` | one `mu_` scope each on the session (`Reshard/Send.lean`, `Reshard/Receive.lean`); `ReshardReceiveSession::FinishLocked` updates `status_` on error before `if (draining_) return;` (`settleSession uuid false` while `draining`), whereas `ReshardSendSession::Finish` returns early when `finalizing_` |
| `poll`, `pollMidSettle` | one `KVCacheManagerWithTransfer::mu_` scope of `CompleteReadWithDetails`, which acquires `session->mu_` separately in `!session->IsDraining()`, `RetireSettledSessionLocked` (`reshard->Done()`), and `SweepSubPlanChainsLocked` (`!sub_session->Done()`); `pollMidSettle` models `EndOp` completing under `session->mu_` between the second and third acquisitions (excluded by A5c in `WorkerState.step`, admitted in `WorkerState.stepSweepWaitsForOpen`) |
| `registerProducer`, `senderVoteComplete`, `cancelIfUnclaimed` | `RequestBlockRegistry::mu_` |
| `startChainCoordination`, `finishWindowSend` (last window), `finishWindowArm` / `startWindowPlan` / `finishWindowSend` (abort) | `status_mu_` for `transfer_status_`; `RunSubPlan`'s registry calls under `RequestBlockRegistry::mu_` |
| `startWindowPlan`, `armDstResult`, `retryBusyArm`, `finishWindowArm`, `sendSrcResult` | `RunSubPlan`'s own thread joins (`armers`, `senders`); the RPCs run unlocked and report through per-index slots |
| `settleDispatchedRecv` | the receiver's `mu_` and `PoolStagingStorage`'s lock on release |

`RunSubPlan(ctx, 0)` returns before `StartChain` spawns `RunSubPlan(ctx, 1)`
(`ExecutePoolReshard`), so the windows of one request never overlap on the
coordinator; what overlaps is a dispatched window's data plane with the next
window's arming, which is what `prevSessionActive` and `retryBusyArm` model.

## Assumptions

* **A1 — `0 <= sub_plan_index < max(1, sub_plan_count)`.** `RunSubPlan` stamps
  every sub-plan with its `index` in `0 .. chain.count - 1`
  (`BuildStartTransferForTarget`). Guard: `registerSubPlan` excludes indices
  `>= max 1 count` (`NoteSubPlanRegisteredLocked` would grow `sub_sessions` to
  `sub_plan_index + 1` slots that no sub-plan fills).
* **A2 — sub-plan UUIDs are fresh.** `SubPlanUuid` derives distinct UUIDs per
  index (`subPlanUuid_pos_of_pos`, `trace_sub_plan_uuid_positive_and_distinct`),
  a retry under the same `req_id` uses a new request UUID, and `PoolReshardPush`
  / `PoolReshardRegisterRecv` reject an active duplicate UUID in `sessions_`
  with `ALREADY_EXISTS`. Guard: `registerSubPlan` excludes a UUID already in
  `seenUuids`. A repeated UUID is `PoolReshardRegisterRecv`'s duplicate-plan
  path, modelled in `Reshard/PoolStaging.lean`.
* **A3 — a rank votes `Complete` only after its last window.** The producer
  calls `RequestBlockRegistry::Complete` for a rank once that rank's worker
  reports `done_sending`, which `RecordPoolReshardTerminalLocked` emits only
  after every sub-plan of the chain on that worker settled. Guard:
  `senderVoteComplete` excludes a rank still in `plan.src_units` of the running
  or a later window. Without it a rank's vote could retire the claim while
  another window is being armed.
* **A4 — producers register before `Coordinate`.** `registerProducer` is
  enabled only before `startChainCoordination`. The registry refuses `Register`
  once the claim is taken (`Reshard/Registry.lean`); a registration landing
  between `StartPoolReshard` and window 0's `LookupAndClaim` is the
  single-window case of `Reshard/Coordinator.lean`.
* **A5 — deadline arm, tombstone sweep, and intra-poll `EndOp` window
  (`Guards.deadlineArm`, `Guards.noDrainingOkAtSweep`,
  `Guards.noSettleBetweenRetireAndSweep`).**
  - *A5a (`Guards.deadlineArm`):* `DeadlineFromNow()` is `timeout_s_` from a
    session's creation and `NoteSubPlanRegisteredLocked` sets `last_activity` on
    every chained registration, so when an entry has been quiet for `timeout_s_`
    (`stalled`), every session in `sessions_` is past `session->deadline()`, and
    `CompleteReadWithDetails` executes
    `if (!session->IsDraining()) { ... session->Finish(DeadlineExceededError(...)); }`
    before `RetireSettledSessionLocked` and `SweepSubPlanChainsLocked`. An idle
    session (`in_flight_ == 0`) sets `done_ = true` synchronously inside
    `Finish` and is retired in that same poll
    (`trace_idle_seated_session_settles_at_deadline_poll`); an in-flight
    `!IsDraining()` session (`in_flight_ > 0`) latches `draining_` /
    `finalizing_` with error while staying `!Done()` until `EndOp`
    (`trace_sub_plan_seated_at_sweep_is_failed_not_done`,
    `trace_stall_sweep_keeps_entry_with_open_session`). Without A5a, an
    in-flight `!IsDraining()` session surviving a tombstone sweep settles OK
    into `it == sub_plan_chains_.end()` as the request's `done`
    (`mutant_no_deadline_arm_reports_done_after_sweep`).
  - *A5b (`Guards.noDrainingOkAtSweep`):* Because `CompleteReadWithDetails`
    gates its deadline arm on `if (!session->IsDraining())`
    (`ReshardReceiveSession::IsDraining` returns `draining_`;
    `ReshardSendSession::IsDraining` returns `finalizing_`, and
    `ReshardSendSession::Finish` returns early on `if (done_ || finalizing_) return;`),
    a sibling sub-plan already in `IsDraining() && !Done()` with `OkStatus()` —
    `ReshardSendSession::RecordPushCompletion` having set `finalizing_ = true`
    while `ReshardSendSession::EndOp` runs unlocked
    `ReleaseDataConnectionsAfterSend`, or
    `ReshardReceiveSession::FinishPoolH2d` having called `Finish(OkStatus())`
    before `self->EndOp()` — is skipped by the deadline arm. Meanwhile,
    `SweepSubPlanChainsLocked` erases `progress.failed || progress.completed`
    entries unconditionally (checking `!sub_session->Done()` only in the live
    `!failed && !completed` arm; cf.
    `trace_draining_session_on_live_chain_survives_stalled_poll`).
    `DoneAfterAllSubPlans` therefore requires that no unretired multi-sub-plan
    session be in `IsDraining() && !Done()` with `OkStatus()` when a
    `failed || completed` tombstone is swept (`Guards.noDrainingOkAtSweep`). C++
    does **not** enforce A5b: if `EndOp` / `FinishPoolH2d` straddles the
    tombstone sweep of a failed chain, that sibling sub-plan settles on a later
    poll into `it == sub_plan_chains_.end()` and emits `done_sending_` /
    `done_recving_` on a single non-retried failed request
    (`mutant_draining_ok_at_sweep_reports_done_after_failure`).
  - *A5c (`Guards.noSettleBetweenRetireAndSweep`):* Because
    `CompleteReadWithDetails` holds `KVCacheManagerWithTransfer::mu_` without
    holding `session->mu_`, a draining session skipped by `!session->IsDraining()`
    and seen as `!Done()` by `RetireSettledSessionLocked` can finish `EndOp`
    (`done_ = true`) before `SweepSubPlanChainsLocked` checks
    `!sub_session->Done()`. C++ does **not** enforce A5c: on an unanchored live
    chain (`progress.anchored == false`, `sub_plan_index > 0`), that mid-poll
    `EndOp` makes `!sub_session->Done()` read `false`, so
    `SweepSubPlanChainsLocked` marks the chain stalled (`progress.failed = true`)
    and executes `progress.sub_sessions.clear()` with `anchored` still `false`;
    on the next poll, `RecordPoolReshardTerminalLocked` checks
    `sub_it == progress.sub_sessions.end()` before
    `if (progress.failed || progress.completed) return;`, hits
    `!progress.anchored`, and emits `done_sending_` / `done_recving_` after
    `failed_recving_` (`mutant_mid_poll_endop_unanchored_reports_done_after_stall`).
    Likewise on a `failed || completed` chain, a session finishing `EndOp` in
    that gap is `Done() == true` yet still unretired in `sessions_`. Checking
    `progress.failed || progress.completed` before `!progress.anchored`
    (`recordTerminalWaitOpen`) and keeping `failed || completed` tombstones in
    `SweepSubPlanChainsLocked` while `sessions_` holds any unretired
    `kPoolReshard*` entry for `req_id` (`sweepStalledChainWaitOpen` /
    `WorkerState.stepSweepWaitsForOpen`) discharges both A5b and A5c
    (`reachable_sweepWaitsForOpen_safe`).
* **A6 — no single-plan registration while a sub-plan is seated
  (`Guards.noSingleWhileSeated`).** C++ worker RPCs (`PoolReshardPush`,
  `PoolReshardRegisterRecv`) and `NoteSubPlanRegisteredLocked` do **not** refuse
  a `sub_plan_count <= 1` arrival while multi-sub-plan sessions of the same
  `req_id` are seated in `sessions_`: `NoteSubPlanRegisteredLocked`
  unconditionally executes `sub_plan_chains_.erase(req_id)` when
  `sub_plan_count <= 1`. Guard: `WorkerState.step` excludes `registerSubPlan`
  with `count <= 1` while an unretired `count > 1` session is seated
  (`Guards.noSingleWhileSeated`). Callers can break A6 in two ways
  (`mutant_single_plan_registration_erases_live_chain`): (i) two pipelined
  `ReshardCoordinator::Coordinate` stages sharing one producer registration
  `req_id` (`ReshardStackTest.PipelinedDestinationStagesShareOneRequestClaim`)
  where one stage plans `count > 1` and another plans `count = 1` on an
  overlapping worker, or (ii) a same-`req_id` retry whose `PlanSubTransfers`
  shrinks from `count > 1` to `count = 1` while an earlier sub-plan session is
  still seated.
* **A7 — one session per `sub_plan_index >= 1` slot
  (`Guards.oneSessionPerSlot`).** `NoteSubPlanRegisteredLocked` unconditionally
  overwrites `progress.sub_sessions[sub_plan_index] = session` without checking
  whether that slot already holds an unretired session. Guard:
  `WorkerState.step` excludes `registerSubPlan` at `index >= 1` when
  `w.chain.present` and `subSessions[index]` is already filled
  (`Guards.oneSessionPerSlot`; `index == 0` re-anchors a fresh entry). Even with
  fresh UUIDs per retry from `ReshardCoordinator`, a **sparse-window sender**
  whose spans appear only in window `index > 0` (`BuildPoolReshardPlan` in
  `planner.cc` skips empty-span senders per window) never receives `index = 0`,
  leaving `progress.anchored = false`; on a same-`req_id` retry while Attempt
  1's window-`index` session is still seated, Attempt 2 again dispatches only
  `index > 0` (never re-anchoring at `0`), overwriting `sub_sessions[index]` so
  Attempt 1's session misses `std::find` on `sub_sessions` and hits the
  `!progress.anchored` stray arm to emit premature `done_sending_`
  (`mutant_slot_overwrite_reports_stray_done`).
* **A8 — single-window exclusive destination staging capacity
  (`CoordChainState`).** In `CoordChainState.step`, `armDstResult` equates
  staging contention (`busy`) with `prevSessionActive`, assuming each
  destination's bounded `PoolStagingStorage` is dedicated to this chain and fits
  at most one window's `PoolStagingLease` at a time. When `staging_leases == 0`
  (unbounded full-mirror storage) or spare arena capacity exists, two windows'
  receivers can stage concurrently; conversely, external transfers sharing the
  arena can trigger `ArmRefusedForBusyStaging` even when
  `prevSessionActive = false`.
* **Scope / not modelled:** `!stopping_.load()` in the re-arm condition (a
  coordinator shutting down aborts instead of re-arming; `retryBusyArm` assumes
  it is not stopping), the `kController` delivery mode's null-controller error
  path, `transfer_details_`, and which of `done_recving_` / `done_sending_` a
  `done` terminal lands in (`is_recv`): `sub_plan_chains_` is shared by sender
  workers (`SessionRole::kPoolReshardSend` → `done_sending_` /
  `failed_recving_`) and receiver workers (`SessionRole::kPoolReshardReceive` →
  `done_recving_` / `failed_recving_`), while a single worker cannot hold both
  roles on the same sub-plan (`BuildStartTransferForTarget` sets
  `is_sender = true` whenever sender schedules are non-empty,
  `sessions_[SubPlanUuid(uuid, index)]` rejects a second active session on the
  same `(uuid, index)` with `ALREADY_EXISTS`, and `sub_sessions[index]` holds a
  single pointer). Pipelined destination stages sharing one `req_id` on an
  overlapping worker (`ReshardStackTest.PipelinedDestinationStagesShareOneRequestClaim`)
  share `sub_plan_chains_[req_id]` and are outside the single-chain-per-`req_id`
  worker model.

## Properties

* `subPlanUuid_zero`, `subPlanUuid_pos_of_pos`: `SubPlanUuid(uuid, 0) = uuid`
  and `0 < SubPlanUuid(uuid, index) <= 0x7FFFFFFFFFFFFFFF` for `index > 0`.
* `planSubTransfers_no_aliased_window_split`: a multi-window chain is planned
  only when no windowed tag shares a destination block ID with another tag, so
  the per-plan `RankWaveOrder` on aliased device pages (`Reshard/Receive.lean`)
  is never split across sub-plans.
* `reachable_worker_safe` and `reachable_sweepWaitsForOpen_safe`
  (`DoneAfterAllSubPlans`): in every reachable state of `WorkerState.step`
  (under A1, A2, A5–A7), and in every reachable state of the candidate fix
  `WorkerState.stepSweepWaitsForOpen` without A5b (`noDrainingOkAtSweep = false`)
  or A5c (`noSettleBetweenRetireAndSweep = false`), every `done_recving` /
  `done_sending` insertion was made with every slot of the request's
  `sub_sessions` (at least `sub_plan_count` of them) settled OK, or by a
  single-plan session settled OK.
* `reachable_coordChain_safe` (`CoordChainSafe`), for every topology whose
  windows are non-empty subsets of the claimed snapshot (`ValidChainCfg`):
  `Registry.Inv`; no dispatched rank is ever left without the registry claim
  (`NoSenderExposed` — the `if (index == 0)` guard on `AbandonClaim`); no
  sender of a window is dispatched while the window arms
  (`NoPushBeforeAllArmed`); every destination is armed while a window
  dispatches (`AllArmedWhileDispatching`); under A8, a destination never has two
  windows' receivers staged at once (`OneWindowStagedPerDestination`);
  `transfer_status_` reads `kCompleted` only after the last window's Stage 2
  (`CompletedOnlyAtChainEnd`); and the claim is held from window 0's Stage 0
  to the end of the chain (`ClaimHeldAcrossWindows`).
* What the shipping code does beyond those guarantees is shown by traces
  (`Traces.lean`): a rank with spans in fewer than `K` windows never fills
  `K` slots and is failed by the stall sweep
  (`trace_sender_in_first_window_only`, `trace_sender_in_last_window_only`);
  the first failing sub-plan publishes `failed_recving` while sibling sessions
  are still active (`trace_first_failure_reports_while_sibling_active`); a
  sub-plan arriving after the failed entry was swept is failed a second time
  (`trace_late_sub_plan_after_sweep_reports_failure_twice`), as is an in-flight
  one still `!Done()` at the sweep
  (`trace_sub_plan_seated_at_sweep_is_failed_not_done`,
  `trace_stall_sweep_keeps_entry_with_open_session`), whereas an idle
  (`in_flight_ == 0`) one settles synchronously in the deadline poll before the
  sweep runs (`trace_idle_seated_session_settles_at_deadline_poll`) and a
  draining one on a live chain is kept by `!sub_session->Done()`
  (`trace_draining_session_on_live_chain_survives_stalled_poll`); a single-plan
  session beside an unanchored entry still reports
  (`trace_single_plan_beside_unanchored_entry_reports`); and a window
  `>= 1` failure keeps the claim until `ttl_s_` even after every dispatched rank
  has voted (`trace_chained_arm_failure_keeps_claim_past_last_vote`).
* Mutants: counting a superseded chain's sub-plan
  (`mutant_counting_stale_sub_plan_reports_done_early`), not re-anchoring on
  sub-plan 0 (`mutant_no_reanchor_never_reports_retry_done`), dropping each of
  the guards A5a, A5b, A5c, A6, and A7
  (`mutant_no_deadline_arm_reports_done_after_sweep`,
  `mutant_draining_ok_at_sweep_reports_done_after_failure`,
  `mutant_mid_poll_endop_unanchored_reports_done_after_stall`,
  `mutant_single_plan_registration_erases_live_chain`,
  `mutant_slot_overwrite_reports_stray_done`), and `AbandonClaim` at every
  index (`mutant_abandon_at_every_index_exposes_active_sender`).
* Searches (`workerViolates`, `coordViolates`, both `!decide (Safe s)`) exhaust
  a two-window worker (single chain, retry re-anchoring, intra-poll `EndOp`
  settlements, and alongside a single-plan request, under both
  `WorkerState.sys` and `WorkerState.sysSweepWaitsForOpen`) and two two-window
  coordinator topologies; `Coverage.lean` measures which arms the 6
  `SubPlanChainTest` and 6 windowed `ReshardStackTest` cases reach.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `coord.h` | `SubTransferSlice` | `:97-102` |
| `coord.h` | `SubTransferChain` | `:108-111` |
| `coord.h` | `ReshardCoordinator` | `:138-207` |
| `coord.cc` | `BuildStartTransferForTarget` | `:111-271` |
| `coord.cc` | `*` (`struct ReshardCoordinator::ChainContext {` .. `std::atomic<bool> finished{false};`) | `:310-321` |
| `coord.cc` | `SubPlanUuid` | `:356-367` |
| `coord.cc` | `PlanSubTransfers` | `:369-472` |
| `coord.cc` | `ReshardCoordinator::StartPoolReshard` | `:474-526` |
| `coord.cc` | `ReshardCoordinator::ExecutePoolReshard` | `:528-601` |
| `coord.cc` | `ReshardCoordinator::ReapFinishedChainsLocked` | `:603-612` |
| `coord.cc` | `ReshardCoordinator::StartChain` | `:614-649` |
| `coord.cc` | `ReshardCoordinator::WaitForSubTransferChains` | `:651-660` |
| `coord.cc` | `ArmRefusedForBusyStaging` | `:667-670` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` | `:678-932` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` (`const int attempts = index == 0 ? 1 : kChainArmAttempts;` .. `if (!retry) break;`) | `:749-790` |
| `planner.cc` | `BuildPoolReshardPlan` (`PoolReshardPlan plan;` .. `plan.dst_units = request.dst_units;`) | `:1289-1295` |
| `mgr.h` | `KVCacheManagerWithTransfer` (`enum class SessionRole {` .. `SessionRole role;`) | `:295-307` |
| `mgr.h` | `KVCacheManagerWithTransfer` (`struct SubPlanChainProgress {` .. `void SweepSubPlanChainsLocked(std::chrono::steady_clock::time_point now)`) | `:381-408` |
| `mgr.cc` | `KVCacheManagerWithTransfer::NoteSubPlanRegisteredLocked` | `:147-183` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RecordPoolReshardTerminalLocked` | `:185-251` |
| `mgr.cc` | `KVCacheManagerWithTransfer::SweepSubPlanChainsLocked` | `:253-302` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RetireSettledSessionLocked` | `:470-529` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardPush` | `:732-774` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` | `:776-825` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` | `:1071-1134` |
| `reshard_send.cc` | `ReshardSendSession::IsDraining` | `:115-118` |
| `reshard_send.cc` | `ReshardSendSession::RecordPushCompletion` | `:661-680` |
| `reshard_send.cc` | `ReshardSendSession::Finish` | `:682-700` |
| `reshard_send.cc` | `ReshardSendSession::EndOp` | `:716-744` |
| `reshard_recv.cc` | `ReshardReceiveSession::IsDraining` | `:115-118` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishLocked` | `:634-646` |
| `reshard_recv.cc` | `ReshardReceiveSession::EndRecvOpLocked` | `:702-712` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishPoolH2d` | `:857-893` |
| `reg.cc` | `RequestBlockRegistry::Complete` | `:317-371` |
| `reg.cc` | `RequestBlockRegistry::CancelIfUnclaimed` | `:373-405` |
| `reg.cc` | `RequestBlockRegistry::LookupAndClaim` | `:439-491` |
| `reg.cc` | `RequestBlockRegistry::AbandonClaim` | `:493-509` |
| `pool_reshard_test.cc` | `SubPlanChainTest.ReceiveTerminalWaitsForTheLastSubPlan` | `:914-950` |
| `pool_reshard_test.cc` | `SubPlanChainTest.FirstSubPlanFailureFailsTheRequestOnce` | `:952-975` |
| `pool_reshard_test.cc` | `SubPlanChainTest.RetryUnderTheSameReqIdIsTrackedAsANewChain` | `:977-1020` |
| `pool_reshard_test.cc` | `SubPlanChainTest.StalledChainFailsAfterTheTransferTimeout` | `:1022-1044` |
| `pool_reshard_test.cc` | `SubPlanChainTest.SinglePlanRequestsReportAtOnce` | `:1046-1058` |
| `pool_reshard_test.cc` | `SubPlanChainTest.SendTerminalWaitsForTheLastSubPlan` | `:1060-1088` |
| `reshard_service_test.cc` | `PlanSubTransfersTest.NoWindowsPlanOneTransfer` | `:982-1000` |
| `reshard_service_test.cc` | `PlanSubTransfersTest.WindowSplitsPagedTagInDestinationOrder` | `:1002-1019` |
| `reshard_service_test.cc` | `PlanSubTransfersTest.UnwindowedTagsRideInTheLastSubTransfer` | `:1021-1049` |
| `reshard_service_test.cc` | `PlanSubTransfersTest.WindowedTagSharingIdsDisablesWindows` | `:1051-1070` |
| `reshard_service_test.cc` | `PlanSubTransfersTest.MalformedWindowsFailClosed` | `:1072-1084` |
| `reshard_service_test.cc` | `SubPlanUuidTest.DerivedUuidsArePositiveAndDistinct` | `:1086-1096` |
| `reshard_service_test.cc` | `ReshardStackTest.WindowedRequestChainsOneSubTransferPerWindow` | `:1098-1158` |
| `reshard_service_test.cc` | `ReshardStackTest.WindowClipsStraddlingSpansAtWindowBoundaries` | `:1160-1245` |
| `reshard_service_test.cc` | `ReshardStackTest.WindowComposesWithPrefixClip` | `:1247-1284` |
| `reshard_service_test.cc` | `ReshardStackTest.ChainedArmRetriesWhileReceiverStagingIsBusy` | `:1286-1311` |
| `reshard_service_test.cc` | `ReshardStackTest.ChainedRequestStaysInProgressUntilTheChainEnds` | `:1313-1335` |
| `reshard_service_test.cc` | `ReshardStackTest.ChainedArmFailureMarksTheTransferFailed` | `:1337-1359` |
| `reshard_service_test.cc` | `ReshardStackTest.PipelinedDestinationStagesShareOneRequestClaim` | `:1785-1810` |
<!-- source-map:end -->
-/
