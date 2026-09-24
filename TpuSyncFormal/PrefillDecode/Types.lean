/-!
# Prefill-to-Decode Transfer Safety: Types

This module defines the basic identifier types, payloads, and lifecycle states
for modeling TPU Sync's prefill-to-decode transfer pipeline in Lean 4.

## C++ Correspondence:
- `BlockId`: Corresponding to `int64_t block_id` (`tpu_sync/core/raw_transfer_core.h`)
- `LayerId`: Corresponding to `size_t layer_idx` in `TransferSendSession::SendNextLayer`
  and `TransferReceiveSession::ExecuteLayerH2d` (`transfer_send_session.h:161`, `transfer_receive_session.h:141`)
- `ReqId`: Corresponding to `std::string req_id_` / `uint64_t uuid_` (`transfer_session.h`)
- `SessionState`: Models the lifecycle flags (`in_flight_`, `draining_`, `done_`, `status_`)
  in `TransferSendSession` and `TransferReceiveSession`.
-/

namespace TpuSyncFormal.PrefillDecode

/-- Unique request identifier. Corresponds to `std::string req_id_` / `uuid_`. -/
abbrev ReqId := Nat

/-- Model layer index, `0 ≤ layer < num_layers`. Corresponds to `size_t layer_idx`. -/
abbrev LayerId := Nat

/-- Physical or logical KV cache block identifier. Corresponds to `int64_t block_id`. -/
abbrev BlockId := Nat

/-- Symbolic block data representing the content of a KV-cache block.
    We track the generating request, layer, and block index to verify that
    the consumer never observes uninitialized, stale, or cross-request data. -/
structure BlockContent where
  sourceReq : ReqId
  layer : LayerId
  block : BlockId
  tag : Nat := 0
deriving DecidableEq, Repr

/-- Status of an individual DMA or network copy operation. -/
inductive CopyStatus where
  | idle
  | inFlight
  | ready
  | failed
deriving DecidableEq, Repr

/-- Protocol check mode for receive readiness.

    **Both modes are safe** on the reachable states of this model; see
    `TpuSyncFormal.PrefillDecode.readiness_predicates_agree`. They differ only in
    *what they rely on* to be safe:

    - `transportOrderingDependent`: models TPU Sync's shipping `IsReadyToComplete()`
      (`(network_completed_ || layers_done) && AllH2dDoneLocked()`,
      `tpu_sync/core/transfer_receive_session.cc:425-430`), where
      `AllH2dDoneLocked()` only tests the futures currently in `h2d_futures_`.
      Its safety is *conditional on the transport ordering invariant*: the transport
      dispatches a layer's H2D copy (`OnLayerReceived`) before it accounts that
      layer's blocks (`OnBlocksReceived`), so `network_completed_` can only be set
      once every layer already has a future in `h2d_futures_`. That ordering is
      guaranteed by `BlockTransport::HandleCustomRequest`
      (`tpu_sync/transport/block_transport.cc:519-533`) and is modelled by the
      precondition of `Step.networkAccountLayerBlocks`.
    - `selfContained`: requires that all layers have completed their H2D DMA copy into
      HBM without appealing to any transport-level ordering. This variant is safe even
      in a hypothetically reordered transport, at the cost of being slightly stricter.

    Neither mode is a bug: the naming records which external assumption each one needs. -/
inductive CheckMode where
  | transportOrderingDependent
  | selfContained
deriving DecidableEq, Repr

end TpuSyncFormal.PrefillDecode
