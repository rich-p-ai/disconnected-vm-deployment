#!/usr/bin/env bash
# Shared helpers for source/destination cluster login and virtctl bootstrap.
# Sourced by build-abc-vm-package.sh and seed-abc-vm-catalog.sh.
# virtctl is pulled from the already-logged-in cluster (ConsoleCLIDownload),
# not from the Internet.

oc_login_if_requested() {
  if [[ -z "${OC_SERVER:-}" && -z "${OC_TOKEN:-}" && -z "${OC_USERNAME:-}" ]]; then
    return 0
  fi

  command -v oc >/dev/null 2>&1 || {
    echo "ERROR: oc is required before login." >&2
    exit 127
  }

  local login_args=()
  if [[ -n "${OC_SERVER:-}" ]]; then
    login_args+=(--server="${OC_SERVER}")
  fi
  if [[ "${OC_INSECURE:-false}" == "true" ]]; then
    login_args+=(--insecure-skip-tls-verify=true)
  fi

  if [[ -n "${OC_TOKEN:-}" ]]; then
    echo "Logging in to OpenShift with a token..."
    oc login --token="${OC_TOKEN}" "${login_args[@]}"
  elif [[ -n "${OC_USERNAME:-}" ]]; then
    echo "Logging in to OpenShift as ${OC_USERNAME}..."
    if [[ -n "${OC_PASSWORD:-}" ]]; then
      oc login -u "${OC_USERNAME}" -p "${OC_PASSWORD}" "${login_args[@]}"
    else
      oc login -u "${OC_USERNAME}" "${login_args[@]}"
    fi
  else
    echo "ERROR: --server was provided without --token or --username." >&2
    exit 2
  fi
}

ensure_logged_in() {
  if oc whoami >/dev/null 2>&1; then
    echo "Logged in as: $(oc whoami)"
    echo "Context: $(oc config current-context)"
    return 0
  fi

  echo "ERROR: Not logged in to OpenShift." >&2
  echo "Log in first, or pass --server and --token (or --username)." >&2
  echo "Example:" >&2
  echo "  oc login --server=https://api.cluster.example.com:6443 --token=<token>" >&2
  exit 1
}

virtctl_arch_label() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "${arch}" ;;
  esac
}

install_virtctl_from_cluster() {
  command -v oc >/dev/null 2>&1 || {
    echo "ERROR: oc is required to download virtctl from the cluster." >&2
    exit 127
  }
  command -v curl >/dev/null 2>&1 || {
    echo "ERROR: curl is required to download virtctl from the cluster." >&2
    exit 127
  }
  command -v tar >/dev/null 2>&1 || {
    echo "ERROR: tar is required to extract virtctl." >&2
    exit 127
  }

  local arch link_text url tmpdir virtctl_bin dest
  arch="$(virtctl_arch_label)"
  link_text="Download virtctl for Linux ${arch}"

  echo "Looking up cluster virtctl download for: ${link_text}"
  url="$(oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged \
    -o jsonpath="{.spec.links[?(@.text=='${link_text}')].href}" 2>/dev/null || true)"

  if [[ -z "${url}" ]]; then
    echo "ERROR: No virtctl download URL found for: ${link_text}" >&2
    echo "Available ConsoleCLIDownload links:" >&2
    oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged \
      -o jsonpath='{range .spec.links[*]}{.text}{"\n"}{end}' >&2 || true
    exit 1
  fi

  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmpdir}'" RETURN

  echo "Downloading virtctl from the cluster (not the Internet)..."
  curl -kL "${url}" -o "${tmpdir}/virtctl.bin"

  if tar -tzf "${tmpdir}/virtctl.bin" >/dev/null 2>&1; then
    tar -xzf "${tmpdir}/virtctl.bin" -C "${tmpdir}"
    virtctl_bin="$(find "${tmpdir}" -type f -name virtctl | head -n1)"
  else
    virtctl_bin="${tmpdir}/virtctl.bin"
    chmod 0755 "${virtctl_bin}"
  fi

  [[ -n "${virtctl_bin}" && -f "${virtctl_bin}" ]] || {
    echo "ERROR: virtctl binary not found in the downloaded package." >&2
    exit 1
  }

  dest="${HOME}/.local/bin"
  mkdir -p "${dest}"
  if [[ -w "${dest}" ]]; then
    install -m 0755 "${virtctl_bin}" "${dest}/virtctl"
    export PATH="${dest}:${PATH}"
    echo "Installed virtctl to ${dest}/virtctl"
  elif command -v sudo >/dev/null 2>&1; then
    sudo install -m 0755 "${virtctl_bin}" /usr/local/bin/virtctl
    echo "Installed virtctl to /usr/local/bin/virtctl"
  else
    echo "ERROR: Cannot write ${dest} and sudo is unavailable." >&2
    exit 1
  fi

  command -v virtctl >/dev/null 2>&1 || {
    echo "ERROR: virtctl installed but not on PATH. Add ${HOME}/.local/bin to PATH." >&2
    exit 1
  }

  virtctl version --client 2>/dev/null || virtctl version || true
}

ensure_virtctl() {
  if command -v virtctl >/dev/null 2>&1; then
    echo "virtctl found: $(command -v virtctl)"
    virtctl version --client 2>/dev/null || virtctl version || true
    return 0
  fi

  echo "virtctl is not installed. Installing from the current cluster..."
  install_virtctl_from_cluster
}
