# Reproducer for finding C1 (findings/README.md): tpu-inference's
# tpu_raiden_connector drops tpu-sync's failed_recving report, so KV blocks
# held for a failed or never-pulled prefill-to-decode transfer are never
# returned to vLLM's block pool on either node. Runs on CPU; no TPU.
#
# How to run (what produced the output pasted in README.md C1):
#   git clone https://github.com/vllm-project/vllm && cd vllm
#   git checkout 6185d73882c0cdfd9ee13cea16a9b50d2b5267be
#   git clone https://github.com/vllm-project/tpu-inference ../tpu-inference
#   git -C ../tpu-inference checkout 7ed46a69e4bf6900af69ad681e01df40a355be85
#   python3 -m venv ../venv && . ../venv/bin/activate
#   pip install torch --index-url https://download.pytorch.org/whl/cpu
#   VLLM_TARGET_DEVICE=empty pip install -e .        # pure-Python vLLM
#   pip install jax pytest && pip install --no-deps -e ../tpu-inference
#   python -m pytest -v <this file>                    # from the vllm checkout
# The first run fetches facebook/opt-125m's config.json from the Hugging Face
# hub (vLLM's test helper builds a ModelConfig from it); HF_HUB_OFFLINE=1 after.
#
# Confirmation tests for finding C1 (tpu-inference tpu_raiden_connector) and
# its tpu-sync side (see C1), run entirely on CPU, no TPU, no network at test time.
#
# Three layers, from narrow to end-to-end:
#   1. connector unit: get_finished() drops poll_stats()' failed_recving;
#      request_finished() on the producer holds blocks (delay_free=True);
#      SendMeta.expiration_time is never read.
#   2. composition, producer: real vLLM Scheduler + real TPUConnectorScheduler;
#      a prefilled request whose transfer is reported by tpu-sync only in
#      failed_recving (what tpu-sync does for a never-pulled send since
#      4246613, and for a failed push) never has its blocks freed.
#   3. composition, consumer: a request waiting for remote KV whose pull fails
#      (again, only failed_recving) and is then aborted by the API layer never
#      has its blocks freed either.
# Each composition test has a control that feeds the report the connector
# *would* give if it forwarded the outcome, and shows the blocks come back.
#
# Pinned sources: vLLM 6185d73, tpu-inference 7ed46a6 (lines cited in
# findings/README.md C1), tpu-sync 0ac16d1.

import os
import sys
import types
from unittest.mock import MagicMock

import pytest

os.environ.setdefault("TPU_KV_TRANSFER_PORT", "9100")
os.environ.setdefault("TPU_P2P_WAIT_PULL_TIMEOUT", "180")

# tpu_raiden_connector imports the TPU model runner for a type annotation
# only; stub it so the module imports on a CPU box.
_runner = types.ModuleType("tpu_inference.runner.tpu_runner")
_runner.TPUModelRunner = object
sys.modules.setdefault("tpu_inference.runner", types.ModuleType("tpu_inference.runner"))
sys.modules["tpu_inference.runner.tpu_runner"] = _runner

# The editable vLLM was built with VLLM_TARGET_DEVICE=empty (no compiled
# ops); its platform auto-detection keys on the version string containing
# "cpu", so select the CPU platform explicitly before any config is built.
import vllm.platforms as _vp  # noqa: E402
from vllm.platforms.cpu import CpuPlatform  # noqa: E402
_vp._current_platform = CpuPlatform()

from vllm.distributed.kv_transfer.kv_connector.factory import KVConnectorFactory  # noqa: E402
from vllm.v1.outputs import KVConnectorOutput, ModelRunnerOutput  # noqa: E402
from vllm.v1.request import RequestStatus  # noqa: E402

from tests.v1.core.utils import create_requests, create_scheduler  # noqa: E402

import tpu_inference.distributed.tpu_raiden_connector as trc  # noqa: E402

CONNECTOR_MODULE = "tpu_inference.distributed.tpu_raiden_connector"
KVConnectorFactory.register_connector("TPUConnector", CONNECTOR_MODULE, "TPUConnector")

BLOCK_SIZE = 16
NUM_BLOCKS = 64


# --------------------------------------------------------------------------
# 1. Connector unit tests
# --------------------------------------------------------------------------

def _worker_with_poll_stats(done_sending, done_recving, failed_recving):
    w = trc.TPUConnectorWorker.__new__(trc.TPUConnectorWorker)
    w.node_id = 0
    w.kv_manager = MagicMock()
    w.kv_manager.poll_stats.return_value = (done_sending, done_recving, failed_recving)
    return w


def test_unit_get_finished_drops_failed_recving():
    """tpu_raiden_connector.py:632-657: the third list is logged and dropped."""
    w = _worker_with_poll_stats([], [], ["req-failed"])
    assert w.get_finished() == (set(), set())
    w.kv_manager.poll_stats.assert_called_once_with()


def test_unit_get_finished_forwards_done_lists():
    w = _worker_with_poll_stats(["p"], ["d"], [])
    assert w.get_finished() == ({"p"}, {"d"})


def test_unit_get_block_ids_with_load_errors_is_default_empty():
    """The vLLM failure channel (base.py:375-393) is not implemented."""
    assert "get_block_ids_with_load_errors" not in trc.TPUConnector.__dict__
    c = trc.TPUConnector.__new__(trc.TPUConnector)
    assert c.get_block_ids_with_load_errors() == set()


def test_unit_producer_request_finished_holds_blocks():
    """tpu_raiden_connector.py:404-455: a finished prefill returns delay_free=True."""
    sched = trc.TPUConnectorScheduler.__new__(trc.TPUConnectorScheduler)
    sched.is_producer = True
    sched.block_size = BLOCK_SIZE
    sched.reqs_to_send = {}
    sched.kv_ip = "127.0.0.1"
    sched.kv_port = "9100"
    req = MagicMock()
    req.request_id = "r"
    req.status = RequestStatus.FINISHED_LENGTH_CAPPED
    req.num_computed_tokens = 2 * BLOCK_SIZE
    delay_free, params = sched.request_finished(req, [10, 11])
    assert delay_free is True
    assert params["remote_block_ids"] == [10, 11]
    assert "r" in sched.reqs_to_send
    # The expiry the SendMeta carries is never consulted anywhere.
    assert sched.reqs_to_send["r"].expiration_time > 0


def test_unit_expiration_time_has_no_reader():
    src = open(trc.__file__).read()
    reads = [l for l in src.splitlines()
             if "expiration_time" in l and "expiration_time=" not in l
             and "expiration_time: float" not in l
             and not l.strip().startswith("expiration_time = ")]
    assert reads == [], reads


# --------------------------------------------------------------------------
# 2./3. Composition: real vLLM Scheduler + real TPUConnectorScheduler
# --------------------------------------------------------------------------

def _scheduler(kv_role: str):
    """vLLM Scheduler with the real TPUConnector on the scheduler side."""
    sched = create_scheduler(
        use_kv_connector="TPUConnector",
        block_size=BLOCK_SIZE,
        num_blocks=NUM_BLOCKS,
        enable_prefix_caching=False,
        max_num_seqs=4,
    )
    # create_scheduler builds a kv_both config; the connector reads its role
    # from kv_transfer_config.is_kv_producer at call time.
    cs = sched.connector.connector_scheduler
    cs.is_producer = (kv_role == "kv_producer")
    return sched


def _free_blocks(sched):
    return sched.kv_cache_manager.block_pool.get_num_free_blocks()


def _step(sched, req_ids=(), sampled=None, kv_out=None):
    out = sched.schedule()
    mro = ModelRunnerOutput(
        req_ids=list(req_ids),
        req_id_to_index={r: i for i, r in enumerate(req_ids)},
        sampled_token_ids=sampled if sampled is not None else [[1000]] * len(req_ids),
        logprobs=None,
        prompt_logprobs_dict={},
        pooler_output=[],
        kv_connector_output=kv_out,
    )
    sched.update_from_output(out, mro)
    return out


def _connector_output(poll_stats):
    """What the real worker-side get_finished() turns poll_stats() into."""
    w = _worker_with_poll_stats(*poll_stats)
    done_sending, done_recving = w.get_finished()
    return KVConnectorOutput(finished_sending=done_sending or None,
                             finished_recving=done_recving or None)


@pytest.mark.parametrize("tpu_sync_report,expect_freed", [
    # tpu-sync 0ac16d1, mgr.cc:961-970: a never-pulled or failed send is
    # reported in failed_recving. The connector drops it.
    (([], [], ["0"]), False),
    # Control: what tpu-sync reported for an expired send before 4246613
    # (done_sending), or what a forwarding connector would report.
    ((["0"], [], []), True),
])
def test_producer_blocks_after_transfer_outcome(tpu_sync_report, expect_freed):
    sched = _scheduler("kv_producer")
    total = _free_blocks(sched)

    # One prefill request, max_tokens=1 (the proxy caps P's output at 1).
    req = create_requests(num_requests=1, num_tokens=4 * BLOCK_SIZE,
                          max_tokens=1, block_size=BLOCK_SIZE)[0]
    sched.add_request(req)
    _step(sched, req_ids=[req.request_id])          # prefill + 1 token -> finished
    assert req.status == RequestStatus.FINISHED_LENGTH_CAPPED
    # The connector asked vLLM to hold the blocks until it reports the send.
    assert req.request_id in sched.requests
    held = total - _free_blocks(sched)
    assert held == 4, held

    # tpu-sync's deadline passes (180 s in production); its poll_stats()
    # reports the outcome; the connector translates; vLLM consumes it, and
    # keeps consuming empty reports for many more steps.
    _step(sched, kv_out=_connector_output(tpu_sync_report))
    for _ in range(50):
        _step(sched, kv_out=_connector_output(([], [], [])))

    freed = _free_blocks(sched) == total
    assert freed == expect_freed
    assert (req.request_id in sched.requests) == (not expect_freed)


@pytest.mark.parametrize("tpu_sync_report,expect_freed", [
    (([], [], ["0"]), False),    # failed receive: dropped by the connector
    (([], ["0"], []), True),     # control: successful receive
])
def test_consumer_blocks_after_failed_pull_and_abort(tpu_sync_report, expect_freed):
    sched = _scheduler("kv_consumer")
    total = _free_blocks(sched)

    req = create_requests(num_requests=1, num_tokens=4 * BLOCK_SIZE,
                          max_tokens=4, block_size=BLOCK_SIZE)[0]
    # What the proxy forwards from P's kv_transfer_params.
    req.kv_transfer_params = {
        "uuid": 7, "remote_block_ids": [1, 2, 3, 4],
        "remote_host": "127.0.0.1", "remote_port": "9100",
        "do_remote_prefill": True,
    }
    sched.add_request(req)
    out = sched.schedule()                           # allocates, waits for remote KV
    assert req.status == RequestStatus.WAITING_FOR_REMOTE_KVS
    assert out.kv_connector_metadata.reqs_to_load   # the worker would start_read
    held = total - _free_blocks(sched)
    assert held == 4, held
    sched.update_from_output(out, ModelRunnerOutput(
        req_ids=[], req_id_to_index={}, sampled_token_ids=[], logprobs=None,
        prompt_logprobs_dict={}, pooler_output=[]))

    # The pull's outcome arrives from tpu-sync; the connector translates.
    _step(sched, kv_out=_connector_output(tpu_sync_report))

    if not expect_freed:
        # Nothing promoted the request; "the request times out at the API
        # layer instead" -- the API server aborts it.
        sched.finish_requests(req.request_id, RequestStatus.FINISHED_ABORTED)
        for _ in range(50):
            _step(sched, kv_out=_connector_output(([], [], [])))
        assert _free_blocks(sched) == total - 4
        assert req.request_id in sched.requests
    else:
        # Successful pull: the request is promoted and decodes to completion.
        for _ in range(8):
            _step(sched, req_ids=[req.request_id])
        assert _free_blocks(sched) == total


# --------------------------------------------------------------------------
# 4. The connector variants of the Lean model (TpuSyncVerify/Transfer/
#    PrefillDecode/Caller.lean), consumer side, against the real scheduler.
#
# Each variant is the Signal the Lean `Connector.onRecv false` produces for a
# failed pull, rendered as the KVConnectorOutput the worker would hand the
# scheduler. The assertions are the Lean traces' end states:
#   fixed          -> trace_fixed_fail / trace_fixed_recompute / trace_fixed_abort_before
#   naive          -> trace_naive_decodes
#   loadErrorOnly  -> trace_loadErrorOnly_fail / trace_loadErrorOnly_recompute
# They check the model's transcription of scheduler.py:1516-1523, 1742-1744,
# 1758, 2061-2070, 2380-2429, 2462-2474 and the fail/recompute policy switch
# (vllm/config/kv_transfer.py:69), which is what the proof rests on.
# --------------------------------------------------------------------------

def _consumer_signal(variant, req_id, block_ids):
    """`Connector.onRecv false` of Caller.lean, as a KVConnectorOutput."""
    if variant == "fixed":
        return KVConnectorOutput(finished_recving={req_id},
                                 invalid_block_ids=set(block_ids))
    if variant == "naive":
        return KVConnectorOutput(finished_recving={req_id})
    if variant == "loadErrorOnly":
        return KVConnectorOutput(invalid_block_ids=set(block_ids))
    raise ValueError(variant)


def _parked_consumer(policy):
    """A consumer scheduler with one request parked in WAITING_FOR_REMOTE_KVS."""
    sched = _scheduler("kv_consumer")
    sched.recompute_kv_load_failures = (policy == "recompute")
    total = _free_blocks(sched)
    req = create_requests(num_requests=1, num_tokens=4 * BLOCK_SIZE,
                          max_tokens=4, block_size=BLOCK_SIZE)[0]
    req.kv_transfer_params = {
        "uuid": 7, "remote_block_ids": [1, 2, 3, 4],
        "remote_host": "127.0.0.1", "remote_port": "9100",
        "do_remote_prefill": True,
    }
    sched.add_request(req)
    out = sched.schedule()
    assert req.status == RequestStatus.WAITING_FOR_REMOTE_KVS
    sched.update_from_output(out, ModelRunnerOutput(
        req_ids=[], req_id_to_index={}, sampled_token_ids=[], logprobs=None,
        prompt_logprobs_dict={}, pooler_output=[]))
    assert total - _free_blocks(sched) == 4
    (block_ids,) = sched.kv_cache_manager.get_block_ids(req.request_id)
    return sched, req, total, list(block_ids)


@pytest.mark.parametrize("policy", ["fail", "recompute"])
def test_fixed_connector_failed_pull_frees_or_recomputes(policy):
    sched, req, total, block_ids = _parked_consumer(policy)
    _step(sched, kv_out=_consumer_signal("fixed", req.request_id, block_ids))
    if policy == "fail":
        # trace_fixed_fail: FINISHED_ERROR in the same step, blocks released by
        # the finished_recving that arrives with the load error.
        assert req.status == RequestStatus.FINISHED_ERROR
        assert _free_blocks(sched) == total
        assert req.request_id not in sched.requests
    else:
        # trace_fixed_recompute: marked failed and complete; the next
        # schedule() frees the transfer blocks and prefills locally from 0.
        assert req.request_id in sched.finished_recving_kv_req_ids
        assert req.request_id in sched.failed_recving_kv_req_ids
        out = _step(sched, req_ids=[req.request_id])
        assert out.num_scheduled_tokens[req.request_id] == 4 * BLOCK_SIZE
        for _ in range(8):
            _step(sched, req_ids=[req.request_id])
        assert _free_blocks(sched) == total
        assert req.request_id not in sched.requests


@pytest.mark.parametrize("policy", ["fail", "recompute"])
def test_fixed_connector_abort_before_failed_pull_frees(policy):
    # trace_fixed_abort_before: the deferred free is released by the
    # completion report; the load error is ignored for a finished request.
    sched, req, total, block_ids = _parked_consumer(policy)
    sched.finish_requests(req.request_id, RequestStatus.FINISHED_ABORTED)
    assert total - _free_blocks(sched) == 4
    _step(sched, kv_out=_consumer_signal("fixed", req.request_id, block_ids))
    assert _free_blocks(sched) == total
    assert req.request_id not in sched.requests


@pytest.mark.parametrize("policy", ["fail", "recompute"])
def test_naive_connector_decodes_on_unwritten_kv(policy):
    # trace_naive_decodes: done_recving alone promotes the request with its
    # prompt counted as computed; the next schedule() runs it as a decode
    # (one token) on blocks nothing wrote. The policy never acts: it only
    # sees invalid_block_ids.
    sched, req, total, block_ids = _parked_consumer(policy)
    _step(sched, kv_out=_consumer_signal("naive", req.request_id, block_ids))
    assert req.request_id not in sched.failed_recving_kv_req_ids
    out = _step(sched, req_ids=[req.request_id])
    assert req.status == RequestStatus.RUNNING
    assert out.num_scheduled_tokens[req.request_id] == 1
    assert req.num_computed_tokens >= 4 * BLOCK_SIZE


@pytest.mark.parametrize("policy", ["fail", "recompute"])
def test_load_error_only_connector_leaks(policy):
    # trace_loadErrorOnly_fail / _recompute: without finished_recving the
    # request is errored (fail) or marked (recompute) but its blocks wait for
    # a completion that never comes.
    sched, req, total, block_ids = _parked_consumer(policy)
    _step(sched, kv_out=_consumer_signal("loadErrorOnly", req.request_id, block_ids))
    for _ in range(50):
        _step(sched, kv_out=_connector_output(([], [], [])))
    if policy == "fail":
        assert req.status == RequestStatus.FINISHED_ERROR
    else:
        assert req.status == RequestStatus.WAITING_FOR_REMOTE_KVS
        assert req.request_id in sched.failed_recving_kv_req_ids
    assert total - _free_blocks(sched) == 4
    assert req.request_id in sched.requests
