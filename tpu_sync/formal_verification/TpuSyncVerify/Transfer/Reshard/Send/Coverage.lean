import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Transfer.Reshard.Send.Traces

/-! # `Send`: branch coverage of `step` by the replayed tests

Part of `TpuSyncVerify.Transfer.Reshard.Send`. Built like
`PrefillDecode/Receive/Coverage.lean` (machinery in `Common/Coverage.lean`):
`Leaf` names one leaf of an event's decision tree, `stepT` is `step` under the
shipping `UnregisterPolicy.shipping` with the leaf attached, and `stepT_step`
proves it is the same function. `life.draining` is the C++ `finalizing_`. -/

namespace TpuSyncVerify.Transfer.Reshard

open TpuSyncVerify.Transfer (Lifecycle)
open TpuSyncVerify.Coverage (Effect Instr insertNew sameSet)

namespace Send

/-- One leaf of `step`'s decision tree per event. `RecordPushCompletion`'s four
outcomes (ignored on a finalizing session, first error, last scheduled push,
another push to come) appear under each event that calls it. -/
inductive Leaf
  /-- `ExecutePush` loop: `D2hPoolBlocks` returned a future; `++in_flight_`. -/
  | d2hIssueOk
  /-- `ExecutePush` loop: lease or `D2hPoolBlocks` failed →
  `RecordPushCompletion(error)` latches `finalizing_`, `EndOp()`, return. -/
  | d2hIssueFail
  /-- Same, on an already finalizing session: `RecordPushCompletion` returns at
  `if (done_ || finalizing_) return;`. -/
  | d2hIssueFailFinalizing
  /-- `ExecutePush`'s closing `EndOp()`. -/
  | execFinish
  /-- D2H callback with an error: `RecordPushCompletion(error)`. -/
  | d2hDoneFail
  /-- D2H callback with an error on a finalizing session: ignored. -/
  | d2hDoneFailFinalizing
  /-- D2H callback OK; `StartPoolPush` returns at `if (done_ || finalizing_)`. -/
  | d2hDoneQuiesced
  /-- D2H callback OK; `StartPoolPush` adds one op per peer and issues the pushes. -/
  | d2hDoneStartsPushes
  /-- `AsyncPush` callback with an error: `RecordPushCompletion(error)`. -/
  | pushDoneFail
  /-- `AsyncPush` callback on a finalizing session: ignored. -/
  | pushDoneFinalizing
  /-- `AsyncPush` callback OK, `--remaining_pool_peer_pushes_ == 0`: finalizing. -/
  | pushDoneLast
  /-- `AsyncPush` callback OK, more pushes to come. -/
  | pushDoneMore
  /-- External `Finish(error)` (deadline sweep, manager teardown). -/
  | cancel
  /-- The poll published a settled session. -/
  | publish
  deriving Repr, DecidableEq

def effect (s s' : Send) : Effect :=
  Effect.of s.life.draining s.life.done s.life.statusOk
    s'.life.draining s'.life.done s'.life.statusOk

abbrev Branch := Leaf × Effect

/-- `RecordPushCompletion`'s outcome for a push completion with status `ok`. -/
def pushLeaf (ok : Bool) (s : Send) : Leaf :=
  if s.life.done = true ∨ s.life.draining = true then .pushDoneFinalizing
  else if !ok then .pushDoneFail
  else if s.remainingPushes ≤ 1 then .pushDoneLast
  else .pushDoneMore

/-- `step .shipping` with the leaf it took. -/
def stepT (s : Send) : Ev → Option (Send × Leaf)
  | .d2hIssue p ok =>
    (s.d2hIssue .shipping p ok).map (·,
      if ok then .d2hIssueOk
      else if s.life.done = true ∨ s.life.draining = true then .d2hIssueFailFinalizing
      else .d2hIssueFail)
  | .execFinish => (s.execFinish).map (·, .execFinish)
  | .d2hDone p ok =>
    (s.d2hDone .shipping p ok).map (·,
      if !ok then
        if s.life.done = true ∨ s.life.draining = true then .d2hDoneFailFinalizing
        else .d2hDoneFail
      else if s.life.done = true ∨ s.life.draining = true then .d2hDoneQuiesced
      else .d2hDoneStartsPushes)
  | .pushDone p ok => (s.pushDone .shipping p ok).map (·, pushLeaf ok s)
  | .cancel => (s.cancel).map (·, .cancel)
  | .publish => (s.publish).map (·, .publish)

/-- `stepT` is `step .shipping` with a tag. -/
theorem stepT_step (s : Send) (e : Ev) : (stepT s e).map (·.1) = step .shipping s e := by
  cases e <;> simp [stepT, step, Option.map_map, Function.comp_def]

def instr : Instr Send Ev Leaf Effect := { stepT, effect }

/-- One pool and one peer; one pool and two peers; two pools of one peer each. -/
def inits : List (Send × List Ev) :=
  [(init [1], events 1), (init [2], events 1), (init [1, 1], events 2)]

def allBranches : Option (List Branch) :=
  inits.foldlM (fun acc (i, evs) =>
    (Coverage.reachableBranches instr i evs 64).map (·.foldl insertNew acc)) []

/-! ## Traces

The send tests construct a session with `ReshardSendSession::Create` on a
placeholder-hold `MakeTestBase` (whose `buffer_holds_[0].holds` is empty, so
`CopyPoolBlocks` cannot run on it) and stand in for `ExecutePush` and
`StartPoolPush`: `ReshardSendSessionTestPeer::BeginPush` takes one push op
(`++in_flight_`), and `CompletePush` runs `RecordPushCompletion` + `EndOp()`
as the `AsyncPush` callback does. After `BeginPush` the session is in the state
the model reaches by `d2hIssue 0 true, execFinish, d2hDone 0 true` on one pool
with one peer (`afterPushStart`); the paired traces start there, so only the
steps the test really drives are counted. -/

/-- One pool, one peer, its push in flight, `ExecutePush` done. -/
def afterPushStart : Send :=
  ((sys [1]).run (tr_parity_send.take 3)).getD (init [1])

example : afterPushStart.pools = [{ peers := 1, stage := .pushing 1 }] ∧
    afterPushStart.life.inFlight = 1 ∧ afterPushStart.execActive = false := by decide

/-- `(upstream test, initial state, trace)`. -/
def paired : List (String × Send × List Ev) :=
  [("ReshardSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsBeforeSettling",
      afterPushStart, [.pushDone 0 true]),
   ("ReshardSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsWhenCancelledMidPush",
      afterPushStart, [.cancel, .pushDone 0 true]),
   ("ReshardSendSessionTest.PooledPolicyKeepsIdlePeerConnections",
      afterPushStart, [.pushDone 0 true])]

def modelOnly : List (String × Send × List Ev) :=
  [("trace_reshard_send_session_test_parity", init [1], tr_parity_send),
   ("trace_multi_pool_multi_peer_send", init [2, 1], tr_multi_pool_multi_peer_send),
   ("trace_cancel_unregisters_on_last_endOp", init [2], tr_cancel_unregisters_on_last_endOp),
   ("trace_early_unregister_on_error_vs_onSettle", init [1, 1], tr_early_unregister_on_error)]

/-- Upstream tests on this C++ whose stimulus is not an event of the model. -/
def notReplayable : List (String × String) :=
  [("ReshardSendSessionTest.CreateRejectsUnknownDataConnReuseValue",
      "Create's TPU_RAIDEN_DATA_CONN_REUSE parse; no session exists"),
   ("PoolReshardSendTest.SenderWithNoBytesForAnyTransferredPoolRefusedUpFront",
      "Create's CountPoolReshardSendSlots == 0 rejection (validSchedule)"),
   ("PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints",
      "PoolReshardPush's has_device_buffers() rejection; no session exists"),
   ("ReshardSendSessionTest.* ValidatePlan tests (6 tests)",
      "ValidatePlan only (validSenderSpan, validSchedule); no session runs")]

/-! ## Result

Every search exhausts its state space, so `allBranches` is exact for senders
of one pool with one or two peers and of two pools with one peer each:
**25 branches**, and every leaf of `Leaf` is in one. (`cancel` never settles an
idle session here: `init` already holds `ExecutePush`'s caller op, `Send` A2.)

The three upstream tests in `paired` reach **3 of 25**: `pushDoneLast`
(drains, settles), `cancel` (drains, errors) and `pushDoneFinalizing`
(settles). The four `modelOnly` traces add 7 more. Of the 22 the tests miss:

| Class | Count | Branches | What it would take |
|---|---|---|---|
| **test** | 16 | `pushDoneFail` (drains+settles+errors; drains+errors), `pushDoneLast` (drains, another op held), `pushDoneMore`, `pushDoneFinalizing` (no effect), `cancel` (no effect; errors after an OK settle), `d2hIssueOk`, `d2hIssueFail` (drains+settles+errors; drains+errors), `d2hIssueFailFinalizing` (settles; no effect), `d2hDoneStartsPushes`, `execFinish` (no effect; settles), `publish` | 7 via `ReshardSendSessionTestPeer` alone (`CompletePush` with an error status for `pushDoneFail` — `UnregisterPolicy.shipping`'s early unregister — `BeginPush` twice, a two-peer plan, a second `Finish`); 9 via `PoolReshardPush` (`ExecutePush`) on `DeviceBackedTestBase`, whose default-constructed `RaidenBufferHandle` makes `raiden::IssueD2hShard` return an empty `PjRtCopyFuture` whose `OnReady` runs `StartPoolPush` synchronously after `ExecutePush` drops `mu_` (`device_size = 0` or `host_blocks = 0` fails `D2hPoolBlocks` synchronously; when pool 0's `AsyncPush` fails synchronously — e.g. `AdapterForOp` under `TPU_RAIDEN_TRANSPORT_BACKEND=peregrine` — `RecordPushCompletion` latches `finalizing_` inline inside `ExecutePush`, reaching `execFinish` settling on 1 pool and `d2hIssueFailFinalizing` on a second `device_size = 0` pool because `ExecutePush`'s loop does not re-check `finalizing_`) |
| **future (stub)** | 6 | `d2hDoneFail` (drains+settles+errors; drains+errors), `d2hDoneFailFinalizing` (no effect; settles), `d2hDoneQuiesced` (no effect; settles) | a controllable `PjRtCopyFuture` fake (a `RawBuffer` / `PJRT_RawBuffer_Extension` test stub backed by `xla::Promise<>`) so an issued D2H copy can stay pending across `Finish` or resolve `OnReady` with an error on CPU |

So no upstream test exercises `ExecutePush`, `StartPoolPush`, a D2H callback,
or a failed push: `ReshardSendSessionTest` uses `MakeTestBase` +
`AttachPlaceholderDeviceHoldForTest` (which leaves `buffer_holds_[0].holds`
empty and drives `ReshardSendSessionTestPeer` instead of `DeviceBackedTestBase`),
and `CompletePush` is called only with `OkStatus()` (`docs/transfer/reshard.md`
§"C++ branch coverage of the anchored spans"). -/

/-- `(leaf, drains, settles, errors)`. -/
def br (l : Leaf) (drains settles errors : Bool) : Branch := (l, ⟨drains, settles, errors⟩)

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, s, tr) => (s, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

inductive Gap where
  | test
  | futureStub
  deriving Repr, DecidableEq

/-- The table above, as the `#guard` checks it. -/
def gaps : List (Branch × Gap) :=
  [(br .pushDoneFail true true true, .test), (br .pushDoneFail true false true, .test),
   (br .pushDoneLast true false false, .test), (br .pushDoneMore false false false, .test),
   (br .pushDoneFinalizing false false false, .test),
   (br .cancel false false false, .test), (br .cancel false false true, .test),
   (br .d2hIssueFail true true true, .test), (br .d2hIssueFail true false true, .test),
   (br .d2hIssueFailFinalizing false true false, .test),
   (br .d2hIssueFailFinalizing false false false, .test),
   (br .d2hIssueOk false false false, .test),
   (br .d2hDoneStartsPushes false false false, .test),
   (br .execFinish false false false, .test), (br .execFinish false true false, .test),
   (br .publish false false false, .test),
   (br .d2hDoneFail true true true, .futureStub), (br .d2hDoneFail true false true, .futureStub),
   (br .d2hDoneFailFinalizing false false false, .futureStub),
   (br .d2hDoneFailFinalizing false true false, .futureStub),
   (br .d2hDoneQuiesced false false false, .futureStub),
   (br .d2hDoneQuiesced false true false, .futureStub)]

def allLeaves : List Leaf :=
  [.d2hIssueOk, .d2hIssueFail, .d2hIssueFailFinalizing, .execFinish, .d2hDoneFail,
   .d2hDoneFailFinalizing, .d2hDoneQuiesced, .d2hDoneStartsPushes, .pushDoneFail,
   .pushDoneFinalizing, .pushDoneLast, .pushDoneMore, .cancel, .publish]

def countGap (g : Gap) : Nat := (gaps.filter (·.2 = g)).length

/-- One search, every check: the state space is exhausted; 25 branches; 3
reached by paired traces, 10 with `modelOnly` (all within the universe, every
trace running to completion); the uncovered set is the table (16 test, 6
future-stub); every leaf fires; every gap has a witness schedule. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let uncoveredPaired := univ.filter (fun b => !coveredByPaired.contains b)
    univ.length = 25 ∧ coveredByPaired.length = 3 ∧ coveredByAll.length = 10 ∧
    coveredByPaired.all univ.contains ∧ coveredByAll.all univ.contains ∧
    sameSet uncoveredPaired (gaps.map Prod.fst) ∧ gaps.length = 22 ∧
    countGap .test = 16 ∧ countGap .futureStub = 6 ∧
    allLeaves.all (fun l => univ.any (·.1 = l)) ∧
    (paired ++ modelOnly).all (fun (_, s, tr) =>
      ((⟨s, step .shipping⟩ : System Send Ev).run tr).isSome) ∧
    gaps.all (fun (b, _) => inits.any fun (i, evs) => (Coverage.witness instr i evs b).isSome)

#guard coverageChecks

end Send

end TpuSyncVerify.Transfer.Reshard
