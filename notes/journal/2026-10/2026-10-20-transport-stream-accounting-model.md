# Transport stream-accounting model: `Receive` A1 and the A4 coarsening become theorems, R-B sharpened

Load this when touching `Receive.lean` A1/A4, `BlockTransport::CompleteIncomingPush`,
`layer_progress_` retirement, or when someone asks whether a duplicate push stream
can corrupt a receive.

Canonical: `verification/TpuSyncVerify/Transfer/PrefillDecode/Transport.lean`
(module header), `verification/docs/transfer/prefill_decode.md` §Boundary
assumptions and §Counterfactual mutants, `findings/README.md` §R-B
(sharpened 2026-10-20) and §Observations. Claims below are at `0ac16d1`.

[FACT] `Transport.lean` models the `{uuid, layer}` progress table
(`block_transport.h:289-310`), the chunk-count and sender-declared completion
contracts, the once-latch, retirement, and the receiver's block/layer counters
and publication. `Transport.reachable_safe` proves, for any positive layer /
sender / stream / block counts and either contract, `OnceDispatched` (= `Receive`
A1), `NetworkSound` (= the A4 coarsening `layersAccounted < issued`) and
`CompleteOnSuccess`, under one explicit assumption: honest senders (at most the
declared streams per layer for the life of the receive). Inductive proof, no
Mathlib; six exhaustive `#guard … = .safe` instances; four witness traces.

[FACT] What one extra stream does without that assumption: chunk-count contract,
before retirement — the duplicate is absorbed but still counted, so
`network_completed_` is reached with another layer never received and the poll
publishes success (`trace_dup_chunk_publishes_missing_layer`); either contract,
after retirement (`bt.cc:764-778`) — a fresh entry fires `OnLayerReceived`
again, `ExecuteLayerH2d` has no latch of its own, the layer is copied twice;
`in_flight_` still holds `done_` off until both copies return, so this is a
redundant DMA plus a spurious failure if the duplicate copy fails
(`trace_dup_after_retirement`, `trace_dup_copy_fails_late`), not a wrong
publication. Sender-declared before retirement rejects it loudly
(`trace_dup_declared_rejected`). Recorded under R-B, not as a new F: no
in-repo caller re-pushes or over-declares.

[FACT] Two assumptions the model names but does not prove (`Transport` A2,
A3), both found by the self-audit: (1) the receiver seats the session
(`mgr.cc:549-567`) before publishing the plan (`:596-599`), and
`CompleteIncomingPush` latches the contract on a layer's first stream
(`bt.cc:661-683`), so a push in that window would run a sender-declared plan
as chunk-count — stable only because the controller starts the sender after
the receiver's registration returns, which is outside this repo; (2) the
sender-declared contract counts distinct `remote_id = node_id()` (`bt.cc:1168`)
against `shard_push_schedules`, keyed by source shard partition
(`raiden_service.proto:178-180`), presuming one source shard per node.

[FACT] The chunk-count contract is single-sender by construction:
`ExpectedPushSenders` returns the schedule count whenever a plan has
`shard_push_schedules` (`kv_cache_manager_base.cc:2687-2703`), which selects the
sender-declared contract. Encoded as `Cfg.WF.chunkSingle`; the honest two-sender
chunk-count instance double-dispatches (`trace_chunk_two_senders`) — this is the
first thing the exhaustive search found and it is out of contract, not a bug.

[OBS 2026-10-20] Self-audit corrections, in order: the first version of the
model settled the receive the moment `num_completed_layers_ == num_layers`
(a paraphrase); C++ only sets `draining_` there and `done_` waits for
`in_flight_ == 0`, so the post-retirement trace's "published with a copy in
flight" was false. Rebuilt the session side on `Session.Lifecycle`
(`streamLife`, `callbackLife`), which made the fix a transcription rather than
a patch. The audit itself then over-claimed twice — "A2 is stronger than
written" (there is an in-process window) and "a failing duplicate copy's
error is swallowed" (`status_` is recorded before the `draining_` early
return) — both caught on the second pass. Lesson for the durable note:
`conventions.md` §"Transcribe, do not paraphrase" applies to the *session*
side of a transport model too; hand-rolled `finished : Option Bool` is the
paraphrase that bit.

[OBS 2026-10-20] Interpretation. The 2026-10-05 parked entry wanted A4's
ordering proved; the decision (user, after a for/against argument) was that the
ordering is a two-line program-order fact and modelling the most-rewritten file
in the repo to restate it would be a maintenance tax, whereas A1's once-latch
and its retirement were doing unexamined work. That rescoping is what produced
the finding. Model-check first, prove second paid off again: the `.safe`
guards and the witness traces were running within the hour; the inductive
proof (sums over `List Nat`, `natSum_map_set`, `countEq_set`) took the rest.

[OBS 2026-10-20] Lean 4.34 tactic pitfalls hit twice this session: a `by cases h, …`
inside an anonymous constructor parses the comma as a second `cases` target
(parenthesise); `simp only [defn] at key` that unfolds a definition inside a
`List.set … (defn …)` subterm makes `key`'s atoms differ from the goal's and
`omega` fails — use `rfl`-proved projection lemmas (`nextLayer_pending`,
`copyDone_pending`) instead of unfolding.

[HYP] A sender-side source of the extra stream exists in principle:
`08048d5` decoupled stream count from rank count, so `header.reserved` and the
streams actually opened come from the same sender-side computation; a future
refactor that splits them (e.g. retrying a failed stream on a fresh connection
while the first was already landed by the receiver) would be reachable from
in-repo code. Not verified; the hardening in `stepHardened` is the cheap
insurance. See `loose-ends/parked.md` "Transport model follow-ups".
