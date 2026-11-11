# Pool-reshard transfer: model and results

The reference map from the pool-addressed resharding KV-cache transfer C++ to
its Lean models under `TpuSyncVerify/Transfer/Reshard/`.

Each module's docstring owns its state table, event table, assumptions,
properties and `## Source map`; this page routes between them. It says what is
proved and where, lists the modules, draws the three boundaries of the model,
tabulates the assumptions and how each is discharged, sets the shipping code
beside the design alternatives modelled next to it, lists the mutants, and ends
with the per-symbol C++ → Lean index. Each `trace_*` theorem's docstring names
the C++ test it replays, so `grep -rn <TestName> TpuSyncVerify` answers "is
test X modelled".

File aliases: `reshard_recv.cc` = `tpu_sync/kv_cache/reshard_receive_session.cc`
(the `ReshardReceiveSession` class lives in its anonymous namespace; the header
`reshard_recv.h` declares only `CreateReshardReceiveSession`),
`reshard_send.cc` = `tpu_sync/kv_cache/reshard_send_session.cc` (likewise
`ReshardSendSession` and `CreateReshardSendSession` in `reshard_send.h`),
`slots.cc` = `tpu_sync/core/pool_reshard_send_slots.cc`,
`mgr.{h,cc}` = `tpu_sync/kv_cache/kv_cache_manager_with_transfer.{h,cc}`,
`base.{h,cc}` = `tpu_sync/kv_cache/kv_cache_manager_base.{h,cc}`,
`raw_core.h` = `tpu_sync/core/raw_transfer_core.h`,
`bt.cc` = `tpu_sync/transport/block_transport.cc`,
`bts.cc` = `tpu_sync/transport/block_transport_session.cc`,
`tpu_sync/transport/transfer_session.h` (the `TransferSession` interface, cited by
its full path),
`planner.cc` = `tpu_sync/kv_cache/reshard/pool_reshard_planner.cc`,
`reg.{h,cc}` = `tpu_sync/kv_cache/reshard/request_block_registry.{h,cc}`,
`coord.{h,cc}` = `tpu_sync/kv_cache/reshard/reshard_coordinator.{h,cc}`,
`pool_reshard_test.cc` = `tpu_sync/kv_cache/kv_cache_manager_with_transfer_pool_reshard_test.cc`,
`reshard_send_test.cc` = `tpu_sync/kv_cache/reshard_send_session_test.cc`,
`reshard_recv_test.cc` = `tpu_sync/kv_cache/reshard_receive_session_test.cc`,
`reshard_service_test.cc` = `tpu_sync/kv_cache/reshard/reshard_service_test.cc`.

## What is proved

Every theorem below is proved on every reachable state of its model; the
statement column is the one-line form, the module docstring has the exact one.

| Property | Theorems | Statement |
|---|---|---|
| Publication correctness and aliased-page rank-wave safety | `Pipeline.reachable_safe`, `Pipeline.reachable_unarmed_safe` (`PublicationCorrect`, `AliasedPageCorrect`), `Pipeline.attention_safe`, `Recv.RankWaveOrder` (`rankWaveOrder_iff`) | No pool is queued, issued, or completed for H2D while any strictly lower-rank pool is not yet `completed`, so lower-rank H2D waves never clobber completed higher-rank pool bytes on shared hybrid-model device pages; when `poll_stats()` publishes `done_recving`, `dstHbm = good numPools` and stays invariant afterwards. |
| Data correctness and post-publication safety across transfers | `Pipeline.system_data_correct`, `Pipeline.system_attention_safe`, `Pipeline.system_unarmed_data_correct`, `Pipeline.system_unarmed_attention_safe` | In any reachable state of `multiSys` or `multiSysUnarmed` (concurrent, overlapped and recycled reshard transfers), no transfer ever writes any of its four buffers after releasing them (`wroteReleased = false`) or reads from recycled `srcHbm`, `srcStaging`, or `dstStaging`; whenever a transfer publishes `done_recving`, its `dstHbm` holds `good ranks.length` and stays equal to `good ranks.length` across every subsequent transition of any transfer. |
| Progress across transfers | `Pipeline.system_progress`, `Pipeline.system_unarmed_progress` | From any reachable multi-transfer state (`multiSys` or `multiSysUnarmed`), any transfer can settle, release both staging leases to `PoolStagingStorage`, and publish both outcomes (`HandedOff`) in finitely many steps, enabling both `.recycleSrc` and `.nextRequest`. |
| Sub-block byte-interval coverage and reconstruction | `Coverage.partition_reconstructs_block`, `Coverage.partition_reconstructs_perm`, `CoveragePipeline.step_pipe`, `CoveragePipeline.reachable_safe` | Any sub-block interval set accepted by `ValidateReceiverCoverage` forms a complete disjoint partition of `[0, extent)` and reconstructs `good extent` under every stream arrival permutation. |
| Multi-sender stream count conservation | `Coverage.stream_count_matches`, `Coverage.senderStreams_pos_iff`, `Pipeline.StreamAccountingSafe` | For every pool group, the receiver's `expected_pushes` validated by `ValidateReceiverCoverage` equals $\sum_s \min(\text{parallelism}, |\text{pairs}_s|)$; a sender with zero scheduled pairs opens zero streams; and `OnPoolReceived(p)` fires only after all `expected_pushes` streams for pool `p` have landed. |
| Destination and source HBM quietness | `Pipeline.DstHbmSafe`, `Pipeline.dstHbm_quiet`, `Pipeline.SrcHbmSafe`, `Pipeline.srcHbm_quiet` | Once the receive is published no H2D copy is pending or unretired (`dstHbm` never changes afterwards); once the send is published no D2H copy is pending or unretired (`srcHbm` may be reclaimed). |
| Bounded host-staging slot conservation, disjointness, and registration safety | `PoolStaging.no_slot_aliasing_between_distinct_uuids`, `PoolStaging.acquireLease_idempotent`, `PoolStaging.allocateMissing_slot_sum`, `PoolStaging.reachable_reserveBeforeLease_safe`, `Pipeline.StagingSafe` | In `PoolStagingStorage`, distinct active UUIDs hold disjoint physical slot lists and never resolve any block IDs to the same staging slot; re-acquiring a shared storage for the same `uuid` is idempotent; under `reserveBeforeLease`, every active session retains its staging lease until it settles; and released staging is never read or written by the session that held it. |
| Termination and drain-to-settle liveness | `Recv.NoOpLeak`, `Send.NoOpLeak`, `Pipeline.NoOpLeak`, `Recv.reachable_can_settle`, `Send.reachable_can_settle`, `Pipeline.reachable_can_settle`, `Pipeline.reachable_unarmed_can_settle` | Every unit of `in_flight_` has an enabled transition that advances or retires it, and every reachable state drains to `done ∧ ¬hasStaging` in finitely many steps. |
| Sender slot conservation and active-until-finalizing invariant | `Send.reachable_safe` (`ActiveOrDraining`, `Publication`) | While `!finalizing_`, `remaining_pool_peer_pushes_` equals $\sum_p \text{remainingSlots}_p$, and `Start`'s caller op (held across `ExecutePushPipeline`) keeps `0 < inFlight` until `finalizing_` is latched; `done_sending` requires every active pool to have completed all peer pushes. |
| Plan visibility | `Recv.SettleSafe`, `Recv.NoRetiredCallback`, `Send.SettleSafe`, `Send.NoRetiredCallback`, `Send.trace_partial_failure_keeps_plan` | Each session owns its `TransferPlan` and `plan()` returns it until `Done()` (`transfer_plan_ == nullptr \|\| Done()` → `absl::nullopt`), so plan visibility needs no state of its own: the plan is visible exactly while `!done`, and `SettleSafe` with `NoRetiredCallback` says nothing that resolves chunks or staging through it is still in flight once it is gone. The receiver has no poll-side finish (`CompleteReadWithDetails` only deadline-finishes a `ReshardReceiveSession`; `FinishPoolH2d` calls `Finish` itself on the last pool); on the sender `RecordPushCompletion` latches `finalizing_` on the first failed push while sibling pools still have ops in flight, and the plan stays visible until the last op drains in `EndOp` (`trace_partial_failure_keeps_plan`). |
| Two-phase Arm-then-Dispatch barrier and producer block registry | `Coordinator.reachable_coord_inv`, `Coordinator.no_push_before_all_armed`, `Coordinator.claimed_while_arming`, `Pipeline.NoUnarmedPush`, `Registry.reachable_safe`, `Registry.tombstone_blocks_register_and_claim`, `Registry.claimed_blocks_register_and_cancel`, `Registry.abandonClaim_preserves_when_other_owner_present`, `Registry.complete_retires_iff_all_claimed_voted`, `Registry.purgeExpiredAll_inv` | No sender is dispatched and no stream lands until every destination unit has armed its `ReshardReceiveSession`; producer blocks remain claimed in `RequestBlockRegistry` throughout arming, blocking `CancelIfUnclaimed` and duplicate `Register`; abandoning one owner's claim preserves sibling owners' claims; `Complete` retires a generation iff every claimed source unit has voted; and cancelling an unclaimed generation leaves a tombstone blocking late registration and claims. |
| Multi-window sub-plan chains: planner, worker chain folding, coordinator chain | `SubPlanChain.subPlanUuid_zero`, `SubPlanChain.subPlanUuid_pos_of_pos`, `SubPlanChain.planSubTransfers_no_aliased_window_split`, `SubPlanChain.reachable_worker_safe`, `SubPlanChain.reachable_sweepWaitsForOpen_safe`, `SubPlanChain.reachable_coordChain_safe` | `SubPlanUuid` fixes index 0 and emits strictly positive `splitmix64` IDs for `index > 0`; `PlanSubTransfers` never splits a request whose windowed tag shares destination block IDs with another tag (preserving intra-plan `order_rank` H2D wave ordering); on each worker, under A1, A2, A5–A7 (and without A5b or A5c under `WorkerState.stepSweepWaitsForOpen`), `done_recving` / `done_sending` for a `count`-plan request is inserted only with `count` distinct sub-plan indices settled OK (`DoneAfterAllSubPlans`); across the chain the coordinator never leaves a dispatched rank without the registry claim (`NoSenderExposed`, the `if (index == 0)` guard), dispatches no sender while a window arms, has every destination armed while it dispatches, paces each window's arm behind the previous window's lease release under single-window destination staging capacity (A8, `OneWindowStagedPerDestination`), publishes `kCompleted` only after the last window, and holds the claim from window 0 to the end of the chain. |
| Engine caller contract above `poll_stats()` (single- and multi-worker) | `Caller.contract_safe`, `Caller.mw_contract_safe`, `Caller.twoChannel_contract`, `Caller.earlyLoadError_fail_eq_finish`, `Caller.earlyLoadError_fail_holds_blocks`, `Caller.leakP_absorbing`, `Caller.leakD_absorbing`, `Caller.mwLeakP_absorbing`, `Caller.mwLeakD_absorbing` | A connector that forwards every publication (`connectorTwoChannel`, matching `vllm-torchtpu`'s Stage-3 `tpu_connector.py` over `AggChannel.eagerBlock`) never frees HBM while any worker on that node is still in flight (`mwEarlyFree = false`), leaks no held block on either node, and never lets decode read unwritten KV, both for a single worker and across workers aggregated by `KVOutputAggregator`; staging `invalid_block_ids` early on an uncertain post-arm RPC error under `Policy.fail` defers the block free until the native receiver settles (`dHeld = true`). |

## Modules

Higher modules compose the lower `step` functions directly: `Pipeline` composes
`Send.step` and `Recv.step` with per-pool stream counters, five pool-indexed
memories (`srcHbm`, `srcStaging`, `wire`, `dstStaging`, `dstHbm`), aliased-page
overwrite (`writePoolHbm`), and the coordinator's Arm-then-Dispatch barrier;
`Coverage` refines `Pipeline`'s scalar stream counter into sub-block byte
intervals via a lockstep forward simulation (`CoveragePipeline.step_pipe`);
`Coordinator` composes `Registry.step` with multi-destination receiver arming
and `PoolStagingLease` lifecycles.

| Module | Scope | Main theorems |
|---|---|---|
| `Common/ListAux.lean`, `Transfer/Session.lean` | List indexing helpers and the shared settle protocol (`in_flight_`, `draining_`, `done_`, staging lease) | `Lifecycle.Consistent` preserved by `beginOp` / `finishLocked` / `endOpLocked` |
| `Reshard/Receive.lean` | One `ReshardReceiveSession` + the manager's deadline sweep and `RetireSettledSessionLocked`: static plan/pool validation (`validPlan`, `validPlanPoolsAndBlocks`), rank-gated `CollectEligiblePoolH2dsLocked`, batch `in_flight_ += to_launch.size()`, `ExecuteEligiblePoolH2ds` (`draining_` early exit), `FinishPoolH2d`, `plan()` visibility until `Done()`, `PushEndPolicy` (`finishOnError` vs. `endOpOnly`) | `Recv.reachable_safe` (`SettleSafe`, `NoRetiredCallback`, `StagingIntegrity`, `SettlesPromptly`, `RankWaveOrder`, `Publication`, `NoOpLeak`), `Recv.rankWaveOrder_iff`, `Recv.reachable_can_settle` |
| `Reshard/Send.lean` | One `ReshardSendSession` (`CountPoolReshardSendSlots`): `Start`'s caller op and per-pool D2H (`ExecutePushPipeline`), per-peer `StartPoolPush`, `remaining_pool_peer_pushes_` conservation, `finalizing_` latched in `RecordPushCompletion` (first error or last push) and settlement in `EndOp` | `Send.reachable_safe` (`SettleSafe`, `NoRetiredCallback`, `StagingIntegrity`, `SettlesPromptly`, `ActiveOrDraining`, `Publication`, `NoOpLeak`), `Send.reachable_can_settle`, `Send.trace_partial_failure_keeps_plan`, `Send.trace_start_fails_fast`, `Send.trace_finish_after_last_push` |
| `Reshard/Pipeline.lean` | Single reshard transfer: `Send` + `Recv` + per-pool `BlockTransport` stream counters + five pool-indexed memories + aliased-page `writePoolHbm` (`clobberHigherRanks`) + Arm-then-Dispatch barrier (`init` vs. `initUnarmed`) | `Pipeline.reachable_safe`, `Pipeline.reachable_unarmed_safe` (`PublicationCorrect`, `AliasedPageCorrect`, `DstHbmSafe`, `SrcHbmSafe`, `StagingSafe`, `StreamAccountingSafe`, `NoUnarmedPush`, `NoOpLeak`), `Pipeline.attention_safe`, `Pipeline.dstHbm_quiet`, `Pipeline.srcHbm_quiet`, `Pipeline.reachable_can_settle`, `Pipeline.reachable_unarmed_can_settle` |
| `Reshard/MultiRequest.lean` | `multiSys` and `multiSysUnarmed`: concurrent and overlapped reshard transfers (`recycleSrc`, `nextRequest`), per-buffer write-after-release checks (`wroteReleased`), and post-publication HBM safety across transfers | `Pipeline.system_data_correct`, `Pipeline.system_attention_safe`, `Pipeline.system_progress`, `Pipeline.system_unarmed_data_correct`, `Pipeline.system_unarmed_attention_safe`, `Pipeline.system_unarmed_progress`, `Pipeline.trace_multi_request`, `Pipeline.trace_overlapped_requests`, `Pipeline.trace_unarmed_multi_request`, `Pipeline.trace_mutant_write_after_release_corrupts_all` |
| `Reshard/Coverage.lean` | Multi-sender stream count conservation (`Σ_s min(parallelism, \|pairs_s\|) = expected_pushes`), the sender's slot count (`CountPoolReshardSendSlots`), `DefaultTransferStreams` (`TPU_RAIDEN_TRANSFER_STREAMS`), `ValidateReceiverCoverage` interval-partition completeness, and byte-level refinement `CoveragePipeline` over `Pipeline` | `Coverage.stream_count_matches`, `Coverage.senderStreams_pos_iff`, `Coverage.partition_reconstructs_block`, `Coverage.partition_reconstructs_perm`, `CoveragePipeline.step_pipe`, `CoveragePipeline.reachable_safe` |
| `Reshard/PoolStaging.lean` | `PoolStagingStorage` bounded slot arena, per-`(storage, uuid)` lease idempotency & cross-UUID disjointness, and receive registration order (`RegistrationPolicy.reserveBeforeLease` vs. the `.leaseBeforeReserve` mutant) | `PoolStaging.acquireLease_idempotent`, `PoolStaging.no_slot_aliasing_between_distinct_uuids`, `PoolStaging.allocateMissing_slot_sum`, `PoolStaging.reachable_reserveBeforeLease_safe`, `PoolStaging.trace_duplicate_uuid_frees_survivor_lease_and_aliases_slot`, `PoolStaging.trace_pool_staging_recv_registration_tests` |
| `Reshard/Registry.lean` | `RequestBlockRegistry` generation lifecycle: per-unit `Register`, multi-owner `LookupAndClaim` (refreshing claimed rows' `expires_at` alongside `claimed_`), `AbandonClaim`, full-set `Complete` voting, `CancelIfUnclaimed` tombstones, and TTL expiration (`purgeExpiredAll`) | `Registry.reachable_safe`, `Registry.tombstone_blocks_register_and_claim`, `Registry.claimed_blocks_register_and_cancel`, `Registry.abandonClaim_preserves_when_other_owner_present`, `Registry.complete_retires_iff_all_claimed_voted`, `Registry.purgeExpiredAll_inv`, `Registry.trace_single_stage_votes_retire_multi_owner_claim`, `Registry.trace_claim_refreshes_registration_ttl_while_failed_claim_does_not`, mutant `Registry.mutant_split_ttl_purges_request_blocks_while_claim_active` |
| `Reshard/Coordinator.lean` | One sub-plan (`ReshardCoordinator::RunSubPlan`) of `ReshardCoordinator::ExecutePoolReshard` composed with `RequestBlockRegistry` and per-destination receiver sessions | `Coordinator.reachable_coord_inv`, `Coordinator.no_push_before_all_armed`, `Coordinator.claimed_while_arming`, `Coordinator.trace_partial_arm_orphans_armed_receiver`, `Coordinator.trace_dispatch_failure_orphans_receivers_and_claim`, `Coordinator.trace_disarm_and_abandon_cleans_up_both_aborts` |
| `Reshard/SubPlanChain.lean` | Multi-window chains: `PlanSubTransfers` and `SubPlanUuid` (`splitmix64`), the worker's `sub_plan_chains_` folding over `SubPlanChainProgress::sub_sessions` (`NoteSubPlanRegisteredLocked`, `RecordPoolReshardTerminalLocked`, `SweepSubPlanChainsLocked`; `ChainProgress{subSessions, completed, failed, anchored}`, one entry per `req_id` shared by both roles), and `StartPoolReshard` / `StartChain` / `RunSubPlan(0 .. K-1)` over `RequestBlockRegistry` with the `ArmRefusedForBusyStaging` re-arm loop and sparse per-window `plan.src_units` | `SubPlanChain.subPlanUuid_zero`, `SubPlanChain.subPlanUuid_pos_of_pos`, `SubPlanChain.planSubTransfers_no_aliased_window_split`, `SubPlanChain.reachable_worker_safe`, `SubPlanChain.reachable_coordChain_safe`, `SubPlanChain.trace_send_terminal_waits_for_last_sub_plan`, `SubPlanChain.trace_sender_in_first_window_only`, `SubPlanChain.trace_first_failure_reports_while_sibling_active`, `SubPlanChain.trace_chained_arm_failure_keeps_claim_past_last_vote`, `SubPlanChain.mutant_abandon_at_every_index_exposes_active_sender`, `SubPlanChain.mutant_no_deadline_arm_reports_done_after_sweep`, `SubPlanChain.mutant_single_plan_registration_erases_live_chain`, `SubPlanChain.mutant_slot_overwrite_reports_stray_done` |
| `Transfer/Caller.lean` | Serving engine above `poll_stats()` shared with `PrefillDecode` (`vllm-torchtpu` `tpu_connector.py` and `tpu-inference` `tpu_raiden_connector.py` on vLLM): `connectorTwoChannel` models Stage-3 reshard outcome forwarding, `MultiWorker.lean` models `KVOutputAggregator` across worker ranks (`AggChannel.eagerBlock` and `AggChannel.latchedReq`), and `earlyLoadError_fail_holds_blocks` models `_stage3_fail_uncertain_loads_early` | `Caller.contract_safe`, `Caller.mw_contract_safe`, `Caller.twoChannel_contract`, `Caller.applyRecv_eager_eq_latched`, `Caller.earlyLoadError_fail_eq_finish`, `Caller.earlyLoadError_fail_holds_blocks`, `Caller.leakP_absorbing`, `Caller.leakD_absorbing`, `Caller.mwLeakP_absorbing`, `Caller.mwLeakD_absorbing`, `Caller.trace_mw_staggered_*` |

## Boundaries

The model sits between three boundaries. Each side names the module that owns
it; the arguments are in those modules.

### Subsystem boundary

In scope is pool-addressed KV-cache resharding: `ReshardReceiveSession`,
`ReshardSendSession`, `CountPoolReshardSendSlots`, `DefaultTransferStreams`,
the output contracts of `ValidatePlan` / `ValidateReceiverCoverage`,
`PoolStagingStorage` bounded leases, `RequestBlockRegistry`, and
`ReshardCoordinator` (`PlanSubTransfers`, `SubPlanUuid`, `ExecutePoolReshard`,
`StartChain`, `RunSubPlan`) together with worker-side `SubPlanChainProgress`
terminal folding (`NoteSubPlanRegisteredLocked`,
`RecordPoolReshardTerminalLocked`, `SweepSubPlanChainsLocked`).

Out of scope: prefill-to-decode ("symmetric") transfer — see
[prefill_decode.md](prefill_decode.md); pure planner geometry and transfer-program
lowering (`tpu_sync/kv_cache/reshard/pool_reshard_planner.cc` and
`tpu_sync/core/transfer_program_reshard.cc`, which compile topology geometry
into `StartTransferRequest` plans validated by `ValidatePlan` /
`ValidateReceiverCoverage`); `RaidenController`, `kv_cache_store`, and
`weight_sync/` model-weight resharding.

### Coordinator and engine boundary (above the sessions)

Modelled: the `RequestBlockRegistry` and `ReshardCoordinator` two-stage and
multi-window protocols — per-tag `dst_window_blocks` chain planning
(`PlanSubTransfers`, `SubPlanUuid`), producer block registration (`Register`),
multi-owner `LookupAndClaim`, `CancelIfUnclaimed` tombstones, Stage 1
destination arming (`PoolReshardRegisterRecv`, including
`ArmRefusedForBusyStaging` retries across `StartChain` windows), Stage 2 sender
dispatch (`PoolReshardPush`, including sparse per-window `plan.src_units`),
per-unit `Complete` voting, worker `SubPlanChainProgress` terminal folding
(`NoteSubPlanRegisteredLocked`, `RecordPoolReshardTerminalLocked`,
`SweepSubPlanChainsLocked`) and `CompleteReadWithDetails` (`poll_stats()`)
outcome publication (`Reshard/SubPlanChain.lean`), and the connector/scheduler
block lifecycle above `poll_stats()` (`Transfer/Caller.lean`: when the engine
may recycle is `.recycleSrc` / `.nextRequest` in `Reshard/MultiRequest.lean`;
what the engine owes a publication is `Caller.Contract`, satisfied by
`connectorTwoChannel` for `vllm-torchtpu`'s Stage-3 connector both for a single
worker and across workers aggregated by `KVOutputAggregator` in
`Caller/MultiWorker.lean` (`AggChannel.eagerBlock`), including its early
`invalid_block_ids` path `_stage3_fail_uncertain_loads_early` via
`earlyLoadError_fail_holds_blocks` and `mw_earlyLoadError_fail_holds_blocks`).

Not modelled: Python submit-worker threading and topology-admission tables in
the external connector above `ReshardService`, partial-prefix load failures and
preemption/prefix caching (`Caller` B2–B3), disjointness of destination device
pages across concurrent transfers (`MultiRequest` A1: all pools sharing a
`storage_index` use a uniform `block_stride_bytes` in `ConfigurePoolStaging` so
blocks $b \neq b'$ occupy disjoint device byte ranges $[b \cdot S, (b+1) \cdot S)$,
and the engine's unified `[0, num_blocks)` block pool hands out distinct
uncached `dst_device_block_ids` across all cache groups to concurrent transfers),
and disjointness of source and destination units (`src_units ∩ dst_units = ∅`),
which is treated as a caller/planner precondition (`BuildStartTransferForTarget`
sets both `is_sender = true` and `is_receiver = true` when a unit appears in
both lists, so `KVCacheListener::HandleControlRequest` routes its Phase 1 arm
RPC to `PoolReshardPush` instead of `PoolReshardRegisterRecv` and never arms a
`ReshardReceiveSession` on that unit).

### Transport and staging boundary (below the session callbacks)

Modelled: the per-`(uuid, pool)` stream accounting, sub-block interval coverage,
and `PoolStagingStorage` slot maps — the incoming-push op (`BeginIncomingPush` =
`KVCacheManagerBase::GetSession(uuid)` + `TryBeginOp`, `EndIncomingPush` =
`Finish(status)` on error then `EndOp`, both free functions in `bts.cc` called
from `StartStream`; `ReshardSendSession::TryBeginOp` returns `false`, so a
push aimed at a sender is `Cancelled`), `CompleteIncomingPush` counting completed streams against
`expected_pushes` before delivering the pool completion once
(`session->OnDataReceived(pool_idx, {}, {})` on the session `BeginIncomingPush`
returned → `ReshardReceiveSession::OnPoolReceived`), sub-block
byte-interval partition on destination staging (`Coverage.lean`), and
per-`(storage_idx, uuid)` slot allocation and release in `PoolStagingStorage`
(`PoolStaging.lean`).

Not modelled: raw TCP socket loops and wire framing (`peregrine::v1::ReadExact`
/ `ReadVExact` / `WriteExact`, TCP connection pooling, and per-transfer idle
connection release in `ReshardSendSession::EndOp`), and raw pointer `memcpy` /
PJRT `CopyRawHostToDevice` / `CopyRawDeviceToHost` internals, which are
collapsed into atomic state-machine transitions (`d2hDone`, `landStream`,
`h2dIssue`, `h2dDone`).

### Bounded host layer staging

On a full host mirror (`!HostLayersBounded()`, i.e.
`KVCacheManagerBase::num_host_layers() == num_layers()`, the default when
`num_staging_layers` is unset), both reshard sessions construct their
`StagingLayerManager` with `0` slots and return `StaticHostLayer(pool_idx)`
(`base_->pool(pool_idx)->storage_index`, for explicit and implicit pools alike;
`NotFound` only for a `pool_idx` outside the pool table, which plan validation
rejects) from `AcquireStagingSlot` and
`LookupStagingSlot`, staging each pool in place in its own storage's host
buffer (`ReshardSendSessionTest.FullHostMirrorStagesPoolsInPlace`,
`ReshardReceiveSessionTest.FullHostMirrorAddressesPoolsInPlace`,
`PoolStagingTest.FullHostMirrorKeepsHeterogeneousStorageSizes`; `Pipeline.lean`'s
per-pool `srcStaging` / `dstStaging` cells assume concurrent pools do not share
overlapping byte extents on the same `(storage_index, block_id)`). When host
layers are bounded (`HostLayersBounded()`, `num_host_layers() < num_layers()`
under `num_staging_layers`), both sessions construct `staging_layer_manager_`
with `num_host_layers()` slots and lease one buffer per **pool index**:
`TransferSession::ResolveStagingSlot(pool_idx)` is queried from
`GetBlockChunks` and from `ValidateChunks` (`GetBlockArrayHostSpan` →
`ResolveBlockArrayHostLayer`); `ReshardSendSession::LookupStagingSlot` returns
the buffer `ExecutePushPipeline` leased before the pool's D2H
(`AcquireStagingSlot`, waiting in `StagingLayerManager::Acquire` for an earlier
pool's pushes to return theirs, until `deadline_` or `cancelled_`), and
`ReshardReceiveSession::AcquireStagingSlot` leases one on first use inside an
op of its own (`++in_flight_` / `EndRecvOpLocked()`, failing the receive on a
timeout). Each session's `Shutdown()` runs where `FinishLocked` /
`RecordPushCompletion` / `Finish` latch draining, buffers are returned on every
early return and callback, and `ReleaseAll()` runs at settle
(`ReleaseLeasesLocked` / `ReleaseStagingLocked`). The reshard models carry none
of this slot state (matching the full host mirror directly when concurrent
pools stage into disjoint host bytes, or `num_host_layers()` at least the
plan's active pool count under `num_staging_layers`). Each module's docstring
(`Reshard/Send.lean`, `Reshard/Receive.lean`, §"Bounded host layer staging")
explains why every safety invariant (`Safe`) still holds under bounded host
layers when pools outnumber `num_host_layers()` — the waits sit inside
`d2hIssue` and the push's own op, and a timed-out or cancelled wait takes the
error or `cancel` arm the model already has — and where progress differs: on
the sender, `ExecutePushPipeline` acquires in rank-sorted order and releases on
push completion so extra pools serialize behind earlier pushes, whereas on a
multi-rank receiver, gated higher-`order_rank` pools whose first chunks arrive
early can hold every buffer until `deadline_` fails the receive
(`FinishLocked(slot.status())`) while a lower-rank pool's push thread blocks in
`StagingLayerManager::Acquire`. The slot manager itself is proved in
`Transfer/LayerStaging.lean` (`StagingLayerManager.lookup_injective`,
`acquire_idempotent`, `shutdown_cancels`) and its multiplexing over a
layer-ordered pipeline in `PrefillDecode/LayerStaging.lean`; the per-session
reshard tests on the bounded-slot path are
`ReshardSendSessionTest.BoundedStagingSlotAcquisitionAndRelease`,
`PipelineSlotWaitTimeoutSettlesSendOutOfBand`,
`StagingSlotReleasedAfterLastPeerPush`, and
`ReshardReceiveSessionTest.BoundedStagingSlotAcquisitionAndRelease` /
`OutOfOrderPoolArrivalResolvesLeasedHostBufferForValidation`.
`PoolStagingStorage` leases (`PoolStaging.lean`) are a different bound: the
arena of host *blocks* a pool reshard uuid may address inside a storage, not
the number of host layer buffers.

## Assumptions and how each is discharged

The session and sub-plan chain modules number their assumptions (`Receive` A1–A4,
`Send` A1–A4, `SubPlanChain` A1–A8); the full statements and arguments are in the
module docstrings.

| Assumption | One-line statement | Status |
|---|---|---|
| Pipeline / MultiRequest engine contract | Destination reads `dstHbm` only after `done_recving`; producer reclaims `srcHbm` only after transfer settlement. | External contract; encoded as the guards of `.recycleSrc` / `.nextRequest` in `Reshard/MultiRequest.lean`. The other direction is `Transfer/Caller.lean`. |
| MultiRequest A1 — cross-transfer destination page disjointness | Destination device pages (`dstHbm`) of distinct concurrent transfers are disjoint, guaranteed by the allocator. | All pools sharing a `storage_index` have a uniform `block_stride_bytes` and `num_blocks` (`ConfigurePoolStaging`) and fit inside `[b * stride, (b + 1) * stride)` (`PoolSpec::Validate(storage_bytes)` when `storage_bytes = num_blocks * stride`, and the caller's manifest builder), so blocks $b \neq b'$ never overlap in device bytes; the engine's unified `[0, num_blocks)` block pool hands out distinct uncached `dst_device_block_ids` across all cache groups to concurrent transfers, and host arena slots are disjoint across `uuid`s (`PoolStaging.no_slot_aliasing_between_distinct_uuids`). |
| Receive A1 — at-most-once `OnPoolReceived` per declared pool | `CompleteIncomingPush` delivers the pool completion (`session->OnDataReceived(l, {}, {})` → `ReshardReceiveSession::OnPoolReceived`) only when `plan_pushes == expected_chunks`, and `RecordPoolReceivedLocked` rejects undeclared or duplicate pool indices. | Discharged: `Pipeline.StreamAccountingSafe`, `Coverage.stream_count_matches`, `CoveragePipeline.step_pipe`. |
| Receive A2 — registration before visibility | `PoolReshardRegisterRecv` reserves the uuid in `pending_pool_reshard_recvs_` (under `mu_`, after retiring a settled incumbent; `PoolStaging` additionally assumes fresh UUIDs across `CompleteReadWithDetails`'s unlocked post-poll lease cleanup) before `CreateReshardReceiveSession` validates the plan and runs `AcquireStagingLeases`; the session enters `sessions_` (as a `SessionEntry` of role `kPoolReshardReceive`) only once the factory succeeds, a failed factory call releases its leases (`ReleaseStaging`) and the `absl::Cleanup` drops the reservation. | Discharged: `PoolStaging.reachable_reserveBeforeLease_safe`, `Coordinator.no_push_before_all_armed`. |
| Receive A3 / Send A3 — no double end and single `StartPoolPush` lock step | Each admitted push and each H2D/D2H op ends at most once; `StartPoolPush`'s two `done_ \|\| finalizing_` checks inspect only immutable plan fields in between and fold into `d2hDone`. | C++ callback and control-flow discipline. |
| Receive A4 — fold of `RecordPool*Locked` with `ExecuteEligiblePoolH2ds` first lock | An external `Finish` between unlocking `mu_` after recording a pool and locking `mu_` in `ExecuteEligiblePoolH2ds` produces the same state as `cancel` arriving before the event, whereas one arriving after `in_flight_ += to_launch.size()` is `cancel` after the event. | Soundness argument in `Receive.lean` (`trace_cancel_between_batch_queue_and_issue`). |
| Send A1 — non-empty schedule with positive peer counts per active pool | `CreateReshardSendSession` rejects `remaining_pool_peer_pushes <= 0`, and `ExecutePushPipeline` skips pools with zero scheduled entries on this sender, matching `CountPoolReshardSendSlots`. | Discharged: `Coverage.senderStreams_pos_iff`, `Send.validPools`. |
| Send A2 — `Start` runs before external `Finish` | `PoolReshardPush` seats the session in `sessions_` (`SessionRole::kPoolReshardSend`) and immediately calls `Start()`, which takes its caller op (`++in_flight_`) under `mu_` before spawning the `ExecutePushPipeline` thread; a `Start()` that finds `done_ \|\| finalizing_` returns the session's status without an op, and a precondition or thread-start failure settles through `RecordPushCompletion(status)` and the `absl::Cleanup end_op` (`ReshardSendSessionTest.StartFailsFastWithoutTransportServer`). | C++ init discipline (`KVCacheManagerWithTransfer::PoolReshardPush`). |
| Send A4 — per-transfer connection-release window in `EndOp` | Under `DataConnectionReuse::kPerTransfer`, the last op (`in_flight_ == 1 && finalizing_`) drops `mu_` in `EndOp` to call `ReleaseDataConnectionsAfterSend` before `--in_flight_` and `SettleLocked()`; nothing modelled changes in the window. | Soundness argument in `Send.lean`. |
| SubPlanChain A1–A2 — valid `sub_plan_index` and fresh per-sub-plan UUIDs | `RunSubPlan` stamps `0 <= sub_plan_index < max(1, sub_plan_count)` (`BuildStartTransferForTarget`), `SubPlanUuid` derives distinct positive UUIDs per index, and retries use a fresh request UUID. | Discharged for `SubPlanUuid` (`subPlanUuid_zero`, `subPlanUuid_pos_of_pos`, `trace_sub_plan_uuid_positive_and_distinct`); duplicate-UUID admission is `Reshard/PoolStaging.lean`. |
| SubPlanChain A5–A7 — `!IsDraining()` deadline arm before the sweep, no draining-OK sibling across tombstone erase, and no mid-poll `EndOp` between retire and sweep (A5a/A5b/A5c); no single-plan registration while a sub-plan of `req_id` is seated (A6); one session per `sub_plan_index >= 1` slot (A7) | Within `CompleteReadWithDetails`, the `!session->IsDraining()` deadline arm runs before `SweepSubPlanChainsLocked` (A5a), whereas `SweepSubPlanChainsLocked` erases `failed \|\| completed` tombstones without checking `!sub_session->Done()` (A5b: no `IsDraining() && !Done()` OK sibling at tombstone erase) and `CompleteReadWithDetails` acquires `session->mu_` separately in `RetireSettledSessionLocked` and `SweepSubPlanChainsLocked` (A5c: no `EndOp` settling `done_ = true` in between); A6 and A7 are caller/environment conditions not enforced by `NoteSubPlanRegisteredLocked` (`sub_plan_count <= 1` erases `sub_plan_chains_[req_id]`, and `sub_sessions[sub_plan_index]` overwrites unconditionally). | Encoded as `WorkerState.Guards{deadlineArm, noDrainingOkAtSweep, noSettleBetweenRetireAndSweep, noSingleWhileSeated, oneSessionPerSlot}` in `stepG`; what breaks without each is shown by `mutant_no_deadline_arm_reports_done_after_sweep`, `mutant_draining_ok_at_sweep_reports_done_after_failure`, `mutant_mid_poll_endop_unanchored_reports_done_after_stall` (both A5b and A5c are discharged in `WorkerState.stepSweepWaitsForOpen`, `reachable_sweepWaitsForOpen_safe`), `mutant_single_plan_registration_erases_live_chain`, and `mutant_slot_overwrite_reports_stray_done`. |
| SubPlanChain A3–A4, A8 — sender `Complete` after last window, producer `Register` before `Coordinate`, and single-window exclusive destination staging capacity | A producer calls `RequestBlockRegistry::Complete` for a rank only after its worker emits `done_sending` (once all `count` sub-plans settle), and registers blocks before `StartPoolReshard`; `CoordChainState`'s `armDstResult` assumes each destination's `PoolStagingStorage` holds one window at a time dedicated to this chain (`busy` iff `prevSessionActive`, A8). | Discharged for `done_sending` (`SubPlanChain.reachable_worker_safe` / `DoneAfterAllSubPlans`) and post-claim `Register` refusal (`Reshard/Registry.lean`); single-window pre-claim arrival is `Reshard/Coordinator.lean`; A8 scopes bounded single-window staging capacity for `OneWindowStagedPerDestination`. |
| Caller B1–B3 — multi-worker `KVOutputAggregator` threshold (`expectedP = 2`, `expectedD = 2`) with one settled outcome per worker (`ENABLE_MULTI_NUMA=0`), whole-transfer failure, no preemption/prefix caching | `Transfer/Caller.lean` §Assumptions. | B1's `KVOutputAggregator` combining step is modelled directly in `Caller/MultiWorker.lean` (`mw_contract_safe`, `applyRecv_eager_eq_latched`, `applyRecv_staggered_eq_batch`, `mw_earlyLoadError_fail_holds_blocks`; enforced across TP ranks by `_sync_stage3_tp_submit_states`), while per-worker folding of `sub_plan_count > 1` chains into a single worker outcome is modelled in `Reshard/SubPlanChain.lean` (`WorkerState`); B2 matches single-outcome `CompleteReadWithDetails` publication; B3 does not change which event frees a transfer-held block. |

## Shipping C++ vs. modelled alternatives

Two modules parameterize `step` by a **shipping C++ guard** and the same
`step` **without it**, so the guard's role is shown by what breaks
(`PushEndPolicy`, `RegistrationPolicy`). Every other module has one shipping
`step`; where a trace shows what the code leaves behind, the module also
carries the `step` change that would close it — `Coordinator.stepDisarmAndAbandon` (disarm and
`AbandonClaim` on both aborts; `NoOrphansWhenAborted` on the 2×2 instance),
`SubPlanChain.WorkerState.stepSweepWaitsForOpen` (hold `failed || completed`
tombstones in `SweepSubPlanChainsLocked` while `sessions_` still holds any
unretired pool-reshard session of `req_id` and check `failed || completed`
before `!anchored` in `RecordPoolReshardTerminalLocked`, proved inductively by
`SubPlanChain.reachable_sweepWaitsForOpen_safe` without A5b or A5c), and
the `if (index == 0)` mutant `SubPlanChain.stepAbandonAtEveryIndex` (which shows
why the coordinator does *not* abandon at every index). These alternatives are
not the shipping code.

| Module | Parameter | Shipping C++ behavior | Modelled alternative |
|---|---|---|---|

| `Reshard/Receive.lean` | `PushEndPolicy` | **`PushEndPolicy.finishOnError`**: `EndIncomingPush` (`bts.cc`) calls `session->Finish(status)` before `EndOp()` when `!status.ok()`, for every session kind, so a failed push drains and releases staging at once (`trace_failed_incoming_push`; `PoolReshardRecvTest.FailedIncomingPushReleasesStagingLeaseBeforeDeadline` drives `GetSession` / `TryBeginOp` / `Finish` / `EndOp` directly). | **`PushEndPolicy.endOpOnly`** (mutant): calls `EndOp()` without checking `status.ok()`, so after a mid-transfer push failure the receiver stays `!IsDraining() && !Done()`, pinning its `PoolStagingLease` and plan until `timeout_s_` (`trace_failed_incoming_push`). `Recv.reachable_safe` holds under both. |
| `Reshard/PoolStaging.lean` | `RegistrationPolicy` | **`RegistrationPolicy.reserveBeforeLease`**: `PoolReshardRegisterRecv` claims `uuid` (`pending_pool_reshard_recvs_.insert`, refused while `sessions_` holds a live session or the set already holds the uuid) before `CreateReshardReceiveSession` constructs the session and acquires `PoolStagingStorage` leases. Proves inductively (`reachable_reserveBeforeLease_safe`) that every active session retains its allocated staging slots (`ActiveSessionsHoldLeases`). | **`RegistrationPolicy.leaseBeforeReserve`** (mutant): acquires `st.leases[uuid]` before the claim. A rejected duplicate-UUID call destroys its temporary session, whose destructor calls `ReleasePoolStagingLeases(uuid)` and frees the surviving session's physical staging slots (`trace_duplicate_uuid_frees_survivor_lease_and_aliases_slot`). |

## Counterfactual mutants

Each mutant removes a specific C++ guard or ordering constraint and is refuted
by an executable counterexample trace or `#guard` check in
`TpuSyncVerify/Transfer/Reshard/`:

| Mutant | C++ guard / invariant removed | Property violated |
|---|---|---|
| `Recv.onPoolReceivedIgnoringRank` | `ReshardReceiveSession::CollectEligiblePoolH2dsLocked` checks that all pools with strictly lower `rank` are `completed` before queuing a pool for H2D | `RankWaveOrder` (higher-rank pool launches H2D before lower-rank pool finishes) |
| `Recv.h2dIssueLeak` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` calls `EndRecvOpLocked()` on each remaining queued pool when exiting early on `draining_` | `NoOpLeak` (`in_flight_` stays positive after cancellation; session never settles) |
| `Send.initOvercountedSlots` | `CountPoolReshardSendSlots` (`CreateReshardSendSession`) deduplicates `(pool, peer)` slots instead of summing raw schedule entries | `NoOpLeak` / `Publication` (`remaining_pool_peer_pushes_` never reaches 0; session hangs with `done = false`) |
| `Send.stepCancelRecordsStatusFirst` (`trace_finish_after_last_push_mutant`) | `ReshardSendSession::Finish` checks `if (done_ \|\| finalizing_) return;` before recording `status_` | `published = some true` on a send whose last push completed OK before a racing `Finish(Cancelled)` (`Send.trace_finish_after_last_push`, model-only; not a `Safe` violation) |
| `Send.startFailWithoutRecord` | `ReshardSendSession::Start` calls `RecordPushCompletion(status)` before ending its caller op on a precondition or thread-start failure | `ActiveOrDraining` (`in_flight_ == 0` with `finalizing_ == false`; the send would wait for the deadline sweep) |
| `Send.d2hDoneLeakOnDraining` | `ReshardSendSession::ExecutePushPipeline`'s `pool_future.OnReady` cleanup calls `EndOp()` when `StartPoolPush` returns early on `done_ \|\| finalizing_` | `NoOpLeak` (leaked pool op keeps `in_flight_ > 0` forever on cancellation) |
| `Pipeline.mutant_ignoring_rank_corrupts_aliased_page` | Rank-ordered H2D wave gate on shared device pages (`ReshardReceiveSession::CollectEligiblePoolH2dsLocked`) | `AliasedPageCorrect` / `PublicationCorrect` (out-of-order arrival writes rank 1 first, then rank 0's `writePoolHbm` clobbers rank 1 to `.junk`, yielding `dstHbm = [kv 0, junk]`) |
| `Pipeline.mutant_onPoolReceived_before_all_streams` | `BlockTransportServerPushSession::CompleteIncomingPush` waits until `plan_pushes == expected_chunks` (`expected_pushes`) before delivering the pool completion (`session->OnDataReceived(pool_idx, {}, {})`) | `StreamAccountingSafe` / `PublicationCorrect` (H2D reads incomplete staging before all sender streams land) |
| `Pipeline.mutant_reclaim_before_publish_corrupts_dstHbm` | Caller/coordinator retires producer blocks only after transfer completion (`SrcHbmSafe`) | `PublicationCorrect` (reclaiming `srcHbm` before D2H copies `.junk` into `dstHbm`) |
| `Pipeline.trace_mutant_write_after_release_corrupts_all` | `ReshardSendSession::SettleLocked` releases `PoolStagingLease` only when `in_flight_ == 0` (`StagingSafe`) | `wroteReleased = false` (releasing `srcStaging` at `execFinish` while D2H is in flight causes `d2hDone` to write after release and corrupt all transfers' buffers) |
| `Coverage.mutant_gap_in_coverage_leaves_unwritten_byte` | `ValidateReceiverCoverage` rejects coverage intervals with a gap (`start_bytes != covered_until` / `covered_until != view.extents[ordinal]`) | Sub-block reconstruction (`byteStaging` retains `.blank` bytes after all streams land) |
| `Coverage.mutant_overlap_in_coverage_rejected` | `ValidateReceiverCoverage` rejects overlapping sub-block intervals (`start_bytes != covered_until` when `start_bytes < covered_until`) | Disjoint interval partition (`validBlockCoverage = false`) |
| `Coverage.mutant_mismatched_expected_pushes_rejected` | `ValidateReceiverCoverage` rejects plans where `expected_pushes` disagrees with $\sum_s \min(\text{parallelism}, |\text{pairs}_s|)$ | `stream_count_matches` (`validateExpectedPushes = false`) |
| `PoolStaging.mutant_non_idempotent_acquire_exhausts_shared_storage` | `KVCacheManagerBase::AcquirePoolStagingLease` skips block IDs already leased by the same `uuid` | Shared-storage lease admission (second pool sharing `storage_index` re-allocates slots and exhausts bounded capacity) |
| `PoolStaging.mutant_leaking_release_breaks_conservation_and_starves` | `KVCacheManagerBase::ReleasePoolStagingLeases` returns all leased slots to `free_slots` when erasing `leases[uuid]` | Slot conservation (`totalSlots = numSlots`; subsequent transfer starves) |
| `Registry.mutant_premature_complete_retires_while_peer_active` | `RequestBlockRegistry::Complete` checks `all_voted` (`completion.units.count(expected_unit)` across `claimed_units_`) before calling `RetireLocked` | Multi-sender claim safety (first sender's `Complete` retires blocks while second sender is still reading) |
| `Registry.mutant_unconditional_abandon_exposes_sibling_owner_to_cancel` | `RequestBlockRegistry::AbandonClaim` retains `claimed_` until `claimed_owners_` is empty | Pipelined multi-owner claim safety (stage 1's `AbandonClaim` exposes stage 2's claimed blocks to `CancelIfUnclaimed`) |
| `Registry.trace_single_stage_votes_retire_multi_owner_claim` | `RequestBlockRegistry::Complete` tracks `completed_units_` per `(req_id, uuid)` rather than per `(req_id, uuid, claim_owner)` | Multi-owner claim isolation (stage 1's senders voting `Complete` retire the generation while stage 2's claim is still active) |
| `Registry.mutant_split_ttl_purges_request_blocks_while_claim_active` | `RequestBlockRegistry::LookupAndClaim` refreshes `registration.expires_at = now + ttl_s_` on every claimed `request_blocks_` row alongside `claimed_[lifecycle_key]` | Claimed registration liveness (`ClaimOwnersConsistent`: omitting the row TTL refresh lets `PurgeExpiredRequestBlocksLocked` erase `request_blocks_` in `[t_0 + ttl_s_, t_1 + ttl_s_)` while `claimed_` is still active) |
| `Coordinator.mutant_dispatch_without_arm_barrier_drops_push` | `ReshardCoordinator::RunSubPlan` joins all Stage 1 receiver-arming threads and verifies every `armed[i]` before launching Stage 2 senders | Two-phase Arm-then-Dispatch (`NoPushBeforeAllArmed`: premature sender push arrives at unarmed `dst_unit 11` and is dropped) |
| `SubPlanChain.stepCountStale` (`mutant_counting_stale_sub_plan_reports_done_early`) | `KVCacheManagerWithTransfer::RecordPoolReshardTerminalLocked` ignores a settled session absent from the anchored chain's `sub_sessions` | `DoneAfterAllSubPlans` (a stale sub-plan from a superseded chain counts toward a retry's `settled` set and emits `done_recving` / `done_sending` while the retry's own sub-plan is still active) |
| `SubPlanChain.stepNoReanchor` (`mutant_no_reanchor_never_reports_retry_done`) | `KVCacheManagerWithTransfer::NoteSubPlanRegisteredLocked` replaces the chain entry on `sub_plan_index == 0` | Retry liveness under same `req_id` (a retry's sub-plans land in the earlier failed entry and never emit `done`) |
| `SubPlanChain.mutant_no_deadline_arm_reports_done_after_sweep` | `CompleteReadWithDetails` deadline-finishes non-draining open sessions (`if (!session->IsDraining())` + `session->deadline() <= now`) before `SweepSubPlanChainsLocked` runs (SubPlanChain A5a) | `DoneAfterAllSubPlans` (after `erasedReported` sweeps a `failed` tombstone, an un-failed sibling settles OK into `entry == none` and emits `done`) |
| `SubPlanChain.mutant_draining_ok_at_sweep_reports_done_after_failure` | No sibling sub-plan is in `IsDraining() && !Done()` with `OkStatus()` when `SweepSubPlanChainsLocked` erases a `failed \|\| completed` tombstone (SubPlanChain A5b; unguarded in shipping C++, closed by `WorkerState.stepSweepWaitsForOpen`) | `DoneAfterAllSubPlans` (on a single non-retried failed chain, an `IsDraining() && !Done()` OK sibling is skipped by `!IsDraining()`, survives tombstone erasure, and emits `done_sending_` / `done_recving_` after `failed_recving_`) |
| `SubPlanChain.mutant_mid_poll_endop_unanchored_reports_done_after_stall` | `session->Done()` does not flip via `EndOp` in the `session->mu_` gap between `RetireSettledSessionLocked` and `SweepSubPlanChainsLocked` (SubPlanChain A5c; unguarded in shipping C++, closed by `WorkerState.stepSweepWaitsForOpen`) | `DoneAfterAllSubPlans` (on an unanchored `sub_plan_index >= 1` chain, mid-poll `EndOp` makes `SweepSubPlanChainsLocked` mark the chain stalled and clear `sub_sessions`, and the next poll hits `!anchored` ahead of `failed` in `RecordPoolReshardTerminalLocked` to emit `done` after `failed_recving_`) |
| `SubPlanChain.mutant_single_plan_registration_erases_live_chain` | Caller/stage condition keeping `sub_plan_count <= 1` registrations from arriving under a `req_id` while a chained sub-plan is still seated (SubPlanChain A6; `NoteSubPlanRegisteredLocked` erases the entry unconditionally) | `DoneAfterAllSubPlans` (the orphaned sub-plan's terminal is reported directly as the request's) |
| `SubPlanChain.mutant_slot_overwrite_reports_stray_done` | Caller condition keeping at most one session per `sub_sessions[sub_plan_index]` slot per unanchored chain (SubPlanChain A7; `NoteSubPlanRegisteredLocked` overwrites unconditionally) | `DoneAfterAllSubPlans` (the overwritten session's terminal hits the `!anchored` stray arm and emits premature `done`) |
| `SubPlanChain.stepAbandonAtEveryIndex` (`mutant_abandon_at_every_index_exposes_active_sender`) | `ReshardCoordinator::RunSubPlan` guards `registry_->AbandonClaim(...)` with `if (index == 0)` on arm / plan aborts | `NoSenderExposed` (`AbandonClaim` on a window `>= 1` failure drops the registry claim while window `0`'s dispatched sender is still reading source HBM, letting `CancelIfUnclaimed` tombstone the generation mid-transfer) |

## Branch coverage by the replayed tests

How much of each model's `step` the upstream tests exercise
([conventions.md](../conventions.md) §Coverage; one `#guard` per model pins
the numbers). The denominator is the exhaustive reachable branch set of the
small instances; the numerator is the branches along traces paired with an
upstream test that drives the C++ through events of the model. Classes:
**test** (the CPU fakes the session tests already seat — `FakeD2hBase`'s
promise-backed `D2hPoolBlocks` in `reshard_send_test.cc`, `FakeH2dBase`'s
`H2dPoolBlocks` in `pool_reshard_test.cc` / `reshard_recv_test.cc`, the
manager hooks and `TestManager::FinishPoolReshardRecvPool` — can drive it
without production changes), **test (copy error)** (`Send`: needs
`FakeD2hBase` to resolve a held D2H promise with an error), **test (held
upload)** (`Receive`: needs `FakeH2dBase` to hold an upload pending across
`Finish`), **window** (an interleaving no harness hook reaches on the 1–2 pool
instances).

| Model | Instances | Branches | Reached by paired tests | Gaps | Of which |
|---|---|---|---|---|---|
| `Receive` | 1 pool; 2 pools of one rank; ranks `[0, 1]` | 36 (+2 unreachable leaves: `FinishPoolH2d`'s `if (done_) return;`, a failed issue on a finalizing session) | 13 (`FailedIncomingPushReleasesStagingLeaseBeforeDeadline`, `ConcurrentDuplicatePoolRecvRegistrationKeepsWinnerStagingLease`, `ReshardReceiveSessionTest.BoundedStagingSlotAcquisitionAndRelease`, `OutOfOrderPoolArrivalResolvesLeasedHostBufferForValidation` and `FullHostMirrorAddressesPoolsInPlace`, the push-framed `ReshardSendSessionTest.PoolOrderInvertedFromStorageOrderPassesTransportValidateChunks`, `FinishPoolReshardRecvRecordsDurationMetric` / `DoesNotRecordMetricOnFailure` (a real failing `h2dDone`), `SinglePlanRequestsReportAtOnce`, `GetSessionResolvesActiveReshardRecvUntilRetired` and the four receive `SubPlanChainTest` cases per sub-plan) | 23 | 14 test, 7 test (held upload), 2 window |
| `Send` | 1 pool with 1 or 2 peers; 2 pools | 26 (every leaf live) | 10 (9 `ReshardSendSessionTest` cases, all from `init` through `Start`: the `PerTransferPolicy*` / `PooledPolicy*` connection tests, `BoundedStagingSlotAcquisitionAndRelease` (both sessions), `StartFailsFastWithoutTransportServer`, `PipelineSlotWaitTimeoutSettlesSendOutOfBand`, `StagingSlotReleasedAfterLastPeerPush`, `PoolOrderInvertedFromStorageOrderPassesTransportValidateChunks`, `FullHostMirrorStagesPoolsInPlace`) | 16 | 11 test, 5 test (copy error) |
| `Pipeline` | 1 pool, armed and unarmed (one paired two-pool trace reaches 2 branches outside it) | 60; every memory move writes the right pool's KV and no H2D clobbers KV in a higher-rank slot | 12 (`ReshardSendSessionTest.PoolOrderInvertedFromStorageOrderPassesTransportValidateChunks`) | 48 | 3 environment, 1 coordinator, 8 covered by session tests (3 `Send`, 5 `Receive`), 36 in the session gap tables (18 `Send`, 18 `Receive`), none unaccounted |
| `Registry` | one `(req_id, uuid)` generation over two units and two owners | 25 (every leaf live); effect is the `Status` before and after and whether `RetireLocked` fired | 25 (44 tests, 50 traces; all 7 `Refusal` constructors asserted — `ReshardStackTest.DuplicateRegistrationRefreshesTtlWhileConflictsAndPostClaimWritesFail`, `CompletionNoOpsAndPreClaimGuard`, `EmptyRegistrationCompletesBeforeClaimAndRetiresOnClaim`, `ForcedReleaseClearsEveryLifecycleState`, `ClaimRefreshesRegistrationTtlForSiblingStageAndCompletion` and `FailedClaimDoesNotRefreshPartialRegistrationTtl` drive the re-registration, `Complete` no-ops, the pre-claim vote, the repeated cancel, `Release`, and claim TTL refresh) | 0 | — (the `force = false` release is refused in `ReshardService::HandleControllerCommand` before the registry) |
| `Coordinator` | 1×1, 1×2, 2×1 and 2×2 sub-plans | 14 (every leaf live); effect is the phase before and after and what an abort leaves armed or claimed | 14 (26 tests, 30 traces; `ReshardStackTest.TwoDestinationsOneArmRefusalAbandonsClaimAndSkipsSenders` drives the refused arm beside an armed destination and `SenderDispatchFailurePropagatesErrorAfterReceiverArm` the failed sender dispatch) | 0 | — (`dispatchFailureTrace` stays model-only) |
| `SubPlanChain` | worker: a two-window request and a retry; coordinator: two ranks over `[[0], [1]]` and `[[0, 1], [1]]` with one destination | 27 arms (worker) and 22 leaves (coordinator), every constructor live; counted per arm because a poll visits several and the environment events are enabled in every phase | 16 (6 `SubPlanChainTest` cases) and 14 (6 windowed `ReshardStackTest` cases) | 11 and 8 | worker: a sub-plan seated before sub-plan 0 (`register unanchored`), a draining session flipped to error or an idle session finished with error (`settle endOpLateErr` / `idleFailed`), the three `CompleteReadWithDetails` deadline-arm cases (`deadline skipDraining` / `drainInFlight` / `settleIdle`), a failing single-plan session (`record directFailed`), a stray terminal under an unanchored entry (`record strayDone` / `strayFailed`), a sweep with an in-flight session still active (`sweep activeKeeps`) and the erasure of a reported entry (`sweep erasedReported`); coordinator: 2 test at window `>= 1` (planner or claim refusal), 2 at a failed sender dispatch after window 0 (`sendFail`, `sendBarrierAbort`), 1 covered by the single-window cases in `Coordinator/Coverage.lean` (window-0 arm failure), 3 registry environment (`voteKeepsClaim`, `voteRetires`, `cancelTombstones`, covered in `Registry/Coverage.lean`) |

What the tests miss: on the receiver, the CPU fakes land one pool at a time
through `OnDataReceived` and complete its upload at once, so no test lands
pools of two ranks out of order (the rank-wave gate holding a higher-rank pool
back), launches a batch of several eligible pools, or holds an upload pending
across `Finish` (`FakeH2dBase` answers a ready future; the `held upload` rows
need it to keep a promise); the push-framed arrival is driven only by
`PoolOrderInvertedFromStorageOrderPassesTransportValidateChunks`. On the
sender, `FakeD2hBase` can hold a D2H copy (`HoldNextCopy`) and complete it
(`CompleteCopy`) but never fails one, and no test fails a push from its
transport callback: the `!status.ok()` arm of `RecordPushCompletion` is reached
through `Start`'s precondition failure in `StartFailsFastWithoutTransportServer`
and the staging-slot timeout in `PipelineSlotWaitTimeoutSettlesSendOutOfBand`
(the `copy error` rows). `KVCacheManagerBase::CopyPoolBlocks` itself runs in
no CPU test (every fake overrides the `D2hPoolBlocks` / `H2dPoolBlocks` seam
above it). On the single-window control plane, `ReshardStackTest` covers every
`Registry` and `Coordinator` branch; on multi-window chains, no test injects a
planner/claim refusal or a sender-dispatch failure at window `>= 1`.

## C++ branch coverage of the anchored spans

`tools/resolve_anchors.py --coverage` intersects `llvm-cov` branch records from
every OSS-buildable CPU unit-test binary with the `Reshard/` source-map spans
([conventions.md](../conventions.md) §Coverage), using virtual `D2hPoolBlocks`
/ `H2dPoolBlocks` test seams (`FakeD2hBase` in `reshard_send_test.cc`,
promise-backed so a copy can stay pending across `Finish` or fill the staged
bytes; `FakeH2dBase` in `pool_reshard_test.cc` and `reshard_recv_test.cc`,
armed with a status per pool or recording the leased host slot) where CPU tests
have no PJRT device buffer:

* **Exercised on CPU in the current suite:** static plan and sub-block coverage
  validation (`ReshardReceiveSession::ValidatePlan`,
  `ValidateReceiverCoverage`, `ReshardSendSession::ValidatePlan`,
  `CountPoolReshardSendSlots`), `PoolStagingStorage` leases
  (`AcquirePoolStagingLease`, `ReleasePoolStagingLeases`), receiver arming
  (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv`),
  `RequestBlockRegistry`, `ReshardCoordinator::RunSubPlan` over
  `WorkerDelivery::Mode::kFramed`, `ReshardSendSession::ExecutePushPipeline`
  through its D2H dispatch, `StartPoolPush` from the D2H callback, and real
  peer pushes (`ReshardSendSessionTest.BoundedStagingSlotAcquisitionAndRelease`,
  `StagingSlotReleasedAfterLastPeerPush`, the `PerTransferPolicy*` /
  `PooledPolicy*` connection tests, and
  `PoolOrderInvertedFromStorageOrderPassesTransportValidateChunks`, which runs a
  send and a receive end to end on CPU and checks the bytes each pool's H2D
  read); and on the receiver, `OnPoolReceived`, `RecordPoolReceivedLocked`,
  `CollectEligiblePoolH2dsLocked`, `ExecuteEligiblePoolH2ds` and `FinishPoolH2d`,
  reached through the session's public interface
  (`TestManager::FinishPoolReshardRecvPool`: `ResolveStagingSlot` then
  `OnDataReceived(pool_idx, {}, {})`, with
  `PoolReshardRecvTest.FinishPoolReshardRecvDoesNotRecordMetricOnFailure`
  arming the upload to fail from its callback) and from a real push in the end
  to end test above.
* **Still outside the CPU suite:** `KVCacheManagerBase::CopyPoolBlocks`
  (`D2hPoolBlocks` / `H2dPoolBlocks` on a real `RaidenBufferHandle`; every CPU
  test overrides the seam above it or, in `DeviceBackedTestBase`, leaves the
  handle default-constructed with `c_hold == nullptr`), the
  `WorkerDelivery::Mode::kController` arm of `ReshardCoordinator::RunSubPlan`,
  a reshard send that the `sessions_` sweep in
  `KVCacheManagerWithTransfer::CompleteReadWithDetails` deadline-finishes (its
  one deadline arm is driven only by a `TransferSendSession`,
  `SendDeadlineTest.ExpiredSendSessionFailsInsteadOfReportingDone`), a push
  that fails from its transport callback (`RecordPushCompletion`'s
  `!status.ok()` arm is reached from `Start`'s precondition failure in
  `StartFailsFastWithoutTransportServer`, from the staging-slot wait timeout in
  `PipelineSlotWaitTimeoutSettlesSendOutOfBand`, never from a D2H or push
  callback), and the rank-wave gate with a
  higher-`order_rank` pool landing while a lower one is still pending (no test
  lands pools of two ranks; `GroupScopesDestinationBlocks` only validates a
  rank-1 group).

Until the CPU suite lands pools of several ranks out of order and fails a push
from its callback, the Lean models in
`Reshard/{Send,Receive,Pipeline,Coordinator,SubPlanChain}.lean` are the only
check on those paths without TPU hardware.

## C++ → Lean routing index

Per C++ symbol: the Lean module that owns it, the model events or definitions
it becomes, and the theorems to open first. The `Lines` column is generated by
`tools/resolve_anchors.py`.

### Receive session (`reshard_recv.{h,cc}`)

<!-- source-map:begin -->
| File | Symbol / anchor | Lines | Lean module | Model events / definitions | Key theorems / mutants |
|---|---|---|---|---|---|
| `tpu_sync/transport/transfer_session.h` | `TransferSession` | `:36-115` | `Transfer/Session.lean` | the interface both reshard sessions implement: `Start`, `Done`, `Finish`, `TryBeginOp` / `EndOp`, `IsDraining`, `ResolveStagingSlot`, `OnDataReceived`, `GetDataReadyFuture`, `plan()`, `deadline()` (the one timeout the manager's sweep reads for every session kind) | `Lifecycle.Consistent` |
| `reshard_recv.cc` | `ReshardReceiveSession` | `:67-242` | `Transfer/Session.lean`, `Reshard/Receive.lean` | the class (private to `reshard_recv.cc`, built only by `CreateReshardReceiveSession`): `in_flight_`, `draining_`, `done_`, `staging_released_`, `pool_order_ranks_`, `transfer_plan_` (`plan()` is `nullopt` once `Done()`), `deadline()`, `TryBeginOp` (`false` when draining or done), `OnDataReceived` (a pool completion → `OnPoolReceived`; a block report is a no-op); `~ReshardReceiveSession` calls `ReleaseStaging()` | `Recv.reachable_safe` |
| `reshard_recv.cc` | `ReshardReceiveSession::ValidatePlan` | `:256-333` | `Reshard/Receive.lean` | `Recv.validPlan`, `Recv.validPlanPoolsAndBlocks` | `Recv.trace_reshard_receive_session_test_parity` |
| `reshard_recv.cc` | `ReshardReceiveSession::ValidateReceiverCoverage` | `:335-538` | `Reshard/Coverage.lean` | `Coverage.validBlockCoverage`, `Coverage.validateExpectedPushes` | `Coverage.partition_reconstructs_perm`, `Coverage.stream_count_matches` |
| `reshard_recv.cc` | `CreateReshardReceiveSession` | `:540-574` | `Reshard/Receive.lean`, `Reshard/PoolStaging.lean` | the factory (`reshard_recv.h`) returning a `std::shared_ptr<TransferSession>`: `ValidatePlan`, the `has_device_buffers()` and `MEMORY_TYPE_HBM` gates, `TransferPlan::Create`, then `AcquireStagingLeases` (rolled back by `ReleaseStaging` on failure); runs under the `pending_pool_reshard_recvs_` claim of `PoolReshardRegisterRecv` (`PoolStaging.RegistrationPolicy.reserveBeforeLease`) | `PoolStaging.reachable_reserveBeforeLease_safe` |
| `reshard_recv.cc` | `ReshardReceiveSession::AcquireStagingLeases` | `:603-642` | `Reshard/Receive.lean`, `Reshard/PoolStaging.lean` | Per-storage bounded lease acquisition (`AcquirePoolStagingLease`) | `PoolStaging.acquireLease_idempotent` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishLocked` | `:656-668` | `Transfer/Session.lean`, `Reshard/Receive.lean` | `Lifecycle.finishLocked`, `Recv.Ev.cancel` | `Recv.SettleSafe` |
| `reshard_recv.cc` | `ReshardReceiveSession::EndRecvOpLocked` | `:734-744` | `Transfer/Session.lean`, `Reshard/Receive.lean` | `Lifecycle.endOpLocked` | `Recv.StagingIntegrity` |
| `reshard_recv.cc` | `ReshardReceiveSession::EndOp` | `:746-749` | `Transfer/Session.lean`, `Reshard/Receive.lean` | `Recv.Ev.pushEnd` (`EndIncomingPush` in `bts.cc`: `Finish(status)` on error, then `EndOp`) | `Recv.SettleSafe`, `Recv.trace_failed_incoming_push` |
| `reshard_recv.cc` | `ReshardReceiveSession::RecordPoolReceivedLocked` | `:751-762` | `Reshard/Receive.lean` | Rejects undeclared or duplicate pool indices (`Receive` A1) | `Recv.reachable_safe` |
| `reshard_recv.cc` | `ReshardReceiveSession::CollectEligiblePoolH2dsLocked` | `:764-793` | `Reshard/Receive.lean`, `Reshard/Pipeline.lean` | Rank gate + batch `in_flight_ += to_launch.size()` | `Recv.RankWaveOrder` (`rankWaveOrder_iff`), `Pipeline.AliasedPageCorrect`, mutants `Recv.onPoolReceivedIgnoringRank`, `Pipeline.mutant_ignoring_rank_corrupts_aliased_page` |
| `reshard_recv.cc` | `ReshardReceiveSession::OnPoolReceived` | `:810-821` | `Reshard/Receive.lean` | `Recv.Ev.onPoolReceived` (the pool completion of `OnDataReceived`, which `CompleteIncomingPush` calls on the session `BeginIncomingPush` returned; a settled session answers `NotFound`) | `Recv.RankWaveOrder` |
| `reshard_recv.cc` | `ReshardReceiveSession::ExecuteEligiblePoolH2ds` | `:823-887` | `Reshard/Receive.lean` | `Recv.Ev.h2dIssue` (`draining_` early exit calls `EndRecvOpLocked()`) | `Recv.NoOpLeak`, mutant `Recv.h2dIssueLeak` |
| `reshard_recv.cc` | `ReshardReceiveSession::FinishPoolH2d` | `:889-925` | `Reshard/Receive.lean` | `Recv.Ev.h2dReady`, `Recv.Ev.h2dDone` (the last pool's completion calls `Finish`) | `Recv.reachable_safe` (`Publication`), `Recv.reachable_can_settle` |
<!-- source-map:end -->

### Send session (`reshard_send.{h,cc}`, `slots.cc`)

<!-- source-map:begin -->
| File | Symbol / anchor | Lines | Lean module | Model events / definitions | Key theorems / mutants |
|---|---|---|---|---|---|
| `reshard_send.cc` | `ReshardSendSession` | `:70-228` | `Transfer/Session.lean`, `Reshard/Send.lean` | the class (private to `reshard_send.cc`, built only by `CreateReshardSendSession`): `remaining_pool_peer_pushes_`, `finalizing_`, `in_flight_`, `done_`, `transfer_plan_` (`plan()` is `nullopt` once `Done()`), `deadline()`, `TryBeginOp() { return false; }` | `Send.reachable_safe` |
| `slots.cc` | `CountPoolReshardSendSlots` | `:27-51` | `Reshard/Send.lean`, `Reshard/Coverage.lean` | Deduplicated `(pool, peer)` slot count (`Coverage.countPoolReshardSendSlots`) | `Send.ActiveOrDraining`, `Coverage.trace_pool_reshard_send_slots_test_parity`, mutant `Send.initOvercountedSlots` |
| `reshard_send.cc` | `CreateReshardSendSession` | `:272-334` | `Reshard/Send.lean` | the factory (`reshard_send.h`) returning a `std::shared_ptr<TransferSession>`: `ReshardSendSession::ValidatePlan`, the `has_device_buffers()` gate, `CountPoolReshardSendSlots` (rejects `remaining_pool_peer_pushes <= 0`), `InitTransportServer`, and the session's `TransferPlan` | `Send.reachable_safe` |
| `reshard_send.cc` | `ReshardSendSession::Start` | `:430-467` | `Reshard/Send.lean` | the caller op (`++in_flight_` unless `done_ \|\| finalizing_`), `ValidatePushPreconditions`, the `ExecutePushPipeline` thread (ended by `EndOp`), and the synchronous failure path (`RecordPushCompletion(status)` + `end_op`: `Send.Ev.startFail`) | `Send.ActiveOrDraining`, `Send.trace_start_fails_fast`, mutant `Send.startFailWithoutRecord` |
| `reshard_send.cc` | `ReshardSendSession::ExecutePushPipeline` | `:469-583` | `Reshard/Send.lean` | `Send.Ev.d2hIssue` per pool (after `AcquireStagingSlot` and the arena lease), `Send.Ev.execFinish` | `Send.ActiveOrDraining` |
| `reshard_send.cc` | `ReshardSendSession::StartPoolPush` | `:585-688` | `Reshard/Send.lean` | `Send.Ev.d2hDone` | `Send.NoOpLeak`, mutant `Send.d2hDoneLeakOnDraining` |
| `reshard_send.cc` | `ReshardSendSession::RecordPushCompletion` | `:690-709` | `Reshard/Send.lean` | `Send.Ev.pushDone`, `Send.recordPushCompletion` (latches `finalizing_` and `staging_layer_manager_.Shutdown()` on the first error or the last scheduled push) | `Send.Publication`, `Send.ActiveOrDraining` |
| `reshard_send.cc` | `ReshardSendSession::Finish` | `:711-729` | `Reshard/Send.lean` | `Send.Ev.cancel` (`if (done_ \|\| finalizing_) return;` before the status record) | `Send.SettlesPromptly`, `Send.trace_finish_after_last_push`, mutant `Send.stepCancelRecordsStatusFirst` |
| `reshard_send.cc` | `ReshardSendSession::EndOp` | `:745-773` | `Reshard/Send.lean` | Releases the per-transfer data connections when `in_flight_ == 1 && finalizing_` (Send A4), then `--in_flight_` and `SettleLocked()` on the last op | `Send.SettleSafe`, `Send.trace_cancel_settles_on_last_endOp` |
<!-- source-map:end -->

### Manager, pool staging, and copy futures (`mgr.{h,cc}`, `base.{h,cc}`, `raw_core.h`)

<!-- source-map:begin -->
| File | Symbol / anchor | Lines | Lean module | Model events / definitions | Key theorems / mutants |
|---|---|---|---|---|---|
| `mgr.h` | `KVCacheManagerWithTransfer` (`struct SubPlanChainProgress {` .. `void SweepSubPlanChainsLocked(std::chrono::steady_clock::time_point now)`) | `:381-408` | `Reshard/SubPlanChain.lean` | `SubPlanChain.ChainProgress`; one `sub_plan_chains_` map keyed by `req_id`, each entry holding the chain's `sub_sessions` (indexed by `sub_plan_index`), `completed`, `failed`, `anchored` and `last_activity` | `SubPlanChain.reachable_worker_safe` |
| `mgr.cc` | `KVCacheManagerWithTransfer::NoteSubPlanRegisteredLocked` | `:147-183` | `Reshard/SubPlanChain.lean` | `SubPlanChain.WorkerEv.registerSubPlan`, `noteSubPlanRegistered`: seats the session at `sub_sessions[sub_plan_index]` (a single-plan request erases the entry; `sub_plan_index == 0` starts a fresh anchored entry) | `SubPlanChain.reachable_worker_safe`, mutant `SubPlanChain.stepNoReanchor` |
| `mgr.cc` | `KVCacheManagerWithTransfer::RecordPoolReshardTerminalLocked` | `:185-251` | `Reshard/SubPlanChain.lean` | `SubPlanChain.WorkerEv.poll`, `recordTerminal`, `recordTerminalWaitOpen`: a settled session absent from an anchored chain's `sub_sessions` is ignored; `done` is inserted once every seated `sub_sessions` entry is `Done()` with an OK status (`completed = true`) | `SubPlanChain.reachable_worker_safe` (`DoneAfterAllSubPlans`), `SubPlanChain.reachable_sweepWaitsForOpen_safe`, `SubPlanChain.trace_first_failure_reports_while_sibling_active`, mutants `SubPlanChain.stepCountStale`, `SubPlanChain.mutant_mid_poll_endop_unanchored_reports_done_after_stall` |
| `mgr.cc` | `KVCacheManagerWithTransfer::SweepSubPlanChainsLocked` | `:253-302` | `Reshard/SubPlanChain.lean` | `SubPlanChain.WorkerEv.poll` / `pollMidSettle` (`stalled = true`), `sweepStalledChain`, `sweepStalledChainWaitOpen` (`WorkerState.stepSweepWaitsForOpen`) | `SubPlanChain.trace_sender_in_first_window_only`, `SubPlanChain.trace_late_sub_plan_after_sweep_reports_failure_twice`, `SubPlanChain.mutant_draining_ok_at_sweep_reports_done_after_failure`, `SubPlanChain.mutant_mid_poll_endop_unanchored_reports_done_after_stall`, `SubPlanChain.reachable_sweepWaitsForOpen_safe` |
| `mgr.cc` | `KVCacheManagerWithTransfer::InitializeBaseHooks` | `:304-308` | `Reshard/Receive.lean`, `Reshard/Pipeline.lean` | the one manager hook, `hooks.get_session`, through which `BeginIncomingPush` / `EndIncomingPush` (`bts.cc`) reach a reshard session (`Recv.Ev.pushBegin`, `Recv.Ev.pushEnd`, `Recv.PushEndPolicy.finishOnError` vs. `.endOpOnly`); `CompleteIncomingPush` then delivers the pool completion to the session it holds (`OnDataReceived`) | `Recv.trace_failed_incoming_push` |
| `mgr.cc` | `KVCacheManagerWithTransfer::GetSession` | `:310-317` | `Reshard/Receive.lean`, `Reshard/PoolStaging.lean` | `sessions_.find(uuid)` under `mu_` | — |
| `mgr.cc` | `KVCacheManagerWithTransfer::RetireSettledSessionLocked` | `:470-529` | `Reshard/Receive.lean`, `Reshard/Send.lean`, `Reshard/SubPlanChain.lean` | a `Done()` entry of role `SessionRole::kPoolReshardSend` / `kPoolReshardReceive` is folded through `RecordPoolReshardTerminalLocked` under its `SessionEntry::req_id` and erased from `sessions_` (`Send.Ev.publish`, `Recv.Ev.publish`); `retired_pool_staging` has the caller run `ReleasePoolStagingLeases(uuid)` outside `mu_` | `SubPlanChain.reachable_worker_safe`, `PoolStaging.RegEv.settleSession` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardPush` | `:732-774` | `Reshard/Send.lean`, `Reshard/SubPlanChain.lean` | Retires a settled incumbent, seats `CreateReshardSendSession`'s session as `SessionEntry{state, plan.req_id(), SessionRole::kPoolReshardSend}`, records sub-plan registration, and calls `Start()` (`Send` A2) | `Send.reachable_safe`, `SubPlanChain.reachable_worker_safe` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` | `:776-825` | `Reshard/Receive.lean`, `Reshard/PoolStaging.lean`, `Reshard/SubPlanChain.lean` | `PoolStaging.RegEv` (`beginArm` = the `pending_pool_reshard_recvs_` claim, `acquireArmLease` inside `CreateReshardReceiveSession`, `finishArm` = seating as `SessionEntry{recv_session, plan.req_id(), SessionRole::kPoolReshardReceive}`, `settleSession`) and `NoteSubPlanRegisteredLocked` | `PoolStaging.reachable_reserveBeforeLease_safe`, `PoolStaging.trace_duplicate_uuid_frees_survivor_lease_and_aliases_slot`, `SubPlanChain.reachable_worker_safe` |
| `mgr.cc` | `KVCacheManagerWithTransfer::UnregisterActivePlan` | `:827-873` | `Reshard/Receive.lean`, `Reshard/Send.lean` | the coordinator's disarm: `Finish(Cancelled)` on a live session (a `TransferSendSession` is erased from `sessions_` first; a `kPoolReshardSend` entry stays for the sweep); not a session event of its own | `Recv.Ev.cancel`, `Send.Ev.cancel` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` | `:1071-1134` | `Reshard/Receive.lean`, `Reshard/Send.lean`, `Reshard/Pipeline.lean`, `Reshard/MultiRequest.lean`, `Reshard/SubPlanChain.lean`, `Transfer/Caller.lean` | one sweep over `sessions_`: the one deadline arm (`session->deadline() <= now` → `Finish(DeadlineExceeded("Transfer session timed out"))` on any non-draining session), then `RetireSettledSessionLocked` and `SweepSubPlanChainsLocked`; every retired uuid that left push progress behind gets `ForgetPushProgress` and `ReleasePoolStagingLeases` outside `mu_` (`Send.Ev.publish`, `Recv.Ev.publish`, `SubPlanChain.WorkerEv.poll`, `Caller.Ev.pOutcome`, `Caller.Ev.dOutcome`) | `Pipeline.PublicationCorrect`, `Pipeline.attention_safe`, `Pipeline.system_data_correct`, `SubPlanChain.reachable_worker_safe`, `Caller.contract_safe` |
| `base.h` | `KVCacheManagerBase` | `:119-1118` | `Reshard/PoolStaging.lean` | `PoolStagingStorage` and aliased hybrid-model pool declarations | `PoolStaging.ArenaInv` |
| `base.h` | `KVCacheManagerBase::AttachPlaceholderDeviceHoldForTest` | `:762` | `Reshard/Receive.lean`, `Reshard/Send.lean` | Placeholder `buffer_holds_` entry (`holds` empty) for validation/peer tests | — |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` | `:2525-2582` | `Reshard/PoolStaging.lean` | `PoolStaging.Arena.acquireLease` | `PoolStaging.acquireLease_idempotent`, `PoolStaging.no_slot_aliasing_between_distinct_uuids`, mutant `mutant_non_idempotent_acquire_exhausts_shared_storage` |
| `base.cc` | `KVCacheManagerBase::ReleasePoolStagingLeases` | `:2584-2600` | `Reshard/PoolStaging.lean` | `PoolStaging.Arena.releaseLease` | `PoolStaging.allocateMissing_slot_sum`, mutant `mutant_leaking_release_breaks_conservation_and_starves` |
| `base.cc` | `KVCacheManagerBase::CopyPoolBlocks` | `:2907-3048` | `Reshard/Receive.lean`, `Reshard/Send.lean` | Pool-extent D2H/H2D dispatch (`D2hPoolBlocks`, `H2dPoolBlocks`) | `Recv.NoOpLeak`, `Send.NoOpLeak` |
| `reshard_recv.cc` | `ReshardReceiveSession::OnDataReceived` | `:127-134` | `Reshard/Receive.lean` | the transport's entry for a pool completion (`CompleteIncomingPush` → `session->OnDataReceived(pool_idx, {}, {})`): empty `minor_dimension_indices` → `OnPoolReceived`; a block report returns OK without effect | `Recv.RankWaveOrder` |
| `base.cc` | `KVCacheManagerBase::GetSession` | `:3071-3077` | `Reshard/Receive.lean`, `Reshard/PoolStaging.lean` | the transport delegate's session lookup (`transfer_hooks_.get_session`) | — |
| `base.cc` | `KVCacheManagerBase::ResolveBlockArrayHostLayer` | `:2134-2192` | `Reshard/Receive.lean`, `Reshard/Send.lean` | resolves `host_layer_idx` via `GetSession(uuid)` → `session->ResolveStagingSlot(block_array_idx)` for `GetBlockArrayHostSpan` | — |
| `base.cc` | `KVCacheManagerBase::GetBlockArrayHostSpan` | `:2194-2256` | `Reshard/Receive.lean`, `Reshard/Send.lean` | host buffer span lookup called per chunk by `ValidateChunks` | — |
| `base.cc` | `KVCacheManagerBase::GetBlockChunks` | `:3389-3561` | `Reshard/PoolStaging.lean`, `Reshard/Send.lean` | `PoolStaging.Arena.resolveBlockSlot` (`block_host_base`), `session->ResolveStagingSlot(layer_idx)` for the host layer buffer (the span check in `ValidateChunks` resolves the same slot through `ResolveBlockArrayHostLayer` / `GetBlockArrayHostSpan`), and sub-block staging resolution on sender | `PoolStaging.no_slot_aliasing_between_distinct_uuids`, `Send.trace_partial_failure_keeps_plan` |
| `raw_core.h` | `PjRtCopyFuture::OnReady` | `:514-568` | `Reshard/Receive.lean`, `Reshard/Send.lean` | Runs callback inline with `OkStatus()` when `!future.IsValid()` and `event_bundles.empty()` | — |
| `raw_core.h` | `IssueD2hShard` | `:657-685` | `Reshard/Send.lean` | Returns immediately-ready no-op `PjRtCopyFuture` on a null `RaidenBufferHandle` (`DeviceBackedTestBase`) | — |
| `raw_core.h` | `IssueH2dShard` | `:687-715` | `Reshard/Receive.lean` | Returns immediately-ready no-op `PjRtCopyFuture` on a null `RaidenBufferHandle` (`DeviceBackedTestBase`) | — |
| `reshard_send_test.cc` | `FakeD2hBase` | `:339-426` | `Reshard/Send.lean` | the CPU test base whose promise-backed `D2hPoolBlocks` override (`HoldNextCopy` / `CompleteCopy` / `FillOnCopy`) lets `ReshardSendSessionTest` drive `Start` → `ExecutePushPipeline` → `StartPoolPush` and real peer pushes to a `StubRecvSession` (`AcceptPushes`) or a `RecordingH2dReceiverBase` (`paired` in `Send/Coverage.lean`) | — |
| `pool_reshard_test.cc` | `TestManager::FinishPoolReshardRecvPool` | `:122-132` | `Reshard/Receive.lean` | lands one pool through the session's public interface: `FakeH2dBase::ArmPoolUpload(pool_idx, status)`, `ResolveStagingSlot(pool_idx)` (the pool's own storage on this full mirror; the helper also tolerates `kNotFound`), then `OnDataReceived(pool_idx, {}, {})` (so `OnPoolReceived`, the rank gate, `ExecuteEligiblePoolH2ds` and `FinishPoolH2d` all run on CPU) | — |
| `pool_reshard_test.cc` | `FakeH2dBase` | `:70-104` | `Reshard/Receive.lean` | the CPU test base whose `H2dPoolBlocks` override answers an armed pool with a ready future carrying the armed status (`TestManager`) | — |
| `pool_reshard_test.cc` | `DeviceBackedTestBase` | `:687-700` | `Reshard/Receive.lean`, `Reshard/Send.lean` | Populates a default-constructed `RaidenBufferHandle` (`BoundedPoolTestManager`) | — |
| `pool_reshard_test.cc` | `PoolReshardRecvTest.FailedIncomingPushReleasesStagingLeaseBeforeDeadline` | `:857-895` | `Reshard/Receive.lean` | Replayed by `trace_failed_incoming_push` (`PushEndPolicy.finishOnError`): `GetSession` → `TryBeginOp` → `Finish(DeadlineExceeded)` → `EndOp`, then `Done()`, the lease back and `HasActivePlan` false | `Recv.trace_failed_incoming_push` |
<!-- source-map:end -->

### Transport and planner (`bt.cc`, `bts.cc`, `planner.cc`)

<!-- source-map:begin -->
| File | Symbol / anchor | Lines | Lean module | Model events / definitions | Key theorems / mutants |
|---|---|---|---|---|---|
| `bt.cc` | `BlockTransport::HandleIncomingPush` | `:459-468` | `Reshard/Pipeline.lean` | delegates the stream to the uuid's `BlockTransportServerPushSession::StartStream` and drops that push session (`DeletePushSession(session)`) once `IsDone()` | `Pipeline.StagingSafe` |
| `bts.cc` | `BeginIncomingPush` | `:242-256` | `Reshard/Receive.lean`, `Reshard/Pipeline.lean` | `Recv.Ev.pushBegin`: `delegate->GetSession(uuid)` then `TryBeginOp()`; `false` is `Cancelled` | `Recv.StagingIntegrity`, `Pipeline.StagingSafe` |
| `bts.cc` | `EndIncomingPush` | `:258-271` | `Reshard/Receive.lean`, `Reshard/Pipeline.lean` | `Recv.Ev.pushEnd`: `Finish(status)` when `!status.ok()`, then `EndOp()` (`PushEndPolicy.finishOnError`) | `Recv.trace_failed_incoming_push`, `Pipeline.StagingSafe` |
| `bts.cc` | `ValidateChunks` | `:275-310` | `Reshard/Receive.lean`, `Reshard/Send.lean`, `Reshard/Coverage.lean` | per-chunk span check after `GetBlockChunks` (`GetBlockArrayHostSpan` → `ResolveBlockArrayHostLayer` → `ResolveStagingSlot`) | — |
| `bts.cc` | `BlockTransportServerPushSession::StartStream` | `:371-505` | `Reshard/Pipeline.lean` | `BeginIncomingPush` / `EndIncomingPush` (also from the `absl::Cleanup` on any early error return) around the incoming push stream | `Pipeline.StagingSafe` |
| `bts.cc` | `BlockTransportServerPushSession::CompleteIncomingPush` | `:724-893` | `Reshard/Pipeline.lean`, `Reshard/Coverage.lean` | Plan-declared progress: counts completed streams against `expected_pushes` and delivers the pool completion once (`session->OnDataReceived(pool_idx, {}, {})` on the session `BeginIncomingPush` returned → `ReshardReceiveSession::OnPoolReceived`; `Pipeline.Ev.landStream`) | `Pipeline.StreamAccountingSafe`, mutant `Pipeline.mutant_onPoolReceived_before_all_streams` |
| `bt.cc` | `BlockTransport::AsyncPushShards` | `:570-634` | `Reshard/Coverage.lean`, `Reshard/Send.lean` | Sender stream fan-out (`min(parallelism, num_blocks)`) and `BuildBlockRequests` call | `Coverage.stream_count_matches` |
| `bt.cc` | `BlockTransport::BuildBlockRequests` | `:744-862` | `Reshard/Coverage.lean`, `Reshard/Send.lean` | Sub-block request construction, `GetBlockChunks` and the shared `ValidateChunks(..., uuid, chunks)` span check | `Coverage.partition_reconstructs_perm` |
| `planner.cc` | `DefaultTransferStreams` | `:611-628` | `Reshard/Coverage.lean` | `Coverage.defaultTransferStreams`, `Coverage.resolvePlanParallelism` | `Coverage.trace_default_transfer_streams_test_parity` |
| `planner.cc` | `BuildPoolReshardPlan` | `:630-1340` | `Reshard/Coverage.lean` | `Coverage.senderStreams`, `Coverage.recomputedExpectedPushes` | `Coverage.stream_count_matches`, `Coverage.senderStreams_pos_iff` |
<!-- source-map:end -->

### Registry and coordinator (`reg.{h,cc}`, `coord.{h,cc}`)

<!-- source-map:begin -->
| File | Symbol / anchor | Lines | Lean module | Model events / definitions | Key theorems / mutants |
|---|---|---|---|---|---|
| `reg.h` | `RequestBlockRegistry` | `:45-151` | `Reshard/Registry.lean` | `RegGen`, `request_blocks_`, `claimed_`, `claimed_owners_`, `completed_units_`, `cancelled_` | `Registry.reachable_safe` |
| `reg.cc` | `RequestBlockRegistry::PurgeExpiredRequestBlocksLocked` | `:61-69` | `Reshard/Registry.lean` | `RegGen.purgeExpiredRequestBlocks` | mutant `Registry.mutant_split_ttl_purges_request_blocks_while_claim_active` |
| `reg.cc` | `RequestBlockRegistry::PurgeExpiredLifecycleLocked` | `:71-96` | `Reshard/Registry.lean` | `RegGen.purgeExpiredAll` | `Registry.purgeExpiredAll_inv` |
| `reg.cc` | `RequestBlockRegistry::RetireLocked` | `:98-116` | `Reshard/Registry.lean` | Erases `request_blocks_` and claim state on completion | `Registry.complete_retires_iff_all_claimed_voted` |
| `reg.cc` | `RequestBlockRegistry::Register` | `:118-300` | `Reshard/Registry.lean` | `Ev.register` | `Registry.tombstone_blocks_register_and_claim`, `Registry.claimed_blocks_register_and_cancel` |
| `reg.cc` | `RequestBlockRegistry::Complete` | `:317-371` | `Reshard/Registry.lean` | `Ev.complete` | `Registry.complete_retires_iff_all_claimed_voted`, `Registry.trace_single_stage_votes_retire_multi_owner_claim`, mutant `mutant_premature_complete_retires_while_peer_active` |
| `reg.cc` | `RequestBlockRegistry::CancelIfUnclaimed` | `:373-405` | `Reshard/Registry.lean` | `Ev.cancelIfUnclaimed` | `Registry.tombstone_blocks_register_and_claim` |
| `reg.cc` | `RequestBlockRegistry::LookupAndClaim` | `:439-501` | `Reshard/Registry.lean` | `Ev.lookupAndClaim` (refreshes claimed rows' `expires_at` alongside `claimed_`) | `Registry.claimed_blocks_register_and_cancel`, `Registry.trace_claim_refreshes_registration_ttl_while_failed_claim_does_not`, mutant `Registry.mutant_split_ttl_purges_request_blocks_while_claim_active` |
| `reg.cc` | `RequestBlockRegistry::AbandonClaim` | `:503-519` | `Reshard/Registry.lean` | `Ev.abandonClaim` | `Registry.abandonClaim_preserves_when_other_owner_present`, mutant `mutant_unconditional_abandon_exposes_sibling_owner_to_cancel` |
| `coord.h` | `SubTransferChain` | `:108-111` | `Reshard/SubPlanChain.lean` | `SubPlanChain.SubTransferSlice`, `SubPlanChain.SubTransferChain` | `SubPlanChain.planSubTransfers_no_aliased_window_split` |
| `coord.h` | `ReshardCoordinator` | `:138-207` | `Reshard/Coordinator.lean`, `Reshard/SubPlanChain.lean` | `CoordState`, `CoordInv`, `CoordChainState`, `CoordChainSafe` | `Coordinator.reachable_coord_inv`, `SubPlanChain.reachable_coordChain_safe` |
| `tpu_sync/kv_cache/kv_cache_listener.cc` | `KVCacheListener::HandleControlRequest` | `:103-228` | `Reshard/Coordinator.lean` | framed TCP listener routing `COMMAND_START_TRANSFER` to `PoolReshardPush` when `start_req.is_sender()` else `PoolReshardRegisterRecv` | — |
| `coord.cc` | `BuildStartTransferForTarget` | `:111-271` | `Reshard/Coordinator.lean` | Target request construction (`is_sender` when unit in `src_units`) | — |
| `coord.cc` | `SubPlanUuid` | `:356-367` | `Reshard/SubPlanChain.lean` | `SubPlanChain.subPlanUuid` (63-bit positive `splitmix64` for `index > 0`) | `SubPlanChain.subPlanUuid_zero`, `SubPlanChain.subPlanUuid_pos_of_pos` |
| `coord.cc` | `PlanSubTransfers` | `:369-472` | `Reshard/SubPlanChain.lean` | `SubPlanChain.planSubTransfers`, `hasWindowedTagSharingIds` | `SubPlanChain.planSubTransfers_no_aliased_window_split` |
| `coord.cc` | `ReshardCoordinator::StartPoolReshard` | `:474-526` | `Reshard/Coordinator.lean`, `Reshard/SubPlanChain.lean` | `ChainEv.startChainCoordination` (`transfer_status_` transitions `if (!chain_started)`) | `SubPlanChain.reachable_coordChain_safe` (`CompletedOnlyAtChainEnd`) |
| `coord.cc` | `ReshardCoordinator::ExecutePoolReshard` | `:528-601` | `Reshard/Coordinator.lean`, `Reshard/SubPlanChain.lean` | Draws `claim_owner`, builds `ChainContext`, runs `RunSubPlan(ctx, 0)`, and spawns `StartChain` when `chain.count > 1` | `Coordinator.reachable_coord_inv`, `SubPlanChain.reachable_coordChain_safe` |
| `coord.cc` | `ReshardCoordinator::StartChain` | `:614-649` | `Reshard/SubPlanChain.lean` | Multi-window chain continuation (`RunSubPlan(ctx, 1 .. count - 1)`) and final `transfer_status_` publication | `SubPlanChain.reachable_coordChain_safe` (`ClaimHeldAcrossWindows`), `SubPlanChain.trace_chained_request_stays_in_progress_until_chain_ends`, `SubPlanChain.trace_chained_arm_failure_keeps_claim_past_last_vote` |
| `coord.cc` | `ArmRefusedForBusyStaging` | `:667-670` | `Reshard/SubPlanChain.lean` | `ChainEv.armDstResult _ .refusedBusy`, `ChainEv.retryBusyArm` (`kChainArmAttempts` re-arm loop while an earlier window holds staging) | `SubPlanChain.reachable_coordChain_safe` (`OneWindowStagedPerDestination`), `SubPlanChain.trace_chained_arm_retries_while_receiver_staging_busy`, `SubPlanChain.trace_busy_refusals_exhaust_arm_attempts` |
| `coord.cc` | `ReshardCoordinator::RunSubPlan` | `:678-932` | `Reshard/Coordinator.lean`, `Reshard/SubPlanChain.lean`, `Reshard/Pipeline.lean` | Stage 0 `LookupAndClaim`, Stage 1 parallel destination arming & busy-staging retries, Stage 2 parallel sender dispatch, `if (index == 0)` on `AbandonClaim` | `Coordinator.no_push_before_all_armed`, `Coordinator.claimed_while_arming`, `Coordinator.trace_partial_arm_orphans_armed_receiver`, `Coordinator.trace_dispatch_failure_orphans_receivers_and_claim`, `SubPlanChain.reachable_coordChain_safe` (`NoSenderExposed`), mutant `SubPlanChain.stepAbandonAtEveryIndex` |
<!-- source-map:end -->

*External, the production reshard caller pair (`Transfer/Caller.lean`):*
vllm-torchtpu `src/vllm_torchtpu/distributed/kv_transfer/tpu_connector.py`,
vLLM `vllm/distributed/kv_transfer/kv_connector/utils.py`, and
vLLM `vllm/v1/core/sched/scheduler.py`
(`TPURaidenConnectorWorker.get_finished`, `_poll_finished`,
`_apply_stage3_submit_outcome`, `_stage3_fail_uncertain_loads_early`,
`get_block_ids_with_load_errors`, `_sync_stage3_tp_submit_states`,
`get_finished_count`; `KVOutputAggregator.aggregate`;
scheduler `_handle_invalid_blocks`, `_update_from_kv_xfer_finished`,
`finish_requests`, `_update_waiting_for_remote_kv`, `kv_load_failure_policy`) →
`Caller.contract_safe`, `Caller.mw_contract_safe`,
`Caller.applyRecv_eager_eq_latched`, `Caller.applyRecv_staggered_eq_batch`,
`Caller.twoChannel_contract`, `Caller.earlyLoadError_fail_eq_finish`,
`Caller.earlyLoadError_fail_holds_blocks`,
`Caller.mw_earlyLoadError_fail_eq_finish`,
`Caller.mw_earlyLoadError_fail_holds_blocks`,
`Caller.trace_twoChannel_early_uncertain_load_error`, `Caller.trace_twoChannel_*`,
`Caller.trace_mw_staggered_*`, `Caller.trace_mw_overcounted_expected_leaks`.

## Where the rest lives

| Content | File |
|---|---|
| `trace_*` witnesses and the tests they replay; `#guard` bounded searches | the theorem docstrings and `#guard` lines in the Lean modules (`grep -rn "theorem trace_\|#guard" TpuSyncVerify/Transfer/Reshard`) |
| how the models are written (one executable `step`, ghost fields, replay, mutants) | [conventions.md](../conventions.md) |
