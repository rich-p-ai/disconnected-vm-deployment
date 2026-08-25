# disconnected-vm-deployment

Two complementary layers for **disconnected OpenShift Virtualization**:

1. **Platform landing zone** (this PR): deploy self-managed OpenShift + OpenShift Virtualization with **no live access** to Red Hat registries at install or Operator install time.
2. **ABC VM client package** (already on `main`): once a cluster exists, a platform engineer packages a VM and end users clone it from a catalog namespace.

This is a consulting starter, not a turnkey installer. Public repo: no secrets.

## What this is

- A path to **mirror → registry → install cluster → install OpenShift Virtualization (CNV) → first VM** in a fully or partially disconnected environment.
- Primary install methods: **Agent-based Installer (ABI)** and **installer-provisioned infrastructure (IPI) disconnected / restricted-network**.
- Optional: **Migration Toolkit for Virtualization (MTV)** as a disconnected path to *land* VMs onto that cluster — not a migration factory.
- After the platform exists, the **ABC VM** builder/end-user guides and bastion scripts package and clone a catalog VM.

## What this is not

- **Not** a duplicate of `mtv-vm-migration-aap`, `virt-rosa-cluster`, or `vm-migration-factory`.
- **Not** a ROSA (Red Hat OpenShift Service on AWS) engagement. ROSA hosted control planes run in a Red Hat-owned AWS account and are not an air-gapped self-managed control plane. See [docs/problem-decision.md](docs/problem-decision.md).
- **Not** a connected install, a proxy-only install, or a production catalog of customer hostnames.
- **Not** a place to store pull secrets, kubeconfigs, disk images, or registry credentials.

## Audience

- Platform engineers standing up a disconnected OCP + OpenShift Virtualization landing zone.
- Platform engineers packaging an ABC VM, and cluster users deploying that catalog image.

## Flow (platform)

1. Connected bastion (or isolated mirror host) pulls content from Red Hat.
2. `oc-mirror` plugin **v2** writes an image set to disk or to a reachable registry.
3. Air-gapped cluster nodes pull only from the **internal mirror registry**.
4. Cluster uses **ImageDigestMirrorSet (IDMS)** / **ImageTagMirrorSet (ITMS)** (ICSP is legacy).
5. Disconnected **OLM CatalogSource** installs OpenShift Virtualization; then **HyperConverged (HCO)**.
6. First VM; optional MTV from a mirrored catalog.
7. Optional: package an ABC VM into `vm-catalog` and clone it into user projects.

Platform details: [docs/runbook.md](docs/runbook.md). Topology: [docs/architecture.md](docs/architecture.md).

## Documentation

### Disconnected platform (OCP + Virt)

| Doc | Purpose |
| --- | --- |
| [docs/problem-decision.md](docs/problem-decision.md) | ABI vs IPI disconnected; self-managed vs ROSA. **Fact** vs **Inference**. |
| [docs/architecture.md](docs/architecture.md) | Bastion, air-gap, mirror registry, oc-mirror, IDMS/ITMS, OLM, CNV, HCO, RHCOS, optional MTV. |
| [docs/disconnected-prerequisites.md](docs/disconnected-prerequisites.md) | Checklist with placeholders only. |
| [docs/runbook.md](docs/runbook.md) | Ordered steps and dry-run notes. Placeholder commands. |
| [docs/risks-gotchas.md](docs/risks-gotchas.md) | Digest mismatch, catalog skew, storage class, CPU models, DNS/NTP, MTV warm vs cold. |

Starters: `ansible/`, `scripts/oc-mirror-wrapper.sh`, `scripts/sanity-check.sh`, `examples/`.

### ABC VM client package

| Reader | Document |
| --- | --- |
| Platform engineer packaging the appliance | [Builder guide](docs/builder-guide.md) |
| Cluster user deploying a VM | [End-user deployment guide](docs/end-user-deployment.md) |

| Script | Role |
| --- | --- |
| [`scripts/build-abc-vm-package.sh`](scripts/build-abc-vm-package.sh) | Export a stopped source VM into a versioned bundle |
| [`scripts/seed-abc-vm-catalog.sh`](scripts/seed-abc-vm-catalog.sh) | Upload bundle disks once into the protected `vm-catalog` namespace |
| [`scripts/deploy-abc-vm.sh`](scripts/deploy-abc-vm.sh) | Clone catalog disks and create a VM in an end-user namespace |

Copy the three ABC scripts to the bastion, mark them executable (`chmod 0750`), and follow the matching guide. Deployment of the catalog VM does not require Internet access, Helm, Python, Ansible, `jq`, `yq`, an SMB share, or an HTTP server.

## No-secrets policy

This is a **public** repository.

- Do **not** commit pull secrets, kubeconfigs, tokens, `.pem` / `.key` files, customer names, real hostnames, real registries, subscription accounts, or disk images (`*.raw`, `*.img`, `*.qcow2`).
- Use placeholders only: `registry.example.internal:8443`, `sha256:REPLACE`, namespace `example`.
- Copy `examples/pull-secret.json.example` to a **local, gitignored** `pull-secret.json`. `.gitignore` excludes secrets/kubeconfigs while keeping `*.example`.

## Version pin

Platform citations target **OpenShift Container Platform 4.18** unless noted. The docs.redhat.com `/latest/` alias currently resolves to a newer 4.y (verified 4.22 as of 2026-08-25). Always match Operator catalog index `v4.y` to the cluster minor.

## License

MIT. See [LICENSE](LICENSE).
