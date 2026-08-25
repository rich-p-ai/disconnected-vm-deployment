# ABC VM

Offline package for deploying an ABC VM on disconnected OpenShift Virtualization.

A platform engineer packages an existing VM once. The disks are transferred offline and seeded as versioned DataVolumes + a DataSource in a protected catalog namespace. End users then clone from that DataSource into their own project.

Work is done from an OpenShift bastion with Bash, `oc`, `virtctl`, and standard GNU utilities. No Internet access, Helm, Python, Ansible, `jq`, `yq`, SMB share, or HTTP server is required.

## Guides

| Reader | Document |
| --- | --- |
| Platform engineer packaging the appliance | [Builder guide](docs/builder-guide.md) |
| Cluster user deploying a VM | [End-user deployment guide](docs/end-user-deployment.md) |

## Scripts

| Script | Role |
| --- | --- |
| [`scripts/build-abc-vm-package.sh`](scripts/build-abc-vm-package.sh) | Export a stopped source VM into a versioned bundle |
| [`scripts/seed-abc-vm-catalog.sh`](scripts/seed-abc-vm-catalog.sh) | Upload disks and create the catalog DataSource |
| [`scripts/deploy-abc-vm.sh`](scripts/deploy-abc-vm.sh) | Clone from DataSource / catalog PVCs and create a VM |

Copy the three scripts to the bastion, mark them executable (`chmod 0750`), and follow the matching guide.

Do not commit disk images (`*.raw`), pull secrets, or kubeconfigs to this repository.
