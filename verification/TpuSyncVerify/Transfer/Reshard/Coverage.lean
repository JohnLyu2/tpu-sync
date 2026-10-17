/-
  TpuSyncVerify/Transfer/Reshard/Coverage.lean

  Stage 3a of `docs/transfer/reshard.md`: horizontal data-plane refinement of
  `Reshard/Pipeline.lean` for sub-block byte-interval coverage and multi-sender
  push-stream accounting:
    * `tpu_sync/kv_cache/reshard_receive_session.cc` (`ValidatePlan`,
      `ValidateReceiverCoverage`, lines 67–349)
    * `tpu_sync/kv_cache/reshard/pool_reshard_planner.cc` (`ValidateSpanCoverage`,
      `EmitSpanSchedule` `expected_pushes` computation, and
      `DefaultTransferStreams`, lines 315–572, 576–594, 908–922, 1117–1153)
    * `tpu_sync/kv_cache/reshard_send_session.cc` (`ExecutePush` / `StartPoolPush`
      per-peer `(src_block_id, dst_block_id)` deduplication, lines 204–225,
      293–348)
    * `tpu_sync/core/pool_reshard_send_slots.cc` (`CountPoolReshardSendSlots`,
      lines 27–51)
    * `tpu_sync/transport/block_transport.cc` (`AsyncPush` stream clamping
      `P = min(parallelism, num_blocks)` and `HandleIncomingPush` /
      `CompleteIncomingPush` plan-declared progress counter, lines 640–793,
      1010–1046)

  Citations in this file are checked against tpu-sync `0ac16d1`.

  What this module proves:
  1. **Multi-sender stream count conservation (`stream_count_matches`,
     `senderStreams_pos_iff`).** Each sender `s` deduplicates its scheduled
     `(src_block_id, dst_block_id)` pairs for a pool group and opens
     `min(parallelism, |pairs_s|)` TCP push streams (`block_transport.cc:1020-1025`,
     `reshard_send_session.cc:293-341`). `ValidateReceiverCoverage`
     (`reshard_receive_session.cc:314-324`) checks that the receiver's
     `expected_pushes` equals `∑_s min(parallelism, |pairs_s|)`, matching the
     planner (`pool_reshard_planner.cc:1134-1142`).
  2. **Exact sub-block byte reconstruction under out-of-order stream arrival
     (`checkContiguous_covers`, `checkContiguous_head_disjoint`,
     `partition_reconstructs_block`, `partition_reconstructs_perm`).**
     `ValidateReceiverCoverage` sorts the logical live-byte intervals
     `[start_bytes, end_bytes)` targeting a destination block and checks that
     they partition `[0, extent)` without gaps or overlaps
     (`reshard_receive_session.cc:325-346`). We prove that any interval list
     accepted by this check is pairwise disjoint and covers every byte
     `b < extent`, so landing the intervals in *any* network arrival order
     reconstructs `good extent` (`[kv 0, …, kv (extent - 1)]`).
  3. **Refinement coupling (`CoveragePipeline.step_pipe`,
     `CoveragePipeline.reachable_safe`).** `CoveragePipeline` refines
     `Reshard.Pipeline` by replacing each pool's scalar stream counter with a
     queue of sub-block intervals and a byte-addressed staging buffer. Every
     `CoveragePipeline` step projects to a `Pipeline.step`, lifting all Stage 2
     pipeline invariants together with byte-level destination reconstruction.
-/
import TpuSyncVerify.Transfer.Reshard.Pipeline

namespace TpuSyncVerify.Transfer.Reshard.Coverage

open TpuSyncVerify
open TpuSyncVerify.Transfer
open TpuSyncVerify.Transfer.Reshard
open TpuSyncVerify.Transfer.Reshard.Pipeline

/-! ## Part 1: Multi-sender `(src_block, dst_block)` pair deduplication and stream counts -/

/-- A logical sub-block range `[startByte, endByte)` inside a destination block's
live byte extent (`reshard_receive_session.cc:289-304`). -/
structure Interval where
  startByte : Nat
  endByte : Nat
  deriving Repr, DecidableEq

/-- One entry of a pool group's push schedule (`reshard_receive_session.cc:266-308`,
`reshard_send_session.cc:295-304`), attributed to `sender` (`source_rank`). -/
structure ScheduleEntry where
  sender : Nat
  srcBlock : Nat
  dstBlock : Nat
  interval : Interval
  deriving Repr, DecidableEq

/-- Distinct `(srcBlock, dstBlock)` pairs scheduled for `sender`
(`reshard_send_session.cc:293-304`, `reshard_receive_session.cc:305-307`). -/
def senderPairs (entries : List ScheduleEntry) (sender : Nat) : List (Nat × Nat) :=
  ((entries.filter fun e => e.sender == sender).map fun e => (e.srcBlock, e.dstBlock)).eraseDups

/-- Number of TCP push streams opened by `sender` under `parallelism`:
`BlockTransport::AsyncPush` clamps `P = min(parallelism, num_blocks)`
(`block_transport.cc:1010-1025`), and a sender with zero pairs opens no streams
(`reshard_send_session.cc:217-224`). -/
def senderStreams (parallelism : Nat) (entries : List ScheduleEntry) (sender : Nat) : Nat :=
  Nat.min parallelism (senderPairs entries sender).length

/-- Total push streams recomputed across `senders` (`pool_reshard_planner.cc:1134-1142`,
`reshard_receive_session.cc:314-318`). -/
def recomputedExpectedPushes (parallelism : Nat) (senders : List Nat)
    (entries : List ScheduleEntry) : Nat :=
  match senders with
  | [] => 0
  | s :: ss => senderStreams parallelism entries s + recomputedExpectedPushes parallelism ss entries

/-- Receiver push-count validation (`reshard_receive_session.cc:188-192, 314-324`
and `pool_reshard_planner.cc:1144-1152`). -/
def validateExpectedPushes (parallelism : Nat) (senders : List Nat)
    (entries : List ScheduleEntry) (expectedPushes : Nat) : Bool :=
  decide (0 < parallelism) &&
  decide (0 < expectedPushes) &&
  decide (recomputedExpectedPushes parallelism senders entries = expectedPushes)

theorem senderStreams_eq_zero_of_no_pairs (parallelism : Nat) (entries : List ScheduleEntry)
    (sender : Nat) (h : senderPairs entries sender = []) :
    senderStreams parallelism entries sender = 0 := by
  simp [senderStreams, h]

theorem senderStreams_pos_iff {parallelism : Nat} {entries : List ScheduleEntry} {sender : Nat} :
    0 < senderStreams parallelism entries sender ↔
      0 < parallelism ∧ 0 < (senderPairs entries sender).length := by
  simp [senderStreams, Nat.lt_min]

theorem senderStreams_le_parallelism (parallelism : Nat) (entries : List ScheduleEntry)
    (sender : Nat) :
    senderStreams parallelism entries sender ≤ parallelism :=
  Nat.min_le_left _ _

theorem senderStreams_le_pairs (parallelism : Nat) (entries : List ScheduleEntry)
    (sender : Nat) :
    senderStreams parallelism entries sender ≤ (senderPairs entries sender).length :=
  Nat.min_le_right _ _

/-- When `validateExpectedPushes` succeeds, the sum of streams emitted by all
senders in `senders` equals the receiver's `expectedPushes`, and `0 < expectedPushes`
(`reshard_receive_session.cc:319-324`, `pool_reshard_planner.cc:1134-1152`). -/
theorem stream_count_matches {parallelism : Nat} {senders : List Nat}
    {entries : List ScheduleEntry} {expectedPushes : Nat}
    (h : validateExpectedPushes parallelism senders entries expectedPushes = true) :
    0 < parallelism ∧ 0 < expectedPushes ∧
      recomputedExpectedPushes parallelism senders entries = expectedPushes := by
  simp only [validateExpectedPushes, Bool.and_eq_true, decide_eq_true_eq] at h
  exact ⟨h.1.1, h.1.2, h.2⟩

/-! ## Part 2: Sub-block interval partition and byte-level block reconstruction -/

/-- Contiguous interval scan from `ValidateReceiverCoverage`
(`reshard_receive_session.cc:329-345`): starting at `coveredUntil`, each
interval `[startByte, endByte)` must start at `coveredUntil` (`start_bytes ==
covered_until`, rejecting both overlaps `start_bytes < covered_until` and gaps
`start_bytes > covered_until`) and be non-empty (`startByte < endByte`, from
`size_bytes > 0` in `PhysicalLiveRangeToLogical`). Returns `some coveredUntil`
after scanning all intervals. -/
def checkContiguousIntervals (coveredUntil : Nat) : List Interval → Option Nat
  | [] => some coveredUntil
  | iv :: rest =>
    if iv.startByte = coveredUntil ∧ iv.startByte < iv.endByte then
      checkContiguousIntervals iv.endByte rest
    else
      none

/-- Full block coverage check (`reshard_receive_session.cc:246-252, 329-346`):
`0 < extent` and the sorted intervals partition `[0, extent)`. -/
def validBlockCoverage (extent : Nat) (intervals : List Interval) : Bool :=
  decide (0 < extent) && decide (checkContiguousIntervals 0 intervals = some extent)

/-- Write one logical byte interval `[iv.startByte, iv.endByte)` into a
destination block byte buffer (`block_transport.cc:603-606`). Byte `b` in range
receives `.kv b`. -/
def writeInterval (iv : Interval) (buf : List Cell) : List Cell :=
  buf.mapIdx fun b c => if iv.startByte ≤ b ∧ b < iv.endByte then .kv b else c

/-- Write a sequence of intervals into `buf` in arrival order. -/
def writeIntervals : List Interval → List Cell → List Cell
  | [], buf => buf
  | iv :: rest, buf => writeIntervals rest (writeInterval iv buf)

@[simp] theorem length_writeInterval (iv : Interval) (buf : List Cell) :
    (writeInterval iv buf).length = buf.length := by
  simp [writeInterval]

@[simp] theorem length_writeIntervals (ivs : List Interval) (buf : List Cell) :
    (writeIntervals ivs buf).length = buf.length := by
  induction ivs generalizing buf with
  | nil => rfl
  | cons iv rest ih => simp [writeIntervals, ih]

theorem getElem?_writeInterval {iv : Interval} {buf : List Cell} {b : Nat}
    (hb : b < buf.length) :
    (writeInterval iv buf)[b]? =
      if iv.startByte ≤ b ∧ b < iv.endByte then some (.kv b) else buf[b]? := by
  simp only [writeInterval, List.getElem?_mapIdx, List.getElem?_eq_getElem hb, Option.map_some]
  split <;> rfl

/-- Writing two intervals into a block buffer commutes, so network arrival order
across senders does not affect the resulting staging bytes. -/
theorem writeInterval_comm (iv₁ iv₂ : Interval) (buf : List Cell) :
    writeInterval iv₁ (writeInterval iv₂ buf) = writeInterval iv₂ (writeInterval iv₁ buf) := by
  apply List.ext_getElem?
  intro b
  by_cases hb : b < buf.length
  · have hb₁ : b < (writeInterval iv₂ buf).length := by simp [hb]
    have hb₂ : b < (writeInterval iv₁ buf).length := by simp [hb]
    rw [getElem?_writeInterval hb₁, getElem?_writeInterval hb,
        getElem?_writeInterval hb₂, getElem?_writeInterval hb]
    by_cases h1 : iv₁.startByte ≤ b ∧ b < iv₁.endByte <;>
      by_cases h2 : iv₂.startByte ≤ b ∧ b < iv₂.endByte <;>
      simp [h1, h2]
  · have h₁ : (writeInterval iv₁ (writeInterval iv₂ buf))[b]? = none :=
      List.getElem?_eq_none (by simp; omega)
    have h₂ : (writeInterval iv₂ (writeInterval iv₁ buf))[b]? = none :=
      List.getElem?_eq_none (by simp; omega)
    rw [h₁, h₂]

theorem getElem?_writeIntervals {ivs : List Interval} {buf : List Cell} {b : Nat}
    (hb : b < buf.length) :
    (writeIntervals ivs buf)[b]? =
      if ivs.any (fun iv => decide (iv.startByte ≤ b ∧ b < iv.endByte)) then
        some (.kv b)
      else
        buf[b]? := by
  induction ivs generalizing buf with
  | nil => simp [writeIntervals]
  | cons iv rest ih =>
    simp only [writeIntervals, List.any_cons]
    rw [ih (by simp [hb]), getElem?_writeInterval hb]
    by_cases h1 : iv.startByte ≤ b ∧ b < iv.endByte <;> simp [h1]

theorem checkContiguous_le {cur ext : Nat} {ivs : List Interval}
    (h : checkContiguousIntervals cur ivs = some ext) :
    cur ≤ ext := by
  induction ivs generalizing cur with
  | nil =>
    simp only [checkContiguousIntervals, Option.some.injEq] at h
    omega
  | cons iv rest ih =>
    simp only [checkContiguousIntervals] at h
    split at h <;> try cases h
    rename_i hcond
    have := ih h
    omega

/-- Key characterization of `checkContiguousIntervals`: if the scan from `cur`
succeeds with `some ext`, then the intervals in `ivs` cover `[cur, ext)`
exactly. -/
theorem checkContiguous_covers {cur ext : Nat} {ivs : List Interval}
    (h : checkContiguousIntervals cur ivs = some ext) (b : Nat) :
    ivs.any (fun iv => decide (iv.startByte ≤ b ∧ b < iv.endByte)) = true ↔
      cur ≤ b ∧ b < ext := by
  induction ivs generalizing cur with
  | nil =>
    simp only [checkContiguousIntervals, Option.some.injEq] at h
    subst h; simp
  | cons iv rest ih =>
    simp only [checkContiguousIntervals] at h
    split at h <;> try cases h
    rename_i hcond
    obtain ⟨hstart, hlt⟩ := hcond
    have hle := checkContiguous_le h
    simp only [List.any_cons, Bool.or_eq_true, decide_eq_true_eq, ih h]
    omega

/-- Any two intervals in a list accepted by `checkContiguousIntervals` are
disjoint: the head interval lies in `[cur, iv.endByte)` while every subsequent
interval lies in `[iv.endByte, ext)`. -/
theorem checkContiguous_head_disjoint {cur ext : Nat} {iv : Interval} {rest : List Interval}
    (h : checkContiguousIntervals cur (iv :: rest) = some ext)
    {iv' : Interval} (hmem : iv' ∈ rest) {b : Nat}
    (hb₁ : iv.startByte ≤ b ∧ b < iv.endByte)
    (hb₂ : iv'.startByte ≤ b ∧ b < iv'.endByte) : False := by
  simp only [checkContiguousIntervals] at h
  split at h <;> try cases h
  rename_i hcond
  have hany : rest.any (fun x => decide (x.startByte ≤ b ∧ b < x.endByte)) = true :=
    List.any_eq_true.mpr ⟨iv', hmem, decide_eq_true_eq.mpr hb₂⟩
  have ⟨hge, _⟩ := (checkContiguous_covers h b).mp hany
  omega

/-- Main block reconstruction theorem: if `validBlockCoverage extent ivs = true`
and `ivs'` is any arrival order containing the same intervals as `ivs`, then
writing `ivs'` into a blank buffer of length `extent` produces `good extent`
(`[kv 0, kv 1, …, kv (extent - 1)]`). -/
theorem partition_reconstructs_perm {extent : Nat} {ivs ivs' : List Interval}
    (hvalid : validBlockCoverage extent ivs = true)
    (hperm : ∀ iv, iv ∈ ivs' ↔ iv ∈ ivs) :
    writeIntervals ivs' (List.replicate extent .blank) = good extent := by
  simp only [validBlockCoverage, Bool.and_eq_true, decide_eq_true_eq] at hvalid
  obtain ⟨_, hcontig⟩ := hvalid
  apply eq_good_of_getElem?
  · simp
  · intro b hb
    have hlen : b < (List.replicate extent Cell.blank).length := by simp [hb]
    rw [getElem?_writeIntervals hlen]
    have hany_iff : ivs'.any (fun iv => decide (iv.startByte ≤ b ∧ b < iv.endByte)) = true ↔
        ivs.any (fun iv => decide (iv.startByte ≤ b ∧ b < iv.endByte)) = true := by
      simp only [List.any_eq_true, hperm]
    have hcov : ivs.any (fun iv => decide (iv.startByte ≤ b ∧ b < iv.endByte)) = true :=
      (checkContiguous_covers hcontig b).mpr ⟨Nat.zero_le b, hb⟩
    rw [hany_iff.mpr hcov]
    simp

/-- Special case when intervals arrive in their canonical sorted order. -/
theorem partition_reconstructs_block {extent : Nat} {ivs : List Interval}
    (hvalid : validBlockCoverage extent ivs = true) :
    writeIntervals ivs (List.replicate extent .blank) = good extent :=
  partition_reconstructs_perm hvalid (fun _ => Iff.rfl)

/-! ## Part 3: Refinement coupling (`CoveragePipeline.step_pipe`) over `Reshard.Pipeline` -/

/-- A pool's byte-coverage state in `CoveragePipeline`:
* `extent` is the destination byte extent for the pool;
* `planIntervals` is the validated sorted interval list of length `peerCounts[p]`;
* `landedIntervals` is the prefix/subset of intervals landed so far;
* `byteStaging` is the receiver's byte-level host staging buffer for this pool. -/
structure PoolCoverage where
  extent : Nat
  planIntervals : List Interval
  landedIntervals : List Interval := []
  byteStaging : List Cell
  deriving Repr, DecidableEq

/-- `CoveragePipeline` refines `Reshard.Pipeline` by tracking sub-block byte
intervals and byte-level destination staging alongside the abstract pipeline
state `pipe`. -/
structure CoveragePipeline where
  pipe : Pipeline
  pools : List PoolCoverage
  deriving Repr, DecidableEq

namespace CoveragePipeline

def validSchedule (ranks : List Nat) (specs : List (Nat × List Interval)) : Bool :=
  let peerCounts := specs.map fun (_, ivs) => ivs.length
  validConfig ranks peerCounts &&
  specs.all fun (ext, ivs) => validBlockCoverage ext ivs

def init (ranks : List Nat) (specs : List (Nat × List Interval)) : CoveragePipeline :=
  let peerCounts := specs.map fun (_, ivs) => ivs.length
  { pipe := Pipeline.init ranks peerCounts
    pools := specs.map fun (ext, ivs) =>
      { extent := ext
        planIntervals := ivs
        landedIntervals := []
        byteStaging := List.replicate ext .blank } }

def step (s : CoveragePipeline) (e : Ev) : Option CoveragePipeline :=
  match e with
  | .landStream p =>
    match s.pipe.landStream p, s.pools[p]? with
    | some pipe', some pc =>
      let k := pc.landedIntervals.length
      match pc.planIntervals[k]? with
      | some iv =>
        let pc' : PoolCoverage :=
          { pc with landedIntervals := pc.landedIntervals ++ [iv]
                    byteStaging := writeInterval iv pc.byteStaging }
        some { pipe := pipe', pools := s.pools.set p pc' }
      | none => none
    | _, _ => none
  | .reseatDstStaging =>
    (s.pipe.reseatDstStaging).map fun pipe' =>
      { pipe := pipe'
        pools := s.pools.map fun pc =>
          { pc with byteStaging := List.replicate pc.extent .junk } }
  | e =>
    (Pipeline.step s.pipe e).map fun pipe' => { s with pipe := pipe' }

def sys (ranks : List Nat) (specs : List (Nat × List Interval)) :
    System CoveragePipeline Ev :=
  ⟨init ranks specs, step⟩

/-- Simulation theorem (`step_pipe`): every `CoveragePipeline` transition
projects directly to a `Reshard.Pipeline` transition on `s.pipe`. -/
theorem step_pipe {s s' : CoveragePipeline} {e : Ev}
    (hs : step s e = some s') :
    Pipeline.step s.pipe e = some s'.pipe := by
  cases e with
  | landStream p =>
    simp only [step] at hs
    split at hs <;> try cases hs
    rename_i pipe' pc hland _
    split at hs <;> simp at hs; subst hs
    exact hland
  | reseatDstStaging =>
    simp only [step, Option.map_eq_some_iff] at hs
    obtain ⟨pipe', hres, rfl⟩ := hs
    exact hres
  | armRecv | send _ | recv _ | reclaim | reseatSrcStaging =>
    simp only [step, Option.map_eq_some_iff] at hs
    obtain ⟨pipe', hstep, rfl⟩ := hs
    exact hstep

theorem reachable_pipe {ranks : List Nat} {specs : List (Nat × List Interval)}
    {s : CoveragePipeline}
    (h : (sys ranks specs).Reachable s) :
    (Pipeline.sys ranks (specs.map fun (_, ivs) => ivs.length)).Reachable s.pipe := by
  induction h with
  | init => exact .init
  | step _ hs ih => exact .step ih (step_pipe hs)

/-- Every state reachable in `CoveragePipeline` satisfies all Stage 2 pipeline
safety properties (`PublicationCorrect`, `AliasedPageCorrect`, `DstHbmSafe`,
`SrcHbmSafe`, `StagingSafe`, `StreamAccountingSafe`, `NoUnarmedPush`,
`NoOpLeak`). -/
theorem reachable_safe {ranks : List Nat} {specs : List (Nat × List Interval)}
    {s : CoveragePipeline}
    (hvalid : validSchedule ranks specs = true)
    (h : (sys ranks specs).Reachable s) :
    Pipeline.Safe s.pipe := by
  simp only [validSchedule, Bool.and_eq_true] at hvalid
  exact Pipeline.reachable_safe hvalid.1 (reachable_pipe h)

end CoveragePipeline

/-! ## Part 4: Concrete witness traces and mutants -/

/-- TP=4 → TP=2 sub-block merge witness: 2 senders (`rank 0`, `rank 1`) push
sub-block slices `[0, 16)` and `[16, 32)` into a 32-byte destination block.
Even when `[16, 32)` arrives on the wire before `[0, 16)`, the reconstructed
staging buffer equals `good 32` (`[kv 0, …, kv 31]`). -/
theorem trace_tp4_to_tp2_subblock_merge :
    let iv0 : Interval := ⟨0, 16⟩
    let iv1 : Interval := ⟨16, 32⟩
    validBlockCoverage 32 [iv0, iv1] = true ∧
    writeIntervals [iv1, iv0] (List.replicate 32 .blank) = good 32 := by
  decide

/-- Multi-sender stream count witness: sender 0 has 3 `(src, dst)` pairs and
sender 1 has 1 pair under `parallelism = 2`, yielding `min(2, 3) + min(2, 1) = 3`
expected push streams (`pool_reshard_planner.cc:1134-1142`). -/
theorem trace_multi_sender_stream_count :
    let entries : List ScheduleEntry :=
      [ ⟨0, 10, 0, ⟨0, 8⟩⟩
      , ⟨0, 11, 0, ⟨8, 16⟩⟩
      , ⟨0, 12, 1, ⟨0, 16⟩⟩
      , ⟨1, 20, 1, ⟨16, 32⟩⟩ ]
    validateExpectedPushes 2 [0, 1] entries 3 = true ∧
    senderStreams 2 entries 0 = 2 ∧
    senderStreams 2 entries 1 = 1 := by
  decide

/-- End-to-end `CoveragePipeline` witness: 2 pools on an aliased page
(`ranks = [0, 1]`), where pool 0 merges 2 sub-block intervals `[0, 4)` and
`[4, 8)` and pool 1 lands `[0, 8)` first. Both `s.pipe.dstHbm = good 2` and
every pool's byte staging buffer equals `good 8`. -/
def coverageTraceEvents : List Ev :=
  [ .send (.d2hIssue 0 true), .send (.d2hIssue 1 true), .send .execFinish
  , .send (.d2hDone 0 true), .send (.d2hDone 1 true)
  , .send (.pushDone 1 true), .send (.pushDone 0 true), .send (.pushDone 0 true)
  , .recv .pushBegin, .landStream 1, .recv (.onPoolReceived 1), .recv (.pushEnd true)
  , .recv .pushBegin, .landStream 0, .recv (.pushEnd true)
  , .recv .pushBegin, .landStream 0, .recv (.onPoolReceived 0), .recv (.pushEnd true)
  , .recv (.h2dIssue 0 true), .recv (.h2dReady 0), .recv (.h2dDone 0 true)
  , .recv (.h2dIssue 1 true), .recv (.h2dReady 1), .recv (.h2dDone 1 true)
  , .send .publish, .recv .publish ]

theorem trace_coverage_pipeline_end_to_end :
    let specs : List (Nat × List Interval) :=
      [(8, [⟨0, 4⟩, ⟨4, 8⟩]), (8, [⟨0, 8⟩])]
    ((CoveragePipeline.sys [0, 1] specs).run coverageTraceEvents).map
      (fun s => (s.pipe.recv.published, s.pipe.dstHbm,
                 s.pools.map (·.byteStaging))) =
      some (some true, good 2, [good 8, good 8]) := by
  decide

/-- Mutant 1: a gap in the sub-block schedule (`[0, 12)` then `[16, 32)`) is
rejected by `validBlockCoverage` and leaves bytes `12..15` as `.blank`. -/
theorem mutant_gap_in_coverage_leaves_unwritten_byte :
    let ivs : List Interval := [⟨0, 12⟩, ⟨16, 32⟩]
    validBlockCoverage 32 ivs = false ∧
    (writeIntervals ivs (List.replicate 32 .blank))[12]? = some .blank := by
  decide

/-- Mutant 2: overlapping sub-block intervals (`[0, 20)` and `[16, 32)`) are
rejected by `validBlockCoverage` (`reshard_receive_session.cc:331-336`). -/
theorem mutant_overlap_in_coverage_rejected :
    validBlockCoverage 32 [⟨0, 20⟩, ⟨16, 32⟩] = false := by
  decide

/-- Mutant 3: declaring `expected_pushes = 3` (summing the 3 raw pairs from
sender `0` instead of `min(parallelism, |pairs_s|) = min(2, 3) = 2`) is
rejected by `validateExpectedPushes` (`reshard_receive_session.cc:319-324`). -/
theorem mutant_mismatched_expected_pushes_rejected :
    let entries : List ScheduleEntry :=
      [ ⟨0, 10, 0, ⟨0, 8⟩⟩
      , ⟨0, 11, 0, ⟨8, 16⟩⟩
      , ⟨0, 12, 1, ⟨0, 16⟩⟩ ]
    validateExpectedPushes 2 [0] entries 3 = false ∧
    validateExpectedPushes 2 [0] entries 2 = true := by
  decide

/-- Group destination-extent prefix validation from `ValidateReceiverCoverage`
(`reshard_receive_session.cc:227-264`):
every non-last destination block must cover the full `liveBytes` (`extent == liveBytes`),
and the final destination block must satisfy `0 < extent ≤ liveBytes`. -/
def validGroupExtents (liveBytes : Nat) : List Nat → Bool
  | [] => false
  | [last] => decide (0 < last ∧ last ≤ liveBytes)
  | e :: rest => decide (e = liveBytes) && validGroupExtents liveBytes rest

/-- `KVCacheManagerBase::ExpectedPushSenders`
(`tpu_sync/kv_cache/kv_cache_manager_base.cc:2687-2704`):
returns `some schedules.length` when the active plan is a block-addressed
receiver plan (`!isSender` and `pool_groups_size() == 0`) with non-empty
`shard_push_schedules`, and `none` for sender plans, pool-grouped plans (which
use `GetPoolPushProgressSpec`, `:2706-2745`), bare plans, or after
`UnregisterActivePlan`. -/
def expectedPushSenders (isSender : Bool) (schedules : List (Nat × List ScheduleEntry)) :
    Option Nat :=
  if isSender || schedules.isEmpty then none
  else some schedules.length

/-- Replay of `ReshardReceiveSessionTest` coverage and push-count unit tests
(`tpu_sync/kv_cache/reshard_receive_session_test.cc:227-403`):
1. `ChecksEveryPoolSpanAndDestinationZeroCover` (`:227-255`, zero intervals `[]`
   on extent `16` rejected at `:249-254`).
2. `RejectsCoverageGap` (`:278-289`, extent `48` with `[0, 16)` and `[32, 48)`).
3. `RejectsCoverageOverlap` (`:291-302`, extent `24` with `[0, 16)` and `[8, 24)`).
4. `RejectsShortCoverage` (`:304-314`, extent `24` with `[0, 16)`).
5. `RejectsNonPrefixExtents` (`:316-330`, modeled with `liveBytes = 64`: `[32, 64]`
   has a partially filled non-last block; `[80]` exceeds `liveBytes`; `[64, 32]`
   is a valid prefix).
6. `RejectsMissingExtents` (`:332-341`, modeled with extent `0`).
7. `RejectsMissingParallelism` (`:343-352`, `parallelism = 0`).
8. `RejectsExpectedPushMismatch` (`:354-363`, 1 schedule entry with
   `expected_pushes = 2`).
9. `RejectsWriteBeyondDeclaredLiveTail` (`:365-403`, declared `extent = 40` with
   logical intervals `[0, 32)` and `[32, 48)` rejected at `:394-396`, and
   `[0, 32)` and `[32, 40)` accepted at `:398-402`). -/
theorem trace_reshard_receive_coverage_test_parity :
    let e1 : List ScheduleEntry := [⟨0, 3, 1, ⟨0, 16⟩⟩]
    validBlockCoverage 16 [] = false ∧
    validBlockCoverage 48 [⟨0, 16⟩, ⟨32, 48⟩] = false ∧
    validBlockCoverage 24 [⟨0, 16⟩, ⟨8, 24⟩] = false ∧
    validBlockCoverage 24 [⟨0, 16⟩] = false ∧
    validGroupExtents 64 [32, 64] = false ∧
    validGroupExtents 64 [80] = false ∧
    validGroupExtents 64 [64, 32] = true ∧
    validBlockCoverage 0 [⟨0, 16⟩] = false ∧
    validateExpectedPushes 0 [0] e1 1 = false ∧
    validateExpectedPushes 2 [0] e1 2 = false ∧
    validateExpectedPushes 2 [0] e1 1 = true ∧
    validBlockCoverage 40 [⟨0, 32⟩, ⟨32, 48⟩] = false ∧
    validBlockCoverage 40 [⟨0, 32⟩, ⟨32, 40⟩] = true := by
  decide

/-- Replay of `ExpectedPushSendersTest.CountsReceiverPlanSchedules`
(`tpu_sync/kv_cache/kv_cache_manager_with_transfer_pool_reshard_test.cc:222-269`):
- Receiver plan (`isSender = false`) with 2 source schedules (`ranks 4 and 5`)
  reports `some 2` (`:228-245`).
- Sender plan (`isSender = true`) reports `none` (`:247-259`).
- Bare plan (`schedules = []`) reports `none` (`:261-265`). -/
theorem trace_expected_push_senders_test_parity :
    let sched4 : List ScheduleEntry := [⟨4, 0, 1, ⟨0, 16⟩⟩]
    let sched5 : List ScheduleEntry := [⟨5, 0, 2, ⟨0, 16⟩⟩]
    expectedPushSenders false [(4, sched4), (5, sched5)] = some 2 ∧
    expectedPushSenders true [(0, sched4)] = none ∧
    expectedPushSenders false [] = none := by
  decide

/-- Parsed `TPU_RAIDEN_TRANSFER_STREAMS` environment variable
(`kTransferStreamsEnvVar`, `tpu_sync/kv_cache/reshard/pool_reshard_planner.h:136-149`,
`tpu_sync/kv_cache/reshard/pool_reshard_planner.cc:576-594`). -/
inductive TransferStreamsEnv where
  | unsetOrEmpty
  | intVal (n : Int)
  | unparsable
  deriving Repr, DecidableEq

/-- `DefaultTransferStreams(topology_parallelism)`
(`tpu_sync/kv_cache/reshard/pool_reshard_planner.cc:576-594`):
- Unset, empty, or `0` returns `some topologyParallelism` (`:578, 585`).
- A positive integer `n` returns `some (min n topologyParallelism)` (`:586-592`).
- Unparsable or negative values return `none` (`InvalidArgumentError`, `:580-584`). -/
def defaultTransferStreams (topologyParallelism : Nat) : TransferStreamsEnv → Option Nat
  | .unsetOrEmpty => some topologyParallelism
  | .intVal n =>
    if n < 0 then none
    else if n == 0 then some topologyParallelism
    else some (Nat.min n.toNat topologyParallelism)
  | .unparsable => none

/-- Plan parallelism resolution in `BuildPoolReshardPlan`
(`tpu_sync/kv_cache/reshard/pool_reshard_planner.cc:908-922`):
an explicit `request.parallelism` overrides `TPU_RAIDEN_TRANSFER_STREAMS` and must
lie in `(0, topologyParallelism]`; otherwise `DefaultTransferStreams` is used. -/
def resolvePlanParallelism (topologyParallelism : Nat) (explicit : Option Nat)
    (env : TransferStreamsEnv) : Option Nat :=
  let resolved :=
    match explicit with
    | some p => some p
    | none => defaultTransferStreams topologyParallelism env
  match resolved with
  | some p =>
    if 0 < p ∧ p ≤ topologyParallelism then some p else none
  | none => none

/-- Replay of `DefaultTransferStreamsTest`
(`tpu_sync/kv_cache/reshard/pool_reshard_planner_streams_test.cc:59-103`) and
`ReshardStackTest` stream-count tests
(`tpu_sync/kv_cache/reshard/reshard_service_test.cc:1818-1896`):
1. `UnsetEmptyOrZeroKeepsOneStreamPerSourceRank`
   (`pool_reshard_planner_streams_test.cc:59-72`): unset/empty or `0` on
   `topology_parallelism = 8` returns `some 8`.
2. `PositiveValueCapsStreamsWithinAdmission` (`:74-87`): `"1"` → `some 1`,
   `"4"` → `some 4`, and `"16"` clamps to `some 8`.
3. `RejectsUnparsableValueNamingVariableAndValue` (`:89-95`) and
   `RejectsNegativeValueNamingVariableAndValue` (`:97-103`): `"many"` and `"-2"`
   return `none`.
4. `UnsetTransferStreamsPlansOneStreamPerSourceRank`
   (`reshard_service_test.cc:1818-1838`),
   `TransferStreamsEnvCapsPlanStreamsAndExpectedPushes` (`:1840-1860`),
   `ExplicitPlanParallelismOverridesTransferStreamsEnv` (`:1862-1879`), and
   `InvalidTransferStreamsEnvFailsThePlan` (`:1881-1896`): with 2 source ranks
   (`topology_parallelism = 2`) and 2 block pairs per rank, unset env plans
   `parallelism = 2` and `expected_pushes = 4`; `TPU_RAIDEN_TRANSFER_STREAMS=1`
   caps `parallelism = 1` and `expected_pushes = 2`; explicit `request.parallelism = 2`
   overrides `TPU_RAIDEN_TRANSFER_STREAMS=1` back to `parallelism = 2` and
   `expected_pushes = 4`; and `"many"` fails the plan (`none`). -/
theorem trace_default_transfer_streams_test_parity :
    defaultTransferStreams 8 .unsetOrEmpty = some 8 ∧
    defaultTransferStreams 8 (.intVal 0) = some 8 ∧
    defaultTransferStreams 8 (.intVal 1) = some 1 ∧
    defaultTransferStreams 8 (.intVal 4) = some 4 ∧
    defaultTransferStreams 8 (.intVal 16) = some 8 ∧
    defaultTransferStreams 8 .unparsable = none ∧
    defaultTransferStreams 8 (.intVal (-2)) = none ∧
    let twoRanksTwoPairs : List ScheduleEntry :=
      [ ⟨0, 0, 7, ⟨0, 1024⟩⟩, ⟨0, 1, 8, ⟨0, 1024⟩⟩
      , ⟨1, 0, 9, ⟨0, 1024⟩⟩, ⟨1, 1, 10, ⟨0, 1024⟩⟩ ]
    (resolvePlanParallelism 2 none .unsetOrEmpty).map
      (fun p => (p, recomputedExpectedPushes p [0, 1] twoRanksTwoPairs)) = some (2, 4) ∧
    (resolvePlanParallelism 2 none (.intVal 1)).map
      (fun p => (p, recomputedExpectedPushes p [0, 1] twoRanksTwoPairs)) = some (1, 2) ∧
    (resolvePlanParallelism 2 (some 2) (.intVal 1)).map
      (fun p => (p, recomputedExpectedPushes p [0, 1] twoRanksTwoPairs)) = some (2, 4) ∧
    resolvePlanParallelism 2 none .unparsable = none := by
  decide

end TpuSyncVerify.Transfer.Reshard.Coverage
