// Cloud Sync & Backup for MangoIDE projects.
//
// Files are stored once each, by the SHA-256 of their contents (so unchanged files are never re-sent).
// Each sync of a project saves a snapshot: a list of path → file hash. The last KEEP snapshots of every
// project are kept, which is what "Backups" restores from.
//
// Saving to the cloud needs Pro. Reading (listing, downloading, restoring) always works, so nobody
// loses access to their own files if Pro ends.

const crypto = require("crypto");

module.exports = function cloud({ db, send, readBody, isPro }) {
  const QUOTA = Number(process.env.CLOUD_QUOTA_MB || 2048) * 1024 * 1024;
  const KEEP = Number(process.env.CLOUD_KEEP_SNAPSHOTS || 20);
  const MAX_FILE = 25 * 1024 * 1024;
  const MAX_BATCH = 24 * 1024 * 1024;
  const SHA = /^[0-9a-f]{64}$/;

  class CloudError extends Error { constructor(status, message, extra) { super(message); this.status = status; this.extra = extra; } }

  async function migrate() {
    await db.query(`
      CREATE TABLE IF NOT EXISTS cloud_blobs (
        user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        sha TEXT NOT NULL,
        size INT NOT NULL,
        data BYTEA NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (user_id, sha)
      );
      CREATE TABLE IF NOT EXISTS cloud_projects (
        id SERIAL PRIMARY KEY,
        user_id INT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (user_id, name)
      );
      CREATE TABLE IF NOT EXISTS cloud_snapshots (
        id SERIAL PRIMARY KEY,
        project_id INT NOT NULL REFERENCES cloud_projects(id) ON DELETE CASCADE,
        manifest JSONB NOT NULL,
        files INT NOT NULL,
        size BIGINT NOT NULL,
        device TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
      );
      CREATE INDEX IF NOT EXISTS cloud_snapshots_project ON cloud_snapshots (project_id, id DESC);
    `);
  }

  const needPro = (u) => { if (!isPro(u)) throw new CloudError(402, "Cloud Sync & Backup is part of MangoIDE Pro. Your existing backups can still be downloaded.", { pro: true }); };
  const json = async (req, limit = 4 * 1024 * 1024) => JSON.parse((await readBody(req, limit)).toString("utf8") || "{}");
  const projectName = (s) => {
    s = String(s || "").trim();
    if (!s || s.length > 200 || s.includes("/") || s === "." || s === ".." || /[\u0000-\u001f]/.test(s)) throw new CloudError(400, "Bad project name.");
    return s;
  };
  const okPath = (p) => typeof p === "string" && p.length > 0 && p.length < 1000 && !p.startsWith("/") &&
    !p.split("/").some((s) => s === "" || s === "." || s === "..");

  async function used(userId) {
    const r = await db.query("SELECT COALESCE(SUM(size), 0)::BIGINT AS n FROM cloud_blobs WHERE user_id = $1", [userId]);
    return Number(r.rows[0].n);
  }

  async function findProject(userId, name) {
    const r = await db.query("SELECT * FROM cloud_projects WHERE user_id = $1 AND name = $2", [userId, name]);
    return r.rows[0] || null;
  }

  // Deletes stored files no snapshot points to anymore (older than an hour, so uploads mid-sync are safe).
  async function collectGarbage(userId) {
    const m = await db.query(
      "SELECT s.manifest FROM cloud_snapshots s JOIN cloud_projects p ON p.id = s.project_id WHERE p.user_id = $1", [userId]);
    const live = new Set();
    for (const row of m.rows) for (const v of Object.values(row.manifest)) live.add(v[0]);
    const all = await db.query("SELECT sha FROM cloud_blobs WHERE user_id = $1 AND created_at < now() - interval '1 hour'", [userId]);
    const dead = all.rows.map((r) => r.sha).filter((s) => !live.has(s));
    for (let i = 0; i < dead.length; i += 500) {
      await db.query("DELETE FROM cloud_blobs WHERE user_id = $1 AND sha = ANY($2)", [userId, dead.slice(i, i + 500)]);
    }
  }

  // GET /cloud/projects
  async function projects(req, res, u) {
    const r = await db.query(`
      SELECT p.name, p.updated_at, s.id AS snapshot, s.files, s.size, s.device
      FROM cloud_projects p
      LEFT JOIN LATERAL (SELECT id, files, size, device FROM cloud_snapshots WHERE project_id = p.id ORDER BY id DESC LIMIT 1) s ON true
      WHERE p.user_id = $1 ORDER BY p.updated_at DESC`, [u.id]);
    send(res, 200, {
      pro: !!isPro(u), used: await used(u.id), quota: QUOTA,
      projects: r.rows.map((p) => ({ name: p.name, updatedAt: p.updated_at, snapshot: p.snapshot, files: p.files || 0, size: Number(p.size || 0), device: p.device })),
    });
  }

  // POST /cloud/missing {shas:[...]} → which ones the cloud doesn't have yet.
  async function missing(req, res, u) {
    needPro(u);
    const b = await json(req);
    const shas = [...new Set((b.shas || []).filter((s) => SHA.test(s)))].slice(0, 20000);
    const have = await db.query("SELECT sha FROM cloud_blobs WHERE user_id = $1 AND sha = ANY($2)", [u.id, shas]);
    const got = new Set(have.rows.map((r) => r.sha));
    send(res, 200, { missing: shas.filter((s) => !got.has(s)) });
  }

  // POST /cloud/upload {blobs:[{sha, data (base64)}]} — the server checks every hash itself.
  async function upload(req, res, u) {
    needPro(u);
    const b = await json(req, Math.ceil(MAX_BATCH * 1.4) + 65536);
    const blobs = Array.isArray(b.blobs) ? b.blobs : [];
    let incoming = 0;
    const rows = [];
    for (const x of blobs) {
      if (!SHA.test(x.sha || "") || typeof x.data !== "string") throw new CloudError(400, "Bad file.");
      const data = Buffer.from(x.data, "base64");
      if (data.length > MAX_FILE) throw new CloudError(413, "A file is over the 25 MB limit.");
      if (crypto.createHash("sha256").update(data).digest("hex") !== x.sha) throw new CloudError(400, "A file was damaged on the way. Try again.");
      incoming += data.length;
      rows.push([x.sha, data]);
    }
    if ((await used(u.id)) + incoming > QUOTA) {
      throw new CloudError(507, `Your cloud storage is full (${Math.round(QUOTA / 1048576)} MB). Delete old projects from the cloud to make room.`, { full: true });
    }
    for (const [sha, data] of rows) {
      await db.query("INSERT INTO cloud_blobs (user_id, sha, size, data) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING", [u.id, sha, data.length, data]);
    }
    send(res, 200, { stored: rows.length });
  }

  // POST /cloud/download {shas:[...]} → {blobs:{sha: base64}} (stops before the reply gets too big).
  async function download(req, res, u) {
    const b = await json(req);
    const shas = [...new Set((b.shas || []).filter((s) => SHA.test(s)))].slice(0, 2000);
    const r = await db.query("SELECT sha, data FROM cloud_blobs WHERE user_id = $1 AND sha = ANY($2)", [u.id, shas]);
    const out = {};
    let total = 0;
    for (const row of r.rows) {
      if (total > 0 && total + row.data.length > MAX_BATCH) break;
      out[row.sha] = row.data.toString("base64");
      total += row.data.length;
    }
    send(res, 200, { blobs: out });
  }

  // POST /cloud/snapshot {project, manifest:{path:[sha,size]}, base, device}
  // base = the snapshot this device last synced. If the cloud has moved on, nothing is saved and the
  // device must merge first (409), so two devices can never wipe out each other's changes.
  async function snapshot(req, res, u) {
    needPro(u);
    const b = await json(req, 16 * 1024 * 1024);
    const name = projectName(b.project);
    const manifest = b.manifest && typeof b.manifest === "object" ? b.manifest : null;
    if (!manifest) throw new CloudError(400, "Missing file list.");
    const entries = Object.entries(manifest);
    if (entries.length > 50000) throw new CloudError(413, "That project has too many files to sync.");
    let size = 0;
    const shas = new Set();
    for (const [p, v] of entries) {
      if (!okPath(p) || !Array.isArray(v) || !SHA.test(v[0] || "") || !Number.isFinite(v[1])) throw new CloudError(400, `Bad entry: ${p}`);
      size += v[1]; shas.add(v[0]);
    }
    const have = await db.query("SELECT sha FROM cloud_blobs WHERE user_id = $1 AND sha = ANY($2)", [u.id, [...shas]]);
    if (have.rowCount !== shas.size) throw new CloudError(409, "Some files didn't finish uploading. Sync again.", { retry: true });

    const client = await db.connect();
    try {
      await client.query("BEGIN");
      await client.query("INSERT INTO cloud_projects (user_id, name) VALUES ($1, $2) ON CONFLICT (user_id, name) DO NOTHING", [u.id, name]);
      const p = (await client.query("SELECT id FROM cloud_projects WHERE user_id = $1 AND name = $2 FOR UPDATE", [u.id, name])).rows[0];
      const latest = (await client.query("SELECT id FROM cloud_snapshots WHERE project_id = $1 ORDER BY id DESC LIMIT 1", [p.id])).rows[0];
      const base = b.base == null ? null : Number(b.base);
      if ((latest?.id ?? null) !== base) {
        await client.query("ROLLBACK");
        throw new CloudError(409, "Another device synced this project first.", { behind: true, latest: latest?.id ?? null });
      }
      const s = await client.query(
        "INSERT INTO cloud_snapshots (project_id, manifest, files, size, device) VALUES ($1, $2, $3, $4, $5) RETURNING id, created_at",
        [p.id, manifest, entries.length, size, String(b.device || "").slice(0, 80) || null]);
      await client.query("UPDATE cloud_projects SET updated_at = now() WHERE id = $1", [p.id]);
      const pruned = await client.query(
        `DELETE FROM cloud_snapshots WHERE project_id = $1 AND id NOT IN (SELECT id FROM cloud_snapshots WHERE project_id = $1 ORDER BY id DESC LIMIT $2)`,
        [p.id, KEEP]);
      await client.query("COMMIT");
      send(res, 200, { id: s.rows[0].id, createdAt: s.rows[0].created_at });
      if (pruned.rowCount) collectGarbage(u.id).catch((e) => console.error("cloud gc", e));
    } catch (e) {
      await client.query("ROLLBACK").catch(() => {});
      throw e;
    } finally {
      client.release();
    }
  }

  // GET /cloud/snapshot?project=&id= (latest when no id)
  async function getSnapshot(req, res, u, url) {
    const p = await findProject(u.id, projectName(url.searchParams.get("project")));
    if (!p) throw new CloudError(404, "That project isn't in the cloud.");
    const id = url.searchParams.get("id");
    const r = id
      ? await db.query("SELECT id, manifest, device, created_at FROM cloud_snapshots WHERE project_id = $1 AND id = $2", [p.id, Number(id)])
      : await db.query("SELECT id, manifest, device, created_at FROM cloud_snapshots WHERE project_id = $1 ORDER BY id DESC LIMIT 1", [p.id]);
    if (!r.rowCount) throw new CloudError(404, "That backup doesn't exist anymore.");
    const s = r.rows[0];
    send(res, 200, { id: s.id, manifest: s.manifest, device: s.device, createdAt: s.created_at });
  }

  // GET /cloud/history?project=
  async function history(req, res, u, url) {
    const p = await findProject(u.id, projectName(url.searchParams.get("project")));
    if (!p) return send(res, 200, { snapshots: [] });
    const r = await db.query("SELECT id, files, size, device, created_at FROM cloud_snapshots WHERE project_id = $1 ORDER BY id DESC", [p.id]);
    send(res, 200, { snapshots: r.rows.map((s) => ({ id: s.id, files: s.files, size: Number(s.size), device: s.device, createdAt: s.created_at })) });
  }

  // POST /cloud/delete {project}
  async function remove(req, res, u) {
    const b = await json(req);
    const name = projectName(b.project);
    await db.query("DELETE FROM cloud_projects WHERE user_id = $1 AND name = $2", [u.id, name]);
    send(res, 200, { ok: true });
    collectGarbage(u.id).catch((e) => console.error("cloud gc", e));
  }

  async function route(req, res, u, url, p) {
    try {
      if (req.method === "GET" && p === "/cloud/projects") { await projects(req, res, u); return true; }
      if (req.method === "POST" && p === "/cloud/missing") { await missing(req, res, u); return true; }
      if (req.method === "POST" && p === "/cloud/upload") { await upload(req, res, u); return true; }
      if (req.method === "POST" && p === "/cloud/download") { await download(req, res, u); return true; }
      if (req.method === "POST" && p === "/cloud/snapshot") { await snapshot(req, res, u); return true; }
      if (req.method === "GET" && p === "/cloud/snapshot") { await getSnapshot(req, res, u, url); return true; }
      if (req.method === "GET" && p === "/cloud/history") { await history(req, res, u, url); return true; }
      if (req.method === "POST" && p === "/cloud/delete") { await remove(req, res, u); return true; }
      return false;
    } catch (e) {
      if (e instanceof CloudError) { send(res, e.status, { message: e.message, ...(e.extra || {}) }); return true; }
      if (e instanceof SyntaxError) { send(res, 400, { message: "Bad request." }); return true; }
      throw e;
    }
  }
  route.migrate = migrate;
  return route;
};
