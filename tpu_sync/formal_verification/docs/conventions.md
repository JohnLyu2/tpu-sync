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
* a bounded search (`#guard ModelCheck.check … = .safe`, or a mutant's
  `.counterexample`) and the inductive proof talk about the same system;
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

1. Module docstring: what is modelled, pointer to `tpu_sync/formal_verification/README.md`
   §Status for the baseline commit, abbreviations for cited files; **State**
   table (field → C++ → role); **Events** table (event → C++ symbol / code
   fragment); **Source map** (`<!-- source-map:begin --> ... <!-- source-map:end -->`
   table generated and verified by `tools/resolve_anchors.py`); **Assumptions**
   (numbered A1, A2, …, each with its C++ symbol/fragment and how it is
   encoded); **Properties** (each stated in words, with the C++ comment or
   promise it corresponds to).
2. `structure S`, `init`.
3. `inductive Ev`; one `def` per event (named so it does not collide with a
   field of `S`, or dot-notation breaks); `step`; `sys`.
4. Property definitions, `Safe` as their conjunction.
5. `Inv`, `inv_init`, `inv_safe`, `step_inv`, `reachable_safe`; progress as
   `drainRank` + a one-step `drain_step` lemma, discharged through
   `System.settles_of_rank`.
6. Frame lemmas other modules need.
7. **Replay and bounded search**: named `trace_*` theorems, `events`,
   `instance : Decidable (Safe s)` and `violates s := !decide (Safe s)` (so
   the searches and the theorems check one predicate; `violates_iff` records
   it), `#guard` searches, mutants.

Modules over roughly a thousand lines are split along these sections into a
directory of part files plus an umbrella: `X.lean` keeps item 1 (the module
docstring with the source map) and only re-exports `X/Model.lean` (items 2–4),
`X/Invariant.lean` (5, up to `reachable_safe`), `X/Progress.lean`,
`X/Frame.lean` (6) and `X/Traces.lean` (7), with `X/Lemmas.lean` for a
structural-lemma section between the model and the invariant where one exists
(modules with their own numbering, such as `BlockOrdering` and `PoolStaging`,
name their parts after their sections). Parts import each other in a linear
chain and repeat the namespace preamble; `import …X` keeps working, and only
`X.lean` carries a source map. An upstream sync therefore touches `X.lean`
(the map), `X/Model.lean` (if the modelled code changed) and `X/Traces.lean`
(if a replayed test was renamed), and a reviewer can read those three without
the proofs.

## Citations and source maps

1. **Single baseline commit (`tpu_sync/formal_verification/README.md` §Status).** The baseline
   `tpu-sync` commit hash is stated once in `tpu_sync/formal_verification/README.md` §Status.
   Individual `.lean` modules and `docs/*.md` files point there rather than
   repeating the commit hash in their headers.
2. **Symbols and code fragments in prose; line numbers only in `source-map`
   tables.** Prose, state/event tables, `def` docstrings, and `theorem`
   docstrings cite C++ symbols (`Class::Method`), quoted C++ code fragments
   (`if (done_ || draining_)`), and GTest `Suite.TestName`s — never raw
   `file:line` or bare `:line` numbers (except where a sentence explicitly
   discusses a historical commit hash or an external foreign-repo Python file).
   Each module and subsystem doc has a single
   `<!-- source-map:begin --> ... <!-- source-map:end -->` table (`| File | Symbol / anchor | Lines |`)
   whose `Lines` column is resolved directly from the C++ source tree by
   `python3 tpu_sync/formal_verification/tools/resolve_anchors.py`:
   - `python3 tpu_sync/formal_verification/tools/resolve_anchors.py --check` verifies that every
     `Lines` cell matches the working tree and that no stray raw `file:line`
     citations exist outside `source-map` blocks.
   - `python3 tpu_sync/formal_verification/tools/resolve_anchors.py --apply` updates `Lines`
     cells in place from the C++ tree.
   - `python3 tpu_sync/formal_verification/tools/resolve_anchors.py --diff <old_ref> <new_ref>`
     classifies every anchor across an upstream sync as `same`, `shift` (pure
     line-offset shift, body identical), `modified` (body changed between the
     two commits — inspect the Lean model), or `FAIL` (anchor renamed/removed),
     and `docs/upstream_rechecks.md` logs what changed.
3. **Findings are frozen at confirmation.** The bug-hunt reports live outside
   `tpu_sync/formal_verification/`, in the fork's `findings/README.md` and
   `findings/filed_bugs.md`; each finding's body (`## Fn.`) is an immutable
   historical record pinned to the commit where the finding was confirmed or
   fixed, and only that README's `Summary` table and `History` section are
   updated when upstream lands a fix. Documents here cite findings by number
   (F1–F10, C1, R-A/R-B) and never link into `findings/`.

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
* where the state space is finite, an exhaustive search for `violates`
  (`#guard … = .safe`). A depth-bounded search that ends in `.outOfFuel` is
  not a verification result and is kept only where no theorem covers the
  property (then the `#guard` carries a `-- Bounded only` comment saying so);
  it is never placed beside a proved `reachable_safe` for the same system;
* at least one mutant per load-bearing guard, shown to produce a
  counterexample.

`decide` on traces of ~20 events is instant; a mutant BFS at fuel 6–8 is
under a second. Keep `#guard`s under ~5 s so `lake build` stays quick.

## Naming

* Modules by subsystem: `Transfer/…`, `Controller/…`; shared machinery in
  `Common/`.
* Events in the voice of the C++ (`h2dBegin`, `pullReply`, `cancel`), not of
  the property.
* Mutants named for what they break (`cancelEager`, `dispatchEarly`,
  `reseatAtFinish`).
