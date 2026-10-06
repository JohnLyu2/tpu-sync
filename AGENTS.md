# TPU Sync fork: formal verification and research notes

notes at: notes/

Two corpora, one home per fact. `verification/` is the human-facing deliverable
(Lean models, docs, findings, tools); `notes/` is the agent research notebook
kept with the `better-than-fish` skill. Facts live in `verification/`; notes
point at them and hold only interpretation, corrections, hypotheses and parked
work. Before non-trivial work read `notes/AGENTS.md`, the last entry of
`notes/sessions.md`, and `notes/loose-ends/parked.md`.

## Project triggers

- "verify lean" / "build proofs" — `cd verification && lake build` (toolchain pinned in `verification/lean-toolchain`).
- "sync upstream" / "re-pin" — follow `verification/README.md` §"Maintenance after an upstream sync".

## Code map

- Transfer sessions: `tpu_sync/core/transfer_send_session.{h,cc}`, `tpu_sync/core/transfer_receive_session.{h,cc}`
- Transfer manager, stats polling (`CompleteReadWithDetails`), host-staging pool (`StagingBlockAllocator`): `tpu_sync/core/kv_cache_manager_with_transfer.{h,cc}`; staging memory `tpu_sync/core/host_memory_allocator.{h,cc}`
- TCP block transport: `tpu_sync/transport/block_transport.{h,cc}`
- KV-cache store, host offload, store RPC service/client: `tpu_sync/kv_cache/{kv_cache_store,host_offload_backend,kv_cache_store_service,kv_cache_store_client}.{h,cc}`
- Raiden controller and remote leases: `tpu_sync/core/controller/raiden_controller.{h,cc}`
- Lean models `verification/TpuSyncVerify/` (`Common/`, `Transfer/`, `Controller/`); docs `verification/docs/`; bug-hunt reports, reproducers and patches `verification/findings/`; citation tool `verification/tools/repin_citations.py`

## Conventions

- Citation baseline: stated once in `verification/README.md` §Status; every file under `verification/` names the commit it cites. Notes carry their own version stamp.
- Fork footprint is additive-only (`AGENTS.md`, `notes/`, `verification/`); never edit upstream files, so syncs stay conflict-free.
- Commit agent-facing files (`AGENTS.md`, `notes/`) separately from `verification/` changes.
