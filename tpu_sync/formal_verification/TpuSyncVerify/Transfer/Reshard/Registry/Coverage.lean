import TpuSyncVerify.Common.Coverage
import TpuSyncVerify.Transfer.Reshard.Registry

/-! # `Registry`: branch coverage of `RegGen.step` by the replayed tests

Part of `TpuSyncVerify.Transfer.Reshard.Registry`. Built like
`Reshard/Receive/Coverage.lean` (machinery in `Common/Coverage.lean`):
`Leaf` names one leaf of an event's decision tree, `stepT` is `RegGen.step` with
the leaf attached, and `stepT_step` proves it is the same function. The registry
has no session lifecycle, so the effect read off a step is the generation's
`Status` before and after and whether `RetireLocked` fired (`RegEffect`).

`RegGen.step` refuses (returns `none`) where the C++ returns an error to its
caller; a refused event is not a branch of the search (as in every other
coverage module) but is an outcome the tests assert on, so the refusal arms are
listed separately (`Refusal`, `refusal`) with the test that reaches each. -/

namespace TpuSyncVerify.Transfer.Reshard.Registry

open TpuSyncVerify.Coverage (Instr insertNew sameSet)

/-- One leaf of `RegGen.step`'s decision tree per event, among the arms that
return a state. -/
inductive Leaf
  /-- `Register`: a new `(req_id, unit)` row (`request_blocks_[key] = std::move(registration);`). -/
  | registerNew
  /-- `Register`: identical re-registration, overwriting the row with a fresh
  `registration.expires_at = now + ttl_s_;`
  (`auto existing = request_blocks_.find(key);` .. `request_blocks_[key] = std::move(registration);`). -/
  | registerRefresh
  /-- `LookupAndClaim`: claim recorded, owner added
  (`claimed_[lifecycle_key] = now + ttl_s_;` .. `claimed_owners_[lifecycle_key].insert(claim_owner);`). -/
  | claimOk
  /-- `LookupAndClaim`: every requested unit had already voted, so the claim
  retires the generation at once (`if (completion_it != completed_units_.end())`). -/
  | claimRetiresVoted
  /-- `AbandonClaim`: another owner remains, the claim stays. -/
  | abandonOther
  /-- `AbandonClaim`: the last owner left, the claim is dropped
  (`if (owner_it->second.empty())`). -/
  | abandonLast
  /-- `Complete`: no registration and not an expected unit
  (`if (!registration_matches && !unit_expected)`): idempotent no-op. -/
  | completeNoOp
  /-- `Complete`: vote recorded under an active claim, not the last
  (`completion.units.insert(unit);`). -/
  | completeVote
  /-- `Complete`: vote recorded with no claim yet — only an empty-blocks
  registration may complete before the snapshot is claimed
  (`!registration_it->second.block_ids.empty()` is what the pre-claim refusal
  tests), and without `has_expected` nothing can retire. -/
  | completeVoteUnclaimed
  /-- `Complete`: the last expected vote, `RetireLocked` (`if (has_expected)` / `all_voted`). -/
  | completeRetires
  /-- `CancelIfUnclaimed` on a cancelled generation: `true`, nothing changes. -/
  | cancelAlready
  /-- `CancelIfUnclaimed` on a claimed generation: `false`, nothing changes
  (`if (claimed_.find(lifecycle_key) != claimed_.end())`). -/
  | cancelRefusedClaimed
  /-- `CancelIfUnclaimed`: tombstone recorded, unclaimed rows erased
  (`cancelled_[lifecycle_key] = now + ttl_s_;` .. `return true;`). -/
  | cancelTombstone
  /-- `Release`: `RetireLocked`. -/
  | release
  deriving Repr, DecidableEq

/-- What a step did to the generation. -/
structure RegEffect where
  before : BlockStatus
  after : BlockStatus
  /-- `RetireLocked` fired in this step. -/
  retires : Bool
  deriving Repr, DecidableEq

def effect (s s' : RegGen) : RegEffect :=
  { before := s.status, after := s'.status, retires := !s.retired && s'.retired }

abbrev Branch := Leaf × RegEffect

/-- The leaf `Complete` takes, read off the state before. -/
def completeLeaf (s : RegGen) (unit : Nat) : Leaf :=
  if (s.lookupUnit unit).isNone && !inClaimedUnits s.claimedUnits unit then .completeNoOp
  else
    match s.claimedUnits with
    | some expected =>
      if allVoted expected (insertNodup unit s.completedUnits) then .completeRetires
      else .completeVote
    | none => .completeVoteUnclaimed

/-- `RegGen.step` with the leaf it took. -/
def stepT (s : RegGen) : Ev → Option (RegGen × Leaf)
  | .register unit nonEmpty =>
    (s.step (.register unit nonEmpty)).map
      (·, if (s.lookupUnit unit).isSome then .registerRefresh else .registerNew)
  | .lookupAndClaim owner units =>
    (s.step (.lookupAndClaim owner units)).map
      (·, if allVoted units s.completedUnits then .claimRetiresVoted else .claimOk)
  | .abandonClaim owner =>
    (s.step (.abandonClaim owner)).map
      (·, if (s.claimOwners.filter (fun o => o != owner)).isEmpty then .abandonLast
          else .abandonOther)
  | .complete unit => (s.step (.complete unit)).map (·, completeLeaf s unit)
  | .cancelIfUnclaimed =>
    (s.step .cancelIfUnclaimed).map
      (·, if s.cancelled then .cancelAlready
          else if s.claimedUnits.isSome then .cancelRefusedClaimed
          else .cancelTombstone)
  | .release => (s.step .release).map (·, .release)

/-- `stepT` is `RegGen.step` with a tag: same enabledness, same post-state. -/
theorem stepT_step (s : RegGen) (e : Ev) : (stepT s e).map (·.1) = RegGen.step s e := by
  cases e <;> simp [stepT, Option.map_map, Function.comp_def]

/-! ## Refusals

The arms of `RegGen.step` that return `none`: the C++ error returns
(`InvalidArgument` / `FailedPrecondition` / `NotFound` statuses that
`ReshardService` turns into `success = false` responses). `refusal` names the
arm; `refusal_step` checks it against `step` on the states the tests reach. -/

inductive Refusal
  /-- `Register` on a cancelled, claimed, or retired generation
  (`if (cancelled_.find(lifecycle_key) != cancelled_.end())`,
  `if (claimed_.find(lifecycle_key) != claimed_.end())`). -/
  | registerLifecycle
  /-- `Register` with a different payload for an existing row. -/
  | registerConflict
  /-- `LookupAndClaim` on a cancelled generation or with no units. -/
  | claimCancelledOrEmpty
  /-- `LookupAndClaim` for a different unit set than the live claim
  (`if (existing_units_it != claimed_units_.end() &&`). -/
  | claimIncompatible
  /-- `LookupAndClaim` naming an unregistered unit (`for (const RaidenId& unit : units)`,
  "Missing producer block registration"). -/
  | claimMissingUnit
  /-- `AbandonClaim` by a non-owner. -/
  | abandonNotOwner
  /-- `Complete` of a non-empty registration before any claim
  (`if (!has_expected && has_registration &&`). -/
  | completeBeforeClaim
  deriving Repr, DecidableEq

def refusal (s : RegGen) : Ev → Option Refusal
  | .register unit nonEmpty =>
    if s.cancelled || s.claimedUnits.isSome || s.retired then some .registerLifecycle
    else match s.lookupUnit unit with
      | some cur => if cur != nonEmpty then some .registerConflict else none
      | none => none
  | .lookupAndClaim _ units =>
    if s.cancelled || units.isEmpty then some .claimCancelledOrEmpty
    else if !compatibleClaim s.claimedUnits units then some .claimIncompatible
    else if !units.all (fun u => (s.lookupUnit u).isSome) then some .claimMissingUnit
    else none
  | .abandonClaim owner =>
    if !s.claimOwners.contains owner then some .abandonNotOwner else none
  | .complete unit =>
    if !s.claimedUnits.isSome && s.lookupUnit unit == some true then some .completeBeforeClaim
    else none
  | .cancelIfUnclaimed => none
  | .release => none

/-- `refusal` names exactly the refused events. -/
theorem refusal_step (s : RegGen) (e : Ev) :
    (refusal s e).isSome = (RegGen.step s e).isNone := by
  cases e <;> (simp only [refusal, RegGen.step]; repeat' split) <;> simp_all

def instr : Instr RegGen Ev Leaf RegEffect := { stepT, effect }

/-- The universe is searched from the empty generation over `checkEvents`: two
producer units, two pipelined owners, one conflicting (empty-blocks)
re-registration, one narrower claim. -/
def allBranches : Option (List Branch) :=
  Coverage.reachableBranches instr RegGen.init checkEvents 64

/-! ## Traces

`paired` lists every test in `reshard_service_test.cc` that drives
`RequestBlockRegistry` through events of this model (through
`ReshardService::HandleControllerCommand`, `BuildPoolReshardPlan`, or
`ReshardCoordinator::RunSubPlan`), with the trace each replays from the empty
generation; owners are `100` / `101` as in `checkEvents`. `refused` lists the
refusals those tests assert, as `(test, trace, refused event, arm)`;
`notReplayable` lists the remaining tests in `reshard_service_test.cc` whose
stimulus is outside `RegGen.step`. -/

def tr_cancel_fresh : List Ev := [.cancelIfUnclaimed]
def tr_register_cancel : List Ev := [.register 0 true, .cancelIfUnclaimed]
def tr_claim_one : List Ev := [.register 0 true, .lookupAndClaim 100 [0]]
def tr_claim_two : List Ev := [.register 0 true, .register 1 true, .lookupAndClaim 100 [0, 1]]
def tr_claim_abandon_one : List Ev := tr_claim_one ++ [.abandonClaim 100]
def tr_claim_abandon_two : List Ev := tr_claim_two ++ [.abandonClaim 100]
def tr_claim_then_cancel_refused : List Ev := tr_claim_two ++ [.cancelIfUnclaimed]
def tr_votes_retire : List Ev := tr_claim_two ++ [.complete 0, .complete 1]
def tr_two_stages : List Ev := tr_claim_two ++ [.lookupAndClaim 101 [0, 1]]
def tr_two_windows : List Ev := tr_claim_two ++ [.lookupAndClaim 100 [0, 1]]
def tr_four_windows_cancel : List Ev :=
  tr_claim_two ++ [.lookupAndClaim 100 [0, 1], .lookupAndClaim 100 [0, 1],
    .lookupAndClaim 100 [0, 1], .cancelIfUnclaimed]
def tr_sibling_keeps_claim : List Ev :=
  tr_two_stages ++ [.abandonClaim 101, .cancelIfUnclaimed, .lookupAndClaim 101 [0, 1]]
def tr_last_stage_frees : List Ev :=
  [.register 0 true, .register 1 true, .lookupAndClaim 100 [0, 1], .abandonClaim 100,
   .lookupAndClaim 101 [0, 1], .abandonClaim 101, .cancelIfUnclaimed]
def tr_arm_failure_retry : List Ev :=
  [.register 0 true, .lookupAndClaim 100 [0], .abandonClaim 100, .lookupAndClaim 101 [0]]

/-- `(upstream test, trace)`, all from `RegGen.init`. -/
def paired : List (String × List Ev) :=
  [("ReshardStackTest.FullPoolReshardFlowEmitsArmThenDispatch", tr_claim_two),
   ("ReshardStackTest.GlobalSpaceSpansSplitAtPageBoundaries", tr_claim_two),
   ("ReshardStackTest.ClipDropsTrimsAndRebasesGlobalSpans", tr_claim_two),
   ("ReshardStackTest.WindowedRequestChainsOneSubTransferPerWindow", tr_four_windows_cancel),
   ("ReshardStackTest.WindowClipsStraddlingSpansAtWindowBoundaries", tr_two_windows),
   ("ReshardStackTest.WindowComposesWithPrefixClip", tr_two_windows),
   ("ReshardStackTest.ChainedArmRetriesWhileReceiverStagingIsBusy", tr_two_windows),
   ("ReshardStackTest.ChainedRequestStaysInProgressUntilTheChainEnds", tr_two_windows),
   ("ReshardStackTest.ChainedArmFailureMarksTheTransferFailed", tr_two_windows),
   ("ReshardStackTest.ClipValidationFailsClosed", tr_arm_failure_retry),
   ("ReshardStackTest.ClipRejectsPageIndexedDeclarations", tr_claim_abandon_one),
   ("ReshardStackTest.ArmFailureAbandonsClaimAndSkipsSenders", tr_arm_failure_retry),
   ("ReshardStackTest.CancelTombstoneBlocksLateRegistration", tr_cancel_fresh),
   ("ReshardStackTest.RequestBlockStatusProbeTracksLifecycle", tr_register_cancel),
   ("ReshardStackTest.RequestBlockStatusProbeTracksLifecycle", tr_claim_then_cancel_refused),
   ("ReshardStackTest.CompletionVotesRetireAfterClaim", tr_votes_retire),
   ("ReshardStackTest.TtlPurgesExpiredRegistrations", [.register 0 true]),
   ("ReshardStackTest.TwoDestinationsArmEachThenDispatchSendersOnce", tr_claim_two),
   ("ReshardStackTest.SubsetSourceManifestsPairPoolsByTag", tr_claim_two),
   ("ReshardStackTest.PipelinedDestinationStagesShareOneRequestClaim", tr_two_stages),
   ("ReshardStackTest.AbandonedStageLeavesTheSiblingClaimInPlace", tr_sibling_keeps_claim),
   ("ReshardStackTest.AbandoningTheLastStageFreesTheClaim", tr_last_stage_frees),
   ("ReshardStackTest.SourceTagsAbsentOnTheDestinationAreIgnored", tr_claim_one),
   ("ReshardStackTest.MismatchedDestinationsFailClosed", tr_arm_failure_retry),
   ("ReshardStackTest.TwoDestinationsShardedSpansRouteBytesPerReceiver", tr_claim_two),
   ("ReshardStackTest.StridedGlobalSpansStayOneEntryPerDestination", tr_claim_two),
   ("ReshardStackTest.StridedGlobalSpansClipByWholePages", tr_claim_two),
   ("ReshardStackTest.StridedGlobalSpansMustStayInsideOnePage", tr_claim_abandon_one),
   ("ReshardStackTest.ShardedSpanOrdinalOutOfRangeFailsClosed", tr_claim_abandon_two),
   ("ReshardStackTest.ShardedDestinationWithoutCoverageFailsClosed", tr_claim_abandon_two),
   ("ReshardStackTest.ShardedNonUniformExtentsFailClosed", tr_claim_abandon_two),
   ("ReshardStackTest.ReplicatedAndRoutedSpansCombine", tr_claim_two),
   ("ReshardStackTest.UnsetTransferStreamsPlansOneStreamPerSourceRank", tr_claim_two),
   ("ReshardStackTest.TransferStreamsEnvCapsPlanStreamsAndExpectedPushes", tr_claim_two),
   ("ReshardStackTest.ExplicitPlanParallelismOverridesTransferStreamsEnv", tr_claim_two),
   ("ReshardStackTest.InvalidTransferStreamsEnvFailsThePlan", [.register 0 true, .register 1 true])]

/-- `(upstream test, trace, refused event, arm)`: the refusals the tests assert
after the trace. `TtlPurgesExpiredRegistrations`'s refusal follows a TTL purge
(`purgeExpiredAll`), which is not an event, so it is checked on the purged state. -/
def refused : List (String × List Ev × Ev × Refusal) :=
  [("ReshardStackTest.CancelTombstoneBlocksLateRegistration", tr_cancel_fresh,
     .register 0 true, .registerLifecycle),
   ("ReshardStackTest.AbandoningTheLastStageFreesTheClaim", tr_last_stage_frees,
     .lookupAndClaim 100 [0, 1], .claimCancelledOrEmpty),
   ("ReshardStackTest.MissingRegistrationKeepsContractString", [],
     .lookupAndClaim 100 [0], .claimMissingUnit)]

/-- Remaining tests in `reshard_service_test.cc` whose stimulus does not reach a
`RegGen.step` transition (plus `MissingRegistrationKeepsContractString` above,
which asserts a refusal on `RegGen.init` without taking a step). -/
def notReplayable : List (String × String) :=
  [("ReshardStackTest.SpansForAnUnregisteredTagAreRefusedAtRegistration",
      "RequestBlockRegistry::Register rejects an unknown pool tag before acquiring the lifecycle mu_ scope"),
   ("ReshardStackTest.NegativeOrdinalRejectedAtRegistration",
      "RequestBlockRegistry::Register rejects dst_unit_ordinal < -1 before acquiring the lifecycle mu_ scope"),
   ("ReshardStackTest.LegacyCommandsFailClosed",
      "worker-side COMMAND_REGISTER_TRANSFER_SCHEDULE rejection; never touches RequestBlockRegistry"),
   ("ReshardControlPipeTest.* (3 tests)", "control-pipe transport round-trip only"),
   ("PlanSubTransfersTest.* (5 tests)", "pure PlanSubTransfers window-splitting unit tests"),
   ("SubPlanUuidTest.DerivedUuidsArePositiveAndDistinct", "pure SubPlanUuid helper unit test")]

-- Every paired trace runs to its end, and each refusal is the named arm.
#guard paired.all fun (_, tr) => (RegGen.sys.run tr).isSome
#guard refused.all fun (_, tr, e, r) =>
  (RegGen.sys.run tr).bind (fun s => refusal s e) == some r
#guard (RegGen.sys.run [.register 0 true]).map
  (fun s => refusal s.purgeExpiredAll (.lookupAndClaim 100 [0])) == some (some .claimMissingUnit)

/-! ## Result

The search exhausts the state space: **25 branches** (14 leaves × the status
transitions each can make), every leaf of `Leaf` reachable. The 35 upstream
tests in `paired` (36 traces) reach **11 of 25**: `registerNew` (from `unknown`
and from `registered`), `claimOk` (first claim on `registered`, subsequent same-
or second-owner claim on `claimed`), `abandonOther`, `abandonLast`,
`completeVote`, `completeRetires`, `cancelRefusedClaimed`, and
`cancelTombstone` (on an empty and on a registered generation). Of the seven
`Refusal` constructors, three are asserted (`registerLifecycle` on a tombstone,
`claimCancelledOrEmpty` on a cancelled generation, `claimMissingUnit`).

The registry is one mutex and one map per table, so every gap is a schedule
`ReshardStackTest` can drive through controller commands; none needs a window
or a stub:

| Class | Count | Branches | What it would take |
|---|---|---|---|
| **test** | 14 | `registerRefresh`; `completeNoOp` (on `unknown`, `registered`, `claimed`, `cancelled`); `completeVoteUnclaimed` and `claimRetiresVoted` (an empty-blocks registration voting before the claim, then the claim retiring at once); `cancelAlready`; `release` (from each status, and on an already retired generation) | re-send an identical `COMMAND_REGISTER_REQUEST_BLOCKS`; `COMMAND_COMPLETE_REQUEST_BLOCKS` for an unknown unit, after retirement, and after a cancel; a registration with no `block_ids` completed before `Coordinate`; a second `COMMAND_CANCEL_REQUEST_BLOCKS_IF_UNCLAIMED`; `COMMAND_RELEASE_REQUEST_BLOCKS` with `force = true` (`ReshardClient::BuildReleaseRequestBlocks`, sent by no C++ test) |

Unasserted `Refusal` constructors: `registerConflict` (a different payload for a
registered unit), `claimIncompatible` (a second claim for a different unit
set), `abandonNotOwner`, and `completeBeforeClaim` (a non-empty registration
completing before planning); within the asserted constructors, no test exercises
`registerLifecycle` on a claimed or retired generation or `claimCancelledOrEmpty`
with `units = []`. -/

def coveredByPaired : List Branch := Coverage.coveredBy instr (paired.map fun (_, tr) => (RegGen.init, tr))

def br (l : Leaf) (b a : BlockStatus) (retires : Bool) : Branch := (l, ⟨b, a, retires⟩)

def gaps : List Branch :=
  [br .registerRefresh .registered .registered false,
   br .completeNoOp .unknown .unknown false, br .completeNoOp .registered .registered false,
   br .completeNoOp .claimed .claimed false, br .completeNoOp .cancelled .cancelled false,
   br .completeVoteUnclaimed .registered .registered false,
   br .claimRetiresVoted .registered .unknown true,
   br .cancelAlready .cancelled .cancelled false,
   br .release .unknown .unknown true, br .release .unknown .unknown false,
   br .release .registered .unknown true, br .release .claimed .unknown true,
   br .release .cancelled .unknown true, br .release .cancelled .unknown false]

def allLeaves : List Leaf :=
  [.registerNew, .registerRefresh, .claimOk, .claimRetiresVoted, .abandonOther, .abandonLast,
   .completeNoOp, .completeVote, .completeVoteUnclaimed, .completeRetires, .cancelAlready,
   .cancelRefusedClaimed, .cancelTombstone, .release]

def assertedRefusals : List Refusal := refused.map (·.2.2.2)

/-- One search, every check: the state space is exhausted; 25 branches; 11
reached by paired traces; the uncovered set is the table; every leaf fires;
every gap has a witness schedule; three refusal arms asserted. -/
def coverageChecks : Bool :=
  match allBranches with
  | none => false
  | some univ =>
    let uncovered := univ.filter (fun b => !coveredByPaired.contains b)
    univ.length = 25 ∧ coveredByPaired.length = 11 ∧
    coveredByPaired.all univ.contains ∧
    sameSet uncovered gaps ∧ gaps.length = 14 ∧
    allLeaves.all (fun l => univ.any (·.1 = l)) ∧
    gaps.all (fun b => (Coverage.witness instr RegGen.init checkEvents b).isSome) ∧
    assertedRefusals.eraseDups.length = 3

#guard coverageChecks

end TpuSyncVerify.Transfer.Reshard.Registry
