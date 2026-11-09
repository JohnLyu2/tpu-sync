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
| `chain` | `sub_plan_chains_[req_id]` (`SubPlanChainProgress`: `sub_sessions`, `completed`, `failed`, `anchored`) | `present = false` is absence from the map; the map is keyed by `req_id` alone, so a worker that is both a source and a destination of the request folds its send and receive sub-plans into one entry |
| `sessions` | the pool-reshard `SessionEntry`s (`SessionRole::kPoolReshardSend` / `kPoolReshardReceive`) registered for `req_id`, with the `sub_plan_index` / `sub_plan_count` of each `StartTransferRequest` and once `Done()` the status it settled with | `retired` marks erasure from `sessions_` by `RetireSettledSessionLocked`; the entry keeps its `shared_ptr` (`active` is the unretired ones) |
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
| worker | `settleSession uuid ok` | the session reaching `Done()` |
| worker | `poll stalled` | `CompleteReadWithDetails`: the `session->deadline() <= now` arm, `RecordPoolReshardTerminalLocked` for each `Done()` session (from `RetireSettledSessionLocked`), then `SweepSubPlanChainsLocked(now)`; `stalled` is `now - progress.last_activity > stall` |
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
| `settleSession` | the session's own `mu_` (`Transfer/Session.lean`); the worker reads `Done()` under `mu_` in `poll` |
| `poll` | one `mu_` scope of `CompleteReadWithDetails`: the deadline arm and `RetireSettledSessionLocked` over `sessions_`, `SweepSubPlanChainsLocked`, and the swap of `done_*_` / `failed_recving_` into the result |
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
  (`BuildStartTransferForTarget`). Guard: `registerSubPlan` refuses other
  indices (`NoteSubPlanRegisteredLocked` would grow `sub_sessions` to
  `sub_plan_index + 1` slots that no sub-plan fills).
* **A2 — sub-plan UUIDs are fresh.** `SubPlanUuid` derives distinct UUIDs per
  index (`subPlanUuid_pos_of_pos`, `trace_sub_plan_uuid_positive_and_distinct`)
  and a retry under the same `req_id` uses a new request UUID. Guard:
  `registerSubPlan` refuses a UUID already in `seenUuids`. A repeated UUID is
  `PoolReshardRegisterRecv`'s duplicate-plan path, modelled in
  `Reshard/PoolStaging.lean`.
* **A3 — a rank votes `Complete` only after its last window.** The producer
  calls `RequestBlockRegistry::Complete` for a rank once that rank's worker
  reports `done_sending`, which `RecordPoolReshardTerminalLocked` emits only
  after every sub-plan of the chain on that worker settled. Guard:
  `senderVoteComplete` refuses a rank still in `plan.src_units` of the running
  or a later window. Without it a rank's vote could retire the claim while
  another window is being armed.
* **A5 — a sub-plan session outlives no stall.** `DeadlineFromNow()` is
  `timeout_s_` from the session's creation and `NoteSubPlanRegisteredLocked`
  sets `last_activity` at its registration, so an entry quiet for `timeout_s_`
  (`stalled`) has every open session of its `req_id` past its deadline, and the
  `session->deadline() <= now` arm of the same `CompleteReadWithDetails` has
  already called `Finish(DeadlineExceeded(...))` on it. Guard: `poll true` on a
  present entry fails every open session first (`Guards.deadlineArm`). Without
  it a session seated when the sweep erases its failed entry could settle OK
  into the no-entry arm as the request's `done`
  (`mutant_no_deadline_arm_reports_done_after_sweep`).
* **A6 — no single-plan registration while a sub-plan is seated.** A
  single-plan `StartTransferRequest` under a `req_id` erases that `req_id`'s
  chain entry (`sub_plan_chains_.erase(req_id)`); the coordinator plans a
  request's sub-plans once (`PlanSubTransfers`), so none arrives while a
  sub-plan session of the same `req_id` is still in `sessions_`. Guard:
  `registerSubPlan` with `count <= 1` refuses while such a session is seated
  (`Guards.noSingleWhileSeated`). Without it the seated sub-plan's clean
  settlement is reported as the request's `done` through the no-entry arm
  (`mutant_single_plan_registration_erases_live_chain`).
* **A7 — one session per `sub_plan_index >= 1` slot.** `RunSubPlan` arms each
  `(req_id, index)` once per chain and a retry re-anchors at index 0;
  `sub_sessions[sub_plan_index] = session` would otherwise drop the earlier
  session from the entry. Guard: `registerSubPlan` refuses an index whose slot
  is filled unless it re-anchors (`Guards.oneSessionPerSlot`). Without it the
  dropped session of an unanchored entry settles into the `stray` arm as the
  request's `done` (`mutant_slot_overwrite_reports_stray_done`).
* **Not modelled:** `!stopping_.load()` in the re-arm condition (a coordinator
  shutting down aborts instead of re-arming; `retryBusyArm` assumes it is not
  stopping), the `kController` delivery mode's null-controller error path,
  `transfer_details_`, and which of `done_recving_` / `done_sending_` a terminal
  lands in (`is_recv`): `WorkerState` is one `sub_plan_chains_` entry with the
  sessions of both roles.
* **A4 — producers register before `Coordinate`.** `registerProducer` is
  enabled only before `startChainCoordination`. The registry refuses `Register`
  once the claim is taken (`Reshard/Registry.lean`); a registration landing
  between `StartPoolReshard` and window 0's `LookupAndClaim` is the
  single-window case of `Reshard/Coordinator.lean`.

## Properties

* `subPlanUuid_zero`, `subPlanUuid_pos_of_pos`: `SubPlanUuid(uuid, 0) = uuid`
  and `0 < SubPlanUuid(uuid, index) <= 0x7FFFFFFFFFFFFFFF` for `index > 0`.
* `planSubTransfers_no_aliased_window_split`: a multi-window chain is planned
  only when no windowed tag shares a destination block ID with another tag, so
  the per-plan `RankWaveOrder` on aliased device pages (`Reshard/Receive.lean`)
  is never split across sub-plans.
* `reachable_worker_safe` (`DoneAfterAllSubPlans`): in every reachable state of
  `WorkerState.step`, every `done_recving` / `done_sending` insertion was made
  with every slot of the request's `sub_sessions` (at least `sub_plan_count`
  of them) settled OK, or by a single-plan session settled OK.
* `reachable_coordChain_safe` (`CoordChainSafe`), for every topology whose
  windows are non-empty subsets of the claimed snapshot (`ValidChainCfg`):
  `Registry.Inv`; no dispatched rank is ever left without the registry claim
  (`NoSenderExposed` — the `if (index == 0)` guard on `AbandonClaim`); no
  sender of a window is dispatched while the window arms
  (`NoPushBeforeAllArmed`); every destination is armed while a window
  dispatches (`AllArmedWhileDispatching`); a destination never has two windows'
  receivers staged at once (`OneWindowStagedPerDestination`);
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
  (`trace_late_sub_plan_after_sweep_reports_failure_twice`), as is one still
  seated at the sweep (`trace_sub_plan_seated_at_sweep_is_failed_not_done`,
  `trace_stall_sweep_keeps_entry_with_open_session`); a single-plan session
  beside an unanchored entry still reports
  (`trace_single_plan_beside_unanchored_entry_reports`); and a window
  `>= 1` failure keeps the claim until `ttl_s_` even after every dispatched rank
  has voted (`trace_chained_arm_failure_keeps_claim_past_last_vote`).
* Mutants: counting a superseded chain's sub-plan
  (`mutant_counting_stale_sub_plan_reports_done_early`), not re-anchoring on
  sub-plan 0 (`mutant_no_reanchor_never_reports_retry_done`), dropping each of
  the guards A5–A7 (`mutant_no_deadline_arm_reports_done_after_sweep`,
  `mutant_single_plan_registration_erases_live_chain`,
  `mutant_slot_overwrite_reports_stray_done`), and `AbandonClaim` at every
  index (`mutant_abandon_at_every_index_exposes_active_sender`).
* Searches (`workerViolates`, `coordViolates`, both `!decide (Safe s)`) exhaust
  a two-window worker (with and without a single-plan request beside it) and
  two two-window coordinator topologies; `Coverage.lean` measures which arms
  the 6 `SubPlanChainTest` and 6 windowed `ReshardStackTest` cases reach.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `coord.h` | `SubTransferSlice` | `:97-102` |
| `coord.h` | `SubTransferChain` | `:108-111` |
| `coord.h` | `ReshardCoordinator` | `:138-207` |
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
<!-- source-map:end -->
-/
