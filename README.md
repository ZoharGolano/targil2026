# Targil2026 — DevOps Full Stack Exercise

## Project overview

This project documents the design, implementation, and validation of a self-managed Kubernetes environment, followed by MongoDB, an application Helm chart, Argo CD GitOps deployment, and a security-gated CI/CD pipeline. The goal is to learn by building, testing failures, and documenting operational decisions and troubleshooting.

**Current status (2026-11-22):** Three Ubuntu Server VMs run K3s `v1.37.2+k3s1` with embedded etcd; a one-server outage/recovery test passed. MongoDB `8.0.13` is deployed and validated with a pinned Helm chart. The Node.js Express application is deployed using a custom Helm chart and Argo CD automated GitOps synchronization. GitHub Actions executes tests, dependency auditing, Semgrep SAST, Docker builds, and Trivy HIGH/CRITICAL vulnerability gates before publishing a tested image to GHCR on `main`. The application was bumped to **1.0.1** (chart **0.2.1**) and promoted via a Helm image-tag change; Kubernetes confirmed a successful rollout of **two Pods** running `ghcr.io/zohargolano/sample-nodejs:sha-9e814c88adad`. Argo CD reported **Synced / Healthy** after promotion. The Argo CD UI is available through Traefik at `https://argocd.test` using a lab-only self-signed certificate.

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
| Application | Stateless Node.js / Express service; app version `1.0.1` | Deployment is appropriate because stable Pod identities and persistent volumes are not required |
| Application deployment | Custom Helm chart `0.2.1`; 2 replicas in `sample-app` | Kubernetes-native declarative rollout and reconciliation |
| Application ingress | Traefik, host `sample-nodejs.test` | Host-based HTTP routing within the lab |
| CI/CD | GitHub Actions; test, npm audit, Semgrep, Docker build, Trivy | Block release publication on failed checks / HIGH or CRITICAL findings |
| Container registry | GHCR, commit-SHA tags | Traceability between source, scan, and deployed artifact |
| GitOps | Argo CD `v3.6.2` in `argocd`, automated sync | Git is the deployment source of truth |
| Argo CD dashboard | Traefik HTTPS `argocd.test`; self-signed TLS | Lab-friendly secure browser entry point |

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

### 4. Node.js application and Helm

1. Forked the sample Node.js application into a separate application repository, [`ZoharGolano/sample-nodejs`](https://github.com/ZoharGolano/sample-nodejs).
2. Confirmed Express endpoints `/my-app`, `/ready`, `/live`, and `/metrics` and automated application tests.
3. Built a custom Helm chart using a **Deployment**, rather than a StatefulSet: the application is stateless and needs neither stable network identities nor per-Pod persistent storage.
4. Configured two replicas, a ClusterIP Service (port `80` to container port `8080`), Traefik Ingress (`sample-nodejs.test`), and readiness/liveness probes (`/ready`, `/live`).
5. Set application container requests to `50m` CPU / `64Mi` memory and limits to `250m` CPU / `256Mi` memory. Applied non-root identity `1000:1000`, disabled automatic ServiceAccount token mounting and privilege escalation, and dropped Linux capabilities.
6. Verified Helm lint/rendering and successfully reached application and metrics endpoints through the ingress.

### 5. CI/CD, image security, and version bumping

1. Implemented `.github/workflows/ci-cd.yml` in the application repository with application tests, `npm audit`, Semgrep SAST, image build, and Trivy scanning.
2. Configured Trivy to fail on **HIGH** or **CRITICAL** vulnerabilities. Image publishing to GHCR happens only on the `main` branch after the relevant checks pass; pull requests do not publish images.
3. Published commit-based images, including `ghcr.io/zohargolano/sample-nodejs:sha-9e814c88adad`, and verified that the image manifest exists in GHCR.
4. Updated Node.js application/package version from `1.0.0` to `1.0.1`, Helm chart version from `0.2.0` to `0.2.1`, and Helm `appVersion` to `1.0.1`.

### 6. Argo CD GitOps and release verification

1. Installed Argo CD using Helm in the `argocd` namespace and configured the UI ingress with a self-signed TLS certificate (`https://argocd.test`).
2. Added a declarative Argo CD Application in the application repository (`gitops/application.yaml`), pointing to `main` and the Helm chart at `helm/sample-nodejs`, with automated sync, pruning, and self-healing.
3. Verified automated reconciliation of an application replica-count change via Git, without manually modifying the live Deployment.
4. Promoted the tested application image by changing **only** `helm/sample-nodejs/values.yaml` from `sha-554122410ff7` to `sha-9e814c88adad` and merging the change into `main`.
5. Verified `deployment "sample-nodejs" successfully rolled out`, two application Pods running the new SHA image, and the Argo CD Application `Synced` / `Healthy`.
6. Recorded release and rollout evidence in the application repository's [`gitops/README.md`](https://github.com/ZoharGolano/sample-nodejs/blob/main/gitops/README.md).

### Application delivery and GitOps architecture

```text
Source change (sample-nodejs GitHub repo)
  └── Pull request → GitHub Actions: tests, npm audit, Semgrep, Docker build, Trivy
        └── Merge to main → approved image published to GHCR (sha-... tag)
              └── Explicit Helm values.yaml image-tag update via PR
                    └── Argo CD watches application repo main / Helm chart
                          └── K3s sample-app namespace
                                └── Deployment (2 Pods) → Service → Traefik Ingress
```

**Repository separation:** Infrastructure and MongoDB configuration live in [`ZoharGolano/targil2026`](https://github.com/ZoharGolano/targil2026). Application code, Helm chart, CI/CD workflow, and Argo CD Application manifest live in the separate [`ZoharGolano/sample-nodejs`](https://github.com/ZoharGolano/sample-nodejs) repository. The application checkout may be nested locally under `application/`, but `/application/` is ignored by the infrastructure repository and **must not be committed as a nested repository**.

**Deployment vs. StatefulSet:** The Express service is stateless, so a Deployment provides rolling updates and replica management without unnecessary stable storage or Pod identity. MongoDB is a separate, single-instance lab component; the Node.js application does not depend on MongoDB for its demonstrated endpoints.

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

# From the Ubuntu host (with working kubectl context)
kubectl get application sample-nodejs -n argocd
kubectl rollout status deployment/sample-nodejs -n sample-app
kubectl get pods -n sample-app -o custom-columns='NAME:.metadata.name,IMAGE:.spec.containers[0].image'
curl -i -H 'Host: sample-nodejs.test' http://192.168.122.11/my-app

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
├── .gitignore                     # Excludes nested application checkout
├── infrastructure/
│   ├── kvm/                       # Cloud-init and disk preparation scripts
│   └── argocd/
│       ├── values.yaml            # Argo CD Helm values
│       └── README.md              # Install, TLS and access notes
├── kubernetes/
│   └── mongodb/
│       ├── values.yaml            # Version-controlled settings; no passwords
│       └── README.md              # MongoDB configuration overview
└── docs/
    ├── 01-infrastructure-setup.md
    ├── 02-k3s-ha.md
    └── 03-mongodb-installation.md

# Separate Git repository, cloned locally at:
# ~/targil2026/application/sample-nodejs/
#   Dockerfile, package.json, .github/workflows/ci-cd.yml,
#   helm/sample-nodejs/, gitops/application.yaml, gitops/README.md
```

The three `docs/` installation guides and the MongoDB/Argo CD configuration documentation are tracked in the infrastructure repository. The application repository is independently version-controlled.

## Security and operational limitations

- Never commit Kubernetes Secrets, passwords, private SSH keys, the K3s `server-token`, admin kubeconfigs, or credentials to Git.
- MongoDB authentication is enabled, but the NodePort is reachable within the permitted lab network; the rendered NetworkPolicy does not restrict source IPs.
- MongoDB has **no persistent volume**, so data can be lost when its pod is replaced or rescheduled.
- MongoDB runs as **standalone**, not a replica set; K3s quorum does not provide database HA.
- All three VMs are on one physical host, creating a single point of failure.
- Legacy Bitnami images and disabled image-origin verification are not suitable defaults for production.
- Argo CD ingress uses a self-signed certificate and local `argocd.test` host mapping; it is not a publicly trusted production HTTPS endpoint.
- Pod names, IP addresses, and measured resource consumption may change between runs.

## Final verification tasks

The K3s cluster, MongoDB installation, Node.js Helm deployment, security-gated GitHub Actions workflow, GHCR publishing, Argo CD automated synchronization, and application v1.0.1 image promotion have been implemented and verified as described above.

Remaining documentation/review work:

1. Expand and review the **application repository's** main README as the entry point for app development, testing, Helm, and GitOps.
2. Verify that repository links, prerequisites, and manual installation/recovery instructions are complete and reproducible.
3. Perform the final requirement-by-requirement review for Targil2026.

The lab remains intentionally non-production (single physical host, ephemeral MongoDB storage, legacy database images, and self-signed Argo CD TLS).

## Documentation

- [Infrastructure provisioning — English](docs/01-infrastructure-setup.md)
- [K3s HA and etcd — English](docs/02-k3s-ha.md)
- [MongoDB installation and troubleshooting — English](docs/03-mongodb-installation.md)
- [MongoDB Helm values](kubernetes/mongodb/values.yaml)
- [MongoDB Helm configuration](kubernetes/mongodb/README.md)
- [Argo CD Helm configuration and HTTPS access](infrastructure/argocd/README.md)
- [Application code and Helm chart](https://github.com/ZoharGolano/sample-nodejs)
- [Application GitOps and v1.0.1 release verification](https://github.com/ZoharGolano/sample-nodejs/blob/main/gitops/README.md)

> Progress is marked complete only where corresponding commands or observed results verified it. Updated: **2026-11-22**.