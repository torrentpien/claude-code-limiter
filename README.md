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
