// Copyright 2026 Google LLC.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Bug-hunt reproducer: a pool-reshard receiver leases one StagingLayerManager
// slot per *pool* (ReshardReceiveSession::AcquireStagingSlot, reached from
// KVCacheManagerBase::GetBlockChunks through TransferSession::ResolveStagingSlot
// on the push thread) out of KVCacheManagerBase::num_host_layers() slots, holds
// it until the pool's H2D completes, and gates a higher-rank pool's H2D behind
// every lower-rank pool (CollectEligiblePoolH2dsLocked). When the pools of one
// plan outnumber the host layer buffers, a higher-rank pool whose bytes arrive
// first can hold the last slot while a lower-rank pool blocks in
// StagingLayerManager::Acquire until the session deadline: the receive stalls
// for timeout_s_ and then fails DEADLINE_EXCEEDED, and the transport reader
// thread carrying the lower-rank pool's stream is parked for that long.
//
// Copy next to kv_cache_manager_with_transfer_pool_reshard_test.cc, apply
// findings/build_targets.patch, and run
//   bazel test --config=oss //tpu_sync/kv_cache:reshard_recv_staging_slot_rank_deadlock_bughunt_test

#include <chrono>  // NOLINT(build/c++11)
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <thread>  // NOLINT(build/c++11)
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"
#include "tpu_sync/kv_cache/kv_cache_manager_base.h"
#include "tpu_sync/kv_cache/kv_cache_manager_with_transfer.h"
#include "tpu_sync/kv_cache/pool_layout.h"
#include "tpu_sync/kv_cache/reshard_receive_session.h"
#include "tpu_sync/rpc/raiden_service.pb.h"
#include "tpu_sync/transport/transfer_session.h"

namespace tpu_raiden {
namespace {

using ::absl_testing::StatusIs;
using ::testing::Contains;
using ::testing::IsEmpty;
using ::tpu_sync::rpc::MEMORY_TYPE_HBM;
using ::tpu_sync::rpc::StartTransferRequest;

constexpr int64_t kStride = 128;
constexpr int64_t kNumBlocks = 16;
constexpr double kTimeoutS = 2.0;

// One device storage with `num_host_layers` host layer buffers, so the
// receiver has exactly that many staging slots for the pools of a plan (the
// test base never issues a device copy: the defect is reached before any H2D).
class DeviceBackedBase : public kv_cache::KVCacheManagerBase {
 public:
  explicit DeviceBackedBase(size_t num_host_layers)
      : KVCacheManagerBase(/*num_layers=*/num_host_layers, /*num_shards=*/1,
                           kStride, /*local_port=*/std::nullopt,
                           std::make_optional<int>(1)) {
    buffer_holds_.resize(num_host_layers);
    major_dim_size_ = num_host_layers;
    for (size_t i = 0; i < num_host_layers; ++i) {
      buffer_holds_[i].holds.resize(1);
      buffer_holds_[i].physical_size = kStride * kNumBlocks;
      layers_[i].shards[0].device_size = kStride * kNumBlocks;
    }
  }
};

class SlotManager : public KVCacheManagerWithTransfer {
 public:
  explicit SlotManager(size_t num_host_layers)
      : KVCacheManagerWithTransfer(
            std::make_unique<DeviceBackedBase>(num_host_layers),
            /*node_id=*/0, /*local_control_port=*/-1, /*max_blocks=*/0,
            /*num_slots=*/0, kTimeoutS) {}
  using KVCacheManagerWithTransfer::PoolReshardRegisterRecv;
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
      .staging_blocks_per_request = 1,
  };
}

// Two pools on storage 0 landing the same device block (the aliased-page
// shape that order_rank exists for), one group per pool.
StartTransferRequest TwoPoolPlan(int64_t uuid, int32_t rank_0, int32_t rank_1) {
  StartTransferRequest plan;
  plan.set_uuid(uuid);
  plan.set_req_id("pool_reshard_req_" + std::to_string(uuid));
  plan.set_dst_mem_type(MEMORY_TYPE_HBM);
  plan.set_use_block_chunks(true);
  plan.set_parallelism(1);
  plan.add_transfer_pool_indices(0);
  plan.add_transfer_pool_indices(1);
  plan.add_pool_dtype_tags("bf16");
  plan.add_pool_dtype_tags("bf16");
  for (int group_idx = 0; group_idx < 2; ++group_idx) {
    auto* group = plan.add_pool_groups();
    group->add_pool_indices(group_idx);
    group->set_order_rank(group_idx == 0 ? rank_0 : rank_1);
    group->add_dst_device_block_ids(0);
    group->set_expected_pushes(1);
    group->add_dst_expected_extent_bytes(16);
    auto* entry = (*plan.mutable_shard_push_schedules())[0].add_entries();
    entry->set_pool_group(group_idx);
    entry->set_dst_peer("127.0.0.1:1");
    entry->set_dst_shard_idx(0);
    entry->set_src_block_id(0);
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

// The first chunk of a pool's push stream: GetBlockChunks resolves the pool's
// host bytes, which leases the pool's staging slot (and blocks while every
// slot is leased).
size_t PushFirstChunk(SlotManager& manager, size_t pool_idx, uint64_t uuid) {
  return manager.base()
      ->GetBlockChunks(/*layer_idx=*/pool_idx, /*shard_idx=*/0,
                       std::vector<int64_t>{0}, /*total_bytes=*/16, uuid,
                       /*sender_node_id=*/0)
      .size();
}

// The end of a pool's push stream: the transport reports a unit completion
// (KVCacheManagerBase::OnLayerReceived, the pool index as the major dimension),
// which the session takes as the pool's wire completion
// (TransferSession::OnDataReceived with no minor indices) and records it,
// launching the pool's H2D only once every lower-rank pool has completed.
absl::Status PoolStreamComplete(SlotManager& manager, size_t pool_idx,
                                uint64_t uuid) {
  return manager.base()->OnLayerReceived(/*layer_idx=*/pool_idx, uuid);
}

void RegisterTwoPools(SlotManager& manager) {
  ABSL_ASSERT_OK(manager.base()->RegisterPools(
      {DensePool("fa"), DensePool("swa")}, /*staging_leases=*/2));
}

// Control: the same arrival order with as many host layer buffers as pools.
// The rank-1 pool holds one slot, the rank-0 pool's first chunk takes the
// other at once; nothing waits.
TEST(ReshardRecvStagingSlotRankDeadlock,
     Control_OneSlotPerPoolResolvesTheLowerRankPoolAtOnce) {
  SlotManager manager(/*num_host_layers=*/2);
  RegisterTwoPools(manager);
  ASSERT_EQ(manager.base()->num_host_layers(), 2u);
  constexpr uint64_t kUuid = 5102;
  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      TwoPoolPlan(kUuid, /*rank_0=*/0, /*rank_1=*/1),
      std::vector<int64_t>{0, 0}));

  ASSERT_EQ(PushFirstChunk(manager, /*pool_idx=*/1, kUuid), 1u);
  ABSL_ASSERT_OK(PoolStreamComplete(manager, /*pool_idx=*/1, kUuid));

  const absl::Time t0 = absl::Now();
  EXPECT_EQ(PushFirstChunk(manager, /*pool_idx=*/0, kUuid), 1u);
  EXPECT_LT(absl::Now() - t0, absl::Seconds(kTimeoutS / 2));

  auto session_or = manager.base()->GetSession(kUuid);
  ASSERT_TRUE(session_or.ok()) << session_or.status();
  EXPECT_FALSE((*session_or)->IsDraining());
  ABSL_EXPECT_OK((*session_or)->GetStatus());
  const auto [sent, received, failed] = manager.CompleteReadRaw();
  EXPECT_THAT(failed, IsEmpty());
}

// The defect: ranks [0, 1], the rank-1 pool's bytes arrive first and take the
// only slot; its H2D is gated behind the rank-0 pool, whose first chunk then
// blocks in StagingLayerManager::Acquire. Nothing can free the slot, so the
// rank-0 push thread is parked until deadline_ and the receive fails
// DEADLINE_EXCEEDED although every byte of both pools was on its way.
TEST(ReshardRecvStagingSlotRankDeadlock,
     LowerRankPoolResolvesWhileHigherRankPoolHoldsTheLastSlot) {
  SlotManager manager(/*num_host_layers=*/1);
  RegisterTwoPools(manager);
  ASSERT_EQ(manager.base()->num_host_layers(), 1u);
  constexpr uint64_t kUuid = 5103;
  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      TwoPoolPlan(kUuid, /*rank_0=*/0, /*rank_1=*/1),
      std::vector<int64_t>{0, 0}));

  // Rank-1 pool: first chunk leases the slot, its stream completes, its H2D
  // is held back by the rank gate (rank-0 pool not complete).
  ASSERT_EQ(PushFirstChunk(manager, /*pool_idx=*/1, kUuid), 1u);
  ABSL_ASSERT_OK(PoolStreamComplete(manager, /*pool_idx=*/1, kUuid));

  // Rank-0 pool: its first chunk needs the slot the rank-1 pool holds.
  size_t rank0_chunks = 99;
  absl::Duration blocked;
  std::thread rank0_push([&]() {
    const absl::Time t0 = absl::Now();
    rank0_chunks = PushFirstChunk(manager, /*pool_idx=*/0, kUuid);
    blocked = absl::Now() - t0;
  });

  // Meanwhile the receive is alive and reports nothing.
  absl::SleepFor(absl::Milliseconds(300));
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(received, IsEmpty());
    EXPECT_THAT(failed, IsEmpty());
  }
  rank0_push.join();

  // Written so that a failure shows the defect: both pools' bytes were
  // available at t=0, so the rank-0 chunk must resolve promptly and the
  // receive must not fail.
  EXPECT_EQ(rank0_chunks, 1u)
      << "[F15] rank-0 pool's first chunk resolved to no host bytes after "
      << blocked << " (the rank-1 pool holds the only staging slot)";
  EXPECT_LT(blocked, absl::Seconds(kTimeoutS / 2))
      << "[F15] rank-0 push thread was parked in StagingLayerManager::Acquire "
         "for " << blocked << " (timeout_s=" << kTimeoutS << ")";

  auto session_or = manager.base()->GetSession(kUuid);
  ASSERT_TRUE(session_or.ok()) << session_or.status();
  std::shared_ptr<TransferSession> session = *session_or;
  EXPECT_FALSE(session->IsDraining())
      << "[F15] receive is draining with status " << session->GetStatus();
  ABSL_EXPECT_OK(session->GetStatus());
  session->AwaitForDone().IgnoreError();
  const auto [sent, received, failed] = manager.CompleteReadRaw();
  EXPECT_THAT(failed, IsEmpty())
      << "[F15] receive with every byte of both pools on its way failed at "
         "the deadline";
}

}  // namespace
}  // namespace tpu_raiden
