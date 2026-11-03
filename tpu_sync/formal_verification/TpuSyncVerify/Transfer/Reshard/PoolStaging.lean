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
`reshard_recv.h`/`reshard_recv.cc` are
`tpu_sync/kv_cache/reshard_receive_session.{h,cc}`; `pool_reshard_test.cc` is
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
     `ReshardReceiveSession::Create`, `ReshardReceiveSession::AcquireStagingLeases`, `ReshardReceiveSession::ReleaseStaging` in `reshard_recv.cc`):**
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
     - Phase 2 (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv` calling `ReshardReceiveSession::Create` and `ReshardReceiveSession::AcquireStagingLeases`): constructs `ReshardReceiveSession`
       and calls `AcquireStagingLeases(plan)`,
       which sets `staging_released_ = false` and calls
       `base_->AcquirePoolStagingLease(uuid(), ...)`. On failure,
       `Create` calls `session->ReleaseStaging()` (`ReleaseStagingLocked`) while
       `uuid` is still claimed, and the `absl::Cleanup clear_pending` of
       `PoolReshardRegisterRecv` drops the claim afterwards.
     - Phase 3 (`KVCacheManagerWithTransfer::PoolReshardRegisterRecv`, `sessions_[plan.uuid()] = recv_session;` under `mu_`):
       drops the pending claim and inserts the session into `sessions_` in one
       scope (and, for a sub-plan of a chained request, records it in the
       request's `recv_chains_` entry, `NoteSubPlanRegisteredLocked`).
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
     (`ReshardReceiveSession::~ReshardReceiveSession` in `reshard_recv.h`, `ReshardReceiveSession::ReleaseStagingLocked` and `ReshardReceiveSession::ReleaseStaging` in `reshard_recv.cc`),
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
| `base.h` | `PoolStagingLease` | `:918-921` |
| `base.h` | `PoolStagingStorage` | `:922-930` |
| `base.cc` | `RemoteAddress` | `:120-141` |
| `base.cc` | `KVCacheManagerBase::ConfigurePoolStaging` | `:2036-2149` |
| `base.cc` | `KVCacheManagerBase::PoolStagingLeaseSnapshot` | `:2157-2168` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` | `:2170-2227` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` (`std::vector<int64_t> missing;` .. `if (missing.empty())`) | `:2181-2195` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` (`if (static_cast<int64_t>(missing.size()) > st.num_slots)` .. `while (st.free_slots.size() < missing.size())`) | `:2198-2206` |
| `base.cc` | `KVCacheManagerBase::AcquirePoolStagingLease` (`auto lease = std::make_shared<PoolStagingLease>();` .. `st.leases[uuid] = std::move(lease);`) | `:2215-2225` |
| `base.cc` | `KVCacheManagerBase::ReleasePoolStagingLeases` | `:2229-2245` |
| `base.cc` | `KVCacheManagerBase::PoolBlockHostBase` | `:2269-2314` |
| `base.cc` | `KVCacheManagerBase::PoolHostBaseAddrs` | `:2436-2486` |
| `base.cc` | `KVCacheManagerBase::CopyPoolBlocks` (`std::shared_ptr<const PoolStagingLease> lease;` .. `auto slot_it = lease->slot_by_block.find(block_id);`) | `:2585-2616` |
| `base.cc` | `KVCacheManagerBase::GetBlockChunks` (`std::shared_ptr<const PoolStagingLease> staging_lease;` .. `const auto block_host_base =`) | `:3123-3183` |
| `tpu_sync/kv_cache/transfer_plan.cc` | `TransferPlan::ResolvePlanBlockChunks` (`.raddr = RemoteAddress(dst_addrs, entry.dst_shard_idx(),`) | `:398-400` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` | `:726-774` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` (`if (!pending_pool_reshard_recvs_.insert(plan.uuid()).second)`) | `:744-747` |
| `mgr.cc` | `KVCacheManagerWithTransfer::PoolReshardRegisterRecv` (`absl::Cleanup clear_pending = [this, uuid = plan.uuid()]() {`) | `:757-760` |
| `mgr.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`std::erase_if(retired_uuids,` .. `pending_pool_reshard_recvs_.contains(uuid);`) | `:1046-1049` |
| `reshard_recv.h` | `ReshardReceiveSession` (`~ReshardReceiveSession() override`) | `:71` |
| `reshard_recv.cc` | `ReshardReceiveSession::Create` | `:353-387` |
| `reshard_recv.cc` | `ReshardReceiveSession::Create` (`auto session =` .. `return session;`) | `:379-386` |
| `reshard_recv.cc` | `ReshardReceiveSession::AcquireStagingLeases` | `:415-454` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReleaseStagingLocked` | `:456-461` |
| `reshard_recv.cc` | `ReshardReceiveSession::ReleaseStaging` | `:463-466` |
| `pool_staging_test.cc` | `PoolStagingTest.BoundedArenaLeasesAndAddressing` | `:153-248` |
| `pool_staging_test.cc` | `PoolStagingTest.FallsBackToFullMirrorWithoutHintsOrLeases` | `:252-275` |
| `pool_staging_test.cc` | `PoolStagingTest.SmallPoolIdentitySharedStorageAndStrideMismatch` | `:280-344` |
| `pool_staging_test.cc` | `PoolStagingTest.SenderRaddrMatchesReceiverPointer` | `:349-463` |
| `pool_staging_test.cc` | `PoolStagingTest.SenderRaddrUsesReceiverLeaseSlot` | `:466-535` |
| `pool_staging_test.cc` | `PoolStagingTest.PoolHostBaseAddrs` | `:540-572` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.DuplicatePoolRecvRegistrationKeepsOriginalStagingLease` | `:671-721` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.ConcurrentDuplicatePoolRecvRegistrationKeepsWinnerStagingLease` | `:723-779` |
| `pool_reshard_test.cc` | `PoolStagingRecvRegistrationTest.StagingAcquireFailureReleasesUuidClaim` | `:781-811` |
<!-- source-map:end -->
-/
