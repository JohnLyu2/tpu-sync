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
| `d2hReady`     | the device finishes a copy: its future becomes `IsReady()` |
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
  rather than naming layers. `SendNextLayer` is chained in layer order
  (`0, 1, …`), so when `SendNextLayer(k)`'s callback wakes in C++, layers
  `0 … k-1` have already woken and layer `k`'s future is ready — hence at
  least `k + 1` futures are ready (`woken < d2hReady`), even if later layers'
  D2H copies finished earlier. Since no event's effect on the counters depends
  on which layer finished, any real interleaving maps onto one the model
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
* **No op leak.** `0 < inFlight →` some event in `drainEvents` is enabled:
  every accounted unit of `in_flight_` has an owner that can advance or retire
  it (`NoOpLeak`), and every reachable state can drain to `done = true` and
  release its staging in a finite number of steps (`reachable_can_settle`).

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
  | d2hReady
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

/-- A dispatched copy finishes on the device; its future becomes ready. -/
def markD2hReady (s : Send) : Option Send :=
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
  | .d2hReady => s.markD2hReady
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

def CountersOrdered (s : Send) : Prop :=
  s.d2hRetired ≤ s.d2hReady ∧ s.d2hReady ≤ s.d2hIssued ∧
    s.d2hIssued + (if s.d2hPending then 1 else 0) ≤ s.numLayers ∧
    s.woken ≤ s.queued ∧ s.queued ≤ s.d2hIssued ∧ s.woken ≤ s.d2hReady ∧
    s.pooled + s.h2hIssued ≤ s.woken ∧
    s.h2hRetired ≤ s.h2hIssued ∧ s.h2hOk ≤ s.h2hRetired

/-- Events that advance or retire an in-flight operation. -/
def drainEvents : List Ev :=
  [.d2hIssue true, .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext, .h2hDone true]

/-- Every unit of `in_flight_` has an owner that can advance or retire it:
while `inFlight > 0`, some event in `drainEvents` is enabled. -/
def NoOpLeak (s : Send) : Prop :=
  0 < s.life.inFlight → ∃ e ∈ drainEvents, (step s e).isSome = true

/-- Everything we want to know about a reachable send session. -/
def Safe (s : Send) : Prop :=
  SettleSafe s ∧ Drained s ∧ StagingIntegrity s ∧ SettlesPromptly s ∧ NoUnderflow s ∧
    Publication s ∧ CountersOrdered s ∧ NoOpLeak s

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
  counters : CountersOrdered s
  /-- A send that started draining without an error had pushed every layer. -/
  ok_draining : s.life.statusOk = true → s.life.draining = true → s.h2hOk = s.numLayers
  /-- Only settled sessions are published. -/
  published_done : ∀ b, s.published = some b → s.life.done = true
  /-- Once published as done, every layer had been pushed (and still has). -/
  published_ok : s.published = some true → s.h2hOk = s.numLayers

theorem inv_init (n : Nat) : Inv (init n) := by
  refine ⟨Lifecycle.consistent_init, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    simp [init, Accounted, CountersOrdered]

theorem inv_noOpLeak {s : Send} (h : Inv s) : NoOpLeak s := by
  intro hif
  have hacc := h.accounted
  have hcnt := h.counters
  unfold Accounted at hacc
  unfold CountersOrdered at hcnt
  by_cases hp : s.d2hPending = true
  · exact ⟨.d2hIssue true, by simp [drainEvents], by simp [step, d2hIssue, hp]⟩
  · by_cases hrd : s.d2hReady < s.d2hIssued
    · exact ⟨.d2hReady, by simp [drainEvents], by simp [step, markD2hReady, hrd]⟩
    · by_cases hret : s.d2hRetired < s.d2hReady
      · exact ⟨.d2hEnd, by simp [drainEvents], by simp [step, d2hEnd, hret]⟩
      · by_cases hwk : s.woken < s.queued
        · have hwr : s.woken < s.d2hReady := by omega
          refine ⟨.wake true, by simp [drainEvents], ?_⟩
          simp only [step, wake, hwk, hwr, and_self, ↓reduceIte, Bool.true_eq_false]
          split <;> rfl
        · by_cases hpool : 0 < s.pooled
          · have hne : s.pooled ≠ 0 := by omega
            refine ⟨.h2hIssue, by simp [drainEvents], ?_⟩
            simp only [step, h2hIssue, hne, ↓reduceIte]
            split <;> rfl
          · by_cases hch : 0 < s.chaining
            · exact ⟨.sendNext, by simp [drainEvents], by simp [step, sendNext]; omega⟩
            · have hh2h : s.h2hRetired < s.h2hIssued := by
                cases hdp : s.d2hPending <;> simp_all <;> omega
              exact ⟨.h2hDone true, by simp [drainEvents], by simp [step, h2hDone, hh2h]⟩

theorem inv_safe {s : Send} (h : Inv s) : Safe s := by
  have hnl := inv_noOpLeak h
  obtain ⟨hl, hacc, hu, hcnt, _, _, hpub⟩ := h
  unfold Accounted at hacc
  unfold CountersOrdered at hcnt
  refine ⟨hl.done_idle, ?_, hl.staging, hl.prompt, hu, hpub, hcnt, hnl⟩
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
  unfold CountersOrdered at hcnt
  cases e with
  | start =>
    simp only [step, start] at hs
    split at hs
    · cases hs
    · split at hs
      · cases hs
        dsimp only [finish]
        refine ⟨Lifecycle.finishOnceLocked_consistent true hl,
          by unfold Accounted; simpa using hacc, hu, hcnt,
          by intro _ _; simp; omega,
          fun b hp => Lifecycle.finishOnceLocked_done_mono true (hpd b hp), hpub⟩
      · cases hs
        exact ⟨hl, by unfold Accounted; simpa using hacc, hu,
          by unfold CountersOrdered; simpa using hcnt, hdr, hpd, hpub⟩
  | d2hBegin =>
    simp only [step, d2hBegin] at hs
    split at hs
    · rename_i hg
      obtain ⟨_, hp, _⟩ := hg
      simp only [Option.map_eq_some_iff] at hs
      obtain ⟨l, hb, rfl⟩ := hs
      have := Lifecycle.beginOp_inFlight hb
      have hact := Lifecycle.beginOp_active hb
      have hdr' := Lifecycle.beginOp_draining hb
      refine ⟨Lifecycle.beginOp_consistent hl hb, ?_, hu, ?_, ?_, ?_, hpub⟩
      · unfold Accounted; simp [hp] at hacc; simp; omega
      · unfold CountersOrdered; simp [hp] at hcnt; simp; omega
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
        · rcases trySendNext_cases { s with d2hPending := false, d2hIssued := s.d2hIssued + 1 }
            with heq | ⟨hlt, hdr', hd', heq⟩
          · rw [heq]
            refine ⟨hl, ?_, hu, ?_, hdr, hpd, hpub⟩
            · unfold Accounted; simp; omega
            · unfold CountersOrdered; simp; omega
          · rw [heq]
            simp at hlt hdr' hd'
            refine ⟨Lifecycle.consistent_incr hl hdr', ?_, hu, ?_, ?_, ?_, hpub⟩
            · unfold Accounted; simp; omega
            · unfold CountersOrdered; simp; omega
            · simp [hdr']
            · intro b hq
              have := hpd b hq
              simp [hd'] at this
        · refine ⟨hl, ?_, hu, ?_, hdr, hpd, hpub⟩
          · unfold Accounted; simp; omega
          · unfold CountersOrdered; simp; omega
      · cases hs
        dsimp only [finish]
        rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishOnceLocked_consistent false hl),
          ?_, hu, ?_, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · intro hok _
          obtain ⟨h1, h2⟩ := hl.finishOnceLocked_false_statusOk (by simpa using hok)
          exact hdr h1 h2
        · exact fun b hq =>
            Lifecycle.endOpLocked_done_mono (Lifecycle.finishOnceLocked_done_mono false (hpd b hq))
  | d2hReady =>
    simp only [step, markD2hReady] at hs
    split at hs
    · cases hs
      exact ⟨hl, by unfold Accounted; simpa using hacc, hu,
        by unfold CountersOrdered; simp; omega, hdr, hpd, hpub⟩
    · cases hs
  | d2hEnd =>
    simp only [step, d2hEnd] at hs
    split at hs
    · cases hs
      rw [endOp_eq (by simp; omega)]
      refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, hpub⟩
      · unfold Accounted; simp; omega
      · unfold CountersOrdered; simp; omega
      · simpa using hdr
      · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
    · cases hs
  | wake ok =>
    simp only [step, wake] at hs
    split at hs
    · split at hs
      · -- the copy failed: Finish(error), then the cleanup ends the op
        cases hs
        dsimp only [finish]
        rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishOnceLocked_consistent false hl),
          ?_, hu, ?_, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · intro hok _
          obtain ⟨h1, h2⟩ := hl.finishOnceLocked_false_statusOk (by simpa using hok)
          exact hdr h1 h2
        · exact fun b hq =>
            Lifecycle.endOpLocked_done_mono (Lifecycle.finishOnceLocked_done_mono false (hpd b hq))
      · split at hs
        · -- draining: the layer is dropped, the op ends
          cases hs
          rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, hpub⟩
          · unfold Accounted; simp; omega
          · unfold CountersOrdered; simp; omega
          · simpa using hdr
          · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
        · -- scheduled on the push pool; the op is carried over
          cases hs
          refine ⟨hl, ?_, hu, ?_, hdr, hpd, hpub⟩
          · unfold Accounted; simp; omega
          · unfold CountersOrdered; simp; omega
    · cases hs
  | h2hIssue =>
    simp only [step, h2hIssue] at hs
    split at hs
    · cases hs
    · split at hs
      · rename_i l hb
        cases hs
        have := Lifecycle.beginOp_inFlight hb
        have hact := Lifecycle.beginOp_active hb
        have hdr' := Lifecycle.beginOp_draining hb
        refine ⟨Lifecycle.beginOp_consistent hl hb, ?_, hu, ?_, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · simp [hdr']
        · intro b hq
          have := hpd b hq
          simp [hact.1] at this
      · cases hs
        rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · simpa using hdr
        · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
  | sendNext =>
    simp only [step, sendNext] at hs
    split at hs
    · cases hs
    · cases hs
      rcases trySendNext_cases { s with chaining := s.chaining - 1 }
        with heq | ⟨hlt, hdr', hd', heq⟩ <;> rw [heq]
      · rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · simpa using hdr
        · exact fun b hq => Lifecycle.endOpLocked_done_mono (hpd b hq)
      · simp at hlt hdr' hd'
        rw [endOp_eq (by simp)]
        refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.consistent_incr hl hdr'), ?_, hu, ?_,
          ?_, ?_, hpub⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · simp [hdr']
        · intro b hq
          have := hpd b hq
          simp [hd'] at this
  | h2hDone ok =>
    simp only [step, h2hDone] at hs
    split at hs
    · -- a push is outstanding, so the session is not settled, so not published
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
          dsimp only [finish]
          rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishOnceLocked_consistent true hl),
            ?_, hu, ?_, ?_, ?_, ?_⟩
          · unfold Accounted; simp; omega
          · unfold CountersOrdered; simp; omega
          · intro _ _; simp; omega
          · simp [hnp]
          · simp [hnp]
        · rw [endOp_eq (by simp; omega)]
          refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hu, ?_, ?_, ?_, ?_⟩
          · unfold Accounted; simp; omega
          · unfold CountersOrdered; simp; omega
          · intro h1 h2
            simp at h1 h2
            have := hdr h1 h2
            simp; omega
          · simp [hnp]
          · simp [hnp]
      · cases hs
        dsimp only [finish]
        rw [endOp_eq (by simp; omega)]
        refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishOnceLocked_consistent false hl),
          ?_, hu, ?_, ?_, ?_, ?_⟩
        · unfold Accounted; simp; omega
        · unfold CountersOrdered; simp; omega
        · intro hok _
          obtain ⟨h1, h2⟩ := hl.finishOnceLocked_false_statusOk (by simpa using hok)
          exact hdr h1 h2
        · simp [hnp]
        · simp [hnp]
    · cases hs
  | cancel =>
    simp only [step, cancel] at hs
    cases hs
    dsimp only [finish]
    refine ⟨Lifecycle.finishOnceLocked_consistent false hl,
      by unfold Accounted; simpa using hacc, hu,
      by unfold CountersOrdered; simpa using hcnt, ?_,
      fun b hq => Lifecycle.finishOnceLocked_done_mono false (hpd b hq), hpub⟩
    intro hok _
    obtain ⟨h1, h2⟩ := hl.finishOnceLocked_false_statusOk (by simpa using hok)
    exact hdr h1 h2
  | publish =>
    simp only [step, publish] at hs
    split at hs
    · rename_i hd
      obtain ⟨hdone, _⟩ := hd
      cases hs
      refine ⟨hl, by unfold Accounted; simpa using hacc, hu,
        by unfold CountersOrdered; simpa using hcnt, hdr, fun _ _ => hdone, ?_⟩
      simp
      intro hst
      exact hdr hst (hl.done_draining hdone)
    · cases hs

theorem reachable_inv {n : Nat} {s : Send} (h : (sys n).Reachable s) : Inv s :=
  (sys n).reachable_induction (inv_init n) (fun _ _ _ hi hs => step_inv hi hs) h

/-- Main result: every reachable send session satisfies all the properties. -/
theorem reachable_safe {n : Nat} {s : Send} (h : (sys n).Reachable s) : Safe s :=
  inv_safe (reachable_inv h)

/-! ### Progress and eventual settlement -/

/-- Remaining steps needed to drain all in-flight operations once draining. -/
def drainRank (s : Send) : Nat :=
  3 * (if s.d2hPending then 1 else 0) + (s.d2hIssued - s.d2hReady) +
    (s.d2hIssued - s.d2hRetired) + (s.queued - s.woken) +
    s.pooled + s.chaining + (s.h2hIssued - s.h2hRetired)

theorem trySendNext_of_draining {s : Send} (hdr : s.life.draining = true) :
    s.trySendNext = s := by
  unfold trySendNext; split <;> simp [Lifecycle.beginOp_of_draining hdr]

@[simp] theorem endOp_draining (s : Send) :
    s.endOp.life.draining = s.life.draining := by
  unfold endOp; split <;> simp

theorem finish_of_draining (ok : Bool) {s : Send} (hdr : s.life.draining = true) :
    s.finish ok = s := by
  simp [finish, Lifecycle.finishOnceLocked_decided ok (Or.inl hdr)]

theorem drainRank_endOp (s : Send) : drainRank s.endOp = drainRank s := by
  unfold endOp; split <;> rfl

/-- While draining and not yet settled, some event in `drainEvents` is enabled,
preserves `draining`, and strictly decreases `drainRank`. -/
theorem drain_step {s : Send} (h : Inv s) (hdr : s.life.draining = true)
    (hnd : s.life.done = false) :
    ∃ e s', step s e = some s' ∧ s'.life.draining = true ∧ drainRank s' < drainRank s := by
  have hif : 0 < s.life.inFlight := by
    cases h0 : s.life.inFlight
    · have := h.life.prompt hdr h0; simp [hnd] at this
    · omega
  have hacc := h.accounted
  have hcnt := h.counters
  unfold Accounted at hacc
  unfold CountersOrdered at hcnt
  by_cases hp : s.d2hPending = true
  · have hs₁ : step s (.d2hIssue true) = some { s with d2hPending := false, d2hIssued := s.d2hIssued + 1 } := by
      simp [step, d2hIssue, hp, trySendNext_of_draining (s := { s with d2hPending := false, d2hIssued := s.d2hIssued + 1 }) hdr]
    exact ⟨.d2hIssue true, _, hs₁, by simp [hdr], by simp [drainRank, hp]; omega⟩
  · by_cases hrd : s.d2hReady < s.d2hIssued
    · have hs₁ : step s .d2hReady = some { s with d2hReady := s.d2hReady + 1 } := by
        simp [step, markD2hReady, hrd]
      exact ⟨.d2hReady, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩
    · by_cases hret : s.d2hRetired < s.d2hReady
      · have hs₁ : step s .d2hEnd = some { s with d2hRetired := s.d2hRetired + 1 }.endOp := by
          simp [step, d2hEnd, hret]
        exact ⟨.d2hEnd, _, hs₁, by simp [hdr], by rw [drainRank_endOp]; simp [drainRank]; omega⟩
      · by_cases hwk : s.woken < s.queued
        · have hwr : s.woken < s.d2hReady := by omega
          have hs₁ : step s (.wake true) = some { s with woken := s.woken + 1 }.endOp := by
            simp [step, wake, hwk, hwr, hdr]
          exact ⟨.wake true, _, hs₁, by simp [hdr], by rw [drainRank_endOp]; simp [drainRank]; omega⟩
        · by_cases hpool : 0 < s.pooled
          · have hs₁ : step s .h2hIssue = some { s with pooled := s.pooled - 1 }.endOp := by
              simp [step, h2hIssue, Lifecycle.beginOp_of_draining hdr]; omega
            exact ⟨.h2hIssue, _, hs₁, by simp [hdr], by rw [drainRank_endOp]; simp [drainRank]; omega⟩
          · by_cases hch : 0 < s.chaining
            · have hs₁ : step s .sendNext = some { s with chaining := s.chaining - 1 }.endOp := by
                simp [step, sendNext, trySendNext_of_draining (s := { s with chaining := s.chaining - 1 }) hdr]
                omega
              exact ⟨.sendNext, _, hs₁, by simp [hdr], by rw [drainRank_endOp]; simp [drainRank]; omega⟩
            · have hh2h : s.h2hRetired < s.h2hIssued := by
                cases hdp : s.d2hPending <;> simp_all <;> omega
              have hs₁ : step s (.h2hDone true) =
                  some { s with h2hRetired := s.h2hRetired + 1, h2hOk := s.h2hOk + 1 }.endOp := by
                simp [step, h2hDone, hh2h,
                  finish_of_draining true (s := { s with h2hRetired := s.h2hRetired + 1, h2hOk := s.h2hOk + 1 }) hdr]
              exact ⟨.h2hDone true, _, hs₁, by simp [hdr], by rw [drainRank_endOp]; simp [drainRank]; omega⟩

theorem draining_can_settle_aux (n : Nat) :
    ∀ (k : Nat) {s : Send}, drainRank s ≤ k → Inv s → s.life.draining = true →
      ∃ evs s', (sys n).runFrom s evs = some s' ∧
        s'.life.done = true ∧ s'.life.hasStaging = false
  | 0, s, hk, h, hdr => by
    have hacc := h.accounted
    unfold Accounted at hacc
    unfold drainRank at hk
    have hd : s.life.done = true := h.life.prompt hdr (by omega)
    have hst : s.life.hasStaging = false := by rw [h.life.staging, hd]; rfl
    exact ⟨[], s, rfl, hd, hst⟩
  | k + 1, s, hk, h, hdr => by
    cases hnd : s.life.done
    · obtain ⟨e, s₁, hs₁, hdr₁, hlt⟩ := drain_step h hdr hnd
      obtain ⟨evs, s', hrun, hd', hst'⟩ :=
        draining_can_settle_aux n k (by omega) (step_inv h hs₁) hdr₁
      refine ⟨e :: evs, s', ?_, hd', hst'⟩
      simp only [System.runFrom, sys, List.foldlM_cons, hs₁]
      exact hrun
    · have hst : s.life.hasStaging = false := by rw [h.life.staging, hnd]; rfl
      exact ⟨[], s, rfl, hnd, hst⟩

/-- Every reachable send session can settle and release its staging buffer in a
finite number of steps. -/
theorem reachable_can_settle {n : Nat} {s : Send} (h : (sys n).Reachable s) :
    ∃ evs s', (sys n).runFrom s evs = some s' ∧
      s'.life.done = true ∧ s'.life.hasStaging = false := by
  have hinv := reachable_inv h
  have hcancel : step s .cancel = some (s.finish false) := rfl
  have hinv₁ := step_inv hinv hcancel
  have hdr₁ : (s.finish false).life.draining = true :=
    hinv.life.finishOnceLocked_draining false
  obtain ⟨evs, s', hrun, hd', hst'⟩ :=
    draining_can_settle_aux n (drainRank (s.finish false)) (Nat.le_refl _) hinv₁ hdr₁
  refine ⟨.cancel :: evs, s', ?_, hd', hst'⟩
  simp only [System.runFrom, sys, List.foldlM_cons, hcancel]
  exact hrun

/-! ## Frame lemmas

What each event leaves alone, and specs for the events the composed transfer
model (`Pipeline.lean`) attaches memory effects or layer guards to. -/

/-- Unfold `step` for a known event and split every branch. -/
macro "send_cases" hs:ident : tactic =>
  `(tactic| (simp only [step, start, d2hBegin, d2hIssue, markD2hReady, d2hEnd, wake, h2hIssue,
      sendNext, h2hDone, cancel, publish] at $hs:ident <;> (repeat' split at $hs:ident)))

theorem step_numLayers {s s' : Send} {e : Ev} (hs : step s e = some s') :
    s'.numLayers = s.numLayers := by
  cases e <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> rfl)

theorem step_done_mono {s s' : Send} {e : Ev} (hs : step s e = some s') (hd : s.life.done = true) :
    s'.life.done = true := by
  cases e <;> simp only [step, start, d2hBegin, d2hIssue, markD2hReady, d2hEnd, wake, h2hIssue,
      sendNext, h2hDone, cancel, publish, endOp, finish, trySendNext,
      Lifecycle.finishOnceLocked_inFlight, Lifecycle.beginOp_of_done hd, Option.map_none] at hs <;>
    (repeat' split at hs) <;> cases hs <;>
    simp [hd, Lifecycle.endOpLocked_done_mono, Lifecycle.finishOnceLocked_done_mono]

theorem step_published_mono {s s' : Send} {e : Ev} {b : Bool} (hs : step s e = some s')
    (hp : s.published = some b) : s'.published = some b := by
  cases e <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; simpa using hp)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> simp_all)

/-- Only `d2hReady` increments `d2hReady`. -/
theorem step_d2hReady {s s' : Send} {e : Ev} (hs : step s e = some s') (he : e ≠ .d2hReady) :
    s'.d2hReady = s.d2hReady := by
  cases e <;> (try exact absurd rfl he) <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> rfl)

theorem d2hReady_spec {s s' : Send} (hs : step s .d2hReady = some s') :
    s.d2hReady < s.d2hIssued ∧ s' = { s with d2hReady := s.d2hReady + 1 } := by
  simp only [step, markD2hReady] at hs
  split at hs
  · cases hs; exact ⟨‹_›, rfl⟩
  · cases hs

/-- Only `wake` consumes a layer's future. -/
theorem step_woken {s s' : Send} {e : Ev} (hs : step s e = some s') (he : ∀ ok, e ≠ .wake ok) :
    s'.woken = s.woken := by
  cases e <;> (try exact absurd rfl (he _)) <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> rfl)

/-- `wake` consumes exactly the next one. -/
theorem wake_woken {s s' : Send} {ok : Bool} (hs : step s (.wake ok) = some s') :
    s'.woken = s.woken + 1 := by
  simp only [step, wake] at hs
  split at hs
  · (repeat' split at hs) <;> cases hs <;>
      simp only [endOp, finish, Lifecycle.finishOnceLocked_inFlight] <;> (repeat' split) <;> rfl
  · cases hs

theorem h2hDone_guard {s s' : Send} {ok : Bool} (hs : step s (.h2hDone ok) = some s') :
    s.h2hRetired < s.h2hIssued := by
  simp only [step, h2hDone] at hs
  split at hs
  · assumption
  · cases hs

theorem step_d2hIssued_le {s s' : Send} {e : Ev} (hs : step s e = some s') :
    s.d2hIssued ≤ s'.d2hIssued := by
  cases e <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; exact Nat.le_refl _)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> simp)

theorem step_h2hRetired {s s' : Send} {e : Ev} (hs : step s e = some s')
    (he : ∀ ok, e ≠ .h2hDone ok) : s'.h2hRetired = s.h2hRetired := by
  cases e <;> (try exact absurd rfl (he _)) <;> send_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> simp only [endOp, finish, trySendNext, Lifecycle.finishOnceLocked_inFlight] <;>
        (repeat' split) <;> rfl)

theorem h2hDone_h2hRetired {s s' : Send} {ok : Bool} (hs : step s (.h2hDone ok) = some s') :
    s'.h2hRetired = s.h2hRetired + 1 := by
  simp only [step, h2hDone] at hs
  split at hs
  · (repeat' split at hs) <;> cases hs <;>
      simp only [endOp, finish, Lifecycle.finishOnceLocked_inFlight] <;> (repeat' split) <;> rfl
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
       .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext,
       .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext,
       .h2hDone true, .h2hDone true, .publish]).map
      (fun s => (s.life.done, s.published, s.h2hOk, s.life.inFlight)) =
      some (true, some true, 2, 0) := by
  decide

/-- "One nobody pulled is reported now" (`mgr.cc:912-913`;
`SendLifecycleTest.UnpulledSendAtOrBeforeItsDeadlineIsNotFailed` in
`kv_cache_manager_with_transfer_control_test.cc:433-460` and
`SendDeadlineTest.ExpiredSendSessionFailsInsteadOfReportingDone` in
`kv_cache_manager_with_transfer_pool_reshard_test.cc:338-347`): before the
deadline an unpulled send holds its staging and cannot be published; once the
deadline fires on the idle send it settles at once, releases its staging,
publishes failure (`some false`), and rejects any late `.start`. -/
theorem trace_never_pulled :
    ((sys 2).run []).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (false, true, none) ∧
    (sys 2).run [.publish] = none ∧
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
    ((sys 2).run [.start, .d2hBegin, .d2hIssue true, .cancel, .d2hReady, .d2hEnd, .publish]).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) := by
  decide

/-- A push fails: the session drains, the layer still waiting in the chain is
dropped by `h2hIssue`'s re-check, and the send is published as failed. -/
theorem trace_push_fails :
    ((sys 2).run
      [.start, .d2hBegin, .d2hIssue true, .d2hBegin, .d2hIssue true,
       .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext,
       .d2hReady, .d2hEnd, .wake true, .h2hDone false, .h2hIssue, .publish]).map
      (fun s => (s.life.done, s.h2hIssued, s.published)) = some (true, 1, some false) := by
  decide

/-- Correspondence note (1): the OK finish happens in the last push callback
while a D2H `OnReady` may still be outstanding; a `Finish(error)` in that
window is ignored. -/
theorem trace_cancel_after_ok_finish :
    ((sys 1).run
      [.start, .d2hBegin, .d2hIssue true, .d2hReady, .wake true, .h2hIssue, .sendNext,
       .h2hDone true, .cancel, .d2hEnd, .publish]).map
      (fun s => (s.life.statusOk, s.published)) = some (true, some true) := by
  decide

/-- A zero-layer send finishes OK inside `StartPush`. -/
theorem trace_zero_layers :
    ((sys 0).run [.start, .publish]).map (fun s => s.published) = some (some true) := by
  decide

/-- `TransferSendSessionTest.DoneGuaranteesAllResourcesReleasedAndNoHbmOrTransportAccessAfterDone`:
two layers; layer 0's H2H push and layer 1's D2H copy are both in flight when
`Finish(DeadlineExceeded)` fires; layer 0's H2H completes first (`done` stays
`false`, `hasStaging` stays `true`); when layer 1's D2H completes, `wake` sees
`draining`, drops layer 1's H2H (`h2hIssued = 1`), and settles (`done = true`,
`hasStaging = false`), after which `.start` is rejected. -/
theorem trace_drain_h2h_and_d2h :
    let pre := [.start, .d2hBegin, .d2hIssue true, .d2hBegin, .d2hIssue true,
                .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext,
                .cancel, .h2hDone true]
    ((sys 2).run pre).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    ((sys 2).run (pre ++ [.d2hReady, .d2hEnd, .wake true, .publish])).map
      (fun s => (s.life.done, s.life.hasStaging, s.h2hIssued, s.published)) =
      some (true, false, 1, some false) ∧
    (sys 2).run (pre ++ [.d2hReady, .d2hEnd, .wake true, .start]) = none := by
  decide

/-- `SendDrainTest.FailedLayerWaitsForTheOtherLayersCopies`: two layers; layer 0's
D2H copy fails while layer 1's D2H copy is still running; the failure and
staging slot are held back until layer 1's copy finishes. -/
theorem trace_failed_d2h_waits_for_other_layer :
    let pre := [.start, .d2hBegin, .d2hIssue true, .d2hBegin, .d2hIssue true,
                .d2hReady, .wake false, .d2hEnd]
    ((sys 2).run pre).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    (sys 2).run (pre ++ [.publish]) = none ∧
    ((sys 2).run (pre ++ [.d2hReady, .d2hEnd, .publish])).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) := by
  decide

/-- `SendLifecycleTest.SuccessCannotOverrideAnEarlierFailure`: dual of
`trace_cancel_after_ok_finish`. If `Finish(error)` runs while the last push is
in flight, a subsequent OK push completion (`h2hDone true` calling `finish true`)
cannot override the earlier failure. -/
theorem trace_ok_after_cancel_keeps_failure :
    ((sys 1).run
      [.start, .d2hBegin, .d2hIssue true, .d2hReady, .d2hEnd, .wake true, .h2hIssue, .sendNext,
       .cancel, .h2hDone true, .publish]).map
      (fun s => (s.life.done, s.life.statusOk, s.published)) = some (true, false, some false) := by
  decide

def events : List Ev :=
  [.start, .d2hBegin, .d2hIssue true, .d2hIssue false, .d2hReady, .d2hEnd,
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
    s.pooled + s.h2hIssued ≤ s.woken && s.h2hRetired ≤ s.h2hIssued && s.h2hOk ≤ s.h2hRetired) ||
  (0 < s.life.inFlight && !(drainEvents.any fun e => (step s e).isSome))

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

/-- Mutant for `NoOpLeak`: `SendNextLayer` omits the
`layer_idx >= d2h_layer_futures_.size()` bounds check at `.cc:379` and takes an
op unconditionally. After the last layer's pool task calls
`SendNextLayer(numLayers)` (`.cc:449`), that call claims an op for a
non-existent layer whose D2H future never becomes ready, leaking the session and
its staging forever (`SettleSafe` holds vacuously, `NoOpLeak` catches it). -/
def trySendNextUnbounded (s : Send) : Send :=
  match s.life.beginOp with
  | some l => { s with life := l, queued := s.queued + 1 }
  | none => s

def sendNextUnbounded (s : Send) : Option Send :=
  if s.chaining = 0 then none
  else some { s with chaining := s.chaining - 1 }.trySendNextUnbounded.endOp

#guard (match ModelCheck.check ⟨init 1, fun s e => match e with
          | .sendNext => sendNextUnbounded s
          | e => step s e⟩ events violates 8 with
        | .counterexample _ => true
        | _ => false)

end Send

end TpuSyncVerify.Transfer.PrefillDecode
