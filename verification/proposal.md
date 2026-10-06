# AI-assisted Formal Verification of Prefill-to-Decode Transfer Safety in TPU Sync

*Status (2026-10-06): the prefill-to-decode case study is complete — results in
[README.md](README.md) and [docs/transfer/prefill_decode.md](docs/transfer/prefill_decode.md);
the defects found on the controller path are in [findings/](findings/README.md).*

This project develops an AI-assisted verification workflow for TPU Sync,
beginning with transfer safety in its **prefill-to-decode transfer path** for
disaggregated serving: when transferred KV-cache data can safely be made available
to the decode consumer, and when source buffers can safely be reclaimed by the
prefill producer. It models TPU Sync's pipelined transfer operations and
asynchronous session lifecycles as a state machine in Lean, with AI assistance
for counterexample construction, proof development, and implementation-test
generation. Model counterexamples are replayed in TPU Sync to investigate
potential races, while recorded implementation executions are replayed in the
model to identify missing behavior. This initial case study will establish and
evaluate the verification workflow before extending it to other transfer paths
and correctness properties.

## 1. Background

LLM serving retains attention keys and values in a KV cache so later tokens can
reuse earlier computation. [TPU Sync](https://github.com/google/tpu-sync)
manages these caches and moves data between TPU memory (HBM), host RAM, and
workers on other machines. In **disaggregated serving**, a compute-optimized
prefill worker computes the prompt KV cache on a large accelerator topology and
transfers it to a decode worker on a smaller topology for autoregressive token
generation.

To achieve high throughput, TPU Sync executes this transfer as an asynchronous,
multi-stage pipeline rather than a synchronous copy:
1. **Device-to-Host (D2H) DMA**: Prefill HBM blocks are copied into local host
   staging DRAM.
2. **Host-to-Host (H2H) Network Streaming**: Host staging blocks are packetized
   into chunks and streamed across multiple parallel TCP connections to the decode
   host.
3. **Host-to-Device (H2D) DMA**: Arrived chunks in decode host staging DRAM are
   copied into decode TPU HBM.

Both workers coordinate this through asynchronous session state machines
(`TransferSendSession` and `TransferReceiveSession`) managed by
`KVCacheManagerWithTransfer`. Applications poll completion through `poll_stats()`:
- **Prefill (producer)** relies on `done_sending` to know when it can safely
  free or reallocate its HBM buffers for the next request.
- **Decode (consumer)** relies on `done_recving` to know when all KV blocks have
  landed in HBM so it can safely launch its attention kernels.

Transfer completion alone does not establish correctness. Because D2H DMA,
multi-stream network chunk arrival, and H2D DMA operate concurrently across
multiple layers and workers, out-of-order chunk arrivals or premature completion
signaling can lead to silent token corruption or engine crashes.

## 2. The verification problem

At the system boundary, the prefill and decode serving engines treat TPU Sync as a transfer layer over a stream of requests $R_1, R_2, \dots$ that continuously recycle **TPU HBM blocks** (managed by the serving engines and reclaimed once `poll_stats()` reports a terminal outcome) and **host staging DRAM buffers** (managed by TPU Sync's `StagingBlockAllocator` and recycled as soon as a session settles). Because multi-layer D2H DMA, multi-stream network pushes, H2D DMA, cancellations, and `poll_stats()` run concurrently across background threads, the central question is:

> Across a stream of requests that continuously recycle TPU HBM and host staging buffers, can out-of-order layer completion, mid-flight failures or cancellations, premature buffer reuse, or completion polling races ever corrupt a request's KV cache in decode HBM or leak buffers?

Ultimately, the serving engines rely on **two system-level properties**:

| System property | Required behavior across requests $R_1, R_2, \dots$ |
| --- | --- |
| **1. End-to-end KV data correctness** | Whenever `poll_stats()` signals `done_recving` for a request $R$, every transformer layer $0 \dots L-1$ of $R$'s decode HBM contains $R$'s exact KV cache `[kv 0, …, kv (L-1)]`, and nothing overwrites $R$'s decode HBM while decode attention is running — even when layers finish D2H, H2H, and H2D out of order, when the prefill engine immediately reclaims and overwrites $R$'s prefill HBM upon `done_sending`, and when $R$ reuses host staging and HBM buffers from earlier completed, failed, or cancelled requests. |
| **2. Progress & no buffer leak** | Every started request $R$ (whether it succeeds, fails, or is cancelled) eventually drains all in-flight operations, settles both sessions so host staging DRAM buffers are returned to `StagingBlockAllocator`, and reports terminal outcomes via `poll_stats()` (`done_sending` / `failed_sending` and `done_recving` / `failed_recving`) so the serving engines can reclaim prefill and decode HBM and later requests never starve. |

In this setting, per-buffer safety properties are the intermediate obligations required to establish the two system-level goals:
- **Clean buffer handoff (no use-after-release across requests):**
  - *Prefill HBM safety:* Once `poll_stats()` reports `done_sending` (or `failed_sending`), all D2H DMA reads from prefill HBM have retired, so the prefill engine immediately overwriting prefill HBM for a new request cannot corrupt an in-flight transfer.
  - *Host staging safety:* Once a send or receive session settles and returns its staging buffer to `StagingBlockAllocator`, all D2H, H2H, and H2D operations touching that staging buffer have retired, so recycling the staging buffer can neither corrupt the finishing request nor overwrite the next request's staging data.
  - *Decode HBM safety:* Once `poll_stats()` reports `done_recving` (or `failed_recving`), all H2D DMA writes to decode HBM have retired, so decode attention and subsequent requests reusing decode HBM are never overwritten by straggling writes.
- **Single-request per-layer delivery:** Within an undisturbed transfer, every layer $l \in \{0 \dots L-1\}$ moves from `prefillHbm[l]` $\to$ `prefillStaging[l]` $\to$ `wire[l]` $\to$ `decodeStaging[l]` $\to$ `decodeHbm[l]` without premature reads, and `done_recving` is published only when all $L$ layers have finished H2D.
- **Finite operation drain (no op leak):** Every accounted unit of `in_flight_` can complete or abort, and once `draining_` is set, remaining operations drain in finitely many steps so both sessions settle and publish.

## 3. Verification approach

### 3.1. Model the pipeline as states and steps

Represent the prefill-to-decode transfer protocol as a formal state-machine model
in Lean (`TpuSyncVerify/Transfer/PrefillDecode/`): a precise description of states and
allowed steps on which to base proofs. States record:
- Prefill HBM buffer allocation, per-layer contents, and reclamation / reuse across requests.
- Producer and consumer host staging DRAM allocations from `StagingBlockAllocator` and reuse across requests.
- Per-layer completion state across D2H, H2H network streaming, landing, and H2D.
- Decode HBM per-layer contents and publication status.
- Session progress counters (`in_flight_`, `draining_`, `done_`, `status_`).

Steps define allowed state transitions:
- Producer D2H dispatch and per-layer completion (in arbitrary layer order).
- Network push transmission, out-of-order layer landing, and push callbacks.
- Consumer H2D dispatch (including the unlock/re-lock window) and per-layer completion.
- `CompleteReadRaw` / `poll_stats()` publication (`done_sending` / `failed_sending`, `done_recving` / `failed_recving`).
- Asynchronous buffer reclamation and reuse across requests (`reclaim`, `reseatPrefillStaging`, `reseatDecodeStaging`, and multi-request transitions).
- Deadlines, failures, cancellation, and staging buffer release.

The model represents data symbolically per transformer layer (`Cell.kv l`, `Cell.junk`, `Cell.blank`), tracking whether copied contents in each layer slot match the original prompt KV blocks. Ground the abstraction in TPU Sync's C++ code: map model steps directly to `TransferSendSession`, `TransferReceiveSession`, `KVCacheManagerWithTransfer`, and `BlockTransport`.

### 3.2. Check modeled executions and prove the system properties in Lean

Lean is a programming language and proof assistant that supports executing the
model and checking mathematical proofs about it. The objective is to prove the
two system-level properties — **end-to-end KV data correctness** (at `done_recving`
and throughout decode attention) and **progress / no buffer leak** across requests —
under explicit assumptions.

Use AI assistance to construct concrete executions covering normal multi-layer
transfers, out-of-order layer completions, slow-consumer buffer reclamation,
multi-request buffer reuse after mid-stream failure, and worker timeout/cancellation
scenarios. Lean checks whether a sequence of steps follows the transition rules and
whether the resulting state satisfies the specification.

To establish the two system-level properties across all modeled executions, prove
inductive invariants from bottom to top: session settle invariants (`Session`),
exact `in_flight_` counter conservation (`Send` and `Receive`), single-request
per-layer delivery, post-handoff buffer quietness, and finite drain (`Pipeline`),
and finally multi-request non-interference and progress (`multiSys`). Lean checks
each proof step.

### 3.3. Replay executions between the model and TPU Sync

Translating model executions into deterministic TPU Sync tests, with AI
assistance, connects potential failures to code, most importantly by attempting
to reproduce counterexamples in `kv_cache_manager_with_transfer_*_test.cc`.
Replay in the other direction tests the model instead: map recorded TPU Sync
executions onto model steps and apply §3.2's execution check, where an execution
the model rejects, or whose outcome it disallows, means missing behavior or an
overly restrictive assumption.

Retain traces from either direction as regression tests, prove repairs in the
model before testing the code changes, and recheck proofs after any model change.

## 4. Deliverables

*   **A Lean model and proof suite** (in `TpuSyncVerify/Transfer/PrefillDecode/`), proving
    the two system-level properties (**end-to-end KV data correctness** and **progress /
    no buffer leak** across requests) from single-request publication correctness,
    clean buffer handoff (prefill HBM, host staging, decode HBM), and finite drain,
    together with checked concrete traces and mutant counterexamples when guards are removed.
*   **Implementation tests and model validation**, covering replay in both
    directions, successful scenarios, and counterexample reproduction in TPU
    Sync's test suite. Retain regression traces and include validated repairs
    where violations are reproduced.
*   **An AI-assisted verification workflow**: the agent loop that proposes
    executions, proofs, and tests and feeds Lean's rejections and test failures
    back as input; the agent setup that drives it (instruction files, skills,
    memory, tool integrations); and a record of where it needed human direction.
