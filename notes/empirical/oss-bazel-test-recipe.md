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

[EMP] Source-based branch coverage for `tpu_sync/formal_verification/tools/resolve_anchors.py --coverage`:
add `--per_file_copt='^tpu_sync/.*@-fprofile-instr-generate,-fcoverage-mapping' --linkopt=-fprofile-instr-generate`
to the base `--config=oss` + `CC`/`CXX` command above (the anchored `^` keeps
generated `bazel-out/.../*.pb.cc` and `external/` uninstrumented; the link flag
pulls in the profile runtime) and build the 19 hardware-free test binaries
measured on 2026-10-29: `transfer_send_session_test`,
`kv_cache_manager_with_transfer_{send_drain,control,pool_reshard,ip}_test`,
`reshard_{send,receive}_session_test`, `pool_staging_test`, `pool_layout_test`,
`kv_cache_listener_test` (tagged `no_oss` in `tpu_sync/kv_cache/BUILD` but with
no TPU dependency; build it by explicit label), `staging_arena_test`,
`pool_reshard_send_slots_test`, `pool_reshard_planner_streams_test`,
`reshard_control_pipe_test`, `reshard_service_test`, `control_plane_backend_test`,
`data_connection_policy_test`, `block_transport_test`,
`block_transport_session_test`.
Run each binary under `LLVM_PROFILE_FILE=<dir>/<name>-%p-%m.profraw` (pass
`--gtest_filter=-*InvalidArgumentsRejected` to `block_transport_session_test`,
whose `BlockTransportServerPullSessionTest.InvalidArgumentsRejected` aborts on
`peregrine::v1::WriteExact(-1, ...)`'s `IsValidSocket` `CHECK`), merge with
`llvm-profdata-21 merge -sparse`, and export with
`llvm-cov-21 export -skip-functions -instr-profile=... <bin1> -object <bin2> ... -object <dso> ...`
over `realpath`-deduplicated `ldd` `_solib_k8/libtpu_Usync*.so` shared libraries
(globbing `_solib_k8/*.so` directly can pick up stale DSOs from moved targets;
`functions have mismatched data` warnings come from third-party inline COMDATs
and do not affect `tpu_sync/` counts).

## See also

- ../journal/2026-10/2026-10-07-f5-per-peer-staging-admission-fix.md
- ../../findings/build_targets.patch (wires in fork-only bug-hunt reproducer targets)
