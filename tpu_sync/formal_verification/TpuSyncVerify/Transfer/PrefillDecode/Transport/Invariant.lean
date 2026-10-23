import TpuSyncVerify.Transfer.PrefillDecode.Transport.Lemmas

/-! # `Transport`: inductive invariant (honest senders) and `reachable_safe`

Part of `TpuSyncVerify.Transfer.PrefillDecode.Transport`. -/

namespace TpuSyncVerify.Transfer.PrefillDecode.Transport

open TpuSyncVerify TpuSyncVerify.Transfer

/-! ## Inductive invariant (honest senders) -/

/-- Every sender has landed all its declared streams for this layer. -/
def fullB (c : Cfg) (sent : List Nat) : Bool := sent.all (fun n => decide (n = c.numStreams))

theorem fullB_iff (c : Cfg) (sent : List Nat) : fullB c sent = true ↔ ∀ n ∈ sent, n = c.numStreams := by
  simp [fullB, List.all_eq_true]

theorem fullB_false_of_lt {c : Cfg} {sent : List Nat} {i n : Nat}
    (h : sent[i]? = some n) (hn : n < c.numStreams) : fullB c sent = false := by
  cases hf : fullB c sent
  · rfl
  · have := (fullB_iff c sent).mp hf n (TpuSyncVerify.getElem?_mem h)
    omega

/-- How a live table entry relates to the ghost `sent`. -/
structure EntryInv (c : Cfg) (sent : List Nat) (p : Progress) : Prop where
  called : p.called = fullB c sent
  chunk : c.declared = false → p.completedChunks = natSum sent
  decl : c.declared = true → p.landed = sent ∧ p.sendersComplete = countEq c.numStreams sent

structure LInv (c : Cfg) (L : Layer) : Prop where
  sentLen : L.sent.length = c.numSenders
  sentLe : ∀ n ∈ L.sent, n ≤ c.numStreams
  entry : ∀ p, L.entry = some p → EntryInv c L.sent p
  noEntry : L.entry = none → natSum L.sent = 0 ∨ fullB c L.sent = true
  disp : L.dispatched = if fullB c L.sent then 1 else 0
  pend : L.pending ≤ L.dispatched

structure Inv (c : Cfg) (s : S) : Prop where
  len : s.layers.length = c.numLayers
  layers : ∀ L ∈ s.layers, LInv c L
  blocks : s.blocks = c.blocksPerStream * natSum (s.layers.map fun L => natSum L.sent)
  life : s.life.Consistent
  /-- An error is only ever recorded by a `FinishLocked`, which also drains. -/
  failed : s.life.statusOk = false → s.life.draining = true
  inFlight : s.life.inFlight = natSum (s.layers.map Layer.pending)
  /-- While no copy has failed, every dispatched copy is pending or completed. -/
  completed : s.life.statusOk = true →
    s.completedLayers + s.life.inFlight = natSum (s.layers.map Layer.dispatched)
  /-- A receive that started draining with an OK status did so because every
  layer's single copy had completed. -/
  fin : s.life.draining = true → s.life.statusOk = true →
    ∀ L ∈ s.layers, L.dispatched = 1 ∧ L.pending = 0

theorem LInv.disp_le_one {c : Cfg} {L : Layer} (h : LInv c L) : L.dispatched ≤ 1 := by
  rw [h.disp]; split <;> omega

theorem LInv.natSum_sent_le {c : Cfg} {L : Layer} (h : LInv c L) :
    natSum L.sent ≤ c.numSenders * c.numStreams :=
  h.sentLen ▸ natSum_le_length_mul h.sentLe

theorem fullB_fresh_false {c : Cfg} (hwf : c.WF) : fullB c (List.replicate c.numSenders 0) = false := by
  cases hs : c.numSenders with
  | zero => exact absurd hs (Nat.ne_of_gt hwf.senders)
  | succ k =>
    apply fullB_false_of_lt (i := 0) (n := 0)
    · simp [List.replicate_succ]
    · exact hwf.streams

theorem inv_init (c : Cfg) (hwf : c.WF) : Inv c (init c) := by
  have hfresh : natSum (freshLayer c).sent = 0 := by simp [freshLayer, natSum_replicate_zero]
  refine ⟨by simp [init], ?_, ?_, Lifecycle.consistent_init, by simp [init], ?_, ?_, by simp [init]⟩
  · intro L hL
    rw [List.eq_of_mem_replicate hL]
    refine ⟨by simp [freshLayer], ?_, by simp [freshLayer], ?_, ?_, by simp [freshLayer]⟩
    · intro n hn; simp [freshLayer] at hn; omega
    · intro _; left; exact hfresh
    · simp [freshLayer, fullB_fresh_false hwf]
  · simp [init, hfresh, natSum_replicate_zero]
  · simp [init, freshLayer, natSum_replicate_zero]
  · intro _; simp [init, freshLayer, natSum_replicate_zero]

/-! ### Helper lemmas on the ghost lists -/

theorem countEq_replicate_zero {k : Nat} (hk : 0 < k) : ∀ n, countEq k (List.replicate n 0) = 0
  | 0 => rfl
  | n + 1 => by
    simp only [List.replicate_succ, countEq, countEq_replicate_zero hk n]
    have : k ≠ 0 := Nat.ne_of_gt hk
    simp [Ne.symm this]

theorem retire_length (ls : List Layer) : (retire ls).length = ls.length := by
  unfold retire; split <;> simp

theorem retire_map_sent (ls : List Layer) :
    (retire ls).map (fun L => natSum L.sent) = ls.map (fun L => natSum L.sent) := by
  unfold retire; split <;> simp [List.map_map, Function.comp_def]

theorem retire_map_pending (ls : List Layer) :
    (retire ls).map Layer.pending = ls.map Layer.pending := by
  unfold retire; split <;> simp [List.map_map, Function.comp_def]

theorem retire_map_dispatched (ls : List Layer) :
    (retire ls).map Layer.dispatched = ls.map Layer.dispatched := by
  unfold retire; split <;> simp [List.map_map, Function.comp_def]

theorem mem_retire {ls : List Layer} {M : Layer} (h : M ∈ retire ls) :
    M ∈ ls ∨ ∃ M₀ ∈ ls, M₀.entryCalled = true ∧ M = { M₀ with entry := none } := by
  unfold retire at h
  split at h
  · rename_i hall
    rw [List.all_eq_true] at hall
    obtain ⟨M₀, hM₀, rfl⟩ := List.mem_map.mp h
    exact Or.inr ⟨M₀, hM₀, hall M₀ hM₀, rfl⟩
  · exact Or.inl h

theorem LInv.clear {c : Cfg} {L : Layer} (h : LInv c L) (hc : L.entryCalled = true) :
    LInv c { L with entry := none } := by
  refine ⟨h.sentLen, h.sentLe, by simp, ?_, h.disp, h.pend⟩
  intro _
  right
  unfold Layer.entryCalled at hc
  split at hc
  · rename_i p hp
    exact (h.entry p hp).called ▸ hc
  · cases hc

theorem getElem?_of_lt_length {l : List Nat} {i : Nat} (hi : i < l.length) :
    ∃ a, l[i]? = some a :=
  ⟨l[i], List.getElem?_eq_getElem hi⟩

/-- A layer with no table entry and a stream still to come is untouched, and
the fresh entry `CompleteIncomingPush` creates for it agrees with the ghost. -/
theorem LInv.entryInv_getD {c : Cfg} (hwf : c.WF) {L : Layer} (h : LInv c L) {i a : Nat}
    (hi : L.sent[i]? = some a) (ha : a < c.numStreams) :
    EntryInv c L.sent (L.entry.getD (freshProgress c)) := by
  cases hE : L.entry with
  | some p => exact h.entry p hE
  | none =>
    have hnf := fullB_false_of_lt hi ha
    rcases h.noEntry hE with hz | hf
    · have hsent : L.sent = List.replicate c.numSenders 0 :=
        List.eq_replicate_iff.mpr ⟨h.sentLen, eq_zero_of_natSum_eq_zero hz⟩
      refine ⟨by simp [freshProgress, hnf], fun _ => by simp [freshProgress, hz], fun _ => ?_⟩
      refine ⟨by simp [freshProgress, hsent], ?_⟩
      simp only [freshProgress, hsent]
      exact (countEq_replicate_zero hwf.streams _).symm
    · rw [hf] at hnf; cases hnf

/-- `CompleteIncomingPush` on an honest stream: never rejects, fires exactly
when this stream completes the sender set, and keeps the entry in agreement
with the ghost. -/
theorem completePush_honest {c : Cfg} (hwf : c.WF) {sent : List Nat} {p : Progress} {i a : Nat}
    (hE : EntryInv c sent p) (hlen : sent.length = c.numSenders)
    (hi : sent[i]? = some a) (ha : a < c.numStreams) :
    ∃ p', completePush c p i = (p', fullB c (sent.set i (a + 1)), false) ∧
      EntryInv c (sent.set i (a + 1)) p' := by
  have hcalled : p.called = false := hE.called ▸ fullB_false_of_lt hi ha
  have hne : a ≠ c.numStreams := Nat.ne_of_lt ha
  cases hd : c.declared with
  | false =>
    have h1 : c.numSenders = 1 := hwf.chunkSingle hd
    have hsent : sent = [a] := by
      match sent, hlen, hi with
      | [], hlen, _ => simp at hlen; omega
      | [x], _, hi =>
        cases i with
        | zero => simp at hi; subst hi; rfl
        | succ j => simp at hi
      | _ :: _ :: _, hlen, _ => simp at hlen; omega
    subst hsent
    have hi0 : i = 0 := by
      cases i with
      | zero => rfl
      | succ j => simp at hi
    subst hi0
    have hcc := hE.chunk hd
    simp only [natSum, Nat.add_zero] at hcc
    refine ⟨(completePush c p 0).1, Prod.ext rfl (Prod.ext ?_ ?_), ?_⟩
    · simp [completePush, hd, hcc, hcalled, fullB]
    · simp [completePush, hd]
    · refine ⟨?_, fun _ => ?_, (fun h' => by rw [hd] at h'; cases h')⟩
      · simp [completePush, hd, hcc, hcalled, fullB]
      · simp [completePush, hd, hcc, natSum]
  | true =>
    obtain ⟨hlanded, hsc⟩ := hE.decl hd
    have hgetD : p.landed.getD i 0 = a := hlanded ▸ getD_eq_of_getElem? hi
    have hgetD' : p.landed[i]? = some a := hlanded ▸ hi
    have hrej : decide (c.numStreams < a + 1) = false := by simp; omega
    have hcount := countEq_set (x := a + 1) (k := c.numStreams) hi hne
    have hfull : fullB c (sent.set i (a + 1)) =
        decide ((if a + 1 = c.numStreams then p.sendersComplete + 1 else p.sendersComplete) =
          c.numSenders) := by
      rw [Bool.eq_iff_iff, decide_eq_true_iff, fullB_iff, ← countEq_eq_length_iff,
        List.length_set, hlen, hcount, hsc]
      by_cases hc : a + 1 = c.numStreams <;> simp [hc]
    refine ⟨(completePush c p i).1, Prod.ext rfl (Prod.ext ?_ ?_), ?_⟩
    · simp only [completePush, hd, ↓reduceIte, hgetD, hrej, hcalled, hfull]; simp
    · simp [completePush, hd, hgetD']; omega
    · refine ⟨?_, (fun h' => by rw [hd] at h'; cases h'), fun _ => ⟨?_, ?_⟩⟩
      · simp only [completePush, hd, ↓reduceIte, hgetD, hrej, hcalled, hfull]; simp
      · simp [completePush, hd, hlanded, hi]
      · simp only [completePush, hd, ↓reduceIte, hgetD, hcount, hsc]; split <;> simp

/-! ### Lifecycle facts used below -/

theorem settle_inFlight (l : Lifecycle) : (l.settleLocked).inFlight = l.inFlight := by
  unfold Lifecycle.settleLocked; split <;> rfl
theorem settle_draining (l : Lifecycle) : (l.settleLocked).draining = l.draining := by
  unfold Lifecycle.settleLocked; split <;> rfl
theorem settle_statusOk (l : Lifecycle) : (l.settleLocked).statusOk = l.statusOk := by
  unfold Lifecycle.settleLocked; split <;> rfl

theorem fl_inFlight (ok : Bool) (l : Lifecycle) : (l.finishLocked ok).inFlight = l.inFlight := by
  unfold Lifecycle.finishLocked
  cases ok <;> cases hs : l.statusOk <;> cases hd : l.draining <;> simp [hs, hd]
theorem fl_draining (ok : Bool) (l : Lifecycle) : (l.finishLocked ok).draining = true := by
  unfold Lifecycle.finishLocked
  cases ok <;> cases hs : l.statusOk <;> cases hd : l.draining <;> simp [hs, hd]
theorem fl_false_statusOk (l : Lifecycle) : (l.finishLocked false).statusOk = false := by
  unfold Lifecycle.finishLocked
  cases hs : l.statusOk <;> cases hd : l.draining <;> simp [hs, hd]
theorem fl_true_statusOk (l : Lifecycle) : (l.finishLocked true).statusOk = l.statusOk := by
  unfold Lifecycle.finishLocked
  cases hs : l.statusOk <;> cases hd : l.draining <;> simp [hs, hd]

theorem eo_inFlight (l : Lifecycle) : (l.endOpLocked).inFlight = l.inFlight - 1 := by
  unfold Lifecycle.endOpLocked; split <;> simp_all
theorem eo_draining (l : Lifecycle) : (l.endOpLocked).draining = l.draining := by
  unfold Lifecycle.endOpLocked; split <;> simp
theorem eo_statusOk (l : Lifecycle) : (l.endOpLocked).statusOk = l.statusOk := by
  unfold Lifecycle.endOpLocked; split <;> simp

theorem beginOp_some {l l' : Lifecycle} (h : l.beginOp = some l') :
    l.draining = false ∧ l' = { l with inFlight := l.inFlight + 1 } := by
  unfold Lifecycle.beginOp at h
  split at h
  · cases h
  · rename_i hn
    cases h
    simp only [not_or, Bool.not_eq_true] at hn
    exact ⟨hn.2, rfl⟩

/-- A non-draining session that takes and returns the push lease, taking the
copy's op in between when the stream fired. -/
theorem streamLife_accept {l : Lifecycle} (hd : l.draining = false) (fire : Bool) :
    streamLife { l with inFlight := l.inFlight + 1 } fire false =
      { l with inFlight := if fire then l.inFlight + 1 else l.inFlight } := by
  unfold streamLife Lifecycle.endOpLocked Lifecycle.settleLocked
  cases fire <;> simp [hd]

/-! ### Preservation -/

theorem stream_inv {c : Cfg} (hwf : c.WF) (hh : c.honest = true) {s s' : S} {l i : Nat}
    (h : Inv c s) (hs : streamStep c s l i = some s') : Inv c s' := by
  unfold streamStep at hs
  split at hs
  · rename_i life₁ L hb hL
    obtain ⟨hdr, hlife₁⟩ := beginOp_some hb
    subst hlife₁
    split at hs
    · cases hs
    rename_i hsender
    split at hs
    · cases hs
    rename_i hguard
    have hLinv := h.layers L (getElem?_mem hL)
    have hi' : i < L.sent.length := by rw [hLinv.sentLen]; omega
    obtain ⟨a, hi⟩ := getElem?_of_lt_length hi'
    have hgetD : L.sent.getD i 0 = a := getD_eq_of_getElem? hi
    have ha : a < c.numStreams := by
      simp only [hh, Bool.true_and, hgetD] at hguard
      simpa using hguard
    obtain ⟨p', hcp, hE'⟩ :=
      completePush_honest hwf (hLinv.entryInv_getD hwf hi ha) hLinv.sentLen hi ha
    split at hs
    rename_i p'' fire reject hcp'
    rw [hcp] at hcp'
    cases hcp'
    simp only [hgetD, Bool.false_eq_true, ↓reduceIte, Option.some.injEq] at hs
    subst hs
    have hsent' : natSum (L.sent.set i (a + 1)) = natSum L.sent + 1 := by
      have := natSum_set (x := a + 1) hi; omega
    have hdisp0 : L.dispatched = 0 := by rw [hLinv.disp, fullB_false_of_lt hi ha]; rfl
    have hpend0 : L.pending = 0 := by have := hLinv.pend; omega
    have hnd : s.life.done = false := h.life.not_done hdr
    have hin := h.inFlight
    rw [streamLife_accept hdr]
    cases hfire : fullB c (L.sent.set i (a + 1))
    all_goals
      have hL₂ : LInv c (nextLayer L p' (L.sent.set i (a + 1)) (fullB c (L.sent.set i (a + 1)))) := by
        refine ⟨by simp [hLinv.sentLen], ?_, ?_, by simp, ?_, ?_⟩
        · intro n hn
          rcases mem_set_cases hn with rfl | hn
          · omega
          · exact hLinv.sentLe n hn
        · intro q hq
          have : p' = q := by simpa using hq
          subst this; exact hE'
        · simp [hdisp0, hfire]
        · simp only [nextLayer_dispatched, nextLayer_pending, hdisp0, hpend0, hfire]; omega
      rw [hfire] at hL₂
      have keyp := natSum_map_set Layer.pending (i := l) hL
        (x := nextLayer L p' (L.sent.set i (a + 1)) (fullB c (L.sent.set i (a + 1))))
      have keyd := natSum_map_set Layer.dispatched (i := l) hL
        (x := nextLayer L p' (L.sent.set i (a + 1)) (fullB c (L.sent.set i (a + 1))))
      have keys := natSum_map_set (fun L : Layer => natSum L.sent) (i := l) hL
        (x := nextLayer L p' (L.sent.set i (a + 1)) (fullB c (L.sent.set i (a + 1))))
      simp only [nextLayer_pending, nextLayer_dispatched, nextLayer_sent, hpend0, hdisp0, hsent',
        hfire, Bool.false_eq_true, ↓reduceIte] at keyp keyd keys
      refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
      · simp [retire_length, h.len]
      · intro M hM
        rcases mem_retire hM with hM | ⟨M₀, hM₀, hc, rfl⟩
        · rcases mem_set_cases hM with rfl | hM
          · exact hL₂
          · exact h.layers M hM
        · rcases mem_set_cases hM₀ with rfl | hM₀
          · exact hL₂.clear hc
          · exact (h.layers M₀ hM₀).clear hc
      · simp only [retire_map_sent]
        rw [h.blocks, Nat.mul_comm, Nat.mul_comm c.blocksPerStream, ← Nat.succ_mul]
        congr 1
        omega
      · exact ⟨fun hd => by simp [hnd] at hd, fun hd => by simp [hnd] at hd,
               fun hd => by simp [hdr] at hd, by simp [h.life.staging]⟩
      · intro hf; simp only at hf; have := h.failed hf; simp [hdr] at this
      · simp only [retire_map_pending, Bool.false_eq_true, ↓reduceIte]
        omega
      · intro hok
        simp only at hok
        simp only [retire_map_dispatched, Bool.false_eq_true, ↓reduceIte]
        have hc := h.completed hok
        omega
      · intro hd; simp [hdr] at hd
  · cases hs

/-- All layers are dispatched once the dispatch count reaches the layer count. -/
theorem all_dispatched_of_sum {c : Cfg} {ls : List Layer} (hlen : ls.length = c.numLayers)
    (hinv : ∀ L ∈ ls, LInv c L) (hsum : c.numLayers ≤ natSum (ls.map Layer.dispatched)) :
    ∀ L ∈ ls, L.dispatched = 1 := by
  intro L hL
  have hle : ∀ n ∈ ls.map Layer.dispatched, n ≤ 1 := by
    intro n hn
    obtain ⟨M, hM, rfl⟩ := List.mem_map.mp hn
    exact (hinv M hM).disp_le_one
  have := all_eq_of_natSum_ge hle (by simpa [hlen] using hsum)
  exact this _ (List.mem_map.mpr ⟨L, hL, rfl⟩)

theorem natSum_dispatched_le {c : Cfg} {ls : List Layer} (hlen : ls.length = c.numLayers)
    (hinv : ∀ L ∈ ls, LInv c L) : natSum (ls.map Layer.dispatched) ≤ c.numLayers := by
  have := natSum_le_length_mul (l := ls.map Layer.dispatched) (k := 1) (fun n hn => by
    obtain ⟨M, hM, rfl⟩ := List.mem_map.mp hn
    exact (hinv M hM).disp_le_one)
  simpa [hlen] using this

theorem all_pending_zero {ls : List Layer} (hz : natSum (ls.map Layer.pending) = 0) :
    ∀ L ∈ ls, L.pending = 0 :=
  fun L hL => eq_zero_of_natSum_eq_zero hz _ (List.mem_map.mpr ⟨L, hL, rfl⟩)

/-- Every layer is full once the block count reaches its target. -/
theorem all_full_of_blocks {c : Cfg} (hwf : c.WF) {s : S} (h : Inv c s)
    (hb : c.target ≤ s.blocks) : ∀ L ∈ s.layers, fullB c L.sent = true := by
  intro L hL
  rw [h.blocks] at hb
  have hle : ∀ n ∈ s.layers.map (fun L => natSum L.sent), n ≤ c.numSenders * c.numStreams := by
    intro n hn
    obtain ⟨M, hM, rfl⟩ := List.mem_map.mp hn
    exact (h.layers M hM).natSum_sent_le
  have hsum : (s.layers.map fun L => natSum L.sent).length * (c.numSenders * c.numStreams) ≤
      natSum (s.layers.map fun L => natSum L.sent) := by
    have hlen : (s.layers.map fun L => natSum L.sent).length = c.numLayers := by simp [h.len]
    rw [hlen]
    unfold Cfg.target Cfg.perLayer at hb
    have hb' : c.numLayers * (c.numSenders * c.numStreams) * c.blocksPerStream ≤
        natSum (s.layers.map fun L => natSum L.sent) * c.blocksPerStream := by
      calc c.numLayers * (c.numSenders * c.numStreams) * c.blocksPerStream
          = c.numSenders * c.numStreams * c.blocksPerStream * c.numLayers := by
            rw [Nat.mul_comm c.numLayers, Nat.mul_right_comm]
        _ ≤ c.blocksPerStream * natSum (s.layers.map fun L => natSum L.sent) := hb
        _ = _ := Nat.mul_comm _ _
    exact Nat.le_of_mul_le_mul_right hb' hwf.blocks
  have hfullL := all_eq_of_natSum_ge hle hsum _ (List.mem_map.mpr ⟨L, hL, rfl⟩)
  have hLinv := h.layers L hL
  rw [fullB_iff]
  exact all_eq_of_natSum_ge hLinv.sentLe (by rw [hLinv.sentLen]; omega)

theorem LInv.copyDone {c : Cfg} {L : Layer} (h : LInv c L) : LInv c L.copyDone :=
  ⟨h.sentLen, h.sentLe, h.entry, h.noEntry, h.disp, by simp; have := h.pend; omega⟩

/-- The lifecycle after the callback, field by field. -/
theorem callbackLife_fields (c : Cfg) (l : Lifecycle) (ok : Bool) (n : Nat) :
    (callbackLife c l ok n).inFlight = l.inFlight - 1 ∧
    (callbackLife c l ok n).statusOk = (if ok then l.statusOk else false) ∧
    (callbackLife c l ok n).draining =
      (if ok then (if n = c.numLayers ∧ l.draining = false then true else l.draining) else true) := by
  unfold callbackLife
  cases ok
  · simp only [Bool.false_eq_true, ↓reduceIte, eo_inFlight, eo_statusOk, eo_draining, fl_inFlight,
      fl_false_statusOk, fl_draining, and_self]
  · simp only [↓reduceIte]
    by_cases hc : n = c.numLayers ∧ l.draining = false
    · simp only [hc, ↓reduceIte, eo_inFlight, eo_statusOk, eo_draining, fl_inFlight,
        fl_true_statusOk, fl_draining, and_self]
    · simp only [hc, ↓reduceIte, eo_inFlight, eo_statusOk, eo_draining, and_self]

theorem h2dDone_inv {c : Cfg} {s s' : S} {l : Nat} {ok : Bool} (h : Inv c s)
    (hs : h2dDoneStep c s l ok = some s') : Inv c s' := by
  unfold h2dDoneStep at hs
  split at hs
  · cases hs
  rename_i L hL
  split at hs
  · cases hs
  rename_i hpend
  cases hs
  have hLinv := h.layers L (getElem?_mem hL)
  have keyp := natSum_map_set Layer.pending (i := l) hL (x := L.copyDone)
  have keyd := natSum_map_set Layer.dispatched (i := l) hL (x := L.copyDone)
  have keys := natSum_map_set (fun L : Layer => natSum L.sent) (i := l) hL (x := L.copyDone)
  simp only [Layer.copyDone_pending, Layer.copyDone_dispatched, Layer.copyDone_sent] at keyp keyd keys
  have hmem : ∀ M ∈ s.layers.set l L.copyDone, LInv c M := by
    intro M hM
    rcases mem_set_cases hM with rfl | hM
    · exact hLinv.copyDone
    · exact h.layers M hM
  have hlen : (s.layers.set l L.copyDone).length = c.numLayers := by simp [h.len]
  have hin := h.inFlight
  have hinF : 0 < s.life.inFlight := by
    rw [hin]
    have := le_natSum_of_mem (List.mem_map.mpr ⟨L, getElem?_mem hL, rfl⟩ :
      L.pending ∈ s.layers.map Layer.pending)
    omega
  have hblocks : s.blocks = c.blocksPerStream *
      natSum ((s.layers.set l L.copyDone).map fun L => natSum L.sent) := by
    rw [h.blocks]; congr 1; omega
  have hdisp_le := natSum_dispatched_le h.len h.layers
  obtain ⟨hf_in, hf_ok, hf_dr⟩ :=
    callbackLife_fields c s.life ok (if ok then s.completedLayers + 1 else s.completedLayers)
  have hcons : (callbackLife c s.life ok
      (if ok then s.completedLayers + 1 else s.completedLayers)).Consistent := by
    unfold callbackLife
    cases ok
    · simp only [Bool.false_eq_true, ↓reduceIte]
      exact Lifecycle.endOpLocked_consistent (Lifecycle.finishLocked_consistent false h.life)
    · simp only [↓reduceIte]
      split
      · exact Lifecycle.endOpLocked_consistent (Lifecycle.finishLocked_consistent true h.life)
      · exact Lifecycle.endOpLocked_consistent h.life
  refine ⟨hlen, hmem, hblocks, hcons, ?_, ?_, ?_, ?_⟩
  · intro hf
    rw [hf_ok] at hf
    rw [hf_dr]
    cases ok
    · rfl
    · simp only [↓reduceIte] at hf ⊢
      split
      · rfl
      · exact h.failed hf
  · show (callbackLife c s.life ok _).inFlight = natSum ((s.layers.set l L.copyDone).map Layer.pending)
    rw [hf_in]; omega
  · intro hok
    rw [hf_ok] at hok
    simp only [hf_in]
    cases ok
    · cases hok
    · simp only [↓reduceIte] at hok ⊢
      have := h.completed hok
      omega
  · intro hdr hok M hM
    rw [hf_ok] at hok
    rw [hf_dr] at hdr
    cases ok
    · cases hok
    · simp only [↓reduceIte] at hok hdr
      have hc := h.completed hok
      split at hdr
      · rename_i hcomp
        -- the success finish: every copy had completed, this was the last op
        have hsum : c.numLayers ≤ natSum ((s.layers.set l L.copyDone).map Layer.dispatched) := by
          omega
        have hall := all_dispatched_of_sum hlen hmem hsum
        have hz : natSum ((s.layers.set l L.copyDone).map Layer.pending) = 0 := by omega
        exact ⟨hall M hM, all_pending_zero hz M hM⟩
      · -- already draining with OK status: the invariant said all copies done,
        -- which contradicts a pending copy on `L`
        rename_i hncomp
        have := h.fin hdr hok L (getElem?_mem hL)
        omega

theorem publish_inv {c : Cfg} (hwf : c.WF) {s s' : S} (h : Inv c s)
    (hs : publishStep c s = some s') : Inv c s' := by
  unfold publishStep at hs
  split at hs
  · cases hs
  rename_i hdr
  simp only [Bool.not_eq_true] at hdr
  split at hs
  · rename_i hcond
    cases hs
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, List.all_eq_true] at hcond
    obtain ⟨hready, hpz⟩ := hcond
    have hz : s.life.inFlight = 0 := by
      rw [h.inFlight]
      have : ∀ n ∈ s.layers.map Layer.pending, n ≤ 0 := by
        intro n hn
        obtain ⟨M, hM, rfl⟩ := List.mem_map.mp hn
        exact Nat.le_of_eq (hpz M hM)
      have := natSum_le_length_mul this
      simpa using this
    have hok : s.life.statusOk = true := by
      cases hok : s.life.statusOk
      · have := h.failed hok; simp [hdr] at this
      · rfl
    have hall : ∀ M ∈ s.layers, M.dispatched = 1 := by
      intro M hM
      rcases hready with hnet | hcomp
      · have hfull := all_full_of_blocks hwf h (by simpa [networkCompleted] using hnet) M hM
        rw [(h.layers M hM).disp, hfull]; rfl
      · exact all_dispatched_of_sum h.len h.layers (by have := h.completed hok; omega) M hM
    refine ⟨h.len, h.layers, h.blocks, Lifecycle.finishLocked_consistent true h.life, ?_, ?_, ?_, ?_⟩
    · intro hf; rw [fl_true_statusOk] at hf; simp [hok] at hf
    · rw [fl_inFlight]; exact h.inFlight
    · intro _; rw [fl_inFlight]; exact h.completed hok
    · intro _ _ M hM
      exact ⟨hall M hM, hpz M hM⟩
  · cases hs

theorem cancel_inv {c : Cfg} {s s' : S} (h : Inv c s) (hs : cancelStep s = some s') : Inv c s' := by
  unfold cancelStep at hs
  split at hs
  · cases hs
  cases hs
  refine ⟨h.len, h.layers, h.blocks, Lifecycle.finishLocked_consistent false h.life, ?_, ?_, ?_, ?_⟩
  · intro _; exact fl_draining false s.life
  · rw [fl_inFlight]; exact h.inFlight
  · intro hok; rw [fl_false_statusOk] at hok; cases hok
  · intro _ hok; rw [fl_false_statusOk] at hok; cases hok

theorem step_inv {c : Cfg} (hwf : c.WF) (hh : c.honest = true) {s s' : S} {e : Ev}
    (h : Inv c s) (hs : step c s e = some s') : Inv c s' := by
  cases e with
  | stream l i => exact stream_inv hwf hh h hs
  | h2dDone l ok => exact h2dDone_inv h hs
  | publish => exact publish_inv hwf h hs
  | cancel => exact cancel_inv h hs

theorem inv_safe {c : Cfg} (hwf : c.WF) {s : S} (h : Inv c s) : Safe c s := by
  refine ⟨fun L hL => (h.layers L hL).disp_le_one, ?_, ?_⟩
  · intro hnet L hL
    have hfull := all_full_of_blocks hwf h (by simpa [networkCompleted] using hnet) L hL
    rw [(h.layers L hL).disp, hfull]
    exact Nat.le_refl _
  · intro hp
    simp only [published, Bool.and_eq_true] at hp
    exact h.fin (h.life.done_draining hp.1) hp.2

/-- **Main theorem.** With honest senders (A4), on either completion contract
and for any well-formed instance, every reachable state dispatches each layer
at most once, reaches its block target only after every layer was dispatched,
and reports success only after every layer's single copy has completed. -/
theorem reachable_safe {c : Cfg} (hwf : c.WF) (hh : c.honest = true) {s : S}
    (hr : (sys c).Reachable s) : Safe c s :=
  inv_safe hwf ((sys c).reachable_induction (inv_init c hwf) (fun _ _ _ h hs => step_inv hwf hh h hs) hr)


end TpuSyncVerify.Transfer.PrefillDecode.Transport
