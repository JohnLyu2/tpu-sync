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
#slide[The prefill → decode transfer][
  A *prefill* worker holds the prompt's KV cache in its TPU memory (HBM). A *decode* worker needs a copy in its own HBM. TPU Sync moves it in three steps, through host memory on each side:

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
    *Sessions.* Each side has a session that keeps count of the copies and pushes still running (`in_flight_`). Once it is told to finish — the last layer completes, an error, or a cancel — it starts no new ones (`draining_`), and when the count reaches zero it _settles_ (`done_`).

    The engines learn the outcome from `poll_stats()`:
    - `done_sending` — prefill may free its HBM
    - `done_recving` — decode may run attention
  ]
]

// ---------------------------------------------------------------------------
#slide[What the transfer must guarantee][
  Copies, pushes, callbacks and cancels can interleave in any order. Across every interleaving, the sessions must never report completion early or hand a buffer on while it is still in use:

  #v(0.5em)
  #grid(
    columns: (13.5em, 1fr),
    row-gutter: 0.9em,
    column-gutter: 1.2em,
    [*Publication correctness*], [When `done_recving` is reported, every layer's cache has arrived in decode HBM, in the right layer position.],
    [*Attention safety*], [Once `done_recving` is reported, nothing that happens later in the pipeline overwrites decode HBM.],
    [*Prefill HBM safety*], [When `done_sending` lets prefill free its HBM, no D2H copy is still reading from it.],
    [*Staging integrity*], [Each host staging buffer is held until its session settles; when it is returned to the pool, no copy or push is still using it.],
    [*Progress*], [Every started transfer eventually settles on both sides and returns its staging buffers.],
  )
]

// ---------------------------------------------------------------------------
#slide[Abstraction levels in TPU Sync — and what we model in Lean][
  TPU Sync's transfer stack has four levels, from whole requests down to TCP chunks. The highlighted rows are what the Lean model covers:

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
#slide[How the Lean model is structured][
  The Lean model mirrors the C++ in four modules at three levels:

  #v(0.3em)
  #cols(columns: (0.85fr, 1.45fr))[
    #v(0.5em)
    #align(center, text(size: 13.5pt, diagram(
      spacing: (1.8em, 1.6em),
      node-stroke: 0.7pt + accent,
      node-shape: rect,
      node-inset: 8pt,
      node-corner-radius: 3pt,
      node((0.5, 0), [`Pipeline`\ #small[memories per layer]]),
      node((0, 1), [`Send`\ #small[prefill counters]]),
      node((1, 1), [`Receive`\ #small[decode counters]]),
      node((0.5, 2), [`Session`\ #small[shared `Lifecycle`]]),
      edge((0.5, 0), (0, 1), "->"),
      edge((0.5, 0), (1, 1), "->"),
      edge((0, 1), (0.5, 2), "->"),
      edge((1, 1), (0.5, 2), "->"),
    )))
  ][
    #table(
      columns: (auto, 1fr),
      table.header[Lean module][What it models],
      [`Session`], [The settle protocol shared by both sides: `inFlight`, `draining`, `done`, and releasing the staging buffer.],
      [`Send`], [`TransferSendSession`: the D2H copy loop and the H2H push chain, at the counter level.],
      [`Receive`], [`TransferReceiveSession`: incoming pushes, H2D copies, the readiness check, at the counter level.],
      [`Pipeline`], [One `Send`, one `Receive`, and the five memories (prefill HBM, prefill staging, network, decode staging, decode HBM), tracking which transformer layer's data is in each.],
    )
  ]

  #v(0.4em)
  `Session`, `Send` and `Receive` only *count* operations. `Pipeline` adds *what each operation moves*; only there can publication correctness be stated.
]

// ---------------------------------------------------------------------------
#slide[`Session` — the shared settle protocol][
  Both sessions use the same protocol to track running work and decide when to settle. Every event in `Send` and `Receive` calls these functions:

  #cols(columns: (1fr, 1fr))[
    ```lean
    def settleLocked (l : Lifecycle) :=
      if l.draining ∧ l.inFlight = 0 ∧ ¬l.done then
        { l with done := true, hasStaging := false }
      else l

    def beginOp (l : Lifecycle) : Option Lifecycle :=
      if l.done ∨ l.draining then none
      else some { l with inFlight := l.inFlight + 1 }

    def endOpLocked (l : Lifecycle) :=
      if l.inFlight = 0 then l
      else settleLocked
        { l with inFlight := l.inFlight - 1 }

    def finish (ok : Bool) (l : Lifecycle) :=
      if l.draining ∨ l.done then l
      else settleLocked
        { l with draining := true, statusOk := ok }
    ```
  ][
    ```lean
    structure Lifecycle where
      inFlight   : Nat  := 0
      draining   : Bool := false
      done       : Bool := false
      statusOk   : Bool := true
      hasStaging : Bool := true

    structure Consistent (l : Lifecycle) : Prop where
      done_draining : l.done → l.draining
      done_idle     : l.done → l.inFlight = 0
      prompt        : l.draining →
                      l.inFlight = 0 → l.done
      staging       : l.hasStaging = !l.done
    ```
    `Consistent` holds initially and is preserved by all four functions — so any session built from them holds its staging buffer until `done`, and reaches `done` only when `inFlight = 0`.
  ]
]

// ---------------------------------------------------------------------------
#slide[`Send` — counting operations on the prefill side][
  `Send` models the prefill session (`TransferSendSession`): it starts all $L$ D2H copies up front, then pushes layers one after another from a thread pool, all sharing a single `inFlight` counter.

  #v(0.3em)
  #cols(columns: (1.05fr, 0.95fr))[
    ```lean
    def Accounted (s : Send) : Prop :=
      s.life.inFlight =
        (if s.d2hPending then 1 else 0)
        + (s.d2hIssued - s.d2hRetired) -- D2H copies
        + (s.queued - s.woken)         -- waiting on D2H
        + s.pooled + s.chaining        -- pool tasks
        + (s.h2hIssued - s.h2hRetired) -- H2H pushes
    ```
    Every unit of `inFlight` is accounted for by a running D2H copy, a `SendNextLayer` callback waiting on its D2H future, a thread-pool task, or a running H2H push.
  ][
    *Why the D2H → H2H handoff is safe*
    - When layer $l$'s D2H copy finishes, the pool task increments `inFlight` for the H2H push _before_ releasing the count held while waiting on D2H (`chaining`) — so `inFlight` cannot hit `0` in the gap between the two steps.

    *Proved for `Send`*
    - At `done`, `inFlight = 0`, so every term in `Accounted` is `0`: no D2H copy, pool task or H2H push is running.
    - `inFlight` never underflows.
    - `done_sending` (`published = some true`) implies all $L$ pushes succeeded (`h2hOk = numLayers`).
  ]
]

// ---------------------------------------------------------------------------
#slide[`Receive` — counting operations on the decode side][
  `Receive` models the decode session (`TransferReceiveSession`): it accepts incoming H2H pushes from the network and dispatches one H2D copy per layer as each layer arrives.

  #v(0.3em)
  #cols(columns: (1.05fr, 0.95fr))[
    ```lean
    def Accounted (s : Recv) : Prop :=
      s.life.inFlight =
        (if s.pullPending then 1 else 0)
        + s.pushes                -- open H2H pushes
        + s.pending               -- H2D lock gap
        + (s.issued - s.retired)  -- H2D copies

    def isReadyToComplete (s : Recv) : Prop :=
      (s.layersAccounted = s.numLayers ∨
       s.completed = s.numLayers) ∧
      s.ready = s.issued
    ```
    Every unit of `inFlight` is the initial pull handshake, an open H2H push, an H2D dispatch between its two locks, or an H2D copy whose callback has not yet run.
  ][
    *Why H2D dispatch is two steps (`pending`)*
    - `ExecuteLayerH2d` drops the session lock while issuing the TPU copy. It claims an `inFlight` count _before_ dropping the lock and re-checks `draining` after re-acquiring it — so a concurrent cancel cannot settle the session mid-dispatch.

    *Proved for `Receive`*
    - At `done`, `inFlight = 0`, so no push, pull request, H2D dispatch or H2D callback is still outstanding.
    - `isReadyToComplete` implies all $L$ H2D copies have finished (`ready = numLayers`).
    - `done_recving` (`published = some true`) implies all $L$ H2D callbacks succeeded (`completed = numLayers`).
  ]
]

// ---------------------------------------------------------------------------
#slide[`Pipeline` — per-layer memories and events][
  `Send` and `Receive` only count operations. `Pipeline` pairs one `Send` and one `Receive` with the five memories, and tags every copy and push with its layer index $l$ so completions can interleave in any order.

  #v(0.2em)
  #cols(columns: (0.95fr, 1.05fr))[
    ```lean
    inductive Cell where
      | blank            -- nothing sent yet
      | kv (layer : Nat) -- layer l's KV data
      | junk             -- another request's bytes

    structure Pipeline where
      numLayers      : Nat
      send           : Send
      recv           : Recv
      prefillHbm     : List Cell
      prefillStaging : List Cell
      wire           : List Cell
      decodeStaging  : List Cell
      decodeHbm      : List Cell
    ```
  ][
    *Initial state ($L$ cells per memory)*
    - `prefillHbm`: `[kv 0, …, kv (L-1)]`
    - `wire`: `[blank, …, blank]`
    - `prefillStaging`, `decodeStaging`, `decodeHbm`: `[junk, …, junk]` (from earlier requests)

    *Data-moving events (in any layer order)*
    - `d2hReady l`: copies `prefillHbm[l]` → `prefillStaging[l]`.
    - `h2hDone l true`: copies `prefillStaging[l]` → `wire[l]`.
    - `land l`: copies `wire[l]` → `decodeStaging[l]` inside an open push.
    - `h2dReady l`: copies `decodeStaging[l]` → `decodeHbm[l]`.

    *Reuse events*
    - Freeing prefill HBM (`reclaim`) or reusing a released staging buffer (`reseat*`) overwrites all $L$ of its slots with `junk`.
  ]
]

// ---------------------------------------------------------------------------
#slide[`Pipeline` — why each layer arrives intact][
  Each layer $l$'s data (`kv l`) moves step by step across the five memories: `prefillHbm` → `prefillStaging` → `wire` → `decodeStaging` → `decodeHbm`. At each step, two properties connect the local C++ guards in `step` to the proved invariant `Pipeline.Inv`:

  #v(0.3em)
  #cols(columns: (1fr, 1fr))[
    *1. Don't read before the previous step finishes*

    - *Guards in `step` (from C++):*
      - Layer $l$'s H2H push wakes only after layer $l$'s _own_ D2H copy finishes (`d2hReadyL[l] = true`).
      - Layer $l$'s H2D copy starts only after layer $l$'s push lands (`landedL[l] = true`).
    - *Proved in `Pipeline.Inv`:*
      - Any active push or H2D copy for layer $l$ reads a slot that the previous step has already written (`woken_d2hReady`, `issued_landed`).
  ][
    *2. Don't overwrite while a step is in flight*

    - *Guards in `step` (from C++):*
      - A session settles (`done := true`, `hasStaging := false`) only when `inFlight = 0`; freeing HBM (`reclaim`) requires `done`, and reusing staging (`reseat*`) requires `hasStaging = false`.
    - *Proved in `Pipeline.Inv`:*
      - Any running copy or push keeps `inFlight > 0` (`Accounted`), so `done = false` and its source memory cannot be overwritten with `junk` before it finishes.
  ]

  #v(0.25em)
  Applying (1) and (2) at each step proves one invariant per memory in `Pipeline.Inv`, each feeding the next:
  #align(center)[
    `phbm_good` #sym.arrow.r `pstaging_good` #sym.arrow.r `wire_good` #sym.arrow.r `dstaging_good` #sym.arrow.r `dhbm_good`
  ]
]

// ---------------------------------------------------------------------------
#slide[Main theorems — decode HBM correctness][
  The first two properties guarantee that decode HBM holds `[kv 0, …, kv (n - 1)]` when `done_recving` is reported, and keeps holding it for the rest of the run:

  #v(0.3em)
  #cols(columns: (1.1fr, 0.9fr))[
    ```lean
    def good (n : Nat) : List Cell :=
      (List.range n).map Cell.kv

    def PublicationCorrect (s : Pipeline) : Prop :=
      s.recv.published = some true →
        s.decodeHbm = good s.numLayers

    theorem attention_safe {n : Nat} {s s' : Pipeline}
        (h  : (sys n).Reachable s)
        (hp : s.recv.published = some true)
        (evs : List Ev)
        (hr : (sys n).runFrom s evs = some s') :
        s'.decodeHbm = good n
    ```
  ][
    *Publication correctness (`PublicationCorrect`)*
    - `good n` is `[kv 0, kv 1, …, kv (n - 1)]` — every layer slot holds its own KV data.
    - Whenever `poll_stats()` reports `done_recving` (`s.recv.published = some true`), `decodeHbm` already equals `good n`.

    *Attention safety (`attention_safe`)*
    - Once `done_recving` has been reported in a reachable state `s`, _any_ later sequence of events `evs` leading to `s'` leaves `s'.decodeHbm = good n`.
    - Freeing prefill HBM, reusing either staging buffer, or a late cancel cannot corrupt decode HBM while attention runs.
  ]
]

// ---------------------------------------------------------------------------
#slide[Main theorems — prefill HBM and staging safety][
  The remaining properties guarantee that no copy or push is still touching prefill HBM or either host staging buffer once it is freed or released:

  #v(0.3em)
  #cols(columns: (1.1fr, 0.9fr))[
    ```lean
    def PrefillHbmSafe (s : Pipeline) : Prop :=
      s.reclaimed = true →
        s.send.d2hPending = false ∧
        s.send.d2hRetired = s.send.d2hIssued

    def StagingSafe (s : Pipeline) : Prop :=
      (s.send.life.hasStaging = false →
        s.send.d2hPending = false ∧
        s.send.d2hRetired = s.send.d2hIssued ∧
        s.send.h2hRetired = s.send.h2hIssued) ∧
      (s.recv.life.hasStaging = false →
        s.recv.pushes = 0 ∧ s.recv.pending = 0 ∧
        s.recv.retired = s.recv.issued)

    theorem reachable_safe {n : Nat} {s : Pipeline}
        (h : (sys n).Reachable s) :
        PublicationCorrect s ∧
        PrefillHbmSafe s ∧ StagingSafe s
    ```
  ][
    *Prefill HBM safety (`PrefillHbmSafe`)*
    - Once the prefill engine frees `prefillHbm` (`s.reclaimed = true`), no D2H copy is mid-dispatch (`d2hPending = false`) and every issued D2H copy has retired — and because the send session has settled, no new D2H copy can start.

    *Staging integrity (`StagingSafe`)*
    - When prefill staging is released (`hasStaging = false`), no D2H copy is mid-dispatch and every D2H copy and H2H push has retired.
    - When decode staging is released, no H2H push is open (`pushes = 0`), no H2D dispatch is pending (`pending = 0`), and every H2D copy has retired.

    *All layer counts (`reachable_safe`)*
    - Holds for every number of transformer layers $n$ and every interleaving the Lean model admits.
  ]
]

// ---------------------------------------------------------------------------
#slide[Main theorems — progress and no op leak][
  In both `Send` and `Receive`, `Accounted` also proves that `inFlight` never gets stuck above zero — every reachable session can drain to `done = true` and release its staging buffer:

  #v(0.3em)
  #cols(columns: (1.1fr, 0.9fr))[
    ```lean
    def NoOpLeak (s : Send) : Prop :=
      0 < s.life.inFlight →
        ∃ e ∈ drainEvents, (step s e).isSome = true

    theorem reachable_can_settle {n : Nat} {s : Send}
        (h : (sys n).Reachable s) :
        ∃ evs s',
          (sys n).runFrom s evs = some s' ∧
          s'.life.done = true ∧
          s'.life.hasStaging = false

    -- Likewise proved in Receive.lean:
    -- Recv.NoOpLeak, Recv.reachable_can_settle
    ```
  ][
    *No operation leak (`NoOpLeak`)*
    - Whenever `inFlight > 0`, `Accounted` guarantees at least one active operation, which enables a completion step in `drainEvents`.
    - Rules out bugs where an early return forgets to decrement `inFlight` (which would leave `done` unreachable and `SettleSafe` vacuously true).

    *Eventual settlement (`reachable_can_settle`)*
    - Once `draining = true`, no new operation can start (`beginOp` returns `none`) and each `drainEvents` step strictly decreases a finite `drainRank`.
    - So from every reachable state, a finite event sequence `evs` settles the session (`done = true`, `hasStaging = false`).
  ]
]

// ---------------------------------------------------------------------------
#slide[How the proofs work][
  All theorems are proved by induction on `Reachable` in Lean 4. Three ideas keep the proofs simple:

  #v(0.35em)
  #cols(columns: (1fr, 1fr))[
    *1. How `inFlight = 0` proves every step has finished*\
    _(`PrefillHbmSafe`, `StagingSafe`, `NoOpLeak`)_
    - In C++, `in_flight_` is just one number — `in_flight_ = 0` alone does not say which copies or pushes are still running.
    - `Accounted` equates `inFlight` to the sum of `Nat` counters for each kind of active work.
    - Because `Nat`s cannot be negative, their sum is `0` _iff every counter is `0`_ — and when `inFlight > 0`, at least one counter is `> 0` (`NoOpLeak`).

    #v(0.3em)
    *2. How `Pipeline` reuses the `Send` and `Receive` proofs*
    - `Pipeline.Inv` includes `s.send.Inv` and `s.recv.Inv` directly; events that only change session counters reuse those proofs as-is, so `Pipeline` only has to prove the memory-touching events.
  ][
    *3. How a counter (`ready = L`) proves every slot $0 … L-1$ is ready*\
    _(`PublicationCorrect`)_
    - C++ checks a counter (`ready == num_layers`), whereas `PublicationCorrect` requires every slot $0 … L-1$ to be filled — so the proof must rule out one layer being counted twice while another is missing.
    - `Pipeline` keeps a list of $L$ booleans (`h2dReadyL : List Bool`, one entry `h2dReadyL[l]` per layer $l$). Layer $l$'s H2D copy flips `h2dReadyL[l]` from `false` to `true` at most once, so:
      ```lean
      countTrue s.h2dReadyL = s.recv.ready
      ```
    - When `ready = L`, a list of $L$ booleans has $L$ `true`s — so _every_ entry `h2dReadyL[l]` must be `true`, and `dhbm_good` gives `decodeHbm[l] = kv l`.
  ]
]

// ---------------------------------------------------------------------------
#slide[Sanity checks on the Lean model][
  Two checks run automatically at every `lake build` to verify that the Lean model neither forbids valid runs nor misses bugs when a guard is dropped:

  #v(0.3em)
  #cols(columns: (1fr, 1fr))[
    *1. Concrete traces (`decide`)*\
    _Checks that key scenarios run to completion:_

    - *Normal multi-layer run:* completes all copies and pushes and publishes `done_recving` with `[kv 0, …, kv (L-1)]`.
    - *Out-of-order layers:* Layer 1 finishes D2H, H2H, and H2D before Layer 0 at every step, and `decodeHbm` still ends with `[kv 0, kv 1]`.
    - *Fast prefill, slow decode:* prefill finishes, frees `prefillHbm`, and reuses `prefillStaging` before decode lands anything — decode still gets `[kv 0, kv 1]`.
    - *Cancel in the H2D lock gap:* a cancel arrives while the session mutex is unlocked during H2D dispatch; the re-check aborts the copy and drains cleanly.
  ][
    *2. Mutants (bounded model checking)*\
    _Checks that removing a C++ guard exposes a bug:_

    - *Settle without waiting for `inFlight = 0`:* session settles and releases its staging buffer while a copy is still running.
    - *Start H2D before layer $l$ lands:* H2D copies stale `[junk]` from `decodeStaging` into `decodeHbm`.
    - *Release staging at `Finish` instead of settle:* staging is reused while in-flight operations are still draining, corrupting the transfer.
    - *Skip `--inFlight` on early abort:* `inFlight` never reaches `0`, so the session is stuck `draining` forever and leaks its staging buffer.
  ]
]
