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

import datetime
import glob
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

_LOG_DIR = os.environ.get("TEST_TMPDIR", os.environ.get("TMPDIR", "/tmp"))
os.environ.setdefault("TPU_LOG_DIR", _LOG_DIR)
os.environ.setdefault("GLOG_log_dir", _LOG_DIR)
os.environ.setdefault("GOOGLE_LOG_DIR", _LOG_DIR)
os.environ.setdefault("TMPDIR", _LOG_DIR)

from absl import app
from absl import flags
from absl.testing import absltest
from absl.testing import parameterized
import numpy as np

import torch
import torch_tpu
import torch.distributed as dist

try:
  from google3.pyglib import resources
except ImportError:
  resources = None

from tpu_sync.api.torch import kv_cache_manager
from tpu_sync.api.torch import kv_cache_store

FLAGS = flags.FLAGS
flags.DEFINE_boolean("run_worker", False, "")
flags.DEFINE_string("worker_mode", "save_load", "")
flags.DEFINE_boolean("use_slices", False, "")
flags.DEFINE_boolean("enable_shm", False, "")
_STORAGE_ROOT = flags.DEFINE_string(
    "storage_root", "", "Path to storage directory for secondary storage"
)
_STORAGE_DIRECT_IO = flags.DEFINE_boolean(
    "storage_direct_io",
    False,
    "Whether to enable Direct I/O (O_DIRECT) in POSIX secondary storage.",
)
_STORAGE_PHASE = flags.DEFINE_string(
    "storage_phase",
    "both",
    "Phase of secondary storage test: 'write', 'read', or 'both'",
)
flags.DEFINE_integer("rank", 0, "")
flags.DEFINE_integer("world_size", 0, "")
flags.DEFINE_integer("master_port", 0, "")
flags.DEFINE_integer("controller_port", 0, "")
flags.DEFINE_integer("controller_port_b", 0, "")
flags.DEFINE_integer("controller_port_s", 0, "")
flags.DEFINE_integer("registry_port", 0, "")

_GOOGLE_PCI_VENDOR_ID = "0x1ae0"
_TOPOLOGY_BY_TPU_PCI_DEVICE_ID = {
    "0x005e": {1: "1,1,1", 2: "1,2,1", 4: "2,2,1", 8: "2,2,2"},
    "0x0062": {1: "1,1,1", 2: "1,2,1", 4: "2,2,1", 8: "2,2,2"},
    "0x0063": {1: "1,1,1", 2: "1,2,1", 4: "2,2,1", 8: "2,2,2"},
    "0x006f": {1: "1,1,1", 2: "1,2,1", 4: "2,2,1", 8: "2,4,1"},
    "0x0076": {2: "1,1,1,2", 4: "1,2,1,2", 8: "2,2,1,2"},
}


def _scan_pci_tpus():
  count = 0
  topology_map = None
  pci_devices = pathlib.Path("/sys/bus/pci/devices")
  if not pci_devices.exists():
    return 0, None
  for device_path in pci_devices.iterdir():
    try:
      vendor_id = (device_path / "vendor").read_text().strip()
      if vendor_id != _GOOGLE_PCI_VENDOR_ID:
        continue
      device_id = (device_path / "device").read_text().strip()
      if device_id in _TOPOLOGY_BY_TPU_PCI_DEVICE_ID:
        try:
          group_id = (device_path / "iommu_group").readlink().name
          (pathlib.Path("/dev/vfio") / group_id).stat()
        except OSError:
          continue
        count += 1
        if topology_map is None:
          topology_map = _TOPOLOGY_BY_TPU_PCI_DEVICE_ID[device_id]
    except OSError:
      continue
  return count, topology_map


def get_tpu_topology(world_size: int) -> str:
  _, topology_map = _scan_pci_tpus()
  if topology_map and world_size in topology_map:
    return topology_map[world_size]
  return (
      "2x4"
      if world_size == 8
      else "2x2"
      if world_size == 4
      else f"1x{world_size}"
  )


def pick_unused_ports(count: int) -> list[int]:
  ports = []
  for _ in range(count):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("localhost", 0))
    port = s.getsockname()[1]
    ports.append(port)
    s.close()
  return ports


def prepare_tpu_environment(world_size: int) -> None:
  log_dir = os.environ.get("TEST_TMPDIR", os.environ.get("TMPDIR", "/tmp"))
  os.environ["TPU_LOG_DIR"] = log_dir
  os.environ["GLOG_log_dir"] = log_dir
  os.environ["GOOGLE_LOG_DIR"] = log_dir
  os.environ["TMPDIR"] = log_dir
  os.environ["GLOG_alsologtostderr"] = "1"
  if "TORCH_TPU_XPROF_SESSION_ID" not in os.environ:
    os.environ["TORCH_TPU_XPROF_SESSION_ID"] = str(time.time_ns())
  ports = pick_unused_ports(world_size)
  os.environ["TORCH_TPU_SLICEBUILDER_ADDRESSES"] = ",".join(
      [f"localhost:{p}" for p in ports]
  )
  if "TORCH_TPU_TOPOLOGY" not in os.environ:
    os.environ["TORCH_TPU_TOPOLOGY"] = get_tpu_topology(world_size)

def worker_launch_cmd() -> list[str]:
  """The command prefix that re-enters this file as a worker rank.

  Under the build system argv[0] is an executable wrapper, so re-running it is
  all that is needed. Run straight from the source tree and argv[0] is a plain
  .py file that cannot be exec'd, so name the interpreter explicitly.
  """
  if os.access(sys.argv[0], os.X_OK):
    return [sys.argv[0]]
  return [sys.executable, os.path.abspath(__file__)]

_registry_process = None
_registry_port = None


def start_servers():
  global _registry_process
  global _registry_port
  _registry_port = pick_unused_ports(1)[0]
  if resources:
    registry_binary = resources.GetResourceFilename(
        "google3/third_party/tpu_raiden/tpu_sync/kv_cache/global_registry/global_registry_server"
    )
    extra_flags = ["--alsologtostderr"]
  else:
    this_dir = os.path.dirname(os.path.abspath(__file__))
    registry_binary = os.path.abspath(
        os.path.join(
            this_dir,
            "..",
            "..",
            "kv_cache",
            "global_registry",
            "global_registry_server",
        )
    )
    extra_flags = []

  print(f"Starting Registry on port {_registry_port}")
  reg_log = open("/tmp/raiden_registry_mpmd.log", "w")
  _registry_process = subprocess.Popen(
      [registry_binary, f"--port={_registry_port}"] + extra_flags,
      stdout=reg_log,
      stderr=subprocess.STDOUT,
  )
  time.sleep(2)


def stop_servers():
  global _registry_process
  if _registry_process:
    code = _registry_process.poll()
    if code is not None and code != 0:
      print(f"--- Registry exited with {code} ---")
      try:
        with open("/tmp/raiden_registry_mpmd.log", "r") as f:
          print(f.read())
      except OSError as e:
        print(f"Failed to read registry log: {e}")
    _registry_process.terminate()
    _registry_process.wait()
    _registry_process = None


def setUpModule():
  os.environ["RAIDEN_DISABLE_SINGLETON_WORKER"] = "1"
  os.environ["GLOG_alsologtostderr"] = "1"


def tearDownModule():
  pass


def _worker_save_load_main(argv):
  rank = FLAGS.rank
  world_size = FLAGS.world_size
  master_port = FLAGS.master_port
  controller_port = FLAGS.controller_port
  registry_port = FLAGS.registry_port

  os.environ["MASTER_ADDR"] = "localhost"
  os.environ["MASTER_PORT"] = str(master_port)
  os.environ["RANK"] = str(rank)
  os.environ["WORLD_SIZE"] = str(world_size)
  os.environ["LOCAL_RANK"] = str(rank)
  os.environ["PJRT_LOCAL_PROCESS_RANK"] = str(rank)
  os.environ["GROUP_RANK"] = "0"
  os.environ["LOCAL_WORLD_SIZE"] = str(world_size)
  os.environ["GLOG_alsologtostderr"] = "1"

  dist.init_process_group(
      backend="gloo",
      init_method=f"tcp://127.0.0.1:{master_port}",
      rank=rank,
      world_size=world_size,
  )

  try:
    device = torch.device("tpu")
    num_blocks = 4
    shape = (num_blocks, 128, 8, 8, 128)
    host_data = np.arange(np.prod(shape), dtype=np.float32).reshape(shape) + (
        rank * 1000.0
    )
    tpu_cache = torch.tensor(host_data, device=device)

    # Expected reference after loading saved blocks 0 and 1 into blocks 2 and 3: [a, b, a, b]
    expected_ref = host_data.copy()
    expected_ref[2] = host_data[0]
    expected_ref[3] = host_data[1]

    store = None
    hashes = [b"hash_mpmd_0", b"hash_mpmd_1"]

    if rank == 0:
      block_elements = 128 * 8 * 8 * 128
      shard_size_bytes = block_elements * 4

      rid = kv_cache_store.RaidenId("mpmd_e2e_job", "0", "mpmd_cache", 0)
      # Init store first on rank 0, this binds the local controller server!
      store = kv_cache_store.KVCacheStore(
          capacity=num_blocks,
          global_registry_address=f"localhost:{registry_port}",
          raiden_id=rid,
          num_shards=world_size,
          shard_size_bytes=shard_size_bytes,
          store_server_ip="127.0.0.1",
          raiden_controller_port=controller_port,
      )

      slices = [
          kv_cache_store.RaidenBlockId(
              rid,
              host_block_id=-1,
              device_block_id=0,
              status=kv_cache_store.BlockStatus.HBM,
          ),
          kv_cache_store.RaidenBlockId(
              rid,
              host_block_id=-1,
              device_block_id=1,
              status=kv_cache_store.BlockStatus.HBM,
          ),
      ]
      assert store.insert(
          hashes, slices, on_host=False
      ), "Failed to insert blocks to store"

    dist.barrier()

    # Store guarantees controller is bound; now initialize managers
    # Store guarantees controller is bound; now initialize managers in rank order
    manager = None
    for r in range(world_size):
      if rank == r:
        manager = kv_cache_manager.KVCacheManager(
            kv_caches=[[tpu_cache]],
            local_control_port=0,
            max_blocks=num_blocks,
            num_slots=2,
            unsafe_skip_buffer_lock=True,
            raiden_worker_port=0,
            raiden_controller_address=f"localhost:{controller_port}",
            worker_id=f"worker_{rank}",
            host_blocks_to_allocate=4,
            node_id=rank,
            enable_shm=FLAGS.enable_shm,
        )
      dist.barrier()

    if rank == 0:
      store.save(hashes)
      done = False
      while not done:
        save_done, save_failed, _, _, _ = store.poll_save_status()
        if save_failed:
          raise RuntimeError(f"Async Save failed: {save_failed}")
        if save_done:
          done = True
        if not done:
          time.sleep(0.01)
      # A successful save consumed the pin; nothing to release.

    if rank == 0:
      print(
          "=== [Rank 0] Loading checkpoint from Host DRAM into TPU HBM blocks"
          " [2, 3] (store.load) ==="
      )
      if FLAGS.use_slices:
        # lookup() pins the returned entries; load(..., slices=...) consumes the pin on success.
        load_slices = [entry for _, entry in store.lookup(hashes)]
        assert len(load_slices) == len(
            hashes
        ), f"expected {len(hashes)} entries, got {load_slices}"
        for entry in load_slices:
          assert (
              entry.status == kv_cache_store.BlockStatus.HOST_AND_HBM
          ), f"entry is {entry.status}, not HOST_AND_HBM"
        assert store.load(
            hashes, [2, 3], slices=load_slices
        ), "load with slices failed"
      else:
        # lookup() pins the returned entries; load() consumes the pin on success.
        assert len(store.lookup(hashes)) == len(hashes)
        assert store.load(hashes, [2, 3]), "load failed"
      done = False
      while not done:
        load_done, load_failed, _ = store.poll_load_status()
        if load_failed:
          raise RuntimeError(f"Async Load failed: {load_failed}")
        if load_done:
          done = True
        if not done:
          time.sleep(0.01)

    dist.barrier()
    try:
      torch.tpu.synchronize()
    except (AttributeError, RuntimeError):
      pass
    print(
        f"=== [Rank {rank}] Verifying TPU memory blocks [2, 3] match saved"
        " blocks [0, 1] ==="
    )
    np.testing.assert_array_equal(tpu_cache.cpu().numpy(), expected_ref)
    print(
        f"=== [Rank {rank}] SUCCESS: E2E MPMD Save/Load [0, 1] -> [2, 3]"
        " roundtrip verified on physical TPU! ==="
    )

  finally:
    dist.barrier()
    dist.destroy_process_group()


def _worker_read_remote_main(argv):
  use_slices = FLAGS.use_slices
  rank = FLAGS.rank
  world_size = FLAGS.world_size
  master_port = FLAGS.master_port
  controller_port_a = FLAGS.controller_port
  controller_port_b = FLAGS.controller_port_b
  registry_port = FLAGS.registry_port

  os.environ["MASTER_ADDR"] = "localhost"
  os.environ["MASTER_PORT"] = str(master_port)
  os.environ["RANK"] = str(rank)
  os.environ["WORLD_SIZE"] = str(world_size)
  os.environ["LOCAL_RANK"] = str(rank)
  os.environ["PJRT_LOCAL_PROCESS_RANK"] = str(rank)
  os.environ["GROUP_RANK"] = "0"
  os.environ["LOCAL_WORLD_SIZE"] = str(world_size)
  os.environ["GLOG_alsologtostderr"] = "1"

  dist.init_process_group(
      backend="gloo",
      init_method=f"tcp://127.0.0.1:{master_port}",
      rank=rank,
      world_size=world_size,
  )

  try:
    device = torch.device("tpu")
    num_blocks = 4
    shape = (num_blocks, 128, 8, 8, 128)
    host_data_a = np.arange(np.prod(shape), dtype=np.float32).reshape(shape) + (
        rank * 1000.0
    )
    tpu_cache_a = torch.tensor(host_data_a, device=device)
    tpu_cache_b = torch.zeros(shape, dtype=torch.float32, device=device)

    # Expected reference after read_remote pulling blocks 0 and 1 into blocks 0 and 1 of tpu_cache_b
    expected_ref = host_data_a.copy()

    store_a = None
    store_b = None
    hashes = [b"hash_mpmd_rr_0", b"hash_mpmd_rr_1"]

    if rank == 0:
      block_elements = 128 * 8 * 8 * 128
      shard_size_bytes = block_elements * 4

      rid_a = kv_cache_store.RaidenId(
          "mpmd_rr_job_a", "0", "mpmd_rr_cache_a", 0
      )
      store_a = kv_cache_store.KVCacheStore(
          capacity=num_blocks,
          global_registry_address=f"localhost:{registry_port}",
          raiden_id=rid_a,
          num_shards=world_size,
          shard_size_bytes=shard_size_bytes,
          store_server_ip="127.0.0.1",
          raiden_controller_port=controller_port_a,
      )

      rid_b = kv_cache_store.RaidenId(
          "mpmd_rr_job_b", "0", "mpmd_rr_cache_b", 0
      )
      store_b = kv_cache_store.KVCacheStore(
          capacity=num_blocks,
          global_registry_address=f"localhost:{registry_port}",
          raiden_id=rid_b,
          num_shards=world_size,
          shard_size_bytes=shard_size_bytes,
          store_server_ip="127.0.0.1",
          raiden_controller_port=controller_port_b,
      )

      slices_a = [
          kv_cache_store.RaidenBlockId(
              rid_a,
              host_block_id=-1,
              device_block_id=0,
              status=kv_cache_store.BlockStatus.HBM,
          ),
          kv_cache_store.RaidenBlockId(
              rid_a,
              host_block_id=-1,
              device_block_id=1,
              status=kv_cache_store.BlockStatus.HBM,
          ),
      ]
      assert store_a.insert(
          hashes, slices_a, on_host=False
      ), "Failed to insert blocks to store_a"

    dist.barrier()

    # Initialize KVCacheManager A and B across all 8 ranks in Unified Host Pool mode (host_blocks_to_allocate=4)
    manager_a = None
    for r in range(world_size):
      if rank == r:
        manager_a = kv_cache_manager.KVCacheManager(
            kv_caches=[[tpu_cache_a]],
            local_control_port=0,
            max_blocks=num_blocks,
            num_slots=2,
            unsafe_skip_buffer_lock=True,
            raiden_worker_port=0,
            raiden_controller_address=f"localhost:{controller_port_a}",
            worker_id=f"worker_a_{rank}",
            host_blocks_to_allocate=4,
            node_id=rank,
        )
      dist.barrier()

    manager_b = None
    for r in range(world_size):
      if rank == r:
        manager_b = kv_cache_manager.KVCacheManager(
            kv_caches=[[tpu_cache_b]],
            local_control_port=0,
            max_blocks=num_blocks,
            num_slots=2,
            unsafe_skip_buffer_lock=True,
            raiden_worker_port=0,
            raiden_controller_address=f"localhost:{controller_port_b}",
            worker_id=f"worker_b_{rank}",
            host_blocks_to_allocate=4,
            node_id=rank,
        )
      dist.barrier()

    if rank == 0:
      store_a.save(hashes)
      done = False
      while not done:
        save_done, save_failed, _, _, _ = store_a.poll_save_status()
        if save_failed:
          raise RuntimeError(f"Job A Async Save failed: {save_failed}")
        if len(save_done) == 2:
          done = True
        if not done:
          time.sleep(0.01)
      # A successful save consumed the pin; nothing to release.

      # Wait for global registry propagation
      deadline = time.time() + 10.0
      lookup_res_b = []
      while time.time() < deadline:
        lookup_res_b = store_b.lookup(hashes, enable_global=True)
        if len(lookup_res_b) == 2:
          break
        time.sleep(0.5)
      assert (
          len(lookup_res_b) == 2
      ), f"Expected 2 remote blocks, got {len(lookup_res_b)}"

      slices_b = [lookup_res_b[0][1], lookup_res_b[1][1]]
      if use_slices:
        print(
            "=== [Rank 0] Launching peer-fetch Load from Job A to Job B with"
            " slices ==="
        )
        assert store_b.load(
            hashes, [0, 1], slices=slices_b
        ), "load failed on store_b"
        done = False
        while not done:
          load_done, load_failed, _ = store_b.poll_load_status()
          if load_failed:
            raise RuntimeError(f"Job B Load failed: {load_failed}")
          if len(load_done) == 2:
            done = True
          if not done:
            time.sleep(0.01)
      else:
        # The read goes straight into TPU blocks [0, 1]; the slices from the
        # lookup are the source coordinate, so there is nothing to insert and
        # no second Load step afterwards.
        print("=== [Rank 0] Launching ReadRemote from Job A to Job B ===")
        assert store_b.read_remote(
            hashes, slices_b, [0, 1]
        ), "read_remote launch failed on store_b"

        done = False
        while not done:
          read_done, read_failed, _ = store_b.poll_remote_read_status()
          if read_failed:
            raise RuntimeError(f"Job B ReadRemote failed: {read_failed}")
          if len(read_done) == 2:
            done = True
          if not done:
            time.sleep(0.01)

        # The read left no local entry, so there is nothing to release here.
        assert not store_b.lookup(hashes), "read_remote must record nothing"

      if use_slices:
        # A load from a peer records nothing locally: no host copy was kept, so
        # the cache is a miss for these hashes.
        assert not store_b.lookup(
            hashes
        ), "peer load must record nothing locally"

    dist.barrier()
    try:
      torch.tpu.synchronize()
    except (AttributeError, RuntimeError):
      pass
    print(
        f"=== [Rank {rank}] Verifying TPU memory blocks [0, 1] match remote"
        " producer blocks ==="
    )
    np.testing.assert_array_equal(
        tpu_cache_b.cpu().numpy()[:2], expected_ref[:2]
    )
    print(
        f"=== [Rank {rank}] SUCCESS: E2E MPMD ReadRemote [0, 1] roundtrip"
        " verified on physical TPU! ==="
    )

  finally:
    dist.barrier()
    dist.destroy_process_group()


def _worker_write_remote_main(argv):
  rank = FLAGS.rank
  world_size = FLAGS.world_size
  master_port = FLAGS.master_port
  controller_port_a = FLAGS.controller_port
  controller_port_b = FLAGS.controller_port_b
  registry_port = FLAGS.registry_port

  os.environ["MASTER_ADDR"] = "localhost"
  os.environ["MASTER_PORT"] = str(master_port)
  os.environ["RANK"] = str(rank)
  os.environ["WORLD_SIZE"] = str(world_size)
  os.environ["LOCAL_RANK"] = str(rank)
  os.environ["PJRT_LOCAL_PROCESS_RANK"] = str(rank)
  os.environ["GROUP_RANK"] = "0"
  os.environ["LOCAL_WORLD_SIZE"] = str(world_size)
  os.environ["GLOG_alsologtostderr"] = "1"

  dist.init_process_group(
      backend="gloo",
      init_method=f"tcp://127.0.0.1:{master_port}",
      rank=rank,
      world_size=world_size,
  )

  try:
    device = torch.device("tpu")
    num_blocks = 4
    shape = (num_blocks, 128, 8, 8, 128)
    host_data_a = np.arange(np.prod(shape), dtype=np.float32).reshape(shape) + (
        rank * 1000.0
    )
    tpu_cache_a = torch.tensor(host_data_a, device=device)
    tpu_cache_b = torch.zeros(shape, dtype=torch.float32, device=device)

    expected_ref = host_data_a.copy()

    store_a = None
    store_b = None
    hashes = [b"hash_mpmd_wr_0", b"hash_mpmd_wr_1"]

    if rank == 0:
      block_elements = 128 * 8 * 8 * 128
      shard_size_bytes = block_elements * 4

      rid_a = kv_cache_store.RaidenId(
          "mpmd_wr_job_a", "0", "mpmd_wr_cache_a", 0
      )
      store_a = kv_cache_store.KVCacheStore(
          capacity=num_blocks,
          global_registry_address=f"localhost:{registry_port}",
          raiden_id=rid_a,
          num_shards=world_size,
          shard_size_bytes=shard_size_bytes,
          store_server_ip="127.0.0.1",
          raiden_controller_port=controller_port_a,
      )

      rid_b = kv_cache_store.RaidenId(
          "mpmd_wr_job_b", "0", "mpmd_wr_cache_b", 0
      )
      store_b = kv_cache_store.KVCacheStore(
          capacity=num_blocks,
          global_registry_address=f"localhost:{registry_port}",
          raiden_id=rid_b,
          num_shards=world_size,
          shard_size_bytes=shard_size_bytes,
          store_server_ip="127.0.0.1",
          raiden_controller_port=controller_port_b,
      )

      slices_a = [
          kv_cache_store.RaidenBlockId(
              rid_a,
              host_block_id=-1,
              device_block_id=0,
              status=kv_cache_store.BlockStatus.HBM,
          ),
          kv_cache_store.RaidenBlockId(
              rid_a,
              host_block_id=-1,
              device_block_id=1,
              status=kv_cache_store.BlockStatus.HBM,
          ),
      ]
      assert store_a.insert(
          hashes, slices_a, on_host=False
      ), "Failed to insert blocks to store_a"

    dist.barrier()

    # Initialize KVCacheManager A and B across all 8 ranks in Unified Host Pool mode
    manager_a = None
    for r in range(world_size):
      if rank == r:
        manager_a = kv_cache_manager.KVCacheManager(
            kv_caches=[[tpu_cache_a]],
            local_control_port=0,
            max_blocks=num_blocks,
            num_slots=2,
            unsafe_skip_buffer_lock=True,
            raiden_worker_port=0,
            raiden_controller_address=f"localhost:{controller_port_a}",
            worker_id=f"worker_a_{rank}",
            host_blocks_to_allocate=4,
            node_id=rank,
        )
      dist.barrier()

    manager_b = None
    for r in range(world_size):
      if rank == r:
        manager_b = kv_cache_manager.KVCacheManager(
            kv_caches=[[tpu_cache_b]],
            local_control_port=0,
            max_blocks=num_blocks,
            num_slots=2,
            unsafe_skip_buffer_lock=True,
            raiden_worker_port=0,
            raiden_controller_address=f"localhost:{controller_port_b}",
            worker_id=f"worker_b_{rank}",
            host_blocks_to_allocate=4,
            node_id=rank,
        )
      dist.barrier()

    if rank == 0:
      store_a.save(hashes)
      deadline = time.time() + 120
      done = False
      while time.time() < deadline:
        save_done, save_failed, _, _, _ = store_a.poll_save_status()
        if save_failed:
          raise RuntimeError(f"Job A Async Save failed: {save_failed}")
        if len(save_done) == 2:
          done = True
          break
        time.sleep(0.01)
      assert done, "Job A Async Save timed out"

      print("=== [Rank 0] Launching WriteRemote from Job A to Job B ===")
      # The local save above consumed the pin, so the offer needs its own.
      # lookup() answers "host-resident here" AND grants the pin that
      # save(dst) spends -- the documented remote-save flow.
      assert len(store_a.lookup(hashes)) == len(hashes), "hashes not resident"
      assert store_a.save(hashes, rid_b), "remote save launch failed on store_a"

      deadline = time.time() + 120
      done = False
      while time.time() < deadline:
        wr_done, wr_failed, wr_pending, _, _ = store_a.poll_save_status()
        if wr_failed:
          raise RuntimeError(f"Job A WriteRemote failed: {wr_failed}")
        if len(wr_done) == 2:
          done = True
          break
        time.sleep(0.01)
      assert done, "Job A WriteRemote timed out"
      # A successful save consumed the pin; nothing to release.

      # Destination holds blocks locally on host DRAM. lookup() pins the landed entries.
      lookup_res_b = store_b.lookup(hashes, enable_global=False)
      assert (
          len(lookup_res_b) == 2
      ), f"Expected 2 blocks on store_b, got {len(lookup_res_b)}"

      # Load blocks [0, 1] from Job B's host pool into TPU HBM (consumes the pin)
      assert store_b.load(hashes, [0, 1]), "load failed on store_b"
      deadline = time.time() + 120
      done = False
      while time.time() < deadline:
        load_done, load_failed, _ = store_b.poll_load_status()
        if load_failed:
          raise RuntimeError(f"Job B Load failed: {load_failed}")
        if len(load_done) == 2:
          done = True
          break
        time.sleep(0.01)
      assert done, "Job B Load timed out"

    dist.barrier()
    try:
      torch.tpu.synchronize()
    except (AttributeError, RuntimeError):
      pass
    print(
        f"=== [Rank {rank}] Verifying TPU memory blocks [0, 1] match offered"
        " producer blocks ==="
    )
    np.testing.assert_array_equal(
        tpu_cache_b.cpu().numpy()[:2], expected_ref[:2]
    )
    print(
        f"=== [Rank {rank}] SUCCESS: E2E MPMD WriteRemote [0, 1] roundtrip"
        " verified on physical TPU! ==="
    )

  finally:
    dist.barrier()
    dist.destroy_process_group()


def _worker_secondary_storage_main(argv):
  rank = FLAGS.rank
  world_size = FLAGS.world_size
  master_port = FLAGS.master_port
  controller_port = FLAGS.controller_port
  storage_root = _STORAGE_ROOT.value
  phase = _STORAGE_PHASE.value

  os.environ["MASTER_ADDR"] = "localhost"
  os.environ["MASTER_PORT"] = str(master_port)
  os.environ["RANK"] = str(rank)
  os.environ["WORLD_SIZE"] = str(world_size)
  os.environ["LOCAL_RANK"] = str(rank)
  os.environ["PJRT_LOCAL_PROCESS_RANK"] = str(rank)
  os.environ["GROUP_RANK"] = "0"
  os.environ["LOCAL_WORLD_SIZE"] = str(world_size)
  os.environ["GLOG_alsologtostderr"] = "1"

  dist.init_process_group(
      backend="gloo",
      init_method=f"tcp://127.0.0.1:{master_port}",
      rank=rank,
      world_size=world_size,
  )
  print(
      f"[MPMD Storage][Rank {rank}][Phase={phase}] Process initialized"
      f" (PID={os.getpid()}, master_port={master_port}). Gloo process group"
      " ready.",
      flush=True,
  )

  try:
    cfg = kv_cache_store._impl.BackendConfig()
    cfg.type = "posix"
    cfg.parallelism.tp_rank = rank
    cfg.parallelism.tp_size = world_size
    cfg.set_property("root_dir", storage_root)
    cfg.set_property("model_name", "test_model_mpmd")
    if _STORAGE_DIRECT_IO.value:
      cfg.set_property("direct_io", "true")
      print(
          f"[MPMD Storage][Rank {rank}] Enabled direct_io in BackendConfig.",
          flush=True,
      )

    device = torch.device("tpu")
    num_blocks = 4
    # Shape: (num_blocks, tokens_per_block, head_shards, heads_per_shard, head_dim)
    # (4 blocks, 128 tokens/block, 8 head shards, 8 heads/shard, head_dim 128).
    shape = (num_blocks, 128, 8, 8, 128)
    host_data = np.arange(np.prod(shape), dtype=np.float32).reshape(shape) + (
        rank * 1000.0
    )
    hashes = [b"hash_mpmd_sec_0", b"hash_mpmd_sec_1"]
    block_elements = 128 * 8 * 8 * 128
    shard_size_bytes = block_elements * 4

    # =========================================================================
    # Write Phase
    # =========================================================================
    if phase in ("write", "both"):
      print(
          f"[MPMD Storage][Step 1/11][Write Phase][Rank {rank}] Initializing"
          " backend config and TPU cache buffer.",
          flush=True,
      )
      tpu_cache = torch.tensor(host_data, device=device)
      try:
        torch.tpu.synchronize()
      except (AttributeError, RuntimeError):
        pass

      print(
          f"[MPMD Storage][Step 2/11][Write Phase][Rank {rank}] Initializing"
          " store and manager, inserting initial HBM blocks hashes to"
          " device_block_id=[0, 1], status=HBM.",
          flush=True,
      )
      rid1 = kv_cache_store.RaidenId(
          "mpmd_sec_job_writer", "0", "mpmd_cache_writer", 0
      )
      # Worker Discovery & Backend Registration:
      # 1. KVCacheStore's RaidenController listens for gRPC RegisterWorker calls on controller_port.
      # 2. Each worker KVCacheManager connects to the controller and registers its worker endpoint.
      # 3. Both store and manager initialize secondary backends locally from BackendConfig.
      store = None
      if rank == 0:
        store = kv_cache_store.KVCacheStore(
            capacity=num_blocks,
            raiden_id=rid1,
            num_shards=world_size,
            shard_size_bytes=shard_size_bytes,
            store_server_ip="127.0.0.1",
            raiden_controller_port=controller_port,
            secondary_backend_configs=[cfg],
        )
        slices = [
            kv_cache_store.RaidenBlockId(
                rid1,
                host_block_id=-1,
                device_block_id=0,
                status=kv_cache_store.BlockStatus.HBM,
            ),
            kv_cache_store.RaidenBlockId(
                rid1,
                host_block_id=-1,
                device_block_id=1,
                status=kv_cache_store.BlockStatus.HBM,
            ),
        ]
        assert store.insert(
            hashes, slices, on_host=False
        ), "Failed to insert blocks to store on rank 0"

      dist.barrier()

      manager = None
      for r in range(world_size):
        if rank == r:
          manager = kv_cache_manager.KVCacheManager(
              kv_caches=[[tpu_cache]],
              local_control_port=0,
              max_blocks=num_blocks,
              num_slots=2,
              unsafe_skip_buffer_lock=True,
              raiden_worker_port=0,
              raiden_controller_address=f"localhost:{controller_port}",
              worker_id=f"worker_{rank}",
              host_blocks_to_allocate=4,
              node_id=rank,
              backend_configs=[cfg],
          )
        dist.barrier()

      if rank == 0:
        pre_lookup = store.lookup(hashes, pin_found=False)
        assert len(pre_lookup) == len(
            hashes
        ), f"Expected {len(hashes)} blocks, got {len(pre_lookup)}"
        for h, b in pre_lookup:
          assert (
              b.status == kv_cache_store.BlockStatus.HBM
          ), f"Expected HBM, got {b.status.name}"
        print(
            "[MPMD Storage][Step 3/11][Write Phase][Rank 0] Pre-save lookup:"
            f" verified status=HBM for all {len(hashes)} blocks.",
            flush=True,
        )

      dist.barrier()

      if rank == 0:
        print(
            "[MPMD Storage][Step 4/11][Write Phase][Rank 0] Triggering"
            f" offload (store.save) for {hashes}...",
            flush=True,
        )
        save_start = time.time()
        assert store.save(hashes), "store.save failed on rank 0"
        done = False
        while not done:
          save_done, save_failed, _, _, _ = store.poll_save_status()
          if save_failed:
            raise RuntimeError(f"Async Save failed: {save_failed}")
          if save_done:
            done = True
          if not done:
            time.sleep(0.01)
        save_duration = time.time() - save_start
        print(
            "[MPMD Storage][Step 4/11][Write Phase][Rank 0] Offload completed"
            f" in {save_duration:.3f}s. Blocks confirmed: {save_done}.",
            flush=True,
        )

      dist.barrier()

      if rank == 0:
        post_lookup = store.lookup(hashes, pin_found=False)
        assert len(post_lookup) == len(hashes)
        for h, b in post_lookup:
          assert (
              b.status == kv_cache_store.BlockStatus.HOST_AND_HBM
          ), f"Expected HOST_AND_HBM, got {b.status.name}"
        print(
            "[MPMD Storage][Step 5/11][Write Phase][Rank 0] Post-save lookup:"
            " verified status=HOST_AND_HBM in tier 0 for all blocks.",
            flush=True,
        )

      dist.barrier()

      # Expected per-rank shard path:
      #   {storage_root}/test_model_mpmd/tp{world_size}_r{rank}/{hash[:3]}/{hash[3:5]}/{hash}.bin
      # Each rank discovers only its rank-local shard file matching its TP rank.
      bin_files = glob.glob(
          os.path.join(
              storage_root,
              "test_model_mpmd",
              f"tp{world_size}_r{rank}",
              "**",
              "*.bin",
          ),
          recursive=True,
      )
      print(
          f"[MPMD Storage][Step 6/11][Write Phase][Rank {rank}] Discovered"
          f" {len(bin_files)} on-disk shard files:"
          f" {[os.path.basename(f) for f in bin_files]} (paths: {bin_files})",
          flush=True,
      )
      assert len(bin_files) == len(hashes), (
          f"Rank {rank}: expected {len(hashes)} disk files, found"
          f" {len(bin_files)}: {bin_files}"
      )
      file_by_name = {os.path.basename(f): f for f in bin_files}
      for i, h in enumerate(hashes):
        expected_filename = f"{h.hex()}.bin"
        assert (
            expected_filename in file_by_name
        ), f"Rank {rank}: missing file {expected_filename} in {file_by_name}"
        fpath = file_by_name[expected_filename]
        fsize = os.path.getsize(fpath)
        assert fsize == shard_size_bytes, (
            f"Rank {rank}: file {expected_filename} size {fsize} != expected"
            f" {shard_size_bytes}"
        )
        with open(fpath, "rb") as f:
          disk_bytes = f.read()
        disk_block_data = np.frombuffer(disk_bytes, dtype=np.float32).reshape(
            shape[1:]
        )
        np.testing.assert_array_equal(disk_block_data, host_data[i])
        print(
            f"  [Rank {rank} Verified File] {expected_filename} ({fsize} B):"
            f" bit-for-bit matched host_data[{i}]",
            flush=True,
        )

      print(
          f"[MPMD Storage][Step 6/11][Write Phase][Rank {rank}] Bit-for-bit"
          f" disk files verified in tp{world_size}_r{rank} ({len(bin_files)}"
          " files).",
          flush=True,
      )

      dist.barrier()

      print(
          f"[MPMD Storage][Step 7/11][Write Phase][Rank {rank}] Erasing TPU HBM"
          " memory and tearing down Instance 1...",
          flush=True,
      )
      tpu_cache.zero_()
      try:
        torch.tpu.synchronize()
      except (AttributeError, RuntimeError):
        pass
      del manager, store

      dist.barrier()

      if phase == "write":
        print(
            f"[MPMD Storage][Step 7/11][Write Phase][Rank {rank}] TPU memory"
            " zeroed; Instance 1 torn down. Exiting write phase.",
            flush=True,
        )
        return

    # =========================================================================
    # Read Phase
    # =========================================================================
    if phase in ("read", "both"):
      tpu_cache = torch.zeros(shape, dtype=torch.float32, device=device)
      try:
        torch.tpu.synchronize()
      except (AttributeError, RuntimeError):
        pass

      expected_ref = np.zeros_like(host_data)
      expected_ref[2] = host_data[0]
      expected_ref[3] = host_data[1]

      print(
          f"[MPMD Storage][Step 8/11][Read Phase][Rank {rank}] Spinning up cold"
          " Instance 2 (Reader) with empty DRAM cache.",
          flush=True,
      )
      rid2 = kv_cache_store.RaidenId(
          "mpmd_sec_job_reader", "0", "mpmd_cache_reader", 0
      )
      # Worker Discovery & Backend Registration:
      # 1. KVCacheStore's RaidenController listens for gRPC RegisterWorker calls on controller_port.
      # 2. Each worker KVCacheManager connects to the controller and registers its worker endpoint.
      # 3. Both store and manager initialize secondary backends locally from BackendConfig.
      store = None
      if rank == 0:
        store = kv_cache_store.KVCacheStore(
            capacity=num_blocks,
            raiden_id=rid2,
            num_shards=world_size,
            shard_size_bytes=shard_size_bytes,
            store_server_ip="127.0.0.1",
            raiden_controller_port=controller_port,
            secondary_backend_configs=[cfg],
        )

      dist.barrier()

      manager = None
      for r in range(world_size):
        if rank == r:
          manager = kv_cache_manager.KVCacheManager(
              kv_caches=[[tpu_cache]],
              local_control_port=0,
              max_blocks=num_blocks,
              num_slots=2,
              unsafe_skip_buffer_lock=True,
              raiden_worker_port=0,
              raiden_controller_address=f"localhost:{controller_port}",
              worker_id=f"worker_{rank}",
              host_blocks_to_allocate=4,
              node_id=rank,
              backend_configs=[cfg],
          )
        dist.barrier()

      storage_slices = None
      if rank == 0:
        print(
            "[MPMD Storage][Step 9/11][Read Phase][Rank 0] Performing cold"
            " lookup to verify SHARED_STORAGE discovery...",
            flush=True,
        )
        storage_lookup = store.lookup(hashes, pin_found=False)
        assert len(storage_lookup) == len(hashes), (
            f"Expected {len(hashes)} blocks from cold lookup, got"
            f" {len(storage_lookup)}"
        )
        for h, b in storage_lookup:
          assert (
              b.status == kv_cache_store.BlockStatus.SHARED_STORAGE
          ), f"Expected SHARED_STORAGE, got {b.status.name}"
          print(
              f"  [Rank 0 Cold Lookup] hash={h!r} status={b.status.name}"
              f" data_name={b.raiden_id.data_name}",
              flush=True,
          )
        storage_slices = [s for _, s in storage_lookup]
        print(
            "[MPMD Storage][Step 9/11][Read Phase][Rank 0] Cold lookup"
            " verified: discovered blocks with status=SHARED_STORAGE from"
            " storage tier.",
            flush=True,
        )

      dist.barrier()

      if rank == 0:
        print(
            f"[MPMD Storage][Step 10/11][Read Phase][Rank 0] Triggering cold"
            f" recall (store.read_remote) into device_block_ids=[2, 3]...",
            flush=True,
        )
        load_start = time.time()
        assert store.read_remote(
            hashes, storage_slices, [2, 3]
        ), "read_remote failed on rank 0"
        done = False
        while not done:
          load_done, load_failed, _ = store.poll_load_status()
          if load_failed:
            raise RuntimeError(f"Async Load failed: {load_failed}")
          if load_done:
            done = True
          if not done:
            time.sleep(0.01)
        load_duration = time.time() - load_start
        print(
            "[MPMD Storage][Step 10/11][Read Phase][Rank 0] Async Load"
            f" completed across all ranks in {load_duration:.3f}s.",
            flush=True,
        )

      dist.barrier()

      try:
        torch.tpu.synchronize()
      except (AttributeError, RuntimeError):
        pass

      print(
          f"[MPMD Storage][Step 10/11][Read Phase][Rank {rank}] Verifying"
          " restored TPU memory blocks [2, 3] match reference bit-for-bit...",
          flush=True,
      )
      tpu_np = tpu_cache.cpu().numpy()
      np.testing.assert_array_equal(tpu_np, expected_ref)
      print(
          f"[MPMD Storage][Step 10/11][Read Phase][Rank {rank}] SUCCESS:"
          f" Bit-for-bit match verified on physical TPU rank {rank}! (blocks"
          " [0,1]=zeros, blocks [2,3]=restored)",
          flush=True,
      )

      dist.barrier()

      if rank == 0:
        repopulated = store.lookup(hashes, pin_found=False)
        assert len(repopulated) == len(hashes)
        for h, b in repopulated:
          assert (
              b.status == kv_cache_store.BlockStatus.HOST_AND_HBM
          ), f"Expected HOST_AND_HBM, got {b.status.name}"
          assert b.device_block_id in [
              2,
              3,
          ], f"Expected device_block_id in [2, 3], got {b.device_block_id}"
          assert (
              b.host_block_id >= 0
          ), f"Expected host_block_id >= 0, got {b.host_block_id}"
          print(
              f"  [Rank 0 Post-Recall Store Status] hash={h!r}"
              f" device_block_id={b.device_block_id}"
              f" host_block_id={b.host_block_id} status={b.status.name}",
              flush=True,
          )
        print(
            "[MPMD Storage][Step 11/11][Read Phase][Rank 0] Post-recall lookup"
            " verified: status=HOST_AND_HBM (device_blocks=[2,3], host_blocks"
            " confirmed >= 0; HBM and host RAM updated).",
            flush=True,
        )

      del manager, store
      dist.barrier()

  finally:
    dist.barrier()
    print(
        f"[MPMD Storage][Rank {rank}][Cleanup] Destroying Gloo process group"
        " and exiting.",
        flush=True,
    )
    dist.destroy_process_group()


# -----------------------------------------------------------------------------
# Helpers for the three-source worker.
#
# poll_save_status() / poll_load_status() DRAIN their results: each block hash
# is reported exactly once, in whichever poll observes it. load() and the
# peer and storage groups of read_remote() complete independently through the
# same tracker, so completions are accumulated across polls.
# -----------------------------------------------------------------------------
_THREE_SOURCE_WAIT_TIMEOUT_S = 120.0
_THREE_SOURCE_BARRIER_TIMEOUT = datetime.timedelta(minutes=5)
_THREE_SOURCE_WORKER_TIMEOUT_S = 600


def _log(tag, phase, rank, msg):
  print(f"[{tag}][Phase {phase}][Rank {rank}] {msg}", flush=True)


def _tpu_sync():
  try:
    torch.tpu.synchronize()
  except (AttributeError, RuntimeError):
    pass


def _wait_for_workers(procs, timeout_s=_THREE_SOURCE_WORKER_TIMEOUT_S):
  """Waits for worker subprocesses; kills all of them on timeout.

  Returns:
    A list of (rank, returncode) for workers that did not exit cleanly.
  """
  deadline = time.time() + timeout_s
  failures = []
  for rank, p in enumerate(procs):
    try:
      p.wait(timeout=max(0.0, deadline - time.time()))
    except subprocess.TimeoutExpired:
      for q in procs:
        if q.poll() is None:
          q.kill()
      for q in procs:
        q.wait()
      return [(r, "timeout") for r in range(len(procs))]
    if p.returncode != 0:
      failures.append((rank, p.returncode))
  return failures


def _wait_for_all(poll_fn, expected_hashes, what,
                  timeout_s=_THREE_SOURCE_WAIT_TIMEOUT_S):
  """Blocks until every hash in expected_hashes is reported done by poll_fn.

  Args:
    poll_fn: store.poll_save_status or store.poll_load_status. Returns a tuple
      whose first two entries are (done, failed); results are drained.
    expected_hashes: the exact set of block hashes that must complete.
    what: label used in error messages.
    timeout_s: fails with the missing hashes after this many seconds.

  Returns:
    Seconds elapsed until all hashes completed.
  """
  expected = set(expected_hashes)
  completed = set()
  start = time.time()
  while True:
    done, failed = poll_fn()[:2]
    if failed:
      raise RuntimeError(f"{what} failed for {failed}")
    completed.update(done)
    if completed == expected:
      return time.time() - start
    if time.time() - start > timeout_s:
      raise TimeoutError(
          f"{what} incomplete after {timeout_s}s:"
          f" missing={sorted(expected - completed)}"
      )
    time.sleep(0.01)


def _assert_statuses(lookup_result, hashes, expected_statuses):
  """Asserts lookup_result is exactly hashes with expected_statuses."""
  got_hashes = [h for h, _ in lookup_result]
  got_statuses = [s.status for _, s in lookup_result]
  assert got_hashes == list(hashes), f"lookup hashes {got_hashes} != {hashes}"
  assert got_statuses == list(expected_statuses), (
      f"lookup statuses {got_statuses} != {list(expected_statuses)}"
  )


def _wait_for_lookup(store, hashes, expected_statuses,
                     timeout_s=_THREE_SOURCE_WAIT_TIMEOUT_S, **lookup_kwargs):
  """Polls store.lookup() until it returns exactly expected_statuses.

  Used where visibility is eventually consistent (global registry publication),
  replacing fixed sleeps. lookup_kwargs must not pin (pin_found=False), since
  the lookup may be repeated.
  """
  start = time.time()
  while True:
    result = store.lookup(hashes, **lookup_kwargs)
    try:
      _assert_statuses(result, hashes, expected_statuses)
      return result
    except AssertionError:
      if time.time() - start > timeout_s:
        raise
    time.sleep(0.1)


def _verify_and_print_shard_files(tag, phase, storage_root, model_name,
                                  world_size, rank, expected_count):
  bin_files = sorted(
      glob.glob(
          os.path.join(
              storage_root,
              model_name,
              f"tp{world_size}_r{rank}",
              "**",
              "*.bin",
          ),
          recursive=True,
      )
  )
  assert len(bin_files) == expected_count, (
      f"Rank {rank}: expected {expected_count} shard files, got"
      f" {len(bin_files)}: {bin_files}"
  )
  _log(tag, phase, rank,
       f"{len(bin_files)} on-disk shard files (exact count verified):")
  for f in bin_files:
    print(f"  [Shard File][Rank {rank}] {f}"
          f" ({os.path.getsize(f)} bytes)", flush=True)


def _init_worker_process_group(tag, rank, world_size, master_port, phase):
  os.environ["MASTER_ADDR"] = "localhost"
  os.environ["MASTER_PORT"] = str(master_port)
  os.environ["RANK"] = str(rank)
  os.environ["WORLD_SIZE"] = str(world_size)
  os.environ["LOCAL_RANK"] = str(rank)
  os.environ["PJRT_LOCAL_PROCESS_RANK"] = str(rank)
  os.environ["GROUP_RANK"] = "0"
  os.environ["LOCAL_WORLD_SIZE"] = str(world_size)
  os.environ["GLOG_alsologtostderr"] = "1"
  # A bounded barrier timeout turns a stuck rank into a fast, attributable
  # failure instead of a silent hang until the Forge test timeout.
  dist.init_process_group(
      backend="gloo",
      init_method=f"tcp://127.0.0.1:{master_port}",
      rank=rank,
      world_size=world_size,
      timeout=_THREE_SOURCE_BARRIER_TIMEOUT,
  )
  print(
      f"[{tag}][Rank {rank}][storage_phase={phase}] Process group ready"
      f" (PID={os.getpid()}, master_port={master_port}).",
      flush=True,
  )


def _create_managers(rank, world_size, **manager_kwargs):
  """Creates one KVCacheManager per rank, one rank at a time."""
  manager = None
  for r in range(world_size):
    if rank == r:
      manager = kv_cache_manager.KVCacheManager(
          local_control_port=0,
          num_slots=2,
          unsafe_skip_buffer_lock=True,
          raiden_worker_port=0,
          host_blocks_to_allocate=4,
          node_id=rank,
          **manager_kwargs,
      )
    dist.barrier()
  return manager


def _hbm_slices(raiden_id, num_blocks):
  return [
      kv_cache_store.RaidenBlockId(
          raiden_id,
          host_block_id=-1,
          device_block_id=i,
          status=kv_cache_store.BlockStatus.HBM,
      )
      for i in range(num_blocks)
  ]


def _worker_three_source_main(argv):
  """4-rank MPMD [HOST, REMOTE, SHARED_STORAGE] via load() + read_remote().

  Mirrors the vLLM connector: one lookup() resolves three sources, and the
  caller issues load() for the local block and ONE read_remote() for the peer
  and storage blocks together. All three complete through poll_load_status().

  Blocks: 3src_h0 -> HOST (consumer B host RAM, pinned by lookup),
          3src_r0 -> REMOTE (peer A host RAM, via global registry),
          3src_s0 -> SHARED_STORAGE.
    1. Seed storage:  writer saves 3src_s0 to POSIX storage.
    2. Stage remote:  peer A saves 3src_r0 to its host RAM (published).
    3. Stage local:   consumer B saves 3src_h0 (host RAM + storage).
    4. Lookup:        B sees exactly [HOST_AND_HBM, REMOTE(A), SHARED_STORAGE].
    5. Load:          load([h0]) -> HBM 1, read_remote([r0, s0]) ->
                      HBM [2, 3]; all done.
    6. Verify:        HBM 1..3 bit-exact on every rank; s0 now HOST_AND_HBM in
                      B's host cache (published by the recall), r0 not local.
  Rank 0 drives each action; every phase ends with one dist.barrier().
  """
  del argv
  tag = "MPMD 3-SOURCE LOAD"
  rank = FLAGS.rank
  world_size = FLAGS.world_size
  controller_port_a = FLAGS.controller_port
  controller_port_b = FLAGS.controller_port_b
  controller_port_s = FLAGS.controller_port_s
  registry_port = FLAGS.registry_port
  storage_root = _STORAGE_ROOT.value
  phase = _STORAGE_PHASE.value
  model_name = "test_model_mpmd_3src"
  status = kv_cache_store.BlockStatus

  _init_worker_process_group(tag, rank, world_size, FLAGS.master_port, phase)
  try:
    cfg = kv_cache_store._impl.BackendConfig()
    cfg.type = "posix"
    cfg.parallelism.tp_rank = rank
    cfg.parallelism.tp_size = world_size
    cfg.set_property("root_dir", storage_root)
    cfg.set_property("model_name", model_name)
    if _STORAGE_DIRECT_IO.value:
      cfg.set_property("direct_io", "true")

    device = torch.device("tpu")
    num_blocks = 4
    # Shape: (4 blocks, 128 tokens/block, 8 head shards, 8 heads/shard,
    # head_dim 128).
    shape = (num_blocks, 128, 8, 8, 128)
    host_data = np.arange(np.prod(shape), dtype=np.float32).reshape(shape) + (
        rank * 1000.0
    )
    shard_size_bytes = 128 * 8 * 8 * 128 * 4
    h0, r0, s0 = b"hash_mpmd_3src_h0", b"hash_mpmd_3src_r0", b"hash_mpmd_3src_s0"

    if phase in ("write", "both"):
      # ---- Phase 1/6: seed storage with s0 (data = host_data[2]). ----
      tpu_cache_s = torch.tensor(host_data[2:3], device=device)
      _tpu_sync()
      rid_s = kv_cache_store.RaidenId(
          "mpmd_3src_job_writer", "0", "mpmd_cache_writer", 0
      )
      store_s = None
      if rank == 0:
        store_s = kv_cache_store.KVCacheStore(
            capacity=1,
            raiden_id=rid_s,
            num_shards=world_size,
            shard_size_bytes=shard_size_bytes,
            store_server_ip="127.0.0.1",
            raiden_controller_port=controller_port_s,
            secondary_backend_configs=[cfg],
        )
        assert store_s.insert(
            [s0], _hbm_slices(rid_s, 1), on_host=False
        ), "writer insert failed"
      dist.barrier()
      manager_s = _create_managers(
          rank,
          world_size,
          kv_caches=[[tpu_cache_s]],
          max_blocks=1,
          raiden_controller_address=f"localhost:{controller_port_s}",
          worker_id=f"worker_s_{rank}",
          backend_configs=[cfg],
      )
      if rank == 0:
        _log(tag, "1/6", rank, f"Saving {s0!r} -> SHARED_STORAGE (POSIX).")
        assert store_s.save([s0]), "writer save failed"
        secs = _wait_for_all(store_s.poll_save_status, [s0], "storage save")
        _log(tag, "1/6", rank, f"{s0!r} saved in {secs:.3f}s.")
      dist.barrier()
      _verify_and_print_shard_files(tag, "1/6", storage_root, model_name,
                                    world_size, rank, 1)
      del manager_s, store_s, tpu_cache_s
      dist.barrier()
      if phase == "write":
        return

    if phase in ("read", "both"):
      # Peer A's HBM block 0 holds r0's data (host_data[1]). Consumer B's HBM
      # block 0 holds h0's data (host_data[0]); blocks 1-3 are zero and are the
      # targets of the three per-source calls.
      tpu_cache_a = torch.tensor(host_data[1:2], device=device)
      init_b = np.zeros(shape, dtype=np.float32)
      init_b[0] = host_data[0]
      tpu_cache_b = torch.tensor(init_b, device=device)
      _tpu_sync()
      rid_a = kv_cache_store.RaidenId(
          "mpmd_3src_job_peer_a", "0", "mpmd_cache_peer_a", 0
      )
      rid_b = kv_cache_store.RaidenId(
          "mpmd_3src_job_consumer_b", "0", "mpmd_cache_consumer_b", 0
      )
      store_a = None
      store_b = None
      if rank == 0:
        store_a = kv_cache_store.KVCacheStore(
            capacity=1,
            global_registry_address=f"localhost:{registry_port}",
            raiden_id=rid_a,
            num_shards=world_size,
            shard_size_bytes=shard_size_bytes,
            store_server_ip="127.0.0.1",
            raiden_controller_port=controller_port_a,
        )
        store_b = kv_cache_store.KVCacheStore(
            capacity=num_blocks,
            global_registry_address=f"localhost:{registry_port}",
            raiden_id=rid_b,
            num_shards=world_size,
            shard_size_bytes=shard_size_bytes,
            store_server_ip="127.0.0.1",
            raiden_controller_port=controller_port_b,
            secondary_backend_configs=[cfg],
        )
        assert store_a.insert(
            [r0], _hbm_slices(rid_a, 1), on_host=False
        ), "peer A insert failed"
        assert store_b.insert(
            [h0], _hbm_slices(rid_b, 1), on_host=False
        ), "consumer B insert failed"
      dist.barrier()
      manager_a = _create_managers(
          rank,
          world_size,
          kv_caches=[[tpu_cache_a]],
          max_blocks=1,
          raiden_controller_address=f"localhost:{controller_port_a}",
          worker_id=f"worker_a_{rank}",
      )
      manager_b = _create_managers(
          rank,
          world_size,
          kv_caches=[[tpu_cache_b]],
          max_blocks=num_blocks,
          raiden_controller_address=f"localhost:{controller_port_b}",
          worker_id=f"worker_b_{rank}",
          backend_configs=[cfg],
      )

      # ---- Phase 2/6: peer A stages r0 in its host RAM. ----
      if rank == 0:
        _log(tag, "2/6", rank,
             f"Peer A saving {r0!r} -> HOST (published to global registry).")
        assert store_a.save([r0]), "peer A save failed"
        _wait_for_all(store_a.poll_save_status, [r0], "peer A save")
      dist.barrier()

      # ---- Phase 3/6: consumer B saves h0. B has a secondary backend, so the
      # save writes h0 to B's host RAM and to POSIX storage; lookup still
      # reports HOST_AND_HBM because the host tier is checked first. ----
      if rank == 0:
        _log(tag, "3/6", rank,
             f"Consumer B saving {h0!r} -> HOST (local) + SHARED_STORAGE.")
        assert store_b.save([h0]), "consumer B save failed"
        _wait_for_all(store_b.poll_save_status, [h0], "consumer B save")
      dist.barrier()

      if rank == 0:
        # ---- Phase 4/6: lookup sees exactly [HOST_AND_HBM, REMOTE, STORAGE].
        hashes = [h0, r0, s0]
        expected = [status.HOST_AND_HBM, status.REMOTE, status.SHARED_STORAGE]
        # Wait (unpinned) for registry visibility, then take the pin once.
        _wait_for_lookup(store_b, hashes, expected,
                         enable_global=True, pin_found=False)
        lookup = store_b.lookup(hashes, enable_global=True, pin_found=True)
        _assert_statuses(lookup, hashes, expected)
        assert lookup[1][1].raiden_id == rid_a, (
            f"r0 owner {lookup[1][1].raiden_id} != peer A"
        )
        for h, b in lookup:
          print(f"  [B Lookup] hash={h!r} status={b.status.name}"
                f" raiden_id={b.raiden_id}", flush=True)
        slice_of = {h: b for h, b in lookup}
        _log(tag, "4/6", rank,
             "Lookup: [HOST_AND_HBM, REMOTE(peer A), SHARED_STORAGE] resolved"
             " in one call.")

        # ---- Phase 5/6: load() local, one read_remote() for the rest. ----
        assert store_b.load([h0], [1], slices=[slice_of[h0]]), "load failed"
        _log(tag, "5/6", rank,
             f"load([{h0!r}]) -> HBM 1 launched (local host DRAM, consumes"
             " lookup pin).")
        assert store_b.read_remote(
            [r0, s0], [slice_of[r0], slice_of[s0]], [2, 3]
        ), "read_remote failed"
        _log(tag, "5/6", rank,
             f"read_remote([{r0!r}, {s0!r}]) -> HBM [2, 3] launched (peer A"
             " DRAM + secondary storage, no pin).")
        secs = _wait_for_all(store_b.poll_load_status, hashes,
                             "three-source load")
        _log(tag, "5/6", rank,
             f"poll_load_status: all 3 blocks done in {secs:.3f}s.")
      dist.barrier()

      # ---- Phase 6/6: bytes on every rank, local records on rank 0. ----
      _tpu_sync()
      after = tpu_cache_b.cpu().numpy()
      np.testing.assert_array_equal(after[1], host_data[0])
      np.testing.assert_array_equal(after[2], host_data[1])
      np.testing.assert_array_equal(after[3], host_data[2])
      _log(tag, "6/6", rank,
           "HBM blocks [1, 2, 3] bit-exact (HOST, REMOTE, SHARED_STORAGE"
           " sources).")
      dist.barrier()
      if rank == 0:
        # The storage recall published s0 into B's host cache; the peer read
        # recorded nothing locally.
        local = store_b.lookup([s0], enable_global=False, pin_found=False)
        _assert_statuses(local, [s0], [status.HOST_AND_HBM])
        assert local[0][1].raiden_id == rid_b, (
            f"s0 owner {local[0][1].raiden_id} != consumer B"
        )
        r0_local = store_b.lookup([r0], enable_global=False, pin_found=False)
        assert not r0_local, f"{r0!r} must not be recorded locally: {r0_local}"
        _log(tag, "6/6", rank,
             f"{s0!r} published HOST_AND_HBM under B; {r0!r} not recorded"
             " locally.")
      del manager_b, store_b, manager_a, store_a
      dist.barrier()
  finally:
    dist.barrier()
    dist.destroy_process_group()


class KVCacheStoreMpmdE2ETest(parameterized.TestCase):

  @classmethod
  def setUpClass(cls):
    super().setUpClass()
    start_servers()

  @classmethod
  def tearDownClass(cls):
    stop_servers()
    super().tearDownClass()

  def test_mpmd_8rank_e2e_save_and_load(self):
    world_size = 8
    prepare_tpu_environment(world_size)
    master_port = pick_unused_ports(1)[0]
    controller_port = pick_unused_ports(1)[0]

    procs = []
    for rank in range(world_size):
      env = os.environ.copy()
      cmd = worker_launch_cmd() + [
          "--run_worker",
          f"--rank={rank}",
          f"--world_size={world_size}",
          f"--master_port={master_port}",
          f"--controller_port={controller_port}",
          f"--registry_port={_registry_port}",
      ]
      procs.append(subprocess.Popen(cmd, env=env))

    failed = False
    for p in procs:
      p.wait()
      if p.returncode != 0:
        failed = True

    if failed:
      self.fail("One or more workers failed!")

  # The same 8-rank save/load/compare run, with rank 0's load driven through
  # the slices form. Worth running under MPMD rather than only single-process:
  # every rank has its own store and its own shard of each block, so a slices
  # path that resolved entries against the wrong rank's index would land the
  # wrong shards here and nowhere else.
  def test_mpmd_8rank_e2e_save_and_load_with_slices(self):
    world_size = 8
    prepare_tpu_environment(world_size)
    master_port = pick_unused_ports(1)[0]
    controller_port = pick_unused_ports(1)[0]

    procs = []
    for rank in range(world_size):
      env = os.environ.copy()
      cmd = worker_launch_cmd() + [
          "--run_worker",
          "--use_slices",
          f"--rank={rank}",
          f"--world_size={world_size}",
          f"--master_port={master_port}",
          f"--controller_port={controller_port}",
          f"--registry_port={_registry_port}",
      ]
      procs.append(subprocess.Popen(cmd, env=env))

    failed = False
    for p in procs:
      p.wait()
      if p.returncode != 0:
        failed = True

    if failed:
      self.fail("One or more workers failed!")

  # The same 8-rank save/load/compare run with the KV pools (and metadata
  # tables) placed in shared memory. Every rank runs in its own process on the
  # same host, so this is the configuration that needs per-rank segment names
  # and one real segment per allocation; today the ranks collide on one name
  # and the pools are additionally left unregistered with the DMA engine on
  # multi-process TPUv7 (the DmaMap workaround). Enable only after the
  # shared-memory allocator rework AND the libtpu release that fixes
  # multi-process DmaMap (with the workaround removed) — the run is not
  # production-representative before both.
  @unittest.skip(
      "Shared-memory segments collide across same-host MPMD ranks and the"
      " allocator aliases every allocation into one segment; also requires"
      " the libtpu multi-process DmaMap fix. Enable after the allocator"
      " rework and the libtpu pin bump."
  )
  def test_mpmd_8rank_e2e_save_and_load_in_shared_memory(self):
    world_size = 8
    prepare_tpu_environment(world_size)
    master_port = pick_unused_ports(1)[0]
    controller_port = pick_unused_ports(1)[0]
    shm_key = f"raiden_mpmd_e2e_{os.getpid()}"

    procs = []
    try:
      for rank in range(world_size):
        env = os.environ.copy()
        env["RAIDEN_SHM_KEY"] = shm_key
        env["RAIDEN_SHM_MODEL_UID"] = "mpmd_e2e_model"
        cmd = worker_launch_cmd() + [
            "--run_worker",
            "--enable_shm",
            f"--rank={rank}",
            f"--world_size={world_size}",
            f"--master_port={master_port}",
            f"--controller_port={controller_port}",
            f"--registry_port={_registry_port}",
        ]
        procs.append(subprocess.Popen(cmd, env=env))

      failed = False
      for p in procs:
        p.wait()
        if p.returncode != 0:
          failed = True

      if failed:
        self.fail("One or more workers failed!")
    finally:
      # Nothing in the serving stack ever unlinks the segments (they must
      # outlive any crash); decommissioning is the operator's explicit
      # shm_unlink — here, the test.
      for name in os.listdir("/dev/shm"):
        if name.startswith(shm_key):
          try:
            os.unlink(os.path.join("/dev/shm", name))
          except OSError:
            pass

  def test_mpmd_8rank_e2e_write_remote(self):
    world_size = 8
    prepare_tpu_environment(world_size)
    master_port = pick_unused_ports(1)[0]
    controller_port_a = pick_unused_ports(1)[0]
    controller_port_b = pick_unused_ports(1)[0]

    procs = []
    for rank in range(world_size):
      env = os.environ.copy()
      cmd = worker_launch_cmd() + [
          "--run_worker",
          "--worker_mode=write_remote",
          f"--rank={rank}",
          f"--world_size={world_size}",
          f"--master_port={master_port}",
          f"--controller_port={controller_port_a}",
          f"--controller_port_b={controller_port_b}",
          f"--registry_port={_registry_port}",
      ]
      procs.append(subprocess.Popen(cmd, env=env))

    failed = False
    for p in procs:
      p.wait()
      if p.returncode != 0:
        failed = True

    if failed:
      self.fail("One or more workers failed in write_remote MPMD test!")

  def _drive_read_remote(self, use_slices: bool):
    world_size = 8
    prepare_tpu_environment(world_size)
    master_port = pick_unused_ports(1)[0]
    controller_port_a = pick_unused_ports(1)[0]
    controller_port_b = pick_unused_ports(1)[0]

    procs = []
    for rank in range(world_size):
      env = os.environ.copy()
      cmd = worker_launch_cmd() + [
          "--run_worker",
          "--worker_mode=read_remote",
          f"--rank={rank}",
          f"--world_size={world_size}",
          f"--master_port={master_port}",
          f"--controller_port={controller_port_a}",
          f"--controller_port_b={controller_port_b}",
          f"--registry_port={_registry_port}",
      ]
      if use_slices:
        cmd.append("--use_slices")
      procs.append(subprocess.Popen(cmd, env=env))

    failed = False
    for p in procs:
      p.wait()
      if p.returncode != 0:
        failed = True

    if failed:
      self.fail("One or more workers failed in read_remote MPMD test!")

  def test_mpmd_8rank_e2e_read_remote(self):
    self._drive_read_remote(use_slices=False)

  def test_mpmd_8rank_e2e_read_remote_with_slices(self):
    # The peer load through load(slices=REMOTE): the worker body always
    # asserted the records-nothing contract, but no driver dispatched it.
    self._drive_read_remote(use_slices=True)

  @parameterized.named_parameters(
      ("buffered", False),
      ("direct_io", True),
  )
  def test_mpmd_4rank_e2e_secondary_storage_offload_recall(
      self, direct_io: bool = False
  ):
    world_size = 4
    prepare_tpu_environment(world_size)
    master_port_w = pick_unused_ports(1)[0]
    controller_port_w = pick_unused_ports(1)[0]
    master_port_r = pick_unused_ports(1)[0]
    controller_port_r = pick_unused_ports(1)[0]

    mode_str = "direct_io" if direct_io else "buffered"
    if _STORAGE_ROOT.value:
      temp_dir = os.path.join(
          _STORAGE_ROOT.value,
          f"torch_mpmd_{mode_str}_{int(time.time())}",
      )
      os.makedirs(temp_dir, exist_ok=True)
      is_custom_root = True
    else:
      temp_dir = tempfile.mkdtemp()
      is_custom_root = False

    print(
        "\n======================================================================\n"
        "[MPMD Driver] STARTING 4-RANK MULTI-PROCESS SECONDARY STORAGE E2E"
        f" TEST (mode={mode_str})\n"
        f"  World Size: {world_size} ranks (processes)\n"
        f"  Instance Group 1 (Writer): master={master_port_w},"
        f" controller={controller_port_w}\n"
        f"  Instance Group 2 (Reader): master={master_port_r},"
        f" controller={controller_port_r}\n"
        f"  Registry: {_registry_port}\n"
        f"  Storage Root: {temp_dir}\n"
        f"  Direct I/O: {direct_io}\n"
        "======================================================================",
        flush=True,
    )

    try:
      # --- Instance Group 1: Writer ---
      print(
          "[MPMD Driver] Spawning Instance Group 1 (Writer)...",
          flush=True,
      )
      procs_w = []
      for rank in range(world_size):
        env = os.environ.copy()
        env["GLOG_alsologtostderr"] = "1"
        cmd = worker_launch_cmd() + [
            "--run_worker",
            "--alsologtostderr",
            "--worker_mode=secondary_storage",
            "--storage_phase=write",
            f"--storage_root={temp_dir}",
            f"--storage_direct_io={direct_io}",
            f"--rank={rank}",
            f"--world_size={world_size}",
            f"--master_port={master_port_w}",
            f"--controller_port={controller_port_w}",
            f"--registry_port={_registry_port}",
        ]
        p = subprocess.Popen(cmd, env=env)
        print(
            f"[MPMD Driver] Spawning Writer worker rank {rank}/{world_size}"
            f" (PID={p.pid})...",
            flush=True,
        )
        procs_w.append(p)

      failed_w = False
      for rank, p in enumerate(procs_w):
        p.wait()
        print(
            f"[MPMD Driver] Writer worker rank {rank} (PID={p.pid}) finished"
            f" with exit code {p.returncode}.",
            flush=True,
        )
        if p.returncode != 0:
          failed_w = True

      if failed_w:
        self.fail(
            "One or more workers failed in Instance Group 1 (Writer)"
            " secondary_storage MPMD test!"
        )
      print(
          "[MPMD Driver] Instance Group 1 (Writer) completed successfully and"
          " exited.",
          flush=True,
      )

      # --- Instance Group 2: Reader ---
      print(
          "[MPMD Driver] Spawning Instance Group 2 (Reader)...",
          flush=True,
      )
      procs_r = []
      for rank in range(world_size):
        env = os.environ.copy()
        env["GLOG_alsologtostderr"] = "1"
        cmd = worker_launch_cmd() + [
            "--run_worker",
            "--alsologtostderr",
            "--worker_mode=secondary_storage",
            "--storage_phase=read",
            f"--storage_root={temp_dir}",
            f"--storage_direct_io={direct_io}",
            f"--rank={rank}",
            f"--world_size={world_size}",
            f"--master_port={master_port_r}",
            f"--controller_port={controller_port_r}",
            f"--registry_port={_registry_port}",
        ]
        p = subprocess.Popen(cmd, env=env)
        print(
            f"[MPMD Driver] Spawning Reader worker rank {rank}/{world_size}"
            f" (PID={p.pid})...",
            flush=True,
        )
        procs_r.append(p)

      failed_r = False
      for rank, p in enumerate(procs_r):
        p.wait()
        print(
            f"[MPMD Driver] Reader worker rank {rank} (PID={p.pid}) finished"
            f" with exit code {p.returncode}.",
            flush=True,
        )
        if p.returncode != 0:
          failed_r = True

      if failed_r:
        self.fail(
            "One or more workers failed in Instance Group 2 (Reader)"
            " secondary_storage MPMD test!"
        )
      print(
          "[MPMD Driver] Instance Group 2 (Reader) completed successfully and"
          " exited.",
          flush=True,
      )

    finally:
      if not is_custom_root:
        shutil.rmtree(temp_dir, ignore_errors=True)
        print(
            f"[MPMD Driver] Cleaned up temporary directory {temp_dir}.",
            flush=True,
        )
      else:
        print(
            f"[MPMD Driver] Preserved custom storage directory {temp_dir}.",
            flush=True,
        )

    print(
        f"[MPMD Driver][SUCCESS] All {world_size} MPMD secondary storage"
        " workers completed successfully across both instance groups!\n"
        "======================================================================\n",
        flush=True,
    )

  def test_mpmd_4rank_e2e_three_source_load(self):
    """4-rank MPMD: [HOST, REMOTE, SHARED_STORAGE] served by three calls."""
    world_size = 4
    prepare_tpu_environment(world_size)
    master_port = pick_unused_ports(1)[0]
    controller_port_a = pick_unused_ports(1)[0]
    controller_port_b = pick_unused_ports(1)[0]
    controller_port_s = pick_unused_ports(1)[0]

    if _STORAGE_ROOT.value:
      temp_dir = os.path.join(
          _STORAGE_ROOT.value,
          f"torch_mpmd_3src_{int(time.time())}",
      )
      os.makedirs(temp_dir, exist_ok=True)
      is_custom_root = True
    else:
      temp_dir = tempfile.mkdtemp()
      is_custom_root = False

    print(
        "\n======================================================================\n"
        "[MPMD Driver] STARTING 4-RANK THREE-SOURCE LOAD E2E TEST\n"
        f"  World Size: {world_size} ranks (processes)\n"
        f"  Master Port: {master_port}\n"
        f"  Writer Controller: {controller_port_s} | Peer A Controller:"
        f" {controller_port_a} | Consumer B Controller: {controller_port_b}\n"
        f"  Registry: {_registry_port}\n"
        f"  Storage Root: {temp_dir}\n"
        "======================================================================",
        flush=True,
    )

    try:
      procs = []
      for rank in range(world_size):
        env = os.environ.copy()
        env["GLOG_alsologtostderr"] = "1"
        cmd = worker_launch_cmd() + [
            "--run_worker",
            "--alsologtostderr",
            "--worker_mode=three_source",
            "--storage_phase=both",
            f"--storage_root={temp_dir}",
            f"--rank={rank}",
            f"--world_size={world_size}",
            f"--master_port={master_port}",
            f"--controller_port={controller_port_a}",
            f"--controller_port_b={controller_port_b}",
            f"--controller_port_s={controller_port_s}",
            f"--registry_port={_registry_port}",
        ]
        p = subprocess.Popen(cmd, env=env)
        print(
            f"[MPMD Driver] Spawning three_source worker rank"
            f" {rank}/{world_size} (PID={p.pid})...",
            flush=True,
        )
        procs.append(p)

      failures = _wait_for_workers(procs)
      if failures:
        self.fail(f"three_source workers failed: {failures}")
      print(
          f"[MPMD Driver][SUCCESS] All {world_size} MPMD three-source workers"
          " completed successfully!\n"
          "======================================================================\n",
          flush=True,
      )
    finally:
      if not is_custom_root:
        shutil.rmtree(temp_dir, ignore_errors=True)

  # The expected_worker_count barrier tests live in kv_cache_store_test.py;
  # they spawn no MPMD workers, so duplicating them here added nothing.


def main(argv):
  if FLAGS.run_worker:
    if FLAGS.worker_mode == "read_remote":
      _worker_read_remote_main(argv)
    elif FLAGS.worker_mode == "write_remote":
      _worker_write_remote_main(argv)
    elif FLAGS.worker_mode == "secondary_storage":
      _worker_secondary_storage_main(argv)
    elif FLAGS.worker_mode == "three_source":
      _worker_three_source_main(argv)
    else:
      _worker_save_load_main(argv)
  else:
    absltest.main()


if __name__ == "__main__":
  app.run(main)
