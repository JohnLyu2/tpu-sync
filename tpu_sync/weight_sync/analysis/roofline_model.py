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

"""Mathematical roofline analytical model for weight synchronization in Trellis / TPU Raiden."""

from collections.abc import Sequence
import dataclasses
import math

# Named constants with b/558046180 references.
_UNOPTIMIZED_FFI_D2H_BW_BYTES_S: float = (
    0.50 * 1e9
)  # TODO(fhzhang): Empirical baseline from b/558046180.
_SINGLE_NUMA_NIC_EFFICIENCY: float = (
    0.604  # TODO(fhzhang): Empirical single-NUMA NIC limit from b/558046180.
)
_COLD_SCHEDULE_MATH_S: float = (
    165.0  # TODO(fhzhang): Cold start slice math from b/558046180.
)
_COLD_PROTO_BUILD_S: float = (
    37.5  # TODO(fhzhang): Proto construction overhead from b/558046180.
)
_COLD_RX_ARM_S: float = (
    4.75  # TODO(fhzhang): RX arming latency from b/558046180.
)
_COLD_RPC_SEND_S: float = (
    1.34  # TODO(fhzhang): RPC send latency from b/558046180.
)
_STEADY_RPC_BASE_S: float = (
    0.15  # TODO(fhzhang): Async TCP RPC dispatch base from b/558046180.
)
_STEADY_RPC_PER_WORKER_S: float = (
    0.018  # TODO(fhzhang): RPC dispatch per worker from b/558046180.
)
_STEADY_CPP_UNROLL_S: float = (
    0.10  # TODO(fhzhang): C++ task unroll overhead from b/558046180.
)
_CHUNK_DMA_BASE_LAUNCH_S: float = (
    0.01  # TODO(fhzhang): Base chunk DMA launch barrier from b/558046180.
)
_TRAINER_CHECKSUM_S: float = (
    5.60  # TODO(fhzhang): Trainer checksum verification from b/558046180.
)
_SAMPLER_CHECKSUM_S: float = (
    1.51  # TODO(fhzhang): Sampler checksum verification from b/558046180.
)
_KV_CACHE_RESET_S: float = (
    0.14  # TODO(fhzhang): KV cache state reset from b/558046180.
)


@dataclasses.dataclass(frozen=True)
class ModelSpec:
  """Model parameter geometry and byte payload configuration.

  Attributes:
    name: Model architecture designation.
    total_params: Total parameter count across all model layers.
    dtype_bytes: Bytes per parameter element (default: 2 for bfloat16).
    total_bytes: Aggregate weight byte size.
    num_layers: Total transformer layer count.
    num_variables: Total tensor variable count across the model.
  """

  name: str
  total_params: int
  dtype_bytes: int = 2
  total_bytes: float = 792.69 * 1e9
  num_layers: int = 60
  num_variables: int = 1008

  def __post_init__(self) -> None:
    if self.total_params <= 0:
      raise ValueError(f"total_params must be > 0, got {self.total_params}")
    if self.dtype_bytes <= 0:
      raise ValueError(f"dtype_bytes must be > 0, got {self.dtype_bytes}")
    if self.total_bytes <= 0:
      raise ValueError(f"total_bytes must be > 0, got {self.total_bytes}")
    if self.num_layers <= 0:
      raise ValueError(f"num_layers must be > 0, got {self.num_layers}")
    if self.num_variables <= 0:
      raise ValueError(f"num_variables must be > 0, got {self.num_variables}")


# Pre-defined Qwen 3.5 397B architecture specification (60 layers, 1008 tensors)
QWEN_3_5_397B_SPEC = ModelSpec(
    name="Qwen3.5-397B",
    total_params=396_345_000_000,
    dtype_bytes=2,
    total_bytes=792.69 * 1e9,
    num_layers=60,
    num_variables=1008,
)


@dataclasses.dataclass(frozen=True)
class TrainerTopology:
  """Trainer cluster topology and hardware parameters.

  Attributes:
    num_hosts: Number of trainer hosts.
    pcie_d2h_bw_per_host_gb_s: PCIe Gen5 D2H bandwidth per host in GB/s.
    d2h_efficiency: Effective D2H DMA efficiency.
    dma_launch_overhead_per_tensor_us: Per-tensor DMA launch overhead in us.
    dma_batch_barrier_overhead_s: Batch barrier and stream sync overhead in s.
    nic_egress_bw_gbps: Host NIC egress bandwidth in Gbps.
    nic_efficiency: Effective NIC egress efficiency.
  """

  num_hosts: int = 32
  pcie_d2h_bw_per_host_gb_s: float = 252.0
  d2h_efficiency: float = 0.60
  dma_launch_overhead_per_tensor_us: float = 20.0
  dma_batch_barrier_overhead_s: float = 0.15
  nic_egress_bw_gbps: float = 200.0
  nic_efficiency: float = 0.85

  def __post_init__(self) -> None:
    if self.num_hosts <= 0:
      raise ValueError(f"num_hosts must be > 0, got {self.num_hosts}")
    if self.pcie_d2h_bw_per_host_gb_s <= 0:
      raise ValueError(
          "pcie_d2h_bw_per_host_gb_s must be > 0, got"
          f" {self.pcie_d2h_bw_per_host_gb_s}"
      )
    if self.d2h_efficiency <= 0:
      raise ValueError(f"d2h_efficiency must be > 0, got {self.d2h_efficiency}")
    if self.nic_egress_bw_gbps <= 0:
      raise ValueError(
          f"nic_egress_bw_gbps must be > 0, got {self.nic_egress_bw_gbps}"
      )
    if self.nic_efficiency <= 0:
      raise ValueError(f"nic_efficiency must be > 0, got {self.nic_efficiency}")


@dataclasses.dataclass(frozen=True)
class SamplerTopology:
  """Inference sampler cluster topology and hardware parameters.

  Attributes:
    num_samplers: Number of inference sampler instances.
    hosts_per_sampler: Number of hosts per sampler replica.
    payload_per_host_bytes: Byte payload size transferred per sampler host.
    nic_ingress_bw_gbps: Host NIC ingress bandwidth in Gbps.
    nic_egress_bw_gbps: Host NIC egress bandwidth in Gbps.
    nic_efficiency: Effective NIC goodput efficiency.
    pcie_h2d_bw_per_host_gb_s: PCIe Gen5 H2D bandwidth per host in GB/s.
    h2d_efficiency: Effective H2D DMA efficiency.
    dma_launch_overhead_per_tensor_us: Per-tensor DMA launch overhead in us.
    cpu_tiling_bw_per_host_gb_s: CPU tiling bandwidth per host in GB/s.
  """

  num_samplers: int = 1
  hosts_per_sampler: int = 2
  payload_per_host_bytes: float = 224.06 * 1e9
  nic_ingress_bw_gbps: float = 200.0
  nic_egress_bw_gbps: float = 200.0
  nic_efficiency: float = 0.85
  pcie_h2d_bw_per_host_gb_s: float = 252.0
  h2d_efficiency: float = 0.60
  dma_launch_overhead_per_tensor_us: float = 20.0
  cpu_tiling_bw_per_host_gb_s: float = 150.0

  def __post_init__(self) -> None:
    if self.num_samplers <= 0:
      raise ValueError(f"num_samplers must be > 0, got {self.num_samplers}")
    if self.hosts_per_sampler <= 0:
      raise ValueError(
          f"hosts_per_sampler must be > 0, got {self.hosts_per_sampler}"
      )
    if self.payload_per_host_bytes <= 0:
      raise ValueError(
          "payload_per_host_bytes must be > 0, got"
          f" {self.payload_per_host_bytes}"
      )
    if self.nic_ingress_bw_gbps <= 0:
      raise ValueError(
          f"nic_ingress_bw_gbps must be > 0, got {self.nic_ingress_bw_gbps}"
      )
    if self.nic_egress_bw_gbps <= 0:
      raise ValueError(
          f"nic_egress_bw_gbps must be > 0, got {self.nic_egress_bw_gbps}"
      )
    if self.nic_efficiency <= 0:
      raise ValueError(f"nic_efficiency must be > 0, got {self.nic_efficiency}")
    if self.pcie_h2d_bw_per_host_gb_s <= 0:
      raise ValueError(
          "pcie_h2d_bw_per_host_gb_s must be > 0, got"
          f" {self.pcie_h2d_bw_per_host_gb_s}"
      )
    if self.h2d_efficiency <= 0:
      raise ValueError(f"h2d_efficiency must be > 0, got {self.h2d_efficiency}")
    if self.cpu_tiling_bw_per_host_gb_s <= 0:
      raise ValueError(
          "cpu_tiling_bw_per_host_gb_s must be > 0, got"
          f" {self.cpu_tiling_bw_per_host_gb_s}"
      )


@dataclasses.dataclass(frozen=True)
class TransferStrategy:
  """Weight synchronization strategy and runtime options.

  Attributes:
    enable_relay_broadcast: Whether multi-hop relay broadcast is enabled.
    pipelined: Whether pipelined chunk streaming is enabled across relay hops.
    num_pipeline_chunks: Number of pipeline chunks/layers for streaming overlap.
    verify_checksums: Whether diagnostic verification checksums are enabled.
    cached_schedule: Step 1+ cached schedule vs Step 0 cold start.
    multi_numa_socket: Multi-NUMA vs Single-NUMA binding.
  """

  enable_relay_broadcast: bool = True
  pipelined: bool = True
  num_pipeline_chunks: int = 60
  verify_checksums: bool = False
  cached_schedule: bool = True
  multi_numa_socket: bool = True

  def __post_init__(self) -> None:
    if self.num_pipeline_chunks <= 0:
      raise ValueError(
          f"num_pipeline_chunks must be > 0, got {self.num_pipeline_chunks}"
      )


@dataclasses.dataclass(frozen=True)
class StageBreakdown:
  """Detailed per-stage latency breakdown and roofline metrics.

  Attributes:
    d2h_s: Device-to-Host transfer latency in seconds.
    trainer_checksum_s: Trainer diagnostic checksum latency in seconds.
    control_plane_s: Orchestrator control plane dispatch latency in seconds.
    h2h_wire_s: Physical network wire latency in seconds.
    h2d_exposed_tail_s: Sampler Host-to-Device exposed tail latency in seconds.
    sampler_checksum_s: Sampler diagnostic checksum latency in seconds.
    kv_reset_s: KV cache reset latency in seconds.
    total_s: Total end-to-end synchronization latency in seconds.
    bottleneck_stage: Primary critical bottleneck stage name.
    bottleneck_description: Detailed description of critical bottleneck path.
    hardware_roofline_floor_s: Theoretical hardware roofline floor in seconds.
    efficiency_vs_roofline: Percentage efficiency relative to hardware roofline.
    seed_samplers: Number of seed samplers populated in Round 0.
    relay_hops: Number of multi-hop relay stages or rounds.
  """

  d2h_s: float
  trainer_checksum_s: float
  control_plane_s: float
  h2h_wire_s: float
  h2d_exposed_tail_s: float
  sampler_checksum_s: float
  kv_reset_s: float
  total_s: float
  bottleneck_stage: str
  bottleneck_description: str
  hardware_roofline_floor_s: float
  efficiency_vs_roofline: float
  seed_samplers: int = 16
  relay_hops: int = 1


class RooflineModel:
  """Analytical roofline evaluator for TPU Raiden weight synchronization."""

  @classmethod
  def _validate_inputs(
      cls,
      model: ModelSpec,
      trainer: TrainerTopology,
      sampler: SamplerTopology,
      strategy: TransferStrategy,
  ) -> None:
    """Validates structural and numeric constraints across all model inputs.

    Args:
      model: Model architecture specifications.
      trainer: Trainer cluster topology and bandwidth parameters.
      sampler: Sampler cluster topology and bandwidth parameters.
      strategy: Transfer and broadcast strategy options.

    Raises:
      ValueError: If any count, size, or bandwidth parameter is invalid.
    """
    if model.num_variables < strategy.num_pipeline_chunks:
      raise ValueError(
          f"num_variables ({model.num_variables}) must be >= "
          f"num_pipeline_chunks ({strategy.num_pipeline_chunks})"
      )
    if sampler.payload_per_host_bytes > model.total_bytes:
      raise ValueError(
          f"sampler payload_per_host_bytes ({sampler.payload_per_host_bytes}) "
          f"cannot exceed model total_bytes ({model.total_bytes})"
      )
    if trainer.num_hosts <= 0:
      raise ValueError(
          f"trainer.num_hosts must be > 0, got {trainer.num_hosts}"
      )
    if sampler.hosts_per_sampler <= 0:
      raise ValueError(
          "sampler.hosts_per_sampler must be > 0, got"
          f" {sampler.hosts_per_sampler}"
      )

  @classmethod
  def compute_d2h_latency(
      cls,
      model: ModelSpec,
      trainer: TrainerTopology,
      is_unoptimized_ffi: bool = False,
  ) -> float:
    """Computes Trainer Device-to-Host (D2H) DMA transfer latency.

    Args:
      model: Model architecture specifications.
      trainer: Trainer cluster topology.
      is_unoptimized_ffi: Whether to simulate unoptimized FFI baseline.

    Returns:
      Total D2H DMA transfer latency in seconds.
    """
    volume_per_host = model.total_bytes / trainer.num_hosts
    if is_unoptimized_ffi:
      return volume_per_host / _UNOPTIMIZED_FFI_D2H_BW_BYTES_S
    eff_bw = trainer.pcie_d2h_bw_per_host_gb_s * 1e9 * trainer.d2h_efficiency
    total_launch_overhead = trainer.dma_batch_barrier_overhead_s + (
        model.num_variables * trainer.dma_launch_overhead_per_tensor_us * 1e-6
    )
    return (volume_per_host / eff_bw) + total_launch_overhead

  @classmethod
  def compute_control_plane_latency(
      cls,
      trainer: TrainerTopology,
      sampler: SamplerTopology,
      strategy: TransferStrategy,
  ) -> float:
    """Computes Orchestrator control-plane schedule and RPC dispatch latency.

    Args:
      trainer: Trainer cluster topology.
      sampler: Sampler cluster topology.
      strategy: Transfer strategy and runtime configuration.

    Returns:
      Total control plane latency in seconds.
    """
    if not strategy.cached_schedule:
      return (
          _COLD_SCHEDULE_MATH_S
          + _COLD_PROTO_BUILD_S
          + _COLD_RX_ARM_S
          + _COLD_RPC_SEND_S
      )

    total_workers = trainer.num_hosts + (
        sampler.num_samplers * sampler.hosts_per_sampler
    )
    rpc_dispatch_s = _STEADY_RPC_BASE_S + (
        _STEADY_RPC_PER_WORKER_S * total_workers
    )
    return rpc_dispatch_s + _STEADY_CPP_UNROLL_S

  @classmethod
  def compute_seed_samplers(
      cls,
      trainer: TrainerTopology,
      sampler: SamplerTopology,
      strategy: TransferStrategy,
  ) -> int:
    """Computes the Round-0 bandwidth-matched seed sampler count.

    Args:
      trainer: Trainer cluster topology.
      sampler: Sampler cluster topology.
      strategy: Transfer strategy options.

    Returns:
      Integer number of seed samplers to populate in Round 0.
    """
    train_tx_bw = (trainer.nic_egress_bw_gbps * 1e9 / 8.0) * (
        trainer.nic_efficiency
        if strategy.multi_numa_socket
        else _SINGLE_NUMA_NIC_EFFICIENCY
    )
    sample_rx_bw = (sampler.nic_ingress_bw_gbps * 1e9 / 8.0) * (
        sampler.nic_efficiency
        if strategy.multi_numa_socket
        else _SINGLE_NUMA_NIC_EFFICIENCY
    )
    denom = sampler.hosts_per_sampler * sample_rx_bw
    n_seed = max(
        1,
        int((trainer.num_hosts * train_tx_bw) // denom),
    )
    return n_seed

  @classmethod
  def compute_h2h_wire_latency(
      cls,
      trainer: TrainerTopology,
      sampler: SamplerTopology,
      strategy: TransferStrategy,
  ) -> tuple[float, str]:
    """Computes Physical Host-to-Host (H2H) network transfer latency.

    Args:
      trainer: Trainer cluster topology.
      sampler: Sampler cluster topology.
      strategy: Transfer strategy options.

    Returns:
      A tuple of (wire_latency_seconds, bottleneck_description).
    """
    sampler_host_volume = sampler.payload_per_host_bytes

    train_tx_bw = (trainer.nic_egress_bw_gbps * 1e9 / 8.0) * (
        trainer.nic_efficiency
        if strategy.multi_numa_socket
        else _SINGLE_NUMA_NIC_EFFICIENCY
    )
    sample_rx_bw = (sampler.nic_ingress_bw_gbps * 1e9 / 8.0) * (
        sampler.nic_efficiency
        if strategy.multi_numa_socket
        else _SINGLE_NUMA_NIC_EFFICIENCY
    )
    sample_tx_bw = (sampler.nic_egress_bw_gbps * 1e9 / 8.0) * (
        sampler.nic_efficiency
        if strategy.multi_numa_socket
        else _SINGLE_NUMA_NIC_EFFICIENCY
    )

    n_samplers = sampler.num_samplers
    n_seed = cls.compute_seed_samplers(trainer, sampler, strategy)

    # Case 1: Unrelayed Direct P2P or sampler count within Round-0 seed capacity
    if not strategy.enable_relay_broadcast or n_samplers <= n_seed:
      trainer_egress_volume = (
          n_samplers * sampler.hosts_per_sampler / trainer.num_hosts
      ) * sampler_host_volume
      t_sender_egress = trainer_egress_volume / train_tx_bw
      t_receiver_ingress = sampler_host_volume / sample_rx_bw
      if t_sender_egress > t_receiver_ingress:
        return (
            t_sender_egress,
            (
                f"Sender Egress Bound (Trainer TX: {trainer.num_hosts} hosts"
                f" @ {trainer.nic_egress_bw_gbps:.0f}G pushing {n_samplers}"
                " samplers)"
            ),
        )
      return (
          t_receiver_ingress,
          (
              "Receiver Ingress Bound (Sampler RX:"
              f" {sampler.hosts_per_sampler} hosts/sampler @"
              f" {sampler.nic_ingress_bw_gbps:.0f}G, N_seed={n_seed})"
          ),
      )

    # Case 2: Bandwidth-Matched Multi-Hop Relay (n_samplers > n_seed)
    seed_count = min(n_samplers, n_seed)
    t_round_0 = max(
        (seed_count * sampler.hosts_per_sampler * sampler_host_volume)
        / (trainer.num_hosts * train_tx_bw),
        sampler_host_volume / sample_rx_bw,
    )
    eff_hop_bw = min(sample_rx_bw, sample_tx_bw)

    if not strategy.pipelined:
      rounds = math.ceil(math.log2(n_samplers / n_seed + 1))
      t_sf = t_round_0 + (rounds - 1) * (sampler_host_volume / eff_hop_bw)
      return (
          t_sf,
          (
              f"Bandwidth-Matched Store-and-Forward (N_seed={n_seed},"
              f" Rounds={rounds})"
          ),
      )

    chain_depth = math.ceil(n_samplers / n_seed)
    stages = strategy.num_pipeline_chunks
    chunk_volume = sampler_host_volume / stages
    chunk_hop_time = chunk_volume / eff_hop_bw
    t_pipelined = t_round_0 + ((chain_depth - 1) * chunk_hop_time)
    return (
        t_pipelined,
        (
            f"Bandwidth-Matched Pipelined Relay (N_seed={n_seed},"
            f" Hops={chain_depth}, BW={eff_hop_bw*8/1e9:.1f} Gbps)"
        ),
    )

  @classmethod
  def compute_h2d_tail_latency(
      cls,
      model: ModelSpec,
      sampler: SamplerTopology,
      strategy: TransferStrategy,
      h2h_latency_s: float,
  ) -> float:
    """Computes Sampler Host-to-Device (H2D) exposed tail latency.

    Args:
      model: Model architecture specifications.
      sampler: Sampler cluster topology.
      strategy: Transfer strategy options.
      h2h_latency_s: Prior H2H wire latency for overlap calculation.

    Returns:
      Exposed H2D tail latency in seconds.
    """
    sampler_host_volume = sampler.payload_per_host_bytes
    tiling_bw = sampler.cpu_tiling_bw_per_host_gb_s * 1e9
    h2d_dma_bw = (
        sampler.pcie_h2d_bw_per_host_gb_s * 1e9 * sampler.h2d_efficiency
    )

    t_tiling_total = sampler_host_volume / tiling_bw
    t_h2d_dma_total = sampler_host_volume / h2d_dma_bw
    t_h2d_stage_total = max(t_tiling_total, t_h2d_dma_total)

    # Under chunk pipelining, H2D overlaps with H2H network streaming
    stages = strategy.num_pipeline_chunks
    tensors_per_stage = model.num_variables // stages
    chunk_launch_overhead = _CHUNK_DMA_BASE_LAUNCH_S + (
        tensors_per_stage * sampler.dma_launch_overhead_per_tensor_us * 1e-6
    )
    chunk_drain_s = (
        (sampler_host_volume / stages) / h2d_dma_bw
    ) + chunk_launch_overhead

    exposed_tail_s = max(0.0, t_h2d_stage_total - h2h_latency_s) + chunk_drain_s
    return exposed_tail_s

  @classmethod
  def evaluate(
      cls,
      model: ModelSpec = QWEN_3_5_397B_SPEC,
      trainer: TrainerTopology = TrainerTopology(),
      sampler: SamplerTopology = SamplerTopology(),
      strategy: TransferStrategy = TransferStrategy(),
      is_unoptimized_d2h: bool = False,
  ) -> StageBreakdown:
    """Runs a complete end-to-end roofline analysis.

    Args:
      model: Model architecture specifications.
      trainer: Trainer cluster topology.
      sampler: Sampler cluster topology.
      strategy: Transfer strategy options.
      is_unoptimized_d2h: Whether to simulate unoptimized FFI baseline.

    Returns:
      StageBreakdown containing latency components and bottleneck metrics.
    """
    cls._validate_inputs(model, trainer, sampler, strategy)

    # 1. D2H DMA
    t_d2h = cls.compute_d2h_latency(
        model, trainer, is_unoptimized_ffi=is_unoptimized_d2h
    )

    # 2. Checksums
    t_train_check = _TRAINER_CHECKSUM_S if strategy.verify_checksums else 0.0
    t_sample_check = _SAMPLER_CHECKSUM_S if strategy.verify_checksums else 0.0

    # 3. Control Plane
    t_control = cls.compute_control_plane_latency(trainer, sampler, strategy)

    # 4. H2H Network Wire
    t_h2h, h2h_desc = cls.compute_h2h_wire_latency(trainer, sampler, strategy)

    # 5. Exposed H2D Tail
    t_h2d_tail = cls.compute_h2d_tail_latency(model, sampler, strategy, t_h2h)

    # 6. KV Reset
    t_kv_reset = _KV_CACHE_RESET_S

    # Total Latency
    t_total = (
        t_d2h
        + t_train_check
        + t_control
        + t_h2h
        + t_h2d_tail
        + t_sample_check
        + t_kv_reset
    )

    # Theoretical Hardware Roofline Ceiling
    vol_train_host = model.total_bytes / trainer.num_hosts
    vol_sample_host = sampler.payload_per_host_bytes
    floor_d2h = vol_train_host / (trainer.pcie_d2h_bw_per_host_gb_s * 1e9)
    floor_h2h = vol_sample_host / (sampler.nic_ingress_bw_gbps * 1e9 / 8.0)
    floor_h2d_drain = (vol_sample_host / strategy.num_pipeline_chunks) / (
        sampler.pcie_h2d_bw_per_host_gb_s * 1e9
    )
    hardware_roofline_floor = (
        floor_d2h + floor_h2h + floor_h2d_drain + t_kv_reset
    )

    # Determine Critical Bottleneck Stage
    stages = {
        "Trainer D2H DMA": t_d2h,
        "Physical H2H Wire": t_h2h,
        "Exposed H2D Tail": t_h2d_tail,
        "Control Plane Dispatch": t_control,
        "Diagnostic Checksums": t_train_check + t_sample_check,
    }
    bottleneck_stage = max(stages.items(), key=lambda x: x[1])[0]

    n_samplers = sampler.num_samplers
    n_seed = cls.compute_seed_samplers(trainer, sampler, strategy)
    if not strategy.enable_relay_broadcast or n_samplers <= n_seed:
      relay_hops = 1
    elif strategy.pipelined:
      relay_hops = math.ceil(n_samplers / n_seed)
    else:
      relay_hops = math.ceil(math.log2(n_samplers / n_seed + 1))

    return StageBreakdown(
        d2h_s=t_d2h,
        trainer_checksum_s=t_train_check,
        control_plane_s=t_control,
        h2h_wire_s=t_h2h,
        h2d_exposed_tail_s=t_h2d_tail,
        sampler_checksum_s=t_sample_check,
        kv_reset_s=t_kv_reset,
        total_s=t_total,
        bottleneck_stage=bottleneck_stage,
        bottleneck_description=(
            h2h_desc
            if bottleneck_stage == "Physical H2H Wire"
            else f"Bottlenecked by {bottleneck_stage}"
        ),
        hardware_roofline_floor_s=hardware_roofline_floor,
        efficiency_vs_roofline=(hardware_roofline_floor / t_total) * 100.0,
        seed_samplers=n_seed,
        relay_hops=relay_hops,
    )

  @classmethod
  def sweep_samplers(
      cls,
      model: ModelSpec = QWEN_3_5_397B_SPEC,
      trainer: TrainerTopology = TrainerTopology(),
      sampler_base: SamplerTopology = SamplerTopology(),
      sampler_counts: Sequence[int] = (1, 2, 4, 8, 16, 32, 64, 128),
  ) -> dict[str, dict[int, StageBreakdown]]:
    """Sweeps over different numbers of samplers and transfer strategies.

    Args:
      model: Model architecture specifications.
      trainer: Trainer cluster topology.
      sampler_base: Base sampler topology with hardware specs.
      sampler_counts: Sequence of sampler instance counts to evaluate.

    Returns:
      Dictionary mapping strategy name to dict of {sampler_count:
      StageBreakdown}.
    """
    strategies = {
        "direct_p2p": TransferStrategy(
            enable_relay_broadcast=False, pipelined=True
        ),
        "matched_store_and_forward": TransferStrategy(
            enable_relay_broadcast=True, pipelined=False
        ),
        "matched_pipelined": TransferStrategy(
            enable_relay_broadcast=True, pipelined=True
        ),
    }
    results: dict[str, dict[int, StageBreakdown]] = {}
    for strat_key, strat in strategies.items():
      results[strat_key] = {}
      for n in sampler_counts:
        s_topo = dataclasses.replace(sampler_base, num_samplers=n)
        results[strat_key][n] = cls.evaluate(
            model=model, trainer=trainer, sampler=s_topo, strategy=strat
        )
    return results
