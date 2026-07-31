#!/usr/bin/env bash
# Start the claude-code-limiter server in the background.
# Usage:  ./start.sh            (uses saved/default admin password)
#         ADMIN_PASSWORD=xxx ./start.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT/data}"
PORT="${PORT:-3000}"
mkdir -p "$DATA_DIR"

# JWT secret persists across restarts so admin sessions survive.
SECRET_FILE="$DATA_DIR/jwt-secret"
if [ ! -f "$SECRET_FILE" ]; then
  head -c 32 /dev/urandom | base64 > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
fi

PID_FILE="$DATA_DIR/server.pid"
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "Server already running (pid $(cat "$PID_FILE"))."
  exit 0
fi

# ADMIN_PASSWORD only matters on the very first start (seeds the DB).
# After that, change it from Dashboard -> Settings.
ADMIN_PASSWORD="${ADMIN_PASSWORD:-limiter-admin-2026}" \
JWT_SECRET="$(cat "$SECRET_FILE")" \
DATA_DIR="$DATA_DIR" \
PORT="$PORT" \
nohup node "$ROOT/packages/server/bin/server.js" \
  >> "$DATA_DIR/server.log" 2>&1 &

echo $! > "$PID_FILE"
sleep 1
if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "Server started (pid $(cat "$PID_FILE"))."
  echo "  Dashboard: http://localhost:$PORT/dashboard"
  echo "  Log:       $DATA_DIR/server.log"
else
  echo "Server failed to start — check $DATA_DIR/server.log"
  exit 1
fi
