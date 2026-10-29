# Caller repositories for the reshard control plane, and what they do with it

Canonical: `findings/README.md` §Callers (reachability table and line-pinned
caller policies); `tpu_sync/formal_verification/TpuSyncVerify/Transfer/Caller.lean`
and `tpu_sync/formal_verification/docs/transfer/reshard.md` §Boundaries. This
note holds where the local clones live and what not to re-investigate.

**Read at:** tpu-sync `42dda54`; `vllm-project/vllm-torchtpu` `9725110`
(2026-10-20); `sgl-project/sglang-torchtpu` `9a6eef1` (2026-10-20) (frozen
stamp).

[EMP] The two open-source engines calling `tpu-sync`'s reshard control plane
(`register_request_blocks` / `coordinate_transfer` / `complete_request_blocks` /
`cancel_request_blocks_if_unclaimed`) are `vllm-project/vllm-torchtpu`
(`src/vllm_torchtpu/distributed/kv_transfer/tpu_connector.py`) and
`sgl-project/sglang-torchtpu`
(`sglang_tpu/disaggregation/raiden/{pipeline,pp_swa,pp_common,sender,receiver,conn}.py`).
Local clones live outside the fork at
`~/Desktop/callers/{vllm-torchtpu,sglang-torchtpu}` (copy into the conversation
scratch directory to read inside the sandbox; ignore the older gitless file at
`~/Desktop/vllm-torchtpu/.../tpu_connector.py`).

[EMP] Both callers re-issue `coordinate_transfer` for a `uuid` **only** on a
pre-arm `"Missing producer block registration"` reply, never after a post-arm
failure (post-arm errors wait for the native terminal, then fail/recompute).
Neither lets a source rank send to more than one destination stage under one
`uuid`: pipeline decode requires equal stage counts, sglang DP decode is a
single destination, and sglang twins/parts/stage groups derive distinct `uuid`s.
Consequence (`findings/README.md` §Callers): F8 is widely reached, F9
masquerades as the benign pre-arm retry, and F10's aliasing half plus R7a/R7b
are unreachable from these callers.

Do not re-investigate:
- "Does `vllm-torchtpu` retry a failed load with the same `uuid`?" — no: post-arm
  errors are marked *uncertain* and blocked until the native terminal before
  reporting via `get_block_ids_with_load_errors`.
- "Is TP prefill → PP decode admitted in `vllm-torchtpu`?" — no
  (`_raiden_qwen35_admission_topology` and `_stage3_source_work_units` require
  equal stage counts for pipeline decode).
- "Does `sglang-torchtpu` share a `uuid` between an FA transfer and its SWA
  twin?" — no (`pp_swa.twin_uuid` derives a distinct one).
- "Does `vllm-torchtpu` free destination HBM on cancellation or scheduler abort
  while `ReshardReceiveSession` is armed?" — no: `cancelled_registration` /
  `unsent_connection_failure` is strictly pre-arm; submitted loads aborted via
  `finished_req_ids` wait in `_stage3_finished_loads_pending_cleanup` until
  native receiver terminal or `expired_uncertain` (even under
  `_stage3_fail_uncertain_loads_early`, `Caller.earlyLoadError_fail_holds_blocks`
  holds `dHeld = true` until `done_recving`).
- "Does `vllm-torchtpu` drop `failed_recving` (like C1) or free producer blocks
  early?" — no: `recv_finished = _done_recving | _failed_recving` stages
  `_failed_block_ids` (`connectorFixed`), and `done_sending` fires only from
  `native_terminal_sends | cancelled_sends`.
- "Can an aliased physical page on a shared `storage_index` hold bytes from two
  concurrent requests (so one transfer's rank-0 FA H2D clobbers another's rank-1
  state bytes)?" — no (`Reshard/MultiRequest.lean` A1): in `vllm-torchtpu`
  (`raiden/pool_manifest.py` `_bind_pool_manifest`, `KVCacheManagerBase::ConfigurePoolStaging`,
  `PoolSpec::Validate`), all pools on a storage share uniform `block_stride_bytes`
  and `num_blocks`, so blocks $b$ and $b'$ overlap in device bytes iff $b = b'$;
  vLLM's unified `BlockPool` (`kv_cache_materializer.py`) allocates disjoint
  block IDs across concurrent requests (and strips prefix-cached blocks via
  `local_block_ids[prefix_pages:]`). `sglang-torchtpu` (`pp_swa.py`) never
  aliases `storage_index` across pools.

## See also

- prefill-decode-caller-tpu-inference-raiden-connector.md
- ../loose-ends/parked.md (dormant Peregrine `kBlockPush` trigger for F10)
