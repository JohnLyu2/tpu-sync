# Upstream re-checks

One row per upstream sync or citation re-audit of the Lean corpus. The
procedure is in [README.md](../README.md) §"Maintenance after an upstream
sync"; the model-side consequences of each sync are described in the
preamble of each affected module. The current citation baseline is stated
once in README.md §Status.

## Prefill-to-decode transfer (`TpuSyncVerify/Transfer/`)

| Date | From → to | What changed in the cited prefill-to-decode code | What was done |
|---|---|---|---|
| 2026-10-06 | `01ffa3d` → `50b0774` (44 upstream commits) | **One behavioural change.** `4efb0dd`: a failed incoming push now runs `DeferUnregisterOnSettle(); Finish(status)` before `EndRecvOp()` (`mgr.cc:239-242`, `bt.cc:376-381`) instead of leaving the session to its deadline — already a trace of the model (`cancel` then `pushEnd`), now with its own C++ test (`FailedIncomingPushImmediatelyFailsSessionAndReleasesStagingBeforeDeadline`). **Additive only:** `completed_at_` set beside every `done_ = true` (`a58a357`); `CompleteReadRaw` became a wrapper over `CompleteReadWithDetails`, poll loop unchanged (`mgr.cc:962-994`); per-read socket timeouts on the decode/receiver side in `HandleIncomingPush`, env-gated and off by default (`e7c933f`); prefill/sender-side handshake-ack and final-ack read timeouts in `tpu_sync/transport/lib/socket_transport_adapter.{h,cc}` (`61b6c76`); `BlockTransport::AsyncPush` returns a future and `SyncPush` is removed (`d73d68b`); control-plane post/poll API refactors: `50fa652` adds only `layer_host_addrs` plumbing on the pull request (`req_spec.layer_host_addrs = base_->LayerHostAddrs(uuid_)`, `recv.cc:474`; `base_->SetRemoteLayerAddrs` in `HandlePullStream`, `mgr.cc:1475`; `base_->ClearRemoteLayerAddrs` when a settled send is swept, `mgr.cc:934`), while `4e9f0a5` and `c4ca33c` touch neither the session classes, the manager nor `block_transport.*`. **Unchanged:** Receive A4's ordering (`bt.cc:559-561`, `:601-615`), `StartRead` admission (`DISABLED_SickPeerStarvesStagingSlotsForHealthyPeer` still disabled), `IsReadyToComplete` and `AllH2dDoneLocked`. | All `file:line` citations in the Lean modules and this file re-pinned with `tools/repin_citations.py`; `lake build` clean. |
| 2026-10-09 | `50b0774` (same pin; citation re-audit) | No upstream change. Four manual passes compared every `file:line`, C++ identifier, test name/range and Lean identifier in `prefill_decode.md` and all 10 `.lean` module docstrings with `50b0774` and with the Lean statements they describe. | ~50 corrections (non-existent identifiers such as `SettleLocked()` / `failed_sending`, stale test ranges, trace descriptions that did not match the theorem tuple, 22 tightened `.cc`/`.h` ranges); `lake build` clean. Details in the notes journal. |
