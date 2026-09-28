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

"""Unit tests for the weight synchronization roofline model."""

import dataclasses

from absl.testing import absltest

from tpu_sync.weight_sync.analysis import roofline_model
from tpu_sync.weight_sync.analysis import sharding_parser

ModelSpec = roofline_model.ModelSpec
RooflineModel = roofline_model.RooflineModel
SamplerTopology = roofline_model.SamplerTopology
TrainerTopology = roofline_model.TrainerTopology
TransferStrategy = roofline_model.TransferStrategy
QWEN_3_5_397B_SPEC = roofline_model.QWEN_3_5_397B_SPEC
ShardingDocParser = sharding_parser.ShardingDocParser


class RooflineModelTest(absltest.TestCase):

  def test_qwen_397b_model_spec(self):
    self.assertEqual(QWEN_3_5_397B_SPEC.name, "Qwen3.5-397B")
    self.assertAlmostEqual(
        QWEN_3_5_397B_SPEC.total_bytes / 1e9, 792.69, places=2
    )
    self.assertEqual(QWEN_3_5_397B_SPEC.num_layers, 60)

  def test_h2h_wire_latency_single_sampler(self):
    trainer = TrainerTopology(
        num_hosts=32, nic_egress_bw_gbps=200.0, nic_efficiency=0.85
    )
    sampler = SamplerTopology(
        num_samplers=1,
        hosts_per_sampler=2,
        nic_ingress_bw_gbps=200.0,
        nic_egress_bw_gbps=200.0,
        nic_efficiency=0.85,
    )
    strat = TransferStrategy(enable_relay_broadcast=True, pipelined=True)

    t_h2h, desc = RooflineModel.compute_h2h_wire_latency(
        trainer=trainer,
        sampler=sampler,
        strategy=strat,
    )
    # Expected: 224.06 GB / (25 GB/s * 0.85) = ~10.54s
    self.assertAlmostEqual(t_h2h, 10.544, delta=0.05)
    self.assertIn("Receiver Ingress Bound", desc)

  def test_d2h_latency(self):
    trainer = TrainerTopology(
        num_hosts=32, pcie_d2h_bw_per_host_gb_s=252.0, d2h_efficiency=0.60
    )
    # Optimized D2H over PCIe Gen5 x16
    t_d2h_opt = RooflineModel.compute_d2h_latency(
        QWEN_3_5_397B_SPEC, trainer, is_unoptimized_ffi=False
    )
    self.assertAlmostEqual(t_d2h_opt, 0.334, delta=0.02)

    # Unoptimized FFI baseline (from b/558046180: ~49.5s - 50.0s)
    t_d2h_unopt = RooflineModel.compute_d2h_latency(
        QWEN_3_5_397B_SPEC, trainer, is_unoptimized_ffi=True
    )
    self.assertAlmostEqual(t_d2h_unopt, 49.54, delta=0.5)

  def test_control_plane_latency(self):
    trainer = TrainerTopology(num_hosts=32)
    sampler = SamplerTopology(num_samplers=1, hosts_per_sampler=2)
    strategy = TransferStrategy(cached_schedule=True)

    t_control = RooflineModel.compute_control_plane_latency(
        trainer=trainer, sampler=sampler, strategy=strategy
    )
    # 0.15 + 0.018 * (32 + 2) + 0.10 = 0.862 s
    self.assertAlmostEqual(t_control, 0.862, delta=0.01)

  def test_bandwidth_matched_seed_samplers(self):
    strategy = TransferStrategy()
    # Symmetric 200G / 200G -> N_seed = 16
    trainer_200g = TrainerTopology(num_hosts=32, nic_egress_bw_gbps=200.0)
    sampler_200g = SamplerTopology(
        hosts_per_sampler=2,
        nic_ingress_bw_gbps=200.0,
        nic_egress_bw_gbps=200.0,
    )
    self.assertEqual(
        RooflineModel.compute_seed_samplers(
            trainer_200g, sampler_200g, strategy
        ),
        16,
    )

    # 400G Trainer / 200G Sampler -> N_seed = 32
    trainer_400g = TrainerTopology(num_hosts=32, nic_egress_bw_gbps=400.0)
    self.assertEqual(
        RooflineModel.compute_seed_samplers(
            trainer_400g, sampler_200g, strategy
        ),
        32,
    )

    # 100G Trainer / 200G Sampler -> N_seed = 8
    trainer_100g = TrainerTopology(num_hosts=32, nic_egress_bw_gbps=100.0)
    self.assertEqual(
        RooflineModel.compute_seed_samplers(
            trainer_100g, sampler_200g, strategy
        ),
        8,
    )

  def test_bandwidth_matched_relay_scaling(self):
    trainer = TrainerTopology(num_hosts=32, nic_egress_bw_gbps=200.0)
    strat_direct = TransferStrategy(
        enable_relay_broadcast=False, pipelined=True
    )
    strat_pipe = TransferStrategy(enable_relay_broadcast=True, pipelined=True)
    strat_sf = TransferStrategy(enable_relay_broadcast=True, pipelined=False)

    # N = 16: Direct P2P and Matched Pipelined Relay have identical wire latency
    sampler_16 = SamplerTopology(
        num_samplers=16,
        hosts_per_sampler=2,
        nic_ingress_bw_gbps=200.0,
        nic_egress_bw_gbps=200.0,
    )
    t_wire_direct_16, _ = RooflineModel.compute_h2h_wire_latency(
        trainer=trainer,
        sampler=sampler_16,
        strategy=strat_direct,
    )
    t_wire_pipe_16, _ = RooflineModel.compute_h2h_wire_latency(
        trainer=trainer,
        sampler=sampler_16,
        strategy=strat_pipe,
    )
    self.assertAlmostEqual(t_wire_direct_16, 10.544, delta=0.05)
    self.assertAlmostEqual(t_wire_pipe_16, 10.544, delta=0.05)

    # N = 64: Matched Pipelined Relay (14.71 s) vs Direct (45.82 s) & S&F (35.27 s)
    sampler_64 = SamplerTopology(
        num_samplers=64,
        hosts_per_sampler=2,
        nic_ingress_bw_gbps=200.0,
        nic_egress_bw_gbps=200.0,
    )
    res_direct_64 = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler_64,
        strategy=strat_direct,
    )
    res_sf_64 = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler_64,
        strategy=strat_sf,
    )
    res_pipe_64 = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler_64,
        strategy=strat_pipe,
    )
    self.assertAlmostEqual(res_pipe_64.total_s, 14.71, delta=0.05)
    self.assertAlmostEqual(res_direct_64.total_s, 45.82, delta=0.05)
    self.assertAlmostEqual(res_sf_64.total_s, 35.27, delta=0.05)
    self.assertEqual(res_sf_64.relay_hops, 3)
    self.assertLess(res_pipe_64.total_s, res_direct_64.total_s)
    self.assertLess(res_pipe_64.total_s, res_sf_64.total_s)

    # N = 128: Matched Pipelined Relay (17.72 s) vs Direct (90.30 s) & S&F (48.13 s)
    sampler_128 = SamplerTopology(
        num_samplers=128,
        hosts_per_sampler=2,
        nic_ingress_bw_gbps=200.0,
        nic_egress_bw_gbps=200.0,
    )
    res_direct_128 = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler_128,
        strategy=strat_direct,
    )
    res_sf_128 = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler_128,
        strategy=strat_sf,
    )
    res_pipe_128 = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler_128,
        strategy=strat_pipe,
    )
    self.assertAlmostEqual(res_pipe_128.total_s, 17.72, delta=0.05)
    self.assertAlmostEqual(res_direct_128.total_s, 90.30, delta=0.05)
    self.assertAlmostEqual(res_sf_128.total_s, 48.13, delta=0.05)
    self.assertEqual(res_sf_128.relay_hops, 4)
    self.assertLess(res_pipe_128.total_s, res_direct_128.total_s)
    self.assertLess(res_pipe_128.total_s, res_sf_128.total_s)

  def test_all_source_binomial_tree_store_and_forward_rounds(self):
    trainer = TrainerTopology(num_hosts=32, nic_egress_bw_gbps=200.0)
    strat_sf = TransferStrategy(enable_relay_broadcast=True, pipelined=False)

    # N_seed = 16.
    # Cumulative populated samplers after R rounds: (2^R - 1) * N_seed.
    # R=1: 16
    # R=2: 48 (covers N=32, N=48)
    # R=3: 112 (covers N=64, N=112)
    # R=4: 240 (covers N=128)
    expected_hops = {
        16: 1,
        32: 2,
        48: 2,
        64: 3,
        112: 3,
        128: 4,
    }
    for n_samplers, rounds in expected_hops.items():
      sampler = SamplerTopology(
          num_samplers=n_samplers,
          hosts_per_sampler=2,
          nic_ingress_bw_gbps=200.0,
          nic_egress_bw_gbps=200.0,
      )
      res = RooflineModel.evaluate(
          model=QWEN_3_5_397B_SPEC,
          trainer=trainer,
          sampler=sampler,
          strategy=strat_sf,
      )
      self.assertEqual(
          res.relay_hops,
          rounds,
          f"Failed for n_samplers={n_samplers}: expected {rounds} rounds,"
          f" got {res.relay_hops}",
      )
      _, desc = RooflineModel.compute_h2h_wire_latency(
          trainer=trainer,
          sampler=sampler,
          strategy=strat_sf,
      )
      if n_samplers > 16:
        self.assertIn(f"Rounds={rounds}", desc)

    # Explicit check for N=48 (2 rounds, ~24.14 s) and N=64 (3 rounds, ~35.27 s)
    sampler_48 = SamplerTopology(
        num_samplers=48,
        hosts_per_sampler=2,
        nic_ingress_bw_gbps=200.0,
        nic_egress_bw_gbps=200.0,
    )
    res_48 = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler_48,
        strategy=strat_sf,
    )
    self.assertEqual(res_48.relay_hops, 2)
    self.assertAlmostEqual(res_48.total_s, 24.14, delta=0.05)

    sampler_64 = SamplerTopology(
        num_samplers=64,
        hosts_per_sampler=2,
        nic_ingress_bw_gbps=200.0,
        nic_egress_bw_gbps=200.0,
    )
    res_64 = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler_64,
        strategy=strat_sf,
    )
    self.assertEqual(res_64.relay_hops, 3)
    self.assertAlmostEqual(res_64.total_s, 35.27, delta=0.05)

  def test_invalid_topology_inputs_raise(self):
    with self.assertRaisesRegex(ValueError, "num_hosts must be > 0"):
      TrainerTopology(num_hosts=0)
    with self.assertRaisesRegex(ValueError, "num_samplers must be > 0"):
      SamplerTopology(num_samplers=-1)
    with self.assertRaisesRegex(
        ValueError, "payload_per_host_bytes must be > 0"
    ):
      SamplerTopology(payload_per_host_bytes=0.0)
    with self.assertRaisesRegex(ValueError, "num_pipeline_chunks must be > 0"):
      TransferStrategy(num_pipeline_chunks=0)

  def test_sweep_samplers(self):
    sampler_counts = (1, 2, 4, 8, 16, 32, 64)
    sweeps = RooflineModel.sweep_samplers(
        model=QWEN_3_5_397B_SPEC,
        trainer=TrainerTopology(),
        sampler_base=SamplerTopology(),
        sampler_counts=sampler_counts,
    )
    expected_strategies = {
        "direct_p2p",
        "matched_store_and_forward",
        "matched_pipelined",
    }
    self.assertEqual(set(sweeps.keys()), expected_strategies)
    for strat_key in expected_strategies:
      self.assertEqual(tuple(sweeps[strat_key].keys()), sampler_counts)
      for n in sampler_counts:
        breakdown = sweeps[strat_key][n]
        self.assertGreater(breakdown.total_s, 0.0)
        self.assertGreater(breakdown.hardware_roofline_floor_s, 0.0)

  def test_validate_inputs_error_paths(self):
    trainer = TrainerTopology()
    sampler = SamplerTopology()
    strategy = TransferStrategy()

    # num_variables < num_pipeline_chunks
    bad_model_variables = dataclasses.replace(
        QWEN_3_5_397B_SPEC, num_variables=10
    )
    with self.assertRaisesRegex(
        ValueError,
        r"num_variables \(10\) must be >= num_pipeline_chunks \(60\)",
    ):
      RooflineModel.evaluate(
          model=bad_model_variables,
          trainer=trainer,
          sampler=sampler,
          strategy=strategy,
      )

    # sampler payload_per_host_bytes > model total_bytes
    bad_sampler_payload = dataclasses.replace(
        sampler, payload_per_host_bytes=1e15
    )
    with self.assertRaisesRegex(ValueError, r"cannot exceed model total_bytes"):
      RooflineModel.evaluate(
          model=QWEN_3_5_397B_SPEC,
          trainer=trainer,
          sampler=bad_sampler_payload,
          strategy=strategy,
      )

  def test_transfer_strategy_options(self):
    trainer = TrainerTopology()
    sampler = SamplerTopology()

    # 1. cached_schedule=False (cold start control plane latency: 208.59 s)
    strat_cold = TransferStrategy(cached_schedule=False)
    res_cold = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler,
        strategy=strat_cold,
    )
    self.assertAlmostEqual(res_cold.control_plane_s, 208.59, places=2)
    self.assertEqual(res_cold.bottleneck_stage, "Control Plane Dispatch")

    # 2. verify_checksums=True (enables trainer and sampler checksum stages)
    strat_check = TransferStrategy(verify_checksums=True)
    res_check = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler,
        strategy=strat_check,
    )
    self.assertAlmostEqual(res_check.trainer_checksum_s, 5.60, places=2)
    self.assertAlmostEqual(res_check.sampler_checksum_s, 1.51, places=2)

    # 3. multi_numa_socket=False (single-NUMA NIC efficiency 0.604 vs multi-NUMA 0.85)
    strat_multi = TransferStrategy(multi_numa_socket=True)
    strat_single = TransferStrategy(multi_numa_socket=False)
    res_multi = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler,
        strategy=strat_multi,
    )
    res_single = RooflineModel.evaluate(
        model=QWEN_3_5_397B_SPEC,
        trainer=trainer,
        sampler=sampler,
        strategy=strat_single,
    )
    self.assertGreater(res_single.h2h_wire_s, res_multi.h2h_wire_s)
    # Expected single-NUMA wire time: 224.06 GB / (25 GB/s * 0.604) = ~14.838 s
    self.assertAlmostEqual(res_single.h2h_wire_s, 14.838, delta=0.05)

  def test_sharding_table_parser(self):
    sample_table = """
| **Component** | **MaxText Parameter Key** | **Shape** | **Dtype** | **Training Sharding** | **Inference Sharding** |
| --- | --- | --- | --- | --- | --- |
| **GDN Input QKVZ** *(45 layers)* | params.decoder.layers_{i}.attention.in_proj_qkvz.kernel | [4096, 20480] | bfloat16 | P('fsdp', None) | P(None, 'model') |
| **MoE Routed Gate** *(All 60 layers)* | params.decoder.layers_{i}.mlp.routed_experts.wi_0 | [512, 4096, 1024] | bfloat16 | P('expert', 'fsdp', None) | P(None, None, ('attn_dp', 'model')) |
"""
    parsed = ShardingDocParser.parse_markdown_table(
        sample_table, model_name="TestModel", num_layers=60
    )
    self.assertEqual(parsed.name, "TestModel")
    self.assertEqual(parsed.total_params, 132_623_892_480)
    self.assertEqual(parsed.total_bytes, 265_247_784_960.0)
    self.assertEqual(parsed.num_variables, 2)
    self.assertEqual(parsed.num_layers, 60)

  def test_sharding_table_parser_unsupported_dtype(self):
    sample_table = """
| **Component** | **MaxText Parameter Key** | **Shape** | **Dtype** | **Training Sharding** | **Inference Sharding** |
| --- | --- | --- | --- | --- | --- |
| **Unsupported** | params.test.weight | [128, 128] | unknown_dtype | P('fsdp', None) | P(None, 'model') |
"""
    with self.assertRaisesRegex(
        ValueError, "Unsupported dtype 'unknown_dtype'"
    ):
      ShardingDocParser.parse_markdown_table(sample_table)

  def test_sharding_table_parser_malformed_shape(self):
    sample_table = """
| **Component** | **MaxText Parameter Key** | **Shape** | **Dtype** | **Training Sharding** | **Inference Sharding** |
| --- | --- | --- | --- | --- | --- |
| **Bad Shape** | params.test.weight | [abc, 128] | bfloat16 | P('fsdp', None) | P(None, 'model') |
"""
    with self.assertRaisesRegex(ValueError, "Malformed shape"):
      ShardingDocParser.parse_markdown_table(sample_table)

  def test_sharding_table_parser_empty_table(self):
    with self.assertRaisesRegex(ValueError, "No valid tensor entries found"):
      ShardingDocParser.parse_markdown_table(
          "# Just markdown text with no table"
      )


if __name__ == "__main__":
  absltest.main()
