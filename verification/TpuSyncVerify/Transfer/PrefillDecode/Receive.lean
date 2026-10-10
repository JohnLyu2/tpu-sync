import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.Session

/-!
# Receive session

Consumer side of the prefill-to-decode model: one `TransferReceiveSession` on
the decode (consumer) side and the slice of `KVCacheManagerWithTransfer` that
drives it. Models the session lifecycle — how in-flight work is counted,
how the session drains and settles, when its host staging is released — along
with the transport's block accounting, the readiness predicate
`IsReadyToComplete`, and the manager's poll that publishes `done_recving` /
`failed_recving`. Layer data, memory contents and the producer are modelled in
`Send.lean` and `Pipeline.lean`.

Citations are to tpu-sync `1fa06d1`. Unqualified `.h`/`.cc` are
`tpu_sync/kv_cache/transfer_receive_session.{h,cc}`; `mgr.cc` is
`tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`; `bt.cc` is
`tpu_sync/transport/block_transport.cc`.

## State

The settle protocol itself is `Transfer.Lifecycle`. On top of it:

| Field             | C++                                        | Role |
|-------------------|--------------------------------------------|------|
| `numLayers`       | `base_->num_layers()`                      | fixed |
| `issued`          | `h2d_futures_.size()` (`.h:278`)           | H2D copies handed to the device |
| `ready`           | futures in `h2d_futures_` with `IsReady()` | copies finished on the device |
| `completed`       | `num_completed_layers_` (`.h:267`)         | callbacks that ran with an OK status |
| `layersAccounted` | layers' worth of the per-shard threshold `total_blocks_ * num_layers` absorbed by the counters `blocks_received_per_shard_` (`.h:261-263`, `.cc:455-456`) | layers whose blocks the transport has reported |
| `published`       | membership in `done_recving_` / `failed_recving_` (`mgr.cc:983-985`) | what `poll_stats()` shows the engine |
| `pushes`          | ghost                                      | incoming pushes between `TryBeginRecvOp` and `EndRecvOp` |
| `pullPending`     | ghost                                      | the StartRead pull handshake still holds its op |
| `pending`         | ghost                                      | `ExecuteLayerH2d` calls between their first and second lock |
| `retired`         | ghost                                      | H2D callbacks that have run, OK or not |

Ghost fields have no single C++ variable. They record where each unit of
`in_flight_` came from, which is what `Accounted` is about.

`network_completed_` (`.h:268`) is not stored: it is exactly
`layersAccounted = numLayers` (`networkCompleted`), see
`RecordBlockShardsReceivedLocked` `.cc:465-471`. The C++ counts per shard
(`blocks_received_per_shard_[s]`, one `int64_t` per shard, `.h:260-265`): each
incoming push stream adds its block count to every shard it carries
(`.cc:457-464`), a shard completes at `total_blocks_ * num_layers`
(`.cc:455-456`), and `network_completed_` is set when every shard has
(`num_completed_shards_ == num_shards`, `.cc:465-471`). The model keeps the
per-layer view: one `netAccount` per layer, which is the coarsening A4 justifies.

## Events

| Event          | C++ |
|----------------|-----|
| `pushBegin`    | `TryBeginRecvOp` (`.h:116-121`) from `begin_incoming_push` (`mgr.cc:198-223`), called at `bt.cc:507` |
| `pushEnd`      | `EndRecvOp` from `end_incoming_push` (`mgr.cc:224-264`), called at `bt.cc:632`. Since `4efb0dd` the hook takes the push's status and, when it is not OK, runs `DeferUnregisterOnSettle(); Finish(status)` first (`mgr.cc:241-244`; the transport's cleanup passes `InternalError("Incoming push failed")` on any early return, `bt.cc:509-516`) — in the model, `cancel` followed by `pushEnd`, see `trace_push_lease_pins_staging_on_cancel` |
| `pullReply ok` | `on_response` of `ExecutePullRequest` (`.cc:516-545`): `Finish` on error, then the `absl::Cleanup` ends the op. Also the fault-injected `Finish(status); EndRecvOp()` in `StartRead` (`mgr.cc:899-905`) |
| `h2dBegin`     | `ExecuteLayerH2d`, first critical section (`.cc:620-632`), from `OnLayerReceived` (`bt.cc:789`, `mgr.cc:137-153`) |
| `h2dIssue ok`  | `ExecuteLayerH2d` from the re-check on (`.cc:641-672`) |
| `h2dReady`     | the device finishes a copy: its future becomes `IsReady()` |
| `h2dDone ok`   | H2D completion callback (`.cc:675-733`) |
| `netAccount`   | `OnBlockShardsReceived` (`.cc:565-613`) via `bt.cc:629-630` / `mgr.cc:1662-1686`: accounts a stream's blocks per shard, may set `network_completed_`, and finishes the session if every layer is also complete (`RecordNetworkCompleteLocked`, `.cc:475-493`, called at `.cc:602-603`) |
| `pollReady`    | `CompleteReadWithDetails` / `CompleteReadRaw` sees `IsReadyToComplete()` and calls `Finish()` (`mgr.cc:968-972`) |
| `cancel`       | any `Finish(error)` from outside the session: deadline (`mgr.cc:973-980`), shutdown (`mgr.cc:351-355`), plan unregister (`mgr.cc:705`) |
| `publish`      | `CompleteReadWithDetails` / `CompleteReadRaw` moves a settled session into `done_recving_` or `failed_recving_` by its status and drops it (`mgr.cc:983-992`) |

## Assumptions

* **A1 (one dispatch per layer).** `BlockTransport` fires `OnLayerReceived`
  once per layer (`on_layer_received_called`, `bt.cc:742-744`), so
  `ExecuteLayerH2d` is entered at most `numLayers` times. Encoded as the
  `h2dBegin` guard `issued + pending < numLayers`. The once-latch lives in the
  `{uuid, layer}` entry of `layer_progress_`, which the transport erases once
  every layer has been called (`bt.cc:764-778`); A1 therefore also assumes no
  sender re-pushes a uuid after its entries were retired while the receive is
  still live.
* **A2 (registration).** The session has blocks to receive and is registered.
  `ReleaseStaging()` is only called from outside on registration failure:
  `mgr.cc:532` and `:878` run before the session is seated, and if
  `base_->RegisterActivePlan` (`:571-573`, called under `plan_lifecycle_mu_`
  after the session was seated in `active_recv_sessions_` under an earlier `mu_`
  lock at `:522-540`) fails, the cleanup `mu_` critical section (`:574-580`)
  releases (`:578`) and erases (`:579`) the session together before the plan is
  published, so it is not an event here.
* **A3 (no double end).** Every op ends at most once, so `in_flight_` never
  underflows: `h2dDone` is only enabled while a callback is outstanding,
  `pushEnd` only while a push is open.
* **A4 (transport ordering).** For the request that completes a layer,
  `HandleIncomingPush` (dispatched from `HandleCustomRequest`, `bt.cc:478`)
  calls `OnLayerReceived` (from `CompleteIncomingPush`, `bt.cc:618-621` →
  `:783-791`) before `OnBlockShardsReceived` (`bt.cc:629-630`), on the same
  thread, and `ExecuteLayerH2d` pushes the future into `h2d_futures_` before
  returning (`.cc:669-672`). A layer's blocks are accounted as one event once
  its copy is issued: guard `layersAccounted < issued`. With several streams
  per layer (several senders, or one sender's push split by source NUMA node
  into shard groups, each stream reporting only the shards it carried) the
  per-shard counters grow before `OnLayerReceived`, but every shard can only
  *reach* `total_blocks_ * num_layers` (`.cc:455-464`) once every stream has
  reported, so the call that sets `network_completed_` (`.cc:465-471`) runs
  after every layer's completing stream has reported, and each such report
  follows that stream's own `OnLayerReceived` on the same thread; lumping each
  layer's accounting into that event is sound for everything proved here. This
  relies on streams reporting exactly their planned block count once (the
  counters are plain sums compared with `>=`, `.cc:459-461`): over-reporting
  would complete a shard early, which is precisely the `netAccountUnordered`
  mutant.

## Properties

All proved on every reachable state (`reachable_safe`):

* **Settle safety.** `done → inFlight = 0`: a settled session owns no work, so
  its blocks and staging can be reused. This is what the comment at
  `.cc:642-646` relies on ("a copy already handed to the device cannot be
  revoked; its in-flight count keeps the receive owned until the copy ends").
* **No retired callback.** `done → retired = issued`: the
  `LOG(DFATAL) << "H2D callback for retired receive"` at `.cc:691-693` is
  unreachable.
* **Staging integrity.** `hasStaging = !done`.
* **Prompt settle.** `draining → inFlight = 0 → done`.
* **Readiness is sound.** `IsReadyToComplete → ready = numLayers`: when the
  poll decides the receive is complete, every layer's copy has been issued
  *and* has finished on the device. The `network_completed_` disjunct is
  sound only because of A4 (the mutant `netAccountUnordered` below shows what
  breaks without it).
* **Publication.** `published = some true → completed = numLayers`: when the
  engine is told `done_recving`, every layer's H2D callback has run with an
  OK status. Counter-level form of *publication correctness*;
  `Pipeline.lean` adds the memory contents.
* **Counters.** `completed ≤ retired ≤ ready ≤ issued ≤ numLayers` and
  `layersAccounted ≤ issued`.
* **No op leak.** `0 < inFlight →` some event in `drainEvents` is enabled:
  every accounted unit of `in_flight_` has an owner that can advance or retire
  it (`NoOpLeak`), and every reachable state can drain to `done = true` and
  release its staging in a finite number of steps (`reachable_can_settle`).

Note on the readiness predicate. One might expect `IsReadyToComplete` to
coincide with "every layer's callback has run OK"; it does not.
`IsReadyToComplete` tests futures (`ready`), and callbacks (`retired`,
`completed`) can lag behind, so the shipping predicate can be true before
`num_completed_layers_` reaches `numLayers` (`trace_poll_before_callbacks`).
That is harmless — `done` still waits for every callback through `in_flight_`
— and the publication property above is the one that matters.
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

/-- A receiver created by `StartRead` (`InitFromLoadPlan`, `.cc:333-352`):
`in_flight_ = 1` for the pull handshake (`.cc:344`; zero-block reads get
`in_flight_ = 0` and are finished by `StartRead` at `mgr.cc:894-897` without a
pull, excluded by A2). -/
def initLoad (numLayers : Nat) : Recv :=
  { numLayers, life := { inFlight := 1 }, pullPending := true }

/-- `network_completed_` (`.cc:465-471`): every shard's blocks accounted
(agrees with `.h:268` for `numLayers > 0`; at `numLayers = 0`, C++'s
`IsReadyToComplete` at `.cc:434-436` holds via its `num_completed_layers_ ==
total_layers` disjunct while `network_completed_` stays `false`). -/
def networkCompleted (s : Recv) : Prop := s.layersAccounted = s.numLayers

/-- `AllH2dDoneLocked` (`.cc:424-429`): every future in `h2d_futures_` is ready. -/
def allH2dDone (s : Recv) : Prop := s.ready = s.issued

/-- `IsReadyToComplete` (`.cc:431-437`). -/
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
(`.cc:542-544`), then the `absl::Cleanup` at `.cc:518` ends the op. -/
def pullReply (ok : Bool) (s : Recv) : Option Recv :=
  if s.pullPending = false then none
  else
    let l := if ok then s.life else s.life.finishLocked false
    some { s with life := l.endOpLocked, pullPending := false }

/-- `ExecuteLayerH2d` up to the first unlock (`.cc:620-632`): refused once
settled or draining, otherwise `++in_flight_`. -/
def h2dBegin (s : Recv) : Option Recv :=
  if s.issued + s.pending < s.numLayers then
    s.life.beginOp.map fun l => { s with life := l, pending := s.pending + 1 }
  else none

/-- `ExecuteLayerH2d` from the re-check on. If the session finished in the
window between the two locks, the op is released and no copy is issued
(`.cc:647-651`). Otherwise the copy is dispatched: on failure
`FinishLocked(status); EndRecvOpLocked()` (`.cc:661-666`); on success its
future joins `h2d_futures_` (`.cc:669-672`) and the op stays in flight until
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

/-- H2D completion callback (`.cc:675-733`), run once per ready future. The
`absl::Cleanup` at `.cc:684` ends the op on every path. On a retired session
the body returns early (`.cc:691-694`, DFATAL). On success
`num_completed_layers_++`; the last layer finishes the session unless it is
already draining (`.cc:698-705`). On failure `FinishLocked(status)` (`.cc:710`). -/
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

/-- `OnBlockShardsReceived` (`.cc:565-613`) for the stream that completes a layer
(A4). Ignored once settled or draining (`.cc:578-580`). Otherwise the stream's
blocks are accounted per shard (`.cc:457-464`); if every shard reaches the
threshold (`.cc:465-471`) and every layer's callback has also run (`.cc:470`),
the session finishes (`RecordNetworkCompleteLocked`, `.cc:487-491`). -/
def netAccount (s : Recv) : Option Recv :=
  if s.life.done = true ∨ s.life.draining = true then none
  else if s.layersAccounted < s.issued then
    let s := { s with layersAccounted := s.layersAccounted + 1 }
    if networkCompleted s ∧ s.completed = s.numLayers then
      some { s with life := s.life.finishLocked true }
    else some s
  else none

/-- `CompleteReadWithDetails` / `CompleteReadRaw` polls a session that is not
draining and finds it ready (`mgr.cc:968-972`). -/
def pollReady (s : Recv) : Option Recv :=
  if s.life.draining = false ∧ isReadyToComplete s then
    some { s with life := s.life.finishLocked true }
  else none

/-- `Finish(error)` from outside the session; enabled at any time. -/
def cancel (s : Recv) : Option Recv :=
  some { s with life := s.life.finishLocked false }

/-- `CompleteReadWithDetails` / `CompleteReadRaw` publishes a settled session
(`mgr.cc:983-992`). -/
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

/-- Events that advance or retire an in-flight operation. -/
def drainEvents : List Ev :=
  [.pushEnd, .pullReply true, .h2dIssue true, .h2dReady, .h2dDone true]

/-- Every unit of `in_flight_` has an owner that can advance or retire it:
while `inFlight > 0`, some event in `drainEvents` is enabled. -/
def NoOpLeak (s : Recv) : Prop :=
  0 < s.life.inFlight → ∃ e ∈ drainEvents, (step s e).isSome = true

/-- Everything we want to know about a reachable receive session. -/
def Safe (s : Recv) : Prop :=
  SettleSafe s ∧ NoRetiredCallback s ∧ StagingIntegrity s ∧ SettlesPromptly s ∧
    ReadinessSound s ∧ Publication s ∧ CountersOrdered s ∧ NoOpLeak s

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

theorem inv_noOpLeak {s : Recv} (h : Inv s) : NoOpLeak s := by
  intro hif
  have hacc := h.accounted
  unfold Accounted at hacc
  have hr := h.retired_le
  have hy := h.ready_le
  by_cases hp : 0 < s.pushes
  · exact ⟨.pushEnd, by simp [drainEvents], by simp [step, pushEnd]; omega⟩
  · by_cases hq : s.pullPending = true
    · exact ⟨.pullReply true, by simp [drainEvents], by simp [step, pullReply, hq]⟩
    · by_cases hpend : 0 < s.pending
      · have hne : s.pending ≠ 0 := by omega
        refine ⟨.h2dIssue true, by simp [drainEvents], ?_⟩
        simp only [step, h2dIssue, hne, ↓reduceIte]
        split <;> rfl
      · by_cases hrd : s.ready < s.issued
        · exact ⟨.h2dReady, by simp [drainEvents], by simp [step, h2dReady, hrd]⟩
        · have hret : s.retired < s.ready := by
            cases hqp : s.pullPending <;> simp_all <;> omega
          refine ⟨.h2dDone true, by simp [drainEvents], ?_⟩
          simp only [step, h2dDone, hret, ↓reduceIte]
          split <;> rfl

theorem inv_safe {s : Recv} (h : Inv s) : Safe s := by
  have hnl := inv_noOpLeak h
  obtain ⟨hl, hacc, hc, hr, hy, hi, ha, hok, hdr, _, hpub⟩ := h
  unfold Accounted at hacc
  refine ⟨hl.done_idle, ?_, hl.staging, hl.prompt, ?_, hpub, ⟨hc, hr, hy, by omega, ha⟩, hnl⟩
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

/-! ### Progress and eventual settlement -/

/-- Remaining steps needed to drain all in-flight operations once draining. -/
def drainRank (s : Recv) : Nat :=
  s.pushes + (if s.pullPending then 1 else 0) + s.pending +
    (s.issued - s.ready) + (s.issued - s.retired)

/-- While draining and not yet settled, some event in `drainEvents` is enabled,
preserves `draining`, and strictly decreases `drainRank`. -/
theorem drain_step {s : Recv} (h : Inv s) (hdr : s.life.draining = true)
    (hnd : s.life.done = false) :
    ∃ e s', step s e = some s' ∧ s'.life.draining = true ∧ drainRank s' < drainRank s := by
  have hif : 0 < s.life.inFlight := by
    cases h0 : s.life.inFlight
    · have := h.life.prompt hdr h0; simp [hnd] at this
    · omega
  have hacc := h.accounted
  unfold Accounted at hacc
  have hr := h.retired_le
  have hy := h.ready_le
  by_cases hp : 0 < s.pushes
  · have hs₁ : step s .pushEnd = some { s with life := s.life.endOpLocked, pushes := s.pushes - 1 } := by
      simp [step, pushEnd]; omega
    exact ⟨.pushEnd, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩
  · by_cases hq : s.pullPending = true
    · have hs₁ : step s (.pullReply true) = some { s with life := s.life.endOpLocked, pullPending := false } := by
        simp [step, pullReply, hq]
      exact ⟨.pullReply true, _, hs₁, by simp [hdr], by simp [drainRank, hq]⟩
    · by_cases hpend : 0 < s.pending
      · have hs₁ : step s (.h2dIssue true) = some { s with pending := s.pending - 1, life := s.life.endOpLocked } := by
          simp [step, h2dIssue, hdr]; omega
        exact ⟨.h2dIssue true, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩
      · by_cases hrd : s.ready < s.issued
        · have hs₁ : step s .h2dReady = some { s with ready := s.ready + 1 } := by
            simp [step, h2dReady, hrd]
          exact ⟨.h2dReady, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩
        · have hret : s.retired < s.ready := by
            cases hqp : s.pullPending <;> simp_all <;> omega
          have hs₁ : step s (.h2dDone true) =
              some { s with retired := s.retired + 1, completed := s.completed + 1, life := s.life.endOpLocked } := by
            simp [step, h2dDone, hret, hnd, hdr]
          exact ⟨.h2dDone true, _, hs₁, by simp [hdr], by simp [drainRank]; omega⟩

theorem draining_can_settle_aux (n : Nat) :
    ∀ (k : Nat) {s : Recv}, drainRank s ≤ k → Inv s → s.life.draining = true →
      ∃ evs s', (sysPush n).runFrom s evs = some s' ∧
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
      simp only [System.runFrom, sysPush, List.foldlM_cons, hs₁]
      exact hrun
    · have hst : s.life.hasStaging = false := by rw [h.life.staging, hnd]; rfl
      exact ⟨[], s, rfl, hnd, hst⟩

/-- Every reachable receive session can settle and release its staging buffer
in a finite number of steps. -/
theorem reachable_can_settle {n : Nat} {s : Recv}
    (h : (sysPush n).Reachable s ∨ (sysLoad n).Reachable s) :
    ∃ evs s', (sysPush n).runFrom s evs = some s' ∧
      s'.life.done = true ∧ s'.life.hasStaging = false := by
  have hinv := h.elim reachable_inv_push reachable_inv_load
  have hcancel : step s .cancel = some { s with life := s.life.finishLocked false } := rfl
  have hinv₁ := step_inv hinv hcancel
  have hdr₁ : ({ s with life := s.life.finishLocked false } : Recv).life.draining = true := by simp
  obtain ⟨evs, s', hrun, hd', hst'⟩ :=
    draining_can_settle_aux n (drainRank { s with life := s.life.finishLocked false })
      (Nat.le_refl _) hinv₁ hdr₁
  refine ⟨.cancel :: evs, s', ?_, hd', hst'⟩
  simp only [System.runFrom, sysPush, List.foldlM_cons, hcancel]
  exact hrun

/-! ## Frame lemmas

What each event leaves alone, and the exact spec for `h2dReady`, which the
composed transfer model (`Pipeline.lean`) attaches a memory effect to. Each is
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

/-- Only `h2dReady` increments `ready`. -/
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

theorem step_pending_issued {s s' : Recv} {e : Ev} (hs : step s e = some s')
    (hb : e ≠ .h2dBegin) (hi : ∀ ok, e ≠ .h2dIssue ok) :
    s'.pending = s.pending ∧ s'.issued = s.issued := by
  cases e <;> (try exact absurd rfl hb) <;> (try exact absurd rfl (hi _)) <;> recv_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; exact ⟨rfl, rfl⟩)
    | (cases hs <;> (repeat' split) <;> exact ⟨rfl, rfl⟩)

theorem h2dBegin_spec {s s' : Recv} (hs : step s .h2dBegin = some s') :
    s.issued + s.pending < s.numLayers ∧ s'.pending = s.pending + 1 ∧ s'.issued = s.issued := by
  simp only [step, h2dBegin] at hs
  split at hs
  · simp only [Option.map_eq_some_iff] at hs
    obtain ⟨l, _, rfl⟩ := hs
    exact ⟨‹_›, rfl, rfl⟩
  · cases hs

theorem h2dIssue_spec {s s' : Recv} {ok : Bool} (hs : step s (.h2dIssue ok) = some s') :
    s.pending ≠ 0 ∧ s'.pending = s.pending - 1 ∧
    s'.issued = (if s.life.done || s.life.draining || !ok then s.issued else s.issued + 1) := by
  simp only [step, h2dIssue] at hs
  split at hs
  · cases hs
  · rename_i hp
    split at hs
    · rename_i hc
      cases hs; exact ⟨hp, rfl, by simp [hc]⟩
    · rename_i hc
      cases ok with
      | false => cases hs; exact ⟨hp, rfl, by simp⟩
      | true =>
        cases hs
        exact ⟨hp, rfl, by simp_all⟩

theorem step_pullPending_of_ne_pullReply {s s' : Recv} {e : Ev} (hs : step s e = some s')
    (he : ∀ ok, e ≠ .pullReply ok) : s'.pullPending = s.pullPending := by
  cases e <;> (try exact absurd rfl (he _)) <;> recv_cases hs <;>
  first
    | (simp only [Option.map_eq_some_iff] at hs; obtain ⟨l, _, rfl⟩ := hs; rfl)
    | (cases hs <;> (repeat' split) <;> rfl)

/-! ## Replay and bounded search

Concrete traces, checked by `decide`, that document the behaviours the model
admits; and a bounded search confirming that no `Safe` violation is reachable
within a few events of either initial state. The inductive proof above is the
actual guarantee; the search guards against a modelling slip making the proof
vacuous. -/

/-- A two-layer push receive that completes through the last H2D callback and
is published as done. -/
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

/-- `RecvDrainTest.ExpiredReceiveKeepsStagingUntilH2dEnds`
(`kv_cache_manager_with_transfer_send_drain_test.cc:609-636`) and
`RecvDrainTest.TimeoutDuringH2dDispatchKeepsStaging` (`:717-753`): the deadline
fires while an H2D copy is in flight (or while the thread is inside
`H2dSyncDispatch` at `.cc:655-660`, after the `.cc:647-652` re-check has passed
— since `.cc:653-672` never re-reads `draining_`/`done_`, that deadline
linearises after `h2dIssue`). The session drains but does not settle until the
copy's callback ends the op, and is then published as failed. -/
theorem trace_deadline_during_copy :
    ((sysLoad 1).run [.pullReply true, .h2dBegin, .h2dIssue true, .cancel]).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    ((sysLoad 1).run
      [.pullReply true, .h2dBegin, .h2dIssue true, .cancel, .h2dReady, .h2dDone true, .publish]).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) := by
  decide

/-- The race the re-check at `.cc:641-652` closes: the session finishes between
the two locks of `ExecuteLayerH2d`, so no copy is issued and the op is released. -/
theorem trace_finish_between_locks :
    ((sysPush 1).run [.h2dBegin, .cancel, .h2dIssue true]).map
      (fun s => (s.issued, s.life.done)) = some (0, true) := by
  decide

/-- A push cannot start once the session is draining. -/
theorem trace_no_push_after_finish :
    (sysPush 1).run [.cancel, .pushBegin] = none := by
  decide

/-- `RecvLifecycleTest.NetworkCompletionWaitsForH2d`: `OnBlockShardsReceived`
(`netAccount`) sets `network_completed_` while the H2D copy is still running on
the device; neither the poll nor publication can complete the session until the
H2D copy finishes. -/
theorem trace_net_completion_waits_for_h2d :
    let pre := [.h2dBegin, .h2dIssue true, .netAccount]
    ((sysPush 1).run pre).map
      (fun s => (s.layersAccounted, s.life.done, s.life.hasStaging)) = some (1, false, true) ∧
    (sysPush 1).run (pre ++ [.pollReady]) = none ∧
    (sysPush 1).run (pre ++ [.publish]) = none ∧
    ((sysPush 1).run (pre ++ [.h2dReady, .h2dDone true, .publish])).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some true) := by
  decide

/-- `RecvLifecycleTest.LateBlockAccountingAfterRetirementIsANoOp`: a fast H2D
callback finishes and retires the session before `OnBlockShardsReceived` runs; the
late `netAccount` is ignored (`mgr.cc:1676-1679` once the poll has dropped the
session, `.cc:578-580` while it is still seated). -/
theorem trace_late_net_account_after_retire :
    let pre := [.h2dBegin, .h2dIssue true, .h2dReady, .h2dDone true, .publish]
    ((sysPush 1).run pre).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some true) ∧
    (sysPush 1).run (pre ++ [.netAccount]) = none := by
  decide

/-- `RecvDrainTest.FailedLayerWaitsForOtherH2dCopies` (and the 1-layer case
`RecvLifecycleTest.SingleFailedH2dReportsFailureAndReturnsStaging`): two layers'
H2D copies are issued; one fails while the other is still in flight; the session
drains and keeps its staging until the remaining copy finishes, then publishes
failure. -/
theorem trace_failed_h2d_waits_for_other_layer :
    let pre := [.h2dBegin, .h2dIssue true, .h2dBegin, .h2dIssue true, .h2dReady, .h2dDone false]
    ((sysPush 2).run pre).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    (sysPush 2).run (pre ++ [.publish]) = none ∧
    ((sysPush 2).run (pre ++ [.h2dReady, .h2dDone true, .publish])).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) := by
  decide

/-- `RecvLifecycleTest.IncomingPushLeasePinsStagingDuringWriteAndRejectsWhenDraining`
(`kv_cache_manager_with_transfer_send_drain_test.cc:806-829`) and
`DemandStagingTest.UnregisteringInFlightReceiverDefersUntilItSettles`
(`kv_cache_manager_with_transfer_pool_reshard_test.cc:434-474`):
an open incoming push lease (`pushBegin`) keeps staging pinned across `cancel`
while rejecting new pushes, and releases staging when `pushEnd` completes.
Since `4efb0dd` the `cancel, pushEnd` suffix is also what a failed push itself
does (`end_incoming_push` finishes the session with the push's status, then
ends the op):
`RecvLifecycleTest.FailedIncomingPushImmediatelyFailsSessionAndReleasesStagingBeforeDeadline`
(`kv_cache_manager_with_transfer_send_drain_test.cc:860-888`). -/
theorem trace_push_lease_pins_staging_on_cancel :
    ((sysPush 1).run [.pushBegin, .cancel]).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    (sysPush 1).run [.pushBegin, .cancel, .pushBegin] = none ∧
    ((sysPush 1).run [.pushBegin, .cancel, .pushEnd, .publish]).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) := by
  decide

/-- `RecvLifecycleTest.IncomingPushLeaseSpansLayerH2dAndBlockAccountingBeforeReleasing`
(`kv_cache_manager_with_transfer_send_drain_test.cc:831-858`):
even if the H2D copy and its callback finish inside `HandleIncomingPush` before
`EndIncomingPush` runs, the open push lease (`pushes = 1`) keeps `done = false`
and `hasStaging = true` until `pushEnd`. -/
theorem trace_push_lease_outlives_h2d :
    let pre := [.pushBegin, .h2dBegin, .h2dIssue true, .h2dReady, .h2dDone true]
    ((sysPush 1).run pre).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    (sysPush 1).run (pre ++ [.publish]) = none ∧
    ((sysPush 1).run (pre ++ [.pushEnd, .publish])).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some true) := by
  decide

/-- `ControlHandshakeTest.ExpiredReceiveKeepsStagingUntilHandshakeEnds`
(`kv_cache_manager_with_transfer_control_test.cc:793-833`), plus the idle
push-plan cases `RecvLifecycleTest.ReceiveWithoutTrafficFailsAtItsDeadline`
(`kv_cache_manager_with_transfer_send_drain_test.cc:596-607`),
`DemandStagingTest.UnregisteringIdleReceiverReleasesPlanAtOnce`
(`kv_cache_manager_with_transfer_pool_reshard_test.cc:407-432`), and
`DemandStagingTest.DemandStagedReceiverPlanUnregistersWhenItSettles`
(`:536-559`): on `sysLoad 1`, a deadline while the pull handshake is still
pending keeps staging pinned until `pullReply` ends the handshake op; on
`sysPush 1` with no admitted push, cancelling or timing out settles and releases
staging at once. -/
theorem trace_deadline_during_handshake :
    ((sysLoad 1).run [.cancel]).map
      (fun s => (s.life.draining, s.life.done, s.life.hasStaging)) = some (true, false, true) ∧
    (sysLoad 1).run [.cancel, .publish] = none ∧
    ((sysLoad 1).run [.cancel, .pullReply false, .publish]).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) ∧
    ((sysPush 1).run [.cancel, .publish]).map
      (fun s => (s.life.done, s.life.hasStaging, s.published)) = some (true, false, some false) := by
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
    s.issued ≤ s.numLayers && s.layersAccounted ≤ s.issued) ||
  (0 < s.life.inFlight && !(drainEvents.any fun e => (step s e).isSome))

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

/-- Mutant for `NoOpLeak`: `ExecuteLayerH2d` returns early on `done_ || draining_`
(`.cc:648-651`) without calling `EndRecvOpLocked()`. A cancel between the two
locks leaks the op: `inFlight` stays positive with no enabled drain event, so
the session never settles (`SettleSafe` holds vacuously, `NoOpLeak` catches
it). -/
def h2dIssueLeak (ok : Bool) (s : Recv) : Option Recv :=
  if s.pending = 0 then none
  else
    let s := { s with pending := s.pending - 1 }
    if s.life.done = true ∨ s.life.draining = true then
      some s
    else if ok then
      some { s with issued := s.issued + 1 }
    else
      some { s with life := (s.life.finishLocked false).endOpLocked }

#guard (match ModelCheck.check ⟨initPush 1, fun s e => match e with
          | .h2dIssue ok => h2dIssueLeak ok s
          | e => step s e⟩ events violates 6 with
        | .counterexample _ => true
        | _ => false)

end Recv

end TpuSyncVerify.Transfer.PrefillDecode
