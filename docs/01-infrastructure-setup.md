# Targil2026 — KVM Infrastructure for Three Kubernetes Servers

> **Record date:** 18 November 2026. **Environment:** self-managed Ubuntu/KVM lab.
> **Scope:** infrastructure was built and verified before K3s installation; K3s and MongoDB were completed later and are documented separately.

## 1. Project objectives

The goal is to build a self-managed, three-node Kubernetes environment, deploy MongoDB and an application with Helm, configure Argo CD, and add a CI/CD pipeline with security scanning. Each phase records its purpose, design choices, commands, measured results, issues, and lessons learned. This document focuses on KVM, Ubuntu provisioning, storage, and VM readiness. K3s/etcd testing is documented in [02-k3s-ha.md](02-k3s-ha.md); MongoDB is documented in [03-mongodb-installation.md](03-mongodb-installation.md).

## 2. Host sizing and three-VM plan

**Verified Ubuntu laptop:** Intel Core i5-1135G7 (4 cores / 8 threads), VT-x enabled, about 31 GiB RAM (around 25 GiB available at initial measurement), 476.9 GiB NVMe drive, root filesystem 467 GiB (427 GiB free at measurement), KVM with QEMU 8.2.2, libvirt/virsh 10.0.0, `virt-install`, and `virt-manager`.

| VM | vCPU | RAM | OS disk | Separate `/var` disk | Reserved IP |
|---|---:|---:|---:|---:|---|
| `k3s-node01` | 2 | 5120 MiB | 25 GiB | 55 GiB | `192.168.122.11` |
| `k3s-node02` | 2 | 5120 MiB | 25 GiB | 55 GiB | `192.168.122.12` |
| `k3s-node03` | 2 | 5120 MiB | 25 GiB | 55 GiB | `192.168.122.13` |

**Design decisions:** use three K3s servers for embedded-etcd quorum and scheduling experiments; all three can run workloads. A separate ext4 `/var` volume isolates Kubernetes runtime data and logs from the OS and satisfies the exercise's minimum 50 GB `/var` requirement. QCOW2 sizes are logical maximums, not fully allocated physical storage; monitor host capacity. All VMs reside on one laptop, so this is not host-level HA.

## 3. Virtualization software and permissions

KVM, QEMU, libvirt, and virtualization support were verified. The unprivileged `virsh -c qemu:///system` command initially failed with **Permission denied**, while the same command under `sudo` succeeded. The libvirt socket was owned by `root:libvirt` with permissions `srw-rw----`; the user was not in that group.

**Resolution:** add `zohargo` to the `libvirt` and `kvm` groups, start a new login session, and verify `id -nG` and `virsh`. Membership in `libvirt` grants powerful host-management privileges and must be restricted to trusted users.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
lscpu | grep -E 'Model name|CPU\(s\)|Virtualization'
free -h
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS
df -h /
ls -l /dev/kvm
virsh --version
qemu-system-x86_64 --version
command -v virt-install
command -v virt-manager
```

```bash
virsh -c qemu:///system list --all
sudo virsh -c qemu:///system list --all
id
ls -l /var/run/libvirt/libvirt-sock
```

```bash
sudo usermod -aG libvirt,kvm zohargo
# Start a new login session (e.g., log out and back in)
id -nG
virsh -c qemu:///system list --all
```

## 4. Virtual networking and DHCP reservations

The libvirt `default` virtual network is active, persistent, and set to autostart. It uses NAT through `virbr0`, subnet `192.168.122.0/24`, gateway `192.168.122.1`, and DHCP range `192.168.122.2`–`192.168.122.254`. The host Wi-Fi interface was observed at `10.100.102.154/24` (an environment-specific, potentially changing address). `virbr0` may appear down when no guests are active even while the libvirt network is configured as active.

**Design choice:** NAT avoids bridging Wi-Fi while permitting VM-to-VM communication and outbound Internet. Access from systems outside this host requires explicit exposure/routing.

A DHCP reservation was configured for node01: MAC `52:54:00:26:00:11`, IP `192.168.122.11`. The XML reservation and subsequent lease were verified. Reserve unique free MACs/IPs before provisioning more VMs; do not re-add reservations already present.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
virsh -c qemu:///system net-list --all
virsh -c qemu:///system net-dumpxml default
ip -br addr
```

```bash
virsh -c qemu:///system net-dhcp-leases default
virsh -c qemu:///system net-update default add ip-dhcp-host \
  "<host mac='52:54:00:26:00:11' name='k3s-node01' ip='192.168.122.11'/>" \
  --live --config
virsh -c qemu:///system net-dumpxml default
```

```xml
<host mac='52:54:00:26:00:11' name='k3s-node01' ip='192.168.122.11'/>
```

## 5. Ubuntu Cloud Image and Cloud-init

The repository stores Cloud-init and helper scripts under `infrastructure/kvm/`; QCOW2 disks remain on the KVM host under `/var/lib/libvirt/images` and must **not** be committed to Git. An existing SSH public key (`~/.ssh/id_ed25519.pub`) was included in Cloud-init; never store the private key in this project.

The node01 `user-data.yaml` provisions an Ubuntu account named `zohargo`, SSH-key authentication, disabled password authentication, system utilities, and `qemu-guest-agent`. Passwordless sudo is a **lab-only convenience**, not a production security baseline. Ubuntu 24.04 Cloud Image and Cloud-init enable repeatable provisioning without installing from an ISO.

The downloaded base image was QCOW2, virtual size approximately **3.5 GiB**, physical size approximately **593 MiB**, `corrupt: false`. `qemu-img info` does not verify the image checksum or vendor signature; use official checksums for stronger supply-chain validation. Partition inspection identified `sda1`, `sda14`, `sda15`, and `sda16`; the running guest exposed root ext4 and boot/EFI partitions.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```text
targil2026/
└── infrastructure/
    └── kvm/
        ├── cloud-init/
        │   └── user-data.yaml
        └── scripts/
```

```yaml
#cloud-config
hostname: k3s-node01
manage_etc_hosts: true
users:
  - name: zohargo
    gecos: DevOps Lab User
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - <INSERT_YOUR_PUBLIC_SSH_KEY>
ssh_pwauth: false
package_update: true
packages:
  - curl
  - wget
  - vim
  - git
  - qemu-guest-agent
  - open-iscsi
  - nfs-common
runcmd:
  - systemctl enable --now qemu-guest-agent
```

```bash
sudo mkdir -p /var/lib/libvirt/images/base
sudo wget \
  https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img \
  -O /var/lib/libvirt/images/base/ubuntu-24.04.img
sudo qemu-img info /var/lib/libvirt/images/base/ubuntu-24.04.img
```

```bash
sudo apt install -y libguestfs-tools
sudo virt-filesystems --long --parts --blkdevs \
  -a /var/lib/libvirt/images/base/ubuntu-24.04.img
```

## 6. Preparing node01 disks

An initial 65 GiB OS disk was prepared, then the design changed **before VM startup** to a 25 GiB OS disk plus a dedicated 55 GiB `/var` disk. The original file was temporarily retained as `k3s-node01.qcow2.old`; assess backup needs before removing it.

Measured values: OS QCOW2 virtual size **25 GiB**, initial disk size about **593 MiB**; `/var` QCOW2 virtual size **55 GiB**, initial disk size about **196 KiB**. Thin provisioning saves initial space but requires sufficient free disk capacity as guest filesystems grow.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
sudo cp /var/lib/libvirt/images/base/ubuntu-24.04.img \
  /var/lib/libvirt/images/k3s-node01.qcow2
sudo qemu-img resize /var/lib/libvirt/images/k3s-node01.qcow2 25G
sudo qemu-img info /var/lib/libvirt/images/k3s-node01.qcow2
```

```bash
sudo qemu-img create -f qcow2 \
  /var/lib/libvirt/images/k3s-node01-var.qcow2 55G
sudo qemu-img info /var/lib/libvirt/images/k3s-node01-var.qcow2
```

## 7. Creating node01

`virt-install` created node01 using the Ubuntu Cloud Image, two VirtIO disks, 2 vCPUs, 5120 MiB memory, a fixed MAC address, serial console, and Cloud-init. Verification showed the VM running, `hostname=k3s-node01`, `cloud-init status: done`, no Cloud-init errors, `DataSourceNoCloud`, and disks `/dev/vda` and `/dev/vdb`. The root partition grew during first boot.

One Cloud-init result showed `last_update` in 1970; check guest clock synchronization and NTP before relying on timestamps or installing clustered software.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
virt-install \
  --connect qemu:///system \
  --name k3s-node01 \
  --memory 5120 \
  --vcpus 2 \
  --os-variant ubuntu24.04 \
  --import \
  --disk path=/var/lib/libvirt/images/k3s-node01.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/k3s-node01-var.qcow2,format=qcow2,bus=virtio \
  --network network=default,model=virtio,mac=52:54:00:26:00:11 \
  --cloud-init user-data=$HOME/targil2026/infrastructure/kvm/cloud-init/user-data.yaml \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole
```

```bash
virsh -c qemu:///system list --all
virsh -c qemu:///system net-dhcp-leases default
ssh zohargo@192.168.122.11
# Inside the VM:
hostname
cloud-init status --long
lsblk -f
```

## 8. Creating the `/var` filesystem

Inside node01, `/dev/vdb` was confirmed as an unused 55 GiB disk with no filesystem signatures. It was formatted ext4 with label `k3s-var` and UUID `78158383-0fcd-4c5f-9e4c-30dacb80cbcf`.

**Destructive-operation warning:** `mkfs.ext4` erases data. Verify disk identity and contents first; `wipefs -n` is read-only. Do not mount an empty disk directly over `/var`, because that would hide existing OS files.

Initial `/var` usage was about **397 MiB**, including `/var/lib` ~246 MiB, `/var/cache` ~134 MiB, and `/var/log` ~17 MiB. No nested mount points were found.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
sudo wipefs -n /dev/vdb           # read-only inspection
sudo mkfs.ext4 -L k3s-var /dev/vdb # destructive operation; new empty disk only
lsblk -f
sudo blkid /dev/vdb
```

```bash
sudo du -shx /var
ls -ld /var
sudo du -h --max-depth=1 -x /var | sort -h
findmnt -R /var
```

## 9. Offline `/var` migration

The guest was shut down before copying `/var`; offline migration prevents services from modifying files during the transfer.

**Attempt 1: guestmount/FUSE.** `rsync -aHAX` failed with `set_acl ... Invalid argument (22)` and exit code 23, involving journal files. Inspection found an additional ACL for group `adm`; the destination appeared as FUSE. An ACL limitation in the guestmount/FUSE path was suspected, but not definitively proven. The nonzero result was not ignored, and both guestmount filesystems were disconnected.

**Attempt 2: qemu-nbd.** With the VM off and NBD devices free, the OS image was attached to `/dev/nbd0` and the data disk to `/dev/nbd1`. Root appeared as `/dev/nbd0p1` (approximately 24 GiB) and the target as ext4 on `/dev/nbd1`. Root was mounted read-only (`ro,noload`), the target read-write; `rsync -aHAX --numeric-ids --one-file-system` returned **0**. A dry-run checksum comparison with `rsync -aHAXnc --itemize-changes` also returned **0**; inspect the itemized output as well because exit code 0 alone does not prove there were zero differences.

`rsync` flags: `-a` archive attributes/ownership/times; `-H` hardlinks; `-A` ACLs; `-X` extended attributes; `--numeric-ids` retain numeric UID/GID; `--one-file-system` avoid traversal into other mounts; `-n -c` checksum-based non-writing validation.

**Safety:** never attach or modify a running VM's QCOW2 image from the host, never mount the same image writable through two tools, and check NBD ownership before connecting.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
# From inside the VM:
exit
# On the host:
virsh -c qemu:///system shutdown k3s-node01
virsh -c qemu:///system domstate k3s-node01  # shut off
```

```bash
sudo mkdir -p /mnt/targil-os /mnt/targil-var
sudo guestmount --rw \
  -a /var/lib/libvirt/images/k3s-node01.qcow2 \
  -m /dev/sda1 /mnt/targil-os
sudo guestmount --rw \
  -a /var/lib/libvirt/images/k3s-node01-var.qcow2 \
  -m /dev/sda /mnt/targil-var
sudo rsync -aHAX --numeric-ids --one-file-system --info=progress2 \
  /mnt/targil-os/var/ /mnt/targil-var/
```

```text
rsync: set_acl: sys_acl_set_file(.../log/journal/...): Invalid argument (22)
rsync error: some files/attrs were not transferred (code 23)
```

```bash
sudo guestunmount /mnt/targil-os
sudo guestunmount /mnt/targil-var
findmnt /mnt/targil-os
findmnt /mnt/targil-var
```

```bash
virsh -c qemu:///system domstate k3s-node01  # shut off
sudo modprobe nbd max_part=16
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS /dev/nbd0 /dev/nbd1
for dev in nbd0 nbd1; do
  cat "/sys/class/block/$dev/pid" 2>/dev/null || echo "$dev not connected"
done
sudo qemu-nbd --connect=/dev/nbd0 --format=qcow2 \
  /var/lib/libvirt/images/k3s-node01.qcow2
sudo partprobe /dev/nbd0
sudo qemu-nbd --connect=/dev/nbd1 --format=qcow2 \
  /var/lib/libvirt/images/k3s-node01-var.qcow2
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS /dev/nbd0 /dev/nbd1
```

```bash
sudo mount -o ro,noload /dev/nbd0p1 /mnt/targil-os
sudo mount /dev/nbd1 /mnt/targil-var
findmnt /mnt/targil-os
findmnt /mnt/targil-var
sudo rsync -aHAX --numeric-ids --one-file-system --info=progress2 \
  /mnt/targil-os/var/ /mnt/targil-var/
echo "rsync exit code: $?"
```

```bash
sudo rsync -aHAXnc --numeric-ids --one-file-system --itemize-changes \
  /mnt/targil-os/var/ /mnt/targil-var/
echo "Verification exit code: $?"
```

## 10. Persistent `/var` mount in fstab

Before changing `/etc/fstab`, the root NBD filesystem was unmounted and passed a read-only `e2fsck -fn` inspection (all five stages, no reported errors). Root was remounted read-write for the edit, and an `fstab.bak` backup was created.

The intended `/var` record is:

```fstab
UUID=78158383-0fcd-4c5f-9e4c-30dacb80cbcf /var ext4 defaults 0 2
```

**Observed issue:** a `tee -a` operation was accidentally run twice and duplicated the entry. It was corrected to one record (`VAR entries: 1`). **Lesson:** appending to configuration is not idempotent; prefer test-and-replace or generate the target file deterministically.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
sudo umount /mnt/targil-os
sudo e2fsck -fn /dev/nbd0p1
```

```bash
sudo mount -o rw /dev/nbd0p1 /mnt/targil-os
findmnt -no SOURCE,FSTYPE,OPTIONS /mnt/targil-os
sudo cp -a /mnt/targil-os/etc/fstab /mnt/targil-os/etc/fstab.bak
```

```fstab
LABEL=cloudimg-rootfs / ext4 discard,commit=30,errors=remount-ro 0 1
LABEL=BOOT /boot ext4 defaults 0 2
LABEL=UEFI /boot/efi vfat umask=0077 0 1
UUID=78158383-0fcd-4c5f-9e4c-30dacb80cbcf /var ext4 defaults 0 2
```

## 11. Boot validation and automating node02/node03

The host synced data, unmounted both filesystems, confirmed no mounts remained, disconnected `/dev/nbd0` and `/dev/nbd1`, started node01, and connected over SSH. The user confirmed `findmnt /var`, `df -h /var`, `lsblk -f`, and `systemctl --failed` were correct; full boot command outputs were not retained in the source conversation.

**Rollback plan:** the original OS-disk `/var` and `fstab.bak` were retained. If a VM fails to boot, shut it down and repair offline using suitable recovery tooling. Never start a VM while its disks are writable-mounted from the host.

### Automating node02 and node03

After manually provisioning node01, repeatable scripts were created: `infrastructure/kvm/scripts/create-vm-disks.sh` and `prepare-var-disk.sh`, with per-VM Cloud-init files. A local `prepare-var-disk.sh.bak` was kept for rollback, not for Git.

Cloud-init set unique hostnames `k3s-node02` and `k3s-node03`, account `zohargo`, and the authorized public SSH key. MAC/IP reservations were created or checked: `52:54:00:26:00:12` → `192.168.122.12` and `52:54:00:26:00:13` → `192.168.122.13`. **Do not rerun `net-update ... add` when those records already exist.**

The disk script accepts only the two expected VM names and checks for existing images/VMs. It copies the base image, resizes OS to 25 GiB, and creates a blank 55 GiB `/var` image. Both VMs had initial physical image sizes near 593 MiB/196 KiB; `qemu-img info` reported `corrupt: false`.

The `/var` script rejects unexpected VM names or already-created VMs, checks NBD availability, verifies an unformatted data disk, runs `mkfs.ext4`, migrates `/var` using `rsync`, verifies contents, backs up `fstab`, and inserts the volume UUID. Both node02/node03 showed exactly one matching `/var` entry in offline `virt-cat` checks. **Not fully idempotent:** never rerun this formatter against a prepared data disk.

**Cleanup issue on node02:** the copy and verification completed, but the first unmount reported `target is busy`, leaving NBD attached. `fuser -vm` showed only `root kernel mount`, not a confirmed blocking userspace process. A normal subsequent `umount` succeeded; NBD devices were disconnected and `lsblk` displayed both as `0B`. The exact root cause was not established.

For node03, `safe_umount` was added with up to five attempts and two seconds between retries (no forced unmount); syntax validation with `bash -n` passed. Two temporary failures preceded a successful third attempt; both mounts and NBD devices were cleaned up. Avoid `umount -f`, `umount -l`, or disconnecting an attached NBD device.

Node02/node03 were created with `virt-install`, obtained reserved addresses `.12` and `.13`, accepted SSH, completed Cloud-init with `errors: []`, mounted ext4 `/var` from `/dev/vdb` (~54 GiB filesystem, ~1% initial use), grew root, and had zero failed systemd units.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
# Host computer; VM must be shut down
sync
sudo umount /mnt/targil-var
sudo umount /mnt/targil-os
findmnt /mnt/targil-var
findmnt /mnt/targil-os
sudo qemu-nbd --disconnect /dev/nbd0
sudo qemu-nbd --disconnect /dev/nbd1
virsh -c qemu:///system start k3s-node01
ssh zohargo@192.168.122.11
```

```bash
findmnt /var
df -h /var
lsblk -f
systemctl --failed
```

```text
infrastructure/kvm/
├── cloud-init/
│   ├── user-data.yaml
│   ├── node02-user-data.yaml
│   └── node03-user-data.yaml
└── scripts/
    ├── create-vm-disks.sh
    ├── prepare-var-disk.sh
    └── prepare-var-disk.sh.bak   # local backup; do not commit to Git
```

```bash
virsh -c qemu:///system net-update default add ip-dhcp-host \
  "<host mac='52:54:00:26:00:12' name='k3s-node02' ip='192.168.122.12'/>" \
  --live --config
virsh -c qemu:///system net-update default add ip-dhcp-host \
  "<host mac='52:54:00:26:00:13' name='k3s-node03' ip='192.168.122.13'/>" \
  --live --config
```

```bash
cd ~/targil2026
./infrastructure/kvm/scripts/create-vm-disks.sh k3s-node02
./infrastructure/kvm/scripts/create-vm-disks.sh k3s-node03
```

```bash
# First-time setup example only: already executed, do NOT rerun!
sudo ./infrastructure/kvm/scripts/prepare-var-disk.sh k3s-node02
sudo ./infrastructure/kvm/scripts/prepare-var-disk.sh k3s-node03
```

```bash
rsync -aHAX --numeric-ids --one-file-system SOURCE/var/ TARGET/
rsync -aHAXnc --numeric-ids --one-file-system --itemize-changes SOURCE/var/ TARGET/
```

```text
umount: /mnt/targil-var.3Mq6HA: target is busy
ERROR: A filesystem is still mounted.
NBD devices were not disconnected.
```

```text
Unmount attempt 1 failed
Unmount attempt 2 failed
Unmount successful: /mnt/targil-var.UTDiPS
Unmount successful: /mnt/targil-os.b1w9Vw
/dev/nbd1 disconnected
/dev/nbd0 disconnected
Preparation completed successfully.
Exit code: 0
```

```bash
# Example for node03, already performed: do NOT run on an existing VM.
virt-install \
  --connect qemu:///system \
  --name k3s-node03 \
  --memory 5120 \
  --vcpus 2 \
  --os-variant ubuntu24.04 \
  --import \
  --disk path=/var/lib/libvirt/images/k3s-node03.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/k3s-node03-var.qcow2,format=qcow2,bus=virtio \
  --network network=default,model=virtio,mac=52:54:00:26:00:13 \
  --cloud-init user-data=$HOME/targil2026/infrastructure/kvm/cloud-init/node03-user-data.yaml \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole
```

```bash
ping -c 3 192.168.122.11
ping -c 3 192.168.122.12
systemctl is-active ssh
ip -br addr
ip route
```

```bash
hostname
free -h
df -h /var
swapon --show
sudo ufw status
curl -I --connect-timeout 5 https://get.k3s.io
```

## 12. Design decisions and tradeoffs

**Design decisions and tradeoffs:** K3s provides a lightweight cluster for this lab; three VMs support quorum/scheduling experiments but lack physical-host redundancy; NAT works over Wi-Fi but needs planned external access; DHCP reservations centralize stable addresses; Cloud-init enables reproducible bootstrapping but clone unique machine IDs and host keys correctly; QCOW2 grows dynamically and must be capacity-monitored; separate ext4 `/var` isolates runtime data but requires careful offline migration; NBD plus `rsync` was chosen after FUSE ACL failures; `fstab` UUIDs survive device-name changes.

The cluster was subsequently installed as K3s `v1.37.2+k3s1` (see document 02).

## 13. Verified infrastructure status

**Infrastructure completion on 18 November 2026:** Three Ubuntu 24.04 VMs, each 2 vCPU, 5120 MiB RAM, 25 GiB OS, separate 55 GiB ext4 `/var`, fixed reserved IP and MAC, SSH, working Cloud-init, tested filesystems and networking.

| VM | IP | MAC | `/var` UUID | Verified result |
|---|---|---|---|---|
| `k3s-node01` | `192.168.122.11` | `52:54:00:26:00:11` | `78158383-0fcd-4c5f-9e4c-30dacb80cbcf` | running; storage and initial K3s prerequisites checked |
| `k3s-node02` | `192.168.122.12` | `52:54:00:26:00:12` | `59b0ccac-a854-4753-a763-dba4b4a66adf` | SSH, Cloud-init done, `/var` on `vdb`, zero failed services |
| `k3s-node03` | `192.168.122.13` | `52:54:00:26:00:13` | `87e88eec-efc2-4999-9a97-4f444b7656cc` | Cloud-init done, `/var` on `vdb`, networking checked, zero failed services |

On node01, observed free memory ~4.4 GiB, `/var` ~51 GiB free, no swap, inactive UFW, and `get.k3s.io` HTTP 200. This check did not prove access to all installation assets. Planned prerequisites included NTP/time, DNS, required TCP/UDP ports, pinned version, and eventually a stable API endpoint. **Later progress:** all three K3s servers joined embedded etcd and passed a follower-stop HA exercise; MongoDB was subsequently installed and validated in document 03.

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

## 14. Quick health-check commands

Use the following host and guest health commands for quick checks. **Safety:** `mkfs`, write-mode QCOW2 attachments, `qemu-nbd --connect`, and offline `fstab` changes can destroy data if a device is misidentified. Do not boot a VM while editing its disks from the host. Keep private keys, credentials, and QCOW2 images out of Git.

### Recorded commands and configuration snippets

> **Note:** these are historical commands from the exercise. Some are destructive or non-idempotent; do not execute them blindly.

```bash
# On the host
virsh -c qemu:///system list --all
virsh -c qemu:///system net-list --all
virsh -c qemu:///system net-dhcp-leases default
df -h /

# Inside the guest
hostname
cloud-init status --long
lsblk -f
findmnt /var
df -h /var
systemctl --failed
```
