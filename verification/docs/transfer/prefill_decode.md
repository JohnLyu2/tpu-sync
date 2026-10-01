# Prefill-to-decode transfer: model and results

The model of `proposal.md` §3, built in four stages under
`TpuSyncVerify/Transfer/PrefillDecode/`. Citations in the Lean files are to
tpu-sync **`01ffa3d`** (the commit this tree is based on); every cited region
was read at that commit when the stage was written.

## Modules

| Module | Stage | Models | Main theorem |
|---|---|---|---|
| `Transfer/Session.lean` | 1 | the settle protocol shared by the session classes: `in_flight_`, `draining_`, `done_`, staging ownership | `Consistent` is preserved by `beginOp`/`finish*`/`endOp` |
| `PrefillDecode/Receive.lean` | 1–2 | one `TransferReceiveSession` plus the manager's poll and publication; transport block accounting; `IsReadyToComplete` | `Recv.reachable_safe` |
| `PrefillDecode/Send.lean` | 3 | one `TransferSendSession`: the D2H loop and the H2H push chain against one `in_flight_` | `Send.reachable_safe` |
| `PrefillDecode/Pipeline.lean` | 4 | `Send` + `Recv` + five layer-indexed memories (prefill HBM → staging → wire → decode staging → decode HBM), engine reclaim, staging reuse | `Pipeline.reachable_safe`, `Pipeline.attention_safe` |

Stage boundaries are the commits on `experimental` (see the README status
table). Each later stage uses the earlier models as-is: `Pipeline` composes
`Send.step` and `Recv.step` and only adds the memory effect of each event.

## Proposal properties → theorems

| Proposal (§2) | Where proved | Statement |
|---|---|---|
| Publication correctness | `Pipeline.reachable_safe` (`PublicationCorrect`) | `recv.published = some true → decodeHbm = good n` |
| … decode never runs attention on stale HBM | `Pipeline.attention_safe` | publication is permanent, and the property holds in every state reachable afterwards |
| Source buffer safety | `Pipeline.reachable_safe` (`SourceBufferSafe`); counter form `Send.Drained` | `reclaimed → d2hRetired = d2hIssued`: no D2H copy is reading the prefill blocks when the engine frees them |
| Staging integrity | `Recv.StagingIntegrity`, `Send.StagingIntegrity`, `Pipeline.StagingSafe` | `hasStaging = !done`; a released staging has no copy writing it and no push reading it |
| Termination | not in scope (see Future work F1) | — |

Counter-level forms of publication are proved per side as well
(`Recv.Publication`: `done_recving → every H2D callback ran OK`;
`Send.Publication`: `done_sending → every push completed OK`), together with
settle safety (`done → inFlight = 0`), prompt settle, readiness soundness
(`IsReadyToComplete → ready = numLayers`) and the counter orderings.

## Correspondence

The module docstrings carry the full tables (field → C++, event → C++). What
was checked when:

| Stage | Files read at `01ffa3d` | Notable |
|---|---|---|
| 1 | `transfer_receive_session.{h,cc}` | `ExecuteLayerH2d` re-checks `done_ || draining_` under its second lock (`.cc:601-612`); fault injection adds dispatch/completion failure paths; `in_flight_` starts at 1 for a load plan (`.cc:342`). All encoded. |
| 2 | `block_transport.cc`, `kv_cache_manager_with_transfer.cc` (`CompleteReadRaw`, `begin/end_incoming_push`, `OnBlocksReceived` path) | `OnLayerReceived` fires once per layer (`bt.cc:528-530`) and before `OnBlocksReceived` on the same thread (`bt.cc:570-584`): assumption A4 of `Receive.lean`. |
| 3 | `transfer_send_session.{h,cc}`, `mgr.cc` pull worker and deadline | two op chains on one counter; `SendNextLayer` carries an op across the pool task; `FinishLocked` is first-call-wins. |
| 4 | the above plus `bt.cc:436-470` (landing), `mgr.cc:918-925` (send publication) | layer granularity (A1), delivery modelled after the callback (A2), one sender (A3). |

Assumptions are numbered per module (`Receive` A1–A4, `Send` A1–A6,
`Pipeline` A1–A4) and each names the guard that encodes it. The ones a reader
should know about:

* **Receive A4 / Pipeline A3** — transport ordering and a single sender per
  layer. Readiness soundness depends on A4; the mutant
  `Recv.netAccountUnordered` shows what breaks without it.
* **Send A5** — no consumer `Ack`: `HandleAck → AckSend → Finish()` has no
  non-test caller at `01ffa3d`, so it is not an event.
* **Pipeline A4** — the engine contract: decode reads only after
  `done_recving`, prefill frees only after `done_sending`.

## Evidence the proofs are not vacuous

Traces (all `decide`):

| Theorem | Shows |
|---|---|
| `Recv.trace_normal`, `Send.trace_normal`, `Pipeline.trace_normal` | the happy path reaches publication with the data in decode HBM |
| `Recv.trace_poll_before_callbacks` | `IsReadyToComplete` can be true before the callbacks ran; publication waits |
| `Recv.trace_deadline_during_copy`, `Send.trace_deadline_during_copy` | a deadline under an in-flight copy drains but does not settle until the op ends |
| `Recv.trace_finish_between_locks` | the race the `.cc:601-612` re-check closes |
| `Recv.trace_no_push_after_finish`, `Pipeline.trace_no_push_after_settle` | nothing lands in a settled receive's staging |
| `Send.trace_never_pulled`, `Send.trace_zero_layers` | the two degenerate sends |
| `Send.trace_push_fails` | a failed push drains the chain |
| `Send.trace_cancel_after_ok_finish` | first-finish-wins on the send side |
| `Pipeline.trace_slow_consumer` | producer published, reclaimed and reseated before the consumer lands anything; data still right |
| `Pipeline.trace_no_dispatch_before_land` | `h2dBegin` needs the layer to have landed |

Bounded searches (`#guard … = .outOfFuel`): `Recv` from both initial states
(fuel 10, n = 2), `Send` (fuel 12, n = 2), `Pipeline` from `init 1` and from
`afterProducer` (fuel 10).

Mutants (each yields a `.counterexample`):

| Mutant | Guard removed | Property that catches it |
|---|---|---|
| `Recv.cancelEager`, `Send.cancelEager` | settle waits for `in_flight_ = 0` | settle safety |
| `Recv.netAccountUnordered` | layer accounted only after its copy is issued (A4) | readiness soundness |
| `Send.sendNextUncounted` / `d2hIssueUncounted` | the op `SendNextLayer` takes at `.cc:381` | no underflow / drained |
| `Pipeline.dispatchEarly` | `h2dBegin` after the layer landed | publication correctness (junk in HBM) |
| `Pipeline.reseatAtFinish` | staging released at settle, not at `Finish` | publication correctness via the send's staging |

## Outcome at `01ffa3d`

No bugs in the transfer path. All proposal properties are proved under the
cited assumptions. Observations (not bugs) worth passing on:

| Observation | Where | Note |
|---|---|---|
| `SendAck` / `HandleAck → AckSend → Finish()` has no non-test caller | `mgr.cc:1529-1532`, `1595-1606` | dead path; excluded (Send A5) |
| a failed **send** is reported in `failed_recving_` | `mgr.cc:920` | naming/semantics quirk visible through `poll_stats()` |
| first `Finish` wins on the send side; a later cancel is ignored | `send.cc:167-175` | intended; `trace_cancel_after_ok_finish` |
| `IsReadyToComplete` can be true before all H2D callbacks ran | `recv.cc:427-433` | harmless; `done` still waits for every callback through `in_flight_` |
| `EndSendOpLocked` has no underflow guard, `EndRecvOpLocked` does | `send.cc:188-194` vs `recv.cc:385-388` | underflow proved unreachable (`NoUnderflow`) |
| `LOG(DFATAL) "H2D callback for retired receive"` is unreachable | `recv.cc:651-653` | proved (`NoRetiredCallback`) |

## Future work

Ranked by expected value. The encoding is complete for the proposal's scope;
what remains is where it deliberately stops.

| # | Work | Why | Cost |
|---|---|---|---|
| F1 | **Progress / no-leak property.** In every reachable state with `inFlight > 0`, some op-retiring event is enabled (every accounted unit of `in_flight_` has an owner that can end it). Both sessions. | `Accounted` says `in_flight_` is explained, not that each unit can retire. A leaked op is a session that never settles and staging never released — the production failure mode the safety proofs do not catch. Cheap given `Accounted`. This is the proposal's "termination" half of staging integrity. | low |
| F2 | **Model validation: Lean traces → C++ scenario tests.** `trace_finish_between_locks`, `trace_poll_before_callbacks`, `trace_cancel_after_ok_finish`, `trace_slow_consumer`; `trace_reseat_at_finish` as a fault-injected negative test, using the fault-injection hooks already in `transfer_*_session.cc`. | The correspondence tables are trusted, not checked. Executable scenarios make them checkable and the work legible to tpu-sync owners. Proposal §3.3. | medium |
| F3 | **Maintenance.** `lake build` in CI on the fork; a citation-check script that stores the cited snippet next to each `file:line` and fails when it drifts. | Citations rot with every upstream commit. | low |
| F4 | **Discharge Receive A1/A3/A4 by modelling the transport.** Add `block_transport.cc`: per-block accounting, `on_layer_received_called`, several senders per layer. Then `OnLayerReceived`-before-`OnBlocksReceived` and readiness soundness are proved rather than assumed. | A4 is the one assumption whose failure would be a real bug. Multi-sender is where the threshold arithmetic `num_completed_blocks_ / total_blocks_` is subtle and currently unexercised. | medium–high; worth it if multi-sender transfers are used in production |
| F5 | Completeness: `Pipeline` on the push-plan path (`Recv.initPush` + `StartPush` via `HandlePullStream`); n = 2 search from a mid-state; the mutant table above kept in sync automatically. | rounds things out; low discovery potential | low |

Explicitly not planned: block-granularity memories for their own sake;
staging-pool contention (`AcquireStagingWithRetry`) — a liveness/resource
question needing a scheduler model, unlikely to pay off.
