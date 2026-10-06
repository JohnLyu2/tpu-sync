# Prefill-to-decode transfer: model and results

The model of `proposal.md` §3, built in four stages under
`TpuSyncVerify/Transfer/PrefillDecode/`. Citations in the Lean files and in
this document are to tpu-sync **`50b0774`**.

## Modules

| Module | Stage | Models | Main theorem |
|---|---|---|---|
| `Common/ListAux.lean` | — | generic `List` indexing, `List.set`, and `countTrue` pigeonhole lemmas | `all_true_of_countTrue_eq_length`, `exists_false_lt`, `all_true_lt_of_countTrue` |
| `Transfer/Session.lean` | 1 | the settle protocol shared by the session classes: `in_flight_`, `draining_`, `done_`, staging ownership | `Consistent` is preserved by `beginOp`/`finish*`/`endOp` |
| `PrefillDecode/Receive.lean` | 1–2 | one `TransferReceiveSession` plus the manager's poll and publication; transport block accounting; `IsReadyToComplete` | `Recv.reachable_safe`, `Recv.reachable_can_settle` |
| `PrefillDecode/ReceivePoll.lean` | 2 (audit) | what the poll-side `IsReadyToComplete` finish contributes, with and without it (`stepM poll`); a `metrics` ghost for the last callback's `RecordEnd`/`RecordH2dComplete` | `Recv.reachable_callbackFinishes`, `Recv.pollReady_window`, `Recv.pollReady_no_settle`, `Recv.netAccount_frame`, `Recv.noPoll_metrics_on_success`, `Recv.noPoll_safe`, `Recv.noPoll_can_settle`, `Recv.noPoll_zero_layers_never_succeeds` |
| `PrefillDecode/Send.lean` | 3 | one `TransferSendSession`: `ValidateAndBeginPull` (`pull_started_` atomic claim), `StartPush`, the D2H loop, and the H2H push chain against one `in_flight_` | `Send.reachable_safe` (`PullClaimed`), `Send.reachable_can_settle` |
| `PrefillDecode/Pipeline.lean` | 4 | single-request pipeline: `Send` + `Recv` + control handshake rendezvous (`notifyForRead`, `pullWait`, `registered`, `pullWaiting`) + five layer-indexed memories (prefill HBM → staging → wire → decode staging → decode HBM), engine reclaim, staging reuse, buffer quietness, and single-request handoff (`PrefillReleased`, `HandedOff`) | `Pipeline.reachable_safe` (`HandshakeSafe`), `Pipeline.reachable_unregistered_safe`, `Pipeline.attention_safe`, `Pipeline.reachable_can_settle`, `Pipeline.handedOff_quiet`, `Pipeline.inv_can_handoff` |
| `PrefillDecode/MultiRequest.lean` | 4 | multi-request system (`multiSys`): `reqs : List Pipeline` concurrently sharing the four buffers with per-buffer read-after-release (`recyclePrefill`, `nextRequest`) and write-after-release (`wroteReleased`) checks | `Pipeline.system_data_correct`, `Pipeline.system_attention_safe`, `Pipeline.system_progress` |
| `PrefillDecode/PeerIsolation.lean` | 4 (multi-peer) | decode consumer pulling from `Peer.sick` and `Peer.healthy` prefill producers concurrently across `StagingBlockAllocator` (`numSlots`, `unboundedPerPeer` vs. `perPeerQuota maxPerPeer`) and `push_pool_` (`poolSize`, `tcpBlocking` vs. `grpcAsync`) | `PeerIsolation.reachable_inv`, `PeerIsolation.tcp_healthy_blocked_when_pool_full`, `PeerIsolation.grpc_healthy_can_complete`, `PeerIsolation.reachable_quota_admits_healthy` |
| `PrefillDecode/UuidTable.lean` | 4 (manager table) | manager UUID registration tables (`active_recv_sessions_[uuid]`, `send_sessions_[uuid]`), drain-before-reuse discipline (`EmplaceRecvSessionLocked`, `StartRead`, `NotifyForRead`), request-ID differentiation, and `PollStats` sweep | `UuidTable.reachable_inv`, `UuidTable.active_recv_preserved`, `UuidTable.active_send_preserved`, `UuidTable.reachable_recv_safe`, `UuidTable.reachable_send_safe` |
| `PrefillDecode/BlockOrdering.lean` | 4 (block-level) | within-layer block-index gather, dual-permutation `BuildLoadCopyPlan` (`transportBlocks` + `h2dSrc`/`h2dDst`), contiguous-run DMA coalescing (`BuildCoalescedSpec`), producer block registration & subset/uniqueness validation (`ValidateRequestedBlocks`), custom host staging (`kCustomHostBlocks`), and multi-layer `BlockPipeline` coupled via `step_pipe` to `Pipeline.step` | `BlockOrdering.execCoalesced_buildCoalescedSpec`, `BlockOrdering.landStage_get_requested`, `BlockOrdering.h2dStage_get_requested`, `BlockOrdering.BlockPipeline.step_pipe`, `BlockOrdering.BlockPipeline.reachable_safe` |
| `PrefillDecode/PipelineChecks.lean` | 4 | executable `decide` traces (including out-of-order layers, handshake rendezvous, and concurrent/overlapped requests), `#guard` bounded searches, and mutants | `Pipeline.trace_normal`, `Pipeline.trace_layers_out_of_order`, `Pipeline.trace_pull_ahead_of_registration`, `Pipeline.trace_multi_request`, `Pipeline.trace_overlapped_requests` |

Stage boundaries are the commits on `experimental` (see the README status
table). Each later stage uses the earlier models as-is: `Pipeline` composes
`Send.step` and `Recv.step`, adds the memory effect of each event and the
per-layer guards the counters cannot express (a push waits for *its* layer's
D2H copy; an H2D dispatch waits for *its* layer to land), `BlockOrdering`
refines `Pipeline`'s per-layer memory cell into a block-indexed array with a
lockstep forward simulation (`BlockPipeline.step_pipe`) over `Pipeline.step`,
`MultiRequest` composes transfers across concurrent and overlapped requests
reusing the four memories (`multiSys`), and `PipelineChecks` contains the
executable traces, bounded searches, and mutants.

## Proposal properties → theorems

| Property | Where proved | Statement |
|---|---|---|
| **System data correctness & attention safety across requests** | `Pipeline.system_data_correct`, `Pipeline.system_attention_safe` | Across any reachable state of `multiSys n` (`reqs : List Pipeline`, modeling concurrent/overlapped requests plus per-buffer read-after-release and write-after-release via `wroteReleased`), whenever any request `r` at index `idx` publishes `done_recving`, `r.decodeHbm = good n` and stays `good n` across all subsequent multi-request transitions (`reqStep`, `recyclePrefill`, `nextRequest`) |
| **System progress across requests** | `Pipeline.system_progress` | From any reachable multi-request state and any request `idx`, a finite trace settles `idx`, releases both host staging buffers to `BufferPool` and publishes both HBM outcomes (`HandedOff`), and enables both `.recyclePrefill idx` and `.nextRequest idx` |
| Publication correctness (single request) | `Pipeline.reachable_safe` (`PublicationCorrect`) | `recv.published = some true → decodeHbm = good n` |
| **Within-layer block gather, dual-permutation reordering, DMA coalescing & custom host staging** | `BlockOrdering.execCoalesced_buildCoalescedSpec`, `BlockOrdering.landStage_get_requested`, `BlockOrdering.h2dStage_get_requested`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`, `BlockPublicationCorrect`, `CustomHostStagingCorrect`) | Contiguous-run DMA coalescing is observationally identical to elementwise block copy (`execCoalesced = execElementwise`); dual-permutation sorting in `BuildLoadCopyPlan` (`transportBlocks` sorted by `dst_block_id`, `h2dSrc`/`h2dDst` sorted by `host_block_id`) algebraically cancels across arbitrary non-contiguous `remote_block_ids`, out-of-order `local_block_ids`, and custom `host_block_ids`, so on `done_recving` every layer `l` and request position `i` satisfies `decodeHbm[l][localBlocks[i]] = prefillHbm[l][requestedRemote[i]]` (`CustomHostStagingCorrect` on `decodeStaging[l][hostBlocks[i]]`) while unrequested HBM and staging blocks are untouched |
| Decode HBM safety & quietness | `DecodeHbmSafe`, `decodeHbm_quiet`, `attention_safe` | `recv.published ≠ none → pending = 0 ∧ retired = issued`, which proves `s'.decodeHbm = s.decodeHbm` for every subsequent transition (`decodeHbm_quiet`) and `s'.decodeHbm = good n` across any post-publication trace (`attention_safe`) |
| Prefill HBM safety & quietness | `PrefillHbmSafe`, `prefillHbm_quiet`, `prefillHbm_quiet_step` | `send.published ≠ none → d2hPending = false ∧ d2hRetired = d2hIssued`, which disables `d2hReady` once `poll_stats()` reports the send outcome (so the caller can safely reclaim `prefillHbm`) |
| Staging integrity & quietness | `Recv.StagingIntegrity`, `Send.StagingIntegrity`, `StagingSafe`, `prefillStaging_quiet`, `decodeStaging_quiet`, `wroteReleased_eq_false` | `hasStaging = !done`; once a staging buffer is released (`hasStaging = false`), `StagingSafe` proves no subsequent transfer step can modify that staging buffer or copy from it, and `wroteReleased_eq_false` combines all four into per-buffer post-release non-interference |
| Handshake rendezvous, subset/uniqueness validation & single-pull claim | `Send.PullClaimed`, `Pipeline.HandshakeSafe`, `Pipeline.reachable_unregistered_safe`, `BlockOrdering.validateRegistration_iff`, `BlockOrdering.validateRequestedBlocks_iff`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`) | `StartPush` (`send.started = true`) and all D2H/H2H activity require `NotifyForRead` registration (`registered = true` with non-empty duplicate-free `registeredBlocks`) and `ValidateAndBeginPull` (`send.pullStarted = true` with non-empty duplicate-free `requestedRemote ⊆ registeredBlocks`), discharging `Send` Assumption A1; while `HandlePullStream` waits in `cv_.WaitWithTimeout` (`pullWaiting = true`), `recv.pullPending = true` and `send.pullStarted = false` |
| Termination (no op leak / drain to settle) | `Recv.NoOpLeak`, `Recv.reachable_can_settle`, `Send.NoOpLeak`, `Send.reachable_can_settle`, `Pipeline.NoOpLeak`, `Pipeline.reachable_can_settle` | `0 < inFlight → ∃ e ∈ drainEvents, (step s e).isSome`: every accounted unit of `in_flight_` has an enabled step that advances or retires it, and every reachable state can drain to `done = true ∧ hasStaging = false`, publish both outcomes (`published ≠ none`), and reclaim prefill HBM (`reclaimed = true`) in finitely many steps |

Counter-level forms of publication are proved per side as well
(`Recv.Publication`: `done_recving → every H2D callback ran OK`;
`Send.Publication`: `done_sending → every push completed OK`), together with
settle safety (`done → inFlight = 0`), prompt settle, no op leak (`NoOpLeak`),
constructive drain to settle (`reachable_can_settle`), readiness soundness
(`IsReadyToComplete → ready = numLayers`) and the counter orderings.

## Correspondence

The module docstrings carry the full tables (field → C++, event → C++). What
was checked when:

| Stage | Files read (`50b0774`) | Notable |
|---|---|---|
| 1 | `transfer_receive_session.{h,cc}` | `ExecuteLayerH2d` re-checks `done_ || draining_` under its second lock (`.cc:605-616`); fault injection adds dispatch/completion failure paths; `in_flight_` starts at 1 for a load plan (`.cc:343`). All encoded. |
| 2 | `block_transport.cc`, `kv_cache_manager_with_transfer.cc` (`CompleteReadRaw`, `begin/end_incoming_push`, `OnBlocksReceived` path) | `OnLayerReceived` fires once per layer (`bt.cc:559-561`) and before `OnBlocksReceived` on the same thread (`bt.cc:601-615`): assumption A4 of `Receive.lean`. At `50b0774` the poll lives in `CompleteReadWithDetails` (`mgr.cc:908-1039`; `CompleteReadRaw`, `:1041-1047`, is a wrapper over it) and `end_incoming_push` finishes the session itself when the push failed (`4efb0dd`, `mgr.cc:239-242`). |
| 3 | `transfer_send_session.{h,cc}`, `mgr.cc` pull worker and deadline | two op chains on one counter; `SendNextLayer` carries an op across the pool task; `FinishLocked` is first-call-wins. |
| 4 | the above plus `bt.cc:467-501` (landing), `mgr.cc:925-935` (send publication), `send.cc:326` / `:451` (D2H copies and pushes are *issued* in layer order), `send.cc:382-386` (`SendNextLayer(l)` waits on layer `l`'s own future), `send.cc:97-114` (`ValidateRequestedBlocksLocked`), `recv.cc:262-330` (`BuildLoadCopyPlan`), `send.cc:203-232` (`BuildCoalescedCopySpec`) | layer granularity (`Pipeline` A1, discharged at block granularity by `BlockOrdering.lean` via `BlockPipeline.step_pipe`), delivery modelled after the callback (A2), one sender per layer (A3). Completion order is **not** assumed: every memory-touching event is layer-indexed. |

Assumptions are numbered per module (`Receive` A1–A4, `Send` A1–A6,
`Pipeline` A1–A4) and each names the guard that encodes it. The ones a reader
should know about:

* **Receive A4 / Pipeline A3** — transport ordering and a single sender per
  layer. Readiness soundness depends on A4; the mutant
  `Recv.netAccountUnordered` shows what breaks without it.
* **Send A3** — the send model counts copies and pushes without naming
  layers; sound for `Send` alone because it has no per-layer state. The
  pipeline, which does, does not inherit this: its events carry the layer
  and its ghost sets (`d2hReadyL`, `h2dReadyL`, …) record which layers have
  passed each stage, with `cnt_d2hReady` / `cnt_h2dReady` tying two of them to
  the session counters.
* **Send A5** — no consumer `Ack`: `HandleAck → AckSend → Finish()` has no
  non-test caller at `50b0774`, so it is not an event.
* **Pipeline A1 (discharged by `BlockOrdering.lean`)** — `Pipeline.lean` models
  each layer's payload as a single `Cell`. `BlockOrdering.lean` refines each
  layer's memory into a block-indexed array (`List BlockVal`), models
  `ValidateRequestedBlocks`, contiguous-run DMA coalescing (`BuildCoalescedSpec`),
  and the dual-permutation `BuildLoadCopyPlan` (`transportBlocks` + `h2dSrc`/`h2dDst`),
  and proves a lockstep forward simulation (`BlockPipeline.step_pipe`) over
  `Pipeline.step`.
* **Pipeline A2** — the push callback is modelled *before* the landing it
  reports; the real order is the reverse. The docstring gives the simulation
  argument (the pushed cell cannot change between issue and callback) and
  the one real trace shape this leaves out (layer landed, callback fails).
* **Pipeline A4** — the engine contract: decode reads only after
  `done_recving`, prefill frees only after `poll_stats()` reports the send
  (`done_sending` or `failed_recving`).

## Evidence the proofs are not vacuous

Traces (all `decide`):

| Theorem | Shows |
|---|---|
| `Recv.trace_normal`, `Send.trace_normal`, `Pipeline.trace_normal` | the happy path reaches publication with the data in decode HBM |
| `Pipeline.trace_layers_out_of_order` | two layers: D2H finishes 1 then 0, pushes complete 1 then 0, layer 1 lands and is dispatched first, H2D finishes 1 then 0 — publication finds `[kv 0, kv 1]`. The proposal's out-of-order question, answered inside the model |
| `Pipeline.trace_wake_needs_own_layer` | `SendNextLayer(0)` does not proceed on layer 1's finished copy |
| `Recv.trace_poll_before_callbacks` | `IsReadyToComplete` can be true before the callbacks ran; publication waits |
| `Recv.trace_poll_skips_metrics` | shipping code, one layer: the poll finishes in that window, the last callback finds `draining_` and skips `RecordTransferDuration`/`RecordH2dComplete`/`RecordEnd`, the engine still sees `done_recving` |
| `Recv.trace_noPoll_normal` | the same transfer with the poll removed: the callback finishes and records |
| `Recv.trace_zero_layers_poll` | with `num_layers() == 0` only the poll ever finishes the session (`noPoll_zero_layers_never_succeeds` is the general statement) |
| `Recv.trace_deadline_during_copy`, `Send.trace_deadline_during_copy` | a deadline under an in-flight copy drains but does not settle until the op ends |
| `Recv.trace_deadline_during_handshake` | a deadline on `sysLoad` while the pull handshake is pending keeps staging pinned until `pullReply` ends the op (`ExpiredReceiveKeepsStagingUntilHandshakeEnds`) |
| `Recv.trace_net_completion_waits_for_h2d` | `network_completed_` is set while an H2D copy is still running; neither the poll nor publication can complete until the copy finishes (`NetworkCompletionWaitsForH2d`) |
| `Recv.trace_late_net_account_after_retire` | a fast H2D callback finishes and retires the session before `OnBlocksReceived`; the late `netAccount` is ignored (`LateBlockAccountingAfterRetirementIsANoOp`) |
| `Recv.trace_failed_h2d_waits_for_other_layer` | two layers' H2D copies issued; one fails while the other runs; staging and failure publication wait for the remaining copy (`FailedLayerWaitsForOtherH2dCopies`) |
| `Recv.trace_push_lease_pins_staging_on_cancel` | an open incoming push lease (`pushBegin`) keeps staging pinned across `cancel` and rejects new pushes until `pushEnd` (`IncomingPushLeasePinsStagingDuringWriteAndRejectsWhenDraining`) |
| `Recv.trace_push_lease_outlives_h2d` | H2D copy and callback finish while the incoming push lease is still open; `done` stays `false` and `hasStaging` stays `true` until `pushEnd` (`IncomingPushLeaseSpansLayerH2dAndBlockAccountingBeforeReleasing`) |
| `Recv.trace_finish_between_locks` | the race the `.cc:605-616` re-check closes |
| `Recv.trace_no_push_after_finish`, `Pipeline.trace_no_push_after_settle` | nothing lands in a settled receive's staging |
| `Send.trace_never_pulled`, `Send.trace_zero_layers` | the two degenerate sends |
| `Send.trace_duplicate_pull_rejected`, `Send.trace_pull_spawn_failure_cleanup` | `ValidateAndBeginPull` sets `pull_started_` atomically and rejects duplicate pulls (`DuplicatePullIsRejectedBeforeAcknowledgement`), while `StartPush` requires `pullStarted = true` and `push_pool_->Schedule` spawn failure calls `Finish(error)` before `StartPush` (`kKvCacheManagerPullSpawn`) |
| `Send.trace_push_fails` | a failed push drains the chain |
| `Send.trace_drain_h2h_and_d2h` | `cancel` with layer 0 H2H and layer 1 D2H both in flight: layer 0 H2H finishes first (`done` stays `false`), then layer 1 D2H finishes and `wake` drops layer 1 H2H and settles (`DoneGuaranteesAllResourcesReleasedAndNoHbmOrTransportAccessAfterDone`) |
| `Send.trace_failed_d2h_waits_for_other_layer` | layer 0 D2H fails while layer 1 D2H runs; failure and staging release wait for layer 1 D2H (`FailedLayerWaitsForTheOtherLayersCopies`) |
| `Send.trace_cancel_after_ok_finish`, `Send.trace_ok_after_cancel_keeps_failure` | first-finish-wins on the send side in both directions (`FailureCannotOverrideAnEarlierSuccess`, `SuccessCannotOverrideAnEarlierFailure`) |
| `Pipeline.trace_registered_and_duplicate_pull` | registered offer is claimed by `.send .beginPull` and acknowledged by `.recv (.pullReply true)`; duplicate `.send .beginPull` is rejected (`RegisteredPullIsAcknowledged`, `DuplicatePullIsRejectedBeforeAcknowledgement`) |
| `Pipeline.trace_unregistered_pull_rejected` | on `sysUnregistered 1`, `.send .beginPull`, `.recv (.pullReply true)`, and `.send .start` are all rejected; `.pullWait` followed by `.recv (.pullReply false)` settles and publishes failure (`PullWithoutRegistrationIsRejected`, `PullAfterRegistrationDeadlineIsRejected`) |
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
| `PeerIsolation.trace_sick_peer_starves_staging_slots`, `PeerIsolation.trace_per_peer_quota_admits_healthy` | under `unboundedPerPeer`, `numSlots` wedged reads to `Peer.sick` exhaust `freeSlots = 0` (even after `.cancel`) and reject `Peer.healthy` (`DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`); under `perPeerQuota 1`, the second `.sick` read is refused and `Peer.healthy` is admitted and completes |
| `UuidTable.trace_duplicate_uuid_rejected_until_drained` | an expired receive session (`draining = true, done = false`) with an in-flight H2D copy rejects `.registerRecv` on the same UUID without leaking staging slots; once the copy finishes (`done = true`), `.registerRecv` retires the settled incumbent inline and seats the replacement (`DuplicateUuidIsRejectedUntilExpiredReceiveDrains`) |
| `UuidTable.trace_duplicate_receive_different_req_id`, `UuidTable.trace_repeated_receive_same_req_id_idempotent` | on `.startRead`, a colliding UUID with a different `reqId` reports `failedRecving = [reqId]` without replacing the incumbent or allocating staging (`DuplicateReceiveDoesNotReplaceOrLeakFirstRead`), whereas a repeated announcement with the same `reqId` is an idempotent no-op (`RepeatedReceiveAnnouncementIsIdempotent`) |
| `UuidTable.trace_duplicate_send_cannot_replace_live_offer`, `UuidTable.trace_start_read_retires_settled_incumbent_inline` | `.notifyForRead` rejects a duplicate UUID while a live send offer is active (`!done`) and permits reuse after `sweepSend` (`DuplicateRegistrationCannotReplaceLiveOffer`); `.startRead` retires a settled (`done = true`) incumbent inline before seating the new session |
| `BlockOrdering.trace_duplicate_registration_rejected`, `BlockOrdering.trace_subset_pull_acknowledged`, `BlockOrdering.trace_unregistered_block_rejected`, `BlockOrdering.trace_duplicate_source_block_rejected`, `BlockOrdering.trace_empty_pull_rejected` | `NotifyForRead` rejects empty or duplicate `block_ids` (`DuplicateBlocksAreRejectedAtRegistration`); `ValidateAndBeginPull` acknowledges a non-empty duplicate-free subset (`UniqueRegisteredSubsetIsAcknowledged`) and rejects unregistered blocks (`PullOfUnregisteredBlockIsRejected`), duplicate source blocks (`PullWithDuplicateSourceBlockIsRejected`), or empty requests (`EmptyPullIsRejected`) |
| `BlockOrdering.trace_local_orchestrated_transfer`, `BlockOrdering.trace_custom_host_block_transfer` | 2-layer local orchestrated transfer to device HBM (`LocalOrchestratedTransfer`) and to caller-supplied `host_block_ids` in `kCustomHostBlocks` mode without touching HBM (`LocalOrchestratedTransferToCustomHostBlock`) |
| `BlockOrdering.trace_non_contiguous_blocks`, `BlockOrdering.trace_host_reordering`, `BlockOrdering.trace_large_complex_non_contiguous_and_reorder` | 2-layer transfers with non-contiguous source/destination block IDs (`test_non_contiguous_blocks`), out-of-order destination block IDs sorted by `BuildLoadCopyPlan` (`test_host_reordering`), and combined 8-block non-contiguous gather + reverse/interleaved reordering with contiguous-run DMA coalescing (`test_large_complex_non_contiguous_and_reorder`) |

Bounded searches (`#guard … = .outOfFuel`): `Recv` from both initial states
(fuel 10, n = 2), `Send` (fuel 12, n = 2), `Pipeline` from `init 1` and from
`afterProducer` (fuel 10), from `afterProducer2` — the two-layer producer that
finished out of order — over the initial consumer landing and dispatch steps
(fuel 5, n = 2), from `afterDispatch2` — after out-of-order landing and
dispatch of both layers — over all H2D completion, callback, publication,
cancellation and staging-reuse interleavings (fuel 7, n = 2), `PeerIsolation`
under `perPeerQuota 1` confirming the first `Peer.healthy` read is never
starved across any interleaving (fuel 5, whereas `unboundedPerPeer` yields a
`.counterexample` at fuel 4), and `UuidTable` confirming `violatesSlotConservation`
is unreachable across all UUID registration, drain, and sweep interleavings
(fuel 5).

Mutants (each yields a `.counterexample` or refutation trace):

| Mutant | Guard removed | Property that catches it |
|---|---|---|
| `Recv.cancelEager`, `Send.cancelEager` | settle waits for `in_flight_ = 0` | settle safety |
| `Recv.netAccountUnordered` | layer accounted only after its copy is issued (A4) | readiness soundness |
| `Send.sendNextUncounted` / `d2hIssueUncounted` | the op `SendNextLayer` takes at `.cc:383` | no underflow / drained |
| `Recv.h2dIssueLeak` | `EndRecvOpLocked()` on the `done_ \|\| draining_` early return in `ExecuteLayerH2d` (`.cc:611`) | no op leak (`NoOpLeak`; `SettleSafe` holds vacuously because the leaked op prevents settling) |
| `Send.sendNextUnbounded` | `layer_idx >= d2h_layer_futures_.size()` check in `SendNextLayer` (`.cc:381`) | no op leak (`NoOpLeak`; `SendNextLayer(numLayers)` takes an op whose future never exists) |
| `Pipeline.dispatchEarly` | `h2dBegin l` after layer `l` landed | publication correctness (junk in HBM) |
| `Pipeline.h2dReadyByRank` | the H2D copy for layer `l` reads slot `l` (it reads the slot the *counter* points at instead — the shape of a counter-indexed model) | publication correctness: with layer 1 landing first, HBM ends `[kv 1, junk]` |
| `Pipeline.reseatAtFinish` | staging released at settle, not at `Finish` | publication correctness via the send's staging |
| `UuidTable.stepOverwriteDraining` | `EmplaceRecvSessionLocked` waits for `done()` rather than overwriting an expired (`draining = true, done = false`) incumbent | staging slot conservation (`freeSlots + activeStaging = numSlots`) |
| `BlockOrdering.trace_mutant_mismatched_transport_order` | `BuildLoadCopyPlan` sorts `h2dDst` by `dst_block_id` without permuting `transportBlocks` (`host_block_ids`) to match | within-layer block publication correctness (`BlockPublicationCorrect` fails on out-of-order `local_block_ids = [2, 0, 3, 1]`) |

## Test suite correspondence (C++ unit tests & `tpu-raiden` skill tests → Lean)

How the existing C++ unit tests (`tools/run_cc_tests.sh` / `tpu-raiden` Blaze
targets) and the `tpu-raiden-tpuvm-release-test` Python E2E tests
(`run_tests.sh`) correspond to the Lean trace theorems (`trace_*`) and general
safety theorems (`reachable_safe`, `reachable_can_settle`, `system_data_correct`,
`system_progress`):

### 1. Producer session tests (`TransferSendSession` → `Send.lean`)

| Test | File & lines | Lean trace theorem | General theorem |
|---|---|---|---|
| `DoneGuaranteesAllResourcesReleasedAndNoHbmOrTransportAccessAfterDone` | `transfer_send_session_test.cc:50-137` | `Send.trace_drain_h2h_and_d2h` | `Send.reachable_safe` (`SettleSafe`, `Drained`, `StagingIntegrity`) |
| `FailedLayerWaitsForTheOtherLayersCopies` | `kv_cache_manager_with_transfer_send_drain_test.cc:158-209` | `Send.trace_failed_d2h_waits_for_other_layer` | `Send.reachable_safe`, `Pipeline.PrefillHbmSafe` |
| `DeadlineMidD2hWaitsForInFlightCopy` | `kv_cache_manager_with_transfer_send_drain_test.cc:213-262` | `Send.trace_deadline_during_copy` | `Send.reachable_safe`, `Pipeline.PrefillHbmSafe` |
| `SendFailureIsReportedInFailedRecvingAndFreesTheSlot` | `kv_cache_manager_with_transfer_control_test.cc:295-333` | `Send.trace_push_fails` | `Send.reachable_safe`, `Send.reachable_can_settle` |
| `SuccessCannotOverrideAnEarlierFailure` | `kv_cache_manager_with_transfer_control_test.cc:335-380` | `Send.trace_ok_after_cancel_keeps_failure` | `Send.Inv.ok_draining`, `Send.Publication` |
| `FailureCannotOverrideAnEarlierSuccess` | `kv_cache_manager_with_transfer_control_test.cc:382-392` | `Send.trace_cancel_after_ok_finish` | `Lifecycle.finishOnceLocked_consistent` |
| `UnpulledSendAtOrBeforeItsDeadlineIsNotFailed` | `kv_cache_manager_with_transfer_control_test.cc:433-460` | `Send.trace_never_pulled` | `Send.Inv.published_done`, `Send.StagingIntegrity` |
| `ExpiredSendSessionFailsInsteadOfReportingDone` | `kv_cache_manager_with_transfer_pool_reshard_test.cc:338-347` | `Send.trace_never_pulled` | `Send.reachable_safe` (`SettlesPromptly`, `StagingIntegrity`) |

### 2. Consumer session & control tests (`TransferReceiveSession` → `Receive.lean`)

| Test | File & lines | Lean trace theorem | General theorem |
|---|---|---|---|
| `ExpiredReceiveKeepsStagingUntilHandshakeEnds` | `kv_cache_manager_with_transfer_control_test.cc:394-431` | `Recv.trace_deadline_during_handshake` | `Recv.reachable_safe` (`SettleSafe`, `StagingIntegrity`) |
| `ReceiveWithoutTrafficFailsAtItsDeadline` | `kv_cache_manager_with_transfer_control_test.cc:462-477` | `Recv.trace_deadline_during_handshake` | `Recv.SettlesPromptly`, `Recv.StagingIntegrity` |
| `UnregisteringIdleReceiverReleasesPlanAtOnce`, `DemandStagedReceiverPlanUnregistersWhenItSettles` | `kv_cache_manager_with_transfer_pool_reshard_test.cc:409-434, 538-561` | `Recv.trace_deadline_during_handshake` | `Recv.SettlesPromptly`, `Recv.StagingIntegrity` |
| `FailedLayerWaitsForOtherH2dCopies` | `kv_cache_manager_with_transfer_send_drain_test.cc:266-326` | `Recv.trace_failed_h2d_waits_for_other_layer` | `Recv.reachable_safe`, `Pipeline.DecodeHbmSafe` |
| `SingleFailedH2dReportsFailureAndReturnsStaging` | `kv_cache_manager_with_transfer_control_test.cc:479-501` | `Recv.trace_failed_h2d_waits_for_other_layer` | `Recv.reachable_safe`, `Recv.reachable_can_settle` |
| `IncomingPushLeasePinsStagingDuringWriteAndRejectsWhenDraining` | `kv_cache_manager_with_transfer_control_test.cc:503-529` | `Recv.trace_push_lease_pins_staging_on_cancel`, `Recv.trace_no_push_after_finish` | `Recv.StagingIntegrity`, `Pipeline.StagingSafe` |
| `FailedIncomingPushImmediatelyFailsSessionAndReleasesStagingBeforeDeadline` (added by `4efb0dd`) | `kv_cache_manager_with_transfer_send_drain_test.cc:854-882` | `Recv.trace_push_lease_pins_staging_on_cancel` (the `cancel`, `pushEnd`, `publish` steps: `end_incoming_push` now runs `Finish(status)` before `EndRecvOp`) | `Recv.StagingIntegrity`, `Recv.SettlesPromptly` |
| `UnregisteringInFlightReceiverDefersUntilItSettles` | `kv_cache_manager_with_transfer_pool_reshard_test.cc:436-476` | `Recv.trace_push_lease_pins_staging_on_cancel` | `Recv.StagingIntegrity`, `Pipeline.StagingSafe` |
| `IncomingPushLeaseSpansLayerH2dAndBlockAccountingBeforeReleasing` | `kv_cache_manager_with_transfer_control_test.cc:531-565` | `Recv.trace_push_lease_outlives_h2d` | `Recv.Accounted`, `Recv.SettleSafe` |
| `NetworkCompletionWaitsForH2d` | `kv_cache_manager_with_transfer_control_test.cc:567-598` | `Recv.trace_net_completion_waits_for_h2d` | `Recv.ReadinessSound`, `Recv.Publication` |
| `LateBlockAccountingAfterRetirementIsANoOp` | `kv_cache_manager_with_transfer_control_test.cc:600-628` | `Recv.trace_late_net_account_after_retire` | `Recv.step_done_mono`, `Recv.reachable_safe` |

### 3. Multi-peer fault isolation & staging-slot starvation tests (`ControlHandshakeTest` → `PeerIsolation.lean`)

| Test | File & lines | Lean trace theorem | General theorem |
|---|---|---|---|
| `ConsumerGivesUpOnProducerThatNeverAnswers` | `kv_cache_manager_with_transfer_control_test.cc:684-716` | `PeerIsolation.trace_consumer_gives_up_and_drains` | `PeerIsolation.reachable_inv` (`slots` conservation), `PeerIsolation.reachable_sessions_safe` |
| Issue #888 TCP blocking handshake pool | `kv_cache_manager_with_transfer_control_test.cc:841-846` | `PeerIsolation.trace_tcp_sick_peer_blocks_healthy` | `PeerIsolation.tcp_healthy_blocked_when_pool_full` |
| `GrpcSickPeerDoesNotDelayHandshakeToHealthyPeer` | `kv_cache_manager_with_transfer_control_test.cc:924-964` | `PeerIsolation.trace_grpc_sick_peer_does_not_delay_healthy` | `PeerIsolation.grpc_freeWorkers_eq_poolSize`, `PeerIsolation.grpc_healthy_can_complete` |
| `GrpcHealthyPeerProgressesWhileSickPeerBacklogDrains` | `kv_cache_manager_with_transfer_control_test.cc:971-1028` | `PeerIsolation.trace_grpc_healthy_progresses_under_backlog` | `PeerIsolation.grpc_freeWorkers_eq_poolSize`, `PeerIsolation.grpc_healthy_can_complete` |
| `DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer` | `kv_cache_manager_with_transfer_control_test.cc:1030-1089` | `PeerIsolation.trace_sick_peer_starves_staging_slots` (`unboundedPerPeer` counterexample), `PeerIsolation.trace_per_peer_quota_admits_healthy` (`perPeerQuota` fix) | `PeerIsolation.reachable_sick_staging_le_quota`, `PeerIsolation.reachable_quota_admits_healthy` |

### 4. Manager UUID registration table, drain-before-reuse & control handshake tests (`RecvDrainTest`, `SendLifecycleTest`, `ControlHandshakeTest` → `UuidTable.lean`, `Send.lean`, `Pipeline.lean`, `BlockOrdering.lean`)

| Test | File & lines | Lean trace theorem | General theorem |
|---|---|---|---|
| `DuplicateUuidIsRejectedUntilExpiredReceiveDrains` | `kv_cache_manager_with_transfer_send_drain_test.cc:633-682` | `UuidTable.trace_duplicate_uuid_rejected_until_drained` | `UuidTable.active_recv_preserved`, `UuidTable.reachable_inv` (`slots` conservation) |
| `DuplicateReceiveDoesNotReplaceOrLeakFirstRead` | `kv_cache_manager_with_transfer_control_test.cc:718-752` | `UuidTable.trace_duplicate_receive_different_req_id` | `UuidTable.active_recv_preserved`, `UuidTable.reachable_inv` |
| `RepeatedReceiveAnnouncementIsIdempotent` | `kv_cache_manager_with_transfer_control_test.cc:754-790` | `UuidTable.trace_repeated_receive_same_req_id_idempotent` | `UuidTable.active_recv_preserved`, `UuidTable.reachable_inv` |
| `DuplicateRegistrationCannotReplaceLiveOffer` | `kv_cache_manager_with_transfer_send_drain_test.cc:363-380` | `UuidTable.trace_duplicate_send_cannot_replace_live_offer` | `UuidTable.active_send_preserved`, `UuidTable.reachable_send_safe` |
| `RegisteredPullIsAcknowledged` | `kv_cache_manager_with_transfer_control_test.cc:353-365` | `Pipeline.trace_registered_and_duplicate_pull` | `Send.PullClaimed`, `Pipeline.HandshakeSafe` |
| `DuplicatePullIsRejectedBeforeAcknowledgement` | `kv_cache_manager_with_transfer_control_test.cc:367-379` | `Send.trace_duplicate_pull_rejected`, `Pipeline.trace_registered_and_duplicate_pull` | `Send.PullClaimed`, `Pipeline.HandshakeSafe` |
| `PullWithoutRegistrationIsRejected`, `PullAfterRegistrationDeadlineIsRejected` | `kv_cache_manager_with_transfer_control_test.cc:381-393` | `Pipeline.trace_unregistered_pull_rejected` | `Pipeline.HandshakeSafe`, `Pipeline.reachable_unregistered_safe` |
| `PullAheadOfRegistrationIsAcknowledgedOnceRegistered` | `kv_cache_manager_with_transfer_control_test.cc:395-413` | `Pipeline.trace_pull_ahead_of_registration` | `Pipeline.HandshakeSafe`, `Pipeline.reachable_unregistered_safe` |
| `ShutdownUnblocksPendingPull` | `kv_cache_manager_with_transfer_control_test.cc:415-441` | `Pipeline.trace_shutdown_unblocks_pending_pull` | `Pipeline.HandshakeSafe`, `Pipeline.reachable_unregistered_safe` |
| `DuplicateBlocksAreRejectedAtRegistration` | `kv_cache_manager_with_transfer_control_test.cc:341-351` | `BlockOrdering.trace_duplicate_registration_rejected` | `BlockOrdering.validateRegistration_iff`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`) |
| `UniqueRegisteredSubsetIsAcknowledged` | `kv_cache_manager_with_transfer_control_test.cc:443-457` | `BlockOrdering.trace_subset_pull_acknowledged` | `BlockOrdering.validateRequestedBlocks_iff`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`) |
| `PullOfUnregisteredBlockIsRejected` | `kv_cache_manager_with_transfer_control_test.cc:459-473` | `BlockOrdering.trace_unregistered_block_rejected` | `BlockOrdering.validateRequestedBlocks_iff`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`) |
| `PullWithDuplicateSourceBlockIsRejected` | `kv_cache_manager_with_transfer_control_test.cc:475-489` | `BlockOrdering.trace_duplicate_source_block_rejected` | `BlockOrdering.validateRequestedBlocks_iff`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`) |
| `EmptyPullIsRejected` | `kv_cache_manager_with_transfer_control_test.cc:491-503` | `BlockOrdering.trace_empty_pull_rejected` | `BlockOrdering.validateRequestedBlocks_iff`, `BlockOrdering.BlockPipeline.reachable_safe` (`BlockValidationSafe`) |
| `LocalOrchestratedTransfer` | `kv_cache_manager_with_transfer_control_test.cc:505-558` | `BlockOrdering.trace_local_orchestrated_transfer` | `BlockOrdering.BlockPipeline.reachable_safe` (`BlockPublicationCorrect`) |
| `LocalOrchestratedTransferToCustomHostBlock` | `kv_cache_manager_with_transfer_control_test.cc:560-619` | `BlockOrdering.trace_custom_host_block_transfer` | `BlockOrdering.BlockPipeline.reachable_safe` (`CustomHostStagingCorrect`) |

### 5. End-to-end prefill-to-decode transfer tests (`tpu-raiden` & `tpu-raiden-tpuvm-release-test` skills → `Pipeline.lean`, `BlockOrdering.lean`, `MultiRequest.lean`, `ReceivePoll.lean`)

| Test | File & lines | Lean theorem | Notes |
|---|---|---|---|
| `SingleDeviceTransfer`, `MultiDeviceTransfer` | `kv_cache_manager_with_transfer_test.cc:135-380` | `Pipeline.trace_normal`, `Recv.noPoll_metrics_on_success` | E2E D2H → H2H → H2D transfer, `poll_stats()` publication, and duration metric observation (`ReceivePoll.lean` also proves `Recv.trace_poll_skips_metrics` when `pollReady` wins the pre-callback window) |
| `test_e2e_transfer_polling`, `test_parallel_pull` | `tpu_sync/api/{jax,torch}/kv_cache_manager_transfer_test.py` | `Pipeline.trace_normal`, `Pipeline.trace_layers_out_of_order`, `Pipeline.reachable_safe` | 2-layer E2E producer (`register_read`) → consumer (`start_read`) → `poll_stats()` verification that `dst_caches` match `src_refs` across all layers |
| Single-host disaggregated serving E2E (`examples/single_host_disagg/run_all.sh`) | `tpu-raiden-tpuvm-release-test` Step 4b | `Pipeline.trace_multi_request`, `Pipeline.trace_overlapped_requests`, `Pipeline.system_data_correct`, `Pipeline.system_progress` | Multi-request prefill-to-decode serving stream recycling HBM and host staging buffers across prompts |
| `test_non_contiguous_blocks`, `test_host_reordering`, `test_large_complex_non_contiguous_and_reorder` | `tpu_sync/api/{jax,torch}/kv_cache_manager_transfer_test.py` | `BlockOrdering.trace_non_contiguous_blocks`, `BlockOrdering.trace_host_reordering`, `BlockOrdering.trace_large_complex_non_contiguous_and_reorder`, `BlockOrdering.BlockPipeline.reachable_safe`, `BlockOrdering.execCoalesced_buildCoalescedSpec` | Full within-layer block-index gather, dual-permutation `BuildLoadCopyPlan`, and contiguous-run DMA coalescing across arbitrary non-contiguous `remote_block_ids` and out-of-order `local_block_ids` (discharging `Pipeline` A1) |

## Outcome at `50b0774`

No bugs in the transfer path. All proposal properties are proved under the
cited assumptions. Observations (not bugs) worth passing on:

| Observation | Where | Note |
|---|---|---|
| `SendAck` / `HandleAck → AckSend → Finish()` has no non-test caller | `mgr.cc:1551-1554`, `1617-1628` | dead path; excluded (Send A5) |
| a failed **send** is reported in `failed_recving_` | `mgr.cc:927` | naming/semantics quirk visible through `poll_stats()` |
| first `Finish` wins on the send side; a later cancel is ignored | `send.cc:167-176` | intended; `trace_cancel_after_ok_finish` |
| `IsReadyToComplete` can be true before all H2D callbacks ran | `recv.cc:430-436` | `done` still waits for every callback through `in_flight_` (`pollReady_no_settle`), so the outcome and its timing are unchanged. But when the poll wins that window the last callback finds `draining_` and skips `RecordTransferDuration`/`RecordH2dComplete`/`RecordEnd` (`recv.cc:663-669, 683-693`) — the transfer's metrics record keeps default times (`trace_poll_skips_metrics`). With `num_layers() > 0` the `num_completed_layers_ == total_layers` disjunct and the `if (all_complete)` finish in `OnBlocksReceived` are dead (`reachable_callbackFinishes`, `netAccount_frame`); only a zero-layer receive needs the poll (`noPoll_zero_layers_never_succeeds`). Removing the poll keeps every proved property and settlement (`noPoll_safe`, `noPoll_can_settle`) and makes `published = some true → metrics` an invariant (`noPoll_metrics_on_success`). `ReceivePoll.lean` |
| `EndSendOpLocked` has no underflow guard, `EndRecvOpLocked` does | `send.cc:189-196` vs `recv.cc:387-390` | underflow proved unreachable (`NoUnderflow`) |
| `LOG(DFATAL) "H2D callback for retired receive"` is unreachable | `recv.cc:655-657` | proved (`NoRetiredCallback`) |
| `done_` is redundant in six lifecycle guards | `recv.cc:368, 392, 541, 586, 612`, `recv.h:117` (same on the send side: `send.cc:168, 191`) | `done → draining` and `done → in_flight_ == 0` are `Lifecycle.Consistent`, which every model keeps in its invariant (`Inv.life`); the guards without `done_` are the same functions on consistent states (`finishLocked'_eq`, `endOpLocked'_eq`, `beginOp'_eq`, `Consistent.done_or_draining`). Defensive code, not a bug. The two `LOG(DFATAL)` branches (`recv.cc:387-390`, `655-657`) are assertions — unreachable by `Accounted` / `NoRetiredCallback` — and stay. `Session.lean` |
| a failed incoming push reaches the session as a flat `InternalError("Incoming push failed")` | `bt.cc:376-381` → `mgr.cc:239-242` (`4efb0dd`) | the actual cause (read timeout, size mismatch, `OnLayerReceived` error) is only in the transport log, so `failed_recving` cannot tell them apart. Observability, not correctness; the model does not distinguish error statuses. |

## Upstream re-checks

| Date | From → to | What changed in the cited code | What was done |
|---|---|---|---|
| 2026-10-06 | `01ffa3d` → `50b0774` (44 upstream commits; merge `77eeec8` on `experimental`) | **One behavioural change.** `4efb0dd`: a failed incoming push now runs `DeferUnregisterOnSettle(); Finish(status)` before `EndRecvOp()` (`mgr.cc:239-242`, `bt.cc:376-381`) instead of leaving the session to its deadline — already a trace of the model (`cancel` then `pushEnd`), now with its own C++ test (above). **Additive only:** `completed_at_` set beside every `done_ = true` (`a58a357`); `CompleteReadRaw` became a wrapper over `CompleteReadWithDetails`, poll loop unchanged (`mgr.cc:962-994`); per-read socket timeouts in `HandleIncomingPush`, env-gated and off by default (`e7c933f`, `61b6c76`); `AsyncPush` returns a `tsl::Future` (`50fa652`, `4e9f0a5`, `c4ca33c`). **Unchanged:** A4's ordering (`bt.cc:559-561`, `:601-615`), `StartRead` admission, `IsReadyToComplete` and `AllH2dDoneLocked`, `raiden_controller.cc` (byte-identical), every cited test. No finding fixed; `DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer` still disabled. | All `file:line` citations in the Lean modules and this file re-pinned with `tools/repin_citations.py` (354 rewritten mechanically, 2 that spanned a hunk by hand, 8 spot-checked against the tree); `Receive.lean` `pushEnd` row and `trace_push_lease_pins_staging_on_cancel` docstring extended; `BlockOrdering.lean` and `PipelineChecks.lean` given the commit statement they lacked; two wrong citations in Stage 4 above corrected (`ValidateRequestedBlocks` pointed into `BuildCoalescedCopySpec`; `copy_spec_builder.h` does not exist in tpu-sync). `lake build` clean, no warnings. |

Procedure for the next sync: `README.md` §"Maintenance after an upstream sync".

## Future work

Ranked by expected value. The encoding is complete for the proposal's scope;
what remains is where it deliberately stops.

| # | Work | Why | Cost |
|---|---|---|---|
| F1 | *(Done)* **Progress / no-leak property.** `NoOpLeak` (`0 < inFlight →` some event in `drainEvents` is enabled) and `reachable_can_settle` (every reachable state can drain to `done = true ∧ hasStaging = false`) proved for both `Recv` and `Send`, with leak mutants `Recv.h2dIssueLeak` and `Send.sendNextUnbounded`. | Closes the vacuity gap of `SettleSafe` when an op is leaked so the session never settles. | done |
| F2 | **Model validation: Lean traces → C++ scenario tests.** `trace_finish_between_locks`, `trace_poll_before_callbacks`, `trace_cancel_after_ok_finish`, `trace_slow_consumer`, `trace_layers_out_of_order`; `trace_reseat_at_finish` as a fault-injected negative test, using the fault-injection hooks already in `transfer_*_session.cc`. In the other direction, recorded executions replay without relabelling layers, since every pipeline event names its layer. | The correspondence tables are trusted, not checked. Executable scenarios make them checkable and the work legible to tpu-sync owners. Proposal §3.3. | medium |
| F3 | **Maintenance.** `lake build` in CI on the fork; a citation-check script that stores the cited snippet next to each `file:line` and fails when it drifts. | Citations rot with every upstream commit. | low |
| F4 | **Discharge Receive A1/A3/A4 by modelling the transport.** Add `block_transport.cc`: per-block accounting, `on_layer_received_called`, several senders per layer. Then `OnLayerReceived`-before-`OnBlocksReceived` and readiness soundness are proved rather than assumed. | A4 is the one assumption whose failure would be a real bug. Multi-sender is where the threshold arithmetic `num_completed_blocks_ / total_blocks_` is subtle and currently unexercised. | medium–high; worth it if multi-sender transfers are used in production |
| F5 | Completeness: `Pipeline` on the push-plan path (`Recv.initPush` + `StartPush` via `HandlePullStream`); a mixed-outcome push (layer landed, callback failed — see Pipeline A2); the mutant table above kept in sync automatically. | rounds things out; low discovery potential | low |

Explicitly not planned: staging-pool contention (`AcquireStagingWithRetry`) — a
liveness/resource question needing a scheduler model, unlikely to pay off.
