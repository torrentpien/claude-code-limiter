# @torrentpien/claude-code-limiter

Per-user rate limits and token accounting for [Claude Code](https://code.claude.com).
Share one subscription across your team, with enforced quotas.

This is the **client CLI** installed on each user's machine. It installs a
system-level hook that checks limits on every prompt and records token usage on
every completed turn.

For the server and dashboard, see
[`packages/server`](../server). For the whole project, see the
[main README](../../README.md).

> Derived from [howincodes/claude-code-limiter](https://github.com/howincodes/claude-code-limiter)
> (MIT). See [Credits](../../README.md#credits).

## Install

This package is **not published to npm**. Install from a clone:

```bash
git clone https://github.com/torrentpien/claude-code-limiter.git
cd claude-code-limiter && npm install
```

Your admin gives you an install code and a server URL:

```bash
sudo node packages/cli/bin/cli.js setup \
  --code CLM-alice-a8f3e2 \
  --server https://limiter.yourteam.com
```

Restart Claude Code. Done.

To get `claude-code-limiter` on your PATH instead of typing the full path, run
`npm link` once inside `packages/cli`.

## Commands

```bash
# Current usage and limits
claude-code-limiter status

# Force a sync with the server (requires sudo)
sudo claude-code-limiter sync

# Remove the limiter (requires sudo)
sudo claude-code-limiter uninstall
```

## What happens when you hit a limit

```
Daily opus limit reached.
Used 5/5 prompts today.

All usage today:
  fable:   2/10  (8 left)
  opus:    5/5   (0 left)
  sonnet: 12/20  (8 left)
  haiku:   3/40  (37 left)

Credit balance: 15/100

Options:
  Switch to another model (if quota remains)
  Try again later
```

## How it works

The installer writes a hook into Claude Code's `managed-settings.json` — the
highest-priority config, which user and project settings cannot override. The
hook checks limits on every prompt, counts usage on every completed turn, and
reads the session transcript to record the tokens that turn actually consumed.

- **Zero npm dependencies** — Node.js built-ins only
- **Works offline** — falls back to the local cache when the server is unreachable
- **Fail-closed** — missing config means blocked, not unlimited
- **Token accounting** — input / output / cache-write / cache-read per model,
  deduplicated by `requestId`, read incrementally from a byte offset
- **8 security layers** — managed settings, `allowManagedHooksOnly`, root-owned
  files, watchdog daemon, server-side tracking, kill switch, per-user tokens,
  fail-closed default

Token usage is **recorded, not enforced**. Prompt counts and credit budgets are
the gates.

## For admins

The [main README](../../README.md) covers server deployment, the dashboard, and
configuration. For running everyone on one shared box instead of on their own
laptops, see [SHARED-HOST.md](../../SHARED-HOST.md).

## Licence

MIT. Original work © 2026 Basha; modifications © 2026 torrentpien.
See [LICENSE](../../LICENSE).
