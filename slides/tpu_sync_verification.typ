#import "lib.typ": *
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge

#show: deck.with(short: [Formal Verification of TPU Sync])

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
      #case(hl: true)[reshard][The workers have different layouts. Each destination chip needs parts from several source chips, so a schedule computes who sends what to whom.]
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
    [As soon as prefill's `poll_stats()` reports `done_sending` or `failed_recving`, the prefill engine frees the HBM blocks and reuses them for a new request.],

    [*Prefill staging*],
    [TPU Sync `StagingBlockAllocator`],
    [Inside `TransferSendSession::FinishLocked()` / `EndSendOpLocked()` (`Lifecycle.settleLocked`), the instant the send session settles (`done_ = true`) its host staging buffer is returned to `StagingBlockAllocator` and reused.],

    [*Decode staging*],
    [TPU Sync `StagingBlockAllocator`],
    [Inside `TransferReceiveSession::FinishLocked()` / `EndRecvOpLocked()` (`Lifecycle.settleLocked`), the instant the receive session settles (`done_ = true`) its host staging buffer is returned to `StagingBlockAllocator` and reused.],

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
  #show table: set text(size: 13pt)
  #table(
    columns: (auto, auto, 1fr, auto),
    inset: (x: 8pt, y: 4.5pt),
    fill: (_, y) => if y in (1, 2, 3) { accent.lighten(90%) } else { none },
    table.header[Component][Unit of data][What it does][In the Lean model],
    [*Manager & Engine*\ `KVCacheManagerWithTransfer`],
    [Whole request],
    [Polls settled sessions (`CompleteReadRaw` / `poll_stats()`), publishes `done_sending` / `done_recving`; the serving engine frees prefill HBM and runs decode attention.],
    [*Modeled*\ `MultiRequest`, `Caller`],

    [*Transfer Sessions*\ `TransferSendSession`\ `TransferReceiveSession`],
    [Transformer\ layer],
    [Issues D2H and H2D copies per transformer layer, chains H2H pushes one layer at a time, tracks `in_flight_` / `draining_` / `done_`, owns host staging.],
    [*Modeled*\ `Send`, `Receive`],

    [*Block Transport*\ `BlockTransport`],
    [KV block →\ layer],
    [Counts arrived KV blocks and streams per transformer layer and notifies the receive session (`begin/end_incoming_push`, `OnLayerReceived(l)`, `OnBlockShardsReceived`).],
    [*Modeled*\ `Transport`, `BlockOrdering`],

    [*Raw Buffer Transport*\ `RawBufferTransport`],
    [Byte chunk /\ TCP socket],
    [Splits host staging buffers into network chunks and streams them across parallel TCP/PSP connections.],
    [Abstracted],
  )

  #v(0.2em)
  Because every session decision (`StartPush`, `SendNextLayer(l)`, `OnLayerReceived(l)`, `ExecuteLayerH2d(l)`) acts on a complete *transformer layer*, `Pipeline` tracks one slot per layer, while `Transport` and `BlockOrdering` refine each layer into network streams and blocks.
]

// ---------------------------------------------------------------------------
#slide[Modeling state: module hierarchy & layer-indexed memories][
  The model builds the system state in four composable layers, from concurrent requests down to the shared session settle protocol:

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
      inset: (x: 8pt, y: 8pt),
      table.header[Layer][Role in the state hierarchy],
      [*`MultiRequest`*], [
        Stream of concurrent/overlapped transfers (`reqs : List Pipeline`) sharing HBM and host staging pools; tracks post-release writes (`wroteReleased`).
      ],
      [*`Pipeline`*], [
        One end-to-end transfer: embeds `Send` + `Receive`, the 5 layer-indexed memories (`List Cell` of length $L$), and per-layer completion flags.
      ],
      [*`Send`* /\ *`Receive`*], [
        Per-session scalar counters for active DMA copies, TCP pushes, and mutex-drop windows (`TransferSendSession` / `TransferReceiveSession`).
      ],
      [*`Session`*], [
        Shared settle state (`Lifecycle`): tracks `inFlight`, `draining`, `done`, and `hasStaging` (releases staging iff `draining && inFlight == 0`).
      ],
    )
  ]

  #v(0.2em)
  #text(size: 13pt)[Around this core: `Caller` models the serving engine above `MultiRequest` (vLLM scheduler + connector), and `Transport` / `BlockOrdering` refine `Receive`'s network callbacks into streams and blocks.]
]

// ---------------------------------------------------------------------------
#slide[Modeling state in Lean: structures & memories][
  Each layer is a Lean `structure` embedding the layer below (`Session.lean` #sym.arrow.r `Pipeline.lean`):

  #v(0.25em)
  #show raw.where(block: true): set text(size: 11pt)
  ```lean
  -- One layer slot of a memory: .kv l (valid layer-l KV), .blank (unwritten wire), or .junk (stale / recycled)
  inductive Cell | blank | kv (layer : Nat) | junk

  -- Shared session settle state (Session.lean)
  structure Lifecycle where
    inFlight   : Nat  := 0
    draining   : Bool := false
    done       : Bool := false
    hasStaging : Bool := true

  -- Single-request pipeline state (Pipeline.lean)
  structure Pipeline where
    send : Send      recv : Recv
    -- 5 fixed-length L memories (one slot per layer 0..L-1, updated in place)
    prefillHbm     : List Cell  -- init: [kv 0, kv 1, ...]
    prefillStaging : List Cell  -- init: [junk, junk, ...]
    wire           : List Cell  -- init: [blank, blank, ...]
    decodeStaging  : List Cell  -- init: [junk, junk, ...]
    decodeHbm      : List Cell  -- init: [junk, junk, ...]
    -- Per-Layer Bool flags (length L: tracks which specific layer l finished out of order)
    landedL        : List Bool
    h2dIssuedL     : List Bool  h2dReadyL : List Bool
  ```
]

// ---------------------------------------------------------------------------
#slide[Modeling actions: non-deterministic events & async steps][
  Concurrent C++ threads, DMA streams, and callbacks are modeled as a transition function `step(state, event)` where any enabled event can fire next:

  #v(0.4em)
  #table(
    columns: (1fr, 1fr),
    inset: (x: 10pt, y: 8.5pt),
    table.header[*Concurrency in C++*][*How the Lean state machine models it*],
    [
      *Out-of-order async DMA & network:*\
      D2H/H2D futures and parallel TCP pushes finish in arbitrary layer order.
    ],
    [
      *Split `Issue` vs. `Ready` events per layer $l$:*\
      Separates dispatch from completion so layers $0 dots L-1$ finish in any order.
    ],
    [
      *Mutex-drop windows:*\
      Session locks are dropped during blocking DMA dispatches and re-acquired afterwards.
    ],
    [
      *Explicit two-step transitions:*\
      Splits lock–unlock–relock sequences (e.g. `h2dBegin l` #sym.arrow.r `h2dIssue l`) so events can interleave in the gap; every event is audited against the `mu_` scopes it stands for.
    ],
    [
      *Async timeouts, polls & buffer reuse:*\
      Deadlines, `poll_stats()`, and allocator reuse happen concurrently with transfers.
    ],
    [
      *Non-deterministic environment steps:*\
      `cancel`, `pollReady`, `reclaim`, and `reseat` can fire whenever their guard is satisfied.
    ],
  )
]

// ---------------------------------------------------------------------------
#slide[Modeling actions in Lean: events & `step` transitions][
  `step : Pipeline → Ev → Option Pipeline` returns `none` when blocked by a guard, or `some s'` with the updated state:

  #v(0.25em)
  #show raw.where(block: true): set text(size: 11pt)
  ```lean
  -- Any enabled event can fire next (Pipeline.lean)
  inductive Ev
    | d2hReady (l : Nat) | h2hDone (l : Nat) (ok : Bool)
    | land (l : Nat)     | h2dBegin (l : Nat)
    | h2dIssue (l : Nat) (ok : Bool) | h2dReady (l : Nat)
    | reclaim            | reseatDecodeStaging | ...

  -- H2D copy for layer l finishes: copies decodeStaging[l] → decodeHbm[l]
  def h2dReady (s : Pipeline) (l : Nat) : Option Pipeline :=
    if s.h2dIssuedL[l]? = some true ∧ s.h2dReadyL[l]? = some false then
      (Recv.step s.recv .h2dReady).map fun rcv =>
        { s with recv := rcv,
                 h2dReadyL := s.h2dReadyL.set l true,
                 decodeHbm := s.decodeHbm.set l (s.decodeStaging.getD l .junk) }
    else none

  -- Released staging buffer is recycled by next request: resets decodeStaging to .junk
  def reseatDecodeStaging (s : Pipeline) : Option Pipeline :=
    if s.recv.life.hasStaging = false then
      some { s with decodeStaging := List.replicate s.numLayers .junk }
    else none
  ```
]

// ---------------------------------------------------------------------------
#slide[Modeling actions: how big is one event?][
  #set par(leading: 0.62em)
  #let mono(body) = align(left, text(font: "DejaVu Sans Mono", size: 14pt, body))
  A Lean event is atomic, so each event stands for *one critical section* of the session's lock `mu_`. When a function releases `mu_` partway through, other threads can run in the gap, so the Lean model may split the function there.

  #v(0.4em)
  *Example: `TransferReceiveSession::ExecuteLayerH2d`* — runs once layer $l$ has fully arrived in decode host staging, and copies it into decode HBM.
  #set list(spacing: 0.45em)
  #text(size: 13.5pt)[
  - `in_flight_` counts work in progress; staging is freed only when it reaches 0.
  - `draining_` is set once the receive finishes, for any reason; no new work may start after that.
  ]

  #v(1.2em)
  #align(center, text(size: 14pt, diagram(
    spacing: (3em, 1.1em),
    node-stroke: 0.7pt + accent,
    node-shape: rect,
    node-inset: 10pt,
    node-corner-radius: 3pt,
    label-size: 14pt,
    node((0, 0), mono[lock(mu\_)\ if draining\_: return\ ++in\_flight\_]),
    node((2, 0), mono[lock(mu\_)\ if draining\_:\ #h(1.2em)\-\-in\_flight\_; return\ start the copy]),
    edge((0, 0), (2, 0), "-->", [unlocked], label-side: left),
    node((0, 1), [`h2dBegin l`], stroke: none, fill: codebg),
    node((2, 1), [`h2dIssue l`], stroke: none, fill: codebg),
    node((1, 1), text(fill: accent)[#sym.arrow.t another thread may\ finish the receive here], stroke: none),
  )))

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
  *How wrong step orderings automatically produce #cell-junk (or trip `wroteReleased`):*
  #set list(spacing: 0.45em)
  - *Out-of-order copy (Step `4` before `3`):* `h2dReady l` runs before `land l` and copies initial #cell-junk from `decodeStaging[l]` into `decodeHbm[l]`.
  - *Read-after-release (Step `5` before `4`):* Early `reseat` overwrites `decodeStaging[l]` with #cell-junk while H2D is still in flight; `h2dReady l` then copies #cell-junk into `decodeHbm[l]`.
  - *Write-after-release (Step `5` before `3`):* `land l` arrives after `reseat` released `decodeStaging`, tripping `wroteReleased` and corrupting the buffer to #cell-junk.
]

// ---------------------------------------------------------------------------
#slide[Model boundary: the serving engine above `poll_stats()`][
  #v(0.6em)
  #set text(size: 17pt)
  #set par(leading: 0.65em)
  #set list(spacing: 0.9em)

  #text(fill: muted)[vLLM scheduler + tpu-inference connector]

  #v(0.9em)
  The proofs initially assumed:
  - Decode reads a request's KV from HBM only after `poll_stats()` reports `done_recving`.
  - Prefill frees a request's HBM only after its send is reported finished.
  - Every reported outcome, success or failure, leads the engine to free that request's blocks.

  #v(0.9em)
  We then modeled the engine to check these assumptions, and found that the shipping connector drops failed outcomes, so KV blocks leak on both nodes; we reproduced it and reported it.

  #v(0.9em)
  The engine model still assumes one connector worker per node; multi-host decode, where several workers' reports are combined, isn't modeled yet.
]

// ---------------------------------------------------------------------------
#slide[Model boundary: the network transport][
  #v(0.6em)
  #set text(size: 17pt)
  #set par(leading: 0.65em)
  #set list(spacing: 0.9em)

  `BlockTransport`'s stream accounting is modeled: it counts the KV streams arriving for each layer and tells the session when the layer has fully arrived.

  #v(0.9em)
  Below it, the proofs assume:
  - each prefill sender sends no more streams per layer than it declared;
  - each stream lands in staging as one unit. Socket reads, wire framing and timeouts aren't modeled.
]

// ---------------------------------------------------------------------------
#slide[Validating the model: translating unit tests to Lean][
  To check that the Lean model faithfully captures the production C++ behavior (without over-constraining valid runs), we replay all 71 `tpu-sync` unit and E2E tests inside the model before proving general theorems:

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
    pill[1 · Production test][Tests *one* fixed schedule in C++ or Python (`71` tests total)],
    align(center + horizon)[#text(size: 20pt, fill: accent.lighten(30%))[#sym.arrow.r]],
    pill[2 · Lean trace (`by decide`)][Executes that exact scenario step-by-step inside the Lean model],
    align(center + horizon)[#text(size: 20pt, fill: accent.lighten(30%))[#sym.arrow.r]],
    pill[3 · Lean theorem][Proves the property holds across *every* thread & DMA schedule],
  )

  #v(0.3em)
  *Example: mid-H2D failure on a 2-layer receive (`FailedLayerWaitsForOtherH2dCopies`)*
  #v(0.2em)
  #cols(columns: (0.80fr, 1.20fr))[
    #block(fill: luma(247), stroke: 0.5pt + luma(222), radius: 4pt, inset: 11pt, width: 100%)[
      #text(fill: accent, weight: "medium", size: 14pt)[C++ unit test (`..._send_drain_test.cc`)]
      #v(0.3em)
      #set text(size: 13pt)
      #set list(spacing: 0.55em)
      - Issues H2D copies for *Layer 0* and *Layer 1*.
      - *Layer 0 fails* while *Layer 1* is still copying.
      - Asserts that staging stays pinned (`!Done()`) and failure is not published until *Layer 1* finishes.
      - #text(fill: muted)[Covers $L = 2$ and 1 failure order.]
    ]
  ][
    ```lean
    -- 1. Executable trace (replays C++ test)
    theorem trace_failed_h2d_waits_for_other_layer :
      let pre := [..., .h2dReady, .h2dDone false]
      ((sysPush 2).run pre).map (fun s =>
        (!s.life.done, s.life.hasStaging)) = some (true,true) ∧
      ((sysPush 2).run (pre ++ [.h2dReady, .h2dDone true,
                                .publish])).map (fun s =>
        (s.life.done, s.published)) = some (true, some false)
        := by decide
    -- 2. General theorem (all L & all schedules)
    theorem reachable_safe : (sysPush n).Reachable s → Safe s
    ```
  ]
]

// ---------------------------------------------------------------------------
#slide[Validating the model: 71 production tests covered in Lean][
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
    cat[1 · Session drain & leases][40 C++][`Send` / `Receive`][
      - Mid-copy failures, deadlines & push failures wait for all in-flight DMA copies
      - Incoming TCP push leases pin host staging; first `Finish` wins
    ],
    cat[2 · Control handshake][10 C++][`Send` / `Receive` / `Pipeline`][
      - Pulls arriving ahead of `NotifyForRead` wait and succeed once registered
      - Rejects duplicate, expired or unregistered pulls; shutdown unblocks waiters
    ],
    cat[3 · Block gather & reordering][5 C++ · 3 E2E][`BlockOrdering`][
      - Rejects empty, duplicate, or unregistered block IDs on pull
      - Proves DMA coalescing & dual-permutation `BuildLoadCopyPlan`
    ],
    cat[4 · UUID drain-before-reuse][4 C++][`UuidTable`][
      - Expired receive (`draining && !done`) blocks UUID reuse until drained
      - Protects live send offers; idempotent on repeated same-request reads
    ],
    cat[5 · Multi-peer fault isolation][4 C++][`PeerIsolation`][
      - Models TCP worker-pool blocking (Issue \#888) vs. async gRPC
      - Per-peer staging quota stops a wedged peer from starving others
    ],
    cat[6 · Multi-layer & multi-request][3 C++ · 2 E2E][`Pipeline` / `MultiRequest`][
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

// ---------------------------------------------------------------------------
#slide[Stopping criterion & coverage: Arie's comment & the QUIC paper][
  Replaying existing unit tests has no stopping criterion — inspired by McMillan & Zuck (_QUIC_, SIGCOMM '19), we measure three kinds of coverage:

  #v(0.4em)
  #show table: set text(size: 13.8pt)
  #table(
    columns: (0.88fr, 1.12fr),
    inset: (x: 11pt, y: 12pt),
    align: (left + horizon, left + horizon),
    table.header[*Coverage criterion*][*What we built & found*],
    [*1. Model branch coverage (`Coverage.lean`)* — what fraction of reachable `(event, branch)` paths in `step` do the 71 tests hit?],
    [Exhaustively computed and `#guard`-pinned: e.g. `Receive` hits *18 / 37* branches; `MultiRequest` has *0* unit tests recycling buffers mid-flight; exposed *1 dead C++ branch*.],
    [*2. Spec-driven gap tests* — generate concrete schedules from the model for uncovered branches and run them on C++.],
    [Lean emits a shortest witness schedule per gap (*missing test* vs. *lock window*) #sym.arrow.r turned drivable gaps into *9 new C++ unit tests*.],
    [*3. Guard / mutant coverage (`Guards.lean`)* — mutate _every_ C++ guard in `step` (not just a few examples) against `Safe`.],
    [Mutating every guard in `Receive` and `Send` caught a missing clause in our own session `Safe` (early _failed_ publication while copies run #sym.arrow.r added `PublishedQuiet`).],
  )
]

// ---------------------------------------------------------------------------
#slide[Closing the C++ #sym.arrow.l.r Lean gap: Aosen's comments][
  #v(0.4em)
  #show table: set text(size: 14pt)
  #table(
    columns: (0.96fr, 1.04fr),
    inset: (x: 11pt, y: 15pt),
    align: (left + horizon, left + horizon),
    table.header[*Gap pointed out & Aosen's suggestion*][*Our check & response*],
    [*1. Lean _assumes_ events are atomic (no data races)* — discharge this premise in C++ with `GUARDED_BY(mu)` + TSan (rather than modeling locks in Lean).],
    [Session headers already carry 80+ `ABSL_GUARDED_BY` annotations. *Extra gap `GUARDED_BY` misses:* holding `mu_` per access doesn't guarantee 1 event = 1 lock scope — so we audited all 12 models, proving multi-lock cleanup tails commute and splitting open windows.],
    [*2. Lean _assumes_ sequential consistency* — check whether `tpu-sync` uses weak atomic orderings (`memory_order_relaxed`, acquire/release) on modelled paths.],
    [*Checked — safe.* Shared state on modelled paths uses mutexes and default sequentially consistent atomics (no lock-free weak-memory protocols).],
    [*3. Lean `step` is hand-transcribed from C++* — connect them mechanically by logging events in C++ tests and replaying logs through executable `step`.],
    [*Planned next — with one catch:* logs (or a sequence number) must be recorded *inside* `mu_`, otherwise preemption right after `unlock` can invert log order relative to step order.],
  )
]

// ---------------------------------------------------------------------------
#slide[Case study: removing the extra `IsReadyToComplete` check][
  #v(0.3em)
  #set text(size: 14pt)
  #set par(leading: 0.65em)
  #set list(spacing: 0.75em)

  *1. The extra check*
  - `TransferReceiveSession` has two completion paths: the last H2D callback (like `TransferSendSession`), *plus* an external poll check `IsReadyToComplete()`.
  - *Question:* Does the poll check ever speed up completion or cover a case the callbacks miss — and can we remove it safely?

  #v(0.4em)
  *2. How the Lean model helped (`ReceivePoll.lean`)*
  - *Proved redundant for progress:* Even when `IsReadyToComplete()` fires early, the session still waits for the last in-flight callback (`in_flight_ > 0`); all safety and liveness theorems hold without it.
  - *Found a hidden metrics bug:* When the poll wins the narrow race before the last callback runs, it sets `draining_` early and causes the callback to silently skip recording transfer metrics.
  - *Caught the one edge case:* Proving liveness without the poll exposed `num_layers == 0` (where no callback runs), showing we only need to finish 0-layer receives at creation.

  #v(0.4em)
  *3. Result*
  - Safely removes the poll check and its bookkeeping state while fixing the metrics race.
]

// ---------------------------------------------------------------------------
#slide[Lean-backed AI agent (`raiden-lean-helper`)][
  #v(0.3em)
  #set text(size: 14.5pt)
  #set par(leading: 0.65em)
  #set list(spacing: 0.85em)

  A subagent that lets engineers and coding agents query the Lean formalization in plain English:

  #v(0.2em)
  *What it does*
  - *Codebase & concurrency Q&A:* Explains how session lifecycles, lock windows, and buffer ownership work, backed by proved theorems and C++ citations.
  - *"What-if" & code-change checks:* Checks whether a proposed C++ change preserves the model's invariants — or returns a concrete C++ thread-interleaving counterexample.

  #v(0.3em)
  *Benefits*
  - *Machine-checked guarantees:* Instead of relying on ad-hoc C++ code inspection, answers and code-change checks are grounded in formal proofs and exhaustive state search across *all* concurrency schedules.
  - *No Lean expertise needed:* Engineers get formal verification guarantees and concrete counterexample traces directly in C++ terms without needing to read or write Lean.
]

// ---------------------------------------------------------------------------
#slide[Plan & discussion][
  #v(1.4em)
  #let item(num, title) = block(
    stroke: (left: 3pt + accent),
    inset: (left: 14pt, y: 6pt),
  )[
    #text(fill: accent, weight: "medium", size: 19pt)[#num · ]
    #text(weight: "medium", size: 19pt)[#title]
  ]

  #stack(
    spacing: 1.8em,
    item[1][Extend the formalization: reshard, KV cache storage & lower-level transport],
    item[2][Everyday agent use],
    item[3][Lean model maintenance],
  )
]







