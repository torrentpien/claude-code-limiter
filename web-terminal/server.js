#!/usr/bin/env node
/**
 * claude-code-limiter — browser terminal front door
 * =================================================
 * One ttyd runs per person (dropped to their uid, see web-terminal.sh). This
 * process is the only thing the tunnel talks to: it authenticates the request
 * against Cloudflare Access, maps the verified email to an OS account, and
 * proxies to that person's ttyd. Nobody can reach another person's terminal,
 * because the backend port is chosen from the JWT, never from the request.
 *
 * Auth: the Cf-Access-Jwt-Assertion header (or CF_Authorization cookie) is
 * verified for real — RS256 signature against the team's JWKS, plus exp/aud.
 * A forged header is rejected, so this does not rely on the tunnel being the
 * only reachable path.
 *
 * Config: /etc/claude-code/web-terminal.json
 *   { port, team_domain, aud, users: { "<email>": "<os-user>" } }
 *
 * Test mode (skips Access — never use with a public hostname attached):
 *   node server.js --test-email=someone@example.com
 */
"use strict";

const http = require("http");
const https = require("https");
const net = require("net");
const fs = require("fs");
const crypto = require("crypto");

const CONFIG_FILE =
  process.env.WEB_TERMINAL_CONFIG || "/etc/claude-code/web-terminal.json";
const PORTMAP_FILE =
  process.env.WEB_TERMINAL_PORTMAP || "/etc/claude-code/web-terminal-ports.json";

const testArg = process.argv.find((a) => a.startsWith("--test-email="));
const TEST_EMAIL = testArg ? testArg.split("=")[1] : null;

function loadJSON(p, fallback) {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return fallback;
  }
}

const cfg = loadJSON(CONFIG_FILE, {});
const PORT = cfg.port || 7680;
const TEAM_DOMAIN = cfg.team_domain || "";
const AUD = cfg.aud || "";
const EMAIL_MAP = cfg.users || {};

function ports() {
  return loadJSON(PORTMAP_FILE, {});
}

// ── Cloudflare Access JWT verification ──────────────────────────────────────
let jwksCache = { at: 0, keys: [] };

function fetchJWKS() {
  return new Promise((resolve) => {
    if (!TEAM_DOMAIN) return resolve([]);
    // Cache for an hour; Access rotates keys slowly and a stale hit only costs
    // one retry (verify() refetches when a kid is unknown).
    if (Date.now() - jwksCache.at < 3600e3 && jwksCache.keys.length)
      return resolve(jwksCache.keys);
    const url = `https://${TEAM_DOMAIN}/cdn-cgi/access/certs`;
    https
      .get(url, { timeout: 5000 }, (res) => {
        let body = "";
        res.on("data", (d) => (body += d));
        res.on("end", () => {
          try {
            const keys = JSON.parse(body).keys || [];
            jwksCache = { at: Date.now(), keys };
            resolve(keys);
          } catch {
            resolve(jwksCache.keys);
          }
        });
      })
      .on("error", () => resolve(jwksCache.keys))
      .on("timeout", function () {
        this.destroy();
        resolve(jwksCache.keys);
      });
  });
}

function b64urlToBuf(s) {
  return Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

async function verifyAccessJWT(token) {
  const parts = String(token || "").split(".");
  if (parts.length !== 3) return null;
  const [h64, p64, s64] = parts;

  let header, payload;
  try {
    header = JSON.parse(b64urlToBuf(h64).toString("utf8"));
    payload = JSON.parse(b64urlToBuf(p64).toString("utf8"));
  } catch {
    return null;
  }
  if (header.alg !== "RS256") return null;

  let keys = await fetchJWKS();
  let jwk = keys.find((k) => k.kid === header.kid);
  if (!jwk) {
    // Unknown kid: keys may have rotated since we cached them.
    jwksCache = { at: 0, keys: [] };
    keys = await fetchJWKS();
    jwk = keys.find((k) => k.kid === header.kid);
  }
  if (!jwk) return null;

  let ok = false;
  try {
    const pub = crypto.createPublicKey({ key: jwk, format: "jwk" });
    ok = crypto.verify(
      "RSA-SHA256",
      Buffer.from(`${h64}.${p64}`),
      pub,
      b64urlToBuf(s64)
    );
  } catch {
    return null;
  }
  if (!ok) return null;

  const now = Math.floor(Date.now() / 1000);
  if (payload.exp && payload.exp < now) return null;
  if (payload.nbf && payload.nbf > now + 60) return null;
  if (TEAM_DOMAIN && payload.iss && !payload.iss.includes(TEAM_DOMAIN)) return null;
  if (AUD) {
    const auds = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!auds.includes(AUD)) return null;
  }
  return payload;
}

function tokenFrom(req) {
  const h = req.headers["cf-access-jwt-assertion"];
  if (h) return h;
  const cookie = req.headers.cookie || "";
  const m = /(?:^|;\s*)CF_Authorization=([^;]+)/.exec(cookie);
  return m ? m[1] : null;
}

// Resolves the request to an OS user, or null. The backend port is derived
// from this — never from anything the client can set.
async function identify(req) {
  if (TEST_EMAIL) return { email: TEST_EMAIL, user: EMAIL_MAP[TEST_EMAIL] || null };
  const claims = await verifyAccessJWT(tokenFrom(req));
  if (!claims) return null;
  const email = String(claims.email || "").toLowerCase();
  return { email, user: EMAIL_MAP[email] || null };
}

function deny(res, code, msg) {
  res.writeHead(code, { "content-type": "text/html; charset=utf-8" });
  res.end(
    `<!doctype html><meta charset="utf-8">` +
      `<div style="font:16px/1.6 system-ui;max-width:34rem;margin:18vh auto;padding:0 1.5rem">` +
      `<h2 style="margin:0 0 .5rem">無法開啟終端機</h2><p>${msg}</p></div>`
  );
}

// ── Proxy ────────────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  let id;
  try {
    id = await identify(req);
  } catch {
    id = null;
  }
  if (!id) return deny(res, 403, "驗證失敗,請重新從 Cloudflare 登入。");
  if (!id.user)
    return deny(
      res,
      403,
      `帳號 <code>${id.email}</code> 尚未開通。<br>請聯絡管理者為你建立使用者。`
    );

  const port = ports()[id.user];
  if (!port) return deny(res, 503, `${id.user} 的終端機尚未啟動,請聯絡管理者。`);

  const up = http.request(
    {
      host: "127.0.0.1",
      port,
      method: req.method,
      path: req.url,
      headers: { ...req.headers, host: `127.0.0.1:${port}` },
    },
    (r) => {
      res.writeHead(r.statusCode, r.headers);
      r.pipe(res);
    }
  );
  up.on("error", () => deny(res, 502, "終端機後端沒有回應。"));
  req.pipe(up);
});

// ttyd carries the session over a WebSocket, so the upgrade must be
// authenticated and routed the same way as the initial page load.
server.on("upgrade", async (req, socket, head) => {
  let id;
  try {
    id = await identify(req);
  } catch {
    id = null;
  }
  const port = id && id.user ? ports()[id.user] : null;
  if (!port) {
    socket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
    return socket.destroy();
  }

  const backend = net.connect(port, "127.0.0.1", () => {
    const head_ =
      `${req.method} ${req.url} HTTP/1.1\r\n` +
      Object.entries({ ...req.headers, host: `127.0.0.1:${port}` })
        .map(([k, v]) =>
          Array.isArray(v) ? v.map((x) => `${k}: ${x}`).join("\r\n") : `${k}: ${v}`
        )
        .join("\r\n") +
      "\r\n\r\n";
    backend.write(head_);
    if (head && head.length) backend.write(head);
    socket.pipe(backend);
    backend.pipe(socket);
  });
  backend.on("error", () => socket.destroy());
  socket.on("error", () => backend.destroy());
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`web-terminal proxy on 127.0.0.1:${PORT}`);
  console.log(`  team   : ${TEAM_DOMAIN || "(unset — JWT cannot be verified)"}`);
  console.log(`  aud    : ${AUD || "(unset — audience not checked)"}`);
  console.log(`  users  : ${Object.keys(EMAIL_MAP).length} email mapping(s)`);
  if (TEST_EMAIL)
    console.log(`  !! TEST MODE as ${TEST_EMAIL} — Access is NOT enforced`);
});
