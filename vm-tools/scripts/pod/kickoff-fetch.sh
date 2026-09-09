#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./fetch \
    --namespace <src-ns> \
    --pvc <work-pvc> \
    --transfer-dir <dir-on-bastion> \
    [--sa <serviceaccount>] \
    [--bundle-name <folder-name>]

Copy /work/bundle from a finished Build work PVC onto this bastion.
Safe to rerun. Does not rebuild the VM export.
Does not delete the PVC.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-kickoff.sh
source "${SCRIPT_DIR}/lib-kickoff.sh"

NS=""
PVC_NAME=""
TRANSFER_DIR=""
SA_NAME=""
BUNDLE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --pvc) PVC_NAME="$2"; shift 2 ;;
    --transfer-dir) TRANSFER_DIR="$2"; shift 2 ;;
    --sa) SA_NAME="$2"; shift 2 ;;
    --bundle-name) BUNDLE_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

require_kickoff_commands
ensure_logged_in

[[ -n "${NS}" && -n "${PVC_NAME}" && -n "${TRANSFER_DIR}" ]] || { usage; exit 2; }
oc get pvc "${PVC_NAME}" -n "${NS}" >/dev/null
SA_NAME="${SA_NAME:-${PVC_NAME%-work}}"
BUNDLE_NAME="${BUNDLE_NAME:-${PVC_NAME%-work}}"
JOB_IMAGE="$(resolve_job_image)"
STAGING_POD="${SA_NAME}-stage"
BUNDLE_LOCAL="${TRANSFER_DIR}/${BUNDLE_NAME}"

mkdir -p "${TRANSFER_DIR}"
echo "Fetching bundle from ${NS}/${PVC_NAME} -> ${BUNDLE_LOCAL}"
copy_pvc_to_local "${NS}" "${PVC_NAME}" "${SA_NAME}" "${JOB_IMAGE}" "${STAGING_POD}" "${BUNDLE_LOCAL}"
print_usb_instructions "${BUNDLE_LOCAL}"
echo "Fetch completed: ${BUNDLE_LOCAL}"
echo "When USB copy is done:  ./cleanup --namespace ${NS}"
