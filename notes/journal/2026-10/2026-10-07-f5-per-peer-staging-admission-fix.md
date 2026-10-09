# F5: per-peer staging admission at `StartRead` — confirmed, fixed, documented

Session `f92271cf`, continued from 2026-10-06. Code read at tpu-sync `50b0774`;
upstream `main` checked at `ebcc7af`.

Canonical: `verification/findings/README.md` §F5 (evidence, mechanism, fix,
validation output), `verification/docs/transfer/prefill_decode.md` §3 (knob ↔
Lean policy) and §Outcome, `verification/findings/per_peer_staging_admission.patch`.
Commit `e30ccc2`. This entry holds only what those do not say.

## Why this was the next upstream contribution

[OBS 2026-10-07] Of the open items, F5 is the only one where the owners have
already written the acceptance test and said in a commit message that the fix
is wanted (`63da027`: "the written-down acceptance criteria for the per-peer
admission work"). Everything we add is therefore a *mechanism* plus a *proof of
what it guarantees*, not an argument that a problem exists. That is the cheapest
kind of upstream change to land, and the Lean model
(`PeerIsolation.reachable_quota_admits_healthy`) is the part nobody else has.

[OBS 2026-10-07] The owners' own test fails on unmodified `50b0774` in 48 ms
with `--gtest_also_run_disabled_tests` (two failures, both the healthy-peer
assertions). Our reading: the test was parked not because it is flaky but
because it is *correct* and nothing makes it pass yet. It needed no edits to
become the regression test for the fix; only the `DISABLED_` prefix and a cap.

## What was non-trivial in the fix (so nobody simplifies it away)

[FACT] The per-peer charge must be released in `StagingBlockAllocator::Allocation`'s
RAII release path (`Reset()` → `ReleaseSlot` / `ReleaseDynamicBlocks`) and
under the same `mu_` acquisition that frees the slot. Releasing it anywhere
else (for example in `TransferReceiveSession::ReleaseStagingLocked` /
`FinishLocked` / `EndRecvOpLocked`) would let the
count and the pool disagree across the window between the two, and the
move-constructor/assignment of `Allocation` must transfer the key or a moved-
from handle would double-release. The patch's `Allocation` carries `peer_key_`
for exactly this reason.

[FACT] The cap check runs *before* the free-slot check in `AcquireLocked`.
Otherwise a peer at cap with free slots available would still be admitted and
the reservation `numSlots − c` the theorem promises would not hold.

[FACT] Keyless acquisitions are exempt. The send side (`AcquireWithTimeout`
in `transfer_send_session.cc:249`) and the incoming-push lease
(`kv_cache_manager_with_transfer.cc:552`) call `Acquire` with no peer; if the
empty key were charged, every push from every producer would share one bucket
and a cap would throttle pushes fleet-wide — a regression the unit test
`NoCapConfiguredLeavesAdmissionUnchanged` does not cover (it only covers the
cap-unset case). Worth a third unit test if the owners ask for more coverage.

[OBS 2026-10-07] After `SilentProducer::DropClients()` the eight admitted
sessions settle within milliseconds (`socket closed during read` on the
handshake thread), not at the 4 s `kStarvationTimeoutS` deadline — the whole
re-enabled test runs in ~48 ms. So the final `free_slots() == free_before`
assertion is checked after a real drain, not after a 30 s timeout fallback.

## Tooling lessons

[OBS 2026-10-07] `git clang-format` cannot run from the sandbox (it writes a
temporary index under `.git/`, which is read-only there). Full-file
`clang-format --style=Google file | diff file -` and reading only one's own
hunks works; the upstream files are not fully clang-format-clean themselves
(include order, a one-line function), so a full-file diff is noisy by design.

[OBS 2026-10-07] Bazel `--test_output=errors` prints nothing for a passing
test, and `bazel-testlogs/.../test.log` is overwritten by the next run of the
same target. To keep verbatim evidence from the *shipped* patch, the last run
before writing it up has to be a verbose (`--test_output=all`, filtered) run of
that exact code. The first validation block in `findings/README.md` had mixed
two runs and carried non-verbatim count annotations; it was rewritten before
commit. Rule of thumb: paste only lines a reader could regenerate with the
command next to them.

[OBS 2026-10-07] The OSS test recipe (compiler flags, which targets are
hardware-only) is now `../../empirical/oss-bazel-test-recipe.md`.

## Open

[OPEN] Follow-ups to the mechanism — wait-at-cap instead of refuse, a
self-sizing share, and plumbing the knob through the constructors / Python
bindings — are parked in `../../loose-ends/parked.md` ("Per-peer staging admission
follow-ups"). Each would need its own theorem; the current proof is for
refuse-at-fixed-cap only.
