import TpuSyncVerify.Transfer.Reshard.PoolStaging.Arena
import TpuSyncVerify.Transfer.Reshard.PoolStaging.ArenaLemmas
import TpuSyncVerify.Transfer.Reshard.PoolStaging.Registration
import TpuSyncVerify.Transfer.Reshard.PoolStaging.Invariant
import TpuSyncVerify.Transfer.Reshard.PoolStaging.Traces

/-!
# Bounded pool host staging and per-UUID lease lifecycle

Formal model and proofs of bounded host staging (`PoolStagingStorage`) and
per-UUID page-lease lifecycle in `KVCacheManagerBase` and
`KVCacheManagerWithTransfer`.

`base.h`/`base.cc` are `tpu_sync/kv_cache/kv_cache_manager_base.{h,cc}`;
`mgr.cc` is `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`;
`reshard_recv.cc` is `tpu_sync/kv_cache/reshard_receive_session.cc` (which
holds the class `ReshardReceiveSession` behind the factory
`CreateReshardReceiveSession`); `pool_reshard_test.cc` is
`tpu_sync/kv_cache/kv_cache_manager_with_transfer_pool_reshard_test.cc`. Exact
line ranges for every symbol, sub-block, and test are in the generated
`## Source map` table below.

  ## C++ anchorage

  1. **Bounded staging arena (`PoolStagingStorage` in `base.h`,
     `KVCacheManagerBase::ConfigurePoolStaging` in `base.cc`):**
     When a storage's pools declare `staging_blocks_per_request > 0` and
     `staging_leases > 0` such that `num_slots = staging_leases *
     blocks_per_lease < max_pool_blocks`, `ConfigurePoolStaging` allocates a
     bounded host arena of `num_slots` page slots (`free_slots = [num_slots-1,
     ..., 0]`, so `.back()` pops `0, 1, ...` in order).

  2. **Idempotent per-UUID lease acquisition (`KVCacheManagerBase::AcquirePoolStagingLease` in `base.cc`):**
     Filters `block_ids` down to `missing` — deduplicated block IDs not already
     present in `st.leases[uuid]->slot_by_block` (`if (cur != nullptr && cur->slot_by_block.contains(block_id)) continue;`). Multiple pools
     sharing a physical storage (`storage_index`) therefore share one page lease
     under the same `uuid` without double-allocating slots. If
     `missing.size() > st.num_slots` or `st.free_slots.size() < missing.size()`,
     acquisition fails with `ResourceExhausted` (`if (static_cast<int64_t>(missing.size()) > st.num_slots)` and `while (st.free_slots.size() < missing.size())`). Otherwise it
     pops `missing.size()` slots from `free_slots` and records `block_id ↦ slot`
     in `st.leases[uuid]` (`for (int64_t block_id : missing)` through `st.leases[uuid] = std::move(lease)`).

  3. **Lease release (`KVCacheManagerBase::ReleasePoolStagingLeases` in `base.cc`):**
     Looks up `st.leases.find(uuid)`, pushes every `slot ∈ lease->slots` back
     onto `st.free_slots`, and erases `uuid` from `st.leases`.

  4. **Receive registration lifecycle (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv` in `mgr.cc`,
     `CreateReshardReceiveSession`, `ReshardReceiveSession::AcquireStagingLeases`, `ReshardReceiveSession::ReleaseStaging` in `reshard_recv.cc`):**
     `PoolReshardRegisterRecv` executes in three steps:
     - Phase 1 (one `mu_` scope of `KVCacheManagerWithTransfer::PoolReshardRegisterRecv`):
       looks `plan.uuid()` up in `sessions_` — a settled incumbent is retired
       (`RetireSettledSessionLocked`), a live one is refused
       (`AlreadyExistsError`) — and claims the uuid in
       `pending_pool_reshard_recvs_`
       (`if (!pending_pool_reshard_recvs_.insert(plan.uuid()).second)` refuses
       a concurrent duplicate) before constructing any `ReshardReceiveSession`
       object; the retired incumbent's leases are released outside the lock
       (`ReleasePoolStagingLeases`) while the claim already blocks a third arm.
     - Phase 2 (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv` calling `CreateReshardReceiveSession` and `ReshardReceiveSession::AcquireStagingLeases`): constructs `ReshardReceiveSession`
       and calls `AcquireStagingLeases(plan)`,
       which sets `staging_released_ = false` and calls
       `base_->AcquirePoolStagingLease(uuid(), ...)`. On failure,
       the factory calls `session->ReleaseStaging()` (`ReleaseStagingLocked`) while
       `uuid` is still claimed, and the `absl::Cleanup clear_pending` of
       `PoolReshardRegisterRecv` drops the claim afterwards.
     - Phase 3 (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv`, `sessions_[plan.uuid()] = SessionEntry{recv_session, plan.req_id(),` under `mu_`):
       drops the pending claim and inserts the session into `sessions_` (as a
       `SessionEntry` with `SessionRole::kPoolReshardReceive`) in one scope
       (and, for a sub-plan of a chained request, records it in the request's
       `sub_plan_chains_` entry, `NoteSubPlanRegisteredLocked`).
     The poll's lease release for a retired uuid honours the claim too:
     `CompleteReadWithDetails` drops a retired uuid from `retired_uuids` when
     `pending_pool_reshard_recvs_.contains(uuid)`, so a re-registration in
     flight never has its freshly acquired lease released by the sweep of the
     uuid's previous session (`settleSession`'s in-flight guard).
     Under the unreserved mutant (`RegistrationPolicy.leaseBeforeReserve`),
     if Phase 2 ran before the uuid was claimed, two concurrent or duplicate
     `PoolReshardRegisterRecv` calls with the same `uuid` would share
     `st.leases[uuid]` in Phase 2; when the second call was then refused
     (`AlreadyExistsError`), destroying its `ReshardReceiveSession` would run
     `~ReshardReceiveSession() -> ReleaseStaging() -> ReleasePoolStagingLeases(uuid)`
     (`ReshardReceiveSession::~ReshardReceiveSession`, `ReshardReceiveSession::ReleaseStagingLocked` and `ReshardReceiveSession::ReleaseStaging` in `reshard_recv.cc`),
     erasing `st.leases[uuid]` and returning the surviving session's slots to
     `free_slots` while the surviving session is still active.

  ## Main results

  - `missingBlocksAux_empty_of_covered` & `acquireLease_idempotent`: re-acquiring
    a subset of already-leased block IDs for the same `uuid` is a no-op
    (`KVCacheManagerBase::AcquirePoolStagingLease`: `if (cur != nullptr && cur->slot_by_block.contains(block_id)) continue;` and `if (missing.empty()) return absl::OkStatus();`).
  - `ArenaInv.conservation` & `allocateMissing_slot_sum`:
    total slots across `freeSlots` and all active leases equals `numSlots`.
  - `no_slot_aliasing_between_distinct_uuids`: when active leases hold disjoint
    slot lists (`ArenaInv.nodupSlots` / `leases_disjoint_of_nodup`), distinct
    `uuid`s never resolve any block ID to the same host staging slot.
  - `reachable_reserveBeforeLease_safe`: under the shipping `reserveBeforeLease`
    protocol (claiming `uuid` before acquiring staging leases), every reachable
    state keeps active session leases live and pairwise slot-disjoint.
  - `trace_duplicate_uuid_frees_survivor_lease_and_aliases_slot`: constructive
    counterexample trace under the `leaseBeforeReserve` mutant showing a
    rejected duplicate-UUID arm freeing the survivor's lease
    and a third session (`uuid = 8`) receiving the same physical slot `0`.

## Source map

Generated by `tools/resolve_anchors.py`.

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|---|---|---|
| `base.h` | `PoolStagingLease` | `:943-946` |
| `base.h` | `PoolStagingStorage` | `:947-955` |
| `base.cc` | `RemoteAddress` | `:145-166` |
| `base.cc` | `KVCacheManagerBase::ConfigurePoolStaging` | `:2390-2503` |
| `base.cc` | `KVCacheManagerBase::PoolStagingLeaseSnapshot` | `:2511-2522` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` | `:2524-2581` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` (`std::vector<int64_t> missing;` .. `if (missing.empty())`) | `:2535-2549` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` (`if (static_cast<int64_t>(missing.size()) > st.num_slots)` .. `while (st.free_slots.size() < missing.size())`) | `:2552-2560` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` (`auto lease = std::make_shared<PoolStagingLease>();` .. `st.leases[uuid] = std::move(lease);`) | `:2569-2579` |
| `base.cc` | `KVCacheManagerBase::ReleasePoolStagingLeases` | `:2583-2599` |
| `base.cc` | `KVCacheManagerBase::PoolBlockHostBase` | `:2623-2668` |
| `base.cc` | `KVCacheManagerBase::PoolHostBaseAddrs` | `:2790-2840` |
| `base.cc` | `KVCacheManagerBase::CopyPoolBlocks` (`std::shared_ptr<const PoolStagingLease> lease;` .. `auto slot_it = lease->slot_by_block.find(block_id);`) | `:2939-2970` |
| `base.cc` | `KVCacheManagerBase::GetBlockChunks` (`std::shared_ptr<const PoolStagingLease> staging_lease;` .. `const auto block_host_base =`) | `:3435-3495` |
| `tpu_sync/kv_cache/transfer_plan.cc` | `TransferPlan::ResolvePlanBlockChunks` (`.raddr = RemoteAddress(dst_addrs, entry.dst_shard_idx(),`) | `:398-400` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` | `:776-825` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` (`if (!pending_pool_reshard_recvs_.insert(plan.uuid()).second)`) | `:794-797` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` (`absl::Cleanup clear_pending = [this, uuid = plan.uuid()]() {`) | `:807-810` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`std::erase_if(retired_uuids,` .. `pending_pool_reshard_recvs_.contains(uuid);`) | `:1106-1109` |
| `reshard_recv.cc` | `ReshardReceiveSession` (`~ReshardReceiveSession() override { ReleaseStaging(); }`) | `:88` |
| `reshard_recv.cc` | `CreateReshardReceiveSession` | `:519-553` |
| `reshard_recv.cc` | `CreateReshardReceiveSession` (`auto session =` .. `return session;`) | `:545-552` |
| `reshard_recv.cc` | `ReshardReceiveSession::AcquireStagingLeases` | `:581-620` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReleaseStagingLocked` | `:622-627` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReleaseStaging` | `:629-632` |
| `pool_staging_test.cc` | `PoolStagingTest.BoundedArenaLeasesAndAddressing` | `:246-342` |
| `pool_staging_test.cc` | `PoolStagingTest.FallsBackToFullMirrorWithoutHintsOrLeases` | `:346-369` |
| `pool_staging_test.cc` | `PoolStagingTest.SmallPoolIdentitySharedStorageAndStrideMismatch` | `:374-438` |
| `pool_staging_test.cc` | `PoolStagingTest.SenderRaddrMatchesReceiverPointer` | `:443-557` |
| `pool_staging_test.cc` | `PoolStagingTest.SenderRaddrUsesReceiverLeaseSlot` | `:560-629` |
| `pool_staging_test.cc` | `PoolStagingTest.PoolHostBaseAddrs` | `:634-666` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.DuplicatePoolRecvRegistrationKeepsOriginalStagingLease` | `:713-763` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.ConcurrentDuplicatePoolRecvRegistrationKeepsWinnerStagingLease` | `:765-821` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.StagingAcquireFailureReleasesUuidClaim` | `:823-853` |
<!-- source-map:end -->
-/
