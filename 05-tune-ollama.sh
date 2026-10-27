#!/usr/bin/env bash
#
# 05-tune-ollama.sh
#
# Installed inside the container as /usr/local/bin/ollama-tune (by script 03).
# Picks the GPU settings Ollama runs with -- HSA_OVERRIDE_GFX_VERSION and
# (optionally) flash attention -- by checking that each candidate produces
# CORRECT output, not just fast output:
#
#   1. short question          -> the answer must say "Paris"
#   2. ~5k-token document      -> the model must find a code hidden in the middle
#   3. the model must actually be running on the GPU
#
# Only candidates that pass all three are eligible; the fastest one is pinned.
# (An earlier version only timed a short prompt, and happily pinned a config
# that produced word salad on long prompts.)
#
# Usage (as root, inside the container):
#   ollama-tune                          test the HSA override candidates, flash attention OFF
#   ollama-tune --with-flash-attn        also test flash attention ON for each candidate
#   ollama-tune --model llama3.1:70b     test with a specific model (slow: reloads it per candidate,
#                                        but it is the only test that proves YOUR model works)
#
# Environment: BENCH_MODEL (default llama3.2:3b), WITH_FLASH_ATTN=1 (same as the flag).
#
# Files: writes ONLY /etc/systemd/system/ollama.service.d/10-gpu-tuning.conf.
# Your own settings (context length, etc.) belong in 20-user.conf, which this
# script creates once and never overwrites. Any flash-attention / HSA lines
# found in other drop-ins (e.g. the old override.conf) are removed, with a
# backup, so they can't silently override the tuned values.

set -uo pipefail

MODEL="${BENCH_MODEL:-llama3.2:3b}"
WITH_FA="${WITH_FLASH_ATTN:-0}"
CAND_HSA=("native" "11.0.0" "11.5.1")      # "native" = no override at all
DROPIN_DIR="${DROPIN_DIR:-/etc/systemd/system/ollama.service.d}"
TUNING_FILE="${DROPIN_DIR}/10-gpu-tuning.conf"
USER_FILE="${DROPIN_DIR}/20-user.conf"
API="${OLLAMA_API:-http://127.0.0.1:11434}"
REQ_TIMEOUT="${REQ_TIMEOUT:-600}"
NEEDLE="7391"

usage() {
  awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="${2:?--model needs a value}"; shift 2 ;;
    --with-flash-attn) WITH_FA=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi
command -v ollama >/dev/null 2>&1 || { echo "ERROR: ollama isn't installed." >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "Installing jq..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null || { echo "ERROR: couldn't install jq." >&2; exit 1; }
fi
mkdir -p "${DROPIN_DIR}"

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
current_value() {   # $1 = variable name; prints the value currently set in any drop-in
  grep -hE "^Environment=\"?$1=" "${DROPIN_DIR}"/*.conf 2>/dev/null \
    | tail -n1 | sed -E "s/^Environment=\"?$1=([^\"]*)\"?.*/\1/"
}

strip_legacy() {    # remove FA/HSA settings from every drop-in except ours
  local f
  for f in "${DROPIN_DIR}"/*.conf; do
    [[ -e "${f}" && "${f}" != "${TUNING_FILE}" ]] || continue
    if grep -qE '^Environment="?(OLLAMA_FLASH_ATTENTION|HSA_OVERRIDE_GFX_VERSION)=' "${f}"; then
      cp -a "${f}" "${f}.bak.$(date +%s)"
      sed -i -E '/^Environment="?(OLLAMA_FLASH_ATTENTION|HSA_OVERRIDE_GFX_VERSION)=/d' "${f}"
      echo "Moved flash-attention/HSA settings out of $(basename "${f}") (backup kept next to it)"
    fi
  done
}

ensure_user_dropin() {
  if ! grep -qs 'OLLAMA_CONTEXT_LENGTH' "${DROPIN_DIR}"/*.conf; then
    cat > "${USER_FILE}" <<'EOF'
# Your own Ollama settings. ollama-tune and ollama-update never touch this file.
[Service]
Environment="OLLAMA_CONTEXT_LENGTH=32768"
EOF
    echo "Created ${USER_FILE} (context length 32768) -- edit it to taste."
  fi
}

apply_tuning() {    # $1 = hsa value or "native", $2 = flash attention 0/1
  {
    echo "# Managed by ollama-tune and re-generated every time it runs."
    echo "# Put your own settings in 20-user.conf instead."
    echo "[Service]"
    echo "Environment=\"OLLAMA_FLASH_ATTENTION=$2\""
    if [[ "$1" != "native" ]]; then
      echo "Environment=\"HSA_OVERRIDE_GFX_VERSION=$1\""
    fi
  } > "${TUNING_FILE}"
  systemctl daemon-reload
  systemctl restart ollama
}

wait_ready() {
  local i
  for i in $(seq 1 30); do
    curl -fsS "${API}/api/version" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------
gen() {             # $1 = prompt, $2 = max tokens to generate -> raw JSON response on stdout
  jq -n --arg m "${MODEL}" --arg p "$1" --argjson n "${2:-64}" \
    '{model:$m, prompt:$p, stream:false, keep_alive:"5m",
      options:{temperature:0, seed:1, num_ctx:16384, num_predict:$n}}' \
  | curl -sS --max-time "${REQ_TIMEOUT}" -H 'Content-Type: application/json' -d @- "${API}/api/generate"
}

make_long_prompt() {  # ~5k tokens, with a secret code hidden in the middle
  echo "Below is a long document. One line in it states a secret code. Read it carefully."
  echo
  local i
  for i in $(seq 1 300); do
    echo "The quick brown fox jumps over the lazy dog near the river, sentence ${i}."
    if [[ "${i}" -eq 150 ]]; then
      echo "IMPORTANT: The secret code is ${NEEDLE}."
    fi
  done
  echo
  echo "Question: what is the secret code? Answer with just the number."
}

on_gpu() {
  curl -sS --max-time 10 "${API}/api/ps" 2>/dev/null \
    | jq -r '.models[0] | if . == null then "no" elif (.size_vram // 0) > 0 then "yes" else "no" end' 2>/dev/null \
    || echo "no"
}

tok_per_sec() {     # reads a generate response on stdin
  jq -r 'if (.eval_duration // 0) > 0 then (.eval_count / (.eval_duration / 1e9)) else 0 end' 2>/dev/null \
    | awk '{printf "%.1f", $1}'
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
PREV_HSA="$(current_value HSA_OVERRIDE_GFX_VERSION)"
strip_legacy
ensure_user_dropin

echo "== Tuning with model ${MODEL} =="
echo "(each candidate restarts Ollama and runs a short check, a ~5k-token check and a speed test)"
echo

apply_tuning "native" 0
if ! wait_ready; then
  echo "ERROR: Ollama didn't come up. Check: journalctl -u ollama -n 100 --no-pager" >&2
  exit 1
fi
if ! ollama pull "${MODEL}"; then
  echo "ERROR: couldn't pull ${MODEL}." >&2
  exit 1
fi
LONG_PROMPT="$(make_long_prompt)"

FA_LIST=(0)
if [[ "${WITH_FA}" == "1" ]]; then FA_LIST=(0 1); fi

declare -a R_HSA=() R_FA=() R_SHORT=() R_LONG=() R_GPU=() R_RATE=()

for fa in "${FA_LIST[@]}"; do
  for hsa in "${CAND_HSA[@]}"; do
    echo "--- HSA_OVERRIDE_GFX_VERSION=${hsa}  flash-attention=${fa} ---"
    short="FAIL"; long="FAIL"; gpu="no"; rate="0.0"

    apply_tuning "${hsa}" "${fa}"
    if wait_ready; then
      resp="$(gen "What is the capital of France? Answer with one word." 16)" || resp=""
      text="$(jq -r '.response // empty' <<<"${resp}" 2>/dev/null)"
      if [[ "${text}" =~ [Pp]aris ]]; then short="ok"; fi
      echo "  short test: ${short}  (answer: $(echo "${text}" | head -c 60 | tr '\n' ' '))"

      resp="$(gen "${LONG_PROMPT}" 32)" || resp=""
      text="$(jq -r '.response // empty' <<<"${resp}" 2>/dev/null)"
      if [[ "${text}" == *"${NEEDLE}"* ]]; then long="ok"; fi
      echo "  long test:  ${long}  (answer: $(echo "${text}" | head -c 60 | tr '\n' ' '))"

      gpu="$(on_gpu)"
      echo "  on GPU:     ${gpu}"

      if [[ "${short}" == "ok" && "${long}" == "ok" ]]; then
        resp="$(gen "Write a paragraph of about 100 words about the ocean." 128)" || resp=""
        rate="$(tok_per_sec <<<"${resp}")"
        echo "  speed:      ${rate} tokens/s"
      fi
    else
      echo "  service failed to come up with this configuration"
    fi

    R_HSA+=("${hsa}"); R_FA+=("${fa}"); R_SHORT+=("${short}"); R_LONG+=("${long}")
    R_GPU+=("${gpu}"); R_RATE+=("${rate}")
  done
done

# ---------------------------------------------------------------------------
# Pick the fastest candidate that is correct and on GPU
# ---------------------------------------------------------------------------
echo
echo "== Results =="
printf "%-10s %-6s %-7s %-7s %-6s %10s\n" "override" "flash" "short" "long" "GPU" "tokens/s"
BEST=-1; BEST_RATE="-1"
for i in "${!R_HSA[@]}"; do
  printf "%-10s %-6s %-7s %-7s %-6s %10s\n" \
    "${R_HSA[$i]}" "${R_FA[$i]}" "${R_SHORT[$i]}" "${R_LONG[$i]}" "${R_GPU[$i]}" "${R_RATE[$i]}"
  if [[ "${R_SHORT[$i]}" == "ok" && "${R_LONG[$i]}" == "ok" && "${R_GPU[$i]}" == "yes" ]]; then
    if awk -v a="${R_RATE[$i]}" -v b="${BEST_RATE}" 'BEGIN{exit !(a>b)}'; then
      BEST_RATE="${R_RATE[$i]}"; BEST="${i}"
    fi
  fi
done
echo

if [[ "${BEST}" -ge 0 ]]; then
  apply_tuning "${R_HSA[$BEST]}" "${R_FA[$BEST]}"
  wait_ready || true
  echo "Pinned: HSA_OVERRIDE_GFX_VERSION=${R_HSA[$BEST]}, flash-attention=${R_FA[$BEST]} (${R_RATE[$BEST]} tokens/s)"
  echo "Config file: ${TUNING_FILE}"
  if [[ "${MODEL}" != *70b* && "${MODEL}" != *72b* ]]; then
    echo
    echo "Note: this was verified with ${MODEL}. If a much larger model still misbehaves,"
    echo "re-run with that model: ollama-tune --model <your-model>"
  fi
  exit 0
fi

# Nothing passed: don't pin a broken config. Fall back to the safest guess.
apply_tuning "${PREV_HSA:-native}" 0
wait_ready || true
echo "WARNING: no candidate produced correct output on the GPU, so nothing was pinned." >&2
echo "Left Ollama on HSA_OVERRIDE_GFX_VERSION=${PREV_HSA:-native}, flash-attention=0." >&2
echo >&2
echo "Things to try next:" >&2
echo "  - A small model can legitimately fail the long test: retry with a bigger one," >&2
echo "    e.g. ollama-tune --model llama3.1:8b" >&2
echo "  - AMD's docs want Linux >= 6.18.4 for stable gfx1151; Proxmox VE 9.1 ships 6.17." >&2
echo "    Try a newer opt-in Proxmox kernel on the HOST (see script 01's notes)." >&2
echo "  - journalctl -u ollama -n 100 --no-pager   (look for page faults / HIP errors)" >&2
echo "  - Vulkan-backed llama.cpp is a different code path and avoids ROCm entirely." >&2
exit 2
