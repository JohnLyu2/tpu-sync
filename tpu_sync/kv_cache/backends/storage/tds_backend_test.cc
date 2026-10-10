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

#include <cstdint>
#include <type_traits>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/status/statusor.h"
#include "absl/synchronization/notification.h"
#include "tpu_sync/kv_cache/backends/backend.h"

namespace tpu_raiden {
namespace kv_cache {
namespace backends {
namespace storage {
namespace {

using ::absl_testing::StatusIs;

static_assert(std::is_base_of_v<tkv::backends::KVBackend,
                                tkv::backends::storage::TdsKVBackend>);

TEST(TdsKVBackendTest, StubbedAsyncMethodsReturnUnimplemented) {
  TdsKVBackend backend(std::string(kTdsBackendName),
                       {{"root_dir", ::testing::TempDir()}});
  EXPECT_EQ(backend.name(), kTdsBackendName);
  EXPECT_EQ(backend.GetProperty("root_dir"), ::testing::TempDir());

  uint8_t byte = 0;
  HostBufferDescriptor slice{.ptr = &byte, .size = 1};
  BlockKey key{.block_hash = "h", .resolved_key = "/tmp/h.bin"};

  {
    absl::Notification done;
    absl::Status status;
    backend.WriteAsync(key, {slice}, 1, [&](absl::Status s) {
      status = std::move(s);
      done.Notify();
    });
    done.WaitForNotification();
    EXPECT_THAT(status, StatusIs(absl::StatusCode::kUnimplemented));
  }

  {
    absl::Notification done;
    absl::Status status;
    backend.ReadAsync(key, {slice}, 1, [&](absl::Status s) {
      status = std::move(s);
      done.Notify();
    });
    done.WaitForNotification();
    EXPECT_THAT(status, StatusIs(absl::StatusCode::kUnimplemented));
  }

  {
    absl::Notification done;
    std::vector<absl::StatusOr<bool>> results;
    backend.BatchExistsAsync({key}, [&](std::vector<absl::StatusOr<bool>> r) {
      results = std::move(r);
      done.Notify();
    });
    done.WaitForNotification();
    ASSERT_EQ(results.size(), 1);
    EXPECT_THAT(results[0], StatusIs(absl::StatusCode::kUnimplemented));
  }
}

}  // namespace
}  // namespace storage
}  // namespace backends
}  // namespace kv_cache
}  // namespace tpu_raiden
