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

#ifndef THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_WEIGHT_SYNC_TILING_UTILS_H_
#define THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_WEIGHT_SYNC_TILING_UTILS_H_

#include <cstdint>
#include <optional>

#include "absl/status/status.h"
#include "xla/layout.h"
#include "xla/shape.h"

namespace tpu_raiden::weight_sync {

// Returns true if the shape and layout qualify for the optimized row-major
// tiling fast-path.
bool IsStandardRowMajorTiled(const xla::Shape& shape,
                             const xla::Layout& layout);

// Returns true if the shape and layout qualify for the optimized column-major
// tiling fast-path.
bool IsStandardColMajorTiled(const xla::Shape& shape,
                             const xla::Layout& layout);

// Calculates the total number of physical elements required for a tiled buffer.
int64_t GetTiledBufferElements(const xla::Shape& shape);

// Large tensors are tiled in parallel: one chunk on the calling thread and
// the rest as helper tasks on a shared pool. When |numa_node| is set, the
// helper tasks are pinned to that node; callers should pass the node of the
// buffers so the copies stay NUMA-local.

// Reconstructs a linear buffer from a tiled buffer based on shape and layout.
absl::Status DetileBuffer(const uint8_t* src_tiled, uint8_t* dst_linear,
                          const xla::Shape& shape, const xla::Layout& layout,
                          std::optional<int> numa_node = std::nullopt);

// Tiles a linear buffer based on shape and layout.
absl::Status TileBuffer(const uint8_t* src_linear, uint8_t* dst_tiled,
                        const xla::Shape& shape, const xla::Layout& layout,
                        std::optional<int> numa_node = std::nullopt);

// Tiles a buffer in place based on shape and layout without allocating an
// intermediate full-size buffer. |buffer| must have a capacity of at least
// GetTiledBufferElements(shape) * itemsize.
absl::Status TileBufferInPlace(uint8_t* buffer, size_t buffer_capacity,
                               const xla::Shape& shape,
                               const xla::Layout& layout,
                               std::optional<int> numa_node = std::nullopt);

}  // namespace tpu_raiden::weight_sync

#endif  // THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_WEIGHT_SYNC_TILING_UTILS_H_
