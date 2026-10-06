import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Common.ListAux
import TpuSyncVerify.Transfer.Session
import TpuSyncVerify.Transfer.PrefillDecode.Receive
import TpuSyncVerify.Transfer.PrefillDecode.ReceivePoll
import TpuSyncVerify.Transfer.PrefillDecode.Send
import TpuSyncVerify.Transfer.PrefillDecode.Pipeline
import TpuSyncVerify.Transfer.PrefillDecode.MultiRequest
import TpuSyncVerify.Transfer.PrefillDecode.PeerIsolation
import TpuSyncVerify.Transfer.PrefillDecode.UuidTable
import TpuSyncVerify.Transfer.PrefillDecode.BlockOrdering
import TpuSyncVerify.Transfer.PrefillDecode.PipelineChecks
import TpuSyncVerify.Controller.ReadRemote

/-!
# TpuSyncVerify

Formal models of TPU Sync protocols and proofs about them, organised by the
subsystem of `tpu_sync/` they describe:

* `Common` — the transition-system core, list/pigeonhole lemmas, and a bounded
  model checker shared by every model.
* `Transfer` — the session-based KV transfer path (`tpu_sync/core/transfer_*`,
  `tpu_sync/transport`). `Transfer.PrefillDecode` is the prefill-to-decode
  model of `proposal.md`, built up in stages through single-request (`Pipeline`)
  and multi-request (`MultiRequest`) proofs plus executable checks
  (`PipelineChecks`).
* `Controller` — `RaidenController` (`tpu_sync/core/controller`).
  `Controller.ReadRemote` is the exhaustive check behind finding F2 in
  `findings/`.

Every module states which tpu-sync commit its citations were checked against.
-/
