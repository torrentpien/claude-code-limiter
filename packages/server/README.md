# @torrentpien/claude-code-limiter-server

Dashboard server for [claude-code-limiter](https://github.com/torrentpien/claude-code-limiter).
Manage per-user rate limits, token accounting, and subscription monitoring for a
shared Claude Code subscription.

This is the **admin server** — REST API + SQLite + real-time dashboard. Deploy it
once, manage everyone from the browser.

For the client CLI, see [`packages/cli`](../cli).

> Derived from [howincodes/claude-code-limiter](https://github.com/howincodes/claude-code-limiter)
> (MIT). See [Credits](../../README.md#credits).

## Deploy

### Docker

```bash
docker build -t claude-code-limiter .
docker run -d --name claude-limiter -p 3000:3000 \
  -v claude-limiter-data:/data \
  -e ADMIN_PASSWORD=your-secure-password \
  claude-code-limiter
```

### Docker Compose with auto-HTTPS

```bash
DOMAIN=limiter.yourdomain.com ADMIN_PASSWORD=secret docker compose up -d
```

Caddy handles the certificates.

### From source

```bash
git clone https://github.com/torrentpien/claude-code-limiter.git
cd claude-code-limiter && npm install
ADMIN_PASSWORD=secret npm run serve
```

Reachable at `http://<this-machine>:3000` from anywhere on the network.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `ADMIN_PASSWORD` | yes, first run | — | Dashboard login password |
| `PORT` | no | `3000` | Server port |
| `JWT_SECRET` | no | auto-generated | Set it to keep admin sessions across restarts |
| `DATA_DIR` | no | `./data`, or `/data` in Docker | SQLite location |

## Dashboard

Open `https://your-server/dashboard` and log in.

- **Overview** — every user at a glance: status, usage bars, credits, live event
  feed, plus a subscription card showing the plan's own 5-hour, weekly, and
  Fable-weekly meters with time-to-reset
- **User detail** — credit gauge, per-model bars, per-model token usage, monthly
  trends, limits editor
- **Add user** — create a user, set limits, get a one-time install code
- **Settings** — credit weights, team name, admin password

> The dashboard actually served is `src/dashboard/` — plain HTML, CSS, and JS
> with no build step. The React source in `packages/dashboard/` is **not** wired
> up. Hard-refresh the browser after editing the vanilla bundle.

## API

### Hook API — used by the CLI on each machine

| Endpoint | Purpose |
|---|---|
| `POST /api/v1/register` | Exchange an install code for an auth token |
| `POST /api/v1/sync` | Session start: sync config, report the model |
| `POST /api/v1/check` | The gate: is this prompt allowed? |
| `POST /api/v1/count` | Record a completed turn, with its token usage |
| `GET  /api/v1/health` | Health check for Docker and load balancers |

Token payloads are sanitised server-side: models are checked against a
whitelist, and the weighted total is **recomputed** rather than trusted.

### Admin API — used by the dashboard

| Endpoint | Purpose |
|---|---|
| `POST   /api/admin/login` | Authenticate, get a JWT |
| `GET    /api/admin/users` | List users with live usage |
| `POST   /api/admin/users` | Create a user + install code |
| `PUT    /api/admin/users/:id` | Update limits, kill, pause, reinstate |
| `DELETE /api/admin/users/:id` | Remove a user |
| `GET    /api/admin/usage` | Usage history for the charts |
| `GET    /api/admin/subscription-usage` | Plan meters; `?refresh=1` forces a live poll |
| `PUT    /api/admin/settings` | Credit weights, team name |

### WebSocket

Connect to `/ws` for `user_check`, `user_blocked`, `user_counted`, and
`user_status_change` events.

## Schema

| Table | Contents |
|---|---|
| `usage_event` | **One row per turn.** The prompt limits are `COUNT(*)` over this, so it must not be diluted |
| `token_event` | Per-model token detail, so a turn that switches models is attributed correctly |
| `subscription_usage` | Polled plan-meter readings, kept as history |
| `user`, `limit_rule`, `install_code`, `device`, `session_event`, `team` | The rest |

Migrations are idempotent and add only nullable columns, so an existing database
upgrades in place.

## Features

- **Per-model limits** — `fable: 10/day, opus: 5/day, sonnet: 20/day`
- **Credit budgets** — one budget across all models
- **Sliding windows** — rolling 24h, or daily / weekly / monthly resets
- **Time-of-day rules** — expensive models during working hours only
- **Kill switch** — block a user instantly
- **Token accounting** — recorded per user, per model, per turn (not enforced)
- **Subscription monitoring** — background poll of the plan's own usage meters
- **Live dashboard** — real-time updates over WebSocket
- **SQLite** — one file, no configuration, just mount a volume

## Licence

MIT. Original work © 2026 Basha; modifications © 2026 torrentpien.
See [LICENSE](../../LICENSE).
