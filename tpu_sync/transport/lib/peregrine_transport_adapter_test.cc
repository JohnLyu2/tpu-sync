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
#include "tpu_sync/transport/lib/transport_adapter.h"

namespace tpu_raiden::transport::lib {
namespace {

using ::absl_testing::IsOkAndHolds;
using ::absl_testing::StatusIs;
using ::testing::IsEmpty;

int PickUnusedLoopbackPort() {
  const int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return 0;
  int reuse = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    close(fd);
    return 0;
  }
  socklen_t len = sizeof(addr);
  if (getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
    close(fd);
    return 0;
  }
  const uint16_t port = ntohs(addr.sin_port);
  close(fd);
  return port;
}

// Adapter bound to 127.0.0.1 on a kernel-assigned port.
absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>> CreateAdapter(
    int num_conns_per_peer = 1) {
  return PeregrineTransportAdapter::Create("127.0.0.1", /*port=*/0,
                                           num_conns_per_peer);
}

TEST(PeregrineTransportAdapterTest, CreateBindsKernelAssignedPort) {
  absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>> adapter =
      CreateAdapter(/*num_conns_per_peer=*/4);
  ABSL_ASSERT_OK(adapter);
  EXPECT_GT((*adapter)->local_port(), 0);
}

TEST(PeregrineTransportAdapterTest, CreateBindsRequestedPort) {
  const int port = PickUnusedLoopbackPort();
  ASSERT_NE(port, 0);

  absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>> adapter =
      PeregrineTransportAdapter::Create("127.0.0.1", port,
                                        /*num_conns_per_peer=*/1);
  ABSL_ASSERT_OK(adapter);
  EXPECT_EQ((*adapter)->local_port(), port);
}

TEST(PeregrineTransportAdapterTest, CreateBindsIpv6Loopback) {
  absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>> adapter =
      PeregrineTransportAdapter::Create("::1", /*port=*/0,
                                        /*num_conns_per_peer=*/1);
  if (!adapter.ok()) {
    GTEST_SKIP() << "IPv6 loopback unavailable: " << adapter.status();
  }
  EXPECT_GT((*adapter)->local_port(), 0);
}

TEST(PeregrineTransportAdapterTest, ReceiverAllocatedPushIsUnimplemented) {
  absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>> adapter =
      CreateAdapter();
  ABSL_ASSERT_OK(adapter);

  uint8_t buf[4] = {};
  Request req = {};
  req.op = TransferOp::kBlockPush;
  req.laddr = buf;
  req.raddr = buf;
  req.len = sizeof(buf);

  absl::Status callback_status = absl::OkStatus();
  absl::StatusOr<Handle> handle = (*adapter)->Post(
      /*peers=*/{"127.0.0.1:1234"}, absl::MakeConstSpan(&req, 1),
      /*src_block_ids=*/{}, /*dst_block_ids=*/{},
      [&](absl::StatusOr<std::vector<int>> result) {
        callback_status = result.status();
      });
  EXPECT_THAT(handle, StatusIs(absl::StatusCode::kUnimplemented));
  EXPECT_THAT(callback_status, StatusIs(absl::StatusCode::kUnimplemented));
}

TEST(PeregrineTransportAdapterTest, PostWithEmptyPeersFails) {
  absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>> adapter =
      CreateAdapter();
  ABSL_ASSERT_OK(adapter);

  uint8_t buf[4] = {1, 2, 3, 4};
  Request req = {};
  req.op = TransferOp::kBlockPushExplicit;
  req.laddr = buf;
  req.raddr = buf;
  req.len = sizeof(buf);

  absl::Status callback_status = absl::OkStatus();
  absl::StatusOr<Handle> handle = (*adapter)->Post(
      /*peers=*/{}, /*requests=*/absl::MakeConstSpan(&req, 1),
      /*src_block_ids=*/{}, /*dst_block_ids=*/{},
      [&](absl::StatusOr<std::vector<int>> result) {
        callback_status = result.status();
      });

  EXPECT_THAT(handle, StatusIs(absl::StatusCode::kInvalidArgument));
  EXPECT_THAT(callback_status, StatusIs(absl::StatusCode::kInvalidArgument));
}

TEST(PeregrineTransportAdapterTest, PostWithEmptyRequestsFails) {
  absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>> adapter =
      CreateAdapter();
  ABSL_ASSERT_OK(adapter);

  absl::Status callback_status = absl::OkStatus();
  absl::StatusOr<Handle> handle = (*adapter)->Post(
      /*peers=*/{"127.0.0.1:1234"}, /*requests=*/{},
      /*src_block_ids=*/{}, /*dst_block_ids=*/{},
      [&](absl::StatusOr<std::vector<int>> result) {
        callback_status = result.status();
      });

  EXPECT_THAT(handle, StatusIs(absl::StatusCode::kInvalidArgument));
  EXPECT_THAT(callback_status, StatusIs(absl::StatusCode::kInvalidArgument));
}

TEST(PeregrineTransportAdapterTest, PostSynchronousFailureInvokesCallback) {
  absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>> adapter =
      CreateAdapter();
  ABSL_ASSERT_OK(adapter);

  uint8_t buf[4] = {1, 2, 3, 4};
  Request req = {};
  req.op = TransferOp::kBlockPushExplicit;
  req.laddr = buf;
  req.raddr = buf;
  req.len = sizeof(buf);

  // Peregrine rejects a malformed peer endpoint synchronously.
  absl::Status callback_status = absl::OkStatus();
  absl::StatusOr<Handle> handle = (*adapter)->Post(
      /*peers=*/{"invalid"}, /*requests=*/absl::MakeConstSpan(&req, 1),
      /*src_block_ids=*/{}, /*dst_block_ids=*/{},
      [&](absl::StatusOr<std::vector<int>> result) {
        callback_status = result.status();
      });

  EXPECT_THAT(handle, StatusIs(absl::StatusCode::kInvalidArgument));
  EXPECT_THAT(callback_status, StatusIs(absl::StatusCode::kInvalidArgument));
}

TEST(PeregrineTransportAdapterTest, PollUnknownHandleFails) {
  absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>> adapter =
      CreateAdapter();
  ABSL_ASSERT_OK(adapter);

  EXPECT_THAT((*adapter)->Poll(12345), StatusIs(absl::StatusCode::kNotFound));
}

TEST(PeregrineTransportAdapterTest, EndToEndTcpWriteAndReadOverLoopback) {
  absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>> local =
      CreateAdapter(/*num_conns_per_peer=*/2);
  ABSL_ASSERT_OK(local);
  absl::StatusOr<std::unique_ptr<PeregrineTransportAdapter>> remote =
      CreateAdapter(/*num_conns_per_peer=*/2);
  ABSL_ASSERT_OK(remote);
  const std::string remote_endpoint =
      absl::StrCat("127.0.0.1:", (*remote)->local_port());

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
  absl::StatusOr<Handle> write_handle = (*local)->Post(
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

  absl::StatusOr<Handle> read_handle = (*local)->Post(
      /*peers=*/{remote_endpoint},
      /*requests=*/absl::MakeConstSpan(&read_req, 1),
      /*src_block_ids=*/{}, /*dst_block_ids=*/{},
      /*on_complete=*/nullptr);
  ABSL_ASSERT_OK(read_handle);

  Status poll_status = Status::kInProgress;
  const absl::Time deadline = absl::Now() + absl::Seconds(10);
  while (absl::Now() < deadline) {
    absl::StatusOr<Status> current = (*local)->Poll(*read_handle);
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
