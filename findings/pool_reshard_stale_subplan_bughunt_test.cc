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

// Hardware-free reproduction for the F13 follow-up at tpu-sync 00e946e3:
// after 25f7d8a7 ("Track reshard sub-plan sessions in
// KVCacheManagerWithTransfer") a pool-reshard session that was registered as
// part of a sub-plan chain can be reported as if it were a single-plan
// request, because chain membership now lives only in `sub_plan_chains_` and
// that entry can disappear while a member session is still alive.
//
// Chain of facts at 00e946e3 (tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc):
//   * NoteSubPlanRegisteredLocked erases `sub_plan_chains_[req_id]` whenever a
//     plan with `sub_plan_count <= 1` registers under `req_id`.
//   * RecordPoolReshardTerminalLocked treats `sub_plan_chains_.find(req_id) ==
//     end()` as "a single-plan request: the session's terminal is the
//     request's" and inserts `req_id` into done_recving_ / failed_recving_
//     immediately. The settling session's own sub_plan_count is no longer
//     consulted (25f7d8a7 removed sub_plan_index()/sub_plan_count() from the
//     reshard sessions).
//   * SweepSubPlanChainsLocked erases a `failed || completed` entry once
//     `timeout_s_` has passed since `last_activity`, without checking whether
//     any `sub_sessions` member is still `!Done()`. A session is Done only
//     when `in_flight_ == 0`, which a late copy or push callback decides, not
//     the deadline: the deadline pass only calls Finish(DEADLINE_EXCEEDED).
//
// Harness: upstream's own CPU harness from
// kv_cache_manager_with_transfer_pool_reshard_test.cc (FakeH2dBase +
// TestManager + ChainedRecvPlan), unchanged. Sub-plans are registered through
// the public PoolReshardRegisterRecv and settled through the session's public
// interface (ResolveStagingSlot / OnDataReceived, or TryBeginOp / Finish /
// EndOp for an op held in flight). Reporting runs through the production
// CompleteReadRaw / CompleteReadWithDetails.
//
// The Control* tests pass on unmodified 00e946e3 (the harness works and the
// chain-to-chain retry upstream already covers is fine). The other four
// assert the expected contract (a stale sub-plan of a failed chain never
// reports a terminal for the req_id) and therefore FAIL on unmodified
// 00e946e3.

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/base/thread_annotations.h"
#include "absl/container/flat_hash_map.h"
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/status/statusor.h"
#include "absl/synchronization/mutex.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"
#include "absl/types/span.h"
#include "xla/future.h"
#include "tpu_sync/core/raw_transfer_core.h"
#include "tpu_sync/kv_cache/kv_cache_manager_base.h"
#include "tpu_sync/kv_cache/kv_cache_manager_with_transfer.h"
#include "tpu_sync/kv_cache/pool_layout.h"
#include "tpu_sync/rpc/raiden_service.pb.h"
#include "tpu_sync/transport/transfer_session.h"

namespace tpu_raiden {
namespace {

using ::testing::Contains;
using ::testing::HasSubstr;
using ::testing::IsEmpty;
using ::tpu_sync::rpc::MEMORY_TYPE_HBM;
using ::tpu_sync::rpc::StartTransferRequest;

// Verbatim from upstream's kv_cache_manager_with_transfer_pool_reshard_test.cc
// at 00e946e3: a CPU-only base whose armed pool upload completes with the
// armed status instead of copying to a device.
class FakeH2dBase : public kv_cache::KVCacheManagerBase {
 public:
  using kv_cache::KVCacheManagerBase::KVCacheManagerBase;

  void ArmPoolUpload(size_t pool_idx, absl::Status status) {
    absl::MutexLock lock(fake_mu_);
    armed_uploads_.insert_or_assign(pool_idx, std::move(status));
  }

  absl::StatusOr<raiden::PjRtCopyFuture> H2dPoolBlocks(
      size_t pool_idx, absl::Span<const int64_t> block_ids,
      std::optional<size_t> shard_idx, std::optional<uint64_t> uuid,
      std::optional<size_t> host_layer_idx) override {
    std::optional<absl::Status> armed;
    {
      absl::MutexLock lock(fake_mu_);
      if (auto it = armed_uploads_.find(pool_idx); it != armed_uploads_.end()) {
        armed = std::move(it->second);
        armed_uploads_.erase(it);
      }
    }
    if (!armed.has_value()) {
      return kv_cache::KVCacheManagerBase::H2dPoolBlocks(
          pool_idx, block_ids, shard_idx, uuid, host_layer_idx);
    }
    auto [promise, future] = xla::MakePromise();
    promise.Set(*std::move(armed));
    return raiden::PjRtCopyFuture(std::move(future), raiden::BufferHolders{});
  }

 private:
  absl::Mutex fake_mu_;
  absl::flat_hash_map<size_t, absl::Status> armed_uploads_
      ABSL_GUARDED_BY(fake_mu_);
};

class TestManager : public KVCacheManagerWithTransfer {
 public:
  explicit TestManager(double timeout_s = 30.0)
      : KVCacheManagerWithTransfer(
            std::make_unique<FakeH2dBase>(
                /*num_layers=*/1, /*num_shards=*/1,
                /*slice_byte_sizes=*/std::vector<size_t>{128},
                /*local_port=*/std::nullopt,
                /*host_blocks_to_allocate=*/std::make_optional(4),
                /*parallelism=*/1, /*host_allocator=*/nullptr),
            /*node_id=*/0, /*local_control_port=*/-1, /*max_blocks=*/0,
            /*num_slots=*/0, timeout_s) {}

  // Lands pool `pool_idx` of pool-reshard receive `uuid` and completes its
  // upload with `status`, as the transport and the device copy would.
  void FinishPoolReshardRecvPool(uint64_t uuid, size_t pool_idx,
                                 const absl::Status& status) {
    absl::StatusOr<std::shared_ptr<TransferSession>> session = GetSession(uuid);
    ABSL_ASSERT_OK(session);
    static_cast<FakeH2dBase&>(*base_).ArmPoolUpload(pool_idx, status);
    ABSL_ASSERT_OK((*session)->ResolveStagingSlot(pool_idx));
    ABSL_ASSERT_OK((*session)->OnDataReceived(
        pool_idx, /*minor_dimension_indices=*/{}, /*shard_ids=*/{}));
  }
  using KVCacheManagerWithTransfer::PoolReshardRegisterRecv;

  void AttachPlaceholderDeviceHold() {
    base()->AttachPlaceholderDeviceHoldForTest();
  }
};

kv_cache::PoolSpec DensePool(std::string tag, int64_t block_stride = 128,
                             std::string dtype_tag = "bf16") {
  return kv_cache::PoolSpec{
      .tag = std::move(tag),
      .storage_index = 0,
      .base_offset_bytes = 0,
      .block_stride_bytes = block_stride,
      .num_blocks = 4,
      .regions = {kv_cache::RegionSpec{
          .name = "block",
          .offset_bytes = 0,
          .stride_bytes = block_stride,
          .unit_bytes = block_stride,
          .num_units = 1,
          .units_per_stride = 1,
      }},
      .dtype_tag = std::move(dtype_tag),
  };
}

StartTransferRequest ValidPlan(int64_t uuid) {
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
  auto* entry = (*plan.mutable_shard_push_schedules())[0].add_entries();
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
  return plan;
}

constexpr char kReqId[] = "chained_req";

// Sub-plan `index` of a `count`-window chain for kReqId, landing destination
// block `index` (upstream's ChainedRecvPlan).
StartTransferRequest ChainedRecvPlan(int64_t uuid, int32_t index,
                                     int32_t count) {
  StartTransferRequest plan = ValidPlan(uuid);
  plan.set_req_id(kReqId);
  plan.set_sub_plan_index(index);
  plan.set_sub_plan_count(count);
  plan.mutable_pool_groups(0)->set_dst_device_block_ids(0, index);
  (*plan.mutable_shard_push_schedules())[0]
      .mutable_entries(0)
      ->set_dst_block_id(index);
  return plan;
}

// A single-plan retry of kReqId (sub_plan_count 0, i.e. "the whole request")
// landing destination block `dst_block`.
StartTransferRequest SinglePlanRetry(int64_t uuid, int32_t dst_block) {
  StartTransferRequest plan = ValidPlan(uuid);
  plan.set_req_id(kReqId);
  plan.mutable_pool_groups(0)->set_dst_device_block_ids(0, dst_block);
  (*plan.mutable_shard_push_schedules())[0]
      .mutable_entries(0)
      ->set_dst_block_id(dst_block);
  return plan;
}

// Starts a two-window chain for kReqId, fails sub-plan 0 (uuid `failed_uuid`,
// reported on the next poll) and leaves sub-plan 1 (uuid `stale_uuid`) in
// flight: the F13 shape.
void StartChainAndFailFirstWindow(TestManager& manager, int64_t failed_uuid,
                                  int64_t stale_uuid) {
  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      ChainedRecvPlan(failed_uuid, /*index=*/0, /*count=*/2),
      std::vector<int64_t>{0}));
  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      ChainedRecvPlan(stale_uuid, /*index=*/1, /*count=*/2),
      std::vector<int64_t>{1}));
  manager.FinishPoolReshardRecvPool(failed_uuid, /*pool_idx=*/0,
                                    absl::InternalError("push failed"));
  const auto [sent, received, failed] = manager.CompleteReadRaw();
  ASSERT_THAT(failed, Contains(kReqId));
  ASSERT_THAT(received, IsEmpty());
}

// --- Case 1: single-plan retry under the same req_id ------------------------

// Control: a single-plan retry with no stale sub-plan behind it reports once,
// on its own terminal.
TEST(StaleSubPlanBughunt, ControlSinglePlanRetryAloneReportsOnItsOwnTerminal) {
  TestManager manager;
  ASSERT_TRUE(manager.base()->RegisterPools({DensePool("fa")}).ok());
  manager.AttachPlaceholderDeviceHold();

  // A two-window chain whose both windows fail: nothing is left in flight.
  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      ChainedRecvPlan(6001, /*index=*/0, /*count=*/2), std::vector<int64_t>{0}));
  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      ChainedRecvPlan(6002, /*index=*/1, /*count=*/2), std::vector<int64_t>{1}));
  manager.FinishPoolReshardRecvPool(6001, 0, absl::InternalError("push failed"));
  manager.FinishPoolReshardRecvPool(6002, 0, absl::InternalError("push failed"));
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    ASSERT_THAT(failed, Contains(kReqId));
  }

  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(SinglePlanRetry(7001, 0),
                                                 std::vector<int64_t>{0}));
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(received, IsEmpty());
    EXPECT_THAT(failed, IsEmpty());
  }
  manager.FinishPoolReshardRecvPool(7001, 0, absl::OkStatus());
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(received, Contains(kReqId));
    EXPECT_THAT(failed, IsEmpty());
  }
}

// A stale sub-plan of the failed chain settling OK must not complete the
// single-plan retry that has not received anything yet.
TEST(StaleSubPlanBughunt,
     StaleSubPlanSettlingOkCompletesTheSinglePlanRetryEarly) {
  TestManager manager;
  ASSERT_TRUE(manager.base()->RegisterPools({DensePool("fa")}).ok());
  manager.AttachPlaceholderDeviceHold();
  StartChainAndFailFirstWindow(manager, /*failed_uuid=*/6001,
                               /*stale_uuid=*/6002);

  // The consumer retries under the same req_id as one window. Registering
  // it erases sub_plan_chains_[kReqId].
  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(SinglePlanRetry(7001, 0),
                                                 std::vector<int64_t>{0}));

  // The stale window lands. Expected: swallowed (the request it belonged to
  // was already failed). Actual on 00e946e3: reported as the retry's
  // done_recving before the retry has moved a byte.
  manager.FinishPoolReshardRecvPool(6002, 0, absl::OkStatus());
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(received, IsEmpty())
        << "stale sub-plan 6002 reported done_recving for the retry";
    EXPECT_THAT(failed, IsEmpty());
  }

  // The retry itself must still report exactly once when it lands.
  manager.FinishPoolReshardRecvPool(7001, 0, absl::OkStatus());
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(received, Contains(kReqId));
    EXPECT_THAT(failed, IsEmpty());
  }
}

// A stale sub-plan of the failed chain settling with an error must not fail
// the single-plan retry.
TEST(StaleSubPlanBughunt, StaleSubPlanSettlingFailedFailsTheSinglePlanRetry) {
  TestManager manager;
  ASSERT_TRUE(manager.base()->RegisterPools({DensePool("fa")}).ok());
  manager.AttachPlaceholderDeviceHold();
  StartChainAndFailFirstWindow(manager, /*failed_uuid=*/6001,
                               /*stale_uuid=*/6002);

  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(SinglePlanRetry(7001, 0),
                                                 std::vector<int64_t>{0}));
  manager.FinishPoolReshardRecvPool(6002, 0,
                                    absl::InternalError("late push failed"));
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(failed, IsEmpty())
        << "stale sub-plan 6002 reported failed_recving for the retry";
    EXPECT_THAT(received, IsEmpty());
  }
  manager.FinishPoolReshardRecvPool(7001, 0, absl::OkStatus());
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(received, Contains(kReqId));
    EXPECT_THAT(failed, IsEmpty());
  }
}

// --- Case 2: tombstone swept while a sub-plan is still draining -------------

// Control: the chain-to-chain retry upstream covers
// (RetryUnderTheSameReqIdIsTrackedAsANewChain) keeps an anchored entry, so a
// stale sub-plan settling after the sweep interval is still swallowed.
TEST(StaleSubPlanBughunt, ControlChainRetryKeepsAnAnchoredEntry) {
  TestManager manager(/*timeout_s=*/0.05);
  ASSERT_TRUE(manager.base()->RegisterPools({DensePool("fa")}).ok());
  manager.AttachPlaceholderDeviceHold();
  StartChainAndFailFirstWindow(manager, /*failed_uuid=*/6001,
                               /*stale_uuid=*/6002);
  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      ChainedRecvPlan(7001, /*index=*/0, /*count=*/2), std::vector<int64_t>{0}));

  // Both the stale window and the retry's first window hold an op in flight
  // across the sweep interval, so neither retires at its deadline.
  absl::StatusOr<std::shared_ptr<TransferSession>> stale_session =
      manager.GetSession(6002);
  ABSL_ASSERT_OK(stale_session);
  std::shared_ptr<TransferSession> stale = *stale_session;
  ASSERT_TRUE(stale->TryBeginOp());
  absl::StatusOr<std::shared_ptr<TransferSession>> retry_session =
      manager.GetSession(7001);
  ABSL_ASSERT_OK(retry_session);
  std::shared_ptr<TransferSession> retry = *retry_session;
  ASSERT_TRUE(retry->TryBeginOp());
  absl::SleepFor(absl::Milliseconds(120));
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(received, IsEmpty());
    EXPECT_THAT(failed, IsEmpty());
  }
  // The stale window retires into the retry's anchored entry and is ignored.
  stale->EndOp();
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(received, IsEmpty());
    EXPECT_THAT(failed, IsEmpty());
  }
  retry->EndOp();
}

// A sub-plan still draining an in-flight op when the failed chain's entry is
// swept retires into a missing entry and re-reports the already-failed
// req_id (with the deadline error the sweep pass latched).
TEST(StaleSubPlanBughunt, SweptChainReportsADrainingSubPlanAsASecondFailure) {
  TestManager manager(/*timeout_s=*/0.05);
  ASSERT_TRUE(manager.base()->RegisterPools({DensePool("fa")}).ok());
  manager.AttachPlaceholderDeviceHold();
  StartChainAndFailFirstWindow(manager, /*failed_uuid=*/6001,
                               /*stale_uuid=*/6002);

  // Sub-plan 1 holds one op in flight (a push or copy still running).
  absl::StatusOr<std::shared_ptr<TransferSession>> stale_session =
      manager.GetSession(6002);
  ABSL_ASSERT_OK(stale_session);
  std::shared_ptr<TransferSession> stale = *stale_session;
  ASSERT_TRUE(stale->TryBeginOp());

  // One transfer timeout later the deadline pass marks the session draining
  // (not Done: the op is still in flight) and the sweep erases the failed
  // entry.
  absl::SleepFor(absl::Milliseconds(120));
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(received, IsEmpty());
    EXPECT_THAT(failed, IsEmpty());
  }
  EXPECT_TRUE(stale->IsDraining());
  EXPECT_FALSE(stale->Done());

  // The op ends; the session retires. Expected: nothing, the request was
  // reported failed one timeout ago. Actual on 00e946e3: a second
  // failed_recving for kReqId.
  stale->EndOp();
  ASSERT_TRUE(stale->Done());
  CompleteReadResult late = manager.CompleteReadWithDetails();
  EXPECT_THAT(late.failed, IsEmpty())
      << "already-failed request reported failed again: "
      << (late.details.contains(kReqId)
              ? late.details.at(kReqId).reason.value_or("")
              : std::string("<no details>"));
  EXPECT_THAT(late.received, IsEmpty());
}

// Same sweep, but the draining sub-plan had already latched OkStatus() (all
// its pushes landed; a copy is still in flight): it retires into the missing
// entry as done_recving, so a request the consumer already saw fail is now
// also reported as received.
TEST(StaleSubPlanBughunt, SweptChainReportsADrainingOkSubPlanAsReceived) {
  TestManager manager(/*timeout_s=*/0.05);
  ASSERT_TRUE(manager.base()->RegisterPools({DensePool("fa")}).ok());
  manager.AttachPlaceholderDeviceHold();
  StartChainAndFailFirstWindow(manager, /*failed_uuid=*/6001,
                               /*stale_uuid=*/6002);

  absl::StatusOr<std::shared_ptr<TransferSession>> stale_session =
      manager.GetSession(6002);
  ABSL_ASSERT_OK(stale_session);
  std::shared_ptr<TransferSession> stale = *stale_session;
  ASSERT_TRUE(stale->TryBeginOp());
  stale->Finish();  // OK, before the deadline pass can latch an error.
  ASSERT_TRUE(stale->IsDraining());
  ASSERT_FALSE(stale->Done());

  absl::SleepFor(absl::Milliseconds(120));
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(received, IsEmpty());
    EXPECT_THAT(failed, IsEmpty());
  }

  stale->EndOp();
  ASSERT_TRUE(stale->Done());
  ABSL_EXPECT_OK(stale->GetStatus());
  {
    const auto [sent, received, failed] = manager.CompleteReadRaw();
    EXPECT_THAT(received, IsEmpty())
        << "already-failed request reported as received";
    EXPECT_THAT(failed, IsEmpty());
  }
}

}  // namespace
}  // namespace tpu_raiden
