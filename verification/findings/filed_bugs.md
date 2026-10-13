# Filed bugs

Code references below are against [`google/tpu-sync` @ `50b0774`](https://github.com/google/tpu-sync/tree/50b0774a62dd96b9aab580546fbf70a9443ce16c)
for bug 1 and [`google/tpu-sync` @ `1fa06d1`](https://github.com/google/tpu-sync/tree/1fa06d1f44345369f4327079828ec6c4989d6694) for bug 2.

These are the write-ups as filed; the permalinks and line numbers are frozen at
`50b0774` and are not re-pinned on upstream syncs. Status updates go in
[README.md](README.md) (§Summary, §History).

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

Both problems are confirmed by unit tests, which will be added in the CL (they fail without the fix).

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

**Fix.** Claim `uuid` via `RegisterActivePlanDirect` in `ReshardReceiveSession::Create` before constructing the session and acquiring staging, rolling back with `UnregisterActivePlanDirect` if `AcquireStagingLeases` fails. Change with regression tests to follow.
