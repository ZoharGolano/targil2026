# Targil2026 — Final Project Report

**Report date:** 2026-11-22  
**Project:** Self-managed Kubernetes and DevSecOps laboratory  
**Infrastructure repository:** https://github.com/ZoharGolano/targil2026  
**Application repository:** https://github.com/ZoharGolano/sample-nodejs  
**Overall result:** Core lab implementation and end-to-end application rollout successfully validated. This is a lab environment, not a production-ready reference architecture.

## 1. Executive summary

Targil2026 demonstrates a complete development-to-deployment workflow on a self-managed three-node K3s cluster. The infrastructure runs as Ubuntu Server virtual machines on a single KVM/libvirt host. The lab includes a standalone MongoDB deployment, a stateless Express/Node.js application packaged with Helm, a GitHub Actions security-gated image pipeline, GitHub Container Registry (GHCR), and Argo CD for declarative GitOps delivery.

A release from application version `1.0.0` to `1.0.1` was implemented, scanned, published, promoted by changing a Helm image tag in Git, and successfully rolled out by Argo CD without manually editing the live Deployment.

**Verification scope:** The cluster, Argo CD, workload status, image reference, rollout, and HTTP ingress were checked on 2026-11-22. Some CI checks, detailed application tests, and MongoDB functional checks were validated earlier in the project, rather than rerun during the final cluster check.

## 2. Architecture

```text
Ubuntu host (KVM / QEMU / libvirt, 192.168.122.0/24)
    |
    +-- k3s-node01 (192.168.122.11) --+
    +-- k3s-node02 (192.168.122.12) --+-- K3s v1.37.2+k3s1
    +-- k3s-node03 (192.168.122.13) --+   embedded etcd, three server nodes
                                           |
                                           +-- mongodb namespace
                                           |     MongoDB 8.0.13 + exporter
                                           |     standalone; persistence disabled
                                           |
                                           +-- sample-app namespace
                                           |     Node.js Deployment (2 replicas)
                                           |     ClusterIP Service -> Traefik Ingress
                                           |     http://sample-nodejs.test/my-app
                                           |
                                           +-- argocd namespace
                                                 Argo CD GitOps controller/server
                                                 https://argocd.test

Application Git repository -> GitHub Actions:
    tests + npm audit + Semgrep -> Docker build -> Trivy gate
    -> publish approved commit-tagged image to GHCR
    -> Helm values image-tag update in Git
    -> Argo CD auto-sync -> Kubernetes rolling update
```

### 2.1 Infrastructure design choices

| Component | Design | Reason / trade-off |
|---|---|---|
| Virtualization | KVM/QEMU/libvirt on Ubuntu host | Reproducible local Linux VM lab |
| Guest OS | Ubuntu Server 24.04 | LTS guest OS with cloud-init |
| Kubernetes | Three K3s server nodes with embedded etcd | Practical quorum and node-failure exercises |
| Network | libvirt NAT `192.168.122.0/24` | Predictable local addressing; not public internet exposure |
| Database | Standalone MongoDB with Helm | Matches lab exercise; not a highly available database |
| Application controller | Kubernetes **Deployment** | Stateless HTTP service requires neither stable Pod identity nor per-Pod persistent storage; a StatefulSet would add unnecessary complexity |
| Application packaging | Helm chart | Parameterized, reproducible Kubernetes declarations |
| Delivery | Separate application and infrastructure Git repositories | Independent application review/releases and infrastructure documentation |
| Reconciliation | Argo CD automated sync, prune and self-heal | Declarative desired state rather than manual `kubectl` rollout changes |

All three VM nodes share **one physical computer**; their control-plane quorum tolerates a server/VM outage but does not remove the physical host as a single point of failure.

## 3. Infrastructure and database implementation

- **K3s:** `v1.37.2+k3s1` on `k3s-node01`, `k3s-node02`, and `k3s-node03`, each reporting `Ready` with `control-plane,etcd` roles during final validation.
- **K3s recovery exercise:** A single-server outage/recovery test previously confirmed that two surviving etcd members retained quorum and cluster access; the stopped node rejoined successfully.
- **MongoDB:** Version `8.0.13`, standalone mode, Helm chart `bitnami/mongodb` `16.5.45`, namespace `mongodb`. Authentication is backed by a Kubernetes Secret; its value is not kept in Git.
- **MongoDB access:** Lab NodePort `32017` to port `27017`; MongoDB exporter provides Prometheus-style metrics on port `9216`.
- **MongoDB storage:** Persistence intentionally disabled, so pod replacement or rescheduling can result in data loss.
- **Known database risks:** Legacy Bitnami images, permissive lab-only connectivity, no database HA, and a database pod showing four historical container restarts at the 2026-11-22 final check. The pod was `2/2 Running` then; cause of those restarts was not investigated during that check.

For installation details and troubleshooting, see [`docs/01-infrastructure-setup.md`](01-infrastructure-setup.md), [`docs/02-k3s-ha.md`](02-k3s-ha.md), and [`docs/03-mongodb-installation.md`](03-mongodb-installation.md).

## 4. Application and Helm configuration

| Item | Implemented configuration |
|---|---|
| Runtime | Express.js application with `prom-client`; Node.js-based tests |
| Application version | `1.0.1` |
| Helm chart version / `appVersion` | `0.2.1` / `1.0.1` |
| Docker | Multi-stage image; non-root runtime user |
| Replicas | 2 |
| HTTP endpoints | `/my-app`, `/ready`, `/live`, `/metrics` |
| Service | `ClusterIP`, service port `80` to application port `8080` |
| Ingress | Traefik, host `sample-nodejs.test` |
| Readiness / liveness | `/ready` / `/live` |
| CPU request / limit | `50m` / `250m` |
| Memory request / limit | `64Mi` / `256Mi` |
| Security | Non-root UID 1000, privilege escalation disabled, dropped Linux capabilities, ServiceAccount token automount disabled |
| Deployed image | `ghcr.io/zohargolano/sample-nodejs:sha-9e814c88adad` |

The Node.js service is **stateless** and therefore uses a Deployment, not a StatefulSet. MongoDB is a separate lab workload; no application-to-database dependency was introduced into the Node.js sample.

## 5. CI/CD, security controls, and release management

The application GitHub Actions workflow implements these stages:

1. Run Node.js application tests and npm dependency auditing.
2. Perform Semgrep static application security testing (SAST).
3. Build a Docker image.
4. Scan the built image using Trivy, with an enforced nonzero exit on `HIGH` or `CRITICAL` vulnerabilities.
5. On successful `main` pushes, publish the scanned image to GHCR using a commit-derived `sha-...` tag.
6. Promote an approved image by updating the Helm chart's pinned image tag through a Git pull request.
7. Let Argo CD synchronize the declared desired state into the K3s cluster.

GitHub Actions jobs were observed passing for the version-bump workflow. Previous image-scanning validation showed zero HIGH/CRITICAL findings for the image then tested. The report does not claim a fresh vulnerability scan was performed during the final Kubernetes verification.

### 5.1 Version 1.0.1 promotion

| Release item | Value |
|---|---|
| Previous image tag | `sha-554122410ff7` |
| Application version | `1.0.1` |
| Version-bump merge commit | `9e814c88adadde88d34142d52b63d220113cb707` |
| Published and promoted image | `ghcr.io/zohargolano/sample-nodejs:sha-9e814c88adad` |
| Promotion location | `helm/sample-nodejs/values.yaml` |
| GitOps reconciliation | Argo CD automatic sync |
| Final result | Both application Pods running the promoted image; Deployment rollout succeeded |

The `main` branch may also generate a distinct CI image for documentation-only or promotion commits; the Helm image tag is intentionally pinned to the specific reviewed, validated application build.

## 6. Final validation evidence — 2026-11-22

The following results were provided from the Ubuntu host against the running cluster.

### 6.1 K3s node readiness

```text
NAME         STATUS   ROLES                VERSION
k3s-node01   Ready    control-plane,etcd   v1.37.2+k3s1
k3s-node02   Ready    control-plane,etcd   v1.37.2+k3s1
k3s-node03   Ready    control-plane,etcd   v1.37.2+k3s1
```

### 6.2 Argo CD synchronization

```text
NAME            SYNC STATUS   HEALTH STATUS
sample-nodejs   Synced        Healthy
```

### 6.3 Application availability and image

```text
deployment.apps/sample-nodejs   2/2   2   2
pod/sample-nodejs-5cd64c9df-v7bgc   1/1   Running   0
pod/sample-nodejs-5cd64c9df-vzg2g   1/1   Running   0

deployment "sample-nodejs" successfully rolled out

ghcr.io/zohargolano/sample-nodejs:sha-9e814c88adad
```

The application Service was a `ClusterIP` on port 80. The Traefik Ingress advertised `sample-nodejs.test` through addresses `192.168.122.11`, `.12`, and `.13`.

### 6.4 HTTP ingress test

Command:

```bash
curl -i -H 'Host: sample-nodejs.test' http://192.168.122.11/my-app
```

Observed response:

```text
HTTP/1.1 200 OK

Hello, World!
```

This proves HTTP request routing through the Traefik-facing endpoint to the application at the time of testing.

### 6.5 MongoDB status

```text
mongodb-549c7d7475-hrt6d   2/2   Running   4 (23h ago)
```

The MongoDB pod was running, but historical restarts should be examined as a follow-up operational exercise.

## 7. Requirements traceability

| Requirement | Evidence / implementation | Status |
|---|---|---|
| Forked sample Node.js project | Application repository `ZoharGolano/sample-nodejs` | Implemented |
| Container packaging | `Dockerfile`, `.dockerignore` | Implemented |
| Helm chart | `helm/sample-nodejs/` | Implemented |
| Explain Deployment vs StatefulSet | Stateless workload design in this report and project documentation | Documented |
| Probes | Helm Deployment `/ready`, `/live` | Implemented |
| Service and Ingress | Helm templates, Traefik route | Verified running |
| Resource requests/limits | Helm values and rendered deployment | Implemented |
| Security configuration | Restricted runtime settings in Helm templates | Implemented |
| SAST | `.github/workflows/ci-cd.yml`, Semgrep | Previously validated |
| Dependency scan | `.github/workflows/ci-cd.yml`, npm audit | Previously validated |
| Image scan gate | `.github/workflows/ci-cd.yml`, Trivy HIGH/CRITICAL | Previously validated |
| Registry publishing | GHCR image tag verified | Verified |
| Version bump | `package.json`, lockfile, chart version/appVersion | Verified |
| GitOps declarative deployment | `gitops/application.yaml`, `gitops/README.md` | Verified |
| Automated promotion/rollout | Helm value change, Argo CD Synced/Healthy, two new Pods | Verified |
| Documentation | Infrastructure `README.md`, `docs/`, MongoDB and Argo CD docs; application README and GitOps docs | Maintained in Git; final branch status should be checked separately |

**Important interpretation:** “Implemented” or “previously validated” reflects evidence collected during the exercise; it does not mean every check was rerun on the final reporting date.

## 8. Key troubleshooting and lessons learned

- **KVM guest lifecycle:** After a physical host restart, libvirt guests must be verified and started as necessary before accessing K3s.
- **Kubernetes CLI access:** The Ubuntu host's `kubectl` works against the K3s cluster; guest-local kubeconfig and SSH access are not required for routine host-side checks.
- **Git repository boundaries:** `application/sample-nodejs` is a separate Git checkout nested under the infrastructure checkout. The infrastructure `.gitignore` excludes `/application/`, preventing accidental tracking or nested repository commits.
- **GitHub PR targeting:** Application changes must target `ZoharGolano/sample-nodejs` `main`, not the upstream starter repository.
- **Helm correctness:** Values/template output were validated with `helm lint`, `helm template`, image inspection, and `git diff --check` before promotion.
- **Argo CD synchronization timing:** The old Deployment image was briefly visible after merge, then switched to the new pinned image; rollout completion and both new Pods were subsequently verified.
- **Secrets:** MongoDB passwords, TLS private keys, and cluster credentials must remain outside source control.
- **Reproducibility versus production readiness:** Pinned chart/image versions improve reproducibility, but do not resolve legacy-image or single-host availability risks.

## 9. Limitations and follow-up work

1. The three-node cluster shares one physical host and therefore lacks host-level fault tolerance.
2. MongoDB runs standalone without persistence; it is intentionally ephemeral and not database-HA capable.
3. MongoDB legacy images and permissive lab connectivity are security compromises and must not be replicated in production.
4. Investigate the four historical MongoDB container restarts; inspect `kubectl describe pod` and previous container logs if still available.
5. Re-run vulnerability and dependency scans periodically; a successful historical scan does not guarantee continued absence of vulnerabilities.
6. Confirm that every documented reconstruction procedure still works on a clean host; this exercise validated an installed system but did not perform a full clean-room rebuild at the end.
7. Check repository `main` branches, links, and documentation changes before declaring the documentation release closed.

## 10. Useful validation commands

```bash
# All commands run on the Ubuntu host with working kubectl/Helm access
kubectl get nodes -o wide
kubectl get application sample-nodejs -n argocd
kubectl get deployments,pods,svc,ingress -n sample-app
kubectl rollout status deployment/sample-nodejs -n sample-app
kubectl get deployment sample-nodejs -n sample-app \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl get pods -n mongodb
curl -i -H 'Host: sample-nodejs.test' http://192.168.122.11/my-app

# Application repository checks
cd ~/targil2026/application/sample-nodejs
helm lint helm/sample-nodejs
helm template sample-nodejs helm/sample-nodejs --namespace sample-app > /tmp/sample-nodejs-rendered.yaml
git status --short

# Infrastructure repository checks
cd ~/targil2026
git status --short
```

## 11. Documentation map

**Infrastructure repository** (`ZoharGolano/targil2026`):

- [`README.md`](../README.md) — overall architecture and project status.
- [`docs/01-infrastructure-setup.md`](01-infrastructure-setup.md) — KVM/libvirt and VM provisioning.
- [`docs/02-k3s-ha.md`](02-k3s-ha.md) — K3s and embedded etcd.
- [`docs/03-mongodb-installation.md`](03-mongodb-installation.md) — MongoDB installation, verification, and troubleshooting.
- [`kubernetes/mongodb/README.md`](../kubernetes/mongodb/README.md) — MongoDB Helm configuration.
- [`infrastructure/argocd/README.md`](../infrastructure/argocd/README.md) — Argo CD installation and HTTPS ingress.

**Application repository** (`ZoharGolano/sample-nodejs`):

- [`README.md`](https://github.com/ZoharGolano/sample-nodejs/blob/main/README.md) — application overview.
- [`helm/sample-nodejs/`](https://github.com/ZoharGolano/sample-nodejs/tree/main/helm/sample-nodejs) — Helm chart.
- [`gitops/application.yaml`](https://github.com/ZoharGolano/sample-nodejs/blob/main/gitops/application.yaml) — Argo CD Application manifest.
- [`gitops/README.md`](https://github.com/ZoharGolano/sample-nodejs/blob/main/gitops/README.md) — GitOps, release promotion, and validation evidence.
- [`.github/workflows/ci-cd.yml`](https://github.com/ZoharGolano/sample-nodejs/blob/main/.github/workflows/ci-cd.yml) — CI/CD workflow.

---

**Conclusion:** Targil2026 has demonstrated a working, security-gated CI/CD-to-GitOps workflow and a successful v1.0.1 deployment on a self-managed three-node K3s lab. The verified result establishes exercise completion for the core technical workflow, subject to the intentionally documented lab-only limitations and any additional formal rubric checks.
