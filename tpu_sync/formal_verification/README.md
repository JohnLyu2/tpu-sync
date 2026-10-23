# Formal Verification of TPU Sync (Lean 4)

TPU Sync is a KV-cache orchestration, host-memory offload and cross-node
transfer library for TPUs. Its data paths run on asynchronous callbacks and
lock-scoped state machines across TPU HBM, host DRAM staging pools, and network
peers. This directory holds Lean 4 models of those data paths and
machine-checked proofs about them.

## What is modelled

**Prefill-to-decode transfer** — [prefill_decode.md](docs/transfer/prefill_decode.md)
- C++: `TransferSendSession`, `TransferReceiveSession`,
  `KVCacheManagerWithTransfer`, the receiver side of `BlockTransport`.
- Lean: [`Transfer/Session.lean`](TpuSyncVerify/Transfer/Session.lean),
  [`Transfer/PrefillDecode/`](TpuSyncVerify/Transfer/PrefillDecode/).
- Proved: when a receive is published as done, decode HBM holds exactly the
  prefill's data; no DMA touches prefill or decode HBM after its session is
  published; host staging is held exactly while a session is unsettled; block
  gather, reordering and DMA coalescing land every requested block where the
  caller asked; a pull is claimed once per handshake; from any reachable state
  every session can drain to settle; one unresponsive peer cannot wedge
  another's reads; the transport's per-stream accounting fires the session
  callbacks exactly when the model assumes.

**Engine caller contract** — [prefill_decode.md](docs/transfer/prefill_decode.md) §Boundaries
- Python: the engine above `poll_stats()` — vLLM's scheduler through
  tpu-inference's connector.
- Lean: [`Transfer/PrefillDecode/Caller.lean`](TpuSyncVerify/Transfer/PrefillDecode/Caller.lean).
- Proved: a connector that forwards every publication never leaks a held block
  on either node and never lets decode run on unwritten KV — the other
  direction of the HBM-lifetime contract the transfer models assume.

**Pool resharding** — [reshard.md](docs/transfer/reshard.md)
- C++: `ReshardSendSession`, `ReshardReceiveSession`, `PoolStagingStorage`,
  `RequestBlockRegistry`, `ReshardCoordinator`.
- Lean: [`Transfer/Reshard/`](TpuSyncVerify/Transfer/Reshard/).
- Proved: published destination HBM holds the right bytes, with sub-block
  coverage reconstructing every byte exactly once and rank-ordered H2D waves
  never corrupting aliased device pages; staging slots are conserved and never
  shared across uuids; the receiver's expected stream count matches what the
  senders produce; registry claims retire only when every owner has completed;
  no push is dispatched before all receivers are armed; sessions drain to
  settle and unregister their plan exactly at settle.

**Controller remote leases** — [read_remote.md](docs/controller/read_remote.md)
- C++: `RaidenController::ReadRemote`.
- Lean: [`Controller/ReadRemote.lean`](TpuSyncVerify/Controller/ReadRemote.lean).
- Checked: exhaustive search of `NoWriteAfterRelease` (the caller never reuses
  destination blocks while a pull into them is in flight). The current code
  violates it in two ways, each with a witness trace; deferring the deadline's
  settle while a pull is in flight makes it hold everywhere.

## Layout

```text
TpuSyncVerify.lean            imports every model
TpuSyncVerify/
  Common/                     transition-system core, list lemmas, bounded model checker
  Transfer/Session.lean       settle protocol shared by every transfer session
  Transfer/PrefillDecode/     prefill-to-decode sessions, pipeline, transport, caller
  Transfer/Reshard/           pool-resharding sessions, staging arena, registry, coordinator
  Controller/ReadRemote.lean  controller remote-read lease
docs/
  conventions.md              how the models are written (one executable step, ghost
                              fields, replay traces, mutants) and how the C++ is cited
  transfer/, controller/      per-subsystem C++ <-> Lean docs: states, events,
                              assumptions, proved theorems
tools/
  resolve_anchors.py          resolves and checks the source-map tables
  run_lean.sh                 evaluates ad hoc Lean snippets against the built models
lakefile.toml, lake-manifest.json, lean-toolchain
```

## How the C++ is cited

Prose and docstrings cite C++ symbols (`Class::Method`), code fragments, and
GTest names (`Suite.TestName`); exact line spans live in per-file
`<!-- source-map:begin --> ... <!-- source-map:end -->` tables. Those spans were
last resolved at commit **`c15ead5`**;
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
