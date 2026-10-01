import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.Session

/-!
# Receive session lifecycle

Stage 1 of the prefill-to-decode model: one `TransferReceiveSession` on the
decode (consumer) side — how in-flight work is counted, how the session drains
and settles, and when its host staging is released. Layer data, the network
and the producer are added in later stages.

Citations are to tpu-sync `01ffa3d`, `tpu_sync/core/transfer_receive_session.{h,cc}`
unless noted.

## State

The settle protocol itself is `Transfer.Lifecycle`. On top of it:

| Field         | C++                                        | Role |
|---------------|--------------------------------------------|------|
| `numLayers`   | `base_->num_layers()`                      | fixed |
| `issued`      | `h2d_futures_.size()` (`.h:248`)           | H2D copies handed to the device |
| `completed`   | `num_completed_layers_` (`.h:238`)         | H2D callbacks that succeeded |
| `pushes`      | ghost                                      | incoming pushes between `TryBeginRecvOp` and `EndRecvOp` |
| `pullPending` | ghost                                      | the StartRead pull handshake still holds its op |
| `pending`     | ghost                                      | `ExecuteLayerH2d` calls between their first and second lock |
| `retired`     | ghost                                      | H2D callbacks that have run, succeeded or not |

Ghost fields have no single C++ variable. They record where each unit of
`in_flight_` came from, which is what `Accounted` is about.

## Events

| Event          | C++ |
|----------------|-----|
| `pushBegin`    | `TryBeginRecvOp` (`.h:109-114`) from `begin_incoming_push` (`kv_cache_manager_with_transfer.cc:191-215`) |
| `pushEnd`      | `EndRecvOp` from `end_incoming_push` (`kv_cache_manager_with_transfer.cc:216-239`) |
| `pullReply ok` | `on_response` of `ExecutePullRequest` (`.cc:476-505`): `Finish` on error, then the `absl::Cleanup` ends the op. Also the fault-injected `Finish(status); EndRecvOp()` in `StartRead` (`kv_cache_manager_with_transfer.cc:886-892`) |
| `h2dBegin`     | `ExecuteLayerH2d`, first critical section (`.cc:580-592`) |
| `h2dIssue ok`  | `ExecuteLayerH2d` from the re-check on (`.cc:601-632`) |
| `h2dDone ok`   | H2D completion callback (`.cc:635-693`) |
| `finish ok`    | `Finish` from outside the session: `CompleteReadRaw` poll and deadline (`kv_cache_manager_with_transfer.cc:956-968`), cancel (`:335-350`), plan unregister (`:692`), `OnBlocksReceived` all-complete (`.cc:556-563`) |

## Assumptions

* **A1 (transport).** `OnLayerReceived` fires at most once per layer, so
  `ExecuteLayerH2d` is entered at most `numLayers` times. Encoded as the
  `h2dBegin` guard `issued + pending < numLayers`.
* **A2 (registration).** The session has blocks to receive and is registered.
  `ReleaseStaging()` is only called from outside on registration failure
  (`kv_cache_manager_with_transfer.cc:519,565,865`), before the session is
  visible to anyone, so it is not an event here.
* **A3 (no double end).** Every op ends at most once, so `in_flight_` never
  underflows. `h2dDone` is only enabled while a callback is outstanding and
  `pushEnd` only while a push is open.

## Properties

All proved on every reachable state (`reachable_inv`, `reachable_safe`):

* **Settle safety.** `done → inFlight = 0`: a settled session owns no work, so
  its blocks and staging can be reused. This is the guarantee the comment at
  `.cc:602-606` relies on ("a copy already handed to the device cannot be
  revoked; its in-flight count keeps the receive owned until the copy ends").
* **No retired callback.** `done → retired = issued`: the
  `LOG(DFATAL) << "H2D callback for retired receive"` at `.cc:651-653` is
  unreachable.
* **Staging integrity.** `hasStaging = !done`: staging is held exactly until
  settle.
* **Prompt settle.** `draining → inFlight = 0 → done`: the last op to end
  settles the session; nothing is left for the sweeper.
* **Counters.** `completed ≤ retired ≤ issued ≤ numLayers`.
-/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)

structure Recv where
  numLayers : Nat
  life : Lifecycle := {}
  issued : Nat := 0
  completed : Nat := 0
  pushes : Nat := 0
  pullPending : Bool := false
  pending : Nat := 0
  retired : Nat := 0
  deriving Repr, DecidableEq

namespace Recv

/-- A receiver registered from a push plan (`InitFromActivePlan`): nothing in
flight until the transport starts pushing. -/
def initPush (numLayers : Nat) : Recv := { numLayers }

/-- A receiver created by `StartRead` (`InitFromLoadPlan`, `.cc:331-350`):
`in_flight_ = 1` for the pull handshake (`.cc:342`). -/
def initLoad (numLayers : Nat) : Recv :=
  { numLayers, life := { inFlight := 1 }, pullPending := true }

inductive Ev where
  | pushBegin
  | pushEnd
  | pullReply (ok : Bool)
  | h2dBegin
  | h2dIssue (ok : Bool)
  | h2dDone (ok : Bool)
  | finish (ok : Bool)
  deriving Repr, DecidableEq

/-- `TryBeginRecvOp`. When it returns `false` the transport drops the push and
the session is unchanged, so only the accepting case is a transition. -/
def pushBegin (s : Recv) : Option Recv :=
  s.life.beginOp.map fun l => { s with life := l, pushes := s.pushes + 1 }

/-- `EndRecvOp` for a push that was accepted. -/
def pushEnd (s : Recv) : Option Recv :=
  if s.pushes = 0 then none
  else some { s with life := s.life.endOpLocked, pushes := s.pushes - 1 }

/-- The pull handshake resolves: `Finish(pull_status)` if it failed
(`.cc:502-504`), then the `absl::Cleanup` at `.cc:478` ends the op. -/
def pullReply (ok : Bool) (s : Recv) : Option Recv :=
  if s.pullPending = false then none
  else
    let l := if ok then s.life else s.life.finishLocked false
    some { s with life := l.endOpLocked, pullPending := false }

/-- `ExecuteLayerH2d` up to the first unlock (`.cc:580-592`): refused once
settled or draining, otherwise `++in_flight_`. -/
def h2dBegin (s : Recv) : Option Recv :=
  if s.issued + s.pending < s.numLayers then
    s.life.beginOp.map fun l => { s with life := l, pending := s.pending + 1 }
  else none

/-- `ExecuteLayerH2d` from the re-check on. If the session finished in the
window between the two locks, the op is released and no copy is issued
(`.cc:607-611`). Otherwise the copy is dispatched: on failure
`FinishLocked(status); EndRecvOpLocked()` (`.cc:621-626`); on success its
future joins `h2d_futures_` (`.cc:629-632`) and the op stays in flight until
the callback. -/
def h2dIssue (ok : Bool) (s : Recv) : Option Recv :=
  if s.pending = 0 then none
  else
    let s := { s with pending := s.pending - 1 }
    if s.life.done = true ∨ s.life.draining = true then
      some { s with life := s.life.endOpLocked }
    else if ok then
      some { s with issued := s.issued + 1 }
    else
      some { s with life := (s.life.finishLocked false).endOpLocked }

/-- H2D completion callback (`.cc:635-693`). The `absl::Cleanup` at `.cc:644`
ends the op on every path. On a retired session the body returns early
(`.cc:651-654`, DFATAL). On success `num_completed_layers_++`; the last layer
finishes the session unless it is already draining (`.cc:658-665`). On failure
`FinishLocked(status)` (`.cc:670`). -/
def h2dDone (ok : Bool) (s : Recv) : Option Recv :=
  if s.retired < s.issued then
    let s := { s with retired := s.retired + 1 }
    if s.life.done = true then
      some { s with life := s.life.endOpLocked }
    else if ok then
      let s := { s with completed := s.completed + 1 }
      let l := if s.completed = s.numLayers ∧ s.life.draining = false
               then s.life.finishLocked true else s.life
      some { s with life := l.endOpLocked }
    else
      some { s with life := (s.life.finishLocked false).endOpLocked }
  else none

/-- `Finish(status)` from outside the session; enabled at any time. -/
def finish (ok : Bool) (s : Recv) : Option Recv :=
  some { s with life := s.life.finishLocked ok }

def step (s : Recv) : Ev → Option Recv
  | .pushBegin => s.pushBegin
  | .pushEnd => s.pushEnd
  | .pullReply ok => s.pullReply ok
  | .h2dBegin => s.h2dBegin
  | .h2dIssue ok => s.h2dIssue ok
  | .h2dDone ok => s.h2dDone ok
  | .finish ok => s.finish ok

/-- A push-plan receiver with `n` layers. -/
def sysPush (n : Nat) : System Recv Ev := ⟨initPush n, step⟩

/-- A StartRead receiver with `n` layers. -/
def sysLoad (n : Nat) : System Recv Ev := ⟨initLoad n, step⟩

/-! ## Properties -/

def SettleSafe (s : Recv) : Prop := s.life.done = true → s.life.inFlight = 0

def NoRetiredCallback (s : Recv) : Prop := s.life.done = true → s.retired = s.issued

def StagingIntegrity (s : Recv) : Prop := s.life.hasStaging = !s.life.done

def SettlesPromptly (s : Recv) : Prop :=
  s.life.draining = true → s.life.inFlight = 0 → s.life.done = true

def CountersOrdered (s : Recv) : Prop :=
  s.completed ≤ s.retired ∧ s.retired ≤ s.issued ∧ s.issued ≤ s.numLayers

/-- Everything we want to know about a reachable receive session. -/
def Safe (s : Recv) : Prop :=
  SettleSafe s ∧ NoRetiredCallback s ∧ StagingIntegrity s ∧ SettlesPromptly s ∧
    CountersOrdered s

/-! ## Inductive invariant -/

/-- Where every unit of `in_flight_` comes from: an open push, the pull
handshake, a dispatch between its two locks, or a copy whose callback has not
run. -/
def Accounted (s : Recv) : Prop :=
  s.life.inFlight =
    s.pushes + (if s.pullPending then 1 else 0) + s.pending + (s.issued - s.retired)

structure Inv (s : Recv) : Prop where
  life : s.life.Consistent
  accounted : Accounted s
  completed_le : s.completed ≤ s.retired
  retired_le : s.retired ≤ s.issued
  issued_le : s.issued + s.pending ≤ s.numLayers

theorem inv_initPush (n : Nat) : Inv (initPush n) := by
  refine ⟨Lifecycle.consistent_init, ?_, ?_, ?_, ?_⟩ <;> simp [initPush, Accounted]

theorem inv_initLoad (n : Nat) : Inv (initLoad n) := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩ <;> simp [initLoad, Accounted]
  constructor <;> simp

theorem inv_safe {s : Recv} (h : Inv s) : Safe s := by
  obtain ⟨hl, hacc, hc, hr, hi⟩ := h
  refine ⟨hl.done_idle, ?_, hl.staging, hl.prompt, hc, hr, by omega⟩
  intro hd
  have h0 := hl.done_idle hd
  unfold Accounted at hacc
  omega

/-- Each event preserves the invariant. One case per event; the `Lifecycle`
lemmas discharge the settle protocol and `omega` the accounting. -/
theorem step_inv {s s' : Recv} {e : Ev} (h : Inv s) (hs : step s e = some s') : Inv s' := by
  obtain ⟨hl, hacc, hc, hr, hi⟩ := h
  unfold Accounted at hacc
  cases e with
  | pushBegin =>
    simp only [step, pushBegin, Option.map_eq_some_iff] at hs
    obtain ⟨l, hb, rfl⟩ := hs
    have := Lifecycle.beginOp_inFlight hb
    refine ⟨Lifecycle.beginOp_consistent hl hb, ?_, hc, hr, hi⟩
    unfold Accounted; simp; omega
  | pushEnd =>
    simp only [step, pushEnd] at hs
    split at hs
    · cases hs
    · cases hs
      refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hc, hr, hi⟩
      unfold Accounted; simp; omega
  | pullReply ok =>
    simp only [step, pullReply] at hs
    split at hs
    · cases hs
    · rename_i hp
      cases hs
      have hp' : s.pullPending = true := by
        cases hq : s.pullPending
        · exact absurd hq hp
        · rfl
      refine ⟨?_, ?_, hc, hr, hi⟩
      · apply Lifecycle.endOpLocked_consistent
        split
        · exact hl
        · exact Lifecycle.finishLocked_consistent _ hl
      · unfold Accounted
        cases ok <;> simp [hp'] at hacc ⊢ <;> omega
  | h2dBegin =>
    simp only [step, h2dBegin] at hs
    split at hs
    · simp only [Option.map_eq_some_iff] at hs
      obtain ⟨l, hb, rfl⟩ := hs
      have := Lifecycle.beginOp_inFlight hb
      refine ⟨Lifecycle.beginOp_consistent hl hb, ?_, hc, hr, by simp; omega⟩
      unfold Accounted; simp; omega
    · cases hs
  | h2dIssue ok =>
    simp only [step, h2dIssue] at hs
    split at hs
    · cases hs
    · rename_i hp
      split at hs
      · cases hs
        refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hc, hr, by simp; omega⟩
        unfold Accounted; simp; omega
      · split at hs
        · cases hs
          refine ⟨hl, ?_, hc, by simp; omega, by simp; omega⟩
          unfold Accounted; simp; omega
        · cases hs
          refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishLocked_consistent _ hl),
            ?_, hc, hr, by simp; omega⟩
          unfold Accounted; simp; omega
  | h2dDone ok =>
    simp only [step, h2dDone] at hs
    split at hs
    · rename_i hlt
      split at hs
      · cases hs
        refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, by simp; omega, by simp; omega, hi⟩
        unfold Accounted; simp; omega
      · split at hs
        · cases hs
          refine ⟨?_, ?_, by simp; omega, by simp; omega, hi⟩
          · apply Lifecycle.endOpLocked_consistent
            split
            · exact Lifecycle.finishLocked_consistent _ hl
            · exact hl
          · unfold Accounted
            split <;> (try simp) <;> omega
        · cases hs
          refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishLocked_consistent _ hl),
            ?_, by simp; omega, by simp; omega, hi⟩
          unfold Accounted; simp; omega
    · cases hs
  | finish ok =>
    simp only [step, finish] at hs
    cases hs
    refine ⟨Lifecycle.finishLocked_consistent _ hl, ?_, hc, hr, hi⟩
    unfold Accounted; simp; omega

theorem reachable_inv_push {n : Nat} {s : Recv} (h : (sysPush n).Reachable s) : Inv s :=
  (sysPush n).reachable_induction (inv_initPush n) (fun _ _ _ hi hs => step_inv hi hs) h

theorem reachable_inv_load {n : Nat} {s : Recv} (h : (sysLoad n).Reachable s) : Inv s :=
  (sysLoad n).reachable_induction (inv_initLoad n) (fun _ _ _ hi hs => step_inv hi hs) h

/-- Main result: every reachable receive session, on either creation path,
satisfies all five properties. -/
theorem reachable_safe {n : Nat} {s : Recv}
    (h : (sysPush n).Reachable s ∨ (sysLoad n).Reachable s) : Safe s :=
  inv_safe (h.elim reachable_inv_push reachable_inv_load)

/-! ## Replay and bounded search

Concrete traces, checked by `decide`, that document the behaviours the model
admits; and a bounded search confirming that no `Safe` violation is reachable
within 10 events of either initial state. The inductive proof above is the
actual guarantee; the search guards against a modelling slip making the proof
vacuous. -/

/-- A two-layer StartRead that completes normally. -/
theorem trace_normal :
    ((sysLoad 2).run
      [.pullReply true, .h2dBegin, .h2dIssue true, .h2dBegin, .h2dIssue true,
       .h2dDone true, .h2dDone true]).map (fun s => (s.life.done, s.life.statusOk, s.completed))
      = some (true, true, 2) := by
  decide

/-- The deadline fires while a copy is in flight: the session drains but does
not settle until the copy's callback ends the op. -/
theorem trace_deadline_during_copy :
    ((sysLoad 1).run [.pullReply true, .h2dBegin, .h2dIssue true, .finish false]).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    ((sysLoad 1).run [.pullReply true, .h2dBegin, .h2dIssue true, .finish false, .h2dDone true]).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, true, false) := by
  decide

/-- The race the re-check at `.cc:601-612` closes: the session finishes between
the two locks of `ExecuteLayerH2d`, so no copy is issued and the op is released. -/
theorem trace_finish_between_locks :
    ((sysPush 1).run [.h2dBegin, .finish false, .h2dIssue true]).map
      (fun s => (s.issued, s.life.done)) = some (0, true) := by
  decide

/-- A push cannot start once the session is draining. -/
theorem trace_no_push_after_finish :
    (sysPush 1).run [.finish true, .pushBegin] = none := by
  decide

def events : List Ev :=
  [.pushBegin, .pushEnd, .pullReply true, .pullReply false, .h2dBegin,
   .h2dIssue true, .h2dIssue false, .h2dDone true, .h2dDone false,
   .finish true, .finish false]

/-- Executable negation of `Safe`. -/
def violates (s : Recv) : Bool :=
  (s.life.done && s.life.inFlight != 0) ||
  (s.life.done && s.retired != s.issued) ||
  (s.life.hasStaging != !s.life.done) ||
  (s.life.draining && s.life.inFlight == 0 && !s.life.done) ||
  !(s.completed ≤ s.retired && s.retired ≤ s.issued && s.issued ≤ s.numLayers)

#guard ModelCheck.check (sysLoad 2) events violates 10 = .outOfFuel
#guard ModelCheck.check (sysPush 2) events violates 10 = .outOfFuel

/-- Sanity check on the search itself: a `Finish` that settles at once, ignoring
in-flight work, must be caught. -/
def finishEager (s : Recv) : Option Recv :=
  some { s with life := { s.life with draining := true, done := true, hasStaging := false } }

#guard (match ModelCheck.check ⟨initPush 1, fun s e => match e with
          | .finish _ => finishEager s
          | e => step s e⟩ events violates 6 with
        | .counterexample _ => true
        | _ => false)

end Recv

end TpuSyncVerify.Transfer.PrefillDecode
