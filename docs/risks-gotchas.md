# Risks and gotchas

**Fact** vs **Inference** as labeled.

## Digest mismatch

**Fact:** OpenShift Virtualization and OCP release images are consumed by **digest**. IDMS maps digest pulls to the mirror. If the digest in a Subscription/CSV/release payload is not present on the mirror, pulls fail with manifest unknown / digest mismatch. oc-mirror v2 IDMS covers the **full** image set (unlike v1 ICSP incremental files). Do not hand-edit `spec.imageDigestMirrors`. [oc-mirror v2 CRs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/about-installing-oc-mirror-v2).

**Inference:** Re-mirror the **same** `ImageSetConfiguration` min/max versions after a failed apply; do not mix a 4.18.2 payload with 4.18.10 IDMS from a different run.

## Catalog skew

**Fact:** Default OperatorHub catalogs are remote. In restricted networks you disable them and point a CatalogSource at a mirrored index. [OLM disconnected](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/olm-restricted-networks).

**Inference:** An index tagged `v4.18` that was mirrored months ago can advertise CSVs whose related images were never copied (filtering + `full: false` heads). If CNV never becomes Available, diff CSV `relatedImages` against `oc mirror --dry-run` mapping.

## Release vs Operator index mismatch

**Fact:** Image set pins `mirror.platform.channels` (for example `stable-4.18`) separately from `mirror.operators.catalog` (`redhat-operator-index:v4.18`). [ImageSetConfiguration parameters](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/about-installing-oc-mirror-v2).

**Fact:** Install OpenShift Virtualization on the matching OCP minor; use channel `stable` so CNV tracks that OCP version. [Installing OpenShift Virtualization](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/installing).

**Inference:** Do not install CNV 4.18 on OCP 4.16 from a mixed image set. Keep channel, index tag, and `openshift-install` binary on the same 4.y (and the same z-stream when possible).

## VM storage class

**Fact:** Without a default storage class, CDI DataVolumes/PVCs stay Pending and automated boot sources do not import. Mark a virt default with `storageclass.kubevirt.io/is-default-virt-class=true`. Prefer **RWX** + **Block** for live migration; configure a storage profile if CDI does not recognize the provisioner. [Virt storage](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/storage); [Installing OpenShift Virtualization](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/installing).

## CPU models

**Fact:** If a VM uses **host model** CPU, **nodes must support that host model**. [Installing OpenShift Virtualization](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/installing).

**Inference:** Mixed CPU generations in the worker pool break live migration for host-model VMs. Pin an explicit `cpu.model` or keep a homogeneous virt worker pool. Confirm supported models with `oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv -o yaml` (cluster-specific; not a global Red Hat list).

## DNS / NTP in air-gap

**Fact:** Nodes must agree on time (TLS). Each node needs an NTP server; disconnected clusters can make control planes **chrony** servers (`local stratum 3 orphan`) and workers clients. UDP/123. [NTP disconnected](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_on_bare_metal/bare-metal-postinstallation-configuration); [IPI NTP/DNS](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_on_bare_metal/installer-provisioned-infrastructure).

**Fact:** CoreDNS needs TCP and UDP to upstream DNS. API/apps/node records must exist before install.

**Inference:** Public `*.rhel.pool.ntp.org` is unreachable in air-gap — never leave the default chrony pool.

## MTV warm vs cold (disconnected)

**Fact:** Cold = source VMs shut down for the whole copy (default). Warm = precopy while running via **CBT**, then cutover shutdown. Warm needs CBT on **each** source VM and disk; if CBT cannot be enabled, use cold. Warm is for vSphere/RHV sources. [Cold and warm migration](https://docs.redhat.com/en/documentation/migration_toolkit_for_virtualization/2.11/html/planning_your_migration_to_red_hat_openshift_virtualization/assembly_cold-warm-migration_mtv).

**Fact:** MTV 2.9.2 is the 2.9 line that works disconnected; earlier 2.9 did not. [MTV 2.9 release notes](https://docs.redhat.com/en/documentation/migration_toolkit_for_virtualization/2.9/html/release_notes/rn-29_release-notes).

**Inference:** Disconnected **catalogs** do not remove the need for a data path from source hypervisor to the target cluster. Warm precopy in a bandwidth-constrained air-gap can run for days and hit CBT snapshot limits — prefer cold unless downtime is unacceptable and CBT is proven.

## ICSP leftovers

**Fact:** ICSP is replaced by IDMS/ITMS. `oc adm migrate icsp` converts files. Deleting **all** ICSPs can remove unrelated policies. [Migrating oc-mirror v1 to v2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/oc-mirror-migration-v1-to-v2).
