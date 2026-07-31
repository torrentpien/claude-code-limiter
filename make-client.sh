#!/usr/bin/env bash
# Build a ready-to-use client package for one person.
#
# The point: a non-technical person should not have to install anything,
# generate a key, edit an SSH config, or type a command. They unzip the file
# and double-click one icon, and Claude opens.
#
# This generates their keypair here, provisions the account via
# provision-user.sh, and packages the private key plus a launcher into a ZIP.
#
# Usage:
#   ./make-client.sh <name> <install-code|-> [--bundle]
#
#   <name>          short slug, must match the dashboard user (e.g. bob)
#   <install-code>  the CLM-... code from the dashboard, or "-" to reuse the
#                   person's existing token (issues them a fresh key)
#   --bundle        embed cloudflared.exe (~55 MB ZIP) instead of downloading
#                   it on first launch (~6 KB ZIP). Use for locked-down PCs.
#   --keep-key      reuse the key from this person's existing ZIP instead of
#                   issuing a new one. Use when only the launcher changed, so
#                   packages already handed out keep working.
set -euo pipefail

# Site-specific hostnames live outside the repo so the published source
# carries no real infrastructure. Create /etc/claude-code/site.env with
# SSH_HOST / DASHBOARD_URL / WEB_TERMINAL_HOST / CF_TEAM_DOMAIN.
SITE_ENV="${SITE_ENV:-/etc/claude-code/site.env}"
# shellcheck source=/dev/null
[ -f "$SITE_ENV" ] && . "$SITE_ENV"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="${1:?need name}"
CODE="${2:?need install code (or - to reuse existing token)}"
BUNDLE=""
KEEP_KEY=""
for opt in "${@:3}"; do
  case "$opt" in
    --bundle)   BUNDLE="--bundle" ;;
    --keep-key) KEEP_KEY="1" ;;
    *) echo "Unknown option: $opt" >&2; exit 1 ;;
  esac
done

SSH_HOST="${SSH_HOST:-claude-ssh.example.com}"
if [ "$SSH_HOST" = "claude-ssh.example.com" ]; then
  echo "SSH_HOST is unset — set it in $SITE_ENV or the generated package won't connect." >&2
  exit 1
fi
OUT_DIR="$ROOT/dist"
STAGE="$(mktemp -d)"
CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
CF_CACHE="$ROOT/data/cloudflared-windows-amd64.exe"
trap 'rm -rf "$STAGE"' EXIT

[ "$(id -u)" -eq 0 ] || { echo "Run as root (it provisions the account)." >&2; exit 1; }

# --- 1. Keypair ----------------------------------------------------------------
# --keep-key recovers the private key from the ZIP we built last time, so a
# launcher-only change doesn't invalidate packages people are already using.
EXISTING_ZIP="$OUT_DIR/$NAME-claude.zip"
if [ -n "$KEEP_KEY" ] && [ -f "$EXISTING_ZIP" ]; then
  python3 - "$EXISTING_ZIP" "$NAME" "$STAGE/id_ed25519" <<'PY'
import sys, zipfile
zp, name, out = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(zp) as z:
    with open(out, "wb") as fh:
        fh.write(z.read(f"{name}-claude/id_ed25519"))
PY
  chmod 600 "$STAGE/id_ed25519"
  ssh-keygen -y -f "$STAGE/id_ed25519" > "$STAGE/id_ed25519.pub"
  echo "Reusing the existing key for $NAME (packages already handed out stay valid)."
else
  [ -n "$KEEP_KEY" ] && echo "No existing package for $NAME — issuing a new key." >&2
  ssh-keygen -q -t ed25519 -N '' -f "$STAGE/id_ed25519" -C "$NAME@claude-box"
fi
PUBKEY="$(cat "$STAGE/id_ed25519.pub")"

# --- 2. Provision the OS account + register the public key --------------------
"$ROOT/provision-user.sh" "$NAME" "$CODE" "$PUBKEY"

# --- 3. Windows launcher -------------------------------------------------------
# The .bat is deliberately PURE ASCII and never calls chcp. cmd.exe reads a
# batch file byte-by-byte in the active code page and remembers byte offsets;
# putting UTF-8 text (or switching code page mid-file) makes it resume parsing
# at a misaligned offset and shred later lines into fragments. So the .bat only
# launches PowerShell, which handles UTF-8 properly, and all the Chinese lives
# in the .ps1.
cat > "$STAGE/連線Claude.bat" <<'BAT'
@echo off
cd /d "%~dp0"
where powershell >nul 2>&1
if errorlevel 1 (
  echo.
  echo   PowerShell not found. This launcher needs Windows PowerShell.
  echo.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect.ps1"
if errorlevel 1 pause
BAT

# PowerShell does the real work. Written UTF-8 *with BOM* below, because
# Windows PowerShell 5.1 reads a BOM-less script as ANSI and would mangle the
# Chinese exactly the way the batch file did.
cat > "$STAGE/connect.ps1.nobom" <<PS1
param([switch]\$VSCode)

\$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
\$Host.UI.RawUI.WindowTitle = 'Claude - $NAME'

# Run from the package folder and put it on PATH, so cloudflared.exe resolves
# without quoting a path that may contain spaces.
\$here = if (\$PSScriptRoot) { \$PSScriptRoot } else { Split-Path -Parent \$MyInvocation.MyCommand.Path }
Set-Location \$here
\$env:PATH = "\$here;\$env:PATH"

\$SshHost   = '$SSH_HOST'
\$User      = '$NAME'
\$HostAlias = 'claude-$NAME'
\$RemoteDir = '/workspace/users/$NAME'

Write-Host ''
Write-Host '  ==============================='
Write-Host '     Claude   ($NAME)'
Write-Host '  ==============================='
Write-Host ''

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  Write-Host '  [!] 這台電腦缺少 SSH 元件。' -ForegroundColor Red
  Write-Host ''
  Write-Host '      開啟「設定」→「系統」→「選用功能」→「新增選用功能」,'
  Write-Host '      搜尋並安裝「OpenSSH 用戶端」,然後再試一次。'
  Write-Host ''
  Read-Host '  按 Enter 關閉'
  exit 1
}

if (-not (Test-Path 'cloudflared.exe')) {
  Write-Host '  首次啟動,正在下載連線元件,請稍候約一分鐘...'
  try {
    \$ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri '$CF_URL' -OutFile 'cloudflared.exe'
  } catch {
    Write-Host ''
    Write-Host '  [!] 下載失敗,請確認網路可以連線後再試一次。' -ForegroundColor Red
    Write-Host ''
    Read-Host '  按 Enter 關閉'
    exit 1
  }
  Write-Host '  下載完成。'
  Write-Host ''
}

# Windows refuses a private key that other accounts can read; unzipping leaves
# it inheriting the folder's permissions, so tighten it every run.
# Subexpression required: "\$env:USERNAME:R" would be parsed as an env var
# literally named "USERNAME:R", which is empty, and icacls would reject ":R".
try { icacls 'id_ed25519' /inheritance:r /grant:r "\$(\$env:USERNAME):R" | Out-Null } catch {}

# --- Register a Host entry in the user's ~/.ssh/config ------------------------
# VS Code Remote-SSH can only use hosts defined there, and it runs ssh from its
# own working directory, so every path here must be absolute. Rewritten on each
# launch so moving the folder fixes itself.
function Update-SshConfig {
  \$sshDir = Join-Path \$env:USERPROFILE '.ssh'
  if (-not (Test-Path \$sshDir)) { New-Item -ItemType Directory -Path \$sshDir -Force | Out-Null }
  \$cfg   = Join-Path \$sshDir 'config'
  \$begin = "# >>> claude-code-limiter: \$HostAlias >>>"
  \$end   = "# <<< claude-code-limiter: \$HostAlias <<<"
  \$block = @"
\$begin
Host \$HostAlias
    HostName \$SshHost
    User \$User
    IdentityFile "\$here\id_ed25519"
    IdentitiesOnly yes
    UserKnownHostsFile "\$here\known_hosts"
    StrictHostKeyChecking accept-new
    ProxyCommand "\$here\cloudflared.exe" access ssh --hostname \$SshHost
    ServerAliveInterval 30
\$end
"@
  \$text = if (Test-Path \$cfg) { Get-Content \$cfg -Raw -Encoding UTF8 } else { '' }
  if (\$null -eq \$text) { \$text = '' }
  \$pattern = [regex]::Escape(\$begin) + '.*?' + [regex]::Escape(\$end)
  \$text = [regex]::Replace(\$text, \$pattern, '', 'Singleline').TrimEnd()
  \$out = if (\$text) { \$text + "\`r\`n\`r\`n" + \$block } else { \$block }
  # UTF-8 *without* BOM: OpenSSH reads the config as UTF-8 but chokes on a BOM,
  # and a Chinese Windows username makes the paths non-ASCII.
  [System.IO.File]::WriteAllText(\$cfg, \$out, (New-Object System.Text.UTF8Encoding(\$false)))
}
try { Update-SshConfig } catch {
  Write-Host "  [!] 無法更新 SSH 設定檔: \$(\$_.Exception.Message)" -ForegroundColor Yellow
}

# --- VS Code mode ---------------------------------------------------------------
if (\$VSCode) {
  \$code = (Get-Command code -ErrorAction SilentlyContinue).Source
  if (-not \$code) {
    foreach (\$p in @(
      "\$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
      "\$env:ProgramFiles\Microsoft VS Code\bin\code.cmd",
      "\${env:ProgramFiles(x86)}\Microsoft VS Code\bin\code.cmd")) {
      if (Test-Path \$p) { \$code = \$p; break }
    }
  }
  if (-not \$code) {
    Write-Host '  [!] 找不到 VS Code。' -ForegroundColor Red
    Write-Host ''
    Write-Host '      請先到 https://code.visualstudio.com 安裝 VS Code,'
    Write-Host '      安裝時請勾選「加入 PATH」,然後再試一次。'
    Write-Host ''
    Read-Host '  按 Enter 關閉'
    exit 1
  }

  Write-Host '  檢查 Remote-SSH 擴充套件...'
  try {
    \$exts = & \$code --list-extensions 2>\$null
    if (\$exts -notcontains 'ms-vscode-remote.remote-ssh') {
      Write-Host '  正在安裝 Remote-SSH 擴充套件,請稍候...'
      & \$code --install-extension ms-vscode-remote.remote-ssh --force | Out-Null
    }
  } catch {
    Write-Host '  (略過擴充套件檢查)' -ForegroundColor Yellow
  }

  Write-Host ''
  Write-Host "  正在用 VS Code 開啟 \$RemoteDir ..."
  Write-Host '  第一次連線 VS Code 需要在遠端安裝元件,可能要等 1 到 2 分鐘。'
  Write-Host ''
  & \$code --remote "ssh-remote+\$HostAlias" \$RemoteDir
  Write-Host '  已送出開啟指令。若 VS Code 沒有反應,請看它右下角的通知。'
  Write-Host ''
  Read-Host '  按 Enter 關閉這個視窗(不會關掉 VS Code)'
  exit 0
}

# --- Terminal mode ----------------------------------------------------------------
Write-Host '  連線中,第一次可能要等 10 到 20 秒...'
Write-Host ''

\$proxy = 'ProxyCommand=cloudflared.exe access ssh --hostname $SSH_HOST'
& ssh -i id_ed25519 -o \$proxy -o StrictHostKeyChecking=accept-new \`
      -o UserKnownHostsFile=known_hosts -o ConnectTimeout=30 \`
      -t '$NAME@$SSH_HOST'
\$rc = \$LASTEXITCODE

Write-Host ''
if (\$rc -ne 0) {
  Write-Host "  [!] 連線結束,代碼 \$rc。" -ForegroundColor Yellow
  Write-Host '      如果一直連不上,把這個視窗拍照傳給管理者。'
} else {
  Write-Host '  已離開 Claude。'
}
Write-Host ''
Read-Host '  按 Enter 關閉'
PS1
printf '\xEF\xBB\xBF' > "$STAGE/connect.ps1"
cat "$STAGE/connect.ps1.nobom" >> "$STAGE/connect.ps1"
rm -f "$STAGE/connect.ps1.nobom"

# Second entry point: same script, VS Code mode. Pure ASCII, like the other bat.
cat > "$STAGE/VSCode開啟.bat" <<'BAT'
@echo off
cd /d "%~dp0"
where powershell >nul 2>&1
if errorlevel 1 (
  echo.
  echo   PowerShell not found. This launcher needs Windows PowerShell.
  echo.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect.ps1" -VSCode
if errorlevel 1 pause
BAT

# --- 4. macOS / Linux launcher --------------------------------------------------
cat > "$STAGE/claude-連線.command" <<SH
#!/bin/bash
cd "\$(dirname "\$0")"
export PATH="\$PWD:\$PATH"
echo "  Claude  ($NAME)"
echo
if ! command -v cloudflared >/dev/null 2>&1 && [ ! -x ./cloudflared ]; then
  echo "  首次啟動，正在下載連線元件..."
  OS=\$(uname -s | tr 'A-Z' 'a-z'); ARCH=\$(uname -m)
  case "\$ARCH" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; esac
  curl -fsSL -o ./cloudflared \\
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-\${OS}-\${ARCH}" || {
      echo "  [!] 下載失敗，請確認網路連線。"; read -r -p "按 Enter 關閉"; exit 1; }
  chmod +x ./cloudflared
fi
chmod 600 id_ed25519
echo "  連線中..."
ssh -i id_ed25519 \\
    -o "ProxyCommand=cloudflared access ssh --hostname $SSH_HOST" \\
    -o StrictHostKeyChecking=accept-new \\
    -o UserKnownHostsFile=known_hosts \\
    -o ConnectTimeout=30 \\
    -t $NAME@$SSH_HOST
echo
read -r -p "已離開 Claude，按 Enter 關閉。"
SH
chmod +x "$STAGE/claude-連線.command"

# --- 5. Instructions ------------------------------------------------------------
# BOM so Notepad on Traditional Chinese Windows doesn't read this as Big5.
printf '\xEF\xBB\xBF' > "$STAGE/請先讀我.txt"
cat >> "$STAGE/請先讀我.txt" <<TXT
Claude 連線包 — $NAME
=====================================

【Windows】
  1. 把這個資料夾整個解壓縮到桌面
  2. 雙擊「連線Claude.bat」
  3. 連上後會停在你自己的工作目錄，
     輸入  claude  就開始使用

  離開 Claude 後會回到同一個目錄，可以再輸入
  claude 繼續，或輸入 exit 結束連線。

  第一次執行會自動下載連線元件（約一分鐘），
  之後每次都是雙擊就進去。

【用 VS Code 開啟（可以直接編輯檔案）】
  雙擊「VSCode開啟.bat」
  它會自動設定好連線、安裝需要的擴充套件，
  然後用 VS Code 直接打開你的遠端目錄。

  第一次連線 VS Code 要在遠端裝元件，約 1~2 分鐘。
  之後也可以直接在 VS Code 左下角的「><」按鈕
  選擇 claude-$NAME 連線。

  在 VS Code 裡按「終端機 > 新增終端機」就能輸入 claude。

【Mac】
  雙擊「claude-連線.command」
  若出現「無法打開，因為來自未識別的開發者」，
  請按住 Control 再點一次，選「打開」。

-------------------------------------
常見問題

Q：黑色視窗閃一下就消失？
A：多半是缺少 OpenSSH 用戶端。開啟「設定 > 系統 >
   選用功能 > 新增選用功能」，安裝「OpenSSH 用戶端」。

Q：資料夾裡的 connect.ps1 是什麼？
A：實際執行連線的腳本，必須和 .bat 放在一起。
   請不要刪除或單獨移動它。

Q：出現 Permission denied？
A：把視窗拍照傳給管理者，可能是金鑰要重發。

Q：出現「limit reached」之類的訊息？
A：你今天的用量到上限了，請找管理者調整額度。

Q：可以把這個資料夾複製給同事嗎？
A：不行。裡面的金鑰代表「你」，額度也算在你頭上。
   同事要用請另外向管理者申請。

-------------------------------------
重要
  · 資料夾裡的 id_ed25519 是你的私人金鑰，
    等同你的密碼，請勿外流。
  · 你不需要登入 Claude 帳號，連上去就能用。
TXT

# --- 6. cloudflared bundling (optional) -----------------------------------------
if [ "$BUNDLE" = "--bundle" ]; then
  if [ ! -f "$CF_CACHE" ]; then
    echo "Downloading cloudflared for bundling..."
    mkdir -p "$ROOT/data"
    curl -fsSL -o "$CF_CACHE" "$CF_URL" || { echo "Download failed; build without --bundle." >&2; exit 1; }
  fi
  cp "$CF_CACHE" "$STAGE/cloudflared.exe"
fi

# --- 7. Zip it up ----------------------------------------------------------------
mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/$NAME-claude.zip"
rm -f "$ZIP"
python3 - "$STAGE" "$ZIP" "$NAME" <<'PY'
import os, sys, zipfile
stage, out, name = sys.argv[1], sys.argv[2], sys.argv[3]
# Preserve the exec bit: macOS refuses to launch a .command without it, and
# zipfile drops modes unless they are written into external_attr explicitly.
EXEC = {".command", ".sh"}
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(os.listdir(stage)):
        if f.endswith(".pub"):
            continue
        src = os.path.join(stage, f)
        mode = 0o755 if os.path.splitext(f)[1] in EXEC or f == "cloudflared.exe" else 0o600
        info = zipfile.ZipInfo(f"{name}-claude/{f}", date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = (mode & 0xFFFF) << 16
        info.create_system = 3  # Unix, so the mode bits are honoured
        with open(src, "rb") as fh:
            z.writestr(info, fh.read())
PY
chmod 600 "$ZIP"

echo
echo "Client package: $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "  contents : 連線Claude.bat / VSCode開啟.bat / connect.ps1 / claude-連線.command / id_ed25519 / 請先讀我.txt"
echo "  host     : $SSH_HOST  (user $NAME)"
[ "$BUNDLE" = "--bundle" ] && echo "  cloudflared: bundled" || echo "  cloudflared: downloads on first launch"
echo
echo "Send this ZIP to $NAME over a private channel — it contains their key."
