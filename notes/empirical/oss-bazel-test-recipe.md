# Running tpu-sync's hardware-free C++ tests from the fork (OSS build)

Canonical for *what* the tests show: `findings/README.md`. This note is the
workstation recipe for getting them to build and run locally, which no
`tpu_sync/formal_verification/` document owns.

**Read at:** tpu-sync `42dda54` (2026-10-28, frozen stamp — update only when
build flags, prerequisites, or target packages change). Bazelisk at
`~/.local/bin`, Bazel 8.6.0 (`.bazelversion`), `clang-21`, `libibverbs-dev` on a
Debian-based workstation.

[EMP] `.bazelrc`'s `build:oss` config names a clang that may not be installed
(`clang-18` here), and `peregrine`'s RDMA targets `#include <infiniband/verbs.h>`
unconditionally (`sudo apt install libibverbs-dev` required since `peregrine`
0.1.14). Pointing Bazel at the installed clang on the command line is enough;
nothing in the tree needs editing:

```sh
bazel test --config=oss \
  --action_env=CC=clang-21 --action_env=CXX=clang++-21 --repo_env=CC=clang-21 \
  --test_output=errors <targets>
```

[EMP] Cost: cold build of the transfer/controller test targets is ~15–16 min
(XLA, gRPC, protobuf from source); incremental rebuilds take ~45–85 s;
`--runs_per_test=10` on the two `kv_cache` session targets is ~3 min warm. Each
checkout (including a `git worktree`) gets its own Bazel output base, so a new
worktree builds cold and deleting a clone orphans its cache.

[EMP] Hardware-free targets covering transfer sessions, resharding, and staging:
- `//tpu_sync/kv_cache:transfer_send_session_test`
- `//tpu_sync/kv_cache:kv_cache_manager_with_transfer_send_drain_test`
- `//tpu_sync/kv_cache:kv_cache_manager_with_transfer_control_test`
- `//tpu_sync/kv_cache:kv_cache_manager_with_transfer_pool_reshard_test`
- `//tpu_sync/kv_cache:kv_cache_manager_with_transfer_ip_test`
- `//tpu_sync/core:staging_arena_test`
- `//tpu_sync/core:pool_reshard_send_slots_test`

Not runnable without TPU / internal services:
`//tpu_sync/kv_cache:kv_cache_manager_with_transfer_test` (`no_oss`,
`requires-jellyfish` — also fails to compile under `--config=oss` with `no member
named 'absl_testing'`), `:kv_cache_manager_with_transfer_perf_test` (`no_oss`,
`requires-ghostfish:4`), and `//tpu_sync/kv_cache:kv_cache_store_test` (`no_oss`,
needs a gRPC registry).

[EMP] Running a `DISABLED_` test: `--test_arg=--gtest_also_run_disabled_tests
--test_arg=--gtest_filter=<pattern>`; add `--test_output=all` to print passing
logs on stdout (otherwise inspect `bazel-testlogs/<pkg>/<target>/test.log` before
re-running). Hardware-free unit tests use `ABSL_ASSERT_OK` / `ABSL_EXPECT_OK`,
`absl_testing::StatusIs`, and `FakeSendBase(num_layers, host_blocks)`.

## See also

- ../journal/2026-10/2026-10-07-f5-per-peer-staging-admission-fix.md
- ../../findings/build_targets.patch (wires in fork-only bug-hunt reproducer targets)
