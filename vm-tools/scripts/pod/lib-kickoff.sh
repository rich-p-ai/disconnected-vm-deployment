#!/usr/bin/env bash
# Shared helpers for pod kickoff scripts (build + dest).
# Sourced by kickoff-build.sh and kickoff-dest.sh.

require_kickoff_commands() {
  local command
  for command in bash oc awk cut grep sed mktemp du find zstd; do
    command -v "${command}" >/dev/null 2>&1 || {
      echo "ERROR: Required command is missing: ${command}" >&2
      exit 127
    }
  done
}

ensure_logged_in() {
  if oc whoami >/dev/null 2>&1; then
    echo "Logged in as: $(oc whoami)"
    echo "Context: $(oc config current-context)"
    return 0
  fi
  echo "ERROR: Not logged in to OpenShift. Run oc login on the bastion first." >&2
  exit 1
}

quantity_to_bytes() {
  local qty="$1"
  local num unit
  qty="$(printf '%s' "${qty}" | tr -d '[:space:]')"
  if [[ "${qty}" =~ ^[0-9]+$ ]]; then
    echo "${qty}"
    return 0
  fi
  if [[ "${qty}" =~ ^([0-9]+(\.[0-9]+)?)([EPTGMK]i?)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"
  else
    echo "ERROR: Invalid storage quantity: ${qty}" >&2
    return 1
  fi
  awk -v n="${num}" -v u="${unit}" '
    BEGIN {
      mult["E"]=1024^6; mult["P"]=1024^5; mult["T"]=1024^4;
      mult["G"]=1024^3; mult["M"]=1024^2; mult["K"]=1024;
      mult["Ei"]=1024^6; mult["Pi"]=1024^5; mult["Ti"]=1024^4;
      mult["Gi"]=1024^3; mult["Mi"]=1024^2; mult["Ki"]=1024;
      printf "%.0f", n * mult[u]
    }'
}

bytes_to_gi() {
  local bytes="$1"
  awk -v b="${bytes}" 'BEGIN { printf "%dGi", int((b + 1024^3 - 1) / (1024^3)) }'
}

compute_source_pvc_bytes() {
  local ns="$1" vm="$2"
  local tmp total=0 size
  tmp="$(mktemp)"
  oc get vm "${vm}" -n "${ns}" \
    -o jsonpath='{range .spec.template.spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\t"}{.dataVolume.name}{"\n"}{end}' \
    | while IFS=$'\t' read -r pvc_name dv_name; do
        local claim="${pvc_name:-${dv_name}}"
        [[ -n "${claim}" ]] || continue
        size="$(oc get pvc "${claim}" -n "${ns}" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)"
        [[ -n "${size}" ]] || continue
        quantity_to_bytes "${size}"
      done > "${tmp}"
  while read -r line; do
    [[ -n "${line}" ]] || continue
    total=$((total + line))
  done < "${tmp}"
  rm -f "${tmp}"
  echo "${total}"
}

largest_disk_bytes_from_tsv() {
  local tsv="$1"
  local max=0 size bytes
  while IFS=$'\t' read -r _ _ _ PVC_SIZE _; do
    [[ -n "${PVC_SIZE}" && "${PVC_SIZE}" != \#* ]] || continue
    bytes="$(quantity_to_bytes "${PVC_SIZE}")"
    if (( bytes > max )); then
      max="${bytes}"
    fi
  done < "${tsv}"
  echo "${max}"
}

resolve_job_image() {
  local image=""
  image="$(oc get istag cli:latest -n openshift -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)"
  if [[ -n "${image}" ]]; then
    echo "${image}"
    return 0
  fi
  image="$(oc get is cli -n openshift -o jsonpath='{.status.tags[?(@.tag=="latest")].items[0].dockerImageReference}' 2>/dev/null || true)"
  if [[ -n "${image}" ]]; then
    echo "${image}"
    return 0
  fi
  image="image-registry.openshift-image-registry.svc:5000/openshift/cli:latest"
  if oc run --dry-run=client -o json --image="${image}" test-cli-check >/dev/null 2>&1; then
    echo "${image}"
    return 0
  fi
  local ns deploy
  for ns in openshift-cnv kubevirt-hyperconverged; do
    deploy="$(oc get deploy -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
      | awk -F '\t' '$1 ~ /virt-operator|cdi-deployment|cdi-operator/ {print $2; exit}')"
    if [[ -n "${deploy}" ]]; then
      echo "${deploy}"
      return 0
    fi
  done
  echo "ERROR: Could not resolve a Job container image." >&2
  exit 1
}

render_template() {
  local tpl="$1" out="$2"
  shift 2
  local content
  content="$(cat "${tpl}")"
  while [[ $# -gt 0 ]]; do
    local key="${1%%=*}"
    local val="${1#*=}"
    content="${content//__${key}__/${val}}"
    shift
  done
  printf '%s\n' "${content}" > "${out}"
}

wait_for_pvc_bound() {
  local ns="$1" pvc="$2" timeout="${3:-600}"
  echo "Waiting for PVC ${ns}/${pvc} to bind..."
  if ! oc wait pvc "${pvc}" -n "${ns}" --for=jsonpath='{.status.phase}'=Bound --timeout="${timeout}s"; then
    oc describe pvc "${pvc}" -n "${ns}" >&2 || true
    echo "ERROR: PVC ${ns}/${pvc} did not bind." >&2
    return 1
  fi
}

wait_for_job_complete() {
  local ns="$1" job="$2" timeout="${3:-86400}"
  echo "Waiting for Job ${ns}/${job} to complete (timeout ${timeout}s)..."
  if ! oc wait job "${job}" -n "${ns}" --for=condition=complete --timeout="${timeout}s"; then
    echo "Job did not complete successfully. Recent logs:" >&2
    oc logs "job/${job}" -n "${ns}" --tail=200 >&2 || true
    oc describe job "${job}" -n "${ns}" >&2 || true
    echo "ERROR: Job ${ns}/${job} failed." >&2
    return 1
  fi
  return 0
}

stream_job_logs() {
  local ns="$1" job="$2"
  local i
  echo "Streaming logs for job/${job}..."
  for i in $(seq 1 120); do
    if oc logs "job/${job}" -n "${ns}" --tail=1 >/dev/null 2>&1; then
      oc logs -f "job/${job}" -n "${ns}" || true
      return 0
    fi
    sleep 2
  done
  echo "WARNING: Job pod not ready for log streaming yet; continuing to wait." >&2
}

apply_staging_pod() {
  local ns="$1" pvc="$2" sa="$3" image="$4" staging_pod="$5"
  oc delete pod "${staging_pod}" -n "${ns}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${staging_pod}
  namespace: ${ns}
spec:
  restartPolicy: Never
  serviceAccountName: ${sa}
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    fsGroup: 1001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: stage
      image: ${image}
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 1001
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
      volumeMounts:
        - name: work
          mountPath: /work
  volumes:
    - name: work
      persistentVolumeClaim:
        claimName: ${pvc}
EOF
  local i
  for i in $(seq 1 60); do
    if oc get pod "${staging_pod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; then
      break
    fi
    sleep 2
  done
}

ensure_writable_dir() {
  local dir="$1"
  if ! mkdir -p "${dir}" 2>/dev/null; then
    echo "ERROR: This bastion account cannot create ${dir}." >&2
    echo "Do not use /home/data unless you own it." >&2
    echo "Use a folder you can write, for example:" >&2
    echo "  --transfer-dir /tmp/vm-transfer" >&2
    echo "  --transfer-dir ${HOME}/vm-transfer" >&2
    exit 1
  fi
  if [[ ! -w "${dir}" ]]; then
    echo "ERROR: ${dir} exists but is not writable by $(id -un)." >&2
    echo "Use --transfer-dir /tmp/vm-transfer" >&2
    exit 1
  fi
}

stage_virtctl_on_pvc() {
  local ns="$1" pvc="$2" sa="$3" image="$4" staging_pod="$5"
  local script_dir repo_root virtctl_path tmpdir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/../.." && pwd)"
  if [[ -f "${repo_root}/scripts/lib/oc-virtctl.sh" ]]; then
    source "${repo_root}/scripts/lib/oc-virtctl.sh"
    ensure_virtctl
    virtctl_path="$(command -v virtctl)"
  elif command -v virtctl >/dev/null 2>&1; then
    virtctl_path="$(command -v virtctl)"
  else
    virtctl_path=""
  fi
  if [[ -z "${virtctl_path}" ]]; then
    local cnv_pod
    cnv_pod="$(oc get pods -n openshift-cnv -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E 'virt-operator|virt-api' | head -n1 || true)"
    if [[ -n "${cnv_pod}" ]]; then
      tmpdir="$(mktemp -d)"
      if oc exec -n openshift-cnv "${cnv_pod}" -- which virtctl >/dev/null 2>&1; then
        oc exec -n openshift-cnv "${cnv_pod}" -- cat "$(oc exec -n openshift-cnv "${cnv_pod}" -- which virtctl)" > "${tmpdir}/virtctl"
        chmod 0755 "${tmpdir}/virtctl"
        virtctl_path="${tmpdir}/virtctl"
      fi
    fi
  fi
  [[ -n "${virtctl_path}" && -f "${virtctl_path}" ]] || {
    echo "ERROR: virtctl could not be resolved on the bastion or from a cluster pod." >&2
    exit 1
  }
  echo "Staging virtctl and zstd onto PVC via pod ${staging_pod}..."
  apply_staging_pod "${ns}" "${pvc}" "${sa}" "${image}" "${staging_pod}"
  oc exec "${staging_pod}" -n "${ns}" -- mkdir -p /work/bin
  oc cp "${virtctl_path}" "${ns}/${staging_pod}:/work/bin/virtctl"
  oc exec "${staging_pod}" -n "${ns}" -- chmod 0755 /work/bin/virtctl
  local zstd_path
  zstd_path="$(command -v zstd || true)"
  if [[ -z "${zstd_path}" ]]; then
    echo "ERROR: zstd is not installed on this bastion. Install it with: sudo dnf install -y zstd" >&2
    delete_staging_pod "${ns}" "${staging_pod}"
    exit 1
  fi
  oc cp "${zstd_path}" "${ns}/${staging_pod}:/work/bin/zstd"
  oc exec "${staging_pod}" -n "${ns}" -- chmod 0755 /work/bin/zstd
  delete_staging_pod "${ns}" "${staging_pod}"
  echo "virtctl and zstd staged at /work/bin on PVC ${pvc}"
}

delete_staging_pod() {
  local ns="$1" pod="$2"
  oc delete pod "${pod}" -n "${ns}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
}

create_job_pvc() {
  local ns="$1" pvc="$2" size="$3" sc="$4"
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
  namespace: ${ns}
  labels:
    abcvm.io/component: pod-job
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  storageClassName: ${sc}
  resources:
    requests:
      storage: ${size}
EOF
}

create_configmap_from_script() {
  local ns="$1" cm="$2" script_path="$3"
  oc create configmap "${cm}" -n "${ns}" \
    --from-file="$(basename "${script_path}")=${script_path}" \
    --dry-run=client -o yaml | oc apply -f -
}

copy_pvc_to_local() {
  local ns="$1" pvc="$2" sa="$3" image="$4" staging_pod="$5" local_dir="$6"
  ensure_writable_dir "${local_dir}"
  apply_staging_pod "${ns}" "${pvc}" "${sa}" "${image}" "${staging_pod}"
  local remote_list base
  remote_list="$(oc exec "${staging_pod}" -n "${ns}" -- sh -c 'ls -1 /work/bundle 2>/dev/null' || true)"
  [[ -n "${remote_list}" ]] || { echo "ERROR: No files found in /work/bundle on Job PVC." >&2; exit 1; }
  while IFS= read -r base; do
    [[ -n "${base}" ]] || continue
    case "${base}" in
      *.raw) echo "ERROR: Refusing to copy raw disk ${base} to bastion." >&2; exit 1 ;;
    esac
    echo "Copying ${base} -> ${local_dir}/"
    oc cp "${ns}/${staging_pod}:/work/bundle/${base}" "${local_dir}/${base}"
  done <<< "${remote_list}"
  delete_staging_pod "${ns}" "${staging_pod}"
}

copy_local_to_pvc() {
  local ns="$1" pvc="$2" sa="$3" image="$4" staging_pod="$5" local_dir="$6"
  if find "${local_dir}" -maxdepth 1 -name '*.raw' -print -quit | grep -q .; then
    echo "ERROR: Refusing to copy raw disk files from ${local_dir}." >&2
    exit 1
  fi
  apply_staging_pod "${ns}" "${pvc}" "${sa}" "${image}" "${staging_pod}"
  oc exec "${staging_pod}" -n "${ns}" -- mkdir -p /work/bundle
  local f base
  for f in "${local_dir}"/*; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    case "${base}" in
      *.raw) echo "ERROR: Refusing to copy raw disk ${base}." >&2; exit 1 ;;
    esac
    echo "Copying ${base} -> PVC..."
    oc cp "${f}" "${ns}/${staging_pod}:/work/bundle/${base}"
  done
  delete_staging_pod "${ns}" "${staging_pod}"
}

print_usb_instructions() {
  local transfer_dir="$1"
  cat <<EOF

=== USB / sneaker-net transfer ===
1. On this bastion, verify checksums:
     cd ${transfer_dir} && sha256sum -c checksums.sha256
2. Copy the entire directory to removable media:
     rsync -a ${transfer_dir}/ /media/usb/vm-bundle/
3. Carry media to the destination bastion.
4. Copy from media to a local bundle path, then run ./dest --bundle-path <dir>.

NAS/NFS volume mounts are not supported in this release.

EOF
}

fail_if_exists() {
  local kind="$1" ns="$2" name="$3"
  if oc get "${kind}" "${name}" -n "${ns}" >/dev/null 2>&1; then
    echo "ERROR: ${kind}/${name} already exists in ${ns}." >&2
    echo "Delete it before retrying:" >&2
    echo "  ./cleanup --namespace ${ns}" >&2
    exit 1
  fi
}

k8s_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr '.' '-' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

run_cleanup() {
  local ns="${1:-}"
  local script
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/cleanup"
  chmod 0750 "${script}" 2>/dev/null || true
  if [[ ! -f "${script}" ]]; then
    echo "WARNING: cleanup script not found at ${script}" >&2
    return 0
  fi
  echo "Cleaning leftover build/dest Jobs..."
  if [[ -n "${ns}" ]]; then
    bash "${script}" --namespace "${ns}" || true
  else
    bash "${script}" || true
  fi
}
