<a id="english"></a>

<p align="center">
  <h1 align="center">claude-code-limiter</h1>
  <p align="center">
    Share one Claude Code subscription across your team — with enforced per-user quotas,
    real token accounting, and a live view of how much of the subscription is left.
  </p>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/node-%3E%3D18-brightgreen" alt="Node >= 18">
  <img src="https://img.shields.io/badge/status-beta-orange" alt="Beta">
</p>

<p align="center">
  <b>One subscription. Multiple users. Fair usage for everyone.</b>
</p>

<p align="center">
  <b>English</b> · <a href="#中文說明">繁體中文</a>
</p>

> **Origin.** This project began as a fork of
> **[howincodes/claude-code-limiter](https://github.com/howincodes/claude-code-limiter)**
> by [howincodes](https://github.com/howincodes) and
> [farisbasha](https://github.com/farisbasha), MIT-licensed. The prompt-counting
> limiter, hook architecture, and dashboard are their design and remain the
> foundation of this codebase. This repository adds shared-host deployment,
> token-level accounting, and subscription-ceiling monitoring — see
> [What this fork adds](#what-this-fork-adds) and [Credits](#credits).

> **Beta.** Actively developed against a live deployment. Things may break and
> APIs may change. Issues and PRs are welcome at
> [torrentpien/claude-code-limiter](https://github.com/torrentpien/claude-code-limiter/issues).

<p align="center">
  <img src=".github/dashboard-demo.png" alt="Dashboard — real-time usage monitoring with live feed" width="700">
</p>
<p align="center">
  <img src=".github/block-message.png" alt="What users see when rate limited" width="500">
</p>

---

## The problem

You're paying for a Claude Code Max subscription. Several people share it.

Then one person discovers Opus and sends 50 prompts in an hour. The whole
subscription hits its rate limit for the rest of the day, and everyone else
gets nothing.

Claude Code has **no built-in usage controls**. No per-user limits, no quotas,
no visibility into who is using what. You are flying blind and paying the bill.

## The solution

A usage-control layer that sits between your people and the shared subscription:

- **Per-user quotas** — daily / weekly / monthly / rolling-24h caps, per model
- **Credit budgets** — one budget across all models; each person spends it how they like
- **Token accounting** — what each person actually consumed, not just how many times they pressed Enter
- **Subscription ceiling monitoring** — how much of your *plan's* 5-hour, weekly, and Fable-weekly allowance is gone
- **Real-time dashboard** — who is using what, right now
- **Kill switch** — revoke access remotely, instantly

A system-level hook on each machine checks limits on every prompt and talks to
a server you self-host. Users cannot bypass it without root on the machine.

---

## What this fork adds

Upstream counts **prompts**. That is the right primitive for fairness, but it
answers neither "how much of my subscription is left?" nor "who actually burned
it?" — a single prompt can cost a thousand times more than another. These
additions close that gap, and make the whole thing deployable on one shared box
instead of on every person's laptop.

### Real token accounting

The hook reads Claude Code's own session transcript and records
`input` / `output` / `cache_write` / `cache_read` per model, per turn.

- **Deduplicated by `requestId`.** One API response is written to the transcript
  as many JSONL lines that each repeat the same cumulative usage. Summing lines
  naively overcounts by roughly 2.4×.
- **Weighted totals** — `input + output + 1.25 × cache_write + 0.1 × cache_read`,
  mirroring the relative price of each token class. Raw sums are useless in
  practice: in one real week, cache reads were 35.8M against 9,986 input tokens.
- **Incremental reads.** The transcript is tailed from a byte offset, so cost is
  proportional to what is new, not to the file size.
- **Per-model attribution.** A turn that switches models is split across models
  rather than being attributed to whichever model happened to be active last.

**Monitoring only.** Nothing is blocked on token usage — the prompt-count and
credit rules remain the only gates. Token enforcement is deliberately left as a
second step, once there is enough data to set defensible thresholds.

### Subscription ceiling monitoring

A background poller reads the same OAuth usage endpoint the Claude Code CLI uses
for `/status`, and records the three meters your plan is actually judged by:

| Meter | What it is |
|---|---|
| **Session (5h)** | Rolling 5-hour window across all models |
| **Weekly (all models)** | The weekly ceiling that usually binds first |
| **Fable (weekly)** | Separate weekly sub-limit for Fable |

The endpoint reports **percentages only** — the dollar fields come back null —
so the dashboard shows percentage, severity, and time-to-reset. History is kept,
which is what makes it possible to work backwards to absolute token figures by
calibrating against measured transcript usage.

### Fable support

Fable is a first-class model throughout — limit rules, credit weights, per-model
tables, and the dashboard — and is ordered first in every model listing, since
its separate weekly sub-limit is usually the one that runs out first.

### Shared-host mode

Instead of installing the limiter on every laptop, run **one box** that is
already logged in to Claude, and give each person their own OS account on it.

```
  laptop ──ssh over Cloudflare tunnel──▶  shared box
                                            │
                                     one OS account per person
                                            │
                          prompt ─▶ managed hook ─▶ limiter server
                                            │
                              identity derived from the OS uid
```

**One OS account = one dashboard identity**, and the binding is the uid itself,
so it cannot be forged from inside a session. Nobody logs in to Claude, nobody
handles a subscription credential, and root sessions bypass the limiter so admin
work is never gated. Full design and threat model: **[SHARED-HOST.md](SHARED-HOST.md)**.

### Zero-setup connection packages

`make-client.sh` builds a per-person ZIP so a non-technical user never installs a
tool, generates a key, or edits an SSH config. They unzip and double-click:

| Platform | Terminal | VS Code |
|---|---|---|
| Windows | `連線Claude.bat` | `VSCode開啟.bat` |
| macOS | `claude-連線.command` | `VSCode開啟.command` |

Each package carries its own SSH keypair (`0600`), writes the `~/.ssh/config`
entry on first run, and fetches `cloudflared` itself — or embeds it with
`--bundle` for locked-down machines. `--keep-key` rebuilds the launchers without
rotating the key, so packages already handed out keep working.

### Browser terminal

`web-terminal.sh` runs one `ttyd` per person, each bound to loopback and dropped
to that person's uid, behind a single proxy that authenticates via Cloudflare
Access. Nothing to install at all — Claude Code in a browser tab.

### Operational tooling

| Script | Purpose |
|---|---|
| `provision-user.sh` | Create the OS account, SSH key file, root-owned token, and workdir; seed credentials |
| `sync-credentials.sh` | Push the box's current Claude credentials back out to every account |
| `start-all.sh` | Bring up server, Cloudflare tunnel, sshd, and browser terminal after a restart |
| `web-terminal.sh` | Start / stop / status for the browser terminals |
| `tunnel-named.sh`, `tunnel-quick.sh` | Cloudflare tunnel helpers |
| `make-client.sh` | Build a person's connection package |

Real hostnames are deliberately **not** in this repository. Every script reads
them from `/etc/claude-code/site.env`, which lives outside the working tree; see
[SHARED-HOST.md](SHARED-HOST.md#site-configuration).

---

## Which mode do you want?

| | **Classic** | **Shared-host** |
|---|---|---|
| Claude Code runs on | each person's own machine | one shared box |
| Who logs in to Claude | each person | nobody — the box is logged in |
| Install per person | `setup` on their machine, needs root | an OS account, created by you |
| Identity | install code → auth token | the OS uid |
| Best for | a team that each has their own laptop and subscription seat | one subscription shared by people who should not hold its credentials |
| Setup guide | below | **[SHARED-HOST.md](SHARED-HOST.md)** |

Both modes use the same server, dashboard, and limit rules.

---

## Quick start (classic mode)

### 1. Run the server

The server must be reachable from every user's machine.

**Docker**
```bash
docker build -t claude-code-limiter packages/server
docker run -d --name claude-limiter -p 3000:3000 \
  -v claude-limiter-data:/data \
  -e ADMIN_PASSWORD=your-secure-password \
  claude-code-limiter
```

**Docker Compose with auto-HTTPS** (Caddy handles certificates)
```bash
cd packages/server
DOMAIN=limiter.yourdomain.com ADMIN_PASSWORD=secret docker compose up -d
```

**From source**
```bash
git clone https://github.com/torrentpien/claude-code-limiter.git
cd claude-code-limiter && npm install
ADMIN_PASSWORD=secret npm run serve
```

> Every user's machine must reach the server URL. `localhost` only works on the
> server itself — use a public URL, a VPS IP, or a LAN IP.

### 2. Add users in the dashboard

Open `https://your-server/dashboard`, log in with your admin password, then
**Add User** → set limits → copy the install code.

### 3. Install on each user's machine

The npm packages are **not published** under this fork's scope, so install from
a clone:

```bash
git clone https://github.com/torrentpien/claude-code-limiter.git
cd claude-code-limiter && npm install
sudo node packages/cli/bin/cli.js setup \
  --code CLM-alice-a8f3e2 \
  --server https://limiter.yourdomain.com
```

Restart Claude Code. That person is now rate-limited.

<details>
<summary>Publishing to npm yourself (optional)</summary>

If you want the shorter `npx @your-scope/claude-code-limiter setup …` form that
the dashboard's copy button shows, publish the two packages under your own npm
scope and update the `name` fields in `packages/cli/package.json` and
`packages/server/package.json` to match.

</details>

---

## What users see when blocked

```
Daily sonnet limit reached for Alice.
Used 20/20 prompts today.

All usage today:
  fable:   2/10  (8 left)
  opus:    5/5   (0 left)
  sonnet: 20/20  (0 left)
  haiku:  12/40  (28 left)

Credit balance: 0/100

Options:
  Switch to another model (if quota remains)
  Try again later
```

Killed by an admin:

```
Your Claude Code access has been revoked by the admin.
Contact your admin to restore access.
```

Outside a model's allowed hours:

```
Opus is only available 9:00 AM - 6:00 PM (Asia/Taipei).
Current time: 8:15 PM. Try sonnet or haiku instead.
```

---

## Features

### Limit types

| Type | Example | Description |
|---|---|---|
| **Per-model caps** | `opus: 5/day, sonnet: 20/day` | Hard prompt limit per model per window |
| **Credit budgets** | `100 credits/day` | One budget across all models |
| **Time-of-day rules** | `opus: 9am–6pm only` | Restrict expensive models to working hours |

### Windows

| Window | Behaviour |
|---|---|
| `daily` | Resets at local midnight |
| `weekly` | Resets Monday midnight |
| `monthly` | Resets on the 1st |
| `sliding_24h` | Rolling 24 hours — no midnight gaming |

### Credit weights (configurable)

| Model | Default cost |
|---|---|
| Fable | 20 credits |
| Opus | 10 credits |
| Sonnet | 3 credits |
| Haiku | 1 credit |

With a 100 credit/day budget: 5 Fable prompts, or 10 Opus, or 33 Sonnet, or 100
Haiku, or any mix. Adjust in **Dashboard → Settings**.

### Monitoring (no enforcement)

| | Granularity | Enforced? |
|---|---|---|
| Prompt counts | per user, per model, per window | **yes** |
| Credit budget | per user, per window | **yes** |
| Token usage | per user, per model, per turn | no — recorded only |
| Subscription meters | whole plan: 5h / weekly / Fable weekly | no — recorded only |

### Admin controls

- **Real-time dashboard** — live usage bars, per-user breakdowns, WebSocket event feed
- **Kill switch** — revoke access immediately; in classic mode it also forces
  `claude auth logout` on that machine (deliberately suppressed in shared-host
  mode, where that would sign out the whole box)
- **Pause / resume** — suspend without revoking
- **Live config push** — change limits server-side; picked up on the next prompt

---

## How it works

Every prompt passes through four hook events:

```
User types a prompt
        │
        ▼
┌─ SessionStart ───────────────────────────────────┐
│  Captures the active model                       │
│  Syncs config + limits from the server           │
└──────────────────────────────────────────────────┘
        │
        ▼
┌─ UserPromptSubmit  (THE GATE) ───────────────────┐
│  Calls /check → "is this prompt allowed?"        │
│  Server checks: status → time rules →            │
│    per-model caps → credit budget                │
│  Denied  → blocks with a usage summary           │
│  Server down → falls back to the local cache     │
└──────────────────────────────────────────────────┘
        │ (allowed)
        ▼
   Claude does its work
   (tool calls pass through PreToolUse,
    for kill/pause enforcement only)
        │
        ▼
┌─ Stop ───────────────────────────────────────────┐
│  Increments the turn counter (local + server)    │
│  Reads new transcript lines and records tokens   │
└──────────────────────────────────────────────────┘
```

**Design decisions**

- **Turns are the unit of enforcement**, not tool calls. One prompt may fire 10+
  tool calls; it still costs one unit of quota.
- **Tokens are the unit of measurement.** They are recorded per turn alongside
  the count, which is what makes cost visible without changing what is enforced.
- **The hook has zero npm dependencies** — Node.js built-ins only.
- **Local-first.** Checks hit the local cache; server syncs happen in the background.
- **Fail-closed.** If the limiter's files are missing, access is denied.

### Database

`usage_event` stays **one row per turn** — `COUNT(*)` is what the prompt limits
are built on, so it must not be diluted. Token detail lives in a separate
`token_event` table, and subscription meter readings in `subscription_usage`.
Migrations are idempotent and add only nullable columns, so an existing database
upgrades in place.

---

## Security

The only way past this is root on the machine — and anyone with root already has
the subscription credentials.

| # | Layer | Prevents |
|---|---|---|
| 1 | **Managed settings** | `managed-settings.json` in a system directory; user and project config cannot override it |
| 2 | **`allowManagedHooksOnly`** | Users defining their own hooks to bypass the limiter |
| 3 | **OS file permissions** | Hook, config, and server files are root-owned — readable, not writable |
| 4 | **Watchdog daemon** | Runs every 5 min, SHA-256 integrity check, restores tampered files from a root-only backup |
| 5 | **Server-side tracking** | Deleting local usage files to reset counts |
| 6 | **Kill switch** | Continued access after revocation |
| 7 | **Per-user auth tokens** | Impersonating another user; the token file is root-owned |
| 8 | **Fail-closed** | Missing config being read as "unlimited" |

Shared-host mode adds three more: identity derived from the uid (so
`CLAUDE_LIMITER_*` environment variables are ignored for non-root), root-owned
`authorized_keys` outside every home directory, and per-account file modes. See
[SHARED-HOST.md](SHARED-HOST.md#isolation-model).

**Known limitation.** In shared-host mode each account can read the shared
`~/.claude/.credentials.json`, because Claude Code has to. Someone could copy it
and use the subscription off-box, outside the limiter. This is inherent to
"share the box's login"; the mitigations are trust and rotation.

### File locations

```
macOS:   /Library/Application Support/ClaudeCode/
Linux:   /etc/claude-code/
Windows: C:\Program Files\ClaudeCode\

<base>/
├── managed-settings.json       ← hooks + allowManagedHooksOnly
├── shared-host.json            ← shared-host mode: per-OS-user identity map
├── site.env                    ← real hostnames, kept out of the repo
├── .backup/                    ← root-only, watchdog restore source
│   ├── managed-settings.json
│   ├── hook.js
│   ├── config.json
│   └── checksums.json          ← SHA-256 of every protected file
└── limiter/
    ├── hook.js                 ← the rate limiter (zero npm deps)
    ├── config.json             ← cached limits + credit weights
    ├── server.json             ← server URL + auth token
    ├── cache.json              ← last server response (offline fallback)
    ├── session-model.txt       ← current model
    ├── tokens/                 ← per-session transcript read offsets
    └── usage/
        └── YYYY-MM-DD.json     ← local counters
```

---

## Configuration

### Limit rules

Set per user in the dashboard. Rules stack; the most restrictive wins.

```json
{ "type": "per_model", "model": "opus", "window": "sliding_24h", "value": 5 }
{ "type": "credits",   "window": "daily", "value": 100 }
{
  "type": "time_of_day",
  "model": "opus",
  "schedule_start": "09:00",
  "schedule_end": "18:00",
  "schedule_tz": "Asia/Taipei"
}
```

### Evaluation order

Every rule is checked on every prompt; the first denial wins.

```
1. Killed or paused?              → BLOCK
2. Model outside its time window? → BLOCK
3. Per-model cap exceeded?        → BLOCK
4. Credit budget exceeded?        → BLOCK
5. ALLOW
```

### Server environment

| Variable | Required | Default | Description |
|---|---|---|---|
| `ADMIN_PASSWORD` | first run | — | Dashboard login password |
| `PORT` | no | `3000` | Listen port |
| `JWT_SECRET` | no | auto | Set it to keep admin sessions across restarts |
| `DATA_DIR` | no | `./data`, `/data` in Docker | SQLite location |

---

## CLI reference

From a clone (see [Quick start](#3-install-on-each-users-machine)):

```bash
sudo node packages/cli/bin/cli.js setup --code <CODE> --server <URL>
     node packages/cli/bin/cli.js status
sudo node packages/cli/bin/cli.js sync
sudo node packages/cli/bin/cli.js uninstall
```

`setup` installs the hook, managed settings, and watchdog, then registers with
the server. It needs `sudo` because it writes to system-protected directories.

```
╔══════════════════════════════════════════════╗
║     claude-code-limiter — Status             ║
╚══════════════════════════════════════════════╝

  User:          Alice
  Active model:  sonnet
  Server:        https://your-server:3000

  ┌────────────┬───────┬───────┬──────────────────────┬──────────┐
  │ Model      │ Used  │ Limit │ Progress             │ Left     │
  ├────────────┼───────┼───────┼──────────────────────┼──────────┤
  │ fable      │   2   │  10   │ ████░░░░░░░░░░░░░░   │    8     │
  │ opus       │   3   │   5   │ ██████████░░░░░░░░   │    2     │
  │ sonnet     │  12   │  20   │ ██████████░░░░░░░░   │    8     │
  │ haiku      │   0   │   ∞   │   ∞ unlimited        │    ∞     │
  └────────────┴───────┴───────┴──────────────────────┴──────────┘

  Credits: 61/100 remaining
```

---

## FAQ

**Can a user bypass this?**
Not without root. The hook runs from a system-protected directory with
root-owned files, `allowManagedHooksOnly` blocks user-defined hooks, the
watchdog restores tampered files every 5 minutes, and deleting everything fails
closed.

**Does deleting local usage files reset my quota?**
No. Usage is tracked server-side; local files are a cache.

**Does this affect Claude.ai in the browser?**
No. Only Claude Code.

**What happens if the server goes down?**
The hook falls back to cached limits and usage. Limits still apply, and
everything reconciles when the server returns. With no cache at all, it denies.

**Does it count tool calls or prompts?**
Prompts (turns). One prompt is one unit of quota no matter how much work it does.
Tokens are recorded separately so you can see the difference.

**Does auto-continue count as extra turns?**
Yes. Each continuation fires its own `Stop` event and consumes real capacity.
Set limits with that in mind.

**Are token limits enforced?**
No — token usage is recorded and displayed only. Prompt counts and credits are
the enforced gates.

**Can I run two subscriptions through one server?**
Not today. One server instance is bound to one set of Claude credentials.

---

## Project structure

```
claude-code-limiter/
├── packages/
│   ├── cli/                      ← client CLI + the hook
│   │   ├── bin/cli.js
│   │   └── src/
│   │       ├── hook.js           ← the limiter (zero npm deps)
│   │       └── installer.js      ← setup / sync / uninstall
│   ├── server/
│   │   ├── bin/server.js
│   │   ├── Dockerfile, docker-compose.yml, Caddyfile
│   │   └── src/
│   │       ├── server/
│   │       │   ├── index.js      ← Express app
│   │       │   ├── db.js         ← SQLite schema + migrations
│   │       │   ├── ws.js         ← WebSocket live feed
│   │       │   ├── routes/       ← hook-api.js, admin-api.js
│   │       │   └── services/     ← limiter, usage, auth,
│   │       │                        subscription-usage
│   │       └── dashboard/        ← THE SERVED DASHBOARD (vanilla JS)
│   │           ├── index.html
│   │           ├── css/style.css
│   │           └── js/app.js
│   └── dashboard/                ← React/Vite source, NOT currently served
├── web-terminal/server.js        ← Access-authenticating ttyd proxy
├── make-client.sh                ← build a person's connection package
├── provision-user.sh             ← create an OS account for shared-host mode
├── sync-credentials.sh           ← push credentials to every account
├── start-all.sh                  ← server + tunnel + sshd + web terminal
├── web-terminal.sh, tunnel-*.sh, start.sh, stop.sh
├── SHARED-HOST.md                ← shared-host design and threat model
└── tests/                        ← inherited placeholders, not yet implemented
```

> **The dashboard you see is `packages/server/src/dashboard/`** — plain HTML,
> CSS, and JavaScript, served directly with no build step. `packages/dashboard/`
> holds an unbuilt React rewrite that is **not** wired up; editing it changes
> nothing. Hard-refresh after editing the vanilla bundle.

---

## Development

```bash
git clone https://github.com/torrentpien/claude-code-limiter.git
cd claude-code-limiter
npm install
ADMIN_PASSWORD=secret npm run serve
```

> **There is no test suite yet.** `npm test` prints `TODO`, and the files under
> `tests/` are inherited placeholders with no assertions in them. Verify changes
> against a running server.

**Guidelines**

- `packages/cli/src/hook.js` must stay **zero-dependency** — Node.js built-ins only.
- The server is Express + better-sqlite3 + ws. Keep it simple.
- The served dashboard is vanilla HTML/CSS/JS — no build step, no framework.
- Never commit `dist/` — connection packages contain private keys.
- Never commit real hostnames — they belong in `/etc/claude-code/site.env`.

---

## Credits

This project is a derivative work of
**[howincodes/claude-code-limiter](https://github.com/howincodes/claude-code-limiter)**,
created by [howincodes](https://github.com/howincodes) with
[farisbasha](https://github.com/farisbasha), and released under the MIT licence.

Theirs is the original idea and the foundation this is built on: the managed-hook
architecture, the four-event gate, the fail-closed design, the limit-rule engine,
the credit-budget model, the watchdog, and the dashboard. The full upstream commit
history is preserved in this repository — `git log` shows exactly which work is
whose.

This fork adds shared-host deployment, transcript-based token accounting,
subscription-ceiling monitoring, Fable support, connection packages, and the
browser terminal. It is maintained independently and is not affiliated with
the upstream project; please do not send its maintainers issues that originate here.

To follow upstream:

```bash
git remote add upstream https://github.com/howincodes/claude-code-limiter.git
git fetch upstream
```

## Licence

[MIT](LICENSE).

- Original work © 2026 Basha — <https://github.com/howincodes/claude-code-limiter>
- Modifications © 2026 torrentpien — <https://github.com/torrentpien/claude-code-limiter>

---

<p align="center">
  <b>Stop sharing blindly. Start sharing fairly.</b>
</p>

---
---

<a id="中文說明"></a>

<p align="center">
  <h1 align="center">claude-code-limiter</h1>
  <p align="center">
    讓一個 Claude Code 訂閱給整個團隊共用 —— 每個人有各自的額度上限、
    真實的 token 計量,以及訂閱本身還剩多少的即時檢視。
  </p>
</p>

<p align="center">
  <a href="#english">English</a> · <b>繁體中文</b>
</p>

<p align="center">
  <b>一個訂閱。多人使用。每個人都分得公平。</b>
</p>

> **出處。** 本專案源自
> **[howincodes/claude-code-limiter](https://github.com/howincodes/claude-code-limiter)**
> 的 fork,作者為 [howincodes](https://github.com/howincodes) 與
> [farisbasha](https://github.com/farisbasha),採 MIT 授權。以 prompt 次數計量的
> 限流器、hook 架構與儀表板都是他們的設計,至今仍是這份程式碼的基礎。本專案在其上
> 加入了共用主機部署、token 層級的計量,以及訂閱上限監控 —— 詳見
> [這個 fork 加了什麼](#這個-fork-加了什麼) 與 [致謝](#致謝)。

> **Beta。** 對著一套實際運行的部署持續開發中,可能會壞、API 可能會變。
> 問題回報與 PR 歡迎送到
> [torrentpien/claude-code-limiter](https://github.com/torrentpien/claude-code-limiter/issues)。

---

## 問題在哪

你付錢訂了 Claude Code Max,幾個人一起用。

然後某個人發現了 Opus,一小時內送出 50 個 prompt。整個訂閱當天剩下的時間全部被
限流,其他人什麼都做不了。

Claude Code **沒有任何內建的用量管控**。沒有個人上限、沒有配額,也看不到誰用了多少。
你在盲飛,而帳單是你在付。

## 這個專案做什麼

一層放在「使用者」和「共用訂閱」之間的用量管控:

- **個人額度** —— 每人每模型的每日 / 每週 / 每月 / 滾動 24 小時上限
- **點數預算** —— 一份跨所有模型的預算,每個人自己決定怎麼花
- **Token 計量** —— 每個人實際消耗了多少,而不只是按了幾次 Enter
- **訂閱上限監控** —— 你的**方案本身**的 5 小時、每週、Fable 每週額度用掉多少了
- **即時儀表板** —— 現在誰在用什麼
- **停權開關** —— 遠端即時撤銷存取權

每台機器上有一個系統層級的 hook,在每個 prompt 送出時檢查上限,並和你自架的伺服器
通訊。使用者沒有機器的 root 權限就繞不過去。

---

## 這個 fork 加了什麼

上游計算的是 **prompt 次數**。就公平分配而言這個單位是對的,但它回答不了
「我的訂閱還剩多少?」,也回答不了「到底是誰燒掉的?」—— 一個 prompt 的成本可以是
另一個的一千倍。以下這些補上了這個缺口,並且讓整套東西可以部署在一台共用主機上,
而不是每個人的筆電上。

### 真實的 token 計量

Hook 會讀取 Claude Code 自己的對話紀錄(transcript),按模型、按回合記錄
`input` / `output` / `cache_write` / `cache_read`。

- **以 `requestId` 去重。** 一次 API 回應在 transcript 裡會被寫成好幾行 JSONL,
  每一行都重複同一份累計用量。直接把每行加總會**多算約 2.4 倍**。
- **加權總量** —— `input + output + 1.25 × cache_write + 0.1 × cache_read`,
  對應各類 token 的相對價格。原始加總在實務上沒有意義:某一週的真實數據裡,
  cache read 是 3,580 萬,而真正的 input 只有 9,986。
- **增量讀取。** 從位元組偏移量往後讀,成本只跟新增的內容成正比,與檔案大小無關。
- **按模型歸屬。** 一個中途換模型的回合會被拆開分別計入,而不是全部算在最後
  剛好在用的那個模型頭上。

**只監督,不管控。** 沒有任何東西會因為 token 用量被擋 —— prompt 次數和點數規則
仍然是唯一的關卡。token 管控刻意留作第二階段,等累積夠多資料、能訂出站得住腳的
門檻之後再說。

### 訂閱上限監控

背景輪詢程式讀取 Claude Code CLI 執行 `/status` 時用的同一個 OAuth 用量端點,
記錄你的方案實際上被三個什麼樣的計量器判定:

| 計量器 | 內容 |
|---|---|
| **Session (5h)** | 跨所有模型的滾動 5 小時視窗 |
| **Weekly (all models)** | 每週上限,通常是最先卡住的那個 |
| **Fable (weekly)** | Fable 專屬的每週子上限 |

這個端點**只回傳百分比** —— 金額欄位一律是 null —— 所以儀表板顯示的是百分比、
嚴重程度,以及距離重置的時間。歷史紀錄會保留下來,這正是後續能夠反推絕對 token
數字的關鍵:拿它去對照實測的 transcript 用量做校正。

### Fable 支援

Fable 在整套系統裡是一等公民 —— 限制規則、點數權重、各模型表格、儀表板都有 ——
而且在每一份模型清單裡都排在**第一位**,因為它那個獨立的每週子上限通常是最先用完的。

### 共用主機模式

與其在每台筆電上安裝限流器,不如跑**一台**已經登入 Claude 的主機,
每個人在上面有自己的作業系統帳號。

```
  筆電 ──ssh 經 Cloudflare tunnel──▶  共用主機
                                          │
                                  每人一個 OS 帳號
                                          │
                        prompt ─▶ 受管 hook ─▶ 限流伺服器
                                          │
                              身分由 OS uid 推導而來
```

**一個 OS 帳號 = 一個儀表板身分**,而且綁定的依據就是 uid 本身,所以在 session
內部偽造不了。沒有人需要登入 Claude,沒有人碰得到訂閱憑證,而 root 的 session
會直接跳過限流器,所以你自己的管理工作永遠不會被擋。完整設計與威脅模型:
**[SHARED-HOST.md](SHARED-HOST.md)**。

### 零設定連線包

`make-client.sh` 會為每個人打包一個 ZIP,讓非技術背景的使用者完全不需要安裝工具、
產生金鑰或編輯 SSH 設定。他們解壓縮、雙擊,就進去了:

| 平台 | 終端機 | VS Code |
|---|---|---|
| Windows | `連線Claude.bat` | `VSCode開啟.bat` |
| macOS | `claude-連線.command` | `VSCode開啟.command` |

每個包裡有自己的 SSH 金鑰對(`0600`),首次執行時會寫入 `~/.ssh/config`,
並且自己去抓 `cloudflared` —— 或用 `--bundle` 直接內嵌,給網路受限的機器用。
`--keep-key` 可以只重建啟動器而不換金鑰,這樣已經發出去的包還是能用。

### 瀏覽器終端機

`web-terminal.sh` 為每個人跑一份 `ttyd`,各自綁在 loopback 上並降權到那個人的 uid,
前面用一個統一的 proxy 透過 Cloudflare Access 驗證。什麼都不用裝 ——
瀏覽器分頁裡就是 Claude Code。

### 維運工具

| 腳本 | 用途 |
|---|---|
| `provision-user.sh` | 建立 OS 帳號、SSH 金鑰檔、root 所有的 token、工作目錄;並植入憑證 |
| `sync-credentials.sh` | 把主機目前的 Claude 憑證推回給所有帳號 |
| `start-all.sh` | 重啟後把伺服器、Cloudflare tunnel、sshd、瀏覽器終端機一起拉起來 |
| `web-terminal.sh` | 瀏覽器終端機的 start / stop / status |
| `tunnel-named.sh`、`tunnel-quick.sh` | Cloudflare tunnel 輔助腳本 |
| `make-client.sh` | 建立某個人的連線包 |

真實主機名稱刻意**不放在這個倉庫裡**。所有腳本都從 `/etc/claude-code/site.env`
讀取,那個檔案位於工作目錄之外;參見
[SHARED-HOST.md](SHARED-HOST.md#site-configuration)。

---

## 你要哪一種模式?

| | **傳統模式** | **共用主機模式** |
|---|---|---|
| Claude Code 跑在 | 每個人自己的機器 | 一台共用主機 |
| 誰登入 Claude | 每個人各自登入 | 沒有人 —— 主機本身已登入 |
| 每人的安裝方式 | 在他的機器上跑 `setup`,需要 root | 由你建立一個 OS 帳號 |
| 身分依據 | 安裝碼 → 認證 token | OS uid |
| 適合 | 每人各有筆電、各有訂閱席次的團隊 | 一個訂閱給一群「不該持有其憑證」的人共用 |
| 設定指南 | 見下方 | **[SHARED-HOST.md](SHARED-HOST.md)** |

兩種模式共用同一套伺服器、儀表板與限制規則。

---

## 快速開始(傳統模式)

### 1. 啟動伺服器

伺服器必須能被每一台使用者的機器連到。

**Docker**
```bash
docker build -t claude-code-limiter packages/server
docker run -d --name claude-limiter -p 3000:3000 \
  -v claude-limiter-data:/data \
  -e ADMIN_PASSWORD=your-secure-password \
  claude-code-limiter
```

**Docker Compose 自動 HTTPS**(憑證由 Caddy 處理)
```bash
cd packages/server
DOMAIN=limiter.yourdomain.com ADMIN_PASSWORD=secret docker compose up -d
```

**從原始碼**
```bash
git clone https://github.com/torrentpien/claude-code-limiter.git
cd claude-code-limiter && npm install
ADMIN_PASSWORD=secret npm run serve
```

> 每一台使用者的機器都必須連得到伺服器網址。`localhost` **只有在伺服器本機上**
> 才有效 —— 請用公開網址、VPS IP 或區網 IP。

### 2. 在儀表板新增使用者

開啟 `https://your-server/dashboard`,用管理員密碼登入,然後
**Add User** → 設定上限 → 複製安裝碼。

### 3. 在每台使用者機器上安裝

npm 套件**沒有**以本 fork 的 scope 發布,所以請從 clone 安裝:

```bash
git clone https://github.com/torrentpien/claude-code-limiter.git
cd claude-code-limiter && npm install
sudo node packages/cli/bin/cli.js setup \
  --code CLM-alice-a8f3e2 \
  --server https://limiter.yourdomain.com
```

重啟 Claude Code。這個人就開始受限流管控了。

<details>
<summary>自行發布到 npm(選用)</summary>

如果你想要儀表板複製按鈕顯示的那種較短的
`npx @your-scope/claude-code-limiter setup …` 形式,請把這兩個套件發布到你自己的
npm scope,並同步修改 `packages/cli/package.json` 與 `packages/server/package.json`
裡的 `name` 欄位。

</details>

---

## 被擋下來時使用者看到什麼

（以下是程式的實際輸出,為英文）

```
Daily sonnet limit reached for Alice.
Used 20/20 prompts today.

All usage today:
  fable:   2/10  (8 left)
  opus:    5/5   (0 left)
  sonnet: 20/20  (0 left)
  haiku:  12/40  (28 left)

Credit balance: 0/100

Options:
  Switch to another model (if quota remains)
  Try again later
```

被管理員停權時:

```
Your Claude Code access has been revoked by the admin.
Contact your admin to restore access.
```

在某個模型的允許時段之外:

```
Opus is only available 9:00 AM - 6:00 PM (Asia/Taipei).
Current time: 8:15 PM. Try sonnet or haiku instead.
```

---

## 功能

### 限制類型

| 類型 | 範例 | 說明 |
|---|---|---|
| **各模型上限** | `opus: 5/day, sonnet: 20/day` | 每個模型在每個視窗內的 prompt 硬上限 |
| **點數預算** | `100 credits/day` | 一份跨所有模型的預算 |
| **時段規則** | `opus: 9am–6pm only` | 把昂貴的模型限制在上班時間 |

### 視窗類型

| 視窗 | 行為 |
|---|---|
| `daily` | 當地時間午夜重置 |
| `weekly` | 週一午夜重置 |
| `monthly` | 每月一號重置 |
| `sliding_24h` | 滾動 24 小時 —— 沒辦法卡午夜鑽漏洞 |

### 點數權重（可調整）

| 模型 | 預設成本 |
|---|---|
| Fable | 20 點 |
| Opus | 10 點 |
| Sonnet | 3 點 |
| Haiku | 1 點 |

每日 100 點的預算可以換成:5 次 Fable、或 10 次 Opus、或 33 次 Sonnet、
或 100 次 Haiku,也可以任意混搭。在 **Dashboard → Settings** 裡調整。

### 監督（不管控）

| | 精細度 | 是否管控 |
|---|---|---|
| Prompt 次數 | 每人、每模型、每視窗 | **是** |
| 點數預算 | 每人、每視窗 | **是** |
| Token 用量 | 每人、每模型、每回合 | 否 —— 只記錄 |
| 訂閱計量器 | 整個方案:5h / 每週 / Fable 每週 | 否 —— 只記錄 |

### 管理員控制項

- **即時儀表板** —— 即時用量長條、每人明細、WebSocket 事件流
- **停權開關** —— 立即撤銷存取權;在傳統模式下還會強制該機器執行
  `claude auth logout`（在共用主機模式下**刻意不做**,因為那會把整台主機登出）
- **暫停 / 恢復** —— 暫時停用而不撤銷
- **設定即時推送** —— 在伺服器端改上限,下一個 prompt 就會生效

---

## 運作原理

每個 prompt 會經過四個 hook 事件:

```
使用者輸入 prompt
        │
        ▼
┌─ SessionStart ───────────────────────────────────┐
│  擷取目前使用的模型                               │
│  從伺服器同步設定與上限                           │
└──────────────────────────────────────────────────┘
        │
        ▼
┌─ UserPromptSubmit  （關卡）──────────────────────┐
│  呼叫 /check → 「這個 prompt 可以放行嗎?」        │
│  伺服器依序檢查:狀態 → 時段規則 →                │
│    各模型上限 → 點數預算                          │
│  拒絕 → 擋下並附上用量摘要                        │
│  伺服器掛掉 → 退回使用本地快取                    │
└──────────────────────────────────────────────────┘
        │ （放行）
        ▼
   Claude 開始工作
   （工具呼叫會經過 PreToolUse,
     但僅用於停權/暫停的即時生效）
        │
        ▼
┌─ Stop ───────────────────────────────────────────┐
│  回合計數 +1（本地與伺服器）                      │
│  讀取 transcript 的新增內容並記錄 token           │
└──────────────────────────────────────────────────┘
```

**設計決策**

- **管控的單位是「回合」**,不是工具呼叫。一個 prompt 可能觸發 10 個以上的工具
  呼叫,它仍然只消耗一單位額度。
- **計量的單位是 token。** 它和次數一起被記錄在每個回合上,這讓成本變得可見,
  同時完全不改變「被管控的是什麼」。
- **Hook 沒有任何 npm 相依** —— 只用 Node.js 內建模組。
- **本地優先。** 檢查打本地快取,和伺服器的同步在背景進行。
- **失效即封鎖。** 限流器的檔案不見了,就是拒絕存取。

### 資料庫

`usage_event` 維持**一個回合一列** —— prompt 上限是建立在 `COUNT(*)` 之上的,
所以不能被稀釋。Token 明細放在獨立的 `token_event` 表,訂閱計量器讀數放在
`subscription_usage`。Migration 是冪等的,而且只新增可為 NULL 的欄位,
所以既有資料庫可以原地升級。

---

## 安全性

唯一的繞過方式是取得機器的 root —— 而任何人有了 root,本來就已經拿得到訂閱憑證了。

| # | 層級 | 防止 |
|---|---|---|
| 1 | **受管設定** | `managed-settings.json` 位於系統目錄;使用者與專案設定都覆蓋不了 |
| 2 | **`allowManagedHooksOnly`** | 使用者自訂 hook 來繞過限流器 |
| 3 | **OS 檔案權限** | Hook、設定、伺服器檔案由 root 擁有 —— 可讀不可寫 |
| 4 | **看門狗 daemon** | 每 5 分鐘執行,SHA-256 完整性檢查,從 root 專屬備份還原被竄改的檔案 |
| 5 | **伺服器端記錄** | 刪掉本地用量檔案來歸零計數 |
| 6 | **停權開關** | 撤銷後仍繼續使用 |
| 7 | **每人專屬認證 token** | 冒充他人;token 檔案由 root 擁有 |
| 8 | **失效即封鎖** | 設定缺失被當成「無限制」 |

共用主機模式再加三層:身分由 uid 推導（因此非 root 的 `CLAUDE_LIMITER_*`
環境變數一律被忽略）、`authorized_keys` 由 root 擁有且不在任何人的家目錄裡、
以及每個帳號各自的檔案權限。參見
[SHARED-HOST.md](SHARED-HOST.md#isolation-model)。

**已知限制。** 在共用主機模式下,每個帳號都讀得到共用的
`~/.claude/.credentials.json`,因為 Claude Code 必須讀它。有人可以把它複製走,
在這台主機之外、限流器管不到的地方使用這個訂閱。這是「共用主機登入」這個做法的
本質限制;能做的只有信任,以及必要時更換登入。

### 檔案位置

```
macOS:   /Library/Application Support/ClaudeCode/
Linux:   /etc/claude-code/
Windows: C:\Program Files\ClaudeCode\

<base>/
├── managed-settings.json       ← hooks + allowManagedHooksOnly
├── shared-host.json            ← 共用主機模式:每個 OS 使用者的身分對應
├── site.env                    ← 真實主機名稱,不進倉庫
├── .backup/                    ← root 專屬,看門狗的還原來源
│   ├── managed-settings.json
│   ├── hook.js
│   ├── config.json
│   └── checksums.json          ← 每個受保護檔案的 SHA-256
└── limiter/
    ├── hook.js                 ← 限流器本體（零 npm 相依）
    ├── config.json             ← 快取的上限與點數權重
    ├── server.json             ← 伺服器網址 + 認證 token
    ├── cache.json              ← 最後一次伺服器回應（離線備援）
    ├── session-model.txt       ← 目前模型
    ├── tokens/                 ← 每個 session 的 transcript 讀取偏移量
    └── usage/
        └── YYYY-MM-DD.json     ← 本地計數
```

---

## 設定

### 限制規則

在儀表板上為每個人設定。規則會疊加,最嚴格的那條生效。

```json
{ "type": "per_model", "model": "opus", "window": "sliding_24h", "value": 5 }
{ "type": "credits",   "window": "daily", "value": 100 }
{
  "type": "time_of_day",
  "model": "opus",
  "schedule_start": "09:00",
  "schedule_end": "18:00",
  "schedule_tz": "Asia/Taipei"
}
```

### 判定順序

每個 prompt 都會檢查所有規則,第一個拒絕就生效。

```
1. 已停權或暫停?           → 擋下
2. 模型在允許時段外?       → 擋下
3. 超過該模型上限?         → 擋下
4. 超過點數預算?           → 擋下
5. 放行
```

### 伺服器環境變數

| 變數 | 必要 | 預設 | 說明 |
|---|---|---|---|
| `ADMIN_PASSWORD` | 首次啟動需要 | — | 儀表板登入密碼 |
| `PORT` | 否 | `3000` | 監聽埠 |
| `JWT_SECRET` | 否 | 自動產生 | 設定它可讓管理員 session 在重啟後保留 |
| `DATA_DIR` | 否 | `./data`,Docker 下為 `/data` | SQLite 位置 |

---

## CLI 指令

從 clone 執行（見 [快速開始](#3-在每台使用者機器上安裝)）:

```bash
sudo node packages/cli/bin/cli.js setup --code <CODE> --server <URL>
     node packages/cli/bin/cli.js status
sudo node packages/cli/bin/cli.js sync
sudo node packages/cli/bin/cli.js uninstall
```

`setup` 會安裝 hook、受管設定與看門狗,然後向伺服器註冊。因為要寫入系統保護目錄,
所以需要 `sudo`。

```
╔══════════════════════════════════════════════╗
║     claude-code-limiter — Status             ║
╚══════════════════════════════════════════════╝

  User:          Alice
  Active model:  sonnet
  Server:        https://your-server:3000

  ┌────────────┬───────┬───────┬──────────────────────┬──────────┐
  │ Model      │ Used  │ Limit │ Progress             │ Left     │
  ├────────────┼───────┼───────┼──────────────────────┼──────────┤
  │ fable      │   2   │  10   │ ████░░░░░░░░░░░░░░   │    8     │
  │ opus       │   3   │   5   │ ██████████░░░░░░░░   │    2     │
  │ sonnet     │  12   │  20   │ ██████████░░░░░░░░   │    8     │
  │ haiku      │   0   │   ∞   │   ∞ unlimited        │    ∞     │
  └────────────┴───────┴───────┴──────────────────────┴──────────┘

  Credits: 61/100 remaining
```

---

## 常見問題

**使用者有辦法繞過嗎?**
沒有 root 就不行。Hook 從系統保護目錄執行、檔案由 root 擁有,
`allowManagedHooksOnly` 擋掉使用者自訂的 hook,看門狗每 5 分鐘還原被竄改的檔案,
而且就算全部刪光,結果是失效即封鎖。

**刪掉本地用量檔案可以讓額度歸零嗎?**
不行。用量記錄在伺服器端,本地檔案只是快取。

**這會影響瀏覽器上的 Claude.ai 嗎?**
不會。只影響 Claude Code。

**伺服器掛掉會怎樣?**
Hook 會退回使用快取的上限與用量。限制仍然生效,伺服器回來後會自動對帳。
如果連快取都沒有,就拒絕。

**它算的是工具呼叫還是 prompt?**
Prompt(回合)。一個 prompt 就是一單位額度,不管它做了多少事。
Token 另外記錄,所以你看得出這中間的差距。

**自動續寫（auto-continue）會算成多個回合嗎?**
會。每一次續寫都會觸發自己的 `Stop` 事件,也確實消耗了真實的運算量。
設定上限時要把這件事考慮進去。

**Token 上限會被強制執行嗎?**
不會 —— token 用量只會被記錄和顯示。真正管控的是 prompt 次數與點數。

**一台伺服器可以同時管兩個訂閱嗎?**
目前不行。一個伺服器實例綁定一組 Claude 憑證。

---

## 專案結構

```
claude-code-limiter/
├── packages/
│   ├── cli/                      ← 客戶端 CLI 與 hook
│   │   ├── bin/cli.js
│   │   └── src/
│   │       ├── hook.js           ← 限流器本體（零 npm 相依）
│   │       └── installer.js      ← setup / sync / uninstall
│   ├── server/
│   │   ├── bin/server.js
│   │   ├── Dockerfile, docker-compose.yml, Caddyfile
│   │   └── src/
│   │       ├── server/
│   │       │   ├── index.js      ← Express 應用
│   │       │   ├── db.js         ← SQLite schema 與 migration
│   │       │   ├── ws.js         ← WebSocket 即時推送
│   │       │   ├── routes/       ← hook-api.js, admin-api.js
│   │       │   └── services/     ← limiter, usage, auth,
│   │       │                        subscription-usage
│   │       └── dashboard/        ← 實際被服務的儀表板（原生 JS）
│   │           ├── index.html
│   │           ├── css/style.css
│   │           └── js/app.js
│   └── dashboard/                ← React/Vite 原始碼,目前沒有被服務
├── web-terminal/server.js        ← 驗證 Access 的 ttyd proxy
├── make-client.sh                ← 建立某個人的連線包
├── provision-user.sh             ← 為共用主機模式建立 OS 帳號
├── sync-credentials.sh           ← 把憑證推給所有帳號
├── start-all.sh                  ← 伺服器 + tunnel + sshd + 瀏覽器終端機
├── web-terminal.sh, tunnel-*.sh, start.sh, stop.sh
├── SHARED-HOST.md                ← 共用主機的設計與威脅模型
└── tests/                        ← 從上游繼承的骨架,尚未實作
```

> **你看到的儀表板是 `packages/server/src/dashboard/`** —— 純 HTML、CSS、
> JavaScript,直接服務,沒有建置步驟。`packages/dashboard/` 裡是一份沒有建置的
> React 改寫版,**沒有**被接上;改它不會有任何效果。改完原生版本後記得強制重新整理。

---

## 開發

```bash
git clone https://github.com/torrentpien/claude-code-limiter.git
cd claude-code-limiter
npm install
ADMIN_PASSWORD=secret npm run serve
```

> **目前沒有測試套件。** `npm test` 只會印出 `TODO`,而 `tests/` 底下是從上游
> 繼承的骨架,裡面沒有任何斷言。請對著實際運行的伺服器驗證你的改動。

**開發準則**

- `packages/cli/src/hook.js` 必須維持**零相依** —— 只用 Node.js 內建模組。
- 伺服器是 Express + better-sqlite3 + ws。保持簡單。
- 被服務的儀表板是原生 HTML/CSS/JS —— 沒有建置步驟,沒有框架。
- **絕對不要 commit `dist/`** —— 連線包裡有私鑰。
- **絕對不要 commit 真實主機名稱** —— 它們該放在 `/etc/claude-code/site.env`。

---

## 致謝

本專案是
**[howincodes/claude-code-limiter](https://github.com/howincodes/claude-code-limiter)**
的衍生作品,原作者為 [howincodes](https://github.com/howincodes) 與
[farisbasha](https://github.com/farisbasha),以 MIT 授權釋出。

原始構想與這一切的基礎都是他們的:受管 hook 架構、四事件關卡、失效即封鎖的設計、
限制規則引擎、點數預算模型、看門狗,以及儀表板。上游完整的 commit 歷史都保留在這個
倉庫裡 —— `git log` 可以清楚看出哪些工作是誰做的。

本 fork 加入了共用主機部署、以 transcript 為基礎的 token 計量、訂閱上限監控、
Fable 支援、連線包,以及瀏覽器終端機。本專案獨立維護,與上游專案並無隸屬關係;
請不要把源自這裡的問題送給上游的維護者。

要追蹤上游:

```bash
git remote add upstream https://github.com/howincodes/claude-code-limiter.git
git fetch upstream
```

## 授權

[MIT](LICENSE)。

- 原始作品 © 2026 Basha —— <https://github.com/howincodes/claude-code-limiter>
- 修改部分 © 2026 torrentpien —— <https://github.com/torrentpien/claude-code-limiter>

---

<p align="center">
  <b>別再盲目共用。開始公平分配。</b>
</p>
