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

Supports both export types:
  raw / gzip     KubeVirt disk image (preferred)
  dir / tar.gz   filesystem PVC export; disk.img is extracted from the tarball
EOF
}

require_base_commands() {
  local command
  for command in bash oc awk cut grep sed sha256sum find sort mkdir cp date tar; do
    command -v "${command}" >/dev/null 2>&1 || {
      echo "ERROR: Required command is missing: ${command}" >&2
      exit 127
    }
  done
}

k8s_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

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

has_format() {
  local formats=" $1 "
  local wanted="$2"
  echo "${formats}" | grep -Fq " ${wanted} "
}

is_skip_volume() {
  case "$1" in
    persistent-state*|*-persistent-state*) return 0 ;;
  esac
  return 1
}

export_formats_for() {
  local wanted="$1" info_file="$2" name formats
  while IFS=$'\t' read -r name formats; do
    [[ "${name}" == "${wanted}" ]] || continue
    echo "${formats}"
    return 0
  done < "${info_file}"
  return 1
}

# Prefer a name match on the PVC/DV, then the VM volume name.
# Accept raw/gzip first; fall back to tar.gz/dir filesystem exports.
pick_export_volume() {
  local wanted="$1"
  local claim="$2"
  local info_file="$3"
  local name formats

  for candidate in ${claim} ${wanted}; do
    [[ -n "${candidate}" ]] || continue
    while IFS=$'\t' read -r name formats; do
      [[ "${name}" == "${candidate}" ]] || continue
      if has_format "${formats}" raw || has_format "${formats}" gzip || \
         has_format "${formats}" tar.gz || has_format "${formats}" dir; then
        echo "${name}"
        return 0
      fi
    done < "${info_file}"
  done

  local match_count=0 match_name=""
  while IFS=$'\t' read -r name formats; do
    [[ -n "${name}" ]] || continue
    is_skip_volume "${name}" && continue
    match_count=$((match_count + 1))
    match_name="${name}"
  done < "${info_file}"

  if [[ "${match_count}" -eq 1 ]]; then
    echo "${match_name}"
    return 0
  fi
  return 1
}

extract_disk_from_archive() {
  local archive="$1"
  local dest="$2"
  local tmp
  tmp="$(mktemp -d "${BUNDLE}/.extract-XXXXXX")"

  echo "Extracting filesystem export ${archive}..."
  tar -xzf "${archive}" -C "${tmp}"

  local found=""
  found="$(find "${tmp}" -type f \( \
    -name 'disk.img' -o -name 'disk.img.gz' -o -name '*.raw' -o \
    -name '*.qcow2' -o -name 'disk' \
  \) | head -n1 || true)"

  if [[ -z "${found}" ]]; then
    found="$(find "${tmp}" -type f -size +64M | sort | head -n1 || true)"
  fi

  if [[ -z "${found}" ]]; then
    echo "ERROR: No disk image found in ${archive}" >&2
    find "${tmp}" -type f >&2 || true
    rm -rf "${tmp}"
    return 1
  fi

  echo "Found disk image in archive: ${found}"
  case "${found}" in
    *.gz)
      gzip -dc "${found}" > "${dest}"
      ;;
    *)
      cp -f "${found}" "${dest}"
      ;;
  esac
  rm -rf "${tmp}"
}

refresh_export_info() {
  local out="$1"
  oc get virtualmachineexport "${EXPORT_NAME}" -n "${NS}" \
    -o jsonpath='{range .status.links.internal.volumes[*]}{.name}{"\t"}{range .formats[*]}{.format}{" "}{end}{"\n"}{end}' \
    > "${out}"
  if [[ ! -s "${out}" ]]; then
    oc get virtualmachineexport "${EXPORT_NAME}" -n "${NS}" \
      -o jsonpath='{range .status.links.external.volumes[*]}{.name}{"\t"}{range .formats[*]}{.format}{" "}{end}{"\n"}{end}' \
      > "${out}"
  fi
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
    *root*|*boot*|*os*|*system*|*c-drive*|*cdrive*)
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

EXPORT_INFO="${BUNDLE}/export-volumes.tsv"
echo "Waiting for export volume links..."
for _ in $(seq 1 30); do
  refresh_export_info "${EXPORT_INFO}"
  if [[ -s "${EXPORT_INFO}" ]]; then
    break
  fi
  sleep 5
done

echo "Export volumes:"
cat "${EXPORT_INFO}" || true

if [[ ! -s "${EXPORT_INFO}" ]]; then
  echo "ERROR: VirtualMachineExport is Ready but published no volume links." >&2
  oc get virtualmachineexport "${EXPORT_NAME}" -n "${NS}" -o yaml >&2 || true
  exit 1
fi

while IFS=$'\t' read -r ROLE VOLUME_NAME FILE_NAME PVC_SIZE VOLUME_MODE; do
  [[ -n "${ROLE}" && "${ROLE}" != \#* ]] || continue

  CLAIM_NAME="$(awk -F '\t' -v vol="${VOLUME_NAME}" '$1==vol {print $2; exit}' "${BUNDLE}/source-disks.tsv")"
  DOWNLOAD_VOLUME="$(pick_export_volume "${VOLUME_NAME}" "${CLAIM_NAME}" "${EXPORT_INFO}" || true)"
  if [[ -z "${DOWNLOAD_VOLUME}" ]]; then
    echo "ERROR: Could not map VM volume ${VOLUME_NAME} (PVC/DV ${CLAIM_NAME}) to an export volume." >&2
    echo "Available export volumes:" >&2
    cat "${EXPORT_INFO}" >&2
    exit 1
  fi

  FORMATS="$(export_formats_for "${DOWNLOAD_VOLUME}" "${EXPORT_INFO}" || true)"
  OUTPUT_FILE="${BUNDLE}/${FILE_NAME}"
  echo "Downloading export volume ${DOWNLOAD_VOLUME} [${FORMATS}] (VM volume ${VOLUME_NAME}, claim ${CLAIM_NAME})"

  if has_format "${FORMATS}" raw || has_format "${FORMATS}" gzip; then
    virtctl vmexport download "${EXPORT_NAME}" \
      --namespace="${NS}" \
      --volume="${DOWNLOAD_VOLUME}" \
      --output="${OUTPUT_FILE}" \
      --format=raw \
      --keep-vme \
      --insecure \
      --port-forward \
      --readiness-timeout=30m
  else
    ARCHIVE="${BUNDLE}/${DOWNLOAD_VOLUME}.tar.gz"
    virtctl vmexport download "${EXPORT_NAME}" \
      --namespace="${NS}" \
      --volume="${DOWNLOAD_VOLUME}" \
      --output="${ARCHIVE}" \
      --keep-vme \
      --insecure \
      --port-forward \
      --readiness-timeout=30m
    extract_disk_from_archive "${ARCHIVE}" "${OUTPUT_FILE}"
  fi

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
