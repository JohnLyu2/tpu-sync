# 2026-10-26 — "more faithful" feedback triaged; `Receive` lock-scope audit

Version stamp: fork `3500ab27`; corpus baseline `c9bc124` (C++ cited at that
commit; `transfer_receive_session.cc` and `kv_cache_manager_with_transfer.cc`
unchanged since).

## The feedback

A reviewer proposed three levels of "more faithful" for the Lean corpus —
(1) model single accesses with thread ids and held locks, (2) model the C++
memory model, (3) connect model to code by trace replay or program logic — and
recommended keeping the current granularity plus `GUARDED_BY` on session and
controller fields, TSan on the test targets, and trace validation of the
receive/send sessions.

## Checked against the repo

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

## `Receive` lock-scope audit (`3500ab27`)

[FACT] New "Lock scopes" section in `Receive.lean` (canonical; 11 new
source-map rows; conventions.md §"One lock scope per event, or say why not").
Result: **no model change**. Per event: `pushBegin`, `pushEnd`, `h2dBegin`,
`netAccount`, `cancel` are one `mu_` scope each; `h2dReady` is a device event;
`pullReply` and `h2dDone` are two scopes (decide, then `EndRecvOp` from an
`absl::Cleanup` declared before the lock, so it runs after the unlock);
`h2dIssue` is two (re-check, `push_back`) with the device dispatch unlocked
between; `pollReady` is three (`IsDraining`, `IsReadyToComplete`, `Finish`);
`publish` is four on a settled session.

Interpretation, not in the docstring:

- The `EndRecvOp`-tail argument is the load-bearing one and generalises: the
  gap state differs from the model's post-state only in `in_flight_`, whose
  only deciding readers are the two settle checks, so a step in the gap
  commutes. `Send.lean` and the Reshard sessions have the same `absl::Cleanup
  end_op` shape; the same paragraph should transfer almost verbatim.
- `h2dIssue`'s gap is exactly why A4 carries the odd-looking clause
  "`ExecuteLayerH2d` pushes the future into `h2d_futures_` before returning".
  Whoever wrote A4 saw this gap; the audit just names it.
- [OBS 2026-10-26] **Late errors.** `FinishLocked` records a non-OK status
  *before* `if (draining_) return;`, so a `Finish(error)` after a settled-OK
  session flips `status_`. The model mirrors it (`Lifecycle.finishLocked`
  docstring: "flips `statusOk` even if already draining"; `cancel` unguarded).
  Two in-tree producers: the deadline sweep (`IsReadyToComplete()` false, then
  the last H2D callback settles OK, then `Finish(DeadlineExceeded)` — reported
  `failed_recving_` with the data landed; deadline semantics, defensible), and
  `UnregisterActivePlan` (`!Done()` under the manager `mu_`, `Finish` outside
  it) racing the poll — it can land between `GetStatus()` and `Details()`, so a
  `done_recving_` entry carries error details. That last one is the single
  outcome found that no interleaving of model steps produces; it lives in
  `transfer_details_`, outside `Recv`'s state. [HYP] Not a finding worth
  filing on its own: it needs the caller to unregister a plan in the same
  microseconds its receive settles, and the caller asking to unregister is not
  waiting on the result. Worth one sentence in the F2/F3 report's "fix" if an
  owner touches `FinishLocked`: `if (draining_) return;` first, or
  `status_` sticky once `done_`.
- The unmodelled `UnregisterSettledPlan` pre-claim in the H2D callback
  (`in_flight_ == 1 && unregister_on_settle_`) drops the plan one scope before
  `done_`; no op is left that could use it. Noted in the table, nothing to do.

## Corrections

None from the user. My own: the first draft of the section said "the only
readers of `in_flight_` are the settle checks" — the callback's pre-claim also
reads it; reworded to "the only decisions that read".
