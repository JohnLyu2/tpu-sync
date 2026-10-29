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
blank (`Moved`), and for an H2D completion whether the coarse copy clobbered a
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
  overwrote KV in a higher-rank slot of the aliased page. -/
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

theorem sendStep_none (s : Pipeline) (e : Send.Ev) (h : Send.step .shipping s.send e = none) :
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

/-- No upstream test runs a reshard transfer end to end on CPU (`Send` and
`Recv` coverage). -/
def paired : List (String × Pipeline × List Ev) := []

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

/-- Where a pipeline gap is accounted for. -/
inductive GapClass
  /-- The engine or allocator: `reclaim`, the two reseats. -/
  | env
  /-- `ReshardCoordinator::RunSubPlan`'s Phase 1, modelled in `Coordinator.lean`. -/
  | coordinator
  /-- `BlockTransportServerPushSession::CompleteIncomingPush` landing a stream. -/
  | transport
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
  | .landStream _ => .transport
  | .send sl _ =>
    if Send.coveredByPaired.contains (sl, b.2) then .sessionCovered
    else if (Send.gaps.map Prod.fst).contains (sl, b.2) then .sessionGap else .unaccounted
  | .recv rl _ _ =>
    if Recv.coveredByPaired.contains (rl, b.2) then .sessionCovered
    else if (Recv.gaps.map Prod.fst).contains (rl, b.2) then .sessionGap else .unaccounted

def movedOf : Leaf → Option Moved
  | .send _ mv => mv
  | .recv _ mv _ => mv
  | .landStream mv => some mv
  | _ => none

def clobbersOf : Leaf → Bool
  | .recv _ _ c => c
  | _ => false

/-! ## Result

The search exhausts the one-pool state space (armed and unarmed): **59
branches**. Every memory move is `kvRight` — the D2H copy, the push, the
landing and the H2D copy only ever move the right pool's KV
(`PublicationCorrect` read off the branch set) — and no H2D completion
clobbers KV in a higher-rank slot (`clobbersKv = false`, `AliasedPageCorrect`).

No upstream test runs a reshard transfer end to end on CPU, so `paired` is
empty and all 59 are gaps; the two `modelOnly` traces reach 17 of them (20
along the traces, three outside the one-pool universe). They partition as:

* **environment** (3): `reclaim`, `reseatSrcStaging`, `reseatDstStaging` — the
  engine freeing producer HBM and the arena handing a released lease to the
  next transfer (`MultiRequest.lean`).
* **coordinator** (1): `armRecv`, Phase 1 of `ReshardCoordinator::RunSubPlan`
  (`Coordinator.lean`).
* **transport** (1): `landStream` — `CompleteIncomingPush` counting a stream
  against `expected_pushes`; the block-transport unit tests drive that
  accounting without a reshard session.
* **covered at session level** (8: 4 `Send`, 4 `Recv`): the session branch
  inside is reached by a session unit test (the push callbacks, `cancel`,
  `pushBegin`, a failed push lease, `publish`); the pipeline adds only the
  memory effect, which those tests cannot observe.
* **in the session gap tables** (46: 20 `Send`, 26 `Recv`): `Send.gaps` /
  `Recv.gaps`, classified there (`test`, `futureStub`, `window`).

Nothing falls between the tables (`unaccounted = 0`).

Two pools of ranks `[0, 1]` add 7 branches (an `init [0, 1] [1, 1]` search,
about 5 s, too slow next to the other `#guard`s; re-run with
`tools/run_lean.sh`): the rank wave (`poolReceivedGated`, `h2dDoneChains`) and
its neighbours, all in the session gap tables, every move still `kvRight` and
no KV clobbered. The rank-blind mutant of `Traces.lean` (`stepRankBlind`)
reaches `clobbersKv = true` in 17 steps from the same state
(`Coverage.witnessP`). -/

/-- One search, every check: exhausted; 59 branches; none paired; 17 reached by
`modelOnly` within the universe; every move is `kvRight`; no KV clobbered; the
gaps partition into 3 environment, 1 coordinator, 1 transport, 8
session-covered, 46 session-gap, none unaccounted. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let count (c : GapClass) := (univ.filter (gapClass · = c)).length
    univ.length = 59 ∧ coveredByPaired.length = 0 ∧
    (univ.filter coveredByAll.contains).length = 17 ∧ coveredByAll.length = 20 ∧
    univ.all (fun b => (movedOf b.1).all (· = .kvRight)) ∧
    univ.all (fun b => !clobbersOf b.1) ∧
    count .env = 3 ∧ count .coordinator = 1 ∧ count .transport = 1 ∧
    count .sessionCovered = 8 ∧ count .sessionGap = 46 ∧ count .unaccounted = 0 ∧
    modelOnly.all (fun (_, s, tr) => ((⟨s, step⟩ : System Pipeline Ev).run tr).isSome)

#guard coverageChecks

end Pipeline

end TpuSyncVerify.Transfer.Reshard
