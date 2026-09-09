# Developer guide — disconnected VM pod pipeline

This is the maintainers’ document. Operators use `vm-tools/HOW-TO.txt`.
You own the scripts, Job templates, RBAC, and the contract between source and dest.

Read this before you change a line in `vm-tools/scripts/pod/` or `manifests/pod/`.

---

## 1. What you are responsible for

We copy a KubeVirt VM from a source OpenShift cluster to a disconnected dest cluster.

Constraints that drive every design choice:

- Dest has **no Internet**.
- Bastion disks are small. Raw Windows/RHEL images do **not** belong on the bastion.
- We **cannot ship a custom container image**. Jobs reuse in-cluster `openshift/cli`.
- Extra binaries must already exist on RHEL / OpenShift, or we stage them from the cluster. That is why compression is **gzip -9**, not zstd.
- Storage class on these sites is **`lvm`** (LVMS, local RWO). CDI clone across namespaces usually fails. Image-upload fallback is expected, not an error.

If a change violates one of those, it is the wrong change.

---

## 2. Mental model

Two machines, two logins, one USB stick.

```
bastion (source)                 cluster (source)              USB                 cluster (dest)              bastion (dest)
----------------                 ----------------              ---                 --------------              ---------------
./build                          Job + work PVC                                 Job + work PVC                ./dest
  create SA/RBAC/PVC/CM            stop VM                                        seed vm-catalog
  stage virtctl onto PVC           virtctl vmexport                               image-upload or clone
  start Job                        gzip -9 one disk at a time                     create VM
  copy *.raw.gz off PVC            write bundle on PVC
```

**Bastion scripts do orchestration only.** They apply YAML and copy small files. They never decompress a guest disk.

**Job scripts do the heavy I/O.** They run inside a pod, on a work PVC that is large enough for one raw disk plus the compressed set.

If you mix those roles (decompress on the bastion, or invent a new image), you will break the air-gap sites.

---

## 3. Tree you actually maintain

The package techs copy is **`vm-tools/`**. That folder must stay self-contained.

```
vm-tools/
  START-HERE.txt          tech entry
  HOW-TO.txt              tech procedure
  build                   wrapper → scripts/pod/kickoff-build.sh
  dest                    wrapper → scripts/pod/kickoff-dest.sh
  cleanup                 cluster-wide leftover Job cleanup
  scripts/pod/
    lib-kickoff.sh        shared bastion helpers
    kickoff-build.sh      source orchestrator
    kickoff-dest.sh       dest orchestrator
    job-build.sh          runs IN the source Job
    job-seed-deploy.sh    runs IN the dest Job
  scripts/lib/oc-virtctl.sh
  manifests/pod/
    job-build.yaml.tpl
    job-dest.yaml.tpl
    rbac-job-build.yaml.tpl
    rbac-job-dest.yaml.tpl
```

There is a second copy under repo-root `scripts/pod/` and `manifests/pod/`.
**If you edit one, edit the other.** Kickoff resolves templates relative to the folder the wrapper lives in (`vm-tools/` when techs run `./build`).

Legacy bastion path (raw disks on the bastion) is `scripts/build-abc-vm-package.sh`, `seed-abc-vm-catalog.sh`, `deploy-abc-vm.sh`. Do not delete it. Do not make the pod path depend on it.

---

## 4. Object graph a kickoff creates

Every run creates a short-lived set named after the Job:

| Object | Build | Dest |
| --- | --- | --- |
| ServiceAccount | Job namespace | user project |
| Role + RoleBinding | Job namespace | user project **and** `vm-catalog` |
| ClusterRole `abc-vm-catalog-cloner` + binding | no | yes (CDI clone grant) |
| Work PVC (`<job>-work`) | RWO on `lvm` | RWO on `lvm` |
| ConfigMap (`<job>-scripts`) | `job-build.sh` | `job-seed-deploy.sh` |
| Staging pod (`<job>-stage`) | copies virtctl onto PVC | copies virtctl + bundle onto PVC |
| Job | runs `job-build.sh` | runs `job-seed-deploy.sh` |

Labels: `abcvm.io/component=pod-job-build|pod-job-dest`, `abcvm.io/job=<name>`.

Job names are DNS-safe: lowercase, dots become dashes, max 63 chars.

```
abc-build-<vm>-<version>
abc-dest-<vm>-<appid>-<version>
```

`cleanup` finds `^abc-(build|dest)-`. If you rename the prefix, update cleanup or leftovers stay forever.

Jobs use `backoffLimit: 0` and `restartPolicy: Never`. A failed Job does not retry. Clean it, then rerun.

`ttlSecondsAfterFinished: 86400` is a backstop. Do not rely on it. Techs should `./cleanup` after a run.

---

## 5. Source path — what `./build` does

### 5.1 Bastion (`kickoff-build.sh`)

1. Confirm `oc` login, VM exists, StorageClass exists.
2. Optional `--clean` deletes leftover Jobs in that namespace.
3. Size the work PVC: **sum of source PVC requests + 10Gi**.
4. Resolve Job image (`openshift/cli:latest` in-cluster, then CNV images).
5. Apply RBAC template.
6. Create work PVC, wait Bound.
7. Stage `virtctl` onto `/work/bin` via a short-lived pod that mounts the PVC.
8. Put `job-build.sh` in a ConfigMap.
9. Apply Job, stream logs, wait Complete (24h).
10. Copy **only** the bundle off the PVC into `--transfer-dir/<vm>-<version>/`.
11. Refuse to write `--transfer-dir` if the account cannot create it (`/home/data` is the usual trap).

`--transfer-dir` must be writable by the bastion user. Prefer `/tmp/vm-transfer` or `$HOME/vm-transfer`.

### 5.2 Job (`job-build.sh`)

1. Require: `bash oc awk gzip virtctl sha256sum` (no zstd).
2. Stop the VM if a VMI exists. Syntax is `virtctl stop <name> -n <ns>` — **no `vm` token**. Wrong syntax is a known outage.
3. Dump `source-vm.yaml`, `source-pvcs.yaml`, `source-disks.tsv`.
4. Pick boot volume by name heuristics (`root`, `boot`, `os`, `c-drive`, …). First disk if nothing matches.
5. Write `disks.tsv` and `release.env`. File names are `<volume>.raw.gz`.
6. Create `VirtualMachineExport`, wait Ready.
7. For each disk:
   - Prefer raw export, then `gzip -9`.
   - If export only offers gzip, gunzip and recompress at `-9`.
   - Delete the raw temp file before the next disk.
   - Assert gzip magic `1f 8b`.
8. `sha256sum *.raw.gz > checksums.sha256`.
9. Delete the export unless `KEEP_EXPORT=true`.

One-disk lifecycle is mandatory on `lvm`. If you keep every raw plus every gz on the PVC, the Job fills the volume and dies.

---

## 6. Dest path — what `./dest` does

One command: seed catalog if needed, then create the VM.

### 6.1 Bastion (`kickoff-dest.sh`)

1. Require bundle files: `release.env`, `disks.tsv`, `checksums.sha256`, at least one `*.raw.gz`.
2. **Reject `*.raw`.** If a tech copied the raw disks, fail hard.
3. Source `release.env` for `APP_ID` / `VERSION`.
4. Fail if `--vm-name` already exists.
5. Create `vm-catalog` namespace if missing.
6. Size work PVC: **bundle bytes + largest disk + 10Gi** (room to gunzip one disk).
7. Apply dest RBAC (user ns + catalog Role + ClusterRoleBinding).
8. Copy the bundle onto the PVC. Stage virtctl.
9. Start Job. Wait up to 48h.

### 6.2 Job (`job-seed-deploy.sh`)

**Seed (`vm-catalog`)** — skipped when DataSource `<release-id>` is already Ready:

- For each row in `disks.tsv`: gunzip one file, `virtctl image-upload dv`, delete the raw, wait DV Succeeded.
- Create/update DataSource pointing at the boot DV.

**Deploy (user project):**

- Try CDI clone from catalog DataSource / catalog PVC.
- On `lvm` this usually fails. That is normal.
- Fallback: gunzip that one disk, `virtctl image-upload` into the user project, delete raw.
- Apply a **minimal** VirtualMachine spec (4 CPU / 8Gi unless you change `release.env` defaults, virtio or volumeMode-aware disk, default pod network).
- Start only if `START_VM=true`. Default is stopped.

Do not treat “clone failed, falling back to image-upload” as a regression.

---

## 7. Bundle contract

This is the API between source and dest. Change it in both Jobs in the same commit.

```
<vm>-<version>/
  release.env           shell-sourceable key=value
  disks.tsv             role<TAB>volume_name<TAB>file<TAB>pvc_size<TAB>volume_mode
  checksums.sha256      sha256 of every *.raw.gz
  source-vm.yaml        debug only
  source-pvcs.yaml      debug only
  source-disks.tsv      debug only
  <volume>.raw.gz       gzip -9 of raw disk
```

`release.env` fields dest depends on:

- `APP_NAME`, `APP_ID`, `VERSION`
- `SOURCE_NAMESPACE`, `SOURCE_VM`
- `CATALOG_NAMESPACE` (default `vm-catalog`)
- `VM_CPU_CORES`, `VM_MEMORY`, `VM_NETWORK_MODE`

`disks.tsv` role `boot` becomes catalog DV `<release-id>-boot` and DataSource name `<release-id>`.
Data disks become `<release-id>-<sanitized-volume>`.

Never put uncompressed `.raw` in the transfer directory.

---

## 8. RBAC — why each rule exists

Kickoff runs as cluster-admin. The **Job pod** does not. It uses the generated SA.

**Build Role** must include:

- `kubevirt.io` VM/VMI get/list/watch/patch
- `subresources.kubevirt.io` `virtualmachines/stop` and `start` — without this, `virtctl stop` returns Forbidden or a confusing client error
- `export.kubevirt.io` VirtualMachineExports CRUD
- pods, PVCs, secrets, services, `pods/portforward` (vmexport download fallback)

**Dest Role (user project)** must include DataVolumes, DataSources, PVCs, pods, `uploadtokenrequests`.

**Dest Role in `vm-catalog`** is the same set so seed can upload goldens.

**ClusterRole `abc-vm-catalog-cloner`** grants `datavolumes/source`. Needed for CDI clone. Harmless if clone is unused.

If you add a new `oc` / `virtctl` call in a Job script, add the verb **before** you test. Restricted PodSecurity warnings are noisy; real Forbidden is a stop-the-line bug.

---

## 9. Storage and scheduling

`lvm` is RWO and node-local.

- Staging pod and Job must land on the **same node** as the work PVC.
- If the Job is Pending: `oc describe pvc`, `oc describe pod`, look for FailedScheduling / WaitForFirstConsumer.
- Do not switch the work PVC to RWX. These clusters do not have it for this class.
- Do not raise build PVC to “2× all disks + all gz” unless a site has the capacity. Current formula is 1× source sum + 10Gi because we delete raw after each gzip.

`quantity_to_bytes` must accept bare integer bytes (some PVCs have no unit). If you “simplify” that function, dest PVC sizing breaks.

---

## 10. Commands you are allowed to depend on

| Where | Allowed |
| --- | --- |
| Bastion | `bash`, `oc`, coreutils, `virtctl` (or copy from a CNV pod) |
| Job image | whatever `openshift/cli` ships: `bash`, `oc`, `gzip`/`gunzip`, `sha256sum`, `tar`, `awk` |

Do **not** add: `jq`, `yq`, Python, Helm, Ansible, zstd, custom RPMs, a new image.

To add a tool: prove it exists on disconnected RHEL 8/9 **and** in `openshift/cli`. If it does not, do not add it.

---

## 11. How to change the code without hurting a site

1. Change `vm-tools/scripts/pod/` and `vm-tools/manifests/pod/` first.
2. Mirror the same files under repo-root `scripts/pod/` and `manifests/pod/`.
3. If you change the bundle format, bump the operator docs and HOW-TO in the same PR.
4. Keep wrappers (`build`, `dest`, `cleanup`) stupid. Logic lives in the scripts they exec.
5. Templates use `__TOKEN__` replacement. Do not introduce Helm or kustomize for this package.
6. Test on a **small** disk VM before a production Windows image.
7. After a failed test, `./cleanup` (or `./cleanup --namespace <ns>`). Then rerun. Do not stack Jobs.

### Safe vs unsafe edits

| Safe | Unsafe |
| --- | --- |
| Log lines, comments, HOW-TO wording | New required binary |
| gzip level `-9` → `-6` (faster, larger USB) | zstd, xz, or a second format |
| CPU/memory defaults in `release.env` | Assuming CDI clone always works |
| Extra `oc wait` timeouts | `virtctl stop vm <name>` (extra token) |
| Cleanup matching more leftover names | Deleting `vm-catalog` from cleanup |

---

## 12. Debugging map

| Symptom | Look at |
| --- | --- |
| `cannot create /home/data/...` | Wrong `--transfer-dir`. Use `/tmp/vm-transfer`. |
| `virtctl stop accepts 1 arg(s), received 2` | Someone put `vm` back in the stop line. |
| Job Pending | Work PVC node vs pod node. `lvm` RWO. |
| Forbidden on stop/start | `subresources.kubevirt.io` missing from build Role. |
| `quantity_to_bytes` / Invalid storage | PVC request is bare bytes. Keep the integer branch. |
| Dest “no *.raw.gz” | Bundle is `.raw.zst` from an old build, or raw files present. |
| Clone failed, then upload | Expected on `lvm`. Wait for upload. |
| Work PVC full | Raw not deleted between disks, or PVC formula too small. |
| PodSecurity restricted warnings | Usually noise if the Job still runs. Fix only if it is Denied. |

Useful commands:

```bash
oc get jobs,pvc,cm,sa -n <ns> | grep abc-
oc logs -f job/<job> -n <ns>
oc describe job/<job> -n <ns>
oc get virtualmachineexport -n <ns>
oc get dv,pvc,datasource -n vm-catalog
oc get vm,dv,pvc -n <user-project>
```

---

## 13. Maintenance schedule

These clusters do not get weekly deploys. Reviews are calendar-driven plus event-driven.

### After every production run (operator + one developer)

- Confirm Job Completed and leftover Jobs were cleaned.
- Confirm transfer dir has no `.raw`.
- File the Job name, namespace, source VM, dest VM, and any WARNING lines in the site notes.
- If clone fell back to upload, that is a note, not a ticket.

### Monthly

- Read last month’s failures. Group them (RBAC, PVC bind, export, upload, naming).
- `oc get storageclass` on a lab cluster. Confirm the name is still `lvm`.
- Confirm `openshift/cli:latest` still contains `gzip` and `oc`.
- Confirm `virtctl` still accepts `stop <name> -n <ns>` (no `vm` token). CNV CLI drift is how we got burned before.
- Grep the pod scripts for `zstd`, `jq`, `python`, `helm`. Those should not appear as required commands.

### Each OpenShift / CNV / CDI upgrade (lab first)

- Full end-to-end on a tiny VM: build → checksum → dest → `oc get vm` → optional start.
- Re-test `virtctl vmexport create|download|delete`.
- Re-test `virtctl image-upload dv`.
- Re-test VM stop/start subresources.
- Check DataVolume API group is still `cdi.kubevirt.io/v1beta1` in our apply blobs. If upstream moves to v1, update both seed and deploy apply blocks.

### Quarterly code review (senior + junior, 60–90 minutes)

Walk this list out loud:

1. Bundle contract still matches both Jobs.
2. `vm-tools/` and `scripts/pod/` copies are identical for the files that matter.
3. RBAC templates still cover every API call in the Job scripts.
4. PVC formulas still match the one-disk lifecycle.
5. Cleanup still matches Job name prefix.
6. HOW-TO still matches flags (`--clean`, `--transfer-dir`, storage class name).
7. No new image, no new RPM, no zstd.
8. Legacy bastion scripts still runnable if a site cannot use Jobs.

### Yearly

- Decide whether catalog clone on `lvm` is still hopeless. If LVMS or CDI gains a working clone path, dest can prefer clone and skip the gunzip fallback for **new** deploys only. Keep the fallback.
- Revisit gzip level vs USB size. Only change level. Do not change format without a versioned bundle field.

---

## 14. Review checklist for a PR

- [ ] Change is in `vm-tools/` **and** mirrored under `scripts/` / `manifests/` if those copies exist.
- [ ] Job script and RBAC template updated together.
- [ ] Bundle fields documented if added/renamed.
- [ ] No new required binary.
- [ ] Names still DNS-safe (`k8s_name` dots → dashes).
- [ ] `virtctl stop` / `start` still name-only.
- [ ] HOW-TO / START-HERE updated if flags or file suffixes changed.
- [ ] Cleanup still finds the Job.
- [ ] Lab E2E on a small disk, source **and** dest.

---

## 15. What success looks like

Source: Job Complete, transfer dir contains `*.raw.gz` + checksums, checksums verify, no `.raw`.

Dest: Job Complete, DataSource Ready in `vm-catalog`, VM object exists in the user project, guest is stopped unless `--start`.

That is the whole product. Everything else is plumbing so a disconnected bastion can do those two things without filling its disk.
