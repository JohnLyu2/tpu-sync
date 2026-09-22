# AI-assisted Formal Verification of Publication Safety in TPU Sync

This project develops an AI-assisted verification workflow for TPU Sync,
beginning with publication safety in its remote-read path: when transferred
KV-cache data can safely be made available to a consumer. It models TPU Sync's
transfer operations and coordination rules as a state machine in Lean, with AI
assistance for counterexample construction, proof development, and
implementation-test generation. Model counterexamples are replayed in TPU Sync to
investigate potential failures, while recorded implementation executions are
replayed in the model to identify missing behavior. This initial case study will
establish and evaluate the remote-read workflow before extending it to other
transfer paths and correctness properties.

## 1. Background

LLM serving retains attention keys and values in a KV cache so later tokens can
reuse earlier computation. [TPU Sync](https://github.com/google/tpu-sync)
manages these caches and moves data between TPU memory, host RAM, and workers on
other machines. A remote load can pull another worker's cached data through local
host staging into TPU memory.

Transfer completion alone does not establish correctness. While a copy is in
progress, a deadline may expire, a lease may be released, or source storage may
be reassigned. The destination must distinguish receiving bytes from having a
valid result that consumers may use.

TPU Sync's remote-read protocol uses **leases**: source-side records that protect
requested cache blocks through **pins**, which prevent eviction and storage
reuse. A lease can expire during a pull, allowing the source to release those
pins. After copying, the destination asks the source for a verdict on the lease
and uses it to decide whether to accept the result. Correctness depends on how
that verdict interacts with copying, deadlines, and completion callbacks.

## 2. The verification problem

Publication means making transferred KV data available to consumers as a valid
result. The central question is:

> Can copying, buffer reuse, and deadline handling overlap in a way that causes
> incorrect KV data to be published?

The verification addresses three related properties:

| Property | Required behavior |
| --- | --- |
| Publication correctness | A successful transfer makes all requested KV blocks available with their expected contents. A failed or invalidated operation cannot later report success. |
| Ownership and cleanup | Each release applies to the correct operation and buffer allocation. Destination buffers cannot be reused while copies may still write them; source reuse must not allow incorrect data to be published. |
| Termination and resource release | Under stated scheduling assumptions, operations eventually succeed or fail. Eventual buffer release additionally depends on outstanding copies finishing; successful transfers depend on capacity and availability. |

## 3. Verification approach

### 3.1. Model the protocol as states and steps

Represent the protocol as a formal state-machine model in Lean: a precise
description of states and allowed steps on which to base proofs. States record
buffer allocation identities, pins and leases, copy progress, deadlines, and
result visibility. Steps define when operations such as granting a lease or
completing a copy are allowed and how they change the state. Allowing these steps
in different orders captures races between concurrent operations.

The model represents data symbolically, tracking whether copied contents match
the requested KV blocks. This captures errors caused by data movement and buffer
reuse without modeling numerical attention, assuming individual copies faithfully
transfer their source contents.

Ground the abstraction in TPU Sync's code: map model steps to implementation
operations, and state which failures, delays, and callback schedules the model
admits, together with any timing assumptions the proofs need.

Rejecting an invalid result does not stop an outstanding copy, so the model must
separate source lease validity from destination buffer lifetime.

### 3.2. Check modeled executions and prove safety in Lean

Lean is a programming language and proof assistant that supports executing the
model and checking mathematical proofs about it. The objective is to establish
whether the modeled protocol satisfies publication correctness under explicit
assumptions.

Use AI assistance to construct concrete executions covering normal transfers and
suspected races. Lean checks whether a sequence of steps follows the transition
rules and whether the resulting state satisfies the specification. An allowed
execution that violates publication correctness is a verified model
counterexample; successful executions confirm that the model permits useful work.

To establish safety across all modeled executions, prove invariants: conditions
that hold initially, are preserved by every allowed step, and imply publication
correctness. Define the correctness properties and assumptions explicitly, then
construct the proofs with AI assistance. Lean checks each proof step.

Termination requires a separate proof under explicit scheduling and
transfer-completion assumptions.

### 3.3. Replay executions between the model and TPU Sync

Translating model executions into deterministic TPU Sync tests, with AI
assistance, connects potential failures to code, most importantly by attempting
to reproduce counterexamples. Replay in the other direction tests the model
instead: map recorded TPU Sync executions onto model steps and apply §3.2's
execution check, where an execution the model rejects, or whose outcome it
disallows, means missing behavior or an overly restrictive assumption.

Retain traces from either direction as regression tests, prove repairs in the
model before testing the code changes, and recheck proofs after any model change.
Trace agreement is validation evidence, not a proof that all implementation
behavior is covered.

## 4. Deliverables

*   **A Lean model and proof suite**, with explicit correctness properties,
    assumptions, code correspondence, checked counterexamples where violations
    are found, and validation against recorded TPU Sync executions.
*   **Implementation tests and model validation**, covering replay in both
    directions, successful scenarios, and counterexample reproduction. Retain
    regression traces and include validated repairs where violations are
    reproduced.
*   **An AI-assisted verification workflow**: the agent loop that proposes
    executions, proofs, and tests and feeds Lean's rejections and test failures
    back as input; the agent setup that drives it (instruction files, skills,
    memory, tool integrations); and a record of where it needed human direction.
