// Stress check for WriteRemoteServerReactor (kv_cache_store_service.cc) at
// upstream 42dda542: StartAck vs OnCancel.
//
// Claim under test: StartAck checks `finished_` under the reactor's mutex,
// unlocks, then calls StartWrite(&ack_event_). OnCancel runs on a gRPC thread
// without the gate mutex and calls FinishWithError(CANCELLED) -> Finish()
// whenever !finished_. If OnCancel could run between the unlock and the
// StartWrite, the ack would be a write after Finish.
//
// Analysis (gRPC 1.81.0, see the report): KVCacheStoreServiceImpl::WriteRemote
// calls StartAck from inside the method handler, before the reactor is
// returned. Until CallbackServerStreamingHandler::RunHandler calls
// SetupReactor, the writer is not bound: StartWrite only records the write in
// the reactor's pre-bind backlog, and OnCancel is gated on two conditions
// (cancellation AND SetupReactor), so it cannot run before the backlog has
// been flushed. A Finish while the ack write is outstanding is a legal
// ordering (separate core batches; the write completes and OnWriteDone runs
// before OnDone). This test exercises the race empirically: many accepted
// offers, each cancelled by the client after a short, varied delay. A crash,
// gRPC "API misuse" CHECK, hang, or TSan report would refute the analysis.

#include <chrono>  // NOLINT(build/c++11)
#include <cstdint>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include <gtest/gtest.h>
#include "absl/base/thread_annotations.h"
#include "absl/status/status.h"
#include "absl/strings/str_cat.h"
#include "absl/synchronization/mutex.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"
#include "absl/types/span.h"
#include "xla/tsl/concurrency/future.h"
#include "tpu_sync/core/buffer.h"
#include "tpu_sync/kv_cache/kv_cache_store_service.h"
#include "grpcpp/create_channel.h"
#include "grpcpp/security/credentials.h"
#include "grpcpp/security/server_credentials.h"
#include "grpcpp/server.h"
#include "grpcpp/server_builder.h"
#include "tpu_sync/common/raiden_id.h"
#include "tpu_sync/kv_cache/global_registry/global_registry_server.h"
#include "tpu_sync/kv_cache/kv_cache_store.h"
#include "tpu_sync/kv_cache/kv_cache_store_client.h"
#include "tpu_sync/proto/worker_service.pb.h"
#include "tpu_sync/rpc/raiden_service.pb.h"

namespace tpu_raiden {
namespace kv_cache {
namespace {

TEST(WriteRemoteReactorStressTest, ClientCancelRacingTheAckNeverMisusesGrpc) {
  global_registry::GlobalRegistryServiceImpl registry;
  grpc::ServerBuilder builder;
  int port = 0;
  builder.AddListeningPort("localhost:0", grpc::InsecureServerCredentials(),
                           &port);
  builder.RegisterService(&registry);
  auto registry_server = builder.BuildAndStart();
  ASSERT_NE(registry_server, nullptr);
  const std::string registry_address = "localhost:" + std::to_string(port);

  int accepted = 0, refused = 0, cancelled = 0, other = 0;
  {
    RaidenId dst{"bh_reactor_dst", "0", "kv", 0};
    KVCacheStore store(/*capacity=*/64, registry_address, dst,
                       /*num_shards=*/1, /*shard_size_bytes=*/1024,
                       /*store_server_ip=*/"127.0.0.1",
                       /*raiden_controller_port=*/0);
    ASSERT_FALSE(store.store_server_address().empty());
    KVCacheStoreClient client(grpc::CreateChannel(
        store.store_server_address(), grpc::InsecureChannelCredentials()));

    ::tpu_sync::rpc::RaidenIdProto src;
    src.set_job_name("bh_reactor_src");
    src.set_job_replica_id("0");
    src.set_data_name("kv");
    ::tpu_sync::proto::RaidenWorkerEndpointsProto group;
    group.set_node_id(0);
    group.set_worker_id("w0");
    group.add_endpoints()->set_endpoint("127.0.0.1:1");
    const std::vector<::tpu_sync::proto::RaidenWorkerEndpointsProto> endpoints =
        {group};

    const int kIterations = 2000;
    const int kDelaysUs[] = {0, 0, 5, 20, 50, 100, 200, 500};
    for (int i = 0; i < kIterations; ++i) {
      const std::string hash = absl::StrCat("h", i);
      auto call = client.WriteRemote(src, {hash}, {0}, endpoints,
                                     /*deadline_ms=*/5000,
                                     /*hold_window=*/absl::Seconds(10),
                                     /*tracker=*/nullptr);
      ASSERT_NE(call.cancel, nullptr);
      const int delay = kDelaysUs[i % (sizeof(kDelaysUs) / sizeof(int))];
      if (delay > 0) absl::SleepFor(absl::Microseconds(delay));
      call.cancel->TryCancel();
      auto ack = call.ack.Await();
      if (ack.ok()) {
        ++accepted;
      } else if (absl::IsCancelled(ack.status())) {
        ++cancelled;
      } else if (absl::IsResourceExhausted(ack.status())) {
        ++refused;
      } else {
        ++other;
      }
      // Every call must end on the client side.
      (void)call.result.Await();
    }
  }  // Store destruction: the service must finish every reactor.
  std::cout << "[observation] acked=" << accepted
            << " cancelled_before_ack=" << cancelled
            << " refused=" << refused << " other=" << other << std::endl;
  EXPECT_GT(accepted + cancelled, 0);
  registry_server->Shutdown(std::chrono::system_clock::now() +
                            std::chrono::milliseconds(200));
}

// Deterministic shape of the claimed window. The pull override runs on the
// handler thread immediately before StartAck (KVCacheStoreServiceImpl::
// WriteRemote calls the transfer function, then StartAck, then returns the
// reactor). The override cancels the client call itself and then lingers for
// `delay`, so the cancellation reaches the server while the handler is still
// running -- before, around, or (delay 0) racing StartAck. If OnCancel could
// run before the handler returns, Finish would precede StartAck's StartWrite.
// Every variant must end cleanly (no "API misuse" CHECK, client call ends,
// operation settles once the pull is failed).
TEST(WriteRemoteReactorStressTest, CancelArrivingInsideTheHandlerIsHarmless) {
  global_registry::GlobalRegistryServiceImpl registry;
  grpc::ServerBuilder reg_builder;
  int reg_port = 0;
  reg_builder.AddListeningPort("localhost:0",
                               grpc::InsecureServerCredentials(), &reg_port);
  reg_builder.RegisterService(&registry);
  auto registry_server = reg_builder.BuildAndStart();
  ASSERT_NE(registry_server, nullptr);

  RaidenId dst{"bh_reactor_dst2", "0", "kv", 0};
  KVCacheStore store(/*capacity=*/64,
                     "localhost:" + std::to_string(reg_port), dst,
                     /*num_shards=*/1, /*shard_size_bytes=*/1024,
                     /*store_server_ip=*/"127.0.0.1",
                     /*raiden_controller_port=*/0);

  struct Slot {
    absl::Mutex mu;
    std::shared_ptr<WriteRemoteCancel> cancel ABSL_GUARDED_BY(mu);
    std::optional<tsl::Promise<>> pull ABSL_GUARDED_BY(mu);
    absl::Duration delay ABSL_GUARDED_BY(mu);
    int handler_cancels ABSL_GUARDED_BY(mu) = 0;
  };
  Slot slot;

  KVCacheStoreServiceImpl service(store.backend().get(),
                                  store.raiden_controller());
  service.SetTransferFnForTesting(
      [&slot](absl::Span<const Buffer>, absl::Span<const Buffer>) {
        auto [promise, future] = tsl::MakePromise<>();
        std::shared_ptr<WriteRemoteCancel> cancel;
        absl::Duration delay;
        {
          absl::MutexLock lock(slot.mu);
          slot.mu.AwaitWithTimeout(
              absl::Condition(
                  +[](Slot* s) {
                    s->mu.AssertHeld();
                    return s->cancel != nullptr;
                  },
                  &slot),
              absl::Seconds(5));
          cancel = slot.cancel;
          delay = slot.delay;
          slot.pull = std::move(promise);
          ++slot.handler_cancels;
        }
        if (cancel != nullptr) cancel->TryCancel();
        if (delay > absl::ZeroDuration()) absl::SleepFor(delay);
        return future;
      });

  grpc::ServerBuilder builder;
  int port = 0;
  builder.AddListeningPort("127.0.0.1:0", grpc::InsecureServerCredentials(),
                           &port);
  builder.RegisterService(&service);
  auto server = builder.BuildAndStart();
  ASSERT_NE(server, nullptr);
  KVCacheStoreClient client(grpc::CreateChannel(
      "127.0.0.1:" + std::to_string(port), grpc::InsecureChannelCredentials()));

  ::tpu_sync::rpc::RaidenIdProto src;
  src.set_job_name("bh_reactor_src2");
  src.set_job_replica_id("0");
  src.set_data_name("kv");
  ::tpu_sync::proto::RaidenWorkerEndpointsProto group;
  group.set_node_id(0);
  group.set_worker_id("w0");
  group.add_endpoints()->set_endpoint("127.0.0.1:1");

  const absl::Duration kDelays[] = {
      absl::ZeroDuration(),     absl::Microseconds(1),
      absl::Microseconds(20),   absl::Microseconds(200),
      absl::Milliseconds(2),    absl::Milliseconds(20)};
  const int kIterations = 300;
  int acked = 0, cancelled = 0, other = 0;
  for (int i = 0; i < kIterations; ++i) {
    {
      absl::MutexLock lock(slot.mu);
      slot.cancel = nullptr;
      slot.pull.reset();
      slot.delay = kDelays[i % (sizeof(kDelays) / sizeof(kDelays[0]))];
    }
    auto call = client.WriteRemote(src, {absl::StrCat("k", i)}, {0}, {group},
                                   /*deadline_ms=*/5000,
                                   /*hold_window=*/absl::Seconds(10),
                                   /*tracker=*/nullptr);
    ASSERT_NE(call.cancel, nullptr);
    {
      absl::MutexLock lock(slot.mu);
      slot.cancel = call.cancel;
    }
    auto ack = call.ack.Await();
    if (ack.ok()) {
      ++acked;
    } else if (absl::IsCancelled(ack.status())) {
      ++cancelled;
    } else {
      ++other;
      std::cout << "[observation] iteration " << i << ": " << ack.status()
                << std::endl;
    }
    (void)call.result.Await();
    // Fail the pull so the operation settles and frees its landing block;
    // the result goes through the (by now nulled or finished) gate.
    std::optional<tsl::Promise<>> pull;
    for (int w = 0; w < 500 && !pull.has_value(); ++w) {
      {
        absl::MutexLock lock(slot.mu);
        if (slot.pull.has_value()) pull = std::move(slot.pull);
        slot.pull.reset();
      }
      if (!pull.has_value()) absl::SleepFor(absl::Milliseconds(2));
    }
    ASSERT_TRUE(pull.has_value()) << "handler never reached the pull, i=" << i;
    pull->Set(absl::InternalError("pull failed (test)"));
  }
  int handler_cancels = 0;
  {
    absl::MutexLock lock(slot.mu);
    handler_cancels = slot.handler_cancels;
  }
  // Let every operation settle, then shut down with all reactors finished.
  for (int w = 0; w < 500 && service.InFlightWriteOpsCountForTesting() > 0;
       ++w) {
    absl::SleepFor(absl::Milliseconds(10));
  }
  std::cout << "[observation] handler-side cancels=" << handler_cancels
            << " acked=" << acked << " cancelled=" << cancelled
            << " other=" << other << " in_flight_ops_after="
            << service.InFlightWriteOpsCountForTesting() << std::endl;
  EXPECT_EQ(handler_cancels, kIterations);
  EXPECT_EQ(other, 0);
  server->Shutdown(std::chrono::system_clock::now() +
                   std::chrono::milliseconds(500));
  registry_server->Shutdown(std::chrono::system_clock::now() +
                            std::chrono::milliseconds(200));
}

}  // namespace
}  // namespace kv_cache
}  // namespace tpu_raiden
