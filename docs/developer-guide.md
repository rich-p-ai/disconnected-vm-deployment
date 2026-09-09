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
- Extra binaries must already exist on RHEL / OpenShift, or we stage them from the cluster. Compression is **gzip -9**, not zstd.
- Storage class on these sites is **`lvm`** (LVMS / TopoLVM, local RWO). CDI clone across namespaces usually fails. Image-upload fallback is expected, not an error.
- Some guests (TrueNAS-backed volumes) advertise multi-petabyte PVC requests. The **work PVC is capped at 300Gi**. Do not remove that cap.

If a change violates one of those, it is the wrong change.

---

## 2. Mental model

Two machines, two logins, one USB stick. **One `./build` command, two Jobs.**

```
bastion (source)              cluster (source)                 USB            cluster (dest)
----------------              ----------------                 ---            --------------
./build                       Job A abc-build-*                               ./dest
  SA / RBAC / work PVC          stop VM, vmexport, gzip -9
  stage virtctl                 write /work/bundle on work PVC
  start Job A
  wait Job A Complete
  start Job B abc-*-xfer        Job B sleeps on same work PVC
  oc cp + sha256 verify         (holds RWO so bastion can pull)
./fetch                         retry of the copy only
```

Job A Complete in the console is **not** “files are on the bastion.”
Done means checksums verified under `--transfer-dir`.

**Bastion scripts orchestrate.** They apply YAML and `oc cp`. They never decompress a guest disk.

**Job A does the heavy I/O.** Job B only keeps the PVC mounted.

A second cluster Job cannot write to the bastion disk. Transfer is always pull-from-PVC on the bastion (`oc cp` with retries).

---

## 3. Tree you actually maintain

The package techs copy is **`vm-tools/`**. That folder must stay self-contained.

```
vm-tools/
  START-HERE.txt
  HOW-TO.txt
  build                   → scripts/pod/kickoff-build.sh
  dest                    → scripts/pod/kickoff-dest.sh
  fetch                   → scripts/pod/kickoff-fetch.sh
  cleanup
  docs/developer-guide.md
  scripts/pod/
    lib-kickoff.sh
    kickoff-build.sh
    kickoff-fetch.sh
    kickoff-dest.sh
    job-build.sh
    job-seed-deploy.sh
  scripts/lib/oc-virtctl.sh
  manifests/pod/
    job-build.yaml.tpl
    job-dest.yaml.tpl
    rbac-job-build.yaml.tpl
    rbac-job-dest.yaml.tpl
```

If a second copy exists under repo-root `scripts/pod/` or `manifests/pod/`, **edit both**.

Legacy bastion path stays. Do not delete it. Do not make the pod path depend on it.

---

## 4. Object graph a kickoff creates

| Object | Build | Transfer | Dest |
| --- | --- | --- | --- |
| ServiceAccount | Job namespace | same SA as build | user project |
| Role + RoleBinding | Job namespace | reused | user project **and** `vm-catalog` |
| Work PVC (`<build-job>-work`) | RWO on `lvm`, **max 300Gi** | same PVC | RWO on `lvm` |
| ConfigMap (`<job>-scripts`) | `job-build.sh` | none | `job-seed-deploy.sh` |
| Staging pod (`<job>-stage`) | virtctl onto PVC | — | virtctl + bundle onto PVC |
| Job A `abc-build-*` | export + gzip | — | — |
| Job B `abc-xfer-*` (or `abc-build-*-xfer`) | — | sleep 4h on work PVC | — |
| Job `abc-dest-*` | — | — | seed + deploy |

`cleanup` matches `^abc-(build|dest|xfer)-`. If you rename the prefix, update cleanup.

Do **not** run `./cleanup` until `sha256sum -c checksums.sha256` is OK on the bastion. Cleanup deletes the work PVC and the bundle on it.

Jobs use `backoffLimit: 0` and `restartPolicy: Never`.
`ttlSecondsAfterFinished: 86400` is a backstop only.

---

## 5. Source path — what `./build` does

### 5.1 Bastion (`kickoff-build.sh`)

1. Confirm `oc` login, VM exists, StorageClass exists.
2. Optional `--clean` deletes leftover Jobs in that namespace. Skip `--clean` if another work PVC still holds a bundle you have not copied.
3. Compute work PVC: `sum(source PVC requests) + 10Gi`, then **cap at 300Gi** (`MAX_WORK_PVC`).
4. Resolve Job image (`openshift/cli:latest`, then CNV images).
5. Apply RBAC. Create work PVC. Wait Bound.
6. Stage `virtctl` onto `/work/bin`.
7. ConfigMap with `job-build.sh`. Start **Job A**. Stream logs. Wait Complete (24h).
8. Release RWO attach (delete Job A pods still holding the volume).
9. Start **Job B** (transfer helper, `sleep 14400`) on the same PVC.
10. `oc cp` each `/work/bundle/*` file with retries. Refuse `*.raw`.
11. `sha256sum -c checksums.sha256`. Only then print success.
12. Leave the PVC. Operator runs `./cleanup` after USB copy.

If step 10–11 dies, **do not rebuild**. Run:

```bash
./fetch --namespace <ns> --pvc <job>-work --transfer-dir <dir> --bundle-name <vm>-<version>
```

`--transfer-dir` must be writable. Prefer `/tmp/vm-transfer` or `$HOME/vm-transfer`. Never `/home/data` unless the account owns it.

Changing the cap: one line in `kickoff-build.sh`, `MAX_WORK_PVC="300Gi"`. Recreate the Job and PVC; you cannot grow a bound LVMS claim in this pipeline.

### 5.2 Job A (`job-build.sh`)

Unchanged contract: stop VM (`virtctl stop <name> -n <ns>`, no `vm` token), export, gzip -9 one disk at a time, write bundle, delete export.

If the guest has a multi-TB data volume, Job A may still try to export it and fill the 300Gi cap. Prefer guests whose **root** disk gzip fits in 300Gi. Do not raise the cap to match a bogus TrueNAS request (we have seen `2181337249Gi`).

### 5.3 Job B + `./fetch`

Job B does not copy to the bastion. It holds the volume.

`copy_pvc_to_local` in `lib-kickoff.sh`:

- `release_rwo_attach` — delete pods still using the work PVC
- `start_xfer_job` — Job + sleep
- `oc_cp_retry` — up to 8 tries per file
- checksum verify

`lvm` is RWO. If Job A’s pod is still around, Job B stays Pending. That is why we delete the completed build pods before transfer.

---

## 6. Dest path — what `./dest` does

Unchanged: seed `vm-catalog` if needed, clone-or-upload, minimal VM. Reject `*.raw`. Gunzip one disk at a time.

---

## 7. Bundle contract

```
<vm>-<version>/
  release.env
  disks.tsv
  checksums.sha256
  source-vm.yaml
  source-pvcs.yaml
  source-disks.tsv
  <volume>.raw.gz
```

Never put uncompressed `.raw` in the transfer directory. Dest rejects `.raw.zst`.

---

## 8. RBAC

Unchanged. Build Role must include `virtualmachines/stop` and `start` subresources.

Transfer Job reuses the build SA. It only needs to mount the PVC and run `sleep`. Do not invent a second Role unless you drop the shared SA.

---

## 9. Storage and sizing

`lvm` is RWO and node-local. Staging pod, Job A, and Job B must follow the PVC.

**Work PVC formula (build):**

```
min( sum(source PVC requests) + 10Gi,  300Gi )
```

TrueNAS / CSI guests often advertise nonsense request values. The cap is mandatory. A Pending work PVC with `ResourceExhausted` and a request in the millions of Gi is the uncapped sizer — not an empty cluster.

`quantity_to_bytes` must accept bare integer bytes. Do not “simplify” it.

Do not flip StorageClass `reclaimPolicy` to Retain for this tool. The USB directory is the product. The work PVC is scratch. Retain on site-wide `lvm` hurts every other app.

---

## 10. Commands you are allowed to depend on

| Where | Allowed |
| --- | --- |
| Bastion | `bash`, `oc`, coreutils, `virtctl` (or copy from a CNV pod) |
| Job image | `openshift/cli`: `bash`, `oc`, `gzip`/`gunzip`, `sha256sum`, `tar`, `awk` |

Do **not** add: `jq`, `yq`, Python, Helm, Ansible, zstd, custom RPMs, a new image.

---

## 11. How to change the code without hurting a site

1. Change `vm-tools/scripts/pod/` and `vm-tools/manifests/pod/` first.
2. Mirror repo-root copies if they exist.
3. Bundle format changes go in both Jobs + docs in the same PR.
4. Keep wrappers (`build`, `dest`, `fetch`, `cleanup`) stupid.
5. Test on a small disk before production Windows / TrueNAS.
6. After a **failed** test you may `./cleanup`. After a **successful Job A** with no bastion copy, do not cleanup — `./fetch`.

### Safe vs unsafe edits

| Safe | Unsafe |
| --- | --- |
| Log lines, HOW-TO wording | New required binary |
| `MAX_WORK_PVC` 300Gi → 400Gi | Removing the cap |
| gzip `-9` → `-6` | zstd / second format |
| Extra `oc cp` retries | Deleting work PVC from cleanup before checksums |
| Cleanup matching `xfer` | Deleting `vm-catalog` from cleanup |
| | `virtctl stop vm <name>` |

---

## 12. Debugging map

| Symptom | Look at |
| --- | --- |
| `cannot create /home/data/...` | `--transfer-dir`. Use `/tmp/vm-transfer`. |
| Job A Complete, empty transfer dir | Copy never ran. `./fetch`. Do not cleanup. |
| Transfer Job Pending | RWO still attached to Job A pod. Delete that pod, keep the PVC. |
| `Requested storage (2181337249Gi)` | Cap missing or old script. Need 300Gi cap. |
| `virtctl stop accepts 1 arg(s), received 2` | Extra `vm` token. |
| Job Pending / FailedScheduling | Work PVC node vs pod node. |
| Forbidden on stop/start | Build Role subresources. |
| Dest “no *.raw.gz” | Old `.raw.zst` or raw files. |
| Clone failed, then upload | Expected on `lvm`. |
| Work PVC full | Raw not deleted between disks, or 300Gi too small for that gzip. |

```bash
oc get jobs,pvc,cm,sa,pod -n <ns> | grep abc-
oc logs -f job/<build-job> -n <ns>
oc get pvc <build-job>-work -n <ns>
sha256sum -c checksums.sha256
```

---

## 13. Maintenance schedule

### After every production run

- Job A Complete **and** transfer-dir checksums OK.
- No `.raw` in the transfer dir.
- Then `./cleanup --namespace <ns>`.
- Note Job names, VM, WARNINGs (including “capped at 300Gi”).

### Monthly

- Failures grouped: RBAC, PVC bind, export, `oc cp`, upload, naming.
- Confirm StorageClass name is still `lvm`.
- Confirm `openshift/cli` still has `gzip`.
- Confirm `virtctl stop <name> -n <ns>`.
- Grep for `zstd`, `jq`, `python`, `helm` as required commands.

### Each OpenShift / CNV / CDI upgrade (lab first)

- Tiny VM E2E: build → fetch/checksum → dest → `oc get vm`.
- Re-test vmexport, image-upload, stop/start subresources.
- Confirm DataVolume API group.

### Quarterly (senior + junior, 60–90 min)

1. Bundle contract matches both Jobs.
2. `vm-tools/` mirrors match.
3. RBAC covers every Job API call.
4. 300Gi cap still present; cleanup matches `xfer`.
5. HOW-TO matches flags.
6. No new image / RPM / zstd.
7. Legacy bastion scripts still runnable.

### Yearly

- Revisit whether catalog clone on `lvm` works. Keep upload fallback.
- Revisit gzip level only. Do not change format without a versioned bundle field.
- Revisit 300Gi cap vs real root-disk sizes.

---

## 14. Review checklist for a PR

- [ ] Change is in `vm-tools/` and mirrored if copies exist.
- [ ] Job script and RBAC updated together.
- [ ] Bundle fields documented if added/renamed.
- [ ] No new required binary.
- [ ] `MAX_WORK_PVC` still set.
- [ ] `virtctl stop` / `start` still name-only.
- [ ] `./fetch` still works if copy dies after Job A.
- [ ] Cleanup still finds `build`, `dest`, and `xfer`.
- [ ] HOW-TO / START-HERE updated if flags changed.
- [ ] Lab E2E on a small disk, source **and** dest.

---

## 15. What success looks like

Source: Job A Complete, Job B Running or copy finished, transfer dir has `*.raw.gz` + checksums, checksums verify, no `.raw`.

Dest: Job Complete, DataSource Ready in `vm-catalog`, VM exists in the user project, guest stopped unless `--start`.

That is the whole product.
