import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.Session

/-!
# Send session

Stage 3 of the prefill-to-decode model: one `TransferSendSession` on the
prefill (producer) side and the slice of `KVCacheManagerWithTransfer` that
drives it. The sender stages each layer's device blocks into host staging
(D2H), pushes the staging to the consumer (H2H) layer by layer, and must not
let the engine reuse the device blocks, or the allocator reseat the staging,
while any copy or push is still running. Memory contents come in stage 4.

Citations are to tpu-sync `01ffa3d`. Unqualified `.h`/`.cc` are
`tpu_sync/core/transfer_send_session.{h,cc}`; `mgr.cc` is
`tpu_sync/core/kv_cache_manager_with_transfer.cc`.

## How a send runs

`StartPush` (`.cc:268-364`) runs once on a worker thread spawned by the
consumer's pull request (`mgr.cc:1497-1507`). It acquires staging
(`.cc:286-291`), then issues one D2H copy per layer in a loop (`.cc:324-361`),
each counted in `in_flight_` from before its dispatch until its future's
`OnReady` ends the op (`.cc:357-360`). After the loop it calls
`SendNextLayer(0)` (`.cc:363`).

`SendNextLayer(l)` (`.cc:366-452`) takes an op (`.cc:375-382`) and waits on
layer `l`'s D2H future. When it is ready (`.cc:384-406`) the layer is handed to
the push pool, whose task (`.cc:406-450`) takes a second op for the H2H push,
issues it, calls `SendNextLayer(l+1)`, and only then releases the first op.
The push's callback (`.cc:428-445`) releases the second op and, when the last
layer's push completes, finishes the session OK (`.cc:440-444`).

So two chains run against the same `in_flight_`: the D2H copies, all issued up
front, and the pushes, strictly one layer after another. The session settles
when both have drained after a `Finish`.

## State

The settle protocol is `Transfer.Lifecycle`. On top of it:

| Field        | C++                                             | Role |
|--------------|-------------------------------------------------|------|
| `numLayers`  | `base_->num_layers()`                           | fixed |
| `started`    | `StartPush` passed its locked section (`.cc:295-313`) | staging acquired, copies may start |
| `d2hPending` | ghost                                           | the D2H loop is between `++in_flight_` (`.cc:330`) and the dispatch's outcome |
| `d2hIssued`  | `d2h_layer_futures_.size()` (`.h:186`)          | copies handed to the device |
| `d2hReady`   | futures with `IsReady()`                        | copies finished |
| `d2hRetired` | ghost                                           | copies whose `OnReady` at `.cc:357-360` has ended their op |
| `queued`     | ghost                                           | `SendNextLayer(l)` calls that took their op (`.cc:381`) |
| `woken`      | ghost                                           | of those, the future callback (`.cc:384`) has run |
| `pooled`     | ghost                                           | layers scheduled on `push_pool` (`.cc:406`) whose task has not run |
| `h2hIssued`  | ghost                                           | pushes handed to the transport (`.cc:424`) |
| `chaining`   | ghost                                           | pool tasks that issued their push and still hold the `SendNextLayer` op (`.cc:424-449`) |
| `h2hRetired` | ghost                                           | push callbacks that have run (`.cc:428`) |
| `h2hOk`      | `num_layers - remaining_h2h_layers_` (`.h:190`) | pushes that completed OK |
| `published`  | membership in `done_sending_` / `failed_recving_` (`mgr.cc:920`) | what `poll_stats()` shows the engine |
| `underflow`  | —                                               | `EndSendOpLocked` ran with `in_flight_ == 0` |

Ghost fields record where each unit of `in_flight_` came from, which is what
`Accounted` is about. `underflow` exists because `EndSendOpLocked`
(`.cc:188-194`) decrements without a guard; the model records the event
instead of silently saturating so that `NoUnderflow` is a theorem.

## Events

| Event          | C++ |
|----------------|-----|
| `start`        | `StartPush` from the acquisition (`.cc:286-291`) through its locked section (`.cc:295-313`): a zero-layer send finishes OK at once (`.cc:300-303`) |
| `d2hBegin`     | one iteration of the D2H loop up to `++in_flight_` (`.cc:325-331`) |
| `d2hIssue ok`  | the dispatch (`.cc:332-341`): failure finishes the session and ends the op (`.cc:342-350`); success records the future (`.cc:352-356`). For the last layer, `SendNextLayer(0)` (`.cc:363`, `.cc:375-382`) is attempted as part of the event |
| `d2hDone`      | the device finishes a copy: its future becomes `IsReady()` |
| `d2hEnd`       | the copy's `OnReady` at `.cc:357-360` ends its op |
| `wake ok`      | `SendNextLayer`'s future callback (`.cc:384-406`): a failed copy finishes the session (`.cc:391-396`); a draining session drops the layer (`.cc:397-403`); otherwise the layer is scheduled on the push pool and the op is carried over (`.cc:405-406`) |
| `h2hIssue`     | the pool task up to the push (`.cc:407-424`): a draining session drops the layer and ends the op (`.cc:411-416`); otherwise a second op is taken (`.cc:420`) and the push issued |
| `sendNext`     | the pool task's `SendNextLayer(l+1)` (`.cc:449`, `.cc:369-382`) followed by the release of the carried-over op (`.cc:407`) |
| `h2hDone ok`   | the push callback (`.cc:428-445`): failure finishes the session (`.cc:429-434`); the last OK push finishes it OK (`.cc:440-444`); the op ends either way |
| `cancel`       | any `Finish(error)` from outside the data path: deadline (`mgr.cc:911-917`), shutdown (`mgr.cc:331-337`), staging acquisition failure (`.cc:288-291`), bad arguments (`.cc:280-285`), pull-worker exceptions (`mgr.cc:1500-1505`) |
| `publish`      | `CompleteReadRaw` moves a settled session into `done_sending_` or `failed_recving_` by its status and drops it (`mgr.cc:918-925`) |

## Assumptions

* **A1 (one `StartPush`).** `ValidateAndBeginPull` rejects a second pull
  (`.cc:125-129`), so `StartPush` runs at most once; `start` is enabled once.
* **A2 (sequential loop).** The D2H loop is one thread, so at most one
  dispatch is between its `++in_flight_` and its outcome: `d2hPending` is a
  `Bool`.
* **A3 (layers are interchangeable).** The model counts copies and pushes
  rather than naming layers. Futures are consumed in issue order
  (`wake` needs `woken < d2hReady`); since no event's effect on the counters
  depends on which layer it is, any real interleaving maps onto one the model
  admits.
* **A4 (no double end).** Each op ends once: every op-ending event is guarded
  by the ghost counter that opened it.
* **A5 (no consumer Ack).** `HandleAck → AckSend → Finish()` (`mgr.cc:1529-1532,
  1595-1606`) would finish a send OK from outside. No code in the repository at
  `01ffa3d` sends an Ack (`SendAck` has only test callers), so it is not an
  event. With it, `Publication` below would read "the consumer acked", not
  "every layer was pushed".
* **A6 (fold of `SendNextLayer(0)`).** Between recording the last future
  (`.cc:355`) and `SendNextLayer(0)`'s lock (`.cc:375`) only a `Finish` can
  change the outcome of the attempt, and it has the same effect ordered before
  the event; the two are one event.

## Properties

All proved on every reachable state (`reachable_safe`):

* **Settle safety.** `done → inFlight = 0`.
* **Drained.** `done →` no copy is pending or unretired, no `SendNextLayer`
  callback, pool task or push is outstanding. In particular no D2H copy still
  reads the device blocks (so the engine may reuse them) or writes the staging,
  and no push still reads the staging (so the allocator may reseat it). This is
  what the comments at `.h:179-180` and `mgr.cc:912-916` promise.
* **Staging integrity.** `hasStaging = !done`: staging, once acquired, is held
  exactly until the session settles.
* **Prompt settle.** `draining → inFlight = 0 → done`.
* **No underflow.** `EndSendOpLocked` never runs on an idle session.
* **Publication.** `published = some true → h2hOk = numLayers`: when the
  engine is told `done_sending`, every layer's push completed OK. Counter-level
  form of the proposal's *publication correctness* for the producer.
* **Counters.** The two chains are ordered:
  `d2hRetired ≤ d2hReady ≤ d2hIssued ≤ numLayers`,
  `woken ≤ queued ≤ d2hIssued`, `woken ≤ d2hReady`,
  `pooled + h2hIssued ≤ woken`, `h2hOk ≤ h2hRetired ≤ h2hIssued`.

Correspondence notes. (1) The sender's `FinishLocked` ignores every call after
the first (`Lifecycle.finishOnceLocked`), unlike the receiver's. An OK finish
happens inside the last push callback while D2H `OnReady`s may still be
outstanding, so a shutdown or deadline in that window leaves the status OK
(`trace_cancel_after_ok_finish`); harmless, since the send did complete.
(2) A failed send is reported in `failed_recving_` (`mgr.cc:920`), there is no
`failed_sending_`. (3) The D2H loop's `if (draining_) return;` (`.cc:329`)
also skips `SendNextLayer(0)`, which is fine because every later
`SendNextLayer` re-checks `draining_`.
-/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)

structure Send where
  numLayers : Nat
  life : Lifecycle := {}
  started : Bool := false
  d2hPending : Bool := false
  d2hIssued : Nat := 0
  d2hReady : Nat := 0
  d2hRetired : Nat := 0
  queued : Nat := 0
  woken : Nat := 0
  pooled : Nat := 0
  h2hIssued : Nat := 0
  chaining : Nat := 0
  h2hRetired : Nat := 0
  h2hOk : Nat := 0
  published : Option Bool := none
  underflow : Bool := false
  deriving Repr, DecidableEq

namespace Send

/-- A registered send (`NotifyForRead`, `mgr.cc:432-452`) that nobody has
pulled yet. -/
def init (numLayers : Nat) : Send := { numLayers }

/-- `EndSendOpLocked` (`.cc:188-194`): `--in_flight_` and settle. The C++ has
no underflow check; the model records one instead of ignoring it. -/
def endOp (s : Send) : Send :=
  if s.life.inFlight = 0 then { s with underflow := true }
  else { s with life := s.life.endOpLocked }

/-- `Finish(status)` / `FinishLocked(status)` (`.cc:167-180`). -/
def finish (ok : Bool) (s : Send) : Send := { s with life := s.life.finishOnceLocked ok }

/-- `SendNextLayer(l)` up to its lock (`.cc:369-382`) for `l = queued`: takes an
op unless the session is draining or layer `l`'s copy was never issued. -/
def trySendNext (s : Send) : Send :=
  if s.queued < s.d2hIssued then
    match s.life.beginOp with
    | some l => { s with life := l, queued := s.queued + 1 }
    | none => s
  else s

inductive Ev where
  | start
  | d2hBegin
  | d2hIssue (ok : Bool)
  | d2hDone
  | d2hEnd
  | wake (ok : Bool)
  | h2hIssue
  | sendNext
  | h2hDone (ok : Bool)
  | cancel
  | publish
  deriving Repr, DecidableEq

/-- `StartPush` with staging acquired. A failed acquisition is `Finish(error)`
with nothing in flight, i.e. `cancel`. On a session that finished meanwhile
the call returns (`.cc:297-299`) and nothing changes. -/
def start (s : Send) : Option Send :=
  if s.started = true ∨ s.life.draining = true ∨ s.life.done = true then none
  else if s.numLayers = 0 then some (s.finish true)
  else some { s with started := true }

/-- One iteration of the D2H loop up to `++in_flight_` (`.cc:325-331`). -/
def d2hBegin (s : Send) : Option Send :=
  if s.started = true ∧ s.d2hPending = false ∧ s.d2hIssued < s.numLayers then
    s.life.beginOp.map fun l => { s with life := l, d2hPending := true }
  else none

/-- The dispatch's outcome. Failure: `FinishLocked(status); EndSendOpLocked()`
(`.cc:347-349`). Success: the future is recorded (`.cc:355`), and after the
last layer `SendNextLayer(0)` is attempted (`.cc:363`, A6). -/
def d2hIssue (ok : Bool) (s : Send) : Option Send :=
  if s.d2hPending = false then none
  else
    let s := { s with d2hPending := false }
    if ok then
      let s := { s with d2hIssued := s.d2hIssued + 1 }
      some (if s.d2hIssued = s.numLayers then s.trySendNext else s)
    else some (s.finish false).endOp

/-- A dispatched copy finishes on the device. -/
def d2hDone (s : Send) : Option Send :=
  if s.d2hReady < s.d2hIssued then some { s with d2hReady := s.d2hReady + 1 } else none

/-- The copy's `OnReady` at `.cc:357-360` ends its op. -/
def d2hEnd (s : Send) : Option Send :=
  if s.d2hRetired < s.d2hReady then some { s with d2hRetired := s.d2hRetired + 1 }.endOp
  else none

/-- `SendNextLayer`'s future callback (`.cc:384-406`) for layer `woken`, which
needs its copy ready. -/
def wake (ok : Bool) (s : Send) : Option Send :=
  if s.woken < s.queued ∧ s.woken < s.d2hReady then
    let s := { s with woken := s.woken + 1 }
    if ok = false then some (s.finish false).endOp
    else if s.life.draining = true then some s.endOp
    else some { s with pooled := s.pooled + 1 }
  else none

/-- The pool task up to and including the push (`.cc:407-424`). -/
def h2hIssue (s : Send) : Option Send :=
  if s.pooled = 0 then none
  else
    let s := { s with pooled := s.pooled - 1 }
    match s.life.beginOp with
    | some l => some { s with life := l, h2hIssued := s.h2hIssued + 1, chaining := s.chaining + 1 }
    | none => some s.endOp

/-- The pool task's tail: `SendNextLayer(l+1)` (`.cc:449`), then the cleanup
at `.cc:407` ends the op it carried. -/
def sendNext (s : Send) : Option Send :=
  if s.chaining = 0 then none
  else some { s with chaining := s.chaining - 1 }.trySendNext.endOp

/-- The push callback (`.cc:428-445`). -/
def h2hDone (ok : Bool) (s : Send) : Option Send :=
  if s.h2hRetired < s.h2hIssued then
    let s := { s with h2hRetired := s.h2hRetired + 1 }
    if ok then
      let s := { s with h2hOk := s.h2hOk + 1 }
      some (if s.h2hOk = s.numLayers then (s.finish true).endOp else s.endOp)
    else some (s.finish false).endOp
  else none

/-- `Finish(error)` from outside the data path; enabled at any time. -/
def cancel (s : Send) : Option Send := some (s.finish false)

/-- `CompleteReadRaw` publishes a settled session (`mgr.cc:918-925`). -/
def publish (s : Send) : Option Send :=
  if s.life.done = true ∧ s.published = none then
    some { s with published := some s.life.statusOk }
  else none

def step (s : Send) : Ev → Option Send
  | .start => s.start
  | .d2hBegin => s.d2hBegin
  | .d2hIssue ok => s.d2hIssue ok
  | .d2hDone => s.d2hDone
  | .d2hEnd => s.d2hEnd
  | .wake ok => s.wake ok
  | .h2hIssue => s.h2hIssue
  | .sendNext => s.sendNext
  | .h2hDone ok => s.h2hDone ok
  | .cancel => s.cancel
  | .publish => s.publish

/-- A registered send with `n` layers. -/
def sys (n : Nat) : System Send Ev := ⟨init n, step⟩

/-! ## Properties -/

def SettleSafe (s : Send) : Prop := s.life.done = true → s.life.inFlight = 0

/-- A settled send has no copy, callback, pool task or push outstanding. -/
def Drained (s : Send) : Prop :=
  s.life.done = true →
    s.d2hPending = false ∧ s.d2hRetired = s.d2hIssued ∧ s.woken = s.queued ∧
      s.pooled = 0 ∧ s.chaining = 0 ∧ s.h2hRetired = s.h2hIssued

def StagingIntegrity (s : Send) : Prop := s.life.hasStaging = !s.life.done

def SettlesPromptly (s : Send) : Prop :=
  s.life.draining = true → s.life.inFlight = 0 → s.life.done = true

def NoUnderflow (s : Send) : Prop := s.underflow = false

def Publication (s : Send) : Prop := s.published = some true → s.h2hOk = s.numLayers

def Counters (s : Send) : Prop :=
  s.d2hRetired ≤ s.d2hReady ∧ s.d2hReady ≤ s.d2hIssued ∧
    s.d2hIssued + (if s.d2hPending then 1 else 0) ≤ s.numLayers ∧
    s.woken ≤ s.queued ∧ s.queued ≤ s.d2hIssued ∧ s.woken ≤ s.d2hReady ∧
    s.pooled + s.h2hIssued ≤ s.woken ∧
    s.h2hRetired ≤ s.h2hIssued ∧ s.h2hOk ≤ s.h2hRetired

/-- Everything we want to know about a reachable send session. -/
def Safe (s : Send) : Prop :=
  SettleSafe s ∧ Drained s ∧ StagingIntegrity s ∧ SettlesPromptly s ∧ NoUnderflow s ∧
    Publication s ∧ Counters s

/-! ## Inductive invariant -/

/-- Where every unit of `in_flight_` comes from: a dispatch in progress, a copy
whose `OnReady` has not ended it, a `SendNextLayer` waiting on its future, a
layer waiting for the pool, a pool task that has not released its op, or a
push whose callback has not run. -/
def Accounted (s : Send) : Prop :=
  s.life.inFlight =
    (if s.d2hPending then 1 else 0) + (s.d2hIssued - s.d2hRetired) + (s.queued - s.woken) +
      s.pooled + s.chaining + (s.h2hIssued - s.h2hRetired)

structure Inv (s : Send) : Prop where
  life : s.life.Consistent
  accounted : Accounted s
  no_underflow : s.underflow = false
  counters : Counters s
  /-- A send that started draining without an error had pushed every layer. -/
  ok_draining : s.life.statusOk = true → s.life.draining = true → s.h2hOk = s.numLayers
  /-- Only settled sessions are published. -/
  published_done : ∀ b, s.published = some b → s.life.done = true
  /-- Once published as done, every layer had been pushed (and still has). -/
  published_ok : s.published = some true → s.h2hOk = s.numLayers

theorem inv_init (n : Nat) : Inv (init n) := by
  refine ⟨Lifecycle.consistent_init, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [init, Accounted, Counters]

theorem inv_safe {s : Send} (h : Inv s) : Safe s := by
  obtain ⟨hl, hacc, hu, hcnt, _, _, hpub⟩ := h
  unfold Accounted at hacc
  unfold Counters at hcnt
  refine ⟨hl.done_idle, ?_, hl.staging, hl.prompt, hu, hpub, hcnt⟩
  intro hd
  have h0 := hl.done_idle hd
  cases hp : s.d2hPending <;> simp [hp] at hacc ⊢ <;> omega

/-! ### Helpers for the step proof -/

theorem endOp_eq {s : Send} (h : 0 < s.life.inFlight) :
    s.endOp = { s with life := s.life.endOpLocked } := by
  unfold endOp
  split
  · omega
  · rfl

theorem finish_cases (ok : Bool) {s : Send} (hl : s.life.Consistent) :
    (s.life.draining = true ∧ s.finish ok = s) ∨
    (s.life.draining = false ∧ s.life.done = false ∧
      s.finish ok = { s with life := Lifecycle.settleLocked
                                { s.life with draining := true, statusOk := ok } }) := by
  cases hd : s.life.draining
  · have hn := hl.not_done hd
    right
    exact ⟨rfl, hn, by simp [finish, Lifecycle.finishOnceLocked_open ok hd hn]⟩
  · left
    exact ⟨rfl, by simp [finish, Lifecycle.finishOnceLocked_decided ok (Or.inl hd)]⟩

theorem trySendNext_cases (s : Send) :
    s.trySendNext = s ∨
    (s.queued < s.d2hIssued ∧ s.life.draining = false ∧ s.life.done = false ∧
      s.trySendNext = { s with life := { s.life with inFlight := s.life.inFlight + 1 },
                               queued := s.queued + 1 }) := by
  unfold trySendNext
  split
  · rename_i hlt
    split
    · rename_i l hb
      right
      obtain ⟨hd, hdr⟩ := Lifecycle.beginOp_active hb
      refine ⟨hlt, hdr, hd, ?_⟩
      unfold Lifecycle.beginOp at hb
      split at hb
      · cases hb
      · cases hb; rfl
    · left; rfl
  · left; rfl

/-- Each event preserves the invariant. -/
theorem step_inv {s s' : Send} {e : Ev} (h : Inv s) (hs : step s e = some s') : Inv s' := by
  obtain ⟨hl, hacc, hu, hcnt, hdr, hpd, hpub⟩ := h
  unfold Accounted at hacc
  unfold Counters at hcnt
  cases e with
  | start =>
    simp only [step, start] at hs
    split at hs
    · cases hs
    · rename_i hn
      simp only [not_or] at hn
      obtain ⟨_, hndr, hnd⟩ := hn
      have hndr' : s.life.draining = false := by simpa using hndr
      have hnd' : s.life.done = false := by simpa using hnd
      split at hs
      · rename_i h0
        cases hs
        rcases finish_cases true hl with ⟨hd, heq⟩ | ⟨_, _, heq⟩
        · simp [hndr'] at hd
        · rw [heq]
          refine ⟨Lifecycle.settleLocked_consistent (by simp) (by simp [hnd']) (by simp [hl.staging, hnd']),
            ?_, hu, hcnt, ?_, ?_, hpub⟩
          · unfold Accounted; simpa using hacc
          · intro _ _; simp; omega
          · intro b hp
            have := hpd b hp
            simp [hnd'] at this
      · cases hs
        exact ⟨hl, by unfold Accounted; simpa using hacc, hu, by unfold Counters; simpa using hcnt,
          hdr, hpd, hpub⟩
  | d2hBegin =>
    simp only [step, d2hBegin] at hs
    split at hs
    · rename_i hg
      obtain ⟨_, hp, _⟩ := hg
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨l, hb, rfl⟩ := hs
      have := Lifecycle.beginOp_inFlight hb
      have hact := Lifecycle.beginOp_active hb
      have hok' := Lifecycle.beginOp_statusOk hb
      have hdr' := Lifecycle.beginOp_draining hb
      refine ⟨Lifecycle.beginOp_consistent hl hb, ?_, hu, ?_, ?_, ?_, hpub⟩
      · unfold Accounted; simp [hp] at hacc; simp; omega
      · unfold Counters; simp [hp] at hcnt; simp; omega
      · simp [hdr']
      · intro b hq
        have := hpd b hq
        simp [hact.1] at this
    · cases hs
  | d2hIssue ok =>
    simp only [step, d2hIssue] at hs
    split at hs
    · cases hs
    · rename_i hp
      have hp' : s.d2hPending = true := by
        cases hq : s.d2hPending
        · exact absurd hq hp
        · rfl
      simp [hp'] at hacc hcnt
      split at hs
      · cases hs
        -- success: the copy is counted already; maybe `SendNextLayer(0)`
        split
        · rename_i hlast
          rcases trySendNext_cases { s with d2hPending := false, d2hIssued := s.d2hIssued + 1 }
            with heq | ⟨hlt, hdr', hd', heq⟩
          · rw [heq]
            refine ⟨hl, ?_, hu, ?_, hdr, hpd, hpub⟩
            · unfold Accounted; simp; omega
            · unfold Counters; simp; omega
          · rw [heq]
            simp at hlt hdr' hd'
            refine ⟨Lifecycle.consistent_incr hl hdr', ?_, hu, ?_, ?_, ?_, hpub⟩
            · unfold Accounted; simp; omega
            · unfold Counters; simp; omega
            · simp [hdr']
            · intro b hq
              have := hpd b hq
              simp [hd'] at this
        · refine ⟨hl, ?_, hu, ?_, hdr, hpd, hpub⟩
          · unfold Accounted; simp; omega
          · unfold Counters; simp; omega
      · cases hs
        rcases finish_cases false (s := { s with d2hPending := false }) hl
          with ⟨hd, heq⟩ | ⟨hd, hn, heq⟩ <;> rw [heq] <;> simp at hd
        · rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, hpub⟩
          · unfold Accounted; simp; omega
          · unfold Counters; simp; omega
          · simpa using hdr
          · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
        · simp at hn
          rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent
              (Lifecycle.settleLocked_consistent (by simp) (by simp [hn]) (by simp [hl.staging, hn])),
            ?_, hu, ?_, ?_, ?_, hpub⟩
          · unfold Accounted; simp; omega
          · unfold Counters; simp; omega
          · simp
          · intro b hq
            have := hpd b hq
            simp [hn] at this
  | d2hDone =>
    simp only [step, d2hDone] at hs
    split at hs
    · cases hs
      exact ⟨hl, by unfold Accounted; simpa using hacc, hu, by unfold Counters; simp; omega,
        hdr, hpd, hpub⟩
    · cases hs
  | d2hEnd =>
    simp only [step, d2hEnd] at hs
    split at hs
    · cases hs
      rw [endOp_eq (by simp; omega)]
      refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, hpub⟩
      · unfold Accounted; simp; omega
      · unfold Counters; simp; omega
      · simpa using hdr
      · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
    · cases hs
  | wake ok =>
    simp only [step, wake] at hs
    split at hs
    · rename_i hg
      split at hs
      · -- the copy failed: Finish(error), then the cleanup ends the op
        cases hs
        rcases finish_cases false (s := { s with woken := s.woken + 1 }) hl
          with ⟨hd, heq⟩ | ⟨hd, hn, heq⟩ <;> rw [heq] <;> simp at hd
        · rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, hpub⟩
          · unfold Accounted; simp; omega
          · unfold Counters; simp; omega
          · simpa using hdr
          · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
        · simp at hn
          rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent
              (Lifecycle.settleLocked_consistent (by simp) (by simp [hn]) (by simp [hl.staging, hn])),
            ?_, hu, ?_, ?_, ?_, hpub⟩
          · unfold Accounted; simp; omega
          · unfold Counters; simp; omega
          · simp
          · intro b hq
            have := hpd b hq
            simp [hn] at this
      · split at hs
        · -- draining: the layer is dropped, the op ends
          cases hs
          rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, hpub⟩
          · unfold Accounted; simp; omega
          · unfold Counters; simp; omega
          · simpa using hdr
          · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
        · -- scheduled on the push pool; the op is carried over
          cases hs
          refine ⟨hl, ?_, hu, ?_, hdr, hpd, hpub⟩
          · unfold Accounted; simp; omega
          · unfold Counters; simp; omega
    · cases hs
  | h2hIssue =>
    simp only [step, h2hIssue] at hs
    split at hs
    · cases hs
    · rename_i hp
      split at hs
      · rename_i l hb
        cases hs
        have := Lifecycle.beginOp_inFlight hb
        have hact := Lifecycle.beginOp_active hb
        have hok' := Lifecycle.beginOp_statusOk hb
        have hdr' := Lifecycle.beginOp_draining hb
        refine ⟨Lifecycle.beginOp_consistent hl hb, ?_, hu, ?_, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold Counters; simp; omega
        · simp [hdr']
        · intro b hq
          have := hpd b hq
          simp [hact.1] at this
      · cases hs
        rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold Counters; simp; omega
        · simpa using hdr
        · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
  | sendNext =>
    simp only [step, sendNext] at hs
    split at hs
    · cases hs
    · rename_i hc
      cases hs
      rcases trySendNext_cases { s with chaining := s.chaining - 1 }
        with heq | ⟨hlt, hdr', hd', heq⟩ <;> rw [heq]
      · rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold Counters; simp; omega
        · simpa using hdr
        · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
      · simp at hlt hdr' hd'
        rw [endOp_eq (by simp)]
        refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.consistent_incr hl hdr'), ?_, hu, ?_,
          ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold Counters; simp; omega
        · simp [hdr']
        · intro b hq
          have := hpd b hq
          simp [hd'] at this
  | h2hDone ok =>
    simp only [step, h2hDone] at hs
    split at hs
    · rename_i hg
      -- a push is outstanding, so the session is not settled, so not published
      have hnp : s.published = none := by
        cases hq : s.published with
        | none => rfl
        | some b =>
          have := hl.done_idle (hpd b hq)
          omega
      split at hs
      · cases hs
        split
        · -- the last push: Finish() then the cleanup ends the op
          rename_i hlast
          try simp at hlast
          rcases finish_cases true
              (s := { s with h2hRetired := s.h2hRetired + 1, h2hOk := s.h2hOk + 1 }) hl
            with ⟨hd, heq⟩ | ⟨hd, hn, heq⟩ <;> rw [heq] <;> simp at hd
          · rw [endOp_eq (by simp; omega)]
            refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, ?_⟩
            · unfold Accounted; simp; omega
            · unfold Counters; simp; omega
            · intro _ _; simp; omega
            · simp [hnp]
            · simp [hnp]
          · simp at hn
            rw [endOp_eq (by simp; omega)]
            refine ⟨Lifecycle.endOpLocked_consistent
                (Lifecycle.settleLocked_consistent (by simp) (by simp [hn])
                  (by simp [hl.staging, hn])),
              ?_, hu, ?_, ?_, ?_, ?_⟩
            · unfold Accounted; simp; omega
            · unfold Counters; simp; omega
            · intro _ _; simp; omega
            · simp [hnp]
            · simp [hnp]
        · rename_i hnl
          rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, ?_⟩
          · unfold Accounted; simp; omega
          · unfold Counters; simp; omega
          · intro h1 h2
            simp at h1 h2
            have := hdr h1 h2
            simp; omega
          · simp [hnp]
          · simp [hnp]
      · cases hs
        rcases finish_cases false (s := { s with h2hRetired := s.h2hRetired + 1 }) hl
          with ⟨hd, heq⟩ | ⟨hd, hn, heq⟩ <;> rw [heq] <;> simp at hd
        · rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, ?_⟩
          · unfold Accounted; simp; omega
          · unfold Counters; simp; omega
          · simpa using hdr
          · simp [hnp]
          · simp [hnp]
        · simp at hn
          rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent
              (Lifecycle.settleLocked_consistent (by simp) (by simp [hn]) (by simp [hl.staging, hn])),
            ?_, hu, ?_, ?_, ?_, ?_⟩
          · unfold Accounted; simp; omega
          · unfold Counters; simp; omega
          · simp
          · simp [hnp]
          · simp [hnp]
    · cases hs
  | cancel =>
    simp only [step, cancel] at hs
    cases hs
    rcases finish_cases false hl with ⟨hd, heq⟩ | ⟨hd, hn, heq⟩ <;> rw [heq]
    · exact ⟨hl, by unfold Accounted; exact hacc, hu, by unfold Counters; exact hcnt, hdr, hpd, hpub⟩
    · refine ⟨Lifecycle.settleLocked_consistent (by simp) (by simp [hn]) (by simp [hl.staging, hn]),
        ?_, hu, ?_, ?_, ?_, hpub⟩
      · unfold Accounted; simpa using hacc
      · unfold Counters; simpa using hcnt
      · simp
      · intro b hq
        have := hpd b hq
        simp [hn] at this
  | publish =>
    simp only [step, publish] at hs
    split at hs
    · rename_i hd
      obtain ⟨hdone, _⟩ := hd
      cases hs
      refine ⟨hl, by unfold Accounted; simpa using hacc, hu, by unfold Counters; simpa using hcnt,
        hdr, fun _ _ => hdone, ?_⟩
      simp
      intro hst
      exact hdr hst (hl.done_draining hdone)
    · cases hs

theorem reachable_inv {n : Nat} {s : Send} (h : (sys n).Reachable s) : Inv s :=
  (sys n).reachable_induction (inv_init n) (fun _ _ _ hi hs => step_inv hi hs) h

/-- Main result: every reachable send session satisfies all the properties. -/
theorem reachable_safe {n : Nat} {s : Send} (h : (sys n).Reachable s) : Safe s :=
  inv_safe (reachable_inv h)

/-! ## Frame lemmas

What each event leaves alone, and exact specs for the two events the
composed transfer model (`Pipeline.lean`) attaches memory effects to. -/

/-- Unfold `step` for a known event and split every branch. -/
macro "send_cases" hs:ident : tactic =>
  `(tactic| (simp only [step, start, d2hBegin, d2hIssue, d2hDone, d2hEnd, wake, h2hIssue, sendNext,
      h2hDone, cancel, publish] at $hs:ident <;> (repeat' split at $hs:ident)))

theorem step_numLayers {s s' : Send} {e : Ev} (hs : step s e = some s') :
    s'.numLayers = s.numLayers := by
  cases e <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> rfl)

theorem step_done_mono {s s' : Send} {e : Ev} (hs : step s e = some s') (hd : s.life.done = true) :
    s'.life.done = true := by
  cases e <;> simp only [step, start, d2hBegin, d2hIssue, d2hDone, d2hEnd, wake, h2hIssue, sendNext,
      h2hDone, cancel, publish, endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight,
      Lifecycle.beginOp_of_done hd, Option.map_none] at hs <;>
    (repeat' split at hs) <;> cases hs <;>
    simp [hd, Lifecycle.endOpLocked_done_mono, Lifecycle.finishOnceLocked_done_mono]

theorem step_published_mono {s s' : Send} {e : Ev} {b : Bool} (hs : step s e = some s')
    (hp : s.published = some b) : s'.published = some b := by
  cases e <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; simpa using hp)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> simp_all)

/-- Only `d2hDone` lands a layer in staging. -/
theorem step_d2hReady {s s' : Send} {e : Ev} (hs : step s e = some s') (he : e ≠ .d2hDone) :
    s'.d2hReady = s.d2hReady := by
  cases e <;> (try exact absurd rfl he) <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> rfl)

theorem d2hDone_spec {s s' : Send} (hs : step s .d2hDone = some s') :
    s.d2hReady < s.d2hIssued ∧ s' = { s with d2hReady := s.d2hReady + 1 } := by
  simp only [step, d2hDone] at hs
  split at hs
  · cases hs; exact ⟨‹_›, rfl⟩
  · cases hs

theorem h2hDone_guard {s s' : Send} {ok : Bool} (hs : step s (.h2hDone ok) = some s') :
    s.h2hRetired < s.h2hIssued := by
  simp only [step, h2hDone] at hs
  split at hs
  · assumption
  · cases hs

/-! ## Replay and bounded search

Concrete traces, checked by `decide`, that document the behaviours the model
admits; and a bounded search confirming that no `Safe` violation is reachable
within a few events. The inductive proof above is the actual guarantee; the
search guards against a modelling slip making the proof vacuous. -/

/-- A two-layer send that completes and is published as `done_sending`. Note
the push chain: layer 1's push is only issued after layer 0's, and
`sendNext` after the last layer takes no op. -/
theorem trace_normal :
    ((sys 2).run
      [.start, .d2hBegin, .d2hIssue true, .d2hBegin, .d2hIssue true,
       .d2hDone, .d2hEnd, .wake true, .h2hIssue, .sendNext,
       .d2hDone, .d2hEnd, .wake true, .h2hIssue, .sendNext,
       .h2hDone true, .h2hDone true, .publish]).map
      (fun s => (s.life.done, s.published, s.h2hOk, s.life.inFlight)) =
      some (true, some true, 2, 0) := by
  decide

/-- "One nobody pulled is reported now" (`mgr.cc:912-913`): the deadline on an
idle send settles it at once. -/
theorem trace_never_pulled :
    ((sys 2).run [.cancel, .publish]).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) ∧
    (sys 2).run [.cancel, .start] = none := by
  decide

/-- The deadline fires while a copy runs: the send drains, keeps its staging,
issues nothing more, and settles when the copy's `OnReady` ends the op. -/
theorem trace_deadline_during_copy :
    ((sys 2).run [.start, .d2hBegin, .d2hIssue true, .cancel]).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    (sys 2).run [.start, .d2hBegin, .d2hIssue true, .cancel, .d2hBegin] = none ∧
    ((sys 2).run [.start, .d2hBegin, .d2hIssue true, .cancel, .d2hDone, .d2hEnd, .publish]).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) := by
  decide

/-- A push fails: the session drains, the layer still waiting in the chain is
dropped by `h2hIssue`'s re-check, and the send is published as failed. -/
theorem trace_push_fails :
    ((sys 2).run
      [.start, .d2hBegin, .d2hIssue true, .d2hBegin, .d2hIssue true,
       .d2hDone, .d2hEnd, .wake true, .h2hIssue, .sendNext,
       .d2hDone, .d2hEnd, .wake true, .h2hDone false, .h2hIssue, .publish]).map
      (fun s => (s.life.done, s.h2hIssued, s.published)) = some (true, 1, some false) := by
  decide

/-- Correspondence note (1): the OK finish happens in the last push callback
while a D2H `OnReady` may still be outstanding; a `Finish(error)` in that
window is ignored. -/
theorem trace_cancel_after_ok_finish :
    ((sys 1).run
      [.start, .d2hBegin, .d2hIssue true, .d2hDone, .wake true, .h2hIssue, .sendNext,
       .h2hDone true, .cancel, .d2hEnd, .publish]).map
      (fun s => (s.life.statusOk, s.published)) = some (true, some true) := by
  decide

/-- A zero-layer send finishes OK inside `StartPush`. -/
theorem trace_zero_layers :
    ((sys 0).run [.start, .publish]).map (fun s => s.published) = some (some true) := by
  decide

def events : List Ev :=
  [.start, .d2hBegin, .d2hIssue true, .d2hIssue false, .d2hDone, .d2hEnd,
   .wake true, .wake false, .h2hIssue, .sendNext, .h2hDone true, .h2hDone false,
   .cancel, .publish]

/-- Executable negation of `Safe`. -/
def violates (s : Send) : Bool :=
  (s.life.done && s.life.inFlight != 0) ||
  (s.life.done && (s.d2hPending || s.d2hRetired != s.d2hIssued || s.woken != s.queued ||
    s.pooled != 0 || s.chaining != 0 || s.h2hRetired != s.h2hIssued)) ||
  (s.life.hasStaging != !s.life.done) ||
  (s.life.draining && s.life.inFlight == 0 && !s.life.done) ||
  s.underflow ||
  (s.published == some true && s.h2hOk != s.numLayers) ||
  !(s.d2hRetired ≤ s.d2hReady && s.d2hReady ≤ s.d2hIssued &&
    s.d2hIssued + (if s.d2hPending then 1 else 0) ≤ s.numLayers &&
    s.woken ≤ s.queued && s.queued ≤ s.d2hIssued && s.woken ≤ s.d2hReady &&
    s.pooled + s.h2hIssued ≤ s.woken && s.h2hRetired ≤ s.h2hIssued && s.h2hOk ≤ s.h2hRetired)

#guard ModelCheck.check (sys 2) events violates 12 = .outOfFuel

/-- Sanity check on the search itself: a `Finish` that settles at once, ignoring
in-flight work, must be caught. -/
def cancelEager (s : Send) : Option Send :=
  some { s with life := { s.life with draining := true, done := true, hasStaging := false } }

#guard (match ModelCheck.check ⟨init 1, fun s e => match e with
          | .cancel => cancelEager s
          | e => step s e⟩ events violates 8 with
        | .counterexample _ => true
        | _ => false)

/-- And the point of the op `SendNextLayer` takes at `.cc:381`: without it a
send whose copies have all ended settles under a `Finish`, and the pool task
that then runs ends an op the session no longer owns. -/
def trySendNextUncounted (s : Send) : Send :=
  if s.queued < s.d2hIssued ∧ s.life.draining = false then { s with queued := s.queued + 1 } else s

def sendNextUncounted (s : Send) : Option Send :=
  if s.chaining = 0 then none
  else some { s with chaining := s.chaining - 1 }.trySendNextUncounted.endOp

def d2hIssueUncounted (ok : Bool) (s : Send) : Option Send :=
  if s.d2hPending = false then none
  else
    let s := { s with d2hPending := false }
    if ok then
      let s := { s with d2hIssued := s.d2hIssued + 1 }
      some (if s.d2hIssued = s.numLayers then s.trySendNextUncounted else s)
    else some (s.finish false).endOp

#guard (match ModelCheck.check ⟨init 1, fun s e => match e with
          | .sendNext => sendNextUncounted s
          | .d2hIssue ok => d2hIssueUncounted ok s
          | e => step s e⟩ events violates 8 with
        | .counterexample _ => true
        | _ => false)

end Send

end TpuSyncVerify.Transfer.PrefillDecode
