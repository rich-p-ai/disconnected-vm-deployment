# Disconnected prerequisites (checklist)

All values are **placeholders**. Do not put real hostnames, accounts, or secrets in this repository.

Legend: **Fact** = required by Red Hat docs. **Inference** = engagement hygiene.

## Subscription and content (connected host only)

- [ ] OpenShift subscription entitling OCP + OpenShift Virtualization. **Inference:** MTV needs its own entitlement if used.
- [ ] Pull secret downloaded to a **local gitignored** file (copy from `examples/pull-secret.json.example`). **Fact:** oc-mirror needs registry credentials; do not use the mirror-write auth file as the cluster install pull secret. [oc-mirror v2 credentials](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/about-installing-oc-mirror-v2).
- [ ] `oc` CLI and `oc-mirror` plugin v2 on `PATH`. Verify: `oc mirror --v2 --help`.
- [ ] `umask 0022` on the oc-mirror host. **Fact:** [oc-mirror v2 prerequisites](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/about-installing-oc-mirror-v2).
- [ ] Pin: OCP channel `stable-4.y`, Operator index `redhat-operator-index:v4.y`, CNV `kubevirt-hyperconverged` matching that minor.

## Mirror registry

- [ ] Registry FQDN placeholder: `registry.example.internal:8443`.
- [ ] Docker V2-2 registry: Quay **or** mirror registry for Red Hat OpenShift. [Creating a mirror registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/installing-mirroring-creating-registry).
- [ ] TLS CA available as a file (not committed). Cluster `additionalTrustBundle` / IDMS path will consume it.
- [ ] Disk sized for release + Operator catalogs + virt images. **Inference:** plan hundreds of GiB; measure with `oc mirror --dry-run --v2`.
- [ ] **Every** future cluster node can route to the registry. **Fact:** unreachable registry breaks install and day-2. [oc-mirror v2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/about-installing-oc-mirror-v2).

## Network, DNS, NTP (air-gap)

- [ ] Cluster name / baseDomain placeholders: `example` / `example.internal`.
- [ ] DNS A/AAAA + PTR for `api`, `api-int`, `*.apps`, and nodes. **Fact:** CoreDNS needs TCP **and** UDP to upstream DNS. [IPI bare metal DNS](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_on_bare_metal/installer-provisioned-infrastructure).
- [ ] NTP reachable (UDP/123) **or** control-plane nodes configured as local chrony servers. **Fact:** [NTP for disconnected clusters](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_on_bare_metal/bare-metal-postinstallation-configuration).
- [ ] No default route to the internet from cluster nodes (air-gap test).

## Cluster sizing for virtualization

- [ ] Topology: SNO, compact (3), or HA. **Fact:** ABI disconnected supports those topologies. [Preparing to install with ABI](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_an_on-premise_cluster_with_the_agent-based_installer/preparing-to-install-with-agent-based-installer).
- [ ] Worker CPU/RAM/storage for VM workloads. **Fact:** virt has explicit CPU overhead and storage-class requirements. [Installing OpenShift Virtualization](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/installing).
- [ ] Default virt storage class planned (`storageclass.kubevirt.io/is-default-virt-class=true`). RWX + Block preferred for live migration. [Virt storage](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/storage).
- [ ] CPU model / host-passthrough policy agreed with hardware. See [risks-gotchas.md](risks-gotchas.md).

## Installer artifacts

- [ ] `openshift-install` matching the mirrored z-stream (ABI and/or IPI).
- [ ] RHCOS / agent ISO build host with space for ISO generation.
- [ ] SSH public key (not a private key) for `install-config.yaml`.
- [ ] Install pull secret for **read** from the mirror (separate from oc-mirror write credentials).

## Optional MTV

- [ ] MTV 2.9.2+ (disconnected support). [MTV 2.9 release notes](https://docs.redhat.com/en/documentation/migration_toolkit_for_virtualization/2.9/html/release_notes/rn-29_release-notes).
- [ ] Source provider network path to the target cluster (ports per provider). [MTV network prerequisites](https://docs.redhat.com/en/documentation/migration_toolkit_for_virtualization/2.9/html/installing_and_using_the_migration_toolkit_for_virtualization/prerequisites-for-all-providers_mtv).
- [ ] Warm vs cold decision (CBT on source disks for warm). [Cold and warm migration](https://docs.redhat.com/en/documentation/migration_toolkit_for_virtualization/2.11/html/planning_your_migration_to_red_hat_openshift_virtualization/assembly_cold-warm-migration_mtv).
