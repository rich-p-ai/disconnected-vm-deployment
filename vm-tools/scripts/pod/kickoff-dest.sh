#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  kickoff-dest.sh \
    --bundle-path <dir-on-bastion-with-archives> \
    --storage-class <lvm-sc> \
    --catalog-namespace <catalog-ns> \
    --namespace <user-project> \
    --vm-name <new-vm> \
    [--start]

Run on the destination-cluster bastion (oc login to dest cluster).
One command: seed catalog (if DataSource not Ready) + deploy VM.
Only compressed archives are copied from the bastion; raw disks never land here.
Default: VM created stopped unless --start.
Fails hard if --vm-name already exists in --namespace.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=lib-kickoff.sh
source "${SCRIPT_DIR}/lib-kickoff.sh"

BUNDLE_PATH=""
STORAGE_CLASS=""
CATALOG_NAMESPACE="vm-catalog"
TARGET_NAMESPACE=""
VM_NAME=""
START_VM="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-path) BUNDLE_PATH="$2"; shift 2 ;;
    --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
    --catalog-namespace) CATALOG_NAMESPACE="$2"; shift 2 ;;
    --namespace) TARGET_NAMESPACE="$2"; shift 2 ;;
    --vm-name) VM_NAME="$2"; shift 2 ;;
    --start) START_VM="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

require_kickoff_commands
ensure_logged_in

[[ -n "${BUNDLE_PATH}" && -n "${STORAGE_CLASS}" && -n "${CATALOG_NAMESPACE}" \
  && -n "${TARGET_NAMESPACE}" && -n "${VM_NAME}" ]] || {
  usage
  exit 2
}

[[ -d "${BUNDLE_PATH}" ]] || {
  echo "ERROR: Bundle path is not a directory: ${BUNDLE_PATH}" >&2
  exit 1
}

[[ -f "${BUNDLE_PATH}/release.env" ]] || {
  echo "ERROR: Missing ${BUNDLE_PATH}/release.env" >&2
  exit 1
}
[[ -f "${BUNDLE_PATH}/disks.tsv" ]] || {
  echo "ERROR: Missing ${BUNDLE_PATH}/disks.tsv" >&2
  exit 1
}
[[ -f "${BUNDLE_PATH}/checksums.sha256" ]] || {
  echo "ERROR: Missing ${BUNDLE_PATH}/checksums.sha256" >&2
  exit 1
}

if find "${BUNDLE_PATH}" -maxdepth 1 -name '*.raw' -print -quit | grep -q .; then
  echo "ERROR: Raw disk files found in ${BUNDLE_PATH}." >&2
  echo "Only compressed bundles (*.raw.gz) may be used with pod kickoff." >&2
  echo "Use the bastion fallback scripts for raw bundles, or re-run kickoff-build.sh." >&2
  exit 1
fi

shopt -s nullglob
gz_files=("${BUNDLE_PATH}"/*.raw.gz)
shopt -u nullglob
if [[ ${#gz_files[@]} -eq 0 ]]; then
  echo "ERROR: No *.raw.gz compressed disks found in ${BUNDLE_PATH}." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${BUNDLE_PATH}/release.env"

oc get storageclass "${STORAGE_CLASS}" >/dev/null
oc get namespace "${TARGET_NAMESPACE}" >/dev/null

if oc get vm "${VM_NAME}" -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: VM ${TARGET_NAMESPACE}/${VM_NAME} already exists." >&2
  exit 1
fi

if ! oc get namespace "${CATALOG_NAMESPACE}" >/dev/null 2>&1; then
  echo "Creating catalog namespace ${CATALOG_NAMESPACE}..."
  oc new-project "${CATALOG_NAMESPACE}" || oc create namespace "${CATALOG_NAMESPACE}"
fi

SAFE_VM="$(k8s_name "${VM_NAME}")"
RELEASE_ID="${APP_ID}-${VERSION//[^a-zA-Z0-9-]/-}"
JOB_NAME="abc-dest-${SAFE_VM}-${RELEASE_ID}"
JOB_NAME="${JOB_NAME:0:63}"
JOB_NAME="${JOB_NAME%-}"
SA_NAME="${JOB_NAME}"
PVC_NAME="${JOB_NAME}-work"
CM_NAME="${JOB_NAME}-scripts"
STAGING_POD="${JOB_NAME}-stage"

fail_if_exists job "${TARGET_NAMESPACE}" "${JOB_NAME}"
fail_if_exists pvc "${TARGET_NAMESPACE}" "${PVC_NAME}"

echo "Computing Job PVC size..."
BUNDLE_BYTES="$(du -sb "${BUNDLE_PATH}" | awk '{print $1}')"
LARGEST_DISK="$(largest_disk_bytes_from_tsv "${BUNDLE_PATH}/disks.tsv")"
OVERHEAD_BYTES="$(quantity_to_bytes "10Gi")"
PVC_BYTES=$((BUNDLE_BYTES + LARGEST_DISK + OVERHEAD_BYTES))
PVC_SIZE="$(bytes_to_gi "${PVC_BYTES}")"
echo "Job PVC size: ${PVC_SIZE} (bundle + largest disk + 10Gi)"

JOB_IMAGE="$(resolve_job_image)"
echo "Job image: ${JOB_IMAGE}"

echo "Applying dest Job RBAC (user ns + catalog clone grant)..."
render_template "${REPO_ROOT}/manifests/pod/rbac-job-dest.yaml.tpl" /tmp/abc-dest-rbac.yaml \
  SA_NAME="${SA_NAME}" NAMESPACE="${TARGET_NAMESPACE}" \
  CATALOG_NAMESPACE="${CATALOG_NAMESPACE}" JOB_NAME="${JOB_NAME}"
oc apply -f /tmp/abc-dest-rbac.yaml

echo "Creating Job PVC ${TARGET_NAMESPACE}/${PVC_NAME}..."
create_job_pvc "${TARGET_NAMESPACE}" "${PVC_NAME}" "${PVC_SIZE}" "${STORAGE_CLASS}"
wait_for_pvc_bound "${TARGET_NAMESPACE}" "${PVC_NAME}"

echo "Copying compressed bundle from bastion to Job PVC..."
copy_local_to_pvc "${TARGET_NAMESPACE}" "${PVC_NAME}" "${SA_NAME}" "${JOB_IMAGE}" "${STAGING_POD}" "${BUNDLE_PATH}"

stage_virtctl_on_pvc "${TARGET_NAMESPACE}" "${PVC_NAME}" "${SA_NAME}" "${JOB_IMAGE}" "${STAGING_POD}"

echo "Creating ConfigMap with job-seed-deploy.sh..."
create_configmap_from_script "${TARGET_NAMESPACE}" "${CM_NAME}" "${SCRIPT_DIR}/job-seed-deploy.sh"

render_template "${REPO_ROOT}/manifests/pod/job-dest.yaml.tpl" /tmp/abc-dest-job.yaml \
  JOB_NAME="${JOB_NAME}" NAMESPACE="${TARGET_NAMESPACE}" SA_NAME="${SA_NAME}" \
  PVC_NAME="${PVC_NAME}" CM_NAME="${CM_NAME}" JOB_IMAGE="${JOB_IMAGE}" \
  TARGET_NS="${TARGET_NAMESPACE}" VM_NAME="${VM_NAME}" \
  STORAGE_CLASS="${STORAGE_CLASS}" CATALOG_NAMESPACE="${CATALOG_NAMESPACE}" \
  START_VM="${START_VM}"

echo "Starting Dest Job ${TARGET_NAMESPACE}/${JOB_NAME}..."
oc apply -f /tmp/abc-dest-job.yaml

stream_job_logs "${TARGET_NAMESPACE}" "${JOB_NAME}" &
LOG_PID=$!

if ! wait_for_job_complete "${TARGET_NAMESPACE}" "${JOB_NAME}" 172800; then
  kill "${LOG_PID}" 2>/dev/null || true
  wait "${LOG_PID}" 2>/dev/null || true
  exit 1
fi
kill "${LOG_PID}" 2>/dev/null || true
wait "${LOG_PID}" 2>/dev/null || true

echo
echo "Dest kickoff completed."
echo "VM: ${TARGET_NAMESPACE}/${VM_NAME}"
if [[ "${START_VM}" != "true" ]]; then
  echo "Start manually with:"
  echo "  virtctl start vm ${VM_NAME} -n ${TARGET_NAMESPACE}"
fi
echo
echo "Optional cleanup (cluster-admin):"
echo "  oc delete job ${JOB_NAME} -n ${TARGET_NAMESPACE} --ignore-not-found"
echo "  oc delete pvc ${PVC_NAME} cm ${CM_NAME} -n ${TARGET_NAMESPACE} --ignore-not-found"
echo "  oc delete sa ${SA_NAME} role ${SA_NAME} rolebinding ${SA_NAME} -n ${TARGET_NAMESPACE} --ignore-not-found"
echo "  oc delete role ${SA_NAME}-catalog rolebinding ${SA_NAME}-catalog -n ${CATALOG_NAMESPACE} --ignore-not-found"
echo "  oc delete clusterrolebinding ${SA_NAME}-catalog-cloner --ignore-not-found"
