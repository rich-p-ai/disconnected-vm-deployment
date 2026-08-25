# Problem and decision (one page)

**Engagement:** deploy and run VMs with OpenShift Virtualization where the cluster has **no live access** to Red Hat/Quay/`registry.redhat.io` at install or Operator install time.

Statements are labeled **Fact** (official docs) or **Inference** (engagement judgment).

## Problem

A disconnected / air-gapped site must:

1. Install self-managed OpenShift Container Platform from mirrored content.
2. Install OpenShift Virtualization from a local OLM catalog.
3. Run (and optionally migrate) VMs without reaching public registries.

## Decision 1 — Agent-based Installer vs IPI disconnected

| Method | When it fits | Notes |
| --- | --- | --- |
| **Agent-based Installer (ABI)** | On-prem / bare metal / air-gap; no BMC orchestration required | **Fact:** ABI combines Assisted Installer UX with offline/air-gapped operation and generates a bootable ISO (`openshift-install agent create image`). See [Preparing to install with the Agent-based Installer](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_an_on-premise_cluster_with_the_agent-based_installer/preparing-to-install-with-agent-based-installer) and [disconnected mirroring for ABI](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_an_on-premise_cluster_with_the_agent-based_installer/understanding-disconnected-installation-mirroring). |
| **IPI disconnected** | Platform APIs available (vSphere, Nutanix, selected clouds) and you want the installer to provision machines | **Fact:** Restricted-network IPI is documented per platform; you still mirror release content and set `imageContentSources` / trust bundle. Index: [Installing a cluster in a disconnected environment](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/installing-disconnected-environments). **Inference:** IPI on public cloud still needs that cloud's APIs; that is not a fully air-gapped control plane. |

**Recommendation (Inference):** default to **ABI** for true air-gap / bare metal. Use **IPI disconnected** when the hypervisor or platform API is in-band and already approved.

**Fact:** Both paths require a Docker V2-2 mirror registry reachable from every cluster node. Preferred mirroring tool is **oc-mirror plugin v2** (`--v2`). [Disconnected environments](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/index); [oc-mirror plugin v2](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/disconnected_environments/about-installing-oc-mirror-v2).

## Decision 2 — Self-managed disconnected OCP+Virt vs ROSA

| Option | Control plane | Fit for this engagement |
| --- | --- | --- |
| **Self-managed disconnected OCP + OpenShift Virtualization** | You own etcd/API in the air-gap | **Primary path.** |
| **ROSA (hosted control planes)** | **Fact:** Control plane components (API server, etcd) are hosted in a **Red Hat-owned AWS account**. Workers are in the customer AWS account and talk to the control plane over AWS PrivateLink. [ROSA architecture models](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/rosa-architecture-models). | **Not** an air-gapped self-managed cluster. |
| **ROSA classic** | **Fact:** Control plane still runs as a Red Hat-managed service in the **customer** AWS account, not in the customer air-gap. Same architecture page. | Same exclusion. |
| **ROSA egress-zero** | **Fact:** Pulls Red Hat images from regional AWS ECR over VPC endpoints; still an AWS-hosted managed service. [Creating ROSA clusters with egress zero](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_rosa_with_hcp_clusters/rosa-hcp-egress-zero-install). | Restricted AWS, not a customer air-gap. |

**Inference:** cite ROSA only to explain why it is out of scope. Do not reuse ROSA/HCP runbooks here.

## Optional MTV

**Fact:** Install OpenShift Virtualization in a restricted environment by configuring OLM for disconnected networks. [Installing OpenShift Virtualization](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/installing).

**Fact:** MTV 2.9.2 added disconnected/offline support (earlier 2.9 did not). [MTV 2.9 release notes](https://docs.redhat.com/en/documentation/migration_toolkit_for_virtualization/2.9/html/release_notes/rn-29_release-notes). Mirror `mtv-operator` into the same catalog as CNV.

**Inference:** MTV is optional inbound landing, not the product of this repo.

## Default decision

**Self-managed disconnected OCP (ABI unless platform IPI is justified) + mirrored CNV/HCO + first VM. MTV optional.**
