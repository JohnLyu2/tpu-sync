# Controller `ReadRemote` and KV-store pinning: confirmed defects, refuted look-alikes

Canonical: `verification/findings/README.md` (F1–F4 with evidence levels,
reproducers, candidate fixes, §"Refuted or closed", §History),
`verification/findings/filed_bugs.md`, `verification/docs/controller/read_remote.md`
and `verification/TpuSyncVerify/Controller/ReadRemote.lean`. This note is what
to carry into the next audit of `RaidenController`, `KVCacheStore`,
`HostOffloadBackend` or `KVCacheStoreService`.

**Verified against:** tpu-sync `50b0774` (`raiden_controller.cc` byte-identical
to `01ffa3d`; the F1 regions of `kv_cache_store.cc` unchanged, lines moved).
None fixed upstream; the F4 fix PR #1105 is open.

## What to carry forward

[FACT] The four defects share one shape: a resource (host-block pin, staging
allocation, lease id) is handed to another thread or peer, and the hand-off is
not ordered against the release path — `Evict`/`Insert` running without
`KVCacheStore::mutex_` (F1), the deadline thread's `Settle` (F2, F3), early
`return`s that skip the cleanup block (F4). In these files ask first "who can
release this while it is in flight, and what orders them?", not "which lock is
missing?".

[FACT] F2 has two shapes and the obvious fix closes only one. Checking
`settled` before issuing the pull stops shape A (`ReadRemote.lateIssue`) and
leaves shape B (`ReadRemote.inFlight`: the deadline fires during the pull);
deferring the deadline's settle while a pull is in flight closes both
(`ReadRemote.deferred_settle_is_safe`, exhaustive search). Shape B has no C++
reproducer; it is a Lean result (`ReadRemote.shipping_inFlight`).

[FACT] Reachability bounds the urgency. `RaidenController::ReadRemote` is
reachable only through the public API (`KVCacheStore::ReadRemote`, bound as
`read_remote` in the torch/jax modules) — no in-tree production caller — so
F1/F2/F3 are latent until a client calls it. F4's orphaned-copy half is
reachable from production `Fetch`/`WriteRemote`
(`findings/README.md` §F4 Reachability).

## Do not re-investigate

Settled, with evidence, in `findings/README.md` §"Refuted or closed" — use its
labels: R-A premature `IsReadyToComplete` (transport ordering A4); R-B stale
same-uuid push (not reachable from vLLM); R-C `RequestBlockRegistry` lifecycle;
R-D `WriteRemote` landing blocks at the deadline (`DeadlineLoop` defers them);
R-E local `Load` eviction mid-copy (pinned before `Load`); R-F Fetch-source
unpin before the pull ends.

Settled in the transfer-path model (`prefill_decode.md` §Outcome): an
`ExecuteLayerH2d` early return leaking an op (`EndRecvOpLocked` runs on that
path; `Receive.trace_finish_between_locks`); a second `FinishLocked` from `Poll`
(no-op once `draining_`; only metrics skipped); a `StartD2hTransfer` callback
after staging is freed (the op is counted before `mu_` is released; `Send`
staging-integrity property).

## Correction trail

[SUPERSEDED → journal/2026-10/2026-10-06-upstream-50b0774-merge-and-citation-repin.md]
(2026-10-06) The 2026-10-05 version named `KVCacheStore::Store` as the
unsynchronised evictor (it does not exist; the writers are `Evict` and
`Insert`), linked four `findings/F1-…md` … `F4-…md` files that never existed,
and used its own R-A…R-F numbering that disagreed with the README's. The facts
were right in `findings/README.md` throughout. Old text:
`git show aaa9be1:notes/durable/controller-read-remote-and-kv-store-pinning-concurrency-traps.md`.

## See also

- prefill-decode-transfer-settle-and-layer-readiness-invariants.md
- lean-step-models-and-ghost-state-in-tpu-sync-verify.md
- ../empirical/bughunt-repro-status-at-01ffa3d.md
