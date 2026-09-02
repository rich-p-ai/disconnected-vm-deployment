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
    [--keep-export] \
    [--server <api-url>] \
    [--token <token>] \
    [--username <user>] \
    [--password <password>] \
    [--insecure]

Bundle directory and VirtualMachineExport names are <vm>-<version>.
Example: --vm windows --version 1.0 -> windows-1.0

Downloads use virtctl --port-forward so no export Route is required.
EOF
}

require_base_commands() {
  local command
  for command in bash oc awk cut grep sed sha256sum find sort mkdir cp date; do
    command -v "${command}" >/dev/null 2>&1 || {
      echo "ERROR: Required command is missing: ${command}" >&2
      exit 127
    }
  done
}

k8s_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

# Collect volume name + backing PVC/DV name from a VirtualMachine.
collect_source_disks() {
  local ns="$1" vm="$2" out="$3"
  : > "${out}"

  oc get vm "${vm}" -n "${ns}" \
    -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\t"}{.persistentVolumeClaim.claimName}{"\t"}{.dataVolume.name}{"\n"}{end}' \
    | while IFS=$'\t' read -r vol_name pvc_name dv_name; do
        [[ -n "${vol_name}" ]] || continue
        local claim="${pvc_name:-${dv_name}}"
        [[ -n "${claim}" ]] || continue
        printf '%s\t%s\n' "${vol_name}" "${claim}"
      done > "${out}"
}

resolve_export_volume() {
  local wanted="$1"
  local names="$2"
  local claim="$3"

  if echo "${names}" | grep -Fxq "${wanted}"; then
    echo "${wanted}"
    return 0
  fi
  if [[ -n "${claim}" ]] && echo "${names}" | grep -Fxq "${claim}"; then
    echo "${claim}"
    return 0
  fi
  local count
  count="$(echo "${names}" | grep -c . || true)"
  if [[ "${count}" == "1" ]]; then
    echo "${names}" | head -n1
    return 0
  fi
  return 1
}

NS=""
VM=""
VERSION=""
OUTPUT_DIR=""
KEEP_EXPORT="false"
OC_SERVER=""
OC_TOKEN=""
OC_USERNAME=""
OC_PASSWORD=""
OC_INSECURE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --vm) VM="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --keep-export) KEEP_EXPORT="true"; shift ;;
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

[[ -n "${NS}" && -n "${VM}" && -n "${VERSION}" && -n "${OUTPUT_DIR}" ]] || {
  usage
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/oc-virtctl.sh" ]]; then
  # shellcheck source=lib/oc-virtctl.sh
  source "${SCRIPT_DIR}/lib/oc-virtctl.sh"
  export OC_SERVER OC_TOKEN OC_USERNAME OC_PASSWORD OC_INSECURE
  oc_login_if_requested
  ensure_logged_in
  ensure_virtctl
else
  oc whoami >/dev/null
  command -v virtctl >/dev/null 2>&1 || {
    echo "ERROR: virtctl is required and scripts/lib/oc-virtctl.sh is not present." >&2
    exit 127
  }
fi

SAFE_VM="$(k8s_name "${VM}")"
SAFE_VERSION="$(k8s_name "${VERSION}")"
RELEASE_ID="${SAFE_VM}-${SAFE_VERSION}"
BUNDLE="${OUTPUT_DIR}/${SAFE_VM}-${VERSION}"
EXPORT_NAME="${RELEASE_ID}"

mkdir -p "${BUNDLE}"

oc get vm "${VM}" -n "${NS}" >/dev/null

echo "Source context: $(oc config current-context)"
echo "Source VM: ${NS}/${VM}"
echo "Bundle: ${BUNDLE}"
echo "Export name: ${EXPORT_NAME}"

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

collect_source_disks "${NS}" "${VM}" "${BUNDLE}/source-disks.tsv"

if [[ ! -s "${BUNDLE}/source-disks.tsv" ]]; then
  echo "ERROR: No PVC- or DataVolume-backed VM disks were found." >&2
  echo "Inspect volumes with:" >&2
  echo "  oc get vm ${VM} -n ${NS} -o yaml | sed -n '/volumes:/,/networks:/p'" >&2
  exit 1
fi

BOOT_VOLUME=""
FIRST_VOLUME=""
while IFS=$'\t' read -r VOLUME_NAME PVC_NAME; do
  [[ -n "${VOLUME_NAME}" && -n "${PVC_NAME}" ]] || continue
  if [[ -z "${FIRST_VOLUME}" ]]; then
    FIRST_VOLUME="${VOLUME_NAME}"
  fi
  LOWER="$(echo "${VOLUME_NAME}" | tr '[:upper:]' '[:lower:]')"
  case "${LOWER}" in
    *root*|*boot*|*os*|*system*)
      BOOT_VOLUME="${VOLUME_NAME}"
      break
      ;;
  esac
done < "${BUNDLE}/source-disks.tsv"

if [[ -z "${BOOT_VOLUME}" ]]; then
  BOOT_VOLUME="${FIRST_VOLUME}"
fi

echo "Selected boot volume: ${BOOT_VOLUME}"
echo "# role<TAB>volume_name<TAB>file<TAB>pvc_size<TAB>volume_mode" > "${BUNDLE}/disks.tsv"

while IFS=$'\t' read -r VOLUME_NAME PVC_NAME; do
  [[ -n "${VOLUME_NAME}" && -n "${PVC_NAME}" ]] || continue

  PVC_SIZE="$(oc get pvc "${PVC_NAME}" -n "${NS}" -o jsonpath='{.spec.resources.requests.storage}')"
  VOLUME_MODE="$(oc get pvc "${PVC_NAME}" -n "${NS}" -o jsonpath='{.spec.volumeMode}')"
  [[ -n "${VOLUME_MODE}" ]] || VOLUME_MODE="Filesystem"

  if [[ "${VOLUME_NAME}" == "${BOOT_VOLUME}" ]]; then
    ROLE="boot"
  else
    ROLE="data"
  fi

  FILE_NAME="${VOLUME_NAME}.raw"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${ROLE}" "${VOLUME_NAME}" "${FILE_NAME}" "${PVC_SIZE}" "${VOLUME_MODE}" \
    >> "${BUNDLE}/disks.tsv"
done < "${BUNDLE}/source-disks.tsv"

cat > "${BUNDLE}/release.env" <<EOF
APP_NAME="${VM}"
APP_ID="${SAFE_VM}"
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

if oc get virtualmachineexport "abc-vm-export-${SAFE_VERSION}" -n "${NS}" >/dev/null 2>&1; then
  virtctl vmexport delete "abc-vm-export-${SAFE_VERSION}" -n "${NS}" || true
fi

echo "Creating VM export ${EXPORT_NAME}..."
virtctl vmexport create "${EXPORT_NAME}" \
  --vm="${VM}" \
  --namespace="${NS}" \
  --ttl=24h

echo "Waiting for VM export ${EXPORT_NAME} to become Ready..."
if ! oc wait virtualmachineexport "${EXPORT_NAME}" -n "${NS}" \
    --for=jsonpath='{.status.phase}'=Ready \
    --timeout=30m; then
  oc describe virtualmachineexport "${EXPORT_NAME}" -n "${NS}" >&2 || true
  echo "ERROR: VirtualMachineExport ${NS}/${EXPORT_NAME} did not become Ready." >&2
  exit 1
fi

EXPORT_VOLUME_NAMES="$(oc get virtualmachineexport "${EXPORT_NAME}" -n "${NS}" \
  -o jsonpath='{range .status.links.internal.volumes[*]}{.name}{"\n"}{end}')"
if [[ -z "${EXPORT_VOLUME_NAMES}" ]]; then
  EXPORT_VOLUME_NAMES="$(oc get virtualmachineexport "${EXPORT_NAME}" -n "${NS}" \
    -o jsonpath='{range .status.links.external.volumes[*]}{.name}{"\n"}{end}')"
fi

echo "Export volumes:"
echo "${EXPORT_VOLUME_NAMES}"

while IFS=$'\t' read -r ROLE VOLUME_NAME FILE_NAME PVC_SIZE VOLUME_MODE; do
  [[ -n "${ROLE}" && "${ROLE}" != \#* ]] || continue

  CLAIM_NAME="$(awk -F '\t' -v vol="${VOLUME_NAME}" '$1==vol {print $2; exit}' "${BUNDLE}/source-disks.tsv")"
  DOWNLOAD_VOLUME="$(resolve_export_volume "${VOLUME_NAME}" "${EXPORT_VOLUME_NAMES}" "${CLAIM_NAME}" || true)"
  if [[ -z "${DOWNLOAD_VOLUME}" ]]; then
    echo "ERROR: Could not map VM volume ${VOLUME_NAME} to an export volume." >&2
    echo "Available export volumes:" >&2
    echo "${EXPORT_VOLUME_NAMES}" >&2
    exit 1
  fi

  OUTPUT_FILE="${BUNDLE}/${FILE_NAME}"
  echo "Downloading export volume ${DOWNLOAD_VOLUME} (VM volume ${VOLUME_NAME}) to ${OUTPUT_FILE}..."

  # Disconnected clusters usually have no virt-export Route. Port-forward
  # uses the in-cluster export service through the API server.
  virtctl vmexport download "${EXPORT_NAME}" \
    --namespace="${NS}" \
    --volume="${DOWNLOAD_VOLUME}" \
    --output="${OUTPUT_FILE}" \
    --format=raw \
    --keep-vme \
    --insecure \
    --port-forward \
    --readiness-timeout=30m

done < "${BUNDLE}/disks.tsv"

(
  cd "${BUNDLE}"
  sha256sum *.raw > checksums.sha256
)

if [[ -f "${SCRIPT_DIR}/seed-abc-vm-catalog.sh" ]]; then
  mkdir -p "${BUNDLE}/lib"
  cp "${SCRIPT_DIR}/seed-abc-vm-catalog.sh" "${BUNDLE}/"
  cp "${SCRIPT_DIR}/deploy-abc-vm.sh" "${BUNDLE}/" 2>/dev/null || true
  if [[ -f "${SCRIPT_DIR}/lib/oc-virtctl.sh" ]]; then
    cp "${SCRIPT_DIR}/lib/oc-virtctl.sh" "${BUNDLE}/lib/"
  fi
  chmod 0750 "${BUNDLE}/seed-abc-vm-catalog.sh" "${BUNDLE}/deploy-abc-vm.sh" 2>/dev/null || true
fi

if [[ "${KEEP_EXPORT}" != "true" ]]; then
  echo "Deleting temporary VM export ${EXPORT_NAME}..."
  virtctl vmexport delete "${EXPORT_NAME}" -n "${NS}" || true
fi

echo
echo "Bundle created successfully: ${BUNDLE}"
echo "Validate with:"
echo "  cd ${BUNDLE} && sha256sum -c checksums.sha256"
echo "Confirm the boot disk role in disks.tsv before transfer."
