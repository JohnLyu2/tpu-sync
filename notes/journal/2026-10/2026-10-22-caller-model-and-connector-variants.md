# Caller model: the engine above `poll_stats()` in Lean, and the connector variants checked against the real scheduler

Load this before touching `Caller.lean`, before filing or reviewing a fix
for C1, or when a question starts "what must a connector do with a
`poll_stats()` outcome".

Canonical: `verification/TpuSyncVerify/Transfer/PrefillDecode/Caller.lean`
(module header: scope, event table, B1–B3, properties);
`verification/docs/transfer/prefill_decode.md` §Modules, §Upper boundary;
`verification/findings/README.md` §C1 (**Lean** bullet, test re-run);
`verification/findings/tpu_inference_connector_c1_test.py` §4.

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

[HYP] The multi-worker aggregator (B1) is the most likely place for a
sibling of C1 on multi-host D: `KVOutputAggregator` releases
`finished_recving` only when every worker has reported, and
`get_finished_count = len(kv_ip)`. A worker whose `poll_stats()` never sees
the request (e.g. it was never `start_read` on that worker's sub-manager)
would hold the whole request forever even with the fixed connector. Not
checked; parked.

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
