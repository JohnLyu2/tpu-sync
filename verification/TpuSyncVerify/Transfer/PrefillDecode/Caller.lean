import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck

/-!
# The engine above `poll_stats()`: connector and scheduler block lifecycle

`Pipeline.lean` ends at the `poll_stats()` boundary: it proves that once
tpu-sync publishes a request's send or receive outcome (`send.published`,
`recv.published : Option Bool` — `some true` for `done_sending` /
`done_recving`, `some false` for `failed_recving`) no copy touches the
request's HBM any more (`PrefillHbmSafe`, `DecodeHbmSafe`), and it *assumes*
(**A4**) that the engine frees that HBM only after publication. This module
models the other direction of the same contract — what the engine must do
*with* a publication — for the production caller of the prefill-to-decode
path: vLLM's scheduler driving `tpu-sync` through tpu-inference's
`TPUConnector`. Finding **C1** (`findings/README.md`) is the trace where a
publication never becomes a free.

Citations: `conn.py` = `tpu_inference/distributed/tpu_raiden_connector.py` at
tpu-inference `7ed46a6`; `sched.py` = `vllm/v1/core/sched/scheduler.py`,
`base.py` = `vllm/distributed/kv_transfer/kv_connector/v1/base.py`,
`mixin.py` = `vllm/v1/worker/kv_connector_model_runner_mixin.py`,
`kvcfg.py` = `vllm/config/kv_transfer.py`, all at vLLM `6185d73` (the pair
`examples/*_disagg/setup.sh` pins); `mgr.cc` =
`tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc` at the baseline commit in
`verification/README.md` §Status.

## Source map

<!-- source-map:begin -->
| File | Symbol / anchor | Lines |
|------|-----------------|-------|
| `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` | `:956-1097` |
| `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`for (auto it = send_sessions_.begin();` .. `send_sessions_.erase(it++);`) | `:964-982` |
| `tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc` | `KVCacheManagerWithTransfer::CompleteReadWithDetails` (`for (auto it = active_recv_sessions_.begin();` .. `active_recv_sessions_.erase(it++);`) | `:1011-1038` |
<!-- source-map:end -->

## What is modelled

One request, both nodes. On the prefill node (P) the request has finished its
one output token and the connector has asked vLLM to keep its KV blocks until
the send is reported (`request_finished` returns `delay_free_blocks = True`,
`conn.py:438`); on the decode node (D) the request has been allocated blocks
and parked in `WAITING_FOR_REMOTE_KVS` with the pull issued (`conn.py:322-378`,
`conn.py:606`). Nothing before that point touches a transfer-held block, so the
model starts there (`init`).

Below the engine sits tpu-sync, abstracted to the two publications of
`Pipeline.lean`: `sendPub` is `send.published` and `recvPub` is
`recv.published`. Each is set once, by `pOutcome ok` / `dOutcome ok`, with
`ok = false` covering a failed push or pull *and* a send nobody pulled before
`timeout_s` (`KVCacheManagerWithTransfer::CompleteReadWithDetails` in `mgr.cc`:
both `(failed ? failed_recving_ : done_sending_)` and timed-out sends go to
`failed_recving_`; the connector passes `TPU_P2P_WAIT_PULL_TIMEOUT`, 180 s, as
`timeout_s`, `conn.py:529`). Which value is published is nondeterministic here;
`Pipeline.lean` says when each is possible.

Between tpu-sync and the scheduler sits the **connector**, the object under
test. Per request and per step it sees at most one of the three
`poll_stats()` lists and produces a `Signal`: `finishedSending` /
`finishedRecving` are membership in the pair `get_finished()` returns
(`base.py:357-373`, read by the worker at `mixin.py:102-104`), `loadError` is
"the request's local blocks are in `get_block_ids_with_load_errors()`"
(`base.py:375-393`, `mixin.py:105`). A `Connector` is the pair of functions
`onSend`, `onRecv : (ok : Bool) → Signal`; the publication and the step that
forwards it are one event, which is sound because nothing engine-visible
happens between tpu-sync inserting into a list and the next `poll_stats()`
draining it. Four connectors are instantiated:

| Connector | `onSend ok` | `onRecv ok` | Is |
|-----------|-------------|-------------|----|
| `connectorCurrent` | `finishedSending := ok` | `finishedRecving := ok` | `conn.py:632-656`: the third list is logged and dropped (`conn.py:640-647`), `get_block_ids_with_load_errors` is not overridden |
| `connectorFixed` | `finishedSending := true` | `finishedRecving := true, loadError := !ok` | the proposed fix: forward every outcome, failed receives through vLLM's load-failure channel |
| `connectorNaive` | `finishedSending := true` | `finishedRecving := true` | the fix the connector's comment warns against: a failed receive reported as done |
| `connectorLoadErrorOnly` | `finishedSending := true` | `finishedRecving := ok, loadError := !ok` | the other half-fix: the failure channel without the completion |

The **scheduler** is `sched.py` restricted to what touches a transfer-held
request, in the order `update_from_output` runs it within one step:

1. `invalid_block_ids` (`sched.py:1516-1523` → `_handle_invalid_blocks`,
   `sched.py:2579-2648`): only a request still in `WAITING_FOR_REMOTE_KVS` is
   affected (`sched.py:2591-2594`). Under `kv_load_failure_policy = "recompute"`
   its `num_computed_tokens` is cut back to the first failed block
   (`sched.py:2553`; the connector would report every local block, so to 0) and
   it is added to `failed_recving_kv_req_ids` (`sched.py:2646`). Under `"fail"`
   — the default, `kvcfg.py:69` — it is finished with `FINISHED_ERROR` through
   `finish_requests` (`sched.py:1742-1744`), which for a
   `WAITING_FOR_REMOTE_KVS` request defers the block free until the id is in
   `finished_recving_kv_req_ids` (`sched.py:2061-2070`).
2. `finished_recving` (`sched.py:1758` → `sched.py:2462-2470`): a request still
   waiting is added to `finished_recving_kv_req_ids`; a request already finished
   (aborted or errored) has its blocks freed on the spot (`_free_blocks`,
   `sched.py:2094-2097`, which also deletes it from `scheduler.requests`).
3. `finished_sending` (`sched.py:2471-2474`): blocks freed on the spot.

Across steps: the next `schedule()` promotes a waiting request whose id is in
`finished_recving_kv_req_ids` (`sched.py:643-652`, `sched.py:2414-2429` →
`_update_waiting_for_remote_kv`, `sched.py:2380-2412`): if the id is also in
`failed_recving_kv_req_ids` and nothing valid was computed, the blocks are
freed and the request goes back to `WAITING` to prefill locally
(`recomputing`, `sched.py:2399`); otherwise the blocks are kept as the
request's KV and it proceeds to decode (`decoding`, `sched.py:2405`). And at any
time the API layer may abort the request (`finish_requests`,
`sched.py:2012-2073`): a waiting request's free is deferred as in 1, a decoding
one is freed; a P request is already finished and is skipped
(`sched.py:2041-2043`) — there is no API-layer action that reaches a P-side
hold.

The P side keeps only `pHeld`; its connector signal is read for
`finishedSending` alone (a P scheduler has no request in
`WAITING_FOR_REMOTE_KVS`, and `request_finished` on D returns
`delay_free_blocks = False`, `conn.py:404-455`).

## Properties

* `leakP`: the send is published and P still holds the blocks.
* `leakD`: the receive is published and D's request is either parked in
  `WAITING_FOR_REMOTE_KVS` with its blocks and no promotion possible, or
  finished with its blocks still deferred. Both are *absorbing* for every
  connector and policy (`leakP_absorbing`, `leakD_absorbing`): nothing in the
  engine can free them afterwards, because the only events that could are the
  publications, and each happens once. That is what makes them leaks rather
  than delays.
* `decodesUnwritten`: D's request proceeds to decode while the receive is not
  published as done. In the real system this is the `AssertionError` the
  connector's comment says kills the EngineCore (`conn.py:641-644`).

`Contract conn` is the obligation on a connector that the theorem needs:
every P outcome yields `finishedSending`, every D outcome yields
`finishedRecving`, and a failed D outcome also yields `loadError` — the two
`base.py` contracts (`base.py:375-393`: "the request must still be reported via
`get_finished()`, and the failed block IDs must appear here no later than that
same pass"). `contract_safe` proves that any connector satisfying it, under
either failure policy, never leaks and never decodes unwritten KV;
`connectorFixed` satisfies it (`fixed_contract`). The other three do not, and
each has a trace: `trace_c1_p`, `trace_c1_d_abort_after`,
`trace_c1_d_abort_before` (C1, the current connector), `trace_naive_decodes`
(why the comment's fear was justified), `trace_loadErrorOnly_fail`,
`trace_loadErrorOnly_recompute` (why the failure channel alone is not enough).
Bounded search exhausts the state space for each configuration.

## Assumptions

* **B1 (one worker).** `KVOutputAggregator` (`vllm/distributed/kv_transfer/kv_connector/utils.py`)
  counts `finished_*` reports per request across workers and unions
  `invalid_block_ids`; with one worker per node it is the identity, which is
  what is modelled. Multi-host (`get_finished_count = len(kv_ip)`,
  `conn.py:398-402`) is not.
* **B2 (whole-transfer failure).** A failed pull invalidates every local
  block of the request, so recomputation starts from token 0 and the
  `num_computed_tokens ≠ 0` branch of `_update_waiting_for_remote_kv`
  (`sched.py:2393-2395`, cache the valid prefix) is not reached. tpu-sync
  reports a receive as one outcome (`(!session->GetStatus().ok() ? failed_recving_ : done_recving_)`
  in `KVCacheManagerWithTransfer::CompleteReadWithDetails`), so a connector has
  no finer information to report.
* **B3 (no preemption, prefix caching or chunking).** None of them changes
  which event frees a transfer-held block.
-/

namespace TpuSyncVerify.Transfer.PrefillDecode.Caller

/-- What the worker-side connector tells the scheduler about one request in
one step: membership in the two sets `get_finished()` returns and whether the
request's local blocks are in `get_block_ids_with_load_errors()`. -/
structure Signal where
  finishedSending : Bool := false
  finishedRecving : Bool := false
  loadError : Bool := false
  deriving Repr, DecidableEq

/-- A worker-side connector, as the function it applies to tpu-sync's report
for one request: `onSend ok` on the producer node when the request is in
`done_sending` (`ok`) or `failed_recving` (`!ok`); `onRecv ok` on the consumer
node when it is in `done_recving` (`ok`) or `failed_recving` (`!ok`). -/
structure Connector where
  onSend : Bool → Signal
  onRecv : Bool → Signal

/-- `conn.py:632-656`: `failed_recving` is logged and dropped on both nodes;
`get_block_ids_with_load_errors` is the base-class default. -/
def connectorCurrent : Connector where
  onSend ok := { finishedSending := ok }
  onRecv ok := { finishedRecving := ok }

/-- The proposed fix: every outcome is forwarded; a failed receive goes through
both of vLLM's channels. -/
def connectorFixed : Connector where
  onSend _ := { finishedSending := true }
  onRecv ok := { finishedRecving := true, loadError := !ok }

/-- The fix the connector's comment (`conn.py:641-644`) warns against: a failed
receive reported as `done_recving` and nothing else. -/
def connectorNaive : Connector where
  onSend _ := { finishedSending := true }
  onRecv _ := { finishedRecving := true }

/-- The other half-fix: the failure channel without the completion report. -/
def connectorLoadErrorOnly : Connector where
  onSend _ := { finishedSending := true }
  onRecv ok := { finishedRecving := ok, loadError := !ok }

/-- vLLM's `kv_load_failure_policy` (`kvcfg.py:69`; `"fail"` is the default). -/
inductive Policy where
  | recompute
  | fail
  deriving Repr, DecidableEq

structure Cfg where
  conn : Connector
  policy : Policy

/-- The decode-node request, as far as its transfer-held blocks are concerned. -/
inductive DStatus where
  /-- `WAITING_FOR_REMOTE_KVS`, blocks allocated, pull issued. -/
  | waitingRemoteKv
  /-- promoted with its blocks as its KV cache (`sched.py:2405`). -/
  | decoding
  /-- promoted after a load failure: blocks freed, back to `WAITING` to prefill locally (`sched.py:2399`). -/
  | recomputing
  /-- finished (aborted by the API layer, or `FINISHED_ERROR`); blocks freed unless deferred. -/
  | finished
  deriving Repr, DecidableEq

structure S where
  /-- `send.published`: what `poll_stats()` on P has reported for the send. -/
  sendPub : Option Bool := none
  /-- `recv.published`: what `poll_stats()` on D has reported for the receive. -/
  recvPub : Option Bool := none
  /-- P still holds the request's KV blocks (and the request in `scheduler.requests`). -/
  pHeld : Bool := true
  dStatus : DStatus := .waitingRemoteKv
  /-- D still holds the blocks allocated for the remote KV. -/
  dHeld : Bool := true
  /-- `request_id ∈ finished_recving_kv_req_ids` (`sched.py:197`). -/
  dFinRecv : Bool := false
  /-- `request_id ∈ failed_recving_kv_req_ids` (`sched.py:198`). -/
  dFailRecv : Bool := false
  deriving Repr, DecidableEq

/-- P finished and holding (`conn.py:438`), D allocated and waiting
(`conn.py:322-378`), pull issued, nothing published. -/
def init : S := {}

inductive Ev where
  /-- tpu-sync publishes the send (`done_sending` if `ok`, else `failed_recving`,
  `(failed ? failed_recving_ : done_sending_).insert(session->req_id())` in
  `KVCacheManagerWithTransfer::CompleteReadWithDetails`) and P's next
  `get_finished()` forwards it. -/
  | pOutcome (ok : Bool)
  /-- tpu-sync publishes the receive (`done_recving` if `ok`, else
  `failed_recving`, `(!session->GetStatus().ok() ? failed_recving_ : done_recving_).insert(session->req_id())`
  in `KVCacheManagerWithTransfer::CompleteReadWithDetails`) and D's next
  `get_finished()` / `get_block_ids_with_load_errors()` forward it. -/
  | dOutcome (ok : Bool)
  /-- D's next `schedule()` promotes the waiting request (`sched.py:2414-2429`). -/
  | promote
  /-- D's request leaves the engine: an API-layer abort (`finish_requests`,
  `sched.py:2012-2073`) at any time, or normal completion once decoding. -/
  | finish
  deriving Repr, DecidableEq

/-- `sched.py:2471-2474`: `finished_sending` frees the blocks. -/
def applySend (sig : Signal) (s : S) : S :=
  if sig.finishedSending then { s with pHeld := false } else s

/-- `sched.py:1516-1523`, `sched.py:2579-2648`: `invalid_block_ids` for a
request still in `WAITING_FOR_REMOTE_KVS`. -/
def applyLoadError (policy : Policy) (s : S) : S :=
  if s.dStatus = .waitingRemoteKv then
    match policy with
    | .recompute => { s with dFailRecv := true }
    | .fail =>
      -- `finish_requests(FINISHED_ERROR)`, `sched.py:1742-1744` → `sched.py:2061-2070`
      { s with dStatus := .finished, dHeld := s.dHeld && !s.dFinRecv,
               dFinRecv := false, dFailRecv := false }
  else s

/-- `sched.py:2462-2470`: `finished_recving` for a waiting request records it;
for a finished request frees its blocks. -/
def applyFinishedRecving (s : S) : S :=
  match s.dStatus with
  | .waitingRemoteKv => { s with dFinRecv := true }
  | .finished => { s with dHeld := false }
  -- `decoding` / `recomputing` need a promotion, which needs this very
  -- report, which happens once: unreachable (the real code would assert).
  | _ => s

/-- One `update_from_output` on D, in its order: load errors (`sched.py:1516`),
then transfer completions (`sched.py:1758`). -/
def applyRecv (policy : Policy) (sig : Signal) (s : S) : S :=
  let s := if sig.loadError then applyLoadError policy s else s
  if sig.finishedRecving then applyFinishedRecving s else s

def pOutcome (c : Cfg) (ok : Bool) (s : S) : Option S :=
  if s.sendPub = none then
    some (applySend (c.conn.onSend ok) { s with sendPub := some ok })
  else none

def dOutcome (c : Cfg) (ok : Bool) (s : S) : Option S :=
  if s.recvPub = none then
    some (applyRecv c.policy (c.conn.onRecv ok) { s with recvPub := some ok })
  else none

/-- `_try_promote_blocked_waiting_request` → `_update_waiting_for_remote_kv`
(`sched.py:2414-2429`, `sched.py:2380-2412`). -/
def promote (s : S) : Option S :=
  if s.dStatus = .waitingRemoteKv ∧ s.dFinRecv = true then
    if s.dFailRecv then
      some { s with dStatus := .recomputing, dHeld := false, dFinRecv := false, dFailRecv := false }
    else
      some { s with dStatus := .decoding, dFinRecv := false }
  else none

/-- `finish_requests` (`sched.py:2012-2073`) on D. -/
def finish (s : S) : Option S :=
  match s.dStatus with
  | .waitingRemoteKv =>
    some { s with dStatus := .finished, dHeld := s.dHeld && !s.dFinRecv,
                  dFinRecv := false, dFailRecv := false }
  | .decoding => some { s with dStatus := .finished, dHeld := false }
  | .recomputing => some { s with dStatus := .finished }
  | .finished => none

def step (c : Cfg) (s : S) : Ev → Option S
  | .pOutcome ok => pOutcome c ok s
  | .dOutcome ok => dOutcome c ok s
  | .promote => promote s
  | .finish => finish s

def sys (c : Cfg) : System S Ev := ⟨init, step c⟩

/-! ## Properties -/

/-- The send is published and P still holds the blocks. -/
def leakP (s : S) : Bool := s.sendPub.isSome && s.pHeld

/-- The receive is published and D either keeps the request parked with its
blocks and nothing to promote it, or has finished it with the free deferred. -/
def leakD (s : S) : Bool :=
  s.recvPub.isSome &&
    ((s.dStatus == .waitingRemoteKv && !s.dFinRecv && s.dHeld) ||
     (s.dStatus == .finished && s.dHeld))

/-- D proceeds to decode on KV that was never written. -/
def decodesUnwritten (s : S) : Bool :=
  s.dStatus == .decoding && s.recvPub != some true

def violates (s : S) : Bool := leakP s || leakD s || decodesUnwritten s

def Safe (s : S) : Prop := violates s = false

/-- What a connector owes the scheduler (`base.py:357-393`). -/
structure Contract (conn : Connector) : Prop where
  /-- Every send outcome is reported as finished sending. -/
  send_total : ∀ ok, (conn.onSend ok).finishedSending = true
  /-- Every receive outcome is reported as finished receiving — including a
  failed one, "so the scheduler can release the request". -/
  recv_total : ∀ ok, (conn.onRecv ok).finishedRecving = true
  /-- A failed receive is also reported on the load-failure channel, no later
  than its completion. -/
  recv_failure_reported : (conn.onRecv false).loadError = true
  /-- No cross-talk: a producer-side report never names the request in
  `finished_recving` or the load-failure set, and a consumer-side report never
  names it in `finished_sending`. The model does not read these fields; the
  real scheduler would assert on them (`sched.py:2469`, `sched.py:2473` →
  `_free_blocks`, `sched.py:2095`), so the contract forbids them. -/
  send_no_recv : ∀ ok, (conn.onSend ok).finishedRecving = false ∧ (conn.onSend ok).loadError = false
  recv_no_send : ∀ ok, (conn.onRecv ok).finishedSending = false

theorem fixed_contract : Contract connectorFixed where
  send_total := by intro ok; rfl
  recv_total := by intro ok; rfl
  recv_failure_reported := rfl
  send_no_recv := by intro ok; exact ⟨rfl, rfl⟩
  recv_no_send := by intro ok; rfl

/-! ## Leaks are absorbing

Whatever the connector and policy: once `leakP` or `leakD` holds it holds in
every later state. The publications are the only events that free a held
block without the engine's own progress, and each happens once. -/

/-- The D-side update leaves the P-side fields alone. -/
theorem applyLoadError_p (p : Policy) (s : S) :
    (applyLoadError p s).pHeld = s.pHeld ∧ (applyLoadError p s).sendPub = s.sendPub := by
  unfold applyLoadError
  split <;> cases p <;> simp

theorem applyFinishedRecving_p (s : S) :
    (applyFinishedRecving s).pHeld = s.pHeld ∧ (applyFinishedRecving s).sendPub = s.sendPub := by
  unfold applyFinishedRecving
  split <;> simp

theorem applyRecv_p (p : Policy) (sig : Signal) (s : S) :
    (applyRecv p sig s).pHeld = s.pHeld ∧ (applyRecv p sig s).sendPub = s.sendPub := by
  unfold applyRecv
  split <;> split <;> simp [applyFinishedRecving_p, applyLoadError_p]

theorem leakP_absorbing {c : Cfg} {s s' : S} {e : Ev}
    (h : leakP s = true) (hs : step c s e = some s') : leakP s' = true := by
  have hp : s.sendPub.isSome = true ∧ s.pHeld = true := by
    simpa [leakP] using h
  cases e with
  | pOutcome ok =>
    simp only [step, pOutcome] at hs
    split at hs
    · rename_i hn
      rw [hn] at hp
      simp at hp
    · simp at hs
  | dOutcome ok =>
    simp only [step, dOutcome] at hs
    split at hs
    · simp only [Option.some.injEq] at hs
      subst hs
      simp [leakP, applyRecv_p, hp]
    · simp at hs
  | promote =>
    simp only [step, promote] at hs
    split at hs
    · split at hs <;> simp only [Option.some.injEq] at hs <;> subst hs <;> simpa [leakP] using hp
    · simp at hs
  | finish =>
    simp only [step, finish] at hs
    split at hs
    · simp only [Option.some.injEq] at hs; subst hs; simpa [leakP] using hp
    · simp only [Option.some.injEq] at hs; subst hs; simpa [leakP] using hp
    · simp only [Option.some.injEq] at hs; subst hs; simpa [leakP] using hp
    · simp at hs

theorem leakD_absorbing {c : Cfg} {s s' : S} {e : Ev}
    (h : leakD s = true) (hs : step c s e = some s') : leakD s' = true := by
  cases e with
  | pOutcome ok =>
    simp only [step, pOutcome] at hs
    split at hs
    · simp only [Option.some.injEq] at hs
      subst hs
      simp only [applySend]
      split <;> simpa [leakD] using h
    · simp at hs
  | dOutcome ok =>
    simp only [step, dOutcome] at hs
    split at hs
    · rename_i hn
      simp [leakD, hn] at h
    · simp at hs
  | promote =>
    simp only [step, promote] at hs
    split at hs
    · rename_i hw
      simp [leakD, hw.1, hw.2] at h
    · simp at hs
  | finish =>
    simp only [step, finish] at hs
    split at hs
    · simp only [Option.some.injEq] at hs; subst hs; simp_all [leakD]
    · simp only [Option.some.injEq] at hs; subst hs; simp_all [leakD]
    · simp only [Option.some.injEq] at hs; subst hs; simp_all [leakD]
    · simp at hs

/-! ## Any connector meeting the contract is safe -/

/-- The inductive invariant for a contract-abiding connector. -/
structure Inv (s : S) : Prop where
  /-- P holds only while the send is unpublished. -/
  p : s.pHeld = true → s.sendPub = none
  /-- Before the receive is published nothing has happened on D. -/
  d_none : s.recvPub = none →
    (s.dStatus = .waitingRemoteKv ∨ s.dStatus = .finished) ∧ s.dFinRecv = false ∧ s.dFailRecv = false
  /-- After publication a parked request is promotable. -/
  d_wait : s.recvPub ≠ none → s.dStatus = .waitingRemoteKv → s.dFinRecv = true
  /-- After a failed publication a parked request is marked for recomputation. -/
  d_fail : s.recvPub = some false → s.dStatus = .waitingRemoteKv → s.dFailRecv = true
  /-- After publication a finished request holds nothing. -/
  d_fin : s.recvPub ≠ none → s.dStatus = .finished → s.dHeld = false
  /-- A recomputing request holds nothing. -/
  d_rec : s.dStatus = .recomputing → s.dHeld = false
  /-- Only a receive published as done decodes. -/
  d_dec : s.dStatus = .decoding → s.recvPub = some true

theorem inv_init : Inv init := by
  constructor <;> simp [init]

theorem inv_safe {s : S} (h : Inv s) : Safe s := by
  simp only [Safe, violates, leakP, leakD, decodesUnwritten, Bool.or_eq_false_iff,
    Bool.and_eq_false_iff]
  refine ⟨⟨?_, ?_⟩, ?_⟩
  · cases hp : s.sendPub with
    | none => simp
    | some b =>
      right
      cases hh : s.pHeld
      · rfl
      · have := h.p hh
        rw [hp] at this
        cases this
  · cases hr : s.recvPub with
    | none => simp
    | some b =>
      right
      have hne : s.recvPub ≠ none := by simp [hr]
      cases hst : s.dStatus <;> simp
      · left
        exact h.d_wait hne hst
      · exact h.d_fin hne hst
  · cases hst : s.dStatus <;> simp
    have := h.d_dec hst
    simp [this]

theorem inv_pOutcome {c : Cfg} (hc : Contract c.conn) {s s' : S} {ok : Bool}
    (h : Inv s) (hs : pOutcome c ok s = some s') : Inv s' := by
  unfold pOutcome at hs
  split at hs
  · rename_i hn
    have hsend := hc.send_total ok
    simp only [applySend, hsend, ite_true, Option.some.injEq] at hs
    subst hs
    exact {
      p := by simp
      d_none := by simpa using h.d_none
      d_wait := by simpa using h.d_wait
      d_fail := by simpa using h.d_fail
      d_fin := by simpa using h.d_fin
      d_rec := by simpa using h.d_rec
      d_dec := by simpa using h.d_dec }
  · simp at hs

theorem inv_dOutcome {c : Cfg} (hc : Contract c.conn) {s s' : S} {ok : Bool}
    (h : Inv s) (hs : dOutcome c ok s = some s') : Inv s' := by
  unfold dOutcome at hs
  split at hs
  · rename_i hn
    obtain ⟨hst, hfin, hfail⟩ := h.d_none hn
    have hfr := hc.recv_total ok
    have hpn : s.pHeld = true → s.sendPub = none := h.p
    simp only [Option.some.injEq] at hs
    subst hs
    -- the P field is untouched by every branch below
    have hle : ok = false → (c.conn.onRecv ok).loadError = true := by
      intro hok; subst hok; exact hc.recv_failure_reported
    cases hst with
    | inl hw =>
      cases hl : (c.conn.onRecv ok).loadError with
      | false =>
        have hok : ok = true := by
          cases ok
          · exact absurd (hle rfl) (by simp [hl])
          · rfl
        subst hok
        simp only [applyRecv, hl, hfr, applyFinishedRecving, hw, ite_true]
        exact {
          p := by simpa using hpn
          d_none := by simp
          d_wait := by simp
          d_fail := by simp
          d_fin := by simp
          d_rec := by simp
          d_dec := by simp }
      | true =>
        cases hp : c.policy with
        | recompute =>
          simp only [applyRecv, hl, hfr, applyLoadError, applyFinishedRecving, hw, ite_true]
          exact {
            p := by simpa using hpn
            d_none := by simp
            d_wait := by simp
            d_fail := by simp
            d_fin := by simp
            d_rec := by simp
            d_dec := by simp }
        | fail =>
          simp only [applyRecv, hl, hfr, applyLoadError, applyFinishedRecving, hw, ite_true]
          exact {
            p := by simpa using hpn
            d_none := by simp
            d_wait := by simp
            d_fail := by simp
            d_fin := by simp
            d_rec := by simp
            d_dec := by simp }
    | inr hf =>
      -- aborted before the outcome: the load error is ignored, the completion frees
      cases hl : (c.conn.onRecv ok).loadError
      · simp only [applyRecv, hl, hfr, applyFinishedRecving, hf, ite_true]
        exact {
          p := by simpa using hpn
          d_none := by simp
          d_wait := by simp
          d_fail := by simp
          d_fin := by simp
          d_rec := by simp
          d_dec := by simp }
      · simp only [applyRecv, hl, hfr, applyLoadError, applyFinishedRecving, hf, ite_true]
        exact {
          p := by simpa using hpn
          d_none := by simp
          d_wait := by simp
          d_fail := by simp
          d_fin := by simp
          d_rec := by simp
          d_dec := by simp }
  · simp at hs

theorem inv_promote {s s' : S} (h : Inv s) (hs : promote s = some s') : Inv s' := by
  unfold promote at hs
  split at hs
  · rename_i hw
    obtain ⟨hw, hfin⟩ := hw
    -- the publication has happened: otherwise `dFinRecv = false`
    have hpub : s.recvPub ≠ none := by
      intro hn
      have := (h.d_none hn).2.1
      rw [hfin] at this
      cases this
    split at hs
    · rename_i hfail
      simp only [Option.some.injEq] at hs
      subst hs
      exact {
        p := by simpa using h.p
        d_none := by intro hn; exact absurd hn hpub
        d_wait := by simp
        d_fail := by simp
        d_fin := by simp
        d_rec := by simp
        d_dec := by simp }
    · rename_i hfail
      simp only [Option.some.injEq] at hs
      subst hs
      have hok : s.recvPub = some true := by
        cases hr : s.recvPub with
        | none => exact absurd hr hpub
        | some b =>
          cases b
          · have := h.d_fail hr hw
            simp [this] at hfail
          · rfl
      exact {
        p := by simpa using h.p
        d_none := by intro hn; exact absurd hn hpub
        d_wait := by simp
        d_fail := by simp
        d_fin := by simp
        d_rec := by simp
        d_dec := by simpa using hok }
  · simp at hs

theorem inv_finish {s s' : S} (h : Inv s) (hs : finish s = some s') : Inv s' := by
  unfold finish at hs
  split at hs
  · rename_i hw
    simp only [Option.some.injEq] at hs
    subst hs
    exact {
      p := by simpa using h.p
      d_none := by intro _; simp
      d_wait := by simp
      d_fail := by simp
      d_fin := by
        intro hpub _
        have := h.d_wait hpub hw
        simp [this]
      d_rec := by simp
      d_dec := by simp }
  · rename_i hd
    simp only [Option.some.injEq] at hs
    subst hs
    exact {
      p := by simpa using h.p
      d_none := by
        intro hn
        have := h.d_dec hd
        rw [hn] at this
        cases this
      d_wait := by simp
      d_fail := by simp
      d_fin := by simp
      d_rec := by simp
      d_dec := by simp }
  · rename_i hr
    simp only [Option.some.injEq] at hs
    subst hs
    have hheld := h.d_rec hr
    exact {
      p := by simpa using h.p
      d_none := by
        intro hn
        have := (h.d_none hn).1
        simp [hr] at this
      d_wait := by simp
      d_fail := by simp
      d_fin := by intro _ _; simpa using hheld
      d_rec := by simp
      d_dec := by simp }
  · simp at hs

theorem step_inv {c : Cfg} (hc : Contract c.conn) {s s' : S} {e : Ev}
    (h : Inv s) (hs : step c s e = some s') : Inv s' := by
  cases e with
  | pOutcome ok => exact inv_pOutcome hc h hs
  | dOutcome ok => exact inv_dOutcome hc h hs
  | promote => exact inv_promote h hs
  | finish => exact inv_finish h hs

/-- A connector that forwards every outcome and reports a failed receive on
the load-failure channel never leaks a transfer-held block on either node and
never lets D decode on unwritten KV, under either failure policy. -/
theorem contract_safe {c : Cfg} (hc : Contract c.conn) {s : S}
    (hr : (sys c).Reachable s) : Safe s :=
  inv_safe ((sys c).reachable_induction inv_init (fun _ _ _ h hs => step_inv hc h hs) hr)

theorem fixed_safe {policy : Policy} {s : S}
    (hr : (sys ⟨connectorFixed, policy⟩).Reachable s) : Safe s :=
  contract_safe fixed_contract hr

/-! ## Replay and search -/

def allEvents : List Ev :=
  [.pOutcome true, .pOutcome false, .dOutcome true, .dOutcome false, .promote, .finish]

/-- The events of a run in which every transfer succeeds. -/
def okEvents : List Ev := [.pOutcome true, .dOutcome true, .promote, .finish]

def search (c : Cfg) (events : List Ev := allEvents) (fuel : Nat := 16) : ModelCheck.Result Ev :=
  ModelCheck.check (sys c) events violates fuel

def leaked (c : Cfg) (events : List Ev := allEvents) : Bool :=
  match search c events with
  | .counterexample _ => true
  | _ => false

/-- Projection used by the traces. -/
structure View where
  pHeld : Bool
  dStatus : DStatus
  dHeld : Bool
  dFinRecv : Bool
  dFailRecv : Bool
  deriving Repr, DecidableEq

def view (s : S) : View := ⟨s.pHeld, s.dStatus, s.dHeld, s.dFinRecv, s.dFailRecv⟩

def current (p : Policy) : Cfg := ⟨connectorCurrent, p⟩
def fixed (p : Policy) : Cfg := ⟨connectorFixed, p⟩
def naive (p : Policy) : Cfg := ⟨connectorNaive, p⟩
def loadErrorOnly (p : Policy) : Cfg := ⟨connectorLoadErrorOnly, p⟩

/-! ### The current connector

When every transfer succeeds, the current connector is fine: `done_sending`
frees P and `done_recving` promotes D (what the connector was tested
against). Exhaustive over `okEvents`. -/

#guard search (current .fail) okEvents = .safe
#guard search (current .recompute) okEvents = .safe

/-- Success path, both nodes: P freed on `done_sending`, D promoted to decode
on `done_recving` and freed when it finishes. -/
theorem trace_current_ok :
    ((sys (current .fail)).run [.pOutcome true, .dOutcome true, .promote, .finish]).map view =
    some ⟨false, .finished, false, false, false⟩ := by
  decide

/-- **C1, P side.** The send is published as failed — a push that failed, or
one nobody pulled within `timeout_s` — and dropped by `get_finished()`; P keeps
the blocks. `leakP_absorbing`: forever. -/
theorem trace_c1_p :
    ((sys (current .fail)).run [.pOutcome false]).map (fun s => (view s, leakP s)) =
    some (⟨true, .waitingRemoteKv, true, false, false⟩, true) := by
  decide

/-- **C1, D side, abort after.** The pull fails, the report is dropped, the
request stays parked; "the request times out at the API layer instead"
(`conn.py:644`) — and the abort defers the free to a `finished_recving` that
will never come (`sched.py:2064-2066`). -/
theorem trace_c1_d_abort_after :
    ((sys (current .fail)).run [.dOutcome false, .finish]).map (fun s => (view s, leakD s)) =
    some (⟨true, .finished, true, false, false⟩, true) := by
  decide

/-- **C1, D side, abort before.** The client gives up while the pull is still
running; the free is deferred; the pull then fails and the report is dropped. -/
theorem trace_c1_d_abort_before :
    ((sys (current .fail)).run [.finish, .dOutcome false]).map (fun s => (view s, leakD s)) =
    some (⟨true, .finished, true, false, false⟩, true) := by
  decide

/-- The same two D-side traces under the recompute policy: the policy never
gets to act, because nothing reaches the scheduler. -/
theorem trace_c1_d_recompute :
    ((sys (current .recompute)).run [.dOutcome false]).map (fun s => (view s, leakD s)) =
    some (⟨true, .waitingRemoteKv, true, false, false⟩, true) ∧
    ((sys (current .recompute)).run [.finish, .dOutcome false]).map (fun s => (view s, leakD s)) =
    some (⟨true, .finished, true, false, false⟩, true) := by
  decide

#guard leaked (current .fail) = true
#guard leaked (current .recompute) = true

/-! ### The fix -/

#guard search (fixed .fail) = .safe
#guard search (fixed .recompute) = .safe

/-- Fixed connector, failed pull, recompute policy: the request is marked
failed and complete in one step, the next `schedule()` frees the blocks and
sends it to prefill locally. -/
theorem trace_fixed_recompute :
    ((sys (fixed .recompute)).run [.dOutcome false]).map view =
      some ⟨true, .waitingRemoteKv, true, true, true⟩ ∧
    ((sys (fixed .recompute)).run [.dOutcome false, .promote]).map view =
      some ⟨true, .recomputing, false, false, false⟩ := by
  decide

/-- Fixed connector, failed pull, fail policy (the default): the load error
finishes the request with `FINISHED_ERROR` and defers the free; the
`finished_recving` in the same step releases it. -/
theorem trace_fixed_fail :
    ((sys (fixed .fail)).run [.dOutcome false]).map view =
      some ⟨true, .finished, false, false, false⟩ := by
  decide

/-- Fixed connector, P side: a failed or never-pulled send frees P. -/
theorem trace_fixed_p :
    ((sys (fixed .fail)).run [.pOutcome false]).map view =
      some ⟨false, .waitingRemoteKv, true, false, false⟩ := by
  decide

/-- Fixed connector, abort before the failed pull is reported: the deferred
free is released by the completion report. -/
theorem trace_fixed_abort_before :
    ((sys (fixed .fail)).run [.finish, .dOutcome false]).map view =
      some ⟨true, .finished, false, false, false⟩ ∧
    ((sys (fixed .recompute)).run [.finish, .dOutcome false]).map view =
      some ⟨true, .finished, false, false, false⟩ := by
  decide

/-! ### The two half-fixes -/

/-- Reporting a failed receive as `done_recving` alone: the scheduler promotes
the request with its full `num_computed_tokens` and decodes on KV that was
never written — the EngineCore-killing assertion the connector's comment
describes. Same under either policy: the policy only acts on
`invalid_block_ids`. -/
theorem trace_naive_decodes :
    ((sys (naive .fail)).run [.dOutcome false, .promote]).map (fun s => (view s, decodesUnwritten s)) =
      some (⟨true, .decoding, true, false, false⟩, true) ∧
    ((sys (naive .recompute)).run [.dOutcome false, .promote]).map (fun s => (view s, decodesUnwritten s)) =
      some (⟨true, .decoding, true, false, false⟩, true) := by
  decide

#guard leaked (naive .fail) = true
#guard leaked (naive .recompute) = true

/-- The load-failure channel without the completion, fail policy: the request
is errored out but its free waits for a `finished_recving` that never comes. -/
theorem trace_loadErrorOnly_fail :
    ((sys (loadErrorOnly .fail)).run [.dOutcome false]).map (fun s => (view s, leakD s)) =
      some (⟨true, .finished, true, false, false⟩, true) := by
  decide

/-- The same under the recompute policy: marked for recomputation but never
promotable. -/
theorem trace_loadErrorOnly_recompute :
    ((sys (loadErrorOnly .recompute)).run [.dOutcome false]).map (fun s => (view s, leakD s)) =
      some (⟨true, .waitingRemoteKv, true, false, true⟩, true) := by
  decide

#guard leaked (loadErrorOnly .fail) = true
#guard leaked (loadErrorOnly .recompute) = true

end TpuSyncVerify.Transfer.PrefillDecode.Caller
