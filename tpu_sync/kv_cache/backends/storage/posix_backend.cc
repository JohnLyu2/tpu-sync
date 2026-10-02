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

#include "tpu_sync/kv_cache/backends/storage/posix_backend.h"

#include <fcntl.h>
#include <sys/uio.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>  // NOLINT(build/c++17)
#include <functional>
#include <future>
#include <iterator>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

#include "absl/algorithm/container.h"
#include "absl/container/flat_hash_map.h"
#include "absl/log/check.h"
#include "absl/log/log.h"
#include "absl/status/status.h"
#include "absl/status/status_macros.h"
#include "absl/status/statusor.h"
#include "absl/strings/ascii.h"
#include "absl/strings/escaping.h"
#include "absl/strings/numbers.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"
#include "absl/synchronization/mutex.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"
#include "absl/types/span.h"
#include "tpu_sync/core/controller/raiden_controller.h"
#include "tpu_sync/core/numa_thread_pool.h"
#include "tpu_sync/kv_cache/backends/backend.h"
#include "tpu_sync/kv_cache/kv_cache_store_backend.h"
#include "tpu_sync/kv_cache/kv_cache_store_backend_factory.h"

namespace tpu_raiden {
namespace kv_cache {
namespace backends {
namespace storage {

namespace fs = std::filesystem;

// --- Direct I/O alignment ---

size_t DirectIOAlignment() {
  static const size_t kAlign = [] {
    const long page = sysconf(_SC_PAGESIZE);
    CHECK_GT(page, 0) << "sysconf(_SC_PAGESIZE) failed";
    CHECK_EQ(page & (page - 1), 0)
        << "page size is not a power of two: " << page;
    LOG(INFO) << "PosixKVBackend: O_DIRECT alignment = " << page
              << " bytes (sysconf(_SC_PAGESIZE))";
    return static_cast<size_t>(page);
  }();
  return kAlign;
}

bool SlicesAreDirectIOAligned(absl::Span<const HostBufferDescriptor> slices) {
  // The alignment is a power of two, so OR-ing address and size lets one mask
  // test cover both.
  const uintptr_t mask = DirectIOAlignment() - 1;
  for (const auto& slice : slices) {
    if (((reinterpret_cast<uintptr_t>(slice.ptr) | slice.size) & mask) != 0) {
      return false;
    }
  }
  return true;
}

// --- PosixKVBackend Implementation ---

PosixKVBackend::PosixKVBackend(
    std::string name, absl::flat_hash_map<std::string, std::string> properties)
    : KVBackend(std::move(properties)), name_(std::move(name)) {
  absl::StatusOr<PosixBackendOptions> options =
      PosixBackendOptions::FromProperties(properties_);
  if (!options.ok()) {
    LOG(FATAL) << "[PosixKVBackend] invalid configuration for " << name_ << ": "
               << options.status();
  }
  options_ = *std::move(options);
  if (options_.direct_io) {
    direct_io_supported_ = ProbeDirectIO(options_.root_dir);
    if (!direct_io_supported_) {
      LOG(FATAL) << "[PosixKVBackend] " << name_
                 << ": direct_io=true but O_DIRECT is not supported on '"
                 << options_.root_dir
                 << "'. Unset direct_io or use a filesystem that supports it.";
    }
  }
  mapper_ =
      std::make_shared<PosixPathMapper>(options_.root_dir, options_.model_name,
                                        options_.tp_size, options_.tp_rank);
  thread_pool_ =
      std::make_unique<NumaThreadPool>(options_.storage_io_thread_pool_size);
}

bool PosixKVBackend::ProbeDirectIO(absl::string_view dir) {
  static std::atomic<uint64_t> probe_seq{0};
  std::string probe_path =
      absl::StrCat(dir, "/.o_direct_probe_", getpid(), "_",
                   probe_seq.fetch_add(1, std::memory_order_relaxed));
  std::error_code ec;
  fs::create_directories(std::string(dir), ec);

  int fd = open(probe_path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_DIRECT, 0644);
  if (fd < 0) {
    LOG(WARNING) << "PosixKVBackend: O_DIRECT probe open failed on '" << dir
                 << "' (errno: " << errno << " - " << strerror(errno) << ")";
    return false;
  }

  // Write one page, aligned to the page size, to verify whether the underlying
  // filesystem accepts O_DIRECT I/O without failing with EINVAL (as happens on
  // overlayfs or older tmpfs).
  const size_t align = DirectIOAlignment();
  void* page = nullptr;
  if (posix_memalign(&page, align, align) != 0) {
    close(fd);
    unlink(probe_path.c_str());
    LOG(WARNING) << "PosixKVBackend: O_DIRECT probe posix_memalign failed on '"
                 << dir << "'";
    return false;
  }
  std::memset(page, 0, align);
  ssize_t written = write(fd, page, align);
  const int write_errno = errno;
  free(page);
  close(fd);
  unlink(probe_path.c_str());

  bool success = (written == static_cast<ssize_t>(align));
  if (success) {
    LOG(INFO) << "PosixKVBackend: O_DIRECT probe on '" << dir
              << "' succeeded with " << align
              << "-byte alignment; direct I/O is supported.";
  } else {
    LOG(WARNING) << "PosixKVBackend: O_DIRECT probe write failed on '" << dir
                 << "' (written: " << written << ", errno: " << write_errno
                 << " - " << strerror(write_errno) << ")";
  }
  return success;
}

void PosixKVBackend::WriteAsync(const BlockKey& key,
                                absl::Span<const HostBufferDescriptor> slices,
                                size_t /*total_bytes*/,
                                std::function<void(absl::Status)> callback) {
  thread_pool_->Schedule(std::nullopt, [direct_io_supported = direct_io_supported_,
                                        key,
                                        slices =
                                            std::vector<HostBufferDescriptor>(
                                                slices.begin(), slices.end()),
                                        callback = std::move(callback)]() {
    // A non-zero offset means this write is one slice of a file several
    // writers share, and a whole-file rename would publish a file
    // containing only this slice. No mapper produces such a key today --
    // PosixPathMapper::MapKey hardcodes offset=0 -- so reject it rather
    // than silently corrupt the file if a future mapper starts
    // partitioning one file across ranks.
    if (key.offset != 0) {
      if (callback)
        callback(absl::InvalidArgumentError(
            absl::StrCat("PosixKVBackend::WriteAsync requires offset 0 (atomic "
                         "whole-file publish); got ",
                         key.offset)));
      return;
    }

    // Write to a temp file and rename into place, so a concurrent Lookup
    // -- which gates on bare existence -- sees either no file or a
    // complete one. Without this, any error below leaves a short file at
    // the final path, which is a permanent phantom hit that fails every
    // future recall with DataLossError.
    //
    // The suffix keeps the temp file in the SAME directory as the final
    // path, because rename(2) is only atomic within a filesystem. The
    // pid distinguishes processes; the counter distinguishes threads and
    // successive writes within one process, which is stricter than a
    // thread id (those get recycled once a thread exits).
    static std::atomic<uint64_t> tmp_seq{0};
    const std::string tmp_path =
        absl::StrCat(key.resolved_key, ".tmp_", getpid(), "_",
                     tmp_seq.fetch_add(1, std::memory_order_relaxed));

    // With direct_io there is no buffered fallback: a misaligned buffer fails
    // the operation before any file is created.
    if (direct_io_supported && !SlicesAreDirectIOAligned(slices)) {
      if (callback)
        callback(absl::InvalidArgumentError(absl::StrCat(
            "PosixKVBackend::WriteAsync: direct_io=true but a slice pointer "
            "or size is not aligned to ",
            DirectIOAlignment(), " bytes for O_DIRECT")));
      return;
    }
    const int open_flags =
        O_WRONLY | O_CREAT | O_TRUNC | (direct_io_supported ? O_DIRECT : 0);

    int fd = open(tmp_path.c_str(), open_flags, 0644);
    if (fd < 0 && errno == ENOENT) {
      // Optimistic open failed because parent directory does not exist yet.
      // Create directory hierarchy and retry open once.
      std::string dir_path =
          std::string(PosixPathMapper::GetParentDir(key.resolved_key));
      if (!dir_path.empty()) {
        std::error_code ec;
        fs::create_directories(dir_path, ec);
        if (ec) {
          if (callback) {
            callback(absl::InternalError(
                absl::StrCat("Failed to create directory: ", dir_path,
                             ", error: ", ec.message())));
          }
          return;
        }
        fd = open(tmp_path.c_str(), open_flags, 0644);
      }
    }

    if (fd < 0) {
      if (callback) {
        callback(absl::ErrnoToStatus(
            errno, absl::StrCat("Failed to open file for write: ", tmp_path)));
      }
      return;
    }

    // Every failure from here on must remove the temp file: nothing else
    // ever will, since this backend's Delete is a no-op stub.
    auto fail = [&tmp_path, &callback](int fd_to_close, absl::Status s) {
      close(fd_to_close);
      unlink(tmp_path.c_str());
      if (callback) callback(std::move(s));
    };

    // Populate iovec array for scatter-gather write.
    std::vector<struct iovec> iov;
    iov.reserve(slices.size());
    size_t total_slices_bytes = 0;
    for (const auto& slice : slices) {
      if (slice.ptr == nullptr && slice.size > 0) {
        fail(fd,
             absl::InvalidArgumentError("Null slice pointer in WriteAsync"));
        return;
      }
      if (slice.size > 0) {
        iov.push_back(iovec{.iov_base = const_cast<void*>(slice.ptr),
                            .iov_len = slice.size});
        total_slices_bytes += slice.size;
      }
    }

    off_t current_offset = 0;
    size_t iov_idx = 0;
    while (iov_idx < iov.size()) {
      // Chunk batch to stay within UIO_MAXIOV (1024) limit.
      int batch_count = std::min<int>(iov.size() - iov_idx, UIO_MAXIOV);
      size_t batch_bytes = 0;
      for (int i = 0; i < batch_count; ++i) {
        batch_bytes += iov[iov_idx + i].iov_len;
      }

      ssize_t written = pwritev(fd, &iov[iov_idx], batch_count, current_offset);
      if (written < 0) {
        if (errno == EINTR) continue;
        int saved_errno = errno;
        fail(fd, absl::ErrnoToStatus(saved_errno,
                                     absl::StrCat("pwritev failed at offset ",
                                                  current_offset)));
        return;
      }
      if (written == 0) {
        fail(fd, absl::InternalError(absl::StrCat(
                     "pwritev returned 0 bytes at offset ", current_offset)));
        return;
      }
      current_offset += written;

      // Fast Path: Entire batch was written (standard regular-file
      // behavior). Advance iov_idx directly by batch_count.
      if (static_cast<size_t>(written) == batch_bytes) {
        iov_idx += batch_count;
        continue;
      }

      // Slow/Rare Path: Partial write across the batch. Drain the partial
      // bytes:
      size_t bytes_left = static_cast<size_t>(written);
      while (bytes_left > 0 && iov_idx < iov.size()) {
        if (bytes_left >= iov[iov_idx].iov_len) {
          bytes_left -= iov[iov_idx].iov_len;
          ++iov_idx;
        } else {
          iov[iov_idx].iov_base =
              static_cast<char*>(iov[iov_idx].iov_base) + bytes_left;
          iov[iov_idx].iov_len -= bytes_left;
          bytes_left = 0;
        }
      }
    }

    if (close(fd) < 0) {
      int saved_errno = errno;
      unlink(tmp_path.c_str());
      if (callback)
        callback(absl::ErrnoToStatus(saved_errno,
                                     "Failed to close file after write"));
      return;
    }

    if (rename(tmp_path.c_str(), key.resolved_key.c_str()) != 0) {
      int saved_errno = errno;
      unlink(tmp_path.c_str());
      if (callback)
        callback(absl::ErrnoToStatus(
            saved_errno, absl::StrCat("Failed to publish ", key.resolved_key)));
      return;
    }
    if (callback) callback(absl::OkStatus());
  });
}

void PosixKVBackend::ReadAsync(const BlockKey& key,
                               absl::Span<const HostBufferDescriptor> slices,
                               size_t /*total_bytes*/,
                               std::function<void(absl::Status)> callback) {
  thread_pool_->Schedule(std::nullopt, [direct_io_supported = direct_io_supported_,
                                        key,
                                        slices =
                                            std::vector<HostBufferDescriptor>(
                                                slices.begin(), slices.end()),
                                        callback = std::move(callback)]() {
    // With direct_io there is no buffered fallback: a misaligned file offset
    // or buffer fails the operation before the file is opened.
    if (direct_io_supported &&
        ((key.offset & (DirectIOAlignment() - 1)) != 0 ||
         !SlicesAreDirectIOAligned(slices))) {
      if (callback)
        callback(absl::InvalidArgumentError(absl::StrCat(
            "PosixKVBackend::ReadAsync: direct_io=true but the file offset, a "
            "slice pointer or a slice size is not aligned to ",
            DirectIOAlignment(), " bytes for O_DIRECT")));
      return;
    }
    const int open_flags = O_RDONLY | (direct_io_supported ? O_DIRECT : 0);

    int fd = open(key.resolved_key.c_str(), open_flags);
    if (fd < 0) {
      if (callback) {
        if (errno == ENOENT) {
          callback(absl::NotFoundError(
              absl::StrCat("Block file not found: ", key.resolved_key)));
        } else {
          callback(absl::ErrnoToStatus(
              errno, absl::StrCat("Failed to open file for read: ",
                                  key.resolved_key)));
        }
      }
      return;
    }

    // Populate iovec array for scatter-gather read.
    std::vector<struct iovec> iov;
    iov.reserve(slices.size());
    for (const auto& slice : slices) {
      if (slice.ptr == nullptr && slice.size > 0) {
        close(fd);
        if (callback) {
          callback(
              absl::InvalidArgumentError("Null slice pointer in ReadAsync"));
        }
        return;
      }
      if (slice.size > 0) {
        iov.push_back(iovec{.iov_base = slice.ptr, .iov_len = slice.size});
      }
    }

    off_t current_offset = key.offset;
    size_t iov_idx = 0;
    while (iov_idx < iov.size()) {
      int batch_count = std::min<int>(iov.size() - iov_idx, UIO_MAXIOV);
      size_t batch_bytes = 0;
      for (int i = 0; i < batch_count; ++i) {
        batch_bytes += iov[iov_idx + i].iov_len;
      }

      ssize_t bytes_read =
          preadv(fd, &iov[iov_idx], batch_count, current_offset);
      if (bytes_read < 0) {
        if (errno == EINTR) continue;
        int saved_errno = errno;
        close(fd);
        if (callback) {
          callback(absl::ErrnoToStatus(
              saved_errno,
              absl::StrCat("preadv failed at offset ", current_offset)));
        }
        return;
      }
      if (bytes_read == 0) {
        close(fd);
        if (callback) {
          callback(absl::DataLossError(absl::StrCat(
              "Unexpected EOF while reading block: ", key.resolved_key)));
        }
        return;
      }
      current_offset += bytes_read;

      // Fast Path: Entire batch was read. Advance iov_idx directly by
      // batch_count.
      if (static_cast<size_t>(bytes_read) == batch_bytes) {
        iov_idx += batch_count;
        continue;
      }

      // Slow/Rare Path: Partial read. Drain the partial bytes:
      size_t bytes_left = static_cast<size_t>(bytes_read);
      while (bytes_left > 0 && iov_idx < iov.size()) {
        if (bytes_left >= iov[iov_idx].iov_len) {
          bytes_left -= iov[iov_idx].iov_len;
          ++iov_idx;
        } else {
          iov[iov_idx].iov_base =
              static_cast<char*>(iov[iov_idx].iov_base) + bytes_left;
          iov[iov_idx].iov_len -= bytes_left;
          bytes_left = 0;
        }
      }
    }

    if (close(fd) < 0) {
      if (callback)
        callback(absl::ErrnoToStatus(errno, "Failed to close file after read"));
      return;
    }
    if (callback) callback(absl::OkStatus());
  });
}

absl::StatusOr<bool> PosixKVBackend::Exists(const BlockKey& key) {
  if (faccessat(AT_FDCWD, key.resolved_key.c_str(), F_OK, AT_EACCESS) == 0) {
    return true;
  }
  if (errno == ENOENT || errno == ENOTDIR) {
    return false;
  }
  return absl::ErrnoToStatus(
      errno, absl::StrCat("faccessat(F_OK) failed for: ", key.resolved_key));
}

void PosixKVBackend::BatchExistsAsync(
    absl::Span<const BlockKey> keys,
    std::function<void(std::vector<absl::StatusOr<bool>>)> callback) {
  if (keys.empty()) {
    // Completed on the pool, not inline, so this call reports asynchronously
    // for every input. A caller that assumes the callback cannot run before
    // BatchExistsAsync returns -- true for every non-empty batch -- would
    // otherwise be re-entered on this one path, which deadlocks it if it holds
    // a lock across the call.
    thread_pool_->Schedule(
        std::nullopt, [callback = std::move(callback)]() { callback({}); });
    return;
  }

  const size_t num_keys = keys.size();
  struct AsyncBatchState {
    std::vector<absl::StatusOr<bool>> results;
    std::atomic<size_t> remaining;
    std::function<void(std::vector<absl::StatusOr<bool>>)> callback;
  };

  auto state = std::make_shared<AsyncBatchState>();
  state->results.resize(num_keys);
  state->remaining.store(num_keys, std::memory_order_relaxed);
  state->callback = std::move(callback);

  for (size_t i = 0; i < num_keys; ++i) {
    thread_pool_->Schedule(std::nullopt, [this, key = keys[i], i, state]() {
      state->results[i] = Exists(key);
      if (state->remaining.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        state->callback(std::move(state->results));
      }
    });
  }
}

// --- PosixPathMapper Implementation ---

namespace {

// HuggingFace-style model IDs (e.g. "meta-llama/Llama-3.1-70B") embed path
// separators, which would inject an extra directory level and break the
// fixed-depth layout. Anything outside [A-Za-z0-9._-] is replaced by '_'.
std::string SanitizeModelName(absl::string_view model_name) {
  std::string sanitized;
  sanitized.reserve(model_name.size());
  for (const char c : model_name) {
    const bool is_safe = absl::ascii_isalnum(static_cast<unsigned char>(c)) ||
                         c == '.' || c == '_' || c == '-';
    sanitized.push_back(is_safe ? c : '_');
  }
  if (sanitized.empty()) return "unknown";
  return sanitized;
}

}  // namespace

PosixPathMapper::PosixPathMapper(absl::string_view root_dir,
                                 absl::string_view model_name, int tp_size,
                                 int tp_rank)
    : root_dir_(root_dir),
      model_name_(SanitizeModelName(model_name)),
      tp_size_(tp_size),
      tp_rank_(tp_rank) {}

absl::StatusOr<PosixBackendOptions> PosixBackendOptions::FromProperties(
    const absl::flat_hash_map<std::string, std::string>& properties) {
  PosixBackendOptions options;
  auto str = [&](absl::string_view key, std::string* out) {
    auto it = properties.find(key);
    if (it != properties.end()) *out = it->second;
  };
  auto num = [&](absl::string_view key, int64_t* out) -> absl::Status {
    auto it = properties.find(key);
    if (it == properties.end()) return absl::OkStatus();
    if (!absl::SimpleAtoi(it->second, out)) {
      return absl::InvalidArgumentError(
          absl::StrCat(key, " is not an integer: ", it->second));
    }
    return absl::OkStatus();
  };
  str("root_dir", &options.root_dir);
  str("model_name", &options.model_name);
  int64_t tp_size = options.tp_size;
  int64_t tp_rank = options.tp_rank;
  int64_t capacity = 0;
  int64_t batch = options.lookup_batch_size;
  int64_t threads = options.storage_io_thread_pool_size;
  ABSL_RETURN_IF_ERROR(num("tp_size", &tp_size));
  ABSL_RETURN_IF_ERROR(num("tp_rank", &tp_rank));
  ABSL_RETURN_IF_ERROR(num("capacity_bytes", &capacity));
  ABSL_RETURN_IF_ERROR(num("lookup_batch_size", &batch));
  ABSL_RETURN_IF_ERROR(num("storage_io_thread_pool_size", &threads));
  if (tp_size < 1) {
    return absl::InvalidArgumentError(
        absl::StrCat("tp_size must be >= 1, got ", tp_size));
  }
  if (tp_rank < 0 || tp_rank >= tp_size) {
    return absl::InvalidArgumentError(
        absl::StrCat("tp_rank must be in [0, ", tp_size, "), got ", tp_rank));
  }
  if (threads < 1) {
    return absl::InvalidArgumentError(absl::StrCat(
        "storage_io_thread_pool_size must be >= 1, got ", threads));
  }
  options.tp_size = static_cast<int>(tp_size);
  options.tp_rank = static_cast<int>(tp_rank);
  options.capacity_bytes = static_cast<size_t>(capacity);
  options.lookup_batch_size =
      batch > 0 ? static_cast<size_t>(batch) : kDefaultLookupBatchSize;
  options.storage_io_thread_pool_size = static_cast<int>(threads);

  if (auto it = properties.find("direct_io"); it != properties.end()) {
    std::string val = absl::AsciiStrToLower(it->second);
    if (val == "true") {
      options.direct_io = true;
    } else if (val == "false") {
      options.direct_io = false;
    } else {
      return absl::InvalidArgumentError(
          absl::StrCat("Invalid boolean value for direct_io: '", it->second,
                       "'; expected 'true' or 'false'"));
    }
  }

  // metadata_cache_max_entries: 0 (off), > 0 (cap) or -1 (unbounded).
  ABSL_RETURN_IF_ERROR(
      num("metadata_cache_max_entries", &options.metadata_cache_max_entries));
  if (options.metadata_cache_max_entries < 0 &&
      options.metadata_cache_max_entries != kUnboundedMetadataCache) {
    return absl::InvalidArgumentError(absl::StrCat(
        "metadata_cache_max_entries must be >= 0 or ", kUnboundedMetadataCache,
        ", got ", options.metadata_cache_max_entries));
  }
  // metadata_cache_ttl_secs: > 0 or -1 (never expire).
  ABSL_RETURN_IF_ERROR(
      num("metadata_cache_ttl_secs", &options.metadata_cache_ttl_secs));
  if (options.metadata_cache_ttl_secs <= 0 &&
      options.metadata_cache_ttl_secs != kUnboundedMetadataCache) {
    return absl::InvalidArgumentError(absl::StrCat(
        "metadata_cache_ttl_secs must be > 0 or ", kUnboundedMetadataCache,
        ", got ", options.metadata_cache_ttl_secs));
  }
  if (options.metadata_cache_max_entries != 0) {
    if (options.metadata_cache_max_entries == kUnboundedMetadataCache) {
      LOG(WARNING) << "POSIX metadata cache is unbounded "
                      "(metadata_cache_max_entries=-1); memory grows with the "
                      "number of distinct shard files looked up.";
    }
    if (options.metadata_cache_ttl_secs == kUnboundedMetadataCache) {
      LOG(WARNING) << "POSIX metadata cache entries never expire "
                      "(metadata_cache_ttl_secs=-1); files removed from "
                      "storage out of band are only forgotten after a failed "
                      "recall.";
    }
  }

  return options;
}

absl::StatusOr<BlockKey> PosixPathMapper::MapKey(
    const std::string& block_hash, const KeyMappingOptions& options) const {
  if (block_hash.empty()) {
    return absl::InvalidArgumentError("block_hash must not be empty.");
  }
  if (block_hash.size() > kMaxBlockHashBytes) {
    return absl::InvalidArgumentError(
        absl::StrCat("block_hash is ", block_hash.size(), " bytes; maximum is ",
                     kMaxBlockHashBytes, " (NAME_MAX after hex encoding)."));
  }
  const int target_rank = (options.parallelism.tp_rank == -1)
                              ? tp_rank_
                              : options.parallelism.tp_rank;
  const int target_tp_size = (options.parallelism.tp_size == -1)
                                 ? tp_size_
                                 : options.parallelism.tp_size;

  // block_hash is opaque binary; encode before it contributes to a path.
  const std::string hash_hex = absl::BytesToHexString(block_hash);
  // Right-pad so the prefix directories are fixed-width for every input
  // length. The filename uses the complete unpadded hash, so short hashes
  // never collide.
  const std::string padded = absl::StrCat(
      hash_hex, std::string(kHashDirL1Width + kHashDirL2Width, '0'));
  const absl::string_view l1(padded.data(), kHashDirL1Width);
  const absl::string_view l2(padded.data() + kHashDirL1Width, kHashDirL2Width);

  std::string resolved_path =
      absl::StrCat(root_dir_, "/", model_name_, "/tp", target_tp_size, "_r",
                   target_rank, "/", l1, "/", l2, "/", hash_hex, ".bin");
  // Block identity stays the raw bytes; only the path is hex-encoded.
  return BlockKey{block_hash, resolved_path, /*offset=*/0, /*size=*/0};
}

// --- PosixKVCacheStoreBackend Implementation ---

MetadataCacheOptions MetadataCacheOptions::FromPosixOptions(
    const PosixBackendOptions& options) {
  MetadataCacheOptions cache_options;
  cache_options.max_entries =
      options.metadata_cache_max_entries == kUnboundedMetadataCache
          ? std::numeric_limits<size_t>::max()
          : static_cast<size_t>(options.metadata_cache_max_entries);
  cache_options.ttl = options.metadata_cache_ttl_secs == kUnboundedMetadataCache
                          ? absl::InfiniteDuration()
                          : absl::Seconds(options.metadata_cache_ttl_secs);
  return cache_options;
}

PosixKVCacheStoreBackend::PosixKVCacheStoreBackend(
    std::shared_ptr<KVBackend> storage_backend, std::string name,
    size_t capacity_bytes, size_t lookup_batch_size,
    MetadataCacheOptions cache_options)
    : storage_backend_(std::move(storage_backend)),
      name_(std::move(name)),
      capacity_bytes_(capacity_bytes),
      lookup_batch_size_(lookup_batch_size > 0 ? lookup_batch_size
                                               : kDefaultLookupBatchSize),
      cache_options_(cache_options),
      cache_(cache_options.max_entries) {
  if (cache_options_.enabled()) {
    LOG(INFO) << "PosixKVCacheStoreBackend '" << name_
              << "': metadata cache enabled (max_entries="
              << (cache_options_.max_entries ==
                          std::numeric_limits<size_t>::max()
                      ? std::string("unbounded")
                      : absl::StrCat(cache_options_.max_entries))
              << ", ttl=" << cache_options_.ttl << ")";
  }
}

size_t PosixKVCacheStoreBackend::metadata_cache_size() const {
  absl::MutexLock lock(cache_mu_);
  return cache_.size();
}

RaidenBlockId PosixKVCacheStoreBackend::MakeSharedStorageBlock() const {
  RaidenBlockId block;
  block.status = BlockStatus::SHARED_STORAGE;
  block.raiden_id.job_replica_id = "shared";
  block.raiden_id.data_name = name_;
  return block;
}

absl::StatusOr<std::vector<BlockKey>> PosixKVCacheStoreBackend::MapShardKeys(
    const std::string& block_hash) const {
  const std::shared_ptr<BlockKeyMapper> mapper = storage_backend_->mapper();
  // In secondary storage each block is partitioned across all TP workers
  // (r0..rN-1), one file per shard. Only the rank-0 shard is required today:
  // its presence is taken as a witness for the whole block.
  // TODO: require every rank in [0, tp_size) for a consistent lookup based on
  // all shards' availability in the storage layer.
  constexpr int kRequiredRanks[] = {0};
  std::vector<BlockKey> keys;
  keys.reserve(std::size(kRequiredRanks));
  for (const int rank : kRequiredRanks) {
    const backends::KeyMappingOptions lookup_opts{
        .parallelism = {.tp_size = mapper->tp_size(), .tp_rank = rank},
    };
    ABSL_ASSIGN_OR_RETURN(BlockKey key,
                          mapper->MapKey(block_hash, lookup_opts));
    keys.push_back(std::move(key));
  }
  return keys;
}

std::vector<std::vector<bool>> PosixKVCacheStoreBackend::CachedFresh(
    absl::Span<const std::vector<BlockKey>> shard_keys) {
  std::vector<std::vector<bool>> fresh;
  fresh.reserve(shard_keys.size());
  for (const std::vector<BlockKey>& keys : shard_keys) {
    fresh.emplace_back(keys.size(), false);
  }
  if (!cache_options_.enabled()) return fresh;
  const absl::Time now = absl::Now();
  absl::MutexLock lock(cache_mu_);
  for (size_t i = 0; i < shard_keys.size(); ++i) {
    for (size_t j = 0; j < shard_keys[i].size(); ++j) {
      const std::string& resolved_key = shard_keys[i][j].resolved_key;
      ExistenceEntry* entry = cache_.Get(resolved_key);  // Promotes to MRU.
      if (entry == nullptr) continue;
      if (now - entry->last_used >= cache_options_.ttl) {
        cache_.Erase(resolved_key);
        continue;
      }
      entry->last_used = now;  // Every hit refreshes the TTL.
      fresh[i][j] = true;
    }
  }
  return fresh;
}

void PosixKVCacheStoreBackend::CacheInsert(
    absl::Span<const BlockKey* const> keys) {
  if (!cache_options_.enabled() || keys.empty()) return;
  const absl::Time now = absl::Now();
  absl::MutexLock lock(cache_mu_);
  for (const BlockKey* key : keys) {
    // Confirmed on storage: insert, or refresh the TTL if already cached.
    std::optional<std::pair<std::string, ExistenceEntry>> evicted =
        cache_.Put(key->resolved_key, ExistenceEntry{now});
    // LRUCache parks the evicted entry on its candidate list; reclaim it now
    // so the cache never holds more than max_entries.
    if (evicted.has_value()) cache_.Erase(evicted->first);
  }
}

std::vector<bool> PosixKVCacheStoreBackend::ProbeExists(
    absl::Span<const BlockKey> keys) {
  std::vector<bool> exists(keys.size(), false);
  std::promise<std::vector<absl::StatusOr<bool>>> promise;
  auto future = promise.get_future();
  storage_backend_->BatchExistsAsync(
      keys, [&promise](std::vector<absl::StatusOr<bool>> res) {
        promise.set_value(std::move(res));
      });
  const std::vector<absl::StatusOr<bool>> answers = future.get();
  // A short answer cannot be attributed to keys reliably; treat it as absent.
  if (answers.size() != keys.size()) return exists;
  for (size_t i = 0; i < answers.size(); ++i) {
    exists[i] = answers[i].ok() && *answers[i];
  }
  return exists;
}

// Returns the longest prefix of `block_hashes` that is available on storage.
//
// Block hash -> shard keys.
//   A KV block is written by every tensor-parallel worker, each storing its own
//   shard as a separate file. MapKey(hash, {tp_size, tp_rank = r}) resolves the
//   file for shard r, e.g.
//     <root>/<model>/tp<tp_size>_r<r>/<l1>/<l2>/<hex(hash)>.bin
//   so one block hash maps to up to tp_size storage keys ("shard keys").
//   MapShardKeys(hash) returns the shard keys that must ALL exist for the block
//   to count as available. Today that is only the rank-0 shard (a witness for
//   the whole block).
//   TODO: change MapShardKeys to report all ranks' keys.
//
// Metadata cache contents.
//   When enabled (metadata_cache_max_entries != 0), the cache maps one shard
//   key (its resolved file path) to the last time it was used: a cache hit or
//   a storage probe that found the file. It holds only positive answers: a
//   shard key is either cached as "exists" or not cached at all. An entry is
//   fresh while now - last_used < ttl (a sliding, idle TTL), so a hot entry
//   is not re-checked on storage. A stale entry for a deleted file is dropped
//   when a recall from this tier fails (Delete()), when it goes unused for
//   ttl, or when it is evicted least-recently-used past max_entries.
//   A block is answered from the cache only if every one of its shard keys is
//   fresh.
//
// Algorithm. i = block index (block_hashes[i], request order); j = shard
// index within MapShardKeys(block_hashes[i]) (today always 0: rank 0).
//   Phase 0 (map):   shard_keys[i] = MapShardKeys(block_hashes[i]), in order.
//                    The first hash that cannot be mapped ends the prefix.
//   Phase 1 (cache): mark each shard key present if it has a fresh cache
//                    entry; each fresh hit refreshes its last_used. Expired
//                    entries are erased and treated as misses.
//   Phase 2 (storage): gather the cache-missed shard keys of ALL blocks into
//                    one list, in block order, and check it with
//                    BatchExistsAsync in chunks of lookup_batch_size. Misses
//                    from different blocks therefore share a storage call.
//                    Early exit: if a chunk reports shard key k absent, the
//                    block owning k is unavailable, so the result can only
//                    contain blocks before it. Because keys are probed in
//                    block order, every key of those earlier blocks was in
//                    this chunk or an earlier one and is already resolved.
//                    Remaining chunks hold keys of the unavailable block or
//                    later blocks only, which cannot change the result, so
//                    they are not probed.
//   Phase 3 (merge): block i is available iff all of shard_keys[i] are present
//                    (fresh in cache or found on storage). Return blocks up to
//                    the first unavailable one, and cache every shard key that
//                    storage confirmed (insert only if absent).
//
// With the cache disabled every shard key is a miss, so Lookup reduces to the
// chunked storage probe with early exit.
absl::StatusOr<BlockSliceList> PosixKVCacheStoreBackend::Lookup(
    absl::Span<const std::string> block_hashes, const LookupOptions& options) {
  BlockSliceList results;
  if (!storage_backend_ || !storage_backend_->mapper() || block_hashes.empty())
    return results;

  // Phase 0 (map).
  std::vector<std::vector<BlockKey>> shard_keys;
  shard_keys.reserve(block_hashes.size());
  for (const std::string& hash : block_hashes) {
    absl::StatusOr<std::vector<BlockKey>> keys = MapShardKeys(hash);
    if (!keys.ok()) break;
    shard_keys.push_back(*std::move(keys));
  }
  if (shard_keys.empty()) return results;

  // Phase 1 (cache).
  std::vector<std::vector<bool>> present = CachedFresh(shard_keys);

  // Phase 2 (storage).
  struct ShardRef {
    size_t block;
    size_t shard;
  };
  // One entry per cache-missed shard key: shard_keys[block][shard]. This is a
  // single flat list across ALL blocks, ordered by block i, then shard j
  // within the block. Chunks below cut this list every lookup_batch_size
  // entries without regard to block boundaries, so one BatchExistsAsync call
  // can carry shards of several blocks, and one block's shards can be split
  // across two consecutive calls.
  std::vector<ShardRef> misses;
  for (size_t i = 0; i < shard_keys.size(); ++i) {
    for (size_t j = 0; j < shard_keys[i].size(); ++j) {
      if (!present[i][j]) misses.push_back({i, j});
    }
  }
  std::vector<const BlockKey*> confirmed;
  for (size_t offset = 0; offset < misses.size();
       offset += lookup_batch_size_) {
    const size_t chunk_len =
        std::min(lookup_batch_size_, misses.size() - offset);
    std::vector<BlockKey> chunk_keys;
    chunk_keys.reserve(chunk_len);
    for (size_t k = 0; k < chunk_len; ++k) {
      const ShardRef& miss = misses[offset + k];
      chunk_keys.push_back(shard_keys[miss.block][miss.shard]);
    }
    const std::vector<bool> exists = ProbeExists(chunk_keys);
    bool chunk_has_absent = false;
    for (size_t k = 0; k < chunk_len; ++k) {
      const ShardRef& miss = misses[offset + k];
      if (exists[k]) {
        present[miss.block][miss.shard] = true;
        confirmed.push_back(&shard_keys[miss.block][miss.shard]);
      } else {
        chunk_has_absent = true;
      }
    }
    if (chunk_has_absent) break;  // Early exit; see Phase 2 above.
  }
  CacheInsert(confirmed);

  // Phase 3 (merge).
  auto all_present = [](const std::vector<bool>& shards) {
    return absl::c_all_of(shards, [](bool shard_present) {
      return shard_present;
    });
  };
  for (size_t i = 0; i < shard_keys.size() && all_present(present[i]); ++i) {
    results.push_back(
        std::make_pair(block_hashes[i], MakeSharedStorageBlock()));
  }
  return results;
}

void PosixKVCacheStoreBackend::Delete(
    absl::Span<const std::string> block_hashes,
    absl::Span<const RaidenBlockId> slices) {
  if (!cache_options_.enabled() || !storage_backend_ ||
      !storage_backend_->mapper()) {
    return;
  }
  std::vector<std::string> resolved_keys;
  resolved_keys.reserve(block_hashes.size());
  for (const std::string& hash : block_hashes) {
    absl::StatusOr<std::vector<BlockKey>> keys = MapShardKeys(hash);
    if (!keys.ok()) continue;  // Never cached; keep invalidating the rest.
    for (BlockKey& key : *keys) {
      resolved_keys.push_back(std::move(key.resolved_key));
    }
  }
  absl::MutexLock lock(cache_mu_);
  for (const std::string& resolved_key : resolved_keys) {
    cache_.Erase(resolved_key);
  }
}

}  // namespace storage
}  // namespace backends
}  // namespace kv_cache
}  // namespace tpu_raiden
// These three names are consumed by REGISTER_KV_CACHE_STORE_BACKEND below.
// They are spelled out in full because the header no longer re-exports them
// into the project root namespace.
using ::tpu_raiden::kv_cache::backends::storage::PosixBackendOptions;
using ::tpu_raiden::kv_cache::backends::storage::PosixKVBackend;
using ::tpu_raiden::kv_cache::backends::storage::PosixKVCacheStoreBackend;

REGISTER_KV_CACHE_STORE_BACKEND(
    ::tpu_raiden::kv_cache::backends::storage::kPosixBackendName,
    [](const ::tpu_raiden::kv_cache::BackendConfig& config,
       ::tpu_raiden::controller::RaidenController* /*controller*/)
        -> absl::StatusOr<
            std::shared_ptr<::tpu_raiden::kv_cache::KVCacheStoreBackend>> {
      const int tp_size =
          config.parallelism.tp_size > 0 ? config.parallelism.tp_size : 1;

      // The coordinator resolves block existence through the rank-0 witness
      // (see PosixKVCacheStoreBackend::Lookup), so its mapper is pinned to
      // rank 0. Per-worker tp_rank lives on the worker's own config.
      ::tpu_raiden::kv_cache::BackendConfig resolved = config;
      ::tpu_raiden::kv_cache::ApplyParallelismToProperties(
          {.tp_size = tp_size, .tp_rank = 0}, &resolved);
      ABSL_ASSIGN_OR_RETURN(
          const PosixBackendOptions options,
          PosixBackendOptions::FromProperties(resolved.properties));

      const std::string backend_name = std::string(
          ::tpu_raiden::kv_cache::backends::storage::kPosixBackendName);
      auto backend =
          std::make_shared<PosixKVBackend>(backend_name, resolved.properties);
      return std::make_shared<PosixKVCacheStoreBackend>(
          std::move(backend), backend_name, options.capacity_bytes,
          options.lookup_batch_size,
          ::tpu_raiden::kv_cache::backends::storage::MetadataCacheOptions::
              FromPosixOptions(options));
    });
