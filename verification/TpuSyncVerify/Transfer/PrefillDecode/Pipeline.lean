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
| `claimedL`    | `OnLayerReceived` has entered `ExecuteLayerH2d` for | — |
| `h2dPendingL` | are between the first and second lock of `ExecuteLayerH2d` | — |
| `h2dIssuedL`  | `ExecuteLayerH2d` has dispatched to the device | — |
| `h2dReadyL`   | have finished their H2D copy (`decodeHbm[l]` written) | `recv.ready` (`cnt_h2dReady`) |

`reclaimed` records that the engine has freed prefill HBM.

## Events

| Event                   | What it is |
|-------------------------|-----------|
| `send e`                | the send session's event `e`, no memory effect. `d2hReady` and `h2hDone` are disabled here (they are the layer-indexed events below). `wake` additionally needs layer `woken`'s copy to have finished: `SendNextLayer(l)` waits on layer `l`'s future (`send.cc:380-384`), not on any future |
| `d2hReady l`            | the D2H copy of layer `l` finishes: `prefillStaging[l] := prefillHbm[l]`. Issued iff `l < d2hIssued` (copies are issued in order) |
| `h2hDone l ok`          | the push callback for layer `l` (`send.cc:428-445`). Push `l` exists iff `l < h2hIssued` (pushes are issued in order). On success `wire[l] := prefillStaging[l]` |
| `recv e`                | the receive session's event `e`, no memory effect. `h2dBegin`, `h2dIssue` and `h2dReady` are disabled here |
| `h2dBegin l`            | `OnLayerReceived(l)` → `ExecuteLayerH2d(l)` up to its first unlock: once per layer (A1), only after layer `l` landed (`bt.cc:528-530`) |
| `h2dIssue l ok`         | `ExecuteLayerH2d(l)` from the re-check on (`recv.cc:601-632`): dispatches layer `l`'s H2D copy unless draining or failed |
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
* **Decode HBM safety** (`DecodeHbmSafe`, `attention_safe`). Once the engine is
  told `done_recving` or `failed_recving` (`recv.published ≠ none`), no H2D copy
  is dispatching or writing to decode HBM (`pending = 0 ∧ retired = issued`);
  moreover, once `done_recving` is reported, `decodeHbm = good n` holds in every
  state reachable afterwards (`attention_safe`).
* **Prefill HBM safety.** `reclaimed → d2hPending = false ∧ d2hRetired = d2hIssued`:
  when the engine frees prefill HBM no D2H copy is dispatching or reading it,
  and (since the send has settled) none will be issued. `proposal.md` §2
  *Source buffer safety*.
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
  /-- ghost: layers `OnLayerReceived` has entered `ExecuteLayerH2d` for -/
  claimedL : List Bool
  /-- ghost: layers between the first and second lock of `ExecuteLayerH2d` -/
  h2dPendingL : List Bool
  /-- ghost: layers `ExecuteLayerH2d` has dispatched to the device -/
  h2dIssuedL : List Bool
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
    h2dPendingL := List.replicate n false, h2dIssuedL := List.replicate n false,
    h2dReadyL := List.replicate n false }

inductive Ev where
  | send (e : Send.Ev)
  | d2hReady (l : Nat)
  | h2hDone (l : Nat) (ok : Bool)
  | recv (e : Recv.Ev)
  | h2dBegin (l : Nat)
  | h2dIssue (l : Nat) (ok : Bool)
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

/-- A receive event with no memory effect. `h2dBegin`, `h2dIssue` and `h2dReady`
are the layer-indexed events below and are disabled here. -/
def recvStep (s : Pipeline) (e : Recv.Ev) : Option Pipeline :=
  match e with
  | .h2dBegin => none
  | .h2dIssue _ => none
  | .h2dReady => none
  | _ => (Recv.step s.recv e).map fun rcv => { s with recv := rcv }

/-- `OnLayerReceived(l)` → `ExecuteLayerH2d(l)` up to its first unlock: fires
once per layer (A1), after layer `l` landed (`bt.cc:528-530`). -/
def h2dBegin (s : Pipeline) (l : Nat) : Option Pipeline :=
  if s.landedL[l]? = some true ∧ s.claimedL[l]? = some false then
    (Recv.step s.recv .h2dBegin).map fun rcv =>
      { s with recv := rcv,
               claimedL := s.claimedL.set l true,
               h2dPendingL := s.h2dPendingL.set l true }
  else none

/-- `ExecuteLayerH2d(l)` from the re-check on (`recv.cc:601-632`): consumes
layer `l`'s pending claim from `h2dBegin l` and, if the session is still active
and dispatch succeeds (`ok = true`), marks layer `l`'s copy as issued. -/
def h2dIssue (s : Pipeline) (l : Nat) (ok : Bool) : Option Pipeline :=
  if s.h2dPendingL[l]? = some true then
    (Recv.step s.recv (.h2dIssue ok)).map fun rcv =>
      { s with recv := rcv,
               h2dPendingL := s.h2dPendingL.set l false,
               h2dIssuedL :=
                 if s.recv.life.done || s.recv.life.draining || !ok then s.h2dIssuedL
                 else s.h2dIssuedL.set l true }
  else none

/-- The H2D copy of layer `l` finishes: `decodeHbm[l] := decodeStaging[l]`. -/
def h2dReady (s : Pipeline) (l : Nat) : Option Pipeline :=
  if s.h2dIssuedL[l]? = some true ∧ s.h2dReadyL[l]? = some false then
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
  | .h2dIssue l ok => s.h2dIssue l ok
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

/-- Once the engine is told `done_recving` or `failed_recving`, no H2D copy is
still dispatching or writing to decode HBM. -/
def DecodeHbmSafe (s : Pipeline) : Prop :=
  s.recv.published ≠ none → s.recv.pending = 0 ∧ s.recv.retired = s.recv.issued

/-- When the engine frees prefill HBM, no D2H copy is reading it. -/
def PrefillHbmSafe (s : Pipeline) : Prop :=
  s.reclaimed = true → s.send.d2hPending = false ∧ s.send.d2hRetired = s.send.d2hIssued

/-- Released staging has no copy writing it and no push or copy reading it. -/
def StagingSafe (s : Pipeline) : Prop :=
  (s.send.life.hasStaging = false →
    s.send.d2hPending = false ∧ s.send.d2hRetired = s.send.d2hIssued ∧
    s.send.h2hRetired = s.send.h2hIssued) ∧
  (s.recv.life.hasStaging = false →
    s.recv.pushes = 0 ∧ s.recv.pending = 0 ∧ s.recv.retired = s.recv.issued)

/-- Events that advance or retire an in-flight operation on either side. -/
def drainEvents (n : Nat) : List Ev :=
  [.send (.d2hIssue true), .send .d2hEnd, .send (.wake true),
   .send .h2hIssue, .send .sendNext,
   .recv .pushEnd, .recv (.pullReply true), .recv (.h2dDone true)] ++
  (List.range n).flatMap fun l =>
    [.d2hReady l, .h2hDone l true, .h2dIssue l true, .h2dReady l]

/-- Every unit of `in_flight_` on either side has an owner that can advance or
retire it in the layer-indexed pipeline. -/
def NoOpLeak (s : Pipeline) : Prop :=
  (0 < s.send.life.inFlight ∨ 0 < s.recv.life.inFlight) →
    ∃ e ∈ drainEvents s.numLayers, (step s e).isSome = true

def Safe (s : Pipeline) : Prop :=
  PublicationCorrect s ∧ DecodeHbmSafe s ∧ PrefillHbmSafe s ∧ StagingSafe s ∧ NoOpLeak s

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

/-- Removing `i` from a set: membership afterwards implies membership before. -/
theorem mem_of_set_false {L : List Bool} {i j : Nat} (h : (L.set i false)[j]? = some true) :
    L[j]? = some true := by
  by_cases hji : j = i
  · subst hji
    by_cases hi : j < L.length
    · rw [List.getElem?_set_self hi] at h; cases h
    · rw [List.getElem?_eq_none (by rw [List.length_set]; omega)] at h; cases h
  · rwa [List.getElem?_set_ne (Ne.symm hji)] at h

theorem mem_of_set_false_ne {L : List Bool} {i j : Nat} (h : (L.set i false)[j]? = some true) :
    j ≠ i := by
  intro rfl
  by_cases hi : j < L.length
  · rw [List.getElem?_set_self hi] at h; cases h
  · rw [List.getElem?_eq_none (by rw [List.length_set]; omega)] at h; cases h

theorem set_true_self {L : List Bool} {i : Nat} (hi : L[i]? = some false) :
    (L.set i true)[i]? = some true :=
  List.getElem?_set_self (lt_length_of_getElem?_eq hi)

theorem set_true_of_mem {L : List Bool} {i j : Nat} (hi : L[i]? = some false)
    (hj : L[j]? = some true) : (L.set i true)[j]? = some true := by
  by_cases hji : j = i
  · subst hji; rw [hi] at hj; cases hj
  · rw [List.getElem?_set_ne (Ne.symm hji)]; exact hj

theorem false_of_not_true {l₁ l₂ : List Bool} {i : Nat} (hlen : l₁.length = l₂.length)
    (hi : l₁[i]? = some false) (himp : l₂[i]? = some true → False) : l₂[i]? = some false := by
  have hlt : i < l₂.length := by have := lt_length_of_getElem?_eq hi; omega
  have heq := List.getElem?_eq_getElem hlt
  cases hb : l₂[i]
  · rw [heq, hb]
  · rw [hb] at heq; exact (himp heq).elim

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

theorem countTrue_set_false : ∀ {l : List Bool} {i : Nat}, l[i]? = some true →
    countTrue (l.set i false) + 1 = countTrue l
  | [], i, h => by simp at h
  | b :: bs, 0, h => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h
    subst h; simp [countTrue]; omega
  | b :: bs, i + 1, h => by
    simp only [List.getElem?_cons_succ] at h
    have ih := countTrue_set_false h
    simp only [List.set_cons_succ, countTrue]; omega

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

theorem exists_true_of_countTrue_pos : ∀ {l : List Bool}, 0 < countTrue l →
    ∃ i < l.length, l[i]? = some true
  | [], h => by simp [countTrue] at h
  | true :: bs, _ => ⟨0, by simp, rfl⟩
  | false :: bs, h => by
    simp [countTrue] at h
    obtain ⟨i, hi, hget⟩ := exists_true_of_countTrue_pos h
    exact ⟨i + 1, by simp; omega, hget⟩

theorem exists_false_lt : ∀ {l : List Bool} {k : Nat},
    k ≤ l.length → countTrue l < k → ∃ i < k, l[i]? = some false
  | _, 0, _, hcnt => by omega
  | [], k + 1, hk, _ => by simp at hk
  | false :: bs, k + 1, _, _ => ⟨0, by omega, rfl⟩
  | true :: bs, k + 1, hk, hcnt => by
    simp [countTrue] at hk hcnt
    obtain ⟨i, hi, hget⟩ := @exists_false_lt bs k (by omega) (by omega)
    exact ⟨i + 1, by omega, hget⟩

theorem exists_diff_of_countTrue_lt : ∀ {l₁ l₂ : List Bool},
    l₁.length = l₂.length → countTrue l₁ < countTrue l₂ →
    ∃ i < l₁.length, l₁[i]? = some false ∧ l₂[i]? = some true
  | [], [], _, hcnt => by simp [countTrue] at hcnt
  | [], _ :: _, hlen, _ => by simp at hlen
  | _ :: _, [], hlen, _ => by simp at hlen
  | b₁ :: bs₁, b₂ :: bs₂, hlen, hcnt => by
    by_cases hb : b₁ = false ∧ b₂ = true
    · obtain ⟨rfl, rfl⟩ := hb; exact ⟨0, by simp, rfl, rfl⟩
    · simp only [List.length_cons, countTrue] at hlen hcnt
      have hlt : countTrue bs₁ < countTrue bs₂ := by
        cases b₁ <;> cases b₂ <;> simp_all <;> omega
      obtain ⟨i, hi, h₁, h₂⟩ := exists_diff_of_countTrue_lt (by omega) hlt
      exact ⟨i + 1, by simp; omega, h₁, h₂⟩

theorem countTrue_le_of_bound : ∀ {l : List Bool} {k : Nat},
    (∀ i, l[i]? = some true → i < k) → countTrue l ≤ k
  | [], _, _ => by simp [countTrue]
  | false :: bs, k, hb => by
    have hb' : ∀ i, bs[i]? = some true → i < k := fun i hi =>
      Nat.lt_of_succ_lt (hb (i + 1) hi)
    simpa [countTrue] using countTrue_le_of_bound hb'
  | true :: bs, 0, hb => by have := hb 0 rfl; omega
  | true :: bs, k + 1, hb => by
    have hb' : ∀ i, bs[i]? = some true → i < k := fun i hi =>
      Nat.lt_of_succ_lt_succ (hb (i + 1) hi)
    have := countTrue_le_of_bound hb'
    simp only [countTrue, ↓reduceIte]; omega

theorem all_true_lt_of_countTrue : ∀ {l : List Bool} {k : Nat},
    (∀ i, l[i]? = some true → i < k) → k ≤ countTrue l →
    ∀ i < k, l[i]? = some true
  | _, 0, _, _, _, hi => by omega
  | [], k + 1, _, hcnt, _, _ => by simp [countTrue] at hcnt
  | false :: bs, k + 1, hb, hcnt, _, _ => by
    have hb' : ∀ i, bs[i]? = some true → i < k := fun i hi =>
      Nat.lt_of_succ_lt_succ (hb (i + 1) hi)
    have := countTrue_le_of_bound hb'
    simp [countTrue] at hcnt; omega
  | true :: bs, k + 1, _, _, 0, _ => rfl
  | true :: bs, k + 1, hb, hcnt, i + 1, hi => by
    have hb' : ∀ j, bs[j]? = some true → j < k := fun j hj =>
      Nat.lt_of_succ_lt_succ (hb (j + 1) hj)
    simp [countTrue] at hcnt
    exact all_true_lt_of_countTrue hb' (by omega) i (by omega)

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
  len_d2hReadyL : s.d2hReadyL.length = s.numLayers
  len_h2hRetiredL : s.h2hRetiredL.length = s.numLayers
  len_claimedL : s.claimedL.length = s.numLayers
  len_h2dPendingL : s.h2dPendingL.length = s.numLayers
  len_h2dIssuedL : s.h2dIssuedL.length = s.numLayers
  len_h2dReadyL : s.h2dReadyL.length = s.numLayers
  /-- Prefill HBM holds the data until the engine reclaims it. -/
  phbm_good : s.reclaimed = false → s.prefillHbm = good s.numLayers
  /-- Prefill HBM is reclaimed only once the send has settled. -/
  reclaimed_done : s.reclaimed = true → s.send.life.done = true
  /-- The per-layer record of finished D2H copies agrees with the send's counter. -/
  cnt_d2hReady : countTrue s.d2hReadyL = s.send.d2hReady
  /-- Only issued D2H copies have finished. -/
  d2hReady_lt : ∀ l : Nat, s.d2hReadyL[l]? = some true → l < s.send.d2hIssued
  /-- The per-layer record of retired H2H pushes agrees with the send's counter. -/
  cnt_h2hRetired : countTrue s.h2hRetiredL = s.send.h2hRetired
  /-- `SendNextLayer(l)`'s callback has run only for layers whose copy finished. -/
  woken_d2hReady : ∀ l : Nat, l < s.send.woken → s.d2hReadyL[l]? = some true
  /-- While the send holds its staging, every finished copy's layer is there. -/
  pstaging_good : s.send.life.done = false →
    ∀ l : Nat, s.d2hReadyL[l]? = some true → s.prefillStaging[l]? = some (.kv l)
  /-- Whatever was delivered for layer `k` is layer `k`. -/
  wire_good : ∀ (k : Nat) (c : Cell), s.wire[k]? = some c → c = .blank ∨ c = .kv k
  /-- A layer is pending in `ExecuteLayerH2d` only after it landed. -/
  pending_landed : ∀ l : Nat, s.h2dPendingL[l]? = some true → s.landedL[l]? = some true
  /-- A layer's H2D copy is issued to the device only after it landed. -/
  issued_landed : ∀ l : Nat, s.h2dIssuedL[l]? = some true → s.landedL[l]? = some true
  /-- A pending layer was claimed. -/
  pending_claimed : ∀ l : Nat, s.h2dPendingL[l]? = some true → s.claimedL[l]? = some true
  /-- An issued layer was claimed and is no longer pending. -/
  issued_claimed : ∀ l : Nat, s.h2dIssuedL[l]? = some true →
    s.claimedL[l]? = some true ∧ s.h2dPendingL[l]? = some false
  /-- The per-layer record of pending H2D dispatches agrees with the receive's counter. -/
  cnt_h2dPending : countTrue s.h2dPendingL = s.recv.pending
  /-- The per-layer record of issued H2D copies agrees with the receive's counter. -/
  cnt_h2dIssued : countTrue s.h2dIssuedL = s.recv.issued
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
    by simp [init], by simp [init], by simp [init], by simp [init], by simp [init],
    by simp [init], by simp [init], by simp [init], fun _ => rfl, by simp [init, Send.init],
    by simp [init, Send.init, countTrue_replicate_false],
    fun l h => (not_mem_replicate_false h).elim,
    by simp [init, Send.init, countTrue_replicate_false],
    by simp [init, Send.init],
    fun _ l h => (not_mem_replicate_false h).elim, ?_,
    fun l h => (not_mem_replicate_false h).elim,
    fun l h => (not_mem_replicate_false h).elim,
    fun l h => (not_mem_replicate_false h).elim,
    fun l h => (not_mem_replicate_false h).elim,
    by simp [init, Recv.initLoad, countTrue_replicate_false],
    by simp [init, Recv.initLoad, countTrue_replicate_false],
    fun _ l h => (not_mem_replicate_false h).elim,
    by simp [init, Recv.initLoad, countTrue_replicate_false],
    fun l h => (not_mem_replicate_false h).elim⟩
  intro k c hk
  simp only [init, List.getElem?_replicate] at hk
  split at hk
  · cases hk; exact Or.inl rfl
  · cases hk

theorem mem_drainEvents_d2hReady {n l : Nat} (hl : l < n) :
    Ev.d2hReady l ∈ drainEvents n := by
  simp only [drainEvents, List.mem_append, List.mem_flatMap, List.mem_range]
  right; exact ⟨l, hl, by simp⟩

theorem mem_drainEvents_h2hDone {n l : Nat} (hl : l < n) :
    Ev.h2hDone l true ∈ drainEvents n := by
  simp only [drainEvents, List.mem_append, List.mem_flatMap, List.mem_range]
  right; exact ⟨l, hl, by simp⟩

theorem mem_drainEvents_h2dIssue {n l : Nat} (hl : l < n) :
    Ev.h2dIssue l true ∈ drainEvents n := by
  simp only [drainEvents, List.mem_append, List.mem_flatMap, List.mem_range]
  right; exact ⟨l, hl, by simp⟩

theorem mem_drainEvents_h2dReady {n l : Nat} (hl : l < n) :
    Ev.h2dReady l ∈ drainEvents n := by
  simp only [drainEvents, List.mem_append, List.mem_flatMap, List.mem_range]
  right; exact ⟨l, hl, by simp⟩

theorem inv_noOpLeak {s : Pipeline} (h : Inv s) : NoOpLeak s := by
  rintro (hif | hif)
  · have hacc := h.send.accounted
    have hcnt := h.send.counters
    unfold Send.Accounted at hacc
    unfold Send.CountersOrdered at hcnt
    by_cases hp : s.send.d2hPending = true
    · refine ⟨.send (.d2hIssue true), by simp [drainEvents], ?_⟩
      simp [step, sendStep, Send.step, Send.d2hIssue, hp]
    · by_cases hrd : s.send.d2hReady < s.send.d2hIssued
      · have hk : s.send.d2hIssued ≤ s.d2hReadyL.length := by
          rw [h.len_d2hReadyL, ← h.n_send]; omega
        obtain ⟨l, hl, hf⟩ := exists_false_lt hk (by rw [h.cnt_d2hReady]; exact hrd)
        have hln : l < s.numLayers := by rw [← h.n_send]; omega
        refine ⟨.d2hReady l, mem_drainEvents_d2hReady hln, ?_⟩
        simp [step, d2hReady, hl, hf, Send.step, Send.markD2hReady, hrd]
      · by_cases hret : s.send.d2hRetired < s.send.d2hReady
        · refine ⟨.send .d2hEnd, by simp [drainEvents], ?_⟩
          simp [step, sendStep, Send.step, Send.d2hEnd, hret]
        · by_cases hwk : s.send.woken < s.send.queued
          · have hwr : s.send.woken < s.send.d2hReady := by omega
            have hwi : s.send.woken < s.send.d2hIssued := by omega
            have hready_eq : s.send.d2hIssued ≤ countTrue s.d2hReadyL := by
              rw [h.cnt_d2hReady]; omega
            have hwl : s.d2hReadyL[s.send.woken]? = some true :=
              all_true_lt_of_countTrue h.d2hReady_lt hready_eq s.send.woken hwi
            refine ⟨.send (.wake true), by simp [drainEvents], ?_⟩
            simp only [step, sendStep, hwl, ↓reduceIte, Send.step, Send.wake, hwk, hwr,
              and_self, Bool.true_eq_false]
            split <;> rfl
          · by_cases hpool : 0 < s.send.pooled
            · have hne : s.send.pooled ≠ 0 := by omega
              refine ⟨.send .h2hIssue, by simp [drainEvents], ?_⟩
              simp only [step, sendStep, Send.step, Send.h2hIssue, hne, ↓reduceIte]
              split <;> rfl
            · by_cases hch : 0 < s.send.chaining
              · refine ⟨.send .sendNext, by simp [drainEvents], ?_⟩
                simp [step, sendStep, Send.step, Send.sendNext]; omega
              · have hh2h : s.send.h2hRetired < s.send.h2hIssued := by
                  cases hdp : s.send.d2hPending <;> simp_all <;> omega
                have hk : s.send.h2hIssued ≤ s.h2hRetiredL.length := by
                  rw [h.len_h2hRetiredL, ← h.n_send]; omega
                obtain ⟨l, hl, hf⟩ := exists_false_lt hk (by rw [h.cnt_h2hRetired]; exact hh2h)
                have hln : l < s.numLayers := by rw [← h.n_send]; omega
                refine ⟨.h2hDone l true, mem_drainEvents_h2hDone hln, ?_⟩
                simp [step, h2hDone, hl, hf, Send.step, Send.h2hDone, hh2h]
  · have hacc := h.recv.accounted
    unfold Recv.Accounted at hacc
    have hr := h.recv.retired_le
    have hy := h.recv.ready_le
    by_cases hp : 0 < s.recv.pushes
    · refine ⟨.recv .pushEnd, by simp [drainEvents], ?_⟩
      simp [step, recvStep, Recv.step, Recv.pushEnd]; omega
    · by_cases hq : s.recv.pullPending = true
      · refine ⟨.recv (.pullReply true), by simp [drainEvents], ?_⟩
        simp [step, recvStep, Recv.step, Recv.pullReply, hq]
      · by_cases hpend : 0 < s.recv.pending
        · have hne : s.recv.pending ≠ 0 := by omega
          obtain ⟨l, hl, hpl⟩ := exists_true_of_countTrue_pos (by rw [h.cnt_h2dPending]; exact hpend)
          rw [h.len_h2dPendingL] at hl
          refine ⟨.h2dIssue l true, mem_drainEvents_h2dIssue hl, ?_⟩
          simp only [step, h2dIssue, hpl, ↓reduceIte, Recv.step, Recv.h2dIssue, hne]
          (repeat' split) <;> rfl
        · by_cases hrd : s.recv.ready < s.recv.issued
          · have hlen : s.h2dReadyL.length = s.h2dIssuedL.length := by
              rw [h.len_h2dReadyL, h.len_h2dIssuedL]
            have hcnt : countTrue s.h2dReadyL < countTrue s.h2dIssuedL := by
              rw [h.cnt_h2dReady, h.cnt_h2dIssued]; exact hrd
            obtain ⟨l, hl, hrf, hit⟩ := exists_diff_of_countTrue_lt hlen hcnt
            rw [h.len_h2dReadyL] at hl
            refine ⟨.h2dReady l, mem_drainEvents_h2dReady hl, ?_⟩
            simp [step, h2dReady, hit, hrf, Recv.step, Recv.h2dReady, hrd]
          · have hret : s.recv.retired < s.recv.ready := by
              cases hqp : s.recv.pullPending <;> simp_all <;> omega
            refine ⟨.recv (.h2dDone true), by simp [drainEvents], ?_⟩
            simp only [step, recvStep, Recv.step, Recv.h2dDone, hret, ↓reduceIte]
            split <;> rfl

theorem inv_safe {s : Pipeline} (h : Inv s) : Safe s := by
  have hsend := h.send
  have hrecv := h.recv
  have hsS := Send.inv_safe hsend
  have hcnt := hsend.counters
  unfold Send.CountersOrdered at hcnt
  refine ⟨?_, ?_, ?_, ⟨?_, ?_⟩, inv_noOpLeak h⟩
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
  · intro hp
    cases hpub : s.recv.published with
    | none => exact (hp hpub).elim
    | some b =>
      have hd := hrecv.published_done b hpub
      have h0 := hrecv.life.done_idle hd
      have hacc := hrecv.accounted
      unfold Recv.Accounted at hacc
      have := hrecv.retired_le
      have := hrecv.ready_le
      exact ⟨by omega, by omega⟩
  · intro hr
    obtain ⟨h0, h1, -⟩ := hsS.2.1 (h.reclaimed_done hr)
    exact ⟨h0, h1⟩
  · intro hst
    obtain ⟨h0, h1, -, -, -, h2⟩ := hsS.2.1 (hsend.life.done_of_released hst)
    exact ⟨h0, h1, h2⟩
  · intro hst
    have hd := hrecv.life.done_of_released hst
    have h0 := hrecv.life.done_idle hd
    have hacc := hrecv.accounted
    unfold Recv.Accounted at hacc
    have := hrecv.retired_le
    have := hrecv.ready_le
    refine ⟨by omega, by omega, by omega⟩

/-! ### Preservation, one lemma per kind of effect -/

/-- A send event that moves no memory, given that the layers `SendNextLayer`
has consumed afterwards all have their copy finished. `x` lets the same lemma
serve `h2hDone l false`, which records the callback without moving data. -/
theorem Inv.send_frame {s : Pipeline} {snd : Send} {e : Send.Ev} (h : Inv s)
    (hs : Send.step s.send e = some snd) (he : e ≠ .d2hReady)
    (hw : ∀ l < snd.woken, s.d2hReadyL[l]? = some true) (x : List Bool)
    (hxlen : x.length = s.numLayers) (hxcnt : countTrue x = snd.h2hRetired) :
    Inv { s with send := snd, h2hRetiredL := x } := by
  refine ⟨Send.step_inv h.send hs, h.recv, (Send.step_numLayers hs).trans h.n_send, h.n_recv,
    h.len_pstaging, h.len_wire, h.len_dstaging, h.len_dhbm, h.len_d2hReadyL, hxlen,
    h.len_claimedL, h.len_h2dPendingL, h.len_h2dIssuedL, h.len_h2dReadyL, h.phbm_good,
    fun hr => Send.step_done_mono hs (h.reclaimed_done hr), ?_, ?_, hxcnt, hw, ?_, h.wire_good,
    h.pending_landed, h.issued_landed, h.pending_claimed, h.issued_claimed,
    h.cnt_h2dPending, h.cnt_h2dIssued, h.dstaging_good, h.cnt_h2dReady, h.dhbm_good⟩
  · show countTrue s.d2hReadyL = snd.d2hReady
    rw [Send.step_d2hReady hs he]; exact h.cnt_d2hReady
  · show ∀ l : Nat, s.d2hReadyL[l]? = some true → l < snd.d2hIssued
    intro l hl
    exact Nat.lt_of_lt_of_le (h.d2hReady_lt l hl) (Send.step_d2hIssued_le hs)
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
    ?_, h.len_wire, h.len_dstaging, h.len_dhbm, ?_, h.len_h2hRetiredL,
    h.len_claimedL, h.len_h2dPendingL, h.len_h2dIssuedL, h.len_h2dReadyL, h.phbm_good,
    fun hr => Send.step_done_mono hs (h.reclaimed_done hr), ?_, ?_, h.cnt_h2hRetired, ?_, ?_, h.wire_good,
    h.pending_landed, h.issued_landed, h.pending_claimed, h.issued_claimed,
    h.cnt_h2dPending, h.cnt_h2dIssued, h.dstaging_good, h.cnt_h2dReady, h.dhbm_good⟩
  · show (s.prefillStaging.set _ _).length = _
    rw [List.length_set]; exact h.len_pstaging
  · show (s.d2hReadyL.set _ _).length = _
    rw [List.length_set]; exact h.len_d2hReadyL
  · show countTrue (s.d2hReadyL.set l true) = s.send.d2hReady + 1
    rw [countTrue_set_true hf, h.cnt_d2hReady]
  · show ∀ j : Nat, (s.d2hReadyL.set l true)[j]? = some true → j < s.send.d2hIssued
    intro j hj
    rcases mem_of_set_true hj with rfl | hj
    · exact hl
    · exact h.d2hReady_lt j hj
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
  have hxlen : (s.h2hRetiredL.set l true).length = s.numLayers := by
    rw [List.length_set]; exact h.len_h2hRetiredL
  have hxcnt : countTrue (s.h2hRetiredL.set l true) = snd.h2hRetired := by
    rw [countTrue_set_true hf, h.cnt_h2hRetired, Send.h2hDone_h2hRetired hs]
  have h' := h.send_frame hs nofun hw (s.h2hRetiredL.set l true) hxlen hxcnt
  refine ⟨h'.send, h'.recv, h'.n_send, h'.n_recv, h'.len_pstaging, ?_, h'.len_dstaging,
    h'.len_dhbm, h'.len_d2hReadyL, h'.len_h2hRetiredL, h'.len_claimedL, h'.len_h2dPendingL,
    h'.len_h2dIssuedL, h'.len_h2dReadyL, h'.phbm_good, h'.reclaimed_done, h'.cnt_d2hReady,
    h'.d2hReady_lt, h'.cnt_h2hRetired, h'.woken_d2hReady, h'.pstaging_good, ?_,
    h'.pending_landed, h'.issued_landed, h'.pending_claimed, h'.issued_claimed,
    h'.cnt_h2dPending, h'.cnt_h2dIssued, h'.dstaging_good, h'.cnt_h2dReady, h'.dhbm_good⟩
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

/-- A receive event that moves no memory. `c`, `p` and `i` let the same lemma
serve `h2dBegin l` and `h2dIssue l ok`, which only update the per-layer dispatch
sets. -/
theorem Inv.recv_frame {s : Pipeline} {rcv : Recv} {e : Recv.Ev} (h : Inv s)
    (hs : Recv.step s.recv e = some rcv) (he : e ≠ .h2dReady) (c p i : List Bool)
    (hclen : c.length = s.numLayers) (hplen : p.length = s.numLayers)
    (hilen : i.length = s.numLayers)
    (hp : ∀ l : Nat, p[l]? = some true → s.landedL[l]? = some true)
    (hi : ∀ l : Nat, i[l]? = some true → s.landedL[l]? = some true)
    (hpc : ∀ l : Nat, p[l]? = some true → c[l]? = some true)
    (hic : ∀ l : Nat, i[l]? = some true → c[l]? = some true ∧ p[l]? = some false)
    (hpcnt : countTrue p = rcv.pending)
    (hicnt : countTrue i = rcv.issued) :
    Inv { s with recv := rcv, claimedL := c, h2dPendingL := p, h2dIssuedL := i } := by
  refine ⟨h.send, Recv.step_inv h.recv hs, h.n_send, (Recv.step_numLayers hs).trans h.n_recv,
    h.len_pstaging, h.len_wire, h.len_dstaging, h.len_dhbm, h.len_d2hReadyL, h.len_h2hRetiredL,
    hclen, hplen, hilen, h.len_h2dReadyL, h.phbm_good, h.reclaimed_done, h.cnt_d2hReady,
    h.d2hReady_lt, h.cnt_h2hRetired, h.woken_d2hReady, h.pstaging_good, h.wire_good, hp, hi,
    hpc, hic, hpcnt, hicnt, ?_, ?_, h.dhbm_good⟩
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
    (hc : s.h2dIssuedL[l]? = some true) (hf : s.h2dReadyL[l]? = some false)
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
    rw [List.getD_eq_getElem?_getD, h.dstaging_good hd l (h.issued_landed l hc)]
    rfl
  rw [hsrc]
  refine ⟨h.send, Recv.step_inv hr hs, h.n_send, (Recv.step_numLayers hs).trans h.n_recv,
    h.len_pstaging, h.len_wire, h.len_dstaging, ?_, h.len_d2hReadyL, h.len_h2hRetiredL,
    h.len_claimedL, h.len_h2dPendingL, h.len_h2dIssuedL, ?_, h.phbm_good, h.reclaimed_done,
    h.cnt_d2hReady, h.d2hReady_lt, h.cnt_h2hRetired, h.woken_d2hReady, h.pstaging_good,
    h.wire_good, h.pending_landed, h.issued_landed, h.pending_claimed, h.issued_claimed,
    h.cnt_h2dPending, h.cnt_h2dIssued, h.dstaging_good, ?_, ?_⟩
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
        exact h.send_frame hsnd nofun (woken_after_wake h hsnd hg) _ h.len_h2hRetiredL
          (by rw [Send.step_h2hRetired hsnd nofun]; exact h.cnt_h2hRetired)
      · cases hs
    all_goals
      (try (rename_i ok; cases ok))
      all_goals
        simp only [step, sendStep, Option.map_eq_some_iff] at hs
        obtain ⟨snd, hsnd, rfl⟩ := hs
        exact h.send_frame hsnd nofun (woken_after_other h hsnd nofun) _ h.len_h2hRetiredL
          (by rw [Send.step_h2hRetired hsnd nofun]; exact h.cnt_h2hRetired)
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
          (by rw [List.length_set]; exact h.len_h2hRetiredL)
          (by rw [countTrue_set_true hf, h.cnt_h2hRetired, Send.h2hDone_h2hRetired hsnd])
      · exact h.send_h2hDone hl hf hsnd hw
    · cases hs
  | recv e =>
    cases e
    case h2dBegin => simp only [step, recvStep] at hs; cases hs
    case h2dIssue ok => simp only [step, recvStep] at hs; cases hs
    case h2dReady => simp only [step, recvStep] at hs; cases hs
    all_goals
      (try (rename_i ok; cases ok))
      all_goals
        simp only [step, recvStep, Option.map_eq_some_iff] at hs
        obtain ⟨rcv, hrcv, rfl⟩ := hs
        have hpi := Recv.step_pending_issued hrcv nofun nofun
        exact h.recv_frame hrcv nofun _ _ _ h.len_claimedL h.len_h2dPendingL h.len_h2dIssuedL
          h.pending_landed h.issued_landed h.pending_claimed h.issued_claimed
          (by rw [hpi.1]; exact h.cnt_h2dPending) (by rw [hpi.2]; exact h.cnt_h2dIssued)
  | h2dBegin l =>
    simp only [step, h2dBegin] at hs
    split at hs
    · rename_i hg
      obtain ⟨hld, hf⟩ := hg
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨rcv, hrcv, rfl⟩ := hs
      obtain ⟨_, hpend, hiss⟩ := Recv.h2dBegin_spec hrcv
      have hpf : s.h2dPendingL[l]? = some false :=
        false_of_not_true (h.len_claimedL.trans h.len_h2dPendingL.symm) hf
          (fun hp => by rw [h.pending_claimed l hp] at hf; cases hf)
      have hif : s.h2dIssuedL[l]? = some false :=
        false_of_not_true (h.len_claimedL.trans h.len_h2dIssuedL.symm) hf
          (fun hi => by rw [(h.issued_claimed l hi).1] at hf; cases hf)
      apply h.recv_frame hrcv nofun _ _ _
        (by rw [List.length_set]; exact h.len_claimedL)
        (by rw [List.length_set]; exact h.len_h2dPendingL)
        h.len_h2dIssuedL
      · intro j hj
        rcases mem_of_set_true hj with rfl | hj
        · exact hld
        · exact h.pending_landed j hj
      · exact h.issued_landed
      · intro j hj
        rcases mem_of_set_true hj with rfl | hj
        · exact set_true_self hf
        · exact set_true_of_mem hf (h.pending_claimed j hj)
      · intro j hj
        have hjl : j ≠ l := by intro rfl; rw [hif] at hj; cases hj
        refine ⟨set_true_of_mem hf (h.issued_claimed j hj).1, ?_⟩
        rw [List.getElem?_set_ne (Ne.symm hjl)]
        exact (h.issued_claimed j hj).2
      · rw [countTrue_set_true hpf, h.cnt_h2dPending, hpend]
      · rw [h.cnt_h2dIssued, hiss]
    · cases hs
  | h2dIssue l ok =>
    simp only [step, h2dIssue] at hs
    split at hs
    · rename_i hp
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨rcv, hrcv, rfl⟩ := hs
      obtain ⟨_, hpend, hiss⟩ := Recv.h2dIssue_spec hrcv
      have hlt_p : l < s.h2dPendingL.length := lt_length_of_getElem?_eq hp
      have hif : s.h2dIssuedL[l]? = some false := by
        have hlt_i : l < s.h2dIssuedL.length := by
          rw [h.len_h2dIssuedL, ← h.len_h2dPendingL]; exact hlt_p
        have heq := List.getElem?_eq_getElem hlt_i
        cases hb : s.h2dIssuedL[l]
        · rw [heq, hb]
        · rw [hb] at heq
          rw [(h.issued_claimed l heq).2] at hp; cases hp
      apply h.recv_frame hrcv nofun _ _ _
        h.len_claimedL
        (by rw [List.length_set]; exact h.len_h2dPendingL)
        (by split <;> simp [h.len_h2dIssuedL])
      · intro j hj
        exact h.pending_landed j (mem_of_set_false hj)
      · intro j hj
        split at hj
        · exact h.issued_landed j hj
        · rcases mem_of_set_true hj with rfl | hj'
          · exact h.pending_landed j hp
          · exact h.issued_landed j hj'
      · intro j hj
        exact h.pending_claimed j (mem_of_set_false hj)
      · intro j hj
        split at hj
        · refine ⟨(h.issued_claimed j hj).1, ?_⟩
          by_cases hjl : j = l
          · subst hjl; exact List.getElem?_set_self hlt_p
          · rw [List.getElem?_set_ne (Ne.symm hjl)]; exact (h.issued_claimed j hj).2
        · rcases mem_of_set_true hj with rfl | hj'
          · exact ⟨h.pending_claimed j hp, List.getElem?_set_self hlt_p⟩
          · have hjl : j ≠ l := by intro rfl; rw [hif] at hj'; cases hj'
            refine ⟨(h.issued_claimed j hj').1, ?_⟩
            rw [List.getElem?_set_ne (Ne.symm hjl)]; exact (h.issued_claimed j hj').2
      · have := countTrue_set_false hp
        rw [h.cnt_h2dPending] at this
        omega
      · rw [hiss]
        split
        · exact h.cnt_h2dIssued
        · rw [countTrue_set_true hif, h.cnt_h2dIssued]
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
          h.len_d2hReadyL, h.len_h2hRetiredL, h.len_claimedL, h.len_h2dPendingL,
          h.len_h2dIssuedL, h.len_h2dReadyL, h.phbm_good, h.reclaimed_done, h.cnt_d2hReady,
          h.d2hReady_lt, h.cnt_h2hRetired, h.woken_d2hReady, h.pstaging_good, h.wire_good,
          ?_, ?_, h.pending_claimed, h.issued_claimed, h.cnt_h2dPending, h.cnt_h2dIssued,
          ?_, h.cnt_h2dReady, h.dhbm_good⟩
        · show (s.decodeStaging.set _ _).length = _
          rw [List.length_set]; exact h.len_dstaging
        · show ∀ j : Nat, s.h2dPendingL[j]? = some true → (s.landedL.set l true)[j]? = some true
          intro j hj
          exact set_true_of_mem hf (h.pending_landed j hj)
        · show ∀ j : Nat, s.h2dIssuedL[j]? = some true → (s.landedL.set l true)[j]? = some true
          intro j hj
          exact set_true_of_mem hf (h.issued_landed j hj)
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
        h.len_dhbm, h.len_d2hReadyL, h.len_h2hRetiredL, h.len_claimedL, h.len_h2dPendingL,
        h.len_h2dIssuedL, h.len_h2dReadyL, ?_, ?_, h.cnt_d2hReady, h.d2hReady_lt,
        h.cnt_h2hRetired, h.woken_d2hReady, h.pstaging_good, h.wire_good, h.pending_landed,
        h.issued_landed, h.pending_claimed, h.issued_claimed, h.cnt_h2dPending,
        h.cnt_h2dIssued, h.dstaging_good, h.cnt_h2dReady, h.dhbm_good⟩
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
        h.len_dhbm, h.len_d2hReadyL, h.len_h2hRetiredL, h.len_claimedL, h.len_h2dPendingL,
        h.len_h2dIssuedL, h.len_h2dReadyL, h.phbm_good, h.reclaimed_done, h.cnt_d2hReady,
        h.d2hReady_lt, h.cnt_h2hRetired, h.woken_d2hReady, ?_, h.wire_good, h.pending_landed,
        h.issued_landed, h.pending_claimed, h.issued_claimed, h.cnt_h2dPending,
        h.cnt_h2dIssued, h.dstaging_good, h.cnt_h2dReady, h.dhbm_good⟩
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
        h.len_dhbm, h.len_d2hReadyL, h.len_h2hRetiredL, h.len_claimedL, h.len_h2dPendingL,
        h.len_h2dIssuedL, h.len_h2dReadyL, h.phbm_good, h.reclaimed_done, h.cnt_d2hReady,
        h.d2hReady_lt, h.cnt_h2hRetired, h.woken_d2hReady, h.pstaging_good, h.wire_good,
        h.pending_landed, h.issued_landed, h.pending_claimed, h.issued_claimed,
        h.cnt_h2dPending, h.cnt_h2dIssued, ?_, h.cnt_h2dReady, h.dhbm_good⟩
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

/-! ### Progress and eventual settlement -/

/-- Remaining steps needed to drain all in-flight operations once both sessions
are draining. -/
def drainRank (s : Pipeline) : Nat :=
  Send.drainRank s.send + Recv.drainRank s.recv

theorem drain_send_step {s : Pipeline} (h : Inv s)
    (hdr : s.send.life.draining = true) (hnd : s.send.life.done = false) :
    ∃ e s', step s e = some s' ∧ s'.send.life.draining = true ∧
      s'.recv = s.recv ∧ Send.drainRank s'.send < Send.drainRank s.send := by
  have hif : 0 < s.send.life.inFlight := by
    cases h0 : s.send.life.inFlight
    · have := h.send.life.prompt hdr h0; simp [hnd] at this
    · omega
  have hacc := h.send.accounted
  have hcnt := h.send.counters
  unfold Send.Accounted at hacc
  unfold Send.CountersOrdered at hcnt
  by_cases hp : s.send.d2hPending = true
  · have hs₁ : step s (.send (.d2hIssue true)) =
        some { s with send := { s.send with d2hPending := false, d2hIssued := s.send.d2hIssued + 1 } } := by
      simp [step, sendStep, Send.step, Send.d2hIssue, hp,
        Send.trySendNext_of_draining (s := { s.send with d2hPending := false, d2hIssued := s.send.d2hIssued + 1 }) hdr]
    exact ⟨.send (.d2hIssue true), _, hs₁, by simp [hdr], rfl, by simp [Send.drainRank, hp]; omega⟩
  · by_cases hrd : s.send.d2hReady < s.send.d2hIssued
    · have hk : s.send.d2hIssued ≤ s.d2hReadyL.length := by
        rw [h.len_d2hReadyL, ← h.n_send]; omega
      obtain ⟨l, hl, hf⟩ := exists_false_lt hk (by rw [h.cnt_d2hReady]; exact hrd)
      have hs₁ : step s (.d2hReady l) =
          some { s with send := { s.send with d2hReady := s.send.d2hReady + 1 },
                        prefillStaging := s.prefillStaging.set l (s.prefillHbm.getD l .junk),
                        d2hReadyL := s.d2hReadyL.set l true } := by
        simp [step, d2hReady, hl, hf, Send.step, Send.markD2hReady, hrd]
      exact ⟨.d2hReady l, _, hs₁, by simp [hdr], rfl, by simp [Send.drainRank]; omega⟩
    · by_cases hret : s.send.d2hRetired < s.send.d2hReady
      · have hs₁ : step s (.send .d2hEnd) =
            some { s with send := { s.send with d2hRetired := s.send.d2hRetired + 1 }.endOp } := by
          simp [step, sendStep, Send.step, Send.d2hEnd, hret]
        exact ⟨.send .d2hEnd, _, hs₁, by simp [hdr], rfl, by rw [Send.drainRank_endOp]; simp [Send.drainRank]; omega⟩
      · by_cases hwk : s.send.woken < s.send.queued
        · have hwr : s.send.woken < s.send.d2hReady := by omega
          have hwi : s.send.woken < s.send.d2hIssued := by omega
          have hready_eq : s.send.d2hIssued ≤ countTrue s.d2hReadyL := by
            rw [h.cnt_d2hReady]; omega
          have hwl : s.d2hReadyL[s.send.woken]? = some true :=
            all_true_lt_of_countTrue h.d2hReady_lt hready_eq s.send.woken hwi
          have hs₁ : step s (.send (.wake true)) =
              some { s with send := { s.send with woken := s.send.woken + 1 }.endOp } := by
            simp [step, sendStep, hwl, Send.step, Send.wake, hwk, hwr, hdr]
          exact ⟨.send (.wake true), _, hs₁, by simp [hdr], rfl, by rw [Send.drainRank_endOp]; simp [Send.drainRank]; omega⟩
        · by_cases hpool : 0 < s.send.pooled
          · have hs₁ : step s (.send .h2hIssue) =
                some { s with send := { s.send with pooled := s.send.pooled - 1 }.endOp } := by
              simp [step, sendStep, Send.step, Send.h2hIssue, Lifecycle.beginOp_of_draining hdr]; omega
            exact ⟨.send .h2hIssue, _, hs₁, by simp [hdr], rfl, by rw [Send.drainRank_endOp]; simp [Send.drainRank]; omega⟩
          · by_cases hch : 0 < s.send.chaining
            · have hs₁ : step s (.send .sendNext) =
                  some { s with send := { s.send with chaining := s.send.chaining - 1 }.endOp } := by
                simp [step, sendStep, Send.step, Send.sendNext,
                  Send.trySendNext_of_draining (s := { s.send with chaining := s.send.chaining - 1 }) hdr]
                omega
              exact ⟨.send .sendNext, _, hs₁, by simp [hdr], rfl, by rw [Send.drainRank_endOp]; simp [Send.drainRank]; omega⟩
            · have hh2h : s.send.h2hRetired < s.send.h2hIssued := by
                cases hdp : s.send.d2hPending <;> simp_all <;> omega
              have hk : s.send.h2hIssued ≤ s.h2hRetiredL.length := by
                rw [h.len_h2hRetiredL, ← h.n_send]; omega
              obtain ⟨l, hl, hf⟩ := exists_false_lt hk (by rw [h.cnt_h2hRetired]; exact hh2h)
              have hs₁ : step s (.h2hDone l true) =
                  some { s with send := { s.send with h2hRetired := s.send.h2hRetired + 1, h2hOk := s.send.h2hOk + 1 }.endOp,
                                wire := s.wire.set l (s.prefillStaging.getD l .junk),
                                h2hRetiredL := s.h2hRetiredL.set l true } := by
                simp [step, h2hDone, hl, hf, Send.step, Send.h2hDone, hh2h,
                  Send.finish_of_draining true (s := { s.send with h2hRetired := s.send.h2hRetired + 1, h2hOk := s.send.h2hOk + 1 }) hdr]
              exact ⟨.h2hDone l true, _, hs₁, by simp [hdr], rfl, by rw [Send.drainRank_endOp]; simp [Send.drainRank]; omega⟩

theorem drain_recv_step {s : Pipeline} (h : Inv s)
    (hdr : s.recv.life.draining = true) (hnd : s.recv.life.done = false) :
    ∃ e s', step s e = some s' ∧ s'.recv.life.draining = true ∧
      s'.send = s.send ∧ Recv.drainRank s'.recv < Recv.drainRank s.recv := by
  have hif : 0 < s.recv.life.inFlight := by
    cases h0 : s.recv.life.inFlight
    · have := h.recv.life.prompt hdr h0; simp [hnd] at this
    · omega
  have hacc := h.recv.accounted
  unfold Recv.Accounted at hacc
  have hr := h.recv.retired_le
  have hy := h.recv.ready_le
  by_cases hp : 0 < s.recv.pushes
  · have hs₁ : step s (.recv .pushEnd) =
        some { s with recv := { s.recv with life := s.recv.life.endOpLocked, pushes := s.recv.pushes - 1 } } := by
      simp [step, recvStep, Recv.step, Recv.pushEnd]; omega
    exact ⟨.recv .pushEnd, _, hs₁, by simp [hdr], rfl, by simp [Recv.drainRank]; omega⟩
  · by_cases hq : s.recv.pullPending = true
    · have hs₁ : step s (.recv (.pullReply true)) =
          some { s with recv := { s.recv with life := s.recv.life.endOpLocked, pullPending := false } } := by
        simp [step, recvStep, Recv.step, Recv.pullReply, hq]
      exact ⟨.recv (.pullReply true), _, hs₁, by simp [hdr], rfl, by simp [Recv.drainRank, hq]⟩
    · by_cases hpend : 0 < s.recv.pending
      · obtain ⟨l, _, hpl⟩ := exists_true_of_countTrue_pos (by rw [h.cnt_h2dPending]; exact hpend)
        have hs₁ : step s (.h2dIssue l true) =
            some { s with recv := { s.recv with pending := s.recv.pending - 1, life := s.recv.life.endOpLocked },
                          h2dPendingL := s.h2dPendingL.set l false,
                          h2dIssuedL := s.h2dIssuedL } := by
          simp [step, h2dIssue, hpl, Recv.step, Recv.h2dIssue, hdr]; omega
        exact ⟨.h2dIssue l true, _, hs₁, by simp [hdr], rfl, by simp [Recv.drainRank]; omega⟩
      · by_cases hrd : s.recv.ready < s.recv.issued
        · have hlen : s.h2dReadyL.length = s.h2dIssuedL.length := by
            rw [h.len_h2dReadyL, h.len_h2dIssuedL]
          have hcnt : countTrue s.h2dReadyL < countTrue s.h2dIssuedL := by
            rw [h.cnt_h2dReady, h.cnt_h2dIssued]; exact hrd
          obtain ⟨l, _, hrf, hit⟩ := exists_diff_of_countTrue_lt hlen hcnt
          have hs₁ : step s (.h2dReady l) =
              some { s with recv := { s.recv with ready := s.recv.ready + 1 },
                            decodeHbm := s.decodeHbm.set l (s.decodeStaging.getD l .junk),
                            h2dReadyL := s.h2dReadyL.set l true } := by
            simp [step, h2dReady, hit, hrf, Recv.step, Recv.h2dReady, hrd]
          exact ⟨.h2dReady l, _, hs₁, by simp [hdr], rfl, by simp [Recv.drainRank]; omega⟩
        · have hret : s.recv.retired < s.recv.ready := by
            cases hqp : s.recv.pullPending <;> simp_all <;> omega
          have hs₁ : step s (.recv (.h2dDone true)) =
              some { s with recv := { s.recv with retired := s.recv.retired + 1, completed := s.recv.completed + 1, life := s.recv.life.endOpLocked } } := by
            simp [step, recvStep, Recv.step, Recv.h2dDone, hret, hnd, hdr]
          exact ⟨.recv (.h2dDone true), _, hs₁, by simp [hdr], rfl, by simp [Recv.drainRank]; omega⟩

theorem draining_can_settle_aux (n : Nat) :
    ∀ (k : Nat) {s : Pipeline}, drainRank s ≤ k → Inv s →
      s.send.life.draining = true → s.recv.life.draining = true →
      ∃ evs s', (sys n).runFrom s evs = some s' ∧
        s'.send.life.done = true ∧ s'.send.life.hasStaging = false ∧
        s'.recv.life.done = true ∧ s'.recv.life.hasStaging = false
  | 0, s, hk, h, hdrS, hdrR => by
    have haccS := h.send.accounted
    have haccR := h.recv.accounted
    unfold Send.Accounted at haccS
    unfold Recv.Accounted at haccR
    unfold drainRank Send.drainRank Recv.drainRank at hk
    have hdS : s.send.life.done = true := h.send.life.prompt hdrS (by omega)
    have hstS : s.send.life.hasStaging = false := by rw [h.send.life.staging, hdS]; rfl
    have hdR : s.recv.life.done = true := h.recv.life.prompt hdrR (by omega)
    have hstR : s.recv.life.hasStaging = false := by rw [h.recv.life.staging, hdR]; rfl
    exact ⟨[], s, rfl, hdS, hstS, hdR, hstR⟩
  | k + 1, s, hk, h, hdrS, hdrR => by
    cases hndS : s.send.life.done
    · obtain ⟨e, s₁, hs₁, hdrS₁, hrecv_eq, hlt⟩ := drain_send_step h hdrS hndS
      have hdrR₁ : s₁.recv.life.draining = true := by rw [hrecv_eq]; exact hdrR
      have hrk : drainRank s₁ ≤ k := by
        unfold drainRank at hk ⊢; rw [hrecv_eq]; omega
      obtain ⟨evs, s', hrun, hdS', hstS', hdR', hstR'⟩ :=
        draining_can_settle_aux n k hrk (step_inv h hs₁) hdrS₁ hdrR₁
      refine ⟨e :: evs, s', ?_, hdS', hstS', hdR', hstR'⟩
      simp only [System.runFrom, sys, List.foldlM_cons, hs₁]
      exact hrun
    · cases hndR : s.recv.life.done
      · obtain ⟨e, s₁, hs₁, hdrR₁, hsend_eq, hlt⟩ := drain_recv_step h hdrR hndR
        have hdrS₁ : s₁.send.life.draining = true := by rw [hsend_eq]; exact hdrS
        have hrk : drainRank s₁ ≤ k := by
          unfold drainRank at hk ⊢; rw [hsend_eq]; omega
        obtain ⟨evs, s', hrun, hdS', hstS', hdR', hstR'⟩ :=
          draining_can_settle_aux n k hrk (step_inv h hs₁) hdrS₁ hdrR₁
        refine ⟨e :: evs, s', ?_, hdS', hstS', hdR', hstR'⟩
        simp only [System.runFrom, sys, List.foldlM_cons, hs₁]
        exact hrun
      · have hstS : s.send.life.hasStaging = false := by rw [h.send.life.staging, hndS]; rfl
        have hstR : s.recv.life.hasStaging = false := by rw [h.recv.life.staging, hndR]; rfl
        exact ⟨[], s, rfl, hndS, hstS, hndR, hstR⟩

theorem runFrom_append {n : Nat} :
    ∀ (evs₁ evs₂ : List Ev) {s s₁ s₂ : Pipeline},
      (sys n).runFrom s evs₁ = some s₁ →
      (sys n).runFrom s₁ evs₂ = some s₂ →
      (sys n).runFrom s (evs₁ ++ evs₂) = some s₂
  | [], evs₂, s, s₁, s₂, h₁, h₂ => by
    simp [System.runFrom] at h₁; subst h₁; exact h₂
  | e :: evs₁, evs₂, s, s₁, s₂, h₁, h₂ => by
    simp only [System.runFrom, sys, List.cons_append, List.foldlM_cons] at h₁ ⊢
    cases hse : step s e with
    | none => simp [hse] at h₁
    | some s' =>
      simp only [hse] at h₁ ⊢
      exact runFrom_append evs₁ evs₂ h₁ h₂

/-- Once both sessions have settled (`done = true`), a short trace of at most
three events (`.send .publish`, `.recv .publish`, `.reclaim`) publishes both
outcomes and reclaims prefill HBM. -/
theorem settled_can_finalize (n : Nat) {s : Pipeline}
    (hdS : s.send.life.done = true) (hstS : s.send.life.hasStaging = false)
    (hdR : s.recv.life.done = true) (hstR : s.recv.life.hasStaging = false) :
    ∃ evs s', (sys n).runFrom s evs = some s' ∧
      s'.send.life.done = true ∧ s'.send.life.hasStaging = false ∧
      s'.recv.life.done = true ∧ s'.recv.life.hasStaging = false ∧
      s'.send.published ≠ none ∧ s'.recv.published ≠ none ∧ s'.reclaimed = true := by
  have ⟨evs₁, s₁, hr₁, hdS₁, hstS₁, hdR₁, hstR₁, hpubS₁⟩ :
      ∃ evs₁ s₁, (sys n).runFrom s evs₁ = some s₁ ∧
        s₁.send.life.done = true ∧ s₁.send.life.hasStaging = false ∧
        s₁.recv.life.done = true ∧ s₁.recv.life.hasStaging = false ∧
        s₁.send.published ≠ none := by
    cases hp : s.send.published with
    | none =>
      refine ⟨[.send .publish], { s with send := { s.send with published := some s.send.life.statusOk } }, ?_,
        hdS, hstS, hdR, hstR, by simp⟩
      simp [System.runFrom, sys, step, sendStep, Send.step, Send.publish, hdS, hp]
    | some b =>
      exact ⟨[], s, rfl, hdS, hstS, hdR, hstR, by simp [hp]⟩
  have ⟨evs₂, s₂, hr₂, hdS₂, hstS₂, hdR₂, hstR₂, hpubS₂, hpubR₂⟩ :
      ∃ evs₂ s₂, (sys n).runFrom s₁ evs₂ = some s₂ ∧
        s₂.send.life.done = true ∧ s₂.send.life.hasStaging = false ∧
        s₂.recv.life.done = true ∧ s₂.recv.life.hasStaging = false ∧
        s₂.send.published ≠ none ∧ s₂.recv.published ≠ none := by
    cases hp : s₁.recv.published with
    | none =>
      refine ⟨[.recv .publish], { s₁ with recv := { s₁.recv with published := some s₁.recv.life.statusOk } }, ?_,
        hdS₁, hstS₁, hdR₁, hstR₁, hpubS₁, by simp⟩
      simp [System.runFrom, sys, step, recvStep, Recv.step, Recv.publish, hdR₁, hp]
    | some b =>
      exact ⟨[], s₁, rfl, hdS₁, hstS₁, hdR₁, hstR₁, hpubS₁, by simp [hp]⟩
  have ⟨evs₃, s₃, hr₃, hdS₃, hstS₃, hdR₃, hstR₃, hpubS₃, hpubR₃, hrec₃⟩ :
      ∃ evs₃ s₃, (sys n).runFrom s₂ evs₃ = some s₃ ∧
        s₃.send.life.done = true ∧ s₃.send.life.hasStaging = false ∧
        s₃.recv.life.done = true ∧ s₃.recv.life.hasStaging = false ∧
        s₃.send.published ≠ none ∧ s₃.recv.published ≠ none ∧ s₃.reclaimed = true := by
    cases hrec : s₂.reclaimed with
    | false =>
      refine ⟨[.reclaim], { s₂ with prefillHbm := List.replicate s₂.numLayers .junk, reclaimed := true }, ?_,
        hdS₂, hstS₂, hdR₂, hstR₂, hpubS₂, hpubR₂, rfl⟩
      simp [System.runFrom, sys, step, reclaim, hpubS₂, hrec]
    | true =>
      exact ⟨[], s₂, rfl, hdS₂, hstS₂, hdR₂, hstR₂, hpubS₂, hpubR₂, hrec⟩
  exact ⟨evs₁ ++ evs₂ ++ evs₃, s₃,
    runFrom_append (evs₁ ++ evs₂) evs₃ (runFrom_append evs₁ evs₂ hr₁ hr₂) hr₃,
    hdS₃, hstS₃, hdR₃, hstR₃, hpubS₃, hpubR₃, hrec₃⟩

/-- Every reachable pipeline state can settle both sessions, release both
staging buffers, publish both outcomes, and reclaim prefill HBM in a finite
number of steps. -/
theorem reachable_can_settle {n : Nat} {s : Pipeline} (h : (sys n).Reachable s) :
    ∃ evs s', (sys n).runFrom s evs = some s' ∧
      s'.send.life.done = true ∧ s'.send.life.hasStaging = false ∧
      s'.recv.life.done = true ∧ s'.recv.life.hasStaging = false ∧
      s'.send.published ≠ none ∧ s'.recv.published ≠ none ∧ s'.reclaimed = true := by
  have hinv := reachable_inv h
  have hcS : step s (.send .cancel) = some { s with send := s.send.finish false } := rfl
  let s₁ : Pipeline := { s with send := s.send.finish false }
  have hinv₁ : Inv s₁ := step_inv hinv hcS
  have hcR : step s₁ (.recv .cancel) =
      some { s₁ with recv := { s₁.recv with life := s₁.recv.life.finishLocked false } } := rfl
  let s₂ : Pipeline := { s₁ with recv := { s₁.recv with life := s₁.recv.life.finishLocked false } }
  have hinv₂ : Inv s₂ := step_inv hinv₁ hcR
  have hdrS₂ : s₂.send.life.draining = true := by
    show (s.send.finish false).life.draining = true
    rcases Send.finish_cases false hinv.send.life with ⟨hd, heq⟩ | ⟨hd, _, heq⟩ <;> simp [heq, hd]
  have hdrR₂ : s₂.recv.life.draining = true := by simp [s₂]
  obtain ⟨evs_d, s_d, hrd, hdS, hstS, hdR, hstR⟩ :=
    draining_can_settle_aux n (drainRank s₂) (Nat.le_refl _) hinv₂ hdrS₂ hdrR₂
  obtain ⟨evs_f, s', hrf, hdS', hstS', hdR', hstR', hpubS', hpubR', hrec'⟩ :=
    settled_can_finalize n hdS hstS hdR hstR
  have hr_cancel : (sys n).runFrom s [.send .cancel, .recv .cancel] = some s₂ := by
    simp [System.runFrom, sys, hcS, hcR, s₁, s₂]
  exact ⟨[.send .cancel, .recv .cancel] ++ evs_d ++ evs_f, s',
    runFrom_append _ evs_f (runFrom_append _ evs_d hr_cancel hrd) hrf,
    hdS', hstS', hdR', hstR', hpubS', hpubR', hrec'⟩

/-! ### Buffer quietness after release

`DecodeHbmSafe`, `PrefillHbmSafe`, and `StagingSafe` state that when a buffer is
released, the session's internal counters for that buffer are drained. The
theorems below turn those counter equalities into the memory-level
non-interference property needed across requests: once a transfer releases a
buffer, no subsequent transition of that transfer can ever read or write that
buffer. -/

/-- Unfold `step` for a known event and split every branch, leaving `hs` as
`some … = some s'`, as the `Option.map` form, or closed. -/
macro "pipe_cases" hs:ident : tactic =>
  `(tactic| (simp only [step, sendStep, recvStep, d2hReady, h2hDone, h2dBegin, h2dIssue,
      h2dReady, land, reclaim, reseatPrefillStaging, reseatDecodeStaging] at $hs:ident <;>
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

theorem step_published_ne_none {s s' : Pipeline} {e : Ev} (hs : step s e = some s')
    (hp : s.recv.published ≠ none) : s'.recv.published ≠ none := by
  cases h : s.recv.published with
  | none => exact absurd h hp
  | some b => rw [step_published_mono hs h]; simp

theorem step_reclaimed_mono {s s' : Pipeline} {e : Ev} (hs : step s e = some s')
    (hr : s.reclaimed = true) : s'.reclaimed = true := by
  cases e <;> (try (rename_i e; cases e)) <;> (try (rename_i ok; cases ok)) <;> pipe_cases hs <;>
  first
    | (obtain ⟨_, _, rfl⟩ := hs; exact hr)
    | (cases hs <;> first | exact hr | rfl)
    | cases hs

theorem step_send_done_mono {s s' : Pipeline} {e : Ev} (hs : step s e = some s')
    (hd : s.send.life.done = true) : s'.send.life.done = true := by
  cases e <;> (try (rename_i e; cases e)) <;> (try (rename_i ok; cases ok)) <;> pipe_cases hs <;>
  first
    | (obtain ⟨_, hr, rfl⟩ := hs; first | exact hd | exact Send.step_done_mono hr hd)
    | (cases hs <;> exact hd)
    | cases hs

theorem step_recv_done_mono {s s' : Pipeline} {e : Ev} (hs : step s e = some s')
    (hd : s.recv.life.done = true) : s'.recv.life.done = true := by
  cases e <;> (try (rename_i e; cases e)) <;> (try (rename_i ok; cases ok)) <;> pipe_cases hs <;>
  first
    | (obtain ⟨_, hr, rfl⟩ := hs; first | exact hd | exact Recv.step_done_mono hr hd)
    | (cases hs <;> exact hd)
    | cases hs

theorem numLayers_eq {n : Nat} {s : Pipeline} (h : (sys n).Reachable s) : s.numLayers = n :=
  (sys n).reachable_induction (P := fun s => s.numLayers = n) rfl
    (fun _ _ _ hi hs => (step_numLayers hs).trans hi) h

/-- Once prefill HBM is reclaimed (`s.reclaimed = true`), `d2hReady` is
permanently disabled (`PrefillHbmSafe` gives `d2hRetired = d2hIssued`, which
with `d2hRetired ≤ d2hReady ≤ d2hIssued` forces `d2hReady = d2hIssued`). -/
theorem prefillHbm_quiet {s : Pipeline} (h : Inv s) (hrec : s.reclaimed = true) (l : Nat) :
    step s (.d2hReady l) = none := by
  have ⟨_, hret⟩ := (inv_safe h).2.2.1 hrec
  have hcnt := h.send.counters
  unfold Send.CountersOrdered at hcnt
  have hnr : ¬ (s.send.d2hReady < s.send.d2hIssued) := by omega
  simp [step, d2hReady, Send.step, Send.markD2hReady, hnr]

theorem prefillHbm_quiet_step {s s' : Pipeline} {e : Ev} (h : Inv s)
    (hrec : s.reclaimed = true) (hs : step s e = some s') :
    s'.prefillHbm = s.prefillHbm := by
  cases e with
  | reclaim => simp [step, reclaim, hrec] at hs
  | d2hReady l => rw [prefillHbm_quiet h hrec l] at hs; cases hs
  | _ =>
    (try (rename_i e; cases e)) <;> (try (rename_i ok; cases ok)) <;> pipe_cases hs <;>
    first | (obtain ⟨_, _, rfl⟩ := hs; rfl) | (cases hs <;> rfl) | cases hs

/-- Once the send session releases its staging buffer (`hasStaging = false`), no
transfer event (anything other than the environment's `reseatPrefillStaging`)
can modify `prefillStaging` or `wire`. Proved from `StagingSafe`. -/
theorem prefillStaging_quiet {s s' : Pipeline} {e : Ev} (h : Inv s)
    (hst : s.send.life.hasStaging = false) (hne : e ≠ .reseatPrefillStaging)
    (hs : step s e = some s') :
    s'.prefillStaging = s.prefillStaging ∧ s'.wire = s.wire := by
  have ⟨_, hd2h, hh2h⟩ := (inv_safe h).2.2.2.1.1 hst
  have hcnt := h.send.counters
  unfold Send.CountersOrdered at hcnt
  cases e with
  | d2hReady l =>
    have hnr : ¬ (s.send.d2hReady < s.send.d2hIssued) := by omega
    simp [step, d2hReady, Send.step, Send.markD2hReady, hnr] at hs
  | h2hDone l ok =>
    have hnr : ¬ (s.send.h2hRetired < s.send.h2hIssued) := by omega
    simp [step, h2hDone, Send.step, Send.h2hDone, hnr] at hs
  | reseatPrefillStaging => exact absurd rfl hne
  | _ =>
    (try (rename_i e; cases e)) <;> (try (rename_i ok; cases ok)) <;> pipe_cases hs <;>
    first | (obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩) | (cases hs <;> exact ⟨rfl, rfl⟩) | cases hs

/-- Once the receive session releases its staging buffer (`hasStaging = false`),
no transfer event (anything other than the environment's `reseatDecodeStaging`)
can modify `decodeStaging` or `decodeHbm`. Proved from `StagingSafe`. -/
theorem decodeStaging_quiet {s s' : Pipeline} {e : Ev} (h : Inv s)
    (hst : s.recv.life.hasStaging = false) (hne : e ≠ .reseatDecodeStaging)
    (hs : step s e = some s') :
    s'.decodeStaging = s.decodeStaging ∧ s'.decodeHbm = s.decodeHbm := by
  have ⟨hpush, _, hret⟩ := (inv_safe h).2.2.2.1.2 hst
  have hr := h.recv.retired_le
  have hy := h.recv.ready_le
  cases e with
  | land l =>
    simp [step, land, hpush] at hs
  | h2dReady l =>
    have hnr : ¬ (s.recv.ready < s.recv.issued) := by omega
    simp [step, h2dReady, Recv.step, Recv.h2dReady, hnr] at hs
  | reseatDecodeStaging => exact absurd rfl hne
  | _ =>
    (try (rename_i e; cases e)) <;> (try (rename_i ok; cases ok)) <;> pipe_cases hs <;>
    first | (obtain ⟨_, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩) | (cases hs <;> exact ⟨rfl, rfl⟩) | cases hs

/-- Once the receive outcome has been published (`done_recving` or
`failed_recving`), no subsequent transition can modify `decodeHbm`. Proved from
`DecodeHbmSafe`: publication implies `retired = issued`, which forces
`ready = issued` and disables `h2dReady`. -/
theorem decodeHbm_quiet {s s' : Pipeline} {e : Ev} (h : Inv s)
    (hp : s.recv.published ≠ none) (hs : step s e = some s') :
    s'.decodeHbm = s.decodeHbm := by
  have ⟨_, hret⟩ := (inv_safe h).2.1 hp
  have hr := h.recv.retired_le
  have hy := h.recv.ready_le
  cases e with
  | h2dReady l =>
    have hnr : ¬ (s.recv.ready < s.recv.issued) := by omega
    simp [step, h2dReady, Recv.step, Recv.h2dReady, hnr] at hs
  | _ =>
    (try (rename_i e; cases e)) <;> (try (rename_i ok; cases ok)) <;> pipe_cases hs <;>
    first | (obtain ⟨_, _, rfl⟩ := hs; rfl) | (cases hs <;> rfl) | cases hs

theorem runFrom_decodeHbm_quiet {n : Nat} :
    ∀ (evs : List Ev) {s s' : Pipeline}, Inv s → s.recv.published ≠ none →
      (sys n).runFrom s evs = some s' → s'.decodeHbm = s.decodeHbm
  | [], _, _, _, _, hr => by simp [System.runFrom] at hr; exact hr ▸ rfl
  | e :: evs, s, s', hinv, hp, hr => by
    simp only [System.runFrom, sys, List.foldlM_cons] at hr
    cases hse : step s e with
    | none => simp [hse] at hr
    | some s₁ =>
      simp only [hse] at hr
      rw [@runFrom_decodeHbm_quiet n evs _ _ (step_inv hinv hse) (step_published_ne_none hse hp) hr]
      exact decodeHbm_quiet hinv hp hse

/-- Once the engine has been told `done_recving`, decode HBM holds the KV
cache from then on: nothing in the rest of the run disturbs it. Proved by
combining `PublicationCorrect` with `runFrom_decodeHbm_quiet` (from
`DecodeHbmSafe`). -/
theorem attention_safe {n : Nat} {s s' : Pipeline} (h : (sys n).Reachable s)
    (hp : s.recv.published = some true) (evs : List Ev)
    (hr : (sys n).runFrom s evs = some s') : s'.decodeHbm = good n := by
  have hinv := reachable_inv h
  rw [runFrom_decodeHbm_quiet evs hinv (by simp [hp]) hr, ← numLayers_eq h]
  exact (inv_safe hinv).1 hp

/-! ## System properties across requests

Multiple requests $R_0, R_1, R_2, \dots$ share the four memory pools (`prefillHbm`,
`prefillStaging`, `decodeStaging`, `decodeHbm`). When the active request has
returned all four pools (`PoolsReleased`), `.nextRequest` moves it to `retired`
and hands the pools to the next request (`init n`). Retired requests can still
take any non-reseat transition (`retiredStep`); if a retired request ever
modifies any of the four shared pools, `multiStep` overwrites `active`'s pools
with `.junk`.

The two top-level system theorems below use all of the single-request properties
(`PublicationCorrect`, `DecodeHbmSafe`, `PrefillHbmSafe`, `StagingSafe`,
`NoOpLeak`, `reachable_can_settle`) as intermediate steps:
1. `system_data_correct` and `system_attention_safe`: across any sequence of
   requests, whenever the active request publishes `done_recving`, `decodeHbm`
   holds `good n` and remains `good n` across all subsequent transitions of both
   `active` and `retired` until `.nextRequest`.
2. `system_progress`: from any reachable multi-request state, a finite trace
   settles the active transfer, publishes its outcomes, releases all four shared
   memory pools (`PoolsReleased`), and enables `.nextRequest`. -/

/-- All four shared memory pools have been returned by this transfer:
prefill HBM is reclaimed, both host staging buffers are released, and the
receive outcome has been published. -/
def PoolsReleased (s : Pipeline) : Prop :=
  s.reclaimed = true ∧
  s.send.life.hasStaging = false ∧
  s.recv.life.hasStaging = false ∧
  s.recv.published ≠ none

instance (s : Pipeline) : Decidable (PoolsReleased s) :=
  inferInstanceAs (Decidable (_ ∧ _ ∧ _ ∧ _))

theorem step_poolsReleased {s s' : Pipeline} {e : Ev} (h : Inv s)
    (hp : PoolsReleased s) (hs : step s e = some s') : PoolsReleased s' := by
  have h' := step_inv h hs
  have hdS : s'.send.life.done = true :=
    step_send_done_mono hs (h.send.life.done_of_released hp.2.1)
  have hdR : s'.recv.life.done = true :=
    step_recv_done_mono hs (h.recv.life.done_of_released hp.2.2.1)
  exact ⟨step_reclaimed_mono hs hp.1,
    by rw [h'.send.life.staging, hdS]; rfl,
    by rw [h'.recv.life.staging, hdR]; rfl,
    step_published_ne_none hs hp.2.2.2⟩

/-- Once a transfer has released all four pools (`PoolsReleased`), no subsequent
transition of that transfer can ever modify any memory. Proved by combining
`prefillHbm_quiet`, `prefillStaging_quiet`, `decodeStaging_quiet`, and
`decodeHbm_quiet`. -/
theorem released_quiet {r r' : Pipeline} {e : Ev} (h : Inv r) (hp : PoolsReleased r)
    (hne₁ : e ≠ .reseatPrefillStaging) (hne₂ : e ≠ .reseatDecodeStaging)
    (hs : step r e = some r') :
    r'.prefillHbm = r.prefillHbm ∧
    r'.prefillStaging = r.prefillStaging ∧
    r'.wire = r.wire ∧
    r'.decodeStaging = r.decodeStaging ∧
    r'.decodeHbm = r.decodeHbm :=
  ⟨prefillHbm_quiet_step h hp.1 hs,
   (prefillStaging_quiet h hp.2.1 hne₁ hs).1,
   (prefillStaging_quiet h hp.2.1 hne₁ hs).2,
   (decodeStaging_quiet h hp.2.2.1 hne₂ hs).1,
   decodeHbm_quiet h hp.2.2.2 hs⟩

/-- Multi-request system state: a list of prior requests that have released the
shared pools (`retired`) and the currently active request holding the shared
pools (`active`). -/
structure MultiState where
  numLayers : Nat
  retired : List Pipeline
  active : Pipeline
  deriving Repr, DecidableEq

inductive MultiEv where
  /-- The currently active request takes a pipeline transition. -/
  | activeStep (e : Ev)
  /-- A prior request `idx` (which already handed off the shared pools) takes a
  transition. -/
  | retiredStep (idx : Nat) (e : Ev)
  /-- Once the active request has released all four shared pools
  (`PoolsReleased`), move it to `retired` and allocate the shared pools to the
  next request. -/
  | nextRequest
  deriving Repr, DecidableEq

def multiInit (n : Nat) : MultiState :=
  { numLayers := n, retired := [], active := init n }

def multiStep (ms : MultiState) : MultiEv → Option MultiState
  | .activeStep e =>
    (step ms.active e).map fun a' => { ms with active := a' }
  | .retiredStep idx e =>
    if e = .reseatPrefillStaging ∨ e = .reseatDecodeStaging then none
    else
      match ms.retired[idx]? with
      | none => none
      | some r =>
        (step r e).map fun r' =>
          -- If a retired request ever modifies any of the four shared pools,
          -- it corrupts the active request's memories.
          let interfered : Bool :=
            r'.prefillHbm != r.prefillHbm ||
            r'.prefillStaging != r.prefillStaging ||
            r'.decodeStaging != r.decodeStaging ||
            r'.decodeHbm != r.decodeHbm
          let active' :=
            if interfered then
              { ms.active with
                prefillHbm := List.replicate ms.numLayers .junk,
                prefillStaging := List.replicate ms.numLayers .junk,
                decodeStaging := List.replicate ms.numLayers .junk,
                decodeHbm := List.replicate ms.numLayers .junk }
            else ms.active
          { ms with retired := ms.retired.set idx r', active := active' }
  | .nextRequest =>
    if PoolsReleased ms.active then
      some { ms with retired := ms.active :: ms.retired, active := init ms.numLayers }
    else none

def multiSys (n : Nat) : System MultiState MultiEv := ⟨multiInit n, multiStep⟩

structure MultiInv (n : Nat) (ms : MultiState) : Prop where
  n_eq : ms.numLayers = n
  active_inv : Inv ms.active
  active_n : ms.active.numLayers = n
  retired_inv : ∀ r ∈ ms.retired, Inv r ∧ PoolsReleased r

theorem multiInv_init (n : Nat) : MultiInv n (multiInit n) :=
  ⟨rfl, inv_init n, rfl, by intro _ h; cases h⟩

theorem mem_set_cases {α : Type} {l : List α} {i : Nat} {x y : α}
    (h : y ∈ l.set i x) : y = x ∨ y ∈ l := by
  induction l generalizing i with
  | nil => simp at h
  | cons a as ih =>
    cases i with
    | zero =>
      simp only [List.set_cons_zero, List.mem_cons] at h
      rcases h with rfl | h
      · exact Or.inl rfl
      · exact Or.inr (List.mem_cons_of_mem a h)
    | succ i =>
      simp only [List.set_cons_succ, List.mem_cons] at h
      rcases h with rfl | h
      · exact Or.inr List.mem_cons_self
      · rcases ih h with rfl | h
        · exact Or.inl rfl
        · exact Or.inr (List.mem_cons_of_mem a h)

theorem getElem?_mem {α : Type} {l : List α} {i : Nat} {x : α}
    (h : l[i]? = some x) : x ∈ l := by
  induction l generalizing i with
  | nil => simp at h
  | cons a as ih =>
    cases i with
    | zero =>
      simp only [List.getElem?_cons_zero, Option.some.injEq] at h
      subst h; exact List.mem_cons_self
    | succ i =>
      simp only [List.getElem?_cons_succ] at h
      exact List.mem_cons_of_mem a (ih h)

/-- Key non-interference lemma: a `retiredStep` never interferes with `active`
because `released_quiet` guarantees that every retired request is quiet on all
four shared memory pools. -/
theorem retiredStep_no_interference {n : Nat} {ms ms' : MultiState} {idx : Nat} {e : Ev}
    (hinv : MultiInv n ms) (hs : multiStep ms (.retiredStep idx e) = some ms') :
    ms'.active = ms.active ∧ MultiInv n ms' := by
  simp only [multiStep] at hs
  split at hs
  · cases hs
  · rename_i hne
    have hne₁ : e ≠ .reseatPrefillStaging := fun h => hne (Or.inl h)
    have hne₂ : e ≠ .reseatDecodeStaging := fun h => hne (Or.inr h)
    cases hget : ms.retired[idx]? with
    | none => simp [hget] at hs
    | some r =>
      simp only [hget, Option.map_eq_some_iff] at hs
      obtain ⟨r', hr', rfl⟩ := hs
      have ⟨hr_inv, hr_rel⟩ := hinv.retired_inv r (getElem?_mem hget)
      have ⟨hq₁, hq₂, _, hq₃, hq₄⟩ := released_quiet hr_inv hr_rel hne₁ hne₂ hr'
      have hint : (r'.prefillHbm != r.prefillHbm || r'.prefillStaging != r.prefillStaging ||
          r'.decodeStaging != r.decodeStaging || r'.decodeHbm != r.decodeHbm) = false := by
        simp [hq₁, hq₂, hq₃, hq₄]
      refine ⟨by simp [hint], ⟨hinv.n_eq, by simp [hint, hinv.active_inv],
        by simp [hint, hinv.active_n], ?_⟩⟩
      intro x hx
      rcases mem_set_cases hx with rfl | hx
      · exact ⟨step_inv hr_inv hr', step_poolsReleased hr_inv hr_rel hr'⟩
      · exact hinv.retired_inv x hx

theorem multiStep_inv {n : Nat} {ms ms' : MultiState} {ev : MultiEv}
    (h : MultiInv n ms) (hs : multiStep ms ev = some ms') : MultiInv n ms' := by
  cases ev with
  | activeStep e =>
    simp only [multiStep, Option.map_eq_some_iff] at hs
    obtain ⟨a', ha', rfl⟩ := hs
    exact ⟨h.n_eq, step_inv h.active_inv ha',
      (step_numLayers ha').trans h.active_n, h.retired_inv⟩
  | retiredStep idx e =>
    exact (retiredStep_no_interference h hs).2
  | nextRequest =>
    simp only [multiStep] at hs
    split at hs
    · rename_i hrel
      cases hs
      refine ⟨h.n_eq, h.n_eq ▸ inv_init n, h.n_eq, ?_⟩
      intro r hr
      rcases List.mem_cons.mp hr with rfl | hr
      · exact ⟨h.active_inv, hrel⟩
      · exact h.retired_inv r hr
    · cases hs

theorem reachable_multiInv {n : Nat} {ms : MultiState}
    (h : (multiSys n).Reachable ms) : MultiInv n ms :=
  (multiSys n).reachable_induction (multiInv_init n) (fun _ _ _ hi hs => multiStep_inv hi hs) h

/-- **System Property 1a (Data correctness at publication across requests):**
In any reachable multi-request state — after any number of prior requests have
run, succeeded, failed, or been cancelled — whenever the active request
publishes `done_recving`, `decodeHbm` holds its KV cache `good n`. -/
theorem system_data_correct {n : Nat} {ms : MultiState}
    (h : (multiSys n).Reachable ms)
    (hp : ms.active.recv.published = some true) :
    ms.active.decodeHbm = good n := by
  have hinv := reachable_multiInv h
  rw [← hinv.active_n]
  exact (inv_safe hinv.active_inv).1 hp

theorem multiRunFrom_decodeHbm_quiet {n : Nat} :
    ∀ (evs : List MultiEv) {ms ms' : MultiState},
      MultiInv n ms → ms.active.recv.published ≠ none →
      (∀ ev ∈ evs, ev ≠ .nextRequest) →
      (multiSys n).runFrom ms evs = some ms' →
      ms'.active.decodeHbm = ms.active.decodeHbm
  | [], _, _, _, _, _, hr => by simp [System.runFrom] at hr; exact hr ▸ rfl
  | ev :: evs, ms, ms', hinv, hp, hno, hr => by
    simp only [System.runFrom, multiSys, List.foldlM_cons] at hr
    cases hse : multiStep ms ev with
    | none => simp [hse] at hr
    | some ms₁ =>
      simp only [hse] at hr
      have hno_head : ev ≠ .nextRequest := hno ev List.mem_cons_self
      have hno_tail : ∀ e ∈ evs, e ≠ .nextRequest :=
        fun e he => hno e (List.mem_cons_of_mem ev he)
      have ⟨hd_eq, hp₁⟩ : ms₁.active.decodeHbm = ms.active.decodeHbm ∧
          ms₁.active.recv.published ≠ none := by
        cases ev with
        | nextRequest => exact absurd rfl hno_head
        | activeStep e =>
          simp only [multiStep, Option.map_eq_some_iff] at hse
          obtain ⟨a', ha', rfl⟩ := hse
          exact ⟨decodeHbm_quiet hinv.active_inv hp ha',
            step_published_ne_none ha' hp⟩
        | retiredStep idx e =>
          have hact := (retiredStep_no_interference hinv hse).1
          rw [hact]; exact ⟨rfl, hp⟩
      rw [@multiRunFrom_decodeHbm_quiet n evs _ _ (multiStep_inv hinv hse) hp₁ hno_tail hr, hd_eq]

/-- **System Property 1b (Attention safety across requests):**
Once the active request publishes `done_recving`, `decodeHbm` stays equal to
`good n` across any subsequent sequence of active and retired-request
transitions before `.nextRequest`. -/
theorem system_attention_safe {n : Nat} {ms ms' : MultiState}
    (h : (multiSys n).Reachable ms)
    (hp : ms.active.recv.published = some true)
    (evs : List MultiEv) (hno : ∀ ev ∈ evs, ev ≠ .nextRequest)
    (hr : (multiSys n).runFrom ms evs = some ms') :
    ms'.active.decodeHbm = good n := by
  have hinv := reachable_multiInv h
  rw [multiRunFrom_decodeHbm_quiet evs hinv (by simp [hp]) hno hr]
  exact system_data_correct h hp

theorem runFrom_activeSteps {n : Nat} :
    ∀ (evs : List Ev) {ms : MultiState} {a' : Pipeline},
      (sys n).runFrom ms.active evs = some a' →
      (multiSys n).runFrom ms (evs.map .activeStep) = some { ms with active := a' }
  | [], ms, a', hr => by
    simp [System.runFrom] at hr; subst hr; rfl
  | e :: evs, ms, a', hr => by
    simp only [System.runFrom, sys, multiSys, List.map_cons, List.foldlM_cons] at hr ⊢
    cases hse : step ms.active e with
    | none => simp [hse] at hr
    | some a₁ =>
      simp only [hse, multiStep, Option.map_some] at hr ⊢
      exact @runFrom_activeSteps n evs _ _ hr

/-- From any pipeline state satisfying `Inv`, a finite trace settles both
sessions, publishes both outcomes, and releases all four shared pools
(`PoolsReleased`). -/
theorem inv_can_release_pools (n : Nat) {s : Pipeline} (hinv : Inv s) :
    ∃ evs s', (sys n).runFrom s evs = some s' ∧ PoolsReleased s' := by
  have hcS : step s (.send .cancel) = some { s with send := s.send.finish false } := rfl
  let s₁ : Pipeline := { s with send := s.send.finish false }
  have hinv₁ : Inv s₁ := step_inv hinv hcS
  have hcR : step s₁ (.recv .cancel) =
      some { s₁ with recv := { s₁.recv with life := s₁.recv.life.finishLocked false } } := rfl
  let s₂ : Pipeline := { s₁ with recv := { s₁.recv with life := s₁.recv.life.finishLocked false } }
  have hinv₂ : Inv s₂ := step_inv hinv₁ hcR
  have hdrS₂ : s₂.send.life.draining = true := by
    show (s.send.finish false).life.draining = true
    rcases Send.finish_cases false hinv.send.life with ⟨hd, heq⟩ | ⟨hd, _, heq⟩ <;> simp [heq, hd]
  have hdrR₂ : s₂.recv.life.draining = true := by simp [s₂]
  obtain ⟨evs_d, s_d, hrd, hdS, hstS, hdR, hstR⟩ :=
    draining_can_settle_aux n (drainRank s₂) (Nat.le_refl _) hinv₂ hdrS₂ hdrR₂
  obtain ⟨evs_f, s', hrf, _, hstS', _, hstR', _, hpubR', hrec'⟩ :=
    settled_can_finalize n hdS hstS hdR hstR
  have hr_cancel : (sys n).runFrom s [.send .cancel, .recv .cancel] = some s₂ := by
    simp [System.runFrom, sys, hcS, hcR, s₁, s₂]
  exact ⟨[.send .cancel, .recv .cancel] ++ evs_d ++ evs_f, s',
    runFrom_append _ evs_f (runFrom_append _ evs_d hr_cancel hrd) hrf,
    hrec', hstS', hstR', hpubR'⟩

/-- **System Property 2 (Progress across requests):**
From any reachable multi-request state, there exists a finite trace `evs` that
settles the active transfer, releases all four shared memory pools
(`PoolsReleased ms'.active`), and enables `.nextRequest` so the next request can
acquire the pools and run. -/
theorem system_progress {n : Nat} {ms : MultiState}
    (h : (multiSys n).Reachable ms) :
    ∃ evs ms', (multiSys n).runFrom ms evs = some ms' ∧
      PoolsReleased ms'.active ∧
      (multiStep ms' .nextRequest).isSome = true := by
  have hinv := reachable_multiInv h
  obtain ⟨evs, a', hr, hrel⟩ := inv_can_release_pools n hinv.active_inv
  refine ⟨evs.map .activeStep, { ms with active := a' },
    runFrom_activeSteps evs hr, hrel, ?_⟩
  simp [multiStep, hrel]

/-! ## Replay and bounded search

Concrete traces, checked by `decide`, that document the behaviours the model
admits — in particular layers completing out of order at every stage; bounded
searches on the one-layer instance; and mutants that show the memory model is
sensitive to the guards the proof rests on, including the per-layer ones. -/

/-- A one-layer producer, start to `done_sending`. -/
def producer : List Ev :=
  [.send .start, .send .d2hBegin, .send (.d2hIssue true), .d2hReady 0, .send .d2hEnd,
   .send (.wake true), .send .h2hIssue, .send .sendNext, .h2hDone 0 true, .send .publish]

/-- A one-layer consumer, pull handshake to `done_recving`. Within the accepted
push, `HandleCustomRequest` (`bt.cc:350-586`) lands the chunk, dispatches
`OnLayerReceived` (`h2dBegin` / `h2dIssue`) and accounts for the chunk
(`netAccount`) before returning (`pushEnd`). -/
def consumer : List Ev :=
  [.recv (.pullReply true), .recv .pushBegin, .land 0, .h2dBegin 0,
   .h2dIssue 0 true, .recv .netAccount, .recv .pushEnd, .h2dReady 0,
   .recv (.h2dDone true), .recv .publish]

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
   .recv .pushBegin, .land 1, .h2dBegin 1, .h2dIssue 1 true, .recv .netAccount, .recv .pushEnd,
   .recv .pushBegin, .land 0, .h2dBegin 0, .h2dIssue 0 true, .recv .netAccount, .recv .pushEnd,
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

/-- An H2D copy cannot finish for a layer whose `ExecuteLayerH2d` was aborted at
the re-check (`h2dIssue l false` or draining), even if another layer's copy was
issued. -/
theorem trace_aborted_issue_cannot_ready :
    (sys 2).run
      (producer2 ++
       [.recv (.pullReply true),
        .recv .pushBegin, .land 0, .h2dBegin 0, .h2dIssue 0 true, .recv .netAccount, .recv .pushEnd,
        .recv .pushBegin, .land 1, .h2dBegin 1, .h2dIssue 1 false, .recv .netAccount, .recv .pushEnd,
        .h2dReady 1]) = none := by
  decide

/-- Multi-request trace: request $R_0$ starts, cancels mid-flight, drains,
publishes failed outcomes, and releases all four shared memory pools;
`.nextRequest` hands the pools to request $R_1$, which completes a full transfer
and publishes `done_recving` with `decodeHbm = [.kv 0]`. -/
theorem trace_multi_request :
    ((multiSys 1).run
      (([.send .start, .send .d2hBegin, .send .cancel, .recv .cancel,
         .send (.d2hIssue true), .d2hReady 0, .send .d2hEnd,
         .recv (.pullReply true), .send .publish, .recv .publish, .reclaim].map
        MultiEv.activeStep) ++
       [.nextRequest] ++
       ((producer ++ consumer).map MultiEv.activeStep))).map
      (fun ms => (ms.retired.length, ms.active.recv.published, ms.active.decodeHbm)) =
    some (1, some true, [.kv 0]) := by
  decide

/-- Every event, for an `n`-layer instance. The five session events that the
pipeline replaces with layer-indexed ones are left out (they are disabled). -/
def events (n : Nat) : List Ev :=
  (Send.events.filter fun e => e != .d2hReady && e != .h2hDone true && e != .h2hDone false).map .send ++
    (Recv.events.filter fun e =>
      e != .h2dBegin && e != .h2dIssue true && e != .h2dIssue false && e != .h2dReady).map .recv ++
    (List.range n).flatMap (fun l =>
      [.d2hReady l, .h2hDone l true, .h2hDone l false,
       .h2dBegin l, .h2dIssue l true, .h2dIssue l false, .h2dReady l, .land l]) ++
    [.reclaim, .reseatPrefillStaging, .reseatDecodeStaging]

/-- Executable negation of `Safe`. -/
def violates (s : Pipeline) : Bool :=
  (s.recv.published == some true && s.decodeHbm != good s.numLayers) ||
  (s.recv.published != none && (s.recv.pending != 0 || s.recv.retired != s.recv.issued)) ||
  (s.reclaimed && (s.send.d2hPending || s.send.d2hRetired != s.send.d2hIssued)) ||
  (!s.send.life.hasStaging &&
    (s.send.d2hPending || s.send.d2hRetired != s.send.d2hIssued ||
     s.send.h2hRetired != s.send.h2hIssued)) ||
  (!s.recv.life.hasStaging &&
    (s.recv.pushes != 0 || s.recv.pending != 0 || s.recv.retired != s.recv.issued)) ||
  ((0 < s.send.life.inFlight || 0 < s.recv.life.inFlight) &&
    !((drainEvents s.numLayers).any fun e => (step s e).isSome))

#guard ModelCheck.check (sys 1) (events 1) violates 10 = .outOfFuel

/-- Publication needs more events than the search above reaches, so search
again from the state the producer leaves behind: every consumer interleaving
with reclaim, staging reuse, cancellation and so on is within reach. -/
def afterProducer : Pipeline := ((sys 1).run producer).getD (init 1)

-- Fuel 10 is the least that reaches publication from here (ten consumer
-- events). This is the slowest guard in the project (~7 s); do not lower it.
#guard ModelCheck.check ⟨afterProducer, step⟩ (events 1) violates 10 = .outOfFuel

/-- Two layers, from the out-of-order producer: explores the initial consumer
landing and dispatch steps (`fuel = 5`, traces of up to 5 events) alongside
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
      { s with recv := rcv,
               claimedL := s.claimedL.set l true,
               h2dPendingL := s.h2dPendingL.set l true }
  else none

def sysDispatchEarly : System Pipeline Ev :=
  ⟨init 1, fun s e => match e with
    | .h2dBegin l => s.dispatchEarly l
    | e => step s e⟩

theorem trace_dispatch_early :
    (sysDispatchEarly.run
      [.recv (.pullReply true), .h2dBegin 0, .h2dIssue 0 true, .h2dReady 0,
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
  if s.h2dIssuedL[l]? = some true ∧ s.h2dReadyL[l]? = some false then
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
        .recv .pushBegin, .land 1, .h2dBegin 1, .h2dIssue 1 true,
        .recv .netAccount, .recv .pushEnd, .h2dReady 1,
        .recv .pushBegin, .land 0, .h2dBegin 0, .h2dIssue 0 true,
        .recv .netAccount, .recv .pushEnd, .h2dReady 0,
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
       .recv (.pullReply true), .recv .pushBegin, .land 0, .h2dBegin 0,
       .h2dIssue 0 true, .recv .pushEnd, .h2dReady 0, .recv (.h2dDone true), .recv .publish]).map
      (fun s => (s.send.life.done, s.recv.published, s.decodeHbm)) =
    some (false, some true, [.junk]) := by
  decide

end Pipeline

end TpuSyncVerify.Transfer.PrefillDecode
