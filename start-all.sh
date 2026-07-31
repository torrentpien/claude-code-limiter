#!/usr/bin/env bash
# Boot everything for shared-host mode after a container (re)start:
#   1. limiter server (Express + SQLite, localhost:3000)
#   2. Cloudflare named tunnel (public HTTPS for dashboard + SSH)
#   3. sshd (loopback only; fronted by the tunnel)
#   4. browser terminal (per-person ttyd + Access-authenticating proxy)
# Nothing here survives a container restart on its own — run this script.
set -euo pipefail

# Site-specific hostnames live outside the repo so the published source
# carries no real infrastructure. Create /etc/claude-code/site.env with
# SSH_HOST / DASHBOARD_URL / WEB_TERMINAL_HOST / CF_TEAM_DOMAIN.
SITE_ENV="${SITE_ENV:-/etc/claude-code/site.env}"
# shellcheck source=/dev/null
[ -f "$SITE_ENV" ] && . "$SITE_ENV"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== 1/4 limiter server =="
"$ROOT/start.sh"

echo "== 2/4 cloudflare named tunnel =="
"$ROOT/tunnel-named.sh"

echo "== 3/4 sshd =="
mkdir -p /run/sshd
if pgrep -x sshd >/dev/null; then
  echo "sshd already running."
else
  ssh-keygen -A >/dev/null 2>&1 || true
  /usr/sbin/sshd
  sleep 1
  pgrep -x sshd >/dev/null && echo "sshd started (listening on 127.0.0.1:22)." || { echo "sshd failed to start" >&2; exit 1; }
fi

echo "== 4/4 browser terminal =="
"$ROOT/web-terminal.sh" start || echo "web terminal failed to start (non-fatal)"

echo ""
echo "All up. Dashboard: ${DASHBOARD_URL:-http://localhost:3000/dashboard}"
echo "Add a person:  sudo ./make-client.sh <name> <install-code>   # one-click ZIP"
echo "               sudo ./provision-user.sh <name> <code> \"<pubkey>\"  # key you were given"
