# The prefill-to-decode caller: tpu-inference `tpu_raiden_connector`, and what it does with `poll_stats`

Canonical: `findings/README.md` §C1 and §Callers (third caller paragraph);
`tpu_sync/formal_verification/docs/transfer/prefill_decode.md` §Upper boundary;
`tpu_sync/formal_verification/TpuSyncVerify/Transfer/Caller.lean`. This note
holds where the external sources live, what the reading settled, and what not to
re-investigate.

**Read at:** tpu-sync `42dda54`; `vllm-project/tpu-inference` `7ed46a6` (pinned
by `examples/*_disagg/setup.sh`), `main` `7840339b`, and PR `#3918`
(`f366ef523`); `vllm-project/vllm` `6185d73` and `e7bb7e2f` (2026-10-28, frozen
stamp).

[EMP] The production caller of the `TpuSyncVerify/Transfer/PrefillDecode/` path
is **not** either torchtpu connector. It is
`tpu_inference/distributed/tpu_raiden_connector.py` (`TPUConnectorScheduler` /
`TPUConnectorWorker`), which calls `register_read` / `start_read` / `poll_stats`
directly and never touches `coordinate_transfer`. `vllm-torchtpu`'s
`tpu_connector.py` and `sglang-torchtpu` drive the reshard control plane only.

[EMP] Sparse clones used for caller readings live in the conversation scratch
directory (`scratch/callers/{tpu-inference,vllm}`), never in the fork (`vllm`
sparse-checked-out to `vllm/v1/core` and
`vllm/distributed/kv_transfer/kv_connector/v1`).

[EMP] `Pipeline` A4 holds for this pair: vLLM `Scheduler` frees transfer-held
blocks only on the connector's finished report and defers freeing on abort of a
`WAITING_FOR_REMOTE_KVS` request, while the connector reports only what tpu-sync
has settled. Reading the same boundary produced **C1** (`findings/README.md`
§C1, reproducer `findings/tpu_inference_connector_c1_test.py`): at `7ed46a6`,
the connector drops `failed_recving` on both P and D, omits
`get_block_ids_with_load_errors`, and leaves `SendMeta.expiration_time` dead,
leaking KV blocks until restart. Upstream fix in flight: `vllm` `e7bb7e2f`
(`KVConnectorTransferResults`, `Scheduler._handle_failed_recving`,
`KVOutputAggregator._failed_recving_pending` — matching `Caller/MultiWorker.lean`
`mwAggRecv`) + `tpu-inference` PR `#3918` (`f366ef523`, matching
`connectorFixed`).

Do not re-investigate:
- "Would reporting a failed receive as `done_recving` alone fix C1?" — no
  (`Caller.trace_naive_decodes`, `test_naive_connector_decodes_on_unwritten_kv`):
  the scheduler promotes the request with its prompt counted as computed. Both
  channels (`done_recving` + `get_block_ids_with_load_errors`, or vLLM's new
  `failed_recving` channel) must fire in the same pass.
- "Would `get_block_ids_with_load_errors` alone fix C1?" — no
  (`Caller.trace_loadErrorOnly_*`): under either `kv_load_failure_policy` the
  block free waits for a completion report that never comes.
- "Does vLLM's default policy recompute on load failure?" — no;
  `KVTransferConfig.kv_load_failure_policy` defaults to `"fail"`, transitioning
  the request to `FINISHED_ERROR` and freeing blocks in the same step.
- "Does `tpu_raiden_connector` retry a failed pull with the same uuid?" — no;
  one `start_read` per request (`_submitted` guard) and a fresh `uuid4` per
  send. R-B's premise holds for this caller too.
- "Does vLLM time out `WAITING_FOR_REMOTE_KVS` on its own?" — no
  (`Scheduler._update_waiting_for_remote_kv` only logs; promotion requires
  `finished_recving_kv_req_ids`).
- "Is `failed_recving` the receive side only?" — no;
  `KVCacheManagerWithTransfer::CompleteReadWithDetails` classifies failed/expired
  *sends* under `failed_recving` too, which causes the P-side half of C1.

## See also

- reshard-callers-vllm-and-sglang-torchtpu.md
- ../journal/2026-10/2026-10-20-caller-side-c1-and-transport-followups.md
