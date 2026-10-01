# Modelling conventions

How the models under `TpuSyncVerify/` are written, so that a new one looks
like the existing ones and a reader of one can read the others.

## One executable `step` is the definition

Every model is a `System S Ev := ⟨init, step⟩` (`Common/System.lean`) with
`step : S → Ev → Option S`. `none` means the event is not enabled. Nothing
else defines the transition relation: `Reachable` is the closure of `step`
from `init`, `run`/`runFrom` replay an event list, and
`ModelCheck.check` searches the same `step`. There is no separate inductive
`Step` whose guards could drift from the function.

Consequences we rely on:

* a concrete scenario is a theorem about `run` proved by `decide`;
* a bounded search (`#guard ModelCheck.check … = .outOfFuel`) and the
  inductive proof talk about the same system;
* a mutant is `⟨init, fun s e => match e with | .x => mutated s | e => step s e⟩`.

Events carry their outcome (`h2dDone (ok : Bool)`, `acquireReply ok`) rather
than being split into two constructors, so the event list for a search stays
short and the C++ callback maps to one row of the table.

## Transcribe, do not paraphrase

The settle logic that the proofs rest on (`FinishLocked`, `EndRecvOpLocked`,
`TryBeginRecvOp`) is transcribed into small Lean functions
(`Transfer/Session.lean`) and every event is composed from them. An event
never re-derives `done` or `draining` by hand.

Where the C++ has a race window the model has an event boundary: an op taken
under one lock and used under a second is two events (`h2dBegin` /
`h2dIssue`), and the field between them is a ghost counter.

## Ghost fields

A ghost field has no single C++ variable. It records *where each unit of a
counter came from* (`pending`, `retired`, `chaining`, …) or a fact about the
environment (`reused`). Ghosts are what make `Accounted`-style invariants
statable: "`in_flight_` equals the sum of the things that hold an op".
Each ghost is listed in the module's state table and marked `ghost`.

Prefer counters to indexed maps when identity does not matter. `Nat` keeps
`DecidableEq`, avoids `funext`, and lets the same model be proved and
model-checked. Use indexed structure only where the property needs it
(`Pipeline` memories are `List Cell` indexed by layer). When identity does
matter but the session keeps only a counter, add a per-item `List Bool`
ghost set next to the counter and tie them with an invariant
(`countTrue set = counter`); the counter stays the thing the C++ checks,
the set is what the proof reasons about.

## Module layout

Each model file, in order:

1. Module docstring: what is modelled, which tpu-sync commit the citations
   are for, abbreviations for cited files; **State** table (field → C++ →
   role); **Events** table (event → C++ location); **Assumptions**
   (numbered A1, A2, …, each with its citation and how it is encoded);
   **Properties** (each stated in words, with the C++ comment or promise it
   corresponds to).
2. `structure S`, `init`.
3. `inductive Ev`; one `def` per event (named so it does not collide with a
   field of `S`, or dot-notation breaks); `step`; `sys`.
4. Property definitions, `Safe` as their conjunction.
5. `Inv`, `inv_init`, `inv_safe`, `step_inv`, `reachable_safe`.
6. Frame lemmas other modules need.
7. **Replay and bounded search**: named `trace_*` theorems, `events`,
   executable `violates`, `#guard` searches, mutants.

## Citations

`file:line` against a named commit, stated once per module. Abbreviate
heavily cited files in the docstring preamble (`recv.cc`, `mgr.cc`, `bt.cc`).
Line numbers are for reading alongside the code, not for machine checking;
when upstream moves, re-check the cited regions and update the commit in the
preamble (`docs/transfer/prefill_decode.md` records what was re-checked and
when).

## Assumptions

Anything the proof trusts about code outside the model is an assumption with
a number, a citation and the guard that encodes it. If an assumption's
failure would be a real bug, say so and, if cheap, show the failure as a
mutant (`netAccountUnordered` for the receive model's A4).

## Properties and proofs

State a property against the C++ comment that motivates it, in the form the
engine or the next module consumes (`published = some true → …`, not an
internal counter equation). `Safe` is the conjunction; `Inv` is whatever
strengthening the induction needs; `reachable_safe` is the theorem to cite.

Proofs are `induction` on `Reachable` and `cases` on the event, with
per-event lemmas where a case is long. No `sorry`, no axioms, no Mathlib.

## Replay, search, mutants

Every module ends with evidence that the proof is not vacuous:

* traces that reach the interesting states (publication, a deadline during
  a copy, the race a re-check closes) and traces that are refused;
* a bounded search for `violates` from the initial state, expected
  `.outOfFuel` for an infinite-fuel-needed system or `.safe` when the state
  space is finite and exhausted — only `.safe` is a verification result;
* at least one mutant per load-bearing guard, shown to produce a
  counterexample.

`decide` on traces of ~20 events is instant; BFS at fuel 10 on the pipeline
is a few seconds. Keep `#guard`s under ~5 s so `lake build` stays quick.

## Naming

* Modules by subsystem: `Transfer/…`, `Controller/…`; shared machinery in
  `Common/`.
* Events in the voice of the C++ (`h2dBegin`, `pullReply`, `cancel`), not of
  the property.
* Mutants named for what they break (`cancelEager`, `dispatchEarly`,
  `reseatAtFinish`).
