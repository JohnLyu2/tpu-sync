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
│   ├── Common/                              # System, Reachable, bounded model checker
│   ├── Transfer/
│   │   ├── Session.lean                     # settle protocol shared by the session classes
│   │   └── PrefillDecode/                   # the proposal's model: Receive, Send, Pipeline
│   └── Controller/ReadRemote.lean           # exhaustive check behind finding F2
├── docs/                                    # correspondence tables, results, future work
└── findings/                                # bug-hunt write-up, repro tests, patches
```

## Status

Citations are to tpu-sync `01ffa3d`.

| Model | Properties | State | Doc |
|---|---|---|---|
| `Transfer/Session` | settle protocol invariant (`Consistent`) | proved | [prefill_decode.md](docs/transfer/prefill_decode.md) |
| `Transfer/PrefillDecode/Receive` | settle safety, no retired callback, staging integrity, prompt settle, readiness soundness, publication (counter form) | proved; bounded search + mutants | same |
| `Transfer/PrefillDecode/Send` | settle safety, drained, staging integrity, prompt settle, no underflow, publication (counter form) | proved; bounded search + mutants | same |
| `Transfer/PrefillDecode/Pipeline` | **publication correctness**, **attention safety**, **source-buffer safety**, **staging safety**; layer-indexed, so layers complete in any order at every stage | proved; bounded search + mutants | same |
| `Controller/ReadRemote` | `NoWriteAfterRelease` | shipping code: counterexamples (shapes A, B); deferred-settle fix: safe by exhaustive search | [read_remote.md](docs/controller/read_remote.md) |

Outcome so far: no bugs in the prefill-to-decode transfer path at `01ffa3d`
(observations in the doc); four confirmed defects in the controller /
KV-cache-store path, written up in [findings/](findings/README.md).

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
