# Controller ReadRemote and KVCacheStore concurrency bugs and refuted look-alikes

Load this note when auditing `RaidenController`, `KVCacheStore`, `HostOffloadBackend`, or `KVCacheStoreService` for concurrency, pinning, lease deadline, or staging buffer lifetime bugs.

## Confirmed defects at commit `01ffa3d`

[SUPERSEDED → journal/2026-10/2026-10-06-upstream-50b0774-merge-and-citation-repin.md] (2026-10-06) One clause below is wrong and left as written: `KVCacheStore::Store` (`kv_cache_store.cc:439, 463`) does not exist — `:465` is `KVCacheStore::Create`. The writers that evict and re-insert without `KVCacheStore::mutex_` are `KVCacheStore::Evict` (`:1840` at `01ffa3d`, `:1851` at `50b0774`) and `KVCacheStore::Insert` (`:1053` / `:1059`), as `verification/findings/README.md` §F1 says. The race itself (`Lookup` unpinned, then `Pin`) is correct and still present at `50b0774` (`:1666-1694`).

[FACT] **F1 — Unpinned `Lookup` + `Pin` TOCTOU in `KVCacheStore::ValidateAndPinHostBlocks` (`kv_cache_store.cc:1655-1683`)**:
`ValidateAndPinHostBlocks` calls `backend()->Lookup(hashes)` with default `LookupOptions` (`pin_found = false`), which acquires and releases `HostOffloadBackend::mutex_`, and only then calls `backend()->Pin(hashes)`. Because `KVCacheStore::Store` (`kv_cache_store.cc:439, 463`) calls `backend_->Evict` and `backend_->Insert` **without** holding `KVCacheStore::mutex_`, a concurrent `Store` in the window between `Lookup` and `Pin` can evict hash $H$'s host block $B$, reuse $B$ for hash $H'$, and re-insert $H$ at $B'$. `Pin(H)` then succeeds on $B'$ while `ValidateAndPinHostBlocks` returns the stale `host_block_id` $B$ (now holding $H'$'s bytes and unpinned) for H2D DMA into TPU HBM.
       → `tpu_sync/kv_cache/kv_cache_store.cc:1655-1683`
       → `tpu_sync/kv_cache/kv_cache_store_service.cc:446-458` (sibling `PrepareRead` already avoids this via `LookupOptions{.enable_global = false, .pin_found = true}`)
       → `verification/findings/README.md` §F1 and `verification/findings/filed_bugs.md` (was: `verification/findings/F1-validate-and-pin-toctou.md`, a file that never existed — fixed 2026-10-06)

       ```cpp
       auto found = backend()->Lookup(hashes);
       for (int64_t h : hashes) {
         if (!found.contains(h)) return false;
       }
       auto pinned = backend()->Pin(hashes);
       ```

[FACT] **F2 — `RaidenController::ReadRemote` deadline vs. pull staging buffer use-after-free (`raiden_controller.cc:1016-1211`)**:
`ReadRemote` spawns a detached deadline thread (`raiden_controller.cc:1079-1104`) whose `Settle(DeadlineExceeded)` immediately returns `state->staging_allocations` to the staging `BufferPool` (`:946-953`). Two races follow:
- **Shape A (check-then-act)**: Neither the `AcquireRemoteReadAsync` callback (`:1032-1047`) nor `PullAndRelease` (`:1123`) checks `state->settled` before calling `TransferBuffers`, starting a remote D2H pull into already-freed staging blocks.
- **Shape B (in-flight pull vs. deadline)**: If the deadline fires while `TransferBuffers` is blocked inside `future.Get()` (`:617, :1153`), `Settle` frees `staging_allocations` while the remote worker is still writing into those buffers. Unlike `KVCacheStoreService::DeadlineLoop` (`kv_cache_store_service.cc:1042`), which defers freeing landing blocks on `WriteRemote` until `CompleteWriteRemote` arrives, `ReadRemote` frees immediately.
       → `tpu_sync/raiden_controller.cc:928-956, 1016-1211`
       → `verification/TpuSyncVerify/Controller/ReadRemote.lean` (`ReadRemote.bug_trace_A_violates`, `ReadRemote.bug_trace_B_violates`, `ReadRemote.safe_under_fixed_config`)
       → `verification/findings/README.md` §F2 and `verification/findings/filed_bugs.md` (was: `verification/findings/F2-read-remote-deadline-uaf.md`, a file that never existed — fixed 2026-10-06)

[FACT] **F3 — Data race on `RemoteReadState::lease_id` (`raiden_controller.cc:897, 1034, 1090-1101`)**:
`RemoteReadState::lease_id` (`int64_t`) is written on the gRPC callback thread (`state->lease_id = resp.lease_id()` at `:1034`) without acquiring `state->mu` or `settled` ordering, and read concurrently on the deadline thread (`if (state->lease_id != 0)` at `:1090-1101`) after `Settle`. Under the C++ memory model this is UB, and if the callback runs after `Settle(DeadlineExceeded)` the newly acquired remote lease is never released until server lease expiry.
       → `tpu_sync/raiden_controller.cc:897, 1034, 1090-1101`
       → `verification/findings/README.md` §F3 and `verification/findings/filed_bugs.md` (was: `verification/findings/F3-remote-read-lease-id-race.md`, a file that never existed — fixed 2026-10-06)

[FACT] **F4 — Auto-staging leak and un-awaited worker futures on early error return in `RaidenController::TransferBuffers` (`raiden_controller.cc:573-793`)**:
When `TransferBuffers` auto-allocates staging blocks (`staging_auto_allocated = true`, `:659-676`), early error returns at `:673, :722, :737, :768, :776` bypass the cleanup block at `:791-793`, permanently leaking staging blocks from `BufferPool`. Worse, if loop 2 (`:757-783`) returns an invalid-argument error on worker $i > 0$ after workers $0 \dots i-1$ were already dispatched at `:772`, it frees the auto-allocated staging buffers at `:769` without awaiting those in-flight worker futures (`future.Get()` is at `:787`).
       → `tpu_sync/raiden_controller.cc:573-793`
       → `verification/findings/README.md` §F4 and `verification/findings/filed_bugs.md` (was: `verification/findings/F4-transfer-buffers-staging-leak.md`, a file that never existed — fixed 2026-10-06)

## Refuted look-alike hypotheses (do not re-investigate)

[FACT] The following 6 suspected concurrency bugs were investigated against `01ffa3d` and **refuted**. **Label warning (2026-10-06):** R-A…R-F here are this note's own numbering and do not match `verification/findings/README.md` §"Refuted or closed": only R-A agrees; this R-B = README R-D, this R-C = README R-E; this R-D/R-E/R-F are not in the README; README R-B (same-uuid stale push), R-C (`RequestBlockRegistry`), R-F (Fetch-source unpin) are not here. Use the README's labels outside these notes.
- **R-A (`TransferReceiveSession::IsReadyToComplete` premature completion)**: Refuted because `BlockTransport::ProcessPacket` (`block_transport.cc:528-530, 570-584`) fires `OnLayerReceived` synchronously on the socket reader thread before `OnBlocksReceived` on that same thread (Assumption A4).
- **R-B (`KVCacheStoreService::WriteRemote` deadline vs. pull UAF)**: Refuted because `DeadlineLoop` (`kv_cache_store_service.cc:1042`) explicitly skips `FreeLandingBlocks` for `WriteRemote` leases (`"WriteRemote: do NOT free landing blocks here... CompleteWriteRemote will release them"`).
- **R-C (`KVCacheStore::Load` local eviction mid-H2D-copy)**: Refuted because the caller (`ValidateAndPinHostBlocks` + `ReleaseHostPins`) pins blocks before `Load` and unpins in the PJRT `OnReady` callback (`kv_cache_store.cc:688-693`), and `Evict` skips blocks with `pin_count > 0` (`host_offload_backend.cc:549`).
- **R-D (`ExecuteLayerH2d` early-return op-count leak)**: Refuted because `EndRecvOpLocked()` is called at `transfer_receive_session.cc:607` on the `done_ || draining_` early return.
- **R-E (`TransferReceiveSession::Poll` double-`FinishLocked`)**: Refuted because `FinishLocked` sets `draining_ = true` before checking `in_flight_ > 0`, making subsequent `FinishLocked` calls no-ops; only metrics recording is skipped (see `ReceivePoll.lean`).
- **R-F (`TransferSendSession::StartD2hTransfer` callback UAF)**: Refuted because `BeginSendOpLocked` increments `in_flight_` before releasing `mu_`, preventing `FinishLocked` from setting `done_ = true` or freeing staging buffers until the callback calls `EndSendOpLocked`.
       → `verification/findings/README.md`

## See also

- prefill-decode-transfer-settle-and-layer-readiness-invariants.md
- lean-step-models-and-ghost-state-in-tpu-sync-verify.md
- ../empirical/bughunt-repro-status-at-01ffa3d.md
