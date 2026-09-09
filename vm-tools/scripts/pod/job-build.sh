#!/usr/bin/env bash
set -Eeuo pipefail

# Runs inside the source-cluster Build Job. Exports VM disks, compresses to gzip,
# writes bundle metadata. Never leaves uncompressed raw on the Job PVC.

WORK_DIR="${WORK_DIR:-/work}"
BUNDLE="${WORK_DIR}/bundle"
BIN_DIR="${WORK_DIR}/bin"
PATH="${BIN_DIR}:${PATH}"
export PATH

require_job_commands() {
  local command missing=()
  for command in bash oc awk cut grep sed sha256sum find sort mkdir date tar gzip virtctl; do
    command -v "${command}" >/dev/null 2>&1 || missing+=("${command}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Job is missing required commands: ${missing[*]}" >&2
    exit 127
  fi
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

pick_export_volume() {
  local wanted="$1" claim="$2" info_file="$3"
  local name formats candidate

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
  local archive="$1" dest="$2"
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
    rm -rf "${tmp}"
    return 1
  fi

  case "${found}" in
    *.gz) gzip -dc "${found}" > "${dest}" ;;
    *) cp -f "${found}" "${dest}" ;;
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

download_and_compress_raw() {
  local export_vol="$1" output_gz="$2"
  local tmp_raw="${BUNDLE}/.tmp-download.raw"
  local pf_args=()

  rm -f "${tmp_raw}" "${output_gz}"

  if virtctl vmexport download "${EXPORT_NAME}" \
      --namespace="${NS}" \
      --volume="${export_vol}" \
      --output="${tmp_raw}" \
      --format=raw \
      --keep-vme \
      --insecure \
      --readiness-timeout=30m 2>/dev/null; then
    :
  else
    echo "In-cluster download failed; retrying with port-forward..."
    pf_args=(--port-forward)
    virtctl vmexport download "${EXPORT_NAME}" \
      --namespace="${NS}" \
      --volume="${export_vol}" \
      --output="${tmp_raw}" \
      --format=raw \
      --keep-vme \
      --insecure \
      --readiness-timeout=30m \
      "${pf_args[@]}"
  fi

  echo "Compressing ${export_vol} -> ${output_gz}..."
  gzip -c "${tmp_raw}" > "${output_gz}"
  rm -f "${tmp_raw}"
}

download_filesystem_and_compress() {
  local export_vol="$1" output_gz="$2"
  local archive="${BUNDLE}/.tmp-${export_vol}.tar.gz"
  local tmp_raw="${BUNDLE}/.tmp-extract.raw"

  rm -f "${archive}" "${tmp_raw}" "${output_gz}"

  if ! virtctl vmexport download "${EXPORT_NAME}" \
      --namespace="${NS}" \
      --volume="${export_vol}" \
      --output="${archive}" \
      --keep-vme \
      --insecure \
      --readiness-timeout=30m 2>/dev/null; then
    virtctl vmexport download "${EXPORT_NAME}" \
      --namespace="${NS}" \
      --volume="${export_vol}" \
      --output="${archive}" \
      --keep-vme \
      --insecure \
      --port-forward \
      --readiness-timeout=30m
  fi

  extract_disk_from_archive "${archive}" "${tmp_raw}"
  rm -f "${archive}"
  gzip -c "${tmp_raw}" > "${output_gz}"
  rm -f "${tmp_raw}"
}

main() {
  : "${NS:?NS required}"
  : "${VM:?VM required}"
  : "${VERSION:?VERSION required}"
  : "${KEEP_EXPORT:=false}"

  require_job_commands
  mkdir -p "${BUNDLE}"

  SAFE_VM="$(k8s_name "${VM}")"
  SAFE_VERSION="$(k8s_name "${VERSION}")"
  RELEASE_ID="${SAFE_VM}-${SAFE_VERSION}"
  EXPORT_NAME="${RELEASE_ID}"

  echo "Build Job: source ${NS}/${VM} release ${RELEASE_ID}"
  oc get vm "${VM}" -n "${NS}" >/dev/null

  if oc get vmi "${VM}" -n "${NS}" >/dev/null 2>&1; then
    echo "Stopping VM ${NS}/${VM}..."
    virtctl stop "${VM}" -n "${NS}"
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
    exit 1
  fi

  BOOT_VOLUME=""
  FIRST_VOLUME=""
  while IFS=$'\t' read -r VOLUME_NAME PVC_NAME; do
    [[ -n "${VOLUME_NAME}" && -n "${PVC_NAME}" ]] || continue
    [[ -z "${FIRST_VOLUME}" ]] && FIRST_VOLUME="${VOLUME_NAME}"
    LOWER="$(echo "${VOLUME_NAME}" | tr '[:upper:]' '[:lower:]')"
    case "${LOWER}" in
      *root*|*boot*|*os*|*system*|*c-drive*|*cdrive*)
        BOOT_VOLUME="${VOLUME_NAME}"
        break
        ;;
    esac
  done < "${BUNDLE}/source-disks.tsv"
  [[ -n "${BOOT_VOLUME}" ]] || BOOT_VOLUME="${FIRST_VOLUME}"
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
    FILE_NAME="${VOLUME_NAME}.raw.gz"
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

  echo "Waiting for VM export to become Ready..."
  if ! oc wait virtualmachineexport "${EXPORT_NAME}" -n "${NS}" \
      --for=jsonpath='{.status.phase}'=Ready \
      --timeout=30m; then
    echo "ERROR: VirtualMachineExport did not become Ready." >&2
    exit 1
  fi

  EXPORT_INFO="${BUNDLE}/export-volumes.tsv"
  for _ in $(seq 1 30); do
    refresh_export_info "${EXPORT_INFO}"
    [[ -s "${EXPORT_INFO}" ]] && break
    sleep 5
  done
  [[ -s "${EXPORT_INFO}" ]] || {
    echo "ERROR: Export published no volume links." >&2
    exit 1
  }

  while IFS=$'\t' read -r ROLE VOLUME_NAME FILE_NAME PVC_SIZE VOLUME_MODE; do
    [[ -n "${ROLE}" && "${ROLE}" != \#* ]] || continue
    CLAIM_NAME="$(awk -F '\t' -v vol="${VOLUME_NAME}" '$1==vol {print $2; exit}' "${BUNDLE}/source-disks.tsv")"
    DOWNLOAD_VOLUME="$(pick_export_volume "${VOLUME_NAME}" "${CLAIM_NAME}" "${EXPORT_INFO}" || true)"
    [[ -n "${DOWNLOAD_VOLUME}" ]] || {
      echo "ERROR: Could not map volume ${VOLUME_NAME} to export volume." >&2
      exit 1
    }
    FORMATS="$(export_formats_for "${DOWNLOAD_VOLUME}" "${EXPORT_INFO}" || true)"
    OUTPUT_GZ="${BUNDLE}/${FILE_NAME}"
    echo "Exporting ${DOWNLOAD_VOLUME} [${FORMATS}] -> ${FILE_NAME}"

    if has_format "${FORMATS}" raw || has_format "${FORMATS}" gzip; then
      download_and_compress_raw "${DOWNLOAD_VOLUME}" "${OUTPUT_GZ}"
    else
      download_filesystem_and_compress "${DOWNLOAD_VOLUME}" "${OUTPUT_GZ}"
    fi
  done < "${BUNDLE}/disks.tsv"

  rm -f "${BUNDLE}/export-volumes.tsv" "${BUNDLE}/.tmp-"* "${BUNDLE}/.extract-"* 2>/dev/null || true

  (
    cd "${BUNDLE}"
    shopt -s nullglob
    files=(*.raw.gz)
    shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then
      echo "ERROR: No compressed disk files produced." >&2
      exit 1
    fi
    sha256sum "${files[@]}" > checksums.sha256
  )

  if [[ "${KEEP_EXPORT}" != "true" ]]; then
    echo "Deleting VM export ${EXPORT_NAME}..."
    virtctl vmexport delete "${EXPORT_NAME}" -n "${NS}" || true
  fi

  echo "Build Job completed. Bundle at ${BUNDLE}"
  ls -la "${BUNDLE}"
}

main "$@"
