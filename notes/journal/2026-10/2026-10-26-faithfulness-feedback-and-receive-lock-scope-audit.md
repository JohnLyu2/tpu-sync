# 2026-10-26 — "more faithful" feedback triaged; `Receive`, `Send`, `Transport` lock-scope audits

Version stamp: fork `3500ab27`..`5efb58a9` (audit follow-up on top); corpus
baseline `c9bc124`. Canonical for the per-event scope tables:
`tpu_sync/formal_verification/TpuSyncVerify/Transfer/PrefillDecode/{Receive,Send,Transport}.lean`
§"Lock scopes" and `tpu_sync/formal_verification/docs/conventions.md` §"One
lock scope per event, or say why not".

## The feedback

A reviewer proposed three levels of "more faithful" for the Lean corpus —
(1) model single accesses with thread ids and held locks, (2) model the C++
memory model, (3) connect model to code by trace replay or program logic — and
recommended keeping the current granularity plus `GUARDED_BY` on session and
controller fields, TSan on the test targets, and trace validation of the
receive/send sessions.

## Checked against the repo (not in `formal_verification/`)

- [FACT] The sessions are already annotated: `transfer_receive_session.h` 36
  `ABSL_GUARDED_BY`/`LOCKS_REQUIRED`, `transfer_send_session.h` 24,
  `staging_arena.h` 16. The gap is the controller: `raiden_controller.h` 5,
  `raiden_controller.cc` 1 — `settled ABSL_GUARDED_BY(mu)` directly below the
  unannotated `uint64_t lease_id` in `RemoteReadState` (F3). The feedback's
  "annotate the sessions" is already done; "annotate the controller" is F3's
  fix.
- [FACT] Nothing in the OSS build enables the analysis: no `-Wthread-safety`
  in `.bazelrc`, `build.sh`, `ci/run_unit_tests.sh` or any `BUILD` copts
  (clang's analysis is off by default). The ~80 annotations in the modelled
  files have never been checked by this repo's build. No sanitizer config
  exists either.
- [FACT] Non-default atomic orderings on modelled paths: exactly one,
  `remaining_h2h_layers_.store(total_layers, std::memory_order_relaxed)` in
  `TransferSendSession::StartPush` before the per-layer callbacks are
  registered (their `fetch_sub(1)` is seq_cst); `session_failed` relaxed
  load/store live in `socket_transport_adapter.cc`, below the modelled
  `BlockTransport`. Level (2) is unnecessary on checked grounds, not assumed
  ones.
- [FACT] `ReadRemote` replay from existing logs is not possible yet: the F2
  write-ups do not preserve `RAIDEN_LEASE` lines, the existing probes cover 3
  of the 5 `ReadRemote.Ev` events (`acquireReply`, `deadline`, `pullDone`;
  none for `shutdown`), and they sit outside `mu`.
- [OBS 2026-10-26] No Bazel on this machine (recorded 2026-10-20); every
  build-side item (the `-Wthread-safety` build, TSan, replay) is gated on a
  build host.

## Verdict recorded

Levels (1) and (2): not worth doing, as the feedback itself said; (1) would
reprove ~9.8 kLOC against a hand-transcribed lock table that one
`--per_file_copt=tpu_sync/.*@-Wthread-safety,-Werror=thread-safety-analysis`
build checks against the real one. Level (3) replay: worth doing, with two
constraints the feedback skipped — probes must emit inside the event's `mu_`
scope (or carry a sequence number assigned under it) or log order ≠ step
order, and events ↔ code points are not 1:1 (`pushEnd` on failure is
`cancel; pushEnd`, hooks, environment events). Instrumentation is a production
change the fork cannot carry; `RAIDEN_LEASE_TRACE` is the in-tree precedent.
Cheapest end-to-end proof of the replay idea: `ReadRemote` (5 events, probes
partly there). Parked as four entries (see `loose-ends/parked.md`).

What is in neither list: the premise itself. `GUARDED_BY` proves each field
access holds the lock; it does not prove a modelled event is one lock scope.
That residual is a reading audit per event, and it is what I did.

## Lock-scope audits of `Receive`, `Send`, `Transport` — interpretation

[FACT] **No model change** in any of the three (canonical tables in the three
`.lean` files; +25 source-map rows total, 680 anchors).

- **The `EndRecvOp`/`EndSendOp`-tail argument** is the load-bearing one and
  transferred from `Receive` to `Send` verbatim (with A7's `release_due` added
  to the readers of `in_flight_`). The gap state differs from the model's
  post-state only in `in_flight_`, whose only deciding readers are the settle
  checks, so a step in the gap commutes.
- **`h2dIssue`'s gap** (`Receive`) is why A4 carries the clause
  "`ExecuteLayerH2d` pushes the future into `h2d_futures_` before returning".
  Whoever wrote A4 saw the gap; the audit names it.
- [OBS 2026-10-26] **Late errors (`Receive` vs `Send`).** The receiver's
  `FinishLocked` records a non-OK status *before* `if (draining_) return;`, so
  a `Finish(error)` after a settled-OK session flips `status_` (the model
  mirrors it: `cancel` unguarded). `UnregisterActivePlan` (`!Done()` under the
  manager `mu_`, `Finish` outside it) racing the poll between `GetStatus()`
  and `Details()` is the single outcome found that no interleaving of model
  steps produces — a `done_recving_` entry with error details in
  `transfer_details_` (outside `Recv`'s state). The sender's first-wins
  `FinishLocked` (`if (draining_ || done_) return;`) has no such flip.
  [HYP] Not a finding worth filing on its own: it needs the caller to
  unregister a plan in the same microseconds its receive settles, and the
  caller asking to unregister is not waiting on the result. Worth one sentence
  if an owner touches `FinishLocked`: `if (draining_) return;` first, or
  `status_` sticky once `done_`.
- **`Transport.stream` is the one deliberately coarse event** in the trio (two
  mutexes). A `Finish` after the push lease and before the delegate calls ends
  leaves a state outside `step`'s reach (latched layer whose stream added no
  `blocks`) that satisfies `Safe`; the session half is exact in `Receive.lean`.
  Not worth splitting: the properties are about the table, and its mutation is
  one scope (A1).
- [HYP] Pattern across the three: every multi-scope session event is "decide
  under the lock, then an `absl::Cleanup` tail that only decrements
  `in_flight_`", and the commuting argument is always the same two lines. If
  the Reshard sessions follow it too, the remaining audits are mostly
  transcription; the interesting rows will be where a scope reads something
  *not* under the session lock (`ReadRemote`'s `lease_id` — F3 — is such a
  row).

## Corrections

1. Draft of `Receive.lean` said "the only readers of `in_flight_` are the
   settle checks" — the H2D callback's unregister pre-claim also reads it;
   reworded to "the only decisions that read".
2. User-requested audit of `3500ab27`..`1fdb60cb`:
   - `Receive.lean` `h2dIssue` said "no stream of this layer reports before
     `ExecuteLayerH2d` returns" — false when a layer has multiple streams
     (earlier streams report before `ExecuteLayerH2d` is entered); what is true
     is that *the stream that completed this layer* is on the same thread and
     calls `OnBlockShardsReceived` after `ExecuteLayerH2d` returns. Also added
     why `Finish(error)` during dispatch commutes with `push_back`
     (`push_back` does not check `draining_`, `FinishLocked` does not read
     `h2d_futures_`), `StartRead`'s fault-injected `pullReply` scopes, and
     dropped "three" on `pollReady` (`req_id()` for the log is a fourth,
     read-only scope).
   - `Send.lean` `sendNext` said "two scopes" unconditionally — for the last
     layer `SendNextLayer(l + 1)` returns at `l >= num_layers()` before its
     lock, leaving only `EndSendOp`.
   - `Transport.lean` `stream` argued `NetworkSound` holds on a mid-stream
     `Finish` because "`dispatched` can only have grown" — hand-wave when
     `Finish` precedes `ExecuteLayerH2d` (no copy is issued); the real reason
     is that `OnBlockShardsReceived` also returns at `done_ || draining_`,
     leaving `blocks < c.target` (`networkCompleted = false`). Also split the
     two mid-stream `Finish` positions (before vs after `ExecuteLayerH2d`).
   - Trimmed this journal entry to stop duplicating the per-event tables in the
     `.lean` files (`notes/AGENTS.md` rule 1) and updated `sessions.md` to cover
     `Send` and `Transport`.
