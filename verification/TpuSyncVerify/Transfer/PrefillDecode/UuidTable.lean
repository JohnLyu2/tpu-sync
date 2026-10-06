import TpuSyncVerify.Common.ListAux
import TpuSyncVerify.Transfer.PrefillDecode.Receive
import TpuSyncVerify.Transfer.PrefillDecode.Send

/-!
# UUID registration table and drain-before-reuse discipline

Models `KVCacheManagerWithTransfer`'s UUID-keyed session tables
(`active_recv_sessions_[uuid]` on the decode consumer and `send_sessions_[uuid]`
on the prefill producer) and its terminal report sets (`done_sending_`,
`done_recving_`, `failed_recving_`) across duplicate announcements, conflicting
UUIDs, and session retries (`tpu_sync/core/kv_cache_manager_with_transfer.cc:443-492,
842-882, 908-994`, `tpu_sync/core/kv_cache_manager_with_transfer_send_drain_test.cc:363-380,
633-682`, `tpu_sync/core/kv_cache_manager_with_transfer_control_test.cc:718-790`,
tpu-sync `50b0774`, re-pinned from `01ffa3d` on 2026-10-06).

## Protocol rules encoded

1. **Consumer `StartRead(req_id, uuid, ...)` (`mgr.cc:845-881`):**
   - If `active_recv_sessions_[uuid]` holds an incumbent with `!Done()`
     (`done = false`, including when `draining = true` with in-flight H2D/push/pull
     work):
     - **Same `req_id` (`incumbent->req_id() == req_id`, `:856`):** idempotent
       re-announcement — returns immediately without allocating staging,
       replacing the incumbent, or recording a failure
       (`RepeatedReceiveAnnouncementIsIdempotent`, `:765-801`).
     - **Different `req_id` (`incumbent->req_id() != req_id`, `:856-858`):**
       rejects the duplicate — leaves the incumbent untouched, allocates no
       staging slot, and records the duplicate `req_id` in `failed_recving_`
       (`DuplicateReceiveDoesNotReplaceOrLeakFirstRead`, `:729-763`).
   - If `active_recv_sessions_[uuid]` holds an already-settled incumbent
     (`incumbent->Done()`, `:847-851`), `StartRead` retires it inline into
     `done_recving_` / `failed_recving_` and erases it before creating the new
     session.

2. **Consumer `EmplaceRecvSessionLocked(uuid, session)` / `RegisterRecv`
   (`mgr.cc:477-492, 528-532`):**
   - Retires an existing entry only if `existing->second->Done()` (`:480-484`).
   - If an incumbent is still draining (`done = false`), `try_emplace` fails
     with `AlreadyExistsError` (`:487-490`) and the caller releases the
     candidate's staging (`:529-531`, `:875-877`), keeping the draining
     incumbent authoritative until all in-flight operations finish
     (`DuplicateUuidIsRejectedUntilExpiredReceiveDrains`, `send_drain_test.cc:633-682`).

3. **Producer `NotifyForRead(req_id, uuid, ...)` (`mgr.cc:459-463`):**
   - `send_sessions_.try_emplace(uuid, session)` rejects any duplicate `uuid`
     while a live offer is present (`DuplicateRegistrationCannotReplaceLiveOffer`,
     `send_drain_test.cc:363-380`).

4. **Sweep in `CompleteReadRaw()` (`mgr.cc:916-994`):**
   - Only sessions with `Done()` (`done = true`) are reported into
     `done_sending_` / `done_recving_` / `failed_recving_` and erased from
     `send_sessions_` / `active_recv_sessions_`.

## Main results

- **Resource conservation & session invariants (`reachable_inv`,
  `reachable_recv_safe`, `reachable_send_safe`):**
  `freeSlots + activeStaging recvTable = cfg.numSlots` holds on every reachable
  state (relying on `Recv.StagingIntegrity`: an entry is only erased or
  retired inline when `done = true`, at which point `hasStaging = false`), and
  every active entry satisfies `Recv.Safe` / `Send.Safe`.
- **Drain-before-reuse persistence (`active_recv_preserved`,
  `active_send_preserved`):**
  While an incumbent at `uuid` has `life.done = false` (in particular, whenever
  `0 < life.inFlight`), no enabled event (`startRead`, `registerRecv`,
  `notifyForRead`, `sweepRecv`, `sweepSend`, `recvStep`, `sendStep`) can remove
  it or change its `(reqId, gen)`.
-/

namespace TpuSyncVerify.Transfer.PrefillDecode.UuidTable

open TpuSyncVerify.Transfer (Lifecycle)
open TpuSyncVerify.Transfer.PrefillDecode (Recv Send)

abbrev Uuid := Nat
abbrev ReqId := Nat

instance : DecidableEq Uuid := inferInstanceAs (DecidableEq Nat)
instance : DecidableEq ReqId := inferInstanceAs (DecidableEq Nat)

/-- One entry in `active_recv_sessions_[uuid]`, tagged with its `reqId` and a
monotonic registration generation `gen`. -/
structure RecvEntry where
  reqId : ReqId
  gen : Nat
  recv : Recv
  deriving Repr, DecidableEq

/-- One entry in `send_sessions_[uuid]`, tagged with its `reqId`. -/
structure SendEntry where
  reqId : ReqId
  gen : Nat
  send : Send
  deriving Repr, DecidableEq

def slotHasStaging : Option RecvEntry → Bool
  | none => false
  | some e => e.recv.life.hasStaging

/-- Number of entries in `recvTable` currently holding a host staging slot. -/
def activeStaging : List (Option RecvEntry) → Nat
  | [] => 0
  | o :: os => (if slotHasStaging o then 1 else 0) + activeStaging os

/-- Set-like insertion (`absl::flat_hash_set::insert`) into a report list. -/
def insertReq (rs : List ReqId) (r : ReqId) : List ReqId :=
  if r ∈ rs then rs else rs ++ [r]

/-- Record a settled receive session's outcome in `doneRecving` or `failedRecving`
(`mgr.cc:848-849, 982-983`). -/
def recordRecvReport (doneRecving failedRecving : List ReqId)
    (reqId : ReqId) (statusOk : Bool) : List ReqId × List ReqId :=
  if statusOk then
    (insertReq doneRecving reqId, failedRecving)
  else
    (doneRecving, insertReq failedRecving reqId)

/-- Record a settled send session's outcome in `doneSending` or `failedRecving`
(`mgr.cc:927-928`). -/
def recordSendReport (doneSending failedRecving : List ReqId)
    (reqId : ReqId) (statusOk : Bool) : List ReqId × List ReqId :=
  if statusOk then
    (insertReq doneSending reqId, failedRecving)
  else
    (doneSending, insertReq failedRecving reqId)

structure Config where
  numLayers : Nat := 1
  numSlots : Nat := 4
  numUuids : Nat := 2
  deriving Repr, DecidableEq

structure State where
  cfg : Config
  freeSlots : Nat
  nextGen : Nat := 0
  recvTable : List (Option RecvEntry)
  sendTable : List (Option SendEntry)
  doneSending : List ReqId := []
  doneRecving : List ReqId := []
  failedRecving : List ReqId := []
  deriving Repr, DecidableEq

def init (cfg : Config) : State :=
  { cfg,
    freeSlots := cfg.numSlots,
    recvTable := List.replicate cfg.numUuids none,
    sendTable := List.replicate cfg.numUuids none }

inductive Ev where
  /-- `StartRead(req_id, uuid, ...)` (`mgr.cc:845-881`): creates a load-plan
  receive session (`Recv.initLoad`), with idempotent same-`reqId` handling and
  immediate `failed_recving_` reporting on a conflicting duplicate `reqId`. -/
  | startRead (reqId : ReqId) (uuid : Uuid)
  /-- `RegisterRecv` / `EmplaceRecvSessionLocked(uuid, session)` (`mgr.cc:477-492,
  528-532`): creates a push-plan receive session (`Recv.initPush`); rejects any
  duplicate `uuid` whose incumbent has `!Done()` without leaking staging. -/
  | registerRecv (reqId : ReqId) (uuid : Uuid)
  /-- Step the active receive session at `uuid` (`Receive.lean`). -/
  | recvStep (uuid : Uuid) (e : Recv.Ev)
  /-- `CompleteReadRaw` sweeps a settled (`Done()`) receive at `uuid`
  (`mgr.cc:981-991`). -/
  | sweepRecv (uuid : Uuid)
  /-- `NotifyForRead(req_id, uuid, ...)` (`mgr.cc:443-464`): registers a send
  offer in `send_sessions_[uuid]`; rejects any duplicate `uuid`. -/
  | notifyForRead (reqId : ReqId) (uuid : Uuid)
  /-- Step the active send session at `uuid` (`Send.lean`). -/
  | sendStep (uuid : Uuid) (e : Send.Ev)
  /-- `CompleteReadRaw` sweeps a settled (`Done()`) send at `uuid`
  (`mgr.cc:926-935`). -/
  | sweepSend (uuid : Uuid)
  deriving Repr, DecidableEq

def step (s : State) : Ev → Option State
  | .startRead reqId uuid =>
    match s.recvTable[uuid]? with
    | none => none
    | some (some inc) =>
      if !inc.recv.life.done then
        -- Incumbent is still active or draining (`mgr.cc:851-860`).
        if inc.reqId == reqId then
          some s
        else
          some { s with failedRecving := insertReq s.failedRecving reqId }
      else
        -- Incumbent is already `Done()`: retire inline (`mgr.cc:847-851`).
        let (doneR, failR) :=
          recordRecvReport s.doneRecving s.failedRecving inc.reqId inc.recv.life.statusOk
        if 0 < s.freeSlots then
          let entry : RecvEntry :=
            { reqId, gen := s.nextGen, recv := Recv.initLoad s.cfg.numLayers }
          some { s with
            freeSlots := s.freeSlots - 1,
            nextGen := s.nextGen + 1,
            recvTable := s.recvTable.set uuid (some entry),
            doneRecving := doneR,
            failedRecving := failR }
        else
          some { s with
            recvTable := s.recvTable.set uuid none,
            doneRecving := doneR,
            failedRecving := insertReq failR reqId }
    | some none =>
      if 0 < s.freeSlots then
        let entry : RecvEntry :=
          { reqId, gen := s.nextGen, recv := Recv.initLoad s.cfg.numLayers }
        some { s with
          freeSlots := s.freeSlots - 1,
          nextGen := s.nextGen + 1,
          recvTable := s.recvTable.set uuid (some entry) }
      else
        some { s with failedRecving := insertReq s.failedRecving reqId }
  | .registerRecv reqId uuid =>
    match s.recvTable[uuid]? with
    | none => none
    | some (some inc) =>
      if !inc.recv.life.done then
        -- `EmplaceRecvSessionLocked` returns `AlreadyExistsError` and caller
        -- releases the candidate's staging (`mgr.cc:487-490, 529-531`).
        none
      else if 0 < s.freeSlots then
        let (doneR, failR) :=
          recordRecvReport s.doneRecving s.failedRecving inc.reqId inc.recv.life.statusOk
        let entry : RecvEntry :=
          { reqId, gen := s.nextGen, recv := Recv.initPush s.cfg.numLayers }
        some { s with
          freeSlots := s.freeSlots - 1,
          nextGen := s.nextGen + 1,
          recvTable := s.recvTable.set uuid (some entry),
          doneRecving := doneR,
          failedRecving := failR }
      else
        none
    | some none =>
      if 0 < s.freeSlots then
        let entry : RecvEntry :=
          { reqId, gen := s.nextGen, recv := Recv.initPush s.cfg.numLayers }
        some { s with
          freeSlots := s.freeSlots - 1,
          nextGen := s.nextGen + 1,
          recvTable := s.recvTable.set uuid (some entry) }
      else
        none
  | .recvStep uuid e =>
    match s.recvTable[uuid]? with
    | none => none
    | some none => none
    | some (some entry) =>
      match Recv.step entry.recv e with
      | none => none
      | some recv' =>
        let entry' : RecvEntry := { entry with recv := recv' }
        let freeSlots' :=
          if entry.recv.life.hasStaging && !recv'.life.hasStaging then
            s.freeSlots + 1
          else s.freeSlots
        some { s with
          freeSlots := freeSlots',
          recvTable := s.recvTable.set uuid (some entry') }
  | .sweepRecv uuid =>
    match s.recvTable[uuid]? with
    | none => none
    | some none => none
    | some (some entry) =>
      if entry.recv.life.done then
        let (doneR, failR) :=
          recordRecvReport s.doneRecving s.failedRecving entry.reqId entry.recv.life.statusOk
        some { s with
          recvTable := s.recvTable.set uuid none,
          doneRecving := doneR,
          failedRecving := failR }
      else
        none
  | .notifyForRead reqId uuid =>
    match s.sendTable[uuid]? with
    | none => none
    | some (some _) =>
      -- `send_sessions_.try_emplace(uuid, session)` fails (`mgr.cc:459-462`).
      none
    | some none =>
      let entry : SendEntry :=
        { reqId, gen := s.nextGen, send := Send.init s.cfg.numLayers }
      some { s with
        nextGen := s.nextGen + 1,
        sendTable := s.sendTable.set uuid (some entry) }
  | .sendStep uuid e =>
    match s.sendTable[uuid]? with
    | none => none
    | some none => none
    | some (some entry) =>
      match Send.step entry.send e with
      | none => none
      | some send' =>
        some { s with
          sendTable := s.sendTable.set uuid (some { entry with send := send' }) }
  | .sweepSend uuid =>
    match s.sendTable[uuid]? with
    | none => none
    | some none => none
    | some (some entry) =>
      if entry.send.life.done then
        let (doneS, failR) :=
          recordSendReport s.doneSending s.failedRecving entry.reqId entry.send.life.statusOk
        some { s with
          sendTable := s.sendTable.set uuid none,
          doneSending := doneS,
          failedRecving := failR }
      else
        none

def sys (cfg : Config) : System State Ev where
  init := init cfg
  step := step

/-! ## Helper lemmas on `activeStaging` and `Recv.step` -/

theorem settleLocked_hasStaging_false {l : Lifecycle} (h : l.hasStaging = false) :
    (Lifecycle.settleLocked l).hasStaging = false := by
  unfold Lifecycle.settleLocked; split <;> simp [h]

theorem finishLocked_hasStaging_false {l : Lifecycle} (ok : Bool) (h : l.hasStaging = false) :
    (Lifecycle.finishLocked ok l).hasStaging = false := by
  simp only [Lifecycle.finishLocked]
  split <;> split
  · exact h
  · exact settleLocked_hasStaging_false h
  · exact h
  · exact settleLocked_hasStaging_false h

theorem endOpLocked_hasStaging_false {l : Lifecycle} (h : l.hasStaging = false) :
    (Lifecycle.endOpLocked l).hasStaging = false := by
  unfold Lifecycle.endOpLocked
  split
  · exact h
  · exact settleLocked_hasStaging_false h

theorem recv_step_hasStaging_false {r r' : Recv} {e : Recv.Ev}
    (hs : Recv.step r e = some r') (h : r.life.hasStaging = false) :
    r'.life.hasStaging = false := by
  cases e <;>
    simp only [Recv.step, Recv.pushBegin, Recv.pushEnd, Recv.pullReply, Recv.h2dBegin,
      Recv.h2dIssue, Recv.h2dReady, Recv.h2dDone, Recv.netAccount, Recv.pollReady,
      Recv.cancel, Recv.publish] at hs <;>
    (repeat' split at hs)
  all_goals
    first
      | (simp only [Option.map_eq_some_iff, Lifecycle.beginOp] at hs
         obtain ⟨l, hl, rfl⟩ := hs
         split at hl <;> cases hl; exact h)
      | (cases hs <;> (repeat' split) <;>
         simp [h, finishLocked_hasStaging_false, endOpLocked_hasStaging_false])

theorem activeStaging_replicate_none : ∀ n, activeStaging (List.replicate n none) = 0
  | 0 => rfl
  | n + 1 => by simp [List.replicate_succ, activeStaging, slotHasStaging, activeStaging_replicate_none n]

theorem activeStaging_set_from_false :
    ∀ {os : List (Option RecvEntry)} {uuid : Nat} {o o' : Option RecvEntry},
      os[uuid]? = some o →
      slotHasStaging o = false →
      activeStaging (os.set uuid o') =
        activeStaging os + (if slotHasStaging o' then 1 else 0)
  | [], _, _, _, h, _ => by simp at h
  | a :: as, 0, o, o', h, hfalse => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h
    subst h
    simp [activeStaging, hfalse]; omega
  | a :: as, uuid + 1, o, o', h, hfalse => by
    simp only [List.getElem?_cons_succ] at h
    have ih := activeStaging_set_from_false (o' := o') h hfalse
    simp only [List.set_cons_succ, activeStaging, ih]; omega

theorem activeStaging_set_step :
    ∀ {os : List (Option RecvEntry)} {uuid : Nat} {e e' : RecvEntry},
      os[uuid]? = some (some e) →
      (e.recv.life.hasStaging = false → e'.recv.life.hasStaging = false) →
      activeStaging (os.set uuid (some e')) +
        (if e.recv.life.hasStaging && !e'.recv.life.hasStaging then 1 else 0) =
        activeStaging os
  | [], _, _, _, h, _ => by simp at h
  | a :: as, 0, e, e', h, hmono => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h
    subst h
    cases h1 : e.recv.life.hasStaging <;> cases h2 : e'.recv.life.hasStaging
    · simp [activeStaging, slotHasStaging, h1, h2]
    · have := hmono h1; simp [h2] at this
    · simp [activeStaging, slotHasStaging, h1, h2]; omega
    · simp [activeStaging, slotHasStaging, h1, h2]
  | a :: as, uuid + 1, e, e', h, hmono => by
    simp only [List.getElem?_cons_succ] at h
    have ih := activeStaging_set_step h hmono
    simp only [List.set_cons_succ, activeStaging]; omega

/-! ## Inductive invariant and resource conservation -/

structure Inv (s : State) : Prop where
  slots : s.freeSlots + activeStaging s.recvTable = s.cfg.numSlots
  recv_inv : ∀ e : RecvEntry, some e ∈ s.recvTable → Recv.Inv e.recv
  send_inv : ∀ e : SendEntry, some e ∈ s.sendTable → Send.Inv e.send

theorem inv_init (cfg : Config) : Inv (init cfg) := by
  refine ⟨by simp [init, activeStaging_replicate_none], ?_, ?_⟩
  · intro e he
    simp [init] at he
  · intro e he
    simp [init] at he

theorem step_inv {s s' : State} {ev : Ev} (h : Inv s) (hs : step s ev = some s') :
    Inv s' := by
  rcases h with ⟨hslots, hrecv, hsend⟩
  cases ev with
  | startRead reqId uuid =>
    simp only [step] at hs
    split at hs
    · cases hs
    · rename_i inc hget
      split at hs
      · split at hs <;> cases hs <;> exact ⟨hslots, hrecv, hsend⟩
      · rename_i hnd
        have hdone : inc.recv.life.done = true := by
          cases hd : inc.recv.life.done <;> simp_all
        have hinc_inv := hrecv inc (getElem?_mem hget)
        have hfalse : slotHasStaging (some inc) = false := by
          simp [slotHasStaging, hinc_inv.life.staging, hdone]
        split at hs
        · rename_i hfree
          cases hs
          refine ⟨?_, ?_, hsend⟩
          · dsimp only
            rw [activeStaging_set_from_false hget hfalse]
            simp [slotHasStaging, Recv.initLoad]
            omega
          · intro e he
            rcases mem_set_cases he with h_eq | he
            · cases h_eq
              exact Recv.inv_initLoad s.cfg.numLayers
            · exact hrecv e he
        · cases hs
          refine ⟨?_, ?_, hsend⟩
          · dsimp only
            rw [activeStaging_set_from_false hget hfalse]
            simp [slotHasStaging]
            omega
          · intro e he
            rcases mem_set_cases he with h_eq | he
            · cases h_eq
            · exact hrecv e he
    · rename_i hget
      split at hs
      · rename_i hfree
        cases hs
        refine ⟨?_, ?_, hsend⟩
        · dsimp only
          rw [activeStaging_set_from_false hget rfl]
          simp [slotHasStaging, Recv.initLoad]
          omega
        · intro e he
          rcases mem_set_cases he with h_eq | he
          · cases h_eq
            exact Recv.inv_initLoad s.cfg.numLayers
          · exact hrecv e he
      · cases hs
        exact ⟨hslots, hrecv, hsend⟩
  | registerRecv reqId uuid =>
    simp only [step] at hs
    split at hs
    · cases hs
    · rename_i inc hget
      split at hs
      · cases hs
      · rename_i hnd
        have hdone : inc.recv.life.done = true := by
          cases hd : inc.recv.life.done <;> simp_all
        have hinc_inv := hrecv inc (getElem?_mem hget)
        have hfalse : slotHasStaging (some inc) = false := by
          simp [slotHasStaging, hinc_inv.life.staging, hdone]
        split at hs
        · rename_i hfree
          cases hs
          refine ⟨?_, ?_, hsend⟩
          · dsimp only
            rw [activeStaging_set_from_false hget hfalse]
            simp [slotHasStaging, Recv.initPush]
            omega
          · intro e he
            rcases mem_set_cases he with h_eq | he
            · cases h_eq
              exact Recv.inv_initPush s.cfg.numLayers
            · exact hrecv e he
        · cases hs
    · rename_i hget
      split at hs
      · rename_i hfree
        cases hs
        refine ⟨?_, ?_, hsend⟩
        · dsimp only
          rw [activeStaging_set_from_false hget rfl]
          simp [slotHasStaging, Recv.initPush]
          omega
        · intro e he
          rcases mem_set_cases he with h_eq | he
          · cases h_eq
            exact Recv.inv_initPush s.cfg.numLayers
          · exact hrecv e he
      · cases hs
  | recvStep uuid e =>
    simp only [step] at hs
    split at hs
    · cases hs
    · cases hs
    · rename_i entry hget
      split at hs
      · cases hs
      · rename_i recv' hstep
        cases hs
        have hst := activeStaging_set_step (e' := { entry with recv := recv' }) hget
          (recv_step_hasStaging_false hstep)
        refine ⟨?_, ?_, hsend⟩
        · dsimp only
          split <;> rename_i hrel <;> simp [hrel] at hst <;> omega
        · intro e' he'
          rcases mem_set_cases he' with h_eq | he'
          · cases h_eq
            exact Recv.step_inv (hrecv entry (getElem?_mem hget)) hstep
          · exact hrecv e' he'
  | sweepRecv uuid =>
    simp only [step] at hs
    split at hs
    · cases hs
    · cases hs
    · rename_i entry hget
      split at hs
      · rename_i hdone
        cases hs
        have hentry_inv := hrecv entry (getElem?_mem hget)
        have hfalse : slotHasStaging (some entry) = false := by
          simp [slotHasStaging, hentry_inv.life.staging, hdone]
        refine ⟨?_, ?_, hsend⟩
        · dsimp only
          rw [activeStaging_set_from_false hget hfalse]
          simp [slotHasStaging]
          omega
        · intro e he
          rcases mem_set_cases he with h_eq | he
          · cases h_eq
          · exact hrecv e he
      · cases hs
  | notifyForRead reqId uuid =>
    simp only [step] at hs
    split at hs
    · cases hs
    · cases hs
    · rename_i hget
      cases hs
      refine ⟨hslots, hrecv, ?_⟩
      intro e he
      rcases mem_set_cases he with h_eq | he
      · cases h_eq
        exact Send.inv_init s.cfg.numLayers
      · exact hsend e he
  | sendStep uuid e =>
    simp only [step] at hs
    split at hs
    · cases hs
    · cases hs
    · rename_i entry hget
      split at hs
      · cases hs
      · rename_i send' hstep
        cases hs
        refine ⟨hslots, hrecv, ?_⟩
        intro e' he'
        rcases mem_set_cases he' with h_eq | he'
        · cases h_eq
          exact Send.step_inv (hsend entry (getElem?_mem hget)) hstep
        · exact hsend e' he'
  | sweepSend uuid =>
    simp only [step] at hs
    split at hs
    · cases hs
    · cases hs
    · rename_i entry hget
      split at hs
      · cases hs
        refine ⟨hslots, hrecv, ?_⟩
        intro e he
        rcases mem_set_cases he with h_eq | he
        · cases h_eq
        · exact hsend e he
      · cases hs

theorem reachable_inv {cfg : Config} {s : State} (h : (sys cfg).Reachable s) : Inv s :=
  (sys cfg).reachable_induction (inv_init cfg) (fun _ _ _ ih hs => step_inv ih hs) h

/-- Every active receive entry in any reachable state satisfies `Recv.Safe`. -/
theorem reachable_recv_safe {cfg : Config} {s : State}
    (h : (sys cfg).Reachable s) {e : RecvEntry} (he : some e ∈ s.recvTable) :
    Recv.Safe e.recv :=
  Recv.inv_safe ((reachable_inv h).recv_inv e he)

/-- Every active send entry in any reachable state satisfies `Send.Safe`. -/
theorem reachable_send_safe {cfg : Config} {s : State}
    (h : (sys cfg).Reachable s) {e : SendEntry} (he : some e ∈ s.sendTable) :
    Send.Safe e.send :=
  Send.inv_safe ((reachable_inv h).send_inv e he)

/-! ## Drain-before-reuse persistence theorems -/

/-- **Consumer drain-before-reuse:** while an entry `inc` at `s.recvTable[uuid]`
has `inc.recv.life.done = false` (which holds whenever `0 < inc.recv.life.inFlight`,
including after a deadline has marked `draining = true`), **every** enabled
system step preserves the incumbent's ownership of `uuid` with the exact same
`(reqId, gen)`. Neither `startRead`, `registerRecv`, nor `sweepRecv` can
overwrite or erase `inc` until it has settled (`done = true`). -/
theorem active_recv_preserved {s s' : State} {ev : Ev} {uuid : Uuid} {inc : RecvEntry}
    (hget : s.recvTable[uuid]? = some (some inc))
    (hnd : inc.recv.life.done = false)
    (hs : step s ev = some s') :
    ∃ recv', s'.recvTable[uuid]? =
      some (some { reqId := inc.reqId, gen := inc.gen, recv := recv' }) := by
  have hlt : uuid < s.recvTable.length := lt_length_of_getElem?_eq hget
  cases ev with
  | startRead reqId u =>
    simp only [step] at hs
    by_cases hu : u = uuid
    · subst hu
      simp only [hget, hnd, Bool.not_false, ↓reduceIte] at hs
      split at hs <;> cases hs <;> exact ⟨inc.recv, hget⟩
    · split at hs
      · cases hs
      · split at hs
        · split at hs <;> cases hs <;> exact ⟨inc.recv, hget⟩
        · split at hs <;> cases hs <;>
          exact ⟨inc.recv, by rw [List.getElem?_set_ne hu]; exact hget⟩
      · split at hs <;> cases hs
        · exact ⟨inc.recv, by rw [List.getElem?_set_ne hu]; exact hget⟩
        · exact ⟨inc.recv, hget⟩
  | registerRecv reqId u =>
    simp only [step] at hs
    by_cases hu : u = uuid
    · subst hu
      simp [hget, hnd] at hs
    · split at hs
      · cases hs
      · split at hs
        · cases hs
        · split at hs <;> cases hs
          exact ⟨inc.recv, by rw [List.getElem?_set_ne hu]; exact hget⟩
      · split at hs <;> cases hs
        exact ⟨inc.recv, by rw [List.getElem?_set_ne hu]; exact hget⟩
  | recvStep u e =>
    simp only [step] at hs
    by_cases hu : u = uuid
    · subst hu
      simp only [hget] at hs
      split at hs
      · cases hs
      · rename_i recv' _
        cases hs
        exact ⟨recv', List.getElem?_set_self hlt⟩
    · split at hs
      · cases hs
      · cases hs
      · split at hs
        · cases hs
        · cases hs
          exact ⟨inc.recv, by rw [List.getElem?_set_ne hu]; exact hget⟩
  | sweepRecv u =>
    simp only [step] at hs
    by_cases hu : u = uuid
    · subst hu
      simp [hget, hnd] at hs
    · split at hs
      · cases hs
      · cases hs
      · split at hs <;> cases hs
        exact ⟨inc.recv, by rw [List.getElem?_set_ne hu]; exact hget⟩
  | notifyForRead _ _ =>
    simp only [step] at hs
    split at hs <;> cases hs
    exact ⟨inc.recv, hget⟩
  | sendStep _ _ =>
    simp only [step] at hs
    split at hs
    · cases hs
    · cases hs
    · split at hs <;> cases hs
      exact ⟨inc.recv, hget⟩
  | sweepSend _ =>
    simp only [step] at hs
    split at hs
    · cases hs
    · cases hs
    · split at hs <;> cases hs
      exact ⟨inc.recv, hget⟩

/-- **Producer drain-before-reuse:** while a send entry `inc` at
`s.sendTable[uuid]` has `inc.send.life.done = false`, **every** enabled system
step preserves `inc`'s ownership of `uuid` with the exact same `(reqId, gen)`. -/
theorem active_send_preserved {s s' : State} {ev : Ev} {uuid : Uuid} {inc : SendEntry}
    (hget : s.sendTable[uuid]? = some (some inc))
    (hnd : inc.send.life.done = false)
    (hs : step s ev = some s') :
    ∃ send', s'.sendTable[uuid]? =
      some (some { reqId := inc.reqId, gen := inc.gen, send := send' }) := by
  have hlt : uuid < s.sendTable.length := lt_length_of_getElem?_eq hget
  cases ev with
  | startRead _ _ =>
    simp only [step] at hs
    split at hs
    · cases hs
    · split at hs
      · split at hs <;> cases hs <;> exact ⟨inc.send, hget⟩
      · split at hs <;> cases hs <;> exact ⟨inc.send, hget⟩
    · split at hs <;> cases hs <;> exact ⟨inc.send, hget⟩
  | registerRecv _ _ =>
    simp only [step] at hs
    split at hs
    · cases hs
    · split at hs
      · cases hs
      · split at hs <;> cases hs <;> exact ⟨inc.send, hget⟩
    · split at hs <;> cases hs <;> exact ⟨inc.send, hget⟩
  | recvStep _ _ =>
    simp only [step] at hs
    split at hs
    · cases hs
    · cases hs
    · split at hs <;> cases hs <;> exact ⟨inc.send, hget⟩
  | sweepRecv _ =>
    simp only [step] at hs
    split at hs
    · cases hs
    · cases hs
    · split at hs <;> cases hs <;> exact ⟨inc.send, hget⟩
  | notifyForRead reqId u =>
    simp only [step] at hs
    by_cases hu : u = uuid
    · subst hu; simp [hget] at hs
    · split at hs <;> cases hs
      exact ⟨inc.send, by rw [List.getElem?_set_ne hu]; exact hget⟩
  | sendStep u e =>
    simp only [step] at hs
    by_cases hu : u = uuid
    · subst hu
      simp only [hget] at hs
      split at hs
      · cases hs
      · rename_i send' _
        cases hs
        exact ⟨send', List.getElem?_set_self hlt⟩
    · split at hs
      · cases hs
      · cases hs
      · split at hs <;> cases hs
        exact ⟨inc.send, by rw [List.getElem?_set_ne hu]; exact hget⟩
  | sweepSend u =>
    simp only [step] at hs
    by_cases hu : u = uuid
    · subst hu; simp [hget, hnd] at hs
    · split at hs
      · cases hs
      · cases hs
      · split at hs <;> cases hs
        exact ⟨inc.send, by rw [List.getElem?_set_ne hu]; exact hget⟩

/-! ## Concrete traces (`SendDrainTest`, `RecvDrainTest`, `ControlHandshakeTest`) -/

structure RecvSummary where
  reqId : ReqId
  gen : Nat
  draining : Bool
  done : Bool
  deriving Repr, DecidableEq

def recvSummary (s : State) (uuid : Uuid) : Option RecvSummary :=
  match s.recvTable[uuid]? with
  | some (some e) =>
    some { reqId := e.reqId, gen := e.gen,
           draining := e.recv.life.draining, done := e.recv.life.done }
  | _ => none

/-- `RecvDrainTest.DuplicateUuidIsRejectedUntilExpiredReceiveDrains`
(`kv_cache_manager_with_transfer_send_drain_test.cc:633-682`):
1. Register `"old"` (`reqId = 0`) at `uuid = 0`, issue layer 0 H2D copy
   (`h2dBegin`, `h2dIssue true`), and expire its deadline (`.cancel`).
2. While `"old"` is draining (`draining = true, done = false`), `.sweepRecv 0`
   and `.registerRecv 1 0` (`"retry"`, `reqId = 1`) are both rejected (`none`),
   and `"old"` keeps `uuid = 0` (`gen = 0`) and its staging slot
   (`freeSlots = 3`).
3. Once `"old"`'s H2D copy finishes (`h2dReady`, `h2dDone true`) and
   `.sweepRecv 0` runs, `"old"` is reported in `failedRecving = [0]`,
   `freeSlots` returns to `4`, and `.registerRecv 1 0` (`"retry"`, `gen = 1`)
   succeeds. -/
theorem trace_duplicate_uuid_rejected_until_drained :
    let cfg : Config := { numLayers := 1, numSlots := 4, numUuids := 1 }
    let pre : List Ev :=
      [.registerRecv 0 0,
       .recvStep 0 .h2dBegin, .recvStep 0 (.h2dIssue true),
       .recvStep 0 .cancel]
    ((sys cfg).run pre).map (fun s => (s.freeSlots, recvSummary s 0)) =
      some (3, some { reqId := 0, gen := 0, draining := true, done := false }) ∧
    (sys cfg).run (pre ++ [.sweepRecv 0]) = none ∧
    (sys cfg).run (pre ++ [.registerRecv 1 0]) = none ∧
    ((sys cfg).run (pre ++
      [.recvStep 0 .h2dReady, .recvStep 0 (.h2dDone true),
       .sweepRecv 0,
       .registerRecv 1 0,
       .recvStep 0 .cancel, .sweepRecv 0])).map
      (fun s => (s.freeSlots, s.doneRecving, s.failedRecving, s.recvTable[0]?)) =
      some (4, [], [0, 1], some none) := by
  decide

/-- `ControlHandshakeTest.DuplicateReceiveDoesNotReplaceOrLeakFirstRead`
(`kv_cache_manager_with_transfer_control_test.cc:718-752`):
1. `startRead` for `"first"` (`reqId = 0, uuid = 0`) allocates 1 slot
   (`freeSlots = 3`).
2. `startRead` for `"duplicate"` (`reqId = 1, uuid = 0`) sees the live incumbent
   with a different `reqId`: it leaves `"first"` at `recvTable[0]` (`reqId = 0`),
   allocates no extra slot (`freeSlots = 3`), and records `"duplicate"` in
   `failedRecving = [1]`.
3. When `"first"`'s handshake fails (`pullReply false`) and `.sweepRecv 0` runs,
   both `"first"` and `"duplicate"` are in `failedRecving = [1, 0]` and
   `freeSlots = 4`. -/
theorem trace_duplicate_receive_different_req_id :
    let cfg : Config := { numLayers := 1, numSlots := 4, numUuids := 1 }
    let pre : List Ev := [.startRead 0 0, .startRead 1 0]
    ((sys cfg).run pre).map
      (fun s => (s.freeSlots, s.failedRecving,
                 (s.recvTable[0]?).bind (fun o => o.map RecvEntry.reqId))) =
      some (3, [1], some 0) ∧
    ((sys cfg).run (pre ++ [.recvStep 0 (.pullReply false), .sweepRecv 0])).map
      (fun s => (s.freeSlots, s.doneRecving, s.failedRecving, s.recvTable[0]?)) =
      some (4, [], [1, 0], some none) := by
  decide

/-- `ControlHandshakeTest.RepeatedReceiveAnnouncementIsIdempotent`
(`kv_cache_manager_with_transfer_control_test.cc:754-790`):
re-delivering `startRead 0 0` with the **same** `(reqId = 0, uuid = 0)` while
the first is still in flight is a no-op (`failedRecving = []`, `freeSlots = 3`),
and when the handshake eventually fails and is swept, `reqId = 0` is reported
once in `failedRecving = [0]`. -/
theorem trace_repeated_receive_same_req_id_idempotent :
    let cfg : Config := { numLayers := 1, numSlots := 4, numUuids := 1 }
    let pre : List Ev := [.startRead 0 0, .startRead 0 0]
    ((sys cfg).run pre).map
      (fun s => (s.freeSlots, s.doneRecving, s.failedRecving)) =
      some (3, [], []) ∧
    ((sys cfg).run (pre ++ [.recvStep 0 (.pullReply false), .sweepRecv 0])).map
      (fun s => (s.freeSlots, s.doneRecving, s.failedRecving, s.recvTable[0]?)) =
      some (4, [], [0], some none) := by
  decide

/-- `SendLifecycleTest.DuplicateRegistrationCannotReplaceLiveOffer`
(`kv_cache_manager_with_transfer_send_drain_test.cc:363-380`):
`notifyForRead 0 0` (`"first"`, `reqId = 0, uuid = 0`) registers a live send
offer. A duplicate `notifyForRead 1 0` (`"replacement"`, `reqId = 1, uuid = 0`)
is rejected (`none`). When `"first"` times out (`.cancel`) and is swept
(`.sweepSend 0`), `"first"` (`reqId = 0`) is reported in `failedRecving = [0]`
and `uuid = 0` becomes free for a subsequent `notifyForRead 1 0`. -/
theorem trace_duplicate_send_cannot_replace_live_offer :
    let cfg : Config := { numLayers := 1, numSlots := 4, numUuids := 1 }
    ((sys cfg).run [.notifyForRead 0 0]).map
      (fun s => (s.sendTable[0]?).bind (fun o => o.map SendEntry.reqId)) =
      some (some 0) ∧
    ((sys cfg).run [.notifyForRead 0 0, .notifyForRead 1 0]).isNone = true ∧
    ((sys cfg).run
      [.notifyForRead 0 0, .sendStep 0 .cancel, .sweepSend 0, .notifyForRead 1 0]).map
      (fun s => (s.failedRecving,
                 (s.sendTable[0]?).bind (fun o => o.map (fun e => (e.reqId, e.gen))))) =
      some ([0], some (1, 1)) := by
  decide

/-- Inline retirement on `StartRead` (`mgr.cc:847-851`): when an incumbent at
`uuid = 0` has already settled (`done = true`), a new `startRead 1 0` retires
the settled incumbent into `doneRecving` / `failedRecving` inline without
needing an intervening `sweepRecv 0`, and seats the new session (`gen = 1`)
without leaking a staging slot. -/
theorem trace_start_read_retires_settled_incumbent_inline :
    let cfg : Config := { numLayers := 1, numSlots := 4, numUuids := 1 }
    let evs : List Ev :=
      [.startRead 0 0,
       .recvStep 0 (.pullReply false),
       .startRead 1 0]
    ((sys cfg).run evs).map
      (fun s => (s.freeSlots, s.failedRecving,
                 (s.recvTable[0]?).bind (fun o => o.map (fun e => (e.reqId, e.gen))))) =
      some (3, [0], some (1, 1)) := by
  decide

/-! ## Bounded model checks and mutant -/

def checkEvents : List Ev :=
  [.startRead 0 0, .startRead 1 0,
   .registerRecv 0 0, .registerRecv 1 0,
   .recvStep 0 (.pullReply true), .recvStep 0 (.pullReply false),
   .recvStep 0 .h2dBegin, .recvStep 0 (.h2dIssue true),
   .recvStep 0 .h2dReady, .recvStep 0 (.h2dDone true),
   .recvStep 0 .cancel, .sweepRecv 0]

/-- Executable check for staging-slot conservation (`freeSlots + activeStaging = numSlots`). -/
def violatesSlotConservation (s : State) : Bool :=
  s.freeSlots + activeStaging s.recvTable != s.cfg.numSlots

#guard ModelCheck.check
  (sys { numLayers := 1, numSlots := 2, numUuids := 1 })
  checkEvents violatesSlotConservation 5 = .outOfFuel

/-- **Mutant (`stepOverwriteDraining`):** what if `registerRecv` allowed
replacing an incumbent as soon as it is `draining` (e.g., past its deadline)
instead of waiting for `done = true` (`inFlight = 0`)? Overwriting a draining
incumbent whose H2D copy is still in flight leaks its pinned staging slot and
breaks slot conservation (`freeSlots + activeStaging != numSlots`). -/
def stepOverwriteDraining (s : State) (ev : Ev) : Option State :=
  match ev with
  | .registerRecv reqId uuid =>
    match s.recvTable[uuid]? with
    | some (some inc) =>
      if inc.recv.life.draining && 0 < s.freeSlots then
        let entry : RecvEntry :=
          { reqId, gen := s.nextGen, recv := Recv.initPush s.cfg.numLayers }
        some { s with
          freeSlots := s.freeSlots - 1,
          nextGen := s.nextGen + 1,
          recvTable := s.recvTable.set uuid (some entry) }
      else step s ev
    | _ => step s ev
  | _ => step s ev

#guard (match ModelCheck.check
          ⟨init { numLayers := 1, numSlots := 2, numUuids := 1 }, stepOverwriteDraining⟩
          checkEvents violatesSlotConservation 5 with
        | .counterexample _ => true
        | _ => false)

end TpuSyncVerify.Transfer.PrefillDecode.UuidTable
