# Bug-hunt findings

Defects found while modelling tpu-sync, with the evidence for each. Each
finding's write-up (`## Fn.`) is a historical record frozen at the commit where
it was confirmed or fixed (line numbers in `## Fn.` bodies reflect `2ed6f8f` as
of 2026-10-22 unless a block of test output or historical note says otherwise;
the F1–F4 tests were run on `b68161a` and re-run on `d16701e`, the F5 tests on
`50b0774`). When upstream lands a fix or moves unrelated lines, update the
`Summary` table and `History` section rather than re-pinning frozen `## Fn.`
bodies.

Callers checked: [`vllm-project/vllm-torchtpu`](https://github.com/vllm-project/vllm-torchtpu)
@ `9725110` (2026-10-20; connector
`src/vllm_torchtpu/distributed/kv_transfer/tpu_connector.py`) and
[`sgl-project/sglang-torchtpu`](https://github.com/sgl-project/sglang-torchtpu)
@ `9a6eef1` (2026-10-20; `sglang_tpu/disaggregation/raiden/{pipeline,pp_swa,pp_common}.py`).
Earlier entries that say "`vllm-torchtpu` @ `6a9132a84`" were read at that
commit. See §Callers for what each finding needs from a caller and whether
these two provide it. The **prefill-to-decode** path (`register_read` /
`start_read` / `poll_stats`) has a third, unrelated caller:
[`vllm-project/tpu-inference`](https://github.com/vllm-project/tpu-inference)
`tpu_inference/distributed/tpu_raiden_connector.py` @ `7ed46a6` (the commit
`examples/*_disagg/setup.sh` pin; unchanged on the cited lines at `main`
`c2b062b`, 2026-10-20, and still at `main` `7840339b`, 2026-10-28 — the fix
is open as [PR #3918](https://github.com/vllm-project/tpu-inference/pull/3918),
see C1) on vLLM @ `6185d73` (same scripts). Caller-side defects
are numbered C1, C2, … and live in the caller, not in tpu-sync.

## Evidence levels

| Level | Meaning |
|---|---|
| **CONFIRMED (test)** | A real C++ test on unmodified production code fails and shows the wrong behaviour. |
| **CONFIRMED (read)** | The defect is unambiguous in the code, but no test has run. |
| **PLAUSIBLE** | Reachability depends on something not yet established. |
| **REFUTED** | Checked and not a bug. Kept so nobody re-investigates it. |

Nothing is promoted to CONFIRMED (test) without real, unedited output pasted
here.

## Method

1. **Extract.** Read the C++ and write down the state and transitions, each
   with a `file:line` citation.
2. **Hypothesise.** Use a Lean model or a bounded search to find a property
   violation (`TpuSyncVerify/Controller/ReadRemote.lean` on branch `controller-verification` for F2).
3. **Reachability.** Check the violating order against the real threading and
   lock structure and against real callers.
4. **Confirm.** Write a deterministic gtest that drives the real code into
   that order. The tests live here, not in the tree; `build_targets.patch`
   adds their targets.

## Files

| File | What |
|---|---|
| `raiden_controller_bughunt_test.cc` | F2 (shape A) and F4 (both halves) |
| `kv_cache_store_pin_race_test.cc` | F1 |
| `reshard_bughunt_test.cc` | R7a, R7b, R8, R2b of `tpu_sync/formal_verification/docs/transfer/reshard.md` (registry / coordinator claim lifecycle; all four pass, not yet filed) |
| `reshard_send_session_bughunt_test.cc` | F10 (R6 of `tpu_sync/formal_verification/docs/transfer/reshard.md`): the sender's early plan unregister and the uuid-keyed staging lease it hands to a retry |
| `numa_kv_cache_manager_bughunt_test.cc` | F11: `NumaAwareKVCacheManager::CompleteReadRaw` eager `failed_recving` while sibling sub-managers still have H2D / D2H DMAs in flight, plus `failed_recving_set_` / barrier-count leak and `req_id`-reuse poisoning |
| `pool_reshard_chain_bughunt_test.cc` | F12 (`PoolReshardChainBughunt`, `ChainClaimTest`) and F13 (`PoolReshardChainBughunt1B`): windowed pool-reshard sub-plan chains (`09a42d4e`) — a sender absent from some windows never reports `done_sending`; a chain failing after window 0 holds the registry claim until TTL; the first failing sub-plan is reported while sibling / later windows still run and can be reported twice |
| `transfer_receive_late_finish_bughunt_test.cc` | F14 (`RecvLateFinishBughunt`): 1 control (`TransferSendSession`) + 4 failing cases driving `end_incoming_push`, `UnregisterActivePlan`, `ExecutePullRequest` `on_response`, and `ReshardReceiveSession` directly (entry points renamed at `56a0269d`; needs porting), where a late `Finish(error)` after every H2D completed OK flips `completions.received` to `completions.failed` (in production only the `on_response` path and a photo-finish deadline-sweep race reach it; see §F14) |
| `reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc` | F15 (`ReshardRecvStagingSlotRankDeadlock`): 1 control (bounded staging `num_layers = 3, num_staging_layers = 2`: two host layer buffers for two pools, rank-0 pool's first chunk resolves at once) + 2 failing cases — (1) bounded staging (`num_layers = 2, num_staging_layers = 1`): rank-1 pool's first chunk takes the only slot, its H2D is rank-gated, rank-0 pool's first chunk blocks in `StagingLayerManager::Acquire` until `deadline_` and the receive fails `DEADLINE_EXCEEDED`, and (2) `47e9f200` full host mirror (`num_layers = 1`, `num_staging_layers` unset): `AcquireStagingSlot` returns `StaticHostLayer(pool_idx) = 0` without leasing, so rank-0 arriving after rank-1 on the same `(storage_index, block_id)` overwrites rank-1's staged host bytes in `layers_[0]` before rank-1's gated H2D runs; runs on CPU at `d3751fcb` |
| `kv_transfer_uuid_and_reshard_push_bughunt_test.cc` | F16 (`UuidRetirementBughunt`: 1 control + 3 failing cases covering `StartRead` inline retirement, `RegisterRecv` inline retirement, and `CompleteReadWithDetails`'s dead `std::erase_if` + unlocked `ForgetPushProgress(uuid)` race, each publishing silent corrupt `completions.received` with layer 0's HBM block unwritten) and F17 (`PoolReshardPushDuplicateUuidBughunt`: 1 control + 1 failing case where concurrent duplicate-UUID `PoolReshardPush` calls both succeed, overwrite `sessions_[uuid]`, and free the shared 1-slot `PoolStagingStorage` lease while the sibling push is still streaming, aliasing the slot to an unrelated transfer); runs on CPU at `56a0269d` and unchanged at `00e946e3` |
| `pool_reshard_stale_subplan_bughunt_test.cc` | F13 at `00e946e3` (`StaleSubPlanBughunt`: 2 controls + 4 failing cases on `25f7d8a7`'s `sub_plan_chains_` — a single-plan retry under the same `req_id` erases a live chain entry so a stale sub-plan reports premature `done_recving` or `failed_recving` for the retry, and `SweepSubPlanChainsLocked` erases a failed chain tombstone while a sibling sub-plan is `IsDraining() && !Done()` so it later emits a second `failed_recving` or false `done_recving` on the failed request; runs on CPU at `00e946e3`) |
| `kv_cache_store_remote_write_bughunt_test.cc` | F18 (`RemoteWriteSettlementTest`: 1 control + 3 failing cases — async `HostOffloadBackend::BeginWriteRemote` settlement never erases `KVCacheStore::active_remote_writes_`, causing `~KVCacheStore` to double-`Release` live pins on a shared backend, and a destination closing the result stream with `CANCELLED` after its ack drops the pin release and save verdict; runs on CPU at `42dda542` and unchanged at `00e946e3`) |
| `kv_cache_store_fetch_bughunt_test.cc` | F19 (`FetchLifetimeTest` 3 failing + `FetchPushAfterFreeTest` 1 failing — `KVCacheStoreClient::Fetch` sets no client deadline so a silent source wedges `ReadRemote`, pins destination host blocks and blocks same-hash retries; when `Fetch` fails, `HostOffloadBackend::LoadRemoteBlocks` frees `dst_host_block_ids` immediately while the receiving worker still accepts planless `op = 6` / `uuid = 0` pushes into freed or reallocated host blocks; runs on CPU at `42dda542` and unchanged at `00e946e3`) |
| `host_block_manager_race_bughunt_test.cc` | F20 (`HostBlockManagerRaceTest`: 1 control + 1 failing case — `KVCacheManagerBase::host_block_manager_` (`LogicalBlockManager`, externally synchronized) is mutated without a lock by concurrent auto-allocating inbound `op = 1` pushes, `H2hRead` pulls and `AllocateBlocks`, handing out duplicate host block IDs; runs on CPU at `42dda542` and unchanged at `00e946e3`) |
| `kv_cache_store_service_reactor_bughunt_test.cc` | R-I (`WriteRemoteReactorStressTest`: 2 passing cases refuting a `WriteRemoteServerReactor::StartAck` vs `OnCancel` write-after-`Finish` race under gRPC 1.81.0; runs on CPU at `42dda542` and unchanged at `00e946e3`) |
| `build_targets.patch` | `cc_test` targets for all 14 `.cc` files above (re-anchored at `d3751fcb`, applies cleanly with zero offset) |
| `candidate_fixes.patch` | fix for F2 (naive, shape A only); the F4 hunk was dropped when upstream fixed F4 (`72255dd`), the F1 hunk when upstream fixed F1 (`b3ea4dc`); see "Fix validation" |
| [`filed_bugs.md`](filed_bugs.md) | verbatim write-ups of bugs filed upstream |
| [`tpu_inference_connector_c1_test.py`](tpu_inference_connector_c1_test.py) | C1 reproducer: vLLM scheduler + tpu-inference connector on CPU, 9 cases incl. 2 controls; run recipe in the header |
| `coverage_gap_tests.patch` (`coverage_gap_{send,recv,read_remote_deadline}.patch`) | 9 upstream-shaped test cases for lifecycle branches no test in the suite reaches, taken from the branch-coverage tables in `tpu_sync/formal_verification/` (`Receive/Coverage.lean`, `Send/Coverage.lean`, and `Controller/ReadRemoteCoverage.lean` on branch `controller-verification`): 4 `RecvLifecycleTest`/`RecvDrainTest` cases appended to `kv_cache_manager_with_transfer_send_drain_test.cc`, 2 `TransferSendSessionTest` cases appended to `transfer_send_session_test.cc`, and a new `read_remote_deadline_test` target (3 cases, own binary with `RAIDEN_REMOTE_READ_DEADLINE_S=1` because `RemoteReadDeadline()` is a process-wide static) with its `BUILD` rule. Based on `42dda542`; all 9 pass there (2026-10-28); at `56a0269d` `coverage_gap_send.patch` and `coverage_gap_read_remote_deadline.patch` still apply, `coverage_gap_recv.patch` (and the combined patch) does not; at `00e946e3` only `coverage_gap_read_remote_deadline.patch` applies (`coverage_gap_send.patch` fails on `transfer_send_session_test.cc:796`). Offered upstream as three small per-target test-only PRs (`coverage_gap_{send,recv,read_remote_deadline}.patch`). Packaged separately below: the two `Receive` handshake cases (`coverage_gap_control_handshake.patch`) and the two `MultiRequest` staging-recycle cases (`coverage_gap_multi_request_recycle.patch`); `coverage_gap_reshard_control.patch` was retired 2026-11-09 after upstream `5835b975` landed the 7 `ReshardStackTest` lifecycle cases. Not included: two `ReadRemote` rows with no observable effect (`acquireAfterShutdown` after the deadline, and `deadlineLate`, which a test cannot see), and the receiver's late-`Finish` status flip, confirmed separately as **F14**. See "Coverage-gap tests" below |
| `coverage_gap_reshard_sessions.patch` | 12 upstream-shaped test cases (4 `ReshardSendSessionTest` cases in `tpu_sync/kv_cache/reshard_send_session_test.cc` plus 4 `PoolReshardRecvTest` and 4 `PoolReshardSendTest` cases in `tpu_sync/kv_cache/kv_cache_manager_with_transfer_pool_reshard_test.cc`) closing every non-F14 `Gap.test` branch of `Reshard/Receive/Coverage.lean` (18 of 21; the other 3 are F14's late-`Finish` status flips) and `Reshard/Send/Coverage.lean` (15 of 16; the other 1 is F14), plus the first CPU end-to-end loopback `Reshard/Pipeline` trace (`trace_arm_before_dispatch`), without pinning F10 or F14. Based on `42dda542`; 12/12 pass (`--runs_per_test=6`, 2026-10-30); does not apply at `56a0269d` (`ReshardSendSessionTestPeer` hunk; F10 is fixed there and upstream added its own sender failure-path tests in `337540eb` / `1523b07d` / `10d181f6`). See "Coverage-gap tests" below |
| `coverage_gap_control_handshake.patch` | 2 upstream-shaped `ControlHandshakeTest` cases extending `tpu_sync/kv_cache/kv_cache_manager_with_transfer_control_test.cc` (adding `SilentProducer::AcceptClient` and a `NumaThreadPool` worker barrier) to close both `Gap.test (stub)` branches of `PrefillDecode/Receive/Coverage.lean` (`pullReplyOk` with no lifecycle effect and `pullReplyOk` settling an expired receive). Based on `42dda542`; 2/2 pass (`--runs_per_test=6`, 2026-10-30); does not apply at `56a0269d` (`:54` hunk; upstream added `TransferReceiveSession` pull-handshake tests of its own in `f5001fac`). See "Coverage-gap tests" below |
| `coverage_gap_multi_request_recycle.patch` | 2 upstream-shaped `MultiRequestTest` cases in `tpu_sync/kv_cache/kv_cache_manager_with_transfer_send_drain_test.cc` closing both live multi-request branches of `PrefillDecode/MultiRequestCoverage.lean` (`nextRequest` / `tr_multi_request` and `recyclePrefill` / `tr_overlapped_requests`) and all 3 `Pipeline/Coverage.lean` environment branches (`reclaim`, `reseatPrefillStaging`, `reseatDecodeStaging`) over loopback control + `BlockTransport` with simulated HBM and staging-pointer reuse assertions; applies cleanly both standalone and stacked with `coverage_gap_recv.patch`. Based on `42dda542`; 2/2 pass (`--runs_per_test=6`, 2026-10-30); does not apply at `56a0269d` (`:1278` hunk). See "Coverage-gap tests" below |

To run F1–F4: copy the two `.cc` files next to the code they test
(`tpu_sync/core/controller/`, `tpu_sync/kv_cache/`), `git apply
findings/build_targets.patch`, then
`bazel test //tpu_sync/core/controller:raiden_controller_bughunt_test
//tpu_sync/kv_cache:kv_cache_store_pin_race_test`. To run F11: copy
`numa_kv_cache_manager_bughunt_test.cc` to `tpu_sync/frameworks/jax/`, apply
`findings/build_targets.patch`, and run
`bazel test --config=oss //tpu_sync/frameworks/jax:numa_kv_cache_manager_bughunt_test`.
To run F12 / F13: copy `pool_reshard_chain_bughunt_test.cc` (pinned to
`42dda542`) or `pool_reshard_stale_subplan_bughunt_test.cc` (`00e946e3`
`sub_plan_chains_` retry and draining-tombstone cases) to `tpu_sync/kv_cache/`,
apply the patch, and run
`bazel test --config=oss //tpu_sync/kv_cache:pool_reshard_stale_subplan_bughunt_test`.
To run F14: copy `transfer_receive_late_finish_bughunt_test.cc` to
`tpu_sync/kv_cache/`, apply `findings/build_targets.patch`, and run
`bazel test --config=oss //tpu_sync/kv_cache:transfer_receive_late_finish_bughunt_test`.
To run F15: copy `reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc` to
`tpu_sync/kv_cache/`, apply `findings/build_targets.patch`, and run
`bazel test --config=oss //tpu_sync/kv_cache:reshard_recv_staging_slot_rank_deadlock_bughunt_test`.
To run F16 / F17: copy `kv_transfer_uuid_and_reshard_push_bughunt_test.cc` to
`tpu_sync/kv_cache/`, apply `findings/build_targets.patch`, and run
`bazel test --config=oss //tpu_sync/kv_cache:kv_transfer_uuid_and_reshard_push_bughunt_test`.
To run F18–F20 and R-I: copy `kv_cache_store_remote_write_bughunt_test.cc`,
`kv_cache_store_fetch_bughunt_test.cc`, `host_block_manager_race_bughunt_test.cc`,
and `kv_cache_store_service_reactor_bughunt_test.cc` to `tpu_sync/kv_cache/`,
apply `findings/build_targets.patch`, and run
`bazel test --config=oss //tpu_sync/kv_cache:kv_cache_store_remote_write_bughunt_test
//tpu_sync/kv_cache:kv_cache_store_fetch_bughunt_test
//tpu_sync/kv_cache:host_block_manager_race_bughunt_test
//tpu_sync/kv_cache:kv_cache_store_service_reactor_bughunt_test`.
F5 needs no repro file:
its test is already in the tree as `DISABLED_`
(`bazel test --config=oss //tpu_sync/kv_cache:kv_cache_manager_with_transfer_control_test
--test_arg=--gtest_also_run_disabled_tests`); the fix patch that re-enabled it
was retired on 2026-10-16 (see F5). All patches applied cleanly at
`42dda542` (`git apply --check`, 2026-10-30; `build_targets.patch` updated
2026-11-03 for F15–F17 and 2026-11-09 for `pool_reshard_stale_subplan_bughunt_test`
and F18–F20 / R-I; `candidate_fixes.patch` was last re-based at `2ed6f8f`).
At `56a0269d` (`git apply --check` from the repo root, 2026-11-03)
`build_targets.patch`, `candidate_fixes.patch`, `coverage_gap_send.patch`,
`coverage_gap_read_remote_deadline.patch` and `coverage_gap_reshard_control.patch`
still apply (the `transfer_send_session_test.cc` hunk at an offset of 33
lines); `coverage_gap_recv.patch` and `coverage_gap_tests.patch` fail on
`kv_cache_manager_with_transfer_send_drain_test.cc` (hunk at `:1733`, the
`RecvLifecycleTest` / `RecvDrainTest` appendix), `coverage_gap_reshard_sessions.patch`
on `reshard_send_session_test.cc` (hunk at `:67`, the extended
`ReshardSendSessionTestPeer`, which upstream itself extended with
`StartPoolPush` / `RecordPushCompletion` / `EndOp` seams in `337540eb` and
`1523b07d`), `coverage_gap_control_handshake.patch` on
`kv_cache_manager_with_transfer_control_test.cc` (hunk at `:54`) and
`coverage_gap_multi_request_recycle.patch` on
`kv_cache_manager_with_transfer_send_drain_test.cc` (hunk at `:1278`); none
has been re-based;
`kv_cache_store_pin_race_test.cc` needs its `WindowBackend::Insert` override
ported to the `InsertOption` signature `2ed6f8f` introduced before it compiles
(F1 is fixed there, see §F1). The F1–F4, R7/R8/R2b and F10 `.cc` reproducers
have not been rebuilt since the runs their entries record.
At `00e946e3` (`git apply --check` from the repo root, 2026-11-09) three
patches apply cleanly: `build_targets.patch` (re-anchored at `00e946e3` with
zero offset across all 14 `.cc` files), `candidate_fixes.patch` and
`coverage_gap_read_remote_deadline.patch`. `coverage_gap_reshard_control.patch`
was retired on 2026-11-09 after upstream `5835b975` appended all 7
`RequestBlockRegistry` / `ReshardCoordinator` lifecycle cases to
`reshard/reshard_service_test.cc` (`Reshard/Registry/Coverage.lean` 25/25,
`Reshard/Coordinator/Coverage.lean` 14/14). `coverage_gap_send.patch` (and so
`coverage_gap_tests.patch`, now failing on both of its files) stopped applying
on `transfer_send_session_test.cc` (hunk at `:796`; `55c218d2`, `000ac1d2` and
`32568d35` rewrote the file's `TransferSendSession::Create` calls and appended
host-source tests). The four that already
failed at `56a0269d` (`coverage_gap_recv.patch` `:1733`,
`coverage_gap_reshard_sessions.patch` `:67`,
`coverage_gap_control_handshake.patch` `:54`,
`coverage_gap_multi_request_recycle.patch` `:1278`) still fail on the same
hunks. Reproducers built and run at `00e946e3`:
`reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc` (ported:
`KVCacheManagerBase::OnPoolReceived(pool_idx, uuid)`, removed by `9c9f92ff`,
became `OnLayerReceived(pool_idx, uuid)`),
`kv_transfer_uuid_and_reshard_push_bughunt_test.cc` (unchanged),
`pool_reshard_stale_subplan_bughunt_test.cc` (written at `00e946e3`), and all
four store/allocator tests (`kv_cache_store_remote_write_bughunt_test.cc`,
`kv_cache_store_fetch_bughunt_test.cc`, `host_block_manager_race_bughunt_test.cc`,
`kv_cache_store_service_reactor_bughunt_test.cc`, all compiling unchanged at
`00e946e3`; see §F13, §F15–§F20, §R-I and §History 2026-11-09). `pool_reshard_chain_bughunt_test.cc`
(F12 / F13 original `42dda542` harness) still needs porting: `ReshardSendSession::Create` →
`CreateReshardSendSession` (returning `std::shared_ptr<TransferSession>`; the
`ReshardSendSession` / `ReshardReceiveSession` types are no longer visible,
`49e2c36c`), `NoteSubPlanRegisteredLocked(is_recv, req_id, uuid, index, count)`
→ `(req_id, session, index, count)` over `sub_plan_chains_` instead of
`recv_chains_` / `send_chains_` (`25f7d8a7`), `sessions_[uuid] = session` →
`SessionEntry{session, req_id, SessionRole::kPoolReshardSend}` and no
`req_id()` on sessions (`000ac1d2`).
`transfer_receive_late_finish_bughunt_test.cc` (F14) still needs the porting
listed in its §Files row.
At `d3751fcb` (`git apply --check` from the repo root, 2026-11-11) the same
three patches apply cleanly: `build_targets.patch` (re-anchored at `d3751fcb`
with zero offset and updated `reshard_recv_staging_slot_rank_deadlock_bughunt_test`
deps), `candidate_fixes.patch` and `coverage_gap_read_remote_deadline.patch`;
the remaining `coverage_gap_*.patch` files still fail on their `56a0269d` /
`00e946e3` hunks. Reproducers built and run at `d3751fcb`:
`reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc` (extended with a
full-mirror aliased-storage host-buffer clobber case after `47e9f200`: 1 control
passing + 2 cases failing), `kv_transfer_uuid_and_reshard_push_bughunt_test.cc`
(2 controls passing + 4 cases failing, unchanged), and
`pool_reshard_stale_subplan_bughunt_test.cc` (2 controls passing + 4 cases
failing, unchanged; see §F13, §F15–§F17 and §History 2026-11-11).

## Summary

| # | Finding | Status | Reachable from production? |
|---|---|---|---|
| F1 | `ValidateAndPinHostBlocks` could return a host block id that no longer holds the hash ([filed](filed_bugs.md#4-kvcachestorevalidateandpinhostblocks-check-then-act-window-between-lookup-and-pin-can-return-a-stale-host_block_id-f1) 2026-10-19) | CONFIRMED (test) on `b68161a` / `d16701e`, code unchanged through `0ac16d1`; **FIXED upstream** in `b3ea4dc` (2026-10-21) | only via the `ReadRemote` API (no in-tree caller) |
| F2 | Remote read keeps DMA-ing into destination blocks after it settled with a deadline error ([filed](filed_bugs.md#7-raidencontrollerreadremote-deadline-settles-the-read-while-the-acquire-callback-and-pull-continue-so-the-dma-writes-into-blocks-the-caller-has-already-recycled-f2--f3) 2026-10-20, together with F3) | CONFIRMED (test) for shapes A and B (B added 2026-10-20, on upstream `449b591`); proved in Lean for both; filed upstream, fix pending; **still open at `d3751fcb`** (`raiden_controller.cc` unchanged since `449b591`) | same |
| F3 | Data race on `RemoteReadState::lease_id` (filed as part of the F2 report) | CONFIRMED (read); filed upstream, fix pending; **still open at `d3751fcb`** (same file, unchanged) | same |
| F4 | `TransferBuffers` leaks auto-allocated staging on every early error, and can return an error after some workers were dispatched ([filed](filed_bugs.md#1-raidencontrollertransferbuffers-error-path-defects-f4), fix: [PR #1105](https://github.com/google/tpu-sync/pull/1105)) | CONFIRMED (test) on `b68161a` / `d16701e`, code unchanged through `50b0774`; **FIXED upstream** by PR #1105 = `72255dd` (2026-10-07) | leak: no in-tree trigger; orphaned copies: yes, via Fetch / WriteRemote on a node_id mismatch |
| F5 | One unresponsive producer pins every host staging slot; `StartRead` then rejects reads from every other producer (no per-peer admission; owner-acknowledged, fix designed and validated on `50b0774`, patch retired 2026-10-16) | CONFIRMED (test), with the owners' own parked test; **still open at `d3751fcb`** (the test is still `DISABLED_` in `kv_cache_manager_with_transfer_control_test.cc`; `StartRead` → `TransferReceiveSession::Create` → `AllocateStagingForLoad` → `StagingBlockAllocator::Acquire` is still first-come-first-served and `staging_arena.cc` is unchanged; `32568d35`'s host destination (`StartRead(..., BlockLocation::kHost)`) lands in caller-named host blocks and leases no staging, so it sidesteps the slot pool rather than fixing its admission) | yes: every consumer `StartRead` to a device destination, given one producer that accepts and never answers |
| F6 | `PoolReshardRegisterRecv`: a rejected duplicate (or racing) registration for an active `uuid` destroys a session object whose destructor releases the **active** session's host-staging lease ([filed](filed_bugs.md#2-poolreshardregisterrecv-duplicate-registration-frees-the-active-sessions-staging-lease-f6)) | CONFIRMED (read) at `1fa06d1`; reproduced by the reporter; **FIXED upstream** in `8653373` (2026-10-13) | yes: any pool-reshard receiver with bounded host staging (`RegisterPools(..., staging_leases > 0)`), on a duplicate or concurrent register for the same `uuid` |
| F7 | `end_incoming_push` hook: a failed incoming push on a `ReshardReceiveSession` is not turned into `Finish(status)` (the `TransferReceiveSession` branch does), so the session, its staging lease and plan claim stay pinned until the deadline sweep, which reports `DEADLINE_EXCEEDED` instead of the push error ([filed](filed_bugs.md#3-reshardreceivesession-ignores-a-failed-endincomingpush-and-pins-poolstagingstorage-until-timeout-r1); R1 in `tpu_sync/formal_verification/docs/transfer/reshard.md`) | CONFIRMED (read) at `0ac16d1`, witnessed in Lean (`Receive.lean`); **FIXED upstream** in `fdeebcd` (2026-10-16) | yes: any pool-reshard receiver whose sender's push fails mid-transfer (socket timeout / disconnect) |
| F8 | `ReshardCoordinator::ExecutePoolReshard`: the sender-dispatch error return omits `registry_->AbandonClaim(...)` (the plan-build, receiver-arm and null-controller returns all call it), so the request stays `STATUS_CLAIMED` until `ttl_s_`, refusing `CancelIfUnclaimed` and re-registration ([filed](filed_bugs.md#5-reshardcoordinatorexecutepoolreshard-sender-dispatch-failure-returns-without-calling-abandonclaim-leaking-the-registry-claim-r2b) 2026-10-19; R2b in `tpu_sync/formal_verification/docs/transfer/reshard.md`) | CONFIRMED (test) at `0ac16d1` (`reshard_bughunt_test.cc`); filed upstream, fix pending; **still open at `d3751fcb`** (`reshard_coordinator.cc` unchanged since `42dda542`; `09a42d4e` split `ExecutePoolReshard` and the plan/arm/dispatch sequence lives in `ReshardCoordinator::RunSubPlan`, whose sender-status loop (`if (!status.ok()) return status;`) still has no `registry_->AbandonClaim(...)`; the three abandoning returns are guarded by `index == 0`) | yes: any pool reshard whose sender `StartTransfer` RPC fails after the receivers were armed |
| F9 | `RequestBlockRegistry::LookupAndClaim` refreshes the `claimed_` TTL but not `expires_at` on the claimed `request_blocks_` rows, so in `[t_reg + ttl, t_claim + ttl)` the producer registrations are purged while the claim is live: `Status` says `STATUS_CLAIMED`, `CancelIfUnclaimed` refuses, and a sibling stage or retry fails with `"Missing producer block registration"` ([filed](filed_bugs.md#6-requestblockregistrylookupandclaim-claiming-a-request-does-not-refresh-request_blocks_-ttl-evicting-producer-registrations-while-the-claim-is-active-r8) 2026-10-19; R8 in `tpu_sync/formal_verification/docs/transfer/reshard.md`) | CONFIRMED (test) at `0ac16d1` (`reshard_bughunt_test.cc`); filed upstream 2026-10-19; **FIXED upstream** in `63c6447c` (2026-11-10, "Refresh producer block registration TTL when a reshard request claims it"): `LookupAndClaim` collects `claimed_rows` and refreshes `registration.expires_at = now + ttl_s_;` on every claimed `request_blocks_` row alongside `claimed_[lifecycle_key] = now + ttl_s_;`, leaving failed claims unrefreshed (`ReshardStackTest.ClaimRefreshesRegistrationTtlForSiblingStageAndCompletion`, `FailedClaimDoesNotRefreshPartialRegistrationTtl`) | yes: any multi-stage pool reshard (or a retry) whose later claim lands more than `ttl_s_` after registration but before the first claim expires |
| F10 | `ReshardSendSession::RecordPushCompletion` unregisters the sender's plan on the **first** failed push while sibling pushes are still in flight (`EndOp` would do it at settle). Siblings then resolve no chunks, and — the sharp half — a retry of the same `uuid` is accepted by `Create` while the failed session drains, shares its uuid-keyed staging lease, and loses that staging when the old session settles; a third transfer is then leased the same slot (the F6 shape on the sender; early unregister since `FinishPoolReshardSend` before `1673c9b`, lease-aliasing window since `3d1b5d4`) (R6 in `tpu_sync/formal_verification/docs/transfer/reshard.md`) | CONFIRMED (test) 2026-10-20 (`reshard_send_session_bughunt_test.cc`, against the `1fa06d1` build; the code involved is unchanged through `2ed6f8f`); **filed 2026-10-23** (bug 9 in `filed_bugs.md`); **FIXED upstream** in `1523b07d` (2026-10-30, "Move active transfer plans into TransferSession"): the plan lives in the session (`plan()` visible until `Done()`), `RecordPushCompletion` / `EndOp` no longer call `UnregisterActivePlan`, `Create` no longer leases, and `PoolReshardPush` refuses a same-uuid retry while the prior session is live (`RetireSettledSessionLocked` → `ALREADY_EXISTS`); verified by reading at `56a0269d`, reproducer not re-run (it drives the removed `UnregisterActivePlan` path) | early unregister: yes, any multi-peer/multi-pool send whose first failure has siblings in flight; lease aliasing: needs a same-uuid re-coordination while the old session drains, which neither `vllm-torchtpu` nor `sglang-torchtpu` does (§Callers) |
| F11 | `NumaAwareKVCacheManager::CompleteReadRaw` (the JAX `poll_stats()` wrapper) emits `failed_recving` on the **first** failing sub-manager while sibling sub-managers still have H2D / D2H DMAs in flight (`done_sending` and `done_recving` barrier-wait across sub-managers; pinned by upstream's `AnyFailureImmediatelyTriggersFailedRecvingAndSuppressesFutureAcks`), and **never erases `failed_recving_set_`** on failure (erased only when `done_recving_counts_[req] >= expected` on pure `done_recving` completions), leaking map entries on every failed/expired transfer and poisoning reused `req_id`s (dropping subsequent `failed_recving` / `done_recving` at `num_subs == 1`, and desynchronizing `done_recving_counts_` into premature `done_recving` after partial failure at `num_subs >= 2`). Present since `00a3f670` (2026-06-23) | CONFIRMED (test) 2026-10-29 (`numa_kv_cache_manager_bughunt_test.cc`, 4/4 cases on unmodified `42dda542`); **filed 2026-10-29** (bug 10 in `filed_bugs.md`); **FIXED upstream** in `c0e8e686` (2026-10-29, "Barrier-wait failed transfers and clean up completion state in NumaAwareKVCacheManager"): `failed_recving_counts_` replaces `failed_recving_set_`, `process_completion` emits once the three counts reach `expected` and erases all four maps, with five rewritten or new `KVCacheManagerWrapperTest` cases (`FailureWaitsForSiblingSubManagersBeforeEmittingFailedRecving`, …, `SingleSubManagerFailureEmitsImmediatelyAndCleansUp`); the Lean `NumaPolicy.settledCounts` barrier is now the shipping code | eager `failed_recving` mid-DMA: yes on a single request when `ENABLE_MULTI_NUMA=1` (`num_subs >= 2`, wired in `tpu_raiden_connector._remote_endpoint`) + a caller forwarding `failed_recving` (masked while C1 dropped `failed_recving`; exposed once [PR #3918](https://github.com/vllm-project/tpu-inference/pull/3918) lands); `failed_recving_set_` leak: yes on every failed/expired transfer even at default `ENABLE_MULTI_NUMA=0`; `req_id`-reuse poisoning: immediate for direct `jax::KVCacheManager` callers, gated by `VLLM_DISABLE_REQUEST_ID_RANDOMIZATION=1` (or 8-hex suffix collision) in vLLM V1 |
| F12 | Windowed pool reshard (`dst_window_blocks` sub-plan chains, `09a42d4e`): `BuildPoolReshardPlan` dispatches only the source units with spans in the current window, while every sub-plan is stamped with the request-wide `sub_plan_count = K`, so a sender in `1 <= m < K` windows never reaches `K` settled sub-plans, reports nothing until `SweepSubPlanChainsLocked` fails it (`DEADLINE_EXCEEDED … m of K sub-plans settled`) after `timeout_s_`; and `RunSubPlan` abandons the registry claim only `if (index == 0)`, so a chain failing at window ≥ 1 leaves every rank not dispatched in `0 .. index-1` — which has no session and never votes `Complete` — in the claim until `ttl_s_` (the F8 gap, now by design for later windows) | CONFIRMED (test) 2026-10-29 (`pool_reshard_chain_bughunt_test.cc`: `PoolReshardChainBughunt` 2 failing + 1 control, `ChainClaimTest` 1 failing + 2 controls, on unmodified `42dda542`); **filed 2026-10-29** (bug 11 in `filed_bugs.md`); **still open at `d3751fcb`** (`pool_reshard_planner.cc` and `reshard_coordinator.cc` unchanged; `RunSubPlan` still abandons `if (index == 0)` only; on the worker, `25f7d8a7` re-keyed the chain as `sub_plan_chains_[req_id].sub_sessions` — one `std::shared_ptr<TransferSession>` slot per `sub_plan_index`, sized `max(sub_plan_count, sub_plan_index + 1)` — and `RecordPoolReshardTerminalLocked` reports `done_sending` only when `settled_count == sub_sessions.size()`, so a sender dispatched in `m < K` windows still leaves `K - m` null slots and is still failed by `SweepSubPlanChainsLocked` after `timeout_s_`) | yes for any multi-window request whose span ownership varies by window (upstream's own `WindowedRequestChainsOneSubTransferPerWindow` / `WindowClipsStraddlingSpansAtWindowBoundaries` shapes), once a caller passes `dst_window_blocks` (`SUPPORTS_DST_WINDOW_BLOCKS` is wired in `api/torch/reshard_client.py`; `vllm-torchtpu` `9725110` and `sglang-torchtpu` `9a6eef1` do not pass it yet) |
| F13 | Windowed pool reshard: `RecordPoolReshardTerminalLocked` emits `failed_recving` on the **first** failing sub-plan with no check for sibling sub-plans of the `req_id` still active (the check `SweepSubPlanChainsLocked` does make), `StartChain` sees only control-plane errors so it keeps arming and dispatching windows `1 .. K-1`, and `PoolReshardPush` / `PoolReshardRegisterRecv` seat them regardless of `chains[req_id].failed` (pinned by upstream's `FirstSubPlanFailureFailsTheRequestOnce`); the failed entry is swept after one `timeout_s_` of inactivity without checking whether seated `sub_sessions` are `Done()`, so a later sub-plan starts a fresh unanchored chain and an already-seated `!Done()` sibling hits `it == sub_plan_chains_.end()`, emitting a second `failed_recving_` (if draining with error) or false `done_sending_` / `done_recving_` on the failed chain (if `IsDraining()` with `OkStatus()`, which `CompleteReadWithDetails`'s deadline arm skips); a single-plan retry (`sub_plan_count <= 1`) under the same `req_id` calls `sub_plan_chains_.erase(req_id)` in `NoteSubPlanRegisteredLocked` (`:160-162`) so any still-seated stale sub-plan emits `done_*` / `failed_recving_` for the retry; and on an unanchored chain (`anchored = false`), `EndOp()` setting `done_ = true` between `RetireSettledSessionLocked` and `SweepSubPlanChainsLocked` makes the sweep clear `sub_sessions` while the next poll hits `!progress.anchored` ahead of `progress.failed` and emits `done_*` after `failed_recving_` | CONFIRMED (test) 2026-10-29 (`pool_reshard_chain_bughunt_test.cc`: `PoolReshardChainBughunt1B` 4/4 failing on unmodified `42dda542`), and **CONFIRMED (test) 2026-11-09 on unmodified `00e946e3` / re-run 2026-11-11 on `d3751fcb`** (`pool_reshard_stale_subplan_bughunt_test.cc`: `StaleSubPlanBughunt` 2 controls passing + 4 cases failing); **filed 2026-10-29** (bug 12 in `filed_bugs.md`, updated 2026-11-09); **still open at `d3751fcb`, changed shape** (`kv_cache_manager_with_transfer.cc` unchanged in `00e946e3..d3751fcb`; `25f7d8a7` merged `recv_chains_` / `send_chains_` into one `sub_plan_chains_` map holding the sub-plan sessions themselves; `RecordPoolReshardTerminalLocked` still sets `progress.failed = true` and inserts `failed_recving_` on the first non-OK sub-plan without checking whether any sibling `sub_sessions` entry is still `!Done()`; `SweepSubPlanChainsLocked` erases a `failed` or `completed` entry after one quiet `timeout_s_` without checking `!sub_session->Done()`, while `CompleteReadWithDetails` skips `IsDraining()` sessions — so an already-seated `!Done()` sibling settling after the sweep hits `it == sub_plan_chains_.end()` and emits a second `failed_recving_` or, if draining OK inside `EndOp` / `FinishPoolH2d`, emits `done_sending_` / `done_recving_` after `failed_recving_` with no retry needed, `NoteSubPlanRegisteredLocked` erases `sub_plan_chains_[req_id]` on a single-plan retry so a stale sub-plan settles into `it == sub_plan_chains_.end()`, an unanchored sub-plan whose `EndOp()` sets `done_ = true` in the `session->mu_` gap between `RetireSettledSessionLocked` (`:494`) and `SweepSubPlanChainsLocked` (`:278`) causes `:298` to clear `sub_sessions` and the next poll to hit `!progress.anchored` (`:201-212`, before `progress.failed` at `:219`) and emit `done_*` after `failed_recving_`, and a late-arriving sub-plan starts a fresh unanchored entry via `try_emplace` and is reported again; `PoolReshardPush` / `PoolReshardRegisterRecv` still seat later sub-plans regardless of `failed`) | mid-DMA free: yes for any multi-window request whose first failure has another window active (the F11 shape on pool reshard, with the engine recomputing into / freeing the destination blocks on `failed_recving`); post-sweep double `failed_recving_` or false `done_*` after failure: any failed multi-window chain whose sibling sub-plan is still `!Done()` (`in_flight_ > 0` or `IsDraining() && !Done()`) when `timeout_s_` sweeps the tombstone, any sparse unanchored sub-plan whose `EndOp()` lands between `RetireSettledSessionLocked` and `SweepSubPlanChainsLocked`, or a worker whose next sub-plan arrives > `timeout_s_` after the failure (cf. F12); single-plan retry collision: gated on same-`req_id` retry or multi-stage pipelined producer sharing `req_id`; same caller gate as F12 |
| F14 | `TransferReceiveSession::FinishLocked` records any first error even while draining (needed: the poll can `Finish()` OK before a failed H2D's callback, whose error must win), so it also admits an *external* `Finish(error)` after every H2D completed OK and the completed receive is reported `failed` instead of `received`. `ReshardReceiveSession::FinishLocked` has the same shape | CONFIRMED (test) 2026-10-30 (`transfer_receive_late_finish_bughunt_test.cc`: 1 control passing + 4 cases failing on unmodified `42dda542`); audited 2026-10-30: low severity; not yet filed; **partly fixed at `00e946e3` (unchanged at `d3751fcb`)**: `32568d35` guards `TransferReceiveSession::Start`'s pull-reply lambda with `if (!pull_status.ok() && !self->draining_) { self->FinishLocked(pull_status); }` ("a receive that already settled … keeps its verdict"), which closes case (3) — the only production-reachable path on the prefill-to-decode receiver — while `TransferReceiveSession::FinishLocked` and `ReshardReceiveSession::FinishLocked` themselves still record the error before `if (draining_) return;`, so cases (1) `EndIncomingPush`, (2) receive-side `UnregisterActivePlan`, (4) `~KVCacheManagerWithTransfer` and the `CompleteReadWithDetails` deadline-sweep race (`!session->IsDraining()` then `session->Finish(DeadlineExceeded("Transfer session timed out"))` in separate `session->mu_` scopes, now one arm for every session kind after `55c218d2`) remain; the **sender half is fixed** since `1523b07d` (`ReshardSendSession::Finish`'s `if (done_ \|\| finalizing_) return;` ahead of the status record; `FinishAfterLastPushFinalizingPreservesOkStatus`, which pinned it, was removed in `49e2c36c`). The reproducer's `EndIncomingPush` / `UnregisterActivePlan` / `ExecutePullRequest` entry points were renamed (`BeginIncomingPush` + `EndIncomingPush` free functions in `block_transport_session.cc`, `TransferReceiveSession::Start`), so it needs porting before a re-run | in production only the deadline sweep's multi-lock-scope check-then-`Finish` window in `CompleteReadWithDetails` when the last H2D/push finishes right at `deadline()` (case (3), the `Start` control reply failing on the return leg after every H2D completed, is closed by `32568d35`). (1) `end_incoming_push` needs a duplicate stream (no in-tree sender); (2) receive-side `UnregisterActivePlan` has no caller in tpu-sync or the three connector repos; (4) `~KVCacheManagerWithTransfer` is never published |
| F15 | `ReshardReceiveSession` leases one host staging slot per **pool** (`AcquireStagingSlot`, reached from `KVCacheManagerBase::GetBlockChunks` / `GetBlockArrayHostSpan` on the push thread) out of `num_host_layers()` slots when `HostLayersBounded()` (`num_staging_layers < num_layers`), holds it until the pool's H2D completes, and gates a higher-`order_rank` pool's H2D behind every lower-rank pool (`CollectEligiblePoolH2dsLocked`), deadlocking until `deadline_` (`DEADLINE_EXCEEDED: Timed out waiting for a free staging slot`) once gated rank-1 pools hold every slot; and on a **full host mirror** (`!HostLayersBounded()`, `47e9f200`), `AcquireStagingSlot` / `LookupStagingSlot` return `StaticHostLayer(pool_idx) = pool->storage_index` without leasing, so when a rank-1 pool arrives before a coarse rank-0 pool sharing `(storage_index, block_id)` and overlapping byte extents, rank 0's push overwrites rank 1's staged host bytes in `layers_[storage_index]` before rank 1's gated H2D runs | CONFIRMED (test) 2026-11-02 (`reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc`: 1 control passing + 1 case failing on unmodified `56a0269d`, re-run 2026-11-09 on `00e946e3`); **filed 2026-11-02** (bug 13 in `filed_bugs.md`); **changed shape at `d3751fcb`** (`47e9f200` stages full-mirror explicit pools in place via `StaticHostLayer(pool_idx)` and leases from `StagingLayerManager` only when `HostLayersBounded()`): re-run 2026-11-11 on unmodified `d3751fcb` with 1 control passing + **2 cases failing** — the bounded-staging (`num_staging_layers < num_layers`) rank-vs-slot deadlock still fires, and full-mirror in-place staging clobbers held rank-1 host bytes on aliased storages while reporting `done_recving` | bounded-staging deadlock: timing-dependent whenever `num_staging_layers < num_layers` and transferred pools exceed `num_host_layers()`; full-mirror aliased-storage host clobber: default `num_staging_layers` unset whenever a multi-tag single-uuid transfer (`vllm-torchtpu` Stage-3) has a coarse rank-0 pool and a rank-1 pool sharing `(storage_index, block_id)` with overlapping region bytes and rank 1's stream lands before rank 0's (the reproducer constructs two pools with fully overlapping bytes; whether a production pool table has a rank-0 and a rank-1 pool with overlapping live bytes is not verified) |
| F16 | `KVCacheManagerWithTransfer` UUID retirement omits `BlockTransport::ForgetPushProgress(uuid)` (and `ReleasePoolStagingLeases(uuid)`) when `StartRead` (`:920-921`) or `EmplaceRecvSessionLocked` (`:576`, via `RegisterRecv`) retires a settled session inline, and `CompleteReadWithDetails` (`:1046-1066`) guards its post-`mu_` `ForgetPushProgress(uuid)` / `ReleasePoolStagingLeases(uuid)` loop with a dead `std::erase_if` inside the same `mu_` critical section that just erased `uuid` from `sessions_` (`RegisterActivePlan` `:624`/`:635` → `:651` likewise seats the replacement under `mu_` and then calls `ForgetPushProgress(uuid)` unlocked). On a multi-layer receiver, stale or mid-transfer-wiped `layer_progress_` suppresses `OnLayerReceived` (H2D) on a layer while `OnBlockShardsReceived` still counts its blocks toward `network_completed_`, so `IsReadyToComplete()` returns `true` and `CompleteReadWithDetails` publishes `completions.received` (`done_recving`) with that layer's destination HBM blocks unwritten | CONFIRMED (test) 2026-11-03 (`kv_transfer_uuid_and_reshard_push_bughunt_test.cc`: `UuidRetirementBughunt` 1 control passing + 3 cases failing on unmodified `56a0269d`); not yet filed; **still open at `d3751fcb`** (re-run 2026-11-09 on `00e946e3` and 2026-11-11 on `d3751fcb`, 1 + 3 unchanged: `kv_cache_manager_with_transfer.cc` unchanged in `00e946e3..d3751fcb`) | gated on same-UUID reuse for the inline and cross-thread `CompleteReadWithDetails` cases (`tpu-inference`, `vllm-torchtpu` and `sglang-torchtpu` mint fresh 63/64-bit UUIDs per transfer today, though `KVCacheManagerWithTransfer` explicitly advertises settled-UUID reuse); `RegisterActivePlan`'s `:635` → `:651` unlocked `ForgetPushProgress(uuid)` after retiring a settled UUID can race against the first push of its *own* newly registered session with no third thread |
| F17 | `KVCacheManagerWithTransfer::PoolReshardPush` (`:690-724` at `56a0269d`) checks `sessions_.find(plan.uuid())` under `mu_` (`:694`), drops `mu_` with no pending-UUID reservation while running `ReshardSendSession::Create` (`:711-715`, contrast `PoolReshardRegisterRecv`'s `pending_pool_reshard_recvs_` at `:744`), and then blindly overwrites `sessions_[plan.uuid()] = state` (`:718`). Two concurrent `PoolReshardPush` RPCs for the same `uuid` both return `OK`, orphan the first live `ReshardSendSession` from `sessions_`, share `uuid`'s bounded `PoolStagingStorage` slot via idempotent `AcquirePoolStagingLease`, and free that slot in `SettleLocked` (`reshard_send_session.cc:593` at `56a0269d`, `:753` at `00e946e3`) when the first duplicate settles while the sibling push is still streaming from it, letting an unrelated transfer lease the same host staging memory (the F6 / F10 slot-aliasing shape) | CONFIRMED (test) 2026-11-03 (`kv_transfer_uuid_and_reshard_push_bughunt_test.cc`: `PoolReshardPushDuplicateUuidBughunt` 1 control passing + 1 case failing on unmodified `56a0269d`); not yet filed; **still open at `d3751fcb`** (re-run 2026-11-09 on `00e946e3` and 2026-11-11 on `d3751fcb`, 1 + 1 unchanged: `PoolReshardPush` `:732-774` still has no pending reservation across `CreateReshardSendSession` and overwrites `sessions_[plan.uuid()] = SessionEntry{...}` at `:767`) | needs two concurrent `START_TRANSFER` sender RPCs with the same `uuid` on one worker (e.g. gRPC/proxy retry on transient timeout while the first call is in `Create`, caller UUID collision, or two `src_units` routed to one worker endpoint); `ReshardCoordinator::RunSubPlan` dispatches once per `src_units[i]` with a fresh 63-bit `uuid` |
| F18 | `KVCacheStore::SaveRemote` records every remote write in `active_remote_writes_` (`kv_cache_store.cc:2358-2366`, introduced in `22a8bf22`) and calls `TakeRemoteWrite` only on synchronous exits (`!ack_res.ok()`, `all_exist`, `!existing_hashes.empty()`, `:2376-2387`); an accepted offer (`operation_id != 0`) settles asynchronously inside `HostOffloadBackend::BeginWriteRemote` (`host_offload_backend.cc:971-1089`), which releases the pins and updates `save_tracker` without erasing `active_remote_writes_`, so `~KVCacheStore` (`:986-1010`) walks every settled entry and calls `OnWriteRemoteVerdict(..., false)`, double-`Release`-ing the internal pin and stealing a live pin on a shared backend; and in the same `call.result.OnReady` continuation (`:983-986`), `absl::StatusCode::kCancelled` returns early while `lifetime->is_alive`, leaking the internal pin and leaving the hashes pending in `save_tracker_` / `sweep_tracker_` without polling `PollWriteRemote` | CONFIRMED (test) 2026-10-29 on unmodified `42dda542`, re-run 2026-11-09 on unmodified `00e946e3` (`kv_cache_store_remote_write_bughunt_test.cc`: `RemoteWriteSettlementTest` 1 control passing + 3 cases failing); not yet filed; **still open at `d3751fcb`** (`kv_cache_store.cc` and `host_offload_backend.cc` unchanged in `00e946e3..d3751fcb`) | yes for any `KVCacheStore` P2P caller using remote `Save(hashes, dst)` or the evict sweep's remote demotion (`vllm-torchtpu` and `sglang-torchtpu` do not use `KVCacheStore`): `active_remote_writes_` leaks on every accepted remote write (double-`Release` pin theft requires `backend()` outliving `KVCacheStore`), and `kCancelled` leaks the internal pin + wedges `save_tracker_` / `sweep_tracker_` whenever a destination ends the `WriteRemote` stream with `CANCELLED` after its ack |
| F19 | `KVCacheStoreClient::Fetch` (`kv_cache_store_client.cc:61-125`) sets no deadline on its `grpc::ClientContext` (unlike `WriteRemote` and `PollWriteRemote`), and nothing above it (`HostOffloadBackend::LoadRemoteBlocks`, `KVCacheStore::ReadRemote` / `Load`) bounds the call, so a silent source wedges the load forever, pins `dst_host_block_ids` in `RaidenController`, and causes retries of the same hash to fail `FAILED_PRECONDITION: Block is already loading`; and when `Fetch` fails (`host_offload_backend.cc:1244-1264`), `LoadRemoteBlocks` calls `raiden_controller_->DeallocateBlockIds(dst_host_block_ids)` at once even though the source pushes via planless explicit-destination `H2hWriteDirect` (`op = 6`, `uuid = 0`) and the receiving worker (`BlockTransportServerPushSession::StartStream` → `KVCacheManagerBase::GetBlockChunks`) only bounds-checks `dst_id` with no allocation or generation check, accepting late pushes into freed or reallocated host blocks (the F2 shape on the production `Fetch` path) | CONFIRMED (test) 2026-10-29 on unmodified `42dda542`, re-run 2026-11-09 on unmodified `00e946e3` (`kv_cache_store_fetch_bughunt_test.cc`: `FetchLifetimeTest` 3/3 failing + `FetchPushAfterFreeTest` 1/1 failing); promoted from "Open / not yet checked"; not yet filed; **still open at `d3751fcb`** (`kv_cache_store_client.cc` and `host_offload_backend.cc` unchanged in `00e946e3..d3751fcb`) | yes for any `KVCacheStore` peer load (`Load(hashes, slices, dev_ids)` / `ReadRemote` on `BlockStatus::REMOTE` slices; `vllm-torchtpu` and `sglang-torchtpu` do not use `KVCacheStore`): no-deadline wedge triggers whenever a peer store accepts `Fetch` and never replies; push-after-free triggers if the control-plane `Fetch` RPC fails (channel reset / proxy timeout, or once a client deadline is added without source-push fencing) while the source's `TransferBuffers` worker push is still in flight |
| F20 | `KVCacheManagerBase::host_block_manager_` (`LogicalBlockManager`, documented `"not thread-safe and requires external synchronization"`, `logical_block_manager.h:33-34`) is mutated with no lock by `KVCacheManagerBase::AllocateBlocks` (`kv_cache_manager_base.h:871-874`: `host_block_manager_->Allocate(num_blocks, /*lock=*/true)`), reached concurrently from per-connection `RawBufferTransport` worker threads on inbound auto-allocating pushes (`op = 1`, `block_transport_session.cc:386-389`), local `BlockTransport::H2hRead` pulls, and `D2hAutoAllocate` / `Unlock` / dynamic `StagingBlockAllocator`, handing out duplicate host block IDs to concurrent owners | CONFIRMED (test) 2026-10-29 on unmodified `42dda542`, re-run 2026-11-09 on unmodified `00e946e3` (`host_block_manager_race_bughunt_test.cc`: `HostBlockManagerRaceTest` 1 control passing + 1 case failing, handing out 1,990 duplicate host block IDs across 42,000 allocations); not yet filed; **still open at `d3751fcb`** (`AllocateBlocks` in `kv_cache_manager_base.h` unchanged) | only via the torch/jax `H2hWrite` (auto-allocating, no `dst_block_ids`) / `H2hRead` / `D2hAutoAllocate` bindings or dynamic `StagingBlockAllocator` (no caller in `tpu-inference`, `vllm-torchtpu`, `sglang-torchtpu`, or `KVCacheStore` — prefill-to-decode uses static `StagingBlockAllocator` slots by default, pool reshard uses `PoolStagingStorage`, and `KVCacheStore` allocates via `RaidenController`'s mutex-guarded `LogicalBlockManager` and pushes explicit `op = 6`) |
| C1 | *(caller: tpu-inference)* `tpu_raiden_connector.get_finished` drops tpu-sync's `failed_recving` list on both nodes and never drives vLLM's load-failure channel; vLLM frees transfer-held KV blocks only on a connector report. D half: failed receives leak D's blocks — since the connector's first commit `a342edc3` (2026-06-08). P half: since tpu-sync `4246613` (2026-08-24; see "tpu-sync side" under C1) an expired send is also in that list, so every never-pulled prefill leaks P's blocks; the connector's own `SendMeta.expiration_time` is set and never read | CONFIRMED (test) 2026-10-20 (`tpu_inference_connector_c1_test.py`, CPU: real vLLM `6185d73` scheduler + real tpu-inference `7ed46a6` connector, tpu-sync `0ac16d1`'s report as its own test shows it; 9/9 incl. 2 controls; 17/17 on 2026-10-22 with the `Caller.lean` connector variants); modelled in Lean 2026-10-22 (`Caller.lean`: `trace_dropFailed_*`, leaks absorbing, `contract_safe` / `mw_contract_safe` for `connectorTwoChannel`); connector unchanged at `main` `c2b062b` and still at `main` `ee8b4ac7` (2026-10-22; the unmerged upstream branch `fix/pd-disagg-kv-pull-hang`, `e7661c73`, applies the same two-channel fix shape to the sibling JAX-P2P `tpu_connector.py` only); not run on hardware; **filed 2026-10-22** (bug 8 in `filed_bugs.md`; the tpu-sync side not raised yet); **fix open as [PR #3918](https://github.com/vllm-project/tpu-inference/pull/3918)** (`f366ef52`, 2026-10-27, "[Disagg] Forward tpu-sync failed transfers in tpu_raiden_connector"; unmerged, not on `main` `7840339b` as of 2026-10-28, where the connector is still unchanged): a new `get_transfer_results()` forwards `failed_recving` as `finished_sending` on P and as `finished_recving` + `failed_recving` on D — an instance of `connectorTwoChannel` over `AggChannel.latchedReq` (`MultiWorker.lean`), with the D-side failure on vLLM's request-level `KVConnectorTransferResults.failed_recving` channel rather than `get_block_ids_with_load_errors` (requiring `ENABLE_MULTI_NUMA=0`, see F11, and a `get_transfer_results()`-capable vLLM ≥ `e7bb7e2f`); tpu-sync at `00e946e3` still files failed and expired sends in `failed_recving_` (`RetireSettledSessionLocked`: `(failed ? failed_recving_ : done_sending_).insert(req_id)`); PR #3918's merge status was not re-read at the `00e946e3` re-check (offline) | yes: any D-side pull failure (both nodes), any D full local prefix hit or D absence (P, after `TPU_P2P_WAIT_PULL_TIMEOUT` = 180 s), any client abort of a pull that later fails (D) |

---

## F1. `ValidateAndPinHostBlocks` could return a host block id that no longer holds the hash

- **Status:** **CONFIRMED (test)**, 2026-09-24, on unmodified `b68161a`;
  re-run on `d16701e` with the same result. Filed upstream 2026-10-19
  ([write-up](filed_bugs.md#4-kvcachestorevalidateandpinhostblocks-check-then-act-window-between-lookup-and-pin-can-return-a-stale-host_block_id-f1)),
  code unchanged through `0ac16d1`. **FIXED upstream** in `b3ea4dc`
  (2026-10-21, "Use single-lock local Lookup in ValidateAndPinHostBlocks and
  SaveRemote"), which is the fix proposed below. Output on the unfixed
  code, verbatim:
  ```
  [ RUN      ] KVCacheStorePinRaceTest.EvictAndReinsertBetweenLookupAndPinReturnsStaleHostBlockId
  tpu_sync/kv_cache/kv_cache_store_pin_race_test.cc:161: Failure
  Expected equality of these values:
    (*ids)[0]
      Which is: 5
    live_block
      Which is: 9
  ValidateAndPinHostBlocks returned host block 5 but h0 now lives at 9; the returned block holds hash 'other'. The pin protects block 9, not the block the reader will pull.
  [  FAILED  ] KVCacheStorePinRaceTest.EvictAndReinsertBetweenLookupAndPinReturnsStaleHostBlockId (10 ms)
  ```
- **Where:** `tpu_sync/kv_cache/kv_cache_store.cc:1623-1651`
  (`KVCacheStore::ValidateAndPinHostBlocks`, as fixed; the unfixed function was
  `:1615-1642` at `0ac16d1`).
- **Defect (through `0ac16d1`):** The function called `backend()->Lookup(hashes)`
  with default options (`pin_found = false` by default,
  `kv_cache_store_backend.h:114`), copied `host_block_id`, and only then called
  `backend()->Pin(hashes)`. The backend mutex was released between the two
  calls. The only lock held across them was `KVCacheStore::mutex_`, and
  neither of the following takes it:
  - `KVCacheStore::Evict` (`kv_cache_store.cc:1809`). The comment at `:1813-1815` says "We do
    not hold store mutex_". It is called from `SweepOnce` and
    `AllocateBlockIds`.
  - `KVCacheStore::Insert` (`kv_cache_store.cc:1017`).
- **Bad interleaving:**
  1. T1 runs `Lookup(h)` and gets host block 5.
  2. T2 evicts `h`; block 5 goes back to the pool.
  3. Block 5 is reused for another hash.
  4. T3 re-inserts `h` at block 9.
  5. T1's `Pin(h)` succeeds because pins are keyed by hash, and the function
     returns **5**.
  6. The reader pulls block 5, which holds another hash's bytes, while the pin
     protects block 9. The lease verdict is still `HELD`, so the wrong bytes
     are accepted silently.
- **Evidence that this is unintended:**
  - The Fetch path closes the same window with `pin_found = true` and a
    comment describing exactly this failure
    (`kv_cache_store_service.cc:461-474`).
  - The header promises "the authoritative source host_block_ids"
    (`kv_cache_store.h:388-391`, now also stating the single-Lookup,
    all-or-nothing contract).
- **Reachability:**
  - The source side runs whenever a peer calls `AcquireReadLease` on this
    controller; the hook is registered at `kv_cache_store.cc:1610-1621`.
  - The only initiator of that RPC in this tree is
    `RaidenController::ReadRemote`, which has **no production C++ caller**.
    `KVCacheStore::Load`'s remote branch uses `backend()->Load`. So in this
    snapshot the path is reachable only through the API and tests.
  - The race needs an evict **and** a re-insert of the same hash between two
    adjacent statements. Narrow, but real.
- **Fix (landed as `b3ea4dc`):** `LookupOptions{.enable_global = false,
  .pin_found = true}` and no separate `Pin` (`kv_cache_store.cc:1626-1629`);
  `HostOffloadBackend::Lookup`'s local prefix path matches and pins under one
  `mutex_` hold (`host_offload_backend.cc:211-237`), and the two error returns
  release the partial pins (`kv_cache_store.cc:1631, 1642`). This also removed
  a blocking registry RPC made while `mutex_` was held. An equivalent change
  (same options, releases by a collected list instead of by span) was in
  `candidate_fixes.patch` until 2026-10-22, when the hunk was dropped as
  redundant.
- **Repro:** `kv_cache_store_pin_race_test.cc`. A delegating backend runs the
  other threads' exact backend calls inside the window. Not re-run on
  `b3ea4dc` (no Bazel on this machine, and `2ed6f8f` itself changed the
  `KVCacheStoreBackend::Insert` signature the test's `WindowBackend`
  overrides, so it needs a one-line adaptation first). By construction it
  passes on the fixed code: the hook still fires after `Lookup` returns, but
  the pin is already held, so `Evict({h})` is refused and the hook returns
  (`kv_cache_store_pin_race_test.cc:134-138`) — the outcome §"Fix
  validation" observed with the patch applied.

## F2. Remote read keeps DMA-ing into destination blocks after it has already failed with a deadline error

- **Status:** **CONFIRMED (test)** for shapes A and B. Shape A first on
  `b68161a` (2026-09-24); both shapes on 2026-10-20 against upstream `main`
  `449b591` (controller sources rebuilt from `449b591`, leaf libraries from
  the `0ac16d1` OSS build; `raiden_controller.cc`'s `ReadRemote` region is
  unchanged between the two). **Proved in Lean** for shapes A and B
  (`TpuSyncVerify/Controller/ReadRemote.lean` on branch `controller-verification`, exhaustive over the reachable
  state space).
- **C++ test output** (unmodified code, verbatim, 2026-10-20 run; the tests
  are written so that a failure shows the defect):
  ```
  [ RUN      ] BugHuntTest.ReadRemoteDoesNotStartPullAfterDeadlineSettled
  [F2] settled after 1.001596645s with: ReadRemote exceeded the destination deadline (1s)
  [F2] pulls issued at settle: 0, pulls issued 4s later: 1
  raiden_controller_bughunt_test.cc:119: Failure
    pulls_after  Which is: 1
  A pull into dst host block 20 was issued AFTER ReadRemote settled with DeadlineExceeded.
  [ RUN      ] BugHuntTest.ReadRemoteSettlesDeadlineWhilePullStillInFlight
  [F2-B] settled after 1.002245805s with: ReadRemote exceeded the destination deadline (1s)
  [F2-B] at settle: pull started=1, pull finished=0
  [F2-B] pull finished 2.004212569s AFTER the caller was told the read failed
  raiden_controller_bughunt_test.cc:206: Failure
  Expected: (finished_after) <= (absl::ToUnixNanos(settled_at)), actual: 1792516287098830194 vs 1792516285094617625
  The DMA into dst host block 20 was still running when ReadRemote settled with DeadlineExceeded, and finished afterwards.
  ```
  Both set `RAIDEN_REMOTE_READ_DEADLINE_S=1`. Shape A delays the source's
  `AcquireReadLease` by 2.5 s with the existing `SetLeaseGrantedHookForTest`
  seam (`controller_service.h:106`). Shape B answers the acquire immediately
  and makes the worker's `H2hReadExplicit` take 3 s (`SlowReadMock`), so the
  deadline fires while the pull is in flight. That configuration only makes
  the tests fast. With defaults the deadline is the lease TTL plus 30 s
  (`raiden_controller.cc:107-130`), so shape A needs an acquire that takes
  longer than that (a hung source) and shape B a pull that outlives the
  deadline, which is the case the deadline exists for.
- **Where:** `tpu_sync/core/controller/raiden_controller.cc:1057-1145`
  (acquire callback and deadline thread), `:1150-1252` (`PullAndRelease`).
- **Defect:** A detached deadline thread calls `Settle(DeadlineExceeded)`
  (`:1125-1145`). Neither the acquire callback (`:1059-1118`) nor
  `PullAndRelease` (`:1202-1203`) checks `state->settled` before calling
  `TransferBuffers`, and an in-flight transfer is never cancelled.
  - If the acquire response arrives after the deadline, the pull **starts**
    after the caller has been told the read failed (shape A).
  - If the deadline fires during the pull, the caller is told the read
    failed while the DMA continues (shape B).
  - The comment in `PullAndRelease` says the host staging blocks are returned
    to the pool "once the read settles, success or failure" (`:1175-1179`; see
    also `raiden_controller.h:180-182`). A late pull
    therefore writes into staging blocks that were freed and reallocated,
    and into device blocks the caller may already be refilling.
- **Lean results:**
  - `shipping_counterexample`: shape A — `deadline, callerReuse,
    acquireReply true`.
  - The naive fix (check `settled` before the pull) closes A and not B
    (`naive_fix_counterexample`).
  - Deferring the deadline's settle while a pull is in flight has no
    violation anywhere in the state space (`deferred_settle_is_safe`). This
    is what the sibling `WriteRemote` path already does (R-D). Trade-off: a
    hung pull then holds the caller until it resolves. A complete fix needs
    cancellation, or settle-with-error while the blocks stay quarantined.
- **Reachability:** as F1: `ReadRemote` has no production caller in this
  tree.
- **Fix in `candidate_fixes.patch`:** the **naive** fix only (skip the pull if
  already settled; still release the lease). It closes shape A and is
  validated below; it does not close shape B.

## F3. Data race on `RemoteReadState::lease_id`

- **Status:** CONFIRMED (read). Undefined behaviour under the C++ memory
  model. Not tested; it needs a TSan build.
- **Where:** `raiden_controller.cc`
  - `uint64_t lease_id` is a plain field, not under `mu` (`:938`; `settled`
    at `:940` is guarded, `lease_id` is not).
  - Written on the gRPC callback thread at `:1075`.
  - Read on the detached deadline thread at `:1131`, `:1136`, `:1142` with no
    synchronisation.
- **Practical effect:** If the deadline thread reads 0, it skips the early
  release and the source keeps its pins for the full lease TTL.
- **Fix:** `std::atomic<uint64_t>`, or guard it with `mu`.

## F4. `TransferBuffers` leaks auto-allocated staging blocks on every early error

- **Status:** **CONFIRMED (test)** on `b68161a` / `d16701e` (code unchanged through `50b0774`), both halves; **FIXED upstream
  in `72255dd`** (2026-10-07, "Validate all workers before dispatching in
  `RaidenController::TransferBuffers` and release auto-allocated staging on
  error" = [PR #1105](https://github.com/google/tpu-sync/pull/1105), merged
  via copybara). At `2ed6f8f` (unchanged since `1fa06d1`) every worker is matched
  (`raiden_controller.cc:708-746`) before staging is auto-allocated
  (`:778-790`) and before any request is built (`:793-809`; a build failure
  frees the staging at `:804`); dispatch starts at `:811` and has no early
  return after it. Three upstream tests cover it
  (`TransferBuffersUnmatchedNodeIdDispatchesNoWorker`,
  `TransferBuffersUnmatchedNodeIdDoesNotLeakAutoStaging`,
  `TransferBuffersRequestBuildFailureReleasesAutoStaging` in
  `raiden_controller_test.cc`). The F4 hunk of `candidate_fixes.patch` is
  therefore obsolete. Evidence below is from the unfixed code, verbatim:
  ```
  [F4] locked host blocks before: 0, after 3 failed TransferBuffers: 3
  raiden_controller_bughunt_test.cc:143: Failure
    locked_after  Which is: 3
    locked_before Which is: 0
  Each failed TransferBuffers leaked its auto-allocated staging block.
  ```
  ```
  [F4-P2] copy jobs workers received for this failed transfer: worker_0=1 worker_1=0
  ```
  (the second after `TransferBuffers` returned `no destination worker group
  with node_id 1 ...`; `BugHuntTest.TransferBuffersDispatchesNoWorkerWhenAnyWorkerIsUnmatched`, on `d16701e`).
- **Where (at `50b0774`, before the fix):** `RaidenController::TransferBuffers`
  (broadcast overload), `raiden_controller.cc:579-799`. When the transfer is
  cross-node and touches local HBM with no staging supplied, it allocates
  staging itself (`:645-662`).
  - Only the success path frees it (`:786-796`).
  - The error returns at `:679` (no workers), `:728` / `:743` (node_id
    mismatch), `:774` (request build) and `:782` (no client) never free it.
  - Worse, `:728` / `:743` / `:774` can return **after** earlier workers were
    already dispatched (`:777`). Those transfers keep running un-awaited
    against the staging blocks and, on the destination side, against its
    buffers, while the caller already sees the error.
- **Reachability:**
  - **Leak half: no in-tree production trigger.** Auto-allocation needs a
    cross-node transfer that touches *local HBM* with no staging supplied.
    The production callers of the broadcast overload never do that: Fetch
    (`kv_cache_store_service.cc:542`, DRAM → remote DRAM), WriteRemote
    (`:805`, remote DRAM → DRAM), `host_offload_backend.cc:1168`, `:1260`
    (local DRAM → HBM), `:1342` (local HBM → DRAM). No Python binding or
    vllm-torchtpu code calls `TransferBuffers` directly.
  - **Orphaned-copy half: reachable from production.** Fetch and WriteRemote
    pass remote worker endpoints, so they go through the node_id matching
    loop. If some workers match and a later one does not,
    `raiden_controller.cc:722` / `:737` (at `50b0774`)
    return after the earlier workers were dispatched. Fetch then awaits the
    error, unpins its source blocks (`unpin_cleanup`,
    `kv_cache_store_service.cc:490`) and fails the RPC; the client's
    `LoadRemoteBlocks` frees `dst_host_block_ids`
    (`host_offload_backend.cc:1131-1142`). Meanwhile the dispatched worker
    copy may still be reading the source and writing the destination.
  - **Trigger:** the two sides disagree about which node_ids exist
    (config/topology mismatch). How likely that is in real deployments is
    not established.
- **Fix:** the cleaner shape — resolve and match every worker *before*
  allocating or dispatching anything
  ([google/tpu-sync#1105](https://github.com/google/tpu-sync/pull/1105)) —
  landed upstream as `72255dd` (the PR's copybara merge). The earlier `candidate_fixes.patch` hunk
  (route every error return through a helper that frees the staging after
  joining already-dispatched futures) was dropped from the patch on 2026-10-10.

---

## F5. One unresponsive producer pins every host staging slot; `StartRead` then rejects reads from every other producer

- **Status:** **CONFIRMED (test)**, owner-acknowledged. The test is the
  owners' own, parked as `DISABLED_` in `63da027` ("the written-down
  acceptance criteria for the per-peer admission work"). Run on unmodified
  `50b0774` with `--gtest_also_run_disabled_tests`, verbatim:
  ```
  [ RUN      ] ControlHandshakeTest.DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer
  E0000 00:00:1791391218.831497      12 transfer_receive_session.cc:226] StartRead: cannot stage 1 blocks for req_id=healthy0 (dynamic=false, free_host_blocks=0, free_slots=0, max_blocks=8)
  tpu_sync/kv_cache/kv_cache_manager_with_transfer_control_test.cc:1126: Failure
  Value of: consumer.has_recv(900)
    Actual: false
  Expected: true
  the read to the healthy peer was rejected outright because an unresponsive peer holds all 8 staging slots; no request to a healthy producer can even be attempted while another producer is wedged
  tpu_sync/kv_cache/kv_cache_manager_with_transfer_control_test.cc:1137: Failure
  Value of: failed_recving
  Expected: doesn't contain any element that is equal to "healthy0"
    Actual: { "healthy0" }, whose element #0 matches
  the healthy read failed immediately rather than being served
  [  FAILED  ] ControlHandshakeTest.DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer (48 ms)
  ```
- **Where:** `KVCacheManagerWithTransfer::StartRead` →
  `TransferReceiveSession::Create` → `AllocateStagingForLoad` →
  `StagingBlockAllocator::Acquire`, non-blocking and first-come-first-served
  (`kv_cache_manager_with_transfer.cc:909-918`,
  `transfer_receive_session.cc:208-235`,
  `tpu_sync/core/staging_arena.cc:514-518`, slot pop `:494-499`; the allocator moved
  there from `kv_cache_manager_with_transfer.cc` in `fc8cff9`).
  - The slot is taken *before* the handshake because the pull request
    carries the allocated host block ids (`transfer_receive_session.cc:523`);
    lazy allocation after the peer answers is not an option.
  - It is released only in `FinishLocked()` / `EndRecvOpLocked()` via
    `ReleaseStagingLocked()` once no copy or push is in flight
    (`Lifecycle.settleLocked` / the `inFlight = 0` rule of the Lean model), so
    cancelling a read to a dead peer does not return its slot before the
    deadline.
  - On `ResourceExhausted`, `StartRead` puts the request in `failed_recving_`
    and returns (`kv_cache_manager_with_transfer.cc:914-917`). No queueing: the
    read is rejected, not delayed.
  - Nothing bounds how many slots one peer may hold. The September changes
    bound how *long*: control-plane deadline (`430089c`, PR #1010, the
    thread-pool half of issue #888), per-read socket timeouts (`e7c933f`,
    `61b6c76`), release on a broken push stream (`4efb0dd`).
- **Reachability:** production path, every consumer `StartRead`. Trigger:
  one producer that accepts connections and never answers (crash without
  RST, partition, hung device) while the scheduler keeps routing reads to
  it; its reads then hold every slot for a deadline at a time and the decode
  host refuses KV transfers from the whole prefill fleet. Availability only,
  no memory-safety component.
- **Lean:** `PeerIsolation.trace_sick_peer_starves_staging_slots` is this
  test as a `decide` trace under `unboundedPerPeer` (`freeSlots = 0` even
  after `.cancel`, next healthy `StartRead` refused).
  `PeerIsolation.reachable_sick_staging_le_quota` and
  `PeerIsolation.reachable_quota_admits_healthy` state what the fix below
  guarantees over all reachable states: under `perPeerQuota c` the sick peer
  holds at most `c` slots, and a healthy peer holding fewer than `c` is
  admitted whenever `c + (slots healthy peers hold) < numSlots`. In words,
  cap `c` reserves `numSlots − c` slots for everyone else. It does not share
  fairly among many peers, it does not queue, and `c = numSlots` guarantees
  nothing (which is why the default is a no-op).
- **Fix (proposed; the patch `per_peer_staging_admission.patch` was validated on
  `50b0774`, re-based onto `1fa06d1`, and retired on 2026-10-16 when upstream
  moved `StagingBlockAllocator` to `tpu_sync/core/staging_arena.{h,cc}` in
  `fc8cff9` — the design and the proof stand, the diff is in the git history at
  tag `upstream-main-2026-10-10`):** `StagingBlockAllocator`
  keeps a count of live allocations per peer key.
  `Acquire(num_blocks, peer_key)` refuses with `kResourceExhausted` once the
  peer already holds `max_staged_reads_per_peer` allocations, even while
  slots are free; the charge is taken only on a successful allocation and
  dropped in `Allocation`'s RAII release under the same lock acquisition that
  returns the slot or the dynamic blocks, so count and pool cannot disagree.
  Keyless acquisitions (send side, incoming-push leases) are never capped.
  `StartRead` passes `remote_endpoint` as the key through
  `TransferReceiveSession::Create` / `AllocateStagingForLoad`; its failure
  path is unchanged and the log now names the peer and the reason. Knob:
  `TPU_RAIDEN_MAX_STAGED_READS_PER_PEER` (same pattern as
  `TPU_RAIDEN_DYNAMIC_HOST_STAGING`) plus an explicit `Create()` argument;
  unset or `0` leaves admission exactly as it is. The parked test is
  re-enabled under cap `kSlots − 1` with the owners' two healthy-peer
  assertions verbatim, plus assertions that the excess sick read is refused
  up front and that every per-peer charge is returned on settle; two
  `StagingBlockAllocatorTest` unit tests cover the allocator alone (cap
  refuses only the peer at cap, and only while it is at cap; no cap leaves
  admission unchanged).
- **Validation (2026-10-07, on `50b0774`, OSS build):** patch applied,
  tests run, upstream files restored. The re-enabled test alone, verbatim
  (log lines not about admission omitted):
  ```
  [ RUN      ] ControlHandshakeTest.SickPeerStarvesStagingSlotsForHealthyPeer
  I0000 00:00:1791391420.582191      12 kv_cache_manager_with_transfer.cc:1132] StagingBlockAllocator: capping staged reads per peer at 7 (num_slots=8)
  E0000 00:00:1791391420.583945      12 transfer_receive_session.cc:228] StartRead: cannot stage 1 blocks for req_id=sick7 from peer=127.0.0.1:46081: Peer 127.0.0.1:46081 already holds 7 staged reads (cap 7); refusing to stage more (dynamic=false, free_host_blocks=0, free_slots=1, held_by_peer=7, max_blocks=8)
  I0000 00:00:1791391420.584110      12 kv_cache_manager_with_transfer.cc:858] StartRead (initiate): req_id=healthy0, uuid=900, numa=-1
  I0000 00:00:1791391420.584206      12 transfer_receive_session.cc:537] StartRead (connecting): req_id=healthy0, uuid=900, numa=-1
  [       OK ] ControlHandshakeTest.SickPeerStarvesStagingSlotsForHealthyPeer (48 ms)
  ```
  The full targets (the two that carry the new tests plus every other
  hardware-free test that links the allocator), verbatim:
  ```
  //tpu_sync/core:kv_cache_manager_with_transfer_ip_test          (cached) PASSED in 0.1s
  //tpu_sync/core:kv_cache_manager_with_transfer_control_test              PASSED in 47.8s
  //tpu_sync/core:kv_cache_manager_with_transfer_pool_reshard_test         PASSED in 22.6s
  //tpu_sync/core:kv_cache_manager_with_transfer_send_drain_test           PASSED in 43.6s
  //tpu_sync/core:transfer_send_session_test                               PASSED in 22.4s

  Executed 4 out of 5 tests: 5 tests pass.
  ```
  (23 tests in the control target, the 22 existing plus the re-enabled one;
  12 in `transfer_send_session_test`, 10 plus the two new
  `StagingBlockAllocatorTest` cases.) `kv_cache_manager_with_transfer_test`
  is `no_oss` / `requires-jellyfish` (TPU hardware) and was not run. The OSS
  build needs a compiler the `.bazelrc` `oss` config can find; here
  `--action_env=CC=clang-21 --action_env=CXX=clang++-21 --repo_env=CC=clang-21`.
- **Open design choices for the owners:** refuse at the cap (as patched,
  matching today's `StartRead` contract and the proof) vs. wait; env knob vs.
  a constructor / Python parameter. A self-sizing share (cap derived from the
  number of peers currently holding staging) is a natural follow-up and would
  need its own proof.

---

## F6. `PoolReshardRegisterRecv`: duplicate registration frees the active session's staging lease

- **Status:** **CONFIRMED (read)** at `1fa06d1`; reproduced by the reporter
  on a bounded-staging receiver (`RegisterPools(..., staging_leases=2)`),
  output not pasted here. Found during the Lean formalization of the pool
  reshard receive path. Filed upstream 2026-10-13 ([write-up](filed_bugs.md#2-poolreshardregisterrecv-duplicate-registration-frees-the-active-sessions-staging-lease-f6));
  **FIXED upstream in `8653373`** (2026-10-13): `ReshardReceiveSession::Create`
  now claims the `uuid` with `RegisterActivePlanDirect` before constructing the
  session and acquiring staging, and rolls the claim back with
  `UnregisterActivePlanDirect` when `AcquireStagingLeases` fails
  (`reshard_receive_session.cc:376-388` at `0ac16d1`); the pool-lease
  forwarders left `StagingBlockAllocator`. Three regression tests:
  `PoolStagingRecvRegistrationTest.DuplicatePoolRecvRegistrationKeepsOriginalStagingLease`,
  `…ConcurrentDuplicatePoolRecvRegistrationKeepsWinnerStagingLease`,
  `…StagingAcquireFailureReleasesUuidClaim` in
  `kv_cache_manager_with_transfer_pool_reshard_test.cc`. The description
  below is of the unfixed code at `1fa06d1`.
- **Where (at `1fa06d1`, before the fix):** two layers disagree about who owns a staging lease.
  1. The per-storage lease table is keyed by `uuid` only, not by session
     instance: `KVCacheManagerBase::AcquirePoolStagingLease`
     (`kv_cache_manager_base.cc:2087-2144`) is idempotent per `uuid` — it
     returns `OK` when `pool_staging_[s].leases[uuid]` already covers the
     requested blocks (`:2096-2114`) — and `ReleasePoolStagingLeases(uuid)`
     (`:2146-2162`) unconditionally erases `leases[uuid]` and returns all of
     its slots to `free_slots` (`:2151-2157`). `StagingBlockAllocator`
     forwards both (`kv_cache_manager_with_transfer.cc:1267-1281`).
  2. `ReshardReceiveSession` is a per-call heap object that acquires staging
     *before* `uuid` uniqueness is enforced. `PoolReshardRegisterRecv`
     (`kv_cache_manager_with_transfer.cc:648-683`) checks
     `active_pool_reshard_recvs_` under `mu_` (`:655-669`), but that table
     only holds sessions whose registration already completed (`:678-681`).
     `mu_` is released while `ReshardReceiveSession::Create`
     (`reshard_receive_session.cc:351-377`) constructs the object (`:372-374`)
     and calls `AcquireStagingLeases` (`:375` → `:407-444`), which sets
     `staging_released_ = false` (`:419`) and leases per storage (`:437-438`,
     possibly blocking on `staging_cv_` for free slots,
     `kv_cache_manager_base.cc:2122-2131`) — all before
     `RegisterActivePlanDirect(uuid)` claims the `uuid` in `active_plans_`
     (`kv_cache_manager_with_transfer.cc:676-677`).
     (`ReshardSendSession::Create` does it the other way round and claims the
     `uuid` first, `reshard_send_session.cc:138-139`.)
- **Sequence** (two `PoolReshardRegisterRecv` calls for the same `uuid = U`
  overlapping in that window, or one call for a `U` already in
  `active_plans_`):
  1. Session S1 acquires `leases[U]`, `staging_released_ = false`.
  2. Session S2, a distinct object for the same `U`, also passes `Create`:
     `AcquirePoolStagingLease(U)` finds `leases[U]` populated and returns
     `OK`; S2 sets `staging_released_ = false`.
  3. S2 is rejected: `RegisterActivePlanDirect(U)` returns `ALREADY_EXISTS`.
  4. S2 goes out of scope: `~ReshardReceiveSession` → `ReleaseStaging()`
     (`reshard_receive_session.h:71`, `.cc:446-455`) →
     `ReleasePoolStagingLeases(U)` erases `leases[U]` and frees S1's slots
     while S1 is still active.
- **Impact:**
  - the active session fails: incoming pushes for `U` can no longer resolve
    their host staging buffer (`GetBlockChunks(uuid = U)` returns no chunks);
  - **silent host-buffer aliasing:** `U`'s physical slots are back in
    `free_slots`, so the next transfer `U2` is leased the same host memory
    while `U` is still active, with no error raised.
- **Reachability:** production path, every bounded-staging pool-reshard
  receiver. Trigger: a duplicate `PoolReshardRegisterRecv` (coordinator retry)
  for an active `uuid`, or two concurrent registrations for the same `uuid`
  while both wait on staging slots — one returns `OK`, the loser returns
  `ALREADY_EXISTS` and its destructor erases the winner's lease.
- **Reporter's observations** (bounded receiver with `staging_leases=2`):
  with `uuid=4001` holding a lease and registered in `active_plans_`, a
  rejected `PoolReshardRegisterRecv(4001)` moves `free_slots` from 1 back to
  2, `GetBlockChunks(uuid=4001)` returns 0 chunks, and a following
  `PoolReshardRegisterRecv(4002)` receives the same physical slot pointer as
  `4001`; with two threads calling `PoolReshardRegisterRecv(4001)`
  concurrently while waiting on slots, one returns `OK`, one
  `ALREADY_EXISTS`, and `free_slots` becomes 2 with `GetBlockChunks(4001)`
  empty.
- **Fix (proposed, in preparation):** claim the `uuid` via
  `RegisterActivePlanDirect` in `ReshardReceiveSession::Create` before
  constructing the session and acquiring staging, rolling back with
  `UnregisterActivePlanDirect` if `AcquireStagingLeases` fails — the order
  `ReshardSendSession::Create` already uses.
- **Lean:** the pool-reshard path is outside the prefill-to-decode model
  (`tpu_sync/formal_verification/docs/transfer/prefill_decode.md` §Boundaries, row 1); `Transfer/Session.lean`
  covers only the per-session settle protocol, whose `hasStaging` token is
  per *instance* — exactly the property the shared `uuid`-keyed lease table
  breaks. A `UuidTable`-style model of `active_plans_` + `pool_staging_`
  would make this a one-step counterexample (`registerRecv` of a live uuid
  followed by the loser's `release`); not written.

---

## F7. `end_incoming_push`: a failed push on a `ReshardReceiveSession` is not finished, pinning staging until the deadline

- **Status:** **CONFIRMED (read)** at `0ac16d1`; witnessed in Lean as R1
  (`trace_r1_failed_incoming_push` in `tpu_sync/formal_verification/TpuSyncVerify/Transfer/Reshard/Receive.lean`,
  tracked as R1 in `tpu_sync/formal_verification/docs/transfer/reshard.md`). Filed upstream 2026-10-16
  ([write-up](filed_bugs.md#3-reshardreceivesession-ignores-a-failed-endincomingpush-and-pins-poolstagingstorage-until-timeout-r1));
  **FIXED upstream in `fdeebcd`** (2026-10-16): the reshard branch of the hook
  now calls `reshard_session->Finish(status)` when `!status.ok()` before
  `EndRecvOp()`, with one regression test,
  `PoolReshardRecvTest.FailedIncomingPushReleasesStagingLeaseBeforeDeadline`
  in `kv_cache_manager_with_transfer_pool_reshard_test.cc`. The description
  below is of the unfixed code at `0ac16d1`.
- **Where (at `0ac16d1`, before the fix):** `KVCacheManagerWithTransfer::InitializeBaseHooks()`
  (`kv_cache_manager_with_transfer.cc:250-290` there; `:250-296` at `2ed6f8f`).
  The `TransferReceiveSession` branch calls `DeferUnregisterOnSettle();
  Finish(status)` on a failed push before `EndRecvOp()` (`:266-271`); the
  `ReshardReceiveSession` branch called `EndRecvOp()` only and ignored
  `status` (`:279-289` there; the fix is `:279-285` at `2ed6f8f`).
- **Sequence:** the sender does not retry a failed push
  (`ReshardSendSession::RecordPushCompletion`, `reshard_send_session.cc:351-373`,
  latches `finalizing_` on the first error), and
  `ReshardReceiveSession::EndRecvOpLocked` (`reshard_receive_session.cc:495-505`)
  settles only when `draining_ && in_flight_ == 0`. So a failed push drops
  `in_flight_` to 0 with `draining_ == false` and `status_ == OK`; `Done()` is
  false, `UnregisterSettledPlan` is skipped, and the hook returns `OK`.
- **Impact:** the session's `PoolStagingLease` keeps its bounded slots and
  `active_plans_[uuid]` stays registered until the deadline sweep
  (`kv_cache_manager_with_transfer.cc:1043-1072`) fires at `timeout_s_`
  (default 120 s) and reports `DEADLINE_EXCEEDED: Pool reshard receive timed
  out`, masking the original error; meanwhile later pool reshards wait on
  `AcquirePoolStagingLease` up to `pool_staging_lease_timeout()` (10 s) and
  fail with `RESOURCE_EXHAUSTED`.
- **Fix:** `if (!status.ok()) reshard_session->Finish(status);` before
  `reshard_session->EndRecvOp()` — as landed in `fdeebcd`.

---

## F8. `ExecutePoolReshard`: sender-dispatch failure leaks the registry claim

- **Status:** **CONFIRMED (test)** at `0ac16d1`, 2026-10-17, by
  `ReshardBughuntTest.R2b_SenderDispatchFailureOrphansRegistryClaimAndArmedReceiver`
  in `reshard_bughunt_test.cc` (tracked as R2b in `tpu_sync/formal_verification/docs/transfer/reshard.md`,
  witnessed in Lean by `trace_r2b_dispatch_failure_orphans_receivers_and_claim`
  in `Coordinator.lean`). Filed upstream 2026-10-19
  ([write-up](filed_bugs.md#5-reshardcoordinatorexecutepoolreshard-sender-dispatch-failure-returns-without-calling-abandonclaim-leaking-the-registry-claim-r2b));
  fix pending. **Still open at `42dda542` (2026-10-28), code moved:**
  `09a42d4e` (2026-10-25, bounded-staging sub-transfer chains) left
  `ExecutePoolReshard` as the per-request shell (metadata, uuid, claim owner,
  `PlanSubTransfers`) and moved the plan / arm / dispatch sequence into
  `ReshardCoordinator::RunSubPlan(ctx, index)`, run inline for sub-plan 0 and
  on a coordinator thread for the rest. There the plan-build, receiver-arm and
  null-controller returns call `registry_->AbandonClaim(args.req_id, uuid,
  ctx->claim_owner)` — now only when `index == 0` — and the sender-status
  loop (`for (const absl::Status& status : sender_status) if (!status.ok())
  return status;`) still does not. The reproducer drives
  `ReshardService::HandleControllerCommand` over a fake worker transport and
  does not name the private method, so the split does not touch it; not
  rebuilt at `42dda542`.
  Output, verbatim (built against the warm OSS Bazel outputs with
  the recipe in `notes/empirical/oss-bazel-test-recipe.md`; all four tests in
  the file pass):
  ```
  [ RUN      ] ReshardBughuntTest.R2b_SenderDispatchFailureOrphansRegistryClaimAndArmedReceiver
  [       OK ] ReshardBughuntTest.R2b_SenderDispatchFailureOrphansRegistryClaimAndArmedReceiver (0 ms)
  ```
  (The test asserts the defect: after the injected sender failure,
  `GetRequestBlockStatus` is `STATUS_CLAIMED` and `CancelIfUnclaimed` returns
  `"false"`; it passes on unmodified code and would fail once the fix lands.)
- **Where (at `2ed6f8f`, unchanged since `0ac16d1`):** `ReshardCoordinator::ExecutePoolReshard`
  (`reshard_coordinator.cc:415-544`). `BuildPoolReshardPlan` claims
  `(req_id, uuid)` under a fresh `claim_owner` (`:417-420`). The three error
  returns that follow — plan build (`:421-424`), receiver arm (`:458-463`),
  null controller (`:483-487`) — call `registry_->AbandonClaim(args.req_id,
  uuid, claim_owner)`. The sender-dispatch return (`:542-544`) does not.
- **Impact:** the sender never started, so no `Complete` vote will arrive; the
  claim stays in `claimed_owners_` and the request reads `STATUS_CLAIMED` until
  `ttl_s_`. In that window `CancelIfUnclaimed`
  (`request_block_registry.cc:388-390`) returns `false` and `Register` for the
  same `(req_id, uuid)` is refused (`:281-285`). The receivers armed in the
  previous step are left waiting for pushes that never come until their own
  `timeout_s_` (that half is R2a, not filed).
- **Fix (proposed):** call `registry_->AbandonClaim(args.req_id, uuid,
  claim_owner);` before `return status;` at `:542-544`, matching the other
  three paths.
- **Sibling candidates, same file family, confirmed by the same test file but
  not filed:** R7b (`AbandonClaim` leaves `completed_units_` behind), R7a
  (owner-unscoped `completed_units_` in `Complete`). See
  `tpu_sync/formal_verification/docs/transfer/reshard.md`. R8 is filed as F9 below.

---

## F9. `LookupAndClaim`: claim TTL and registration TTL diverge, purging claimed rows

- **Status:** **CONFIRMED (test)** at `0ac16d1`, 2026-10-17, by
  `ReshardBughuntTest.R8_SplitTtlEvictsRequestBlocksWhileClaimIsStillActive`
  in `reshard_bughunt_test.cc` (R8 in `tpu_sync/formal_verification/docs/transfer/reshard.md`, witnessed in
  Lean by `mutant_split_ttl_purges_request_blocks_while_claim_active` in
  `Registry.lean`). Filed upstream 2026-10-19
  ([write-up](filed_bugs.md#6-requestblockregistrylookupandclaim-claiming-a-request-does-not-refresh-request_blocks_-ttl-evicting-producer-registrations-while-the-claim-is-active-r8));
  **FIXED upstream** in `63c6447c` (2026-11-10, "Refresh producer block
  registration TTL when a reshard request claims it", which implements the
  proposed fix below: `LookupAndClaim` collects `claimed_rows` and sets
  `registration.expires_at = now + ttl_s_;` on every claimed `request_blocks_`
  row alongside `claimed_[lifecycle_key] = now + ttl_s_;`, with regression tests
  `ReshardStackTest.ClaimRefreshesRegistrationTtlForSiblingStageAndCompletion`
  and `FailedClaimDoesNotRefreshPartialRegistrationTtl`). Output on the unfixed
  code, verbatim (same run as F8):
  ```
  [ RUN      ] ReshardBughuntTest.R8_SplitTtlEvictsRequestBlocksWhileClaimIsStillActive
  [       OK ] ReshardBughuntTest.R8_SplitTtlEvictsRequestBlocksWhileClaimIsStillActive (1 ms)
  ```
  (With `ttl_s = 60`: register at `t = 1000`, stage 0 claims at `t = 1040`,
  at `t = 1070` the status probe still reads `STATUS_CLAIMED` while stage 1's
  `CoordinateTransfer` fails with `"Missing producer block registration"`.)
- **Where (at `2ed6f8f`, unchanged since `0ac16d1`):** `request_block_registry.cc`. `Register` stamps
  `expires_at = now + ttl_s_` on each `request_blocks_` row (`:263`).
  `LookupAndClaim` (`:440-491`) reads those rows (`:462-470`), then sets
  `claimed_[key] = now + ttl_s_` (`:473`) and refreshes `completed_units_`
  (`:478`) but never touches the rows' `expires_at`.
  `PurgeExpiredRequestBlocksLocked` (`:61-69`) runs at the top of every
  operation and erases rows with `expires_at <= now` regardless of `claimed_`.
- **Impact:** in `[t_reg + ttl, t_claim + ttl)` the request is claimed with no
  backing registration. `Status` (`:421-423`) reports `STATUS_CLAIMED`,
  `CancelIfUnclaimed` (`:388-390`) refuses, and any further `LookupAndClaim`
  (`:464-468`) — a sibling pipelined stage, or the retry in upstream's own
  `AbandonedStageLeavesTheSiblingClaimInPlace` — fails. With the default
  `ttl_s_ = 600` this needs a claim that lands more than ten minutes after
  registration; with shorter TTLs (tests use 60) it is a narrow queueing delay.
- **Fix (proposed):** in `LookupAndClaim`, set `it->second.expires_at = now +
  ttl_s_` on each claimed row when setting `claimed_[key]`; or make
  `PurgeExpiredRequestBlocksLocked` skip rows whose `(req_id, uuid)` is in
  `claimed_`.

---

## F10. `ReshardSendSession`: the first failed push unregisters the plan while siblings are in flight, and hands the uuid's staging lease to a retry

- **Status:** **CONFIRMED (test)** 2026-10-20 by
  `ReshardSendSessionBughuntTest.R6_FirstFailedPushUnregistersPlanWhileSiblingInFlightAndReopensF6`
  in `reshard_send_session_bughunt_test.cc` (R6 in `tpu_sync/formal_verification/docs/transfer/reshard.md`,
  witnessed in Lean by `trace_early_unregister_on_error_vs_onSettle` in
  `Send.lean`). Built against the `1fa06d1` OSS outputs and headers (the warm
  build on this machine); `RecordPushCompletion`, `Create`'s
  register-before-lease order, `AcquirePoolStagingLease` /
  `ReleasePoolStagingLeases` and `UnregisterActivePlanDirect` are unchanged
  through upstream `2ed6f8f` (the session's later diffs are data-connection
  reuse and the `StagingBlockAllocator` → `KVCacheManagerBase` forwarding move).
  **Filed upstream 2026-10-23** (bug 9 in [`filed_bugs.md`](filed_bugs.md)).
  **FIXED upstream in `1523b07d` (2026-10-30)**, read at `56a0269d`: the plan
  moved into the session (`plan()` returns it until `Done()`), so there is no
  `UnregisterActivePlan` call left in `RecordPushCompletion` or `EndOp`;
  `Create` neither registers a plan nor leases staging (each pool's lease is
  taken in `ExecutePushPipeline`), and `PoolReshardPush` refuses a same-uuid
  retry while the prior session is `!Done()`, so the retry can no longer share
  the draining session's lease on the manager path. The reproducer below drove
  the removed path and was not re-run. Output, verbatim (the test asserts the defect, so it passes
  on unmodified code):
  ```
  [ RUN      ] ReshardSendSessionBughuntTest.R6_FirstFailedPushUnregistersPlanWhileSiblingInFlightAndReopensF6
  E0000 ... reshard_send_session.cc:351] Pool reshard send failed uuid=6001 req_id=pool_reshard_req_6001: UNAVAILABLE: peer 1 refused
  [       OK ] ReshardSendSessionBughuntTest.R6_FirstFailedPushUnregistersPlanWhileSiblingInFlightAndReopensF6 (7 ms)
  ```
  The test drives the session's op accounting through upstream's own
  `ReshardSendSessionTestPeer` friend seam (`reshard_send_session.h`), because
  `ExecutePush` needs real D2H copies.
- **Where (at `2ed6f8f`, unchanged since `0ac16d1`):** `ReshardSendSession::RecordPushCompletion`
  (`reshard_send_session.cc:351-392`). On the first `!status.ok()` it latches
  `finalizing_` and calls `manager.UnregisterActivePlan(uuid_)` (`:366-367`,
  `:383`) regardless of `in_flight_`. `EndOp` (`:418-440`) already unregisters
  when the last op of a finalizing send is counted out, so the early call is
  redundant on the success path and only differs when siblings are in flight.
- **History and attribution:** the early `UnregisterActivePlan` on the first
  failed push predates the `ReshardSendSession` extraction (`1673c9b`,
  2026-09-19; it was already in `FinishPoolReshardSend` at `674e7fb`). Before
  `3d1b5d4` (2026-09-24) `ReleasePoolStagingLeases(uuid)` also ran on the first
  failure; `3d1b5d4` moved the lease release to `SettleLocked` (and added
  `EndOp`'s settle-time unregister) without removing `RecordPushCompletion`'s
  first-failure unregister, opening the lease-aliasing window between the first
  failed push and settle.
- **Sequence shown by the test** (bounded staging, `staging_leases = 2`,
  one source block, two destination peers so `remaining_pool_peer_pushes = 2`):
  1. Session A: `Create` registers plan `uuid`; its lease takes one slot
     (`free_slots` 2 → 1); the push to peer 1 resolves one chunk at slot `P`.
  2. Peer 1's push fails; peer 2's is still in flight. `in_flight_ == 1`,
     `!Done()`, and **`HasActivePlan(uuid) == false`**.
  3. A sibling resolving its chunks now gets none (`GetBlockChunks(uuid)`
     empty). On a full-mirror storage the same call falls back to un-sliced
     full-block extents instead (`kv_cache_manager_base.cc:3307-3326`).
  4. A retry `Create` for the same `uuid` **succeeds** (it would be
     `ALREADY_EXISTS` while the plan is registered — the guard `8653373` relies
     on for the receiver). Its `AcquirePoolStagingLease(uuid)` is idempotent
     per uuid, so it shares A's slot: `free_slots` stays 1, the retry's chunk
     is `P`.
  5. Peer 2's push returns; A settles; `ReleaseLeasesLocked` →
     `ReleasePoolStagingLeases(uuid)` frees the shared slot: `free_slots`
     back to 2 while the retry is live, and the retry's `GetBlockChunks(uuid)`
     is now empty.
  6. A third transfer (`uuid + 1`) leases the same slot `P` — the F6
     aliasing, on the sender.
- **Impact:** a send that fails on one peer with others in flight drops its
  plan early; with a same-uuid retry arriving before it drains (the
  coordinator's own tests retry under the same uuid), the retry's host staging
  is released under it and reallocated to an unrelated transfer, silently.
  Without the retry the harm is limited: later chunk resolution in the failed
  session fails (bounded) or falls back to whole blocks (full mirror), and the
  socket adapter's per-uuid failure latch cancels the sibling posts anyway.
- **Fix (proposed):** drop the early `UnregisterActivePlan` in
  `RecordPushCompletion` (keep `finalizing_`); let `EndOp` unregister at
  settle, as it already does for sends finished from outside. Alternatively
  make `AcquirePoolStagingLease` refuse a uuid whose lease is held by a
  session that has not settled.

---

## F11. `NumaAwareKVCacheManager::CompleteReadRaw` emits `failed_recving` while sibling sub-managers still have DMAs in flight, and never erases `failed_recving_set_` on failure

- **Status:** **CONFIRMED (test)** 2026-10-29 on unmodified `42dda542`
  (`numa_kv_cache_manager_bughunt_test.cc`, 4/4 cases; found while auditing
  [tpu-inference PR #3918](https://github.com/vllm-project/tpu-inference/pull/3918)
  against `Caller.lean` / `Caller/MultiWorker.lean`'s boundary assumptions).
  **Filed upstream 2026-10-29** (bug 10 in [`filed_bugs.md`](filed_bugs.md)).
  **FIXED upstream in `c0e8e686` (2026-10-29)**, read at `56a0269d`:
  `failed_recving_set_` is gone, `failed_recving_counts_` joins the two done
  maps, and a `process_completion` lambda emits nothing for a `req_id` until
  `s_count + r_count + f_count >= expected`, reports `failed_recving` if any
  sub-manager failed, and erases all four map entries — the
  `NumaPolicy.settledCounts` barrier of `Caller/NumaBarrier.lean`. Five rewritten
  or new `KVCacheManagerWrapperTest` cases pin it (`FailureWaitsForSiblingSubManagersBeforeEmittingFailedRecving`,
  `FailureWhenAllSubManagersFailEmitsFailedRecvingOnce`,
  `RecvFirstThenFailureWaitsForSubManagersAndEmitsFailure`,
  `SendFailureWaitsForSiblingSubManagersBeforeEmittingFailedRecving`,
  `SingleSubManagerFailureEmitsImmediatelyAndCleansUp`; the pre-existing
  `VotingConsensusPromotesDone{Recving,Sending}OnlyWhenAllAgree` still hold);
  the former `AnyFailureImmediatelyTriggersFailedRecvingAndSuppressesFutureAcks`
  was rewritten into the first of them. The reproducer was not re-run. Output, verbatim (all four tests assert the safety contract
  and therefore fail on unmodified code):
  ```
  [ RUN      ] NumaKVCacheManagerBughuntTest.FailedRecvSubManagerDoesNotSettleWhileSiblingH2dInFlight
  I0000 00:00:1793242868.767765    1441 transfer_receive_session.cc:821] OnLayerReceived (H2D copy start) layer 0: req_id=req_recv, uuid=101, numa=-1
  I0000 00:00:1793242868.767855    1441 transfer_receive_session.cc:821] OnLayerReceived (H2D copy start) layer 0: req_id=req_recv, uuid=101, numa=-1
  E0000 00:00:1793242868.767916    1441 transfer_receive_session.cc:892] OnLayerReceived (H2D copy failed) layer 0 for req_id: req_recv, error: INTERNAL: sub0 h2d failed
  W0000 00:00:1793242868.768045    1441 kv_cache_manager_with_transfer.cc:1287] Transfer failed: req_id=req_recv code=INTERNAL phase=h2d elapsed_ms=0.333251 reason=sub0 h2d failed
  I0000 00:00:1793242868.768121    1441 transfer_receive_session.cc:881] OnLayerReceived (H2D copy complete) layer 0: req_id=req_recv, numa=-1
  I0000 00:00:1793242868.768163    1441 transfer_receive_session.cc:914] All layers H2D copy complete: req_id=req_recv
  tpu_sync/frameworks/jax/numa_kv_cache_manager_bughunt_test.cc:295: Failure
  Value of: f1.empty()
    Actual: false
  Expected: true
  CompleteReadRaw emitted failed_recving while sub1 still had an in-flight H2D DMA; recycled HBM byte became 0x55 instead of 0xaa

  [  FAILED  ] NumaKVCacheManagerBughuntTest.FailedRecvSubManagerDoesNotSettleWhileSiblingH2dInFlight (15 ms)
  [ RUN      ] NumaKVCacheManagerBughuntTest.FailedSendSubManagerDoesNotSettleWhileSiblingD2hInFlight
  I0000 00:00:1793242868.773835    1441 kv_cache_manager_with_transfer.cc:111] RAIDEN_TIMING event=producer_register req_id=req_send uuid=202 node_id=0 blocks=1 enqueue_ms=0.03596 failed=0
  I0000 00:00:1793242868.773946    1441 kv_cache_manager_with_transfer.cc:111] RAIDEN_TIMING event=producer_register req_id=req_send uuid=202 node_id=0 blocks=1 enqueue_ms=0.02383 failed=0
  I0000 00:00:1793242868.774026    1441 transfer_send_session.cc:523] StartPush (D2H start) layer 0: uuid=202, numa=-1
  W0000 00:00:1793242868.774146    1441 kv_cache_manager_with_transfer.cc:1287] Transfer failed: req_id=req_send code=CANCELLED phase=await_pull elapsed_ms=0.57406 reason=sub0 peer reset
  tpu_sync/frameworks/jax/numa_kv_cache_manager_bughunt_test.cc:333: Failure
  Value of: f1.empty()
    Actual: false
  Expected: true
  CompleteReadRaw emitted failed_recving while sub1 still had an in-flight D2H DMA; sub1 D2H read overwritten byte 0xfe instead of 0x11

  I0000 00:00:1793242868.774375    1503 transfer_send_session.cc:622] StartPush (H2H start layer 0): uuid=202, numa=-1
  I0000 00:00:1793242868.774528    1503 transfer_send_session.cc:644] StartPush (H2H complete layer 0): uuid=202, numa=-1
  I0000 00:00:1793242868.774569    1503 transfer_send_session.cc:650] StartPush (All H2H complete): uuid=202
  [  FAILED  ] NumaKVCacheManagerBughuntTest.FailedSendSubManagerDoesNotSettleWhileSiblingD2hInFlight (5 ms)
  [ RUN      ] NumaKVCacheManagerBughuntTest.SingleSubManagerFailureDoesNotPoisonReusedReqId
  tpu_sync/frameworks/jax/numa_kv_cache_manager_bughunt_test.cc:357: Failure
  Expected equality of these values:
    f2
      Which is: {}
    std::vector<std::string>{"req_reuse"}
      Which is: { "req_reuse" }
  Second failure for req_reuse was silently dropped!

  tpu_sync/frameworks/jax/numa_kv_cache_manager_bughunt_test.cc:362: Failure
  Expected equality of these values:
    r3
      Which is: {}
    std::vector<std::string>{"req_reuse"}
      Which is: { "req_reuse" }
  Healthy done_recving for req_reuse was silently suppressed!

  [  FAILED  ] NumaKVCacheManagerBughuntTest.SingleSubManagerFailureDoesNotPoisonReusedReqId (2 ms)
  [ RUN      ] NumaKVCacheManagerBughuntTest.PartialFailureDoesNotDesyncBarrierCountIntoPrematureDoneRecving
  tpu_sync/frameworks/jax/numa_kv_cache_manager_bughunt_test.cc:393: Failure
  Expected equality of these values:
    r2
      Which is: {}
    std::vector<std::string>{"req_chain"}
      Which is: { "req_chain" }
  Healthy transfer 2 done_recving was dropped due to residual state!

  tpu_sync/frameworks/jax/numa_kv_cache_manager_bughunt_test.cc:400: Failure
  Value of: r3.empty()
    Actual: false
  Expected: true
  Transfer 3 emitted done_recving after only 1 of 2 sub-managers finished (decoding unwritten KV on sub1's shards)!

  [  FAILED  ] NumaKVCacheManagerBughuntTest.PartialFailureDoesNotDesyncBarrierCountIntoPrematureDoneRecving (4 ms)
  ```
  (Transport startup lines `Detected interface: lo` / `InitTransportServer:
  Local IP: 127.0.0.1` omitted above for brevity; the test passes
  `bind_ip = "127.0.0.1"`.)
- **Where (at `42dda542`, unchanged since `00a3f670`):**
  `NumaAwareKVCacheManager::CompleteReadRaw`
  (`tpu_sync/frameworks/jax/kv_cache_manager.cc:639-678`), over per-request
  aggregation maps `done_sending_counts_`, `done_recving_counts_`,
  `req_expected_counts_`, `failed_recving_set_` (`kv_cache_manager.h:287-290`).
  Every JAX `KVCacheManager.poll_stats()` call (`api/jax/kv_cache_manager.py:170-177`
  → `tpu_raiden_jax_module.cc:321-326`) routes through this method, both under
  default `ENABLE_MULTI_NUMA=0` (`num_subs == 1`) and under `ENABLE_MULTI_NUMA=1`
  (`num_subs >= 2`). The eager-failure behaviour is explicitly pinned by
  upstream's own unit test
  `KVCacheManagerWrapperTest.AnyFailureImmediatelyTriggersFailedRecvingAndSuppressesFutureAcks`
  (`kv_cache_manager_wrapper_test.cc:198-225`).
- **History and attribution:** introduced with `NumaAwareKVCacheManager` in
  `00a3f670` (2026-06-23). Until C1's fix
  ([tpu-inference PR #3918](https://github.com/vllm-project/tpu-inference/pull/3918),
  `f366ef52`, 2026-10-27), `tpu_raiden_connector` dropped `failed_recving` on
  both producer and consumer, masking Defect 1's mid-DMA block free. Once a
  `KVConnectorTransferResults`-compliant caller forwards `failed_recving`
  (`finished_sending` on P; `finished_recving` + `failed_recving` on D),
  `NumaAwareKVCacheManager::CompleteReadRaw` becomes the intra-worker twin of
  the cross-worker race vLLM fixed in `KVOutputAggregator` (`e7bb7e2f`,
  holding `failed_recving` until every worker reports `finished_recving`).
- **Two coupled defects and the four test sequences:**
  1. **Eager `failed_recving` while sibling sub-managers still have DMAs in
     flight (`num_subs >= 2`, `ENABLE_MULTI_NUMA=1`).** `done_sending`
     (`:646-652`) and `done_recving` (`:653-669`) barrier-wait until all
     participating sub-managers report, whereas `failed_recving` (`:670-674`)
     is emitted on the **first** sub-manager that reports `f`. Each
     `KVCacheManagerWithTransfer` sub-manager drains its own D2H / H2D copies
     before publishing `failed_recving` (`RecvDrainTest.*`, `SendDrainTest.*`),
     but `CompleteReadRaw` breaks that drain invariant across sub-managers:
     - *Case 1a (`FailedRecvSubManagerDoesNotSettleWhileSiblingH2dInFlight`,
       real `TransferReceiveSession`s):* `sub0` and `sub1` both have H2D copies
       in flight into HBM block 0; `sub0`'s H2D fails and drains while `sub1`'s
       H2D is still running (`!ptr0->HasActiveRecv(101)`,
       `ptr1->HasActiveRecv(101)`). `CompleteReadRaw` immediately emits
       `failed_recving = {"req_recv"}`; the caller recycles HBM block 0 to a
       new request (`0xAA`), and `sub1`'s in-flight H2D DMA overwrites it with
       `0x55` (`Pipeline` A4 / `Caller` `earlyFree = false` violated).
     - *Case 1b (`FailedSendSubManagerDoesNotSettleWhileSiblingD2hInFlight`,
       real `TransferSendSession`s):* `sub1` serves a pull and has a D2H copy
       reading HBM block 0 (`0x11`), while `sub0` cancels/fails before pull.
       `CompleteReadRaw` immediately emits `failed_recving = {"req_send"}`; the
       producer connector forwards it as `finished_sending`, the scheduler
       recycles HBM block 0 (`0xFE`), and `sub1`'s in-flight D2H reads `0xFE`.
  2. **Unbounded `failed_recving_set_` / count-map leak and `req_id`-reuse
     poisoning (including default `ENABLE_MULTI_NUMA=0`, `num_subs == 1`).**
     `failed_recving_set_.erase(req)` (`:667`) is reachable **only** inside the
     `done_recving` loop when `done_recving_counts_[req] >= expected`
     (`:661-668`), which counts `done_recving` (`r`) only — never
     `failed_recving` (`f`) and never `done_sending` (`s`). Every failed
     receive or failed/expired send (including every unpulled prefill after
     `TPU_P2P_WAIT_PULL_TIMEOUT` = 180 s under `ENABLE_MULTI_NUMA=0`) leaves
     `req` in `failed_recving_set_` for the life of the process (and on
     multi-NUMA partial failures also leaks `done_sending_counts_`,
     `done_recving_counts_`, and `req_expected_counts_`):
     - *Case 2a (`SingleSubManagerFailureDoesNotPoisonReusedReqId`,
       `num_subs == 1`):* after one failure on `"req_reuse"`, a second failure
       with the same `req_id` hits `failed_recving_set_.insert(req).second ==
       false` (`:671`) and is silently dropped (re-creating C1's block leak
       even with PR #3918), and a subsequent healthy receive has `done_recving`
       silently suppressed (`:664-667`, hanging the request in
       `WAITING_FOR_REMOTE_KVS`).
     - *Case 2b
       (`PartialFailureDoesNotDesyncBarrierCountIntoPrematureDoneRecving`,
       `num_subs == 2`):* after a partial failure (`sub0` fails, `sub1`
       finishes `done_recving` — the exact sequence of
       `AnyFailureImmediatelyTriggersFailedRecvingAndSuppressesFutureAcks`),
       `done_recving_counts_["req_chain"]` stays `1` and `failed_recving_set_`
       retains `"req_chain"`. On a second (healthy) transfer, `sub0`'s
       `done_recving` bumps the count `1 → 2 == expected`, suppresses
       `done_recving` via `failed_recving_set_`, and erases both maps; `sub1`'s
       `done_recving` in the same poll re-inserts `done_recving_counts_ = 1`.
       On a third transfer, `done_recving` is emitted **prematurely** as soon as
       `sub0` alone finishes (`1 → 2`), before `sub1` has written its KV shards.
- **Reachability:**
  - *Defect 1 (single-request mid-DMA HBM free):* requires `ENABLE_MULTI_NUMA=1`
    (`num_subs >= 2`), which `tpu-inference` explicitly wires in
    `TPUConnectorWorker._remote_endpoint` (`tpu_raiden_connector.py:551-583` at
    `f366ef52`, present since `a342edc3`), plus a caller that frees blocks on
    `failed_recving` (such as PR #3918), plus any staggered or asymmetric
    sub-manager failure/timeout on P or D. No `req_id` reuse is needed.
  - *Defect 2 (`failed_recving_set_` leak + `req_id` reuse):* the map growth
    fires unconditionally on every failed/expired transfer even at default
    `ENABLE_MULTI_NUMA=0`. For the `req_id`-collision consequences, vLLM V1's
    `InputProcessor.assign_request_id` (`vllm/v1/engine/input_processor.py:354-371`
    at `e7bb7e2f`) appends `-{random_uuid():.8}` by default even when a client
    supplies `request_id`, so in vLLM it requires either
    `VLLM_DISABLE_REQUEST_ID_RANDOMIZATION=1` or an 8-hex birthday collision
    across ~65k failed/expired transfers sharing the same external prefix;
    direct Python/C++ `jax::KVCacheManager` callers and benchmarks hit it
    immediately on deterministic IDs.
- **Fix (proposed):** track per-request *settled* sub-manager counts (`ok +
  fail`) on both send (`num_subs`) and recv (`expected`) barriers together with
  a per-request `any_failed` bit; emit nothing until all participating
  sub-managers have settled, then emit once (`failed_recving` if `any_failed`,
  otherwise `done_sending` / `done_recving`) and erase all per-request map
  entries (`done_sending_counts_`, `done_recving_counts_`,
  `req_expected_counts_`, `failed_recving_set_`). Update
  `AnyFailureImmediatelyTriggersFailedRecvingAndSuppressesFutureAcks` to expect
  `failed_recving` on the barrier-completing poll rather than the first failing
  sub-manager's poll.

---

## F12. Windowed pool reshard: a sender absent from some windows never reports `done_sending`, and a chain failing after window 0 holds the registry claim until TTL

- **Status:** **CONFIRMED (test)** 2026-10-29 on unmodified `42dda542`
  (`pool_reshard_chain_bughunt_test.cc`: `PoolReshardChainBughunt` — 1 passing
  control, 2 failing; `ChainClaimTest` — 1 failing, 2 passing controls).
  **Filed upstream 2026-10-29** (bug 11 in [`filed_bugs.md`](filed_bugs.md),
  which holds the write-up). Still open at `56a0269d` (planner and
  `RunSubPlan` unchanged). Output, verbatim (transport start-up lines
  `Detected interface: lo` / `InitTransportServer` / `bound_ip_` /
  `pool host staging configured` omitted; `timeout_s_ = 0.05` in the sender
  half, an injected clock with `ttl_s_ = 600` in the claim half):
  ```
  [ RUN      ] PoolReshardChainBughunt.ControlSenderInEverySubPlanReportsDone
  [1A] poll at +0ms after settling (timeout_s=0.05): sent={windowed_req,} failed={}
  [1A] poll at +60ms after settling (timeout_s=0.05): sent={} failed={}
  [1A] poll at +120ms after settling (timeout_s=0.05): sent={} failed={}
  [1A] poll at +180ms after settling (timeout_s=0.05): sent={} failed={}
  [       OK ] PoolReshardChainBughunt.ControlSenderInEverySubPlanReportsDone (195 ms)
  [ RUN      ] PoolReshardChainBughunt.SenderInOnlySomeSubPlansFirstWindowOnlyNeverReportsDone
  [1A] poll at +0ms after settling (timeout_s=0.05): sent={} failed={}
  W0000 00:00:1793298019.244212     125 kv_cache_manager_with_transfer.cc:279] Pool reshard send req_id=windowed_req: pool reshard sub-plan chain stalled: 1 of 2 sub-plans settled, none active for 0.05s
  W0000 00:00:1793298019.244352     125 kv_cache_manager_with_transfer.cc:1287] Transfer failed: req_id=windowed_req code=DEADLINE_EXCEEDED reason=pool reshard sub-plan chain stalled: 1 of 2 sub-plans settled, none active for 0.05s
  [1A] poll at +60ms after settling (timeout_s=0.05): sent={} failed={windowed_req,} details[windowed_req].reason=pool reshard sub-plan chain stalled: 1 of 2 sub-plans settled, none active for 0.05s
  [1A] poll at +120ms after settling (timeout_s=0.05): sent={} failed={}
  [1A] poll at +180ms after settling (timeout_s=0.05): sent={} failed={}
  tpu_sync/kv_cache/pool_reshard_chain_bughunt_test.cc:277: Failure
  Value of: reported_sent
    Actual: false
  Expected: true
  sender settled every sub-plan it was dispatched (1 of sub_plan_count=2) successfully, but req_id never appeared in done_sending

  tpu_sync/kv_cache/pool_reshard_chain_bughunt_test.cc:281: Failure
  Value of: reported_failed
    Actual: true
  Expected: false
  sender whose every dispatched sub-plan succeeded was reported failed: pool reshard sub-plan chain stalled: 1 of 2 sub-plans settled, none active for 0.05s

  [  FAILED  ] PoolReshardChainBughunt.SenderInOnlySomeSubPlansFirstWindowOnlyNeverReportsDone (185 ms)
  [ RUN      ] PoolReshardChainBughunt.SenderInOnlySomeSubPlansLastWindowOnlyNeverReportsDone
  (same two failures, `1 of sub_plan_count=2`)
  [  FAILED  ] PoolReshardChainBughunt.SenderInOnlySomeSubPlansLastWindowOnlyNeverReportsDone (184 ms)
  [ RUN      ] ChainClaimTest.ArmFailureAtSubPlan1LeavesClaimUntilTtl
  E0000 00:00:1793298019.829035     226 reshard_coordinator.cc:631] Pool reshard sub-transfer 1 of 2 failed for req_id=req-1c uuid=81: INTERNAL: Raiden remote native execution failed: injected arm refusal
   (the request's receivers and senders settle through their sub-plan chain deadline)
  [1C] worker calls: 10.0.0.2:9600(arm sub_plan 0/2), 10.0.0.1:9100(send sub_plan 0/2), 10.0.0.2:9600(arm sub_plan 1/2)
  [1C] transfer status: 4 (4 = kFailed)
  [1C] rank 0 votes Complete -> success=1 rows_retired=0
  [1C] after every dispatched sender voted: status=STATUS_CLAIMED CancelIfUnclaimed=false
  tpu_sync/kv_cache/pool_reshard_chain_bughunt_test.cc:842: Failure
  Expected: (after_vote) != (ProtoStatus::STATUS_CLAIMED), actual: 3 vs 3
  the failed chain's claim outlives every dispatched sender's vote

  tpu_sync/kv_cache/pool_reshard_chain_bughunt_test.cc:844: Failure
  Expected equality of these values:
    cancel
      Which is: "false"
    "true"
  CancelIfUnclaimed still refuses after the chain failed and every dispatched sender voted

  [1C] at claim+599s: status=STATUS_CLAIMED CancelIfUnclaimed=false
  [1C] at claim+601s: status=STATUS_UNKNOWN
  [  FAILED  ] ChainClaimTest.ArmFailureAtSubPlan1LeavesClaimUntilTtl (24 ms)
  [ RUN      ] ChainClaimTest.ControlUndispatchedRankVoteWouldRetireTheClaim
  [1C-ctl] rank 1 votes too -> rows_retired=2 status=STATUS_UNKNOWN
  [       OK ] ChainClaimTest.ControlUndispatchedRankVoteWouldRetireTheClaim (3 ms)
  [ RUN      ] ChainClaimTest.ControlArmFailureAtSubPlan0AbandonsTheClaim
  [1C-0] coordinate success=0 (Raiden remote native execution failed: injected arm refusal); worker calls: 10.0.0.2:9600(arm sub_plan 0/2); status=STATUS_REGISTERED CancelIfUnclaimed=true
  [       OK ] ChainClaimTest.ControlArmFailureAtSubPlan0AbandonsTheClaim (1 ms)
  ```
- **Where (at `42dda542`, introduced by `09a42d4e`, 2026-10-25):**
  `BuildPoolReshardPlan` keeps only the units with schedule entries in the
  window (`pool_reshard_planner.cc:1290-1294`) while
  `ReshardCoordinator::RunSubPlan` stamps `sub_plan_count = ctx->chain.count`
  on every sub-plan (`reshard_coordinator.cc:730-733`) and dispatches only
  `plan.src_units` (`:812-878`); on the sender,
  `KVCacheManagerWithTransfer::NoteSubPlanRegisteredLocked`
  (`kv_cache_manager_with_transfer.cc:151-175`),
  `RecordPoolReshardTerminalLocked` (`:218-226`) and
  `SweepSubPlanChainsLocked` (`:273-283`). The claim half: `RunSubPlan`'s three
  `if (index == 0)` abandons (`reshard_coordinator.cc:725`, `:785-787`,
  `:816-818`), the header's "later ones leave the claim to the dispatched
  senders' terminals" (`reshard_coordinator.h:173-175`), `LookupAndClaim` over
  all of `request.src_units` (`pool_reshard_planner.cc:1119-1120`) and
  `RequestBlockRegistry::Complete`'s all-voted retirement
  (`request_block_registry.cc:317-371`).
- **How the tests drive it:** the sender half uses a real
  `KVCacheManagerWithTransfer` and registers each sender sub-plan exactly as
  `PoolReshardPush` does (`ReshardSendSession::Create`, insert into
  `active_pool_reshard_sends_`, `NoteSubPlanRegisteredLocked`), replacing only
  the device push by settling the session with `Finish(OkStatus())`; reporting
  then runs through the production `CompleteReadWithDetails`. A sender
  dispatched in `{0, 1}` of `K = 2` reports `done_sending` (control); one
  dispatched in `{0}` or `{1}` never does and is failed by the sweep. The claim
  half runs a real `ReshardService` over a payload-capturing transport with an
  injected clock: two ranks, window = 2 of 4 pages (`K = 2`, rank 0 in window 0
  only), sub-plan 1's arm hard-refused; after the only dispatched rank votes
  `Complete` the request is still `STATUS_CLAIMED` and `CancelIfUnclaimed`
  returns `false` until `ttl_s_`; controls show rank 1's vote would retire it
  at once and that the same refusal at sub-plan 0 abandons immediately.
- **Relation to F8:** F8 is the sender-dispatch return in the same function
  that never abandons at any index; F12's claim half is the `index >= 1`
  design (abandon left to the senders' terminals) meeting partial dispatch.
  Fixing F8 alone does not close it.
- **Reachability:** every multi-window request whose span ownership varies by
  window — upstream's own `WindowedRequestChainsOneSubTransferPerWindow` (2 of
  4 windows per rank) and `WindowClipsStraddlingSpansAtWindowBoundaries` (rank 0
  in window 0 of 2) have this shape. Gated on a caller passing
  `dst_window_blocks`: the binding is wired
  (`api/torch/reshard_client.py:55-56`, `SUPPORTS_DST_WINDOW_BLOCKS`), but
  `vllm-torchtpu` `9725110` and `sglang-torchtpu` `9a6eef1` do not pass it.
- **Fix:** not proposed in the report (design choice for the owners: per-sender
  `sub_plan_count`, or an explicit no-op terminal for the windows a unit is not
  in; and for the claim, votes recorded for never-dispatched units when the
  chain aborts).

## F13. Windowed pool reshard: the first failing sub-plan is reported while sibling or later windows still run DMAs, and can be reported twice

- **Status:** **CONFIRMED (test)** 2026-10-29 on unmodified `42dda542`
  (`pool_reshard_chain_bughunt_test.cc`: `PoolReshardChainBughunt1B`, 4/4
  failing). **Filed upstream 2026-10-29** (bug 12 in
  [`filed_bugs.md`](filed_bugs.md), which holds the write-up). Still open at
  `56a0269d` (`RecordPoolReshardTerminalLocked` unchanged). Output, verbatim
  (start-up lines omitted as for F12; the `[1A]` prefix on the poll lines is
  the shared print helper's):
  ```
  [ RUN      ] PoolReshardChainBughunt1B.RecvFailureNotReportedWhileSiblingSubPlanActive
  [1B-a] EndIncomingPush(sub-plan 0, error) -> CANCELLED: ReshardReceiveSession for uuid=7100 failed: peer reset mid-push
  W0000 00:00:1793298019.554387     125 kv_cache_manager_with_transfer.cc:212] Pool reshard receive req_id=windowed_req failed at sub-plan 0 of 2: UNAVAILABLE: peer reset mid-push
  W0000 00:00:1793298019.554455     125 kv_cache_manager_with_transfer.cc:1287] Transfer failed: req_id=windowed_req code=UNAVAILABLE reason=sub-plan 0 of 2: peer reset mid-push
  [1A] 1B-a poll after sub-plan 0 failed: sent={} failed={windowed_req,} details[windowed_req].reason=sub-plan 0 of 2: peer reset mid-push
  [1B-a] at that poll: sub-plan 0{Done=1 IsDraining=1 HasPendingWork=0 status=UNAVAILABLE: peer reset mid-push} sub-plan 1{Done=0 IsDraining=0 HasPendingWork=1 status=OK}
  tpu_sync/kv_cache/pool_reshard_chain_bughunt_test.cc:423: Failure
  Value of: Reports(r.failed) && !sub1->Done()
    Actual: true
  Expected: false
  failed_recving published for windowed_req while sibling sub-plan 1 is still live: sub-plan 1{Done=0 IsDraining=0 HasPendingWork=1 status=OK}

  [1B-a] EndIncomingPush(sub-plan 1, ok) -> OK
  [1A] 1B-a poll after sub-plan 1 settled OK: sent={} failed={}
  [1B-a] final sub-plan 1{Done=1 IsDraining=1 HasPendingWork=0 status=OK}
  [  FAILED  ] PoolReshardChainBughunt1B.RecvFailureNotReportedWhileSiblingSubPlanActive (4 ms)
  [ RUN      ] PoolReshardChainBughunt1B.RecvLaterSubPlanAcceptedAfterChainFailureReported
  [1A] 1B-b poll after sub-plan 0 failed: sent={} failed={windowed_req,} details[windowed_req].reason=sub-plan 0 of 2: peer reset mid-push
  [1B-b] PoolReshardRegisterRecv(sub-plan 1 of failed chain) -> OK; plan claimed=1 session=sub-plan 1{Done=0 IsDraining=0 HasPendingWork=1 status=OK}
  tpu_sync/kv_cache/pool_reshard_chain_bughunt_test.cc:462: Failure
  Value of: late.ok()
    Actual: true
  Expected: false
  sub-plan 1 of a chain already reported failed was accepted

  tpu_sync/kv_cache/pool_reshard_chain_bughunt_test.cc:464: Failure
  Value of: claimed
    Actual: true
  Expected: false
  the late sub-plan claimed its plan uuid

  tpu_sync/kv_cache/pool_reshard_chain_bughunt_test.cc:465: Failure
  Expected equality of these values:
    sub1
      Which is: (ptr = 0x55edc892e190, value = 328-byte object <...>)
    nullptr
      Which is: (nullptr)
  the late sub-plan has a live receive session

  [1A] 1B-b poll after the late sub-plan settled OK: sent={} failed={}
  [1B-b] late sub-plan terminal swallowed: received=0 failed=0
  [  FAILED  ] PoolReshardChainBughunt1B.RecvLaterSubPlanAcceptedAfterChainFailureReported (4 ms)
  [ RUN      ] PoolReshardChainBughunt1B.RecvLateSubPlanAfterSweepReportsTheFailureAgain
  [1A] 1B-b' poll after sub-plan 0 failed: sent={} failed={windowed_req,} details[windowed_req].reason=sub-plan 0 of 2: peer reset mid-push
  [1A] 1B-b' poll +120ms (failed chain erased): sent={} failed={}
  [1A] 1B-b' poll +0ms after late sub-plan 1 settled OK: sent={} failed={}
  W0000 00:00:1793298019.743117     125 kv_cache_manager_with_transfer.cc:279] Pool reshard receive req_id=windowed_req: pool reshard sub-plan chain stalled: 1 of 2 sub-plans settled, none active for 0.05s
  [1A] 1B-b' poll +60ms after late sub-plan 1 settled OK: sent={} failed={windowed_req,} details[windowed_req].reason=pool reshard sub-plan chain stalled: 1 of 2 sub-plans settled, none active for 0.05s
  [1A] 1B-b' poll +120ms after late sub-plan 1 settled OK: sent={} failed={}
  tpu_sync/kv_cache/pool_reshard_chain_bughunt_test.cc:511: Failure
  Expected equality of these values:
    failed_reports
      Which is: 2
    1
  windowed_req was reported in failed_recving 2 times

  [  FAILED  ] PoolReshardChainBughunt1B.RecvLateSubPlanAfterSweepReportsTheFailureAgain (245 ms)
  [ RUN      ] PoolReshardChainBughunt1B.SenderFailureNotReportedWhileSiblingSubPlanActive
  E0000 00:00:1793298019.807564     125 reshard_send_session.cc:361] Pool reshard send failed uuid=7400 req_id=windowed_req: UNAVAILABLE: peer reset mid-push
  W0000 00:00:1793298019.807699     125 kv_cache_manager_with_transfer.cc:212] Pool reshard send req_id=windowed_req failed at sub-plan 0 of 2: UNAVAILABLE: peer reset mid-push
  [1A] 1B-c poll after sender sub-plan 0 failed: sent={} failed={windowed_req,} details[windowed_req].reason=sub-plan 0 of 2: peer reset mid-push
  [1B-c] at that poll: sub-plan 0{Done=1 IsDraining=1 status=UNAVAILABLE: peer reset mid-push} sub-plan 1{Done=0 IsDraining=0 status=OK}
  tpu_sync/kv_cache/pool_reshard_chain_bughunt_test.cc:539: Failure
  Value of: Reports(r.failed) && !(*sub1)->Done()
    Actual: true
  Expected: false
  failed_recving published for sender windowed_req while sibling sub-plan 1 still has a push in flight: sub-plan 1{Done=0 IsDraining=0 status=OK}

  [1A] 1B-c poll after sender sub-plan 1 settled OK: sent={} failed={}
  [1B-c] final sub-plan 1{Done=1 IsDraining=1 status=OK}
  [  FAILED  ] PoolReshardChainBughunt1B.SenderFailureNotReportedWhileSiblingSubPlanActive (3 ms)
  ```
  Whole binary: `10 tests from 3 test suites ran. (852 ms total)`, 3 passed
  (the controls), 7 failed.
- **Where (at `42dda542`):** `RecordPoolReshardTerminalLocked`'s failure
  branch (`kv_cache_manager_with_transfer.cc:205-217`) against the
  active-session check `SweepSubPlanChainsLocked` does make (`:252-267`);
  `PoolReshardPush` (`:833-871`) and `PoolReshardRegisterRecv` (`:873-910`)
  never consult `chains[req_id].failed`; the swallowed-terminal early-out
  (`:203`); the tombstone erase one `timeout_s_` after the last registration
  or terminal (`:242-248`) and the stall report (`:273-283`);
  `ReshardCoordinator::StartChain` (`reshard_coordinator.cc:614-649`) and the
  arm-retry loop (`:749-795`). Upstream's
  `SubPlanChainTest.FirstSubPlanFailureFailsTheRequestOnce`
  (`kv_cache_manager_with_transfer_pool_reshard_test.cc:861-884`) pins the
  "later sub-plan still armed, terminal swallowed" behaviour.
- **The four cases:** (a) receiver: sub-plans 0 and 1 of `K = 2` armed, both
  with an admitted push (`BeginIncomingPush`); sub-plan 0's push ends with an
  error → `failed_recving` is published while sub-plan 1 is live. (b) receiver:
  after the failure is reported, `PoolReshardRegisterRecv` for sub-plan 1 is
  accepted (plan claimed, session live) and its clean terminal dropped. (b′)
  receiver, `timeout_s_ = 50 ms`: the failed entry is swept, a late sub-plan 1
  settles OK, and the request is failed a second time with `chain stalled`.
  (c) sender: the same as (a) with `ReshardSendSession`s and one push in flight
  each. Each test asserts the per-session contract (no `failed_recving` while a
  sibling is live; a sub-plan of a failed chain refused; at most one failure
  report) and fails on the unmodified code.
- **Relation to F11:** the same defect class — an aggregate terminal emitted
  on the first failure without a barrier on the aggregate's other members —
  one level up (sub-plans of a request instead of NUMA sub-managers of a
  worker). The per-session drain (`Recv.SettleSafe` / `Send.SettleSafe` in
  `Transfer/Reshard/`) is intact; the chain aggregation above it is not
  modelled (`reshard.md` §Boundaries), which is where it was found.
- **Reachability:** mid-DMA free — any multi-window request whose first
  failure has another window active, with the engine recomputing into (or on
  abort freeing) the destination blocks on `failed_recving` (§Callers); double
  report — a worker whose next sub-plan arrives more than `timeout_s_` after
  the failure, typically a sender skipped in the intervening windows (F12's
  shape). Same `dst_window_blocks` caller gate as F12.
- **Fix:** not proposed in the report (fail the chain once all of the request's
  sessions on this worker have settled, mirroring the sweep's active check;
  refuse new sub-plans of a failed `req_id` or stop the chain on a data-plane
  failure; and keep the tombstone until the chain's last window can no longer
  arrive and every seated `sub_sessions` entry has reached `Done()`).
- **Re-read 2026-11-09 at `00e946e3`:** `25f7d8a7` merged `recv_chains_` /
  `send_chains_` into `sub_plan_chains_` (`SubPlanChainProgress{sub_sessions,
  completed, failed, last_activity, anchored}`), and made
  `RecordPoolReshardTerminalLocked` (`kv_cache_manager_with_transfer.cc:192-196`)
  emit the sub-plan's own terminal directly whenever `it == sub_plan_chains_.end()`.
  Because `SweepSubPlanChainsLocked` (`:264-269`) still erases `progress.failed ||
  progress.completed` after a quiet `timeout_s_` without checking
  `!sub_session->Done()`, while `CompleteReadWithDetails` (`:1082`) skips
  `session->IsDraining()` in its deadline arm, an already-seated sibling sub-plan
  that is still `!Done()` across that sweep now settles into `it ==
  sub_plan_chains_.end()` on a subsequent poll — emitting a second
  `failed_recving_` if draining on error, or emitting false `done_sending_` /
  `done_recving_` on the failed chain if it had already latched `IsDraining()`
  with `OkStatus()` (`ReshardSendSession::EndOp` during unlocked
  `ReleaseDataConnectionsAfterSend`, or `ReshardReceiveSession::FinishPoolH2d`
  before `self->EndOp()`), with no caller retry required (`SubPlanChain`
  `mutant_draining_ok_at_sweep_reports_done_after_failure`). In addition,
  `CompleteReadWithDetails` acquires `session->mu_` separately in
  `RetireSettledSessionLocked` (`:494`) and `SweepSubPlanChainsLocked` (`:278`):
  if an unanchored (`progress.anchored == false`, `index >= 1`) sub-plan's
  `EndOp()` sets `done_ = true` (`OkStatus()`) in between, `:278-298` marks the
  chain stalled (`failed_recving_`, `progress.failed = true`) and clears
  `progress.sub_sessions`, and the next poll hits `sub_it ==
  progress.sub_sessions.end()` (`:201-212`, checked before `if (progress.failed ||
  progress.completed)` at `:219`) to emit `done_sending_` / `done_recving_`
  after `failed_recving_` (`SubPlanChain`
  `mutant_mid_poll_endop_unanchored_reports_done_after_stall`).
- **C++ test at `00e946e3`** (`pool_reshard_stale_subplan_bughunt_test.cc`,
  `StaleSubPlanBughunt`, 2 controls passing + 4 cases failing on unmodified
  `00e946e3`, 2026-11-09): exercises both (1) a single-plan retry
  (`sub_plan_count <= 1`) under the same `req_id` erasing a live
  `sub_plan_chains_[req_id]` entry in `NoteSubPlanRegisteredLocked` (`:160-162`)
  so a still-seated sub-plan from the failed attempt reports premature
  `done_recving` or `failed_recving` for the retry (`SubPlanChain` A6 /
  `mutant_single_erases_live_chain`), and (2) `SweepSubPlanChainsLocked`
  (`:264-269`) erasing a failed chain tombstone while a sibling sub-plan holds
  an open `TryBeginOp()` across `timeout_s_`, after which `EndOp()` + poll
  emits a second `failed_recving` (when the deadline arm marked it draining) or
  false `done_recving` on the already-failed request (when it had already
  called `Finish()` OK before `timeout_s_`, `SubPlanChain`
  `mutant_draining_ok_at_sweep_reports_done_after_failure`). Verbatim output
  (glog `tpu_utils` / `raw_buffer_transport` startup lines omitted):
  ```
  [==========] Running 6 tests from 1 test suite.
  [----------] Global test environment set-up.
  [----------] 6 tests from StaleSubPlanBughunt
  [ RUN      ] StaleSubPlanBughunt.ControlSinglePlanRetryAloneReportsOnItsOwnTerminal
  W0000 00:00:1794259519.455566    1607 kv_cache_manager_with_transfer.cc:229] Pool reshard receive req_id=chained_req failed at sub-plan 0 of 2: INTERNAL: push failed
  W0000 00:00:1794259519.455708    1607 kv_cache_manager_with_transfer.cc:1129] Transfer failed: req_id=chained_req code=INTERNAL reason=sub-plan 0 of 2: push failed
  [       OK ] StaleSubPlanBughunt.ControlSinglePlanRetryAloneReportsOnItsOwnTerminal (8 ms)
  [ RUN      ] StaleSubPlanBughunt.StaleSubPlanSettlingOkCompletesTheSinglePlanRetryEarly
  W0000 00:00:1794259519.460686    1607 kv_cache_manager_with_transfer.cc:229] Pool reshard receive req_id=chained_req failed at sub-plan 0 of 2: INTERNAL: push failed
  W0000 00:00:1794259519.460769    1607 kv_cache_manager_with_transfer.cc:1129] Transfer failed: req_id=chained_req code=INTERNAL reason=sub-plan 0 of 2: push failed
  tpu_sync/kv_cache/pool_reshard_stale_subplan_bughunt_test.cc:309: Failure
  Value of: received
  Expected: is empty
    Actual: { "chained_req" }, whose size is 1
  stale sub-plan 6002 reported done_recving for the retry

  [  FAILED  ] StaleSubPlanBughunt.StaleSubPlanSettlingOkCompletesTheSinglePlanRetryEarly (3 ms)
  [ RUN      ] StaleSubPlanBughunt.StaleSubPlanSettlingFailedFailsTheSinglePlanRetry
  W0000 00:00:1794259519.465448    1607 kv_cache_manager_with_transfer.cc:229] Pool reshard receive req_id=chained_req failed at sub-plan 0 of 2: INTERNAL: push failed
  W0000 00:00:1794259519.465556    1607 kv_cache_manager_with_transfer.cc:1129] Transfer failed: req_id=chained_req code=INTERNAL reason=sub-plan 0 of 2: push failed
  W0000 00:00:1794259519.466089    1607 kv_cache_manager_with_transfer.cc:1129] Transfer failed: req_id=chained_req code=INTERNAL reason=late push failed
  tpu_sync/kv_cache/pool_reshard_stale_subplan_bughunt_test.cc:338: Failure
  Value of: failed
  Expected: is empty
    Actual: { "chained_req" }, whose size is 1
  stale sub-plan 6002 reported failed_recving for the retry

  [  FAILED  ] StaleSubPlanBughunt.StaleSubPlanSettlingFailedFailsTheSinglePlanRetry (4 ms)
  [ RUN      ] StaleSubPlanBughunt.ControlChainRetryKeepsAnAnchoredEntry
  W0000 00:00:1794259519.469734    1607 kv_cache_manager_with_transfer.cc:229] Pool reshard receive req_id=chained_req failed at sub-plan 0 of 2: INTERNAL: push failed
  W0000 00:00:1794259519.469813    1607 kv_cache_manager_with_transfer.cc:1129] Transfer failed: req_id=chained_req code=INTERNAL reason=sub-plan 0 of 2: push failed
  [       OK ] StaleSubPlanBughunt.ControlChainRetryKeepsAnAnchoredEntry (124 ms)
  [ RUN      ] StaleSubPlanBughunt.SweptChainReportsADrainingSubPlanAsASecondFailure
  W0000 00:00:1794259519.594502    1607 kv_cache_manager_with_transfer.cc:229] Pool reshard receive req_id=chained_req failed at sub-plan 0 of 2: INTERNAL: push failed
  W0000 00:00:1794259519.594600    1607 kv_cache_manager_with_transfer.cc:1129] Transfer failed: req_id=chained_req code=INTERNAL reason=sub-plan 0 of 2: push failed
  W0000 00:00:1794259519.715040    1607 kv_cache_manager_with_transfer.cc:1129] Transfer failed: req_id=chained_req code=DEADLINE_EXCEEDED reason=Transfer session timed out
  tpu_sync/kv_cache/pool_reshard_stale_subplan_bughunt_test.cc:427: Failure
  Value of: late.failed
  Expected: is empty
    Actual: { "chained_req" }, whose size is 1
  already-failed request reported failed again: Transfer session timed out

  [  FAILED  ] StaleSubPlanBughunt.SweptChainReportsADrainingSubPlanAsASecondFailure (124 ms)
  [ RUN      ] StaleSubPlanBughunt.SweptChainReportsADrainingOkSubPlanAsReceived
  W0000 00:00:1794259519.719281    1607 kv_cache_manager_with_transfer.cc:229] Pool reshard receive req_id=chained_req failed at sub-plan 0 of 2: INTERNAL: push failed
  W0000 00:00:1794259519.719370    1607 kv_cache_manager_with_transfer.cc:1129] Transfer failed: req_id=chained_req code=INTERNAL reason=sub-plan 0 of 2: push failed
  tpu_sync/kv_cache/pool_reshard_stale_subplan_bughunt_test.cc:467: Failure
  Value of: received
  Expected: is empty
    Actual: { "chained_req" }, whose size is 1
  already-failed request reported as received

  [  FAILED  ] StaleSubPlanBughunt.SweptChainReportsADrainingOkSubPlanAsReceived (124 ms)
  [----------] 6 tests from StaleSubPlanBughunt (390 ms total)

  [----------] Global test environment tear-down
  [==========] 6 tests from 1 test suite ran. (391 ms total)
  [  PASSED  ] 2 tests.
  [  FAILED  ] 4 tests, listed below:
  [  FAILED  ] StaleSubPlanBughunt.StaleSubPlanSettlingOkCompletesTheSinglePlanRetryEarly
  [  FAILED  ] StaleSubPlanBughunt.StaleSubPlanSettlingFailedFailsTheSinglePlanRetry
  [  FAILED  ] StaleSubPlanBughunt.SweptChainReportsADrainingSubPlanAsASecondFailure
  [  FAILED  ] StaleSubPlanBughunt.SweptChainReportsADrainingOkSubPlanAsReceived

   4 FAILED TESTS
  ```
- **Upstream bug updated 2026-11-09:** a comment on bug 12 records the
  `00e946e3` shape after `25f7d8a7` (no entry in `sub_plan_chains_` read as a
  single-plan request; the single-plan-retry erase and the sweep of a tombstone
  whose sibling is still draining) and notes that the first half of the
  original report is unchanged. The original description is left as filed.

---

## F14. `TransferReceiveSession::FinishLocked` lets a late external error overwrite a receive whose every H2D already completed OK, flipping `received` to `failed`

- **Status:** **CONFIRMED (test)** 2026-10-30, on unmodified `42dda542`:
  `transfer_receive_late_finish_bughunt_test.cc` (1 positive control + 4
  cases; `RecvLateFinishBughunt`). **Audited 2026-10-30 (later): the code defect
  is real, but of the four tested paths only (3, the pull reply) is reachable in
  production (alongside a photo-finish deadline-sweep check-then-`Finish` window
  in `CompleteReadWithDetails`), both through narrow windows; severity low.**
  The four cases drive `EndIncomingPush`, `UnregisterActivePlan`, the pull reply
  and the pool H2D directly; they show the flip, not production reachability.
  Not yet filed. Surfaced while auditing the late-error window of
  `Transfer/PrefillDecode/Receive.lean` (§Lock scopes) and
  `findings/coverage_gap_tests.patch` (see "Coverage-gap tests" below).
  **At `56a0269d` (2026-11-02):** still open on both receivers
  (`TransferReceiveSession::FinishLocked`, `ReshardReceiveSession::FinishLocked`
  unchanged in shape); the sender half is fixed — `1523b07d` moved
  `ReshardSendSession::Finish`'s `if (done_ || finalizing_) return;` ahead of
  the status record, pinned by
  `ReshardSendSessionTest.FinishAfterLastPushFinalizingPreservesOkStatus`. The
  reproducer's entry points moved (`BeginIncomingPush` / `EndIncomingPush` free
  functions in `block_transport_session.cc`, `TransferReceiveSession::Start`
  for the pull reply) and need porting before a re-run.
- **Root cause (`42dda542`):** `TransferReceiveSession::FinishLocked`
  (`tpu_sync/kv_cache/transfer_receive_session.cc:449-464`) records the first
  error even while draining (`if (!status.ok() && status_.ok()) status_ = status;`
  before `if (draining_) return;`, no `done_` check), whereas
  `TransferSendSession::FinishLocked` (`transfer_send_session.cc:247`) returns
  on `if (draining_ || done_)`. The receive rule is **needed**: `IsReadyToComplete`
  / `AllH2dDoneLocked` (`transfer_receive_session.cc:537-550`) test that every
  H2D future is *ready*, not that it succeeded, so the poll in
  `CompleteReadWithDetails` (`kv_cache_manager_with_transfer.cc:1212-1215`) can
  `Finish()` OK before a failed H2D's callback runs
  `FinishLocked(status_or.status(), kH2dPhase)` (`:895`), and that late error
  must win (`ReceivePoll.pollReady_window`; replayed in the Lean receive model:
  after `.pollReady` the session is draining, OK, one op in flight, and
  `.h2dDone false` publishes `some false`). The defect is narrower: the rule
  also admits *external* errors after the last successful H2D callback has
  called `FinishLocked()` (`:889`), i.e. once every layer is on device.
  `ReshardReceiveSession::FinishLocked` (`reshard_receive_session.cc:474-484`)
  has the same shape; there `IsReadyToComplete` requires `network_completed_`,
  which `FinishPoolH2d` sets only when every pool completed OK (`:699`), so the
  poll-side dependency does not exist. `ReshardSendSession::Finish`
  (`reshard_send_session.cc:394-410`) has the same shape and no poll-side
  `IsReadyToComplete` caller either; its only external caller is the deadline
  sweep (`:1185-1188` of the manager), where `!session->IsDraining()` and
  `session->Finish(DeadlineExceededError)` run in separate `session->mu_` lock
  scopes (the same near-deadline check-then-`Finish` window the two receive
  sweeps have at `:1211-1222` and `:1243-1250`).
- **The four paths the test drives, and what reaches them:**
  1. **Trailing stream cleanup (`hooks.end_incoming_push`,
     `kv_cache_manager_with_transfer.cc:390-436`;
     `BlockTransportServerPushSession::StartStream`,
     `block_transport_session.cc:334-448`) — not reachable from in-tree
     senders.** `StartStream` passes `InternalError` only if it fails before
     `incoming_push_lease_held = false`; after its data landed only
     `CompleteIncomingPush` / `OnBlockShardsReceived` can fail, which needs a
     duplicate or extra stream (excluded by honest senders, `Transport.lean`
     A4). A stream failing earlier means data never arrived, so the failure is
     genuine.
  2. **`KVCacheManagerWithTransfer::UnregisterActivePlan`
     (`kv_cache_manager_with_transfer.cc:912-949`) — race real, no production
     caller.** The `!Done()` check under `mu_` then `Finish(Cancelled)` outside
     it can land after the data completed (and makes `EndIncomingPush(OK)`
     return `CancelledError`, failing the sender's ACK). Receive-side
     `UnregisterActivePlan` is reached only through the Python
     `unregister_active_plan` API, which nothing calls in tpu-sync,
     tpu-inference, vllm-torchtpu or sglang-torchtpu; cancel-wins on a race is
     also a defensible meaning.
  3. **Late control reply on `StartRead`
     (`TransferReceiveSession::ExecutePullRequest`,
     `transfer_receive_session.cc:629-664`;
     `KVCacheManagerWithTransfer::HandlePullStream`,
     `kv_cache_manager_with_transfer.cc:1525-1547`) — reachable in production
     (alongside the deadline sweep's check-then-`Finish` window).**
     `HandlePullStream` detaches `StartPush` before returning the response. If
     the reply fails on the return leg after the push and every H2D completed,
     `on_response` runs `self->FinishLocked(pull_status)` (`:662`) and the
     session settles failed. This happens **before** `done_`, not after: the
     handshake op (`InitFromLoadPlan`, `in_flight_ = 1`) is released only by
     `on_response`'s `end_op` (`:631`). Narrow: `control_timeout_s_` =
     `kPullRegistrationGrace` + slack (`:91-95`) is sized so the reply
     normally arrives first. (Separately, in `CompleteReadWithDetails`,
     `!IsDraining()` / `IsReadyToComplete()` and `Finish(DeadlineExceededError)`
     take separate `session->mu_` locks at `:1185-1188`, `:1211-1222`, and
     `:1243-1250`, so an H2D or push callback completing OK in between right at
     `deadline()` is likewise overwritten.)
  4. **`~KVCacheManagerWithTransfer` (`:555-587`) — no observable effect.** No
     `CompleteReadWithDetails` poll can follow teardown, so the flipped status
     is never published.
- **Consequence:** no data corruption (HBM holds every block). A completed P/D
  receive is reported in `failed_recving`; under vLLM's default
  `kv_load_failure_policy = "fail"` the request ends `FINISHED_ERROR`, under
  `"recompute"` the prefill is redone.
- **Test output** (unedited; OSS Bazel on unmodified `42dda542`):

  ```
  ==================== Test output for //tpu_sync/kv_cache:transfer_receive_late_finish_bughunt_test:
  Running main() from gmock_main.cc
  [==========] Running 5 tests from 1 test suite.
  [----------] Global test environment set-up.
  [----------] 5 tests from RecvLateFinishBughunt
  [ RUN      ] RecvLateFinishBughunt.Control_TransferSendSessionPreservesOkAcrossLateErrorFinish
  WARNING: All log messages before absl::InitializeLog() is called are written to STDERR
  I0000 00:00:1793325935.733336    1471 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793325935.733501    1471 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793325935.734540    1471 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 32833, listening tcp socket 3: [::]:32833--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793325935.734942    1471 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793325935.736668    1471 kv_cache_manager_with_transfer.cc:111] RAIDEN_TIMING event=producer_register req_id=req-send-ok uuid=100 node_id=0 blocks=1 enqueue_ms=0.04468 failed=0
  I0000 00:00:1793325935.736734    1471 kv_cache_manager_with_transfer.cc:111] RAIDEN_TIMING event=producer_ack req_id=req-send-ok uuid=100 node_id=0 blocks=0 bytes=0 stage_to_ack_ms=7.75648e+08 register_to_ack_ms=0.4185 failed=0
  [       OK ] RecvLateFinishBughunt.Control_TransferSendSessionPreservesOkAcrossLateErrorFinish (8 ms)
  [ RUN      ] RecvLateFinishBughunt.TrailingPushStreamErrorAfterCompletedH2dMustNotFlipReceivedToFailed
  I0000 00:00:1793325935.740117    1471 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793325935.740165    1471 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793325935.740644    1471 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 35049, listening tcp socket 3: [::]:35049--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793325935.740783    1471 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793325935.741734    1471 kv_cache_manager_with_transfer.cc:760] RegisterActivePlan (Receiver): Populated active_recv_sessions_ for UUID 201 with 1 total physical block-pushes (including duplicates across sources) for automatic H2D.
  I0000 00:00:1793325935.741922    1471 transfer_receive_session.cc:821] OnLayerReceived (H2D copy start) layer 0: req_id=req-trail-push, uuid=201, numa=-1
  I0000 00:00:1793325935.742015    1471 transfer_receive_session.cc:881] OnLayerReceived (H2D copy complete) layer 0: req_id=req-trail-push, numa=-1
  I0000 00:00:1793325935.742070    1471 transfer_receive_session.cc:914] All layers H2D copy complete: req_id=req-trail-push
  W0000 00:00:1793325935.742199    1471 kv_cache_manager_with_transfer.cc:1287] Transfer failed: req_id=req-trail-push code=INTERNAL phase=receive elapsed_ms=0.38576 reason=Incoming push failed
  tpu_sync/kv_cache/transfer_receive_late_finish_bughunt_test.cc:330: Failure
  Value of: completions.received
  Expected: has 1 element that is equal to "req-trail-push"
    Actual: {}

  tpu_sync/kv_cache/transfer_receive_late_finish_bughunt_test.cc:331: Failure
  Value of: completions.failed
  Expected: is empty
    Actual: { "req-trail-push" }, whose size is 1

  [  FAILED  ] RecvLateFinishBughunt.TrailingPushStreamErrorAfterCompletedH2dMustNotFlipReceivedToFailed (3 ms)
  [ RUN      ] RecvLateFinishBughunt.UnregisterActivePlanAfterCompletedH2dMustNotFlipReceivedToFailed
  I0000 00:00:1793325935.743552    1471 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793325935.743599    1471 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793325935.744033    1471 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 45877, listening tcp socket 3: [::]:45877--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793325935.744159    1471 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793325935.745015    1471 kv_cache_manager_with_transfer.cc:760] RegisterActivePlan (Receiver): Populated active_recv_sessions_ for UUID 202 with 1 total physical block-pushes (including duplicates across sources) for automatic H2D.
  I0000 00:00:1793325935.745125    1471 transfer_receive_session.cc:821] OnLayerReceived (H2D copy start) layer 0: req_id=req-unreg-plan, uuid=202, numa=-1
  I0000 00:00:1793325935.745185    1471 transfer_receive_session.cc:881] OnLayerReceived (H2D copy complete) layer 0: req_id=req-unreg-plan, numa=-1
  I0000 00:00:1793325935.745222    1471 transfer_receive_session.cc:914] All layers H2D copy complete: req_id=req-unreg-plan
  tpu_sync/kv_cache/transfer_receive_late_finish_bughunt_test.cc:355: Failure
  Value of: consumer.base()->EndIncomingPush( 202, absl::OkStatus())
  Expected: is OK
    Actual: CANCELLED: Receive session for uuid=202 failed: receive plan unregistered
  === Source Location Trace: === 
  tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc:414
   (of type absl::lts_20260526::Status)

  W0000 00:00:1793325935.745478    1471 kv_cache_manager_with_transfer.cc:1287] Transfer failed: req_id=req-unreg-plan code=CANCELLED phase=receive elapsed_ms=0.25807 reason=receive plan unregistered
  tpu_sync/kv_cache/transfer_receive_late_finish_bughunt_test.cc:358: Failure
  Value of: completions.received
  Expected: has 1 element that is equal to "req-unreg-plan"
    Actual: {}

  tpu_sync/kv_cache/transfer_receive_late_finish_bughunt_test.cc:359: Failure
  Value of: completions.failed
  Expected: is empty
    Actual: { "req-unreg-plan" }, whose size is 1

  [  FAILED  ] RecvLateFinishBughunt.UnregisterActivePlanAfterCompletedH2dMustNotFlipReceivedToFailed (3 ms)
  [ RUN      ] RecvLateFinishBughunt.LateControlPullReplyErrorAfterCompletedH2dMustNotFlipReceivedToFailed
  I0000 00:00:1793325935.746702    1471 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793325935.746748    1471 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793325935.747183    1471 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 35121, listening tcp socket 3: [::]:35121--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793325935.747320    1471 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793325935.748129    1471 kv_cache_manager_with_transfer.cc:1058] StartRead (initiate): req_id=req-pull-reply, uuid=203, numa=-1
  I0000 00:00:1793325935.748286    1471 transfer_receive_session.cc:625] StartRead (connecting): req_id=req-pull-reply, uuid=203, numa=-1
  I0000 00:00:1793325935.748555    1471 transfer_receive_session.cc:821] OnLayerReceived (H2D copy start) layer 0: req_id=req-pull-reply, uuid=203, numa=-1
  I0000 00:00:1793325935.748620    1471 transfer_receive_session.cc:881] OnLayerReceived (H2D copy complete) layer 0: req_id=req-pull-reply, numa=-1
  I0000 00:00:1793325935.748654    1471 transfer_receive_session.cc:914] All layers H2D copy complete: req_id=req-pull-reply
  E0000 00:00:1793325935.748685    1471 transfer_receive_session.cc:655] Raiden consumer error during Hybrid Bridge StartRead connect: control pull request: control reply timed out on return leg
  W0000 00:00:1793325935.748759    1471 kv_cache_manager_with_transfer.cc:1287] Transfer failed: req_id=req-pull-reply code=DEADLINE_EXCEEDED phase=connect peer=127.0.0.1:9999 elapsed_ms=0.49503 reason=control pull request: control reply timed out on return leg
  tpu_sync/kv_cache/transfer_receive_late_finish_bughunt_test.cc:397: Failure
  Value of: completions.received
  Expected: has 1 element that is equal to "req-pull-reply"
    Actual: {}

  tpu_sync/kv_cache/transfer_receive_late_finish_bughunt_test.cc:398: Failure
  Value of: completions.failed
  Expected: is empty
    Actual: { "req-pull-reply" }, whose size is 1

  [  FAILED  ] RecvLateFinishBughunt.LateControlPullReplyErrorAfterCompletedH2dMustNotFlipReceivedToFailed (3 ms)
  [ RUN      ] RecvLateFinishBughunt.PoolReshardUnregisterAfterCompletedPoolH2dMustNotFlipReceivedToFailed
  I0000 00:00:1793325935.749992    1471 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793325935.750041    1471 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793325935.750453    1471 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 34663, listening tcp socket 3: [::]:34663--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793325935.750594    1471 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793325935.751414    1471 kv_cache_manager_base.cc:2109] KVCacheManagerBase: pool host staging configured: leases=0 bounded_storages=0 (0 B) full_mirror_storages=0 (0 B)
  W0000 00:00:1793325935.751755    1471 kv_cache_manager_with_transfer.cc:1287] Transfer failed: req_id=req-pool-reshard code=CANCELLED reason=receive plan unregistered
  tpu_sync/kv_cache/transfer_receive_late_finish_bughunt_test.cc:426: Failure
  Value of: completions.received
  Expected: has 1 element that is equal to "req-pool-reshard"
    Actual: {}

  tpu_sync/kv_cache/transfer_receive_late_finish_bughunt_test.cc:427: Failure
  Value of: completions.failed
  Expected: is empty
    Actual: { "req-pool-reshard" }, whose size is 1

  [  FAILED  ] RecvLateFinishBughunt.PoolReshardUnregisterAfterCompletedPoolH2dMustNotFlipReceivedToFailed (2 ms)
  [----------] 5 tests from RecvLateFinishBughunt (21 ms total)

  [----------] Global test environment tear-down
  [==========] 5 tests from 1 test suite ran. (21 ms total)
  [  PASSED  ] 1 test.
  [  FAILED  ] 4 tests, listed below:
  [  FAILED  ] RecvLateFinishBughunt.TrailingPushStreamErrorAfterCompletedH2dMustNotFlipReceivedToFailed
  [  FAILED  ] RecvLateFinishBughunt.UnregisterActivePlanAfterCompletedH2dMustNotFlipReceivedToFailed
  [  FAILED  ] RecvLateFinishBughunt.LateControlPullReplyErrorAfterCompletedH2dMustNotFlipReceivedToFailed
  [  FAILED  ] RecvLateFinishBughunt.PoolReshardUnregisterAfterCompletedPoolH2dMustNotFlipReceivedToFailed
  ```
- **Fix:** gate **recording the error** (not `draining_ = true` itself, which
  the final `Finish(OkStatus())` call still needs to set!) once every upload
  has completed OK: in `TransferReceiveSession::FinishLocked`, compute
  `all_uploaded_ok = (total_layers > 0 ? num_completed_layers_ >= static_cast<int32_t>(total_layers) : network_completed_)`
  (where `total_layers = base_ != nullptr ? base_->num_layers() : 0`) and guard
  the assignment with `if (!status.ok() && status_.ok() && !done_ && !all_uploaded_ok)`
  (checking `num_completed_layers_` directly rather than setting a latch inside
  `ExecuteLayerH2d`'s `&& !self->draining_` block at `:886-890`, which is
  skipped when the poll-side `Finish()` set `draining_ = true` before the last
  H2D `OnReady` callback ran); in `ReshardReceiveSession::FinishLocked`, guard
  the assignment with
  `if (!status.ok() && status_.ok() && !done_ && !network_completed_)` (since
  `FinishPoolH2d` sets `network_completed_ = true` at `:699` *before* calling
  `Finish(terminal_status)` at `:702`, returning early on `network_completed_`
  before `draining_ = true` would prevent `done_` from ever becoming `true`);
  and in `ReshardSendSession::Finish`, move `if (done_ || finalizing_) return;`
  to the top (safe there because `ReshardSendSession` has no `IsReadyToComplete`
  poll). **Do not** copy `TransferSendSession`'s `if (draining_ || done_) return;`
  onto `TransferReceiveSession::FinishLocked` (the fix originally proposed here):
  it would drop an H2D failure that lands after the poll-side `Finish()` and
  publish `done_recving` over a failed copy.

---

## F15. `ReshardReceiveSession` deadlocks on its per-pool host staging slots when a higher-rank pool's bytes arrive before a lower-rank pool has a slot

- **Status:** **CONFIRMED (test)** 2026-11-02, on unmodified `56a0269d`:
  `reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc` (1 control + 1
  case; `ReshardRecvStagingSlotRankDeadlock`). **Filed 2026-11-02** (bug 13 in
  `filed_bugs.md`). Found while
  scoping bounded host layer staging out of the reshard Lean models at the
  `56a0269d` sync: the composition of the per-pool slot lease (`951b49be`,
  2026-10-28) with the pre-existing rank-wave H2D gate is a classic
  hold-and-wait cycle.
- **Root cause (`56a0269d`):** `ReshardReceiveSession` constructs its
  `staging_layer_manager_` with `base->num_host_layers()` slots
  (`reshard_receive_session.cc:398`) and leases one slot per **pool index**
  (`AcquireStagingSlot(pool_idx)`, `:482-506`), unconditionally — unlike
  `TransferReceiveSession::AcquireStagingSlot`, which returns `NotFound("no
  bounded host staging")` on a full mirror and lets `GetBlockChunks` address
  the layer in place. The lease is taken on the push thread by the pool's
  first chunk (`KVCacheManagerBase::GetBlockChunks` →
  `session->ResolveStagingSlot(layer_idx)` with `layer_idx` the pool index,
  `kv_cache_manager_base.cc:3137-3147`) and released only when the pool's H2D
  completes (`ExecuteEligiblePoolH2ds`'s `OnReady`, `:677-687`) or fails.
  `CollectEligiblePoolH2dsLocked` (`:566-595`) launches a pool's H2D only when
  every pool of strictly lower `order_rank` is `completed`, and
  `BuildPoolReshardPlan` assigns `order_rank = group_idx == 0 ? 0 : 1`
  (`pool_reshard_planner.cc:1262`: FA first, state classes after it on aliased
  arena pages). Slots are storages (`num_host_layers()` = `layers_.size()`)
  while each tag selects its own pools, so when several tags' pools share a
  storage a multi-tag plan has more pools than slots (fewer slots still with
  `num_staging_layers`), and once every free slot is held by rank-1 pools whose
  rank-0 counterparts have no slot, nothing can progress: the rank-0 pools'
  push threads block in `StagingLayerManager::Acquire(pool_idx, deadline_,
  &cancelled_)`, the rank-1 pools' H2Ds wait for the rank-0 pools, and after
  `timeout_s_` (default 120 s) `AcquireStagingSlot` runs
  `FinishLocked(DeadlineExceeded)`, `CompleteReadWithDetails` publishes
  `failed_recving`, and every sender's push for those pools fails on the ack.
- **C++ test output** (unmodified code, verbatim, 2026-11-02; `timeout_s = 2`):
  ```
  [ RUN      ] ReshardRecvStagingSlotRankDeadlock.Control_OneSlotPerPoolResolvesTheLowerRankPoolAtOnce
  [       OK ] ReshardRecvStagingSlotRankDeadlock.Control_OneSlotPerPoolResolvesTheLowerRankPoolAtOnce (7 ms)
  [ RUN      ] ReshardRecvStagingSlotRankDeadlock.LowerRankPoolResolvesWhileHigherRankPoolHoldsTheLastSlot
  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:236: Failure
  Expected equality of these values:
      Which is: 0
      Which is: 1
  [F15] rank-0 pool's first chunk resolved to no host bytes after 1.999620679s (the rank-1 pool holds the only staging slot)
  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:239: Failure
  Expected: (blocked) < (absl::Seconds(kTimeoutS / 2)), actual: 1.999620679s vs 1s
  [F15] rank-0 push thread was parked in StagingLayerManager::Acquire for 1.999620679s (timeout_s=2)
  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:246: Failure
  Expected: false
  [F15] receive is draining with status DEADLINE_EXCEEDED: Timed out waiting for a free staging slot for unit 0
  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:248: Failure
  Expected: is OK
  W0000 00:00:1793642090.962536      12 kv_cache_manager_with_transfer.cc:1069] Transfer failed: req_id=pool_reshard_req_5103 code=DEADLINE_EXCEEDED reason=Timed out waiting for a free staging slot for unit 0
  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:251: Failure
  Expected: is empty
  [F15] receive with every byte of both pools on its way failed at the deadline
  [  FAILED  ] ReshardRecvStagingSlotRankDeadlock.LowerRankPoolResolvesWhileHigherRankPoolHoldsTheLastSlot (2004 ms)
  ```
  The test drives the two entry points the push thread uses
  (`GetBlockChunks` for the first chunk, `OnPoolReceived` for the completed
  stream) on a `KVCacheManagerBase` with one device storage, two pools
  (`fa`, `swa`) on it and `num_layers = 1` (one host layer buffer, so one
  slot); the control is the same sequence with `num_layers = 2`. No H2D is
  issued in either case (the rank-1 pool's upload is gated), which is what
  lets it run on CPU — at `56a0269d` `KVCacheManagerBase::CopyPoolBlocks`
  calls `GetOnDeviceSizeInBytes()` on the placeholder device hold and
  segfaults, so the CPU pool-H2D seam `coverage_gap_reshard_sessions.patch`
  relied on is gone.
- **Reachability (audited 2026-11-02):** the precondition, more pools than
  slots, holds in production: slots are storages (`num_host_layers()` =
  `layers_.size()`), and `vllm-torchtpu` Stage-3 sends one transfer per request
  carrying several tags (GLM `mla.nope` / `mla.rope` / `dsa.idx`; Kimi `fa` +
  `gdn.conv.gN` / `gdn.ssm.gN`), so whenever several tags' pools share a storage
  (the aliased-page layout `order_rank` exists for) `pools > slots`. The
  trigger is narrower than "≥ 2 tags and ≥ 2 senders": a slot is keyed by
  **pool index** and shared by every sender and stream of that pool, so once
  any sender's first chunk for a rank-0 pool arrives, that pool holds a slot
  and later senders' bytes for it need none. The cycle closes only if every
  slot ends up held by a gated rank-1 pool while some rank-0 pool has received
  no first chunk from any sender. Two ways there:
  1. *Arrival reordering within a sender.* `ReshardSendSession` issues D2H in
     `order_rank` order (`reshard_send_session.cc:314-317`), but each pool's
     transport reads wait on that pool's `GetDataReadyFuture` and pools push
     concurrently, so a rank-1 pool's first chunk can reach the receiver
     before a rank-0 pool's. A finished push frees the *sender's* slot while
     the receiver keeps its lease until the gated H2D, so a sender can cycle
     several rank-1 pools through while one rank-0 D2H lags.
  2. *Rank-blind hand-off.* `StagingLayerManager::Acquire` waits on an
     `absl::Mutex` condition with no ordering, so once rank-0 laggards and
     rank-1 pools both wait, each slot a completing rank-0 pool releases can
     go to a rank-1 waiter.
  One sender can suffice; more senders, tags and layers in flight make it
  likelier, and bounded receive staging (`num_staging_layers < num_layers`,
  which neither `vllm-torchtpu` nor `sglang-torchtpu` sets) makes it much
  likelier. When it fires the receive stalls `timeout_s_` (120 s default) with
  the stalled streams' transport reader threads parked, then fails
  `DEADLINE_EXCEEDED`. Single-tag plans and `sglang-torchtpu` requests that
  split classes into separate uuids (`pp_swa.twin_uuid`) are not affected.
  Not shown: an end-to-end run producing the arrival order (the test drives
  the receiver's entry points in a chosen order).
- **Candidate fixes:** (b) is the safe shape: lease in rank order — do not
  hand a slot to a pool while some lower-rank pool of the plan holds none
  (reserve one slot per lower-rank pool not yet leased), or equivalently make
  the hand-off rank-aware so a released slot goes to the lowest-rank waiter
  first. (c) at minimum, fail the wait fast with a diagnostic naming the slot
  holders instead of consuming the whole transfer deadline. (a) addressing
  pools in place on a full mirror (as `TransferReceiveSession::AcquireStagingSlot`
  does) restores the pre-`951b49be` behaviour but needs a check first: pools of
  different tags may alias the same storage bytes (the planner rejects overlap
  only within a pool, `pool_layout.cc`), and in-place staging would let one
  pool's incoming bytes overwrite another's host bytes before its gated H2D
  reads them, which the per-pool slots currently prevent. The sender has the
  same per-pool lease (`reshard_send_session.cc:174`, `:181-203`) but acquires
  in rank order and releases on push completion, so it only serialises.
- **Repro:** `reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc`;
  copy to `tpu_sync/kv_cache/`, apply `findings/build_targets.patch`, and run
  `bazel test --config=oss //tpu_sync/kv_cache:reshard_recv_staging_slot_rank_deadlock_bughunt_test`.
- **Re-run 2026-11-09 on unmodified `00e946e3`** (the reproducer's two
  `OnPoolReceived(pool_idx, uuid)` calls ported to `OnLayerReceived(pool_idx,
  uuid)` after `9c9f92ff` removed the former; `AcquireStagingSlot`,
  `CollectEligiblePoolH2dsLocked` and `StagingLayerManager::Acquire` are
  unchanged, `49e2c36c` only moved the class into `reshard_receive_session.cc`'s
  anonymous namespace behind `CreateReshardReceiveSession`). Still 1 control
  passing + 1 case failing; gtest lines of the verbatim log (glog lines
  dropped):
  ```
  [ RUN      ] ReshardRecvStagingSlotRankDeadlock.Control_OneSlotPerPoolResolvesTheLowerRankPoolAtOnce
  [       OK ] ReshardRecvStagingSlotRankDeadlock.Control_OneSlotPerPoolResolvesTheLowerRankPoolAtOnce (8 ms)
  [ RUN      ] ReshardRecvStagingSlotRankDeadlock.LowerRankPoolResolvesWhileHigherRankPoolHoldsTheLastSlot
  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:246: Failure
  Expected equality of these values:
    rank0_chunks
      Which is: 0
    1u
      Which is: 1
  [F15] rank-0 pool's first chunk resolved to no host bytes after 1.999661353s (the rank-1 pool holds the only staging slot)

  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:249: Failure
  Expected: (blocked) < (absl::Seconds(kTimeoutS / 2)), actual: 1.999661353s vs 1s
  [F15] rank-0 push thread was parked in StagingLayerManager::Acquire for 1.999661353s (timeout_s=2)

  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:256: Failure
  Value of: session->IsDraining()
    Actual: true
  Expected: false
  [F15] receive is draining with status DEADLINE_EXCEEDED: Timed out waiting for a free staging slot for unit 0
  === Source Location Trace: === 
  tpu_sync/kv_cache/transfer_receive_session.cc:110


  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:258: Failure
  Value of: session->GetStatus()
  Expected: is OK
    Actual: DEADLINE_EXCEEDED: Timed out waiting for a free staging slot for unit 0
  === Source Location Trace: === 
  tpu_sync/kv_cache/transfer_receive_session.cc:110
   (of type absl::lts_20260526::Status)

  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:261: Failure
  Value of: failed
  Expected: is empty
    Actual: { "pool_reshard_req_5103" }, whose size is 1
  [F15] receive with every byte of both pools on its way failed at the deadline

  [  FAILED  ] ReshardRecvStagingSlotRankDeadlock.LowerRankPoolResolvesWhileHigherRankPoolHoldsTheLastSlot (2005 ms)
  ```
  Note for the next re-check: `4e61045e` added a second push-thread entry into
  `ResolveStagingSlot` — `BlockTransportDelegate::GetBlockArrayHostSpan` →
  `KVCacheManagerBase::ResolveBlockArrayHostLayer` → `session->ResolveStagingSlot(pool)`,
  used by the shared `ValidateChunks` — so the blocking `Acquire` is now also
  reachable from chunk validation, not only from `GetBlockChunks`.
- **Re-run 2026-11-11 on unmodified `d3751fcb`** after upstream `47e9f200`
  ("Stage explicit-pool reshard transfers in place on a full host mirror"):
  `ReshardReceiveSession` now constructs `staging_layer_manager_` with
  `HostLayersBounded() ? base->num_host_layers() : 0` slots
  (`HostLayersBounded()` = `base_->num_host_layers() < base_->num_layers()`) and
  returns `StaticHostLayer(pool_idx) = pool->storage_index` from
  `AcquireStagingSlot` and `LookupStagingSlot` when `!HostLayersBounded()`.
  That narrows the `StagingLayerManager::Acquire` deadlock to bounded host layer
  staging (`num_staging_layers < num_layers`), while realizing candidate fix
  `(a)`'s aliased-storage host-buffer overwrite on a full host mirror: when two
  pools of different `order_rank` share `storage_index = 0` and destination
  block `0`, `GetBlockChunks` hands both pools the exact same host buffer
  address (`0x557d2d008a00`), so when the rank-1 pool (`swa`) arrives first and
  its H2D is held back behind rank 0, the rank-0 pool (`fa`) arriving next
  overwrites rank 1's staged `0xBB` bytes with `0xAA` before rank 1's H2D runs,
  and `CompleteReadRaw()` publishes `done_recving` with rank 1's upload reading
  `0xAA`. Extended `reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc` to
  1 control (`num_layers = 3, num_staging_layers = 2`) + 2 failing cases
  (bounded-staging deadlock at `num_layers = 2, num_staging_layers = 1`, and
  full-mirror in-place aliased-host clobber at `num_layers = 1`); gtest lines of
  the verbatim log (glog lines dropped):
  ```
  [ RUN      ] ReshardRecvStagingSlotRankDeadlock.Control_OneSlotPerPoolResolvesTheLowerRankPoolAtOnce
  [       OK ] ReshardRecvStagingSlotRankDeadlock.Control_OneSlotPerPoolResolvesTheLowerRankPoolAtOnce (9 ms)
  [ RUN      ] ReshardRecvStagingSlotRankDeadlock.LowerRankPoolResolvesWhileHigherRankPoolHoldsTheLastSlot
  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:308: Failure
  Expected equality of these values:
    rank0_chunks
      Which is: 0
    1u
      Which is: 1
  [F15] rank-0 pool's first chunk resolved to no host bytes after 1.999623796s (the rank-1 pool holds the only staging slot)

  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:311: Failure
  Expected: (blocked) < (absl::Seconds(kTimeoutS / 2)), actual: 1.999623796s vs 1s
  [F15] rank-0 push thread was parked in StagingLayerManager::Acquire for 1.999623796s (timeout_s=2)

  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:318: Failure
  Value of: session->IsDraining()
    Actual: true
  Expected: false
  [F15] receive is draining with status DEADLINE_EXCEEDED: Timed out waiting for a free staging slot for unit 0
  === Source Location Trace: === 
  tpu_sync/kv_cache/transfer_receive_session.cc:110


  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:320: Failure
  Value of: session->GetStatus()
  Expected: is OK
    Actual: DEADLINE_EXCEEDED: Timed out waiting for a free staging slot for unit 0
  === Source Location Trace: === 
  tpu_sync/kv_cache/transfer_receive_session.cc:110
   (of type absl::lts_20260526::Status)

  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:323: Failure
  Value of: failed
  Expected: is empty
    Actual: { "pool_reshard_req_5103" }, whose size is 1
  [F15] receive with every byte of both pools on its way failed at the deadline

  [  FAILED  ] ReshardRecvStagingSlotRankDeadlock.LowerRankPoolResolvesWhileHigherRankPoolHoldsTheLastSlot (2006 ms)
  [ RUN      ] ReshardRecvStagingSlotRankDeadlock.FullHostMirrorInPlaceStagingPreservesHeldRank1BytesWhenRank0ArrivesLater
  tpu_sync/kv_cache/reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc:379: Failure
  Expected equality of these values:
    manager.device_base().UploadedBytes( 1)
      Which is: { '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170), '\xAA' (170) }
    std::vector<uint8_t>(16, 0xBB)
      Which is: { '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187), '\xBB' (187) }
  [F15 / 47e9f200] full-mirror in-place staging resolved rank-0 and rank-1 pools to the same host buffer (0x557d2d008a00 vs 0x557d2d008a00), so rank-0's push overwrote rank-1's staged bytes with 0xAA before rank-1's gated H2D ran

  [  FAILED  ] ReshardRecvStagingSlotRankDeadlock.FullHostMirrorInPlaceStagingPreservesHeldRank1BytesWhenRank0ArrivesLater (4 ms)
  ```

---

## F16. `KVCacheManagerWithTransfer` UUID retirement omits `BlockTransport::ForgetPushProgress` on inline replacement and sweeps it unlocked behind a dead `std::erase_if` guard, suppressing layer H2D and publishing silent corrupt `done_recving`

- **Status:** **CONFIRMED (test)** 2026-11-03, on unmodified `56a0269d`:
  `kv_transfer_uuid_and_reshard_push_bughunt_test.cc` (`UuidRetirementBughunt`,
  1 control passing + 3 cases failing). Found during the `56a0269d`
  model-to-code audit of `UuidTable.lean` (`retireAndReplace` / `sweepSettled`)
  against `KVCacheManagerWithTransfer` (`10d181f6` / `1523b07d`).
- **Root cause (`56a0269d`):** when `10d181f6` and `1523b07d` unified
  `sessions_` under `TransferSession` and added inline settled-session
  retirement on UUID reuse, transport push-progress cleanup
  (`BlockTransport::ForgetPushProgress(uuid)`) and reshard pool-staging cleanup
  (`KVCacheManagerBase::ReleasePoolStagingLeases(uuid)`) were split from the
  `mu_` critical section in two broken ways:
  1. *Omitted cleanup on inline retirement.* `RetireSettledSessionLocked`
     (`kv_cache_manager_with_transfer.cc:436-511`) records
     `*retired_push_progress = true` (`:447-449`) and
     `*retired_pool_leases = true` (`:464-466`, `:499-501`) only when the caller
     passes non-null out-parameters. Two inline-replacement callers invoke
     `RetireSettledSessionLocked(existing)` with default `nullptr` arguments and
     never call `ForgetPushProgress(uuid)` or `ReleasePoolStagingLeases(uuid)`
     at all:
     - `StartRead` (`:920-921`), when a pull reuses a `uuid` whose prior session
       already settled (`existing->second->Done()`) before
       `CompleteReadWithDetails` swept it;
     - `EmplaceRecvSessionLocked` (`:576`), reached directly by `RegisterRecv`
       (`:672`) under the same precondition (`RegisterActivePlan` checks before
       calling `EmplaceRecvSessionLocked`, `:600-608`, so only `RegisterRecv`
       hits `:576`).
  2. *Dead `std::erase_if` guard + unlocked post-`mu_` cleanup.*
     `CompleteReadWithDetails` (`:1039-1066`) erases settled entries from
     `sessions_` inside `mu_` (`:1043`), immediately runs `std::erase_if` on
     `retired_uuids` checking `sessions_.contains(uuid) ||
     pending_pool_reshard_recvs_.contains(uuid)` **still inside that same `mu_`
     critical section** (`:1046-1050` — no concurrent registration can run while
     `mu_` is held, so the filter is dead code for every non-pending UUID it
     just erased), unlocks `mu_` (`:1058`), and then calls
     `ForgetPushProgress(entry.uuid)` and `ReleasePoolStagingLeases(entry.uuid)`
     unlocked (`:1061-1066`). Any replacement session registered in the window
     after `:1058` has its live push progress (or pool-staging lease) wiped
     mid-transfer. For the same reason, `RegisterActivePlan` (`:624`/`635` →
     `:649-653`), `PoolReshardPush` (`:702-709`), and `PoolReshardRegisterRecv`
     (`:749-756`) drop `mu_` after seating or reserving the replacement `uuid`
     before calling `ForgetPushProgress(uuid)` /
     `ReleasePoolStagingLeases(uuid)`; in `RegisterActivePlan`, the new
     `TransferReceiveSession` is already live in `sessions_` at `:624`/`:635`
     before `:651` runs `ForgetPushProgress(uuid)`, so an eager push for the
     newly registered plan can land in `[635, 651]` and be wiped by its *own*
     registration call.
  3. *Why stale or wiped `layer_progress_` causes silent HBM corruption.* In
     `BlockTransportServerPushSession::StartStream`
     (`block_transport_session.cc:461-471`), `CompleteIncomingPush` (`:609-684`)
     fires `OnLayerReceived(layer_idx, uuid)` once per layer (marking
     `progress.on_layer_received_called = true`, `:653-655`, `:660`) and clears
     `layer_progress_` / marks the push session `done_` only when *every* layer
     has completed (`:656-680`), while `StartStream` unconditionally calls
     `delegate_->OnBlockShardsReceived(...)` (`:469-470`) on every stream.
     - Under (1), if Attempt #1 received layer 0 (`on_layer_received_called =
       true` on `layer_progress_[0]`) and then failed before layer 1 completed
       (e.g. control pull error or chunk-validation error on layer 1), the
       transport push session remains alive in `active_push_sessions_[uuid]`.
       Attempt #2's layer-0 stream sees `on_layer_received_called == true` and
       skips `OnLayerReceived` (no H2D for layer 0), yet `OnBlockShardsReceived`
       still increments Attempt #2's per-shard block count; once layer 1's
       stream lands and its H2D finishes, `RecordBlockShardsReceivedLocked` sets
       `network_completed_ = true` (`transfer_receive_session.cc:580-594`),
       `IsReadyToComplete()` (`:558-564`, `(network_completed_ ||
       num_completed_layers_ == total_layers) && AllH2dDoneLocked()`) returns
       `true` (`in_flight_ == 0`), and `CompleteReadWithDetails` publishes
       Attempt #2 in `completions.received` (`done_recving`) with layer 0's HBM
       blocks untouched.
     - Under (2), on a 2-sender receiver plan (`ExpectedPushSenders == 2`,
       `:648`), if `sender_0`'s layer-0 stream lands before the unlocked
       `ForgetPushProgress(uuid)` wipes `active_push_sessions_[uuid]`,
       `sender_1`'s layer-0 stream starts a fresh `layer_progress_[0]` with
       `senders_complete == 1 < 2` (so layer 0's `OnLayerReceived` never fires),
       while both senders' `OnBlockShardsReceived` callbacks still count toward
       `network_completed_` on the `TransferReceiveSession`, again publishing
       `completions.received` with layer 0's HBM blocks unwritten.
- **C++ test output** (unmodified `56a0269d`, verbatim, 2026-11-03):
  ```
  [----------] 4 tests from UuidRetirementBughunt
  [ RUN      ] UuidRetirementBughunt.Control_SweepBeforeSameUuidStartReadCopiesEveryLayer
  WARNING: All log messages before absl::InitializeLog() is called are written to STDERR
  I0000 00:00:1793730701.579221    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.579376    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.580308    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 38191, listening tcp socket 3: [::]:38191--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.580714    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793730701.582288    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.582339    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.582727    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 32931, listening tcp socket 4: [::]:32931--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.582875    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793730701.583872    1438 kv_cache_manager_with_transfer.cc:897] StartRead (initiate): req_id=req_1, uuid=7701, numa=-1
  I0000 00:00:1793730701.584064    1438 transfer_receive_session.cc:642] StartRead (connecting): req_id=req_1, uuid=7701, numa=-1
  I0000 00:00:1793730701.585099    1481 conn_util.cc:235] connected tcp socket 5: 127.0.0.1:48526--127.0.0.1:38191
  I0000 00:00:1793730701.585348    1482 raw_buffer_transport.cc:717] accepted tcp socket 6: [::ffff:127.0.0.1]:38191--[::ffff:127.0.0.1]:48526
  I0000 00:00:1793730701.585643    1482 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=6, op=6, uuid=7701, numa=0
  I0000 00:00:1793730701.586200    1482 transfer_receive_session.cc:842] OnLayerReceived (H2D copy start) layer 0: req_id=req_1, uuid=7701, numa=-1
  I0000 00:00:1793730701.586308    1482 transfer_receive_session.cc:900] OnLayerReceived (H2D copy complete) layer 0: req_id=req_1, numa=-1
  E0000 00:00:1793730701.586662    1438 transfer_receive_session.cc:672] Raiden consumer error during Hybrid Bridge StartRead connect: control pull request: producer died after layer 0
  W0000 00:00:1793730701.586817    1438 kv_cache_manager_with_transfer.cc:1069] Transfer failed: req_id=req_1 code=UNAVAILABLE phase=connect peer=127.0.0.1:9 elapsed_ms=2.72844 reason=control pull request: producer died after layer 0
  I0000 00:00:1793730701.586885    1438 kv_cache_manager_with_transfer.cc:897] StartRead (initiate): req_id=req_2, uuid=7701, numa=-1
  I0000 00:00:1793730701.587001    1438 transfer_receive_session.cc:642] StartRead (connecting): req_id=req_2, uuid=7701, numa=-1
  I0000 00:00:1793730701.587915    1482 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=6, op=6, uuid=7701, numa=0
  I0000 00:00:1793730701.588360    1482 transfer_receive_session.cc:842] OnLayerReceived (H2D copy start) layer 0: req_id=req_2, uuid=7701, numa=-1
  I0000 00:00:1793730701.588419    1482 transfer_receive_session.cc:900] OnLayerReceived (H2D copy complete) layer 0: req_id=req_2, numa=-1
  I0000 00:00:1793730701.588923    1482 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=6, op=6, uuid=7701, numa=0
  I0000 00:00:1793730701.589239    1482 transfer_receive_session.cc:842] OnLayerReceived (H2D copy start) layer 1: req_id=req_2, uuid=7701, numa=-1
  I0000 00:00:1793730701.589311    1482 transfer_receive_session.cc:900] OnLayerReceived (H2D copy complete) layer 1: req_id=req_2, numa=-1
  I0000 00:00:1793730701.589350    1482 transfer_receive_session.cc:927] All layers H2D copy complete: req_id=req_2
  I0000 00:00:1793730701.590047    1482 raw_buffer_transport.cc:742] peer closed tcp socket 6: [::ffff:127.0.0.1]:38191--[::ffff:127.0.0.1]:48526
  [       OK ] UuidRetirementBughunt.Control_SweepBeforeSameUuidStartReadCopiesEveryLayer (14 ms)
  [ RUN      ] UuidRetirementBughunt.StartReadInlineRetirementSkipsLayerZeroH2dAndPublishesCorruptSuccess
  I0000 00:00:1793730701.592093    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.592148    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.592513    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 44253, listening tcp socket 3: [::]:44253--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.592648    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793730701.593766    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.593812    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.594378    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 33295, listening tcp socket 4: [::]:33295--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.594535    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793730701.595475    1438 kv_cache_manager_with_transfer.cc:897] StartRead (initiate): req_id=req_1, uuid=7702, numa=-1
  I0000 00:00:1793730701.595615    1438 transfer_receive_session.cc:642] StartRead (connecting): req_id=req_1, uuid=7702, numa=-1
  I0000 00:00:1793730701.596117    1511 conn_util.cc:235] connected tcp socket 5: 127.0.0.1:46448--127.0.0.1:44253
  I0000 00:00:1793730701.596337    1512 raw_buffer_transport.cc:717] accepted tcp socket 6: [::ffff:127.0.0.1]:44253--[::ffff:127.0.0.1]:46448
  I0000 00:00:1793730701.596452    1512 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=6, op=6, uuid=7702, numa=0
  I0000 00:00:1793730701.596768    1512 transfer_receive_session.cc:842] OnLayerReceived (H2D copy start) layer 0: req_id=req_1, uuid=7702, numa=-1
  I0000 00:00:1793730701.596837    1512 transfer_receive_session.cc:900] OnLayerReceived (H2D copy complete) layer 0: req_id=req_1, numa=-1
  E0000 00:00:1793730701.597038    1438 transfer_receive_session.cc:672] Raiden consumer error during Hybrid Bridge StartRead connect: control pull request: producer died after layer 0
  I0000 00:00:1793730701.597106    1438 kv_cache_manager_with_transfer.cc:897] StartRead (initiate): req_id=req_2, uuid=7702, numa=-1
  I0000 00:00:1793730701.597261    1438 transfer_receive_session.cc:642] StartRead (connecting): req_id=req_2, uuid=7702, numa=-1
  I0000 00:00:1793730701.597710    1512 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=6, op=6, uuid=7702, numa=0
  I0000 00:00:1793730701.598329    1512 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=6, op=6, uuid=7702, numa=0
  I0000 00:00:1793730701.598602    1512 transfer_receive_session.cc:842] OnLayerReceived (H2D copy start) layer 1: req_id=req_2, uuid=7702, numa=-1
  I0000 00:00:1793730701.598660    1512 transfer_receive_session.cc:900] OnLayerReceived (H2D copy complete) layer 1: req_id=req_2, numa=-1
  I0000 00:00:1793730701.598942    1438 kv_cache_manager_with_transfer.cc:1022] CompleteReadRaw (polling completion): req_id=req_2
  W0000 00:00:1793730701.599054    1438 kv_cache_manager_with_transfer.cc:1069] Transfer failed: req_id=req_1 code=UNAVAILABLE phase=connect peer=127.0.0.1:9 elapsed_ms=1.53439 reason=control pull request: producer died after layer 0
  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:424: Failure
  Value of: consumer.sim_base()->DispatchedLayers()
  Expected: has 2 elements where
  element #0 is equal to 0,
  element #1 is equal to 1
    Actual: { 1 }, which has 1 element
  [F16] StartRead inline retirement omitted ForgetPushProgress(7702), suppressing layer 0's H2D on req_2

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:427: Failure
  Expected equality of these values:
    consumer.sim_base()->HbmByte( 0, 1)
      Which is: '\xEE' (238)
    0xB0
      Which is: 176
  [F16] req_2 was reported in completions.received (done_recving) with poison byte 0xEE still in layer 0's HBM block

  I0000 00:00:1793730701.600523    1512 raw_buffer_transport.cc:742] peer closed tcp socket 6: [::ffff:127.0.0.1]:44253--[::ffff:127.0.0.1]:46448
  [  FAILED  ] UuidRetirementBughunt.StartReadInlineRetirementSkipsLayerZeroH2dAndPublishesCorruptSuccess (10 ms)
  [ RUN      ] UuidRetirementBughunt.RegisterRecvInlineRetirementSkipsLayerZeroH2dAndPublishesCorruptSuccess
  I0000 00:00:1793730701.602332    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.602387    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.602914    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 37235, listening tcp socket 3: [::]:37235--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.603078    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793730701.604202    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.604247    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.604622    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 36983, listening tcp socket 4: [::]:36983--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.604766    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793730701.605860    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.605955    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.606338    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 41301, listening tcp socket 5: [::]:41301--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.606502    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793730701.607849    1555 conn_util.cc:235] connected tcp socket 6: 127.0.0.1:38820--127.0.0.1:37235
  I0000 00:00:1793730701.608017    1556 raw_buffer_transport.cc:717] accepted tcp socket 7: [::ffff:127.0.0.1]:37235--[::ffff:127.0.0.1]:38820
  I0000 00:00:1793730701.608122    1556 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=7, op=6, uuid=7703, numa=0
  I0000 00:00:1793730701.608412    1556 transfer_receive_session.cc:842] OnLayerReceived (H2D copy start) layer 0: req_id=req_1, uuid=7703, numa=-1
  I0000 00:00:1793730701.608495    1556 transfer_receive_session.cc:900] OnLayerReceived (H2D copy complete) layer 0: req_id=req_1, numa=-1
  I0000 00:00:1793730701.608927    1556 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=7, op=6, uuid=7703, numa=0
  E0000 00:00:1793730701.609201    1556 block_transport.cc:431] Incoming push rejected: uuid=7703 op=6 local_id=1: OUT_OF_RANGE: Chunk out of bounds. Chunk ptr: 93841372993792, size: 128, Block array base: 93841372865920, Block array size: 1024
  === Source Location Trace: === 
  tpu_sync/transport/block_transport_session.cc:148
  tpu_sync/transport/block_transport_session.cc:452
  tpu_sync/transport/block_transport_session.cc:181
  tpu_sync/transport/block_transport_session.cc:452

  E0000 00:00:1793730701.609274    1556 raw_buffer_transport.cc:749] ProcessPeerRequest failed: OUT_OF_RANGE: Chunk out of bounds. Chunk ptr: 93841372993792, size: 128, Block array base: 93841372865920, Block array size: 1024
  === Source Location Trace: === 
  tpu_sync/transport/block_transport_session.cc:148
  tpu_sync/transport/block_transport_session.cc:452
  tpu_sync/transport/block_transport_session.cc:181
  tpu_sync/transport/block_transport_session.cc:452

  I0000 00:00:1793730701.609937    1557 conn_util.cc:235] connected tcp socket 6: 127.0.0.1:38828--127.0.0.1:37235
  I0000 00:00:1793730701.610126    1558 raw_buffer_transport.cc:717] accepted tcp socket 7: [::ffff:127.0.0.1]:37235--[::ffff:127.0.0.1]:38828
  I0000 00:00:1793730701.610252    1558 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=7, op=6, uuid=7703, numa=0
  I0000 00:00:1793730701.610946    1558 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=7, op=6, uuid=7703, numa=0
  I0000 00:00:1793730701.611236    1558 transfer_receive_session.cc:842] OnLayerReceived (H2D copy start) layer 1: req_id=req_2, uuid=7703, numa=-1
  I0000 00:00:1793730701.611313    1558 transfer_receive_session.cc:900] OnLayerReceived (H2D copy complete) layer 1: req_id=req_2, numa=-1
  I0000 00:00:1793730701.611495    1438 kv_cache_manager_with_transfer.cc:1022] CompleteReadRaw (polling completion): req_id=req_2
  W0000 00:00:1793730701.611607    1438 kv_cache_manager_with_transfer.cc:1069] Transfer failed: req_id=req_1 code=INTERNAL phase=receive elapsed_ms=1.77906 reason=Incoming push failed
  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:496: Failure
  Value of: consumer.sim_base()->DispatchedLayers()
  Expected: has 2 elements where
  element #0 is equal to 0,
  element #1 is equal to 1
    Actual: { 1 }, which has 1 element
  [F16] RegisterRecv inline retirement omitted ForgetPushProgress(7703), suppressing layer 0's H2D on req_2

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:499: Failure
  Expected equality of these values:
    consumer.sim_base()->HbmByte( 0, 0)
      Which is: '\xEE' (238)
    0xB0
      Which is: 176
  [F16] req_2 was reported in completions.received (done_recving) with poison byte 0xEE still in layer 0's HBM block

  I0000 00:00:1793730701.612180    1558 raw_buffer_transport.cc:742] peer closed tcp socket 7: [::ffff:127.0.0.1]:37235--[::ffff:127.0.0.1]:38828
  [  FAILED  ] UuidRetirementBughunt.RegisterRecvInlineRetirementSkipsLayerZeroH2dAndPublishesCorruptSuccess (12 ms)
  [ RUN      ] UuidRetirementBughunt.CompleteReadSweepDeadEraseIfWipesLiveReplacementAndPublishesCorruptHbm
  I0000 00:00:1793730701.614596    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.614644    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.615035    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 38987, listening tcp socket 3: [::]:38987--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.615187    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793730701.616293    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.616338    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.616737    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 43235, listening tcp socket 4: [::]:43235--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.616889    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793730701.618057    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.618105    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.618447    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 35555, listening tcp socket 5: [::]:35555--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.618595    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1793730701.631045    1438 kv_cache_manager_with_transfer.cc:641] RegisterActivePlan (Receiver): Populated sessions_ for UUID 8801 with 2 total physical block-pushes (including duplicates across sources) for automatic H2D.
  I0000 00:00:1793730701.631568    1602 conn_util.cc:235] connected tcp socket 6: 127.0.0.1:58736--127.0.0.1:38987
  I0000 00:00:1793730701.631810    1603 raw_buffer_transport.cc:717] accepted tcp socket 7: [::ffff:127.0.0.1]:38987--[::ffff:127.0.0.1]:58736
  I0000 00:00:1793730701.631911    1603 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=7, op=6, uuid=8801, numa=0
  W0000 00:00:1793730701.632463    1601 kv_cache_manager_with_transfer.cc:1069] Transfer failed: req_id=old_req code=DEADLINE_EXCEEDED phase=receive elapsed_ms=0.15066 reason=Receive session timed out
  I0000 00:00:1793730701.632946    1604 conn_util.cc:235] connected tcp socket 8: 127.0.0.1:58752--127.0.0.1:38987
  I0000 00:00:1793730701.633163    1605 raw_buffer_transport.cc:717] accepted tcp socket 9: [::ffff:127.0.0.1]:38987--[::ffff:127.0.0.1]:58752
  I0000 00:00:1793730701.633403    1605 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=9, op=6, uuid=8801, numa=0
  I0000 00:00:1793730701.634480    1603 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=7, op=6, uuid=8801, numa=0
  I0000 00:00:1793730701.635081    1605 block_transport.cc:421] HandleCustomRequest (H2H read start): client_fd=9, op=6, uuid=8801, numa=0
  I0000 00:00:1793730701.635387    1605 transfer_receive_session.cc:842] OnLayerReceived (H2D copy start) layer 1: req_id=new_req, uuid=8801, numa=-1
  I0000 00:00:1793730701.635472    1605 transfer_receive_session.cc:900] OnLayerReceived (H2D copy complete) layer 1: req_id=new_req, numa=-1
  I0000 00:00:1793730701.635690    1438 kv_cache_manager_with_transfer.cc:1022] CompleteReadRaw (polling completion): req_id=new_req
  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:587: Failure
  Value of: consumer.sim_base()->DispatchedLayers()
  Expected: has 2 elements where
  element #0 is equal to 0,
  element #1 is equal to 1
    Actual: { 1 }, which has 1 element
  [F16] CompleteReadWithDetails post-mu_ ForgetPushProgress(8801) wiped live new_req's sender_0 layer-0 progress, suppressing layer 0's H2D

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:591: Failure
  Expected equality of these values:
    consumer.sim_base()->HbmByte( 0, 0)
      Which is: '\xEE' (238)
    0xC0
      Which is: 192
  [F16] new_req was reported in completions.received (done_recving) with poison byte 0xEE still in layer 0's HBM block

  I0000 00:00:1793730701.636719    1605 raw_buffer_transport.cc:742] peer closed tcp socket 9: [::ffff:127.0.0.1]:38987--[::ffff:127.0.0.1]:58752
  I0000 00:00:1793730701.638003    1603 raw_buffer_transport.cc:742] peer closed tcp socket 7: [::ffff:127.0.0.1]:38987--[::ffff:127.0.0.1]:58736
  [  FAILED  ] UuidRetirementBughunt.CompleteReadSweepDeadEraseIfWipesLiveReplacementAndPublishesCorruptHbm (25 ms)
  [----------] 4 tests from UuidRetirementBughunt (62 ms total)
  ```
- **Reachability:** the inline-retirement paths (`StartRead`, `RegisterRecv`)
  and the cross-thread `CompleteReadWithDetails` race require reusing a settled
  `uuid`. `tpu-inference`, `vllm-torchtpu`, and `sglang-torchtpu` mint fresh
  63/64-bit UUIDs per transfer today (§Callers), so those three paths are gated
  on callers that reuse settled UUIDs — a contract `KVCacheManagerWithTransfer`
  explicitly supports and tests (`RegisterActivePlan`, `StartRead`,
  `PoolReshardPush`, and `PoolReshardRegisterRecv` were all refactored in
  `10d181f6` / `1523b07d` specifically to retire settled incumbents inline).
  In addition, `RegisterActivePlan` (`:624`/`635` → `:651`) seats the newly
  created `TransferReceiveSession` in `sessions_` under `mu_` and then calls
  `ForgetPushProgress(uuid)` unlocked when an earlier settled session occupied
  that `uuid`, so an incoming push for the *newly* registered plan landing in
  `[635, 651]` is wiped by its own `RegisterActivePlan` call without needing a
  third thread.
- **Candidate fixes:**
  1. Key `BlockTransport::active_push_sessions_` (or `ForgetPushProgress`) and
     `PoolStagingStorage` leases by `(uuid, session_ptr)` or a monotonic
     per-registration generation so retiring an old session can never erase or
     release state belonging to a newer session.
  2. Until (1) lands, pass `&retired_push_progress, &retired_pool_leases` in
     every inline `RetireSettledSessionLocked` caller (`StartRead` `:920-921`,
     `EmplaceRecvSessionLocked` `:576`), run `ForgetPushProgress(uuid)` /
     `ReleasePoolStagingLeases(uuid)` **before** emplacing the replacement in
     `sessions_` (while holding a pending-UUID reservation so no concurrent
     registration or incoming push for the replacement is admitted yet), and
     skip `ForgetPushProgress` / `ReleasePoolStagingLeases` in
     `CompleteReadWithDetails` whenever `uuid` has been re-registered or
     reserved since it was retired.
  3. As defence in depth on the receiver, require
     `num_completed_layers_ == total_layers` (not `network_completed_ ||
     num_completed_layers_ == total_layers`) in
     `TransferReceiveSession::IsReadyToComplete` (`transfer_receive_session.cc:558-564`)
     whenever `automatic_h2d_` is active, so suppressed `OnLayerReceived`
     callbacks can never publish `done_recving` with unwritten layers.
- **Repro:** `kv_transfer_uuid_and_reshard_push_bughunt_test.cc`; copy to
  `tpu_sync/kv_cache/`, apply `findings/build_targets.patch`, and run
  `bazel test --config=oss //tpu_sync/kv_cache:kv_transfer_uuid_and_reshard_push_bughunt_test`.
- **Re-run 2026-11-09 on unmodified `00e946e3`** (reproducer unchanged; at HEAD
  the inline retirements are `StartRead` `:998-999` and
  `EmplaceRecvSessionLocked` `:613`, both still `RetireSettledSessionLocked(it)`
  with the default null out-parameters, the dead `std::erase_if` is
  `:1106-1110` inside the `mu_` scope that erased the uuid, the unlocked
  `ForgetPushProgress` / `ReleasePoolStagingLeases` loop `:1121-1126`, and
  `RegisterActivePlan` seats the replacement at `:669` / `:683` before its
  unlocked `ForgetPushProgress(uuid)` at `:699`). Still 1 control passing + 3
  cases failing; gtest lines of the verbatim log (glog lines dropped):
  ```
  [----------] 4 tests from UuidRetirementBughunt
  [ RUN      ] UuidRetirementBughunt.Control_SweepBeforeSameUuidStartReadCopiesEveryLayer
  [       OK ] UuidRetirementBughunt.Control_SweepBeforeSameUuidStartReadCopiesEveryLayer (13 ms)
  [ RUN      ] UuidRetirementBughunt.StartReadInlineRetirementSkipsLayerZeroH2dAndPublishesCorruptSuccess
  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:424: Failure
  Value of: consumer.sim_base()->DispatchedLayers()
  Expected: has 2 elements where
  element #0 is equal to 0,
  element #1 is equal to 1
    Actual: { 1 }, which has 1 element
  [F16] StartRead inline retirement omitted ForgetPushProgress(7702), suppressing layer 0's H2D on req_2

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:427: Failure
  Expected equality of these values:
    consumer.sim_base()->HbmByte( 0, 1)
      Which is: '\xEE' (238)
    0xB0
      Which is: 176
  [F16] req_2 was reported in completions.received (done_recving) with poison byte 0xEE still in layer 0's HBM block

  [  FAILED  ] UuidRetirementBughunt.StartReadInlineRetirementSkipsLayerZeroH2dAndPublishesCorruptSuccess (9 ms)
  [ RUN      ] UuidRetirementBughunt.RegisterRecvInlineRetirementSkipsLayerZeroH2dAndPublishesCorruptSuccess
  === Source Location Trace: === 
  tpu_sync/transport/block_transport_session.cc:297
  tpu_sync/transport/block_transport_session.cc:473
  tpu_sync/transport/block_transport_session.cc:137
  tpu_sync/transport/block_transport_session.cc:473

  === Source Location Trace: === 
  tpu_sync/transport/block_transport_session.cc:297
  tpu_sync/transport/block_transport_session.cc:473
  tpu_sync/transport/block_transport_session.cc:137
  tpu_sync/transport/block_transport_session.cc:473

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:496: Failure
  Value of: consumer.sim_base()->DispatchedLayers()
  Expected: has 2 elements where
  element #0 is equal to 0,
  element #1 is equal to 1
    Actual: { 1 }, which has 1 element
  [F16] RegisterRecv inline retirement omitted ForgetPushProgress(7703), suppressing layer 0's H2D on req_2

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:499: Failure
  Expected equality of these values:
    consumer.sim_base()->HbmByte( 0, 0)
      Which is: '\xEE' (238)
    0xB0
      Which is: 176
  [F16] req_2 was reported in completions.received (done_recving) with poison byte 0xEE still in layer 0's HBM block

  [  FAILED  ] UuidRetirementBughunt.RegisterRecvInlineRetirementSkipsLayerZeroH2dAndPublishesCorruptSuccess (12 ms)
  [ RUN      ] UuidRetirementBughunt.CompleteReadSweepDeadEraseIfWipesLiveReplacementAndPublishesCorruptHbm
  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:587: Failure
  Value of: consumer.sim_base()->DispatchedLayers()
  Expected: has 2 elements where
  element #0 is equal to 0,
  element #1 is equal to 1
    Actual: { 1 }, which has 1 element
  [F16] CompleteReadWithDetails post-mu_ ForgetPushProgress(8801) wiped live new_req's sender_0 layer-0 progress, suppressing layer 0's H2D

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:591: Failure
  Expected equality of these values:
    consumer.sim_base()->HbmByte( 0, 0)
      Which is: '\xEE' (238)
    0xC0
      Which is: 192
  [F16] new_req was reported in completions.received (done_recving) with poison byte 0xEE still in layer 0's HBM block

  [  FAILED  ] UuidRetirementBughunt.CompleteReadSweepDeadEraseIfWipesLiveReplacementAndPublishesCorruptHbm (23 ms)
  [----------] 4 tests from UuidRetirementBughunt (59 ms total)
  ```

---

## F17. `KVCacheManagerWithTransfer::PoolReshardPush` lacks a pending-UUID reservation and blindly overwrites `sessions_[uuid]`, reopening bounded `PoolStagingStorage` slot aliasing on concurrent duplicate-UUID `START_TRANSFER` RPCs

- **Status:** **CONFIRMED (test)** 2026-11-03, on unmodified `56a0269d`:
  `kv_transfer_uuid_and_reshard_push_bughunt_test.cc`
  (`PoolReshardPushDuplicateUuidBughunt`, 1 control passing + 1 case failing).
  Found during the `56a0269d` model-to-code audit of `PoolReshardPush` against
  `PoolReshardRegisterRecv` (`UuidTable.lean` / `Reshard/PoolStaging`).
- **Root cause (`56a0269d`):** `PoolReshardRegisterRecv` (`:726-778`) closes the
  unlocked `Create` window with `pending_pool_reshard_recvs_` (`:738-745`, added
  when fixing F6 in `8653373`) and re-checks `sessions_.find(plan.uuid())`
  before emplacing (`:765-772`). Its sender sibling `PoolReshardPush`
  (`kv_cache_manager_with_transfer.cc:690-724`, rewritten in `1523b07d`) omits
  both guards:
  1. Under the first `mu_` lock (`:693-700`), it checks `sessions_.find(uuid)`
     and returns `AlreadyExistsError` only if a live session is *already* in
     `sessions_`, then unlocks `mu_` (`:701`) without inserting `uuid` into any
     `pending_pool_reshard_sends_` set.
  2. Outside `mu_`, it runs `ReshardSendSession::Create` (`:711-715`, which
     calls `InitTransportServer()` at `reshard_send_session.cc:144` and launches
     the detached `ExecutePushPipeline` task).
  3. Under the second `mu_` lock (`:717-721`), it executes
     `sessions_[plan.uuid()] = state;` (`:718`) with **no re-check** and calls
     `NoteSubPlanRegisteredLocked(plan, /*is_sender=*/true)` (`:719-720`).
  When two `PoolReshardPush` calls for the same `uuid` arrive concurrently, both
  pass `:694`, both construct and launch live `ReshardSendSession` pipelines,
  and the second overwrites `sessions_[uuid]` — orphaning the first live
  `ReshardSendSession` from `sessions_` while double-registering `uuid` in the
  sub-plan chain. Both detached pipelines call
  `base_->AcquirePoolStagingLease(uuid(), ...)` (`reshard_send_session.cc:362-364`),
  which is idempotent by `uuid` (`PoolStagingStorage::Acquire` returns the
  already-leased slot to the second caller). As soon as the faster duplicate
  settles (`SettleLocked`, `:593`), it calls
  `base_->ReleasePoolStagingLeases(uuid())`, freeing that bounded
  `PoolStagingStorage` slot while the slower duplicate is still mid-D2H or
  mid-`AsyncPush` reading from it; an unrelated transfer then leases the exact
  same host staging address (the F6 / F10 slot-aliasing hazard).
- **C++ test output** (unmodified `56a0269d`, verbatim, 2026-11-03):
  ```
  [----------] 2 tests from PoolReshardPushDuplicateUuidBughunt
  [ RUN      ] PoolReshardPushDuplicateUuidBughunt.Control_SequentialDuplicateUuidIsRejectedWhileFirstSendIsLive
  I0000 00:00:1793730701.640539    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.640610    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.640991    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 33773, listening tcp socket 4: [::]:33773--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.641149    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=4, numa_send_adapters=0
  I0000 00:00:1793730701.642496    1438 kv_cache_manager_base.cc:2143] KVCacheManagerBase: pool host staging configured: leases=1 bounded_storages=1 (128 B) full_mirror_storages=0 (0 B)
  I0000 00:00:1793730701.643867    1625 conn_util.cc:235] connected tcp socket 6: 127.0.0.1:49946--127.0.0.1:36405
  E0000 00:00:1793730701.644180    1625 reshard_send_session.cc:510] Pool reshard send failed uuid=9101 req_id=reshard_req_9101: INTERNAL: tcp socket recvmsg eof failed: fd=6 127.0.0.1:49946--*
  === Source Location Trace: === 
  external/peregrine+/peregrine/src/internal/socket/tcp_socket_util.cc:170

  [       OK ] PoolReshardPushDuplicateUuidBughunt.Control_SequentialDuplicateUuidIsRejectedWhileFirstSendIsLive (5 ms)
  [ RUN      ] PoolReshardPushDuplicateUuidBughunt.ConcurrentDuplicateUuidOverwritesSessionAndAliasesLivePoolStagingSlot
  I0000 00:00:1793730701.645770    1438 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1793730701.645820    1438 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1793730701.646371    1438 raw_buffer_transport.cc:321] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 33729, listening tcp socket 3: [::]:33729--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1793730701.646518    1438 block_transport.cc:373] local_port=0, local_ips=127.0.0.1, parallelism=4, numa_send_adapters=0
  I0000 00:00:1793730701.647787    1438 kv_cache_manager_base.cc:2143] KVCacheManagerBase: pool host staging configured: leases=1 bounded_storages=1 (128 B) full_mirror_storages=0 (0 B)
  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:910: Failure
  Value of: both_accepted
    Actual: true
  Expected: false
  [F17] both concurrent PoolReshardPush calls for uuid=9201 returned OK (missing pending_pool_reshard_sends_ reservation and sessions_[uuid] overwrite)

  I0000 00:00:1793730701.674595    1648 conn_util.cc:235] connected tcp socket 6: 127.0.0.1:45498--127.0.0.1:33441
  I0000 00:00:1793730701.674617    1645 conn_util.cc:235] connected tcp socket 7: 127.0.0.1:45502--127.0.0.1:33441
  E0000 00:00:1793730701.674916    1648 reshard_send_session.cc:510] Pool reshard send failed uuid=9201 req_id=reshard_req_9201: INTERNAL: FAILED_PRECONDITION: tcp socket sendmsg failed: fd=6 127.0.0.1:45498--*: Broken pipe
  === Source Location Trace: === 
  external/peregrine+/peregrine/src/internal/socket/tcp_socket_util.cc:123
  tpu_sync/transport/lib/adapter/socket_transport_adapter.cc:632

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:927: Failure
  Expected equality of these values:
    manager.base()->PoolStagingSummary().at(0).free_slots
      Which is: 1
    0
  [F17] settling duplicate send freed uuid=9201's PoolStagingStorage slot while the sibling send still has an open TCP push in flight

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:935: Failure
  Value of: other_lease
  Expected: has a status code that is equal to RESOURCE_EXHAUSTED, and has an error message that is anything
    Actual: OK (of type absl::lts_20260526::Status), which is OK
  [F17] unrelated uuid=9202 leased the 1-slot arena while uuid=9201 still has an active TCP push in flight

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:943: Failure
  Expected: (other_addrs_or->host_base_addrs(0)) != (slot_0_addr), actual: 93841372925120 vs 93841372925120
  [F17] unrelated uuid=9202 received the exact host staging address (0x555925b2ccc0) still in flight for uuid=9201

  E0000 00:00:1793730701.676363    1645 reshard_send_session.cc:510] Pool reshard send failed uuid=9201 req_id=reshard_req_9201: INTERNAL: tcp socket recvmsg eof failed: fd=7 127.0.0.1:45502--*
  === Source Location Trace: === 
  external/peregrine+/peregrine/src/internal/socket/tcp_socket_util.cc:170

  [  FAILED  ] PoolReshardPushDuplicateUuidBughunt.ConcurrentDuplicateUuidOverwritesSessionAndAliasesLivePoolStagingSlot (57 ms)
  [----------] 2 tests from PoolReshardPushDuplicateUuidBughunt (63 ms total)
  ```
- **Reachability:** requires two concurrent sender `START_TRANSFER` RPCs with
  the same `uuid` reaching one worker's `PoolReshardPush` while bounded pool
  host staging (`staging_leases > 0`) is configured — e.g. a gRPC / proxy retry
  after a transient deadline while the first call is still in `Create` (for
  instance on first-call `InitTransportServer()`), two `src_units` misconfigured
  onto the same worker endpoint, or a caller UUID collision. `ReshardCoordinator::RunSubPlan`
  dispatches once per `src_units[i]` with a fresh 63-bit `uuid` today, and
  neither `vllm-torchtpu` nor `sglang-torchtpu` retries post-arm (§Callers).
- **Candidate fixes:** mirror `PoolReshardRegisterRecv`: reserve `plan.uuid()`
  in a `pending_pool_reshard_sends_` set (or a single unified
  `pending_uuids_` set across all registration entry points) under `mu_` before
  dropping `mu_` for `ReshardSendSession::Create`, erase the reservation via a
  cleanup guard, and `try_emplace` (never `operator[]` overwrite) under the
  second `mu_` lock — or defer starting `ExecutePushPipeline` until after the
  session is emplaced in `sessions_`.
- **Repro:** `kv_transfer_uuid_and_reshard_push_bughunt_test.cc`; copy to
  `tpu_sync/kv_cache/`, apply `findings/build_targets.patch`, and run
  `bazel test --config=oss //tpu_sync/kv_cache:kv_transfer_uuid_and_reshard_push_bughunt_test`.
- **Re-run 2026-11-09 on unmodified `00e946e3`** (reproducer unchanged; at HEAD
  `PoolReshardPush` `:732-774` still checks `sessions_.find(plan.uuid())` under
  `mu_` (`:743`), drops `mu_` around `CreateReshardSendSession` (`:760-764`,
  the `49e2c36c` factory) with no pending reservation — contrast
  `PoolReshardRegisterRecv`'s `pending_pool_reshard_recvs_` insert at `:794` —
  and overwrites `sessions_[plan.uuid()] = SessionEntry{state, plan.req_id(),
  SessionRole::kPoolReshardSend}` at `:767-768`; neither `000ac1d2`'s
  `SessionEntry` nor `25f7d8a7`'s `NoteSubPlanRegisteredLocked` call at `:769`
  adds a duplicate check). Still 1 control passing + 1 case failing; gtest
  lines of the verbatim log (glog lines dropped):
  ```
  [----------] 2 tests from PoolReshardPushDuplicateUuidBughunt
  [ RUN      ] PoolReshardPushDuplicateUuidBughunt.Control_SequentialDuplicateUuidIsRejectedWhileFirstSendIsLive
  === Source Location Trace: === 
  external/peregrine+/peregrine/src/internal/socket/tcp_socket_util.cc:170

  [       OK ] PoolReshardPushDuplicateUuidBughunt.Control_SequentialDuplicateUuidIsRejectedWhileFirstSendIsLive (4 ms)
  [ RUN      ] PoolReshardPushDuplicateUuidBughunt.ConcurrentDuplicateUuidOverwritesSessionAndAliasesLivePoolStagingSlot
  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:910: Failure
  Value of: both_accepted
    Actual: true
  Expected: false
  [F17] both concurrent PoolReshardPush calls for uuid=9201 returned OK (missing pending_pool_reshard_sends_ reservation and sessions_[uuid] overwrite)

  === Source Location Trace: === 
  external/peregrine+/peregrine/src/internal/socket/tcp_socket_util.cc:123
  tpu_sync/transport/lib/adapter/socket_transport_adapter.cc:632

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:927: Failure
  Expected equality of these values:
    manager.base()->PoolStagingSummary().at(0).free_slots
      Which is: 1
    0
  [F17] settling duplicate send freed uuid=9201's PoolStagingStorage slot while the sibling send still has an open TCP push in flight

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:935: Failure
  Value of: other_lease
  Expected: has a status code that is equal to RESOURCE_EXHAUSTED, and has an error message that is anything
    Actual: OK (of type absl::lts_20260526::Status), which is OK
  [F17] unrelated uuid=9202 leased the 1-slot arena while uuid=9201 still has an active TCP push in flight

  tpu_sync/kv_cache/kv_transfer_uuid_and_reshard_push_bughunt_test.cc:943: Failure
  Expected: (other_addrs_or->host_base_addrs(0)) != (slot_0_addr), actual: 94224510626112 vs 94224510626112
  [F17] unrelated uuid=9202 received the exact host staging address (0x55b25a7c2940) still in flight for uuid=9201

  === Source Location Trace: === 
  external/peregrine+/peregrine/src/internal/socket/tcp_socket_util.cc:170

  [  FAILED  ] PoolReshardPushDuplicateUuidBughunt.ConcurrentDuplicateUuidOverwritesSessionAndAliasesLivePoolStagingSlot (57 ms)
  [----------] 2 tests from PoolReshardPushDuplicateUuidBughunt (62 ms total)
  ```

---

## F18. `KVCacheStore::SaveRemote` leaks accepted offers in `active_remote_writes_` (`~KVCacheStore` double-`Release`s live pins on a shared backend), and `HostOffloadBackend::BeginWriteRemote` drops `CANCELLED` result streams without releasing the internal pin or recording a verdict

- **Status:** **CONFIRMED (test)** 2026-10-29 on unmodified `42dda542`, re-run
  2026-11-09 on unmodified `00e946e3`:
  `kv_cache_store_remote_write_bughunt_test.cc` (`RemoteWriteSettlementTest`,
  1 control passing + 3 cases failing). Surfaced during the 2026-10-29 audit of
  the source-side async remote-write settlement introduced in `22a8bf22`. Not
  yet filed.
- **Where / Root cause (`00e946e3`):**
  1. **Leaked `active_remote_writes_` entry and destructor double-`Release` (2a):**
     `KVCacheStore::SaveRemote` (`tpu_sync/kv_cache/kv_cache_store.cc:2354-2411`)
     takes an internal pin on `block_hashes` (`:2338`) and inserts a
     `RemoteWriteState` into `active_remote_writes_[op_key]` (`:2358-2366`)
     before calling `backend->BeginWriteRemote(...)` (`:2373-2375`). It erases
     that entry via `TakeRemoteWrite(op_key)` (`:2414-2424`) **only** on the
     synchronous exits (`!ack_res.ok()` at `:2379`, and `ack.all_exist ||
     !ack.existing_hashes.empty()` at `:2384-2386`). When the destination
     accepts the offer (`ack.operation_id != 0`), `SaveRemote` updates
     `it->second.{operation_id, cancel, hold_expiry}` (`:2401-2410`) and returns
     `OkStatus()`. The accepted offer subsequently settles inside
     `HostOffloadBackend::BeginWriteRemote`'s `call.result.OnReady` (or
     `poll_future.OnReady`) continuation (`tpu_sync/kv_cache/host_offload_backend.cc:971-1089`),
     which releases the internal pin (plus the caller's pin on commit, `:996-1000`,
     `:1054-1057`) and publishes the verdict into `save_tracker`, **without
     notifying `KVCacheStore` or calling `TakeRemoteWrite`**. Every accepted
     remote write therefore remains in `active_remote_writes_` for the lifetime
     of the store. When `~KVCacheStore` runs (`kv_cache_store.cc:986-1010`), it
     walks every entry in `active_remote_writes_` and calls
     `OnWriteRemoteVerdict(std::move(state), /*succeeded=*/false, {})` (`:1008`
     → `:2426-2456`), which calls `backend->Release(state.block_hashes)` a
     **second time** (`:2431`) — stealing a live pin from any concurrent or
     subsequent holder on a `KVCacheStoreBackend` that outlives the store (and
     re-merging a bogus failed verdict into `save_tracker_` / `sweep_tracker_`).
  2. **`kCancelled` result stream after ack drops pin release and verdict (2b):**
     Inside `BeginWriteRemote`'s `call.result.OnReady` continuation
     (`host_offload_backend.cc:983-986`),
     ```cpp
     if (!result_or.ok() &&
         result_or.status().code() == absl::StatusCode::kCancelled) {
       return;
     }
     ```
     returns early while `lifetime->is_alive` is `true` — releasing neither the
     internal pin nor `save_tracker`'s pending mark, and skipping
     `PollWriteRemoteAsync` (`:1039-1040`). That guard assumes `kCancelled` can
     only come from `~KVCacheStore`'s own `state.cancel->TryCancel()` (`kv_cache_store.cc:1001`),
     ignoring that the **destination** ends the `WriteRemote` server stream with
     `CANCELLED` whenever `WriteRemoteServerReactor::OnWriteDone(false)` or
     `OnCancel()` runs (`kv_cache_store_service.cc:195-198, 217-222`) or an
     intermediary resets the stream after the ack. Contrast `UNAVAILABLE`
     (the control case), which falls through `:983` into `PollWriteRemoteAsync`
     and settles cleanly. Under `CANCELLED`, the internal pin leaks (`GetPinCount`
     stays 2 = caller + internal) and the hashes stay pending in `save_tracker_`
     / `sweep_tracker_` past `RAIDEN_REMOTE_WRITE_HOLD_S` (waking neither
     `PollSaveStatus()` nor `WaitForBatchWriteResult`, which loops forever on the
     sweep thread at `kv_cache_store.cc:2138-2160`!).
- **C++ test output** (unmodified `00e946e3`, verbatim, 2026-11-09):
  ```
  Running main() from gmock_main.cc
  [==========] Running 4 tests from 1 test suite.
  [----------] Global test environment set-up.
  [----------] 4 tests from RemoteWriteSettlementTest
  [ RUN      ] RemoteWriteSettlementTest.AcceptedCommittedWriteIsErasedFromActiveRemoteWrites
  WARNING: All log messages before absl::InitializeLog() is called are written to STDERR
  I0000 00:00:1794259778.603616   36851 kv_cache_store.cc:937] KVCacheStore published at 127.0.0.1:40935
  tpu_sync/kv_cache/kv_cache_store_remote_write_bughunt_test.cc:297: Failure
  Expected equality of these values:
    store->InFlightRemoteWritesCountForTesting()
      Which is: 1
    0u
      Which is: 0
  the accepted operation settled (verdict delivered, pins released) but its active_remote_writes_ entry was never erased

  W0000 00:00:1794259778.647931   36851 kv_cache_store.cc:1005] Store destroyed with remote write 777 still outstanding; releasing its source pin without waiting for the destination's verdict.
  [  FAILED  ] RemoteWriteSettlementTest.AcceptedCommittedWriteIsErasedFromActiveRemoteWrites (100 ms)
  [ RUN      ] RemoteWriteSettlementTest.DestroyingTheStoreAfterSettlementDoesNotStealALivePin
  I0000 00:00:1794259778.697518   36851 kv_cache_store.cc:937] KVCacheStore published at 127.0.0.1:46851
  W0000 00:00:1794259778.740184   36851 kv_cache_store.cc:1005] Store destroyed with remote write 777 still outstanding; releasing its source pin without waiting for the destination's verdict.
  tpu_sync/kv_cache/kv_cache_store_remote_write_bughunt_test.cc:327: Failure
  Expected equality of these values:
    backend->GetPinCount("a")
      Which is: 0
    1
  ~KVCacheStore released the settled operation's internal pin a second time, dropping a pin it does not own

  [  FAILED  ] RemoteWriteSettlementTest.DestroyingTheStoreAfterSettlementDoesNotStealALivePin (100 ms)
  [ RUN      ] RemoteWriteSettlementTest.CancelledResultStreamAfterAckSettlesWithinTheHold
  I0000 00:00:1794259778.797946   36851 kv_cache_store.cc:937] KVCacheStore published at 127.0.0.1:46379
  tpu_sync/kv_cache/kv_cache_store_remote_write_bughunt_test.cc:351: Failure
  Value of: pending
    Actual: true
  Expected: false
  hash still pending in the save tracker after the HOLD window: the CANCELLED result was dropped without a verdict

  tpu_sync/kv_cache/kv_cache_store_remote_write_bughunt_test.cc:354: Failure
  Value of: failed
  Expected: has 1 element that is equal to "a"
    Actual: {}

  tpu_sync/kv_cache/kv_cache_store_remote_write_bughunt_test.cc:355: Failure
  Expected equality of these values:
    store->GetPinCount("a")
      Which is: 2
    1
  the internal pin (2 = caller + internal) was never released after the destination cancelled the stream

  W0000 00:00:1794259787.821519   36851 kv_cache_store.cc:1005] Store destroyed with remote write 777 still outstanding; releasing its source pin without waiting for the destination's verdict.
  [  FAILED  ] RemoteWriteSettlementTest.CancelledResultStreamAfterAckSettlesWithinTheHold (9110 ms)
  [ RUN      ] RemoteWriteSettlementTest.ControlUnavailableResultStreamAfterAckSettles
  I0000 00:00:1794259787.909774   36851 kv_cache_store.cc:937] KVCacheStore published at 127.0.0.1:41935
  W0000 00:00:1794259787.952270   36851 kv_cache_store.cc:1005] Store destroyed with remote write 777 still outstanding; releasing its source pin without waiting for the destination's verdict.
  [       OK ] RemoteWriteSettlementTest.ControlUnavailableResultStreamAfterAckSettles (100 ms)
  [----------] 4 tests from RemoteWriteSettlementTest (9412 ms total)

  [----------] Global test environment tear-down
  [==========] 4 tests from 1 test suite ran. (9412 ms total)
  [  PASSED  ] 1 test.
  [  FAILED  ] 3 tests, listed below:
  [  FAILED  ] RemoteWriteSettlementTest.AcceptedCommittedWriteIsErasedFromActiveRemoteWrites
  [  FAILED  ] RemoteWriteSettlementTest.DestroyingTheStoreAfterSettlementDoesNotStealALivePin
  [  FAILED  ] RemoteWriteSettlementTest.CancelledResultStreamAfterAckSettlesWithinTheHold

   3 FAILED TESTS
  ```
- **Reachability:** any `KVCacheStore` P2P deployment using remote
  `Save(hashes, dst_raiden_id)` or `SweepOnce`'s remote demotion
  (`WaitForBatchWriteResult`). Neither `vllm-torchtpu`, `sglang-torchtpu`, nor
  `tpu-inference`'s `tpu_raiden_connector` instantiates `KVCacheStore`. On a
  long-lived `KVCacheStore`: 2a grows `active_remote_writes_` unboundedly by one
  `RemoteWriteState` per accepted remote save and logs a spurious `"Store
  destroyed with remote write … still outstanding"` + double-`Release` at
  shutdown (corrupting pins if `backend()` is shared); 2b permanently wedges the
  `StoreMonitor` sweep thread inside `WaitForBatchWriteResult` (`while
  (!pending.empty())`, `kv_cache_store.cc:2138`) and leaks internal pins if a
  peer store closes an accepted `WriteRemote` stream with `CANCELLED`.
- **Candidate fixes:** pass an `on_settled` callback (guarded by `KVCacheStore::lifetime_`)
  into `BeginWriteRemote` — or move single-owner settlement ownership into
  `KVCacheStore` via `TakeRemoteWrite(op_key)` so whichever of the async
  continuation or `~KVCacheStore` wins `TakeRemoteWrite(op_key)` is the **sole**
  releaser of the internal pin; and replace the blanket `code() == kCancelled`
  early return in `BeginWriteRemote` with an explicit local-abandonment flag set
  only when `~KVCacheStore` itself cancels the call, treating peer-originated
  `CANCELLED` like any other stream break (fall through to `PollWriteRemoteAsync`
  within `remaining_hold`).
- **Repro:** `kv_cache_store_remote_write_bughunt_test.cc`; copy to
  `tpu_sync/kv_cache/`, apply `findings/build_targets.patch`, and run
  `bazel test --config=oss //tpu_sync/kv_cache:kv_cache_store_remote_write_bughunt_test`.

---

## F19. `KVCacheStoreClient::Fetch` sets no RPC deadline (wedging `ReadRemote` and its host blocks on a silent source), and `HostOffloadBackend::LoadRemoteBlocks` frees `dst_host_block_ids` immediately on `Fetch` failure while the worker still accepts planless `op = 6` / `uuid = 0` pushes into them

- **Status:** **CONFIRMED (test)** 2026-10-29 on unmodified `42dda542`, re-run
  2026-11-09 on unmodified `00e946e3`:
  `kv_cache_store_fetch_bughunt_test.cc` (`FetchLifetimeTest` 3/3 failing +
  `FetchPushAfterFreeTest` 1/1 failing). Promoted from §"Open / not yet checked".
  Not yet filed.
- **Where / Root cause (`00e946e3`):**
  1. **Missing `Fetch` RPC deadline (3a):** `KVCacheStoreClient::Fetch`
     (`tpu_sync/kv_cache/kv_cache_store_client.cc:61-125`) constructs a default
     `grpc::ClientContext` (`:108`) and calls `stub_->async()->Fetch(...)`
     (`:112`) **without calling `context->set_deadline(...)`** (contrast
     `WriteRemote` and `PollWriteRemote` in the same file, which both set client
     deadlines). Nothing above it bounds the wait: `HostOffloadBackend::LoadRemoteBlocks`
     (`tpu_sync/kv_cache/host_offload_backend.cc:1190-1331`) allocates
     `dst_host_block_ids` from `raiden_controller_->AllocateBlockIds(...)`
     (`:1210`) before calling `client_ptr->Fetch(...)` (`:1224-1226`), and
     `KVCacheStore::ReadRemote` / `Load` marks `block_hashes` pending in
     `load_tracker_` beforehand. A peer store that accepts `Fetch` and hangs
     (e.g. wedged worker `TransferBuffers`, deadlocked peer, blackholed TCP
     connection without keepalive) leaves `context->deadline() ==
     time_point::max()`, pins `dst_host_block_ids` outside the LRU (unreclaimable
     by eviction), keeps the hashes pending in `PollLoadStatus()` /
     `PollRemoteReadStatus()` forever, and rejects any retry of the same hash
     with `FAILED_PRECONDITION: Block is already loading`.
  2. **Immediate `DeallocateBlockIds` on `Fetch` error vs planless `op = 6` /
     `uuid = 0` worker push (3b):** When `fetch_future` resolves with an error
     (`host_offload_backend.cc:1244-1264`), `LoadRemoteBlocks` immediately
     returns `dst_host_block_ids` to `raiden_controller_->DeallocateBlockIds(dst_host_block_ids)`
     (`:1245`). Meanwhile, on the source peer, `KVCacheStoreServiceImpl::Fetch`
     (`kv_cache_store_service.cc:541-544`) drives `controller_->TransferBuffers(src_buffers, dst_buffers)`
     without cancellation or lease fencing when the `Fetch` gRPC call breaks
     (or, crucially, if a client deadline is added to fix 3a!). On the wire,
     `TransferBuffers` pushes host-to-host blocks via planless explicit-destination
     `H2hWriteDirect(..., /*uuid=*/0)` (`header.op == 6`, `header.uuid == 0`),
     and on the destination worker `BlockTransportServerPushSession::StartStream`
     (`tpu_sync/transport/block_transport_session.cc:365-499`) →
     `KVCacheManagerBase::GetBlockChunks` only bounds-checks `dst_id` against the
     host buffer array — consulting neither `LogicalBlockManager::IsAllocated(dst_id)`
     nor any session/lease generation. A late source push for the failed `Fetch`
     is therefore accepted (`OK`) into a freed or reallocated host block,
     silently overwriting the new owner's bytes (the F2 write-after-settle shape
     on `KVCacheStore`'s production `Fetch` path; note `FetchPushAfterFreeTest`
     proves the two halves separately rather than driving a mid-`TransferBuffers`
     gRPC channel drop end-to-end).
- **C++ test output** (unmodified `00e946e3`, verbatim, 2026-11-09):
  ```
  Running main() from gmock_main.cc
  [==========] Running 4 tests from 2 test suites.
  [----------] Global test environment set-up.
  [----------] 3 tests from FetchLifetimeTest
  [ RUN      ] FetchLifetimeTest.FetchRpcCarriesAClientDeadline
  tpu_sync/kv_cache/kv_cache_store_fetch_bughunt_test.cc:220: Failure
  Expected: (source_->deadline()) != (std::chrono::system_clock::time_point::max()), actual: 2262-04-11 23:47:16.854775807 vs 2262-04-11 23:47:16.854775807
  KVCacheStoreClient::Fetch sent the call with no deadline

  [observation] client Fetch future still pending after 12s
  tpu_sync/kv_cache/kv_cache_store_fetch_bughunt_test.cc:233: Failure
  Value of: future.IsReady()
    Actual: false
  Expected: true
  Fetch against a silent source is still pending after 12s

  [  FAILED  ] FetchLifetimeTest.FetchRpcCarriesAClientDeadline (12315 ms)
  [ RUN      ] FetchLifetimeTest.SilentSourceWedgesReadRemoteAndItsHostBlocks
  WARNING: All log messages before absl::InitializeLog() is called are written to STDERR
  I0000 00:00:1794259795.862827   36887 kv_cache_store.cc:937] KVCacheStore published at 127.0.0.1:34621
  [observation] after 12s: settled=0 pending=1 free_host_blocks=7/8 retry=FAILED_PRECONDITION: Block is already loading: h
  tpu_sync/kv_cache/kv_cache_store_fetch_bughunt_test.cc:272: Failure
  Value of: settled
    Actual: false
  Expected: true
  the remote read is still pending after 12s against a silent source

  tpu_sync/kv_cache/kv_cache_store_fetch_bughunt_test.cc:274: Failure
  Expected equality of these values:
    free_after
      Which is: 7
    free_before
      Which is: 8
  the destination host block is still allocated after 12s

  tpu_sync/kv_cache/kv_cache_store_fetch_bughunt_test.cc:276: Failure
  Value of: absl::IsFailedPrecondition(retry)
    Actual: true
  Expected: false
  a retry of the same hash is refused as already loading: FAILED_PRECONDITION: Block is already loading: h

  [  FAILED  ] FetchLifetimeTest.SilentSourceWedgesReadRemoteAndItsHostBlocks (12314 ms)
  [ RUN      ] FetchLifetimeTest.FailedFetchFreesTheDestinationBlocksAtOnce
  I0000 00:00:1794259808.176211   36887 kv_cache_store.cc:937] KVCacheStore published at 127.0.0.1:46535
  [observation] free before=8 handed_to_source=0 reallocated_count=8
  tpu_sync/kv_cache/kv_cache_store_fetch_bughunt_test.cc:315: Failure
  Value of: absl::c_linear_search(*reallocated, handed_to_source[0])
    Actual: true
  Expected: false
  host block 0 was handed to the source as a push destination, freed when Fetch failed, and handed out again while the source may still be writing into it

  [  FAILED  ] FetchLifetimeTest.FailedFetchFreesTheDestinationBlocksAtOnce (100 ms)
  [----------] 3 tests from FetchLifetimeTest (24730 ms total)

  [----------] 1 test from FetchPushAfterFreeTest
  [ RUN      ] FetchPushAfterFreeTest.LatePlanlessPushOverwritesAReallocatedBlock
  I0000 00:00:1794259808.254598   36887 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1794259808.254695   36887 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1794259808.255496   36887 raw_buffer_transport.cc:320] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 44069, listening tcp socket 7: [::]:44069--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1794259808.255715   36887 block_transport.cc:344] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1794259808.257234   36887 tpu_utils.cc:663] Detected interface: lo, BDF: None, MTU: 65536, NUMA: -1, Classification: Control/Fallback Interface
  W0000 00:00:1794259808.257365   36887 tpu_utils.cc:700] No data plane NIC was discovered; KV traffic will fall back to a single rail. Set TPU_RAIDEN_DATA_NICS to an explicit comma-separated interface allowlist (for example "ens6,enp192s4"), or raise the MTU of the data interfaces above 1500.
  InitTransportServer: target_numa=[]
  InitTransportServer: Local IP: 127.0.0.1 numa=-1
  I0000 00:00:1794259808.257953   36887 raw_buffer_transport.cc:320] bound_ip_: 127.0.0.1, local_ips_: 127.0.0.1, local_port_: 39311, listening tcp socket 8: [::]:39311--*, listen_backlog: 4096, pin_recv_threads_to_nic_numa: false
  I0000 00:00:1794259808.258238   36887 block_transport.cc:344] local_port=0, local_ips=127.0.0.1, parallelism=1, numa_send_adapters=0
  I0000 00:00:1794259808.259786   37066 conn_util.cc:260] connected tcp socket 9: 127.0.0.1:39500--127.0.0.1:39311
  I0000 00:00:1794259808.260028   37067 raw_buffer_transport.cc:717] accepted tcp socket 10: [::ffff:127.0.0.1]:39311--[::ffff:127.0.0.1]:39500
  I0000 00:00:1794259808.260210   37067 block_transport.cc:392] HandleCustomRequest (H2H read start): client_fd=10, op=6, uuid=0, numa=1
  [observation] late push status=OK new owner's first byte=0xa5
  tpu_sync/kv_cache/kv_cache_store_fetch_bughunt_test.cc:367: Failure
  Value of: late.ok()
    Actual: true
  Expected: false
  a planless uuid-0 push into a freed-and-reallocated block was accepted

  tpu_sync/kv_cache/kv_cache_store_fetch_bughunt_test.cc:370: Failure
  Expected equality of these values:
    first_byte
      Which is: '\xA5' (165)
    0x11
      Which is: 17
  the late push overwrote the new owner's bytes

  I0000 00:00:1794259808.261418   37067 block_transport.cc:392] HandleCustomRequest (H2H read start): client_fd=10, op=6, uuid=0, numa=1
  tpu_sync/kv_cache/kv_cache_store_fetch_bughunt_test.cc:378: Failure
  Value of: into_free.ok()
    Actual: true
  Expected: false
  a planless uuid-0 push into an unallocated block was accepted

  [  FAILED  ] FetchPushAfterFreeTest.LatePlanlessPushOverwritesAReallocatedBlock (11 ms)
  [----------] 1 test from FetchPushAfterFreeTest (12 ms total)

  [----------] Global test environment tear-down
  [==========] 4 tests from 2 test suites ran. (24743 ms total)
  [  PASSED  ] 0 tests.
  [  FAILED  ] 4 tests, listed below:
  [  FAILED  ] FetchLifetimeTest.FetchRpcCarriesAClientDeadline
  [  FAILED  ] FetchLifetimeTest.SilentSourceWedgesReadRemoteAndItsHostBlocks
  [  FAILED  ] FetchLifetimeTest.FailedFetchFreesTheDestinationBlocksAtOnce
  [  FAILED  ] FetchPushAfterFreeTest.LatePlanlessPushOverwritesAReallocatedBlock

   4 FAILED TESTS
  ```
- **Reachability:** any `KVCacheStore` peer-load caller (`Load(hashes, slices,
  device_block_ids)` or `ReadRemote` on `BlockStatus::REMOTE` slices; neither
  `vllm-torchtpu` nor `sglang-torchtpu` uses `KVCacheStore`). Note the trap
  between 3a and 3b (identical to F2's naive-fix trap): adding a `ClientContext`
  deadline to `Fetch` alone fixes 3a **at the cost of making 3b routine**,
  because every timed-out `Fetch` will immediately `DeallocateBlockIds(dst_host_block_ids)`
  while the source's `TransferBuffers` worker push is still writing into those
  blocks!
- **Candidate fixes:** (1) add a configurable `Fetch` deadline (plus a source
  HOLD margin, mirroring `WriteRemote`'s `RAIDEN_REMOTE_WRITE_HOLD_S` vs
  `granted_deadline` gap, or switch peer loads from source-push `Fetch` to
  destination-pull so the destination's `TransferBuffers` future directly gates
  `DeallocateBlockIds`, as `WriteRemote`'s `ReleaseLandingBlocks` does in R-D);
  or (2) register a per-`Fetch` `uuid != 0` receive session on the destination
  workers so `BeginIncomingPush` / `EndIncomingPush` pins `in_flight_` and
  `DeallocateBlockIds` waits for `session->Done()`.
- **Repro:** `kv_cache_store_fetch_bughunt_test.cc`; copy to
  `tpu_sync/kv_cache/`, apply `findings/build_targets.patch`, and run
  `bazel test --config=oss //tpu_sync/kv_cache:kv_cache_store_fetch_bughunt_test`.

---

## F20. `KVCacheManagerBase::host_block_manager_` (`LogicalBlockManager`) is mutated without synchronization across inbound auto-allocating `op = 1` pushes, `H2hRead` pulls, and `AllocateBlocks`, handing out duplicate host block IDs

- **Status:** **CONFIRMED (test)** 2026-10-29 on unmodified `42dda542`, re-run
  2026-11-09 on unmodified `00e946e3`:
  `host_block_manager_race_bughunt_test.cc` (`HostBlockManagerRaceTest`,
  1 control passing + 1 case failing). Not yet filed.
- **Where / Root cause (`00e946e3`):** `LogicalBlockManager`
  (`tpu_sync/kv_cache/logical_block_manager.h:33-35`) has no internal mutex and
  documents: *"This class is not thread-safe and requires external
  synchronization for concurrent access."* (`RaidenController` wraps its own
  `LogicalBlockManager` in `RaidenController::mu_`.) By contrast,
  `KVCacheManagerBase` owns `std::unique_ptr<LogicalBlockManager>
  host_block_manager_` (`tpu_sync/kv_cache/kv_cache_manager_base.h:803`) with
  **no mutex** guarding it:
  - `KVCacheManagerBase::AllocateBlocks(num_blocks, uuid)` (`:871-874`) calls
    `host_block_manager_->Allocate(num_blocks, /*lock=*/true)` unlocked;
  - `RawBufferTransport` serves every accepted TCP connection on its own
    `ConnectionWorker` thread, and `BlockTransportServerPushSession::StartStream`
    (`tpu_sync/transport/block_transport_session.cc:386-389`) calls
    `delegate_->AllocateBlocks(header.count_or_size, header.uuid)` for `header.op
    == 1` (auto-allocating `H2hWrite(peer, src_block_ids)` with no destination
    IDs);
  - local `BlockTransport::H2hRead` pulls (the torch/jax `H2hRead` binding,
    called with the Python GIL released), `D2hAutoAllocate`, `Unlock`, and
    dynamic-mode `StagingBlockAllocator` all read and mutate the same
    `host_block_manager_` without a lock.
  Concurrent `Allocate` calls race on `blocks_[i].is_allocated`,
  `access_counter_`, and `num_free_`, handing the same host block ID to two or
  more concurrent callers.
- **C++ test output** (unmodified `00e946e3`, 2026-11-09; glog `tpu_utils` /
  `raw_buffer_transport` / `HandleCustomRequest` `I0000` lines omitted,
  `[observation]` / `[duplicate]` / `[control]` and gtest lines verbatim):
  ```
  Running main() from gmock_main.cc
  [==========] Running 2 tests from 1 test suite.
  [----------] Global test environment set-up.
  [----------] 2 tests from HostBlockManagerRaceTest
  [ RUN      ] HostBlockManagerRaceTest.ConcurrentAutoAllocatingPushesAndLocalAllocs
  [observation] handed_out=42000 distinct=40010 duplicates=1990 errors=0 free 65535 -> 23535 (expected 23535)
  [duplicate] block 1: local #0 and pull #0
  [duplicate] block 2: local #1 and push 0#0
  [duplicate] block 2: local #1 and push 1#0
  [duplicate] block 2: local #1 and push 2#0
  [duplicate] block 2: local #1 and push 3#0
  [duplicate] block 4: local #3 and push 0#1
  [duplicate] block 3: local #2 and pull #1
  [duplicate] block 4: local #3 and push 2#1
  [duplicate] block 4: local #3 and push 3#1
  [duplicate] block 4: local #3 and push 1#1
  tpu_sync/kv_cache/host_block_manager_race_bughunt_test.cc:162: Failure
  Value of: duplicates.empty()
    Actual: false
  Expected: true
  1990 host block ids were handed to two owners at once

  [  FAILED  ] HostBlockManagerRaceTest.ConcurrentAutoAllocatingPushesAndLocalAllocs (29795 ms)
  [ RUN      ] HostBlockManagerRaceTest.ControlSameWorkloadSerializedHasNoDuplicates
  [control] handed_out=2400 duplicates=0 free 8191 -> 5791
  [       OK ] HostBlockManagerRaceTest.ControlSameWorkloadSerializedHasNoDuplicates (507 ms)
  [----------] 2 tests from HostBlockManagerRaceTest (30303 ms total)

  [----------] Global test environment tear-down
  [==========] 2 tests from 1 test suite ran. (30303 ms total)
  [  PASSED  ] 1 test.
  [  FAILED  ] 1 test, listed below:
  [  FAILED  ] HostBlockManagerRaceTest.ConcurrentAutoAllocatingPushesAndLocalAllocs

   1 FAILED TEST
  ```
- **Reachability:** reachable only by callers that drive `KVCacheManagerBase`'s
  own `host_block_manager_` concurrently — specifically the torch/jax
  auto-allocating `H2hWrite(peer, src_block_ids)` (`op = 1`), `H2hRead`,
  `D2hAutoAllocate` / `Unlock` bindings, or dynamic-staging
  `StagingBlockAllocator` (`TPU_RAIDEN_DYNAMIC_HOST_STAGING=1`). None of the
  three disaggregated serving connectors (`tpu-inference`, `vllm-torchtpu`,
  `sglang-torchtpu`) or `KVCacheStore` reaches it: prefill-to-decode uses static
  `StagingBlockAllocator` slots (`staging_arena.cc`, guarded by its own
  `absl::Mutex`), pool reshard uses `PoolStagingStorage` (`staging_mu_`), and
  `KVCacheStore` allocates from `RaidenController`'s mutex-guarded
  `LogicalBlockManager` and pushes explicit destination IDs (`op = 6`).
- **Candidate fixes:** guard `KVCacheManagerBase::host_block_manager_` behind a
  dedicated `mutable absl::Mutex host_block_mu_` on `KVCacheManagerBase` (or make
  `LogicalBlockManager` internally mutex-guarded) and deprecate direct unlocked
  `host_block_manager()` pointer access in favor of locked `KVCacheManagerBase`
  methods.
- **Repro:** `host_block_manager_race_bughunt_test.cc`; copy to
  `tpu_sync/kv_cache/`, apply `findings/build_targets.patch`, and run
  `bazel test --config=oss //tpu_sync/kv_cache:host_block_manager_race_bughunt_test`.

---

## C1. tpu-inference `tpu_raiden_connector`: failed and never-pulled transfers leak their KV blocks on both nodes

- **Status:** **CONFIRMED (test)** 2026-10-20, on CPU, no TPU:
  [`tpu_inference_connector_c1_test.py`](tpu_inference_connector_c1_test.py)
  runs vLLM `6185d73`'s real `Scheduler` with tpu-inference `7ed46a6`'s real
  `TPUConnectorScheduler`, feeds it the connector's own translation of what
  tpu-sync `0ac16d1` reports (via the real `TPUConnectorWorker.get_finished`
  over a stubbed `poll_stats()`), and shows the blocks are never returned on
  either node; the two control cases (the report tpu-sync gave before
  `4246613`, or a successful receive) free them. tpu-sync's side of the chain
  — a never-pulled send lands in `failed_recving` — is tpu-sync's own
  upstream test `SendDrainTest.SendNobodyPulledFailsAtItsDeadline`
  (`kv_cache_manager_with_transfer_send_drain_test.cc:370-379`), not
  re-run here. Not yet run end to end on hardware; filed 2026-10-22 against
  tpu-inference (bug 8 in [`filed_bugs.md`](filed_bugs.md)). First read
  across the three codebases earlier the same day (the cited lines are
  identical at tpu-inference `main` `c2b062b`, and still at `main`
  `ee8b4ac7`, 2026-10-22). **Upstream status 2026-10-22:** no fix to
  `tpu_raiden_connector.py` on any branch. An unmerged upstream branch,
  `fix/pd-disagg-kv-pull-hang` (`e7661c73`, 2026-10-16), fixes a *different*
  symptom (decode hang: never-ready arrays inserted after a timed-out pull)
  in the sibling JAX-P2P connector `tpu_connector.py` — the one
  tpu-inference's own `examples/disagg` and kube benchmark configure — and
  its D-side remedy is exactly the fix shape below: the failed request stays
  in `done_recving` *and* its local blocks go through a new
  `get_block_ids_with_load_errors()` in the same step. (That legacy connector
  has since received its own fixes on tpu-inference `main`:
  [#3751](https://github.com/vllm-project/tpu-inference/pull/3751),
  `4325e35a6`, 2026-10-14, "TPUConnector: free prefill KV when decode skips
  the pull", and [#3839](https://github.com/vllm-project/tpu-inference/pull/3839),
  `58d3883d4`, 2026-10-19, "Fix decode hang when KV pull fails …", which adds
  `get_block_ids_with_load_errors` and `_invalid_block_ids` there. Neither
  touches `tpu_raiden_connector.py`.) tpu-sync upstream
  through `2ed6f8f` (merged 2026-10-22) does not change the
  `failed_recving_` classification of a failed or never-pulled send. The
  `vllm-jax` successor repository holds only a README (`d086b9c`).
  **Upstream status 2026-10-28:** the fix is open as
  [PR #3918](https://github.com/vllm-project/tpu-inference/pull/3918)
  (`f366ef523b2d385d6f9df0083f11eafcc5ba9c89`, Shawn Lu, 2026-10-27,
  "[Disagg] Forward tpu-sync failed transfers in tpu_raiden_connector"; ref
  `refs/pull/3918/head`, not on `main` `7840339b`, where the connector's
  history is still the five commits listed under "History and attribution").
  Its description names both halves as this entry does (prefill: a
  never-pulled request stays delay-free forever; decode: a failed pull stays
  `WAITING_FOR_REMOTE_KVS`). The change adds
  `TPUConnector.get_transfer_results(finished_req_ids)` delegating to a new
  `TPUConnectorWorker.get_transfer_results() -> KVConnectorTransferResults`;
  producer: `finished_sending_set.update(failed_recving)` plus
  `self.transfer_stats.record_failed_transfer()` per entry; consumer:
  `self._submitted.difference_update(failed_recving)`,
  `finished_recving_set.update(failed_recving)`,
  `failed_recving_set.update(failed_recving)`; `get_finished()` becomes
  `results.finished_sending, results.finished_recving`; the old comment "Do
  NOT report failed receives as done_recving …" is removed. Tests added in
  `tests/distributed/test_tpu_connector.py`, class
  `TestTPURaidenConnectorWorker`:
  `test_get_transfer_results_when_kv_manager_is_none`,
  `test_get_transfer_results_producer_forwards_failed_as_finished_sending`,
  `test_get_transfer_results_consumer_forwards_failed_recving`,
  `test_connector_delegates_get_transfer_results`. It relies on the vLLM API
  tpu-inference's LKG moved to in `43768bd50` (2026-10-26, vLLM `e7bb7e2f`)
  and `7840339bd` (2026-10-28, vLLM `2fb320d8`): see "Fix shape" below for
  how that API carries the D-side failure. tpu-sync at `42dda542` still files
  failed and expired sends in `failed_recving_`
  (`KVCacheManagerWithTransfer::CompleteReadWithDetails`, `(failed ?
  failed_recving_ : done_sending_)`), with no `failed_sending` list.
  This is a defect in the
  **caller**, recorded here because it is the production caller of the path
  `tpu_sync/formal_verification/TpuSyncVerify/Transfer/PrefillDecode/` models and because tpu-sync's
  `poll_stats` naming and the `4246613` reclassification (the "tpu-sync side" subsection below) are half of the P-side story.
- **Test output** (unedited; `torch 2.14.1+cpu`, `jax 0.11.2`,
  `vllm 0.23.1rc1.dev565+g6185d7388.empty`, `tpu-inference 7ed46a6`):

  ```
  tpu_inference_connector_c1_test.py::test_unit_get_finished_drops_failed_recving PASSED
  tpu_inference_connector_c1_test.py::test_unit_get_finished_forwards_done_lists PASSED
  tpu_inference_connector_c1_test.py::test_unit_get_block_ids_with_load_errors_is_default_empty PASSED
  tpu_inference_connector_c1_test.py::test_unit_producer_request_finished_holds_blocks PASSED
  tpu_inference_connector_c1_test.py::test_unit_expiration_time_has_no_reader PASSED
  tpu_inference_connector_c1_test.py::test_producer_blocks_after_transfer_outcome[tpu_sync_report0-False] PASSED
  tpu_inference_connector_c1_test.py::test_producer_blocks_after_transfer_outcome[tpu_sync_report1-True] PASSED
  tpu_inference_connector_c1_test.py::test_consumer_blocks_after_failed_pull_and_abort[tpu_sync_report0-False] PASSED
  tpu_inference_connector_c1_test.py::test_consumer_blocks_after_failed_pull_and_abort[tpu_sync_report1-True] PASSED
  ============================== 9 passed in 8.92s ===============================
  ```

  Re-run 2026-10-22 with §4 of the file added (the connector variants of
  `Caller.lean`, below): `17 passed in 9.87s`, the eight new cases being
  `test_fixed_connector_failed_pull_frees_or_recomputes[fail|recompute]`,
  `test_fixed_connector_abort_before_failed_pull_frees[fail|recompute]`,
  `test_naive_connector_decodes_on_unwritten_kv[fail|recompute]`,
  `test_load_error_only_connector_leaks[fail|recompute]`.

  Captured in the failing-case runs, the connector's only trace of the
  event: `ERROR tpu_raiden_connector.py:645 TPUConnector Worker 0 -->
  failed_recving=['0']`. What the two composition cases assert, in words:
  producer — a 4-block prefill finishes `FINISHED_LENGTH_CAPPED`,
  `request_finished` holds the 4 blocks, tpu-sync's `([], [], ["0"])` is
  translated to an empty `KVConnectorOutput`, and after 51 further scheduler
  steps the pool is still 4 short and the request still in
  `scheduler.requests`; consumer — a request waits for remote KV with 4
  blocks allocated, the failed pull is translated to nothing, the API layer
  aborts the request, and after 51 steps the 4 blocks are still held. With
  `(["0"], [], [])` (producer) or `([], ["0"], [])` (consumer) both pools
  return to their starting size.
- **The contract being broken** (vLLM, `kv_connector/v1/base.py:357-389`): a
  request for which `request_finished()` returned `True` has its blocks held
  by the scheduler until the connector returns its id from `get_finished()`;
  and *"even if failures occur, the request must still be reported via
  `get_finished()`, and the failed block IDs must appear
  [in `get_block_ids_with_load_errors`] no later than that same pass."*
  The scheduler frees sender blocks only from `finished_sending`
  (`scheduler.py:2471-2474`), frees or recomputes a failed receive only through
  `invalid_block_ids → failed_recving_kv_req_ids` (`:2390-2401, 2646`), and
  has no timeout of its own for `WAITING_FOR_REMOTE_KVS` (`:646-651` logs
  only).
- **Where (connector):** `get_finished` (`tpu_raiden_connector.py:632-657`)
  destructures `poll_stats()` into `done_sending, done_recving, failed_recving`
  (`:638`), logs `failed_recving` and returns only the first two (`:640-657`;
  the comment: *"Do NOT report failed receives as done_recving … Leave them
  pending; the request times out at the API layer instead"*).
  `get_block_ids_with_load_errors` is not overridden (base default `set()`,
  `base.py:375-393`). `SendMeta.expiration_time` is declared (`:113`) and set
  from `TPU_P2P_WAIT_PULL_TIMEOUT` (`:441-446`) and **never read**.
- **History and attribution.** The connector was created in one commit,
  `a342edc3` (2026-06-08, "Use tpu-raiden for KV cache transfer"), as a port
  of the JAX-P2P `tpu_connector.py`. The old connector had a live expiry loop
  — *"Mark a req as done sending when it's expired. This req can then be
  released blocks in the current scheduler step"* (`tpu_connector.py:921-935`
  at `a342edc3^`) — that put expired sends into `done_sending` itself. The
  port removed that loop (its `get_finished` says it *"replaces the
  reqs_wait_pull/reqs_pulling bookkeeping"*, `:634-636`), kept the
  `expiration_time` field and its assignment, and relied on tpu-sync's
  `done_sending` instead. At that date the reliance was **correct**: tpu-sync
  reported an expired send as `done_sending` (`978efff`, 2026-06-13). The
  **D half** of C1 (failed receives never surfaced) therefore dates from
  `a342edc3`; the **P half** dates from tpu-sync `4246613` (2026-08-24, see the "tpu-sync side" subsection),
  which moved expired sends to `failed_recving_` without the connector
  following. Three later connector commits (`35969606`, `134033aa`,
  `7ed46a6`) touched the file without changing any of this, nor did the one
  after the pin (`67d7e0b3`, 2026-09-09, IPv6) on the way to `c2b062b`.
- **Producer sequence (P leaks):** `request_finished` returns
  `delay_free_blocks = True` with a fresh uuid (`:437-455`) → scheduler holds
  the blocks (`scheduler.py:2075-2092`) → worker `register_read` (`:587`) →
  tpu-sync `NotifyForRead` creates a `TransferSendSession` with
  `deadline = now + timeout_s` (`kv_cache_manager_with_transfer.cc:462-506`;
  `timeout_s` is the same 180 s, connector `:522`, `utils.py:88-91`). If D
  never pulls, or the push fails, the poll finishes the session with
  `DeadlineExceeded`/the push error and files the req_id in **`failed_recving_`**
  (`mgr.cc:967-976`: `(failed ? failed_recving_ : done_sending_)`). The
  connector drops it; `finished_sending` never contains it; the blocks are
  never freed.
- **Consumer sequence (D leaks):** `start_read` (`:606`) → tpu-sync receive
  fails (deadline, transport error, producer gone) → `failed_recving` →
  dropped. The request stays `WAITING_FOR_REMOTE_KVS` with its blocks. When the
  client disconnects and the API server aborts it, `finish_requests` sets
  `delay_free_blocks = request_id not in finished_recving_kv_req_ids`
  (`scheduler.py:2063-2068`) — true — and the free is deferred to a
  `finished_recving` report that never comes.
- **Triggers:** any D-side pull failure (both nodes); D with a **full local
  prefix hit** for a prompt P just prefilled — D's "notify P" branch is a no-op
  by design (`:614-621`: *"the producer is freed by the pull's own ack, or by
  timeout if no pull happened"*) so P waits 180 s and then leaks; D absent
  (proxy drop, D restart before `start_read`) — P; client abort of a pull that
  later fails — D.
- **Impact:** a monotone drain of the KV block pool on long-running P and D
  nodes, one `logger.error` line per event and nothing else; presents as
  shrinking KV capacity and admission stalls after hours, cured by restart.
  The leaked requests also stay in `scheduler.requests`.
- **What is *not* wrong:** the pair never frees a block tpu-sync may still be
  DMA-ing into. Success, failure and abort all free either after settlement
  or never. That discharges `Pipeline` A4 (`tpu_sync/formal_verification/docs/transfer/prefill_decode.md`
  §Upper boundary; `wroteReleased` in `MultiRequest.lean`) for this caller
  pair, by reading — the leak is the trace where a failure report never maps
  to a free.
- **Lean** (`tpu_sync/formal_verification/TpuSyncVerify/Transfer/Caller.lean` and `Caller/MultiWorker.lean`, 2026-10-22 / 2026-10-27):
  the pair is modelled above `Pipeline.lean`'s publication boundary — the
  connector as a function from tpu-sync's per-request report to what it tells
  the scheduler (`Connector`), the scheduler's transfer-held block lifecycle
  on both nodes under both `kv_load_failure_policy` values, both for a single
  worker and across two workers aggregated by `KVOutputAggregator`
  (`MultiWorker.lean`). C1 is
  `trace_dropFailed_p` (P: `pOutcome false` → `leakP`), `trace_dropFailed_d_abort_after` and
  `trace_dropFailed_d_abort_before` (D: `dOutcome false` and `finish` in either order
  → `leakD`), and in the multi-worker model `trace_mw_dropFailed_partial_failure_leaks`
  (one worker succeeds while the other fails, stopping `pSentCount` / `dRecvCount`
  at `1 < 2`), all with `connectorDropFailed`; `leakP_absorbing` /
  `leakD_absorbing` (`mwLeakP_absorbing` / `mwLeakD_absorbing`) prove no later
  engine event can undo either, which is the formal content of "leak". The
  two-channel fix shape below is `connectorTwoChannel`, and `contract_safe` /
  `mw_contract_safe` prove that *any* connector meeting `Contract` (forward
  every outcome; a failed receive also on the load-failure channel — the
  `base.py:357-393` text) never frees HBM while a worker is still in flight
  (`mwEarlyFree = false`), never leaks, and never decodes unwritten KV under
  either policy and under both `AggChannel.eagerBlock` and
  `AggChannel.latchedReq`. The two half-fixes each have a trace: `trace_naive_decodes`
  (`done_recving` alone — the EngineCore crash the connector's comment fears
  is real: the request is promoted with its whole prompt counted as computed)
  and `trace_loadErrorOnly_*` / `trace_mw_latched_loadErrorOnly_never_emits`
  (load-failure channel alone — errored or latched,
  but the free waits for a `finished_recving` that never comes, so still a
  leak). Each of these end states is also asserted against the real
  scheduler in §4 of the test file. Exhaustive `search` / `mwSearch` per
  configuration: `connectorTwoChannel` safe, the other three find the trace. Assumptions B1–B3
  in the module header (`expectedP = 2`, `expectedD = 2` matching participating
  workers in `MultiWorker.lean`, whole-transfer failure, no preemption / prefix
  caching / chunking).
- **Hardware repro (not yet run):** `examples/single_host_disagg`: start P
  and D, send one request through the proxy, stop D before it pulls (or make
  D's prefix cache hit the whole prompt), wait `TPU_P2P_WAIT_PULL_TIMEOUT`,
  observe P's `failed_recving=` error line and that P's KV usage never
  returns; repeat to watch it accumulate. The CPU test above covers every
  state transition except the native timeout firing.
- **Fix shape (for the record, not the point of this entry):** report
  timed-out/failed sends in `finished_sending` (settled, safe) and failed
  receives through **both** `get_finished()`'s `done_recving` and
  `get_block_ids_with_load_errors` in the same pass — either alone is wrong
  (`Caller.trace_naive_decodes`, `trace_loadErrorOnly_*`); the pair preserves
  the crash protection the comment is about (`Caller.contract_safe`);
  companion tpu-sync change: a separate `failed_sending` list from
  `poll_stats()`. *As carried by PR #3918 (2026-10-28):* the same shape, with
  the D-side failure on vLLM's request-level channel instead of the
  block-level one. In the vLLM that tpu-inference's LKG now tracks
  (`e7bb7e2f`, then `2fb320d8`),
  `KVConnectorBase_V1.get_transfer_results` returns
  `KVConnectorTransferResults(finished_sending, finished_recving,
  failed_recving)` (the default implementation wraps `get_finished`);
  `KVConnectorModelRunnerMixin._get_kv_connector_output` copies the three
  sets into `KVConnectorOutput` and still sets `invalid_block_ids =
  get_block_ids_with_load_errors()`; `Scheduler.update_from_output` calls
  `_handle_failed_recving(kv_connector_output.failed_recving)` before
  `_handle_invalid_blocks` — for a `WAITING_FOR_REMOTE_KVS` request, under
  `recompute_kv_load_failures` it sets `num_computed_tokens = 0` and adds the
  id to `failed_recving_kv_req_ids`, otherwise the request is failed; and
  `KVOutputAggregator.aggregate` keeps `_failed_recving_pending |=
  kv_output.failed_recving` and emits `failed_recving =
  _failed_recving_pending & finished_recving`, so a multi-worker failure is
  surfaced only once every worker has reported. The PR's mapping (P: failed →
  `finished_sending`; D: failed → `finished_recving` ∧ `failed_recving`) is
  therefore an instance of `connectorTwoChannel` / `Contract` in `Caller.lean`
  over `AggChannel.latchedReq` (`MultiWorker.lean`): the aggregator forwards
  `invalid_block_ids` eagerly (`AggChannel.eagerBlock`) whereas it latches
  `failed_recving` in `_failed_recving_pending` (`dFailPending`) until every
  participating worker has reported (`finished_recving`), delivering failure and
  completion to the scheduler in the same pass (`applyRecv_eager_eq_latched`,
  `trace_mw_latched_staggered_fail_then_ok_*`). Note two couplings: PR #3918's
  `get_finished()` wrapper returns `(results.finished_sending,
  results.finished_recving)` without overriding `get_block_ids_with_load_errors`,
  so on a pre-`e7bb7e2f` vLLM that calls `get_finished()` it would behave as
  `connectorNaive` (`trace_naive_decodes`); and under `TPU_RAIDEN_ENABLE_MULTI_NUMA=1`,
  `NumaAwareKVCacheManager::CompleteReadRaw` violates the settled-before-report
  precondition (F11). The companion tpu-sync change is still open (see the next
  subsection).

### The tpu-sync side of C1: `4246613` reclassified a never-pulled send from `done_sending` to `failed_recving`, and the list is named for the other side — contributing cause and improvement request, not a defect

- **Status:** not a tpu-sync defect — downgraded 2026-10-20 after asking
  whether it is a problem without C1. It is not: a consumer that reads all
  three `poll_stats()` lists and frees on any outcome is unaffected, and
  tpu-sync's behaviour is self-consistent and pinned by its own test
  (`SendDrainTest.SendNobodyPulledFailsAtItsDeadline`,
  `kv_cache_manager_with_transfer_send_drain_test.cc:370-379`). What
  remains is an API-contract and naming problem that made C1's P half
  likely and will catch the next connector author the same way; to be
  raised with the tpu-sync owners as an **improvement request** inside C1's
  report, not as a numbered finding. In-tree readers of `failed_recving`
  other than the connector are two microbenchmarks that read it on the
  receiver only (`examples/microbenchmarks/jax_d2d_read_benchmark_runner.py:360-363`,
  `torch_d2d_read_benchmark_runner.py:326`), i.e. exactly the reading the
  name invites.
- **Where:** `KVCacheManagerWithTransfer::CompleteReadWithDetails`,
  `kv_cache_manager_with_transfer.cc:964-985`. A send session past its
  deadline and not draining is finished with `DeadlineExceeded` (`:967-973`)
  and then `(failed ? failed_recving_ : done_sending_).insert(req_id)`
  (`:974-976`). `poll_stats()` returns the three lists verbatim
  (`api/jax/kv_cache_manager.py:164-171`, `api/torch/` likewise).
- **History.** At `978efff` (2026-06-13) the sweep did
  `done_sending_.insert(entry->req_id)` for an expired send
  (`core/kv_cache_manager_with_transfer.cc:770-771` then): a registration
  nobody pulled was reported as *done sending*, and the producer freed its
  blocks. `4246613` (2026-08-24, "Retry and fail loudly when host transfer
  staging memory is exhausted") changed that line to
  `failed_recving_.insert(entry->req_id)` with the comment *"Nothing pulled
  this entry within its deadline; the bytes were never sent, so the transfer
  failed."* Its description and validation are about staging exhaustion
  (1,112 exhaustion events, dynamic staging); the never-pulled case changed
  meaning in the same hunk. `8b65aa8` (2026-09-10) folded both outcomes into
  the `failed ? … : …` line that stands today. The 2026-06-08 port of the
  tpu-inference connector (`a342edc3`) was written against the earlier
  meaning: it relies on `done_sending` to cover expiry (its own expiry
  bookkeeping was removed in the port, see C1) and drops `failed_recving`.
- **Why it still matters on the tpu-sync side:** `poll_stats()`
  is the producer's only signal that it may free the prompt's KV blocks.
  Whether a never-pulled prefill is "done" or "failed" is a reasonable
  design choice either way, but changing it is an API change for every
  producer, and routing a *send* outcome through a list called
  `failed_recving` invites exactly the reading the connector made ("the
  consumer's failures; not our blocks"). No in-tree Python caller, test or
  doc was updated to read `failed_recving` on the producer when `4246613`
  landed.
- **Effect through C1:** with the tpu-inference connector, every prefill
  whose consumer never pulls — D full local prefix hit, D absent, proxy drop
  — leaks its producer-side HBM blocks until restart (C1 for the vLLM
  mechanics); two months of exposure on anything running tpu-sync ≥
  `4246613` with that connector. Without C1: no effect.
- **Improvement request:** report producer outcomes in their own
  lists — at minimum a `failed_sending` alongside `done_sending` — and say
  in `poll_stats()`'s docstring which list a producer must read to release
  blocks. Whether an expired, never-pulled send belongs in `done_sending`
  (the consumer does not need it, so the bytes "not being sent" is not an
  error for the producer) or in `failed_sending` is the owners' call; what
  matters is that it is not silently in neither place the producer reads.
  Still the case at `42dda542` (2026-10-28): `CompleteReadWithDetails` files
  a failed or expired send with `(failed ? failed_recving_ : done_sending_)`
  and there is no `failed_sending` list. The nearest upstream activity is the
  unmerged branch `yinlin/settled-transfer-failure-reason` (`74376a90`,
  2026-10-13, "Report why a transfer failed in poll_stats_with_details"),
  which attaches a code / reason / phase to each failed transfer but keeps
  the list structure. With PR #3918 the tpu-inference connector reads
  `failed_recving` on both roles, so the request is now about the next
  caller, not this one.

---

## Callers

What the two open-source engines that drive `tpu-sync` do at the points the
reshard findings depend on. Read 2026-10-20 at `vllm-torchtpu` `9725110`
(`tpu_connector.py`, 7,047 lines) and `sglang-torchtpu` `9a6eef1`
(`sglang_tpu/disaggregation/raiden/`). Line numbers are for those commits.

**How each caller uses the control plane.**

- *vllm-torchtpu* — one `coordinate_transfer` per request ("Starts exactly one
  source-controller transfer per request", `tpu_connector.py:5425`); a second
  submission for the same destination request is skipped (`:5480-5491`). The
  only retry is for the exact pre-arm error `"Missing producer block
  registration"` (`_start_stage3_transfer_with_d5_retry`, `:5271-5303`, 10 ms
  cadence for at most `_STAGE3_D5_REGISTRATION_WAIT_S = 5.0` s; the deferred
  path parks and re-attempts once per scheduler step until the registration
  wait budget, `:5966-5996`). Cancellation and pre-send connection failures
  fail the load without retry (`:6006-6031`); **any other error after the RPC
  is "uncertain": the load stays blocked waiting for the native terminal, and
  is never re-coordinated** (`:6032-6050`). Pipeline decode requires the same
  stage count as pipeline prefill, and every stage names the complete source
  rank set (`_stage3_source_work_units`, `:4860-4893`). Admitted topologies
  are `pp{2,4,8}_prefill → pp{2,4,8}_decode` (TP 1) and `pcp/dp` prefill →
  `dp`/`dp…tp2` decode (`:3856-3930`); TP prefill → PP decode is not admitted.
  Producer side: registrations past their expiry are offered to
  `cancel_request_blocks_if_unclaimed` on every poll until it returns true
  (`:5160-5190` and the expiry sweep above it).
- *sglang-torchtpu* — `coordinate_transfer` retried only while the reply
  contains `"Missing producer block registration"` and the room's deadline has
  not passed (50 ms cadence, `pipeline.py:1672-1721`); any other failure fails
  the room, and the room's pages stay armed for one native deadline because
  "the controller arms the receivers before the senders, so a push can still
  land" (`:1716-1731`). Decode must "use DP or the same pipeline stage count"
  (`:1201-1206`): a DP decode pulls from all prefill stages in one transfer
  (one destination unit); a PP decode stage pulls only from its own rank.
  Twins (SWA), early parts and stage groups each get a **distinct derived
  uuid** (`pp_common.py:197-208`, `pp_swa.py:98-99`). Producer release: with a
  DP decode, `cancel_request_blocks_if_unclaimed` is retried every 50 ms until
  it returns true; with a PP decode the producer votes
  `complete_request_blocks` (`:1568-1592`).

- *tpu-inference* (`tpu_raiden_connector.py` @ `7ed46a6`, 663 lines) — the
  **prefill-to-decode** caller; it does not use the reshard control plane at
  all. Producer: `request_finished` holds blocks and mints a uuid
  (`:437-455`); worker `register_read` (`:587`). Consumer: one `start_read`
  per request (`:600-613`), a no-op "notify" when there is nothing to pull
  (`:614-621`). Outcome: `get_finished` forwards `done_sending`/`done_recving`
  and drops `failed_recving` (`:632-657`) — see C1 (fix open as PR #3918,
  2026-10-27; note that `_remote_endpoint`, `:519-551` at `7ed46a6`, wires
  multi-NUMA `len(local_eps) > 1` shard-matched pulls, so forwarding
  `failed_recving` under `ENABLE_MULTI_NUMA=1` unmasks F11's eager-failure
  mid-DMA free in `NumaAwareKVCacheManager::CompleteReadRaw`). uuid: fresh per send
  (`get_uuid`, `:659-663`), no same-uuid retry anywhere, which is what R-B
  needs. No Python-side timeout is enforced (`SendMeta.expiration_time` is
  dead); every deadline is tpu-sync's.

**What this means per finding.**

| Finding | Caller condition it needs | vllm-torchtpu | sglang-torchtpu |
|---|---|---|---|
| F8 / R2b (claim leak on sender-dispatch failure) | a sender RPC failing after arming | Reached. The connector sees a post-arm error, marks the load "uncertain", waits for the receiver's native timeout, then recomputes. The producer's `cancel_request_blocks_if_unclaimed` returns `false` every poll until `ttl_s_` (600 s): its registered blocks stay pinned for that long. | Reached. Room fails, pages armed for one native deadline. DP-decode producers retry `cancel_…_if_unclaimed` every 50 ms until TTL; PP-decode producers vote `complete_request_blocks`, which does retire the claim once every rank has voted. |
| F9 / R8 (claim refreshes `claimed_` TTL but not `request_blocks_` TTL) | a claim more than `ttl_s_` after registration, while an earlier claim is live | Reached only for pipeline decode (several stages claim the same uuid at different times) and only if a later stage's claim lands > 600 s after registration. **Its error string is the one both callers treat as the benign pre-arm "registrations not yet there" case**, so the stage would spin on retries until its wait budget (vllm: up to the registration wait; sglang: the room deadline) and then fail the load / room — a stall followed by recompute, not corruption. | Same, for PP decode. |
| F10 / R6 — early unregister half | first failing push with siblings in flight | Reached (any multi-peer or multi-pool send). Consequence without a retry: later chunk resolution in the failed session returns nothing (bounded) or whole blocks (full mirror); the socket adapter's per-uuid failure latch cancels the sibling posts anyway. | Same. |
| F10 / R6 — staging-lease aliasing half | a **second `coordinate_transfer` with the same uuid** while the failed sender session drains | **Not reached.** Post-arm failures are never re-coordinated; the only retry is pre-arm. | **Not reached.** Same policy; sibling transfers use distinct derived uuids. |
| R7a (owner-unscoped `completed_units_` on multi-stage claims) | one source rank sending to ≥ 2 destination stages under one uuid | **Not reached.** Equal stage counts are enforced (`:4874-4881`), each rank feeds one stage; TP prefill → PP decode is not admitted. | **Not reached.** DP decode is one destination; PP decode requires equal stage counts (`:1201-1206`). |
| R7b (stale `completed_units_` after `AbandonClaim`) | a vote before an abandon, then a re-claim of the same uuid | **Not reached** by the callers' retry policies (re-claims happen only before any sender was dispatched, i.e. before any vote). | Same. |
| `Pipeline` A4 (no HBM free under a live DMA) | the engine frees transfer-held blocks only after the connector reports settlement | n/a (reshard caller) | n/a | 
| C1 (block leak on failure) | a transfer failure or a never-pulled registration | n/a (reshard caller) | n/a |
| F7 / R1 (fixed) | a failed incoming push on a reshard receiver | Was reached: exactly the "uncertain, wait for native terminal" path, which is why the fix shortens the wait from `timeout_s_` to immediate. | Same ("pages armed until the native deadline"). |

Net: F8 is the reshard finding with the widest caller exposure (every
post-arm sender failure pins producer blocks for the TTL); F9's exposure is
narrow but it masquerades as the callers' benign retry case; F10's aliasing
and R7a/R7b need a same-uuid re-coordination or a rank fanning out to several
stages, which neither caller does today. Those remain real defects in
`tpu-sync` (the library cannot assume the caller's policy) but are not
production incidents waiting to happen with these two engines as of these
commits.

---

## Refuted or closed

### R-A. Premature completion in `TransferReceiveSession::IsReadyToComplete()`: REFUTED

The transport dispatches a layer before counting its blocks
(`block_transport.cc:790` then `:630-631`); the receiver counts per shard
and across senders; the `network_completed_` disjunct is an intentional fast path. The
receive-session model proves readiness sound under this ordering
(`Transfer/PrefillDecode/Receive.lean`, assumption A4, `ReadinessSound`).

### R-B. Stale push after a same-uuid retry: not reachable from vLLM

The receive session counts blocks without de-duplication and the chunk header
has no generation, so a push from an old attempt could count toward a new
attempt's session. vLLM never re-arms a uuid: the uuid is fresh per send
(`tpu_connector.py:5607`); a request is loaded once (`_remote_kv_processed`);
a failed load is recomputed, not pulled again; the only same-uuid retry is on
`"Missing producer block registration"`, which comes from `LookupAndClaim`
(`request_block_registry.cc:440-466`) and runs before any receiver is armed.
This remains an **API hazard** for other callers, since the headers allow
same-uuid re-registration.


**Sharpened 2026-10-20 (`0ac16d1`), `Transfer/PrefillDecode/Transport.lean`.**
The hazard is narrower and the consequence more specific than the 2026-09
wording:

- Of the three completion contracts in `BlockTransport::CompleteIncomingPush`
  (`block_transport.cc:641-794`), the sender-declared (`:733-737`) and
  plan-declared (`:705-709`) ones reject a stream beyond the declared count and
  fail the receive; the chunk-count contract (`:740-742`) — the one the
  prefill-to-decode path uses whenever the receive plan has no
  `shard_push_schedules` (`kv_cache_manager_base.cc:2688-2704`) — accepts it
  silently. The duplicate is not dispatched (`completed_chunks ≠ num_streams`)
  but is still reported through `OnBlockShardsReceived` (`:630-631`), so
  `network_completed_` is reached with another layer's blocks never received,
  and `IsReadyToComplete` (`transfer_receive_session.cc:450-455`) reports
  success with that layer never copied
  (`Transport.trace_dup_chunk_publishes_missing_layer`).
- On **either** contract, once every layer has been called the transport
  erases the uuid's `layer_progress_` entries (`:765-779`) while the receive is
  still live (its H2D copies are in flight), and `ExecuteLayerH2d` has no
  once-latch of its own (`transfer_receive_session.cc:642-700`). A later stream
  for that uuid starts a fresh entry, fires `OnLayerReceived` again and issues
  a second copy of the same layer while the first may still run. The session
  is *not* fooled about settlement — `in_flight_` holds `done_` off until both
  copies return (`:412-416`) — but the two callbacks bring
  `num_completed_layers_` to `num_layers()` (`:725-731`) with another layer's
  copy still pending, and a failing duplicate copy fails the whole receive,
  because `FinishLocked` records the first error even when already draining
  (`:359-363`) (`Transport.trace_dup_after_retirement`,
  `trace_dup_copy_fails_late`). A redundant DMA and a spurious failure, not a
  wrong publication.
- In both cases the duplicate stream's payload read (`:605`) rewrites the
  layer's host staging while the first H2D copy of that layer may still be
  reading it; harmless only if the duplicate carries the same bytes.
- With honest senders (at most the declared streams per layer, for the life of
  the receive) none of this is reachable on either contract:
  `Transport.reachable_safe` (`OnceDispatched`, `NetworkSound`,
  `CompleteOnSuccess`), for any positive layer, sender, stream and block
  counts. The model rests on two further assumptions it names but does not
  prove (`Transport` A2, A3): the contract a layer runs under is latched by
  its first stream (`:662-684`), and the receiver seats the session before it
  publishes the plan (`kv_cache_manager_with_transfer.cc:555-573` vs
  `:602-605`), so a push landing in that window would latch chunk-count on a
  sender-declared plan; and the sender-declared contract counts distinct
  `remote_id = node_id()` (`:1170`) against `shard_push_schedules`, which are
  keyed by source shard, so it presumes one source shard per node.

Still not reachable from the in-repo callers for the reason above (fresh uuid
per send, no retry into an armed receiver), and no in-repo sender path opens
more streams than it declares (`header.reserved`), so this stays an **API
hazard** rather than a numbered finding. Two local changes close it without
touching honest behaviour — reject `completed_chunks > num_streams` in the
chunk-count branch, mirroring the other two, and keep a per-layer once-latch in
`ExecuteLayerH2d` (`Transport.stepHardened`: bounded searches find no
violation, honest traces unchanged). Worth doing if the transport is ever
exposed to a sender it does not control.

Re-read 2026-10-28 at `42dda542`: `42dda542` itself ("Extract server session
classes for BlockTransport") moved the server side into
`tpu_sync/transport/block_transport_session.{h,cc}`. The three completion
contracts now live in `BlockTransportServerPushSession::CompleteIncomingPush`;
the sender-declared and plan-declared branches still reject an over-count
(`AlreadyExistsError`) and the chunk-count branch is still
`array_complete = progress.completed_chunks == expected_chunks;` with no
rejection. Retirement is now per session object: once every layer has been
called the session clears `layer_progress_`, sets `done_` and is erased from
`BlockTransport::active_push_sessions_`, and
`BlockTransport::GetOrCreatePushSession` seats a fresh session for the next
stream of that uuid. Same hazard, same verdict; the line citations above are
from `0ac16d1` and are not re-pinned.

Checked 2026-10-30 at `42dda542` against the in-repo controllers and
`ExpectedPushSenders`: `KVCacheManagerBase::ExpectedPushSenders(uuid)`
(`kv_cache_manager_base.cc:2745-2762`) returns `std::nullopt` when no receiver
plan is registered (`StartRead`, `KVCacheStore` /
`WorkerServiceImpl::TransferBuffers`, `WeightSynchronizerBase`), when
`request.pool_groups_size() > 0` (`ReshardCoordinator::RunSubPlan`), and when
`request.shard_push_schedules_size() == 0` (including primary
`StageBroadcastGroup` hops in `BroadcastEngine.execute_slice_broadcast_pipeline`'s
`_dispatch_hop`), so only
non-pool receiver `RegisterActivePlan` plans (`pool_groups_size() == 0` with
`shard_push_schedules_size() > 0`) enter the `sender_streams` gate. Inside
`KVCacheManagerWithTransfer::RegisterActivePlan`, `EmplaceRecvSessionLocked`
runs synchronously before `base_->RegisterActivePlan`, and in-repo controller
hops that populate non-pool receiver `shard_push_schedules`
(`BroadcastEngine.execute_slice_broadcast_pipeline`'s `_run_single_transfer`
via `RaidenController.start_transfer`,
and remote destination preparation via
`RaidenControllerClientFacade.register_transfer_schedule`) await receiver
`COMMAND_START_TRANSFER` completion before dispatching senders (leaving
`Transport` A2 an external ordering assumption only against pushes dispatched
before `RegisterActivePlan` returns). For `Transport` A3,
`BuildPoolReshardPlan` checks unique contiguous `transfer_rank`s and
`HostOffloadBackend::ComposeKVTransferSpec` checks dense `[0, N)` `node_id`s
when `KVCacheStore` starts with `expected_worker_count > 0` and a global
registry (`WorkerRegistry::RegisterWorker` exempts `node_id == 0`, and both
paths bypass `ExpectedPushSenders`), whereas legacy non-pool
`RegisterActivePlan` plans leave `A3` unchecked (`KVCacheManagerWithTransfer`
and its `KVCacheManager` bindings default `node_id` to `0`,
`KVCacheManagerBase::node_id()` defaults to `-1`, and
`JobEntity.encode_start_transfer` keys receiver `shard_push_schedules` per
source shard when `num_src_shards > 1` while `header.remote_id` is per-worker
`node_id()`, so `num_src_shards > 1` or multi-worker default `node_id = 0`
mis-indexes `GetBlockChunks`, fails with `AlreadyExistsError`, or hangs with
`senders_complete < expected_senders`). `Transport.lean` §Assumptions updated
accordingly.

Re-read 2026-11-09 at `00e946e3`: the Peregrine backend commits (`e082548c`,
`984125ce`) and the `GetBlockArrayHostSpan` / `ValidateChunks` rework
(`4e61045e`, `103ec23f`) grew `block_transport_session.cc` by some 500 lines,
but `BlockTransportServerPushSession::CompleteIncomingPush`'s three contracts
are as before: the plan-declared and sender-declared branches return
`AlreadyExistsError` on an over-count and the chunk-count branch is still
`array_complete = progress.completed_chunks == expected_chunks;` with no
rejection. Same verdict.

### R-C. `RequestBlockRegistry` lifecycle: no defect found (read)

Claims are owner-scoped; a cancel tombstone blocks later registration and
claims; an early completion vote is allowed only for an empty `block_ids`
registration. TTL-based edge cases (claim or tombstone expiring after 600 s by
default) need a transfer or rank to be more than 600 s late. Design limits,
not bugs.

### R-D. `WriteRemote` landing blocks freed at the deadline while the DMA is still writing: REFUTED (read)

`DeadlineLoop` (`kv_cache_store_service.cc:1087`) marks the op failed but
does **not** free the landing blocks. They are freed only when the transfer
future resolves (`CompleteWriteRemote`, `:864-904`, → `ReleaseLandingBlocks`
`:589`); a leak warning is logged if the transfer never resolves
(`:1115-1126`). This is the `deferSettleWhilePullInFlight` design from the
Lean model. `ReadRemote` (F2) lacks it, which suggests F2 is an oversight
rather than a design choice.

### R-E. Local `KVCacheStore::Load` reads host blocks that could be evicted mid-copy: REFUTED (read)

Both `Load` overloads require that the caller already holds a pin on every
hash; eviction skips pinned entries (`host_offload_backend.cc:679, 778`,
`lru_cache.h:258-294`).

### R-F. Fetch-source (production remote load) unpins before the pull finishes: REFUTED (read)

It matches and pins atomically (`pin_found = true`,
`kv_cache_store_service.cc:461-474`); the pins are released by a scope cleanup
after `transfer_future.Await()` returns (`:490`, `:542`).

### R-G. Reshard settle sweep in `CompleteReadWithDetails` is generation-less: API hazard only (read, `c9bc124`)

The manager's settle sweep collects `(uuid, generation)` pairs under `mu_` and,
after dropping `mu_` (`kv_cache_manager_with_transfer.cc:1105`), calls
`UnregisterSettledPlan(uuid, generation)` and
`base_->ReleasePoolStagingLeases(uuid)` for each (`:1108-1113`). For the
prefill-to-decode receiver the generation is real
(`TransferReceiveSession::TakePendingUnregister`,
`transfer_receive_session.cc:438`) and `UnregisterSettledPlan` skips a plan
whose uuid now belongs to a newer registration (`:785-790`). For reshard it is
always 0: `ReshardReceiveSession::TakePendingUnregister` hard-codes it
(`reshard_receive_session.cc:512-520`; the header says "0 for pool-reshard
plans") and a failed `ReshardSendSession` is pushed as `(uuid, 0)` (`:1024`).
`ReleasePoolStagingLeases` is uuid-keyed with no generation at all
(`kv_cache_manager_base.cc:2147-2163`).

Consequence, if reached: a new same-uuid `PoolReshardPush` /
`PoolReshardRegisterRecv` that passes the `AlreadyExists` check after the old
entry is erased (`:673-686`, `:712-727`, erasures at `:1026` / `:1093`) and
acquires its leases in `Create` (`reshard_receive_session.cc:381`,
`reshard_send_session.cc:231`) before the post-`mu_` loop runs has those
leases freed under it — the F6 aliasing shape, reached from the sweep instead
of from a duplicate registration — and, because generation 0 skips the guard,
`UnregisterSettledPlan(uuid, 0)` drops the newcomer's plan as well.

Why it is an API hazard and not a finding: (1) the sweep's release is a
backstop — both reshard sessions already release their own leases on settle
(`reshard_receive_session.cc:461-465`, `reshard_send_session.cc:473`), so the
call only bites when *another* session holds the uuid; (2) that needs a
same-uuid re-coordination inside a microsecond window, and the only reshard
caller mints a random 63-bit uuid per transfer
(`tpu_sync/rpc/raiden_controller.py:760`, `:1072`) — the same precondition and
verdict as R-B and the F10 aliasing half in the Callers table; (3) on the
receive side the new `Create` registers its plan before leasing, so while the
old plan is still registered the retry fails with `AlreadyExists`
(`kv_cache_manager_base.cc:3175`) rather than leasing, narrowing the window
further. Not modelled in Lean: the statement ("a uuid-keyed release with no
generation frees another holder's slots under uuid reuse") is a one-line
reading of `ReleasePoolStagingLeases`, and `Reshard/PoolStaging/Registration.lean`
already carries the F6 witness for the same slot-aliasing consequence.

Re-read 2026-11-03 at `56a0269d`: `10d181f6` / `1523b07d` removed
`UnregisterSettledPlan(uuid, generation)` (plans now live inside
`TransferSession`) and replaced `CompleteReadWithDetails`'s generation check
with `std::erase_if` over `retired_uuids` checking
`sessions_.contains(entry.uuid) ||
pending_pool_reshard_recvs_.contains(entry.uuid)` (`kv_cache_manager_with_transfer.cc:1046-1050`),
followed after unlocking `mu_` (`:1058`) by unlocked
`ForgetPushProgress(entry.uuid)` and `ReleasePoolStagingLeases(entry.uuid)`
calls (`:1061-1066`). Because `std::erase_if` runs inside the *same* `mu_`
critical section that just erased `entry.uuid` from `sessions_` (`:1043`), the
guard is dead code for every non-pending UUID, widening this post-`mu_` sweep
window to `ForgetPushProgress(uuid)` on prefill-to-decode and `RegisterActivePlan`
receivers as well; reproduced end-to-end as **F16**
(`UuidRetirementBughunt.CompleteReadSweepDeadEraseIfWipesLiveReplacementAndPublishesCorruptHbm`).
At `00e946e3` the same `std::erase_if` still runs inside the `mu_` scope that
erased the uuid (now after `SweepSubPlanChainsLocked(now)`,
`kv_cache_manager_with_transfer.cc:1106-1110`), followed by the unlocked
`ForgetPushProgress` / `ReleasePoolStagingLeases` loop (`:1121-1126`); see
F16's 2026-11-09 re-run.

### R-H. `ReshardCoordinator::RunSubPlan` `kController` `sender_status[i]` misindexing after a pre-RPC `continue`: low-severity error-attribution clobber (read, `56a0269d`)

In `ReshardCoordinator::RunSubPlan`'s `WorkerDelivery::Mode::kController`
sender-dispatch loop (`tpu_sync/kv_cache/reshard/reshard_coordinator.cc:818-854`),
`sender_status` has size `N = plan.src_units.size()` (`:817`). If unit `k` hits
either pre-RPC error branch — missing schedule in `src_schedule_keys`
(`:831-835`) or `!compiled.ok()` from `CompileStartTransfer` (`:838-842`) — the
loop sets `sender_status[k] = error` and executes `continue` **without** pushing
into `futures`, while a subsequent unit `m > k` pushes its RPC future at
`futures[m - skipped]` (`:843-844`). The collection loop (`:846-854`) then
iterates `for (size_t i = 0; i < futures.size(); ++i)` and assigns
`sender_status[i] = ...` (`:850`, `:852`), overwriting `sender_status[k]` with
unit `m`'s `OK` status while leaving `sender_status[m]` default-constructed
`absl::OkStatus()`. Consequently the final check loop (`:876-878`) sees all
`OK` and `RunSubPlan` returns `absl::OkStatus()` despite unit `k` never having
been dispatched (contrast `kDirectWorkerRpc` at `:855-874`, which pushes a
ready `MakeErrorFuture` on error so `futures` stays 1:1 with `sender_status`).

Why it stays here rather than as a numbered finding: both `continue` branches
check invariants of the `PoolReshardPlan` that `BuildPoolReshardPlan` just built
in-memory on lines `:755-762` (`src_units` vs `sender_plans` map keys and
`CompileStartTransfer`), so neither `continue` is reachable from valid planner
output today; it is latent defensive-code rot that would surface only if a
future planner change violated its own invariant under `kController` delivery.
Fix: push `tsl::MakeErrorFuture<absl::Status>(...)` (matching `kDirectWorkerRpc`)
or store `(unit_idx, future)` pairs in `futures`.

### R-I. `WriteRemoteServerReactor::StartAck` vs `OnCancel` write-after-`Finish` hazard: REFUTED (test, `42dda542` / `00e946e3`)

`WriteRemoteServerReactor::StartAck` (`tpu_sync/kv_cache/kv_cache_store_service.cc:138-149`)
checks `finished_` under `mu_`, unlocks `mu_`, and then calls
`StartWrite(&ack_event_)`, while `OnCancel()` (`:217-222`) runs on a gRPC thread
without `gate_->mu` and calls `FinishWithError(::grpc::Status::CANCELLED)` →
`Finish(status)` (`:161-174`). If `OnCancel()` could run between `StartAck`'s
unlock and `StartWrite`, `StartWrite(&ack_event_)` would execute after `Finish`,
which gRPC forbids (`API misuse` `CHECK`).

Checked against gRPC 1.81.0 and confirmed empirically by
`kv_cache_store_service_reactor_bughunt_test.cc` (`WriteRemoteReactorStressTest`,
2/2 passing at `42dda542` and re-run 2026-11-09 on unmodified `00e946e3`):
`KVCacheStoreServiceImpl::WriteRemote` calls `StartAck` from inside the synchronous
method handler *before* returning the reactor pointer. Until
`CallbackServerStreamingHandler::RunHandler` calls `SetupReactor` on the
returned pointer, the reactor's writer is unbound: `StartWrite` only appends to
the reactor's pre-bind backlog, and gRPC gates `OnCancel` on **both**
cancellation *and* `SetupReactor` completion, so `OnCancel` cannot fire before
the pre-bind backlog has been flushed. Once the `ack_event_` write is in flight,
a concurrent `Finish(CANCELLED)` from `OnCancel` is legal in gRPC's callback API
(separate core batches; `OnWriteDone` runs before `OnDone`). Verbatim output
(`00e946e3`):
```
Running main() from gmock_main.cc
[==========] Running 2 tests from 1 test suite.
[----------] Global test environment set-up.
[----------] 2 tests from WriteRemoteReactorStressTest
[ RUN      ] WriteRemoteReactorStressTest.ClientCancelRacingTheAckNeverMisusesGrpc
WARNING: All log messages before absl::InitializeLog() is called are written to STDERR
I0000 00:00:1794259778.700440   36834 kv_cache_store.cc:937] KVCacheStore published at 127.0.0.1:39463
[observation] acked=0 cancelled_before_ack=2000 refused=0 other=0
[       OK ] WriteRemoteReactorStressTest.ClientCancelRacingTheAckNeverMisusesGrpc (2503 ms)
[ RUN      ] WriteRemoteReactorStressTest.CancelArrivingInsideTheHandlerIsHarmless
I0000 00:00:1794259781.196744   36834 kv_cache_store.cc:937] KVCacheStore published at 127.0.0.1:43343
[observation] handler-side cancels=300 acked=0 cancelled=300 other=0 in_flight_ops_after=300
W0000 00:00:1794259786.748632   36834 kv_cache_store.cc:964] Failed to unpublish store address 127.0.0.1:43343: failed to connect to all addresses; last error: UNKNOWN: ipv4:127.0.0.1:41525: Failed to connect to remote host: Connection refused. Peers may dial a dead address until it is replaced.
[       OK ] WriteRemoteReactorStressTest.CancelArrivingInsideTheHandlerIsHarmless (5606 ms)
[----------] 2 tests from WriteRemoteReactorStressTest (8109 ms total)

[----------] Global test environment tear-down
[==========] 2 tests from 1 test suite ran. (8110 ms total)
[  PASSED  ] 2 tests.
```

### Open / not yet checked

- *(Promoted to **F19**, 2026-11-09)* `KVCacheStoreClient::Fetch` sets no RPC
  deadline (`kv_cache_store_client.cc:61-125`), and on `Fetch` failure
  `HostOffloadBackend::LoadRemoteBlocks` frees `dst_host_block_ids` immediately
  (`host_offload_backend.cc:1244-1264`) while the receiving worker accepts
  planless `op = 6` / `uuid = 0` pushes into freed or reallocated host blocks
  (`kv_cache_store_fetch_bughunt_test.cc`, 4/4 failing; the combined end-to-end
  interleaving of a `Fetch` RPC breaking mid-`TransferBuffers` is exercised as
  those two halves rather than one single test).
- ReadRemote hooks capture a raw `this`, and `ClearReadRemoteHooks` is not
  called in `~KVCacheStore`. The controller is owned by the store and is
  destroyed first among the members that matter, so this is probably safe.
  Not verified.

## Coverage-gap tests (`coverage_gap_tests.patch` and per-PR `coverage_gap_{send,recv,read_remote_deadline}.patch`, at `42dda542`, run 2026-10-28: 9/9 pass; offered upstream)

The branch-coverage tables in `tpu_sync/formal_verification/` classify, per
model, which branches of the Lean `step` the upstream tests reach; the rows
classed **test** are schedules the existing harnesses can drive today but no
test does. This patch is those rows as tests, in the style of the files they
extend, with the outcome each asserts taken from the model's post-state. It
was first drafted at `c9bc124` (18 cases, all 18 passing there), then re-based
on `42dda542` and cut to the 9 cases that still add a branch after an
independent redundancy audit; the cuts are listed below the table.

| Case | Branch (Lean table) | What it pins |
|---|---|---|
| `RecvLifecycleTest.FailedH2dDispatchFailsAndSettlesTheReceive` | `Receive` `h2dIssueFail` drains settles errors | `hooks::kTransferRecvSessionH2dDispatch`: the receive fails in phase `h2d`, settles at once, slot back — no upstream test fails an H2D dispatch |
| `RecvLifecycleTest.SecondFinishOnAFailedReceiveIsANoOp` | `cancel` (no effect) | a second `Finish(error)` on a draining receive: the first error's code and reason are what the poll reports, once |
| `RecvLifecycleTest.PushLeaseClosingBeforeTheCopyEndsDoesNotSettle` | `pushEnd` (no effect) | the lease release neither settles nor frees staging; the callback does (the usual order for an asynchronous H2D) |
| `RecvDrainTest.CancelledReceiveWhoseCopyThenFailsStaysCancelled` | `h2dDoneFail` settles | the copy's error is absorbed by the draining receive; the reported code stays `CANCELLED` |
| `TransferSendSessionTest.FailedD2hDispatchOnFirstLayerSettlesAtOnce` | `Send` `wakeFail` settles | layer 0's `D2hSyncDispatch` refused with nothing issued: `fail_unissued_layers` fails layer 0's promise and the H2H chain's own callback releases the last op, so the send settles inside `StartPush` (upstream's `D2hDispatchFailureFailsUnissuedLayersAndDrainsIssuedCopies` covers a later layer with a copy in flight) |
| `TransferSendSessionTest.CancelledSendWhosePushThenFailsKeepsCancelled` | `h2hDoneFail` settles | **pins the sender's first-`Finish`-wins rule** through the push callback's error branch (no upstream test completes an H2H with an error) |
| `ReadRemoteDeadlineTest.UnansweredAcquireSettlesAtTheDeadline` | `ReadRemote` `deadlineSettles` settles | the deadline thread fires (1 s), the late lease is released |
| `ReadRemoteDeadlineTest.LateAcquireFailureAfterTheDeadlineIsAbsorbed` | `acquireFailed` (no effect) | a `NotFound` landing after the settle changes nothing and starts no read |
| `ReadRemoteDeadlineTest.PullCompletingAfterTheDeadlineReleasesTheLease` | `pullDone` (no effect) | shape B's shape, asserting only settle + lease release (the DMA-after-settle itself is F2) |

The `ReadRemote` deadline fixture holds the first in-suite tests in which
`RemoteReadDeadline()` fires at all (default 150 s; every `ReadRemotePullTest`
ends in seconds). It is its own `cc_test` with
`env = {"RAIDEN_REMOTE_READ_DEADLINE_S": "1"}` because the deadline is a
process-wide static. The cases assert what the shipping code promises and do
not assert the F2 property; `raiden_controller_bughunt_test.cc` does that and
fails on purpose.

**Cut on the re-base (drafted at `c9bc124`, dropped at `42dda542`).** Upstream
`1b78685f` (pre-created per-layer promises, H2H chain armed before the copies
are issued) and the tests landed with it made several cases redundant:
`FailedD2hDispatchOnSecondLayerWaitsForTheFirstCopy` (same schedule as
upstream's `D2hDispatchFailureFailsUnissuedLayersAndDrainsIssuedCopies`),
`CopyAlreadyFailedAtDispatchFailsTheSend` (the `d2hEnd`-before-`wake` branch
no longer exists: the chain is registered on the promise, not on the
dispatch's future), `FailedPushFailsTheSend` and
`ExpiredSendWhoseCopyThenFailsSettlesOnce` (already pinned by
`DetailsSayAFailedPushFailedInPushWhileCopiesRun` /
`ExpiredSendKeepsItsStagingUntilTheCopyEnds`),
`DrainWithLastCopyCompletingBeforeTheFirstPush` (the swapped order exercises no
branch `DoneGuaranteesAllResourcesReleased…` does not), and the three
receive-under-lease variants (the lease arithmetic is already
`IncomingPushLeasePinsStagingDuringWriteAndRejectsWhenDraining`).

**Promoted to F14 (2026-10-30), not a coverage-gap test: the receiver's late-`Finish` status flip.**
`LateErrorAfterSettledOkIsReportedAsFailed` (in the `c9bc124` draft; passed
there) drove a receive to settle OK (`FinishCopy(0, OkStatus)` → done, staging
released, data on device) and then called `Finish(CancelledError)`: the poll
reported the receive in `failed_recving`. Rather than pinning the flip in a
coverage test, **F14** (`transfer_receive_late_finish_bughunt_test.cc`, above)
drives four candidate paths across `TransferReceiveSession`
and `ReshardReceiveSession` on unmodified `42dda542` (one of them, the late pull
reply, is reachable in production; §F14).

Runs: 18/18 at `c9bc124` (2026-10-28, OSS Bazel recipe in the fork notes) and
9/9 at `42dda542` the same day, with the full `transfer_send_session_test`
(19 cases) and `kv_cache_manager_with_transfer_send_drain_test` (42 cases)
binaries green around them; `--runs_per_test=10` on the two kv_cache targets
also green. A failure on a later upstream is either a transcription error
(check against the harness first), a model error (the Lean post-state
disagrees with the C++ — a finding for `tpu_sync/formal_verification/`), or a
defect.

### Reshard control-plane coverage-gap tests (`coverage_gap_reshard_control.patch`, at `42dda542`, run 2026-10-30: 7/7 pass; **retired 2026-11-09** after upstream `5835b975` landed all 7 cases)

Appended 7 `TEST_F(ReshardStackTest, ...)` cases to
`tpu_sync/kv_cache/reshard/reshard_service_test.cc` covering all 14 `Gap.test`
branches and all 4 unasserted `Refusal` constructors of
`Reshard/Registry/Coverage.lean` plus all 4 gap branches of
`Reshard/Coordinator/Coverage.lean`, without asserting F8 on sender-dispatch
failure:

| Case | Branch / refusal (`Registry` / `Coordinator` Lean table) | What it pins |
|---|---|---|
| `ReshardStackTest.DuplicateRegistrationRefreshesTtlWhileConflictsAndPostClaimWritesFail` | `Registry` `registerRefresh`, `Refusal.registerConflict`, `Refusal.registerLifecycle` (claimed) | idempotent re-registration refreshes `expires_at` (`now_` advance past initial TTL); mismatched block payload and post-claim writes fail closed without clobbering the live entry |
| `ReshardStackTest.IncompatibleClaimUnitSetAndNonOwnerAbandonPreserveClaim` | `Registry` `Refusal.claimIncompatible`, `Refusal.abandonNotOwner` | a claim for a mismatched source unit set fails while leaving `STATUS_CLAIMED`; `AbandonClaim` by a non-owner is ignored |
| `ReshardStackTest.CompletionNoOpsAndPreClaimGuard` | `Registry` `Refusal.completeBeforeClaim`, `completeNoOp` (`unknown` incl. post-retire, `registered`, `claimed`, `cancelled`), `cancelAlready` | non-empty pre-claim `Complete` fails; unregistered / unclaimed sibling-unit, unknown, post-retire, and cancelled `Complete` calls and duplicate `CancelIfUnclaimed` are safe no-ops |
| `ReshardStackTest.EmptyRegistrationCompletesBeforeClaimAndRetiresOnClaim` | `Registry` `completeVoteUnclaimed`, `claimRetiresVoted` | a rank with zero `block_ids` may vote `Complete` before `LookupAndClaim`, and claiming when every unit has already voted retires `request_blocks_` immediately |
| `ReshardStackTest.ForcedReleaseClearsEveryLifecycleState` | `Registry` `release` (all 6 reachable `status` × `retired` combinations) + `force=false` rejection | `COMMAND_RELEASE_REQUEST_BLOCKS` rejects `force=false` and clears `unknown` (unretired and post-retire), `registered`, `claimed`, and `cancelled` (unretired and post-retire) back to `STATUS_UNKNOWN` |
| `ReshardStackTest.TwoDestinationsSecondArmFailureAbandonsClaimAndSkipsSenders` | `Coordinator` `armFail`, `armBarrierAbort` (with `armedLeft = true`) | holding dst 1 until dst 0 has armed and then failing dst 1's `COMMAND_START_TRANSFER` aborts at the arm barrier with dst 0 armed, abandons the registry claim, and dispatches zero senders |
| `ReshardStackTest.SenderDispatchFailurePropagatesErrorAfterReceiverArm` | `Coordinator` `sendFail`, `sendBarrierAbort` | with two source ranks, rank 0 failing sender `COMMAND_START_TRANSFER` and rank 1 succeeding propagates failure from `COMMAND_COORDINATE_TRANSFER` after arming the receiver (asserts error propagation without pinning F8's missing `AbandonClaim`) |

Runs: full `//tpu_sync/kv_cache/reshard:reshard_service_test` target green at
`42dda542` with `--runs_per_test=5` (2026-10-30); `git apply --check` also clean
against `337540eb`. Retired 2026-11-09: upstream `5835b975` landed all 7 cases
in `tpu_sync/kv_cache/reshard/reshard_service_test.cc:2405-2703` (naming case 6
`TwoDestinationsOneArmRefusalAbandonsClaimAndSkipsSenders`), leaving
`Reshard/Registry/Coverage.lean` (`25/25`, all 7 refusals) and
`Reshard/Coordinator/Coverage.lean` (`14/14`) with zero gaps.

### Reshard session and loopback-pipeline coverage-gap tests (`coverage_gap_reshard_sessions.patch`, at `42dda542`, run 2026-10-30: 12/12 pass)

Extends `tpu_sync/kv_cache/reshard_send_session_test.cc` (4 `ReshardSendSessionTest`
cases) and `tpu_sync/kv_cache/kv_cache_manager_with_transfer_pool_reshard_test.cc`
(4 `PoolReshardRecvTest` + 4 `PoolReshardSendTest` cases) to close every
non-**F14** `Gap.test` branch of `Reshard/Receive/Coverage.lean` (18 of 21) and
`Reshard/Send/Coverage.lean` (15 of 16) plus the end-to-end CPU loopback
`Reshard/Pipeline` trace (`trace_arm_before_dispatch`), using
`DeviceBackedTestBase`'s null `RaidenBufferHandle` (on which `raiden::IssueD2hShard`
and `IssueH2dShard` run a synchronous no-op `PjRtCopyFuture` on CPU) without
production code changes. Excluded intentionally: the 3 `Reshard/Receive`
(`cancel` errors, `pushEndFail` settles+errors, `pushEndFail` errors) and 1
`Reshard/Send` (`cancel` errors) **F14** late-`Finish` status flips (covered as
failing bug-hunt tests in `transfer_receive_late_finish_bughunt_test.cc`), and
mid-flight `HasActivePlan` on a first failed push (**F10**):

| Case | Branch (`Reshard/Receive`, `Reshard/Send`, `Reshard/Pipeline` Lean table) | What it pins |
|---|---|---|
| `ReshardSendSessionTest.SingleFailedPushSettlesUnregistersPlanAndPropagatesError` | `Send` `pushDoneFail` drains settles errors | a single failed push settles the send at once, unregisters the active plan, and propagates the error status |
| `ReshardSendSessionTest.FirstFailedPushWaitsForInFlightSiblingBeforeSettling` | `Send` `pushDoneFail` drains errors, `pushDoneFinalizing` settles | the first failed push enters draining/finalizing while a sibling push remains in flight (asserts drain + error preservation without pinning F10's early plan unregister) |
| `ReshardSendSessionTest.MultiPeerPushAndCallerHeldOpKeepSessionLiveUntilFinalOp` | `Send` `pushDoneMore` (no effect), `pushDoneLast` drains (caller op held) | on a 2-peer plan, peer 0's completion keeps the pool live until peer 1's completion settles it; on a single-peer plan with `ExecutePush`'s caller op still held, the peer's completion marks the session draining without settling until `EndOp` settles it OK |
| `ReshardSendSessionTest.DuplicateCancelAndNonFinalPushCompletionKeepSessionDraining` | `Send` `cancel` (no effect), `pushDoneFinalizing` (no effect) | a second `Finish(error)` on a draining send preserves the first error, and the first of two in-flight push completions on a finalizing send keeps it draining until the second ends |
| `PoolReshardRecvTest.OnPoolReceivedUploadsSinglePoolAndWaitsForOpenPushLease` | `Receive` `pushEndOk` (no effect; settles), `poolReceivedLaunches`, `h2dIssueOk`, `h2dReady`, `h2dDoneLast` (drains; drains settles) | an empty push stream closes without settling; `OnPoolReceived` under an open push lease runs synchronous H2D and marks the receive draining while keeping staging pinned until `EndIncomingPush(OK)`; with no open lease, `OnPoolReceived` uploads and settles immediately |
| `PoolReshardRecvTest.RankWaveGatesHigherRankPoolAndChainsWhileBatchWaitsForPeers` | `Receive` `poolReceivedGated`, `h2dDoneChains`, `h2dDoneMore` (no effect) | on ranks `[0, 1]`, pool 1 arriving first is held back until pool 0's upload chains pool 1; on ranks `[0, 0]`, pool 0 uploads without settling until pool 1 arrives |
| `PoolReshardRecvTest.ConcurrentPushesAndUnregisterDrainBeforeSettling` | `Receive` `cancel` (drains errors; no effect), `poolReceivedQuiesced`, `pushEndFail` (no effect; settles; drains errors) | two open push streams across `UnregisterActivePlan` (plus duplicate unregister and `OnPoolReceived` while draining) keep staging pinned until the second stream ends; a failed first stream with a second open drains without settling until `EndIncomingPush(OK)` |
| `PoolReshardRecvTest.FailedH2dPoolBlocksFailsReceiveAndWaitsForOpenPushLease` | `Receive` `h2dIssueFail` (drains settles errors; drains errors) | `device_size = 0` fails `H2dPoolBlocks` (`OUT_OF_RANGE`), settling immediately with no open push lease and waiting for `EndIncomingPush` when a push lease is open |
| `PoolReshardSendTest.LoopbackPushUploadsReceiverPoolAndPublishesBothSides` | `Send` `d2hIssueOk`, `d2hDoneStartsPushes`, `publish`; `Receive` `publish`; `Pipeline` `trace_arm_before_dispatch` | full loopback `PoolReshardRegisterRecv` + `PoolReshardPush` copies bytes from sender host mirror into receiver bounded staging, uploads, settles, releases staging, and publishes `sent` and `received` |
| `PoolReshardSendTest.ExecutePushReturnsWhilePeerPushRemainsInFlight` | `Send` `execFinish` (no effect) | `PoolReshardPush` returns while a TCP push to a held peer socket is still in flight (`has_pool_send == true`), then settles and reports failure once the peer closes |
| `PoolReshardSendTest.SynchronousD2hFailureSettlesOrDrainsInFlightPoolPush` | `Send` `d2hIssueFail` (drains settles errors; drains errors) | `device_size = 0` fails `PoolReshardPush` synchronously (`OUT_OF_RANGE`), settling at once on 1 pool and draining until pool 0's in-flight TCP push ends on a 2-pool plan |
| `PoolReshardSendTest.FinalizingSessionDuringExecutePushSettlesOrDrainsRemainingOps` | `Send` `execFinish` settles, `d2hIssueFailFinalizing` (settles; no effect) | a synchronous `BuildBlockRequests` failure inside `StartPoolPush` marks the session finalizing while `ExecutePush` still holds its caller op, settling at `ExecutePush`'s `EndOp` on 1 pool, absorbing pool 1's synchronous `D2hPoolBlocks` failure on 2 pools (preserving pool 0's `NOT_FOUND`), and keeping staging pinned when a sibling TCP push is still open |

Runs: full `//tpu_sync/kv_cache:reshard_send_session_test` (13 cases) and
`//tpu_sync/kv_cache:kv_cache_manager_with_transfer_pool_reshard_test` (32 cases)
green at `42dda542` with `--runs_per_test=6` (2026-10-30).

### Consumer control-handshake coverage-gap tests (`coverage_gap_control_handshake.patch`, at `42dda542`, run 2026-10-30: 2/2 pass)

Extends `tpu_sync/kv_cache/kv_cache_manager_with_transfer_control_test.cc`
(`SilentProducer::AcceptClient` + a `NumaThreadPool` barrier) with 2
`ControlHandshakeTest` cases closing both `Gap.test (stub)` branches of
`PrefillDecode/Receive/Coverage.lean`:

| Case | Branch (`PrefillDecode/Receive` Lean table) | What it pins |
|---|---|---|
| `ControlHandshakeTest.AcceptedPullAdvancesReceivePhaseAndReleasesHandshakeOp` | `Receive` `pullReplyOk` (no effect) | an `OK` pull reply clears `handshake_pending_` and releases the handshake's `in_flight_` op while keeping staging pinned; a subsequent `FailRecv` settles immediately in phase `receive` rather than staying draining in `connect` |
| `ControlHandshakeTest.AcceptedPullAfterDeadlineSweepSettlesExpiredReceive` | `Receive` `pullReplyOk` settles | when the deadline sweep marks a connecting receive draining in phase `connect` and the producer subsequently answers `OK`, `on_response` releases the last op and settles the receive with its original `DEADLINE_EXCEEDED` / `connect` details |

Runs: full `//tpu_sync/kv_cache:kv_cache_manager_with_transfer_control_test`
green at `42dda542` with `--runs_per_test=6` (2026-10-30); `git apply --check`
also clean against `337540eb`.

### Multi-request buffer-recycling coverage-gap tests (`coverage_gap_multi_request_recycle.patch`, at `42dda542`, run 2026-10-30: 2/2 pass)

Adds 2 `MultiRequestTest` cases to
`tpu_sync/kv_cache/kv_cache_manager_with_transfer_send_drain_test.cc` closing
both live multi-request branches of `PrefillDecode/MultiRequestCoverage.lean`
(`nextRequest` and `recyclePrefill`) and all 3 `Pipeline/Coverage.lean`
environment branches (`reclaim`, `reseatPrefillStaging`, `reseatDecodeStaging`)
over real loopback control + `BlockTransport` with simulated HBM and
promise-controlled D2H / H2D copies:

| Case | Branch (`MultiRequest` / `Pipeline` Lean table) | What it pins |
|---|---|---|
| `MultiRequestTest.HandedOffCancelledTransferRecyclesBothStagingSlotsForNextRequest` | `Multi.Leaf.nextRequest` (`tr_multi_request`) + `Pipeline.Leaf.{reclaim, reseatPrefillStaging, reseatDecodeStaging}` | cancelling request 0 during D2H keeps the producer's single staging slot pinned until D2H finishes; after both sides publish failure (`HandedOff`), request 1 reclaims prefill HBM (`0xAA` → `0xBB`), reuses and overwrites the single staging slot on both sides, and delivers `0xBB` to decode HBM without touching request 0's decode block |
| `MultiRequestTest.PrefillRecyclesAndOverwritesStagingWhileEarlierConsumerH2dStillRuns` | `Multi.Leaf.recyclePrefill` (`tr_overlapped_requests`) + post-handoff consumer staging recycle | once request 0 publishes `sent` on the producer (`PrefillReleased`) while request 0's consumer H2D is still paused, request 1 recycles and overwrites prefill HBM and the producer's single staging slot with `0xBB` without corrupting request 0's pending consumer H2D (`0xAA`); after request 0 finishes and publishes `received`, request 2 reuses and overwrites request 0's released consumer staging slot (`0xCC`) while request 0's decode HBM retains `0xAA` |

Runs: full `//tpu_sync/kv_cache:kv_cache_manager_with_transfer_send_drain_test`
green at `42dda542` with `--runs_per_test=6` both standalone and stacked with
`coverage_gap_recv.patch` (2026-10-30).

## Observations on the prefill-to-decode path (non-bugs at `2ed6f8f`)

Behaviours that looked like defects during the prefill-to-decode model work and
turned out to be intended, dead, or proved unreachable. Kept here so they are not
re-investigated; the Lean names in the last column are the proofs. Short names
as in the Lean preambles: `recv.cc` = `tpu_sync/kv_cache/transfer_receive_session.cc`,
`send.cc` = `tpu_sync/kv_cache/transfer_send_session.cc`,
`mgr.cc` = `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`,
`bt.cc` = `tpu_sync/transport/block_transport.cc`.

| Observation | Where (`2ed6f8f`) | Note |
|---|---|---|
| client-side `SendAck` has no non-test caller; the server-side `OnAck → HandleAck → AckSend → Finish()` handler is wired but never triggered in-repo | `grpc_control_plane_backend.cc:373`, `tcp_control_plane_backend.cc:662`; `mgr.cc:1187-1189, 1364-1367, 1430-1441` | dead path; excluded (`Send` A5) |
| a failed **send** is reported in `failed_recving_` | `mgr.cc:975-976` | naming/semantics quirk visible through `poll_stats()`; since `4246613` (2026-08-24) this also covers a send nobody pulled, and the tpu-inference connector drops the list — the contributing cause of **C1**'s producer half (see the "tpu-sync side" subsection under C1; judged an improvement request, not a defect) |
| first `Finish` wins on the send side; a later cancel is ignored | `send.cc:193-206` | intended; `trace_cancel_after_ok_finish` |
| `IsReadyToComplete` can be true before all H2D callbacks ran | `recv.cc:450-456` | `done` still waits for every callback through `in_flight_` (`pollReady_no_settle`), so the outcome and its timing are unchanged. But when the poll wins that window the last callback finds `draining_` and skips `RecordTransferDuration`/`RecordH2dComplete`/`RecordEnd` (`recv.cc:726-732, 746-756`) — the transfer's metrics record keeps default times (`trace_poll_skips_metrics`). With `num_layers() > 0` the `num_completed_layers_ == total_layers` disjunct and the `if (all_complete)` finish in `OnBlockShardsReceived` (`RecordNetworkCompleteLocked`) are dead (`reachable_callbackFinishes`, `netAccount_frame`); only a zero-layer receive needs the poll (`noPoll_zero_layers_never_succeeds`). Removing the poll (design alternative `stepM false` in `ReceivePoll.lean`) keeps every proved property and settlement (`noPoll_safe`, `noPoll_can_settle`) and makes `published = some true → metrics` an invariant (`noPoll_metrics_on_success`). |
| `EndSendOpLocked` has no underflow guard, `EndRecvOpLocked` does | `send.cc:253-260` vs `recv.cc:407-410` | underflow proved unreachable (`NoUnderflow`) |
| `LOG(DFATAL) "H2D callback for retired receive"` is unreachable | `recv.cc:718-720` | proved (`NoRetiredCallback`) |
| `done_` is redundant in six lifecycle guards | `recv.cc:365, 412, 605, 649, 675`, `recv.h:119` (send side: `send.cc:195, 255, 326, 340, 391`) | `done → draining` and `done → in_flight_ == 0` are `Lifecycle.Consistent`, which every model keeps in its invariant (`Inv.life`); the guards without `done_` are the same functions on consistent states (`finishLocked'_eq`, `endOpLocked'_eq`, `beginOp'_eq`, `Consistent.done_or_draining`). Defensive code, not a bug. The two `LOG(DFATAL)` branches (`recv.cc:407-410`, `718-720`) are assertions — unreachable by `Accounted` / `NoRetiredCallback` — and stay. `Session.lean` |
| a failed incoming push reaches the session as a flat `InternalError("Incoming push failed")` | `bt.cc:510-517` → `mgr.cc:267-270` | the actual cause (read timeout, size mismatch, `OnLayerReceived` error) is only in the transport log, so `failed_recving` cannot tell them apart. Observability, not correctness; the model does not distinguish error statuses. |
| `TransferSendSession::EndSendOp` drops `mu_` inside the last op of a draining send under `TPU_RAIDEN_DATA_CONN_REUSE=per_transfer` | `send.cc:262-289` (window `:284-287`) | closes idle data connections before `EndSendOpLocked`; `in_flight_ == 1`, `draining_`, `!done_` are fixed across the window (no new op, `FinishLocked` returns early, the poll sees `Done() == false`), so the model's atomic `endOp` is exact and only `done_` is delayed. Default `pooled` never enters the branch. `Send.lean` A7. |
| the chunk-count completion contract has no over-count rejection; retirement erases the `OnLayerReceived` once-latch while the receive is live | `bt.cc:740-742` vs `:705-709, 733-737`; `:765-779`; `recv.cc:642-700` | sound for honest senders (`Transport.reachable_safe`); what one extra stream does, the two unproved assumptions (plan-publication window `mgr.cc:573-604`, `remote_id` vs `shard_push_schedules` identity) and a candidate hardening are under R-B above. `Transport.lean` |

---

## Fix validation (2026-09-24, on `b68161a`)

`candidate_fixes.patch` was applied to a scratch clone, the tests run, and the
clone reset. Results, verbatim:

```
[F2] pulls issued at settle: 0, pulls issued 4s later: 0
[F4] locked host blocks before: 0, after 3 failed TransferBuffers: 0
//tpu_sync/core/controller:raiden_controller_bughunt_test   PASSED
//tpu_sync/core/controller:raiden_controller_test           PASSED   (59 existing tests, no regressions)
//tpu_sync/kv_cache:kv_cache_store_pin_race_test            PASSED
```

- **F1 fix** (hunk dropped 2026-10-22, upstream `b3ea4dc` is an equivalent
  change): with it, the eviction inside the window is refused because
  `h0` is pinned. For this run the test hook was changed to "skip the
  reinsert if the eviction is refused"; it still fails on the unfixed code,
  where the eviction succeeds.
- **F2 fix:** the naive fix only; closes shape A, not shape B.
- **F4 fix** (hunk dropped 2026-10-10, upstream `72255dd`): every error
  return frees the auto-allocated staging, after joining any
  already-dispatched worker futures.
- `kv_cache_store_test` was not run (`no_oss`, needs a gRPC registry
  environment).

## History

- 2026-09-24: found and confirmed on `b68161a`; re-run on `d16701e` (F1, F2,
  F4 still fail; `raiden_controller.cc` unchanged; F1 test adapted to the
  `Evict(hashes, evicted_hashes*)` signature from `e767161`).
- 2026-10-01: ported into `tpu_sync/formal_verification/`; citations re-checked against
  `01ffa3d` by reading (cited `raiden_controller.cc` regions identical;
  `kv_cache_store.cc` lines moved by −15); both patches re-based and apply
  cleanly. Tests not re-run.
- 2026-10-06: upstream `50b0774` merged into `experimental` (`77eeec8`).
  Re-checked by diff: `raiden_controller.cc` byte-identical to `01ffa3d`
  (F2, F3, F4 numbers hold); the F1 regions of `kv_cache_store.cc`
  (`ValidateAndPinHostBlocks`, `Evict`/`Insert`) unchanged, lines moved by
  +11 (1655–1683 at `01ffa3d` → `kv_cache_store.cc:1666-1694`); F4 fix PR #1105 still open, not merged.
  No finding fixed. Line numbers in this file and in `filed_bugs.md`
  re-pinned to `50b0774`; both patches still apply cleanly.
- 2026-10-07: F5 added. Confirmed on `50b0774` by running the owners' parked
  `DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`; fix written, tested
  and shipped as `per_peer_staging_admission.patch` (output above). Upstream
  `main` checked at `ebcc7af` (three commits past `50b0774`: `93e09ee`,
  `a29649c`, `ebcc7af`): none touches `StartRead` admission or the
  allocator, the test is still `DISABLED_`, and no issue or PR proposes a
  per-peer cap.
- 2026-10-10: upstream `1fa06d1` (38 commits past `50b0774`). **F4 fixed
  upstream** by `72255dd` (2026-10-07; PR #1105 merged via copybara, three new tests);
  its hunk dropped from `candidate_fixes.patch`. F1, F2, F3, F5 unchanged
  (`kv_cache_store.cc` F1 regions moved +6 since `50b0774`; `ReadRemote` region of
  `raiden_controller.cc` moved +35, byte-identical; `StartRead` admission and
  the allocator untouched, `DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`
  still disabled). Sessions and manager moved to `tpu_sync/kv_cache/`
  (`5afe1ef`); `per_peer_staging_admission.patch` re-based onto the new paths,
  all three patches apply cleanly. Tests not re-run.
- 2026-10-13: F6 added (pool-reshard receiver: a rejected duplicate
  `PoolReshardRegisterRecv` destroys a session whose destructor releases the
  active session's `uuid`-keyed staging lease), read-confirmed at `1fa06d1`
  and reproduced by the reporter; filed upstream, fix with regression tests
  to follow. Upstream `main` checked 10 commits past `1fa06d1`: no fix yet;
  `fc8cff9` moves `StagingBlockAllocator` to `tpu_sync/core/staging_arena.h`
  (re-pin note for the next sync).
- 2026-10-16: upstream `0ac16d1` (48 commits past `1fa06d1`). **F6 fixed
  upstream** by `8653373` (2026-10-13, three regression tests). F1, F2, F3
  unchanged (`raiden_controller.cc` and the `kv_cache_store.cc` F1 regions
  untouched). F5 still open (`DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`
  at `control_test.cc:1103-1151`, still disabled); `StagingBlockAllocator`
  moved to `tpu_sync/core/staging_arena.{h,cc}` (`fc8cff9`), so
  `per_peer_staging_admission.patch` no longer applies and was retired rather
  than re-based (decision: keep the proof and the write-up). `NotifyForRead`
  now throws on an invalid registration instead of returning 0 (`80e2c52`);
  `TransferDetails` reports the failed phase (`5a73483`). Two patches remain
  and apply cleanly. Tests not re-run.
- 2026-10-19: F7 added (pool-reshard receiver: the `end_incoming_push` hook
  does not `Finish(status)` a `ReshardReceiveSession` on a failed push, so
  staging lease and plan claim stay pinned until the deadline sweep; R1 of
  `tpu_sync/formal_verification/docs/transfer/reshard.md`). Filed upstream 2026-10-16 and **fixed upstream**
  by `fdeebcd` (2026-10-16, one regression test). Upstream `main` is at
  `2a97685` (5 commits past `0ac16d1`); not yet merged into the fork, so
  line numbers in this file stay pinned to `0ac16d1`. Separately, four
  hardware-free reproducers for the reshard registry/coordinator candidates
  R7a, R7b, R8 and R2b were written and pass (`reshard_bughunt_test.cc`,
  target in `build_targets.patch`); they remain tracked in `reshard.md` until
  filed.
- 2026-10-19 (later): **F1 filed upstream** (write-up as bug 4 in
  `filed_bugs.md`, pinned to `0ac16d1`); `ValidateAndPinHostBlocks` region
  verified unchanged at `0ac16d1` (`kv_cache_store.cc:1615-1642`). Fix pending.
- 2026-10-19 (later): **F8 filed upstream** (R2b: `ExecutePoolReshard`
  sender-dispatch return omits `AbandonClaim`; write-up as bug 5 in
  `filed_bugs.md`, pinned to `0ac16d1`; reproducer
  `ReshardBughuntTest.R2b_…` in `reshard_bughunt_test.cc`). Fix pending.
- 2026-10-19 (later): **F9 filed upstream** (R8: `LookupAndClaim` refreshes
  the claim TTL but not the claimed `request_blocks_` rows; write-up as bug 6
  in `filed_bugs.md`, pinned to `0ac16d1`; reproducer `ReshardBughuntTest.R8_…`).
  Fix pending. Remaining unfiled reshard candidates with reproducers: R7b, R7a.
- 2026-10-20: **F2 shape B confirmed by a C++ test**
  (`BugHuntTest.ReadRemoteSettlesDeadlineWhilePullStillInFlight`, added to
  `raiden_controller_bughunt_test.cc`; a `SlowReadMock` makes the worker's
  read outlive the 1 s deadline). Both F2 tests run against upstream `main`
  `449b591` (2026-10-20; 15 commits past `0ac16d1`): controller sources
  (`raiden_controller.cc`, `controller_service.cc`, `worker_service_impl.cc`,
  …, `logical_block_manager.cc`) compiled from `449b591`, everything else
  linked from the `0ac16d1` OSS build. `ReadRemote` / `PullAndRelease` are
  byte-identical between `0ac16d1` and `449b591` (the only controller change
  is a `num_free_blocks()` accessor, `9ac3d3e`). F1, F3 regions also
  unchanged at `449b591`.
- 2026-10-20 (later): **F10 added** (R6: `ReshardSendSession::RecordPushCompletion`
  unregisters the plan on the first failed push while siblings are in flight;
  a same-uuid retry then shares, and loses, the uuid-keyed staging lease — the
  F6 shape on the sender). Confirmed by
  `reshard_send_session_bughunt_test.cc` using upstream's
  `ReshardSendSessionTestPeer` seam, against the `1fa06d1` warm build (the
  only OSS outputs on this machine; the involved code is unchanged through
  `449b591`). Correction to the 2026-10-20 F2 entry above: the "leaf
  libraries" used for the F2 run are from that same `1fa06d1` build, not
  `0ac16d1`; the controller sources were compiled from `449b591` as stated.
  Not yet filed.
- 2026-10-20 (later): callers recorded and re-read at head —
  `vllm-torchtpu` `9725110`, `sglang-torchtpu` `9a6eef1` (§Callers). Result:
  F8 reached by every post-arm sender failure in both engines; F9 reached
  only by late pipeline-stage claims and then mistaken for the benign pre-arm
  retry; F10's lease-aliasing half, R7a and R7b need a same-uuid
  re-coordination or a rank fanning out to several stages, which neither
  engine does. F10's summary-row reachability updated accordingly.
- 2026-10-20 (later): **F2 + F3 filed upstream** as one report (write-up as
  bug 7 in `filed_bugs.md`, pinned to `449b591` — the commit the shape A/B
  tests ran against; `ReadRemote` unchanged since `0ac16d1`). Fix pending.
  Filed tally: F1, F2+F3, F4 (fixed), F6 (fixed), F7 (fixed), F8, F9.
- 2026-10-20 — Opened the prefill-to-decode caller for the first time:
  tpu-inference `tpu_raiden_connector.py` @ `7ed46a6` (the examples' pin; same
  at `main` `c2b062b`) on vLLM `6185d73`. Result: `Pipeline` A4 holds for the
  pair by reading; **C1** recorded (failed/never-pulled transfers leak KV
  blocks on P and D; `failed_recving` dropped by the connector, `SendMeta.
  expiration_time` dead). Dated both halves: D half since the connector's
  first commit `a342edc3` (2026-06-08); P half since tpu-sync `4246613`
  (2026-08-24) reclassified a never-pulled send from `done_sending_` to
  `failed_recving_` — first recorded as F11, then downgraded the same day to a
  contributing cause / improvement request under C1 (not a problem without
  C1). §Callers gains the third caller.
  Then confirmed C1 by test on CPU (`tpu_inference_connector_c1_test.py`,
  9/9 with controls; real vLLM scheduler, real connector, tpu-sync's report
  as its own `SendNobodyPulledFailsAtItsDeadline` shows it). Neither filed yet.
- 2026-10-22: **C1 filed** against the caller (tpu-inference), write-up as
  bug 8 in `filed_bugs.md` (pinned to tpu-inference `c2b062b`, vLLM
  `5ab4e44` — the version the filed lines were read against — and tpu-sync
  `0ac16d1`). The tpu-sync side stays an improvement request, not yet
  raised. Filed tally: F1, F2+F3, F4 (fixed), F6 (fixed), F7 (fixed), F8,
  F9, C1.
- 2026-10-22 (later): upstream `2ed6f8f` merged (32 commits past `0ac16d1`).
  **F1 FIXED upstream** by `b3ea4dc` (2026-10-21): `ValidateAndPinHostBlocks`
  now does one `Lookup(..., pin_found = true)` and releases partial pins on
  its error paths — the change `candidate_fixes.patch` carried, whose hunk is
  dropped; the patch is now F2 shape A only (re-based, applies at `2ed6f8f`).
  `fdeebcd` (F7's fix) is now in the tree; `Reshard/Receive.lean` takes
  `PushEndPolicy.finishOnError` as its default and keeps the old hook as
  `.endOpOnly` for the R1 witness. Other changes in cited code are
  line-shifts only (`9ac3d3e` in `raiden_controller.cc`, `TransferOp` enum
  and Peregrine includes in `block_transport.cc`, `LookupOptions` refactor in
  `host_offload_backend.cc` / `kv_cache_store_service.cc`). F5's test is still
  `DISABLED_`. Citations re-pinned to `2ed6f8f`. Filed tally: F1 (fixed),
  F2+F3, F4 (fixed), F6 (fixed), F7 (fixed), F8, F9, C1.
- 2026-10-23: **F10 (R6) filed upstream** (write-up as bug 9 in
  `filed_bugs.md`, pinned to `2ed6f8f`). Filed tally: F1 (fixed), F2+F3, F4
  (fixed), F6 (fixed), F7 (fixed), F8, F9, F10, C1.
- 2026-10-23 (later): the Lean corpus (`tpu_sync/formal_verification/`) no
  longer carries finding numbers, filing status, reproducer or patch
  pointers, or fixed-defect history — it describes the code as it is, and this
  file is the only home of that tracking. Consequences for cross-references:
  `reshard.md` and `TpuSyncVerify/Transfer/Reshard/` dropped the `R1`–`R8`
  labels and `trace_r*` prefixes (`trace_failed_incoming_push`,
  `trace_duplicate_uuid_frees_survivor_lease_and_aliases_slot`,
  `trace_partial_arm_orphans_armed_receiver`,
  `trace_dispatch_failure_orphans_receivers_and_claim`,
  `trace_single_stage_votes_retire_multi_owner_claim`,
  `trace_split_ttl_purges_request_blocks_while_claim_active`). The C1
  traces in `Caller.lean` were renamed `trace_c1_*` →
  `trace_current_connector_*`. `read_remote.md` lost its "Reproducers and
  patches" and "Upstream fix" status rows. The sync log moved to
  `notes/upstream-rechecks.md`. Finding bodies above are frozen and still say
  "tracked as R1/R5 in `reshard.md`" as of their confirmation date.
- 2026-10-27: **R-G** added (read, `c9bc124`): the reshard settle sweep in
  `CompleteReadWithDetails` passes generation 0 and releases leases by uuid
  only; closed as an API hazard with the same precondition as R-B and the F10
  aliasing half (same-uuid re-coordination, which no caller does). Not
  modelled in Lean.
- 2026-10-28: upstream `42dda542` merged (40 commits past `c9bc124`, which
  was 21 past `2ed6f8f`). **No finding fixed.** Re-checked every open
  finding by `git diff c9bc1241 42dda542` on its cited files and by reading
  the current code:
  - F2, F3: `raiden_controller.cc` unchanged since `449b591` — still open.
  - F5: `ControlHandshakeTest.DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`
    still `DISABLED_` (`control_test.cc:1103`); `StartRead` →
    `TransferReceiveSession::Create` → `AllocateStagingForLoad` →
    `StagingBlockAllocator::Acquire` still first-come-first-served, on
    `ResourceExhausted` the request still goes to `failed_recving_`;
    `staging_arena.{h,cc}` unchanged; `0b12f51f` only adds a
    `MetricsCollector` argument to `Create` — still open.
  - F8: still open, **code moved** — `09a42d4e` (2026-10-25) split
    `ExecutePoolReshard` into a per-request shell plus
    `ReshardCoordinator::RunSubPlan(ctx, index)`; the sender-status return
    there still omits `AbandonClaim`, and the three abandoning returns are
    now guarded by `index == 0` (a chained sub-plan after the first leaves
    the claim to the dispatched senders' terminals by design, per the header
    comment). Summary row and the F8 status line point at the new symbol.
  - F9: `request_block_registry.cc` unchanged since `0ac16d1` — still open.
  - F10: `reshard_send_session.cc` unchanged since `2ed6f8f` (the header
    gained `sub_plan_index()` / `sub_plan_count()`) — still open.
  - R-B: `42dda542` moved the server push path into
    `BlockTransportServerPushSession` (`block_transport_session.{h,cc}`); the
    chunk-count branch still has no over-count rejection and retirement is
    now per session object — same verdict, note added under R-B.
  - R-G: the settle sweep in `CompleteReadWithDetails` still pushes failed
    sends as `(uuid, 0)` and releases pool staging by uuid — unchanged.
  - "Open / not yet checked": `kv_cache_store_client.cc` unchanged
    (`Fetch` still sets no RPC deadline) — unchanged.
  - **C1: fix open upstream.** tpu-inference
    [PR #3918](https://github.com/vllm-project/tpu-inference/pull/3918)
    (`f366ef52`, 2026-10-27) adds `get_transfer_results()` to
    `TPUConnector` / `TPUConnectorWorker` and forwards `failed_recving` as
    `finished_sending` on P and as `finished_recving` + `failed_recving` on
    D, with four unit tests in `TestTPURaidenConnectorWorker`; unmerged, not
    on tpu-inference `main` `7840339b` (2026-10-28), where
    `tpu_raiden_connector.py`'s history is unchanged. It is an instance of
    `connectorFixed` on vLLM's request-level
    `KVConnectorTransferResults.failed_recving` channel (the LKG moved to it
    in `43768bd50` / `7840339bd`). The legacy JAX-P2P `tpu_connector.py` got
    its own fixes on `main` (#3751 `4325e35a6`, #3839 `58d3883d4`). tpu-sync
    side at `42dda542`: still `(failed ? failed_recving_ : done_sending_)`,
    no `failed_sending`; nearest upstream activity is the unmerged branch
    `yinlin/settled-transfer-failure-reason` (`74376a90`). Summary row, C1
    status / fix-shape paragraphs, the tpu-sync-side subsection, §Callers
    and `filed_bugs.md` bug 8 updated; the frozen line citations are not
    re-pinned.
  - Patches: `build_targets.patch`, `candidate_fixes.patch` and
    `coverage_gap_tests.patch` (re-based on `42dda542` in the fork on
    2026-10-28, 9/9 pass) all pass `git apply --check` at `42dda542`; the
    first two were not regenerated. The four `.cc` reproducers were not
    rebuilt. Filed tally unchanged: F1 (fixed), F2+F3, F4 (fixed), F6
    (fixed), F7 (fixed), F8, F9, F10, C1 (fix open as PR #3918).
- 2026-10-29: **F11 added** (`NumaAwareKVCacheManager::CompleteReadRaw` in
  `tpu_sync/frameworks/jax/kv_cache_manager.cc:639-678`: emits `failed_recving`
  on the first failing sub-manager while sibling sub-managers still have H2D /
  D2H DMAs in flight, and never erases `failed_recving_set_` on failure,
  leaking map entries on every failed/expired transfer and poisoning reused
  `req_id`s). Found while checking `tpu-inference` PR #3918 against
  `Caller.lean` / `Caller/MultiWorker.lean`, and confirmed by
  `numa_kv_cache_manager_bughunt_test.cc` (4/4 cases on unmodified `42dda542`,
  target added to `build_targets.patch` alongside fixing two pre-existing hunk
  line counts in `tpu_sync/kv_cache/BUILD` and `tpu_sync/kv_cache/reshard/BUILD`),
  and **filed upstream** the same day (bug 10 in `filed_bugs.md`). Filed tally:
  F1 (fixed), F2+F3, F4 (fixed), F6 (fixed), F7 (fixed), F8, F9, F10, F11, C1
  (fix open as PR #3918). In `Transfer/Caller`, made the two-channel connector primary
  (`connectorFixed` → `connectorTwoChannel`, `connectorCurrent` →
  `connectorDropFailed`, `trace_current_connector_*` → `trace_dropFailed_*`,
  `trace_fixed_*` → `trace_twoChannel_*`) and modelled `KVOutputAggregator`'s
  latched `_failed_recving_pending` channel directly (`AggChannel.latchedReq` in
  `Caller/MultiWorker.lean`).
- 2026-10-29 (later): **F12 and F13 added and filed** (bugs 11 and 12 in
  `filed_bugs.md`, both pinned to `42dda542`). Both are in the windowed
  pool-reshard sub-plan chains `09a42d4e` (2026-10-25) introduced, which no
  Lean model covers (`reshard.md` §Boundaries names `StartChain` /
  `RecordPoolReshardTerminalLocked` / `SweepSubPlanChainsLocked` as out of
  scope) — found by a read of that boundary after F11, confirmed by
  `pool_reshard_chain_bughunt_test.cc` (10 cases: F12 sender half 2 failing +
  1 control, F12 claim half 1 failing + 2 controls, F13 4 failing; target
  added to `build_targets.patch`). F12: a sender dispatched in only some
  windows never reports `done_sending` and is failed by the sweep after
  `timeout_s_`; a chain failing at window ≥ 1 keeps never-dispatched units in
  the claim until `ttl_s_` (the `index == 0` guard F8's 2026-10-28 note
  describes, meeting `BuildPoolReshardPlan`'s per-window `src_units`). F13: the
  first failing sub-plan is reported while siblings still run and the chain
  keeps arming later windows (pinned by upstream's
  `FirstSubPlanFailureFailsTheRequestOnce`); the swept tombstone lets a late
  sub-plan fail the request a second time. Both gated on a caller passing
  `dst_window_blocks`, which neither `vllm-torchtpu` `9725110` nor
  `sglang-torchtpu` `9a6eef1` does. Filed tally: F1 (fixed), F2+F3, F4
  (fixed), F6 (fixed), F7 (fixed), F8, F9, F10, F11, F12, F13, C1 (fix open as
  PR #3918). Also run but not filed in this pass: reproducers for
  `KVCacheStore` remote-write settlement (`kv_cache_store_remote_write_bughunt_test.cc`),
  `KVCacheStoreClient::Fetch` / `LoadRemoteBlocks` (`kv_cache_store_fetch_bughunt_test.cc`),
  the unsynchronized host `LogicalBlockManager` (`host_block_manager_race_bughunt_test.cc`),
  and a refutation of a `WriteRemoteServerReactor` `StartAck` / `OnCancel`
  contract hazard (`kv_cache_store_service_reactor_bughunt_test.cc`, passes);
  recorded as untriaged files only, write-ups to follow.
- 2026-10-30: **F14 added** (`transfer_receive_late_finish_bughunt_test.cc`,
  1 control passing + 4/4 production paths failing on unmodified `42dda542`;
  target added to `build_targets.patch`): `TransferReceiveSession::FinishLocked`
  and `ReshardReceiveSession::FinishLocked` (plus `ReshardSendSession::Finish`)
  overwrite `status_ = OK` on a late `Finish(error)` after 100% of H2Ds have
  completed OK, flipping `completions.received` to `completions.failed` across
  `hooks.end_incoming_push`, `UnregisterActivePlan`, `ExecutePullRequest`
  `on_response`, and `~KVCacheManagerWithTransfer`. Added
  `coverage_gap_reshard_control.patch` (7 `ReshardStackTest` cases closing all
  14 `Gap.test` branches and 4 unasserted `Refusal`s of
  `Reshard/Registry/Coverage.lean` plus all 4 gap branches of
  `Reshard/Coordinator/Coverage.lean`, 7/7 pass `--runs_per_test=5` on
  `42dda542`), and checked `Transport` A2 & A3 against the in-repo controllers
  (`R-B` above and `Transport.lean` §Assumptions).
- 2026-10-30 (later): **F14 audited and corrected.** Of the four tested paths,
  only the late `ExecutePullRequest` reply is reachable in production (alongside
  a near-deadline check-then-`Finish` window across separate `session->mu_`
  lock scopes in `CompleteReadWithDetails` on `TransferReceiveSession`,
  `ReshardReceiveSession`, and `ReshardSendSession`), and the pull reply lands
  before `done_` (the handshake op), not after; `end_incoming_push` needs a
  duplicate stream, receive-side `UnregisterActivePlan` has no caller in
  tpu-sync or the connector repos, and the destructor's flip is never
  published. Replaced the proposed fix on `TransferReceiveSession` (copy the
  sender's `if (draining_ || done_) return;`), which would publish
  `done_recving` over an H2D that fails after the poll-side `Finish()`, with
  gating `status_ = status` on `!done_ && !all_layers_ok_` (and `!done_ &&
  !network_completed_` on `ReshardReceiveSession`, without skipping
  `draining_ = true`). Also corrected the claim that no OK-draining state has
  incomplete HBM: the poll-side `Finish()` creates one.
- 2026-10-30 (later): **Added remaining coverage-gap test patches**
  (`coverage_gap_reshard_sessions.patch`, `coverage_gap_control_handshake.patch`,
  `coverage_gap_multi_request_recycle.patch`; 16 new test cases total across
  `reshard_send_session_test.cc`,
  `kv_cache_manager_with_transfer_pool_reshard_test.cc`,
  `kv_cache_manager_with_transfer_control_test.cc`, and
  `kv_cache_manager_with_transfer_send_drain_test.cc`, all green 6/6 with
  `--runs_per_test=6` at `42dda542`): closes all 18 non-F14 `Gap.test` branches
  of `Reshard/Receive/Coverage.lean`, all 15 non-F14 `Gap.test` branches of
  `Reshard/Send/Coverage.lean`, the CPU loopback `Reshard/Pipeline` trace
  (`trace_arm_before_dispatch`), both `Gap.test (stub)` branches of
  `PrefillDecode/Receive/Coverage.lean`, both live multi-request branches of
  `PrefillDecode/MultiRequestCoverage.lean`, and all 3 `Pipeline/Coverage.lean`
  environment branches (`reclaim`, `reseatPrefillStaging`,
  `reseatDecodeStaging`).
- 2026-11-02: **Re-checked at upstream `56a0269d`** (merge `4b769582`;
  the upstream commits since `42dda542` are mostly the `TransferSession`
  interface refactor: `Start` / `TryBeginOp` / `EndOp` / `OnDataReceived` /
  `ResolveStagingSlot` / `GetDataReadyFuture` / `plan()`, one `sessions_` map
  with `RetireSettledSessionLocked`, manager hooks reduced to `get_session`,
  `BeginIncomingPush` / `EndIncomingPush` in `block_transport_session.cc`).
  **F11 fixed** by `c0e8e686` (2026-10-29): `NumaAwareKVCacheManager::CompleteReadRaw`
  barrier-waits failed transfers with `failed_recving_counts_` and a
  `process_completion` lambda that erases all four maps, with five rewritten or
  new `KVCacheManagerWrapperTest` cases; the Lean `NumaPolicy.settledCounts`
  design alternative is now the shipping code and `eagerFailSet` the mutant.
  **F10 fixed** by `1523b07d` (2026-10-30): the plan lives in the session
  (`plan()` until `Done()`), no `UnregisterActivePlan` in
  `RecordPushCompletion` / `EndOp`, `Create` no longer leases, and
  `PoolReshardPush` refuses a same-uuid retry while the prior session is live.
  **F14 half-fixed**: the same commit moved `ReshardSendSession::Finish`'s
  `if (done_ || finalizing_) return;` ahead of the status record (pinned by
  `FinishAfterLastPushFinalizingPreservesOkStatus`); both receivers'
  `FinishLocked` unchanged, still open, reproducer entry points renamed.
  **Still open:** F2 / F3 (`raiden_controller.cc` unchanged), F5
  (`DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer` still disabled), F8
  (`RunSubPlan` `if (index == 0)` unchanged), F9 (`request_block_registry.cc`
  unchanged), F12 / F13 (planner, `RunSubPlan`, `NoteSubPlanRegisteredLocked`
  and `RecordPoolReshardTerminalLocked` unchanged; `SweepSubPlanChainsLocked`
  now checks liveness as `sessions_.contains(uuid)` over the chain's
  `plan_uuids`), C1 (external, PR #3918 status not re-read). Patches: five
  still apply (`build_targets`, `candidate_fixes`, `coverage_gap_send`,
  `coverage_gap_read_remote_deadline`, `coverage_gap_reshard_control`), five
  do not (`coverage_gap_recv`, `coverage_gap_tests`,
  `coverage_gap_reshard_sessions`, `coverage_gap_control_handshake`,
  `coverage_gap_multi_request_recycle`; hunks listed under §Files); nothing
  re-based or re-run. Upstream also added its own sender failure-path and
  pull-handshake tests (`337540eb`, `1523b07d`, `10d181f6`, `f5001fac`) that
  overlap `coverage_gap_reshard_sessions.patch` and
  `coverage_gap_control_handshake.patch`.
- 2026-11-02 (later): **F15 added** (`reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc`,
  1 control passing + 1 case failing on unmodified `56a0269d`; target added to
  `build_targets.patch`): `ReshardReceiveSession`'s per-pool host staging slot
  (`951b49be`) composed with the plan-wide `order_rank` H2D gate deadlocks a
  multi-tag plan whose rank-1 pools' bytes arrive before every rank-0 pool has
  a slot; the rank-0 push thread sits in `StagingLayerManager::Acquire` until
  `deadline_` and the receive fails `DEADLINE_EXCEEDED`. Found by reading the
  boundary while scoping bounded staging out of the reshard Lean models. Also
  noted: `KVCacheManagerBase::CopyPoolBlocks` now dereferences the placeholder
  device hold (`GetOnDeviceSizeInBytes()`), so the CPU pool-H2D seam the
  `coverage_gap_reshard_sessions.patch` rank-wave tests used segfaults at
  `56a0269d`. Filed tally unchanged (F15 not yet filed).
- 2026-11-02 (later): **F15 audited and filed** (bug 13 in `filed_bugs.md`).
  Audit corrected the reachability argument: a staging slot is keyed by pool
  index and shared by every sender, so a slow sender's rank-0 bytes reuse the
  slot a faster sender's chunk already leased; the cycle needs every slot held
  by a gated rank-1 pool while some rank-0 pool has received nothing from any
  sender, reached through concurrent per-pool pushes overtaking on the wire and
  the rank-blind `StagingLayerManager::Acquire` hand-off. Recommended fix moved
  to rank-ordered leasing; in-place staging on a full mirror flagged as unsafe
  (pools of different tags may share storage bytes). Filed tally 13.
- 2026-11-03: **F16, F17, R-G re-read and R-H added** from the `56a0269d`
  full-repo model-to-code audit (`kv_transfer_uuid_and_reshard_push_bughunt_test.cc`,
  2 controls passing + 4 cases failing on unmodified `56a0269d`; target added
  to `build_targets.patch`):
  - **F16** (`UuidRetirementBughunt`, 1 control + 3 failing cases): inline
    settled-session retirement in `StartRead` (`:920-921`) and
    `EmplaceRecvSessionLocked` (`:576`, via `RegisterRecv`) omits
    `BlockTransport::ForgetPushProgress(uuid)` (and
    `ReleasePoolStagingLeases(uuid)`), and `CompleteReadWithDetails`
    (`:1046-1066`) guards its post-`mu_` `ForgetPushProgress(uuid)` /
    `ReleasePoolStagingLeases(uuid)` loop with a dead `std::erase_if` inside
    the same `mu_` lock scope that just erased `uuid` from `sessions_`
    (`RegisterActivePlan` `:635` → `:651` likewise calls `ForgetPushProgress`
    unlocked after seating the replacement); stale or wiped `layer_progress_`
    suppresses layer 0's `OnLayerReceived` (H2D) while `OnBlockShardsReceived`
    still drives `network_completed_ = true`, publishing silent corrupt
    `completions.received` (`done_recving`) with layer 0's HBM unwritten. Also
    noted under **R-G** (`56a0269d` re-read).
  - **F17** (`PoolReshardPushDuplicateUuidBughunt`, 1 control + 1 failing case):
    `PoolReshardPush` (`:690-724`) lacks `PoolReshardRegisterRecv`'s pending-UUID
    reservation across the unlocked `ReshardSendSession::Create` window and
    blindly overwrites `sessions_[plan.uuid()] = state` (`:718`), so concurrent
    duplicate-UUID `PoolReshardPush` calls both return `OK`, share `uuid`'s
    bounded `PoolStagingStorage` lease, and free the slot on the faster
    session's settle while the sibling push is still streaming from it (aliasing
    the slot to an unrelated transfer).
  - **R-H** (`CONFIRMED (read)` at `56a0269d`, low-severity defensive-code
    hazard): `ReshardCoordinator::RunSubPlan` `WorkerDelivery::Mode::kController`
    overwrites `sender_status[i]` by `futures` index (`:846-854`) after a
    pre-RPC `continue` (`:831-842`) skips pushing to `futures`, clobbering the
    skipped unit's error with a later unit's `OK` (unreachable from valid
    `BuildPoolReshardPlan` output today).
  Filed tally unchanged (F16 and F17 not yet filed).
- 2026-11-09: **Re-checked at upstream `00e946e3`** (merge `8241a969`, 57
  commits past `56a0269d`). **No filed finding fixed; F14's prefill-to-decode
  production case closed.** Per finding, by `git log 56a0269d..00e946e3` on the
  cited files and by reading the code at HEAD:
  - F2, F3: `raiden_controller.cc` has no commit in the window — still open.
  - F5: `ControlHandshakeTest.DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer`
    still `DISABLED_` (`control_test.cc:1236`; `000ac1d2` only rewrote the
    test's `req_id` lookup); `StartRead` → `TransferReceiveSession::Create` →
    `AllocateStagingForLoad` → `StagingBlockAllocator::Acquire` unchanged,
    `staging_arena.cc` unchanged. `32568d35`'s `BlockLocation::kHost`
    destination lands in caller-named host blocks with no staging lease, so it
    is outside the slot pool rather than an admission fix — still open.
  - F8, F9, F12 (claim half), R-C, R-H: `reshard_coordinator.cc`,
    `request_block_registry.cc` and `pool_reshard_planner.cc` have no commit in
    the window; `5835b975` only appended `RequestBlockRegistry` /
    `ReshardCoordinator` lifecycle tests to `reshard_service_test.cc` — still
    open / unchanged.
  - F12 (sender half), F13: **changed shape, same defects.** `25f7d8a7` merged
    `recv_chains_` / `send_chains_` into `sub_plan_chains_` (keyed by `req_id`;
    `SubPlanChainProgress{sub_sessions, completed, failed, last_activity,
    anchored}` holds the sub-plan sessions themselves, one slot per
    `sub_plan_index`, sized `max(sub_plan_count, sub_plan_index + 1)`) and
    `000ac1d2` moved `req_id` into `SessionEntry{session, req_id, role}`.
    `RecordPoolReshardTerminalLocked(is_recv, req_id, uuid, session, status)`
    reports the request's terminal only when every slot holds a `Done()` OK
    session (so a sender absent from some windows still never completes and is
    still failed by `SweepSubPlanChainsLocked` after `timeout_s_`), and still
    sets `failed` + `failed_recving_` on the first non-OK sub-plan without
    checking sibling `sub_sessions` for `!Done()`. Worse, `SweepSubPlanChainsLocked`
    (`:264-269`) erases a `failed` / `completed` entry after one quiet
    `timeout_s_` without checking `!sub_session->Done()`, while
    `CompleteReadWithDetails` (`:1082`) skips `IsDraining()` sessions in its
    deadline arm: after the tombstone is erased, a late-arriving sub-plan
    `try_emplace`s a fresh unanchored entry and is reported again, and an
    already-seated `!Done()` sibling settles into `it == sub_plan_chains_.end()`
    (`:192-196`) to emit a second `failed_recving_` (if draining with error) or
    false `done_sending_` / `done_recving_` on the failed chain (if draining
    with `OkStatus()`, with no retry needed); and on an unanchored (`index >= 1`)
    entry, `EndOp()` setting `done_ = true` (`OkStatus()`) between
    `RetireSettledSessionLocked` (`:494`) and `SweepSubPlanChainsLocked` (`:278`)
    causes `:298` to clear `progress.sub_sessions` and the next poll to hit
    `!progress.anchored` (`:201-212`, ahead of `if (progress.failed ||
    progress.completed)` at `:219`) and emit `done_*` after `failed_recving_`.
    Also checked: `BuildPoolReshardPlan` (`pool_reshard_planner.cc:649-661`)
    deduplicates `unique_src` and `unique_dst` separately without rejecting
    `src_units ∩ dst_units ≠ ∅`, but within one sub-plan (`plan.uuid`)
    `BuildStartTransferForTarget` sets both `is_sender = true` and `is_receiver =
    true` so the Phase 1 framed arm RPC (`KVCacheListener::HandleControlRequest`,
    `kv_cache_listener.cc:117`) routes to `PoolReshardPush` rather than
    `PoolReshardRegisterRecv` and never arms a receive session on that unit
    (while Phase 2's `PoolReshardPush` refuses `ALREADY_EXISTS` if Phase 1's
    session is still live or retires it once `Done()`); across pipelined
    `Coordinate` stages sharing one producer registration `req_id`
    (`PipelinedDestinationStagesShareOneRequestClaim`), however, Stage 2's
    registration on a shared producer collides on `sub_plan_chains_[req_id]`
    (`erase` when `sub_plan_count <= 1`, or re-anchor on `sub_plan_index == 0`).
  - F14: **partly fixed.** `32568d35` guards `TransferReceiveSession::Start`'s
    pull-reply lambda with `if (!pull_status.ok() && !self->draining_)`, so a
    control reply failing after the data settled no longer flips `received` to
    `failed` — case (3), the only production-reachable path on the
    prefill-to-decode receiver. `TransferReceiveSession::FinishLocked` and
    `ReshardReceiveSession::FinishLocked` still record the error before
    `if (draining_) return;` (cases (1) `EndIncomingPush`, (2) receive-side
    `UnregisterActivePlan`, (4) the destructor), and `CompleteReadWithDetails`'s
    deadline sweep — now `55c218d2`'s single `session->deadline() <= now` →
    `Finish(DeadlineExceeded("Transfer session timed out"))` arm for every kind
    — still checks `IsDraining()` and finishes in separate `session->mu_` scopes.
    Summary row and reachability column updated; reproducer still needs the
    porting listed in §Files.
  - F15: still open; `49e2c36c` moved `ReshardReceiveSession` into
    `reshard_receive_session.cc`'s anonymous namespace behind
    `CreateReshardReceiveSession` without changing `AcquireStagingSlot` or
    `CollectEligiblePoolH2dsLocked`; `4e61045e` added
    `GetBlockArrayHostSpan` → `ResolveBlockArrayHostLayer` →
    `ResolveStagingSlot` (used by the shared `ValidateChunks`) as a second
    push-thread entry into the blocking `Acquire`. Reproducer ported
    (`KVCacheManagerBase::OnPoolReceived` → `OnLayerReceived`, removed by
    `9c9f92ff`) and re-run:
    1 control passing + 1 case failing (output under §F15).
  - F16, F17: still open; reproducer compiles unchanged and re-run gives the
    same 2 controls passing + 4 cases failing (outputs under §F16 / §F17).
    `StartRead` `:998-999` and `EmplaceRecvSessionLocked` `:613` still retire
    with null out-parameters, the dead `std::erase_if` is `:1106-1110`, the
    unlocked loop `:1121-1126`, `RegisterActivePlan` `:669` / `:683` → `:699`;
    `PoolReshardPush` `:732-774` still has no pending reservation and
    overwrites `sessions_[plan.uuid()]` at `:767`.
  - R-B: `block_transport_session.cc` grew ~500 lines (Peregrine backend
    `e082548c` / `984125ce`, `GetBlockArrayHostSpan` `4e61045e` / `103ec23f`)
    but `CompleteIncomingPush`'s chunk-count branch is still
    `progress.completed_chunks == expected_chunks` with no over-count
    rejection — same verdict. R-D, R-E, R-F: the store-path commits in the
    window are metrics (`eaa4bfbc`, `f9a61121`, `0bc13ad3`, `388b84e8`,
    `6ed2d949`, `542706fd`) and the `LoadOptions` 4-argument `Load`
    consolidation (`43081b1e`, `d56282ba`, `a74e87a9`); pinning and landing-block
    release are unchanged — same verdicts. R-G: see its 2026-11-09 note.
    "Open / not yet checked": `kv_cache_store_client.cc` unchanged.
  - C1: external; PR #3918 status not re-read (offline). tpu-sync's
    `RetireSettledSessionLocked` still files failed and expired sends in
    `failed_recving_`.
  - Patches (`git apply --check` from the repo root): `build_targets.patch`
    (kv_cache hunk at offset 75), `candidate_fixes.patch` and
    `coverage_gap_read_remote_deadline.patch` apply; `coverage_gap_send.patch`
    (`transfer_send_session_test.cc:796`) and
    `coverage_gap_reshard_control.patch` (`reshard_service_test.cc:2361`) newly
    fail; `coverage_gap_tests.patch`, `coverage_gap_recv.patch`,
    `coverage_gap_reshard_sessions.patch`, `coverage_gap_control_handshake.patch`
    and `coverage_gap_multi_request_recycle.patch` still fail on their
    `56a0269d` hunks. Nothing re-based. `pool_reshard_chain_bughunt_test.cc`
    (F12 / F13) now needs porting (symbols under §Files); the OSS build needed
    network access once to fetch `peregrine` 0.1.17 from the Bazel registry
    (`00e946e3` bumps the pin). Filed tally unchanged: F1 (fixed), F2+F3, F4
    (fixed), F6 (fixed), F7 (fixed), F8, F9, F10 (fixed), F11 (fixed), F12,
    F13, F15, C1 (fix open as PR #3918); F14, F16, F17 not yet filed.
- 2026-11-09 (later): **F18, F19, F20 and R-I written up and re-verified on
  `00e946e3`; `pool_reshard_stale_subplan_bughunt_test.cc` added under F13;
  `coverage_gap_reshard_control.patch` retired.**
  - Triaged, rebuilt, and ran on unmodified `00e946e3` the four 2026-10-29
    store/allocator reproducers (all four compile unchanged): **F18**
    (`kv_cache_store_remote_write_bughunt_test.cc`, 1 control + 3 failing:
    accepted remote writes settle in `HostOffloadBackend::BeginWriteRemote`
    without erasing `KVCacheStore::active_remote_writes_` so `~KVCacheStore`
    double-`Release`s live pins, and `kCancelled` after ack drops the pin
    release and save verdict), **F19** (`kv_cache_store_fetch_bughunt_test.cc`,
    4/4 failing, promoted from "Open / not yet checked": `KVCacheStoreClient::Fetch`
    sets no deadline and `LoadRemoteBlocks` frees `dst_host_block_ids` on error
    while the worker accepts planless `op = 6` / `uuid = 0` pushes into freed or
    reallocated host blocks), **F20** (`host_block_manager_race_bughunt_test.cc`,
    1 control + 1 failing: `KVCacheManagerBase::host_block_manager_` mutated
    without a lock across concurrent auto-allocating `op = 1` pushes, `H2hRead`
    pulls, and `AllocateBlocks`, handing out 1,990 duplicate host block IDs
    across 42,000 allocations), and **R-I**
    (`kv_cache_store_service_reactor_bughunt_test.cc`, 2/2 passing: refutes the
    `WriteRemoteServerReactor::StartAck` vs `OnCancel` race under gRPC 1.81.0).
  - Built and ran `pool_reshard_stale_subplan_bughunt_test.cc` (`StaleSubPlanBughunt`,
    2 controls + 4 failing on unmodified `00e946e3`) covering F13's
    `sub_plan_chains_` single-plan retry collision (`NoteSubPlanRegisteredLocked`
    erasing a live chain entry) and `SweepSubPlanChainsLocked` erasing a failed
    tombstone while a sibling sub-plan is `IsDraining() && !Done()` (emitting a
    second `failed_recving` or false `done_recving` on the failed request).
  - Re-anchored `build_targets.patch` cleanly at `00e946e3` (0 offset, covering
    all 14 `.cc` files) and retired `coverage_gap_reshard_control.patch`
    (superseded by upstream `5835b975` in `reshard_service_test.cc:2405-2703`,
    leaving `Reshard/Registry/Coverage.lean` 25/25 and
    `Reshard/Coordinator/Coverage.lean` 14/14). Filed tally unchanged (F14,
    F16–F20 not yet filed).
- 2026-11-09 (later): **F13 upstream bug updated.** Left a comment on bug 12
  with the `00e946e3` shape (after `25f7d8a7`, "no entry in `sub_plan_chains_`"
  is read as a single-plan request; the single-plan retry under the same
  `req_id` erases a live entry, and the tombstone sweep ignores a sibling that
  is still draining), noting that part 1 of the original report is unchanged
  and part 2 is the new mechanism. Original description left as filed;
  `filed_bugs.md` bug 12 carries the *Update* line. Filed tally unchanged.
- 2026-11-11: **Re-checked at upstream `d3751fcb`** (merge `74f27def`, 23
  commits past `00e946e3`). **F9 fixed upstream (`63c6447c`); F15 changed shape
  (`47e9f200`).** Per finding, by `git log 00e946e3..d3751fcb` on the cited
  files, reading the code at HEAD, and re-running OSS Bazel reproducers:
  - **F9 — FIXED upstream in `63c6447c`** (2026-11-10, "Refresh producer block
    registration TTL when a reshard request claims it"):
    `RequestBlockRegistry::LookupAndClaim` (`request_block_registry.cc:461-482`)
    collects `claimed_rows` during unit validation and updates
    `registration.expires_at = now + ttl_s_;` on every claimed `request_blocks_`
    row alongside `claimed_[lifecycle_key] = now + ttl_s_;`, leaving partial
    registrations on their original TTL when a claim fails
    (`ReshardStackTest.ClaimRefreshesRegistrationTtlForSiblingStageAndCompletion`,
    `FailedClaimDoesNotRefreshPartialRegistrationTtl`). Summary, §F9, and
    `filed_bugs.md` §6 updated.
  - **F15 — changed shape (`47e9f200`):** `ReshardReceiveSession` and
    `ReshardSendSession` (`reshard_{receive,send}_session.cc`) now construct
    `staging_layer_manager_` with `HostLayersBounded() ? base->num_host_layers() : 0`
    slots and return `StaticHostLayer(pool_idx) = pool->storage_index` from
    `AcquireStagingSlot` and `LookupStagingSlot` when `!HostLayersBounded()`
    (`num_host_layers() == num_layers()`, default when `num_staging_layers` is
    unset). Whenever `num_staging_layers < num_layers`, the per-pool
    `StagingLayerManager::Acquire` × `order_rank` H2D gate deadlock still fires
    (`LowerRankPoolResolvesWhileHigherRankPoolHoldsTheLastSlot`). On a full host
    mirror, in-place staging removes the slot wait at the cost of realizing the
    aliased-storage host-buffer overwrite noted in §F15 candidate fix `(a)` and
    `filed_bugs.md` §13: when a rank-1 pool arrives before a coarse rank-0 pool
    sharing `(storage_index, block_id)` and overlapping region bytes, both pools
    address the same `layers_[storage_index]` bytes, so rank 0's push overwrites
    rank 1's held host bytes before rank 1's gated H2D runs while the receive
    settles OK (`FullHostMirrorInPlaceStagingPreservesHeldRank1BytesWhenRank0ArrivesLater`).
    Extended `reshard_recv_staging_slot_rank_deadlock_bughunt_test.cc` and ran
    on unmodified `d3751fcb` (1 control passing + 2 cases failing; output under
    §F15).
  - **F2, F3, F5, F8, F12, F13, F14, F16, F17, F18, F19, F20:** unchanged in
    `00e946e3..d3751fcb` (`kv_transfer_uuid_and_reshard_push_bughunt_test` 2
    controls + 4 failing and `pool_reshard_stale_subplan_bughunt_test` 2
    controls + 4 failing re-run on `d3751fcb`). Also noted: `e3d1c848`
    (Peregrine 10/N) wires `BlockTransport::ResolveRecvBuffer` and
    `OnRecvComplete` into `PeregrineTransportAdapter::RecvHooks` behind opt-in
    `TPU_RAIDEN_ENABLE_PEREGRINE` for `kBlockPushExplicit` (`raddr = nullptr`,
    and `ValidateChunks` rejects `chunks.size() > uint16_t::max()`).
  - **Patches:** `build_targets.patch` re-anchored cleanly at `d3751fcb` (zero
    offset across all 4 `BUILD` files, updated deps for F15's extended test);
    `candidate_fixes.patch` and `coverage_gap_read_remote_deadline.patch` apply
    cleanly; remaining `coverage_gap_*.patch` files unchanged. OSS Bazel needed
    network access once to fetch `peregrine` 0.1.19 from the Bazel registry.
    Filed tally: F1 (fixed), F2+F3, F4 (fixed), F6 (fixed), F7 (fixed), F8, F9
    (**fixed**), F10 (fixed), F11 (fixed), F12, F13, F15, C1 (fix open as PR
    #3918); F14, F16–F20 not yet filed.
