# ABC VM End-User Deployment Guide

This guide explains how to deploy a new **ABC VM** into a disconnected OpenShift cluster.

Use this guide only after a platform administrator has seeded the required ABC VM version into the cluster catalog namespace. The deployment does not require Internet access, an SMB share, an HTTP server, Helm, Python, Ansible, `jq`, or `yq`.

The deployment script uses only:

- Bash
- `oc`
- standard Linux shell utilities
- OpenShift Virtualization and CDI already installed in the target cluster

> The deployment clones the already imported ABC VM catalog disks into your project. It does not download the VM image from any external system.

---

## 1. Before you begin

You need the following information from your platform administrator:

| Required item | Example | Purpose |
|---|---|---|
| ABC VM bundle location on the bastion | `/srv/abc-vm/releases/abc-vm-1.0.0` | Contains the deployment script and release metadata |
| Target namespace | `user-project` | The OpenShift project where the VM will be created |
| VM name | `abc-vm-01` | Name for the new virtual machine |
| Target storage class | `ocs-storagecluster-ceph-rbd` | Storage used for your cloned writable disks |
| Catalog namespace | `vm-catalog` | Namespace that contains protected golden ABC VM disks |
| Approved VM version | `1.0.0` | Appliance release to deploy |

Your user account or deployment service account must be permitted to:

- Create `DataVolume` objects in the target namespace.
- Create `VirtualMachine` objects in the target namespace.
- Clone the approved ABC VM catalog PVCs from `vm-catalog`.

If you receive a permissions error, contact the platform administrator. Do not attempt to modify the catalog namespace or its PVCs.

---

## 2. What the deployment creates

For an ABC VM named `abc-vm-01`, the deployment creates:

```text
Target namespace: user-project
├── DataVolume/abc-vm-01-boot
├── PersistentVolumeClaim/abc-vm-01-boot
├── DataVolume/abc-vm-01-data            # If the appliance includes a data disk
├── PersistentVolumeClaim/abc-vm-01-data # If the appliance includes a data disk
└── VirtualMachine/abc-vm-01
```

Your disks are writable clones. They are independent of the golden catalog image and of other users’ deployments.

The VM is created **stopped by default** unless you explicitly use `--start`.

---

## 3. Preflight checks

Log in to the disconnected cluster from the approved bastion:

```bash
oc config current-context
oc whoami
```

Confirm your target namespace exists:

```bash
oc get namespace user-project
```

Confirm the selected storage class exists:

```bash
oc get storageclass ocs-storagecluster-ceph-rbd
```

Confirm the VM catalog is available:

```bash
oc get dv,pvc,datasource -n vm-catalog
```

Confirm the relevant ABC VM release is present. For version `1.0.0`, the expected catalog disks are usually named similarly to:

```text
abc-vm-1-0-0-boot
abc-vm-1-0-0-data
```

The exact disks are listed in the appliance bundle’s `disks.tsv` file.

---

## 4. Confirm the deployment bundle

Go to the provided bundle directory:

```bash
cd /srv/abc-vm/releases/abc-vm-1.0.0
```

Confirm the expected files exist:

```bash
ls -l release.env disks.tsv deploy-abc-vm.sh checksums.sha256
```

Verify the appliance disk checksums:

```bash
sha256sum -c checksums.sha256
```

Review the release metadata:

```bash
cat release.env
cat disks.tsv
```

Example disk manifest:

```text
# role<TAB>volume_name<TAB>file<TAB>pvc_size<TAB>volume_mode
boot    rootdisk     rootdisk.raw     120Gi   Block
data    datadisk     datadisk.raw     500Gi   Block
```

You do not need to directly use the `.raw` files during a normal deployment. The deployment is cloned from the in-cluster catalog copies.

---

## 5. Deploy the VM

### Create the VM and leave it stopped

Use this as the normal first deployment. It allows you to inspect the created resources before booting the guest.

```bash
./deploy-abc-vm.sh \
  --bundle /srv/abc-vm/releases/abc-vm-1.0.0 \
  --namespace user-project \
  --vm-name abc-vm-01 \
  --storage-class ocs-storagecluster-ceph-rbd
```

### Create and start the VM

Use `--start` only when the VM name, target namespace, storage class, and required network configuration have already been approved.

```bash
./deploy-abc-vm.sh \
  --bundle /srv/abc-vm/releases/abc-vm-1.0.0 \
  --namespace user-project \
  --vm-name abc-vm-01 \
  --storage-class ocs-storagecluster-ceph-rbd \
  --start
```

### Override CPU and memory

If your platform team allows resource overrides, provide them at deployment:

```bash
./deploy-abc-vm.sh \
  --bundle /srv/abc-vm/releases/abc-vm-1.0.0 \
  --namespace user-project \
  --vm-name abc-vm-01 \
  --storage-class ocs-storagecluster-ceph-rbd \
  --cpu-cores 8 \
  --memory 16Gi
```

The script does not change the catalog image. It creates a new VM and separate cloned disks in your namespace.

---

## 6. Monitor deployment progress

The script waits for each cloned DataVolume to complete. Clone duration depends on the image size, storage platform, storage class, and CSI snapshot/clone support.

In another terminal, monitor the deployment:

```bash
oc get dv,pvc,vm -n user-project -w
```

Expected DataVolume state:

```text
NAME                  PHASE
abc-vm-01-boot        Succeeded
abc-vm-01-data        Succeeded
```

If the VM was created stopped, review it:

```bash
oc get vm abc-vm-01 -n user-project
oc describe vm abc-vm-01 -n user-project
```

Start it when ready:

```bash
virtctl start vm abc-vm-01 -n user-project
```

Or use OpenShift Virtualization console:

```text
Virtualization → VirtualMachines → abc-vm-01 → Start
```

---

## 7. Validate after boot

Check the VM instance:

```bash
oc get vmi -n user-project
oc get pods -n user-project
```

Review events if the VM does not start:

```bash
oc describe vm abc-vm-01 -n user-project
oc get events -n user-project --sort-by=.lastTimestamp
```

Validate from the guest operating system:

- Confirm the operating system reaches a healthy login or application-ready state.
- Confirm every expected disk is visible and mounted.
- Confirm the expected network interface, IP address, DNS resolution, and routing.
- Confirm application services start successfully.
- Confirm time synchronization and certificates if applicable.
- Enroll the VM in the required backup, monitoring, and patch-management processes.

For Windows guests, confirm that VirtIO storage and network drivers are installed before changing disk or NIC types. The standard appliance deployment uses VirtIO disks.

---

## 8. Network configuration

The standard deployment script creates a VM attached to the default pod network with masquerade networking.

If your deployment requires a Multus secondary network, static MAC address, static guest IP, VLAN, or other non-default network configuration, contact the platform administrator before deployment. Those settings must be provided in an approved version of the deployment script or a platform-specific overlay.

Do not edit catalog resources to change networking.

---

## 9. Common issues

### DataVolume clone remains pending or fails

Inspect the resource and events:

```bash
oc describe dv abc-vm-01-boot -n user-project
oc get events -n user-project --sort-by=.lastTimestamp
```

Common causes:

- The selected storage class does not support the required access mode or volume mode.
- Insufficient capacity exists in the target storage system.
- The catalog source PVC is unavailable.
- Cross-namespace clone RBAC has not been granted.

Contact the platform administrator with the output of the `oc describe dv` command.

### Permission denied or forbidden

The deployment identity lacks required permissions. Capture the exact error and contact the platform administrator.

Typical required permissions include creation of DataVolumes and VirtualMachines in the target project, plus permission to clone the approved catalog PVCs from `vm-catalog`.

### VM does not boot

Run:

```bash
oc describe vm abc-vm-01 -n user-project
oc get vmi,pods -n user-project
oc get events -n user-project --sort-by=.lastTimestamp
```

Possible causes include:

- The source guest requires a disk bus or driver different from the standard VirtIO configuration.
- Required network configuration was not applied.
- The application or guest OS was not shut down cleanly before the source export.
- Guest-level licensing, hardware binding, certificates, or boot configuration requires adjustment.

### Need to deploy another VM

Run the same deployment command with a different `--vm-name`. Each deployment creates separate disks in the target namespace.

```bash
./deploy-abc-vm.sh \
  --bundle /srv/abc-vm/releases/abc-vm-1.0.0 \
  --namespace user-project \
  --vm-name abc-vm-02 \
  --storage-class ocs-storagecluster-ceph-rbd
```

---

## 10. Safety rules

- Do not run deployment commands in `vm-catalog`.
- Do not modify, delete, or start the golden catalog PVCs.
- Do not reuse an existing VM name or disk name in the same project.
- Do not delete the cloned PVCs unless you intend to permanently remove the VM’s data.
- Do not use `oc delete project` as a normal VM removal mechanism; it deletes all resources in that project, including VM disks.
- Do not deploy an unverified or checksum-failing bundle.
- Use immutable appliance versions. Do not treat `latest` as a release version.

---

## 11. Deleting a deployed VM

Deleting a VM does not necessarily remove its data volumes and PVCs automatically. Review the resources first:

```bash
oc get vm,dv,pvc -n user-project -l abcvm.io/vm=abc-vm-01
```

To remove the VM only:

```bash
oc delete vm abc-vm-01 -n user-project
```

To permanently remove the cloned boot and data disks after the VM is deleted, explicitly delete their DataVolumes/PVCs according to your organization’s data-retention policy:

```bash
oc delete dv abc-vm-01-boot -n user-project
oc delete dv abc-vm-01-data -n user-project
```

Confirm the disk names before issuing deletion commands. Deleting a PVC permanently deletes the VM data unless your storage policy retains the underlying persistent volume.

---

## 12. Support information to collect

When opening a support request, provide:

```bash
oc config current-context
oc whoami
oc get vm,dv,pvc,vmi,pods -n user-project
oc describe vm abc-vm-01 -n user-project
oc describe dv abc-vm-01-boot -n user-project
oc get events -n user-project --sort-by=.lastTimestamp
```

Also include:

- ABC VM release version.
- Target namespace.
- VM name.
- Target storage class.
- Whether `--start` was used.
- The exact deployment command, with any sensitive values removed.
- The full error message or relevant event output.
