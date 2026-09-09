# Disconnected VM deployment

Copy a VM from a source OpenShift Virtualization cluster to a disconnected cluster. No Internet on dest. No Helm, Ansible, or extra CLI tools.

## Use this

Folder: **[vm-tools/](vm-tools/)**  
Tech sheet: **[vm-tools/START-HERE.txt](vm-tools/START-HERE.txt)**  
Operator guide: **[docs/pod-operator-guide.md](docs/pod-operator-guide.md)**

Storage class on these clusters: **`lvm`**

```bash
cd vm-tools
chmod 0750 build dest

# Source cluster
./build --namespace <src> --vm <vm> --version 0.1.0-test --storage-class lvm --transfer-dir /tmp/vm-transfer

# Dest cluster (seed + create VM, one command)
./dest --bundle-path /path/to/<vm>-0.1.0-test --storage-class lvm --catalog-namespace vm-catalog --namespace <project> --vm-name <new-vm>
```

USB carries the transfer directory (`*.raw.gz` + metadata). Never copy `*.raw`.

## How it works

1. Source Job exports disks and gzip-compresses them in-cluster.
2. Bastion copies compressed files only.
3. Dest Job seeds `vm-catalog` if needed, then creates the VM. On `lvm`, clone usually falls back to `virtctl image-upload`.

## Legacy bastion path

Raw disks on the bastion: `scripts/build-abc-vm-package.sh`, `scripts/seed-abc-vm-catalog.sh`, `scripts/deploy-abc-vm.sh`. See [builder-guide.md](docs/builder-guide.md) and [end-user-deployment.md](docs/end-user-deployment.md).

## Limits

PVC-backed disks only. Source VM must be stopped for a consistent export. Destination needs OpenShift Virtualization + CDI. Created VMs are a minimal spec (CPU, memory, disks, default pod network). Do not commit `*.raw`, `*.raw.gz`, kubeconfigs, or pull secrets.

## License

See [LICENSE](LICENSE).
