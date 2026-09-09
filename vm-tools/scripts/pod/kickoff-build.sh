#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  kickoff-build.sh \
    --namespace <src-ns> \
    --vm <src-vm> \
    --version <ver> \
    --storage-class <lvm-sc> \
    --transfer-dir <dir-on-bastion> \
    [--keep-export] [--clean]

Run on the source-cluster bastion (oc login to source cluster).
Creates a Build Job that exports and compresses VM disks in-cluster.
Then a transfer Job holds the work PVC while files copy to --transfer-dir.
Raw disks never land on the bastion.
Use --transfer-dir /tmp/vm-transfer or $HOME/vm-transfer. Do not use /home/data unless you own it.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=lib-kickoff.sh
source "${SCRIPT_DIR}/lib-kickoff.sh"

NS=""
VM=""
VERSION=""
STORAGE_CLASS=""
TRANSFER_DIR=""
KEEP_EXPORT="false"
CLEAN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --vm) VM="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
    --transfer-dir) TRANSFER_DIR="$2"; shift 2 ;;
    --keep-export) KEEP_EXPORT="true"; shift ;;
    --clean) CLEAN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

require_kickoff_commands
ensure_logged_in

[[ -n "${NS}" && -n "${VM}" && -n "${VERSION}" && -n "${STORAGE_CLASS}" && -n "${TRANSFER_DIR}" ]] || {
  usage
  exit 2
}

ensure_writable_dir "${TRANSFER_DIR}"

oc get vm "${VM}" -n "${NS}" >/dev/null
oc get storageclass "${STORAGE_CLASS}" >/dev/null

if [[ "${CLEAN}" == "true" ]]; then
  run_cleanup "${NS}"
fi

SAFE_VM="$(k8s_name "${VM}")"
SAFE_VERSION="$(k8s_name "${VERSION}")"
JOB_NAME="abc-build-${SAFE_VM}-${SAFE_VERSION}"
JOB_NAME="${JOB_NAME:0:63}"
JOB_NAME="${JOB_NAME%-}"
SA_NAME="${JOB_NAME}"
PVC_NAME="${JOB_NAME}-work"
CM_NAME="${JOB_NAME}-scripts"
STAGING_POD="${JOB_NAME}-stage"

fail_if_exists job "${NS}" "${JOB_NAME}"
fail_if_exists pvc "${NS}" "${PVC_NAME}"

echo "Computing Job PVC size from source VM PVC requests..."
SRC_BYTES="$(compute_source_pvc_bytes "${NS}" "${VM}")"
[[ "${SRC_BYTES}" -gt 0 ]] || {
  echo "ERROR: Could not determine source VM PVC sizes." >&2
  exit 1
}
OVERHEAD_BYTES="$(quantity_to_bytes "10Gi")"
PVC_BYTES=$((SRC_BYTES + OVERHEAD_BYTES))
PVC_SIZE="$(bytes_to_gi "${PVC_BYTES}")"
echo "Job PVC size: ${PVC_SIZE} (1× source PVC sum + 10Gi workspace)"

JOB_IMAGE="$(resolve_job_image)"
echo "Job image: ${JOB_IMAGE}"

echo "Applying build Job RBAC..."
render_template "${REPO_ROOT}/manifests/pod/rbac-job-build.yaml.tpl" /tmp/abc-build-rbac.yaml \
  SA_NAME="${SA_NAME}" NAMESPACE="${NS}" JOB_NAME="${JOB_NAME}"
oc apply -f /tmp/abc-build-rbac.yaml

echo "Creating Job PVC ${NS}/${PVC_NAME}..."
create_job_pvc "${NS}" "${PVC_NAME}" "${PVC_SIZE}" "${STORAGE_CLASS}"
wait_for_pvc_bound "${NS}" "${PVC_NAME}"

stage_virtctl_on_pvc "${NS}" "${PVC_NAME}" "${SA_NAME}" "${JOB_IMAGE}" "${STAGING_POD}"

echo "Creating ConfigMap with job-build.sh..."
create_configmap_from_script "${NS}" "${CM_NAME}" "${SCRIPT_DIR}/job-build.sh"

render_template "${REPO_ROOT}/manifests/pod/job-build.yaml.tpl" /tmp/abc-build-job.yaml \
  JOB_NAME="${JOB_NAME}" NAMESPACE="${NS}" SA_NAME="${SA_NAME}" \
  PVC_NAME="${PVC_NAME}" CM_NAME="${CM_NAME}" JOB_IMAGE="${JOB_IMAGE}" \
  SOURCE_NS="${NS}" SOURCE_VM="${VM}" VERSION="${VERSION}" KEEP_EXPORT="${KEEP_EXPORT}"

echo "Starting Build Job ${NS}/${JOB_NAME}..."
oc apply -f /tmp/abc-build-job.yaml

stream_job_logs "${NS}" "${JOB_NAME}" &
LOG_PID=$!

if ! wait_for_job_complete "${NS}" "${JOB_NAME}" 86400; then
  kill "${LOG_PID}" 2>/dev/null || true
  wait "${LOG_PID}" 2>/dev/null || true
  exit 1
fi
kill "${LOG_PID}" 2>/dev/null || true
wait "${LOG_PID}" 2>/dev/null || true

ensure_writable_dir "${TRANSFER_DIR}"
BUNDLE_LOCAL="${TRANSFER_DIR}/${SAFE_VM}-${VERSION}"
ensure_writable_dir "${BUNDLE_LOCAL}"

echo "Build Job is Complete. Starting transfer Job and copying bundle to ${BUNDLE_LOCAL}..."
echo "If this copy dies, rerun:"
echo "  ./fetch --namespace ${NS} --pvc ${PVC_NAME} --transfer-dir ${TRANSFER_DIR} --bundle-name ${SAFE_VM}-${VERSION}"
copy_pvc_to_local "${NS}" "${PVC_NAME}" "${SA_NAME}" "${JOB_IMAGE}" "${STAGING_POD}" "${BUNDLE_LOCAL}"

echo
echo "=== Checksums (compressed artifacts only) ==="
if [[ -f "${BUNDLE_LOCAL}/checksums.sha256" ]]; then
  cat "${BUNDLE_LOCAL}/checksums.sha256"
  echo
  echo "Verify with:"
  echo "  cd ${BUNDLE_LOCAL} && sha256sum -c checksums.sha256"
else
  echo "WARNING: checksums.sha256 not found in bundle." >&2
fi

print_usb_instructions "${BUNDLE_LOCAL}"

echo "Build kickoff completed: ${BUNDLE_LOCAL}"
echo
echo "Optional cleanup (cluster-admin):"
echo "  ./cleanup --namespace ${NS}"
