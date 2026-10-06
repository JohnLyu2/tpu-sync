# Project: TPU Sync research & verification notes

notes at: notes/

The `better-than-fish` skill governs how to add and maintain notes in this directory. Re-read its `SKILL.md` and `references/format.md` for conventions.

## Marker & tier conventions

- `[FACT]` — source-grounded (`path:line` + snippet) or Lean-proved claim; lives in `durable/`
- `[EMP]` — reproducible empirical / test result with `Verified against:` commit header; lives in `empirical/`
- `[OBS YYYY-MM-DD]` — dated observation from a specific run/trace; lives in `journal/YYYY-MM/`
- `[HYP]` — untested or partial hypothesis; lives in `journal/YYYY-MM/`
- `[OPEN]` — known unknown with a corresponding 5-field entry in `loose-ends/parked.md`
- `[SUPERSEDED → filename.md]` — never delete wrong claims; mark in place and cross-link

## Code locations to anchor citations

- Tree = upstream `50b0774` merged as `8f03107` (2026-10-06; local tag `upstream-main-2026-10-06`). Every citation under `verification/` (Lean modules, `docs/`, `findings/`) is at `50b0774` (re-pin after a sync with `verification/tools/repin_citations.py OLD NEW --apply`, then hand-check wrapped lists); notes dated before 2026-10-06 are at `01ffa3d` unless they say otherwise (`journal/2026-10/2026-10-06-upstream-50b0774-merge-and-citation-repin.md` has the line-shift table)
- Transfer sessions: `tpu_sync/core/transfer_send_session.{h,cc}`, `tpu_sync/core/transfer_receive_session.{h,cc}`
- Transfer manager and host-staging pool (`StagingBlockAllocator`): `tpu_sync/core/kv_cache_manager_with_transfer.{h,cc}`; staging memory `tpu_sync/core/host_memory_allocator.{h,cc}` (there is no `buffer_pool.{h,cc}`)
- Network transport: `tpu_sync/transport/block_transport.{h,cc}` (+ `block_transport_delegate.h`, `lib/socket_transport_adapter.{h,cc}`)
- KV cache store & offload: `tpu_sync/kv_cache/kv_cache_store.{h,cc}`, `tpu_sync/kv_cache/host_offload_backend.{h,cc}`, `tpu_sync/kv_cache/kv_cache_store_service.{h,cc}`
- Raiden controller: `tpu_sync/core/controller/raiden_controller.{h,cc}`; control planes `tpu_sync/core/{tcp,grpc}_control_plane_backend.cc`
- Lean 4 models: `verification/TpuSyncVerify/` (`Common/`, `Transfer/`, `Controller/`)
- Bug-hunt reports: `verification/findings/`

## Durable notes index

- `prefill-decode-transfer-settle-and-layer-readiness-invariants.md` — 3-stage D2H/H2H/H2D pipeline, settle invariants, `ExecuteLayerH2d` lock window, `OnLayerReceived` ordering (A4), and `ReceivePoll` metrics skip
- `lean-step-models-and-ghost-state-in-tpu-sync-verify.md` — `System S Ev` pattern, ghost state, mutant testing, and end-to-end `Pipeline` / `MultiRequest` theorems
- `controller-read-remote-and-kv-store-pinning-concurrency-traps.md` — confirmed concurrency bugs (F1–F4) and 6 refuted look-alike traps (R-A..R-F)

## Active investigations

Tracked in `loose-ends/parked.md`:
- `KVCacheStoreClient::Fetch` missing deadline + `LoadRemoteBlocks` staging free on transport error
- Lean witness trace translation into C++ `transfer_session_test.cc`
- Discharging `Receive` transport assumptions A1/A3/A4 via a Lean `BlockTransport` model
- Propagate the real push-failure status instead of `InternalError("Incoming push failed")` (`4efb0dd`)
- Citation drift check in CI (`repin_citations.py` dry run must report no `shift`/`CHECK`)
