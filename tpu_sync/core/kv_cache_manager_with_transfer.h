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

#ifndef THIRD_PARTY_TPU_RAIDEN_CORE_KV_CACHE_MANAGER_WITH_TRANSFER_H_
#define THIRD_PARTY_TPU_RAIDEN_CORE_KV_CACHE_MANAGER_WITH_TRANSFER_H_

// Forwarding header. KVCacheManagerWithTransfer moved to
// tpu_sync/kv_cache/. Include the new path and depend on
// //tpu_sync/kv_cache:kv_cache_manager_with_transfer
// instead; this header will be removed once all callers migrate.
#include "tpu_sync/kv_cache/kv_cache_manager_with_transfer.h"  // IWYU pragma: export

#endif  // THIRD_PARTY_TPU_RAIDEN_CORE_KV_CACHE_MANAGER_WITH_TRANSFER_H_
