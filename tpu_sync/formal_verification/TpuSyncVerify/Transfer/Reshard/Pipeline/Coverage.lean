import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Transfer.Reshard.Receive.Coverage
import TpuSyncVerify.Transfer.Reshard.Send.Coverage
import TpuSyncVerify.Transfer.Reshard.Pipeline.Traces

/-! # `Pipeline`: branch coverage of `step` by the replayed tests

Part of `TpuSyncVerify.Transfer.Reshard.Pipeline`. Same construction as
`PrefillDecode/Pipeline/Coverage.lean` (machinery in `Common/Coverage.lean`).

`Pipeline.step` wraps the two session steps and adds the pool-indexed memories,
the stream counters and the arm barrier. Its leaves are the session leaves
where a session step is taken (`Send.Leaf`, `Recv.Leaf`, through `Send.stepT` /
`Recv.stepT`), plus what the memory events moved: for each copy or landing,
whether the cell written was the right pool's KV, another pool's, junk or
blank (`Moved`), and for an H2D completion whether `writePoolHbm` overwrote a
higher-rank slot that already held KV (`clobbersKv`). `Effect` is the lifecycle
effect of whichever session the step touched. -/

namespace TpuSyncVerify.Transfer.Reshard

open TpuSyncVerify.Transfer (Lifecycle)
open TpuSyncVerify.Coverage (Effect Instr insertNew sameSet)

namespace Pipeline

/-- What a memory event wrote into slot `p`. -/
inductive Moved
  | kvRight
  | kvOther
  | junk
  | blank
  deriving Repr, DecidableEq

def moved (c : Cell) (p : Nat) : Moved :=
  match c with
  | .kv q => if q = p then .kvRight else .kvOther
  | .junk => .junk
  | .blank => .blank

inductive Leaf
  /-- Phase 1 of `ReshardCoordinator::RunSubPlan` arms the receiver. -/
  | armRecv
  /-- A send event, with the session leaf `Send.stepT` attached; for a D2H or
  push completion, what moved into `srcStaging[p]` / `wire[p]`. -/
  | send (sl : Send.Leaf) (mv : Option Moved)
  /-- A receive event, with the session leaf `Recv.stepT` attached; for an H2D
  completion, what moved into `dstHbm[p]` and whether `writePoolHbm`
  overwrote KV in a higher-rank pool's slot. -/
  | recv (rl : Recv.Leaf) (mv : Option Moved) (clobbersKv : Bool)
  /-- `CompleteIncomingPush` lands a stream into `dstStaging[p]`. -/
  | landStream (mv : Moved)
  /-- The source frees producer HBM after the send published. -/
  | reclaim
  /-- A released sender staging lease is reused. -/
  | reseatSrcStaging
  /-- A released receiver staging lease is reused. -/
  | reseatDstStaging
  deriving Repr, DecidableEq

def effect (s s' : Pipeline) : Effect :=
  let es := Send.effect s.send s'.send
  let er := Recv.effect s.recv s'.recv
  { drains := es.drains || er.drains, settles := es.settles || er.settles,
    errors := es.errors || er.errors }

abbrev Branch := Leaf × Effect

def sendMoved (s : Pipeline) : Send.Ev → Option Moved
  | .d2hDone p true => some (moved (s.srcHbm.getD p .junk) p)
  | .pushDone p true => some (moved (s.srcStaging.getD p .junk) p)
  | _ => none

def isKv : Cell → Bool
  | .kv _ => true
  | _ => false

def recvMoved (s : Pipeline) : Recv.Ev → Option Moved × Bool
  | .h2dDone p true =>
    match s.recv.pools[p]? with
    | some pool =>
      (some (moved (s.dstStaging.getD p .junk) p),
       (List.zip s.recv.pools s.dstHbm).any fun (q, c) => decide (pool.rank < q.rank) && isKv c)
    | none => (none, false)
  | _ => (none, false)

/-- `step` with the leaf it took; the session leaf comes from the session's own
`stepT`, so a pipeline branch names the session branch inside it. -/
def stepT (s : Pipeline) : Ev → Option (Pipeline × Leaf)
  | .armRecv => (s.armRecv).map (·, .armRecv)
  | .send e =>
    (Send.stepT s.send e).bind fun (_, sl) => (s.sendStep e).map (·, .send sl (sendMoved s e))
  | .recv e =>
    (Recv.stepT s.recv e).bind fun (_, rl) =>
      (s.recvStep e).map (·, .recv rl (recvMoved s e).1 (recvMoved s e).2)
  | .landStream p => (s.landStream p).map (·, .landStream (moved (s.wire.getD p .junk) p))
  | .reclaim => (s.reclaim).map (·, .reclaim)
  | .reseatSrcStaging => (s.reseatSrcStaging).map (·, .reseatSrcStaging)
  | .reseatDstStaging => (s.reseatDstStaging).map (·, .reseatDstStaging)

theorem sendStep_none (s : Pipeline) (e : Send.Ev) (h : Send.step s.send e = none) :
    s.sendStep e = none := by
  cases e <;> simp [sendStep, h]

theorem recvStep_none (s : Pipeline) (e : Recv.Ev) (h : Recv.step .finishOnError s.recv e = none) :
    s.recvStep e = none := by
  cases e <;> simp [recvStep, h] <;> split <;> simp

private theorem bind_map_fst {α β γ : Type} (o : Option α) (f : Option β) (g : α → γ)
    (h : o = none → f = none) :
    (o.bind fun a => f.map (·, g a)).map (·.1) = f := by
  cases o with
  | none => simp [h rfl]
  | some a => cases f <;> simp

/-- `stepT` is `step` with a tag: same enabledness, same post-state. -/
theorem stepT_step (s : Pipeline) (e : Ev) : (stepT s e).map (·.1) = step s e := by
  cases e with
  | send e =>
    exact bind_map_fst _ _ _ fun h => sendStep_none s e (by rw [← Send.stepT_step, h]; rfl)
  | recv e =>
    exact bind_map_fst _ _ _ fun h => recvStep_none s e (by rw [← Recv.stepT_step, h]; rfl)
  | _ => simp [stepT, step, Option.map_map, Function.comp_def]

/-- As in `Recv`, more than two open push leases add states but no branch. -/
def instr : Instr Pipeline Ev Leaf Effect := { stepT, effect, keep := fun s => s.recv.pushes ≤ 2 }

/-- One pool with one peer, armed and unarmed. -/
def inits : List (Pipeline × List Ev) :=
  [(init [0] [1], allEvents 1), (initUnarmed [0] [1], allEvents 1)]

def allBranches : Option (List Branch) :=
  inits.foldlM (fun acc (i, evs) =>
    (Coverage.reachableBranches instr i evs 64).map (·.foldl insertNew acc)) []

/-- Replay of
`ReshardSendSessionTest.PoolOrderInvertedFromStorageOrderPassesTransportValidateChunks`
(`reshard_send_session_test.cc`): `CreateReshardReceiveSession` (on
`RecordingH2dReceiverBase`) + `CreateReshardSendSession` (on `FakeD2hBase`) run
two rank-0 pools of one stream each end to end over `BlockTransport`
(`SocketTransportAdapter`). Ready `FakeD2hBase` futures run `StartPoolPush` inline
inside `ExecutePushPipeline` before `execFinish`; each pool's push stream lands
(`CompleteIncomingPush` → `OnDataReceived`) and `RecordingH2dReceiverBase`
uploads it inline inside the stream's `pushBegin`..`pushEnd` op.

The trace is the test's events in the model's order, not the test's: in the
test each stream lands, uploads and is acknowledged before the sender's push
callback (`pushDone p true`) runs, whereas `landStream p` is enabled only
after `pushDone p true` (`Pipeline.lean` A2), so each `pushDone` is listed
ahead of the receive events of its stream. -/
def tr_inverted_pool_order : List Ev :=
  [.send (.d2hIssue 0 true), .send (.d2hDone 0 true),
   .send (.d2hIssue 1 true), .send (.d2hDone 1 true),
   .send .execFinish,
   .send (.pushDone 0 true),
   .recv .pushBegin, .landStream 0, .recv (.onPoolReceived 0),
   .recv (.h2dIssue 0 true), .recv (.h2dReady 0), .recv (.h2dDone 0 true),
   .recv (.pushEnd true),
   .send (.pushDone 1 true),
   .recv .pushBegin, .landStream 1, .recv (.onPoolReceived 1),
   .recv (.h2dIssue 1 true), .recv (.h2dReady 1), .recv (.h2dDone 1 true),
   .recv (.pushEnd true)]

def paired : List (String × Pipeline × List Ev) :=
  [("ReshardSendSessionTest.PoolOrderInvertedFromStorageOrderPassesTransportValidateChunks",
      init [0, 0] [1, 1], tr_inverted_pool_order)]

def modelOnly : List (String × Pipeline × List Ev) :=
  [("trace_aliased_page_out_of_order_arrival", init [0, 1] [1, 2],
      outOfOrderPrefix ++ outOfOrderSuffix),
   ("trace_arm_before_dispatch", initUnarmed [0] [1],
      [.armRecv, .send (.d2hIssue 0 true), .send .execFinish,
       .send (.d2hDone 0 true), .send (.pushDone 0 true), .send .publish,
       .recv .pushBegin, .landStream 0, .recv (.onPoolReceived 0),
       .recv (.h2dIssue 0 true), .recv (.h2dReady 0), .recv (.h2dDone 0 true),
       .recv (.pushEnd true), .recv .publish])]

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, s, tr) => (s, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

/-- Where an uncovered pipeline branch is accounted for. -/
inductive GapClass
  /-- The engine or allocator: `reclaim`, the two reseats. -/
  | env
  /-- `ReshardCoordinator::RunSubPlan`'s Phase 1, modelled in `Coordinator.lean`. -/
  | coordinator
  /-- The session branch inside is reached by a session unit test. -/
  | sessionCovered
  /-- The session branch inside is in that session's gap table. -/
  | sessionGap
  | unaccounted
  deriving Repr, DecidableEq

def gapClass (b : Branch) : GapClass :=
  match b.1 with
  | .armRecv => .coordinator
  | .reclaim | .reseatSrcStaging | .reseatDstStaging => .env
  | .send sl _ =>
    if Send.coveredByPaired.contains (sl, b.2) then .sessionCovered
    else if (Send.gaps.map Prod.fst).contains (sl, b.2) then .sessionGap else .unaccounted
  | .recv rl _ _ =>
    if Recv.coveredByPaired.contains (rl, b.2) then .sessionCovered
    else if (Recv.gaps.map Prod.fst).contains (rl, b.2) then .sessionGap else .unaccounted
  | _ => .unaccounted

def movedOf : Leaf → Option Moved
  | .send _ mv => mv
  | .recv _ mv _ => mv
  | .landStream mv => some mv
  | _ => none

def clobbersOf : Leaf → Bool
  | .recv _ _ c => c
  | _ => false

/-! ## Result

The search exhausts the one-pool state space (armed and unarmed): **60
branches**. Every memory move is `kvRight` — the D2H copy, the push, the
landing and the H2D copy only ever move the right pool's KV
(`PublicationCorrect` read off the branch set) — and no H2D completion
clobbers KV in a higher-rank slot (`clobbersKv = false`, `AliasedPageCorrect`).

One C++ test
(`ReshardSendSessionTest.PoolOrderInvertedFromStorageOrderPassesTransportValidateChunks`)
runs `CreateReshardReceiveSession` + `CreateReshardSendSession` end to end over
`BlockTransport` (`SocketTransportAdapter`) across two rank-0 pools of one stream
each: it reaches **12 of the 60** one-pool branches (`landStream .kvRight`, 4
`Send` happy-path branches, and 7 `Recv` happy-path branches) plus 2 multi-pool
branches outside the one-pool universe (`send .pushDoneMore` and
`recv .h2dDoneMore`), 14 along the trace in all. Adding the two `modelOnly`
traces reaches 18 of 60 within the universe (22 in all). The **48** one-pool
branches missed by `paired` partition as:

* **environment** (3): `reclaim`, `reseatSrcStaging`, `reseatDstStaging` — the
  engine freeing producer HBM and the arena handing a released lease to the
  next transfer (`MultiRequest.lean`).
* **coordinator** (1): `armRecv`, Phase 1 of `ReshardCoordinator::RunSubPlan`
  (`Coordinator.lean`; paired at the coordinator level in
  `Coordinator/Coverage.lean`).
* **covered at session level** (8: 3 `Send`, 5 `Recv`): the session branch
  inside is reached by a session unit test (`cancel` on either side, a failed
  `Start`, a D2H copy returning after `Finish`, a failed push lease, an unframed
  last-pool H2D completion settling at once, a failed H2D callback, or `Recv`
  `publish`); the pipeline adds only the memory effect, which those tests
  cannot observe.
* **in the session gap tables** (36: 18 `Send`, 18 `Recv`): `Send.gaps` /
  `Recv.gaps`, classified there (`test`, `copyError` / `heldUpload`, `window`).

Nothing falls between the tables (`unaccounted = 0`, which also checks that
`landStream` is covered by `paired`).

Two pools of ranks `[0, 1]` add 7 branches (an `init [0, 1] [1, 1]` search,
about 5 s, too slow next to the other `#guard`s; re-run with
`tools/run_lean.sh`): the rank wave (`poolReceivedGated`, `h2dDoneChains`) and
its neighbours, all in the session gap tables, every move still `kvRight` and
no KV clobbered. The rank-blind mutant of `Traces.lean` (`stepRankBlind`)
reaches `clobbersKv = true` in 17 steps from the same state
(`Coverage.witnessP`). -/

/-- One search, every check: exhausted; 60 branches; 12 reached by `paired`
within the one-pool universe (14 along the trace, 2 multi-pool), 18 with
`modelOnly` (22 in all); every move is `kvRight`; no KV clobbered; the 48
uncovered one-pool branches partition into 3 environment, 1 coordinator, 8
session-covered, 36 session-gap, none unaccounted; every trace runs to
completion. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let gaps := univ.filter (fun b => !coveredByPaired.contains b)
    let count (c : GapClass) := (gaps.filter (gapClass · = c)).length
    univ.length = 60 ∧ (univ.filter coveredByPaired.contains).length = 12 ∧
    coveredByPaired.length = 14 ∧
    (univ.filter coveredByAll.contains).length = 18 ∧ coveredByAll.length = 22 ∧
    univ.all (fun b => (movedOf b.1).all (· = .kvRight)) ∧
    univ.all (fun b => !clobbersOf b.1) ∧
    gaps.length = 48 ∧
    count .env = 3 ∧ count .coordinator = 1 ∧
    count .sessionCovered = 8 ∧ count .sessionGap = 36 ∧ count .unaccounted = 0 ∧
    (paired ++ modelOnly).all (fun (_, s, tr) =>
      ((⟨s, step⟩ : System Pipeline Ev).run tr).isSome)

#guard coverageChecks

end Pipeline

end TpuSyncVerify.Transfer.Reshard
