#!/usr/bin/env bash
# Start/stop the browser terminal: one ttyd per person (dropped to their own
# uid) plus the Access-authenticating proxy that fronts them.
#
#   ./web-terminal.sh start [--test-email you@example.com]
#   ./web-terminal.sh stop
#   ./web-terminal.sh status
#
# Only the proxy should be exposed through the tunnel. Each ttyd binds to
# 127.0.0.1 on its own port and runs as exactly one person.
set -euo pipefail

# Site-specific hostnames live outside the repo so the published source
# carries no real infrastructure. Create /etc/claude-code/site.env with
# SSH_HOST / DASHBOARD_URL / WEB_TERMINAL_HOST / CF_TEAM_DOMAIN.
SITE_ENV="${SITE_ENV:-/etc/claude-code/site.env}"
# shellcheck source=/dev/null
[ -f "$SITE_ENV" ] && . "$SITE_ENV"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="/etc/claude-code/web-terminal.json"
PORTMAP="/etc/claude-code/web-terminal-ports.json"
RUN_DIR="$ROOT/data"
LOG="$RUN_DIR/web-terminal.log"
GROUP="claudeusers"
BASE_PORT=7690

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
mkdir -p "$RUN_DIR"

members() { getent group "$GROUP" | awk -F: '{print $4}' | tr ',' ' '; }

stop_all() {
  pkill -f "ttyd -p 76" 2>/dev/null || true
  [ -f "$RUN_DIR/web-terminal.pid" ] && kill "$(cat "$RUN_DIR/web-terminal.pid")" 2>/dev/null || true
  rm -f "$RUN_DIR/web-terminal.pid"
  echo "Stopped ttyd instances and proxy."
}

case "${1:-start}" in
  stop) stop_all; exit 0 ;;
  status)
    echo "== ttyd =="; ps -eo user,pid,cmd | grep "[t]tyd -p 76" || echo "  (none)"
    echo "== proxy =="; ps -eo pid,cmd | grep "[w]eb-terminal/server.js" || echo "  (none)"
    echo "== ports =="; cat "$PORTMAP" 2>/dev/null || echo "  (no portmap)"
    exit 0 ;;
esac

shift || true
stop_all >/dev/null 2>&1 || true

# Seed a config on first run; the admin fills in aud + the email->user map.
if [ ! -f "$CONFIG" ]; then
  # Unquoted heredoc: team_domain is substituted from the site config. The
  # JSON below contains no other $ or backticks, so nothing else expands.
  cat > "$CONFIG" <<EOF
{
  "_readme": "Browser terminal. 'users' maps a Cloudflare Access email to an OS account. 'aud' is the Access application's Application Audience tag; leave empty only while testing.",
  "port": 7680,
  "team_domain": "${CF_TEAM_DOMAIN:-your-team.cloudflareaccess.com}",
  "aud": "",
  "users": {}
}
EOF
  chown root:root "$CONFIG"; chmod 644 "$CONFIG"
  echo "Created $CONFIG — add your email->user mappings there."
fi

# One ttyd per person, on a stable port, running as exactly that person.
echo "{" > "$PORTMAP.tmp"
i=0; first=1
for u in $(members); do
  id -u "$u" >/dev/null 2>&1 || continue
  port=$((BASE_PORT + i)); i=$((i + 1))
  uid="$(id -u "$u")"; gid="$(id -g "$u")"
  wd="/workspace/users/$u"; [ -d "$wd" ] || wd="/home/$u"
  /usr/local/bin/ttyd -p "$port" -i 127.0.0.1 -W -u "$uid" -g "$gid" \
    -t titleFixed="Claude — $u" -t disableLeaveAlert=true \
    bash -l >> "$LOG" 2>&1 &
  [ $first -eq 1 ] || echo "," >> "$PORTMAP.tmp"
  first=0
  printf '  "%s": %s' "$u" "$port" >> "$PORTMAP.tmp"
  echo "  ttyd for $u on 127.0.0.1:$port (as uid $uid)"
done
printf '\n}\n' >> "$PORTMAP.tmp"
mv "$PORTMAP.tmp" "$PORTMAP"; chown root:root "$PORTMAP"; chmod 644 "$PORTMAP"

sleep 1
node "$ROOT/web-terminal/server.js" "$@" >> "$LOG" 2>&1 &
echo $! > "$RUN_DIR/web-terminal.pid"
sleep 1

if kill -0 "$(cat "$RUN_DIR/web-terminal.pid")" 2>/dev/null; then
  echo "Proxy started (pid $(cat "$RUN_DIR/web-terminal.pid")). Log: $LOG"
  echo
  echo "Next: add a Cloudflare public hostname on the SAME tunnel —"
  echo "  ${WEB_TERMINAL_HOST:-claude-web.example.com} -> HTTP -> localhost:7680"
  echo "  then an Access application over it, and put its AUD tag in $CONFIG."
else
  echo "Proxy failed to start; see $LOG" >&2; tail -5 "$LOG" >&2; exit 1
fi
