// Live sessions: several people editing the same project at once, plus "share a copy" links.
//
// A live session lives in memory on this server. The host (Pro) uploads the project's text files,
// everyone connects over a WebSocket, and every edit is an operation that the server puts in order
// (operational transformation), so everyone ends up with exactly the same text.
// Joining is free; you just need to be signed in.

const crypto = require("crypto");
const { WebSocketServer } = require("ws");
const ot = require("./ot");

module.exports = function collab({ db, send, readBody, isPro, authUser, html, appScheme }) {
  const MAX_FILES = 1500, MAX_FILE = 1024 * 1024, MAX_TOTAL = 20 * 1024 * 1024, MAX_PEOPLE = 12;
  const HISTORY = 1000, IDLE_MS = 15 * 60 * 1000, SHARE_DAYS = 30;
  const COLORS = ["#ff9f0a", "#30d158", "#0a84ff", "#ff375f", "#bf5af2", "#64d2ff", "#ffd60a", "#ff6b3d", "#5e5ce6", "#66d4cf", "#ac8e68", "#ff8fab"];
  const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const sessions = new Map();     // code → session

  class CError extends Error { constructor(status, message, extra) { super(message); this.status = status; this.extra = extra; } }

  const newCode = (n) => { let s = ""; const b = crypto.randomBytes(n); for (const x of b) s += ALPHABET[x % ALPHABET.length]; return s; };
  const okPath = (p) => typeof p === "string" && p.length > 0 && p.length < 1000 && !p.startsWith("/") &&
    !p.split("/").some((s) => s === "" || s === "." || s === "..");
  const json = async (req, limit) => JSON.parse((await readBody(req, limit)).toString("utf8") || "{}");

  // ---------- Live sessions ----------

  // POST /collab/start {name, files:{path:text}} → {code}
  async function start(req, res, u) {
    if (!isPro(u)) throw new CError(402, "Hosting a live session is part of MangoIDE Pro. Joining one is free.", { pro: true });
    const b = await json(req, MAX_TOTAL + 2 * 1024 * 1024);
    const name = String(b.name || "Project").slice(0, 120);
    const files = b.files && typeof b.files === "object" ? Object.entries(b.files) : [];
    if (files.length > MAX_FILES) throw new CError(413, `Live sessions can share up to ${MAX_FILES} text files.`);
    const docs = new Map();
    let total = 0;
    for (const [p, text] of files) {
      if (!okPath(p) || typeof text !== "string" || text.length > MAX_FILE) continue;
      total += text.length;
      docs.set(p, { text, rev: 0, history: [], ids: [] });
    }
    if (total > MAX_TOTAL) throw new CError(413, "That project is too big for a live session (20 MB of text).");
    // One session per host at a time.
    for (const [code, s] of sessions) if (s.hostId === u.id) end(s, "The host started a new session.");
    let code;
    do { code = newCode(6); } while (sessions.has(code));
    const s = { code, name, hostId: u.id, hostLogin: u.login, docs, clients: new Map(), colors: new Map(), lastActive: Date.now() };
    sessions.set(code, s);
    send(res, 200, { code, name, link: `${process.env.PUBLIC_URL || ""}/j/${code}` });
  }

  function end(s, reason) {
    for (const c of s.clients.keys()) { try { c.send(JSON.stringify({ t: "ended", reason })); c.close(1000, "ended"); } catch {} }
    sessions.delete(s.code);
  }

  function people(s) {
    const seen = [];
    for (const c of s.clients.values()) {
      seen.push({ id: c.id, login: c.login, avatar: c.avatar, color: c.color, host: c.host, path: c.path || null });
    }
    return seen;
  }

  function broadcast(s, msg, except) {
    const data = JSON.stringify(msg);
    for (const ws of s.clients.keys()) if (ws !== except && ws.readyState === 1) ws.send(data);
  }

  function colorFor(s, userId) {
    if (!s.colors.has(userId)) s.colors.set(userId, COLORS[s.colors.size % COLORS.length]);
    return s.colors.get(userId);
  }

  function handle(s, ws, me, msg) {
    s.lastActive = Date.now();
    const reply = (m) => ws.readyState === 1 && ws.send(JSON.stringify(m));
    switch (msg.t) {
      case "op": {
        const d = s.docs.get(msg.path);
        if (!d || !ot.valid(msg.op) || !Number.isInteger(msg.rev)) return reply({ t: "resync", path: msg.path, text: d?.text ?? "", rev: d?.rev ?? 0 });
        const behind = d.rev - msg.rev;
        if (behind < 0 || behind > d.history.length) return reply({ t: "resync", path: msg.path, text: d.text, rev: d.rev });
        try {
          let op = msg.op;
          for (const h of d.history.slice(d.history.length - behind)) op = ot.transform(op, h)[0];
          const text = ot.apply(d.text, op);
          if (text.length > MAX_FILE * 2) throw new Error("too big");
          d.text = text;
          d.history.push(op);
          if (typeof msg.id === "string" && msg.id.length <= 64) { d.ids.push(msg.id); if (d.ids.length > 200) d.ids.shift(); }
          if (d.history.length > HISTORY) d.history.splice(0, d.history.length - HISTORY);
          d.rev++;
          reply({ t: "ack", path: msg.path, rev: d.rev });
          broadcast(s, { t: "op", path: msg.path, rev: d.rev, op, by: me.id }, ws);
        } catch {
          reply({ t: "resync", path: msg.path, text: d.text, rev: d.rev });
        }
        return;
      }
      case "sel": {
        if (typeof msg.path !== "string" || !Number.isInteger(msg.a) || !Number.isInteger(msg.b)) return;
        const changedFile = me.path !== msg.path;
        me.path = msg.path;
        broadcast(s, { t: "sel", by: me.id, path: msg.path, a: msg.a, b: msg.b }, ws);
        if (changedFile) broadcast(s, { t: "people", people: people(s) });
        return;
      }
      case "add": {
        if (!okPath(msg.path) || typeof msg.text !== "string" || msg.text.length > MAX_FILE) return;
        const d = s.docs.get(msg.path);
        if (d) return reply({ t: "resync", path: msg.path, text: d.text, rev: d.rev });
        if (s.docs.size >= MAX_FILES) return reply({ t: "error", message: "This session has the maximum number of files." });
        s.docs.set(msg.path, { text: msg.text, rev: 0, history: [], ids: [] });
        broadcast(s, { t: "added", path: msg.path, text: msg.text, rev: 0, by: me.id }, ws);
        reply({ t: "added", path: msg.path, text: msg.text, rev: 0, by: me.id });
        return;
      }
      case "end": {
        if (me.host) end(s, "The host ended the session.");
        return;
      }
      case "ping": return reply({ t: "pong" });
    }
  }

  function attach(server) {
    const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_TOTAL + 4 * 1024 * 1024 });
    server.on("upgrade", async (req, socket, head) => {
      try {
        const url = new URL(req.url, "http://x");
        if (url.pathname !== "/collab/ws") return socket.destroy();
        const u = await authUser(req);
        const s = sessions.get(String(url.searchParams.get("code") || "").toUpperCase());
        const refuse = (status, text) => { socket.write(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`); socket.destroy(); };
        if (!u) return refuse(401, "Unauthorized");
        if (!s) return refuse(404, "Not Found");
        const distinctUsers = new Set([...s.clients.values()].map((c) => c.userId));
        if (!distinctUsers.has(u.id) && distinctUsers.size >= MAX_PEOPLE) return refuse(403, "Full");
        wss.handleUpgrade(req, socket, head, (ws) => {
          const me = { id: newCode(8), userId: u.id, login: u.login, avatar: u.avatar_url, color: colorFor(s, u.id), host: u.id === s.hostId, path: null };
          s.clients.set(ws, me);
          s.lastActive = Date.now();
          const files = {};
          for (const [p, d] of s.docs) files[p] = { text: d.text, rev: d.rev, ids: d.ids.slice(-50) };
          ws.send(JSON.stringify({ t: "welcome", you: me, session: { code: s.code, name: s.name, host: s.hostLogin }, files, people: people(s) }));
          broadcast(s, { t: "people", people: people(s) }, ws);
          ws.on("message", (data) => {
            let msg; try { msg = JSON.parse(data.toString("utf8")); } catch { return; }
            if (sessions.get(s.code) === s) handle(s, ws, me, msg);
          });
          ws.on("close", () => {
            s.clients.delete(ws);
            s.lastActive = Date.now();
            if (sessions.get(s.code) === s) broadcast(s, { t: "people", people: people(s) });
          });
          ws.on("error", () => {});
        });
      } catch (e) {
        console.error("collab upgrade", e);
        socket.destroy();
      }
    });
    // Drop sessions nobody has been in for a while, and keep connections alive through proxies.
    setInterval(() => {
      const now = Date.now();
      for (const s of sessions.values()) {
        if (s.clients.size === 0 && now - s.lastActive > IDLE_MS) sessions.delete(s.code);
      }
      for (const ws of wss.clients) { try { ws.ping(); } catch {} }
    }, 30000).unref();
    setInterval(() => { db.query("DELETE FROM shares WHERE expires_at < now()").catch(() => {}); }, 6 * 3600 * 1000).unref();
  }

  // ---------- Share a copy (link) ----------

  async function migrate() {
    await db.query(`
      CREATE TABLE IF NOT EXISTS shares (
        code TEXT PRIMARY KEY,
        user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        manifest JSONB NOT NULL,
        files INT NOT NULL,
        size BIGINT NOT NULL,
        downloads INT NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        expires_at TIMESTAMPTZ NOT NULL
      );
    `);
  }

  // POST /share/create {name, manifest:{path:[sha,size]}} — files must already be uploaded with /cloud/upload.
  async function createShare(req, res, u) {
    if (!isPro(u)) throw new CError(402, "Sharing a project link is part of MangoIDE Pro. Opening a shared link is free.", { pro: true });
    const b = await json(req, 16 * 1024 * 1024);
    const name = String(b.name || "Project").trim().slice(0, 120) || "Project";
    const entries = Object.entries(b.manifest || {});
    if (!entries.length) throw new CError(400, "There are no files to share.");
    if (entries.length > 20000) throw new CError(413, "That project has too many files to share.");
    let size = 0;
    const shas = new Set();
    for (const [p, v] of entries) {
      if (!okPath(p) || !Array.isArray(v) || !/^[0-9a-f]{64}$/.test(v[0] || "") || !Number.isFinite(v[1])) throw new CError(400, `Bad entry: ${p}`);
      size += v[1]; shas.add(v[0]);
    }
    const have = await db.query("SELECT sha FROM cloud_blobs WHERE user_id = $1 AND sha = ANY($2)", [u.id, [...shas]]);
    if (have.rowCount !== shas.size) throw new CError(409, "Some files didn't finish uploading. Try again.");
    const code = newCode(10);
    const days = Math.max(1, Math.min(365, Number(b.days) || SHARE_DAYS));
    await db.query(
      `INSERT INTO shares (code, user_id, name, manifest, files, size, expires_at) VALUES ($1, $2, $3, $4, $5, $6, now() + ($7 || ' days')::interval)`,
      [code, u.id, name, b.manifest, entries.length, size, String(days)]);
    send(res, 200, { code, link: `${process.env.PUBLIC_URL || ""}/s/${code}`, days });
  }

  async function shareRow(code) {
    if (!/^[A-Z0-9]{10}$/.test(code)) return null;
    const r = await db.query(
      "SELECT s.*, u.login FROM shares s JOIN users u ON u.id = s.user_id WHERE s.code = $1 AND s.expires_at > now()", [code]);
    return r.rows[0] || null;
  }

  // GET /share/info?code= (no sign-in needed)
  async function shareInfo(req, res, url) {
    const s = await shareRow(String(url.searchParams.get("code") || "").toUpperCase());
    if (!s) throw new CError(404, "That link doesn't exist or has expired.");
    send(res, 200, { code: s.code, name: s.name, owner: s.login, files: s.files, size: Number(s.size), createdAt: s.created_at, expiresAt: s.expires_at, manifest: s.manifest });
  }

  // POST /share/download {code, shas} → {blobs:{sha: base64}} (only files that belong to that share)
  async function shareDownload(req, res) {
    const b = await json(req, 2 * 1024 * 1024);
    const s = await shareRow(String(b.code || "").toUpperCase());
    if (!s) throw new CError(404, "That link doesn't exist or has expired.");
    const allowed = new Set(Object.values(s.manifest).map((v) => v[0]));
    const shas = [...new Set((b.shas || []).filter((x) => allowed.has(x)))].slice(0, 2000);
    const r = await db.query("SELECT sha, data FROM cloud_blobs WHERE user_id = $1 AND sha = ANY($2)", [s.user_id, shas]);
    const out = {};
    let total = 0;
    for (const row of r.rows) {
      if (total > 0 && total + row.data.length > 24 * 1024 * 1024) break;
      out[row.sha] = row.data.toString("base64");
      total += row.data.length;
    }
    if (b.first) await db.query("UPDATE shares SET downloads = downloads + 1 WHERE code = $1", [s.code]);
    send(res, 200, { blobs: out });
  }

  // GET /share/mine
  async function myShares(req, res, u) {
    const r = await db.query("SELECT code, name, files, size, downloads, created_at, expires_at FROM shares WHERE user_id = $1 AND expires_at > now() ORDER BY created_at DESC", [u.id]);
    send(res, 200, { shares: r.rows.map((s) => ({ code: s.code, name: s.name, files: s.files, size: Number(s.size), downloads: s.downloads, createdAt: s.created_at, expiresAt: s.expires_at, link: `${process.env.PUBLIC_URL || ""}/s/${s.code}` })) });
  }

  // POST /share/revoke {code}
  async function revoke(req, res, u) {
    const b = await json(req, 64 * 1024);
    await db.query("DELETE FROM shares WHERE code = $1 AND user_id = $2", [String(b.code || "").toUpperCase(), u.id]);
    send(res, 200, { ok: true });
  }

  // ---------- Landing pages for links ----------

  function landing(res, kind, code) {
    const safe = String(code).toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 12);
    const isJoin = kind === "j";
    const s = isJoin ? sessions.get(safe) : null;
    const title = isJoin ? (s ? `Join “${escape(s.name)}”` : "Live session") : "Shared project";
    const body = isJoin
      ? (s ? `<p>${escape(s.hostLogin)} invited you to edit live in MangoIDE.</p>` : `<p>This session has ended or the code is wrong.</p>`)
      : `<p>Someone shared a MangoIDE project with you.</p>`;
    html(res, 200, title, `${body}<a href="${appScheme}://${isJoin ? "join" : "share"}/${safe}">Open in MangoIDE</a><p style="opacity:.6;margin-top:22px">Code: ${safe}</p>`);
  }
  const escape = (t) => String(t).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  // ---------- Routes ----------

  // Routes that work without signing in.
  async function publicRoute(req, res, url, p) {
    try {
      if (req.method === "GET" && /^\/(j|s)\/[A-Za-z0-9]{4,12}$/.test(p)) { const [, k, c] = p.split("/"); landing(res, k, c); return true; }
      if (req.method === "GET" && p === "/share/info") { await shareInfo(req, res, url); return true; }
      if (req.method === "POST" && p === "/share/download") { await shareDownload(req, res); return true; }
      return false;
    } catch (e) { return fail(res, e); }
  }

  async function route(req, res, u, url, p) {
    try {
      if (req.method === "POST" && p === "/collab/start") { await start(req, res, u); return true; }
      if (req.method === "GET" && p === "/collab/info") {
        const s = sessions.get(String(url.searchParams.get("code") || "").toUpperCase());
        if (!s) throw new CError(404, "That session has ended or the code is wrong.");
        send(res, 200, { code: s.code, name: s.name, host: s.hostLogin, people: people(s).length, files: s.docs.size });
        return true;
      }
      if (req.method === "POST" && p === "/share/create") { await createShare(req, res, u); return true; }
      if (req.method === "GET" && p === "/share/mine") { await myShares(req, res, u); return true; }
      if (req.method === "POST" && p === "/share/revoke") { await revoke(req, res, u); return true; }
      return false;
    } catch (e) { return fail(res, e); }
  }

  function fail(res, e) {
    if (e instanceof CError) { send(res, e.status, { message: e.message, ...(e.extra || {}) }); return true; }
    if (e instanceof SyntaxError) { send(res, 400, { message: "Bad request." }); return true; }
    throw e;
  }

  // Files a share points to must survive the cloud's cleanup.
  async function liveShas(userId) {
    const r = await db.query("SELECT manifest FROM shares WHERE user_id = $1 AND expires_at > now()", [userId]);
    const out = new Set();
    for (const row of r.rows) for (const v of Object.values(row.manifest)) out.add(v[0]);
    return out;
  }

  return { route, publicRoute, attach, migrate, liveShas };
};
