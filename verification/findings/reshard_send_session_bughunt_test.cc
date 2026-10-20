// Hardware-free reproduction for R6 (docs/transfer/reshard.md):
// ReshardSendSession::RecordPushCompletion unregisters the active plan on the
// FIRST failed push, while sibling pushes of the same session are still in
// flight (reshard_send_session.cc:351-392 at 0ac16d1; EndOp at :418-440 would
// unregister at settle anyway).
//
// Consequences shown here, in order:
//   1. The plan is gone while the session still has an op in flight
//      (HasActivePlan(uuid) == false, in_flight_ == 1, !Done()).
//   2. A sibling push that resolves its chunks after that point finds none
//      (GetBlockChunks(uuid) is empty) -- on bounded staging its request build
//      fails NOT_FOUND; on full-mirror storages the same call falls back to
//      un-sliced full-block extents (kv_cache_manager_base.cc:3306-3325).
//   3. Because the plan is unregistered, a retry of the SAME uuid is accepted
//      by ReshardSendSession::Create (RegisterActivePlanDirect no longer
//      refuses it) while the failed session is still draining. The retry's
//      AcquirePoolStagingLease(uuid) is idempotent per uuid and therefore
//      SHARES the draining session's slot. When the draining session finally
//      settles, ReleaseLeasesLocked -> ReleasePoolStagingLeases(uuid) frees
//      that slot under the retry: the retry's chunks vanish, and a third
//      transfer is leased the same physical slot. This is the F6 shape
//      (fixed on the receiver in 8653373 by registering the plan before
//      leasing) reopened on the sender by the early unregister.
//
// Uses the ReshardSendSessionTestPeer friend seam declared in
// reshard_send_session.h to drive the session's op accounting without a
// device or a network (ExecutePush needs real D2H copies).

#include <chrono>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/status/statusor.h"
#include "absl/synchronization/mutex.h"
#include "absl/time/time.h"
#include "tpu_sync/kv_cache/kv_cache_manager_base.h"
#include "tpu_sync/kv_cache/kv_cache_manager_with_transfer.h"
#include "tpu_sync/kv_cache/pool_layout.h"
#include "tpu_sync/kv_cache/reshard_send_session.h"
#include "tpu_sync/rpc/raiden_service.pb.h"
#include "tpu_sync/transport/block_transport.h"

namespace tpu_raiden {

// The friend seam upstream declares for its own reshard_send_session_test.cc.
struct ReshardSendSessionTestPeer {
  // What ExecutePush does before issuing pushes: bind the manager and count
  // `n` ops in flight (one per (pool, peer) push).
  static void BeginOps(ReshardSendSession& s, KVCacheManagerWithTransfer& m,
                       int n) {
    absl::MutexLock lock(s.mu_);
    s.manager_ = &m;
    s.in_flight_ += n;
  }
  static void RecordPushCompletion(ReshardSendSession& s,
                                   KVCacheManagerWithTransfer& m,
                                   const absl::Status& st) {
    s.RecordPushCompletion(m, st);
  }
  static void EndOp(ReshardSendSession& s) { s.EndOp(); }
  static int in_flight(const ReshardSendSession& s) {
    absl::MutexLock lock(s.mu_);
    return s.in_flight_;
  }
};

namespace {

using ::absl_testing::StatusIs;
using ::tpu_sync::rpc::MEMORY_TYPE_HBM;
using ::tpu_sync::rpc::StartTransferRequest;

constexpr int64_t kStride = 128;
constexpr int64_t kNumBlocks = 16;

// Same device-backed, host-only test base upstream uses for its bounded pool
// staging tests (kv_cache_manager_with_transfer_pool_reshard_test.cc): a
// physical_size > 0 makes storage 0 "device-backed", which is what
// RegisterPools(..., staging_leases) requires to carve a bounded arena. No
// path below touches the (empty) hold.
class DeviceBackedTestBase : public kv_cache::KVCacheManagerBase {
 public:
  DeviceBackedTestBase(size_t slice_byte_size, int host_blocks,
                       size_t physical_size)
      : KVCacheManagerBase(/*num_layers=*/1, /*num_shards=*/1, slice_byte_size,
                           /*local_port=*/std::nullopt,
                           std::make_optional(host_blocks)) {
    buffer_holds_.resize(1);
    buffer_holds_[0].holds.resize(1);
    buffer_holds_[0].physical_size = physical_size;
    major_dim_size_ = 1;
    layers_[0].shards[0].device_size = physical_size;
  }
};

class BoundedPoolTestManager : public KVCacheManagerWithTransfer {
 public:
  BoundedPoolTestManager()
      : KVCacheManagerWithTransfer(  // the protected base-injecting ctor
            std::make_unique<DeviceBackedTestBase>(
                kStride, /*host_blocks=*/1, kStride * kNumBlocks),
            /*node_id=*/0, /*local_control_port=*/-1, /*max_blocks=*/0,
            /*num_slots=*/0, /*timeout_s=*/30.0) {}
  // What PoolReshardPush hands to ReshardSendSession::Create.
  StagingBlockAllocator* staging_allocator() { return staging_allocator_.get(); }
};

kv_cache::PoolSpec DensePool(std::string tag) {
  return kv_cache::PoolSpec{
      .tag = std::move(tag),
      .storage_index = 0,
      .base_offset_bytes = 0,
      .block_stride_bytes = kStride,
      .num_blocks = kNumBlocks,
      .regions = {kv_cache::RegionSpec{
          .name = "block",
          .offset_bytes = 0,
          .stride_bytes = kStride,
          .unit_bytes = kStride,
          .num_units = 1,
          .units_per_stride = 1,
      }},
      .dtype_tag = "bf16",
  };
}

// A sender plan for `uuid` pushing source block `src_block` to two peers:
// one (pool, peer) slot per peer, so remaining_pool_peer_pushes == 2.
StartTransferRequest TwoPeerSenderPlan(int64_t uuid, int32_t src_block) {
  StartTransferRequest plan;
  plan.set_uuid(uuid);
  plan.set_req_id("pool_reshard_req_" + std::to_string(uuid));
  plan.set_dst_mem_type(MEMORY_TYPE_HBM);
  plan.set_use_block_chunks(true);
  plan.set_parallelism(1);
  plan.add_transfer_pool_indices(0);
  plan.add_pool_dtype_tags("bf16");
  auto* group = plan.add_pool_groups();
  group->add_pool_indices(0);
  group->add_dst_device_block_ids(0);
  group->set_expected_pushes(1);
  group->add_dst_expected_extent_bytes(16);
  for (const char* peer : {"127.0.0.1:1", "127.0.0.1:2"}) {
    auto* entry = (*plan.mutable_shard_push_schedules())[0].add_entries();
    entry->set_dst_peer(peer);
    entry->set_dst_shard_idx(0);
    entry->set_src_block_id(src_block);
    entry->set_dst_block_id(0);
    entry->set_src_offset_bytes(0);
    entry->set_dst_offset_bytes(0);
    entry->set_size_bytes(16);
    entry->set_src_stride_bytes(0);
    entry->set_dst_stride_bytes(0);
    entry->set_count(1);
  }
  return plan;
}

// What a push to peer 1 resolves at request-build time
// (BlockTransport::BuildBlockRequests -> GetBlockChunks).
std::vector<transport::BlockChunk> ChunksFor(kv_cache::KVCacheManagerBase& base,
                                             int64_t block, uint64_t uuid) {
  return base.GetBlockChunks(/*layer_idx=*/0, /*shard_idx=*/0,
                             std::vector<int64_t>{block},
                             /*total_bytes=*/64, uuid, /*sender_node_id=*/-1,
                             /*peer=*/"127.0.0.1:1");
}

TEST(ReshardSendSessionBughuntTest,
     R6_FirstFailedPushUnregistersPlanWhileSiblingInFlightAndReopensF6) {
  using Peer = ReshardSendSessionTestPeer;
  BoundedPoolTestManager manager;
  kv_cache::KVCacheManagerBase& base = *manager.base();

  kv_cache::PoolSpec pool = DensePool("fa");
  pool.staging_blocks_per_request = 1;
  ABSL_ASSERT_OK(base.RegisterPools({pool}, /*staging_leases=*/2));
  ASSERT_TRUE(base.PoolStorageStagingBounded(0));
  ASSERT_EQ(base.PoolStagingSummary()[0].free_slots, 2);

  constexpr uint64_t kUuid = 6001;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(30);

  // --- Session A: the sender's first attempt. -------------------------------
  // Create registers the plan (RegisterActivePlanDirect); ExecutePush would
  // then lease staging, D2H, and issue one push per peer. We do the lease and
  // the op accounting by hand (no device here).
  absl::StatusOr<std::shared_ptr<ReshardSendSession>> a_or =
      ReshardSendSession::Create(&base, manager.staging_allocator(),
                                 std::vector<int64_t>{0}, /*parallelism=*/1,
                                 deadline, TwoPeerSenderPlan(kUuid, 0));
  ASSERT_TRUE(a_or.ok()) << a_or.status();
  std::shared_ptr<ReshardSendSession> a = *a_or;
  ASSERT_TRUE(base.HasActivePlan(kUuid));
  Peer::BeginOps(*a, manager, /*n=*/2);  // pushes to peer 1 and peer 2
  ABSL_ASSERT_OK(base.AcquirePoolStagingLease(
      kUuid, /*storage_idx=*/0, std::vector<int64_t>{0},
      base.pool_staging_lease_timeout()));
  ASSERT_EQ(base.PoolStagingSummary()[0].free_slots, 1);
  const auto chunks_a = ChunksFor(base, 0, kUuid);
  ASSERT_EQ(chunks_a.size(), 1u);
  const uint8_t* slot_a = chunks_a[0].ptr;
  ASSERT_NE(slot_a, nullptr);

  // --- Push to peer 1 fails; the push to peer 2 is still in flight. ---------
  Peer::RecordPushCompletion(*a, manager,
                             absl::UnavailableError("peer 1 refused"));
  Peer::EndOp(*a);
  EXPECT_EQ(Peer::in_flight(*a), 1);
  EXPECT_FALSE(a->Done());
  EXPECT_TRUE(a->IsDraining());

  // (1) R6: the plan is already gone although peer 2's push is in flight.
  EXPECT_FALSE(base.HasActivePlan(kUuid))
      << "expected (buggy) early unregister; if this holds, R6 is fixed";

  // (2) A sibling resolving its chunks now finds nothing for the uuid.
  EXPECT_TRUE(ChunksFor(base, 0, kUuid).empty());

  // (3) A retry of the same uuid is ACCEPTED while A is still draining. With
  //     the plan still registered (as it would be if the unregister waited
  //     for settle, like EndOp does) this would be ALREADY_EXISTS -- the
  //     guard 8653373 relies on for the receiver.
  absl::StatusOr<std::shared_ptr<ReshardSendSession>> retry =
      ReshardSendSession::Create(&base, manager.staging_allocator(),
                                 std::vector<int64_t>{0}, /*parallelism=*/1,
                                 deadline, TwoPeerSenderPlan(kUuid, 0));
  ASSERT_TRUE(retry.ok()) << retry.status();
  std::shared_ptr<ReshardSendSession> r = *retry;
  Peer::BeginOps(*r, manager, /*n=*/2);
  ABSL_ASSERT_OK(base.AcquirePoolStagingLease(
      kUuid, /*storage_idx=*/0, std::vector<int64_t>{0},
      base.pool_staging_lease_timeout()));
  // The retry did not get a slot of its own: it shares A's (idempotent per
  // uuid), so the free count did not move and its chunk is A's slot.
  EXPECT_EQ(base.PoolStagingSummary()[0].free_slots, 1);
  const auto chunks_r = ChunksFor(base, 0, kUuid);
  ASSERT_EQ(chunks_r.size(), 1u);
  EXPECT_EQ(chunks_r[0].ptr, slot_a);

  // --- A's last push (peer 2) returns; A settles and releases "its" lease. --
  Peer::RecordPushCompletion(*a, manager, absl::OkStatus());  // no-op: finalizing
  Peer::EndOp(*a);
  ASSERT_TRUE(a->Done());

  // The retry is still active, but its staging is gone: the slot is back in
  // the free list and the retry's chunks no longer resolve.
  EXPECT_FALSE(r->Done());
  EXPECT_EQ(base.PoolStagingSummary()[0].free_slots, 2)
      << "A's settle released the slot the retry is using";
  EXPECT_TRUE(ChunksFor(base, 0, kUuid).empty())
      << "the retry's staging vanished under it";

  // A third transfer is now leased the same physical slot: silent aliasing
  // with whatever the retry's pushes are still reading.
  constexpr uint64_t kOtherUuid = 6002;
  absl::StatusOr<std::shared_ptr<ReshardSendSession>> other_or =
      ReshardSendSession::Create(&base, manager.staging_allocator(),
                                 std::vector<int64_t>{5}, /*parallelism=*/1,
                                 deadline, TwoPeerSenderPlan(kOtherUuid, 5));
  ASSERT_TRUE(other_or.ok()) << other_or.status();
  std::shared_ptr<ReshardSendSession> other = *other_or;
  Peer::BeginOps(*other, manager, /*n=*/2);
  ABSL_ASSERT_OK(base.AcquirePoolStagingLease(
      kOtherUuid, /*storage_idx=*/0, std::vector<int64_t>{5},
      base.pool_staging_lease_timeout()));
  const auto chunks_other = ChunksFor(base, 5, kOtherUuid);
  ASSERT_EQ(chunks_other.size(), 1u);
  EXPECT_EQ(chunks_other[0].ptr, slot_a)
      << "third transfer aliases the slot the retry still owns";

  // Drain the remaining sessions so the manager can be torn down.
  for (auto& s : {r, other}) {
    s->Finish(absl::CancelledError("test teardown"));
    Peer::EndOp(*s);
    Peer::EndOp(*s);
    EXPECT_TRUE(s->Done());
  }
}

}  // namespace
}  // namespace tpu_raiden
