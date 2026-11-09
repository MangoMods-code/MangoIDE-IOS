// GitHub for MangoIDE: list repos, download a repo (clone/pull), push commits, publish a project.
// The user's GitHub token stays encrypted in the database and never goes to the app.
//
// Free:  cloning repos you own.
// Pro:   cloning anyone else's repo, pulling, pushing, publishing a new repo.

const { Readable } = require("stream");
const { pipeline } = require("stream/promises");

module.exports = function github({ decrypt, send, readBody, isPro }) {
  const API = "https://api.github.com";
  const NAME = /^[A-Za-z0-9_.-]{1,100}$/;
  const busy = new Set();

  class GHError extends Error { constructor(status, message, extra) { super(message); this.status = status; this.extra = extra; } }

  function token(u) {
    if (!u.github_token_enc) throw new GHError(401, "GitHub access is missing. Sign out and sign in with GitHub again.");
    return decrypt(u.github_token_enc);
  }

  async function gh(u, method, path, body) {
    const r = await fetch(API + path, {
      method,
      headers: {
        Authorization: `Bearer ${token(u)}`, "User-Agent": "MangoIDE", Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    const text = await r.text();
    let json = null; try { json = text ? JSON.parse(text) : null; } catch {}
    if (!r.ok) {
      if (r.status === 401) throw new GHError(401, "GitHub access expired. Sign out and sign in with GitHub again.");
      if (r.status === 404) throw new GHError(404, "That repository wasn't found, or your GitHub account can't see it.");
      if (r.status === 403 && /rate limit/i.test(json?.message || "")) throw new GHError(429, "GitHub's rate limit was hit. Try again in a few minutes.");
      throw new GHError(r.status >= 500 ? 502 : r.status, json?.message ? `GitHub: ${json.message}` : `GitHub error ${r.status}`, { github: json });
    }
    return json;
  }

  const needPro = (u, what) => { if (!isPro(u)) throw new GHError(402, `${what} is part of MangoIDE Pro.`, { pro: true }); };
  const isOwn = (u, repo) => String(repo.owner?.id) === String(u.github_id);
  const ownerName = (url) => {
    const owner = url.searchParams.get("owner") || "", name = url.searchParams.get("name") || "";
    if (!NAME.test(owner) || !NAME.test(name)) throw new GHError(400, "Use owner/name, like octocat/hello-world.");
    return { owner, name };
  };
  const shortRepo = (u, r) => ({
    owner: r.owner.login, name: r.name, fullName: r.full_name, private: r.private, own: isOwn(u, r),
    defaultBranch: r.default_branch, description: r.description, pushedAt: r.pushed_at, fork: r.fork,
  });
  const refPath = (ref) => ref.split("/").map(encodeURIComponent).join("/");

  // GET /github/repos?page=1 — repos you own, collaborate on, or can see through your orgs.
  async function repos(req, res, u, url) {
    const page = Math.max(1, Math.min(50, Number(url.searchParams.get("page") || 1)));
    const list = await gh(u, "GET", `/user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100&page=${page}`);
    send(res, 200, { pro: !!isPro(u), login: u.login, repos: list.map((r) => shortRepo(u, r)), more: list.length === 100 });
  }

  // GET /github/repo?owner=&name= — one repo (used for "clone by name") plus its branches.
  async function repo(req, res, u, url) {
    const { owner, name } = ownerName(url);
    const r = await gh(u, "GET", `/repos/${owner}/${name}`);
    const branches = await gh(u, "GET", `/repos/${owner}/${name}/branches?per_page=100`).catch(() => []);
    send(res, 200, { ...shortRepo(u, r), branches: branches.map((b) => b.name), canClone: isOwn(u, r) || !!isPro(u) });
  }

  // GET /github/archive?owner=&name=&ref=&purpose=clone|pull — streams the repo as a zip.
  // Header X-Commit-Sha says exactly which commit it is.
  async function archive(req, res, u, url) {
    const { owner, name } = ownerName(url);
    const purpose = url.searchParams.get("purpose") === "pull" ? "pull" : "clone";
    const r = await gh(u, "GET", `/repos/${owner}/${name}`);
    if (purpose === "pull") needPro(u, "Pulling changes");
    else if (!isOwn(u, r)) needPro(u, "Cloning repositories you don't own");
    const ref = url.searchParams.get("ref") || r.default_branch;
    if (!/^[A-Za-z0-9_.\/-]{1,200}$/.test(ref) || ref.includes("..")) throw new GHError(400, "Bad branch name.");
    if (busy.has(u.id)) throw new GHError(429, "Another download is still running.");
    busy.add(u.id);
    try {
      const commit = await gh(u, "GET", `/repos/${owner}/${name}/commits/${refPath(ref)}`);
      const z = await fetch(`${API}/repos/${owner}/${name}/zipball/${commit.sha}`, {
        headers: { Authorization: `Bearer ${token(u)}`, "User-Agent": "MangoIDE", Accept: "application/vnd.github+json" },
        redirect: "follow",
      });
      if (!z.ok || !z.body) throw new GHError(502, `GitHub couldn't make the download (${z.status}).`);
      res.writeHead(200, {
        "Content-Type": "application/zip", "Cache-Control": "no-store", "X-Commit-Sha": commit.sha,
        "X-Branch": ref, "X-Own": isOwn(u, r) ? "1" : "0",
        ...(z.headers.get("content-length") ? { "Content-Length": z.headers.get("content-length") } : {}),
      });
      // pipeline tears both ends down if the phone disconnects mid-download.
      await pipeline(Readable.fromWeb(z.body), res).catch(() => {});
    } finally {
      busy.delete(u.id);
    }
  }

  // POST /github/push {owner, name, branch, base, message, files:[{path, content (base64), executable?}], deletes:[path]}
  // Makes one commit on top of `base`. If GitHub has moved on since then, nothing is written and you're asked to pull.
  async function push(req, res, u) {
    needPro(u, "Pushing to GitHub");
    const b = JSON.parse((await readBody(req, 80 * 1024 * 1024)).toString("utf8") || "{}");
    const { owner, name, branch, base } = b;
    const message = String(b.message || "").trim().slice(0, 5000);
    const files = Array.isArray(b.files) ? b.files : [], deletes = Array.isArray(b.deletes) ? b.deletes : [];
    if (!NAME.test(owner || "") || !NAME.test(name || "")) throw new GHError(400, "Bad repository.");
    if (!/^[A-Za-z0-9_.\/-]{1,200}$/.test(branch || "") || branch.includes("..")) throw new GHError(400, "Bad branch name.");
    if (!/^[0-9a-f]{40}$/.test(base || "")) throw new GHError(400, "Missing the commit this project came from. Pull first.");
    if (!message) throw new GHError(400, "Write a commit message.");
    if (!files.length && !deletes.length) throw new GHError(400, "There's nothing to commit.");
    if (files.length + deletes.length > 3000) throw new GHError(400, "That's too many files for one commit. Push in smaller parts.");
    const okPath = (p) => typeof p === "string" && p.length > 0 && p.length < 1000 && !p.startsWith("/") && !p.split("/").some((s) => s === ".." || s === "." || s === "" || s === ".git");
    for (const f of files) if (!okPath(f.path) || typeof f.content !== "string") throw new GHError(400, `Bad file: ${f.path}`);
    for (const d of deletes) if (!okPath(d)) throw new GHError(400, `Bad file: ${d}`);
    if (busy.has(u.id)) throw new GHError(429, "Another GitHub action is still running.");
    busy.add(u.id);
    try {
      const repoPath = `/repos/${owner}/${name}`;
      const ref = await gh(u, "GET", `${repoPath}/git/ref/heads/${refPath(branch)}`).catch((e) => { if (e.status === 404) return null; throw e; });
      if (!ref) throw new GHError(404, `The branch ${branch} doesn't exist on GitHub anymore.`);
      if (ref.object.sha !== base) throw new GHError(409, "GitHub has newer commits than this project. Pull first, then push.", { behind: true });
      const baseCommit = await gh(u, "GET", `${repoPath}/git/commits/${base}`);

      // Upload file contents a few at a time.
      const tree = [];
      let i = 0;
      async function worker() {
        while (i < files.length) {
          const f = files[i++];
          const blob = await gh(u, "POST", `${repoPath}/git/blobs`, { content: f.content, encoding: "base64" });
          tree.push({ path: f.path, mode: f.executable ? "100755" : "100644", type: "blob", sha: blob.sha });
        }
      }
      await Promise.all(Array.from({ length: Math.min(4, files.length) }, worker));
      for (const d of deletes) tree.push({ path: d, mode: "100644", type: "blob", sha: null });

      const newTree = await gh(u, "POST", `${repoPath}/git/trees`, { base_tree: baseCommit.tree.sha, tree });
      const commit = await gh(u, "POST", `${repoPath}/git/commits`, { message, tree: newTree.sha, parents: [base] });
      try {
        await gh(u, "PATCH", `${repoPath}/git/refs/heads/${refPath(branch)}`, { sha: commit.sha, force: false });
      } catch (e) {
        if (e.status === 422) throw new GHError(409, "GitHub got newer commits while pushing. Pull first, then push.", { behind: true });
        throw e;
      }
      send(res, 200, { commit: commit.sha, url: commit.html_url });
    } finally {
      busy.delete(u.id);
    }
  }

  // POST /github/create {name, private, description} — new repo on your account, ready for the first push.
  async function create(req, res, u) {
    needPro(u, "Publishing to GitHub");
    const b = JSON.parse((await readBody(req, 64 * 1024)).toString("utf8") || "{}");
    if (!NAME.test(b.name || "")) throw new GHError(400, "Repository names can use letters, numbers, - _ and .");
    const r = await gh(u, "POST", "/user/repos", {
      name: b.name, private: b.private !== false, description: String(b.description || "").slice(0, 300) || undefined, auto_init: true,
    });
    // auto_init makes the first commit; wait for the branch to exist.
    let head = null;
    for (let t = 0; t < 8 && !head; t++) {
      head = await gh(u, "GET", `/repos/${r.owner.login}/${r.name}/git/ref/heads/${refPath(r.default_branch)}`).catch(() => null);
      if (!head) await new Promise((ok) => setTimeout(ok, 700));
    }
    if (!head) throw new GHError(502, "GitHub made the repo but it isn't ready yet. Try Link to GitHub in a minute.");
    send(res, 200, { ...shortRepo(u, r), commit: head.object.sha });
  }

  // Routes. Returns true if it handled the request.
  return async function route(req, res, u, url, p) {
    try {
      if (req.method === "GET" && p === "/github/repos") { await repos(req, res, u, url); return true; }
      if (req.method === "GET" && p === "/github/repo") { await repo(req, res, u, url); return true; }
      if (req.method === "GET" && p === "/github/archive") { await archive(req, res, u, url); return true; }
      if (req.method === "POST" && p === "/github/push") { await push(req, res, u); return true; }
      if (req.method === "POST" && p === "/github/create") { await create(req, res, u); return true; }
      return false;
    } catch (e) {
      if (e instanceof GHError) { if (!res.headersSent) send(res, e.status, { message: e.message, ...(e.extra || {}) }); else res.destroy(); return true; }
      if (e instanceof SyntaxError) { send(res, 400, { message: "Bad request." }); return true; }
      throw e;
    }
  };
};
