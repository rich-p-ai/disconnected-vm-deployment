# Disconnected ABC VM Deployment

Offline packaging and deployment of a reusable **ABC VM** appliance on air-gapped OpenShift Virtualization clusters.

## Purpose

Copy a production-ready VM from a source OpenShift cluster (Cluster A) into a fully disconnected OpenShift Virtualization cluster (Cluster B) without network connectivity between them, then make that VM available as a golden catalog image that end users can clone into their own projects.

Designed for strict air-gap environments:

- No Internet access required after the initial packaging.
- No Helm, Python, Ansible, `jq`, `yq`, external registries, SMB shares, or HTTP servers on the destination side.
- Uses only tools normally present on an OpenShift bastion: Bash, `oc`, `virtctl`, and standard GNU utilities.

## Recommended flow: pod Jobs + USB shuttle (compressed only)

The bastion holds scripts and kickoff only. **Raw disks never land on the bastion.** Export/compress runs in a Job on the source cluster; seed and deploy run in a Job on the destination cluster. Compressed archives move by USB / approved media.

| Step | Where | Command |
| --- | --- | --- |
| Build | Source bastion (`oc` → source cluster) | [`scripts/pod/kickoff-build.sh`](scripts/pod/kickoff-build.sh) |
| Transfer | USB / sneaker-net | Copy `--transfer-dir` bundle (`*.raw.gz` + metadata) |
| Seed + deploy | Dest bastion (`oc` → dest cluster) | [`scripts/pod/kickoff-dest.sh`](scripts/pod/kickoff-dest.sh) |

Full operator instructions: **[Pod operator guide](docs/pod-operator-guide.md)**

```text
Source cluster Job          Bastion (shuttle)           Dest cluster Job
──────────────────          ─────────────────           ──────────────────
Stop VM, VMExport      -->  *.raw.gz only        -->    seed catalog (if needed)
gzip in-cluster             USB copy                    image-upload deploy VM
```

NAS/NFS RWX volume mounts are **not** supported in this release.

## Bastion fallback (raw on bastion)

If OpenShift Jobs are unavailable or you prefer the original flow, use the three bastion scripts directly (raw disks on the bastion during transfer):

1. **Build** — [`scripts/build-abc-vm-package.sh`](scripts/build-abc-vm-package.sh)
2. **Seed** — [`scripts/seed-abc-vm-catalog.sh`](scripts/seed-abc-vm-catalog.sh)
3. **Deploy** — [`scripts/deploy-abc-vm.sh`](scripts/deploy-abc-vm.sh)

See [Builder guide](docs/builder-guide.md) and [End-user deployment guide](docs/end-user-deployment.md).

On LVM/TopoLVM, deploy uses `virtctl image-upload` (not CDI clone). Sample catalog RBAC: [`manifests/rbac-catalog-clone.yaml`](manifests/rbac-catalog-clone.yaml).

## Guides

| Audience | Document |
| --- | --- |
| Pod Job + USB shuttle (recommended) | [Pod operator guide](docs/pod-operator-guide.md) |
| Platform engineer (bastion fallback) | [Builder guide](docs/builder-guide.md) |
| Cluster user (bastion fallback deploy) | [End-user deployment guide](docs/end-user-deployment.md) |

## Scripts and manifests

| Path | Role |
| --- | --- |
| [`scripts/pod/kickoff-build.sh`](scripts/pod/kickoff-build.sh) | Kick off source-cluster Build Job; copy compressed bundle to bastion |
| [`scripts/pod/kickoff-dest.sh`](scripts/pod/kickoff-dest.sh) | Kick off dest-cluster Job (seed if needed + deploy VM) |
| [`scripts/pod/job-build.sh`](scripts/pod/job-build.sh) | In-cluster build logic (exported via ConfigMap) |
| [`scripts/pod/job-seed-deploy.sh`](scripts/pod/job-seed-deploy.sh) | In-cluster seed + deploy logic |
| [`manifests/pod/`](manifests/pod/) | Job and RBAC templates (rendered by kickoff scripts) |
| [`scripts/build-abc-vm-package.sh`](scripts/build-abc-vm-package.sh) | Bastion fallback: export VM to raw bundle |
| [`scripts/seed-abc-vm-catalog.sh`](scripts/seed-abc-vm-catalog.sh) | Bastion fallback: seed catalog |
| [`scripts/deploy-abc-vm.sh`](scripts/deploy-abc-vm.sh) | Bastion fallback: deploy VM |
| [`manifests/rbac-catalog-clone.yaml`](manifests/rbac-catalog-clone.yaml) | Sample RBAC for catalog access |

Make scripts executable: `chmod 0750 scripts/pod/*.sh scripts/*.sh`

## Important constraints and known limitations

- Source VM must use PVC-backed disks and must be fully stopped for a consistent export.
- Destination cluster requires OpenShift Virtualization + CDI.
- The scripts create a **minimal** VirtualMachine (CPU, memory, virtio disks, default pod network). Firmware, CPU model, Multus networks, cloud-init, secrets, and other domain settings from the source are **not** preserved.
- Boot disk is auto-selected by volume name heuristics (`root` / `boot` / `os` / `system`); always review `disks.tsv`.
- Export is offline / crash-consistent at the disk level — use a clean guest shutdown for application consistency.
- One boot disk and unique roles for additional disks (two `data` roles will collide on catalog names).
- LVM/TopoLVM: deploy uses `virtctl image-upload`, not CDI host-assisted clone.
- Do not commit disk images (`*.raw`, `*.raw.gz`), pull secrets, or kubeconfigs to this repository.

## License

See [LICENSE](LICENSE).
