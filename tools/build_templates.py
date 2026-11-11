#!/usr/bin/env python3
"""Turns templates/<language>.pack into MangoIDE/Resources/templates-<language>.json.

Pack format:
    === slug | Name | Category | sf.symbol | One-line summary
    @entry main.py          (optional; defaults to main.py, else the first file)
    --- path/to/file
    file contents...

`__PROJECT__` in paths or contents becomes the project's name when someone creates it.
Run with --test to also execute every Python template (empty input) and report failures.
"""
import json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def parse(path, language):
    out, cur, fname, buf = [], None, None, []
    def flush():
        nonlocal fname, buf
        if cur is not None and fname:
            cur["files"][fname] = "\n".join(buf).strip("\n") + "\n"
        fname, buf = None, []
    for line in open(path, encoding="utf-8").read().split("\n"):
        if line.startswith("=== "):
            flush()
            slug, name, category, icon, summary = [p.strip() for p in line[4:].split("|", 4)]
            cur = {"id": f"{language}/{slug}", "name": name, "category": category, "icon": icon,
                   "summary": summary, "language": language, "entry": "", "files": {}}
            out.append(cur)
        elif line.startswith("@entry ") and cur is not None and fname is None:
            cur["entry"] = line[7:].strip()
        elif line.startswith("--- "):
            flush(); fname = line[4:].strip()
        elif fname is not None:
            buf.append(line)
    flush()
    for t in out:
        assert t["files"], t["id"]
        if not t["entry"]:
            t["entry"] = next((f for f in t["files"] if f.startswith("main.")), next(iter(t["files"])))
        assert t["entry"] in t["files"], (t["id"], t["entry"])
    assert len({t["id"] for t in out}) == len(out), "duplicate slug"
    return out

def test(templates):
    bad = 0
    for t in templates:
        with tempfile.TemporaryDirectory() as d:
            for p, c in t["files"].items():
                full = os.path.join(d, p)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                open(full, "w", encoding="utf-8").write(c)
            try:
                if t["language"] == "python":
                    cmd = [sys.executable, t["entry"]]
                elif t["language"] == "javascript":
                    cmd = ["node", os.path.join(ROOT, "tools", "js_run.js"), t["entry"]]
                else:  # swift: compile, then run
                    c = subprocess.run(["swiftc", "-Onone", "-o", "a.out", t["entry"]], cwd=d, capture_output=True, text=True, timeout=300)
                    if c.returncode != 0:
                        bad += 1
                        print("FAIL", t["id"], "- does not compile:\n" + "\n".join(l for l in c.stderr.splitlines() if "error" in l or "^" in l or "|" in l)[:1500])
                        continue
                    cmd = ["./a.out"]
                r = subprocess.run(cmd, cwd=d, input="", capture_output=True, text=True, timeout=30)
                ok, why = r.returncode == 0, ((r.stderr.strip() or r.stdout.strip()).splitlines() or ["exit %d" % r.returncode])[-1]
            except subprocess.TimeoutExpired:
                ok, why = False, "timed out"
        if not ok:
            bad += 1; print("FAIL", t["id"], "-", why)
    print(f"{len(templates) - bad}/{len(templates)} ran cleanly")
    return bad

def main():
    failures = 0
    for f in sorted(os.listdir(os.path.join(ROOT, "templates"))):
        if not f.endswith(".pack"): continue
        lang = f[:-5]
        ts = parse(os.path.join(ROOT, "templates", f), lang)
        dest = os.path.join(ROOT, "MangoIDE", "Resources", f"templates-{lang}.json")
        json.dump(ts, open(dest, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print(f"{lang}: {len(ts)} templates -> {os.path.relpath(dest, ROOT)}")
        import shutil
        can = {"python": True, "javascript": bool(shutil.which("node")), "swift": bool(shutil.which("swiftc"))}
        only = [a[7:] for a in sys.argv if a.startswith("--only=")]
        if "--test" in sys.argv and can.get(lang) and (not only or lang in only): failures += test(ts)
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    main()
