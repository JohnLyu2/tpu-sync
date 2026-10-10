# `prefill_decode.md` split into a hot map and cold evidence files

Load this when something that used to be in `verification/docs/transfer/prefill_decode.md`
cannot be found, or before adding content to that file.

[OBS 2026-10-10] `prefill_decode.md` had grown to 68 KB / 300 lines and is the
mandatory first read of `tpu-sync-lean-helper` every session (`config.yaml`
Method step 1), so its size was paid on every question and on every citation
audit. Restructured (verbatim moves, no rewrites except the `Modules` table):

| Was in `prefill_decode.md` | Now |
|---|---|
| §"Executable trace witnesses (`trace_*`) & bounded searches", §"Test suite correspondence" (the table said 52 tests; the true count by distinct test names in the trace docstrings is 56 = 50 C++ + 6 E2E, as the slides say — corrected in `prefill_decode.md` on the same day) | **Deleted** (first moved to a `prefill_decode_tests.md`, then dropped the same day on the user's "delete what is not helpful" call). Every row duplicated a `trace_*` docstring or a `#guard` line; the nine test attributions and three notes that existed only in the table (`FailedSendWithoutWorkSettlesImmediately`, `FinishBeforeStartPushDoesNotAcquireStagingOrAccessHbm`, `ExpiredSendKeepsItsStagingUntilTheCopyEnds`, `SendSessionImplementsTransferSessionInterface`, `FailureCannotOverrideAnEarlierSuccess`, `StatusIsFrozenOnceSessionIsDrainingOrDone`, `ZeroLayerSessionCompletesAndReleasesStagingWithoutHang`, `OutOfOrderLayersSettleAfterEveryH2d`, the `run_all.sh` E2E, the `CompleteH2h` no-witness note, the `MockMetricsBackend` note, the issue-#888 comment range) were folded into the owning docstrings in `Send.lean`, `PipelineChecks.lean`, `PeerIsolation.lean` first. "Is test X modelled" is now `grep -rn X TpuSyncVerify`. |
| §"C++ observations (non-bugs at `50b0774`)" | `verification/findings/README.md` §"Observations on the prefill-to-decode path (non-bugs at `50b0774`)", before §"Fix validation". |
| §"Upstream re-checks" | `verification/docs/upstream_rechecks.md` (corpus-wide; README §"Maintenance after an upstream sync" now points there). |
| §"Modules" (4-column table + composition paragraph, 5.3 KB) | Condensed to a 3-column map (2.5 KB); the long per-module description lives in each module's header docstring. |

Also: README §Status table cut from 11 long rows to 9 short ones (the long
property lists duplicated `prefill_decode.md` §Verified properties);
`proposal.md` marked as a frozen planning document (not re-pinned on syncs);
the 2026-10-09 audit row in `upstream_rechecks.md` reduced to its outcome (the
narrative is `sessions.md` 2026-10-09).

Result: hot file 34 KB / 149 lines (routing index, modules map, shipping vs.
design alternatives, properties → theorems, boundaries, assumptions, mutants,
"Where the rest lives"). `tools/repin_citations.py` already globs `docs/**/*.md`,
so `upstream_rechecks.md` is re-pinned automatically.

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
- `verification/docs/upstream_rechecks.md`
- `verification/findings/README.md` §Observations
