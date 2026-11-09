import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Transfer.Reshard.Send.Traces

/-! # `Send`: branch coverage of `step` by the replayed tests

Part of `TpuSyncVerify.Transfer.Reshard.Send`. Built like
`PrefillDecode/Receive/Coverage.lean` (machinery in `Common/Coverage.lean`):
`Leaf` names one leaf of an event's decision tree, `stepT` is `step` with the
leaf attached, and `stepT_step` proves it is the same function. `life.draining` is the C++ `finalizing_`. -/

namespace TpuSyncVerify.Transfer.Reshard

open TpuSyncVerify.Transfer (Lifecycle)
open TpuSyncVerify.Coverage (Effect Instr insertNew sameSet)

namespace Send

/-- One leaf of `step`'s decision tree per event. `RecordPushCompletion`'s four
outcomes (ignored on a finalizing session, first error, last scheduled push,
another push to come) appear under each event that calls it. -/
inductive Leaf
  /-- `Start`: `ValidatePushPreconditions` failed or the pipeline thread could
  not start → `RecordPushCompletion(error)` latches `finalizing_`, the
  `absl::Cleanup` `EndOp()` settles. -/
  | startFail
  /-- Same, on an already finalizing session: `RecordPushCompletion` returns at
  `if (done_ || finalizing_) return;`. -/
  | startFailFinalizing
  /-- `ExecutePushPipeline` loop: `D2hPoolBlocks` returned a future; `++in_flight_`. -/
  | d2hIssueOk
  /-- `ExecutePushPipeline` loop: staging slot, lease or `D2hPoolBlocks` failed →
  `RecordPushCompletion(error)` latches `finalizing_`, return; the thread's
  `EndOp()`. -/
  | d2hIssueFail
  /-- Same, on an already finalizing session: `RecordPushCompletion` returns at
  `if (done_ || finalizing_) return;` (or the loop's own
  `if (done_ || finalizing_)` re-check returned first). -/
  | d2hIssueFailFinalizing
  /-- The pipeline thread's closing `EndOp()`. -/
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
  /-- External `Finish(error)` (deadline sweep, manager teardown, `UnregisterActivePlan`). -/
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

/-- `step` with the leaf it took. -/
def stepT (s : Send) : Ev → Option (Send × Leaf)
  | .startFail =>
    (s.startFail).map (·,
      if s.life.done = true ∨ s.life.draining = true then .startFailFinalizing
      else .startFail)
  | .d2hIssue p ok =>
    (s.d2hIssue p ok).map (·,
      if ok then .d2hIssueOk
      else if s.life.done = true ∨ s.life.draining = true then .d2hIssueFailFinalizing
      else .d2hIssueFail)
  | .execFinish => (s.execFinish).map (·, .execFinish)
  | .d2hDone p ok =>
    (s.d2hDone p ok).map (·,
      if !ok then
        if s.life.done = true ∨ s.life.draining = true then .d2hDoneFailFinalizing
        else .d2hDoneFail
      else if s.life.done = true ∨ s.life.draining = true then .d2hDoneQuiesced
      else .d2hDoneStartsPushes)
  | .pushDone p ok => (s.pushDone p ok).map (·, pushLeaf ok s)
  | .cancel => (s.cancel).map (·, .cancel)
  | .publish => (s.publish).map (·, .publish)

/-- `stepT` is `step` with a tag. -/
theorem stepT_step (s : Send) (e : Ev) : (stepT s e).map (·.1) = step s e := by
  cases e <;> simp [stepT, step, Option.map_map, Function.comp_def]

def instr : Instr Send Ev Leaf Effect := { stepT, effect }

/-- One pool and one peer; one pool and two peers; two pools of one peer each. -/
def inits : List (Send × List Ev) :=
  [(init [1], events 1), (init [2], events 1), (init [1, 1], events 2)]

def allBranches : Option (List Branch) :=
  inits.foldlM (fun acc (i, evs) =>
    (Coverage.reachableBranches instr i evs 64).map (·.foldl insertNew acc)) []

/-! ## Traces

The session tests in `reshard_send_session_test.cc` run a real
`ReshardSendSession` from `Start` on a `FakeD2hBase` — a `KVCacheManagerBase`
whose `D2hPoolBlocks` returns a `PjRtCopyFuture` that is ready at once, or
parked until `CompleteCopy` for a pool passed to `HoldNextCopy` — and push over
TCP to a receiver base whose `get_session` hook hands every push a
`StubRecvSession` (`AcceptPushes`); `RouteSessionLookups` points the sender's
own lookups at the session so pulls resolve its staging slots. A ready future
runs `pool_future.OnReady` on the pipeline thread inside the loop, so
`d2hDone p true` precedes `execFinish` in those traces; a parked copy holds its
op across the test's `Finish`. Every paired trace therefore starts from `init`.
`StartFailsFastWithoutTransportServer` fails `Start` on a CPU-only manager
before the pipeline thread exists. -/

/-- One pool, one peer, its push in flight, the pipeline thread done (the start
of `trace_finish_after_last_push`). -/
def afterPushStart : Send :=
  ((sys [1]).run (tr_parity_send.take 3)).getD (init [1])

example : afterPushStart.pools = [{ peers := 1, stage := .pushing 1 }] ∧
    afterPushStart.life.inFlight = 1 ∧ afterPushStart.execActive = false := by decide

/-- One pool and one peer, run to completion: `d2hIssue`, the inline D2H
callback issuing the push, the pipeline thread's `EndOp()`, the push callback. -/
def tr_one_pool_push : List Ev :=
  [.d2hIssue 0 true, .d2hDone 0 true, .execFinish, .pushDone 0 true]

/-- `BoundedStagingSlotAcquisitionAndRelease`, first session: three pools and
one host layer. Pool 0's held copy completes and its push returns the buffer;
pool 1 then leases it and its copy is held; `Finish(Cancelled)` wakes pool 2's
slot wait (`d2hIssue 2 false` on a finalizing session, folding the pipeline
thread's `EndOp()`); pool 1's released copy finds the send finalizing and its
`EndOp()` settles it. -/
def tr_bounded_three_pools : List Ev :=
  [.d2hIssue 0 true, .d2hDone 0 true, .pushDone 0 true, .d2hIssue 1 true,
   .cancel, .d2hIssue 2 false, .d2hDone 1 true]

/-- A slot wait running into `deadline_` while pool 0's held copy owns the
only buffer (`PipelineSlotWaitTimeoutSettlesSendOutOfBand` and the
`timeout_session` of `BoundedStagingSlotAcquisitionAndRelease`): pool 1's
`AcquireStagingSlot` fails with `DeadlineExceeded`, latching `finalizing_`;
the released copy's `EndOp()` settles. -/
def tr_slot_wait_timeout : List Ev :=
  [.d2hIssue 0 true, .d2hIssue 1 false, .d2hDone 0 true]

/-- `(upstream test, initial state, trace)`. -/
def paired : List (String × Send × List Ev) :=
  [("ReshardSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsBeforeSettling",
      init [1], tr_one_pool_push),
   ("ReshardSendSessionTest.PerTransferPolicyClosesIdlePeerConnectionsWhenCancelledMidCopy",
      init [1], [.d2hIssue 0 true, .execFinish, .cancel, .d2hDone 0 true]),
   ("ReshardSendSessionTest.PooledPolicyKeepsIdlePeerConnections",
      init [1], tr_one_pool_push),
   ("ReshardSendSessionTest.BoundedStagingSlotAcquisitionAndRelease",
      init [1, 1, 1], tr_bounded_three_pools),
   ("ReshardSendSessionTest.BoundedStagingSlotAcquisitionAndRelease (timeout_session)",
      init [1, 1, 1], tr_slot_wait_timeout),
   ("ReshardSendSessionTest.StartFailsFastWithoutTransportServer",
      init [1], tr_start_fails_fast.take 1),
   ("ReshardSendSessionTest.PipelineSlotWaitTimeoutSettlesSendOutOfBand",
      init [1, 1], tr_slot_wait_timeout),
   ("ReshardSendSessionTest.StagingSlotReleasedAfterLastPeerPush",
      init [2], [.d2hIssue 0 true, .execFinish, .d2hDone 0 true, .pushDone 0 true, .pushDone 0 true]),
   ("ReshardSendSessionTest.PoolOrderInvertedFromStorageOrderPassesTransportValidateChunks",
      init [1, 1], [.d2hIssue 0 true, .d2hDone 0 true, .d2hIssue 1 true, .d2hDone 1 true,
                    .execFinish, .pushDone 0 true, .pushDone 1 true])]

def modelOnly : List (String × Send × List Ev) :=
  [("trace_reshard_send_session_test_parity", init [1], tr_parity_send),
   ("trace_multi_pool_multi_peer_send", init [2, 1], tr_multi_pool_multi_peer_send),
   ("trace_start_fails_fast", init [1], tr_start_fails_fast),
   ("trace_cancel_settles_on_last_endOp", init [2], tr_cancel_settles_on_last_endOp),
   ("trace_partial_failure_keeps_plan", init [1, 1], tr_partial_failure_keeps_plan),
   ("trace_finish_after_last_push", afterPushStart, tr_finish_after_last_push)]

/-- Upstream tests on this C++ whose stimulus is not an event of the model. -/
def notReplayable : List (String × String) :=
  [("ReshardSendSessionTest.CreateRejectsUnknownDataConnReuseValue",
      "Create's TPU_RAIDEN_DATA_CONN_REUSE parse; no session exists"),
   ("PoolReshardSendTest.SenderWithNoBytesForAnyTransferredPoolRefusedUpFront",
      "Create's CountPoolReshardSendSlots == 0 rejection (validSchedule)"),
   ("PoolReshardValidationTest.DeviceOnlyRejectionAtPublicEntryPoints",
      "PoolReshardPush's has_device_buffers() rejection; no session exists"),
   ("SubPlanChainTest.SendTerminalWaitsForTheLastSubPlan",
      "Finish() on a session whose Start never ran (in_flight_ == 0, outside A2); asserts chain terminal aggregation (SubPlanChain.lean)"),
   ("PoolReshardSessionLookupTest.GetSessionResolvesActiveReshardSendUntilRetired",
      "same Finish() before Start, then GetSession before and after RetireSettledSessionLocked"),
   ("ReshardSendSessionTest.* ValidatePlan tests (6 tests)",
      "CreateReshardSendSession's ValidatePlan only (validSenderSpan, validSchedule); no session runs")]

/-! ## Result

Every search exhausts its state space, so `allBranches` is exact for senders
of one pool with one or two peers and of two pools with one peer each:
**26 branches**, and every leaf of `Leaf` is in one. (`cancel` never settles an
idle session here: `init` already holds `Start`'s caller op, `Send` A2; and it
never changes the status of a finalizing session, `Finish`'s
`if (done_ || finalizing_) return;`.)

The nine upstream traces in `paired` reach **10 of 26**: `d2hIssueOk`,
`d2hDoneStartsPushes`, `d2hDoneQuiesced` (settles), `execFinish` (no effect),
`pushDoneMore`, `pushDoneLast` (drains, settles), `cancel` (drains, errors),
`startFail` (drains, settles, errors), `d2hIssueFail` (drains, errors) and
`d2hIssueFailFinalizing` (no effect). The six `modelOnly` traces add 5 more.
Of the 16 the tests miss:

| Class | Count | Branches | What it would take |
|---|---|---|---|
| **test** | 11 | `pushDoneFail` (drains+settles+errors; drains+errors), `pushDoneLast` (drains, another op held), `pushDoneFinalizing` (no effect; settles), `cancel` (no effect), `startFailFinalizing` (settles), `d2hIssueFail` (drains+settles+errors), `d2hIssueFailFinalizing` (settles), `execFinish` (settles), `publish` | the `FakeD2hBase` fixtures with a push that fails or is held: a peer whose `get_session` hook refuses the push (`pushDoneFail`), a push still in flight when `Finish` runs (`pushDoneFinalizing`, then `cancel` on the finalizing send), a `D2hPoolBlocks` override returning an error status for the first pool (`d2hIssueFail` settling, no copy in flight), the pipeline thread finishing its loop after the last push returned (`execFinish` settling, `pushDoneLast` with the caller op still held — a race the ready-future tests do not pin down), a `Finish` between `Start`'s `++in_flight_;` and `ValidatePushPreconditions` (`startFailFinalizing`), and a send registered through `PoolReshardPush` and polled by `CompleteReadWithDetails` (`publish`) |
| **test (copy error)** | 5 | `d2hDoneFail` (drains+settles+errors; drains+errors), `d2hDoneFailFinalizing` (no effect; settles), `d2hDoneQuiesced` (no effect) | `FakeD2hBase` completing a held copy with an error status (`xla::Promise<>::Set(status)`, as `FakeH2dBase::ArmPoolUpload` does in `kv_cache_manager_with_transfer_pool_reshard_test.cc`); `d2hDoneQuiesced` without effect needs a second held copy still counted when a cancelled send's first copy returns |

So the upstream send tests now drive a successful D2H issue, its inline
callback issuing real pushes, a copy returning after `Finish`, and the slot
wait failing, but no failed push and no failed copy: `FakeD2hBase::CompleteCopy`
only sets its promise OK, and every push in `reshard_send_session_test.cc`
lands on a `StubRecvSession` that accepts it (`docs/transfer/reshard.md`
§"C++ branch coverage of the anchored spans"). -/

/-- `(leaf, drains, settles, errors)`. -/
def br (l : Leaf) (drains settles errors : Bool) : Branch := (l, ⟨drains, settles, errors⟩)

def coveredByPaired : List Branch :=
  Coverage.coveredBy instr (paired.map fun (_, s, tr) => (s, tr))
def coveredByAll : List Branch :=
  Coverage.coveredBy instr ((paired ++ modelOnly).map fun (_, s, tr) => (s, tr))

inductive Gap where
  | test
  | copyError
  deriving Repr, DecidableEq

/-- The table above, as the `#guard` checks it. -/
def gaps : List (Branch × Gap) :=
  [(br .pushDoneFail true true true, .test), (br .pushDoneFail true false true, .test),
   (br .pushDoneFinalizing false false false, .test),
   (br .pushDoneFinalizing false true false, .test),
   (br .pushDoneLast true false false, .test),
   (br .cancel false false false, .test),
   (br .startFailFinalizing false true false, .test),
   (br .d2hIssueFail true true true, .test),
   (br .d2hIssueFailFinalizing false true false, .test),
   (br .execFinish false true false, .test),
   (br .publish false false false, .test),
   (br .d2hDoneFail true true true, .copyError), (br .d2hDoneFail true false true, .copyError),
   (br .d2hDoneFailFinalizing false false false, .copyError),
   (br .d2hDoneFailFinalizing false true false, .copyError),
   (br .d2hDoneQuiesced false false false, .copyError)]

def allLeaves : List Leaf :=
  [.startFail, .startFailFinalizing, .d2hIssueOk, .d2hIssueFail, .d2hIssueFailFinalizing,
   .execFinish, .d2hDoneFail, .d2hDoneFailFinalizing, .d2hDoneQuiesced, .d2hDoneStartsPushes,
   .pushDoneFail, .pushDoneFinalizing, .pushDoneLast, .pushDoneMore, .cancel, .publish]

def countGap (g : Gap) : Nat := (gaps.filter (·.2 = g)).length

/-- One search, every check: the state space is exhausted; 26 branches; 10
reached by paired traces, 15 with `modelOnly` (all within the universe, every
trace running to completion); the uncovered set is the table (11 test, 5
copy-error); every leaf fires; every gap has a witness schedule. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let uncoveredPaired := univ.filter (fun b => !coveredByPaired.contains b)
    univ.length = 26 ∧ coveredByPaired.length = 10 ∧ coveredByAll.length = 15 ∧
    coveredByPaired.all univ.contains ∧ coveredByAll.all univ.contains ∧
    sameSet uncoveredPaired (gaps.map Prod.fst) ∧ gaps.length = 16 ∧
    countGap .test = 11 ∧ countGap .copyError = 5 ∧
    allLeaves.all (fun l => univ.any (·.1 = l)) ∧
    (paired ++ modelOnly).all (fun (_, s, tr) =>
      ((⟨s, step⟩ : System Send Ev).run tr).isSome) ∧
    gaps.all (fun (b, _) => inits.any fun (i, evs) => (Coverage.witness instr i evs b).isSome)

#guard coverageChecks

end Send

end TpuSyncVerify.Transfer.Reshard
