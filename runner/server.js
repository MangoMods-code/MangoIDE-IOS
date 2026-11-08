// MangoIDE runner: a tiny Piston-compatible code execution server.
// POST /api/v2/execute  { language, files: [{ name, content }], stdin }
// GET  /api/v2/runtimes
// Every request needs the key from the RUNNER_KEY variable (Authorization: Bearer <key> or X-Runner-Key).

const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { spawn, execSync } = require("child_process");

const PORT = Number(process.env.PORT || 8080);
const KEY = process.env.RUNNER_KEY || "";
const RUN_TIMEOUT = Number(process.env.RUN_TIMEOUT_MS || 15000);
const COMPILE_TIMEOUT = Number(process.env.COMPILE_TIMEOUT_MS || 60000);
const MAX_OUTPUT = 256 * 1024;
const MAX_BODY = 2 * 1024 * 1024;
const MAX_CONCURRENT = Number(process.env.MAX_CONCURRENT || 4);

let sandboxUser = null;
try {
  sandboxUser = {
    uid: Number(execSync("id -u runner").toString().trim()),
    gid: Number(execSync("id -g runner").toString().trim()),
  };
} catch { /* running locally without the sandbox user */ }

// language -> how to run it. {file} is the source path, {dir} the work folder.
const LANGS = {
  python:     { aliases: ["py", "python3"], ext: "py", run: ["python3", "-u", "{file}"], version: "python3 --version" },
  javascript: { aliases: ["js", "node"], ext: "js", run: ["node", "{file}"], version: "node --version" },
  typescript: { aliases: ["ts"], ext: "ts", run: ["tsx", "{file}"], version: "tsx --version" },
  java:       { aliases: [], ext: "java", run: ["java", "-Xmx256m", "{file}"], version: "java -version 2>&1 | head -1" },
  c:          { aliases: ["gcc"], ext: "c", compile: ["gcc", "-O2", "-o", "{dir}/a.out", "{file}", "-lm"], run: ["{dir}/a.out"], version: "gcc -dumpversion" },
  "c++":      { aliases: ["cpp", "g++"], ext: "cpp", compile: ["g++", "-O2", "-std=c++20", "-o", "{dir}/a.out", "{file}"], run: ["{dir}/a.out"], version: "g++ -dumpversion" },
  go:         { aliases: ["golang"], ext: "go", compile: ["go", "build", "-o", "{dir}/a.out", "{file}"], run: ["{dir}/a.out"], version: "go version" },
  rust:       { aliases: ["rs"], ext: "rs", compile: ["rustc", "-O", "-o", "{dir}/a.out", "{file}"], run: ["{dir}/a.out"], version: "rustc --version" },
  ruby:       { aliases: ["rb"], ext: "rb", run: ["ruby", "{file}"], version: "ruby --version" },
  php:        { aliases: [], ext: "php", run: ["php", "{file}"], version: "php -r 'echo PHP_VERSION;'" },
  lua:        { aliases: [], ext: "lua", run: ["lua5.4", "{file}"], version: "lua5.4 -v" },
  bash:       { aliases: ["sh", "shell"], ext: "sh", run: ["bash", "{file}"], version: "bash --version | head -1" },
  perl:       { aliases: ["pl"], ext: "pl", run: ["perl", "{file}"], version: "perl -e 'print $^V'" },
  sqlite3:    { aliases: ["sql", "sqlite"], ext: "sql", run: ["sh", "-c", "sqlite3 -header -column :memory: < {file}"], version: "sqlite3 --version | cut -d' ' -f1" },
  fortran:    { aliases: ["gfortran"], ext: "f90", compile: ["gfortran", "-O2", "-o", "{dir}/a.out", "{file}"], run: ["{dir}/a.out"], version: "gfortran -dumpversion" },
  pascal:     { aliases: ["fpc"], ext: "pas", compile: ["fpc", "-O2", "-v0", "-o{dir}/a.out", "{file}"], run: ["{dir}/a.out"], version: "fpc -iV" },
  nim:        { aliases: [], ext: "nim", compile: ["nim", "c", "--hints:off", "--nimcache:{dir}/cache", "-o:{dir}/a.out", "{file}"], run: ["{dir}/a.out"], version: "nim --version | head -1" },
  elixir:     { aliases: ["exs"], ext: "exs", run: ["elixir", "{file}"], version: "elixir --version | tail -1" },
  rscript:    { aliases: ["r"], ext: "r", run: ["Rscript", "{file}"], version: "Rscript --version 2>&1" },
  kotlin:     { aliases: ["kt"], ext: "kts", run: ["kotlinc", "-script", "{file}"], version: "kotlinc -version 2>&1 | tail -1", wrapKotlin: true },
  csharp:     { aliases: ["cs", "c#"], ext: "cs", compile: ["mcs", "-out:{dir}/a.exe", "{file}"], run: ["mono", "{dir}/a.exe"], version: "mcs --version" },
  haskell:    { aliases: ["hs"], ext: "hs", compile: ["ghc", "-O0", "-outputdir", "{dir}/obj", "-o", "{dir}/a.out", "{file}"], run: ["{dir}/a.out"], version: "ghc --numeric-version" },
};

// Work out which languages are actually installed, and their versions.
const RUNTIMES = [];
for (const [name, def] of Object.entries(LANGS)) {
  try {
    const v = execSync(def.version, { stdio: ["ignore", "pipe", "pipe"], timeout: 15000, shell: "/bin/bash" })
      .toString().trim().split("\n")[0].replace(/^[^\d]*/, "").split(/\s/)[0] || "installed";
    def.versionString = v;
    RUNTIMES.push({ language: name, version: v, aliases: def.aliases, runtime: name });
  } catch { def.missing = true; }
}
console.log("Runtimes:", RUNTIMES.map(r => `${r.language} ${r.version}`).join(", "));
if (!KEY) console.warn("WARNING: RUNNER_KEY is not set, so every request will be refused.");

function findLang(name) {
  const n = String(name || "").toLowerCase();
  for (const [key, def] of Object.entries(LANGS)) {
    if (key === n || def.aliases.includes(n)) return [key, def];
  }
  return [null, null];
}

function fill(args, vars) {
  return args.map(a => a.replace("{file}", vars.file).replace(/\{dir\}/g, vars.dir));
}

function exec(cmd, { cwd, stdin, timeout }) {
  return new Promise(resolve => {
    const env = { PATH: process.env.PATH, HOME: cwd, TMPDIR: cwd, GOCACHE: path.join(cwd, ".gocache"), GOPATH: path.join(cwd, ".go"), LANG: "C.UTF-8" };
    const opts = { cwd, env, detached: true };
    if (sandboxUser) { opts.uid = sandboxUser.uid; opts.gid = sandboxUser.gid; }
    let child;
    try { child = spawn(cmd[0], cmd.slice(1), opts); }
    catch (e) { return resolve({ stdout: "", stderr: String(e.message), code: 127, signal: null }); }
    let stdout = "", stderr = "", killedBy = null;
    const cap = (buf, add) => (buf.length >= MAX_OUTPUT ? buf : (buf + add).slice(0, MAX_OUTPUT));
    child.stdout.on("data", d => { stdout = cap(stdout, d.toString()); });
    child.stderr.on("data", d => { stderr = cap(stderr, d.toString()); });
    const timer = setTimeout(() => {
      killedBy = "SIGKILL";
      try { process.kill(-child.pid, "SIGKILL"); } catch { try { child.kill("SIGKILL"); } catch {} }
    }, timeout);
    child.on("error", e => { stderr += e.message; });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      try { process.kill(-child.pid, "SIGKILL"); } catch {}
      if (killedBy) stderr += `\n[Time limit of ${Math.round(timeout / 1000)}s reached]`;
      if (stdout.length >= MAX_OUTPUT) stdout += "\n[Output cut off]";
      resolve({ stdout, stderr, code: killedBy ? null : code, signal: killedBy || signal, output: stdout + stderr });
    });
    if (stdin) child.stdin.write(stdin);
    child.stdin.on("error", () => {});
    child.stdin.end();
  });
}

let running = 0;

async function execute(body) {
  const [lang, def] = findLang(body.language);
  if (!lang) return [400, { message: `${body.language} isn't supported by this runner.` }];
  if (def.missing) return [400, { message: `${lang} isn't installed on this runner.` }];
  const files = Array.isArray(body.files) ? body.files : [];
  if (!files.length || typeof files[0].content !== "string") return [400, { message: "No code was sent." }];
  if (running >= MAX_CONCURRENT) return [429, { message: "The runner is busy, try again in a moment." }];
  running++;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "run-"));
  try {
    if (sandboxUser) fs.chownSync(dir, sandboxUser.uid, sandboxUser.gid);
    let mainPath = null;
    files.forEach((f, i) => {
      let name = path.basename(String(f.name || `file${i}`)) || `file${i}`;
      if (i === 0) name = "main." + def.ext;
      const p = path.join(dir, name);
      let content = f.content;
      // Kotlin scripts don't call main() on their own.
      if (i === 0 && def.wrapKotlin && /fun\s+main\s*\(/.test(content)) content += "\n\nmain()\n";
      fs.writeFileSync(p, content);
      if (sandboxUser) fs.chownSync(p, sandboxUser.uid, sandboxUser.gid);
      if (i === 0) mainPath = p;
    });
    const vars = { file: mainPath, dir };
    const result = { language: lang, version: def.versionString };
    if (def.compile) {
      const c = await exec(fill(def.compile, vars), { cwd: dir, timeout: COMPILE_TIMEOUT });
      result.compile = c;
      if (c.code !== 0) return [200, result];
    }
    result.run = await exec(fill(def.run, vars), { cwd: dir, stdin: body.stdin || "", timeout: RUN_TIMEOUT });
    return [200, result];
  } finally {
    running--;
    fs.rm(dir, { recursive: true, force: true }, () => {});
  }
}

function authorized(req) {
  if (!KEY) return false;
  const h = req.headers["authorization"] || "";
  const given = h.startsWith("Bearer ") ? h.slice(7) : (req.headers["x-runner-key"] || "");
  const a = Buffer.from(String(given)), b = Buffer.from(KEY);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function send(res, status, obj) {
  const data = JSON.stringify(obj);
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) });
  res.end(data);
}

http.createServer((req, res) => {
  const url = (req.url || "/").split("?")[0].replace(/\/+$/, "") || "/";
  if (req.method === "GET" && (url === "/" || url === "/health")) {
    return send(res, 200, { ok: true, name: "MangoIDE runner", languages: RUNTIMES.length });
  }
  if (!authorized(req)) return send(res, 401, { message: "Wrong or missing runner key. Check Settings › Run in MangoIDE." });
  if (req.method === "GET" && url === "/api/v2/runtimes") return send(res, 200, RUNTIMES);
  if (req.method === "POST" && url === "/api/v2/execute") {
    let raw = "";
    let tooBig = false;
    req.on("data", d => { raw += d; if (raw.length > MAX_BODY) { tooBig = true; req.destroy(); } });
    req.on("end", async () => {
      if (tooBig) return;
      let body;
      try { body = JSON.parse(raw); } catch { return send(res, 400, { message: "Request wasn't valid JSON." }); }
      try { const [status, out] = await execute(body); send(res, status, out); }
      catch (e) { send(res, 500, { message: "Runner error: " + e.message }); }
    });
    return;
  }
  send(res, 404, { message: "Not found" });
}).listen(PORT, () => console.log(`MangoIDE runner listening on ${PORT}`));
