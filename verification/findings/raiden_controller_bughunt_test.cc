// Bug-hunt repros for RaidenController (scratch clone only; not upstream).
//
// F2: ReadRemote issues its pull AFTER it has already settled with
//     DeadlineExceeded. Neither the acquire callback nor PullAndRelease checks
//     RemoteReadState::settled before TransferBuffers (raiden_controller.cc
//     1034-1076, 1109-1162).
// F4: TransferBuffers auto-allocates local host staging blocks
//     (raiden_controller.cc:644) and then has early error returns
//     (:673, :722, :737, :768, :776) that never deallocate them.

#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"
#include "absl/synchronization/notification.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"
#include "xla/tsl/concurrency/future.h"
#include "xla/tsl/platform/statusor.h"
#include "tpu_sync/core/buffer.h"
#include "tpu_sync/core/controller/controller_client.h"
#include "tpu_sync/core/controller/raiden_controller.h"
#include "tpu_sync/core/controller/test_util.h"
#include "tpu_sync/core/kv_manager_holder.h"
#include "tpu_sync/core/raiden_transfer_endpoint.h"

namespace tpu_raiden {
namespace controller {
namespace {

// RemoteReadDeadline() caches its env var in a function-local static on first
// use, so set it before any test runs.
const bool kDeadlineEnvSet = [] {
  setenv("RAIDEN_REMOTE_READ_DEADLINE_S", "1", /*overwrite=*/1);
  return true;
}();

class BugHuntTest : public ::testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(kDeadlineEnvSet);
    worker_ = CreateTestWorkerServer();
    unit_.set_job_name("test_job");
    unit_.set_job_replica_id("0");
    unit_.set_data_name("test_data");
  }
  void Register(RaidenController& c, int64_t node_id = 0) {
    core::controller::RaidenControllerClient client(c.controller_address());
    auto st = client.RegisterWorker(
        "worker_0", worker_->server_address,
        {::tpu_raiden::RaidenTransferEndpoint{worker_->server_address, {}}},
        node_id);
    ASSERT_TRUE(st.ok()) << st.message();
  }
  ::tpu_sync::rpc::RaidenIdProto unit_;
  std::unique_ptr<TestWorkerServer> worker_;
};

// F2 --------------------------------------------------------------------------
TEST_F(BugHuntTest, ReadRemoteDoesNotStartPullAfterDeadlineSettled) {
  ShardAwareMockTransferManager mock;
  worker_->service->SetTransferManager(KVManagerHolder(&mock));

  auto src = core::controller::CreateTestControllerServer();
  src->service->SetReadRemoteHooks(
      [](absl::Span<const std::string> h)
          -> absl::StatusOr<std::vector<int32_t>> {
        return std::vector<int32_t>(h.size(), 42);
      },
      [](absl::Span<const std::string>) {});
  ASSERT_TRUE(src->client
                  ->RegisterWorker(
                      "src_worker_0", "src_worker_0_addr",
                      {::tpu_raiden::RaidenTransferEndpoint{"src_ep:1", {0, 1}}},
                      /*node_id=*/0)
                  .ok());
  // The source is slow to answer AcquireReadLease: 2.5 s > the 1 s deadline.
  src->service->SetLeaseGrantedHookForTest(
      [](uint64_t) { absl::SleepFor(absl::Milliseconds(2500)); });

  TF_ASSERT_OK_AND_ASSIGN(
      auto dest, RaidenController::Create(unit_, /*num_blocks=*/5,
                                          /*num_shards=*/2,
                                          /*shard_size_bytes=*/512, ""));
  Register(*dest);

  const absl::Time start = absl::Now();
  absl::Status st =
      dest->ReadRemote(src->server_address, {10}, /*dst_host_block_ids=*/{20},
                       {"h0"})
          .Await();
  const absl::Duration settled_after = absl::Now() - start;
  ASSERT_EQ(st.code(), absl::StatusCode::kDeadlineExceeded) << st;
  const int pulls_at_settle = mock.vector_h2h_read_calls + mock.h2h_read_calls;

  // The caller has been told the read FAILED, so it may now reuse block 20.
  // Give the delayed acquire time to land.
  absl::SleepFor(absl::Seconds(4));
  const int pulls_after = mock.vector_h2h_read_calls + mock.h2h_read_calls;

  std::cerr << "[F2] settled after " << settled_after
            << " with: " << st.message() << "\n"
            << "[F2] pulls issued at settle: " << pulls_at_settle
            << ", pulls issued 4s later: " << pulls_after << "\n";
  EXPECT_EQ(pulls_at_settle, 0);
  EXPECT_EQ(pulls_after, 0)
      << "A pull into dst host block 20 was issued AFTER ReadRemote settled "
         "with DeadlineExceeded.";
}

// F4 --------------------------------------------------------------------------
TEST_F(BugHuntTest, TransferBuffersErrorPathDoesNotLeakAutoStagingBlocks) {
  ShardAwareMockTransferManager mock;
  worker_->service->SetTransferManager(KVManagerHolder(&mock));
  TF_ASSERT_OK_AND_ASSIGN(
      auto controller, RaidenController::Create(unit_, /*num_blocks=*/5,
                                                /*num_shards=*/2,
                                                /*shard_size_bytes=*/512, ""));
  Register(*controller, /*node_id=*/0);
  const int locked_before = controller->block_manager()->num_locked_blocks();

  // Local HBM source -> remote DRAM destination: needs LOCAL host staging, and
  // none is supplied, so TransferBuffers auto-allocates it (:639-656). The
  // peer advertises node_id 7 only, so worker node 0 has no match (:735-741).
  ::tpu_raiden::RaidenWorkerEndpoints peer{/*node_id=*/7, "peer_w",
                                           {{"10.0.0.9:41000", {0, 1}}}};
  Buffer src(1, {}, std::nullopt, ::tpu_sync::rpc::MEMORY_TYPE_HBM);
  Buffer dst(2, {}, std::nullopt, ::tpu_sync::rpc::MEMORY_TYPE_DRAM);
  dst.set_remote_worker_endpoints({peer});

  for (int i = 0; i < 3; ++i) {
    absl::Status st = controller->TransferBuffers({src}, {dst}).Await();
    ASSERT_EQ(st.code(), absl::StatusCode::kFailedPrecondition) << st;
  }
  const int locked_after = controller->block_manager()->num_locked_blocks();
  std::cerr << "[F4] locked host blocks before: " << locked_before
            << ", after 3 failed TransferBuffers: " << locked_after << "\n";
  EXPECT_EQ(locked_after, locked_before)
      << "Each failed TransferBuffers leaked its auto-allocated staging block.";
}

// F4, problem 2 ---------------------------------------------------------------
// Fetch-shaped transfer (local DRAM -> remote DRAM, no staging involved) with
// two local workers on node 0 and node 1, but the destination advertises only
// node 0. Workers are dispatched in worker_id order, so worker_0 (node 0) is
// sent its copy job at :771 before worker_1 (node 1) fails the match at :737.
// TransferBuffers then reports failure while worker_0's job is in flight and
// un-awaited. Callers (e.g. the Fetch handler, kv_cache_store_service.cc:527)
// treat that failure as "nothing is touching my blocks any more".
TEST_F(BugHuntTest, TransferBuffersDispatchesNoWorkerWhenAnyWorkerIsUnmatched) {
  ShardAwareMockTransferManager mock0;
  ShardAwareMockTransferManager mock1;
  worker_->service->SetTransferManager(KVManagerHolder(&mock0));
  auto worker1 = CreateTestWorkerServer();
  worker1->service->SetTransferManager(KVManagerHolder(&mock1));

  TF_ASSERT_OK_AND_ASSIGN(
      auto controller, RaidenController::Create(unit_, /*num_blocks=*/5,
                                                /*num_shards=*/2,
                                                /*shard_size_bytes=*/512, ""));
  core::controller::RaidenControllerClient client(
      controller->controller_address());
  ASSERT_TRUE(client
                  .RegisterWorker("worker_0", worker_->server_address,
                                  {::tpu_raiden::RaidenTransferEndpoint{
                                      worker_->server_address, {}}},
                                  /*node_id=*/0)
                  .ok());
  ASSERT_TRUE(client
                  .RegisterWorker("worker_1", worker1->server_address,
                                  {::tpu_raiden::RaidenTransferEndpoint{
                                      worker1->server_address, {}}},
                                  /*node_id=*/1)
                  .ok());

  ::tpu_raiden::RaidenWorkerEndpoints peer{/*node_id=*/0, "peer_w0",
                                           {{"10.0.0.9:41000", {0, 1}}}};
  Buffer src(1, {}, std::nullopt, ::tpu_sync::rpc::MEMORY_TYPE_DRAM);
  Buffer dst(2, {}, std::nullopt, ::tpu_sync::rpc::MEMORY_TYPE_DRAM);
  dst.set_remote_worker_endpoints({peer});

  absl::Status st = controller->TransferBuffers({src}, {dst}).Await();
  ASSERT_EQ(st.code(), absl::StatusCode::kFailedPrecondition) << st;

  // The call has already reported failure. Give any job that was sent before
  // the failure time to reach the worker, then count what arrived.
  const absl::Time deadline = absl::Now() + absl::Seconds(2);
  while (mock0.vector_h2h_write_calls == 0 && absl::Now() < deadline) {
    absl::SleepFor(absl::Milliseconds(10));
  }
  std::cerr << "[F4-P2] TransferBuffers returned: " << st.message() << "\n"
            << "[F4-P2] copy jobs workers received for this failed transfer: "
            << "worker_0=" << mock0.vector_h2h_write_calls
            << " worker_1=" << mock1.vector_h2h_write_calls << "\n";
  EXPECT_EQ(mock0.vector_h2h_write_calls, 0)
      << "worker_0 was sent a copy for a transfer that TransferBuffers "
         "reported as failed; nobody awaits that copy.";
  EXPECT_EQ(mock1.vector_h2h_write_calls, 0);
}

}  // namespace
}  // namespace controller
}  // namespace tpu_raiden
