import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Transfer.Session
import TpuSyncVerify.Transfer.PrefillDecode.Receive
import TpuSyncVerify.Transfer.PrefillDecode.Send

/-!
# TpuSyncVerify

Formal models of TPU Sync protocols and proofs about them, organised by the
subsystem of `tpu_sync/` they describe:

* `Common` — the transition-system core and a bounded model checker shared by
  every model.
* `Transfer` — the session-based KV transfer path (`tpu_sync/core/transfer_*`,
  `tpu_sync/transport`). `Transfer.PrefillDecode` is the prefill-to-decode
  model of `proposal.md`, built up in stages.

Every module states which tpu-sync commit its citations were checked against.
-/
