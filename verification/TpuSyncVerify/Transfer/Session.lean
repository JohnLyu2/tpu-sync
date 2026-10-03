/-!
# Session lifecycle

The settle protocol shared by TPU Sync's session classes
(`TransferReceiveSession`, `TransferSendSession`, `ReshardReceiveSession`,
`ReshardSendSession`): a count of in-flight operations, a `draining_` flag that
stops new ones, and a `done_` flag set by whichever of `Finish` or the last
`EndOp` comes second. The session owns its host staging until it settles.

Citations are to tpu-sync `01ffa3d`; `recv` is
`tpu_sync/core/transfer_receive_session.{h,cc}`, `send` is
`tpu_sync/core/transfer_send_session.{h,cc}`.

| Field        | recv                     | send                     |
|--------------|--------------------------|--------------------------|
| `inFlight`   | `in_flight_` (`.h:241`)  | `in_flight_` (`.h:181`)  |
| `draining`   | `draining_` (`.h:243`)   | `draining_` (`.h:184`)   |
| `done`       | `done_` (`.h:244`)       | `done_` (`.h:185`)       |
| `statusOk`   | `status_.ok()` (`.h:242`) | `status_.ok()` (`.h:177`) |
| `hasStaging` | `!staging_.empty()` (`.h:229`, `HasStaging` `.h:102-105`) | `!staging_.empty()` (`.h:170`, `HasStaging` `.h:83-86`); see below |

The two classes settle the same way but decide their status differently:

* `finishLocked` is the receiver's `FinishLocked` (`recv.cc:361-371`): the
  **first error wins** — a later `Finish(error)` on a session that is already
  draining still flips the status.
* `finishOnceLocked` is the sender's `FinishLocked` (`send.cc:167-175`): the
  **first `Finish` wins** — once draining or done, later calls are ignored,
  whatever their status.

`endOpLocked` transcribes `EndRecvOpLocked` (`recv.cc:384-394`), whose
underflow branch is a no-op. The sender's `EndSendOpLocked` (`send.cc:188-194`)
decrements unconditionally; the send model records an underflow instead of
reusing the no-op so that its absence can be proved. `beginOp` transcribes
`TryBeginRecvOp` (`recv.h:109-114`) and the sender's `if (draining_) return;
++in_flight_` pattern (`send.cc:329-330, 377-381, 413-420`), which refuses on
`draining_` alone; the two agree under `Consistent`.

The sender acquires its staging inside `StartPush` rather than at creation. Its
model starts `Lifecycle` with `hasStaging = true` all the same and reads the
flag as "not yet released": the slot is actually held iff the flag is set and
the acquisition happened.

`Consistent` is the invariant of the protocol on its own: a settled session has
nothing in flight and no staging, and a draining session settles as soon as its
last operation ends.
-/

namespace TpuSyncVerify.Transfer

structure Lifecycle where
  inFlight : Nat := 0
  draining : Bool := false
  done : Bool := false
  statusOk : Bool := true
  hasStaging : Bool := true
  deriving Repr, DecidableEq

namespace Lifecycle

/-- The settle check at the end of both `FinishLocked` (`.cc:367-370`) and
`EndRecvOpLocked` (`.cc:390-393`): draining with nothing in flight releases
staging and marks the session done. -/
def settleLocked (l : Lifecycle) : Lifecycle :=
  if l.draining = true ∧ l.inFlight = 0 ∧ l.done = false then
    { l with hasStaging := false, done := true }
  else l

/-- The receiver's `FinishLocked(status)` (`recv.cc:361-371`): `draining` is
sticky and the first error wins (`ok = false` flips `statusOk` even if already
draining). -/
def finishLocked (ok : Bool) (l : Lifecycle) : Lifecycle :=
  let l := if ok = false ∧ l.statusOk = true then { l with statusOk := false } else l
  if l.draining = true then l else settleLocked { l with draining := true }

/-- The sender's `FinishLocked(status)` (`send.cc:167-175`): the first call
decides the outcome, later ones are ignored. -/
def finishOnceLocked (ok : Bool) (l : Lifecycle) : Lifecycle :=
  if l.draining = true ∨ l.done = true then l
  else settleLocked { l with draining := true, statusOk := ok }

/-- `EndRecvOpLocked` (`.cc:384-394`). The underflow branch (`.cc:385-388`,
`LOG(DFATAL)`) leaves the state unchanged. -/
def endOpLocked (l : Lifecycle) : Lifecycle :=
  if l.inFlight = 0 then l else settleLocked { l with inFlight := l.inFlight - 1 }

/-- `TryBeginRecvOp` (`.h:109-114`): refused once settled or draining. -/
def beginOp (l : Lifecycle) : Option Lifecycle :=
  if l.done = true ∨ l.draining = true then none
  else some { l with inFlight := l.inFlight + 1 }

/-! ## Invariant of the protocol -/

/-- A settled session is draining, owns no work and no staging; a draining
session with no work left is settled. -/
structure Consistent (l : Lifecycle) : Prop where
  done_draining : l.done = true → l.draining = true
  done_idle : l.done = true → l.inFlight = 0
  prompt : l.draining = true → l.inFlight = 0 → l.done = true
  staging : l.hasStaging = !l.done

theorem consistent_init : Consistent {} := by
  constructor <;> simp

theorem settleLocked_consistent {l : Lifecycle}
    (h₁ : l.done = true → l.draining = true)
    (h₂ : l.done = true → l.inFlight = 0)
    (h₃ : l.hasStaging = !l.done) :
    Consistent (settleLocked l) := by
  unfold settleLocked
  split
  · rename_i h
    obtain ⟨hd, hi, hn⟩ := h
    constructor <;> simp [hd, hi]
  · rename_i h
    refine ⟨h₁, h₂, ?_, h₃⟩
    intro hd hi
    cases hdone : l.done with
    | true => rfl
    | false => exact absurd ⟨hd, hi, hdone⟩ h

theorem finishLocked_consistent {l : Lifecycle} (ok : Bool) (h : Consistent l) :
    Consistent (finishLocked ok l) := by
  have key : ∀ l' : Lifecycle, Consistent l' →
      Consistent (if l'.draining = true then l' else settleLocked { l' with draining := true }) := by
    intro l' h'
    split
    · exact h'
    · exact settleLocked_consistent (by simp) (by simpa using h'.done_idle)
        (by simpa using h'.staging)
  simp only [finishLocked]
  split
  · exact key _ ⟨h.done_draining, h.done_idle, h.prompt, h.staging⟩
  · exact key _ h

theorem finishOnceLocked_consistent {l : Lifecycle} (ok : Bool) (h : Consistent l) :
    Consistent (finishOnceLocked ok l) := by
  unfold finishOnceLocked
  split
  · exact h
  · exact settleLocked_consistent (by simp) (by simpa using h.done_idle)
      (by simpa using h.staging)

/-- Contrapositive of `done_draining`. -/
theorem Consistent.not_done {l : Lifecycle} (h : Consistent l) (hd : l.draining = false) :
    l.done = false := by
  cases hdone : l.done
  · rfl
  · have := h.done_draining hdone
    simp [hd] at this

/-- Staging is only released by settling. -/
theorem Consistent.done_of_released {l : Lifecycle} (h : Consistent l)
    (hs : l.hasStaging = false) : l.done = true := by
  have := h.staging
  cases hdone : l.done <;> simp_all

/-- Taking an op on a session that is not draining (hence not done). -/
theorem consistent_incr {l : Lifecycle} (h : Consistent l) (hd : l.draining = false) :
    Consistent { l with inFlight := l.inFlight + 1 } := by
  have := h.not_done hd
  constructor <;> simp [hd, this, h.staging]

theorem endOpLocked_consistent {l : Lifecycle} (h : Consistent l) :
    Consistent (endOpLocked l) := by
  unfold endOpLocked
  split
  · exact h
  · apply settleLocked_consistent
    · simpa using h.done_draining
    · intro hd
      have := h.done_idle hd
      simp; omega
    · simpa using h.staging

theorem beginOp_consistent {l l' : Lifecycle} (h : Consistent l) (hb : beginOp l = some l') :
    Consistent l' := by
  unfold beginOp at hb
  split at hb
  · cases hb
  · rename_i hn
    cases hb
    have hd : l.done = false := by
      cases hdone : l.done
      · rfl
      · exact absurd (Or.inl hdone) hn
    have hdr : l.draining = false := by
      cases hdrain : l.draining
      · rfl
      · exact absurd (Or.inr hdrain) hn
    constructor <;> simp [hd, hdr, h.staging]

/-! ## What each operation does to `inFlight` -/

@[simp] theorem settleLocked_inFlight (l : Lifecycle) :
    (settleLocked l).inFlight = l.inFlight := by
  unfold settleLocked; split <;> rfl

@[simp] theorem finishLocked_inFlight (ok : Bool) (l : Lifecycle) :
    (finishLocked ok l).inFlight = l.inFlight := by
  simp only [finishLocked]
  split <;> split <;> simp

@[simp] theorem endOpLocked_inFlight (l : Lifecycle) :
    (endOpLocked l).inFlight = l.inFlight - 1 := by
  unfold endOpLocked
  split
  · omega
  · simp

theorem beginOp_inFlight {l l' : Lifecycle} (hb : beginOp l = some l') :
    l'.inFlight = l.inFlight + 1 := by
  unfold beginOp at hb
  split at hb
  · cases hb
  · cases hb; rfl

theorem beginOp_active {l l' : Lifecycle} (hb : beginOp l = some l') :
    l.done = false ∧ l.draining = false := by
  unfold beginOp at hb
  split at hb
  · cases hb
  · rename_i hn
    constructor
    · cases hdone : l.done
      · rfl
      · exact absurd (Or.inl hdone) hn
    · cases hdrain : l.draining
      · rfl
      · exact absurd (Or.inr hdrain) hn

/-! ## What each operation does to `statusOk` and `draining` -/

@[simp] theorem settleLocked_statusOk (l : Lifecycle) :
    (settleLocked l).statusOk = l.statusOk := by
  unfold settleLocked; split <;> rfl

@[simp] theorem settleLocked_draining (l : Lifecycle) :
    (settleLocked l).draining = l.draining := by
  unfold settleLocked; split <;> rfl

/-- `FinishLocked` records the first error: the status stays OK only if it was
OK and this finish is OK. -/
@[simp] theorem finishLocked_statusOk (ok : Bool) (l : Lifecycle) :
    (finishLocked ok l).statusOk = (ok && l.statusOk) := by
  have key : ∀ l' : Lifecycle,
      (if l'.draining = true then l' else settleLocked { l' with draining := true }).statusOk
        = l'.statusOk := by
    intro l'; split <;> simp
  simp only [finishLocked]
  split
  · rename_i h
    rw [key]
    simp [h.1]
  · rename_i h
    rw [key]
    cases ok <;> cases hst : l.statusOk <;> simp_all

@[simp] theorem finishLocked_draining (ok : Bool) (l : Lifecycle) :
    (finishLocked ok l).draining = true := by
  simp only [finishLocked]
  split <;> split <;> simp_all

/-- `finishOnceLocked` is the identity once the outcome is decided, and
otherwise starts draining with the given status. -/
theorem finishOnceLocked_decided {l : Lifecycle} (ok : Bool)
    (h : l.draining = true ∨ l.done = true) : finishOnceLocked ok l = l := by
  unfold finishOnceLocked; simp [h]

theorem finishOnceLocked_open {l : Lifecycle} (ok : Bool)
    (hd : l.draining = false) (hn : l.done = false) :
    finishOnceLocked ok l = settleLocked { l with draining := true, statusOk := ok } := by
  unfold finishOnceLocked; simp [hd, hn]

@[simp] theorem finishOnceLocked_inFlight (ok : Bool) (l : Lifecycle) :
    (finishOnceLocked ok l).inFlight = l.inFlight := by
  unfold finishOnceLocked; split <;> simp

/-- The first `Finish` decides: the status only changes if nothing had been
decided yet. -/
@[simp] theorem finishOnceLocked_statusOk (ok : Bool) (l : Lifecycle) :
    (finishOnceLocked ok l).statusOk =
      (if l.draining = true ∨ l.done = true then l.statusOk else ok) := by
  unfold finishOnceLocked; split <;> simp_all

@[simp] theorem finishOnceLocked_draining (ok : Bool) (l : Lifecycle) :
    (finishOnceLocked ok l).draining = (l.draining || !l.done) := by
  unfold finishOnceLocked
  split
  · rename_i h
    rcases h with h | h <;> simp [h]
  · rename_i h
    simp only [not_or] at h
    simp [h.1, h.2]

@[simp] theorem endOpLocked_statusOk (l : Lifecycle) :
    (endOpLocked l).statusOk = l.statusOk := by
  unfold endOpLocked; split <;> simp

@[simp] theorem endOpLocked_draining (l : Lifecycle) :
    (endOpLocked l).draining = l.draining := by
  unfold endOpLocked; split <;> simp

theorem beginOp_statusOk {l l' : Lifecycle} (hb : beginOp l = some l') :
    l'.statusOk = l.statusOk := by
  unfold beginOp at hb
  split at hb
  · cases hb
  · cases hb; rfl

theorem beginOp_draining {l l' : Lifecycle} (hb : beginOp l = some l') :
    l'.draining = false := by
  unfold beginOp at hb
  split at hb
  · cases hb
  · rename_i hn
    cases hb
    cases hdrain : l.draining
    · rfl
    · exact absurd (Or.inr hdrain) hn

theorem beginOp_done {l l' : Lifecycle} (hb : beginOp l = some l') :
    l'.done = false := by
  unfold beginOp at hb
  split at hb
  · cases hb
  · rename_i hn
    cases hb
    cases hdone : l.done
    · rfl
    · exact absurd (Or.inl hdone) hn

/-- A settled session refuses new ops. -/
theorem beginOp_of_done {l : Lifecycle} (hd : l.done = true) : beginOp l = none := by
  unfold beginOp; simp [hd]

/-- A draining session refuses new ops. -/
theorem beginOp_of_draining {l : Lifecycle} (hdr : l.draining = true) : beginOp l = none := by
  unfold beginOp; simp [hdr]

/-! ## `done` is never cleared -/

theorem settleLocked_done_mono {l : Lifecycle} (h : l.done = true) :
    (settleLocked l).done = true := by
  unfold settleLocked; split <;> simp_all

theorem finishLocked_done_mono {l : Lifecycle} (ok : Bool) (h : l.done = true) :
    (finishLocked ok l).done = true := by
  simp only [finishLocked]
  split <;> split
  · simpa using h
  · exact settleLocked_done_mono (by simpa using h)
  · exact h
  · exact settleLocked_done_mono (by simpa using h)

theorem finishOnceLocked_done_mono {l : Lifecycle} (ok : Bool) (h : l.done = true) :
    (finishOnceLocked ok l).done = true := by
  rw [finishOnceLocked_decided ok (Or.inr h)]; exact h

theorem endOpLocked_done_mono {l : Lifecycle} (h : l.done = true) :
    (endOpLocked l).done = true := by
  unfold endOpLocked
  split
  · exact h
  · exact settleLocked_done_mono (by simpa using h)

/-! ## Redundant `done_` guards

Audit of the `done_` mentions in the receiver's lifecycle guards (`recv` at
`01ffa3d`; the same code sits at `b68161a` lines `.cc:365`, `.cc:388`,
`.cc:520`, `.cc:565`, `.h:111`). `Consistent` already decides each of them:

* `FinishLocked` `.cc:367`: past the `if (draining_) return` (`.cc:365`),
  `!done_` holds — `Consistent.not_done`;
* `EndRecvOpLocked` `.cc:390`: past the underflow return (`.cc:385-388`),
  `!done_` holds — `Consistent.not_done_of_inFlight`;
* `done_ || draining_` in `TryBeginRecvOp` (`.h:111`), `OnBlocksReceived`
  (`.cc:537`) and `ExecuteLayerH2d` (`.cc:582`, `.cc:608`) is `draining_` —
  `Consistent.done_or_draining`.

The sender has the same two: `send.cc:168` (`draining_ || done_`) and
`send.cc:190` (`!done_`).

The primed functions below are the transcriptions with those guards removed.
They agree with the originals on every `Consistent` lifecycle, and every
model built on this file keeps `Consistent` as part of its invariant
(`Recv.Inv.life`, `Send.Inv.life`), so dropping the guards changes no
transition of any reachable state. The `LOG(DFATAL)` branches
(`.cc:385-388`, `.cc:651-653`) are a different matter: they are assertions,
unreachable by `Accounted` and `NoRetiredCallback` respectively, not
redundant tests of an already-known value. -/

/-- `settleLocked` without the `!done_` conjunct. -/
def settleLocked' (l : Lifecycle) : Lifecycle :=
  if l.draining = true ∧ l.inFlight = 0 then { l with hasStaging := false, done := true }
  else l

/-- `FinishLocked` without the `!done_` at `.cc:367`. -/
def finishLocked' (ok : Bool) (l : Lifecycle) : Lifecycle :=
  let l := if ok = false ∧ l.statusOk = true then { l with statusOk := false } else l
  if l.draining = true then l else settleLocked' { l with draining := true }

/-- `EndRecvOpLocked` without the `!done_` at `.cc:390`. -/
def endOpLocked' (l : Lifecycle) : Lifecycle :=
  if l.inFlight = 0 then l else settleLocked' { l with inFlight := l.inFlight - 1 }

/-- `TryBeginRecvOp` refusing on `draining_` alone (the sender's pattern). -/
def beginOp' (l : Lifecycle) : Option Lifecycle :=
  if l.draining = true then none else some { l with inFlight := l.inFlight + 1 }

/-- Contrapositive of `done_idle`: a session with work in flight is not done. -/
theorem Consistent.not_done_of_inFlight {l : Lifecycle} (h : Consistent l)
    (hi : l.inFlight ≠ 0) : l.done = false := by
  cases hd : l.done
  · rfl
  · exact absurd (h.done_idle hd) hi

/-- `done_ || draining_` is `draining_`. -/
theorem Consistent.done_or_draining {l : Lifecycle} (h : Consistent l) :
    (l.done || l.draining) = l.draining := by
  cases hd : l.done
  · simp
  · simp [h.done_draining hd]

theorem settleLocked'_eq {l : Lifecycle}
    (h : l.draining = true → l.inFlight = 0 → l.done = false) :
    settleLocked' l = settleLocked l := by
  unfold settleLocked' settleLocked
  split <;> split
  · rfl
  · rename_i hc hc'
    exact absurd ⟨hc.1, hc.2, h hc.1 hc.2⟩ hc'
  · rename_i hc hc'
    exact absurd ⟨hc'.1, hc'.2.1⟩ hc
  · rfl

theorem finishLocked'_eq {l : Lifecycle} (ok : Bool) (h : Consistent l) :
    finishLocked' ok l = finishLocked ok l := by
  have key : ∀ l' : Lifecycle, (l'.done = true → l'.draining = true) →
      (if l'.draining = true then l' else settleLocked' { l' with draining := true })
        = (if l'.draining = true then l' else settleLocked { l' with draining := true }) := by
    intro l' hdd
    split
    · rfl
    · rename_i hn
      apply settleLocked'_eq
      intro _ _
      show l'.done = false
      cases hd : l'.done
      · rfl
      · exact absurd (hdd hd) hn
  simp only [finishLocked', finishLocked]
  split
  · exact key _ h.done_draining
  · exact key _ h.done_draining

theorem endOpLocked'_eq {l : Lifecycle} (h : Consistent l) :
    endOpLocked' l = endOpLocked l := by
  unfold endOpLocked' endOpLocked
  split
  · rfl
  · rename_i hn
    apply settleLocked'_eq
    intro _ _
    show l.done = false
    exact h.not_done_of_inFlight hn

theorem beginOp'_eq {l : Lifecycle} (h : Consistent l) : beginOp' l = beginOp l := by
  unfold beginOp' beginOp
  cases hdr : l.draining
  · simp [h.not_done hdr]
  · simp

end Lifecycle

end TpuSyncVerify.Transfer
