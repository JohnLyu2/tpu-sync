# TPU Sync research notes

Kept with the `better-than-fish` skill; its `SKILL.md` and `references/format.md`
define the markers, tiers and triggers. Repo entry point, code map and commit
conventions: `../AGENTS.md`.

## Project conventions

- Facts live in `verification/` (docs, findings, Lean docstrings). A `durable/`
  or `empirical/` note is a thin pointer: a `Canonical:` line naming the
  `verification/` document that owns the facts, then only what that document
  does not say — interpretation, "do not re-investigate" guidance, the
  correction trail. Never copy a fact table or a citation list into a note;
  every copy made so far went stale within a week.
- Upstream-sync facts (what changed in cited code, what was re-pinned) go in
  `verification/docs/upstream_rechecks.md` and
  `verification/findings/README.md` §"History"; the journal records the delta
  of understanding, corrections and tooling lessons, with a link.
- `loose-ends/parked.md` is the only backlog.
- Version stamps: every note names the tpu-sync commit its claims were read at.
  Notes dated before 2026-10-06 are at `01ffa3d`; the line-shift table to
  `50b0774` is in `journal/2026-10/2026-10-06-upstream-50b0774-merge-and-citation-repin.md`;
  notes dated 2026-10-06..09 are at `50b0774`; since 2026-10-10 the pin is
  `1fa06d1` and the session/manager sources live under `tpu_sync/kv_cache/`
  (`journal/2026-10/2026-10-10-upstream-1fa06d1-sync.md`).
- Markers as in the skill: `[FACT]` source-grounded or Lean-proved (`durable/`);
  `[EMP]` reproducible result with a "Verified against" stamp (`empirical/`);
  `[OBS YYYY-MM-DD]` and `[HYP]` (`journal/YYYY-MM/`); `[OPEN]` with a parked
  entry; `[SUPERSEDED → file]` marks a wrong claim in place, never deleted.

## Durable notes index

- `prefill-decode-transfer-settle-and-layer-readiness-invariants.md` — why the
  settle protocol and the `ExecuteLayerH2d` lock window matter; what to check
  before touching them. Canonical: `verification/docs/transfer/prefill_decode.md`.
- `lean-step-models-and-ghost-state-in-tpu-sync-verify.md` — how the models are
  built (one executable `step`, ghost latches, replay + mutants) and how to
  start a new one. Canonical: `verification/docs/conventions.md`.
- `controller-read-remote-and-kv-store-pinning-concurrency-traps.md` — the four
  confirmed defects and the look-alikes already refuted. Canonical:
  `verification/findings/README.md`.
