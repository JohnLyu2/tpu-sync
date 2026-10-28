import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.PrefillDecode.Receive.Traces

/-! # `Recv`: guard inventory — which C++ checks the properties need

Part of `TpuSyncVerify.Transfer.PrefillDecode.Receive`.

`Traces.lean` has one mutant per load-bearing guard, chosen by hand. This
file goes the other way: every guard in `step` that transcribes a C++ check
is listed, mutated (dropped, or weakened to the disjunct in question), and
searched exhaustively against the **observable** properties — `Safe` without
`CountersOrdered`, the ghost-counter equations that would kill any malformed
step for reasons the C++ cannot see. A mutant the search kills shows the
check is needed for a promise the receiver makes; a mutant that survives
shows the check serves something the properties do not state — an
optimisation, metrics, or a different property — and says which.

Ghost guards (`pending = 0`, `retired < ready`, `layersAccounted < issued`,
`pullPending`) are not mutated: they are the model's bookkeeping of which
callbacks are outstanding, not checks the C++ performs.

The searches run on `initPush 1`, `initPush 2`, `initLoad 1`, `initLoad 2`
with at most two open push leases (a third adds states, not behaviour — see
`Coverage.lean`), which makes every state space finite, so `.safe` is a
result and `.counterexample` a schedule. -/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)

namespace Recv

/-- The observable properties: `Safe` without the ghost-counter equations. -/
def SafeObs (s : Recv) : Prop :=
  SettleSafe s ∧ NoRetiredCallback s ∧ StagingIntegrity s ∧ SettlesPromptly s ∧
    ReadinessSound s ∧ Publication s ∧ NoOpLeak s ∧ PublishedQuiet s

instance (s : Recv) : Decidable (SafeObs s) := by
  unfold SafeObs SettleSafe NoRetiredCallback StagingIntegrity SettlesPromptly ReadinessSound
    Publication NoOpLeak PublishedQuiet
  infer_instance

def violatesObs (s : Recv) : Bool := !decide (SafeObs s)

theorem violatesObs_iff (s : Recv) : violatesObs s = false ↔ SafeObs s := by simp [violatesObs]

/-- `step` with one event replaced, and states with more than two open push
leases refused so that the search exhausts. -/
def mutant (override : Recv → Ev → Option (Option Recv)) (init : Recv) : System Recv Ev :=
  ⟨init, fun s e =>
    ((override s e).getD (step s e)).bind fun s' => if s'.pushes ≤ 2 then some s' else none⟩

def guardInits : List Recv := [initPush 1, initPush 2, initLoad 1, initLoad 2]

/-- `.safe` on every start, or the first counterexample. -/
def verdict (override : Recv → Ev → Option (Option Recv)) : ModelCheck.Result Ev :=
  guardInits.foldl (fun acc i =>
    match acc with
    | .safe => ModelCheck.check (mutant override i) events violatesObs 64
    | r => r) .safe

def killed (override : Recv → Ev → Option (Option Recv)) : Bool :=
  match verdict override with
  | .counterexample _ => true
  | _ => false

def survives (override : Recv → Ev → Option (Option Recv)) : Bool :=
  verdict override = .safe

/-- A survivor against the full `Safe`, ghost equations included: rules out
"killed only by bookkeeping". -/
def survivesFull (override : Recv → Ev → Option (Option Recv)) : Bool :=
  guardInits.all fun i => ModelCheck.check (mutant override i) events violates 64 = .safe

/-! ## The guards

| # | C++ check | Event | Mutant | Verdict |
|---|---|---|---|---|
| G1 | `TryBeginRecvOp`: `if (done_ \|\| draining_) return false` | `pushBegin` | accept always | **killed** — `SettleSafe`: a push admitted on a settled session gives `done ∧ inFlight > 0` (its bytes land in staging another receive may own) |
| G2 | `ExecuteLayerH2d`, first lock: `if (done_ \|\| draining_) return` | `h2dBegin` | take the op always | **killed** — `SettleSafe`, same as G1 |
| G2′ | … the `draining_` disjunct of G2 | `h2dBegin` | check `done_` only | **survives** — an op taken on a draining session is released by the re-check (G3); the first check's `draining_` saves a lock round-trip and a log line, nothing the properties state |
| G3 | `ExecuteLayerH2d`, second lock: `if (done_ \|\| draining_) { EndRecvOpLocked(); return; }` | `h2dIssue` | dispatch regardless | **survives** — the copy's op keeps the session unsettled until its callback, so staging and HBM stay owned; `done_` cannot hold here (`in_flight_ > 0`); the check is "a finished receive starts no copy it does not need" (the C++ comment): wasted DMA, not safety. (`h2dIssueLeak` in `Traces.lean` is the *other* half: returning without `EndRecvOpLocked()` leaks the op) |
| G4 | H2D callback: `if (self->done_) { LOG(DFATAL); return; }` | `h2dDone` | — | **assertion**, unreachable by `NoRetiredCallback`; not mutated |
| G5 | H2D callback, last layer: `&& !self->draining_` before `FinishLocked()` | `h2dDone` | `FinishLocked()` on the last layer regardless | **survives** — `FinishLocked` with an OK status on a draining session returns at `if (draining_) return;` with `status_` untouched; the condition gates `all_layers_done`, i.e. the duration metric and `RecordEnd`, not the lifecycle |
| G6 | `OnBlockShardsReceived`: `if (done_ \|\| draining_) return OkStatus()` | `netAccount` | account regardless | **survives** — `RecordNetworkCompleteLocked`'s `FinishLocked()` on a draining session is a no-op; what the check prevents is counting a dead receive's blocks (`accumulated_host_block_ids_`, `RecordLastPacket`) |
| G7 | `CompleteReadWithDetails`: `!session->IsDraining()` before the readiness poll | `pollReady` | poll regardless | **survives** — `Finish()` with an OK status on a draining session is a no-op (`ReceivePoll.lean` shows the whole poll is redundant for the lifecycle) |
| G8 | `CompleteReadWithDetails`: `if (session->Done())` before publishing | `publish` | publish once draining | **killed** — `PublishedQuiet`: `failed_recving` reported with an H2D op still open (`h2dBegin, cancel, publish`), and `Publication`: `done_recving` reported with a callback still outstanding. The `Safe` the module had killed this mutant only through the OK half; the failed half — the engine refilling decode HBM under a copy — was stated one module up (`Pipeline.DecodeHbmSafe`) and nowhere here. `PublishedQuiet` was added, as on the sender |
| G9 | `EndRecvOpLocked`: `draining_ &&` in the settle condition | every `EndRecvOp` | settle at `in_flight_ == 0` regardless (the mutant also marks the session draining when it settles, keeping `Consistent.done_draining`; the kill does not depend on it) | **killed** — `Publication`: a receive settles OK the moment its first push lease (or handshake op) ends, before any layer |
| G10 | `FinishLocked`: `in_flight_ == 0 &&` in the settle condition | `cancel` | settle at once | **killed** — `cancelEager` in `Traces.lean` (`SettleSafe`) |
| G11 | `TryBeginRecvOp`'s `done_` disjunct | `pushBegin` | check `draining_` only | **equivalent** on every reachable state (`Lifecycle.beginOp'_eq`, `Session.lean` §Redundant `done_` guards); not a mutant |

Five checks are load-bearing (G1, G2, G8, G9, and G10 from `Traces.lean`);
five survive — against the full `Safe` too (`survivesFull`), so none is a
case of "killed only by bookkeeping". The survivors are of two
kinds: G2′, G3 and G7 are optimisations or second lines of defence whose
first line the properties already see; G5 and G6 guard metrics and
accounting the model does not carry. None is a redundancy the C++ should
lose — each has a purpose — but none is needed for what is proved, which is
what a reader of `reachable_safe` should know. The G8 `Publication` schedule is
the poll-before-callback window of `ReceivePoll.lean`: with `Done()` dropped, the
poll's `Finish()` would publish a receive whose callback has not run. -/

def g1 : Recv → Ev → Option (Option Recv)
  | s, .pushBegin => some (some { s with life := { s.life with inFlight := s.life.inFlight + 1 },
                                         pushes := s.pushes + 1 })
  | _, _ => none

def g2 : Recv → Ev → Option (Option Recv)
  | s, .h2dBegin =>
    some (if s.issued + s.pending < s.numLayers then
      some { s with life := { s.life with inFlight := s.life.inFlight + 1 }, pending := s.pending + 1 }
    else none)
  | _, _ => none

def g2' : Recv → Ev → Option (Option Recv)
  | s, .h2dBegin =>
    some (if s.issued + s.pending < s.numLayers ∧ s.life.done = false then
      some { s with life := { s.life with inFlight := s.life.inFlight + 1 }, pending := s.pending + 1 }
    else none)
  | _, _ => none

def g3 : Recv → Ev → Option (Option Recv)
  | s, .h2dIssue ok =>
    some (if s.pending = 0 then none
      else
        let s := { s with pending := s.pending - 1 }
        if ok then some { s with issued := s.issued + 1 }
        else some { s with life := (s.life.finishLocked false).endOpLocked })
  | _, _ => none

def g5 : Recv → Ev → Option (Option Recv)
  | s, .h2dDone ok =>
    some (if s.retired < s.ready then
      let s := { s with retired := s.retired + 1 }
      if s.life.done = true then some { s with life := s.life.endOpLocked }
      else if ok then
        let s := { s with completed := s.completed + 1 }
        let l := if s.completed = s.numLayers then s.life.finishLocked true else s.life
        some { s with life := l.endOpLocked }
      else some { s with life := (s.life.finishLocked false).endOpLocked }
    else none)
  | _, _ => none

def g6 : Recv → Ev → Option (Option Recv)
  | s, .netAccount =>
    some (if s.layersAccounted < s.issued then
      let s := { s with layersAccounted := s.layersAccounted + 1 }
      if networkCompleted s ∧ s.completed = s.numLayers then
        some { s with life := s.life.finishLocked true }
      else some s
    else none)
  | _, _ => none

def g7 : Recv → Ev → Option (Option Recv)
  | s, .pollReady =>
    some (if isReadyToComplete s then some { s with life := s.life.finishLocked true } else none)
  | _, _ => none

def g8 : Recv → Ev → Option (Option Recv)
  | s, .publish =>
    some (if s.life.draining = true ∧ s.published = none then
      some { s with published := some s.life.statusOk } else none)
  | _, _ => none

/-- `endOpLocked` settling at `inFlight = 0` whether or not draining, on every
event that ends an op. -/
def endOpEager (l : Lifecycle) : Lifecycle :=
  if l.inFlight = 0 then l
  else
    let l := { l with inFlight := l.inFlight - 1 }
    if l.inFlight = 0 ∧ l.done = false then { l with draining := true, hasStaging := false, done := true }
    else l

def g9 : Recv → Ev → Option (Option Recv)
  | s, .pushEnd => some (if s.pushes = 0 then none
      else some { s with life := endOpEager s.life, pushes := s.pushes - 1 })
  | s, .pullReply ok => some (if s.pullPending = false then none
      else
        let l := if ok then s.life else s.life.finishLocked false
        some { s with life := endOpEager l, pullPending := false })
  | s, .h2dIssue ok => some (if s.pending = 0 then none
      else
        let s := { s with pending := s.pending - 1 }
        if s.life.done = true ∨ s.life.draining = true then some { s with life := endOpEager s.life }
        else if ok then some { s with issued := s.issued + 1 }
        else some { s with life := endOpEager (s.life.finishLocked false) })
  | s, .h2dDone ok => some (if s.retired < s.ready then
      let s := { s with retired := s.retired + 1 }
      if s.life.done = true then some { s with life := endOpEager s.life }
      else if ok then
        let s := { s with completed := s.completed + 1 }
        let l := if s.completed = s.numLayers ∧ s.life.draining = false
                 then s.life.finishLocked true else s.life
        some { s with life := endOpEager l }
      else some { s with life := endOpEager (s.life.finishLocked false) }
    else none)
  | _, _ => none

#guard killed g1
#guard killed g2
#guard survives g2'
#guard survives g3
#guard survives g5
#guard survives g6
#guard survives g7
#guard killed g8
#guard killed g9
#guard [g2', g3, g5, g6, g7].all survivesFull

/- The schedules the search returns for the three killed checks no hand-written
mutant covered, and for G8 (evaluated, as the other searches: `decide` on a
fuel-64 search exceeds the kernel's recursion depth). -/
#guard ModelCheck.check (mutant g1 (initPush 1)) events violatesObs 64 =
  .counterexample [.cancel, .pushBegin]
#guard ModelCheck.check (mutant g2 (initPush 1)) events violatesObs 64 =
  .counterexample [.cancel, .h2dBegin]
#guard ModelCheck.check (mutant g8 (initPush 1)) events violatesObs 64 =
  .counterexample [.h2dBegin, .cancel, .publish]
#guard ModelCheck.check (mutant g9 (initPush 1)) events violatesObs 64 =
  .counterexample [.pushBegin, .pushEnd, .publish]

end Recv

end TpuSyncVerify.Transfer.PrefillDecode
