#!/usr/bin/env bash
# =============================================================================
# Install Battlemage GPU firmware and load the xe kernel driver.
#
# Clones the linux-firmware repository, installs the Battlemage GuC and HuC
# firmware blobs (bmg_guc_70.bin, bmg_huc.bin) into /lib/firmware/xe/, then
# loads or reloads the xe kernel driver. Finally verifies the driver is bound
# to the GPU and adds the current user to the render/video groups for access.
#
# Assumes:
#   - Ubuntu 24.04 (or compatible)
#   - Kernel >= 6.8 with xe driver support for Battlemage
#   - You have sudo access
#
# Run with: sudo bash 01-install-firmware.sh
# =============================================================================

set -euo pipefail

log()  { echo ""; echo "==> $*"; }
info() { echo "    $*" >&2; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log "Cloning linux-firmware..."
git clone --depth=1 \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git \
  "$TMPDIR/linux-firmware"

FW_SRC="$TMPDIR/linux-firmware/xe"
FW_DST="/lib/firmware/xe"

log "Creating firmware directory..."
sudo mkdir -p "$FW_DST"

for fw in bmg_guc_70.bin bmg_huc.bin; do
  if [[ ! -f "$FW_SRC/$fw" ]]; then
    die "$fw not found in linux-firmware repository"
  fi

  info "Installing $fw"
  sudo cp -f "$FW_SRC/$fw" "$FW_DST/"
done

info "Firmware installed"

if lsmod | grep -q '^xe '; then
  log "Attempting xe reload..."

  if sudo modprobe -r xe 2>/dev/null; then
    sudo modprobe xe
    info "xe driver reloaded"
  else
    warn "Unable to unload xe driver. A reboot is required."
    exit 0
  fi
else
  log "Loading xe driver"
  sudo modprobe xe
fi

sleep 3

log "DRM devices"
ls -l /dev/dri || true

log "xe status"
dmesg | tail -100 | grep -i xe || true

warn "If renderD128 is still missing, reboot the VM."

# ── Verify xe driver and device nodes ────────────────────────────────────────

log "Verifying xe driver..."

if lspci -nnk | grep -A5 "Intel Corporation Battlemage" | grep -q "Kernel driver in use: xe"; then
    info "xe driver is bound to the Battlemage GPU."
else
    warn "xe driver is not currently bound to the Battlemage GPU. A reboot may be required."
fi

if [ -e /dev/dri/renderD128 ]; then
    info "Found render node: /dev/dri/renderD128"
else
    warn "/dev/dri/renderD128 was not found. OpenCL, Level Zero, and SYCL will not function until the render node exists."
fi

# ── Add current user to required groups ──────────────────────────────────────

log "Ensuring user has GPU access permissions..."

CURRENT_USER="${SUDO_USER:-$USER}"

for grp in render video; do
    if id -nG "$CURRENT_USER" | grep -qw "$grp"; then
        info "$CURRENT_USER is already a member of '$grp'"
    else
        sudo usermod -aG "$grp" "$CURRENT_USER"
        info "Added $CURRENT_USER to '$grp'"
    fi
done

echo ""
echo "NOTE:"
echo "  Group membership changes do not take effect until the next login."
echo "  Either log out and back in, or reboot."
echo ""
echo "  Verify afterwards with:"
echo "    groups"
echo "    ls -l /dev/dri"
