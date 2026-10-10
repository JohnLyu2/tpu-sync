#!/usr/bin/env bash
# Zero-footprint Lean 4 runner for TpuSyncVerify counterfactuals and checks.
#
# Usage:
#   verification/tools/run_lean.sh << 'EOF'
#   import TpuSyncVerify.Transfer.PrefillDecode.Receive
#   open TpuSyncVerify TpuSyncVerify.Transfer.PrefillDecode TpuSyncVerify.Transfer.PrefillDecode.Recv
#   #eval ModelCheck.check ⟨initPush 1, fun s e => match e with
#     | .cancel => cancelEager s
#     | e => step s e⟩ events violates 6
#   EOF
#
#   verification/tools/run_lean.sh --build

set -euo pipefail

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v lake >/dev/null 2>&1; then
  LAKE_BIN="$(command -v lake)"
elif [[ -x "${HOME}/.elan/bin/lake" ]]; then
  LAKE_BIN="${HOME}/.elan/bin/lake"
else
  echo "ERROR: 'lake' not found on PATH or in ~/.elan/bin/lake." >&2
  echo "Install elan (https://github.com/leanprover/elan); toolchain is pinned in verification/lean-toolchain." >&2
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
