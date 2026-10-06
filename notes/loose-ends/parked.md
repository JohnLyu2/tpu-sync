# Parked investigations and loose ends

Each entry uses the 5-field `better-than-fish` format so any future session can pick it up cold.

## Audit KVCacheStoreClient::Fetch missing RPC deadline and LoadRemoteBlocks staging free on transport error
**Status:** parked 2026-10-05
**Context:** `KVCacheStoreClient::Fetch` (`tpu_sync/kv_cache/kv_cache_store_client.cc:61-125`) sets no gRPC deadline on `ClientContext` (`grpc::ClientContext ctx;`), unlike `PrepareWrite` (`10s`) and `CompleteWrite` (`30s`). Furthermore, in `HostOffloadBackend::LoadRemoteBlocks` (`tpu_sync/kv_cache/host_offload_backend.cc:1184-1195`), if `TransferBuffers` returns an error (e.g., one worker fails or times out while another worker's D2H/H2H transfer is still in flight), `dst_host_block_ids` are immediately freed back to the host block allocator (`:1190-1193`).
**Why parked:** Flagged as an unverified follow-up at the end of the `01ffa3d` concurrency bug-hunt (`verification/findings/README.md`) after confirming F1–F4.
**To resume:** Inspect `RaidenController::TransferBuffers` (`tpu_sync/core/controller/raiden_controller.cc:617, 786-790`) and `WorkerServiceImpl::TransferData` to check whether `TransferBuffers` can return early while any peer worker still writes into `dst_host_block_ids`, or whether `future.Get()` drains all dispatched workers before returning.
**Effort estimate:** ~45 min.
**References:** ../durable/controller-read-remote-and-kv-store-pinning-concurrency-traps.md, verification/findings/README.md

## Translate Lean witness traces into C++ transfer_session_test.cc scenario tests
**Status:** parked 2026-10-05
**Context:** `verification/TpuSyncVerify/Transfer/Receive.lean`, `ReceivePoll.lean`, and `MultiRequest.lean` contain 5 high-value executable witness traces (`trace_finish_between_locks`, `trace_poll_before_callbacks`, `trace_slow_consumer`, `trace_layers_out_of_order`, `trace_reseat_at_finish`) that exercise subtle lock windows and callback orderings in `TransferReceiveSession` and `KVCacheManagerWithTransfer`.
**Why parked:** Lean proofs and trace witnesses are complete (`verification/docs/transfer/prefill_decode.md` Future Work F2); C++ unit test harness wiring in `tpu_sync/kv_cache/transfer_session_test.cc` was deferred.
**To resume:** Add to `tpu_sync/core/transfer_send_session_test.cc` / `tpu_sync/core/kv_cache_manager_with_transfer_send_drain_test.cc` (receive side has no session-level test file) deterministic multi-threaded or mock-PJRT callback tests corresponding to each of the 5 Lean `decide` traces.
**Effort estimate:** ~2 hours.
**References:** ../durable/prefill-decode-transfer-settle-and-layer-readiness-invariants.md, verification/docs/transfer/prefill_decode.md

## Model BlockTransport multi-sender per-block completion in Lean to discharge Receive assumptions A1/A3/A4
**Status:** parked 2026-10-05
**Context:** `TransferReceiveSession` correctness (`Receive` readiness soundness, `Receive.lean`) relies on four transport boundary assumptions (A1–A4), notably A4 (`OnLayerReceived` fires before `OnBlocksReceived` on the same reader thread in `block_transport.cc:528-530, 570-584`). Currently `BlockTransport` is treated as the environment of `Receive.lean`.
**Why parked:** Scoped out of the initial session-layer formalization (`verification/docs/transfer/prefill_decode.md` Future Work F4).
**To resume:** Create `verification/TpuSyncVerify/Transfer/Transport.lean` modeling `BlockTransport::ProcessPacket` per-block byte counters (`expected_Senders_per_block`, `layer_blocks_remaining_`, `total_blocks_remaining_`) across concurrent reader threads, and prove A1, A3, and A4 as theorems.
**Effort estimate:** ~half-day.
**References:** ../durable/prefill-decode-transfer-settle-and-layer-readiness-invariants.md, verification/docs/transfer/prefill_decode.md

## Propagate the real push-failure status through `EndIncomingPush`
**Status:** parked 2026-10-06
**Context:** Since upstream `4efb0dd`, `BlockTransport::HandleIncomingPush`'s `absl::Cleanup` reports every early return to the receive session as `InternalError("Incoming push failed")` (`tpu_sync/transport/block_transport.cc:376-381` at `50b0774`), and `end_incoming_push` finishes the session with that status (`tpu_sync/core/kv_cache_manager_with_transfer.cc:239-242`). The actual cause — handshake/payload read timeout (`e7c933f`), size mismatch, `OnLayerReceived`/`OnBlocksReceived` error — is only in the transport log, so `failed_recving` (and the connector's retry policy) cannot tell a dead peer from a corrupt stream. Observability, not correctness: the Lean model does not distinguish error statuses.
**Why parked:** no behavioural impact; the re-pin and the per-peer-admission proposal came first.
**To resume:** capture the status of the failing step in a local `absl::Status push_status` inside `HandleIncomingPush` (set before each `ABSL_RETURN_IF_ERROR`, or wrap the body in a lambda and pass its result to the cleanup), pass it to `EndIncomingPush(uuid, status)`; add a case to `RecvLifecycleTest.FailedIncomingPushImmediatelyFailsSessionAndReleasesStagingBeforeDeadline` asserting the session status code equals the injected read error (`DeadlineExceeded`). Small CL; could ride along with any change touching that hook.
**Effort estimate:** ~30 min
**References:** journal/2026-10/2026-10-06-upstream-50b0774-merge-and-citation-repin.md

## Citation drift check in CI (future-work F3)
**Status:** parked 2026-10-06
**Context:** `verification/tools/repin_citations.py OLD NEW` already classifies every `file:line` citation in the Lean modules and `docs/` as same/shift/grown/CHECK against `git diff -U0`. Run as a dry run with OLD = the commit each module says it cites and NEW = HEAD, "no `shift`/`grown`/`CHECK` lines" is exactly the drift check `docs/transfer/prefill_decode.md` §Future work F3 asks for. Known blind spots (wrapped citation lists, bare backticked continuations, per-column unqualified `.h`/`.cc`) are listed in the journal entry.
**Why parked:** the re-pin itself was the priority; CI on the fork does not exist yet.
**To resume:** (1) make the script read the pinned commit from each module's preamble instead of the command line (regex `tpu-sync \`([0-9a-f]{7})\``); (2) add `--check` returning non-zero on any non-`same`; (3) teach it the two continuation forms; (4) wire `lake build` + `repin_citations.py --check` into a GitHub Actions workflow on `experimental`.
**Effort estimate:** ~1 hr
**References:** journal/2026-10/2026-10-06-upstream-50b0774-merge-and-citation-repin.md, `verification/docs/transfer/prefill_decode.md` (Future work F3)
