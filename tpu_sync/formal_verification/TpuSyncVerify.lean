import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Common.ListAux
import TpuSyncVerify.Transfer.Session
import TpuSyncVerify.Transfer.PrefillDecode.Receive
import TpuSyncVerify.Transfer.PrefillDecode.ReceivePoll
import TpuSyncVerify.Transfer.PrefillDecode.Send
-- The remaining Transfer models and the Controller model land in follow-up
-- changes and are imported here as they arrive.

/-!
# TpuSyncVerify

Lean 4 models of TPU Sync's KV-cache data paths and machine-checked proofs
about them. This module imports every model; see `README.md` for what is
modelled, the directory layout, and how the C++ is cited.

* `Common` — transition-system core, list lemmas, bounded model checker.
* `Transfer` — `Session` (settle protocol shared by every transfer session),
  `PrefillDecode/`, `Reshard/`.
* `Controller` — `ReadRemote`.
-/
