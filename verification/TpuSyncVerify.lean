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
import TpuSyncVerify.Transfer.PrefillDecode.Transport
import TpuSyncVerify.Transfer.PrefillDecode.Caller
import TpuSyncVerify.Transfer.Reshard.Receive
import TpuSyncVerify.Transfer.Reshard.Send
import TpuSyncVerify.Transfer.Reshard.Pipeline
import TpuSyncVerify.Transfer.Reshard.Coverage
import TpuSyncVerify.Transfer.Reshard.PoolStaging
import TpuSyncVerify.Transfer.Reshard.Registry
import TpuSyncVerify.Transfer.Reshard.Coordinator
import TpuSyncVerify.Controller.ReadRemote

/-!
# TpuSyncVerify

Formal models of TPU Sync protocols and proofs about them, organised by the
subsystem of `tpu_sync/` they describe:

* `Common` — the transition-system core, list/pigeonhole lemmas, and a bounded
  model checker shared by every model.
* `Transfer` — the session-based KV transfer path (`tpu_sync/kv_cache/transfer_*`,
  `tpu_sync/kv_cache/reshard_*`, `tpu_sync/kv_cache/kv_cache_manager_with_transfer.*`,
  `tpu_sync/transport`): shared session lifecycle (`Transfer.Session`); under
  `Transfer.PrefillDecode` the consumer and producer sessions (`Receive`,
  `ReceivePoll`, `Send`), single- and multi-request pipelines (`Pipeline`,
  `MultiRequest`, `PipelineChecks`), the transport's receiver-side stream
  accounting behind `Receive` A1/A4 (`Transport`), the engine above
  `poll_stats()` — vLLM's scheduler through tpu-inference's connector, the
  other direction of `Pipeline` A4 and the model behind finding C1
  (`Caller`) — multi-peer fault isolation (`PeerIsolation`),
  UUID registration table (`UuidTable`), and block-level gather/reordering/coalescing
  (`BlockOrdering`); and under `Transfer.Reshard` the pool-addressed resharding
  path (`Receive`, `Send`, `Pipeline`, `Coverage`, `PoolStaging`, `Registry`,
  `Coordinator`) of `docs/transfer/reshard.md`.
* `Controller` — `RaidenController` (`tpu_sync/core/controller`).
  `Controller.ReadRemote` is the exhaustive check behind finding F2 (bug-hunt
  reports live in the fork, see `README.md`).

Every module states which tpu-sync commit its citations were checked against.
-/
