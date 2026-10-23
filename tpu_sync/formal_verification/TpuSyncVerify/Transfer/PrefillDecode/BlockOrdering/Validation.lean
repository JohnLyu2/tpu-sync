import TpuSyncVerify.Transfer.PrefillDecode.Pipeline

/-! # `BlockOrdering`: producer registration and pull validation

Part of `TpuSyncVerify.Transfer.PrefillDecode.BlockOrdering`; the module docstring and
source map live in `BlockOrdering.lean`. -/

namespace TpuSyncVerify.Transfer.PrefillDecode

namespace BlockOrdering

/-! ## 1. Producer Registration & Pull Validation (`PopulateRegisteredBlocks`, `ValidateAndBeginPull`) -/

/-- Decidable list duplicate check (`TransferSendSession::PopulateRegisteredBlocks`). -/
def noDuplicates : List Nat → Bool
  | [] => true
  | x :: xs => (!xs.contains x) && noDuplicates xs

theorem noDuplicates_iff_nodup (xs : List Nat) :
    noDuplicates xs = true ↔ xs.Nodup := by
  induction xs with
  | nil => simp [noDuplicates]
  | cons x xs ih =>
    simp [noDuplicates, List.nodup_cons, ih]

/-- `TransferSendSession::PopulateRegisteredBlocks` (called from
`TransferSendSession::Create`): `NotifyForRead` accepts `registered_block_ids`
iff it contains no duplicate block ID. -/
def validateRegistration (registered : List Nat) : Bool :=
  noDuplicates registered

theorem validateRegistration_iff (registered : List Nat) :
    validateRegistration registered = true ↔ registered.Nodup :=
  noDuplicates_iff_nodup registered

/-- `TransferSendSession::ValidateRequestedBlocksLocked`: `ValidateAndBeginPull`
accepts `requested_block_ids` iff:
1. `!requested_block_ids.empty()`,
2. every requested block is in `registered_block_set_`
   (`registered_block_set_.find(block_id) == registered_block_set_.end()` false), and
3. `requested_block_ids` has no duplicate producer block IDs
   (`!seen.insert(block_id).second` false). -/
def validateRequestedBlocks (registered requested : List Nat) : Bool :=
  (!requested.isEmpty) && requested.all (fun b => registered.contains b) &&
    noDuplicates requested

theorem validateRequestedBlocks_iff (registered requested : List Nat) :
    validateRequestedBlocks registered requested = true ↔
      requested ≠ [] ∧ (∀ b ∈ requested, b ∈ registered) ∧ requested.Nodup := by
  simp [validateRequestedBlocks, Bool.and_eq_true,
    List.all_eq_true, noDuplicates_iff_nodup, and_assoc]


end BlockOrdering

end TpuSyncVerify.Transfer.PrefillDecode
