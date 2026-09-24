import TpuSyncFormal.PrefillDecode.Types
import TpuSyncFormal.PrefillDecode.State
import TpuSyncFormal.PrefillDecode.Step
import TpuSyncFormal.PrefillDecode.Properties
import TpuSyncFormal.PrefillDecode.Invariants
import TpuSyncFormal.PrefillDecode.Proof
import TpuSyncFormal.PrefillDecode.HypotheticalReordering

/-!
# TPU Sync: Prefill-to-Decode Transfer Safety

Formal model of TPU Sync's prefill-to-decode transfer pipeline in Lean 4.
Covers DMA operations (D2H, H2D), multi-stream network chunk streaming,
asynchronous session lifecycles (`TransferSendSession`, `TransferReceiveSession`),
completion polling (`CompleteReadRaw`), and publication safety properties.

## Main result

The completion predicate TPU Sync ships,
`TransferReceiveSession::IsReadyToComplete()`, is **safe**: on every reachable state
it implies that all H2D copies have finished, hence that every KV block is committed
to decode HBM before `done_recving` is published
(`PrefillDecode.shipping_predicate_implies_all_h2d_completed`,
`PrefillDecode.reachable_system_safety`). The argument rests on the transport ordering
invariant `PrefillDecode.transport_ordering_invariant`, which reflects the fact that
`BlockTransport::HandleCustomRequest` dispatches a layer's H2D copy before accounting
that layer's blocks.

`PrefillDecode.HypotheticalReordering` documents — as a counterfactual, not as a
defect — what would break if that transport ordering were removed.
-/
