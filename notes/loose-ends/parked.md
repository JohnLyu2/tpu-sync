# Parked investigations and loose ends

Open items only (5-field `better-than-fish` format, symbol citations instead of raw line spans). Delete an entry when it is `done`, `closed`, or `retired` (record lasting outcomes in `journal/YYYY-MM/`, `upstream-rechecks.md`, or the deliverable).

## Audit `KVCacheStoreClient::Fetch` missing RPC deadline and `LoadRemoteBlocks` staging free on transport error
**Status:** parked 2026-10-05 (`Read at: 01ffa3d`)
**Context:** `KVCacheStoreClient::Fetch` (`tpu_sync/kv_cache/kv_cache_store_client.cc`) sets no gRPC deadline on `grpc::ClientContext`, unlike `WriteRemote` (`hold_window`) and `PollWriteRemote` (`kRpcDeadline`). In `HostOffloadBackend::LoadRemoteBlocks` (`tpu_sync/kv_cache/host_offload_backend.cc`), if `Fetch` fails or reports `failed_block_hashes`, `dst_host_block_ids` are immediately freed via `raiden_controller_->DeallocateBlockIds(dst_host_block_ids)`.
**Why parked:** Unverified follow-up from the `01ffa3d` concurrency bug-hunt after confirming F1–F4.
**To resume:** Inspect `RaidenController::TransferBuffers` (`tpu_sync/core/controller/raiden_controller.cc`), `KVCacheStoreServiceImpl::Fetch` (`tpu_sync/kv_cache/kv_cache_store_service.cc`, `transfer_future.Await()`), and `WorkerServiceImpl::TransferBuffers` (`tpu_sync/core/controller/worker_service_impl.cc`) to check whether a failed `Fetch` RPC or `TransferBuffers` call can return while a peer worker still writes into `dst_host_block_ids`, or whether `tsl::JoinFutures` + `transfer_future.Await()` drains all dispatched workers first.
**Effort estimate:** ~45 min.
**References:** ../durable/controller-read-remote-and-kv-store-pinning-concurrency-traps.md, findings/README.md

## Translate Lean witness traces into C++ scenario tests in `kv_cache_manager_with_transfer_send_drain_test.cc`
**Status:** parked 2026-10-05
**Context:** `Transfer/PrefillDecode/Receive.lean` (`Recv.trace_finish_between_locks`, `Recv.trace_poll_before_callbacks`), `ReceivePoll.lean` (`Recv.trace_poll_skips_metrics`), and `PipelineChecks.lean` (`Pipeline.trace_slow_consumer`, `Pipeline.trace_layers_out_of_order`, `Pipeline.trace_reseat_at_finish`) witness lock windows and callback orderings in `TransferReceiveSession` and `KVCacheManagerWithTransfer` not yet covered by dedicated scenario tests (see also the coverage-gap test PR entry below).
**Why parked:** Lean proofs and trace witnesses landed first; C++ harness wiring deferred.
**To resume:** Add deterministic mock-PJRT callback / ordering tests to `tpu_sync/kv_cache/transfer_send_session_test.cc` and `tpu_sync/kv_cache/kv_cache_manager_with_transfer_send_drain_test.cc` paired against the Lean `decide` traces.
**Effort estimate:** ~2 h.
**References:** ../durable/prefill-decode-transfer-settle-and-layer-readiness-invariants.md, tpu_sync/formal_verification/docs/transfer/prefill_decode.md

## Transport model follow-ups: plan-declared contract, `expected_senders` resolution race, in-tree hardening
**Status:** parked 2026-10-20 (`Read at: 0ac16d1`)
**Context:** `Transfer/PrefillDecode/Transport.lean` covers the chunk-count and sender-declared contracts of `CompleteIncomingPush` (`tpu_sync/transport/block_transport_session.cc`, formerly `block_transport.cc`). Not covered: (a) the plan-declared reshard contract (`AccumulateLandedShards`, `expected_pushes`, retirement by `expected_pools`); (b) the plan-publication window where `KVCacheManagerWithTransfer::RegisterActivePlan` seats the receive session under `mu_` before publishing the plan while `CompleteIncomingPush` latches `ExpectedPushSenders` on a layer's first stream (`Transport` A2); (c) whether the sender-declared contract comparing distinct `header.remote_id = node_id()` against `shard_push_schedules_size()` (`KVCacheManagerBase`, `rpc/raiden_service.proto`) can stall if one node owns two source shard partitions (`Transport` A3; decided by schedule construction in `rpc/raiden_controller.py`); (d) the two hardening edits in `Transport.stepHardened` (chunk-count over-count rejection; per-layer once-latch in `ExecuteLayerH2d`), which exist only in Lean.
**Why parked:** `findings/README.md` §R-B is an API hazard unreachable from in-repo callers; (b) and (c) depend on Python controller sequencing outside the Lean corpus.
**To resume:** (1) Read `raiden_controller.py` schedule construction + `node_id()` assignment to settle (c); (2) check controller ordering between receiver `RegisterActivePlan` reply and sender start for (b); (3) add a `planDeclared` arm to `completePush` if modelling reshard transport; (4) offer `stepHardened` as a C++ patch + `block_transport_test.cc` case if owners want API hardening.
**Effort estimate:** (1) ~1 h; (2) ~1 h; (3) ~half-day; (4) ~1 h + OSS Bazel run.
**References:** ../journal/2026-10/2026-10-20-transport-stream-accounting-model.md, tpu_sync/formal_verification/docs/transfer/prefill_decode.md §Boundary assumptions, findings/README.md §R-B

## Propagate the real push-failure status through `EndIncomingPush`
**Status:** parked 2026-10-06 (`Read at: 50b0774`)
**Context:** Incoming push cleanup (`BlockTransportServerPushSession::StartStream`, formerly `BlockTransport::HandleIncomingPush`) reports every early return to the receive session as generic `InternalError("Incoming push failed")` via `end_incoming_push`, hiding the underlying read timeout, size mismatch, or `OnLayerReceived` error in `failed_recving`. Observability only; the Lean model does not distinguish error codes.
**Why parked:** No correctness impact.
**To resume:** Capture the failing step's `absl::Status` before returning, pass it to `EndIncomingPush(uuid, status)`, and assert the propagated status code (`DeadlineExceeded`) in `RecvLifecycleTest.FailedIncomingPushImmediatelyFailsSessionAndReleasesStagingBeforeDeadline`.
**Effort estimate:** ~30 min.
**References:** ../journal/2026-10/2026-10-06-upstream-50b0774-merge-and-citation-repin.md

## Citation drift check in CI (`.github/workflows/verification.yml`)
**Status:** parked 2026-10-06 (`resolve_anchors.py --check` done 2026-10-23; CI workflow remaining)
**Context:** `tpu_sync/formal_verification/tools/resolve_anchors.py --check` and `lake build` verify all source-map spans and proofs mechanically, but no `.github/workflows/verification.yml` runs them in CI yet.
**Why parked:** Planned to land upstream in the final upstream-landing step so the fork inherits it via sync rather than carrying a fork-only workflow.
**To resume:** Add `.github/workflows/verification.yml` (`elan` → `lake build` → `python3 tools/resolve_anchors.py --check`) upstream once the remaining corpus CLs land (or in the fork if upstream landing stalls).
**Effort estimate:** ~30 min.
**References:** ../journal/2026-10/2026-10-22-upstream-2ed6f8f-sync-and-repin-tool-defect.md, tpu_sync/formal_verification/docs/conventions.md §"Citing the C++"

## Per-peer staging admission follow-ups: wait-at-cap, self-sizing share, constructor/Python knob
**Status:** parked 2026-10-07 (`Read at: 50b0774`; patch retired 2026-10-16 after `fc8cff9` moved `StagingBlockAllocator` to `tpu_sync/core/staging_arena.{h,cc}`, last at tag `upstream-main-2026-10-10`)
**Context:** `PeerIsolation.reachable_quota_admits_healthy` proves the fixed per-peer cap (`TPU_RAIDEN_MAX_STAGED_READS_PER_PEER`). Deferred variants pending owner feedback on F5: (a) waiting at the cap instead of refusing (`StagingBlockAllocator::AcquireWithTimeout` per-peer wait queue + liveness proof); (b) self-sizing share `cap = f(active peers)`; (c) plumbing the cap through `KVCacheManagerWithTransfer` constructors and Python bindings.
**Why parked:** Waiting on owner decision (refuse vs wait, env knob vs constructor parameter).
**To resume:** Re-base the F5 patch onto `staging_arena.{h,cc}`, extend `PeerIsolation.lean` and `SickPeerStarvesStagingSlotsForHealthyPeer` for the chosen variant, and validate via `../empirical/oss-bazel-test-recipe.md`.
**Effort estimate:** (c) ~1 h; (b) ~half-day; (a) ~1 day.
**References:** ../journal/2026-10/2026-10-07-f5-per-peer-staging-admission-fix.md, ../durable/prefill-decode-transfer-settle-and-layer-readiness-invariants.md, findings/README.md §F5

## Missing C++ test: a send blocked in `AcquireStagingWithRetry` woken by a freed slot (and `deadline_` expiry)
**Status:** parked 2026-10-09 (`Read at: 50b0774`)
**Context:** `TransferSendSession::AcquireStagingWithRetry` (`tpu_sync/kv_cache/transfer_send_session.cc`) polls `StagingBlockAllocator::AcquireWithTimeout` (`tpu_sync/core/staging_arena.cc`) in 1 ms slices with three exits: slot freed, own `Finish`, or `deadline_` expiry. Only the `Finish` exit is tested (`CancelledWhileWaitingForStagingExitsWithoutShuttingDownAllocator` in `transfer_send_session_test.cc`). `Send.lean` abstracts this wait into instant `.start` / `.cancel`.
**Why parked:** Upstream test gap only; wait-at-cap in F5 variant (a) would subsume any Lean wait state.
**To resume:** Add two tests to `transfer_send_session_test.cc` (live send blocked on 1-slot pool woken when dummy session releases; past `deadline_` returning `DeadlineExceeded` with no staging held) and run via `../empirical/oss-bazel-test-recipe.md`.
**Effort estimate:** ~1 h.
**References:** ../journal/2026-10/2026-10-09-lean-helper-audit-and-timing.md, tpu_sync/formal_verification/docs/transfer/prefill_decode.md §Boundary assumptions

## Refine `Receive.lean` block accounting to per-shard counters
**Status:** parked 2026-10-10 (`Read at: 1fa06d1`)
**Context:** `TransferReceiveSession::OnBlockShardsReceived` counts received blocks per shard (`blocks_received_per_shard_`, `num_completed_shards_`) and sets `network_completed_` when every shard reaches `total_blocks_ * num_layers`. `Receive.lean` keeps one `netAccount` per layer (`layersAccounted < issued`) backed by prose soundness argument A4.
**Why parked:** No proved property depends on shard count; refining `Recv` state would touch every theorem and trace for no new safety guarantee.
**To resume:** Only if a shard-specific bug or feature motivates it: parameterize `Recv` by `numShards` and `shardBlocks`, define `networkCompleted` across all shards, and discharge `networkCompleted → issued = numLayers` from per-stream ordering.
**Effort estimate:** ~half-day.
**References:** ../journal/2026-10/2026-10-10-upstream-1fa06d1-sync.md, tpu_sync/formal_verification/TpuSyncVerify/Transfer/PrefillDecode/Receive.lean

## Peregrine `BlockTransport` backend: re-check per-uuid failure latch if `kBlockPush` is enabled
**Status:** parked 2026-10-20 (`Read at: 42dda54`; dormant trigger — re-open only if `PeregrineTransportAdapter::Post` adds `TransferOp::kBlockPush` support)
**Context:** F10 (`ReshardSendSession::RecordPushCompletion` unregistering the plan on the first failed push while sibling pushes remain in flight) is prevented from sending wrong fallback extents on the socket path by `SocketTransportAdapter::PostSocketPush`'s `session_failed_by_uuid_` latch (`tpu_sync/transport/lib/adapter/socket_transport_adapter.cc`). `PeregrineTransportAdapter::Post` (`peregrine_transport_adapter.cc`) carries no per-uuid failure latch, but currently refuses receiver-allocated `TransferOp::kBlockPush` (what `ReshardSendSession` issues) with `UnimplementedError` and only handles `kBlockPushExplicit`.
**Why parked:** Unreachable until `PeregrineTransportAdapter::Post` supports `kBlockPush`.
**To resume:** If an upstream sync modifies `PeregrineTransportAdapter::Post` to accept `kBlockPush` while F10 is still open, check whether sibling posts of a failed uuid are cancelled before fallback extent resolution; if not, extend F10 with a wrong-bytes consequence and test.
**Effort estimate:** ~1 h reading; ~half-day if a transport test is needed.
**References:** findings/README.md §F10, §Callers

## Build with `-Wthread-safety` as an error over `tpu_sync/`, then annotate `RemoteReadState` and the controller
**Status:** parked 2026-10-26 (`Read at: c9bc124`)
**Context:** Session and arena headers carry ~80 `ABSL_GUARDED_BY` / `LOCKS_REQUIRED` annotations, but no OSS build flag enables `-Wthread-safety`. `RaidenController` (`raiden_controller.{h,cc}`) leaves `RemoteReadState::lease_id` unannotated directly above `settled ABSL_GUARDED_BY(mu)` (F3).
**Why parked:** Lock-scope audits came first; OSS Bazel is now working locally (`../empirical/oss-bazel-test-recipe.md`).
**To resume:** Run `bazel build --config=oss ... --per_file_copt='tpu_sync/.*@-Wthread-safety,-Werror=thread-safety-analysis' //tpu_sync/...`, triage warnings as annotation fixes vs findings, and annotate `RemoteReadState` + `raiden_controller.{h,cc}`.
**Effort estimate:** 1–4 h triage + 2–4 h controller annotations.
**References:** ../journal/2026-10/2026-10-26-faithfulness-feedback-and-receive-lock-scope-audit.md, findings/README.md §F3

## TSan run of the controller and receive/send test targets (F3 → CONFIRMED (test))
**Status:** parked 2026-10-26 (`Read at: c9bc124`)
**Context:** F3 (`RemoteReadState::lease_id` data race) is CONFIRMED (read) only; `ReadRemoteSettlesDeadlineWhilePullStillInFlight` (`findings/raiden_controller_bughunt_test.cc`, `findings/build_targets.patch`) provokes the deadline-vs-callback race if built under TSan.
**Why parked:** Uninstrumented third-party runtime noise under `--copt=-fsanitize=thread` is unknown until tried.
**To resume:** Run `raiden_controller_bughunt_test` and `kv_cache_manager_with_transfer_send_drain_test` with `-fsanitize=thread` via OSS Bazel; bound the attempt at half a day (record noise if suppressions balloon, otherwise paste the TSan report into `findings/README.md` §F3).
**Effort estimate:** ½ day (bounded).
**References:** findings/README.md §F2, §F3, ../journal/2026-10/2026-10-26-faithfulness-feedback-and-receive-lock-scope-audit.md

## Trace replay: run C++ event logs through the Lean `step` (`ReadRemote` first, then `Receive`, `Send`)
**Status:** parked 2026-10-26 (`Read at: c9bc124`)
**Context:** Nothing mechanically checks C++ runtime event logs against `step`. Probes must emit inside each event's `mu_` scope (or carry a lock-assigned sequence number), mapped via each module's `## Lock scopes` table. `RAIDEN_LEASE_TRACE` in `raiden_controller.cc` is an in-tree precedent for `ReadRemote` (needs `shutdown` probe + moving `DEADLINE` inside `mu`).
**Why parked:** Session probes require production-code hooks upstream (fork is additive-only); `ReadRemote` can be prototyped locally first.
**To resume:** (1) Run `ReadRemote` reproducers with `RAIDEN_LEASE_TRACE`, convert logs to Lean `#guard ((sys …).run trace).isSome` checks; (2) propose an env-gated `TPU_SYNC_TRACE` macro upstream for `Receive` and `Send` at the `## Lock scopes` points and replay `send_drain_test.cc` / `transfer_send_session_test.cc`.
**Effort estimate:** `ReadRemote` ~1 day; `Receive` ~3 days; `Send` +1–2 days.
**References:** tpu_sync/formal_verification/TpuSyncVerify/Transfer/PrefillDecode/Receive.lean §Lock scopes, ../journal/2026-10/2026-10-26-faithfulness-feedback-and-receive-lock-scope-audit.md

## Coverage stopping criterion (W1–W4 remaining): Reshard W1, `Pipeline`/`ReadRemote` W2, `llvm-cov` W3, schedule-runner W4
**Status:** parked 2026-10-27 (PrefillDecode + `ReadRemote` W1 and `Receive`/`Send` W2 done; `Common/Coverage.lean` in place)
**Context:** Spec/implementation coverage plan from McMillan & Zuck's QUIC work (`docs/conventions.md` §"Coverage"). Remaining stages: (W1) branch-coverage modules for `Transfer/Reshard/{Receive,Send,Pipeline,Registry,Coordinator}`; (W2) guard × mutant inventories for `Pipeline` and `ReadRemote`; (W3) `llvm-cov export` intersected with `resolve_anchors.py` source-map spans to list unexecuted C++ branches inside modelled code; (W4) `TEST_P` C++ schedule interpreter over `RecvTestManager` running Lean-enumerated schedules and checking post-states (`Done()`, `IsDraining()`, `num_free_slots`, `copies_issued`, published status).
**Why parked:** Prioritized landing the PrefillDecode/Controller coverage modules and upstream gap-test PR first.
**To resume:** Pick independently: Reshard W1 (~½ day/model), `Pipeline`/`ReadRemote` W2 (~½ day), W3 `llvm-cov` + `resolve_anchors.py --coverage` (~1 day via OSS Bazel), or W4 `Receive` `TEST_P` runner (~3 days).
**Effort estimate:** As above per stage.
**References:** ../journal/2026-10/2026-10-27-coverage-stopping-criterion-receive-pilot.md, tpu_sync/formal_verification/docs/conventions.md §"Coverage"

## Upstream coverage-gap test PR + remaining handshake-stub and recycle tests
**Status:** parked 2026-10-28 (`findings/coverage_gap_tests.patch` green 9/9 at `42dda542`, ready to file)
**Context:** Nine hardware-free gtest cases closing `Receive/Coverage.lean`, `Send/Coverage.lean`, and `Controller/ReadRemoteCoverage.lean` test gaps are validated (`--runs_per_test=10`) in `findings/coverage_gap_tests.patch` (`findings/README.md` §Coverage-gap tests). Also surfaced: receiver late-`Finish` flip (`TransferReceiveSession::FinishLocked` lacks a `if (done_) return;` guard, unlike sender) and three unwritten test gaps needing new seams (2 consumer handshake tests needing a replying producer stub; 1 multi-request staging-recycle test needing a staging-observing seam).
**Why parked:** Waiting on user filing of the 9-test PR and the late-`Finish` GitHub issue.
**To resume:** (1) Cut a clean branch from `42dda542`, apply `findings/coverage_gap_tests.patch`, and open the test-only PR; (2) file the late-`Finish` flip issue with the `if (done_) return;` fix; (3) once merged, flip those rows to `paired` in `Receive/Coverage.lean`, `Send/Coverage.lean`, and `ReadRemoteCoverage.lean`; (4) optionally build the replying-producer stub (2 cases) and multi-request recycle case (1 case).
**Effort estimate:** Filing ~30 min; stub + recycle tests ~3 h.
**References:** findings/README.md §Coverage-gap tests, ../journal/2026-10/2026-10-27-coverage-stopping-criterion-receive-pilot.md

## `RecordNetworkCompleteLocked`'s `FinishLocked()` arm is dead; reply-after-data flips a complete receive to failed
**Status:** parked 2026-10-27 (`Read at: c9bc124`; two low-severity observations, neither filed)
**Context:** (a) `TransferReceiveSession::RecordNetworkCompleteLocked`'s `all_complete` → `FinishLocked()` arm cannot execute for `num_shards() ≥ 1` because `num_completed_layers_` only increments in the H2D callback (which calls `FinishLocked()` on the last layer unless `draining_`, after which `OnBlockShardsReceived` returns early). (b) `HandlePullStream` spawns `StartPush` before returning the pull response, so all layers can land before `on_response` runs; a transport error on that reply then flips `status_` on a completed receive (`Receive/Coverage.lean` `pullReplyFail`).
**Why parked:** (a) is dead-code cleanup; (b) is a narrow design wart (only promote to a finding if `"control pull request: ..."` is ever observed on a receive whose layers all landed).
**To resume:** Mention alongside any `transfer_receive_session.cc` touch: turn (a) into a `DCHECK` or remove it, and have `on_response` ignore non-OK once `done_` / all layers completed.
**Effort estimate:** ~30 min each.
**References:** tpu_sync/formal_verification/TpuSyncVerify/Transfer/PrefillDecode/Receive/Coverage.lean, ../journal/2026-10/2026-10-27-coverage-stopping-criterion-receive-pilot.md

## Optionally add a `NumaAwareKVCacheManager` sub-manager barrier model under `Transfer/Caller/`
**Status:** parked 2026-10-29 (`Read at: 42dda542`)
**Context:** F11 (`NumaAwareKVCacheManager::CompleteReadRaw` eager `failed_recving` mid-DMA under `ENABLE_MULTI_NUMA=1` + `failed_recving_set_` / barrier-count leak on every failed/expired transfer) is confirmed by `findings/numa_kv_cache_manager_bughunt_test.cc`, recorded in `findings/README.md` §F11, and filed as bug 10 in `findings/filed_bugs.md`.
**Why parked:** Lean modelling of `NumaAwareKVCacheManager` deferred after confirming and filing F11.
**To resume:** Optionally add a small sub-manager barrier model under `TpuSyncVerify/Transfer/Caller/` proving `earlyFree = false` and cross-transfer state reset for the settled-count (`ok + fail`) fix.
**Effort estimate:** ~2 h.
**References:** findings/README.md §F11, findings/filed_bugs.md, ../empirical/prefill-decode-caller-tpu-inference-raiden-connector.md


## Triage and write up the four unfiled bug-hunt reproducers from the 2026-10-29 post-F11 audit
**Status:** parked 2026-10-29 (`Read at: 42dda542`; all four built and run on unmodified `42dda542`, files committed under `findings/` without `README.md` entries or `build_targets.patch` targets)
**Context:** After F11, four parked/unmodelled areas were audited by reading and the candidates confirmed or refuted by test: (1) `KVCacheStore::active_remote_writes_` is never erased on async `HostOffloadBackend::BeginWriteRemote` settlement (`~KVCacheStore` then double-`Release`s live pins) and a remote `CANCELLED` after the ack drops the pin release and the save verdict — `findings/kv_cache_store_remote_write_bughunt_test.cc` (3 failing + 1 control); (2) `KVCacheStoreClient::Fetch` sets no RPC deadline and `HostOffloadBackend::LoadRemoteBlocks` frees `dst_host_block_ids` on a transport error while the receiver still accepts planless op-6 / uuid-0 pushes into them — `findings/kv_cache_store_fetch_bughunt_test.cc` (4 failing; closes the older "`Fetch` missing RPC deadline" parked item above); (3) `KVCacheManagerBase::host_block_manager_` (`LogicalBlockManager`, documented as externally synchronized) is mutated without a lock by concurrent auto-allocating inbound pushes, `H2hRead` and `AllocateBlocks` — `findings/host_block_manager_race_bughunt_test.cc` (duplicate block ids; 1 failing + 1 control; no in-tree production caller of the auto-allocating `H2hWrite` / `H2hRead` found); (4) `WriteRemoteServerReactor::StartAck` vs `OnCancel` is **refuted** (gRPC 1.81.0 defers `OnCancel` until after `SetupReactor`; `Finish` during a pending `StartWrite` is legal) — `findings/kv_cache_store_service_reactor_bughunt_test.cc` (2 passing). User decision 2026-10-29: filing is scoped to the transfer path first; (1)–(3) are store-path and deferred.
**Why parked:** Transfer-path findings (F12, F13) were written up and filed first; the store-path write-ups need the same README/filed-bugs treatment and a decision on whether to file (1) and (2) given the `vllm-torchtpu` / `sglang-torchtpu` callers do not use `KVCacheStore`.
**To resume:** For each of (1)–(3): add a `## Fn.` entry to `findings/README.md` with the verbatim output, a Summary row, and a `build_targets.patch` target; fold (4) into §Refuted; then draft reports in the house style (Cause / Impact / one-line confirmation). Delete the superseded "`Fetch` missing RPC deadline" entry above when (2) is written up.
**Effort estimate:** ~1 h per finding for README + patch; ~30 min per report.
**References:** findings/README.md §History (2026-10-29, later), ../durable/controller-read-remote-and-kv-store-pinning-concurrency-traps.md
