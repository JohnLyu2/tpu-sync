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

"""Command-line interface for TPU Raiden weight synchronization roofline analysis."""

from collections.abc import Sequence

from absl import app
from absl import flags

from tpu_sync.weight_sync.analysis import roofline_model

_MODEL_BYTES_GB = flags.DEFINE_float(
    "model_bytes_gb",
    792.69,
    "Total model weight size in GB (default: 792.69 GB for Qwen3.5-397B).",
)
_NUM_SAMPLERS = flags.DEFINE_integer(
    "num_samplers", 1, "Number of inference sampler instances (default: 1)."
)
_TRAINER_NIC_GBPS = flags.DEFINE_float(
    "trainer_nic_gbps",
    200.0,
    "Trainer host NIC egress bandwidth in Gbps (default: 200 Gbps).",
)
_SAMPLER_NIC_GBPS = flags.DEFINE_float(
    "sampler_nic_gbps",
    200.0,
    "Sampler host NIC ingress/egress bandwidth in Gbps (default: 200 Gbps).",
)
_SAMPLER_PAYLOAD_PER_HOST_GB = flags.DEFINE_float(
    "sampler_payload_per_host_gb",
    None,
    "Payload per sampler host in GB (scales with --model_bytes_gb if omitted).",
)
_ENABLE_RELAY_BROADCAST = flags.DEFINE_bool(
    "enable_relay_broadcast",
    True,
    "Whether bandwidth-matched multi-hop relay broadcast is enabled (False"
    " forces Direct P2P).",
)
_PIPELINED = flags.DEFINE_bool(
    "pipelined",
    True,
    "Whether chunk pipelining is enabled across relay hops.",
)
_TRAINER_HOSTS = flags.DEFINE_integer(
    "trainer_hosts", 32, "Number of trainer hosts (default: 32)."
)
_SAMPLER_HOSTS_PER_INSTANCE = flags.DEFINE_integer(
    "sampler_hosts_per_instance",
    2,
    "Number of hosts per sampler replica (default: 2).",
)
_SWEEP_SAMPLERS = flags.DEFINE_bool(
    "sweep_samplers",
    False,
    "Whether to run a sweep across sampler counts (1 to 128).",
)
_VERIFY_CHECKSUMS = flags.DEFINE_bool(
    "verify_checksums",
    False,
    "Whether diagnostic verification checksums are enabled.",
)


def _format_table(headers: Sequence[str], rows: Sequence[Sequence[str]]) -> str:
  """Formats rows and columns into an aligned ASCII markdown-style table.

  Args:
    headers: Sequence of column header labels.
    rows: Sequence of rows, each containing string cell values.

  Returns:
    Formatted string table with headers and separators.
  """
  col_widths = [len(h) for h in headers]
  for r in rows:
    for i, val in enumerate(r):
      col_widths[i] = max(col_widths[i], len(str(val)))

  header_line = " | ".join(
      h.ljust(col_widths[i]) for i, h in enumerate(headers)
  )
  sep_line = "-+-".join("-" * col_widths[i] for i in range(len(headers)))
  row_lines = [
      " | ".join(str(val).ljust(col_widths[i]) for i, val in enumerate(r))
      for r in rows
  ]
  return f"{header_line}\n{sep_line}\n" + "\n".join(row_lines)


def main(argv: Sequence[str]) -> None:
  """Executes roofline analysis evaluation or sweep over sampler counts.

  Args:
    argv: Positional command-line arguments.
  """
  del argv  # Unused

  if _SAMPLER_PAYLOAD_PER_HOST_GB.value is not None:
    sampler_payload_bytes = _SAMPLER_PAYLOAD_PER_HOST_GB.value * 1e9
  else:
    sampler_payload_bytes = (_MODEL_BYTES_GB.value / 792.69) * 224.06 * 1e9

  total_params = (
      396_345_000_000
      if _MODEL_BYTES_GB.value == 792.69
      else int((_MODEL_BYTES_GB.value * 1e9) / 2)
  )

  model = roofline_model.ModelSpec(
      name="Qwen3.5-397B",
      total_params=total_params,
      dtype_bytes=2,
      total_bytes=_MODEL_BYTES_GB.value * 1e9,
      num_layers=60,
      num_variables=1008,
  )

  trainer = roofline_model.TrainerTopology(
      num_hosts=_TRAINER_HOSTS.value,
      nic_egress_bw_gbps=_TRAINER_NIC_GBPS.value,
  )

  sampler = roofline_model.SamplerTopology(
      num_samplers=_NUM_SAMPLERS.value,
      hosts_per_sampler=_SAMPLER_HOSTS_PER_INSTANCE.value,
      payload_per_host_bytes=sampler_payload_bytes,
      nic_ingress_bw_gbps=_SAMPLER_NIC_GBPS.value,
      nic_egress_bw_gbps=_SAMPLER_NIC_GBPS.value,
  )

  strategy = roofline_model.TransferStrategy(
      enable_relay_broadcast=_ENABLE_RELAY_BROADCAST.value,
      pipelined=_PIPELINED.value,
      verify_checksums=_VERIFY_CHECKSUMS.value,
  )

  if _SWEEP_SAMPLERS.value:
    print("\n=======================================================")
    print(
        f"Weight Sync Scalability Sweep ({model.name}, Trainer"
        f" NIC={_TRAINER_NIC_GBPS.value:.0f}G, Sampler"
        f" NIC={_SAMPLER_NIC_GBPS.value:.0f}G)"
    )
    print("=======================================================\n")
    sweeps = roofline_model.RooflineModel.sweep_samplers(
        model=model,
        trainer=trainer,
        sampler_base=sampler,
        sampler_counts=[1, 2, 4, 8, 16, 32, 64, 128],
    )
    headers = [
        "N_samplers",
        "N_seed",
        "Chain Hops",
        "Direct P2P",
        "Matched Store & Forward",
        "Matched Pipelined Relay",
        "Speedup vs Direct",
    ]
    rows = []
    for n in [1, 2, 4, 8, 16, 32, 64, 128]:
      t_direct = sweeps["direct_p2p"][n].total_s
      t_sf = sweeps["matched_store_and_forward"][n].total_s
      t_pipe = sweeps["matched_pipelined"][n].total_s
      n_seed = sweeps["matched_pipelined"][n].seed_samplers
      hops = sweeps["matched_pipelined"][n].relay_hops
      speedup = t_direct / max(1e-6, t_pipe)
      rows.append([
          f"{n}",
          f"{n_seed}",
          f"{hops}",
          f"{t_direct:.2f} s",
          f"{t_sf:.2f} s",
          f"{t_pipe:.2f} s",
          f"{speedup:.2f}x",
      ])
    print(_format_table(headers, rows))
    return

  res = roofline_model.RooflineModel.evaluate(
      model=model, trainer=trainer, sampler=sampler, strategy=strategy
  )

  print("\n=======================================================")
  print(f"TPU Raiden Weight Sync Roofline Analysis: {model.name}")
  print("=======================================================\n")
  print("Configuration:")
  print(
      f"  - Model Payload:           {model.total_bytes / 1e9:.2f} GB"
      f" ({model.total_params:,} params, {model.num_variables} variables,"
      f" {model.num_layers} layers)"
  )
  print(
      f"  - Trainer Hosts:           {trainer.num_hosts} hosts (D2H payload:"
      f" {model.total_bytes / trainer.num_hosts / 1e9:.2f} GB/host)"
  )
  print(
      f"  - Samplers:                {sampler.num_samplers} instance(s)"
      f" ({sampler.hosts_per_sampler} hosts/instance)"
  )
  print(f"  - Trainer Host NIC:        {_TRAINER_NIC_GBPS.value:.1f} Gbps")
  print(f"  - Sampler Host NIC:        {_SAMPLER_NIC_GBPS.value:.1f} Gbps")
  strategy_str = (
      f"Bandwidth-Matched Pipelined Relay (Hops={res.relay_hops},"
      f" N_seed={res.seed_samplers})"
      if strategy.enable_relay_broadcast and strategy.pipelined
      else (
          f"Bandwidth-Matched Store-and-Forward (Rounds={res.relay_hops},"
          f" N_seed={res.seed_samplers})"
          if strategy.enable_relay_broadcast
          else "Direct P2P"
      )
  )
  print(f"  - Strategy:                {strategy_str}")
  print(
      "  - Diagnostics/Checksums:  "
      f" {'Enabled' if strategy.verify_checksums else 'Disabled (Production default)'}"
  )

  print("\nStage Breakdown:")
  headers = ["Pipeline Stage", "Time (s)", "Share (%)", "Notes"]
  rows = [
      [
          "1. Trainer D2H DMA",
          f"{res.d2h_s:.3f} s",
          f"{(res.d2h_s/res.total_s)*100:.1f}%",
          "PCIe Gen5 x16 (60% eff + DMA launch overhead) HBM -> Host DRAM",
      ],
      [
          "2. Control Plane Dispatch",
          f"{res.control_plane_s:.3f} s",
          f"{(res.control_plane_s/res.total_s)*100:.1f}%",
          "Cached schedule + C++ task unroll",
      ],
      [
          "3. Physical H2H Wire",
          f"{res.h2h_wire_s:.3f} s",
          f"{(res.h2h_wire_s/res.total_s)*100:.1f}%",
          res.bottleneck_description,
      ],
      [
          "4. Exposed H2D Tail",
          f"{res.h2d_exposed_tail_s:.3f} s",
          f"{(res.h2d_exposed_tail_s/res.total_s)*100:.1f}%",
          "CPU Tiling + PCIe H2D DMA drain",
      ],
      [
          "5. KV Cache / State Reset",
          f"{res.kv_reset_s:.3f} s",
          f"{(res.kv_reset_s/res.total_s)*100:.1f}%",
          "Prefix cache & state reset",
      ],
  ]
  if strategy.verify_checksums:
    rows.insert(
        1,
        [
            "  - Trainer Checksum",
            f"{res.trainer_checksum_s:.3f} s",
            f"{(res.trainer_checksum_s/res.total_s)*100:.1f}%",
            "Diagnostic verification",
        ],
    )
    rows.insert(
        5,
        [
            "  - Sampler Checksum",
            f"{res.sampler_checksum_s:.3f} s",
            f"{(res.sampler_checksum_s/res.total_s)*100:.1f}%",
            "Diagnostic verification",
        ],
    )

  print(_format_table(headers, rows))

  print("\nSummary:")
  print(f"  - Total Weight Sync Time:  {res.total_s:.2f} s")
  print(
      f"  - Hardware Roofline Floor: {res.hardware_roofline_floor_s:.2f} s"
      " (100% theoretical ceiling)"
  )
  print(
      f"  - Hardware Efficiency:     {res.efficiency_vs_roofline:.1f}% of"
      " roofline ceiling"
  )
  print(f"  - Primary Bottleneck:      {res.bottleneck_stage}\n")


if __name__ == "__main__":
  app.run(main)
