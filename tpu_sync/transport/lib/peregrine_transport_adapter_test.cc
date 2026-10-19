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

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_cat.h"
#include "absl/synchronization/notification.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"
#include "absl/types/span.h"
#include "peregrine/src/api/transport.h"
#include "peregrine/src/api/transport_types.h"
#include "peregrine/src/api/transport_util.h"
#include "tpu_sync/transport/lib/transport_adapter.h"

namespace tpu_raiden::transport::lib {
namespace {

using ::absl_testing::IsOkAndHolds;
using ::absl_testing::StatusIs;
using ::testing::IsEmpty;
using ::testing::NotNull;

std::string PickUnusedLoopbackEndpoint() {
  const int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return "";
  int reuse = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    close(fd);
    return "";
  }
  socklen_t len = sizeof(addr);
  if (getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
    close(fd);
    return "";
  }
  const uint16_t port = ntohs(addr.sin_port);
  close(fd);
  return absl::StrCat("127.0.0.1:", port);
}

// Creates a real Peregrine TCP transport listening on a loopback endpoint.
std::unique_ptr<::peregrine::Transport> CreateLoopbackTransport() {
  const std::string endpoint = PickUnusedLoopbackEndpoint();
  if (endpoint.empty()) return nullptr;
  return ::peregrine::CreateTransport(endpoint, ::peregrine::TransportType::kTcp,
                                      /*num_conns_per_peer=*/1);
}

TEST(PeregrineTransportAdapterTest, NullTransportFailsGracefully) {
  PeregrineTransportAdapter adapter(
      std::unique_ptr<::peregrine::Transport>(nullptr));

  uint8_t buf[4] = {1, 2, 3, 4};
  Request req = {};
  req.op = TransferOp::kBlockPushExplicit;
  req.laddr = buf;
  req.raddr = buf;
  req.len = sizeof(buf);

  absl::Status callback_status = absl::OkStatus();
  absl::StatusOr<Handle> handle = adapter.Post(
      /*peers=*/{"127.0.0.1:1234"}, /*requests=*/absl::MakeConstSpan(&req, 1),
      /*src_block_ids=*/{}, /*dst_block_ids=*/{},
      [&](absl::StatusOr<std::vector<int>> result) {
        callback_status = result.status();
      });

  EXPECT_THAT(handle, StatusIs(absl::StatusCode::kFailedPrecondition));
  EXPECT_THAT(callback_status, StatusIs(absl::StatusCode::kFailedPrecondition));
  EXPECT_THAT(adapter.Poll(1), StatusIs(absl::StatusCode::kFailedPrecondition));
}

TEST(PeregrineTransportAdapterTest, PostWithEmptyPeersFails) {
  std::unique_ptr<::peregrine::Transport> transport = CreateLoopbackTransport();
  ASSERT_THAT(transport, NotNull());
  PeregrineTransportAdapter adapter(std::move(transport));

  uint8_t buf[4] = {1, 2, 3, 4};
  Request req = {};
  req.op = TransferOp::kBlockPushExplicit;
  req.laddr = buf;
  req.raddr = buf;
  req.len = sizeof(buf);

  absl::Status callback_status = absl::OkStatus();
  absl::StatusOr<Handle> handle = adapter.Post(
      /*peers=*/{}, /*requests=*/absl::MakeConstSpan(&req, 1),
      /*src_block_ids=*/{}, /*dst_block_ids=*/{},
      [&](absl::StatusOr<std::vector<int>> result) {
        callback_status = result.status();
      });

  EXPECT_THAT(handle, StatusIs(absl::StatusCode::kInvalidArgument));
  EXPECT_THAT(callback_status, StatusIs(absl::StatusCode::kInvalidArgument));
}

TEST(PeregrineTransportAdapterTest, PostWithEmptyRequestsFails) {
  std::unique_ptr<::peregrine::Transport> transport = CreateLoopbackTransport();
  ASSERT_THAT(transport, NotNull());
  PeregrineTransportAdapter adapter(std::move(transport));

  absl::Status callback_status = absl::OkStatus();
  absl::StatusOr<Handle> handle = adapter.Post(
      /*peers=*/{"127.0.0.1:1234"}, /*requests=*/{},
      /*src_block_ids=*/{}, /*dst_block_ids=*/{},
      [&](absl::StatusOr<std::vector<int>> result) {
        callback_status = result.status();
      });

  EXPECT_THAT(handle, StatusIs(absl::StatusCode::kInvalidArgument));
  EXPECT_THAT(callback_status, StatusIs(absl::StatusCode::kInvalidArgument));
}

TEST(PeregrineTransportAdapterTest, PostSynchronousFailureInvokesCallback) {
  std::unique_ptr<::peregrine::Transport> transport = CreateLoopbackTransport();
  ASSERT_THAT(transport, NotNull());
  PeregrineTransportAdapter adapter(std::move(transport));

  uint8_t buf[4] = {1, 2, 3, 4};
  Request req = {};
  req.op = TransferOp::kBlockPushExplicit;
  req.laddr = buf;
  req.raddr = buf;
  req.len = sizeof(buf);

  // Peregrine rejects a malformed peer endpoint synchronously.
  absl::Status callback_status = absl::OkStatus();
  absl::StatusOr<Handle> handle = adapter.Post(
      /*peers=*/{"invalid"}, /*requests=*/absl::MakeConstSpan(&req, 1),
      /*src_block_ids=*/{}, /*dst_block_ids=*/{},
      [&](absl::StatusOr<std::vector<int>> result) {
        callback_status = result.status();
      });

  EXPECT_THAT(handle, StatusIs(absl::StatusCode::kInvalidArgument));
  EXPECT_THAT(callback_status, StatusIs(absl::StatusCode::kInvalidArgument));
}

TEST(PeregrineTransportAdapterTest, PollUnknownHandleFails) {
  std::unique_ptr<::peregrine::Transport> transport = CreateLoopbackTransport();
  ASSERT_THAT(transport, NotNull());
  PeregrineTransportAdapter adapter(std::move(transport));

  EXPECT_THAT(adapter.Poll(12345), StatusIs(absl::StatusCode::kNotFound));
}

TEST(PeregrineTransportAdapterTest, EndToEndTcpWriteAndReadOverLoopback) {
  const std::string local_endpoint = PickUnusedLoopbackEndpoint();
  const std::string remote_endpoint = PickUnusedLoopbackEndpoint();
  ASSERT_FALSE(local_endpoint.empty());
  ASSERT_FALSE(remote_endpoint.empty());

  std::unique_ptr<::peregrine::Transport> local_transport =
      ::peregrine::CreateTransport(local_endpoint,
                                   ::peregrine::TransportType::kTcp,
                                   /*num_conns_per_peer=*/2);
  std::unique_ptr<::peregrine::Transport> remote_transport =
      ::peregrine::CreateTransport(remote_endpoint,
                                   ::peregrine::TransportType::kTcp,
                                   /*num_conns_per_peer=*/2);
  ASSERT_NE(local_transport, nullptr);
  ASSERT_NE(remote_transport, nullptr);
  PeregrineTransportAdapter local_adapter(std::move(local_transport));
  PeregrineTransportAdapter remote_adapter(std::move(remote_transport));

  std::vector<uint8_t> src_buf = {10, 20, 30, 40, 50, 60, 70, 80};
  std::vector<uint8_t> remote_buf(src_buf.size(), 0);

  // 1. Write (Op::kWrite) with completion callback.
  Request write_req = {};
  write_req.op = TransferOp::kBlockPushExplicit;
  write_req.laddr = src_buf.data();
  write_req.raddr = remote_buf.data();
  write_req.len = src_buf.size();

  absl::Notification write_done;
  absl::StatusOr<std::vector<int>> write_result;
  absl::StatusOr<Handle> write_handle = local_adapter.Post(
      /*peers=*/{remote_endpoint},
      /*requests=*/absl::MakeConstSpan(&write_req, 1),
      /*src_block_ids=*/{}, /*dst_block_ids=*/{},
      [&](absl::StatusOr<std::vector<int>> res) {
        write_result = std::move(res);
        write_done.Notify();
      });

  ABSL_ASSERT_OK(write_handle);
  ASSERT_TRUE(write_done.WaitForNotificationWithTimeout(absl::Seconds(10)));
  EXPECT_THAT(write_result, IsOkAndHolds(IsEmpty()));
  EXPECT_EQ(remote_buf, src_buf);

  // 2. Read (Op::kRead) with Poll().
  std::vector<uint8_t> read_buf(src_buf.size(), 0);
  Request read_req = {};
  read_req.op = TransferOp::kBlockPull;
  read_req.laddr = read_buf.data();
  read_req.raddr = remote_buf.data();
  read_req.len = read_buf.size();

  absl::StatusOr<Handle> read_handle = local_adapter.Post(
      /*peers=*/{remote_endpoint},
      /*requests=*/absl::MakeConstSpan(&read_req, 1),
      /*src_block_ids=*/{}, /*dst_block_ids=*/{}, /*on_complete=*/nullptr);
  ABSL_ASSERT_OK(read_handle);

  Status poll_status = Status::kInProgress;
  const absl::Time deadline = absl::Now() + absl::Seconds(10);
  while (absl::Now() < deadline) {
    absl::StatusOr<Status> current = local_adapter.Poll(*read_handle);
    ABSL_ASSERT_OK(current);
    poll_status = *current;
    if (poll_status != Status::kInProgress) {
      break;
    }
    absl::SleepFor(absl::Milliseconds(20));
  }
  EXPECT_EQ(poll_status, Status::kSuccess);
  EXPECT_EQ(read_buf, src_buf);
}

}  // namespace
}  // namespace tpu_raiden::transport::lib
