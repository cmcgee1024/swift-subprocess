#!/usr/bin/env bash
# test-using-qemu.sh
#
# Boots a Linux VM under QEMU to run commands (default: swift test) against a
# specific distro+kernel combination.  Supports two modes:
#
#   disk mode   — downloads a pre-built disk.qcow2 from images.linuxcontainers.org
#                 and injects credentials via a cloud-init seed ISO.
#
#   rootfs mode — downloads a rootfs.tar.xz from images.linuxcontainers.org and
#                 fetches the kernel separately (e.g. from an RPM repo), then
#                 builds the disk image locally with mkfs.ext4 -d.
#
# Known profiles live in the PROFILES table near the top of this file.
# Must run as root on Linux.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LXC_BASE="https://images.linuxcontainers.org/images"
LXC_GPG_KEY_IDS=(
    "602F567663359FCDE9BCD0E79F93B4C4F3D4444A"
    "C2DE3F5BDE2F6068"
)

# ── Defaults ──────────────────────────────────────────────────────────────────
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/qemu-swift-$$}"
VM_MEMORY="${VM_MEMORY:-2048}"
VM_CPUS="${VM_CPUS:-2}"
SSH_HOST_PORT="${SSH_PORT:-2222}"
KEEP_WORK="${KEEP_WORK:-false}"

QEMU_PID=""
SSH_OPTS=()

# ── Logging ───────────────────────────────────────────────────────────────────
info()  { printf '\033[32m[INFO]\033[0m  %s\n'  "$*"; }
warn()  { printf '\033[33m[WARN]\033[0m  %s\n'  "$*" >&2; }
error() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
step()  { printf '\033[36m[STEP]\033[0m  %s\n'  "$*"; }

# ── Profile registry ──────────────────────────────────────────────────────────
# Each entry is a pipe-separated string:
#   LXC_SPEC | USERSPACE_FILE | KERNEL_MODE | KERNEL_DONOR_SPEC
#
# USERSPACE_FILE:      "disk.qcow2"  → disk mode (cloud-init SSH injection)
#                      "rootfs.tar.xz" → rootfs mode (direct SSH config, -kernel boot)
#
# KERNEL_MODE:         "disk"     → kernel lives inside the disk.qcow2 (GRUB boots it)
#                      "lxc-disk" → extract kernel+initrd from a second LXC disk.qcow2;
#                                   KERNEL_DONOR_SPEC names that donor image's LXC path
#
# KERNEL_DONOR_SPEC:   LXC path (distro/release/arch/variant) of the kernel donor image.
#                      Used only for lxc-disk mode.  Debian Bullseye ships kernel 5.10 LTS
#                      and is publicly accessible, making it a good donor for AL2 userspace.
#
# To add a new combination, append a line here — no other code changes needed.

declare -A PROFILES
#                               LXC spec                          | file            | kernel    | kernel donor spec
PROFILES["al2-5.10"]="amazonlinux/2/amd64/default                | rootfs.tar.xz  | lxc-disk  | debian/bullseye/amd64/cloud"
PROFILES["al2-5.10-arm64"]="amazonlinux/2/arm64/default          | rootfs.tar.xz  | lxc-disk  | debian/bullseye/arm64/cloud"
PROFILES["almalinux-8"]="almalinux/8/amd64/cloud                 | disk.qcow2     | disk      | "
PROFILES["almalinux-8-arm64"]="almalinux/8/arm64/cloud           | disk.qcow2     | disk      | "
PROFILES["almalinux-9"]="almalinux/9/amd64/cloud                 | disk.qcow2     | disk      | "
PROFILES["almalinux-9-arm64"]="almalinux/9/arm64/cloud           | disk.qcow2     | disk      | "
PROFILES["rockylinux-8"]="rockylinux/8/amd64/cloud               | disk.qcow2     | disk      | "
PROFILES["rockylinux-8-arm64"]="rockylinux/8/arm64/cloud         | disk.qcow2     | disk      | "
PROFILES["rockylinux-9"]="rockylinux/9/amd64/cloud               | disk.qcow2     | disk      | "
PROFILES["rockylinux-9-arm64"]="rockylinux/9/arm64/cloud         | disk.qcow2     | disk      | "
PROFILES["ubuntu-22.04"]="ubuntu/jammy/amd64/cloud               | disk.qcow2     | disk      | "
PROFILES["ubuntu-22.04-arm64"]="ubuntu/jammy/arm64/cloud         | disk.qcow2     | disk      | "
PROFILES["ubuntu-24.04"]="ubuntu/noble/amd64/cloud               | disk.qcow2     | disk      | "
PROFILES["ubuntu-24.04-arm64"]="ubuntu/noble/arm64/cloud         | disk.qcow2     | disk      | "
PROFILES["debian-12"]="debian/bookworm/amd64/cloud               | disk.qcow2     | disk      | "
PROFILES["debian-12-arm64"]="debian/bookworm/arm64/cloud         | disk.qcow2     | disk      | "

list_profiles() {
    echo "Available profiles:"
    for key in $(echo "${!PROFILES[@]}" | tr ' ' '\n' | sort); do
        local lxc_spec; lxc_spec=$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); print $1}' <<< "${PROFILES[$key]}")
        printf "  %-20s  %s\n" "$key" "$lxc_spec"
    done
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    set +e
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        info "Shutting down VM (PID $QEMU_PID)..."
        ssh "${SSH_OPTS[@]}" root@localhost "poweroff" 2>/dev/null || true
        sleep 3
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [[ "$KEEP_WORK" != "true" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    elif [[ "$KEEP_WORK" == "true" ]]; then
        info "Work directory preserved: $WORK_DIR"
    fi
}
trap cleanup EXIT INT TERM

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [<profile>] [-- <guest-command>]

Boot a Linux VM under QEMU and run a command inside it.

OPTIONS:
  -h, --help             Show this help
  --list-profiles        List available profiles and exit
  -m, --memory MB        VM RAM in MB              (default: $VM_MEMORY, env: VM_MEMORY)
  -c, --cpus N           VM CPU count              (default: $VM_CPUS,   env: VM_CPUS)
  -w, --workdir DIR      Host directory to copy to /mnt/host (default: CWD)
  -p, --ssh-port PORT    Host-side SSH forwarding port (default: $SSH_HOST_PORT, env: SSH_PORT)
      --keep-image       Reuse existing disk image in WORK_DIR (skip download/build)
      --keep-work        Preserve WORK_DIR after exit
      --skip-install     Skip tool installation
      --no-swift         Skip Swift toolchain installation

PROFILE (default: al2-5.10):
  A named entry from the built-in profile table.  Run --list-profiles to see all.
  Examples:  al2-5.10   almalinux-8   ubuntu-22.04   debian-12

GUEST COMMAND (after --):
  Runs as root inside the VM, in /mnt/host, with Swift on PATH.
  Default: swift test

ENVIRONMENT: VM_MEMORY  VM_CPUS  SSH_PORT  KEEP_WORK  WORK_DIR  TMPDIR

NOTES:
  - disk mode images require cloud-init in the guest (Ubuntu, Debian, Fedora, AlmaLinux do).
  - rootfs mode (e.g. al2-5.10) fetches userspace from LXC and kernel from a donor disk image.
  - lxc-disk kernel mode downloads a second LXC disk.qcow2 and extracts vmlinuz+initrd via debugfs.
  - rootfs mode waits up to 10 min for SSH; first boot installs openssh-server if absent.
  - amd64: QEMU's built-in SeaBIOS handles GRUB boot; no extra firmware needed.
  - arm64: install qemu-efi-aarch64 for UEFI firmware.
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
HOST_WORKDIR="$(pwd)"
PROFILE_NAME="al2-5.10"
GUEST_COMMAND="swift test"
KEEP_IMAGE=false
SKIP_INSTALL=false
NO_SWIFT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)            usage ;;
        --list-profiles)      list_profiles; exit 0 ;;
        -m|--memory)          VM_MEMORY="$2";     shift 2 ;;
        -c|--cpus)            VM_CPUS="$2";       shift 2 ;;
        -w|--workdir)         HOST_WORKDIR="$2";  shift 2 ;;
        -p|--ssh-port)        SSH_HOST_PORT="$2"; shift 2 ;;
        --keep-image)         KEEP_IMAGE=true;    shift ;;
        --keep-work)          KEEP_WORK=true;     shift ;;
        --skip-install)       SKIP_INSTALL=true;  shift ;;
        --no-swift)           NO_SWIFT=true;      shift ;;
        --)                   shift; GUEST_COMMAND="$*"; break ;;
        -*)                   error "Unknown option: $1" ;;
        *)                    PROFILE_NAME="$1";  shift ;;
    esac
done

[[ ! -d "$HOST_WORKDIR" ]] && error "Workdir not found: $HOST_WORKDIR"
[[ "$(id -u)" -ne 0 ]] && error "Must run as root."

# ── Load profile ──────────────────────────────────────────────────────────────
[[ -z "${PROFILES[$PROFILE_NAME]+_}" ]] && {
    error "Unknown profile '$PROFILE_NAME'. Run --list-profiles to see available profiles."
}

IFS='|' read -r P_LXC_SPEC P_USERSPACE_FILE P_KERNEL_MODE P_KERNEL_DONOR_SPEC \
    <<< "${PROFILES[$PROFILE_NAME]}"

# Trim whitespace from each field
P_LXC_SPEC=$(echo "$P_LXC_SPEC" | xargs)
P_USERSPACE_FILE=$(echo "$P_USERSPACE_FILE" | xargs)
P_KERNEL_MODE=$(echo "$P_KERNEL_MODE" | xargs)
P_KERNEL_DONOR_SPEC=$(echo "$P_KERNEL_DONOR_SPEC" | xargs)

IFS='/' read -r DISTRO RELEASE ARCH VARIANT <<< "$P_LXC_SPEC"
VARIANT="${VARIANT:-default}"

info "Profile:  $PROFILE_NAME  ($P_LXC_SPEC, $P_USERSPACE_FILE, kernel: $P_KERNEL_MODE)"
info "Workdir:  $HOST_WORKDIR"
info "Command:  $GUEST_COMMAND"
info "VM:       ${VM_MEMORY} MB RAM, ${VM_CPUS} CPU(s)"
info "SSH port: $SSH_HOST_PORT"

mkdir -p "$WORK_DIR"

# ── Architecture ──────────────────────────────────────────────────────────────
# amd64: q35 + built-in SeaBIOS — no firmware file needed.
# arm64: virt machine needs UEFI (EDK2); install qemu-efi-aarch64.
case "$ARCH" in
    amd64|x86_64)
        QEMU_BIN="qemu-system-x86_64"
        QEMU_MACHINE_ARGS=(-machine q35)
        UEFI_PKG=""
        UEFI_FIRMWARE_SEARCH=()
        ;;
    arm64|aarch64)
        QEMU_BIN="qemu-system-aarch64"
        QEMU_MACHINE_ARGS=(-machine virt -cpu cortex-a57)
        UEFI_PKG="qemu-efi-aarch64"
        UEFI_FIRMWARE_SEARCH=(
            /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
            /usr/share/edk2/aarch64/QEMU_EFI.fd
            /usr/share/edk2-aarch64/QEMU_EFI.fd
        )
        ;;
    *)  error "Unsupported architecture: $ARCH" ;;
esac

# ── Install host tools (host must be Ubuntu) ──────────────────────────────────
install_tools() {
    step "Installing required tools..."
    apt-get update -qq
    local pkgs=(qemu-utils openssh-client gpg curl cpio genisoimage parted xz-utils)
    case "$ARCH" in
        amd64|x86_64) pkgs+=(qemu-system-x86) ;;
        arm64|aarch64) pkgs+=(qemu-system-arm qemu-efi-aarch64) ;;
    esac
    # rootfs mode additionally needs e2fsprogs (debugfs) for lxc-disk kernel extraction
    [[ "$P_USERSPACE_FILE" != "disk.qcow2" ]] && pkgs+=(e2fsprogs)
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

[[ "$SKIP_INSTALL" != "true" ]] && install_tools

# Verify required binaries
command -v "$QEMU_BIN" &>/dev/null || error "$QEMU_BIN not found."
command -v ssh         &>/dev/null || error "ssh not found."
command -v curl        &>/dev/null || error "curl not found."
command -v sha256sum   &>/dev/null || error "sha256sum not found."

MKISO_CMD=""
for c in genisoimage mkisofs xorriso; do
    command -v "$c" &>/dev/null && { MKISO_CMD="$c"; break; }
done

# ── Locate UEFI firmware (arm64 only) ────────────────────────────────────────
UEFI_FIRMWARE=""
for f in "${UEFI_FIRMWARE_SEARCH[@]:-}"; do
    [[ -f "$f" ]] && { UEFI_FIRMWARE="$f"; break; }
done
[[ "${#UEFI_FIRMWARE_SEARCH[@]}" -gt 0 && -z "$UEFI_FIRMWARE" ]] && \
    error "ARM64 UEFI firmware not found. Install: $UEFI_PKG"
[[ -n "$UEFI_FIRMWARE" ]] && info "UEFI firmware: $UEFI_FIRMWARE"

# ── Find latest LXC build ─────────────────────────────────────────────────────
step "Finding latest build for $P_LXC_SPEC..."
IMAGE_URL_BASE="$LXC_BASE/$DISTRO/$RELEASE/$ARCH/$VARIANT"
BUILD=$(curl -sf "$IMAGE_URL_BASE/" \
    | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' \
    | sort | tail -1) || true
[[ -z "$BUILD" ]] && error "No builds found at $IMAGE_URL_BASE/"
info "Latest build: $BUILD"
BUILD_URL="$IMAGE_URL_BASE/$BUILD"

SHA256SUMS_FILE="$WORK_DIR/SHA256SUMS"
SHA256SUMS_SIG="$WORK_DIR/SHA256SUMS.asc"
step "Fetching SHA256SUMS..."
curl -f -sS -o "$SHA256SUMS_FILE" "$BUILD_URL/SHA256SUMS"

if ! grep -qE '(^|\s)\.?/?'"$P_USERSPACE_FILE"'(\s|$)' "$SHA256SUMS_FILE"; then
    error "$P_USERSPACE_FILE not listed in SHA256SUMS for $P_LXC_SPEC.\nBrowse: $BUILD_URL/"
fi

# ── Download userspace image ──────────────────────────────────────────────────
USERSPACE_FILE="$WORK_DIR/$P_USERSPACE_FILE"

if [[ "$KEEP_IMAGE" == "true" && -f "$USERSPACE_FILE" ]]; then
    info "Reusing existing userspace image: $USERSPACE_FILE"
else
    step "Downloading $P_USERSPACE_FILE..."
    curl -f --progress-bar -o "$USERSPACE_FILE" "$BUILD_URL/$P_USERSPACE_FILE"
fi

if ! curl -f -sS -o "$SHA256SUMS_SIG" "$BUILD_URL/SHA256SUMS.asc" 2>/dev/null; then
    curl -f -sS -o "$SHA256SUMS_SIG" "$BUILD_URL/SHA256SUMS.gpg" 2>/dev/null || \
        warn "No signature file; skipping GPG verification."
fi

# ── Verify checksum ───────────────────────────────────────────────────────────
step "Verifying image integrity..."
export GNUPGHOME="$WORK_DIR/.gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"

if [[ -s "$SHA256SUMS_SIG" ]]; then
    GPG_VERIFIED=false
    for key_id in "${LXC_GPG_KEY_IDS[@]}"; do
        if gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys "$key_id" 2>/dev/null ||
           gpg --keyserver hkps://keys.openpgp.org    --recv-keys "$key_id" 2>/dev/null; then
            if gpg --verify "$SHA256SUMS_SIG" "$SHA256SUMS_FILE" 2>/dev/null; then
                info "GPG signature verified (key: $key_id)"
                GPG_VERIFIED=true; break
            fi
        fi
    done
    [[ "$GPG_VERIFIED" != "true" ]] && warn "GPG verification failed; continuing with SHA256 only."
else
    warn "No signature file; skipping GPG verification."
fi

EXPECTED_HASH=$(awk -v f="$P_USERSPACE_FILE" '$2==f || $2=="./"f {print $1}' "$SHA256SUMS_FILE")
[[ -z "$EXPECTED_HASH" ]] && error "No checksum for $P_USERSPACE_FILE in SHA256SUMS"
ACTUAL_HASH=$(sha256sum "$USERSPACE_FILE" | awk '{print $1}')
[[ "$EXPECTED_HASH" == "$ACTUAL_HASH" ]] || \
    error "SHA256 mismatch!\n  Expected: $EXPECTED_HASH\n  Actual:   $ACTUAL_HASH"
info "SHA256 checksum OK"

# ── Generate SSH key (used by both modes) ─────────────────────────────────────
ssh-keygen -t ed25519 -f "$WORK_DIR/vm_key" -N "" -C "qemu-swift-test" -q
VM_PUBKEY=$(cat "$WORK_DIR/vm_key.pub")

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o ConnectTimeout=5
    -o BatchMode=yes
    -o LogLevel=ERROR
    -i "$WORK_DIR/vm_key"
    -p "$SSH_HOST_PORT"
)

# ══════════════════════════════════════════════════════════════════════════════
# DISK MODE — pre-built qcow2, cloud-init seed ISO for credentials
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$P_USERSPACE_FILE" == "disk.qcow2" ]]; then

    # Cloud-init NoCloud seed ISO: injects our SSH key into root's authorized_keys
    # on first boot via runcmd.  All images in this mode have cloud-init installed.
    [[ -z "$MKISO_CMD" ]] && error "No ISO tool found. Install genisoimage, mkisofs, or xorriso."

    step "Creating cloud-init seed ISO..."
    CLOUD_DIR="$WORK_DIR/cloud-init"
    mkdir -p "$CLOUD_DIR"

    cat > "$CLOUD_DIR/meta-data" <<METADATA
instance-id: qemu-swift-$$
local-hostname: swift-test
METADATA

    cat > "$CLOUD_DIR/user-data" <<USERDATA
#cloud-config
disable_root: false
ssh_pwauth: false
runcmd:
  - mkdir -p /root/.ssh
  - chmod 700 /root/.ssh
  - echo "${VM_PUBKEY}" > /root/.ssh/authorized_keys
  - chmod 600 /root/.ssh/authorized_keys
  - mkdir -p /etc/ssh/sshd_config.d
  - echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/99-root.conf
  - systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
  - systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null || true
USERDATA

    SEED_ISO="$WORK_DIR/seed.iso"
    case "$MKISO_CMD" in
        genisoimage|mkisofs)
            "$MKISO_CMD" -output "$SEED_ISO" -volid cidata -joliet -rock \
                "$CLOUD_DIR/user-data" "$CLOUD_DIR/meta-data" 2>/dev/null ;;
        xorriso)
            xorriso -as mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock \
                "$CLOUD_DIR/user-data" "$CLOUD_DIR/meta-data" 2>/dev/null ;;
    esac

    # COW overlay keeps the base image pristine; --keep-image reuses the base
    OVERLAY_IMAGE="$WORK_DIR/overlay.qcow2"
    qemu-img create -q -f qcow2 -b "$USERSPACE_FILE" -F qcow2 "$OVERLAY_IMAGE"

    QEMU_CMD=(
        "$QEMU_BIN"
        "${QEMU_MACHINE_ARGS[@]}"
        -m "$VM_MEMORY"
        -smp "$VM_CPUS"
        -drive "file=${OVERLAY_IMAGE},if=virtio,format=qcow2"
        -drive "file=${SEED_ISO},if=virtio,format=raw"
        -netdev "user,id=net0,hostfwd=tcp::${SSH_HOST_PORT}-:22"
        -device virtio-net-pci,netdev=net0
        -display none
        -serial "file:${WORK_DIR}/console.log"
    )
    [[ -n "$UEFI_FIRMWARE" ]] && QEMU_CMD+=(-bios "$UEFI_FIRMWARE")
    [[ -e /dev/kvm ]] && QEMU_CMD+=(-enable-kvm)

# ══════════════════════════════════════════════════════════════════════════════
# ROOTFS MODE — assemble kernel + userspace from separate sources, -kernel boot
# ══════════════════════════════════════════════════════════════════════════════
else

    ROOTFS_DIR="$WORK_DIR/rootfs"
    DISK_IMAGE="$WORK_DIR/vm.qcow2"

    if [[ "$KEEP_IMAGE" == "true" && -f "$DISK_IMAGE" ]]; then
        info "Reusing existing disk image: $DISK_IMAGE"
    else

        # ── Extract rootfs ────────────────────────────────────────────────────
        step "Extracting rootfs to $ROOTFS_DIR..."
        rm -rf "$ROOTFS_DIR"
        mkdir -p "$ROOTFS_DIR"
        # --no-same-owner avoids chown() failures when CAP_CHOWN is restricted
        tar -C "$ROOTFS_DIR" -xf "$USERSPACE_FILE" --no-same-owner
        [[ -d "$ROOTFS_DIR/etc" ]] || error "Rootfs extraction looks empty; check the tarball."

        # resolv.conf is often a dangling symlink in LXC images.  Write reliable
        # public DNS so the guest's queries go through QEMU's NAT directly to
        # Google/Cloudflare rather than through QEMU's own DNS proxy, which drops
        # queries under load.  Prevent NetworkManager from overwriting this with
        # whatever DHCP provides (QEMU's proxy at 10.0.2.3).
        rm -f "$ROOTFS_DIR/etc/resolv.conf"
        printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$ROOTFS_DIR/etc/resolv.conf"
        mkdir -p "$ROOTFS_DIR/etc/NetworkManager/conf.d"
        printf '[main]\ndns=none\n' > "$ROOTFS_DIR/etc/NetworkManager/conf.d/90-dns-none.conf"

        # ── Configure SSH access (no chroot needed) ───────────────────────────
        step "Configuring SSH access in rootfs..."
        mkdir -p "$ROOTFS_DIR/root/.ssh"
        chmod 700 "$ROOTFS_DIR/root/.ssh"
        echo "$VM_PUBKEY" > "$ROOTFS_DIR/root/.ssh/authorized_keys"
        chmod 600 "$ROOTFS_DIR/root/.ssh/authorized_keys"

        mkdir -p "$ROOTFS_DIR/etc/ssh/sshd_config.d"
        echo "PermitRootLogin yes" > "$ROOTFS_DIR/etc/ssh/sshd_config.d/99-root.conf"

        # Pre-generate SSH host keys so sshd can start without /dev/urandom issues
        ssh-keygen -A -f "$ROOTFS_DIR" 2>/dev/null || true

        # Enable sshd at boot via systemd wants symlink
        mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
        for svc in \
            "$ROOTFS_DIR/usr/lib/systemd/system/sshd.service" \
            "$ROOTFS_DIR/lib/systemd/system/sshd.service" \
            "$ROOTFS_DIR/usr/lib/systemd/system/ssh.service" \
            "$ROOTFS_DIR/lib/systemd/system/ssh.service"; do
            if [[ -f "$svc" ]]; then
                ln -sf "${svc#"$ROOTFS_DIR"}" \
                    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/$(basename "$svc")"
                break
            fi
        done

        # ── Bootstrap sshd if not pre-installed ──────────────────────────────────
        # LXC container images are minimal; openssh-server is often absent (e.g. AL2).
        # If sshd is missing, drop a one-shot systemd unit that installs it on first
        # boot via the guest's own package manager.  QEMU's user-mode NAT gives the VM
        # internet access, so yum/apt can reach their public CDN mirrors.
        # The ConditionPathExists guard makes it a no-op on subsequent boots.
        if [[ ! -f "$ROOTFS_DIR/usr/sbin/sshd" && ! -f "$ROOTFS_DIR/sbin/sshd" ]]; then
            warn "sshd not found in rootfs — adding first-boot service to install it (~30–60 s extra)."
            cat > "$ROOTFS_DIR/etc/systemd/system/qemu-bootstrap-sshd.service" <<'SVCEOF'
[Unit]
Description=Bootstrap: install openssh-server for QEMU SSH access
After=network.target
Wants=network.target
ConditionPathExists=!/root/.qemu-sshd-bootstrapped

[Service]
Type=oneshot
TimeoutStartSec=300
ExecStart=/bin/bash -c '\
    for i in $(seq 1 30); do ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 && break; sleep 1; done; \
    if command -v yum >/dev/null 2>&1; then \
        yum install -y openssh-server; \
    elif command -v apt-get >/dev/null 2>&1; then \
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server; \
    fi'
ExecStartPost=/bin/bash -c 'systemctl enable --now sshd 2>/dev/null || systemctl enable --now ssh 2>/dev/null || true'
ExecStartPost=/bin/bash -c 'touch /root/.qemu-sshd-bootstrapped'
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF
            ln -sf /etc/systemd/system/qemu-bootstrap-sshd.service \
                "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/qemu-bootstrap-sshd.service"
        fi

        printf '/dev/vda1  /     ext4  defaults  0 1\ntmpfs  /tmp  tmpfs  defaults  0 0\n' \
            > "$ROOTFS_DIR/etc/fstab"

        # ── Fetch kernel from LXC donor disk image (lxc-disk mode) ──────────────
        if [[ "$P_KERNEL_MODE" == "lxc-disk" ]]; then
            [[ -z "$P_KERNEL_DONOR_SPEC" ]] && error "lxc-disk mode requires a KERNEL_DONOR_SPEC"
            step "Fetching kernel from LXC donor: $P_KERNEL_DONOR_SPEC..."

            IFS='/' read -r D_DISTRO D_RELEASE D_ARCH D_VARIANT <<< "$P_KERNEL_DONOR_SPEC"
            D_VARIANT="${D_VARIANT:-cloud}"
            DONOR_URL_BASE="$LXC_BASE/$D_DISTRO/$D_RELEASE/$D_ARCH/$D_VARIANT"

            DONOR_BUILD=$(curl -sf "$DONOR_URL_BASE/" \
                | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' \
                | sort | tail -1) || true
            [[ -z "$DONOR_BUILD" ]] && error "No builds found for kernel donor at $DONOR_URL_BASE/"
            info "Donor build: $DONOR_BUILD"

            DONOR_QCOW="$WORK_DIR/kernel-donor.qcow2"
            step "Downloading donor disk.qcow2..."
            curl -f --progress-bar -o "$DONOR_QCOW" "$DONOR_URL_BASE/$DONOR_BUILD/disk.qcow2"

            # Convert to raw so losetup can attach it (ioctl-based, no mount syscall)
            DONOR_RAW="$WORK_DIR/kernel-donor.raw"
            step "Converting donor image to raw for losetup..."
            qemu-img convert -f qcow2 -O raw "$DONOR_QCOW" "$DONOR_RAW"
            rm -f "$DONOR_QCOW"

            DONOR_LOOP=$(losetup -f --show --partscan "$DONOR_RAW")
            for _ in $(seq 1 15); do ls "${DONOR_LOOP}p"* &>/dev/null 2>&1 && break; sleep 1; done

            # Walk partitions and use debugfs to find the one containing /boot/vmlinuz-*
            VMLINUZ_FOUND=false
            for part in "${DONOR_LOOP}p"*; do
                [[ -b "$part" ]] || continue
                if debugfs -R "ls /boot" "$part" 2>/dev/null | grep -q "vmlinuz"; then
                    step "Extracting kernel+initrd from $part..."
                    VMLINUZ_NAME=$(debugfs -R "ls /boot" "$part" 2>/dev/null \
                        | grep -oE 'vmlinuz-[^ <]+' | sort -V | tail -1)
                    INITRD_NAME=$(debugfs -R "ls /boot" "$part" 2>/dev/null \
                        | grep -oE 'initrd\.img-[^ <]+' | sort -V | tail -1)
                    [[ -z "$VMLINUZ_NAME" ]] && continue
                    debugfs -R "dump /boot/$VMLINUZ_NAME $WORK_DIR/vmlinuz" "$part" 2>/dev/null
                    [[ -n "$INITRD_NAME" ]] && \
                        debugfs -R "dump /boot/$INITRD_NAME $WORK_DIR/initrd.img" "$part" 2>/dev/null
                    VMLINUZ_FOUND=true
                    info "Kernel: $VMLINUZ_NAME"
                    [[ -n "$INITRD_NAME" ]] && info "Initrd: $INITRD_NAME"
                    break
                fi
            done

            losetup -d "$DONOR_LOOP" 2>/dev/null || true
            rm -f "$DONOR_RAW"
            [[ "$VMLINUZ_FOUND" != "true" ]] && error "No vmlinuz found in donor disk image"
        fi

        # ── Create disk image from rootfs directory (no mount needed) ─────────
        step "Creating disk image via mkfs.ext4 -d..."
        RAW_IMAGE="$WORK_DIR/vm.raw"
        DISK_SIZE="${VM_DISK_SIZE:-10G}"
        truncate -s "$DISK_SIZE" "$RAW_IMAGE"
        parted -s "$RAW_IMAGE" mklabel msdos
        parted -s "$RAW_IMAGE" mkpart primary ext4 1MiB 100%
        LOOP_DEV=$(losetup -f --show --partscan "$RAW_IMAGE")
        for _ in $(seq 1 15); do [[ -b "${LOOP_DEV}p1" ]] && break; sleep 1; done
        [[ -b "${LOOP_DEV}p1" ]] || error "Partition ${LOOP_DEV}p1 did not appear."
        mkfs.ext4 -F -L root -d "$ROOTFS_DIR" "${LOOP_DEV}p1"
        losetup -d "$LOOP_DEV" 2>/dev/null || true

        step "Converting to qcow2..."
        qemu-img convert -f raw -O qcow2 "$RAW_IMAGE" "$DISK_IMAGE"
        rm -f "$RAW_IMAGE"
        info "Disk image ready: $DISK_IMAGE"
    fi

    # Build QEMU command for direct kernel boot
    QEMU_KERNEL="$WORK_DIR/vmlinuz"
    QEMU_INITRD="$WORK_DIR/initrd.img"
    [[ -f "$QEMU_KERNEL" ]] || error "Kernel not found at $QEMU_KERNEL"

    # net.ifnames=0: use eth0 naming so NetworkManager/ifcfg finds the NIC
    KERNEL_APPEND="root=/dev/vda1 rw console=ttyS0,115200n8 net.ifnames=0 biosdevname=0 quiet"

    QEMU_CMD=(
        "$QEMU_BIN"
        "${QEMU_MACHINE_ARGS[@]}"
        -m "$VM_MEMORY"
        -smp "$VM_CPUS"
        -kernel "$QEMU_KERNEL"
        -append "$KERNEL_APPEND"
        -drive "file=${DISK_IMAGE},if=virtio,format=qcow2"
        -netdev "user,id=net0,hostfwd=tcp::${SSH_HOST_PORT}-:22"
        -device virtio-net-pci,netdev=net0
        -display none
        -serial "file:${WORK_DIR}/console.log"
    )
    [[ -f "$QEMU_INITRD" ]] && QEMU_CMD+=(-initrd "$QEMU_INITRD")
    [[ -n "$UEFI_FIRMWARE" ]] && QEMU_CMD+=(-bios "$UEFI_FIRMWARE")
    [[ -e /dev/kvm ]] && QEMU_CMD+=(-enable-kvm)

fi

# ── Boot ──────────────────────────────────────────────────────────────────────
step "Booting VM..."
info "QEMU: ${QEMU_CMD[*]}"
"${QEMU_CMD[@]}" &
QEMU_PID=$!
info "QEMU PID: $QEMU_PID"

# ── Wait for SSH ──────────────────────────────────────────────────────────────
# rootfs mode may need extra time on first boot to install openssh-server via yum/apt.
SSH_MAX_WAIT=60
[[ "$P_USERSPACE_FILE" != "disk.qcow2" ]] && SSH_MAX_WAIT=120
step "Waiting for VM SSH (up to $((SSH_MAX_WAIT * 5 / 60)) min)..."
SSH_CONNECTED=false
for i in $(seq 1 $SSH_MAX_WAIT); do
    if ssh "${SSH_OPTS[@]}" root@localhost "echo ok" &>/dev/null; then
        SSH_CONNECTED=true
        info "SSH connected (${i}×5 s = $((i*5)) s elapsed)."
        break
    fi
    sleep 5
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        warn "QEMU exited unexpectedly. Boot console:"
        cat "$WORK_DIR/console.log" >&2
        error "VM boot failed."
    fi
done

if [[ "$SSH_CONNECTED" != "true" ]]; then
    warn "SSH timeout. Boot console:"
    cat "$WORK_DIR/console.log" >&2
    error "Could not SSH into VM after $((SSH_MAX_WAIT * 5 / 60)) minutes."
fi

# ── Copy working directory into VM ───────────────────────────────────────────
step "Copying workdir to VM at /mnt/host..."
ssh "${SSH_OPTS[@]}" root@localhost "mkdir -p /mnt/host"
scp -r -P "$SSH_HOST_PORT" -i "$WORK_DIR/vm_key" \
    -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR \
    "$HOST_WORKDIR/." root@localhost:/mnt/host/

# ── Install Swift toolchain ───────────────────────────────────────────────────
if [[ "$NO_SWIFT" != "true" ]]; then
    step "Installing Swift toolchain via swiftly..."
    ssh "${SSH_OPTS[@]}" root@localhost \
        "cd /mnt/host && bash scripts/prep-linux-swift.sh --install-swiftly"
fi

# ── Run guest command ─────────────────────────────────────────────────────────
step "Running guest command: $GUEST_COMMAND"
ssh "${SSH_OPTS[@]}" root@localhost bash <<ENDSSH
[ -f /root/.local/share/swiftly/env.sh ] && . /root/.local/share/swiftly/env.sh
cd /mnt/host
$GUEST_COMMAND
ENDSSH

info "Guest command completed successfully."
