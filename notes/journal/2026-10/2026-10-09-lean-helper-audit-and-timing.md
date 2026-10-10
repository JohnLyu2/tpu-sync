# 2026-10-09 — Lean-helper agent: citation re-audit of `prefill_decode.md` and first timing runs

Read at tpu-sync `50b0774`. Canonical facts: `verification/docs/transfer/prefill_decode.md`
(amended into the unpushed routing-index commit) and `verification/agents/tpu-sync-lean-helper/`.
This entry holds the audit history and interpretation.

[OBS 2026-10-09] Two audit passes of the routing doc against `50b0774` (a first pass by hand,
then four parallel read-only subagents, one per table family) found ~40 wrong items in a
document that had been written *two days earlier* against the same commit. The error classes,
in decreasing frequency: (1) invented identifiers that read like the codebase's naming
(`StartReshardRead`, `send_deadline_`, `layer_states_`, `BuildCoalescedSpec`, `kCustomHostBlocks`,
Lean `PeerIsolation.Ev.pullReply`); (2) right function, wrong owner (the first lock of
`ExecuteLayerH2d` is inline, not `TryBeginRecvOp`; duplicate-block rejection lives in
`TransferSendSession::Create`, not the manager; `HandleIncomingPush`, not `HandleCustomRequest`);
(3) line ranges off by a few lines or spanning two tests; (4) a test paired with a trace it does
not witness (`FailedSendWithoutWorkSettlesImmediately` ↔ `Send.trace_push_fails`). Our reading:
class (1) is the one that poisons an agent — a routing index with plausible fake names makes
the helper cite confidently and wrongly — so the audit rule is *every identifier in the routing
doc is opened in the source, not pattern-matched from memory*. Splitting the audit by table
family across subagents worked because each table's citations are independent; the merged
report had no overlap and no contradictions.

[OBS 2026-10-09] First timing runs of the helper agent on three shapes of question (self-reported
tool counts; transcripts not flushed at the time): cheap theorem lookup 0:49 / 5 tool calls /
0 Lean runs; negative control ("does the model prove the staging wait cannot deadlock?") 1:41 /
9 calls / 0 Lean; test-to-trace mapping needing a derived event sequence
(`TimeoutDuringH2dDispatchKeepsStaging`) 2:16 / 9 calls / 1 Lean run. Earlier fault-tolerance
audit questions took 3–6 min each. The negative control is the important one: the agent said
"no theorem", explained the `.start`/`.cancel` abstraction, and then located a real C++ test gap
instead of inventing coverage. The case-5 agent correctly rejected the hint
(`trace_finish_between_locks` has `issued = 0`) and derived `[.h2dBegin, .h2dIssue true, .cancel, …]`.

[HYP] Time is dominated by file reads, not Lean: one `run_lean.sh` call is ~10 s, while
reading three C++ files and two Lean modules is most of the ~2 min. If the routing doc keeps its
`file:line` ranges exact, the agent can `view_file` narrow windows and the lookups stay under a
minute; the moment a range is stale the agent falls back to scanning whole files and the cost
triples. That makes the citation audit a performance feature, not just a correctness one.

Outputs: [SUPERSEDED → folded into `Recv.trace_deadline_during_copy` below] originally added
`Recv.trace_timeout_during_h2d_dispatch`, then dropped it on re-inspection because on `Receive.lean`
`(sysLoad 1).run [.pullReply true] = some (initPush 1)` makes `[.h2dBegin, .h2dIssue true, .cancel, …]`
on `sysPush 1` the exact same post-handshake trace as `trace_deadline_during_copy` (and `h2dIssue`
already coarse-grains Lock 2 `.cc:611-616`, `H2dSyncDispatch` `.cc:619-624`, and Lock 3 `.cc:634-636`
into one atomic step, so the model identifies `TimeoutDuringH2dDispatchKeepsStaging` with
`ExpiredReceiveKeepsStagingUntilH2dEnds` by reduction rather than a separate trace); one §2 test row
in `prefill_decode.md` pointing to `Recv.trace_deadline_during_copy`; one parked item in
`loose-ends/parked.md` (missing slot-freed-wakeup test). [OPEN] → that parked item.

[OBS 2026-10-09] Third pass over `prefill_decode.md` (session `f6950942`, independent of the two
passes above; facts in the doc's 2026-10-09 re-check row). Thirteen more items survived two
audits, and they fall into classes the first passes under-weighted: (a) names invented for
*outside* code that nobody opened because it is not in the repo (`Disagg*Queue`,
`RAIDEN_WAITING_TIMEOUT` in the boundary table — replaced by what the repo actually configures,
`examples/single_host_disagg/{prefill,decode}.sh`); (b) trace descriptions written from the
C++/Python test's *theme* instead of the Lean statement — `trace_custom_host_block_transfer` is
single-layer and does write device block 1, the "large complex" trace is 10 of 16 blocks in 6 DMA
runs not "8-block", and all three Python block tests permute `remote_block_ids` while
`local_block_ids` stay in order; (c) a true-sounding locking claim that is false at one of three
call sites (`mgr.cc:576` runs after the session was seated at `:528`); (d) case-only identifier
drift (`done()` for `Done()`, `PollStats` for the poll sweep). Our reading: checking that an
identifier *exists* (the first passes' rule) catches class (a) but not (b)–(c); for those the
rule is *compare the sentence with the Lean term and the C++ line, not the test name*.
`lake build` clean after the comment-only Lean edits (Receive A2 docstring, `trace_normal` test
names in `PipelineChecks.lean`, Trace 7 range in `BlockOrdering.lean`).

[OBS 2026-10-09] Statement-level pass (session `f6950942`, continued): a script paired every
sentence of the trace table, the properties table and the parenthetical claims in the test
tables with the Lean theorem it describes — statement, docstring, and the event-list /
initial-state defs it references (`scratch/pair_traces.py` in the conversation artifacts;
89 references, all resolved). 58 pairs read; 4 real mismatches + 2 nits, all of class (b)
from the entry above: `trace_duplicate_uuid_rejected_until_drained` sweeps before re-registering
(the doc credited `registerRecv` with inline retirement, which the step does but no trace
exercises); `trace_duplicate_registration_rejected` is duplicates-only (the doc added "empty",
which is a C++-only check at `mgr.cc:439-441`); the block-level publication row equated
`decodeHbmB` with the *reclaimable* `prefillHbmB` instead of `.kv l t.remote`; the handshake row
claimed a non-empty duplicate-free `registeredBlocks` that nothing proves (`BlockPipeline` takes
it as a parameter). Our reading: prose written from the C++ test's *intent* drifts from the
Lean term in exactly these ways — it credits the model with a guard the C++ has but the model
omits, or with a sequence the model proves only in a different order. The pairing script makes
that check mechanical; worth re-running after any trace is added or renamed. Observed in
passing: the sibling session (`639cd8eb`) folded `trace_timeout_during_h2d_dispatch` into
`trace_deadline_during_copy` while this pass ran; its new `.cc:611-636` citations check out.

[OBS 2026-10-09] Fourth pass — `.lean` module headers and `/-- … -/` docstrings across all 10
files under `verification/TpuSyncVerify/Transfer/` (session `639cd8eb`; three parallel read-only
auditors, 189 citations verified OK, 35 docstring fixes applied). What survived in `.lean`
comments fell into the exact three un-audited buckets: (1) `.lean` trace/theorem docstrings never
compared against their own event lists (`Recv.trace_normal` said "completes through the poll" when
its event list has no `.pollReady`; `UuidTable.trace_duplicate_uuid_rejected_until_drained`
omitted the final `.cancel, .sweepRecv 0` steps); (2) Lean-to-C++ name conflation inside prose
(`Pipeline.lean` wrote `failed_sending` three times in docstrings even though `Send.lean` notes
there is only `failed_recving_`; `MultiRequest.lean` and `PeerIsolation.lean` wrote
`SettleLocked()` as if it were a C++ method rather than `Lifecycle.settleLocked`); (3) four bare
`:NNN-MMM` test line ranges in `PeerIsolation.lean` and `UuidTable.lean` (`:1034-1093`,
`:1042-1044`, `:765-801`, `:729-763`) that `repin_citations.py` skipped during `01ffa3d → 50b0774`
because they lacked a filename prefix — now prefixed with
`kv_cache_manager_with_transfer_control_test.cc:` so future re-pins update them automatically.

[OBS 2026-10-09] Fifth pass — full corpus audit across `verification/` (`README.md`, `proposal.md`,
`slides/prefill_decode.typ`, `findings/`, `Controller/ReadRemote.lean`, `Common/*.lean`, mid-file
`Transfer/*.lean` docstrings, and `repin_citations.py` `prev_path` bindings) plus `notes/` and
`AGENTS.md` (four parallel read-only subagents + mechanical `prev_path` simulation):
- **`repin_citations.py` `prev_path` misbinding trap:** `repin_citations.py` binds a bare `` `:N` ``
  citation to the most recently resolved file in the document (`prev_path`). Whenever a bullet or
  table row cites a second file in the middle (e.g., `send.cc:60-66` inside a `mgr.cc` row of
  `prefill_decode.md`, or `control_test.cc:754-790` between two `mgr.cc` bullets in `UuidTable.lean`,
  or `host_offload_backend.cc:1221` before `:722` in `findings/README.md`), subsequent bare `:N`
  citations silently bind to the wrong file on the next upstream sync. Fixed all 8 instances across
  `UuidTable.lean`, `PeerIsolation.lean`, `prefill_decode.md`, and `findings/README.md`, plus updated
  `findings/kv_cache_store_pin_race_test.cc`'s header comments to `50b0774` line numbers (`repin_citations.py`
  scans `.lean` and `.md` only, not `.cc`).
- **`slides/prefill_decode.typ`:** updated Slide 16's Lean snippet to match the actual
  `Recv.trace_failed_h2d_waits_for_other_layer` and `Recv.reachable_safe` declarations in
  `Receive.lean` (removing non-existent `System.runFrom` and `sys init s₀`), and aligned Slide 16–17
  test counts (`56` total: `27 + 6 + 10 + 4 + 4 + 5`) with `prefill_decode.md` §1–§5.
- **`notes/`:** cleaned up remaining namespace/symbol drift in `notes/durable/*.md`, `notes/loose-ends/parked.md`,
  `notes/AGENTS.md`, and `notes/journal/2026-10/*.md` (`Lifecycle.Consistent`, `Recv.trace_*`,
  `TryBeginRecvOp`/`++in_flight_`, `StartPush`, `BlockTransport::HandleIncomingPush`/`LayerProgress`,
  `WriteRemote`/`PollWriteRemote`, `WorkerServiceImpl::TransferBuffers`, `ReadRemote.shipping_inFlight`,
  and relative `../` links).

[OBS 2026-10-09] Sixth pass (`f6950942`) — statement-level pairing of the remaining sections of
`prefill_decode.md` not covered by the 58-pair trace/property pass (mutants table, bounded
searches, observations, shipping-vs-alternatives, boundaries, routing index, and all 40 test
correspondence rows paired with both their C++ test bodies and their Lean general theorems).
Two substantive mismatches surfaced where prose described a plausible mechanism or theorem name
rather than the Lean term:
1. `Send.sendNextUncounted` / `d2hIssueUncounted` (`prefill_decode.md` mutants table) claimed the
   mutant removed the D2H loop's `++in_flight_` (`send.cc:332`). In `Send.lean:1141-1165`, both
   `d2hIssueUncounted` and `sendNextUncounted` delegate to `trySendNextUncounted`, which removes
   only `SendNextLayer`'s `++in_flight_` (`send.cc:383`, reached from `SendNextLayer(0)` at
   `send.cc:365` and `SendNextLayer(l+1)` at `send.cc:451`).
2. `StatusIsFrozenOnceSessionIsDrainingOrDone` and `FailureCannotOverrideAnEarlierSuccess` (§1)
   cited `Lifecycle.finishOnceLocked_consistent` (`Consistent l → Consistent (finishOnceLocked ok l)`)
   for first-finish-wins status freeze instead of `Lifecycle.finishOnceLocked_decided` and
   `Lifecycle.finishOnceLocked_statusOk` (`Session.lean:269-287`).
Also added `PrefillDecode/PipelineChecks.lean` to the `HandlePullStream` routing row, added the
`ReceivePoll` `#guard` bounded searches, and pinned the Python test line ranges in §5 and
`PipelineChecks.lean`.
