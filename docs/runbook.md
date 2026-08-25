# Runbook — disconnected OCP + OpenShift Virtualization

Ordered path. Commands are **placeholders**. Replace `registry.example.internal:8443`, versions, and paths. Never paste real pull secrets into tickets or git.

Official sequence: [Disconnected environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/index) → [oc-mirror v2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/about-installing-oc-mirror-v2) → [install disconnected](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/installing-disconnected-environments) → [OLM disconnected](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/olm-restricted-networks) → [install OpenShift Virtualization](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/installing).

## 0. Dry-run notes

- **oc-mirror:** `oc mirror -c imageset-config.yaml file://./oc-mirror-workspace --dry-run --v2` lists images in `working-dir/dry-run/mapping.txt` / `missing.txt`. **Fact:** [Performing a dry run for oc-mirror plugin v2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/about-installing-oc-mirror-v2).
- **Ansible:** `ansible-playbook -i ansible/inventory/hosts.yml.example ansible/playbooks/site.yml --check --tags dry_run` (see `ansible/`).
- **oc:** `oc apply --dry-run=server -f examples/` only **after** you have a cluster kubeconfig (gitignored).
- Do not `--dry-run` a live `openshift-install` and expect a cluster; ABI ISO generation is the real artifact.

## 1. Mirror (connected host)

```bash
# Placeholder — see scripts/oc-mirror-wrapper.sh
export AUTHFILE="${XDG_RUNTIME_DIR}/containers/auth.json"   # gitignored
umask 0022
oc mirror --v2 --help

# Fully disconnected: mirror to disk
./scripts/oc-mirror-wrapper.sh disk

# Partially disconnected: bastion can reach the registry
# ./scripts/oc-mirror-wrapper.sh mirror
```

**Fact:** Image set API `mirror.openshift.io/v2alpha1`. Include platform channel **and** `kubevirt-hyperconverged` in the same pin. Optional: `mtv-operator`.

Transfer the archive (USB/SFTP) into the air-gap if you used mirror-to-disk.

## 2. Registry (air-gap or dual-homed bastion)

Install **mirror registry for Red Hat OpenShift** or use existing Quay. Placeholder:

```bash
# Placeholder — follow the current mirror-registry install flags in:
# https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/installing-mirroring-creating-registry
# sudo ./mirror-registry install --quayHostname registry.example.internal ...
```

Then disk-to-mirror:

```bash
./scripts/oc-mirror-wrapper.sh publish
```

Keep the generated `working-dir/cluster-resources/` (IDMS, ITMS, CatalogSource).

## 3. Install the cluster

### 3a. Agent-based Installer (default air-gap)

**Fact:** [ABI disconnected mirroring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_an_on-premise_cluster_with_the_agent-based_installer/understanding-disconnected-installation-mirroring); [install with customizations](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_an_on-premise_cluster_with_the_agent-based_installer/installing-with-agent-based-installer).

In `install-config.yaml` set `additionalTrustBundle` (registry CA) and `imageContentSources` from oc-mirror / `oc adm release mirror` output. In `agent-config.yaml` set `rendezvousIP` to a control-plane host.

```bash
# Placeholder
./openshift-install agent create image --dir ./abi-input
# Boot hosts from the ISO. Wait:
# ./openshift-install --dir ./abi-input agent wait-for install-complete
```

### 3b. IPI disconnected (when the platform API is in-band)

**Fact:** Per-platform restricted-network IPI is listed in [Installing a cluster in a disconnected environment](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/installing-disconnected-environments). Same mirror + `imageContentSources` + CA. Example (vSphere): follow that platform's restricted-network IPI procedure — do not copy ROSA steps.

```bash
# Placeholder
./openshift-install create manifests --dir ./ipi-input
./openshift-install create cluster --dir ./ipi-input
```

Copy `kubeconfig` to a gitignored path. Run `./scripts/sanity-check.sh`.

## 4. Install OpenShift Virtualization (disconnected)

1. Apply oc-mirror cluster resources (IDMS/ITMS/CatalogSource).
2. Disable default OperatorHub sources.
3. Subscribe to `kubevirt-hyperconverged` from the **local** CatalogSource.
4. Create HyperConverged.

```bash
# Placeholders — edit examples/ first
oc apply -f examples/ImageDigestMirrorSet.yaml
oc apply -f examples/ImageTagMirrorSet.yaml
oc apply -f examples/CatalogSource.yaml

# Fact: disable default catalogs on restricted networks
# https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/olm-restricted-networks
oc patch OperatorHub cluster --type json \
  -p '[{"op":"add","path":"/spec/disableAllDefaultSources","value":true}]'

oc apply -f examples/Subscription-kubevirt-hyperconverged.yaml
# wait for CSV Succeeded, then:
oc apply -f examples/HyperConverged.yaml
oc get hco kubevirt-hyperconverged -n openshift-cnv
```

**Fact:** [Installing OpenShift Virtualization](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/installing).

## 5. First VM

Ensure a default virt storage class exists, then apply the example VM (placeholder disk image digest).

```bash
oc apply -f examples/VirtualMachine.yaml
oc get vm,vmi -n example
```

## 6. Optional MTV

Mirror `mtv-operator`, subscribe from the same CatalogSource, create `ForkliftController`. MTV 2.9.2+ for disconnected. Network path to the **source** hypervisor is still required.

## Ansible mapping

`ansible/playbooks/site.yml` tags: `mirror`, `registry`, `install`, `virt`, `vm`, `dry_run`. Inventory is `hosts.yml.example` with no real hosts.
