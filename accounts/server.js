// MangoIDE accounts server
// - Sign in with GitHub (OAuth). Session tokens are random, sent to the app once, and stored here only as SHA-256 hashes.
// - GitHub access tokens are encrypted at rest (AES-256-GCM).
// - Payments go through Stripe Checkout: card details never reach this server or the app.
// - Stripe webhooks are signature-checked; credits use an idempotent ledger so nothing is counted twice.
// - AI requests paid with credits are checked against the balance first, one at a time per user.

const http = require("http");
const crypto = require("crypto");
const { Pool } = require("pg");

const PORT = Number(process.env.PORT || 8080);
const PUBLIC_URL = (process.env.PUBLIC_URL || "").replace(/\/+$/, "");
const APP_SCHEME = "mangoide";
const GITHUB_CLIENT_ID = process.env.GITHUB_CLIENT_ID || "";
const GITHUB_CLIENT_SECRET = process.env.GITHUB_CLIENT_SECRET || "";
const TOKEN_ENC_KEY = process.env.TOKEN_ENC_KEY ? Buffer.from(process.env.TOKEN_ENC_KEY, "base64") : null;
const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY || "";
const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET || "";
const ANTHROPIC_KEY = process.env.ANTHROPIC_API_KEY || "";
const PRO_PRICE_CENTS = Number(process.env.PRO_PRICE_CENTS || 499);
const AI_MARKUP = Number(process.env.AI_MARKUP || 1.5);
const TOPUPS = (process.env.TOPUP_OPTIONS || "500,1000,2000").split(",").map(Number).filter((n) => n >= 100);
const SESSION_DAYS = 90;
// GitHub account IDs (numbers, not usernames, so a renamed account can't take it) that get Pro for free.
const PRO_GITHUB_IDS = new Set((process.env.PRO_GITHUB_IDS || "").split(",").map((s) => s.trim()).filter(Boolean));

const stripe = STRIPE_SECRET_KEY ? require("stripe")(STRIPE_SECRET_KEY) : null;
const db = new Pool({ connectionString: process.env.DATABASE_URL, max: 10, ssl: process.env.DATABASE_URL?.includes("railway.internal") ? false : { rejectUnauthorized: false } });

// Prices per million tokens (USD), matching Anthropic's list prices. Credits are stored in micro-dollars.
const MODEL_PRICES = {
  "claude-haiku-5-5": { input: 0.10, output: 0.50, cacheWrite: 0.125, cacheRead: 0.01 },
  "claude-sonnet-5-5": { input: 2, output: 10, cacheWrite: 2.5, cacheRead: 0.10 },
  "claude-opus-5-5": { input: 4, output: 20, cacheWrite: 5, cacheRead: 0.20 },
};

// ---------- Database ----------

async function migrate() {
  await db.query(`
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      github_id BIGINT UNIQUE NOT NULL,
      login TEXT NOT NULL,
      name TEXT,
      avatar_url TEXT,
      github_token_enc TEXT,
      stripe_customer_id TEXT UNIQUE,
      pro_status TEXT NOT NULL DEFAULT 'none',
      pro_until TIMESTAMPTZ,
      credits_micro BIGINT NOT NULL DEFAULT 0,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE TABLE IF NOT EXISTS sessions (
      id SERIAL PRIMARY KEY,
      user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token_hash TEXT UNIQUE NOT NULL,
      device TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      last_used TIMESTAMPTZ NOT NULL DEFAULT now(),
      expires_at TIMESTAMPTZ NOT NULL,
      revoked BOOLEAN NOT NULL DEFAULT false
    );
    CREATE TABLE IF NOT EXISTS ledger (
      id SERIAL PRIMARY KEY,
      user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      delta_micro BIGINT NOT NULL,
      reason TEXT NOT NULL,
      ref TEXT UNIQUE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE TABLE IF NOT EXISTS oauth_states (
      state TEXT PRIMARY KEY,
      app_state TEXT NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  `);
}

// ---------- Helpers ----------

const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");
const randomToken = (bytes = 32) => crypto.randomBytes(bytes).toString("base64url");

function encrypt(text) {
  if (!TOKEN_ENC_KEY || TOKEN_ENC_KEY.length !== 32) throw new Error("TOKEN_ENC_KEY missing");
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv("aes-256-gcm", TOKEN_ENC_KEY, iv);
  const enc = Buffer.concat([c.update(text, "utf8"), c.final()]);
  return Buffer.concat([iv, c.getAuthTag(), enc]).toString("base64");
}

function decrypt(blob) {
  const buf = Buffer.from(blob, "base64");
  const d = crypto.createDecipheriv("aes-256-gcm", TOKEN_ENC_KEY, buf.subarray(0, 12));
  d.setAuthTag(buf.subarray(12, 28));
  return Buffer.concat([d.update(buf.subarray(28)), d.final()]).toString("utf8");
}

function send(res, status, obj, headers = {}) {
  const data = JSON.stringify(obj);
  res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...headers });
  res.end(data);
}

function html(res, status, title, body) {
  res.writeHead(status, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Frame-Options": "DENY",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'" });
  res.end(`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title>
<style>body{font-family:-apple-system,sans-serif;background:#1c1a24;color:#eee;display:grid;place-items:center;min-height:90vh;text-align:center;padding:24px}
a{display:inline-block;margin-top:18px;background:#ff9a1a;color:#111;padding:12px 22px;border-radius:12px;text-decoration:none;font-weight:600}</style>
<div><h1>🥭 ${title}</h1>${body}</div>`);
}

function redirect(res, location) {
  res.writeHead(302, { Location: location, "Cache-Control": "no-store" });
  res.end();
}

function readBody(req, limit = 12 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = []; let size = 0;
    req.on("data", (d) => { size += d.length; if (size > limit) { reject(new Error("Request too big")); req.destroy(); } else chunks.push(d); });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

// Simple per-IP rate limiting for sensitive endpoints.
const buckets = new Map();
function rateLimited(req, key, limit, windowMs) {
  const ip = (req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").split(",")[0].trim();
  const k = `${key}:${ip}`;
  const now = Date.now();
  const b = buckets.get(k) || { count: 0, reset: now + windowMs };
  if (now > b.reset) { b.count = 0; b.reset = now + windowMs; }
  b.count++;
  buckets.set(k, b);
  return b.count > limit;
}
setInterval(() => { const now = Date.now(); for (const [k, b] of buckets) if (now > b.reset) buckets.delete(k); }, 60000).unref();

async function authUser(req) {
  const h = req.headers["authorization"] || "";
  if (!h.startsWith("Bearer ")) return null;
  const hash = sha256(h.slice(7).trim());
  const r = await db.query(
    `UPDATE sessions SET last_used = now() WHERE token_hash = $1 AND NOT revoked AND expires_at > now()
     RETURNING id, user_id`, [hash]);
  if (!r.rowCount) return null;
  const u = await db.query("SELECT * FROM users WHERE id = $1", [r.rows[0].user_id]);
  return u.rows[0] ? { ...u.rows[0], session_id: r.rows[0].id } : null;
}

function isPro(u) {
  if (PRO_GITHUB_IDS.has(String(u.github_id))) return true;
  return ["active", "trialing"].includes(u.pro_status) || (u.pro_until && new Date(u.pro_until) > new Date());
}

function publicUser(u) {
  return {
    login: u.login, name: u.name, avatarURL: u.avatar_url,
    pro: !!isPro(u), proStatus: PRO_GITHUB_IDS.has(String(u.github_id)) ? "owner pass" : u.pro_status, proUntil: u.pro_until,
    credits: Number(u.credits_micro) / 1e6,
    topups: TOPUPS.map((c) => c / 100), proPrice: PRO_PRICE_CENTS / 100,
    payments: !!stripe, aiCredits: !!ANTHROPIC_KEY,
  };
}

// ---------- GitHub login ----------

async function githubStart(req, res, url) {
  if (rateLimited(req, "login", 20, 10 * 60 * 1000)) return html(res, 429, "Slow down", "<p>Too many sign-in attempts. Try again in a few minutes.</p>");
  if (!GITHUB_CLIENT_ID) return html(res, 503, "Not set up yet", "<p>GitHub sign-in isn't configured on the server yet.</p>");
  const appState = url.searchParams.get("app_state") || "";
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(appState)) return html(res, 400, "Bad request", "<p>Open sign-in from MangoIDE.</p>");
  const state = randomToken(24);
  await db.query("INSERT INTO oauth_states (state, app_state) VALUES ($1, $2)", [state, appState]);
  await db.query("DELETE FROM oauth_states WHERE created_at < now() - interval '15 minutes'");
  const q = new URLSearchParams({
    client_id: GITHUB_CLIENT_ID,
    redirect_uri: `${PUBLIC_URL}/auth/github/callback`,
    scope: "read:user repo",
    state,
    allow_signup: "true",
  });
  redirect(res, `https://github.com/login/oauth/authorize?${q}`);
}

async function githubCallback(req, res, url) {
  const code = url.searchParams.get("code"), state = url.searchParams.get("state");
  if (!code || !state) return html(res, 400, "Sign-in cancelled", "<p>You can close this and try again in MangoIDE.</p>");
  const st = await db.query("DELETE FROM oauth_states WHERE state = $1 AND created_at > now() - interval '15 minutes' RETURNING app_state", [state]);
  if (!st.rowCount) return html(res, 400, "Sign-in expired", "<p>Please start again from MangoIDE.</p>");
  const appState = st.rows[0].app_state;

  const tokRes = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify({ client_id: GITHUB_CLIENT_ID, client_secret: GITHUB_CLIENT_SECRET, code, redirect_uri: `${PUBLIC_URL}/auth/github/callback` }),
  });
  const tok = await tokRes.json();
  if (!tok.access_token) return html(res, 400, "GitHub said no", "<p>Sign-in didn't complete. Try again from MangoIDE.</p>");

  const ghRes = await fetch("https://api.github.com/user", { headers: { Authorization: `Bearer ${tok.access_token}`, "User-Agent": "MangoIDE", Accept: "application/vnd.github+json" } });
  const gh = await ghRes.json();
  if (!gh.id) return html(res, 400, "GitHub error", "<p>Couldn't read your GitHub profile.</p>");

  const u = await db.query(
    `INSERT INTO users (github_id, login, name, avatar_url, github_token_enc) VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (github_id) DO UPDATE SET login = EXCLUDED.login, name = EXCLUDED.name, avatar_url = EXCLUDED.avatar_url, github_token_enc = EXCLUDED.github_token_enc
     RETURNING id`, [gh.id, gh.login, gh.name || null, gh.avatar_url || null, encrypt(tok.access_token)]);

  const session = randomToken(32);
  const device = String(req.headers["user-agent"] || "").slice(0, 120);
  await db.query(
    `INSERT INTO sessions (user_id, token_hash, device, expires_at) VALUES ($1, $2, $3, now() + interval '${SESSION_DAYS} days')`,
    [u.rows[0].id, sha256(session), device]);
  // Hand the session to the app through its own URL scheme. ASWebAuthenticationSession captures this; it never shows in Safari history.
  redirect(res, `${APP_SCHEME}://auth?token=${encodeURIComponent(session)}&app_state=${encodeURIComponent(appState)}`);
}

// ---------- Payments (Stripe Checkout) ----------

async function ensureCustomer(u) {
  if (u.stripe_customer_id) return u.stripe_customer_id;
  const c = await stripe.customers.create({ description: `MangoIDE user ${u.login}`, metadata: { user_id: String(u.id), github_login: u.login } });
  await db.query("UPDATE users SET stripe_customer_id = $1 WHERE id = $2", [c.id, u.id]);
  return c.id;
}

async function checkout(req, res, u) {
  if (!stripe) return send(res, 503, { message: "Payments aren't set up on the server yet." });
  if (rateLimited(req, "checkout", 20, 10 * 60 * 1000)) return send(res, 429, { message: "Too many attempts. Try again in a few minutes." });
  const body = JSON.parse((await readBody(req, 10000)).toString() || "{}");
  const customer = await ensureCustomer(u);
  const common = {
    customer,
    client_reference_id: String(u.id),
    success_url: `${PUBLIC_URL}/billing/done?status=success`,
    cancel_url: `${PUBLIC_URL}/billing/done?status=cancel`,
  };
  let session;
  if (body.kind === "pro") {
    if (isPro(u)) return send(res, 400, { message: "You already have Pro." });
    session = await stripe.checkout.sessions.create({
      ...common,
      mode: "subscription",
      line_items: [{ quantity: 1, price_data: { currency: "usd", unit_amount: PRO_PRICE_CENTS, recurring: { interval: "month" }, product_data: { name: "MangoIDE Pro" } } }],
      subscription_data: { metadata: { user_id: String(u.id) } },
      metadata: { user_id: String(u.id), kind: "pro" },
    });
  } else if (body.kind === "topup") {
    const cents = Number(body.cents);
    if (!TOPUPS.includes(cents)) return send(res, 400, { message: "Pick one of the top-up amounts." });
    session = await stripe.checkout.sessions.create({
      ...common,
      mode: "payment",
      line_items: [{ quantity: 1, price_data: { currency: "usd", unit_amount: cents, product_data: { name: `MangoIDE AI credit ($${(cents / 100).toFixed(2)})` } } }],
      payment_intent_data: { metadata: { user_id: String(u.id), kind: "topup" } },
      metadata: { user_id: String(u.id), kind: "topup", cents: String(cents) },
    });
  } else {
    return send(res, 400, { message: "Unknown purchase." });
  }
  send(res, 200, { url: session.url });
}

async function portal(req, res, u) {
  if (!stripe) return send(res, 503, { message: "Payments aren't set up on the server yet." });
  if (!u.stripe_customer_id) return send(res, 400, { message: "No purchases yet." });
  const p = await stripe.billingPortal.sessions.create({ customer: u.stripe_customer_id, return_url: `${PUBLIC_URL}/billing/done?status=portal` });
  send(res, 200, { url: p.url });
}

async function addLedger(userId, deltaMicro, reason, ref) {
  // ref is unique: the same Stripe event or AI request can never be counted twice.
  const client = await db.connect();
  try {
    await client.query("BEGIN");
    const ins = await client.query("INSERT INTO ledger (user_id, delta_micro, reason, ref) VALUES ($1, $2, $3, $4) ON CONFLICT (ref) DO NOTHING RETURNING id",
      [userId, Math.round(deltaMicro), reason, ref]);
    if (ins.rowCount) await client.query("UPDATE users SET credits_micro = credits_micro + $1 WHERE id = $2", [Math.round(deltaMicro), userId]);
    await client.query("COMMIT");
    return ins.rowCount > 0;
  } catch (e) {
    await client.query("ROLLBACK");
    throw e;
  } finally {
    client.release();
  }
}

async function syncSubscription(sub) {
  const userId = Number(sub.metadata?.user_id) || null;
  const until = sub.current_period_end ? new Date(sub.current_period_end * 1000) : (sub.items?.data?.[0]?.current_period_end ? new Date(sub.items.data[0].current_period_end * 1000) : null);
  if (userId) {
    await db.query("UPDATE users SET pro_status = $1, pro_until = $2 WHERE id = $3", [sub.status, until, userId]);
  } else {
    await db.query("UPDATE users SET pro_status = $1, pro_until = $2 WHERE stripe_customer_id = $3", [sub.status, until, sub.customer]);
  }
}

async function webhook(req, res) {
  if (!stripe || !STRIPE_WEBHOOK_SECRET) return send(res, 503, { message: "Webhooks not configured" });
  const raw = await readBody(req, 1024 * 1024);
  let event;
  try {
    event = stripe.webhooks.constructEvent(raw, req.headers["stripe-signature"], STRIPE_WEBHOOK_SECRET);
  } catch (e) {
    return send(res, 400, { message: "Bad signature" });
  }
  const obj = event.data.object;
  switch (event.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded":
      if (obj.metadata?.kind === "topup" && obj.payment_status === "paid") {
        const cents = Number(obj.amount_total ?? obj.metadata.cents);
        await addLedger(Number(obj.metadata.user_id), cents * 10000, "topup", `stripe:${obj.id}`);
      }
      if (obj.metadata?.kind === "pro" && obj.subscription) {
        await syncSubscription(await stripe.subscriptions.retrieve(obj.subscription));
      }
      break;
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
      await syncSubscription(obj);
      break;
    case "charge.refunded": {
      // Take refunded top-ups back out of the balance.
      const pi = obj.payment_intent && (await stripe.paymentIntents.retrieve(obj.payment_intent));
      if (pi?.metadata?.kind === "topup") {
        await addLedger(Number(pi.metadata.user_id), -Number(obj.amount_refunded) * 10000, "refund", `refund:${obj.id}:${obj.amount_refunded}`);
      }
      break;
    }
  }
  send(res, 200, { received: true });
}

// ---------- AI with credits ----------

const aiBusy = new Set();

function costMicro(model, usage) {
  const p = MODEL_PRICES[model];
  const n = (k) => Number(usage?.[k] || 0);
  const usd = (n("input_tokens") * p.input + n("output_tokens") * p.output + n("cache_creation_input_tokens") * p.cacheWrite + n("cache_read_input_tokens") * p.cacheRead) / 1e6;
  return Math.ceil(usd * AI_MARKUP * 1e6);
}

async function ai(req, res, u) {
  if (!ANTHROPIC_KEY) return send(res, 503, { message: "AI credits aren't set up on the server yet." });
  if (aiBusy.has(u.id)) return send(res, 429, { message: "One request at a time, please." });
  if (Number(u.credits_micro) < 5000) return send(res, 402, { message: "You're out of AI credit. Top up in Settings › Account." });
  const body = JSON.parse((await readBody(req)).toString());
  if (!MODEL_PRICES[body.model]) return send(res, 400, { message: "That model isn't available." });
  aiBusy.add(u.id);
  try {
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: body.model, max_tokens: Math.min(Number(body.max_tokens) || 8000, 16000), system: body.system, messages: body.messages, tools: body.tools }),
      signal: AbortSignal.timeout(180000),
    });
    const json = await r.json();
    if (json.usage) {
      const cost = costMicro(body.model, json.usage);
      await addLedger(u.id, -cost, "ai", `ai:${json.id || crypto.randomUUID()}`);
    }
    const bal = await db.query("SELECT credits_micro FROM users WHERE id = $1", [u.id]);
    send(res, r.status, json, { "X-Credits": String(Number(bal.rows[0].credits_micro) / 1e6) });
  } finally {
    aiBusy.delete(u.id);
  }
}

// ---------- GitHub (repos, clone, pull, push) ----------

const githubRoutes = require("./github")({ decrypt, send, readBody, isPro });
const cloudRoutes = require("./cloud")({ db, send, readBody, isPro });

// ---------- Routes ----------

async function route(req, res) {
  const url = new URL(req.url, PUBLIC_URL || "http://localhost");
  const p = url.pathname.replace(/\/+$/, "") || "/";
  if (req.method === "GET" && (p === "/" || p === "/health")) return send(res, 200, { ok: true, name: "MangoIDE accounts" });
  if (req.method === "GET" && p === "/auth/github/start") return githubStart(req, res, url);
  if (req.method === "GET" && p === "/auth/github/callback") return githubCallback(req, res, url);
  if (req.method === "POST" && p === "/stripe/webhook") return webhook(req, res);
  if (req.method === "GET" && p === "/billing/done") {
    const s = url.searchParams.get("status");
    const title = s === "success" ? "Payment complete" : s === "portal" ? "All set" : "Payment cancelled";
    const msg = s === "success" ? "<p>Thanks! Your purchase will show in MangoIDE in a few seconds.</p>" : s === "portal" ? "" : "<p>No charge was made.</p>";
    return html(res, 200, title, `${msg}<a href="${APP_SCHEME}://billing">Back to MangoIDE</a>`);
  }

  if (rateLimited(req, "api", 300, 60 * 1000)) return send(res, 429, { message: "Too many requests." });
  const u = await authUser(req);
  if (!u) return send(res, 401, { message: "Please sign in again." });

  if (req.method === "GET" && p === "/me") return send(res, 200, publicUser(u));
  if (req.method === "POST" && p === "/auth/logout") {
    await db.query("UPDATE sessions SET revoked = true WHERE id = $1", [u.session_id]);
    return send(res, 200, { ok: true });
  }
  if (req.method === "POST" && p === "/auth/logout-all") {
    await db.query("UPDATE sessions SET revoked = true WHERE user_id = $1", [u.id]);
    return send(res, 200, { ok: true });
  }
  if (req.method === "GET" && p === "/me/sessions") {
    const r = await db.query("SELECT id, device, created_at, last_used, id = $2 AS current FROM sessions WHERE user_id = $1 AND NOT revoked AND expires_at > now() ORDER BY last_used DESC", [u.id, u.session_id]);
    return send(res, 200, r.rows);
  }
  if (req.method === "POST" && p === "/billing/checkout") return checkout(req, res, u);
  if (req.method === "POST" && p === "/billing/portal") return portal(req, res, u);
  if (req.method === "POST" && p === "/ai/messages") return ai(req, res, u);
  if (p.startsWith("/github/") && await githubRoutes(req, res, u, url, p)) return;
  if (p.startsWith("/cloud/") && await cloudRoutes(req, res, u, url, p)) return;
  send(res, 404, { message: "Not found" });
}

migrate().then(() => cloudRoutes.migrate()).then(() => {
  http.createServer((req, res) => {
    route(req, res).catch((e) => {
      console.error(e);
      if (!res.headersSent) send(res, 500, { message: "Server error" });
    });
  }).listen(PORT, () => {
    console.log(`MangoIDE accounts on ${PORT}`);
    console.log(`GitHub login: ${GITHUB_CLIENT_ID ? "configured" : "missing GITHUB_CLIENT_ID/SECRET"} · Stripe: ${stripe ? (STRIPE_SECRET_KEY.startsWith("sk_test") ? "TEST mode" : "LIVE mode") : "missing"} · Webhook: ${STRIPE_WEBHOOK_SECRET ? "ok" : "missing"} · AI credits: ${ANTHROPIC_KEY ? "on" : "off"} · Token key: ${TOKEN_ENC_KEY?.length === 32 ? "ok" : "missing"}`);
  });
}).catch((e) => { console.error("Database setup failed:", e); process.exit(1); });
