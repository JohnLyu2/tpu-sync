import TpuSyncFormal.PrefillDecode.Types

/-!
# Prefill-to-Decode Transfer Safety: State

This module formalizes the system state of the TPU Sync prefill-to-decode pipeline,
including physical memories (Prefill HBM, Host Staging, Network in-flight chunks,
Decode Host Staging, and Decode HBM) and session control registers.

## C++ Correspondence:
- `ProducerSessionState`: Models `TransferSendSession`
  - `in_flight_` (`transfer_send_session.h:181`)
  - `draining_` (`transfer_send_session.h:184`)
  - `done_` (`transfer_send_session.h:185`)
  - `remaining_h2h_layers_` (`transfer_send_session.h:190`)
  - `d2h_layer_futures_` (`transfer_send_session.h:186`)
- `ConsumerSessionState`: Models `TransferReceiveSession`
  - `in_flight_` (`transfer_receive_session.h:241`)
  - `draining_` (`transfer_receive_session.h:243`)
  - `done_` (`transfer_receive_session.h:244`)
  - `network_completed_` (`transfer_receive_session.h:239`)
  - `num_completed_layers_` (`transfer_receive_session.h:238`)
  - `num_completed_blocks_` (`transfer_receive_session.h:237`)
  - `h2d_futures_` (`transfer_receive_session.h:248`)
  - `blocksAccounted` is a ledger (no single C++ field) recording which layers'
    blocks `OnBlocksReceived` has already folded into `num_completed_blocks_`;
    it exists so that the model cannot count the same blocks twice.
- Manager State: Models `KVCacheManagerWithTransfer`
  - `done_sending_`, `done_recving_`, `failed_recving_` (`kv_cache_manager_with_transfer.h`)
-/

namespace TpuSyncFormal.PrefillDecode

/-- Static transfer configuration for a request. -/
structure TransferConfig where
  reqId : ReqId
  numLayers : Nat
  numBlocks : Nat
  numLayers_pos : 0 < numLayers
  numBlocks_pos : 0 < numBlocks
deriving Repr

/-- State of the producer transfer send session (`TransferSendSession`). -/
structure ProducerSessionState where
  inFlight : Nat := 0
  draining : Bool := false
  done : Bool := false
  statusOk : Bool := true
  d2hDispatched : LayerId → Bool := fun _ => false
  d2hCompleted : LayerId → Bool := fun _ => false
  h2hDispatched : LayerId → Bool := fun _ => false
  h2hCompleted : LayerId → Bool := fun _ => false
  remainingH2h : Nat := 0

/-- State of the consumer transfer receive session (`TransferReceiveSession`). -/
structure ConsumerSessionState where
  inFlight : Nat := 0
  draining : Bool := false
  done : Bool := false
  statusOk : Bool := true
  hasStaging : Bool := true
  networkCompleted : Bool := false
  h2dDispatched : LayerId → Bool := fun _ => false
  h2dCompleted : LayerId → Bool := fun _ => false
  completedLayers : Nat := 0
  completedBlocks : Nat := 0
  /-- Ledger of which layers' blocks have already been counted into
      `num_completed_blocks_` by `OnBlocksReceived` /
      `RecordBlocksReceivedLocked` (`transfer_receive_session.cc:432-452`).
      A layer's blocks are accounted exactly once, so this ledger keeps
      `completedBlocks` in step with the set of accounted layers. -/
  blocksAccounted : LayerId → Bool := fun _ => false

/-- Symbolic contents of physical and host memory buffers across nodes. -/
structure PhysicalMemory where
  prefillHbm : LayerId → BlockId → Option BlockContent
  prefillStaging : LayerId → BlockId → Option BlockContent
  networkInFlight : LayerId → BlockId → Option BlockContent
  decodeStaging : LayerId → BlockId → Option BlockContent
  decodeHbm : LayerId → BlockId → Option BlockContent

/-- Global state of the prefill-to-decode system. -/
structure SystemState where
  config : TransferConfig
  mode : CheckMode
  producer : ProducerSessionState
  consumer : ConsumerSessionState
  mem : PhysicalMemory
  -- Manager published completion flags (observed by vLLM via `poll_stats()`)
  doneSending : Bool := false
  doneRecving : Bool := false
  failedSending : Bool := false
  failedRecving : Bool := false
  -- External engine lifecycle states
  sourceBufferFreed : Bool := false
  consumerConsumed : Bool := false

/-- In TPU Sync, `TransferReceiveSession::AllH2dDoneLocked()` iterates over
    the dispatched `h2d_futures_` vector and checks whether every future is ready.
    If a layer has not yet been dispatched, it has no entry in `h2d_futures_`,
    so it is not checked by `AllH2dDoneLocked()`. -/
def allDispatchedH2dDone (cfg : TransferConfig) (c : ConsumerSessionState) : Bool :=
  (List.range cfg.numLayers).all fun l =>
    !c.h2dDispatched l || c.h2dCompleted l

/-- The readiness predicate that TPU Sync actually ships, transcribed from
    `TransferReceiveSession::IsReadyToComplete()`
    (`tpu_sync/core/transfer_receive_session.cc:425-430`):
    `(network_completed_ || num_completed_layers_ == total_layers) && AllH2dDoneLocked()`.

    Read in isolation, the `network_completed_` disjunct looks dangerous, because
    `AllH2dDoneLocked()` only inspects layers that already have a future in
    `h2d_futures_`. It is nevertheless sound, because the transport establishes the
    ordering invariant `networkCompleted → every layer is dispatched`
    (`Step.networkAccountLayerBlocks`, mirroring
    `block_transport.cc:519-533`); see `transport_ordering_invariant` and
    `shipping_predicate_implies_all_h2d_completed` in `Proof.lean`. -/
def readyShipping (s : SystemState) : Bool :=
  (s.consumer.networkCompleted || s.consumer.completedLayers == s.config.numLayers) &&
    allDispatchedH2dDone s.config s.consumer

/-- A readiness predicate that does not depend on any transport-level ordering:
    it names all `numLayers` layers explicitly instead of quantifying over the
    dynamically-populated `h2d_futures_` vector. -/
def readySelfContained (s : SystemState) : Bool :=
  s.consumer.completedLayers == s.config.numLayers &&
    (List.range s.config.numLayers).all fun l => s.consumer.h2dCompleted l

/-- Evaluation of `TransferReceiveSession::IsReadyToComplete()` in the selected mode.
    `readiness_predicates_agree` shows the two modes coincide on every reachable
    state, so the mode is a modelling knob, not a behavioural difference. -/
def isReadyToComplete (s : SystemState) : Bool :=
  match s.mode with
  | CheckMode.transportOrderingDependent => readyShipping s
  | CheckMode.selfContained => readySelfContained s

/-- Initial state constructor for a transfer with valid initial data in prefill HBM. -/
def initialState (cfg : TransferConfig) (mode : CheckMode) : SystemState :=
  let expectedData (l : LayerId) (b : BlockId) : Option BlockContent :=
    if l < cfg.numLayers ∧ b < cfg.numBlocks then
      some { sourceReq := cfg.reqId, layer := l, block := b, tag := 1 }
    else
      none
  {
    config := cfg
    mode := mode
    producer := {
      inFlight := 0
      draining := false
      done := false
      statusOk := true
      d2hDispatched := fun _ => false
      d2hCompleted := fun _ => false
      h2hDispatched := fun _ => false
      h2hCompleted := fun _ => false
      remainingH2h := cfg.numLayers
    }
    consumer := {
      inFlight := 0
      draining := false
      done := false
      statusOk := true
      hasStaging := true
      networkCompleted := false
      h2dDispatched := fun _ => false
      h2dCompleted := fun _ => false
      completedLayers := 0
      completedBlocks := 0
      blocksAccounted := fun _ => false
    }
    mem := {
      prefillHbm := expectedData
      prefillStaging := fun _ _ => none
      networkInFlight := fun _ _ => none
      decodeStaging := fun _ _ => none
      decodeHbm := fun _ _ => none
    }
    doneSending := false
    doneRecving := false
    failedSending := false
    failedRecving := false
    sourceBufferFreed := false
    consumerConsumed := false
  }

end TpuSyncFormal.PrefillDecode
