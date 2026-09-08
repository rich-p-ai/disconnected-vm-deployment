# Smoke test

Small stopped VM, one PVC, 20–40Gi. Storage class **`LVM`**.

```bash
cd vm-tools
chmod 0750 build dest
oc whoami
oc get storageclass LVM
```

## Source

```bash
./build \
  --namespace <src-ns> \
  --vm <test-vm> \
  --version 0.1.0-test \
  --storage-class LVM \
  --transfer-dir /tmp/vm-transfer
```

Pass: `/tmp/vm-transfer/<vm>-0.1.0-test/` has `*.raw.gz` + `checksums.sha256`, no `*.raw`.

## USB

Copy that directory. On dest: `sha256sum -c checksums.sha256`.

## Dest

```bash
oc get ns <user-project> || oc new-project <user-project>

./dest \
  --bundle-path /tmp/vm-transfer/<vm>-0.1.0-test \
  --storage-class LVM \
  --catalog-namespace vm-catalog \
  --namespace <user-project> \
  --vm-name test-vm-01
```

No `--start` on the first run. Clone-fail then image-upload is normal on `LVM`.

## Optional power-on

```bash
virtctl start vm test-vm-01 -n <user-project>
```

Cleanup commands are printed by `./build` and `./dest`.
