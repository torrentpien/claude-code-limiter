#!/usr/bin/env bash
# Provision an isolated limiter identity: one OS account per person, mapped to
# one dashboard user. Each person SSHes in as their own OS user and uses this
# box's already-logged-in Claude without logging in themselves, while being
# tracked and limited as their own dashboard identity.
#
# Isolation model (see SHARED-HOST.md):
#   - Identity comes from the OS account, not the environment. hook.js reads
#     /etc/claude-code/shared-host.json and derives paths from the uid, so a
#     person cannot repoint the limiter by editing their shell rc files.
#   - authorized_keys lives in root-owned /etc/ssh/authorized_keys/<name>, so
#     people cannot add keys for each other (which would share one quota).
#   - Homes are 0750 and per-person, so files, history, and caches don't leak.
#
# Usage:
#   ./provision-user.sh <name> <install-code> "<ssh-public-key>"
#
#   <name>          short slug, e.g. alice  (must match the dashboard user)
#   <install-code>  the one-time code from the dashboard (CLM-...). On re-runs,
#                   pass "-" to keep the existing token and only update the key.
#   <ssh pubkey>    the person's public key line (ssh-ed25519 AAAA... me@laptop)
set -euo pipefail

# Site-specific hostnames live outside the repo so the published source
# carries no real infrastructure. Create /etc/claude-code/site.env with
# SSH_HOST / DASHBOARD_URL / WEB_TERMINAL_HOST / CF_TEAM_DOMAIN.
SITE_ENV="${SITE_ENV:-/etc/claude-code/site.env}"
# shellcheck source=/dev/null
[ -f "$SITE_ENV" ] && . "$SITE_ENV"

NAME="${1:?need name}"
CODE="${2:?need install code (or - to reuse existing token)}"
PUBKEY="${3:?need ssh public key}"

case "$NAME" in
  root|dev|ubuntu|daemon|bin|sys) echo "Refusing to use reserved account '$NAME'." >&2; exit 1 ;;
esac
if ! printf '%s' "$NAME" | grep -qE '^[a-z_][a-z0-9_-]{0,30}$'; then
  echo "Invalid name '$NAME' (use lowercase letters, digits, '-' and '_')." >&2; exit 1
fi

SERVER_URL="${SERVER_URL:-http://localhost:3000}"
LIMITER_BASE="/etc/claude-code"
DIR="$LIMITER_BASE/limiter-$NAME"           # writable caches (owned by NAME)
SECRETS_DIR="$LIMITER_BASE/secrets"         # root-owned tokens
SERVER_FILE="$SECRETS_DIR/$NAME.json"
GROUP="claudeusers"
KEYS_DIR="/etc/ssh/authorized_keys"
AUTH_KEYS="$KEYS_DIR/$NAME"
HOME_DIR="/home/$NAME"
SRC_CREDS="/root/.claude/.credentials.json"

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

# --- Resolve auth_token from install code (or reuse existing) ------------------
read_existing_token() { grep -o '"auth_token"[^,}]*' "$SERVER_FILE" 2>/dev/null | grep -o '[0-9a-f-]\{36\}' | head -1; }
if [ "$CODE" = "-" ]; then
  # AUTH_TOKEN lets the dashboard provision straight from the user row it
  # already holds, with no install code round-trip.
  TOKEN="${AUTH_TOKEN:-$(read_existing_token || true)}"
  [ -n "$TOKEN" ] || { echo "No existing token in $SERVER_FILE — supply a real install code or set AUTH_TOKEN." >&2; exit 1; }
else
  RESP="$(curl -s -X POST "$SERVER_URL/api/v1/register" -H 'Content-Type: application/json' -d "{\"code\":\"$CODE\"}")"
  TOKEN="$(printf '%s' "$RESP" | grep -o '"auth_token"[^,}]*' | grep -o '[0-9a-f-]\{36\}' | head -1 || true)"
  if [ -z "$TOKEN" ]; then
    TOKEN="$(read_existing_token || true)"
    [ -n "$TOKEN" ] || { echo "Register failed and no existing token. Server said: $RESP" >&2; exit 1; }
    echo "Note: install code not accepted; reusing existing token." >&2
  fi
fi

# --- OS account ----------------------------------------------------------------
getent group "$GROUP" >/dev/null || groupadd "$GROUP"
if id -u "$NAME" >/dev/null 2>&1; then
  usermod -aG "$GROUP" "$NAME"
else
  useradd --create-home --shell /bin/bash --groups "$GROUP" "$NAME"
fi
# 0750: the person and root only. Keeps files/history from leaking sideways.
chown "$NAME:$NAME" "$HOME_DIR"; chmod 750 "$HOME_DIR"

# --- Shared Claude login (copy, so no re-login is needed) ----------------------
# Each account gets its own copy; Claude Code refreshes them independently.
# Re-seed everyone with ./sync-credentials.sh if a refresh ever diverges.
install -d -m 700 -o "$NAME" -g "$NAME" "$HOME_DIR/.claude"
if [ -f "$SRC_CREDS" ]; then
  install -m 600 -o "$NAME" -g "$NAME" "$SRC_CREDS" "$HOME_DIR/.claude/.credentials.json"
else
  echo "WARNING: $SRC_CREDS not found — $NAME will have to log in to Claude." >&2
fi
# Skip onboarding prompts on first run.
if [ ! -f "$HOME_DIR/.claude.json" ]; then
  printf '{\n  "hasCompletedOnboarding": true\n}\n' > "$HOME_DIR/.claude.json"
fi
chown "$NAME:$NAME" "$HOME_DIR/.claude.json"; chmod 600 "$HOME_DIR/.claude.json"

# --- Land in their own workdir on login, with a hint of what to type -----------
# In ~/.profile (login shells) rather than ~/.bashrc, so subshells aren't moved
# around. Marker-guarded so re-provisioning doesn't stack duplicates.
PROFILE="$HOME_DIR/.profile"
MARKER="# >>> claude-code-limiter >>>"
touch "$PROFILE"
if ! grep -qF "$MARKER" "$PROFILE"; then
  cat >> "$PROFILE" <<PROF

$MARKER
# Start each login in this person's own working directory.
if [ -d "/workspace/users/$NAME" ]; then
  cd "/workspace/users/$NAME" || true
fi
# Interactive logins only — don't print into scp/rsync/command runs.
case \$- in
  *i*)
    printf '\n  你好,%s。這裡是你的工作目錄:\n    %s\n\n' "$NAME" "\$PWD"
    printf '  輸入  claude   開始使用(離開 Claude 後會回到這裡)\n'
    printf '  輸入  exit     結束連線\n\n'
    ;;
esac
# <<< claude-code-limiter <<<
PROF
fi
chown "$NAME:$NAME" "$PROFILE"
# Silence Ubuntu's MOTD and "Last login" banner so the only thing a
# non-technical person sees on connecting is the hint above.
touch "$HOME_DIR/.hushlogin"; chown "$NAME:$NAME" "$HOME_DIR/.hushlogin"

# --- Token/URL: root-owned, readable only by this person -----------------------
install -d -m 755 -o root -g root "$SECRETS_DIR"
printf '{\n  "url": "%s",\n  "auth_token": "%s"\n}\n' "$SERVER_URL" "$TOKEN" > "$SERVER_FILE"
chown "root:$NAME" "$SERVER_FILE"; chmod 640 "$SERVER_FILE"

# --- Per-person cache dir: writable by them, private from everyone else --------
install -d -m 700 -o "$NAME" -g "$NAME" "$DIR"
install -d -m 700 -o "$NAME" -g "$NAME" "$DIR/usage"
# shared_host:true stops the kill switch from logging the whole box out.
if [ ! -f "$DIR/config.json" ]; then
  printf '{\n  "user_name": "%s",\n  "shared_host": true,\n  "status": "active",\n  "limits": []\n}\n' "$NAME" > "$DIR/config.json"
fi
chown "$NAME:$NAME" "$DIR/config.json"; chmod 600 "$DIR/config.json"

# --- SSH key: root-owned so people can't add keys for each other ---------------
install -d -m 755 -o root -g root "$KEYS_DIR"
printf '%s\n' "$PUBKEY" > "$AUTH_KEYS"
chown root:root "$AUTH_KEYS"; chmod 644 "$AUTH_KEYS"

# --- Working dir ---------------------------------------------------------------
install -d -m 750 -o "$NAME" -g "$NAME" "/workspace/users/$NAME"

echo "Provisioned '$NAME':"
echo "  os account  : $NAME (group $GROUP), home $HOME_DIR (0750)"
echo "  cache dir   : $DIR  (0700, $NAME)"
echo "  token file  : $SERVER_FILE  (0640 root:$NAME)"
echo "  server      : $SERVER_URL  (token ${TOKEN:0:8}...)"
echo "  workdir     : /workspace/users/$NAME"
echo "  ssh key     : $AUTH_KEYS  (root-owned)"
echo "  login       : ssh $NAME@${SSH_HOST:-<set SSH_HOST in $SITE_ENV>}"
