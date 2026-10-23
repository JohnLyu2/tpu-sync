# The prefill-to-decode caller: tpu-inference `tpu_raiden_connector`, and what it does with `poll_stats`

Canonical: `findings/README.md` §C1 and §Callers (third caller
paragraph); `verification/docs/transfer/prefill_decode.md` §Upper boundary. This
note holds where the sources are, what the reading settled, and what not to
re-investigate.

**Verified against:** tpu-sync `0ac16d1`; `vllm-project/tpu-inference`
`7ed46a6` (pinned by `examples/*_disagg/setup.sh`) and `main` `c2b062b`
(2026-10-20); `vllm-project/vllm` `6185d73` (same scripts).
**Last verified:** 2026-10-22 (model and §4 tests added; upstream re-checked at tpu-inference `ee8b4ac7`, tpu-sync `75bd590`; sources unchanged)

[EMP] The production caller of the path `TpuSyncVerify/Transfer/PrefillDecode/`
models is **not** either torchtpu connector. It is
`tpu_inference/distributed/tpu_raiden_connector.py` (663 lines), which calls
`register_read` / `start_read` / `poll_stats` directly and never touches
`coordinate_transfer`. `vllm-torchtpu`'s 7,047-line `tpu_connector.py` and
`sglang-torchtpu` drive the reshard control plane only. Before 2026-10-20 the
§Callers table was read as if it covered the prefill-to-decode path; it did not.

[EMP] Sparse clones used for the reading live in the conversation scratch
directory (`scratch/callers/{tpu-inference,vllm}`), never in the fork. vLLM was
sparse-checked-out to `vllm/v1/core` and
`vllm/distributed/kv_transfer/kv_connector/v1` only.

[EMP] `Pipeline` A4 holds for this pair by reading: vLLM frees transfer-held
blocks only on the connector's finished report and defers the free on abort of
a `WAITING_FOR_REMOTE_KVS` request; the connector reports only what tpu-sync
has settled. The same reading produced C1: the connector drops `failed_recving`
on both nodes, never implements `get_block_ids_with_load_errors`, and its own
`SendMeta.expiration_time` is dead code, so failed and never-pulled transfers
leak their blocks until restart.

[FACT] Since 2026-10-22 the pair is modelled:
`verification/TpuSyncVerify/Transfer/PrefillDecode/Caller.lean` (the engine
above `poll_stats()`; `Contract` is the `base.py:357-393` text as a `Prop` on
the connector; `contract_safe`; C1 as `trace_c1_*`; leaks absorbing). The
scheduler transcription it rests on is asserted against the real scheduler by
§4 of the C1 test file (17/17). What the model does not cover is its B1–B3.

Do not re-investigate:
- "Would reporting a failed receive as `done_recving` alone be a fix?" — no;
  `Caller.trace_naive_decodes` and `test_naive_connector_decodes_on_unwritten_kv`:
  the request is promoted with its prompt counted as computed. The connector
  comment's fear is correct; the missing piece is the load-failure channel
  *in the same pass*, not the omission of the completion.
- "Would `get_block_ids_with_load_errors` alone be a fix?" — no;
  `trace_loadErrorOnly_*`: under either policy the free waits for a
  `finished_recving` that never comes.
- "Does the default policy recompute?" — no; `kv_load_failure_policy`
  defaults to `"fail"` (`vllm/config/kv_transfer.py:69`); with the fixed
  connector the request is `FINISHED_ERROR` and freed in the same step.
- "Does the connector retry a failed pull with the same uuid?" — no; one
  `start_read` per request, `_submitted` guard (`:600-606`), uuid fresh per send
  (`:659-663`). R-B's premise holds for this caller too.
- "Does vLLM time out `WAITING_FOR_REMOTE_KVS` on its own?" — no
  (`scheduler.py:646-651` logs; promotion needs `finished_recving_kv_req_ids`).
- "Is `failed_recving` the receive side only?" — no; tpu-sync files failed
  *sends* there too (`mgr.cc:970`), which is half of C1.

[OBS 2026-10-22] Upstream check: `tpu_raiden_connector.py` unchanged at
tpu-inference `main` `ee8b4ac7`; `vllm-jax` is README-only (`d086b9c`), so
nothing to carry yet; tpu-sync `main` `75bd590` leaves the send
classification alone. The unmerged branch `fix/pd-disagg-kv-pull-hang`
(`e7661c73`) is the nearest upstream activity: same fix shape, other
connector (`tpu_connector.py`, which tpu-inference's own examples use — the
raiden connector is configured by tpu-sync's `examples/*_disagg`). Its author
is the natural reviewer for a C1 fix. Details canonical (C1 status).

Open: hardware repro of C1 (recipe in the C1 entry); re-check `vllm-jax`
once it has code.

## See also

- reshard-callers-vllm-and-sglang-torchtpu.md (the other two callers)
- ../journal/2026-10/2026-10-20-caller-side-c1-and-transport-followups.md
