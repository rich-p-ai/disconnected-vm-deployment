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

oc whoami >/dev/null
oc get namespace "${TARGET_NAMESPACE}" >/dev/null
oc get namespace "${CATALOG_NAMESPACE}" >/dev/null
oc get storageclass "${STORAGE_CLASS}" >/dev/null

if oc get vm "${VM_NAME}" -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: VM ${TARGET_NAMESPACE}/${VM_NAME} already exists." >&2
  exit 1
fi

if ! oc get datasource "${RELEASE_ID}" -n "${CATALOG_NAMESPACE}" >/dev/null 2>&1; then
  echo "ERROR: Catalog DataSource ${CATALOG_NAMESPACE}/${RELEASE_ID} not found. Run seed first." >&2
  exit 1
fi

echo "Waiting for catalog DataSource ${CATALOG_NAMESPACE}/${RELEASE_ID} to become Ready..."
if ! oc wait datasource "${RELEASE_ID}" -n "${CATALOG_NAMESPACE}" --for=condition=Ready --timeout=15m; then
  oc describe datasource "${RELEASE_ID}" -n "${CATALOG_NAMESPACE}" >&2 || true
  echo "ERROR: Catalog DataSource ${CATALOG_NAMESPACE}/${RELEASE_ID} is not Ready." >&2
  exit 1
fi

USE_UEFI="false"
DISK_BUS="virtio"
if [[ -f "${BUNDLE}/source-vm.yaml" ]] && grep -Eq 'efi:|bootloader:' "${BUNDLE}/source-vm.yaml"; then
  echo "Source VM uses UEFI; enabling EFI firmware and TPM on the target VM."
  USE_UEFI="true"
  DISK_BUS="sata"
fi

echo "Target context: $(oc config current-context)"
echo "Target namespace: ${TARGET_NAMESPACE}"
echo "VM name: ${VM_NAME}"
echo "Catalog namespace: ${CATALOG_NAMESPACE}"
echo "Using DataSource: ${RELEASE_ID}"

DISK_FILE="$(mktemp)"
VOLUME_FILE="$(mktemp)"
trap 'rm -f "${DISK_FILE}" "${VOLUME_FILE}"' EXIT

while IFS=$'\t' read -r ROLE VOLUME_NAME FILE_NAME PVC_SIZE VOLUME_MODE; do
  ROLE="$(strip_cr "${ROLE}")"
  VOLUME_NAME="$(strip_cr "${VOLUME_NAME}")"
  PVC_SIZE="$(strip_cr "${PVC_SIZE}")"
  VOLUME_MODE="$(strip_cr "${VOLUME_MODE}")"
  [[ -n "${ROLE}" && "${ROLE}" != \#* ]] || continue

  SUFFIX="$(disk_suffix "${ROLE}" "${VOLUME_NAME}")"
  TARGET_DV="${VM_NAME}-${SUFFIX}"
  VOL_NAME="${SUFFIX}"

  if ! oc get dv "${TARGET_DV}" -n "${TARGET_NAMESPACE}" >/dev/null 2>&1 && \
     ! oc get pvc "${TARGET_DV}" -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
    if [[ "${ROLE}" == "boot" ]]; then
      cat <<EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${TARGET_DV}
  namespace: ${TARGET_NAMESPACE}
  labels:
    abcvm.io/app: "${APP_ID}"
    abcvm.io/version: "${VERSION}"
    abcvm.io/role: "${ROLE}"
    abcvm.io/vm: "${VM_NAME}"
spec:
  sourceRef:
    kind: DataSource
    name: ${RELEASE_ID}
    namespace: ${CATALOG_NAMESPACE}
  storage:
    storageClassName: ${STORAGE_CLASS}
    accessModes:
      - ReadWriteOnce
    volumeMode: ${VOLUME_MODE}
    resources:
      requests:
        storage: ${PVC_SIZE}
EOF
    else
      SOURCE_PVC="${RELEASE_ID}-${SUFFIX}"
      oc get pvc "${SOURCE_PVC}" -n "${CATALOG_NAMESPACE}" >/dev/null || {
        echo "ERROR: Source catalog PVC does not exist: ${CATALOG_NAMESPACE}/${SOURCE_PVC}" >&2
        exit 1
      }
      cat <<EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${TARGET_DV}
  namespace: ${TARGET_NAMESPACE}
  labels:
    abcvm.io/app: "${APP_ID}"
    abcvm.io/version: "${VERSION}"
    abcvm.io/role: "${ROLE}"
    abcvm.io/vm: "${VM_NAME}"
spec:
  source:
    pvc:
      namespace: ${CATALOG_NAMESPACE}
      name: ${SOURCE_PVC}
  storage:
    storageClassName: ${STORAGE_CLASS}
    accessModes:
      - ReadWriteOnce
    volumeMode: ${VOLUME_MODE}
    resources:
      requests:
        storage: ${PVC_SIZE}
EOF
    fi
  else
    echo "Reusing existing disk ${TARGET_NAMESPACE}/${TARGET_DV}"
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

while IFS=$'\t' read -r ROLE VOLUME_NAME FILE_NAME PVC_SIZE VOLUME_MODE; do
  ROLE="$(strip_cr "${ROLE}")"
  VOLUME_NAME="$(strip_cr "${VOLUME_NAME}")"
  [[ -n "${ROLE}" && "${ROLE}" != \#* ]] || continue
  SUFFIX="$(disk_suffix "${ROLE}" "${VOLUME_NAME}")"
  TARGET_DV="${VM_NAME}-${SUFFIX}"

  echo "Waiting for cloned DataVolume ${TARGET_NAMESPACE}/${TARGET_DV}..."
  oc wait dv "${TARGET_DV}" -n "${TARGET_NAMESPACE}" \
    --for=jsonpath='{.status.phase}'=Succeeded \
    --timeout=4h
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
            efi: {}
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
cat "${VM_FILE}"
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
