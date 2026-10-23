# `ReadRemote`: destination-side settle protocol

`TpuSyncVerify/Controller/ReadRemote.lean` models the destination half of
`RaidenController::ReadRemote` (`tpu_sync/core/controller/raiden_controller.cc`). It
shows that a remote read can keep DMA-ing into the caller's destination blocks
after the caller has been told the read failed.

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
| `shipping` | issues `TransferBuffers(src_buffers, dst_buffers, staging_buffers)` in `RaidenController::PullAndRelease` unconditionally | `std::thread([state, deadline = RemoteReadDeadline()] { ... })` in `RaidenController::ReadRemote` calls `state->Settle(DeadlineExceededError(...))` |
| `checkSettledBeforePull` | candidate fix: skips the pull if already settled | settles |
| `deferSettleWhilePullInFlight` | as above | does not settle while a pull is in flight; the pull's completion settles — what the sibling `WriteRemote` path already does (`kv_cache_store_service.cc` `DeadlineLoop`) |

## Property

`NoWriteAfterRelease`: the caller never reuses the destination blocks while a
pull into them is in flight (issued and not done). The caller is entitled to
this by the `if (to_hbm)` comment in `RaidenController::PullAndRelease`
(`"KVCacheStore returns them to the pool once the read settles, success or failure"`).

## Results

| Theorem | Result |
|---|---|
| `shipping_counterexample` | `[deadline, callerReuse, acquireReply true]` — **shape A**: the deadline settles, the caller takes its blocks back, the late acquire reply issues the pull into them anyway |
| `shipping_inFlight` | `[acquireReply true, deadline, callerReuse]` — **shape B**: the pull is issued, the deadline settles under it, the caller reuses the blocks under the DMA |
| `naive_fix_closes_lateIssue`, `naive_fix_counterexample` | the naive fix closes A; its first counterexample is B |
| `deferred_settle_is_safe` | `.safe`: deferring the deadline's settle while a pull is in flight has no violation anywhere in the state space |
| `deferred_settle_settles` | the deferred design still settles once the pull resolves |
| `trace_full_success` | `[acquireReply true, pullDone, callerReuse]` — happy path / completed pull settles and allows safe caller reuse (`violates = false`) across all three `Impl`s |
| `trace_acquire_fails_fast` | `[acquireReply false, callerReuse]` — acquire RPC failure settles immediately without issuing a pull (`pullIssued = false`, `violates = false`) |
| `trace_teardown_before_acquire` | `[shutdown, acquireReply true, callerReuse]` — controller torn down before acquire reply settles with `Cancelled` without issuing a pull (`pullIssued = false`, `violates = false`) |
| `trace_teardown_during_pull` | `[acquireReply true, shutdown, pullDone, callerReuse]` — controller torn down during pull still completes and settles cleanly (`pullDone = true`, `violates = false`) |

Shape A is deterministic (the acquire reply can be delayed until after the
deadline); shape B is the case the deadline exists for and has no
deterministic test. The deferred-settle design's cost
is that a hung pull holds the caller until it resolves; a complete fix needs
cancellation, or settle-with-error while the blocks stay quarantined.

## Source map & test suite correspondence (`tpu-raiden` C++ → Lean)

The `ReadRemote` implementation in `tpu_sync/core/controller/raiden_controller.cc`
(`ctrl.cc`), its unit tests in `tpu_sync/core/controller/raiden_controller_test.cc`
(`ctrl_test.cc`, `bazel test //tpu_sync/core/controller:raiden_controller_test`)
map to `ReadRemote.lean` as follows (line ranges resolved by
`tools/resolve_anchors.py`); shape A is
`[.deadline, .callerReuse, .acquireReply true]`, i.e. `shipping_lateIssue`,
`shipping_counterexample`, `naive_fix_closes_lateIssue`:

<!-- source-map:begin -->
| File | Symbol / anchor | Lines | Lean theorem | Notes |
|---|---|---|---|---|
| `ctrl.cc` | `RaidenController::ReadRemote` | `:953-1148` | `sys` | Destination-side lease acquire, callback registration, and deadline thread |
| `ctrl.cc` | `RaidenController::ReadRemote` (`std::thread([state, deadline = RemoteReadDeadline()]`) | `:1125-1145` | `Ev.deadline` | Detached deadline thread calling `state->Settle(DeadlineExceededError(...))` |
| `ctrl.cc` | `RaidenController::PullAndRelease` | `:1150-1252` | `Ev.acquireReply`, `Ev.pullDone` | Builds buffers, issues `TransferBuffers`, releases lease and settles in `transfer.OnReady` |
| `ctrl.cc` | `RaidenController::PullAndRelease` (`// remote host src -> local host staging -> local device dst.` .. `// the read's only product.`) | `:1175-1179` | `NoWriteAfterRelease` | Comment stating host staging is returned once the read settles |
| `ctrl.cc` | `RaidenController::PullAndRelease` (`tsl::Future<> transfer =`) | `:1202-1203` | `pullIssued` | Unconditional `TransferBuffers(src_buffers, dst_buffers, staging_buffers)` call |
| `ctrl_test.cc` | `ReadRemotePullTest.FullSuccessPathUsesAuthoritativeIdsAndSrcEndpoints` | `:634-661` | `trace_full_success` | Acquire succeeds, pull issues & completes, lease released, promise settles before caller reuse |
| `ctrl_test.cc` | `ReadRemotePullTest.HbmModeBuildsStagingPlusDeviceDst` | `:663-686` | `trace_full_success` | Same settle lifecycle; C++ test also checks staging + device destination buffer construction |
| `ctrl_test.cc` | `ReadRemotePullTest.HostModeBuildsDramDstWithNoStaging` | `:688-703` | `trace_full_success` | Same settle lifecycle; C++ test checks DRAM-only destination buffer construction |
| `ctrl_test.cc` | `ReadRemotePullTest.DeviceIdSizeMismatchRejectedBeforeAcquire` | `:705-724` | Pre-RPC validation | Synchronous argument check before `AcquireReadLease`, prior to the state machine's initial state |
| `ctrl_test.cc` | `ReadRemotePullTest.EmptyControllerAddressRejectedBeforeAcquire` | `:766-783` | Pre-RPC validation | Synchronous argument check before `AcquireReadLease` |
| `ctrl_test.cc` | `ReadRemotePullTest.EmptyHashesRejected` | `:785-795` | Pre-RPC validation | Synchronous argument check before `AcquireReadLease` |
| `ctrl_test.cc` | `ReadRemotePullTest.PeerChurnDoesNotGrowTheStubCacheWithoutBound` | `:731-761` | gRPC stub cache | Channel LRU sizing |
| `ctrl_test.cc` | `ReadRemotePullTest.AcquireNotFoundFailsFastWithoutTransfer` | `:797-815` | `trace_acquire_fails_fast` | Source returns `NOT_FOUND` (`acquireReply false`); settles immediately with `pullIssued = false` |
| `ctrl_test.cc` | `ReadRemotePullTest.TransferFailureStillReleasesTheLease` | `:817-833` | `trace_full_success` | Pull future resolves with error (`pullDone`), releases lease, and settles |
| `ctrl_test.cc` | `ReadRemotePullTest.RevokedVerdictFailsTheRead` | `:835-855` | `trace_full_success` | Pull completes (`pullDone`), lease release returns `REVOKED`, settles with `FailedPrecondition` |
| `ctrl_test.cc` | `ReadRemotePullTest.ControllerTeardownMidReadIsSafe` | `:857-882` | `trace_teardown_before_acquire`, `trace_teardown_during_pull` | Controller destroyed either before `acquireReply` (skips pull, settles `Cancelled`) or during `pullInFlight` (finishes pull via shared state and settles) |
<!-- source-map:end -->
