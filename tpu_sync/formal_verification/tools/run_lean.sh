#!/usr/bin/env bash

# Copyright 2026 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Evaluates a Lean 4 snippet (stdin, or the given `lean` arguments) against the
# built TpuSyncVerify models without adding a file to the source tree. It reads
# the compiled modules under `.lake/`: if `.lake/build/lib` is missing it runs
# `lake build` first, and it does not rebuild after a source change, so run it
# with `--build` (or run `lake build`) after editing a model.
#
# Usage:
#   tpu_sync/formal_verification/tools/run_lean.sh << 'EOF'
#   import TpuSyncVerify.Transfer.PrefillDecode.Receive
#   open TpuSyncVerify TpuSyncVerify.Transfer.PrefillDecode TpuSyncVerify.Transfer.PrefillDecode.Recv
#   #eval ModelCheck.check ⟨initPush 1, fun s e => match e with
#     | .cancel => cancelEager s
#     | e => step s e⟩ events violates 6
#   EOF
#
#   tpu_sync/formal_verification/tools/run_lean.sh --build

set -euo pipefail

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v lake >/dev/null 2>&1; then
  LAKE_BIN="$(command -v lake)"
elif [[ -x "${HOME}/.elan/bin/lake" ]]; then
  LAKE_BIN="${HOME}/.elan/bin/lake"
else
  echo "ERROR: 'lake' not found on PATH or in ~/.elan/bin/lake." >&2
  echo "Install elan (https://github.com/leanprover/elan); toolchain is pinned in tpu_sync/formal_verification/lean-toolchain." >&2
  exit 127
fi

cd "${VERIFY_DIR}"

if [[ "${1:-}" == "--build" ]]; then
  exec "${LAKE_BIN}" build
fi

# Ensure precompiled .olean artifacts exist before evaluating snippets.
if [[ ! -d "${VERIFY_DIR}/.lake/build/lib" ]]; then
  "${LAKE_BIN}" build >/dev/null
fi

if [[ $# -eq 0 ]]; then
  exec "${LAKE_BIN}" env lean --stdin
else
  exec "${LAKE_BIN}" env lean "$@"
fi
