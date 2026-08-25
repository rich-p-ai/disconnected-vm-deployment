#!/usr/bin/env bash
# Placeholder sanity checks. Safe to run without a cluster (skips oc checks).
# Does not print secrets.
set -euo pipefail

fail=0
say() { printf '%s\n' "$*"; }
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    say "MISSING: $1"
    fail=1
  else
    say "OK: $1 -> $(command -v "$1")"
  fi
}

say "== tooling =="
need oc
need ansible-playbook || true
if command -v oc >/dev/null 2>&1; then
  if oc mirror --v2 --help >/dev/null 2>&1; then
    say "OK: oc-mirror plugin v2"
  else
    say "MISSING: oc-mirror plugin v2 (oc mirror --v2 --help failed)"
    fail=1
  fi
fi

say "== placeholder config =="
for f in scripts/imageset-config.yaml.example examples/CatalogSource.yaml examples/HyperConverged.yaml; do
  if [[ -f "$f" ]]; then
    say "OK: $f"
  else
    say "MISSING: $f"
    fail=1
  fi
done

if [[ -f pull-secret.json ]]; then
  say "WARN: pull-secret.json present locally (gitignored). Do not commit it."
fi

if [[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]]; then
  say "== cluster (KUBECONFIG set) =="
  oc get imagedigestmirrorset || fail=1
  oc get imagetagmirrorset || true
  oc get catalogsource -n openshift-marketplace || fail=1
  oc get hco -n openshift-cnv || true
else
  say "SKIP: cluster checks (KUBECONFIG unset)"
fi

exit "${fail}"
