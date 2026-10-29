# TPU Sync fork: formal verification and research notes

notes at: notes/

Two corpora, one home per fact. `tpu_sync/formal_verification/` is the human-facing deliverable
(Lean models, docs, tools), alongside fork-only `findings/`, `agents/`, and `slides/` at the repo root; `notes/` is the agent research notebook
kept with the `better-than-fish` skill. Facts live in `tpu_sync/formal_verification/` and `findings/`; notes
point at them and hold only interpretation, corrections, hypotheses and parked
work. Before non-trivial work read `notes/AGENTS.md`, the last entry of
`notes/sessions.md`, and `notes/loose-ends/parked.md`.

## Project triggers

- "verify lean" / "build proofs" — `cd tpu_sync/formal_verification && lake build && python3 tools/resolve_anchors.py --check` (toolchain pinned in `tpu_sync/formal_verification/lean-toolchain`).
- "sync upstream" / "re-pin" — merge upstream into `main` with a merge commit (never squash/rebase), run `python3 tpu_sync/formal_verification/tools/resolve_anchors.py --diff <old> <new>`, inspect any `MODIFIED` or `FAIL` anchors, run `python3 tpu_sync/formal_verification/tools/resolve_anchors.py --apply --check`, update the baseline commit in `tpu_sync/formal_verification/README.md` §"How the C++ is cited", run `lake build`, and append one row to `notes/upstream-rechecks.md` (add a `notes/journal/` entry only if a model or assumption changed; do not re-stamp `notes/durable/` or `notes/empirical/` unless an upstream change invalidates a claim there; see `tpu_sync/formal_verification/docs/conventions.md`).

## Code map

- Transfer sessions: `tpu_sync/kv_cache/transfer_send_session.{h,cc}`, `tpu_sync/kv_cache/transfer_receive_session.{h,cc}` (moved from `tpu_sync/core/` in upstream `5afe1ef`, 2026-10-07)
- Transfer manager, stats polling (`CompleteReadWithDetails`): `tpu_sync/kv_cache/kv_cache_manager_with_transfer.{h,cc}` (`tpu_sync/core/kv_cache_manager_with_transfer.h` is a forwarding shim); host-staging pool `StagingBlockAllocator`: `tpu_sync/core/staging_arena.{h,cc}` (moved there in upstream `fc8cff9`, 2026-10-12); staging memory `tpu_sync/core/host_memory_allocator.{h,cc}`
- TCP block transport: `tpu_sync/transport/block_transport.{h,cc}`, `tpu_sync/transport/block_transport_session.{h,cc}`
- KV-cache store, host offload, store RPC service/client: `tpu_sync/kv_cache/{kv_cache_store,host_offload_backend,kv_cache_store_service,kv_cache_store_client}.{h,cc}`
- Raiden controller and remote leases: `tpu_sync/core/controller/raiden_controller.{h,cc}`
- Lean models `tpu_sync/formal_verification/TpuSyncVerify/` (`Common/`, `Transfer/`, `Controller/`; modules over ~1000 lines are an umbrella `X.lean` holding the docstring and source map over `X/{Model,Lemmas,Invariant,Progress,Frame,Traces}.lean`); docs `tpu_sync/formal_verification/docs/`; tools `tpu_sync/formal_verification/tools/{resolve_anchors.py,run_lean.sh}`. `tpu_sync/formal_verification/` is self-contained and mirrors what lands upstream. Fork-only, at the repo root: bug-hunt reports, reproducers and patches `findings/`; Lean-backed Q&A and code-reasoning subagent `agents/tpu-sync-lean-helper/`; slides `slides/`

## Conventions

- Citation baseline: stated once in `tpu_sync/formal_verification/README.md` §"How the C++ is cited". Lean modules and `docs/*.md` cite C++ symbols (`Class::Method`), code fragments, and GTest `Suite.TestName`s in prose and keep exact line spans inside `<!-- source-map:begin --> ... <!-- source-map:end -->` tables resolved by `tpu_sync/formal_verification/tools/resolve_anchors.py`. Findings (`findings/`) are frozen at their confirmation commit. Notes carry their own version stamp.
- Fork footprint is additive-only (`AGENTS.md`, `notes/`, the new directory `tpu_sync/formal_verification/`, `findings/`, `agents/`, `slides/`, plus the fork callout at the top of `README.md`); never edit other upstream files, so syncs stay conflict-free. Nothing under `tpu_sync/formal_verification/` may link into or mention `findings/`, `agents/`, `slides/` or this fork (`tpu_sync/formal_verification/docs/conventions.md` §"Describe the code as it is").
- Commit agent-facing files (`AGENTS.md`, `notes/`) separately from `tpu_sync/formal_verification/` changes.
