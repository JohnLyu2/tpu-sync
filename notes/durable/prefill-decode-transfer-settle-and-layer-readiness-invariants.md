# Prefill-to-decode transfer: settle protocol and layer readiness

Canonical: `verification/docs/transfer/prefill_decode.md` (model, properties →
theorems, correspondence, observations, upstream re-checks) and the module
docstrings under `verification/TpuSyncVerify/Transfer/`. The facts and their
citations live there; this note is what to keep in mind when touching the code.

**Verified against:** tpu-sync `50b0774` (the canonical doc's baseline).

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

[FACT] Receive-side completion is sound only under a transport ordering
assumption (`Receive` A4: `OnLayerReceived` for the last layer runs before
`OnBlocksReceived`, on the same reader thread). That is an assumption about
`block_transport.cc`, not a theorem; discharging it is parked
(`../loose-ends/parked.md`; `prefill_decode.md` §"Boundary assumptions").

[FACT] `CompleteReadWithDetails` (`poll_stats()`, Lean `.pollReady`) can finish a
receive before its last H2D callbacks run. The
outcome is unaffected (`done` still waits through `in_flight_`); only the
per-transfer metrics are skipped (`Recv.trace_poll_skips_metrics`). Not
a bug — do not re-open it as one; the audit is `ReceivePoll.lean` and
`verification/findings/README.md` §"Observations on the prefill-to-decode path (non-bugs at `50b0774`)".

[FACT] Consumer-side staging admission is first-come-first-served with no
per-peer bound: `StartRead` takes a slot before the handshake and keeps it
until `Lifecycle.settleLocked` (`FinishLocked` / `EndRecvOpLocked` →
`ReleaseStagingLocked`), so one producer that accepts and never answers pins the
pool and every other producer's reads are *rejected* (`failed_recving_`), not
delayed. Owner-acknowledged (their test is parked as `DISABLED_`); confirmed
and fixed as F5, canonical `verification/findings/README.md` §F5, patch
`verification/findings/per_peer_staging_admission.patch`, guarantee
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
2026-10-06 it cited paths that do not exist (`tpu_sync/kv_cache/transfer_*_session.cc`
— they are under `tpu_sync/core/`; `BufferPool::Lease` — the pool is
`StagingBlockAllocator`; `Transfer/Manager.lean`) and theorem names that do not
exist (`Receive.sound_completion`, `Receive.MissingCancelRecheck`,
`Session.invariant_preserved`, `MultiRequest.hbm_exclusive_ownership`). The
facts were right in `prefill_decode.md` the whole time. Old text:
`git show aaa9be1:notes/durable/prefill-decode-transfer-settle-and-layer-readiness-invariants.md`.

## See also

- lean-step-models-and-ghost-state-in-tpu-sync-verify.md
- controller-read-remote-and-kv-store-pinning-concurrency-traps.md
