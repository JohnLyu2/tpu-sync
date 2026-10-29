// Reproducer for unsynchronized access to KVCacheManagerBase's host
// LogicalBlockManager (checked at upstream 42dda542).
//
// LogicalBlockManager is documented as not thread-safe ("requires external
// synchronization", logical_block_manager.h) and has no mutex of its own.
// KVCacheManagerBase::AllocateBlocks (kv_cache_manager_base.h) calls
// host_block_manager_->Allocate(n, /*lock=*/true) with no lock. One caller is
// the inbound auto-allocating push: RawBufferTransport serves every accepted
// connection on its own ConnectionWorker thread, and
// BlockTransportServerPushSession::StartStream calls
// delegate_->AllocateBlocks for op 1 (a push with no destination ids, which
// is what H2hWrite(peer, src_block_ids) sends -- the torch/jax `H2hWrite`
// binding). So pushes from different peers (or parallel connections) allocate
// concurrently, and they also race any local caller on the receiver
// (AllocateBlocks via D2hAutoAllocate / BlockTransport::H2hRead, Unlock via
// the frameworks' unlock, StagingBlockAllocator in dynamic staging).
//
// The test drives the real paths: several in-process senders push op-1
// (auto-allocating) H2hWrite into one receiver while a local thread on the
// receiver allocates through KVCacheManagerBase::AllocateBlocks. Every block
// handed out is allocated locked and never released, so all ids must be
// distinct and the free count must drop by exactly the number handed out.

#include <atomic>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>
#include <thread>  // NOLINT(build/c++11)
#include <vector>

#include <gtest/gtest.h>
#include "absl/container/flat_hash_map.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_cat.h"
#include "absl/synchronization/mutex.h"
#include "tpu_sync/kv_cache/kv_cache_manager_base.h"
#include "tpu_sync/kv_cache/kv_cache_manager_with_transfer.h"
#include "tpu_sync/kv_cache/logical_block_manager.h"
#include "tpu_sync/transport/block_transport_delegate.h"

namespace tpu_raiden {
namespace kv_cache {
namespace {

std::unique_ptr<KVCacheManagerWithTransfer> MakeManager(int host_blocks,
                                                        int node_id) {
  return std::make_unique<KVCacheManagerWithTransfer>(
      /*num_layers=*/1, /*num_shards=*/1, /*slice_byte_size=*/64,
      /*local_port=*/0, /*host_blocks_to_allocate=*/host_blocks,
      /*parallelism=*/1, /*node_id=*/node_id, /*local_control_port=*/-1,
      /*max_blocks=*/1, /*num_slots=*/1, /*timeout_s=*/10.0);
}

TEST(HostBlockManagerRaceTest, ConcurrentAutoAllocatingPushesAndLocalAllocs) {
  constexpr int kHostBlocks = 65536;
  constexpr int kSenders = 4;
  constexpr int kPushesPerSender = 400;
  constexpr int kLocalAllocs = 40000;
  constexpr int kLocalPulls = 400;

  auto receiver = MakeManager(kHostBlocks, /*node_id=*/100);
  LogicalBlockManager* ledger = receiver->base()->host_block_manager();
  ASSERT_NE(ledger, nullptr);
  const int free_before = ledger->num_free_blocks();
  ASSERT_GE(free_before,
            kSenders * kPushesPerSender + kLocalAllocs + kLocalPulls);
  const std::string peer =
      absl::StrCat("127.0.0.1:", *receiver->base()->local_port());

  std::vector<std::unique_ptr<KVCacheManagerWithTransfer>> senders;
  for (int s = 0; s < kSenders; ++s) {
    senders.push_back(MakeManager(/*host_blocks=*/4, /*node_id=*/s));
    std::memset(senders.back()->base()->GetBlockHostPointer(0, 0, 0),
                0x40 + s, 64);
  }

  absl::Mutex mu;
  // block id -> owner label ("push s#i" or "local #i").
  absl::flat_hash_map<int, std::string> owner;
  std::vector<std::string> duplicates;
  std::atomic<int> handed_out{0};
  std::atomic<int> errors{0};
  auto record = [&](int id, std::string who) {
    absl::MutexLock lock(mu);
    auto [it, inserted] = owner.emplace(id, who);
    if (!inserted) {
      duplicates.push_back(absl::StrCat("block ", id, ": ", it->second,
                                        " and ", who));
    }
    handed_out.fetch_add(1);
  };

  std::atomic<bool> go{false};
  std::vector<std::thread> threads;
  for (int s = 0; s < kSenders; ++s) {
    threads.emplace_back([&, s] {
      while (!go.load()) {
      }
      for (int i = 0; i < kPushesPerSender; ++i) {
        // op 1: no destination ids, the receiver allocates.
        absl::StatusOr<std::vector<int>> ids =
            senders[s]->base()->H2hWriteDirect(peer, /*src_block_ids=*/{0});
        if (!ids.ok() || ids->size() != 1) {
          errors.fetch_add(1);
          continue;
        }
        record((*ids)[0], absl::StrCat("push ", s, "#", i));
      }
    });
  }
  threads.emplace_back([&] {
    while (!go.load()) {
    }
    // The receiver's own transport-side allocation entry point: what
    // BlockTransport::H2hRead and BlockTransportServerPushSession call
    // (KVCacheManagerBase overrides it publicly through the delegate
    // interface; the KVCacheManagerBase-level name is protected).
    transport::BlockTransportDelegate* delegate = receiver->base();
    for (int i = 0; i < kLocalAllocs; ++i) {
      absl::StatusOr<std::vector<int>> ids = delegate->AllocateBlocks(1);
      if (!ids.ok() || ids->size() != 1) {
        errors.fetch_add(1);
        continue;
      }
      record((*ids)[0], absl::StrCat("local #", i));
    }
  });
  // A real local production path on the receiver: pulls (H2hRead, as the
  // torch/jax `H2hRead` binding issues with the GIL released), each of which
  // auto-allocates its local landing block in BlockTransport::H2hRead.
  const std::string sender0 =
      absl::StrCat("127.0.0.1:", *senders[0]->base()->local_port());
  threads.emplace_back([&] {
    while (!go.load()) {
    }
    for (int i = 0; i < kLocalPulls; ++i) {
      absl::StatusOr<std::vector<int>> ids =
          receiver->base()->H2hReadDirect(sender0, /*src_block_ids=*/{0});
      if (!ids.ok() || ids->size() != 1) {
        errors.fetch_add(1);
        continue;
      }
      record((*ids)[0], absl::StrCat("pull #", i));
    }
  });
  go.store(true);
  for (auto& t : threads) t.join();

  const int free_after = ledger->num_free_blocks();
  std::cout << "[observation] handed_out=" << handed_out.load()
            << " distinct=" << owner.size()
            << " duplicates=" << duplicates.size()
            << " errors=" << errors.load() << " free " << free_before << " -> "
            << free_after << " (expected " << free_before - handed_out.load()
            << ")" << std::endl;
  for (size_t i = 0; i < duplicates.size() && i < 10; ++i) {
    std::cout << "[duplicate] " << duplicates[i] << std::endl;
  }

  EXPECT_TRUE(duplicates.empty())
      << duplicates.size()
      << " host block ids were handed to two owners at once";
  EXPECT_EQ(free_after, free_before - handed_out.load())
      << "num_free_blocks is inconsistent with the blocks handed out";
  EXPECT_EQ(errors.load(), 0);
}

// Control: the same three paths, run one after another on one receiver. Must
// pass on unmodified code -- it shows the duplicates above come from the
// concurrency, not from the paths' own allocation semantics.
TEST(HostBlockManagerRaceTest, ControlSameWorkloadSerializedHasNoDuplicates) {
  auto receiver = MakeManager(/*host_blocks=*/8192, /*node_id=*/100);
  auto sender = MakeManager(/*host_blocks=*/4, /*node_id=*/0);
  LogicalBlockManager* ledger = receiver->base()->host_block_manager();
  const int free_before = ledger->num_free_blocks();
  const std::string to_receiver =
      absl::StrCat("127.0.0.1:", *receiver->base()->local_port());
  const std::string to_sender =
      absl::StrCat("127.0.0.1:", *sender->base()->local_port());

  absl::flat_hash_map<int, std::string> owner;
  int handed_out = 0, duplicates = 0;
  auto record = [&](int id, std::string who) {
    ++handed_out;
    if (!owner.emplace(id, std::move(who)).second) ++duplicates;
  };
  for (int i = 0; i < 200; ++i) {
    auto ids = sender->base()->H2hWriteDirect(to_receiver, {0});
    ASSERT_TRUE(ids.ok()) << ids.status();
    record((*ids)[0], absl::StrCat("push #", i));
  }
  transport::BlockTransportDelegate* delegate = receiver->base();
  for (int i = 0; i < 2000; ++i) {
    auto ids = delegate->AllocateBlocks(1);
    ASSERT_TRUE(ids.ok()) << ids.status();
    record((*ids)[0], absl::StrCat("local #", i));
  }
  for (int i = 0; i < 200; ++i) {
    auto ids = receiver->base()->H2hReadDirect(to_sender, {0});
    ASSERT_TRUE(ids.ok()) << ids.status();
    record((*ids)[0], absl::StrCat("pull #", i));
  }
  std::cout << "[control] handed_out=" << handed_out
            << " duplicates=" << duplicates << " free " << free_before
            << " -> " << ledger->num_free_blocks() << std::endl;
  EXPECT_EQ(duplicates, 0);
  EXPECT_EQ(ledger->num_free_blocks(), free_before - handed_out);
}

}  // namespace
}  // namespace kv_cache
}  // namespace tpu_raiden
