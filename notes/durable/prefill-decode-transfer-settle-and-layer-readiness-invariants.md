# Prefill-to-decode transfer pipeline, settle protocol, and layer readiness invariants

Load this note when auditing or modifying `TransferSendSession`, `TransferReceiveSession`, `KVCacheManagerWithTransfer`, `BlockTransport`, or their Lean counterparts in `verification/TpuSyncVerify/Transfer/`.

[FACT] TPU Sync transfers KV caches from prefill TPUs to decode TPUs across three overlapped stages per request (`uuid`):
1. **D2H DMA (`TransferSendSession`)**: Copies layer blocks from prefill TPU HBM (`prefill_buffers`) into host staging DRAM (`BufferPool::Lease`).
2. **H2H TCP streaming (`BlockTransport`)**: Packetizes each staging block into `BlockPacket`s and streams them over parallel TCP sockets (`block_transport.cc:154-199`).
3. **H2D DMA (`TransferReceiveSession`)**: Copies each received layer from decode host staging DRAM into decode TPU HBM (`decode_buffers`) as soon as `OnLayerReceived` fires.
       → `tpu_sync/kv_cache/transfer_send_session.cc:322-377`
       → `tpu_sync/kv_cache/transfer_receive_session.cc:508-693`
       → `verification/TpuSyncVerify/Transfer/Pipeline.lean` (`Pipeline.system_data_correct`)

[FACT] Both `TransferSendSession` and `TransferReceiveSession` share a 6-field settle state machine (`draining_`, `done_`, `failed_`, `in_flight_`, `pending_finish_status_`, `hasStaging`) that guarantees host staging buffers are never returned to `BufferPool` while any DMA or network op is still in flight (`done → draining` and `done → in_flight_ == 0`).
       → `tpu_sync/kv_cache/transfer_send_session.cc:510-585`
       → `tpu_sync/kv_cache/transfer_receive_session.cc:695-769`
       → `verification/TpuSyncVerify/Transfer/Session.lean` (`Session.invariant_preserved`)

       ```cpp
       draining_ = true;
       if (!status.ok() && pending_finish_status_.ok()) {
         pending_finish_status_ = status;
       }
       if (in_flight_ > 0) {
         return;
       }
       done_ = true;
       failed_ = !pending_finish_status_.ok();
       ```

[FACT] `TransferReceiveSession::ExecuteLayerH2d` releases `mu_` after snapshotting `staging_buffers_` and `decode_buffers_` (`transfer_receive_session.cc:532-558`), builds the PJRT H2D copy descriptors unlocked, and re-acquires `mu_` at `:601`. If `FinishLocked` ran during the unlocked window (`done_ || draining_`), `ExecuteLayerH2d` aborts and calls `EndRecvOpLocked()` (`:602-612`) so the `BeginRecvOpLocked()` increment from `OnLayerReceived` does not leak `in_flight_` and wedge settlement.
       → `tpu_sync/kv_cache/transfer_receive_session.cc:601-612`
       → `verification/TpuSyncVerify/Transfer/Receive.lean` (`Receive.trace_finish_between_locks`, `Receive.MissingCancelRecheck`)

       ```cpp
       absl::MutexLock lock(mu_);
       if (done_ || draining_) {
         EndRecvOpLocked();
         return;
       }
       in_flight_++;
       ```

[FACT] `TransferReceiveSession::IsReadyToComplete` (`transfer_receive_session.cc:427-433`) checks `layers_received_ >= num_layers() && layers_h2d_completed_ >= layers_received_ && all_blocks_received_`. Because the second conjunct compares against `layers_received_` rather than `num_layers()`, its soundness depends critically on transport ordering assumption **A4**: in `BlockTransport::ProcessPacket` (`block_transport.cc:528-530, 570-584`), `OnLayerReceived` fires synchronously on the reader thread for the last layer **before** `OnBlocksReceived` sets `all_blocks_received_ = true` on that same thread.
       → `tpu_sync/kv_cache/transfer_receive_session.cc:427-433`
       → `tpu_sync/kv_cache/block_transport.cc:528-530, 570-584`
       → `verification/TpuSyncVerify/Transfer/Receive.lean` (`Receive.sound_completion`)

[FACT] `TransferReceiveSession::Poll` calls `FinishLocked(absl::OkStatus())` whenever `IsReadyToComplete()` holds (`transfer_receive_session.cc:329-332`). Because `layers_h2d_completed_` is incremented inside the H2D `OnReady` callback **before** `EndRecvOpLocked()` (`:659-665`), a concurrent `Poll()` can observe `IsReadyToComplete() == true` while `in_flight_ > 0`, setting `draining_ = true` without finishing (`in_flight_ > 0`). When the final H2D callback subsequently runs, it takes the `if (draining_)` branch (`:661-664`) and skips `RecordTransferDuration`, `RecordH2dComplete`, and `RecordEnd` (`:679-689`), even though the transfer succeeded and `EndRecvOpLocked()` still settles the session cleanly. Only `num_layers() == 0` actually needs `Poll()` to trigger `FinishLocked(OkStatus)`.
       → `tpu_sync/kv_cache/transfer_receive_session.cc:329-332, 659-689`
       → `verification/TpuSyncVerify/Transfer/ReceivePoll.lean` (`ReceivePoll.trace_poll_skips_metrics`)

[FACT] `KVCacheManagerWithTransfer` publishes `done_sending` / `failed_sending` and `done_recving` / `failed_recving` exclusively through `poll_stats()`. On the send path (`kv_cache_manager_with_transfer.cc:916-921`), a failed send session is appended to `failed_recving_` rather than `failed_sending_` (copy-paste quirk preserved in `Manager.lean`). Furthermore, `free_blocks` can immediately recycle HBM blocks once `done_recving` is published (`kv_cache_manager_with_transfer.cc:428-449`), which is safe because `done_recving` implies `in_flight_ == 0` and all H2D DMAs have retired (`MultiRequest.hbm_exclusive_ownership`).
       → `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc:428-449, 902-928`
       → `verification/TpuSyncVerify/Transfer/Manager.lean`
       → `verification/TpuSyncVerify/Transfer/MultiRequest.lean` (`MultiRequest.hbm_exclusive_ownership`, `MultiRequest.staging_exclusive_ownership`)

## Why this matters

Any change to lock acquisition order in `ExecuteLayerH2d`, callback ordering in `BlockTransport::ProcessPacket`, or op-count balancing in `Begin*OpLocked`/`End*OpLocked` can silently corrupt decode HBM or permanently leak host staging buffers. Always check the corresponding Lean mutant in `verification/TpuSyncVerify/Transfer/` before modifying these paths.

## See also

- lean-step-models-and-ghost-state-in-tpu-sync-verify.md
- controller-read-remote-and-kv-store-pinning-concurrency-traps.md
