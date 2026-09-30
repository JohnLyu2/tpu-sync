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

#ifndef THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_CORE_STAGING_ARENA_H_
#define THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_CORE_STAGING_ARENA_H_

#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <vector>

#include "absl/base/thread_annotations.h"
#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/synchronization/mutex.h"
#include "xla/pjrt/pjrt_client.h"
#include "tpu_sync/core/host_memory_allocator.h"

namespace tpu_raiden {

struct ShardBufferInfoBase {
  const uint8_t* host_ptr = nullptr;
  size_t host_size = 0;
  size_t device_size = 0;
  const xla::PjRtDevice* device = nullptr;
  std::unique_ptr<uint8_t[], void (*)(void*)> owned_host_buffer = {
      nullptr, [](void*) {}};
  std::shared_ptr<void> host_owner;
  std::unique_ptr<uint8_t[], void (*)(void*)> owned_tiled_buffer = {
      nullptr, [](void*) {}};
  std::shared_ptr<void> tiled_owner;
  uint8_t* tiled_ptr = nullptr;
  size_t tiled_size = 0;

  // Releases underlying host and tiled buffer allocations while preserving
  // metadata such as |device_size| and |device|.
  void ReleaseMemory() {
    host_ptr = nullptr;
    host_size = 0;
    owned_host_buffer.reset();
    host_owner.reset();
    owned_tiled_buffer.reset();
    tiled_owner.reset();
    tiled_ptr = nullptr;
    tiled_size = 0;
  }
};

struct LayerInfoBase {
  std::vector<ShardBufferInfoBase> shards;

  // Releases underlying host and tiled memory across all shards in this
  // layer while preserving the shard vector size.
  void ReleaseMemory() {
    for (ShardBufferInfoBase& shard : shards) {
      shard.ReleaseMemory();
    }
  }
};

// Adapts a non-owning |allocator| pointer into a `HostBufferAllocator`
// callback that invokes `AllocateDmaMappedForDevice`.
inline HostBufferAllocator MakeHostBufferAllocator(
    HostMemoryAllocator* allocator) {
  if (allocator == nullptr) {
    return nullptr;
  }
  return [allocator](size_t size_bytes, const xla::PjRtDevice* device)
             -> absl::StatusOr<HostBufferAllocation> {
    return allocator->AllocateDmaMappedForDevice(size_bytes, device);
  };
}

// Returns a default CPU `HostBufferAllocator` backed by
// `MallocHostMemoryAllocator` (`posix_memalign`).
inline HostBufferAllocator MakeDefaultHostBufferAllocator() {
  auto allocator = std::make_shared<MallocHostMemoryAllocator>();
  return [allocator](size_t size_bytes, const xla::PjRtDevice* /*device*/)
             -> absl::StatusOr<HostBufferAllocation> {
    return allocator->Allocate(size_bytes);
  };
}

// Manages layer staging metadata (`LayerInfoBase`) across one or more
// fixed-size `std::vector<LayerInfoBase>` chunk collections.
//
// Supports both:
// 1. Dynamic slot acquisition via `Acquire()` returning a move-only RAII
//    `Allocation` handle that returns the slot to the arena when destroyed.
//    When out of capacity and `Config::allow_dynamic_growth` is enabled,
//    the arena grows by appending a new `std::vector<LayerInfoBase>` with the
//    same size as the previous vector and allocating backing host buffers via
//    the configured `HostBufferAllocator`, preserving pointer/reference
//    stability for all existing `Allocation` handles.
// 2. Backward-compatible index-based access (`GetLayer(layer_idx)` and
//    `operator[](layer_idx)`).
//
// Thread-safe for concurrent `Acquire()` and `Allocation` release.
class StagingArena {
 public:
  struct Config {
    // Number of `LayerInfoBase` slots in each allocated chunk vector.
    size_t initial_capacity = 0;
    // Number of shards to pre-size on each `LayerInfoBase` slot when a chunk
    // is allocated.
    size_t num_shards = 0;
    // Per-shard host buffer size in bytes when allocating without an initial
    // `layers` template.
    size_t shard_host_size = 0;
    // If true, appends a new `std::vector<LayerInfoBase>` of the same size as
    // the previous chunk when `Acquire()` is called and no free slots remain.
    bool allow_dynamic_growth = false;
    // If true, calls `LayerInfoBase::ReleaseMemory()` when an `Allocation`
    // returns its slot to the arena.
    bool release_memory_on_free = false;
  };

  // Move-only RAII handle representing an acquired `LayerInfoBase` slot in
  // `StagingArena`. Automatically returns the slot to the arena on
  // destruction unless already released via `Release()`.
  class Allocation {
   public:
    Allocation() = default;
    Allocation(StagingArena* arena, size_t layer_idx, LayerInfoBase* layer)
        : arena_(arena), layer_idx_(layer_idx), layer_(layer) {}

    ~Allocation() { Release(); }

    Allocation(const Allocation&) = delete;
    Allocation& operator=(const Allocation&) = delete;

    Allocation(Allocation&& other) noexcept
        : arena_(other.arena_),
          layer_idx_(other.layer_idx_),
          layer_(other.layer_) {
      other.arena_ = nullptr;
      other.layer_idx_ = 0;
      other.layer_ = nullptr;
    }

    Allocation& operator=(Allocation&& other) noexcept {
      if (this != &other) {
        Release();
        arena_ = other.arena_;
        layer_idx_ = other.layer_idx_;
        layer_ = other.layer_;
        other.arena_ = nullptr;
        other.layer_idx_ = 0;
        other.layer_ = nullptr;
      }
      return *this;
    }

    // Explicitly returns the acquired slot to the arena before destruction.
    void Release();

    // Frees underlying host/tiled memory on this slot's `LayerInfoBase`.
    void ReleaseMemory() {
      if (layer_ != nullptr) {
        layer_->ReleaseMemory();
      }
    }

    bool valid() const { return arena_ != nullptr && layer_ != nullptr; }
    explicit operator bool() const { return valid(); }

    size_t layer_idx() const { return layer_idx_; }
    size_t index() const { return layer_idx_; }

    LayerInfoBase& layer() { return *layer_; }
    const LayerInfoBase& layer() const { return *layer_; }
    LayerInfoBase* get() { return layer_; }
    const LayerInfoBase* get() const { return layer_; }
    LayerInfoBase& operator*() { return *layer_; }
    const LayerInfoBase& operator*() const { return *layer_; }
    LayerInfoBase* operator->() { return layer_; }
    const LayerInfoBase* operator->() const { return layer_; }

   private:
    StagingArena* arena_ = nullptr;
    size_t layer_idx_ = 0;
    LayerInfoBase* layer_ = nullptr;
  };

  StagingArena() = default;
  explicit StagingArena(Config config,
                        HostBufferAllocator host_allocator = nullptr);
  explicit StagingArena(std::vector<LayerInfoBase> layers,
                        HostBufferAllocator host_allocator = nullptr);
  StagingArena(std::vector<LayerInfoBase> layers,
               HostBufferAllocator host_allocator, Config config);
  StagingArena(std::vector<LayerInfoBase> layers, Config config,
               HostBufferAllocator host_allocator = nullptr);

  StagingArena(const StagingArena&) = delete;
  StagingArena& operator=(const StagingArena&) = delete;

  StagingArena(StagingArena&& other) noexcept;
  StagingArena& operator=(StagingArena&& other) noexcept;

  Config config() const;

  // Acquires a free `LayerInfoBase` slot from the arena. If all existing
  // slots are in use, grows the arena by adding another
  // `std::vector<LayerInfoBase>` of the same size and allocating its host
  // buffers via `host_allocator_` when `Config::allow_dynamic_growth` is
  // enabled, or returns `absl::ResourceExhaustedError` otherwise.
  absl::StatusOr<Allocation> Acquire();

  // Backward-compatible direct access to a specific layer by |layer_idx|.
  LayerInfoBase& GetLayer(size_t layer_idx);
  const LayerInfoBase& GetLayer(size_t layer_idx) const;
  LayerInfoBase& operator[](size_t layer_idx);
  const LayerInfoBase& operator[](size_t layer_idx) const;

  size_t size() const;
  size_t capacity() const { return size(); }

  // Arena inspection helpers.
  size_t num_chunks() const;
  size_t chunk_size() const;
  size_t in_use_count() const;
  size_t available_count() const;

 private:
  friend class Allocation;

  struct ShardTemplate {
    size_t alloc_size = 0;
    size_t device_size = 0;
    size_t tiled_size = 0;
    const xla::PjRtDevice* device = nullptr;
  };

  void ReleaseSlot(size_t layer_idx);
  absl::Status AllocateShardUnlocked(ShardBufferInfoBase& shard,
                                     const ShardTemplate& tmpl)
      ABSL_EXCLUSIVE_LOCKS_REQUIRED(mu_);
  absl::Status EnsureLayerAllocatedUnlocked(size_t layer_idx)
      ABSL_EXCLUSIVE_LOCKS_REQUIRED(mu_);
  absl::Status AppendChunkUnlocked() ABSL_EXCLUSIVE_LOCKS_REQUIRED(mu_);
  LayerInfoBase& GetLayerUnlocked(size_t layer_idx)
      ABSL_SHARED_LOCKS_REQUIRED(mu_);
  const LayerInfoBase& GetLayerUnlocked(size_t layer_idx) const
      ABSL_SHARED_LOCKS_REQUIRED(mu_);
  size_t SizeUnlocked() const ABSL_SHARED_LOCKS_REQUIRED(mu_);

  mutable absl::Mutex mu_;
  Config config_ ABSL_GUARDED_BY(mu_);
  HostBufferAllocator host_allocator_ ABSL_GUARDED_BY(mu_);
  size_t chunk_capacity_ ABSL_GUARDED_BY(mu_) = 0;
  std::vector<std::vector<ShardTemplate>> chunk_template_ ABSL_GUARDED_BY(mu_);
  std::vector<std::unique_ptr<std::vector<LayerInfoBase>>> chunk_collections_
      ABSL_GUARDED_BY(mu_);
  std::deque<size_t> free_slots_ ABSL_GUARDED_BY(mu_);
  std::vector<bool> in_use_ ABSL_GUARDED_BY(mu_);
};

}  // namespace tpu_raiden

#endif  // THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_CORE_STAGING_ARENA_H_
