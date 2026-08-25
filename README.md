# disconnected-vm-deployment

Scaffold for deploying and running virtual machines with **OpenShift Virtualization** on a **self-managed, disconnected (air-gapped) OpenShift Container Platform** cluster. There is no live access to Red Hat registries (`registry.redhat.io`, Quay, OperatorHub) at install or Operator install time.

This repository is a consulting starter: runbooks, architecture notes, placeholder manifests, Ansible roles, and wrapper scripts. It is not a turnkey installer.

## What this is

- A path to **mirror → registry → install cluster → install OpenShift Virtualization (CNV) → first VM** in a fully or partially disconnected environment.
- Primary install methods: **Agent-based Installer (ABI)** and **installer-provisioned infrastructure (IPI) disconnected / restricted-network**.
- Optional: **Migration Toolkit for Virtualization (MTV)** as a disconnected path to *land* VMs onto that cluster — not a migration factory.

## What this is not

- **Not** a duplicate of `mtv-vm-migration-aap`, `virt-rosa-cluster`, or `vm-migration-factory`.
- **Not** a ROSA (Red Hat OpenShift Service on AWS) engagement. ROSA hosted control planes run in a Red Hat-owned AWS account and are not an air-gapped self-managed control plane. See [docs/problem-decision.md](docs/problem-decision.md).
- **Not** a connected install, a proxy-only install, or a production catalog of customer hostnames.
- **Not** a place to store pull secrets, kubeconfigs, or registry credentials.

## Audience

Platform engineers and consultants who already hold an OpenShift subscription and need a repeatable disconnected OCP + OpenShift Virtualization landing zone.

## Flow (summary)

1. Connected bastion (or isolated mirror host) pulls content from Red Hat.
2. `oc-mirror` plugin **v2** writes an image set to disk or to a reachable registry.
3. Air-gapped cluster nodes pull only from the **internal mirror registry**.
4. Cluster uses **ImageDigestMirrorSet (IDMS)** / **ImageTagMirrorSet (ITMS)** (ICSP is legacy).
5. Disconnected **OLM CatalogSource** installs OpenShift Virtualization; then **HyperConverged (HCO)**.
6. First VM; optional MTV from a mirrored catalog.

Details: [docs/runbook.md](docs/runbook.md). Topology: [docs/architecture.md](docs/architecture.md).

## Documentation

| Doc | Purpose |
| --- | --- |
| [docs/problem-decision.md](docs/problem-decision.md) | ABI vs IPI disconnected; self-managed vs ROSA. **Fact** vs **Inference**. |
| [docs/architecture.md](docs/architecture.md) | Bastion, air-gap, mirror registry, oc-mirror, IDMS/ITMS, OLM, CNV, HCO, RHCOS, optional MTV. |
| [docs/disconnected-prerequisites.md](docs/disconnected-prerequisites.md) | Checklist with placeholders only. |
| [docs/runbook.md](docs/runbook.md) | Ordered steps and dry-run notes. Placeholder commands. |
| [docs/risks-gotchas.md](docs/risks-gotchas.md) | Digest mismatch, catalog skew, storage class, CPU models, DNS/NTP, MTV warm vs cold. |

Starters live under `ansible/`, `scripts/`, and `examples/`.

## No-secrets policy

This is a **public** repository.

- Do **not** commit pull secrets, kubeconfigs, tokens, `.pem` / `.key` files, customer names, real hostnames, real registries, or subscription accounts.
- Use placeholders only: `registry.example.internal:8443`, `sha256:REPLACE`, namespace `example`.
- Copy `examples/pull-secret.json.example` to a **local, gitignored** `pull-secret.json`. `.gitignore` already excludes `**/*secret*`, `kubeconfig`, `*.kubeconfig`, `pull-secret.json`, `.env`, `*.pem`, and `*.key`. `*.example` files are kept.

## Version pin

Citations target **OpenShift Container Platform 4.18** unless noted. The docs.redhat.com `/latest/` alias currently resolves to a newer 4.y (verified 4.22 as of 2026-08-25). Always match Operator catalog index `v4.y` to the cluster minor.

## License

MIT. See [LICENSE](LICENSE).
