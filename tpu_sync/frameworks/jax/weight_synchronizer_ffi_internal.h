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

#ifndef THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_FRAMEWORKS_JAX_WEIGHT_SYNCHRONIZER_FFI_INTERNAL_H_
#define THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_FRAMEWORKS_JAX_WEIGHT_SYNCHRONIZER_FFI_INTERNAL_H_

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "absl/base/thread_annotations.h"
#include "absl/container/flat_hash_map.h"
#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"
#include "absl/synchronization/mutex.h"
#include "absl/types/span.h"
// The zero-copy FFI includes the internal XLA FFI header, which defines the
// same `xla::ffi` types as the external API header; skip the latter there.
#ifndef TENSORFLOW_COMPILER_XLA_FFI_FFI_H_
#include "xla/ffi/api/ffi.h"
#endif  // TENSORFLOW_COMPILER_XLA_FFI_FFI_H_
#include "xla/stream_executor/stream.h"
#include "tpu_sync/core/tpu_utils.h"
#include "tpu_sync/frameworks/jax/weight_synchronizer_ffi.h"

namespace tpu_raiden {
namespace weight_sync {

extern std::unique_ptr<stream_executor::Stream> g_streams[kMaxShards];
void ClearSharedWsMap();

// Resolves the host control-plane IP reachable from external orchestrator nodes
// (e.g., GKE CPU nodepools). Probes the kernel default route first when
// |use_default_route_probe| is true, then falls back to `eth0` in |host_nics|,
// any physical `kControlPlane` NIC in |host_nics|, and finally |fallback_ip|.
std::string ResolveControlPlaneIp(absl::Span<const HostNicAddress> host_nics,
                                  absl::string_view fallback_ip,
                                  bool use_default_route_probe = true);

// Packs |ip_str| (IPv4 or IPv6) as a 16-byte IPv4-mapped IPv6 / IPv6 address
// into 4 `int32_t` elements at |dst|.
void PackIpToInt32s(absl::string_view ip_str, int32_t* dst);

// Per-chip shard descriptor passed to the init FFIs in `shard_idx_buf`, laid
// out as `[shard_idx, local_slot, submanager_idx, global_shard_idx, numa_0,
// ..., numa_{num_shards-1}]`. Only `shard_idx` is required; the first four
// elements may be truncated (missing ones keep their defaults), and the NUMA
// list is either absent or complete.
struct FfiShardDescriptor {
  int32_t shard_idx = 0;
  int32_t local_slot = -1;
  int32_t submanager_idx = -1;
  int32_t global_shard_idx = -1;
  // NUMA node (socket) of the device in every local slot of the submanager,
  // indexed by local slot; -1 marks an unknown socket. Empty when the caller
  // passed no sockets, which is equivalent to all -1: the synchronizer then
  // binds only the host's first data NIC.
  std::vector<int32_t> slot_numa_nodes;

  // Parses |raw| for a submanager of |num_shards| slots. Fails if |raw| is
  // empty, `shard_idx` is outside [0, kMaxShards), `local_slot`,
  // `submanager_idx`, or `global_shard_idx` is below -1 (absent), |raw| has
  // more than 4 but not exactly `4 + num_shards` elements, or a NUMA node is
  // below -1.
  static absl::StatusOr<FfiShardDescriptor> FromSpan(
      absl::Span<const int32_t> raw, int32_t num_shards);

  // `submanager_idx` if set, else `shard_idx / num_shards` (0 if
  // |num_shards| <= 0).
  int32_t effective_submanager_idx(int32_t num_shards) const;
  // `global_shard_idx` if set, else `shard_idx`.
  int64_t effective_global_shard() const;
  bool has_explicit_global() const { return global_shard_idx >= 0; }
};

// Per-shard endpoint row written by the init FFIs into a buffer of 5, 6, or
// >= 10 `int32_t` elements: [0..3] packed data IP, [4] data port,
// [5] listener port (width >= 6), [6..9] packed control-plane IP (width >= 10).
struct ShardEndpoints {
  std::string data_ip;
  int32_t data_port = 0;
  int32_t listener_port = 0;
  std::string control_ip;

  // Writes the fields that fit in |out|. Fails if |out| has fewer than 5
  // elements.
  absl::Status PackToSpan(absl::Span<int32_t> out) const;
};

// Owns the `WeightSynchronizerBase` instances behind one family of FFI
// handlers, keyed by `shard_idx`. Shards of the same submanager (same
// submanager index, listener port, and local port) share one instance, which
// avoids re-binding its sockets; each shard is assigned a local slot within
// that instance. Re-initializing a shard with the arguments it was registered
// with returns the same instance and changes nothing; re-initializing it with
// conflicting arguments fails until the registry is cleared. Instances are only
// deleted by `Clear(/*delete_instances=*/true)`.
//
// There are two independent process-wide registries. `Default()` holds the
// instances created by the standard FFI (`init_weight_synchronizer`, `ws_*`),
// which copies between device memory and the instance's host staging buffers
// with StreamExecutor (or `memcpy` without a stream). `ZeroCopy()` holds the
// instances created by the Google-internal zero-copy FFI
// (`raiden_weight_synchronizer_*`), which wraps the XLA device buffers as PJRT
// raw buffers, binds them into the instance (`BindWeights`), and copies through
// those raw buffers. Both create instances with the same parameters; they are
// kept apart because only the zero-copy path binds device buffers and keeps
// per-shard raw-buffer state, and because it is Copybara-stripped from the
// open-source build.
class WeightSynchronizerFfiManager {
 public:
  // Registry of the standard FFI handlers.
  static WeightSynchronizerFfiManager& Default();
  // Registry of the zero-copy FFI handlers.
  static WeightSynchronizerFfiManager& ZeroCopy();

  // |host_nics| lists this host's NICs; it is called when an instance is
  // created (to pick its data NICs) and when endpoints are written (to resolve
  // the control-plane IP).
  explicit WeightSynchronizerFfiManager(
      std::function<std::vector<HostNicAddress>()> host_nics =
          [] { return GetLocalHostNicAddresses(); })
      : host_nics_(std::move(host_nics)) {}

  WeightSynchronizerFfiManager(const WeightSynchronizerFfiManager&) = delete;
  WeightSynchronizerFfiManager& operator=(const WeightSynchronizerFfiManager&) =
      delete;

  // Returns the instance shared by |desc|'s submanager, keyed by
  // `desc.effective_submanager_idx(num_shards)`, |listener_port|, and
  // |local_port|, creating it on first use, and registers `desc.shard_idx` in
  // it at local slot `desc.local_slot` (`shard_idx % num_shards` if absent)
  // with global shard index `desc.effective_global_shard()`. A new instance
  // gets one shard per local slot on `desc.slot_numa_nodes` and binds the data
  // NICs of the known NUMA nodes, or only the host's first data NIC when no
  // node is known (see `RaidenManagerBase::InitTransportServer`).
  //
  // Calling it again with the arguments a shard was registered with returns
  // the same instance and changes nothing. Fails with InvalidArgument if
  // |num_shards| <= 0, `desc.slot_numa_nodes` is neither empty nor
  // |num_shards| long, or `desc.local_slot` >= |num_shards|. Fails with
  // FailedPrecondition, leaving the registry unchanged, if `desc.shard_idx` is
  // registered to another instance or at another slot or global shard index,
  // its slot is taken by another shard, the instance was created with another
  // |num_layers|, |num_shards|, |parallelism|, |slice_byte_sizes|, or
  // (non-empty) `desc.slot_numa_nodes`, or a new instance would derive the
  // same listener or data port as an existing one. Re-initializing with
  // different arguments requires `Clear(/*delete_instances=*/true)` first; a
  // clear that keeps the instances also keeps their ports bound.
  absl::StatusOr<WeightSynchronizerBase*> GetOrCreateSynchronizer(
      const FfiShardDescriptor& desc, int32_t listener_port, int32_t num_layers,
      int32_t parallelism, const std::vector<size_t>& slice_byte_sizes,
      int32_t local_port, int32_t num_shards) ABSL_LOCKS_EXCLUDED(mu_);

  // Returns the instance registered for |shard_idx|, or nullptr if none is or
  // |shard_idx| is out of range.
  WeightSynchronizerBase* GetSynchronizerForShard(int32_t shard_idx) const
      ABSL_LOCKS_EXCLUDED(mu_);

  // Returns true if any registered instance has an active listener.
  bool HasActiveListener() const ABSL_LOCKS_EXCLUDED(mu_);

  // Returns |shard_idx|'s local slot within its instance (0 if unregistered).
  size_t GetLocalSlot(int32_t shard_idx) const ABSL_LOCKS_EXCLUDED(mu_);

  // Packs the endpoints of |shard_idx|'s instance into |out| (see
  // `ShardEndpoints`). The data IP is entry `local_slot % n` of the n local
  // IPs serving |shard_idx|'s local slot (`local_ips_for_shard`), i.e. a NIC
  // on the slot's NUMA node when known. The control-plane IP is resolved only
  // when |out| has room for it, and is the same for every slot of an instance.
  absl::Status WriteShardEndpoints(int32_t shard_idx,
                                   absl::Span<int32_t> out) const;

  // Records one completed multi-H2D shard. Returns true when a full round over
  // max(1, initialized shards, |num_shards|) shards has completed.
  bool RecordMultiH2dCompletion(size_t num_shards);

  // Drops all bookkeeping and unregisters every shard. If |delete_instances|,
  // also deletes the distinct instances that were registered to shards.
  void Clear(bool delete_instances) ABSL_LOCKS_EXCLUDED(mu_);

 private:
  // Selects the instance shared by one submanager, from the
  // `GetOrCreateSynchronizer` arguments that determine its ports. A negative
  // port means "none" and is stored as -1.
  struct InstanceKey {
    int32_t submanager_idx;
    int32_t listener_port;
    int32_t local_port;

    friend bool operator==(const InstanceKey& a, const InstanceKey& b) {
      return a.submanager_idx == b.submanager_idx &&
             a.listener_port == b.listener_port && a.local_port == b.local_port;
    }
    template <typename H>
    friend H AbslHashValue(H h, const InstanceKey& key) {
      return H::combine(std::move(h), key.submanager_idx, key.listener_port,
                        key.local_port);
    }
    template <typename Sink>
    friend void AbslStringify(Sink& sink, const InstanceKey& key) {
      sink.Append(absl::StrCat("{submanager_idx=", key.submanager_idx,
                               ", listener_port=", key.listener_port,
                               ", local_port=", key.local_port, "}"));
    }
  };

  struct SlotAndGlobal {
    size_t slot;
    int64_t global_shard;
  };

  // Creation arguments and registered shards of one instance.
  struct InstanceInfo {
    InstanceKey key;
    int32_t parallelism;
    std::vector<size_t> slice_byte_sizes;
    // NUMA node of every local slot; all -1 if created without NUMA nodes.
    std::vector<int32_t> slot_numa_nodes;
    // Local slot and global shard index of every registered `shard_idx`.
    absl::flat_hash_map<int32_t, SlotAndGlobal> shards;
  };

  // Fails with FailedPrecondition if registering |desc| with these arguments
  // in the existing instance |ws| would require different creation arguments.
  absl::Status ValidateReuse(WeightSynchronizerBase* ws,
                             const FfiShardDescriptor& desc, int32_t num_layers,
                             int32_t num_shards, int32_t parallelism,
                             const std::vector<size_t>& slice_byte_sizes) const
      ABSL_EXCLUSIVE_LOCKS_REQUIRED(mu_);

  mutable absl::Mutex mu_;
  const std::function<std::vector<HostNicAddress>()> host_nics_;
  std::array<WeightSynchronizerBase*, kMaxShards> shard_table_
      ABSL_GUARDED_BY(mu_) = {};
  absl::flat_hash_map<InstanceKey, WeightSynchronizerBase*> ws_map_
      ABSL_GUARDED_BY(mu_);
  absl::flat_hash_map<WeightSynchronizerBase*, InstanceInfo> instances_
      ABSL_GUARDED_BY(mu_);
  std::atomic<size_t> initialized_shards_{0};
  std::atomic<size_t> multi_h2d_completed_shards_{0};
};

#ifndef TENSORFLOW_COMPILER_XLA_FFI_FFI_H_
xla::ffi::Error TriggerWeightSynchronizerInitImpl(
    xla::ffi::AnyBuffer x, xla::ffi::AnyBuffer shard_idx_buf,
    xla::ffi::AnyBuffer slice_byte_sizes_buf, int32_t local_port,
    int32_t parallelism, int32_t num_layers, int32_t listener_port,
    int32_t num_shards, xla::ffi::Result<xla::ffi::AnyBuffer> out);

xla::ffi::Error TriggerWeightSynchronizerInitAndD2hHelper(
    xla::ffi::AnyBuffer shard_idx_buf, xla::ffi::AnyBuffer slice_byte_sizes_buf,
    absl::Span<const xla::ffi::AnyBuffer> jax_arrays, int32_t local_port,
    int32_t parallelism, int32_t num_layers, int32_t listener_port,
    int32_t num_shards, xla::ffi::Result<xla::ffi::AnyBuffer> out);

xla::ffi::Error TriggerMultiH2DImpl(xla::ffi::AnyBuffer shard_idx_buf,
                                    xla::ffi::RemainingRets rets);
#endif  // TENSORFLOW_COMPILER_XLA_FFI_FFI_H_

}  // namespace weight_sync
}  // namespace tpu_raiden

#endif  // THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_FRAMEWORKS_JAX_WEIGHT_SYNCHRONIZER_FFI_INTERNAL_H_
