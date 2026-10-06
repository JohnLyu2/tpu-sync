# 2026-10-06 — Notes reorganisation: one home per fact

Session `f92271cf`. Decision taken with the user while preparing the fork for
`main`.

## Decision

[FACT] Two corpora, two audiences, one home per fact. `verification/` is the
human-facing deliverable and owns every fact (models, docs, findings, the
upstream re-check log, the sync procedure). `notes/` is the agent notebook and
owns only what the deliverable does not say: interpretation, "do not
re-investigate" guidance, corrections with "why I was misled", hypotheses,
parked work, the session index. A durable/empirical note starts with a
`Canonical:` line naming the `verification/` document it defers to. Rules
recorded in the repo `AGENTS.md` (`../../../AGENTS.md`) and in
`notes/AGENTS.md` (`../../AGENTS.md`).

[FACT] Three further decisions: durable/empirical notes become thin pointers +
interpretation (not full copies); `verification/slides/*.pdf` is ignored (the
`.typ` sources are tracked); the code map lives in the root `AGENTS.md` only.
Agent-facing files (`AGENTS.md`, `notes/`) are always committed separately
from `verification/` so the two can be split later.

## Why: the drift evidence

[OBS 2026-10-06] Every fact copied into `notes/` on 2026-10-05 had gone stale or
was wrong by 2026-10-06, while the `verification/` document it was copied from
was maintained:

- `durable/prefill-decode-…invariants.md`: paths under `tpu_sync/kv_cache/`
  for files that live under `tpu_sync/core/`; `BufferPool::Lease` (the pool is
  `StagingBlockAllocator`); `Transfer/Manager.lean`; theorem names
  `Receive.sound_completion`, `Receive.MissingCancelRecheck`,
  `Session.invariant_preserved`, `MultiRequest.hbm_exclusive_ownership` — none
  exist. Real names: `Session.Consistent`, `Receive.trace_finish_between_locks`,
  `ReceivePoll.trace_poll_skips_metrics`, `MultiRequest.system_data_correct`.
- `durable/lean-step-models-…md`: `Common/Tactics.lean` with `unpack_step` /
  `reachable_invariant` / `StepPreserves`, and `docs/test_suite_correspondence.md`
  — none exist.
- `durable/controller-…traps.md`: `KVCacheStore::Store`, four `findings/F1-…md`
  files, a private R-A…R-F numbering colliding with the README's (already
  superseded in the merge entry).
- `empirical/bughunt-repro-status-at-01ffa3d.md`: invented bazel targets and a
  shape-B test; "12 modules, Lean v4.29.0" (14 modules, v4.34.0);
  `ReadRemote.bug_trace_B_violates` is `ReadRemote.shipping_inFlight`.
- Both `AGENTS.md` files carried the same code map and the same
  active-investigation list as `loose-ends/parked.md`; the re-pin recipe
  existed in five places.

Reading of the pattern: the copies were written from memory of the deliverable,
not from it, and nothing forced them to be re-read when the deliverable moved.
Pointers do not have that failure mode; interpretation ages more slowly than
citations.

## What was done

[FACT] Commits on `experimental`: `aaa9be1` (snapshot of `notes/` + `AGENTS.md`
before the cleanup — the old text is `git show aaa9be1:<path>`), `09b1650`
(`verification/README.md` as the single home of status and sync procedure;
PDF ignored), and the cleanup commit after this entry (both `AGENTS.md`
rewritten, four notes thinned, three stale references in `parked.md` fixed).
`verification/` still has zero links into `notes/`; the fork footprint is
still additive-only (`AGENTS.md`, `notes/`, `verification/`).

[HYP] The thin notes will stay correct longer because each has one
`Canonical:` target and names at most a handful of theorems. Check at the next
upstream sync: grep the notes for theorem and path names and confirm they still
resolve (`grep -o '\`[A-Za-z]*\.[a-z_]*\`'` against `verification/`).

## See also

- 2026-10-06-upstream-50b0774-merge-and-citation-repin.md (the corrections that
  prompted this)
- ../../../AGENTS.md, ../../AGENTS.md (the rules)
