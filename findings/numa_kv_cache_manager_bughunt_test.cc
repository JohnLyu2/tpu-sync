// Hardware-free reproduction for F11:
// NumaAwareKVCacheManager::CompleteReadRaw (tpu_sync/frameworks/jax/
// kv_cache_manager.cc:639-678 at 42dda542) aggregates per-sub-manager
// CompleteReadRaw() triples (done_sending, done_recving, failed_recving) across
// sub_managers_, with two coupled defects:
//
//   1. Eager failure publication while sibling sub-managers still have DMAs in
//      flight (num_subs >= 2, ENABLE_MULTI_NUMA=1): done_sending (:646-652) and
//      done_recving (:653-669) wait until all sub-managers settle, but
//      failed_recving (:670-674) is emitted on the FIRST failing sub-manager
//      (pinned by upstream's own AnyFailureImmediatelyTriggersFailedRecvingAnd-
//      SuppressesFutureAcks, kv_cache_manager_wrapper_test.cc:198-225). Once a
//      KVConnectorTransferResults-compliant caller (e.g. tpu-inference PR #3918)
//      forwards failed_recving to the scheduler, the engine frees and recycles
//      the request's HBM blocks while sibling sub-managers still have live H2D
//      (consumer) or D2H (producer) DMAs running on their shards.
//
//   2. Unbounded failed_recving_set_ / count-map leak and req_id poisoning
//      (fires even at the default ENABLE_MULTI_NUMA=0, num_subs == 1):
//      failed_recving_set_.erase(req) (:667) is reachable ONLY inside the
//      done_recving loop when done_recving_counts_[req] >= expected (:661-668),
//      which counts done_recving (r) only -- never failed_recving (f) and never
//      done_sending (s). Every failed receive or failed/expired send leaves
//      req in failed_recving_set_ forever (and on partial multi-NUMA failures
//      also leaks done_sending_counts_, done_recving_counts_, and
//      req_expected_counts_). If the same req_id reoccurs:
//        - at num_subs == 1, a subsequent failure is silently dropped (:671)
//          and a subsequent healthy receive has done_recving suppressed (:664);
//        - at num_subs == 2, a partial failure (sub0 fail + sub1 ok) leaves
//          done_recving_counts_[req] == 1 and failed_recving_set_ == {req},
//          dropping the next healthy transfer's done_recving AND causing the
//          third transfer to emit done_recving after only 1 of 2 sub-managers
//          has finished H2D (unwritten KV on sub1's shards).
//
// All four tests assert the safety contract and therefore FAIL on unmodified
// 42dda542.

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <ios>
#include <memory>
#include <optional>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/synchronization/mutex.h"
#include "xla/future.h"
#include "xla/tsl/platform/statusor.h"
#include "xla/tsl/platform/test.h"
#include "tpu_sync/core/raw_transfer_core.h"
#include "tpu_sync/frameworks/jax/kv_cache_manager.h"
#include "tpu_sync/kv_cache/kv_cache_manager_base.h"
#include "tpu_sync/kv_cache/kv_cache_manager_with_transfer.h"
#include "tpu_sync/kv_cache/transfer_receive_session.h"
#include "tpu_sync/kv_cache/transfer_send_session.h"
#include "tpu_sync/rpc/raiden_service.pb.h"

namespace tpu_raiden {
namespace kv_cache {
namespace jax {
namespace {

// Lightweight stub sub-manager matching upstream's MockSubManager seam for
// isolating CompleteReadRaw()'s state machine.
class StubSubManager : public KVCacheManagerWithTransfer {
 public:
  class StubBase : public kv_cache::KVCacheManagerBase {
   public:
    StubBase()
        : kv_cache::KVCacheManagerBase(
              /*num_layers=*/1, /*num_shards=*/1,
              /*slice_byte_size=*/128, /*local_port=*/std::nullopt,
              /*host_blocks_to_allocate=*/1, /*parallelism=*/1,
              /*host_allocator=*/nullptr, /*bind_ip=*/"127.0.0.1") {}
  };

  StubSubManager()
      : KVCacheManagerWithTransfer(std::make_unique<StubBase>(), /*node_id=*/0,
                                   /*local_control_port=*/-1, /*max_blocks=*/1,
                                   /*num_slots=*/1, /*timeout_s=*/10.0) {}

  std::vector<std::string> sending, recving, failed;

  std::tuple<std::vector<std::string>, std::vector<std::string>,
             std::vector<std::string>>
  CompleteReadRaw() override {
    auto res = std::make_tuple(sending, recving, failed);
    sending.clear();
    recving.clear();
    failed.clear();
    return res;
  }
};

// Real KVCacheManagerWithTransfer sub-manager driving unmodified
// TransferReceiveSession and TransferSendSession over controllable D2H / H2D
// PjRtCopyFutures and a simulated HBM block to observe mid-DMA block recycling.
class RealSessionSubManager : public KVCacheManagerWithTransfer {
 public:
  explicit RealSessionSubManager(size_t num_layers = 1, double timeout_s = 10.0)
      : KVCacheManagerWithTransfer(
            std::make_unique<ControllableBase>(num_layers, this),
            /*node_id=*/0, /*local_control_port=*/-1, /*max_blocks=*/1,
            /*num_slots=*/2, timeout_s),
        hbm_block_0_(128, 0x00) {}

  void AddRecv(const std::string& req_id, uint64_t uuid) {
    ::tpu_sync::rpc::StartTransferRequest plan;
    plan.set_uuid(uuid);
    plan.set_use_block_chunks(true);
    auto* entry = (*plan.mutable_shard_push_schedules())[0].add_entries();
    entry->set_dst_shard_idx(0);
    entry->set_src_block_id(0);
    entry->set_dst_block_id(0);
    entry->set_size_bytes(base()->block_bytes(0));
    entry->set_count(1);
    ASSERT_TRUE(RegisterActivePlan(uuid, plan, /*is_sender=*/false).ok());
    absl::MutexLock lock(mu_);
    active_recv_sessions_[uuid] = *TransferReceiveSession::Create(
        base(), staging_allocator_.get(), uuid, req_id, /*blocks_per_layer=*/1,
        DeadlineFromNow(), /*acquire_staging=*/true);
  }

  absl::Status TriggerRecvH2d(uint64_t uuid) {
    return base()->OnLayerReceived(/*layer_idx=*/0, uuid);
  }

  bool HasActiveRecv(uint64_t uuid) {
    absl::MutexLock lock(mu_);
    auto it = active_recv_sessions_.find(uuid);
    return it != active_recv_sessions_.end() && !it->second->Done();
  }

  void ServePull(uint64_t uuid) {
    std::shared_ptr<TransferSendSession> session;
    {
      absl::MutexLock lock(mu_);
      session = send_sessions_.at(uuid);
    }
    session->StartPush({"127.0.0.1:1"}, /*src_block_ids=*/{0},
                       /*dst_block_ids=*/{0});
  }

  void FailSend(uint64_t uuid, absl::Status status) {
    std::shared_ptr<TransferSendSession> session;
    {
      absl::MutexLock lock(mu_);
      session = send_sessions_.at(uuid);
    }
    session->Finish(std::move(status));
  }

  bool HasActiveSend(uint64_t uuid) {
    absl::MutexLock lock(mu_);
    auto it = send_sessions_.find(uuid);
    return it != send_sessions_.end() && !it->second->Done();
  }

  size_t copies_issued() {
    absl::MutexLock lock(copies_mu_);
    return copies_.size();
  }

  void FinishH2dCopy(size_t index, absl::Status status,
                     uint8_t incoming_h2d_byte = 0x55) {
    if (status.ok()) {
      absl::MutexLock hbm_lock(hbm_mu_);
      std::fill(hbm_block_0_.begin(), hbm_block_0_.end(), incoming_h2d_byte);
    }
    absl::MutexLock lock(copies_mu_);
    copies_.at(index).Set(std::move(status));
  }

  uint8_t FinishD2hCopyAndReadHbm(size_t index, absl::Status status) {
    uint8_t observed = 0;
    {
      absl::MutexLock hbm_lock(hbm_mu_);
      observed = hbm_block_0_[0];
    }
    absl::MutexLock lock(copies_mu_);
    copies_.at(index).Set(std::move(status));
    return observed;
  }

  void WriteHbmBlock0(uint8_t fill_byte) {
    absl::MutexLock hbm_lock(hbm_mu_);
    std::fill(hbm_block_0_.begin(), hbm_block_0_.end(), fill_byte);
  }

  uint8_t ReadHbmBlock0() {
    absl::MutexLock hbm_lock(hbm_mu_);
    return hbm_block_0_[0];
  }

 private:
  class ControllableBase : public kv_cache::KVCacheManagerBase {
   public:
    ControllableBase(size_t num_layers, RealSessionSubManager* owner)
        : kv_cache::KVCacheManagerBase(
              num_layers, /*num_shards=*/1,
              std::vector<size_t>(num_layers, 128), /*local_port=*/std::nullopt,
              /*host_blocks_to_allocate=*/2, /*parallelism=*/1,
              /*host_allocator=*/nullptr, /*bind_ip=*/"127.0.0.1"),
          owner_(owner) {}

    absl::StatusOr<raiden::PjRtCopyFuture> H2dSyncDispatch(
        const std::vector<int64_t>& src_offsets_major_dim,
        const std::vector<int64_t>& dst_offsets_major_dim,
        const std::vector<int64_t>& copy_sizes_major_dim,
        std::optional<int64_t> slot_idx, std::optional<size_t> layer_idx,
        std::optional<size_t> host_layer_idx,
        std::optional<size_t> shard_idx) override {
      auto [promise, future] = xla::MakePromise<>();
      absl::MutexLock lock(owner_->copies_mu_);
      owner_->copies_.push_back(std::move(promise));
      return raiden::PjRtCopyFuture(std::move(future), raiden::BufferHolders{});
    }

    absl::StatusOr<raiden::PjRtCopyFuture> D2hSyncDispatch(
        const std::vector<int64_t>& src_offsets_major_dim,
        const std::vector<int64_t>& dst_offsets_major_dim,
        const std::vector<int64_t>& copy_sizes_major_dim,
        std::optional<int64_t> slot_idx, std::optional<size_t> layer_idx,
        std::optional<size_t> host_layer_idx,
        std::optional<size_t> shard_idx) override {
      auto [promise, future] = xla::MakePromise<>();
      absl::MutexLock lock(owner_->copies_mu_);
      owner_->copies_.push_back(std::move(promise));
      return raiden::PjRtCopyFuture(std::move(future), raiden::BufferHolders{});
    }

    void H2hWriteDirectAsync(
        const std::vector<std::string>& peers,
        const std::vector<int>& src_block_ids,
        const std::vector<int>& dst_block_ids, uint64_t uuid, int layer_idx,
        std::function<void(absl::StatusOr<std::vector<int>>)> on_complete)
        override {
      on_complete(src_block_ids);
    }

   private:
    RealSessionSubManager* owner_;
  };

  absl::Mutex copies_mu_;
  std::vector<xla::Promise<>> copies_;
  absl::Mutex hbm_mu_;
  std::vector<uint8_t> hbm_block_0_;
};

// 1a (ENABLE_MULTI_NUMA=1, consumer): sub0's receive fails while sub1's
// TransferReceiveSession still has an H2D DMA in flight. CompleteReadRaw must
// NOT report req_recv as settled until sub1's H2D DMA drains; otherwise the
// caller recycles HBM block 0 and sub1's in-flight H2D DMA overwrites it.
TEST(NumaKVCacheManagerBughuntTest,
     FailedRecvSubManagerDoesNotSettleWhileSiblingH2dInFlight) {
  auto sub0 = std::make_unique<RealSessionSubManager>();
  auto sub1 = std::make_unique<RealSessionSubManager>();
  RealSessionSubManager* ptr0 = sub0.get();
  RealSessionSubManager* ptr1 = sub1.get();

  std::vector<std::unique_ptr<KVCacheManagerWithTransfer>> subs;
  subs.push_back(std::move(sub0));
  subs.push_back(std::move(sub1));
  TF_ASSERT_OK_AND_ASSIGN(std::unique_ptr<KVCacheManager> mgr,
                          KVCacheManager::Create(std::move(subs)));

  ptr0->AddRecv("req_recv", /*uuid=*/101);
  ptr1->AddRecv("req_recv", /*uuid=*/101);
  ASSERT_TRUE(ptr0->TriggerRecvH2d(101).ok());
  ASSERT_TRUE(ptr1->TriggerRecvH2d(101).ok());
  ASSERT_EQ(ptr0->copies_issued(), 1);
  ASSERT_EQ(ptr1->copies_issued(), 1);

  ptr0->FinishH2dCopy(0, absl::InternalError("sub0 h2d failed"));
  ASSERT_FALSE(ptr0->HasActiveRecv(101));
  ASSERT_TRUE(ptr1->HasActiveRecv(101));

  auto [s1, r1, f1] = mgr->CompleteReadRaw();
  if (!f1.empty()) {
    // Caller sees failed_recving={"req_recv"}, frees block 0, and recycles it
    // to a new request writing 0xAA into HBM.
    ptr1->WriteHbmBlock0(0xAA);
  }
  // sub1's still-in-flight H2D DMA lands 0x55 into HBM block 0.
  ptr1->FinishH2dCopy(0, absl::OkStatus(), /*incoming_h2d_byte=*/0x55);
  ASSERT_TRUE(ptr1->OnBlockShardsReceived({0}, {0}, 101).ok());

  EXPECT_TRUE(f1.empty())
      << "CompleteReadRaw emitted failed_recving while sub1 still had an "
         "in-flight H2D DMA; recycled HBM byte became 0x"
      << std::hex << static_cast<int>(ptr1->ReadHbmBlock0())
      << " instead of 0xaa";
}

// 1b (ENABLE_MULTI_NUMA=1, producer): sub0's send fails/cancels while sub1's
// TransferSendSession still has a D2H DMA reading HBM block 0.
TEST(NumaKVCacheManagerBughuntTest,
     FailedSendSubManagerDoesNotSettleWhileSiblingD2hInFlight) {
  auto sub0 = std::make_unique<RealSessionSubManager>();
  auto sub1 = std::make_unique<RealSessionSubManager>();
  RealSessionSubManager* ptr0 = sub0.get();
  RealSessionSubManager* ptr1 = sub1.get();
  ptr1->WriteHbmBlock0(0x11);

  std::vector<std::unique_ptr<KVCacheManagerWithTransfer>> subs;
  subs.push_back(std::move(sub0));
  subs.push_back(std::move(sub1));
  TF_ASSERT_OK_AND_ASSIGN(std::unique_ptr<KVCacheManager> mgr,
                          KVCacheManager::Create(std::move(subs)));

  ASSERT_GT(mgr->NotifyForRead("req_send", /*uuid=*/202, /*block_ids=*/{0}), 0);
  ptr1->ServePull(202);
  ASSERT_EQ(ptr1->copies_issued(), 1);
  ptr0->FailSend(202, absl::CancelledError("sub0 peer reset"));
  ASSERT_FALSE(ptr0->HasActiveSend(202));
  ASSERT_TRUE(ptr1->HasActiveSend(202));

  auto [s1, r1, f1] = mgr->CompleteReadRaw();
  if (!f1.empty()) {
    // Producer connector forwards failed_recving as finished_sending; scheduler
    // frees and overwrites HBM block 0 with 0xFE while sub1 D2H is reading it.
    ptr1->WriteHbmBlock0(0xFE);
  }
  uint8_t d2h_read_byte = ptr1->FinishD2hCopyAndReadHbm(0, absl::OkStatus());

  EXPECT_TRUE(f1.empty())
      << "CompleteReadRaw emitted failed_recving while sub1 still had an "
         "in-flight D2H DMA; sub1 D2H read overwritten byte 0x"
      << std::hex << static_cast<int>(d2h_read_byte) << " instead of 0x11";
}

// 2a (default ENABLE_MULTI_NUMA=0, num_subs == 1): failed_recving_set_ is never
// erased on failure, dropping subsequent failed_recving and done_recving
// reports if the same req_id reoccurs.
TEST(NumaKVCacheManagerBughuntTest,
     SingleSubManagerFailureDoesNotPoisonReusedReqId) {
  auto sub0 = std::make_unique<StubSubManager>();
  StubSubManager* ptr0 = sub0.get();
  std::vector<std::unique_ptr<KVCacheManagerWithTransfer>> subs;
  subs.push_back(std::move(sub0));
  TF_ASSERT_OK_AND_ASSIGN(std::unique_ptr<KVCacheManager> mgr,
                          KVCacheManager::Create(std::move(subs)));

  ptr0->failed.push_back("req_reuse");
  auto [s1, r1, f1] = mgr->CompleteReadRaw();
  ASSERT_EQ(f1, std::vector<std::string>{"req_reuse"});

  ptr0->failed.push_back("req_reuse");
  auto [s2, r2, f2] = mgr->CompleteReadRaw();
  EXPECT_EQ(f2, std::vector<std::string>{"req_reuse"})
      << "Second failure for req_reuse was silently dropped!";

  ptr0->recving.push_back("req_reuse");
  auto [s3, r3, f3] = mgr->CompleteReadRaw();
  EXPECT_EQ(r3, std::vector<std::string>{"req_reuse"})
      << "Healthy done_recving for req_reuse was silently suppressed!";
}

// 2b (ENABLE_MULTI_NUMA=1, num_subs == 2): partial failure leaves
// done_recving_counts_[req] == 1 and failed_recving_set_ == {req}, dropping the
// next healthy completion AND causing the third transfer to emit done_recving
// prematurely when only 1 of 2 sub-managers has finished H2D.
TEST(NumaKVCacheManagerBughuntTest,
     PartialFailureDoesNotDesyncBarrierCountIntoPrematureDoneRecving) {
  auto sub0 = std::make_unique<StubSubManager>();
  auto sub1 = std::make_unique<StubSubManager>();
  StubSubManager* ptr0 = sub0.get();
  StubSubManager* ptr1 = sub1.get();
  std::vector<std::unique_ptr<KVCacheManagerWithTransfer>> subs;
  subs.push_back(std::move(sub0));
  subs.push_back(std::move(sub1));
  TF_ASSERT_OK_AND_ASSIGN(std::unique_ptr<KVCacheManager> mgr,
                          KVCacheManager::Create(std::move(subs)));

  // Transfer 1: sub0 fails, sub1 finishes recving (the exact sequence of
  // AnyFailureImmediatelyTriggersFailedRecvingAndSuppressesFutureAcks).
  ptr0->failed.push_back("req_chain");
  (void)mgr->CompleteReadRaw();
  ptr1->recving.push_back("req_chain");
  (void)mgr->CompleteReadRaw();

  // Transfer 2 (healthy): both sub0 and sub1 finish recving.
  ptr0->recving.push_back("req_chain");
  ptr1->recving.push_back("req_chain");
  auto [s2, r2, f2] = mgr->CompleteReadRaw();
  EXPECT_EQ(r2, std::vector<std::string>{"req_chain"})
      << "Healthy transfer 2 done_recving was dropped due to residual state!";

  // Transfer 3 (healthy, staggered): ONLY sub0 finishes recving; sub1 has NOT
  // written its KV shards yet.
  ptr0->recving.push_back("req_chain");
  auto [s3, r3, f3] = mgr->CompleteReadRaw();
  EXPECT_TRUE(r3.empty())
      << "Transfer 3 emitted done_recving after only 1 of 2 sub-managers "
         "finished (decoding unwritten KV on sub1's shards)!";
}

}  // namespace
}  // namespace jax
}  // namespace kv_cache
}  // namespace tpu_raiden
