#!/usr/bin/env bash

set -euo pipefail

VM_NAME="${VM_NAME:-ubuntu-local}"
VM_DIR="${VM_DIR:-$HOME/vms/ubuntu}"
UBUNTU_IMG="${UBUNTU_IMG:-ubuntu-26.04}"
UBUNTU_URL="${UBUNTU_URL:-https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-amd64.img}"
DISK_GB="${DISK_GB:-20}"
MEMORY_MB="${MEMORY_MB:-16384}"
VCPUS="${VCPUS:-2}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SKIP_INSTALL="${SKIP_INSTALL:-0}"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"

usage() {
  cat <<'EOF'
Usage: ubuntu-cloud-vm.sh [--help]

Fedora KVM/libvirt: Ubuntu 24.04 cloud image + cloud-init seed, then virt-install.

Environment overrides:
  VM_NAME VM_DIR UBUNTU_IMG UBUNTU_URL DISK_GB MEMORY_MB VCPUS SSH_KEY
  SKIP_INSTALL=1    skip dnf + libvirtd setup (expects tools already installed)
  FORCE_DOWNLOAD=1  re-download cloud image even if present
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_host_packages() {
  if [[ "$SKIP_INSTALL" == "1" ]]; then
    log "SKIP_INSTALL=1: skipping dnf install and libvirtd setup."
    return
  fi
  sudo dnf install -y @virtualization virt-install qemu-img cloud-utils-cloud-localds
  sudo systemctl enable --now libvirtd
  sudo virsh net-start default 2>/dev/null || true
  sudo virsh net-autostart default
}

pick_os_variant() {
  local preferred="ubuntu24.04"
  if cmd_exists osinfo-query; then
    if osinfo-query os 2>/dev/null | awk '{print $1}' | grep -qx "$preferred"; then
      printf '%s' "$preferred"
      return
    fi
    local fallback
    fallback="$(osinfo-query os 2>/dev/null | awk 'tolower($0) ~ /ubuntu/ {print $1; exit}')"
    if [[ -n "${fallback:-}" ]]; then
      log "Note: ${preferred} not in osinfo-db; using ${fallback}."
      printf '%s' "$fallback"
      return
    fi
  fi
  log "Note: osinfo-query unavailable; using generic."
  printf '%s' "generic"
}

ensure_ssh_key() {
  if [[ -f "${SSH_KEY}.pub" ]]; then
    return
  fi
  log "Generating SSH key at ${SSH_KEY} ..."
  ssh-keygen -t ed25519 -N "" -f "$SSH_KEY"
}

ensure_vm_dir_writable() {
  mkdir -p "$VM_DIR"
  if [[ ! -w "$VM_DIR" ]]; then
    die "VM_DIR is not writable: $VM_DIR (fix: sudo chown -R \"$(id -un):$(id -gn)\" \"$VM_DIR\" or set VM_DIR to a directory under your home)."
  fi
}

write_cloud_init() {
  local pub
  pub="$(cat "${SSH_KEY}.pub")"
  cat >"$VM_DIR/user-data" <<EOF
#cloud-config
users:
  - default
ssh_authorized_keys:
  - ${pub}
packages:
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
EOF
  cat >"$VM_DIR/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF
  # cloud-localds writes seed.iso in CWD; stale or root-owned seed.iso breaks non-root runs.
  rm -f "$VM_DIR/seed.iso"
  (cd "$VM_DIR" && cloud-localds seed.iso user-data meta-data)
}

download_image() {
  local path="$VM_DIR/$UBUNTU_IMG"
  if [[ -f "$path" && "$FORCE_DOWNLOAD" != "1" ]]; then
    log "Using existing image: $path"
    return
  fi
  log "Downloading Ubuntu cloud image ..."
  curl -fL -o "$path" "$UBUNTU_URL"
  qemu-img resize "$path" "${DISK_GB}G"
}

domain_exists() {
  sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1
}

remove_existing_vm() {
  if ! domain_exists; then
    return
  fi

  log "Domain '$VM_NAME' already exists. Recreating from scratch ..."

  sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true

  if ! sudo virsh undefine "$VM_NAME" --remove-all-storage --nvram; then
    sudo virsh undefine "$VM_NAME" --remove-all-storage || true
  fi

  rm -f "$VM_DIR/$UBUNTU_IMG" "$VM_DIR/seed.iso" "$VM_DIR/user-data" "$VM_DIR/meta-data"
}

create_vm() {
  local img seed osv
  img="$(realpath "$VM_DIR/$UBUNTU_IMG")"
  seed="$(realpath "$VM_DIR/seed.iso")"
  osv="$(pick_os_variant)"
  log "Creating VM '$VM_NAME' (os-variant=$osv) ..."
  sudo virt-install \
    --name "$VM_NAME" \
    --memory "$MEMORY_MB" \
    --vcpus "$VCPUS" \
    --disk "path=${img},format=qcow2,bus=virtio" \
    --disk "path=${seed},device=cdrom" \
    --os-variant "$osv" \
    --import \
    --network network=default,model=virtio \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole
}

print_next_steps() {
  log ""
  log "VM IP (when lease is ready):"
  log "  sudo virsh domifaddr $VM_NAME"
  log ""
  log "SSH (Ubuntu cloud default user is often 'ubuntu'):"
  log "  ssh ubuntu@<VM_IP>"
  log ""
  log "Useful:"
  log "  sudo virsh list --all"
  log "  sudo virsh start $VM_NAME"
  log "  sudo virsh shutdown $VM_NAME"
  log "  sudo virsh console $VM_NAME"
  log "  sudo virsh domifaddr $VM_NAME"
  log "  ssh ubuntu@<VM_IP>"
  log "  ssh -N -L 8080:127.0.0.1:8080 ubuntu@<VM_IP>"
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac

  ensure_vm_dir_writable
  cd "$VM_DIR"

  ensure_host_packages

  for b in virt-install qemu-img cloud-localds curl virsh sudo; do
    cmd_exists "$b" || die "Missing command: $b (install host packages or fix PATH)."
  done

  remove_existing_vm
  ensure_ssh_key
  download_image
  write_cloud_init
  create_vm
  print_next_steps
}

main "$@"