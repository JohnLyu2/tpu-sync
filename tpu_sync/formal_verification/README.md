# Formal Verification of TPU Sync (Lean 4)

TPU Sync moves KV-cache blocks across TPU HBM, host DRAM staging pools, and
network peers using asynchronous callbacks and lock-scoped state machines.

This directory contains the **Lean 4 formalization (`TpuSyncVerify/`)**: models
of the C++ session state machines, staging allocators, and multi-node transfer
pipelines, with proofs of end-to-end data correctness, HBM and host-staging
memory safety, lifecycle termination, and cross-peer fault isolation; the
code-to-model reference docs (`docs/`); and the tools that keep the citations
honest (`tools/`). You do not need Lean to use `docs/`: each doc maps C++
symbols to the model's states, events, assumptions and proved properties; the
`.lean` files are what the machine checks. The proofs use no `sorry`, no
axioms, and no Mathlib.

## Status & What's Covered

Prose and docstrings cite C++ symbols (`Class::Method`), code fragments, and
GTest names (`Suite.TestName`); exact line spans live in per-file
`<!-- source-map:begin --> ... <!-- source-map:end -->` tables. Those spans were
last resolved at commit **`c15ead5`**;
[`tools/resolve_anchors.py`](tools/resolve_anchors.py) `--check` re-verifies
them against the working tree. The two external callers that `Caller.lean`
cites are pinned separately, to the pair `examples/*_disagg/setup.sh`
installs: tpu-inference `7ed46a6`, vLLM `6185d73`.

| Subsystem | What Is Modeled & Proved | Lean Models | Design & Proof Doc |
|---|---|---|---|
| **Prefill-to-Decode Transfer** | Send/receive session settle protocol, multi-request buffer recycling, block gather & DMA coalescing, UUID drain, cross-peer fault isolation, and the transport's receiver-side stream accounting | [`TpuSyncVerify/Transfer/Session.lean`](TpuSyncVerify/Transfer/Session.lean), [`TpuSyncVerify/Transfer/PrefillDecode/`](TpuSyncVerify/Transfer/PrefillDecode/) | [prefill_decode.md](docs/transfer/prefill_decode.md) |
| **Engine Caller Contract** | The engine above `poll_stats()` — vLLM's scheduler through tpu-inference's connector — and what it must do with a publication: the other direction of the HBM-lifetime contract the transfer models assume | [`TpuSyncVerify/Transfer/PrefillDecode/Caller.lean`](TpuSyncVerify/Transfer/PrefillDecode/Caller.lean) | [prefill_decode.md](docs/transfer/prefill_decode.md) §Boundaries |
| **Pool Resharding** | Multi-pool send/receive sessions, rank-ordered H2D waves, sub-block byte-interval coverage, `PoolStagingStorage` arena leases, block registry, and two-stage coordinator barriers | [`TpuSyncVerify/Transfer/Reshard/`](TpuSyncVerify/Transfer/Reshard/) | [reshard.md](docs/transfer/reshard.md) |
| **Controller & Remote Leases** | Remote read lease lifecycle and `NoWriteAfterRelease` safety via exhaustive state-space exploration | [`TpuSyncVerify/Controller/ReadRemote.lean`](TpuSyncVerify/Controller/ReadRemote.lean) | [read_remote.md](docs/controller/read_remote.md) |

## Where to Look

- [docs/conventions.md](docs/conventions.md) — how the models are written
  (one executable `step`, ghost fields, replay traces, mutants), the citation
  format, and the proof conventions.
- [`TpuSyncVerify.lean`](TpuSyncVerify.lean) imports every model;
  [`TpuSyncVerify/Common/`](TpuSyncVerify/Common/) holds the shared
  transition-system and bounded model-checking infrastructure.
- [`tools/resolve_anchors.py`](tools/resolve_anchors.py) resolves and checks
  the source-map tables; [`tools/run_lean.sh`](tools/run_lean.sh) evaluates ad
  hoc Lean snippets (counterfactual mutants, bounded searches) against the
  built models.

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
