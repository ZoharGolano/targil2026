# Targil2026 — DevOps Full Stack Exercise

## Project overview

This project documents the design and implementation of a self-managed Kubernetes environment, followed by MongoDB, an application Helm chart, Argo CD GitOps deployment, and a security-gated CI/CD pipeline.

**Current status (2026-11-18):** All three Ubuntu virtual machines (`k3s-node01`, `k3s-node02`, `k3s-node03`) are provisioned and validated. **K3s is not installed yet.** MongoDB, Argo CD, the application, and CI/CD are also not deployed.

## Infrastructure design

| Component | Selected design | Rationale |
|---|---|---|
| Virtualization | KVM / QEMU / libvirt | Linux-native VM management on a laptop |
| Guest OS | Ubuntu Server 24.04 | LTS base image with Cloud-init support |
| Kubernetes distribution | K3s (planned) | Lightweight self-managed Kubernetes for a local lab |
| Nodes | Three VMs provisioned; combined control-plane, etcd and worker roles planned for K3s | Explore quorum, scheduling and node failures |
| Node sizing | 2 vCPU, 5 GiB RAM | Fit three VMs into the available 32 GB laptop RAM |
| Storage per VM | 25 GiB OS + 55 GiB `/var` | Isolate system and Kubernetes runtime data |
| Network | libvirt default NAT, 192.168.122.0/24 | Reproducible local networking, outgoing internet access |
| IP assignment | DHCP reservations by MAC | Stable per-node IPs without configuring static addresses in the guest |
| Provisioning | Ubuntu Cloud Image + Cloud-init | Repeatable VM initialization |

### Planned hosts

| Host | IP | Role | State |
|---|---|---|---|
| `k3s-node01` | `192.168.122.11` | Control plane + etcd + worker (after K3s install) | VM provisioned; K3s preflight checked |
| `k3s-node02` | `192.168.122.12` | Control plane + etcd + worker (planned) | VM provisioned; cloud-init done; `/var` verified |
| `k3s-node03` | `192.168.122.13` | Control plane + etcd + worker (planned) | VM provisioned; cloud-init done; network checked |

## Completed work

1. Verified laptop hardware, VT-x/KVM, QEMU/libvirt, and available capacity; resolved libvirt socket permissions.
2. Configured libvirt `default` NAT (`192.168.122.0/24`) and DHCP reservations for `.11`, `.12`, and `.13` with unique MAC addresses.
3. Downloaded Ubuntu 24.04 Cloud Image; provisioned all three VMs with Cloud-init, SSH keys, 2 vCPU and 5120 MiB RAM each.
4. Created two QCOW2 disks per VM: 25 GiB OS and 55 GiB dedicated ext4 `/var`.
5. Migrated `/var` offline preserving ACLs/xattrs; created `create-vm-disks.sh` and `prepare-var-disk.sh` to automate node02 and node03 storage provisioning.
6. Diagnosed temporary `umount: target is busy` errors, enhanced cleanup with bounded retries, and confirmed both NBD devices were detached (`0B`).
7. Verified node02 and node03 booted with cloud-init `done`, no reported errors, root filesystem expanded, `/var` on `/dev/vdb`, and zero failed systemd units.
8. Verified node03 reaches node01 and node02 by ping with 0% packet loss; SSH active, interface `192.168.122.13/24`, gateway `192.168.122.1`.
9. Checked node01 K3s preflight: 4.8 GiB RAM (4.4 GiB available at check), ~51 GiB free on `/var`, swap disabled, UFW inactive, and HTTP 200 from `get.k3s.io`.

**Not completed:** The K3s installation and three-member etcd cluster. Do not confuse OS provisioning with Kubernetes readiness.

## Troubleshooting and lessons learned

**Libvirt permissions:** A regular user could not access the `root:libvirt` Unix socket, although `sudo virsh` worked. Group permissions were updated and access revalidated.

**ACL preservation:** `rsync -aHAX` over guestmount reported `set_acl: Invalid argument` for systemd journal paths. Using direct ext4 mounts via qemu-nbd allowed the transfer to complete without reported errors. This illustrates the need to preserve ACLs, xattrs, ownership and hard links during system-directory migration.

**Idempotency:** Repeating `tee -a` appended a duplicate `/var` entry to node01 `fstab`. It was removed. The new `prepare-var-disk.sh` performs safety checks but is **initial-provisioning-only**, not a fully idempotent script. Do not rerun on prepared disks.

**Disk safety:** QCOW2 images must not be edited simultaneously by the guest and the host. The guest was shut down and filesystems unmounted before block-device access. Disk identifiers were checked before formatting.

**Transient unmount failure:** On node02, copying and fstab updates completed but cleanup returned `target is busy`; after inspection, manual unmount and NBD disconnect succeeded. On node03, bounded retry succeeded on the third unmount attempt. Exact root cause was not established.

## Validation commands

```bash
# On the laptop
virsh -c qemu:///system list --all
virsh -c qemu:///system net-dhcp-leases default

# On k3s-node01
hostname
cloud-init status --long
lsblk -f
findmnt /var
df -h /var
systemctl --failed
```

## Next milestones

- Validate NTP/time, DNS, Kubernetes-required port connectivity and the selected pinned K3s version.
- Deploy K3s with embedded etcd and establish a stable Kubernetes API endpoint.
- Deploy MongoDB 8.0.13 using a suitable Bitnami Helm chart, with explicit resource constraints and exporter metrics.
- Deploy Argo CD, then build the application's Docker image and Helm chart.
- Implement GitHub Actions with SAST, image vulnerability scanning and a HIGH-severity deployment gate, version bumping, and GitOps-based deployment.

## Documentation

The updated Hebrew step-by-step infrastructure runbook, including the three VMs, provisioning scripts, troubleshooting, and verified preflight results, is located at:

[`docs/01-infrastructure-setup-he.md`](docs/01-infrastructure-setup-he.md)

> This README reflects work completed to date. Any future changes must be validated and documented before being marked as complete.
