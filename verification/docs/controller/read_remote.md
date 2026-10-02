# `ReadRemote`: destination-side settle protocol

`TpuSyncVerify/Controller/ReadRemote.lean` models the destination half of
`RaidenController::ReadRemote` (`tpu_sync/core/controller/raiden_controller.cc`,
tpu-sync `01ffa3d`). It is the model behind finding **F2** in
`findings/README.md`: a remote read can keep DMA-ing into the caller's
destination blocks after the caller has been told the read failed.

## What is modelled

Seven booleans — `acquired`, `pullIssued`, `pullDone`, `settled`,
`deadlineFired`, `shutdown`, and the ghost `reused` (the caller has taken its
destination blocks back) — and five events: the acquire-lease reply (OK or
failed), controller shutdown, the deadline thread, pull completion, and the
caller reusing its blocks once the future has settled. Every event fires at
most once, so the reachable state space is finite and `ModelCheck.check`
exhausts it: `.safe` here is a proof, not a bound.

`Impl` selects the implementation of the acquire callback and the deadline:

| `Impl` | Acquire callback | Deadline |
|---|---|---|
| `shipping` | issues the pull unconditionally (`:1161-1162`) | settles (`:1084-1104`) |
| `checkSettledBeforePull` | skips the pull if already settled (`findings/candidate_fixes.patch`) | settles |
| `deferSettleWhilePullInFlight` | as above | does not settle while a pull is in flight; the pull's completion settles — what the sibling `WriteRemote` path already does (`kv_cache_store_service.cc` `DeadlineLoop`) |

## Property

`NoWriteAfterRelease`: the caller never reuses the destination blocks while a
pull into them is in flight (issued and not done). The caller is entitled to
this by the comment at `:1134-1138`.

## Results

| Theorem | Result |
|---|---|
| `shipping_counterexample` | `[deadline, callerReuse, acquireReply true]` — **shape A**: the deadline settles, the caller takes its blocks back, the late acquire reply issues the pull into them anyway |
| `shipping_inFlight` | `[acquireReply true, deadline, callerReuse]` — **shape B**: the pull is issued, the deadline settles under it, the caller reuses the blocks under the DMA |
| `naive_fix_closes_lateIssue`, `naive_fix_counterexample` | the naive fix closes A; its first counterexample is B |
| `deferred_settle_is_safe` | `.safe`: deferring the deadline's settle while a pull is in flight has no violation anywhere in the state space |
| `deferred_settle_settles` | the deferred design still settles once the pull resolves |

Shape A is confirmed on unmodified code by
`findings/raiden_controller_bughunt_test.cc`; shape B is the case the deadline
exists for and has no deterministic test. The deferred-settle design's cost
is that a hung pull holds the caller until it resolves; a complete fix needs
cancellation, or settle-with-error while the blocks stay quarantined.

## Status

| | |
|---|---|
| Citations | `01ffa3d`; the cited regions of `raiden_controller.cc` are identical to `b68161a`, where the finding was made |
| Tests in `findings/` | last run on `d16701e`; not re-run on `01ffa3d` |
| Patches in `findings/` | re-based; `git apply --check` clean at `01ffa3d` |
| Upstream fix | none known |
