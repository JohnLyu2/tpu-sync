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

#include "tpu_sync/core/buffer.h"

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "tpu_sync/core/raiden_transfer_endpoint.h"
#include "tpu_sync/proto/worker_service.pb.h"

namespace tpu_raiden {

::tpu_sync::proto::BufferProto Buffer::ToProto() const {
  ::tpu_sync::proto::BufferProto proto;
  if (index_ >= 0) {
    proto.set_index(index_);
  }
  for (const auto& shard : shards_) {
    proto.add_buffer_handles()->set_handle(shard.handle);
  }
  proto.set_memory_type(memory_type_);
  if (remote_address_.has_value()) {
    proto.set_remote_address(*remote_address_);
  }
  for (const auto& ep : remote_descriptors_) {
    *proto.add_remote_descriptors() = ep.ToProto();
  }
  for (const auto& group : remote_worker_endpoints_) {
    auto* proto_group = proto.add_remote_worker_endpoints();
    proto_group->set_node_id(group.node_id);
    proto_group->set_worker_id(group.worker_id);
    for (const auto& ep : group.endpoints) {
      *proto_group->add_endpoints() = ep.ToProto();
    }
  }
  return proto;
}

Buffer Buffer::FromProto(const ::tpu_sync::proto::BufferProto& proto,
                         std::optional<std::string> remote_address) {
  int index = proto.has_index() ? proto.index() : -1;
  std::vector<BufferShard> shards;
  shards.reserve(proto.buffer_handles_size());
  for (const auto& handle_proto : proto.buffer_handles()) {
    shards.push_back(BufferShard{
        .handle = handle_proto.handle(),
        .offset = 0,
        .size = 0,
    });
  }
  ::tpu_sync::rpc::MemoryType memory_type = proto.memory_type();
  std::optional<std::string> addr = remote_address;
  if (!addr.has_value() && !proto.remote_address().empty()) {
    addr = proto.remote_address();
  }
  std::vector<RaidenTransferEndpoint> remote_descriptors;
  remote_descriptors.reserve(proto.remote_descriptors_size());
  for (const auto& ep_proto : proto.remote_descriptors()) {
    remote_descriptors.push_back(RaidenTransferEndpoint::FromProto(ep_proto));
  }
  Buffer buffer(index, std::move(shards), std::move(addr), memory_type,
                std::move(remote_descriptors));
  std::vector<RaidenWorkerEndpoints> remote_worker_endpoints;
  remote_worker_endpoints.reserve(proto.remote_worker_endpoints_size());
  for (const auto& group_proto : proto.remote_worker_endpoints()) {
    RaidenWorkerEndpoints group;
    group.node_id = group_proto.node_id();
    group.worker_id = group_proto.worker_id();
    group.endpoints.reserve(group_proto.endpoints_size());
    for (const auto& ep_proto : group_proto.endpoints()) {
      group.endpoints.push_back(RaidenTransferEndpoint::FromProto(ep_proto));
    }
    remote_worker_endpoints.push_back(std::move(group));
  }
  buffer.set_remote_worker_endpoints(std::move(remote_worker_endpoints));
  return buffer;
}

}  // namespace tpu_raiden
