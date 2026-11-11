// Runs a JavaScript template the way MangoIDE does on the phone: only console, prompt(), print and
// timers exist (no require, no process). The runtime is read straight out of RunService.swift.
const fs = require("fs"), path = require("path"), vm = require("vm");
const swift = fs.readFileSync(path.join(__dirname, "..", "MangoIDE", "Run", "RunService.swift"), "utf8");
const block = swift.slice(swift.indexOf("JS-RUNTIME-BEGIN"), swift.indexOf("JS-RUNTIME-END"));
const runtime = block.slice(block.indexOf('"""') + 3, block.lastIndexOf('"""'));
const input = fs.readFileSync(0, "utf8");
const lines = input.split("\n");
const sandbox = {
  __out: (s) => process.stdout.write(s + "\n"),
  __err: (s) => { process.stdout.write(s + "\n"); },
  readLine: () => (lines.length ? lines.shift() : undefined),
};
vm.createContext(sandbox);
vm.runInContext(runtime, sandbox);
const drain = () => new Promise((r) => setImmediate(r));
(async () => {
  let failed = false;
  try { vm.runInContext('"use strict";\n' + fs.readFileSync(process.argv[2], "utf8"), sandbox, { filename: process.argv[2], timeout: 10000 }); }
  catch (e) { failed = true; console.log(String(e)); }
  await drain();
  let ticks = 0;
  while (ticks < 20000 && vm.runInContext("__tick()", sandbox)) { ticks++; await drain(); }
  process.exit(failed ? 1 : 0);
})();
process.on("unhandledRejection", (e) => { console.log("Unhandled rejection: " + e); process.exit(1); });
