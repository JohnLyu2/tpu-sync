# Lean 4 Formalization

TPU Sync moves KV-cache blocks across TPU HBM, host DRAM staging pools, and
network peers using asynchronous callbacks and lock-scoped state machines. This
directory contains the **Lean 4 formalization (`TpuSyncVerify/`)**: models of
the C++ session state machines, staging allocators, and multi-node transfer
pipelines, with proofs of end-to-end data correctness, HBM and host-staging
memory safety, lifecycle termination, and cross-peer fault isolation; the
code-to-model reference docs (`docs/`); and the tools that keep the citations
honest (`tools/`). It is self-contained: everything it refers to is either in
this directory or in `tpu_sync/`.

## Status & What's Covered

The formal models (`TpuSyncVerify/`) and design docs (`docs/`) are pinned to
tpu-sync baseline commit **`c15ead5`** (upstream `main` merged 2026-10-23).
Prose and docstrings cite C++ symbols (`Class::Method`), code fragments, and
GTest `Suite.TestName`s; exact line spans live in per-file
`<!-- source-map:begin --> ... <!-- source-map:end -->` tables generated and
verified from the C++ source tree by
[`tools/resolve_anchors.py`](tools/resolve_anchors.py). The two external
callers that `Caller.lean` cites are pinned separately, to the pair
`examples/*_disagg/setup.sh` installs: tpu-inference `7ed46a6`, vLLM
`6185d73`.

| Subsystem | What Is Modeled & Proved | Lean Models | Design & Proof Doc |
|---|---|---|---|
| **Prefill-to-Decode Transfer** | Send/receive session settle protocol, multi-request buffer recycling, block gather & DMA coalescing, UUID drain, cross-peer fault isolation, the transport's receiver-side stream accounting (`Transport.lean`), and the engine above `poll_stats()` — vLLM's scheduler through tpu-inference's connector, the other direction of the engine contract (`Caller.lean`) | [`TpuSyncVerify/Transfer/Session.lean`](TpuSyncVerify/Transfer/Session.lean), [`TpuSyncVerify/Transfer/PrefillDecode/`](TpuSyncVerify/Transfer/PrefillDecode/) | [prefill_decode.md](docs/transfer/prefill_decode.md) |
| **Pool Resharding** | Multi-pool send/receive sessions, rank-ordered H2D waves, sub-block byte-interval coverage, `PoolStagingStorage` arena leases, block registry, and two-stage coordinator barriers | [`TpuSyncVerify/Transfer/Reshard/`](TpuSyncVerify/Transfer/Reshard/) | [reshard.md](docs/transfer/reshard.md) |
| **Controller & Remote Leases** | Remote read lease lifecycle and `NoWriteAfterRelease` safety via exhaustive state-space exploration | [`TpuSyncVerify/Controller/ReadRemote.lean`](TpuSyncVerify/Controller/ReadRemote.lean) | [read_remote.md](docs/controller/read_remote.md) |

## Where to Look

- **Subsystem write-ups (`docs/`):** Start here for the C++ ↔ Lean mapping,
  state/event tables, proved theorems, and boundary assumptions:
  - [docs/transfer/prefill_decode.md](docs/transfer/prefill_decode.md) — symmetric prefill-to-decode transfer pipeline
  - [docs/transfer/reshard.md](docs/transfer/reshard.md) — asymmetric multi-pool KV-cache resharding
  - [docs/controller/read_remote.md](docs/controller/read_remote.md) — controller remote lease lifecycle
  - [docs/conventions.md](docs/conventions.md) — modeling style, citation format, and proof conventions
- **Lean 4 models & proofs (`TpuSyncVerify/`):** Imported by
  [`TpuSyncVerify.lean`](TpuSyncVerify.lean), with shared transition-system and
  bounded model-checking infrastructure in
  [`TpuSyncVerify/Common/`](TpuSyncVerify/Common/).
- **Tools (`tools/`):** [`resolve_anchors.py`](tools/resolve_anchors.py)
  (source-map resolution and drift check) and the ad hoc Lean counterfactual
  runner [`run_lean.sh`](tools/run_lean.sh).

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
