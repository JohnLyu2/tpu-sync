# verification

AI-assisted formal verification of publication safety in TPU Sync: when
transferred KV-cache data can safely be made available to a consumer.

See [proposal.md](proposal.md) for the plan and
[docs/conventions.md](docs/conventions.md) for how the models are written.

## Layout

```
verification/
├── TpuSyncVerify.lean                       # imports every model
├── TpuSyncVerify/
│   ├── Common/                              # System, ListAux, bounded model checker
│   ├── Transfer/
│   │   ├── Session.lean                     # settle protocol shared by the session classes
│   │   └── PrefillDecode/                   # Receive, ReceivePoll, Send, Pipeline, MultiRequest,
│   │                                        # PipelineChecks, PeerIsolation, UuidTable, BlockOrdering
│   └── Controller/ReadRemote.lean           # exhaustive check behind finding F2
├── agents/tpu-sync-lean-helper/             # Lean-backed Q&A and code-reasoning subagent
├── docs/                                    # routing index + results (prefill_decode.md), replay evidence
│                                            # (prefill_decode_tests.md), conventions, upstream_rechecks.md
├── findings/                                # bug-hunt write-up, repro tests, patches
├── tools/                                   # repin_citations.py, run_lean.sh (stdin counterfactual runner)
└── slides/                                  # Typst deck (prefill_decode.typ)
```

## Status

All citations (models, `docs/`, `findings/`) are to tpu-sync `50b0774`
(upstream `main` as merged into this fork on 2026-10-06).

| Model | Properties | State | Doc |
|---|---|---|---|
| `Transfer/Session` | settle protocol invariant (`Consistent`) | proved | [prefill_decode.md](docs/transfer/prefill_decode.md) |
| `Transfer/PrefillDecode/Receive` | settle safety, no retired callback, staging integrity, prompt settle, readiness soundness, publication (counter form), no op leak / termination | proved; bounded search + mutants | same |
| `Transfer/PrefillDecode/ReceivePoll` | audit of the poll-side `IsReadyToComplete` finish: the last callback finishes first (`reachable_callbackFinishes`), the poll only fires in the pre-callback window and never settles (`pollReady_window`, `pollReady_no_settle`), `OnBlocksReceived` never finishes (`netAccount_frame`); without the poll every property and settlement are kept (`noPoll_safe`, `noPoll_can_settle`) and the end-of-transfer metrics are always recorded on success (`noPoll_metrics_on_success`, violated with the poll: `trace_poll_skips_metrics`); zero layers is the one case that needs it (`noPoll_zero_layers_never_succeeds`) | proved; bounded search | same |
| `Transfer/PrefillDecode/Send` | settle safety, drained, staging integrity, prompt settle, no underflow, publication (counter form), no op leak / termination | proved; bounded search + mutants | same |
| `Transfer/PrefillDecode/Pipeline` | single-request **publication correctness**, **decode HBM safety** (`DecodeHbmSafe`, `decodeHbm_quiet`, `attention_safe`), **prefill HBM safety** (`PrefillHbmSafe`, `prefillHbm_quiet`), **staging safety** (`StagingSafe`, `prefillStaging_quiet`, `decodeStaging_quiet`), **no op leak / termination** (`NoOpLeak`, `reachable_can_settle`), and handoff (`PrefillReleased`, `HandedOff`, `handedOff_quiet`, `inv_can_handoff`); layer-indexed, so layers complete in any order at every stage | proved | same |
| `Transfer/PrefillDecode/MultiRequest` | **system data correctness & attention safety across requests** (`system_data_correct`, `system_attention_safe`), **system progress across requests** (`system_progress`), proved over concurrent/overlapped requests (`reqs : List Pipeline`) with per-buffer read-after-release and write-after-release (`wroteReleased`) checks | proved | same |
| `Transfer/PrefillDecode/PipelineChecks` | concrete `decide` traces (normal, out-of-order layers, overlapped & recycled requests), `#guard` bounded searches, and mutants | checked | same |
| `Transfer/PrefillDecode/PeerIsolation` | cross-peer fault isolation: a decode consumer pulling from a `sick` and a `healthy` prefill peer that share `StagingBlockAllocator` slots and the `push_pool_`. Under the shipping unbounded-per-peer admission the sick peer pins every slot and healthy reads are *rejected* (`trace_sick_peer_starves_staging_slots`); on the TCP control plane a full pool blocks the healthy handshake (`tcp_healthy_blocked_when_pool_full`), on gRPC it completes (`grpc_healthy_can_complete`); a per-peer quota admits the healthy peer (`reachable_quota_admits_healthy`) | proved; `decide` traces, bounded search | same |
| `Transfer/PrefillDecode/UuidTable` | manager UUID tables (`active_recv_sessions_`, `send_sessions_`) and the drain-before-reuse discipline: a live session is never displaced by a same-uuid retry (`active_recv_preserved`, `active_send_preserved`), per-table safety (`reachable_recv_safe`, `reachable_send_safe`) | proved; bounded search + mutants | same |
| `Transfer/PrefillDecode/BlockOrdering` | within-layer block refinement of `Pipeline` (discharges its A1): block-index gather and dual-permutation `BuildLoadCopyPlan`, coalesced DMA runs equal element-wise copies on every memory (`execCoalesced_buildCoalescedSpec`), subset/uniqueness validation, custom host staging; `BlockPipeline.step_pipe` couples each block step to `Pipeline.step`, `BlockPipeline.reachable_safe` | proved; `decide` traces + mutants | same |
| `Controller/ReadRemote` | `NoWriteAfterRelease` | shipping code: counterexamples (shapes A, B); deferred-settle fix: safe by exhaustive search | [read_remote.md](docs/controller/read_remote.md) |

Outcome so far: no data-correctness or safety bugs in the prefill-to-decode
transfer path at `50b0774` (observations in the doc); one owner-acknowledged
availability gap on that path (F5, no per-peer staging admission at
`StartRead`) confirmed with the owners' own parked test and fixed by
`findings/per_peer_staging_admission.patch`; four confirmed defects in the
controller / KV-cache-store path, written up in
[findings/](findings/README.md). None fixed upstream as of `50b0774`.

## Building

Requires [elan](https://github.com/leanprover/elan); the toolchain is pinned by
`lean-toolchain` (Lean 4.34.0) and fetched automatically. No other
dependencies.

```sh
cd verification
lake build
```

A clean build takes about half a minute; every `theorem` is checked and every
`#guard` search is run, so a green build is the verification result.

## Maintenance after an upstream sync

All work happens on `main`; upstream is merged into it with a merge commit,
never by squash or rebase, so commit hashes cited here and in the notes stay
valid. Citations rot with every upstream commit. After merging a new upstream
`main`:

```sh
cd verification
python3 tools/repin_citations.py <old> <new>            # dry run: one line per citation
python3 tools/repin_citations.py <old> <new> --apply    # rewrites same/shift/grown
```

Read every `CHECK` line (the range overlaps edited code — re-read it and fix by
hand), then grep for citation lists that wrap onto a second line and for bare
backticked ranges after a comma (the script does not follow either). Update the
commit sentence in each module preamble, in this file, in `docs/*/*.md` and in
`findings/README.md` / `findings/filed_bugs.md`; re-run `git apply --check` on
the three patches in `findings/`; run `lake build`; add a row to
[docs/upstream_rechecks.md](docs/upstream_rechecks.md).
