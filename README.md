# Disconnected ABC VM Deployment

Offline packaging and deployment of a reusable **ABC VM** appliance on air-gapped OpenShift Virtualization clusters.

## Purpose

Copy a production-ready VM from a source OpenShift cluster (Cluster A) into a fully disconnected OpenShift Virtualization cluster (Cluster B) without network connectivity between them, then make that VM available as a golden catalog image that end users can clone into their own projects.

Designed for strict air-gap environments:

- No Internet access required after the initial packaging.
- No Helm, Python, Ansible, `jq`, `yq`, external registries, SMB shares, or HTTP servers on the destination side.
- Uses only tools normally present on an OpenShift bastion: Bash, `oc`, `virtctl`, and standard GNU utilities.

## How it works (CDI / DataSource pattern)

1. **Build** (source cluster)  
   Stop the source VM, export its PVC-backed disks as raw images via `VirtualMachineExport`, and produce a versioned offline bundle (disks, checksums, metadata, scripts).

2. **Transfer**  
   Move the complete bundle to a bastion that can reach the disconnected cluster (USB, approved media, etc.).

3. **Seed** (destination cluster)  
   Upload disks as DataVolumes into a protected `vm-catalog` namespace and create a versioned **DataSource** for the boot disk. The seed waits until the DataSource is Ready.

4. **Grant catalog clone RBAC** (cluster admin)  
   Apply the sample in [`manifests/rbac-catalog-clone.yaml`](manifests/rbac-catalog-clone.yaml) (edit subjects first).

5. **Deploy** (end-user namespace)  
   Clone a writable boot disk from the catalog DataSource (`spec.sourceRef`) and any data disks from catalog PVCs, then create a VirtualMachine.

```text
Source cluster                    Offline transfer                 Disconnected cluster
───────────────                   ────────────────                 ─────────────────────
Source VM  ──export──►  Bundle   ───────────────►  Bastion  ──seed──►  vm-catalog
  (PVC disks)             *.raw + metadata                              ├─ DataVolumes
                                                                        ├─ PVCs (golden)
                                                                        └─ DataSource  ◄── deploy ──► User project
                                                                                                       ├─ Cloned DVs/PVCs
                                                                                                       └─ VirtualMachine
```

## Guides

| Audience | Document |
| --- | --- |
| Platform engineer who packages the appliance | [Builder guide](docs/builder-guide.md) |
| Cluster user who deploys a VM instance | [End-user deployment guide](docs/end-user-deployment.md) |

## Scripts and manifests

| Path | Role |
| --- | --- |
| [`scripts/build-abc-vm-package.sh`](scripts/build-abc-vm-package.sh) | Export a stopped source VM into a versioned offline bundle |
| [`scripts/seed-abc-vm-catalog.sh`](scripts/seed-abc-vm-catalog.sh) | Upload disks and create the catalog DataSource |
| [`scripts/deploy-abc-vm.sh`](scripts/deploy-abc-vm.sh) | Clone from DataSource / catalog PVCs and create a VM |
| [`manifests/rbac-catalog-clone.yaml`](manifests/rbac-catalog-clone.yaml) | Sample RBAC for cross-namespace catalog clone (required) |

Copy the three scripts to the bastion, make them executable (`chmod 0750`), and follow the matching guide. The build script includes the seed and deploy scripts inside every generated bundle.

## Important constraints and known limitations

- Source VM must use PVC-backed disks and must be fully stopped for a consistent export.
- Destination cluster requires OpenShift Virtualization + CDI.
- **Cross-namespace clone RBAC is mandatory** before end-user deploy (use the sample manifest).
- The scripts create a **minimal** VirtualMachine (CPU, memory, virtio disks, default pod network). Firmware, CPU model, Multus networks, cloud-init, secrets, and other domain settings from the source are **not** preserved.
- Boot disk is auto-selected by volume name heuristics (`root` / `boot` / `os` / `system`); always review `disks.tsv`.
- Export is offline / crash-consistent at the disk level — use a clean guest shutdown for application consistency.
- One boot disk and unique roles for additional disks (two `data` roles will collide on catalog names).
- Do not commit disk images (`*.raw`), pull secrets, or kubeconfigs to this repository.

## License

See [LICENSE](LICENSE).
