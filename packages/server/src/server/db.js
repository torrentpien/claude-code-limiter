'use strict';

const path = require('path');
const fs = require('fs');
const Database = require('better-sqlite3');
const { v4: uuidv4 } = require('uuid');
const bcrypt = require('bcryptjs');

let db = null;

/**
 * Initialize the database: open/create, set up tables, indexes.
 * @param {string} [dbPath] - Optional path to the SQLite file.
 */
function init(dbPath) {
  if (db) return db;

  if (!dbPath) {
    const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, '..', '..', 'data');
    dbPath = path.join(DATA_DIR, 'limiter.db');
  }

  const dataDir = path.dirname(dbPath);
  if (!fs.existsSync(dataDir)) {
    fs.mkdirSync(dataDir, { recursive: true });
  }

  db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');

  // Create tables
  db.exec(`
    CREATE TABLE IF NOT EXISTS team (
      id              TEXT PRIMARY KEY,
      name            TEXT NOT NULL,
      admin_password  TEXT NOT NULL,
      credit_weights  TEXT NOT NULL DEFAULT '{"opus":10,"sonnet":3,"haiku":1,"fable":20}',
      created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS user (
      id          TEXT PRIMARY KEY,
      team_id     TEXT NOT NULL REFERENCES team(id),
      slug        TEXT NOT NULL,
      name        TEXT NOT NULL,
      auth_token  TEXT NOT NULL UNIQUE,
      status      TEXT NOT NULL DEFAULT 'active',
      killed_at   DATETIME,
      last_seen   DATETIME,
      created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(team_id, slug)
    );

    CREATE TABLE IF NOT EXISTS limit_rule (
      id              TEXT PRIMARY KEY,
      user_id         TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
      type            TEXT NOT NULL,
      model           TEXT,
      window          TEXT,
      value           INTEGER,
      schedule_start  TEXT,
      schedule_end    TEXT,
      schedule_tz     TEXT,
      created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS usage_event (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id     TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
      model       TEXT NOT NULL,
      credit_cost INTEGER NOT NULL,
      timestamp   DATETIME NOT NULL,
      source      TEXT NOT NULL DEFAULT 'hook'
    );

    CREATE TABLE IF NOT EXISTS install_code (
      code        TEXT PRIMARY KEY,
      user_id     TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
      used        BOOLEAN DEFAULT 0,
      created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS device (
      id              TEXT PRIMARY KEY,
      user_id         TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
      hostname        TEXT,
      platform        TEXT,
      arch            TEXT,
      os_version      TEXT,
      node_version    TEXT,
      claude_version  TEXT,
      subscription_type TEXT,
      default_model   TEXT,
      first_seen      DATETIME DEFAULT CURRENT_TIMESTAMP,
      last_seen       DATETIME DEFAULT CURRENT_TIMESTAMP,
      last_ip         TEXT,
      UNIQUE(user_id, hostname)
    );

    CREATE TABLE IF NOT EXISTS session_event (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id         TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
      device_id       TEXT REFERENCES device(id),
      type            TEXT NOT NULL,
      model           TEXT,
      prompt_length   INTEGER,
      project_dir     TEXT,
      tools_used      INTEGER,
      session_id      TEXT,
      blocked_reason  TEXT,
      response_length INTEGER,
      timestamp       DATETIME NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_session_event_user_ts ON session_event(user_id, timestamp);
    CREATE INDEX IF NOT EXISTS idx_session_event_type ON session_event(user_id, type, timestamp);

    CREATE INDEX IF NOT EXISTS idx_usage_user_ts ON usage_event(user_id, timestamp);
    CREATE INDEX IF NOT EXISTS idx_usage_model_ts ON usage_event(user_id, model, timestamp);
    CREATE INDEX IF NOT EXISTS idx_user_auth_token ON user(auth_token);
    CREATE INDEX IF NOT EXISTS idx_user_team ON user(team_id);
    CREATE INDEX IF NOT EXISTS idx_limit_rule_user ON limit_rule(user_id);
    CREATE INDEX IF NOT EXISTS idx_install_code_user ON install_code(user_id);
    CREATE INDEX IF NOT EXISTS idx_device_user ON device(user_id);

    -- Token usage split by the model that actually served each response.
    -- Separate from usage_event because one turn can involve more than one
    -- model (subagents), while usage_event must stay exactly one row per turn
    -- or every COUNT(*)-based limit would break.
    CREATE TABLE IF NOT EXISTS token_event (
      id                 INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id            TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
      model              TEXT NOT NULL,
      input_tokens       INTEGER NOT NULL DEFAULT 0,
      output_tokens      INTEGER NOT NULL DEFAULT 0,
      cache_write_tokens INTEGER NOT NULL DEFAULT 0,
      cache_read_tokens  INTEGER NOT NULL DEFAULT 0,
      weighted_tokens    INTEGER NOT NULL DEFAULT 0,
      timestamp          DATETIME NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_token_user_ts ON token_event(user_id, timestamp);
    CREATE INDEX IF NOT EXISTS idx_token_model_ts ON token_event(user_id, model, timestamp);

    -- Snapshots of the shared Claude subscription's own limits. Not tied to a
    -- user: everyone on this box logs in as the same account, so this is one
    -- pool. Percentages only -- the upstream API publishes no token figures
    -- for subscription plans.
    CREATE TABLE IF NOT EXISTS subscription_usage (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      kind        TEXT NOT NULL,
      group_name  TEXT,
      label       TEXT NOT NULL,
      scope_model TEXT,
      percent     INTEGER,
      severity    TEXT,
      resets_at   DATETIME,
      is_active   INTEGER NOT NULL DEFAULT 0,
      timestamp   DATETIME NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_sub_usage_ts ON subscription_usage(timestamp);
    CREATE INDEX IF NOT EXISTS idx_sub_usage_kind_ts ON subscription_usage(kind, scope_model, timestamp);
  `);

  migrate();

  console.log(`Database initialized at ${dbPath}`);
  return db;
}

/**
 * Additive schema migrations for databases created before a column existed.
 * Every column added here must be nullable — existing rows keep NULL, which
 * reads as "recorded before token accounting" rather than "zero tokens".
 */
function migrate() {
  const cols = new Set(
    db.prepare('PRAGMA table_info(usage_event)').all().map(c => c.name)
  );
  const added = [
    ['input_tokens', 'INTEGER'],
    ['output_tokens', 'INTEGER'],
    ['cache_write_tokens', 'INTEGER'],
    ['cache_read_tokens', 'INTEGER'],
    ['weighted_tokens', 'INTEGER'],
  ].filter(([name]) => !cols.has(name));

  for (const [name, type] of added) {
    db.exec(`ALTER TABLE usage_event ADD COLUMN ${name} ${type}`);
  }
  if (added.length) {
    console.log(`Migrated usage_event: added ${added.map(c => c[0]).join(', ')}`);
  }
}

/**
 * Seed a default team if none exists.
 * @param {string} [adminPassword] - Plain-text admin password.
 */
function seed(adminPassword) {
  const conn = getDb();
  const row = conn.prepare('SELECT COUNT(*) AS count FROM team').get();
  if (row.count > 0) return;

  const password = adminPassword || process.env.ADMIN_PASSWORD || 'changeme';
  const hash = bcrypt.hashSync(password, 10);
  const teamId = uuidv4();

  conn.prepare(
    'INSERT INTO team (id, name, admin_password, credit_weights) VALUES (?, ?, ?, ?)'
  ).run(teamId, 'Default Team', hash, JSON.stringify({ opus: 10, sonnet: 3, haiku: 1, fable: 20 }));

  console.log(`Default team created (id: ${teamId})`);
  if (password === 'changeme') {
    console.warn('WARNING: Using default admin password "changeme". Set ADMIN_PASSWORD env var for production.');
  }
}

/**
 * Get the raw database instance.
 */
function getDb() {
  if (!db) throw new Error('Database not initialized. Call init() first.');
  return db;
}

/**
 * Close the database connection.
 */
function close() {
  if (db) {
    db.close();
    db = null;
  }
}

// --------------- Team helpers ---------------

function getTeam(teamId) {
  return getDb().prepare('SELECT * FROM team WHERE id = ?').get(teamId);
}

function getDefaultTeam() {
  return getDb().prepare('SELECT * FROM team ORDER BY created_at ASC LIMIT 1').get();
}

function updateTeam(teamId, fields) {
  const sets = [];
  const values = [];
  if (fields.name !== undefined) { sets.push('name = ?'); values.push(fields.name); }
  if (fields.credit_weights !== undefined) { sets.push('credit_weights = ?'); values.push(typeof fields.credit_weights === 'string' ? fields.credit_weights : JSON.stringify(fields.credit_weights)); }
  if (fields.admin_password !== undefined) { sets.push('admin_password = ?'); values.push(fields.admin_password); }
  if (sets.length === 0) return;
  values.push(teamId);
  getDb().prepare(`UPDATE team SET ${sets.join(', ')} WHERE id = ?`).run(...values);
}

// --------------- User helpers ---------------

function getUser(userId) {
  return getDb().prepare('SELECT * FROM user WHERE id = ?').get(userId);
}

function getUserByToken(authToken) {
  return getDb().prepare('SELECT * FROM user WHERE auth_token = ?').get(authToken);
}

function getUserBySlug(teamId, slug) {
  return getDb().prepare('SELECT * FROM user WHERE team_id = ? AND slug = ?').get(teamId, slug);
}

function getAllUsers(teamId) {
  return getDb().prepare('SELECT * FROM user WHERE team_id = ? ORDER BY created_at ASC').all(teamId);
}

function createUser({ teamId, slug, name }) {
  const id = uuidv4();
  const authToken = uuidv4();
  getDb().prepare(
    'INSERT INTO user (id, team_id, slug, name, auth_token) VALUES (?, ?, ?, ?, ?)'
  ).run(id, teamId, slug, name, authToken);
  return getUser(id);
}

function updateUser(userId, fields) {
  const sets = [];
  const values = [];
  if (fields.name !== undefined) { sets.push('name = ?'); values.push(fields.name); }
  if (fields.slug !== undefined) { sets.push('slug = ?'); values.push(fields.slug); }
  if (fields.status !== undefined) {
    sets.push('status = ?');
    values.push(fields.status);
    if (fields.status === 'killed') {
      sets.push('killed_at = ?');
      values.push(new Date().toISOString());
    } else if (fields.status === 'active') {
      sets.push('killed_at = NULL');
    }
  }
  if (fields.last_seen !== undefined) { sets.push('last_seen = ?'); values.push(fields.last_seen); }
  if (sets.length === 0) return;
  values.push(userId);
  getDb().prepare(`UPDATE user SET ${sets.join(', ')} WHERE id = ?`).run(...values);
}

function deleteUser(userId) {
  // Foreign keys with ON DELETE CASCADE handle related rows
  getDb().prepare('DELETE FROM user WHERE id = ?').run(userId);
}

// --------------- Limit Rule helpers ---------------

function getLimitRules(userId) {
  return getDb().prepare('SELECT * FROM limit_rule WHERE user_id = ? ORDER BY created_at ASC').all(userId);
}

function createLimitRule({ userId, type, model, window, value, schedule_start, schedule_end, schedule_tz }) {
  const id = uuidv4();
  getDb().prepare(
    'INSERT INTO limit_rule (id, user_id, type, model, window, value, schedule_start, schedule_end, schedule_tz) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
  ).run(id, userId, type, model || null, window || null, value != null ? value : null, schedule_start || null, schedule_end || null, schedule_tz || null);
  return getDb().prepare('SELECT * FROM limit_rule WHERE id = ?').get(id);
}

function deleteLimitRule(ruleId) {
  getDb().prepare('DELETE FROM limit_rule WHERE id = ?').run(ruleId);
}

function deleteLimitRulesForUser(userId) {
  getDb().prepare('DELETE FROM limit_rule WHERE user_id = ?').run(userId);
}

// --------------- Usage Event helpers ---------------

function recordUsage({ userId, model, creditCost, timestamp, source, tokens }) {
  const ts = timestamp || new Date().toISOString();
  const src = source || 'hook';
  const t = tokens || {};
  // NULL, not 0, when the client sent nothing — so "no token data" stays
  // distinguishable from "a turn that genuinely used none".
  const n = (v) => (typeof v === 'number' && isFinite(v) ? Math.round(v) : null);
  return getDb().prepare(
    `INSERT INTO usage_event
       (user_id, model, credit_cost, timestamp, source,
        input_tokens, output_tokens, cache_write_tokens, cache_read_tokens, weighted_tokens)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    userId, model, creditCost, ts, src,
    n(t.input), n(t.output), n(t.cache_write), n(t.cache_read), n(t.weighted)
  );
}

/**
 * Get usage event count by model for a user since a given timestamp.
 * Returns { opus: N, sonnet: N, haiku: N, default: N }
 */
function getUsage(userId, since) {
  const rows = getDb().prepare(
    'SELECT model, COUNT(*) AS count FROM usage_event WHERE user_id = ? AND timestamp >= ? GROUP BY model'
  ).all(userId, since);

  const result = { opus: 0, sonnet: 0, haiku: 0, fable: 0, default: 0 };
  for (const row of rows) {
    result[row.model] = row.count;
  }
  return result;
}

/**
 * Get usage with credit sums for a user since a given timestamp.
 */
function getUsageWithCredits(userId, since) {
  const rows = getDb().prepare(
    'SELECT model, COUNT(*) AS count, SUM(credit_cost) AS total_credits FROM usage_event WHERE user_id = ? AND timestamp >= ? GROUP BY model'
  ).all(userId, since);

  const counts = { opus: 0, sonnet: 0, haiku: 0, fable: 0, default: 0 };
  let totalCredits = 0;
  for (const row of rows) {
    counts[row.model] = row.count;
    totalCredits += row.total_credits;
  }
  // Tokens come from token_event, not from usage_event's per-turn columns:
  // a turn attributes its whole token spend to one model, which is wrong
  // whenever a subagent ran on a different one.
  const { tokens, tokensByModel } = getTokenUsage(userId, since);
  return { counts, totalCredits, tokens, tokensByModel };
}

function emptyTokenTotals() {
  return { input: 0, output: 0, cache_write: 0, cache_read: 0, weighted: 0 };
}

// --------------- Subscription usage (shared account ceiling) ---------------

/**
 * Store one poll's worth of limit rows.
 * @param {object[]} rows - from services/subscription-usage normalize()
 * @param {string} timestamp - ISO string; identical across the batch
 */
function recordSubscriptionUsage(rows, timestamp) {
  if (!rows || !rows.length) return 0;
  const ts = timestamp || new Date().toISOString();
  const stmt = getDb().prepare(
    `INSERT INTO subscription_usage
       (kind, group_name, label, scope_model, percent, severity, resets_at, is_active, timestamp)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  );
  const insertAll = getDb().transaction((items) => {
    for (const r of items) {
      stmt.run(
        r.kind, r.groupName, r.label, r.scopeModel,
        r.percent, r.severity, r.resetsAt, r.isActive, ts
      );
    }
  });
  insertAll(rows);
  return rows.length;
}

/**
 * The most recent snapshot, as a list of limits.
 * Buckets come and go between polls (a scoped cap only appears once the
 * upstream account has one), so select by the newest timestamp rather than
 * assuming a fixed set of rows.
 */
function getLatestSubscriptionUsage() {
  const latest = getDb()
    .prepare('SELECT MAX(timestamp) AS ts FROM subscription_usage')
    .get();
  if (!latest || !latest.ts) return { timestamp: null, limits: [] };

  const limits = getDb().prepare(
    `SELECT kind, group_name, label, scope_model, percent, severity, resets_at, is_active
       FROM subscription_usage
      WHERE timestamp = ?
      ORDER BY id`
  ).all(latest.ts);

  return { timestamp: latest.ts, limits };
}

/**
 * History for one bucket, oldest first — for charting a burn-down.
 */
function getSubscriptionUsageHistory(kind, scopeModel, since) {
  return getDb().prepare(
    `SELECT percent, severity, resets_at, timestamp
       FROM subscription_usage
      WHERE kind = ?
        AND (scope_model IS ? OR scope_model = ?)
        AND timestamp >= ?
      ORDER BY timestamp`
  ).all(kind, scopeModel || null, scopeModel || null, since);
}

function cleanupOldSubscriptionUsage(days) {
  const cutoff = new Date(Date.now() - (days || 30) * 86400000).toISOString();
  return getDb()
    .prepare('DELETE FROM subscription_usage WHERE timestamp < ?')
    .run(cutoff);
}

/**
 * Record the per-model token split for one turn.
 * @param {string} userId
 * @param {object} byModel - { fable: {input, output, cache_write, cache_read, weighted}, … }
 * @param {string} timestamp
 */
function recordTokensByModel(userId, byModel, timestamp) {
  if (!byModel) return 0;
  const ts = timestamp || new Date().toISOString();
  const stmt = getDb().prepare(
    `INSERT INTO token_event
       (user_id, model, input_tokens, output_tokens,
        cache_write_tokens, cache_read_tokens, weighted_tokens, timestamp)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  );
  let n = 0;
  const insertAll = getDb().transaction((entries) => {
    for (const [model, t] of entries) {
      stmt.run(userId, model, t.input, t.output, t.cache_write, t.cache_read, t.weighted, ts);
      n++;
    }
  });
  insertAll(Object.entries(byModel));
  return n;
}

/**
 * Token totals since a timestamp, overall and split by model.
 */
function getTokenUsage(userId, since) {
  const rows = getDb().prepare(
    `SELECT model,
            SUM(input_tokens)       AS input,
            SUM(output_tokens)      AS output,
            SUM(cache_write_tokens) AS cache_write,
            SUM(cache_read_tokens)  AS cache_read,
            SUM(weighted_tokens)    AS weighted
       FROM token_event
      WHERE user_id = ? AND timestamp >= ?
      GROUP BY model`
  ).all(userId, since);

  const tokens = emptyTokenTotals();
  const tokensByModel = {};
  for (const row of rows) {
    const t = {
      input: row.input, output: row.output,
      cache_write: row.cache_write, cache_read: row.cache_read,
      weighted: row.weighted,
    };
    tokensByModel[row.model] = t;
    for (const k of Object.keys(tokens)) tokens[k] += t[k];
  }
  return { tokens, tokensByModel };
}

/**
 * Get usage for a specific window type.
 * @param {string} userId
 * @param {string} windowType - daily | weekly | monthly | sliding_24h
 * @param {string} [tz] - IANA timezone (default UTC)
 * @returns {{ counts: object, totalCredits: number, windowStart: string }}
 */
function getUsageForWindow(userId, windowType, tz) {
  const windowStart = calculateWindowStart(windowType, tz);
  const data = getUsageWithCredits(userId, windowStart);
  return { ...data, windowStart };
}

/**
 * Calculate the start of a window in ISO string.
 */
function calculateWindowStart(windowType, tz) {
  const now = new Date();

  if (windowType === 'sliding_24h') {
    return new Date(now.getTime() - 24 * 60 * 60 * 1000).toISOString();
  }

  // For daily/weekly/monthly we compute midnight in the given timezone
  // then convert back to UTC ISO string for the DB query.
  const timeZone = tz || 'UTC';

  // Get current date parts in the target timezone
  const parts = getDatePartsInTZ(now, timeZone);

  let year = parts.year;
  let month = parts.month; // 1-based
  let day = parts.day;

  if (windowType === 'daily') {
    // midnight today in the timezone
  } else if (windowType === 'weekly') {
    // Monday of this week
    const dayOfWeek = parts.dayOfWeek; // 0=Sun, 1=Mon, ...
    const daysToSubtract = dayOfWeek === 0 ? 6 : dayOfWeek - 1;
    const dt = new Date(year, month - 1, day - daysToSubtract);
    year = dt.getFullYear();
    month = dt.getMonth() + 1;
    day = dt.getDate();
  } else if (windowType === 'monthly') {
    day = 1;
  }

  // Build a date string in the target timezone and convert to UTC
  // Create the local midnight in the target timezone
  const localMidnight = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}T00:00:00`;

  // Use a trick: compute the UTC offset for this date in this timezone
  const utcDate = localDateToUTC(localMidnight, timeZone);
  return utcDate.toISOString();
}

/**
 * Get date components in a given timezone.
 */
function getDatePartsInTZ(date, timeZone) {
  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
    weekday: 'short',
    hour: 'numeric',
    minute: 'numeric',
    // hour12:false renders midnight as hour "24", which pushed window starts
    // back a full day for UTC-offset-0 timezones; h23 keeps midnight at "00".
    hourCycle: 'h23',
  });
  const parts = formatter.formatToParts(date);
  const map = {};
  for (const p of parts) {
    map[p.type] = p.value;
  }
  const dayOfWeekMap = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  return {
    year: parseInt(map.year, 10),
    month: parseInt(map.month, 10),
    day: parseInt(map.day, 10),
    hour: parseInt(map.hour, 10) % 24,
    minute: parseInt(map.minute, 10),
    dayOfWeek: dayOfWeekMap[map.weekday] ?? 0,
  };
}

/**
 * Convert a local date string (without TZ info) in a given timezone to a UTC Date object.
 */
function localDateToUTC(localDateStr, timeZone) {
  // Parse the local date string
  const [datePart, timePart] = localDateStr.split('T');
  const [year, month, day] = datePart.split('-').map(Number);
  const [hour, minute, second] = (timePart || '00:00:00').split(':').map(Number);

  // Create a date in UTC first, then figure out the offset for this timezone
  const utcGuess = new Date(Date.UTC(year, month - 1, day, hour, minute, second || 0));

  // Get what the local time would be at this UTC time in the target timezone
  const inTZ = getDatePartsInTZ(utcGuess, timeZone);

  // The offset in minutes: inTZ time - utcGuess time
  const utcMinutes = utcGuess.getUTCHours() * 60 + utcGuess.getUTCMinutes();
  const tzMinutes = inTZ.hour * 60 + inTZ.minute;

  // Day difference handling
  let offsetMinutes = tzMinutes - utcMinutes;

  // Handle day boundary: if the tz date differs from UTC date, adjust
  const utcDay = utcGuess.getUTCDate();
  if (inTZ.day > utcDay) {
    offsetMinutes += 24 * 60;
  } else if (inTZ.day < utcDay) {
    offsetMinutes -= 24 * 60;
  }

  // The actual UTC time = local time - offset
  return new Date(utcGuess.getTime() - offsetMinutes * 60 * 1000);
}

/**
 * Get recent events for a user or all users.
 */
function getRecentEvents({ userId, limit, teamId }) {
  const lim = limit || 50;
  if (userId) {
    return getDb().prepare(
      'SELECT e.*, u.name AS user_name, u.slug AS user_slug FROM usage_event e JOIN user u ON e.user_id = u.id WHERE e.user_id = ? ORDER BY e.timestamp DESC LIMIT ?'
    ).all(userId, lim);
  }
  if (teamId) {
    return getDb().prepare(
      'SELECT e.*, u.name AS user_name, u.slug AS user_slug FROM usage_event e JOIN user u ON e.user_id = u.id WHERE u.team_id = ? ORDER BY e.timestamp DESC LIMIT ?'
    ).all(teamId, lim);
  }
  return getDb().prepare(
    'SELECT e.*, u.name AS user_name, u.slug AS user_slug FROM usage_event e JOIN user u ON e.user_id = u.id ORDER BY e.timestamp DESC LIMIT ?'
  ).all(lim);
}

/**
 * Delete events older than N days.
 */
function cleanupOldEvents(days) {
  const cutoff = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
  return getDb().prepare('DELETE FROM usage_event WHERE timestamp < ?').run(cutoff);
}

// --------------- Install Code helpers ---------------

function createInstallCode(userId) {
  // Generate a human-readable code: CLM-<slug-prefix>-<random>
  const user = getUser(userId);
  const prefix = user ? user.slug.substring(0, 8) : 'user';
  const random = uuidv4().substring(0, 6);
  const code = `CLM-${prefix}-${random}`;

  getDb().prepare(
    'INSERT INTO install_code (code, user_id) VALUES (?, ?)'
  ).run(code, userId);

  return code;
}

function useInstallCode(code) {
  const row = getDb().prepare('SELECT * FROM install_code WHERE code = ? AND used = 0').get(code);
  if (!row) return null;

  getDb().prepare('UPDATE install_code SET used = 1 WHERE code = ?').run(code);
  return row;
}

// --------------- Device helpers ---------------

/**
 * Upsert a device record for a user.
 * @param {string} userId
 * @param {object} deviceInfo - { hostname, platform, arch, os_version, node_version, claude_version, subscription_type, default_model, ip }
 * @returns {object} the device row
 */
function upsertDevice(userId, deviceInfo) {
  const hostname = deviceInfo.hostname || 'unknown';
  const existing = getDb().prepare(
    'SELECT * FROM device WHERE user_id = ? AND hostname = ?'
  ).get(userId, hostname);

  if (existing) {
    const sets = ['last_seen = ?'];
    const values = [new Date().toISOString()];
    if (deviceInfo.platform) { sets.push('platform = ?'); values.push(deviceInfo.platform); }
    if (deviceInfo.arch) { sets.push('arch = ?'); values.push(deviceInfo.arch); }
    if (deviceInfo.os_version) { sets.push('os_version = ?'); values.push(deviceInfo.os_version); }
    if (deviceInfo.node_version) { sets.push('node_version = ?'); values.push(deviceInfo.node_version); }
    if (deviceInfo.claude_version) { sets.push('claude_version = ?'); values.push(deviceInfo.claude_version); }
    if (deviceInfo.subscription_type) { sets.push('subscription_type = ?'); values.push(deviceInfo.subscription_type); }
    if (deviceInfo.default_model) { sets.push('default_model = ?'); values.push(deviceInfo.default_model); }
    if (deviceInfo.ip) { sets.push('last_ip = ?'); values.push(deviceInfo.ip); }
    values.push(existing.id);
    getDb().prepare(`UPDATE device SET ${sets.join(', ')} WHERE id = ?`).run(...values);
    return getDb().prepare('SELECT * FROM device WHERE id = ?').get(existing.id);
  } else {
    const id = uuidv4();
    getDb().prepare(
      `INSERT INTO device (id, user_id, hostname, platform, arch, os_version, node_version, claude_version, subscription_type, default_model, last_ip)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).run(
      id, userId, hostname,
      deviceInfo.platform || null,
      deviceInfo.arch || null,
      deviceInfo.os_version || null,
      deviceInfo.node_version || null,
      deviceInfo.claude_version || null,
      deviceInfo.subscription_type || null,
      deviceInfo.default_model || null,
      deviceInfo.ip || null
    );
    return getDb().prepare('SELECT * FROM device WHERE id = ?').get(id);
  }
}

/**
 * Get all devices for a user.
 * @param {string} userId
 * @returns {Array}
 */
function getDevices(userId) {
  return getDb().prepare('SELECT * FROM device WHERE user_id = ? ORDER BY last_seen DESC').all(userId);
}

/**
 * Get all devices for a team.
 * @param {string} teamId
 * @returns {Array}
 */
function getDevicesByTeam(teamId) {
  return getDb().prepare(
    `SELECT d.*, u.name AS user_name, u.slug AS user_slug
     FROM device d
     JOIN user u ON d.user_id = u.id
     WHERE u.team_id = ?
     ORDER BY d.last_seen DESC`
  ).all(teamId);
}

// --------------- Session Event helpers ---------------

/**
 * Record a session event.
 * @param {object} data - { user_id, device_id, type, model, prompt_length, project_dir, tools_used, session_id, blocked_reason, response_length, timestamp }
 */
function recordSessionEvent(data) {
  const ts = data.timestamp || new Date().toISOString();
  return getDb().prepare(
    `INSERT INTO session_event (user_id, device_id, type, model, prompt_length, project_dir, tools_used, session_id, blocked_reason, response_length, timestamp)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    data.user_id,
    data.device_id || null,
    data.type,
    data.model || null,
    data.prompt_length != null ? data.prompt_length : null,
    data.project_dir || null,
    data.tools_used != null ? data.tools_used : null,
    data.session_id || null,
    data.blocked_reason || null,
    data.response_length != null ? data.response_length : null,
    ts
  );
}

/**
 * Get session events for a user with optional filters.
 * @param {string} userId
 * @param {object} [opts] - { since, type, limit }
 * @returns {Array}
 */
function getSessionEvents(userId, opts) {
  opts = opts || {};
  const conditions = ['user_id = ?'];
  const params = [userId];

  if (opts.since) {
    conditions.push('timestamp >= ?');
    params.push(opts.since);
  }
  if (opts.type) {
    conditions.push('type = ?');
    params.push(opts.type);
  }

  const lim = opts.limit || 100;
  params.push(lim);

  return getDb().prepare(
    `SELECT * FROM session_event WHERE ${conditions.join(' AND ')} ORDER BY timestamp DESC LIMIT ?`
  ).all(...params);
}

/**
 * Get analytics data for a team.
 * @param {string} teamId
 * @param {object} [opts] - { days, user_id }
 * @returns {object} Analytics data
 */
function getAnalytics(teamId, opts) {
  opts = opts || {};
  const days = opts.days || 7;
  const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();

  const userFilter = opts.user_id ? ' AND se.user_id = ?' : '';
  const userFilterParams = opts.user_id ? [opts.user_id] : [];

  // Peak usage hours (group by hour of day, count events)
  const peakHours = getDb().prepare(
    `SELECT CAST(strftime('%H', se.timestamp) AS INTEGER) AS hour, COUNT(*) AS count
     FROM session_event se
     JOIN user u ON se.user_id = u.id
     WHERE u.team_id = ? AND se.timestamp >= ? AND se.type = 'prompt'${userFilter}
     GROUP BY hour
     ORDER BY hour`
  ).all(teamId, since, ...userFilterParams);

  // Per-project usage
  const projectUsage = getDb().prepare(
    `SELECT se.project_dir AS project, COUNT(*) AS count
     FROM session_event se
     JOIN user u ON se.user_id = u.id
     WHERE u.team_id = ? AND se.timestamp >= ? AND se.type = 'prompt' AND se.project_dir IS NOT NULL${userFilter}
     GROUP BY se.project_dir
     ORDER BY count DESC
     LIMIT 20`
  ).all(teamId, since, ...userFilterParams);

  // Model distribution
  const modelDistRows = getDb().prepare(
    `SELECT se.model, COUNT(*) AS count
     FROM session_event se
     JOIN user u ON se.user_id = u.id
     WHERE u.team_id = ? AND se.timestamp >= ? AND se.type = 'prompt' AND se.model IS NOT NULL${userFilter}
     GROUP BY se.model`
  ).all(teamId, since, ...userFilterParams);
  const modelDistribution = {};
  for (const row of modelDistRows) {
    modelDistribution[row.model] = row.count;
  }

  // Daily active users
  const dailyActive = getDb().prepare(
    `SELECT DATE(se.timestamp) AS date, COUNT(DISTINCT se.user_id) AS users
     FROM session_event se
     JOIN user u ON se.user_id = u.id
     WHERE u.team_id = ? AND se.timestamp >= ?${userFilter}
     GROUP BY DATE(se.timestamp)
     ORDER BY date`
  ).all(teamId, since, ...userFilterParams);

  // Block rate
  const totalPrompts = getDb().prepare(
    `SELECT COUNT(*) AS count FROM session_event se
     JOIN user u ON se.user_id = u.id
     WHERE u.team_id = ? AND se.timestamp >= ? AND se.type = 'prompt'${userFilter}`
  ).get(teamId, since, ...userFilterParams);

  const blockedCount = getDb().prepare(
    `SELECT COUNT(*) AS count FROM session_event se
     JOIN user u ON se.user_id = u.id
     WHERE u.team_id = ? AND se.timestamp >= ? AND se.type = 'blocked'${userFilter}`
  ).get(teamId, since, ...userFilterParams);

  const total = totalPrompts.count;
  const blocked = blockedCount.count;
  const blockRate = { total, blocked, rate: total > 0 ? +(blocked / total).toFixed(4) : 0 };

  // Average prompt length
  const avgPromptRow = getDb().prepare(
    `SELECT AVG(se.prompt_length) AS avg_len FROM session_event se
     JOIN user u ON se.user_id = u.id
     WHERE u.team_id = ? AND se.timestamp >= ? AND se.type = 'prompt' AND se.prompt_length IS NOT NULL${userFilter}`
  ).get(teamId, since, ...userFilterParams);
  const avgPromptLength = avgPromptRow.avg_len ? Math.round(avgPromptRow.avg_len) : 0;

  // Average response length
  const avgRespRow = getDb().prepare(
    `SELECT AVG(se.response_length) AS avg_len FROM session_event se
     JOIN user u ON se.user_id = u.id
     WHERE u.team_id = ? AND se.timestamp >= ? AND se.type = 'turn_complete' AND se.response_length IS NOT NULL${userFilter}`
  ).get(teamId, since, ...userFilterParams);
  const avgResponseLength = avgRespRow.avg_len ? Math.round(avgRespRow.avg_len) : 0;

  // Average prompts per session
  const sessionCounts = getDb().prepare(
    `SELECT se.session_id, COUNT(*) AS count
     FROM session_event se
     JOIN user u ON se.user_id = u.id
     WHERE u.team_id = ? AND se.timestamp >= ? AND se.type = 'prompt' AND se.session_id IS NOT NULL${userFilter}
     GROUP BY se.session_id`
  ).all(teamId, since, ...userFilterParams);
  let avgPromptsPerSession = 0;
  if (sessionCounts.length > 0) {
    const totalSessionPrompts = sessionCounts.reduce((sum, r) => sum + r.count, 0);
    avgPromptsPerSession = +(totalSessionPrompts / sessionCounts.length).toFixed(1);
  }

  // Devices
  const devicesQuery = opts.user_id
    ? getDb().prepare('SELECT * FROM device WHERE user_id = ? ORDER BY last_seen DESC').all(opts.user_id)
    : getDevicesByTeam(teamId);

  return {
    peak_hours: peakHours,
    model_distribution: modelDistribution,
    project_usage: projectUsage,
    daily_active: dailyActive,
    block_rate: blockRate,
    avg_prompt_length: avgPromptLength,
    avg_response_length: avgResponseLength,
    avg_prompts_per_session: avgPromptsPerSession,
    devices: devicesQuery,
  };
}

module.exports = {
  init,
  seed,
  close,
  getDb,
  // Team
  getTeam,
  getDefaultTeam,
  updateTeam,
  // User
  getUser,
  getUserByToken,
  getUserBySlug,
  getAllUsers,
  createUser,
  updateUser,
  deleteUser,
  // Limit Rules
  getLimitRules,
  createLimitRule,
  deleteLimitRule,
  deleteLimitRulesForUser,
  // Usage
  recordUsage,
  recordTokensByModel,
  getTokenUsage,
  recordSubscriptionUsage,
  getLatestSubscriptionUsage,
  getSubscriptionUsageHistory,
  cleanupOldSubscriptionUsage,
  getUsage,
  getUsageWithCredits,
  getUsageForWindow,
  getRecentEvents,
  cleanupOldEvents,
  // Install Codes
  createInstallCode,
  useInstallCode,
  // Device
  upsertDevice,
  getDevices,
  getDevicesByTeam,
  // Session Events / Analytics
  recordSessionEvent,
  getSessionEvents,
  getAnalytics,
  // Helpers (exported for services)
  calculateWindowStart,
  getDatePartsInTZ,
};
