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

"""Unit test for weight sync with TP mismatch (Trainer TP=2 -> Sampler TP=1).

Tests Flat Direct Push (broadcast_k=64) weight transfer from a TP=2 trainer
to a TP=1 sampler, reproducing reported hang conditions under bounded timeouts.
"""

import asyncio
import dataclasses
import threading

from absl import flags
from absl import logging
from absl.testing import absltest
from absl.testing import parameterized
import numpy as np

from tpu_sync.api.common import RaidenId
from tpu_sync.api.jax import weight_synchronizer
from tpu_sync.rpc import raiden_controller
from tpu_sync.rpc import raiden_service_pb2

_TRANSFER_TIMEOUT_SECS = flags.DEFINE_float(
    "transfer_timeout_secs",
    10.0,
    "Maximum seconds to wait for transfer controller future and destination"
    " completion before declaring a hang failure.",
)


def _make_small_model_specs() -> (
    list[tuple[tuple[int, ...], list[str], str, int]]
):
  """Generates a small model spec with mixed TP-sharded and replicated layers.

  Returns:
    List of tuples of (shape, sharding_spec, name, layer_idx).
  """
  specs = [
      # Layer 0: Attention Q projection (column-sharded on 'tp')
      ((64, 64), ["", "tp"], "decoder.layers.0.attention.query.kernel", 0),
      # Layer 1: Attention Out projection (row-sharded on 'tp')
      ((64, 64), ["tp", ""], "decoder.layers.0.attention.out.kernel", 1),
      # Layer 2: MLP Gate/Up projection (column-sharded on 'tp')
      ((64, 128), ["", "tp"], "decoder.layers.0.mlp.gate_up_proj.kernel", 2),
      # Layer 3: LayerNorm scale (replicated 1D)
      ((64,), [""], "decoder.layers.0.norm.scale", 3),
      # Layer 4: Layer 1 Attention Q projection (column-sharded on 'tp')
      ((64, 64), ["", "tp"], "decoder.layers.1.attention.query.kernel", 4),
      # Layer 5: Layer 1 MLP Down projection (row-sharded on 'tp')
      ((128, 64), ["tp", ""], "decoder.layers.1.mlp.down_proj.kernel", 5),
      # Layer 6: Layer 1 LayerNorm scale (replicated 1D)
      ((64,), [""], "decoder.layers.1.norm.scale", 6),
  ]
  return specs


def _build_variable_protos(
    specs: list[tuple[tuple[int, ...], list[str], str, int]],
    mesh_shape_dict: dict[str, int],
    item_size: int = 2,
    global_shard_indices: list[int] | None = None,
) -> list[raiden_service_pb2.VariableMetadataProto]:
  """Constructs VariableMetadataProto descriptors with explicit sharding specs.

  Args:
    specs: List of variable specification tuples.
    mesh_shape_dict: Mapping of mesh dimension name to mesh dimension size.
    item_size: Byte size of each scalar element.
    global_shard_indices: Optional list of global shard indices for this worker.

  Returns:
    List of VariableMetadataProto descriptors.
  """
  protos = []
  for shape, spec_axes, name, layer_idx in specs:
    sharding_shape = [
        1 if not axis else mesh_shape_dict[axis] for axis in spec_axes
    ]
    layout = list(range(len(shape) - 1, -1, -1))
    proto = raiden_service_pb2.VariableMetadataProto(
        name=name,
        shape=list(shape),
        mesh_shape=sharding_shape,
        layout=layout,
        item_size=item_size,
        layer_idx=layer_idx,
        sharding_spec=spec_axes,
    )
    if global_shard_indices is not None:
      proto.global_shard_indices.extend(global_shard_indices)
    protos.append(proto)
  return protos


def _calculate_shard_byte_sizes(
    specs: list[tuple[tuple[int, ...], list[str], str, int]],
    mesh_shape_dict: dict[str, int],
    item_size: int = 2,
) -> list[int]:
  """Computes per-layer host buffer capacity for one shard of the given mesh.

  Args:
    specs: List of variable specification tuples.
    mesh_shape_dict: Mapping of mesh dimension name to mesh dimension size.
    item_size: Byte size of each scalar element.

  Returns:
    List of per-layer byte sizes for one shard buffer.
  """
  sizes = []
  for shape, spec_axes, _, _ in specs:
    sharding_shape = [
        1 if not axis else mesh_shape_dict[axis] for axis in spec_axes
    ]
    shard_elements = int(np.prod(shape) // np.prod(sharding_shape))
    sizes.append(shard_elements * item_size)
  return sizes


@dataclasses.dataclass(frozen=True)
class Scaled35BVarSpec:
  """Specification for a scaled-down 35B model parameter."""

  name: str
  shape: tuple[int, ...]
  trainer_sharding: list[str]
  sampler_sharding: list[str]
  item_size: int = 2


def _make_scaled_35b_specs() -> list[Scaled35BVarSpec]:
  """Generates scaled-down 35B model specs matching MLPerf recipe sharding.

  Returns:
    List of Scaled35BVarSpec with attention, GDN, router, MoE, and shared
    experts.
  """
  return [
      # 1. Attn Q projection (emb, heads, head_dim)
      Scaled35BVarSpec(
          name="decoder.layers.0.attention.query.kernel",
          shape=(64, 4, 32),
          trainer_sharding=["fsdp,context", "tensor", ""],
          sampler_sharding=["", "expert", ""],
          item_size=2,
      ),
      # 2. Attn K projection
      Scaled35BVarSpec(
          name="decoder.layers.0.attention.key.kernel",
          shape=(64, 2, 32),
          trainer_sharding=["fsdp,context", "tensor", ""],
          sampler_sharding=["", "expert", ""],
          item_size=2,
      ),
      # 3. Attn V projection
      Scaled35BVarSpec(
          name="decoder.layers.0.attention.value.kernel",
          shape=(64, 2, 32),
          trainer_sharding=["fsdp,context", "tensor", ""],
          sampler_sharding=["", "expert", ""],
          item_size=2,
      ),
      # 4. Attn Out projection
      Scaled35BVarSpec(
          name="decoder.layers.0.attention.out.kernel",
          shape=(4, 32, 64),
          trainer_sharding=["tensor", "", "fsdp,context"],
          sampler_sharding=["expert", "", ""],
          item_size=2,
      ),
      # 5. GDN in_proj_qkvz
      Scaled35BVarSpec(
          name="decoder.layers.0.linear_attention.in_proj_qkvz.kernel",
          shape=(64, 4, 32),
          trainer_sharding=["fsdp,context", "tensor", ""],
          sampler_sharding=["", "expert", ""],
          item_size=2,
      ),
      # 6. GDN in_proj_ba
      Scaled35BVarSpec(
          name="decoder.layers.0.linear_attention.in_proj_ba.kernel",
          shape=(64, 2, 32),
          trainer_sharding=["fsdp,context", "", "tensor"],
          sampler_sharding=["", "", "expert"],
          item_size=2,
      ),
      # 7. GDN out_proj
      Scaled35BVarSpec(
          name="decoder.layers.0.linear_attention.out_proj.kernel",
          shape=(4, 32, 64),
          trainer_sharding=["tensor", "", "fsdp,context"],
          sampler_sharding=["expert", "", ""],
          item_size=2,
      ),
      # 8. MoE Router Gate
      Scaled35BVarSpec(
          name="decoder.layers.0.router.gate.kernel",
          shape=(64, 8),
          trainer_sharding=["fsdp,context", ""],
          sampler_sharding=["", ""],
          item_size=2,
      ),
      # 9. Fused Experts wi (num_experts, emb, 2*hidden)
      Scaled35BVarSpec(
          name="decoder.layers.0.moe.experts.wi.kernel",
          shape=(8, 64, 128),
          trainer_sharding=["", "fsdp,context", "tensor"],
          sampler_sharding=["expert", "", ""],
          item_size=2,
      ),
      # 10. Fused Experts wo (num_experts, hidden, emb)
      Scaled35BVarSpec(
          name="decoder.layers.0.moe.experts.wo.kernel",
          shape=(8, 64, 64),
          trainer_sharding=["", "tensor", "fsdp,context"],
          sampler_sharding=["expert", "", ""],
          item_size=2,
      ),
      # 11. Shared Expert wi_0 (emb, hidden)
      Scaled35BVarSpec(
          name="decoder.layers.0.shared_expert.wi_0.kernel",
          shape=(64, 64),
          trainer_sharding=["fsdp,context", "tensor"],
          sampler_sharding=["", "expert"],
          item_size=2,
      ),
      # 12. Shared Expert wi_1 (emb, hidden)
      Scaled35BVarSpec(
          name="decoder.layers.0.shared_expert.wi_1.kernel",
          shape=(64, 64),
          trainer_sharding=["fsdp,context", "tensor"],
          sampler_sharding=["", "expert"],
          item_size=2,
      ),
      # 13. Shared Expert wo (hidden, emb)
      Scaled35BVarSpec(
          name="decoder.layers.0.shared_expert.wo.kernel",
          shape=(64, 64),
          trainer_sharding=["tensor", "fsdp,context"],
          sampler_sharding=["expert", ""],
          item_size=2,
      ),
      # 14. Shared Expert Gate (emb, 1) - float32
      Scaled35BVarSpec(
          name="decoder.layers.0.shared_expert_gate.kernel",
          shape=(64, 1),
          trainer_sharding=["fsdp,context", ""],
          sampler_sharding=["", ""],
          item_size=4,
      ),
  ]


def _compute_var_mesh_shape(
    spec_axes: list[str],
    mesh_shape_dict: dict[str, int],
) -> list[int]:
  """Computes per-variable logical mesh shape (global_shape // local_shape).

  Args:
    spec_axes: Partitioning axis names per array dimension.
    mesh_shape_dict: Mapping of mesh dimension name to mesh dimension size.

  Returns:
    List of dimension sizes in the variable's logical mesh shape.
  """
  var_mesh_shape = []
  for axis_spec in spec_axes:
    if not axis_spec:
      var_mesh_shape.append(1)
    else:
      sub_size = 1
      for sub_axis in axis_spec.split(","):
        cleaned_axis = sub_axis.strip()
        if not cleaned_axis:
          continue
        sub_size *= mesh_shape_dict[cleaned_axis]
      var_mesh_shape.append(sub_size)
  return var_mesh_shape


def _build_35b_variable_protos(
    specs: list[Scaled35BVarSpec],
    mesh_shape_dict: dict[str, int],
    is_trainer: bool,
) -> list[raiden_service_pb2.VariableMetadataProto]:
  """Constructs VariableMetadataProto descriptors for scaled 35B model.

  Args:
    specs: List of Scaled35BVarSpec descriptors.
    mesh_shape_dict: Mapping of mesh dimension name to mesh dimension size.
    is_trainer: True if building descriptors for trainer, False for sampler.

  Returns:
    List of VariableMetadataProto descriptors.
  """
  protos = []
  for idx, item in enumerate(specs):
    spec_axes = item.trainer_sharding if is_trainer else item.sampler_sharding
    var_mesh_shape = _compute_var_mesh_shape(spec_axes, mesh_shape_dict)
    layout = list(range(len(item.shape) - 1, -1, -1))
    proto = raiden_service_pb2.VariableMetadataProto(
        name=item.name,
        shape=list(item.shape),
        mesh_shape=var_mesh_shape,
        layout=layout,
        item_size=item.item_size,
        layer_idx=idx,
        sharding_spec=spec_axes,
    )
    protos.append(proto)
  return protos


def _calculate_35b_shard_byte_sizes(
    specs: list[Scaled35BVarSpec],
    mesh_shape_dict: dict[str, int],
    is_trainer: bool,
) -> list[int]:
  """Computes per-layer host buffer capacity for one shard of the 35B model.

  Args:
    specs: List of Scaled35BVarSpec descriptors.
    mesh_shape_dict: Mapping of mesh dimension name to mesh dimension size.
    is_trainer: True if calculating for trainer mesh, False for sampler mesh.

  Returns:
    List of per-layer byte sizes for one shard buffer.
  """
  sizes = []
  for item in specs:
    spec_axes = item.trainer_sharding if is_trainer else item.sampler_sharding
    var_mesh_shape = _compute_var_mesh_shape(spec_axes, mesh_shape_dict)
    shard_elements = int(np.prod(item.shape) // np.prod(var_mesh_shape))
    sizes.append(shard_elements * item.item_size)
  return sizes


def _slice_global_array(
    global_arr: np.ndarray,
    mesh_axes: list[str],
    mesh_shape: tuple[int, ...],
    sharding_spec: list[str],
    phys_coords: dict[str, int],
) -> np.ndarray:
  """Extracts the slice of global_arr belonging to a device at phys_coords.

  Args:
    global_arr: Full unpartitioned variable NumPy array.
    mesh_axes: Logical mesh dimension names in row-major order.
    mesh_shape: Logical mesh shape.
    sharding_spec: Partitioning axis names per array dimension.
    phys_coords: Logical coordinate mapping axis name to coordinate index.

  Returns:
    Sliced NumPy array slice for this device coordinate.
  """
  slices = []
  for dim_idx, axis_spec in enumerate(sharding_spec):
    dim_len = global_arr.shape[dim_idx]
    if not axis_spec:
      slices.append(slice(0, dim_len))
    else:
      coord = 0
      dim_mesh_size = 1
      for sub_axis in axis_spec.split(","):
        axis_name = sub_axis.strip()
        axis_pos = mesh_axes.index(axis_name)
        sub_size = mesh_shape[axis_pos]
        coord = coord * sub_size + phys_coords[axis_name]
        dim_mesh_size *= sub_size
      slice_size = dim_len // dim_mesh_size
      start = coord * slice_size
      end = start + slice_size
      slices.append(slice(start, end))
  return global_arr[tuple(slices)]


def _fill_trainer_and_compute_expected_35b(
    specs: list[Scaled35BVarSpec],
    trainer_mesh_axes: list[str],
    trainer_mesh_shape: tuple[int, ...],
    trainer_host_shards: list[list[int]],
    ws_src_list: list[weight_synchronizer.WeightSynchronizer],
    sampler_mesh_axes: list[str],
    sampler_mesh_shape: tuple[int, ...],
    seed: int = 0x5A,
) -> list[list[np.ndarray]]:
  """Fills trainer host buffers and computes expected sampler shard arrays.

  Args:
    specs: List of Scaled35BVarSpec descriptors.
    trainer_mesh_axes: Logical mesh axes for trainer.
    trainer_mesh_shape: Logical mesh shape for trainer.
    trainer_host_shards: Per-host list of global shard indices.
    ws_src_list: List of WeightSynchronizer instances for trainer hosts.
    sampler_mesh_axes: Logical mesh axes for sampler.
    sampler_mesh_shape: Logical mesh shape for sampler.
    seed: Deterministic pattern seed byte.

  Returns:
    List of expected arrays per layer and sampler shard: [layer_idx][shard_idx].
  """
  total_trainer_shards = int(np.prod(trainer_mesh_shape))
  expected_by_layer: list[list[np.ndarray]] = []

  for l, item in enumerate(specs):
    num_elem = int(np.prod(item.shape))
    if item.item_size == 4:
      global_arr = (
          (np.arange(num_elem, dtype=np.float32) + 1.0) * 0.125 * (l + 1)
      ).reshape(item.shape)
    else:
      seed_u16 = np.uint16((seed + l * 7) & 0xFF) << np.uint16(8)
      layer_tag = np.uint16((l + 1) & 0x0F) << np.uint16(4)
      offsets = np.arange(num_elem, dtype=np.uint16) & np.uint16(0x000F)
      global_arr = (seed_u16 | layer_tag | offsets).reshape(item.shape)

    for j in range(total_trainer_shards):
      rem = j
      phys_coords = {}
      for axis, size in reversed(
          list(zip(trainer_mesh_axes, trainer_mesh_shape))
      ):
        phys_coords[axis] = rem % size
        rem //= size

      shard_arr = _slice_global_array(
          global_arr,
          trainer_mesh_axes,
          trainer_mesh_shape,
          item.trainer_sharding,
          phys_coords,
      )

      shard_assigned = False
      for ws, shards in zip(ws_src_list, trainer_host_shards):
        if j in shards:
          local_slot = shards.index(j)
          buf = ws.get_host_buffer(layer_idx=l, shard_idx=local_slot)
          words = buf.view(shard_arr.dtype)
          words[: shard_arr.size] = shard_arr.ravel()
          shard_assigned = True
          break
      if not shard_assigned:
        raise ValueError(
            f"Global shard {j} is not mapped to any host synchronizer"
        )

    layer_expected = []
    total_sampler_shards = int(np.prod(sampler_mesh_shape))
    for k in range(total_sampler_shards):
      rem = k
      sampler_phys_coords = {}
      for axis, size in reversed(
          list(zip(sampler_mesh_axes, sampler_mesh_shape))
      ):
        sampler_phys_coords[axis] = rem % size
        rem //= size
      expected_shard = _slice_global_array(
          global_arr,
          sampler_mesh_axes,
          sampler_mesh_shape,
          item.sampler_sharding,
          sampler_phys_coords,
      )
      layer_expected.append(expected_shard)
    expected_by_layer.append(layer_expected)

  return expected_by_layer


def _await_destination_completion(
    ws: weight_synchronizer.WeightSynchronizer,
    uuid: int,
    errors: list[RuntimeError],
) -> None:
  """Awaits transfer completion on a destination worker and captures RuntimeError.

  Args:
    ws: Destination WeightSynchronizer instance.
    uuid: Transfer UUID to await.
    errors: List to append any caught RuntimeError to.
  """
  try:
    ws.wait_for_transfer_completion(uuid=uuid)
  except RuntimeError as e:
    errors.append(e)


class WeightSyncTpMismatchTest(parameterized.TestCase):
  """Reproduces and tests weight sync hang under TP mismatch (TP=2 -> TP=1)."""

  def setUp(self):
    super().setUp()
    self.timeout_secs = _TRANSFER_TIMEOUT_SECS.value
    self.item_size = 2  # bfloat16 / float16
    self.specs = _make_small_model_specs()
    self.num_layers = len(self.specs)

    self.controller_network_client = (
        raiden_controller.WeightSyncWorkerRpcClient(name_resolver=None)
    )
    self.addCleanup(self.controller_network_client.close)

    self.controller = raiden_controller.RaidenController(
        port=0,
        worker_rpc_client=self.controller_network_client,
    )
    self.controller_server = raiden_controller.RaidenControllerServer(
        self.controller
    )
    self.controller_server.start()
    self.addCleanup(self.controller_server.stop)

    self.ctrl_client = raiden_controller.RaidenControllerClientFacade(
        f"127.0.0.1:{self.controller_server.port}",
        name_resolver=None,
    )
    if hasattr(self.ctrl_client, "_control_pipe_client") and hasattr(
        self.ctrl_client._control_pipe_client, "close"
    ):
      self.addCleanup(self.ctrl_client._control_pipe_client.close)

    weight_synchronizer.configure_telemetry(["buffered"])
    self.addCleanup(lambda: weight_synchronizer.configure_telemetry([]))

  def _execute_transfer_with_timeout(
      self,
      src_units: list[RaidenId],
      dst_units: list[RaidenId],
      dst_ws_list: list[weight_synchronizer.WeightSynchronizer],
      uuid: int,
      req_id: str,
      test_label: str,
      skip_tiling: dict[int, bool] | None,
      timeout_secs: float,
  ) -> None:
    """Executes start_transfer and waits with bounded timeout for hang reproduction.

    Args:
      src_units: List of source work units.
      dst_units: List of destination work units.
      dst_ws_list: List of destination WeightSynchronizer instances to await.
      uuid: Transfer UUID.
      req_id: Request identifier string.
      test_label: Descriptive label for failure messages.
      skip_tiling: Explicit skip_tiling dictionary, or None for automatic
        ReshardPlanner alignment.
      timeout_secs: Timeout duration in seconds before declaring a hang.
    """
    self.controller.broadcast_k = 64
    self.controller._plan_cache.clear()

    future = self.controller.start_transfer(
        src_units=src_units,
        dst_units=dst_units,
        dst_mem_type=raiden_controller.RaidenMemoryType.DRAM,
        use_block_chunks=True,
        is_sender=True,
        uuid=uuid,
        req_id=req_id,
        skip_d2h=True,
        skip_tiling=skip_tiling,
    )

    loop = asyncio.new_event_loop()
    try:
      try:
        loop.run_until_complete(
            asyncio.wait_for(future.wait(), timeout=timeout_secs)
        )
      except asyncio.TimeoutError:
        self.fail(
            "Transfer HUNG at stage 'controller_future': future.wait() did not"
            f" complete within {timeout_secs}s for {test_label}."
        )
    finally:
      loop.close()

    for idx, ws_dst in enumerate(dst_ws_list):
      completion_errors: list[RuntimeError] = []
      dest_thread = threading.Thread(
          target=_await_destination_completion,
          args=(ws_dst, uuid, completion_errors),
          daemon=True,
      )
      dest_thread.start()
      dest_thread.join(timeout=timeout_secs)
      if dest_thread.is_alive():
        self.fail(
            "Transfer HUNG at stage 'destination_completion': destination"
            f" worker {idx} wait_for_transfer_completion(uuid={uuid}) did not"
            f" unblock within {timeout_secs}s for {test_label}."
        )
      if completion_errors:
        raise completion_errors[0]

  def _fill_and_compute_expected_tp1(
      self,
      ws_src: weight_synchronizer.WeightSynchronizer,
      seed: int = 0x33,
  ) -> list[np.ndarray]:
    """Fills TP=1 source with unique pattern and returns expected full arrays.

    Args:
      ws_src: Source WeightSynchronizer instance.
      seed: Deterministic pattern seed byte.

    Returns:
      List of expected full NumPy arrays.
    """
    expected_arrays = []
    seed_u16 = np.uint16(seed & 0xFF) << np.uint16(8)
    for l, (shape, _, _, _) in enumerate(self.specs):
      buf = ws_src.get_host_buffer(layer_idx=l, shard_idx=0)
      words = buf.view(np.uint16)
      num_elements = int(np.prod(shape))
      layer_tag = np.uint16((l + 1) & 0x0F) << np.uint16(4)
      offsets = np.arange(num_elements, dtype=np.uint16) & np.uint16(0x000F)
      pattern = seed_u16 | layer_tag | offsets
      words[:num_elements] = pattern
      expected_arrays.append(pattern.reshape(shape))
    return expected_arrays

  def _fill_and_compute_expected_tp2(
      self,
      trainer_shards: list[tuple[weight_synchronizer.WeightSynchronizer, int]],
      seed: int = 0x55,
  ) -> list[np.ndarray]:
    """Fills TP=2 trainer shards and returns reassembled ground-truth arrays.

    Args:
      trainer_shards: List of (ws_instance, shard_idx) pairs for shard 0 and 1.
      seed: Deterministic pattern seed byte.

    Returns:
      List of reassembled expected full NumPy arrays of shape specs[l][0].
    """
    expected_full_arrays = []
    seed_u16 = np.uint16(seed & 0xFF) << np.uint16(8)
    for l, (shape, spec_axes, _, _) in enumerate(self.specs):
      layer_tag = np.uint16((l + 1) & 0x0F) << np.uint16(4)
      is_tp_sharded = "tp" in spec_axes
      if is_tp_sharded:
        tp_axis = spec_axes.index("tp")
        shard_dim_size = shape[tp_axis] // 2
        shard_shape = list(shape)
        shard_shape[tp_axis] = shard_dim_size
        shard_elements = int(np.prod(shard_shape))

        shard_arrays = []
        for s_idx, (ws, local_shard) in enumerate(trainer_shards):
          buf = ws.get_host_buffer(layer_idx=l, shard_idx=local_shard)
          words = buf.view(np.uint16)
          shard_tag = np.uint16(s_idx & 0x03) << np.uint16(2)
          offsets = np.arange(shard_elements, dtype=np.uint16) & np.uint16(
              0x0003
          )
          pattern = seed_u16 | layer_tag | shard_tag | offsets
          words[:shard_elements] = pattern
          shard_arrays.append(pattern.reshape(shard_shape))
        reassembled = np.concatenate(shard_arrays, axis=tp_axis)
        expected_full_arrays.append(reassembled)
      else:
        # Replicated tensor
        num_elements = int(np.prod(shape))
        offsets = np.arange(num_elements, dtype=np.uint16) & np.uint16(0x000F)
        pattern = seed_u16 | layer_tag | offsets
        for ws, local_shard in trainer_shards:
          buf = ws.get_host_buffer(layer_idx=l, shard_idx=local_shard)
          words = buf.view(np.uint16)
          words[:num_elements] = pattern
        expected_full_arrays.append(pattern.reshape(shape))
    return expected_full_arrays

  def _verify_sampler_parity(
      self,
      ws_dst: weight_synchronizer.WeightSynchronizer,
      expected_arrays: list[np.ndarray],
      test_label: str,
  ) -> None:
    """Verifies byte and numerical parity of destination host buffers.

    Args:
      ws_dst: Destination WeightSynchronizer instance.
      expected_arrays: List of expected NumPy arrays per layer.
      test_label: Descriptive label for assertion error messages.
    """
    for l, expected in enumerate(expected_arrays):
      num_elements = expected.size
      buf = ws_dst.get_host_buffer(layer_idx=l, shard_idx=0)
      actual = buf.view(np.uint16)[:num_elements].reshape(expected.shape)
      self.assertTrue(
          np.array_equal(actual, expected),
          f"{test_label}: byte parity mismatch in layer {l} ("
          f"{self.specs[l][2]}). Actual != Expected.",
      )

  def test_control_tp1_to_tp1(self):
    """Control case: Trainer TP=1 -> Sampler TP=1 should succeed with full parity."""
    src_mesh_dict = {"tp": 1}
    dst_mesh_dict = {"tp": 1}

    src_slice_sizes = _calculate_shard_byte_sizes(
        self.specs, src_mesh_dict, self.item_size
    )
    dst_slice_sizes = _calculate_shard_byte_sizes(
        self.specs, dst_mesh_dict, self.item_size
    )

    ws_src = (
        weight_synchronizer.WeightSynchronizer.test_only_create_cpu_instance(
            num_layers=self.num_layers,
            num_shards=1,
            slice_byte_size=src_slice_sizes,
            local_port=0,
            listener_port=0,
            bind_ip="127.0.0.1",
        )
    )
    self.addCleanup(ws_src.shutdown)

    ws_dst = (
        weight_synchronizer.WeightSynchronizer.test_only_create_cpu_instance(
            num_layers=self.num_layers,
            num_shards=1,
            slice_byte_size=dst_slice_sizes,
            local_port=0,
            listener_port=0,
            bind_ip="127.0.0.1",
        )
    )
    self.addCleanup(ws_dst.shutdown)

    src_unit = RaidenId("control_trainer", "0", "weights")
    dst_unit = RaidenId("control_sampler", "0", "weights")

    mesh_axes = ["tp"]
    src_protos = _build_variable_protos(
        self.specs, src_mesh_dict, self.item_size, global_shard_indices=[0]
    )
    dst_protos = _build_variable_protos(
        self.specs, dst_mesh_dict, self.item_size, global_shard_indices=[0]
    )

    self.ctrl_client.register_work_unit(
        src_unit,
        [f"127.0.0.1:{ws_src.local_port}"],
        f"127.0.0.1:{ws_src.listener_port}",
        mesh_shape=[1],
        variables=src_protos,
        mesh_axes=mesh_axes,
    )
    self.ctrl_client.register_work_unit(
        dst_unit,
        [f"127.0.0.1:{ws_dst.local_port}"],
        f"127.0.0.1:{ws_dst.listener_port}",
        mesh_shape=[1],
        variables=dst_protos,
        mesh_axes=mesh_axes,
    )

    expected_arrays = self._fill_and_compute_expected_tp1(ws_src, seed=0x77)
    for l in range(self.num_layers):
      ws_dst.get_host_buffer(layer_idx=l, shard_idx=0)[:] = 0x00

    self._execute_transfer_with_timeout(
        src_units=[src_unit],
        dst_units=[dst_unit],
        dst_ws_list=[ws_dst],
        uuid=2001,
        req_id="ctrl_tp1_to_tp1",
        test_label="Control TP=1 -> TP=1",
        skip_tiling={l: False for l in range(self.num_layers)},
        timeout_secs=self.timeout_secs,
    )
    self._verify_sampler_parity(ws_dst, expected_arrays, "Control TP=1->TP=1")

  def test_trainer_tp2_single_unit_to_sampler_tp1(self):
    """Layout (a): Trainer TP=2 (1 unit, num_shards=2) -> Sampler TP=1."""
    src_mesh_dict = {"tp": 2}
    dst_mesh_dict = {"tp": 1}

    src_slice_sizes = _calculate_shard_byte_sizes(
        self.specs, src_mesh_dict, self.item_size
    )
    dst_slice_sizes = _calculate_shard_byte_sizes(
        self.specs, dst_mesh_dict, self.item_size
    )

    ws_src = (
        weight_synchronizer.WeightSynchronizer.test_only_create_cpu_instance(
            num_layers=self.num_layers,
            num_shards=2,
            slice_byte_size=src_slice_sizes,
            local_port=0,
            listener_port=0,
            bind_ip="127.0.0.1",
        )
    )
    self.addCleanup(ws_src.shutdown)

    ws_dst = (
        weight_synchronizer.WeightSynchronizer.test_only_create_cpu_instance(
            num_layers=self.num_layers,
            num_shards=1,
            slice_byte_size=dst_slice_sizes,
            local_port=0,
            listener_port=0,
            bind_ip="127.0.0.1",
        )
    )
    self.addCleanup(ws_dst.shutdown)

    src_unit = RaidenId("trainer", "0", "weights")
    dst_unit = RaidenId("sampler", "0", "weights")

    src_protos = _build_variable_protos(
        self.specs, src_mesh_dict, self.item_size
    )
    for p in src_protos:
      if "tp" in p.sharding_spec:
        p.global_shard_indices.extend([0, 1])
      else:
        p.global_shard_indices.extend([0, 0])

    dst_protos = _build_variable_protos(
        self.specs, dst_mesh_dict, self.item_size, global_shard_indices=[0]
    )

    mesh_axes = ["tp"]
    mesh_shape = [2]

    self.ctrl_client.register_work_unit(
        src_unit,
        [f"127.0.0.1:{ws_src.local_port}"] * 2,
        f"127.0.0.1:{ws_src.listener_port}",
        mesh_shape=mesh_shape,
        variables=src_protos,
        mesh_axes=mesh_axes,
    )
    self.ctrl_client.register_work_unit(
        dst_unit,
        [f"127.0.0.1:{ws_dst.local_port}"],
        f"127.0.0.1:{ws_dst.listener_port}",
        mesh_shape=[1],
        variables=dst_protos,
        mesh_axes=mesh_axes,
    )

    expected_arrays = self._fill_and_compute_expected_tp2(
        [(ws_src, 0), (ws_src, 1)], seed=0xAA
    )
    for l in range(self.num_layers):
      ws_dst.get_host_buffer(layer_idx=l, shard_idx=0)[:] = 0x00

    self._execute_transfer_with_timeout(
        src_units=[src_unit],
        dst_units=[dst_unit],
        dst_ws_list=[ws_dst],
        uuid=2002,
        req_id="tp2_single_unit_to_tp1",
        test_label="Trainer TP=2 (1 unit, 2 shards) -> Sampler TP=1",
        skip_tiling={l: False for l in range(self.num_layers)},
        timeout_secs=self.timeout_secs,
    )
    self._verify_sampler_parity(
        ws_dst, expected_arrays, "Trainer TP=2 (1 unit) -> Sampler TP=1"
    )

  def test_trainer_tp2_single_unit_spec_mapping_to_sampler_tp1(self):
    """Layout (a) via spec mapping (no global_shard_indices, auto skip_tiling)."""
    src_mesh_dict = {"tp": 2}
    dst_mesh_dict = {"tp": 1}

    src_slice_sizes = _calculate_shard_byte_sizes(
        self.specs, src_mesh_dict, self.item_size
    )
    dst_slice_sizes = _calculate_shard_byte_sizes(
        self.specs, dst_mesh_dict, self.item_size
    )

    ws_src = (
        weight_synchronizer.WeightSynchronizer.test_only_create_cpu_instance(
            num_layers=self.num_layers,
            num_shards=2,
            slice_byte_size=src_slice_sizes,
            local_port=0,
            listener_port=0,
            bind_ip="127.0.0.1",
        )
    )
    self.addCleanup(ws_src.shutdown)

    ws_dst = (
        weight_synchronizer.WeightSynchronizer.test_only_create_cpu_instance(
            num_layers=self.num_layers,
            num_shards=1,
            slice_byte_size=dst_slice_sizes,
            local_port=0,
            listener_port=0,
            bind_ip="127.0.0.1",
        )
    )
    self.addCleanup(ws_dst.shutdown)

    src_unit = RaidenId("trainer_spec", "0", "weights")
    dst_unit = RaidenId("sampler_spec", "0", "weights")

    src_protos = _build_variable_protos(
        self.specs, src_mesh_dict, self.item_size
    )
    dst_protos = _build_variable_protos(
        self.specs, dst_mesh_dict, self.item_size
    )

    mesh_axes = ["tp"]
    mesh_shape = [2]

    self.ctrl_client.register_work_unit(
        src_unit,
        [f"127.0.0.1:{ws_src.local_port}"] * 2,
        f"127.0.0.1:{ws_src.listener_port}",
        mesh_shape=mesh_shape,
        variables=src_protos,
        mesh_axes=mesh_axes,
    )
    self.ctrl_client.register_work_unit(
        dst_unit,
        [f"127.0.0.1:{ws_dst.local_port}"],
        f"127.0.0.1:{ws_dst.listener_port}",
        mesh_shape=[1],
        variables=dst_protos,
        mesh_axes=mesh_axes,
    )

    expected_arrays = self._fill_and_compute_expected_tp2(
        [(ws_src, 0), (ws_src, 1)], seed=0xEE
    )
    for l in range(self.num_layers):
      ws_dst.get_host_buffer(layer_idx=l, shard_idx=0)[:] = 0x00

    self._execute_transfer_with_timeout(
        src_units=[src_unit],
        dst_units=[dst_unit],
        dst_ws_list=[ws_dst],
        uuid=2004,
        req_id="tp2_single_unit_spec_mapping_to_tp1",
        test_label="Trainer TP=2 (spec-mapping) -> Sampler TP=1",
        skip_tiling=None,
        timeout_secs=self.timeout_secs,
    )
    self._verify_sampler_parity(
        ws_dst, expected_arrays, "Trainer TP=2 (spec-mapping) -> Sampler TP=1"
    )

  def test_trainer_tp2_multi_unit_to_sampler_tp1(self):
    """Layout (b): Trainer TP=2 (2 units, 1 shard each) -> Sampler TP=1."""
    src_mesh_dict = {"tp": 2}
    dst_mesh_dict = {"tp": 1}

    src_slice_sizes = _calculate_shard_byte_sizes(
        self.specs, src_mesh_dict, self.item_size
    )
    dst_slice_sizes = _calculate_shard_byte_sizes(
        self.specs, dst_mesh_dict, self.item_size
    )

    ws_src0 = (
        weight_synchronizer.WeightSynchronizer.test_only_create_cpu_instance(
            num_layers=self.num_layers,
            num_shards=1,
            slice_byte_size=src_slice_sizes,
            local_port=0,
            listener_port=0,
            bind_ip="127.0.0.1",
            global_shard_indices=[0],
        )
    )
    self.addCleanup(ws_src0.shutdown)

    ws_src1 = (
        weight_synchronizer.WeightSynchronizer.test_only_create_cpu_instance(
            num_layers=self.num_layers,
            num_shards=1,
            slice_byte_size=src_slice_sizes,
            local_port=0,
            listener_port=0,
            bind_ip="127.0.0.1",
            global_shard_indices=[1],
        )
    )
    self.addCleanup(ws_src1.shutdown)

    ws_dst = (
        weight_synchronizer.WeightSynchronizer.test_only_create_cpu_instance(
            num_layers=self.num_layers,
            num_shards=1,
            slice_byte_size=dst_slice_sizes,
            local_port=0,
            listener_port=0,
            bind_ip="127.0.0.1",
        )
    )
    self.addCleanup(ws_dst.shutdown)

    src_unit0 = RaidenId("trainer", "0", "weights")
    src_unit1 = RaidenId("trainer", "1", "weights")
    dst_unit = RaidenId("sampler", "0", "weights")

    mesh_axes = ["tp"]
    src_protos0 = _build_variable_protos(
        self.specs, src_mesh_dict, self.item_size
    )
    for p in src_protos0:
      p.global_shard_indices.append(0)

    src_protos1 = _build_variable_protos(
        self.specs, src_mesh_dict, self.item_size
    )
    for p in src_protos1:
      # If TP sharded, global shard is 1; if replicated, global shard is 0
      p.global_shard_indices.append(1 if "tp" in p.sharding_spec else 0)

    dst_protos = _build_variable_protos(
        self.specs, dst_mesh_dict, self.item_size, global_shard_indices=[0]
    )

    self.ctrl_client.register_work_unit(
        src_unit0,
        [f"127.0.0.1:{ws_src0.local_port}"],
        f"127.0.0.1:{ws_src0.listener_port}",
        mesh_shape=[1],
        variables=src_protos0,
        mesh_axes=mesh_axes,
    )
    self.ctrl_client.register_work_unit(
        src_unit1,
        [f"127.0.0.1:{ws_src1.local_port}"],
        f"127.0.0.1:{ws_src1.listener_port}",
        mesh_shape=[1],
        variables=src_protos1,
        mesh_axes=mesh_axes,
    )
    self.ctrl_client.register_work_unit(
        dst_unit,
        [f"127.0.0.1:{ws_dst.local_port}"],
        f"127.0.0.1:{ws_dst.listener_port}",
        mesh_shape=[1],
        variables=dst_protos,
        mesh_axes=mesh_axes,
    )

    expected_arrays = self._fill_and_compute_expected_tp2(
        [(ws_src0, 0), (ws_src1, 0)], seed=0xCC
    )
    for l in range(self.num_layers):
      ws_dst.get_host_buffer(layer_idx=l, shard_idx=0)[:] = 0x00

    self._execute_transfer_with_timeout(
        src_units=[src_unit0, src_unit1],
        dst_units=[dst_unit],
        dst_ws_list=[ws_dst],
        uuid=2003,
        req_id="tp2_multi_unit_to_tp1",
        test_label="Trainer TP=2 (2 units, 1 shard each) -> Sampler TP=1",
        skip_tiling={l: False for l in range(self.num_layers)},
        timeout_secs=self.timeout_secs,
    )
    self._verify_sampler_parity(
        ws_dst, expected_arrays, "Trainer TP=2 (2 units) -> Sampler TP=1"
    )

  def _verify_sampler_parity_35b(
      self,
      ws_dst: weight_synchronizer.WeightSynchronizer,
      specs: list[Scaled35BVarSpec],
      expected_by_layer: list[list[np.ndarray]],
      test_label: str,
  ) -> None:
    """Verifies byte and numerical parity for all shards of the 35B model.

    Args:
      ws_dst: Destination WeightSynchronizer instance.
      specs: List of Scaled35BVarSpec descriptors.
      expected_by_layer: Expected arrays per layer and sampler shard.
      test_label: Descriptive label for assertion error messages.
    """
    for l, item in enumerate(specs):
      num_shards = len(expected_by_layer[l])
      for k in range(num_shards):
        expected = expected_by_layer[l][k]
        buf = ws_dst.get_host_buffer(layer_idx=l, shard_idx=k)
        actual = np.frombuffer(buf, dtype=expected.dtype)[
            : expected.size
        ].reshape(expected.shape)
        self.assertTrue(
            np.array_equal(actual, expected),
            f"{test_label}: byte parity mismatch in layer {l} ({item.name}) "
            f"on sampler shard {k}. Actual != Expected.",
        )

  def _run_pathways_transfer_test(
      self,
      trainer_mesh_shape: tuple[int, ...],
      trainer_mesh_axes: list[str],
      trainer_host_shards: list[list[int]],
      test_label: str,
      uuid: int,
      req_id: str,
      timeout_secs: float = 10.0,
  ) -> None:
    """Executes a Pathways-emulating weight transfer test case.

    Args:
      trainer_mesh_shape: Logical mesh shape for trainer.
      trainer_mesh_axes: Logical mesh axes for trainer.
      trainer_host_shards: List of shard index lists, one per trainer host.
      test_label: Descriptive label for test and error logging.
      uuid: Transfer UUID.
      req_id: Request identifier string.
      timeout_secs: Timeout duration in seconds before declaring a hang.
    """
    specs = _make_scaled_35b_specs()
    num_layers = len(specs)

    trainer_mesh_dict = dict(zip(trainer_mesh_axes, trainer_mesh_shape))
    sampler_mesh_axes = ["attn_dp_expert", "expert"]
    sampler_mesh_shape = (4, 2)
    sampler_mesh_dict = dict(zip(sampler_mesh_axes, sampler_mesh_shape))

    src_slice_sizes = _calculate_35b_shard_byte_sizes(
        specs, trainer_mesh_dict, is_trainer=True
    )
    dst_slice_sizes = _calculate_35b_shard_byte_sizes(
        specs, sampler_mesh_dict, is_trainer=False
    )

    ws_src_list = []
    for host_shards in trainer_host_shards:
      ws_src = (
          weight_synchronizer.WeightSynchronizer.test_only_create_cpu_instance(
              num_layers=num_layers,
              num_shards=len(host_shards),
              slice_byte_size=src_slice_sizes,
              local_port=0,
              listener_port=0,
              bind_ip="127.0.0.1",
              global_shard_indices=host_shards,
          )
      )
      self.addCleanup(ws_src.shutdown)
      ws_src_list.append(ws_src)

    total_sampler_shards = int(np.prod(sampler_mesh_shape))
    ws_dst = (
        weight_synchronizer.WeightSynchronizer.test_only_create_cpu_instance(
            num_layers=num_layers,
            num_shards=total_sampler_shards,
            slice_byte_size=dst_slice_sizes,
            local_port=0,
            listener_port=0,
            bind_ip="127.0.0.1",
            global_shard_indices=list(range(total_sampler_shards)),
        )
    )
    self.addCleanup(ws_dst.shutdown)

    src_unit = RaidenId(f"trainer_{req_id}", "", "weights")
    dst_unit = RaidenId(f"sampler_{req_id}", "", "weights")

    src_protos = _build_35b_variable_protos(
        specs, trainer_mesh_dict, is_trainer=True
    )
    dst_protos = _build_35b_variable_protos(
        specs, sampler_mesh_dict, is_trainer=False
    )

    total_trainer_shards = int(np.prod(trainer_mesh_shape))
    trainer_shard_addresses: list[str | None] = [None] * total_trainer_shards
    for ws_src, host_shards in zip(ws_src_list, trainer_host_shards):
      for shard_idx in host_shards:
        trainer_shard_addresses[shard_idx] = f"127.0.0.1:{ws_src.local_port}"
    for j, addr in enumerate(trainer_shard_addresses):
      if addr is None:
        raise ValueError(f"Global shard {j} not assigned to any emulated host")

    trainer_rpc_endpoints = [
        f"127.0.0.1:{ws_src.listener_port}" for ws_src in ws_src_list
    ]

    self.ctrl_client.register_work_unit(
        src_unit,
        trainer_shard_addresses,  # type: ignore[arg-type]
        control_plane_rpc_address=",".join(trainer_rpc_endpoints),
        mesh_shape=list(trainer_mesh_shape),
        variables=src_protos,
        mesh_axes=trainer_mesh_axes,
    )
    self.ctrl_client.register_work_unit(
        dst_unit,
        [f"127.0.0.1:{ws_dst.local_port}"] * total_sampler_shards,
        control_plane_rpc_address=f"127.0.0.1:{ws_dst.listener_port}",
        mesh_shape=list(sampler_mesh_shape),
        variables=dst_protos,
        mesh_axes=sampler_mesh_axes,
    )

    expected_by_layer = _fill_trainer_and_compute_expected_35b(
        specs=specs,
        trainer_mesh_axes=trainer_mesh_axes,
        trainer_mesh_shape=trainer_mesh_shape,
        trainer_host_shards=trainer_host_shards,
        ws_src_list=ws_src_list,
        sampler_mesh_axes=sampler_mesh_axes,
        sampler_mesh_shape=sampler_mesh_shape,
    )

    for l in range(num_layers):
      for k in range(total_sampler_shards):
        ws_dst.get_host_buffer(layer_idx=l, shard_idx=k)[:] = 0x00

    try:
      self._execute_transfer_with_timeout(
          src_units=[src_unit],
          dst_units=[dst_unit],
          dst_ws_list=[ws_dst],
          uuid=uuid,
          req_id=req_id,
          test_label=test_label,
          skip_tiling=None,
          timeout_secs=timeout_secs,
      )
    except AssertionError as hang_err:
      if not self.controller._plan_cache:
        raise RuntimeError(
            "No cached transfer schedule found in controller._plan_cache for"
            f" uuid={uuid}"
        ) from hang_err
      cached_sched = next(iter(self.controller._plan_cache.values()))
      push_scheds = cached_sched.computed_schedules[src_unit]

      job_entity = self.controller.get_or_create_entity(src_unit)
      transfer_plan = self.controller._active_transfers.get(req_id)
      if transfer_plan is None:
        raise RuntimeError(
            f"No active transfer plan found in controller for req_id={req_id}"
        ) from hang_err

      diag_msg = [f"Planned push schedule shards: {sorted(push_scheds.keys())}"]
      total_untransmitted: set[int] = set()
      for h_idx, (ws_src, held_shards_list) in enumerate(
          zip(ws_src_list, trainer_host_shards)
      ):
        endpoint = f"127.0.0.1:{ws_src.listener_port}"
        assigned_shards = job_entity.get_host_owned_shards(
            transfer_plan, endpoint, unit=src_unit
        )
        if assigned_shards is None:
          raise RuntimeError(
              f"get_host_owned_shards returned None for endpoint {endpoint}"
          ) from hang_err
        held_shards = set(held_shards_list)
        dropped_shards = assigned_shards - held_shards
        total_untransmitted |= dropped_shards
        diag_msg.append(
            f"Host {h_idx} (endpoint {endpoint}) assigned shards"
            f" {sorted(assigned_shards)} via get_host_owned_shards but holds"
            f" {sorted(held_shards)}; dropped by Host {h_idx}:"
            f" {sorted(dropped_shards)}"
        )
      diag_msg.append(
          f"Total un-transmitted shards: {sorted(total_untransmitted)}"
      )
      logging.error(
          "%s: TRANSFER HANG DIAGNOSTICS:\n%s", test_label, "\n".join(diag_msg)
      )
      raise hang_err

    self._verify_sampler_parity_35b(
        ws_dst, specs, expected_by_layer, test_label
    )

  def test_pathways_control_t1_mesh_2_2_1(self):
    """Pathways control: Trainer TP=1 mesh (2,2,1) -> Sampler (4,2)."""
    self._run_pathways_transfer_test(
        trainer_mesh_shape=(2, 2, 1),
        trainer_mesh_axes=["fsdp", "context", "tensor"],
        trainer_host_shards=[[0, 1], [2, 3]],
        test_label="Pathways Control T=1 (2,2,1)",
        uuid=3001,
        req_id="pw_ctrl_t1_221",
    )

  def test_pathways_control_t1_mesh_4_2_1(self):
    """Pathways control: Trainer TP=1 mesh (4,2,1) -> Sampler (4,2)."""
    self._run_pathways_transfer_test(
        trainer_mesh_shape=(4, 2, 1),
        trainer_mesh_axes=["fsdp", "context", "tensor"],
        trainer_host_shards=[[0, 1, 2, 3], [4, 5, 6, 7]],
        test_label="Pathways Control T=1 (4,2,1)",
        uuid=3002,
        req_id="pw_ctrl_t1_421",
    )

  def test_pathways_repro_t2_mesh_2_2_2_contiguous_order(self):
    """Pathways comparison: Trainer TP=2 mesh (2,2,2) with contiguous host shards."""
    self._run_pathways_transfer_test(
        trainer_mesh_shape=(2, 2, 2),
        trainer_mesh_axes=["fsdp", "context", "tensor"],
        trainer_host_shards=[[0, 1, 2, 3], [4, 5, 6, 7]],
        test_label="Pathways T=2 (2,2,2) Contiguous Host-Order Control",
        uuid=3003,
        req_id="pw_t2_contig",
    )

  @absltest.expectedFailure
  def test_pathways_t2_mesh_2_2_2_torus_order(self):
    """Pathways comparison: Trainer TP=2 mesh (2,2,2) with non-contiguous torus host shards.

    Known issue: get_host_owned_shards assigns a contiguous shard slice to each
    host endpoint, which mismatches torus-interleaved physical host shard
    ownership.
    Shards assigned to a host that are not staged in its local memory buffer are
    silently skipped via `continue` in PushWeightsResharded, resulting in a hang
    at transfer completion waiting for dropped shards.
    """
    self._run_pathways_transfer_test(
        trainer_mesh_shape=(2, 2, 2),
        trainer_mesh_axes=["fsdp", "context", "tensor"],
        trainer_host_shards=[[0, 1, 4, 5], [2, 3, 6, 7]],
        test_label="Pathways T=2 (2,2,2) Torus Non-Contiguous Order",
        uuid=3004,
        req_id="pw_t2_torus",
        timeout_secs=2.5,
    )


if __name__ == "__main__":
  absltest.main()
