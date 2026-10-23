# `tpu-sync-lean-helper`: Formal-Verification-Backed Code Q&A and Change Checker for TPU Sync (demo)

`tpu-sync-lean-helper` is a formal-verification-backed subagent for **TPU Sync** (`tpu_sync/`). Using a formal Lean 4 model, it helps engineers in two ways:
1. **Answer questions about how the code works and what it guarantees**: Explain session lifecycles, buffer/HBM ownership, protocol invariants, and boundary assumptions using the Lean model, including why specific checks or locks exist and what races they prevent.
2. **Check whether a proposed code change is safe**: Evaluate a C++ diff or "what-if" change (such as relaxing a check, reordering operations, or changing a state update) against the formal model, and run the Lean verifier on the modified logic to either **find a concrete multi-threaded race trace that breaks safety** or **mathematically prove that the invariants still hold**.

Under the hood, the subagent pairs live C++ code inspection with **`TpuSyncVerify`** ([`verification/`](../../verification/)), a Lean 4 formal verification suite that models TPU Sync's state machines, buffer ownership lifecycles, and concurrency invariants (currently supporting the symmetric prefill-to-decode KV-cache transfer subsystem). Unlike a standard AI assistant that reasons informally and can easily miss subtle multi-threaded interleavings, `tpu-sync-lean-helper` backs its answers with machine-checked proofs and exhaustive state exploration—clearly distinguishing between **what is mathematically guaranteed**, **what depends on external callers or lower layers (like the Python orchestrator or TCP/RDMA transport)**, and **what lies outside the model**.

To use this agent, engineers do not need to know Lean 4 or formal methods: you ask questions about the C++ code, and the agent handles all Lean verification behind the scenes and reports back in **C++ terms**.

> **Note:** `tpu-sync-lean-helper` is currently a demo version. For issues, feedback, or discussion, contact **John Lu** (`johnzlu@google.com`).

---

## Scope

The formal model used by this agent currently covers the prefill-to-decode KV-cache transfer subsystem within three boundaries (see [`verification/docs/transfer/prefill_decode.md`](../../verification/docs/transfer/prefill_decode.md) for details):

- **Subsystem boundary**: Currently, the agent is scoped to the **prefill-to-decode ("symmetric") KV-cache transfer path** (`TransferSendSession`, `TransferReceiveSession`, `KVCacheManagerWithTransfer`, control-plane backends, and `BlockTransport` session callbacks). Pool resharding ("asymmetric TP" / `ReshardSendSession` / `ReshardReceiveSession`), `RaidenController`, and `kv_cache_store` are out of scope for this subagent.
- **Upper boundary (Serving engines: vLLM / SGLang)**: The session-level transfer model starts at TPU Sync's transfer API (`NotifyForRead`, `StartRead`, `CompleteReadWithDetails` / `poll_stats()`) and its caller HBM-lifetime contract (the serving engine must not reuse prefill or decode HBM blocks until `poll_stats()` publishes the session in `done_sending`, `done_recving`, or `failed_recving`). External serving-engine schedulers, queues, bootstrap servers, and Python-side timeouts sit above this boundary.
- **Lower boundary (Raw transport & socket I/O)**: The model stops at the session–transport callback protocol (`BeginIncomingPush`, `OnLayerReceived`, `OnBlockShardsReceived`, `EndIncomingPush`), block-copy/coalescing plans, and control-plane worker pools. Raw socket I/O (`peregrine::ReadExact` / `TcpSocketUtil::Recv`), wire framing, and internal byte accumulation in `block_transport.cc` sit below the Lean abstraction boundary.

If a question is purely outside these boundaries, the agent states that it is outside the current model rather than speculating. If a question spans a boundary, the agent answers the modelled TPU Sync side, states the contract the model assumes at that boundary, and clearly marks which part sits outside the model (inspecting the C++ code directly when needed for lower-level transport details).

---

## Setup & Invocation

1. **Setup**: Register `agents` (this repository's root-level agent directory) in your agent configuration (e.g., `"entries": [{ "path": "agents" }]` in `agents.json`) so `tpu-sync-lean-helper` ([`agent.json`](agent.json), [`config.yaml`](config.yaml)) is discovered when working in the repository.
2. **Invocation**: Mention `@tpu-sync-lean-helper` directly in chat or ask the main agent to invoke the `tpu-sync-lean-helper` subagent on your question or diff.
3. **Lean Toolchain**: Code Q&A runs with zero shell commands. When the subagent needs to run the Lean 4 verifier live on a new code change via [`verification/tools/run_lean.sh`](../../verification/tools/run_lean.sh), it uses [`elan`](https://github.com/leanprover/elan) with the toolchain pinned in [`verification/lean-toolchain`](../../verification/lean-toolchain) (`leanprover/lean4:v4.33.0`) and evaluates snippets via `stdin` without modifying the working tree.

---

## Usage Examples

### Example 1: Code Q&A

**Prompt:**
> `@tpu-sync-lean-helper` When a receive session is cancelled or times out, what guarantees that an in-flight push or H2D copy won't write into released host staging or decode HBM buffers?

**Response:**
> [`TransferReceiveSession`](../../tpu_sync/kv_cache/transfer_receive_session.h) prevents use-after-free on both host staging and decode HBM through a two-phase **drain-then-settle** protocol in [`TransferReceiveSession::FinishLocked`](../../tpu_sync/kv_cache/transfer_receive_session.cc) and [`TransferReceiveSession::EndRecvOpLocked`](../../tpu_sync/kv_cache/transfer_receive_session.cc). This guarantee is formally proved in the Lean receive and pipeline models across all interleavings of pull handshakes, incoming socket pushes, H2D DMA completions, and timeouts (assuming the serving engine waits for `poll_stats()` before reusing HBM blocks):
>
> - **Cancellation only starts draining (`draining_ = true`)**: When a timeout or error calls `FinishLocked`, it sets `draining_ = true` to block any new pull, push, or H2D dispatch, but only releases host staging (`ReleaseStagingLocked()`) and marks the session `done_ = true` if `in_flight_ == 0`.
> - **`in_flight_` tracks every active operation**: The pull RPC handshake, each active incoming transport push (`BeginIncomingPush` / `EndIncomingPush`), and each dispatched PjRt H2D copy holds `+1` on `in_flight_`. While any of these are still running (`in_flight_ > 0`), `done_` stays `false` and host staging remains pinned.
> - **HBM stays quiet after `poll_stats()` reports completion**: `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`poll_stats()`) only reports the request ID in `done_recving_` or `failed_recving_` after `session->Done()` (`done_ == true`, meaning `in_flight_ == 0`). Any late transport push or H2D dispatch that arrives after `draining_ = true` checks `done_ || draining_` under `mu_` (including a second lock re-check immediately before `H2dSyncDispatch`) and aborts before touching staging or HBM.
> - **What the Lean model verifies**: The formal model tracks buffer ownership alongside the session state machine and proves as an inductive invariant that host staging is held whenever `done_ == false` and that no H2D DMA is pending once `poll_stats()` publishes an outcome. It also includes a counterfactual test showing that if `FinishLocked` marked `done_ = true` and released staging immediately without waiting for `in_flight_ == 0`, an already-dispatched H2D copy or active push would write into recycled staging buffers.

---

### Example 2: Checking a Proposed Change

**Prompt:**
> `@tpu-sync-lean-helper` Can we remove the `IsReadyToComplete()` finish check in `KVCacheManagerWithTransfer::CompleteReadWithDetails` (and the `if (all_complete)` finish branch in `TransferReceiveSession::OnBlockShardsReceived`) and rely solely on the last layer's H2D callback in `ExecuteLayerH2d` to finish the receive session?

**Response:**
> **Yes, as long as `num_layers() > 0` (or zero-layer sessions are finished at creation) — and removing it actually fixes a race where end-of-transfer metrics are silently skipped.** Both properties are formally proved in the Lean receive-polling model:
>
> - **Why the last H2D callback is sufficient for `num_layers() > 0`**: In [`TransferReceiveSession::ExecuteLayerH2d`](../../tpu_sync/kv_cache/transfer_receive_session.cc), the H2D completion callback that increments `num_completed_layers_` to `num_layers()` already calls `FinishLocked()` under `mu_`. Because `OnBlockShardsReceived` can only observe `num_completed_layers_ == total_layers` after that callback has already set `draining_ = true`, the `if (all_complete)` finish branch in `OnBlockShardsReceived` is unreachable dead code.
> - **Why `IsReadyToComplete()` in `CompleteReadWithDetails` can skip metrics**: `IsReadyToComplete()` can only fire in the narrow window after all H2D futures become ready and before the last H2D callback acquires `mu_`. Firing in that window does not speed up settlement (`in_flight_ > 0` until the callback exits, so `done_` still waits for the callback), and instead sets `draining_ = true` early—causing the last callback to hit `if (self->draining_) return;` and skip `RecordTransferDuration`, `RecordH2dComplete`, and `RecordEnd`.
> - **What the Lean model verifies**: The formal model compares the shipping state machine against a variant with `IsReadyToComplete()` removed. It proves that for any session with `num_layers > 0`, every reachable state still settles safely and records end-of-transfer metrics on `done_recving_`, whereas the `num_layers == 0` corner case never fires an H2D callback and therefore must be finished at session creation (matching `TransferSendSession::StartPush`).

---

## Directory Organization

```text
agents/tpu-sync-lean-helper/                    # this directory (fork-only; not part of verification/)
├── README.md                                   # Overview, usage examples, and setup guide
├── agent.json                                  # Subagent manifest
└── config.yaml                                 # Subagent system prompt, tool configuration, and workflow
verification/
├── lean-toolchain                              # Pinned Lean 4 version (leanprover/lean4:v4.33.0)
├── lakefile.toml                               # Lake package config (zero external dependencies)
├── TpuSyncVerify.lean                          # Root umbrella module
├── TpuSyncVerify/
│   ├── Common/                                 # Transition-system framework & BFS model checker
│   └── Transfer/                               # Session lifecycle & prefill-to-decode transfer models/proofs
├── docs/
│   ├── conventions.md                          # C++-to-Lean modelling & mutant conventions
│   └── transfer/prefill_decode.md              # Canonical C++ <-> Lean routing index & boundary assumptions
└── tools/
    └── run_lean.sh                             # Zero-footprint Lean runner (evaluates snippets via stdin)
```

- **Agent Configuration ([`agent.json`](agent.json), [`config.yaml`](config.yaml))**: Defines the `tpu-sync-lean-helper` subagent, its read-only workspace tools, and the workflow that maps C++ questions and diffs to the Lean suite and translates formal results back into C++ terms.
- **Formal Models & Proofs ([`verification/TpuSyncVerify/`](../../verification/TpuSyncVerify/))**: Self-contained Lean 4 models, inductive invariant proofs, executable trace witnesses, and counterfactual mutants for the symmetric prefill-to-decode KV-cache transfer subsystem (`Session`, `Receive`, `ReceivePoll`, `Send`, `Pipeline`, `MultiRequest`, `PeerIsolation`, `UuidTable`, `BlockOrdering`, and `Transport`), pinned to the baseline `tpu-sync` commit in [`verification/README.md` §Status](../../verification/README.md#status-whats-covered).
- **Code-to-Model Reference Docs ([`verification/docs/`](../../verification/docs/))**: [`transfer/prefill_decode.md`](../../verification/docs/transfer/prefill_decode.md) provides the full routing table between `tpu_sync/` C++ files/methods and the Lean modules, along with explicit subsystem/caller/transport boundary assumptions; [`conventions.md`](../../verification/docs/conventions.md) documents how C++ state machines and mutants are encoded in Lean.
- **Zero-Footprint Lean Runner ([`verification/tools/run_lean.sh`](../../verification/tools/run_lean.sh))**: Evaluates ad-hoc Lean snippets and counterfactual mutants via `stdin` without touching files in the working tree.
