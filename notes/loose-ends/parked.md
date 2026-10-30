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

## Transport model follow-ups: plan-declared reshard contract and in-tree `stepHardened` hardening
**Status:** parked 2026-10-20 (`Read at: 42dda542`; `Transport` A2 & A3 controller/caller boundary checks closed 2026-10-30 in `Transport.lean` §Assumptions and `findings/README.md` §R-B)
**Context:** `Transfer/PrefillDecode/Transport.lean` covers the chunk-count and sender-declared contracts of `CompleteIncomingPush` (`tpu_sync/transport/block_transport_session.cc`). Still open: (a) modelling the plan-declared reshard contract (`AccumulateLandedShards`, `expected_pushes`, retirement by `expected_pools`); (b) offering the two Lean-only hardening edits in `Transport.stepHardened` (chunk-count over-count rejection; per-layer once-latch in `ExecuteLayerH2d`) as C++ hardening.
**Why parked:** `findings/README.md` §R-B (`sender_streams` contract) is entered only on non-pool receiver `RegisterActivePlan` plans (`pool_groups_size() == 0` with `shard_push_schedules_size() > 0`), and every in-repo controller hop that populates those schedules awaits receiver `COMMAND_START_TRANSFER` completion before dispatching senders (while pool reshard, primary `StageBroadcastGroup` hops in `BroadcastEngine.execute_slice_broadcast_pipeline`, weight sync, and `KVCacheStore` transfers bypass `ExpectedPushSenders`).
**To resume:** (1) Add a `planDeclared` arm to `completePush` if modelling reshard transport; (2) offer `stepHardened` as a C++ patch + `block_transport_test.cc` case if owners want API hardening for direct `RegisterActivePlan` callers.
**Effort estimate:** (1) ~half-day; (2) ~1 h + OSS Bazel run.
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

## Coverage stopping criterion (W2–W4 remaining): `Pipeline`/`ReadRemote` W2, schedule-runner W4
**Status:** parked 2026-10-29; updated 2026-10-30 (W1 complete on every model, all `Gap.test` / `test (stub)` / multi-request recycle patches packaged under `findings/coverage_gap_*.patch`, `Receive`/`Send` W2 and `llvm-cov` × `resolve_anchors.py --coverage` W3 done; remaining W2 deprioritized per user direction)
**Context:** Spec/implementation coverage plan from McMillan & Zuck's QUIC work (`docs/conventions.md` §"Coverage"). Remaining stages: (W4) `TEST_P` C++ schedule interpreter over `RecvTestManager` running Lean-enumerated schedules and checking post-states (`Done()`, `IsDraining()`, `num_free_slots`, `copies_issued`, published status); optional (W2) guard × mutant inventories for `Pipeline` and `ReadRemote`.
**Why parked:** Completed W1 everywhere, test patches across every `PrefillDecode`, `ReadRemote`, and `Reshard` `Gap.test` hole, session W2, and repo-wide `llvm-cov` W3; user deprioritized further guard × mutant inventories as lower value.
**To resume:** Build the W4 `Receive` `TEST_P` runner (~3 days), or revisit `Pipeline`/`ReadRemote` W2 (~½ day) if a wrapper-level spec question motivates it.
**Effort estimate:** As above per stage.
**References:** ../journal/2026-10/2026-10-27-coverage-stopping-criterion-receive-pilot.md, tpu_sync/formal_verification/docs/conventions.md §"Coverage", tpu_sync/formal_verification/docs/transfer/reshard.md §"Branch coverage by the replayed tests"

## Upstream coverage-gap test PRs and F14 filing
**Status:** parked 2026-10-29; updated 2026-10-30 (first three patches handed to maintainers; four follow-up patches `findings/coverage_gap_{reshard_control,reshard_sessions,control_handshake,multi_request_recycle}.patch` and **F14** reproducer `findings/transfer_receive_late_finish_bughunt_test.cc` verified on `42dda542`)
**Context:** Hardware-free gtest cases closing every non-F14 `Gap.test`, `test (stub)`, and multi-request recycle hole across `PrefillDecode`, `ReadRemote`, and `Reshard` are packaged into standalone upstream PR patches (`findings/README.md` §Coverage-gap tests). Receiver late-`Finish` status flip is confirmed and documented as **F14** (`findings/transfer_receive_late_finish_bughunt_test.cc`; audit 2026-10-30: low severity — in production only the late pull-reply path and a near-deadline check-then-`Finish` sweep window reach it, and `TransferReceiveSession::FinishLocked` must gate `status_ = status` on `!done_ && !all_uploaded_ok` rather than returning early on `draining_`, because the poll-side `Finish()` can precede a failed H2D callback; `findings/README.md` §F14).
**Why parked:** Waiting for the test patches to land upstream and for **F14** to be filed.
**To resume:** (1) hand `findings/coverage_gap_{reshard_control,reshard_sessions,control_handshake,multi_request_recycle}.patch` to maintainers and, once the patches land, flip those rows to `paired` in the corresponding `Coverage.lean` modules at the next sync; (2) file **F14** and add a `findings/filed_bugs.md` entry.
**Effort estimate:** Filing F14 ~15 min.
**References:** findings/README.md §F14 and §Coverage-gap tests, ../journal/2026-10/2026-10-27-coverage-stopping-criterion-receive-pilot.md

## Sync upstream `42dda542` → `337540eb`: bounded host layer staging reached the reshard sessions
**Status:** parked 2026-10-30 (`resolve_anchors.py --diff 42dda542 337540eb`: `456 same, 274 shift, 77 modified, 0 drift, 9 fail`; every `modified`/`fail` is in `Reshard/*`)
**Context:** 13 upstream commits. `951b49be` (pool reshard receives) and `3d98f153` (sends) add bounded host layer staging (`StagingLayerManager`, `num_staging_layers`; the receive hook `acquire_recv_staging` / `lookup_send_staging` now also resolves `ReshardReceiveSession` / `ReshardSendSession`), `f9f66e7c` fails the send synchronously when its pipeline thread cannot start, `337540eb` resolves live staging leases while finalizing and adds 126 lines of `reshard_send_session_test` failure-path tests, `9f5270bc` replaces `TPU_RAIDEN_NUM_STAGING_LAYERS` with a `num_staging_layers` constructor parameter (`ScopedEnv` removed from `send_drain_test.cc`). `ReshardSendSession::ExecutePush` is restructured (3 `FAIL` anchors: the per-pool loop, `pool_future.OnReady`, `d2h_futures_.push_back` fragments); `StartPoolPush`, `RecordPushCompletion`, `Finish`, `SettleLocked`, `ReleaseLeasesLocked`, `ReshardReceiveSession::ExecuteEligiblePoolH2ds` (+~30 lines), `ReleaseStagingLocked`, `FinishLocked`, `CopyPoolBlocks`, `GetBlockChunks`, `PoolHostBaseAddrs`, `ConfigurePoolStaging` modified. `PrefillDecode/*`, `Caller`, `Registry`, `Coordinator` only shift.
**Why parked:** Yesterday's `42dda542` sync re-modelled `Send`; this one needs a scope decision first — take bounded staging into the reshard `Send`/`Receive` models (new slot-acquire state with its own failure/cancel arms, the synchronous thread-start failure) or scope it out as `PrefillDecode/{Send,Receive}` do (`§"Bounded host layer staging"`), then re-derive the three `Reshard/*/Coverage.lean` universes and pair the new `reshard_send_session_test` cases (several likely close `Reshard/Send/Coverage.lean` `Gap.test` rows).
**To resume:** merge `337540eb` (merge commit), decide the staging scope, `--diff`/`--apply`, re-run the Reshard W1 coverage searches, bump the README baseline, add the `upstream-rechecks.md` row.
**Effort estimate:** scope-out ~½ day (anchors + coverage re-derivation); scope-in ~2 days.
**References:** notes/upstream-rechecks.md (2026-10-28 row), tpu_sync/formal_verification/docs/transfer/reshard.md §"Branch coverage by the replayed tests"

## Reshard `PjRtCopyFuture` promise fake (`futureStub` branches) and post-`1b78685f` dead `d2h_layer_futures_.size()` guards
**Status:** parked 2026-10-29; updated 2026-10-30 (`Read at: 42dda542`; synchronous CPU `Gap.test` branches closed in `findings/coverage_gap_reshard_sessions.patch`)
**Context:** (a) After `findings/coverage_gap_reshard_sessions.patch` exercises synchronous CPU `ExecutePush` / `StartPoolPush` / `OnPoolReceived` / `ExecuteEligiblePoolH2ds` via `DeviceBackedTestBase`, the remaining `Gap.futureStub` branches in `Reshard/{Receive,Send}/Coverage.lean` require an issued pool D2H or H2D `PjRtCopyFuture` to stay pending across `Finish` or resolve `OnReady` with an error on CPU (a promise-backed `RawBuffer` / `PJRT_RawBuffer_Extension` test fake); (b) in `TransferSendSession`, `l >= d2h_layer_futures_.size()` in `SendNextLayer` (after `l >= base_->num_layers()`) and `d2h_layer_futures_.size() < base_->num_layers()` in `CurrentPhaseLocked` are dead since `1b78685f` pre-populates all `d2h_layer_futures_` before `SendNextLayer(0)`.
**Why parked:** Upstream test-seam / dead-code candidates; Lean models in `Reshard/{Send,Receive,Pipeline}.lean` already verify the async-future paths.
**To resume:** (1) Optionally add a test-only `xla::Promise<>`-backed `RawBuffer` / `PJRT_RawBuffer_Extension` fake to close the `Reshard/{Receive,Send}` `futureStub` branches; (2) fold (b) into any `transfer_send_session.cc` cleanup PR.
**Effort estimate:** (1) ~2 h; (2) ~15 min.
**References:** findings/README.md §Coverage-gap tests, tpu_sync/formal_verification/docs/transfer/reshard.md §"Branch coverage by the replayed tests", tpu_sync/formal_verification/docs/transfer/prefill_decode.md §"C++ branch coverage of the anchored spans"

## `TransferReceiveSession::RecordNetworkCompleteLocked`'s `FinishLocked()` arm is dead
**Status:** parked 2026-10-27 (`Read at: c9bc124`; reply-after-data late-`Finish` flip graduated to **F14** on 2026-10-30)
**Context:** `TransferReceiveSession::RecordNetworkCompleteLocked`'s `all_complete` → `FinishLocked()` arm cannot execute for `num_shards() ≥ 1` because `num_completed_layers_` only increments in the H2D callback (which calls `FinishLocked()` on the last layer unless `draining_`, after which `OnBlockShardsReceived` returns early).
**Why parked:** Dead-code cleanup only.
**To resume:** Mention alongside any `transfer_receive_session.cc` touch (e.g. when fixing **F14**): turn the `all_complete` arm in `RecordNetworkCompleteLocked` into a `DCHECK` or remove it.
**Effort estimate:** ~15 min.
**References:** tpu_sync/formal_verification/TpuSyncVerify/Transfer/PrefillDecode/Receive/Coverage.lean, findings/README.md §F14, ../journal/2026-10/2026-10-27-coverage-stopping-criterion-receive-pilot.md

## Triage and write up the four unfiled bug-hunt reproducers from the 2026-10-29 post-F11 audit
**Status:** parked 2026-10-29 (`Read at: 42dda542`; all four built and run on unmodified `42dda542`, files committed under `findings/` without `README.md` entries or `build_targets.patch` targets)
**Context:** After F11, four parked/unmodelled areas were audited by reading and the candidates confirmed or refuted by test: (1) `KVCacheStore::active_remote_writes_` is never erased on async `HostOffloadBackend::BeginWriteRemote` settlement (`~KVCacheStore` then double-`Release`s live pins) and a remote `CANCELLED` after the ack drops the pin release and the save verdict — `findings/kv_cache_store_remote_write_bughunt_test.cc` (3 failing + 1 control); (2) `KVCacheStoreClient::Fetch` sets no RPC deadline and `HostOffloadBackend::LoadRemoteBlocks` frees `dst_host_block_ids` on a transport error while the receiver still accepts planless op-6 / uuid-0 pushes into them — `findings/kv_cache_store_fetch_bughunt_test.cc` (4 failing; closes the older "`Fetch` missing RPC deadline" parked item above); (3) `KVCacheManagerBase::host_block_manager_` (`LogicalBlockManager`, documented as externally synchronized) is mutated without a lock by concurrent auto-allocating inbound pushes, `H2hRead` and `AllocateBlocks` — `findings/host_block_manager_race_bughunt_test.cc` (duplicate block ids; 1 failing + 1 control; no in-tree production caller of the auto-allocating `H2hWrite` / `H2hRead` found); (4) `WriteRemoteServerReactor::StartAck` vs `OnCancel` is **refuted** (gRPC 1.81.0 defers `OnCancel` until after `SetupReactor`; `Finish` during a pending `StartWrite` is legal) — `findings/kv_cache_store_service_reactor_bughunt_test.cc` (2 passing). User decision 2026-10-29: filing is scoped to the transfer path first; (1)–(3) are store-path and deferred.
**Why parked:** Transfer-path findings (F12, F13) were written up and filed first; the store-path write-ups need the same README/filed-bugs treatment and a decision on whether to file (1) and (2) given the `vllm-torchtpu` / `sglang-torchtpu` callers do not use `KVCacheStore`.
**To resume:** For each of (1)–(3): add a `## Fn.` entry to `findings/README.md` with the verbatim output, a Summary row, and a `build_targets.patch` target; fold (4) into §Refuted; then draft reports in the house style (Cause / Impact / one-line confirmation). Delete the superseded "`Fetch` missing RPC deadline" entry above when (2) is written up.
**Effort estimate:** ~1 h per finding for README + patch; ~30 min per report.
**References:** findings/README.md §History (2026-10-29, later), ../durable/controller-read-remote-and-kv-store-pinning-concurrency-traps.md
