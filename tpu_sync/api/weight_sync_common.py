# Copyright 2026 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Weight sync helpers shared by the JAX and Torch Python APIs."""

from typing import Any


def _bandwidth_gbps(num_bytes: int, time_ms: float) -> float:
  """Returns `num_bytes` over `time_ms` in GB/s, or 0.0 if nothing was moved."""
  if num_bytes <= 0:
    return 0.0
  return (num_bytes / 1e9) / max(time_ms / 1000.0, 1e-9)


def metrics_to_dict(m: Any) -> dict[str, float | int]:
  """Converts a native `WeightSyncMetrics` into the `get_metrics()` dict.

  Shared by the JAX and Torch `WeightSynchronizer` wrappers. Each framework
  extension binds its own `WeightSyncMetrics` class with the same fields, so
  `m` is accepted by duck typing.

  Args:
    m: A `WeightSyncMetrics` returned by a native `WeightSynchronizer`.

  Returns:
    The raw `last_*`, `total_*` and call count fields, plus `*_bandwidth_gbps`
    values derived from the matching bytes and time fields.
  """
  return {
      "last_d2h_time_ms": m.last_d2h_time_ms,
      "last_h2d_time_ms": m.last_h2d_time_ms,
      "last_h2h_time_ms": m.last_h2h_time_ms,
      "last_staging_time_ms": m.last_staging_time_ms,
      "last_tiling_time_ms": m.last_tiling_time_ms,
      "last_detiling_time_ms": m.last_detiling_time_ms,
      "last_total_push_resharded_time_ms": m.last_total_push_resharded_time_ms,
      "last_d2h_bytes": m.last_d2h_bytes,
      "last_h2d_bytes": m.last_h2d_bytes,
      "last_h2h_bytes": m.last_h2h_bytes,
      "last_tiled_bytes": m.last_tiled_bytes,
      "last_detiled_bytes": m.last_detiled_bytes,
      "total_d2h_time_ms": m.total_d2h_time_ms,
      "total_h2d_time_ms": m.total_h2d_time_ms,
      "total_h2h_time_ms": m.total_h2h_time_ms,
      "total_staging_time_ms": m.total_staging_time_ms,
      "total_tiling_time_ms": m.total_tiling_time_ms,
      "total_detiling_time_ms": m.total_detiling_time_ms,
      "total_push_resharded_time_ms": m.total_push_resharded_time_ms,
      "total_d2h_bytes": m.total_d2h_bytes,
      "total_h2d_bytes": m.total_h2d_bytes,
      "total_h2h_bytes": m.total_h2h_bytes,
      "total_tiled_bytes": m.total_tiled_bytes,
      "total_detiled_bytes": m.total_detiled_bytes,
      "d2h_call_count": m.d2h_call_count,
      "push_resharded_call_count": m.push_resharded_call_count,
      "d2h_bandwidth_gbps": _bandwidth_gbps(
          m.last_d2h_bytes, m.last_d2h_time_ms
      ),
      "h2d_bandwidth_gbps": _bandwidth_gbps(
          m.last_h2d_bytes, m.last_h2d_time_ms
      ),
      "h2h_bandwidth_gbps": _bandwidth_gbps(
          m.last_h2h_bytes, m.last_h2h_time_ms
      ),
      "total_h2h_bandwidth_gbps": _bandwidth_gbps(
          m.total_h2h_bytes, m.total_h2h_time_ms
      ),
      "tiling_bandwidth_gbps": _bandwidth_gbps(
          m.last_tiled_bytes, m.last_tiling_time_ms
      ),
      "detiling_bandwidth_gbps": _bandwidth_gbps(
          m.last_detiled_bytes, m.last_detiling_time_ms
      ),
  }
