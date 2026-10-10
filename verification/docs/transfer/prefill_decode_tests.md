# Prefill-to-decode transfer: replay evidence (traces, bounded searches, tests)

Companion to [prefill_decode.md](prefill_decode.md) (the routing index and
results). This file is the long tail: every executable `trace_*` witness,
the `#guard` bounded searches, and the C++/Python test → Lean correspondence.
Each `trace_*` theorem also carries this information in its own docstring in
the Lean module, which is the canonical copy; `grep -n "^theorem trace_"` under
`TpuSyncVerify/Transfer/` lists them. All `file:line` citations are to tpu-sync
**`50b0774`**.

## Executable trace witnesses (`trace_*`) & bounded searches

Traces (all machine-checked via `decide`):

| Theorem | Shows |
|---|---|
| `Recv.trace_normal`, `Send.trace_normal`, `Pipeline.trace_normal` | the happy path reaches publication with the data in decode HBM |
| `Pipeline.trace_layers_out_of_order` | two layers: D2H finishes 1 then 0, pushes complete 1 then 0, layer 1 lands and is dispatched first, H2D finishes 1 then 0 — publication finds `[kv 0, kv 1]` |
| `Pipeline.trace_wake_needs_own_layer` | `SendNextLayer(0)` does not proceed on layer 1's finished copy |
| `Recv.trace_poll_before_callbacks` | `IsReadyToComplete` can be true before the callbacks ran; publication waits |
| `Recv.trace_poll_skips_metrics` | shipping code, one layer: the poll finishes in that window, the last callback finds `draining_` and skips `RecordTransferDuration`/`RecordH2dComplete`/`RecordEnd`, the engine still sees `done_recving` |
| `Recv.trace_noPoll_normal` | the same transfer with the poll removed (`stepM false`): the callback finishes and records |
| `Recv.trace_zero_layers_poll` | with `num_layers() == 0` only the poll ever finishes the session (`noPoll_zero_layers_never_succeeds` is the general statement) |
| `Recv.trace_deadline_during_copy`, `Send.trace_deadline_during_copy` | a deadline under an in-flight copy drains (`draining_ = true`) but does not settle (`done_ = false`) or release staging until the copy finishes |
| `Recv.trace_deadline_during_handshake` | a deadline on `sysLoad` while the pull handshake is pending keeps staging pinned until `pullReply` ends the op (`ExpiredReceiveKeepsStagingUntilHandshakeEnds`) |
| `Recv.trace_net_completion_waits_for_h2d` | `network_completed_` is set while an H2D copy is still running; neither the poll nor publication can complete until the copy finishes (`NetworkCompletionWaitsForH2d`) |
| `Recv.trace_late_net_account_after_retire` | a fast H2D callback finishes and retires the session before `OnBlocksReceived`; the late `netAccount` is ignored (`LateBlockAccountingAfterRetirementIsANoOp`) |
| `Recv.trace_failed_h2d_waits_for_other_layer` | two layers' H2D copies issued; one fails while the other runs; staging and failure publication wait for the remaining copy (`FailedLayerWaitsForOtherH2dCopies`) |
| `Recv.trace_push_lease_pins_staging_on_cancel` | an open incoming push lease (`pushBegin`) keeps staging pinned across `cancel` and rejects new pushes until `pushEnd` (`IncomingPushLeasePinsStagingDuringWriteAndRejectsWhenDraining`) |
| `Recv.trace_push_lease_outlives_h2d` | H2D copy and callback finish while the incoming push lease is still open; `done` stays `false` and `hasStaging` stays `true` until `pushEnd` (`IncomingPushLeaseSpansLayerH2dAndBlockAccountingBeforeReleasing`) |
| `Recv.trace_finish_between_locks` | the race between the two locks of `ExecuteLayerH2d` that the `.cc:605-616` `done_ \|\| draining_` re-check closes |
| `Recv.trace_no_push_after_finish`, `Pipeline.trace_no_push_after_settle` | nothing lands in a settled receive's staging |
| `Send.trace_never_pulled`, `Send.trace_zero_layers` | the two degenerate sends (unpulled send expiring cleanly at deadline; zero-layer send finishing immediately in `StartPush`) |
| `Send.trace_duplicate_pull_rejected`, `Send.trace_pull_spawn_failure_cleanup` | `ValidateAndBeginPull` sets `pull_started_` atomically and rejects duplicate pulls both before and after `StartPush` begins (`DuplicatePullIsRejectedBeforeAcknowledgement`); when the `StartPush` thread spawn fails after the claim (`counter_cleanup`, `mgr.cc:1508-1516`, `kKvCacheManagerPullSpawn`), `Finish(error)` settles the session at once with no staging, publishes failure, and a late `StartPush` (`.start`) is rejected |
| `Send.trace_push_fails` | a failed push drains the chain |
| `Send.trace_drain_h2h_and_d2h` | `cancel` with layer 0 H2H and layer 1 D2H both in flight: layer 0 H2H finishes first (`done` stays `false`), then layer 1 D2H finishes and `wake` drops layer 1 H2H and settles (`DoneGuaranteesAllResourcesReleasedAndNoHbmOrTransportAccessAfterDone`) |
| `Send.trace_failed_d2h_waits_for_other_layer` | layer 0 D2H fails while layer 1 D2H runs; failure and staging release wait for layer 1 D2H (`FailedLayerWaitsForTheOtherLayersCopies`) |
| `Send.trace_cancel_after_ok_finish`, `Send.trace_ok_after_cancel_keeps_failure` | first-finish-wins on the send side in both directions (`FailureCannotOverrideAnEarlierSuccess`, `SuccessCannotOverrideAnEarlierFailure`) |
| `Pipeline.trace_registered_and_duplicate_pull` | registered offer is claimed by `.send .beginPull` and acknowledged by `.recv (.pullReply true)`; duplicate `.send .beginPull` is rejected (`RegisteredPullIsAcknowledged`, `DuplicatePullIsRejectedBeforeAcknowledgement`) |
| `Pipeline.trace_unregistered_pull_rejected` | on `sysUnregistered 1`, `.send .beginPull`, `.recv (.pullReply true)`, and `.send .start` are all rejected; `.pullWait` followed by `.recv (.pullReply false)` settles and publishes failure (`PullWithoutRegistrationIsRejected`; compare `PullAfterRegistrationDeadlineIsRejected`, covered on a registered offer by `Send.trace_never_pulled`) |
| `Pipeline.trace_pull_ahead_of_registration` | on `sysUnregistered 1`, `HandlePullStream` waits in `cv_.WaitWithTimeout` (`.pullWait`), `NotifyForRead` registers the offer (`.notifyForRead`), and the full transfer completes to `done_sending` and `done_recving` (`PullAheadOfRegistrationIsAcknowledgedOnceRegistered`) |
| `Pipeline.trace_shutdown_unblocks_pending_pull` | while `.pullWait` is waiting on an unregistered offer, shutdown cancels both sessions and fails the pending pull (`.recv (.pullReply false)`), unblocking the consumer and settling both sides (`ShutdownUnblocksPendingPull`) |
| `Pipeline.trace_slow_consumer` | producer published, reclaimed and reseated before the consumer lands anything; data still right |
| `Pipeline.trace_no_dispatch_before_land` | `h2dBegin l` needs layer `l` to have landed |
| `Pipeline.trace_aborted_issue_cannot_ready` | `h2dReady l` needs layer `l`'s own `h2dIssue l` to have issued the copy (cannot borrow another layer's `issued` count) |
| `Pipeline.trace_multi_request` | request $R_0$ cancels mid-flight, drains, publishes failed outcomes, and hands off all four buffers via `.nextRequest 0` to request $R_1$, which completes a full transfer to `decodeHbm = [.kv 0]` |
| `Pipeline.trace_overlapped_requests` | request $R_0$ finishes its send side, `.recyclePrefill 0` immediately recycles prefill HBM and prefill staging to start request $R_1$ while $R_0$'s receive side has not yet started; $R_1$'s send side and $R_0$'s receive side run concurrently, and both finish with `decodeHbm = [.kv 0]` |
| `PeerIsolation.trace_tcp_sick_peer_blocks_healthy` | on `tcpBlocking`, `poolSize` handshakes to `Peer.sick` hold all workers (`freeWorkers = 0`) and block a `Peer.healthy` handshake until a `.sick` handshake times out (Issue #888) |
| `PeerIsolation.trace_grpc_sick_peer_does_not_delay_healthy`, `PeerIsolation.trace_grpc_healthy_progresses_under_backlog` | on `grpcAsync`, waiting handshakes to `Peer.sick` hold no worker (`freeWorkers = poolSize`), so `Peer.healthy` transfers complete and publish `done_recving` while `Peer.sick` reads stay stalled (`GrpcSickPeerDoesNotDelayHandshakeToHealthyPeer`, `GrpcHealthyPeerProgressesWhileSickPeerBacklogDrains`) |
| `PeerIsolation.trace_consumer_gives_up_and_drains` | stalled reads to `Peer.sick` give up on handshake timeout (`pullReply false`), publish failure (`published = some false`), and return all staging slots (`ConsumerGivesUpOnProducerThatNeverAnswers`) |
| `PeerIsolation.trace_sick_peer_starves_staging_slots`, `PeerIsolation.trace_per_peer_quota_admits_healthy` | under shipping `unboundedPerPeer`, `numSlots` wedged reads to `Peer.sick` exhaust `freeSlots = 0` (even after `.cancel`) and reject `Peer.healthy` (`DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`); under design alternative `perPeerQuota 1`, the second `.sick` read is refused and `Peer.healthy` is admitted and completes |
| `UuidTable.trace_duplicate_uuid_rejected_until_drained` | an expired receive session (`draining = true, done = false`) with an in-flight H2D copy is neither swept (`.sweepRecv`) nor replaced (`.registerRecv` on the same UUID is rejected), and keeps its staging slot; once the copy finishes (`done = true`) and `.sweepRecv` retires `"old"` into `failedRecving = [0]` and restores `freeSlots = 4`, `.registerRecv` seats `"retry"` (`gen = 1`), which then expires and is swept into `failedRecving = [0, 1]` with `recvTable[0]? = some none` (`DuplicateUuidIsRejectedUntilExpiredReceiveDrains`) |
| `UuidTable.trace_duplicate_receive_different_req_id`, `UuidTable.trace_repeated_receive_same_req_id_idempotent` | on `.startRead`, a colliding UUID with a different `reqId` reports `failedRecving = [reqId]` without replacing the incumbent or allocating staging (`DuplicateReceiveDoesNotReplaceOrLeakFirstRead`), whereas a repeated announcement with the same `reqId` is an idempotent no-op (`RepeatedReceiveAnnouncementIsIdempotent`) |
| `UuidTable.trace_duplicate_send_cannot_replace_live_offer`, `UuidTable.trace_start_read_retires_settled_incumbent_inline` | `.notifyForRead` rejects a duplicate UUID while a live send offer is active (`!done`) and permits reuse after `sweepSend` (`DuplicateRegistrationCannotReplaceLiveOffer`); `.startRead` retires a settled (`done = true`) incumbent inline before seating the new session |
| `BlockOrdering.trace_duplicate_registration_rejected`, `BlockOrdering.trace_subset_pull_acknowledged`, `BlockOrdering.trace_unregistered_block_rejected`, `BlockOrdering.trace_duplicate_source_block_rejected`, `BlockOrdering.trace_empty_pull_rejected` | `PopulateRegisteredBlocks` at `NotifyForRead` rejects duplicate `block_ids` (`validateRegistration [0, 0] = false`, `DuplicateBlocksAreRejectedAtRegistration`; `validateRegistration [] = true`, as the C++ empty-`block_ids` check is earlier in `NotifyForRead` at `mgr.cc:439-441`); `ValidateAndBeginPull` acknowledges a non-empty duplicate-free subset (`UniqueRegisteredSubsetIsAcknowledged`) and rejects unregistered blocks (`PullOfUnregisteredBlockIsRejected`), duplicate source blocks (`PullWithDuplicateSourceBlockIsRejected`), or empty requests (`EmptyPullIsRejected`) |
| `BlockOrdering.trace_local_orchestrated_transfer`, `BlockOrdering.trace_custom_host_block_transfer` | single-layer pull of remote block `0` into device block `1` (`BlockPipeline.sys 1 2 2 [0] [⟨0, 1, 0⟩]`; device block `0` untouched — `LocalOrchestratedTransfer`), and the same pull staged through the caller-supplied `local_host_block_ids = [4]` (`allocateStagingForLoad [1] (.customHost [4]) = some [4]`, `sys 1 2 6 …`): host block `4` and device block `1` receive the data while host block `5` and device block `0` stay blank (`LocalOrchestratedTransferToCustomHostBlock`) |
| `BlockOrdering.trace_non_contiguous_blocks`, `BlockOrdering.trace_host_reordering`, `BlockOrdering.trace_large_complex_non_contiguous_and_reorder` | 2-layer transfers (layers completing out of order) with non-contiguous source blocks `remote = [0, 2]` into `local = [0, 1]` of 3 (`test_non_contiguous_blocks`); reversed source order `remote = [1, 0]`, `local = [0, 1]`, re-sorted by `BuildLoadCopyPlan`'s `remote_order` so `local[0] ← remote[1]`, `local[1] ← remote[0]` (`test_host_reordering`); and 10 of 16 blocks per layer, `registered = [0, 2, 3, 5, 6, 7, 9, 11, 12, 14]`, requested in reverse into `local = [0..9]`, with `BuildCoalescedCopySpec` compressing the sorted D2H blocks into 6 contiguous DMA runs and blocks `10..15` untouched (`test_large_complex_non_contiguous_and_reorder`) |

Bounded searches (`#guard … = .outOfFuel`): `Recv` from both initial states
(`sysPush 2` and `sysLoad 2`, fuel 10, n = 2), `ReceivePoll` under `stepM false`
from `sysMPush false 2` and `sysMLoad false 2` confirming `violatesMetrics` is
unreachable (fuel 10, n = 2, whereas shipping `sysMPush true 1` yields a
`.counterexample` at fuel 8), `Send` (fuel 12, n = 2), `Pipeline` from `sys 1`
(`init 1`, fuel 10), from `sysUnregistered 1` (`initUnregistered 1` — pull ahead
of registration — fuel 8), from `afterProducer` (fuel 10), from `afterProducer2`
— the two-layer producer that finished out of order — over the initial consumer
landing and dispatch steps (fuel 5, n = 2), from `afterDispatch2` — after
out-of-order landing and dispatch of both layers — over all H2D completion,
callback, publication, cancellation and staging-reuse interleavings (fuel 7,
n = 2), `PeerIsolation` under `perPeerQuota 1` confirming the first
`Peer.healthy` read is never starved across any interleaving (fuel 5, whereas
shipping `unboundedPerPeer` yields a `.counterexample` at fuel 4), and
`UuidTable` confirming `violatesSlotConservation` is unreachable across all UUID
registration, drain, and sweep interleavings (fuel 5).

## Test suite correspondence (C++ & Python tests → Lean)

How the C++ unit tests (`tools/run_cc_tests.sh`) and Python E2E tests
correspond to the Lean trace theorems (`trace_*`) and general safety theorems
(`reachable_safe`, `reachable_can_settle`, `system_data_correct`, `system_progress`):

### 1. Producer session tests (`TransferSendSession` → `Send.lean`)

| Test | File & lines | Lean trace theorem | General theorem |
|---|---|---|---|
| `DoneGuaranteesAllResourcesReleasedAndNoHbmOrTransportAccessAfterDone` | `transfer_send_session_test.cc:295-352` | `Send.trace_drain_h2h_and_d2h` | `Send.reachable_safe` (`SettleSafe`, `Drained`, `StagingIntegrity`) |
| `FailedLayerWaitsForTheOtherLayersCopies` | `kv_cache_manager_with_transfer_send_drain_test.cc:332-350` | `Send.trace_failed_d2h_waits_for_other_layer` | `Send.reachable_safe`, `Pipeline.PrefillHbmSafe` |
| `ExpiredSendKeepsItsStagingUntilTheCopyEnds` | `kv_cache_manager_with_transfer_send_drain_test.cc:306-330` | `Send.trace_deadline_during_copy` | `Send.reachable_safe`, `Pipeline.PrefillHbmSafe` |
| `FailedSendWithoutWorkSettlesImmediately` | `kv_cache_manager_with_transfer_send_drain_test.cc:405-415` | `Send.trace_never_pulled` (the `[.cancel, .publish]` conjunct: a send with no in-flight work — here a synthetic send with `in_flight = 0` failed via `Decide(failed = true)` — settles, releases staging and is reported in `failed_recving` at once) | `Send.reachable_can_settle`, `Send.StagingIntegrity` |
| `ZeroLayerSessionCompletesAndReleasesStagingWithoutHang` | `transfer_send_session_test.cc:391-410` | `Send.trace_zero_layers` | `Send.reachable_safe`, `Send.reachable_can_settle` |
| `FinishBeforeStartPushDoesNotAcquireStagingOrAccessHbm` | `transfer_send_session_test.cc:266-293` | `Send.trace_pull_spawn_failure_cleanup` (`[.beginPull, .cancel, .publish]` settles with no staging; a later `.start` is rejected) | `Send.PullClaimed`, `Send.StagingIntegrity` |
| `SendSessionImplementsTransferSessionInterface` | `transfer_send_session_test.cc:156-186` | `Send.trace_deadline_during_copy` (`Finish(error)` with a D2H in flight drains but does not settle until the copy ends) | `Send.reachable_safe` (`SettleSafe`, `StagingIntegrity`) |
| `StatusIsFrozenOnceSessionIsDrainingOrDone` | `transfer_send_session_test.cc:433-463` | `Send.trace_cancel_after_ok_finish` | `Lifecycle.finishOnceLocked_decided`, `Lifecycle.finishOnceLocked_statusOk`, `Send.step_done_mono` |
| *(no C++ witness)* | — | `Send.trace_push_fails` (a failed H2H push drains the chain); no test currently fails an H2H push — `FakeSendBase::CompleteH2h(i, error)` at `transfer_send_session_test.cc:84-91` accepts an error status but every caller passes success | `Send.reachable_safe`, `Send.Publication` |
| `SuccessCannotOverrideAnEarlierFailure` | `kv_cache_manager_with_transfer_send_drain_test.cc:451-463` | `Send.trace_ok_after_cancel_keeps_failure` | `Lifecycle.finishOnceLocked_decided`, `Send.Inv.ok_draining`, `Send.Publication` |
| `FailureCannotOverrideAnEarlierSuccess` | `kv_cache_manager_with_transfer_send_drain_test.cc:437-449` | `Send.trace_cancel_after_ok_finish` | `Lifecycle.finishOnceLocked_decided`, `Lifecycle.finishOnceLocked_statusOk` |
| `SendNobodyPulledFailsAtItsDeadline`, `ExpiredSendSessionFailsInsteadOfReportingDone` | `kv_cache_manager_with_transfer_send_drain_test.cc:352-361`, `kv_cache_manager_with_transfer_pool_reshard_test.cc:338-347` | `Send.trace_never_pulled` | `Send.Inv.published_done`, `Send.Publication`, `Send.StagingIntegrity` |

### 2. Consumer session & control tests (`TransferReceiveSession` → `Receive.lean`)

| Test | File & lines | Lean trace theorem | General theorem |
|---|---|---|---|
| `ExpiredReceiveKeepsStagingUntilHandshakeEnds` | `kv_cache_manager_with_transfer_control_test.cc:792-832` | `Recv.trace_deadline_during_handshake` | `Recv.reachable_safe` (`SettleSafe`, `StagingIntegrity`) |
| `ReceiveWithoutTrafficFailsAtItsDeadline`, `UnregisteringIdleReceiverReleasesPlanAtOnce`, `DemandStagedReceiverPlanUnregistersWhenItSettles` | `kv_cache_manager_with_transfer_send_drain_test.cc:591-602`, `kv_cache_manager_with_transfer_pool_reshard_test.cc:409-434, 538-561` | `Recv.trace_deadline_during_handshake` (the idle `sysPush 1 [.cancel, .publish]` conjunct) | `Recv.SettlesPromptly`, `Recv.StagingIntegrity` |
| `ExpiredReceiveKeepsStagingUntilH2dEnds` | `kv_cache_manager_with_transfer_send_drain_test.cc:604-631` | `Recv.trace_deadline_during_copy` | `Recv.reachable_safe` (`SettleSafe`, `StagingIntegrity`) |
| `TimeoutDuringH2dDispatchKeepsStaging` | `kv_cache_manager_with_transfer_send_drain_test.cc:712-748` | `Recv.trace_deadline_during_copy` (deadline inside `H2dSyncDispatch` after the `.cc:611-616` re-check linearises after `h2dIssue`, since `.cc:617-636` never re-reads `draining_`/`done_`) | `Recv.reachable_safe` (`SettleSafe`, `StagingIntegrity`), `Recv.reachable_can_settle` |
| `OutOfOrderLayersSettleAfterEveryH2d` | `kv_cache_manager_with_transfer_send_drain_test.cc:557-576` | `Pipeline.trace_layers_out_of_order` | `Recv.Accounted`, `Recv.SettleSafe` |
| `FailedLayerWaitsForOtherH2dCopies` | `kv_cache_manager_with_transfer_send_drain_test.cc:684-710` | `Recv.trace_failed_h2d_waits_for_other_layer` | `Recv.reachable_safe`, `Pipeline.DecodeHbmSafe` |
| `SingleFailedH2dReportsFailureAndReturnsStaging` | `kv_cache_manager_with_transfer_send_drain_test.cc:578-589` | `Recv.trace_failed_h2d_waits_for_other_layer` | `Recv.reachable_safe`, `Recv.reachable_can_settle` |
| `IncomingPushLeasePinsStagingDuringWriteAndRejectsWhenDraining`, `UnregisteringInFlightReceiverDefersUntilItSettles` | `kv_cache_manager_with_transfer_send_drain_test.cc:801-824`, `kv_cache_manager_with_transfer_pool_reshard_test.cc:436-476` | `Recv.trace_push_lease_pins_staging_on_cancel`, `Recv.trace_no_push_after_finish` | `Recv.StagingIntegrity`, `Pipeline.StagingSafe` |
| `FailedIncomingPushImmediatelyFailsSessionAndReleasesStagingBeforeDeadline` (added by `4efb0dd`) | `kv_cache_manager_with_transfer_send_drain_test.cc:854-882` | `Recv.trace_push_lease_pins_staging_on_cancel` (the `cancel`, `pushEnd`, `publish` steps: `end_incoming_push` now runs `Finish(status)` before `EndRecvOp`) | `Recv.StagingIntegrity`, `Recv.SettlesPromptly` |
| `IncomingPushLeaseSpansLayerH2dAndBlockAccountingBeforeReleasing` | `kv_cache_manager_with_transfer_send_drain_test.cc:826-852` | `Recv.trace_push_lease_outlives_h2d` | `Recv.Accounted`, `Recv.SettleSafe` |
| `NetworkCompletionWaitsForH2d` | `kv_cache_manager_with_transfer_send_drain_test.cc:483-501` | `Recv.trace_net_completion_waits_for_h2d` | `Recv.ReadinessSound`, `Recv.Publication` |
| `LateBlockAccountingAfterRetirementIsANoOp` | `kv_cache_manager_with_transfer_send_drain_test.cc:533-555` | `Recv.trace_late_net_account_after_retire` | `Recv.step_done_mono`, `Recv.reachable_safe` |

### 3. Multi-peer fault isolation & staging-slot starvation tests (`ControlHandshakeTest` → `PeerIsolation.lean`)

| Test | File & lines | Lean trace theorem | General theorem |
|---|---|---|---|
| `ConsumerGivesUpOnProducerThatNeverAnswers` | `kv_cache_manager_with_transfer_control_test.cc:684-716` | `PeerIsolation.trace_consumer_gives_up_and_drains` | `PeerIsolation.reachable_inv` (`slots` conservation), `PeerIsolation.reachable_sessions_safe` |
| *(no test — design comment only)* Issue #888 TCP blocking handshake pool; the TCP backend still runs the blocking call on `push_pool_` and is being retired rather than fixed | `kv_cache_manager_with_transfer_control_test.cc:834-847` (comment) | `PeerIsolation.trace_tcp_sick_peer_blocks_healthy` | `PeerIsolation.tcp_healthy_blocked_when_pool_full` |
| `GrpcSickPeerDoesNotDelayHandshakeToHealthyPeer` | `kv_cache_manager_with_transfer_control_test.cc:924-964` | `PeerIsolation.trace_grpc_sick_peer_does_not_delay_healthy` | `PeerIsolation.grpc_freeWorkers_eq_poolSize`, `PeerIsolation.grpc_healthy_can_complete` |
| `GrpcHealthyPeerProgressesWhileSickPeerBacklogDrains` | `kv_cache_manager_with_transfer_control_test.cc:971-1028` | `PeerIsolation.trace_grpc_healthy_progresses_under_backlog` | `PeerIsolation.grpc_freeWorkers_eq_poolSize`, `PeerIsolation.grpc_healthy_can_complete` |
| `DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer` | `kv_cache_manager_with_transfer_control_test.cc:1041-1089` (rationale comment `:1030-1040`) | `PeerIsolation.trace_sick_peer_starves_staging_slots` (shipping `unboundedPerPeer` counterexample), `PeerIsolation.trace_per_peer_quota_admits_healthy` (design alternative `perPeerQuota` fix) | `PeerIsolation.reachable_sick_staging_le_quota`, `PeerIsolation.reachable_quota_admits_healthy` |

### 4. Manager UUID registration table, drain-before-reuse, control handshake & block-plan tests (`RecvDrainTest`, `SendLifecycleTest`, `ControlHandshakeTest`, `KVCacheManagerWithTransferTest` → `UuidTable.lean`, `Send.lean`, `Pipeline.lean`, `BlockOrdering.lean`)

| Test | File & lines | Lean trace theorem | General theorem |
|---|---|---|---|
| `DuplicateUuidIsRejectedUntilExpiredReceiveDrains` | `kv_cache_manager_with_transfer_send_drain_test.cc:633-682` | `UuidTable.trace_duplicate_uuid_rejected_until_drained` | `UuidTable.active_recv_preserved`, `UuidTable.reachable_inv` (`slots` conservation) |
| `DuplicateReceiveDoesNotReplaceOrLeakFirstRead` | `kv_cache_manager_with_transfer_control_test.cc:718-752` | `UuidTable.trace_duplicate_receive_different_req_id` | `UuidTable.active_recv_preserved`, `UuidTable.reachable_inv` |
| `RepeatedReceiveAnnouncementIsIdempotent` | `kv_cache_manager_with_transfer_control_test.cc:754-790` | `UuidTable.trace_repeated_receive_same_req_id_idempotent` | `UuidTable.active_recv_preserved`, `UuidTable.reachable_inv` |
| `DuplicateRegistrationCannotReplaceLiveOffer` | `kv_cache_manager_with_transfer_send_drain_test.cc:363-380` | `UuidTable.trace_duplicate_send_cannot_replace_live_offer` | `UuidTable.active_send_preserved`, `UuidTable.reachable_send_safe` |
| `RegisteredPullIsAcknowledged` | `kv_cache_manager_with_transfer_control_test.cc:281-291` | `Pipeline.trace_registered_and_duplicate_pull` | `Send.PullClaimed`, `Pipeline.HandshakeSafe` |
| `DuplicatePullIsRejectedBeforeAcknowledgement` | `kv_cache_manager_with_transfer_control_test.cc:367-379` | `Send.trace_duplicate_pull_rejected`, `Pipeline.trace_registered_and_duplicate_pull` | `Send.PullClaimed`, `Pipeline.HandshakeSafe` |
| `PullWithoutRegistrationIsRejected`, `PullAfterRegistrationDeadlineIsRejected` | `kv_cache_manager_with_transfer_control_test.cc:293-306, 308-330` | `Pipeline.trace_unregistered_pull_rejected` (unregistered offer, `:293-306`), `Send.trace_never_pulled` (`[.cancel, .beginPull] = none` on an expired registered offer, `:308-330`) | `Pipeline.HandshakeSafe`, `Pipeline.reachable_unregistered_safe`, `Send.PullClaimed` |
| `PullAheadOfRegistrationIsAcknowledgedOnceRegistered` | `kv_cache_manager_with_transfer_control_test.cc:332-351` | `Pipeline.trace_pull_ahead_of_registration` | `Pipeline.HandshakeSafe`, `Pipeline.reachable_unregistered_safe` |
| `ShutdownUnblocksPendingPull` | `kv_cache_manager_with_transfer_control_test.cc:555-573` | `Pipeline.trace_shutdown_unblocks_pending_pull` | `Pipeline.HandshakeSafe`, `Pipeline.reachable_unregistered_safe` |
| `DuplicateBlocksAreRejectedAtRegistration` | `kv_cache_manager_with_transfer_send_drain_test.cc:382-391` | `BlockOrdering.trace_duplicate_registration_rejected` | `BlockOrdering.validateRegistration_iff`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`) |
| `UniqueRegisteredSubsetIsAcknowledged` | `kv_cache_manager_with_transfer_control_test.cc:353-365` | `BlockOrdering.trace_subset_pull_acknowledged` | `BlockOrdering.validateRequestedBlocks_iff`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`) |
| `PullOfUnregisteredBlockIsRejected` | `kv_cache_manager_with_transfer_control_test.cc:381-394` | `BlockOrdering.trace_unregistered_block_rejected` | `BlockOrdering.validateRequestedBlocks_iff`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`) |
| `PullWithDuplicateSourceBlockIsRejected` | `kv_cache_manager_with_transfer_control_test.cc:396-409` | `BlockOrdering.trace_duplicate_source_block_rejected` | `BlockOrdering.validateRequestedBlocks_iff`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`) |
| `EmptyPullIsRejected` | `kv_cache_manager_with_transfer_control_test.cc:411-423` | `BlockOrdering.trace_empty_pull_rejected` | `BlockOrdering.validateRequestedBlocks_iff`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`) |
| `LocalOrchestratedTransfer` | `kv_cache_manager_with_transfer_test.cc:111-290` | `BlockOrdering.trace_local_orchestrated_transfer` | `BlockOrdering.BlockPipeline.reachable_safe` (`BlockPublicationCorrect`) |
| `LocalOrchestratedTransferToCustomHostBlock` | `kv_cache_manager_with_transfer_test.cc:324-438` | `BlockOrdering.trace_custom_host_block_transfer` | `BlockOrdering.BlockPipeline.reachable_safe` (`CustomHostStagingCorrect`) |

### 5. End-to-end prefill-to-decode transfer tests (`Pipeline.lean`, `BlockOrdering.lean`, `MultiRequest.lean`, `ReceivePoll.lean`)

| Test | File & lines | Lean theorem | Notes |
|---|---|---|---|
| `LocalOrchestratedTransfer`, `TreeBroadcastCorrectness8Nodes`, `MultiIpOrchestratedTransfer` | `kv_cache_manager_with_transfer_test.cc:111-290, 440-594, 596-676` | `Pipeline.trace_normal`, `Recv.noPoll_metrics_on_success` | E2E D2H → H2H → H2D transfer and `poll_stats()` publication; only `LocalOrchestratedTransfer` installs a `MockMetricsBackend` and expects the transfer-duration histogram exactly once (`:196-199`), so it is an implicit, timing-dependent witness that the last H2D callback normally beats the poll (`ReceivePoll.lean` proves `Recv.trace_poll_skips_metrics` for the interleaving where `pollReady` wins the pre-callback window) |
| `test_e2e_transfer_polling`, `test_parallel_pull` | `tpu_sync/api/jax/kv_cache_manager_transfer_test.py:102-185, 451-531`, `tpu_sync/api/torch/kv_cache_manager_transfer_test.py:147-174, 285-311` | `Pipeline.trace_normal`, `Pipeline.trace_layers_out_of_order`, `Pipeline.reachable_safe` | 2-layer E2E producer (`register_read`) → consumer (`start_read`) → `poll_stats()` verification that `dst_caches` match `src_refs` across all layers |
| Single-host disaggregated serving E2E | `examples/single_host_disagg/run_all.sh` | `Pipeline.trace_multi_request`, `Pipeline.trace_overlapped_requests`, `Pipeline.system_data_correct`, `Pipeline.system_progress` | Multi-request prefill-to-decode serving stream recycling HBM and host staging buffers across prompts |
| `test_non_contiguous_blocks`, `test_host_reordering`, `test_large_complex_non_contiguous_and_reorder` | `tpu_sync/api/jax/kv_cache_manager_transfer_test.py:187-272, 274-357, 359-449`, `tpu_sync/api/torch/kv_cache_manager_transfer_test.py:176-207, 209-238, 240-283` | `BlockOrdering.trace_non_contiguous_blocks`, `BlockOrdering.trace_host_reordering`, `BlockOrdering.trace_large_complex_non_contiguous_and_reorder`, `BlockOrdering.BlockPipeline.reachable_safe`, `BlockOrdering.execCoalesced_buildCoalescedSpec` | Full within-layer block-index gather, dual-permutation `BuildLoadCopyPlan`, and contiguous-run DMA coalescing across non-contiguous and reversed `remote_block_ids` (the tests pass in-order `local_block_ids`; arbitrary `local_block_ids` orders are covered by the general theorems), discharging `Pipeline` A1 |
