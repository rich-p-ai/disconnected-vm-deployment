#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  build-abc-vm-package.sh \
    --namespace <source-namespace> \
    --vm <source-vm-name> \
    --version <release-version> \
    --output-dir <bundle-parent-directory> \
    [--keep-export]

Example:
  build-abc-vm-package.sh \
    --namespace source-project \
    --vm source-vm \
    --version 1.0.0 \
    --output-dir /srv/abc-vm/releases
EOF
}

require_commands() {
  local command
  for command in bash oc virtctl awk cut grep sed sha256sum find sort mkdir cp date; do
    command -v "${command}" >/dev/null 2>&1 || {
      echo "ERROR: Required command is missing: ${command}" >&2
      exit 127
    }
  done
}

NS=""
VM=""
VERSION=""
OUTPUT_DIR=""
KEEP_EXPORT="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --vm) VM="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --keep-export) KEEP_EXPORT="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

require_commands

[[ -n "${NS}" && -n "${VM}" && -n "${VERSION}" && -n "${OUTPUT_DIR}" ]] || {
  usage
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="${OUTPUT_DIR}/abc-vm-${VERSION}"
EXPORT_NAME="abc-vm-export-${VERSION//[^a-zA-Z0-9-]/-}"

mkdir -p "${BUNDLE}"

oc whoami >/dev/null
oc get vm "${VM}" -n "${NS}" >/dev/null

if ! oc api-resources --api-group=kubevirt.io -o name | grep -qx 'virtualmachines'; then
  echo "ERROR: OpenShift Virtualization VirtualMachine API is unavailable." >&2
  exit 1
fi

if ! oc api-resources --api-group=cdi.kubevirt.io -o name | grep -qx 'datavolumes'; then
  echo "ERROR: CDI DataVolume API is unavailable." >&2
  exit 1
fi

echo "Source context: $(oc config current-context)"
echo "Source VM: ${NS}/${VM}"
echo "Bundle: ${BUNDLE}"

if oc get vmi "${VM}" -n "${NS}" >/dev/null 2>&1; then
  echo "Stopping VM ${NS}/${VM}..."
  virtctl stop vm "${VM}" -n "${NS}"

  echo "Waiting for VMI termination..."
  while oc get vmi "${VM}" -n "${NS}" >/dev/null 2>&1; do
    sleep 5
  done
fi

echo "Saving source metadata..."
oc get vm "${VM}" -n "${NS}" -o yaml > "${BUNDLE}/source-vm.yaml"
oc get pvc -n "${NS}" -o yaml > "${BUNDLE}/source-pvcs.yaml"

oc get vm "${VM}" -n "${NS}" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.persistentVolumeClaim)]}{.name}{"\t"}{.persistentVolumeClaim.claimName}{"\n"}{end}' \
  > "${BUNDLE}/source-disks.tsv"

[[ -s "${BUNDLE}/source-disks.tsv" ]] || {
  echo "ERROR: No PVC-backed VM disks were found." >&2
  exit 1
}

: > "${BUNDLE}/disks.tsv"

while IFS=$'\t' read -r VOLUME_NAME PVC_NAME; do
  [[ -n "${VOLUME_NAME}" && -n "${PVC_NAME}" ]] || continue

  PVC_SIZE="$(oc get pvc "${PVC_NAME}" -n "${NS}" -o jsonpath='{.spec.resources.requests.storage}')"
  VOLUME_MODE="$(oc get pvc "${PVC_NAME}" -n "${NS}" -o jsonpath='{.spec.volumeMode}')"
  [[ -n "${VOLUME_MODE}" ]] || VOLUME_MODE="Filesystem"

  ROLE="data"
  if [[ ! -s "${BUNDLE}/disks.tsv" ]]; then
    ROLE="boot"
  fi

  FILE_NAME="${VOLUME_NAME}.raw"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${ROLE}" "${VOLUME_NAME}" "${FILE_NAME}" "${PVC_SIZE}" "${VOLUME_MODE}" \
    >> "${BUNDLE}/disks.tsv"
done < "${BUNDLE}/source-disks.tsv"

cat > "${BUNDLE}/release.env" <<EOF
APP_NAME="ABC VM"
APP_ID="abc-vm"
VERSION="${VERSION}"
SOURCE_NAMESPACE="${NS}"
SOURCE_VM="${VM}"
CATALOG_NAMESPACE="vm-catalog"
VM_CPU_CORES="4"
VM_MEMORY="8Gi"
VM_NETWORK_MODE="pod"
EOF

if oc get virtualmachineexport "${EXPORT_NAME}" -n "${NS}" >/dev/null 2>&1; then
  echo "Deleting pre-existing export: ${EXPORT_NAME}"
  virtctl vmexport delete "${EXPORT_NAME}" -n "${NS}" || true
fi

echo "Creating VM export ${EXPORT_NAME}..."
virtctl vmexport create "${EXPORT_NAME}" \
  --vm="${VM}" \
  --namespace="${NS}" \
  --ttl=24h

echo "Waiting for VM export readiness..."
while true; do
  PHASE="$(oc get virtualmachineexport "${EXPORT_NAME}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"

  if [[ "${PHASE}" == "Ready" ]]; then
    break
  fi

  if [[ "${PHASE}" == "Failed" ]]; then
    oc describe virtualmachineexport "${EXPORT_NAME}" -n "${NS}" >&2 || true
    exit 1
  fi

  echo "Current export phase: ${PHASE:-unknown}"
  sleep 10
done

while IFS=$'\t' read -r ROLE VOLUME_NAME FILE_NAME PVC_SIZE VOLUME_MODE; do
  [[ -n "${ROLE}" && "${ROLE}" != \#* ]] || continue

  OUTPUT_FILE="${BUNDLE}/${FILE_NAME}"
  echo "Downloading ${VOLUME_NAME} to ${OUTPUT_FILE}..."

  virtctl vmexport download "${EXPORT_NAME}" \
    --namespace="${NS}" \
    --volume="${VOLUME_NAME}" \
    --output="${OUTPUT_FILE}" \
    --format=raw \
    --keep-vme

done < "${BUNDLE}/disks.tsv"

(
  cd "${BUNDLE}"
  sha256sum *.raw > checksums.sha256
)

cp "${SCRIPT_DIR}/seed-abc-vm-catalog.sh" "${BUNDLE}/"
cp "${SCRIPT_DIR}/deploy-abc-vm.sh" "${BUNDLE}/"
chmod 0750 "${BUNDLE}/seed-abc-vm-catalog.sh" "${BUNDLE}/deploy-abc-vm.sh"

if [[ "${KEEP_EXPORT}" != "true" ]]; then
  echo "Deleting temporary VM export ${EXPORT_NAME}..."
  virtctl vmexport delete "${EXPORT_NAME}" -n "${NS}" || true
fi

echo
echo "ABC VM bundle created successfully: ${BUNDLE}"
echo "Validate bundle contents with:"
echo "  cd ${BUNDLE} && sha256sum -c checksums.sha256"
