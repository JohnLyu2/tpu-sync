# Lean 4 step models, ghost state, and proof patterns in TpuSyncVerify

Load this note when reading, extending, or debugging Lean 4 models in `verification/TpuSyncVerify/`.

[FACT] Every state machine in `TpuSyncVerify` is an instance of `System S Ev` (`verification/TpuSyncVerify/Common/System.lean`), which bundles an initial state `init : S` and a single executable transition function `step : S → Ev → Option S` (`none` = disabled guard, `some s'` = atomic transition). Both inductive proofs (`Reachable sys s`), kernel-checked witness traces (`run sys tr = some s` by `decide`), and bounded BFS (`ModelCheck.check`) execute the exact same `step` function, preventing spec-vs-checker drift.
       → `verification/TpuSyncVerify/Common/System.lean:18-65`
       → `verification/docs/conventions.md`

       ```lean
       structure System (S : Type) (Ev : Type) where
         init : S
         step : S → Ev → Option S
       ```

[FACT] Inductive step proofs follow a 3-step template via `TpuSyncVerify/Common/Tactics.lean`:
1. Establish `StepPreserves sys Inv` (`∀ s e s', Inv s → sys.step s e = some s' → Inv s'`).
2. Inside the step proof, `cases e` on the finite event type and run `unpack_step` (which simplifies `step`, splits `if`/`match` guards, and substitutes `s'`).
3. Lift to all reachable states via ` reachable_invariant sys Inv h_init h_step`.
       → `verification/TpuSyncVerify/Common/Tactics.lean`
       → `verification/docs/conventions.md`

[FACT] Symbolic memory arrays (`List Cell` where `Cell := .blank | .kv l | .junk`) and ghost latches are embedded directly in model state structures to turn ordering, read-after-release, and write-after-release bugs into violations of `decodeHbm = good n` (`[.kv 0, …, .kv (n-1)]`):
- **5 layer-indexed memories (`Pipeline.lean`):** `prefillHbm` starts at `good n`; `prefillStaging`, `decodeStaging`, and `decodeHbm` start filled with `.junk`; `wire` starts filled with `.blank`. Copies read their source at *completion* (`d2hReady l`, `h2hDone l true`, `land l`, `h2dReady l`) and execute `dst[l] := src[l]`.
- **Adversarial clobbering on release (`reclaim`, `reseat*`, `recyclePrefill`):** Immediately resets released buffers to `.junk`, so any in-flight read that completes after release copies `.junk` downstream into `decodeHbm`.
- **Cross-request write-poisoning detector (`wroteReleased` in `MultiRequest.lean`):** Monitors all four shared buffers on every `reqStep`; if an older request writes to a buffer it already released, *all* requests' memories are overwritten with `.junk`.
- **UAF latch (`stagingFreed` / `uafRecorded` in `ReadRemote.lean`):** Latches `true` if `TransferBuffers` starts or runs while `stagingFreed = true`, turning a temporal use-after-free race into a state invariant `¬ s.uafRecorded`.
       → `verification/TpuSyncVerify/Transfer/PrefillDecode/Pipeline.lean:23-82`
       → `verification/TpuSyncVerify/Transfer/PrefillDecode/MultiRequest.lean:1-120`
       → `verification/TpuSyncVerify/Controller/ReadRemote.lean`

[FACT] Every model is validated in two complementary directions at `lake build`:
1. **Positive validation (52 production tests → `by decide` traces):** Every C++ unit test and Python E2E test in `tpu-sync` is replayed step-by-step inside the Lean model (`Send.lean`, `Receive.lean`, `PipelineChecks.lean`, `BlockOrdering.lean`, `UuidTable.lean`, `PeerIsolation.lean`, `ReadRemote.lean`) to check that the model is not over-constrained and matches production behavior.
2. **Negative validation (mutant checks):** Critical C++ guards are removed one at a time (`Session.lean`, `dispatchEarly`, `h2dReadyByRank`, `reseatAtFinish` in `PipelineChecks.lean`, `Send.lean`, `Receive.lean`, `cfgBuggy` in `ReadRemote.lean`) and checked via `decide` or `ModelCheck.check` to confirm that Lean automatically finds a counterexample trace.
       → `verification/TpuSyncVerify/Transfer/PrefillDecode/PipelineChecks.lean:268-346`
       → `verification/docs/test_suite_correspondence.md`

## Verify

```bash
# Build all 14 Lean modules (zero sorry, zero extra axioms)
cd verification && lake build
```

## Why this matters

When auditing a new C++ subsystem (e.g., `BlockTransport` or `HostOffloadBackend`), model it as a `System S Ev` with a `Config` toggle (`cfgBuggy` vs `cfgFixed`) and ghost UAF/ownership latches. You get both a machine-checked counterexample trace for bug reports and a machine-checked safety proof for the proposed fix in the same file.

## See also

- prefill-decode-transfer-settle-and-layer-readiness-invariants.md
- controller-read-remote-and-kv-store-pinning-concurrency-traps.md
