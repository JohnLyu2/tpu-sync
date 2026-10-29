// Reproducers for remote-load (Fetch) lifetime defects in KVCacheStoreClient /
// HostOffloadBackend, checked at upstream 42dda542.
//
// 3a. KVCacheStoreClient::Fetch never sets a deadline on its ClientContext
//     (WriteRemote and PollWriteRemote both do). HostOffloadBackend::
//     LoadRemoteBlocks allocates the destination host blocks before calling
//     Fetch and frees them only from the Fetch continuation, and nothing above
//     it (KVCacheStore::ReadRemote / Load, PollLoadStatus, the Python API)
//     applies a timeout. A source that accepts the call and never answers
//     therefore pins the destination host blocks and leaves the hashes
//     pending in the load tracker -- and refuses a retry of the same hashes
//     ("already loading") -- for as long as the source stays silent.
//
// 3b. When Fetch fails, LoadRemoteBlocks returns the destination host block
//     ids to the controller's ledger at once, although the source's workers
//     may still be pushing into them: the source pushes with a planless
//     explicit-destination push (op 6, uuid 0), and the receiving worker only
//     bounds-checks the destination block id. These tests cover the two
//     halves separately:
//       (i)  LoadRemoteBlocks frees the ids handed to the source as soon as
//            Fetch fails, and the very same ids are handed out again;
//       (ii) a receiving worker accepts a uuid-0 explicit push into a block
//            id that its own LogicalBlockManager has freed and reallocated to
//            a new owner, overwriting the new owner's bytes.
//     The end-to-end interleaving (a Fetch RPC failing while the source's
//     TransferBuffers is still running) is not driven here.
//
// Hardware-free: in-process GlobalRegistry, fake KVCacheStoreService, and two
// in-process KVCacheManagerWithTransfer workers over loopback BlockTransport.

#include <chrono>  // NOLINT(build/c++11)
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/algorithm/container.h"
#include "absl/base/thread_annotations.h"
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_cat.h"
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
#include "tpu_sync/core/controller/raiden_controller.h"
#include "tpu_sync/kv_cache/global_registry/global_registry_client.h"
#include "tpu_sync/kv_cache/global_registry/global_registry_server.h"
#include "tpu_sync/kv_cache/kv_cache_manager_base.h"
#include "tpu_sync/kv_cache/kv_cache_manager_with_transfer.h"
#include "tpu_sync/kv_cache/kv_cache_store.h"
#include "tpu_sync/kv_cache/kv_cache_store_client.h"
#include "tpu_sync/kv_cache/logical_block_manager.h"
#include "tpu_sync/proto/kv_cache_store_service.grpc.pb.h"
#include "tpu_sync/rpc/raiden_service.pb.h"

namespace tpu_raiden {
namespace kv_cache {
namespace {

enum class FetchMode {
  // Accept the call and never answer (until the server shuts down).
  kHang,
  // Fail at once, as a broken or cancelled control-plane call would.
  kFailUnavailable,
};

// A source store that records what each Fetch asked for and either hangs or
// fails. A hung call is finished only when gRPC cancels it (client cancel or
// server shutdown).
class FakeFetchSource
    : public ::tpu_raiden::kv_cache::proto::KVCacheStoreService::
          CallbackService {
 public:
  explicit FakeFetchSource(FetchMode mode) : mode_(mode) {}

  class HangingReactor : public ::grpc::ServerUnaryReactor {
   public:
    void OnCancel() override { Finish(::grpc::Status::CANCELLED); }
    void OnDone() override { delete this; }
  };

  ::grpc::ServerUnaryReactor* Fetch(
      ::grpc::CallbackServerContext* context,
      const proto::FetchRequest* request,
      proto::FetchResponse* /*response*/) override {
    {
      absl::MutexLock lock(mu_);
      ++fetch_calls_;
      deadline_ = context->deadline();
      host_block_ids_.assign(request->host_block_ids().begin(),
                             request->host_block_ids().end());
    }
    if (mode_ == FetchMode::kHang) {
      return new HangingReactor();
    }
    auto* reactor = context->DefaultReactor();
    reactor->Finish(::grpc::Status(::grpc::StatusCode::UNAVAILABLE,
                                   "source control channel broke"));
    return reactor;
  }

  bool AwaitCall(absl::Duration timeout) {
    absl::MutexLock lock(mu_);
    return mu_.AwaitWithTimeout(
        absl::Condition(
            +[](int* calls) { return *calls > 0; }, &fetch_calls_),
        timeout);
  }
  std::chrono::system_clock::time_point deadline() const {
    absl::MutexLock lock(mu_);
    return deadline_;
  }
  std::vector<int32_t> host_block_ids() const {
    absl::MutexLock lock(mu_);
    return host_block_ids_;
  }

 private:
  const FetchMode mode_;
  mutable absl::Mutex mu_;
  int fetch_calls_ ABSL_GUARDED_BY(mu_) = 0;
  std::chrono::system_clock::time_point deadline_ ABSL_GUARDED_BY(mu_);
  std::vector<int32_t> host_block_ids_ ABSL_GUARDED_BY(mu_);
};

class FetchLifetimeTest : public ::testing::Test {
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
    if (source_server_) {
      source_server_->Shutdown(std::chrono::system_clock::now() +
                               std::chrono::milliseconds(200));
    }
    registry_client_.reset();
    if (registry_server_) {
      registry_server_->Shutdown(std::chrono::system_clock::now() +
                                 std::chrono::milliseconds(200));
    }
  }

  // Starts the fake source and returns its address; publishes it under `id`
  // if `id` is non-empty.
  std::string StartSource(FetchMode mode, const RaidenId& id) {
    source_ = std::make_unique<FakeFetchSource>(mode);
    grpc::ServerBuilder builder;
    int port = 0;
    builder.AddListeningPort("127.0.0.1:0", grpc::InsecureServerCredentials(),
                             &port);
    builder.RegisterService(source_.get());
    source_server_ = builder.BuildAndStart();
    EXPECT_NE(source_server_, nullptr);
    const std::string address = "127.0.0.1:" + std::to_string(port);
    if (!id.empty()) {
      EXPECT_TRUE(registry_client_->RegisterStore(id, address).ok());
    }
    return address;
  }

  std::unique_ptr<KVCacheStore> MakeStore(const RaidenId& id) {
    return std::make_unique<KVCacheStore>(
        /*capacity=*/8, registry_address_, id, /*num_shards=*/1,
        /*shard_size_bytes=*/1024, /*store_server_ip=*/"127.0.0.1",
        /*raiden_controller_port=*/0);
  }

  std::string registry_address_;
  std::unique_ptr<global_registry::GlobalRegistryServiceImpl>
      registry_service_;
  std::unique_ptr<grpc::Server> registry_server_;
  std::unique_ptr<global_registry::GlobalRegistryClient> registry_client_;
  std::unique_ptr<FakeFetchSource> source_;
  std::unique_ptr<grpc::Server> source_server_;
};

// 3a(i): the Fetch RPC must carry a deadline. The server sees the client's
// deadline; an infinite one (no set_deadline) maps to time_point::max().
TEST_F(FetchLifetimeTest, FetchRpcCarriesAClientDeadline) {
  const std::string address = StartSource(FetchMode::kHang, RaidenId{});
  KVCacheStoreClient client(
      grpc::CreateChannel(address, grpc::InsecureChannelCredentials()));
  ::tpu_sync::rpc::RaidenIdProto me;
  me.set_job_name("bh_fetch_client");
  auto future = client.Fetch({"h"}, /*device_block_ids=*/{0},
                             /*host_block_ids=*/{0}, me,
                             /*client_worker_endpoints=*/{});
  ASSERT_TRUE(source_->AwaitCall(absl::Seconds(5)));

  EXPECT_NE(source_->deadline(), std::chrono::system_clock::time_point::max())
      << "KVCacheStoreClient::Fetch sent the call with no deadline";

  // Bounded observation: with no deadline the future cannot resolve while the
  // source stays silent.
  const absl::Duration kObserve = absl::Seconds(12);
  const absl::Time end = absl::Now() + kObserve;
  while (absl::Now() < end && !future.IsReady()) {
    absl::SleepFor(absl::Milliseconds(100));
  }
  std::cout << "[observation] client Fetch future "
            << (future.IsReady() ? "resolved" : "still pending") << " after "
            << kObserve << std::endl;
  EXPECT_TRUE(future.IsReady())
      << "Fetch against a silent source is still pending after " << kObserve;
}

// 3a(ii): through the store. A silent source keeps the hash pending in the
// load tracker, keeps the destination host block allocated, and blocks a
// retry of the same hash.
TEST_F(FetchLifetimeTest, SilentSourceWedgesReadRemoteAndItsHostBlocks) {
  RaidenId me{"bh_fetch_dst_a", "0", "kv", 0};
  RaidenId src{"bh_fetch_src_a", "0", "kv", 0};
  StartSource(FetchMode::kHang, src);
  auto store = MakeStore(me);
  controller::RaidenController* controller = store->raiden_controller();
  ASSERT_NE(controller, nullptr);
  const int free_before = controller->num_free_blocks();

  ABSL_ASSERT_OK(store->ReadRemote({"h"},
                                   {RaidenBlockId(src, 3, BlockStatus::REMOTE)},
                                   /*device_block_ids=*/{0}));
  ASSERT_TRUE(source_->AwaitCall(absl::Seconds(5)));
  ASSERT_EQ(controller->num_free_blocks(), free_before - 1);

  const absl::Duration kObserve = absl::Seconds(12);
  const absl::Time end = absl::Now() + kObserve;
  bool settled = false;
  while (absl::Now() < end && !settled) {
    auto [done, failed, pending] = store->PollRemoteReadStatus();
    settled = !done.empty() || !failed.empty();
    if (!settled) absl::SleepFor(absl::Milliseconds(100));
  }
  auto [done, failed, pending] = store->PollRemoteReadStatus();
  const int free_after = controller->num_free_blocks();
  auto retry = store->ReadRemote(
      {"h"}, {RaidenBlockId(src, 3, BlockStatus::REMOTE)}, {0});
  std::cout << "[observation] after " << kObserve << ": settled=" << settled
            << " pending=" << pending.size() << " free_host_blocks="
            << free_after << "/" << free_before
            << " retry=" << retry.ToString() << std::endl;

  EXPECT_TRUE(settled) << "the remote read is still pending after "
                       << kObserve << " against a silent source";
  EXPECT_EQ(free_after, free_before)
      << "the destination host block is still allocated after " << kObserve;
  EXPECT_FALSE(absl::IsFailedPrecondition(retry))
      << "a retry of the same hash is refused as already loading: "
      << retry.ToString();
}

// 3b(i): when Fetch fails, the destination host block ids that were handed to
// the source go straight back to the ledger and are handed out again, while
// the source may still be pushing into them.
TEST_F(FetchLifetimeTest, FailedFetchFreesTheDestinationBlocksAtOnce) {
  RaidenId me{"bh_fetch_dst_b", "0", "kv", 0};
  RaidenId src{"bh_fetch_src_b", "0", "kv", 0};
  StartSource(FetchMode::kFailUnavailable, src);
  auto store = MakeStore(me);
  controller::RaidenController* controller = store->raiden_controller();
  ASSERT_NE(controller, nullptr);
  const int free_before = controller->num_free_blocks();

  ABSL_ASSERT_OK(store->ReadRemote({"h"},
                                   {RaidenBlockId(src, 3, BlockStatus::REMOTE)},
                                   /*device_block_ids=*/{0}));
  ASSERT_TRUE(source_->AwaitCall(absl::Seconds(5)));
  const std::vector<int32_t> handed_to_source = source_->host_block_ids();
  ASSERT_EQ(handed_to_source.size(), 1u);

  bool failed_seen = false;
  for (int i = 0; i < 300 && !failed_seen; ++i) {
    auto [done, failed, pending] = store->PollRemoteReadStatus();
    failed_seen = !failed.empty();
    if (!failed_seen) absl::SleepFor(absl::Milliseconds(10));
  }
  ASSERT_TRUE(failed_seen);

  // The next allocations (any new owner) can receive the very block the
  // source was told to write into.
  auto reallocated = controller->AllocateBlockIds(controller->num_free_blocks());
  ASSERT_TRUE(reallocated.ok()) << reallocated.status();
  std::cout << "[observation] free before=" << free_before
            << " handed_to_source=" << handed_to_source[0]
            << " reallocated_count=" << reallocated->size() << std::endl;
  EXPECT_FALSE(absl::c_linear_search(*reallocated, handed_to_source[0]))
      << "host block " << handed_to_source[0]
      << " was handed to the source as a push destination, freed when "
         "Fetch failed, and handed out again while the source may still be "
         "writing into it";
  ABSL_EXPECT_OK(controller->DeallocateBlockIds(*reallocated));
}

// 3b(ii): the receiving worker accepts a planless explicit-destination push
// (op 6, uuid 0) into a block id it has freed and given to a new owner, and
// the late push overwrites the new owner's bytes. The worker only
// bounds-checks the id; there is no lease, generation or allocation check.
TEST(FetchPushAfterFreeTest, LatePlanlessPushOverwritesAReallocatedBlock) {
  constexpr size_t kSliceBytes = 128;
  KVCacheManagerWithTransfer source(
      /*num_layers=*/1, /*num_shards=*/1, kSliceBytes,
      /*local_port=*/0, /*host_blocks_to_allocate=*/4,
      /*parallelism=*/1, /*node_id=*/0, /*local_control_port=*/-1,
      /*max_blocks=*/1, /*num_slots=*/1, /*timeout_s=*/10.0);
  KVCacheManagerWithTransfer receiver(
      /*num_layers=*/1, /*num_shards=*/1, kSliceBytes,
      /*local_port=*/0, /*host_blocks_to_allocate=*/4,
      /*parallelism=*/1, /*node_id=*/1, /*local_control_port=*/-1,
      /*max_blocks=*/1, /*num_slots=*/1, /*timeout_s=*/10.0);
  LogicalBlockManager* ledger = receiver.base()->host_block_manager();
  ASSERT_NE(ledger, nullptr);

  // The Fetch's destination block: allocated, handed to the source, then
  // freed when the Fetch RPC fails.
  auto fetch_dst = ledger->Allocate(1, /*lock=*/true);
  ASSERT_TRUE(fetch_dst.ok()) << fetch_dst.status();
  const int block = (*fetch_dst)[0];
  ABSL_ASSERT_OK(ledger->Deallocate({block}));
  ASSERT_FALSE(ledger->IsAllocated(block));

  // A new owner takes the same block and fills it.
  ABSL_ASSERT_OK(ledger->AllocateTarget({block}));
  std::memset(receiver.base()->GetBlockHostPointer(0, 0, block), 0x11,
              kSliceBytes);

  // The source's push for the failed Fetch arrives late.
  std::memset(source.base()->GetBlockHostPointer(0, 0, 0), 0xA5, kSliceBytes);
  const std::string peer =
      absl::StrCat("127.0.0.1:", *receiver.base()->local_port());
  absl::StatusOr<std::vector<int>> late = source.base()->H2hWriteDirect(
      peer, /*src_block_ids=*/{0}, /*dst_block_ids=*/{block}, /*uuid=*/0);
  const uint8_t first_byte =
      receiver.base()->GetBlockHostPointer(0, 0, block)[0];
  std::cout << "[observation] late push status=" << late.status()
            << " new owner's first byte=0x" << std::hex
            << static_cast<int>(first_byte) << std::dec << std::endl;

  EXPECT_FALSE(late.ok())
      << "a planless uuid-0 push into a freed-and-reallocated block was "
         "accepted";
  EXPECT_EQ(first_byte, 0x11)
      << "the late push overwrote the new owner's bytes";

  // Same acceptance with the block left unallocated.
  ABSL_ASSERT_OK(ledger->Deallocate({block}));
  ASSERT_FALSE(ledger->IsAllocated(block));
  auto into_free = source.base()->H2hWriteDirect(
      peer, /*src_block_ids=*/{0}, /*dst_block_ids=*/{block}, /*uuid=*/0);
  EXPECT_FALSE(into_free.ok())
      << "a planless uuid-0 push into an unallocated block was accepted";
}

}  // namespace
}  // namespace kv_cache
}  // namespace tpu_raiden
