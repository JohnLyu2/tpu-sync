# tpu-sync-formal

AI-assisted formal verification of publication safety in
[TPU Sync](https://github.com/google/tpu-sync): when transferred KV-cache data
can safely be made available to a consumer.

See [proposal.md](proposal.md) for the plan.

## Building

Requires [elan](https://github.com/leanprover/elan); the toolchain is pinned by
`lean-toolchain` (Lean 4.34.0) and fetched automatically.

```sh
lake build
```

## Status: the shipping completion predicate is safe

`TransferReceiveSession::IsReadyToComplete()` — `(network_completed_ ||
num_completed_layers_ == total_layers) && AllH2dDoneLocked()` — is **correct**. On every
reachable state of the model it implies that all H2D copies have finished, hence that
every KV block is committed to decode HBM before `done_recving` is published.

The `network_completed_` disjunct is sound because the transport dispatches a layer's
H2D copy (`OnLayerReceived`, `block_transport.cc:525`) before it accounts that layer's
blocks (`OnBlocksReceived`, `block_transport.cc:533`), so `h2d_futures_` is already
complete whenever `network_completed_` is set.

| Module | Contents |
| --- | --- |
| `TpuSyncFormal/PrefillDecode/Types.lean`, `State.lean` | State space and the two readiness predicates |
| `Step.lean` | Transition relation, including the transport ordering precondition |
| `Properties.lean` | Safety specifications |
| `Invariants.lean` | The inductive invariant and its preservation proof |
| `Proof.lean` | Main theorems + a concrete transport-ordered execution |
| `HypotheticalReordering.lean` | A counterfactual, **not** a defect: what would break if the transport accounted blocks before dispatching a layer |

An earlier revision of this project claimed a publication bug in the shipping
predicate. That claim was an artifact of a modelling error and has been retracted; see
`docs/prefill_decode_correspondence.md` §3.

