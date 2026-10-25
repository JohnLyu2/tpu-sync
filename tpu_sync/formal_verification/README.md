# Formal Verification of TPU Sync (Lean 4)

TPU Sync is a KV-cache orchestration, host-memory offload and cross-node
transfer library for TPUs. Its data paths run on asynchronous callbacks and
lock-scoped state machines across TPU HBM, host DRAM staging pools, and network
peers. This directory holds Lean 4 models of those data paths and
machine-checked proofs about them.

## What is modelled

The shared infrastructure (`Common/`), the transfer-session lifecycle model
and the prefill-to-decode subsystem (`Transfer/PrefillDecode/`, including the
transport and engine caller models) are in; the resharding and controller
models below arrive in follow-up changes.

**Prefill-to-decode transfer** — [prefill_decode.md](docs/transfer/prefill_decode.md)
- C++: `TransferSendSession`, `TransferReceiveSession`,
  `KVCacheManagerWithTransfer`, the receiver side of `BlockTransport`.
- Lean: [`Transfer/Session.lean`](TpuSyncVerify/Transfer/Session.lean),
  [`Transfer/PrefillDecode/`](TpuSyncVerify/Transfer/PrefillDecode/).
- Proved: data correctness on publication, HBM and staging safety,
  drain-to-settle termination, cross-peer isolation.

**Engine caller contract** — [prefill_decode.md](docs/transfer/prefill_decode.md) §Boundaries
- Python: vLLM's scheduler through tpu-inference's connector, above
  `poll_stats()`.
- Lean: [`Transfer/PrefillDecode/Caller.lean`](TpuSyncVerify/Transfer/PrefillDecode/Caller.lean).
- Proved: a connector that forwards every publication leaks no held block and
  never decodes on unwritten KV.

**Pool resharding** — `docs/transfer/reshard.md` *(follow-up)*
- C++: `ReshardSendSession`, `ReshardReceiveSession`, `PoolStagingStorage`,
  `RequestBlockRegistry`, `ReshardCoordinator`.
- Lean: `Transfer/Reshard/`.
- Proved: data correctness including sub-block coverage and aliased-page
  ordering, staging slot conservation, registry claim safety,
  arm-before-dispatch, termination.

**Controller remote leases** — `docs/controller/read_remote.md` *(follow-up)*
- C++: `RaidenController::ReadRemote`.
- Lean: `Controller/ReadRemote.lean`.
- Checked: `NoWriteAfterRelease` by exhaustive search — violated by the
  current code (two witness traces), holds if the deadline defers while a pull
  is in flight.

## Layout

```text
TpuSyncVerify.lean            imports every model
TpuSyncVerify/
  Common/                     transition-system core, list lemmas, bounded model checker
  Transfer/Session.lean       settle protocol shared by every transfer session
  Transfer/PrefillDecode/     prefill-to-decode sessions, pipeline, transport, caller
  Transfer/Reshard/           pool-resharding sessions, staging arena, registry, coordinator (follow-up)
  Controller/ReadRemote.lean  controller remote-read lease (follow-up)
docs/
  conventions.md              how the models are written (one executable step, ghost
                              fields, replay traces, mutants) and how the C++ is cited
  transfer/, controller/      per-subsystem C++ <-> Lean docs: states, events,
                              assumptions, proved theorems (reshard, controller follow-up)
tools/
  resolve_anchors.py          resolves and checks the source-map tables
lakefile.toml, lake-manifest.json, lean-toolchain
```

## How the C++ is cited

Prose and docstrings cite C++ symbols (`Class::Method`), code fragments, and
GTest names (`Suite.TestName`); exact line spans live in per-file
`<!-- source-map:begin --> ... <!-- source-map:end -->` tables. Those spans were
last resolved at commit **`c9bc124`**;
[`tools/resolve_anchors.py`](tools/resolve_anchors.py) `--check` re-verifies
them against the working tree. The two external callers that `Caller.lean`
cites are pinned separately, to the pair `examples/*_disagg/setup.sh`
installs: tpu-inference `7ed46a6`, vLLM `6185d73`.

## Building & Verifying

Requires [elan](https://github.com/leanprover/elan); the toolchain pinned in
[`lean-toolchain`](lean-toolchain) (Lean 4.33.0) is fetched automatically.

```sh
cd tpu_sync/formal_verification
lake build
python3 tools/resolve_anchors.py --check
```

A clean build takes about half a minute; every `theorem` is machine-checked,
every `#guard` bounded search is executed, and `resolve_anchors.py --check`
verifies all C++ source-map tables and checks for stray raw line citations.
