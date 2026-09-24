import TpuSyncFormal.PrefillDecode.Types
import TpuSyncFormal.PrefillDecode.State
import TpuSyncFormal.PrefillDecode.Step
import TpuSyncFormal.PrefillDecode.Properties
import TpuSyncFormal.PrefillDecode.Invariants

/-!
# Prefill-to-Decode Transfer Safety: Main Results

This module states the end-to-end results about TPU Sync's prefill-to-decode
pipeline as modelled here. The headline is:

> The completion predicate that TPU Sync actually ships,
> `TransferReceiveSession::IsReadyToComplete()`
> (`tpu_sync/core/transfer_receive_session.cc:425-430`)
> ```cpp
> return (network_completed_ ||
>         num_completed_layers_ == static_cast<int32_t>(total_layers)) &&
>        AllH2dDoneLocked();
> ```
> is **safe**. On every reachable state it implies that all `num_layers` H2D copies
> have completed, and therefore that every KV block is committed to decode HBM
> before `done_recving` is published.

## Why the `network_completed_` disjunct is not a hole

`AllH2dDoneLocked()` only iterates the futures currently in `h2d_futures_`, so read
in isolation it looks as though `network_completed_` could fire while some layer has
never been dispatched, making the check vacuous. It cannot, because the transport
dispatches a layer's H2D copy *before* it accounts that layer's blocks:
`BlockTransport::HandleCustomRequest` calls
`block_delegate_->OnLayerReceived(l, header.uuid)` (`transport/block_transport.cc:525`),
which synchronously pushes the H2D future into `h2d_futures_`
(`transfer_receive_session.cc:594-598`), and only afterwards calls
`block_delegate_->OnBlocksReceived(allocated_ids, header.uuid)`
(`transport/block_transport.cc:533`), which is what advances `num_completed_blocks_`
towards `total_blocks_ * total_layers` and sets `network_completed_`
(`transfer_receive_session.cc:432-452`). Since `total_blocks_` is summed over all
senders of the plan (`transfer_receive_session.cc:176-199`), the threshold cannot be
tripped early on a multi-sender plan either.

That ordering is modelled by the precondition of `Step.networkAccountLayerBlocks` and
yields the inductive `transport_ordering_invariant` below, from which the safety of
the shipping predicate follows.

## What was wrong with the earlier version of this model

An earlier version of this development fused data landing and block accounting into a
single `stepNetworkDeliverChunk` transition with no dependency on H2D dispatch. That
model permitted all accounting to complete before any layer was dispatched and hence
"proved" a publication bug in the shipping C++. The defect was in the model, not in
the code. The trace is retained, honestly reframed, in `HypotheticalReordering.lean`.

## Modelling assumptions — what these theorems do *not* establish

These are proofs about a model. They are only as strong as the correspondence, so the
assumptions are listed explicitly:

1. **Per-layer atomic accounting.** `Step.networkAccountLayerBlocks` accounts *all* of a
   layer's blocks in one event that must follow the layer's dispatch. With several
   senders per layer the real code may account some of layer `l`'s blocks before
   `OnLayerReceived(l)` fires; what the C++ guarantees is that the accounting which
   *completes* layer `l` follows dispatch (`trigger_completion`,
   `transport/block_transport.cc:441-525`), so the threshold
   `total_blocks_ * total_layers` cannot be reached before every layer is dispatched.
   The model lumps a layer's partial accountings into that final event. This step of
   the argument is justified by code reading, **not** by a Lean proof.
2. **Exactly-once accounting.** The `blocksAccounted` ledger assumes a layer's blocks are
   folded into `num_completed_blocks_` once. Duplicate or retried requests, and the
   deduplication in `transfer_receive_session.cc:176-199`, are not modelled.
3. **Scope.** One request/session with a uniform `numBlocks` per layer; no concurrent
   sessions, no `plan_declared` / `OnPoolReceived` resharding-pool path, no failed H2D
   or D2H copies (`status_or` error branches), no wall-clock deadline arithmetic beyond
   the abstract `Step.consumerTimeout` / `Step.producerTimeout` events.
4. **Concurrency abstraction.** This is an interleaving transition system: each C++
   critical section is treated as one atomic step. Data races *inside* a step, memory
   ordering, and lock-acquisition interleavings are out of scope.
5. **H2D completion is one event here, two in the C++.** `Step.h2dComplete` simultaneously
   makes the layer's copy observable to `AllH2dDoneLocked()` *and* increments
   `completedLayers`. The real system separates these: `AllH2dDoneLocked()` tests
   `f.IsReady()` (`transfer_receive_session.cc:418-423`), whereas `num_completed_layers_`
   is bumped inside the `OnReady` callback (`:610-619`), which must first acquire `mu_` —
   the same mutex `IsReadyToComplete()` holds (`:425-430`). A poll landing in that window
   sees `IsReady() = true` with `num_completed_layers_` still behind.

   **Consequence: `readiness_predicates_agree` does not transfer to the C++.** In that
   window the shipping predicate publishes (safely — the DMA is done) while the stricter
   self-contained predicate waits for the callback. The two are equal *in this model* only
   because the model fuses the two events. Do not read that theorem as "the stricter form
   is a free substitution"; on the real code it delays publication, which is why the
   shipping disjunct is best understood as an intentional fast path rather than laxness.
6. **Pinned revision.** Line citations refer to tpu-sync `b68161a` (see `tpu-sync.rev`).
-/

namespace TpuSyncFormal.PrefillDecode

/-! ## 1. The transport ordering invariant -/

/-- **Transport ordering invariant.** On every reachable state, if the receive
    session considers the network transfer complete then every layer's H2D copy has
    already been dispatched — i.e. `h2d_futures_` has an entry for every layer, so
    `AllH2dDoneLocked()` is a check over all `numLayers` layers. -/
theorem transport_ordering_invariant {cfg : TransferConfig} {mode : CheckMode}
    {s : SystemState} (hR : Reachable (initialState cfg mode) s) :
    s.consumer.networkCompleted = true →
      ∀ l, l < s.config.numLayers → s.consumer.h2dDispatched l = true :=
  (inv_of_reachable hR).networkCompleted_dispatched

/-! ## 2. The shipping predicate is safe -/

/-- **MAIN RESULT.** On every reachable state, if the *shipping* predicate
    `(network_completed_ || num_completed_layers_ == total_layers) && AllH2dDoneLocked()`
    evaluates to `true`, then every layer has finished its H2D DMA copy.

    Note that no `CheckMode` hypothesis is needed: the statement is about the shipping
    Boolean expression itself, on any reachable state of the corrected model. -/
theorem shipping_predicate_implies_all_h2d_completed {cfg : TransferConfig}
    {mode : CheckMode} {s : SystemState}
    (hR : Reachable (initialState cfg mode) s)
    (hReady : readyShipping s = true) :
    ∀ l, l < s.config.numLayers → s.consumer.h2dCompleted l = true :=
  readyShipping_implies_all_h2dCompleted s
    (inv_of_reachable hR).completedLayers_count
    (inv_of_reachable hR).networkCompleted_dispatched
    hReady

/-- Consequence of the main result: when the shipping predicate fires, every block of
    every layer is already committed, with the correct contents, in decode HBM. So
    completing the session at that point cannot publish a partial transfer. -/
theorem shipping_predicate_implies_hbm_committed {cfg : TransferConfig}
    {mode : CheckMode} {s : SystemState}
    (hR : Reachable (initialState cfg mode) s)
    (hReady : readyShipping s = true) :
    ∀ l, l < s.config.numLayers → ∀ b, b < s.config.numBlocks →
      s.mem.decodeHbm l b = some (expectedBlockContent s.config l b) := by
  intro l hl b hb
  exact (inv_of_reachable hR).h2dCompleted_hbm l
    (shipping_predicate_implies_all_h2d_completed hR hReady l hl) b hb

/-- The same statement phrased for whichever mode the model was instantiated with. -/
theorem isReadyToComplete_implies_all_h2d_completed {cfg : TransferConfig}
    {mode : CheckMode} {s : SystemState}
    (hR : Reachable (initialState cfg mode) s)
    (hReady : isReadyToComplete s = true) :
    ∀ l, l < s.config.numLayers → s.consumer.h2dCompleted l = true :=
  ready_implies_all_h2dCompleted s
    (inv_of_reachable hR).completedLayers_count
    (inv_of_reachable hR).networkCompleted_dispatched
    hReady

/-- Bool extensionality helper. -/
private theorem bool_eq_of_iff {a b : Bool} (h1 : a = true → b = true)
    (h2 : b = true → a = true) : a = b := by
  cases a <;> cases b <;> simp_all

/-- **The shipping predicate and the self-contained predicate agree** on every
    reachable state. The stricter `readySelfContained` is therefore not a bug fix; it
    is the same test, written without relying on the transport's ordering guarantee. -/
theorem readiness_predicates_agree {cfg : TransferConfig} {mode : CheckMode}
    {s : SystemState} (hR : Reachable (initialState cfg mode) s) :
    readyShipping s = readySelfContained s := by
  have inv := inv_of_reachable hR
  refine bool_eq_of_iff (fun h => ?_) (fun h => ?_)
  · exact all_h2dCompleted_implies_readySelfContained s inv.completedLayers_count
      (shipping_predicate_implies_all_h2d_completed hR h)
  · exact all_h2dCompleted_implies_readyShipping s inv.completedLayers_count
      (readySelfContained_implies_all_h2dCompleted s h)

/-! ## 3. End-to-end safety of every reachable state -/

/-- Publication Correctness holds on every reachable state, in either mode. -/
theorem reachable_publication_correctness {cfg : TransferConfig} {mode : CheckMode}
    {s : SystemState} (hR : Reachable (initialState cfg mode) s) :
    PublicationCorrectness s := by
  intro hdone l hl b hb
  have inv := inv_of_reachable hR
  exact inv.h2dCompleted_hbm l (inv.doneRecving_h2dDone hdone l hl) b hb

/-- Consumer Attention Safety holds on every reachable state: the decode engine never
    runs attention kernels over uncommitted HBM. -/
theorem reachable_attention_safety {cfg : TransferConfig} {mode : CheckMode}
    {s : SystemState} (hR : Reachable (initialState cfg mode) s) :
    ConsumerAttentionSafety s := by
  intro hconsumed l hl b hb
  have inv := inv_of_reachable hR
  exact inv.h2dCompleted_hbm l
    (inv.doneRecving_h2dDone (inv.consumed_doneRecving hconsumed) l hl) b hb

/-- Source Buffer Safety holds on every reachable state. -/
theorem reachable_source_buffer_safety {cfg : TransferConfig} {mode : CheckMode}
    {s : SystemState} (hR : Reachable (initialState cfg mode) s) :
    SourceBufferSafety s :=
  ⟨(inv_of_reachable hR).doneSending_d2hDone, (inv_of_reachable hR).sourceFreed_d2hDone⟩

/-- Staging Resource Integrity holds on every reachable state. -/
theorem reachable_staging_integrity {cfg : TransferConfig} {mode : CheckMode}
    {s : SystemState} (hR : Reachable (initialState cfg mode) s) :
    StagingResourceIntegrity s := by
  have hflag := (inv_of_reachable hR).stagingFlag
  constructor
  · intro hdone
    rw [hflag, hdone]
    rfl
  · intro hcase
    have hnot : s.consumer.done = false := by
      cases hd : s.consumer.done with
      | false => rfl
      | true => exact absurd hd hcase.2
    rw [hflag, hnot]
    rfl

/-- **End-to-end theorem.** Every state reachable from an initial state satisfies the
    full safety specification, *including* when the model is instantiated with the
    shipping completion predicate (`CheckMode.transportOrderingDependent`). -/
theorem reachable_system_safety {cfg : TransferConfig} {mode : CheckMode}
    {s : SystemState} (hR : Reachable (initialState cfg mode) s) :
    SystemSafety s :=
  ⟨reachable_publication_correctness hR, reachable_attention_safety hR,
    reachable_source_buffer_safety hR, reachable_staging_integrity hR⟩

/-- Specialisation to the shipping predicate, spelled out for the record. -/
theorem shipping_mode_is_safe {cfg : TransferConfig} {s : SystemState}
    (hR : Reachable (initialState cfg CheckMode.transportOrderingDependent) s) :
    SystemSafety s :=
  reachable_system_safety hR

/-! ## 4. A concrete execution under the real transport ordering

The theorems above are vacuous if no interesting state is reachable, so we exhibit a
complete 2-layer transfer that runs to `done_recving` with the *shipping* predicate
enabled, and check the interesting intermediate states by evaluation. -/

/-- Concrete 2-layer, 1-block configuration. -/
def demoConfig : TransferConfig := {
  reqId := 42
  numLayers := 2
  numBlocks := 1
  numLayers_pos := by decide
  numBlocks_pos := by decide
}

/-- Initial state with the shipping completion predicate enabled. -/
def demoInit : SystemState := initialState demoConfig CheckMode.transportOrderingDependent

-- A full transfer. Note steps 11-14: the transport dispatches layer `l`'s H2D copy
-- (`OnLayerReceived`) before accounting layer `l`'s blocks (`OnBlocksReceived`).
def t1  := stepD2hDispatch demoInit 0
def t2  := stepD2hComplete t1 0
def t3  := stepD2hDispatch t2 1
def t4  := stepD2hComplete t3 1
def t5  := stepH2hDispatch t4 0
def t6  := stepH2hComplete t5 0
def t7  := stepH2hDispatch t6 1
def t8  := stepH2hComplete t7 1
def t9  := stepNetworkLandChunk t8 0 0
def t10 := stepNetworkLandChunk t9 1 0
def t11 := stepH2dDispatch t10 0
def t12 := stepNetworkAccountLayerBlocks t11 0
def t13 := stepH2dDispatch t12 1
def t14 := stepNetworkAccountLayerBlocks t13 1
def t15 := stepH2dComplete t14 0
def t16 := stepH2dComplete t15 1
def t17 := stepConsumerCompleteReadRaw t16
def t18 := stepDecodeConsumeAttention t17

theorem t1_valid : Step demoInit t1 := by
  apply Step.d2hDispatch 0
  · decide
  · rfl
  · rfl

theorem t2_valid : Step t1 t2 := by
  apply Step.d2hComplete 0
  · decide
  · rfl
  · rfl
  · decide

theorem t3_valid : Step t2 t3 := by
  apply Step.d2hDispatch 1
  · decide
  · rfl
  · rfl

theorem t4_valid : Step t3 t4 := by
  apply Step.d2hComplete 1
  · decide
  · rfl
  · rfl
  · decide

theorem t5_valid : Step t4 t5 := by
  apply Step.h2hDispatch 0
  · decide
  · rfl
  · rfl
  · rfl

theorem t6_valid : Step t5 t6 := by
  apply Step.h2hComplete 0
  · decide
  · rfl
  · rfl
  · decide
  · decide

theorem t7_valid : Step t6 t7 := by
  apply Step.h2hDispatch 1
  · decide
  · rfl
  · rfl
  · rfl

theorem t8_valid : Step t7 t8 := by
  apply Step.h2hComplete 1
  · decide
  · rfl
  · rfl
  · decide
  · decide

/-- Layer 0's chunk lands in consumer host staging. No counter moves. -/
theorem t9_valid : Step t8 t9 := by
  apply Step.networkLandChunk 0 0
  · decide
  · decide
  · decide
  · rfl

/-- Layer 1's chunk lands in consumer host staging. Still no counter moves:
    landing bytes in host DRAM is invisible to the session. -/
theorem t10_valid : Step t9 t10 := by
  apply Step.networkLandChunk 1 0
  · decide
  · decide
  · decide
  · rfl

/-- `OnLayerReceived(0)`: layer 0's H2D copy is dispatched. -/
theorem t11_valid : Step t10 t11 := by
  apply Step.h2dDispatch 0
  · decide
  · rfl
  · rfl
  · rfl
  · intro b hb
    cases b with
    | zero => decide
    | succ n => contradiction

/-- `OnBlocksReceived` for layer 0's request — legal only because layer 0 was
    dispatched first. -/
theorem t12_valid : Step t11 t12 := by
  apply Step.networkAccountLayerBlocks 0
  · decide
  · rfl
  · rfl

/-- `OnLayerReceived(1)`: layer 1's H2D copy is dispatched. -/
theorem t13_valid : Step t12 t13 := by
  apply Step.h2dDispatch 1
  · decide
  · rfl
  · rfl
  · rfl
  · intro b hb
    cases b with
    | zero => decide
    | succ n => contradiction

/-- `OnBlocksReceived` for layer 1's request. This is the event that trips
    `num_completed_blocks_ >= total_blocks_ * total_layers` and sets
    `network_completed_`. -/
theorem t14_valid : Step t13 t14 := by
  apply Step.networkAccountLayerBlocks 1
  · decide
  · rfl
  · rfl

theorem t15_valid : Step t14 t15 := by
  apply Step.h2dComplete 0
  · decide
  · rfl
  · rfl
  · decide

theorem t16_valid : Step t15 t16 := by
  apply Step.h2dComplete 1
  · decide
  · rfl
  · rfl
  · decide

theorem t17_valid : Step t16 t17 := by
  apply Step.consumerCompleteReadRaw
  · rfl
  · rfl
  · rfl

theorem t18_valid : Step t17 t18 := by
  apply Step.decodeConsumeAttention
  · rfl
  · rfl

/-- The completed state `t18` is reachable from `demoInit`. -/
theorem demo_reachable : Reachable demoInit t18 := by
  apply Reachable.step
  · apply Reachable.step
    · apply Reachable.step
      · apply Reachable.step
        · apply Reachable.step
          · apply Reachable.step
            · apply Reachable.step
              · apply Reachable.step
                · apply Reachable.step
                  · apply Reachable.step
                    · apply Reachable.step
                      · apply Reachable.step
                        · apply Reachable.step
                          · apply Reachable.step
                            · apply Reachable.step
                              · apply Reachable.step
                                · apply Reachable.step
                                  · apply Reachable.step
                                    · exact Reachable.refl
                                    · exact t1_valid
                                  · exact t2_valid
                                · exact t3_valid
                              · exact t4_valid
                            · exact t5_valid
                          · exact t6_valid
                        · exact t7_valid
                      · exact t8_valid
                    · exact t9_valid
                  · exact t10_valid
                · exact t11_valid
              · exact t12_valid
            · exact t13_valid
          · exact t14_valid
        · exact t15_valid
      · exact t16_valid
    · exact t17_valid
  · exact t18_valid

/-! ### What the trace shows about the shipping predicate

At `t14` the session has `network_completed_ = true` while *no* H2D copy has finished
yet. In the earlier, incorrect model this was the dangerous state, because layer 1 had
never been dispatched and `AllH2dDoneLocked()` skipped it. Under the real transport
ordering, `network_completed_` at `t14` implies both layers are already in
`h2d_futures_`, so `AllH2dDoneLocked()` — and with it the shipping predicate — is
correctly `false` at `t14` and at `t15`, and only becomes `true` at `t16`. -/

/-- `network_completed_` is set at `t14`. -/
theorem networkCompleted_at_t14 : t14.consumer.networkCompleted = true := by rfl

/-- ... and at that moment both layers are already dispatched: the transport ordering
    invariant, witnessed concretely. -/
theorem all_dispatched_at_t14 :
    t14.consumer.h2dDispatched 0 = true ∧ t14.consumer.h2dDispatched 1 = true :=
  ⟨rfl, rfl⟩

/-- No H2D copy has completed at `t14`, yet the shipping predicate is `false`, because
    `AllH2dDoneLocked()` now genuinely covers both layers. -/
theorem shipping_not_ready_at_t14 : readyShipping t14 = false := by rfl

/-- Even after layer 0 completes, the shipping predicate stays `false` while layer 1's
    H2D copy is outstanding. This is exactly the state that the earlier, incorrect
    model claimed was publishable. -/
theorem shipping_not_ready_at_t15 : readyShipping t15 = false := by rfl

/-- Once both H2D copies complete, the shipping predicate fires. -/
theorem shipping_ready_at_t16 : readyShipping t16 = true := by rfl

/-- The two readiness predicates agree on `t15`, concretely. -/
theorem predicates_agree_at_t15 : readyShipping t15 = readySelfContained t15 := by rfl

/-- The session settles cleanly and publishes `done_recving`. -/
theorem doneRecving_at_t18 : t18.doneRecving = true := by rfl

/-- The demo execution satisfies the full safety specification — obtained from the
    general theorem, not by evaluating this particular state. -/
theorem demo_system_safety : SystemSafety t18 := reachable_system_safety demo_reachable

/-- Publication Correctness for the demo execution. -/
theorem demo_publication_correctness : PublicationCorrectness t18 :=
  demo_system_safety.1

/-- Consumer Attention Safety for the demo execution. -/
theorem demo_attention_safety : ConsumerAttentionSafety t18 :=
  demo_system_safety.2.1

/-- Both layers really are committed to decode HBM in the final state. -/
theorem demo_hbm_complete :
    t18.mem.decodeHbm 0 0 = some (expectedBlockContent demoConfig 0 0) ∧
    t18.mem.decodeHbm 1 0 = some (expectedBlockContent demoConfig 1 0) :=
  ⟨rfl, rfl⟩

end TpuSyncFormal.PrefillDecode
