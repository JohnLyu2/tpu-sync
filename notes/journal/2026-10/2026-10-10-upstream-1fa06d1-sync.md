# Upstream `1fa06d1` sync: per-shard receive accounting, `core/ → kv_cache/` move, F4 fixed upstream

Load this when the tree is at or past `1fa06d1`, when a note cites `50b0774`
line numbers for the sessions, manager or `block_transport.cc`, or before the
next upstream sync.

[FACT] Upstream `google/tpu-sync` `main` = `1fa06d1` (2026-10-10, 38 commits
past `50b0774`). Fetched over HTTPS (`git fetch https://github.com/google/tpu-sync.git
main:refs/remotes/upstream-https/main`; SSH to GitHub is refused from the
workstation shell). Facts about what changed in the modelled code are in
`verification/docs/upstream_rechecks.md` (2026-10-10 row) and in the module
preambles; this entry holds what is not there.

[FACT] **The Lean model did not change.** The only behavioural change on the
modelled path (`OnBlocksReceived` → `OnBlockShardsReceived`, per-shard counters
`blocks_received_per_shard_` / `num_completed_shards_`, `91d5b59` NUMA-split
pushes) is below the `netAccount` abstraction. A4's soundness argument now runs
over shards: a shard reaches `total_blocks_ * num_layers` only after every
stream carrying it has reported, so the call that sets `network_completed_`
runs after every layer's completing stream, and each such stream runs
`OnLayerReceived` (from `CompleteIncomingPush`, `bt.cc:618-621` → `:789`) before
its own `OnBlockShardsReceived` (`bt.cc:629-630`). Receive.lean's A4 and the
docs say this; `ReadinessSound` is unchanged.

[FACT] **F4 is fixed upstream** by `72255dd` (2026-10-07, "Validate all workers
before dispatching in `RaidenController::TransferBuffers` and release
auto-allocated staging on error", the PR #1105 shape, three new tests). The F4
hunk was dropped from `candidate_fixes.patch`; `findings/README.md` §F4,
§Summary and §History record it. F1, F2, F3, F5 unchanged.

[OBS 2026-10-10] Tooling lessons from the re-pin (also folded into the tool):

- `repin_citations.py` ran `git diff -U0 OLD NEW -- <old path>`, which shows a
  moved file as a full deletion. It now reads `git diff -M --name-status
  --diff-filter=R`, diffs `OLD:old NEW:new` blob-to-blob, accepts aliases and
  paths spelled in either naming, and rewrites a full OLD path to the NEW one
  (`moved` tag). `ALIASES`/`RECV`/`SEND` are now spelled in `tpu_sync/kv_cache/`.
- **Unqualified `.cc:`/`.h:` in a source whose `DEFAULTS` is `recv` are
  mis-shifted when the line is about `send`.** This bit `prefill_decode.md`'s
  send row (`.h:187-191`, `.cc:157-201`, bare `:157-160`, `:189-196`) and
  `Session.lean`'s send column (`.h:187/190/191/183/176`, `.h:89-92`): the
  tool shifted them by the *receive* file's offsets. Restored by hand from HEAD
  (`send.cc`/`send.h` had zero line movement). Rule: after `--apply`, diff
  every line containing `send` against HEAD in `Session.lean` and the docs.
- Lines that name another commit (`4efb0dd`, `e7c933f`) are skipped by design;
  32 of them needed hand re-pinning this time. Grep for `skip(other-commit)`
  in the dry run and treat the list as a to-do.
- `findings/filed_bugs.md` is verbatim bug text with GitHub permalinks pinned
  to a commit; the tool shifted numbers inside those links. Reverted, and the
  file is now in the tool's `FROZEN` set. `proposal.md` is likewise frozen
  (header note), but it is not in the tool's default sources anyway.
- The dry run before `--apply` is the only record of which citations were
  `CHECK`; save it (`> /tmp/repin_dry.txt`) before applying.

[OBS 2026-10-10] The merge of `1fa06d1` into `main` is a state-changing git
operation and was done only with the user's explicit approval in the
conversation (the "always allow" for `git add`/`git commit` granted earlier in
the session was revoked at the user's request). Work order that made this
possible without the merge: `--apply` and all hand edits only need the fetched
objects (`git show upstream-https/main:<path>`), so the re-pin, patch
regeneration (`patch -p1` in a scratch copy of the upstream files) and
`lake build` all ran before the merge.

[HYP] Next cuts to maintenance, not done: the ~45 `bt.cc` ranges in
`prefill_decode.md`'s routing index are the most rot-prone citations left in
the hot file; a per-shard `Vector Nat` refinement of `Receive.lean` would turn
the A4 prose argument into a theorem (parked, low value while the model's
properties do not depend on shard count).

## Related
- `verification/docs/upstream_rechecks.md`
- `verification/findings/README.md` §F4, §History
- `verification/tools/repin_citations.py`
- `2026-10-10-prefill-decode-doc-split.md`
- `../../loose-ends/parked.md` (per-shard refinement entry)

[OBS 2026-10-10, second audit] A four-agent audit against `1fa06d1` after the
re-pin found no modelling defect and ~40 precision fixes, all applied: one
wrong suite name (`RecvLifecycleTest.OutOfOrderLayersSettleAfterEveryH2d`),
three `prefill_decode.md` sub-citations the re-pin had shifted by +22
(`ReleaseStagingLocked`/`FinishLocked`/`EndRecvOpLocked`), `findings` §F3 not
re-pinned (+35), a Blaze `//third_party/...` target and a non-existent
`tools/run_cc_tests.sh` in `docs/controller/read_remote.md` (removed: public
repo rule), the **test count: 56 (50 C++ + 6 E2E), not 52** — the old table
undercounted and the slides had it right — and a set of docstring statements
that claimed more than the cited test asserts (gRPC "healthy" peers are
`StalledGrpcProducer`s and the tests check contact latency only;
`ConsumerGivesUp…` runs on TCP with `num_layers = 0`; `RegisterRecv` takes no
staging slot — the model's `registerRecv` slot accounting matches
`RegisterActivePlan` and the `AddRecv` fixture). Two assumptions were made
explicit in `Receive.lean`: A4 needs streams to report exactly their planned
block count once (counters are plain `>=` sums), and A1 assumes no re-push of
a uuid after `BlockTransport` erased its `layer_progress_` entries
(`bt.cc:764-778`). Rule for next time: after `--apply`, re-run the audit; the
tool's `.cc`/`.h` default and the +N shifts inside rewritten functions are the
two error sources.
