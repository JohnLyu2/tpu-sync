# 2026-10-30 — Reshard sub-plan chains modelled; candidate-policy proofs rejected in favour of "describe the code as it is"

Version stamp: fork `bf34af03`..`d78fe3f6`; corpus baseline `42dda542`. Canonical:
`tpu_sync/formal_verification/TpuSyncVerify/Transfer/Reshard/SubPlanChain.lean`
(docstring, assumptions A1–A4, source map), its `Model` / `Invariant` /
`Traces` / `Coverage` parts, and `docs/transfer/reshard.md` §"What is proved",
§"Shipping C++ vs. modelled design alternatives", §"Branch coverage".

## What landed (`f1adb453`, `d78fe3f6`)

Three systems in one module: `planSubTransfers` / `subPlanUuid` (pure
functions), `WorkerState` (one worker's `SubPlanChainProgress` folding for one
`req_id`), `CoordChainState` (`StartPoolReshard` / `StartChain` /
`RunSubPlan(0 .. K-1)` over the `Registry.RegGen` generation). Shipping-only
`step`s; the `if (index == 0)` guard on `AbandonClaim` is kept as the mutant
`stepAbandonAtEveryIndex`.

- [FACT] Proved on shipping code: `DoneAfterAllSubPlans` (worker) and
  `CoordChainSafe` (`NoSenderExposed`, `NoPushBeforeAllArmed`,
  `AllArmedWhileDispatching`, `OneWindowStagedPerDestination`,
  `CompletedOnlyAtChainEnd`, `ClaimHeldAcrossWindows`, `Registry.Inv`).
- [FACT] F12 (sparse sender never reaches `K`; window ≥ 1 failure keeps the
  claim) and F13 (first failure reported while siblings active; late sub-plan
  failed twice) re-derived as shipping traces; nothing new found by the model.
- [INTERPRETATION] The coordinator-side *universal* guarantee the C++ actually
  gives is `ClaimHeldAcrossWindows` + `NoSenderExposed`: the claim never drops
  while a dispatched rank reads HBM, which is exactly what `if (index == 0)`
  buys and what the naive "abandon at every index" fix would break. That is
  the sentence to use when F12's claim-stranding is discussed upstream.

## Decision: no candidate policies inside `formal_verification/`

The first draft (never committed) carried `ChainPolicy.settledBarrier` and
`ChainCleanupPolicy.reconcileDispatched` — invented mechanisms (per-target
`(targetIndex, targetCount)` fields; coordinator-driven synthetic `Complete`
votes) with ~1,550 lines of inductive proof and *no* inductive theorem on
`.shipping`. User audit 2026-10-30 (this session) rejected it; the rule is
`docs/conventions.md` §"Describe the code as it is": candidate fixes belong in
`findings/` beside the filed bug, the tree keeps shipping `step`s plus guard
mutants. Root causes recorded for next time: copying the
`Coordinator/Hardened.lean` "hardened alternative" template without noticing
the cost had inverted; chasing an unconditional `reachable_safe` by designing a
fix in Lean instead of proving what the shipping code guarantees and tracing
the rest; not re-reading `conventions.md` before starting.

- [CORRECTION] The same audit found the draft's `retryBusyArm` unfaithful
  (fired before the armers' join; erased permanent arm failures). Shipping
  `RunSubPlan` joins all armers, then retries only if every unarmed destination
  is `ArmRefusedForBusyStaging` and `attempt + 1 < attempts`
  (`attempts = index == 0 ? 1 : kChainArmAttempts`); any other error aborts.
  Now `ArmOutcome = ok | refusedBusy | failed` with that exact condition.
- [CORRECTION] (`d78fe3f6`) `SweepSubPlanChainsLocked(now)` runs after the
  `RecordPoolReshardTerminalLocked` calls of the same `CompleteReadWithDetails`,
  which set `last_activity = now`; a chained, non-superseded record in a poll
  therefore blocks the stall sweep in that poll. Single-plan and superseded
  records do not touch the entry. Modelled as `SweepAcc.touched`.

## Traps

- `ModelCheck.check` dedupes with `List.contains`: a worker event set with four
  registrations (two uuids for index 1) does not finish; three registrations
  exhaust in ~2 s. Keep `workerCheckEvents` at three.
- Branch coverage for these two systems is counted per **arm**, not per
  `Leaf × Effect`: a poll visits several `RecordPoolReshardTerminalLocked` arms,
  and the coordinator's environment events are enabled in every phase, so the
  branch universe was 80 / 44 and unreadable. `Coverage.lean` says so.
- Two tabs building in one `.lake` invalidate each other's oleans
  ("incompatible header"); run builds one at a time.
- `reshard_service_test.cc` is modified in the working tree by the coverage-gap
  patch work; anchors still resolve because the added tests are appended.

## Open

- Commit 2 of the "Option B, staged" plan: demote `UnregisterPolicy.onSettle`
  (`Reshard/Send`) and `CleanupPolicy.disarmAndAbandonOnFailure`
  (`Reshard/Coordinator/Hardened.lean`) to `Traces.lean` alternative steps
  (→ `loose-ends/parked.md`).
- The coordinator invariant proof is ~850 lines of mechanical case splits;
  per-event helper lemmas would cut ~300.
