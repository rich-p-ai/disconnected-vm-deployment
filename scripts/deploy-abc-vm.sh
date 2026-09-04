#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  deploy-abc-vm.sh \
    --bundle <vm-bundle-directory> \
    --namespace <target-namespace> \
    --vm-name <new-vm-name> \
    --storage-class <target-storage-class> \
    [--catalog-namespace <namespace>] \
    [--cpu-cores <count>] \
    [--memory <quantity>] \
    [--start]

On LVM/TopoLVM, disks are always created with virtctl image-upload.
CDI host-assisted clones and populators are skipped: they crash on
lost+found or hang Pending. The script does not patch CDI to run as root.
EOF
}

require_commands() {
  local command
  for command in bash oc awk cut grep sed; do
    command -v "${command}" >/dev/null 2>&1 || {
      echo "ERROR: Required command is missing: ${command}" >&2
      exit 127
    }
  done
}

strip_cr() {
  printf '%s' "$1" | tr -d '\r'
}

disk_suffix() {
  local role="$1" volume_name="$2"
  if [[ "${role}" == "boot" ]]; then
    echo "boot"
  else
    echo "${volume_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
  fi
}

storage_is_lvm() {
  local provisioner
  provisioner="$(oc get storageclass "${STORAGE_CLASS}" -o jsonpath='{.provisioner}' 2>/dev/null || true)"
  echo "${provisioner} ${STORAGE_CLASS}" | grep -Eiq 'topolvm|lvm|lvms|logicalvolume'
}

has_snapshot_class() {
  oc get volumesnapshotclass >/dev/null 2>&1 && \
    [[ -n "$(oc get volumesnapshotclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)" ]]
}

remove_target_disk() {
  local name="$1"
  oc delete dv "${name}" -n "${TARGET_NAMESPACE}" --ignore-not-found --wait=true || true
  oc delete pvc "${name}" -n "${TARGET_NAMESPACE}" --ignore-not-found --wait=true || true
}

wait_dv_succeeded() {
  local ns="$1" name="$2" timeout_secs="${3:-7200}"
  local start now phase
  start="$(date +%s)"
  while true; do
    phase="$(oc get dv "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "Succeeded" ]]; then
      return 0
    fi
    if [[ "${phase}" == "Failed" ]]; then
      oc describe dv "${name}" -n "${ns}" >&2 || true
      return 1
    fi
    now="$(date +%s)"
    if (( now - start > timeout_secs )); then
      echo "ERROR: Timed out waiting for DataVolume ${ns}/${name} (phase=${phase:-unknown})." >&2
      oc describe dv "${name}" -n "${ns}" >&2 || true
      return 1
    fi
    echo "  ${ns}/${name} phase=${phase:-unknown}"
    sleep 20
  done
}

upload_disk() {
  local dv_name="$1" image_path="$2" size="$3" volume_mode="$4" role="$5"
  local mode_lower
  mode_lower="$(echo "${volume_mode}" | tr '[:upper:]' '[:lower:]')"

  [[ -f "${image_path}" ]] || {
    echo "ERROR: Missing bundle image ${image_path}" >&2
    return 1
  }

  remove_target_disk "${dv_name}"

  echo "Uploading ${image_path} -> ${TARGET_NAMESPACE}/${dv_name}"
  virtctl image-upload dv "${dv_name}" \
    --namespace="${TARGET_NAMESPACE}" \
    --size="${size}" \
    --storage-class="${STORAGE_CLASS}" \
    --volume-mode="${mode_lower}" \
    --access-mode=ReadWriteOnce \
    --image-path="${image_path}" \
    --insecure \
    --wait-secs=86400

  oc label dv "${dv_name}" -n "${TARGET_NAMESPACE}" \
    "abcvm.io/app=${APP_ID}" \
    "abcvm.io/version=${VERSION}" \
    "abcvm.io/role=${role}" \
    "abcvm.io/vm=${VM_NAME}" \
    --overwrite >/dev/null 2>&1 || true
}

BUNDLE=""
TARGET_NAMESPACE=""
VM_NAME=""
STORAGE_CLASS=""
CATALOG_NAMESPACE_OVERRIDE=""
CPU_OVERRIDE=""
MEMORY_OVERRIDE=""
START_VM="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2 ;;
    --namespace) TARGET_NAMESPACE="$2"; shift 2 ;;
    --vm-name) VM_NAME="$2"; shift 2 ;;
    --storage-class) STORAGE_CLASS="$2"; shift 2 ;;
    --catalog-namespace) CATALOG_NAMESPACE_OVERRIDE="$2"; shift 2 ;;
    --cpu-cores) CPU_OVERRIDE="$2"; shift 2 ;;
    --memory) MEMORY_OVERRIDE="$2"; shift 2 ;;
    --start) START_VM="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

require_commands

[[ -n "${BUNDLE}" && -n "${TARGET_NAMESPACE}" && -n "${VM_NAME}" && -n "${STORAGE_CLASS}" ]] || {
  usage
  exit 2
}

[[ -f "${BUNDLE}/release.env" ]] || { echo "ERROR: Missing release.env" >&2; exit 1; }
[[ -f "${BUNDLE}/disks.tsv" ]] || { echo "ERROR: Missing disks.tsv" >&2; exit 1; }

source "${BUNDLE}/release.env"

CATALOG_NAMESPACE="${CATALOG_NAMESPACE_OVERRIDE:-${CATALOG_NAMESPACE:-vm-catalog}}"
RELEASE_ID="${APP_ID}-${VERSION//[^a-zA-Z0-9-]/-}"
CPU_CORES="${CPU_OVERRIDE:-${VM_CPU_CORES}}"
MEMORY="${MEMORY_OVERRIDE:-${VM_MEMORY}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/oc-virtctl.sh" ]]; then
  # shellcheck source=lib/oc-virtctl.sh
  source "${SCRIPT_DIR}/lib/oc-virtctl.sh"
  ensure_logged_in
  ensure_virtctl
else
  oc whoami >/dev/null
  command -v virtctl >/dev/null 2>&1 || {
    echo "ERROR: virtctl is required for image-upload." >&2
    exit 127
  }
fi

oc get namespace "${TARGET_NAMESPACE}" >/dev/null
oc get storageclass "${STORAGE_CLASS}" >/dev/null

if oc get vm "${VM_NAME}" -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: VM ${TARGET_NAMESPACE}/${VM_NAME} already exists." >&2
  exit 1
fi

if storage_is_lvm; then
  echo "Storage class ${STORAGE_CLASS} is LVM/TopoLVM. Using virtctl image-upload (no CDI clone)."
else
  echo "Provisioning disks with virtctl image-upload."
fi

USE_UEFI="false"
DISK_BUS="virtio"
if [[ -f "${BUNDLE}/source-vm.yaml" ]] && grep -Eq 'efi:|bootloader:' "${BUNDLE}/source-vm.yaml"; then
  echo "Source VM uses UEFI; enabling EFI Secure Boot, SMM, and TPM on the target VM."
  USE_UEFI="true"
  DISK_BUS="sata"
fi

echo "Target context: $(oc config current-context)"
echo "Target namespace: ${TARGET_NAMESPACE}"
echo "VM name: ${VM_NAME}"

DISK_FILE="$(mktemp)"
VOLUME_FILE="$(mktemp)"
trap 'rm -f "${DISK_FILE}" "${VOLUME_FILE}"' EXIT

while IFS=$'\t' read -r ROLE VOLUME_NAME FILE_NAME PVC_SIZE VOLUME_MODE; do
  ROLE="$(strip_cr "${ROLE}")"
  VOLUME_NAME="$(strip_cr "${VOLUME_NAME}")"
  FILE_NAME="$(strip_cr "${FILE_NAME}")"
  PVC_SIZE="$(strip_cr "${PVC_SIZE}")"
  VOLUME_MODE="$(strip_cr "${VOLUME_MODE}")"
  [[ -n "${ROLE}" && "${ROLE}" != \#* ]] || continue
  [[ -n "${VOLUME_MODE}" ]] || VOLUME_MODE="Filesystem"

  SUFFIX="$(disk_suffix "${ROLE}" "${VOLUME_NAME}")"
  TARGET_DV="${VM_NAME}-${SUFFIX}"
  VOL_NAME="${SUFFIX}"
  IMAGE_PATH="${BUNDLE}/${FILE_NAME}"

  phase="$(oc get dv "${TARGET_DV}" -n "${TARGET_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Succeeded" ]]; then
    echo "Reusing ready disk ${TARGET_NAMESPACE}/${TARGET_DV}"
  else
    if oc get dv "${TARGET_DV}" -n "${TARGET_NAMESPACE}" >/dev/null 2>&1 || \
       oc get pvc "${TARGET_DV}" -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
      echo "Removing incomplete disk ${TARGET_NAMESPACE}/${TARGET_DV} (phase=${phase:-none})"
      remove_target_disk "${TARGET_DV}"
    fi
    upload_disk "${TARGET_DV}" "${IMAGE_PATH}" "${PVC_SIZE}" "${VOLUME_MODE}" "${ROLE}"
    wait_dv_succeeded "${TARGET_NAMESPACE}" "${TARGET_DV}" 86400
  fi

  cat >> "${VOLUME_FILE}" <<EOF
        - name: ${VOL_NAME}
          persistentVolumeClaim:
            claimName: ${TARGET_DV}
EOF

  if [[ "${ROLE}" == "boot" ]]; then
    cat >> "${DISK_FILE}" <<EOF
            - name: ${VOL_NAME}
              disk:
                bus: ${DISK_BUS}
              bootOrder: 1
EOF
  else
    cat >> "${DISK_FILE}" <<EOF
            - name: ${VOL_NAME}
              disk:
                bus: ${DISK_BUS}
EOF
  fi
done < "${BUNDLE}/disks.tsv"

VM_FILE="${BUNDLE}/generated-${VM_NAME}-vm.yaml"
{
  cat <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${TARGET_NAMESPACE}
  labels:
    abcvm.io/app: "${APP_ID}"
    abcvm.io/version: "${VERSION}"
spec:
  running: false
  template:
    metadata:
      labels:
        kubevirt.io/domain: ${VM_NAME}
        abcvm.io/app: "${APP_ID}"
        abcvm.io/version: "${VERSION}"
    spec:
      domain:
        cpu:
          cores: ${CPU_CORES}
        resources:
          requests:
            memory: "${MEMORY}"
EOF
  if [[ "${USE_UEFI}" == "true" ]]; then
    cat <<'EOF'
        firmware:
          bootloader:
            efi:
              secureBoot: true
        features:
          smm:
            enabled: true
        tpm: {}
EOF
  fi
  cat <<'EOF'
        devices:
          disks:
EOF
  cat "${DISK_FILE}"
  cat <<'EOF'
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
EOF
  cat "${VOLUME_FILE}"
} > "${VM_FILE}"

echo "Applying VM manifest ${VM_FILE}"
oc apply -f "${VM_FILE}"

if [[ "${START_VM}" == "true" ]]; then
  echo "Starting VM ${TARGET_NAMESPACE}/${VM_NAME}..."
  oc patch vm "${VM_NAME}" -n "${TARGET_NAMESPACE}" \
    --type=merge \
    -p '{"spec":{"running":true}}'
else
  echo "VM created and left stopped: ${TARGET_NAMESPACE}/${VM_NAME}"
  echo "Start it after review with:"
  echo "  virtctl start vm ${VM_NAME} -n ${TARGET_NAMESPACE}"
fi

echo
echo "Deployment completed."
oc get vm,dv,pvc -n "${TARGET_NAMESPACE}" -l "abcvm.io/vm=${VM_NAME}" 2>/dev/null || true
