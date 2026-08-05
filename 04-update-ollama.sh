#!/usr/bin/env bash
#
# 04-update-ollama.sh
#
# Installed inside the container as /usr/local/bin/ollama-update by
# 03-setup-ollama.sh. Run it any time to check whether a newer Ollama
# release is out and, if so, install it.
#
# A new Ollama build can ship an updated bundled ROCm runtime, which can
# change which HSA_OVERRIDE_GFX_VERSION is fastest / actually runs on GPU
# for gfx1151 -- so after updating, this re-runs the same benchmark script
# 03 used and re-pins whichever override wins now.
#
# Usage (as root, inside the container -- or `pct exec <CTID> -- ollama-update` from the host):
#   ollama-update                     update if a newer version exists, then re-benchmark
#   ollama-update --force             re-benchmark even if already on the latest version
#   ollama-update --skip-benchmark    update the binary only, don't re-tune the override
#
set -uo pipefail

BENCH_MODEL="${BENCH_MODEL:-llama3.2:1b}"
BENCH_PROMPT="Write one short sentence about the ocean."
HSA_CANDIDATES=("native" "11.0.0" "11.5.1")
OVERRIDE_FILE="/etc/systemd/system/ollama.service.d/override.conf"

SKIP_BENCHMARK=0
FORCE=0
for arg in "$@"; do
  case "${arg}" in
    --skip-benchmark) SKIP_BENCHMARK=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg} (use --force, --skip-benchmark, or --help)" >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi
if ! command -v ollama >/dev/null 2>&1; then
  echo "ERROR: ollama isn't installed. Run 03-setup-ollama.sh first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Check current vs latest version
# ---------------------------------------------------------------------------
CURRENT_VERSION="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
LATEST_VERSION="$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null \
  | grep -m1 '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

echo "Installed Ollama version: ${CURRENT_VERSION:-unknown}"

UPDATE_NEEDED=0
if [[ -z "${LATEST_VERSION}" ]]; then
  echo "Couldn't reach the GitHub API to check the latest release (rate-limited or offline)."
  echo "Running the installer anyway -- it's a no-op if you're already current."
  UPDATE_NEEDED=1
else
  echo "Latest Ollama release:    ${LATEST_VERSION}"
  if [[ "${CURRENT_VERSION}" != "${LATEST_VERSION}" ]]; then
    UPDATE_NEEDED=1
  fi
fi

if [[ "${UPDATE_NEEDED}" -eq 0 && "${FORCE}" -eq 0 ]]; then
  echo "Already up to date. Nothing to do (pass --force to re-benchmark anyway)."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Install the update
# ---------------------------------------------------------------------------
if [[ "${UPDATE_NEEDED}" -eq 1 ]]; then
  echo "== Installing update =="
  curl -fsSL https://ollama.com/install.sh | sh
fi

systemctl daemon-reload
systemctl restart ollama

NEW_VERSION="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
echo "Now running Ollama ${NEW_VERSION:-unknown}"

PREVIOUS_OVERRIDE="$(grep -oE 'HSA_OVERRIDE_GFX_VERSION=[0-9.]+' "${OVERRIDE_FILE}" 2>/dev/null | cut -d= -f2)"
PREVIOUS_OVERRIDE="${PREVIOUS_OVERRIDE:-native}"

if [[ "${SKIP_BENCHMARK}" -eq 1 ]]; then
  echo "Skipping re-benchmark (--skip-benchmark). Previously pinned override left as-is: ${PREVIOUS_OVERRIDE}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Re-benchmark HSA_OVERRIDE_GFX_VERSION candidates on the new version
# ---------------------------------------------------------------------------
write_override() {
  local hsa_value="$1"
  local env_line=""
  if [[ "${hsa_value}" != "native" ]]; then
    env_line="Environment=\"HSA_OVERRIDE_GFX_VERSION=${hsa_value}\""
  fi
  mkdir -p /etc/systemd/system/ollama.service.d
  cat > "${OVERRIDE_FILE}" <<EOF
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
    curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

if ! wait_for_ollama; then
  echo "ERROR: Ollama didn't come back up after the update. Check: journalctl -u ollama -n 100 --no-pager" >&2
  exit 1
fi

if ! ollama pull "${BENCH_MODEL}" >/dev/null; then
  echo "WARNING: couldn't pull ${BENCH_MODEL} to re-benchmark; leaving previous override (${PREVIOUS_OVERRIDE}) in place." >&2
  write_override "${PREVIOUS_OVERRIDE}"
  exit 0
fi

echo
echo "== Re-benchmarking HSA_OVERRIDE_GFX_VERSION candidates =="
declare -a RESULT_NAME=()
declare -a RESULT_RATE=()
declare -a RESULT_GPU=()

for cand in "${HSA_CANDIDATES[@]}"; do
  echo "--- Candidate: ${cand} ---"
  write_override "${cand}"
  if ! wait_for_ollama; then
    echo "  service failed to come up with this override, skipping"
    RESULT_NAME+=("${cand}"); RESULT_RATE+=("0"); RESULT_GPU+=("no")
    continue
  fi

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
  if ollama ps 2>/dev/null | grep -qi "GPU"; then
    GPU_STATUS="yes"
  fi

  echo "  eval rate: ${RATE} tokens/s   GPU used: ${GPU_STATUS}"
  RESULT_NAME+=("${cand}")
  RESULT_RATE+=("${RATE}")
  RESULT_GPU+=("${GPU_STATUS}")
done

BEST_IDX=-1
BEST_RATE="-1"
for i in "${!RESULT_NAME[@]}"; do
  if [[ "${RESULT_GPU[$i]}" == "yes" ]] && awk -v a="${RESULT_RATE[$i]}" -v b="${BEST_RATE}" 'BEGIN{exit !(a>b)}'; then
    BEST_RATE="${RESULT_RATE[$i]}"
    BEST_IDX="${i}"
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
  echo "WARNING: none of the candidates were confirmed running on GPU after the update." >&2
  echo "Falling back to the highest raw tokens/s -- this needs manual investigation." >&2
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
echo "Previous pinned override: ${PREVIOUS_OVERRIDE}"
echo "New winner:                ${WINNER} (${RESULT_RATE[$BEST_IDX]} tokens/s, GPU used: ${RESULT_GPU[$BEST_IDX]})"
write_override "${WINNER}"
wait_for_ollama || true
echo "Done. Pinned HSA_OVERRIDE_GFX_VERSION=${WINNER}."
