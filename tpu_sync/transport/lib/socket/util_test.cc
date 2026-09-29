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

#include "tpu_sync/transport/lib/socket/util.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <string>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/log/check.h"
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/strings/str_cat.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"

namespace tpu_raiden::transport::lib {
namespace {

using ::absl_testing::StatusIs;
using ::testing::HasSubstr;

// A loopback listener that never accepts. The kernel still completes the
// handshake of the connections that fit in its accept queue.
class LoopbackListener {
 public:
  explicit LoopbackListener(int backlog) : backlog_(backlog) {
    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t len = sizeof(addr);
    auto* sa = reinterpret_cast<sockaddr*>(&addr);
    listen_fd_ = socket(AF_INET, SOCK_STREAM, 0);
    CHECK_GE(listen_fd_, 0);
    CHECK_EQ(bind(listen_fd_, sa, len), 0);
    CHECK_EQ(listen(listen_fd_, backlog_), 0);
    CHECK_EQ(getsockname(listen_fd_, sa, &len), 0);
    addr_ = addr;
  }
  LoopbackListener(const LoopbackListener&) = delete;
  LoopbackListener& operator=(const LoopbackListener&) = delete;
  ~LoopbackListener() {
    for (int fd : filler_fds_) close(fd);
    close(listen_fd_);
  }

  // Fills the accept queue, so the kernel drops every further SYN and a
  // connect() can only retry.
  void FillAcceptQueue() {
    for (int i = 0; i <= backlog_ + 1; ++i) {
      const int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
      CHECK_GE(fd, 0);
      connect(fd, reinterpret_cast<const sockaddr*>(&addr_), sizeof(addr_));
      filler_fds_.push_back(fd);
    }
    absl::SleepFor(absl::Milliseconds(100));
  }

  std::string address() const {
    return absl::StrCat("127.0.0.1:", ntohs(addr_.sin_port));
  }

 private:
  const int backlog_;
  int listen_fd_ = -1;
  sockaddr_in addr_ = {};
  std::vector<int> filler_fds_;
};

TEST(ConnectToPeerTest, GivesUpWhenPeerNeverCompletesHandshake) {
  LoopbackListener listener(/*backlog=*/0);
  listener.FillAcceptQueue();

  const absl::Time start = absl::Now();
  EXPECT_THAT(ConnectToPeer(listener.address()),
              StatusIs(absl::StatusCode::kUnavailable, HasSubstr("timed out")));
  // Well under the kernel's ~127 s SYN retry budget.
  EXPECT_LT(absl::Now() - start, absl::Seconds(30));
}

}  // namespace
}  // namespace tpu_raiden::transport::lib
