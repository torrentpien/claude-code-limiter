#!/usr/bin/env bash
# Run the Cloudflare named tunnel (remotely-managed, token-based).
# Token lives in data/tunnel-token (gitignored). Hostname/ingress is managed
# in the Cloudflare Zero Trust dashboard (Networks -> Tunnels -> Public Hostname).
# Usage:  ./tunnel-named.sh          start
#         ./tunnel-named.sh stop     stop
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT/data}"
TOKEN_FILE="$DATA_DIR/tunnel-token"
LOG="$DATA_DIR/tunnel-named.log"
PID_FILE="$DATA_DIR/tunnel-named.pid"
mkdir -p "$DATA_DIR"

if [ "${1:-}" = "stop" ]; then
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    kill "$(cat "$PID_FILE")" && echo "Named tunnel stopped."
  else
    echo "Named tunnel not running."
  fi
  rm -f "$PID_FILE"
  exit 0
fi

if [ ! -f "$TOKEN_FILE" ]; then
  echo "Missing $TOKEN_FILE — paste the tunnel token there first." >&2
  exit 1
fi

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "Named tunnel already running (pid $(cat "$PID_FILE"))."
  exit 0
fi

nohup cloudflared tunnel --no-autoupdate run --token "$(cat "$TOKEN_FILE")" >> "$LOG" 2>&1 &
echo $! > "$PID_FILE"

# Wait for the connector to register with Cloudflare's edge
for i in $(seq 1 40); do
  if grep -q "Registered tunnel connection" "$LOG" 2>/dev/null; then
    echo "Named tunnel connected (pid $(cat "$PID_FILE"))."
    exit 0
  fi
  sleep 0.5
done
echo "Started, but no registration seen yet — check $LOG"
