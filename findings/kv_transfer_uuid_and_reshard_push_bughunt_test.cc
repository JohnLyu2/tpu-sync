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

// Hardware-free reproduction for F16 and F17 (tpu-sync 56a0269d):
//
// F16 (UuidRetirementBughunt):
//   1. Inline retirement in KVCacheManagerWithTransfer::StartRead (:920-921)
//      and EmplaceRecvSessionLocked (:576, reached from RegisterRecv :672)
//      calls RetireSettledSessionLocked(existing) with default nullptr
//      out-parameters, erasing a settled session from sessions_ without calling
//      BlockTransport::ForgetPushProgress(uuid) (or ReleasePoolStagingLeases).
//      When Attempt #1 landed layer 0 (setting on_layer_received_called = true)
//      and settled on an error before layer 1 completed, a replacement StartRead
//      or RegisterRecv for the same uuid inherits the stale push-progress entry:
//      layer 0's OnLayerReceived(0, uuid) (H2D) is suppressed while
//      OnBlockShardsReceived still counts layer 0's blocks toward
//      network_completed_, so CompleteReadWithDetails publishes the replacement
//      request in completions.received (done_recving) with layer 0's HBM
//      destination block completely unwritten.
//   2. CompleteReadWithDetails (:1046-1066) attempts to filter re-registered
//      uuids out of retired_uuids via std::erase_if checking
//      sessions_.contains(uuid) || pending_pool_reshard_recvs_.contains(uuid),
//      but runs std::erase_if inside the same mu_ critical section that just
//      erased those uuids from sessions_ (making the guard dead code), then
//      unlocks mu_ (:1058) and calls ForgetPushProgress(uuid) +
//      ReleasePoolStagingLeases(uuid) unlocked (:1061-1066). A concurrent
//      replacement receive registered after mu_ unlocks has its live transport
//      push progress wiped mid-transfer, again suppressing layer 0's H2D while
//      still publishing done_recving via network_completed_.
//
// F17 (PoolReshardPushDuplicateUuidBughunt):
//   KVCacheManagerWithTransfer::PoolReshardPush (:692-723) checks
//   sessions_.find(plan.uuid()) under mu_ (:694), drops mu_ with no pending-uuid
//   reservation while constructing ReshardSendSession::Create (:711-715,
//   contrast PoolReshardRegisterRecv's pending_pool_reshard_recvs_ at :744),
//   and then blindly overwrites sessions_[plan.uuid()] = state (:718). Two
//   concurrent PoolReshardPush calls for the same uuid both succeed, orphan the
//   first live ReshardSendSession from sessions_, share uuid's bounded
//   PoolStagingStorage slot via idempotent AcquirePoolStagingLease, and free
//   that slot on the first session's settle while the surviving sender push is
//   still streaming out of it, letting an unrelated transfer lease the same
//   host staging memory.
//
// Copy next to kv_cache_manager_with_transfer_pool_reshard_test.cc, apply
// findings/build_targets.patch, and run:
//   bazel test --config=oss //tpu_sync/kv_cache:kv_transfer_uuid_and_reshard_push_bughunt_test

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>  // NOLINT(build/c++11)
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <thread>  // NOLINT(build/c++11)
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"
#include "absl/synchronization/mutex.h"
#include "absl/synchronization/notification.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"
#include "xla/future.h"
#include "xla/pjrt/c/pjrt_c_api.h"
#include "xla/pjrt/c/pjrt_c_api_raw_buffer_extension.h"
#include "xla/tsl/concurrency/future.h"
#include "tpu_sync/core/control_plane_backend.h"
#include "tpu_sync/core/raiden_transfer_endpoint.h"
#include "tpu_sync/core/raw_transfer_core.h"
#include "tpu_sync/kv_cache/kv_cache_manager_base.h"
#include "tpu_sync/kv_cache/kv_cache_manager_with_transfer.h"
#include "tpu_sync/kv_cache/pool_layout.h"
#include "tpu_sync/rpc/raiden_service.pb.h"
#include "tpu_sync/transport/block_transport.h"
#include "tpu_sync/transport/transfer_session.h"

namespace tpu_raiden {
namespace {

using ::absl_testing::IsOk;
using ::absl_testing::StatusIs;
using ::testing::Contains;
using ::testing::ElementsAre;
using ::testing::IsEmpty;
using ::tpu_sync::rpc::MEMORY_TYPE_HBM;
using ::tpu_sync::rpc::StartTransferRequest;

constexpr size_t kNumLayers = 2;
constexpr int64_t kStride = 128;
constexpr int kHostBlocks = 8;
constexpr uint8_t kPoisonByte = 0xEE;

// ---------------------------------------------------------------------------
// F16 helpers: consumer manager with simulated HBM + manual pull control.
// ---------------------------------------------------------------------------

class ManualControlBackend final : public ControlPlaneBackend {
 public:
  absl::StatusOr<int> StartServer(int /*requested_port*/,
                                  ControlPlaneHandler* /*handler*/) override {
    return 0;
  }
  void StopServer() override {}

  tsl::Future<PullStreamResponseSpec> SendPullRequest(
      absl::string_view /*remote_endpoint*/, const PullStreamRequestSpec& req,
      absl::Duration /*timeout*/) override {
    auto [promise, future] = tsl::MakePromise<PullStreamResponseSpec>();
    {
      absl::MutexLock lock(mu_);
      pull_promise_ = std::move(promise);
      last_req_ = req;
      pull_ready_ = true;
    }
    return std::move(future);
  }

  absl::Status SendAck(absl::string_view /*remote_endpoint*/, uint64_t /*uuid*/,
                       absl::Duration /*timeout*/) override {
    return absl::OkStatus();
  }

  absl::string_view Name() const override { return "manual"; }

  PullStreamRequestSpec WaitForPullRequest() {
    absl::MutexLock lock(mu_);
    mu_.Await(absl::Condition(&pull_ready_));
    pull_ready_ = false;
    return last_req_;
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
  PullStreamRequestSpec last_req_ ABSL_GUARDED_BY(mu_);
  bool pull_ready_ ABSL_GUARDED_BY(mu_) = false;
};

class SimHbmBase final : public kv_cache::KVCacheManagerBase {
 public:
  explicit SimHbmBase(size_t num_layers)
      : kv_cache::KVCacheManagerBase(
            num_layers, /*num_shards=*/1,
            std::vector<size_t>(num_layers, static_cast<size_t>(kStride)),
            /*local_port=*/0, /*host_blocks_to_allocate=*/kHostBlocks,
            /*parallelism=*/1, nullptr),
        sim_hbm_(num_layers,
                 std::vector<uint8_t>(kHostBlocks * kStride, kPoisonByte)) {
    InitTransportServer();
  }

  absl::StatusOr<raiden::PjRtCopyFuture> H2dSyncDispatch(
      const std::vector<int64_t>& src_offsets_major_dim,
      const std::vector<int64_t>& dst_offsets_major_dim,
      const std::vector<int64_t>& copy_sizes_major_dim,
      std::optional<int64_t> /*slot_idx*/, std::optional<size_t> layer_idx,
      std::optional<size_t> host_layer_idx,
      std::optional<size_t> /*shard_idx*/) override {
    const size_t l = layer_idx.value_or(0);
    const size_t hl = host_layer_idx.value_or(l);
    const uint8_t* host_ptr = GetHostPointer(hl, /*shard_idx=*/0);
    {
      absl::MutexLock lock(hbm_mu_);
      dispatched_layers_.push_back(l);
      if (src_offsets_major_dim.empty()) {
        std::memcpy(sim_hbm_[l].data(), host_ptr, kStride);
      } else {
        for (size_t i = 0; i < copy_sizes_major_dim.size(); ++i) {
          std::memcpy(
              sim_hbm_[l].data() + dst_offsets_major_dim[i] * kStride,
              host_ptr + src_offsets_major_dim[i] * kStride,
              static_cast<size_t>(copy_sizes_major_dim[i] * kStride));
        }
      }
    }
    return raiden::PjRtCopyFuture(xla::Future<>(absl::OkStatus()),
                                  raiden::BufferHolders{});
  }

  uint8_t HbmByte(size_t layer, size_t block) const {
    absl::MutexLock lock(hbm_mu_);
    return sim_hbm_.at(layer).at(block * kStride);
  }

  void ResetHbmAndLog() {
    absl::MutexLock lock(hbm_mu_);
    for (auto& layer_buf : sim_hbm_) {
      std::fill(layer_buf.begin(), layer_buf.end(), kPoisonByte);
    }
    dispatched_layers_.clear();
  }

  std::vector<size_t> DispatchedLayers() const {
    absl::MutexLock lock(hbm_mu_);
    return dispatched_layers_;
  }

  absl::Mutex* server_init_mu() { return &server_init_mu_; }

 private:
  mutable absl::Mutex hbm_mu_;
  std::vector<std::vector<uint8_t>> sim_hbm_ ABSL_GUARDED_BY(hbm_mu_);
  std::vector<size_t> dispatched_layers_ ABSL_GUARDED_BY(hbm_mu_);
};

class SimConsumerManager final : public KVCacheManagerWithTransfer {
 public:
  SimConsumerManager()
      : KVCacheManagerWithTransfer(std::make_unique<SimHbmBase>(kNumLayers),
                                   /*node_id=*/0, /*local_control_port=*/-1,
                                   /*max_blocks=*/2, /*num_slots=*/4,
                                   /*timeout_s=*/30.0) {
    auto backend = std::make_unique<ManualControlBackend>();
    manual_control_ = backend.get();
    control_backend_ = std::move(backend);
  }

  SimHbmBase* sim_base() { return static_cast<SimHbmBase*>(base()); }
  ManualControlBackend* manual_control() { return manual_control_; }

  std::string DataEndpoint() const {
    return get_local_data_endpoints().at(0).endpoint;
  }

 private:
  ManualControlBackend* manual_control_ = nullptr;
};

void FillSenderBlock(kv_cache::KVCacheManagerBase& sender, size_t layer,
                     size_t block, uint8_t value) {
  std::memset(sender.GetHostPointer(layer, /*shard_idx=*/0) + block * kStride,
              value, kStride);
}

std::vector<int> ToIntVec(const std::vector<int64_t>& v) {
  return std::vector<int>(v.begin(), v.end());
}

StartTransferRequest MakeTwoSenderHbmRecvPlan(uint64_t uuid,
                                              const std::string& req_id,
                                              int64_t dst_block_0,
                                              int64_t dst_block_1) {
  StartTransferRequest plan;
  plan.set_uuid(uuid);
  plan.set_req_id(req_id);
  plan.set_dst_mem_type(MEMORY_TYPE_HBM);
  plan.set_use_block_chunks(true);
  auto* e0 = (*plan.mutable_shard_push_schedules())[0].add_entries();
  e0->set_dst_shard_idx(0);
  e0->set_src_block_id(0);
  e0->set_dst_block_id(dst_block_0);
  e0->set_size_bytes(kStride);
  e0->set_count(1);
  auto* e1 = (*plan.mutable_shard_push_schedules())[1].add_entries();
  e1->set_dst_shard_idx(0);
  e1->set_src_block_id(0);
  e1->set_dst_block_id(dst_block_1);
  e1->set_size_bytes(kStride);
  e1->set_count(1);
  return plan;
}

// Control for F16: when CompleteReadWithDetails() sweeps a failed 2-layer
// StartRead before the uuid is reused, ForgetPushProgress(uuid) clears the
// stale layer-0 push progress and Attempt #2 copies both layers to HBM.
TEST(UuidRetirementBughunt,
     Control_SweepBeforeSameUuidStartReadCopiesEveryLayer) {
  SimConsumerManager consumer;
  kv_cache::KVCacheManagerBase sender(kNumLayers, /*num_shards=*/1, kStride,
                                      /*local_port=*/0, kHostBlocks);
  sender.InitTransportServer();
  FillSenderBlock(sender, /*layer=*/0, /*block=*/0, 0xA0);
  FillSenderBlock(sender, /*layer=*/1, /*block=*/0, 0xA1);
  FillSenderBlock(sender, /*layer=*/0, /*block=*/1, 0xB0);
  FillSenderBlock(sender, /*layer=*/1, /*block=*/1, 0xB1);

  constexpr uint64_t kUuid = 7701;
  const std::string peer = consumer.DataEndpoint();

  // Attempt #1 lands layer 0, then settles on a failed pull reply before
  // layer 1 ever arrives.
  consumer.StartRead("req_1", kUuid, "127.0.0.1:9", /*remote_block_ids=*/{0},
                     /*local_block_ids=*/{0}, /*parallelism=*/1);
  const PullStreamRequestSpec req1 =
      consumer.manual_control()->WaitForPullRequest();
  ASSERT_THAT(
      sender.transport_server()
          ->AsyncPush({peer}, {0}, ToIntVec(req1.dst_block_ids),
                      /*parallelism=*/1, transport::MajorOrder::kLayerMajor,
                      kUuid, /*layer_idx=*/0)
          .Await(),
      IsOk());
  consumer.manual_control()->CompletePull(
      absl::UnavailableError("producer died after layer 0"));

  // Sweeping first calls ForgetPushProgress(kUuid).
  const CompleteReadResult sweep1 = consumer.CompleteReadWithDetails();
  ASSERT_THAT(sweep1.failed, ElementsAre("req_1"));
  consumer.sim_base()->ResetHbmAndLog();

  // Attempt #2 reuses kUuid and copies both layers into local block 1.
  consumer.StartRead("req_2", kUuid, "127.0.0.1:9", /*remote_block_ids=*/{1},
                     /*local_block_ids=*/{1}, /*parallelism=*/1);
  const PullStreamRequestSpec req2 =
      consumer.manual_control()->WaitForPullRequest();
  consumer.manual_control()->CompletePull(PullStreamResponseSpec{.status = 0});
  ASSERT_THAT(
      sender.transport_server()
          ->AsyncPush({peer}, {1}, ToIntVec(req2.dst_block_ids),
                      /*parallelism=*/1, transport::MajorOrder::kLayerMajor,
                      kUuid, /*layer_idx=*/0)
          .Await(),
      IsOk());
  ASSERT_THAT(
      sender.transport_server()
          ->AsyncPush({peer}, {1}, ToIntVec(req2.dst_block_ids),
                      /*parallelism=*/1, transport::MajorOrder::kLayerMajor,
                      kUuid, /*layer_idx=*/1)
          .Await(),
      IsOk());

  const CompleteReadResult sweep2 = consumer.CompleteReadWithDetails();
  EXPECT_THAT(sweep2.received, ElementsAre("req_2"));
  EXPECT_THAT(consumer.sim_base()->DispatchedLayers(), ElementsAre(0, 1));
  EXPECT_EQ(consumer.sim_base()->HbmByte(/*layer=*/0, /*block=*/1), 0xB0);
  EXPECT_EQ(consumer.sim_base()->HbmByte(/*layer=*/1, /*block=*/1), 0xB1);
}

// F16 (StartRead inline retirement, kv_cache_manager_with_transfer.cc:920-921):
// StartRead calls RetireSettledSessionLocked(incumbent) with nullptr
// out-parameters, erasing Attempt #1 from sessions_ without calling
// ForgetPushProgress(kUuid). Attempt #2 inherits layer_progress_[0]'s
// on_layer_received_called == true, skips layer 0's H2D, and is published in
// completions.received (done_recving) with layer 0's HBM block still 0xEE.
TEST(UuidRetirementBughunt,
     StartReadInlineRetirementSkipsLayerZeroH2dAndPublishesCorruptSuccess) {
  SimConsumerManager consumer;
  kv_cache::KVCacheManagerBase sender(kNumLayers, /*num_shards=*/1, kStride,
                                      /*local_port=*/0, kHostBlocks);
  sender.InitTransportServer();
  FillSenderBlock(sender, /*layer=*/0, /*block=*/0, 0xA0);
  FillSenderBlock(sender, /*layer=*/1, /*block=*/0, 0xA1);
  FillSenderBlock(sender, /*layer=*/0, /*block=*/1, 0xB0);
  FillSenderBlock(sender, /*layer=*/1, /*block=*/1, 0xB1);

  constexpr uint64_t kUuid = 7702;
  const std::string peer = consumer.DataEndpoint();

  consumer.StartRead("req_1", kUuid, "127.0.0.1:9", /*remote_block_ids=*/{0},
                     /*local_block_ids=*/{0}, /*parallelism=*/1);
  const PullStreamRequestSpec req1 =
      consumer.manual_control()->WaitForPullRequest();
  ASSERT_THAT(
      sender.transport_server()
          ->AsyncPush({peer}, {0}, ToIntVec(req1.dst_block_ids),
                      /*parallelism=*/1, transport::MajorOrder::kLayerMajor,
                      kUuid, /*layer_idx=*/0)
          .Await(),
      IsOk());
  consumer.manual_control()->CompletePull(
      absl::UnavailableError("producer died after layer 0"));
  consumer.sim_base()->ResetHbmAndLog();

  // Reuse kUuid before CompleteReadWithDetails() runs: StartRead retires req_1
  // inline without calling ForgetPushProgress(kUuid).
  consumer.StartRead("req_2", kUuid, "127.0.0.1:9", /*remote_block_ids=*/{1},
                     /*local_block_ids=*/{1}, /*parallelism=*/1);
  const PullStreamRequestSpec req2 =
      consumer.manual_control()->WaitForPullRequest();
  consumer.manual_control()->CompletePull(PullStreamResponseSpec{.status = 0});
  ASSERT_THAT(
      sender.transport_server()
          ->AsyncPush({peer}, {1}, ToIntVec(req2.dst_block_ids),
                      /*parallelism=*/1, transport::MajorOrder::kLayerMajor,
                      kUuid, /*layer_idx=*/0)
          .Await(),
      IsOk());
  ASSERT_THAT(
      sender.transport_server()
          ->AsyncPush({peer}, {1}, ToIntVec(req2.dst_block_ids),
                      /*parallelism=*/1, transport::MajorOrder::kLayerMajor,
                      kUuid, /*layer_idx=*/1)
          .Await(),
      IsOk());

  const CompleteReadResult result = consumer.CompleteReadWithDetails();
  ASSERT_THAT(result.failed, ElementsAre("req_1"));
  ASSERT_THAT(result.received, ElementsAre("req_2"));
  EXPECT_EQ(consumer.sim_base()->HbmByte(/*layer=*/1, /*block=*/1), 0xB1);
  EXPECT_THAT(consumer.sim_base()->DispatchedLayers(), ElementsAre(0, 1))
      << "[F16] StartRead inline retirement omitted ForgetPushProgress("
      << kUuid << "), suppressing layer 0's H2D on req_2";
  EXPECT_EQ(consumer.sim_base()->HbmByte(/*layer=*/0, /*block=*/1), 0xB0)
      << "[F16] req_2 was reported in completions.received (done_recving) "
         "with poison byte 0xEE still in layer 0's HBM block";
}

// F16 (RegisterRecv / EmplaceRecvSessionLocked inline retirement,
// kv_cache_manager_with_transfer.cc:576): same defect via RegisterRecv.
// Attempt #1 lands layer 0 and settles when layer 1's push fails validation on
// an out-of-range destination block; RegisterRecv retires Attempt #1 inline
// without ForgetPushProgress(kUuid), and Attempt #2 publishes
// completions.received with layer 0's HBM unwritten.
TEST(UuidRetirementBughunt,
     RegisterRecvInlineRetirementSkipsLayerZeroH2dAndPublishesCorruptSuccess) {
  SimConsumerManager consumer;
  kv_cache::KVCacheManagerBase sender_1(kNumLayers, /*num_shards=*/1, kStride,
                                        /*local_port=*/0, kHostBlocks);
  kv_cache::KVCacheManagerBase sender_2(kNumLayers, /*num_shards=*/1, kStride,
                                        /*local_port=*/0, kHostBlocks);
  sender_1.InitTransportServer();
  sender_2.InitTransportServer();
  FillSenderBlock(sender_1, /*layer=*/0, /*block=*/0, 0xA0);

  constexpr uint64_t kUuid = 7703;
  const std::string peer = consumer.DataEndpoint();

  ABSL_ASSERT_OK(consumer.RegisterRecv(kUuid, "req_1",
                                       /*expected_block_count=*/1));
  ASSERT_THAT(
      sender_1.transport_server()
          ->AsyncPush({peer}, {0}, {0}, /*parallelism=*/1,
                      transport::MajorOrder::kLayerMajor, kUuid,
                      /*layer_idx=*/0)
          .Await(),
      IsOk());
  // Layer 1 out-of-range dst_block_ids={999} fails ValidateChunks and triggers
  // EndIncomingPush(error) -> session->Finish(error), settling req_1
  // immediately while leaving active_push_sessions_[kUuid] alive with layer 0
  // marked on_layer_received_called == true.
  ASSERT_FALSE(sender_1.transport_server()
                   ->AsyncPush({peer}, {0}, {999}, /*parallelism=*/1,
                               transport::MajorOrder::kLayerMajor, kUuid,
                               /*layer_idx=*/1)
                   .Await()
                   .ok());
  consumer.sim_base()->ResetHbmAndLog();

  FillSenderBlock(sender_2, /*layer=*/0, /*block=*/0, 0xB0);
  FillSenderBlock(sender_2, /*layer=*/1, /*block=*/0, 0xB1);
  ABSL_ASSERT_OK(consumer.RegisterRecv(kUuid, "req_2",
                                       /*expected_block_count=*/1));
  ASSERT_THAT(
      sender_2.transport_server()
          ->AsyncPush({peer}, {0}, {0}, /*parallelism=*/1,
                      transport::MajorOrder::kLayerMajor, kUuid,
                      /*layer_idx=*/0)
          .Await(),
      IsOk());
  ASSERT_THAT(
      sender_2.transport_server()
          ->AsyncPush({peer}, {0}, {0}, /*parallelism=*/1,
                      transport::MajorOrder::kLayerMajor, kUuid,
                      /*layer_idx=*/1)
          .Await(),
      IsOk());

  const CompleteReadResult result = consumer.CompleteReadWithDetails();
  ASSERT_THAT(result.failed, ElementsAre("req_1"));
  ASSERT_THAT(result.received, ElementsAre("req_2"));
  EXPECT_EQ(consumer.sim_base()->HbmByte(/*layer=*/1, /*block=*/0), 0xB1);
  EXPECT_THAT(consumer.sim_base()->DispatchedLayers(), ElementsAre(0, 1))
      << "[F16] RegisterRecv inline retirement omitted ForgetPushProgress("
      << kUuid << "), suppressing layer 0's H2D on req_2";
  EXPECT_EQ(consumer.sim_base()->HbmByte(/*layer=*/0, /*block=*/0), 0xB0)
      << "[F16] req_2 was reported in completions.received (done_recving) "
         "with poison byte 0xEE still in layer 0's HBM block";
}

// F16 (CompleteReadWithDetails dead std::erase_if + unlocked ForgetPushProgress
// race, kv_cache_manager_with_transfer.cc:1046-1066): std::erase_if checks
// sessions_.contains(uuid) inside the same mu_ scope that just erased uuid, so
// it never filters anything, and the post-mu_ loop calls ForgetPushProgress on
// a newly registered live session, wiping its landed sender_0 layer-0 progress
// and publishing completions.received with layer 0's HBM unwritten.
TEST(UuidRetirementBughunt,
     CompleteReadSweepDeadEraseIfWipesLiveReplacementAndPublishesCorruptHbm) {
  SimConsumerManager consumer;
  kv_cache::KVCacheManagerBase sender_0(kNumLayers, /*num_shards=*/1, kStride,
                                        /*local_port=*/0, kHostBlocks);
  kv_cache::KVCacheManagerBase sender_1(kNumLayers, /*num_shards=*/1, kStride,
                                        /*local_port=*/0, kHostBlocks);
  sender_0.set_node_id(0);
  sender_1.set_node_id(1);
  sender_0.InitTransportServer();
  sender_1.InitTransportServer();
  FillSenderBlock(sender_0, /*layer=*/0, /*block=*/0, 0xC0);
  FillSenderBlock(sender_0, /*layer=*/1, /*block=*/0, 0xC1);
  FillSenderBlock(sender_1, /*layer=*/0, /*block=*/0, 0xC0);
  FillSenderBlock(sender_1, /*layer=*/1, /*block=*/0, 0xC1);

  constexpr uint64_t kUuid = 8801;
  const std::string peer = consumer.DataEndpoint();
  const auto expired =
      std::chrono::steady_clock::now() - std::chrono::seconds(1);
  ABSL_ASSERT_OK(consumer.RegisterRecv(kUuid, "old_req", 1, expired));

  // Hold server_init_mu_ so CompleteReadWithDetails() drops mu_ (:1058) and
  // parks right at base_->transport_server() (:1062) before calling
  // ForgetPushProgress(kUuid).
  CompleteReadResult old_sweep;
  std::thread sweep_thread;
  {
    absl::MutexLock hold_init(consumer.sim_base()->server_init_mu());
    sweep_thread =
        std::thread([&]() { old_sweep = consumer.CompleteReadWithDetails(); });

    while (consumer.base()->GetSession(kUuid).ok()) {
      absl::SleepFor(absl::Milliseconds(1));
    }
    absl::SleepFor(absl::Milliseconds(10));

    // Re-register kUuid and land sender_0's layer-0 stream while sweep_thread
    // is parked between unlocking mu_ (:1058) and ForgetPushProgress (:1063).
    ABSL_ASSERT_OK(consumer.RegisterActivePlan(
        kUuid, MakeTwoSenderHbmRecvPlan(kUuid, "new_req", 0, 1),
        /*is_sender=*/false));
    ASSERT_THAT(sender_0.transport_server()
                    ->AsyncPush({peer}, {0}, {0}, /*parallelism=*/1,
                                transport::MajorOrder::kLayerMajor, kUuid,
                                /*layer_idx=*/0)
                    .Await(),
                IsOk());
  }
  sweep_thread.join();
  ASSERT_THAT(old_sweep.failed, ElementsAre("old_req"));

  // Complete the remaining streams (sender_1 layer 0, plus both senders on
  // layer 1) for the live replacement plan.
  ASSERT_THAT(sender_1.transport_server()
                  ->AsyncPush({peer}, {0}, {1}, /*parallelism=*/1,
                              transport::MajorOrder::kLayerMajor, kUuid,
                              /*layer_idx=*/0)
                  .Await(),
              IsOk());
  ASSERT_THAT(sender_0.transport_server()
                  ->AsyncPush({peer}, {0}, {0}, /*parallelism=*/1,
                              transport::MajorOrder::kLayerMajor, kUuid,
                              /*layer_idx=*/1)
                  .Await(),
              IsOk());
  ASSERT_THAT(sender_1.transport_server()
                  ->AsyncPush({peer}, {0}, {1}, /*parallelism=*/1,
                              transport::MajorOrder::kLayerMajor, kUuid,
                              /*layer_idx=*/1)
                  .Await(),
              IsOk());

  const CompleteReadResult live_sweep = consumer.CompleteReadWithDetails();
  ASSERT_THAT(live_sweep.received, ElementsAre("new_req"));
  EXPECT_EQ(consumer.sim_base()->HbmByte(/*layer=*/1, /*block=*/0), 0xC1);
  EXPECT_EQ(consumer.sim_base()->HbmByte(/*layer=*/1, /*block=*/1), 0xC1);
  EXPECT_THAT(consumer.sim_base()->DispatchedLayers(), ElementsAre(0, 1))
      << "[F16] CompleteReadWithDetails post-mu_ ForgetPushProgress(" << kUuid
      << ") wiped live new_req's sender_0 layer-0 progress, suppressing "
         "layer 0's H2D";
  EXPECT_EQ(consumer.sim_base()->HbmByte(/*layer=*/0, /*block=*/0), 0xC0)
      << "[F16] new_req was reported in completions.received (done_recving) "
         "with poison byte 0xEE still in layer 0's HBM block";
}

// ---------------------------------------------------------------------------
// F17 helpers: CPU-stubbed device hold + TCP peer socket that holds pushes.
// ---------------------------------------------------------------------------

raiden::RaidenBufferHandle MakeStubDeviceHold(size_t size_bytes) {
  static PJRT_Api c_api{};
  static PJRT_RawBuffer_Extension ext{};
  static size_t g_device_bytes = 0;
  g_device_bytes = size_bytes;
  ext.PJRT_RawBuffer_GetOnDeviceSizeInBytes =
      +[](PJRT_RawBuffer_GetOnDeviceSizeInBytes_Args* args) -> PJRT_Error* {
    args->on_device_size_in_bytes = g_device_bytes;
    return nullptr;
  };
  ext.PJRT_RawBuffer_CopyRawDeviceToHost =
      +[](PJRT_RawBuffer_CopyRawDeviceToHost_Args* args) -> PJRT_Error* {
    args->event = nullptr;
    return nullptr;
  };
  ext.PJRT_RawBuffer_CopyRawHostToDevice =
      +[](PJRT_RawBuffer_CopyRawHostToDevice_Args* args) -> PJRT_Error* {
    args->event = nullptr;
    return nullptr;
  };
  raiden::RaidenBufferHandle hold;
  hold.is_common_buffer = false;
  hold.c_raw_buffer = nullptr;
  hold.c_hold =
      std::make_shared<raiden::RawBufferHolder>(&c_api, &ext, nullptr);
  return hold;
}

class HeldPeerListener {
 public:
  HeldPeerListener() {
    listen_fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    ::setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    ::bind(listen_fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    ::listen(listen_fd_, 8);
    socklen_t len = sizeof(addr);
    ::getsockname(listen_fd_, reinterpret_cast<sockaddr*>(&addr), &len);
    endpoint_ = absl::StrCat("127.0.0.1:", ntohs(addr.sin_port));
    accept_thread_ = std::thread([this]() { AcceptLoop(); });
  }

  ~HeldPeerListener() { Shutdown(); }

  const std::string& endpoint() const { return endpoint_; }

  size_t AcceptedCount() {
    absl::MutexLock lock(mu_);
    return client_fds_.size();
  }

  bool WaitForAcceptedCount(size_t count, absl::Duration timeout) {
    absl::MutexLock lock(mu_);
    auto ready = [&]() ABSL_SHARED_LOCKS_REQUIRED(mu_) {
      return client_fds_.size() >= count;
    };
    return mu_.AwaitWithTimeout(absl::Condition(&ready), timeout);
  }

  void CloseOne(size_t index) {
    int fd = -1;
    {
      absl::MutexLock lock(mu_);
      if (index < client_fds_.size()) {
        fd = client_fds_[index];
        client_fds_[index] = -1;
      }
    }
    if (fd >= 0) {
      ::shutdown(fd, SHUT_RDWR);
      ::close(fd);
    }
  }

  void Shutdown() {
    int lfd = -1;
    std::vector<int> fds;
    {
      absl::MutexLock lock(mu_);
      stopping_ = true;
      lfd = listen_fd_;
      listen_fd_ = -1;
      fds.swap(client_fds_);
    }
    if (lfd >= 0) {
      ::shutdown(lfd, SHUT_RDWR);
      ::close(lfd);
    }
    for (int fd : fds) {
      if (fd >= 0) {
        ::shutdown(fd, SHUT_RDWR);
        ::close(fd);
      }
    }
    if (accept_thread_.joinable()) {
      accept_thread_.join();
    }
  }

 private:
  void AcceptLoop() {
    while (true) {
      int lfd;
      {
        absl::MutexLock lock(mu_);
        if (stopping_ || listen_fd_ < 0) return;
        lfd = listen_fd_;
      }
      int cfd = ::accept(lfd, nullptr, nullptr);
      if (cfd < 0) return;
      absl::MutexLock lock(mu_);
      if (stopping_) {
        ::close(cfd);
        return;
      }
      client_fds_.push_back(cfd);
    }
  }

  absl::Mutex mu_;
  int listen_fd_ = -1;
  bool stopping_ ABSL_GUARDED_BY(mu_) = false;
  std::vector<int> client_fds_ ABSL_GUARDED_BY(mu_);
  std::string endpoint_;
  std::thread accept_thread_;
};

class ReshardSenderBase final : public kv_cache::KVCacheManagerBase {
 public:
  ReshardSenderBase()
      : KVCacheManagerBase(/*num_layers=*/1, /*num_shards=*/1, kStride,
                           /*local_port=*/0, std::make_optional<int>(4),
                           /*parallelism=*/4) {
    constexpr size_t kBlocks = 16;
    buffer_holds_.resize(1);
    major_dim_size_ = 1;
    buffer_holds_[0].holds.push_back(MakeStubDeviceHold(kStride * kBlocks));
    buffer_holds_[0].physical_size = kStride * kBlocks;
    layers_[0].shards[0].device_size = kStride * kBlocks;
    InitTransportServer();
  }

  absl::Mutex* server_init_mu() { return &server_init_mu_; }
};

class ReshardSenderManager final : public KVCacheManagerWithTransfer {
 public:
  ReshardSenderManager()
      : KVCacheManagerWithTransfer(std::make_unique<ReshardSenderBase>(),
                                   /*node_id=*/0, /*local_control_port=*/-1,
                                   /*max_blocks=*/0, /*num_slots=*/0,
                                   /*timeout_s=*/30.0) {}

  ReshardSenderBase* sender_base() {
    return static_cast<ReshardSenderBase*>(base());
  }
  using KVCacheManagerWithTransfer::PoolReshardPush;
  using KVCacheManagerWithTransfer::PoolReshardRegisterRecv;
};

kv_cache::PoolSpec BoundedDensePool() {
  return kv_cache::PoolSpec{
      .tag = "fa",
      .storage_index = 0,
      .base_offset_bytes = 0,
      .block_stride_bytes = kStride,
      .num_blocks = 16,
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

StartTransferRequest OnePoolReshardPlan(uint64_t uuid, const std::string& peer,
                                        int64_t block_id = 0) {
  StartTransferRequest plan;
  plan.set_uuid(uuid);
  plan.set_req_id(absl::StrCat("reshard_req_", uuid));
  plan.set_dst_mem_type(MEMORY_TYPE_HBM);
  plan.set_use_block_chunks(true);
  plan.set_parallelism(1);
  plan.add_transfer_pool_indices(0);
  plan.add_pool_dtype_tags("bf16");
  auto* group = plan.add_pool_groups();
  group->add_pool_indices(0);
  group->set_order_rank(0);
  group->add_dst_device_block_ids(block_id);
  group->set_expected_pushes(1);
  group->add_dst_expected_extent_bytes(kStride);
  auto* entry = (*plan.mutable_shard_push_schedules())[0].add_entries();
  entry->set_pool_group(0);
  entry->set_dst_peer(peer);
  entry->set_dst_shard_idx(0);
  entry->set_src_block_id(block_id);
  entry->set_dst_block_id(block_id);
  entry->set_src_offset_bytes(0);
  entry->set_dst_offset_bytes(0);
  entry->set_size_bytes(kStride);
  entry->set_count(1);
  return plan;
}

// Control for F17: sequential duplicate PoolReshardPush for a live uuid is
// rejected by RetireSettledSessionLocked -> AlreadyExistsError, keeping the
// single bounded PoolStagingStorage slot pinned to the active send.
TEST(PoolReshardPushDuplicateUuidBughunt,
     Control_SequentialDuplicateUuidIsRejectedWhileFirstSendIsLive) {
  HeldPeerListener held_peer;
  ReshardSenderManager manager;
  ABSL_ASSERT_OK(manager.base()->RegisterPools({BoundedDensePool()},
                                               /*staging_leases=*/1));

  constexpr uint64_t kUuid = 9101;
  const StartTransferRequest plan =
      OnePoolReshardPlan(kUuid, held_peer.endpoint());
  ABSL_ASSERT_OK(manager.PoolReshardPush(plan, std::vector<int64_t>{0}));
  ASSERT_TRUE(held_peer.WaitForAcceptedCount(1, absl::Seconds(5)));

  EXPECT_THAT(manager.PoolReshardPush(plan, std::vector<int64_t>{0}),
              StatusIs(absl::StatusCode::kAlreadyExists));
  EXPECT_EQ(manager.base()->PoolStagingSummary().at(0).free_slots, 0);
  EXPECT_THAT(manager.base()->AcquirePoolStagingLease(
                  /*uuid=*/9102, /*storage_idx=*/0, std::vector<int64_t>{1},
                  absl::ZeroDuration()),
              StatusIs(absl::StatusCode::kResourceExhausted));

  held_peer.Shutdown();
  auto session_or = manager.base()->GetSession(kUuid);
  if (session_or.ok()) {
    (*session_or)->AwaitForDone().IgnoreError();
  }
}

// F17 (PoolReshardPush missing pending-uuid reservation + blind sessions_[uuid]
// overwrite, kv_cache_manager_with_transfer.cc:692-723): two concurrent
// PoolReshardPush calls for kUuid both pass sessions_.find(kUuid) before either
// emplaces, both return OK, and the second overwrites sessions_[kUuid] while
// the first is live. Both detached pipelines share kUuid's 1-slot
// PoolStagingStorage lease; when one duplicate settles first, its SettleLocked
// calls ReleasePoolStagingLeases(kUuid), freeing slot 0 underneath the still-
// streaming sibling so an unrelated uuid=9202 leases the exact same host
// staging memory.
TEST(PoolReshardPushDuplicateUuidBughunt,
     ConcurrentDuplicateUuidOverwritesSessionAndAliasesLivePoolStagingSlot) {
  ReshardSenderManager manager;
  HeldPeerListener held_peer;
  auto cleanup_peers = [&]() {
    held_peer.Shutdown();
    auto survivor_or = manager.base()->GetSession(9201);
    if (survivor_or.ok()) {
      (*survivor_or)->AwaitForDone().IgnoreError();
    }
    absl::SleepFor(absl::Milliseconds(25));
  };
  struct ScopedCleanup {
    std::function<void()> fn;
    ~ScopedCleanup() { fn(); }
  } guard{cleanup_peers};

  ABSL_ASSERT_OK(manager.base()->RegisterPools({BoundedDensePool()},
                                               /*staging_leases=*/1));
  ASSERT_EQ(manager.base()->PoolStagingSummary().at(0).num_slots, 1);

  // Record the single PoolStagingStorage slot's host address up front.
  ABSL_ASSERT_OK(manager.base()->AcquirePoolStagingLease(
      /*uuid=*/9200, /*storage_idx=*/0, std::vector<int64_t>{0},
      absl::ZeroDuration()));
  const auto probe_addrs_or = manager.base()->PoolHostBaseAddrs(9200, 0);
  ASSERT_THAT(probe_addrs_or, IsOk());
  const uint64_t slot_0_addr = probe_addrs_or->host_base_addrs(0);
  manager.base()->ReleasePoolStagingLeases(9200);
  ASSERT_EQ(manager.base()->PoolStagingSummary().at(0).free_slots, 1);

  constexpr uint64_t kUuid = 9201;
  constexpr uint64_t kOtherUuid = 9202;
  const StartTransferRequest plan =
      OnePoolReshardPlan(kUuid, held_peer.endpoint(), /*block_id=*/0);

  absl::Status status_1;
  absl::Status status_2;
  std::thread call_1;
  std::thread call_2;
  {
    // Hold server_init_mu_ so both concurrent RPC threads pass the initial
    // sessions_.find(kUuid) check (:694) and line up in ReshardSendSession::
    // Create -> InitTransportServer() (:713).
    absl::MutexLock hold_init(manager.sender_base()->server_init_mu());
    call_1 = std::thread([&]() {
      status_1 = manager.PoolReshardPush(plan, std::vector<int64_t>{0});
    });
    call_2 = std::thread([&]() {
      status_2 = manager.PoolReshardPush(plan, std::vector<int64_t>{0});
    });
    absl::SleepFor(absl::Milliseconds(25));
  }
  call_1.join();
  call_2.join();

  const bool both_accepted = status_1.ok() && status_2.ok();
  EXPECT_FALSE(both_accepted)
      << "[F17] both concurrent PoolReshardPush calls for uuid=" << kUuid
      << " returned OK (missing pending_pool_reshard_sends_ reservation and "
         "sessions_[uuid] overwrite)";

  ASSERT_TRUE(held_peer.WaitForAcceptedCount(2, absl::Seconds(5)));
  ASSERT_EQ(manager.base()->PoolStagingSummary().at(0).free_slots, 0);

  // Close ONLY connection 0; connection 1's duplicate ReshardSendSession
  // remains parked mid-AsyncPush reading from slot 0.
  held_peer.CloseOne(0);
  const absl::Time wait_deadline = absl::Now() + absl::Seconds(5);
  while (manager.base()->PoolStagingSummary().at(0).free_slots == 0 &&
         absl::Now() < wait_deadline) {
    absl::SleepFor(absl::Milliseconds(1));
  }

  EXPECT_EQ(manager.base()->PoolStagingSummary().at(0).free_slots, 0)
      << "[F17] settling duplicate send freed uuid=" << kUuid
      << "'s PoolStagingStorage slot while the sibling send still has an open "
         "TCP push in flight";

  const absl::Status other_lease = manager.base()->AcquirePoolStagingLease(
      kOtherUuid, /*storage_idx=*/0, std::vector<int64_t>{3},
      absl::ZeroDuration());
  EXPECT_THAT(other_lease, StatusIs(absl::StatusCode::kResourceExhausted))
      << "[F17] unrelated uuid=" << kOtherUuid
      << " leased the 1-slot arena while uuid=" << kUuid
      << " still has an active TCP push in flight";
  if (other_lease.ok()) {
    const auto other_addrs_or =
        manager.base()->PoolHostBaseAddrs(kOtherUuid, 0);
    ASSERT_THAT(other_addrs_or, IsOk());
    EXPECT_NE(other_addrs_or->host_base_addrs(0), slot_0_addr)
        << "[F17] unrelated uuid=" << kOtherUuid
        << " received the exact host staging address (0x" << std::hex
        << slot_0_addr << ") still in flight for uuid=" << std::dec << kUuid;
    manager.base()->ReleasePoolStagingLeases(kOtherUuid);
  }
}

}  // namespace
}  // namespace tpu_raiden
