#!/usr/bin/env bash
set -Eeuo pipefail

# Runs inside the destination-cluster Job: seed catalog (if needed) then deploy VM.
# Extracts one compressed disk at a time; never leaves full raw bundle on PVC.

WORK_DIR="${WORK_DIR:-/work}"
BUNDLE="${WORK_DIR}/bundle"
BIN_DIR="${WORK_DIR}/bin"
PATH="${BIN_DIR}:${PATH}"
export PATH

require_job_commands() {
  local command missing=()
  for command in bash oc awk cut grep sed gunzip gzip sha256sum virtctl; do
    command -v "${command}" >/dev/null 2>&1 || missing+=("${command}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Job is missing required commands: ${missing[*]}" >&2
    exit 127
  fi
}

strip_cr() {
  printf '%s' "$1" | tr -d '\r'
}

catalog_suffix() {
  local role="$1" volume_name="$2"
  if [[ "${role}" == "boot" ]]; then
    echo "boot"
  else
    echo "${volume_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
  fi
}

disk_suffix() {
  catalog_suffix "$@"
}

remove_target_disk() {
  local ns="$1" name="$2"
  oc delete dv "${name}" -n "${ns}" --ignore-not-found --wait=true || true
  oc delete pvc "${name}" -n "${ns}" --ignore-not-found --wait=true || true
}

wait_dv_succeeded() {
  local ns="$1" name="$2" timeout_secs="${3:-86400}"
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
    if oc get pods -n "${ns}" --no-headers 2>/dev/null | grep -E 'source-pod|clone' | grep -Eq 'CrashLoopBackOff|Error'; then
      echo "ERROR: CDI clone helper pod is failing in ${ns}." >&2
      oc get pods -n "${ns}" | grep -E 'source-pod|clone|upload' >&2 || true
      oc describe dv "${name}" -n "${ns}" >&2 || true
      return 1
    fi
    now="$(date +%s)"
    if (( now - start > timeout_secs )); then
      echo "ERROR: Timed out waiting for DataVolume ${ns}/${name}." >&2
      return 1
    fi
    echo "  ${ns}/${name} phase=${phase:-unknown}"
    sleep 20
  done
}

datasource_is_ready() {
  local ns="$1" name="$2"
  local ready
  ready="$(oc get datasource "${name}" -n "${ns}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "${ready}" == "True" ]]
}

gunzip_one_disk() {
  local gz_path="$1" raw_path="$2"
  rm -f "${raw_path}"
  echo "Decompressing ${gz_path} -> ${raw_path}..."
  gunzip -c "${gz_path}" > "${raw_path}"
}

upload_disk() {
  local target_ns="$1" dv_name="$2" image_path="$3" size="$4" volume_mode="$5"
  local mode_lower
  mode_lower="$(echo "${volume_mode}" | tr '[:upper:]' '[:lower:]')"

  [[ -f "${image_path}" ]] || {
    echo "ERROR: Missing image ${image_path}" >&2
    return 1
  }

  remove_target_disk "${target_ns}" "${dv_name}"

  echo "Uploading ${image_path} -> ${target_ns}/${dv_name}"
  virtctl image-upload dv "${dv_name}" \
    --namespace="${target_ns}" \
    --size="${size}" \
    --storage-class="${STORAGE_CLASS}" \
    --volume-mode="${mode_lower}" \
    --access-mode=ReadWriteOnce \
    --image-path="${image_path}" \
    --insecure \
    --wait-secs=86400
}

clone_disk_to_target() {
  local dv_name="$1" role="$2" suffix="$3" size="$4" volume_mode="$5"
  local mode_lower
  mode_lower="$(echo "${volume_mode}" | tr '[:upper:]' '[:lower:]')"

  if [[ "${role}" == "boot" ]]; then
    cat <<EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${dv_name}
  namespace: ${TARGET_NAMESPACE}
  annotations:
    cdi.kubevirt.io/storage.usePopulator: "true"
  labels:
    abcvm.io/app: "${APP_ID}"
    abcvm.io/version: "${VERSION}"
    abcvm.io/role: "${role}"
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
    volumeMode: ${mode_lower}
    resources:
      requests:
        storage: ${size}
EOF
  else
    local source_pvc="${RELEASE_ID}-${suffix}"
    oc get pvc "${source_pvc}" -n "${CATALOG_NAMESPACE}" >/dev/null || return 1
    cat <<EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${dv_name}
  namespace: ${TARGET_NAMESPACE}
  annotations:
    cdi.kubevirt.io/storage.usePopulator: "true"
  labels:
    abcvm.io/app: "${APP_ID}"
    abcvm.io/version: "${VERSION}"
    abcvm.io/role: "${role}"
    abcvm.io/vm: "${VM_NAME}"
spec:
  source:
    pvc:
      namespace: ${CATALOG_NAMESPACE}
      name: ${source_pvc}
  storage:
    storageClassName: ${STORAGE_CLASS}
    accessModes:
      - ReadWriteOnce
    volumeMode: ${mode_lower}
    resources:
      requests:
        storage: ${size}
EOF
  fi
}

provision_target_disk() {
  local ROLE="$1" VOLUME_NAME="$2" FILE_NAME="$3" PVC_SIZE="$4" VOLUME_MODE="$5"
  local SUFFIX TARGET_DV GZ_PATH RAW_PATH phase
  SUFFIX="$(disk_suffix "${ROLE}" "${VOLUME_NAME}")"
  TARGET_DV="${VM_NAME}-${SUFFIX}"
  GZ_PATH="${BUNDLE}/${FILE_NAME}"
  RAW_PATH="${BUNDLE}/.tmp-deploy-${SUFFIX}.raw"

  phase="$(oc get dv "${TARGET_DV}" -n "${TARGET_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Succeeded" ]]; then
    echo "Reusing ready disk ${TARGET_NAMESPACE}/${TARGET_DV}"
    return 0
  fi

  if oc get dv "${TARGET_DV}" -n "${TARGET_NAMESPACE}" >/dev/null 2>&1 || \
     oc get pvc "${TARGET_DV}" -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
    echo "Removing incomplete disk ${TARGET_NAMESPACE}/${TARGET_DV} (phase=${phase:-none})"
    remove_target_disk "${TARGET_NAMESPACE}" "${TARGET_DV}"
  fi

  echo "Trying CDI clone from catalog -> ${TARGET_NAMESPACE}/${TARGET_DV}..."
  if clone_disk_to_target "${TARGET_DV}" "${ROLE}" "${SUFFIX}" "${PVC_SIZE}" "${VOLUME_MODE}" && \
     wait_dv_succeeded "${TARGET_NAMESPACE}" "${TARGET_DV}" 1800; then
    echo "Clone succeeded for ${TARGET_NAMESPACE}/${TARGET_DV}"
  else
    echo "WARNING: CDI clone from catalog rejected or failed for ${TARGET_DV} (common on LVM/TopoLVM)."
    echo "Falling back to gunzip + virtctl image-upload from compressed bundle."
    remove_target_disk "${TARGET_NAMESPACE}" "${TARGET_DV}"
    gunzip_one_disk "${GZ_PATH}" "${RAW_PATH}"
    upload_disk "${TARGET_NAMESPACE}" "${TARGET_DV}" "${RAW_PATH}" "${PVC_SIZE}" "${VOLUME_MODE}"
    rm -f "${RAW_PATH}"
    wait_dv_succeeded "${TARGET_NAMESPACE}" "${TARGET_DV}" 86400
  fi

  oc label dv "${TARGET_DV}" -n "${TARGET_NAMESPACE}" \
    "abcvm.io/app=${APP_ID}" \
    "abcvm.io/version=${VERSION}" \
    "abcvm.io/role=${ROLE}" \
    "abcvm.io/vm=${VM_NAME}" \
    --overwrite >/dev/null 2>&1 || true
}

seed_catalog() {
  local RELEASE_ID="$1"
  echo "Seeding catalog namespace ${CATALOG_NAMESPACE}..."

  while IFS=$'\t' read -r ROLE VOLUME_NAME FILE_NAME PVC_SIZE VOLUME_MODE; do
    ROLE="$(strip_cr "${ROLE}")"
    VOLUME_NAME="$(strip_cr "${VOLUME_NAME}")"
    FILE_NAME="$(strip_cr "${FILE_NAME}")"
    PVC_SIZE="$(strip_cr "${PVC_SIZE}")"
    VOLUME_MODE="$(strip_cr "${VOLUME_MODE}")"
    [[ -n "${ROLE}" && "${ROLE}" != \#* ]] || continue
    [[ -n "${VOLUME_MODE}" ]] || VOLUME_MODE="Filesystem"

    local SUFFIX DV_NAME GZ_PATH RAW_PATH
    SUFFIX="$(catalog_suffix "${ROLE}" "${VOLUME_NAME}")"
    DV_NAME="${RELEASE_ID}-${SUFFIX}"
    GZ_PATH="${BUNDLE}/${FILE_NAME}"
    RAW_PATH="${BUNDLE}/.tmp-${SUFFIX}.raw"

    [[ -f "${GZ_PATH}" ]] || {
      echo "ERROR: Missing compressed disk ${GZ_PATH}" >&2
      exit 1
    }

    if oc get dv "${DV_NAME}" -n "${CATALOG_NAMESPACE}" >/dev/null 2>&1; then
      local PHASE
      PHASE="$(oc get dv "${DV_NAME}" -n "${CATALOG_NAMESPACE}" -o jsonpath='{.status.phase}')"
      if [[ "${PHASE}" == "Succeeded" ]]; then
        echo "Catalog DataVolume already ready: ${DV_NAME}"
        continue
      fi
      echo "ERROR: Catalog DataVolume ${DV_NAME} exists in phase ${PHASE}." >&2
      exit 1
    fi

    gunzip_one_disk "${GZ_PATH}" "${RAW_PATH}"
    upload_disk "${CATALOG_NAMESPACE}" "${DV_NAME}" "${RAW_PATH}" "${PVC_SIZE}" "${VOLUME_MODE}"
    rm -f "${RAW_PATH}"

    wait_dv_succeeded "${CATALOG_NAMESPACE}" "${DV_NAME}" 86400

    oc label pvc "${DV_NAME}" -n "${CATALOG_NAMESPACE}" \
      "abcvm.io/app=${APP_ID}" \
      "abcvm.io/version=${VERSION}" \
      "abcvm.io/role=${ROLE}" \
      --overwrite
  done < "${BUNDLE}/disks.tsv"

  local BOOT_DV_NAME="${RELEASE_ID}-boot"
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
    echo "ERROR: DataSource is not Ready." >&2
    exit 1
  fi
}

deploy_vm() {
  local DISK_FILE VOLUME_FILE
  DISK_FILE="$(mktemp)"
  VOLUME_FILE="$(mktemp)"
  trap 'rm -f "${DISK_FILE}" "${VOLUME_FILE}"' RETURN

  if oc get vm "${VM_NAME}" -n "${TARGET_NAMESPACE}" >/dev/null 2>&1; then
    echo "ERROR: VM ${TARGET_NAMESPACE}/${VM_NAME} already exists." >&2
    exit 1
  fi

  USE_UEFI="false"
  DISK_BUS="virtio"
  if [[ -f "${BUNDLE}/source-vm.yaml" ]] && grep -Eq 'efi:|bootloader:' "${BUNDLE}/source-vm.yaml"; then
    echo "Source VM uses UEFI; enabling EFI Secure Boot, SMM, and TPM."
    USE_UEFI="true"
    DISK_BUS="sata"
  fi

  echo "Deploying VM ${TARGET_NAMESPACE}/${VM_NAME} (catalog clone first, image-upload fallback)..."

  while IFS=$'\t' read -r ROLE VOLUME_NAME FILE_NAME PVC_SIZE VOLUME_MODE; do
    ROLE="$(strip_cr "${ROLE}")"
    VOLUME_NAME="$(strip_cr "${VOLUME_NAME}")"
    FILE_NAME="$(strip_cr "${FILE_NAME}")"
    PVC_SIZE="$(strip_cr "${PVC_SIZE}")"
    VOLUME_MODE="$(strip_cr "${VOLUME_MODE}")"
    [[ -n "${ROLE}" && "${ROLE}" != \#* ]] || continue
    [[ -n "${VOLUME_MODE}" ]] || VOLUME_MODE="Filesystem"

    local SUFFIX TARGET_DV VOL_NAME
    SUFFIX="$(disk_suffix "${ROLE}" "${VOLUME_NAME}")"
    TARGET_DV="${VM_NAME}-${SUFFIX}"
    VOL_NAME="${SUFFIX}"

    provision_target_disk "${ROLE}" "${VOLUME_NAME}" "${FILE_NAME}" "${PVC_SIZE}" "${VOLUME_MODE}"

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

  local VM_FILE="${BUNDLE}/generated-${VM_NAME}-vm.yaml"
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

  echo "Applying VM manifest..."
  oc apply -f "${VM_FILE}"

  if [[ "${START_VM}" == "true" ]]; then
    echo "Starting VM ${TARGET_NAMESPACE}/${VM_NAME}..."
    oc patch vm "${VM_NAME}" -n "${TARGET_NAMESPACE}" \
      --type=merge \
      -p '{"spec":{"running":true}}'
  else
    echo "VM created and left stopped: ${TARGET_NAMESPACE}/${VM_NAME}"
  fi

  oc get vm,dv,pvc -n "${TARGET_NAMESPACE}" -l "abcvm.io/vm=${VM_NAME}" 2>/dev/null || true
}

main() {
  : "${TARGET_NAMESPACE:?TARGET_NAMESPACE required}"
  : "${VM_NAME:?VM_NAME required}"
  : "${STORAGE_CLASS:?STORAGE_CLASS required}"
  : "${CATALOG_NAMESPACE:?CATALOG_NAMESPACE required}"
  : "${START_VM:=false}"

  require_job_commands
  [[ -d "${BUNDLE}" ]] || { echo "ERROR: Bundle dir ${BUNDLE} missing." >&2; exit 1; }
  [[ -f "${BUNDLE}/release.env" ]] || { echo "ERROR: Missing release.env" >&2; exit 1; }
  [[ -f "${BUNDLE}/disks.tsv" ]] || { echo "ERROR: Missing disks.tsv" >&2; exit 1; }
  [[ -f "${BUNDLE}/checksums.sha256" ]] || { echo "ERROR: Missing checksums.sha256" >&2; exit 1; }

  # shellcheck source=/dev/null
  source "${BUNDLE}/release.env"

  CPU_CORES="${VM_CPU_CORES:-4}"
  MEMORY="${VM_MEMORY:-8Gi}"
  RELEASE_ID="${APP_ID}-${VERSION//[^a-zA-Z0-9-]/-}"

  echo "Dest Job: release ${RELEASE_ID} -> VM ${TARGET_NAMESPACE}/${VM_NAME}"
  echo "Verifying checksums..."
  (
    cd "${BUNDLE}"
    sha256sum -c checksums.sha256
  )

  oc get storageclass "${STORAGE_CLASS}" >/dev/null
  oc get namespace "${TARGET_NAMESPACE}" >/dev/null

  if ! oc get namespace "${CATALOG_NAMESPACE}" >/dev/null 2>&1; then
    echo "ERROR: Catalog namespace ${CATALOG_NAMESPACE} does not exist." >&2
    exit 1
  fi

  if datasource_is_ready "${CATALOG_NAMESPACE}" "${RELEASE_ID}"; then
    echo "DataSource ${CATALOG_NAMESPACE}/${RELEASE_ID} is already Ready; skipping seed."
  else
    seed_catalog "${RELEASE_ID}"
  fi

  deploy_vm
  echo "Dest Job completed successfully."
}

main "$@"
