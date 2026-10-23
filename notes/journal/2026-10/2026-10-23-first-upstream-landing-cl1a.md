# 2026-10-23 — first upstream landing: CL 1a submitted, corpus cleaned of fork references, `verification/` → `tpu_sync/formal_verification/`

Version stamp: fork `265f822` (merge of upstream `b82eb2f`); corpus baseline still `c15ead5`.

## What happened

- **Location decided:** the corpus lives at `tpu_sync/formal_verification/` in
  both trees (`6f3ae8d` renamed it in the fork; `resolve_anchors.py` roots at
  that path and prunes `formal_verification/` + `.lake/` from the C++ walk).
- **Rule adopted (conventions.md §Citing the C++):** the corpus describes the
  code as it is. No finding numbers, filing dates, reproducer/patch pointers,
  fixed-defect history or mention of the fork anywhere under
  `tpu_sync/formal_verification/` (`531e023`). `reshard.md`'s findings table
  became "Observations (R2a–R8)" (R1/R5 rows dropped — fixed upstream; their
  pre-fix behaviour survives only as `PushEndPolicy.endOpOnly` and
  `RegistrationPolicy.leaseBeforeReserve`); `read_remote.md` lost its
  reproducer/upstream-fix rows; `trace_c1_*` → `trace_current_connector_*`.
  `findings/README.md` §History records the mapping. `upstream_rechecks.md`
  moved to `notes/upstream-rechecks.md` (fork process, not code description).
- **README / conventions rewritten for in-tree readers** (`0ff8f46` and the
  README commits before it): what is modelled → layout → how the C++ is cited
  → building; conventions reordered shape → layout → faithful → proofs →
  evidence → citing, terms defined on first use.
- **Upstream step 1a landed (`b82eb2f`):** `Common/` + root module + lakefile
  set + README + conventions + `resolve_anchors.py`. Two incidental changes
  rode along: `difflib` added to `tpu_sync/internal/static_imports_check.py`'s
  stdlib allowlist, and `tpu_sync/formal_verification/.lake/` added to the root
  `.gitignore` (the fork's per-directory copy is deleted in this merge).
- **Sync** `c15ead5` → `b82eb2f` (merge `265f822`): `--diff` 648 `same`; the
  README's "last resolved at `c15ead5`" remains true, no corpus edit. Upstream
  export added Apache headers to `lakefile.toml` and `resolve_anchors.py`; taken
  from upstream. `README.md` and `TpuSyncVerify.lean` intentionally differ from
  upstream until the models land (upstream has follow-up markers / 3 imports).

## Lessons

- `[OBS 2026-10-23]` `tpu_sync/internal/static_imports_check.py` maintains a
  hand-written stdlib allowlist over Python files in the repo; any new stdlib
  import in a `.py` tool needs a line in `static_imports_check.py`.
- `[OBS 2026-10-23]` Put `.lake/` ignore rules in the repo-root `.gitignore`
  rather than a nested `.gitignore`.
- `[OBS 2026-10-23]` GitHub Actions checks run after upstream commits land on
  `google/tpu-sync`.
- Workflow from here: the corpus is edited in the fork, landed step by step,
  and the fork merges upstream back; fork-only `README.md`/`TpuSyncVerify.lean`
  differences shrink to zero as steps 2a–5 land.

## Next

Step 1b (build rules); step 2a `Session.lean` → 2b Receive(+Poll)
→ 2c Send → 2d Pipeline+MultiRequest+doc; then 3 (checks), 4 (reshard),
5 (controller), 6 (GitHub workflow), 7 (agent cut-over), 8 (docs).
