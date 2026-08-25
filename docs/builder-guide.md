# ABC VM Builder Guide

This guide is for the platform engineer who packages an existing OpenShift Virtualization VM as an offline, reusable **ABC VM** appliance for a disconnected cluster.

The process uses only tools normally present on an OpenShift bastion:

- Bash
- `oc`
- `virtctl`
- standard GNU/Linux commands (`awk`, `grep`, `sed`, `sha256sum`, `find`, etc.)

No Helm, Python, Ansible, `jq`, `yq`, external repositories, Internet access, SMB mount, or HTTP server is required after the initial packaging.

---

## 1. What this produces

The build process creates a self-contained offline bundle:

```text
abc-vm-1.0.0/
├── build-abc-vm-package.sh
├── seed-abc-vm-catalog.sh
├── deploy-abc-vm.sh
├── release.env
├── disks.tsv
├── checksums.sha256
├── source-vm.yaml
├── source-pvcs.yaml
├── <volume>.raw          # one or more raw disk images
└── ...
```

Roles of the three scripts:

1. **Build** – Export a stopped source VM and its disks to the bastion.
2. **Seed** – Upload the disks as DataVolumes into a protected catalog namespace and create a versioned **DataSource** (the primary catalog object).
3. **Deploy** – Clone a writable boot disk from the DataSource using `spec.sourceRef` (and data disks from catalog PVCs using `spec.source.pvc`) and create a VirtualMachine in an end-user namespace.

After the bundle is transferred, the destination cluster needs no connectivity to the source cluster or the Internet.

---

## 2. Architecture (CDI / DataSource pattern)

```text
Source OpenShift cluster                    Destination disconnected cluster
────────────────────────                    ──────────────────────────────
Source VM                                   vm-catalog namespace
  └─ PVC-backed disks                         ├─ DataVolume/<release>-boot
          │                                   ├─ DataVolume/<release>-data
          │ export (raw)                      ├─ PVC (golden images)
          ▼                                   └─ DataSource/<release>   ← primary catalog object
Bastion bundle                                         │
  /srv/abc-vm/releases/abc-vm-1.0.0/                   │ clone
  ├─ *.raw                                             ▼
  ├─ release.env                                User namespace
  ├─ disks.tsv                                    ├─ DataVolume/<vm>-boot   (from DataSource)
  └─ scripts                                      ├─ DataVolume/<vm>-data   (from PVC)
                                                  └─ VirtualMachine/<vm>
```

The objects in `vm-catalog` are **golden source images**. Do not start VMs from them and do not grant normal users permission to modify or delete them.

---

## 3. Prerequisites

### Source cluster

- OpenShift Virtualization installed and healthy.
- Source VM uses PVC-backed disks.
- Permission to stop the VM, read VM/PVCs, and create/download `VirtualMachineExport` resources.
- VM can be fully stopped for a consistent export.

### Destination cluster

- OpenShift Virtualization and CDI installed and healthy.
- Suitable destination `StorageClass` available.
- Bastion can authenticate to the destination cluster API.
- Bastion has enough free space for the exported images.

### Bastion tools

```bash
for command in bash oc virtctl awk cut grep sed sha256sum find sort; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "Missing required command: ${command}" >&2
    exit 127
  }
done

oc version --client
virtctl version --client || virtctl version
```

Use a `virtctl` version compatible with the OpenShift Virtualization release on both clusters.

---

## 4. Project layout on the bastion

```bash
mkdir -p /srv/abc-vm/scripts
cd /srv/abc-vm/scripts
```

Copy the three scripts from this repository’s `scripts/` directory and make them executable:

```bash
chmod 0750 build-abc-vm-package.sh seed-abc-vm-catalog.sh deploy-abc-vm.sh
```

The build script automatically copies the seed and deploy scripts into every generated bundle.

---

## 5. Build notes

- The source VM is stopped for an offline-consistent export.
- Disks are downloaded with `--format=raw` (required to avoid gzip corruption).
- Boot disk selection prefers a volume whose name contains `root`, `boot`, `os`, or `system` (case-insensitive). Otherwise the first PVC is used. **Always review and edit `disks.tsv` if needed before transfer.**
- `disks.tsv` records PVC size and volumeMode (Block / Filesystem).
- SHA-256 checksums are written for every `.raw` file.
- Use `--keep-export` only for troubleshooting.

---

## 6. Build the bundle

```bash
oc config current-context
oc whoami

cd /srv/abc-vm/scripts

./build-abc-vm-package.sh \
  --namespace source-project \
  --vm source-vm \
  --version 1.0.0 \
  --output-dir /srv/abc-vm/releases
```

Validate:

```bash
cd /srv/abc-vm/releases/abc-vm-1.0.0
sha256sum -c checksums.sha256
cat release.env
column -t -s $'\t' disks.tsv 2>/dev/null || cat disks.tsv
```

Example `disks.tsv`:

```text
# role<TAB>volume_name<TAB>file<TAB>pvc_size<TAB>volume_mode
boot    rootdisk     rootdisk.raw     120Gi   Block
data    datadisk     datadisk.raw     500Gi   Block
```

---

## 7. Seed the catalog on the disconnected cluster

Transfer the entire `abc-vm-<version>` directory to a bastion that can reach the destination cluster.

```bash
cd /srv/abc-vm/releases/abc-vm-1.0.0
sha256sum -c checksums.sha256

oc config current-context
oc whoami

./seed-abc-vm-catalog.sh \
  --bundle /srv/abc-vm/releases/abc-vm-1.0.0 \
  --storage-class ocs-storagecluster-ceph-rbd \
  --catalog-namespace vm-catalog
```

The seed script:

- Uploads each disk as a DataVolume (preserving volumeMode).
- Labels the resulting PVCs.
- Creates a **DataSource** named after the release (e.g. `abc-vm-1-0-0`) that points at the boot PVC. This is the primary catalog object.
- Waits until the DataSource is Ready.

Verify:

```bash
oc get dv,pvc,datasource -n vm-catalog -l abcvm.io/app=abc-vm
```

Expected objects (example):

```text
DataVolume/abc-vm-1-0-0-boot   Succeeded
DataVolume/abc-vm-1-0-0-data   Succeeded
PersistentVolumeClaim/abc-vm-1-0-0-boot   Bound
PersistentVolumeClaim/abc-vm-1-0-0-data   Bound
DataSource/abc-vm-1-0-0          Ready=True
```

This package names catalog disks by role (`<release>-boot`, `<release>-data`). Use one boot disk and at most one disk with role `data`, or give extra disks distinct roles (for example `data2`). Two lines with the same role collide on the same catalog object name.

Do not delete or modify the catalog objects while users depend on this release.

---

## 8. Catalog permissions (required before user deploy)

Cross-namespace clone is denied by default. A cluster administrator must grant permissions **before** end users run the deploy script.

A ready-to-adapt sample is in the repository:

[`manifests/rbac-catalog-clone.yaml`](../manifests/rbac-catalog-clone.yaml)

### Quick apply (customize subjects first)

1. Edit the sample and set the real User / Group / ServiceAccount names.
2. Confirm the catalog namespace is `vm-catalog` (or change the Role namespace).
3. Apply:

```bash
oc apply -f manifests/rbac-catalog-clone.yaml
```

### What the sample grants

- ClusterRole `abc-vm-catalog-cloner` on `datavolumes/source` (required by CDI for cross-namespace clone).
- Role `abc-vm-catalog-reader` in `vm-catalog` for get/list/watch on DataSources, DataVolumes, and PVCs.
- Example RoleBindings (edit subjects before use).

### Validate

```bash
oc auth can-i create datavolumes.cdi.kubevirt.io -n user-project
oc auth can-i create virtualmachines.kubevirt.io -n user-project
oc auth can-i get datasources.cdi.kubevirt.io -n vm-catalog
oc auth can-i get persistentvolumeclaims -n vm-catalog
```

Then perform a real test deploy into a non-production project. Keep the catalog namespace protected from user modification.

---

## 9. Build validation checklist

- `sha256sum -c checksums.sha256` succeeds.
- Every exported disk is non-empty.
- `disks.tsv` has the correct boot disk and all data disks (roles are unique).
- Source guest was shut down cleanly.
- Bundle transferred via approved offline process.
- Seed succeeds; every catalog DataVolume reaches `Succeeded` and the DataSource is Ready=True.
- Catalog RBAC is applied and validated.
- Test deploy produces a working VM that boots, sees all disks, and runs the application.
- Network, DNS, certificates, licensing, backups, and monitoring are validated.
- Record the tested OpenShift Virtualization version, storage class, and appliance version.

---

## 10. Troubleshooting

**Export stays pending**  
Confirm the source VM is fully stopped and no pods are using the PVCs.

```bash
oc get vmi -n source-project
oc describe virtualmachineexport <export-name> -n source-project
```

**Upload fails or stays pending**  
Check DataVolume events and confirm the storage class supports the requested volumeMode and access mode.

```bash
oc describe dv <name> -n vm-catalog
```

**Clone fails**  
Almost always RBAC or storage-class incompatibility. Inspect the target DataVolume events. The boot disk must clone with `spec.sourceRef` (`kind: DataSource`). Ensure `manifests/rbac-catalog-clone.yaml` (or equivalent) is applied.

**VM does not boot**  
- Confirm the disk marked `boot` is correct.
- Confirm volumeMode matches expectations.
- The deploy script uses virtio; Windows guests need VirtIO drivers already present.
- Check VM / VMI events and launcher logs.

---

## 11. Versioning and retention

Use immutable version directories and object names:

```text
abc-vm-1.0.0
abc-vm-1.0.1
abc-vm-2.0.0
```

Never overwrite an existing catalog release. Create a new version, validate it, then publish it.

Retain the golden catalog PVCs and DataSource for as long as end users need that version.

---

## 12. Known limitations (set expectations)

- Only PVC-backed disks are exported.
- The created VirtualMachine is minimal: CPU cores, memory, virtio disks, default pod network. Firmware, CPU model, Multus networks, cloud-init, secrets, and other domain settings from the source are not preserved.
- Export is offline / crash-consistent at the disk level; ensure a clean guest shutdown for application consistency.
- Secondary networks, static IPs, and advanced networking require a platform-approved overlay.
