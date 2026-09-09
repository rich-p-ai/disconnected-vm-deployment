# Test run (temporary)

Follow this for the first cluster smoke test. Full docs will be rewritten after the process is proven.

Storage class on these clusters is **`lvm`** (OpenShift LVMS / TopoLVM, local RWO). It is not an external array. Pass the name exactly:

```bash
--storage-class lvm
```

Use a **small, stopped** test VM with **one PVC** (about 20–40Gi). Do not start with a production Windows or RHEL disk.

---

## 0. Bastion

```bash
cd vm-tools
chmod 0750 build dest
oc whoami
oc get storageclass lvm
```

Need cluster-admin on the cluster you are logged into, plus `oc` and `virtctl` (or CNV so kickoff can stage virtctl).

---

## 1. Source cluster — build

```bash
oc login <source-api>

./build \
  --namespace <src-ns> \
  --vm <test-vm> \
  --version 0.1.0-test \
  --storage-class lvm \
  --transfer-dir /tmp/vm-transfer
```

**Pass**

- Job completes
- `/tmp/vm-transfer/<vm>-0.1.0-test/` has `*.raw.gz`, `release.env`, `disks.tsv`, `checksums.sha256`
- No `*.raw`
- `cd /tmp/vm-transfer/<vm>-0.1.0-test && sha256sum -c checksums.sha256`

**Fail**

```bash
oc logs -f job/abc-build-<vm>-0-1-0-test -n <src-ns>
oc describe job,pvc -n <src-ns> | less
```

On `lvm`, the staging pod and Job must bind on the **same node** (RWO). If the Job is Pending, check the PVC node and pod events.

---

## 2. Copy bundle

Same bastion: reuse `/tmp/vm-transfer/<vm>-0.1.0-test`.

Two bastions: copy that directory only (USB is fine). Do not copy `*.raw`.

---

## 3. Dest cluster — seed + deploy

```bash
oc login <dest-api>
oc get ns <user-project> || oc new-project <user-project>

./dest \
  --bundle-path /tmp/vm-transfer/<vm>-0.1.0-test \
  --storage-class lvm \
  --catalog-namespace vm-catalog \
  --namespace <user-project> \
  --vm-name test-vm-01
```

Leave off `--start` on the first run.

**Pass**

- Job completes
- `oc get datasource -n vm-catalog` Ready for this version
- `oc get vm,dv,pvc -n <user-project>` shows `test-vm-01` **stopped**
- Logs may show CDI clone failure then `image-upload` fallback. That is expected on `lvm`.

---

## 4. Optional start

```bash
virtctl start vm test-vm-01 -n <user-project>
oc get vmi test-vm-01 -n <user-project>
```

Confirm the guest boots, then stop it.

---

## Cleanup

Job names are printed at the end of each kickoff.

```bash
# Source
JOB=abc-build-<vm>-0-1-0-test
NS=<src-ns>
oc delete job "${JOB}" -n "${NS}" --ignore-not-found
oc delete pvc "${JOB}-work" cm "${JOB}-scripts" sa "${JOB}" role "${JOB}" rolebinding "${JOB}" -n "${NS}" --ignore-not-found

# Dest work objects (keep vm-catalog goldens unless you want them gone)
JOB=abc-dest-test-vm-01-<app-id>-0-1-0-test
NS=<user-project>
oc delete job "${JOB}" -n "${NS}" --ignore-not-found
oc delete pvc "${JOB}-work" cm "${JOB}-scripts" -n "${NS}" --ignore-not-found
oc delete sa "${JOB}" role "${JOB}" rolebinding "${JOB}" -n "${NS}" --ignore-not-found
```

---

## Do not

- Use a production disk size on this pass
- Put `*.raw` in `--bundle-path`
- Reuse a Job/PVC name without deleting the previous run
- Pass any storage class other than `lvm` on these clusters
