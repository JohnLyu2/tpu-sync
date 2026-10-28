# Caller model: the engine above `poll_stats()` in Lean, and the connector variants checked against the real scheduler

Load this before touching `Caller.lean`, before filing or reviewing a fix
for C1, or when a question starts "what must a connector do with a
`poll_stats()` outcome".

Canonical: `tpu_sync/formal_verification/TpuSyncVerify/Transfer/Caller.lean` (moved from `Transfer/PrefillDecode/Caller.lean` on 2026-10-27 to cover both transfer paths, and split into `Caller/{Model,Invariant,Traces,MultiWorker}.lean`)
(module header: scope, event table, B1–B3, properties);
`tpu_sync/formal_verification/docs/transfer/prefill_decode.md` §Modules, §Upper boundary;
`tpu_sync/formal_verification/docs/transfer/reshard.md` §Modules, §Coordinator and engine boundary;
`findings/README.md` §C1 (**Lean** bullet, test re-run);
`findings/tpu_inference_connector_c1_test.py` §4.

[OBS 2026-10-22] Scope decision, from the plan the user approved: do not
model vLLM; model the boundary contract both ways with the connector as the
object under test. `Pipeline`/`MultiRequest` already had the safety
direction (A4: do not free before publication). The new file has the
liveness direction (every publication becomes a free) and the one safety
property the connector's own comment is about (do not decode on unwritten
KV). The engine is six states and four events; tpu-sync is two `Option Bool`
fields that are `Pipeline`'s `send.published` / `recv.published` by name.
Whole model, proofs, traces, searches: 845 lines, first build with one
type error, zero warnings after the lint pass.

[FACT] Three modelling choices worth remembering, each justified in the
header:
- Publication and the connector's forwarding are one event. Sound because
  nothing engine-visible happens between tpu-sync inserting into a list and
  the next `poll_stats()` draining it; the abort-before / abort-after
  interleavings are still distinct traces.
- The connector is a *function* (`Connector.onSend`, `onRecv : Bool →
  Signal`), not state, so `Contract conn` is a `Prop` on it and the main
  theorem quantifies over all connectors. The shipping connector, the fix
  and two half-fixes are four values.
- Leaks are stated as `leakP` / `leakD` Bool predicates and proved
  *absorbing* for every connector and policy. That lemma is what justifies
  the word "leak" in the report: no later engine action can recover,
  because the only events that free without the engine's own progress are
  the two publications and each happens once.

[FACT] The scheduler transcription (`applyLoadError`, `applyFinishedRecving`,
within-step order `invalid_block_ids` → fail-policy `finish_requests` →
`finished_recving`) was the model's main risk, so §4 of the CPU test now
drives the real vLLM `6185d73` scheduler with the `KVConnectorOutput` each
Lean connector would produce for a failed pull and asserts the Lean traces'
end states: fixed/fail frees in the same step (`FINISHED_ERROR`, pool full,
request gone); fixed/recompute marks both sets, next `schedule()` runs the
full 64-token prompt again and the pool returns at completion;
fixed/abort-before frees on the completion report; naive promotes and
schedules one token with the prompt counted as computed (the crash witness —
the CPU test cannot crash, so the witness is `num_scheduled_tokens == 1`);
loadErrorOnly leaks under both policies. 17/17.

[FACT] Two things learned about vLLM `6185d73` while transcribing, both now
in the model header: `kv_load_failure_policy` defaults to `"fail"`
(`vllm/config/kv_transfer.py:69`), so the recompute path the C1 report
describes is the non-default one; and under `"fail"` the free of an errored
`WAITING_FOR_REMOTE_KVS` request is *also* deferred to `finished_recving`
(`finish_requests` runs at `:1742` before `_update_from_kv_xfer_finished` at
`:1758`), which is why `invalid_block_ids` alone leaks under either policy.
Neither changes C1; both sharpen the fix text: "both channels, same pass".

[OBS 2026-10-22] The `Contract` gained two no-cross-talk fields after a
self-audit: the model reads only `finishedSending` on P and only
`finishedRecving` / `loadError` on D, and the real scheduler asserts if a
connector names a request in the wrong set (`_free_blocks` on an unfinished
request). Without those fields a connector could satisfy the contract and
crash the real scheduler while the model said safe.

[HYP → FACT 2026-10-27] The multi-worker aggregator (B1) is modelled in
`Transfer/Caller/MultiWorker.lean` (`mwAggSend`, `mwAggRecv`, `expectedP`,
`expectedD`). Checked against `tpu_inference/distributed/tpu_raiden_connector.py`
(`:398-402`, `:579-613`) and `vllm_torchtpu/distributed/kv_transfer/tpu_connector.py`
(`:2566-2585`, `:6113-6137` `_sync_stage3_tp_submit_states`):
- Under `connectorFixed` with `expectedP = 2`, `expectedD = 2` (guaranteed on
  `vllm-torchtpu` by `_sync_stage3_tp_submit_states` broadcasting `"failed"`,
  `"uncertain"`, or `"accepted"` across TP ranks so every worker rank either
  fails immediately or arms its 180 s native deadline), `mw_contract_safe` /
  `mw_fixed_safe` proves that no reachable state ever frees HBM while any worker
  on that node is still in flight (`mwEarlyFree = false`, discharging **A4**
  across workers when one worker fails early and triggers `loadError` while a
  sibling worker's H2D is still live), decodes unwritten KV
  (`mwDecodesUnwritten = false`), or leaks blocks on P or D (`mwLeakP = false`,
  `mwLeakD = false`). `applySend_staggered_eq_batch` and
  `applyRecv_staggered_eq_batch` (via `applyLoadError_idem`) prove that two
  workers reporting in the same `KVOutputAggregator.aggregate` pass yield the
  exact same scheduler state as two back-to-back `pWorker` / `dWorker` steps, and
  `mw_earlyLoadError_fail_eq_finish` / `mw_earlyLoadError_fail_holds_blocks`
  extend the uncertain-load proofs to 2 workers.
- Under `connectorCurrent` (`tpu-inference`), if one worker fails and the other
  succeeds, the aggregator count sticks at `1 < 2` and leaks
  (`trace_mw_current_partial_failure_leaks` — the multi-worker manifestation of C1).
- Even under `connectorFixed`, if `get_finished_count()` exceeds the number of
  participating workers (`expectedP = 3` or `expectedD = 3` with 2 workers), the
  count sticks at `2 < 3` and leaks (`trace_mw_overcounted_expected_leaks`).

[OBS 2026-10-22] Upstream check after the model: no fix for C1 anywhere;
but the unmerged tpu-inference branch `fix/pd-disagg-kv-pull-hang`
(`e7661c73`, 2026-10-16) independently arrives at `connectorFixed`'s D side
for the *other* connector (`tpu_connector.py`), for a hang rather than a
leak. Two readings: the fix shape is now corroborated by someone who hit it
in production; and the two connectors have diverged in failure handling,
so a C1 fix should be reviewed against that branch rather than written
fresh. Also learned: tpu-inference's own examples and kube benchmark drive
`tpu_connector.py`, not the raiden connector — the raiden connector's only
configured user in either repo is tpu-sync's `examples/*_disagg`.

## Corrections

None this session. The C1 report text was audited line by line against the
cited sources before this session; the model agrees with it.

## See also

- 2026-10-20-caller-side-c1-and-transport-followups.md (how C1 was found,
  the triage this plan came from)
- ../../empirical/prefill-decode-caller-tpu-inference-raiden-connector.md
- ../../loose-ends/parked.md § Caller-side formalization (re-scoped today)
