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

#include "tpu_sync/transport/lib/adapter/peregrine_transport_adapter.h"

#include <cstddef>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "absl/memory/memory.h"
#include "absl/status/status.h"
#include "absl/status/status_macros.h"
#include "absl/status/statusor.h"
#include "absl/strings/match.h"
#include "absl/strings/numbers.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"
#include "absl/types/span.h"
#include "peregrine/src/api/transport.h"
#include "peregrine/src/api/transport_types.h"
#include "peregrine/src/api/transport_util.h"
#include "tpu_sync/transport/lib/adapter/transport_adapter.h"

namespace tpu_raiden::transport::lib {
namespace {

using ::peregrine::Op;

absl::Status ReportError(CompletionCallback& on_complete, absl::Status status) {
  if (on_complete) {
    on_complete(status);
  }
  return status;
}

// Port of an "ip:port" / "[ipv6]:port" endpoint, or -1 if it has none.
int PortOf(absl::string_view endpoint) {
  const size_t colon = endpoint.rfind(':');
  if (colon == absl::string_view::npos) return -1;
  int port;
  return absl::SimpleAtoi(endpoint.substr(colon + 1), &port) ? port : -1;
}

}  // namespace

absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>>
PeregrineTransportAdapter::Create(absl::string_view bind_ip, int port,
                                  int num_conns_per_peer) {
  const std::string endpoint = absl::StrContains(bind_ip, ':')
                                   ? absl::StrCat("[", bind_ip, "]:", port)
                                   : absl::StrCat(bind_ip, ":", port);
  std::unique_ptr<::peregrine::Transport> transport =
      ::peregrine::CreateTransport(endpoint, ::peregrine::TransportType::kTcp,
                                   num_conns_per_peer);
  if (transport == nullptr) {
    return absl::UnavailableError(
        absl::StrCat("Failed to create Peregrine transport on ", endpoint));
  }
  const int local_port = PortOf(transport->GetControlEndpoint());
  if (local_port <= 0) {
    return absl::InternalError(
        absl::StrCat("Peregrine transport on ", endpoint,
                     " reported an invalid control endpoint: ",
                     transport->GetControlEndpoint()));
  }
  return absl::WrapUnique(
      new PeregrineTransportAdapter(std::move(transport), local_port));
}

PeregrineTransportAdapter::PeregrineTransportAdapter(
    std::unique_ptr<::peregrine::Transport> transport, int local_port)
    : transport_(std::move(transport)), local_port_(local_port) {}

absl::StatusOr<Handle> PeregrineTransportAdapter::Post(
    absl::Span<const std::string> peers, absl::Span<const Request> requests,
    absl::Span<const int> /*src_block_ids*/,
    absl::Span<const int> /*dst_block_ids*/, CompletionCallback on_complete) {
  if (peers.empty()) {
    return ReportError(on_complete,
                       absl::InvalidArgumentError("Peers cannot be empty"));
  }
  if (requests.empty()) {
    return ReportError(on_complete,
                       absl::InvalidArgumentError("Requests cannot be empty"));
  }

  // Every request of one Post carries the same op. Receiver-allocated pushes
  // have no remote address and cannot be expressed over Peregrine.
  Op op;
  switch (requests.front().op) {
    case TransferOp::kBlockPushExplicit:
      op = Op::kWrite;
      break;
    case TransferOp::kBlockPull:
      op = Op::kRead;
      break;
    case TransferOp::kBlockPush:
      return ReportError(
          on_complete,
          absl::UnimplementedError(
              "Receiver-allocated block push is not supported over Peregrine; "
              "explicit destination block ids are required"));
    default:
      return ReportError(on_complete,
                         absl::InvalidArgumentError(absl::StrCat(
                             "Unsupported op over Peregrine: ",
                             static_cast<int>(requests.front().op))));
  }

  std::vector<::peregrine::Request> peregrine_requests;
  peregrine_requests.reserve(requests.size());
  for (const Request& req : requests) {
    peregrine_requests.push_back(::peregrine::Request{
        .op = op,
        .laddr = req.laddr,
        .raddr = req.raddr,
        .len = req.len,
    });
  }

  // Peregrine identifies a host by a single control-plane endpoint and handles
  // multi-NIC data transfer internally, so only the first peer is used.
  // TODO(swasthi): Weight sync broadcasts to multiple distinct hosts via
  // `ShardPushEntryProto.dst_peers`; that path is not supported here yet.
  const std::string& peer = peers.front();

  if (!on_complete) {
    ABSL_ASSIGN_OR_RETURN(
        const ::peregrine::Handle handle,
        transport_->Post(peer, peregrine_requests, /*on_complete=*/nullptr));
    return handle.value();
  }

  auto callback = std::make_shared<CompletionCallback>(std::move(on_complete));

  absl::StatusOr<::peregrine::Handle> handle = transport_->Post(
      peer, peregrine_requests, [callback](::peregrine::Status status) {
        if (status == ::peregrine::Status::kSuccess) {
          (*callback)(std::vector<int>{});
        } else {
          (*callback)(absl::InternalError(
              absl::StrCat("Peregrine transport request failed with status: ",
                           ::peregrine::ToString(status))));
        }
      });
  if (!handle.ok()) {
    (*callback)(handle.status());
    return handle.status();
  }
  return handle->value();
}

absl::StatusOr<Status> PeregrineTransportAdapter::Poll(Handle handle) {
  return transport_->Poll(::peregrine::Handle(handle));
}

}  // namespace tpu_raiden::transport::lib
