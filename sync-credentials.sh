#!/usr/bin/env bash
# Re-seed every provisioned account with root's current Claude credentials.
#
# Each account keeps its own copy of ~/.claude/.credentials.json so people can
# use the shared login without signing in. Claude Code refreshes those copies
# independently, so if one account's token goes stale (or you re-login as root),
# run this to push root's current credentials back out to everyone.
#
# Usage:  sudo ./sync-credentials.sh
set -euo pipefail

SRC="/root/.claude/.credentials.json"
GROUP="claudeusers"

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
[ -f "$SRC" ] || { echo "$SRC not found — log in as root with 'claude' first." >&2; exit 1; }

members="$(getent group "$GROUP" | awk -F: '{print $4}' | tr ',' ' ')"
[ -n "${members// /}" ] || { echo "No members in group '$GROUP'." >&2; exit 0; }

for u in $members; do
  home="$(getent passwd "$u" | cut -d: -f6)"
  [ -n "$home" ] && [ -d "$home" ] || { echo "skip $u (no home)"; continue; }
  install -d -m 700 -o "$u" -g "$u" "$home/.claude"
  install -m 600 -o "$u" -g "$u" "$SRC" "$home/.claude/.credentials.json"
  echo "synced $u"
done
echo "Done. Ask anyone with a live session to restart 'claude'."
