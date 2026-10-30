import Std.Tactic.BVDecide
import TpuSyncVerify.Transfer.Reshard.Coordinator.Lemmas
import TpuSyncVerify.Transfer.Reshard.SubPlanChain.Model

/-! # `SubPlanChain`: safety predicates, inductive invariants, `reachable_safe`

Part of `TpuSyncVerify.Transfer.Reshard.SubPlanChain`; the module docstring and
source map live in `SubPlanChain.lean`. -/

namespace TpuSyncVerify.Transfer.Reshard.SubPlanChain

open TpuSyncVerify
open TpuSyncVerify.Transfer.Reshard.Registry
open TpuSyncVerify.Transfer.Reshard.Coordinator
  (CoordPhase abandonIfClaimed abandonIfClaimed_inv abandonIfClaimed_clears_single_owner
   register_preserves_idle_reg lookupAndClaim_from_idle_shape)

/-! ## Part I — `SubPlanUuid` and `PlanSubTransfers` -/

/-- `SubPlanUuid(uuid, 0)` is the identity (`coord.cc`). -/
theorem subPlanUuid_zero (uuid : UInt64) : subPlanUuid uuid 0 = uuid :=
  rfl

private theorem uint64_and_mask_le (x : UInt64) :
    (x &&& (0x7FFFFFFFFFFFFFFF : UInt64)) ≤ (0x7FFFFFFFFFFFFFFF : UInt64) := by
  change (x.toBitVec &&& (0x7FFFFFFFFFFFFFFF : BitVec 64)) ≤ (0x7FFFFFFFFFFFFFFF : BitVec 64)
  bv_decide

/-- For every `index > 0`, `SubPlanUuid(uuid, index)` is strictly positive and
fits in a signed 64-bit positive integer (`[1, 0x7FFFFFFFFFFFFFFF]`). -/
theorem subPlanUuid_pos_of_pos (uuid : UInt64) {index : Nat} (h : 0 < index) :
    (0 : UInt64) < subPlanUuid uuid index ∧
    subPlanUuid uuid index ≤ (0x7FFFFFFFFFFFFFFF : UInt64) := by
  unfold subPlanUuid
  have hne : (index == 0) = false := beq_false_of_ne (Nat.ne_of_gt h)
  simp only [hne, Bool.false_eq_true, ↓reduceIte]
  split
  · rename_i hpos
    exact ⟨hpos, uint64_and_mask_le _⟩
  · decide

/-- **Aliased-page windowing guard (`planSubTransfers_no_aliased_window_split`,
`PlanSubTransfers` in `reshard_coordinator.cc`)**:
Whenever `planSubTransfers` produces a multi-window chain (`chain.count > 1`),
`hasWindowedTagSharingIds` is `false` (no windowed tag shares any destination
block ID with another tag, preserving intra-plan `RankWaveOrder` on aliased
device pages) and `chain.subPlans.length = chain.count`. -/
theorem planSubTransfers_no_aliased_window_split {args : PlanArgs} {chain : SubTransferChain}
    (hplan : planSubTransfers args = some chain) (hgt : 1 < chain.count) :
    chain.subPlans.length = chain.count ∧
    ∃ counts,
      let windows := args.dstWindowBlocks.map Int.toNat
      let winPerTag := (List.range args.numTags).map fun i =>
        windowsForTag (counts.getD i 0) (windows.getD i 0)
      hasWindowedTagSharingIds (idsByTag args.dstDeviceBlockIds counts) winPerTag = false := by
  unfold planSubTransfers at hplan
  split at hplan
  · cases hplan
  split at hplan
  · injection hplan with h; subst h; simp at hgt
  split at hplan
  · cases hplan
  cases hcnt :
      (if args.dstBlockCounts.isEmpty then
        if args.numTags != 1 then none else some [args.dstDeviceBlockIds.length]
      else if args.dstBlockCounts.length != args.numTags then none
      else some args.dstBlockCounts) with
  | none =>
    simp only [hcnt] at hplan
    injection hplan with h; subst h; simp at hgt
  | some counts =>
    simp only [hcnt] at hplan
    split at hplan
    · injection hplan with h; subst h; simp at hgt
    split at hplan
    · injection hplan with h; subst h; simp at hgt
    rename_i hno_share
    split at hplan
    · injection hplan with h; subst h; simp at hgt
    injection hplan with h
    subst h
    refine ⟨by simp, counts, ?_⟩
    simpa using hno_share

/-! ## Part II — Worker chain folding -/

theorem mem_insertNodup {x y : Nat} {xs : List Nat} :
    x ∈ insertNodup y xs ↔ x = y ∨ x ∈ xs := by
  unfold insertNodup
  split
  · rename_i h
    have hm : y ∈ xs := List.contains_iff_mem.mp h
    constructor
    · intro hx; exact Or.inr hx
    · rintro (rfl | hx) <;> assumption
  · simp [List.mem_append, or_comm]

private theorem nodup_append_single {l : List Nat} {x : Nat} (h : l.Nodup) (hx : x ∉ l) :
    (l ++ [x]).Nodup := by
  induction l with
  | nil => simp
  | cons a t ih =>
    rw [List.nodup_cons] at h
    simp only [List.cons_append, List.nodup_cons]
    refine ⟨?_, ih h.2 (fun hm => hx (List.mem_cons_of_mem _ hm))⟩
    intro hm
    rcases List.mem_append.mp hm with hm | hm
    · exact h.1 hm
    · simp only [List.mem_singleton] at hm
      subst hm
      exact hx (List.mem_cons_self ..)

theorem insertNodup_nodup {x : Nat} {xs : List Nat} (h : xs.Nodup) : (insertNodup x xs).Nodup := by
  unfold insertNodup
  split
  · exact h
  · rename_i hc
    exact nodup_append_single h (fun hm => hc (List.contains_iff_mem.mpr hm))

/-- **`done` only after every sub-plan settled (`DoneAfterAllSubPlans`,
`RecordPoolReshardTerminalLocked`)**: every insertion of `req_id` into
`done_recving_` / `done_sending_` for a `count`-plan request was made with
`count` distinct sub-plan indices in `[0, count)` settled OK
(`if (progress.settled.size() >= progress.count)`). -/
def DoneAfterAllSubPlans (w : WorkerState) : Prop :=
  ∀ e ∈ w.doneLog, e.2.Nodup ∧ (∀ i ∈ e.2, i < e.1) ∧ e.1 ≤ e.2.length

structure WorkerSafe (w : WorkerState) : Prop where
  doneAfterAll : DoneAfterAllSubPlans w

/-- Inductive invariant of `WorkerState.step`. -/
structure WorkerInv (w : WorkerState) : Prop where
  safe : WorkerSafe w
  settledNodup : w.chain.settled.Nodup
  settledBound : ∀ i ∈ w.chain.settled, i < w.chain.count
  activeIndex : ∀ s ∈ w.active, s.index < max 1 s.count

theorem init_workerInv : WorkerInv WorkerState.init where
  safe := ⟨fun _ h => by cases h⟩
  settledNodup := List.nodup_nil
  settledBound := fun _ h => by cases h
  activeIndex := fun _ h => by cases h

private def GoodEntry (e : Nat × List Nat) : Prop :=
  e.2.Nodup ∧ (∀ i ∈ e.2, i < e.1) ∧ e.1 ≤ e.2.length

private theorem noteSubPlanRegistered_shape (c : ChainProgress) (uuid index count : Nat)
    (hn : c.settled.Nodup) (hb : ∀ i ∈ c.settled, i < c.count) :
    (noteSubPlanRegistered c uuid index count).1.settled.Nodup ∧
    ∀ i ∈ (noteSubPlanRegistered c uuid index count).1.settled,
      i < (noteSubPlanRegistered c uuid index count).1.count := by
  unfold noteSubPlanRegistered
  split
  · exact ⟨hn, hb⟩
  · dsimp only
    split
    · exact ⟨List.nodup_nil, fun _ h => by cases h⟩
    · split
      · refine ⟨hn, ?_⟩
        intro i hi
        exact Nat.lt_of_lt_of_le (hb i hi) (Nat.le_max_left _ _)
      · exact ⟨List.nodup_nil, fun _ h => by cases h⟩

private theorem recordTerminal_shape (c : ChainProgress) (s : SubSession)
    (hn : c.settled.Nodup) (hb : ∀ i ∈ c.settled, i < c.count)
    (hs : s.index < max 1 s.count) :
    (recordTerminal c s).1.settled.Nodup ∧
    (∀ i ∈ (recordTerminal c s).1.settled, i < (recordTerminal c s).1.count) ∧
    (∀ k idx, (recordTerminal c s).2 = .done k idx → GoodEntry (k, idx)) := by
  unfold recordTerminal
  split
  · rename_i hle
    have hmax : max 1 s.count = 1 := by omega
    refine ⟨hn, hb, ?_⟩
    intro k idx h
    split at h
    · injection h with hk hidx
      subst hk; subst hidx
      refine ⟨by simp, ?_, by simp⟩
      intro i hi
      simp only [List.mem_singleton] at hi
      subst hi
      omega
    · cases h
  · rename_i hgt
    split
    · exact ⟨hn, hb, fun _ _ h => by cases h⟩
    · -- `c0` is `c` or a default-constructed entry.
      have hc0 : ∀ c0 : ChainProgress, (c0 = c ∨ c0 = { present := true }) →
          c0.settled.Nodup ∧ ∀ i ∈ c0.settled, i < c0.count := by
        rintro c0 (rfl | rfl)
        · exact ⟨hn, hb⟩
        · exact ⟨List.nodup_nil, fun _ h => by cases h⟩
      generalize hc0def : (if c.present then c else { present := true } : ChainProgress) = c0
      have hc0' : c0.settled.Nodup ∧ ∀ i ∈ c0.settled, i < c0.count := by
        split at hc0def
        · exact hc0 c0 (Or.inl hc0def.symm)
        · exact hc0 c0 (Or.inr hc0def.symm)
      obtain ⟨hn0, hb0⟩ := hc0'
      dsimp only
      split
      · exact ⟨hn0, hb0, fun _ _ h => by cases h⟩
      · split
        · refine ⟨hn0, ?_, fun _ _ h => by cases h⟩
          intro i hi
          exact Nat.lt_of_lt_of_le (hb0 i hi) (Nat.le_max_left _ _)
        · have hcount : max 1 s.count = s.count := by omega
          have hidx_bound : ∀ i ∈ insertNodup s.index c0.settled, i < max c0.count s.count := by
            intro i hi
            rcases mem_insertNodup.mp hi with rfl | hi
            · omega
            · exact Nat.lt_of_lt_of_le (hb0 i hi) (Nat.le_max_left _ _)
          split
          · rename_i hlen
            refine ⟨List.nodup_nil, fun _ h => by simp at h, ?_⟩
            intro k idx h
            injection h with hk hidx
            subst hk; subst hidx
            refine ⟨insertNodup_nodup hn0, hidx_bound, ?_⟩
            simpa using hlen
          · exact ⟨insertNodup_nodup hn0, hidx_bound, fun _ _ h => by cases h⟩

private theorem foldRecord_shape (settled : List SubSession) :
    ∀ (acc : WorkerState.SweepAcc),
      acc.1.settled.Nodup → (∀ i ∈ acc.1.settled, i < acc.1.count) →
      (∀ s ∈ settled, s.index < max 1 s.count) →
      (∀ e ∈ acc.2.2.2, GoodEntry e) →
      let r := settled.foldl WorkerState.recordStep acc
      r.1.settled.Nodup ∧ (∀ i ∈ r.1.settled, i < r.1.count) ∧ ∀ e ∈ r.2.2.2, GoodEntry e := by
  induction settled with
  | nil =>
    intro acc hn hb _ hlog
    exact ⟨hn, hb, hlog⟩
  | cons s rest ih =>
    intro acc hn hb hs hlog
    have hs0 := hs s (List.mem_cons_self ..)
    have hrest : ∀ s' ∈ rest, s'.index < max 1 s'.count :=
      fun s' h => hs s' (List.mem_cons_of_mem _ h)
    obtain ⟨hn', hb', hgood⟩ := recordTerminal_shape acc.1 s hn hb hs0
    simp only [List.foldl_cons]
    have hstep : ∀ acc' : WorkerState.SweepAcc, WorkerState.recordStep acc s = acc' →
        acc'.1.settled.Nodup ∧ (∀ i ∈ acc'.1.settled, i < acc'.1.count) ∧
        ∀ e ∈ acc'.2.2.2, GoodEntry e := by
      intro acc' h
      unfold WorkerState.recordStep at h
      rcases hrt : recordTerminal acc.1 s with ⟨c', t⟩
      rw [hrt] at h hn' hb' hgood
      cases t with
      | supersededIgnored => subst h; exact ⟨hn', hb', hlog⟩
      | failedIgnored => subst h; exact ⟨hn', hb', hlog⟩
      | settledPartial => subst h; exact ⟨hn', hb', hlog⟩
      | done k idx =>
        subst h
        refine ⟨hn', hb', ?_⟩
        intro e he
        rcases List.mem_append.mp he with he | he
        · exact hlog e he
        · simp only [List.mem_singleton] at he
          subst he
          exact hgood k idx rfl
      | failed => subst h; exact ⟨hn', hb', hlog⟩
    obtain ⟨hn1, hb1, hlog1⟩ := hstep _ rfl
    exact ih _ hn1 hb1 hrest hlog1

private theorem recordAll_shape (c : ChainProgress) (settled : List SubSession)
    (hn : c.settled.Nodup) (hb : ∀ i ∈ c.settled, i < c.count)
    (hs : ∀ s ∈ settled, s.index < max 1 s.count) :
    (WorkerState.recordAll c settled).1.settled.Nodup ∧
    (∀ i ∈ (WorkerState.recordAll c settled).1.settled, i < (WorkerState.recordAll c settled).1.count) ∧
    ∀ e ∈ (WorkerState.recordAll c settled).2.2.2, GoodEntry e :=
  foldRecord_shape settled (c, 0, 0, []) hn hb hs (fun _ h => by cases h)

theorem WorkerInv.toSafe {w : WorkerState} (h : WorkerInv w) : WorkerSafe w := h.safe

theorem step_preserves_workerInv {w w' : WorkerState} {e : WorkerEv}
    (hinv : WorkerInv w) (hstep : WorkerState.step w e = some w') : WorkerInv w' := by
  cases e with
  | registerSubPlan uuid index count =>
    simp only [WorkerState.step] at hstep
    split at hstep
    · cases hstep
    split at hstep
    · cases hstep
    rename_i hidx
    injection hstep with h; subst h
    obtain ⟨hn, hb⟩ := noteSubPlanRegistered_shape w.chain uuid index count
      hinv.settledNodup hinv.settledBound
    refine ⟨⟨hinv.safe.doneAfterAll⟩, hn, hb, ?_⟩
    intro s hs
    rcases List.mem_append.mp hs with hs | hs
    · exact hinv.activeIndex s hs
    · simp only [List.mem_singleton] at hs
      subst hs
      simp only [Nat.not_le] at hidx
      exact hidx
  | settleSession uuid ok =>
    simp only [WorkerState.step] at hstep
    split at hstep
    · cases hstep
    injection hstep with h; subst h
    refine ⟨⟨hinv.safe.doneAfterAll⟩, hinv.settledNodup, hinv.settledBound, ?_⟩
    intro s' hs'
    obtain ⟨s, hs, rfl⟩ := List.mem_map.mp hs'
    have := hinv.activeIndex s hs
    split <;> simpa using this
  | poll stalled =>
    simp only [WorkerState.step] at hstep
    have hsettled : ∀ s ∈ w.active.filter (·.done), s.index < max 1 s.count :=
      fun s hs => hinv.activeIndex s (List.mem_filter.mp hs).1
    have hr := recordAll_shape w.chain (w.active.filter (·.done))
      hinv.settledNodup hinv.settledBound hsettled
    generalize WorkerState.recordAll w.chain (w.active.filter (·.done)) = r at hstep hr
    rcases r with ⟨c1, dInc, fInc, log⟩
    obtain ⟨hn1, hb1, hlog⟩ := hr
    -- The sweep keeps `settled` or erases the entry.
    have hsweep : ∀ (c2 : ChainProgress) (b : SweepOutcome),
        (if stalled then sweepStalledChain c1 (w.active.filter (!·.done)) else (c1, .notSwept)) = (c2, b) →
        c2.settled.Nodup ∧ ∀ i ∈ c2.settled, i < c2.count := by
      intro c2 b h
      split at h
      · unfold sweepStalledChain at h
        split at h
        · injection h with h1 _; subst h1; exact ⟨hn1, hb1⟩
        split at h
        · injection h with h1 _; subst h1; exact ⟨List.nodup_nil, fun _ h => by cases h⟩
        split at h
        · injection h with h1 _; subst h1; exact ⟨hn1, hb1⟩
        · injection h with h1 _; subst h1; exact ⟨hn1, hb1⟩
      · injection h with h1 _; subst h1; exact ⟨hn1, hb1⟩
    generalize hr2 : (if stalled then sweepStalledChain c1 (w.active.filter (!·.done)) else (c1, .notSwept)) = r2 at hstep
    rcases r2 with ⟨c2, sweepFail⟩
    obtain ⟨hn2, hb2⟩ := hsweep c2 sweepFail hr2
    injection hstep with h; subst h
    refine ⟨⟨?_⟩, hn2, hb2, ?_⟩
    · intro e he
      rcases List.mem_append.mp he with he | he
      · exact hinv.safe.doneAfterAll e he
      · exact hlog e he
    · intro s hs
      exact hinv.activeIndex s (List.mem_filter.mp hs).1

/-- **Main worker theorem (`reachable_worker_safe`)**: in every reachable state of
`WorkerState.step`, `DoneAfterAllSubPlans` holds. -/
theorem reachable_worker_safe {w : WorkerState} (hr : WorkerState.sys.Reachable w) :
    WorkerSafe w :=
  (WorkerState.sys.reachable_induction init_workerInv
    (fun _ _ _ hinv hstep => step_preserves_workerInv hinv hstep) hr).toSafe

/-! ## Part III — Coordinator multi-window chain -/

/-- Well-formed chain topology: at least one window, every window non-empty and
drawn from the claimed source snapshot (`BuildPoolReshardPlan` keeps a subset of
`request.src_units`, and a window with no spans is never planned). -/
structure ValidChainCfg (allSrcUnits : List Nat) (winSrcUnits : List (List Nat)) : Prop where
  winNonEmpty : winSrcUnits ≠ []
  winSub : ∀ ws ∈ winSrcUnits, ws ≠ [] ∧ ∀ u ∈ ws, u ∈ allSrcUnits

/-- **No dispatched sender without a claim (`NoSenderExposed`,
`ReshardCoordinator::RunSubPlan` `if (index == 0)`)**: a rank whose
`ReshardSendSession` was dispatched in some window and has not yet voted
`Complete` is never left without the generation's registry claim. -/
def NoSenderExposed (s : CoordChainState) : Prop := s.activeSenderExposed = false

/-- **No push before all armed (`NoPushBeforeAllArmed`, `RunSubPlan`)**: while a
window is arming, none of its senders has been dispatched. -/
def NoPushBeforeAllArmed (s : CoordChainState) : Prop :=
  s.winPhase = .arming → s.sendResults = []

/-- **All armed while dispatching (`AllArmedWhileDispatching`, `RunSubPlan`)**:
while a window dispatches senders, every destination's receiver for that
window is armed. -/
def AllArmedWhileDispatching (s : CoordChainState) : Prop :=
  s.winPhase = .dispatching → ∀ d ∈ s.dstStates, d.curWinArmed = true

/-- **One window staged per destination (`OneWindowStagedPerDestination`,
`ArmRefusedForBusyStaging`)**: a destination whose earlier window's receiver
still holds its staging lease never has the current window's receiver armed. -/
def OneWindowStagedPerDestination (s : CoordChainState) : Prop :=
  ∀ d ∈ s.dstStates, d.prevSessionActive = true → d.curWinArmed = false

/-- **`kCompleted` only at chain end (`CompletedOnlyAtChainEnd`, `StartChain`)**:
`transfer_status_` reads `kCompleted` only after the last window's Stage 2. -/
def CompletedOnlyAtChainEnd (s : CoordChainState) : Prop :=
  s.transferStatus = .completed → s.winIdx + 1 = s.winSrcUnits.length ∧ s.winPhase = .succeeded

/-- **Claim held across windows (`ClaimHeldAcrossWindows`, `RunSubPlan`
`LookupAndClaim`)**: from window 0's Stage 0 until the chain ends, the source
snapshot stays claimed by `ctx->claim_owner`, so `CancelIfUnclaimed` cannot
cancel it between windows. -/
def ClaimHeldAcrossWindows (s : CoordChainState) : Prop :=
  s.transferStatus = .inProgress → (s.winPhase ≠ .idle ∨ 0 < s.winIdx) →
    s.reg.claimedUnits = some s.allSrcUnits ∧ s.reg.claimOwners = [s.claimOwner]

structure CoordChainSafe (s : CoordChainState) : Prop where
  regInv : Registry.Inv s.reg
  noSenderExposed : NoSenderExposed s
  noPushBeforeAllArmed : NoPushBeforeAllArmed s
  allArmedWhileDispatching : AllArmedWhileDispatching s
  oneWindowStaged : OneWindowStagedPerDestination s
  completedOnlyAtChainEnd : CompletedOnlyAtChainEnd s
  claimHeldAcrossWindows : ClaimHeldAcrossWindows s

def RegIdle (s : CoordChainState) : Prop :=
  s.reg.claimedUnits = none ∧ s.reg.claimOwners = [] ∧ s.reg.completedUnits = []

def ClaimedBy (s : CoordChainState) : Prop :=
  s.reg.claimedUnits = some s.allSrcUnits ∧ s.reg.claimOwners = [s.claimOwner]

def ClaimReleased (s : CoordChainState) : Prop :=
  s.reg.claimedUnits = none ∧ s.reg.claimOwners = []

/-- No rank of the running or a later window has voted `Complete`. -/
def RemainingUnvoted (s : CoordChainState) : Prop :=
  ∀ j, s.winIdx ≤ j → ∀ w ∈ s.winSrcUnits.getD j [], w ∉ s.reg.completedUnits

def Running (s : CoordChainState) : Prop :=
  s.winPhase = .idle ∨ s.winPhase = .arming ∨ s.winPhase = .dispatching

def PhaseShape (s : CoordChainState) : Prop :=
  (s.transferStatus = .notStarted ∧ s.winIdx = 0 ∧ s.winPhase = .idle ∧
    s.activeSenders = [] ∧ RegIdle s) ∨
  (s.transferStatus = .inProgress ∧ s.winIdx = 0 ∧ s.winPhase = .idle ∧
    s.activeSenders = [] ∧ RegIdle s) ∨
  (s.transferStatus = .inProgress ∧ s.winIdx < s.winSrcUnits.length ∧ Running s ∧
    (s.winIdx = 0 → s.winPhase ≠ .idle ∧ (s.winPhase = .arming → s.activeSenders = [])) ∧
    ClaimedBy s ∧ RemainingUnvoted s) ∨
  (((s.transferStatus = .completed ∧ s.winIdx + 1 = s.winSrcUnits.length ∧
      s.winPhase = .succeeded) ∨ s.transferStatus = .failed) ∧
    (ClaimedBy s ∨ ClaimReleased s))

/-- Inductive invariant of `CoordChainState.step`. -/
structure CoordChainInv (s : CoordChainState) : Prop where
  cfg : ValidChainCfg s.allSrcUnits s.winSrcUnits
  dstShape : s.dstStates.map (·.unit) = s.dstUnits
  regInv : Registry.Inv s.reg
  noExposed : s.activeSenderExposed = false
  activeSrc : ∀ u ∈ s.activeSenders, u ∈ s.allSrcUnits ∧ u ∉ s.reg.completedUnits
  activeClaimed : s.activeSenders ≠ [] → ClaimedBy s
  oneLease : ∀ d ∈ s.dstStates, d.prevSessionActive = true → d.curWinArmed = false
  armShape : s.winPhase = .arming → ∀ d ∈ s.dstStates, d.curWinArmed = armOk s.armResults d.unit
  dispShape : s.winPhase = .dispatching → ∀ d ∈ s.dstStates, d.curWinArmed = true
  restShape : (s.winPhase = .idle ∨ s.winPhase = .succeeded) →
    ∀ d ∈ s.dstStates, d.curWinArmed = false
  noPushArming : s.winPhase = .arming → s.sendResults = []
  phase : PhaseShape s

theorem CoordChainInv.toSafe {s : CoordChainState} (h : CoordChainInv s) : CoordChainSafe s where
  regInv := h.regInv
  noSenderExposed := h.noExposed
  noPushBeforeAllArmed := h.noPushArming
  allArmedWhileDispatching := h.dispShape
  oneWindowStaged := h.oneLease
  completedOnlyAtChainEnd := by
    intro hc
    rcases h.phase with ⟨ht, _⟩ | ⟨ht, _⟩ | ⟨ht, _⟩ | ⟨⟨_, hl, hp⟩ | ht, _⟩
    · rw [hc] at ht; cases ht
    · rw [hc] at ht; cases ht
    · rw [hc] at ht; cases ht
    · exact ⟨hl, hp⟩
    · rw [hc] at ht; cases ht
  claimHeldAcrossWindows := by
    intro hst hrun
    rcases h.phase with ⟨ht, _⟩ | ⟨_, hi, hp, _⟩ | ⟨_, _, _, _, hcl, _⟩ | ⟨⟨ht, _⟩ | ht, _⟩
    · rw [hst] at ht; cases ht
    · rcases hrun with hne | hpos
      · exact absurd hp hne
      · omega
    · exact hcl
    · rw [hst] at ht; cases ht
    · rw [hst] at ht; cases ht

/-! ### Registry and list helpers -/

private theorem lookupAndClaim_when_claimed {reg reg' : RegGen} {owner : Nat} {units : List Nat}
    (hinv : Registry.Inv reg) (hc : reg.claimedUnits = some units) (ho : reg.claimOwners = [owner])
    (hstep : RegGen.step reg (.lookupAndClaim owner units) = some reg') :
    reg'.claimedUnits = some units ∧ reg'.claimOwners = [owner] ∧
    reg'.completedUnits = reg.completedUnits := by
  dsimp only [RegGen.step] at hstep
  split at hstep
  · cases hstep
  split at hstep
  · cases hstep
  split at hstep
  · cases hstep
  have hall : allVoted units reg.completedUnits = false := hinv.partialVotes units hc
  simp only [hall, Bool.false_eq_true, ↓reduceIte, Option.some.injEq] at hstep
  subst hstep
  simp [ho, insertNodup]

private theorem complete_claimed {reg : RegGen} {units : List Nat} {owner u : Nat}
    (hc : reg.claimedUnits = some units) (ho : reg.claimOwners = [owner]) (hu : u ∈ units) :
    RegGen.step reg (.complete u) =
      some (if allVoted units (insertNodup u reg.completedUnits) then reg.retireLocked
            else { reg with completedUnits := insertNodup u reg.completedUnits }) := by
  have hin : inClaimedUnits (some units) u = true := by simp [inClaimedUnits, hu]
  have _ := ho
  unfold RegGen.step
  simp only [hc, hin, Option.isSome_some, Bool.not_true, Bool.false_and, Bool.false_eq_true,
    ↓reduceIte, Bool.and_false]
  split <;> rfl

private theorem cancelIfUnclaimed_shape {reg reg' : RegGen}
    (hstep : RegGen.step reg .cancelIfUnclaimed = some reg') :
    reg' = reg ∨
    (reg.claimedUnits = none ∧ reg'.claimedUnits = none ∧ reg'.claimOwners = [] ∧
      reg'.completedUnits = []) := by
  dsimp only [RegGen.step] at hstep
  split at hstep
  · injection hstep with h; exact Or.inl h.symm
  split at hstep
  · injection hstep with h; exact Or.inl h.symm
  · rename_i hns
    injection hstep with h; subst h
    refine Or.inr ⟨?_, rfl, rfl, rfl⟩
    cases hcl : reg.claimedUnits with
    | none => rfl
    | some _ => rw [hcl] at hns; simp at hns

private theorem armOk_append (rs : List (Nat × ArmOutcome)) (u : Nat) (o : ArmOutcome) (v : Nat) :
    armOk (rs ++ [(u, o)]) v = (armOk rs v || (u == v && o == .ok)) := by
  simp [armOk, List.any_append]

private theorem armOk_filter_ok (rs : List (Nat × ArmOutcome)) (v : Nat) :
    armOk (rs.filter (·.2 == .ok)) v = armOk rs v := by
  induction rs with
  | nil => rfl
  | cons r rest ih =>
    obtain ⟨ru, ro⟩ := r
    simp only [armOk, List.filter_cons] at ih ⊢
    split <;> simp_all [List.any_cons]

private theorem armOk_false_of_not_reported {rs : List (Nat × ArmOutcome)} {v : Nat}
    (h : armReported rs v = false) : armOk rs v = false := by
  simp only [armReported, List.any_eq_false] at h
  simp only [armOk, List.any_eq_false]
  intro r hr
  have := h r hr
  simp_all

private theorem armOk_of_reported_no_fail {rs : List (Nat × ArmOutcome)} {v : Nat}
    (hrep : armReported rs v = true) (hok : anyArmFailed rs = false) : armOk rs v = true := by
  simp only [armReported, List.any_eq_true] at hrep
  simp only [anyArmFailed, List.any_eq_false] at hok
  obtain ⟨r, hr, hrv⟩ := hrep
  have := hok r hr
  simp only [armOk, List.any_eq_true]
  refine ⟨r, hr, ?_⟩
  simp_all

private theorem getD_mem_of_lt {l : List (List Nat)} {j : Nat} (h : j < l.length) :
    l.getD j [] ∈ l := by
  rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h]
  exact List.getElem_mem h

private theorem getD_eq_nil_of_le {l : List (List Nat)} {j : Nat} (h : l.length ≤ j) :
    l.getD j [] = [] := by
  rw [List.getD_eq_getElem?_getD, List.getElem?_eq_none h]
  rfl

private theorem not_in_remaining {s : CoordChainState} {u : Nat}
    (hst : s.transferStatus = .inProgress) (h : s.appearsInRemainingWindows u = false) :
    ∀ j, s.winIdx ≤ j → u ∉ s.winSrcUnits.getD j [] := by
  intro j hj hmem
  unfold CoordChainState.appearsInRemainingWindows at h
  rw [hst] at h
  simp only [beq_self_eq_true, Bool.true_and, List.any_eq_false, List.mem_range] at h
  by_cases hlt : j < s.winSrcUnits.length
  · have := h j hlt
    simp only [hj, decide_true, Bool.true_and, List.contains_iff_mem] at this
    exact this hmem
  · rw [getD_eq_nil_of_le (Nat.le_of_not_lt hlt)] at hmem
    cases hmem

private theorem map_unit_preserved (ds : List ChainDstState) (f : ChainDstState → ChainDstState)
    (hf : ∀ d, (f d).unit = d.unit) : (ds.map f).map (·.unit) = ds.map (·.unit) := by
  rw [List.map_map]
  apply List.map_congr_left
  intro d _
  exact hf d

/-! ### Initial state and step preservation -/

theorem init_coordChainInv {allSrcs : List Nat} {winSrcs : List (List Nat)} {dsts : List Nat}
    {owner maxAtt : Nat} (hcfg : ValidChainCfg allSrcs winSrcs) :
    CoordChainInv (CoordChainState.init allSrcs winSrcs dsts owner maxAtt) where
  cfg := hcfg
  dstShape := by simp [CoordChainState.init, List.map_map, Function.comp_def]
  regInv := Registry.init_inv
  noExposed := rfl
  activeSrc := fun _ h => by cases h
  activeClaimed := fun h => absurd rfl h
  oneLease := by
    intro d hd
    simp only [CoordChainState.init, List.mem_map] at hd
    obtain ⟨_, _, rfl⟩ := hd
    intro h; cases h
  armShape := fun h => by cases h
  dispShape := fun h => by cases h
  restShape := by
    intro _ d hd
    simp only [CoordChainState.init, List.mem_map] at hd
    obtain ⟨_, _, rfl⟩ := hd
    rfl
  noPushArming := fun h => by cases h
  phase := Or.inl ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- `syncSenderExposure` is the identity when no sender is active or the
generation is claimed. -/
private theorem syncSenderExposure_id {s : CoordChainState}
    (h : s.activeSenders = [] ∨ s.reg.claimedUnits.isSome = true) :
    CoordChainState.syncSenderExposure s = s := by
  unfold CoordChainState.syncSenderExposure
  rcases h with h | h <;> simp [h]

private theorem inv_syncSenderExposure {s : CoordChainState}
    (h : s.activeSenders = [] ∨ s.reg.claimedUnits.isSome = true) (hinv : CoordChainInv s) :
    CoordChainInv s.syncSenderExposure := by
  rw [syncSenderExposure_id h]; exact hinv

private theorem length_pos_of_ne_nil {l : List (List Nat)} (h : l ≠ []) : 0 < l.length := by
  cases l with
  | nil => exact absurd rfl h
  | cons _ _ => simp

set_option maxHeartbeats 800000 in
theorem step_preserves_coordChainInv {s s' : CoordChainState} {e : ChainEv}
    (hinv : CoordChainInv s) (hstep : CoordChainState.step s e = some s') :
    CoordChainInv s' := by
  obtain ⟨hcfg, hdst, hreg, hexp, hasrc, hacl, hlease, harm, hdisp, hrest, hnp, hph⟩ := hinv
  cases e with
  | registerProducer u =>
    simp only [CoordChainState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hg
    simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, Bool.not_eq_true', not_or,
      Decidable.not_not] at hg
    obtain ⟨hst, _⟩ := hg
    cases hr : RegGen.step s.reg (.register u true) with
    | none => rw [hr] at hstep; cases hstep
    | some reg' =>
      rw [hr] at hstep
      simp only [Option.map_some, Option.some.injEq] at hstep
      subst hstep
      rcases hph with ⟨_, hi, hp, hact, hc, ho, hcomp⟩ | ⟨ht, _⟩ | ⟨ht, _⟩ | ⟨⟨ht, _⟩ | ht, _⟩
      · obtain ⟨hc', ho', hcomp'⟩ := register_preserves_idle_reg s.reg reg' u hc ho hcomp hr
        refine ⟨hcfg, hdst, Registry.step_preserves_inv hreg hr, hexp, ?_, ?_, hlease, harm, hdisp,
          hrest, hnp, Or.inl ⟨hst, hi, hp, hact, hc', ho', hcomp'⟩⟩
        · intro v hv; rw [hact] at hv; cases hv
        · intro h; exact absurd hact h
      · rw [hst] at ht; cases ht
      · rw [hst] at ht; cases ht
      · rw [hst] at ht; cases ht
      · rw [hst] at ht; cases ht

  | startChainCoordination =>
    simp only [CoordChainState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hg
    simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hg
    injection hstep with h; subst h
    rcases hph with ⟨_, hi, hp, hact, hidle⟩ | ⟨ht, _⟩ | ⟨ht, _⟩ | ⟨⟨ht, _⟩ | ht, _⟩
    · exact ⟨hcfg, hdst, hreg, hexp, hasrc, hacl, hlease, harm, hdisp, hrest, hnp,
        Or.inr (Or.inl ⟨rfl, hi, hp, hact, hidle⟩)⟩
    · rw [hg] at ht; cases ht
    · rw [hg] at ht; cases ht
    · rw [hg] at ht; cases ht
    · rw [hg] at ht; cases ht

  | startWindowPlan planOk =>
    simp only [CoordChainState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hg
    simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, not_or, Decidable.not_not] at hg
    obtain ⟨hst, hidle⟩ := hg
    have hpos : 0 < s.winSrcUnits.length := length_pos_of_ne_nil hcfg.winNonEmpty
    have hrest_idle := hrest (Or.inl hidle)
    -- Abort at Stage 0 from a state whose claim shape we know.
    have habort : ∀ (s0 : CoordChainState), s0.allSrcUnits = s.allSrcUnits →
        s0.winSrcUnits = s.winSrcUnits → s0.dstUnits = s.dstUnits → s0.claimOwner = s.claimOwner →
        s0.winIdx = s.winIdx → s0.dstStates = s.dstStates → s0.activeSenders = s.activeSenders →
        s0.activeSenderExposed = false → s0.sendResults = s.sendResults → s0.winPhase = .idle →
        Registry.Inv s0.reg →
        (s.winIdx ≠ 0 → ClaimedBy s0) →
        (s.winIdx = 0 → s0.activeSenders = [] ∧
          ((s0.reg.claimedUnits = none ∧ s0.reg.claimOwners = []) ∨ ClaimedBy s0)) →
        (∀ u ∈ s0.activeSenders, u ∈ s0.allSrcUnits ∧ u ∉ s0.reg.completedUnits) →
        (s0.activeSenders ≠ [] → ClaimedBy s0) →
        CoordChainInv (CoordChainState.abortWindow 0 s0) := by
      intro s0 h1 h2 h3 h4 h5 h6 h7 h8 h9 h10 hinv0 hcl0 hsh0 hasrc0 hacl0
      unfold CoordChainState.abortWindow
      simp only [Nat.zero_le, decide_true, Bool.true_and, beq_iff_eq]
      split
      · rename_i hw0
        obtain ⟨hact, hshape⟩ := hsh0 (by rw [← h5]; exact hw0)
        have hcl : (abandonIfClaimed s0.reg s0.claimOwner).claimedUnits = none ∧
            (abandonIfClaimed s0.reg s0.claimOwner).claimOwners = [] := by
          rcases hshape with ⟨hcn, ho⟩ | ⟨hc, ho⟩
          · exact abandonIfClaimed_clears_single_owner s0.reg s0.allSrcUnits s0.claimOwner
              (Or.inr ⟨hcn, ho⟩)
          · exact abandonIfClaimed_clears_single_owner s0.reg s0.allSrcUnits s0.claimOwner
              (Or.inl ⟨hc, ho⟩)
        refine inv_syncSenderExposure (Or.inl hact) ?_
        refine ⟨by rw [h1, h2]; exact hcfg, by rw [h6, h3]; exact hdst,
          abandonIfClaimed_inv _ _ hinv0, h8, ?_, ?_, by rw [h6]; exact hlease,
          (fun h => by cases h), (fun h => by cases h), (fun h => by rcases h with h | h <;> cases h),
          (fun h => by cases h), ?_⟩
        · intro v hv; rw [hact] at hv; cases hv
        · intro h; exact absurd hact h
        · exact Or.inr (Or.inr (Or.inr ⟨Or.inr rfl, Or.inr hcl⟩))
      · rename_i hw0
        have hcl : ClaimedBy s0 := hcl0 (by rw [← h5]; exact hw0)
        have hsome : s0.reg.claimedUnits.isSome = true := by rw [hcl.1]; rfl
        refine inv_syncSenderExposure (Or.inr hsome) ?_
        refine ⟨by rw [h1, h2]; exact hcfg, by rw [h6, h3]; exact hdst, hinv0, h8, hasrc0, hacl0,
          by rw [h6]; exact hlease,
          (fun h => by cases h), (fun h => by cases h), (fun h => by rcases h with h | h <;> cases h),
          (fun h => by cases h), ?_⟩
        exact Or.inr (Or.inr (Or.inr ⟨Or.inr rfl, Or.inl hcl⟩))
    cases hr : RegGen.step s.reg (.lookupAndClaim s.claimOwner s.allSrcUnits) with
    | none =>
      simp only [hr, Option.some.injEq] at hstep
      subst hstep
      -- `LookupAndClaim` refused: the registry is unchanged.
      refine habort s rfl rfl rfl rfl rfl rfl rfl hexp rfl hidle hreg ?_ ?_ hasrc hacl
      · intro hw0
        rcases hph with ⟨_, hi, _⟩ | ⟨_, hi, _⟩ | ⟨_, _, _, _, hc, _⟩ | ⟨⟨ht, _⟩ | ht, _⟩
        · exact absurd hi hw0
        · exact absurd hi hw0
        · exact hc
        · rw [hst] at ht; cases ht
        · rw [hst] at ht; cases ht
      · intro hw0
        rcases hph with ⟨_, _, _, hact, hc, ho, _⟩ | ⟨_, _, _, hact, hc, ho, _⟩ |
            ⟨_, _, _, hz, _⟩ | ⟨⟨ht, _⟩ | ht, _⟩
        · exact ⟨hact, Or.inl ⟨hc, ho⟩⟩
        · exact ⟨hact, Or.inl ⟨hc, ho⟩⟩
        · exact absurd hidle (hz hw0).1
        · rw [hst] at ht; cases ht
        · rw [hst] at ht; cases ht
    | some regClaimed =>
      simp only [hr] at hstep
      have hreg' : Registry.Inv regClaimed := Registry.step_preserves_inv hreg hr
      -- The claim shape after `LookupAndClaim`.
      have hclaimed : regClaimed.claimedUnits = some s.allSrcUnits ∧
          regClaimed.claimOwners = [s.claimOwner] ∧
          (regClaimed.completedUnits = s.reg.completedUnits ∨ regClaimed.completedUnits = []) ∧
          (s.winIdx = 0 → s.activeSenders = []) := by
        rcases hph with ⟨ht, _⟩ | ⟨_, _, _, hact, _, ho, hcomp⟩ |
            ⟨_, _, _, hz, hc, _⟩ | ⟨⟨ht, _⟩ | ht, _⟩
        · rw [hst] at ht; cases ht
        · obtain ⟨hc', ho', hcomp'⟩ := lookupAndClaim_from_idle_shape s.reg regClaimed
            s.claimOwner s.allSrcUnits ho hcomp hr
          exact ⟨hc', ho', Or.inr hcomp', fun _ => hact⟩
        · obtain ⟨hc', ho', hcomp'⟩ := lookupAndClaim_when_claimed hreg hc.1 hc.2 hr
          exact ⟨hc', ho', Or.inl hcomp', fun hw0 => absurd hidle (hz hw0).1⟩
        · rw [hst] at ht; cases ht
        · rw [hst] at ht; cases ht
      obtain ⟨hc', ho', hcomp', hact0⟩ := hclaimed
      have hasrc' : ∀ u ∈ s.activeSenders, u ∈ s.allSrcUnits ∧ u ∉ regClaimed.completedUnits := by
        intro u hu
        obtain ⟨h1, h2⟩ := hasrc u hu
        refine ⟨h1, ?_⟩
        rcases hcomp' with h | h <;> rw [h]
        · exact h2
        · intro h; cases h
      split at hstep
      · -- `BuildPoolReshardPlan` succeeded: Stage 1 begins.
        injection hstep with h; subst h
        refine inv_syncSenderExposure (Or.inr (by simp [hc'])) ?_
        refine ⟨hcfg, hdst, hreg', hexp, hasrc', fun _ => ⟨hc', ho'⟩, hlease, ?_,
          (fun h => by cases h), (fun h => by rcases h with h | h <;> cases h), fun _ => rfl, ?_⟩
        · intro _ d hd
          rw [hrest_idle d hd]
          rfl
        · refine Or.inr (Or.inr (Or.inl ⟨hst, ?_, Or.inr (Or.inl rfl), ?_, ⟨hc', ho'⟩, ?_⟩))
          · rcases hph with ⟨ht, _⟩ | ⟨_, hi, _⟩ | ⟨_, hl, _⟩ | ⟨⟨ht, _⟩ | ht, _⟩
            · rw [hst] at ht; cases ht
            · rw [hi]; exact hpos
            · exact hl
            · rw [hst] at ht; cases ht
            · rw [hst] at ht; cases ht
          · intro hw0
            exact ⟨(fun h => by cases h), fun _ => hact0 hw0⟩
          · intro j hj w hw
            rcases hph with ⟨ht, _⟩ | ⟨_, _, _, _, _, _, hcomp⟩ | ⟨_, _, _, _, _, hrem⟩ | ⟨⟨ht, _⟩ | ht, _⟩
            · rw [hst] at ht; cases ht
            · rcases hcomp' with h | h <;> rw [h]
              · rw [hcomp]; intro h; cases h
              · intro h; cases h
            · rcases hcomp' with h | h <;> rw [h]
              · exact hrem j hj w hw
              · intro h; cases h
            · rw [hst] at ht; cases ht
            · rw [hst] at ht; cases ht
      · -- `BuildPoolReshardPlan` refused: abort with the claim taken.
        injection hstep with h; subst h
        exact habort { s with reg := regClaimed } rfl rfl rfl rfl rfl rfl rfl hexp rfl hidle hreg'
          (fun _ => ⟨hc', ho'⟩) (fun hw0 => ⟨hact0 hw0, Or.inr ⟨hc', ho'⟩⟩) hasrc' (fun _ => ⟨hc', ho'⟩)

  | armDstResult dstUnit outcome =>
    simp only [CoordChainState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hg
    simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, not_or, Decidable.not_not] at hg
    obtain ⟨hst, harming⟩ := hg
    split at hstep
    · cases hstep
    rename_i hg2
    simp only [Bool.or_eq_true, Bool.not_eq_true', not_or] at hg2
    obtain ⟨_, hnrep⟩ := hg2
    split at hstep
    · cases hstep
    rename_i hadmit
    injection hstep with h; subst h
    have harm' := harm harming
    have hbusy_false : outcome = .ok →
        ∀ d ∈ s.dstStates, d.unit = dstUnit → d.prevSessionActive = false := by
      intro hok d hd hu
      simp only [Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true', not_or,
        not_and] at hadmit
      have := hadmit.1 hok
      simp only [Bool.not_eq_true, List.any_eq_false, Bool.and_eq_true, beq_iff_eq,
        not_and] at this
      exact this d hd hu
    refine ⟨hcfg, ?_, hreg, hexp, hasrc, hacl, ?_, ?_,
      (fun h => by rw [harming] at h; cases h),
      (fun h => by rcases h with h | h <;> rw [harming] at h <;> cases h), hnp, ?_⟩
    · rw [map_unit_preserved _ _ (fun d => by split <;> rfl)]
      exact hdst
    · intro d' hd'
      obtain ⟨d, hd, rfl⟩ := List.mem_map.mp hd'
      split
      · rename_i hcond
        simp only [Bool.and_eq_true, beq_iff_eq] at hcond
        intro hprev
        exact absurd hprev (by rw [hbusy_false hcond.2 d hd hcond.1]; decide)
      · exact hlease d hd
    · intro _ d' hd'
      obtain ⟨d, hd, rfl⟩ := List.mem_map.mp hd'
      have hd_arm := harm' d hd
      have hnotok := armOk_false_of_not_reported (Bool.eq_false_iff.mpr hnrep)
      split
      · rename_i hcond
        simp only [Bool.and_eq_true, beq_iff_eq] at hcond
        simp only [armOk_append, hcond.1, hcond.2, beq_self_eq_true, Bool.and_self, Bool.or_true]
      · rename_i hcond
        simp only [Bool.and_eq_true, beq_iff_eq, not_and] at hcond
        simp only [armOk_append, hd_arm]
        by_cases hu : dstUnit = d.unit
        · have hno : outcome ≠ .ok := fun h => hcond hu.symm h
          have : (outcome == .ok) = false := beq_false_of_ne hno
          simp [hu, this]
        · have : (dstUnit == d.unit) = false := beq_false_of_ne hu
          simp [this]
    · rcases hph with ⟨ht, _⟩ | ⟨_, _, hp, _⟩ | ⟨_, hl, _, hz, hc, hrem⟩ | ⟨⟨ht, _⟩ | ht, _⟩
      · rw [hst] at ht; cases ht
      · rw [harming] at hp; cases hp
      · refine Or.inr (Or.inr (Or.inl ⟨hst, hl, Or.inr (Or.inl harming), ?_, hc, hrem⟩))
        intro hw0
        exact ⟨(fun h => by rw [harming] at h; cases h), fun _ => (hz hw0).2 harming⟩
      · rw [hst] at ht; cases ht
      · rw [hst] at ht; cases ht

  | retryBusyArm =>
    simp only [CoordChainState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hg
    simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, not_or, Decidable.not_not] at hg
    obtain ⟨hst, harming⟩ := hg
    split at hstep
    · cases hstep
    injection hstep with h; subst h
    refine ⟨hcfg, hdst, hreg, hexp, hasrc, hacl, hlease, ?_,
      (fun h => by rw [harming] at h; cases h),
      (fun h => by rcases h with h | h <;> rw [harming] at h <;> cases h), hnp, ?_⟩
    · intro _ d hd
      rw [armOk_filter_ok]
      exact harm harming d hd
    · rcases hph with ⟨ht, _⟩ | ⟨_, _, hp, _⟩ | ⟨_, hl, _, hz, hc, hrem⟩ | ⟨⟨ht, _⟩ | ht, _⟩
      · rw [hst] at ht; cases ht
      · rw [harming] at hp; cases hp
      · exact Or.inr (Or.inr (Or.inl ⟨hst, hl, Or.inr (Or.inl harming), hz, hc, hrem⟩))
      · rw [hst] at ht; cases ht
      · rw [hst] at ht; cases ht

  | finishWindowArm =>
    simp only [CoordChainState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hg
    simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, not_or, Decidable.not_not] at hg
    obtain ⟨hst, harming⟩ := hg
    split at hstep
    · cases hstep
    rename_i hg2
    simp only [Bool.or_eq_true, Bool.not_eq_true', not_or] at hg2
    obtain ⟨hallrep, _⟩ := hg2
    simp only [Bool.not_eq_false] at hallrep
    rcases hph with ⟨ht, _⟩ | ⟨_, _, hp, _⟩ | ⟨_, hl, _, hz, hc, hrem⟩ | ⟨⟨ht, _⟩ | ht, _⟩
    · rw [hst] at ht; cases ht
    · rw [harming] at hp; cases hp
    · split at hstep
      · -- Every destination armed: Stage 2.
        rename_i hnofail
        simp only [Bool.not_eq_true'] at hnofail
        injection hstep with h; subst h
        refine ⟨hcfg, hdst, hreg, hexp, hasrc, hacl, hlease, (fun h => by cases h), ?_,
          (fun h => by rcases h with h | h <;> cases h), (fun h => by cases h), ?_⟩
        · intro _ d hd
          rw [harm harming d hd]
          have hmem : d.unit ∈ s.dstUnits := by
            rw [← hdst]; exact List.mem_map.mpr ⟨d, hd, rfl⟩
          have hrep : armReported s.armResults d.unit = true := by
            simp only [allArmReported, List.all_eq_true] at hallrep
            exact hallrep d.unit hmem
          exact armOk_of_reported_no_fail hrep hnofail
        · refine Or.inr (Or.inr (Or.inl ⟨hst, hl, Or.inr (Or.inr rfl), ?_, hc, hrem⟩))
          intro _
          exact ⟨(fun h => by cases h), (fun h => by cases h)⟩
      · -- A destination refused: `return arm_status[i]`.
        injection hstep with h; subst h
        unfold CoordChainState.abortWindow
        simp only [Nat.le_refl, decide_true, Bool.true_and, beq_iff_eq]
        split
        · rename_i hw0
          have hact : s.activeSenders = [] := (hz hw0).2 harming
          have hcl := abandonIfClaimed_clears_single_owner s.reg s.allSrcUnits s.claimOwner
            (Or.inl hc)
          refine inv_syncSenderExposure (Or.inl hact) ?_
          refine ⟨hcfg, hdst, abandonIfClaimed_inv _ _ hreg, hexp, ?_, ?_, hlease,
            (fun h => by cases h), (fun h => by cases h), (fun h => by rcases h with h | h <;> cases h),
            (fun h => by cases h), ?_⟩
          · intro v hv; rw [hact] at hv; cases hv
          · intro h; exact absurd hact h
          · exact Or.inr (Or.inr (Or.inr ⟨Or.inr rfl, Or.inr hcl⟩))
        · refine inv_syncSenderExposure (Or.inr (by simp [hc.1])) ?_
          refine ⟨hcfg, hdst, hreg, hexp, hasrc, hacl, hlease,
            (fun h => by cases h), (fun h => by cases h), (fun h => by rcases h with h | h <;> cases h),
            (fun h => by cases h), ?_⟩
          exact Or.inr (Or.inr (Or.inr ⟨Or.inr rfl, Or.inl hc⟩))
    · rw [hst] at ht; cases ht
    · rw [hst] at ht; cases ht

  | sendSrcResult srcUnit ok =>
    simp only [CoordChainState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hg
    simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, not_or, Decidable.not_not] at hg
    obtain ⟨hst, hdispatching⟩ := hg
    split at hstep
    · cases hstep
    rename_i hg2
    simp only [Bool.or_eq_true, Bool.not_eq_true', not_or] at hg2
    obtain ⟨hmem, _⟩ := hg2
    simp only [Bool.not_eq_false] at hmem
    injection hstep with h; subst h
    rcases hph with ⟨ht, _⟩ | ⟨_, _, hp, _⟩ | ⟨_, hl, _, hz, hc, hrem⟩ | ⟨⟨ht, _⟩ | ht, _⟩
    · rw [hst] at ht; cases ht
    · rw [hdispatching] at hp; cases hp
    · have hsrc_mem : srcUnit ∈ s.allSrcUnits ∧ srcUnit ∉ s.reg.completedUnits := by
        have hwin : s.winSrcUnits.getD s.winIdx [] ∈ s.winSrcUnits := getD_mem_of_lt hl
        have hin : srcUnit ∈ s.winSrcUnits.getD s.winIdx [] := by
          unfold CoordChainState.curWindowSrcs at hmem
          exact List.contains_iff_mem.mp hmem
        exact ⟨(hcfg.winSub _ hwin).2 srcUnit hin, hrem s.winIdx (Nat.le_refl _) srcUnit hin⟩
      refine inv_syncSenderExposure (Or.inr (by simp [hc.1])) ?_
      refine ⟨hcfg, hdst, hreg, hexp, ?_, fun _ => hc, hlease,
        (fun h => by rw [hdispatching] at h; cases h), fun _ => hdisp hdispatching,
        (fun h => by rcases h with h | h <;> rw [hdispatching] at h <;> cases h),
        (fun h => by rw [hdispatching] at h; cases h), ?_⟩
      · intro u hu
        split at hu
        · rcases mem_insertNodup.mp hu with rfl | hu
          · exact hsrc_mem
          · exact hasrc u hu
        · exact hasrc u hu
      · refine Or.inr (Or.inr (Or.inl ⟨hst, hl, Or.inr (Or.inr hdispatching), ?_, hc, hrem⟩))
        intro _
        exact ⟨(fun h => by rw [hdispatching] at h; cases h),
          (fun h => by rw [hdispatching] at h; cases h)⟩
    · rw [hst] at ht; cases ht
    · rw [hst] at ht; cases ht

  | finishWindowSend =>
    simp only [CoordChainState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hg
    simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, not_or, Decidable.not_not] at hg
    obtain ⟨hst, hdispatching⟩ := hg
    split at hstep
    · cases hstep
    rcases hph with ⟨ht, _⟩ | ⟨_, _, hp, _⟩ | ⟨_, hl, _, hz, hc, hrem⟩ | ⟨⟨ht, _⟩ | ht, _⟩
    · rw [hst] at ht; cases ht
    · rw [hdispatching] at hp; cases hp
    · have hsome : s.reg.claimedUnits.isSome = true := by rw [hc.1]; rfl
      split at hstep
      · -- A sender RPC failed: `return status;` with the claim in place.
        injection hstep with h; subst h
        unfold CoordChainState.abortWindow
        have h21 : ((2 : Nat) <= 1) = false := by decide
        simp only [h21, Bool.false_eq_true]
        refine inv_syncSenderExposure (Or.inr hsome) ?_
        refine ⟨hcfg, hdst, hreg, hexp, hasrc, hacl, hlease,
          (fun h => by cases h), (fun h => by cases h), (fun h => by rcases h with h | h <;> cases h),
          (fun h => by cases h), ?_⟩
        exact Or.inr (Or.inr (Or.inr ⟨Or.inr rfl, Or.inl hc⟩))
      · have hdst' : (s.dstStates.map fun d =>
            { d with prevSessionActive := d.prevSessionActive || d.curWinArmed,
                     curWinArmed := false }).map (·.unit) = s.dstUnits := by
          have hmap := map_unit_preserved s.dstStates
            (fun d => { d with prevSessionActive := d.prevSessionActive || d.curWinArmed, curWinArmed := false })
            (fun _ => rfl)
          rw [hmap]
          exact hdst
        have hlease' : ∀ d ∈ (s.dstStates.map fun d =>
            { d with prevSessionActive := d.prevSessionActive || d.curWinArmed,
                     curWinArmed := false }), d.prevSessionActive = true → d.curWinArmed = false := by
          intro d' hd'
          obtain ⟨d, _, rfl⟩ := List.mem_map.mp hd'
          intro _; rfl
        have hrest' : ∀ d ∈ (s.dstStates.map fun d =>
            { d with prevSessionActive := d.prevSessionActive || d.curWinArmed,
                     curWinArmed := false }), d.curWinArmed = false := by
          intro d' hd'
          obtain ⟨d, _, rfl⟩ := List.mem_map.mp hd'
          rfl
        split at hstep
        · -- Another window follows on `StartChain`.
          rename_i hmore
          injection hstep with h; subst h
          refine ⟨hcfg, hdst', hreg, hexp, hasrc, fun h => hacl h, hlease',
            (fun h => by cases h), (fun h => by cases h), fun _ => hrest', (fun h => by cases h), ?_⟩
          refine Or.inr (Or.inr (Or.inl ⟨hst, hmore, Or.inl rfl, (fun h => by cases h), hc, ?_⟩))
          intro j hj
          exact hrem j (Nat.le_of_succ_le hj)
        · -- Last window: `transfer_status_ = kCompleted`.
          rename_i hlast
          injection hstep with h; subst h
          refine ⟨hcfg, hdst', hreg, hexp, hasrc, fun h => hacl h, hlease',
            (fun h => by cases h), (fun h => by cases h), fun _ => hrest', (fun h => by cases h), ?_⟩
          refine Or.inr (Or.inr (Or.inr ⟨Or.inl ⟨rfl, ?_, rfl⟩, Or.inl hc⟩))
          show s.winIdx + 1 = s.winSrcUnits.length
          omega
    · rw [hst] at ht; cases ht
    · rw [hst] at ht; cases ht

  | settleDispatchedRecv dstUnit =>
    simp only [CoordChainState.step] at hstep
    split at hstep
    · cases hstep
    injection hstep with h; subst h
    have hunit : ∀ d : ChainDstState,
        (if d.unit == dstUnit then { d with prevSessionActive := false } else d).unit = d.unit := by
      intro d; split <;> rfl
    have hcur : ∀ d : ChainDstState,
        (if d.unit == dstUnit then { d with prevSessionActive := false } else d).curWinArmed =
          d.curWinArmed := by
      intro d; split <;> rfl
    refine ⟨hcfg, by rw [map_unit_preserved _ _ hunit]; exact hdst, hreg, hexp, hasrc, hacl, ?_,
      ?_, ?_, ?_, hnp, ?_⟩
    · intro d' hd'
      obtain ⟨d, hd, rfl⟩ := List.mem_map.mp hd'
      split
      · intro h; cases h
      · exact hlease d hd
    · intro hp d' hd'
      obtain ⟨d, hd, rfl⟩ := List.mem_map.mp hd'
      rw [hcur, hunit]
      exact harm hp d hd
    · intro hp d' hd'
      obtain ⟨d, hd, rfl⟩ := List.mem_map.mp hd'
      rw [hcur]
      exact hdisp hp d hd
    · intro hp d' hd'
      obtain ⟨d, hd, rfl⟩ := List.mem_map.mp hd'
      rw [hcur]
      exact hrest hp d hd
    · rcases hph with ⟨h1, h2, h3, h4, h5⟩ | ⟨h1, h2, h3, h4, h5⟩ | ⟨h1, h2, h3, h4, h5, h6⟩ | ⟨h1, h2⟩
      · exact Or.inl ⟨h1, h2, h3, h4, h5⟩
      · exact Or.inr (Or.inl ⟨h1, h2, h3, h4, h5⟩)
      · exact Or.inr (Or.inr (Or.inl ⟨h1, h2, h3, h4, h5, h6⟩))
      · exact Or.inr (Or.inr (Or.inr ⟨h1, h2⟩))

  | senderVoteComplete srcUnit =>
    simp only [CoordChainState.step] at hstep
    split at hstep
    · cases hstep
    rename_i hg
    simp only [Bool.or_eq_true, Bool.not_eq_true', not_or] at hg
    obtain ⟨hactive, hnorem⟩ := hg
    simp only [Bool.not_eq_false] at hactive
    have hactive' : srcUnit ∈ s.activeSenders := List.contains_iff_mem.mp hactive
    have hne : s.activeSenders ≠ [] := by
      intro h; rw [h] at hactive'; cases hactive'
    have hc := hacl hne
    obtain ⟨hsrc_in, hsrc_unvoted⟩ := hasrc srcUnit hactive'
    rw [complete_claimed hc.1 hc.2 hsrc_in] at hstep
    simp only [Option.map_some, Option.some.injEq] at hstep
    subst hstep
    -- The remaining active senders after this vote.
    have hfilter_mem : ∀ v, v ∈ s.activeSenders.filter (· != srcUnit) ↔
        v ∈ s.activeSenders ∧ v ≠ srcUnit := by
      intro v
      simp [List.mem_filter]
    split
    · -- Every claimed rank has voted: `RetireLocked`.
      rename_i hall
      have hempty : s.activeSenders.filter (· != srcUnit) = [] := by
        apply List.eq_nil_iff_forall_not_mem.mpr
        intro v hv
        obtain ⟨hv_act, hv_ne⟩ := (hfilter_mem v).mp hv
        obtain ⟨hv_in, hv_unvoted⟩ := hasrc v hv_act
        simp only [allVoted, List.all_eq_true] at hall
        have := hall v hv_in
        rcases mem_insertNodup.mp (List.contains_iff_mem.mp this) with h | h
        · exact hv_ne h
        · exact hv_unvoted h
      rw [hempty]
      refine inv_syncSenderExposure (Or.inl rfl) ?_
      refine ⟨hcfg, hdst, Registry.retireLocked_inv s.reg, hexp, (fun _ h => by cases h),
        fun h => absurd rfl h, hlease, harm, hdisp, hrest, hnp, ?_⟩
      rcases hph with ⟨_, _, _, hact, _⟩ | ⟨_, _, _, hact, _⟩ | ⟨hst, hl, hrun, _, _, hrem⟩ |
          ⟨hterm, _⟩
      · exact absurd hact hne
      · exact absurd hact hne
      · -- In progress, the running window still has an unvoted rank.
        exfalso
        have hwin : s.winSrcUnits.getD s.winIdx [] ∈ s.winSrcUnits := getD_mem_of_lt hl
        obtain ⟨hwne, hwsub⟩ := hcfg.winSub _ hwin
        obtain ⟨w, hw⟩ := List.exists_mem_of_ne_nil _ hwne
        have hw_unvoted := hrem s.winIdx (Nat.le_refl _) w hw
        have hw_ne : w ≠ srcUnit := by
          intro h; subst h
          exact not_in_remaining hst (Bool.eq_false_iff.mpr hnorem) s.winIdx (Nat.le_refl _) hw
        simp only [allVoted, List.all_eq_true] at hall
        have := hall w (hwsub w hw)
        rcases mem_insertNodup.mp (List.contains_iff_mem.mp this) with h | h
        · exact hw_ne h
        · exact hw_unvoted h
      · exact Or.inr (Or.inr (Or.inr ⟨hterm, Or.inr ⟨rfl, rfl⟩⟩))
    · -- The claim stays; `srcUnit` is recorded.
      rename_i hnall
      refine inv_syncSenderExposure (Or.inr (by simp [hc.1])) ?_
      have hasrc' : ∀ v ∈ s.activeSenders.filter (· != srcUnit),
          v ∈ s.allSrcUnits ∧ v ∉ insertNodup srcUnit s.reg.completedUnits := by
        intro v hv
        obtain ⟨hv_act, hv_ne⟩ := (hfilter_mem v).mp hv
        obtain ⟨hv_in, hv_unvoted⟩ := hasrc v hv_act
        refine ⟨hv_in, ?_⟩
        intro h
        rcases mem_insertNodup.mp h with h | h
        · exact hv_ne h
        · exact hv_unvoted h
      refine ⟨hcfg, hdst, ?_, hexp, hasrc', fun _ => ⟨hc.1, hc.2⟩, hlease, harm, hdisp, hrest, hnp, ?_⟩
      · have := Registry.step_preserves_inv hreg (complete_claimed hc.1 hc.2 hsrc_in)
        simpa [hnall] using this
      · rcases hph with ⟨_, _, _, hact, _⟩ | ⟨_, _, _, hact, _⟩ | ⟨hst, hl, hrun, hz, _, hrem⟩ |
            ⟨hterm, _⟩
        · exact absurd hact hne
        · exact absurd hact hne
        · refine Or.inr (Or.inr (Or.inl ⟨hst, hl, hrun, ?_, ⟨hc.1, hc.2⟩, ?_⟩))
          · intro hw0
            obtain ⟨h1, h2⟩ := hz hw0
            refine ⟨h1, fun hp => ?_⟩
            exact absurd hne (by rw [h2 hp]; exact fun h => h rfl)
          · intro j hj w hw hmem
            have hnot := not_in_remaining hst (Bool.eq_false_iff.mpr hnorem) j hj
            rcases mem_insertNodup.mp hmem with h | h
            · subst h; exact hnot hw
            · exact hrem j hj w hw h
        · exact Or.inr (Or.inr (Or.inr ⟨hterm, Or.inl ⟨hc.1, hc.2⟩⟩))

  | cancelIfUnclaimed =>
    simp only [CoordChainState.step] at hstep
    cases hr : RegGen.step s.reg .cancelIfUnclaimed with
    | none => rw [hr] at hstep; cases hstep
    | some reg' =>
      rw [hr] at hstep
      simp only [Option.map_some, Option.some.injEq] at hstep
      subst hstep
      have hreg' := Registry.step_preserves_inv hreg hr
      rcases cancelIfUnclaimed_shape hr with rfl | ⟨hnone, hc', ho', hcomp'⟩
      · refine inv_syncSenderExposure ?_ ?_
        · by_cases h : s.activeSenders = []
          · exact Or.inl h
          · exact Or.inr (by simp [(hacl h).1])
        · exact ⟨hcfg, hdst, hreg', hexp, hasrc, hacl, hlease, harm, hdisp, hrest, hnp, hph⟩
      · -- Unclaimed: no sender can be active.
        have hact : s.activeSenders = [] := by
          by_cases h : s.activeSenders = []
          · exact h
          · exfalso
            have := (hacl h).1
            rw [hnone] at this; cases this
        refine inv_syncSenderExposure (Or.inl hact) ?_
        refine ⟨hcfg, hdst, hreg', hexp, (fun _ h => by rw [hact] at h; cases h),
          fun h => absurd hact h, hlease, harm, hdisp, hrest, hnp, ?_⟩
        rcases hph with ⟨h1, h2, h3, h4, _⟩ | ⟨h1, h2, h3, h4, _⟩ | ⟨_, _, _, _, hc, _⟩ | ⟨hterm, _⟩
        · exact Or.inl ⟨h1, h2, h3, h4, hc', ho', hcomp'⟩
        · exact Or.inr (Or.inl ⟨h1, h2, h3, h4, hc', ho', hcomp'⟩)
        · exfalso; have := hc.1; rw [hnone] at this; cases this
        · exact Or.inr (Or.inr (Or.inr ⟨hterm, Or.inr ⟨hc', ho'⟩⟩))

/-- **Main coordinator theorem (`reachable_coordChain_safe`)**: for every
well-formed chain topology, every reachable state of `CoordChainState.step`
satisfies `CoordChainSafe`. -/
theorem reachable_coordChain_safe {allSrcs : List Nat} {winSrcs : List (List Nat)}
    {dsts : List Nat} {owner maxAtt : Nat} (hcfg : ValidChainCfg allSrcs winSrcs)
    {s : CoordChainState}
    (hr : (CoordChainState.sys allSrcs winSrcs dsts owner maxAtt).Reachable s) :
    CoordChainSafe s :=
  ((CoordChainState.sys allSrcs winSrcs dsts owner maxAtt).reachable_induction
    (init_coordChainInv hcfg)
    (fun _ _ _ hinv hstep => step_preserves_coordChainInv hinv hstep) hr).toSafe

end TpuSyncVerify.Transfer.Reshard.SubPlanChain
