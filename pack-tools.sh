#!/usr/bin/env bash
# Rebuild vm-tools-*.tar.gz from this directory. Run on a connected workstation.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-1.0.0}"
OUT_DIR="${2:-${ROOT}/dist}"
NAME="vm-tools-${VERSION}"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

if find "${ROOT}" -name '*.raw' -print -quit | grep -q .; then
  echo "ERROR: Refusing to pack; raw disk files present." >&2
  exit 1
fi

mkdir -p "${STAGE}/vm-tools" "${OUT_DIR}"
# Tools package only — scripts, manifests, tech sheet. No disk images.
install -d \
  "${STAGE}/vm-tools/scripts/pod" \
  "${STAGE}/vm-tools/scripts/lib" \
  "${STAGE}/vm-tools/manifests/pod" \
  "${STAGE}/vm-tools/docs"
cp -a "${ROOT}/scripts/pod/." "${STAGE}/vm-tools/scripts/pod/"
cp -a "${ROOT}/scripts/lib/oc-virtctl.sh" "${STAGE}/vm-tools/scripts/lib/"
cp -a "${ROOT}/manifests/pod/." "${STAGE}/vm-tools/manifests/pod/"
cp -a "${ROOT}/START-HERE.txt" "${ROOT}/build" "${ROOT}/dest" "${ROOT}/pack-tools.sh" "${STAGE}/vm-tools/"
[[ -f "${ROOT}/docs/TEST-RUN.md" ]] && cp -a "${ROOT}/docs/TEST-RUN.md" "${STAGE}/vm-tools/docs/"
chmod 0750 "${STAGE}/vm-tools/build" "${STAGE}/vm-tools/dest" "${STAGE}/vm-tools/pack-tools.sh" "${STAGE}/vm-tools/scripts/pod/"*.sh

tar -C "${STAGE}" -czf "${OUT_DIR}/${NAME}.tar.gz" vm-tools
(
  cd "${OUT_DIR}"
  sha256sum "${NAME}.tar.gz" > "${NAME}.sha256"
)

echo "Wrote ${OUT_DIR}/${NAME}.tar.gz"
echo "Wrote ${OUT_DIR}/${NAME}.sha256"
echo
echo "USB: copy those two files. On the bastion:"
echo "  sha256sum -c ${NAME}.sha256"
echo "  tar -xzf ${NAME}.tar.gz"
echo "  cd vm-tools && cat START-HERE.txt"
