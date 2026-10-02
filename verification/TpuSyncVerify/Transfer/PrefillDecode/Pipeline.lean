import TpuSyncVerify.Transfer.PrefillDecode.Receive
import TpuSyncVerify.Transfer.PrefillDecode.Send

/-!
# Prefill-to-decode pipeline

Stage 4 of the prefill-to-decode model: one `Send` session, one `Recv` session
and the five memories the KV data moves through between them. The sessions
are the stage 1-3 models, used as-is; this file adds what they abstract away —
*which bytes* each copy moves, and *which layer* each copy is for — and proves
the proposal's publication correctness: when the decode engine is told
`done_recving`, its HBM holds the prefill's KV cache. The buffer-safety
properties of the proposal (prefill HBM reclaimed, staging released) turn
out to be corollaries of the sessions' settle protocol and are stated here too.

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
| `prefillHbm`     | the request's KV cache in prefill HBM | `reclaim` (the engine frees prefill HBM) |
| `prefillStaging` | the send's host staging (`send.cc:286-291`) | `d2hReady l` (D2H copy, `send.cc:332-341`), `reseatPrefillStaging` |
| `wire`           | data delivered by a direct H2H write (`send.cc:424-445`) | `h2hDone l true` |
| `decodeStaging`  | the receive's host staging | `land l` (transport, `bt.cc:436-470`), `reseatDecodeStaging` |
| `decodeHbm`      | the decode request's KV cache in decode HBM | `h2dReady l` (H2D copy, `recv.cc:575-696`) |

## Layers complete in any order

The sessions count copies; they do not say which layer a copy was for. The
real system issues D2H copies in layer order (`send.cc:324`) and pushes in
layer order (`send.cc:449`), but D2H futures resolve in any order, pushes
travel over separate connections and land in any order (`bt.cc:528-530`
reports each layer when *its* last block is in), and H2D futures resolve in
any order. So every event that touches a memory carries the layer it is for,
and per-layer ghost sets record which layers have passed each stage:

| Ghost         | Layers that … | Agrees with |
|---------------|---------------|-------------|
| `d2hReadyL`   | have finished their D2H copy (`prefillStaging[l]` written) | `send.d2hReady` (`cnt_d2hReady`) |
| `h2hRetiredL` | have run their push callback | — |
| `landedL`     | the transport has landed in `decodeStaging` | — |
| `claimedL`    | `OnLayerReceived` has handed to `ExecuteLayerH2d` | — |
| `h2dReadyL`   | have finished their H2D copy (`decodeHbm[l]` written) | `recv.ready` (`cnt_h2dReady`) |

`reclaimed` records that the engine has freed prefill HBM.

## Events

| Event                   | What it is |
|-------------------------|-----------|
| `send e`                | the send session's event `e`, no memory effect. `d2hReady` and `h2hDone` are disabled here (they are the layer-indexed events below). `wake` additionally needs layer `woken`'s copy to have finished: `SendNextLayer(l)` waits on layer `l`'s future (`send.cc:380-384`), not on any future |
| `d2hReady l`            | the D2H copy of layer `l` finishes: `prefillStaging[l] := prefillHbm[l]`. Issued iff `l < d2hIssued` (copies are issued in order) |
| `h2hDone l ok`          | the push callback for layer `l` (`send.cc:428-445`). Push `l` exists iff `l < h2hIssued` (pushes are issued in order). On success `wire[l] := prefillStaging[l]` |
| `recv e`                | the receive session's event `e`, no memory effect. `h2dBegin` and `h2dReady` are disabled here |
| `h2dBegin l`            | `OnLayerReceived(l)` → `ExecuteLayerH2d(l)` up to its first unlock: once per layer (A1), only after layer `l` landed (`bt.cc:528-530`) |
| `h2dReady l`            | the H2D copy of layer `l` finishes: `decodeHbm[l] := decodeStaging[l]` |
| `land l`                | the transport writes layer `l` from the wire into `decodeStaging[l]`, inside an accepted push (`bt.cc:350` … `bt.cc:586`) |
| `reclaim`               | the engine frees prefill HBM once `poll_stats()` has reported the send (`mgr.cc:918-925`) |
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
* **A2 (delivery ordered after the callback).** In the model, the sender's
  push callback (`h2hDone l true`) puts layer `l` on the wire and the
  receiver lands it (`land l`) at or after that step. In the real system the
  write lands *before* the callback fires (the receiver acks after
  `EndIncomingPush`, `bt.cc:586-589`). This reversal is sound because
  `prefillStaging[l]` is invariant throughout `[h2hIssue, h2hDone]`: the push
  holds an op (`in_flight_ > 0`), so the send cannot settle and its staging
  cannot be reseated, and `d2hReady l` has already run before
  `SendNextLayer(l)` woke and cannot run a second time. Reading
  `prefillStaging[l]` at `h2hDone` therefore reads the exact value that was
  present when the real transport streamed the data, so every real trace with
  a successful callback has a model trace with the same receiver-side states.
  The model cannot express a layer that landed whose push callback then
  reports failure (lost ack); that trace is safe for the same reason, but it
  is not in the model.
* **A3 (one sender per layer).** Each layer's data comes from one producer.
  With several producers per layer the transport's block threshold decides
  when the layer is complete; each contributing push still read a correct
  source, which is all the proof uses.
* **A4 (engine contract).** The decode engine reads the KV cache only after
  `poll_stats()` reports `done_recving`; the prefill engine frees prefill HBM
  only after it reports the send. Both are outside tpu-sync.

## Properties

All proved on every reachable state (`reachable_safe`):

* **Publication correctness.** `recv.published = some true → decodeHbm = good n`:
  when the engine is told `done_recving`, decode HBM holds every layer of the
  prefill's KV cache. First half of `proposal.md` §2 *Publication correctness*.
* **Attention safety** (`attention_safe`). Publication is permanent
  (`Recv.step_published_mono`) and the property holds in every reachable
  state, so decode HBM stays correct for the rest of the run — in particular
  whenever the engine runs attention over it. Second half of `proposal.md` §2
  *Publication correctness*.
* **Prefill HBM safety.** `reclaimed → d2hRetired = d2hIssued`: when the
  engine frees prefill HBM no D2H copy is reading it, and (since the
  send has settled) none will be issued. `proposal.md` §2 *Source buffer
  safety*.
* **Staging safety.** A send whose staging was released has no copy writing
  it and no push reading it; a receive whose staging was released has no push
  writing it and no copy reading it. Safety half of `proposal.md` §2 *Staging
  integrity & termination*. Both follow from `done → inFlight = 0` and the
  sessions' accounting of `in_flight_`.

Why the proof goes through, in one paragraph. A copy that completes is still
in flight, so its session is not settled; a session that is not settled still
owns its staging (nobody has reseated it) and, on the send side, the engine
has not reclaimed prefill HBM (it does that only after publication, which
needs settling). So every copy reads a buffer that nobody else has touched,
and each copy for layer `l` reads slot `l` and writes slot `l`, so by
induction on the chain HBM → staging → wire → staging → HBM each layer that
arrives is the right one, whatever order the layers arrive in. The guards that
make this true are exactly the sessions' refusal to begin an op once draining
and their refusal to settle while an op is in flight — the settle protocol of
stage 1 — plus the per-layer guards that a push waits for its own layer's
copy and an H2D dispatch for its own layer's landing.
-/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)

/-- What a layer slot of a memory holds. -/
inductive Cell where
  | blank
  | kv (layer : Nat)
  | junk
  deriving Repr, DecidableEq

/-- Number of `true`s in a per-layer set. -/
def countTrue : List Bool → Nat
  | [] => 0
  | b :: bs => (if b then 1 else 0) + countTrue bs

structure Pipeline where
  numLayers : Nat
  send : Send
  recv : Recv
  prefillHbm : List Cell
  prefillStaging : List Cell
  wire : List Cell
  decodeStaging : List Cell
  decodeHbm : List Cell
  /-- ghost: layers whose D2H copy has finished -/
  d2hReadyL : List Bool
  /-- ghost: layers whose push callback has run -/
  h2hRetiredL : List Bool
  /-- ghost: layers the transport has landed -/
  landedL : List Bool
  /-- ghost: layers handed to `ExecuteLayerH2d` -/
  claimedL : List Bool
  /-- ghost: layers whose H2D copy has finished -/
  h2dReadyL : List Bool
  reclaimed : Bool := false
  deriving Repr, DecidableEq

namespace Pipeline

/-- A memory holding layers `0 … n-1` correctly. -/
def good (n : Nat) : List Cell := (List.range n).map Cell.kv

/-- A registered send and a `StartRead` receive (`Recv.initLoad`: the path
the Hybrid Bridge uses) for the same `n`-layer request. Prefill HBM holds
the data; every other buffer holds whatever its previous user left. -/
def init (n : Nat) : Pipeline :=
  { numLayers := n, send := Send.init n, recv := Recv.initLoad n,
    prefillHbm := good n, prefillStaging := List.replicate n .junk,
    wire := List.replicate n .blank, decodeStaging := List.replicate n .junk,
    decodeHbm := List.replicate n .junk,
    d2hReadyL := List.replicate n false, h2hRetiredL := List.replicate n false,
    landedL := List.replicate n false, claimedL := List.replicate n false,
    h2dReadyL := List.replicate n false }

inductive Ev where
  | send (e : Send.Ev)
  | d2hReady (l : Nat)
  | h2hDone (l : Nat) (ok : Bool)
  | recv (e : Recv.Ev)
  | h2dBegin (l : Nat)
  | h2dReady (l : Nat)
  | land (l : Nat)
  | reclaim
  | reseatPrefillStaging
  | reseatDecodeStaging
  deriving Repr, DecidableEq

/-- A send event with no memory effect. The two that move data are the
layer-indexed `d2hReady l` / `h2hDone l ok` and are disabled here. `wake` gets
the per-layer guard the counter model cannot state: `SendNextLayer(woken)`
waits on layer `woken`'s own future. -/
def sendStep (s : Pipeline) (e : Send.Ev) : Option Pipeline :=
  match e with
  | .d2hReady => none
  | .h2hDone _ => none
  | .wake _ =>
    if s.d2hReadyL[s.send.woken]? = some true then
      (Send.step s.send e).map fun snd => { s with send := snd }
    else none
  | _ => (Send.step s.send e).map fun snd => { s with send := snd }

/-- The D2H copy of layer `l` finishes: `prefillStaging[l] := prefillHbm[l]`.
Copies are issued in layer order (`send.cc:324`), so layer `l`'s exists iff
`l < d2hIssued`; which finishes first is up to the device. -/
def d2hReady (s : Pipeline) (l : Nat) : Option Pipeline :=
  if l < s.send.d2hIssued ∧ s.d2hReadyL[l]? = some false then
    (Send.step s.send .d2hReady).map fun snd =>
      { s with send := snd,
               prefillStaging := s.prefillStaging.set l (s.prefillHbm.getD l .junk),
               d2hReadyL := s.d2hReadyL.set l true }
  else none

/-- The push callback for layer `l` (`send.cc:428-445`). Pushes are issued in
layer order by the `SendNextLayer` chain, so push `l` exists iff
`l < h2hIssued`; pushes complete in any order. A successful push delivers
`prefillStaging[l]`. -/
def h2hDone (s : Pipeline) (l : Nat) (ok : Bool) : Option Pipeline :=
  if l < s.send.h2hIssued ∧ s.h2hRetiredL[l]? = some false then
    (Send.step s.send (.h2hDone ok)).map fun snd =>
      if ok then
        { s with send := snd, h2hRetiredL := s.h2hRetiredL.set l true,
                 wire := s.wire.set l (s.prefillStaging.getD l .junk) }
      else { s with send := snd, h2hRetiredL := s.h2hRetiredL.set l true }
  else none

/-- A receive event with no memory effect. `h2dBegin` and `h2dReady` are the
layer-indexed events below and are disabled here. -/
def recvStep (s : Pipeline) (e : Recv.Ev) : Option Pipeline :=
  match e with
  | .h2dBegin => none
  | .h2dReady => none
  | _ => (Recv.step s.recv e).map fun rcv => { s with recv := rcv }

/-- `OnLayerReceived(l)` → `ExecuteLayerH2d(l)` up to its first unlock: fires
once per layer (A1), after layer `l` landed (`bt.cc:528-530`). -/
def h2dBegin (s : Pipeline) (l : Nat) : Option Pipeline :=
  if s.landedL[l]? = some true ∧ s.claimedL[l]? = some false then
    (Recv.step s.recv .h2dBegin).map fun rcv =>
      { s with recv := rcv, claimedL := s.claimedL.set l true }
  else none

/-- The H2D copy of layer `l` finishes: `decodeHbm[l] := decodeStaging[l]`. -/
def h2dReady (s : Pipeline) (l : Nat) : Option Pipeline :=
  if s.claimedL[l]? = some true ∧ s.h2dReadyL[l]? = some false then
    (Recv.step s.recv .h2dReady).map fun rcv =>
      { s with recv := rcv,
               decodeHbm := s.decodeHbm.set l (s.decodeStaging.getD l .junk),
               h2dReadyL := s.h2dReadyL.set l true }
  else none

/-- The transport lands layer `l`, inside an accepted push, once something has
been delivered for it. Layers land in any order. -/
def land (s : Pipeline) (l : Nat) : Option Pipeline :=
  if s.recv.pushes ≠ 0 ∧ s.landedL[l]? = some false then
    match s.wire[l]? with
    | some c =>
      if c = .blank then none
      else some { s with decodeStaging := s.decodeStaging.set l c, landedL := s.landedL.set l true }
    | none => none
  else none

/-- The engine frees prefill HBM after the send was reported (as done or as
failed: either way the send has settled, so no copy is reading it). -/
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
  | .d2hReady l => s.d2hReady l
  | .h2hDone l ok => s.h2hDone l ok
  | .recv e => s.recvStep e
  | .h2dBegin l => s.h2dBegin l
  | .h2dReady l => s.h2dReady l
  | .land l => s.land l
  | .reclaim => s.reclaim
  | .reseatPrefillStaging => s.reseatPrefillStaging
  | .reseatDecodeStaging => s.reseatDecodeStaging

/-- An `n`-layer transfer. -/
def sys (n : Nat) : System Pipeline Ev := ⟨init n, step⟩

/-! ## Properties -/

/-- When the engine is told `done_recving`, decode HBM holds the KV cache. -/
def PublicationCorrect (s : Pipeline) : Prop :=
  s.recv.published = some true → s.decodeHbm = good s.numLayers

/-- When the engine frees prefill HBM, no D2H copy is reading it. -/
def PrefillHbmSafe (s : Pipeline) : Prop :=
  s.reclaimed = true → s.send.d2hRetired = s.send.d2hIssued

/-- Released staging has no copy writing it and no push or copy reading it. -/
def StagingSafe (s : Pipeline) : Prop :=
  (s.send.life.hasStaging = false →
    s.send.d2hRetired = s.send.d2hIssued ∧ s.send.h2hRetired = s.send.h2hIssued) ∧
  (s.recv.life.hasStaging = false → s.recv.pushes = 0 ∧ s.recv.retired = s.recv.issued)

def Safe (s : Pipeline) : Prop := PublicationCorrect s ∧ PrefillHbmSafe s ∧ StagingSafe s

/-! ## Facts about `good`, per-layer sets and `countTrue` -/

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

/-- Reading a memory after `.kv k` was written at a valid index `k`. -/
theorem getElem?_set_kv {l : List Cell} {k j : Nat} (hk : k < l.length)
    (hj : j ≠ k → l[j]? = some (.kv j)) : (l.set k (.kv k))[j]? = some (.kv j) := by
  by_cases hjk : j = k
  · subst hjk; exact List.getElem?_set_self hk
  · rw [List.getElem?_set_ne (Ne.symm hjk)]; exact hj hjk

theorem lt_length_of_getElem?_eq {α : Type} {l : List α} {i : Nat} {a : α}
    (h : l[i]? = some a) : i < l.length :=
  (List.getElem?_eq_some_iff.mp h).1

/-- Adding `i` to a set: membership afterwards is `i` or membership before. -/
theorem mem_of_set_true {L : List Bool} {i j : Nat} (h : (L.set i true)[j]? = some true) :
    j = i ∨ L[j]? = some true := by
  by_cases hji : j = i
  · exact Or.inl hji
  · right; rwa [List.getElem?_set_ne (Ne.symm hji)] at h

theorem set_true_self {L : List Bool} {i : Nat} (hi : L[i]? = some false) :
    (L.set i true)[i]? = some true :=
  List.getElem?_set_self (lt_length_of_getElem?_eq hi)

theorem set_true_of_mem {L : List Bool} {i j : Nat} (hi : L[i]? = some false)
    (hj : L[j]? = some true) : (L.set i true)[j]? = some true := by
  by_cases hji : j = i
  · subst hji; rw [hi] at hj; cases hj
  · rw [List.getElem?_set_ne (Ne.symm hji)]; exact hj

theorem countTrue_replicate_false : ∀ n, countTrue (List.replicate n false) = 0
  | 0 => rfl
  | n + 1 => by simp [List.replicate_succ, countTrue, countTrue_replicate_false n]

theorem countTrue_le_length : ∀ l : List Bool, countTrue l ≤ l.length
  | [] => Nat.le_refl _
  | b :: bs => by
    have := countTrue_le_length bs
    simp only [countTrue, List.length_cons]; split <;> omega

theorem countTrue_set_true : ∀ {l : List Bool} {i : Nat}, l[i]? = some false →
    countTrue (l.set i true) = countTrue l + 1
  | [], i, h => by simp at h
  | b :: bs, 0, h => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h
    subst h; simp [countTrue]; omega
  | b :: bs, i + 1, h => by
    simp only [List.getElem?_cons_succ] at h
    simp only [List.set_cons_succ, countTrue, countTrue_set_true h]; omega

/-- A set with as many members as slots is full. -/
theorem all_true_of_countTrue_eq_length : ∀ {l : List Bool}, countTrue l = l.length →
    ∀ i, i < l.length → l[i]? = some true
  | [], _, i, hi => by simp at hi
  | b :: bs, h, i, hi => by
    have hle := countTrue_le_length bs
    simp only [countTrue, List.length_cons] at h
    cases b with
    | false => simp at h; omega
    | true =>
      cases i with
      | zero => simp
      | succ i =>
        simp only [List.getElem?_cons_succ]
        exact all_true_of_countTrue_eq_length (by simp at h; omega) i (by simp at hi; omega)

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
  len_h2dReadyL : s.h2dReadyL.length = s.numLayers
  /-- Prefill HBM holds the data until the engine reclaims it. -/
  phbm_good : s.reclaimed = false → s.prefillHbm = good s.numLayers
  /-- Prefill HBM is reclaimed only once the send has settled. -/
  reclaimed_done : s.reclaimed = true → s.send.life.done = true
  /-- The per-layer record of finished D2H copies agrees with the send's counter. -/
  cnt_d2hReady : countTrue s.d2hReadyL = s.send.d2hReady
  /-- `SendNextLayer(l)`'s callback has run only for layers whose copy finished. -/
  woken_d2hReady : ∀ l : Nat, l < s.send.woken → s.d2hReadyL[l]? = some true
  /-- While the send holds its staging, every finished copy's layer is there. -/
  pstaging_good : s.send.life.done = false →
    ∀ l : Nat, s.d2hReadyL[l]? = some true → s.prefillStaging[l]? = some (.kv l)
  /-- Whatever was delivered for layer `k` is layer `k`. -/
  wire_good : ∀ (k : Nat) (c : Cell), s.wire[k]? = some c → c = .blank ∨ c = .kv k
  /-- A layer enters `ExecuteLayerH2d` only after it landed. -/
  claimed_landed : ∀ l : Nat, s.claimedL[l]? = some true → s.landedL[l]? = some true
  /-- While the receive holds its staging, every landed layer is there. -/
  dstaging_good : s.recv.life.done = false →
    ∀ l : Nat, s.landedL[l]? = some true → s.decodeStaging[l]? = some (.kv l)
  /-- The per-layer record of finished H2D copies agrees with the receive's counter. -/
  cnt_h2dReady : countTrue s.h2dReadyL = s.recv.ready
  /-- Every finished copy put its layer in decode HBM. -/
  dhbm_good : ∀ l : Nat, s.h2dReadyL[l]? = some true → s.decodeHbm[l]? = some (.kv l)

/-- No layer is in an empty set. -/
theorem not_mem_replicate_false {n i : Nat} (h : (List.replicate n false)[i]? = some true) :
    False := by
  simp only [List.getElem?_replicate] at h
  split at h <;> cases h

theorem inv_init (n : Nat) : Inv (init n) := by
  refine ⟨Send.inv_init n, Recv.inv_initLoad n, rfl, rfl, by simp [init], by simp [init],
    by simp [init], by simp [init], by simp [init], fun _ => rfl, by simp [init, Send.init],
    by simp [init, Send.init, countTrue_replicate_false], by simp [init, Send.init],
    fun _ l h => (not_mem_replicate_false h).elim, ?_,
    fun l h => (not_mem_replicate_false h).elim,
    fun _ l h => (not_mem_replicate_false h).elim,
    by simp [init, Recv.initLoad, countTrue_replicate_false],
    fun l h => (not_mem_replicate_false h).elim⟩
  intro k c hk
  simp only [init, List.getElem?_replicate] at hk
  split at hk
  · cases hk; exact Or.inl rfl
  · cases hk

theorem inv_safe {s : Pipeline} (h : Inv s) : Safe s := by
  have hsend := h.send
  have hrecv := h.recv
  have hsS := Send.inv_safe hsend
  have hcnt := hsend.counters
  unfold Send.CountersOrdered at hcnt
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro hp
    apply eq_good h.len_dhbm
    intro k hk
    apply h.dhbm_good
    have hready : s.recv.ready = s.numLayers := by
      have := hrecv.published_ok hp
      have := hrecv.completed_le
      have := hrecv.retired_le
      have := hrecv.ready_le
      have := hrecv.issued_le
      have := h.n_recv
      omega
    apply all_true_of_countTrue_eq_length
    · rw [h.cnt_h2dReady, hready, h.len_h2dReadyL]
    · rw [h.len_h2dReadyL]; exact hk
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

/-- A send event that moves no memory, given that the layers `SendNextLayer`
has consumed afterwards all have their copy finished. `x` lets the same lemma
serve `h2hDone l false`, which records the callback without moving data. -/
theorem Inv.send_frame {s : Pipeline} {snd : Send} {e : Send.Ev} (h : Inv s)
    (hs : Send.step s.send e = some snd) (he : e ≠ .d2hReady)
    (hw : ∀ l < snd.woken, s.d2hReadyL[l]? = some true) (x : List Bool) :
    Inv { s with send := snd, h2hRetiredL := x } := by
  refine ⟨Send.step_inv h.send hs, h.recv, (Send.step_numLayers hs).trans h.n_send, h.n_recv,
    h.len_pstaging, h.len_wire, h.len_dstaging, h.len_dhbm, h.len_h2dReadyL, h.phbm_good,
    fun hr => Send.step_done_mono hs (h.reclaimed_done hr), ?_, hw, ?_, h.wire_good,
    h.claimed_landed, h.dstaging_good, h.cnt_h2dReady, h.dhbm_good⟩
  · show countTrue s.d2hReadyL = snd.d2hReady
    rw [Send.step_d2hReady hs he]; exact h.cnt_d2hReady
  · show snd.life.done = false → ∀ l : Nat, s.d2hReadyL[l]? = some true → s.prefillStaging[l]? = some (.kv l)
    intro hd
    apply h.pstaging_good
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
    unfold Send.CountersOrdered at hcnt
    omega

/-- The D2H copy of layer `l` lands in staging. -/
theorem Inv.send_d2hReady {s : Pipeline} {snd : Send} {l : Nat} (h : Inv s)
    (hl : l < s.send.d2hIssued) (hf : s.d2hReadyL[l]? = some false)
    (hs : Send.step s.send .d2hReady = some snd) :
    Inv { s with send := snd,
                 prefillStaging := s.prefillStaging.set l (s.prefillHbm.getD l .junk),
                 d2hReadyL := s.d2hReadyL.set l true } := by
  obtain ⟨hlt, rfl⟩ := Send.d2hReady_spec hs
  have hcnt := h.send.counters
  unfold Send.CountersOrdered at hcnt
  have hd : s.send.life.done = false := send_not_done_of_outstanding h.send (Or.inl hlt)
  have hnr : s.reclaimed = false := by
    cases hr : s.reclaimed
    · rfl
    · have := h.reclaimed_done hr; rw [hd] at this; cases this
  have hk : l < s.numLayers := by have := h.n_send; omega
  have hsrc : s.prefillHbm.getD l .junk = .kv l := by
    rw [h.phbm_good hnr]; exact good_getD hk
  rw [hsrc]
  refine ⟨Send.step_inv h.send hs, h.recv, (Send.step_numLayers hs).trans h.n_send, h.n_recv,
    ?_, h.len_wire, h.len_dstaging, h.len_dhbm, h.len_h2dReadyL, h.phbm_good,
    fun hr => Send.step_done_mono hs (h.reclaimed_done hr), ?_, ?_, ?_, h.wire_good,
    h.claimed_landed, h.dstaging_good, h.cnt_h2dReady, h.dhbm_good⟩
  · show (s.prefillStaging.set _ _).length = _
    rw [List.length_set]; exact h.len_pstaging
  · show countTrue (s.d2hReadyL.set l true) = s.send.d2hReady + 1
    rw [countTrue_set_true hf, h.cnt_d2hReady]
  · show ∀ j < s.send.woken, (s.d2hReadyL.set l true)[j]? = some true
    intro j hj
    exact set_true_of_mem hf (h.woken_d2hReady j hj)
  · show _ → ∀ j : Nat, (s.d2hReadyL.set l true)[j]? = some true →
      (s.prefillStaging.set l (.kv l))[j]? = some (.kv j)
    intro _ j hj
    apply getElem?_set_kv (by rw [h.len_pstaging]; exact hk)
    intro hjl
    exact h.pstaging_good hd j ((mem_of_set_true hj).resolve_left hjl)

/-- A successful push of layer `l` delivers it. -/
theorem Inv.send_h2hDone {s : Pipeline} {snd : Send} {l : Nat} (h : Inv s)
    (hl : l < s.send.h2hIssued) (hf : s.h2hRetiredL[l]? = some false)
    (hs : Send.step s.send (.h2hDone true) = some snd)
    (hw : ∀ l' < snd.woken, s.d2hReadyL[l']? = some true) :
    Inv { s with send := snd, h2hRetiredL := s.h2hRetiredL.set l true,
                 wire := s.wire.set l (s.prefillStaging.getD l .junk) } := by
  have hlt := Send.h2hDone_guard hs
  have hcnt := h.send.counters
  unfold Send.CountersOrdered at hcnt
  have hd : s.send.life.done = false := send_not_done_of_outstanding h.send (Or.inr hlt)
  have hk : l < s.numLayers := by have := h.n_send; omega
  have hdl : s.d2hReadyL[l]? = some true := h.woken_d2hReady l (by omega)
  have hsrc : s.prefillStaging.getD l .junk = .kv l := by
    rw [List.getD_eq_getElem?_getD, h.pstaging_good hd l hdl]; rfl
  rw [hsrc]
  have h' := h.send_frame hs nofun hw (s.h2hRetiredL.set l true)
  refine ⟨h'.send, h'.recv, h'.n_send, h'.n_recv, h'.len_pstaging, ?_, h'.len_dstaging,
    h'.len_dhbm, h'.len_h2dReadyL, h'.phbm_good, h'.reclaimed_done, h'.cnt_d2hReady,
    h'.woken_d2hReady, h'.pstaging_good, ?_, h'.claimed_landed, h'.dstaging_good, h'.cnt_h2dReady,
    h'.dhbm_good⟩
  · show (s.wire.set _ _).length = _
    rw [List.length_set]; exact h.len_wire
  · show ∀ j (c : Cell), (s.wire.set l _)[j]? = some c → c = .blank ∨ c = .kv j
    intro j c hj
    by_cases hjl : j = l
    · subst hjl
      rw [List.getElem?_set_self (by rw [h.len_wire]; exact hk)] at hj
      cases hj; exact Or.inr rfl
    · rw [List.getElem?_set_ne (Ne.symm hjl)] at hj
      exact h.wire_good j c hj

/-- A receive event that moves no memory. `x` lets the same lemma serve
`h2dBegin l`, which only records the claim. -/
theorem Inv.recv_frame {s : Pipeline} {rcv : Recv} {e : Recv.Ev} (h : Inv s)
    (hs : Recv.step s.recv e = some rcv) (he : e ≠ .h2dReady) (x : List Bool)
    (hx : ∀ l : Nat, x[l]? = some true → s.landedL[l]? = some true) :
    Inv { s with recv := rcv, claimedL := x } := by
  refine ⟨h.send, Recv.step_inv h.recv hs, h.n_send, (Recv.step_numLayers hs).trans h.n_recv,
    h.len_pstaging, h.len_wire, h.len_dstaging, h.len_dhbm, h.len_h2dReadyL, h.phbm_good,
    h.reclaimed_done, h.cnt_d2hReady, h.woken_d2hReady, h.pstaging_good, h.wire_good, hx, ?_, ?_,
    h.dhbm_good⟩
  · show rcv.life.done = false → ∀ l : Nat, s.landedL[l]? = some true → s.decodeStaging[l]? = some (.kv l)
    intro hd
    apply h.dstaging_good
    cases hd0 : s.recv.life.done
    · rfl
    · rw [Recv.step_done_mono hs hd0] at hd; cases hd
  · show countTrue s.h2dReadyL = rcv.ready
    rw [Recv.step_ready hs he]; exact h.cnt_h2dReady

/-- The H2D copy of layer `l` lands in decode HBM. -/
theorem Inv.recv_h2dReady {s : Pipeline} {rcv : Recv} {l : Nat} (h : Inv s)
    (hc : s.claimedL[l]? = some true) (hf : s.h2dReadyL[l]? = some false)
    (hs : Recv.step s.recv .h2dReady = some rcv) :
    Inv { s with recv := rcv,
                 decodeHbm := s.decodeHbm.set l (s.decodeStaging.getD l .junk),
                 h2dReadyL := s.h2dReadyL.set l true } := by
  obtain ⟨hlt, rfl⟩ := Recv.h2dReady_spec hs
  have hr := h.recv
  have hd : s.recv.life.done = false := by
    cases hd : s.recv.life.done
    · rfl
    · have := (Recv.inv_safe hr).2.1 hd
      have := hr.retired_le
      omega
  have hk : l < s.numLayers := by
    have := lt_length_of_getElem?_eq hf; rw [h.len_h2dReadyL] at this; exact this
  have hsrc : s.decodeStaging.getD l .junk = .kv l := by
    rw [List.getD_eq_getElem?_getD, h.dstaging_good hd l (h.claimed_landed l hc)]
    rfl
  rw [hsrc]
  refine ⟨h.send, Recv.step_inv hr hs, h.n_send, (Recv.step_numLayers hs).trans h.n_recv,
    h.len_pstaging, h.len_wire, h.len_dstaging, ?_, ?_, h.phbm_good, h.reclaimed_done,
    h.cnt_d2hReady, h.woken_d2hReady, h.pstaging_good, h.wire_good, h.claimed_landed,
    h.dstaging_good, ?_, ?_⟩
  · show (s.decodeHbm.set _ _).length = _
    rw [List.length_set]; exact h.len_dhbm
  · show (s.h2dReadyL.set _ _).length = _
    rw [List.length_set]; exact h.len_h2dReadyL
  · show countTrue (s.h2dReadyL.set l true) = s.recv.ready + 1
    rw [countTrue_set_true hf, h.cnt_h2dReady]
  · show ∀ j : Nat, (s.h2dReadyL.set l true)[j]? = some true → (s.decodeHbm.set l (.kv l))[j]? = some (.kv j)
    intro j hj
    apply getElem?_set_kv (by rw [h.len_dhbm]; exact hk)
    intro hjl
    exact h.dhbm_good j ((mem_of_set_true hj).resolve_left hjl)

/-- Layers `SendNextLayer` has consumed after a `wake`: the ones before, plus
the one the guard checked. -/
theorem woken_after_wake {s : Pipeline} {snd : Send} {ok : Bool} (h : Inv s)
    (hs : Send.step s.send (.wake ok) = some snd)
    (hg : s.d2hReadyL[s.send.woken]? = some true) :
    ∀ l < snd.woken, s.d2hReadyL[l]? = some true := by
  rw [Send.wake_woken hs]
  intro l hl
  rcases Nat.lt_succ_iff_lt_or_eq.mp hl with hl | rfl
  · exact h.woken_d2hReady l hl
  · exact hg

/-- Layers `SendNextLayer` has consumed after any other send event: unchanged. -/
theorem woken_after_other {s : Pipeline} {snd : Send} {e : Send.Ev} (h : Inv s)
    (hs : Send.step s.send e = some snd) (he : ∀ ok, e ≠ .wake ok) :
    ∀ l < snd.woken, s.d2hReadyL[l]? = some true := by
  rw [Send.step_woken hs he]; exact h.woken_d2hReady

theorem step_inv {s s' : Pipeline} {e : Ev} (h : Inv s) (hs : step s e = some s') : Inv s' := by
  cases e with
  | send e =>
    cases e
    case d2hReady => simp only [step, sendStep] at hs; cases hs
    case h2hDone ok => simp only [step, sendStep] at hs; cases hs
    case wake ok =>
      simp only [step, sendStep] at hs
      split at hs
      · rename_i hg
        simp only [Option.map_eq_some_iff] at hs
        obtain ⟨snd, hsnd, rfl⟩ := hs
        exact h.send_frame hsnd nofun (woken_after_wake h hsnd hg) _
      · cases hs
    all_goals
      (try (rename_i ok; cases ok))
      all_goals
        simp only [step, sendStep, Option.map_eq_some_iff] at hs
        obtain ⟨snd, hsnd, rfl⟩ := hs
        exact h.send_frame hsnd nofun (woken_after_other h hsnd nofun) _
  | d2hReady l =>
    simp only [step, d2hReady] at hs
    split at hs
    · rename_i hg
      obtain ⟨hl, hf⟩ := hg
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨snd, hsnd, rfl⟩ := hs
      exact h.send_d2hReady hl hf hsnd
    · cases hs
  | h2hDone l ok =>
    simp only [step, h2hDone] at hs
    split at hs
    · rename_i hg
      obtain ⟨hl, hf⟩ := hg
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨snd, hsnd, rfl⟩ := hs
      have hw := woken_after_other h hsnd nofun
      cases ok
      · exact h.send_frame hsnd nofun hw _
      · exact h.send_h2hDone hl hf hsnd hw
    · cases hs
  | recv e =>
    cases e
    case h2dBegin => simp only [step, recvStep] at hs; cases hs
    case h2dReady => simp only [step, recvStep] at hs; cases hs
    all_goals
      (try (rename_i ok; cases ok))
      all_goals
        simp only [step, recvStep, Option.map_eq_some_iff] at hs
        obtain ⟨rcv, hrcv, rfl⟩ := hs
        exact h.recv_frame hrcv nofun _ h.claimed_landed
  | h2dBegin l =>
    simp only [step, h2dBegin] at hs
    split at hs
    · rename_i hg
      obtain ⟨hld, hf⟩ := hg
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨rcv, hrcv, rfl⟩ := hs
      apply h.recv_frame hrcv nofun
      intro j hj
      rcases mem_of_set_true hj with rfl | hj
      · exact hld
      · exact h.claimed_landed j hj
    · cases hs
  | h2dReady l =>
    simp only [step, h2dReady] at hs
    split at hs
    · rename_i hg
      obtain ⟨hc, hf⟩ := hg
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨rcv, hrcv, rfl⟩ := hs
      exact h.recv_h2dReady hc hf hrcv
    · cases hs
  | land l =>
    simp only [step, land] at hs
    split at hs
    · rename_i hg
      obtain ⟨-, hf⟩ := hg
      split at hs
      · rename_i c hc
        split at hs
        · cases hs
        rename_i hcb
        cases hs
        have hkv : c = .kv l := (h.wire_good _ _ hc).resolve_left hcb
        have hlen : l < s.numLayers := by
          have := lt_length_of_getElem?_eq hc
          rw [h.len_wire] at this; exact this
        subst hkv
        refine ⟨h.send, h.recv, h.n_send, h.n_recv, h.len_pstaging, h.len_wire, ?_, h.len_dhbm,
          h.len_h2dReadyL, h.phbm_good, h.reclaimed_done, h.cnt_d2hReady, h.woken_d2hReady,
          h.pstaging_good, h.wire_good, ?_, ?_, h.cnt_h2dReady, h.dhbm_good⟩
        · show (s.decodeStaging.set _ _).length = _
          rw [List.length_set]; exact h.len_dstaging
        · show ∀ j : Nat, s.claimedL[j]? = some true → (s.landedL.set l true)[j]? = some true
          intro j hj
          exact set_true_of_mem hf (h.claimed_landed j hj)
        · show _ → ∀ j : Nat, (s.landedL.set l true)[j]? = some true →
            (s.decodeStaging.set l (.kv l))[j]? = some (.kv j)
          intro hd j hj
          apply getElem?_set_kv (by rw [h.len_dstaging]; exact hlen)
          intro hjl
          exact h.dstaging_good hd j ((mem_of_set_true hj).resolve_left hjl)
      · cases hs
    · cases hs
  | reclaim =>
    simp only [step, reclaim] at hs
    split at hs
    · rename_i hg
      obtain ⟨hp, -⟩ := hg
      cases hs
      obtain ⟨b, hb⟩ := Option.ne_none_iff_exists'.mp hp
      refine ⟨h.send, h.recv, h.n_send, h.n_recv, h.len_pstaging, h.len_wire, h.len_dstaging,
        h.len_dhbm, h.len_h2dReadyL, ?_, ?_, h.cnt_d2hReady, h.woken_d2hReady, h.pstaging_good,
        h.wire_good, h.claimed_landed, h.dstaging_good, h.cnt_h2dReady, h.dhbm_good⟩
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
        h.len_dhbm, h.len_h2dReadyL, h.phbm_good, h.reclaimed_done, h.cnt_d2hReady, h.woken_d2hReady,
        ?_, h.wire_good, h.claimed_landed, h.dstaging_good, h.cnt_h2dReady, h.dhbm_good⟩
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
        h.len_dhbm, h.len_h2dReadyL, h.phbm_good, h.reclaimed_done, h.cnt_d2hReady, h.woken_d2hReady,
        h.pstaging_good, h.wire_good, h.claimed_landed, ?_, h.cnt_h2dReady, h.dhbm_good⟩
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

/-- Unfold `step` for a known event and split every branch, leaving `hs` as
`some … = some s'`, as the `Option.map` form, or closed. -/
macro "pipe_cases" hs:ident : tactic =>
  `(tactic| (simp only [step, sendStep, recvStep, d2hReady, h2hDone, h2dBegin, h2dReady, land,
      reclaim, reseatPrefillStaging, reseatDecodeStaging] at $hs:ident <;>
      (repeat' split at $hs:ident) <;>
      (try simp only [Option.map_eq_some_iff] at $hs:ident)))

theorem step_numLayers {s s' : Pipeline} {e : Ev} (hs : step s e = some s') :
    s'.numLayers = s.numLayers := by
  cases e <;> (try (rename_i e; cases e)) <;> (try (rename_i ok; cases ok)) <;> pipe_cases hs <;>
  first
    | (obtain ⟨_, _, rfl⟩ := hs; rfl)
    | (cases hs <;> rfl)
    | cases hs

theorem step_published_mono {s s' : Pipeline} {e : Ev} {b : Bool} (hs : step s e = some s')
    (hp : s.recv.published = some b) : s'.recv.published = some b := by
  cases e <;> (try (rename_i e; cases e)) <;> (try (rename_i ok; cases ok)) <;> pipe_cases hs <;>
  first
    | (obtain ⟨_, hr, rfl⟩ := hs; first | exact hp | exact Recv.step_published_mono hr hp)
    | (cases hs <;> exact hp)
    | cases hs

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
admits — in particular layers completing out of order at every stage; bounded
searches on the one-layer instance; and mutants that show the memory model is
sensitive to the guards the proof rests on, including the per-layer ones. -/

/-- A one-layer producer, start to `done_sending`. -/
def producer : List Ev :=
  [.send .start, .send .d2hBegin, .send (.d2hIssue true), .d2hReady 0, .send .d2hEnd,
   .send (.wake true), .send .h2hIssue, .send .sendNext, .h2hDone 0 true, .send .publish]

/-- A one-layer consumer, pull handshake to `done_recving`. -/
def consumer : List Ev :=
  [.recv (.pullReply true), .recv .pushBegin, .land 0, .recv .pushEnd, .h2dBegin 0,
   .recv (.h2dIssue true), .recv .netAccount, .h2dReady 0, .recv (.h2dDone true),
   .recv .publish]

/-- Producer then consumer: both sides published as done, the data in decode
HBM. -/
theorem trace_normal :
    ((sys 1).run (producer ++ consumer)).map
      (fun s => (s.send.published, s.recv.published, s.decodeHbm)) =
    some (some true, some true, [.kv 0]) := by
  decide

/-- A two-layer producer whose D2H copies finish in reverse order and whose
pushes complete in reverse order. The push *chain* is still 0 then 1
(`SendNextLayer`), and `wake` for layer 0 waits for layer 0's copy. -/
def producer2 : List Ev :=
  [.send .start, .send .d2hBegin, .send (.d2hIssue true), .send .d2hBegin, .send (.d2hIssue true),
   .d2hReady 1, .d2hReady 0, .send .d2hEnd, .send .d2hEnd,
   .send (.wake true), .send .h2hIssue, .send .sendNext,
   .send (.wake true), .send .h2hIssue, .send .sendNext,
   .h2hDone 1 true, .h2hDone 0 true, .send .publish]

/-- A two-layer consumer that lands layer 1 first, dispatches its H2D first,
and whose H2D copies finish in the order 1, 0. -/
def consumer2 : List Ev :=
  [.recv (.pullReply true),
   .recv .pushBegin, .land 1, .recv .pushEnd, .h2dBegin 1, .recv (.h2dIssue true), .recv .netAccount,
   .recv .pushBegin, .land 0, .recv .pushEnd, .h2dBegin 0, .recv (.h2dIssue true), .recv .netAccount,
   .h2dReady 1, .h2dReady 0, .recv (.h2dDone true), .recv (.h2dDone true), .recv .publish]

/-- Layers complete out of order at every stage; publication still finds the
right data in the right slots. This is the proposal's out-of-order question
answered inside the model. -/
theorem trace_layers_out_of_order :
    ((sys 2).run (producer2 ++ consumer2)).map
      (fun s => (s.send.published, s.recv.published, s.decodeHbm)) =
    some (some true, some true, [.kv 0, .kv 1]) := by
  decide

/-- The push chain is ordered: `SendNextLayer(0)` cannot proceed on layer 1's
copy, however early it finished. -/
theorem trace_wake_needs_own_layer :
    (sys 2).run
      [.send .start, .send .d2hBegin, .send (.d2hIssue true), .send .d2hBegin,
       .send (.d2hIssue true), .d2hReady 1, .send (.wake true)] = none ∧
    ((sys 2).run
      [.send .start, .send .d2hBegin, .send (.d2hIssue true), .send .d2hBegin,
       .send (.d2hIssue true), .d2hReady 1, .d2hReady 0, .send (.wake true)]).isSome = true := by
  decide

/-- The producer is long gone — published, prefill HBM reclaimed, staging reused —
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
      .land 0] = none := by
  decide

/-- The layer must land before the device is asked to copy it. -/
theorem trace_no_dispatch_before_land :
    (sys 1).run [.recv (.pullReply true), .h2dBegin 0] = none := by
  decide

/-- Every event, for an `n`-layer instance. The four session events that the
pipeline replaces with layer-indexed ones are left out (they are disabled). -/
def events (n : Nat) : List Ev :=
  (Send.events.filter fun e => e != .d2hReady && e != .h2hDone true && e != .h2hDone false).map .send ++
    (Recv.events.filter fun e => e != .h2dBegin && e != .h2dReady).map .recv ++
    (List.range n).flatMap (fun l =>
      [.d2hReady l, .h2hDone l true, .h2hDone l false, .h2dBegin l, .h2dReady l, .land l]) ++
    [.reclaim, .reseatPrefillStaging, .reseatDecodeStaging]

/-- Executable negation of `Safe`. -/
def violates (s : Pipeline) : Bool :=
  (s.recv.published == some true && s.decodeHbm != good s.numLayers) ||
  (s.reclaimed && s.send.d2hRetired != s.send.d2hIssued) ||
  (!s.send.life.hasStaging &&
    (s.send.d2hRetired != s.send.d2hIssued || s.send.h2hRetired != s.send.h2hIssued)) ||
  (!s.recv.life.hasStaging && (s.recv.pushes != 0 || s.recv.retired != s.recv.issued))

#guard ModelCheck.check (sys 1) (events 1) violates 10 = .outOfFuel

/-- Publication needs more events than the search above reaches, so search
again from the state the producer leaves behind: every consumer interleaving
with reclaim, staging reuse, cancellation and so on is within reach. -/
def afterProducer : Pipeline := ((sys 1).run producer).getD (init 1)

-- Fuel 10 is the least that reaches publication from here (nine consumer
-- events). This is the slowest guard in the project (~7 s); do not lower it.
#guard ModelCheck.check ⟨afterProducer, step⟩ (events 1) violates 10 = .outOfFuel

/-- Two layers, from the out-of-order producer: explores the initial consumer
landing and dispatch steps (`fuel = 5`, traces of up to 4 events) alongside
reclaim and staging reuse; deeper consumer interleavings are covered from
`afterDispatch2` below. -/
def afterProducer2 : Pipeline := ((sys 2).run producer2).getD (init 2)

#guard ModelCheck.check ⟨afterProducer2, step⟩ (events 2) violates 5 = .outOfFuel

/-- Two layers, from the state where layer 1 landed and was dispatched before
layer 0: every order of the two H2D completions, the two callbacks,
publication, cancellation and staging reuse from there. -/
def afterDispatch2 : Pipeline := ((sys 2).run (producer2 ++ consumer2.take 13)).getD (init 2)

#guard ModelCheck.check ⟨afterDispatch2, step⟩ (events 2) violates 7 = .outOfFuel

/-- Mutant: `ExecuteLayerH2d` entered before the layer has landed. The copy
moves whatever the staging buffer held, and the receive is published as done
with junk in HBM. -/
def dispatchEarly (s : Pipeline) (l : Nat) : Option Pipeline :=
  if s.claimedL[l]? = some false then
    (Recv.step s.recv .h2dBegin).map fun rcv =>
      { s with recv := rcv, claimedL := s.claimedL.set l true }
  else none

def sysDispatchEarly : System Pipeline Ev :=
  ⟨init 1, fun s e => match e with
    | .h2dBegin l => s.dispatchEarly l
    | e => step s e⟩

theorem trace_dispatch_early :
    (sysDispatchEarly.run
      [.recv (.pullReply true), .h2dBegin 0, .recv (.h2dIssue true), .h2dReady 0,
       .recv (.h2dDone true), .recv .publish]).map
      (fun s => (s.recv.published, s.decodeHbm)) = some (some true, [.junk]) := by
  decide

#guard (match ModelCheck.check sysDispatchEarly (events 1) violates 8 with
        | .counterexample _ => true
        | _ => false)

/-- Mutant: the H2D copy for layer `l` reads whichever staging slot the
*counter* points at (`decodeStaging[ready]`) instead of its own. With layers
in order this is invisible; with layer 1 landing first it copies layer 0's
still-junk slot into layer 1's HBM, and the receive is published as done.
This is the guard the per-layer events exist to state. -/
def h2dReadyByRank (s : Pipeline) (l : Nat) : Option Pipeline :=
  if s.claimedL[l]? = some true ∧ s.h2dReadyL[l]? = some false then
    (Recv.step s.recv .h2dReady).map fun rcv =>
      { s with recv := rcv,
               decodeHbm := s.decodeHbm.set l (s.decodeStaging.getD s.recv.ready .junk),
               h2dReadyL := s.h2dReadyL.set l true }
  else none

def sysH2dReadyByRank : System Pipeline Ev :=
  ⟨init 2, fun s e => match e with
    | .h2dReady l => s.h2dReadyByRank l
    | e => step s e⟩

theorem trace_h2d_by_rank :
    (sysH2dReadyByRank.run
      (producer2 ++
       [.recv (.pullReply true),
        .recv .pushBegin, .land 1, .recv .pushEnd, .h2dBegin 1, .recv (.h2dIssue true),
        .recv .netAccount, .h2dReady 1,
        .recv .pushBegin, .land 0, .recv .pushEnd, .h2dBegin 0, .recv (.h2dIssue true),
        .recv .netAccount, .h2dReady 0,
        .recv (.h2dDone true), .recv (.h2dDone true), .recv .publish])).map
      (fun s => (s.recv.published, s.decodeHbm)) = some (some true, [.kv 1, .junk]) := by
  decide

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
      [.send .start, .send .d2hBegin, .send (.d2hIssue true), .d2hReady 0, .send .d2hEnd,
       .send (.wake true), .send .h2hIssue, .send .cancel, .reseatPrefillStaging,
       .h2hDone 0 true,
       .recv (.pullReply true), .recv .pushBegin, .land 0, .recv .pushEnd, .h2dBegin 0,
       .recv (.h2dIssue true), .h2dReady 0, .recv (.h2dDone true), .recv .publish]).map
      (fun s => (s.send.life.done, s.recv.published, s.decodeHbm)) =
    some (false, some true, [.junk]) := by
  decide

end Pipeline

end TpuSyncVerify.Transfer.PrefillDecode
