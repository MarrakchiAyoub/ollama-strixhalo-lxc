#!/usr/bin/env bash
#
# 03-setup-ollama.sh
#
# Runs INSIDE the Ubuntu 24.04 LXC container (script 02 copies it in and
# runs it automatically; you can also re-run it manually inside the
# container later to re-apply the settings below).
#
# What it does:
#   1. Installs the ROCm userspace libraries (NOT the kernel driver -- the
#      Proxmox host already provides that) plus the Mesa Vulkan driver (RADV).
#   2. Matches container groups to the host GPU device GIDs so a non-root
#      process (Ollama's systemd service) can actually open the devices.
#   3. Installs Ollama via the official installer and configures it to use
#      the VULKAN backend, through systemd drop-ins:
#        00-base.conf   listen address, keep-alive        (rewritten by this script)
#        10-gpu.conf    Vulkan backend, flash attention off (rewritten by this script)
#        20-user.conf   context length, your own tweaks     (yours -- created once, never overwritten)
#
# Why Vulkan and not ROCm: on gfx1151 with Linux 6.17 (Proxmox VE 9.1), Ollama's
# ROCm backend corrupts long prompts -- short prompts are fine, but anything past
# a few thousand tokens (e.g. Open WebUI's hidden tool definitions) turns into word
# salad, on every model size tried, with flash attention on or off. The Vulkan
# backend gives correct output. AMD's docs want Linux >= 6.18.4 for gfx1151, so
# ROCm may work again after a host kernel upgrade.
#
# Trade-offs of Vulkan here: roughly 45% slower prompt processing than ROCm, and
# the GPU can address ~64 GiB instead of ~107 GiB.
#
# Env vars (optional, passed in automatically by script 02):
#   KFD_GID, RENDER_GID, RENDER_DEV
# If not set, this script will try to detect them from the already
# passed-through /dev/kfd and /dev/dri/renderD* nodes inside the container.
#   CONTEXT_LENGTH   default context for new installs (default 32768). Always set
#                    explicitly: left on auto, Ollama picks the model's full 131072
#                    for llama3.1, which does not fit and crashes the GPU driver.

set -uo pipefail  # not -e: the final backend check only warns

ROCM_VERSION="${ROCM_VERSION:-7.2}"      # ROCm release line to track; bump if AMD has shipped newer
CONTEXT_LENGTH="${CONTEXT_LENGTH:-32768}"
DROPIN_DIR=/etc/systemd/system/ollama.service.d

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root inside the container." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 0. Figure out device GIDs if not passed in
# ---------------------------------------------------------------------------
if [[ -z "${RENDER_DEV:-}" ]]; then
  for dev in /dev/dri/renderD*; do
    [[ -e "${dev}" ]] && RENDER_DEV="${dev}" && break
  done
fi
if [[ -z "${RENDER_DEV:-}" || ! -e "${RENDER_DEV}" ]]; then
  echo "ERROR: no /dev/dri/renderD* device found inside the container." >&2
  echo "Make sure script 02's GPU passthrough (dev0/dev1 lines) actually took effect." >&2
  exit 1
fi
if [[ ! -e /dev/kfd ]]; then
  echo "ERROR: /dev/kfd not found inside the container." >&2
  exit 1
fi
KFD_GID="${KFD_GID:-$(stat -c '%g' /dev/kfd)}"
RENDER_GID="${RENDER_GID:-$(stat -c '%g' "${RENDER_DEV}")}"

echo "== Using /dev/kfd (gid ${KFD_GID}) and ${RENDER_DEV} (gid ${RENDER_GID}) =="

# ---------------------------------------------------------------------------
# 1. Base packages (incl. the Vulkan driver and vulkaninfo)
# ---------------------------------------------------------------------------
echo "== apt update/upgrade =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y wget curl gnupg ca-certificates lsb-release software-properties-common jq zstd \
  mesa-vulkan-drivers vulkan-tools

# ---------------------------------------------------------------------------
# 2. ROCm userspace (repo-based install, no kernel driver / no DKMS)
# ---------------------------------------------------------------------------
echo "== Installing ROCm ${ROCM_VERSION} userspace libraries =="
mkdir -p /etc/apt/keyrings
chmod 0755 /etc/apt/keyrings
wget -qO- https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg > /dev/null
CODENAME="$(lsb_release -cs)"
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} ${CODENAME} main" \
  | tee /etc/apt/sources.list.d/rocm.list > /dev/null
printf 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n' \
  | tee /etc/apt/preferences.d/rocm-pin-600 > /dev/null
apt-get update -y

# Only the userspace runtime + tools -- explicitly NOT amdgpu-dkms (that's a
# kernel driver package and would fight with the host's own amdgpu driver).
apt-get install -y rocminfo rocm-smi-lib rocm-hip-runtime hipblaslt rocblas || {
  echo "Some ROCm packages failed to install -- check 'apt-cache search rocm' for the" >&2
  echo "exact package names available for ROCm ${ROCM_VERSION} on ${CODENAME} and adjust." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 3. Match groups to host device GIDs
# ---------------------------------------------------------------------------
echo "== Matching container groups to host device GIDs =="

find_or_make_group() {
  local gid="$1" want_name="$2"
  local existing
  existing="$(getent group | awk -F: -v g="${gid}" '$3==g{print $1; exit}')"
  if [[ -n "${existing}" ]]; then
    echo "${existing}"
  else
    groupadd -g "${gid}" "${want_name}" >/dev/null
    echo "${want_name}"
  fi
}

KFD_GROUP="$(find_or_make_group "${KFD_GID}" hostkfd)"
RENDER_GROUP="$(find_or_make_group "${RENDER_GID}" hostrender)"
echo "kfd gid ${KFD_GID} -> group '${KFD_GROUP}'"
echo "render gid ${RENDER_GID} -> group '${RENDER_GROUP}'"

# ---------------------------------------------------------------------------
# 4. Install Ollama + its systemd drop-ins
# ---------------------------------------------------------------------------
echo "== Installing Ollama =="
curl -fsSL https://ollama.com/install.sh | sh

if ! id ollama >/dev/null 2>&1 || ! systemctl list-unit-files ollama.service >/dev/null 2>&1; then
  echo "ERROR: the Ollama installer didn't finish successfully -- no 'ollama' user and/or" >&2
  echo "no ollama.service unit was created. Scroll up for the installer's own error." >&2
  exit 1
fi

# Ollama's installer creates a system user "ollama" that runs the service.
usermod -aG "${KFD_GROUP},${RENDER_GROUP}" ollama

mkdir -p "${DROPIN_DIR}"

# Older versions of these scripts wrote everything into override.conf, including
# a forced flash attention and a benchmarked HSA override. It sorts AFTER the
# files below, so left in place it would silently override them. Move it aside
# (the new name doesn't end in .conf, so systemd ignores it).
if [[ -f "${DROPIN_DIR}/override.conf" ]]; then
  backup="${DROPIN_DIR}/override.conf.bak-$(date +%s)"
  mv "${DROPIN_DIR}/override.conf" "${backup}"
  echo "Moved the old ${DROPIN_DIR}/override.conf to ${backup}"
fi

cat > "${DROPIN_DIR}/00-base.conf" <<'EOF'
# Managed by 03-setup-ollama.sh (rewritten on every run). Put your own settings in 20-user.conf.
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=10m"
EOF

cat > "${DROPIN_DIR}/10-gpu.conf" <<'EOF'
# Managed by 03-setup-ollama.sh (rewritten on every run). Put your own settings in 20-user.conf.
# Vulkan backend: the ROCm backend produces garbled output on long prompts on gfx1151.
# OLLAMA_IGPU_ENABLE: without it Ollama ignores the iGPU and silently runs on CPU.
# Flash attention off: untested with Vulkan here, and unstable on gfx1151 in general.
[Service]
Environment="OLLAMA_LLM_LIBRARY=vulkan"
Environment="OLLAMA_IGPU_ENABLE=1"
Environment="OLLAMA_FLASH_ATTENTION=0"
EOF

if [[ ! -f "${DROPIN_DIR}/20-user.conf" ]]; then
  cat > "${DROPIN_DIR}/20-user.conf" <<EOF
# Your own Ollama settings. 03-setup-ollama.sh and ollama-update never overwrite this file.
# Always set a context length: on auto, Ollama picks 131072 for llama3.1, which does not
# fit in the GPU's ~64 GiB and crashes the driver. Raise it only if the model + KV cache fit.
[Service]
Environment="OLLAMA_CONTEXT_LENGTH=${CONTEXT_LENGTH}"
EOF
  echo "Created ${DROPIN_DIR}/20-user.conf (context length ${CONTEXT_LENGTH}) -- edit it to taste."
fi

wait_for_ollama() {
  local i
  for i in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

systemctl daemon-reload
systemctl enable ollama >/dev/null 2>&1 || true
systemctl restart ollama
if ! wait_for_ollama; then
  echo "ERROR: Ollama service didn't come up. Check: journalctl -u ollama -n 100 --no-pager" >&2
  exit 1
fi

echo "== Checking the Vulkan backend =="
if ! vulkaninfo --summary 2>/dev/null | grep -qi "radv"; then
  echo "WARNING: vulkaninfo doesn't list a RADV (Mesa AMD) device. Ollama will fall back to CPU." >&2
  echo "Check: vulkaninfo --summary   and that the ollama user is in the render group." >&2
fi
BACKEND_LINE="$(journalctl -u ollama --since '-2min' --no-pager 2>/dev/null | grep 'inference compute' | tail -n1)"
if [[ "${BACKEND_LINE}" == *"library=Vulkan"* ]]; then
  echo "Ollama is using the Vulkan GPU backend."
else
  echo "WARNING: couldn't confirm library=Vulkan in the Ollama journal. Check:" >&2
  echo "  journalctl -u ollama --no-pager | grep 'inference compute'" >&2
  echo "  (last line seen: ${BACKEND_LINE:-none})" >&2
fi

# ---------------------------------------------------------------------------
# 5. Install the "ollama-update" command
# ---------------------------------------------------------------------------
# 04-update-ollama.sh checks for a newer Ollama release and installs it. It's
# copied in by script 02 right alongside this one.
if [[ -f /root/04-update-ollama.sh ]]; then
  install -m 0755 /root/04-update-ollama.sh /usr/local/bin/ollama-update
  echo "Installed update command: ollama-update"
else
  echo "NOTE: /root/04-update-ollama.sh wasn't found, so the 'ollama-update' command" >&2
  echo "wasn't installed. Copy it in and install manually if you want it:" >&2
  echo "  pct push <CTID> ./04-update-ollama.sh /usr/local/bin/ollama-update" >&2
  echo "  pct exec <CTID> -- chmod +x /usr/local/bin/ollama-update" >&2
fi

echo
echo "== Setup complete =="
echo "Settings files in ${DROPIN_DIR}/:"
for f in "${DROPIN_DIR}"/*.conf; do
  echo "--- $(basename "${f}") ---"
  cat "${f}"
done
echo
echo "Try it:                  ollama run llama3.2:3b \"tell me a fact about the ocean\""
echo "Check GPU offload with:  ollama ps"
echo "Update Ollama with:      ollama-update"
echo "  (or from the host: ./02-create-gpu-lxc.sh update <CTID>)"
