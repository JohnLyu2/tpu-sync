# Upstream `0ac16d1` sync: NotifyForRead throws, connection-release window, phases, allocator moved, F6 fixed

Load this when the tree is at or past `0ac16d1`, when a note cites `1fa06d1`
line numbers for `send.cc`/`mgr.cc`/the staging allocator, or before the next
upstream sync.

[FACT] Upstream `google/tpu-sync` `main` = `0ac16d1` (2026-10-16, 48 commits
past `1fa06d1`). The modelled `step` functions are unchanged. What changed and
where it is recorded: `verification/docs/upstream_rechecks.md` (2026-10-16
row), `Send.lean` A7 (the `EndSendOp` connection-release window, `08048d5`),
the `Phase`/`failedPhase` sections at the end of `Send.lean` and `Receive.lean`
(`TransferDetails`, `5a73483`), `UuidTable.lean`/`BlockOrdering.lean` wording
for `NotifyForRead` throwing (`80e2c52`), `findings/README.md` §F5 (patch
retired), §F6 (fixed in `8653373`), §History.

[FACT] `StagingBlockAllocator` lives in `tpu_sync/core/staging_arena.{h,cc}`
since `fc8cff9`; the pool-lease forwarders it had at `1fa06d1` are gone (the
reshard sessions call `KVCacheManagerBase` directly after the F6 fix). The
repin tool has `arena.cc`/`arena.h` aliases. Every `mgr.cc:12xx`/`13xx`
allocator citation in notes dated before 2026-10-16 is stale.

[OBS 2026-10-16] Decisions taken for this sync (user): A — document the
`EndSendOp` window, do not model it; B — write trace theorems for the new
tests (done as derived `phase`/`failedPhase` functions, no new state: `phase`
is `CurrentPhaseLocked` on the model, `failedPhase s e` is the argument the
failing event passes to `FinishLocked`, explicit `kD2hPhase`/`kPushPhase`/
`kH2dPhase` at the callbacks, derived otherwise); C — retire
`per_peer_staging_admission.patch` rather than re-base it onto
`staging_arena.cc` (proof and write-up kept; the diff is in history at tag
`upstream-main-2026-10-10`); D — stash → merge → pop as before.

[OBS 2026-10-16] Re-pin mechanics this time: 97 `CHECK` + 48 other-commit
lines. What worked: build an old→new anchor dictionary per file from the new
source (function headers via grep, then `awk` line dumps of the bodies) and
apply it with a regex over `send.cc:OLD` / `` `.cc:OLD`` `` tokens, then verify
by printing the code at every cited line. For test files, regenerate the
`name → [TEST line, closing brace]` table from the new file and cross-check
every `name … file:range` pair in the corpus; 13 mismatches surfaced that way
(4 false positives: multi-test sentences and deliberate sub-ranges). The
send-row trap (`.cc`/`.h` default = recv in `Session.lean` and the docs) was
handled up front. The routing-index rows in `prefill_decode.md` were rewritten
whole from the anchor tables rather than patched citation by citation.

[OBS 2026-10-16] `a6eaa5a` ("DMA failures not propagated to PollError/Await")
only touches `raw_transfer_core.h`'s poll/await helpers used by the
controller's `TransferBuffers`; the sessions use `OnReady` callbacks whose
status argument was already correct. No model impact; worth remembering when
the commit title suggests otherwise.

[HYP] The `Details…` tests make the failed *phase* an engine-visible outcome.
If vLLM/SGLang start branching on `phase` (retry on `connect`, not on `h2d`),
`phase` should become state in `Pipeline.lean`'s publication, not a derived
function — then `Publication` would carry `(Bool, Phase)`.

## Related
- `verification/docs/upstream_rechecks.md`
- `verification/TpuSyncVerify/Transfer/PrefillDecode/Send.lean` (A7, `Phase`)
- `findings/README.md` §F5, §F6, §History
- `2026-10-10-upstream-1fa06d1-sync.md`
