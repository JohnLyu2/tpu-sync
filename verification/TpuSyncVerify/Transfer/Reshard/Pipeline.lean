import TpuSyncVerify.Common.ListAux
import TpuSyncVerify.Transfer.Reshard.Receive
import TpuSyncVerify.Transfer.Reshard.Send

/-!
# Pool-reshard transfer pipeline

Stage 2 of the pool-addressed resharding model (`docs/transfer/reshard.md`):
composes `Reshard.Send` (`ReshardSendSession`, `Send.lean`), `Reshard.Recv`
(`ReshardReceiveSession`, `Receive.lean`), the plan-declared stream progress in
`BlockTransport::HandleIncomingPush` (`bt.cc:640-793`), the Arm-then-Dispatch
coordination barrier in `ReshardCoordinator::ExecutePoolReshard`
(`coord.cc:429-549`), and the five memories KV data moves through between source
and destination HBM — including **aliased device pages** shared across pool
ranks (`recv.h:180-184`, `base.h:689-692`).

Citations are to tpu-sync `1fa06d1`:
* `send.cc` — `tpu_sync/kv_cache/reshard_send_session.cc`
* `slots.cc` — `tpu_sync/core/pool_reshard_send_slots.cc`
* `recv.h` / `recv.cc` — `tpu_sync/kv_cache/reshard_receive_session.{h,cc}`
* `bt.cc` — `tpu_sync/transport/block_transport.cc`
* `mgr.cc` — `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`
* `base.h` — `tpu_sync/kv_cache/kv_cache_manager_base.h`
* `coord.cc` — `tpu_sync/kv_cache/reshard/reshard_coordinator.cc`

## Memories and aliased device pages

A memory is a list indexed by pool `p < numPools`. A `Cell` is `.kv p` (pool
`p`'s resharded KV data), `.junk` (stale/reclaimed memory or lower-rank coarse
padding on an aliased page), or `.blank` (never written on the wire).

| Memory       | Role | Written by |
|--------------|------|------------|
| `srcHbm`     | producer KV cache in source HBM | `reclaim` (after `send.published ≠ none`) |
| `srcStaging` | sender `PoolStagingStorage` (`send.cc:139-145`) | `send (.d2hDone p true)`, `reseatSrcStaging` |
| `wire`       | bytes delivered by sender peer pushes (`send.cc:332-337`) | `send (.pushDone p true)` |
| `dstStaging` | receiver `PoolStagingStorage` (`recv.cc:301-307`) | `landStream p` (`bt.cc:603-685`), `reseatDstStaging` |
| `dstHbm`     | consumer KV cache in destination HBM (`recv.cc:591-690`) | `recv (.h2dDone p true)` via `writePoolHbm` |

### Modelling aliased device pages (`writePoolHbm`)

On hybrid attention + state arenas (`base.h:689-692`, `recv.h:180-184`), pools
of different ranks can share physical HBM pages: a lower-rank pool's coarse H2D
copy writes across the page (clobbering bytes belonging to higher-rank pools),
and higher-rank H2D waves are meant to run afterwards to overwrite those bytes
with the true higher-rank pool data.

We model this pessimistic page aliasing directly on `dstHbm`: when pool `p`
completes its H2D copy (`recv (.h2dDone p true)`), `writePoolHbm` writes
`dstStaging[p]` to `dstHbm[p]` **and** clobbers `dstHbm[q] := .junk` for every
pool `q` of strictly higher rank (`pool_p.rank < pool_q.rank`). Because Stage 1's
`Recv.RankWaveOrder` guarantees that no higher-rank pool `q` has entered
`queued`, `issued`, `ready`, or `completed` when a lower-rank pool `p` is in
`ready`, this clobbering never overwrites a completed higher-rank pool
(`AliasedPageCorrect`), so `dstHbm = good numPools` holds when `done_recving`
is published (`PublicationCorrect`). Conversely, a mutant that omits the rank
gate allows pool 1 (rank 1) to finish H2D before pool 0 (rank 0), and pool 0's
subsequent H2D clobbers `dstHbm[1]` to `.junk`.
-/

namespace TpuSyncVerify.Transfer.Reshard

open TpuSyncVerify.Transfer (Lifecycle)

/-- Contents of one pool slot in memory. -/
inductive Cell where
  | blank
  | kv (pool : Nat)
  | junk
  deriving Repr, DecidableEq

namespace Pipeline

/-- A memory holding `.kv p` at every pool index `0 … n - 1`. -/
def good (n : Nat) : List Cell := (List.range n).map Cell.kv

/-- Coarse lower-rank H2D copy clobbers any strictly higher-rank pool slot on an
aliased arena page (`recv.h:180-184`, `base.h:689-692`). -/
def clobberHigherRanks (pools : List Pool) (r : Nat) (hbm : List Cell) : List Cell :=
  List.zipWith (fun pool c => if r < pool.rank then .junk else c) pools hbm

/-- Completing pool `p`'s H2D copy at rank `r` writes `val` to `hbm[p]` after
clobbering any strictly higher-rank pool slot. -/
def writePoolHbm (pools : List Pool) (p : Nat) (r : Nat) (val : Cell)
    (hbm : List Cell) : List Cell :=
  (clobberHigherRanks pools r hbm).set p val

/-- A reshard pipeline schedule is valid when there is at least one pool,
`ranks` and `peerCounts` have the same length, and every pool has at least one
expected push stream (`recv.cc:137-139`, `slots.cc:43-49`). -/
def validConfig (ranks peerCounts : List Nat) : Bool :=
  !ranks.isEmpty && (ranks.length == peerCounts.length) && peerCounts.all (0 < ·)

end Pipeline

/-- Composed reshard pipeline state. -/
structure Pipeline where
  numPools : Nat
  peerCounts : List Nat
  send : Send
  recv : Recv
  srcHbm : List Cell
  srcStaging : List Cell
  wire : List Cell
  dstStaging : List Cell
  dstHbm : List Cell
  /-- Completed sender peer pushes per pool (`send.cc:332-337`). -/
  sentStreams : List Nat
  /-- Streams landed by `BlockTransport::HandleIncomingPush` per pool (`bt.cc:684`). -/
  landedStreams : List Nat
  /-- Whether source HBM has been freed after `send.published ≠ none`. -/
  reclaimed : Bool := false
  /-- Whether `PoolReshardRegisterRecv` has armed the receiver (`coord.cc:433-475`). -/
  armed : Bool := true
  deriving Repr, DecidableEq

namespace Pipeline

/-- Initial state for a reshard transfer with pool ranks `ranks` and per-pool
expected stream counts `peerCounts`, after `PoolReshardRegisterRecv` has armed
the receiver (`armed = true`). -/
def init (ranks peerCounts : List Nat) : Pipeline :=
  let n := ranks.length
  { numPools := n
    peerCounts := peerCounts
    send := Send.init peerCounts
    recv := Recv.init ranks
    srcHbm := good n
    srcStaging := List.replicate n .junk
    wire := List.replicate n .blank
    dstStaging := List.replicate n .junk
    dstHbm := List.replicate n .junk
    sentStreams := List.replicate n 0
    landedStreams := List.replicate n 0
    reclaimed := false
    armed := true }

/-- Initial state before Phase 1 of `ReshardCoordinator::ExecutePoolReshard`
(`PoolReshardRegisterRecv`, `coord.cc:433-475`) has armed the receiver. -/
def initUnarmed (ranks peerCounts : List Nat) : Pipeline :=
  { init ranks peerCounts with armed := false }

inductive Ev where
  | armRecv
  | send (e : Send.Ev)
  | recv (e : Recv.Ev)
  | landStream (p : Nat)
  | reclaim
  | reseatSrcStaging
  | reseatDstStaging
  deriving Repr, DecidableEq

/-- Phase 1 of `ReshardCoordinator::ExecutePoolReshard` (`coord.cc:433-475`,
`mgr.cc:642-727`): `PoolReshardRegisterRecv` arms the destination receiver. -/
def armRecv (s : Pipeline) : Option Pipeline :=
  if s.armed = false then
    some { s with armed := true }
  else none

/-- Sender transition (`send.cc:220-430`). Launching a D2H copy
(`d2hIssue p true`) requires the receiver to be armed (`coord.cc:480-544`);
`d2hDone p true` copies `srcHbm[p]` into `srcStaging[p]`; `pushDone p true`
places `srcStaging[p]` on `wire[p]` and increments `sentStreams[p]`. -/
def sendStep (s : Pipeline) (e : Send.Ev) : Option Pipeline :=
  match e with
  | .d2hIssue p ok =>
    if ok = false ∨ s.armed = true then
      (Send.step .shipping s.send (.d2hIssue p ok)).map fun snd =>
        { s with send := snd }
    else none
  | .d2hDone p ok =>
    (Send.step .shipping s.send (.d2hDone p ok)).map fun snd =>
      if ok then
        { s with send := snd
                 srcStaging := s.srcStaging.set p (s.srcHbm.getD p .junk) }
      else { s with send := snd }
  | .pushDone p ok =>
    (Send.step .shipping s.send (.pushDone p ok)).map fun snd =>
      if ok then
        { s with send := snd
                 wire := s.wire.set p (s.srcStaging.getD p .junk)
                 sentStreams := s.sentStreams.set p (s.sentStreams.getD p 0 + 1) }
      else { s with send := snd }
  | e =>
    (Send.step .shipping s.send e).map fun snd => { s with send := snd }

/-- Receiver transition (`recv.cc:497-694`, `bt.cc:742-787`). `pushBegin`
requires the receiver to be armed (`mgr.cc:155-201`); `onPoolReceived p`
requires all `peerCounts[p]` expected streams to have landed (`bt.cc:742-787`);
`h2dDone p true` writes `dstStaging[p]` to `dstHbm[p]` and clobbers any strictly
higher-rank pool slots on the aliased page (`writePoolHbm`). -/
def recvStep (s : Pipeline) (e : Recv.Ev) : Option Pipeline :=
  match e with
  | .pushBegin =>
    if s.armed = true then
      (Recv.step .shipping s.recv .pushBegin).map fun rcv => { s with recv := rcv }
    else none
  | .onPoolReceived p =>
    if s.landedStreams[p]? = some (s.peerCounts.getD p 0) then
      (Recv.step .shipping s.recv (.onPoolReceived p)).map fun rcv =>
        { s with recv := rcv }
    else none
  | .h2dDone p ok =>
    match s.recv.pools[p]? with
    | some pool =>
      (Recv.step .shipping s.recv (.h2dDone p ok)).map fun rcv =>
        if ok then
          { s with recv := rcv
                   dstHbm := writePoolHbm s.recv.pools p pool.rank
                               (s.dstStaging.getD p .junk) s.dstHbm }
        else { s with recv := rcv }
    | none => none
  | e =>
    (Recv.step .shipping s.recv e).map fun rcv => { s with recv := rcv }

/-- `BlockTransport::HandleIncomingPush` lands one push stream for pool `p` into
`dstStaging[p]` and increments `completed_chunks` (`bt.cc:603-685`). -/
def landStream (s : Pipeline) (p : Nat) : Option Pipeline :=
  if 0 < s.recv.pushes then
    match s.landedStreams[p]?, s.sentStreams[p]?, s.wire[p]? with
    | some k, some m, some c =>
      if k < m ∧ c ≠ .blank then
        some { s with dstStaging := s.dstStaging.set p c
                      landedStreams := s.landedStreams.set p (k + 1) }
      else none
    | _, _, _ => none
  else none

/-- Source engine/registry reclaims producer HBM once `CompleteReadWithDetails`
has published the send session (`mgr.cc:949-955`, `coord.cc:643-681`). -/
def reclaim (s : Pipeline) : Option Pipeline :=
  if s.send.published ≠ none ∧ s.reclaimed = false then
    some { s with srcHbm := List.replicate s.numPools .junk, reclaimed := true }
  else none

/-- Released sender `PoolStagingLease` slots may be reused by another transfer
(`mgr.cc:611-639`, `send.cc:412-424`). -/
def reseatSrcStaging (s : Pipeline) : Option Pipeline :=
  if s.send.life.hasStaging = false then
    some { s with srcStaging := List.replicate s.numPools .junk }
  else none

/-- Released receiver `PoolStagingLease` slots may be reused by another transfer
(`mgr.cc:649-677`, `recv.cc:467-471`). -/
def reseatDstStaging (s : Pipeline) : Option Pipeline :=
  if s.recv.life.hasStaging = false then
    some { s with dstStaging := List.replicate s.numPools .junk }
  else none

def step (s : Pipeline) : Ev → Option Pipeline
  | .armRecv => s.armRecv
  | .send e => s.sendStep e
  | .recv e => s.recvStep e
  | .landStream p => s.landStream p
  | .reclaim => s.reclaim
  | .reseatSrcStaging => s.reseatSrcStaging
  | .reseatDstStaging => s.reseatDstStaging

def sys (ranks peerCounts : List Nat) : System Pipeline Ev :=
  ⟨init ranks peerCounts, step⟩

def sysUnarmed (ranks peerCounts : List Nat) : System Pipeline Ev :=
  ⟨initUnarmed ranks peerCounts, step⟩

/-! ## Structural lemmas on `good`, `clobberHigherRanks`, and `writePoolHbm` -/

@[simp] theorem getElem?_replicate_getD {α : Type} (n p : Nat) (x : α) :
    (List.replicate n x)[p]?.getD x = x := by
  rw [List.getElem?_replicate]
  split <;> rfl

@[simp] theorem getD_replicate_self {α : Type} (n p : Nat) (x : α) :
    (List.replicate n x).getD p x = x := by
  rw [List.getD_eq_getElem?_getD, getElem?_replicate_getD]

theorem getD_set_self {α : Type} {l : List α} {p : Nat} {v d : α} (hp : p < l.length) :
    (l.set p v).getD p d = v := by
  rw [List.getD_eq_getElem?_getD, List.getElem?_set_self hp]; rfl

theorem getD_set_ne {α : Type} {l : List α} {p q : Nat} {v d : α} (hne : p ≠ q) :
    (l.set p v).getD q d = l.getD q d := by
  rw [List.getD_eq_getElem?_getD, List.getD_eq_getElem?_getD, List.getElem?_set_ne hne]

theorem exists_getElem?_of_mem {α : Type} {l : List α} {x : α} (h : x ∈ l) :
    ∃ p < l.length, l[p]? = some x := by
  obtain ⟨p, hp, rfl⟩ := List.getElem_of_mem h
  exact ⟨p, hp, List.getElem?_eq_getElem hp⟩

@[simp] theorem length_good (n : Nat) : (good n).length = n := by
  simp [good]

theorem getElem?_good {n p : Nat} (hp : p < n) :
    (good n)[p]? = some (.kv p) := by
  simp [good, hp]

theorem getD_good {n p : Nat} (hp : p < n) (d : Cell) :
    (good n).getD p d = .kv p := by
  rw [List.getD_eq_getElem?_getD, getElem?_good hp]; rfl

theorem eq_good_of_getElem? {xs : List Cell} {n : Nat}
    (hlen : xs.length = n) (h : ∀ p < n, xs[p]? = some (.kv p)) :
    xs = good n := by
  apply List.ext_getElem?
  intro p
  by_cases hp : p < n
  · rw [h p hp, getElem?_good hp]
  · have h₁ : xs[p]? = none := List.getElem?_eq_none (by omega)
    have h₂ : (good n)[p]? = none := List.getElem?_eq_none (by simp; omega)
    rw [h₁, h₂]

@[simp] theorem length_clobberHigherRanks (pools : List Pool) (r : Nat) (hbm : List Cell) :
    (clobberHigherRanks pools r hbm).length = min pools.length hbm.length := by
  simp [clobberHigherRanks]

@[simp] theorem length_writePoolHbm (pools : List Pool) (p r : Nat) (val : Cell) (hbm : List Cell) :
    (writePoolHbm pools p r val hbm).length = min pools.length hbm.length := by
  simp [writePoolHbm]

theorem getElem?_clobberHigherRanks_of_not_lt {pools : List Pool} {hbm : List Cell}
    {r q : Nat} {pool : Pool} (hpool : pools[q]? = some pool) (hnlt : ¬(r < pool.rank)) :
    (clobberHigherRanks pools r hbm)[q]? = hbm[q]? := by
  unfold clobberHigherRanks
  rw [List.getElem?_zipWith, hpool]
  cases hbm[q]? <;> simp [hnlt]

theorem getElem?_writePoolHbm_self {pools : List Pool} {hbm : List Cell}
    {p r : Nat} {val : Cell} (hp : p < min pools.length hbm.length) :
    (writePoolHbm pools p r val hbm)[p]? = some val := by
  unfold writePoolHbm
  apply List.getElem?_set_self
  simp [hp]

theorem getElem?_writePoolHbm_of_ne_of_not_lt {pools : List Pool} {hbm : List Cell}
    {p q r : Nat} {val : Cell} {pool : Pool}
    (hne : p ≠ q) (hpool : pools[q]? = some pool) (hnlt : ¬(r < pool.rank)) :
    (writePoolHbm pools p r val hbm)[q]? = hbm[q]? := by
  unfold writePoolHbm
  rw [List.getElem?_set_ne hne]
  exact getElem?_clobberHigherRanks_of_not_lt hpool hnlt

/-! ## Safety properties -/

/-- When `poll_stats()` reports `done_recving`, destination HBM holds every
transferred pool's resharded KV data (`dstHbm = good numPools`). -/
def PublicationCorrect (s : Pipeline) : Prop :=
  s.recv.published = some true → s.dstHbm = good s.numPools

/-- Aliased-page rank-wave integrity: once any pool `q` completes its H2D copy
(`pool.stage = .completed`), its destination slot `dstHbm[q]` holds `.kv q` and
is never clobbered by any subsequent H2D wave. -/
def AliasedPageCorrect (s : Pipeline) : Prop :=
  ∀ q < s.numPools, ∀ pool,
    s.recv.pools[q]? = some pool → pool.stage = .completed → s.dstHbm[q]? = some (.kv q)

abbrev DonePoolsIntact (s : Pipeline) : Prop := AliasedPageCorrect s

/-- Once the receiver is published (`done_recving` or `failed_recving`), no pool
has an H2D copy queued or in flight. -/
def DstHbmSafe (s : Pipeline) : Prop :=
  s.recv.published ≠ none → Recv.poolOps s.recv.pools = 0

/-- Once the sender is published (`done_sending` or `failed_sending`) or source
HBM is reclaimed, neither `ExecutePush` nor any D2H/push op is active. -/
def SrcHbmSafe (s : Pipeline) : Prop :=
  (s.send.published ≠ none →
    s.send.execActive = false ∧ Send.poolOps s.send.pools = 0) ∧
  (s.reclaimed = true →
    s.send.life.done = true ∧ s.send.execActive = false ∧ Send.poolOps s.send.pools = 0)

/-- Once either session releases its `PoolStagingLease`, no DMA copy or network
push is reading or writing its staging buffer. -/
def StagingSafe (s : Pipeline) : Prop :=
  (s.send.life.hasStaging = false →
    s.send.execActive = false ∧ Send.poolOps s.send.pools = 0) ∧
  (s.recv.life.hasStaging = false →
    s.recv.pushes = 0 ∧ Recv.poolOps s.recv.pools = 0)

/-- Plan-declared transport progress accounting (`bt.cc:684-787`): landed streams
never exceed sent streams, sent streams never exceed `peerCounts`, and any pool
that has passed `OnPoolReceived` (`stage ≠ .waiting`) has landed all
`peerCounts[p]` expected streams. -/
def StreamAccountingSafe (s : Pipeline) : Prop :=
  ∀ p < s.numPools,
    s.landedStreams.getD p 0 ≤ s.sentStreams.getD p 0 ∧
    s.sentStreams.getD p 0 ≤ s.peerCounts.getD p 0 ∧
    (∀ pool, s.recv.pools[p]? = some pool → pool.stage ≠ .waiting →
      s.landedStreams.getD p 0 = s.peerCounts.getD p 0)

/-- Two-phase Arm-then-Dispatch barrier (`coord.cc:433-544`): before
`PoolReshardRegisterRecv` arms the receiver (`armed = false`), no sender pool
has launched a D2H copy or push and no receiver push or H2D is active. -/
def NoUnarmedPush (s : Pipeline) : Prop :=
  s.armed = false →
    (∀ pool ∈ s.send.pools, pool.stage = .pending ∨ pool.stage = .aborted) ∧
    s.recv.pushes = 0 ∧
    (∀ pool ∈ s.recv.pools, pool.stage = .waiting)

/-- Events that drain in-flight operations on either session. -/
def drainEvents (n : Nat) : List Ev :=
  (Send.drainEvents n).map Ev.send ++ (Recv.drainEvents n).map Ev.recv

/-- Every in-flight operation on either session has an enabled drain step in the
composed pipeline. -/
def NoOpLeak (s : Pipeline) : Prop :=
  (0 < s.send.life.inFlight ∨ 0 < s.recv.life.inFlight) →
    ∃ e ∈ drainEvents s.numPools, (step s e).isSome = true

def Safe (s : Pipeline) : Prop :=
  PublicationCorrect s ∧ AliasedPageCorrect s ∧ DstHbmSafe s ∧ SrcHbmSafe s ∧
    StagingSafe s ∧ StreamAccountingSafe s ∧ NoUnarmedPush s ∧ NoOpLeak s

/-! ## Inductive invariant -/

structure Inv (s : Pipeline) : Prop where
  sendInv : Send.Inv .shipping s.send
  recvInv : Recv.Inv s.recv
  num_pos : 0 < s.numPools
  len_peers : s.peerCounts.length = s.numPools
  len_send : s.send.pools.length = s.numPools
  len_recv : s.recv.pools.length = s.numPools
  len_srcHbm : s.srcHbm.length = s.numPools
  len_srcStg : s.srcStaging.length = s.numPools
  len_wire : s.wire.length = s.numPools
  len_dstStg : s.dstStaging.length = s.numPools
  len_dstHbm : s.dstHbm.length = s.numPools
  len_sent : s.sentStreams.length = s.numPools
  len_landed : s.landedStreams.length = s.numPools
  peers_match : ∀ p < s.numPools, ∀ pool,
    s.send.pools[p]? = some pool → pool.peers = s.peerCounts.getD p 0
  srcHbm_ok : s.reclaimed = false → s.srcHbm = good s.numPools
  reclaimed_pub : s.reclaimed = true → s.send.published ≠ none
  srcStg_ok : s.send.life.done = false →
    ∀ p < s.numPools, ∀ pool, s.send.pools[p]? = some pool →
      (∃ k, pool.stage = .pushing k) → s.srcStaging[p]? = some (.kv p)
  sent_bound : ∀ p < s.numPools, ∀ pool,
    s.send.pools[p]? = some pool →
      s.sentStreams.getD p 0 + pool.remainingSlots ≤ pool.peers
  wire_ok : ∀ p < s.numPools,
    0 < s.sentStreams.getD p 0 → s.wire[p]? = some (.kv p)
  landed_le_sent : ∀ p < s.numPools,
    s.landedStreams.getD p 0 ≤ s.sentStreams.getD p 0
  dstStg_ok : s.recv.life.done = false →
    ∀ p < s.numPools, 0 < s.landedStreams.getD p 0 → s.dstStaging[p]? = some (.kv p)
  recv_stage_landed : ∀ p < s.numPools, ∀ pool,
    s.recv.pools[p]? = some pool → pool.stage ≠ .waiting →
      s.landedStreams.getD p 0 = s.peerCounts.getD p 0
  done_intact : AliasedPageCorrect s
  unarmed_send : s.armed = false →
    ∀ p < s.numPools, ∀ pool, s.send.pools[p]? = some pool →
      pool.stage = .pending ∨ pool.stage = .aborted
  unarmed_recv : s.armed = false →
    s.recv.pushes = 0 ∧
    (∀ p < s.numPools, s.landedStreams.getD p 0 = 0) ∧
    (∀ p < s.numPools, ∀ pool, s.recv.pools[p]? = some pool → pool.stage = .waiting)

theorem validConfig_parts {ranks peerCounts : List Nat}
    (h : validConfig ranks peerCounts = true) :
    Send.validSchedule peerCounts = true ∧
    0 < ranks.length ∧
    peerCounts.length = ranks.length := by
  unfold validConfig at h
  simp only [Bool.and_eq_true, beq_iff_eq] at h
  obtain ⟨⟨hne, hlen⟩, hall⟩ := h
  have hpos : 0 < ranks.length := by
    cases ranks with
    | nil => simp at hne
    | cons _ _ => simp
  have hpe_ne : (!peerCounts.isEmpty) = true := by
    cases peerCounts with
    | nil =>
      have : ranks.length = 0 := hlen
      omega
    | cons _ _ => rfl
  exact ⟨by simp [Send.validSchedule, hpe_ne, hall], hpos, hlen.symm⟩

theorem getElem?_map_init_send {peerCounts : List Nat} {p : Nat} {pool : SendPool}
    (h : (peerCounts.map fun n => ({ peers := n, stage := .pending } : SendPool))[p]? = some pool) :
    pool.peers = peerCounts.getD p 0 ∧ pool.stage = .pending := by
  rw [List.getElem?_map] at h
  cases hpe : peerCounts[p]? with
  | none => simp [hpe] at h
  | some n =>
    simp only [hpe, Option.map_some, Option.some.injEq] at h
    subst h
    simp [List.getD_eq_getElem?_getD, hpe]

theorem getElem?_map_init_recv {ranks : List Nat} {p : Nat} {pool : Pool}
    (h : (ranks.map fun r => ({ rank := r, stage := .waiting } : Pool))[p]? = some pool) :
    pool.rank = ranks.getD p 0 ∧ pool.stage = .waiting := by
  rw [List.getElem?_map] at h
  cases hr : ranks[p]? with
  | none => simp [hr] at h
  | some r =>
    simp only [hr, Option.map_some, Option.some.injEq] at h
    subst h
    simp [List.getD_eq_getElem?_getD, hr]

theorem inv_init {ranks peerCounts : List Nat} (h : validConfig ranks peerCounts = true) :
    Inv (init ranks peerCounts) := by
  obtain ⟨hsend, hpos, hlen⟩ := validConfig_parts h
  refine ⟨Send.inv_init .shipping hsend, Recv.inv_init ranks, hpos,
    hlen, by simp [init, Send.init, hlen], by simp [init, Recv.init],
    by simp [init], by simp [init], by simp [init], by simp [init],
    by simp [init], by simp [init], by simp [init],
    ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro p _ pool hget
    exact (getElem?_map_init_send hget).1
  · intro _; rfl
  · intro hr; simp [init] at hr
  · intro _ p _ pool hget ⟨k, hk⟩
    have hst := (getElem?_map_init_send hget).2
    simp [hst] at hk
  · intro p _ pool hget
    have hst := (getElem?_map_init_send hget).2
    simp [init, SendPool.remainingSlots, hst]
  · intro p _ hgt
    simp [init] at hgt
  · intro p _
    simp [init]
  · intro _ p _ hgt
    simp [init] at hgt
  · intro p _ pool hget hne
    have hst := (getElem?_map_init_recv hget).2
    exact absurd hst hne
  · intro q _ pool hget hdone
    have hst := (getElem?_map_init_recv hget).2
    simp [hst] at hdone
  · intro ha; simp [init] at ha
  · intro ha; simp [init] at ha

theorem inv_initUnarmed {ranks peerCounts : List Nat} (h : validConfig ranks peerCounts = true) :
    Inv (initUnarmed ranks peerCounts) := by
  have hi := inv_init h
  refine ⟨hi.sendInv, hi.recvInv, hi.num_pos, hi.len_peers, hi.len_send, hi.len_recv,
    hi.len_srcHbm, hi.len_srcStg, hi.len_wire, hi.len_dstStg, hi.len_dstHbm,
    hi.len_sent, hi.len_landed, hi.peers_match, hi.srcHbm_ok, hi.reclaimed_pub,
    hi.srcStg_ok, hi.sent_bound, hi.wire_ok, hi.landed_le_sent,
    hi.dstStg_ok, hi.recv_stage_landed, hi.done_intact, ?_, ?_⟩
  · intro _ p _ pool hget
    exact Or.inl (getElem?_map_init_send hget).2
  · refine fun _ => ⟨rfl, fun p _ => ?_, fun p _ pool hget => (getElem?_map_init_recv hget).2⟩
    simp [initUnarmed, init]

/-! ### Helper lemmas for `Safe` and `step_inv` -/

theorem peerCount_pos {s : Pipeline} (h : Inv s) {p : Nat} (hp : p < s.numPools) :
    0 < s.peerCounts.getD p 0 := by
  have hlt : p < s.send.pools.length := by rw [h.len_send]; exact hp
  have hget : s.send.pools[p]? = some s.send.pools[p] := List.getElem?_eq_getElem hlt
  have hallPos : Send.allPosPeers s.send.pools = true := by
    have hv := h.sendInv.valid; unfold Send.validPools at hv
    simp only [Bool.and_eq_true] at hv; exact hv.2
  have hp_pos := Send.peers_pos_of_allPosPeers hallPos hget
  rw [← h.peers_match p hp s.send.pools[p] hget]
  exact hp_pos

theorem step_send_isSome {s : Pipeline} {e : Send.Ev} (he : e ∈ Send.drainEvents s.numPools) :
    (step s (.send e)).isSome = (Send.step .shipping s.send e).isSome := by
  simp only [Send.drainEvents, List.mem_append, List.mem_singleton, List.mem_flatMap,
    List.mem_range] at he
  rcases he with rfl | ⟨p, _, hp⟩
  · simp [step, sendStep]
  · simp only [List.mem_cons, List.not_mem_nil, or_false] at hp
    rcases hp with rfl | rfl | rfl <;> simp [step, sendStep]

theorem step_recv_isSome {s : Pipeline} {e : Recv.Ev} (he : e ∈ Recv.drainEvents s.numPools) :
    (step s (.recv e)).isSome = (Recv.step .shipping s.recv e).isSome := by
  simp only [Recv.drainEvents, List.mem_append, List.mem_singleton, List.mem_flatMap,
    List.mem_range] at he
  rcases he with rfl | ⟨p, _, hp⟩
  · simp [step, recvStep]
  · simp only [List.mem_cons, List.not_mem_nil, or_false] at hp
    rcases hp with rfl | rfl | rfl
    · simp [step, recvStep]
    · simp [step, recvStep]
    · simp only [step, recvStep, Recv.step, Recv.h2dDone]
      cases s.recv.pools[p]? <;> simp

theorem inv_noOpLeak {s : Pipeline} (h : Inv s) : NoOpLeak s := by
  intro hif
  rcases hif with hsnd | hrcv
  · obtain ⟨e, he, hsome⟩ := Send.inv_noOpLeak h.sendInv hsnd
    rw [h.len_send] at he
    refine ⟨.send e, ?_, ?_⟩
    · simp only [drainEvents, List.mem_append, List.mem_map]
      exact Or.inl ⟨e, he, rfl⟩
    · rw [step_send_isSome he]; exact hsome
  · obtain ⟨e, he, hsome⟩ := Recv.inv_noOpLeak .shipping h.recvInv hrcv
    rw [h.len_recv] at he
    refine ⟨.recv e, ?_, ?_⟩
    · simp only [drainEvents, List.mem_append, List.mem_map]
      exact Or.inr ⟨e, he, rfl⟩
    · rw [step_recv_isSome he]; exact hsome

theorem allCompleted_getElem? {ps : List Pool} (h : Recv.allCompleted ps = true)
    {p : Nat} {pool : Pool} (hget : ps[p]? = some pool) :
    pool.stage = .completed := by
  unfold Recv.allCompleted at h
  rw [List.all_eq_true] at h
  have hmem := List.mem_of_getElem? hget
  exact beq_iff_eq.mp (h pool hmem)

theorem inv_safe {s : Pipeline} (h : Inv s) : Safe s := by
  have hsendSafe := Send.inv_safe h.sendInv
  have hrecvSafe := Recv.inv_safe .shipping h.recvInv
  refine ⟨?_, h.done_intact, ?_, ?_, ?_, ?_, ?_, inv_noOpLeak h⟩
  · -- PublicationCorrect
    intro hpub
    have ⟨hallComp, _⟩ := h.recvInv.published_ok hpub
    apply eq_good_of_getElem? h.len_dstHbm
    intro p hp
    have hlt : p < s.recv.pools.length := by rw [h.len_recv]; exact hp
    have hget : s.recv.pools[p]? = some s.recv.pools[p] := List.getElem?_eq_getElem hlt
    exact h.done_intact p hp s.recv.pools[p] hget (allCompleted_getElem? hallComp hget)
  · -- DstHbmSafe
    intro hpub
    cases hb : s.recv.published with
    | none => exact absurd hb hpub
    | some b =>
      have ⟨hd, _⟩ := h.recvInv.published_done b hb
      exact hrecvSafe.2.1 hd
  · -- SrcHbmSafe
    refine ⟨?_, ?_⟩
    · intro hpub
      cases hb : s.send.published with
      | none => exact absurd hb hpub
      | some b =>
        have hd := h.sendInv.published_done b hb
        exact hsendSafe.2.1 hd
    · intro hrec
      have hpub := h.reclaimed_pub hrec
      cases hb : s.send.published with
      | none => exact absurd hb hpub
      | some b =>
        have hd := h.sendInv.published_done b hb
        have ⟨hex, hpo⟩ := hsendSafe.2.1 hd
        exact ⟨hd, hex, hpo⟩
  · -- StagingSafe
    refine ⟨?_, ?_⟩
    · intro hst
      have hd : s.send.life.done = true := by
        rw [h.sendInv.life.staging] at hst; simpa using hst
      exact hsendSafe.2.1 hd
    · intro hst
      have hd : s.recv.life.done = true := by
        rw [h.recvInv.life.staging] at hst; simpa using hst
      have hif := h.recvInv.life.done_idle hd
      have hacc := h.recvInv.accounted; unfold Recv.Accounted at hacc
      omega
  · -- StreamAccountingSafe
    intro p hp
    have hlt : p < s.send.pools.length := by rw [h.len_send]; exact hp
    have hget : s.send.pools[p]? = some s.send.pools[p] := List.getElem?_eq_getElem hlt
    have hpe := h.peers_match p hp s.send.pools[p] hget
    have hbnd := h.sent_bound p hp s.send.pools[p] hget
    exact ⟨h.landed_le_sent p hp, by omega, h.recv_stage_landed p hp⟩
  · -- NoUnarmedPush
    intro ha
    have hlen_s := h.len_send
    have hlen_r := h.len_recv
    refine ⟨?_, (h.unarmed_recv ha).1, ?_⟩
    · intro pool hmem
      obtain ⟨p, hp, hget⟩ := exists_getElem?_of_mem hmem
      exact h.unarmed_send ha p (by omega) pool hget
    · intro pool hmem
      obtain ⟨p, hp, hget⟩ := exists_getElem?_of_mem hmem
      exact (h.unarmed_recv ha).2.2 p (by omega) pool hget

/-! ### Frame lemmas on `Send.step` and `Recv.step` -/

@[simp] theorem endOp_pools (r : Send) : (Send.endOp r).pools = r.pools := rfl
@[simp] theorem endOp_published (r : Send) : (Send.endOp r).published = r.published := rfl
@[simp] theorem endOp_life (r : Send) : (Send.endOp r).life = r.life.endOpLocked := rfl

@[simp] theorem recordPushCompletion_pools (pol : UnregisterPolicy) (ok : Bool) (r : Send) :
    (Send.recordPushCompletion pol ok r).pools = r.pools := by
  unfold Send.recordPushCompletion
  split <;> try rfl
  split <;> try rfl
  split <;> rfl

@[simp] theorem recordPushCompletion_published (pol : UnregisterPolicy) (ok : Bool) (r : Send) :
    (Send.recordPushCompletion pol ok r).published = r.published := by
  unfold Send.recordPushCompletion
  split <;> try rfl
  split <;> try rfl
  split <;> rfl

theorem recordPushCompletion_done_mono (pol : UnregisterPolicy) (ok : Bool) (r : Send)
    (hd : r.life.done = true) :
    (Send.recordPushCompletion pol ok r).life.done = true := by
  unfold Send.recordPushCompletion
  simp [hd]

theorem send_step_published_ne_none {pol : UnregisterPolicy} {r r' : Send} {e : Send.Ev}
    (hs : Send.step pol r e = some r') (hpub : r.published ≠ none) :
    r'.published ≠ none := by
  cases e with
  | d2hIssue p ok =>
    simp only [Send.step, Send.d2hIssue] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs <;> { cases hs; simpa using hpub }
  | execFinish =>
    simp only [Send.step, Send.execFinish] at hs
    split at hs <;> try cases hs
    simpa using hpub
  | d2hDone p ok =>
    simp only [Send.step, Send.d2hDone] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs
    · cases hs; simpa using hpub
    · split at hs <;> { cases hs; simpa using hpub }
  | pushDone p ok =>
    simp only [Send.step, Send.pushDone] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    simpa using hpub
  | cancel =>
    simp only [Send.step, Send.cancel, Option.some.injEq] at hs
    subst hs; exact hpub
  | publish =>
    simp only [Send.step, Send.publish] at hs
    split at hs <;> try cases hs
    simp

theorem send_step_done_mono {pol : UnregisterPolicy} {r r' : Send} {e : Send.Ev}
    (hs : Send.step pol r e = some r') (hd : r.life.done = true) :
    r'.life.done = true := by
  cases e with
  | d2hIssue p ok =>
    simp only [Send.step, Send.d2hIssue] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs
    · cases hs; exact hd
    · cases hs
      exact Lifecycle.endOpLocked_done_mono (recordPushCompletion_done_mono pol false _ hd)
  | execFinish =>
    simp only [Send.step, Send.execFinish] at hs
    split at hs <;> try cases hs
    exact Lifecycle.endOpLocked_done_mono hd
  | d2hDone p ok =>
    simp only [Send.step, Send.d2hDone] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs
    · cases hs
      exact Lifecycle.endOpLocked_done_mono (recordPushCompletion_done_mono pol false _ hd)
    · split at hs <;> { cases hs; exact Lifecycle.endOpLocked_done_mono hd }
  | pushDone p ok =>
    simp only [Send.step, Send.pushDone] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    exact Lifecycle.endOpLocked_done_mono (recordPushCompletion_done_mono pol ok _ hd)
  | cancel =>
    simp only [Send.step, Send.cancel, Option.some.injEq] at hs
    subst hs; exact Lifecycle.finishLocked_done_mono false hd
  | publish =>
    simp only [Send.step, Send.publish] at hs
    split at hs <;> try cases hs
    exact hd

theorem send_poolOps_pos_of_stage {ps : List SendPool} {p : Nat} {pool : SendPool}
    (hget : ps[p]? = some pool) (hop : 0 < pool.stage.opCount) :
    0 < Send.poolOps ps := by
  have ⟨_, hle⟩ := Send.poolOps_set pool.stage hget
  omega

theorem send_not_done_of_stage {r : Send} (h : Send.Inv .shipping r) {p : Nat} {pool : SendPool}
    (hget : r.pools[p]? = some pool) (hop : 0 < pool.stage.opCount) :
    r.life.done = false := by
  have hpo := send_poolOps_pos_of_stage hget hop
  have hacc := h.accounted; unfold Send.Accounted at hacc
  cases hd : r.life.done
  · rfl
  · have := h.life.done_idle hd; omega

theorem launchPass_length (canLaunch : Nat → Bool) :
    ∀ ps : List Pool, (Recv.launchPass canLaunch ps).1.length = ps.length
  | [] => rfl
  | _ :: ps => by
    simp only [Recv.launchPass]
    split <;> simp [launchPass_length canLaunch ps]

theorem launchPass_getElem? (canLaunch : Nat → Bool) :
    ∀ (ps : List Pool) (q : Nat) (pool' : Pool),
      (Recv.launchPass canLaunch ps).1[q]? = some pool' →
        ∃ pool, ps[q]? = some pool ∧ pool'.rank = pool.rank ∧
          (pool'.stage = .waiting ↔ pool.stage = .waiting) ∧
          (pool'.stage = .completed ↔ pool.stage = .completed)
  | [], _, _, h => by simp [Recv.launchPass] at h
  | p :: _, 0, pool', h => by
    simp only [Recv.launchPass] at h
    split at h
    · rename_i hc
      have hst : p.stage = .received := by
        simp only [Bool.and_eq_true, beq_iff_eq] at hc; exact hc.1
      simp only [List.getElem?_cons_zero, Option.some.injEq] at h
      subst h
      exact ⟨p, rfl, rfl, by simp [hst], by simp [hst]⟩
    · simp only [List.getElem?_cons_zero, Option.some.injEq] at h
      subst h
      exact ⟨p, rfl, rfl, Iff.rfl, Iff.rfl⟩
  | _ :: ps, q + 1, pool', h => by
    simp only [Recv.launchPass] at h
    split at h <;> {
      simp only [List.getElem?_cons_succ] at h
      exact launchPass_getElem? canLaunch ps q pool' h
    }

@[simp] theorem launchEligible_pools_length (r : Recv) :
    (Recv.launchEligible r).pools.length = r.pools.length := by
  unfold Recv.launchEligible
  split
  · rfl
  · exact launchPass_length _ r.pools

@[simp] theorem launchEligible_done (r : Recv) :
    (Recv.launchEligible r).life.done = r.life.done := by
  unfold Recv.launchEligible
  split <;> rfl

@[simp] theorem launchEligible_pushes (r : Recv) :
    (Recv.launchEligible r).pushes = r.pushes := by
  unfold Recv.launchEligible
  split <;> rfl

theorem launchEligible_getElem? {r : Recv} {q : Nat} {pool' : Pool}
    (h : (Recv.launchEligible r).pools[q]? = some pool') :
    ∃ pool, r.pools[q]? = some pool ∧ pool'.rank = pool.rank ∧
      (pool'.stage = .waiting ↔ pool.stage = .waiting) ∧
      (pool'.stage = .completed ↔ pool.stage = .completed) := by
  unfold Recv.launchEligible at h
  split at h
  · exact ⟨pool', h, rfl, Iff.rfl, Iff.rfl⟩
  · exact launchPass_getElem? _ r.pools q pool' h

theorem recv_step_pools_length {pol : PushEndPolicy} {r r' : Recv} {e : Recv.Ev}
    (hs : Recv.step pol r e = some r') : r'.pools.length = r.pools.length := by
  cases e with
  | pushBegin =>
    simp only [Recv.step, Recv.pushBegin, Option.map_eq_some_iff] at hs
    obtain ⟨_, _, rfl⟩ := hs; rfl
  | pushEnd ok =>
    simp only [Recv.step, Recv.pushEnd] at hs
    split at hs <;> try cases hs
    simp
  | onPoolReceived p =>
    simp only [Recv.step, Recv.onPoolReceived] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    simp
  | h2dIssue p ok =>
    simp only [Recv.step, Recv.h2dIssue] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs
    · cases hs; simp
    · split at hs <;> { cases hs; simp }
  | h2dReady p =>
    simp only [Recv.step, Recv.h2dReady] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    simp
  | h2dDone p ok =>
    simp only [Recv.step, Recv.h2dDone] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs
    · cases hs; simp
    · split at hs
      · cases hs; simp
      · split at hs
        · cases hs; simp
        · split at hs <;> { cases hs; simp }
  | pollReady =>
    simp only [Recv.step, Recv.pollReady] at hs
    split at hs <;> try cases hs
    rfl
  | cancel =>
    simp only [Recv.step, Recv.cancel, Option.some.injEq] at hs
    subst hs; rfl
  | publish =>
    simp only [Recv.step, Recv.publish] at hs
    split at hs <;> try cases hs
    rfl

theorem recv_step_done_mono {pol : PushEndPolicy} {r r' : Recv} {e : Recv.Ev}
    (hs : Recv.step pol r e = some r') (hd : r.life.done = true) :
    r'.life.done = true := by
  cases e with
  | pushBegin =>
    simp only [Recv.step, Recv.pushBegin, Option.map_eq_some_iff] at hs
    obtain ⟨l, hb, _⟩ := hs
    have hact := Lifecycle.beginOp_active hb
    simp [hd] at hact
  | pushEnd ok =>
    simp only [Recv.step, Recv.pushEnd] at hs
    split at hs <;> try cases hs
    simp only [Recv.maybeUnregisterSettled_life]
    apply Lifecycle.endOpLocked_done_mono
    split <;> simp [hd, Lifecycle.finishLocked_done_mono]
  | onPoolReceived p =>
    simp only [Recv.step, Recv.onPoolReceived] at hs
    split at hs <;> try cases hs
    split at hs
    · cases hs
    · rename_i hact; exfalso; exact hact (Or.inl hd)
  | h2dIssue p ok =>
    simp only [Recv.step, Recv.h2dIssue] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs
    · cases hs; exact Lifecycle.endOpLocked_done_mono hd
    · rename_i hact; exfalso; exact hact (Or.inl hd)
  | h2dReady p =>
    simp only [Recv.step, Recv.h2dReady] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    exact hd
  | h2dDone p ok =>
    simp only [Recv.step, Recv.h2dDone, hd, ↓reduceIte] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    simp [Lifecycle.endOpLocked_done_mono hd]
  | pollReady =>
    simp only [Recv.step, Recv.pollReady] at hs
    split at hs <;> try cases hs
    exact Lifecycle.finishLocked_done_mono true hd
  | cancel =>
    simp only [Recv.step, Recv.cancel, Option.some.injEq] at hs
    subst hs; exact Lifecycle.finishLocked_done_mono false hd
  | publish =>
    simp only [Recv.step, Recv.publish] at hs
    split at hs <;> try cases hs
    exact hd

theorem recv_not_done_of_ready {r : Recv} (h : Recv.Inv r) {p : Nat} {pool : Pool}
    (hget : r.pools[p]? = some pool) (hrd : pool.stage = .ready) :
    r.life.done = false := by
  have ⟨_, hpos⟩ := Recv.poolOps_set_drop hget (p' := { pool with stage := .aborted })
    (by simp [hrd, PoolStage.holdsOp]) rfl
  have hacc := h.accounted; unfold Recv.Accounted at hacc
  cases hd : r.life.done
  · rfl
  · have := h.life.done_idle hd; omega

/-! ### Per-event invariant preservation -/

theorem step_armRecv_inv {s s' : Pipeline} (h : Inv s) (hs : s.armRecv = some s') :
    Inv s' := by
  simp only [armRecv] at hs
  split at hs <;> try cases hs
  exact ⟨h.sendInv, h.recvInv, h.num_pos, h.len_peers, h.len_send, h.len_recv,
    h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
    h.len_sent, h.len_landed, h.peers_match, h.srcHbm_ok, h.reclaimed_pub,
    h.srcStg_ok, h.sent_bound, h.wire_ok, h.landed_le_sent,
    h.dstStg_ok, h.recv_stage_landed, h.done_intact,
    fun ha => by simp at ha, fun ha => by simp at ha⟩

theorem step_reclaim_inv {s s' : Pipeline} (h : Inv s) (hs : s.reclaim = some s') :
    Inv s' := by
  simp only [reclaim] at hs
  split at hs <;> try cases hs
  rename_i hc
  exact ⟨h.sendInv, h.recvInv, h.num_pos, h.len_peers, h.len_send, h.len_recv,
    by simp, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
    h.len_sent, h.len_landed, h.peers_match,
    fun hr => by simp at hr, fun _ => hc.1,
    h.srcStg_ok, h.sent_bound, h.wire_ok, h.landed_le_sent,
    h.dstStg_ok, h.recv_stage_landed, h.done_intact,
    h.unarmed_send, h.unarmed_recv⟩

theorem step_reseatSrcStaging_inv {s s' : Pipeline} (h : Inv s)
    (hs : s.reseatSrcStaging = some s') : Inv s' := by
  simp only [reseatSrcStaging] at hs
  split at hs <;> try cases hs
  rename_i hst
  have hd : s.send.life.done = true := by
    rw [h.sendInv.life.staging] at hst; simpa using hst
  exact ⟨h.sendInv, h.recvInv, h.num_pos, h.len_peers, h.len_send, h.len_recv,
    h.len_srcHbm, by simp, h.len_wire, h.len_dstStg, h.len_dstHbm,
    h.len_sent, h.len_landed, h.peers_match, h.srcHbm_ok, h.reclaimed_pub,
    fun hnd => by simp [hd] at hnd, h.sent_bound, h.wire_ok, h.landed_le_sent,
    h.dstStg_ok, h.recv_stage_landed, h.done_intact,
    h.unarmed_send, h.unarmed_recv⟩

theorem step_reseatDstStaging_inv {s s' : Pipeline} (h : Inv s)
    (hs : s.reseatDstStaging = some s') : Inv s' := by
  simp only [reseatDstStaging] at hs
  split at hs <;> try cases hs
  rename_i hst
  have hd : s.recv.life.done = true := by
    rw [h.recvInv.life.staging] at hst; simpa using hst
  exact ⟨h.sendInv, h.recvInv, h.num_pos, h.len_peers, h.len_send, h.len_recv,
    h.len_srcHbm, h.len_srcStg, h.len_wire, by simp, h.len_dstHbm,
    h.len_sent, h.len_landed, h.peers_match, h.srcHbm_ok, h.reclaimed_pub,
    h.srcStg_ok, h.sent_bound, h.wire_ok, h.landed_le_sent,
    fun hnd => by simp [hd] at hnd, h.recv_stage_landed, h.done_intact,
    h.unarmed_send, h.unarmed_recv⟩

theorem step_landStream_inv {s s' : Pipeline} {p : Nat} (h : Inv s)
    (hs : s.landStream p = some s') : Inv s' := by
  simp only [landStream] at hs
  split at hs <;> try cases hs
  rename_i hpush
  split at hs <;> try cases hs
  rename_i k m c hlk hsm hwc
  split at hs <;> try cases hs
  rename_i hkm
  obtain ⟨hlt_km, _⟩ := hkm
  have hlen_l := h.len_landed
  have hlen_dst := h.len_dstStg
  have hp : p < s.numPools := by
    have := lt_length_of_getElem?_eq hlk
    omega
  have hsm_d : s.sentStreams.getD p 0 = m := by
    rw [List.getD_eq_getElem?_getD, hsm]; rfl
  have hlk_d : s.landedStreams.getD p 0 = k := by
    rw [List.getD_eq_getElem?_getD, hlk]; rfl
  have hc_kv : c = .kv p := by
    have hw := h.wire_ok p hp (by omega)
    rw [hwc] at hw; exact Option.some.inj hw
  subst hc_kv
  refine ⟨h.sendInv, h.recvInv, h.num_pos, h.len_peers, h.len_send, h.len_recv,
    h.len_srcHbm, h.len_srcStg, h.len_wire, by simp [h.len_dstStg], h.len_dstHbm,
    h.len_sent, by simp [h.len_landed], h.peers_match, h.srcHbm_ok, h.reclaimed_pub,
    h.srcStg_ok, h.sent_bound, h.wire_ok, ?_, ?_, ?_, h.done_intact,
    h.unarmed_send, fun ha => by have := (h.unarmed_recv ha).1; omega⟩
  · intro q hq
    by_cases hqp : p = q
    · subst hqp
      rw [getD_set_self (by omega), hsm_d]
      omega
    · rw [getD_set_ne (by omega)]
      exact h.landed_le_sent q hq
  · intro hnd q hq hgt
    by_cases hqp : p = q
    · subst hqp
      exact List.getElem?_set_self (by omega)
    · rw [List.getElem?_set_ne hqp]
      rw [getD_set_ne (by omega)] at hgt
      exact h.dstStg_ok hnd q hq hgt
  · intro q hq pool hget hne
    have hprev := h.recv_stage_landed q hq pool hget hne
    by_cases hqp : p = q
    · subst hqp
      have hlt_s : p < s.send.pools.length := by rw [h.len_send]; exact hp
      have hsget : s.send.pools[p]? = some s.send.pools[p] := List.getElem?_eq_getElem hlt_s
      have hpe := h.peers_match p hp s.send.pools[p] hsget
      have hbnd := h.sent_bound p hp s.send.pools[p] hsget
      omega
    · rw [getD_set_ne (by omega)]
      exact hprev

theorem step_send_inv {s s' : Pipeline} {e : Send.Ev} (h : Inv s)
    (hs : s.sendStep e = some s') : Inv s' := by
  have hlen_s := h.len_send
  have hlen_srcStg := h.len_srcStg
  have hlen_w := h.len_wire
  have hlen_sent := h.len_sent
  rcases e with ⟨p, ok⟩ | _ | ⟨p, ok⟩ | ⟨p, ok⟩ | _ | _
  · simp only [sendStep] at hs
    split at hs <;> try cases hs
    rename_i hguard
    simp only [Option.map_eq_some_iff] at hs
    obtain ⟨snd, hsnd, rfl⟩ := hs
    have hsndInv := Send.step_inv .shipping h.sendInv hsnd
    have hpub_m : s.send.published ≠ none → snd.published ≠ none :=
      send_step_published_ne_none hsnd
    have hdone_m : snd.life.done = false → s.send.life.done = false := by
      intro hnd; cases hd : s.send.life.done
      · rfl
      · have := send_step_done_mono hsnd hd; simp [hnd] at this
    simp only [Send.step, Send.d2hIssue] at hsnd
    split at hsnd <;> try cases hsnd
    split at hsnd <;> try cases hsnd
    rename_i pool hget
    split at hsnd <;> try cases hsnd
    rename_i hpend
    simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hpend
    have hp_lt : p < s.send.pools.length := lt_length_of_getElem?_eq hget
    have hlen' : snd.pools.length = s.numPools := by
      split at hsnd <;> { cases hsnd; simp [h.len_send] }
    have hset : snd.pools = s.send.pools.set p { pool with stage := if ok then .d2h else .aborted } := by
      split at hsnd <;> { rename_i hok; cases hsnd; simp [hok] }
    refine ⟨hsndInv, h.recvInv, h.num_pos, h.len_peers, hlen', h.len_recv,
      h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
      h.len_sent, h.len_landed, ?_, h.srcHbm_ok, fun hr => hpub_m (h.reclaimed_pub hr),
      ?_, ?_, h.wire_ok, h.landed_le_sent, h.dstStg_ok, h.recv_stage_landed,
      h.done_intact, ?_, h.unarmed_recv⟩
    · intro q hq pool' hget'
      rw [hset] at hget'
      by_cases hpq : p = q
      · subst hpq
        rw [List.getElem?_set_self hp_lt] at hget'
        cases hget'; exact h.peers_match p hq pool hget
      · rw [List.getElem?_set_ne hpq] at hget'
        exact h.peers_match q hq pool' hget'
    · intro hnd q hq pool' hget' ⟨k, hk⟩
      rw [hset] at hget'
      by_cases hpq : p = q
      · subst hpq
        rw [List.getElem?_set_self hp_lt] at hget'
        cases hget'
        cases ok <;> simp at hk
      · rw [List.getElem?_set_ne hpq] at hget'
        exact h.srcStg_ok (hdone_m hnd) q hq pool' hget' ⟨k, hk⟩
    · intro q hq pool' hget'
      rw [hset] at hget'
      by_cases hpq : p = q
      · subst hpq
        rw [List.getElem?_set_self hp_lt] at hget'
        cases hget'
        have hb := h.sent_bound p hq pool hget
        cases ok <;> simp only [SendPool.remainingSlots, hpend, ↓reduceIte, Bool.false_eq_true] at hb ⊢ <;> omega
      · rw [List.getElem?_set_ne hpq] at hget'
        exact h.sent_bound q hq pool' hget'
    · intro ha q hq pool' hget'
      rw [hset] at hget'
      by_cases hpq : p = q
      · subst hpq
        rw [List.getElem?_set_self hp_lt] at hget'
        cases hget'
        rcases hguard with hok | harm
        · simp [hok]
        · rw [ha] at harm; cases harm
      · rw [List.getElem?_set_ne hpq] at hget'
        exact h.unarmed_send ha q hq pool' hget'
  · simp only [sendStep, Option.map_eq_some_iff] at hs
    obtain ⟨snd, hsnd, rfl⟩ := hs
    have hsndInv := Send.step_inv .shipping h.sendInv hsnd
    have hpub_m : s.send.published ≠ none → snd.published ≠ none :=
      send_step_published_ne_none hsnd
    have hdone_m : snd.life.done = false → s.send.life.done = false := by
      intro hnd; cases hd : s.send.life.done
      · rfl
      · have := send_step_done_mono hsnd hd; simp [hnd] at this
    have hpools_eq : snd.pools = s.send.pools := by
      simp only [Send.step, Send.execFinish] at hsnd
      split at hsnd <;> simp at hsnd; subst hsnd; rfl
    refine ⟨hsndInv, h.recvInv, h.num_pos, h.len_peers, by rw [hpools_eq]; exact h.len_send,
      h.len_recv, h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
      h.len_sent, h.len_landed, by rw [hpools_eq]; exact h.peers_match,
      h.srcHbm_ok, fun hr => hpub_m (h.reclaimed_pub hr),
      fun hnd => by rw [hpools_eq]; exact h.srcStg_ok (hdone_m hnd),
      by rw [hpools_eq]; exact h.sent_bound,
      h.wire_ok, h.landed_le_sent, h.dstStg_ok, h.recv_stage_landed,
      h.done_intact, fun ha => by rw [hpools_eq]; exact h.unarmed_send ha, h.unarmed_recv⟩
  · simp only [sendStep, Option.map_eq_some_iff] at hs
    obtain ⟨snd, hsnd, hs'⟩ := hs
    have hsndInv := Send.step_inv .shipping h.sendInv hsnd
    have hpub_m : s.send.published ≠ none → snd.published ≠ none :=
      send_step_published_ne_none hsnd
    have hdone_m : snd.life.done = false → s.send.life.done = false := by
      intro hnd; cases hd : s.send.life.done
      · rfl
      · have := send_step_done_mono hsnd hd; simp [hnd] at this
    have hsnd_step := hsnd
    simp only [Send.step, Send.d2hDone] at hsnd_step
    split at hsnd_step <;> try cases hsnd_step
    rename_i pool hget
    split at hsnd_step <;> try cases hsnd_step
    rename_i hd2h
    simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hd2h
    have hp_lt : p < s.send.pools.length := lt_length_of_getElem?_eq hget
    have hp : p < s.numPools := by omega
    have hnd_s : s.send.life.done = false :=
      send_not_done_of_stage h.sendInv hget (by simp [hd2h, SendStage.opCount])
    have hrec_f : s.reclaimed = false := by
      cases hr : s.reclaimed
      · rfl
      · have hpub := h.reclaimed_pub hr
        cases hb : s.send.published with
        | none => exact absurd hb hpub
        | some b =>
          have hd := h.sendInv.published_done b hb
          simp [hnd_s] at hd
    have hsrc_good : s.srcHbm = good s.numPools := h.srcHbm_ok hrec_f
    have harm_t : s.armed = true := by
      cases ha : s.armed
      · rcases h.unarmed_send ha p hp pool hget with hst | hst <;> simp [hd2h] at hst
      · rfl
    have hpools : ∃ st', snd.pools = s.send.pools.set p { pool with stage := st' } ∧
        (ok = false → st' = .aborted) ∧
        (ok = true → st' = .aborted ∨ st' = .pushing pool.peers) := by
      split at hsnd_step
      · rename_i hnok
        cases hsnd_step
        exact ⟨.aborted, by simp, fun _ => rfl, fun hok => by subst hok; cases hnok⟩
      · rename_i hnok
        split at hsnd_step
        · cases hsnd_step
          exact ⟨.aborted, by simp, fun _ => rfl, fun _ => Or.inl rfl⟩
        · cases hsnd_step
          exact ⟨.pushing pool.peers, by simp, fun hok_f => by subst hok_f; simp at hnok, fun _ => Or.inr rfl⟩
    obtain ⟨st', hset, hst_f, hst_t⟩ := hpools
    cases ok with
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at hs'
      subst hs'
      have hst_ab : st' = .aborted := hst_f rfl
      subst hst_ab
      refine ⟨hsndInv, h.recvInv, h.num_pos, h.len_peers, by simp [hset, h.len_send], h.len_recv,
        h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
        h.len_sent, h.len_landed, ?_, h.srcHbm_ok, fun hr => hpub_m (h.reclaimed_pub hr),
        ?_, ?_, h.wire_ok, h.landed_le_sent, h.dstStg_ok, h.recv_stage_landed,
        h.done_intact, fun ha => by simp [harm_t] at ha, h.unarmed_recv⟩
      · intro q hq pool' hget'
        rw [hset] at hget'
        by_cases hpq : p = q
        · subst hpq
          rw [List.getElem?_set_self hp_lt] at hget'
          cases hget'; exact h.peers_match p hq pool hget
        · rw [List.getElem?_set_ne hpq] at hget'
          exact h.peers_match q hq pool' hget'
      · intro hnd q hq pool' hget' ⟨k, hk⟩
        rw [hset] at hget'
        by_cases hpq : p = q
        · subst hpq
          rw [List.getElem?_set_self hp_lt] at hget'
          cases hget'; simp at hk
        · rw [List.getElem?_set_ne hpq] at hget'
          exact h.srcStg_ok (hdone_m hnd) q hq pool' hget' ⟨k, hk⟩
      · intro q hq pool' hget'
        rw [hset] at hget'
        by_cases hpq : p = q
        · subst hpq
          rw [List.getElem?_set_self hp_lt] at hget'
          cases hget'
          have hb := h.sent_bound p hq pool hget
          simp only [SendPool.remainingSlots, hd2h] at hb ⊢; omega
        · rw [List.getElem?_set_ne hpq] at hget'
          exact h.sent_bound q hq pool' hget'
    | true =>
      simp only [↓reduceIte] at hs'
      subst hs'
      refine ⟨hsndInv, h.recvInv, h.num_pos, h.len_peers, by simp [hset, h.len_send], h.len_recv,
        h.len_srcHbm, by simp [h.len_srcStg], h.len_wire, h.len_dstStg, h.len_dstHbm,
        h.len_sent, h.len_landed, ?_, h.srcHbm_ok, fun hr => hpub_m (h.reclaimed_pub hr),
        ?_, ?_, h.wire_ok, h.landed_le_sent, h.dstStg_ok, h.recv_stage_landed,
        h.done_intact, fun ha => by simp [harm_t] at ha, h.unarmed_recv⟩
      · intro q hq pool' hget'
        rw [hset] at hget'
        by_cases hpq : p = q
        · subst hpq
          rw [List.getElem?_set_self hp_lt] at hget'
          cases hget'; exact h.peers_match p hq pool hget
        · rw [List.getElem?_set_ne hpq] at hget'
          exact h.peers_match q hq pool' hget'
      · intro hnd q hq pool' hget' ⟨k, hk⟩
        rw [hset] at hget'
        by_cases hpq : p = q
        · subst hpq
          rw [List.getElem?_set_self (by omega), hsrc_good, getD_good hp]
        · rw [List.getElem?_set_ne hpq] at hget' ⊢
          exact h.srcStg_ok (hdone_m hnd) q hq pool' hget' ⟨k, hk⟩
      · intro q hq pool' hget'
        rw [hset] at hget'
        by_cases hpq : p = q
        · subst hpq
          rw [List.getElem?_set_self hp_lt] at hget'
          cases hget'
          have hb := h.sent_bound p hq pool hget
          rcases hst_t rfl with rfl | rfl <;>
            simp only [SendPool.remainingSlots, hd2h] at hb ⊢ <;> omega
        · rw [List.getElem?_set_ne hpq] at hget'
          exact h.sent_bound q hq pool' hget'
  · simp only [sendStep, Option.map_eq_some_iff] at hs
    obtain ⟨snd, hsnd, hs'⟩ := hs
    have hsndInv := Send.step_inv .shipping h.sendInv hsnd
    have hpub_m : s.send.published ≠ none → snd.published ≠ none :=
      send_step_published_ne_none hsnd
    have hdone_m : snd.life.done = false → s.send.life.done = false := by
      intro hnd; cases hd : s.send.life.done
      · rfl
      · have := send_step_done_mono hsnd hd; simp [hnd] at this
    have hsnd_step := hsnd
    simp only [Send.step, Send.pushDone] at hsnd_step
    split at hsnd_step <;> try cases hsnd_step
    rename_i pool hget
    split at hsnd_step <;> try cases hsnd_step
    rename_i k hpush
    have hp_lt : p < s.send.pools.length := lt_length_of_getElem?_eq hget
    have hp : p < s.numPools := by omega
    have hnd_s : s.send.life.done = false :=
      send_not_done_of_stage h.sendInv hget (by simp [hpush, SendStage.opCount])
    have harm_t : s.armed = true := by
      cases ha : s.armed
      · rcases h.unarmed_send ha p hp pool hget with hst | hst <;> simp [hpush] at hst
      · rfl
    have hstg_kv : s.srcStaging.getD p .junk = .kv p := by
      have h1 := h.srcStg_ok hnd_s p hp pool hget ⟨k + 1, hpush⟩
      rw [List.getD_eq_getElem?_getD, h1]; rfl
    cases ok with
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at hs'
      subst hs'
      refine ⟨hsndInv, h.recvInv, h.num_pos, h.len_peers, by simp [h.len_send], h.len_recv,
        h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
        h.len_sent, h.len_landed, ?_, h.srcHbm_ok, fun hr => hpub_m (h.reclaimed_pub hr),
        ?_, ?_, h.wire_ok, h.landed_le_sent, h.dstStg_ok, h.recv_stage_landed,
        h.done_intact, fun ha => by simp [harm_t] at ha, h.unarmed_recv⟩
      · intro q hq pool' hget'
        simp only [endOp_pools, recordPushCompletion_pools] at hget'
        by_cases hpq : p = q
        · subst hpq
          rw [List.getElem?_set_self hp_lt] at hget'
          cases hget'; exact h.peers_match p hq pool hget
        · rw [List.getElem?_set_ne hpq] at hget'
          exact h.peers_match q hq pool' hget'
      · intro hnd q hq pool' hget' ⟨m, hm⟩
        simp only [endOp_pools, recordPushCompletion_pools] at hget'
        by_cases hpq : p = q
        · subst hpq
          exact h.srcStg_ok hnd_s p hq pool hget ⟨k + 1, hpush⟩
        · rw [List.getElem?_set_ne hpq] at hget'
          exact h.srcStg_ok hnd_s q hq pool' hget' ⟨m, hm⟩
      · intro q hq pool' hget'
        simp only [endOp_pools, recordPushCompletion_pools] at hget'
        by_cases hpq : p = q
        · subst hpq
          rw [List.getElem?_set_self hp_lt] at hget'
          cases hget'
          have hb := h.sent_bound p hq pool hget
          simp only [SendPool.remainingSlots, hpush] at hb ⊢; omega
        · rw [List.getElem?_set_ne hpq] at hget'
          exact h.sent_bound q hq pool' hget'
    | true =>
      simp only [↓reduceIte] at hs'
      subst hs'
      refine ⟨hsndInv, h.recvInv, h.num_pos, h.len_peers, by simp [h.len_send], h.len_recv,
        h.len_srcHbm, h.len_srcStg, by simp [h.len_wire], h.len_dstStg, h.len_dstHbm,
        by simp [h.len_sent], h.len_landed, ?_, h.srcHbm_ok, fun hr => hpub_m (h.reclaimed_pub hr),
        ?_, ?_, ?_, ?_, h.dstStg_ok, h.recv_stage_landed,
        h.done_intact, fun ha => by simp [harm_t] at ha, h.unarmed_recv⟩
      · intro q hq pool' hget'
        simp only [endOp_pools, recordPushCompletion_pools] at hget'
        by_cases hpq : p = q
        · subst hpq
          rw [List.getElem?_set_self hp_lt] at hget'
          cases hget'; exact h.peers_match p hq pool hget
        · rw [List.getElem?_set_ne hpq] at hget'
          exact h.peers_match q hq pool' hget'
      · intro hnd q hq pool' hget' ⟨m, hm⟩
        simp only [endOp_pools, recordPushCompletion_pools] at hget'
        by_cases hpq : p = q
        · subst hpq
          exact h.srcStg_ok hnd_s p hq pool hget ⟨k + 1, hpush⟩
        · rw [List.getElem?_set_ne hpq] at hget'
          exact h.srcStg_ok hnd_s q hq pool' hget' ⟨m, hm⟩
      · intro q hq pool' hget'
        simp only [endOp_pools, recordPushCompletion_pools] at hget'
        by_cases hpq : p = q
        · subst hpq
          rw [List.getElem?_set_self hp_lt] at hget'
          cases hget'
          have hb := h.sent_bound p hq pool hget
          rw [getD_set_self (by omega)]
          simp only [SendPool.remainingSlots, hpush] at hb ⊢; omega
        · rw [List.getElem?_set_ne hpq] at hget'
          rw [getD_set_ne (by omega)]
          exact h.sent_bound q hq pool' hget'
      · intro q hq hgt
        by_cases hpq : p = q
        · subst hpq
          rw [List.getElem?_set_self (by omega), hstg_kv]
        · rw [List.getElem?_set_ne hpq]
          rw [getD_set_ne (by omega)] at hgt
          exact h.wire_ok q hq hgt
      · intro q hq
        have hle := h.landed_le_sent q hq
        dsimp only
        by_cases hpq : p = q
        · subst hpq
          rw [getD_set_self (by omega)]; omega
        · rw [getD_set_ne (by omega)]; exact hle
  · simp only [sendStep, Option.map_eq_some_iff] at hs
    obtain ⟨snd, hsnd, rfl⟩ := hs
    have hsndInv := Send.step_inv .shipping h.sendInv hsnd
    have hpub_m : s.send.published ≠ none → snd.published ≠ none :=
      send_step_published_ne_none hsnd
    have hdone_m : snd.life.done = false → s.send.life.done = false := by
      intro hnd; cases hd : s.send.life.done
      · rfl
      · have := send_step_done_mono hsnd hd; simp [hnd] at this
    have hpools_eq : snd.pools = s.send.pools := by
      simp only [Send.step, Send.cancel] at hsnd
      cases hsnd; rfl
    refine ⟨hsndInv, h.recvInv, h.num_pos, h.len_peers, by rw [hpools_eq]; exact h.len_send,
      h.len_recv, h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
      h.len_sent, h.len_landed, by rw [hpools_eq]; exact h.peers_match,
      h.srcHbm_ok, fun hr => hpub_m (h.reclaimed_pub hr),
      fun hnd => by rw [hpools_eq]; exact h.srcStg_ok (hdone_m hnd),
      by rw [hpools_eq]; exact h.sent_bound,
      h.wire_ok, h.landed_le_sent, h.dstStg_ok, h.recv_stage_landed,
      h.done_intact, fun ha => by rw [hpools_eq]; exact h.unarmed_send ha, h.unarmed_recv⟩
  · simp only [sendStep, Option.map_eq_some_iff] at hs
    obtain ⟨snd, hsnd, rfl⟩ := hs
    have hsndInv := Send.step_inv .shipping h.sendInv hsnd
    have hpub_m : s.send.published ≠ none → snd.published ≠ none :=
      send_step_published_ne_none hsnd
    have hdone_m : snd.life.done = false → s.send.life.done = false := by
      intro hnd; cases hd : s.send.life.done
      · rfl
      · have := send_step_done_mono hsnd hd; simp [hnd] at this
    have hpools_eq : snd.pools = s.send.pools := by
      simp only [Send.step, Send.publish] at hsnd
      split at hsnd <;> simp at hsnd; subst hsnd; rfl
    refine ⟨hsndInv, h.recvInv, h.num_pos, h.len_peers, by rw [hpools_eq]; exact h.len_send,
      h.len_recv, h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
      h.len_sent, h.len_landed, by rw [hpools_eq]; exact h.peers_match,
      h.srcHbm_ok, fun hr => hpub_m (h.reclaimed_pub hr),
      fun hnd => by rw [hpools_eq]; exact h.srcStg_ok (hdone_m hnd),
      by rw [hpools_eq]; exact h.sent_bound,
      h.wire_ok, h.landed_le_sent, h.dstStg_ok, h.recv_stage_landed,
      h.done_intact, fun ha => by rw [hpools_eq]; exact h.unarmed_send ha, h.unarmed_recv⟩

theorem h2dDone_pools_shape {r r' : Recv} {p : Nat} {ok : Bool}
    (hs : Recv.h2dDone p ok r = some r') :
    ∃ pool st, r.pools[p]? = some pool ∧ pool.stage = .ready ∧
      (st = .aborted ∨ (ok = true ∧ st = .completed)) ∧
      (r'.pools = r.pools.set p { pool with stage := st } ∨
       r'.pools = (Recv.launchEligible { r with pools := r.pools.set p { pool with stage := st } }).pools) := by
  simp only [Recv.h2dDone] at hs
  split at hs <;> try cases hs
  rename_i pool hget
  split at hs <;> try cases hs
  rename_i hrd
  simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hrd
  split at hs
  · cases hs
    exact ⟨pool, .aborted, hget, hrd, Or.inl rfl, Or.inl (by simp)⟩
  · split at hs
    · cases hs
      exact ⟨pool, .aborted, hget, hrd, Or.inl rfl, Or.inl (by simp)⟩
    · split at hs
      · cases hs
        exact ⟨pool, .aborted, hget, hrd, Or.inl rfl, Or.inl (by simp)⟩
      · rename_i hnot_nok
        have hok : ok = true := by cases ok <;> simp at hnot_nok ⊢
        split at hs
        · cases hs
          exact ⟨pool, .completed, hget, hrd, Or.inr ⟨hok, rfl⟩, Or.inl (by simp)⟩
        · cases hs
          exact ⟨pool, .completed, hget, hrd, Or.inr ⟨hok, rfl⟩, Or.inr (by simp)⟩

theorem h2dDone_getElem? {r r' : Recv} {p q : Nat} {ok : Bool} {pool' : Pool}
    (hs : Recv.h2dDone p ok r = some r') (hget' : r'.pools[q]? = some pool') :
    (∃ pool, r.pools[p]? = some pool ∧ pool.stage = .ready ∧ p = q ∧
      (pool'.stage = .completed → ok = true)) ∨
    (p ≠ q ∧ ∃ pool_q, r.pools[q]? = some pool_q ∧
      (pool'.stage = .waiting ↔ pool_q.stage = .waiting) ∧
      (pool'.stage = .completed ↔ pool_q.stage = .completed)) := by
  obtain ⟨pool, st, hget, hrd, hst, hshape⟩ := h2dDone_pools_shape hs
  have hp_lt : p < r.pools.length := lt_length_of_getElem?_eq hget
  have hmid : ∃ pool₁, (r.pools.set p { pool with stage := st })[q]? = some pool₁ ∧
      (pool'.stage = .waiting ↔ pool₁.stage = .waiting) ∧
      (pool'.stage = .completed ↔ pool₁.stage = .completed) := by
    rcases hshape with h1 | h2
    · rw [h1] at hget'
      exact ⟨pool', hget', Iff.rfl, Iff.rfl⟩
    · rw [h2] at hget'
      obtain ⟨pool₁, hget₁, _, hw, hc⟩ := launchEligible_getElem? hget'
      exact ⟨pool₁, hget₁, hw, hc⟩
  obtain ⟨pool₁, hget₁, hw, hc⟩ := hmid
  by_cases hpq : p = q
  · subst hpq
    rw [List.getElem?_set_self hp_lt, Option.some.injEq] at hget₁
    subst hget₁
    refine Or.inl ⟨pool, hget, hrd, rfl, fun hcomp => ?_⟩
    have hst_c : st = .completed := hc.mp hcomp
    rcases hst with rfl | ⟨hok, _⟩
    · cases hst_c
    · exact hok
  · rw [List.getElem?_set_ne hpq] at hget₁
    exact Or.inr ⟨hpq, pool₁, hget₁, hw, hc⟩

theorem recv_other_stage_pres {r rcv : Recv} {e : Recv.Ev}
    (hrcv : Recv.step .shipping r e = some rcv)
    (hne1 : e ≠ .pushBegin)
    (hne2 : ∀ p, e ≠ .onPoolReceived p)
    (hne3 : ∀ p ok, e ≠ .h2dDone p ok)
    (q : Nat) (pool' : Pool) (hget' : rcv.pools[q]? = some pool') :
    ∃ pool_q : Pool, r.pools[q]? = some pool_q ∧
      (pool'.stage = .waiting → pool_q.stage = .waiting) ∧
      (pool_q.stage = .waiting → pool'.stage = .waiting) ∧
      (pool'.stage = .completed → pool_q.stage = .completed) := by
  cases e with
  | pushBegin => exact absurd rfl hne1
  | onPoolReceived p => exact absurd rfl (hne2 p)
  | h2dDone p ok => exact absurd rfl (hne3 p ok)
  | pushEnd ok =>
    simp only [Recv.step, Recv.pushEnd] at hrcv
    split at hrcv <;> try cases hrcv
    simp only [Recv.maybeUnregisterSettled_pools] at hget'
    exact ⟨pool', hget', id, id, id⟩
  | h2dIssue p ok =>
    simp only [Recv.step, Recv.h2dIssue] at hrcv
    split at hrcv <;> try cases hrcv
    rename_i pool hget
    split at hrcv <;> try cases hrcv
    rename_i hq_st
    simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hq_st
    have hp_lt : p < r.pools.length := lt_length_of_getElem?_eq hget
    have hset : ∃ st', (st' = .aborted ∨ st' = .issued) ∧
        rcv.pools = r.pools.set p { pool with stage := st' } := by
      split at hrcv
      · cases hrcv; exact ⟨.aborted, Or.inl rfl, rfl⟩
      · split at hrcv
        · cases hrcv; exact ⟨.issued, Or.inr rfl, rfl⟩
        · cases hrcv; exact ⟨.aborted, Or.inl rfl, by simp⟩
    obtain ⟨st', hst', hpools'⟩ := hset
    rw [hpools'] at hget'
    by_cases hpq : p = q
    · subst hpq
      rw [List.getElem?_set_self hp_lt, Option.some.injEq] at hget'
      subst hget'
      refine ⟨pool, hget, ?_, fun hw => by simp [hq_st] at hw, ?_⟩ <;>
        { rcases hst' with rfl | rfl <;> simp }
    · rw [List.getElem?_set_ne hpq] at hget'
      exact ⟨pool', hget', id, id, id⟩
  | h2dReady p =>
    simp only [Recv.step, Recv.h2dReady] at hrcv
    split at hrcv <;> try cases hrcv
    rename_i pool hget
    split at hrcv <;> try cases hrcv
    rename_i his
    simp only [beq_iff_eq] at his
    have hp_lt : p < r.pools.length := lt_length_of_getElem?_eq hget
    by_cases hpq : p = q
    · subst hpq
      rw [List.getElem?_set_self hp_lt, Option.some.injEq] at hget'
      subst hget'
      exact ⟨pool, hget, by simp, fun hw => by simp [his] at hw, by simp⟩
    · rw [List.getElem?_set_ne hpq] at hget'
      exact ⟨pool', hget', id, id, id⟩
  | pollReady =>
    simp only [Recv.step, Recv.pollReady] at hrcv
    split at hrcv <;> try cases hrcv
    exact ⟨pool', hget', id, id, id⟩
  | cancel =>
    simp only [Recv.step, Recv.cancel, Option.some.injEq] at hrcv
    subst hrcv; exact ⟨pool', hget', id, id, id⟩
  | publish =>
    simp only [Recv.step, Recv.publish] at hrcv
    split at hrcv <;> try cases hrcv
    exact ⟨pool', hget', id, id, id⟩

theorem recv_other_pushes_zero {r rcv : Recv} {e : Recv.Ev}
    (hrcv : Recv.step .shipping r e = some rcv)
    (hne1 : e ≠ .pushBegin)
    (hne2 : ∀ p, e ≠ .onPoolReceived p)
    (hne3 : ∀ p ok, e ≠ .h2dDone p ok)
    (hp0 : r.pushes = 0) : rcv.pushes = 0 := by
  cases e with
  | pushBegin => exact absurd rfl hne1
  | onPoolReceived p => exact absurd rfl (hne2 p)
  | h2dDone p ok => exact absurd rfl (hne3 p ok)
  | pushEnd ok =>
    simp only [Recv.step, Recv.pushEnd, hp0, ↓reduceIte] at hrcv; cases hrcv
  | h2dIssue p ok =>
    simp only [Recv.step, Recv.h2dIssue] at hrcv
    split at hrcv <;> try cases hrcv
    split at hrcv <;> try cases hrcv
    split at hrcv
    · cases hrcv; exact hp0
    · split at hrcv <;> { cases hrcv; simpa using hp0 }
  | h2dReady p =>
    simp only [Recv.step, Recv.h2dReady] at hrcv
    split at hrcv <;> try cases hrcv
    split at hrcv <;> try cases hrcv
    exact hp0
  | pollReady =>
    simp only [Recv.step, Recv.pollReady] at hrcv
    split at hrcv <;> try cases hrcv
    exact hp0
  | cancel =>
    simp only [Recv.step, Recv.cancel, Option.some.injEq] at hrcv
    subst hrcv; exact hp0
  | publish =>
    simp only [Recv.step, Recv.publish] at hrcv
    split at hrcv <;> try cases hrcv
    exact hp0

theorem step_recv_other_inv {s : Pipeline} {rcv : Recv} {e : Recv.Ev} (h : Inv s)
    (hrcv : Recv.step .shipping s.recv e = some rcv)
    (hne1 : e ≠ .pushBegin)
    (hne2 : ∀ p, e ≠ .onPoolReceived p)
    (hne3 : ∀ p ok, e ≠ .h2dDone p ok) :
    Inv { s with recv := rcv } := by
  have hrcvInv := Recv.step_inv .shipping h.recvInv hrcv
  have hdone_m : rcv.life.done = false → s.recv.life.done = false := by
    intro hnd; cases hd : s.recv.life.done
    · rfl
    · have := recv_step_done_mono hrcv hd; simp [hnd] at this
  have hlen' : rcv.pools.length = s.numPools := by
    rw [recv_step_pools_length hrcv, h.len_recv]
  refine ⟨h.sendInv, hrcvInv, h.num_pos, h.len_peers, h.len_send, hlen',
    h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
    h.len_sent, h.len_landed, h.peers_match, h.srcHbm_ok, h.reclaimed_pub,
    h.srcStg_ok, h.sent_bound, h.wire_ok, h.landed_le_sent,
    fun hnd => h.dstStg_ok (hdone_m hnd), ?_, ?_, h.unarmed_send, ?_⟩
  · intro q hq pool' hget' hne
    obtain ⟨pool_q, hget_q, _, hw_to, _⟩ := recv_other_stage_pres hrcv hne1 hne2 hne3 q pool' hget'
    exact h.recv_stage_landed q hq pool_q hget_q (fun hw_q => hne (hw_to hw_q))
  · intro q hq pool' hget' hcomp'
    obtain ⟨pool_q, hget_q, _, _, hc⟩ := recv_other_stage_pres hrcv hne1 hne2 hne3 q pool' hget'
    exact h.done_intact q hq pool_q hget_q (hc hcomp')
  · intro ha
    have ⟨hp0, hl0, hw_all⟩ := h.unarmed_recv ha
    refine ⟨recv_other_pushes_zero hrcv hne1 hne2 hne3 hp0, hl0, fun q hq pool' hget' => ?_⟩
    obtain ⟨pool_q, hget_q, _, hw_to, _⟩ := recv_other_stage_pres hrcv hne1 hne2 hne3 q pool' hget'
    exact hw_to (hw_all q hq pool_q hget_q)

theorem step_recv_inv {s s' : Pipeline} {e : Recv.Ev} (h : Inv s)
    (hs : s.recvStep e = some s') : Inv s' := by
  have hlen_r := h.len_recv
  cases e with
  | pushBegin =>
    simp only [recvStep] at hs
    split at hs <;> try cases hs
    rename_i harm
    simp only [Option.map_eq_some_iff] at hs
    obtain ⟨rcv, hrcv, rfl⟩ := hs
    have hrcvInv := Recv.step_inv .shipping h.recvInv hrcv
    have hdone_m : rcv.life.done = false → s.recv.life.done = false := by
      intro hnd; cases hd : s.recv.life.done
      · rfl
      · have := recv_step_done_mono hrcv hd; simp [hnd] at this
    have hpools_eq : rcv.pools = s.recv.pools := by
      simp only [Recv.step, Recv.pushBegin, Option.map_eq_some_iff] at hrcv
      obtain ⟨_, _, rfl⟩ := hrcv; rfl
    exact ⟨h.sendInv, hrcvInv, h.num_pos, h.len_peers, h.len_send,
      by rw [hpools_eq]; exact h.len_recv,
      h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
      h.len_sent, h.len_landed, h.peers_match, h.srcHbm_ok, h.reclaimed_pub,
      h.srcStg_ok, h.sent_bound, h.wire_ok, h.landed_le_sent,
      fun hnd => h.dstStg_ok (hdone_m hnd),
      by rw [hpools_eq]; exact h.recv_stage_landed,
      fun q hq pool hget => by rw [hpools_eq] at hget; exact h.done_intact q hq pool hget,
      h.unarmed_send, fun ha => by simp [harm] at ha⟩
  | onPoolReceived p =>
    simp only [recvStep] at hs
    split at hs <;> try cases hs
    rename_i hland_p
    simp only [Option.map_eq_some_iff] at hs
    obtain ⟨rcv, hrcv, rfl⟩ := hs
    have hrcvInv := Recv.step_inv .shipping h.recvInv hrcv
    have hdone_m : rcv.life.done = false → s.recv.life.done = false := by
      intro hnd; cases hd : s.recv.life.done
      · rfl
      · have := recv_step_done_mono hrcv hd; simp [hnd] at this
    have hlen' : rcv.pools.length = s.numPools := by
      rw [recv_step_pools_length hrcv, h.len_recv]
    simp only [Recv.step, Recv.onPoolReceived] at hrcv
    split at hrcv <;> try cases hrcv
    rename_i pool hget
    split at hrcv <;> try cases hrcv
    rename_i hact
    simp only [not_or, Bool.not_eq_true, bne_iff_ne, ne_eq, Decidable.not_not] at hact
    obtain ⟨_, hwait⟩ := hact
    have hp_lt : p < s.recv.pools.length := lt_length_of_getElem?_eq hget
    have hp : p < s.numPools := by omega
    have hland_d : s.landedStreams.getD p 0 = s.peerCounts.getD p 0 := by
      rw [List.getD_eq_getElem?_getD, hland_p]; rfl
    have harm_t : s.armed = true := by
      have hpe_pos := peerCount_pos h hp
      cases ha : s.armed
      · have hl0 := (h.unarmed_recv ha).2.1 p hp
        omega
      · rfl
    refine ⟨h.sendInv, hrcvInv, h.num_pos, h.len_peers, h.len_send, hlen',
      h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
      h.len_sent, h.len_landed, h.peers_match, h.srcHbm_ok, h.reclaimed_pub,
      h.srcStg_ok, h.sent_bound, h.wire_ok, h.landed_le_sent,
      fun hnd => h.dstStg_ok (hdone_m hnd), ?_, ?_,
      h.unarmed_send, ?_⟩
    · intro q hq pool' hget' hne
      obtain ⟨pool₁, hget₁, _, hw, _⟩ := launchEligible_getElem? hget'
      by_cases hpq : p = q
      · subst hpq; exact hland_d
      · rw [List.getElem?_set_ne hpq] at hget₁
        exact h.recv_stage_landed q hq pool₁ hget₁ (fun hw₁ => hne (hw.mpr hw₁))
    · intro q hq pool' hget' hcomp'
      obtain ⟨pool₁, hget₁, _, _, hc⟩ := launchEligible_getElem? hget'
      have hcomp₁ : pool₁.stage = .completed := hc.mp hcomp'
      by_cases hpq : p = q
      · subst hpq
        rw [List.getElem?_set_self hp_lt, Option.some.injEq] at hget₁
        subst hget₁; cases hcomp₁
      · rw [List.getElem?_set_ne hpq] at hget₁
        exact h.done_intact q hq pool₁ hget₁ hcomp₁
    · intro ha; simp [harm_t] at ha
  | h2dDone p ok =>
    simp only [recvStep] at hs
    split at hs <;> try cases hs
    rename_i pool hget
    simp only [Option.map_eq_some_iff] at hs
    obtain ⟨rcv, hrcv, hs'⟩ := hs
    have hrcvInv := Recv.step_inv .shipping h.recvInv hrcv
    have hdone_m : rcv.life.done = false → s.recv.life.done = false := by
      intro hnd; cases hd : s.recv.life.done
      · rfl
      · have := recv_step_done_mono hrcv hd; simp [hnd] at this
    have hlen' : rcv.pools.length = s.numPools := by
      rw [recv_step_pools_length hrcv, h.len_recv]
    have hrcv_step : Recv.h2dDone p ok s.recv = some rcv := hrcv
    obtain ⟨pool₀, st, hget₀, hrd, _, _⟩ := h2dDone_pools_shape hrcv_step
    rw [hget] at hget₀; injection hget₀ with hpool_eq; subst hpool_eq
    have hp_lt : p < s.recv.pools.length := lt_length_of_getElem?_eq hget
    have hp : p < s.numPools := by omega
    have hnd_r : s.recv.life.done = false := recv_not_done_of_ready h.recvInv hget hrd
    have harm_t : s.armed = true := by
      cases ha : s.armed
      · have hw := (h.unarmed_recv ha).2.2 p hp pool hget
        simp [hrd] at hw
      · rfl
    cases ok with
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at hs'
      subst hs'
      refine ⟨h.sendInv, hrcvInv, h.num_pos, h.len_peers, h.len_send, hlen',
        h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg, h.len_dstHbm,
        h.len_sent, h.len_landed, h.peers_match, h.srcHbm_ok, h.reclaimed_pub,
        h.srcStg_ok, h.sent_bound, h.wire_ok, h.landed_le_sent,
        fun hnd => h.dstStg_ok (hdone_m hnd), ?_, ?_,
        h.unarmed_send, fun ha => by simp [harm_t] at ha⟩
      · intro q hq pool' hget' hne
        rcases h2dDone_getElem? hrcv_step hget' with ⟨_, _, _, rfl, _⟩ | ⟨_, pool_q, hget_q, hw, _⟩
        · exact h.recv_stage_landed p hq pool hget (by simp [hrd])
        · exact h.recv_stage_landed q hq pool_q hget_q (fun hw_q => hne (hw.mpr hw_q))
      · intro q hq pool' hget' hcomp'
        rcases h2dDone_getElem? hrcv_step hget' with ⟨_, _, _, rfl, hok⟩ | ⟨_, pool_q, hget_q, _, hc⟩
        · cases hok hcomp'
        · exact h.done_intact q hq pool_q hget_q (hc.mp hcomp')
    | true =>
      simp only [↓reduceIte] at hs'
      subst hs'
      have hland_p : s.landedStreams.getD p 0 = s.peerCounts.getD p 0 :=
        h.recv_stage_landed p hp pool hget (by simp [hrd])
      have hpe_pos : 0 < s.peerCounts.getD p 0 := peerCount_pos h hp
      have hstg_kv : s.dstStaging.getD p .junk = .kv p := by
        have h1 := h.dstStg_ok hnd_r p hp (by omega)
        rw [List.getD_eq_getElem?_getD, h1]; rfl
      refine ⟨h.sendInv, hrcvInv, h.num_pos, h.len_peers, h.len_send, hlen',
        h.len_srcHbm, h.len_srcStg, h.len_wire, h.len_dstStg,
        by simp [h.len_recv, h.len_dstHbm],
        h.len_sent, h.len_landed, h.peers_match, h.srcHbm_ok, h.reclaimed_pub,
        h.srcStg_ok, h.sent_bound, h.wire_ok, h.landed_le_sent,
        fun hnd => h.dstStg_ok (hdone_m hnd), ?_, ?_,
        h.unarmed_send, fun ha => by simp [harm_t] at ha⟩
      · intro q hq pool' hget' hne
        rcases h2dDone_getElem? hrcv_step hget' with ⟨_, _, _, rfl, _⟩ | ⟨_, pool_q, hget_q, hw, _⟩
        · exact hland_p
        · exact h.recv_stage_landed q hq pool_q hget_q (fun hw_q => hne (hw.mpr hw_q))
      · intro q hq pool' hget' hcomp'
        rcases h2dDone_getElem? hrcv_step hget' with ⟨_, _, _, rfl, _⟩ | ⟨hpq, pool_q, hget_q, _, hc⟩
        · rw [getElem?_writePoolHbm_self (by simp [h.len_recv, h.len_dstHbm, hp]), hstg_kv]
        · have hcomp_q : pool_q.stage = .completed := hc.mp hcomp'
          have hnlt : ¬(pool.rank < pool_q.rank) := by
            intro hlt_r
            have hrw := Recv.rankWaveOrder_iff.mp h.recvInv.rankWave
              pool_q (List.mem_of_getElem? hget_q) pool (List.mem_of_getElem? hget)
              (by simp [hcomp_q, PoolStage.launched]) hlt_r
            simp [hrd] at hrw
          rw [getElem?_writePoolHbm_of_ne_of_not_lt hpq hget_q hnlt]
          exact h.done_intact q hq pool_q hget_q hcomp_q
  | pushEnd ok =>
    simp only [recvStep, Option.map_eq_some_iff] at hs
    obtain ⟨rcv, hrcv, rfl⟩ := hs
    exact step_recv_other_inv h hrcv (fun h => by cases h) (fun _ h => by cases h) (fun _ _ h => by cases h)
  | h2dIssue p ok =>
    simp only [recvStep, Option.map_eq_some_iff] at hs
    obtain ⟨rcv, hrcv, rfl⟩ := hs
    exact step_recv_other_inv h hrcv (fun h => by cases h) (fun _ h => by cases h) (fun _ _ h => by cases h)
  | h2dReady p =>
    simp only [recvStep, Option.map_eq_some_iff] at hs
    obtain ⟨rcv, hrcv, rfl⟩ := hs
    exact step_recv_other_inv h hrcv (fun h => by cases h) (fun _ h => by cases h) (fun _ _ h => by cases h)
  | pollReady =>
    simp only [recvStep, Option.map_eq_some_iff] at hs
    obtain ⟨rcv, hrcv, rfl⟩ := hs
    exact step_recv_other_inv h hrcv (fun h => by cases h) (fun _ h => by cases h) (fun _ _ h => by cases h)
  | cancel =>
    simp only [recvStep, Option.map_eq_some_iff] at hs
    obtain ⟨rcv, hrcv, rfl⟩ := hs
    exact step_recv_other_inv h hrcv (fun h => by cases h) (fun _ h => by cases h) (fun _ _ h => by cases h)
  | publish =>
    simp only [recvStep, Option.map_eq_some_iff] at hs
    obtain ⟨rcv, hrcv, rfl⟩ := hs
    exact step_recv_other_inv h hrcv (fun h => by cases h) (fun _ h => by cases h) (fun _ _ h => by cases h)

theorem step_inv {s s' : Pipeline} {e : Ev} (h : Inv s) (hs : step s e = some s') :
    Inv s' := by
  cases e with
  | armRecv => exact step_armRecv_inv h hs
  | send e => exact step_send_inv h hs
  | recv e => exact step_recv_inv h hs
  | landStream p => exact step_landStream_inv h hs
  | reclaim => exact step_reclaim_inv h hs
  | reseatSrcStaging => exact step_reseatSrcStaging_inv h hs
  | reseatDstStaging => exact step_reseatDstStaging_inv h hs

theorem reachable_inv {ranks peerCounts : List Nat} {s : Pipeline}
    (hvalid : validConfig ranks peerCounts = true)
    (h : (sys ranks peerCounts).Reachable s) : Inv s :=
  (sys ranks peerCounts).reachable_induction (inv_init hvalid) (fun _ _ _ => step_inv) h

theorem reachable_unarmed_inv {ranks peerCounts : List Nat} {s : Pipeline}
    (hvalid : validConfig ranks peerCounts = true)
    (h : (sysUnarmed ranks peerCounts).Reachable s) : Inv s :=
  (sysUnarmed ranks peerCounts).reachable_induction (inv_initUnarmed hvalid)
    (fun _ _ _ => step_inv) h

/-- Main safety theorem: every reachable state of the composed reshard pipeline
on a valid schedule satisfies `PublicationCorrect`, `AliasedPageCorrect`,
`DstHbmSafe`, `SrcHbmSafe`, `StagingSafe`, `StreamAccountingSafe`,
`NoUnarmedPush`, and `NoOpLeak`. -/
theorem reachable_safe {ranks peerCounts : List Nat} {s : Pipeline}
    (hvalid : validConfig ranks peerCounts = true)
    (h : (sys ranks peerCounts).Reachable s) : Safe s :=
  inv_safe (reachable_inv hvalid h)

/-- Every state reachable from the pre-Phase-1 unarmed state (`initUnarmed`)
also satisfies all pipeline safety properties. -/
theorem reachable_unarmed_safe {ranks peerCounts : List Nat} {s : Pipeline}
    (hvalid : validConfig ranks peerCounts = true)
    (h : (sysUnarmed ranks peerCounts).Reachable s) : Safe s :=
  inv_safe (reachable_unarmed_inv hvalid h)

/-! ## Quietness and temporal post-publication safety (`attention_safe`) -/

@[simp] theorem launchEligible_published (r : Recv) :
    (Recv.launchEligible r).published = r.published := by
  unfold Recv.launchEligible; split <;> rfl

@[simp] theorem maybeUnregisterSettled_published (r : Recv) :
    (Recv.maybeUnregisterSettled r).published = r.published := by
  unfold Recv.maybeUnregisterSettled; split <;> rfl

theorem recv_step_published_eq {pol : PushEndPolicy} {r r' : Recv} {e : Recv.Ev}
    (hs : Recv.step pol r e = some r') (hpub : r.published ≠ none) :
    r'.published = r.published := by
  cases e with
  | pushBegin =>
    simp only [Recv.step, Recv.pushBegin, Option.map_eq_some_iff] at hs
    obtain ⟨_, _, rfl⟩ := hs; rfl
  | pushEnd ok =>
    simp only [Recv.step, Recv.pushEnd] at hs
    split at hs <;> simp at hs; subst hs; simp
  | onPoolReceived p =>
    simp only [Recv.step, Recv.onPoolReceived] at hs
    split at hs <;> try cases hs
    split at hs <;> simp at hs; subst hs; simp
  | h2dIssue p ok =>
    simp only [Recv.step, Recv.h2dIssue] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs
    · simp at hs; subst hs; rfl
    · split at hs <;> { simp at hs; subst hs; simp }
  | h2dReady p =>
    simp only [Recv.step, Recv.h2dReady] at hs
    split at hs <;> try cases hs
    split at hs <;> simp at hs; subst hs; rfl
  | h2dDone p ok =>
    simp only [Recv.step, Recv.h2dDone] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs
    · simp at hs; subst hs; simp
    · split at hs
      · simp at hs; subst hs; simp
      · split at hs
        · simp at hs; subst hs; simp
        · split at hs <;> { simp at hs; subst hs; simp }
  | pollReady =>
    simp only [Recv.step, Recv.pollReady] at hs
    split at hs <;> simp at hs; subst hs; rfl
  | cancel =>
    simp only [Recv.step, Recv.cancel, Option.some.injEq] at hs
    subst hs; rfl
  | publish =>
    simp only [Recv.step, Recv.publish] at hs
    split at hs <;> try cases hs
    rename_i hc; exact absurd hc.2 hpub

/-- Once the receiver is published (`done_recving` or `failed_recving`), no
pipeline step can modify `dstHbm` or `recv.published`. -/
theorem dstHbm_quiet {s s' : Pipeline} {e : Ev} (h : Inv s)
    (hpub : s.recv.published ≠ none) (hs : step s e = some s') :
    s'.dstHbm = s.dstHbm ∧ s'.recv.published = s.recv.published ∧ s'.numPools = s.numPools := by
  cases e with
  | armRecv =>
    simp only [step, armRecv] at hs
    split at hs <;> simp at hs; subst hs; exact ⟨rfl, rfl, rfl⟩
  | send e =>
    cases e <;> simp only [step, sendStep, Option.map_eq_some_iff] at hs
    · split at hs <;> try cases hs
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl, rfl⟩
    · obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl, rfl⟩
    · obtain ⟨_, _, hs'⟩ := hs; split at hs' <;> { subst hs'; exact ⟨rfl, rfl, rfl⟩ }
    · obtain ⟨_, _, hs'⟩ := hs; split at hs' <;> { subst hs'; exact ⟨rfl, rfl, rfl⟩ }
    · obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl, rfl⟩
    · obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl, rfl⟩
  | recv e =>
    cases e with
    | pushBegin =>
      simp only [step, recvStep] at hs
      split at hs <;> try cases hs
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨rcv, hrcv, rfl⟩ := hs
      exact ⟨rfl, recv_step_published_eq hrcv hpub, rfl⟩
    | onPoolReceived p =>
      simp only [step, recvStep] at hs
      split at hs <;> try cases hs
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨rcv, hrcv, rfl⟩ := hs
      exact ⟨rfl, recv_step_published_eq hrcv hpub, rfl⟩
    | h2dDone p ok =>
      simp only [step, recvStep] at hs
      split at hs <;> try cases hs
      rename_i pool hget
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨rcv, hrcv, _⟩ := hs
      obtain ⟨pool₀, _, hget₀, hrd, _, _⟩ := h2dDone_pools_shape hrcv
      rw [hget] at hget₀; injection hget₀ with heq; subst heq
      have hnd := recv_not_done_of_ready h.recvInv hget hrd
      cases hb : s.recv.published with
      | none => exact absurd hb hpub
      | some b =>
        have ⟨hd, _⟩ := h.recvInv.published_done b hb
        simp [hnd] at hd
    | pushEnd ok | h2dIssue p ok | h2dReady p | pollReady | cancel | publish =>
      simp only [step, recvStep, Option.map_eq_some_iff] at hs
      obtain ⟨rcv, hrcv, rfl⟩ := hs
      exact ⟨rfl, recv_step_published_eq hrcv hpub, rfl⟩
  | landStream p =>
    simp only [step, landStream] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs <;> simp at hs; subst hs; exact ⟨rfl, rfl, rfl⟩
  | reclaim =>
    simp only [step, reclaim] at hs
    split at hs <;> simp at hs; subst hs; exact ⟨rfl, rfl, rfl⟩
  | reseatSrcStaging =>
    simp only [step, reseatSrcStaging] at hs
    split at hs <;> simp at hs; subst hs; exact ⟨rfl, rfl, rfl⟩
  | reseatDstStaging =>
    simp only [step, reseatDstStaging] at hs
    split at hs <;> simp at hs; subst hs; exact ⟨rfl, rfl, rfl⟩

theorem runFrom_dstHbm_quiet {ranks peerCounts : List Nat} :
    ∀ (evs : List Ev) {s s' : Pipeline},
      Inv s → s.recv.published ≠ none →
      (sys ranks peerCounts).runFrom s evs = some s' →
      s'.dstHbm = s.dstHbm ∧ s'.recv.published = s.recv.published ∧ s'.numPools = s.numPools
  | [], _, _, _, _, hrun => by
    simp only [System.runFrom, List.foldlM_nil] at hrun
    injection hrun with hrun
    subst hrun; exact ⟨rfl, rfl, rfl⟩
  | e :: evs, s, s', h, hpub, hrun => by
    simp only [System.runFrom, List.foldlM_cons, Option.bind_eq_bind,
      Option.bind_eq_some_iff] at hrun
    obtain ⟨s₁, hs₁, hrun₁⟩ := hrun
    have ⟨hd₁, hp₁, hn₁⟩ := dstHbm_quiet h hpub hs₁
    have hinv₁ := step_inv h hs₁
    have hpub₁ : s₁.recv.published ≠ none := by rw [hp₁]; exact hpub
    have ⟨hd₂, hp₂, hn₂⟩ := runFrom_dstHbm_quiet evs hinv₁ hpub₁ hrun₁
    exact ⟨hd₂.trans hd₁, hp₂.trans hp₁, hn₂.trans hn₁⟩

/-- Temporal post-publication safety (`attention_safe`): once `poll_stats()`
reports `done_recving` (`s.recv.published = some true`), destination HBM holds
`good numPools` and remains equal to `good numPools` across any subsequent
sequence of pipeline events (including sender/receiver staging reuse, source HBM
reclamation, and late drain or cancellation steps). -/
theorem attention_safe {ranks peerCounts : List Nat} {s s' : Pipeline} {evs : List Ev}
    (hvalid : validConfig ranks peerCounts = true)
    (hr : (sys ranks peerCounts).Reachable s)
    (hpub : s.recv.published = some true)
    (hrun : (sys ranks peerCounts).runFrom s evs = some s') :
    s'.dstHbm = good s.numPools ∧ s'.recv.published = some true := by
  have hinv := reachable_inv hvalid hr
  have hgood : s.dstHbm = good s.numPools := (inv_safe hinv).1 hpub
  have hne : s.recv.published ≠ none := by simp [hpub]
  have ⟨hd, hp, _⟩ := runFrom_dstHbm_quiet evs hinv hne hrun
  exact ⟨hd.trans hgood, hp.trans hpub⟩

/-- Before the sender is published (`s.send.published = none`), no pipeline step
can modify `srcHbm`. -/
theorem srcHbm_quiet {s s' : Pipeline} {e : Ev}
    (hpub : s.send.published = none) (hs : step s e = some s') :
    s'.srcHbm = s.srcHbm := by
  cases e with
  | armRecv =>
    simp only [step, armRecv] at hs; split at hs <;> simp at hs; subst hs; rfl
  | send e =>
    cases e <;> simp only [step, sendStep, Option.map_eq_some_iff] at hs
    · split at hs <;> try cases hs
      simp only [Option.map_eq_some_iff] at hs; obtain ⟨_, _, rfl⟩ := hs; rfl
    · obtain ⟨_, _, rfl⟩ := hs; rfl
    · obtain ⟨_, _, hs'⟩ := hs; split at hs' <;> { subst hs'; rfl }
    · obtain ⟨_, _, hs'⟩ := hs; split at hs' <;> { subst hs'; rfl }
    · obtain ⟨_, _, rfl⟩ := hs; rfl
    · obtain ⟨_, _, rfl⟩ := hs; rfl
  | recv e =>
    cases e <;> simp only [step, recvStep] at hs
    · split at hs <;> try cases hs
      simp only [Option.map_eq_some_iff] at hs; obtain ⟨_, _, rfl⟩ := hs; rfl
    · simp only [Option.map_eq_some_iff] at hs; obtain ⟨_, _, rfl⟩ := hs; rfl
    · split at hs <;> try cases hs
      simp only [Option.map_eq_some_iff] at hs; obtain ⟨_, _, rfl⟩ := hs; rfl
    · simp only [Option.map_eq_some_iff] at hs; obtain ⟨_, _, rfl⟩ := hs; rfl
    · simp only [Option.map_eq_some_iff] at hs; obtain ⟨_, _, rfl⟩ := hs; rfl
    · split at hs <;> try cases hs
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨_, _, hs'⟩ := hs; split at hs' <;> { subst hs'; rfl }
    · simp only [Option.map_eq_some_iff] at hs; obtain ⟨_, _, rfl⟩ := hs; rfl
    · simp only [Option.map_eq_some_iff] at hs; obtain ⟨_, _, rfl⟩ := hs; rfl
    · simp only [Option.map_eq_some_iff] at hs; obtain ⟨_, _, rfl⟩ := hs; rfl
  | landStream p =>
    simp only [step, landStream] at hs
    split at hs <;> try cases hs
    split at hs <;> try cases hs
    split at hs <;> simp at hs; subst hs; rfl
  | reclaim =>
    simp only [step, reclaim, hpub, ne_eq, not_true_eq_false, false_and, ↓reduceIte] at hs
    cases hs
  | reseatSrcStaging =>
    simp only [step, reseatSrcStaging] at hs; split at hs <;> simp at hs; subst hs; rfl
  | reseatDstStaging =>
    simp only [step, reseatDstStaging] at hs; split at hs <;> simp at hs; subst hs; rfl

/-- Once the sender releases its `PoolStagingLease` (`hasStaging = false`), no
sender event can read or write `srcStaging` or `wire`. -/
theorem srcStaging_quiet {s s' : Pipeline} {e : Send.Ev} (h : Inv s)
    (hst : s.send.life.hasStaging = false) (hs : step s (.send e) = some s') :
    s'.srcStaging = s.srcStaging ∧ s'.wire = s.wire := by
  have hd : s.send.life.done = true := by
    rw [h.sendInv.life.staging] at hst; simpa using hst
  cases e with
  | d2hIssue p ok =>
    simp only [step, sendStep] at hs
    split at hs <;> try cases hs
    simp only [Option.map_eq_some_iff] at hs
    obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩
  | d2hDone p ok =>
    simp only [step, sendStep, Option.map_eq_some_iff] at hs
    obtain ⟨snd, hsnd, _⟩ := hs
    simp only [Send.step, Send.d2hDone] at hsnd
    split at hsnd <;> try cases hsnd
    rename_i pool hget
    split at hsnd <;> try cases hsnd
    rename_i hd2h
    simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hd2h
    have hnd := send_not_done_of_stage h.sendInv hget (by simp [hd2h, SendStage.opCount])
    simp [hnd] at hd
  | pushDone p ok =>
    simp only [step, sendStep, Option.map_eq_some_iff] at hs
    obtain ⟨snd, hsnd, _⟩ := hs
    simp only [Send.step, Send.pushDone] at hsnd
    cases hget : s.send.pools[p]? with
    | none => simp [hget] at hsnd
    | some pool =>
      simp only [hget] at hsnd
      cases hpush : pool.stage with
      | pending | d2h | aborted => simp [hpush] at hsnd
      | pushing n =>
        cases n with
        | zero => simp [hpush] at hsnd
        | succ k =>
          have hnd := send_not_done_of_stage h.sendInv hget (by simp [hpush, SendStage.opCount])
          simp [hnd] at hd
  | execFinish | cancel | publish =>
    simp only [step, sendStep, Option.map_eq_some_iff] at hs
    obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩

/-- Once the receiver releases its `PoolStagingLease` (`hasStaging = false`),
neither `landStream` nor any receiver event can modify `dstStaging` or `dstHbm`. -/
theorem dstStaging_quiet {s s' : Pipeline} {e : Ev} (h : Inv s)
    (hst : s.recv.life.hasStaging = false)
    (hne : e ≠ .reseatDstStaging) (hs : step s e = some s') :
    s'.dstStaging = s.dstStaging ∧ s'.dstHbm = s.dstHbm := by
  have hd : s.recv.life.done = true := by
    rw [h.recvInv.life.staging] at hst; simpa using hst
  have hif := h.recvInv.life.done_idle hd
  have hacc := h.recvInv.accounted; unfold Recv.Accounted at hacc
  have hp0 : s.recv.pushes = 0 := by omega
  cases e with
  | armRecv =>
    simp only [step, armRecv] at hs; split at hs <;> simp at hs; subst hs; exact ⟨rfl, rfl⟩
  | send e =>
    cases e <;> simp only [step, sendStep, Option.map_eq_some_iff] at hs
    · split at hs <;> try cases hs
      simp only [Option.map_eq_some_iff] at hs; obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩
    · obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩
    · obtain ⟨_, _, hs'⟩ := hs; split at hs' <;> { subst hs'; exact ⟨rfl, rfl⟩ }
    · obtain ⟨_, _, hs'⟩ := hs; split at hs' <;> { subst hs'; exact ⟨rfl, rfl⟩ }
    · obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩
    · obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩
  | recv e =>
    cases e with
    | pushBegin =>
      simp only [step, recvStep] at hs
      split at hs <;> try cases hs
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩
    | onPoolReceived p =>
      simp only [step, recvStep] at hs
      split at hs <;> try cases hs
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩
    | h2dDone p ok =>
      simp only [step, recvStep] at hs
      split at hs <;> try cases hs
      rename_i pool hget
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨rcv, hrcv, _⟩ := hs
      obtain ⟨pool₀, _, hget₀, hrd, _, _⟩ := h2dDone_pools_shape hrcv
      rw [hget] at hget₀; injection hget₀ with heq; subst heq
      have hnd := recv_not_done_of_ready h.recvInv hget hrd
      simp [hnd] at hd
    | pushEnd ok | h2dIssue p ok | h2dReady p | pollReady | cancel | publish =>
      simp only [step, recvStep, Option.map_eq_some_iff] at hs
      obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩
  | landStream p =>
    simp only [step, landStream, hp0, Nat.lt_irrefl, ↓reduceIte] at hs; cases hs
  | reclaim =>
    simp only [step, reclaim] at hs; split at hs <;> simp at hs; subst hs; exact ⟨rfl, rfl⟩
  | reseatSrcStaging =>
    simp only [step, reseatSrcStaging] at hs; split at hs <;> simp at hs; subst hs; exact ⟨rfl, rfl⟩
  | reseatDstStaging => exact absurd rfl hne

/-! ## Progress and eventual settlement -/

def drainRank (s : Pipeline) : Nat :=
  s.send.life.inFlight + Recv.drainRank s.recv

theorem send_drain_step_lift {s : Pipeline} (h : Inv s)
    (hdr : s.send.life.draining = true) (hnd : s.send.life.done = false) :
    ∃ e s', step s (.send e) = some s' ∧
      s'.send.life.draining = true ∧ s'.recv = s.recv ∧
      s'.send.life.inFlight < s.send.life.inFlight := by
  have hif : 0 < s.send.life.inFlight := by
    cases h0 : s.send.life.inFlight
    · have := h.sendInv.life.prompt hdr h0; simp [hnd] at this
    · omega
  have hacc := h.sendInv.accounted; unfold Send.Accounted at hacc
  cases hex : s.send.execActive
  · simp only [hex, Bool.false_eq_true, ↓reduceIte, Nat.zero_add] at hacc
    obtain ⟨p, _, pool, hget, hop⟩ := Send.exists_op_of_poolOps_pos (ps := s.send.pools) (by omega)
    cases hst : pool.stage with
    | pending | aborted => simp [hst, SendStage.opCount] at hop
    | d2h =>
      let snd := Send.endOp { s.send with pools := s.send.pools.set p { pool with stage := .aborted } }
      have hs₁ : Send.step .shipping s.send (.d2hDone p true) = some snd := by
        simp [Send.step, Send.d2hDone, hget, hst, hdr, snd]
      let s' : Pipeline := { s with send := snd, srcStaging := s.srcStaging.set p (s.srcHbm.getD p .junk) }
      refine ⟨.d2hDone p true, s', ?_, by simp [s', snd, hdr], rfl, by simp [s', snd]; omega⟩
      simp [step, sendStep, hs₁, s']
    | pushing k =>
      cases k with
      | zero => simp [hst, SendStage.opCount] at hop
      | succ k =>
        let snd := Send.endOp { s.send with pools := s.send.pools.set p { pool with stage := .pushing k } }
        have hs₁ : Send.step .shipping s.send (.pushDone p true) = some snd := by
          simp [Send.step, Send.pushDone, hget, hst, Send.recordPushCompletion, hdr, snd]
        let s' : Pipeline :=
          { s with send := snd
                   wire := s.wire.set p (s.srcStaging.getD p .junk)
                   sentStreams := s.sentStreams.set p (s.sentStreams.getD p 0 + 1) }
        refine ⟨.pushDone p true, s', ?_, by simp [s', snd, hdr], rfl, by simp [s', snd]; omega⟩
        simp [step, sendStep, hs₁, s']
  · cases hiss : Send.allIssued s.send.pools
    · obtain ⟨p, _, pool, hget, hp⟩ := Send.exists_pending_of_allIssued_false hiss
      let snd := Send.endOp { s.send with pools := s.send.pools.set p { pool with stage := .aborted },
                                          execActive := false }
      have hs₁ : Send.step .shipping s.send (.d2hIssue p false) = some snd := by
        simp [Send.step, Send.d2hIssue, hex, hget, hp, Send.recordPushCompletion, hdr, snd]
      let s' : Pipeline := { s with send := snd }
      refine ⟨.d2hIssue p false, s', ?_, by simp [s', snd, hdr], rfl, by simp [s', snd]; omega⟩
      simp [step, sendStep, hs₁, s']
    · let snd := Send.endOp { s.send with execActive := false }
      have hs₁ : Send.step .shipping s.send .execFinish = some snd := by
        simp [Send.step, Send.execFinish, hex, hiss, snd]
      let s' : Pipeline := { s with send := snd }
      refine ⟨.execFinish, s', ?_, by simp [s', snd, hdr], rfl, by simp [s', snd]; omega⟩
      simp [step, sendStep, hs₁, s']

theorem recv_drain_step_lift {s : Pipeline} (h : Inv s)
    (hdr : s.recv.life.draining = true) (hnd : s.recv.life.done = false) :
    ∃ e s', step s (.recv e) = some s' ∧
      s'.recv.life.draining = true ∧ s'.send = s.send ∧
      Recv.drainRank s'.recv < Recv.drainRank s.recv := by
  obtain ⟨e, rcv, hrcv, hdr', hlt⟩ := Recv.drain_step .shipping h.recvInv hdr hnd
  have hlift : ∃ s', step s (.recv e) = some s' ∧ s'.recv = rcv ∧ s'.send = s.send := by
    cases e with
    | pushBegin =>
      simp only [Recv.step, Recv.pushBegin, Option.map_eq_some_iff] at hrcv
      obtain ⟨_, hb, _⟩ := hrcv
      have hact := Lifecycle.beginOp_active hb
      simp [hdr] at hact
    | onPoolReceived p =>
      simp only [Recv.step, Recv.onPoolReceived] at hrcv
      split at hrcv <;> try cases hrcv
      rename_i pool hget
      split at hrcv <;> try cases hrcv
      rename_i hact
      simp only [Recv.launchEligible, hdr, true_or, or_true, ↓reduceIte] at hlt
      -- launchEligible is identity when draining = true, and setting waiting -> received
      -- leaves drainSteps = 0 unchanged, contradicting hlt!
      exfalso
      have hwait : pool.stage = .waiting := by
        simp only [not_or, Bool.not_eq_true, bne_iff_ne, ne_eq, Decidable.not_not] at hact
        exact hact.2
      have hd_eq : Recv.poolDrainSteps (s.recv.pools.set p { pool with stage := .received }) =
          Recv.poolDrainSteps s.recv.pools := by
        clear hlt hdr'
        have key : ∀ (ps : List Pool) (idx : Nat), ps[idx]? = some pool →
            Recv.poolDrainSteps (ps.set idx { pool with stage := .received }) =
            Recv.poolDrainSteps ps := by
          intro ps idx hi
          induction ps generalizing idx with
          | nil => simp at hi
          | cons q qs ih =>
            cases idx with
            | zero =>
              simp only [List.getElem?_cons_zero, Option.some.injEq] at hi
              subst hi
              simp [List.set_cons_zero, Recv.poolDrainSteps, hwait, PoolStage.drainSteps]
            | succ idx =>
              simp only [List.getElem?_cons_succ] at hi
              simp [List.set_cons_succ, Recv.poolDrainSteps, ih idx hi]
        exact key s.recv.pools p hget
      unfold Recv.drainRank at hlt
      simp only [hd_eq] at hlt
      omega
    | h2dDone p ok =>
      have hrcv_step : Recv.h2dDone p ok s.recv = some rcv := hrcv
      obtain ⟨pool, _, hget, _, _, _⟩ := h2dDone_pools_shape hrcv_step
      let s' : Pipeline :=
        if ok then
          { s with recv := rcv
                   dstHbm := writePoolHbm s.recv.pools p pool.rank
                               (s.dstStaging.getD p .junk) s.dstHbm }
        else { s with recv := rcv }
      refine ⟨s', ?_, ?_⟩
      · simp only [step, recvStep, hget, hrcv, Option.map_some, s']
      · dsimp only [s']; split <;> exact ⟨rfl, rfl⟩
    | pushEnd ok | h2dIssue p ok | h2dReady p | pollReady | cancel | publish =>
      exact ⟨{ s with recv := rcv }, by simp [step, recvStep, hrcv], rfl, rfl⟩
  obtain ⟨s', hs', hrcv_eq, hsnd_eq⟩ := hlift
  exact ⟨e, s', hs', by rw [hrcv_eq]; exact hdr', hsnd_eq, by rw [hrcv_eq]; exact hlt⟩

theorem drain_step {s : Pipeline} (h : Inv s)
    (hsdr : s.send.life.draining = true) (hrdr : s.recv.life.draining = true)
    (hnot_both : ¬(s.send.life.done = true ∧ s.recv.life.done = true)) :
    ∃ e s', step s e = some s' ∧
      s'.send.life.draining = true ∧ s'.recv.life.draining = true ∧
      drainRank s' < drainRank s := by
  cases hsnd_d : s.send.life.done
  · obtain ⟨e, s', hs', hdr', hrcv_eq, hlt⟩ := send_drain_step_lift h hsdr hsnd_d
    refine ⟨.send e, s', hs', hdr', by rw [hrcv_eq]; exact hrdr, ?_⟩
    unfold drainRank
    rw [hrcv_eq]; omega
  · have hrcv_nd : s.recv.life.done = false := by
      cases hr_d : s.recv.life.done
      · rfl
      · exact absurd ⟨hsnd_d, hr_d⟩ hnot_both
    obtain ⟨e, s', hs', hdr', hsnd_eq, hlt⟩ := recv_drain_step_lift h hrdr hrcv_nd
    refine ⟨.recv e, s', hs', by rw [hsnd_eq]; exact hsdr, hdr', ?_⟩
    unfold drainRank
    rw [hsnd_eq]; omega

theorem both_done_settle (sys₀ : System Pipeline Ev) (hstep : sys₀.step = step)
    {s : Pipeline} (h : Inv s)
    (hs_done : s.send.life.done = true) (hr_done : s.recv.life.done = true) :
    ∃ evs s', sys₀.runFrom s evs = some s' ∧
      s'.send.life.done = true ∧ s'.recv.life.done = true ∧
      s'.send.life.hasStaging = false ∧ s'.recv.life.hasStaging = false ∧
      s'.send.planUnregistered = true ∧ s'.recv.planUnregistered = true := by
  have hs_stg : s.send.life.hasStaging = false := by rw [h.sendInv.life.staging, hs_done]; rfl
  have hr_stg : s.recv.life.hasStaging = false := by rw [h.recvInv.life.staging, hr_done]; rfl
  have hs_pl : s.send.planUnregistered = true := h.sendInv.done_plan hs_done
  by_cases hpl : s.recv.planUnregistered = true
  · exact ⟨[], s, rfl, hs_done, hr_done, hs_stg, hr_stg, hs_pl, hpl⟩
  · cases hpub : s.recv.published with
    | none =>
      let s₁ : Pipeline :=
        { s with recv := { s.recv with published := some s.recv.life.statusOk,
                                       planUnregistered := true } }
      have hstep_pub : step s (.recv .publish) = some s₁ := by
        simp [step, recvStep, Recv.step, Recv.publish, hr_done, hpub, s₁]
      refine ⟨[.recv .publish], s₁, ?_, hs_done, hr_done, hs_stg, hr_stg, hs_pl, rfl⟩
      simp [System.runFrom, hstep, hstep_pub]
    | some b =>
      exact absurd (h.recvInv.published_done b hpub).2 hpl

theorem draining_can_settle_aux (sys₀ : System Pipeline Ev) (hstep : sys₀.step = step) :
    ∀ (k : Nat) {s : Pipeline}, drainRank s ≤ k → Inv s →
      s.send.life.draining = true → s.recv.life.draining = true →
      ∃ evs s', sys₀.runFrom s evs = some s' ∧
        s'.send.life.done = true ∧ s'.recv.life.done = true ∧
        s'.send.life.hasStaging = false ∧ s'.recv.life.hasStaging = false ∧
        s'.send.planUnregistered = true ∧ s'.recv.planUnregistered = true
  | 0, s, hk, h, hsdr, hrdr => by
    unfold drainRank Recv.drainRank at hk
    have hle := Recv.poolOps_le_poolDrainSteps s.recv.pools
    have hacc := h.recvInv.accounted; unfold Recv.Accounted at hacc
    have hs_done : s.send.life.done = true := h.sendInv.life.prompt hsdr (by omega)
    have hr_done : s.recv.life.done = true := h.recvInv.life.prompt hrdr (by omega)
    exact both_done_settle sys₀ hstep h hs_done hr_done
  | k + 1, s, hk, h, hsdr, hrdr => by
    by_cases hboth : s.send.life.done = true ∧ s.recv.life.done = true
    · exact both_done_settle sys₀ hstep h hboth.1 hboth.2
    · obtain ⟨e, s₁, hs₁, hsdr₁, hrdr₁, hlt⟩ := drain_step h hsdr hrdr hboth
      obtain ⟨evs, s', hrun, h1, h2, h3, h4, h5, h6⟩ :=
        draining_can_settle_aux sys₀ hstep k (by omega) (step_inv h hs₁) hsdr₁ hrdr₁
      have hstep₁ : sys₀.step s e = some s₁ := hstep ▸ hs₁
      refine ⟨e :: evs, s', ?_, h1, h2, h3, h4, h5, h6⟩
      simp only [System.runFrom, List.foldlM_cons, hstep₁]
      exact hrun

theorem can_settle_of_inv (sys₀ : System Pipeline Ev) (hstep : sys₀.step = step)
    {s : Pipeline} (hinv : Inv s) :
    ∃ evs s', sys₀.runFrom s evs = some s' ∧
      s'.send.life.done = true ∧ s'.recv.life.done = true ∧
      s'.send.life.hasStaging = false ∧ s'.recv.life.hasStaging = false ∧
      s'.send.planUnregistered = true ∧ s'.recv.planUnregistered = true := by
  let s₁ : Pipeline := { s with send := { s.send with life := s.send.life.finishLocked false } }
  let s₂ : Pipeline := { s₁ with recv := { s₁.recv with life := s₁.recv.life.finishLocked false } }
  have hs₁ : step s (.send .cancel) = some s₁ := rfl
  have hs₂ : step s₁ (.recv .cancel) = some s₂ := rfl
  have hinv₁ := step_inv hinv hs₁
  have hinv₂ := step_inv hinv₁ hs₂
  have hsdr₂ : s₂.send.life.draining = true := by simp [s₂, s₁]
  have hrdr₂ : s₂.recv.life.draining = true := by simp [s₂]
  obtain ⟨evs, s', hrun, h1, h2, h3, h4, h5, h6⟩ :=
    draining_can_settle_aux sys₀ hstep (drainRank s₂) (Nat.le_refl _) hinv₂ hsdr₂ hrdr₂
  have hstep₁ : sys₀.step s (.send .cancel) = some s₁ := hstep ▸ hs₁
  have hstep₂ : sys₀.step s₁ (.recv .cancel) = some s₂ := hstep ▸ hs₂
  refine ⟨.send .cancel :: .recv .cancel :: evs, s', ?_, h1, h2, h3, h4, h5, h6⟩
  simp only [System.runFrom, List.foldlM_cons, hstep₁]
  change (sys₀.step s₁ (.recv .cancel) >>= fun s₃ => List.foldlM sys₀.step s₃ evs) = some s'
  rw [hstep₂]
  exact hrun

/-- Every reachable state of the composed reshard pipeline on a valid schedule
can drain both sessions to `done = true`, release both `PoolStagingLease`s
(`hasStaging = false`), and unregister both active plans
(`planUnregistered = true`) in finitely many steps. -/
theorem reachable_can_settle {ranks peerCounts : List Nat} {s : Pipeline}
    (hvalid : validConfig ranks peerCounts = true)
    (h : (sys ranks peerCounts).Reachable s) :
    ∃ evs s', (sys ranks peerCounts).runFrom s evs = some s' ∧
      s'.send.life.done = true ∧ s'.recv.life.done = true ∧
      s'.send.life.hasStaging = false ∧ s'.recv.life.hasStaging = false ∧
      s'.send.planUnregistered = true ∧ s'.recv.planUnregistered = true :=
  can_settle_of_inv (sys ranks peerCounts) rfl (reachable_inv hvalid h)

/-- Every state reachable from the pre-Phase-1 unarmed state (`initUnarmed`)
can also drain both sessions to `done = true` and release all staging leases
and active plans in finitely many steps. -/
theorem reachable_unarmed_can_settle {ranks peerCounts : List Nat} {s : Pipeline}
    (hvalid : validConfig ranks peerCounts = true)
    (h : (sysUnarmed ranks peerCounts).Reachable s) :
    ∃ evs s', (sysUnarmed ranks peerCounts).runFrom s evs = some s' ∧
      s'.send.life.done = true ∧ s'.recv.life.done = true ∧
      s'.send.life.hasStaging = false ∧ s'.recv.life.hasStaging = false ∧
      s'.send.planUnregistered = true ∧ s'.recv.planUnregistered = true :=
  can_settle_of_inv (sysUnarmed ranks peerCounts) rfl (reachable_unarmed_inv hvalid h)

/-! ## Concrete traces and bounded verification

### Out-of-order network arrival on aliased device pages

Two pools with `ranks = [0, 1]` and `peerCounts = [1, 2]` share an aliased
device page (`recv.h:180-184`, `base.h:689-692`). Even when pool 1 (rank 1, 2
peer streams) finishes landing all of its network streams and calls
`onPoolReceived 1` **before** pool 0 (rank 0, 1 peer stream) has landed its
stream:
1. `onPoolReceived 1` records pool 1 as `.received` without launching its H2D
   copy (`dstHbm = [.junk, .junk]`).
2. When pool 0 subsequently lands its stream and calls `onPoolReceived 0`,
   pool 0 enters `.queued`, completes its H2D copy (`h2dDone 0 true`), writes
   `.kv 0` to `dstHbm[0]` (while clobbering `dstHbm[1]` to `.junk`), and
   `FinishPoolH2d` automatically unblocks and queues pool 1 (`stage = .queued`).
3. Pool 1's second-wave H2D copy (`h2dDone 1 true`) then overwrites `dstHbm[1]`
   with `.kv 1`, so `publish` reports `done_recving` with `dstHbm = good 2`.
-/

def outOfOrderPrefix : List Ev :=
  [ -- Sender issues D2H for pool 0 (1 peer) and pool 1 (2 peers), finishes ExecutePush,
    -- and completes all 3 peer pushes onto the wire.
    .send (.d2hIssue 0 true), .send (.d2hIssue 1 true), .send .execFinish,
    .send (.d2hDone 0 true), .send (.d2hDone 1 true),
    .send (.pushDone 0 true), .send (.pushDone 1 true), .send (.pushDone 1 true),
    .send .publish,
    -- Receiver begins incoming pushes; pool 1 (rank 1) lands BOTH streams and calls
    -- OnPoolReceived(1) BEFORE pool 0 (rank 0) has landed its stream.
    .recv .pushBegin,
    .landStream 1, .landStream 1,
    .recv (.onPoolReceived 1) ]

def outOfOrderSuffix : List Ev :=
  [ -- Pool 0 (rank 0) now lands its stream, calls OnPoolReceived(0), and runs Wave 0 H2D.
    .landStream 0,
    .recv (.onPoolReceived 0),
    .recv (.h2dIssue 0 true), .recv (.h2dReady 0), .recv (.h2dDone 0 true),
    -- Finishing pool 0's H2D automatically queues pool 1 (rank 1); Wave 1 H2D now runs.
    .recv (.h2dIssue 1 true), .recv (.h2dReady 1), .recv (.h2dDone 1 true),
    .recv (.pushEnd true),
    .recv .publish,
    -- Post-settlement cleanup: reclaim producer HBM and reseat both staging leases.
    .reclaim, .reseatSrcStaging, .reseatDstStaging ]

theorem trace_aliased_page_out_of_order_arrival :
    let s := sys [0, 1] [1, 2]
    -- After pool 1 (rank 1) lands first, it waits at `.received` while pool 0 is `.waiting`.
    (s.run outOfOrderPrefix).map
      (fun p => (p.recv.pools.map Pool.stage, p.dstHbm)) =
      some ([.waiting, .received], [.junk, .junk]) ∧
    -- After pool 0 (rank 0) completes Wave 0 H2D, pool 1 (rank 1) completes Wave 1 H2D
    -- and `dstHbm = [.kv 0, .kv 1] = good 2` survives post-publication cleanup.
    (s.run (outOfOrderPrefix ++ outOfOrderSuffix)).map
      (fun p => (p.send.published, p.recv.published, p.dstHbm, p.reclaimed)) =
      some (some true, some true, [.kv 0, .kv 1], true) := by decide

/-- Two-phase Arm-then-Dispatch trace (`coord.cc:433-544`): from `initUnarmed`,
neither sender D2H (`d2hIssue 0 true`) nor receiver `pushBegin` can fire before
`armRecv`; once `armRecv` runs, the transfer completes cleanly. -/
theorem trace_arm_before_dispatch :
    let s := sysUnarmed [0] [1]
    s.run [.send (.d2hIssue 0 true)] = none ∧
    s.run [.recv .pushBegin] = none ∧
    (s.run [
      .armRecv,
      .send (.d2hIssue 0 true), .send .execFinish,
      .send (.d2hDone 0 true), .send (.pushDone 0 true), .send .publish,
      .recv .pushBegin, .landStream 0, .recv (.onPoolReceived 0),
      .recv (.h2dIssue 0 true), .recv (.h2dReady 0), .recv (.h2dDone 0 true),
      .recv (.pushEnd true), .recv .publish
    ]).map (fun p => (p.armed, p.recv.published, p.dstHbm)) =
      some (true, some true, [.kv 0]) := by decide

/-! ### Executable safety checker and `#guard` bounded searches -/

def allEvents (n : Nat) : List Ev :=
  [.armRecv, .reclaim, .reseatSrcStaging, .reseatDstStaging] ++
  (Send.events n).map Ev.send ++
  (Recv.events n).map Ev.recv ++
  (List.range n).map Ev.landStream

def checkSafe (s : Pipeline) : Bool :=
  let pubOk := !(s.recv.published == some true) || (s.dstHbm == good s.numPools)
  let aliasedOk := (List.range s.numPools).all fun q =>
    match s.recv.pools[q]? with
    | some pool => !(pool.stage == .completed) || (s.dstHbm[q]? == some (.kv q))
    | none => true
  let dstSafe := s.recv.published.isNone || (Recv.poolOps s.recv.pools == 0)
  let srcSafe :=
    (s.send.published.isNone || (!s.send.execActive && Send.poolOps s.send.pools == 0)) &&
    (!s.reclaimed || (s.send.life.done && !s.send.execActive && Send.poolOps s.send.pools == 0))
  let stgSafe :=
    (s.send.life.hasStaging || (!s.send.execActive && Send.poolOps s.send.pools == 0)) &&
    (s.recv.life.hasStaging || (s.recv.pushes == 0 && Recv.poolOps s.recv.pools == 0))
  let streamOk := (List.range s.numPools).all fun p =>
    decide (s.landedStreams.getD p 0 ≤ s.sentStreams.getD p 0) &&
    decide (s.sentStreams.getD p 0 ≤ s.peerCounts.getD p 0) &&
    match s.recv.pools[p]? with
    | some pool => (pool.stage == .waiting) || (s.landedStreams.getD p 0 == s.peerCounts.getD p 0)
    | none => true
  let armOk := s.armed ||
    (s.send.pools.all (fun pool => pool.stage == .pending || pool.stage == .aborted) &&
     s.recv.pushes == 0 &&
     s.recv.pools.all (fun pool => pool.stage == .waiting))
  let noLeak :=
    !(decide (0 < s.send.life.inFlight) || decide (0 < s.recv.life.inFlight)) ||
    (drainEvents s.numPools).any fun e => (step s e).isSome
  pubOk && aliasedOk && dstSafe && srcSafe && stgSafe && streamOk && armOk && noLeak

def violates (s : Pipeline) : Bool := !checkSafe s

#guard ModelCheck.check (sys [0, 1] [1, 1]) (allEvents 2) violates 3 = .outOfFuel
#guard ModelCheck.check (sysUnarmed [0, 1] [1, 2]) (allEvents 2) violates 3 = .outOfFuel

/-! ## Mutants (`docs/transfer/reshard.md`)

1. **Rank-blind H2D launch (`stepRankBlind`)**: if `CollectEligiblePoolH2dsLocked`
   ignores pool rank (`prereqsCompleted` replaced by `fun _ => true`, as in
   `Recv.onPoolReceivedIgnoringRank`), then when pool 1 (rank 1) lands before
   pool 0 (rank 0), pool 1 completes H2D first and pool 0's subsequent coarse
   H2D copy clobbers `dstHbm[1]` to `.junk`, violating `PublicationCorrect` and
   `AliasedPageCorrect`.
2. **Premature `OnPoolReceived` (`stepPrematurePoolReceived`)**: if
   `BlockTransport::HandleIncomingPush` fires `OnPoolReceived(p)` on the first
   arriving stream (`0 < landedStreams[p]`) instead of waiting for all
   `peerCounts[p]` streams (`bt.cc:742-787`), `StreamAccountingSafe` is violated.
3. **Premature producer reclamation (`stepReclaimEarly`)**: if producer HBM is
   reclaimed before `send.published ≠ none`, D2H copies `.junk` into destination
   HBM and violates `PublicationCorrect`.
-/

def recvStepRankBlind (s : Pipeline) (e : Recv.Ev) : Option Pipeline :=
  match e with
  | .onPoolReceived p =>
    if s.landedStreams[p]? = some (s.peerCounts.getD p 0) then
      (Recv.onPoolReceivedIgnoringRank p s.recv).map fun rcv =>
        { s with recv := rcv }
    else none
  | e => recvStep s e

def stepRankBlind (s : Pipeline) : Ev → Option Pipeline
  | .recv e => recvStepRankBlind s e
  | e => step s e

def sysRankBlind (ranks peerCounts : List Nat) : System Pipeline Ev :=
  ⟨init ranks peerCounts, stepRankBlind⟩

/-- Mutant 1: without the rank gate in `CollectEligiblePoolH2dsLocked`,
out-of-order network arrival lets pool 1 (rank 1) finish H2D before pool 0
(rank 0), and pool 0's subsequent H2D copy clobbers the shared page slot
`dstHbm[1]` to `.junk`, publishing `done_recving` with corrupted HBM
(`[.kv 0, .junk] ≠ good 2`). -/
theorem mutant_ignoring_rank_corrupts_aliased_page :
    ∃ s, (sysRankBlind [0, 1] [1, 2]).Reachable s ∧
      s.recv.published = some true ∧ s.dstHbm = [.kv 0, .junk] ∧
      ¬PublicationCorrect s ∧ ¬AliasedPageCorrect s := by
  let evs : List Ev :=
    outOfOrderPrefix ++
    [ -- Without the rank gate, pool 1 (rank 1) was already queued by onPoolReceived 1
      -- and completes its H2D copy BEFORE pool 0 (rank 0) even lands!
      .recv (.h2dIssue 1 true), .recv (.h2dReady 1), .recv (.h2dDone 1 true),
      -- Now pool 0 (rank 0) lands and runs its coarse H2D copy, clobbering dstHbm[1]!
      .landStream 0, .recv (.onPoolReceived 0),
      .recv (.h2dIssue 0 true), .recv (.h2dReady 0), .recv (.h2dDone 0 true),
      .recv (.pushEnd true), .recv .publish ]
  let s := ((sysRankBlind [0, 1] [1, 2]).run evs).getD (init [0, 1] [1, 2])
  have hrun : (sysRankBlind [0, 1] [1, 2]).run evs = some s := by decide
  refine ⟨s, (sysRankBlind [0, 1] [1, 2]).run_reachable hrun, by decide, by decide, ?_, ?_⟩
  · intro hpub
    have := hpub (by decide)
    revert this; decide
  · intro hal
    have := hal 1 (by decide) { rank := 1, stage := .completed } (by decide) rfl
    revert this; decide

def stepPrematurePoolReceived (s : Pipeline) : Ev → Option Pipeline
  | .recv (.onPoolReceived p) =>
    if 0 < s.landedStreams.getD p 0 then
      (Recv.step .shipping s.recv (.onPoolReceived p)).map fun rcv =>
        { s with recv := rcv }
    else none
  | e => step s e

def sysPrematurePoolReceived (ranks peerCounts : List Nat) : System Pipeline Ev :=
  ⟨init ranks peerCounts, stepPrematurePoolReceived⟩

/-- Mutant 2: firing `OnPoolReceived(0)` after 1 stream when `peerCounts = [2]`
violates `StreamAccountingSafe`. -/
theorem mutant_onPoolReceived_before_all_streams :
    ∃ s, (sysPrematurePoolReceived [0] [2]).Reachable s ∧ ¬StreamAccountingSafe s := by
  let evs : List Ev :=
    [ .send (.d2hIssue 0 true), .send .execFinish,
      .send (.d2hDone 0 true), .send (.pushDone 0 true),
      .recv .pushBegin, .landStream 0, .recv (.onPoolReceived 0) ]
  let s := ((sysPrematurePoolReceived [0] [2]).run evs).getD (init [0] [2])
  have hrun : (sysPrematurePoolReceived [0] [2]).run evs = some s := by decide
  refine ⟨s, (sysPrematurePoolReceived [0] [2]).run_reachable hrun, ?_⟩
  intro hstr
  have ⟨_, _, hstage⟩ := hstr 0 (by decide)
  have := hstage { rank := 0, stage := .queued } (by decide) (by decide)
  revert this; decide

def stepReclaimEarly (s : Pipeline) : Ev → Option Pipeline
  | .reclaim =>
    if s.reclaimed = false then
      some { s with srcHbm := List.replicate s.numPools .junk, reclaimed := true }
    else none
  | e => step s e

def sysReclaimEarly (ranks peerCounts : List Nat) : System Pipeline Ev :=
  ⟨init ranks peerCounts, stepReclaimEarly⟩

/-- Mutant 3: reclaiming producer HBM before `send.published ≠ none` causes D2H
to stage `.junk` and publish `done_recving` with `dstHbm = [.junk] ≠ good 1`. -/
theorem mutant_reclaim_before_publish_corrupts_dstHbm :
    ∃ s, (sysReclaimEarly [0] [1]).Reachable s ∧
      s.recv.published = some true ∧ s.dstHbm = [.junk] ∧ ¬PublicationCorrect s := by
  let evs : List Ev :=
    [ .reclaim,
      .send (.d2hIssue 0 true), .send .execFinish,
      .send (.d2hDone 0 true), .send (.pushDone 0 true),
      .recv .pushBegin, .landStream 0, .recv (.onPoolReceived 0),
      .recv (.h2dIssue 0 true), .recv (.h2dReady 0), .recv (.h2dDone 0 true),
      .recv (.pushEnd true), .recv .publish ]
  let s := ((sysReclaimEarly [0] [1]).run evs).getD (init [0] [1])
  have hrun : (sysReclaimEarly [0] [1]).run evs = some s := by decide
  refine ⟨s, (sysReclaimEarly [0] [1]).run_reachable hrun, by decide, by decide, ?_⟩
  intro hpub
  have := hpub (by decide)
  revert this; decide

end Pipeline
end TpuSyncVerify.Transfer.Reshard

