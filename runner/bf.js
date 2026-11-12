// A small Brainfuck interpreter: node bf.js program.bf  (input comes from stdin)
const fs = require("fs");
const code = [...fs.readFileSync(process.argv[2], "utf8")].filter((c) => "+-<>[].,".includes(c));
const jump = {}, stack = [];
code.forEach((c, i) => {
  if (c === "[") stack.push(i);
  if (c === "]") {
    if (!stack.length) { console.error(`Unmatched ] (instruction ${i + 1})`); process.exit(1); }
    const j = stack.pop(); jump[i] = j; jump[j] = i;
  }
});
if (stack.length) { console.error("Unmatched ["); process.exit(1); }
let input = Buffer.alloc(0);
try { input = fs.readFileSync(0); } catch {}
const tape = new Uint8Array(300000);
let ptr = 0, inAt = 0, out = [];
const flush = () => { process.stdout.write(Buffer.from(out)); out = []; };
for (let pc = 0; pc < code.length; pc++) {
  switch (code[pc]) {
    case "+": tape[ptr]++; break;
    case "-": tape[ptr]--; break;
    case ">": if (++ptr >= tape.length) ptr = 0; break;
    case "<": if (--ptr < 0) ptr = tape.length - 1; break;
    case ".": out.push(tape[ptr]); if (out.length > 4096) flush(); break;
    case ",": tape[ptr] = inAt < input.length ? input[inAt++] : 0; break;
    case "[": if (!tape[ptr]) pc = jump[pc]; break;
    case "]": if (tape[ptr]) pc = jump[pc]; break;
  }
}
flush();
