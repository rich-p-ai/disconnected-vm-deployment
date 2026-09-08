# Pod Operator Guide — ABC VM USB Shuttle

This guide covers the **pod-based** ABC VM workflow: heavy export/compress and seed/deploy run in OpenShift Jobs on each cluster. The bastion holds code and kickoff only. **Raw disks never land on the bastion** — only compressed archives (`*.raw.gz`) and metadata are copied via USB / sneaker-net.

NAS/NFS volume mounts and RWX shared storage are **out of scope** for this release.

For the legacy path where raw disks are exported directly to the bastion, see [Builder guide](builder-guide.md) and [End-user deployment guide](end-user-deployment.md).

---

## Architecture

```text
Source cluster (Job)          Bastion (shuttle)              Dest cluster (Job)
────────────────────          ─────────────────              ────────────────────
Stop VM, VMExport             transfer-dir/                  Verify checksums
gzip disks in-cluster    -->  *.raw.gz + metadata    -->     seed catalog (if needed)
Job PVC                       USB copy only                  image-upload deploy VM
```

- **Build** runs on the **source** cluster.
- **Dest** runs on the **disconnected destination** cluster (seed + deploy in one Job).
- Dest deploy uses `virtctl image-upload` on LVM/TopoLVM (same as `deploy-abc-vm.sh`), not CDI clone.

---

## Prerequisites

### Bastion (both clusters)

- Bash, `oc`, network access to the cluster API you are logged into.
- `virtctl` on the bastion **or** ability to bootstrap it from the cluster (`scripts/lib/oc-virtctl.sh`).
- Cluster-admin (or equivalent) to create Job SA, RBAC, PVC, ConfigMap, and Job.
- Removable media for USB transfer between bastions.

### Source cluster

- OpenShift Virtualization installed.
- Source VM uses **PVC-backed disks** only.
- VM can be stopped for export (Job stops it if running).
- LVM (or caller-chosen) `StorageClass` for the Job work PVC.

### Destination cluster

- OpenShift Virtualization + CDI installed.
- LVM `StorageClass` for Job work PVC and target VM disks.
- Catalog namespace (default `vm-catalog`; created by kickoff if missing).

---

## Source: build kickoff

Log in to the **source** cluster on the bastion, then from the repo root:

```bash
chmod 0750 scripts/pod/kickoff-build.sh scripts/pod/kickoff-dest.sh

./scripts/pod/kickoff-build.sh \
  --namespace my-source-ns \
  --vm abc-vm \
  --version 1.0.0 \
  --storage-class lvms-vg1 \
  --transfer-dir /srv/abc-vm/transfers
```

Optional: `--keep-export` leaves the `VirtualMachineExport` on the source cluster after the Job completes.

### What happens

1. Kickoff computes Job PVC size from source VM PVC requests + 10Gi overhead.
2. Creates SA, RBAC, LVM PVC, stages `virtctl` onto the PVC, ConfigMap, and Build Job.
3. Job stops the VM, creates `VirtualMachineExport`, downloads each disk, **gzip compresses immediately**, writes `release.env`, `disks.tsv` (compressed filenames), `checksums.sha256`, and source metadata.
4. Kickoff waits for Job success, copies **compressed bundle only** to `--transfer-dir/<app-id>-<version>/`.
5. Prints checksums and USB instructions.

### Bundle contents (compressed)

```text
abc-vm-1.0.0/
├── release.env
├── disks.tsv              # file column is *.raw.gz
├── checksums.sha256       # hashes of compressed files only
├── source-vm.yaml
├── source-pvcs.yaml
├── source-disks.tsv
├── rootdisk.raw.gz
└── datadisk.raw.gz        # if present
```

---

## USB / sneaker-net transfer

On **source bastion**:

```bash
cd /srv/abc-vm/transfers/abc-vm-1.0.0
sha256sum -c checksums.sha256

# Copy to removable media (example)
rsync -a /srv/abc-vm/transfers/abc-vm-1.0.0/ /media/usb/abc-vm-1.0.0/
```

Physically move media to the **destination bastion**, then:

```bash
rsync -a /media/usb/abc-vm-1.0.0/ /srv/abc-vm/inbound/abc-vm-1.0.0/
cd /srv/abc-vm/inbound/abc-vm-1.0.0 && sha256sum -c checksums.sha256
```

Do **not** copy uncompressed `*.raw` files. If the bundle contains `.raw` files, `kickoff-dest.sh` refuses to run.

---

## Destination: seed + deploy kickoff

Log in to the **destination** cluster, then:

```bash
./scripts/pod/kickoff-dest.sh \
  --bundle-path /srv/abc-vm/inbound/abc-vm-1.0.0 \
  --storage-class lvms-vg1 \
  --catalog-namespace vm-catalog \
  --namespace user-project \
  --vm-name my-abc-vm
```

Add `--start` to create the VM and set `spec.running: true`.

### What happens

1. Validates bundle (metadata, checksums, `*.raw.gz` only — no raw).
2. Fails if VM `--vm-name` already exists in `--namespace`.
3. Creates dest Job SA, RBAC (including catalog clone grant), LVM PVC.
4. `oc cp` compressed bundle from bastion onto Job PVC.
5. Job verifies checksums.
6. If `DataSource ${APP_ID}-${VERSION}` in catalog is **already Ready**, **skips seed**.
7. Else seeds catalog one disk at a time: gunzip → `virtctl image-upload` → delete raw → next disk.
8. Deploys VM via `virtctl image-upload` into `--namespace` (LVM-safe path).
9. VM left **stopped** unless `--start`.

---

## Watching Jobs

```bash
# Replace ns and job name from kickoff output
oc get jobs -n <namespace>
oc logs -f job/<job-name> -n <namespace>
oc describe job/<job-name> -n <namespace>
```

Build Job timeout: 24h. Dest Job timeout: 48h (large uploads).

---

## Reruns

| Situation | Behavior |
| --- | --- |
| DataSource already Ready | Dest Job skips catalog seed; deploy proceeds |
| Same Job name still exists | Kickoff fails — delete previous Job/PVC first |
| VM name already exists | Kickoff and Job fail hard |
| Partial failed seed | Resolve or delete stuck catalog DVs manually before retry |

---

## Failure and cleanup

If a Job fails, inspect logs first:

```bash
oc logs job/<job-name> -n <namespace>
oc describe job/<job-name> -n <namespace>
```

Remove Job resources (cluster-admin):

**Build (source namespace):**

```bash
JOB=abc-build-abc-vm-1.0.0
NS=my-source-ns
oc delete job "${JOB}" -n "${NS}" --ignore-not-found
oc delete pvc "${JOB}-work" configmap "${JOB}-scripts" \
  sa "${JOB}" role "${JOB}" rolebinding "${JOB}" -n "${NS}" --ignore-not-found
```

**Dest (user namespace + catalog):**

```bash
JOB=abc-dest-my-abc-vm-abc-vm-1-0-0
NS=user-project
CAT=vm-catalog
oc delete job "${JOB}" -n "${NS}" --ignore-not-found
oc delete pvc "${JOB}-work" configmap "${JOB}-scripts" -n "${NS}" --ignore-not-found
oc delete sa "${JOB}" role "${JOB}" rolebinding "${JOB}" -n "${NS}" --ignore-not-found
oc delete role "${JOB}-catalog" rolebinding "${JOB}-catalog" -n "${CAT}" --ignore-not-found
oc delete clusterrolebinding "${JOB}-catalog-cloner" --ignore-not-found
```

Golden catalog objects in `vm-catalog` are **not** deleted by cleanup above.

---

## Container image selection

Kickoff picks an image already on the cluster:

1. `openshift/cli` ImageStream (preferred)
2. Else `virt-operator` / CDI operator image from `openshift-cnv`

`virtctl` is copied from the bastion (or a cluster pod) onto the Job PVC at `/work/bin/virtctl`. No custom container image is built or pushed.

---

## Known limitations (unchanged)

- Minimal VirtualMachine spec (CPU, memory, virtio/sata disks, default pod network).
- Boot disk selected by volume name heuristics — review `disks.tsv`.
- Export is crash-consistent; use clean guest shutdown for app consistency.
- One boot disk; unique roles for additional disks.
- LVM deploy uses image-upload, not CDI clone (see `deploy-abc-vm.sh`).
- `disks.tsv` from pod build lists **compressed** filenames; bastion fallback bundles use `.raw`.

---

## Bastion fallback (raw on bastion)

If Jobs are unavailable or you already have a raw bundle:

| Step | Script |
| --- | --- |
| Build | `scripts/build-abc-vm-package.sh` |
| Seed | `scripts/seed-abc-vm-catalog.sh` |
| Deploy | `scripts/deploy-abc-vm.sh` |

See [Builder guide](builder-guide.md) and [End-user deployment guide](end-user-deployment.md).
