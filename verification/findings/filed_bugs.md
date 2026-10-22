# Filed bugs

Code references below are against [`google/tpu-sync` @ `50b0774`](https://github.com/google/tpu-sync/tree/50b0774a62dd96b9aab580546fbf70a9443ce16c)
for bug 1, [`google/tpu-sync` @ `1fa06d1`](https://github.com/google/tpu-sync/tree/1fa06d1f44345369f4327079828ec6c4989d6694) for bug 2,
and [`google/tpu-sync` @ `0ac16d1`](https://github.com/google/tpu-sync/tree/0ac16d1) for bugs 3–6,
and [`google/tpu-sync` @ `449b591`](https://github.com/google/tpu-sync/tree/449b591) for bug 7.
Bug 8 is a caller-side defect and cites
[`vllm-project/tpu-inference` @ `c2b062b`](https://github.com/vllm-project/tpu-inference/tree/c2b062b),
[`vllm-project/vllm` @ `5ab4e44`](https://github.com/vllm-project/vllm/tree/5ab4e44)
and [`google/tpu-sync` @ `0ac16d1`](https://github.com/google/tpu-sync/tree/0ac16d1).

These are the write-ups as filed; the permalinks and line numbers are frozen at
the commit each names (`50b0774` for bug 1, `1fa06d1` for bug 2, `0ac16d1` for
bugs 3–6, `449b591` for bug 7, the three pins above for bug 8) and are not re-pinned on upstream syncs; the only edits are the italic
*Update* sentences and one internal tooling word replaced by "with the fix".
Status updates go in [README.md](README.md) (§Summary, §History).

---

## 1. `RaidenController::TransferBuffers` error-path defects (F4)

The broadcast overload of [`RaidenController::TransferBuffers`](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/core/controller/raiden_controller.cc#L573) has two problems on its error paths.

**Problem 1: it returns an error while copies are still in flight.**

*Cause*
- The function loops over workers. Each worker's copy job is sent as soon as that worker passes its checks, before the loop checks the next worker ([raiden_controller.cc:771](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/core/controller/raiden_controller.cc#L771)).
- If a later worker has no matching `node_id` on the remote side, the function returns an error from inside the loop:
  - remote source has no worker group with that `node_id` ([raiden_controller.cc:720-727](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/core/controller/raiden_controller.cc#L720-L727))
  - remote destination has no worker group with that `node_id` ([raiden_controller.cc:735-742](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/core/controller/raiden_controller.cc#L735-L742))
- The already-dispatched `worker_futures` are dropped. The caller gets an already-failed future while those copies may still be in flight.

*Impact: callers clean up on that error.* For example, on Fetch:
- The server exits after `Await()` fails ([kv_cache_store_service.cc:527-536](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/kv_cache/kv_cache_store_service.cc#L527-L536)), and `unpin_cleanup` unpins the source blocks ([kv_cache_store_service.cc:475-476](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/kv_cache/kv_cache_store_service.cc#L475-L476)).
- The client then deallocates `dst_host_block_ids` ([host_offload_backend.cc:1183-1190](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/kv_cache/host_offload_backend.cc#L1183-L1190)).
- Both can happen while the dispatched worker's copy (`H2hWrite` on the Fetch path) is still in flight.

**Problem 2: auto-allocated staging leaks.**
- When local staging is needed and not provided, it is auto-allocated ([raiden_controller.cc:639-656](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/core/controller/raiden_controller.cc#L639-L656)).
- It is only deallocated after all workers are dispatched and complete ([raiden_controller.cc:780-790](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/core/controller/raiden_controller.cc#L780-L790)).
- The early returns at [L673](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/core/controller/raiden_controller.cc#L673), [L722](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/core/controller/raiden_controller.cc#L722), [L737](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/core/controller/raiden_controller.cc#L737), [L768](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/core/controller/raiden_controller.cc#L768) and [L776](https://github.com/google/tpu-sync/blob/50b0774/tpu_sync/core/controller/raiden_controller.cc#L776) leave the blocks allocated and locked.

Both problems are confirmed by unit tests, which will be added with the fix (they fail without it).

**Proposed fix (covers both problems):**
1. Do all checks first: worker matching and client availability.
2. Then allocate staging.
3. Then build all requests, deallocating if a build fails.
4. Dispatch only at the end.

All of the function's early returns happen before the first job is sent. After that, the returned future completes only when every sent job's RPC has finished.

**Fix:** [google/tpu-sync#1105](https://github.com/google/tpu-sync/pull/1105) — still open, not merged as of upstream `50b0774` (2026-10-06). *Update 2026-10-10: merged — PR #1105 landed upstream as `72255dd` (2026-10-07); see README.md §F4.*

---

## 2. `PoolReshardRegisterRecv`: duplicate registration frees the active session's staging lease (F6)

Filed 2026-10-13. Found during Lean formalization.

**Summary.** On a pool-reshard receiver with bounded host staging, a duplicate or concurrently racing `PoolReshardRegisterRecv` for a `uuid` that is already active in `active_plans_` is rejected with `ALREADY_EXISTS`, but as a side effect its destructor **releases the host-staging lease of the active session** for that `uuid`.

**Root cause.** Two layers disagree about who owns a staging lease:

1. The per-storage staging table is keyed only by `uuid`, not by session instance. In [`KVCacheManagerBase::AcquirePoolStagingLease` / `ReleasePoolStagingLeases`](https://github.com/google/tpu-sync/blob/1fa06d1/tpu_sync/kv_cache/kv_cache_manager_base.cc#L2086-L2161), `AcquirePoolStagingLease(uuid, ...)` is idempotent per `uuid` (returns `OK` if `pool_staging_[s].leases[uuid]` already covers the requested blocks), and `ReleasePoolStagingLeases(uuid)` unconditionally erases `leases[uuid]` and returns all of its slots to `free_slots`.
2. `ReshardReceiveSession` is a per-call heap object that acquires staging before `uuid` uniqueness is enforced. In [`KVCacheManagerWithTransfer::PoolReshardRegisterRecv`](https://github.com/google/tpu-sync/blob/1fa06d1/tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc#L642-L677), the initial `active_pool_reshard_recvs_` check under `mu_` only sees sessions that have already finished registration (inserted at [L674](https://github.com/google/tpu-sync/blob/1fa06d1/tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc#L674)). Between that check and L674, `mu_` is released while [`ReshardReceiveSession::Create`](https://github.com/google/tpu-sync/blob/1fa06d1/tpu_sync/kv_cache/reshard_receive_session.cc#L351-L377) constructs a new session object, sets `staging_released_ = false` ([L419](https://github.com/google/tpu-sync/blob/1fa06d1/tpu_sync/kv_cache/reshard_receive_session.cc#L419)), and calls `AcquirePoolStagingLease(uuid)` ([L437-L438](https://github.com/google/tpu-sync/blob/1fa06d1/tpu_sync/kv_cache/reshard_receive_session.cc#L437-L438); it can also block waiting for free slots) — all **before** `RegisterActivePlanDirect(uuid)` claims `uuid` in `active_plans_` ([L670-L671](https://github.com/google/tpu-sync/blob/1fa06d1/tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc#L670-L671)).

When two `PoolReshardRegisterRecv` calls for the same `uuid=U` overlap in this window (or a call arrives for a `uuid` already registered in `active_plans_`):

- **Session S1** acquires `leases[U]` and sets `staging_released_ = false`.
- **Session S2** (a distinct `ReshardReceiveSession` object for the same `U`) also succeeds in `Create`: `AcquirePoolStagingLease(U)` sees `leases[U]` already populated and returns `OK`, and S2 also sets `staging_released_ = false`.
- **S2 is rejected:** `RegisterActivePlanDirect(U)` returns `ALREADY_EXISTS`.
- **S2's destructor frees S1's lease:** when S2 goes out of scope, [`~ReshardReceiveSession()`](https://github.com/google/tpu-sync/blob/1fa06d1/tpu_sync/kv_cache/reshard_receive_session.h#L67) `-> ReleaseStaging() -> ReleasePoolStagingLeases(U)` erases `leases[U]` and returns S1's slots to `free_slots` while S1 is still active.

By contrast, [`ReshardSendSession::Create`](https://github.com/google/tpu-sync/blob/1fa06d1/tpu_sync/kv_cache/reshard_send_session.cc#L138-L139) claims `uuid` via `RegisterActivePlanDirect` before constructing the session object.

**Impact.**

- Transfer failure for the active session: incoming pushes for `U` can no longer resolve their host staging buffer (`GetBlockChunks(uuid=U)` returns no chunks).
- Silent host-buffer aliasing: because `U`'s physical staging slots were returned to `free_slots`, the next transfer `U2` is allocated the exact same host memory addresses while `U` is still active. No error is raised.

**Reproduction** (bounded-staging receiver, `RegisterPools(..., staging_leases=2)`):

- If `uuid=4001` holds a staging lease and is registered in `active_plans_`, a rejected `PoolReshardRegisterRecv(4001)` causes `free_slots` to go from 1 back to 2, `GetBlockChunks(uuid=4001)` to return 0 chunks, and a subsequent `PoolReshardRegisterRecv(4002)` to receive the same physical slot pointer as `4001`.
- If two threads call `PoolReshardRegisterRecv(4001)` concurrently while waiting on staging slots, one returns `OK` and one returns `ALREADY_EXISTS`, and the loser's destructor erases the winner's lease (`free_slots` becomes 2, `GetBlockChunks(uuid=4001)` returns 0 chunks).

**Fix.** Claim `uuid` via `RegisterActivePlanDirect` in `ReshardReceiveSession::Create` before constructing the session and acquiring staging, rolling back with `UnregisterActivePlanDirect` if `AcquireStagingLeases` fails. Change with regression tests to follow. *Update 2026-10-16: landed upstream as `8653373` (2026-10-13) with three regression tests; see README.md §F6.*


---

## 3. `ReshardReceiveSession` ignores a failed `EndIncomingPush` and pins `PoolStagingStorage` until timeout (R1)

Filed 2026-10-16. Found during Lean formalization.

In [`KVCacheManagerWithTransfer::InitializeBaseHooks()`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc#L250-L290), the `hooks.end_incoming_push` callback handles two receive session types:

1. **Prefill-decode receive (`TransferReceiveSession`):** When `!status.ok()`, it calls `recv_session->DeferUnregisterOnSettle()` and `recv_session->Finish(status)` before `recv_session->EndRecvOp()` ([kv_cache_manager_with_transfer.cc:266-271](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc#L266-L271)).
2. **Pool reshard receive (`ReshardReceiveSession`):** It calls `reshard_session->EndRecvOp()` directly **without** checking `if (!status.ok()) { reshard_session->Finish(status); }` ([kv_cache_manager_with_transfer.cc:279-289](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc#L279-L289)).

Because [`ReshardSendSession::RecordPushCompletion`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard_send_session.cc#L351-L373) aborts on the first failed push without retrying, and [`ReshardReceiveSession::EndRecvOpLocked()`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard_receive_session.cc#L495-L505) only marks the session settled when `draining_ && in_flight_ == 0`:

1. A failed incoming push (e.g., socket timeout/disconnect during `PushData`) decrements `in_flight_` to `0`, but `draining_` remains `false` and `status_` remains `absl::OkStatus()`.
2. `reshard_session->Done()` returns `false`, so `UnregisterSettledPlan(uuid, generation)` is skipped and `hooks.end_incoming_push` returns `absl::OkStatus()` instead of `CANCELLED`.
3. The session's `PoolStagingLease` continues holding bounded `PoolStagingStorage` slots (`free_slots` stays decremented), `active_plans_[uuid]` remains registered, and `GetFinishedRecvingReqIds()` does not surface the failed request in `failed_recving` until the deadline sweep in [kv_cache_manager_with_transfer.cc:1037-1066](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc#L1037-L1066) fires at `deadline()` (`timeout_s_`, default 120 s). When it does, the request is reported as `DEADLINE_EXCEEDED: Pool reshard receive timed out`, masking the original push error.
4. Under transient network failures, leaked `PoolStagingLease` slots starve subsequent pool reshards: `AcquirePoolStagingLease` waits up to `pool_staging_lease_timeout()` (default 10 s) and then fails with `RESOURCE_EXHAUSTED` until the stale session times out.

**Fix.** In [`KVCacheManagerWithTransfer::InitializeBaseHooks()`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc#L279), call `reshard_session->Finish(status)` when `!status.ok()` before `reshard_session->EndRecvOp()`. *Update 2026-10-19: landed upstream as `fdeebcd` (2026-10-16) with a regression test in `kv_cache_manager_with_transfer_pool_reshard_test.cc`; see README.md §F7.*


---

## 4. `KVCacheStore::ValidateAndPinHostBlocks`: check-then-act window between Lookup and Pin can return a stale `host_block_id` (F1)

Filed 2026-10-19. Found during Lean formalization and confirmed by a unit test.

[`KVCacheStore::ValidateAndPinHostBlocks`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_store.cc#L1615-L1642) looks up the requested hashes first and pins them in a separate call, so it can return a `host_block_id` that no longer holds the requested hash.

**Cause**
- `backend()->Lookup(block_hashes)` at [kv_cache_store.cc:1618](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_store.cc#L1618) runs with default [`LookupOptions`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_store_backend.h#L101-L105) (`pin_found = false`), copies `existing.host_block_id` ([kv_cache_store.cc:1634](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_store.cc#L1634)), and only then calls `backend()->Pin(block_hashes)` ([kv_cache_store.cc:1637](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_store.cc#L1637)).
- The backend mutex is released between the two calls. Only `KVCacheStore::mutex_` is held across them, and neither [`KVCacheStore::Evict`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_store.cc#L1804-L1809) (*"We do not hold store mutex_ across this call"*) nor [`KVCacheStore::Insert`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_store.cc#L1008-L1041) takes `mutex_`.
- If a hash is evicted from `old_id` (and `old_id` is reused for another hash) and re-inserted at `new_id` inside that window, `Pin(block_hashes)` succeeds (pins are keyed by hash, so it pins `new_id`), while `ValidateAndPinHostBlocks` returns `old_id`.

**Impact**
- The caller pulls `old_id` (which now holds unrelated bytes) while the pin protects `new_id`; `ReleaseReadLease` still reports `LEASE_HELD`, so the wrong bytes are accepted silently.
- Note: [`KVCacheStoreServiceImpl::Fetch`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_store_service.cc#L449-L457) already closes this exact window with `pin_found = true`. `ValidateAndPinHostBlocks` is only used by [`RaidenControllerServiceImpl::AcquireReadLease`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/core/controller/controller_service.cc#L175) ([`RaidenController::ReadRemote`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/core/controller/raiden_controller.cc#L947-L1142), which has no production caller yet).

Found during the Lean formalization and confirmed by a created unit test.

**Proposed fix.** Call `backend()->Lookup(block_hashes, LookupOptions{.enable_global = false, .pin_found = true})`, release the returned pins on any validation refusal, and drop the separate `backend()->Pin(block_hashes)` call, mirroring `Fetch`. Reproducer: [`kv_cache_store_pin_race_test.cc`](kv_cache_store_pin_race_test.cc); candidate fix in [`candidate_fixes.patch`](candidate_fixes.patch).


---

## 5. `ReshardCoordinator::ExecutePoolReshard`: sender dispatch failure returns without calling `AbandonClaim`, leaking the registry claim (R2b)

Filed 2026-10-19. Found during Lean formalization and confirmed by a unit test.

[`ReshardCoordinator::ExecutePoolReshard`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/reshard_coordinator.cc#L415-L544) claims the request in `RequestBlockRegistry` under a per-call `claim_owner`, but omits `registry_->AbandonClaim(args.req_id, uuid, claim_owner)` when sender dispatch fails.

**Cause**
- `BuildPoolReshardPlan(plan_request, registry_, claim_owner)` at [reshard_coordinator.cc:420](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/reshard_coordinator.cc#L420) claims `(args.req_id, uuid)` in `RequestBlockRegistry` under `claim_owner`.
- The earlier error returns—plan build failure ([L421-424](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/reshard_coordinator.cc#L421-L424)), receiver arm failure ([L458-463](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/reshard_coordinator.cc#L458-L463)), and null controller ([L483-487](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/reshard_coordinator.cc#L483-L487))—all roll back the claim via `registry_->AbandonClaim(args.req_id, uuid, claim_owner)`.
- However, if receiver arming succeeds and any sender dispatch fails (`!sender_status[i].ok()`), lines [542-544](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/reshard_coordinator.cc#L542-L544) return `status` directly without calling `registry_->AbandonClaim(args.req_id, uuid, claim_owner)`.

**Impact**
- Because the sender transfer failed to start, `Complete` is never called for that transfer, leaving `claim_owner` leaked in `claimed_owners_[(req_id, uuid)]` and the request stuck in `STATUS_CLAIMED` until `ttl_s_` expires.
- While stuck in `STATUS_CLAIMED`, producer cleanup via [`RequestBlockRegistry::CancelIfUnclaimed`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L388-L390) is rejected (`returns false`), and any re-registration for `(req_id, uuid)` is rejected at [request_block_registry.cc:281-285](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L281-L285) (`"Request block registration is already claimed"`).

Confirmed by a unit test. Found during Lean formalization.

**Proposed fix**
- At [reshard_coordinator.cc:542-544](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/reshard_coordinator.cc#L542-L544), call `registry_->AbandonClaim(args.req_id, uuid, claim_owner);` before returning `!status.ok()`.

Reproducer: `ReshardBughuntTest.R2b_SenderDispatchFailureOrphansRegistryClaimAndArmedReceiver` in [`reshard_bughunt_test.cc`](reshard_bughunt_test.cc).


---

## 6. `RequestBlockRegistry::LookupAndClaim`: claiming a request does not refresh `request_blocks_` TTL, evicting producer registrations while the claim is active (R8)

Filed 2026-10-19. Found during Lean formalization and confirmed by a unit test.

[`RequestBlockRegistry::LookupAndClaim`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L440-L491) sets `claimed_[lifecycle_key] = now + ttl_s_` when a request is claimed, but does not refresh `expires_at` on the corresponding `request_blocks_` entries, so [`PurgeExpiredRequestBlocksLocked`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L61-L69) evicts the producer block registrations while the claim is still active.

**Cause**
- [`RequestBlockRegistry::Register`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L263) sets `registration.expires_at = t_reg + ttl_s_` on each `request_blocks_[(req_id, unit)]` entry.
- When `LookupAndClaim` claims `(req_id, uuid)` at `t_claim > t_reg`, it sets `claimed_[lifecycle_key] = t_claim + ttl_s_` ([L473](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L473)) and refreshes `completion_it->second.expires_at = t_claim + ttl_s_` ([L478](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L478)), but leaves `expires_at = t_reg + ttl_s_` on the `request_blocks_` rows it looked up at [L462-470](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L462-L470).
- In the window `[t_reg + ttl_s_, t_claim + ttl_s_)`, `PurgeExpiredRequestBlocksLocked` ([L61-69](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L61-L69)) erases `request_blocks_[(req_id, unit)]` while `claimed_[(req_id, uuid)]` remains live.

**Impact**
- In that window, [`RequestBlockRegistry::Status`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L421-L423) still reports `STATUS_CLAIMED` and [`CancelIfUnclaimed`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L388-L390) still returns `false`, yet a sibling pipelined stage claiming the request—or a stage retrying after a receiver-arm failure (the scenario in [`AbandonedStageLeavesTheSiblingClaimInPlace`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/reshard_service_test.cc#L1305-L1332))—fails in `LookupAndClaim` ([L464-468](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L464-L468)) with `"Missing producer block registration"`.

**Proposed fix**
- In [`LookupAndClaim`](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/reshard/request_block_registry.cc#L462-L474), set `it->second.expires_at = now + ttl_s_` on each claimed `request_blocks_` entry alongside `claimed_[lifecycle_key] = now + ttl_s_` (alternatively, have `PurgeExpiredRequestBlocksLocked` skip rows whose `(req_id, uuid)` is present in `claimed_`).

Reproducer: `ReshardBughuntTest.R8_SplitTtlEvictsRequestBlocksWhileClaimIsStillActive` in [`reshard_bughunt_test.cc`](reshard_bughunt_test.cc).


---

## 7. `RaidenController::ReadRemote`: deadline settles the read while the acquire callback and pull continue, so the DMA writes into blocks the caller has already recycled (F2 + F3)

Filed 2026-10-20. Found during Lean formalization; both shapes confirmed by unit tests. Code references are against [`google/tpu-sync` @ `449b591`](https://github.com/google/tpu-sync/tree/449b591) (upstream `main` on the day of filing; the `ReadRemote` region is unchanged since `0ac16d1`, shifted +6 lines by `9ac3d3e`).

[`RaidenController::ReadRemote`](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/core/controller/raiden_controller.cc#L953-L1148) resolves the caller's future from a detached deadline thread, but neither the acquire callback nor the pull checks that the read has already settled, and nothing cancels an in-flight transfer. The caller is told the read failed and recycles its destination blocks while the DMA can still start or still be writing into them.

**Cause**
- The acquire callback ([raiden_controller.cc:1059-1118](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/core/controller/raiden_controller.cc#L1059-L1118)) stores `lease_id` and calls `PullAndRelease` ([L1117](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/core/controller/raiden_controller.cc#L1117)) without checking `state->settled`; `PullAndRelease` issues `TransferBuffers` ([L1202-1203](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/core/controller/raiden_controller.cc#L1202-L1203)) without checking it either.
- The detached deadline thread ([L1125-1145](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/core/controller/raiden_controller.cc#L1125-L1145)) calls `state->Settle(DeadlineExceeded)` after `RemoteReadDeadline()` ([L111-130](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/core/controller/raiden_controller.cc#L111-L130), default lease TTL + 30 s). [`RemoteReadState::Settle`](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/core/controller/raiden_controller.cc#L942-L950) is first-wins; the losing path's work is not stopped.
- Two shapes follow: (A) the acquire reply arrives after the deadline, so the pull **starts** after the caller saw the failure; (B) the deadline fires during the pull, so the caller sees the failure while the DMA **continues**.
- Related data race in the same state: `RemoteReadState::lease_id` ([L938](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/core/controller/raiden_controller.cc#L938)) is a plain `uint64_t` (unlike `settled`, which is `ABSL_GUARDED_BY(mu)`), written on the gRPC callback thread ([L1075](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/core/controller/raiden_controller.cc#L1075)) and read on the deadline thread ([L1131-1142](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/core/controller/raiden_controller.cc#L1131-L1142)) with no synchronisation. If the deadline thread reads a stale 0 it skips the early `ReleaseReadLease`, and the source keeps its pins for the full TTL.

**Impact**
- `PullAndRelease`'s own contract ([L1175-1179](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/core/controller/raiden_controller.cc#L1175-L1179)) is that `KVCacheStore` returns the host staging blocks to the pool "once the read settles, success or failure", and the device blocks are the caller's to reuse. A late or continuing pull therefore writes into staging blocks that may already be reallocated and into device blocks the caller may already be refilling, with no error reported.
- The sibling `WriteRemote` path already handles this correctly: [`KVCacheStoreServiceImpl::DeadlineLoop`](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/kv_cache/kv_cache_store_service.cc#L1053-L1066) marks the op failed at the deadline but keeps the landing blocks until the transfer future resolves ([`CompleteWriteRemote`](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/kv_cache/kv_cache_store_service.cc#L832-L872) → `ReleaseLandingBlocks`), and logs if the transfer never resolves ([L1067-1080](https://github.com/google/tpu-sync/blob/449b591/tpu_sync/kv_cache/kv_cache_store_service.cc#L1067-L1080)). `ReadRemote` has no equivalent.
- Note: `RaidenController::ReadRemote` is only reached through `RaidenControllerServiceImpl` / tests today (`KVCacheStore::ReadRemote` routes peer loads through the `Fetch` path), so this is latent until the lease-based read is wired up.

Both shapes are confirmed by unit tests (`RAIDEN_REMOTE_READ_DEADLINE_S=1`): shape A by delaying the source's `AcquireReadLease` 2.5 s — a pull into the destination block is issued ~3 s after the future settled with `DEADLINE_EXCEEDED`; shape B by making the worker's read take 3 s — at settle the pull has started and not finished, and it completes 2 s after the caller was told the read failed. An exhaustive state-space model also shows that checking `settled` before the pull closes shape A only.

**Proposed fix**
- Checking `state->settled` before `PullAndRelease` / `TransferBuffers` closes shape A only.
- For shape B, mirror `WriteRemote`: let the deadline mark the read failed, but defer `Settle` (and therefore the caller's block reuse) until the in-flight transfer's `OnReady` fires — at the cost that a hung pull holds the caller — or add real cancellation of the in-flight transfer.
- Make `lease_id` `std::atomic<uint64_t>` (or guard it with `mu`).

Reproducers: `BugHuntTest.ReadRemoteDoesNotStartPullAfterDeadlineSettled` (A) and `BugHuntTest.ReadRemoteSettlesDeadlineWhilePullStillInFlight` (B) in [`raiden_controller_bughunt_test.cc`](raiden_controller_bughunt_test.cc); model `TpuSyncVerify/Controller/ReadRemote.lean`; naive fix in [`candidate_fixes.patch`](candidate_fixes.patch).


---

## 8. tpu-inference `tpu_raiden_connector`: `get_finished` drops tpu-sync's `failed_recving`, so failed and never-pulled transfers leak their KV blocks on both prefill and decode nodes (C1)

Filed 2026-10-22 against the caller (tpu-inference), not tpu-sync. Permalinks: tpu-inference `c2b062b`, vLLM `5ab4e44`, tpu-sync `0ac16d1`. The vLLM pin is the one the report was read against, newer than the `6185d73` that `Caller.lean` and `tpu_inference_connector_c1_test.py` use (the `examples/*_disagg/setup.sh` pin); the connector and scheduler logic are the same at both, but `5ab4e44` adds the `get_transfer_results` / `KVConnectorTransferResults.failed_recving` channel named in the fix, whose `6185d73`-era equivalent is `get_block_ids_with_load_errors` (`connectorFixed`'s `loadError` in `Caller.lean`).

[`TPUConnectorWorker.get_finished`](https://github.com/vllm-project/tpu-inference/blob/c2b062b/tpu_inference/distributed/tpu_raiden_connector.py#L632-L656) returns only tpu-sync's `done_sending` and `done_recving` and discards `failed_recving`, so vLLM is never told that a transfer failed and never frees the KV blocks it holds for it, on both the prefill (P) and the decode (D) node.

Discarding `failed_recving` is deliberate. The comment at [L641-644](https://github.com/vllm-project/tpu-inference/blob/c2b062b/tpu_inference/distributed/tpu_raiden_connector.py#L641-L644) avoids reporting a failed receive as done (vLLM would decode on unwritten KV and crash the EngineCore) and expects that *"the request times out at the API layer instead"*; the comment at [L614-621](https://github.com/vllm-project/tpu-inference/blob/c2b062b/tpu_inference/distributed/tpu_raiden_connector.py#L614-L621) expects the producer to be freed *"by timeout if no pull happened"*. But neither timeout exists as a free path: vLLM never frees a transfer-held request on its own, and tpu-sync reports the producer timeout in the very list that is dropped.

Found during Lean formulation.

**Cause**
- *Connector.* `get_finished` destructures `poll_stats()` into `(done_sending, done_recving, failed_recving)` ([L638](https://github.com/vllm-project/tpu-inference/blob/c2b062b/tpu_inference/distributed/tpu_raiden_connector.py#L638)), logs `failed_recving` ([L640-647](https://github.com/vllm-project/tpu-inference/blob/c2b062b/tpu_inference/distributed/tpu_raiden_connector.py#L640-L647)) and returns the other two ([L656](https://github.com/vllm-project/tpu-inference/blob/c2b062b/tpu_inference/distributed/tpu_raiden_connector.py#L656)). `get_block_ids_with_load_errors` is not overridden (base default `set()`). The connector's own expiry bookkeeping (`reqs_wait_pull` in `tpu_connector.py`) was not carried over when the connector was ported to tpu-sync (`a342edc3`): `SendMeta.expiration_time` is still set ([L441-446](https://github.com/vllm-project/tpu-inference/blob/c2b062b/tpu_inference/distributed/tpu_raiden_connector.py#L441-L446)) but never read.
- *vLLM: the "API-layer timeout" does not free.* The scheduler has no timeout for a transfer-held request. It frees sender blocks only from `finished_sending` ([scheduler.py:3198-3201](https://github.com/vllm-project/vllm/blob/5ab4e44/vllm/v1/core/sched/scheduler.py#L3198-L3201)), keeps a `WAITING_FOR_REMOTE_KVS` request parked until `finished_recving` ([L3144-3149](https://github.com/vllm-project/vllm/blob/5ab4e44/vllm/v1/core/sched/scheduler.py#L3144-L3149)), and when such a request is aborted defers the free until the id appears in `finished_recving_kv_req_ids` ([L2677-2686](https://github.com/vllm-project/vllm/blob/5ab4e44/vllm/v1/core/sched/scheduler.py#L2677-L2686)). The connector contract says so explicitly ([`KVConnectorTransferResults`](https://github.com/vllm-project/vllm/blob/5ab4e44/vllm/distributed/kv_transfer/kv_connector/v1/base.py#L88-L97)): *"Failed receives also appear in `finished_recving` so the scheduler can release the request from its transfer wait state"*; likewise [`get_block_ids_with_load_errors`](https://github.com/vllm-project/vllm/blob/5ab4e44/vllm/distributed/kv_transfer/kv_connector/v1/base.py#L411-L429).
- *tpu-sync: the producer "timeout" is reported in the dropped list.* A send that failed, or that nobody pulled before `timeout_s`, is filed in `failed_recving` ([kv_cache_manager_with_transfer.cc:961-970](https://github.com/google/tpu-sync/blob/0ac16d1/tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc#L961-L970)). Before tpu-sync `4246613` (2026-08-24) an expired send went to `done_sending`, which is what the connector relied on when its expiry loop was removed.

**Impact**
- **P:** every prefill whose consumer never pulls (D full local prefix hit, for which D's notify branch is a no-op by design; D absent; proxy drop) holds its HBM blocks for `TPU_P2P_WAIT_PULL_TIMEOUT` (180 s) and then leaks them; the request also stays in `scheduler.requests`.
- **D:** every failed pull leaves the request in `WAITING_FOR_REMOTE_KVS` with its blocks; a later client abort defers the free to a `finished_recving` report that never comes.
- Net effect: a monotone drain of the KV pool on long-running prefill and decode nodes, one `logger.error` line per event, cured only by restart.

Confirmed by a CPU unit test driving the real vLLM `Scheduler` and connector classes over a stubbed `poll_stats()`: the blocks are never freed, while controls that forward the outcome free them.

**Proposed fix**
Forward `failed_recving` instead of dropping it: failed sends as `finished_sending`, failed receives via [`get_transfer_results`](https://github.com/vllm-project/vllm/blob/5ab4e44/vllm/distributed/kv_transfer/kv_connector/v1/base.py#L401-L409) so vLLM recomputes rather than decodes.

Reproducer: [`tpu_inference_connector_c1_test.py`](tpu_inference_connector_c1_test.py). The tpu-sync side (`4246613`'s reclassification and the `failed_recving` naming) is an improvement request, not filed as a defect; see README §C1 "tpu-sync side".
