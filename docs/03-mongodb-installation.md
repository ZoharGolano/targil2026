# Targil2026 — MongoDB 8.0.13 Deployment with Helm on K3s

> **Record date:** 18 November 2026. **Environment:** self-managed Ubuntu/KVM lab.
> **Status:** successfully deployed, authenticated, reachable via NodePort, exporter verified. **Lab only:** standalone, ephemeral data and Legacy Images.

## 1. Goals and design choices

| Topic | Selected configuration | Rationale |
|---|---|---|
| Helm chart | `bitnami/mongodb` `16.5.45` | Pinned chart declares MongoDB 8.0.13 |
| MongoDB | `8.0.13` | Exercise requirement; verified inside running container |
| Architecture | `standalone` | Simple lab deployment; **not** MongoDB HA |
| Namespace | `mongodb` | Logical grouping; not automatic network isolation |
| Persistence | disabled | Exercise requirement; Pod replacement can lose data |
| Authentication | enabled; existing Kubernetes Secret | No password stored in Git/values |
| External access | `NodePort` `32017` | Host-to-VM connectivity test |
| Exporter | port `9216` | Prometheus-compatible `/metrics` |
| Images | `bitnamilegacy` MongoDB and exporter | Lab only; no routine security updates |

This is a training configuration, **not** a production deployment.

## 2. Infrastructure context

The lab has three K3s control-plane/worker nodes behind libvirt NAT (`192.168.122.11`, `.12`, `.13`). Deployment was performed from `k3s-node03`; the MongoDB Pod was observed on that node with temporary Pod IP `10.42.2.3`. Pod IPs are not stable service endpoints.

## 3. Helm and chart versions

Helm 3 was installed, and the Bitnami repository was added. `helm search repo bitnami/mongodb --versions` identified `bitnami/mongodb` chart **16.5.45**, `appVersion` **8.0.13**.

Chart and app versions are not interchangeable. The actual MongoDB version was separately checked using `mongod --version` in the running container.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
helm version
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo bitnami/mongodb --versions | grep '8.0.13'
helm show chart bitnami/mongodb --version 16.5.45
helm show values bitnami/mongodb --version 16.5.45 > default-values.yaml
```

```text
bitnami/mongodb    16.5.45    8.0.13
```

## 4. Helm values file

The source-controlled configuration is `kubernetes/mongodb/values.yaml`. Below is the **lab configuration** used in the installation; do not store passwords in this file. `global.security.allowInsecureImages: true` bypasses chart image-origin verification for the substituted Legacy Images. This is a documented lab-only security exception.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```yaml
# Targil2026 lab-only configuration
global:
  security:
    allowInsecureImages: true
architecture: standalone
image:
  registry: docker.io
  repository: bitnamilegacy/mongodb
  tag: 8.0.13-debian-12-r0
auth:
  enabled: true
  existingSecret: mongodb-credentials
persistence:
  enabled: false
service:
  type: NodePort
  ports:
    mongodb: 27017
  nodePorts:
    mongodb: 32017
resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 2Gi
metrics:
  enabled: true
  image:
    registry: docker.io
    repository: bitnamilegacy/mongodb-exporter
    tag: 0.47.0-debian-12-r1
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

## 5. Rendering manifests before installation

Before installing, `helm template` rendered the manifests into `rendered.yaml`. Observed kinds: NetworkPolicy, PodDisruptionBudget, ServiceAccount, ConfigMap, two Services, and Deployment. Rendered images were `docker.io/bitnamilegacy/mongodb:8.0.13-debian-12-r0` and `docker.io/bitnamilegacy/mongodb-exporter:0.47.0-debian-12-r1`.

Rendering validates Helm templating, **not** image availability, Pod startup, or runtime database authentication. `rendered.yaml` is generated output and should be screened for sensitive information before sharing; committing it is optional.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
helm template mongodb bitnami/mongodb \
  --version 16.5.45 --namespace mongodb \
  -f values.yaml > rendered.yaml

grep '^kind:' rendered.yaml
grep 'image:' rendered.yaml
```

```text
docker.io/bitnamilegacy/mongodb:8.0.13-debian-12-r0
docker.io/bitnamilegacy/mongodb-exporter:0.47.0-debian-12-r1
```

## 6. Namespace and Kubernetes Secret

Namespace `mongodb` was created. A random 48-character hexadecimal root password was generated with OpenSSL and stored in a Kubernetes `Opaque` Secret called `mongodb-credentials`, using key `mongodb-root-password`. The Secret was created without storing plaintext in the project or command history. A read-only size check yielded **48 bytes**.

**Operational warning:** do not recreate or rotate this Secret casually after MongoDB has initialized; a mismatched stored credential can cause authentication failures.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
sudo k3s kubectl create namespace mongodb
```

```bash
PASSWORD="$(openssl rand -hex 24)"
printf '%s' "$PASSWORD" | \
  sudo k3s kubectl -n mongodb create secret generic mongodb-credentials \
    --from-file=mongodb-root-password=/dev/stdin
unset PASSWORD
```

```bash
sudo k3s kubectl -n mongodb get secret mongodb-credentials \
  -o jsonpath='{.data.mongodb-root-password}' | base64 -d | wc -c
```

## 7. Helm installation and repository troubleshooting

The first `sudo helm install` failed with `Error: INSTALLATION FAILED: repo bitnami not found`. Cause: the chart repo had been added for unprivileged user `zohargo`, but `sudo` looked up the root account's Helm repository configuration. Adding/updating `bitnami` with `sudo helm repo ...` resolved the issue.

Installation then succeeded: release `mongodb`, namespace `mongodb`, revision **1**, status **deployed**, chart **mongodb-16.5.45**, appVersion **8.0.13**. The Kubernetes API was accessed with root-protected `/etc/rancher/k3s/k3s.yaml`.

Future improvement: configure a limited RBAC identity and protected kubeconfig for the host rather than routine `sudo helm` from a K3s server.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```text
Error: INSTALLATION FAILED: repo bitnami not found
```

```bash
sudo helm repo add bitnami https://charts.bitnami.com/bitnami
sudo helm repo update
sudo helm show chart bitnami/mongodb --version 16.5.45
```

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  helm install mongodb bitnami/mongodb \
  --version 16.5.45 \
  --namespace mongodb \
  --values values.yaml \
  --wait --timeout 5m
```

## 8. Verification results

**Observed deployment state:** Pod `mongodb-549c7d7475-hrt6d`, `2/2 Running`, zero restarts, Pod IP `10.42.2.3` on `k3s-node03`. Services: `mongodb` NodePort (`10.43.196.248`, `27017:32017/TCP`) and `mongodb-metrics` ClusterIP (`10.43.131.98`, `9216/TCP`).

**Verified actual MongoDB version:** `mongod --version` printed `db version v8.0.13`.

**Authentication failure and fix:** the initial command passed `"$MONGODB_ROOT_PASSWORD"`, which was **not set**. The chart used file-based secrets (`MONGODB_ROOT_PASSWORD_FILE` was set). Reading that mounted file inside the container enabled a successful authenticated `mongosh` ping: `{ ok: 1 }`. **Security caveat:** passing a password through `--password` can expose it transiently in process arguments; this was a lab-only test command.

**Outside-cluster TCP check:** Ubuntu host `nc -vz -w 5 192.168.122.13 32017` succeeded. This verifies TCP reachability only—not external MongoDB authentication. With `externalTrafficPolicy: Local`, the check targeted the node currently hosting the Pod; other nodes may not accept the same external traffic.

**Exporter:** port forwarding `svc/mongodb-metrics` and reading `/metrics` yielded `mongodb_up{cluster_role="mongod"} 1`. Sample `mongodb_ss_connections` metrics included `current=3`, `active=1`. This proves exporter connectivity to MongoDB, **not** automatic Prometheus scraping.

**Resources:**

| Container | CPU request | CPU limit | Memory request | Memory limit | Measured CPU | Measured memory |
|---|---:|---:|---:|---:|---:|---:|
| mongodb | 250m | 1 core | 512Mi | 2Gi | 90m | 89Mi |
| metrics | 50m | 200m | 64Mi | 256Mi | 1m | 11Mi |

Measurements are a point-in-time snapshot, not averages or peaks. `cpu: 1` is equivalent to `1000m`.

**Persistence:** `kubectl get pvc -n mongodb` returned `No resources found in mongodb namespace.` This matches `persistence.enabled: false`.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
sudo k3s kubectl get pods -n mongodb -o wide
sudo k3s kubectl get svc -n mongodb
```

```text
mongodb-549c7d7475-hrt6d   2/2 Running   0 restarts   10.42.2.3   k3s-node03
mongodb           NodePort    10.43.196.248   27017:32017/TCP
mongodb-metrics   ClusterIP   10.43.131.98    9216/TCP
```

```bash
sudo k3s kubectl -n mongodb exec deploy/mongodb -c mongodb -- mongod --version
```

```bash
sudo k3s kubectl -n mongodb exec deploy/mongodb -c mongodb -- bash -c '
  mongosh --quiet --host 127.0.0.1 \
    --username "$MONGODB_ROOT_USER" \
    --password "$(cat "$MONGODB_ROOT_PASSWORD_FILE")" \
    --authenticationDatabase admin \
    --eval "db.adminCommand({ping: 1})"
'
```

```javascript
{ ok: 1 }
```

```bash
nc -vz -w 5 192.168.122.13 32017
```

```text
Connection to 192.168.122.13 32017 port [tcp/*] succeeded!
```

```bash
sudo k3s kubectl -n mongodb port-forward svc/mongodb-metrics 9216:9216
# In another terminal on the same server:
curl -fsS http://127.0.0.1:9216/metrics | grep '^mongodb_up'
```

```text
mongodb_up{cluster_role="mongod"} 1
```

```bash
sudo k3s kubectl -n mongodb get deployment mongodb \
  -o jsonpath='{range .spec.template.spec.containers[*]}Container: {.name}{"\n"}Requests: {.resources.requests}{"\n"}Limits: {.resources.limits}{"\n\n"}{end}'
sudo k3s kubectl top pod -n mongodb --containers
```

```bash
sudo k3s kubectl get pvc -n mongodb
```

## 9. Network security

The rendered NetworkPolicy selected the MongoDB Pod with `policyTypes: [Ingress, Egress]`. Its egress rule `{}` allows all outbound traffic. Its ingress rules allowed TCP ports **27017** and **9216** but omitted `from`, so they did **not** restrict allowed source IPs/namespaces. Namespace isolation, NetworkPolicy, and a firewall are separate concepts. Protect NodePort `32017` at the VM/host network boundary; this policy is not proof of safe Internet exposure.

## 10. Limitations and risks

1. **Standalone database:** no replica-set/database HA.
2. **Ephemeral data:** loss of a Pod or replacement can destroy stored data.
3. **Legacy images:** not receiving routine security updates; chart warned about substituted images and bypassed origin checking.
4. **NodePort:** exposes a TCP endpoint on the lab network; authorization and firewall restrictions remain necessary.
5. **Credentials:** never commit plaintext passwords, tokens, admin kubeconfigs, or screenshots containing secrets.
6. **Monitoring:** the exporter works, but Prometheus scraping has not been verified.
7. **Test scope:** the outside check validated TCP, not a full remote authenticated `mongosh` session.

## 11. Files to commit to Git

Keep `kubernetes/mongodb/values.yaml` and this document (`docs/03-mongodb-installation.md`) in Git. `default-values.yaml` and `rendered.yaml` are generated/reference artifacts, not required for version control. Review the staged diff for secrets before committing. The Git repository should be managed from the Ubuntu host, not by initializing an unrelated Git repository on `k3s-node03`.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```text
kubernetes/mongodb/values.yaml
docs/03-mongodb-installation-he.md
```

```bash
cd ~/targil2026
git status --short
git diff --no-index /dev/null kubernetes/mongodb/values.yaml || true
# Manually verify no passwords or sensitive information are present
```

```bash
git add kubernetes/mongodb/values.yaml docs/03-mongodb-installation-he.md
git diff --cached --stat
git diff --cached --check
git commit -m "Document MongoDB 8.0.13 Helm deployment and validation"
```

## 12. Next steps

Next tasks: optionally perform a full authenticated MongoDB connection through NodePort from the host; tighten firewall/NetworkPolicy rules; deploy the application and its Helm chart; implement Argo CD GitOps; add GitHub Actions with SAST and Trivy security gating. Keep README and documentation aligned with actual completed tests.
