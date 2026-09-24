import TpuSyncFormal.PrefillDecode.Types
import TpuSyncFormal.PrefillDecode.State
import TpuSyncFormal.PrefillDecode.Step

/-!
# Prefill-to-Decode Transfer Safety: Formal Properties

This module defines the three core safety specifications outlined in Section 2
of `proposal.md`:
1. `PublicationCorrectness`: Decode consumer only accesses fully committed, correct HBM.
2. `SourceBufferSafety`: Prefill producer never frees or overwrites source HBM while D2H reads are in flight.
3. `StagingResourceIntegrity`: Host staging DRAM is held throughout in-flight operations and released upon settlement.

## Status

All of these properties (plus `ConsumerAttentionSafety`) are **proved to hold on every
reachable state** of the model, for *both* `CheckMode`s — including
`CheckMode.transportOrderingDependent`, which is the completion predicate TPU Sync
actually ships. See `TpuSyncFormal.PrefillDecode.reachable_system_safety` in
`Proof.lean`, which is discharged from the inductive invariant in `Invariants.lean`.
No property in this file is currently known to be violated by TPU Sync.
-/

namespace TpuSyncFormal.PrefillDecode

/-- Expected KV cache block data for request `cfg.reqId` at layer `l` and block `b`. -/
def expectedBlockContent (cfg : TransferConfig) (l : LayerId) (b : BlockId) : BlockContent :=
  { sourceReq := cfg.reqId, layer := l, block := b, tag := 1 }

/-- Property 1: Publication Correctness.
    When `done_recving` is signaled to the engine:
    1. Every requested KV block across all layers is fully written into decode TPU HBM.
    2. The content in HBM exactly matches the expected prefill block contents.
    3. If attention kernels are launched (`consumerConsumed = true`), every block is present and correct. -/
def PublicationCorrectness (s : SystemState) : Prop :=
  s.doneRecving = true →
    (∀ l : LayerId, l < s.config.numLayers →
     ∀ b : BlockId, b < s.config.numBlocks →
       s.mem.decodeHbm l b = some (expectedBlockContent s.config l b))

/-- Stronger publication safety: the decode engine never executes attention kernels on incomplete data. -/
def ConsumerAttentionSafety (s : SystemState) : Prop :=
  s.consumerConsumed = true →
    (∀ l : LayerId, l < s.config.numLayers →
     ∀ b : BlockId, b < s.config.numBlocks →
       s.mem.decodeHbm l b = some (expectedBlockContent s.config l b))

/-- Property 2: Source Buffer Safety.
    When `done_sending` is signaled:
    1. All D2H DMA reads from prefill HBM have completed.
    2. No DMA reads remain in-flight.
    3. Prefill engine buffer reclaim (`sourceBufferFreed`) only occurs when all D2H reads are done. -/
def SourceBufferSafety (s : SystemState) : Prop :=
  (s.doneSending = true →
    ∀ l : LayerId, l < s.config.numLayers →
      s.producer.d2hCompleted l = true) ∧
  (s.sourceBufferFreed = true →
    ∀ l : LayerId, l < s.config.numLayers →
      s.producer.d2hCompleted l = true)

/-- Property 3: Staging Resource Integrity.
    1. Staging DRAM is guaranteed to be held whenever operations are in flight.
    2. Staging DRAM is guaranteed to be released once the session is settled (`done = true`). -/
def StagingResourceIntegrity (s : SystemState) : Prop :=
  (s.consumer.done = true → s.consumer.hasStaging = false) ∧
  (s.consumer.inFlight > 0 ∧ ¬ s.consumer.done → s.consumer.hasStaging = true)

/-- Combined system safety theorem specification. -/
def SystemSafety (s : SystemState) : Prop :=
  PublicationCorrectness s ∧
  ConsumerAttentionSafety s ∧
  SourceBufferSafety s ∧
  StagingResourceIntegrity s

end TpuSyncFormal.PrefillDecode
