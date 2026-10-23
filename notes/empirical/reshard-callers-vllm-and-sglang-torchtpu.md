# Caller repositories for the reshard control plane, and what they do with it

Canonical: `findings/README.md` §Callers (the per-finding
reachability table and the line-pinned description of each caller's retry and
topology policy). This note holds only where the clones are, what the reading
settled, and what not to re-investigate.

**Verified against:** tpu-sync `0ac16d1` (fork `main`) with upstream `main` at
`449b591`; `vllm-project/vllm-torchtpu` `9725110` (2026-10-20);
`sgl-project/sglang-torchtpu` `9a6eef1` (2026-10-20).
**Last verified:** 2026-10-20

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

Open (parked): whether the Peregrine `BlockTransport` backend (`5adb0f4`,
`b43de27`, not in the fork yet) has the socket adapter's per-uuid failure
latch; without it, F10's early unregister would let a sibling post reach the
wire with full-block fallback extents on full-mirror staging.

## See also

- ../journal/2026-10/2026-10-07-f5-per-peer-staging-admission-fix.md (F5 also
  depends on caller behaviour: one producer that accepts and never answers)
- bughunt-repro-status-at-01ffa3d.md
