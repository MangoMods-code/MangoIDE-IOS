// Runs a tiny "hello" program in the newer languages when the server starts and logs which ones work,
// so a broken install shows up in the logs instead of on someone's phone.
const SAMPLES = {
  "objective-c": "#import <Foundation/Foundation.h>\n\nint main(void) {\n    NSAutoreleasePool *pool = [NSAutoreleasePool new];\n    NSString *name = @\"MangoIDE\";\n    printf(\"Hello from %s!\\n\", [name UTF8String]);\n    [pool drain];\n    return 0;\n}\n",
  vlang: "fn main() {\n\tname := 'MangoIDE'\n\tprintln('Hello from ${name}!')\n}\n",
  powershell: "$name = \"MangoIDE\"\nWrite-Output \"Hello from $name!\"\n",
  fish: "set name MangoIDE\necho \"Hello from $name!\"\n",
  zsh: "name=MangoIDE\necho \"Hello from $name!\"\n",
  commonlisp: "(let ((name \"MangoIDE\"))\n  (format t \"Hello from ~a!~%\" name))\n",
  guile: "(display \"Hello from MangoIDE!\")\n(newline)\n",
  forth: ": hello  .\" Hello from MangoIDE!\" cr ;\nhello\n",
  sml: "val name = \"MangoIDE\";\nval () = print (\"Hello from \" ^ name ^ \"!\\n\");\n",
  raku: "my $name = \"MangoIDE\";\nsay \"Hello from $name!\";\n",
  haxe: "class Main {\n    static function main() {\n        var name = \"MangoIDE\";\n        Sys.println('Hello from $name!');\n    }\n}\n",
  vala: "void main () {\n    string name = \"MangoIDE\";\n    print (\"Hello from %s!\\n\", name);\n}\n",
  basic: "name$ = \"MangoIDE\"\nprint \"Hello from \", name$, \"!\"\n",
  brainfuck: "++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.\n",
  rexx: "/* REXX */\nname = \"MangoIDE\"\nsay \"Hello from\" name\"!\"\n",
  algol68: "BEGIN\n  STRING name = \"MangoIDE\";\n  print((\"Hello from \", name, \"!\", new line))\nEND\n",
  pike: "int main() {\n    string name = \"MangoIDE\";\n    write(\"Hello from %s!\\n\", name);\n    return 0;\n}\n",
  fennel: "(local name \"MangoIDE\")\n(print (.. \"Hello from \" name \"!\"))\n",
  hy: "(setv name \"MangoIDE\")\n(print f\"Hello from {name}!\")\n",
  coffeescript: "name = \"MangoIDE\"\nconsole.log \"Hello from #{name}!\"\n",
  nushell: "let name = \"MangoIDE\"\nprint $\"Hello from ($name)!\"\n",
  jq: "\"Hello from \\(\"MangoIDE\")!\"\n",
  sed: "s/world/MangoIDE/g\n",
  bc: "print \"Hello from MangoIDE!\\n\"\n",
  m4: "define(`name', `MangoIDE')dnl\nHello from name!\n",
};

module.exports = async function selfTest(execute, LANGS) {
  const ok = [], bad = [];
  for (const [language, content] of Object.entries(SAMPLES)) {
    if (!LANGS[language] || LANGS[language].missing) continue;
    try {
      const [, r] = await execute({ language, files: [{ content }], stdin: language === "sed" ? "Hello from world!\n" : "" });
      const out = (r.run && r.run.stdout) || "";
      if (out.includes("Hello")) ok.push(language);
      else {
        const why = ((r.compile && r.compile.code !== 0 ? r.compile.output : r.run && r.run.output) || r.message || "no output").trim().split("\n").slice(-3).join(" / ");
        bad.push(`${language} (${why.slice(0, 300)})`);
      }
    } catch (e) { bad.push(`${language} (${e.message})`); }
  }
  console.log(`Self-test passed: ${ok.join(", ") || "none"}`);
  if (bad.length) console.log(`Self-test FAILED: ${bad.join(" | ")}`);
};
