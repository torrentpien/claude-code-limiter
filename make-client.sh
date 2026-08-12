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
# macOS/Linux counterpart to connect.ps1: one script with a --vscode switch,
# fronted by two thin .command wrappers, so the two entry points can't drift.
# Must stay BOM-less -- a BOM before the shebang stops it being executable.
cat > "$STAGE/connect.sh" <<SH
#!/bin/bash
set -u

here="\$(cd "\$(dirname "\$0")" && pwd)"
cd "\$here"
export PATH="\$here:\$PATH"

SSH_HOST_NAME='$SSH_HOST'
USER_NAME='$NAME'
HOST_ALIAS='claude-$NAME'
REMOTE_DIR='/workspace/users/$NAME'

VSCODE=0
[ "\${1:-}" = "--vscode" ] && VSCODE=1

echo
echo "  ==============================="
echo "     Claude   ($NAME)"
echo "  ==============================="
echo

# A ZIP opened from a browser is quarantined by Gatekeeper, which also blocks
# the cloudflared we unpack next to it. Clearing the package folder is safe --
# the user already chose to run this.
xattr -dr com.apple.quarantine "\$here" 2>/dev/null || true

# --- cloudflared ----------------------------------------------------------------
# VS Code launches ssh from its own working directory, so ProxyCommand needs an
# absolute path -- resolve one here rather than relying on PATH.
CF_BIN=""
if [ -x "\$here/cloudflared" ]; then
  CF_BIN="\$here/cloudflared"
elif command -v cloudflared >/dev/null 2>&1; then
  CF_BIN="\$(command -v cloudflared)"
else
  echo "  首次啟動，正在下載連線元件..."
  OS=\$(uname -s | tr 'A-Z' 'a-z')
  ARCH=\$(uname -m)
  case "\$ARCH" in x86_64|amd64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; esac
  BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"
  ok=0
  if [ "\$OS" = "darwin" ]; then
    # macOS ships ONLY a .tgz -- the bare binary URL used by other platforms
    # 404s here, which previously surfaced as a misleading network error.
    if curl -fsSL -o "\$here/cf.tgz" "\$BASE/cloudflared-darwin-\${ARCH}.tgz" &&
       tar -xzf "\$here/cf.tgz" -C "\$here" cloudflared; then
      ok=1
    fi
    rm -f "\$here/cf.tgz"
  else
    curl -fsSL -o "\$here/cloudflared" "\$BASE/cloudflared-\${OS}-\${ARCH}" && ok=1
  fi
  if [ "\$ok" != "1" ]; then
    echo "  [!] 下載連線元件失敗。"
    echo "      請確認可以連上 github.com，或先自行安裝 cloudflared："
    echo "        brew install cloudflared"
    read -r -p "  按 Enter 關閉"
    exit 1
  fi
  chmod +x "\$here/cloudflared"
  CF_BIN="\$here/cloudflared"
  echo "  下載完成。"
  echo
fi

# Unzipping leaves the key with the folder's permissions; ssh refuses a key
# others can read, so tighten it every run.
chmod 600 "\$here/id_ed25519" 2>/dev/null || true

# --- Register a Host entry in ~/.ssh/config -------------------------------------
# VS Code Remote-SSH can only use hosts defined there. Rewritten every launch so
# moving the folder fixes itself; paths are absolute and quoted because the
# package may sit in a directory with spaces.
update_ssh_config() {
  mkdir -p "\$HOME/.ssh" && chmod 700 "\$HOME/.ssh"
  cfg="\$HOME/.ssh/config"
  begin="# >>> claude-code-limiter: \$HOST_ALIAS >>>"
  end="# <<< claude-code-limiter: \$HOST_ALIAS <<<"
  [ -f "\$cfg" ] || : > "\$cfg"

  # Drop any previous block for this alias, keeping the user's own entries.
  awk -v b="\$begin" -v e="\$end" '
    \$0 == b { skip = 1 }
    !skip    { print }
    \$0 == e { skip = 0 }
  ' "\$cfg" > "\$cfg.claude.tmp" || return 1

  {
    sed -e :a -e '/^\\n*\$/{\$d;N;};/\\n\$/ba' "\$cfg.claude.tmp"
    printf '\\n%s\\n' "\$begin"
    printf 'Host %s\\n' "\$HOST_ALIAS"
    printf '    HostName %s\\n' "\$SSH_HOST_NAME"
    printf '    User %s\\n' "\$USER_NAME"
    printf '    IdentityFile "%s"\\n' "\$here/id_ed25519"
    printf '    IdentitiesOnly yes\\n'
    printf '    UserKnownHostsFile "%s"\\n' "\$here/known_hosts"
    printf '    StrictHostKeyChecking accept-new\\n'
    printf '    ProxyCommand "%s" access ssh --hostname %s\\n' "\$CF_BIN" "\$SSH_HOST_NAME"
    printf '    ServerAliveInterval 30\\n'
    printf '%s\\n' "\$end"
  } > "\$cfg.claude.new" && mv "\$cfg.claude.new" "\$cfg"
  rm -f "\$cfg.claude.tmp"
  chmod 600 "\$cfg"
}
update_ssh_config || echo "  [!] 無法更新 SSH 設定檔，VS Code 模式可能無法使用。"

# --- VS Code mode ---------------------------------------------------------------
if [ "\$VSCODE" = "1" ]; then
  CODE=""
  if command -v code >/dev/null 2>&1; then
    CODE="\$(command -v code)"
  else
    for p in \\
      "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \\
      "\$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; do
      [ -x "\$p" ] && CODE="\$p" && break
    done
  fi
  if [ -z "\$CODE" ]; then
    echo "  [!] 找不到 VS Code。"
    echo
    echo "      請先到 https://code.visualstudio.com 安裝 VS Code，"
    echo "      然後再試一次。"
    echo
    read -r -p "  按 Enter 關閉"
    exit 1
  fi

  echo "  檢查 Remote-SSH 擴充套件..."
  if ! "\$CODE" --list-extensions 2>/dev/null | grep -qi '^ms-vscode-remote.remote-ssh\$'; then
    echo "  正在安裝 Remote-SSH 擴充套件，請稍候..."
    "\$CODE" --install-extension ms-vscode-remote.remote-ssh --force >/dev/null 2>&1 ||
      echo "  (擴充套件安裝失敗，請在 VS Code 內手動安裝 Remote-SSH)"
  fi

  echo
  echo "  正在用 VS Code 開啟 \$REMOTE_DIR ..."
  echo "  第一次連線 VS Code 需要在遠端安裝元件，可能要等 1 到 2 分鐘。"
  echo
  "\$CODE" --remote "ssh-remote+\$HOST_ALIAS" "\$REMOTE_DIR"
  echo "  已送出開啟指令。若 VS Code 沒有反應，請看它右下角的通知。"
  echo
  read -r -p "  按 Enter 關閉這個視窗（不會關掉 VS Code）"
  exit 0
fi

# --- Terminal mode --------------------------------------------------------------
echo "  連線中..."
ssh -i "\$here/id_ed25519" \\
    -o "ProxyCommand=\\"\$CF_BIN\\" access ssh --hostname \$SSH_HOST_NAME" \\
    -o IdentitiesOnly=yes \\
    -o StrictHostKeyChecking=accept-new \\
    -o UserKnownHostsFile="\$here/known_hosts" \\
    -o ConnectTimeout=30 \\
    -o ServerAliveInterval=30 \\
    -t "\$USER_NAME@\$SSH_HOST_NAME"
echo
read -r -p "已離開 Claude，按 Enter 關閉。"
SH
chmod +x "$STAGE/connect.sh"

cat > "$STAGE/claude-連線.command" <<'SH'
#!/bin/bash
exec "$(cd "$(dirname "$0")" && pwd)/connect.sh"
SH
chmod +x "$STAGE/claude-連線.command"

cat > "$STAGE/VSCode開啟.command" <<'SH'
#!/bin/bash
exec "$(cd "$(dirname "$0")" && pwd)/connect.sh" --vscode
SH
chmod +x "$STAGE/VSCode開啟.command"

# --- 5. Instructions ------------------------------------------------------------
# BOM so Notepad on Traditional Chinese Windows doesn't read this as Big5.
printf '\xEF\xBB\xBF' > "$STAGE/請先讀我.txt"
cat >> "$STAGE/請先讀我.txt" <<TXT
Claude 連線套件 — $NAME
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
  1. 把這個資料夾整個解壓縮到桌面
  2. ★ 先做下面「第一次使用要先解除封鎖」這一步 ★
  3. 雙擊「claude-連線.command」
  4. 連上後輸入  claude  就開始使用

★ 第一次使用要先解除封鎖（只要做一次）

  從網路下載的檔案會被 macOS 封鎖，畫面會出現
  「Apple could not verify ...」或
  「無法打開，因為來自未識別的開發者」。

  【做法一：最快，各版本都適用】
    1. 打開「終端機」（Terminal）
       ─ 按 Command + 空白鍵，輸入「終端機」再按 Enter

    2. 輸入 cd 和一個空格（就這三個字元，先不要按 Enter）：

         cd

    3. 把解壓縮後的整個資料夾，用滑鼠拖進終端機視窗
       路徑會自動出現在 cd 後面，這時才按 Enter

    4. 再輸入下面這一行，然後按 Enter：

         xattr -cr .

       最後面那個小數點是指令的一部分，不要漏掉。
       沒有任何訊息就是成功了。

    5. 回到 Finder，雙擊「claude-連線.command」

    ※ 第 2、3 步如果不小心提早按了 Enter，畫面不會有錯，
      重做一次第 2 步就好。

  【做法一之二：上面還是不行的話】
    在同一個終端機視窗（已經 cd 進資料夾了）輸入：

         bash ./connect.sh

    這樣是直接執行，不會經過 macOS 的封鎖檢查。

  【做法二：不想用終端機】
    1. 先雙擊「claude-連線.command」讓它被擋一次
    2. 打開「系統設定」→「隱私權與安全性」
    3. 往下捲到「安全性」，會看到
       「已阻擋 claude-連線.command」
    4. 按旁邊的「仍要打開」，再雙擊一次

  註：macOS 15 (Sequoia) 之後，「按住 Control 再點一次」
      已經不能用了，請用上面兩種做法。

【Mac 用 VS Code 開啟】
  雙擊「VSCode開啟.command」
  （如果上面的「解除封鎖」是用做法一做的，
    這個檔案已經一起解除了，直接雙擊即可）

  它會自動設定好連線、安裝需要的擴充套件，
  然後用 VS Code 直接打開你的遠端目錄。
  之後也可以在 VS Code 左下角的「><」按鈕
  選擇 claude-$NAME 連線。

-------------------------------------
常見問題

Q：黑色視窗閃一下就消失？
A：多半是缺少 OpenSSH 用戶端。開啟「設定 > 系統 >
   選用功能 > 新增選用功能」，安裝「OpenSSH 用戶端」。

Q：資料夾裡的 connect.ps1 / connect.sh 是什麼？
A：實際執行連線的腳本（Windows 用 .ps1，Mac 用 .sh），
   必須和啟動檔放在同一個資料夾。
   請不要刪除或單獨移動它們。

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
        # S_IFREG (0o100000) must be OR'd in. Permission bits alone leave the
        # file-type field zero, which extractors read as an unknown type and
        # then normalise the mode away -- macOS Archive Utility drops the exec
        # bit, and the .command fails with "you do not have appropriate access
        # privileges". This is what ZipFile.write() stores via st_mode.
        info.external_attr = ((0o100000 | mode) & 0xFFFF) << 16
        info.create_system = 3  # Unix, so the mode bits are honoured
        with open(src, "rb") as fh:
            z.writestr(info, fh.read())
PY
chmod 600 "$ZIP"

echo
echo "Client package: $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "  contents : Windows 連線Claude.bat / VSCode開啟.bat / connect.ps1"
echo "             macOS   claude-連線.command / VSCode開啟.command / connect.sh"
echo "             共用    id_ed25519 / 請先讀我.txt"
echo "  host     : $SSH_HOST  (user $NAME)"
[ "$BUNDLE" = "--bundle" ] && echo "  cloudflared: bundled" || echo "  cloudflared: downloads on first launch"
echo
echo "Send this ZIP to $NAME over a private channel — it contains their key."
