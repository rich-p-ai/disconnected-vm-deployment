# ABC VM Builder Guide

This guide is for the engineer who packages an existing OpenShift Virtualization VM as an offline, reusable **ABC VM** appliance bundle.

The process uses only tools normally present on an OpenShift bastion:

- Bash
- `oc`
- `virtctl`
- standard GNU/Linux commands such as `awk`, `grep`, `sed`, `sha256sum`, and `find`

No Helm, Python, Ansible, `jq`, `yq`, external repositories, Internet access, SMB mount, or HTTP server is required at deployment time.

---

## 1. What this produces

The build process creates a self-contained bundle that can be transferred to a disconnected OpenShift environment:

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
├── bootdisk.raw
└── datadisk.raw
```

The bundle has three roles:

1. **Build**: Export a stopped source VM and its disks to the bastion.
2. **Seed**: Upload the exported disks once into a protected catalog namespace on the disconnected cluster.
3. **Deploy**: Clone catalog disks and create a new VM in an end-user namespace.

The destination cluster does not need access to the source cluster, Internet, an SMB share, or a web server after the bundle is transferred to the destination bastion.

---

## 2. Architecture

```text
Source OpenShift cluster                         Destination disconnected cluster
────────────────────────                         ──────────────────────────────
Source VM                                        vm-catalog namespace
  └─ PVC-backed disks                                 └─ Golden catalog DataVolumes/PVCs
          │                                                    │
          │ export to bastion                                  │ local clone
          ▼                                                    ▼
Bastion bundle                                           User namespace
  /srv/abc-vm/abc-vm-1.0.0/                              ├─ Cloned boot PVC
  ├─ bootdisk.raw                                        ├─ Cloned data PVC(s)
  ├─ datadisk.raw                                        └─ ABC VM
  ├─ release.env
  └─ disks.tsv
```

The `vm-catalog` disks are **golden source images**. Do not start VMs directly from them and do not grant normal users permission to modify or delete them.

---

## 3. Prerequisites

### Source cluster requirements

- OpenShift Virtualization is installed and healthy.
- The source VM uses PVC-backed disks.
- You have permission to stop the VM, read the VM/PVCs, and create/download `VirtualMachineExport` resources.
- The source VM can be stopped for a consistent disk-level export.

### Destination cluster requirements

- OpenShift Virtualization and CDI are installed and healthy.
- A suitable destination `StorageClass` is available.
- The bastion can authenticate to the destination cluster API.
- The bastion has adequate free space for the exported images.

### Bastion requirements

Run the following checks:

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

Use a `virtctl` version compatible with the installed OpenShift Virtualization release.

---

## 4. Create the project layout

On the bastion that can access the source cluster:

```bash
mkdir -p /srv/abc-vm/scripts
cd /srv/abc-vm/scripts
```

Copy the three scripts from this repository’s `scripts/` directory onto the bastion and make them executable:

```bash
chmod 0750 build-abc-vm-package.sh
chmod 0750 seed-abc-vm-catalog.sh
chmod 0750 deploy-abc-vm.sh
```

Keep these scripts in source control. The build script copies the seed and deploy scripts into every generated VM bundle so that a transfer contains all required tooling.

---

## 5. Build script

Use [`scripts/build-abc-vm-package.sh`](../scripts/build-abc-vm-package.sh) from this repository. Copy that file to the bastion; do not recreate it by hand. The file in `scripts/` is the source of truth.


### Important build notes

- The source VM is stopped for an offline-consistent export.
- The first PVC-backed disk is classified as the `boot` disk. If that is not correct, edit `disks.tsv` before transferring the bundle.
- The script records the source PVC requested capacity and volume mode in `disks.tsv`.
- The script writes SHA-256 checksums for every exported `.raw` file.
- Use `--keep-export` only for troubleshooting. The normal default is to remove the temporary export object after the download completes.

---

## 6. Build the ABC VM bundle

Set the source-cluster context on the bastion:

```bash
oc config current-context
oc whoami
```

Run the build script:

```bash
cd /srv/abc-vm/scripts

./build-abc-vm-package.sh \
  --namespace source-project \
  --vm source-vm \
  --version 1.0.0 \
  --output-dir /srv/abc-vm/releases
```

Validate the resulting bundle:

```bash
cd /srv/abc-vm/releases/abc-vm-1.0.0
sha256sum -c checksums.sha256
cat release.env
column -t -s $'\t' disks.tsv 2>/dev/null || cat disks.tsv
```

If needed, edit `disks.tsv` so the correct operating-system disk has the `boot` role:

```text
# role<TAB>volume_name<TAB>file<TAB>pvc_size<TAB>volume_mode
boot    rootdisk     rootdisk.raw     120Gi   Block
data    datadisk     datadisk.raw     500Gi   Block
```

Do not alter disk file names unless the matching `file` column is also changed.

---

## 7. Catalog seed script

Use [`scripts/seed-abc-vm-catalog.sh`](../scripts/seed-abc-vm-catalog.sh) from this repository. Copy that file to the bastion; do not recreate it by hand. The file in `scripts/` is the source of truth.


---

## 8. Seed the disconnected cluster catalog

Transfer the complete `abc-vm-<version>` directory to a bastion that can access the disconnected OpenShift cluster. Use your approved offline transfer process.

On the destination bastion:

```bash
cd /srv/abc-vm/releases/abc-vm-1.0.0
sha256sum -c checksums.sha256

oc config current-context
oc whoami
```

Seed the catalog using the target cluster storage class:

```bash
./seed-abc-vm-catalog.sh \
  --bundle /srv/abc-vm/releases/abc-vm-1.0.0 \
  --storage-class ocs-storagecluster-ceph-rbd \
  --catalog-namespace vm-catalog
```

Expected objects:

```bash
oc get dv,pvc,datasource -n vm-catalog
```

Example expected result:

```text
NAME                              PHASE
DataVolume/abc-vm-1-0-0-boot      Succeeded
DataVolume/abc-vm-1-0-0-data      Succeeded

NAME                              STATUS   VOLUME                                     CAPACITY
PersistentVolumeClaim/abc-vm-1-0-0-boot   Bound    pvc-...                              120Gi
PersistentVolumeClaim/abc-vm-1-0-0-data   Bound    pvc-...                              500Gi

NAME                 AGE
DataSource/abc-vm-1-0-0
```

The catalog is now ready for user deployments. Do not delete or modify the catalog PVCs while users depend on this appliance release.

---

## 9. Deployment script

Use [`scripts/deploy-abc-vm.sh`](../scripts/deploy-abc-vm.sh) from this repository. Copy that file to the bastion; do not recreate it by hand. The file in `scripts/` is the source of truth.


---

## 10. Catalog permissions

A user or deployment service account needs explicit permission to clone catalog PVCs from `vm-catalog` into its own project. Namespace isolation prevents this by default.

A cluster administrator should grant only the required cross-namespace clone permissions according to the OpenShift Virtualization version and organizational RBAC policy.

Validate the deployment identity before handing the procedure to users:

```bash
oc auth can-i create datavolumes.cdi.kubevirt.io -n user-project
oc auth can-i create virtualmachines.kubevirt.io -n user-project
```

Also test an actual clone into a non-production project. The source catalog namespace must remain protected from user modification.

---

## 11. Build validation checklist

Before releasing an ABC VM bundle:

- Confirm `sha256sum -c checksums.sha256` succeeds.
- Confirm every exported disk file is non-empty.
- Confirm `disks.tsv` contains the correct boot disk and all data disks.
- Confirm source guest shutdown was clean and application-consistent.
- Transfer the bundle through the approved offline process.
- Seed into a non-production disconnected cluster first.
- Confirm every catalog DataVolume reaches `Succeeded`.
- Deploy a test VM using the deployment script.
- Confirm the guest boots, detects all disks, and the application works.
- Validate network settings, DNS, certificates, application licensing, backups, and monitoring.
- Record the tested OpenShift Virtualization version, storage class, and appliance version in your release notes.

---

## 12. Troubleshooting

### VM export remains pending

Check that the source VM is fully stopped and no pod is using the source PVCs:

```bash
oc get vmi -n source-project
oc get virtualmachineexport -n source-project
oc describe virtualmachineexport abc-vm-export-1-0-0 -n source-project
```

### Disk upload fails or remains pending

Check the DataVolume and importer pod events:

```bash
oc get dv,pvc,pods -n vm-catalog
oc describe dv abc-vm-1-0-0-boot -n vm-catalog
```

Verify that the destination storage class supports the requested access mode and volume mode.

### Clone fails across namespaces

This is typically an RBAC issue or a storage cloning compatibility issue. Check the DataVolume events:

```bash
oc describe dv abc-vm-01-boot -n user-project
```

Confirm the deployment identity has the required permissions and that the source and destination storage classes are supported by your selected cloning workflow.

### VM does not boot

- Confirm the disk marked `boot` in `disks.tsv` is the actual boot disk.
- Confirm the imported disk’s `volumeMode` matches the source/guest expectations.
- Confirm the VM’s disk bus is appropriate. The provided script uses `virtio`.
- For Windows guests, verify VirtIO storage and network drivers are already installed in the guest.
- Check VM events and launcher logs:

```bash
oc describe vm abc-vm-01 -n user-project
oc get vmi -n user-project
oc get pods -n user-project
```

---

## 13. Versioning and retention

Use immutable version directories and catalog object names:

```text
abc-vm-1.0.0
abc-vm-1.0.1
abc-vm-2.0.0
```

Do not overwrite an existing catalog release in place. Create a new release, validate it, then publish it for deployment.

Keep these items together for each release:

- The disk image files.
- `checksums.sha256`.
- `release.env`.
- `disks.tsv`.
- The source VM and PVC metadata exports.
- Release notes documenting the tested target cluster and storage configuration.

Retain the golden catalog PVCs for as long as end users need to deploy that version.
