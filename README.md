# Targil2026 — DevOps Full Stack Exercise

## Project overview

This project documents the design and implementation of a self-managed Kubernetes environment, followed by MongoDB, an application Helm chart, Argo CD GitOps deployment, and a security-gated CI/CD pipeline.

**Current status:** The first Ubuntu virtual machine (`k3s-node01`) is provisioned and validated. Kubernetes, the database, Argo CD, the application, and CI/CD are **not yet deployed**.

## Infrastructure design

| Component | Selected design | Rationale |
|---|---|---|
| Virtualization | KVM / QEMU / libvirt | Linux-native VM management on a laptop |
| Guest OS | Ubuntu Server 24.04 | LTS base image with Cloud-init support |
| Kubernetes distribution | K3s (planned) | Lightweight self-managed Kubernetes for a local lab |
| Nodes | Three combined control-plane, etcd and worker nodes (planned) | Explore quorum, scheduling and node failures |
| Node sizing | 2 vCPU, 5 GiB RAM | Fit three VMs into the available 32 GB laptop RAM |
| Storage per VM | 25 GiB OS + 55 GiB `/var` | Isolate system and Kubernetes runtime data |
| Network | libvirt default NAT, 192.168.122.0/24 | Reproducible local networking, outgoing internet access |
| IP assignment | DHCP reservations by MAC | Stable per-node IPs without configuring static addresses in the guest |
| Provisioning | Ubuntu Cloud Image + Cloud-init | Repeatable VM initialization |

### Planned hosts

| Host | IP | Role | State |
|---|---|---|---|
| `k3s-node01` | `192.168.122.11` | Control plane + etcd + worker (after K3s install) | VM created and storage configured |
| `k3s-node02` | `192.168.122.12` | Control plane + etcd + worker | Not created |
| `k3s-node03` | `192.168.122.13` | Control plane + etcd + worker | Not created |

## Completed work

1. Verified laptop hardware, virtualization support, available memory and disk space.
2. Confirmed KVM/QEMU and libvirt availability; resolved the libvirt socket permission issue by assigning the operator to the required groups.
3. Verified libvirt NAT networking, then configured and validated a MAC-to-IP DHCP reservation for `k3s-node01`.
4. Downloaded the Ubuntu 24.04 Cloud Image and created independent QCOW2 OS and data disks.
5. Provisioned `k3s-node01` with Cloud-init and SSH-key authentication; validated boot, hostname, DHCP and storage discovery.
6. Formatted a dedicated 55 GiB ext4 filesystem for `/var`.
7. Migrated `/var` offline. The initial FUSE/guestmount-based rsync hit ACL errors (exit code 23), so the disks were reattached through qemu-nbd and rsync completed successfully (exit code 0).
8. Verified migration, backed up `fstab`, configured `/var` by filesystem UUID, removed a duplicate fstab entry, and rebooted the guest. The post-boot storage and service checks were reported successful.

## Troubleshooting and lessons learned

**Libvirt permissions:** A regular user could not access the `root:libvirt` Unix socket, although `sudo virsh` worked. Group permissions were updated and access revalidated.

**ACL preservation:** `rsync -aHAX` over guestmount reported `set_acl: Invalid argument` for systemd journal paths. Using direct ext4 mounts via qemu-nbd allowed the transfer to complete without reported errors. This illustrates the need to preserve ACLs, xattrs, ownership and hard links during system-directory migration.

**Idempotency:** Repeating `tee -a` appended a duplicate `/var` entry to `fstab`. It was removed and verified; future provisioning will use a repeatable configuration procedure.

**Disk safety:** QCOW2 images must not be edited simultaneously by the guest and the host. The guest was shut down and filesystems unmounted before block-device access. Disk identifiers were checked before formatting.

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

- Automate VM creation and `/var` preparation for `k3s-node02` and `k3s-node03` with unique identities.
- Validate NTP, DNS, network connectivity, resource headroom, and the selected K3s version.
- Deploy K3s with embedded etcd and establish a stable Kubernetes API endpoint.
- Deploy MongoDB 8.0.13 using a suitable Bitnami Helm chart, with explicit resource constraints and exporter metrics.
- Deploy Argo CD, then build the application's Docker image and Helm chart.
- Implement GitHub Actions with SAST, image vulnerability scanning and a HIGH-severity deployment gate, version bumping, and GitOps-based deployment.

## Documentation

The detailed Hebrew step-by-step infrastructure runbook, including executed commands and observed outputs, is located at:

[`docs/01-infrastructure-setup-he.md`](docs/01-infrastructure-setup-he.md)

> This README reflects work completed to date. Any future changes must be validated and documented before being marked as complete.
