#!/usr/bin/env bash
# Expose the limiter via a Cloudflare Quick Tunnel (random trycloudflare.com URL).
# For testing only — the URL changes on every restart. Use a named tunnel for production.
# Usage:  ./tunnel-quick.sh          start and print the public URL
#         ./tunnel-quick.sh stop     stop the tunnel
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT/data}"
PORT="${PORT:-3000}"
LOG="$DATA_DIR/tunnel-quick.log"
PID_FILE="$DATA_DIR/tunnel-quick.pid"
mkdir -p "$DATA_DIR"

if [ "${1:-}" = "stop" ]; then
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    kill "$(cat "$PID_FILE")" && echo "Tunnel stopped."
  else
    echo "Tunnel not running."
  fi
  rm -f "$PID_FILE"
  exit 0
fi

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "Tunnel already running (pid $(cat "$PID_FILE"))."
  grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" | tail -1
  exit 0
fi

: > "$LOG"
nohup cloudflared tunnel --no-autoupdate --url "http://localhost:$PORT" >> "$LOG" 2>&1 &
echo $! > "$PID_FILE"

# Wait for cloudflared to print the assigned URL
for i in $(seq 1 40); do
  URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" | tail -1 || true)"
  [ -n "$URL" ] && break
  sleep 0.5
done

if [ -n "${URL:-}" ]; then
  echo "Quick Tunnel up (pid $(cat "$PID_FILE"))"
  echo "  Public URL: $URL"
  echo "  Dashboard:  $URL/dashboard"
else
  echo "Tunnel started but no URL found yet — check $LOG"
  exit 1
fi
