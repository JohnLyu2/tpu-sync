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

#include "tpu_sync/core/staging_arena.h"

#include <cstddef>
#include <memory>
#include <utility>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/synchronization/mutex.h"
#include "tpu_sync/core/host_memory_allocator.h"

namespace tpu_raiden {

void StagingArena::Allocation::Release() {
  if (arena_ != nullptr) {
    arena_->ReleaseSlot(layer_idx_);
    arena_ = nullptr;
    layer_idx_ = 0;
    layer_ = nullptr;
  }
}

StagingArena::StagingArena(Config config, HostBufferAllocator host_allocator)
    : config_(config),
      host_allocator_(std::move(host_allocator)),
      chunk_capacity_(config.initial_capacity) {
  if (chunk_capacity_ > 0) {
    chunk_template_.assign(
        chunk_capacity_,
        std::vector<ShardTemplate>(
            config_.num_shards,
            ShardTemplate{.alloc_size = config_.shard_host_size,
                          .device_size = config_.shard_host_size}));
    auto chunk = std::make_unique<std::vector<LayerInfoBase>>(chunk_capacity_);
    for (size_t i = 0; i < chunk_capacity_; ++i) {
      (*chunk)[i].shards.resize(config_.num_shards);
      for (size_t s = 0; s < config_.num_shards; ++s) {
        (*chunk)[i].shards[s].device_size = config_.shard_host_size;
        if (config_.shard_host_size > 0 && host_allocator_) {
          (void)AllocateShardUnlocked((*chunk)[i].shards[s],
                                      chunk_template_[i][s]);
        }
      }
    }
    chunk_collections_.push_back(std::move(chunk));
    in_use_.assign(chunk_capacity_, false);
    for (size_t i = 0; i < chunk_capacity_; ++i) {
      free_slots_.push_back(i);
    }
  }
}

StagingArena::StagingArena(std::vector<LayerInfoBase> layers,
                           HostBufferAllocator host_allocator)
    : StagingArena(std::move(layers), std::move(host_allocator), Config{}) {}

StagingArena::StagingArena(std::vector<LayerInfoBase> layers,
                           HostBufferAllocator host_allocator, Config config)
    : config_(config), host_allocator_(std::move(host_allocator)) {
  if (!layers.empty()) {
    chunk_capacity_ = layers.size();
    config_.initial_capacity = chunk_capacity_;
    if (config_.num_shards == 0 && !layers[0].shards.empty()) {
      config_.num_shards = layers[0].shards.size();
    }
    chunk_template_.resize(chunk_capacity_);
    for (size_t i = 0; i < chunk_capacity_; ++i) {
      chunk_template_[i].resize(layers[i].shards.size());
      for (size_t s = 0; s < layers[i].shards.size(); ++s) {
        const ShardBufferInfoBase& shard = layers[i].shards[s];
        size_t alloc_size = shard.host_size > 0 ? shard.host_size
                                                : (config_.shard_host_size > 0
                                                       ? config_.shard_host_size
                                                       : shard.device_size);
        chunk_template_[i][s] = ShardTemplate{
            .alloc_size = alloc_size,
            .device_size = shard.device_size,
            .tiled_size = shard.tiled_size,
            .device = shard.device,
        };
      }
    }
    chunk_collections_.push_back(
        std::make_unique<std::vector<LayerInfoBase>>(std::move(layers)));
    in_use_.assign(chunk_capacity_, false);
    for (size_t i = 0; i < chunk_capacity_; ++i) {
      free_slots_.push_back(i);
    }
  } else if (config_.initial_capacity > 0) {
    chunk_capacity_ = config_.initial_capacity;
    chunk_template_.assign(
        chunk_capacity_,
        std::vector<ShardTemplate>(
            config_.num_shards,
            ShardTemplate{.alloc_size = config_.shard_host_size,
                          .device_size = config_.shard_host_size}));
    (void)AppendChunkUnlocked();
  }
}

StagingArena::StagingArena(std::vector<LayerInfoBase> layers, Config config,
                           HostBufferAllocator host_allocator)
    : StagingArena(std::move(layers), std::move(host_allocator), config) {}

StagingArena::StagingArena(StagingArena&& other) noexcept {
  absl::MutexLock lock(other.mu_);
  config_ = other.config_;
  host_allocator_ = std::move(other.host_allocator_);
  chunk_capacity_ = other.chunk_capacity_;
  chunk_template_ = std::move(other.chunk_template_);
  chunk_collections_ = std::move(other.chunk_collections_);
  free_slots_ = std::move(other.free_slots_);
  in_use_ = std::move(other.in_use_);
  other.chunk_capacity_ = 0;
}

StagingArena& StagingArena::operator=(StagingArena&& other) noexcept {
  if (this != &other) {
    absl::MutexLock lock_this(mu_);
    absl::MutexLock lock_other(other.mu_);
    config_ = other.config_;
    host_allocator_ = std::move(other.host_allocator_);
    chunk_capacity_ = other.chunk_capacity_;
    chunk_template_ = std::move(other.chunk_template_);
    chunk_collections_ = std::move(other.chunk_collections_);
    free_slots_ = std::move(other.free_slots_);
    in_use_ = std::move(other.in_use_);
    other.chunk_capacity_ = 0;
  }
  return *this;
}

StagingArena::Config StagingArena::config() const {
  absl::MutexLock lock(mu_);
  return config_;
}

absl::Status StagingArena::AllocateShardUnlocked(ShardBufferInfoBase& shard,
                                                 const ShardTemplate& tmpl) {
  shard.device_size = tmpl.device_size;
  shard.device = tmpl.device;
  shard.tiled_size = tmpl.tiled_size;
  if (tmpl.alloc_size == 0) {
    return absl::OkStatus();
  }
  if (!host_allocator_) {
    return absl::FailedPreconditionError(
        "StagingArena requires a host_allocator to allocate host memory");
  }
  absl::StatusOr<HostBufferAllocation> alloc =
      host_allocator_(tmpl.alloc_size, tmpl.device);
  if (!alloc.ok()) {
    return alloc.status();
  }
  if (alloc->ptr == nullptr) {
    return absl::InternalError(
        "Host allocator returned null buffer for StagingArena");
  }
  if (alloc->size < tmpl.alloc_size) {
    return absl::InternalError(
        "Host allocator returned undersized buffer for StagingArena");
  }
  shard.host_ptr = alloc->ptr;
  shard.host_size = alloc->size;
  shard.host_owner = std::move(alloc->owner);
  return absl::OkStatus();
}

absl::Status StagingArena::EnsureLayerAllocatedUnlocked(size_t layer_idx) {
  if (!host_allocator_ || chunk_capacity_ == 0) {
    return absl::OkStatus();
  }
  size_t tmpl_idx = layer_idx % chunk_capacity_;
  if (tmpl_idx >= chunk_template_.size()) {
    return absl::OkStatus();
  }
  LayerInfoBase& layer = GetLayerUnlocked(layer_idx);
  const std::vector<ShardTemplate>& shard_templates = chunk_template_[tmpl_idx];
  for (size_t s = 0; s < layer.shards.size() && s < shard_templates.size();
       ++s) {
    if (layer.shards[s].host_ptr == nullptr &&
        shard_templates[s].alloc_size > 0) {
      absl::Status status =
          AllocateShardUnlocked(layer.shards[s], shard_templates[s]);
      if (!status.ok()) {
        return status;
      }
    }
  }
  return absl::OkStatus();
}

absl::Status StagingArena::AppendChunkUnlocked() {
  if (chunk_capacity_ == 0) {
    return absl::ResourceExhaustedError(
        "StagingArena has zero chunk capacity and cannot grow");
  }
  auto chunk = std::make_unique<std::vector<LayerInfoBase>>(chunk_capacity_);
  for (size_t i = 0; i < chunk_capacity_; ++i) {
    LayerInfoBase& layer = (*chunk)[i];
    size_t num_shards = i < chunk_template_.size() ? chunk_template_[i].size()
                                                   : config_.num_shards;
    layer.shards.resize(num_shards);
    for (size_t s = 0; s < num_shards; ++s) {
      ShardTemplate tmpl =
          (i < chunk_template_.size() && s < chunk_template_[i].size())
              ? chunk_template_[i][s]
              : ShardTemplate{.alloc_size = config_.shard_host_size,
                              .device_size = config_.shard_host_size};
      absl::Status status = AllocateShardUnlocked(layer.shards[s], tmpl);
      if (!status.ok()) {
        return status;
      }
    }
  }
  size_t base_idx = in_use_.size();
  chunk_collections_.push_back(std::move(chunk));
  in_use_.resize(base_idx + chunk_capacity_, false);
  for (size_t i = 0; i < chunk_capacity_; ++i) {
    free_slots_.push_back(base_idx + i);
  }
  return absl::OkStatus();
}

absl::StatusOr<StagingArena::Allocation> StagingArena::Acquire() {
  absl::MutexLock lock(mu_);
  if (free_slots_.empty()) {
    if (!config_.allow_dynamic_growth) {
      return absl::ResourceExhaustedError(
          "StagingArena is out of capacity and dynamic capacity growth is "
          "disabled");
    }
    absl::Status status = AppendChunkUnlocked();
    if (!status.ok()) {
      return status;
    }
  }
  size_t slot_idx = free_slots_.front();
  absl::Status alloc_status = EnsureLayerAllocatedUnlocked(slot_idx);
  if (!alloc_status.ok()) {
    return alloc_status;
  }
  free_slots_.pop_front();
  in_use_[slot_idx] = true;
  return Allocation(this, slot_idx, &GetLayerUnlocked(slot_idx));
}

void StagingArena::ReleaseSlot(size_t layer_idx) {
  absl::MutexLock lock(mu_);
  if (layer_idx >= in_use_.size() || !in_use_[layer_idx]) {
    return;
  }
  if (config_.release_memory_on_free) {
    GetLayerUnlocked(layer_idx).ReleaseMemory();
  }
  in_use_[layer_idx] = false;
  free_slots_.push_front(layer_idx);
}

LayerInfoBase& StagingArena::GetLayerUnlocked(size_t layer_idx) {
  size_t chunk_idx = layer_idx / chunk_capacity_;
  size_t offset = layer_idx % chunk_capacity_;
  return (*chunk_collections_[chunk_idx])[offset];
}

const LayerInfoBase& StagingArena::GetLayerUnlocked(size_t layer_idx) const {
  size_t chunk_idx = layer_idx / chunk_capacity_;
  size_t offset = layer_idx % chunk_capacity_;
  return (*chunk_collections_[chunk_idx])[offset];
}

LayerInfoBase& StagingArena::GetLayer(size_t layer_idx) {
  absl::MutexLock lock(mu_);
  return GetLayerUnlocked(layer_idx);
}

const LayerInfoBase& StagingArena::GetLayer(size_t layer_idx) const {
  absl::MutexLock lock(mu_);
  return GetLayerUnlocked(layer_idx);
}

LayerInfoBase& StagingArena::operator[](size_t layer_idx) {
  absl::MutexLock lock(mu_);
  return GetLayerUnlocked(layer_idx);
}

const LayerInfoBase& StagingArena::operator[](size_t layer_idx) const {
  absl::MutexLock lock(mu_);
  return GetLayerUnlocked(layer_idx);
}

size_t StagingArena::SizeUnlocked() const {
  return chunk_collections_.size() * chunk_capacity_;
}

size_t StagingArena::size() const {
  absl::MutexLock lock(mu_);
  return SizeUnlocked();
}

size_t StagingArena::num_chunks() const {
  absl::MutexLock lock(mu_);
  return chunk_collections_.size();
}

size_t StagingArena::chunk_size() const {
  absl::MutexLock lock(mu_);
  return chunk_capacity_;
}

size_t StagingArena::in_use_count() const {
  absl::MutexLock lock(mu_);
  return SizeUnlocked() - free_slots_.size();
}

size_t StagingArena::available_count() const {
  absl::MutexLock lock(mu_);
  return free_slots_.size();
}

}  // namespace tpu_raiden
