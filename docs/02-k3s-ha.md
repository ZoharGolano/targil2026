# Targil2026 — K3s Installation, etcd Validation, and High Availability Test

> **Record date:** 18 November 2026. **Environment:** self-managed Ubuntu/KVM lab.
> **Verified:** three K3s servers Ready, three healthy voting etcd members, pre-test snapshot, and successful node02 follower-stop/recovery.
> **Not tested:** leader outage, snapshot restore, off-host backup, and API load-balancer failover. MongoDB was completed subsequently.

## 1. Goal and architecture

Build K3s on three Ubuntu 24.04.5 LTS VMs, each simultaneously a control-plane server, embedded-etcd voter, and schedulable workload node. Etcd requires a **2-of-3 Raft majority**: it can tolerate one server outage while the other two remain healthy, but all VMs share a single physical host.

| Parameter | Verified value |
|---|---|
| VM | 2 vCPU, 5120 MiB RAM, 25 GiB OS + 55 GiB ext4 `/var` |
| OS | Ubuntu 24.04.5 LTS |
| K3s | `v1.37.2+k3s1` (build `f6973cb8`) |
| containerd | `2.3.7-k3s1` |
| etcd server | `3.7.1` |
| etcdctl on node03 | `3.4.30`, API v3 |
| Node roles | `control-plane,etcd`; no workload-blocking taint |
| Addresses | `.11`, `.12`, `.13` within `192.168.122.0/24`; API TCP 6443 |

**Decision:** all three VMs run `k3s server`, not agents, to demonstrate embedded-etcd HA. **Limitation:** joining servers point to `https://192.168.122.11:6443`; no independent stable API load balancer has been configured.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```text
                      Ubuntu Laptop — KVM/libvirt
                       NAT 192.168.122.0/24
                                |
                       K3s v1.37.2+k3s1
                                |
             +------------------+------------------+
             |                  |                  |
      k3s-node01           k3s-node02           k3s-node03
      192.168.122.11       192.168.122.12       192.168.122.13
      Control Plane        Control Plane        Control Plane
      etcd voting member   etcd voting member   etcd voting member
      schedulable          schedulable          schedulable
             +------------------+------------------+
                        Raft quorum = 2/3
```

## 2. Prerequisite checks

On node01, readiness checks showed hostname `k3s-node01`, 4.8 GiB RAM (~4.4 GiB available), a ~54 GiB `/var` filesystem (~51 GiB free), no swap, inactive UFW, and HTTP 200 from `https://get.k3s.io`. HTTP success does not guarantee all required binaries/images are reachable. Node03 successfully pinged nodes 01/02 with 0% packet loss and SSH was active. Node02 received HTTP **401 Unauthorized** from the API `/livez` URL using `curl -k`: this demonstrated TCP/API reachability plus expected authentication enforcement, not an infrastructure outage. `-k` was used for connectivity testing only.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
hostname
free -h
df -h /var
swapon --show
sudo ufw status
curl -I --connect-timeout 5 https://get.k3s.io
```

## 3. Installing the first server (node01)

Node01 initialized the embedded-etcd cluster with `cluster-init: true`, explicitly advertised `node-ip: 192.168.122.11`, and included this address as a TLS SAN. `/etc/rancher/k3s/config.yaml` was protected with mode 600.

The official installer script was downloaded and reviewed before invocation. After installation, the K3s service was active; node01 was `Ready`, role `control-plane,etcd`, version `v1.37.2+k3s1`. CoreDNS, metrics-server, local-path-provisioner, Traefik, and ServiceLB Pods ran normally. Completed `helm-install-*` jobs were expected.

**Reproducibility note:** the original node01 installation did not explicitly pin `INSTALL_K3S_VERSION`; its resulting version was recorded, and that version was pinned for node02/03. Future rebuilds should pin all three at the start.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<'YAML'
cluster-init: true
node-ip: 192.168.122.11
tls-san:
  - 192.168.122.11
YAML
sudo chmod 600 /etc/rancher/k3s/config.yaml
```

```bash
curl -sfL https://get.k3s.io -o /tmp/install-k3s.sh
sudo install -o root -g root -m 700 /tmp/install-k3s.sh /root/install-k3s.sh
# After reviewing the installer script:
sudo sh /root/install-k3s.sh
```

```bash
sudo systemctl is-active k3s
sudo k3s --version
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
```

## 4. Joining node02 and node03

Node02 and node03 each have `/etc/rancher/k3s/config.yaml` pointing to `server: https://192.168.122.11:6443`, with their own `node-ip`, `tls-san`, and a protected `token-file: /etc/rancher/k3s/server-token`. Joining servers must **not** have `cluster-init: true`.

The original server join token was read from node01 at `/var/lib/rancher/k3s/server/token` and piped between encrypted SSH connections from the authorized Ubuntu laptop. The secret was never printed in the conversation or stored in documentation/Git. The target token files were verified nonempty and `600 root:root`; do not copy private SSH keys between nodes.

Node02/node03 installed K3s explicitly with `INSTALL_K3S_VERSION=v1.37.2+k3s1` and `INSTALL_K3S_EXEC=server`. The final node listing showed all three `Ready`, the same K3s version, and `control-plane,etcd` roles; system Pods and ServiceLB were running.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```yaml
server: https://192.168.122.11:6443
node-ip: 192.168.122.12
token-file: /etc/rancher/k3s/server-token
tls-san:
  - 192.168.122.12
```

```bash
set -o pipefail
ssh zohargo@192.168.122.11 \
  'sudo cat /var/lib/rancher/k3s/server/token' \
  | ssh zohargo@192.168.122.12 \
  'sudo sh -c "umask 077; cat > /etc/rancher/k3s/server-token"'
```

```bash
curl -sfL https://get.k3s.io -o /tmp/install-k3s.sh
sudo install -o root -g root -m 700 /tmp/install-k3s.sh /root/install-k3s.sh
sudo env INSTALL_K3S_VERSION='v1.37.2+k3s1' \
  INSTALL_K3S_EXEC='server' \
  sh /root/install-k3s.sh
```

## 5. API readiness, kubeconfig, and EndpointSlice

`sudo k3s kubectl get --raw='/readyz?verbose'` ended in `readyz check passed` and showed positive etcd, etcd-readiness, informer-sync, and storage-readiness checks.

Unprivileged `kubectl get no` initially failed reading `/etc/rancher/k3s/k3s.yaml`, because this cluster-admin kubeconfig is root-protected. Running `sudo k3s kubectl` worked. **Do not chmod the admin kubeconfig to 0644.** A separate least-privileged kubeconfig/RBAC identity is a better long-term approach.

The API Service EndpointSlice contained `192.168.122.11`, `.12`, and `.13` on port 6443. The older Endpoints API emitted a deprecation warning in Kubernetes 1.33+. EndpointSlice membership does not itself establish etcd health.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
sudo k3s kubectl get --raw='/readyz?verbose'
```

```bash
sudo k3s kubectl get endpointslices -n default \
  -l kubernetes.io/service-name=kubernetes -o wide
```

## 6. Etcd snapshot before the HA test

A manual etcd snapshot was saved on node03 **before** the HA test.

| Field | Observed value |
|---|---|
| Snapshot name | `pre-ha-test-k3s-node03-1795023370` |
| Timestamp | `2026-11-18T17:36:10Z` |
| Size | `11710496` bytes (~11.2 MiB) |
| Path | `/var/lib/rancher/k3s/server/db/snapshots/pre-ha-test-k3s-node03-1795023370` |
| Restore tested? | **No** |

`k3s etcd-snapshot ls` listed the backup, despite warnings that server configuration flags such as `--server`, `--node-ip`, `--token-file`, and `--tls-san` do not apply to the snapshot command. A `sudo ls .../pre-ha-test-*` check failed because the shell expanded the wildcard before privilege escalation; `sudo find` avoids this issue. The source record did not include the output of the proposed `find` command, so that specific verification is **not claimed** as completed.

Etcd restoration also requires the **original server token**, securely backed up separately. An etcd API snapshot does not back up application PVC data, local files, or the host.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
sudo k3s etcd-snapshot save --name pre-ha-test
sudo k3s etcd-snapshot ls
```

```bash
sudo find /var/lib/rancher/k3s/server/db/snapshots \
  -maxdepth 1 -type f -name 'pre-ha-test-*' -printf '%f | %s bytes\n'
```

## 7. Direct etcd membership and health checks

On node03, `etcd-client` installed `etcdctl 3.4.30` (API v3), while the server reported etcd 3.7.1. Member listing, endpoint status, and endpoint health succeeded. This does not establish universal compatibility of every administration operation across the versions.

TLS files (root-protected): `server-ca.crt`, `client.crt`, `client.key` under `/var/lib/rancher/k3s/server/tls/etcd`. No private key contents were displayed.

| Member | Member ID | Peer URL | Client URL | Voter? | Leader at measurement? |
|---|---|---|---|---|---|
| node01 | `69d968bf93159205` | `https://192.168.122.11:2380` | `https://192.168.122.11:2379` | yes | **yes** |
| node02 | `82c559eb04bcdb0c` | `https://192.168.122.12:2380` | `https://192.168.122.12:2379` | yes | no |
| node03 | `a26fd1aaed44a2dc` | `https://192.168.122.13:2380` | `https://192.168.122.13:2379` | yes | no |

All three had `IS LEARNER=false`, started status true, etcd server 3.7.1, approximately 12 MB DB, Raft term 2, similar Raft indexes (~13837–13838), no reported endpoint errors. All three endpoint health checks succeeded at about 4–5 ms.

**Caution:** the example uses `$ETCD_TLS` within `sudo env ... etcdctl`; when executed in a shell, variables must be defined in that shell. These checks require the appropriate root-protected TLS credentials.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
apt-cache policy etcd-client
sudo apt update
sudo apt install -y etcd-client
etcdctl version
```

```text
/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt
/var/lib/rancher/k3s/server/tls/etcd/client.crt
/var/lib/rancher/k3s/server/tls/etcd/client.key
```

```bash
# On node03; define a local shell variable for readability
ETCD_TLS=/var/lib/rancher/k3s/server/tls/etcd

sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert="$ETCD_TLS/server-ca.crt" \
  --cert="$ETCD_TLS/client.crt" \
  --key="$ETCD_TLS/client.key" \
  member list -w table

sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert="$ETCD_TLS/server-ca.crt" \
  --cert="$ETCD_TLS/client.crt" \
  --key="$ETCD_TLS/client.key" \
  endpoint status --cluster -w table

sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert="$ETCD_TLS/server-ca.crt" \
  --cert="$ETCD_TLS/client.crt" \
  --key="$ETCD_TLS/client.key" \
  endpoint health --cluster -w table
```

## 8. Controlled follower outage and recovery

**Controlled failure experiment:** node02 was a follower while node01 was leader. Before shutdown, the `svclb-traefik` workload on node02 was healthy (2/2). From the host, `sudo systemctl stop k3s` was run on node02.

During the outage node02 became `NotReady`; node01 and node03 remained `Ready`; querying node03's API `/readyz` succeeded. Etcd health for nodes 01 and 03 remained true, showing that the 2-of-3 quorum survived. Node02 was restarted using `sudo systemctl start k3s`, subsequently returned to `Ready`, and etcd health across all three endpoints was again true.

**What this proves:** one follower-server service outage can be tolerated while a 2/3 majority is retained, and the stopped server can rejoin. **What it does not prove:** leader failover, physical-host independence, disk-failure recovery, snapshot restore, or load-balanced API continuity. Do not overstate the scope of this single test.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
# SSH into node02 from the host
ssh zohargo@192.168.122.12
hostname # must return k3s-node02
sudo systemctl stop k3s
sudo systemctl is-active k3s
```

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get --raw='/readyz'

sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://192.168.122.11:2379,https://192.168.122.13:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
  endpoint health -w table
```

```bash
# On node02
sudo systemctl start k3s
sudo systemctl is-active k3s

# On node03
sudo k3s kubectl get nodes -o wide
sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
  endpoint health --cluster -w table
```

## 9. Troubleshooting and lessons learned

**Lessons learned:** treat unprivileged kubeconfig permission errors as access-control issues, not cluster failures; check K3s API readiness separately from etcd member health; use EndpointSlice rather than deprecated Endpoints where available; verify token-file permissions without exposing token values; take a snapshot before destructive or failure testing; preserve the original server token for disaster recovery; avoid assuming a successful snapshot means restore has been tested; and distinguish a controlled follower stop from a full HA certification.

## 10. Routine health checks

The following commands are convenient periodic checks for node readiness, system workloads, API readiness, etcd members and etcd endpoint health. Adjust file locations and credentials for your environment.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
# From any of the three K3s servers
sudo systemctl is-active k3s
sudo k3s --version
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A -o wide
sudo k3s kubectl get --raw='/readyz?verbose'
sudo k3s kubectl get endpointslices -n default \
  -l kubernetes.io/service-name=kubernetes -o wide
sudo k3s etcd-snapshot ls

# On node03 after installing etcd-client: membership and health checks
sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
  endpoint health --cluster -w table
```

## 11. Open items and subsequent work

**Still open:** deliberate etcd leader-stop/failover test, snapshot restore drill, off-host encrypted backup of snapshots and join token, a stable HA API endpoint/load balancer, production-grade node and host monitoring, and workload-level redundancy.

**Progress update:** the next phase—MongoDB 8.0.13 on Helm—was completed after this HA report was originally written. See [03-mongodb-installation.md](03-mongodb-installation.md). Application Helm charts, Argo CD, GitHub Actions, SAST, and Trivy remain future work.

## 12. Technical references

Useful technical references named in the original project: the official K3s installation and server configuration documentation, the K3s embedded-etcd/HA and backup/restore guides, Kubernetes API readiness probes, Kubernetes EndpointSlice documentation, and etcd `etcdctl` guidance. Prefer upstream documentation for current flags and upgrade-specific behavior.
