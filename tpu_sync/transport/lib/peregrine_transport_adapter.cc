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

#include "tpu_sync/transport/lib/peregrine_transport_adapter.h"

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "absl/status/status.h"
#include "absl/status/status_macros.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_cat.h"
#include "absl/types/span.h"
#include "peregrine/src/api/transport.h"
#include "peregrine/src/api/transport_types.h"
#include "tpu_sync/transport/lib/transport_adapter.h"

namespace tpu_raiden::transport::lib {
namespace {

using ::peregrine::Op;

absl::Status ReportError(CompletionCallback& on_complete, absl::Status status) {
  if (on_complete) {
    on_complete(status);
  }
  return status;
}

}  // namespace

PeregrineTransportAdapter::PeregrineTransportAdapter(
    std::unique_ptr<::peregrine::Transport> transport)
    : transport_(std::move(transport)) {}

absl::StatusOr<Handle> PeregrineTransportAdapter::Post(
    absl::Span<const std::string> peers, absl::Span<const Request> requests,
    absl::Span<const int> /*src_block_ids*/,
    absl::Span<const int> /*dst_block_ids*/, CompletionCallback on_complete) {
  if (transport_ == nullptr) {
    return ReportError(on_complete, absl::FailedPreconditionError(
                                        "Peregrine transport is null"));
  }
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
  if (transport_ == nullptr) {
    return absl::FailedPreconditionError("Peregrine transport is null");
  }
  return transport_->Poll(::peregrine::Handle(handle));
}

}  // namespace tpu_raiden::transport::lib
