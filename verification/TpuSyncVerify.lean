/-!
# TPU Sync publication safety

Formal model of the TPU Sync remote-read protocol and proofs about when
transferred KV-cache data may be published to a consumer.

The modules below are added incrementally; see `proposal.md` for the overall
plan.
-/
