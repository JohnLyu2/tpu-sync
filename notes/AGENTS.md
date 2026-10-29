# TPU Sync research notes

Kept with the `better-than-fish` skill (`SKILL.md` and `references/format.md`
define markers, tiers and triggers). Repo entry point, code map and commit
conventions: `../AGENTS.md`.

## Maintenance rules (keep cost O(1))

- **One home per fact.** Facts, symbol spans and module/test inventories live in
  `tpu_sync/formal_verification/` and `findings/`. A `durable/` or `empirical/`
  note starts with `Canonical:` naming the deliverable that owns the facts, then
  keeps only what that document does not say: workstation/build recipes,
  interpretation, "do not re-investigate" traps, and correction trails. Cite
  symbols (`Class::Method`), never raw `file:line` spans or file/module counts.
- **Frozen `Read at:` stamps (no sync re-stamping).** Every note states the
  commit(s) its claims were actually read or run against, and keeps that stamp
  frozen until an upstream change invalidates a claim in the note. Routine
  upstream syncs touch **only** `notes/upstream-rechecks.md` (one row per sync;
  add a `journal/YYYY-MM/` entry only when a model or assumption changed).
  Unstamped journal notes before 2026-10-06 are at `01ffa3d`; full pin history
  is `notes/upstream-rechecks.md`.
- **Evict closed items from `loose-ends/parked.md`.** `parked.md` holds *open*
  work only. When an item is `done`, `closed`, or `retired`, delete it from
  `parked.md` (any lasting takeaway belongs in `journal/`, `upstream-rechecks.md`,
  or the deliverable).
- **Keep `sessions.md` a short rolling index.** Each entry in `sessions.md` is
  ≤ 2–3 lines (date, theme, commit/journal/finding pointers, plus one-line user
  correction if any — never duplicate journal narratives). Roll completed months
  to `sessions/YYYY-MM.md` so `sessions.md` stays under ~50 lines.
- **Markers:** `[FACT]` source-grounded or Lean-proved (`durable/`); `[EMP]`
  reproducible observation with a frozen `Read at:` stamp (`empirical/`);
  `[OBS YYYY-MM-DD]` and `[HYP]` (`journal/YYYY-MM/`); `[OPEN]` with a parked
  entry; `[SUPERSEDED → path]` marks a wrong or graduated note in place, never
  silently deleted.

## Live notes index

- `durable/prefill-decode-transfer-settle-and-layer-readiness-invariants.md` —
  why the settle protocol and `ExecuteLayerH2d` lock window matter; shortcuts
  already ruled out. Canonical: `tpu_sync/formal_verification/docs/transfer/prefill_decode.md`.
- `durable/lean-step-models-and-ghost-state-in-tpu-sync-verify.md` — working
  method for executable `step` models, ghost latches, replay + mutants.
  Canonical: `tpu_sync/formal_verification/docs/conventions.md`.
- `durable/controller-read-remote-and-kv-store-pinning-concurrency-traps.md` —
  shared shape of controller/store hand-off races and refuted look-alikes.
  Canonical: `findings/README.md`.
- `empirical/oss-bazel-test-recipe.md` — building and running hardware-free C++
  tests from the fork (OSS Bazel, `clang`, `libibverbs-dev`).
- `empirical/prefill-decode-caller-tpu-inference-raiden-connector.md` —
  `tpu-inference` + `vllm` caller boundary and settled C1 non-fixes.
- `empirical/reshard-callers-vllm-and-sglang-torchtpu.md` — `vllm-torchtpu` +
  `sglang-torchtpu` retry/topology/block-pool invariants and local clone paths.
