# verification

AI-assisted formal verification of publication safety in TPU Sync: when
transferred KV-cache data can safely be made available to a consumer.

See [proposal.md](proposal.md) for the plan.

## Building

Requires [elan](https://github.com/leanprover/elan); the toolchain is pinned by
`lean-toolchain` (Lean 4.34.0) and fetched automatically.

```sh
cd verification
lake build
```
