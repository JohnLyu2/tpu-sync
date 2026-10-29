# Bug-hunt reproduction status (graduated)

[SUPERSEDED → ../../findings/README.md] (2026-10-29) All reproduction evidence
levels, patch validation results, and test-run commit history live canonically
in `findings/README.md` (§Summary, §"Fix validation", §History), while Lean
module inventories and build instructions live in
`tpu_sync/formal_verification/README.md`. Kept as a frozen stub to preserve the
2026-10-06 correction trail linked from `../journal/2026-10/`.

## Correction trail

[SUPERSEDED → ../journal/2026-10/2026-10-06-upstream-50b0774-merge-and-citation-repin.md]
(2026-10-06) The 2026-10-05 table named bazel targets `bughunt_f1_test` /
`bughunt_f2_test` and a test `ShapeB_DeadlineFreesStagingWhilePullInFlight` —
none exist (shape B has no C++ test); put `raiden_controller.cc` at
`tpu_sync/`; misstated the module count and Lean version; and cited
`ReadRemote.bug_trace_B_violates`, whose real name is
`ReadRemote.shipping_inFlight`. Old text:
`git show aaa9be1:notes/empirical/bughunt-repro-status-at-01ffa3d.md`.
