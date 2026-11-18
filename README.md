# Targil2026 — DevOps Full Stack Exercise

## Project overview

This project documents the design, implementation, and validation of a self-managed Kubernetes environment, followed by MongoDB, an application Helm chart, Argo CD GitOps deployment, and a security-gated CI/CD pipeline. The goal is to learn by building, testing failures, and documenting operational decisions and troubleshooting.

**Current status (2026-11-18):** All three Ubuntu virtual machines are provisioned. A three-server K3s cluster with embedded etcd is running, and a one-node K3s outage/recovery test succeeded. **MongoDB 8.0.13 is deployed and validated** using a pinned Bitnami Helm chart. The application, Argo CD, and CI/CD pipeline remain to be implemented.

> **Lab only:** All virtual machines share one physical laptop, so the infrastructure is not physically highly available. MongoDB runs as a single standalone instance with persistence disabled. The deployment uses legacy container images without ongoing security updates and must not be treated as production-ready.

## Infrastructure design

| Component | Implemented design | Rationale |
|---|---|---|
| Virtualization | KVM / QEMU / libvirt | Linux-native VM management on a laptop |
| Guest OS | Ubuntu Server 24.04 | LTS base image with Cloud-init support |
| Kubernetes distribution | K3s `v1.37.2+k3s1` | Lightweight, self-managed Kubernetes for a local lab |
| Cluster topology | Three K3s servers, each running control-plane, embedded etcd, and worker roles | Explore quorum, scheduling, and node failures |
| Node sizing | 2 vCPU, 5120 MiB RAM per VM | Fit three VMs into the available 32 GB laptop RAM |
| Storage per VM | 25 GiB OS + 55 GiB `/var` | Isolate system and Kubernetes runtime data |
| Network | libvirt default NAT, `192.168.122.0/24` | Reproducible local networking and outgoing internet access |
| IP assignment | DHCP reservations by MAC address | Stable per-node IPs without guest static-IP configuration |
| Provisioning | Ubuntu Cloud Image + Cloud-init | Repeatable VM initialization |
| Database | MongoDB `8.0.13`, standalone, no persistent volume | Meet the exercise requirements; intentionally ephemeral |
| Database deployment | Helm `bitnami/mongodb` chart `16.5.45` | Reproducible, pinned installation |

### Hosts

| Host | IP | Kubernetes roles | Status |
|---|---|---|---|
| `k3s-node01` | `192.168.122.11` | Control plane + etcd + worker | Ready |
| `k3s-node02` | `192.168.122.12` | Control plane + etcd + worker | Ready; outage/recovery tested |
| `k3s-node03` | `192.168.122.13` | Control plane + etcd + worker | Ready; hosts the MongoDB pod at last verification |

### Current deployment architecture

```text
Ubuntu laptop — KVM / libvirt NAT (192.168.122.0/24)
│
├── k3s-node01  192.168.122.11 ─┐
├── k3s-node02  192.168.122.12 ─┼── K3s HA control plane / embedded etcd (3 members)
└── k3s-node03  192.168.122.13 ─┘
           │
           └── Namespace: mongodb
               ├── MongoDB 8.0.13 (standalone; one pod)
               │   └── Service: NodePort 32017 → TCP 27017
               └── MongoDB Exporter (sidecar)
                   └── Service: ClusterIP TCP 9216 → /metrics
```

The configured MongoDB Service has `externalTrafficPolicy: Local`. At the time of testing, the MongoDB pod was on `k3s-node03`, so the host-side TCP test targeted `192.168.122.13:32017`. That address may need to change if the pod is rescheduled.

## Completed work

### 1. VM infrastructure

1. Verified laptop hardware, VT-x/KVM, QEMU/libvirt, and capacity; resolved libvirt socket permissions.
2. Configured libvirt `default` NAT (`192.168.122.0/24`) and DHCP reservations for `.11`, `.12`, and `.13` with unique MAC addresses.
3. Provisioned three Ubuntu 24.04 virtual machines with Cloud-init, SSH keys, 2 vCPU, and 5120 MiB RAM each.
4. Created two QCOW2 disks per VM: 25 GiB OS and 55 GiB dedicated ext4 `/var`.
5. Migrated `/var` offline while preserving ownership, ACLs, and extended attributes; added `create-vm-disks.sh` and `prepare-var-disk.sh` provisioning scripts.
6. Diagnosed transient `umount: target is busy` errors, improved bounded-retry cleanup, and verified the disk mounts and boot process.
7. Verified network connectivity, cloud-init completion, disk layout, and system service health.

### 2. K3s and embedded etcd

1. Installed pinned K3s `v1.37.2+k3s1` on all three servers; `k3s-node01` initialized embedded etcd, and nodes 02/03 joined as additional servers.
2. Confirmed all nodes were `Ready` and running the combined `control-plane,etcd` roles.
3. Verified Kubernetes API readiness and all three etcd members using `etcdctl member list`, `endpoint status --cluster`, and `endpoint health --cluster`.
4. Saved a pre-test etcd snapshot on `k3s-node03`.
5. Stopped K3s on `k3s-node02`: the node became `NotReady`, but the Kubernetes API and the remaining two etcd endpoints stayed healthy (2/3 quorum).
6. Restarted K3s on `k3s-node02` and confirmed all nodes returned to `Ready` and all three etcd endpoints were healthy.

**HA limitation:** This demonstrates tolerance of a single K3s server outage, not tolerance of losing the common physical laptop. A separate etcd-leader failure scenario was not tested.

### 3. MongoDB with Helm

1. Installed Helm `v3.22.1` and pinned Bitnami MongoDB chart `16.5.45` (application version `8.0.13`).
2. Created the `mongodb` namespace and a Kubernetes Secret, `mongodb-credentials`, containing the `mongodb-root-password` key. The password itself is **not stored in Git**.
3. Created [`kubernetes/mongodb/values.yaml`](kubernetes/mongodb/values.yaml) with standalone architecture, authentication, explicit requests/limits, disabled persistence, NodePort `32017`, and enabled exporter metrics.
4. Used `helm template` to inspect the generated Deployment, Services, NetworkPolicy, and other resources before installation.
5. Installed MongoDB successfully; Helm release `mongodb` reached `deployed` and its pod reached `2/2 Running` with zero restarts at verification time.
6. Confirmed the running database reports **`db version v8.0.13`** with `mongod --version`.
7. Authenticated with `mongosh` and successfully ran `db.adminCommand({ping: 1})`, receiving `{ ok: 1 }`.
8. Tested NodePort reachability from the laptop with `nc -vz -w 5 192.168.122.13 32017`; the TCP connection succeeded.
9. Queried exporter `/metrics` through `kubectl port-forward` and observed `mongodb_up{cluster_role="mongod"} 1`.
10. Confirmed container resource configuration, measured live CPU/memory usage, and verified that no PVC exists in the `mongodb` namespace.

### MongoDB configuration and verification

| Parameter | Verified result |
|---|---|
| Chart / release | `bitnami/mongodb` `16.5.45` / `mongodb` |
| MongoDB version | `8.0.13` (verified inside the container) |
| Namespace | `mongodb` |
| Architecture | Standalone |
| Authentication | Root authentication succeeded; password referenced via Kubernetes Secret |
| MongoDB Service | `NodePort`, `27017:32017/TCP` |
| Metrics Service | `ClusterIP`, `9216/TCP` |
| Exporter health | `mongodb_up{cluster_role="mongod"} 1` |
| Persistence | Disabled; no PVC found |
| MongoDB requests | `250m` CPU; `512Mi` memory |
| MongoDB limits | `1` CPU; `2Gi` memory |
| Exporter requests | `50m` CPU; `64Mi` memory |
| Exporter limits | `200m` CPU; `256Mi` memory |
| Observed MongoDB usage | `90m` CPU; `89Mi` memory (point-in-time sample) |
| Observed exporter usage | `1m` CPU; `11Mi` memory (point-in-time sample) |

**Metrics scope:** The exporter is healthy and serving Prometheus-format metrics. Automatic collection by a Prometheus server has **not** yet been verified.

## Troubleshooting and lessons learned

**Libvirt permissions:** A regular user could not access the `root:libvirt` Unix socket, although `sudo virsh` worked. Group permissions were updated and access revalidated.

**ACL preservation:** `rsync -aHAX` over guestmount reported `set_acl: Invalid argument` for systemd journal paths. Direct ext4 mounts via qemu-nbd allowed the transfer to complete without reported errors.

**Idempotency:** Repeating `tee -a` appended a duplicate `/var` entry to node01 `fstab`; it was removed. `prepare-var-disk.sh` is for initial provisioning and must not be rerun on already-prepared disks without review.

**Disk safety:** QCOW2 images were edited only when guests were shut down and the relevant filesystems were unmounted. Disk identifiers were checked before formatting.

**Transient unmount failure:** On node02, copying and fstab updates completed but cleanup returned `target is busy`; manual cleanup succeeded. On node03, a bounded retry succeeded on the third attempt. The exact cause was not established.

**Helm repository under `sudo`:** `helm install` initially failed with `repo bitnami not found` because the repository was registered under the regular user while installation ran as root. Running `sudo helm repo add bitnami https://charts.bitnami.com/bitnami` and `sudo helm repo update` resolved it.

**MongoDB file-based credentials:** An initial `mongosh` login failed because `MONGODB_ROOT_PASSWORD` was not set inside the container. The chart instead provided `MONGODB_ROOT_PASSWORD_FILE`; reading the password from the mounted secret file allowed successful authentication. Do not print or commit secret values.

**Network policy and NodePort:** The rendered NetworkPolicy allows ingress to ports `27017` and `9216` without source restrictions. It is not an effective source-IP allowlist; access must be controlled through the surrounding network/firewall and other suitable measures. A successful `nc` connection validates TCP reachability only, not MongoDB authentication.

**Legacy Bitnami images:** The lab uses `docker.io/bitnamilegacy/mongodb:8.0.13-debian-12-r0` and `docker.io/bitnamilegacy/mongodb-exporter:0.47.0-debian-12-r1`. These legacy images do not receive normal security maintenance. `global.security.allowInsecureImages: true` bypasses the chart's original image verification; this is a lab-only compromise.

## Validation commands

```bash
# On the Ubuntu laptop
virsh -c qemu:///system list --all
virsh -c qemu:///system net-dhcp-leases default
nc -vz -w 5 192.168.122.13 32017

# On a K3s server
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
sudo k3s kubectl get pods,svc -n mongodb -o wide
sudo k3s kubectl -n mongodb exec deploy/mongodb -c mongodb -- mongod --version
sudo k3s kubectl top pod -n mongodb --containers
sudo k3s kubectl get pvc -n mongodb
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm list -n mongodb

# Authenticated MongoDB ping: password is read from a mounted Secret file.
# Note: using --password exposes the value briefly in the mongosh process arguments.
sudo k3s kubectl -n mongodb exec deploy/mongodb -c mongodb -- bash -c '
  mongosh --quiet --host 127.0.0.1 \
    --username "$MONGODB_ROOT_USER" \
    --password "$(cat "$MONGODB_ROOT_PASSWORD_FILE")" \
    --authenticationDatabase admin \
    --eval "db.adminCommand({ping: 1})"
'

# In one terminal on the K3s server:
sudo k3s kubectl -n mongodb port-forward svc/mongodb-metrics 9216:9216

# In another terminal on the same server:
curl -fsS http://127.0.0.1:9216/metrics | grep '^mongodb_up'
```

## Repository layout

```text
targil2026/
├── README.md
├── infrastructure/
│   └── kvm/                       # VM setup, cloud-init, disk preparation scripts
├── kubernetes/
│   └── mongodb/
│       └── values.yaml            # Version-controlled Helm values; no passwords
└── docs/
    ├── 01-infrastructure-setup.md
    ├── 02-k3s-ha.md
    └── 03-mongodb-installation.md
```

Documentation availability depends on which files have been copied into the local Git checkout. The links below are intended repository paths; check files before committing.

## Security and operational limitations

- Never commit Kubernetes Secrets, passwords, private SSH keys, the K3s `server-token`, admin kubeconfigs, or credentials to Git.
- MongoDB authentication is enabled, but the NodePort is reachable within the permitted lab network; the rendered NetworkPolicy does not restrict source IPs.
- MongoDB has **no persistent volume**, so data can be lost when its pod is replaced or rescheduled.
- MongoDB runs as **standalone**, not a replica set; K3s quorum does not provide database HA.
- All three VMs are on one physical host, creating a single point of failure.
- Legacy Bitnami images and disabled image-origin verification are not suitable defaults for production.
- Pod names, IP addresses, and measured resource consumption may change between runs.

## Next milestones

1. Ensure this README, the MongoDB values file, and the step-by-step documentation are tracked in the main Git repository, then push safely to GitHub.
2. Fork or prepare the exercise application, build its Docker image, and deploy it with an application Helm chart.
3. Install Argo CD and configure GitOps to reconcile application manifests from Git.
4. Create GitHub Actions workflows for SAST, Trivy image vulnerability scans, and a HIGH-severity gate before publishing/deploying images.
5. Document and validate the end-to-end change, build, scan, publish, and GitOps deployment workflow.

## Documentation

- [Infrastructure provisioning — English](docs/01-infrastructure-setup.md)
- [K3s HA and etcd — English](docs/02-k3s-ha.md)
- [MongoDB installation and troubleshooting — English](docs/03-mongodb-installation.md)
- [MongoDB Helm values](kubernetes/mongodb/values.yaml)

> Progress is marked complete only where corresponding commands or observed results verified it. Updated: **2026-11-18**.
