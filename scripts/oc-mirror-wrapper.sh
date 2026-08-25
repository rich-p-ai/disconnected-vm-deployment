#!/usr/bin/env bash
# Placeholder wrapper for oc-mirror plugin v2.
# Fact: https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/about-installing-oc-mirror-v2
# Does not embed credentials. AUTHFILE must already exist and is gitignored.
set -euo pipefail

CONFIG="${OC_MIRROR_CONFIG:-scripts/imageset-config.yaml.example}"
WORKSPACE="${OC_MIRROR_WORKSPACE:-./oc-mirror-workspace}"
REGISTRY="${MIRROR_REGISTRY:-docker://registry.example.internal:8443}"
MODE="${1:-help}"

if [[ -n "${AUTHFILE:-}" ]]; then
  AUTH_ARGS=(--authfile "${AUTHFILE}")
else
  AUTH_ARGS=()
fi

usage() {
  cat <<'EOF'
Usage: scripts/oc-mirror-wrapper.sh <dry-run|disk|mirror|publish>

  dry-run  oc mirror --dry-run --v2 (no images copied)
  disk     mirror-to-disk (connected host, fully disconnected workflow)
  mirror   mirror-to-mirror (bastion can reach internet AND registry)
  publish  disk-to-mirror (--from workspace to registry)

Environment:
  OC_MIRROR_CONFIG      default scripts/imageset-config.yaml.example
  OC_MIRROR_WORKSPACE   default ./oc-mirror-workspace
  MIRROR_REGISTRY       default docker://registry.example.internal:8443
  AUTHFILE              optional path to containers auth.json (gitignored)
EOF
}

need_oc_mirror() {
  if ! command -v oc >/dev/null 2>&1; then
    echo "oc not on PATH" >&2
    exit 1
  fi
  oc mirror --v2 --help >/dev/null
}

case "${MODE}" in
  help|-h|--help)
    usage
    ;;
  dry-run)
    need_oc_mirror
    oc mirror "${AUTH_ARGS[@]}" -c "${CONFIG}" "file://${WORKSPACE}" --dry-run --v2
    ;;
  disk)
    need_oc_mirror
    oc mirror "${AUTH_ARGS[@]}" -c "${CONFIG}" "file://${WORKSPACE}" --v2
    ;;
  mirror)
    need_oc_mirror
    oc mirror "${AUTH_ARGS[@]}" -c "${CONFIG}" --workspace "file://${WORKSPACE}" "${REGISTRY}" --v2
    ;;
  publish)
    need_oc_mirror
    oc mirror "${AUTH_ARGS[@]}" -c "${CONFIG}" --from "file://${WORKSPACE}" "${REGISTRY}" --v2
    ;;
  *)
    usage
    exit 1
    ;;
esac
