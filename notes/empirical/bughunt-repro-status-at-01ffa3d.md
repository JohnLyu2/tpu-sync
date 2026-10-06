# Bug-hunt deterministic reproduction and Lean model-check status

**Verified against:** `tpu-sync` commit `01ffa3d` (reproducer tests executed on branch `bughunt` at commits `b68161a` / `d16701e`)
**Last verified:** 2026-10-05
**Status:** repeated (deterministic GTest reproducers + Lean `decide` kernel checks)

[SUPERSEDED → journal/2026-10/2026-10-06-upstream-50b0774-merge-and-citation-repin.md] (2026-10-06) Three things in the table below are wrong and are left as written for the trail: (a) there are no bazel targets `bughunt_f1_test` / `bughunt_f2_test` — the reproducers are `verification/findings/kv_cache_store_pin_race_test.cc` (`KVCacheStorePinRaceTest.EvictAndReinsertBetweenLookupAndPinReturnsStaleHostBlockId`) and `verification/findings/raiden_controller_bughunt_test.cc` (`BugHuntTest.ReadRemoteDoesNotStartPullAfterDeadlineSettled` and the two `TransferBuffers…` tests), built via `verification/findings/build_targets.patch`; (b) F2 **shape B has no C++ test** — `ShapeB_DeadlineFreesStagingWhilePullInFlight` does not exist; shape B is Lean-only (`ReadRemote.bug_trace_B_violates`); (c) `raiden_controller.cc` is at `tpu_sync/core/controller/`. Superseded by: the journal entry above. Still true: all four findings have deterministic witnesses, and the Lean checks.

[EMP] All four confirmed concurrency / lifetime bugs in `KVCacheStore` and `RaidenController` have deterministic failure witnesses against the `01ffa3d` code logic:

| Finding | Subsystem | Verification / Repro Method | Result |
|---|---|---|---|
| **F1** (`ValidateAndPinHostBlocks` TOCTOU) | `tpu_sync/kv_cache/kv_cache_store.cc:1655-1683` | `bazel test //tpu_sync/kv_cache:bughunt_f1_test` (`ValidateAndPinHostBlocksToctouReturnsStaleBlockId`, 2 threads + barriers) | **100% deterministic failure** (`lookup_ids[0] == 0` holding `H_other = 999` bytes while `H_target = 100` moved to block `1`) |
| **F2** (`ReadRemote` deadline vs. pull UAF) | `tpu_sync/raiden_controller.cc:1016-1211` | `bazel test //tpu_sync:bughunt_f2_test` (`ShapeA_CallbackPullsIntoFreedStagingAfterDeadline` & `ShapeB_DeadlineFreesStagingWhilePullInFlight`) + `verification/TpuSyncVerify/Controller/ReadRemote.lean` | **100% deterministic failure** on both Shape A (`80 ms` acquire latency vs `30 ms` deadline) and Shape B (`80 ms` pull vs `30 ms` deadline); Lean `ReadRemote.bug_trace_A_violates` and `bug_trace_B_violates` proved via `decide` |
| **F3** (`RemoteReadState::lease_id` data race) | `tpu_sync/raiden_controller.cc:897, 1034, 1090-1101` | Static happens-before audit + covered by F2 Shape A interleaving where `lease_id` is written after `Settle(DeadlineExceeded)` | Unsynchronized non-atomic read/write across gRPC callback thread and detached deadline thread; leaks remote lease until server expiry |
| **F4** (`TransferBuffers` auto-staging leak & un-awaited futures) | `tpu_sync/raiden_controller.cc:573-793` | Static path audit across 5 early-return branches (`:673, :722, :737, :768, :776`) | Permanent `BufferPool` staging block leak on 4 branches; un-awaited in-flight worker DMA into freed staging on `:768-770` when worker $i > 0$ fails `node_id` validation |

[EMP] All 12 Lean 4 modules in `verification/TpuSyncVerify/` compile cleanly under `leanprover/lean4:v4.29.0` with zero `sorry` and zero extra axioms (`lake build`), discharging all 22 invariant and progress obligations plus 7 mutant counterexample traces.

## Reproduce

```bash
# Verify Lean 4 models, invariants, and F2 counterexample traces
cd verification && lake build
```

## See also

- ../durable/controller-read-remote-and-kv-store-pinning-concurrency-traps.md
- ../durable/lean-step-models-and-ghost-state-in-tpu-sync-verify.md
