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

#include "tpu_sync/kv_cache/backends/storage/tds_backend.h"

#include <cstddef>
#include <functional>
#include <string>
#include <utility>
#include <vector>

#include "absl/container/flat_hash_map.h"
#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/types/span.h"
#include "tpu_sync/kv_cache/backends/backend.h"

namespace tpu_raiden {
namespace kv_cache {
namespace backends {
namespace storage {

TdsKVBackend::TdsKVBackend(
    std::string name, absl::flat_hash_map<std::string, std::string> properties)
    : KVBackend(std::move(properties)), name_(std::move(name)) {}

void TdsKVBackend::WriteAsync(const BlockKey& /*key*/,
                              absl::Span<const HostBufferDescriptor> /*slices*/,
                              size_t /*total_bytes*/,
                              std::function<void(absl::Status)> callback) {
  if (callback) {
    callback(absl::UnimplementedError(
        "TdsKVBackend::WriteAsync is not implemented"));
  }
}

void TdsKVBackend::ReadAsync(const BlockKey& /*key*/,
                             absl::Span<const HostBufferDescriptor> /*slices*/,
                             size_t /*total_bytes*/,
                             std::function<void(absl::Status)> callback) {
  if (callback) {
    callback(
        absl::UnimplementedError("TdsKVBackend::ReadAsync is not implemented"));
  }
}

void TdsKVBackend::BatchExistsAsync(
    absl::Span<const BlockKey> keys,
    std::function<void(std::vector<absl::StatusOr<bool>>)> callback) {
  if (callback) {
    callback(std::vector<absl::StatusOr<bool>>(
        keys.size(),
        absl::UnimplementedError(
            "TdsKVBackend::BatchExistsAsync is not implemented")));
  }
}

}  // namespace storage
}  // namespace backends
}  // namespace kv_cache
}  // namespace tpu_raiden
