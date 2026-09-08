# Pod deployment guide

Copy a VM from a source OpenShift Virtualization cluster to a disconnected cluster using Jobs. The bastion only runs kickoff. Disks are compressed on the source cluster. USB carries `*.raw.gz` only.

**Toolkit folder:** [`vm-tools/`](../vm-tools/). Copy that folder to each bastion. Techs start at [`vm-tools/START-HERE.txt`](../vm-tools/START-HERE.txt).

Storage class on these clusters is **`LVM`** (OpenShift LVMS, local RWO). Pass that name exactly. It is not an external LVM array.

NAS/NFS is not supported in this release.

---

## What runs where

```text
Source cluster Job              USB                   Dest cluster Job
------------------              ---                   ----------------
Stop VM, export disks     -->   *.raw.gz        -->   Seed vm-catalog (if needed)
gzip on a Job PVC               metadata              Create VM in user project
```

| Step | Who | Command |
| --- | --- | --- |
| Build | Source bastion, logged into source API | `cd vm-tools && ./build ...` |
| Carry | USB | The transfer directory only |
| Seed + deploy | Dest bastion, logged into dest API | `cd vm-tools && ./dest ...` |

`./dest` is one command: seed catalog if the DataSource is not Ready, then create the VM. Default VM state is stopped.

On `LVM`, CDI clone usually fails. The Job then gunzips one disk at a time and uses `virtctl image-upload` into the user project. That fallback is expected.

---

## Prerequisites

- Cluster-admin `oc` login to the cluster you are targeting
- `virtctl` on the bastion, or CNV so kickoff can stage it
- OpenShift Virtualization on source; Virtualization + CDI on dest
- Source VM: PVC-backed disks, can be stopped
- StorageClass `LVM` exists (`oc get storageclass LVM`)
- First test: one small disk (20–40Gi), not a production image

---

## Source — build

```bash
cd vm-tools
chmod 0750 build dest
oc whoami
oc get storageclass LVM

./build \
  --namespace <source-project> \
  --vm <source-vm> \
  --version 0.1.0-test \
  --storage-class LVM \
  --transfer-dir /tmp/vm-transfer
```

`--keep-export` is optional and leaves the VirtualMachineExport in place.

**Pass:** `/tmp/vm-transfer/<vm>-0.1.0-test/` has `*.raw.gz`, `release.env`, `disks.tsv`, `checksums.sha256`. No `*.raw`. Checksums verify.

Work PVC size is `2 ×` source PVC sum `+ 10Gi` so gzip has room.

On `LVM` the staging pod and Job must land on the same node. If the Job is Pending, check PVC node and pod events.

---

## USB

Copy the transfer directory only:

```text
/tmp/vm-transfer/<vm>-0.1.0-test/
  release.env
  disks.tsv
  checksums.sha256
  source-vm.yaml
  source-pvcs.yaml
  source-disks.tsv
  *.raw.gz
```

Also copy `vm-tools/` if the dest bastion does not have it.

Do not copy `*.raw`. Dest refuses a bundle that contains raw disks.

On dest:

```bash
cd /path/to/<vm>-0.1.0-test && sha256sum -c checksums.sha256
```

---

## Dest — seed + deploy

```bash
cd vm-tools
oc get ns <user-project> || oc new-project <user-project>

./dest \
  --bundle-path /path/to/<vm>-0.1.0-test \
  --storage-class LVM \
  --catalog-namespace vm-catalog \
  --namespace <user-project> \
  --vm-name <new-vm>
```

Add `--start` only when you intend to power the VM on immediately.

**Pass:** Job completes. `DataSource` in `vm-catalog` is Ready. VM exists in the user project and is stopped unless `--start`.

If that DataSource is already Ready, seed is skipped and only the new VM is created.

---

## Watch and clean up

Job names are printed by `./build` and `./dest`.

```bash
oc logs -f job/<job-name> -n <namespace>
oc describe job/<job-name> -n <namespace>
```

Build timeout 24h. Dest timeout 48h.

Delete the previous Job and work PVC before a retry of the same name. Do not delete `vm-catalog` goldens unless you intend to re-seed.

The scripts print the exact `oc delete` lines.

---

## Limits

- Minimal VM spec (CPU, memory, virtio/sata, default pod network). Source firmware/networks/cloud-init are not copied except a UEFI detect for bootloader flags.
- Boot disk is chosen by volume name. Check `disks.tsv`.
- Export is crash-consistent. Shut the guest down cleanly first.
- No new container image is pushed. Kickoff uses in-cluster `openshift/cli` (or CNV) and stages `virtctl` onto the Job PVC.

Legacy bastion path (raw on the bastion): `scripts/build-abc-vm-package.sh`, `scripts/seed-abc-vm-catalog.sh`, `scripts/deploy-abc-vm.sh`. See [builder-guide.md](builder-guide.md) and [end-user-deployment.md](end-user-deployment.md).
