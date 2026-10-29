# Prefill-to-decode transfer: settle protocol and layer readiness

Canonical: `tpu_sync/formal_verification/docs/transfer/prefill_decode.md` (model, properties →
theorems, correspondence, observations, upstream re-checks) and the module
docstrings under `tpu_sync/formal_verification/TpuSyncVerify/Transfer/`. The facts and their
citations live there; this note is what to keep in mind when touching the code.

**Read at:** tpu-sync `42dda54` (frozen stamp; live baseline and anchors live in the canonical doc).

## What to keep in mind

[FACT] Session safety rests on one small protocol, not on any single lock:
`draining_`, `done_`, `in_flight_` and the host-staging lease move together
(`done → draining`, `done → in_flight_ == 0`; `Lifecycle.Consistent`). Every
"is this callback safe?" question in `TransferSendSession` /
`TransferReceiveSession` reduces to: is the op counted (`TryBeginRecvOp` /
`++in_flight_` under `mu_`, Lean `Lifecycle.beginOp`)
before `mu_` is released, and un-counted (`EndRecvOpLocked` / `EndSendOpLocked`) on every exit path,
early returns included? The regression for the one non-obvious exit is
`Recv.trace_finish_between_locks` (`ExecuteLayerH2d` re-checking
`done_ || draining_` after its unlocked window).

[FACT] Receive-side completion is sound under a transport ordering and
stream-accounting contract (`Receive` A4: on the socket path, `OnLayerReceived`
for the completing stream of a layer runs before `OnBlockShardsReceived` on the
same reader thread, and every shard counter reaches `total_blocks_ * num_layers`
only after every layer was dispatched — the coarsening is discharged in
`Transport.lean` `NetworkSound` under `Transport` A4 honest senders; on the
Peregrine path added in `86d4506`, `OnRecvNetworkComplete` is called immediately
after the `num_layers()`-th `OnLayerReceived`; see `prefill_decode.md`
§"Boundary assumptions").

[FACT] `CompleteReadWithDetails` (`poll_stats()`, Lean `.pollReady`) can finish a
receive before its last H2D callbacks run. The
outcome is unaffected (`done` still waits through `in_flight_`); only the
per-transfer metrics are skipped (`Recv.trace_poll_skips_metrics`). Not
a bug — do not re-open it as one; the audit is `ReceivePoll.lean` and
`findings/README.md` §"Observations on the prefill-to-decode path (non-bugs at `50b0774`)".

[FACT] Consumer-side staging admission is first-come-first-served with no
per-peer bound: `StartRead` takes a slot before the handshake and keeps it
until `Lifecycle.settleLocked` (`FinishLocked` / `EndRecvOpLocked` →
`ReleaseStagingLocked`), so one producer that accepts and never answers pins the
pool and every other producer's reads are *rejected* (`failed_recving_`), not
delayed. Owner-acknowledged (their test is parked as `DISABLED_`); confirmed
as F5, canonical `findings/README.md` §F5 (the `per_peer_staging_admission.patch`
was validated on `50b0774` and retired on 2026-10-16 when `StagingBlockAllocator`
moved to `tpu_sync/core/staging_arena.{h,cc}` in `fc8cff9`), guarantee
`PeerIsolation.reachable_quota_admits_healthy` (cap `c` reserves
`numSlots − c` slots for other peers; nothing more). Two shortcuts are
already ruled out, do not re-derive them: allocating staging lazily after the
peer answers (the pull request carries the host block ids), and reclaiming the
slot on cancel (release before `inFlight = 0` lets the producer write into
reused host blocks).

## Why this matters

A change to the lock order in `ExecuteLayerH2d`, to callback order in the
transport, or to the `++in_flight_` / `End*OpLocked` balance can corrupt decode HBM or
leave a session holding staging forever. Before changing those paths, read the
matching row of `prefill_decode.md` §"C++ to Lean routing index" and
§"Counterfactual mutants" — the mutant rows say which C++ guard each property depends on.

## Correction trail

[SUPERSEDED → ../journal/2026-10/2026-10-06-notes-reorganization-one-home-per-fact.md]
The 2026-10-05 version copied the invariants with their citations. By
2026-10-06 it cited paths that did not exist at `50b0774` (`tpu_sync/kv_cache/transfer_*_session.cc`
— they were under `tpu_sync/core/` until `5afe1ef` moved them to `tpu_sync/kv_cache/` on 2026-10-07; `BufferPool::Lease` — the pool is
`StagingBlockAllocator`; `Transfer/Manager.lean`) and theorem names that do not
exist (`Receive.sound_completion`, `Receive.MissingCancelRecheck`,
`Session.invariant_preserved`, `MultiRequest.hbm_exclusive_ownership`). The
facts were right in `prefill_decode.md` the whole time. Old text:
`git show aaa9be1:notes/durable/prefill-decode-transfer-settle-and-layer-readiness-invariants.md`.

## See also

- lean-step-models-and-ghost-state-in-tpu-sync-verify.md
- controller-read-remote-and-kv-store-pinning-concurrency-traps.md
