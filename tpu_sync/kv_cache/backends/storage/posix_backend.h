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

#ifndef THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_KV_CACHE_BACKENDS_STORAGE_POSIX_BACKEND_H_
#define THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_KV_CACHE_BACKENDS_STORAGE_POSIX_BACKEND_H_

#include <fcntl.h>
#include <unistd.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "absl/base/nullability.h"
#include "absl/base/thread_annotations.h"
#include "absl/container/flat_hash_map.h"
#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"
#include "absl/synchronization/mutex.h"
#include "absl/time/time.h"
#include "absl/types/span.h"
#include "xla/tsl/concurrency/future.h"
#include "tpu_sync/common/raiden_id.h"
#include "tpu_sync/core/numa_thread_pool.h"
#include "tpu_sync/kv_cache/backends/backend.h"
#include "tpu_sync/kv_cache/kv_cache_store_backend.h"
#include "tpu_sync/kv_cache/lru_cache.h"

namespace tpu_raiden {
namespace kv_cache {

class BlockTracker;

namespace backends {
namespace storage {

// Canonical identifier for the POSIX storage tier.
inline constexpr absl::string_view kPosixBackendName = "posix";

inline constexpr size_t kDefaultLookupBatchSize = 32;

// Prefix-directory widths, in hex characters, over the encoded block hash.
// 3 + 2 yields 16^5 == 1,048,576 leaf directories per topology namespace.
inline constexpr size_t kHashDirL1Width = 3;
inline constexpr size_t kHashDirL2Width = 2;
// Hex encoding doubles the length, and the ".bin" suffix costs 4 more
// characters: 2*125 + 4 == 254 <= NAME_MAX (255).
inline constexpr size_t kMaxBlockHashBytes = 125;

// Typed, validated view of a POSIX backend's configuration. Every POSIX knob
// lives here; `FromProperties` is the single parse-and-validate point.
struct PosixBackendOptions {
  std::string root_dir = "/tmp/raiden_storage";
  std::string model_name = "unknown";
  int tp_size = 1;
  int tp_rank = -1;  // Required; -1 means the caller did not supply it.
  size_t capacity_bytes = 0;
  size_t lookup_batch_size = kDefaultLookupBatchSize;

  // Worker threads in this backend instance's NumaThreadPool. Every async
  // POSIX file operation runs on it -- WriteAsync, ReadAsync and
  // BatchExistsAsync share one pool and one queue, one task per block -- so
  // this is also the ceiling on concurrent pwrite/pread/stat syscalls issued
  // by this backend. Not per-NUMA-node, not per-file-descriptor.
  int storage_io_thread_pool_size = 16;

  // When true, the backend opens block files with O_DIRECT to bypass the
  // Linux page cache. Defaults to false if omitted. Probed once at
  // construction; if the filesystem under `root_dir` does not accept O_DIRECT,
  // construction fails. Every buffer pointer, buffer length and file offset
  // must then be a multiple of DirectIOAlignment(); otherwise the operation
  // fails with InvalidArgument. There is no buffered fallback.
  bool direct_io = false;

  // Capacity of the coordinator-side PosixKVCacheStoreBackend metadata cache,
  // which remembers storage files confirmed to exist so repeated lookups of a
  // hot prefix skip the existence syscall. Counted in shard entries (one per
  // file). 0 disables the cache (default); kUnboundedMetadataCache (-1) means
  // unbounded. Least recently used entries are dropped past the cap.
  int64_t metadata_cache_max_entries = 0;
  // Idle TTL, in seconds, of a cached existence entry: it expires once it has
  // gone this long without a cache hit or a storage re-confirmation. Stale
  // entries for deleted files are also dropped when a recall from this tier
  // fails. kUnboundedMetadataCache (-1) means entries never expire.
  int64_t metadata_cache_ttl_secs = 60;

  // Parses and validates `properties`. Returns InvalidArgumentError for an
  // unparseable value, a negative thread-pool size, or a missing tp_rank.
  static absl::StatusOr<PosixBackendOptions> FromProperties(
      const absl::flat_hash_map<std::string, std::string>& properties);
};

// Sentinel for metadata_cache_max_entries / metadata_cache_ttl_secs.
inline constexpr int64_t kUnboundedMetadataCache = -1;

// Runtime configuration of PosixKVCacheStoreBackend's existence cache.
struct MetadataCacheOptions {
  // Shard entries. 0 disables the cache; std::numeric_limits<size_t>::max()
  // means unbounded.
  size_t max_entries = 0;
  // Idle TTL. absl::InfiniteDuration() means entries never expire.
  absl::Duration ttl = absl::Seconds(60);

  bool enabled() const { return max_entries > 0; }

  // Converts the validated POSIX options into runtime cache options.
  static MetadataCacheOptions FromPosixOptions(
      const PosixBackendOptions& options);
};

// Alignment required for O_DIRECT buffers, lengths and file offsets: the
// runtime page size (4 KiB on x86_64, commonly 16 KiB or 64 KiB on arm64).
// Queried once and cached.
size_t DirectIOAlignment();

// True when every slice's address and length are multiples of
// DirectIOAlignment().
bool SlicesAreDirectIOAligned(absl::Span<const HostBufferDescriptor> slices);

// PosixKVBackend implements KVBackend for POSIX filesystems (e.g., Lustre,
// local disk).
class PosixKVBackend : public KVBackend {
 public:
  // Both arguments are required: `properties` must carry the topology
  // (`tp_rank`, and `tp_size` when sharded), which PosixBackendOptions
  // validates. Defaulting them would turn a missing rank into a runtime
  // LOG(FATAL) instead of a compile error.
  PosixKVBackend(std::string name,
                 absl::flat_hash_map<std::string, std::string> properties);

  std::string name() const override { return name_; }

  const PosixBackendOptions& options() const { return options_; }

  bool is_direct_io_supported() const { return direct_io_supported_; }

  static bool ProbeDirectIO(absl::string_view dir);

  void WriteAsync(const BlockKey& key,
                  absl::Span<const HostBufferDescriptor> slices,
                  size_t total_bytes,
                  std::function<void(absl::Status)> callback) override;

  void ReadAsync(const BlockKey& key,
                 absl::Span<const HostBufferDescriptor> slices,
                 size_t total_bytes,
                 std::function<void(absl::Status)> callback) override;

  void BatchExistsAsync(
      absl::Span<const BlockKey> keys,
      std::function<void(std::vector<absl::StatusOr<bool>>)> callback) override;

 private:
  absl::StatusOr<bool> Exists(const BlockKey& key);

  std::string name_;
  PosixBackendOptions options_;
  bool direct_io_supported_ = false;
  // MUST be the last-declared member: destruction runs in reverse declaration
  // order, and ~NumaThreadPool joins its workers after draining the queue, so
  // declaring it last is what guarantees every in-flight task finishes before
  // any member it might touch is destroyed. The scheduled lambdas capture raw
  // `this` and rely on this.
  std::unique_ptr<NumaThreadPool> thread_pool_;
};

// PosixPathMapper implements the filesystem path resolution policy.
// Maps block hash identifiers and tensor-parallel rank to a rank-partitioned
// hierarchical directory layout over the HEX-ENCODED block hash (see
// BlockKeyMapper::MapKey):
//   `<root_dir>/<model_name>/tp<tp_size>_r<tp_rank>/<l1>/<l2>/<hash_hex>.bin`
class PosixPathMapper : public BlockKeyMapper {
 public:
  static absl::string_view GetParentDir(absl::string_view path) {
    size_t last_slash = path.find_last_of('/');
    if (last_slash == absl::string_view::npos) return "";
    return path.substr(0, last_slash);
  }

  PosixPathMapper(absl::string_view root_dir, absl::string_view model_name,
                  int tp_size, int tp_rank);

  absl::StatusOr<BlockKey> MapKey(
      const std::string& block_hash,
      const KeyMappingOptions& options = {}) const override;
  int tp_size() const override { return tp_size_; }

 private:
  std::string root_dir_;
  std::string model_name_;
  int tp_size_;
  int tp_rank_;
};

// PosixKVCacheStoreBackend probes persistent storage (e.g., Lustre, POSIX).
//
// Optional metadata cache: when enabled, Lookup remembers which shard files it
// has confirmed on storage and answers later lookups of them without a storage
// probe. See Lookup for the block-to-shard-key mapping and cache contents.
class PosixKVCacheStoreBackend : public KVCacheStoreBackend {
 public:
  PosixKVCacheStoreBackend(std::shared_ptr<KVBackend> storage_backend,
                           std::string name = std::string(kPosixBackendName),
                           size_t capacity_bytes = 0,
                           size_t lookup_batch_size = kDefaultLookupBatchSize,
                           MetadataCacheOptions cache_options = {});

  std::string name() const override { return name_; }

  size_t lookup_batch_size() const { return lookup_batch_size_; }

  const MetadataCacheOptions& metadata_cache_options() const {
    return cache_options_;
  }

  // Number of entries currently held by the metadata cache (0 if disabled).
  size_t metadata_cache_size() const;

  // Returns the longest prefix of `block_hashes` available on storage. See the
  // definition for the algorithm and the metadata cache contents.
  absl::StatusOr<BlockSliceList> Lookup(
      absl::Span<const std::string> block_hashes,
      const LookupOptions& options = {}) override;

  tsl::Future<> Load(const RaidenId& remote_id,
                     absl::Span<const std::string> block_hashes,
                     absl::Span<const int32_t> device_block_ids,
                     absl::Span<const RaidenBlockId> slices,
                     BlockTracker* absl_nonnull load_tracker) override {
    return tsl::Future<>(absl::OkStatus());
  }

  std::pair<bool, BlockSliceList> Insert(
      absl::Span<const std::string> block_hashes,
      absl::Span<const RaidenBlockId> slices, bool on_host) override {
    return {true, {}};
  }

  bool InsertAndLock(absl::Span<const std::string> block_hashes,
                     absl::Span<const RaidenBlockId> slices,
                     bool on_host) override {
    return true;
  }

  size_t ReleaseAndDelete(absl::Span<const std::string> block_hashes) override {
    return 0;
  }
  // Storage files are never removed through this tier. When the metadata
  // cache is enabled, this drops the cached shard keys of `block_hashes` so the
  // next Lookup re-probes storage; KVCacheStore calls it when a recall from
  // this tier fails. `slices` is unused. No-op when the cache is disabled.
  void Delete(absl::Span<const std::string> block_hashes,
              absl::Span<const RaidenBlockId> slices) override;
  bool Pin(absl::Span<const std::string> block_hashes) override { return true; }
  void Release(absl::Span<const std::string> block_hashes) override {}
  int GetPinCount(const std::string& hash) const override { return 0; }
  size_t GetCapacity() const override { return capacity_bytes_; }
  size_t GetSize() const override { return 0; }
  size_t GetAvailableSpace() const override { return capacity_bytes_; }

  std::shared_ptr<KVBackend> storage_backend() const {
    return storage_backend_;
  }

 private:
  struct ExistenceEntry {
    // Last cache hit or storage confirmation of the shard file. Anchor of the
    // idle TTL.
    absl::Time last_used;
  };

  // Returns the storage keys ("shard keys") that must all exist for ONE block,
  // `block_hash`, to be available.
  absl::StatusOr<std::vector<BlockKey>> MapShardKeys(
      const std::string& block_hash) const;

  // Indexing: i = position of the block in the Lookup request
  // (block_hashes[i]); j = position of the shard key within
  // MapShardKeys(block_hashes[i]) (today j is always 0, the rank-0 shard).
  // Returns fresh[i][j] = true iff shard_keys[i][j] has a fresh cache entry.
  // Expired entries are erased and reported as absent.
  std::vector<std::vector<bool>> CachedFresh(
      absl::Span<const std::vector<BlockKey>> shard_keys);

  // Records storage-confirmed shard keys. A key that is already cached keeps
  // its original timestamp.
  void CacheInsert(absl::Span<const BlockKey* const> keys);

  // Synchronously probes storage for `keys`. Returns one entry per key; a
  // short or failed answer is reported as absent from that point on.
  std::vector<bool> ProbeExists(absl::Span<const BlockKey> keys);

  RaidenBlockId MakeSharedStorageBlock() const;

  std::shared_ptr<KVBackend> storage_backend_;
  std::string name_ = std::string(kPosixBackendName);
  size_t capacity_bytes_ = 0;
  size_t lookup_batch_size_ = 32;
  const MetadataCacheOptions cache_options_;

  // Never held across storage I/O or key mapping.
  mutable absl::Mutex cache_mu_;
  LRUCache<std::string, ExistenceEntry> cache_ ABSL_GUARDED_BY(cache_mu_);
};

}  // namespace storage
}  // namespace backends
}  // namespace kv_cache
}  // namespace tpu_raiden

#endif  // THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_KV_CACHE_BACKENDS_STORAGE_POSIX_BACKEND_H_
