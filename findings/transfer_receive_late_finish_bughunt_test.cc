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

// Hardware-free reproduction for F14 (tpu-sync 42dda542):
// TransferReceiveSession::FinishLocked (tpu_sync/kv_cache/
// transfer_receive_session.cc:449-464) and ReshardReceiveSession::FinishLocked
// (tpu_sync/kv_cache/reshard_receive_session.cc:474-484) mutate `status_`
// before checking `draining_` and never check `done_`:
//
//   if (!status.ok() && status_.ok()) {
//     status_ = status;
//     ...
//   }
//   if (draining_) return;
//
// Compare TransferSendSession::FinishLocked (tpu_sync/kv_cache/
// transfer_send_session.cc:247), which begins with:
//
//   if (draining_ || done_) return;
//
// On both receive session classes, FinishLocked(OkStatus()) is invoked only
// after 100% of destination HBM uploads (every layer or every pool) have
// completed with OkStatus(). Yet if a non-OK Finish(...) arrives while an
// already-OK session is draining its last transport/control reference (or in
// the window before CompleteReadWithDetails reaps a settled session), status_
// is overwritten with the late error, flipping a completed HBM receive from
// `completions.received` into `completions.failed`.

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"
#include "absl/synchronization/mutex.h"
#include "absl/synchronization/notification.h"
#include "absl/time/time.h"
#include "xla/future.h"
#include "xla/tsl/concurrency/future.h"
#include "tpu_sync/core/control_plane_backend.h"
#include "tpu_sync/core/raiden_transfer_endpoint.h"
#include "tpu_sync/core/raw_transfer_core.h"
#include "tpu_sync/kv_cache/kv_cache_manager_base.h"
#include "tpu_sync/kv_cache/kv_cache_manager_with_transfer.h"
#include "tpu_sync/kv_cache/pool_layout.h"
#include "tpu_sync/kv_cache/reshard_receive_session.h"
#include "tpu_sync/kv_cache/transfer_receive_session.h"
#include "tpu_sync/kv_cache/transfer_send_session.h"
#include "tpu_sync/rpc/raiden_service.pb.h"

namespace tpu_raiden {

struct PoolReshardRecvTestPeer {
  static void FinishPoolH2d(ReshardReceiveSession& session,
                            KVCacheManagerWithTransfer& manager,
                            size_t pool_idx, const absl::Status& status) {
    session.FinishPoolH2d(manager, pool_idx, status);
  }
};

namespace {

using ::absl_testing::IsOk;
using ::testing::ElementsAre;
using ::testing::IsEmpty;
using ::tpu_sync::rpc::MEMORY_TYPE_HBM;
using ::tpu_sync::rpc::StartTransferRequest;

constexpr int64_t kSlots = 2;

// Async ControlPlaneBackend whose PullStream future resolves when the test
// triggers it, matching an async control channel whose reply arrives after the
// producer's detached StartPush worker has already delivered the data stream.
class ManualControlBackend final : public ControlPlaneBackend {
 public:
  absl::StatusOr<int> StartServer(int /*requested_port*/,
                                  ControlPlaneHandler* /*handler*/) override {
    return 0;
  }
  void StopServer() override {}

  tsl::Future<PullStreamResponseSpec> SendPullRequest(
      absl::string_view /*remote_endpoint*/,
      const PullStreamRequestSpec& /*req*/,
      absl::Duration /*timeout*/) override {
    auto [promise, future] = tsl::MakePromise<PullStreamResponseSpec>();
    {
      absl::MutexLock lock(mu_);
      pull_promise_ = std::move(promise);
    }
    sent_.Notify();
    return std::move(future);
  }

  absl::Status SendAck(absl::string_view /*remote_endpoint*/, uint64_t /*uuid*/,
                       absl::Duration /*timeout*/) override {
    return absl::OkStatus();
  }

  absl::string_view Name() const override { return "manual"; }

  bool WaitForPullSent(absl::Duration timeout) {
    return sent_.WaitForNotificationWithTimeout(timeout);
  }

  void CompletePull(absl::StatusOr<PullStreamResponseSpec> result) {
    tsl::Promise<PullStreamResponseSpec> promise;
    {
      absl::MutexLock lock(mu_);
      promise = std::move(pull_promise_);
    }
    promise.Set(std::move(result));
  }

 private:
  absl::Mutex mu_;
  tsl::Promise<PullStreamResponseSpec> pull_promise_ ABSL_GUARDED_BY(mu_);
  absl::Notification sent_;
};

class LateFinishTestManager : public KVCacheManagerWithTransfer {
 public:
  explicit LateFinishTestManager(size_t num_layers = 1, double timeout_s = 30.0)
      : KVCacheManagerWithTransfer(std::make_unique<FakeBase>(num_layers, this),
                                   /*node_id=*/0,
                                   /*local_control_port=*/-1,
                                   /*max_blocks=*/1,
                                   /*num_slots=*/kSlots, timeout_s) {
    auto backend = std::make_unique<ManualControlBackend>();
    manual_control_ = backend.get();
    control_backend_ = std::move(backend);
  }

  ManualControlBackend* manual_control() { return manual_control_; }

  void CompleteCopy(size_t index, absl::Status status) {
    xla::Promise<> promise;
    {
      absl::MutexLock lock(copies_mu_);
      promise = std::move(copies_.at(index));
    }
    promise.Set(std::move(status));
  }

  size_t copies_issued() {
    absl::MutexLock lock(copies_mu_);
    return copies_.size();
  }

  void FinishPoolReshardRecvPool(uint64_t uuid, size_t pool_idx,
                                 const absl::Status& status) {
    std::shared_ptr<ReshardReceiveSession> session;
    {
      absl::MutexLock lock(mu_);
      session = active_pool_reshard_recvs_.at(uuid);
    }
    PoolReshardRecvTestPeer::FinishPoolH2d(*session, *this, pool_idx, status);
  }

  void CancelSend(uint64_t uuid, const absl::Status& status) {
    std::shared_ptr<TransferSendSession> session;
    {
      absl::MutexLock lock(mu_);
      session = send_sessions_.at(uuid);
    }
    session->Finish(status);
  }

  using KVCacheManagerWithTransfer::AckSend;
  using KVCacheManagerWithTransfer::PoolReshardRegisterRecv;

 private:
  class FakeBase final : public kv_cache::KVCacheManagerBase {
   public:
    FakeBase(size_t num_layers, LateFinishTestManager* owner)
        : kv_cache::KVCacheManagerBase(num_layers, /*num_shards=*/1,
                                       std::vector<size_t>(num_layers, 128),
                                       /*local_port=*/std::nullopt,
                                       /*host_blocks_to_allocate=*/4,
                                       /*parallelism=*/1, nullptr),
          owner_(owner) {}

    absl::StatusOr<raiden::PjRtCopyFuture> H2dSyncDispatch(
        const std::vector<int64_t>& /*src_offsets_major_dim*/,
        const std::vector<int64_t>& /*dst_offsets_major_dim*/,
        const std::vector<int64_t>& /*copy_sizes_major_dim*/,
        std::optional<int64_t> /*slot_idx*/,
        std::optional<size_t> /*layer_idx*/,
        std::optional<size_t> /*host_layer_idx*/,
        std::optional<size_t> /*shard_idx*/) override {
      auto [promise, future] = xla::MakePromise<>();
      absl::MutexLock lock(owner_->copies_mu_);
      owner_->copies_.push_back(std::move(promise));
      return raiden::PjRtCopyFuture(std::move(future), raiden::BufferHolders{});
    }

   private:
    LateFinishTestManager* owner_;
  };

  absl::Mutex copies_mu_;
  std::vector<xla::Promise<>> copies_ ABSL_GUARDED_BY(copies_mu_);
  ManualControlBackend* manual_control_ = nullptr;
};

StartTransferRequest MakeHbmRecvPlan(uint64_t uuid, const std::string& req_id) {
  StartTransferRequest plan;
  plan.set_uuid(uuid);
  plan.set_req_id(req_id);
  plan.set_dst_mem_type(MEMORY_TYPE_HBM);
  plan.set_use_block_chunks(true);
  auto* entry = (*plan.mutable_shard_push_schedules())[0].add_entries();
  entry->set_dst_shard_idx(0);
  entry->set_src_block_id(0);
  entry->set_dst_block_id(0);
  entry->set_size_bytes(128);
  entry->set_count(1);
  return plan;
}

kv_cache::PoolSpec MakeDensePool() {
  return kv_cache::PoolSpec{
      .tag = "fa",
      .storage_index = 0,
      .base_offset_bytes = 0,
      .block_stride_bytes = 128,
      .num_blocks = 4,
      .regions = {kv_cache::RegionSpec{
          .name = "block",
          .offset_bytes = 0,
          .stride_bytes = 128,
          .unit_bytes = 128,
          .num_units = 1,
          .units_per_stride = 1,
      }},
      .dtype_tag = "bf16",
  };
}

StartTransferRequest MakePoolReshardRecvPlan(uint64_t uuid,
                                             const std::string& req_id) {
  StartTransferRequest plan;
  plan.set_uuid(uuid);
  plan.set_req_id(req_id);
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
  entry->set_size_bytes(16);
  entry->set_count(1);
  return plan;
}

// Positive control: TransferSendSession::FinishLocked guards `status_` behind
// `if (draining_ || done_) return;`, so a late error Finish after AckSend
// settled the send OK preserves `done_sending` and never flips to `failed`.
TEST(RecvLateFinishBughunt,
     Control_TransferSendSessionPreservesOkAcrossLateErrorFinish) {
  LateFinishTestManager producer(/*num_layers=*/1);
  ASSERT_GT(producer.NotifyForRead("req-send-ok", /*uuid=*/100, {0}), 0);
  producer.AckSend(/*uuid=*/100);

  producer.CancelSend(/*uuid=*/100,
                      absl::CancelledError("late cancel after ok settle"));

  CompleteReadResult completions = producer.CompleteReadWithDetails();
  EXPECT_THAT(completions.sent, ElementsAre("req-send-ok"));
  EXPECT_THAT(completions.failed, IsEmpty());
}

// Path 1 (hooks.end_incoming_push): BlockTransportServerPushSession::StartStream
// fires CompleteIncomingPush -> OnLayerReceived (lines 438-441) before clearing
// `incoming_push_lease_held` (line 448) and writing the final 1-byte ACK (line
// 453), and a second concurrently-admitted duplicate stream can also hit
// absl::Cleanup end_incoming_push(InternalError("Incoming push failed")) after
// all layers' H2D copies have already completed OK. Once every H2D copy into
// destination HBM has succeeded (FinishLocked(OkStatus()) ran), a trailing
// stream teardown error must not flip the completed receive to failed.
TEST(RecvLateFinishBughunt,
     TrailingPushStreamErrorAfterCompletedH2dMustNotFlipReceivedToFailed) {
  LateFinishTestManager consumer(/*num_layers=*/1);
  ABSL_ASSERT_OK(consumer.RegisterActivePlan(
      /*uuid=*/201, MakeHbmRecvPlan(/*uuid=*/201, "req-trail-push"),
      /*is_sender=*/false));

  ABSL_ASSERT_OK(consumer.base()->BeginIncomingPush(/*uuid=*/201));
  ABSL_ASSERT_OK(consumer.base()->OnLayerReceived(/*layer_idx=*/0, /*uuid=*/201));
  ASSERT_EQ(consumer.copies_issued(), 1u);
  consumer.CompleteCopy(0, absl::OkStatus());

  // Every layer's H2D into HBM has completed with OkStatus(); now the open
  // incoming push stream exits via StartStream's absl::Cleanup.
  consumer.base()
      ->EndIncomingPush(/*uuid=*/201,
                        absl::InternalError("Incoming push failed"))
      .IgnoreError();

  CompleteReadResult completions = consumer.CompleteReadWithDetails();
  EXPECT_THAT(completions.received, ElementsAre("req-trail-push"));
  EXPECT_THAT(completions.failed, IsEmpty());
}

// Path 2 (KVCacheManagerWithTransfer::UnregisterActivePlan): UnregisterActivePlan
// captures `recv` while `!recv->Done()` (e.g. while EndIncomingPush has not yet
// released the push lease even though every H2D copy already completed OK, or
// in the window between the unlocked `mu_` check at line 927 and `recv->Finish`
// at line 938) and calls `recv->Finish(CancelledError("receive plan
// unregistered"))`. A receive whose H2D copies into HBM have all completed OK
// and whose push stream closes cleanly must report `received`, not `failed`.
TEST(RecvLateFinishBughunt,
     UnregisterActivePlanAfterCompletedH2dMustNotFlipReceivedToFailed) {
  LateFinishTestManager consumer(/*num_layers=*/1);
  ABSL_ASSERT_OK(consumer.RegisterActivePlan(
      /*uuid=*/202, MakeHbmRecvPlan(/*uuid=*/202, "req-unreg-plan"),
      /*is_sender=*/false));

  ABSL_ASSERT_OK(consumer.base()->BeginIncomingPush(/*uuid=*/202));
  ABSL_ASSERT_OK(consumer.base()->OnLayerReceived(/*layer_idx=*/0, /*uuid=*/202));
  ASSERT_EQ(consumer.copies_issued(), 1u);
  consumer.CompleteCopy(0, absl::OkStatus());

  ABSL_ASSERT_OK(consumer.UnregisterActivePlan(/*uuid=*/202));
  ABSL_EXPECT_OK(
      consumer.base()->EndIncomingPush(/*uuid=*/202, absl::OkStatus()));

  CompleteReadResult completions = consumer.CompleteReadWithDetails();
  EXPECT_THAT(completions.received, ElementsAre("req-unreg-plan"));
  EXPECT_THAT(completions.failed, IsEmpty());
}

// Path 3 (ExecutePullRequest::on_response): HandlePullStream detaches the
// producer's StartPush worker before returning PullStreamResponseSpec on the
// control channel. If all pushed layers arrive and complete H2D into HBM before
// a delayed/failing control reply resolves on_response, `self->FinishLocked`
// overwrites the settled OK status with the control-channel error.
TEST(RecvLateFinishBughunt,
     LateControlPullReplyErrorAfterCompletedH2dMustNotFlipReceivedToFailed) {
  LateFinishTestManager consumer(/*num_layers=*/1);

  consumer.StartRead("req-pull-reply", /*uuid=*/203,
                     /*remote_endpoint=*/"127.0.0.1:9999",
                     /*remote_block_ids=*/{0}, /*local_block_ids=*/{0});
  ASSERT_TRUE(consumer.manual_control()->WaitForPullSent(absl::Seconds(5)));

  // Data push arrives and H2D into HBM completes OK while the control reply is
  // still in flight.
  ABSL_ASSERT_OK(consumer.base()->OnLayerReceived(/*layer_idx=*/0, /*uuid=*/203));
  ASSERT_EQ(consumer.copies_issued(), 1u);
  consumer.CompleteCopy(0, absl::OkStatus());

  // Control reply fails on the return leg after HBM already holds every block.
  consumer.manual_control()->CompletePull(
      absl::DeadlineExceededError("control reply timed out on return leg"));

  // Wait briefly for on_response to run on the future thread and release its op.
  const absl::Time deadline = absl::Now() + absl::Seconds(5);
  CompleteReadResult completions;
  while (absl::Now() < deadline) {
    completions = consumer.CompleteReadWithDetails();
    if (!completions.received.empty() || !completions.failed.empty()) {
      break;
    }
    absl::SleepFor(absl::Milliseconds(1));
  }

  EXPECT_THAT(completions.received, ElementsAre("req-pull-reply"));
  EXPECT_THAT(completions.failed, IsEmpty());
}

// Path 4 (ReshardReceiveSession::FinishLocked): pool-reshard receive has the
// exact same unguarded `if (!status.ok() && status_.ok()) status_ = status;`
// before `if (draining_) return;`. Once every declared pool's H2D has completed
// OK, a late UnregisterActivePlan (or trailing EndIncomingPush error) flips
// `done_recving` into `failed_recving`.
TEST(RecvLateFinishBughunt,
     PoolReshardUnregisterAfterCompletedPoolH2dMustNotFlipReceivedToFailed) {
  LateFinishTestManager consumer(/*num_layers=*/1);
  ABSL_ASSERT_OK(consumer.base()->RegisterPools({MakeDensePool()}));
  consumer.base()->AttachPlaceholderDeviceHoldForTest();

  ABSL_ASSERT_OK(consumer.PoolReshardRegisterRecv(
      MakePoolReshardRecvPlan(/*uuid=*/204, "req-pool-reshard"),
      std::vector<int64_t>{0}));

  ABSL_ASSERT_OK(consumer.base()->BeginIncomingPush(/*uuid=*/204));
  consumer.FinishPoolReshardRecvPool(/*uuid=*/204, /*pool_idx=*/0,
                                     absl::OkStatus());

  ABSL_ASSERT_OK(consumer.UnregisterActivePlan(/*uuid=*/204));
  consumer.base()
      ->EndIncomingPush(/*uuid=*/204, absl::OkStatus())
      .IgnoreError();

  CompleteReadResult completions = consumer.CompleteReadWithDetails();
  EXPECT_THAT(completions.received, ElementsAre("req-pool-reshard"));
  EXPECT_THAT(completions.failed, IsEmpty());
}

}  // namespace
}  // namespace tpu_raiden
