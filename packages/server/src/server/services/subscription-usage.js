'use strict';

/**
 * Subscription-level usage — the ceiling the limiter itself cannot see.
 *
 * The limiter tracks who used what. This tracks how much of the *shared
 * subscription* is left, which is a different question: everyone on this box
 * logs in as the same Claude account, so one exhausted weekly bucket blocks
 * every user at once regardless of their per-user quota.
 *
 * Source is the same endpoint Claude Code's own /status reads
 * (`fetchUtilization` in the CLI bundle). It reports percentages and reset
 * times only — no token or dollar figures are published for subscription
 * plans, so `limit_dollars` and friends come back null.
 */

const fs = require('fs');
const db = require('../db');

const CREDENTIALS_FILE =
  process.env.CLAUDE_CREDENTIALS_FILE || '/root/.claude/.credentials.json';
const USAGE_URL =
  process.env.CLAUDE_USAGE_URL || 'https://api.anthropic.com/api/oauth/usage';
const DEFAULT_INTERVAL_MS = 5 * 60 * 1000;
const REQUEST_TIMEOUT_MS = 15000;

let timer = null;

/**
 * The credentials file layout is undocumented and has changed shape before,
 * so walk it instead of hardcoding a path to the token.
 */
function findToken(node) {
  if (node && typeof node === 'object') {
    if (!Array.isArray(node)) {
      for (const [key, value] of Object.entries(node)) {
        if ((key === 'accessToken' || key === 'access_token') &&
            typeof value === 'string' && value) {
          return value;
        }
        const found = findToken(value);
        if (found) return found;
      }
      return null;
    }
    for (const item of node) {
      const found = findToken(item);
      if (found) return found;
    }
  }
  return null;
}

function readToken() {
  const raw = fs.readFileSync(CREDENTIALS_FILE, 'utf-8');
  const token = findToken(JSON.parse(raw));
  if (!token) throw new Error(`no access token in ${CREDENTIALS_FILE}`);
  return token;
}

/**
 * Human label for a limit entry. Scoped entries name their model; the rest
 * map to the same wording Claude Code's /status uses.
 */
function labelFor(entry) {
  const model = entry.scope && entry.scope.model && entry.scope.model.display_name;
  if (model) return `${model} (weekly)`;
  switch (entry.kind) {
    case 'session': return 'Session (5h)';
    case 'weekly_all': return 'Weekly (all models)';
    default: return entry.kind;
  }
}

/**
 * Normalize the API payload into rows.
 *
 * `limits[]` is the authoritative list — the top-level `five_hour` /
 * `seven_day` / `seven_day_*` keys duplicate a subset of it and are null for
 * buckets that don't apply, while model-specific caps (Fable) appear ONLY as
 * `weekly_scoped` entries inside `limits[]`.
 */
function normalize(payload) {
  const entries = Array.isArray(payload && payload.limits) ? payload.limits : [];
  return entries.map((entry) => ({
    kind: entry.kind || 'unknown',
    groupName: entry.group || null,
    label: labelFor(entry),
    scopeModel: (entry.scope && entry.scope.model && entry.scope.model.display_name) || null,
    // Already 0-100 on the wire, despite the field elsewhere being a fraction.
    percent: typeof entry.percent === 'number' ? entry.percent : null,
    severity: entry.severity || null,
    resetsAt: entry.resets_at || null,
    isActive: entry.is_active ? 1 : 0,
  }));
}

/**
 * Fetch and store one snapshot.
 * @returns {{ ok: boolean, rows?: object[], error?: string }}
 */
async function poll() {
  let token;
  try {
    token = readToken();
  } catch (err) {
    return { ok: false, error: `credentials: ${err.message}` };
  }

  const controller = new AbortController();
  const abort = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  let payload;
  try {
    const res = await fetch(USAGE_URL, {
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        'anthropic-beta': 'oauth-2025-04-20',
      },
      signal: controller.signal,
    });
    if (!res.ok) {
      return { ok: false, error: `HTTP ${res.status}` };
    }
    payload = await res.json();
  } catch (err) {
    return { ok: false, error: `${err.name}: ${err.message}` };
  } finally {
    clearTimeout(abort);
  }

  const rows = normalize(payload);
  if (!rows.length) return { ok: false, error: 'no limits in response' };

  const timestamp = new Date().toISOString();
  db.recordSubscriptionUsage(rows, timestamp);
  return { ok: true, rows, timestamp };
}

/**
 * Poll on an interval. One poller per box: every user shares one login, so
 * there is exactly one pool to watch.
 */
function start(intervalMs) {
  if (timer) return;
  const every = intervalMs || DEFAULT_INTERVAL_MS;

  const run = () => {
    poll().then((result) => {
      if (!result.ok) {
        console.warn(`[subscription-usage] poll failed: ${result.error}`);
        return;
      }
      const summary = result.rows
        .map((r) => `${r.label}=${r.percent}%`)
        .join(' ');
      console.log(`[subscription-usage] ${summary}`);
    });
  };

  run();
  timer = setInterval(run, every);
  if (timer.unref) timer.unref();
  console.log(`[subscription-usage] polling every ${Math.round(every / 1000)}s`);
}

function stop() {
  if (timer) {
    clearInterval(timer);
    timer = null;
  }
}

module.exports = { start, stop, poll, normalize };
