# Caller side: which caller is real, A4 discharged by reading, C1 found

Load this when a question starts "what does the engine do when…" on the
prefill-to-decode path, or before filing C1.

Canonical: `findings/README.md` §C1, §Callers;
`verification/docs/transfer/prefill_decode.md` §Upper boundary;
`notes/empirical/prefill-decode-caller-tpu-inference-raiden-connector.md`.

[OBS 2026-10-20] The session started as a brainstorm of caller-side
formalization questions (contract-as-theorem, abort-vs-settlement, topology
admission by `decide`, uuid injectivity, F8/F9 timed models, controller
ordering and schedule identity). Triage: abort-vs-settlement (#3), the two
in-repo controller questions (#8/#9) and the admission table (#4) were "worth
doing"; the rest enhancements. The user then asked whether I knew the real
caller — I did not: the §Callers reading covered the reshard callers only.
Fetching the examples' pinned tpu-inference commit settled it in minutes and
answered #3 in the same hour.

[FACT] Answer to #3: `Pipeline` A4 holds for tpu-inference `7ed46a6` + vLLM
`6185d73`. The by-product is C1 (details canonical). The decisive sentence is
vLLM's own contract text, `kv_connector/v1/base.py:383-389`: failures must
still be reported via `get_finished()` and the failed blocks via
`get_block_ids_with_load_errors()`; the connector does neither.

[FACT] Dated by bisecting both repos (canonical: `findings/README.md` §C1
"History and attribution" and its "tpu-sync side" subsection): D half since the connector's first commit
`a342edc3` (2026-06-08); P half since tpu-sync `4246613` (2026-08-24), which
changed the deadline sweep's report for a never-pulled send from
`done_sending_` to `failed_recving_`. At the port date the connector's
reliance on `done_sending` was correct. Method that found it: `git log -S` on
the list names, then a per-commit grep over `kv_cache_manager_with_transfer.cc`
for `failed_recving_` inside the `deadline <= now` sweep, collapsed to the
commits where the count changed. The tpu-inference side needed the sparse
clone's full history of one file (`git log -- path`, four commits).

[OBS 2026-10-20] The user's "how long has it existed?" was the question that
split the attribution. Before it, C1 read as a connector omission with a
tpu-sync naming nit attached; after it, half of C1 is a tpu-sync API change
with no consumer update, briefly numbered F11. Then the user's "are they
problems without each other?" downgraded it: tpu-sync's behaviour is
self-consistent and pinned by its own test; without C1 the change harms
nobody; so it is a contributing cause and an improvement request inside C1's
report, not a numbered finding. Two questions worth asking of every
caller-side finding, in this order: how long, and does each side stand alone.

[EMP] C1 confirmed by test on CPU, no TPU (canonical: `findings/README.md`
§C1 "Test output", reproducer `findings/tpu_inference_connector_c1_test.py`).
Recipe that worked: vLLM `6185d73` installed editable with
`VLLM_TARGET_DEVICE=empty` (pure Python; then pin
`vllm.platforms._current_platform = CpuPlatform()` before building configs,
since the empty build registers no device), CPU torch, CPU jax, tpu-inference
`7ed46a6` with `--no-deps` and `tpu_inference.runner.tpu_runner` stubbed in
`sys.modules` (the connector imports it for a type only). vLLM's own
`tests/v1/core/utils.create_scheduler` builds a real `Scheduler`; register the
connector with `KVConnectorFactory.register_connector("TPUConnector", …)` and
pass `use_kv_connector="TPUConnector"`. The HF hub file-list API is blocked by
corp policy (403) but `config.json` for `facebook/opt-125m` fetches; after the
first run use `HF_HUB_OFFLINE=1`. Whole suite ~9 s. Environment lives in the
conversation scratch directory (`scratch/callers/{venv,vllm,tpu-inference}`),
not in the fork.

[HYP] C1's P-side leak may be the common case rather than the failure case:
a decode node with a full local prefix hit for a prompt the prefill node just
computed (repeated prompts, shared long system prompts rounded to whole
blocks) makes D's "notify P" branch a no-op and P leaks after 180 s on every
such request. Needs the hardware repro to size; the recipe is in the C1 entry.

[OBS 2026-10-20] Method note. Three corrections from the user's "check again"
loop earlier today carried over: state evidence level honestly (C1 is
CONFIRMED (read), not reproduced), separate the positive result (A4 holds)
from the defect so it is not lost, and keep fix prose short when the user has
said the bug is the point.

Next: file C1 (draft in the conversation artifacts), then #9 and #8 on
`rpc/raiden_controller.py`, then #4.
