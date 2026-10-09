# Running tpu-sync's hardware-free C++ tests from the fork (OSS build)

Canonical for *what* the tests show: `verification/findings/README.md`
(§F5 validation, §"Fix validation"). This note is the recipe for getting them
to build and run at all, which no `verification/` document owns.

**Verified against:** tpu-sync `50b0774`, 2026-10-07, six runs in one day
(cold build, four incremental builds, one unfixed-tree run). Bazel 8.6.0
(`.bazelversion`), clang 21 on a Debian-based workstation.
**Last verified:** 2026-10-07

[EMP] The repo's `.bazelrc` `build:oss` config names a clang that may not be
installed (`clang-18` here). Pointing it at the installed one on the command
line is enough; nothing in the tree needs editing:

```sh
bazel test --config=oss \
  --action_env=CC=clang-21 --action_env=CXX=clang++-21 --repo_env=CC=clang-21 \
  --test_output=errors <targets>
```

There was no `bazel` or `bazelisk` on `PATH`; a Bazel 8.6.0 binary fetched
outside the repo works (the fork does not vendor one).

[EMP] Cost: the cold build of `//tpu_sync/core:kv_cache_manager_with_transfer_control_test`
is ~15 min (XLA, gRPC, protobuf from source); an incremental rebuild after
touching `kv_cache_manager_with_transfer.{h,cc}` is 45–85 s plus test time.
The warm output base is per clone: deleting the clone orphans it.

[EMP] Hardware-free targets that link `StagingBlockAllocator` /
`TransferReceiveSession`, all green at `50b0774` with and without
`per_peer_staging_admission.patch`:
`//tpu_sync/core:kv_cache_manager_with_transfer_control_test` (~48 s),
`:transfer_send_session_test`, `:kv_cache_manager_with_transfer_send_drain_test`,
`:kv_cache_manager_with_transfer_pool_reshard_test`,
`:kv_cache_manager_with_transfer_ip_test`.
Not runnable here: `:kv_cache_manager_with_transfer_test` (`no_oss`,
`requires-jellyfish` — TPU hardware; it also fails to *compile* in the OSS
config with `no member named 'absl_testing'`, so a build error there is not a
regression of ours), `:kv_cache_manager_with_transfer_perf_test` (`no_oss`,
`requires-ghostfish:4`), and `//tpu_sync/kv_cache:kv_cache_store_test`
(`no_oss`, needs a gRPC registry).

[EMP] Running a `DISABLED_` test: `--test_arg=--gtest_also_run_disabled_tests
--test_arg=--gtest_filter=<pattern>`; add `--test_output=all` to see a passing
test's log on the console (otherwise read `bazel-testlogs/<pkg>/<target>/test.log`,
which the next run of the same target overwrites).

[EMP] The repo's own gtest helpers: `ABSL_ASSERT_OK` / `ABSL_EXPECT_OK` and
`absl_testing::StatusIs` are what the hardware-free tests use
(`transfer_send_session_test.cc`); `FakeSendBase(num_layers, host_blocks)` is
the ready-made `KVCacheManagerBase` stub for allocator-level tests.

## See also

- ../journal/2026-10/2026-10-07-f5-per-peer-staging-admission-fix.md
- bughunt-repro-status-at-01ffa3d.md (F1–F4 reproducers, a different build
  recipe: their targets come from `build_targets.patch`)
