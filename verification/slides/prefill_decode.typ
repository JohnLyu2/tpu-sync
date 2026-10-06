#import "lib.typ": *
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge

#show: deck.with(short: [Formal Verification of TPU Sync · prefill → decode transfer])

#title-slide([Formal Verification of TPU Sync])

// ---------------------------------------------------------------------------
#slide[TPU Sync: overview][
  TPU Sync is a library used by LLM inference and RL training systems on Cloud TPU. It manages large blocks of data — KV cache and model weights — and moves them between TPU memory, host memory and other machines. The transfers are asynchronous: the caller starts one, continues computing, and polls for completion.

  #v(0.7em)
  #let card(title, body) = grid.cell(fill: luma(246), inset: 12pt)[
    #text(fill: accent, weight: "medium", size: 16pt, title)
    #v(0.3em)
    #set text(size: 13pt)
    #set par(leading: 0.5em)
    #body
  ]
  #let case(label, body, hl: false) = block(
    width: 100%, inset: (x: 9pt, y: 7pt), radius: 2pt,
    fill: if hl { accent.lighten(86%) } else { white },
  )[#text(fill: if hl { accent } else { black }, weight: "medium", label) \ #body]
  #grid(
    columns: (1.5fr, 1fr, 0.8fr),
    column-gutter: 0.9em,
    card[KV transfer][
      Moves a request's KV cache from one worker to another. The cache is spread over a worker's chips, and there are two cases:
      #v(0.5em)
      #case(hl: true)[prefill → decode][Both workers have the same layout. Each chip sends its part to the matching chip on the other side; the transfers are independent of each other.]
      #v(0.4em)
      #case[reshard][The workers have different layouts. Each destination chip needs parts from several source chips, so a schedule computes who sends what to whom.]
    ],
    card[KV cache storage][
      Keeps finished requests' KV blocks so later requests with the same prefix can reuse them instead of recomputing.
      #v(0.5em)
      Blocks are stored across TPU memory, host DRAM and other hosts, found by a hash of their content, and copied back in on a hit.
    ],
    card[Weight sync][
      Copies model weights from RL trainers to samplers between training steps.
    ],
  )
]

// ---------------------------------------------------------------------------
#slide[Why formally verify TPU Sync?][
  TPU Sync moves KV caches and weights asynchronously across TPU memory, host DRAM, and the network while continuously recycling memory buffers across requests.

  #v(0.55em)
  #cols(columns: (1fr, 1fr))[
    #set list(spacing: 1.15em)
    *Why concurrency bugs are hard to catch*
    #v(0.2em)
    - *Asynchronous, multi-stage pipeline:* DMA copies, network pushes, callbacks, and cancellations interleave in arbitrary order.
    - *Aggressive buffer reuse:* TPU HBM and host staging DRAM are immediately recycled to new requests as soon as a transfer finishes or aborts.
    - *High-stakes failure modes:* Releasing a buffer one step too early causes *silent KV corruption*; missing a cleanup step on abort *leaks memory forever*.
  ][
    #set list(spacing: 1.15em)
    *Benefits of formal verification*
    #v(0.2em)
    - *Trust beyond unit tests:* Whereas a unit test checks one schedule at a time, a mechanized proof guarantees correctness across *every* thread, DMA, lock-drop, and abort interleaving.
    - *Clearer developer understanding:* Turns implicit C++ assumptions about locks, callbacks, and reference counts into explicit *invariants* that explain *why* the protocol is safe.
    - *Safer maintenance & refactoring:* Serves as a machine-checked guardrail when evolving or simplifying the code — catching broken invariants immediately at compile time.
  ]
]

// ---------------------------------------------------------------------------
#slide[Verification workflow in Lean 4][
  *Lean 4* is a functional programming language and interactive theorem prover that lets us both *execute* a system model on concrete test cases and *mathematically prove* properties across all possible executions:

  #v(1.8em)
  #let step-card(num, title, body) = block(
    fill: luma(248),
    stroke: 0.6pt + luma(220),
    radius: 4pt,
    inset: (x: 14pt, y: 16pt),
    width: 100%,
  )[
    #text(fill: accent, weight: "medium", size: 16pt)[#num · #title]
    #v(0.6em)
    #set text(size: 13.5pt)
    #set par(leading: 0.65em)
    #body
  ]

  #grid(
    columns: (1fr, auto, 1fr, auto, 1fr),
    column-gutter: 0.7em,
    step-card[1][Model the system][
      Choose the right *abstraction level* to capture the C++ concurrency and buffer-ownership logic as a state machine in Lean 4.
    ],
    align(center + horizon)[#text(size: 22pt, fill: accent.lighten(30%))[#sym.arrow.r]],
    step-card[2][Validate the model][
      Check that the model behaves like the real system: valid executions succeed, and injected bugs are caught.
    ],
    align(center + horizon)[#text(size: 22pt, fill: accent.lighten(30%))[#sym.arrow.r]],
    step-card[3][Prove correctness][
      Mathematically prove that core safety and progress guarantees hold across every possible execution schedule.
    ],
  )
]

// ---------------------------------------------------------------------------
#slide[prefill → decode transfer (single request)][
  For each request, the *prefill engine* computes the prompt's KV cache in *prefill HBM*, and the *decode engine* needs a copy in *decode HBM* to generate tokens. TPU Sync moves it in three steps, through a host staging buffer on each machine:

  #v(0.5em)
  #align(center, text(size: 14pt, diagram(
    spacing: (3.6em, 1.3em),
    node-stroke: 0.7pt + accent,
    node-shape: rect,
    node-inset: 8pt,
    node-corner-radius: 3pt,
    label-size: 13pt,
    label-sep: 4pt,
    node((0, 0), [prefill HBM\ `prefillHbm`]),
    node((1, 0), [prefill host staging\ `prefillStaging`]),
    node((2, 0), [network\ `wire`]),
    node((3, 0), [decode host staging\ `decodeStaging`]),
    node((4, 0), [decode HBM\ `decodeHbm`]),
    edge((0, 0), (1, 0), "->", [① D2H], label-side: left),
    edge((1, 0), (2, 0), "->", [② H2H], label-side: left),
    edge((2, 0), (3, 0), "->", [], label-side: left),
    edge((3, 0), (4, 0), "->", [③ H2D], label-side: left),
    node((0.5, 1), [`TransferSendSession` (prefill side)], stroke: none, fill: codebg),
    node((3.5, 1), [`TransferReceiveSession` (decode side)], stroke: none, fill: codebg),
  )))
  #v(0.6em)

  #cols(columns: (1fr, 1fr))[
    *Layer by layer.* The cache is not moved in one piece: each of the three steps above runs once per transformer layer.
    + *D2H* — copy, prefill HBM → host staging
    + *H2H* — push over TCP to the decode host's staging
    + *H2D* — copy, decode staging → decode HBM

    Steps start in layer order but finish in any order.
  ][
    *One session pair per request.* For each request, TPU Sync creates a session on each side (`TransferSendSession` and `TransferReceiveSession`) that counts the copies and pushes still running (`in_flight_`). Once told to finish — the last layer completes, an error, or a cancel — it starts no new ones (`draining_`), and when the count reaches zero it _settles_ (`done_`).

    The serving engines poll `poll_stats()` for the outcome:
    - `done_sending` — prefill engine may free its HBM
    - `done_recving` — decode engine may run attention
  ]
]

// ---------------------------------------------------------------------------
#slide[Buffer recycling across requests][
  In production, prefill and decode serve a continuous stream of requests $R_1, R_2, …$ that share four memory pools across two ownership boundaries:

  #v(0.3em)
  #table(
    columns: (auto, auto, 1fr),
    fill: (_, y) => if calc.odd(y) { accent.lighten(93%) } else { none },
    table.header[Buffer][Pool owner][When a request's buffer is recycled to a later request],
    [*Prefill HBM*],
    [Prefill serving engine],
    [As soon as prefill's `poll_stats()` reports `done_sending` or `failed_sending`, the prefill engine frees the HBM blocks and reuses them for a new request.],

    [*Prefill staging*],
    [TPU Sync `BufferPool`],
    [Inside `TransferSendSession::SettleLocked()`, the instant the send session settles (`done_ = true`) its host staging buffer is returned to `BufferPool` and reused.],

    [*Decode staging*],
    [TPU Sync `BufferPool`],
    [Inside `TransferReceiveSession::SettleLocked()`, the instant the receive session settles (`done_ = true`) its host staging buffer is returned to `BufferPool` and reused.],

    [*Decode HBM*],
    [Decode serving engine],
    [When decode's `poll_stats()` reports `done_recving`, the decode engine reads `decode HBM` for attention and then reallocates those HBM blocks to a later request (or immediately on `failed_recving`).],
  )

  #v(0.25em)
  Once a request releases a staging buffer or hands back an HBM buffer, a later request may immediately start reading and writing that same memory — so any straggling operation from the earlier request would corrupt the transfer.
]

// ---------------------------------------------------------------------------
#slide[What we want to prove — main theorems across requests][
  Across the entire stream of requests $R_1, R_2, …$ as TPU HBM and host staging buffers are continuously recycled, we prove three system-level theorems:

  #v(0.7em)
  - *Theorem 1 (Publication correctness):* When TPU Sync signals to the decode engine that $R_k$'s KV transfer succeeded, $R_k$'s decode HBM holds the correct KV cache from prefill across all transformer layers.

  #v(0.5em)
  - *Theorem 2 (Decoding safety):* Once TPU Sync signals that $R_k$'s KV transfer succeeded, nothing overwrites $R_k$'s decode HBM while the decode engine is decoding.

  #v(0.5em)
  - *Theorem 3 (Progress & no buffer leak):* Every started request $R_k$ (whether it succeeds, fails, or is cancelled) eventually settles both sessions and releases all four HBM and staging buffers for reuse.
]

// ---------------------------------------------------------------------------
#slide[Proof sketch — reducing multiple requests to a single request][
  Concurrent requests $R_1, R_2, …$ do not share session state — they interact _only_ when a buffer released by an earlier request is reused by a later request.

  #v(0.45em)
  This reduces *Theorems 1–3* across *all* requests to *three lemmas on a single request*:

  #v(0.55em)
  - *Lemma 1 (No buffer access after release):* Once a request releases _any_ of its four buffers, it never reads or writes that buffer again — so later requests can safely reuse released buffers, and decode HBM is never overwritten during decoding (*proves Theorem 2* and isolates requests).

  #v(0.45em)
  - *Lemma 2 (Single-request KV correctness):* If a request's active buffers are not overwritten by other requests, signaling transfer success guarantees its decode HBM holds the correct KV cache across all layers (*with Lemma 1, proves Theorem 1*).

  #v(0.45em)
  - *Lemma 3 (Single-request eventual drain):* Every request eventually finishes all in-flight operations, settles both sessions, and releases all four buffers (*proves Theorem 3*).
]

// ---------------------------------------------------------------------------
#slide[Proof sketch — Lemma 1: No buffer access after release][
  *Lemma 1:* Once a request releases any of its four buffers (prefill HBM, prefill staging, decode staging, or decode HBM), no copy or network push from that request ever reads or writes that buffer again.

  #v(0.45em)
  We prove *Lemma 1* from two invariants on each session's settle protocol (`in_flight_`, `draining_`, `done_`):

  #v(0.35em)
  - *Invariant 1a (Settle gate):* Buffers are released only when the session settles (`done_ = true`), which implies `draining_ == true` (no *future* operations can start) and `in_flight_ == 0`.

  #v(0.35em)
  - *Invariant 1b (`in_flight_` conservation):* `in_flight_` equals the exact sum of non-negative counters for active copies, callbacks, pool tasks, and network pushes (each stage claims the next `in_flight_` count before releasing its own).

  #v(0.45em)
  #sym.arrow.r.double *Together, Invariants 1a + 1b prove Lemma 1:* when any buffer is released, `in_flight_ == 0` forces every active operation counter to be `0`, and `draining_ == true` prevents any new operation from starting.
]

// ---------------------------------------------------------------------------
#slide[Proof sketch — Lemma 2: Single-request KV correctness][
  *Lemma 2:* Within a single request (assuming its active buffers are not overwritten by other requests), when transfer success is signaled, decode HBM holds the correct KV cache from prefill across all $L$ transformer layers — even when layers finish out of order.

  #v(0.45em)
  We prove *Lemma 2* from two invariants across the $L$ layers:

  #v(0.35em)
  - *Invariant 2a (Per-layer stage ordering):* For each layer, each stage along `prefill HBM` #sym.arrow.r `prefill staging` #sym.arrow.r `network` #sym.arrow.r `decode staging` #sym.arrow.r `decode HBM` starts only after that layer's previous stage finishes, while `in_flight_ > 0` keeps its source buffer from being released mid-operation.

  #v(0.35em)
  - *Invariant 2b (At-most-once layer counting):* The receive session increments a completed-layer counter on each H2D completion and signals success only when the counter reaches $L$; each of the $L$ layers increments this counter at most once.

  #v(0.45em)
  #sym.arrow.r.double *Together, Invariants 2a + 2b prove Lemma 2:* because each of the $L$ layers increments the counter at most once, reaching $L$ guarantees *every one of the $L$ layers* has finished H2D — and Invariant 2a ensures each layer in decode HBM holds the right KV cache from prefill.
]

// ---------------------------------------------------------------------------
#slide[Proof sketch — Lemma 3: Single-request eventual drain][
  *Lemma 3:* From any state of a request (normal completion, error, or mid-stream cancellation), all in-flight operations finish in finitely many steps (`in_flight_ == 0`), settling both sessions (`done_ = true`) and releasing all four buffers.

  #v(0.45em)
  We prove *Lemma 3* by combining an invariant with a well-founded ranking measure:

  #v(0.35em)
  - *Invariant 3 (No stuck operations):* Whenever `in_flight_ > 0`, at least one active operation counter is positive (by Invariant 1b) and its completion or abort step is enabled.

  #v(0.35em)
  - *Ranking measure (Bounded remaining work):* Once `draining_ = true` blocks new operations, every enabled step strictly decreases a `Nat` ranking function measuring remaining work across all $L$ layers.

  #v(0.45em)
  #sym.arrow.r.double *Together, Invariant 3 + the ranking measure prove Lemma 3:* from any state, setting `draining_ = true` guarantees `in_flight_` reaches `0` in finitely many steps, settling both sessions (`done_ = true`) and releasing all four buffers.
]

// ---------------------------------------------------------------------------
#slide[Modeling TPU Sync in Lean: abstraction levels][
  To mechanize this top-to-bottom proof in Lean, we model the top three levels of TPU Sync's transfer stack and abstract byte chunks into whole transformer layers:

  #v(0.2em)
  #table(
    columns: (auto, auto, 1fr, auto),
    fill: (_, y) => if y in (1, 2) { accent.lighten(90%) } else if y == 3 { accent.lighten(95%) } else { none },
    table.header[Component][Unit of data][What it does][In the Lean model],
    [*Manager & Engine*\ `KVCacheManagerWithTransfer`],
    [Whole request],
    [Polls settled sessions (`CompleteReadRaw` / `poll_stats()`), publishes `done_sending` / `done_recving`, frees prefill HBM, runs decode attention.],
    [*Modeled*],

    [*Transfer Sessions*\ `TransferSendSession`\ `TransferReceiveSession`],
    [Transformer\ layer],
    [Issues D2H and H2D copies per transformer layer, chains H2H pushes one layer at a time, tracks `in_flight_` / `draining_` / `done_`, owns host staging.],
    [*Modeled*],

    [*Block Transport*\ `BlockTransport`],
    [KV block →\ layer],
    [Counts arrived KV blocks for each transformer layer and notifies the receive session (`begin/end_incoming_push`, `OnLayerReceived(l)` when all blocks of layer $l$ land, `OnBlocksReceived`).],
    [*Callbacks modeled;*\ blocks abstracted],

    [*Raw Buffer Transport*\ `RawBufferTransport`],
    [Byte chunk /\ TCP socket],
    [Splits host staging buffers into network chunks and streams them across parallel TCP/PSP connections.],
    [Abstracted],
  )

  #v(0.2em)
  Because every session decision (`StartPush`, `SendNextLayer(l)`, `OnLayerReceived(l)`, `ExecuteLayerH2d(l)`) acts on a complete *transformer layer*, the Lean model tracks one slot per transformer layer rather than individual KV blocks or TCP chunks.
]

// ---------------------------------------------------------------------------
#slide[Modeling state: module hierarchy & layer-indexed memories][
  The Lean formalization builds the system state in four modular layers from top-level requests down to primitive session locks:

  #v(0.3em)
  #cols(columns: (0.85fr, 1.45fr))[
    #v(0.4em)
    #align(center, text(size: 13pt, diagram(
      spacing: (1.5em, 1.25em),
      node-stroke: 0.7pt + accent,
      node-shape: rect,
      node-inset: 6pt,
      node-corner-radius: 3pt,
      node((0.5, 0), [*`MultiRequest`*\ #small[`reqs : List Pipeline`]]),
      node((0.5, 1), [*`Pipeline`*\ #small[5 `List Cell` memories]]),
      node((0, 2), [*`Send`*\ #small[prefill counters]]),
      node((1, 2), [*`Receive`*\ #small[decode counters]]),
      node((0.5, 3), [*`Session`*\ #small[shared `Lifecycle`]]),
      edge((0.5, 0), (0.5, 1), "->"),
      edge((0.5, 1), (0, 2), "->"),
      edge((0.5, 1), (1, 2), "->"),
      edge((0, 2), (0.5, 3), "->"),
      edge((1, 2), (0.5, 3), "->"),
    )))
  ][
    #table(
      columns: (auto, 1fr),
      inset: (x: 8pt, y: 7pt),
      table.header[Layer][State represented in the model],
      [*`MultiRequest`*], [
        #set list(spacing: 0.55em)
        - `reqs : List Pipeline` (stream of concurrent requests)
        - Cross-request buffer recycling & write-release detection
      ],
      [*`Pipeline`*], [
        #set list(spacing: 0.55em)
        - 5 memories of length $L$ (`List Cell` per layer)
        - `Cell` is `.kv l` (valid layer $l$), `.blank`, or `.junk`
      ],
      [*`Send`* /\ *`Receive`*], [
        #set list(spacing: 0.55em)
        - Counters for active DMA copies, pushes, and pool tasks
        - Tracks mutex-drop windows and completion callbacks
      ],
      [*`Session`*], [
        #set list(spacing: 0.55em)
        - `inFlight` counter, `draining`, `done`, `statusOk`
        - Settle gate: releases staging iff `inFlight == 0`
      ],
    )
  ]
]

// ---------------------------------------------------------------------------
#slide[Modeling actions: non-deterministic events & async steps][
  We model concurrent C++ threads, DMA streams, and network callbacks as a non-deterministic transition system `step(state, event)` where any enabled event can fire next:

  #v(0.4em)
  #table(
    columns: (1fr, 1fr),
    inset: (x: 10pt, y: 8.5pt),
    table.header[*Concurrency in the C++ implementation*][*How the Lean state machine models it*],
    [
      *Out-of-order async DMA & network:*\
      D2H and H2D device futures resolve in arbitrary layer order; parallel TCP pushes arrive out of order.
    ],
    [
      *Split `Issue` vs. `Ready` events:*\
      Decouples dispatch from completion so transformer layers $0 dots L-1$ advance and complete independently.
    ],
    [
      *Fine-grained locking & thread handoffs:*\
      Mutexes are dropped during blocking dispatches and re-acquired before updating session state.
    ],
    [
      *Explicit lock-gap states:*\
      Models unlock/re-lock windows with intermediate ghost states (e.g., `ExecuteLayerH2d` lock gap).
    ],
    [
      *Cancellations, polls & buffer recycling:*\
      Deadlines, peer disconnects, `poll_stats()`, and buffer reuse fire asynchronously across requests.
    ],
    [
      *Non-deterministic transitions:*\
      Any active DMA, callback, cancellation, poll, or buffer-recycle step (`reclaim`, `reseat`, `recycle`) can fire next.
    ],
  )
]

// ---------------------------------------------------------------------------
#slide[Example: how steps update memories & catch bugs][
  #let cell-kv = box(fill: rgb("#e6f4ea"), stroke: 0.7pt + rgb("#137333"), inset: (x: 6pt, y: 2.5pt), radius: 3pt)[#text(fill: rgb("#137333"), weight: "bold", size: 10.5pt)[`kv l`]]
  #let cell-blank = box(fill: rgb("#f1f3f4"), stroke: 0.7pt + rgb("#5f6368"), inset: (x: 6pt, y: 2.5pt), radius: 3pt)[#text(fill: rgb("#5f6368"), size: 10.5pt)[`blank`]]
  #let cell-junk = box(fill: rgb("#fce8e6"), stroke: 0.7pt + rgb("#c5221f"), inset: (x: 6pt, y: 2.5pt), radius: 3pt)[#text(fill: rgb("#c5221f"), weight: "bold", size: 10.5pt)[`junk`]]

  *Normal execution (`0 → 1 → 2 → 3 → 4 → 5`):* #h(0.3em) #cell-kv valid layer-$l$ KV #h(0.4em) #cell-junk stale / recycled DRAM #h(0.4em) #cell-blank unwritten wire

  #v(0.3em)
  #align(center)[
    #text(size: 11pt)[
      #table(
        columns: (auto, auto, 1.05fr, 1.35fr, 0.65fr, 1.3fr, 1fr),
        align: (left + horizon, left + horizon, center + horizon, center + horizon, center + horizon, center + horizon, center + horizon),
        inset: (x: 6pt, y: 5.5pt),
        table.header[Step (layer $l$)][Memory update][`prefillHbm`][`prefillStaging`][`wire`][`decodeStaging`][`decodeHbm`],
        [*0. Initial state*], [Staging & decode start as `junk`], [#cell-kv], [#cell-junk], [#cell-blank], [#cell-junk], [#cell-junk],
        [*1. `d2hReady l`*], [`prefillStaging[l] := prefillHbm[l]`], [#cell-kv], [#cell-kv], [#cell-blank], [#cell-junk], [#cell-junk],
        [*2. `h2hDone l`*], [`wire[l] := prefillStaging[l]`], [#cell-kv], [#cell-kv], [#cell-kv], [#cell-junk], [#cell-junk],
        [*3. `land l`*], [`decodeStaging[l] := wire[l]`], [#cell-kv], [#cell-kv], [#cell-kv], [#cell-kv], [#cell-junk],
        [*4. `h2dReady l`*], [`decodeHbm[l] := decodeStaging[l]`], [#cell-kv], [#cell-kv], [#cell-kv], [#cell-kv], [#cell-kv],
        [*5. `reclaim` / `reseat`*], [Released buffers reset to `junk`], [#cell-junk], [#cell-junk], [#cell-kv], [#cell-junk], [#cell-kv],
      )
    ]
  ]

  #v(0.35em)
  *Why any concurrency bug produces `decodeHbm[l] =` #cell-junk (steps firing in the wrong order):*
  #set list(spacing: 0.45em)
  - *Out-of-order copy (e.g. Step `4` before `3`):* `h2dReady l` runs before `land l`, reading initial #cell-junk from `decodeStaging[l]` into `decodeHbm[l]`.
  - *Read-after-release (Step `5` before `4`):* Early `reseat` resets `decodeStaging[l]` to #cell-junk while H2D is in flight; `h2dReady l` then copies #cell-junk into `decodeHbm[l]`.
  - *Write-after-release (Step `5` before `3`):* `land l` writes to `decodeStaging` after `reseat` released it; the model's `wroteReleased` check catches the late write and sets `decodeHbm[l]` to #cell-junk.
]



// ---------------------------------------------------------------------------
#slide[Validating the model: translating unit tests to Lean][
  To check that the Lean model faithfully captures the production C++ behavior (without over-constraining valid runs), we replay all 52 `tpu-sync` unit and E2E tests inside the model before proving general theorems:

  #v(0.25em)
  #let pill(title, sub) = block(
    fill: luma(246), stroke: 0.6pt + luma(220), radius: 4pt,
    inset: (x: 12pt, y: 9pt), width: 100%,
  )[
    #text(fill: accent, weight: "medium", size: 15pt, title)\
    #v(0.15em)
    #text(size: 13pt, sub)
  ]
  #grid(
    columns: (1fr, auto, 1fr, auto, 1fr),
    column-gutter: 0.6em,
    pill[1 · Production test][Tests *one* fixed schedule in C++ or Python (`52` tests total)],
    align(center + horizon)[#text(size: 20pt, fill: accent.lighten(30%))[#sym.arrow.r]],
    pill[2 · Lean trace (`by decide`)][Executes that exact scenario step-by-step inside the Lean model],
    align(center + horizon)[#text(size: 20pt, fill: accent.lighten(30%))[#sym.arrow.r]],
    pill[3 · Lean theorem][Proves the property holds across *every* thread & DMA schedule],
  )

  #v(0.35em)
  *Example: mid-H2D failure on a 2-layer receive (`FailedLayerWaitsForOtherH2dCopies`)*
  #v(0.2em)
  #cols(columns: (0.94fr, 1.06fr))[
    #block(fill: luma(247), stroke: 0.5pt + luma(222), radius: 4pt, inset: 11pt, width: 100%)[
      #text(fill: accent, weight: "medium", size: 14pt)[C++ unit test (`..._send_drain_test.cc`)]
      #v(0.3em)
      #set text(size: 13pt)
      #set list(spacing: 0.55em)
      - Issues H2D copies for *Layer 0* and *Layer 1*.
      - *Layer 0 fails* while *Layer 1* is still copying.
      - Asserts that staging stays pinned (`!done()`) and failure is not published until *Layer 1* finishes.
      - #text(fill: muted)[Covers $L = 2$ and 1 failure order.]
    ]
  ][
    #set text(size: 11.5pt)
    ```lean
    -- 1. Executable trace (replays C++ test)
    theorem trace_failed_h2d_waits_for_other_layer :
      ∃ s1 s2,
        run 2 init2 [..., h2dCallback false] = some s1 ∧
        !s1.life.done ∧ s1.life.hasStaging ∧
        run 2 s1 [h2dReady, h2dCallback true,
                  pollPublish] = some s2 ∧
        s2.life.done ∧ s2.published = some false := by decide
    -- 2. General theorem (all L & all schedules)
    theorem reachable_safe : Reachable n s →
      SettleSafe s ∧ StagingIntegrity s
    ```
  ]
]

// ---------------------------------------------------------------------------
#slide[Validating the model: 52 production tests covered in Lean][
  #v(0.15em)
  #let cat(title, count, mod, bullets) = block(
    fill: luma(247), stroke: 0.5pt + luma(222), radius: 4pt,
    inset: (x: 12pt, y: 9pt), width: 100%,
  )[
    #grid(
      columns: (1fr, auto),
      text(fill: accent, weight: "medium", size: 14pt, title),
      text(size: 11.5pt, fill: muted)[#count · #mod],
    )
    #v(0.25em)
    #set text(size: 12.5pt)
    #set par(leading: 0.45em)
    #set list(spacing: 0.4em)
    #bullets
  ]

  #grid(
    columns: (1fr, 1fr),
    column-gutter: 0.9em,
    row-gutter: 0.65em,
    cat[1 · Session drain & leases][21 C++][`Send` / `Receive`][
      - Mid-copy failures & deadlines wait for all in-flight DMA copies
      - Incoming TCP push leases pin host staging; first `Finish` wins
    ],
    cat[2 · Control handshake][6 C++][`Send` / `Pipeline`][
      - Pulls arriving ahead of `NotifyForRead` wait and succeed once registered
      - Rejects duplicate or unregistered pulls; shutdown unblocks waiters
    ],
    cat[3 · Block gather & reordering][7 C++ · 3 E2E][`BlockOrdering`][
      - Rejects empty, duplicate, or unregistered block IDs on pull
      - Proves DMA coalescing & dual-permutation `BuildLoadCopyPlan`
    ],
    cat[4 · UUID drain-before-reuse][4 C++][`UuidTable`][
      - Expired receive (`draining && !done`) blocks UUID reuse until drained
      - Protects live send offers; idempotent on repeated same-request reads
    ],
    cat[5 · Multi-peer fault isolation][5 C++][`PeerIsolation`][
      - Models TCP worker-pool blocking (Issue \#888) vs. async gRPC
      - Per-peer staging quota stops a wedged peer from starving others
    ],
    cat[6 · Multi-layer & multi-request][3 E2E][`MultiRequest`][
      - Out-of-order layer completion across D2H, H2H, and H2D stages
      - Continuous HBM & host staging recycling across concurrent requests
    ],
  )
]

// ---------------------------------------------------------------------------
#slide[Validating the model: mutant checks][
  #let cell-junk = box(fill: rgb("#fce8e6"), stroke: 0.7pt + rgb("#c5221f"), inset: (x: 6pt, y: 2.5pt), radius: 3pt)[#text(fill: rgb("#c5221f"), weight: "bold", size: 10.5pt)[`junk`]]

  We also test *mutant models*—removing one C++ guard at a time—to check that Lean catches the resulting bug:

  #v(0.5em)
  #table(
    columns: (0.78fr, 1.22fr),
    inset: (x: 10pt, y: 11pt),
    align: (left + horizon, left + horizon),
    table.header[*Dropped C++ guard (mutant)*][*Bug caught automatically by Lean*],
    [*Settle without waiting for `inFlight == 0`*],
    [Session settles and frees staging while a DMA copy or push is running.],
    [*Release staging at `Finish()` instead of settle*],
    [In-flight push reads released staging and delivers #cell-junk to `decodeHbm`.],
    [*Start H2D before layer $l$ lands*],
    [H2D reads `decodeStaging[l]` early and copies #cell-junk into `decodeHbm[l]`.],
    [*Skip `--inFlight` on early abort*],
    [`inFlight` never reaches `0`, leaving the session stuck `draining` forever.],
  )
]

