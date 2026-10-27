#!/usr/bin/env bash
#
# 02-create-gpu-lxc.sh
#
# Run this ON THE PROXMOX HOST as root. It copies 03/04/05 into the container:
# from the files next to it if they exist (a git checkout), otherwise it
# downloads them from the repo's main branch on raw.githubusercontent.com.
#
# Creates an unprivileged Ubuntu 24.04 LXC container, passes through the
# AMD iGPU's /dev/kfd (ROCm compute) and /dev/dri/renderDxxx (DRM render)
# device nodes, starts it, then copies in and runs 03-setup-ollama.sh to
# install ROCm + Ollama and tune it for gfx1151.
#
# Run 01-host-memory-tuning.sh (and reboot) FIRST if you want the GPU to be
# able to use more than your BIOS's default small VRAM/UMA carve-out.
#
# Usage:
#   ./02-create-gpu-lxc.sh                    Create a new container (default)
#   ./02-create-gpu-lxc.sh create             Same as above
#   ./02-create-gpu-lxc.sh update [CTID]      Update an existing container: first copies the
#                                              latest 04/05 helper scripts from this repo into
#                                              it, then checks for a newer Ollama release and
#                                              re-runs the GPU tuning. CTID defaults to the
#                                              CTID variable below (900).
#   ./02-create-gpu-lxc.sh update [CTID] --force          re-tune even if already up to date
#   ./02-create-gpu-lxc.sh update [CTID] --skip-benchmark update the binary only, skip re-tuning
#
# Optional environment for tuning (create and update):
#   BENCH_MODEL=llama3.1:70b   test GPU settings with the model you actually use (slower, but
#                              the only test that proves YOUR model produces correct output)
#   WITH_FLASH_ATTN=1          also test flash attention (off by default: unstable on gfx1151)
#
# The update/tune logic lives inside the container as /usr/local/bin/ollama-update
# and /usr/local/bin/ollama-tune -- you can also run those directly:
#   pct exec <CTID> -- ollama-update [--force|--skip-benchmark]
#   pct exec <CTID> -- ollama-tune [--model NAME] [--with-flash-attn]

set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/MarrakchiAyoub/ollama-strixhalo-lxc/main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# fetch_script NAME DEST: copy NAME from next to this script, else download it from GitHub.
fetch_script() {
  local name="$1" dest="$2"
  if [[ -f "${SCRIPT_DIR}/${name}" ]]; then
    cp "${SCRIPT_DIR}/${name}" "${dest}"
    return 0
  fi
  echo "  ${name} not found locally, downloading from ${RAW_BASE}/${name} ..."
  curl -fsSL "${RAW_BASE}/${name}" -o "${dest}"
}

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

  # Keep the helper commands inside the container in sync with this repo
  # (also migrates containers built from an older version of these scripts).
  echo "== Syncing helper scripts into container ${UPDATE_CTID} =="
  for pair in "04-update-ollama.sh:ollama-update" "05-tune-ollama.sh:ollama-tune"; do
    name="${pair%%:*}"
    src="${WORK_DIR}/${name}"
    dst="/usr/local/bin/${pair##*:}"
    if fetch_script "${name}" "${src}"; then
      pct push "${UPDATE_CTID}" "${src}" "${dst}"
      pct exec "${UPDATE_CTID}" -- chmod 0755 "${dst}"
      echo "  installed ${dst}"
    else
      echo "  WARNING: couldn't get ${name} (not next to this script, download failed); leaving the copy inside the container as-is" >&2
    fi
  done

  echo "== Checking for an Ollama update in container ${UPDATE_CTID} =="
  pct exec "${UPDATE_CTID}" -- env BENCH_MODEL="${BENCH_MODEL:-}" WITH_FLASH_ATTN="${WITH_FLASH_ATTN:-0}" \
    ollama-update "$@"
  exit $?
elif [[ "${MODE}" != "create" ]]; then
  echo "Usage: $0 [create|update [CTID] [--force|--skip-benchmark]]" >&2
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
for _ in $(seq 1 30); do
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

echo "== Fetching and copying in the Ollama/ROCm setup + helper scripts =="
for f in 03-setup-ollama.sh 04-update-ollama.sh 05-tune-ollama.sh; do
  if ! fetch_script "${f}" "${WORK_DIR}/${f}"; then
    echo "ERROR: couldn't get ${f} (not next to this script, and download from ${RAW_BASE}/${f} failed)." >&2
    exit 1
  fi
  pct push "${CTID}" "${WORK_DIR}/${f}" "/root/${f}"
done
pct exec "${CTID}" -- chmod +x /root/03-setup-ollama.sh /root/04-update-ollama.sh /root/05-tune-ollama.sh

echo "== Running setup inside the container (installs ROCm + Ollama and tunes it -- can take 10-20+ minutes) =="
pct exec "${CTID}" -- env KFD_GID="${KFD_GID}" RENDER_GID="${RENDER_GID}" RENDER_DEV="${RENDER_DEV}" \
  BENCH_MODEL="${BENCH_MODEL:-}" WITH_FLASH_ATTN="${WITH_FLASH_ATTN:-0}" \
  bash /root/03-setup-ollama.sh

echo
echo "== Done =="
CT_IP="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')"
echo "Container ${CTID} (${HOSTNAME}) is up at ${CT_IP:-<check pct exec ${CTID} -- hostname -I>}"
echo "Ollama API: http://${CT_IP:-<ct-ip>}:11434"
echo "Quick test: pct exec ${CTID} -- ollama run llama3.2:3b \"hello\""
echo "Check for Ollama updates later with: ./02-create-gpu-lxc.sh update ${CTID}"
echo "  (or directly: pct exec ${CTID} -- ollama-update)"
