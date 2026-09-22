/-!
# TPU Sync publication safety

Formal model of the TPU Sync remote-read protocol and proofs about when
transferred KV-cache data may be published to a consumer.

The modules below are added incrementally; see `docs/correspondence.md` for the
implementation facts each part of the model is required to match, and
`proposal.md` for the overall plan.
-/
