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
3. **Deploy** – Clone a writable boot disk from the DataSource (and data disks from catalog PVCs) and create a VirtualMachine in an end-user namespace.

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
- The first PVC-backed disk is marked `boot` in `disks.tsv`. Edit the file if that is incorrect before transferring the bundle.
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
DataSource/abc-vm-1-0-0
```

Do not delete or modify the catalog objects while users depend on this release.

---

## 8. Catalog permissions

Users (or their service accounts) need permission to:

- Create DataVolumes and VirtualMachines in their own namespace.
- Clone from the catalog DataSource and from the catalog PVCs in `vm-catalog`.

Cross-namespace clone access is not granted by default. A cluster administrator must create the appropriate RBAC (typically a ClusterRole on `datavolumes/source` plus RoleBindings).

Validate before handing the procedure to users:

```bash
oc auth can-i create datavolumes.cdi.kubevirt.io -n user-project
oc auth can-i create virtualmachines.kubevirt.io -n user-project
```

Also perform a real test clone into a non-production project. Keep the catalog namespace protected.

---

## 9. Build validation checklist

- `sha256sum -c checksums.sha256` succeeds.
- Every exported disk is non-empty.
- `disks.tsv` has the correct boot disk and all data disks.
- Source guest was shut down cleanly.
- Bundle transferred via approved offline process.
- Seed succeeds; every catalog DataVolume reaches `Succeeded` and the DataSource exists.
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
Almost always RBAC or storage-class incompatibility. Inspect the target DataVolume events.

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
