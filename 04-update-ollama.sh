#!/usr/bin/env bash
#
# 04-update-ollama.sh
#
# Installed inside the container as /usr/local/bin/ollama-update by
# 03-setup-ollama.sh. Run it any time to check whether a newer Ollama
# release is out and, if so, install it.
#
# The Ollama settings (Vulkan backend, context length, ...) live in systemd
# drop-ins in /etc/systemd/system/ollama.service.d/ and are not touched by an
# update.
#
# Usage (as root, inside the container -- or `pct exec <CTID> -- ollama-update` from the host):
#   ollama-update             update if a newer version exists
#   ollama-update --force     reinstall even if already on the latest version
#
set -uo pipefail

FORCE=0
for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg} (use --force or --help)" >&2
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
  echo "Already up to date. Nothing to do (pass --force to reinstall anyway)."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Install the update
# ---------------------------------------------------------------------------
echo "== Installing update =="
curl -fsSL https://ollama.com/install.sh | sh

systemctl daemon-reload
systemctl restart ollama

NEW_VERSION="$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
echo "Now running Ollama ${NEW_VERSION:-unknown}"

for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    echo "Ollama is up. Check long-prompt output after an update; see the README troubleshooting section."
    exit 0
  fi
  sleep 2
done
echo "ERROR: Ollama didn't come back up after the update. Check: journalctl -u ollama -n 100 --no-pager" >&2
exit 1
