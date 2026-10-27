#!/usr/bin/env bash
#
# 04-update-ollama.sh
#
# Installed inside the container as /usr/local/bin/ollama-update. Checks whether
# a newer Ollama release is out and, if so, installs it, then re-runs
# ollama-tune (script 05): a new Ollama build can change which GPU settings
# produce correct output on gfx1151, so they're re-verified after every update.
#
# Usage (as root, inside the container -- or `pct exec <CTID> -- ollama-update`):
#   ollama-update                     update if a newer version exists, then re-tune
#   ollama-update --force             re-tune even if already on the latest version
#   ollama-update --skip-benchmark    update the binary only, leave the tuned settings as they are
#
# Environment passed through to ollama-tune: BENCH_MODEL, WITH_FLASH_ATTN=1.
#
set -uo pipefail

SKIP_BENCHMARK=0
FORCE=0
for arg in "$@"; do
  case "${arg}" in
    --skip-benchmark) SKIP_BENCHMARK=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0"
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
  echo "Already up to date. Nothing to do (pass --force to re-tune anyway)."
  exit 0
fi

if [[ "${UPDATE_NEEDED}" -eq 1 ]]; then
  echo "== Installing update =="
  curl -fsSL https://ollama.com/install.sh | sh
  systemctl daemon-reload
  systemctl restart ollama
  NEW_VERSION="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  echo "Now running Ollama ${NEW_VERSION:-unknown}"
fi

if [[ "${SKIP_BENCHMARK}" -eq 1 ]]; then
  echo "Skipping re-tune (--skip-benchmark). Tuned settings left as they are."
  exit 0
fi

if ! command -v ollama-tune >/dev/null 2>&1; then
  echo "ERROR: ollama-tune isn't installed in this container." >&2
  echo "Run './02-create-gpu-lxc.sh update <CTID>' from the host -- it installs the latest helper scripts first." >&2
  exit 1
fi

echo
exec ollama-tune
