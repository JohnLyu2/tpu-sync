import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.Session

/-!
# Receive session

Stages 1-2 of the prefill-to-decode model: one `TransferReceiveSession` on the
decode (consumer) side and the slice of `KVCacheManagerWithTransfer` that
drives it. Stage 1 is the session lifecycle — how in-flight work is counted,
how the session drains and settles, when its host staging is released. Stage 2
adds the transport's block accounting, the readiness predicate
`IsReadyToComplete`, and the manager's poll that publishes `done_recving` /
`failed_recving`. Layer data, memory contents and the producer come in later
stages.

Citations are to tpu-sync `01ffa3d`. Unqualified `.h`/`.cc` are
`tpu_sync/core/transfer_receive_session.{h,cc}`; `mgr.cc` is
`tpu_sync/core/kv_cache_manager_with_transfer.cc`; `bt.cc` is
`tpu_sync/transport/block_transport.cc`.

## State

The settle protocol itself is `Transfer.Lifecycle`. On top of it:

| Field             | C++                                        | Role |
|-------------------|--------------------------------------------|------|
| `numLayers`       | `base_->num_layers()`                      | fixed |
| `issued`          | `h2d_futures_.size()` (`.h:248`)           | H2D copies handed to the device |
| `ready`           | futures in `h2d_futures_` with `IsReady()` | copies finished on the device |
| `completed`       | `num_completed_layers_` (`.h:238`)         | callbacks that ran with an OK status |
| `layersAccounted` | `num_completed_blocks_ / total_blocks_` (`.h:237`) | layers whose blocks the transport has reported |
| `published`       | membership in `done_recving_` / `failed_recving_` (`mgr.cc:971-973`) | what `poll_stats()` shows the engine |
| `pushes`          | ghost                                      | incoming pushes between `TryBeginRecvOp` and `EndRecvOp` |
| `pullPending`     | ghost                                      | the StartRead pull handshake still holds its op |
| `pending`         | ghost                                      | `ExecuteLayerH2d` calls between their first and second lock |
| `retired`         | ghost                                      | H2D callbacks that have run, OK or not |

Ghost fields have no single C++ variable. They record where each unit of
`in_flight_` came from, which is what `Accounted` is about.

`network_completed_` (`.h:239`) is not stored: it is exactly
`layersAccounted = numLayers` (`networkCompleted`), see
`RecordBlocksReceivedLocked` `.cc:447-449`.

## Events

| Event          | C++ |
|----------------|-----|
| `pushBegin`    | `TryBeginRecvOp` (`.h:109-114`) from `begin_incoming_push` (`mgr.cc:191-215`), called at `bt.cc:350` |
| `pushEnd`      | `EndRecvOp` from `end_incoming_push` (`mgr.cc:216-239`), called at `bt.cc:586` |
| `pullReply ok` | `on_response` of `ExecutePullRequest` (`.cc:476-505`): `Finish` on error, then the `absl::Cleanup` ends the op. Also the fault-injected `Finish(status); EndRecvOp()` in `StartRead` (`mgr.cc:886-892`) |
| `h2dBegin`     | `ExecuteLayerH2d`, first critical section (`.cc:580-592`), from `OnLayerReceived` (`bt.cc:575`, `mgr.cc:130-146`) |
| `h2dIssue ok`  | `ExecuteLayerH2d` from the re-check on (`.cc:601-632`) |
| `h2dReady`     | the device finishes a copy: its future becomes `IsReady()` |
| `h2dDone ok`   | H2D completion callback (`.cc:635-693`) |
| `netAccount`   | `OnBlocksReceived` (`.cc:525-573`) via `bt.cc:583-584` / `mgr.cc:1642-1659`: accounts a layer's blocks, may set `network_completed_`, and finishes the session if every layer is also complete (`.cc:556-563`) |
| `pollReady`    | `CompleteReadRaw` sees `IsReadyToComplete()` and calls `Finish()` (`mgr.cc:956-960`) |
| `cancel`       | any `Finish(error)` from outside the session: deadline (`mgr.cc:961-968`), shutdown (`mgr.cc:335-350`), plan unregister (`mgr.cc:692`) |
| `publish`      | `CompleteReadRaw` moves a settled session into `done_recving_` or `failed_recving_` by its status and drops it (`mgr.cc:971-978`) |

## Assumptions

* **A1 (one dispatch per layer).** `BlockTransport` fires `OnLayerReceived`
  once per layer (`on_layer_received_called`, `bt.cc:528-530`), so
  `ExecuteLayerH2d` is entered at most `numLayers` times. Encoded as the
  `h2dBegin` guard `issued + pending < numLayers`.
* **A2 (registration).** The session has blocks to receive and is registered.
  `ReleaseStaging()` is only called from outside on registration failure
  (`mgr.cc:519,565,865`), before the session is visible, so it is not an
  event here.
* **A3 (no double end).** Every op ends at most once, so `in_flight_` never
  underflows: `h2dDone` is only enabled while a callback is outstanding,
  `pushEnd` only while a push is open.
* **A4 (transport ordering).** For the request that completes a layer,
  `HandleCustomRequest` calls `OnLayerReceived` (`bt.cc:570-577`) before
  `OnBlocksReceived` (`bt.cc:583-584`), on the same thread, and
  `ExecuteLayerH2d` pushes the future into `h2d_futures_` before returning
  (`.cc:629-632`). A layer's blocks are accounted as one event once its copy is
  issued: guard `layersAccounted < issued`. With several senders per layer the
  real counter can grow before `OnLayerReceived`, but it can only *reach* the
  threshold `total_blocks_ * num_layers` (`.cc:447-448`) after the last layer's
  final request, which is the ordered one; lumping each layer's accounting into
  that event is sound for everything proved here.

## Properties

All proved on every reachable state (`reachable_safe`):

* **Settle safety.** `done → inFlight = 0`: a settled session owns no work, so
  its blocks and staging can be reused. This is what the comment at
  `.cc:602-606` relies on ("a copy already handed to the device cannot be
  revoked; its in-flight count keeps the receive owned until the copy ends").
* **No retired callback.** `done → retired = issued`: the
  `LOG(DFATAL) << "H2D callback for retired receive"` at `.cc:651-653` is
  unreachable.
* **Staging integrity.** `hasStaging = !done`.
* **Prompt settle.** `draining → inFlight = 0 → done`.
* **Readiness is sound.** `IsReadyToComplete → ready = numLayers`: when the
  poll decides the receive is complete, every layer's copy has been issued
  *and* has finished on the device. The `network_completed_` disjunct is
  sound only because of A4 (see `HypotheticalReordering` in the v1 archive for
  what breaks without it).
* **Publication.** `published = some true → completed = numLayers`: when the
  engine is told `done_recving`, every layer's H2D callback has run with an
  OK status. Counter-level form of the proposal's *publication correctness*;
  stage 4 adds the memory contents.
* **Counters.** `completed ≤ retired ≤ ready ≤ issued ≤ numLayers` and
  `layersAccounted ≤ issued`.

Note on the readiness predicate. The v1 model proved its two readiness
variants equal; here they are not: `IsReadyToComplete` tests futures
(`ready`), callbacks (`retired`, `completed`) can lag behind, so the shipping
predicate can be true before `num_completed_layers_` reaches `numLayers`. That
is harmless — `done` still waits for every callback through `in_flight_` — and
the publication property above is the one that matters.
-/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)

structure Recv where
  numLayers : Nat
  life : Lifecycle := {}
  issued : Nat := 0
  ready : Nat := 0
  completed : Nat := 0
  layersAccounted : Nat := 0
  published : Option Bool := none
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

/-- `network_completed_` (`.cc:447-449`): every layer's blocks accounted. -/
def networkCompleted (s : Recv) : Prop := s.layersAccounted = s.numLayers

/-- `AllH2dDoneLocked` (`.cc:420-425`): every future in `h2d_futures_` is ready. -/
def allH2dDone (s : Recv) : Prop := s.ready = s.issued

/-- `IsReadyToComplete` (`.cc:427-433`). -/
def isReadyToComplete (s : Recv) : Prop :=
  (networkCompleted s ∨ s.completed = s.numLayers) ∧ allH2dDone s

instance : DecidablePred networkCompleted :=
  fun s => inferInstanceAs (Decidable (s.layersAccounted = s.numLayers))
instance : DecidablePred allH2dDone :=
  fun s => inferInstanceAs (Decidable (s.ready = s.issued))
instance : DecidablePred isReadyToComplete :=
  fun s => inferInstanceAs (Decidable ((networkCompleted s ∨ s.completed = s.numLayers) ∧ allH2dDone s))

inductive Ev where
  | pushBegin
  | pushEnd
  | pullReply (ok : Bool)
  | h2dBegin
  | h2dIssue (ok : Bool)
  | h2dReady
  | h2dDone (ok : Bool)
  | netAccount
  | pollReady
  | cancel
  | publish
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

/-- A dispatched copy finishes on the device; its future becomes ready. -/
def h2dReady (s : Recv) : Option Recv :=
  if s.ready < s.issued then some { s with ready := s.ready + 1 } else none

/-- H2D completion callback (`.cc:635-693`), run once per ready future. The
`absl::Cleanup` at `.cc:644` ends the op on every path. On a retired session
the body returns early (`.cc:651-654`, DFATAL). On success
`num_completed_layers_++`; the last layer finishes the session unless it is
already draining (`.cc:658-665`). On failure `FinishLocked(status)` (`.cc:670`). -/
def h2dDone (ok : Bool) (s : Recv) : Option Recv :=
  if s.retired < s.ready then
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

/-- `OnBlocksReceived` (`.cc:525-573`) for the request that completes a layer
(A4). Ignored once settled or draining (`.cc:537-539`). Otherwise the layer's
blocks are accounted (`.cc:440`); if that reaches the threshold
(`.cc:447-449`) and every layer's callback has also run (`.cc:451`), the
session finishes (`.cc:556-563`). -/
def netAccount (s : Recv) : Option Recv :=
  if s.life.done = true ∨ s.life.draining = true then none
  else if s.layersAccounted < s.issued then
    let s := { s with layersAccounted := s.layersAccounted + 1 }
    if networkCompleted s ∧ s.completed = s.numLayers then
      some { s with life := s.life.finishLocked true }
    else some s
  else none

/-- `CompleteReadRaw` polls a session that is not draining and finds it ready
(`mgr.cc:956-960`). -/
def pollReady (s : Recv) : Option Recv :=
  if s.life.draining = false ∧ isReadyToComplete s then
    some { s with life := s.life.finishLocked true }
  else none

/-- `Finish(error)` from outside the session; enabled at any time. -/
def cancel (s : Recv) : Option Recv :=
  some { s with life := s.life.finishLocked false }

/-- `CompleteReadRaw` publishes a settled session (`mgr.cc:971-978`). -/
def publish (s : Recv) : Option Recv :=
  if s.life.done = true ∧ s.published = none then
    some { s with published := some s.life.statusOk }
  else none

def step (s : Recv) : Ev → Option Recv
  | .pushBegin => s.pushBegin
  | .pushEnd => s.pushEnd
  | .pullReply ok => s.pullReply ok
  | .h2dBegin => s.h2dBegin
  | .h2dIssue ok => s.h2dIssue ok
  | .h2dReady => s.h2dReady
  | .h2dDone ok => s.h2dDone ok
  | .netAccount => s.netAccount
  | .pollReady => s.pollReady
  | .cancel => s.cancel
  | .publish => s.publish

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

def ReadinessSound (s : Recv) : Prop := isReadyToComplete s → s.ready = s.numLayers

def Publication (s : Recv) : Prop := s.published = some true → s.completed = s.numLayers

def CountersOrdered (s : Recv) : Prop :=
  s.completed ≤ s.retired ∧ s.retired ≤ s.ready ∧ s.ready ≤ s.issued ∧
    s.issued ≤ s.numLayers ∧ s.layersAccounted ≤ s.issued

/-- Everything we want to know about a reachable receive session. -/
def Safe (s : Recv) : Prop :=
  SettleSafe s ∧ NoRetiredCallback s ∧ StagingIntegrity s ∧ SettlesPromptly s ∧
    ReadinessSound s ∧ Publication s ∧ CountersOrdered s

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
  retired_le : s.retired ≤ s.ready
  ready_le : s.ready ≤ s.issued
  issued_le : s.issued + s.pending ≤ s.numLayers
  accounted_le : s.layersAccounted ≤ s.issued
  /-- While no error has been recorded, every callback that ran succeeded. -/
  ok_completed : s.life.statusOk = true → s.completed = s.retired
  /-- A session that started draining without an error had issued every layer. -/
  ok_draining : s.life.statusOk = true → s.life.draining = true → s.issued = s.numLayers
  /-- Only settled sessions are published. -/
  published_done : ∀ b, s.published = some b → s.life.done = true
  /-- Once published as done, every layer had completed (and still has). -/
  published_ok : s.published = some true → s.completed = s.numLayers

theorem inv_initPush (n : Nat) : Inv (initPush n) := by
  refine ⟨Lifecycle.consistent_init, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;>
    simp [initPush, Accounted]

theorem inv_initLoad (n : Nat) : Inv (initLoad n) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [initLoad, Accounted]
  constructor <;> simp

theorem inv_safe {s : Recv} (h : Inv s) : Safe s := by
  obtain ⟨hl, hacc, hc, hr, hy, hi, ha, hok, hdr, _, hpub⟩ := h
  unfold Accounted at hacc
  refine ⟨hl.done_idle, ?_, hl.staging, hl.prompt, ?_, hpub, hc, hr, hy, by omega, ha⟩
  · intro hd
    have h0 := hl.done_idle hd
    omega
  · rintro ⟨hnet | hcomp, hall⟩
    · unfold networkCompleted at hnet; unfold allH2dDone at hall; omega
    · unfold allH2dDone at hall; omega

/-- Each event preserves the invariant. One case per event; the `Lifecycle`
lemmas discharge the settle protocol and `omega` the arithmetic. -/
theorem step_inv {s s' : Recv} {e : Ev} (h : Inv s) (hs : step s e = some s') : Inv s' := by
  obtain ⟨hl, hacc, hc, hr, hy, hi, ha, hok, hdr, hpd, hpub⟩ := h
  unfold Accounted at hacc
  cases e with
  | pushBegin =>
    simp only [step, pushBegin, Option.map_eq_some_iff] at hs
    obtain ⟨l, hb, rfl⟩ := hs
    have := Lifecycle.beginOp_inFlight hb
    have hact := Lifecycle.beginOp_active hb
    have hok' := Lifecycle.beginOp_statusOk hb
    have hdr' := Lifecycle.beginOp_draining hb
    refine ⟨Lifecycle.beginOp_consistent hl hb, ?_, hc, hr, hy, hi, ha, ?_, ?_, ?_, hpub⟩
    · unfold Accounted; simp; omega
    · simpa [hok'] using hok
    · simp [hdr']
    · intro b hp
      have := hpd b hp
      simp [hact.1] at this
  | pushEnd =>
    simp only [step, pushEnd] at hs
    split at hs
    · cases hs
    · cases hs
      refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hc, hr, hy, hi, ha, ?_, ?_, ?_, hpub⟩
      · unfold Accounted; simp; omega
      · simpa using hok
      · simpa using hdr
      · exact fun b hp => Lifecycle.endOpLocked_done_mono (hpd b hp)
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
      refine ⟨?_, ?_, hc, hr, hy, hi, ha, ?_, ?_, ?_, hpub⟩
      · apply Lifecycle.endOpLocked_consistent
        split
        · exact hl
        · exact Lifecycle.finishLocked_consistent _ hl
      · unfold Accounted
        cases ok <;> simp [hp'] at hacc ⊢ <;> omega
      · cases ok <;> simp <;> exact hok
      · cases ok <;> simp
        · exact hdr
      · intro b hp
        have hd := hpd b hp
        apply Lifecycle.endOpLocked_done_mono
        split
        · exact hd
        · exact Lifecycle.finishLocked_done_mono _ hd
  | h2dBegin =>
    simp only [step, h2dBegin] at hs
    split at hs
    · simp only [Option.map_eq_some_iff] at hs
      obtain ⟨l, hb, rfl⟩ := hs
      have := Lifecycle.beginOp_inFlight hb
      have hact := Lifecycle.beginOp_active hb
      have hok' := Lifecycle.beginOp_statusOk hb
      have hdr' := Lifecycle.beginOp_draining hb
      refine ⟨Lifecycle.beginOp_consistent hl hb, ?_, hc, hr, hy, by simp; omega, ha, ?_, ?_, ?_,
        hpub⟩
      · unfold Accounted; simp; omega
      · simpa [hok'] using hok
      · simp [hdr']
      · intro b hp
        have := hpd b hp
        simp [hact.1] at this
    · cases hs
  | h2dIssue ok =>
    simp only [step, h2dIssue] at hs
    split at hs
    · cases hs
    · rename_i hp
      split at hs
      · cases hs
        refine ⟨Lifecycle.endOpLocked_consistent hl, ?_, hc, hr, hy, by simp; omega, ha, ?_, ?_, ?_,
          hpub⟩
        · unfold Accounted; simp; omega
        · simpa using hok
        · simpa using hdr
        · exact fun b hp => Lifecycle.endOpLocked_done_mono (hpd b hp)
      · rename_i hact
        split at hs
        · cases hs
          refine ⟨hl, ?_, hc, hr, by simp; omega, by simp; omega, by simp; omega, hok, ?_, hpd, hpub⟩
          · unfold Accounted; simp; omega
          · intro _ hd
            exact absurd (Or.inr hd) hact
        · cases hs
          refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishLocked_consistent _ hl),
            ?_, hc, hr, hy, by simp; omega, ha, ?_, ?_, ?_, hpub⟩
          · unfold Accounted; simp; omega
          · simp
          · simp
          · exact fun b hp =>
              Lifecycle.endOpLocked_done_mono (Lifecycle.finishLocked_done_mono _ (hpd b hp))
  | h2dReady =>
    simp only [step, h2dReady] at hs
    split at hs
    · cases hs
      exact ⟨hl, by unfold Accounted; simpa using hacc, hc, by simp; omega, by simp; omega,
        hi, ha, hok, hdr, hpd, hpub⟩
    · cases hs
  | h2dDone ok =>
    simp only [step, h2dDone] at hs
    split at hs
    · rename_i hlt
      split at hs
      · rename_i hd
        -- the DFATAL branch: unreachable, since done forces retired = issued
        have h0 := hl.done_idle hd
        omega
      · rename_i hnd
        split at hs
        · cases hs
          refine ⟨?_, ?_, by simp; omega, by simp; omega, hy, hi, ha, ?_, ?_, ?_, ?_⟩
          · apply Lifecycle.endOpLocked_consistent
            split
            · exact Lifecycle.finishLocked_consistent _ hl
            · exact hl
          · unfold Accounted
            split <;> (try simp) <;> omega
          · split <;> simp <;> intro h1 <;> have := hok h1 <;> omega
          · split
            · rename_i hfin
              obtain ⟨hfin, _⟩ := hfin
              intro _ _
              simp
              omega
            · simp
              intro h1 h2
              exact hdr h1 h2
          · intro b hp
            exact absurd (hpd b hp) hnd
          · intro hp
            exact absurd (hpd true hp) hnd
        · cases hs
          refine ⟨Lifecycle.endOpLocked_consistent (Lifecycle.finishLocked_consistent _ hl),
            ?_, by simp; omega, by simp; omega, hy, hi, ha, ?_, ?_, ?_, hpub⟩
          · unfold Accounted; simp; omega
          · simp
          · simp
          · intro b hp
            exact absurd (hpd b hp) hnd
    · cases hs
  | netAccount =>
    simp only [step, netAccount] at hs
    split at hs
    · cases hs
    · rename_i hact
      split at hs
      · split at hs
        · rename_i hfin
          cases hs
          refine ⟨Lifecycle.finishLocked_consistent _ hl, ?_, hc, hr, hy, hi, by simp; omega,
            ?_, ?_, ?_, hpub⟩
          · unfold Accounted; simpa using hacc
          · simpa using hok
          · intro _ _
            simp
            omega
          · exact fun b hp => Lifecycle.finishLocked_done_mono _ (hpd b hp)
        · cases hs
          refine ⟨hl, ?_, hc, hr, hy, hi, by simp; omega, hok, ?_, hpd, hpub⟩
          · unfold Accounted; simpa using hacc
          · simpa using hdr
      · cases hs
  | pollReady =>
    simp only [step, pollReady] at hs
    split at hs
    · rename_i hrd
      obtain ⟨hndr, hnet | hcomp, hall⟩ := hrd
      · cases hs
        refine ⟨Lifecycle.finishLocked_consistent _ hl, ?_, hc, hr, hy, hi, ha, ?_, ?_, ?_, hpub⟩
        · unfold Accounted; simpa using hacc
        · simpa using hok
        · unfold networkCompleted at hnet; unfold allH2dDone at hall
          intro _ _; simp; omega
        · exact fun b hp => Lifecycle.finishLocked_done_mono _ (hpd b hp)
      · cases hs
        refine ⟨Lifecycle.finishLocked_consistent _ hl, ?_, hc, hr, hy, hi, ha, ?_, ?_, ?_, hpub⟩
        · unfold Accounted; simpa using hacc
        · simpa using hok
        · intro _ _; simp; omega
        · exact fun b hp => Lifecycle.finishLocked_done_mono _ (hpd b hp)
    · cases hs
  | cancel =>
    simp only [step, cancel] at hs
    cases hs
    refine ⟨Lifecycle.finishLocked_consistent _ hl, ?_, hc, hr, hy, hi, ha, ?_, ?_, ?_, hpub⟩
    · unfold Accounted; simpa using hacc
    · simp
    · simp
    · exact fun b hp => Lifecycle.finishLocked_done_mono _ (hpd b hp)
  | publish =>
    simp only [step, publish] at hs
    split at hs
    · rename_i hd
      obtain ⟨hdone, _⟩ := hd
      cases hs
      refine ⟨hl, by unfold Accounted; simpa using hacc, hc, hr, hy, hi, ha, hok, hdr,
        fun _ _ => hdone, ?_⟩
      simp
      intro hst
      have h0 := hl.done_idle hdone
      have h1 := hok hst
      have h2 := hdr hst (hl.done_draining hdone)
      omega
    · cases hs

theorem reachable_inv_push {n : Nat} {s : Recv} (h : (sysPush n).Reachable s) : Inv s :=
  (sysPush n).reachable_induction (inv_initPush n) (fun _ _ _ hi hs => step_inv hi hs) h

theorem reachable_inv_load {n : Nat} {s : Recv} (h : (sysLoad n).Reachable s) : Inv s :=
  (sysLoad n).reachable_induction (inv_initLoad n) (fun _ _ _ hi hs => step_inv hi hs) h

/-- Main result: every reachable receive session, on either creation path,
satisfies all the properties. -/
theorem reachable_safe {n : Nat} {s : Recv}
    (h : (sysPush n).Reachable s ∨ (sysLoad n).Reachable s) : Safe s :=
  inv_safe (h.elim reachable_inv_push reachable_inv_load)

/-! ## Frame lemmas

What each event leaves alone, and exact specs for the two events the
composed transfer model (`Pipeline.lean`) attaches memory effects to. Each is
proved by unfolding `step` for every event and splitting every branch. -/

/-- Unfold `step` for a known event and split every branch, leaving `hs` as
`some … = some s'` or, for `beginOp` branches, the `Option.map` form. -/
macro "recv_cases" hs:ident : tactic =>
  `(tactic| (simp only [step, pushBegin, pushEnd, pullReply, h2dBegin, h2dIssue, h2dReady, h2dDone,
      netAccount, pollReady, cancel, publish] at $hs:ident <;> (repeat' split at $hs:ident)))

theorem step_numLayers {s s' : Recv} {e : Ev} (hs : step s e = some s') :
    s'.numLayers = s.numLayers := by
  cases e <;> recv_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> (repeat' split) <;> rfl)

theorem step_done_mono {s s' : Recv} {e : Ev} (hs : step s e = some s') (hd : s.life.done = true) :
    s'.life.done = true := by
  cases e <;> simp only [step, pushBegin, pushEnd, pullReply, h2dBegin, h2dIssue, h2dReady, h2dDone,
      netAccount, pollReady, cancel, publish, Lifecycle.beginOp_of_done hd, Option.map_none] at hs <;>
    (repeat' split at hs) <;> cases hs <;>
    simp [hd, Lifecycle.endOpLocked_done_mono, Lifecycle.finishLocked_done_mono]

theorem step_published_mono {s s' : Recv} {e : Ev} {b : Bool} (hs : step s e = some s')
    (hp : s.published = some b) : s'.published = some b := by
  cases e <;> recv_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; simpa using hp)
    | (cases hs <;> (repeat' split) <;> simp_all)

/-- Only `h2dBegin` claims a new layer for the device. -/
theorem step_issued_pending {s s' : Recv} {e : Ev} (hs : step s e = some s') (he : e ≠ .h2dBegin) :
    s'.issued + s'.pending ≤ s.issued + s.pending := by
  cases e <;> (try exact absurd rfl he) <;> recv_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; simp)
    | (cases hs <;> (repeat' split) <;> simp <;> omega)

theorem h2dBegin_issued_pending {s s' : Recv} (hs : step s .h2dBegin = some s') :
    s'.issued + s'.pending = s.issued + s.pending + 1 := by
  simp only [step, h2dBegin] at hs
  split at hs
  · simp only [Option.map_eq_some_iff] at hs
    obtain ⟨l, _, rfl⟩ := hs; simp; omega
  · cases hs

/-- Only `h2dReady` lands a layer in HBM. -/
theorem step_ready {s s' : Recv} {e : Ev} (hs : step s e = some s') (he : e ≠ .h2dReady) :
    s'.ready = s.ready := by
  cases e <;> (try exact absurd rfl he) <;> recv_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> (repeat' split) <;> rfl)

theorem h2dReady_spec {s s' : Recv} (hs : step s .h2dReady = some s') :
    s.ready < s.issued ∧ s' = { s with ready := s.ready + 1 } := by
  simp only [step, h2dReady] at hs
  split at hs
  · cases hs; exact ⟨‹_›, rfl⟩
  · cases hs

/-! ## Replay and bounded search

Concrete traces, checked by `decide`, that document the behaviours the model
admits; and a bounded search confirming that no `Safe` violation is reachable
within a few events of either initial state. The inductive proof above is the
actual guarantee; the search guards against a modelling slip making the proof
vacuous. -/

/-- A two-layer push receive that completes through the poll and is published
as done. -/
theorem trace_normal :
    ((sysPush 2).run
      [.pushBegin, .h2dBegin, .h2dIssue true, .netAccount, .pushEnd,
       .pushBegin, .h2dBegin, .h2dIssue true, .netAccount, .pushEnd,
       .h2dReady, .h2dReady, .h2dDone true, .h2dDone true, .publish]).map
      (fun s => (s.life.done, s.published, s.completed)) = some (true, some true, 2) := by
  decide

/-- The poll can see `IsReadyToComplete` before the callbacks run; the session
drains but is not published until they have. -/
theorem trace_poll_before_callbacks :
    ((sysPush 1).run
      [.pushBegin, .h2dBegin, .h2dIssue true, .netAccount, .pushEnd, .h2dReady, .pollReady]).map
      (fun s => (s.life.draining, s.life.done, s.completed)) = some (true, false, 0) ∧
    (sysPush 1).run
      [.pushBegin, .h2dBegin, .h2dIssue true, .netAccount, .pushEnd, .h2dReady, .pollReady,
       .publish] = none ∧
    ((sysPush 1).run
      [.pushBegin, .h2dBegin, .h2dIssue true, .netAccount, .pushEnd, .h2dReady, .pollReady,
       .h2dDone true, .publish]).map
      (fun s => (s.published, s.completed)) = some (some true, 1) := by
  decide

/-- The deadline fires while a copy is in flight: the session drains but does
not settle until the copy's callback ends the op, and is then published as
failed. -/
theorem trace_deadline_during_copy :
    ((sysLoad 1).run [.pullReply true, .h2dBegin, .h2dIssue true, .cancel]).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    ((sysLoad 1).run
      [.pullReply true, .h2dBegin, .h2dIssue true, .cancel, .h2dReady, .h2dDone true, .publish]).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) := by
  decide

/-- The race the re-check at `.cc:601-612` closes: the session finishes between
the two locks of `ExecuteLayerH2d`, so no copy is issued and the op is released. -/
theorem trace_finish_between_locks :
    ((sysPush 1).run [.h2dBegin, .cancel, .h2dIssue true]).map
      (fun s => (s.issued, s.life.done)) = some (0, true) := by
  decide

/-- A push cannot start once the session is draining. -/
theorem trace_no_push_after_finish :
    (sysPush 1).run [.cancel, .pushBegin] = none := by
  decide

def events : List Ev :=
  [.pushBegin, .pushEnd, .pullReply true, .pullReply false, .h2dBegin,
   .h2dIssue true, .h2dIssue false, .h2dReady, .h2dDone true, .h2dDone false,
   .netAccount, .pollReady, .cancel, .publish]

/-- Executable negation of `Safe`. -/
def violates (s : Recv) : Bool :=
  (s.life.done && s.life.inFlight != 0) ||
  (s.life.done && s.retired != s.issued) ||
  (s.life.hasStaging != !s.life.done) ||
  (s.life.draining && s.life.inFlight == 0 && !s.life.done) ||
  (decide (isReadyToComplete s) && s.ready != s.numLayers) ||
  (s.published == some true && s.completed != s.numLayers) ||
  !(s.completed ≤ s.retired && s.retired ≤ s.ready && s.ready ≤ s.issued &&
    s.issued ≤ s.numLayers && s.layersAccounted ≤ s.issued)

#guard ModelCheck.check (sysLoad 2) events violates 10 = .outOfFuel
#guard ModelCheck.check (sysPush 2) events violates 10 = .outOfFuel

/-- Sanity check on the search itself: a `Finish` that settles at once, ignoring
in-flight work, must be caught. -/
def cancelEager (s : Recv) : Option Recv :=
  some { s with life := { s.life with draining := true, done := true, hasStaging := false } }

#guard (match ModelCheck.check ⟨initPush 1, fun s e => match e with
          | .cancel => cancelEager s
          | e => step s e⟩ events violates 6 with
        | .counterexample _ => true
        | _ => false)

/-- And the point of A4: let the transport account a layer before its copy is
issued and `IsReadyToComplete` becomes unsound. -/
def netAccountUnordered (s : Recv) : Option Recv :=
  if s.life.done = true ∨ s.life.draining = true then none
  else if s.layersAccounted < s.numLayers then
    some { s with layersAccounted := s.layersAccounted + 1 }
  else none

#guard (match ModelCheck.check ⟨initPush 1, fun s e => match e with
          | .netAccount => netAccountUnordered s
          | e => step s e⟩ events violates 6 with
        | .counterexample _ => true
        | _ => false)

end Recv

end TpuSyncVerify.Transfer.PrefillDecode
