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
│   │   ├── PrefillDecode/                   # Receive, ReceivePoll, Send, Pipeline, MultiRequest,
│   │   │                                    # PipelineChecks, PeerIsolation, UuidTable, BlockOrdering
│   │   └── Reshard/                         # Receive, Send, Pipeline, Coverage, PoolStaging,
│   │                                        # Registry, Coordinator (Stages 1–4 of docs/transfer/reshard.md)
│   └── Controller/ReadRemote.lean           # exhaustive check behind finding F2
├── agents/tpu-sync-lean-helper/             # Lean-backed Q&A and code-reasoning subagent
├── docs/                                    # prefill_decode.md (C++→Lean map, results), conventions, upstream_rechecks.md
├── findings/                                # bug-hunt write-up, repro tests, patches
├── tools/                                   # repin_citations.py, run_lean.sh (stdin counterfactual runner)
└── slides/                                  # Typst deck (prefill_decode.typ)
```

## Status

All citations (models, `docs/`, `findings/`) are to tpu-sync `0ac16d1`
(upstream `main` as merged into this fork on 2026-10-16); `findings/filed_bugs.md`
and `proposal.md` are frozen at the commit they name.

| Model | Proved | Doc |
|---|---|---|
| `Transfer/Session` | settle-protocol invariant `Lifecycle.Consistent` | [prefill_decode.md](docs/transfer/prefill_decode.md) |
| `PrefillDecode/Receive`, `Send` | per-session settle safety, staging integrity, counter conservation, readiness soundness, publication (counter form), no op leak; bounded search + mutants | same |
| `PrefillDecode/ReceivePoll` | what the poll-side `IsReadyToComplete` finish contributes; without it every property holds and metrics are always recorded | same |
| `PrefillDecode/Pipeline`, `BlockOrdering` | single-request publication correctness, decode/prefill HBM and staging safety, handoff, termination; refined to block level (gather, dual-permutation `BuildLoadCopyPlan`, DMA coalescing) | same |
| `PrefillDecode/MultiRequest` | data correctness, attention safety and progress across concurrent/overlapped requests recycling the four buffers | same |
| `PrefillDecode/PeerIsolation`, `UuidTable` | cross-peer fault isolation (staging slots, `push_pool_`, TCP vs gRPC; per-peer quota admits healthy peers); UUID drain-before-reuse | same |
| `PrefillDecode/PipelineChecks` | `decide` traces, `#guard` searches, mutants | same |
| `Reshard/Receive`, `Send` | `ReshardReceiveSession` and `ReshardSendSession` (`CountPoolReshardSendSlots`) on `Session.Lifecycle`: settle safety, `PoolStagingLease` & plan-registration lifecycle (`PlanIntegrity`), rank-ordered pool H2D waves (`RankWaveOrder`), multi-pool publication, termination, `IsReadyToComplete` redundancy (R3), `end_incoming_push` error policy (R1); `decide` traces, bounded search + mutants | [reshard.md](docs/transfer/reshard.md) |
| `Reshard/Pipeline`, `Coverage` | end-to-end reshard pipeline (`Send` + `Recv` + per-pool transport streams + 5 memories + aliased-page `writePoolHbm` + arm-then-dispatch barrier): publication & aliased-page correctness, HBM/staging safety, stream accounting, termination; refined to sub-block byte-interval coverage, multi-sender stream conservation, and permutation-invariant block reconstruction | same |
| `Reshard/PoolStaging` | bounded `PoolStagingStorage` arena & per-UUID page-lease lifecycle: idempotent re-acquisition, slot conservation, cross-UUID disjointness, duplicate-UUID registration race (R5 / F6: `.reserveBeforeLease` shipping fix vs. `.leaseBeforeReserve` counterexample) | same |
| `Reshard/Registry`, `Coordinator` | `RequestBlockRegistry` generation lifecycle (multi-owner claims, full-set voting, tombstones, TTL expiration, R7, R8) composed with two-stage `ReshardCoordinator::ExecutePoolReshard` (arm + dispatch barriers, R2a/R2b orphan counterexamples under `.shipping` vs. `.disarmAndAbandonOnFailure` cleanup) | same |
| `Controller/ReadRemote` | `NoWriteAfterRelease`: counterexamples on shipping code, deferred-settle fix safe by exhaustive search | [read_remote.md](docs/controller/read_remote.md) |

Outcome so far: no data-correctness or safety bugs in the prefill-to-decode
transfer path at `0ac16d1` (non-bug observations in [findings/](findings/README.md) §Observations); one owner-acknowledged
availability gap on that path (F5, no per-peer staging admission at
`StartRead`) confirmed with the owners' own parked test and fixed by
a per-peer admission patch (validated on `50b0774`, retired 2026-10-16 when the allocator moved); four confirmed defects in the
controller / KV-cache-store path, written up in
[findings/](findings/README.md), F4 fixed upstream in `72255dd` (PR #1105); and one
memory-aliasing defect on the pool-reshard receive path (F6, a rejected duplicate
`PoolReshardRegisterRecv` frees the active session's staging lease), filed
2026-10-13 and fixed upstream the same day in `8653373`. F1, F2, F3 and F5 are open as of `0ac16d1`.

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
`findings/README.md` (`findings/filed_bugs.md` and `proposal.md` are frozen); re-run `git apply --check` on
the two patches in `findings/`; run `lake build`; add a row to
[docs/upstream_rechecks.md](docs/upstream_rechecks.md).
