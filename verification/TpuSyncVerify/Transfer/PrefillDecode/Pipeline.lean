import TpuSyncVerify.Transfer.PrefillDecode.Receive
import TpuSyncVerify.Transfer.PrefillDecode.Send

/-!
# Prefill-to-decode pipeline

Stage 4 of the prefill-to-decode model: one `Send` session, one `Recv` session
and the five memories the KV data moves through between them. The sessions
are the stage 1-3 models, used as-is; this file adds what they abstract away —
*which bytes* each copy moves — and proves the proposal's publication
correctness: when the decode engine is told `done_recving`, its HBM holds the
prefill's KV cache. The buffer-safety properties of the proposal (prefill
blocks reclaimed, staging released) turn out to be corollaries of the
sessions' settle protocol and are stated here too.

Citations are to tpu-sync `01ffa3d`: `send.cc` is
`tpu_sync/core/transfer_send_session.cc`, `recv.cc` is
`tpu_sync/core/transfer_receive_session.cc`, `bt.cc` is
`tpu_sync/transport/block_transport.cc`, `mgr.cc` is
`tpu_sync/core/kv_cache_manager_with_transfer.cc`.

## Memories

A memory is a list indexed by layer. A `Cell` is `.kv l` (layer `l`'s KV
data), `.junk` (whatever a buffer held before, or holds after it was reused)
or `.blank` (never written). Layer `l` of a memory is correct iff it is
`.kv l`.

| Memory           | Role | Written by |
|------------------|------|------------|
| `prefillHbm`     | the request's KV blocks on the prefill device | `reclaim` (the engine frees them) |
| `prefillStaging` | the send's host staging (`send.cc:286-291`) | `d2hDone` (D2H copy, `send.cc:332-341`), `reseatPrefillStaging` |
| `wire`           | data delivered by a direct H2H write (`send.cc:424-445`) | `h2hDone true` |
| `decodeStaging`  | the receive's host staging | `land` (transport, `bt.cc:436-470`), `reseatDecodeStaging` |
| `decodeHbm`      | the decode request's KV blocks | `h2dReady` (H2D copy, `recv.cc:575-696`) |

`landed` counts layers the transport has written into `decodeStaging`;
`reclaimed` records that the engine has freed the prefill blocks.

## Events

| Event                   | What it is |
|-------------------------|-----------|
| `send e`                | the send session's event `e`, plus its memory effect: `d2hDone` copies layer `d2hReady` from `prefillHbm` to `prefillStaging`; `h2hDone true` copies layer `h2hRetired` from `prefillStaging` to the `wire` |
| `recv e`                | the receive session's event `e`, plus: `h2dBegin` additionally requires layer `issued + pending` to have landed (`OnLayerReceived` fires after the layer's last block, `bt.cc:528-530`); `h2dReady` copies layer `ready` from `decodeStaging` to `decodeHbm` |
| `land`                  | the transport writes the next layer from the wire into `decodeStaging`, inside an accepted push (`bt.cc:350` … `bt.cc:586`) |
| `reclaim`               | the engine frees the prefill blocks once `poll_stats()` has reported the send (`mgr.cc:918-925`) |
| `reseatPrefillStaging`  | the host staging pool hands the send's released staging to someone else, who writes to it |
| `reseatDecodeStaging`   | likewise for the receive's staging |

A copy reads its source when it *completes*, not when it is issued. This is
the pessimistic choice: a source that is overwritten at any point during the
copy may be read after the overwrite. Corruption is never undone, so a model
that reads at issue time admits no violation this one does not.

## Assumptions

* **A1 (layers move whole).** Blocks are not modelled: a layer is copied as a
  unit. The transport delivers a layer's blocks individually but reports the
  layer only once the last block is in (`on_layer_received_called`,
  `bt.cc:528-530`), and both device copies are per layer.
* **A2 (delivery after the callback).** The sender's push callback
  (`h2hDone`) puts the data on the wire and the receiver lands it later. In
  the real system the write has landed *before* the callback fires. The
  model admits more interleavings than the system; nothing the producer does
  between the two changes what was delivered, so every real behaviour is
  included.
* **A3 (one sender).** Layers land in order from a single producer. With
  several producers per layer the indices interleave but each layer's data
  still comes from a copy that read a correct source, which is all the proof
  uses.
* **A4 (engine contract).** The decode engine reads the KV cache only after
  `poll_stats()` reports `done_recving`; the prefill engine frees the blocks
  only after it reports the send. Both are outside tpu-sync.

## Properties

All proved on every reachable state (`reachable_safe`):

* **Publication correctness.** `recv.published = some true → decodeHbm = good n`:
  when the engine is told `done_recving`, decode HBM holds every layer of the
  prefill's KV cache. Property (1) of the proposal.
* **Attention safety** (`attention_safe`). Publication is permanent
  (`Recv.step_published_mono`) and the property holds in every reachable
  state, so decode HBM stays correct for the rest of the run — in particular
  whenever the engine runs attention over it. Property (2).
* **Source-buffer safety.** `reclaimed → d2hRetired = d2hIssued`: when the
  engine frees the prefill blocks no D2H copy is reading them, and (since the
  send has settled) none will be issued. Property (3).
* **Staging safety.** A send whose staging was released has no copy writing
  it and no push reading it; a receive whose staging was released has no push
  writing it and no copy reading it. Property (4). Both follow from
  `done → inFlight = 0` and the sessions' accounting of `in_flight_`.

Why the proof goes through, in one paragraph. A copy that completes is still
in flight, so its session is not settled; a session that is not settled still
owns its staging (nobody has reseated it) and, on the send side, the engine
has not reclaimed the blocks (it does that only after publication, which
needs settling). So every copy reads a buffer that nobody else has touched,
and by induction on the chain HBM → staging → wire → staging → HBM each
layer that arrives is the right one. The guards that make this true are
exactly the sessions' refusal to begin an op once draining and their refusal
to settle while an op is in flight — the settle protocol of stage 1.
-/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)

/-- What a layer slot of a memory holds. -/
inductive Cell where
  | blank
  | kv (layer : Nat)
  | junk
  deriving Repr, DecidableEq

structure Pipeline where
  numLayers : Nat
  send : Send
  recv : Recv
  prefillHbm : List Cell
  prefillStaging : List Cell
  wire : List Cell
  decodeStaging : List Cell
  decodeHbm : List Cell
  landed : Nat := 0
  reclaimed : Bool := false
  deriving Repr, DecidableEq

namespace Pipeline

/-- A memory holding layers `0 … n-1` correctly. -/
def good (n : Nat) : List Cell := (List.range n).map Cell.kv

/-- A registered send and a `StartRead` receive (`Recv.initLoad`: the path
the Hybrid Bridge uses) for the same `n`-layer request. The prefill's blocks
hold the data; every other buffer holds whatever its previous user left. -/
def init (n : Nat) : Pipeline :=
  { numLayers := n, send := Send.init n, recv := Recv.initLoad n,
    prefillHbm := good n, prefillStaging := List.replicate n .junk,
    wire := List.replicate n .blank, decodeStaging := List.replicate n .junk,
    decodeHbm := List.replicate n .junk }

inductive Ev where
  | send (e : Send.Ev)
  | recv (e : Recv.Ev)
  | land
  | reclaim
  | reseatPrefillStaging
  | reseatDecodeStaging
  deriving Repr, DecidableEq

/-- A send event with its memory effect, computed from the pre-state. -/
def sendStep (s : Pipeline) (e : Send.Ev) : Option Pipeline :=
  (Send.step s.send e).map fun snd =>
    match e with
    | .d2hDone =>
      { s with send := snd,
               prefillStaging := s.prefillStaging.set s.send.d2hReady
                 (s.prefillHbm.getD s.send.d2hReady .junk) }
    | .h2hDone true =>
      { s with send := snd,
               wire := s.wire.set s.send.h2hRetired
                 (s.prefillStaging.getD s.send.h2hRetired .junk) }
    | _ => { s with send := snd }

/-- A receive event with its memory effect. -/
def recvStep (s : Pipeline) : Recv.Ev → Option Pipeline
  | .h2dBegin =>
    if s.recv.issued + s.recv.pending < s.landed then
      (Recv.step s.recv .h2dBegin).map fun rcv => { s with recv := rcv }
    else none
  | .h2dReady =>
    (Recv.step s.recv .h2dReady).map fun rcv =>
      { s with recv := rcv,
               decodeHbm := s.decodeHbm.set s.recv.ready
                 (s.decodeStaging.getD s.recv.ready .junk) }
  | e => (Recv.step s.recv e).map fun rcv => { s with recv := rcv }

/-- The transport lands the next layer, if something has been delivered for
it, inside an accepted push. -/
def land (s : Pipeline) : Option Pipeline :=
  if s.recv.pushes = 0 then none
  else match s.wire[s.landed]? with
    | some c =>
      if c = .blank then none
      else some { s with decodeStaging := s.decodeStaging.set s.landed c, landed := s.landed + 1 }
    | none => none

/-- The engine frees the prefill blocks after the send was reported. -/
def reclaim (s : Pipeline) : Option Pipeline :=
  if s.send.published ≠ none ∧ s.reclaimed = false then
    some { s with prefillHbm := List.replicate s.numLayers .junk, reclaimed := true }
  else none

/-- Released staging is somebody else's buffer. -/
def reseatPrefillStaging (s : Pipeline) : Option Pipeline :=
  if s.send.life.hasStaging = false then
    some { s with prefillStaging := List.replicate s.numLayers .junk }
  else none

def reseatDecodeStaging (s : Pipeline) : Option Pipeline :=
  if s.recv.life.hasStaging = false then
    some { s with decodeStaging := List.replicate s.numLayers .junk }
  else none

def step (s : Pipeline) : Ev → Option Pipeline
  | .send e => s.sendStep e
  | .recv e => s.recvStep e
  | .land => s.land
  | .reclaim => s.reclaim
  | .reseatPrefillStaging => s.reseatPrefillStaging
  | .reseatDecodeStaging => s.reseatDecodeStaging

/-- An `n`-layer transfer. -/
def sys (n : Nat) : System Pipeline Ev := ⟨init n, step⟩

/-! ## Properties -/

/-- When the engine is told `done_recving`, decode HBM holds the KV cache. -/
def PublicationCorrect (s : Pipeline) : Prop :=
  s.recv.published = some true → s.decodeHbm = good s.numLayers

/-- When the engine frees the prefill blocks, no copy is reading them. -/
def SourceBufferSafe (s : Pipeline) : Prop :=
  s.reclaimed = true → s.send.d2hRetired = s.send.d2hIssued

/-- Released staging has no copy writing it and no push or copy reading it. -/
def StagingSafe (s : Pipeline) : Prop :=
  (s.send.life.hasStaging = false →
    s.send.d2hRetired = s.send.d2hIssued ∧ s.send.h2hRetired = s.send.h2hIssued) ∧
  (s.recv.life.hasStaging = false → s.recv.pushes = 0 ∧ s.recv.retired = s.recv.issued)

def Safe (s : Pipeline) : Prop := PublicationCorrect s ∧ SourceBufferSafe s ∧ StagingSafe s

/-! ## Inductive invariant -/

structure Inv (s : Pipeline) : Prop where
  send : s.send.Inv
  recv : s.recv.Inv
  n_send : s.send.numLayers = s.numLayers
  n_recv : s.recv.numLayers = s.numLayers
  len_pstaging : s.prefillStaging.length = s.numLayers
  len_wire : s.wire.length = s.numLayers
  len_dstaging : s.decodeStaging.length = s.numLayers
  len_dhbm : s.decodeHbm.length = s.numLayers
  /-- The prefill blocks hold the data until the engine reclaims them. -/
  hbm_good : s.reclaimed = false → s.prefillHbm = good s.numLayers
  /-- Blocks are reclaimed only once the send has settled. -/
  reclaimed_done : s.reclaimed = true → s.send.life.done = true
  /-- While the send holds its staging, every finished copy's layer is there. -/
  staging_good : s.send.life.done = false →
    ∀ k < s.send.d2hReady, s.prefillStaging[k]? = some (.kv k)
  /-- Whatever was delivered for layer `k` is layer `k`. -/
  wire_good : ∀ k (c : Cell), s.wire[k]? = some c → c = .blank ∨ c = .kv k
  /-- A layer is handed to the device only after it landed. -/
  dispatched_le_landed : s.recv.issued + s.recv.pending ≤ s.landed
  /-- While the receive holds its staging, every landed layer is there. -/
  dstaging_good : s.recv.life.done = false →
    ∀ k < s.landed, s.decodeStaging[k]? = some (.kv k)
  /-- Every finished copy put its layer in decode HBM. -/
  dhbm_good : ∀ k < s.recv.ready, s.decodeHbm[k]? = some (.kv k)

/-! ### Facts about `good` -/

theorem good_length (n : Nat) : (good n).length = n := by simp [good]

theorem good_get {n k : Nat} (hk : k < n) : (good n)[k]? = some (.kv k) := by simp [good, hk]

theorem good_getD {n k : Nat} (hk : k < n) : (good n).getD k .junk = .kv k := by
  simp [List.getD_eq_getElem?_getD, good, hk]

theorem eq_good {l : List Cell} {n : Nat} (hlen : l.length = n)
    (hget : ∀ k < n, l[k]? = some (.kv k)) : l = good n := by
  apply List.ext_getElem?
  intro i
  by_cases hi : i < n
  · rw [hget i hi, good_get hi]
  · rw [List.getElem?_eq_none (by omega), List.getElem?_eq_none (by rw [good_length]; omega)]

/-- Writing `.kv k` at a valid index `k` of a memory that was correct below
`m` makes it correct below `max m (k+1)`; in particular below `k + 1` when
`k ≤ m`. -/
theorem set_good {l : List Cell} {k m : Nat} (hk : k < l.length) (hkm : k ≤ m)
    (hl : ∀ j < m, l[j]? = some (.kv j)) :
    ∀ j < k + 1, (l.set k (.kv k))[j]? = some (.kv j) := by
  intro j hj
  by_cases hjk : j = k
  · subst hjk; exact List.getElem?_set_self hk
  · rw [List.getElem?_set_ne (Ne.symm hjk)]; exact hl j (by omega)

theorem inv_init (n : Nat) : Inv (init n) := by
  refine ⟨Send.inv_init n, Recv.inv_initLoad n, rfl, rfl, by simp [init], by simp [init],
    by simp [init], by simp [init], fun _ => rfl, by simp [init, Send.init], ?_, ?_,
    by simp [init, Recv.initLoad], by simp [init], by simp [init, Recv.initLoad]⟩
  · simp [init, Send.init]
  · intro k c hk
    simp only [init, List.getElem?_replicate] at hk
    split at hk
    · cases hk; exact Or.inl rfl
    · cases hk

theorem inv_safe {s : Pipeline} (h : Inv s) : Safe s := by
  have hsend := h.send
  have hrecv := h.recv
  have hsS := Send.inv_safe hsend
  have hcnt := hsend.counters
  unfold Send.Counters at hcnt
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro hp
    apply eq_good h.len_dhbm
    intro k hk
    apply h.dhbm_good
    have := hrecv.published_ok hp
    have := hrecv.completed_le
    have := hrecv.retired_le
    have := h.n_recv
    omega
  · intro hr
    exact (hsS.2.1 (h.reclaimed_done hr)).2.1
  · intro hst
    obtain ⟨-, h1, -, -, -, h2⟩ := hsS.2.1 (hsend.life.done_of_released hst)
    exact ⟨h1, h2⟩
  · intro hst
    have hd := hrecv.life.done_of_released hst
    have h0 := hrecv.life.done_idle hd
    have hacc := hrecv.accounted
    unfold Recv.Accounted at hacc
    have := hrecv.retired_le
    have := hrecv.ready_le
    constructor <;> omega

/-! ### Preservation, one lemma per kind of effect -/

/-- A send event that moves no memory. -/
theorem Inv.send_frame {s : Pipeline} {snd : Send} {e : Send.Ev} (h : Inv s)
    (hs : Send.step s.send e = some snd) (he : e ≠ .d2hDone) : Inv { s with send := snd } := by
  refine ⟨Send.step_inv h.send hs, h.recv, (Send.step_numLayers hs).trans h.n_send, h.n_recv,
    h.len_pstaging, h.len_wire, h.len_dstaging, h.len_dhbm, h.hbm_good,
    fun hr => Send.step_done_mono hs (h.reclaimed_done hr), ?_, h.wire_good,
    h.dispatched_le_landed, h.dstaging_good, h.dhbm_good⟩
  show snd.life.done = false → ∀ k < snd.d2hReady, s.prefillStaging[k]? = some (.kv k)
  intro hd
  rw [Send.step_d2hReady hs he]
  apply h.staging_good
  cases hd0 : s.send.life.done
  · rfl
  · rw [Send.step_done_mono hs hd0] at hd; cases hd

/-- A send that still has a copy or push outstanding has not settled. -/
theorem send_not_done_of_outstanding {t : Send} (h : t.Inv)
    (ho : t.d2hReady < t.d2hIssued ∨ t.h2hRetired < t.h2hIssued) : t.life.done = false := by
  cases hd : t.life.done
  · rfl
  · have hdr := (Send.inv_safe h).2.1 hd
    have hcnt := h.counters
    unfold Send.Counters at hcnt
    omega

/-- The D2H copy of layer `d2hReady` lands in staging. -/
theorem Inv.send_d2hDone {s : Pipeline} {snd : Send} (h : Inv s)
    (hs : Send.step s.send .d2hDone = some snd) :
    Inv { s with send := snd,
                 prefillStaging := s.prefillStaging.set s.send.d2hReady
                   (s.prefillHbm.getD s.send.d2hReady .junk) } := by
  obtain ⟨hlt, rfl⟩ := Send.d2hDone_spec hs
  have hcnt := h.send.counters
  unfold Send.Counters at hcnt
  have hd : s.send.life.done = false := send_not_done_of_outstanding h.send (Or.inl hlt)
  have hnr : s.reclaimed = false := by
    cases hr : s.reclaimed
    · rfl
    · have := h.reclaimed_done hr; rw [hd] at this; cases this
  have hk : s.send.d2hReady < s.numLayers := by have := h.n_send; omega
  have hsrc : s.prefillHbm.getD s.send.d2hReady .junk = .kv s.send.d2hReady := by
    rw [h.hbm_good hnr]; exact good_getD hk
  rw [hsrc]
  refine ⟨Send.step_inv h.send hs, h.recv, (Send.step_numLayers hs).trans h.n_send, h.n_recv,
    ?_, h.len_wire, h.len_dstaging, h.len_dhbm, h.hbm_good,
    fun hr => Send.step_done_mono hs (h.reclaimed_done hr), ?_, h.wire_good,
    h.dispatched_le_landed, h.dstaging_good, h.dhbm_good⟩
  · show (s.prefillStaging.set _ _).length = _
    rw [List.length_set]; exact h.len_pstaging
  · show _ → ∀ k < s.send.d2hReady + 1, (s.prefillStaging.set _ _)[k]? = some (.kv k)
    intro _
    exact set_good (by rw [h.len_pstaging]; exact hk) (Nat.le_refl _) (h.staging_good hd)

/-- A successful push of layer `h2hRetired` delivers it. -/
theorem Inv.send_h2hDone {s : Pipeline} {snd : Send} (h : Inv s)
    (hs : Send.step s.send (.h2hDone true) = some snd) :
    Inv { s with send := snd,
                 wire := s.wire.set s.send.h2hRetired
                   (s.prefillStaging.getD s.send.h2hRetired .junk) } := by
  have hlt := Send.h2hDone_guard hs
  have hcnt := h.send.counters
  unfold Send.Counters at hcnt
  have hd : s.send.life.done = false := send_not_done_of_outstanding h.send (Or.inr hlt)
  have hk : s.send.h2hRetired < s.numLayers := by have := h.n_send; omega
  have hsrc : s.prefillStaging.getD s.send.h2hRetired .junk = .kv s.send.h2hRetired := by
    rw [List.getD_eq_getElem?_getD, h.staging_good hd _ (by omega)]; rfl
  rw [hsrc]
  have h' := h.send_frame hs nofun
  refine ⟨h'.send, h'.recv, h'.n_send, h'.n_recv, h'.len_pstaging, ?_, h'.len_dstaging,
    h'.len_dhbm, h'.hbm_good, h'.reclaimed_done, h'.staging_good, ?_,
    h'.dispatched_le_landed, h'.dstaging_good, h'.dhbm_good⟩
  · show (s.wire.set _ _).length = _
    rw [List.length_set]; exact h.len_wire
  · show ∀ j (c : Cell), (s.wire.set s.send.h2hRetired _)[j]? = some c → c = .blank ∨ c = .kv j
    intro j c hj
    by_cases hjk : j = s.send.h2hRetired
    · subst hjk
      rw [List.getElem?_set_self (by rw [h.len_wire]; exact hk)] at hj
      cases hj; exact Or.inr rfl
    · rw [List.getElem?_set_ne (Ne.symm hjk)] at hj
      exact h.wire_good j c hj

/-- A receive event that moves no memory, given that it respects landing. -/
theorem Inv.recv_frame {s : Pipeline} {rcv : Recv} {e : Recv.Ev} (h : Inv s)
    (hs : Recv.step s.recv e = some rcv) (he : e ≠ .h2dReady)
    (hil : rcv.issued + rcv.pending ≤ s.landed) : Inv { s with recv := rcv } := by
  refine ⟨h.send, Recv.step_inv h.recv hs, h.n_send, (Recv.step_numLayers hs).trans h.n_recv,
    h.len_pstaging, h.len_wire, h.len_dstaging, h.len_dhbm, h.hbm_good, h.reclaimed_done,
    h.staging_good, h.wire_good, hil, ?_, ?_⟩
  · show rcv.life.done = false → ∀ k < s.landed, s.decodeStaging[k]? = some (.kv k)
    intro hd
    apply h.dstaging_good
    cases hd0 : s.recv.life.done
    · rfl
    · rw [Recv.step_done_mono hs hd0] at hd; cases hd
  · show ∀ k < rcv.ready, s.decodeHbm[k]? = some (.kv k)
    rw [Recv.step_ready hs he]; exact h.dhbm_good

/-- The H2D copy of layer `ready` lands in decode HBM. -/
theorem Inv.recv_h2dReady {s : Pipeline} {rcv : Recv} (h : Inv s)
    (hs : Recv.step s.recv .h2dReady = some rcv) :
    Inv { s with recv := rcv,
                 decodeHbm := s.decodeHbm.set s.recv.ready
                   (s.decodeStaging.getD s.recv.ready .junk) } := by
  obtain ⟨hlt, rfl⟩ := Recv.h2dReady_spec hs
  have hr := h.recv
  have hd : s.recv.life.done = false := by
    cases hd : s.recv.life.done
    · rfl
    · have := (Recv.inv_safe hr).2.1 hd
      have := hr.retired_le
      omega
  have hk : s.recv.ready < s.numLayers := by
    have := hr.issued_le; have := h.n_recv; omega
  have hsrc : s.decodeStaging.getD s.recv.ready .junk = .kv s.recv.ready := by
    rw [List.getD_eq_getElem?_getD,
      h.dstaging_good hd _ (by have := h.dispatched_le_landed; omega)]
    rfl
  rw [hsrc]
  refine ⟨h.send, Recv.step_inv hr hs, h.n_send, (Recv.step_numLayers hs).trans h.n_recv,
    h.len_pstaging, h.len_wire, h.len_dstaging, ?_, h.hbm_good, h.reclaimed_done,
    h.staging_good, h.wire_good, h.dispatched_le_landed, h.dstaging_good, ?_⟩
  · show (s.decodeHbm.set _ _).length = _
    rw [List.length_set]; exact h.len_dhbm
  · show ∀ k < s.recv.ready + 1, (s.decodeHbm.set _ _)[k]? = some (.kv k)
    exact set_good (by rw [h.len_dhbm]; exact hk) (Nat.le_refl _) h.dhbm_good

theorem step_inv {s s' : Pipeline} {e : Ev} (h : Inv s) (hs : step s e = some s') : Inv s' := by
  cases e with
  | send e =>
    cases e <;> (try (rename_i ok; cases ok)) <;>
      simp only [step, sendStep, Option.map_eq_some_iff] at hs <;>
      obtain ⟨snd, hsnd, rfl⟩ := hs
    all_goals first
      | exact h.send_d2hDone hsnd
      | exact h.send_h2hDone hsnd
      | exact h.send_frame hsnd nofun
  | recv e =>
    cases e
    case h2dBegin =>
      simp only [step, recvStep] at hs
      split at hs
      · rename_i hg
        simp only [Option.map_eq_some_iff] at hs
        obtain ⟨rcv, hrcv, rfl⟩ := hs
        have := Recv.h2dBegin_issued_pending hrcv
        exact h.recv_frame hrcv nofun (by omega)
      · cases hs
    case h2dReady =>
      simp only [step, recvStep, Option.map_eq_some_iff] at hs
      obtain ⟨rcv, hrcv, rfl⟩ := hs
      exact h.recv_h2dReady hrcv
    all_goals
      (try (rename_i ok; cases ok))
      all_goals
        simp only [step, recvStep, Option.map_eq_some_iff] at hs
        obtain ⟨rcv, hrcv, rfl⟩ := hs
        exact h.recv_frame hrcv nofun
          (Nat.le_trans (Recv.step_issued_pending hrcv nofun) h.dispatched_le_landed)
  | land =>
    simp only [step, land] at hs
    split at hs
    · cases hs
    split at hs
    · rename_i c hc
      split at hs
      · cases hs
      rename_i hcb
      cases hs
      have hkv : c = .kv s.landed := (h.wire_good _ _ hc).resolve_left hcb
      have hlen : s.landed < s.numLayers := by
        have := (List.getElem?_eq_some_iff.mp hc).1
        rw [h.len_wire] at this; exact this
      subst hkv
      refine ⟨h.send, h.recv, h.n_send, h.n_recv, h.len_pstaging, h.len_wire, ?_, h.len_dhbm,
        h.hbm_good, h.reclaimed_done, h.staging_good, h.wire_good, ?_, ?_, h.dhbm_good⟩
      · show (s.decodeStaging.set _ _).length = _
        rw [List.length_set]; exact h.len_dstaging
      · show s.recv.issued + s.recv.pending ≤ s.landed + 1
        have := h.dispatched_le_landed; omega
      · show _ → ∀ k < s.landed + 1, (s.decodeStaging.set _ _)[k]? = some (.kv k)
        intro hd
        exact set_good (by rw [h.len_dstaging]; exact hlen) (Nat.le_refl _) (h.dstaging_good hd)
    · cases hs
  | reclaim =>
    simp only [step, reclaim] at hs
    split at hs
    · rename_i hg
      obtain ⟨hp, -⟩ := hg
      cases hs
      obtain ⟨b, hb⟩ := Option.ne_none_iff_exists'.mp hp
      refine ⟨h.send, h.recv, h.n_send, h.n_recv, h.len_pstaging, h.len_wire, h.len_dstaging,
        h.len_dhbm, ?_, ?_, h.staging_good, h.wire_good, h.dispatched_le_landed,
        h.dstaging_good, h.dhbm_good⟩
      · show true = false → _
        intro hc; cases hc
      · show _ → s.send.life.done = true
        intro _; exact h.send.published_done b hb
    · cases hs
  | reseatPrefillStaging =>
    simp only [step, reseatPrefillStaging] at hs
    split at hs
    · rename_i hst
      cases hs
      have hd := h.send.life.done_of_released hst
      refine ⟨h.send, h.recv, h.n_send, h.n_recv, ?_, h.len_wire, h.len_dstaging,
        h.len_dhbm, h.hbm_good, h.reclaimed_done, ?_, h.wire_good, h.dispatched_le_landed,
        h.dstaging_good, h.dhbm_good⟩
      · show (List.replicate _ _).length = _
        exact List.length_replicate
      · show s.send.life.done = false → _
        intro hn; rw [hd] at hn; cases hn
    · cases hs
  | reseatDecodeStaging =>
    simp only [step, reseatDecodeStaging] at hs
    split at hs
    · rename_i hst
      cases hs
      have hd := h.recv.life.done_of_released hst
      refine ⟨h.send, h.recv, h.n_send, h.n_recv, h.len_pstaging, h.len_wire, ?_,
        h.len_dhbm, h.hbm_good, h.reclaimed_done, h.staging_good, h.wire_good,
        h.dispatched_le_landed, ?_, h.dhbm_good⟩
      · show (List.replicate _ _).length = _
        exact List.length_replicate
      · show s.recv.life.done = false → _
        intro hn; rw [hd] at hn; cases hn
    · cases hs

theorem reachable_inv {n : Nat} {s : Pipeline} (h : (sys n).Reachable s) : Inv s :=
  (sys n).reachable_induction (inv_init n) (fun _ _ _ hi hs => step_inv hi hs) h

/-- Main result: every reachable state of the pipeline satisfies all the
properties. -/
theorem reachable_safe {n : Nat} {s : Pipeline} (h : (sys n).Reachable s) : Safe s :=
  inv_safe (reachable_inv h)

/-! ### Attention safety -/

theorem step_numLayers {s s' : Pipeline} {e : Ev} (hs : step s e = some s') :
    s'.numLayers = s.numLayers := by
  cases e with
  | send e =>
    cases e <;> (try (rename_i ok; cases ok)) <;>
      simp only [step, sendStep, Option.map_eq_some_iff] at hs <;>
      obtain ⟨_, _, rfl⟩ := hs <;> rfl
  | recv e =>
    cases e <;> simp only [step, recvStep, Option.map_eq_some_iff] at hs <;>
      (try split at hs) <;> (try simp only [Option.map_eq_some_iff] at hs) <;>
      first | (obtain ⟨_, _, rfl⟩ := hs; rfl) | cases hs
  | _ =>
    simp only [step, land, reclaim, reseatPrefillStaging, reseatDecodeStaging] at hs
    repeat' split at hs
    all_goals (cases hs <;> rfl)

theorem step_published_mono {s s' : Pipeline} {e : Ev} {b : Bool} (hs : step s e = some s')
    (hp : s.recv.published = some b) : s'.recv.published = some b := by
  cases e with
  | send e =>
    cases e <;> (try (rename_i ok; cases ok)) <;>
      simp only [step, sendStep, Option.map_eq_some_iff] at hs <;>
      obtain ⟨_, _, rfl⟩ := hs <;> exact hp
  | recv e =>
    cases e <;> simp only [step, recvStep, Option.map_eq_some_iff] at hs <;>
      (try split at hs) <;> (try simp only [Option.map_eq_some_iff] at hs) <;>
      first | (obtain ⟨_, hr, rfl⟩ := hs; exact Recv.step_published_mono hr hp) | cases hs
  | _ =>
    simp only [step, land, reclaim, reseatPrefillStaging, reseatDecodeStaging] at hs
    repeat' split at hs
    all_goals (cases hs <;> exact hp)

theorem numLayers_eq {n : Nat} {s : Pipeline} (h : (sys n).Reachable s) : s.numLayers = n :=
  (sys n).reachable_induction (P := fun s => s.numLayers = n) rfl
    (fun _ _ _ hi hs => (step_numLayers hs).trans hi) h

theorem runFrom_published_mono {n : Nat} {b : Bool} :
    ∀ (evs : List Ev) {s s' : Pipeline}, s.recv.published = some b →
      (sys n).runFrom s evs = some s' → s'.recv.published = some b := by
  intro evs
  induction evs with
  | nil =>
    intro s s' hp h
    simp [System.runFrom] at h
    exact h ▸ hp
  | cons e evs ih =>
    intro s s' hp h
    simp only [System.runFrom, List.foldlM_cons] at h
    cases hse : step s e with
    | none => simp [sys, hse] at h
    | some s₁ =>
      simp only [sys, hse] at h
      exact ih (step_published_mono hse hp) h

/-- Once the engine has been told `done_recving`, decode HBM holds the KV
cache from then on: nothing in the rest of the run disturbs it. -/
theorem attention_safe {n : Nat} {s s' : Pipeline} (h : (sys n).Reachable s)
    (hp : s.recv.published = some true) (evs : List Ev)
    (hr : (sys n).runFrom s evs = some s') : s'.decodeHbm = good n := by
  have h' := (sys n).runFrom_reachable h evs hr
  rw [← numLayers_eq h']
  exact (reachable_safe h').1 (runFrom_published_mono evs hp hr)

/-! ## Replay and bounded search

Concrete traces, checked by `decide`, that document the behaviours the model
admits; bounded searches on the one-layer instance; and two mutants that show
the memory model is sensitive to the guards the proof rests on. -/

/-- A one-layer producer, start to `done_sending`. -/
def producer : List Ev :=
  [.send .start, .send .d2hBegin, .send (.d2hIssue true), .send .d2hDone, .send .d2hEnd,
   .send (.wake true), .send .h2hIssue, .send .sendNext, .send (.h2hDone true), .send .publish]

/-- A one-layer consumer, pull handshake to `done_recving`. -/
def consumer : List Ev :=
  [.recv (.pullReply true), .recv .pushBegin, .land, .recv .pushEnd, .recv .h2dBegin,
   .recv (.h2dIssue true), .recv .netAccount, .recv .h2dReady, .recv (.h2dDone true),
   .recv .publish]

/-- Producer then consumer: both sides published as done, the data in decode
HBM. -/
theorem trace_normal :
    ((sys 1).run (producer ++ consumer)).map
      (fun s => (s.send.published, s.recv.published, s.decodeHbm)) =
    some (some true, some true, [.kv 0]) := by
  decide

/-- The producer is long gone — published, blocks reclaimed, staging reused —
before the consumer lands the layer; the data is still right (A2). -/
theorem trace_slow_consumer :
    ((sys 1).run (producer ++ [.reclaim, .reseatPrefillStaging] ++ consumer)).map
      (fun s => (s.reclaimed, s.prefillHbm, s.prefillStaging, s.recv.published, s.decodeHbm)) =
    some (true, [.junk], [.junk], some true, [.kv 0]) := by
  decide

/-- A receive that has settled takes no push: once its staging is somebody
else's buffer, nothing can land in it. -/
theorem trace_no_push_after_settle :
    ((sys 1).run [.recv .cancel, .recv (.pullReply true), .recv .publish, .reseatDecodeStaging]).map
      (fun s => (s.recv.published, s.recv.life.hasStaging)) = some (some false, false) ∧
    (sys 1).run [.recv .cancel, .recv (.pullReply true), .recv .publish, .reseatDecodeStaging,
      .recv .pushBegin] = none ∧
    (sys 1).run [.recv .cancel, .recv (.pullReply true), .recv .publish, .reseatDecodeStaging,
      .land] = none := by
  decide

/-- The layer must land before the device is asked to copy it. -/
theorem trace_no_dispatch_before_land :
    (sys 1).run [.recv (.pullReply true), .recv .h2dBegin] = none := by
  decide

def events : List Ev :=
  Send.events.map .send ++ Recv.events.map .recv ++
    [.land, .reclaim, .reseatPrefillStaging, .reseatDecodeStaging]

/-- Executable negation of `Safe`. -/
def violates (s : Pipeline) : Bool :=
  (s.recv.published == some true && s.decodeHbm != good s.numLayers) ||
  (s.reclaimed && s.send.d2hRetired != s.send.d2hIssued) ||
  (!s.send.life.hasStaging &&
    (s.send.d2hRetired != s.send.d2hIssued || s.send.h2hRetired != s.send.h2hIssued)) ||
  (!s.recv.life.hasStaging && (s.recv.pushes != 0 || s.recv.retired != s.recv.issued))

#guard ModelCheck.check (sys 1) events violates 10 = .outOfFuel

/-- Publication needs more events than the search above reaches, so search
again from the state the producer leaves behind: every consumer interleaving
with reclaim, staging reuse, cancellation and so on is within reach. -/
def afterProducer : Pipeline := ((sys 1).run producer).getD (init 1)

#guard ModelCheck.check ⟨afterProducer, step⟩ events violates 10 = .outOfFuel

/-- Mutant: `ExecuteLayerH2d` entered before the layer has landed. The copy
moves whatever the staging buffer held, and the receive is published as done
with junk in HBM. -/
def dispatchEarly (s : Pipeline) : Option Pipeline :=
  (Recv.step s.recv .h2dBegin).map fun rcv => { s with recv := rcv }

def sysDispatchEarly : System Pipeline Ev :=
  ⟨init 1, fun s e => match e with
    | .recv .h2dBegin => s.dispatchEarly
    | e => step s e⟩

theorem trace_dispatch_early :
    (sysDispatchEarly.run
      [.recv (.pullReply true), .recv .h2dBegin, .recv (.h2dIssue true), .recv .h2dReady,
       .recv (.h2dDone true), .recv .publish]).map
      (fun s => (s.recv.published, s.decodeHbm)) = some (some true, [.junk]) := by
  decide

#guard (match ModelCheck.check sysDispatchEarly events violates 8 with
        | .counterexample _ => true
        | _ => false)

/-- Mutant: the send's staging goes back to the pool at `Finish` instead of at
settle, i.e. while a push may still be reading it. The pushed data is junk,
the receiver accepts it, and is published as done. This is the failure the
`in_flight_` protocol exists to prevent. -/
def reseatAtFinish (s : Pipeline) : Option Pipeline :=
  if s.send.life.draining = true then
    some { s with prefillStaging := List.replicate s.numLayers .junk }
  else none

theorem trace_reseat_at_finish :
    ((⟨init 1, fun s e => match e with
        | .reseatPrefillStaging => s.reseatAtFinish
        | e => step s e⟩ : System Pipeline Ev).run
      [.send .start, .send .d2hBegin, .send (.d2hIssue true), .send .d2hDone, .send .d2hEnd,
       .send (.wake true), .send .h2hIssue, .send .cancel, .reseatPrefillStaging,
       .send (.h2hDone true),
       .recv (.pullReply true), .recv .pushBegin, .land, .recv .pushEnd, .recv .h2dBegin,
       .recv (.h2dIssue true), .recv .h2dReady, .recv (.h2dDone true), .recv .publish]).map
      (fun s => (s.send.life.done, s.recv.published, s.decodeHbm)) =
    some (false, some true, [.junk]) := by
  decide

end Pipeline

end TpuSyncVerify.Transfer.PrefillDecode
