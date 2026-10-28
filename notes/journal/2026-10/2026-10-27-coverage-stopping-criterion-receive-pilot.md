# 2026-10-27 — Coverage as the stopping criterion: Receive pilot

Version stamp: fork `633f4c47`; corpus baseline `c9bc124`. Canonical for the
numbers, the branch table and the recipe:
`tpu_sync/formal_verification/TpuSyncVerify/Transfer/PrefillDecode/Receive/Coverage.lean`,
`Receive.lean` §Coverage, `docs/conventions.md` §"Coverage".

## The feedback

Reviewer: validation against known behaviour (unit tests, real runs,
simulation) is right, but we stop when we run out of unit tests; there is no
coverage notion, hence no stopping criterion. Pointer: McMillan & Zuck,
"Formal specification and testing of QUIC" (SIGCOMM '19) — an executable spec
used both as monitor on real traffic and as generator driving the
implementation, with spec-action coverage plus implementation coverage as the
stop condition; every disagreement is a spec fix or a bug.

## What we decided (plan artifact in the conversation; the parked entry below is the durable copy)

Four criteria per model, two measurable on this machine:
C1 every `(event, branch)` of `step` reached by a trace paired with a C++
test or classified; C2 every guard has a killed mutant; C3 C++ branch coverage
inside the source-mapped spans; C4 Lean-generated schedules run against the
C++ and runtime replay. Build-host items (C3, C4) are the QUIC loop proper;
`RecvTestManager` already drives every `Recv.Ev`, so the "tester" half is a
`TEST_P` interpreter over a Lean-emitted schedule table, not a research
project.

## Receive pilot — interpretation (facts in `Coverage.lean`)

- [FACT] 37 reachable branches (exhaustive for ≤ 2 layers, ≤ 2 open pushes);
  paired upstream tests reach 18. The denominator came out *exact*, not
  bounded, because `pushes` is the only unbounded counter and pruning at 2
  loses no branch. Expect the same for `Send` (nothing unbounded but the
  `in_flight_` ghosts, all layer-capped).
- [FACT] Two `Leaf`s never fire: the retired-callback `LOG(DFATAL)` (the
  invariant's `NoRetiredCallback`) and `RecordNetworkCompleteLocked`'s
  `FinishLocked()` arm — **dead C++**, by the same reasoning in the C++
  (`num_completed_layers_` is only incremented in the callback, which finishes
  unless draining; `OnBlockShardsReceived` then returns early). Same genre as
  the `IsReadyToComplete` redundancy; found by the BFS never producing the
  leaf, confirmed by reading. Premise: `num_shards() ≥ 1`.
- [OBS 2026-10-27] **Reply-after-data flip.** `HandlePullStream` spawns the
  `StartPush` thread *before* it returns the pull response, so a consumer can
  dispatch, copy and even complete every layer before `on_response` runs. If
  the reply then fails at the transport level, `FinishLocked(pull_status)`
  flips `status_` on a complete receive → `failed_recving` for correct data
  (caller recomputes; under tpu-inference's connector, C1 leaks instead).
  [HYP] Low severity — needs a control path slower or flakier than the whole
  transfer; design wart rather than defect (reply status is irrelevant once
  `network_completed_`). One-line fix if an owner wants it: `on_response`
  ignores a non-OK status once `network_completed_`. Not filed.
- [FACT] No upstream test fails `H2dSyncDispatch`, and no consumer-side unit
  test completes a handshake (`RegisteredPullIsAcknowledged` is producer-side;
  the control-plane producers hold, drop or reject). The model says both paths
  are fine, which is exactly the "model agrees with itself" problem coverage
  exists to break.
- [FACT] Yesterday's late-error `[OBS]` is the `cancel errors` branch with a
  5-event harness schedule (`AddRecv; ReceiveLayer; FinishCopy(ok); FailRecv;
  poll`).

## Design notes worth keeping

- Coverage must be measured on the *proved* `step`. `stepT` is
  `(event s).map (·, tag)` with the tag computed from the same pre-state
  guards; `stepT_step` is one `simp`. Never redefine `step` as a projection of
  `stepT` (touches every proof) and never hand-write a second boolean step
  (the `violates`/`Safe` lesson again).
- `Effect` (drains / settles / errors) read off before/after states is what
  made the Lifecycle branches visible without re-transcribing `Session.lean`.
- One `#guard` with `let`s, not one per check: each `#guard` re-runs the
  search (6 s → 2.5 s).
- `#guard` cannot carry a docstring; bind the check to a `def` first.
- `universe` is a Lean keyword.

## Corrections

1. Self-audit: the two `RecvDrainTest`s had been paired with the pull-shaped
   trace (`initLoad 1`), crediting `pullReplyOk` to tests that never pull;
   re-paired with a push-shaped trace, 19 → 18 covered, and the finding that
   no unit test completes a handshake fell out. "9 tests all drivable today"
   → 8 + 2 that need a producer stub (`SilentProducer` cannot answer). One
   paired trace included a `publish` its test never performs (`take 3`).
2. Independent auditor (read-only): `netAccountCompletes` called an
   "assertion" in two places (it is a dead arm — renamed `unreachableLeaves`);
   dead-arm argument missed `num_shards() == 0`; "no other writer" →
   "incremented nowhere else"; `cancel (no effect)` is in fact reached
   unasserted at teardown (`~KVCacheManagerWithTransfer` `Finish`es seated
   sessions); "13 distinct traces" → 13 named (12 distinct sequences);
   "three lease tests" → four; `RecvBase::H2dSyncDispatch` "can" → "could be
   made to" return an error.

## Send (`85f91676`) — interpretation

Canonical: `Send/Coverage.lean` §Result, `Send.lean` §Coverage,
`Common/Coverage.lean` (machinery now shared; `Receive` ported, numbers
unchanged).

- [FACT] 43 branches, every leaf live, paired tests reach 26; 17 gaps = 7
  test / 10 window. Compared with `Receive`, `Send` has more lock windows
  (the push-pool task and `SendNextLayer`'s `++in_flight_`→`OnReady` gap add
  positions no harness hook reaches) and no dead arm.
- [FACT] **D2H-future callbacks run LIFO.** `xla::Future::OnReady` is
  `AsyncValue::AndThen`: waiters are prepended and run from the head on the
  setting thread; a callback on an already-available value runs at
  registration (`xla/tsl/concurrency/async_value.{h,cc}`,
  `EnqueueWaiterListNode` / `RunWaiters`, read in the pinned xla under the
  bazel cache). `StartPush` registers `d2hEnd` inside its loop,
  `SendNextLayer(0)` registers `wake` after it, so a test-completed copy runs
  `wake` then `d2hEnd`; a copy complete at registration (FakeSendBase
  non-manual) runs `d2hEnd` first. Four traces had the wrong order; the model
  itself never fixed it (A3 says any interleaving maps onto one it admits,
  which is still true — but the *tests* pick one, and coverage needs to know
  which). Also holds in production through `PjRtCopyFuture::OnReady`, whose
  first call materialises the joined future that later calls attach to.
- [FACT] Six send tests drive `Finish(OkStatus())` from outside
  (`TestManager::Decide(false)`, `session->Finish(absl::OkStatus())`). The
  only production source is `AckSend`, which A5 excludes as dead, so these
  tests exercise a stimulus production never produces; the old docstrings had
  paired three of them "by analogy" with `cancel`-based traces. Now
  `notReplayable`. If an owner ever wires the Ack, A5 falls and `Send` needs
  a `finishOk` event — and these six tests become its replays.
- [FACT] `DetailsSayAFailedPushFailedInPushWhileCopiesRun`'s injected failure
  (`hooks::kRaidenManagerBaseH2hWrite`) is reported synchronously inside the
  pool task, before `SendNextLayer(l + 1)`: the test reaches `sendNextRefused`
  deterministically, which I had classified as a window.
- [HYP] Pattern across both models: the harness can drive every *external*
  stimulus (cancel, failed copy/push/dispatch, completion order between
  different futures) but no *internal* one (a `Finish` landing between two
  lock scopes of one event, or between a future's readiness and its callback).
  The window class is therefore exactly the per-event lock-scope audit's
  residual, seen from the test side; W4's schedule interpreter will have the
  same blind spot unless the C++ grows a test hook at those points.

## Corrections (Send round)

1. Independent audit #1 (eight findings, all applied): `DetailsSayAFailedPush…`
   trace order (above); control-plane `TestManager` has zero layers, so the
   three acknowledged-pull tests are `init 0, [beginPull, start]`
   (`startZeroLayers`), not `init 1, [beginPull]`; a late `StartPush` on a
   finished send is `cancel` (no effect) per the model's own mapping of a
   refused acquisition, so three paired tests cover it; "no test reaches it"
   was false for two windows that `…CancelledMidPush` / `DoneGuarantees…` reach
   by chance (`WaitForH2hCalls` returns before the task tail); the
   `PullAfterRegistrationDeadlineIsRejected` test polls and so is paired, not
   `notReplayable`; three refusal-only control tests and
   `SendDeadlineTest.ExpiredSendSessionFails…` were in neither list; "six not
   replayable" vs seven rows; the callback order was "undetermined" — resolved
   by reading xla, which dissolved the "order" class I had invented.
2. Independent audit #2: my scripted edit of `Send.lean` spliced on the first
   occurrence of "`## Source map`", a prose mention near the top, and
   appended the whole docstring body a second time with stale numbers.
   Neither `lake build` nor `resolve_anchors.py --check` notices a duplicated
   docstring. Rule: never splice on a string that can occur in prose; diff
   the file against HEAD before committing. Plus: the zero-layer control
   pairings and `DoneGuarantees…` are racy and now say which order they take;
   `ServePull` never calls `ValidateAndBeginPull` (the `beginPull` is the
   model's precondition, said so).

## Pipeline (`728cae5b`) — interpretation

Canonical: `Pipeline/Coverage.lean` §Result, `prefill_decode.md` §"Branch
coverage by the replayed tests" (the three-model table).

- [FACT] 75 branches at one layer; paired E2E/control tests reach 25; the 50
  gaps are 3 environment + 17 session-covered + 30 session-gap, none
  unaccounted. The composed model's leaves carry the inner session leaf, so
  the `#guard` can check that every pipeline gap is explained one level down
  — the first coverage result that is a *partition* rather than a list.
- [FACT] Every memory move in the reachable set writes the right layer's KV:
  `PublicationCorrect` is visible in the branch set itself (and the
  `dispatchEarly` mutant's `h2dReady junk` is the counter-check).
- [FACT] The E2E tests exercise exactly the happy paths and the handshake
  rejections. Nothing at pipeline level fails a copy, a push, or a dispatch;
  all of that lives in the session unit tests (or in their gap tables).
- [HYP] The three environment branches (`reclaim`, both reseats) are the
  multi-request story; `MultiRequest.lean` has no coverage yet and the only
  test that drives them is the single-host disagg E2E script. If coverage is
  extended there, those three are the ones to pair.
- Tooling: the shared search keyed `seen` by list membership; the one-layer
  pipeline took 80 s, two layers would not finish. `Std.HashSet` + `deriving
  Hashable` on the five state types: 3 s and 20 s. The two-layer result is
  documented but not a `#guard` (budget ~5 s per guard).

## Corrections (Pipeline round)

1. Independent audit: "28 of 75, 47 gaps" was wrong — `coveredByPaired`
   counts branches along the traces, and the two two-layer E2E rows take 4
   branches outside the one-layer universe the guard searches; the class
   counts (3+18+30 = 51) already contradicted the prose and I had not added
   them. Correct: 25 in-universe, 29 along traces, 50 gaps. The guard now
   pins both numbers. Rule: when the universe and the traces run on different
   instances, count coverage *inside the universe* and say what falls outside.
2. Same audit: two control rows omitted the client's ack read; the
   deadline-rejection control test was in neither list (it polls: `[cancel,
   publish]` on the producer); `trace_normal` cited the two-layer Python
   tests; `keep` drops a pruned successor's branch in the search but not in
   `witnessP` (now said); the mutant's borrowed tag has a placeholder (said).
3. Second audit: "every model state type derives `Hashable`" overclaimed
   (five do); two of the six non-E2E two-layer branches are session-covered,
   not gap-table; "runs" → "rows"; `Reshard/Coverage.lean` is byte coverage,
   disambiguated.

## ReadRemote (`71426548`) — interpretation

Canonical: `Controller/ReadRemoteCoverage.lean` §Result,
`docs/controller/read_remote.md` §"Branch coverage".

- [FACT] 11 branches, whole state space; `ReadRemotePullTest` reaches 5; of
  the 6 gaps, 5 need the deadline thread to fire and the 6th is the ghost
  `callerReuse`. No upstream test lets the deadline fire: default 150 s
  (`DefaultLeaseTtl() + 30 s`), every case ends in seconds, and the detached
  thread is killed with the process. **F2's shapes A and B live entirely in
  the region the suite never enters**, and the region is one stimulus wide:
  time. That is the sharpest "where there is no evidence" statement coverage
  has produced so far, and it is exactly where the fork's two bug-hunt
  reproducers sit (`findings/raiden_controller_bughunt_test.cc`, which the
  deliverable cannot cite).
- [FACT] `Leaf × Effect` with `Effect = settles` cannot see shape A's issuing
  step: `acquireIssuesPull` is the same branch whether or not the read is
  settled, because issuing does not settle. The coverage number is honest
  about that in prose; the property/search is what catches it. Lesson for
  the recipe: the effect should record what the *property* talks about —
  here "issued after settled" — or the bug's own step counts as covered.
- [HYP] The `callerReuse` cut generalises: any ghost event that models the
  *environment's* next move (reseats, reclaim, callerReuse) is enabled by the
  tests but never performed by them. `Pipeline` classed them "environment";
  `ReadRemote` classes it "ghost". Same thing; pick one word in conventions
  when the next model comes.

## Corrections (ReadRemote round)

1. Self: the first table was written by hand before the search ran — three
   of five rows were wrong (`shutdown` / `acquireIssuesPull` have no settling
   variant; `acquireFailed` / `acquireAfterShutdown` have no-effect variants
   instead). Rule, again: enumerate first, then write the table.
2. Independent audit: `callerReuse` paired as test-reached was an over-claim
   (cut: 6 → 5 covered, gaps 5 → 6); the teardown test admits three
   outcomes, not two (paired with all three); "the deadline thread runs after
   the test, unobserved" was false (it never wakes before exit); env var is
   `RAIDEN_REMOTE_READ_DEADLINE_S` (I had written a `TPU_RAIDEN_…` name),
   integer seconds, read once per process.

## MultiRequest (`f44e707c`) — interpretation

Canonical: `MultiRequestCoverage.lean` §Result, `prefill_decode.md` coverage
table row.

- [FACT] Unbounded state space → no universe; measured by leaves added
  (3): the corruption arm is dead by theorem, the two recycles are reached
  only by the `run_all.sh` replays. **No upstream test overwrites a buffer an
  earlier request released while that request is still observable.** The
  whole multi-request story — the thing the slides' Theorems 1–3 are about —
  has no in-suite test behind it; its evidence is the Lean proof plus a demo
  script.
- [HYP] Cheapest test that would change this: a `RecvTestManager` case that
  registers a second receive on the first's staging slot after the first
  publishes, then completes a late callback of the first and checks the
  second's buffer — the `reseatAtFinish` mutant as a C++ test. Belongs in the
  upstream test PR.

## Corrections (MultiRequest round)

1. Independent audit: `nextRequest` recycles three buffers, not four
   (`decodeHbm`, the published result, is kept — junking it would contradict
   `system_attention_safe`); "no test recycles a buffer to a later request"
   was too strong (two tests hand released resources to later requests with
   the earlier one finished) — tightened to "overwrites … while still
   observable", tests named; stale "no coverage there yet" in
   `Pipeline/Coverage.lean`.

## W2 guard inventory, Receive and Send (`5f1d205c`) — interpretation

Canonical: `Receive/Guards.lean`, `Send/Guards.lean` (tables, mutants,
`#guard`s), the umbrellas' §"Coverage and guards", `PublishedQuiet` in both
`Model.lean`s.

- [FACT] Scope chosen narrower than the plan: only guards that transcribe a
  C++ check (not ghost-counter guards), judged against `Safe` minus the
  ghost equations, with a second `#guard` (`survivesFull`) that survivors
  also survive the full `Safe`. Receive: 10 mutated, 5 load-bearing, 5
  survive. Send: 11 mutated, 5 load-bearing, 7 survive. Every survivor has a
  purpose outside the properties — wasted-work avoidance (a `Finish` stops
  new work at every lock it passes, so each check is one line of a 2–3-line
  defence), metrics/accounting, or the first-`Finish`-wins design choice,
  which no safety property can see. No C++ redundancy to propose beyond the
  known ones.
- [FACT] **The finding: a property gap in both session modules.** Dropping
  `Done()` before publishing survived the `Safe` each module had.
  `Publication` constrains only `some true`; `ok_draining` makes an early OK
  publication harmless; an early *failed* publication was unconstrained — the
  engine reclaiming prefill HBM or refilling decode HBM under a copy still
  in flight. That promise existed only in `Pipeline.PrefillHbmSafe` /
  `DecodeHbmSafe`. `Send.PublishedQuiet` and `Recv.PublishedQuiet`
  (`published ≠ none → nothing dispatching or unretired`) added, proved from
  `published_done` + `done_idle` + `Accounted` in four lines each, appended
  last in `Safe` so positional projections elsewhere are untouched. The
  mutant now dies in 3–5 events. This is the proof-side analogue of
  ReadRemote's `Effect = settles` blind spot: the module stated the easy
  half of its promise.
- [HYP] Pattern for the recipe (`conventions.md` does not yet say it): a
  killed check whose killer is a *one-directional* property is suspicious —
  check the other direction. Both `Publication`s were one-directional and
  both hid the same gap.
- Tooling: `decide` on a fuel-64 search exceeds the kernel's recursion
  depth; schedule pins are `#guard`s, not theorems. `Guards.lean` and
  `Coverage.lean` share a namespace, so list names must differ
  (`guardInits`).

## Corrections (W2 round)

1. Independent audit: Send survivor count "six" was seven (S3′ is its own
   row); "survivors also survive full `Safe`" was checked ad hoc, not pinned
   → `survivesFull` guards; `endOpEager` also sets `draining` (kept for
   `Consistent`, now said, kill independent of it); S3′'s cover is S4's
   `trySendNext` refusal, not S5; G2's schedule unpinned; `Finish()` vs
   `FinishLocked()` on the sender's last push; and the audit's observation
   that Receive's G8 was killed only through the OK half is what produced
   `Recv.PublishedQuiet` — I had added it on the sender only.
2. Committed by the concurrent session as `5f1d205c` (file set verified
   identical to the audited tree); this journal entry is the record that
   commit lacked.
