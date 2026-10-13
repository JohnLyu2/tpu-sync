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

#ifndef THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_TRANSPORT_LIB_PEREGRINE_TRANSPORT_ADAPTER_H_
#define THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_TRANSPORT_LIB_PEREGRINE_TRANSPORT_ADAPTER_H_

#include <memory>
#include <string>

#include "absl/status/statusor.h"
#include "absl/types/span.h"
#include "peregrine/src/api/transport.h"
#include "tpu_sync/transport/lib/transport_adapter.h"

namespace tpu_raiden::transport::lib {

// Peregrine implementation of TransportAdapter.
class PeregrineTransportAdapter : public TransportAdapter {
 public:
  explicit PeregrineTransportAdapter(
      std::unique_ptr<::peregrine::Transport> transport);
  ~PeregrineTransportAdapter() override = default;

  absl::StatusOr<Handle> Post(absl::Span<const std::string> peers,
                              absl::Span<const Request> requests,
                              absl::Span<const int> src_block_ids,
                              absl::Span<const int> dst_block_ids,
                              CompletionCallback on_complete) override;

  absl::StatusOr<Status> Poll(Handle handle) override;

 private:
  std::unique_ptr<::peregrine::Transport> transport_;
};

}  // namespace tpu_raiden::transport::lib

#endif  // THIRD_PARTY_TPU_RAIDEN_TPU_SYNC_TRANSPORT_LIB_PEREGRINE_TRANSPORT_ADAPTER_H_
