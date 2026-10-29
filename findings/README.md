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
| `build_targets.patch` | `cc_test` targets for the six files above |
| `candidate_fixes.patch` | fix for F2 (naive, shape A only); the F4 hunk was dropped when upstream fixed F4 (`72255dd`), the F1 hunk when upstream fixed F1 (`b3ea4dc`); see "Fix validation" |
| [`filed_bugs.md`](filed_bugs.md) | verbatim write-ups of bugs filed upstream |
| [`tpu_inference_connector_c1_test.py`](tpu_inference_connector_c1_test.py) | C1 reproducer: vLLM scheduler + tpu-inference connector on CPU, 9 cases incl. 2 controls; run recipe in the header |
| `coverage_gap_tests.patch` (`coverage_gap_{send,recv,read_remote_deadline}.patch`) | 9 upstream-shaped test cases for lifecycle branches no test in the suite reaches, taken from the branch-coverage tables in `tpu_sync/formal_verification/` (`Receive/Coverage.lean`, `Send/Coverage.lean`, and `Controller/ReadRemoteCoverage.lean` on branch `controller-verification`): 4 `RecvLifecycleTest`/`RecvDrainTest` cases appended to `kv_cache_manager_with_transfer_send_drain_test.cc`, 2 `TransferSendSessionTest` cases appended to `transfer_send_session_test.cc`, and a new `read_remote_deadline_test` target (3 cases, own binary with `RAIDEN_REMOTE_READ_DEADLINE_S=1` because `RemoteReadDeadline()` is a process-wide static) with its `BUILD` rule. Based on `42dda542`; all 9 pass there (2026-10-28). Offered upstream as three small per-target test-only PRs (`coverage_gap_{send,recv,read_remote_deadline}.patch`). Not included: the two `Receive` handshake cases that need a replying control-plane producer stub, the multi-request recycle case, which needs a seam that observes staging contents, two `ReadRemote` rows with no observable effect (`acquireAfterShutdown` after the deadline, and `deadlineLate`, which a test cannot see), and the receiver's late-`Finish` status flip, kept as a finding instead. See "Coverage-gap tests" below |

To run F1–F4: copy the two `.cc` files next to the code they test
(`tpu_sync/core/controller/`, `tpu_sync/kv_cache/`), `git apply
findings/build_targets.patch`, then
`bazel test //tpu_sync/core/controller:raiden_controller_bughunt_test
//tpu_sync/kv_cache:kv_cache_store_pin_race_test`. To run F11: copy
`numa_kv_cache_manager_bughunt_test.cc` to `tpu_sync/frameworks/jax/`, apply
`findings/build_targets.patch`, and run
`bazel test --config=oss //tpu_sync/frameworks/jax:numa_kv_cache_manager_bughunt_test`.
To run F12 / F13: copy `pool_reshard_chain_bughunt_test.cc` to `tpu_sync/kv_cache/`,
apply the patch, and run
`bazel test --config=oss //tpu_sync/kv_cache:pool_reshard_chain_bughunt_test`.
F5 needs no repro file:
its test is already in the tree as `DISABLED_`
(`bazel test --config=oss //tpu_sync/kv_cache:kv_cache_manager_with_transfer_control_test
--test_arg=--gtest_also_run_disabled_tests`); the fix patch that re-enabled it
was retired on 2026-10-16 (see F5). All three patches apply cleanly at
`42dda542` (`git apply --check`, 2026-10-29; `build_targets.patch` updated
2026-10-29 for F11 and F12/F13; `candidate_fixes.patch` was last re-based at `2ed6f8f`);
`kv_cache_store_pin_race_test.cc` needs its `WindowBackend::Insert` override
ported to the `InsertOption` signature `2ed6f8f` introduced before it compiles
(F1 is fixed there, see §F1). The F1–F4, R7/R8/R2b and F10 `.cc` reproducers
have not been rebuilt since the runs their entries record.

## Summary

| # | Finding | Status | Reachable from production? |
|---|---|---|---|
| F1 | `ValidateAndPinHostBlocks` could return a host block id that no longer holds the hash ([filed](filed_bugs.md#4-kvcachestorevalidateandpinhostblocks-check-then-act-window-between-lookup-and-pin-can-return-a-stale-host_block_id-f1) 2026-10-19) | CONFIRMED (test) on `b68161a` / `d16701e`, code unchanged through `0ac16d1`; **FIXED upstream** in `b3ea4dc` (2026-10-21) | only via the `ReadRemote` API (no in-tree caller) |
| F2 | Remote read keeps DMA-ing into destination blocks after it settled with a deadline error ([filed](filed_bugs.md#7-raidencontrollerreadremote-deadline-settles-the-read-while-the-acquire-callback-and-pull-continue-so-the-dma-writes-into-blocks-the-caller-has-already-recycled-f2--f3) 2026-10-20, together with F3) | CONFIRMED (test) for shapes A and B (B added 2026-10-20, on upstream `449b591`); proved in Lean for both; filed upstream, fix pending; **still open at `42dda542`** (`raiden_controller.cc` unchanged since `449b591`) | same |
| F3 | Data race on `RemoteReadState::lease_id` (filed as part of the F2 report) | CONFIRMED (read); filed upstream, fix pending; **still open at `42dda542`** (same file, unchanged) | same |
| F4 | `TransferBuffers` leaks auto-allocated staging on every early error, and can return an error after some workers were dispatched ([filed](filed_bugs.md#1-raidencontrollertransferbuffers-error-path-defects-f4), fix: [PR #1105](https://github.com/google/tpu-sync/pull/1105)) | CONFIRMED (test) on `b68161a` / `d16701e`, code unchanged through `50b0774`; **FIXED upstream** by PR #1105 = `72255dd` (2026-10-07) | leak: no in-tree trigger; orphaned copies: yes, via Fetch / WriteRemote on a node_id mismatch |
| F5 | One unresponsive producer pins every host staging slot; `StartRead` then rejects reads from every other producer (no per-peer admission; owner-acknowledged, fix designed and validated on `50b0774`, patch retired 2026-10-16) | CONFIRMED (test), with the owners' own parked test; **still open at `42dda542`** (the test is still `DISABLED_`; `StartRead` → `TransferReceiveSession::Create` → `AllocateStagingForLoad` → `StagingBlockAllocator::Acquire` is still first-come-first-served, `0b12f51f` only threads a `MetricsCollector` through `Create`) | yes: every consumer `StartRead`, given one producer that accepts and never answers |
| F6 | `PoolReshardRegisterRecv`: a rejected duplicate (or racing) registration for an active `uuid` destroys a session object whose destructor releases the **active** session's host-staging lease ([filed](filed_bugs.md#2-poolreshardregisterrecv-duplicate-registration-frees-the-active-sessions-staging-lease-f6)) | CONFIRMED (read) at `1fa06d1`; reproduced by the reporter; **FIXED upstream** in `8653373` (2026-10-13) | yes: any pool-reshard receiver with bounded host staging (`RegisterPools(..., staging_leases > 0)`), on a duplicate or concurrent register for the same `uuid` |
| F7 | `end_incoming_push` hook: a failed incoming push on a `ReshardReceiveSession` is not turned into `Finish(status)` (the `TransferReceiveSession` branch does), so the session, its staging lease and plan claim stay pinned until the deadline sweep, which reports `DEADLINE_EXCEEDED` instead of the push error ([filed](filed_bugs.md#3-reshardreceivesession-ignores-a-failed-endincomingpush-and-pins-poolstagingstorage-until-timeout-r1); R1 in `tpu_sync/formal_verification/docs/transfer/reshard.md`) | CONFIRMED (read) at `0ac16d1`, witnessed in Lean (`Receive.lean`); **FIXED upstream** in `fdeebcd` (2026-10-16) | yes: any pool-reshard receiver whose sender's push fails mid-transfer (socket timeout / disconnect) |
| F8 | `ReshardCoordinator::ExecutePoolReshard`: the sender-dispatch error return omits `registry_->AbandonClaim(...)` (the plan-build, receiver-arm and null-controller returns all call it), so the request stays `STATUS_CLAIMED` until `ttl_s_`, refusing `CancelIfUnclaimed` and re-registration ([filed](filed_bugs.md#5-reshardcoordinatorexecutepoolreshard-sender-dispatch-failure-returns-without-calling-abandonclaim-leaking-the-registry-claim-r2b) 2026-10-19; R2b in `tpu_sync/formal_verification/docs/transfer/reshard.md`) | CONFIRMED (test) at `0ac16d1` (`reshard_bughunt_test.cc`); filed upstream, fix pending; **still open at `42dda542`, code moved**: `09a42d4e` (2026-10-25) split `ExecutePoolReshard` and the plan/arm/dispatch sequence now lives in `ReshardCoordinator::RunSubPlan`, whose sender-status loop (`if (!status.ok()) return status;`) still has no `registry_->AbandonClaim(...)`; the three abandoning returns are now guarded by `index == 0` | yes: any pool reshard whose sender `StartTransfer` RPC fails after the receivers were armed |
| F9 | `RequestBlockRegistry::LookupAndClaim` refreshes the `claimed_` TTL but not `expires_at` on the claimed `request_blocks_` rows, so in `[t_reg + ttl, t_claim + ttl)` the producer registrations are purged while the claim is live: `Status` says `STATUS_CLAIMED`, `CancelIfUnclaimed` refuses, and a sibling stage or retry fails with `"Missing producer block registration"` ([filed](filed_bugs.md#6-requestblockregistrylookupandclaim-claiming-a-request-does-not-refresh-request_blocks_-ttl-evicting-producer-registrations-while-the-claim-is-active-r8) 2026-10-19; R8 in `tpu_sync/formal_verification/docs/transfer/reshard.md`) | CONFIRMED (test) at `0ac16d1` (`reshard_bughunt_test.cc`); filed upstream, fix pending; **still open at `42dda542`** (`request_block_registry.cc` unchanged since `0ac16d1`) | yes: any multi-stage pool reshard (or a retry) whose later claim lands more than `ttl_s_` after registration but before the first claim expires |
| F10 | `ReshardSendSession::RecordPushCompletion` unregisters the sender's plan on the **first** failed push while sibling pushes are still in flight (`EndOp` would do it at settle). Siblings then resolve no chunks, and — the sharp half — a retry of the same `uuid` is accepted by `Create` while the failed session drains, shares its uuid-keyed staging lease, and loses that staging when the old session settles; a third transfer is then leased the same slot (the F6 shape on the sender; early unregister since `FinishPoolReshardSend` before `1673c9b`, lease-aliasing window since `3d1b5d4`) (R6 in `tpu_sync/formal_verification/docs/transfer/reshard.md`) | CONFIRMED (test) 2026-10-20 (`reshard_send_session_bughunt_test.cc`, against the `1fa06d1` build; the code involved is unchanged through `2ed6f8f`); **filed 2026-10-23** (bug 9 in `filed_bugs.md`); **still open at `42dda542`** (`reshard_send_session.cc` unchanged since `2ed6f8f`; the header only gained `sub_plan_index()` / `sub_plan_count()` accessors in `09a42d4e`) | early unregister: yes, any multi-peer/multi-pool send whose first failure has siblings in flight; lease aliasing: needs a same-uuid re-coordination while the old session drains, which neither `vllm-torchtpu` nor `sglang-torchtpu` does (§Callers) |
| F11 | `NumaAwareKVCacheManager::CompleteReadRaw` (the JAX `poll_stats()` wrapper) emits `failed_recving` on the **first** failing sub-manager while sibling sub-managers still have H2D / D2H DMAs in flight (`done_sending` and `done_recving` barrier-wait across sub-managers; pinned by upstream's `AnyFailureImmediatelyTriggersFailedRecvingAndSuppressesFutureAcks`), and **never erases `failed_recving_set_`** on failure (erased only when `done_recving_counts_[req] >= expected` on pure `done_recving` completions), leaking map entries on every failed/expired transfer and poisoning reused `req_id`s (dropping subsequent `failed_recving` / `done_recving` at `num_subs == 1`, and desynchronizing `done_recving_counts_` into premature `done_recving` after partial failure at `num_subs >= 2`). Present since `00a3f670` (2026-06-23) | CONFIRMED (test) 2026-10-29 (`numa_kv_cache_manager_bughunt_test.cc`, 4/4 cases on unmodified `42dda542`); **filed 2026-10-29** (bug 10 in `filed_bugs.md`) | eager `failed_recving` mid-DMA: yes on a single request when `ENABLE_MULTI_NUMA=1` (`num_subs >= 2`, wired in `tpu_raiden_connector._remote_endpoint`) + a caller forwarding `failed_recving` (masked while C1 dropped `failed_recving`; exposed once [PR #3918](https://github.com/vllm-project/tpu-inference/pull/3918) lands); `failed_recving_set_` leak: yes on every failed/expired transfer even at default `ENABLE_MULTI_NUMA=0`; `req_id`-reuse poisoning: immediate for direct `jax::KVCacheManager` callers, gated by `VLLM_DISABLE_REQUEST_ID_RANDOMIZATION=1` (or 8-hex suffix collision) in vLLM V1 |
| F12 | Windowed pool reshard (`dst_window_blocks` sub-plan chains, `09a42d4e`): `BuildPoolReshardPlan` dispatches only the source units with spans in the current window, while every sub-plan is stamped with the request-wide `sub_plan_count = K`, so a sender in `1 <= m < K` windows never reaches `K` settled sub-plans, reports nothing until `SweepSubPlanChainsLocked` fails it (`DEADLINE_EXCEEDED … m of K sub-plans settled`) after `timeout_s_`; and `RunSubPlan` abandons the registry claim only `if (index == 0)`, so a chain failing at window ≥ 1 leaves every rank not dispatched in `0 .. index-1` — which has no session and never votes `Complete` — in the claim until `ttl_s_` (the F8 gap, now by design for later windows) | CONFIRMED (test) 2026-10-29 (`pool_reshard_chain_bughunt_test.cc`: `PoolReshardChainBughunt` 2 failing + 1 control, `ChainClaimTest` 1 failing + 2 controls, on unmodified `42dda542`); **filed 2026-10-29** (bug 11 in `filed_bugs.md`) | yes for any multi-window request whose span ownership varies by window (upstream's own `WindowedRequestChainsOneSubTransferPerWindow` / `WindowClipsStraddlingSpansAtWindowBoundaries` shapes), once a caller passes `dst_window_blocks` (`SUPPORTS_DST_WINDOW_BLOCKS` is wired in `api/torch/reshard_client.py`; `vllm-torchtpu` `9725110` and `sglang-torchtpu` `9a6eef1` do not pass it yet) |
| F13 | Windowed pool reshard: `RecordPoolReshardTerminalLocked` emits `failed_recving` on the **first** failing sub-plan with no check for sibling sub-plans of the `req_id` still active (the check `SweepSubPlanChainsLocked` does make), `StartChain` sees only control-plane errors so it keeps arming and dispatching windows `1 .. K-1`, and `PoolReshardPush` / `PoolReshardRegisterRecv` seat them regardless of `chains[req_id].failed` (pinned by upstream's `FirstSubPlanFailureFailsTheRequestOnce`); the failed entry is swept after one `timeout_s_` of inactivity, so a later sub-plan starts a fresh unanchored chain that is failed again | CONFIRMED (test) 2026-10-29 (`pool_reshard_chain_bughunt_test.cc`: `PoolReshardChainBughunt1B` 4/4 failing on unmodified `42dda542`); **filed 2026-10-29** (bug 12 in `filed_bugs.md`) | mid-DMA free: yes for any multi-window request whose first failure has another window active (the F11 shape on pool reshard, with the engine recomputing into / freeing the destination blocks on `failed_recving`); double report: a worker whose next sub-plan arrives > `timeout_s_` after the failure (a sender skipped in the intervening windows, cf. F12); same caller gate as F12 |
| C1 | *(caller: tpu-inference)* `tpu_raiden_connector.get_finished` drops tpu-sync's `failed_recving` list on both nodes and never drives vLLM's load-failure channel; vLLM frees transfer-held KV blocks only on a connector report. D half: failed receives leak D's blocks — since the connector's first commit `a342edc3` (2026-06-08). P half: since tpu-sync `4246613` (2026-08-24; see "tpu-sync side" under C1) an expired send is also in that list, so every never-pulled prefill leaks P's blocks; the connector's own `SendMeta.expiration_time` is set and never read | CONFIRMED (test) 2026-10-20 (`tpu_inference_connector_c1_test.py`, CPU: real vLLM `6185d73` scheduler + real tpu-inference `7ed46a6` connector, tpu-sync `0ac16d1`'s report as its own test shows it; 9/9 incl. 2 controls; 17/17 on 2026-10-22 with the `Caller.lean` connector variants); modelled in Lean 2026-10-22 (`Caller.lean`: `trace_dropFailed_*`, leaks absorbing, `contract_safe` / `mw_contract_safe` for `connectorTwoChannel`); connector unchanged at `main` `c2b062b` and still at `main` `ee8b4ac7` (2026-10-22; the unmerged upstream branch `fix/pd-disagg-kv-pull-hang`, `e7661c73`, applies the same two-channel fix shape to the sibling JAX-P2P `tpu_connector.py` only); not run on hardware; **filed 2026-10-22** (bug 8 in `filed_bugs.md`; the tpu-sync side not raised yet); **fix open as [PR #3918](https://github.com/vllm-project/tpu-inference/pull/3918)** (`f366ef52`, 2026-10-27, "[Disagg] Forward tpu-sync failed transfers in tpu_raiden_connector"; unmerged, not on `main` `7840339b` as of 2026-10-28, where the connector is still unchanged): a new `get_transfer_results()` forwards `failed_recving` as `finished_sending` on P and as `finished_recving` + `failed_recving` on D — an instance of `connectorTwoChannel` over `AggChannel.latchedReq` (`MultiWorker.lean`), with the D-side failure on vLLM's request-level `KVConnectorTransferResults.failed_recving` channel rather than `get_block_ids_with_load_errors` (requiring `ENABLE_MULTI_NUMA=0`, see F11, and a `get_transfer_results()`-capable vLLM ≥ `e7bb7e2f`); tpu-sync at `42dda542` still files failed and expired sends in `failed_recving_` | yes: any D-side pull failure (both nodes), any D full local prefix hit or D absence (P, after `TPU_P2P_WAIT_PULL_TIMEOUT` = 180 s), any client abort of a pull that later fails (D) |

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
  Lean by `trace_r8_split_ttl_purges_request_blocks_while_claim_active` in
  `Registry.lean`). Filed upstream 2026-10-19
  ([write-up](filed_bugs.md#6-requestblockregistrylookupandclaim-claiming-a-request-does-not-refresh-request_blocks_-ttl-evicting-producer-registrations-while-the-claim-is-active-r8));
  fix pending. Output, verbatim (same run as F8):
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
  **Filed upstream 2026-10-23** (bug 9 in [`filed_bugs.md`](filed_bugs.md)). Output, verbatim (the test asserts the defect, so it passes
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
  **Filed upstream 2026-10-29** (bug 10 in [`filed_bugs.md`](filed_bugs.md)). Output, verbatim (all four tests assert the safety contract
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
  which holds the write-up). Output, verbatim (transport start-up lines
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
  [`filed_bugs.md`](filed_bugs.md), which holds the write-up). Output, verbatim
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
  arrive).

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

### Open / not yet checked

- `KVCacheStoreClient::Fetch` sets no RPC deadline
  (`kv_cache_store_client.cc:61-125`). If the RPC fails with a transport error
  while the source's workers are still writing, `LoadRemoteBlocks` frees
  `dst_host_block_ids` immediately (`host_offload_backend.cc:1131-1142`). Same
  shape as F2 but in the production path. Whether in-flight source DMA can
  outlive a failed Fetch RPC depends on worker and transport teardown, not
  established. **PLAUSIBLE.**
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

**Dropped as a finding, not a test: the receiver's late-`Finish` status flip.**
`LateErrorAfterSettledOkIsReportedAsFailed` (in the `c9bc124` draft; passed
there) drove a receive to settle OK (`FinishCopy(0, OkStatus)` → done, staging
released, data on device) and then called `Finish(CancelledError)`: the poll
reported the receive in `failed_recving`. `TransferReceiveSession::FinishLocked`
(`transfer_receive_session.cc:451` at `42dda542`) overwrites `status_` whenever
the new status is an error and the old one OK, with no `done_` guard; the
sender's `FinishLocked` (`transfer_send_session.cc:247`) returns early once
draining or done. In production the writer is the deadline sweep or
`UnregisterActivePlan`'s check-then-`Finish` racing the last H2D callback; the
consumer then treats a landed transfer as failed and re-requests it (wasteful,
not unsafe). An upstream reviewer would rightly ask for the one-line guard
rather than a test that pins the flip, so the case is not in the PR; it is a
reproducer for an issue to file (the late-error window of `Receive.lean`
§Lock scopes), and the Lean model should then gain the guard too.

Runs: 18/18 at `c9bc124` (2026-10-28, OSS Bazel recipe in the fork notes) and
9/9 at `42dda542` the same day, with the full `transfer_send_session_test`
(19 cases) and `kv_cache_manager_with_transfer_send_drain_test` (42 cases)
binaries green around them; `--runs_per_test=10` on the two kv_cache targets
also green. A failure on a later upstream is either a transcription error
(check against the harness first), a model error (the Lean post-state
disagrees with the C++ — a finding for `tpu_sync/formal_verification/`), or a
defect.

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
