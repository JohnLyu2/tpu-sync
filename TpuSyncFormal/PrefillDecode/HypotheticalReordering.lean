import TpuSyncFormal.PrefillDecode.Types
import TpuSyncFormal.PrefillDecode.State
import TpuSyncFormal.PrefillDecode.Step
import TpuSyncFormal.PrefillDecode.Properties
import TpuSyncFormal.PrefillDecode.Invariants
import TpuSyncFormal.PrefillDecode.Proof

/-!
# A Hypothetical Reordering of the Transport (NOT a defect in TPU Sync)

> **This file does not describe a bug in the shipping code.**
> The completion predicate that TPU Sync ships,
> `TransferReceiveSession::IsReadyToComplete()`
> (`tpu_sync/core/transfer_receive_session.cc:425-430`), is *correct* under the real
> transport. That is proved in `Proof.lean`
> (`shipping_predicate_implies_all_h2d_completed`, `reachable_system_safety`).
> What follows is a counterfactual: it shows which property of the transport the
> predicate depends on, by exhibiting what would break if that property were removed.

## History

An earlier version of this model fused two distinct transport events into a single
transition: landing a chunk's payload in consumer host staging, *and* accounting that
chunk's blocks into `num_completed_blocks_`. The fused transition had no dependency on
H2D dispatch, so the model allowed all block accounting (and hence
`network_completed_`) to complete before any layer was ever dispatched. In that model
`AllH2dDoneLocked()` — which iterates only over the futures present in `h2d_futures_` —
was vacuous, and the 15-step trace below "proved" a publication bug.

The trace is real, but the model was not. An audit of the C++ established that the
transport always dispatches a layer's H2D copy before it accounts that layer's blocks:
`BlockTransport::HandleCustomRequest` calls
`block_delegate_->OnLayerReceived(l, header.uuid)` (`transport/block_transport.cc:525`),
which synchronously pushes the H2D future into `h2d_futures_`
(`transfer_receive_session.cc:594-598`), before calling
`block_delegate_->OnBlocksReceived(allocated_ids, header.uuid)`
(`transport/block_transport.cc:533`). `Step.networkAccountLayerBlocks` now carries that
ordering as a precondition, and the trace below is *not* a `Step` execution any more.

## What this file actually proves

We keep the trace and label it accurately. `ReorderedStep` is the corrected `Step`
relation extended with one extra, deliberately unsound transition
(`accountBeforeDispatch`) that accounts a layer's blocks *without* requiring the layer
to have been dispatched — i.e. a transport in which `OnBlocksReceived` may overtake
`OnLayerReceived`. Under that hypothetical transport:

* the trace reaches a state where `done_recving` is published with layer 1 never
  written to decode HBM (`violates_publication_correctness_when_transport_ordering_omitted`);
* the decode engine then runs attention over that hole
  (`violates_attention_safety_when_transport_ordering_omitted`);
* and the precise invariant that fails is the transport ordering invariant
  (`reordering_breaks_transport_ordering_invariant`).

Read as a *requirement document*: if anyone ever changes the transport so that blocks
are accounted before the corresponding `OnLayerReceived`, then
`IsReadyToComplete()` must be strengthened to `readySelfContained` (drop the
`network_completed_ ||` disjunct, or enumerate all `num_layers` layers).
-/

namespace TpuSyncFormal.PrefillDecode

/-- A hypothetical transport that may account a layer's blocks before dispatching that
    layer's H2D copy. It is the corrected `Step` relation plus the single extra
    transition `accountBeforeDispatch`; nothing else is weakened.

    Note that `accountBeforeDispatch` reuses exactly the same state transformers as the
    real model (`stepNetworkLandChunk` followed by `stepNetworkAccountLayerBlocks`);
    the *only* difference from `Step.networkLandChunk` + `Step.networkAccountLayerBlocks`
    is the missing `h2dDispatched l = true` precondition. -/
inductive ReorderedStep : SystemState → SystemState → Prop where
  /-- Everything the real transport can do. -/
  | transportOrdered {s s' : SystemState} : Step s s' → ReorderedStep s s'
  /-- The counterfactual: `OnBlocksReceived` overtaking `OnLayerReceived`. -/
  | accountBeforeDispatch (l : LayerId) (b : BlockId) (s : SystemState) :
      l < s.config.numLayers →
      b < s.config.numBlocks →
      s.mem.networkInFlight l b ≠ none →
      s.mem.decodeStaging l b = none →
      s.consumer.blocksAccounted l = false →
      ReorderedStep s (stepNetworkAccountLayerBlocks (stepNetworkLandChunk s l b) l)

/-- Reachability under the hypothetical transport. -/
inductive ReorderedReachable (init : SystemState) : SystemState → Prop where
  | refl : ReorderedReachable init init
  | step {s s' : SystemState} :
      ReorderedReachable init s → ReorderedStep s s' → ReorderedReachable init s'

/-- Concrete 2-layer, 1-block configuration. -/
def reorderConfig : TransferConfig := {
  reqId := 42
  numLayers := 2
  numBlocks := 1
  numLayers_pos := by decide
  numBlocks_pos := by decide
}

/-- Initial state with the shipping completion predicate enabled. -/
def reorderInit : SystemState :=
  initialState reorderConfig CheckMode.transportOrderingDependent

-- Trace definition: 15 discrete transitions. Steps 1-8 and 11-15 are ordinary `Step`s;
-- only steps 9 and 10 use the hypothetical `accountBeforeDispatch` transition.
def u1  := stepD2hDispatch reorderInit 0
def u2  := stepD2hComplete u1 0
def u3  := stepD2hDispatch u2 1
def u4  := stepD2hComplete u3 1
def u5  := stepH2hDispatch u4 0
def u6  := stepH2hComplete u5 0
def u7  := stepH2hDispatch u6 1
def u8  := stepH2hComplete u7 1
def u9  := stepNetworkAccountLayerBlocks (stepNetworkLandChunk u8 0 0) 0
def u10 := stepNetworkAccountLayerBlocks (stepNetworkLandChunk u9 1 0) 1
def u11 := stepH2dDispatch u10 0
def u12 := stepH2dComplete u11 0
def u13 := stepConsumerPollComplete u12
def u14 := stepConsumerCompleteReadRaw u13
def u15 := stepDecodeConsumeAttention u14

/-- Step 1 validity: D2H dispatch for layer 0 is enabled. -/
theorem ustep1_valid : ReorderedStep reorderInit u1 := by
  apply ReorderedStep.transportOrdered
  apply Step.d2hDispatch 0
  · decide
  · rfl
  · rfl

/-- Step 2 validity: D2H complete for layer 0 is enabled. -/
theorem ustep2_valid : ReorderedStep u1 u2 := by
  apply ReorderedStep.transportOrdered
  apply Step.d2hComplete 0
  · decide
  · rfl
  · rfl
  · decide

/-- Step 3 validity: D2H dispatch for layer 1 is enabled. -/
theorem ustep3_valid : ReorderedStep u2 u3 := by
  apply ReorderedStep.transportOrdered
  apply Step.d2hDispatch 1
  · decide
  · rfl
  · rfl

/-- Step 4 validity: D2H complete for layer 1 is enabled. -/
theorem ustep4_valid : ReorderedStep u3 u4 := by
  apply ReorderedStep.transportOrdered
  apply Step.d2hComplete 1
  · decide
  · rfl
  · rfl
  · decide

/-- Step 5 validity: H2H dispatch for layer 0 is enabled. -/
theorem ustep5_valid : ReorderedStep u4 u5 := by
  apply ReorderedStep.transportOrdered
  apply Step.h2hDispatch 0
  · decide
  · rfl
  · rfl
  · rfl

/-- Step 6 validity: H2H complete for layer 0 is enabled. -/
theorem ustep6_valid : ReorderedStep u5 u6 := by
  apply ReorderedStep.transportOrdered
  apply Step.h2hComplete 0
  · decide
  · rfl
  · rfl
  · decide
  · decide

/-- Step 7 validity: H2H dispatch for layer 1 is enabled. -/
theorem ustep7_valid : ReorderedStep u6 u7 := by
  apply ReorderedStep.transportOrdered
  apply Step.h2hDispatch 1
  · decide
  · rfl
  · rfl
  · rfl

/-- Step 8 validity: H2H complete for layer 1 is enabled. -/
theorem ustep8_valid : ReorderedStep u7 u8 := by
  apply ReorderedStep.transportOrdered
  apply Step.h2hComplete 1
  · decide
  · rfl
  · rfl
  · decide
  · decide

/-- Step 9: **hypothetical**. Layer 0's chunk lands *and* its blocks are accounted,
    with no `OnLayerReceived(0)` in between. The real transport cannot do this. -/
theorem ustep9_hypothetical : ReorderedStep u8 u9 := by
  apply ReorderedStep.accountBeforeDispatch 0 0
  · decide
  · decide
  · decide
  · rfl
  · rfl

/-- Step 10: **hypothetical**. Same for layer 1. This is the event that sets
    `network_completed_` while `h2d_futures_` is still empty. -/
theorem ustep10_hypothetical : ReorderedStep u9 u10 := by
  apply ReorderedStep.accountBeforeDispatch 1 0
  · decide
  · decide
  · decide
  · rfl
  · rfl

/-- Step 11 validity: Consumer dispatches H2D for layer 0 (and only layer 0). -/
theorem ustep11_valid : ReorderedStep u10 u11 := by
  apply ReorderedStep.transportOrdered
  apply Step.h2dDispatch 0
  · decide
  · rfl
  · rfl
  · rfl
  · intro b hb
    cases b with
    | zero => decide
    | succ n => contradiction

/-- Step 12 validity: Consumer completes H2D for layer 0. -/
theorem ustep12_valid : ReorderedStep u11 u12 := by
  apply ReorderedStep.transportOrdered
  apply Step.h2dComplete 0
  · decide
  · rfl
  · rfl
  · decide

/-- The consequence of the missing ordering: `network_completed_` is set while layer 1
    has no entry in `h2d_futures_`, so `AllH2dDoneLocked()` skips it and the shipping
    predicate fires with layer 1 unwritten. -/
theorem isReadyToComplete_at_u12 : isReadyToComplete u12 = true := by rfl

/-- Step 13 validity: polling completes the session on the strength of that check. -/
theorem ustep13_valid : ReorderedStep u12 u13 := by
  apply ReorderedStep.transportOrdered
  apply Step.consumerPollComplete
  · rfl
  · rfl
  · exact isReadyToComplete_at_u12

/-- Step 14 validity: Manager `CompleteReadRaw` emits `done_recving`. -/
theorem ustep14_valid : ReorderedStep u13 u14 := by
  apply ReorderedStep.transportOrdered
  apply Step.consumerCompleteReadRaw
  · rfl
  · rfl
  · rfl

/-- Step 15 validity: decode engine consumes uncommitted HBM. -/
theorem ustep15_valid : ReorderedStep u14 u15 := by
  apply ReorderedStep.transportOrdered
  apply Step.decodeConsumeAttention
  · rfl
  · rfl

/-- `u15` is reachable **only** under the hypothetical transport: the derivation uses
    `accountBeforeDispatch` at steps 9 and 10. -/
theorem hypothetical_trace_reachable : ReorderedReachable reorderInit u15 := by
  apply ReorderedReachable.step
  · apply ReorderedReachable.step
    · apply ReorderedReachable.step
      · apply ReorderedReachable.step
        · apply ReorderedReachable.step
          · apply ReorderedReachable.step
            · apply ReorderedReachable.step
              · apply ReorderedReachable.step
                · apply ReorderedReachable.step
                  · apply ReorderedReachable.step
                    · apply ReorderedReachable.step
                      · apply ReorderedReachable.step
                        · apply ReorderedReachable.step
                          · apply ReorderedReachable.step
                            · apply ReorderedReachable.step
                              · exact ReorderedReachable.refl
                              · exact ustep1_valid
                            · exact ustep2_valid
                          · exact ustep3_valid
                        · exact ustep4_valid
                      · exact ustep5_valid
                    · exact ustep6_valid
                  · exact ustep7_valid
                · exact ustep8_valid
              · exact ustep9_hypothetical
            · exact ustep10_hypothetical
          · exact ustep11_valid
        · exact ustep12_valid
      · exact ustep13_valid
    · exact ustep14_valid
  · exact ustep15_valid

/-- Layer 1, block 0 in decode HBM is completely missing in `u15`. -/
theorem layer1_hbm_missing_in_u15 : u15.mem.decodeHbm 1 0 = none := by rfl

/-- Decode engine has consumed attention memory in `u15`. -/
theorem consumed_in_u15 : u15.consumerConsumed = true := by rfl

/-- **Counterfactual result.** *If* the transport accounted blocks before dispatching a
    layer, Publication Correctness would be violated at the reachable state `u15`.
    Under the real transport ordering this state is not reachable; see
    `Proof.reachable_publication_correctness`. -/
theorem violates_publication_correctness_when_transport_ordering_omitted :
    ¬ PublicationCorrectness u15 := by
  intro hPub
  unfold PublicationCorrectness at hPub
  have hDoneRecv : u15.doneRecving = true := rfl
  have hAll := hPub hDoneRecv
  have hLayer1 := hAll 1 (by decide) 0 (by decide)
  revert hLayer1
  decide

/-- **Counterfactual result.** Likewise for Consumer Attention Safety. -/
theorem violates_attention_safety_when_transport_ordering_omitted :
    ¬ ConsumerAttentionSafety u15 := by
  intro hSafe
  unfold ConsumerAttentionSafety at hSafe
  have hConsumed : u15.consumerConsumed = true := rfl
  have hAll := hSafe hConsumed
  have hLayer1 := hAll 1 (by decide) 0 (by decide)
  revert hLayer1
  decide

/-! ## Exactly which invariant the reordering destroys -/

/-- At `u10` the hypothetical transport has set `network_completed_` while layer 1 has
    never been dispatched. -/
theorem reordering_breaks_ordering_at_u10 :
    u10.consumer.networkCompleted = true ∧ u10.consumer.h2dDispatched 1 = false :=
  ⟨rfl, rfl⟩

/-- Consequently `u10` violates the transport ordering invariant, and hence `Inv`.
    Since `Inv` is preserved by every `Step` and holds initially
    (`Invariants.inv_of_reachable`), `u10` is *not* reachable by `Step` from
    `reorderInit`: the counterexample lives strictly outside the real model. -/
theorem reordering_breaks_transport_ordering_invariant : ¬ Inv u10 := by
  intro hinv
  have hdisp : u10.consumer.h2dDispatched 1 = true :=
    hinv.networkCompleted_dispatched rfl 1 (by decide)
  rw [reordering_breaks_ordering_at_u10.2] at hdisp
  exact absurd hdisp (by decide)

/-- Restated as unreachability in the corrected model: no `Step`-execution from
    `reorderInit` ever reaches `u10`. -/
theorem u10_unreachable_under_real_transport : ¬ Reachable reorderInit u10 := by
  intro hR
  exact reordering_breaks_transport_ordering_invariant (inv_of_reachable hR)

/-- The state the old counterexample called "the vulnerability" — the shipping
    predicate `true` while layer 1 is unwritten — is likewise unreachable under the
    real transport. This follows from `shipping_predicate_implies_hbm_committed`, not
    from inspecting `u12`. -/
theorem u12_unreachable_under_real_transport : ¬ Reachable reorderInit u12 := by
  intro hR
  have hready : readyShipping u12 = true := rfl
  have h := shipping_predicate_implies_hbm_committed hR hready 1 (by decide) 0 (by decide)
  have hmissing : u12.mem.decodeHbm 1 0 = none := rfl
  rw [hmissing] at h
  exact absurd h (by simp)

/-- And so is the final "published a hole" state `u15`, by
    `reachable_publication_correctness`. -/
theorem u15_unreachable_under_real_transport : ¬ Reachable reorderInit u15 := by
  intro hR
  have h := reachable_publication_correctness hR rfl 1 (by decide) 0 (by decide)
  rw [layer1_hbm_missing_in_u15] at h
  exact absurd h (by simp)

end TpuSyncFormal.PrefillDecode
