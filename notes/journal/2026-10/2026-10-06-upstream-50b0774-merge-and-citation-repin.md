# Upstream `50b0774` merged; citations re-pinned; what changed and what we had wrong

Load this when the tree is at or past `50b0774`, when re-pinning citations after
the next upstream sync, or when a note cites `01ffa3d` line numbers.

[OBS 2026-10-06] Upstream `google/tpu-sync` `main` = `50b0774` (44 commits past
`01ffa3d`) was merged into `experimental` as `8f03107` (no conflicts: our commits
only touch `verification/`, upstream never does). Local tag
`upstream-main-2026-10-06` = `50b0774`. The user's checkout had *not* been synced
before this (merge-base was still `01ffa3d`, no fetch in the reflog) despite
"I just synced" — check `git merge-base HEAD <upstream>` before trusting that.

[FACT] **One behavioural change in the modelled code since `01ffa3d`: `4efb0dd`
(2026-10-02, "Immediately fail decode receive session when an incoming push
fails").** `end_incoming_push` now takes the push's `absl::Status`; when it is
not OK it runs `recv_session->DeferUnregisterOnSettle(); recv_session->Finish(status);`
*before* `EndRecvOp()` (`tpu_sync/core/kv_cache_manager_with_transfer.cc:239-242`
at `50b0774`). `BlockTransport::HandleIncomingPush`'s `absl::Cleanup` passes
`InternalError("Incoming push failed")` on any early return
(`tpu_sync/transport/block_transport.cc:376-381`); the success path still calls
`EndIncomingPush(uuid)` with the default OK status (`:617`). Before, a failed
push only ended the op and the session lived to its deadline. Upstream test:
`RecvLifecycleTest.FailedIncomingPushImmediatelyFailsSessionAndReleasesStagingBeforeDeadline`
(`kv_cache_manager_with_transfer_send_drain_test.cc:854-882`). Our reading: the
Lean `Receive` model already admits this as the `cancel` then `pushEnd` steps of
`trace_push_lease_pins_staging_on_cancel` (`Finish` while the push's own op is in
flight sets `draining_` and the status; the following `EndRecvOp` takes
`in_flight_` to 0 and settles, releasing staging on the connection worker). No
model change; `Receive.lean` event table and that docstring now say so.

[OBS 2026-10-06] Everything else in the cited code is additive or a refactor:
`completed_at_` set beside every `done_ = true` (`a58a357`, exposed via
`poll_stats_with_details`; set at settle, so unaffected by the `IsReadyToComplete`
metrics skip); `CompleteReadRaw()` is now a wrapper over
`CompleteReadWithDetails()` (`mgr.cc:908-1039` / `:1041-1047`), poll loop
unchanged (`:962-994`, log string still says `CompleteReadRaw`); per-read socket
timeouts in `HandleIncomingPush`, env-gated `TPU_RAIDEN_DECODE_{HANDSHAKE,PAYLOAD}_READ_TIMEOUT_S`,
**off by default** (`e7c933f`; prefill-side handshake/ack timeouts `61b6c76`);
`AsyncPush` returns `tsl::Future`, `SyncPush` removed (`50fa652`, `4e9f0a5`,
`c4ca33c`, `d73d68b`). Unchanged: A4's ordering (`bt.cc:559-561`, `:601-615`,
`OnLayerReceived` before `OnBlocksReceived` on one thread), `StartRead` staging
admission, `IsReadyToComplete`/`AllH2dDoneLocked`, `raiden_controller.cc`
(byte-identical to `01ffa3d`), every cited test file.

[OBS 2026-10-06] Findings status at `50b0774`: none fixed. F4's PR #1105 open,
not merged. `DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer` still disabled
(`control_test.cc:1041`). For the per-peer-admission argument the upstream
timeouts change the framing, not the conclusion: `4efb0dd` frees a slot at once
when a push *fails*, the env timeouts bound how long a *stalled* peer holds one,
nothing bounds how many slots one peer holds.

[OBS 2026-10-06] Line shifts `01ffa3d → 50b0774` (for reading old notes against
the new tree): `transfer_receive_session.cc` +1 after `:49`, +2 after `:370`, +3
after `:394`, +4 after `:473`; `transfer_send_session.cc` +1 after `:173`, +2
after `:192`; `kv_cache_manager_with_transfer.cc` +6…+11 before `StartRead`, +10
inside the poll, +22 after `:1454`; `block_transport.cc` +23…+31 (A4 region
+31); `kv_cache_store.cc` +6 after `:201`, +11 after `:1493` (F1 region
`:1655-1683` → `:1666-1694`); `send_drain_test.cc` +4/+10/+28/+45.
`raiden_controller.cc`, `metrics_collector.cc`, `raw_transfer_core.h`, `hooks.h`,
`kv_cache_store_{service,client}.cc`, `host_offload_backend.cc`, all cited
`*_test.cc` except `send_drain_test.cc`: 0.

## Corrections made while re-pinning (supersedes earlier notes)

[FACT] The F1/F2 reproducers are **not** bazel targets `bughunt_f1_test` /
`bughunt_f2_test`. They are `verification/findings/kv_cache_store_pin_race_test.cc`
(`KVCacheStorePinRaceTest.EvictAndReinsertBetweenLookupAndPinReturnsStaleHostBlockId`)
and `verification/findings/raiden_controller_bughunt_test.cc` (`BugHuntTest.
ReadRemoteDoesNotStartPullAfterDeadlineSettled`, `…TransferBuffersErrorPathDoesNotLeakAutoStagingBlocks`,
`…TransferBuffersDispatchesNoWorkerWhenAnyWorkerIsUnmatched`), built as
`//tpu_sync/kv_cache:kv_cache_store_pin_race_test` and
`//tpu_sync/core/controller:raiden_controller_bughunt_test` via
`verification/findings/build_targets.patch`. **F2 shape B has no C++ test** — it
is Lean-only (`ReadRemote.bug_trace_B_violates`). Supersedes the table in
`bughunt-repro-status-at-01ffa3d.md`. Why misled: the empirical note was
written from the findings' *descriptions* (shape A/B, F1–F4) and the names were
invented to match them instead of read from `findings/README.md:36-50`.

[FACT] `KVCacheStore::Store` does not exist at `01ffa3d` (or `50b0774`). The
callers that evict and re-insert host blocks without `KVCacheStore::mutex_` —
the other half of the F1 race — are `KVCacheStore::Evict` (`kv_cache_store.cc:1840`
at `01ffa3d`, `:1851` at `50b0774`) and `KVCacheStore::Insert` (`:1053` / `:1059`),
as `findings/README.md:87-90` says. Supersedes the F1 paragraph of
`controller-read-remote-and-kv-store-pinning-concurrency-traps.md`. Why misled:
"a concurrent Store" is the natural name for the writer in a lookup/pin race;
nobody opened the file at `:439, 463` (that is `KVCacheStore::Create`).

[FACT] Paths: sessions, manager and controller are `tpu_sync/core/…`
(`tpu_sync/core/controller/raiden_controller.cc`), the transport is
`tpu_sync/transport/block_transport.cc`; there is no `tpu_sync/buffer_pool.{h,cc}`
— host staging is `StagingBlockAllocator` in `kv_cache_manager_with_transfer.{h,cc}`
over `tpu_sync/core/host_memory_allocator.{h,cc}`. Both `AGENTS.md` files had
`tpu_sync/kv_cache/transfer_*` and `tpu_sync/raiden_controller.cc`; fixed today.
There are no `verification/findings/F1-…md` … `F4-…md` files; the reports are
sections of `verification/findings/README.md` plus `filed_bugs.md`.

[FACT] The R-A…R-F labels in `controller-read-remote-and-kv-store-pinning-concurrency-traps.md`
are the note's own and do **not** match `findings/README.md` §"Refuted or
closed": only R-A agrees; note R-B = README R-D (`WriteRemote` deadline), note
R-C = README R-E (`Load` eviction mid-copy); note R-D/R-E/R-F are transfer-session
items that are not in the README at all; README R-B (same-uuid stale push), R-C
(`RequestBlockRegistry`), R-F (Fetch-source unpin) are missing from the note.
Use the README's labels when talking to anyone else.

[FACT] `verification/docs/transfer/prefill_decode.md` Stage-4 row cited
`send.cc:217-291` for `ValidateRequestedBlocks` (that range is inside
`BuildCoalescedCopySpec`; the function is `ValidateRequestedBlocksLocked`,
`send.cc:97-114`) and `copy_spec_builder.h:42-92` for `BuildCoalescedSpec` (no
such file in tpu-sync; `TransferSendSession::BuildCoalescedCopySpec`,
`send.cc:203-232` at `50b0774`). Fixed in `0b3208b`. `BlockOrdering.lean`'s own
citations were right; the doc row was written from memory.

## Tooling

[OBS 2026-10-06] `verification/tools/repin_citations.py OLD NEW [--apply]` maps
every `file:line` citation in the Lean modules and `docs/` through
`git diff -U0 OLD NEW` hunks: 354 rewritten mechanically, 2 hunk-spanning ranges
by hand, 8 spot-checked against the tree, `lake build` clean. Blind spots to
check by hand after `--apply`: (1) a citation list that wraps onto the next line
(`mgr.cc:1551-1554,` ⏎ `1595-1606`) — only the first line is rewritten; grep
for lines starting with digits; (2) a bare backticked range after a comma
(`` `recv.cc:385-388`, `651-653` ``); (3) modules whose unqualified `.h`/`.cc`
switch file by table column (`Session.lean` field table: recv vs send header)
or by row (`prefill_decode.md` mutant table); (4) lines naming another commit
are skipped on purpose (`b68161a` audit lines in `Session.lean`). Found 4 wrapped
lists and 1 column mix-up this time; all fixed in `0b3208b`.

[HYP] `4efb0dd` collapses every push failure into `InternalError("Incoming push
failed")`; the real cause (read timeout, size mismatch, `OnLayerReceived` error)
survives only in the transport log, so `failed_recving` cannot distinguish them.
Observability only; parked in `loose-ends/parked.md`.

[FACT 2026-10-06, `c523e75`] Follow-up on user request: every reference
statement under `verification/` now names only the current commit (`50b0774`);
the re-pin history lives in `prefill_decode.md` §"Upstream re-checks" and
`findings/README.md` §"History". `findings/` was re-pinned too (so the whole
tree has one baseline): `kv_cache_store.cc` F1 lines `:1666-1694` (fn),
`:1669` (Lookup), `:1688` (Pin), `:1851` (Evict), `:1855-1857` (its "do not
hold store mutex_" comment — the old `:1843-1845` was off by one even at
`01ffa3d`), `:1059` (Insert), `:1653-1663` (hook); `block_transport.cc:607`/
`:615`; `filed_bugs.md` permalinks hash-swapped (cited files byte-identical).
Both `findings/` patches `git apply --check` clean at the merged tree. Tool
blind spot (5): a bare `` `:N` `` after a citation of a *different* file
inherits the wrong file — `findings/README.md` F1 had `kv_cache_store_backend.h:104`
between two `kv_cache_store.cc` bare cites, so the tool reported them `same`
instead of shifting; fixed by naming the file once (`kv_cache_store.cc:1688`).
`findings/*.md` is now a default source of the tool. Dry run `NEW NEW`: 563
`same`, 0 `shift`.

## See also

- ../../durable/prefill-decode-transfer-settle-and-layer-readiness-invariants.md
- ../../durable/controller-read-remote-and-kv-store-pinning-concurrency-traps.md
- ../../empirical/bughunt-repro-status-at-01ffa3d.md
- `verification/docs/transfer/prefill_decode.md` §"Upstream re-checks"
