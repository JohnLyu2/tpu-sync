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

#include "tpu_sync/core/staging_arena.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/status/statusor.h"
#include "xla/pjrt/pjrt_client.h"
#include "tpu_sync/core/host_memory_allocator.h"

namespace tpu_raiden {
namespace {

using ::absl_testing::IsOk;
using ::absl_testing::StatusIs;

TEST(StagingArenaTest, LayerOrderAcquireAndReleaseReuse) {
  StagingArena arena(StagingArena::Config{
      .initial_capacity = 2,
      .num_shards = 2,
      .allow_dynamic_growth = false,
  });

  EXPECT_EQ(arena.size(), 2);
  EXPECT_EQ(arena.num_chunks(), 1);
  EXPECT_EQ(arena.chunk_size(), 2);
  EXPECT_EQ(arena.available_count(), 2);
  EXPECT_EQ(arena.in_use_count(), 0);

  uint8_t dummy_buf_a = 0xAA;
  uint8_t dummy_buf_b = 0xBB;

  // Simulate processing 6 layers in layer order while only holding 1 slot at a
  // time. The arena should reuse slot 0 without growing.
  for (size_t step = 0; step < 6; ++step) {
    absl::StatusOr<StagingArena::Allocation> alloc = arena.Acquire();
    ASSERT_THAT(alloc, IsOk());
    ASSERT_TRUE(alloc->valid());
    EXPECT_EQ(alloc->layer_idx(), 0);
    EXPECT_EQ(arena.in_use_count(), 1);
    EXPECT_EQ(arena.available_count(), 1);
    ASSERT_EQ((*alloc)->shards.size(), 2);

    if (step == 0) {
      (*alloc)->shards[0].host_ptr = &dummy_buf_a;
      (*alloc)->shards[0].host_size = 64;
      (*alloc)->shards[1].host_ptr = &dummy_buf_b;
      (*alloc)->shards[1].host_size = 128;
    } else {
      // Buffer pointers remain intact across releases when
      // release_memory_on_free is false.
      EXPECT_EQ((*alloc)->shards[0].host_ptr, &dummy_buf_a);
      EXPECT_EQ((*alloc)->shards[0].host_size, 64);
      EXPECT_EQ((*alloc)->shards[1].host_ptr, &dummy_buf_b);
      EXPECT_EQ((*alloc)->shards[1].host_size, 128);
    }

    // Verify backward-compatible index access points to the same LayerInfoBase.
    EXPECT_EQ(&arena.GetLayer(alloc->layer_idx()), alloc->get());
    EXPECT_EQ(&arena[alloc->layer_idx()], alloc->get());
  }

  EXPECT_EQ(arena.in_use_count(), 0);
  EXPECT_EQ(arena.available_count(), 2);
  EXPECT_EQ(arena.num_chunks(), 1);
}

TEST(StagingArenaTest, OutOfCapacityWithoutDynamicGrowthReturnsError) {
  StagingArena arena(StagingArena::Config{
      .initial_capacity = 2,
      .num_shards = 1,
      .allow_dynamic_growth = false,
  });

  absl::StatusOr<StagingArena::Allocation> alloc0 = arena.Acquire();
  ASSERT_THAT(alloc0, IsOk());
  absl::StatusOr<StagingArena::Allocation> alloc1 = arena.Acquire();
  ASSERT_THAT(alloc1, IsOk());
  EXPECT_EQ(alloc0->layer_idx(), 0);
  EXPECT_EQ(alloc1->layer_idx(), 1);
  EXPECT_EQ(arena.in_use_count(), 2);
  EXPECT_EQ(arena.available_count(), 0);

  EXPECT_THAT(arena.Acquire(), StatusIs(absl::StatusCode::kResourceExhausted));

  // Explicitly releasing alloc0 returns slot 0 to the arena immediately.
  alloc0->Release();
  EXPECT_FALSE(alloc0->valid());
  EXPECT_EQ(arena.in_use_count(), 1);
  EXPECT_EQ(arena.available_count(), 1);

  absl::StatusOr<StagingArena::Allocation> alloc_reused = arena.Acquire();
  ASSERT_THAT(alloc_reused, IsOk());
  EXPECT_EQ(alloc_reused->layer_idx(), 0);
}

TEST(StagingArenaTest, DynamicCapacityGrowthPreservesPointerStability) {
  size_t allocator_calls = 0;
  HostBufferAllocator default_alloc = MakeDefaultHostBufferAllocator();
  HostBufferAllocator counting_alloc = [&](size_t size_bytes,
                                           const xla::PjRtDevice* device)
      -> absl::StatusOr<HostBufferAllocation> {
    ++allocator_calls;
    return default_alloc(size_bytes, device);
  };

  StagingArena arena(
      StagingArena::Config{
          .initial_capacity = 2,
          .num_shards = 3,
          .shard_host_size = 128,
          .allow_dynamic_growth = true,
      },
      counting_alloc);

  // Initial chunk of 2 layers * 3 shards = 6 allocations.
  EXPECT_EQ(allocator_calls, 6);

  absl::StatusOr<StagingArena::Allocation> alloc0 = arena.Acquire();
  ASSERT_THAT(alloc0, IsOk());
  absl::StatusOr<StagingArena::Allocation> alloc1 = arena.Acquire();
  ASSERT_THAT(alloc1, IsOk());
  LayerInfoBase* ptr0 = alloc0->get();
  LayerInfoBase* ptr1 = alloc1->get();
  EXPECT_EQ(arena.num_chunks(), 1);
  EXPECT_EQ(arena.size(), 2);

  // Acquiring a 3rd slot triggers adding a new std::vector<LayerInfoBase> of
  // the same size (2) and allocating 2 * 3 = 6 new shard buffers.
  absl::StatusOr<StagingArena::Allocation> alloc2 = arena.Acquire();
  ASSERT_THAT(alloc2, IsOk());
  EXPECT_EQ(allocator_calls, 12);
  EXPECT_EQ(arena.num_chunks(), 2);
  EXPECT_EQ(arena.chunk_size(), 2);
  EXPECT_EQ(arena.size(), 4);
  EXPECT_EQ(arena.in_use_count(), 3);
  EXPECT_EQ(arena.available_count(), 1);
  EXPECT_EQ(alloc2->layer_idx(), 2);
  ASSERT_EQ((*alloc2)->shards.size(), 3);
  for (size_t s = 0; s < 3; ++s) {
    EXPECT_NE((*alloc2)->shards[s].host_ptr, nullptr);
    EXPECT_EQ((*alloc2)->shards[s].host_size, 128);
  }

  // Existing allocations and layer references must remain pointer-stable.
  EXPECT_EQ(alloc0->get(), ptr0);
  EXPECT_EQ(alloc1->get(), ptr1);
  EXPECT_EQ(&arena.GetLayer(0), ptr0);
  EXPECT_EQ(&arena[1], ptr1);
  EXPECT_EQ(&arena.GetLayer(2), alloc2->get());

  // Acquire 2 more to trigger a 3rd chunk of size 2 (total capacity = 6).
  absl::StatusOr<StagingArena::Allocation> alloc3 = arena.Acquire();
  ASSERT_THAT(alloc3, IsOk());
  absl::StatusOr<StagingArena::Allocation> alloc4 = arena.Acquire();
  ASSERT_THAT(alloc4, IsOk());
  EXPECT_EQ(allocator_calls, 18);
  EXPECT_EQ(alloc3->layer_idx(), 3);
  EXPECT_EQ(alloc4->layer_idx(), 4);
  EXPECT_EQ(arena.num_chunks(), 3);
  EXPECT_EQ(arena.size(), 6);
  EXPECT_EQ(&arena[0], ptr0);
  EXPECT_EQ(&arena[1], ptr1);
  EXPECT_EQ(&arena[4], alloc4->get());
}

TEST(StagingArenaTest, DynamicGrowthWithoutAllocatorReturnsError) {
  std::vector<LayerInfoBase> initial_layers(1);
  initial_layers[0].shards.resize(1);
  initial_layers[0].shards[0].device_size = 256;
  initial_layers[0].shards[0].host_size = 256;

  StagingArena arena(std::move(initial_layers), /*host_allocator=*/nullptr,
                     StagingArena::Config{.allow_dynamic_growth = true});
  absl::StatusOr<StagingArena::Allocation> alloc0 = arena.Acquire();
  ASSERT_THAT(alloc0, IsOk());

  // Attempting to grow when shard memory is needed but no allocator was passed
  // must fail with kFailedPrecondition.
  EXPECT_THAT(arena.Acquire(), StatusIs(absl::StatusCode::kFailedPrecondition));
}

TEST(StagingArenaTest, ReleaseMemoryOnFreeResetsShardBuffers) {
  StagingArena arena(StagingArena::Config{
      .initial_capacity = 1,
      .num_shards = 1,
      .allow_dynamic_growth = false,
      .release_memory_on_free = true,
  });

  auto backing_memory = std::make_shared<std::vector<uint8_t>>(256, 0x7F);
  {
    absl::StatusOr<StagingArena::Allocation> alloc = arena.Acquire();
    ASSERT_THAT(alloc, IsOk());
    (*alloc)->shards[0].host_ptr = backing_memory->data();
    (*alloc)->shards[0].host_size = backing_memory->size();
    (*alloc)->shards[0].device_size = 512;
    (*alloc)->shards[0].host_owner = backing_memory;
    EXPECT_EQ(backing_memory.use_count(), 2);
  }

  // Destruction of `alloc` should have released `host_owner` and cleared host
  // pointers/sizes while preserving `shards.size()` and `device_size`.
  EXPECT_EQ(backing_memory.use_count(), 1);
  absl::StatusOr<StagingArena::Allocation> reacquired = arena.Acquire();
  ASSERT_THAT(reacquired, IsOk());
  ASSERT_EQ((*reacquired)->shards.size(), 1);
  EXPECT_EQ((*reacquired)->shards[0].host_ptr, nullptr);
  EXPECT_EQ((*reacquired)->shards[0].host_size, 0);
  EXPECT_EQ((*reacquired)->shards[0].host_owner, nullptr);
  EXPECT_EQ((*reacquired)->shards[0].device_size, 512);
}

TEST(StagingArenaTest, MoveAssignmentReleasesPreviousSlot) {
  StagingArena arena(StagingArena::Config{
      .initial_capacity = 2,
      .num_shards = 1,
      .allow_dynamic_growth = false,
  });

  absl::StatusOr<StagingArena::Allocation> alloc0 = arena.Acquire();
  ASSERT_THAT(alloc0, IsOk());
  absl::StatusOr<StagingArena::Allocation> alloc1 = arena.Acquire();
  ASSERT_THAT(alloc1, IsOk());
  EXPECT_EQ(arena.in_use_count(), 2);
  EXPECT_EQ(arena.available_count(), 0);

  // Move-assigning alloc1 into alloc0 must release slot 0 back to the arena.
  *alloc0 = *std::move(alloc1);
  EXPECT_EQ(arena.in_use_count(), 1);
  EXPECT_EQ(arena.available_count(), 1);
  EXPECT_EQ(alloc0->layer_idx(), 1);
}

TEST(StagingArenaTest, ConstructFromMovedVectorAndAccessByLayerIndex) {
  HostBufferAllocator alloc_fn = MakeDefaultHostBufferAllocator();
  std::vector<LayerInfoBase> initial_layers(3);
  for (size_t i = 0; i < initial_layers.size(); ++i) {
    initial_layers[i].shards.resize(2);
    for (size_t s = 0; s < 2; ++s) {
      size_t sz = (i + 1) * 1024;
      initial_layers[i].shards[s].device_size = sz;
      absl::StatusOr<HostBufferAllocation> buf = alloc_fn(sz, nullptr);
      ASSERT_THAT(buf, IsOk());
      initial_layers[i].shards[s].host_ptr = buf->ptr;
      initial_layers[i].shards[s].host_size = buf->size;
      initial_layers[i].shards[s].host_owner = std::move(buf->owner);
    }
  }

  StagingArena arena(std::move(initial_layers), alloc_fn,
                     StagingArena::Config{.allow_dynamic_growth = true});
  EXPECT_EQ(arena.size(), 3);
  EXPECT_EQ(arena.num_chunks(), 1);
  EXPECT_EQ(arena.chunk_size(), 3);
  EXPECT_EQ(arena[0].shards[0].device_size, 1024);
  EXPECT_EQ(arena.GetLayer(1).shards[0].device_size, 2048);
  EXPECT_EQ(arena[2].shards[0].device_size, 3072);

  // Acquiring 4 slots grows by adding another vector of size 3 (and 2 shards),
  // allocating new host memory matching each layer's template size.
  absl::StatusOr<StagingArena::Allocation> a0 = arena.Acquire();
  absl::StatusOr<StagingArena::Allocation> a1 = arena.Acquire();
  absl::StatusOr<StagingArena::Allocation> a2 = arena.Acquire();
  absl::StatusOr<StagingArena::Allocation> a3 = arena.Acquire();
  ASSERT_THAT(a0, IsOk());
  ASSERT_THAT(a1, IsOk());
  ASSERT_THAT(a2, IsOk());
  ASSERT_THAT(a3, IsOk());
  EXPECT_EQ(arena.num_chunks(), 2);
  EXPECT_EQ(arena.size(), 6);
  ASSERT_EQ((*a3)->shards.size(), 2);
  EXPECT_NE((*a3)->shards[0].host_ptr, nullptr);
  EXPECT_NE((*a3)->shards[0].host_ptr, arena[0].shards[0].host_ptr);
  EXPECT_EQ((*a3)->shards[0].host_size, 1024);
  EXPECT_EQ((*a3)->shards[0].device_size, 1024);
}

}  // namespace
}  // namespace tpu_raiden
