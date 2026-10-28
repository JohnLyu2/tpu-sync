# Caller repositories for the reshard control plane, and what they do with it

Canonical: `findings/README.md` §Callers (the per-finding
reachability table and the line-pinned description of each caller's retry and
topology policy); `tpu_sync/formal_verification/TpuSyncVerify/Transfer/Caller.lean`
and `tpu_sync/formal_verification/docs/transfer/reshard.md` §Boundaries (the
`poll_stats()` → connector → vLLM scheduler boundary shared with
`PrefillDecode`, where `connectorFixed` models `vllm-torchtpu`'s Stage-3
outcome forwarding and `earlyLoadError_fail_holds_blocks` models
`_stage3_fail_uncertain_loads_early`). This note holds only where the clones
are, what the reading settled, and what not to re-investigate.

**Verified against:** tpu-sync `c9bc124` (fork `main`);
`vllm-project/vllm-torchtpu` `9725110` (2026-10-20);
`sgl-project/sglang-torchtpu` `9a6eef1` (2026-10-20).
**Last verified:** 2026-10-27

[EMP] The two open-source engines that call `tpu-sync`'s reshard control plane
(`register_request_blocks` / `coordinate_transfer` / `complete_request_blocks`
/ `cancel_request_blocks_if_unclaimed`) are
<https://github.com/vllm-project/vllm-torchtpu> (connector:
`src/vllm_torchtpu/distributed/kv_transfer/tpu_connector.py`) and
<https://github.com/sgl-project/sglang-torchtpu>
(`sglang_tpu/disaggregation/raiden/{pipeline,pp_swa,pp_common,sender,receiver,conn}.py`).
Clones live outside the fork at `~/Desktop/callers/{vllm-torchtpu,sglang-torchtpu}`
(local disk; not visible to the sandboxed shell — read them from a copy under
the conversation scratch directory or with an unsandboxed command). The loose
single file `~/Desktop/vllm-torchtpu/.../tpu_connector.py` (2026-09-24, 5,610
lines, no `.git`) predates `9725110` and differs from it; prefer the clone.

[EMP] Both callers re-issue `coordinate_transfer` for the same uuid **only**
while the reply contains `"Missing producer block registration"` (a pre-arm,
side-effect-free reply), and never after a post-arm failure. Both treat any
post-arm failure as "wait for the native terminal, then fail/recompute".
Neither has a rank send to more than one destination stage under one uuid:
pipeline decode requires equal stage counts; sglang's DP decode is a single
destination; sglang's twins/parts/stage groups use distinct derived uuids.
Consequences for the findings are in the canonical table; the short version:
F8 is the widely reached one, F9 masquerades as the callers' benign retry
case, F10's aliasing half and R7a/R7b are not reachable from these callers.

Do not re-investigate:
- "Does vllm retry a failed load with the same uuid?" — no (`tpu_connector.py:6032-6050`
  at `9725110`: post-arm errors are *uncertain*, blocked until the native
  terminal, then recompute via `get_block_ids_with_load_errors`).
- "Is TP prefill → PP decode admitted in vllm?" — no (`_raiden_qwen35_admission_topology`,
  `:3856-3930`; `_stage3_source_work_units` `:4874-4881` requires equal stage
  counts for pipeline decode).
- "Does sglang share a uuid between the FA transfer and its SWA twin?" — no
  (`pp_swa.twin_uuid` derives a distinct one).
- "Does vllm-torchtpu free destination HBM on a cancellation or scheduler abort
  while a `ReshardReceiveSession` is still armed?" — no: `tpu_connector.py:6006-6031`
  (`cancelled_registration` / `unsent_connection_failure`) is strictly pre-arm;
  a scheduler abort of a submitted load (`finished_req_ids`, `:6339-6353`) is
  parked in `_stage3_finished_loads_pending_cleanup` and `done_recving` is
  withheld until the native receiver terminal or `expired_uncertain` (`:6400-6414`,
  `:6525-6535`). Under `_stage3_fail_uncertain_loads_early` (`:2717, 6039-6040`),
  staging `_failed_block_ids` on the `"uncertain"` RPC error pass transitions the
  scheduler to `FINISHED_ERROR` with `dHeld = true` (`Caller.earlyLoadError_fail_holds_blocks`),
  still deferring `_free_blocks` until `done_recving` arrives on the terminal pass.
- "Does vllm-torchtpu drop `failed_recving` (like tpu-inference C1) or free
  producer blocks before `cancel_request_blocks_if_unclaimed` / native send
  terminal?" — no (`:6365-6378, 6462-6463, 6545-6571`: `recv_finished = _done_recving | _failed_recving`,
  `newly_failed` blocks staged into `_failed_block_ids`, and producer
  `done_sending` emitted only from `native_terminal_sends | cancelled_sends`).
- "Can a single aliased physical page on a shared `storage_index` hold bytes
  belonging to two different concurrent requests (so Request $A$'s rank-0 FA
  H2D could clobber Request $B$'s rank-1 state bytes across transfers)?" — no
  (`MultiRequest` A1 in `Reshard/MultiRequest.lean`): across all three hybrid
  pool manifests in `vllm-torchtpu` (`raiden/pool_manifest.py` at `9725110`:
  `build_qwen35_pool_manifest` `:1105-1166`, `build_kimi_k3_pool_manifest`,
  `build_dsv4_pool_manifest` `:1641-1695`, plus `block_major_pool.py`), every
  pool on a storage shares one uniform `block_stride_bytes = raw_nbytes // num_blocks`
  and `num_blocks` (`ConfigurePoolStaging` in `kv_cache_manager_base.cc:1981-2009`),
  with sub-page `base_offset_bytes + region.extent_end_bytes <= block_stride_bytes`
  enforced by `_bind_pool_manifest` (`pool_manifest.py:1140-1148`) and by
  `PoolSpec::Validate(storage_bytes)` whenever `storage_bytes == num_blocks * block_stride_bytes`
  (note: `PoolSpec::Validate` checks `region.Validate(block_stride_bytes)` relative to
  `base_offset_bytes` plus `storage_extent_end_bytes() <= storage_bytes`, so if a
  synthetic test passes `storage_bytes > num_blocks * stride` — as in
  `PoolStagingTest.PoolHostBaseAddrs` at `pool_staging_test.cc:493-497` —
  `base_offset_bytes + extent_end` can exceed `stride`; production storage tensors
  always have `storage_bytes == num_blocks * stride`). Thus block $b$ of pool $P_1$
  and block $b'$ of pool $P_2$ overlap in device bytes iff $b = b'$. Above `tpu-sync`,
  vLLM's unified `BlockPool` (`kv_cache_materializer.py:237-306`,
  `runner/kv_cache_dsv4.py:168-170`, `runner/kv_cache_manager.py:448-450`) allocates
  from a single `[0, num_blocks)` free list shared across all `kv_cache_groups`
  (in fact, `local_block_ids` for FA and `mamba_state_block_ids` / non-0 `group_blocks`
  for Mamba/GDN/KDA/DSv4 are disjoint even within the *same* request in `tpu_connector.py:5703-5739`,
  and shared prefix-cached blocks are stripped from `local_block_ids[prefix_pages:]`
  at `tpu_connector.py:1930-1951`). `sglang-torchtpu` (`pp_swa.py:113-121`) assigns
  a distinct `storage_index` per pool and never aliases storages at all. Per-transfer
  `order_rank` (`CollectEligiblePoolH2dsLocked`) is only exercised when a single
  transfer or unit test passes `b_fa == b_state` within one `uuid`.

Open (parked, checked through `c9bc124` in `../loose-ends/parked.md`): whether
the Peregrine `BlockTransport` backend (`5adb0f4`, `b43de27`, `86d4506`;
`tpu_sync/transport/lib/adapter/peregrine_transport_adapter.{h,cc}`) has the
socket adapter's per-uuid failure latch once wired in (at `c9bc124`,
`BlockTransport` still constructs `SocketTransportAdapter` and
`PeregrineTransportAdapter::Post` refuses `kBlockPush` with
`UnimplementedError`); without a latch, F10's early unregister would let a
sibling post reach the wire with full-block fallback extents on full-mirror
staging.

## See also

- ../journal/2026-10/2026-10-07-f5-per-peer-staging-admission-fix.md (F5 also
  depends on caller behaviour: one producer that accepts and never answers)
- bughunt-repro-status-at-01ffa3d.md
