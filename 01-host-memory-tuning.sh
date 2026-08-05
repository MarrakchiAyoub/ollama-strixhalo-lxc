#!/usr/bin/env bash
#
# 01-host-memory-tuning.sh
#
# Run this ON THE PROXMOX HOST as root, BEFORE creating the LXC container.
#
# What it does:
#   1. Checks the running kernel version against what's known to work well
#      for Strix Halo (gfx1151) and tells you if a newer opt-in PVE kernel
#      is worth installing.
#   2. Raises the host's GTT/TTM memory pool so the iGPU can address more
#      of your system RAM as "VRAM" (unified memory). This replaces the
#      deprecated amdgpu.gttsize parameter.
#   3. Optionally sets amd_iommu=on iommu=pt (recommended for UMA APU
#      performance).
#
# This script EDITS YOUR BOOTLOADER CONFIG and requires a REBOOT to take
# effect. It does not reboot for you. It backs up whatever it touches
# before changing it. Read it before running it.
#
# Safe to skip entirely if you'd rather rely on a fixed BIOS VRAM/UMA split
# instead of dynamic GTT sizing -- but then your usable "VRAM" is capped at
# whatever your BIOS carve-out is.

set -euo pipefail

# ---------------------------------------------------------------------------
# Config -- edit to taste
# ---------------------------------------------------------------------------

# How much system RAM (in GiB) the GPU should be ALLOWED to map as GTT/VRAM.
# This is a ceiling, not a reservation -- unused RAM stays available to
# everything else. Leave meaningful headroom for Proxmox + other guests.
# Community reports put the practical max around ~105-108GiB on a 128GiB
# board before things get unstable; adjust for your installed RAM.
GPU_GTT_GIB="${GPU_GTT_GIB:-96}"

# Whether to add amd_iommu=on iommu=pt to the kernel cmdline. Recommended
# for APUs with unified memory; leave "yes" unless you have a specific
# reason not to (e.g. you're already passing through other PCIe devices
# with different IOMMU needs).
SET_IOMMU_PT="${SET_IOMMU_PT:-yes}"

# ---------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root on the Proxmox host." >&2
  exit 1
fi

if ! command -v pveversion >/dev/null 2>&1; then
  echo "This doesn't look like a Proxmox host (no 'pveversion' command). Aborting." >&2
  exit 1
fi

echo "== Kernel check =="
CURRENT_KERNEL="$(uname -r)"
echo "Running kernel: ${CURRENT_KERNEL}"
echo "AMD's ROCm docs want Linux >=6.18.4 for fully stable gfx1151 KFD behavior."
echo "Proxmox VE 9.1+ ships 6.17 by default; newer opt-in kernels (e.g. 6.19, 7.0)"
echo "have shown better Strix Halo results in community testing."
echo
echo "Kernels currently installed on this host:"
dpkg -l 'pve-kernel-*' 2>/dev/null | awk '/^ii/{print "  - "$2" "$3}' || true
echo
echo "To see what newer opt-in kernel is available:"
echo "    apt update && apt list --all-versions 'pve-kernel-*' 2>/dev/null | grep -v installed"
echo "To install and boot a newer one (example, check the actual available version first):"
echo "    apt install pve-kernel-6.19"
echo "    proxmox-boot-tool kernel pin 6.19.x-pve   # or whatever version got installed"
echo "    proxmox-boot-tool refresh"
echo "    reboot"
echo "This script does NOT install a new kernel automatically -- do that by hand if you"
echo "want a newer one, since the exact available version/package name changes over time."
echo

# ---------------------------------------------------------------------------
# GTT / TTM memory pool
# ---------------------------------------------------------------------------

# pages_limit is in 4KiB pages. 1 GiB = 1024^3 bytes / 4096 bytes-per-page
# = 262144 pages.
PAGES_PER_GIB=262144
PAGES_LIMIT=$(( GPU_GTT_GIB * PAGES_PER_GIB ))

echo "== GTT/TTM sizing =="
echo "Requesting a GPU-addressable pool of ${GPU_GTT_GIB} GiB => ttm.pages_limit=${PAGES_LIMIT}"
echo

CURRENT_CMDLINE=""
CMDLINE_FILE=""
USE_SYSTEMD_BOOT=0

if [[ -f /etc/kernel/cmdline ]]; then
  USE_SYSTEMD_BOOT=1
  CMDLINE_FILE="/etc/kernel/cmdline"
  CURRENT_CMDLINE="$(cat "${CMDLINE_FILE}")"
elif [[ -f /etc/default/grub ]]; then
  CMDLINE_FILE="/etc/default/grub"
  CURRENT_CMDLINE="$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/' || true)"
else
  echo "Couldn't find /etc/kernel/cmdline or /etc/default/grub -- unsure how this host boots." >&2
  echo "Add these kernel parameters manually: ttm.pages_limit=${PAGES_LIMIT} amdttm.pages_limit=${PAGES_LIMIT}" >&2
  exit 1
fi

# Build the set of params we want present.
declare -a WANT_PARAMS=(
  "ttm.pages_limit=${PAGES_LIMIT}"
  "amdttm.pages_limit=${PAGES_LIMIT}"
  "amdttm.page_pool_size=${PAGES_LIMIT}"
)
if [[ "${SET_IOMMU_PT}" == "yes" ]]; then
  WANT_PARAMS+=("amd_iommu=on" "iommu=pt")
fi

NEW_CMDLINE="${CURRENT_CMDLINE}"
for p in "${WANT_PARAMS[@]}"; do
  key="${p%%=*}"
  # Strip any existing occurrence of this key (with or without value) then re-add.
  NEW_CMDLINE="$(echo "${NEW_CMDLINE}" | sed -E "s/(^| )${key}(=[^ ]*)?( |$)/ /g")"
  NEW_CMDLINE="${NEW_CMDLINE} ${p}"
done
# Collapse repeated spaces, trim.
NEW_CMDLINE="$(echo "${NEW_CMDLINE}" | tr -s ' ' | sed -E 's/^ +| +$//g')"

echo "Current cmdline: ${CURRENT_CMDLINE}"
echo "New cmdline:     ${NEW_CMDLINE}"
echo
read -r -p "Apply this and update the bootloader now? [y/N] " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Aborted, no changes made."
  exit 0
fi

TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"
cp -a "${CMDLINE_FILE}" "${CMDLINE_FILE}.bak.${TS}"
echo "Backed up ${CMDLINE_FILE} to ${CMDLINE_FILE}.bak.${TS}"

if [[ "${USE_SYSTEMD_BOOT}" -eq 1 ]]; then
  echo "${NEW_CMDLINE}" > "${CMDLINE_FILE}"
  proxmox-boot-tool refresh
else
  sed -i.bak-orig -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"|" /etc/default/grub
  update-grub
fi

echo
echo "Done. Reboot the host when convenient for this to take effect:"
echo "    reboot"
echo
echo "After reboot, verify with:"
echo "    cat /proc/cmdline"
echo "    cat /sys/module/ttm/parameters/pages_limit"
