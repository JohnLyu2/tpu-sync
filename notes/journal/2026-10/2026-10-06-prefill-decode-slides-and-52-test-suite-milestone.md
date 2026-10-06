# Milestone: prefill-to-decode verification suite (52 tests) & presentation deck complete

Load this note when resuming work on the prefill-to-decode formal verification, reviewing how the 52 C++/E2E tests map to Lean modules, or updating the `verification/slides/prefill_decode.typ` presentation deck.

[OBS 2026-10-06] Completed the 18-slide Typst presentation deck (`verification/slides/prefill_decode.typ`, committed at `d69c7c9`) alongside the expanded `TpuSyncVerify.Transfer.PrefillDecode` suite (`e9c2d8e`..`61539dc`), marking the completion of the prefill-to-decode verification milestone.
       → `verification/slides/prefill_decode.typ:1-543`
       → `verification/TpuSyncVerify.lean:4-13`

[FACT] All 52 prefill-to-decode unit and E2E tests in `tpu-sync` are replayed as executable `by decide` trace theorems in Lean and generalized into all-schedules safety and liveness theorems across 9 `Transfer/PrefillDecode/` modules:
1. **Session drain & leases (21 C++ tests):** `Send.lean`, `Receive.lean`, `ReceivePoll.lean`
2. **Control handshake rendezvous (6 C++ tests):** `Send.lean`, `Pipeline.lean`, `PipelineChecks.lean` (`c4bdee2`)
3. **Within-layer block gather, dual-permutation reordering & DMA coalescing (7 C++ + 3 E2E tests):** `BlockOrdering.lean` (`61539dc`)
4. **UUID registration tables & drain-before-reuse (4 C++ tests):** `UuidTable.lean` (`4c153f5`)
5. **Cross-peer fault isolation & staging quota (5 C++ tests, Issue #888):** `PeerIsolation.lean` (`5e2d770`)
6. **Multi-layer out-of-order & multi-request concurrent buffer recycling (3 E2E tests):** `Pipeline.lean`, `MultiRequest.lean`, `PipelineChecks.lean` (`c967abc`, `2e07a3e`, `3d90a73`)
       → `verification/docs/test_suite_correspondence.md`
       → `verification/slides/prefill_decode.typ:472-519`

[FACT] The 18-slide deck (`verification/slides/prefill_decode.typ` at `d69c7c9`) is structured into four self-contained arcs:
- **Slides 1–4 (Overview & workflow):** TPU Sync overview (KV transfer, KV cache storage, Weight sync), why concurrency bugs in async DMA/network/buffer-reuse are hard to catch and how formal verification helps (trust beyond unit tests, explicit *invariants*, safer refactoring), and the 3-step Lean 4 workflow (`1 · Model the system` → `2 · Validate the model` → `3 · Prove correctness`).
- **Slides 5–11 (Problem statement, main theorems & top-down proof sketch):** Single-request 5-memory pipeline (Slide 5), concurrent buffer recycling across requests with `wroteReleased` and `.junk` clobbering (Slide 6), Theorem 1–3 statements (Slide 7), and top-to-bottom proof sketch reducing Theorems 1–2 to Lemmas 1–3 and inductive Invariants 1a/1b, 2a/2b, 3 plus the finite ranking measure for Theorem 3 (Slides 8–11).
- **Slides 12–15 (Modeling TPU Sync in Lean — Abstraction → State → Actions → Example):**
  - Slide 12: Component abstraction table (`Manager`, `TransferSessions`, `BlockTransport`, `RawBufferTransport`).
  - Slide 13 (*State*): 4-layer module hierarchy (`MultiRequest` → `Pipeline` → `Send`/`Receive` → `Session`).
  - Slide 14 (*Actions*): Non-deterministic transition system `step(state, event)` mapping out-of-order DMA/network futures, mutex lock-gap windows, and async cancellations/polls/buffer-recycle steps.
  - Slide 15 (*Example*): Diagonal evolution of slot $l$ across the 5 memories (`prefillHbm`, `prefillStaging`, `wire`, `decodeStaging`, `decodeHbm`) in normal execution (`0 → 1 → 2 → 3 → 4 → 5`), contrasted with the 3 wrong step orderings that produce `decodeHbm[l] = .junk` (*Step 4 before 3* out-of-order copy, *Step 5 before 4* read-after-release, *Step 5 before 3* write-after-release).
- **Slides 16–18 (Validating the model):**
  - Slide 16: High-level motivation (checking that the Lean model faithfully captures production C++ behavior without over-constraining valid runs) and the 3-step mapping (`Production test` → `Lean trace (by decide)` → `Lean theorem`).
  - Slide 17: Breakdown of the 52 production tests across 6 categories.
  - Slide 18: Simplified 4-row table of mutant checks (`Settle without waiting for inFlight == 0`, `Release staging at Finish() instead of settle`, `Start H2D before layer l lands`, `Skip --inFlight on early abort`).

## Verify

```bash
# Compile slides to PDF
typst compile verification/slides/prefill_decode.typ verification/slides/prefill_decode.pdf

# Build all Lean proofs and executable trace/mutant checks
cd verification && lake build
```

## See also

- ../../durable/lean-step-models-and-ghost-state-in-tpu-sync-verify.md
- ../../durable/prefill-decode-transfer-settle-and-layer-readiness-invariants.md
