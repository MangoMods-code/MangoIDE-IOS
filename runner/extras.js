// Extra runner features for MangoIDE:
//   Interactive runs  POST /api/v2/sessions {language, files, args} → {id} (or {compile} if it didn't build)
//                     GET  /api/v2/sessions/:id/stream   (one JSON event per line: out / err / exit)
//                     POST /api/v2/sessions/:id/input {data, eof}
//                     POST /api/v2/sessions/:id/kill
//   Error checking    POST /api/v2/check  {language, files} → {diagnostics:[{line, col, severity, message}]}
//   Formatting        POST /api/v2/format {filename, content} → {content}
//   What's available  GET  /api/v2/tools

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { spawn, execSync } = require("child_process");

module.exports = function extras({ LANGS, findLang, fill, prepare, exec, cleanArgs, sandboxUser, readBody, send, COMPILE_TIMEOUT }) {
  const SESSION_LIMIT = Number(process.env.MAX_SESSIONS || 6);
  const SESSION_WALL = Number(process.env.SESSION_TIMEOUT_MS || 10 * 60 * 1000);
  const SESSION_UNWATCHED = 60 * 1000;
  const SESSION_OUTPUT = 2 * 1024 * 1024;
  const sessions = new Map();

  const has = (bin) => { try { execSync(`command -v ${bin}`, { stdio: "ignore", shell: "/bin/bash" }); return true; } catch { return false; } };
  const HAS_STDBUF = has("stdbuf");

  function envFor(cwd) {
    return { PATH: process.env.PATH, HOME: cwd, TMPDIR: cwd, GOCACHE: path.join(cwd, ".gocache"), GOPATH: path.join(cwd, ".go"),
             LANG: "C.UTF-8", PYTHONUNBUFFERED: "1", TERM: "dumb" };
  }

  // ---------- Interactive sessions ----------

  function emit(s, ev) {
    if (ev.t === "out" || ev.t === "err") {
      if (s.bytes >= SESSION_OUTPUT) { if (!s.capped) { s.capped = true; emit(s, { t: "err", data: "\n[Output limit reached, the rest isn't shown]\n" }); } return; }
      s.bytes += ev.data.length;
    }
    const line = JSON.stringify(ev) + "\n";
    if (s.listeners.size) for (const res of s.listeners) res.write(line);
    else s.backlog.push(line);
  }

  function finish(s) {
    clearTimeout(s.wall); clearTimeout(s.unwatched);
    for (const res of s.listeners) res.end();
    s.listeners.clear();
    fs.rm(s.dir, { recursive: true, force: true }, () => {});
    setTimeout(() => sessions.delete(s.id), 30000);   // keep the final events around briefly for a late stream
  }

  function kill(s) {
    if (s.ended) return;
    try { process.kill(-s.child.pid, "SIGKILL"); } catch { try { s.child.kill("SIGKILL"); } catch {} }
  }

  function armUnwatched(s) {
    clearTimeout(s.unwatched);
    if (!s.listeners.size && !s.ended) s.unwatched = setTimeout(() => { emit(s, { t: "err", data: "\n[Stopped: nobody was watching]\n" }); kill(s); }, SESSION_UNWATCHED);
  }

  async function startSession(body) {
    const [lang, def] = findLang(body.language);
    if (!lang) return [400, { message: `${body.language} isn't supported by this runner.` }];
    if (def.missing) return [400, { message: `${lang} isn't installed on this runner.` }];
    const files = Array.isArray(body.files) ? body.files.slice(0, 500) : [];
    if (!files.length || typeof files[0].content !== "string") return [400, { message: "No code was sent." }];
    const live = [...sessions.values()].filter((s) => !s.ended).length;
    if (live >= SESSION_LIMIT) return [429, { message: "The runner is busy, try again in a moment." }];

    const { dir, mainPath } = prepare(def, files, !!body.keep_names);
    const vars = { file: mainPath, dir };
    let compile = null;
    if (def.compile) {
      compile = await exec(fill(def.compile, vars), { cwd: dir, timeout: COMPILE_TIMEOUT });
      if (compile.code !== 0) { fs.rm(dir, { recursive: true, force: true }, () => {}); return [200, { compile }]; }
    }
    let cmd = [...fill(def.run, vars), ...cleanArgs(body.args)];
    if (HAS_STDBUF) cmd = ["stdbuf", "-o0", "-e0", ...cmd];   // so prompts show before the program waits for input
    const opts = { cwd: dir, env: envFor(dir), detached: true };
    if (sandboxUser) { opts.uid = sandboxUser.uid; opts.gid = sandboxUser.gid; }
    let child;
    try { child = spawn(cmd[0], cmd.slice(1), opts); }
    catch (e) { fs.rm(dir, { recursive: true, force: true }, () => {}); return [500, { message: e.message }]; }

    const id = crypto.randomBytes(12).toString("hex");
    const s = { id, child, dir, listeners: new Set(), backlog: [], bytes: 0, ended: false, capped: false };
    sessions.set(id, s);
    child.stdout.on("data", (d) => emit(s, { t: "out", data: d.toString() }));
    child.stderr.on("data", (d) => emit(s, { t: "err", data: d.toString() }));
    child.stdin.on("error", () => {});
    child.on("error", (e) => emit(s, { t: "err", data: e.message }));
    child.on("close", (code, signal) => {
      s.ended = true;
      try { process.kill(-child.pid, "SIGKILL"); } catch {}
      emit(s, { t: "exit", code: s.timedOut ? null : code, signal: s.timedOut ? "SIGKILL" : signal, timedOut: !!s.timedOut });
      finish(s);
    });
    s.wall = setTimeout(() => { s.timedOut = true; emit(s, { t: "err", data: `\n[Time limit of ${Math.round(SESSION_WALL / 60000)} min reached]\n` }); kill(s); }, SESSION_WALL);
    armUnwatched(s);
    return [200, { id, compile }];
  }

  function stream(req, res, s) {
    res.writeHead(200, { "Content-Type": "application/x-ndjson", "Cache-Control": "no-store", "X-Accel-Buffering": "no" });
    res.write(JSON.stringify({ t: "hello" }) + "\n");
    for (const line of s.backlog) res.write(line);
    s.backlog = [];
    if (s.ended && !s.listeners.size) { res.end(); return; }
    s.listeners.add(res);
    clearTimeout(s.unwatched);
    const keepAlive = setInterval(() => res.write(JSON.stringify({ t: "ping" }) + "\n"), 15000);
    req.on("close", () => { clearInterval(keepAlive); s.listeners.delete(res); armUnwatched(s); });
  }

  // ---------- Error checking ----------

  const PY_CHECK = [
    "import sys, json",
    "src = open(sys.argv[1], encoding='utf-8', errors='replace').read()",
    "try:",
    "    compile(src, sys.argv[1], 'exec')",
    "    print('[]')",
    "except SyntaxError as e:",
    "    print(json.dumps([{'line': e.lineno or 1, 'col': e.offset or 1, 'severity': 'error', 'message': e.msg}]))",
  ].join("\n");

  // name: the file name to check under (some compilers care, e.g. Java's public class).
  const CHECKERS = {
    python: { cmd: ["python3", "-c", PY_CHECK, "{file}"], parse: "json" },
    javascript: { cmd: ["node", "--check", "{file}"], parse: "node" },
    c: { cmd: ["gcc", "-fsyntax-only", "-Wall", "-fno-diagnostics-color", "{file}"], parse: "gcc" },
    "c++": { cmd: ["g++", "-fsyntax-only", "-std=c++20", "-Wall", "-fno-diagnostics-color", "{file}"], parse: "gcc" },
    go: { cmd: ["gofmt", "-e", "-l", "{file}"], parse: "gcc" },
    rust: { cmd: ["rustc", "--error-format=short", "--emit=metadata", "--crate-type", "bin", "-o", "{dir}/check.rmeta", "{file}"], parse: "gcc" },
    swift: { cmd: ["swiftc", "-typecheck", "{file}"], parse: "gcc" },
    java: { cmd: ["javac", "-Xlint:none", "-d", "{dir}/classes", "{file}"], parse: "javac", keepName: true },
    ruby: { cmd: ["ruby", "-wc", "{file}"], parse: "ruby" },
    php: { cmd: ["php", "-l", "{file}"], parse: "php" },
    lua: { cmd: ["luac5.4", "-p", "{file}"], parse: "lua" },
    bash: { cmd: ["bash", "-n", "{file}"], parse: "bash" },
    perl: { cmd: ["perl", "-c", "{file}"], parse: "perl" },
  };

  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

  function parse(kind, out, name) {
    const n = esc(name);
    const list = [];
    const add = (line, col, severity, message) => {
      message = String(message || "").trim();
      if (!message || list.length >= 200) return;
      list.push({ line: Math.max(1, Number(line) || 1), col: Math.max(1, Number(col) || 1), severity: /warn/i.test(severity) ? "warning" : /note/i.test(severity) ? "info" : "error", message });
    };
    const lines = out.split("\n");
    if (kind === "json") {
      try { for (const d of JSON.parse(lines.find((l) => l.trim().startsWith("[")) || "[]")) add(d.line, d.col, d.severity, d.message); } catch {}
      return list;
    }
    if (kind === "node") {
      const m = out.match(new RegExp(`${n}:(\\d+)`));
      const msg = lines.find((l) => /^\w*Error:/.test(l));
      if (m || msg) add(m ? m[1] : 1, 1, "error", msg || "Syntax error");
      return list;
    }
    for (const l of lines) {
      let m;
      if (kind === "gcc" && (m = l.match(new RegExp(`(?:^|/)${n}:(\\d+):(\\d+):\\s*(?:(fatal error|error|warning|note)(?:\\[\\w+\\])?\\s*:)?\\s*(.*)$`)))) add(m[1], m[2], m[3] || "error", m[4]);
      else if (kind === "javac" && (m = l.match(new RegExp(`(?:^|/)${n}:(\\d+):\\s*(error|warning):\\s*(.*)$`)))) add(m[1], 1, m[2], m[3]);
      else if (kind === "ruby" && (m = l.match(new RegExp(`(?:^|/)${n}:(\\d+):\\s*(warning:)?\\s*(.*)$`)))) add(m[1], 1, m[2] ? "warning" : "error", m[3]);
      else if (kind === "php" && (m = l.match(/(?:Parse|Fatal) error:\s*(.*?) in .* on line (\d+)/))) add(m[2], 1, "error", m[1]);
      else if (kind === "lua" && (m = l.match(new RegExp(`(?:^|/)${n}:(\\d+):\\s*(.*)$`)))) add(m[1], 1, "error", m[2]);
      else if (kind === "bash" && (m = l.match(new RegExp(`(?:^|/)${n}: line (\\d+):\\s*(.*)$`)))) add(m[1], 1, "error", m[2]);
      else if (kind === "perl" && (m = l.match(new RegExp(`^(.*) at (?:.*/)?${n} line (\\d+)[.,]`)))) add(m[2], 1, "error", m[1]);
    }
    return list;
  }

  async function check(body) {
    const [lang] = findLang(body.language);
    const c = lang && CHECKERS[lang];
    if (!c) return [200, { diagnostics: [], supported: false }];
    const f = Array.isArray(body.files) && body.files[0];
    if (!f || typeof f.content !== "string" || f.content.length > 1024 * 1024) return [400, { message: "No code was sent." }];
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "chk-"));
    try {
      const def = LANGS[lang];
      const base = path.basename(String(f.name || "")) || ("main." + def.ext);
      const name = c.keepName ? base : "main." + def.ext;
      const file = path.join(dir, name);
      fs.writeFileSync(file, f.content);
      if (sandboxUser) execSync(`chown -R ${sandboxUser.uid}:${sandboxUser.gid} ${JSON.stringify(dir)}`, { stdio: "ignore" });
      const r = await exec(fill(c.cmd, { file, dir }), { cwd: dir, timeout: 20000 });
      return [200, { diagnostics: parse(c.parse, (r.stdout || "") + "\n" + (r.stderr || ""), name), supported: true }];
    } finally {
      fs.rm(dir, { recursive: true, force: true }, () => {});
    }
  }

  // ---------- Formatting ----------

  const PRETTIER = new Set(["js", "jsx", "mjs", "cjs", "ts", "tsx", "json", "css", "scss", "less", "html", "htm", "vue", "md", "markdown", "yaml", "yml", "graphql", "gql"]);
  const CLANG = new Set(["c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm", "java", "cs", "proto"]);
  const TOOLS = { prettier: has("prettier"), clang: has("clang-format"), gofmt: has("gofmt"), rustfmt: has("rustfmt"), black: has("black"), shfmt: has("shfmt") };

  function formatterFor(ext) {
    if (PRETTIER.has(ext) && TOOLS.prettier) return ["prettier", "--stdin-filepath", "main." + ext];
    if (CLANG.has(ext) && TOOLS.clang) return ["clang-format", "--assume-filename=main." + ext];
    if (ext === "go" && TOOLS.gofmt) return ["gofmt"];
    if (ext === "rs" && TOOLS.rustfmt) return ["rustfmt", "--edition", "2021"];
    if ((ext === "py" || ext === "pyw") && TOOLS.black) return ["black", "-q", "-"];
    if ((ext === "sh" || ext === "bash" || ext === "zsh") && TOOLS.shfmt) return ["shfmt"];
    return null;
  }

  async function format(body) {
    const ext = path.extname(String(body.filename || "")).slice(1).toLowerCase();
    const cmd = formatterFor(ext);
    if (!cmd) return [400, { message: `No formatter for .${ext || "?"} files on this runner.` }];
    if (typeof body.content !== "string" || body.content.length > 2 * 1024 * 1024) return [400, { message: "Nothing to format." }];
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "fmt-"));
    try {
      if (sandboxUser) fs.chownSync(dir, sandboxUser.uid, sandboxUser.gid);
      const r = await exec(cmd, { cwd: dir, stdin: body.content, timeout: 20000 });
      if (r.code !== 0) return [422, { message: (r.stderr || "The formatter couldn't read this file.").trim().split("\n").slice(0, 6).join("\n") }];
      return [200, { content: r.stdout }];
    } finally {
      fs.rm(dir, { recursive: true, force: true }, () => {});
    }
  }

  function tools() {
    const fmt = [...PRETTIER, ...CLANG, "go", "rs", "py", "sh"].filter((e) => formatterFor(e));
    return { format: fmt, check: Object.keys(CHECKERS).filter((l) => !LANGS[l]?.missing), interactive: true };
  }

  // ---------- Routes ----------

  function withBody(req, res, limit, fn) {
    readBody(req, limit).then(async (raw) => {
      let body;
      try { body = JSON.parse(raw || "{}"); } catch { return send(res, 400, { message: "Request wasn't valid JSON." }); }
      try { const [status, out] = await fn(body); send(res, status, out); }
      catch (e) { send(res, 500, { message: "Runner error: " + e.message }); }
    }, (e) => send(res, 413, { message: e.message }));
  }

  function route(req, res, url) {
    if (req.method === "GET" && url === "/api/v2/tools") { send(res, 200, tools()); return true; }
    if (req.method === "POST" && url === "/api/v2/check") { withBody(req, res, 2 * 1024 * 1024, check); return true; }
    if (req.method === "POST" && url === "/api/v2/format") { withBody(req, res, 3 * 1024 * 1024, format); return true; }
    if (req.method === "POST" && url === "/api/v2/sessions") { withBody(req, res, 8 * 1024 * 1024, startSession); return true; }
    const m = url.match(/^\/api\/v2\/sessions\/([0-9a-f]{24})\/(stream|input|kill)$/);
    if (!m) return false;
    const s = sessions.get(m[1]);
    if (!s) { send(res, 404, { message: "That run has finished." }); return true; }
    if (req.method === "GET" && m[2] === "stream") { stream(req, res, s); return true; }
    if (req.method === "POST" && m[2] === "input") {
      withBody(req, res, 256 * 1024, async (b) => {
        if (s.ended) return [410, { message: "The program already finished." }];
        if (typeof b.data === "string" && b.data) s.child.stdin.write(b.data);
        if (b.eof) s.child.stdin.end();
        return [200, { ok: true }];
      });
      return true;
    }
    if (req.method === "POST" && m[2] === "kill") { kill(s); send(res, 200, { ok: true }); return true; }
    return false;
  }

  return { route };
};
