# Upstream `2ed6f8f` sync: two findings closed, one tool defect found by audit

Session `f92271cf`, continued 2026-10-22. Code at tpu-sync `2ed6f8f`
(32 commits past `0ac16d1`), merge `3d2e822`, re-pin `91d9656`.

Canonical: `verification/docs/upstream_rechecks.md` (2026-10-22 row: what
changed in cited code, what was done), `findings/README.md`
§F1, §F7, §History, `verification/TpuSyncVerify/Transfer/Reshard/Receive.lean`
(`PushEndPolicy` docstring). This entry holds the interpretation.

## What the sync meant for the models

[OBS 2026-10-22] Both findings that upstream closed in this window are ones
the corpus had already *proposed the fix for*: F1's `b3ea4dc` is the
`candidate_fixes.patch` hunk in different spelling (same `LookupOptions`,
releases by span instead of by a collected list); F7's `fdeebcd` is
`Reshard/Receive.lean`'s `finishOnError` policy with the same regression
shape as `trace_r1_failed_incoming_push`. Reading: the "shipping vs. modelled
alternative" parameterisation pays off at sync time — the model's work on a
sync like this is a default flip, not a proof. Nothing in any `step` changed.

[FACT] After the flip, `Reshard/Pipeline.lean` composes `Recv.step
.finishOnError`; every proof in both reshard modules was already
policy-generic (`step_inv pol`, `reachable_safe pol`), so the rename
`shipping → endOpOnly` and the default change built first time with zero
proof edits. Keep that discipline: a policy inductive with the shipping
behaviour as *one* constructor, proofs over all constructors.

[OBS 2026-10-22] F5's test is still `DISABLED_` at `2ed6f8f`; the Peregrine
`BlockTransport` backend (`b43de27`, `5adb0f4`) is an adapter class only —
not instantiated by `BlockTransport`, refuses `kBlockPush`, no per-uuid
latch — so the parked F10/Peregrine question is answered for now and
re-opens only when `BlockTransport` starts constructing it.

## The tool defect (the real lesson of the day)

[FACT] `tools/repin_citations.py` resolves a bare `` `:N` `` to the file of
the nearest *earlier* explicit citation in the same source line, and the
corpus writes many sentences of the form "`mgr.cc:ABC` … and the connector
(`:N`)" where `:N` is a *different* file (vLLM, tpu-inference,
`reshard_*_session.cc`, `raiden_controller.cc` next to a `.h` cite). On a
sync where `mgr.cc` moved +6 and `bt.cc` +1, every such bare citation was
shifted by the wrong delta: ~27 Python lines in `Caller.lean`, four rows of
`reshard.md`, `findings/README.md` §F3 (`.h` delta applied to `.cc`), §C1,
§R-B, and — worst — two lines *inside a fenced verbatim test log*. The
tool's own report showed none of this: the entries were plain `shift`.

[OBS 2026-10-22] Three independent audits were needed. The first (arithmetic
per citation, file resolved from the sentence) found the class; the second
(every added line re-read, ~200 target lines spot-read) confirmed the fixes
and found range nits; the third (semantic: "is the *claim* true?") caught a
wrong sentence I had written about the F1 reproducer ("hook point no longer
exists" — it exists; the test would *pass* on the fix, and what blocks a
re-run is `2ed6f8f`'s `Insert` signature change). Reading: arithmetic audits
do not catch prose errors, and I write prose errors when closing a finding
in a hurry. The third angle is not optional.

[OBS 2026-10-22] Cheap mechanical check that would have caught most of it,
now in the rechecks row as the rule: for every changed bare citation, decide
the file from the sentence and compare the applied delta with that file's;
and for every explicit citation of an *unchanged* file on a changed line,
assert it is byte-identical to the previous version (47/47 held after the
fixes). Fenced blocks must be skipped outright.

## Parked / next

[OPEN] Fix `repin_citations.py`: (a) inherit the file of the nearest explicit
cite only within the same backtick group or parenthesis, else emit `CHECK`;
(b) never rewrite inside ``` fences; (c) treat files from foreign pins
(`sched.py`, `conn.py`, `base.py`, `tpu_raiden_connector.py`, `utils.py`,
`kvcfg.py`) as external by default. Folded into the parked "Citation drift
check in CI" item.
