import TpuSyncVerify.Common.System
import TpuSyncVerify.Common.ModelCheck
import TpuSyncVerify.Common.ListAux
import TpuSyncVerify.Transfer.Session

/-!
# Receiver-side stream accounting in `BlockTransport`

Models the `{uuid, layer}` progress table of `BlockTransport` and the two
receiver counters of `TransferReceiveSession` it feeds, to discharge the
assumption `Receive.lean` calls **A1** ("one dispatch per layer") and the
coarsening behind **A4** ("a layer's blocks are accounted once its copy is
issued"), and to state exactly what they rest on.

Citations are against tpu-sync `0ac16d1`. Abbreviations: `bt.cc` =
`tpu_sync/transport/block_transport.cc`, `bt.h` =
`tpu_sync/transport/block_transport.h`, `recv.cc` =
`tpu_sync/kv_cache/transfer_receive_session.cc`, `mgr.cc` =
`tpu_sync/kv_cache/kv_cache_manager_with_transfer.cc`.

## What is modelled

One receive (`uuid`) with `numLayers` block arrays, each pushed by
`numSenders` senders that each declare `numStreams` streams per layer
(`header.reserved`, `bt.cc:619,641`) carrying `blocksPerStream` blocks. A
stream is `HandleIncomingPush` (`bt.cc:495-638`) from the admission gate to
the final ack, collapsed into one event: the progress-table update is one
`progress_mu_` critical section (`bt.cc:674-781`) and the two delegate
callbacks that follow run on the same reader thread, so interleaving other
streams between them changes nothing the properties here observe. The
sender always names one layer per stream (`send.cc:520` → `bt.cc:1171-1174`),
so the all-layers form `local_id == 0xFFFFFFFF` (`bt.cc:355-357, 651`) does
not arise and `l` ranges over `0 .. numLayers - 1`.

Two of the three completion contracts of `CompleteIncomingPush`
(`bt.cc:640-793`) are modelled, selected by `Cfg.declared`:

* **chunk-count** (`expected_senders = nullopt`, `bt.cc:739-741`): the layer
  completes when `completed_chunks == num_streams`. This is the contract of
  the prefill-to-decode path whenever no receiver plan with
  `shard_push_schedules` is registered (`ExpectedPushSenders`,
  `kv_cache_manager_base.cc:2687-2703`) — in particular always on the
  `StartRead` pull path, which registers no plan (`mgr.cc:844-948`).
* **sender-declared** (`expected_senders = some n`, `bt.cc:710-738`): per
  sender `landed`/`declared`, `senders_complete`, and three rejections
  (`AlreadyExists` when a sender lands more than it declared or more senders
  than expected appear, `FailedPrecondition` when a sender re-declares).

The plan-declared contract (`bt.cc:686-709`, pool resharding) is out of
scope; see `Reshard/`.

The session side is `Transfer/Session.lean`'s `Lifecycle`, transcribed as
`Receive.lean` does: the push lease is `beginOp` (`TryBeginRecvOp`,
`mgr.cc:243-248`) and is returned inside the same event (`EndRecvOp`,
`mgr.cc:271`/`:632`); the H2D callback and the poll finish through
`finishLocked`/`endOpLocked` (`recv.cc:357-370, 406-417`). `inFlight` counts
only H2D copies whose callback has not run.

## State

| Field | C++ | Role |
|---|---|---|
| `Layer.entry` | `layer_progress_[{uuid, l}]` (`bt.h:289-310, 322, 333`) | `none` = no entry (never created, or erased by retirement) |
| `Progress.completedChunks` | `LayerProgress::completed_chunks` | chunk-count contract |
| `Progress.landed` | `SenderStreams::landed` per sender | sender-declared contract |
| `Progress.sendersComplete` | `LayerProgress::senders_complete` | sender-declared contract |
| `Progress.called` | `LayerProgress::on_layer_received_called` | the once-latch |
| `Layer.sent` | ghost | streams accepted per sender for this layer |
| `Layer.dispatched` | ghost | `OnLayerReceived` → `ExecuteLayerH2d` entries for this layer |
| `Layer.pending` | subset of `h2d_futures_` (`recv.cc:696-699`) | copies issued for this layer whose callback has not run |
| `blocks` | `blocks_received_per_shard_` collapsed to one shard (`recv.cc:474-490`) | block units reported by `OnBlockShardsReceived` |
| `completedLayers` | `num_completed_layers_` (`recv.cc:725`) | H2D callbacks that ran OK |
| `life` | `in_flight_`, `draining_`, `done_`, `status_`, staging (`Lifecycle`) | settle protocol |

The shard dimension is collapsed: every shard shares the one target
`total_blocks_ * num_layers` (`recv.cc:474-475`) and a stream adds its block
count to every shard it carries, so one counter against
`numSenders * numStreams * blocksPerStream * numLayers` has the same
completion behaviour (A4 in `Receive.lean` restates this over shards).

## Events

| Event | C++ |
|---|---|
| `stream l s` | `HandleIncomingPush`: `BeginIncomingPush` → `TryBeginRecvOp` (`mgr.cc:224-249`, refuses once `done_`/`draining_`), payload, `CompleteIncomingPush` (`bt.cc:618-621`), on completion `OnLayerReceived` → `ExecuteLayerH2d` (`mgr.cc:163-178`, `recv.cc:642-700`, `++in_flight_` at `:652`), then `OnBlockShardsReceived` (`bt.cc:629-630`, `recv.cc:592-640`), `EndIncomingPush` (`bt.cc:632`). A rejection inside `CompleteIncomingPush` returns early and the `absl::Cleanup` ends the push with `InternalError` (`bt.cc:509-516`), which `end_incoming_push` turns into `Finish(status)` then `EndRecvOp` (`mgr.cc:267-271`). |
| `h2dDone l ok` | the `OnReady` callback of a layer's copy (`recv.cc:702-744`): on OK `num_completed_layers_++` and, at `num_layers()` while not draining, the success `FinishLocked()` (`:725-731`); on error `FinishLocked(status, kH2dPhase)` (`:737`); then the cleanup's `EndRecvOp` (`:712`) |
| `publish` | `CompleteReadWithDetails` (`mgr.cc:1009-1013`): a receive that is not draining and `IsReadyToComplete()` (`recv.cc:450-455`: `network_completed_ || num_completed_layers_ == num_layers`, and every issued future ready) is `Finish()`ed. "Every future ready" is taken as "every callback has run"; the window between the two is `ReceivePoll.lean`'s subject (`pollReady`) and changes no property here. |
| `cancel` | the deadline sweep (`mgr.cc:1014-1020`) or any other `Finish(error)` on a receive that is not yet draining |

`published` (`life.done && life.statusOk`) is what the poll reports in
`done_recving_` (`mgr.cc:1024-1026`).

## Assumptions

* **A1 (one lock).** All progress-table mutation is under `progress_mu_`
  (`bt.cc:674-781`); the latch is set in the same critical section that
  decides completion (`bt.cc:742-744`). Encoded by making the table update
  one step.
* **A2 (stable expectation).** `ExpectedPushSenders(uuid)` is read outside
  the lock and latched on the layer's first stream (`bt.cc:661-683`), so the
  contract a layer runs under is whatever the first stream saw. Encoded as
  the fixed `Cfg.declared`. On the `StartRead` path there is never a plan;
  on the plan path the session is seated (`mgr.cc:549-567`) *before* the
  plan is published (`:596-599`), so a push landing in that window would
  latch chunk-count on a layer of a sender-declared plan. That the sender
  does not start before the receiver's registration has returned is a
  controller-side ordering outside this repository's code; it is assumed,
  not proved. `trace_chunk_two_senders` is what the window would produce
  on a multi-sender plan.
* **A3 (uniform declaration, one node per schedule).** Every sender declares
  the same `numStreams`, and no sender outside the expected set appears; the
  `FailedPrecondition` and "more senders" rejections (`bt.cc:719-727`) are
  therefore never taken and are not modelled. Senders are told apart by
  `header.remote_id = node_id()` (`bt.cc:1168`) while `expected_senders`
  counts `shard_push_schedules`, keyed by source shard partition
  (`raiden_service.proto:178-180`); the contract therefore presumes one
  source shard per node, which the receiver never checks.
* **A4 (honest senders) — `Cfg.honest`.** Every sender sends at most the
  streams it declared for each layer, for the life of the receive. Encoded as
  a guard on `stream`: a stream beyond the declaration is not enabled. This
  is the assumption the C++ does **not** enforce on the chunk-count contract,
  nor on any contract after the table entries are retired
  (`bt.cc:764-778`); the traces at the end drop it.

## Properties

* **`OnceDispatched`** — `ExecuteLayerH2d` runs at most once per layer. This
  is `Receive.lean` A1 and what its guard `issued + pending < numLayers`
  encodes.
* **`NetworkSound`** — when the block count reaches its target, every layer's
  copy has been issued. This is the coarsening behind `Receive.lean` A4
  (`netAccount` guarded by `layersAccounted < issued`).
* **`CompleteOnSuccess`** — a receive published as successful issued every
  layer's copy exactly once and no copy is still in flight. This is what the
  engine reads out of `done_recving`.

`reachable_safe`: under A4 both contracts satisfy all three, for any
positive `numLayers`, `numSenders`, `numStreams`, `blocksPerStream`.

Without A4 (`Cfg.honest = false`) the traces at the end show what one extra
stream does: on the chunk-count contract before retirement the receive is
published with a layer never copied; on either contract after retirement the
layer is copied twice (the session's `in_flight_` still holds `done_` off
until both copies return, and a failing duplicate copy fails the receive).
-/

namespace TpuSyncVerify.Transfer.PrefillDecode.Transport

open TpuSyncVerify TpuSyncVerify.Transfer

/-! ## Parameters and state -/

structure Cfg where
  numLayers : Nat
  numSenders : Nat
  /-- Streams each sender declares per layer (`header.reserved`). -/
  numStreams : Nat
  /-- Block units a stream adds to the receiver's count. -/
  blocksPerStream : Nat
  /-- `true`: sender-declared contract (`expected_senders = some numSenders`);
  `false`: chunk-count contract (`expected_senders = nullopt`). -/
  declared : Bool
  /-- A4: refuse streams beyond a sender's declaration. -/
  honest : Bool
  deriving Repr, DecidableEq

/-- `LayerProgress` (`bt.h:289-310`). -/
structure Progress where
  completedChunks : Nat
  landed : List Nat
  sendersComplete : Nat
  called : Bool
  deriving Repr, DecidableEq

structure Layer where
  entry : Option Progress
  sent : List Nat
  dispatched : Nat
  pending : Nat
  deriving Repr, DecidableEq

structure S where
  layers : List Layer
  blocks : Nat
  completedLayers : Nat
  /-- `in_flight_` / `draining_` / `done_` / `status_` / staging of the receive
  session (`Transfer/Session.lean`). `inFlight` counts only H2D copies whose
  callback has not run: the push lease is taken and returned inside the one
  atomic `stream` event. -/
  life : Lifecycle
  deriving Repr, DecidableEq

def natSum : List Nat → Nat
  | [] => 0
  | n :: ns => n + natSum ns

/-- Blocks an honest run delivers per layer. -/
def Cfg.perLayer (c : Cfg) : Nat := c.numSenders * c.numStreams * c.blocksPerStream

/-- `total_blocks_ * num_layers` (`recv.cc:474-475`). -/
def Cfg.target (c : Cfg) : Nat := c.perLayer * c.numLayers

/-- The preconditions the C++ already enforces or the deployment guarantees:
at least one layer-array sender, a positive declared stream count
(`bt.cc:713-717`), and non-empty streams. -/
structure Cfg.WF (c : Cfg) : Prop where
  senders : 0 < c.numSenders
  streams : 0 < c.numStreams
  blocks : 0 < c.blocksPerStream
  /-- The chunk-count contract is single-sender. On the `StartRead` path no
  receiver plan is registered at all and the pull goes to one endpoint
  (`mgr.cc:840`, `:948`), so there is one sender; on the plan path a plan with
  several `shard_push_schedules` makes `ExpectedPushSenders` return their count
  (`kv_cache_manager_base.cc:2696-2703`), selecting the sender-declared
  contract. `trace_chunk_two_senders` shows what the excluded instance does. -/
  chunkSingle : c.declared = false → c.numSenders = 1

def freshLayer (c : Cfg) : Layer :=
  { entry := none, sent := List.replicate c.numSenders 0, dispatched := 0, pending := 0 }

def init (c : Cfg) : S :=
  { layers := List.replicate c.numLayers (freshLayer c),
    blocks := 0, completedLayers := 0, life := {} }

/-- `network_completed_` (`recv.cc:484-487`), derived. -/
def networkCompleted (c : Cfg) (s : S) : Bool := decide (c.target ≤ s.blocks)

/-- What `CompleteReadWithDetails` reports in `done_recving_` (`mgr.cc:1024-1026`). -/
def published (s : S) : Bool := s.life.done && s.life.statusOk

/-! ## Events -/

inductive Ev where
  | stream (layer sender : Nat)
  | h2dDone (layer : Nat) (ok : Bool)
  | publish
  | cancel
  deriving Repr, DecidableEq

def freshProgress (c : Cfg) : Progress :=
  { completedChunks := 0, landed := List.replicate c.numSenders 0,
    sendersComplete := 0, called := false }

/-- `CompleteIncomingPush` on one table entry (`bt.cc:674-744`). Returns the
updated entry, whether this stream completed the layer (`trigger_completion`),
and whether the push was rejected. In the sender-declared contract the
`landed` increment (`bt.cc:729`) persists even when the over-count check that
follows it (`bt.cc:732-736`) rejects the push. -/
def completePush (c : Cfg) (p : Progress) (sender : Nat) : Progress × Bool × Bool :=
  if c.declared then
    let landed := p.landed.getD sender 0 + 1
    let sendersComplete :=
      if landed = c.numStreams then p.sendersComplete + 1 else p.sendersComplete
    let reject := decide (c.numStreams < landed)
    let complete := decide (sendersComplete = c.numSenders)
    let fire := complete && !reject && !p.called
    ({ p with completedChunks := p.completedChunks + 1,
              landed := p.landed.set sender landed,
              sendersComplete := sendersComplete,
              called := p.called || (complete && !reject) },
     fire, reject)
  else
    let completed := p.completedChunks + 1
    let complete := decide (completed = c.numStreams)
    ({ p with completedChunks := completed, called := p.called || complete },
     complete && !p.called, false)

def Layer.entryCalled (L : Layer) : Bool :=
  match L.entry with
  | some p => p.called
  | none => false

/-- Retirement (`bt.cc:764-778`): once every layer's latch is set, the uuid's
entries are erased. -/
def retire (layers : List Layer) : List Layer :=
  if layers.all Layer.entryCalled then layers.map (fun L => { L with entry := none })
  else layers

/-- The layer after an accepted stream: the updated table entry, the ghost
stream count, and — when the stream completed the layer — the `ExecuteLayerH2d`
entry and its in-flight copy. -/
def nextLayer (L : Layer) (p' : Progress) (sent' : List Nat) (fire : Bool) : Layer :=
  { entry := some p', sent := sent',
    dispatched := if fire then L.dispatched + 1 else L.dispatched,
    pending := if fire then L.pending + 1 else L.pending }

@[simp] theorem nextLayer_entry (L : Layer) (p' : Progress) (s' : List Nat) (f : Bool) :
    (nextLayer L p' s' f).entry = some p' := rfl
@[simp] theorem nextLayer_sent (L : Layer) (p' : Progress) (s' : List Nat) (f : Bool) :
    (nextLayer L p' s' f).sent = s' := rfl
@[simp] theorem nextLayer_dispatched (L : Layer) (p' : Progress) (s' : List Nat) (f : Bool) :
    (nextLayer L p' s' f).dispatched = if f then L.dispatched + 1 else L.dispatched := rfl
@[simp] theorem nextLayer_pending (L : Layer) (p' : Progress) (s' : List Nat) (f : Bool) :
    (nextLayer L p' s' f).pending = if f then L.pending + 1 else L.pending := rfl

/-- The session side of one stream, given the transport's verdict. Push lease
`TryBeginRecvOp` (`beginOp`, `mgr.cc:243-248`); on completion `ExecuteLayerH2d`
takes the copy's op (`recv.cc:652`, `fire`); a rejection runs the cleanup's
`EndIncomingPush(InternalError)` → `Finish(status)` (`mgr.cc:267-270`); the
lease is returned by `EndRecvOp` (`mgr.cc:271`, or `:632` on success). -/
def streamLife (l : Lifecycle) (fire reject : Bool) : Lifecycle :=
  let l := if fire then { l with inFlight := l.inFlight + 1 } else l
  let l := if reject then l.finishLocked false else l
  l.endOpLocked

/-- `HandleIncomingPush` for one stream of layer `l` from sender `sender`. -/
def streamStep (c : Cfg) (s : S) (l sender : Nat) : Option S :=
  match s.life.beginOp, s.layers[l]? with
  | some life₁, some L =>
    if c.numSenders ≤ sender then none
    else if c.honest && c.numStreams ≤ L.sent.getD sender 0 then none
    else
      match completePush c (L.entry.getD (freshProgress c)) sender with
      | (p', fire, reject) =>
        let sent' := L.sent.set sender (L.sent.getD sender 0 + 1)
        if reject then
          some { s with layers := s.layers.set l { L with entry := some p', sent := sent' },
                        life := streamLife life₁ false true }
        else
          some { s with layers := retire (s.layers.set l (nextLayer L p' sent' fire)),
                        life := streamLife life₁ fire false,
                        blocks := s.blocks + c.blocksPerStream }
  | _, _ => none

def Layer.copyDone (L : Layer) : Layer := { L with pending := L.pending - 1 }

@[simp] theorem Layer.copyDone_pending (L : Layer) : L.copyDone.pending = L.pending - 1 := rfl
@[simp] theorem Layer.copyDone_dispatched (L : Layer) : L.copyDone.dispatched = L.dispatched := rfl
@[simp] theorem Layer.copyDone_sent (L : Layer) : L.copyDone.sent = L.sent := rfl
@[simp] theorem Layer.copyDone_entry (L : Layer) : L.copyDone.entry = L.entry := rfl

/-- The H2D `OnReady` callback (`recv.cc:702-744`): on success
`num_completed_layers_++` and, at `num_layers()` while not draining, the
success `FinishLocked()`; on failure `FinishLocked(status, kH2dPhase)`; then
the cleanup's `EndRecvOp`. -/
def callbackLife (c : Cfg) (l : Lifecycle) (ok : Bool) (completed : Nat) : Lifecycle :=
  let l :=
    if ok then
      if completed = c.numLayers ∧ l.draining = false then l.finishLocked true else l
    else l.finishLocked false
  l.endOpLocked

def h2dDoneStep (c : Cfg) (s : S) (l : Nat) (ok : Bool) : Option S :=
  match s.layers[l]? with
  | none => none
  | some L =>
    if L.pending = 0 then none
    else
      let completed := if ok then s.completedLayers + 1 else s.completedLayers
      some { s with layers := s.layers.set l L.copyDone,
                    completedLayers := completed,
                    life := callbackLife c s.life ok completed }

/-- The poll (`mgr.cc:1009-1013`): a receive that is not draining and
`IsReadyToComplete()` (`recv.cc:450-455`) is finished with OK. `AllH2dDoneLocked`
(every issued future ready) is taken as "every callback has run"; the window
between the two is `ReceivePoll.lean`'s subject and changes nothing here. -/
def publishStep (c : Cfg) (s : S) : Option S :=
  if s.life.draining then none
  else if (networkCompleted c s || decide (s.completedLayers = c.numLayers)) &&
          s.layers.all (fun L => decide (L.pending = 0)) then
    some { s with life := s.life.finishLocked true }
  else none

/-- The deadline sweep (`mgr.cc:1014-1020`) or any other `Finish(error)`. -/
def cancelStep (s : S) : Option S :=
  if s.life.draining then none else some { s with life := s.life.finishLocked false }

def step (c : Cfg) (s : S) : Ev → Option S
  | .stream l sender => streamStep c s l sender
  | .h2dDone l ok => h2dDoneStep c s l ok
  | .publish => publishStep c s
  | .cancel => cancelStep s

def sys (c : Cfg) : System S Ev := ⟨init c, step c⟩

/-! ## Properties -/

def OnceDispatched (s : S) : Prop := ∀ L ∈ s.layers, L.dispatched ≤ 1

def NetworkSound (c : Cfg) (s : S) : Prop :=
  networkCompleted c s = true → ∀ L ∈ s.layers, 1 ≤ L.dispatched

def CompleteOnSuccess (s : S) : Prop :=
  published s = true → ∀ L ∈ s.layers, L.dispatched = 1 ∧ L.pending = 0

def Safe (c : Cfg) (s : S) : Prop := OnceDispatched s ∧ NetworkSound c s ∧ CompleteOnSuccess s

/-- Executable negation of `Safe`, for the bounded searches. -/
def violates (c : Cfg) (s : S) : Bool :=
  s.layers.any (fun L => decide (1 < L.dispatched)) ||
  (networkCompleted c s && s.layers.any (fun L => decide (L.dispatched = 0))) ||
  (published s &&
    s.layers.any (fun L => !(decide (L.dispatched = 1) && decide (L.pending = 0))))

/-! ## Arithmetic over `natSum` -/

theorem natSum_append : ∀ (l₁ l₂ : List Nat), natSum (l₁ ++ l₂) = natSum l₁ + natSum l₂
  | [], _ => by simp [natSum]
  | n :: ns, l₂ => by simp [natSum, natSum_append ns l₂, Nat.add_assoc]

theorem le_natSum_of_mem : ∀ {l : List Nat} {a : Nat}, a ∈ l → a ≤ natSum l
  | n :: ns, a, h => by
    simp only [natSum]
    rcases List.mem_cons.mp h with rfl | h
    · exact Nat.le_add_right _ _
    · exact Nat.le_trans (le_natSum_of_mem h) (Nat.le_add_left _ _)

theorem natSum_le_length_mul : ∀ {l : List Nat} {k : Nat}, (∀ n ∈ l, n ≤ k) →
    natSum l ≤ l.length * k
  | [], _, _ => by simp [natSum]
  | n :: ns, k, h => by
    simp only [natSum, List.length_cons, Nat.succ_mul]
    have hn := h n (List.mem_cons_self ..)
    have hns := natSum_le_length_mul (fun m hm => h m (List.mem_cons_of_mem _ hm))
    omega

theorem all_eq_of_natSum_ge : ∀ {l : List Nat} {k : Nat}, (∀ n ∈ l, n ≤ k) →
    l.length * k ≤ natSum l → ∀ n ∈ l, n = k
  | [], _, _, _, _, h => by simp at h
  | n :: ns, k, hle, hsum, m, hm => by
    simp only [natSum, List.length_cons, Nat.succ_mul] at hsum
    have hn := hle n (List.mem_cons_self ..)
    have hns := natSum_le_length_mul (fun m hm => hle m (List.mem_cons_of_mem _ hm))
    rcases List.mem_cons.mp hm with rfl | hm
    · omega
    · exact all_eq_of_natSum_ge (fun m hm => hle m (List.mem_cons_of_mem _ hm))
        (by omega) m hm

theorem eq_zero_of_natSum_eq_zero {l : List Nat} (h : natSum l = 0) : ∀ m ∈ l, m = 0 :=
  fun _ hm => Nat.le_zero.mp (h ▸ le_natSum_of_mem hm)

theorem natSum_replicate_zero : ∀ n, natSum (List.replicate n 0) = 0
  | 0 => rfl
  | n + 1 => by simp [List.replicate_succ, natSum, natSum_replicate_zero n]

theorem natSum_set : ∀ {l : List Nat} {i a x : Nat}, l[i]? = some a →
    natSum (l.set i x) + a = natSum l + x
  | [], i, _, _, h => by simp at h
  | n :: ns, 0, a, x, h => by
    simp at h; subst h; simp [natSum, Nat.add_comm, Nat.add_left_comm]
  | n :: ns, i + 1, a, x, h => by
    simp only [List.getElem?_cons_succ] at h
    simp only [List.set_cons_succ, natSum]
    have := natSum_set (x := x) h
    omega

theorem natSum_map_set {α : Type} (f : α → Nat) {l : List α} {i : Nat} {a x : α}
    (h : l[i]? = some a) :
    natSum ((l.set i x).map f) + f a = natSum (l.map f) + f x := by
  rw [List.map_set]
  exact natSum_set (by simp [h])

def countEq (k : Nat) : List Nat → Nat
  | [] => 0
  | n :: ns => (if n = k then 1 else 0) + countEq k ns

theorem countEq_le_length (k : Nat) : ∀ l : List Nat, countEq k l ≤ l.length
  | [] => Nat.le_refl _
  | n :: ns => by
    simp only [countEq, List.length_cons]
    have := countEq_le_length k ns
    split <;> omega

theorem countEq_eq_length_iff (k : Nat) : ∀ l : List Nat,
    countEq k l = l.length ↔ ∀ n ∈ l, n = k
  | [] => by simp [countEq]
  | n :: ns => by
    simp only [countEq, List.length_cons, List.mem_cons, forall_eq_or_imp]
    have hle := countEq_le_length k ns
    have ih := countEq_eq_length_iff k ns
    constructor
    · intro h
      split at h
      · exact ⟨‹_›, ih.mp (by omega)⟩
      · omega
    · rintro ⟨rfl, h⟩
      simp [ih.mpr h]; omega

theorem countEq_set : ∀ {l : List Nat} {i a x k : Nat}, l[i]? = some a → a ≠ k →
    countEq k (l.set i x) = countEq k l + (if x = k then 1 else 0)
  | [], i, _, _, _, h, _ => by simp at h
  | n :: ns, 0, a, x, k, h, hne => by
    simp at h; subst h; simp [countEq, hne]; omega
  | n :: ns, i + 1, a, x, k, h, hne => by
    simp only [List.getElem?_cons_succ] at h
    simp only [List.set_cons_succ, countEq, countEq_set h hne]
    omega

theorem getD_eq_of_getElem? : ∀ {l : List Nat} {i a d : Nat}, l[i]? = some a → l.getD i d = a
  | [], _, _, _, h => by simp at h
  | n :: ns, 0, a, d, h => by simp at h; subst h; rfl
  | n :: ns, i + 1, a, d, h => by
    simp only [List.getElem?_cons_succ] at h
    simp only [List.getD_cons_succ]
    exact getD_eq_of_getElem? h

/-! ## Inductive invariant (honest senders) -/

/-- Every sender has landed all its declared streams for this layer. -/
def fullB (c : Cfg) (sent : List Nat) : Bool := sent.all (fun n => decide (n = c.numStreams))

theorem fullB_iff (c : Cfg) (sent : List Nat) : fullB c sent = true ↔ ∀ n ∈ sent, n = c.numStreams := by
  simp [fullB, List.all_eq_true]

theorem fullB_false_of_lt {c : Cfg} {sent : List Nat} {i n : Nat}
    (h : sent[i]? = some n) (hn : n < c.numStreams) : fullB c sent = false := by
  cases hf : fullB c sent
  · rfl
  · have := (fullB_iff c sent).mp hf n (TpuSyncVerify.getElem?_mem h)
    omega

/-- How a live table entry relates to the ghost `sent`. -/
structure EntryInv (c : Cfg) (sent : List Nat) (p : Progress) : Prop where
  called : p.called = fullB c sent
  chunk : c.declared = false → p.completedChunks = natSum sent
  decl : c.declared = true → p.landed = sent ∧ p.sendersComplete = countEq c.numStreams sent

structure LInv (c : Cfg) (L : Layer) : Prop where
  sentLen : L.sent.length = c.numSenders
  sentLe : ∀ n ∈ L.sent, n ≤ c.numStreams
  entry : ∀ p, L.entry = some p → EntryInv c L.sent p
  noEntry : L.entry = none → natSum L.sent = 0 ∨ fullB c L.sent = true
  disp : L.dispatched = if fullB c L.sent then 1 else 0
  pend : L.pending ≤ L.dispatched

structure Inv (c : Cfg) (s : S) : Prop where
  len : s.layers.length = c.numLayers
  layers : ∀ L ∈ s.layers, LInv c L
  blocks : s.blocks = c.blocksPerStream * natSum (s.layers.map fun L => natSum L.sent)
  life : s.life.Consistent
  /-- An error is only ever recorded by a `FinishLocked`, which also drains. -/
  failed : s.life.statusOk = false → s.life.draining = true
  inFlight : s.life.inFlight = natSum (s.layers.map Layer.pending)
  /-- While no copy has failed, every dispatched copy is pending or completed. -/
  completed : s.life.statusOk = true →
    s.completedLayers + s.life.inFlight = natSum (s.layers.map Layer.dispatched)
  /-- A receive that started draining with an OK status did so because every
  layer's single copy had completed. -/
  fin : s.life.draining = true → s.life.statusOk = true →
    ∀ L ∈ s.layers, L.dispatched = 1 ∧ L.pending = 0

theorem LInv.disp_le_one {c : Cfg} {L : Layer} (h : LInv c L) : L.dispatched ≤ 1 := by
  rw [h.disp]; split <;> omega

theorem LInv.natSum_sent_le {c : Cfg} {L : Layer} (h : LInv c L) :
    natSum L.sent ≤ c.numSenders * c.numStreams :=
  h.sentLen ▸ natSum_le_length_mul h.sentLe

theorem fullB_fresh_false {c : Cfg} (hwf : c.WF) : fullB c (List.replicate c.numSenders 0) = false := by
  cases hs : c.numSenders with
  | zero => exact absurd hs (Nat.ne_of_gt hwf.senders)
  | succ k =>
    apply fullB_false_of_lt (i := 0) (n := 0)
    · simp [List.replicate_succ]
    · exact hwf.streams

theorem inv_init (c : Cfg) (hwf : c.WF) : Inv c (init c) := by
  have hfresh : natSum (freshLayer c).sent = 0 := by simp [freshLayer, natSum_replicate_zero]
  refine ⟨by simp [init], ?_, ?_, Lifecycle.consistent_init, by simp [init], ?_, ?_, by simp [init]⟩
  · intro L hL
    rw [List.eq_of_mem_replicate hL]
    refine ⟨by simp [freshLayer], ?_, by simp [freshLayer], ?_, ?_, by simp [freshLayer]⟩
    · intro n hn; simp [freshLayer] at hn; omega
    · intro _; left; exact hfresh
    · simp [freshLayer, fullB_fresh_false hwf]
  · simp [init, hfresh, natSum_replicate_zero]
  · simp [init, freshLayer, natSum_replicate_zero]
  · intro _; simp [init, freshLayer, natSum_replicate_zero]

/-! ### Helper lemmas on the ghost lists -/

theorem countEq_replicate_zero {k : Nat} (hk : 0 < k) : ∀ n, countEq k (List.replicate n 0) = 0
  | 0 => rfl
  | n + 1 => by
    simp only [List.replicate_succ, countEq, countEq_replicate_zero hk n]
    have : k ≠ 0 := Nat.ne_of_gt hk
    simp [Ne.symm this]

theorem retire_length (ls : List Layer) : (retire ls).length = ls.length := by
  unfold retire; split <;> simp

theorem retire_map_sent (ls : List Layer) :
    (retire ls).map (fun L => natSum L.sent) = ls.map (fun L => natSum L.sent) := by
  unfold retire; split <;> simp [List.map_map, Function.comp_def]

theorem retire_map_pending (ls : List Layer) :
    (retire ls).map Layer.pending = ls.map Layer.pending := by
  unfold retire; split <;> simp [List.map_map, Function.comp_def]

theorem retire_map_dispatched (ls : List Layer) :
    (retire ls).map Layer.dispatched = ls.map Layer.dispatched := by
  unfold retire; split <;> simp [List.map_map, Function.comp_def]

theorem mem_retire {ls : List Layer} {M : Layer} (h : M ∈ retire ls) :
    M ∈ ls ∨ ∃ M₀ ∈ ls, M₀.entryCalled = true ∧ M = { M₀ with entry := none } := by
  unfold retire at h
  split at h
  · rename_i hall
    rw [List.all_eq_true] at hall
    obtain ⟨M₀, hM₀, rfl⟩ := List.mem_map.mp h
    exact Or.inr ⟨M₀, hM₀, hall M₀ hM₀, rfl⟩
  · exact Or.inl h

theorem LInv.clear {c : Cfg} {L : Layer} (h : LInv c L) (hc : L.entryCalled = true) :
    LInv c { L with entry := none } := by
  refine ⟨h.sentLen, h.sentLe, by simp, ?_, h.disp, h.pend⟩
  intro _
  right
  unfold Layer.entryCalled at hc
  split at hc
  · rename_i p hp
    exact (h.entry p hp).called ▸ hc
  · cases hc

theorem getElem?_of_lt_length {l : List Nat} {i : Nat} (hi : i < l.length) :
    ∃ a, l[i]? = some a :=
  ⟨l[i], List.getElem?_eq_getElem hi⟩

/-- A layer with no table entry and a stream still to come is untouched, and
the fresh entry `CompleteIncomingPush` creates for it agrees with the ghost. -/
theorem LInv.entryInv_getD {c : Cfg} (hwf : c.WF) {L : Layer} (h : LInv c L) {i a : Nat}
    (hi : L.sent[i]? = some a) (ha : a < c.numStreams) :
    EntryInv c L.sent (L.entry.getD (freshProgress c)) := by
  cases hE : L.entry with
  | some p => exact h.entry p hE
  | none =>
    have hnf := fullB_false_of_lt hi ha
    rcases h.noEntry hE with hz | hf
    · have hsent : L.sent = List.replicate c.numSenders 0 :=
        List.eq_replicate_iff.mpr ⟨h.sentLen, eq_zero_of_natSum_eq_zero hz⟩
      refine ⟨by simp [freshProgress, hnf], fun _ => by simp [freshProgress, hz], fun _ => ?_⟩
      refine ⟨by simp [freshProgress, hsent], ?_⟩
      simp only [freshProgress, hsent]
      exact (countEq_replicate_zero hwf.streams _).symm
    · rw [hf] at hnf; cases hnf

/-- `CompleteIncomingPush` on an honest stream: never rejects, fires exactly
when this stream completes the sender set, and keeps the entry in agreement
with the ghost. -/
theorem completePush_honest {c : Cfg} (hwf : c.WF) {sent : List Nat} {p : Progress} {i a : Nat}
    (hE : EntryInv c sent p) (hlen : sent.length = c.numSenders)
    (hi : sent[i]? = some a) (ha : a < c.numStreams) :
    ∃ p', completePush c p i = (p', fullB c (sent.set i (a + 1)), false) ∧
      EntryInv c (sent.set i (a + 1)) p' := by
  have hcalled : p.called = false := hE.called ▸ fullB_false_of_lt hi ha
  have hne : a ≠ c.numStreams := Nat.ne_of_lt ha
  cases hd : c.declared with
  | false =>
    have h1 : c.numSenders = 1 := hwf.chunkSingle hd
    have hsent : sent = [a] := by
      match sent, hlen, hi with
      | [], hlen, _ => simp at hlen; omega
      | [x], _, hi =>
        cases i with
        | zero => simp at hi; subst hi; rfl
        | succ j => simp at hi
      | _ :: _ :: _, hlen, _ => simp at hlen; omega
    subst hsent
    have hi0 : i = 0 := by
      cases i with
      | zero => rfl
      | succ j => simp at hi
    subst hi0
    have hcc := hE.chunk hd
    simp only [natSum, Nat.add_zero] at hcc
    refine ⟨(completePush c p 0).1, Prod.ext rfl (Prod.ext ?_ ?_), ?_⟩
    · simp [completePush, hd, hcc, hcalled, fullB]
    · simp [completePush, hd]
    · refine ⟨?_, fun _ => ?_, (fun h' => by rw [hd] at h'; cases h')⟩
      · simp [completePush, hd, hcc, hcalled, fullB]
      · simp [completePush, hd, hcc, natSum]
  | true =>
    obtain ⟨hlanded, hsc⟩ := hE.decl hd
    have hgetD : p.landed.getD i 0 = a := hlanded ▸ getD_eq_of_getElem? hi
    have hgetD' : p.landed[i]? = some a := hlanded ▸ hi
    have hrej : decide (c.numStreams < a + 1) = false := by simp; omega
    have hcount := countEq_set (x := a + 1) (k := c.numStreams) hi hne
    have hfull : fullB c (sent.set i (a + 1)) =
        decide ((if a + 1 = c.numStreams then p.sendersComplete + 1 else p.sendersComplete) =
          c.numSenders) := by
      rw [Bool.eq_iff_iff, decide_eq_true_iff, fullB_iff, ← countEq_eq_length_iff,
        List.length_set, hlen, hcount, hsc]
      by_cases hc : a + 1 = c.numStreams <;> simp [hc]
    refine ⟨(completePush c p i).1, Prod.ext rfl (Prod.ext ?_ ?_), ?_⟩
    · simp only [completePush, hd, ↓reduceIte, hgetD, hrej, hcalled, hfull]; simp
    · simp [completePush, hd, hgetD']; omega
    · refine ⟨?_, (fun h' => by rw [hd] at h'; cases h'), fun _ => ⟨?_, ?_⟩⟩
      · simp only [completePush, hd, ↓reduceIte, hgetD, hrej, hcalled, hfull]; simp
      · simp [completePush, hd, hlanded, hi]
      · simp only [completePush, hd, ↓reduceIte, hgetD, hcount, hsc]; split <;> simp

/-! ### Lifecycle facts used below -/

theorem settle_inFlight (l : Lifecycle) : (l.settleLocked).inFlight = l.inFlight := by
  unfold Lifecycle.settleLocked; split <;> rfl
theorem settle_draining (l : Lifecycle) : (l.settleLocked).draining = l.draining := by
  unfold Lifecycle.settleLocked; split <;> rfl
theorem settle_statusOk (l : Lifecycle) : (l.settleLocked).statusOk = l.statusOk := by
  unfold Lifecycle.settleLocked; split <;> rfl

theorem fl_inFlight (ok : Bool) (l : Lifecycle) : (l.finishLocked ok).inFlight = l.inFlight := by
  unfold Lifecycle.finishLocked
  cases ok <;> cases hs : l.statusOk <;> cases hd : l.draining <;> simp [hs, hd]
theorem fl_draining (ok : Bool) (l : Lifecycle) : (l.finishLocked ok).draining = true := by
  unfold Lifecycle.finishLocked
  cases ok <;> cases hs : l.statusOk <;> cases hd : l.draining <;> simp [hs, hd]
theorem fl_false_statusOk (l : Lifecycle) : (l.finishLocked false).statusOk = false := by
  unfold Lifecycle.finishLocked
  cases hs : l.statusOk <;> cases hd : l.draining <;> simp [hs, hd]
theorem fl_true_statusOk (l : Lifecycle) : (l.finishLocked true).statusOk = l.statusOk := by
  unfold Lifecycle.finishLocked
  cases hs : l.statusOk <;> cases hd : l.draining <;> simp [hs, hd]

theorem eo_inFlight (l : Lifecycle) : (l.endOpLocked).inFlight = l.inFlight - 1 := by
  unfold Lifecycle.endOpLocked; split <;> simp_all
theorem eo_draining (l : Lifecycle) : (l.endOpLocked).draining = l.draining := by
  unfold Lifecycle.endOpLocked; split <;> simp
theorem eo_statusOk (l : Lifecycle) : (l.endOpLocked).statusOk = l.statusOk := by
  unfold Lifecycle.endOpLocked; split <;> simp

theorem beginOp_some {l l' : Lifecycle} (h : l.beginOp = some l') :
    l.draining = false ∧ l' = { l with inFlight := l.inFlight + 1 } := by
  unfold Lifecycle.beginOp at h
  split at h
  · cases h
  · rename_i hn
    cases h
    simp only [not_or, Bool.not_eq_true] at hn
    exact ⟨hn.2, rfl⟩

/-- A non-draining session that takes and returns the push lease, taking the
copy's op in between when the stream fired. -/
theorem streamLife_accept {l : Lifecycle} (hd : l.draining = false) (fire : Bool) :
    streamLife { l with inFlight := l.inFlight + 1 } fire false =
      { l with inFlight := if fire then l.inFlight + 1 else l.inFlight } := by
  unfold streamLife Lifecycle.endOpLocked Lifecycle.settleLocked
  cases fire <;> simp [hd]

/-! ### Preservation -/

theorem stream_inv {c : Cfg} (hwf : c.WF) (hh : c.honest = true) {s s' : S} {l i : Nat}
    (h : Inv c s) (hs : streamStep c s l i = some s') : Inv c s' := by
  unfold streamStep at hs
  split at hs
  · rename_i life₁ L hb hL
    obtain ⟨hdr, hlife₁⟩ := beginOp_some hb
    subst hlife₁
    split at hs
    · cases hs
    rename_i hsender
    split at hs
    · cases hs
    rename_i hguard
    have hLinv := h.layers L (getElem?_mem hL)
    have hi' : i < L.sent.length := by rw [hLinv.sentLen]; omega
    obtain ⟨a, hi⟩ := getElem?_of_lt_length hi'
    have hgetD : L.sent.getD i 0 = a := getD_eq_of_getElem? hi
    have ha : a < c.numStreams := by
      simp only [hh, Bool.true_and, hgetD] at hguard
      simpa using hguard
    obtain ⟨p', hcp, hE'⟩ :=
      completePush_honest hwf (hLinv.entryInv_getD hwf hi ha) hLinv.sentLen hi ha
    split at hs
    rename_i p'' fire reject hcp'
    rw [hcp] at hcp'
    cases hcp'
    simp only [hgetD, Bool.false_eq_true, ↓reduceIte, Option.some.injEq] at hs
    subst hs
    have hsent' : natSum (L.sent.set i (a + 1)) = natSum L.sent + 1 := by
      have := natSum_set (x := a + 1) hi; omega
    have hdisp0 : L.dispatched = 0 := by rw [hLinv.disp, fullB_false_of_lt hi ha]; rfl
    have hpend0 : L.pending = 0 := by have := hLinv.pend; omega
    have hnd : s.life.done = false := h.life.not_done hdr
    have hin := h.inFlight
    rw [streamLife_accept hdr]
    cases hfire : fullB c (L.sent.set i (a + 1))
    all_goals
      have hL₂ : LInv c (nextLayer L p' (L.sent.set i (a + 1)) (fullB c (L.sent.set i (a + 1)))) := by
        refine ⟨by simp [hLinv.sentLen], ?_, ?_, by simp, ?_, ?_⟩
        · intro n hn
          rcases mem_set_cases hn with rfl | hn
          · omega
          · exact hLinv.sentLe n hn
        · intro q hq
          have : p' = q := by simpa using hq
          subst this; exact hE'
        · simp [hdisp0, hfire]
        · simp only [nextLayer_dispatched, nextLayer_pending, hdisp0, hpend0, hfire]; omega
      rw [hfire] at hL₂
      have keyp := natSum_map_set Layer.pending (i := l) hL
        (x := nextLayer L p' (L.sent.set i (a + 1)) (fullB c (L.sent.set i (a + 1))))
      have keyd := natSum_map_set Layer.dispatched (i := l) hL
        (x := nextLayer L p' (L.sent.set i (a + 1)) (fullB c (L.sent.set i (a + 1))))
      have keys := natSum_map_set (fun L : Layer => natSum L.sent) (i := l) hL
        (x := nextLayer L p' (L.sent.set i (a + 1)) (fullB c (L.sent.set i (a + 1))))
      simp only [nextLayer_pending, nextLayer_dispatched, nextLayer_sent, hpend0, hdisp0, hsent',
        hfire, Bool.false_eq_true, ↓reduceIte] at keyp keyd keys
      refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
      · simp [retire_length, h.len]
      · intro M hM
        rcases mem_retire hM with hM | ⟨M₀, hM₀, hc, rfl⟩
        · rcases mem_set_cases hM with rfl | hM
          · exact hL₂
          · exact h.layers M hM
        · rcases mem_set_cases hM₀ with rfl | hM₀
          · exact hL₂.clear hc
          · exact (h.layers M₀ hM₀).clear hc
      · simp only [retire_map_sent]
        rw [h.blocks, Nat.mul_comm, Nat.mul_comm c.blocksPerStream, ← Nat.succ_mul]
        congr 1
        omega
      · exact ⟨fun hd => by simp [hnd] at hd, fun hd => by simp [hnd] at hd,
               fun hd => by simp [hdr] at hd, by simp [h.life.staging]⟩
      · intro hf; simp only at hf; have := h.failed hf; simp [hdr] at this
      · simp only [retire_map_pending, Bool.false_eq_true, ↓reduceIte]
        omega
      · intro hok
        simp only at hok
        simp only [retire_map_dispatched, Bool.false_eq_true, ↓reduceIte]
        have hc := h.completed hok
        omega
      · intro hd; simp [hdr] at hd
  · cases hs

/-- All layers are dispatched once the dispatch count reaches the layer count. -/
theorem all_dispatched_of_sum {c : Cfg} {ls : List Layer} (hlen : ls.length = c.numLayers)
    (hinv : ∀ L ∈ ls, LInv c L) (hsum : c.numLayers ≤ natSum (ls.map Layer.dispatched)) :
    ∀ L ∈ ls, L.dispatched = 1 := by
  intro L hL
  have hle : ∀ n ∈ ls.map Layer.dispatched, n ≤ 1 := by
    intro n hn
    obtain ⟨M, hM, rfl⟩ := List.mem_map.mp hn
    exact (hinv M hM).disp_le_one
  have := all_eq_of_natSum_ge hle (by simpa [hlen] using hsum)
  exact this _ (List.mem_map.mpr ⟨L, hL, rfl⟩)

theorem natSum_dispatched_le {c : Cfg} {ls : List Layer} (hlen : ls.length = c.numLayers)
    (hinv : ∀ L ∈ ls, LInv c L) : natSum (ls.map Layer.dispatched) ≤ c.numLayers := by
  have := natSum_le_length_mul (l := ls.map Layer.dispatched) (k := 1) (fun n hn => by
    obtain ⟨M, hM, rfl⟩ := List.mem_map.mp hn
    exact (hinv M hM).disp_le_one)
  simpa [hlen] using this

theorem all_pending_zero {ls : List Layer} (hz : natSum (ls.map Layer.pending) = 0) :
    ∀ L ∈ ls, L.pending = 0 :=
  fun L hL => eq_zero_of_natSum_eq_zero hz _ (List.mem_map.mpr ⟨L, hL, rfl⟩)

/-- Every layer is full once the block count reaches its target. -/
theorem all_full_of_blocks {c : Cfg} (hwf : c.WF) {s : S} (h : Inv c s)
    (hb : c.target ≤ s.blocks) : ∀ L ∈ s.layers, fullB c L.sent = true := by
  intro L hL
  rw [h.blocks] at hb
  have hle : ∀ n ∈ s.layers.map (fun L => natSum L.sent), n ≤ c.numSenders * c.numStreams := by
    intro n hn
    obtain ⟨M, hM, rfl⟩ := List.mem_map.mp hn
    exact (h.layers M hM).natSum_sent_le
  have hsum : (s.layers.map fun L => natSum L.sent).length * (c.numSenders * c.numStreams) ≤
      natSum (s.layers.map fun L => natSum L.sent) := by
    have hlen : (s.layers.map fun L => natSum L.sent).length = c.numLayers := by simp [h.len]
    rw [hlen]
    unfold Cfg.target Cfg.perLayer at hb
    have hb' : c.numLayers * (c.numSenders * c.numStreams) * c.blocksPerStream ≤
        natSum (s.layers.map fun L => natSum L.sent) * c.blocksPerStream := by
      calc c.numLayers * (c.numSenders * c.numStreams) * c.blocksPerStream
          = c.numSenders * c.numStreams * c.blocksPerStream * c.numLayers := by
            rw [Nat.mul_comm c.numLayers, Nat.mul_right_comm]
        _ ≤ c.blocksPerStream * natSum (s.layers.map fun L => natSum L.sent) := hb
        _ = _ := Nat.mul_comm _ _
    exact Nat.le_of_mul_le_mul_right hb' hwf.blocks
  have hfullL := all_eq_of_natSum_ge hle hsum _ (List.mem_map.mpr ⟨L, hL, rfl⟩)
  have hLinv := h.layers L hL
  rw [fullB_iff]
  exact all_eq_of_natSum_ge hLinv.sentLe (by rw [hLinv.sentLen]; omega)

theorem LInv.copyDone {c : Cfg} {L : Layer} (h : LInv c L) : LInv c L.copyDone :=
  ⟨h.sentLen, h.sentLe, h.entry, h.noEntry, h.disp, by simp; have := h.pend; omega⟩

/-- The lifecycle after the callback, field by field. -/
theorem callbackLife_fields (c : Cfg) (l : Lifecycle) (ok : Bool) (n : Nat) :
    (callbackLife c l ok n).inFlight = l.inFlight - 1 ∧
    (callbackLife c l ok n).statusOk = (if ok then l.statusOk else false) ∧
    (callbackLife c l ok n).draining =
      (if ok then (if n = c.numLayers ∧ l.draining = false then true else l.draining) else true) := by
  unfold callbackLife
  cases ok
  · simp only [Bool.false_eq_true, ↓reduceIte, eo_inFlight, eo_statusOk, eo_draining, fl_inFlight,
      fl_false_statusOk, fl_draining, and_self]
  · simp only [↓reduceIte]
    by_cases hc : n = c.numLayers ∧ l.draining = false
    · simp only [hc, ↓reduceIte, eo_inFlight, eo_statusOk, eo_draining, fl_inFlight,
        fl_true_statusOk, fl_draining, and_self]
    · simp only [hc, ↓reduceIte, eo_inFlight, eo_statusOk, eo_draining, and_self]

theorem h2dDone_inv {c : Cfg} {s s' : S} {l : Nat} {ok : Bool} (h : Inv c s)
    (hs : h2dDoneStep c s l ok = some s') : Inv c s' := by
  unfold h2dDoneStep at hs
  split at hs
  · cases hs
  rename_i L hL
  split at hs
  · cases hs
  rename_i hpend
  cases hs
  have hLinv := h.layers L (getElem?_mem hL)
  have keyp := natSum_map_set Layer.pending (i := l) hL (x := L.copyDone)
  have keyd := natSum_map_set Layer.dispatched (i := l) hL (x := L.copyDone)
  have keys := natSum_map_set (fun L : Layer => natSum L.sent) (i := l) hL (x := L.copyDone)
  simp only [Layer.copyDone_pending, Layer.copyDone_dispatched, Layer.copyDone_sent] at keyp keyd keys
  have hmem : ∀ M ∈ s.layers.set l L.copyDone, LInv c M := by
    intro M hM
    rcases mem_set_cases hM with rfl | hM
    · exact hLinv.copyDone
    · exact h.layers M hM
  have hlen : (s.layers.set l L.copyDone).length = c.numLayers := by simp [h.len]
  have hin := h.inFlight
  have hinF : 0 < s.life.inFlight := by
    rw [hin]
    have := le_natSum_of_mem (List.mem_map.mpr ⟨L, getElem?_mem hL, rfl⟩ :
      L.pending ∈ s.layers.map Layer.pending)
    omega
  have hblocks : s.blocks = c.blocksPerStream *
      natSum ((s.layers.set l L.copyDone).map fun L => natSum L.sent) := by
    rw [h.blocks]; congr 1; omega
  have hdisp_le := natSum_dispatched_le h.len h.layers
  obtain ⟨hf_in, hf_ok, hf_dr⟩ :=
    callbackLife_fields c s.life ok (if ok then s.completedLayers + 1 else s.completedLayers)
  have hcons : (callbackLife c s.life ok
      (if ok then s.completedLayers + 1 else s.completedLayers)).Consistent := by
    unfold callbackLife
    cases ok
    · simp only [Bool.false_eq_true, ↓reduceIte]
      exact Lifecycle.endOpLocked_consistent (Lifecycle.finishLocked_consistent false h.life)
    · simp only [↓reduceIte]
      split
      · exact Lifecycle.endOpLocked_consistent (Lifecycle.finishLocked_consistent true h.life)
      · exact Lifecycle.endOpLocked_consistent h.life
  refine ⟨hlen, hmem, hblocks, hcons, ?_, ?_, ?_, ?_⟩
  · intro hf
    rw [hf_ok] at hf
    rw [hf_dr]
    cases ok
    · rfl
    · simp only [↓reduceIte] at hf ⊢
      split
      · rfl
      · exact h.failed hf
  · show (callbackLife c s.life ok _).inFlight = natSum ((s.layers.set l L.copyDone).map Layer.pending)
    rw [hf_in]; omega
  · intro hok
    rw [hf_ok] at hok
    simp only [hf_in]
    cases ok
    · cases hok
    · simp only [↓reduceIte] at hok ⊢
      have := h.completed hok
      omega
  · intro hdr hok M hM
    rw [hf_ok] at hok
    rw [hf_dr] at hdr
    cases ok
    · cases hok
    · simp only [↓reduceIte] at hok hdr
      have hc := h.completed hok
      split at hdr
      · rename_i hcomp
        -- the success finish: every copy had completed, this was the last op
        have hsum : c.numLayers ≤ natSum ((s.layers.set l L.copyDone).map Layer.dispatched) := by
          omega
        have hall := all_dispatched_of_sum hlen hmem hsum
        have hz : natSum ((s.layers.set l L.copyDone).map Layer.pending) = 0 := by omega
        exact ⟨hall M hM, all_pending_zero hz M hM⟩
      · -- already draining with OK status: the invariant said all copies done,
        -- which contradicts a pending copy on `L`
        rename_i hncomp
        have := h.fin hdr hok L (getElem?_mem hL)
        omega

theorem publish_inv {c : Cfg} (hwf : c.WF) {s s' : S} (h : Inv c s)
    (hs : publishStep c s = some s') : Inv c s' := by
  unfold publishStep at hs
  split at hs
  · cases hs
  rename_i hdr
  simp only [Bool.not_eq_true] at hdr
  split at hs
  · rename_i hcond
    cases hs
    simp only [Bool.and_eq_true, Bool.or_eq_true, decide_eq_true_eq, List.all_eq_true] at hcond
    obtain ⟨hready, hpz⟩ := hcond
    have hz : s.life.inFlight = 0 := by
      rw [h.inFlight]
      have : ∀ n ∈ s.layers.map Layer.pending, n ≤ 0 := by
        intro n hn
        obtain ⟨M, hM, rfl⟩ := List.mem_map.mp hn
        exact Nat.le_of_eq (hpz M hM)
      have := natSum_le_length_mul this
      simpa using this
    have hok : s.life.statusOk = true := by
      cases hok : s.life.statusOk
      · have := h.failed hok; simp [hdr] at this
      · rfl
    have hall : ∀ M ∈ s.layers, M.dispatched = 1 := by
      intro M hM
      rcases hready with hnet | hcomp
      · have hfull := all_full_of_blocks hwf h (by simpa [networkCompleted] using hnet) M hM
        rw [(h.layers M hM).disp, hfull]; rfl
      · exact all_dispatched_of_sum h.len h.layers (by have := h.completed hok; omega) M hM
    refine ⟨h.len, h.layers, h.blocks, Lifecycle.finishLocked_consistent true h.life, ?_, ?_, ?_, ?_⟩
    · intro hf; rw [fl_true_statusOk] at hf; simp [hok] at hf
    · rw [fl_inFlight]; exact h.inFlight
    · intro _; rw [fl_inFlight]; exact h.completed hok
    · intro _ _ M hM
      exact ⟨hall M hM, hpz M hM⟩
  · cases hs

theorem cancel_inv {c : Cfg} {s s' : S} (h : Inv c s) (hs : cancelStep s = some s') : Inv c s' := by
  unfold cancelStep at hs
  split at hs
  · cases hs
  cases hs
  refine ⟨h.len, h.layers, h.blocks, Lifecycle.finishLocked_consistent false h.life, ?_, ?_, ?_, ?_⟩
  · intro _; exact fl_draining false s.life
  · rw [fl_inFlight]; exact h.inFlight
  · intro hok; rw [fl_false_statusOk] at hok; cases hok
  · intro _ hok; rw [fl_false_statusOk] at hok; cases hok

theorem step_inv {c : Cfg} (hwf : c.WF) (hh : c.honest = true) {s s' : S} {e : Ev}
    (h : Inv c s) (hs : step c s e = some s') : Inv c s' := by
  cases e with
  | stream l i => exact stream_inv hwf hh h hs
  | h2dDone l ok => exact h2dDone_inv h hs
  | publish => exact publish_inv hwf h hs
  | cancel => exact cancel_inv h hs

theorem inv_safe {c : Cfg} (hwf : c.WF) {s : S} (h : Inv c s) : Safe c s := by
  refine ⟨fun L hL => (h.layers L hL).disp_le_one, ?_, ?_⟩
  · intro hnet L hL
    have hfull := all_full_of_blocks hwf h (by simpa [networkCompleted] using hnet) L hL
    rw [(h.layers L hL).disp, hfull]
    exact Nat.le_refl _
  · intro hp
    simp only [published, Bool.and_eq_true] at hp
    exact h.fin (h.life.done_draining hp.1) hp.2

/-- **Main theorem.** With honest senders (A4), on either completion contract
and for any well-formed instance, every reachable state dispatches each layer
at most once, reaches its block target only after every layer was dispatched,
and reports success only after every layer's single copy has completed. -/
theorem reachable_safe {c : Cfg} (hwf : c.WF) (hh : c.honest = true) {s : S}
    (hr : (sys c).Reachable s) : Safe c s :=
  inv_safe hwf ((sys c).reachable_induction (inv_init c hwf) (fun _ _ _ h hs => step_inv hwf hh h hs) hr)

/-! ## Configurations and event lists for replay and search -/

def cfgChunk (numLayers numSenders numStreams : Nat) (honest : Bool) : Cfg :=
  { numLayers, numSenders, numStreams, blocksPerStream := 1, declared := false, honest }

def cfgDeclared (numLayers numSenders numStreams : Nat) (honest : Bool) : Cfg :=
  { numLayers, numSenders, numStreams, blocksPerStream := 1, declared := true, honest }

def events (c : Cfg) : List Ev :=
  ((List.range c.numLayers).flatMap fun l =>
    (List.range c.numSenders).map fun s => Ev.stream l s) ++
  ((List.range c.numLayers).flatMap fun l => [Ev.h2dDone l true, Ev.h2dDone l false]) ++
  [.publish, .cancel]

/-- Bounded search for a `Safe` violation on configuration `c`. -/
def search (c : Cfg) (fuel : Nat) : ModelCheck.Result Ev :=
  ModelCheck.check (sys c) (events c) (violates c) fuel

def foundCounterexample (c : Cfg) (fuel : Nat) : Bool :=
  match search c fuel with
  | .counterexample _ => true
  | _ => false

/-- Projection used by the traces: the session outcome and the per-layer
dispatch and pending counts. -/
structure View where
  draining : Bool
  done : Bool
  statusOk : Bool
  dispatched : List Nat
  pending : List Nat
  deriving Repr, DecidableEq

def view (s : S) : View :=
  ⟨s.life.draining, s.life.done, s.life.statusOk,
   s.layers.map (·.dispatched), s.layers.map (·.pending)⟩

/-! ### Honest senders: exhaustive on small instances -/

#guard search (cfgChunk 2 1 2 true) 40 = .safe
#guard search (cfgChunk 3 1 1 true) 40 = .safe
#guard search (cfgChunk 2 1 3 true) 40 = .safe
#guard search (cfgDeclared 2 2 1 true) 40 = .safe
#guard search (cfgDeclared 2 1 2 true) 40 = .safe
#guard search (cfgDeclared 2 2 2 true) 60 = .safe

/-- Honest run, chunk-count contract, two layers of two streams: both layers
dispatched once, the network completes exactly when the last stream lands,
the table is retired, and the second callback settles the receive with OK. -/
theorem trace_honest_chunk :
    ((sys (cfgChunk 2 1 2 true)).run
      [.stream 0 0, .stream 0 0, .stream 1 0, .stream 1 0, .h2dDone 0 true, .h2dDone 1 true]).map
      (fun s => (view s, s.blocks, s.layers.map (·.entry))) =
    some (⟨true, true, true, [1, 1], [0, 0]⟩, 4, [none, none]) := by
  decide

/-- Honest run, sender-declared contract, two senders: a layer is dispatched
only when both senders' streams have landed. -/
theorem trace_honest_declared :
    ((sys (cfgDeclared 2 2 1 true)).run [.stream 0 0, .stream 1 0]).map
      (fun s => s.layers.map (·.dispatched)) = some [0, 0] ∧
    ((sys (cfgDeclared 2 2 1 true)).run
      [.stream 0 0, .stream 1 0, .stream 0 1, .stream 1 1, .h2dDone 0 true, .h2dDone 1 true]).map
      view = some ⟨true, true, true, [1, 1], [0, 0]⟩ := by
  decide

/-- A failed copy fails the receive once every op has returned; the poll never
publishes it. -/
theorem trace_failed_copy :
    ((sys (cfgChunk 2 1 1 true)).run
      [.stream 0 0, .stream 1 0, .h2dDone 0 false, .h2dDone 1 true]).map view =
    some ⟨true, true, false, [1, 1], [0, 0]⟩ ∧
    (sys (cfgChunk 2 1 1 true)).run
      [.stream 0 0, .stream 1 0, .h2dDone 0 false, .publish] = none := by
  decide

/-- **Out of contract: chunk-count with two senders.** `Cfg.WF.chunkSingle`
excludes this instance; the trace shows why. `expected_chunks` is the stream
count one sender declared (`header.reserved`), so sender 1's single stream
completes each layer on its own, the table is retired once sender 1 has
covered both layers, and sender 0's first (honest) stream for layer 0 then
starts a fresh entry and dispatches layer 0 a second time. -/
theorem trace_chunk_two_senders :
    ((sys (cfgChunk 2 2 1 true)).run [.stream 1 1, .stream 0 1, .stream 0 0]).map
      (fun s => s.layers.map (·.dispatched)) = some [2, 1] := by
  decide

/-! ### Without A4: one extra stream -/

/-- **Chunk-count contract, before retirement.** Layer 0 (one declared stream)
lands twice; layer 1 never arrives. The duplicate is absorbed
(`completed_chunks = 2 ≠ 1`, no second dispatch, no error) but still reported
through `OnBlockShardsReceived`, so `network_completed_` is reached with
layer 1's blocks never received. Once layer 0's copy lands, `IsReadyToComplete`
is true, the poll's `Finish()` settles at once (`in_flight_ == 0`) and the
receive is published in `done_recving_` with layer 1 never copied. -/
theorem trace_dup_chunk_publishes_missing_layer :
    ((sys (cfgChunk 2 1 1 false)).run
      [.stream 0 0, .stream 0 0, .h2dDone 0 true, .publish]).map
      (fun s => (published s, networkCompleted (cfgChunk 2 1 1 false) s,
                 s.layers.map (·.dispatched))) =
    some (true, true, [1, 0]) := by
  decide

/-- **Either contract, after retirement.** Both layers land and the table
entries are erased (`bt.cc:764-778`). An extra stream for layer 0 then
creates a fresh entry whose first stream completes it: `OnLayerReceived`
fires again and a second copy of layer 0 is issued while the first may still
run (`dispatched = [2, 1]`). The session is not fooled about settlement —
`in_flight_` holds `done_` off until every copy has returned — but
`num_completed_layers_` reaches `num_layers()` after the two layer-0
callbacks, so the receive starts draining with layer 1's copy still pending,
and settles with OK once it returns. -/
theorem trace_dup_after_retirement :
    ((sys (cfgChunk 2 1 1 false)).run
      [.stream 0 0, .stream 1 0, .stream 0 0, .h2dDone 0 true, .h2dDone 0 true]).map view =
    some ⟨true, false, true, [2, 1], [0, 1]⟩ ∧
    ((sys (cfgChunk 2 1 1 false)).run
      [.stream 0 0, .stream 1 0, .stream 0 0, .h2dDone 0 true, .h2dDone 0 true,
       .h2dDone 1 true]).map view =
    some ⟨true, true, true, [2, 1], [0, 0]⟩ ∧
    ((sys (cfgDeclared 2 1 1 false)).run
      [.stream 0 0, .stream 1 0, .stream 0 0, .h2dDone 0 true, .h2dDone 0 true,
       .h2dDone 1 true]).map view =
    some ⟨true, true, true, [2, 1], [0, 0]⟩ := by
  decide

/-- The redundant copy can also fail the receive: `FinishLocked` records the
first error even when already draining (`recv.cc:359-363`), so a duplicate
copy that fails after the honest copies succeeded turns a complete transfer
into `failed_recving`. -/
theorem trace_dup_copy_fails_late :
    ((sys (cfgChunk 2 1 1 false)).run
      [.stream 0 0, .stream 1 0, .stream 0 0, .h2dDone 0 true, .h2dDone 1 true,
       .h2dDone 0 false]).map view =
    some ⟨true, true, false, [2, 1], [0, 0]⟩ := by
  decide

/-- **Sender-declared contract, before retirement.** The same duplicate is
rejected (`landed > declared`, `bt.cc:732-736`), the push fails and the
receive is finished with an error: loud, not silent. -/
theorem trace_dup_declared_rejected :
    ((sys (cfgDeclared 2 1 1 false)).run [.stream 0 0, .stream 0 0]).map view =
      some ⟨true, false, false, [1, 0], [1, 0]⟩ ∧
    (sys (cfgDeclared 2 1 1 false)).run [.stream 0 0, .stream 0 0, .stream 1 0] = none := by
  decide

#guard foundCounterexample (cfgChunk 2 1 1 false) 6
#guard foundCounterexample (cfgDeclared 2 1 1 false) 6

/-! ### Candidate hardening

Two small changes close every trace above without touching the honest
behaviour: (1) the chunk-count contract rejects a stream beyond the declared
count, as the other two contracts already do (`bt.cc:704-708, 732-736`);
(2) `ExecuteLayerH2d` keeps a per-layer once-latch of its own, so a dispatch
after the transport retired its entries is a no-op. `stepHardened` is `step`
with exactly those two edits. The dishonest state space stays infinite (after
retirement a fresh entry's first stream is within the declared count and is
accepted, so the block count is unbounded), so the searches below are bounded:
no violation within the depth, where the unhardened step finds one at depth 4. -/

def completePushHardened (c : Cfg) (p : Progress) (sender : Nat) : Progress × Bool × Bool :=
  if c.declared then completePush c p sender
  else
    let completed := p.completedChunks + 1
    let complete := decide (completed = c.numStreams)
    ({ p with completedChunks := completed, called := p.called || complete },
     complete && !p.called, decide (c.numStreams < completed))

def streamStepHardened (c : Cfg) (s : S) (l sender : Nat) : Option S :=
  match s.life.beginOp, s.layers[l]? with
  | some life₁, some L =>
    if c.numSenders ≤ sender then none
    else if c.honest && c.numStreams ≤ L.sent.getD sender 0 then none
    else
      match completePushHardened c (L.entry.getD (freshProgress c)) sender with
      | (p', fire, reject) =>
        let sent' := L.sent.set sender (L.sent.getD sender 0 + 1)
        if reject then
          some { s with layers := s.layers.set l { L with entry := some p', sent := sent' },
                        life := streamLife life₁ false true }
        else
          -- session-side once-latch: a second `OnLayerReceived` issues no copy
          let fire := fire && decide (L.dispatched = 0)
          some { s with layers := retire (s.layers.set l (nextLayer L p' sent' fire)),
                        life := streamLife life₁ fire false,
                        blocks := s.blocks + c.blocksPerStream }
  | _, _ => none

def stepHardened (c : Cfg) (s : S) : Ev → Option S
  | .stream l sender => streamStepHardened c s l sender
  | e => step c s e

def searchHardened (c : Cfg) (fuel : Nat) : ModelCheck.Result Ev :=
  ModelCheck.check ⟨init c, stepHardened c⟩ (events c) (violates c) fuel

#guard searchHardened (cfgChunk 2 1 1 false) 12 = .outOfFuel
#guard searchHardened (cfgChunk 2 1 2 false) 12 = .outOfFuel
#guard searchHardened (cfgDeclared 2 1 1 false) 12 = .outOfFuel
#guard searchHardened (cfgDeclared 2 2 1 false) 12 = .outOfFuel

/-- The hardened step still runs the honest traces to the same end states. -/
theorem trace_hardened_honest :
    ((⟨init (cfgChunk 2 1 2 true), stepHardened (cfgChunk 2 1 2 true)⟩ : System S Ev).run
      [.stream 0 0, .stream 0 0, .stream 1 0, .stream 1 0, .h2dDone 0 true, .h2dDone 1 true]).map
      view = some ⟨true, true, true, [1, 1], [0, 0]⟩ := by
  decide

/-- Under the hardening the pre-retirement duplicate fails the receive loudly
and the post-retirement duplicate issues no second copy. -/
theorem trace_hardened_dups :
    ((⟨init (cfgChunk 2 1 1 false), stepHardened (cfgChunk 2 1 1 false)⟩ : System S Ev).run
      [.stream 0 0, .stream 0 0]).map view = some ⟨true, false, false, [1, 0], [1, 0]⟩ ∧
    ((⟨init (cfgChunk 2 1 1 false), stepHardened (cfgChunk 2 1 1 false)⟩ : System S Ev).run
      [.stream 0 0, .stream 1 0, .stream 0 0, .h2dDone 0 true]).map view =
    some ⟨false, false, true, [1, 1], [0, 1]⟩ := by
  decide

end TpuSyncVerify.Transfer.PrefillDecode.Transport
