# Bug-hunt reproduction status

Canonical: `verification/findings/README.md` §Summary (evidence level per
finding), §"Fix validation" (what the candidate patch changes), §History
(which commit each test run was on). This note holds the stamp and the
correction trail only.

**Verified against:** tpu-sync `b68161a`, re-run on `d16701e`
(reproducers `verification/findings/kv_cache_store_pin_race_test.cc`,
`raiden_controller_bughunt_test.cc`, wired in by `build_targets.patch`); the
cited code is unchanged at `01ffa3d` and `50b0774`; tests not re-run since
`d16701e`.
**Last verified:** 2026-09-24 (test runs), 2026-10-06 (code diff)

[EMP] F1, F2 (shape A) and F4 fail deterministically on the unmodified tree;
F3 is a reading-level finding (data race, no test); F2 shape B is Lean-only
(`ReadRemote.shipping_inFlight`). With `candidate_fixes.patch` applied the same
tests pass, except that the F2 fix is the naive one and closes shape A only.

[EMP] `lake build` of `verification/` is clean: 14 modules, no `sorry`, no
extra axioms, `leanprover/lean4:v4.34.0` (`verification/README.md` §Building).

## Correction trail

[SUPERSEDED → journal/2026-10/2026-10-06-upstream-50b0774-merge-and-citation-repin.md]
(2026-10-06) The 2026-10-05 table named bazel targets `bughunt_f1_test` /
`bughunt_f2_test` and a test `ShapeB_DeadlineFreesStagingWhilePullInFlight` —
none exist (shape B has no C++ test); put `raiden_controller.cc` at
`tpu_sync/`; said "12 modules under Lean v4.29.0"; and cited
`ReadRemote.bug_trace_B_violates`, whose real name is
`ReadRemote.shipping_inFlight`. Old text:
`git show aaa9be1:notes/empirical/bughunt-repro-status-at-01ffa3d.md`.

## See also

- ../durable/controller-read-remote-and-kv-store-pinning-concurrency-traps.md
