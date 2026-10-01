/-!
# Session lifecycle

The settle protocol shared by TPU Sync's session classes
(`TransferReceiveSession`, `TransferSendSession`, `ReshardReceiveSession`,
`ReshardSendSession`): a count of in-flight operations, a `draining_` flag that
stops new ones, and a `done_` flag set by whichever of `Finish` or the last
`EndOp` comes second. The session owns its host staging until it settles.

Citations are to tpu-sync `01ffa3d`, `tpu_sync/core/transfer_receive_session.{h,cc}`.

| Field        | C++                                         |
|--------------|---------------------------------------------|
| `inFlight`   | `in_flight_` (`.h:241`)                     |
| `draining`   | `draining_` (`.h:243`)                      |
| `done`       | `done_` (`.h:244`)                          |
| `statusOk`   | `status_.ok()` (`.h:242`); the first error wins (`.cc:362-364`) |
| `hasStaging` | `!staging_.empty()` (`.h:229`, `HasStaging` `.h:102-105`) |

`finishLocked` and `endOpLocked` transcribe `FinishLocked` (`.cc:361-371`) and
`EndRecvOpLocked` (`.cc:384-394`); `beginOp` transcribes `TryBeginRecvOp`
(`.h:109-114`). Session models compose their events from these three so the
settle rules are written down once.

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

/-- `FinishLocked(status)` (`.cc:361-371`). Idempotent: a second call only
records the status. -/
def finishLocked (ok : Bool) (l : Lifecycle) : Lifecycle :=
  let l := if ok = false ∧ l.statusOk = true then { l with statusOk := false } else l
  if l.draining = true then l else settleLocked { l with draining := true }

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

theorem endOpLocked_done_mono {l : Lifecycle} (h : l.done = true) :
    (endOpLocked l).done = true := by
  unfold endOpLocked
  split
  · exact h
  · exact settleLocked_done_mono (by simpa using h)

end Lifecycle

end TpuSyncVerify.Transfer
