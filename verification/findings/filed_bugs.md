# Filed bugs

Code references below are against [`google/tpu-sync` @ `50b0774`](https://github.com/google/tpu-sync/tree/50b0774a62dd96b9aab580546fbf70a9443ce16c).

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

**Fix:** [google/tpu-sync#1105](https://github.com/google/tpu-sync/pull/1105) — still open, not merged as of upstream `50b0774` (2026-10-06).
