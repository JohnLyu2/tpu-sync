import TpuSyncVerify.Transfer.PrefillDecode.Pipeline.Coverage

/-! # `MultiRequest`: branch coverage of `multiStep`

Part of `TpuSyncVerify.Transfer.PrefillDecode.MultiRequest`; imports the
traces in `PipelineChecks.lean` through `Pipeline/Coverage.lean`.

`multiStep` adds three things to `Pipeline.step`: the two recycle events and
the write-after-release corruption arm of `reqStep`. Everything else a
`reqStep` does is a `Pipeline` branch of the request it steps, measured in
`Pipeline/Coverage.lean`; this file measures only what is new. The state
space is unbounded (every recycle spawns a request), so there is no
exhaustive universe here: the three new leaves are shown reachable or dead
by theorem, and the two multi-request traces are checked against them. -/

namespace TpuSyncVerify.Transfer.PrefillDecode.Pipeline

open TpuSyncVerify.Coverage (Instr)

namespace Multi

/-- What `multiStep` did beyond the stepped request's own `Pipeline` branch. -/
inductive Leaf
  /-- Request `idx` took a `Pipeline` step with the given leaf, no write after release. -/
  | reqStep (l : Pipeline.Leaf)
  /-- Request `idx` wrote a buffer it had released: every request's buffers corrupted. -/
  | corrupted
  /-- `PrefillReleased`: prefill HBM and staging recycled, a new request started. -/
  | recyclePrefill
  /-- `HandedOff`: prefill HBM, prefill staging and decode staging recycled (decode
  HBM, the published result, is kept), a new request started. -/
  | nextRequest
  deriving Repr, DecidableEq

def stepT (ms : MultiState) : MultiEv → Option (MultiState × Leaf)
  | .reqStep idx e =>
    match ms.reqs[idx]? with
    | none => none
    | some r =>
      (Pipeline.stepT r e).map fun (r', l) =>
        let reqs' := ms.reqs.set idx r'
        if !isRecycleEv e && wroteReleased r r' then
          ({ ms with reqs := reqs'.map corruptBuffers }, .corrupted)
        else ({ ms with reqs := reqs' }, .reqStep l)
  | .recyclePrefill idx => (multiStep ms (.recyclePrefill idx)).map (·, .recyclePrefill)
  | .nextRequest idx => (multiStep ms (.nextRequest idx)).map (·, .nextRequest)

theorem stepT_step (ms : MultiState) (ev : MultiEv) :
    (stepT ms ev).map (·.1) = multiStep ms ev := by
  cases ev with
  | reqStep idx e =>
    simp only [stepT, multiStep]
    cases hget : ms.reqs[idx]? with
    | none => rfl
    | some r =>
      simp only
      rw [← Pipeline.stepT_step]
      cases Pipeline.stepT r e with
      | none => rfl
      | some p => simp only [Option.map_some]; split <;> rfl
  | recyclePrefill idx => simp [stepT, Option.map_map, Function.comp_def]
  | nextRequest idx => simp [stepT, Option.map_map, Function.comp_def]

/-- The leaves along a trace (no `Effect`: the lifecycle effect of a `reqStep`
is the stepped request's, already measured). -/
def leaves (ms : MultiState) : List MultiEv → List Leaf
  | [] => []
  | ev :: evs =>
    match stepT ms ev with
    | none => []
    | some (ms', l) => l :: leaves ms' evs

/-! ## Result

Three leaves are new in `multiStep`:

* `corrupted` — **dead by theorem**: `not_isRecycleEv_and_wroteReleased_eq_false`
  shows no reachable request writes a buffer it released (it is the arm
  `system_data_correct` and `system_attention_safe` rest on never being
  taken). It is the multi-request form of the `Pipeline` mutants
  `reseatAtFinish` / `dispatchEarly`.
* `recyclePrefill`, `nextRequest` — the engine starting the next request on
  recycled buffers. Reached by the two multi-request traces
  (`trace_overlapped_requests`, `trace_multi_request`), which replay the
  single-host disaggregated serving example (`examples/single_host_disagg/run_all.sh`)
  — a script, not a test in the suite, so both are `modelOnly`. **No upstream
  test overwrites a buffer an earlier request released while that request is
  still observable** (`TreeBroadcastCorrectness8Nodes` re-reads a published
  decode block and reuses its freed staging slot for later sends, and
  `DuplicateUuidIsRejectedUntilExpiredReceiveDrains` re-acquires staging on a
  retry — later requests on released resources, with the earlier request
  finished or not checked again). These are the three
  "environment" gaps of `Pipeline/Coverage.lean` (`reclaim`, the two reseats)
  seen from the other side: the pipeline's environment events are what a
  recycle does to the request being recycled.

So `MultiRequest` adds two live branches to the corpus and the upstream tests
reach neither; the single-request pipeline branches each `reqStep` takes are
the `Pipeline` numbers. -/

def tr_multi_request : List MultiEv :=
  ([.send .beginPull, .send .start, .send .d2hBegin, .send .cancel, .recv .cancel,
    .send (.d2hIssue true), .d2hReady 0, .send (.wake true), .send .d2hEnd,
    .recv (.pullReply true), .send .publish, .recv .publish].map (MultiEv.reqStep 0)) ++
  [.nextRequest 0] ++ ((producer ++ consumer).map (MultiEv.reqStep 1))

def tr_overlapped_requests : List MultiEv :=
  (producer.map (MultiEv.reqStep 0)) ++ [.recyclePrefill 0] ++
  (producer.map (MultiEv.reqStep 1)) ++ (consumer.map (MultiEv.reqStep 0)) ++
  (consumer.map (MultiEv.reqStep 1))

def modelOnly : List (String × List MultiEv) :=
  [("cancelled request handed off, next request completes (run_all.sh)", tr_multi_request),
   ("prefill recycled while the receive side still runs (run_all.sh)", tr_overlapped_requests)]

def paired : List (String × List MultiEv) := []

/-- Both traces run to their end; `nextRequest` and `recyclePrefill` are each
reached by one of them; `corrupted` by neither; no `reqStep` in either trace
corrupts. -/
def coverageChecks : Bool :=
  let ls := modelOnly.map fun (_, tr) => leaves (multiInit 1) tr
  (modelOnly.all fun (_, tr) => ((multiSys 1).run tr).isSome) ∧
  (ls[0]?.map (·.contains .nextRequest)).getD false ∧
  (ls[1]?.map (·.contains .recyclePrefill)).getD false ∧
  ls.all (fun l => !l.contains .corrupted)

#guard coverageChecks

end Multi

end TpuSyncVerify.Transfer.PrefillDecode.Pipeline
