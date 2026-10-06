// Repro for a check-then-act window in KVCacheStore::ValidateAndPinHostBlocks.
//
// ValidateAndPinHostBlocks (kv_cache_store.cc:1670-1697) does
//     slices = backend()->Lookup(hashes)      // default options: pin_found=false
//     ids    = slices[i].host_block_id
//     backend()->Pin(hashes)
// under KVCacheStore::mutex_ only. The backend's own mutex is released between
// Lookup and Pin, and neither KVCacheStore::Evict (kv_cache_store.cc:1744-1761,
// "We do not hold store mutex_") nor KVCacheStore::Insert
// (kv_cache_store.cc:1055-1088) takes KVCacheStore::mutex_. So another thread
// can evict the hash and re-insert it at a different host block inside the
// window. Pin then succeeds (keyed by hash) and the function returns the OLD
// host block id, which no longer holds that hash.
//
// The test makes the window deterministic with a delegating backend. After the
// real Lookup returns, it runs the exact backend calls that the other threads
// would make:
//   * inner->Evict({h})  -- what KVCacheStore::Evict does before it touches
//     any store lock (DeallocateBlockIds runs afterwards);
//   * inner->InsertAndLock + inner->Release -- what KVCacheStore::Insert plus
//     the caller's Release do for a single-backend store (no store lock).

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/functional/any_invocable.h"
#include "absl/status/statusor.h"
#include "absl/types/span.h"
#include "xla/tsl/concurrency/future.h"
#include "tpu_sync/common/raiden_id.h"
#include "tpu_sync/kv_cache/block_tracker.h"
#include "tpu_sync/kv_cache/kv_cache_store.h"
#include "tpu_sync/kv_cache/kv_cache_store_backend.h"

namespace tpu_raiden {
namespace kv_cache {
namespace {

// Forwards everything to `inner`; runs `after_lookup_` once, right after the
// first Lookup returns (i.e. inside ValidateAndPinHostBlocks' window).
class WindowBackend : public KVCacheStoreBackend {
 public:
  explicit WindowBackend(std::shared_ptr<KVCacheStoreBackend> inner)
      : inner_(std::move(inner)) {}

  void SetAfterLookup(absl::AnyInvocable<void()> fn) {
    after_lookup_ = std::move(fn);
  }

  std::string name() const override { return "window:" + inner_->name(); }
  absl::StatusOr<BlockSliceList> Lookup(absl::Span<const std::string> hashes,
                                        const LookupOptions& options) override {
    auto result = inner_->Lookup(hashes, options);
    if (after_lookup_) {
      auto fn = std::move(after_lookup_);
      after_lookup_ = nullptr;
      fn();
    }
    return result;
  }
  tsl::Future<> Load(const RaidenId& remote_id,
                     absl::Span<const std::string> block_hashes,
                     absl::Span<const int32_t> device_block_ids,
                     absl::Span<const RaidenBlockId> slices,
                     BlockTracker* absl_nonnull load_tracker) override {
    return inner_->Load(remote_id, block_hashes, device_block_ids, slices,
                        load_tracker);
  }
  std::pair<bool, BlockSliceList> Insert(absl::Span<const std::string> h,
                                         absl::Span<const RaidenBlockId> s,
                                         bool on_host) override {
    return inner_->Insert(h, s, on_host);
  }
  bool InsertAndLock(absl::Span<const std::string> h,
                     absl::Span<const RaidenBlockId> s, bool on_host) override {
    return inner_->InsertAndLock(h, s, on_host);
  }
  size_t ReleaseAndDelete(absl::Span<const std::string> h) override {
    return inner_->ReleaseAndDelete(h);
  }
  void Delete(absl::Span<const std::string> h,
              absl::Span<const RaidenBlockId> s) override {
    inner_->Delete(h, s);
  }
  bool Pin(absl::Span<const std::string> h) override { return inner_->Pin(h); }
  void Release(absl::Span<const std::string> h) override { inner_->Release(h); }
  int GetPinCount(const std::string& h) const override {
    return inner_->GetPinCount(h);
  }
  size_t GetCapacity() const override { return inner_->GetCapacity(); }
  size_t GetSize() const override { return inner_->GetSize(); }
  size_t GetAvailableSpace() const override {
    return inner_->GetAvailableSpace();
  }
  std::vector<std::string> GetEvictableKeys(size_t count) override {
    return inner_->GetEvictableKeys(count);
  }
  std::vector<int> Evict(const std::vector<std::string>& h,
                         std::vector<std::string>* evicted = nullptr) override {
    return inner_->Evict(h, evicted);
  }

 private:
  std::shared_ptr<KVCacheStoreBackend> inner_;
  absl::AnyInvocable<void()> after_lookup_;
};

TEST(KVCacheStorePinRaceTest,
     EvictAndReinsertBetweenLookupAndPinReturnsStaleHostBlockId) {
  // A plain store only to obtain a real HostOffloadBackend.
  KVCacheStore donor(4, "", {}, /*num_shards=*/1, /*shard_size_bytes=*/512,
                     /*store_server_ip=*/"127.0.0.1");
  std::shared_ptr<KVCacheStoreBackend> inner = donor.backends()[0];
  auto window = std::make_shared<WindowBackend>(inner);
  KVCacheStore store(window, RaidenId{}, /*num_shards=*/1,
                     /*shard_size_bytes=*/512, /*store_server_ip=*/"127.0.0.1");

  const RaidenId rid{"src_job", "0", "src_cache", 0};
  const std::string h = "h0";
  constexpr int kOldHostBlock = 5;
  constexpr int kNewHostBlock = 9;
  ASSERT_TRUE(store
                  .Insert({h},
                          {RaidenBlockId(rid, kOldHostBlock, -1,
                                         BlockStatus::HOST)},
                          /*on_host=*/true)
                  .ok());
  store.Release({h});

  window->SetAfterLookup([&] {
    // Thread B: eviction sweep tries to erase h. It only succeeds if h is not
    // pinned at this point (i.e. if the lookup did not pin it).
    std::vector<int> freed = inner->Evict({h});
    if (freed.empty()) return;  // Eviction refused: nothing can go stale.
    ASSERT_THAT(freed, ::testing::ElementsAre(kOldHostBlock));
    // Host block 5 went back to the pool and is reused for another hash.
    const std::vector<std::string> other = {"other"};
    ASSERT_TRUE(inner->InsertAndLock(
        other, {RaidenBlockId(rid, kOldHostBlock, -1, BlockStatus::HOST)},
        true));
    inner->Release(other);
    // Thread C: the same prefix is offloaded again, at a different block.
    const std::vector<std::string> hv = {h};
    ASSERT_TRUE(inner->InsertAndLock(
        hv, {RaidenBlockId(rid, kNewHostBlock, -1, BlockStatus::HOST)}, true));
    inner->Release(hv);
  });

  auto ids = store.ValidateAndPinHostBlocks(std::vector<std::string>{h});
  ASSERT_TRUE(ids.ok()) << ids.status();

  // What the LRU says h lives at now, after the call returned.
  auto now = inner->Lookup(std::vector<std::string>{h}, LookupOptions{});
  ASSERT_TRUE(now.ok());
  ASSERT_EQ(now->size(), 1u);
  const int live_block = (*now)[0].second.host_block_id;

  // Correct behaviour: the returned id must be where h actually lives (and
  // the block the pin protects), or the call must fail.
  EXPECT_EQ((*ids)[0], live_block)
      << "ValidateAndPinHostBlocks returned host block " << (*ids)[0]
      << " but h0 now lives at " << live_block
      << "; the returned block holds hash 'other'. The pin protects block "
      << live_block << ", not the block the reader will pull.";
  EXPECT_EQ(store.GetPinCount(h), 1);
  EXPECT_EQ(store.GetPinCount("other"), 0);
  store.UnpinHostBlocks(std::vector<std::string>{h});
}

}  // namespace
}  // namespace kv_cache
}  // namespace tpu_raiden
