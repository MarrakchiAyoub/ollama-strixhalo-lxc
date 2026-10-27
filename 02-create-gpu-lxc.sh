#!/usr/bin/env bash
#
# 02-create-gpu-lxc.sh
#
# Run this ON THE PROXMOX HOST as root.
#
# Creates an unprivileged Ubuntu 24.04 LXC container, passes through the
# AMD iGPU's /dev/kfd (ROCm compute) and /dev/dri/renderDxxx (DRM render)
# device nodes, starts it, then copies in and runs 03-setup-ollama.sh to
# install Ollama and configure it to use the Vulkan GPU backend (ROCm
# corrupts long prompts on gfx1151 -- see 03-setup-ollama.sh).
#
# Run 01-host-memory-tuning.sh (and reboot) FIRST if you want the GPU to be
# able to use more than your BIOS's default small VRAM/UMA carve-out.
#
# Usage:
#   ./02-create-gpu-lxc.sh                    Create a new container (default)
#   ./02-create-gpu-lxc.sh create             Same as above
#   ./02-create-gpu-lxc.sh update [CTID]      Check for a newer Ollama release
#                                              inside an existing container
#                                              created by this script, and
#                                              install it if there is one. CTID
#                                              defaults to the CTID variable
#                                              below (900).
#   ./02-create-gpu-lxc.sh update [CTID] --force          reinstall even if
#                                                          already up to date
#
# The actual update logic lives inside the container as /usr/local/bin/
# ollama-update (installed by 03-setup-ollama.sh) -- this "update" mode is
# just a convenience wrapper so you don't have to remember the pct exec
# command. You can always run it directly instead:
#   pct exec <CTID> -- ollama-update [--force]

set -euo pipefail

MODE="${1:-create}"
if [[ "${MODE}" == "update" ]]; then
  UPDATE_CTID="${2:-${CTID:-900}}"
  shift $(( $# >= 2 ? 2 : $# ))
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root on the Proxmox host." >&2
    exit 1
  fi
  if ! pct status "${UPDATE_CTID}" >/dev/null 2>&1; then
    echo "ERROR: no container ${UPDATE_CTID} found." >&2
    exit 1
  fi
  if [[ "$(pct status "${UPDATE_CTID}")" != "status: running" ]]; then
    echo "Container ${UPDATE_CTID} isn't running, starting it..."
    pct start "${UPDATE_CTID}"
    sleep 5
  fi
  if ! pct exec "${UPDATE_CTID}" -- command -v ollama-update >/dev/null 2>&1; then
    echo "ERROR: /usr/local/bin/ollama-update isn't present in container ${UPDATE_CTID}." >&2
    echo "That's installed by 03-setup-ollama.sh -- if this container predates it," >&2
    echo "copy 04-update-ollama.sh in and install it manually:" >&2
    echo "  pct push ${UPDATE_CTID} ./04-update-ollama.sh /usr/local/bin/ollama-update" >&2
    echo "  pct exec ${UPDATE_CTID} -- chmod +x /usr/local/bin/ollama-update" >&2
    exit 1
  fi
  echo "== Checking for an Ollama update in container ${UPDATE_CTID} =="
  pct exec "${UPDATE_CTID}" -- ollama-update "$@"
  exit $?
elif [[ "${MODE}" != "create" ]]; then
  echo "Usage: $0 [create|update [CTID] [--force]]" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Config -- edit to taste before running
# ---------------------------------------------------------------------------

CTID="${CTID:-900}"
HOSTNAME="${HOSTNAME:-ollama-gpu}"
DISK_SIZE_GB="${DISK_SIZE_GB:-64}"          # ROCm + ollama + a handful of models
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
IPCONFIG="${IPCONFIG:-ip=dhcp}"             # or e.g. "ip=192.168.1.50/24,gw=192.168.1.1"

# Cores: default to all host cores. Override with e.g. CORES=16.
CORES="${CORES:-$(nproc)}"

# Memory: default to (total host RAM - 16GiB reserved for Proxmox itself),
# capped so we don't try to hand the container more RAM than exists.
# Override with e.g. MEMORY_GB=96.
TOTAL_HOST_RAM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
DEFAULT_MEMORY_GB=$(( TOTAL_HOST_RAM_GB - 16 ))
if (( DEFAULT_MEMORY_GB < 8 )); then DEFAULT_MEMORY_GB=8; fi
MEMORY_GB="${MEMORY_GB:-${DEFAULT_MEMORY_GB}}"
SWAP_GB="${SWAP_GB:-4}"

# Ubuntu 24.04 is the best-tested distro for AMD's ROCm apt repo right now.
TEMPLATE_PATTERN="ubuntu-24.04-standard"

# ---------------------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root on the Proxmox host." >&2
  exit 1
fi
if ! command -v pct >/dev/null 2>&1; then
  echo "This doesn't look like a Proxmox host (no 'pct' command). Aborting." >&2
  exit 1
fi

echo "== Sanity checks =="
for storage_var in TEMPLATE_STORAGE ROOTFS_STORAGE; do
  storage_id="${!storage_var}"
  if ! pvesm status -storage "${storage_id}" >/dev/null 2>&1; then
    echo "ERROR: storage '${storage_id}' (from \$${storage_var}) does not exist on this host." >&2
    echo "Available storage:" >&2
    pvesm status >&2 || true
    echo "Set ${storage_var} to one of the names above, e.g.:" >&2
    echo "  ${storage_var}=<name> ./02-create-gpu-lxc.sh" >&2
    exit 1
  fi
done
if [[ ! -e /dev/kfd ]]; then
  echo "ERROR: /dev/kfd not found on the HOST. The amdgpu kernel driver with" >&2
  echo "KFD (compute) support doesn't seem to be active. Check 'lsmod | grep amdgpu'" >&2
  echo "and 'dmesg | grep -i kfd'. Note: the Proxmox HOST only needs the in-kernel" >&2
  echo "amdgpu driver -- do NOT install the full ROCm userspace stack on the host" >&2
  echo "itself, that goes inside the container (script 03 does it)." >&2
  exit 1
fi
if [[ ! -d /dev/dri ]]; then
  echo "ERROR: /dev/dri not found on the HOST. GPU driver not initialized." >&2
  exit 1
fi

echo "== Detecting the AMD render device =="
RENDER_DEV=""
for dev in /dev/dri/renderD*; do
  [[ -e "${dev}" ]] || continue
  name="$(basename "${dev}")"
  driver_link="/sys/class/drm/${name}/device/driver"
  if [[ -e "${driver_link}" ]]; then
    driver="$(basename "$(readlink -f "${driver_link}")")"
    if [[ "${driver}" == "amdgpu" ]]; then
      RENDER_DEV="${dev}"
      break
    fi
  fi
done

if [[ -z "${RENDER_DEV}" ]]; then
  echo "ERROR: Couldn't find an amdgpu-owned /dev/dri/renderD* device. Is another" >&2
  echo "GPU driver claiming it, or is this not the right host?" >&2
  ls -l /dev/dri/ >&2 || true
  exit 1
fi

KFD_GID="$(stat -c '%g' /dev/kfd)"
RENDER_GID="$(stat -c '%g' "${RENDER_DEV}")"

echo "Found render device: ${RENDER_DEV} (gid ${RENDER_GID})"
echo "Found /dev/kfd (gid ${KFD_GID})"
echo

echo "== Container plan =="
echo "  CTID:        ${CTID}"
echo "  Hostname:    ${HOSTNAME}"
echo "  Cores:       ${CORES}"
echo "  Memory:      ${MEMORY_GB} GiB (swap ${SWAP_GB} GiB)  [host has ${TOTAL_HOST_RAM_GB} GiB total]"
echo "  Disk:        ${DISK_SIZE_GB} GiB on ${ROOTFS_STORAGE}"
echo "  Network:     ${BRIDGE}, ${IPCONFIG}"
echo "  Passthrough: /dev/kfd (gid ${KFD_GID}), ${RENDER_DEV} (gid ${RENDER_GID})"
echo
read -r -p "Proceed? [y/N] " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

if pct status "${CTID}" >/dev/null 2>&1; then
  echo "ERROR: CT ${CTID} already exists. Pick a different CTID or remove it first." >&2
  exit 1
fi

echo "== Making sure the Ubuntu 24.04 template is available =="
pveam update >/dev/null 2>&1 || true
TEMPLATE_FILE="$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep "^${TEMPLATE_PATTERN}" | sort -V | tail -n1)"
if [[ -z "${TEMPLATE_FILE}" ]]; then
  echo "ERROR: Couldn't find a '${TEMPLATE_PATTERN}' template via 'pveam available'." >&2
  echo "Run 'pveam update && pveam available' and adjust TEMPLATE_PATTERN." >&2
  exit 1
fi
if [[ ! -e "/var/lib/vz/template/cache/${TEMPLATE_FILE}" ]]; then
  echo "Downloading ${TEMPLATE_FILE} ..."
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE_FILE}"
fi

echo "== Creating LXC ${CTID} =="
pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" \
  --memory $(( MEMORY_GB * 1024 )) \
  --swap $(( SWAP_GB * 1024 )) \
  --rootfs "${ROOTFS_STORAGE}:${DISK_SIZE_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},firewall=1,${IPCONFIG}" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1

echo "== Wiring up GPU passthrough in /etc/pve/lxc/${CTID}.conf =="
{
  echo "dev0: /dev/kfd,gid=${KFD_GID}"
  echo "dev1: ${RENDER_DEV},gid=${RENDER_GID}"
} >> "/etc/pve/lxc/${CTID}.conf"

echo "== Starting container =="
pct start "${CTID}"

echo "Waiting for network..."
for i in $(seq 1 30); do
  if pct exec "${CTID}" -- getent hosts ollama.com >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "== Verifying device nodes are visible inside the container =="
pct exec "${CTID}" -- bash -c 'ls -l /dev/kfd /dev/dri/' || {
  echo "ERROR: device nodes not visible inside the container. Check /etc/pve/lxc/${CTID}.conf" >&2
  exit 1
}

RAW_BASE="https://raw.githubusercontent.com/MarrakchiAyoub/ollama-strixhalo-lxc/main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

fetch_script() {
  local name="$1" dest="$2"
  if [[ -f "${SCRIPT_DIR}/${name}" ]]; then
    cp "${SCRIPT_DIR}/${name}" "${dest}"
    return
  fi
  echo "  ${name} not found locally, downloading from ${RAW_BASE}/${name} ..."
  if ! curl -fsSL "${RAW_BASE}/${name}" -o "${dest}"; then
    echo "ERROR: failed to download ${name} from ${RAW_BASE}/${name}" >&2
    exit 1
  fi
}

echo "== Fetching the Ollama/ROCm setup + update scripts =="
fetch_script "03-setup-ollama.sh" "${WORK_DIR}/03-setup-ollama.sh"
fetch_script "04-update-ollama.sh" "${WORK_DIR}/04-update-ollama.sh"

echo "== Copying them into the container =="
pct push "${CTID}" "${WORK_DIR}/03-setup-ollama.sh" /root/03-setup-ollama.sh
pct push "${CTID}" "${WORK_DIR}/04-update-ollama.sh" /root/04-update-ollama.sh
pct exec "${CTID}" -- chmod +x /root/03-setup-ollama.sh /root/04-update-ollama.sh

echo "== Running setup inside the container (installs the GPU userspace libs + Ollama -- can take 10+ minutes) =="
pct exec "${CTID}" -- env KFD_GID="${KFD_GID}" RENDER_GID="${RENDER_GID}" RENDER_DEV="${RENDER_DEV}" \
  bash /root/03-setup-ollama.sh

echo
echo "== Done =="
CT_IP="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')"
echo "Container ${CTID} (${HOSTNAME}) is up at ${CT_IP:-<check pct exec ${CTID} -- hostname -I>}"
echo "Ollama API: http://${CT_IP:-<ct-ip>}:11434"
echo "Quick test: pct exec ${CTID} -- ollama run llama3.2:1b \"hello\""
echo "Check for Ollama updates later with: ./02-create-gpu-lxc.sh update ${CTID}"
echo "  (or directly: pct exec ${CTID} -- ollama-update)"
