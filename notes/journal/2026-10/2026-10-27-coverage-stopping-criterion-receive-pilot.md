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
