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

"""Unit tests for JAX utils."""

import dataclasses
import os

from absl.testing import absltest
import jax
import jax.numpy as jnp
import numpy as np

from tpu_sync.frameworks.jax import utils

os.environ["XLA_FLAGS"] = "--xla_force_host_platform_device_count=4"

P = jax.sharding.PartitionSpec


class GlobalShardIndicesForArrayTest(absltest.TestCase):

  def setUp(self):
    super().setUp()
    devices = jax.devices("cpu")
    self.assertLen(devices, 4)
    self.mesh = jax.sharding.Mesh(np.array(devices).reshape(2, 2), ("x", "y"))
    self.mesh_flat_devices = list(self.mesh.devices.flat)

  def _put(self, spec: P) -> jax.Array:
    return jax.device_put(
        jnp.arange(64, dtype=jnp.float32).reshape(8, 8),
        jax.sharding.NamedSharding(self.mesh, spec),
    )

  def test_fully_sharded_2d_enumerates_grid_row_major(self):
    arr = self._put(P("x", "y"))
    self.assertEqual(
        utils.global_shard_indices_for_array(arr, self.mesh_flat_devices),
        [0, 1, 2, 3],
    )

  def test_transposed_spec_follows_tensor_dims_not_mesh_dims(self):
    arr = self._put(P("y", "x"))
    # mesh (x, y) flat order is (0,0), (0,1), (1,0), (1,1); tensor dim 0 is
    # partitioned by y and dim 1 by x, so the slice index is y * 2 + x.
    self.assertEqual(
        utils.global_shard_indices_for_array(arr, self.mesh_flat_devices),
        [0, 2, 1, 3],
    )

  def test_replicated_minor_axis_shares_index(self):
    arr = self._put(P("x", None))
    self.assertEqual(
        utils.global_shard_indices_for_array(arr, self.mesh_flat_devices),
        [0, 0, 1, 1],
    )

  def test_replicated_major_axis_shares_index(self):
    arr = self._put(P("y", None))
    self.assertEqual(
        utils.global_shard_indices_for_array(arr, self.mesh_flat_devices),
        [0, 1, 0, 1],
    )

  def test_dim1_only_sharding(self):
    arr = self._put(P(None, "x"))
    self.assertEqual(
        utils.global_shard_indices_for_array(arr, self.mesh_flat_devices),
        [0, 0, 1, 1],
    )

  def test_fully_replicated_all_zero(self):
    arr = self._put(P())
    self.assertEqual(
        utils.global_shard_indices_for_array(arr, self.mesh_flat_devices),
        [0, 0, 0, 0],
    )

  def test_follows_shard_devices_order_not_mesh_order(self):
    arr = self._put(P("x", "y"))
    reversed_devices = list(reversed(self.mesh_flat_devices))
    self.assertEqual(
        utils.global_shard_indices_for_array(arr, reversed_devices),
        [3, 2, 1, 0],
    )

  def test_subset_of_devices(self):
    arr = self._put(P("x", "y"))
    self.assertEqual(
        utils.global_shard_indices_for_array(
            arr, [self.mesh_flat_devices[3], self.mesh_flat_devices[1]]
        ),
        [3, 1],
    )

  def test_device_outside_sharding_raises(self):
    sub_mesh = jax.sharding.Mesh(
        np.array(self.mesh_flat_devices[:2]).reshape(1, 2), ("x", "y")
    )
    arr = jax.device_put(
        jnp.zeros((8, 8), dtype=jnp.float32),
        jax.sharding.NamedSharding(sub_mesh, P("x", "y")),
    )
    with self.assertRaisesRegex(ValueError, "is not part of the sharding"):
      utils.global_shard_indices_for_array(arr, [self.mesh_flat_devices[3]])

  def test_ragged_partition_raises(self):
    # JAX rejects uneven NamedShardings up front, so use a duck-typed sharding
    # that claims a 3-row tile over an 8-row array.
    device = self.mesh_flat_devices[0]
    arr = _FakeArray(
        shape=(8, 8),
        sharding=_FakeSharding(
            shard_shape_value=(3, 8),
            device_map={device: (slice(0, 3), slice(0, 8))},
        ),
    )
    with self.assertRaisesRegex(ValueError, "does not tile array shape"):
      utils.global_shard_indices_for_array(arr, [device])

  def test_misaligned_slice_start_raises(self):
    device = self.mesh_flat_devices[0]
    arr = _FakeArray(
        shape=(8, 8),
        sharding=_FakeSharding(
            shard_shape_value=(4, 8),
            device_map={device: (slice(2, 6), slice(0, 8))},
        ),
    )
    with self.assertRaisesRegex(ValueError, "not tile-aligned at dim 0"):
      utils.global_shard_indices_for_array(arr, [device])


@dataclasses.dataclass(frozen=True)
class _FakeSharding:
  """Duck-typed sharding exposing only what the helper reads."""

  shard_shape_value: tuple[int, ...]
  device_map: dict[jax.Device, tuple[slice, ...]]

  def shard_shape(self, global_shape: tuple[int, ...]) -> tuple[int, ...]:
    del global_shape
    return self.shard_shape_value

  def devices_indices_map(
      self, global_shape: tuple[int, ...]
  ) -> dict[jax.Device, tuple[slice, ...]]:
    del global_shape
    return self.device_map


@dataclasses.dataclass(frozen=True)
class _FakeArray:
  shape: tuple[int, ...]
  sharding: _FakeSharding


if __name__ == "__main__":
  absltest.main()
