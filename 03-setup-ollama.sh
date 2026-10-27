#!/usr/bin/env bash
#
# 03-setup-ollama.sh
#
# Runs INSIDE the Ubuntu 24.04 LXC container (script 02 copies it in and
# runs it automatically; you can also re-run it manually inside the
# container later).
#
# What it does:
#   1. Installs ROCm userspace libraries (NOT the kernel driver -- the
#      Proxmox host already provides that; the container just needs the
#      userspace runtime that talks to /dev/kfd and /dev/dri).
#   2. Matches container groups to the host GPU device GIDs so a non-root
#      process (Ollama's systemd service) can actually open the devices.
#   3. Installs Ollama via the official installer, with its settings split
#      into systemd drop-ins:
#        00-base.conf        listen address, keep-alive     (managed here)
#        10-gpu-tuning.conf  HSA override + flash attention (managed by ollama-tune)
#        20-user.conf        context length, your own tweaks (yours -- never overwritten)
#   4. Installs the helper commands  ollama-tune (script 05)  and
#      ollama-update (script 04), then runs ollama-tune, which tests GPU
#      settings for CORRECT output (short + long prompt) and pins the fastest
#      one that passes.
#
# Env vars (optional, passed in automatically by script 02):
#   KFD_GID, RENDER_GID, RENDER_DEV, BENCH_MODEL, WITH_FLASH_ATTN
# If the GIDs aren't set, this script detects them from the already
# passed-through /dev/kfd and /dev/dri/renderD* nodes inside the container.

set -uo pipefail  # not -e: a failing tuning run shouldn't abort the rest of the setup

ROCM_VERSION="${ROCM_VERSION:-7.2}"      # ROCm release line to track; bump if AMD has shipped newer

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root inside the container." >&2
  exit 1
fi

for f in 04-update-ollama.sh 05-tune-ollama.sh; do
  if [[ ! -f "/root/${f}" ]]; then
    echo "ERROR: /root/${f} not found. Script 02 copies it in; if you're running 03 by hand, copy it there first." >&2
    exit 1
  fi
done

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
# 1. Base packages
# ---------------------------------------------------------------------------
echo "== apt update/upgrade =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y wget curl gnupg ca-certificates lsb-release software-properties-common jq zstd

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

mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/00-base.conf <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=10m"
EOF
# 10-gpu-tuning.conf is written by ollama-tune; 20-user.conf is created by it
# on first run (context length) and is never overwritten afterwards.

# ---------------------------------------------------------------------------
# 5. Install the helper commands, then tune
# ---------------------------------------------------------------------------
install -m 0755 /root/05-tune-ollama.sh /usr/local/bin/ollama-tune
install -m 0755 /root/04-update-ollama.sh /usr/local/bin/ollama-update
echo "Installed commands: ollama-tune, ollama-update"

systemctl daemon-reload
systemctl enable ollama >/dev/null 2>&1 || true
systemctl restart ollama

echo
echo "== Tuning GPU settings (this loads a test model several times; allow a few minutes) =="
ollama-tune
TUNE_RC=$?

echo
echo "== Setup complete =="
echo "Settings files in /etc/systemd/system/ollama.service.d/:"
for f in /etc/systemd/system/ollama.service.d/*.conf; do
  echo "--- $(basename "${f}") ---"
  cat "${f}"
done
echo
echo "Check GPU offload any time with:    ollama ps"
echo "Re-verify GPU settings with:        ollama-tune   (add --model <your-model> to test the model you actually use)"
echo "Check for a newer Ollama with:      ollama-update"
echo "  (or from the host: ./02-create-gpu-lxc.sh update <CTID>)"
if [[ "${TUNE_RC}" -ne 0 ]]; then
  echo
  echo "NOTE: ollama-tune found no configuration that produced correct output -- see its warning above." >&2
fi
exit "${TUNE_RC}"
