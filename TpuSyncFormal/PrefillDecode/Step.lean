import TpuSyncFormal.PrefillDecode.Types
import TpuSyncFormal.PrefillDecode.State

/-!
# Prefill-to-Decode Transfer Safety: Transition Steps

This module specifies executable step functions and the inductive transition relation
`Step s s'` modeling all discrete concurrent events across producer (Prefill),
network, consumer (Decode), and orchestrating manager (`KVCacheManagerWithTransfer`).

## C++ Method Correspondence:
- `stepD2hDispatch`: `TransferSendSession::StartPush` loop (`transfer_send_session.cc:323-336`)
- `stepD2hComplete`: `layer_future.OnReady` callback (`transfer_send_session.cc:352-355`)
- `stepH2hDispatch`: `SendNextLayer` -> `base_->H2hWriteDirectAsync` (`transfer_send_session.cc:410-415`)
- `stepH2hComplete`: `H2hWriteDirectAsync` completion callback (`transfer_send_session.cc:418-435`)
- `stepProducerTimeout`: `KVCacheManagerWithTransfer::CompleteReadRaw` (`kv_cache_manager_with_transfer.cc:853-859`)
- `stepProducerCompleteReadRaw`: `KVCacheManagerWithTransfer::CompleteReadRaw` (`kv_cache_manager_with_transfer.cc:860-866`)
- `stepNetworkLandChunk`: payload copy of a pushed chunk into consumer host staging
  inside `BlockTransport::HandleCustomRequest` (`transport/block_transport.cc:436-470`)
- `stepNetworkAccountLayerBlocks`: `BlockTransport::HandleCustomRequest` calling
  `OnBlocksReceived` (`transport/block_transport.cc:533`) →
  `TransferReceiveSession::RecordBlocksReceivedLocked` (`transfer_receive_session.cc:432-452`).
  The transport always dispatches the layer's H2D copy first
  (`OnLayerReceived`, `transport/block_transport.cc:525`), which is why the
  corresponding step rule requires `h2dDispatched l = true`.
- `stepH2dDispatch`: `TransferReceiveSession::ExecuteLayerH2d` (`transfer_receive_session.cc:568-598`)
- `stepH2dComplete`: `H2D` completion callback (`transfer_receive_session.cc:602-640`)
- `stepConsumerPollComplete`: `KVCacheManagerWithTransfer::CompleteReadRaw` polling `IsReadyToComplete()` (`kv_cache_manager_with_transfer.cc:898-901`)
- `stepConsumerTimeout`: `KVCacheManagerWithTransfer::CompleteReadRaw` (`kv_cache_manager_with_transfer.cc:902-909`)
- `stepConsumerCompleteReadRaw`: `KVCacheManagerWithTransfer::CompleteReadRaw` (`kv_cache_manager_with_transfer.cc:912-922`)
- `stepPrefillReclaimBuffer`: vLLM prefill engine freeing/overwriting HBM upon observing `done_sending`
- `stepDecodeConsumeAttention`: vLLM decode engine executing attention kernels upon observing `done_recving`
-/

namespace TpuSyncFormal.PrefillDecode

/-- Executable state transformation: Producer D2H dispatch for layer `l`. -/
def stepD2hDispatch (s : SystemState) (l : LayerId) : SystemState :=
  { s with
    producer := { s.producer with
      inFlight := s.producer.inFlight + 1
      d2hDispatched := fun idx => if idx = l then true else s.producer.d2hDispatched idx
    }
  }

/-- Executable state transformation: Producer D2H completion for layer `l`. -/
def stepD2hComplete (s : SystemState) (l : LayerId) : SystemState :=
  let newInFlight := s.producer.inFlight - 1
  let newDone := s.producer.draining && (newInFlight == 0)
  let updatedStaging := fun lyr bid =>
    if lyr = l ∧ bid < s.config.numBlocks then
      s.mem.prefillHbm lyr bid
    else
      s.mem.prefillStaging lyr bid
  { s with
    producer := { s.producer with
      inFlight := newInFlight
      d2hCompleted := fun idx => if idx = l then true else s.producer.d2hCompleted idx
      done := s.producer.done || newDone
    }
    mem := { s.mem with prefillStaging := updatedStaging }
  }

/-- Executable state transformation: Producer H2H push dispatch for layer `l`. -/
def stepH2hDispatch (s : SystemState) (l : LayerId) : SystemState :=
  { s with
    producer := { s.producer with
      inFlight := s.producer.inFlight + 1
      h2hDispatched := fun idx => if idx = l then true else s.producer.h2hDispatched idx
    }
  }

/-- Executable state transformation: Producer H2H push completion for layer `l`. -/
def stepH2hComplete (s : SystemState) (l : LayerId) : SystemState :=
  let newRemaining := s.producer.remainingH2h - 1
  let triggersFinish := (newRemaining == 0)
  let newDraining := s.producer.draining || triggersFinish
  let newInFlight := s.producer.inFlight - 1
  let newDone := newDraining && (newInFlight == 0)
  let updatedNetwork := fun lyr bid =>
    if lyr = l ∧ bid < s.config.numBlocks then
      s.mem.prefillStaging lyr bid
    else
      s.mem.networkInFlight lyr bid
  { s with
    producer := { s.producer with
      inFlight := newInFlight
      h2hCompleted := fun idx => if idx = l then true else s.producer.h2hCompleted idx
      remainingH2h := newRemaining
      draining := newDraining
      done := s.producer.done || newDone
    }
    mem := { s.mem with networkInFlight := updatedNetwork }
  }

/-- Executable state transformation: Producer timeout. -/
def stepProducerTimeout (s : SystemState) : SystemState :=
  let newDone := (s.producer.inFlight == 0)
  { s with
    producer := { s.producer with
      draining := true
      statusOk := false
      done := newDone
    }
  }

/-- Executable state transformation: Producer CompleteReadRaw. -/
def stepProducerCompleteReadRaw (s : SystemState) : SystemState :=
  if s.producer.statusOk then
    { s with doneSending := true }
  else
    { s with failedSending := true }

/-- Executable state transformation: **data landing only**.
    The chunk `(l, b)` that was in flight on the network is written into the
    consumer's host staging buffer. This models the payload half of
    `BlockTransport::HandleCustomRequest`, i.e. the `ReadExact`/`memcpy` of the
    pushed chunk into the destination host blocks
    (`tpu_sync/transport/block_transport.cc:436-470`).

    Crucially this step performs **no session accounting**: it does not touch
    `num_completed_blocks_` or `network_completed_`. Landing bytes in host DRAM is
    invisible to `TransferReceiveSession` until the transport explicitly reports
    them via `OnBlocksReceived`, which is modelled by
    `stepNetworkAccountLayerBlocks`. -/
def stepNetworkLandChunk (s : SystemState) (l : LayerId) (b : BlockId) : SystemState :=
  let updatedNetwork := fun lyr bid =>
    if lyr = l ∧ bid = b then none else s.mem.networkInFlight lyr bid
  let updatedStaging := fun lyr bid =>
    if lyr = l ∧ bid = b then s.mem.networkInFlight l b else s.mem.decodeStaging lyr bid
  { s with
    mem := { s.mem with
      networkInFlight := updatedNetwork
      decodeStaging := updatedStaging
    }
  }

/-- Executable state transformation: **session accounting only** for layer `l`'s blocks.
    Models `block_delegate_->OnBlocksReceived(allocated_ids, header.uuid)`
    (`tpu_sync/transport/block_transport.cc:533`), which reaches
    `TransferReceiveSession::RecordBlocksReceivedLocked`
    (`tpu_sync/core/transfer_receive_session.cc:432-452`):
    ```cpp
    num_completed_blocks_ += block_ids.size();
    ...
    if (num_completed_blocks_ >= total_blocks_ * static_cast<int32_t>(total_layers)) {
      network_completed_ = true;
      ...
    }
    ```
    `total_blocks_` is the number of distinct block transfers summed over *all*
    senders in the plan (`transfer_receive_session.cc:176-199`), so the threshold
    cannot be tripped early on a multi-sender plan.

    The transport ordering this step must respect lives in the step relation, not
    here: see `Step.networkAccountLayerBlocks`. -/
def stepNetworkAccountLayerBlocks (s : SystemState) (l : LayerId) : SystemState :=
  let newCompletedBlocks := s.consumer.completedBlocks + s.config.numBlocks
  let networkDone := decide (s.config.numLayers * s.config.numBlocks ≤ newCompletedBlocks)
  { s with
    consumer := { s.consumer with
      completedBlocks := newCompletedBlocks
      blocksAccounted := fun idx => if idx = l then true else s.consumer.blocksAccounted idx
      networkCompleted := s.consumer.networkCompleted || networkDone
    }
  }

/-- Executable state transformation: Consumer H2D dispatch for layer `l`. -/
def stepH2dDispatch (s : SystemState) (l : LayerId) : SystemState :=
  { s with
    consumer := { s.consumer with
      inFlight := s.consumer.inFlight + 1
      h2dDispatched := fun idx => if idx = l then true else s.consumer.h2dDispatched idx
    }
  }

/-- Executable state transformation: Consumer H2D completion for layer `l`. -/
def stepH2dComplete (s : SystemState) (l : LayerId) : SystemState :=
  let newCompletedLayers := s.consumer.completedLayers + 1
  let allLayersDone := (newCompletedLayers == s.config.numLayers)
  let triggersFinish := allLayersDone && !s.consumer.draining
  let newDraining := s.consumer.draining || triggersFinish
  let newInFlight := s.consumer.inFlight - 1
  let newDone := newDraining && (newInFlight == 0)
  let updatedHbm := fun lyr bid =>
    if lyr = l ∧ bid < s.config.numBlocks then
      s.mem.decodeStaging lyr bid
    else
      s.mem.decodeHbm lyr bid
  { s with
    consumer := { s.consumer with
      inFlight := newInFlight
      h2dCompleted := fun idx => if idx = l then true else s.consumer.h2dCompleted idx
      completedLayers := newCompletedLayers
      draining := newDraining
      done := s.consumer.done || newDone
      hasStaging := if newDone then false else s.consumer.hasStaging
    }
    mem := { s.mem with decodeHbm := updatedHbm }
  }

/-- Executable state transformation: Consumer poll completion in `CompleteReadRaw`. -/
def stepConsumerPollComplete (s : SystemState) : SystemState :=
  let newDone := (s.consumer.inFlight == 0)
  { s with
    consumer := { s.consumer with
      draining := true
      done := newDone
      hasStaging := if newDone then false else s.consumer.hasStaging
    }
  }

/-- Executable state transformation: Consumer timeout past deadline. -/
def stepConsumerTimeout (s : SystemState) : SystemState :=
  let newDone := (s.consumer.inFlight == 0)
  { s with
    consumer := { s.consumer with
      draining := true
      statusOk := false
      done := newDone
      hasStaging := if newDone then false else s.consumer.hasStaging
    }
  }

/-- Executable state transformation: Consumer CompleteReadRaw. -/
def stepConsumerCompleteReadRaw (s : SystemState) : SystemState :=
  if s.consumer.statusOk then
    { s with doneRecving := true }
  else
    { s with failedRecving := true }

/-- Executable state transformation: Prefill engine buffer reclaim/reuse. -/
def stepPrefillReclaimBuffer (s : SystemState) : SystemState :=
  let overwrittenHbm := fun (lyr : LayerId) (bid : BlockId) =>
    some { sourceReq := 99999, layer := lyr, block := bid, tag := 99999 }
  { s with
    sourceBufferFreed := true
    mem := { s.mem with prefillHbm := overwrittenHbm }
  }

/-- Executable state transformation: Decode engine attention kernel launch. -/
def stepDecodeConsumeAttention (s : SystemState) : SystemState :=
  { s with consumerConsumed := true }

/-- Inductive step relation: `Step s s'` defines allowed non-deterministic transitions. -/
inductive Step : SystemState → SystemState → Prop where

  | d2hDispatch (l : LayerId) (s : SystemState) :
      l < s.config.numLayers →
      s.producer.draining = false →
      s.producer.d2hDispatched l = false →
      Step s (stepD2hDispatch s l)

  | d2hComplete (l : LayerId) (s : SystemState) :
      l < s.config.numLayers →
      s.producer.d2hDispatched l = true →
      s.producer.d2hCompleted l = false →
      0 < s.producer.inFlight →
      Step s (stepD2hComplete s l)

  | h2hDispatch (l : LayerId) (s : SystemState) :
      l < s.config.numLayers →
      s.producer.d2hCompleted l = true →
      s.producer.draining = false →
      s.producer.h2hDispatched l = false →
      Step s (stepH2hDispatch s l)

  | h2hComplete (l : LayerId) (s : SystemState) :
      l < s.config.numLayers →
      s.producer.h2hDispatched l = true →
      s.producer.h2hCompleted l = false →
      0 < s.producer.inFlight →
      0 < s.producer.remainingH2h →
      Step s (stepH2hComplete s l)

  | producerTimeout (s : SystemState) :
      s.producer.draining = false →
      s.producer.done = false →
      Step s (stepProducerTimeout s)

  | producerCompleteReadRaw (s : SystemState) :
      s.producer.done = true →
      s.doneSending = false →
      s.failedSending = false →
      Step s (stepProducerCompleteReadRaw s)

  /-- Payload of chunk `(l, b)` lands in the consumer's host staging buffer.
      Pure data movement: no session counter is touched. -/
  | networkLandChunk (l : LayerId) (b : BlockId) (s : SystemState) :
      l < s.config.numLayers →
      b < s.config.numBlocks →
      s.mem.networkInFlight l b ≠ none →
      s.mem.decodeStaging l b = none →
      Step s (stepNetworkLandChunk s l b)

  /-- **Transport ordering rule.** The transport may only account layer `l`'s blocks
      into `num_completed_blocks_` after it has dispatched layer `l`'s H2D copy.

      This mirrors `BlockTransport::HandleCustomRequest`, which for the request that
      completes layer `l` runs, in this order and on the same thread:
      - `tpu_sync/transport/block_transport.cc:525`
        `block_delegate_->OnLayerReceived(l, header.uuid)` — dispatches layer `l`'s
        H2D copy and, before returning, synchronously pushes the resulting future
        into `h2d_futures_` (`tpu_sync/core/transfer_receive_session.cc:594-598`);
      - `tpu_sync/transport/block_transport.cc:533`
        `block_delegate_->OnBlocksReceived(allocated_ids, header.uuid)` — folds that
        request's blocks into `num_completed_blocks_`.

      The `blocksAccounted` guard records that a layer's blocks are counted exactly
      once. Modelling assumption: with several senders per layer, the real code may
      account *some* of layer `l`'s blocks before `OnLayerReceived(l)` fires; but the
      accounting that *completes* layer `l` is always preceded by dispatch, because
      `trigger_completion` (and hence `OnLayerReceived`) fires on that same final
      request (`block_transport.cc:441-525`). Lumping a layer's accounting into that
      final, dispatch-ordered event is therefore sound for the threshold reasoning:
      `num_completed_blocks_` can only reach `total_blocks_ * total_layers` once every
      layer's final request has been handled. -/
  | networkAccountLayerBlocks (l : LayerId) (s : SystemState) :
      l < s.config.numLayers →
      s.consumer.h2dDispatched l = true →
      s.consumer.blocksAccounted l = false →
      Step s (stepNetworkAccountLayerBlocks s l)

  /-- `OnLayerReceived(l)` → `TransferReceiveSession::ExecuteLayerH2d`
      (`transfer_receive_session.cc:568-598`): the layer's H2D copy is issued and its
      future is appended to `h2d_futures_`. The transport only fires this once every
      chunk of layer `l` has landed in host staging (`trigger_completion` in
      `block_transport.cc:441-525`), which is the unchanged staging precondition
      below. -/
  | h2dDispatch (l : LayerId) (s : SystemState) :
      l < s.config.numLayers →
      s.consumer.draining = false →
      s.consumer.done = false →
      s.consumer.h2dDispatched l = false →
      (∀ b : BlockId, b < s.config.numBlocks → s.mem.decodeStaging l b ≠ none) →
      Step s (stepH2dDispatch s l)

  | h2dComplete (l : LayerId) (s : SystemState) :
      l < s.config.numLayers →
      s.consumer.h2dDispatched l = true →
      s.consumer.h2dCompleted l = false →
      0 < s.consumer.inFlight →
      Step s (stepH2dComplete s l)

  | consumerPollComplete (s : SystemState) :
      s.consumer.draining = false →
      s.consumer.done = false →
      isReadyToComplete s = true →
      Step s (stepConsumerPollComplete s)

  | consumerTimeout (s : SystemState) :
      s.consumer.draining = false →
      s.consumer.done = false →
      Step s (stepConsumerTimeout s)

  | consumerCompleteReadRaw (s : SystemState) :
      s.consumer.done = true →
      s.doneRecving = false →
      s.failedRecving = false →
      Step s (stepConsumerCompleteReadRaw s)

  | prefillReclaimBuffer (s : SystemState) :
      s.doneSending = true →
      s.sourceBufferFreed = false →
      Step s (stepPrefillReclaimBuffer s)

  | decodeConsumeAttention (s : SystemState) :
      s.doneRecving = true →
      s.consumerConsumed = false →
      Step s (stepDecodeConsumeAttention s)

/-- Multi-step reachability: reflexive-transitive closure of `Step`. -/
inductive Reachable (init : SystemState) : SystemState → Prop where
  | refl : Reachable init init
  | step {s s' : SystemState} : Reachable init s → Step s s' → Reachable init s'

end TpuSyncFormal.PrefillDecode
