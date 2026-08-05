#!/usr/bin/env bash
#
# 03-setup-ollama.sh
#
# Runs INSIDE the Ubuntu 24.04 LXC container (script 02 copies it in and
# runs it automatically; you can also re-run it manually inside the
# container later, e.g. after an Ollama/ROCm update, to re-tune it).
#
# What it does:
#   1. Installs ROCm userspace libraries (NOT the kernel driver -- the
#      Proxmox host already provides that; the container just needs the
#      userspace runtime that talks to /dev/kfd and /dev/dri).
#   2. Matches container groups to the host GPU device GIDs so a non-root
#      process (Ollama's systemd service) can actually open the devices.
#   3. Installs Ollama via the official installer.
#   4. Benchmarks a small model under a few HSA_OVERRIDE_GFX_VERSION
#      candidates (gfx1151 has no single stable "correct" override right
#      now -- the fastest option, confirmed to actually run on GPU, wins)
#      and pins whichever one wins.
#
# Env vars (optional, passed in automatically by script 02):
#   KFD_GID, RENDER_GID, RENDER_DEV
# If not set, this script will try to detect them from the already
# passed-through /dev/kfd and /dev/dri/renderD* nodes inside the container.

set -uo pipefail  # not -e: benchmark trials are allowed to fail without killing the script

ROCM_VERSION="${ROCM_VERSION:-7.2}"      # ROCm release line to track; bump if AMD has shipped newer
BENCH_MODEL="${BENCH_MODEL:-llama3.2:1b}"
BENCH_PROMPT="Write one short sentence about the ocean."
HSA_CANDIDATES=("native" "11.0.0" "11.5.1")   # "native" = no override at all

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
# 4. Install Ollama
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

write_override() {
  local hsa_value="$1"
  local env_line=""
  if [[ "${hsa_value}" != "native" ]]; then
    env_line="Environment=\"HSA_OVERRIDE_GFX_VERSION=${hsa_value}\""
  fi
  cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KEEP_ALIVE=10m"
${env_line}
EOF
  systemctl daemon-reload
  systemctl restart ollama
}

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

echo "== Starting Ollama (native config) and pulling benchmark model ${BENCH_MODEL} =="
write_override "native"
if ! wait_for_ollama; then
  echo "ERROR: Ollama service didn't come up. Check: journalctl -u ollama -n 100 --no-pager" >&2
  exit 1
fi

if ! ollama pull "${BENCH_MODEL}"; then
  echo "ERROR: failed to pull ${BENCH_MODEL}. Check network access from inside the container." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Benchmark HSA_OVERRIDE_GFX_VERSION candidates
# ---------------------------------------------------------------------------
echo
echo "== Benchmarking HSA_OVERRIDE_GFX_VERSION candidates on ${BENCH_MODEL} =="
echo "(gfx1151 support is a moving target; the fastest option confirmed to run"
echo " on GPU -- not silently falling back to CPU -- wins and gets pinned.)"
echo

declare -a RESULT_NAME=()
declare -a RESULT_RATE=()
declare -a RESULT_GPU=()

for cand in "${HSA_CANDIDATES[@]}"; do
  echo "--- Candidate: HSA_OVERRIDE_GFX_VERSION=${cand} ---"
  write_override "${cand}"
  if ! wait_for_ollama; then
    echo "  service failed to come up with this override, skipping"
    RESULT_NAME+=("${cand}"); RESULT_RATE+=("0"); RESULT_GPU+=("no")
    continue
  fi

  # Make sure the model isn't still resident from a previous trial so we get
  # a clean load under this override.
  ollama stop "${BENCH_MODEL}" >/dev/null 2>&1 || true
  sleep 1

  OUT=""
  if OUT="$(timeout 90 ollama run "${BENCH_MODEL}" --verbose "${BENCH_PROMPT}" 2>&1)"; then
    RATE="$(echo "${OUT}" | grep -E '^eval rate:' | awk '{print $3}' | head -n1)"
    RATE="${RATE:-0}"
  else
    echo "  run timed out or crashed under this override"
    RATE="0"
  fi

  GPU_STATUS="no"
  PS_OUT="$(ollama ps 2>/dev/null || true)"
  if echo "${PS_OUT}" | grep -qi "GPU"; then
    GPU_STATUS="yes"
  fi

  echo "  eval rate: ${RATE} tokens/s   GPU used: ${GPU_STATUS}"
  RESULT_NAME+=("${cand}")
  RESULT_RATE+=("${RATE}")
  RESULT_GPU+=("${GPU_STATUS}")
done

# ---------------------------------------------------------------------------
# 6. Pick a winner and pin it
# ---------------------------------------------------------------------------
BEST_IDX=-1
BEST_RATE="-1"
for i in "${!RESULT_NAME[@]}"; do
  if [[ "${RESULT_GPU[$i]}" == "yes" ]]; then
    if awk -v a="${RESULT_RATE[$i]}" -v b="${BEST_RATE}" 'BEGIN{exit !(a>b)}'; then
      BEST_RATE="${RESULT_RATE[$i]}"
      BEST_IDX="${i}"
    fi
  fi
done

echo
echo "== Results =="
printf "%-10s %12s %8s\n" "override" "tokens/s" "on GPU"
for i in "${!RESULT_NAME[@]}"; do
  printf "%-10s %12s %8s\n" "${RESULT_NAME[$i]}" "${RESULT_RATE[$i]}" "${RESULT_GPU[$i]}"
done
echo

if [[ "${BEST_IDX}" -eq -1 ]]; then
  echo "WARNING: none of the candidates were confirmed running on GPU." >&2
  echo "Falling back to whichever had the highest raw tokens/s, but this needs" >&2
  echo "manual investigation -- the GPU is probably not being used at all." >&2
  echo "Diagnostics:" >&2
  rocminfo 2>&1 | grep -A3 -i "gfx" >&2 || true
  echo "--- last 40 lines of ollama journal ---" >&2
  journalctl -u ollama -n 40 --no-pager >&2 || true
  for i in "${!RESULT_NAME[@]}"; do
    if awk -v a="${RESULT_RATE[$i]}" -v b="${BEST_RATE}" 'BEGIN{exit !(a>b)}'; then
      BEST_RATE="${RESULT_RATE[$i]}"
      BEST_IDX="${i}"
    fi
  done
fi

WINNER="${RESULT_NAME[$BEST_IDX]}"
echo "Winner: HSA_OVERRIDE_GFX_VERSION=${WINNER} (${RESULT_RATE[$BEST_IDX]} tokens/s, GPU used: ${RESULT_GPU[$BEST_IDX]})"
write_override "${WINNER}"
wait_for_ollama || true
systemctl enable ollama >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 7. Install the "ollama-update" command
# ---------------------------------------------------------------------------
# 04-update-ollama.sh checks for a newer Ollama release, installs it, and
# re-runs this same benchmark, so the pinned HSA_OVERRIDE_GFX_VERSION stays
# correct as new Ollama/ROCm builds ship. It's copied in by script 02 right
# alongside this one.
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
echo "Pinned config: /etc/systemd/system/ollama.service.d/override.conf"
cat /etc/systemd/system/ollama.service.d/override.conf
echo
echo "Try it: ollama run ${BENCH_MODEL} \"tell me a fact about the ocean\""
echo "Check GPU offload any time with: ollama ps"
echo "Check for a newer Ollama release any time with: ollama-update"
echo "  (or from the host: ./02-create-gpu-lxc.sh update <CTID>)"
