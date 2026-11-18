#!/usr/bin/env bash

set -euo pipefail

VM_NAME="${1:-}"

BASE_IMAGE="/var/lib/libvirt/images/base/ubuntu-24.04.img"
IMAGE_DIR="/var/lib/libvirt/images"

OS_SIZE="25G"
VAR_SIZE="55G"

if [[ -z "$VM_NAME" ]]; then
    echo "Usage: $0 <vm-name>"
    exit 1
fi

if [[ ! "$VM_NAME" =~ ^k3s-node0[23]$ ]]; then
    echo "ERROR: Only k3s-node02 or k3s-node03 are allowed"
    exit 1
fi

OS_DISK="${IMAGE_DIR}/${VM_NAME}.qcow2"
VAR_DISK="${IMAGE_DIR}/${VM_NAME}-var.qcow2"

echo "Preparing disks for: $VM_NAME"

# Verify the base image exists
if [[ ! -f "$BASE_IMAGE" ]]; then
    echo "ERROR: Ubuntu base image not found"
    exit 1
fi

# Prevent overwriting existing disks
if [[ -e "$OS_DISK" || -e "$VAR_DISK" ]]; then
    echo "ERROR: One or more disks already exist"
    echo "No changes made"
    exit 1
fi

# Prevent creating disks for an existing VM
if virsh -c qemu:///system dominfo "$VM_NAME" &>/dev/null; then
    echo "ERROR: VM already exists"
    exit 1
fi

echo "Creating OS disk..."

sudo cp "$BASE_IMAGE" "$OS_DISK"

sudo qemu-img resize "$OS_DISK" "$OS_SIZE"

echo "Creating VAR disk..."

sudo qemu-img create \
    -f qcow2 \
    "$VAR_DISK" \
    "$VAR_SIZE"

echo "Verifying disks..."

sudo qemu-img info "$OS_DISK"
sudo qemu-img info "$VAR_DISK"

echo "Disk creation completed successfully"
