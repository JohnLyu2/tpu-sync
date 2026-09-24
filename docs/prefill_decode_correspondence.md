# Prefill-to-Decode Code Correspondence Map

This document maps the Lean 4 formal state machine (`TpuSyncFormal.PrefillDecode.*`)
directly to Google TPU Sync (commit `b68161a`).

---

## 1. Type & State Correspondence

| Lean Concept | Lean Symbol | TPU Sync C++ Class / Member | File & Line Reference |
| :--- | :--- | :--- | :--- |
| **Request ID** | `ReqId` | `std::string req_id_` / `uint64_t uuid_` | `core/transfer_session.h:46-47` |
| **Layer Index** | `LayerId` | `size_t layer_idx` / `size_t l` | `core/transfer_send_session.h:161`, `core/transfer_receive_session.h:141` |
| **Block Index** | `BlockId` | `int64_t block_id` / `DeviceBlockId` | `core/raw_transfer_core.h:35` |
| **Send In-flight Count** | `s.producer.inFlight` | `int in_flight_` | `core/transfer_send_session.h:181` |
| **Send Draining Flag** | `s.producer.draining` | `bool draining_` | `core/transfer_send_session.h:184` |
| **Send Done Flag** | `s.producer.done` | `bool done_` | `core/transfer_send_session.h:185` |
| **Send H2H Remaining** | `s.producer.remainingH2h` | `std::atomic<size_t> remaining_h2h_layers_` | `core/transfer_send_session.h:190` |
| **Send D2H Futures** | `s.producer.d2hDispatched` | `std::vector<raiden::PjRtCopyFuture> d2h_layer_futures_` | `core/transfer_send_session.h:186` |
| **Recv In-flight Count** | `s.consumer.inFlight` | `int in_flight_` | `core/transfer_receive_session.h:241` |
| **Recv Draining Flag** | `s.consumer.draining` | `bool draining_` | `core/transfer_receive_session.h:243` |
| **Recv Done Flag** | `s.consumer.done` | `bool done_` | `core/transfer_receive_session.h:244` |
| **Recv Network Done** | `s.consumer.networkCompleted` | `bool network_completed_` | `core/transfer_receive_session.h:239` |
| **Recv Completed Layers**| `s.consumer.completedLayers` | `int32_t num_completed_layers_` | `core/transfer_receive_session.h:238` |
| **Recv Completed Blocks**| `s.consumer.completedBlocks` | `int32_t num_completed_blocks_` | `core/transfer_receive_session.h:237` |
| **Recv Accounted Layers**| `s.consumer.blocksAccounted` | *(ledger, no single field)* which layers' blocks `OnBlocksReceived` has already folded into `num_completed_blocks_` | `core/transfer_receive_session.cc:432-452` |
| **Recv H2D Futures** | `s.consumer.h2dDispatched` | `std::vector<raiden::PjRtCopyFuture> h2d_futures_` | `core/transfer_receive_session.h:248` |
| **Recv Staging Allocation**| `s.consumer.hasStaging` | `StagingAllocation staging_` | `core/transfer_receive_session.h:229` |
| **Published Send Done** | `s.doneSending` | `done_sending_` set | `core/kv_cache_manager_with_transfer.h:145` |
| **Published Recv Done** | `s.doneRecving` | `done_recving_` set | `core/kv_cache_manager_with_transfer.h:146` |

---

## 2. Transition Steps Correspondence

| Lean Step | Implementation Trigger / Function | File & Lines | Detailed Behavior |
| :--- | :--- | :--- | :--- |
| `d2hDispatch(l)` | `TransferSendSession::StartPush` | `core/transfer_send_session.cc:323-356` | Increments `in_flight_`, issues `base_->D2hSyncDispatch(...)`, appends future to `d2h_layer_futures_`. |
| `d2hComplete(l)` | D2H future `OnReady` callback | `core/transfer_send_session.cc:352-355` | Decrements `in_flight_` via `EndSendOp()`. If draining and `in_flight_ == 0`, releases staging and sets `done_ = true`. |
| `h2hDispatch(l)` | `TransferSendSession::SendNextLayer` | `core/transfer_send_session.cc:396-417` | After layer `l` D2H is ready, schedules push pool task, increments `in_flight_`, issues `base_->H2hWriteDirectAsync(...)`. |
| `h2hComplete(l)` | `H2hWriteDirectAsync` callback | `core/transfer_send_session.cc:418-435` | Decrements `remaining_h2h_layers_`. If last layer, calls `Finish()`. Decrements `in_flight_` via `EndSendOp()`. |
| `producerTimeout` | `KVCacheManagerWithTransfer::CompleteReadRaw` | `core/kv_cache_manager_with_transfer.cc:853-859` | If `deadline <= now`, calls `session->Finish(DeadlineExceededError)`. Drains in-flight work. |
| `producerCompleteReadRaw` | `KVCacheManagerWithTransfer::CompleteReadRaw` | `core/kv_cache_manager_with_transfer.cc:860-866` | If `session->Done()`, inserts `req_id` into `done_sending_` (or `failed_recving_` on error). |
| `networkLandChunk(l, b)` | Payload copy of a pushed chunk into consumer host staging, inside `BlockTransport::HandleCustomRequest` | `transport/block_transport.cc:436-470` | Moves the chunk from the wire into the destination host blocks. Touches **no** session counter. |
| `networkAccountLayerBlocks(l)` | `BlockTransport::HandleCustomRequest` → `OnBlocksReceived` → `TransferReceiveSession::RecordBlocksReceivedLocked` | `transport/block_transport.cc:533`, `core/transfer_receive_session.cc:432-452` | Adds the layer's blocks to `num_completed_blocks_`; sets `network_completed_` once `num_completed_blocks_ >= total_blocks_ * total_layers`. **Precondition** `h2dDispatched l = true` mirrors `OnLayerReceived(l)` at `transport/block_transport.cc:525` running first. |
| `h2dDispatch(l)` | `TransferReceiveSession::ExecuteLayerH2d` | `core/transfer_receive_session.cc:568-598` | Increments `in_flight_`, issues `base_->H2dSyncDispatch(...)`, appends future to `h2d_futures_`. |
| `h2dComplete(l)` | H2D future `OnReady` callback | `core/transfer_receive_session.cc:602-640` | Increments `num_completed_layers_`. If all layers complete, calls `FinishLocked()`. Decrements `in_flight_` via `EndRecvOp()`. If draining and `in_flight_ == 0`, releases staging and sets `done_ = true`. |
| `consumerPollComplete` | `KVCacheManagerWithTransfer::CompleteReadRaw` | `core/kv_cache_manager_with_transfer.cc:898-901` | Polling loop calls `session->IsReadyToComplete()`. If true, calls `session->Finish()`. |
| `consumerTimeout` | `KVCacheManagerWithTransfer::CompleteReadRaw` | `core/kv_cache_manager_with_transfer.cc:902-909` | If `deadline <= now`, defers unregister and calls `Finish(DeadlineExceededError)`. |
| `consumerCompleteReadRaw` | `KVCacheManagerWithTransfer::CompleteReadRaw` | `core/kv_cache_manager_with_transfer.cc:912-922` | If `session->Done()`, inserts `req_id` into `done_recving_`. |

---

## 3. `IsReadyToComplete` is safe — retraction of an earlier claim

> **Retraction.** An earlier revision of this document and of the Lean model claimed
> that `TransferReceiveSession::IsReadyToComplete()` admits a publication bug. **That
> claim was wrong.** It was an artifact of a modelling error, not of the C++ code. The
> shipping predicate is safe; this section explains why, and what it depends on.

### The predicate

In `tpu_sync/core/transfer_receive_session.cc:425-430`:
```cpp
bool TransferReceiveSession::IsReadyToComplete() const {
  absl::MutexLock lock(mu_);
  const size_t total_layers = base_ != nullptr ? base_->num_layers() : 0;
  return (network_completed_ ||
          num_completed_layers_ == static_cast<int32_t>(total_layers)) &&
         AllH2dDoneLocked();
}
```
And lines 418-423:
```cpp
bool TransferReceiveSession::AllH2dDoneLocked() const {
  for (const auto& f : h2d_futures_) {
    if (!f.IsReady()) return false;
  }
  return true;
}
```

### The apparent hazard

`AllH2dDoneLocked()` iterates only the futures already present in `h2d_futures_`. Read
in isolation, it therefore looks as though `network_completed_` could become `true`
while some layer has never been dispatched, so that `AllH2dDoneLocked()` would skip
that layer and the session would settle with unwritten HBM.

### Why it cannot happen: the transport ordering invariant

The transport never accounts a layer's blocks before dispatching that layer's H2D copy.
In `BlockTransport::HandleCustomRequest`, for the request that completes layer `l`:

| Order | Call | File & line | Effect |
| :--- | :--- | :--- | :--- |
| 1 | `block_delegate_->OnLayerReceived(l, header.uuid)` | `transport/block_transport.cc:525` | Dispatches layer `l`'s H2D copy; `h2d_futures_.push_back(future)` happens synchronously before returning (`core/transfer_receive_session.cc:594-598`). |
| 2 | `block_delegate_->OnBlocksReceived(allocated_ids, header.uuid)` | `transport/block_transport.cc:533` | Advances `num_completed_blocks_` and may set `network_completed_` (`core/transfer_receive_session.cc:432-452`). |

Two further facts close the argument:

* `network_completed_` is only set when
  `num_completed_blocks_ >= total_blocks_ * total_layers`, and `total_blocks_` is the
  count of distinct block transfers summed over **all** senders of the plan
  (`core/transfer_receive_session.cc:176-199`). The threshold therefore cannot be
  tripped early on a multi-sender plan.
* With several senders per layer, some of layer `l`'s blocks may be accounted before
  `OnLayerReceived(l)` fires, but the accounting that *completes* layer `l` is always
  preceded by it, because `trigger_completion` fires on that same final request
  (`transport/block_transport.cc:441-525`).

Hence: `network_completed_ == true` implies every layer already has an entry in
`h2d_futures_`, so `AllH2dDoneLocked()` is a check over all `num_layers` layers, and
the predicate is equivalent to "all `num_layers` H2D copies have finished".

### Formal model verification

| Claim | Lean theorem |
| :--- | :--- |
| Transport ordering invariant is inductive | `TpuSyncFormal.PrefillDecode.transport_ordering_invariant` |
| Shipping predicate ⇒ all H2D copies done | `TpuSyncFormal.PrefillDecode.shipping_predicate_implies_all_h2d_completed` |
| Shipping predicate ⇒ all KV blocks committed to decode HBM | `TpuSyncFormal.PrefillDecode.shipping_predicate_implies_hbm_committed` |
| Shipping predicate ≡ the stricter all-layers predicate on reachable states | `TpuSyncFormal.PrefillDecode.readiness_predicates_agree` |
| Publication correctness, attention safety, source-buffer safety, staging integrity for all reachable states | `TpuSyncFormal.PrefillDecode.reachable_system_safety` |

### The counterfactual (not a defect)

`TpuSyncFormal/PrefillDecode/HypotheticalReordering.lean` keeps the old 15-step trace,
but under a relation (`ReorderedStep`) that drops **only** the dispatch-before-accounting
precondition. It shows what would break if the transport were ever reordered so that
`OnBlocksReceived` could overtake `OnLayerReceived`:

- `violates_publication_correctness_when_transport_ordering_omitted`
- `violates_attention_safety_when_transport_ordering_omitted`
- `reordering_breaks_transport_ordering_invariant` / `u10_unreachable_under_real_transport`
  (the offending state is provably unreachable in the corrected model)

Read as a requirement: if that ordering is ever changed, `IsReadyToComplete()` must be
strengthened to drop the `network_completed_ ||` disjunct:
```cpp
bool TransferReceiveSession::IsReadyToComplete() const {
  absl::MutexLock lock(mu_);
  const size_t total_layers = base_ != nullptr ? base_->num_layers() : 0;
  return num_completed_layers_ == static_cast<int32_t>(total_layers) &&
         AllH2dDoneLocked();
}
```
This variant (`CheckMode.selfContained` in the model) is not a bug fix; it is the same
test written without relying on the transport's ordering guarantee.

