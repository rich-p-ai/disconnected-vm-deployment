# ABC VM End-User Deployment Guide

This guide explains how to deploy a new **ABC VM** instance into a disconnected OpenShift Virtualization cluster.

Use this guide only after a platform administrator has seeded the required ABC VM version into the cluster catalog. The deployment requires no Internet access, SMB share, HTTP server, Helm, Python, Ansible, `jq`, or `yq`.

The deployment script uses only:

- Bash
- `oc`
- standard Linux shell utilities
- OpenShift Virtualization and CDI already present on the cluster

> The script clones from the in-cluster catalog (DataSource for the boot disk, catalog PVCs for any data disks). It does not download images from any external system.

---

## 1. Before you begin

Obtain the following from your platform administrator:

| Required item | Example | Purpose |
|---|---|---|
| ABC VM bundle location on the bastion | `/srv/abc-vm/releases/abc-vm-1.0.0` | Contains the deploy script and release metadata |
| Target namespace | `user-project` | Project where the VM will be created |
| VM name | `abc-vm-01` | Name for the new virtual machine |
| Target storage class | `ocs-storagecluster-ceph-rbd` | Storage for the writable cloned disks |
| Catalog namespace | `vm-catalog` | Namespace holding the golden images and DataSource |
| Approved VM version | `1.0.0` | Appliance release to deploy |

Your account (or the deployment service account) must be allowed to:

- Create `DataVolume` and `VirtualMachine` objects in the target namespace.
- Clone from the catalog **DataSource** and from the catalog PVCs in `vm-catalog`.

If you receive a permissions error, contact the platform administrator. Never modify objects in the catalog namespace.

---

## 2. What the deployment creates

For a VM named `abc-vm-01` the script creates:

```text
Target namespace: user-project
├── DataVolume/abc-vm-01-boot          ← cloned from catalog DataSource
├── PersistentVolumeClaim/abc-vm-01-boot
├── DataVolume/abc-vm-01-data          ← cloned from catalog PVC (if present)
├── PersistentVolumeClaim/abc-vm-01-data
└── VirtualMachine/abc-vm-01
```

The disks are independent writable clones. The VM is created **stopped** unless you pass `--start`.

---

## 3. Preflight checks

```bash
oc config current-context
oc whoami

oc get namespace user-project
oc get storageclass ocs-storagecluster-ceph-rbd

# Confirm the catalog DataSource and golden disks exist
oc get datasource,dv,pvc -n vm-catalog
```

For version `1.0.0` you should see objects similar to:

```text
DataSource/abc-vm-1-0-0
DataVolume/abc-vm-1-0-0-boot
DataVolume/abc-vm-1-0-0-data
```

The exact names are derived from the release and are listed in the bundle’s `disks.tsv` and `release.env`.

---

## 4. Confirm the deployment bundle

```bash
cd /srv/abc-vm/releases/abc-vm-1.0.0

ls -l release.env disks.tsv deploy-abc-vm.sh checksums.sha256
sha256sum -c checksums.sha256
cat release.env
cat disks.tsv
```

You do not need the `.raw` files for a normal deployment; they were already uploaded during seeding. The checksum check simply confirms the bundle is intact.

---

## 5. Deploy the VM

### Create the VM and leave it stopped (recommended first run)

```bash
./deploy-abc-vm.sh \
  --bundle /srv/abc-vm/releases/abc-vm-1.0.0 \
  --namespace user-project \
  --vm-name abc-vm-01 \
  --storage-class ocs-storagecluster-ceph-rbd
```

### Create and start the VM

```bash
./deploy-abc-vm.sh \
  --bundle /srv/abc-vm/releases/abc-vm-1.0.0 \
  --namespace user-project \
  --vm-name abc-vm-01 \
  --storage-class ocs-storagecluster-ceph-rbd \
  --start
```

### Override CPU / memory (if permitted)

```bash
./deploy-abc-vm.sh \
  --bundle /srv/abc-vm/releases/abc-vm-1.0.0 \
  --namespace user-project \
  --vm-name abc-vm-01 \
  --storage-class ocs-storagecluster-ceph-rbd \
  --cpu-cores 8 \
  --memory 16Gi
```

The script never modifies the catalog. It only creates new resources in your namespace.

---

## 6. Monitor progress

```bash
oc get dv,pvc,vm -n user-project -w
```

Wait until every DataVolume reaches `Succeeded`. Clone time depends on image size and storage performance.

If the VM was left stopped:

```bash
oc get vm abc-vm-01 -n user-project
oc describe vm abc-vm-01 -n user-project
virtctl start vm abc-vm-01 -n user-project
```

---

## 7. Validate after boot

```bash
oc get vmi,pods -n user-project
oc describe vm abc-vm-01 -n user-project
oc get events -n user-project --sort-by=.lastTimestamp
```

From the guest:

- OS reaches a healthy login / application-ready state.
- All expected disks are visible and mounted.
- Network, DNS, and routing work as required.
- Application services start successfully.
- Enroll the VM in backup, monitoring, and patch processes.

Windows guests must already contain VirtIO drivers; the deployment uses virtio disks.

---

## 8. Network configuration

The script attaches the VM to the default pod network with masquerade.  
Any Multus secondary network, static IP, static MAC, or VLAN requirement must be handled by a platform-approved overlay or a customized deploy script. Do not edit catalog resources.

---

## 9. Common issues

**DataVolume clone pending or failed**

```bash
oc describe dv abc-vm-01-boot -n user-project
oc get events -n user-project --sort-by=.lastTimestamp
```

Typical causes: missing cross-namespace RBAC, storage class does not support the volume mode / access mode, insufficient capacity, or catalog object missing.

**Permission denied**  
Your identity lacks create or clone rights. Contact the platform administrator.

**VM does not boot**  
Check events, confirm the boot disk is correct, and verify guest drivers / licensing / certificates.

**Deploy another instance**  
Use a different `--vm-name`. Each run creates independent disks.

---

## 10. Safety rules

- Never run deploy commands against `vm-catalog`.
- Never modify, delete, or start the golden catalog objects.
- Do not reuse an existing VM or disk name in the same project.
- Do not delete cloned PVCs unless you intend to destroy the VM data.
- Do not use `oc delete project` as a normal cleanup method.
- Only deploy a bundle whose checksums verify successfully.
- Use immutable version numbers; never treat “latest” as a release.

---

## 11. Deleting a deployed VM

```bash
oc get vm,dv,pvc -n user-project -l abcvm.io/vm=abc-vm-01

# Remove the VM
oc delete vm abc-vm-01 -n user-project

# Optionally remove the cloned disks (permanent data loss)
oc delete dv abc-vm-01-boot abc-vm-01-data -n user-project
```

Confirm names before deleting. Storage policies may retain underlying volumes.

---

## 12. Information to collect for support

```bash
oc config current-context
oc whoami
oc get vm,dv,pvc,vmi,pods -n user-project
oc describe vm abc-vm-01 -n user-project
oc describe dv abc-vm-01-boot -n user-project
oc get events -n user-project --sort-by=.lastTimestamp
```

Also include: appliance version, target namespace, VM name, storage class, whether `--start` was used, the exact command (redacted), and the full error or event output.
