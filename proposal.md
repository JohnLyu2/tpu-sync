# AI-assisted Formal Verification of Prefill-to-Decode Transfer Safety in TPU Sync

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

Transfer safety in disaggregated serving requires that asynchronous completion
signals (`done_sending` and `done_recving`) strictly reflect the physical state of
memory operations across nodes. Because TPU Sync coordinates multi-layer DMA transfers
and multi-stream network chunks concurrently across background threads, completion
polling can race with ongoing memory operations. The central question is:

> Can pipelined DMA copying, multi-stream network streaming, buffer reuse, and
> completion polling overlap in a way that causes corrupted KV data to be
> consumed or source buffers to be prematurely overwritten?

The verification addresses three related properties:

| Property | Required behavior |
| --- | --- |
| Publication correctness | When `done_recving` is signaled, all requested KV blocks are fully committed to decode HBM with their expected contents. Decode never executes attention kernels on uncommitted or stale HBM memory. |
| Source buffer safety | When `done_sending` is signaled, all D2H DMA reads from prefill HBM have completed. Prefill never frees or overwrites source HBM buffers while a transfer is still reading from them. |
| Staging integrity & termination | Under stated scheduling and network assumptions, operations eventually succeed or fail. Host staging DRAM blocks allocated for the pipeline are guaranteed to be released on completion, timeout, or cancellation, preventing memory leaks and cross-request memory pollution. |

## 3. Verification approach

### 3.1. Model the pipeline as states and steps

Represent the prefill-to-decode transfer protocol as a formal state-machine model
in Lean (`TpuSyncFormal/PrefillDecode/`): a precise description of states and
allowed steps on which to base proofs. States record:
- Prefill HBM buffer allocation, contents, and lifetime (active, ready to free, reused).
- Producer and consumer host staging DRAM allocations from `StagingBlockAllocator`.
- In-flight network chunks and out-of-order layer/shard arrivals.
- Decode HBM buffer contents and publication status.
- Session progress counters (`in_flight_`, `draining_`, `done_`, `status_`).

Steps define allowed state transitions:
- Producer D2H dispatch and layer completion.
- Network chunk transmission, transport out-of-order delivery, and layer arrival.
- Consumer H2D dispatch and completion.
- `CompleteReadRaw` polling updates (`done_sending`, `done_recving`, `failed_recving`).
- Producer buffer deallocation / reallocation and consumer attention kernel launch.
- Deadlines, cancellation, and staging buffer release.

The model represents data symbolically, tracking whether copied contents match the
original prompt KV blocks. Ground the abstraction in TPU Sync's C++ code: map model
steps directly to `TransferSendSession`, `TransferReceiveSession`,
`KVCacheManagerWithTransfer`, and `BlockTransport`.

### 3.2. Check modeled executions and prove safety in Lean

Lean is a programming language and proof assistant that supports executing the
model and checking mathematical proofs about it. The objective is to establish
whether the modeled pipeline satisfies publication correctness and source buffer
safety under explicit assumptions.

Use AI assistance to construct concrete executions covering normal multi-layer
transfers, out-of-order network chunk arrivals, and worker timeout/cancellation
scenarios. Lean checks whether a sequence of steps follows the transition rules and
whether the resulting state satisfies the specification. An allowed execution that
violates publication correctness or causes a premature buffer overwrite is a
verified model counterexample.

To establish safety across all modeled executions, prove inductive invariants:
conditions that hold initially, are preserved by every allowed step, and imply
publication correctness and source buffer safety. Define the correctness
properties and assumptions explicitly, then construct the proofs with AI
assistance. Lean checks each proof step.

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

*   **A Lean model and proof suite** (in `TpuSyncFormal/PrefillDecode/`), with
    explicit correctness properties (publication correctness, source buffer
    safety, staging integrity), checked counterexamples where violations are
    found, and validation against recorded TPU Sync executions.
*   **Implementation tests and model validation**, covering replay in both
    directions, successful scenarios, and counterexample reproduction in TPU
    Sync's test suite. Retain regression traces and include validated repairs
    where violations are reproduced.
*   **An AI-assisted verification workflow**: the agent loop that proposes
    executions, proofs, and tests and feeds Lean's rejections and test failures
    back as input; the agent setup that drives it (instruction files, skills,
    memory, tool integrations); and a record of where it needed human direction.
