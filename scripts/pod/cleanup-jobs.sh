#!/usr/bin/env bash
# Wrapper so repo scripts/pod matches vm-tools/cleanup.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -x "${ROOT}/vm-tools/cleanup" ]]; then
  exec "${ROOT}/vm-tools/cleanup" "$@"
fi
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../vm-tools/cleanup" "$@"
