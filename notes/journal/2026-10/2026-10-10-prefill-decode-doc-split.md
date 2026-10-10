# `prefill_decode.md` split into a hot map and cold evidence files

Load this when something that used to be in `verification/docs/transfer/prefill_decode.md`
cannot be found, or before adding content to that file.

[OBS 2026-10-10] `prefill_decode.md` had grown to 68 KB / 300 lines and is the
mandatory first read of `tpu-sync-lean-helper` every session (`config.yaml`
Method step 1), so its size was paid on every question and on every citation
audit. Restructured (verbatim moves, no rewrites except the `Modules` table):

| Was in `prefill_decode.md` | Now |
|---|---|
| §"Executable trace witnesses (`trace_*`) & bounded searches", §"Test suite correspondence" (52 tests) | `verification/docs/transfer/prefill_decode_tests.md` (29 KB). Canonical copy of each trace/test fact is still the theorem docstring in the Lean module. |
| §"C++ observations (non-bugs at `50b0774`)" | `verification/findings/README.md` §"Observations on the prefill-to-decode path (non-bugs at `50b0774`)", before §"Fix validation". |
| §"Upstream re-checks" | `verification/docs/upstream_rechecks.md` (corpus-wide; README §"Maintenance after an upstream sync" now points there). |
| §"Modules" (4-column table + composition paragraph, 5.3 KB) | Condensed to a 3-column map (2.5 KB); the long per-module description lives in each module's header docstring. |

Result: hot file 34 KB / 149 lines (routing index, modules map, shipping vs.
design alternatives, properties → theorems, boundaries, assumptions, mutants,
"Where the rest lives"). `tools/repin_citations.py` already globs `docs/**/*.md`,
so the new files are re-pinned automatically; `DEFAULTS` gained
`prefill_decode_tests.md` (unqualified `.cc` = `recv.cc`).

[HYP] A further cut would be the ~45 `bt.cc`/test line citations inside the
routing index; they are the most rot-prone. Not done: the index is the one
thing the helper needs to route a C++ question, and removing ranges there would
push the agent to grep. Revisit after the `1fa06d1` sync, which rewrites all
`bt.cc` ranges anyway.

Why misled / nothing: the "internal" copy of this doc was reportedly shortened
in another session (`Raiden Lean Helper Audit Plan`); that transcript was not
on this machine and the internal tree is not indexed here, so this split was
designed independently. If the two diverge, prefer whichever keeps one home per
fact; the mapping above says where each fact went here.

Pointers updated: `notes/AGENTS.md`, `loose-ends/parked.md`, the two durable
notes that cited the moved sections. Journal entries before 2026-10-10 still
name the old section titles; they are dated and were left as written.

## Related
- `verification/docs/transfer/prefill_decode.md`
- `verification/docs/transfer/prefill_decode_tests.md`
- `verification/docs/upstream_rechecks.md`
- `verification/findings/README.md` §Observations
