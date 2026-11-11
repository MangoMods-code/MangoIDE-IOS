// Opens every web template in a phone-sized browser and fails on any page error, console error or
// missing file. Also taps around a little so click handlers run. Needs Playwright (skipped without it).
//   node tools/web_test.js [--shots=<dir>] [slug ...]
const fs = require("fs"), os = require("os"), path = require("path");
let chromium;
try { ({ chromium } = require("playwright")); } catch (e) { console.log("web: Playwright not installed, skipped"); process.exit(0); }

const root = path.join(__dirname, "..");
const templates = JSON.parse(fs.readFileSync(path.join(root, "MangoIDE", "Resources", "templates-web.json"), "utf8"));
const shots = (process.argv.find((a) => a.startsWith("--shots=")) || "").slice(8);
const only = process.argv.slice(2).filter((a) => !a.startsWith("--"));

(async () => {
  const browser = await chromium.launch();
  let bad = 0;
  for (const t of templates) {
    const slug = t.id.split("/")[1];
    if (only.length && !only.includes(slug)) continue;
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "webt-"));
    for (const [name, content] of Object.entries(t.files)) {
      fs.mkdirSync(path.dirname(path.join(dir, name)), { recursive: true });
      fs.writeFileSync(path.join(dir, name), content);
    }
    const page = await browser.newPage({ viewport: { width: 390, height: 760 }, hasTouch: true, isMobile: true });
    const problems = [];
    page.on("pageerror", (e) => problems.push("error: " + e.message));
    page.on("console", (m) => { if (m.type() === "error") problems.push("console: " + m.text()); });
    page.on("requestfailed", (r) => problems.push("missing: " + r.url()));
    await page.goto("file://" + path.join(dir, t.entry));
    await page.waitForTimeout(400);
    if (shots) await page.screenshot({ path: path.join(shots, slug + ".png") });
    // Tap every button once (twice for the first), type into text fields, swipe on canvases and boards.
    for (const input of await page.$$("input:not([type=checkbox]):not([type=range])")) await input.fill("Test 123").catch(() => {});
    const buttons = await page.$$("button");
    for (const b of buttons.slice(0, 40)) await b.click({ timeout: 500, force: true }).catch(() => {});
    for (const sel of ["canvas", "#board"]) {
      const box = await (await page.$(sel))?.boundingBox();
      if (!box) continue;
      for (const [dx, dy] of [[80, 0], [0, 80], [-80, 0], [0, -80]]) {
        const x = box.x + box.width / 2, y = box.y + box.height / 2;
        await page.mouse.move(x, y); await page.mouse.down(); await page.mouse.move(x + dx, y + dy, { steps: 4 }); await page.mouse.up();
      }
    }
    await page.waitForTimeout(500);
    if (shots) await page.screenshot({ path: path.join(shots, slug + "-after.png") });
    const wide = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    if (wide > 2) problems.push(`page is ${wide}px wider than the screen`);
    if (problems.length) { bad++; console.log("FAIL", t.id, "-", [...new Set(problems)].join(" | ")); }
    await page.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
  await browser.close();
  console.log(`web: ${templates.length - bad}/${templates.length} opened cleanly`);
  process.exit(bad ? 1 : 0);
})();
