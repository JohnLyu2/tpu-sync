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

import types

from absl.testing import absltest

from tpu_sync.api import weight_sync_common

# Every field bound on the native `WeightSyncMetrics`.
_METRIC_FIELDS = (
    "last_d2h_time_ms",
    "last_h2d_time_ms",
    "last_h2h_time_ms",
    "last_staging_time_ms",
    "last_tiling_time_ms",
    "last_detiling_time_ms",
    "last_total_push_resharded_time_ms",
    "last_d2h_bytes",
    "last_h2d_bytes",
    "last_h2h_bytes",
    "last_tiled_bytes",
    "last_detiled_bytes",
    "total_d2h_time_ms",
    "total_h2d_time_ms",
    "total_h2h_time_ms",
    "total_staging_time_ms",
    "total_tiling_time_ms",
    "total_detiling_time_ms",
    "total_push_resharded_time_ms",
    "total_d2h_bytes",
    "total_h2d_bytes",
    "total_h2h_bytes",
    "total_tiled_bytes",
    "total_detiled_bytes",
    "d2h_call_count",
    "push_resharded_call_count",
)


class WeightSyncCommonTest(absltest.TestCase):

  def test_metrics_to_dict(self):
    fields = {name: 0 for name in _METRIC_FIELDS}
    fields.update(
        last_d2h_time_ms=2.0,
        last_d2h_bytes=4_000_000,
        last_h2d_time_ms=4.0,
        last_h2d_bytes=2_000_000,
        total_h2d_time_ms=10.0,
        total_h2d_bytes=6_000_000,
        total_h2h_time_ms=1.0,
        total_h2h_bytes=3_000_000,
        d2h_call_count=3,
    )
    # Bytes recorded with zero time must not divide by zero.
    fields.update(last_tiling_time_ms=0.0, last_tiled_bytes=1_000)

    d = weight_sync_common.metrics_to_dict(types.SimpleNamespace(**fields))

    # Every native field is passed through unchanged.
    for name, value in fields.items():
      self.assertEqual(d[name], value, name)
    # 4 MB in 2 ms is 2 GB/s; 2 MB in 4 ms is 0.5 GB/s.
    self.assertAlmostEqual(d["d2h_bandwidth_gbps"], 2.0)
    self.assertAlmostEqual(d["h2d_bandwidth_gbps"], 0.5)
    self.assertAlmostEqual(d["total_h2h_bandwidth_gbps"], 3.0)
    # No bytes moved means no bandwidth, regardless of the time.
    self.assertEqual(d["h2h_bandwidth_gbps"], 0.0)
    self.assertEqual(d["detiling_bandwidth_gbps"], 0.0)
    self.assertGreater(d["tiling_bandwidth_gbps"], 0.0)


if __name__ == "__main__":
  absltest.main()
