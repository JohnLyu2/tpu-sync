# Project: TPU Sync & Formal Verification Notes

notes at: notes/

The `better-than-fish` skill governs how to read, add, and maintain research notes for this repository. Before starting non-trivial research, concurrency auditing, or Lean modeling, check `notes/AGENTS.md`, `notes/sessions.md`, and `notes/loose-ends/parked.md`.

## Project-specific triggers

- "verify lean" / "build proofs" — run `lake build` inside `verification/` (`leanprover/lean4:v4.34.0`, per `lean-toolchain`).
- "note this" / "save this" — record to `notes/journal/YYYY-MM/` or `notes/durable/` per `better-than-fish`.
- "park this" — append a 5-field entry to `notes/loose-ends/parked.md`.
- "what do we know about X" — search `notes/durable/`, `notes/empirical/`, and `notes/journal/` and synthesize with provenance markers.

## Code locations to anchor citations

- Tree = upstream `50b0774` merged into `experimental` as `8f03107` (2026-10-06; local tag `upstream-main-2026-10-06`). Every citation under `verification/` (Lean modules, `docs/`, `findings/`) is to `50b0774`; notes dated before 2026-10-06 cite `01ffa3d` (line-shift table in `notes/journal/2026-10/2026-10-06-upstream-50b0774-merge-and-citation-repin.md`). After the next sync: `cd verification && python3 tools/repin_citations.py <old> <new>` (dry run, then `--apply`; hand-check wrapped citation lists), update the commit sentence in each module preamble, `README.md`, `docs/*/*.md` and `findings/*.md`, re-check the two `findings/` patches with `git apply --check`, add a row to `docs/transfer/prefill_decode.md` §"Upstream re-checks".
- C++ KV-cache transfer engine:
  - Send / Receive sessions: `tpu_sync/core/transfer_send_session.{h,cc}`, `tpu_sync/core/transfer_receive_session.{h,cc}`
  - Manager, stats polling (`CompleteReadWithDetails` / `CompleteReadRaw`) & host-staging pool (`StagingBlockAllocator`): `tpu_sync/core/kv_cache_manager_with_transfer.{h,cc}`; staging memory `tpu_sync/core/host_memory_allocator.{h,cc}`
  - TCP block transport: `tpu_sync/transport/block_transport.{h,cc}` (`HandleIncomingPush`, `begin/end_incoming_push` delegate calls)
- Disaggregated KV store & Raiden controller:
  - Local/global store & host offload: `tpu_sync/kv_cache/kv_cache_store.{h,cc}`, `tpu_sync/kv_cache/host_offload_backend.{h,cc}`, `tpu_sync/kv_cache/kv_cache_store_service.{h,cc}`, `tpu_sync/kv_cache/kv_cache_store_client.{h,cc}`
  - Controller & remote leases: `tpu_sync/core/controller/raiden_controller.{h,cc}`
- Lean 4 formalization & bug-hunt harness:
  - Lean package root: `verification/` (`verification/TpuSyncVerify.lean`)
  - Transfer models & proofs: `verification/TpuSyncVerify/Transfer/`
  - Controller models & bug witnesses: `verification/TpuSyncVerify/Controller/ReadRemote.lean`
  - Bug-hunt reports: `verification/findings/` (`README.md` §F1–F4, `filed_bugs.md`, two reproducer tests + patches)
  - Citation re-pin tool: `verification/tools/repin_citations.py`

## Active investigations

Listed in `notes/loose-ends/parked.md`. Quick view:

- Audit `KVCacheStoreClient::Fetch` missing RPC deadline + immediate staging free on transport error in `LoadRemoteBlocks` (~45 min)
- Translate Lean regression traces (`trace_finish_between_locks`, `trace_poll_before_callbacks`, `trace_reseat_at_finish`) into C++ `transfer_session_test.cc` tests (~2 hrs)
- Model `block_transport.cc` multi-sender per-block completion accounting in Lean to discharge `Receive` assumptions A1/A3/A4 (~half-day)
- Propagate the real push-failure status through `EndIncomingPush` instead of a flat `InternalError("Incoming push failed")` (`4efb0dd`; ~30 min)
- Citation drift check in CI: `repin_citations.py` dry run must report no `shift`/`CHECK` (~1 hr)
