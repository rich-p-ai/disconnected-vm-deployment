# Disconnected ABC VM Deployment

Offline packaging and deployment of a reusable **ABC VM** appliance on air-gapped OpenShift Virtualization clusters.

## Purpose

Copy a production-ready VM from a source OpenShift cluster (Cluster A) into a fully disconnected OpenShift Virtualization cluster (Cluster B) without network connectivity between them, then make that VM available as a golden catalog image that end users can clone into their own projects.

The workflow is designed for strict air-gap environments:

- No Internet access required at any stage after the initial packaging.
- No Helm, Python, Ansible, `jq`, `yq`, external registries, SMB shares, or HTTP servers needed on the destination side.
- Uses only tools normally present on an OpenShift bastion: Bash, `oc`, `virtctl`, and standard GNU utilities.

## How it works (CDI / DataSource pattern)

1. **Build** (source cluster)  
   Stop the source VM, export its PVC-backed disks as raw images via `VirtualMachineExport`, and produce a versioned offline bundle containing the disks, checksums, metadata, and the three operational scripts.

2. **Transfer**  
   Move the complete bundle to a bastion that can reach the disconnected cluster using your approved offline process (USB, sneaker-net, approved media, etc.).

3. **Seed** (destination cluster)  
   Upload the disks as DataVolumes into a protected `vm-catalog` namespace and create a versioned **DataSource** that points at the boot disk. The DataSource becomes the primary catalog object.

4. **Deploy** (end-user namespace)  
   Clone a writable boot disk from the catalog DataSource and any data disks from the corresponding catalog PVCs, then create a VirtualMachine. The new disks are independent of the golden images.

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

## Scripts

| Script | Role |
| --- | --- |
| [`scripts/build-abc-vm-package.sh`](scripts/build-abc-vm-package.sh) | Export a stopped source VM into a versioned offline bundle |
| [`scripts/seed-abc-vm-catalog.sh`](scripts/seed-abc-vm-catalog.sh) | Upload disks and create the catalog DataSource |
| [`scripts/deploy-abc-vm.sh`](scripts/deploy-abc-vm.sh) | Clone from DataSource / catalog PVCs and create a VM |

Copy the three scripts to the bastion, make them executable (`chmod 0750`), and follow the matching guide. The build script automatically includes the seed and deploy scripts inside every generated bundle.

## Important constraints and notes

- Source VM must use PVC-backed disks and must be fully stopped for a consistent export.
- Destination cluster requires OpenShift Virtualization + CDI.
- Cross-namespace clone permissions (for DataSource / PVC sources in `vm-catalog`) must be granted by a cluster administrator.
- The scripts intentionally create a minimal VirtualMachine (CPU, memory, virtio disks, default pod network). Complex domain settings, Multus networks, cloud-init, or firmware customizations from the source are not preserved.
- Do not commit disk images (`*.raw`), pull secrets, or kubeconfigs to this repository.

## License

See [LICENSE](LICENSE).
