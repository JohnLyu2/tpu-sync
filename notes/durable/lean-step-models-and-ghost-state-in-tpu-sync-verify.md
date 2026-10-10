# Lean step models in TpuSyncVerify: how they are built, how to start one

Canonical: `verification/docs/conventions.md` (one executable `step`,
transcribe-don't-paraphrase, ghost fields, module layout, citations,
assumptions, properties and proofs, replay/search/mutants, naming) and
`verification/TpuSyncVerify/Common/{System,ModelCheck}.lean`. This note is the
working method distilled from using them.

**Verified against:** `verification/` at `09b1650` (14 modules,
`leanprover/lean4:v4.34.0`).

## Working method

[FACT] One `step : S → Ev → Option S` per model is the definition. Inductive
proofs (`Reachable`), replayed traces (`run … = some s` by `decide`) and
bounded search (`ModelCheck.check`) all execute that same function, so the
checker cannot drift from the spec. When a proof and a replayed C++ test
disagree, the test is the C++: fix the model or the claim, never the trace.

[FACT] Memory is symbolic (`Cell := .blank | .kv l | .junk`) and release is
adversarial: freeing a buffer overwrites it with `.junk` at once, so a read that
completes after a release shows up as `.junk` in decode HBM instead of as a
timing argument. Ghost latches turn temporal claims ("the pull was still
running when the caller got its blocks back") into state predicates
(`ReadRemote.NoWriteAfterRelease`). To audit a new subsystem, copy that shape:
an `Impl`/`Config` toggle for shipping vs. fixed behaviour, a latch for the
hazard, then `ModelCheck.check` yields the counterexample for the report and
`.safe` for the fix in one file (`ReadRemote.shipping_counterexample`,
`ReadRemote.deferred_settle_is_safe` — 263 lines for F2, both shapes and the fix).

[FACT] Validation runs in both directions at `lake build`: the transfer path's
C++ unit tests and E2E tests are replayed as `decide` traces (positive — the
model is not over-constrained; `prefill_decode.md` §"Test suite
correspondence"), and critical guards are removed one at a time in mutant
configurations to confirm a property breaks (negative — the proofs are not
vacuous; `prefill_decode.md` §"Counterfactual mutants").

## Why this matters

The 2026-09 bug hunt found its four defects by replaying code paths, and the
2026-10 transfer-path audit found none; both results were believable only
because the traces execute the same `step` the theorems are about. A model
without replayed traces is a drawing; a proof without mutants may be vacuous.

## Correction trail

[SUPERSEDED → ../journal/2026-10/2026-10-06-notes-reorganization-one-home-per-fact.md]
The 2026-10-05 version described a 3-step proof template via
`Common/Tactics.lean` (`unpack_step`, `reachable_invariant`, `StepPreserves`)
and a `docs/test_suite_correspondence.md`; none of these exist. The real
template is `conventions.md` §"Properties and proofs"; the correspondence is a
section of `prefill_decode.md`. Old text:
`git show aaa9be1:notes/durable/lean-step-models-and-ghost-state-in-tpu-sync-verify.md`.

## See also

- prefill-decode-transfer-settle-and-layer-readiness-invariants.md
- controller-read-remote-and-kv-store-pinning-concurrency-traps.md
