#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  seed-abc-vm-catalog.sh \
    --bundle <abc-vm-bundle-directory> \
    --storage-class <destination-storage-class> \
    [--catalog-namespace <namespace>] \
    [--server <api-url>] \
    [--token <token>] \
    [--username <user>] \
    [--password <password>] \
    [--insecure]

If virtctl is missing, the script installs it from the destination cluster
ConsoleCLIDownload (not the Internet).

Example:
  seed-abc-vm-catalog.sh \
    --server https://api.dest.example.com:6443 \
    --token "$OC_TOKEN" \
    --bundle /srv/abc-vm/releases/abc-vm-1.0.0 \
    --storage-class ocs-storagecluster-ceph-rbd \
    --catalog-namespace vm-catalog
EOF
}

require_base_commands() {
  local command
  for command in bash oc awk cut grep sed sha256sum mkdir; do
    command -v "${command}" >/dev/null 2>&1 || {
      echo "ERROR: Required command is missing: ${command}" >&2
      exit 127
    }
  done
}

# Catalog object name suffix: boot stays "boot"; other disks use sanitized volume name
catalog_suffix() {
  local role="$1" volume_name="$2"
  if [[ "${role}" == "boot" ]]; then
    echo "boot"
  else
    echo "${volume_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
  fi
}

BUNDLE=""
STORAGE_CLASS=""
CATALOG_NAMESPACE_OVERRIDE=""
OC_SERVER=""
OC_TOKEN=""
OC_USERNAME=""
OC_PASSWORD=""
OC_INSECURE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2 ;;
    --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
    --catalog-namespace) CATALOG_NAMESPACE_OVERRIDE="$2"; shift 2 ;;
    --server) OC_SERVER="$2"; shift 2 ;;
    --token) OC_TOKEN="$2"; shift 2 ;;
    --username) OC_USERNAME="$2"; shift 2 ;;
    --password) OC_PASSWORD="$2"; shift 2 ;;
    --insecure) OC_INSECURE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

require_base_commands

[[ -n "${BUNDLE}" && -n "${STORAGE_CLASS}" ]] || {
  usage
  exit 2
}

[[ -f "${BUNDLE}/release.env" ]] || { echo "ERROR: Missing release.env" >&2; exit 1; }
[[ -f "${BUNDLE}/disks.tsv" ]] || { echo "ERROR: Missing disks.tsv" >&2; exit 1; }
[[ -f "${BUNDLE}/checksums.sha256" ]] || { echo "ERROR: Missing checksums.sha256" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer the helper next to this script (repo or copied bundle).
# shellcheck source=lib/oc-virtctl.sh
if [[ -f "${SCRIPT_DIR}/lib/oc-virtctl.sh" ]]; then
  source "${SCRIPT_DIR}/lib/oc-virtctl.sh"
elif [[ -f "${SCRIPT_DIR}/oc-virtctl.sh" ]]; then
  source "${SCRIPT_DIR}/oc-virtctl.sh"
else
  echo "ERROR: Missing helper scripts/lib/oc-virtctl.sh" >&2
  exit 1
fi

export OC_SERVER OC_TOKEN OC_USERNAME OC_PASSWORD OC_INSECURE
oc_login_if_requested
ensure_logged_in
ensure_virtctl

# release.env is produced by the trusted build script. Do not source untrusted bundles.
source "${BUNDLE}/release.env"

CATALOG_NAMESPACE="${CATALOG_NAMESPACE_OVERRIDE:-${CATALOG_NAMESPACE:-vm-catalog}}"
RELEASE_ID="${APP_ID}-${VERSION//[^a-zA-Z0-9-]/-}"

oc get storageclass "${STORAGE_CLASS}" >/dev/null
require_cdi_api

echo "Destination context: $(oc config current-context)"
echo "Catalog namespace: ${CATALOG_NAMESPACE}"
echo "Release: ${RELEASE_ID}"

echo "Verifying disk checksums..."
(
  cd "${BUNDLE}"
  sha256sum -c checksums.sha256
)

if ! oc get namespace "${CATALOG_NAMESPACE}" >/dev/null 2>&1; then
  oc new-project "${CATALOG_NAMESPACE}"
fi

while IFS=$'\t' read -r ROLE VOLUME_NAME FILE_NAME PVC_SIZE VOLUME_MODE; do
  [[ -n "${ROLE}" && "${ROLE}" != \#* ]] || continue

  IMAGE_PATH="${BUNDLE}/${FILE_NAME}"
  SUFFIX="$(catalog_suffix "${ROLE}" "${VOLUME_NAME}")"
  DV_NAME="${RELEASE_ID}-${SUFFIX}"

  [[ -f "${IMAGE_PATH}" ]] || {
    echo "ERROR: Missing image file ${IMAGE_PATH}" >&2
    exit 1
  }

  if oc get dv "${DV_NAME}" -n "${CATALOG_NAMESPACE}" >/dev/null 2>&1; then
    PHASE="$(oc get dv "${DV_NAME}" -n "${CATALOG_NAMESPACE}" -o jsonpath='{.status.phase}')"

    if [[ "${PHASE}" == "Succeeded" ]]; then
      echo "Catalog DataVolume already exists and is ready: ${DV_NAME}"
      continue
    fi

    echo "ERROR: Catalog DataVolume ${DV_NAME} already exists in phase ${PHASE}." >&2
    echo "Resolve or delete it manually before retrying." >&2
    exit 1
  fi

  # virtctl expects lowercase volume-mode values
  VOLUME_MODE_LOWER="$(echo "${VOLUME_MODE}" | tr '[:upper:]' '[:lower:]')"

  echo "Uploading ${FILE_NAME} as ${CATALOG_NAMESPACE}/${DV_NAME} (volumeMode=${VOLUME_MODE_LOWER})..."
  virtctl image-upload dv "${DV_NAME}" \
    --namespace="${CATALOG_NAMESPACE}" \
    --size="${PVC_SIZE}" \
    --storage-class="${STORAGE_CLASS}" \
    --volume-mode="${VOLUME_MODE_LOWER}" \
    --access-mode=ReadWriteOnce \
    --image-path="${IMAGE_PATH}" \
    --wait-secs=86400

  PHASE="$(oc get dv "${DV_NAME}" -n "${CATALOG_NAMESPACE}" -o jsonpath='{.status.phase}')"
  [[ "${PHASE}" == "Succeeded" ]] || {
    echo "ERROR: Upload did not complete successfully for ${DV_NAME}; phase=${PHASE}" >&2
    exit 1
  }

  oc label pvc "${DV_NAME}" -n "${CATALOG_NAMESPACE}" \
    "abcvm.io/app=${APP_ID}" \
    "abcvm.io/version=${VERSION}" \
    "abcvm.io/role=${ROLE}" \
    --overwrite

done < "${BUNDLE}/disks.tsv"

BOOT_DV_NAME="${RELEASE_ID}-boot"

# DataSource is the primary catalog object users (and the deploy script) reference
cat <<EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ${RELEASE_ID}
  namespace: ${CATALOG_NAMESPACE}
  labels:
    abcvm.io/app: ${APP_ID}
    abcvm.io/version: "${VERSION}"
    abcvm.io/role: boot
spec:
  source:
    pvc:
      name: ${BOOT_DV_NAME}
      namespace: ${CATALOG_NAMESPACE}
EOF

echo "Waiting for DataSource ${CATALOG_NAMESPACE}/${RELEASE_ID} to become Ready..."
if ! oc wait datasource "${RELEASE_ID}" -n "${CATALOG_NAMESPACE}" --for=condition=Ready --timeout=15m; then
  oc describe datasource "${RELEASE_ID}" -n "${CATALOG_NAMESPACE}" >&2 || true
  echo "ERROR: DataSource ${CATALOG_NAMESPACE}/${RELEASE_ID} is not Ready." >&2
  exit 1
fi

echo
echo "Catalog seed completed successfully."
echo "Primary catalog object: DataSource/${RELEASE_ID}"
oc get dv,pvc,datasource -n "${CATALOG_NAMESPACE}" -l "abcvm.io/app=${APP_ID}"
