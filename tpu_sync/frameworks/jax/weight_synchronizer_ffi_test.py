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

"""Unit tests for weight_synchronizer_ffi APIs on TPU."""

import collections
import dataclasses
import os
from absl.testing import absltest
from absl.testing import parameterized
import jax
import jax.numpy as jnp
import numpy as np
from tpu_sync.frameworks.jax import weight_synchronizer_ffi


class WeightSynchronizerFfiTest(parameterized.TestCase):

  def setUp(self):
    super().setUp()
    self.devices = jax.devices()
    self.num_devices = len(self.devices)
    self.mesh = jax.sharding.Mesh(np.array(self.devices), ("x",))
    self.weight_sharding = jax.sharding.NamedSharding(
        self.mesh, jax.sharding.PartitionSpec("x", None)
    )
    self.shard_idx = jax.device_put(
        jnp.arange(self.num_devices, dtype=jnp.int32),
        jax.sharding.NamedSharding(self.mesh, jax.sharding.PartitionSpec("x")),
    )

  def tearDown(self):
    weight_synchronizer_ffi.destroy_weight_synchronizer()
    os.environ.pop("RAIDEN_FFI_USE_DIRECT_DEVICE_BUFFER", None)
    super().tearDown()

  @parameterized.named_parameters(
      ("legacy", "0"),
      ("zerocopy", "1"),
  )
  def test_init_weight_synchronizer_and_d2h(self, direct_buffer_env):
    os.environ["RAIDEN_FFI_USE_DIRECT_DEVICE_BUFFER"] = direct_buffer_env
    w0 = jax.device_put(
        jnp.arange(self.num_devices * 16, dtype=jnp.bfloat16).reshape(
            self.num_devices, 16
        ),
        self.weight_sharding,
    )
    w1 = jax.device_put(
        jnp.ones((self.num_devices, 32), dtype=jnp.bfloat16),
        self.weight_sharding,
    )
    device_arrays = [w0, w1]
    slice_byte_sizes = jax.device_put(
        jnp.array([16 * 2, 32 * 2], dtype=jnp.int32),
        jax.sharding.NamedSharding(self.mesh, jax.sharding.PartitionSpec(None)),
    )

    meta = weight_synchronizer_ffi.init_weight_synchronizer_and_d2h(
        device_arrays=device_arrays,
        shard_idx=self.shard_idx,
        mesh=self.mesh,
        slice_byte_sizes=slice_byte_sizes,
        local_port=0,
        parallelism=1,
        num_layers=len(device_arrays),
        listener_port=0,
        num_shards=self.num_devices,
    )
    jax.block_until_ready(meta)

    meta_np = np.asarray(meta)
    self.assertEqual(meta_np.shape, (self.num_devices, 10))
    for rank in range(self.num_devices):
      self.assertGreater(int(meta_np[rank, 4]), 0)
      self.assertGreater(int(meta_np[rank, 5]), 0)

  @parameterized.named_parameters(
      ("legacy", "0"),
      ("zerocopy", "1"),
  )
  def test_d2h_and_h2d(self, direct_buffer_env):
    os.environ["RAIDEN_FFI_USE_DIRECT_DEVICE_BUFFER"] = direct_buffer_env
    src_w0 = jax.device_put(
        jnp.arange(self.num_devices * 16, dtype=jnp.bfloat16).reshape(
            self.num_devices, 16
        ),
        self.weight_sharding,
    )
    src_w1 = jax.device_put(
        jnp.full((self.num_devices, 32), 3.5, dtype=jnp.bfloat16),
        self.weight_sharding,
    )
    slice_byte_sizes = jax.device_put(
        jnp.array([16 * 2, 32 * 2], dtype=jnp.int32),
        jax.sharding.NamedSharding(self.mesh, jax.sharding.PartitionSpec(None)),
    )

    meta = weight_synchronizer_ffi.init_weight_synchronizer(
        device_arrays=[src_w0, src_w1],
        shard_idx=self.shard_idx,
        mesh=self.mesh,
        slice_byte_sizes=slice_byte_sizes,
        local_port=0,
        parallelism=1,
        num_layers=2,
        listener_port=0,
        num_shards=self.num_devices,
    )
    jax.block_until_ready(meta)

    d2h_w0 = weight_synchronizer_ffi.d2h(
        src_w0, self.shard_idx, self.mesh, layer_idx=0
    )
    d2h_w1 = weight_synchronizer_ffi.d2h(
        src_w1, self.shard_idx, self.mesh, layer_idx=1
    )
    jax.block_until_ready(d2h_w0)
    jax.block_until_ready(d2h_w1)

    dst_w0_init = jax.device_put(
        jnp.zeros_like(src_w0),
        self.weight_sharding,
    )
    dst_w1_init = jax.device_put(
        jnp.zeros_like(src_w1),
        self.weight_sharding,
    )

    dst_w0 = weight_synchronizer_ffi.h2d(
        dst_w0_init, self.shard_idx, self.mesh, layer_idx=0
    )
    dst_w1 = weight_synchronizer_ffi.h2d(
        dst_w1_init, self.shard_idx, self.mesh, layer_idx=1
    )
    jax.block_until_ready(dst_w0)
    jax.block_until_ready(dst_w1)

    np.testing.assert_array_equal(np.asarray(dst_w0), np.asarray(src_w0))
    np.testing.assert_array_equal(np.asarray(dst_w1), np.asarray(src_w1))

  @parameterized.named_parameters(
      ("legacy", "0"),
      ("zerocopy", "1"),
  )
  def test_multi_h2d(self, direct_buffer_env):
    os.environ["RAIDEN_FFI_USE_DIRECT_DEVICE_BUFFER"] = direct_buffer_env
    src_w0 = jax.device_put(
        jnp.arange(self.num_devices * 16, dtype=jnp.bfloat16).reshape(
            self.num_devices, 16
        ),
        self.weight_sharding,
    )
    src_w1 = jax.device_put(
        jnp.full((self.num_devices, 32), 7.25, dtype=jnp.bfloat16),
        self.weight_sharding,
    )
    src_arrays = [src_w0, src_w1]
    slice_byte_sizes = jax.device_put(
        jnp.array([16 * 2, 32 * 2], dtype=jnp.int32),
        jax.sharding.NamedSharding(self.mesh, jax.sharding.PartitionSpec(None)),
    )

    meta = weight_synchronizer_ffi.init_weight_synchronizer_and_d2h(
        device_arrays=src_arrays,
        shard_idx=self.shard_idx,
        mesh=self.mesh,
        slice_byte_sizes=slice_byte_sizes,
        local_port=0,
        parallelism=1,
        num_layers=len(src_arrays),
        listener_port=0,
        num_shards=self.num_devices,
    )
    jax.block_until_ready(meta)

    dst_templates = [
        jax.device_put(jnp.zeros_like(arr), self.weight_sharding)
        for arr in src_arrays
    ]
    restored = weight_synchronizer_ffi.multi_h2d(
        dst_templates, self.shard_idx, self.mesh
    )
    for orig, rest in zip(src_arrays, restored):
      jax.block_until_ready(rest)
      np.testing.assert_array_equal(np.asarray(rest), np.asarray(orig))

  @parameterized.named_parameters(
      ("legacy", "0"),
      ("direct_device_buffer", "1"),
  )
  def test_init_weight_synchronizer_multi_layer_bind(self, direct_buffer_env):
    os.environ["RAIDEN_FFI_USE_DIRECT_DEVICE_BUFFER"] = direct_buffer_env
    src_w0 = jax.device_put(
        jnp.arange(self.num_devices * 16, dtype=jnp.bfloat16).reshape(
            self.num_devices, 16
        ),
        self.weight_sharding,
    )
    src_w1 = jax.device_put(
        jnp.full((self.num_devices, 32), 3.5, dtype=jnp.bfloat16),
        self.weight_sharding,
    )
    src_arrays = [src_w0, src_w1]
    slice_byte_sizes = jax.device_put(
        jnp.array([16 * 2, 32 * 2], dtype=jnp.int32),
        jax.sharding.NamedSharding(self.mesh, jax.sharding.PartitionSpec(None)),
    )

    meta = weight_synchronizer_ffi.init_weight_synchronizer(
        device_arrays=src_arrays,
        shard_idx=self.shard_idx,
        mesh=self.mesh,
        slice_byte_sizes=slice_byte_sizes,
        local_port=0,
        parallelism=1,
        num_layers=len(src_arrays),
        listener_port=0,
        num_shards=self.num_devices,
    )
    meta_np = np.asarray(meta).reshape(-1, 10)
    self.assertEqual(meta_np.shape, (self.num_devices, 10))
    for row in meta_np:
      self.assertGreater(int(row[4]), 0)
      self.assertGreater(int(row[5]), 0)


@dataclasses.dataclass(frozen=True)
class _FakeDevice:
  """Minimal stand-in for a jax.Device in a multi-process mesh."""

  process_index: int
  id: int


class DeriveHostSlotsTest(absltest.TestCase):

  def _assert_each_host_owns_exactly_slots_0_to_n(
      self, host_indices: np.ndarray, local_slots: np.ndarray, num_shards: int
  ) -> None:
    slots_by_host = collections.defaultdict(list)
    for host_idx, slot in zip(host_indices.flat, local_slots.flat):
      slots_by_host[int(host_idx)].append(int(slot))
    for host_idx, slots in slots_by_host.items():
      self.assertEqual(
          sorted(slots),
          list(range(num_shards)),
          f"host_idx={host_idx} slots={slots}",
      )

  def test_single_process_mesh_groups_contiguous_runs_of_num_shards(self):
    devices = np.array(jax.devices())
    self.assertLen(devices, 8)
    self.assertLen({d.process_index for d in devices}, 1)

    host_indices, local_slots = weight_synchronizer_ffi._derive_host_slots(
        devices, num_shards=4
    )

    self.assertEqual(host_indices.tolist(), [0, 0, 0, 0, 1, 1, 1, 1])
    self.assertEqual(local_slots.tolist(), [0, 1, 2, 3, 0, 1, 2, 3])
    self._assert_each_host_owns_exactly_slots_0_to_n(
        host_indices, local_slots, num_shards=4
    )

  def test_single_process_mesh_single_synchronizer_for_all_devices(self):
    devices = np.array(jax.devices())
    self.assertLen(devices, 8)

    host_indices, local_slots = weight_synchronizer_ffi._derive_host_slots(
        devices, num_shards=8
    )

    self.assertEqual(host_indices.tolist(), [0] * 8)
    self.assertEqual(local_slots.tolist(), list(range(8)))
    self._assert_each_host_owns_exactly_slots_0_to_n(
        host_indices, local_slots, num_shards=8
    )

  def test_single_process_2d_mesh_uses_flat_row_major_order(self):
    devices = np.array(jax.devices()).reshape(2, 4)

    host_indices, local_slots = weight_synchronizer_ffi._derive_host_slots(
        devices, num_shards=4
    )

    self.assertEqual(host_indices.shape, (2, 4))
    self.assertEqual(host_indices.tolist(), [[0, 0, 0, 0], [1, 1, 1, 1]])
    self.assertEqual(local_slots.tolist(), [[0, 1, 2, 3], [0, 1, 2, 3]])
    self._assert_each_host_owns_exactly_slots_0_to_n(
        host_indices, local_slots, num_shards=4
    )

  def test_single_process_mesh_rejects_num_shards_not_dividing_devices(self):
    devices = np.array(jax.devices())
    self.assertLen(devices, 8)
    with self.assertRaisesRegex(
        ValueError, "8 devices, which is not a multiple of num_shards=3"
    ):
      weight_synchronizer_ffi._derive_host_slots(devices, num_shards=3)

  def test_rejects_non_positive_num_shards(self):
    devices = np.array(jax.devices())
    with self.assertRaisesRegex(ValueError, "num_shards must be positive"):
      weight_synchronizer_ffi._derive_host_slots(devices, num_shards=0)

  def test_multi_process_mesh_uses_process_index_and_rank_within_process(
      self,
  ):
    # 2 processes x 4 devices, interleaved along the minor mesh axis so that
    # a process's devices are NOT a contiguous run in flat order.
    devices = np.empty((2, 4), dtype=object)
    for row in range(2):
      for col in range(4):
        devices[row, col] = _FakeDevice(process_index=col % 2, id=row * 4 + col)

    host_indices, local_slots = weight_synchronizer_ffi._derive_host_slots(
        devices, num_shards=4
    )

    self.assertEqual(host_indices.tolist(), [[0, 1, 0, 1], [0, 1, 0, 1]])
    self.assertEqual(local_slots.tolist(), [[0, 0, 1, 1], [2, 2, 3, 3]])
    self._assert_each_host_owns_exactly_slots_0_to_n(
        host_indices, local_slots, num_shards=4
    )

  def test_multi_process_mesh_rejects_process_not_owning_num_shards(self):
    devices = np.array(
        [_FakeDevice(process_index=0, id=i) for i in range(5)]
        + [_FakeDevice(process_index=1, id=5 + i) for i in range(3)]
    )
    with self.assertRaisesRegex(
        ValueError, "process_index 0 owns 5 mesh devices but num_shards=4"
    ):
      weight_synchronizer_ffi._derive_host_slots(devices, num_shards=4)

  def test_prepare_shard_info_packs_slot_host_and_global_mesh_columns(self):
    mesh = jax.sharding.Mesh(np.array(jax.devices()).reshape(2, 4), ("x", "y"))
    shard_idx = jax.device_put(
        jnp.arange(8, dtype=jnp.int32).reshape(2, 4),
        jax.sharding.NamedSharding(mesh, jax.sharding.PartitionSpec("x", "y")),
    )

    packed = weight_synchronizer_ffi._prepare_shard_info(
        shard_idx, mesh, num_shards=4
    )

    packed_np = np.asarray(packed)
    self.assertEqual(packed_np.shape, (2, 4, 4))
    self.assertTrue(
        packed.sharding.is_equivalent_to(
            jax.sharding.NamedSharding(
                mesh, jax.sharding.PartitionSpec("x", "y", None)
            ),
            packed_np.ndim,
        )
    )
    self.assertEqual(packed_np[..., 0].tolist(), [[0, 1, 2, 3], [4, 5, 6, 7]])
    self.assertEqual(packed_np[..., 1].tolist(), [[0, 1, 2, 3], [0, 1, 2, 3]])
    self.assertEqual(packed_np[..., 2].tolist(), [[0, 0, 0, 0], [1, 1, 1, 1]])
    self.assertEqual(packed_np[..., 3].tolist(), [[0, 1, 2, 3], [4, 5, 6, 7]])


if __name__ == "__main__":
  absltest.main()
