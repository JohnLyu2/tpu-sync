import TpuSyncFormal.PrefillDecode.Types
import TpuSyncFormal.PrefillDecode.State
import TpuSyncFormal.PrefillDecode.Step
import TpuSyncFormal.PrefillDecode.Properties

/-!
# Prefill-to-Decode Transfer Safety: Inductive Invariants

This module carries the whole safety argument for the *corrected* model, in which
`Step.networkLandChunk` (data landing) and `Step.networkAccountLayerBlocks`
(session accounting) are distinct events and the latter may only fire after the
layer's H2D copy has been dispatched, exactly as
`BlockTransport::HandleCustomRequest` sequences
`OnLayerReceived` (`transport/block_transport.cc:525`) before
`OnBlocksReceived` (`transport/block_transport.cc:533`).

The central field of `Inv` is `networkCompleted_dispatched`, the **transport
ordering invariant**

    networkCompleted = true  →  ∀ l < numLayers, h2dDispatched l = true

which is what makes the shipping `IsReadyToComplete()` predicate safe: once
`network_completed_` is set, `h2d_futures_` already contains a future for every
layer, so `AllH2dDoneLocked()` is a check over all `numLayers` layers rather than
a vacuous one.

Everything else in `Inv` is the supporting cast needed to get from "the readiness
predicate fired" to "every KV block sits correctly in decode HBM":
counting invariants tying `num_completed_layers_` / `num_completed_blocks_` to the
per-layer flags, monotone dataflow invariants for the memory contents, and the
producer-side invariants that keep prefill HBM alive until every D2H read is done.
-/

namespace TpuSyncFormal.PrefillDecode

/-! ## A small counting library

`countTrue p n` counts how many of `0, 1, ..., n-1` satisfy `p`. It is the tool
that converts the C++ counters (`num_completed_layers_`, `num_completed_blocks_`)
into statements about *all* layers. The project deliberately has no Mathlib
dependency, so the handful of lemmas we need are proved here. -/

/-- Number of indices `x < n` with `p x = true`. -/
def countTrue (p : Nat → Bool) : Nat → Nat
  | 0 => 0
  | n + 1 => (if p n then 1 else 0) + countTrue p n

theorem countTrue_le (p : Nat → Bool) (n : Nat) : countTrue p n ≤ n := by
  induction n with
  | zero => simp [countTrue]
  | succ n ih =>
    simp only [countTrue]
    split <;> omega

theorem countTrue_congr {p q : Nat → Bool} (n : Nat) (h : ∀ x, x < n → p x = q x) :
    countTrue p n = countTrue q n := by
  induction n with
  | zero => rfl
  | succ n ih =>
    have hn : p n = q n := h n (Nat.lt_succ_self n)
    have hrest : countTrue p n = countTrue q n := ih (fun x hx => h x (Nat.lt_succ_of_lt hx))
    simp [countTrue, hn, hrest]

theorem countTrue_const_false (n : Nat) : countTrue (fun _ => false) n = 0 := by
  induction n with
  | zero => rfl
  | succ n ih => simp [countTrue, ih]

/-- Flipping one index from `false` to `true` increments the count. -/
theorem countTrue_update {p : Nat → Bool} {l : Nat} (hp : p l = false) (n : Nat) (hlt : l < n) :
    countTrue (fun x => if x = l then true else p x) n = countTrue p n + 1 := by
  induction n with
  | zero => omega
  | succ n ih =>
    rcases Nat.lt_succ_iff_lt_or_eq.mp hlt with h | h
    · have hne : ¬ (n = l) := by omega
      have hrec := ih h
      have hqn : (if n = l then true else p n) = p n := by simp [hne]
      rw [countTrue, countTrue, hrec, hqn]
      omega
    · subst h
      have hcong : countTrue (fun x => if x = l then true else p x) l = countTrue p l :=
        countTrue_congr l (fun x hx => by
          have hxne : ¬ (x = l) := by omega
          simp [hxne])
      have hql : (if l = l then true else p l) = true := by simp
      rw [countTrue, countTrue, hcong, hql, hp]
      simp
      omega

/-- A full count means the predicate holds everywhere below `n`.
    This is how "`num_completed_layers_ == total_layers`" becomes
    "every layer finished". -/
theorem countTrue_eq_all {p : Nat → Bool} (n : Nat) (h : countTrue p n = n) :
    ∀ l, l < n → p l = true := by
  induction n with
  | zero => intro l hl; omega
  | succ n ih =>
    have hle := countTrue_le p n
    simp only [countTrue] at h
    cases hpn : p n with
    | false =>
      rw [hpn] at h
      simp at h
      omega
    | true =>
      rw [hpn] at h
      simp at h
      have h' : countTrue p n = n := by omega
      intro l hl
      rcases Nat.lt_succ_iff_lt_or_eq.mp hl with hlt | heq
      · exact ih h' l hlt
      · subst heq; exact hpn

/-- Converse of `countTrue_eq_all`. -/
theorem countTrue_all (p : Nat → Bool) (n : Nat) (h : ∀ l, l < n → p l = true) :
    countTrue p n = n := by
  induction n with
  | zero => rfl
  | succ n ih =>
    have hn : p n = true := h n (Nat.lt_succ_self n)
    have hrest : countTrue p n = n := ih (fun x hx => h x (Nat.lt_succ_of_lt hx))
    rw [countTrue, hn, hrest]
    simp
    omega

/-! ## Pointwise flag updates

Every `stepX` that "sets a flag for layer `l`" does so as
`fun idx => if idx = l then true else old idx`; these two lemmas are the only
facts we need about that shape. -/

theorem updTrue {f : Nat → Bool} {l x : Nat} (h : f x = true) :
    (if x = l then true else f x) = true := by
  by_cases hx : x = l
  · simp [hx]
  · simp [hx, h]

theorem updCases {f : Nat → Bool} {l x : Nat} (h : (if x = l then true else f x) = true) :
    x = l ∨ f x = true := by
  by_cases hx : x = l
  · exact Or.inl hx
  · exact Or.inr (by simpa [hx] using h)

/-- Staging-slot bookkeeping for the steps that may settle the session. -/
theorem staging_update {hasStaging done nd : Bool} (h : hasStaging = !done) :
    (if nd = true then false else hasStaging) = !(done || nd) := by
  cases nd <;> simp [h]

/-- Staging-slot bookkeeping for steps that overwrite (rather than accumulate) `done`. -/
theorem staging_set {hasStaging nd : Bool} (h : hasStaging = true) :
    (if nd = true then false else hasStaging) = !nd := by
  cases nd <;> simp [h]

/-! ## The inductive invariant -/

/-- The conjunction of every fact we maintain along `Step`.

    Grouped as: producer structure, producer completion safety, memory dataflow,
    consumer counting + **transport ordering**, and consumer completion safety. -/
structure Inv (s : SystemState) : Prop where
  /-- `SendNextLayer` only pushes a layer whose D2H read already landed
      (`transfer_send_session.cc:410-415`). -/
  h2hDispatched_d2hCompleted :
    ∀ l, s.producer.h2hDispatched l = true → s.producer.d2hCompleted l = true
  /-- A completed H2H push was dispatched first. -/
  h2hCompleted_h2hDispatched :
    ∀ l, s.producer.h2hCompleted l = true → s.producer.h2hDispatched l = true
  /-- `remaining_h2h_layers_` really is the number of layers still to push. -/
  remainingH2h_count :
    s.producer.remainingH2h + countTrue s.producer.h2hCompleted s.config.numLayers
      = s.config.numLayers
  /-- A cleanly draining producer has finished every D2H read. -/
  producerDraining_d2hDone :
    s.producer.draining = true → s.producer.statusOk = true →
      ∀ l, l < s.config.numLayers → s.producer.d2hCompleted l = true
  /-- A cleanly settled producer has finished every D2H read. -/
  producerDone_d2hDone :
    s.producer.done = true → s.producer.statusOk = true →
      ∀ l, l < s.config.numLayers → s.producer.d2hCompleted l = true
  /-- `done_sending` is only published after every D2H read completed. -/
  doneSending_d2hDone :
    s.doneSending = true → ∀ l, l < s.config.numLayers → s.producer.d2hCompleted l = true
  /-- The prefill engine only reclaims its HBM after every D2H read completed. -/
  sourceFreed_d2hDone :
    s.sourceBufferFreed = true → ∀ l, l < s.config.numLayers → s.producer.d2hCompleted l = true
  /-- Until the prefill engine reclaims it, source HBM holds the expected data. -/
  prefillHbmIntact :
    s.sourceBufferFreed = false →
      ∀ l, l < s.config.numLayers → ∀ b, b < s.config.numBlocks →
        s.mem.prefillHbm l b = some (expectedBlockContent s.config l b)
  /-- Anything sitting in producer host staging is correct data. -/
  prefillStagingContent :
    ∀ l b c, s.mem.prefillStaging l b = some c → c = expectedBlockContent s.config l b
  /-- Anything in flight on the network is correct data. -/
  networkInFlightContent :
    ∀ l b c, s.mem.networkInFlight l b = some c → c = expectedBlockContent s.config l b
  /-- Anything in consumer host staging is correct data. -/
  decodeStagingContent :
    ∀ l b c, s.mem.decodeStaging l b = some c → c = expectedBlockContent s.config l b
  /-- `ExecuteLayerH2d` is only dispatched once the layer's blocks are all staged. -/
  h2dDispatched_staging :
    ∀ l, s.consumer.h2dDispatched l = true →
      ∀ b, b < s.config.numBlocks → s.mem.decodeStaging l b ≠ none
  /-- A completed H2D copy leaves the whole layer correct in decode HBM. -/
  h2dCompleted_hbm :
    ∀ l, s.consumer.h2dCompleted l = true →
      ∀ b, b < s.config.numBlocks →
        s.mem.decodeHbm l b = some (expectedBlockContent s.config l b)
  /-- A completed H2D copy was dispatched first (it has an entry in `h2d_futures_`). -/
  h2dCompleted_dispatched :
    ∀ l, s.consumer.h2dCompleted l = true → s.consumer.h2dDispatched l = true
  /-- `num_completed_layers_` counts exactly the layers whose H2D copy finished. -/
  completedLayers_count :
    s.consumer.completedLayers = countTrue s.consumer.h2dCompleted s.config.numLayers
  /-- `num_completed_blocks_` counts exactly the blocks of the accounted layers. -/
  completedBlocks_count :
    s.consumer.completedBlocks
      = s.config.numBlocks * countTrue s.consumer.blocksAccounted s.config.numLayers
  /-- **Ordering, per event:** a layer's blocks are only accounted after its H2D
      dispatch (`block_transport.cc:525` before `:533`). -/
  accounted_dispatched :
    ∀ l, s.consumer.blocksAccounted l = true → s.consumer.h2dDispatched l = true
  /-- **The transport ordering invariant.** `network_completed_` implies every layer
      already has a future in `h2d_futures_`, which is precisely what makes
      `AllH2dDoneLocked()` a total check in the shipping predicate. -/
  networkCompleted_dispatched :
    s.consumer.networkCompleted = true →
      ∀ l, l < s.config.numLayers → s.consumer.h2dDispatched l = true
  /-- A cleanly draining receive session has finished every H2D copy. -/
  consumerDraining_h2dDone :
    s.consumer.draining = true → s.consumer.statusOk = true →
      ∀ l, l < s.config.numLayers → s.consumer.h2dCompleted l = true
  /-- A cleanly settled receive session has finished every H2D copy. -/
  consumerDone_h2dDone :
    s.consumer.done = true → s.consumer.statusOk = true →
      ∀ l, l < s.config.numLayers → s.consumer.h2dCompleted l = true
  /-- `done_recving` is only published after every H2D copy completed. -/
  doneRecving_h2dDone :
    s.doneRecving = true → ∀ l, l < s.config.numLayers → s.consumer.h2dCompleted l = true
  /-- The decode engine only runs attention after `done_recving`. -/
  consumed_doneRecving : s.consumerConsumed = true → s.doneRecving = true
  /-- The staging slot is held exactly until the session settles. -/
  stagingFlag : s.consumer.hasStaging = !s.consumer.done

/-! ## Readiness implies completion

This is the key lemma about `IsReadyToComplete()`. Note that it holds for *both*
check modes: the shipping predicate is rescued by the transport ordering
invariant `hOrder`, the self-contained predicate needs no such help. -/

/-- **The shipping predicate is safe.** If
    `(network_completed_ || num_completed_layers_ == total_layers) && AllH2dDoneLocked()`
    holds in a state satisfying the layer-counting and *transport ordering*
    invariants, then every layer's H2D copy has completed.

    This is the formal content of "the shipping `IsReadyToComplete()` is not buggy":
    the `network_completed_` disjunct can only be taken when every layer is already
    in `h2d_futures_`, and then `AllH2dDoneLocked()` covers all of them. -/
theorem readyShipping_implies_all_h2dCompleted (s : SystemState)
    (hCount : s.consumer.completedLayers
      = countTrue s.consumer.h2dCompleted s.config.numLayers)
    (hOrder : s.consumer.networkCompleted = true →
      ∀ l, l < s.config.numLayers → s.consumer.h2dDispatched l = true)
    (hReady : readyShipping s = true) :
    ∀ l, l < s.config.numLayers → s.consumer.h2dCompleted l = true := by
  intro l hl
  unfold readyShipping at hReady
  have hAnd := (Bool.and_eq_true _ _).mp hReady
  have hAllDisp := hAnd.2
  unfold allDispatchedH2dDone at hAllDisp
  rw [List.all_eq_true] at hAllDisp
  have hMem : l ∈ List.range s.config.numLayers := List.mem_range.mpr hl
  have hcheck := hAllDisp l hMem
  rcases (Bool.or_eq_true _ _).mp hAnd.1 with hnet | hlayers
  · -- `network_completed_` branch: transport ordering makes `AllH2dDoneLocked()` total
    have hdisp := hOrder hnet l hl
    simpa [hdisp] using hcheck
  · -- `num_completed_layers_ == total_layers` branch: counting makes it total
    have heq : s.consumer.completedLayers = s.config.numLayers := by
      simpa using hlayers
    have hfull : countTrue s.consumer.h2dCompleted s.config.numLayers
        = s.config.numLayers := by rw [← hCount]; exact heq
    exact countTrue_eq_all _ hfull l hl

/-- The self-contained predicate names every layer explicitly, so it needs no
    transport-level assumption. -/
theorem readySelfContained_implies_all_h2dCompleted (s : SystemState)
    (hReady : readySelfContained s = true) :
    ∀ l, l < s.config.numLayers → s.consumer.h2dCompleted l = true := by
  intro l hl
  unfold readySelfContained at hReady
  have hAll := (Bool.and_eq_true _ _).mp hReady |>.2
  rw [List.all_eq_true] at hAll
  exact hAll l (List.mem_range.mpr hl)

/-- Either mode of `IsReadyToComplete()` implies every layer's H2D copy completed. -/
theorem ready_implies_all_h2dCompleted (s : SystemState)
    (hCount : s.consumer.completedLayers
      = countTrue s.consumer.h2dCompleted s.config.numLayers)
    (hOrder : s.consumer.networkCompleted = true →
      ∀ l, l < s.config.numLayers → s.consumer.h2dDispatched l = true)
    (hReady : isReadyToComplete s = true) :
    ∀ l, l < s.config.numLayers → s.consumer.h2dCompleted l = true := by
  unfold isReadyToComplete at hReady
  split at hReady
  · exact readyShipping_implies_all_h2dCompleted s hCount hOrder hReady
  · exact readySelfContained_implies_all_h2dCompleted s hReady

/-- Conversely, once every layer's H2D copy has completed the self-contained
    predicate fires. -/
theorem all_h2dCompleted_implies_readySelfContained (s : SystemState)
    (hCount : s.consumer.completedLayers
      = countTrue s.consumer.h2dCompleted s.config.numLayers)
    (hAll : ∀ l, l < s.config.numLayers → s.consumer.h2dCompleted l = true) :
    readySelfContained s = true := by
  unfold readySelfContained
  have hfull : s.consumer.completedLayers = s.config.numLayers := by
    rw [hCount]; exact countTrue_all _ _ hAll
  refine (Bool.and_eq_true _ _).mpr ⟨by simp [hfull], ?_⟩
  rw [List.all_eq_true]
  intro x hx
  exact hAll x (List.mem_range.mp hx)

/-- ... and so does the shipping predicate. -/
theorem all_h2dCompleted_implies_readyShipping (s : SystemState)
    (hCount : s.consumer.completedLayers
      = countTrue s.consumer.h2dCompleted s.config.numLayers)
    (hAll : ∀ l, l < s.config.numLayers → s.consumer.h2dCompleted l = true) :
    readyShipping s = true := by
  unfold readyShipping
  have hfull : s.consumer.completedLayers = s.config.numLayers := by
    rw [hCount]; exact countTrue_all _ _ hAll
  refine (Bool.and_eq_true _ _).mpr ⟨?_, ?_⟩
  · exact (Bool.or_eq_true _ _).mpr (Or.inr (by simp [hfull]))
  · unfold allDispatchedH2dDone
    rw [List.all_eq_true]
    intro x hx
    simp [hAll x (List.mem_range.mp hx)]

/-! ## The invariant holds initially and is preserved -/

theorem inv_initialState (cfg : TransferConfig) (mode : CheckMode) :
    Inv (initialState cfg mode) where
  h2hDispatched_d2hCompleted := by
    intro l h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  h2hCompleted_h2hDispatched := by
    intro l h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  remainingH2h_count := by
    show cfg.numLayers + countTrue (fun _ => false) cfg.numLayers = cfg.numLayers
    rw [countTrue_const_false]
    omega
  producerDraining_d2hDone := by
    intro h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  producerDone_d2hDone := by
    intro h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  doneSending_d2hDone := by
    intro h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  sourceFreed_d2hDone := by
    intro h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  prefillHbmIntact := by
    intro _ l hl b hb
    have hl' : l < cfg.numLayers := hl
    have hb' : b < cfg.numBlocks := hb
    show (if l < cfg.numLayers ∧ b < cfg.numBlocks then
            some { sourceReq := cfg.reqId, layer := l, block := b, tag := 1 }
          else none) = some (expectedBlockContent cfg l b)
    simp [expectedBlockContent, hl', hb']
  prefillStagingContent := by
    intro l b c h
    have h' : (none : Option BlockContent) = some c := h
    exact absurd h' (by simp)
  networkInFlightContent := by
    intro l b c h
    have h' : (none : Option BlockContent) = some c := h
    exact absurd h' (by simp)
  decodeStagingContent := by
    intro l b c h
    have h' : (none : Option BlockContent) = some c := h
    exact absurd h' (by simp)
  h2dDispatched_staging := by
    intro l h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  h2dCompleted_hbm := by
    intro l h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  h2dCompleted_dispatched := by
    intro l h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  completedLayers_count := by
    show 0 = countTrue (fun _ => false) cfg.numLayers
    rw [countTrue_const_false]
  completedBlocks_count := by
    show 0 = cfg.numBlocks * countTrue (fun _ => false) cfg.numLayers
    rw [countTrue_const_false]
    omega
  accounted_dispatched := by
    intro l h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  networkCompleted_dispatched := by
    intro h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  consumerDraining_h2dDone := by
    intro h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  consumerDone_h2dDone := by
    intro h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  doneRecving_h2dDone := by
    intro h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  consumed_doneRecving := by
    intro h
    have h' : (false : Bool) = true := h
    exact absurd h' (by decide)
  stagingFlag := rfl

/-- `Inv` is inductive: every `Step` preserves it. -/
theorem inv_step {s s' : SystemState} (ih : Inv s) (hstep : Step s s') : Inv s' := by
  cases hstep with
  | d2hDispatch l s hl hdrain hnd =>
    exact { ih with }
  | d2hComplete l s hl hdisp hnotdone hinflight =>
    have hmono : ∀ x, s.producer.d2hCompleted x = true →
        (if x = l then true else s.producer.d2hCompleted x) = true := fun _ h => updTrue h
    -- Source HBM cannot have been reclaimed yet: layer `l`'s D2H read is still open.
    have hfree : s.sourceBufferFreed = false := by
      cases hf : s.sourceBufferFreed with
      | false => rfl
      | true =>
        have hdone := ih.sourceFreed_d2hDone hf l hl
        rw [hdone] at hnotdone
        exact absurd hnotdone (by decide)
    exact { ih with
      h2hDispatched_d2hCompleted := fun x hx => hmono x (ih.h2hDispatched_d2hCompleted x hx)
      producerDraining_d2hDone := fun hd hok x hx =>
        hmono x (ih.producerDraining_d2hDone hd hok x hx)
      producerDone_d2hDone := by
        intro hdone hok x hx
        have hdone' :
            (s.producer.done || (s.producer.draining && (s.producer.inFlight - 1 == 0))) = true :=
          hdone
        refine hmono x ?_
        rcases (Bool.or_eq_true _ _).mp hdone' with h | h
        · exact ih.producerDone_d2hDone h hok x hx
        · exact ih.producerDraining_d2hDone ((Bool.and_eq_true _ _).mp h).1 hok x hx
      doneSending_d2hDone := fun hds x hx => hmono x (ih.doneSending_d2hDone hds x hx)
      sourceFreed_d2hDone := fun hsf x hx => hmono x (ih.sourceFreed_d2hDone hsf x hx)
      prefillStagingContent := by
        intro lyr bid c hc
        have hc' : (if lyr = l ∧ bid < s.config.numBlocks then s.mem.prefillHbm lyr bid
                    else s.mem.prefillStaging lyr bid) = some c := hc
        split at hc'
        · rename_i hcase
          have hlyr : lyr < s.config.numLayers := by rw [hcase.1]; exact hl
          have hhbm := ih.prefillHbmIntact hfree lyr hlyr bid hcase.2
          rw [hhbm] at hc'
          exact (Option.some.inj hc').symm
        · exact ih.prefillStagingContent lyr bid c hc'
    }
  | h2hDispatch l s hl hd2h hdrain hnd =>
    exact { ih with
      h2hDispatched_d2hCompleted := by
        intro x hx
        have hx' : (if x = l then true else s.producer.h2hDispatched x) = true := hx
        rcases updCases hx' with heq | hold
        · rw [heq]; exact hd2h
        · exact ih.h2hDispatched_d2hCompleted x hold
      h2hCompleted_h2hDispatched := fun x hx => updTrue (ih.h2hCompleted_h2hDispatched x hx)
    }
  | h2hComplete l s hl hdisp hnc hinflight hrem =>
    have hupd := countTrue_update hnc s.config.numLayers hl
    have hold := ih.remainingH2h_count
    -- Once `remaining_h2h_layers_` hits zero every layer has been pushed, hence read.
    have hdrainAll : (s.producer.draining || (s.producer.remainingH2h - 1 == 0)) = true →
        s.producer.statusOk = true →
        ∀ x, x < s.config.numLayers → s.producer.d2hCompleted x = true := by
      intro hd hok x hx
      rcases (Bool.or_eq_true _ _).mp hd with h | h
      · exact ih.producerDraining_d2hDone h hok x hx
      · have hz : s.producer.remainingH2h - 1 = 0 := by simpa using h
        have hcnt : countTrue (fun idx => if idx = l then true else s.producer.h2hCompleted idx)
            s.config.numLayers = s.config.numLayers := by
          rw [hupd]; omega
        have hallNew := countTrue_eq_all _ hcnt x hx
        rcases updCases hallNew with heq | hkeep
        · rw [heq]; exact ih.h2hDispatched_d2hCompleted l hdisp
        · exact ih.h2hDispatched_d2hCompleted x (ih.h2hCompleted_h2hDispatched x hkeep)
    exact { ih with
      h2hCompleted_h2hDispatched := by
        intro x hx
        have hx' : (if x = l then true else s.producer.h2hCompleted x) = true := hx
        rcases updCases hx' with heq | hkeep
        · rw [heq]; exact hdisp
        · exact ih.h2hCompleted_h2hDispatched x hkeep
      remainingH2h_count := by
        show s.producer.remainingH2h - 1
            + countTrue (fun idx => if idx = l then true else s.producer.h2hCompleted idx)
                s.config.numLayers = s.config.numLayers
        rw [hupd]
        omega
      producerDraining_d2hDone := hdrainAll
      producerDone_d2hDone := by
        intro hdone hok x hx
        have hdone' : (s.producer.done ||
            ((s.producer.draining || (s.producer.remainingH2h - 1 == 0)) &&
              (s.producer.inFlight - 1 == 0))) = true := hdone
        rcases (Bool.or_eq_true _ _).mp hdone' with h | h
        · exact ih.producerDone_d2hDone h hok x hx
        · exact hdrainAll ((Bool.and_eq_true _ _).mp h).1 hok x hx
      networkInFlightContent := by
        intro lyr bid c hc
        have hc' : (if lyr = l ∧ bid < s.config.numBlocks then s.mem.prefillStaging lyr bid
                    else s.mem.networkInFlight lyr bid) = some c := hc
        split at hc'
        · exact ih.prefillStagingContent lyr bid c hc'
        · exact ih.networkInFlightContent lyr bid c hc'
    }
  | producerTimeout s hdrain hdone =>
    exact { ih with
      producerDraining_d2hDone := by
        intro _ hok
        have hok' : (false : Bool) = true := hok
        exact absurd hok' (by decide)
      producerDone_d2hDone := by
        intro _ hok
        have hok' : (false : Bool) = true := hok
        exact absurd hok' (by decide)
    }
  | producerCompleteReadRaw s hdone hds hfs =>
    by_cases hok : s.producer.statusOk = true
    · have heq : stepProducerCompleteReadRaw s = { s with doneSending := true } := by
        simp [stepProducerCompleteReadRaw, hok]
      rw [heq]
      exact { ih with
        doneSending_d2hDone := fun _ x hx => ih.producerDone_d2hDone hdone hok x hx }
    · have hok' : s.producer.statusOk = false := by simpa using hok
      have heq : stepProducerCompleteReadRaw s = { s with failedSending := true } := by
        simp [stepProducerCompleteReadRaw, hok']
      rw [heq]
      exact { ih with }
  | networkLandChunk l b s hl hb hinflight hstaging =>
    exact { ih with
      networkInFlightContent := by
        intro lyr bid c hc
        have hc' : (if lyr = l ∧ bid = b then none else s.mem.networkInFlight lyr bid)
            = some c := hc
        split at hc'
        · exact absurd hc' (by simp)
        · exact ih.networkInFlightContent lyr bid c hc'
      decodeStagingContent := by
        intro lyr bid c hc
        have hc' : (if lyr = l ∧ bid = b then s.mem.networkInFlight l b
                    else s.mem.decodeStaging lyr bid) = some c := hc
        split at hc'
        · rename_i hcase
          have hnet := ih.networkInFlightContent l b c hc'
          rw [hcase.1, hcase.2]
          exact hnet
        · exact ih.decodeStagingContent lyr bid c hc'
      h2dDispatched_staging := by
        intro lyr hdisp bid hbid
        have hkeep := ih.h2dDispatched_staging lyr hdisp bid hbid
        show (if lyr = l ∧ bid = b then s.mem.networkInFlight l b
              else s.mem.decodeStaging lyr bid) ≠ none
        split
        · exact hinflight
        · exact hkeep
    }
  | networkAccountLayerBlocks l s hl hdisp hnotacc =>
    have hupd := countTrue_update hnotacc s.config.numLayers hl
    have hcount : s.consumer.completedBlocks + s.config.numBlocks
        = s.config.numBlocks *
            countTrue (fun idx => if idx = l then true else s.consumer.blocksAccounted idx)
              s.config.numLayers := by
      rw [hupd, ih.completedBlocks_count, Nat.mul_succ]
    exact { ih with
      completedBlocks_count := hcount
      accounted_dispatched := by
        intro x hx
        have hx' : (if x = l then true else s.consumer.blocksAccounted x) = true := hx
        rcases updCases hx' with heq | hkeep
        · rw [heq]; exact hdisp
        · exact ih.accounted_dispatched x hkeep
      networkCompleted_dispatched := by
        intro hnet x hx
        have hnet' : (s.consumer.networkCompleted ||
            decide (s.config.numLayers * s.config.numBlocks
              ≤ s.consumer.completedBlocks + s.config.numBlocks)) = true := hnet
        rcases (Bool.or_eq_true _ _).mp hnet' with h | h
        · exact ih.networkCompleted_dispatched h x hx
        · -- The threshold can only be met once every layer has been accounted,
          -- and every accounted layer was dispatched first.
          have hthr : s.config.numLayers * s.config.numBlocks
              ≤ s.consumer.completedBlocks + s.config.numBlocks := of_decide_eq_true h
          have hBpos : 0 < s.config.numBlocks := s.config.numBlocks_pos
          have hle := countTrue_le
            (fun idx => if idx = l then true else s.consumer.blocksAccounted idx)
            s.config.numLayers
          have h1 : s.config.numLayers * s.config.numBlocks
              ≤ s.config.numBlocks *
                countTrue (fun idx => if idx = l then true else s.consumer.blocksAccounted idx)
                  s.config.numLayers := by rw [← hcount]; exact hthr
          have h2 : s.config.numBlocks *
              countTrue (fun idx => if idx = l then true else s.consumer.blocksAccounted idx)
                s.config.numLayers
              ≤ s.config.numBlocks * s.config.numLayers :=
            Nat.mul_le_mul (Nat.le_refl _) hle
          have h3 : s.config.numBlocks * s.config.numLayers
              = s.config.numLayers * s.config.numBlocks := Nat.mul_comm _ _
          have heq : s.config.numBlocks *
              countTrue (fun idx => if idx = l then true else s.consumer.blocksAccounted idx)
                s.config.numLayers
              = s.config.numBlocks * s.config.numLayers := by omega
          have hfull := Nat.eq_of_mul_eq_mul_left hBpos heq
          have hallq := countTrue_eq_all _ hfull x hx
          rcases updCases hallq with hxl | hkeep
          · rw [hxl]; exact hdisp
          · exact ih.accounted_dispatched x hkeep
    }
  | h2dDispatch l s hl hdrain hdone hnd hstaging =>
    exact { ih with
      h2dDispatched_staging := by
        intro x hx bid hbid
        have hx' : (if x = l then true else s.consumer.h2dDispatched x) = true := hx
        rcases updCases hx' with heq | hkeep
        · rw [heq]; exact hstaging bid hbid
        · exact ih.h2dDispatched_staging x hkeep bid hbid
      h2dCompleted_dispatched := fun x hx => updTrue (ih.h2dCompleted_dispatched x hx)
      accounted_dispatched := fun x hx => updTrue (ih.accounted_dispatched x hx)
      networkCompleted_dispatched := fun hn x hx => updTrue (ih.networkCompleted_dispatched hn x hx)
    }
  | h2dComplete l s hl hdisp hnc hinflight =>
    have hcount : s.consumer.completedLayers + 1
        = countTrue (fun idx => if idx = l then true else s.consumer.h2dCompleted idx)
            s.config.numLayers := by
      rw [countTrue_update hnc s.config.numLayers hl, ih.completedLayers_count]
    have hfinish : s.consumer.completedLayers + 1 = s.config.numLayers →
        ∀ x, x < s.config.numLayers →
          (if x = l then true else s.consumer.h2dCompleted x) = true := by
      intro heq
      apply countTrue_eq_all
      rw [← hcount]
      exact heq
    have hdrainAll : (s.consumer.draining ||
          ((s.consumer.completedLayers + 1 == s.config.numLayers) && !s.consumer.draining)) = true →
        s.consumer.statusOk = true →
        ∀ x, x < s.config.numLayers →
          (if x = l then true else s.consumer.h2dCompleted x) = true := by
      intro hd hok x hx
      rcases (Bool.or_eq_true _ _).mp hd with h | h
      · exact updTrue (ih.consumerDraining_h2dDone h hok x hx)
      · have hfin : s.consumer.completedLayers + 1 = s.config.numLayers := by
          simpa using ((Bool.and_eq_true _ _).mp h).1
        exact hfinish hfin x hx
    exact { ih with
      h2dCompleted_dispatched := by
        intro x hx
        have hx' : (if x = l then true else s.consumer.h2dCompleted x) = true := hx
        rcases updCases hx' with heq | hkeep
        · rw [heq]; exact hdisp
        · exact ih.h2dCompleted_dispatched x hkeep
      completedLayers_count := hcount
      h2dCompleted_hbm := by
        intro x hx bid hbid
        have hx' : (if x = l then true else s.consumer.h2dCompleted x) = true := hx
        show (if x = l ∧ bid < s.config.numBlocks then s.mem.decodeStaging x bid
              else s.mem.decodeHbm x bid) = some (expectedBlockContent s.config x bid)
        split
        · rename_i hcase
          have hne : s.mem.decodeStaging x bid ≠ none := by
            rw [hcase.1]
            exact ih.h2dDispatched_staging l hdisp bid hbid
          cases hval : s.mem.decodeStaging x bid with
          | none => exact absurd hval hne
          | some c =>
            have hcontent := ih.decodeStagingContent x bid c hval
            rw [hcontent]
        · rename_i hcase
          have hxne : ¬ (x = l) := fun h => hcase ⟨h, hbid⟩
          have hkeep : s.consumer.h2dCompleted x = true := by
            rcases updCases hx' with heq | hkeep
            · exact absurd heq hxne
            · exact hkeep
          exact ih.h2dCompleted_hbm x hkeep bid hbid
      consumerDraining_h2dDone := hdrainAll
      consumerDone_h2dDone := by
        intro hdone hok x hx
        have hdone' : (s.consumer.done ||
            ((s.consumer.draining ||
              ((s.consumer.completedLayers + 1 == s.config.numLayers) && !s.consumer.draining)) &&
              (s.consumer.inFlight - 1 == 0))) = true := hdone
        rcases (Bool.or_eq_true _ _).mp hdone' with h | h
        · exact updTrue (ih.consumerDone_h2dDone h hok x hx)
        · exact hdrainAll ((Bool.and_eq_true _ _).mp h).1 hok x hx
      doneRecving_h2dDone := fun hdr x hx => updTrue (ih.doneRecving_h2dDone hdr x hx)
      stagingFlag := staging_update ih.stagingFlag
    }
  | consumerPollComplete s hdrain hdone hready =>
    have hall := ready_implies_all_h2dCompleted s ih.completedLayers_count
      ih.networkCompleted_dispatched hready
    have hstag : s.consumer.hasStaging = true := by
      have h := ih.stagingFlag
      rw [hdone] at h
      simpa using h
    exact { ih with
      consumerDraining_h2dDone := fun _ _ x hx => hall x hx
      consumerDone_h2dDone := fun _ _ x hx => hall x hx
      stagingFlag := staging_set hstag
    }
  | consumerTimeout s hdrain hdone =>
    have hstag : s.consumer.hasStaging = true := by
      have h := ih.stagingFlag
      rw [hdone] at h
      simpa using h
    exact { ih with
      consumerDraining_h2dDone := by
        intro _ hok
        have hok' : (false : Bool) = true := hok
        exact absurd hok' (by decide)
      consumerDone_h2dDone := by
        intro _ hok
        have hok' : (false : Bool) = true := hok
        exact absurd hok' (by decide)
      stagingFlag := staging_set hstag
    }
  | consumerCompleteReadRaw s hdone hdr hfr =>
    by_cases hok : s.consumer.statusOk = true
    · have heq : stepConsumerCompleteReadRaw s = { s with doneRecving := true } := by
        simp [stepConsumerCompleteReadRaw, hok]
      rw [heq]
      exact { ih with
        doneRecving_h2dDone := fun _ x hx => ih.consumerDone_h2dDone hdone hok x hx
        consumed_doneRecving := fun _ => rfl }
    · have hok' : s.consumer.statusOk = false := by simpa using hok
      have heq : stepConsumerCompleteReadRaw s = { s with failedRecving := true } := by
        simp [stepConsumerCompleteReadRaw, hok']
      rw [heq]
      exact { ih with }
  | prefillReclaimBuffer s hds hsf =>
    exact { ih with
      prefillHbmIntact := by
        intro hfree
        have hfree' : (true : Bool) = false := hfree
        exact absurd hfree' (by decide)
      sourceFreed_d2hDone := fun _ x hx => ih.doneSending_d2hDone hds x hx
    }
  | decodeConsumeAttention s hdr hcons =>
    exact { ih with consumed_doneRecving := fun _ => hdr }

/-- `Inv` holds at every state reachable from an initial state satisfying it. -/
theorem inv_reachable {init s : SystemState} (hinit : Inv init) (h : Reachable init s) : Inv s := by
  induction h with
  | refl => exact hinit
  | step _ hstep ihr => exact inv_step ihr hstep

/-- `Inv` holds at every state reachable from `initialState`. -/
theorem inv_of_reachable {cfg : TransferConfig} {mode : CheckMode} {s : SystemState}
    (h : Reachable (initialState cfg mode) s) : Inv s :=
  inv_reachable (inv_initialState cfg mode) h

end TpuSyncFormal.PrefillDecode
