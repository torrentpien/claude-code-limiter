#!/usr/bin/env bash
# Stop the claude-code-limiter server started by start.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT/data}"
PID_FILE="$DATA_DIR/server.pid"

if [ ! -f "$PID_FILE" ]; then
  echo "No pid file ($PID_FILE) — server not running?"
  exit 0
fi

PID="$(cat "$PID_FILE")"
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  echo "Sent SIGTERM to pid $PID."
else
  echo "Process $PID not running."
fi
rm -f "$PID_FILE"
