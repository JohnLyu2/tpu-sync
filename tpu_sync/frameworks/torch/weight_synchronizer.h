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

#ifndef THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_FRAMEWORKS_TORCH_WEIGHT_SYNCHRONIZER_H_
#define THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_FRAMEWORKS_TORCH_WEIGHT_SYNCHRONIZER_H_

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "tpu_sync/core/raiden_transfer_endpoint.h"
#include "tpu_sync/core/raw_transfer_core.h"
#ifndef WITHOUT_PYTHON
#include "ATen/core/TensorBody.h"
#include "csrc/api/tensor_buffer.h"
#endif
#include "tpu_sync/weight_sync/weight_synchronizer_base.h"

namespace tpu_sync {
namespace rpc {
class StartTransferRequest;
}  // namespace rpc
}  // namespace tpu_sync

namespace tpu_raiden {
namespace torch {

// PyTorch facade over weight_sync::WeightSynchronizerBase. Unpacks at::Tensor
// shards into PJRT buffer handles and keeps the tensor buffer references alive
// for the lifetime of the binding. NUMA placement of host tiling, H2D and
// transport listeners is handled by the base class per shard.
class WeightSynchronizer {
 public:
  WeightSynchronizer(const WeightSynchronizer&) = delete;
  WeightSynchronizer& operator=(const WeightSynchronizer&) = delete;
  WeightSynchronizer(WeightSynchronizer&&) = default;
  WeightSynchronizer& operator=(WeightSynchronizer&&) = default;

#ifndef WITHOUT_PYTHON
  WeightSynchronizer(
      const std::vector<std::vector<at::Tensor>>& device_tensors,
      std::optional<int> local_port = std::nullopt, int parallelism = 1,
      std::optional<int> listener_port = std::nullopt,
      std::optional<std::string> bind_ip = std::nullopt,
      bool unsafe_skip_buffer_lock = true, bool auto_h2d = false,
      std::optional<std::vector<int64_t>> global_shard_indices = std::nullopt);

  absl::Status BindWeights(
      const std::vector<std::vector<at::Tensor>>& device_tensors);
#endif
  // Releases all bound device tensors and TPU HBM buffer holds while keeping
  // the synchronizer (host staging memory, listeners, controller registration)
  // alive for a later BindWeights(). D2h()/H2d()/pushes fail with
  // FailedPrecondition until weights are re-bound. Must not be called while a
  // D2H/H2D/push is in flight.
  void UnbindWeights();

  // CPU / Mock metadata constructor for tests without PJRT TPU devices
  WeightSynchronizer(
      size_t num_layers, size_t num_shards, size_t slice_byte_size,
      std::optional<int> local_port = std::nullopt, int parallelism = 1,
      std::optional<int> listener_port = std::nullopt,
      std::optional<std::string> bind_ip = std::nullopt, bool auto_h2d = false,
      std::optional<std::vector<int64_t>> global_shard_indices = std::nullopt);
  WeightSynchronizer(
      size_t num_layers, size_t num_shards,
      std::vector<size_t> slice_byte_sizes,
      std::optional<int> local_port = std::nullopt, int parallelism = 1,
      std::optional<int> listener_port = std::nullopt,
      std::optional<std::string> bind_ip = std::nullopt, bool auto_h2d = false,
      std::optional<std::vector<int64_t>> global_shard_indices = std::nullopt);

  ~WeightSynchronizer();

  absl::StatusOr<raiden::PjRtCopyFuture> D2h(uint64_t uuid = 0);
  absl::StatusOr<raiden::PjRtCopyFuture> H2d(uint64_t uuid = 0);

  absl::Status PushWeights(const std::vector<std::string>& peers);
  absl::Status PushWeightsResharded(
      const tpu_sync::rpc::StartTransferRequest& request);

  void SetSkipTiling(const std::vector<bool>& skip_tiling);
  void SetSkipTiling(bool skip_all);
  void DrainPendingH2d();
  absl::Status WaitForTransferCompletion(uint64_t uuid = 0);

  weight_sync::WeightSyncMetrics GetMetrics() const;
  void ResetMetrics();

  const uint8_t* GetHostBufferPtr(size_t layer_idx, size_t shard_idx) const;
  size_t GetHostBufferSize(size_t layer_idx, size_t shard_idx) const;
  std::optional<int> local_port() const;
  std::optional<int> listener_port() const;
  bool is_listener_active() const;

  std::vector<std::string> local_ips() const;
  std::vector<RaidenTransferEndpoint> get_local_endpoints() const;

  size_t num_layers() const;
  size_t num_shards() const;
  size_t slice_byte_size() const;

  void test_only_set_bandwidth_limit(double test_only_simulated_egress_gbps,
                                     double test_only_simulated_ingress_gbps);

  static std::unique_ptr<WeightSynchronizer> test_only_create_cpu_instance(
      size_t num_layers, size_t num_shards, size_t slice_byte_size,
      std::optional<int> local_port = std::nullopt, int parallelism = 1,
      std::optional<int> listener_port = std::nullopt,
      std::optional<std::string> bind_ip = std::nullopt, bool auto_h2d = false,
      std::optional<std::vector<int64_t>> global_shard_indices = std::nullopt,
      double test_only_simulated_egress_gbps = 0.0,
      double test_only_simulated_ingress_gbps = 0.0);

  static std::unique_ptr<WeightSynchronizer> test_only_create_cpu_instance(
      size_t num_layers, size_t num_shards,
      std::vector<size_t> slice_byte_sizes,
      std::optional<int> local_port = std::nullopt, int parallelism = 1,
      std::optional<int> listener_port = std::nullopt,
      std::optional<std::string> bind_ip = std::nullopt, bool auto_h2d = false,
      std::optional<std::vector<int64_t>> global_shard_indices = std::nullopt,
      double test_only_simulated_egress_gbps = 0.0,
      double test_only_simulated_ingress_gbps = 0.0);

 private:
  std::unique_ptr<weight_sync::WeightSynchronizerBase> base_;
#ifndef WITHOUT_PYTHON
  bool unsafe_skip_buffer_lock_ = true;
  std::vector<torch_tpu::TensorBufferHandle> buffer_refs_;
#endif
};

}  // namespace torch
}  // namespace tpu_raiden

#endif  // THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_FRAMEWORKS_TORCH_WEIGHT_SYNCHRONIZER_H_
