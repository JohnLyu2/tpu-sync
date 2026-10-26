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

"""Parity tests for the JAX and Torch WeightSynchronizer bindings.

This file holds WeightSynchronizer behaviour that must be identical for both
bindings. Every test runs once per binding, selected with --framework:
weight_synchronizer_parity_test runs the JAX binding and
weight_synchronizer_parity_torch_test the Torch binding, both through the public
Python WeightSynchronizer API.

Contracts:
- A get_host_buffer() view keeps its synchronizer, including the listener and
  the host staging memory the view aliases, alive until the last view is
  dropped, even after shutdown() has dropped the wrapper's reference to it.
"""

import gc
import hashlib
import os
import socket
import time
import traceback
from typing import Any

from absl import flags
from absl.testing import absltest
import numpy as np

_FRAMEWORK = flags.DEFINE_enum(
    "framework",
    "jax",
    ["jax", "torch"],
    "Framework WeightSynchronizer implementation to test ('jax' or 'torch').",
)

# Seconds to wait for a TCP handshake with a listener on loopback. A closed port
# is refused immediately, so this only bounds a hung handshake.
_CONNECT_TIMEOUT_SECS = 5.0

# Slice size for the listener-based lifetime test, which only observes the
# listener. Kept small so that test does not disturb the allocator state that
# _STAGING_BUFFER_BYTES relies on.
_SMALL_SLICE_BYTES = 1024 * 1024

# WeightSynchronizerBase::InitHostBuffers sizes every host staging buffer as
# slice_byte_size plus --raiden_weight_sync_host_buffer_scratchpad_size, whose
# default is 256 KiB (weight_sync/weight_synchronizer_base.cc:61-63, 290-292).
_HOST_BUFFER_SCRATCHPAD_BYTES = 256 * 1024

# Host staging buffer size for the teardown test: 64 MiB, a realistic per-layer
# shard and exactly 32 2 MiB hugepages. The passing path does not depend on the
# allocator: while a view keeps its synchronizer alive, the buffer is never
# freed. The size only makes a regression, a freed buffer, observable under
# each allocator the test can run with:
# - TCMalloc (the py_test default) returns a whole-hugepage allocation to its
#   HugeCache. If the cache limit (20 MiB minimum, raised only by usage dips)
#   is below 64 MiB, at least 64 MiB minus the limit is madvise(MADV_DONTNEED)ed
#   and reads back as zeros. If the limit is at least 64 MiB but below 128 MiB,
#   the freed range stays cached as the only range large enough for the next
#   64 MiB allocation, which recycles it.
# - glibc malloc mmap()s chunks above its 32 MiB mmap threshold ceiling and
#   munmap()s them on free(), so the freed range is unmapped or remapped.
# - ASan poisons freed memory, so reading it aborts.
# - MSan and TSan serve chunks this large from the sanitizer secondary
#   allocator, which munmap()s them on free(), so the freed range is unmapped
#   or remapped.
_STAGING_BUFFER_BYTES = 64 * 1024 * 1024

# Length of the byte pattern row repeated over a staging buffer. It divides
# _STAGING_BUFFER_BYTES, so the row can be broadcast in place.
_PATTERN_ROW_BYTES = 4096

# Exit codes of the forked child that checksums a host buffer view. The non-zero
# codes avoid 1, which sanitizers exit with after printing a report.
_CHILD_EXIT_BYTES_INTACT = 0
_CHILD_EXIT_BYTES_CHANGED = 77
_CHILD_EXIT_PYTHON_ERROR = 78

# Seconds the forked child may take to checksum a view before it is killed.
# Checksumming 64 MiB takes well under a second, so this only bounds a hang.
_CHILD_TIMEOUT_SECS = 60.0

# POSIX SIGKILL signal number for terminating a timed-out child process.
_SIGKILL = 9

# Seconds between polls for the exit of the forked child.
_CHILD_POLL_INTERVAL_SECS = 0.01

_BYTES_INTACT = "bytes intact"


def _host_buffer_as_numpy(buf: Any) -> np.ndarray:
  """Returns a zero-copy NumPy uint8 view of a JAX or Torch host buffer."""
  if hasattr(buf, "numpy"):
    return buf.numpy()
  return buf


def _listener_accepts_connections(port: int) -> bool:
  """Returns whether a TCP listener accepts connections on 127.0.0.1:port."""
  try:
    with socket.create_connection(
        ("127.0.0.1", port), timeout=_CONNECT_TIMEOUT_SECS
    ):
      return True
  except ConnectionRefusedError:
    return False


def _data_span(buf: np.ndarray) -> tuple[int, int]:
  """Returns the [start, stop) virtual address range of the bytes of buf."""
  start = buf.__array_interface__["data"][0]
  return start, start + buf.nbytes


def _check_digest_in_child_process(
    buf: np.ndarray, expected_digest: bytes
) -> str:
  """Checksums buf in a forked child so a faulting read cannot kill the runner.

  Args:
    buf: Host buffer view to read.
    expected_digest: BLAKE2b digest of the bytes that buf must hold.

  Returns:
    _BYTES_INTACT if the child read the expected bytes, otherwise a description
    of how the child's read went wrong.
  """
  pid = os.fork()
  if pid == 0:  # Child: must exit here and never return into the test runner.
    exit_code = _CHILD_EXIT_PYTHON_ERROR
    try:
      if hashlib.blake2b(buf).digest() == expected_digest:
        exit_code = _CHILD_EXIT_BYTES_INTACT
      else:
        exit_code = _CHILD_EXIT_BYTES_CHANGED
    except BaseException:  # pylint: disable=broad-exception-caught
      traceback.print_exc()
    finally:
      os._exit(exit_code)
  deadline = time.monotonic() + _CHILD_TIMEOUT_SECS
  waited_pid, wait_status = os.waitpid(pid, os.WNOHANG)
  while waited_pid == 0:
    if time.monotonic() >= deadline:
      os.kill(pid, _SIGKILL)
      os.waitpid(pid, 0)
      return f"child timed out after {_CHILD_TIMEOUT_SECS:g} s"
    time.sleep(_CHILD_POLL_INTERVAL_SECS)
    waited_pid, wait_status = os.waitpid(pid, os.WNOHANG)
  if os.WIFSIGNALED(wait_status):
    signal_number = os.WTERMSIG(wait_status)
    return f"child died with signal {signal_number}"
  exit_code = os.WEXITSTATUS(wait_status)
  if exit_code == _CHILD_EXIT_BYTES_INTACT:
    return _BYTES_INTACT
  if exit_code == _CHILD_EXIT_BYTES_CHANGED:
    return "child read bytes that differ from the ones written before teardown"
  if exit_code == _CHILD_EXIT_PYTHON_ERROR:
    return "child raised a Python exception (traceback above)"
  return f"child exited with unexpected code {exit_code}"


class WeightSynchronizerParityTest(absltest.TestCase):
  """WeightSynchronizer contracts shared by the JAX and Torch bindings."""

  def setUp(self):
    super().setUp()
    # pylint: disable=g-import-not-at-top
    if _FRAMEWORK.value == "torch":
      from tpu_sync.api.torch import weight_synchronizer as torch_ws

      self.weight_synchronizer_cls = torch_ws.WeightSynchronizer
    else:
      from tpu_sync.api.jax import weight_synchronizer as jax_ws

      self.weight_synchronizer_cls = jax_ws.WeightSynchronizer
    # pylint: enable=g-import-not-at-top

  def assert_view_type_matches_framework(self, view: Any) -> None:
    """Asserts that a view under --framework=torch is a torch.Tensor.

    A torch.Tensor has .numpy() and a NumPy array does not, so the check needs
    no torch import and keeps the Torch target from testing NumPy views.

    Args:
      view: Object returned by get_host_buffer().
    """
    if _FRAMEWORK.value == "torch":
      self.assertTrue(
          hasattr(view, "numpy"),
          "--framework=torch, but get_host_buffer() returned"
          f" {type(view).__name__} instead of a torch.Tensor.",
      )

  def test_host_buffer_keeps_synchronizer_alive(self):
    """A host buffer view keeps the native synchronizer alive until dropped.

    The probe is the synchronizer's listener, which the native destructor
    closes synchronously (~WeightSynchronizerBase -> ~WeightSynchronizerListener
    -> TcpControlPipeServer::Stop()). The probe is shown to observe both
    states: it is accepted while the synchronizer is referenced and refused
    once the last view is gone.
    """
    ws = self.weight_synchronizer_cls.test_only_create_cpu_instance(
        num_layers=1,
        num_shards=1,
        slice_byte_size=_SMALL_SLICE_BYTES,
        listener_port=0,
        bind_ip="127.0.0.1",
    )
    listener_port = ws.listener_port
    self.assertTrue(
        _listener_accepts_connections(listener_port),
        "Positive control failed: the listener of a live synchronizer on"
        f" 127.0.0.1:{listener_port} refused a connection.",
    )
    host_view = ws.get_host_buffer(layer_idx=0, shard_idx=0)
    self.assert_view_type_matches_framework(host_view)

    ws.shutdown()
    del ws
    gc.collect()

    self.assertTrue(
        _listener_accepts_connections(listener_port),
        "Synchronizer destroyed while a get_host_buffer() view is alive: its"
        f" listener on 127.0.0.1:{listener_port} refused connections once"
        " shutdown() dropped the last Python reference to it, so the view"
        " points into freed host staging memory.",
    )

    del host_view
    gc.collect()

    self.assertFalse(
        _listener_accepts_connections(listener_port),
        "Dropping the last get_host_buffer() view did not destroy the"
        f" synchronizer: its listener on 127.0.0.1:{listener_port} still"
        " accepts connections.",
    )

  def test_host_buffer_contents_survive_synchronizer_teardown(self):
    """View bytes survive teardown and are not recycled by a new synchronizer.

    The post-teardown read runs in a forked child, because reading freed
    staging memory can fault; see _STAGING_BUFFER_BYTES for why freeing the
    buffer is observable.
    """
    # Distinct byte patterns that differ in every byte.
    first_pattern_row = (np.arange(_PATTERN_ROW_BYTES) % 251 + 1).astype(
        np.uint8
    )
    second_pattern_row = np.invert(first_pattern_row)

    first_ws = self.weight_synchronizer_cls.test_only_create_cpu_instance(
        num_layers=1,
        num_shards=1,
        slice_byte_size=_STAGING_BUFFER_BYTES - _HOST_BUFFER_SCRATCHPAD_BYTES,
    )
    first_view = first_ws.get_host_buffer(layer_idx=0, shard_idx=0)
    self.assert_view_type_matches_framework(first_view)
    first_bytes = _host_buffer_as_numpy(first_view)
    self.assertLen(
        first_bytes,
        _STAGING_BUFFER_BYTES,
        "Host staging buffer is not slice_byte_size + 256 KiB; update"
        " _HOST_BUFFER_SCRATCHPAD_BYTES so the buffer stays exactly"
        " _STAGING_BUFFER_BYTES.",
    )
    first_bytes.reshape(-1, _PATTERN_ROW_BYTES)[:] = first_pattern_row
    first_digest = hashlib.blake2b(first_bytes).digest()
    self.assertEqual(
        _check_digest_in_child_process(first_bytes, first_digest),
        _BYTES_INTACT,
        "Positive control failed: a forked child could not read back the"
        " bytes of a live synchronizer's get_host_buffer() view.",
    )

    first_ws.shutdown()
    del first_ws
    gc.collect()

    second_ws = self.weight_synchronizer_cls.test_only_create_cpu_instance(
        num_layers=1,
        num_shards=1,
        slice_byte_size=_STAGING_BUFFER_BYTES - _HOST_BUFFER_SCRATCHPAD_BYTES,
    )
    self.addCleanup(second_ws.shutdown)
    second_bytes = _host_buffer_as_numpy(
        second_ws.get_host_buffer(layer_idx=0, shard_idx=0)
    )
    self.assertLen(second_bytes, len(first_bytes))
    second_bytes.reshape(-1, _PATTERN_ROW_BYTES)[:] = second_pattern_row

    first_start, first_stop = _data_span(first_bytes)
    second_start, second_stop = _data_span(second_bytes)
    self.assertFalse(
        first_start < second_stop and second_start < first_stop,
        "get_host_buffer() view aliases another synchronizer's staging buffer:"
        f" the view [{first_start:#x}, {first_stop:#x}) of the torn-down"
        " synchronizer overlaps the new synchronizer's buffer"
        f" [{second_start:#x}, {second_stop:#x}).",
    )
    read_outcome = _check_digest_in_child_process(first_bytes, first_digest)
    self.assertEqual(
        read_outcome,
        _BYTES_INTACT,
        "Reading a get_host_buffer() view after its synchronizer was"
        f" destroyed: {read_outcome}. The view must keep the synchronizer"
        " and its host staging memory alive.",
    )


if __name__ == "__main__":
  absltest.main()
