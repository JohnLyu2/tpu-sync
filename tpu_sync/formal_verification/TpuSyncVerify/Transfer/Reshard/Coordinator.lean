import TpuSyncVerify.Transfer.Reshard.Coordinator.Model
import TpuSyncVerify.Transfer.Reshard.Coordinator.Lemmas
import TpuSyncVerify.Transfer.Reshard.Coordinator.Invariant
import TpuSyncVerify.Transfer.Reshard.Coordinator.Traces
import TpuSyncVerify.Transfer.Reshard.Coordinator.Coverage

/-!
# Two-stage reshard coordinator (`ReshardCoordinator::RunSubPlan`)

Formal model of one sub-transfer of `ReshardCoordinator::ExecutePoolReshard`
(`tpu_sync/kv_cache/reshard/reshard_coordinator.{h,cc}`) — the plan, arm and
dispatch stages of `ReshardCoordinator::RunSubPlan` — composed with
`RequestBlockRegistry` (`TpuSyncVerify.Transfer.Reshard.Registry`).

`coord.h`/`coord.cc` are `tpu_sync/kv_cache/reshard/reshard_coordinator.{h,cc}`;
`mgr.cc` is `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`;
`reshard_recv.cc` is `tpu_sync/kv_cache/reshard_receive_session.cc`;
`reg.cc` is `tpu_sync/kv_cache/reshard/request_block_registry.cc`;
`planner.cc` is `tpu_sync/kv_cache/reshard/pool_reshard_planner.cc`;
`kv_cache_listener.cc` is `tpu_sync/kv_cache/kv_cache_listener.cc`;
`reshard_service.cc` is `tpu_sync/kv_cache/reshard/reshard_service.cc`; and
`reshard_service_test.cc` is
`tpu_sync/kv_cache/reshard/reshard_service_test.cc`. Exact line
ranges for every symbol, sub-block, and test are in the generated
`## Source map` table below.

  C++ source under analysis:
  * `PoolReshardArgs` and `ReshardCoordinator` (`coord.h`)
  * `ReshardCoordinator::ExecutePoolReshard`, `ReshardCoordinator::RunSubPlan`
    and `ReshardCoordinator::StartChain` (`coord.cc`)
  * `KVCacheListener::HandleControlRequest` (`tpu_sync/kv_cache/kv_cache_listener.cc`, `PoolReshardRegisterRecv` control-pipe handler)
  * `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` (`mgr.cc`: the `pending_pool_reshard_recvs_` claim, `CreateReshardReceiveSession`, insertion into `sessions_`)
  * `CreateReshardReceiveSession`, `ReshardReceiveSession::AcquireStagingLeases`, and `ReshardReceiveSession::ReleaseStaging` / `ReshardReceiveSession::ReleaseStagingLocked` (`reshard_recv.cc`)

  ## Scope: one sub-plan of a request

  `ReshardCoordinator::ExecutePoolReshard` fetches the source and destination
  metadata once, picks the request's `uuid`, plans the request's sub-transfer
  chain (`ReshardCoordinator::PlanSubTransfers`: one sub-plan per
  `dst_window_blocks` window of the destination block lists, `chain.count == 1`
  when no tag is windowed), draws one `claim_owner` for the whole chain
  (`claim_counter.fetch_add(1)`, so the registry sees one claim per request),
  stores all of it in a `ReshardCoordinator::ChainContext`, and runs sub-plan 0
  inline (`RunSubPlan(ctx, 0)`). When `ctx->chain.count > 1`,
  `ReshardCoordinator::StartChain` runs sub-plans `1..count-1` one after another
  on a coordinator thread (`chains_`), which records the request's final
  `transfer_status_` (`kCompleted` once every sub-plan has been dispatched,
  `kFailed` at the first failure or on shutdown); `StartPoolReshard` records
  that status itself only `if (!chain_started)`.

  Each `RunSubPlan(ctx, index)` call is one plan → arm → dispatch sequence:
  `BuildPoolReshardPlan(plan_request, registry_, ctx->claim_owner)` claims the
  source snapshot in `RequestBlockRegistry` (`LookupAndClaim`); the `armers`
  threads arm every destination (`PoolReshardRegisterRecv`) and are joined; the
  senders are dispatched (`PoolReshardPush`) and joined. This module models one
  such call with `index == 0` in which every claimed source rank emits at least
  one schedule entry (`plan.src_units = request.src_units`; when prefix clipping
  or pipelined stage filtering leaves a claimed rank with no surviving entries,
  `if (schedules.find(unit) != schedules.end())` omits it from `plan.src_units`).
  Later sub-plans of a chain (`index >= 1`, `StartChain`, sparse
  `plan.src_units`, `ArmRefusedForBusyStaging` re-arming up to
  `kChainArmAttempts` times while `!stopping_.load()`, and `if (index == 0)`
  registry-claim ownership across sub-plans) together with worker-side
  per-request chain folding (`KVCacheManagerWithTransfer::NoteSubPlanRegisteredLocked`,
  `RecordPoolReshardTerminalLocked`, `SweepSubPlanChainsLocked`) are modelled
  in `Reshard/SubPlanChain.lean`. `WorkerDelivery::Mode::kController`'s
  `delivery_.controller == nullptr` post-arm error path (which calls
  `AbandonClaim` after Phase 1 arming and returns `InternalError` before
  dispatching senders) is excluded from `Ev` alongside transport and
  serialization setup errors (matching `SubPlanChain.lean`). The sender-dispatch
  failure path is the same for every index: `for (const absl::Status& status : sender_status)`
  returns the first error without disarming receivers and without `AbandonClaim`.

  What this file proves:
  1. **Universal Protocol Guarantees (`CoordInv`, `reachable_coord_inv`)**:
     Across all reachable states:
     * `Registry.Inv s.reg` holds at every step.
     * `NoPushBeforeAllArmed` (`ReshardCoordinator::RunSubPlan`, `for (std::thread& t : armers) t.join();` before `sender_dispatch_ns`): No sender
       is dispatched (`s.sendResults = []`) and no receiver receives any push
       while `s.phase = .idle ∨ s.phase = .arming`.
     * `AllArmedInDispatching` (`ReshardCoordinator::RunSubPlan`, `for (std::thread& t : armers) t.join();` and the `if (armed[i]) continue;` scan that ends in `return arm_status[i];`): Entering
       `.dispatching` requires `s.armFailed = false` and all `dstUnits`
       reported in `s.armResults`.
     * `ClaimedWhileArming` (`ReshardCoordinator::RunSubPlan`, `BuildPoolReshardPlan(plan_request, registry_, ctx->claim_owner)` through the `armed[i]` scan): Throughout
       `.arming`, the source snapshot remains claimed in `RequestBlockRegistry`
       (`s.reg.claimedUnits = some s.srcUnits` and `s.reg.claimOwners = [s.claimOwner]`),
       preventing `CancelIfUnclaimed` and conflicting `Register` calls.
     * `LeaseMatchesSession`: Every destination unit holds a `PoolStagingLease`
       if and only if its `ReshardReceiveSession` is currently armed.
  2. **What the two abort paths leave behind (`Traces.lean`)**:
     * `trace_partial_arm_orphans_armed_receiver`
       (`ReshardCoordinator::RunSubPlan`, `return arm_status[i];`;
       `ReshardStackTest.TwoDestinationsOneArmRefusalAbandonsClaimAndSkipsSenders`
       drives it): When `dst_unit 10` succeeds in arming
       and `dst_unit 11` fails, `RunSubPlan` calls `AbandonClaim` (`if (index == 0)`) and
       aborts without disarming `dst_unit 10`, leaving `dst_unit 10`'s
       `ReshardReceiveSession` and `PoolStagingLease` orphaned until
       `timeout_s_`.
     * `trace_dispatch_failure_orphans_receivers_and_claim`
       (`ReshardCoordinator::RunSubPlan`, `for (const absl::Status& status : sender_status)`;
       `ReshardStackTest.SenderDispatchFailurePropagatesErrorAfterReceiverArm`
       is its 2×1 form, asserting the registry still reads claimed): When all `dst_units` arm and
       `src_unit 0` succeeds but `src_unit 1` fails during Stage 2 dispatch,
       `RunSubPlan` returns `sender_status` without disarming
       `dst_units` AND without calling `registry_->AbandonClaim(...)`. Both
       `dst_units` remain orphaned with active sessions/leases AND
       `claimed_[(req_id, uuid)]` remains pinned in `RequestBlockRegistry`
       until `ttl_s_`.
  3. **Searches and the disarm-and-abandon alternative (`Traces.lean`)**:
     `violatesCoordInv = !decide (CoordInv s)` finds no violation over the 2×2
     instance; `stepDisarmAndAbandon`, which also disarms the armed
     destinations and calls `AbandonClaim` on both aborts, is the one `step`
     change under which `NoOrphansWhenAborted` holds on that instance
     (`trace_disarm_and_abandon_cleans_up_both_aborts`); the shipping `step`
     violates it on both abort traces.

  ## Lock scopes

  `ReshardCoordinator::StartPoolReshard` writes `transfer_status_[args.req_id]`
  under `ReshardCoordinator::status_mu_` before `ExecutePoolReshard` and, for a
  request that did not continue as a chain (`if (!chain_started)`), again after
  it; a chained request's final status is written by `StartChain`'s thread under
  the same `status_mu_`. `ExecutePoolReshard` reads `directory_->LocalMetadata`
  under `*directory_->mu()` (shared with `RequestBlockRegistry::mu_`) on entry.
  `StartChain`, `ReapFinishedChainsLocked`, `WaitForSubTransferChains` and
  `~ReshardCoordinator` hold `ReshardCoordinator::chains_mu_` only to spawn,
  reap and join chain threads; `RunSubPlan` itself takes neither `status_mu_`
  nor `chains_mu_` (it reads the `stopping_` atomic only when deciding whether
  to re-arm). Stage-result vectors (`arm_replies` / `arm_status` / `armed`,
  `sender_status`) are synchronized across worker threads by the
  `std::thread::join` barriers, while shared registry and receiver state are
  guarded by `RequestBlockRegistry::mu_` (`Registry.lean`) and each
  destination's `KVCacheManagerWithTransfer::mu_`:

  | Event | Scopes | Between them |
  |---|---|---|
  | `registerProducer srcUnit` | 1 `RequestBlockRegistry::mu_` scope (`RequestBlockRegistry::Register`) | — |
  | `startPlan planOk` | 1 `RequestBlockRegistry::mu_` scope in `BuildPoolReshardPlan` (`LookupAndClaim`), plus a second scope (`AbandonClaim`, `if (index == 0)`) if `planOk = false` after claiming | — |
  | `armDstResult dstUnit ok` | 1 `armers` worker thread calling `PoolReshardRegisterRecv` on `dstUnit` (2 `KVCacheManagerWithTransfer::mu_` scopes, `Pipeline.lean`) and writing its own `arm_replies[i]` / `arm_status[i]` / `armed[i]` slot | worker threads write disjoint slots of `arm_replies` / `arm_status` / `armed`, joined at `finishArmBarrier` |
  | `finishArmBarrier` | `for (std::thread& t : armers) t.join();`, followed for an unarmed destination (`if (armed[i]) continue;`) by 1 `RequestBlockRegistry::mu_` scope (`registry_->AbandonClaim`, `if (index == 0)`) before `return arm_status[i];` | `join()` orders all `arm_status[i]` / `armed[i]` writes before the scan that inspects them; with `index == 0` there is a single arm attempt (`attempts = 1`), so the re-arm loop is not entered |
  | `sendSrcResult srcUnit ok` | 1 `senders` worker thread (or `SubmitTransferProgram` future) calling `PoolReshardPush` on `srcUnit` and writing `sender_status[i]` on failure; on `ok = true`, folds the sender RPC, receiver settlement (`Receive.lean`), and the producer's `registry_->Complete` vote (1 `RequestBlockRegistry::mu_` scope) | folding `Complete` into `ok = true` is sound for `CoordInv` because whenever any `srcUnit` fails (`sendFailed = true`), that unit never calls `Complete`, keeping `allVoted = false` |
  | `finishSendBarrier` | `for (std::thread& t : senders) t.join();` (or the final `futures[i].Await()`) before `for (const absl::Status& status : sender_status)` | `join()` / `Await()` orders all `sender_status[i]` writes before the status check |

  ## Branch coverage

  `Coordinator/Coverage.lean`: 14 branches of `CoordState.step` over the 1×1,
  1×2, 2×1 and 2×2 sub-plans; the 26 single-sub-plan `ReshardStackTest` cases
  (30 traces) that drive `RunSubPlan` within scope reach all 14, the two
  failure-cleanup paths of `Traces.lean` — a refused arm beside an armed
  destination and a failed sender dispatch — through
  `TwoDestinationsOneArmRefusalAbandonsClaimAndSkipsSenders` and
  `SenderDispatchFailurePropagatesErrorAfterReceiverArm`.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `coord.h` | `WorkerDelivery` | `:62-67` |
| `coord.h` | `PoolReshardArgs` | `:70-92` |
| `coord.h` | `ReshardCoordinator` | `:138-207` |
| `coord.cc` | `*` (`struct ReshardCoordinator::ChainContext {` .. `std::atomic<bool> finished{false};`) | `:310-321` |
| `coord.cc` | `ReshardCoordinator::StartPoolReshard` | `:474-526` |
| `coord.cc` | `ReshardCoordinator::ExecutePoolReshard` | `:528-601` |
| `coord.cc` | `ReshardCoordinator::ExecutePoolReshard` (`static std::atomic<uintptr_t> claim_counter` .. `reinterpret_cast<const void*>(claim_counter.fetch_add(1));`) | `:566-568` |
| `coord.cc` | `ReshardCoordinator::ExecutePoolReshard` (`absl::Status first = RunSubPlan(ctx, 0);` .. `return absl::OkStatus();`) | `:592-600` |
| `coord.cc` | `ReshardCoordinator::StartChain` | `:614-649` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` | `:678-932` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` (`auto plan_or = BuildPoolReshardPlan(plan_request, registry_, ctx->claim_owner);` .. `PoolReshardPlan& plan = *plan_or;`) | `:723-728` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` (`std::vector<absl::Status> arm_status` .. `for (std::thread& t : armers) t.join();`) | `:743-776` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` (`bool retry = false;` .. `return arm_status[i];`) | `:777-788` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` (`std::vector<absl::Status> sender_status` .. `for (std::thread& t : senders) t.join();`) | `:813-873` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` (`if (delivery_.controller == nullptr)`) | `:815-821` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` (`for (const absl::Status& status : sender_status)`) | `:876-878` |
| `kv_cache_listener.cc` | `KVCacheListener::HandleControlRequest` (`} else if (is_pool_reshard) {` .. `(*resp->mutable_receiver_pool_addrs())[pool_idx] =`) | `:138-169` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardPush` | `:732-774` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` | `:776-825` |
| `reshard_recv.cc` | `CreateReshardReceiveSession` | `:519-553` |
| `reshard_recv.cc` | `ReshardReceiveSession::AcquireStagingLeases` | `:581-620` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReleaseStagingLocked` | `:622-627` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReleaseStaging` | `:629-632` |
| `reshard_recv.cc` | `ReshardReceiveSession::RecordPoolH2dResultLocked` | `:763-776` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishPoolH2d` | `:857-893` |
| `planner.cc` | `SplitGlobalSpaceSpans` | `:267-338` |
| `planner.cc` | `ValidateSpanCoverage` | `:350-487` |
| `planner.cc` | `BuildPoolReshardPlan` (`auto registrations_or =` .. `if (!registrations_or.ok()) return registrations_or.status();`) | `:1119-1121` |
| `planner.cc` | `BuildPoolReshardPlan` (`if (unique_peers.size() != request.dst_units.size())`) | `:1136-1142` |
| `planner.cc` | `BuildPoolReshardPlan` (`PoolReshardPlan plan;` .. `plan.dst_units = request.dst_units;`) | `:1289-1295` |
| `reg.cc` | `RequestBlockRegistry::Register` | `:118-300` |
| `reg.cc` | `RequestBlockRegistry::Complete` | `:317-371` |
| `reg.cc` | `RequestBlockRegistry::LookupAndClaim` | `:439-491` |
| `reg.cc` | `RequestBlockRegistry::AbandonClaim` | `:493-509` |
| `reshard_service.cc` | `ReshardService::HandleControllerCommand` (`case tpu_sync::rpc::ControllerRequest::COMMAND_COMPLETE_REQUEST_BLOCKS:`) | `:293-305` |
| `reshard_service_test.cc` | `ReshardStackTest.FullPoolReshardFlowEmitsArmThenDispatch` | `:801-875` |
| `reshard_service_test.cc` | `ReshardStackTest.GlobalSpaceSpansSplitAtPageBoundaries` | `:877-918` |
| `reshard_service_test.cc` | `ReshardStackTest.ClipDropsTrimsAndRebasesGlobalSpans` | `:920-976` |
| `reshard_service_test.cc` | `ReshardStackTest.ClipValidationFailsClosed` | `:1361-1394` |
| `reshard_service_test.cc` | `ReshardStackTest.ClipRejectsPageIndexedDeclarations` | `:1396-1408` |
| `reshard_service_test.cc` | `ReshardStackTest.MissingRegistrationKeepsContractString` | `:1410-1420` |
| `reshard_service_test.cc` | `ReshardStackTest.ArmFailureAbandonsClaimAndSkipsSenders` | `:1422-1438` |
| `reshard_service_test.cc` | `ReshardStackTest.RequestBlockStatusProbeTracksLifecycle` | `:1470-1534` |
| `reshard_service_test.cc` | `ReshardStackTest.CompletionVotesRetireAfterClaim` | `:1536-1559` |
| `reshard_service_test.cc` | `ReshardStackTest.TwoDestinationsArmEachThenDispatchSendersOnce` | `:1572-1642` |
| `reshard_service_test.cc` | `ReshardStackTest.SubsetSourceManifestsPairPoolsByTag` | `:1644-1783` |
| `reshard_service_test.cc` | `ReshardStackTest.SourceTagsAbsentOnTheDestinationAreIgnored` | `:1897-1978` |
| `reshard_service_test.cc` | `ReshardStackTest.MismatchedDestinationsFailClosed` | `:1980-2018` |
| `reshard_service_test.cc` | `ReshardStackTest.TwoDestinationsShardedSpansRouteBytesPerReceiver` | `:2023-2088` |
| `reshard_service_test.cc` | `ReshardStackTest.StridedGlobalSpansStayOneEntryPerDestination` | `:2090-2145` |
| `reshard_service_test.cc` | `ReshardStackTest.StridedGlobalSpansMustStayInsideOnePage` | `:2180-2190` |
| `reshard_service_test.cc` | `ReshardStackTest.ShardedSpanOrdinalOutOfRangeFailsClosed` | `:2192-2207` |
| `reshard_service_test.cc` | `ReshardStackTest.ShardedDestinationWithoutCoverageFailsClosed` | `:2209-2222` |
| `reshard_service_test.cc` | `ReshardStackTest.ShardedNonUniformExtentsFailClosed` | `:2224-2238` |
| `reshard_service_test.cc` | `ReshardStackTest.ReplicatedAndRoutedSpansCombine` | `:2251-2283` |
| `reshard_service_test.cc` | `ReshardStackTest.UnsetTransferStreamsPlansOneStreamPerSourceRank` | `:2325-2345` |
| `reshard_service_test.cc` | `ReshardStackTest.TransferStreamsEnvCapsPlanStreamsAndExpectedPushes` | `:2347-2367` |
| `reshard_service_test.cc` | `ReshardStackTest.DuplicateRegistrationRefreshesTtlWhileConflictsAndPostClaimWritesFail` | `:2405-2436` |
| `reshard_service_test.cc` | `ReshardStackTest.CompletionNoOpsAndPreClaimGuard` | `:2469-2531` |
| `reshard_service_test.cc` | `ReshardStackTest.ForcedReleaseClearsEveryLifecycleState` | `:2562-2625` |
| `reshard_service_test.cc` | `ReshardStackTest.TwoDestinationsOneArmRefusalAbandonsClaimAndSkipsSenders` | `:2627-2665` |
| `reshard_service_test.cc` | `ReshardStackTest.SenderDispatchFailurePropagatesErrorAfterReceiverArm` | `:2667-2703` |
<!-- source-map:end -->
-/
