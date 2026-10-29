// Reproducers for two source-side remote-write settlement defects in
// KVCacheStore / HostOffloadBackend (introduced with the async remote-write
// settlement in upstream commit 22a8bf22; checked at 42dda542).
//
// Each test FAILS on the unmodified code; the failure is the defect.
//
// 2a. KVCacheStore::SaveRemote records every offer in active_remote_writes_.
//     TakeRemoteWrite is called only on the synchronous exits (ack error,
//     all/partial-exist). An accepted offer (operation_id != 0) settles inside
//     HostOffloadBackend::BeginWriteRemote's call.result.OnReady continuation,
//     which releases the pins and publishes the verdict but never tells the
//     store, so the entry is never erased. ~KVCacheStore later walks the
//     leaked entry and calls OnWriteRemoteVerdict(state, false), which
//     releases the (already released) internal pin a second time -- stealing
//     a pin from whoever holds one on a backend that can outlive the store.
//
// 2b. In the same continuation, a result of CANCELLED returns early with the
//     backend still alive: no Release, no tracker verdict, no poll. When the
//     destination ends the stream with CANCELLED after its ack (the server
//     reactor's OnCancel -> Finish(CANCELLED) path, or a destination going
//     away), the internal pin leaks and the hashes stay pending forever (only
//     the store's destructor, via the 2a leak, ever settles them).
//
// Harness: an in-process GlobalRegistry and an in-process fake destination
// KVCacheStoreService on localhost, as the upstream RemoteWriteSourceTest
// does. Hardware-free and deterministic.

#include <chrono>  // NOLINT(build/c++11)
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/base/thread_annotations.h"
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/synchronization/mutex.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"
#include "grpcpp/channel.h"
#include "grpcpp/create_channel.h"
#include "grpcpp/security/credentials.h"
#include "grpcpp/security/server_credentials.h"
#include "grpcpp/server.h"
#include "grpcpp/server_builder.h"
#include "grpcpp/server_context.h"
#include "grpcpp/support/server_callback.h"
#include "grpcpp/support/status.h"
#include "tpu_sync/common/raiden_id.h"
#include "tpu_sync/kv_cache/global_registry/global_registry_client.h"
#include "tpu_sync/kv_cache/global_registry/global_registry_server.h"
#include "tpu_sync/kv_cache/kv_cache_store.h"
#include "tpu_sync/kv_cache/kv_cache_store_backend.h"
#include "tpu_sync/proto/kv_cache_store_service.grpc.pb.h"

namespace tpu_raiden {
namespace kv_cache {
namespace {

// How the fake destination ends an accepted offer.
enum class DestinationMode {
  // Ack, then stream a COMMITTED result and finish OK.
  kCommit,
  // Ack, then finish the stream with CANCELLED and no result.
  kCancelAfterAck,
  // Ack, then finish the stream with UNAVAILABLE and no result (control).
  kUnavailableAfterAck,
};

class FakeDestination
    : public ::tpu_raiden::kv_cache::proto::KVCacheStoreService::
          CallbackService {
 public:
  static constexpr uint64_t kOperationId = 777;

  explicit FakeDestination(DestinationMode mode) : mode_(mode) {}

  class Reactor : public ::grpc::ServerWriteReactor<proto::WriteRemoteEvent> {
   public:
    Reactor(DestinationMode mode, int64_t deadline_ms) : mode_(mode) {
      auto* ack = ack_.mutable_ack();
      ack->set_operation_id(kOperationId);
      ack->set_exist_state(proto::WRITE_EXIST_STATE_UNSPECIFIED);
      ack->set_granted_deadline_ms(deadline_ms);
      result_.mutable_result()->set_state(
          proto::PollWriteRemoteResponse::COMMITTED);
      StartWrite(&ack_);
    }

    void OnWriteDone(bool ok) override {
      if (!ok) {
        Done(::grpc::Status(::grpc::StatusCode::CANCELLED, "write failed"));
        return;
      }
      {
        absl::MutexLock lock(mu_);
        if (ack_written_) {
          return;  // The result write; StartWriteAndFinish finishes the call.
        }
        ack_written_ = true;
      }
      switch (mode_) {
        case DestinationMode::kCommit: {
          absl::MutexLock lock(mu_);
          finished_ = true;
          StartWriteAndFinish(&result_, ::grpc::WriteOptions(),
                              ::grpc::Status::OK);
          break;
        }
        case DestinationMode::kCancelAfterAck:
          Done(::grpc::Status(::grpc::StatusCode::CANCELLED,
                              "destination cancelled the offer"));
          break;
        case DestinationMode::kUnavailableAfterAck:
          Done(::grpc::Status(::grpc::StatusCode::UNAVAILABLE,
                              "destination went away"));
          break;
      }
    }

    void OnCancel() override { Done(::grpc::Status::CANCELLED); }
    void OnDone() override { delete this; }

   private:
    void Done(::grpc::Status status) {
      {
        absl::MutexLock lock(mu_);
        if (finished_) return;
        finished_ = true;
      }
      Finish(status);
    }

    const DestinationMode mode_;
    absl::Mutex mu_;
    proto::WriteRemoteEvent ack_;
    proto::WriteRemoteEvent result_;
    bool ack_written_ ABSL_GUARDED_BY(mu_) = false;
    bool finished_ ABSL_GUARDED_BY(mu_) = false;
  };

  ::grpc::ServerWriteReactor<proto::WriteRemoteEvent>* WriteRemote(
      ::grpc::CallbackServerContext* /*context*/,
      const proto::WriteRemoteRequest* request) override {
    absl::MutexLock lock(mu_);
    ++write_calls_;
    return new Reactor(mode_, request->deadline_ms());
  }

  // Polls (only reached on the non-CANCELLED error path) answer FAILED.
  ::grpc::ServerUnaryReactor* PollWriteRemote(
      ::grpc::CallbackServerContext* context,
      const proto::PollWriteRemoteRequest* /*request*/,
      proto::PollWriteRemoteResponse* response) override {
    auto* reactor = context->DefaultReactor();
    {
      absl::MutexLock lock(mu_);
      ++poll_calls_;
    }
    response->set_state(proto::PollWriteRemoteResponse::FAILED);
    reactor->Finish(::grpc::Status::OK);
    return reactor;
  }

  int write_calls() const {
    absl::MutexLock lock(mu_);
    return write_calls_;
  }
  int poll_calls() const {
    absl::MutexLock lock(mu_);
    return poll_calls_;
  }

 private:
  const DestinationMode mode_;
  mutable absl::Mutex mu_;
  int write_calls_ ABSL_GUARDED_BY(mu_) = 0;
  int poll_calls_ ABSL_GUARDED_BY(mu_) = 0;
};

class RemoteWriteSettlementTest : public ::testing::Test {
 protected:
  void SetUp() override {
    registry_service_ =
        std::make_unique<global_registry::GlobalRegistryServiceImpl>();
    grpc::ServerBuilder builder;
    int port = 0;
    builder.AddListeningPort("localhost:0", grpc::InsecureServerCredentials(),
                             &port);
    builder.RegisterService(registry_service_.get());
    registry_server_ = builder.BuildAndStart();
    ASSERT_NE(registry_server_, nullptr);
    registry_address_ = "localhost:" + std::to_string(port);
    registry_client_ = std::make_unique<global_registry::GlobalRegistryClient>(
        grpc::CreateChannel(registry_address_,
                            grpc::InsecureChannelCredentials()));
  }

  void TearDown() override {
    if (destination_server_) {
      destination_server_->Shutdown(std::chrono::system_clock::now() +
                                    std::chrono::milliseconds(200));
    }
    registry_client_.reset();
    if (registry_server_) {
      registry_server_->Shutdown(std::chrono::system_clock::now() +
                                 std::chrono::milliseconds(200));
    }
    unsetenv("RAIDEN_REMOTE_WRITE_HOLD_S");
  }

  std::unique_ptr<KVCacheStore> MakeStore(const RaidenId& id) {
    return std::make_unique<KVCacheStore>(
        /*capacity=*/8, registry_address_, id, /*num_shards=*/1,
        /*shard_size_bytes=*/1024, /*store_server_ip=*/"127.0.0.1",
        /*raiden_controller_port=*/0);
  }

  // Host-resident and pinned once (the caller's pin a remote save consumes).
  static void Populate(KVCacheStore& store, const RaidenId& id,
                       const std::vector<std::string>& hashes) {
    std::vector<RaidenBlockId> slices;
    for (size_t i = 0; i < hashes.size(); ++i) {
      slices.push_back(
          RaidenBlockId(id, static_cast<int>(i), BlockStatus::HOST));
    }
    ABSL_ASSERT_OK(store.Insert(hashes, slices, /*on_host=*/true));
  }

  void StartDestination(const RaidenId& dst, DestinationMode mode) {
    destination_ = std::make_unique<FakeDestination>(mode);
    grpc::ServerBuilder builder;
    int port = 0;
    builder.AddListeningPort("127.0.0.1:0", grpc::InsecureServerCredentials(),
                             &port);
    builder.RegisterService(destination_.get());
    destination_server_ = builder.BuildAndStart();
    ASSERT_NE(destination_server_, nullptr);
    ABSL_ASSERT_OK(registry_client_->RegisterStore(
        dst, "127.0.0.1:" + std::to_string(port)));
  }

  // Polls PollSaveStatus until nothing is pending and a verdict arrived, or
  // `timeout` passes. Returns {done, failed, still_pending_at_end}.
  static std::tuple<std::vector<std::string>, std::vector<std::string>, bool>
  AwaitSettled(KVCacheStore& store, absl::Duration timeout) {
    std::vector<std::string> done_all, failed_all;
    const absl::Time end = absl::Now() + timeout;
    bool pending_now = true;
    while (absl::Now() < end) {
      auto [done, failed, pending, existing, unregistered] =
          store.PollSaveStatus();
      done_all.insert(done_all.end(), done.begin(), done.end());
      failed_all.insert(failed_all.end(), failed.begin(), failed.end());
      pending_now = !pending.empty();
      if (!pending_now && (!done_all.empty() || !failed_all.empty())) {
        break;
      }
      absl::SleepFor(absl::Milliseconds(20));
    }
    return {done_all, failed_all, pending_now};
  }

  std::string registry_address_;
  std::unique_ptr<global_registry::GlobalRegistryServiceImpl>
      registry_service_;
  std::unique_ptr<grpc::Server> registry_server_;
  std::unique_ptr<global_registry::GlobalRegistryClient> registry_client_;
  std::unique_ptr<FakeDestination> destination_;
  std::unique_ptr<grpc::Server> destination_server_;
};

// 2a(i): an accepted remote write that commits must leave no in-flight entry
// behind once its verdict has been delivered.
TEST_F(RemoteWriteSettlementTest,
       AcceptedCommittedWriteIsErasedFromActiveRemoteWrites) {
  RaidenId src{"bh_rw_src_a", "0", "kv", 0};
  RaidenId dst{"bh_rw_dst_a", "0", "kv", 0};
  auto store = MakeStore(src);
  Populate(*store, src, {"a"});
  StartDestination(dst, DestinationMode::kCommit);

  ASSERT_EQ(store->GetPinCount("a"), 1);
  ABSL_ASSERT_OK(store->Save({"a"}, dst));
  auto [done, failed, pending] = AwaitSettled(*store, absl::Seconds(10));
  ASSERT_THAT(done, ::testing::ElementsAre("a"));
  ASSERT_TRUE(failed.empty());
  ASSERT_FALSE(pending);
  // Both the internal and the caller's pin were spent by the commit.
  ASSERT_EQ(store->GetPinCount("a"), 0);

  EXPECT_EQ(store->InFlightRemoteWritesCountForTesting(), 0u)
      << "the accepted operation settled (verdict delivered, pins released) "
         "but its active_remote_writes_ entry was never erased";
}

// 2a(ii): the leaked entry makes ~KVCacheStore release the internal pin a
// second time, taking a pin that belongs to someone else on a backend that
// outlives the store.
TEST_F(RemoteWriteSettlementTest,
       DestroyingTheStoreAfterSettlementDoesNotStealALivePin) {
  RaidenId src{"bh_rw_src_b", "0", "kv", 0};
  RaidenId dst{"bh_rw_dst_b", "0", "kv", 0};
  auto store = MakeStore(src);
  Populate(*store, src, {"a"});
  StartDestination(dst, DestinationMode::kCommit);

  ABSL_ASSERT_OK(store->Save({"a"}, dst));
  auto [done, failed, pending] = AwaitSettled(*store, absl::Seconds(10));
  ASSERT_THAT(done, ::testing::ElementsAre("a"));
  ASSERT_EQ(store->GetPinCount("a"), 0);

  // Someone (a reader, a later Lookup) pins the block again. The backend is
  // shared and outlives the store.
  std::shared_ptr<KVCacheStoreBackend> backend = store->backend();
  ASSERT_NE(backend, nullptr);
  ASSERT_TRUE(backend->Pin({"a"}));
  ASSERT_EQ(backend->GetPinCount("a"), 1);

  store.reset();

  EXPECT_EQ(backend->GetPinCount("a"), 1)
      << "~KVCacheStore released the settled operation's internal pin a "
         "second time, dropping a pin it does not own";
}

// 2b: the destination acks, then ends the result stream with CANCELLED. The
// source must still settle the operation within its HOLD window: drop the
// internal pin and report the hash as failed (it cannot know the outcome).
TEST_F(RemoteWriteSettlementTest,
       CancelledResultStreamAfterAckSettlesWithinTheHold) {
  // Shortest legal HOLD (must exceed the 5 s margin) to bound the wait.
  setenv("RAIDEN_REMOTE_WRITE_HOLD_S", "6", /*overwrite=*/1);
  RaidenId src{"bh_rw_src_c", "0", "kv", 0};
  RaidenId dst{"bh_rw_dst_c", "0", "kv", 0};
  auto store = MakeStore(src);
  Populate(*store, src, {"a"});
  StartDestination(dst, DestinationMode::kCancelAfterAck);

  ABSL_ASSERT_OK(store->Save({"a"}, dst));
  ASSERT_EQ(destination_->write_calls(), 1);

  // HOLD (6 s) plus slack.
  auto [done, failed, pending] = AwaitSettled(*store, absl::Seconds(9));

  EXPECT_FALSE(pending)
      << "hash still pending in the save tracker after the HOLD window: the "
         "CANCELLED result was dropped without a verdict";
  EXPECT_THAT(failed, ::testing::ElementsAre("a"));
  EXPECT_EQ(store->GetPinCount("a"), 1)
      << "the internal pin (2 = caller + internal) was never released after "
         "the destination cancelled the stream";
}

// Control for 2b: the same shape with UNAVAILABLE instead of CANCELLED takes
// the poll path and settles (expected to PASS on unmodified code).
TEST_F(RemoteWriteSettlementTest,
       ControlUnavailableResultStreamAfterAckSettles) {
  setenv("RAIDEN_REMOTE_WRITE_HOLD_S", "6", /*overwrite=*/1);
  RaidenId src{"bh_rw_src_d", "0", "kv", 0};
  RaidenId dst{"bh_rw_dst_d", "0", "kv", 0};
  auto store = MakeStore(src);
  Populate(*store, src, {"a"});
  StartDestination(dst, DestinationMode::kUnavailableAfterAck);

  ABSL_ASSERT_OK(store->Save({"a"}, dst));
  auto [done, failed, pending] = AwaitSettled(*store, absl::Seconds(9));

  EXPECT_FALSE(pending);
  EXPECT_THAT(failed, ::testing::ElementsAre("a"));
  EXPECT_EQ(store->GetPinCount("a"), 1);
  EXPECT_GE(destination_->poll_calls(), 1);
}

}  // namespace
}  // namespace kv_cache
}  // namespace tpu_raiden
