import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.PrefillDecode.Send.Traces

/-! # `Send`: guard inventory — which C++ checks the properties need

Part of `TpuSyncVerify.Transfer.PrefillDecode.Send`; same construction as
`Receive/Guards.lean`. Every guard in `step` that transcribes a C++ check is
mutated and searched exhaustively (zero, one and two layers; every counter is
layer-capped, so no pruning is needed) against the observable properties —
`Safe` without `CountersOrdered`. Ghost guards (`d2hPending`, `pooled = 0`,
`chaining = 0`, `woken < queued`, the `retired < ready` pairs) are the model's
bookkeeping of outstanding callbacks and are not mutated. -/

namespace TpuSyncVerify.Transfer.PrefillDecode

open TpuSyncVerify.Transfer (Lifecycle)

namespace Send

def SafeObs (s : Send) : Prop :=
  SettleSafe s ∧ Drained s ∧ StagingIntegrity s ∧ SettlesPromptly s ∧ NoUnderflow s ∧
    Publication s ∧ NoOpLeak s ∧ PullClaimed s ∧ PublishedQuiet s

instance (s : Send) : Decidable (SafeObs s) := by
  unfold SafeObs SettleSafe Drained StagingIntegrity SettlesPromptly NoUnderflow Publication
    NoOpLeak PullClaimed PublishedQuiet
  infer_instance

def violatesObs (s : Send) : Bool := !decide (SafeObs s)

theorem violatesObs_iff (s : Send) : violatesObs s = false ↔ SafeObs s := by simp [violatesObs]

def mutant (override : Send → Ev → Option (Option Send)) (init : Send) : System Send Ev :=
  ⟨init, fun s e => (override s e).getD (step s e)⟩

def guardInits : List Send := [init 0, init 1, init 2]

def verdict (override : Send → Ev → Option (Option Send)) : ModelCheck.Result Ev :=
  guardInits.foldl (fun acc i =>
    match acc with
    | .safe => ModelCheck.check (mutant override i) events violatesObs 64
    | r => r) .safe

def killed (override : Send → Ev → Option (Option Send)) : Bool :=
  match verdict override with
  | .counterexample _ => true
  | _ => false

def survives (override : Send → Ev → Option (Option Send)) : Bool :=
  verdict override = .safe

/-- A survivor against the full `Safe`, ghost equations included. -/
def survivesFull (override : Send → Ev → Option (Option Send)) : Bool :=
  guardInits.all fun i => ModelCheck.check (mutant override i) events violates 64 = .safe

/-! ## The guards

| # | C++ check | Event | Mutant | Verdict |
|---|---|---|---|---|
| S1 | `ValidateAndBeginPull`: `if (pull_started_)` rejects a duplicate pull | `beginPull` | — | **not expressible here**: its consequence is a second `StartPush` worker on one session; the model has one `start` by construction (`started`). `Pipeline.HandshakeSafe` states the single claim; `trace_duplicate_pull_rejected` pins the refusal |
| S1′ | `ValidateAndBeginPull`: `deadline_ <= now` (an expired offer; modelled as refusing on `draining ∨ done`) | `beginPull` | claim regardless | **survives** — the claim on a settled send leads nowhere: `start` is refused (S2), and in the C++ `AcquireStagingWithRetry` returns `status_` and the `Finish` is ignored |
| S2 | `StartPush`, locked section: `if (draining_ \|\| done_) return;` | `start` | enter the loop regardless | **survives** — `SendNextLayer(0)` (S4) and the loop's `if (draining_) return;` (S3) both refuse; `started` on a settled send changes no property |
| S3 | `StartPush` loop: `if (draining_) { ...; return; } ++in_flight_;` | `d2hBegin` | take the op always | **killed** — `SettleSafe`: a copy issued after the send settled (`cancel` then `fail_unissued_layers` settles `SendNextLayer(0)`'s op before layer 0's copy starts) |
| S3′ | … checking `done_` instead of `draining_` | `d2hBegin` | refuse on `done_` only | **survives** — copies issued on a draining send drain through `d2hEnd`; no further `SendNextLayer` is queued (`trySendNext` refuses while draining, S4), so none is pushed; wasted DMA, not safety. S3 drops `beginOp` whole, i.e. its `done_` disjunct too: `beginOp` stands for the sender's `draining_`-only check (`Session.lean`), `done → draining` under `Consistent` |
| S4 | `SendNextLayer`: `draining_` in `if (draining_ \|\| l >= d2h_layer_futures_.size()) return;` | `trySendNext` (in `start`, `sendNext`) | take the op regardless of `draining_` (keeping `!done`, since `ReleaseStagingBlocksLocked` clears `d2h_layer_futures_` at settle) | **survives** — the op waits on its pre-created future, `fail_unissued_layers` resolves any unissued layer's promise, and `wake` (S5) releases the op; the bounds half is `sendNextUnbounded` in `Traces.lean` (killed, `NoOpLeak`) |
| S5 | `SendNextLayer`'s `OnReady`: `if (self->draining_) { ...; return; }` after an OK copy | `wake` | schedule the push regardless | **survives** — the pool task's own check (S6) refuses |
| S6 | pool task: `if (self->draining_) { ...; return; }` before `H2hWriteDirectAsync` | `h2hIssue` | push regardless | **survives** — a push on a draining send reads staging the send still holds (`in_flight_ > 0` until the push callback) and ends through `h2hDone`; wasted network, not safety. S5 and S6 are two lines of the same defence; each alone is enough, and the properties need neither |
| S7 | push callback: `Finish()` only when every layer's push has completed (`remaining_h2h_layers_` reaching 0) | `h2hDone` | `Finish()` on every OK push | **killed** — `Publication`: `done_sending` with a layer not yet pushed |
| S8 | `CompleteReadWithDetails`: `if (session->Done())` before publishing | `publish` | publish once draining | **killed** — `PublishedQuiet`: `failed_recving` reported while a D2H copy is still dispatching into, or reading, prefill HBM. **This mutant survived the `Safe` the module had**: `Publication` is one-directional and `ok_draining` makes an early OK publication harmless, so nothing at the session level said what `Done()` is for on the sender; the promise was stated only one module up (`Pipeline.PrefillHbmSafe`). `PublishedQuiet` was added to `Safe` as a result — the first property this inventory produced |
| S9 | `EndSendOpLocked`: `draining_ &&` in the settle condition | every `EndSendOp` | settle at `in_flight_ == 0` regardless (the mutant also marks the send draining when it settles, keeping `Consistent.done_draining`) | **survives** — `StartPush` arms `SendNextLayer(0)` (`++in_flight_`) before the D2H loop, and each layer's callback hands its op to the push pool (`wake true`) where `H2hWriteDirectAsync` takes the next op (`h2hIssue`) before `SendNextLayer(l + 1)` and `end_op` (`sendNext`), until the last push calls `FinishLocked()` (`h2hDone true`) before its `end_op`; so an unbroken `in_flight_ > 0` baton spans the active lifetime of every non-zero-layer send, and `in_flight_` never hits `0` while `!draining_` |
| S10 | `FinishLocked`: `if (draining_ \|\| done_) return;` (first `Finish` wins) | `cancel` and every `finish` | first error wins instead (the receiver's rule) | **survives** — the properties are one-directional (`published = some true → every push OK`); which status a late error leaves is pinned by `trace_cancel_after_ok_finish`, not by `Safe` |
| S11 | `FinishLocked`: `in_flight_ == 0` in the settle condition | `cancel` | settle at once | **killed** — `cancelEager` in `Traces.lean` (`SettleSafe`) |
| S12 | `AcquireStagingWithRetry`: `if (draining_ \|\| done_)` before and after the acquisition | `start` | — | folded into the atomic `start` (`Send.lean` §Lock scopes); a `Finish` in that window is `cancel` before `start`, which S2 refuses |
| S13 | `StartPush`: `absl::Cleanup fail_unissued_layers` resolving unissued promises | `wake` | omit unissued-layer resolution | **killed** — `trace_without_fail_unissued_leaks` in `Traces.lean` (`in_flight_ = 1` with no enabled `drainEvents` step under the mutated step after `[.beginPull, .start, .cancel]`) |

Five checks are load-bearing (S3, S7, S8, plus S11 and S13 from `Traces.lean`,
alongside S4's bounds half `sendNextUnbounded`);
eight survive, all against the full `Safe` as well (`survivesFull`). S1′, S2,
S3′, S4, S5, S6 are each one of two or three lines of defence against doing
work for a dead send, and the properties see the last line only — a `Finish`
on a send stops *new* work at every lock it passes, which costs nothing and
makes each check individually unnecessary. S9 is redundant for a structural
reason: arming `SendNextLayer(0)` before the D2H loop keeps `in_flight_ > 0`
continuously until `FinishLocked()` marks the send draining. S10 is different: it is a design choice
(first-`Finish`-wins) that no safety property can see, only a replay. And S8
is the inventory's finding: a load-bearing check whose purpose the session's
properties did not state until `PublishedQuiet` was added. -/

def s1' : Send → Ev → Option (Option Send)
  | s, .beginPull => some (if s.pullStarted = true then none else some { s with pullStarted := true })
  | _, _ => none

def s2 : Send → Ev → Option (Option Send)
  | s, .start => some (if s.pullStarted = false ∨ s.started = true then none
      else if s.numLayers = 0 then some (s.finish true) else some { s with started := true }.trySendNext)
  | _, _ => none

def s3 : Send → Ev → Option (Option Send)
  | s, .d2hBegin => some (if s.started = true ∧ s.d2hPending = false ∧ s.d2hIssued < s.numLayers then
      some { s with life := { s.life with inFlight := s.life.inFlight + 1 }, d2hPending := true }
    else none)
  | _, _ => none

def s3' : Send → Ev → Option (Option Send)
  | s, .d2hBegin => some (if s.started = true ∧ s.d2hPending = false ∧ s.d2hIssued < s.numLayers ∧
        s.life.done = false then
      some { s with life := { s.life with inFlight := s.life.inFlight + 1 }, d2hPending := true }
    else none)
  | _, _ => none

/-- `trySendNext` without the `draining_` refusal (`ReleaseStagingBlocksLocked`
clears `d2h_layer_futures_` at settle, so `done = false` remains). -/
def trySendNextNoDrain (s : Send) : Send :=
  if s.queued < s.numLayers ∧ s.life.done = false then
    { s with life := { s.life with inFlight := s.life.inFlight + 1 }, queued := s.queued + 1 }
  else s

def s4 : Send → Ev → Option (Option Send)
  | s, .start => some (if s.pullStarted = false ∨ s.started = true ∨ s.life.draining = true ∨
        s.life.done = true then none
      else if s.numLayers = 0 then some (s.finish true)
      else some { s with started := true }.trySendNextNoDrain)
  | s, .sendNext => some (if s.chaining = 0 then none
      else some { s with chaining := s.chaining - 1 }.trySendNextNoDrain.endOp)
  | _, _ => none

def s5 : Send → Ev → Option (Option Send)
  | s, .wake ok => some (if s.woken < s.queued ∧
        (s.woken < s.d2hReady ∨
          (ok = false ∧ s.life.draining = true ∧ s.d2hPending = false ∧
            s.d2hIssued ≤ s.woken)) then
      let s := { s with woken := s.woken + 1 }
      if ok = false then some (s.finish false).endOp else some { s with pooled := s.pooled + 1 }
    else none)
  | _, _ => none

def s6 : Send → Ev → Option (Option Send)
  | s, .h2hIssue => some (if s.pooled = 0 then none
      else
        let s := { s with pooled := s.pooled - 1 }
        some { s with life := { s.life with inFlight := s.life.inFlight + 1 },
                      h2hIssued := s.h2hIssued + 1, chaining := s.chaining + 1 })
  | _, _ => none

def s7 : Send → Ev → Option (Option Send)
  | s, .h2hDone ok => some (if s.h2hRetired < s.h2hIssued then
      let s := { s with h2hRetired := s.h2hRetired + 1 }
      if ok then some ({ s with h2hOk := s.h2hOk + 1 }.finish true).endOp
      else some (s.finish false).endOp
    else none)
  | _, _ => none

def s8 : Send → Ev → Option (Option Send)
  | s, .publish => some (if s.life.draining = true ∧ s.published = none then
      some { s with published := some s.life.statusOk } else none)
  | _, _ => none

/-- `endOp` settling at `inFlight = 0` whether or not draining. -/
def endOpEager (s : Send) : Send :=
  if s.life.inFlight = 0 then { s with underflow := true }
  else
    let l := { s.life with inFlight := s.life.inFlight - 1 }
    if l.inFlight = 0 ∧ l.done = false then
      { s with life := { l with draining := true, hasStaging := false, done := true } }
    else { s with life := l }

def s9 : Send → Ev → Option (Option Send)
  | s, .d2hIssue ok => some (if s.d2hPending = false then none
      else
        let s := { s with d2hPending := false }
        if ok then some { s with d2hIssued := s.d2hIssued + 1 }
        else some (s.finish false).endOpEager)
  | s, .d2hEnd => some (if s.d2hRetired < s.d2hReady then
      some { s with d2hRetired := s.d2hRetired + 1 }.endOpEager else none)
  | s, .wake ok => some (if s.woken < s.queued ∧
        (s.woken < s.d2hReady ∨
          (ok = false ∧ s.life.draining = true ∧ s.d2hPending = false ∧
            s.d2hIssued ≤ s.woken)) then
      let s := { s with woken := s.woken + 1 }
      if ok = false then some (s.finish false).endOpEager
      else if s.life.draining = true then some s.endOpEager
      else some { s with pooled := s.pooled + 1 }
    else none)
  | s, .h2hIssue => some (if s.pooled = 0 then none
      else
        let s := { s with pooled := s.pooled - 1 }
        match s.life.beginOp with
        | some l => some { s with life := l, h2hIssued := s.h2hIssued + 1, chaining := s.chaining + 1 }
        | none => some s.endOpEager)
  | s, .sendNext => some (if s.chaining = 0 then none
      else some { s with chaining := s.chaining - 1 }.trySendNext.endOpEager)
  | s, .h2hDone ok => some (if s.h2hRetired < s.h2hIssued then
      let s := { s with h2hRetired := s.h2hRetired + 1 }
      if ok then
        let s := { s with h2hOk := s.h2hOk + 1 }
        some (if s.h2hOk = s.numLayers then (s.finish true).endOpEager else s.endOpEager)
      else some (s.finish false).endOpEager
    else none)
  | _, _ => none

/-- Every `finish` first-error-wins (`Lifecycle.finishLocked`) instead of
first-`Finish`-wins. -/
def finishErrWins (ok : Bool) (s : Send) : Send := { s with life := s.life.finishLocked ok }

def s10 : Send → Ev → Option (Option Send)
  | s, .start => some (if s.pullStarted = false ∨ s.started = true ∨ s.life.draining = true ∨
        s.life.done = true then none
      else if s.numLayers = 0 then some (s.finishErrWins true)
      else some { s with started := true }.trySendNext)
  | s, .d2hIssue ok => some (if s.d2hPending = false then none
      else
        let s := { s with d2hPending := false }
        if ok then some { s with d2hIssued := s.d2hIssued + 1 }
        else some (s.finishErrWins false).endOp)
  | s, .wake ok => some (if s.woken < s.queued ∧
        (s.woken < s.d2hReady ∨
          (ok = false ∧ s.life.draining = true ∧ s.d2hPending = false ∧
            s.d2hIssued ≤ s.woken)) then
      let s := { s with woken := s.woken + 1 }
      if ok = false then some (s.finishErrWins false).endOp
      else if s.life.draining = true then some s.endOp
      else some { s with pooled := s.pooled + 1 }
    else none)
  | s, .h2hDone ok => some (if s.h2hRetired < s.h2hIssued then
      let s := { s with h2hRetired := s.h2hRetired + 1 }
      if ok then
        let s := { s with h2hOk := s.h2hOk + 1 }
        some (if s.h2hOk = s.numLayers then (s.finishErrWins true).endOp else s.endOp)
      else some (s.finishErrWins false).endOp
    else none)
  | s, .cancel => some (some (s.finishErrWins false))
  | _, _ => none

#guard survives s1'
#guard survives s2
#guard killed s3
#guard survives s3'
#guard survives s4
#guard survives s5
#guard survives s6
#guard killed s7
#guard killed s8
#guard survives s9
#guard survives s10
#guard [s1', s2, s3', s4, s5, s6, s9, s10].all survivesFull

/- The schedules the search returns for the killed checks (evaluated: `decide`
on a fuel-64 search exceeds the kernel's recursion depth). -/
#guard ModelCheck.check (mutant s3 (init 1)) events violatesObs 64 =
  .counterexample [.beginPull, .start, .cancel, .wake false, .d2hBegin]
#guard ModelCheck.check (mutant s7 (init 2)) events violatesObs 64 =
  .counterexample [.beginPull, .start, .d2hBegin, .d2hIssue true, .d2hReady, .wake true,
    .h2hIssue, .h2hDone true, .sendNext, .d2hEnd, .publish]
#guard ModelCheck.check (mutant s8 (init 1)) events violatesObs 64 =
  .counterexample [.beginPull, .start, .d2hBegin, .cancel, .publish]

end Send

end TpuSyncVerify.Transfer.PrefillDecode
