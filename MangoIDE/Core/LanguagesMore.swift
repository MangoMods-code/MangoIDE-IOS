import Foundation

/// Extra languages and file formats. Same shape as LanguageLibrary.core; runner names match the runner server.
extension LanguageLibrary {
    private static func L(_ id: String, _ name: String, _ ext: [String], kw: [String] = [], types: [String] = [],
                          lit: [String] = [], line: String? = nil, block: (String, String)? = nil,
                          quotes: [String] = ["\"", "'"], runner: String? = nil, template: String? = nil,
                          markup: Bool = false, deco: Bool = false, pre: Bool = false, ci: Bool = false) -> LanguageDef {
        LanguageDef(id: id, name: name, extensions: ext, keywords: kw.isEmpty ? nil : kw, types: types.isEmpty ? nil : types,
                    literals: lit.isEmpty ? nil : lit, lineComment: line, blockCommentStart: block?.0, blockCommentEnd: block?.1,
                    quotes: quotes, runner: runner, template: template, markup: markup ? true : nil,
                    decorators: deco ? true : nil, preprocessor: pre ? true : nil, caseInsensitive: ci ? true : nil)
    }

    static let more: [LanguageDef] = [
        // Apple & systems
        L("objc", "Objective-C", ["m", "mm"], kw: ["@interface", "@implementation", "@end", "@property", "@synthesize", "@protocol", "@class", "@selector", "self", "super", "if", "else", "for", "while", "return", "static", "const", "void", "id", "nil", "YES", "NO", "import", "typedef", "struct"],
          types: ["NSString", "NSArray", "NSDictionary", "NSObject", "NSInteger", "BOOL", "int", "float", "double", "char"], lit: ["nil", "YES", "NO", "NULL"],
          line: "//", block: ("/*", "*/"), runner: "objective-c", template: "#import <Foundation/Foundation.h>\n\nint main(void) {\n    @autoreleasepool {\n        NSLog(@\"Hello from MangoIDE!\");\n    }\n    return 0;\n}\n", pre: true),
        L("logos", "Logos (iOS Tweak)", ["x", "xm", "xi", "xmi"],
          kw: ["%hook", "%end", "%orig", "%group", "%ctor", "%dtor", "%new", "%init", "%c", "%log", "%subclass", "%property", "%hookf", "%config",
               "@interface", "@implementation", "@end", "@property", "@synthesize", "@protocol", "@class", "@selector", "self", "super", "if", "else", "for", "while",
               "return", "static", "const", "void", "id", "import", "include", "typedef", "struct", "extern", "switch", "case", "break", "default"],
          types: ["NSString", "NSArray", "NSDictionary", "NSObject", "NSInteger", "NSUInteger", "CGFloat", "CGRect", "CGPoint", "CGSize", "BOOL", "int", "float", "double", "char",
                  "UIView", "UIViewController", "UIColor", "UILabel", "UIImage", "UIButton", "UIWindow", "UIApplication", "NSBundle", "NSUserDefaults"],
          lit: ["nil", "YES", "NO", "NULL"], line: "//", block: ("/*", "*/"), pre: true),
        L("d", "D", ["d"], kw: ["import", "module", "void", "int", "auto", "if", "else", "for", "foreach", "while", "return", "class", "struct", "enum", "immutable", "const", "string", "writeln", "static", "public", "private"],
          lit: ["true", "false", "null"], line: "//", block: ("/*", "*/"), runner: "d",
          template: "import std.stdio;\n\nvoid main() {\n    auto name = \"MangoIDE\";\n    writeln(\"Hello from \", name, \"!\");\n}\n"),
        L("crystal", "Crystal", ["cr"], kw: ["def", "end", "if", "elsif", "else", "unless", "while", "until", "class", "struct", "module", "require", "puts", "return", "do", "case", "when", "property", "getter"],
          lit: ["true", "false", "nil"], line: "#", runner: "crystal", template: "name = \"MangoIDE\"\nputs \"Hello from #{name}!\"\n"),
        L("v", "V", ["v"], kw: ["fn", "mut", "pub", "struct", "if", "else", "for", "in", "return", "import", "module", "match", "println"],
          lit: ["true", "false", "none"], line: "//", block: ("/*", "*/"), runner: "vlang", template: "fn main() {\n\tname := 'MangoIDE'\n\tprintln('Hello from ${name}!')\n}\n"),
        L("assembly", "Assembly", ["asm", "s", "S", "nasm"], kw: ["mov", "add", "sub", "mul", "div", "jmp", "je", "jne", "jz", "jnz", "call", "ret", "push", "pop", "cmp", "lea", "syscall", "int", "section", "global", "db", "dw", "dd", "dq", "ldr", "str", "bl", "b", "cbz", "svc"],
          line: ";", quotes: ["\"", "'"], runner: "nasm64", ci: true),
        L("wasm", "WebAssembly Text", ["wat", "wast"], kw: ["module", "func", "param", "result", "local", "export", "import", "memory", "call", "i32", "i64", "f32", "f64", "get", "set", "add", "sub"],
          line: ";;", block: ("(;", ";)"), quotes: ["\""]),

        // JVM / .NET / functional
        L("groovy", "Groovy", ["groovy", "gradle", "gvy"], kw: ["def", "class", "if", "else", "for", "while", "return", "import", "package", "new", "println", "static", "void", "try", "catch", "in"],
          lit: ["true", "false", "null"], line: "//", block: ("/*", "*/"), quotes: ["'''", "\"\"\"", "\"", "'"], runner: "groovy",
          template: "def name = 'MangoIDE'\nprintln \"Hello from ${name}!\"\n", deco: true),
        L("clojure", "Clojure", ["clj", "cljs", "cljc", "edn"], kw: ["defn", "def", "let", "fn", "if", "do", "when", "cond", "loop", "recur", "ns", "require", "println", "map", "filter", "reduce"],
          lit: ["true", "false", "nil"], line: ";", quotes: ["\""], runner: "clojure", template: "(def name \"MangoIDE\")\n(println (str \"Hello from \" name \"!\"))\n"),
        L("fsharp", "F#", ["fs", "fsx", "fsi"], kw: ["let", "mutable", "fun", "function", "match", "with", "if", "then", "else", "for", "in", "do", "type", "module", "open", "printfn", "rec", "and", "member"],
          lit: ["true", "false", "null"], line: "//", block: ("(*", "*)"), quotes: ["\"\"\"", "\""], runner: "fsharp",
          template: "let name = \"MangoIDE\"\nprintfn \"Hello from %s!\" name\n"),
        L("ocaml", "OCaml", ["ml", "mli"], kw: ["let", "rec", "in", "fun", "function", "match", "with", "if", "then", "else", "type", "module", "open", "begin", "end", "and", "of"],
          lit: ["true", "false"], block: ("(*", "*)"), quotes: ["\""], runner: "ocaml",
          template: "let name = \"MangoIDE\"\nlet () = Printf.printf \"Hello from %s!\\n\" name\n"),
        L("erlang", "Erlang", ["erl", "hrl"], kw: ["module", "export", "fun", "case", "of", "end", "if", "receive", "after", "when", "begin", "try", "catch"],
          lit: ["true", "false", "ok", "undefined"], line: "%", quotes: ["\""], runner: "erlang",
          template: "-module(main).\n-export([main/1]).\n\nmain(_) ->\n    io:format(\"Hello from MangoIDE!~n\").\n"),
        L("elm", "Elm", ["elm"], kw: ["module", "exposing", "import", "type", "alias", "case", "of", "let", "in", "if", "then", "else"], types: ["Int", "Float", "String", "Bool", "List", "Maybe", "Html"],
          lit: ["True", "False"], line: "--", block: ("{-", "-}"), quotes: ["\"\"\"", "\""]),
        L("scheme", "Scheme / Racket / Lisp", ["scm", "ss", "rkt", "lisp", "lsp", "cl", "el"], kw: ["define", "lambda", "let", "if", "cond", "else", "begin", "defun", "setq", "displayln", "display", "require", "provide"],
          lit: ["#t", "#f", "nil", "t"], line: ";", block: ("#|", "|#"), quotes: ["\""], runner: "racket", template: "#lang racket\n(define name \"MangoIDE\")\n(displayln (string-append \"Hello from \" name \"!\"))\n"),
        L("prolog", "Prolog", ["pro", "prolog"], kw: ["is", "not", "fail", "true", "write", "nl", "format", "initialization", "halt"],
          line: "%", block: ("/*", "*/"), runner: "prolog", template: ":- initialization(main).\nmain :- write('Hello from MangoIDE!'), nl, halt.\n"),
        L("gleam", "Gleam", ["gleam"], kw: ["fn", "pub", "let", "case", "import", "type", "const", "use", "assert"], lit: ["True", "False", "Nil"], line: "//", quotes: ["\""]),

        // Scripting
        L("powershell", "PowerShell", ["ps1", "psm1", "psd1"], kw: ["function", "param", "if", "elseif", "else", "foreach", "for", "while", "return", "Write-Host", "Write-Output", "Get-ChildItem", "Set-Location"],
          lit: ["$true", "$false", "$null"], line: "#", block: ("<#", "#>"), runner: "powershell", template: "$name = \"MangoIDE\"\nWrite-Output \"Hello from $name!\"\n", ci: true),
        L("batch", "Batch", ["bat", "cmd"], kw: ["echo", "set", "if", "else", "goto", "call", "for", "in", "do", "exit", "rem", "setlocal", "endlocal"], line: "REM", quotes: ["\""], ci: true),
        L("fish", "Fish", ["fish"], kw: ["function", "end", "if", "else", "for", "in", "while", "set", "echo", "return", "switch", "case"], lit: ["true", "false"], line: "#", runner: "bash"),
        L("tcl", "Tcl", ["tcl"], kw: ["proc", "set", "if", "else", "elseif", "foreach", "for", "while", "return", "puts", "expr"], line: "#", quotes: ["\""], runner: "tcl", template: "set name \"MangoIDE\"\nputs \"Hello from $name!\"\n"),
        L("awk", "AWK", ["awk"], kw: ["BEGIN", "END", "print", "printf", "if", "else", "for", "while", "function", "return", "next"], line: "#", quotes: ["\""], runner: "awk", template: "BEGIN { name = \"MangoIDE\"; print \"Hello from \" name \"!\" }\n"),
        L("matlab", "MATLAB / Octave", ["matlab", "oct"], kw: ["function", "end", "if", "elseif", "else", "for", "while", "return", "disp", "fprintf", "switch", "case"],
          lit: ["true", "false"], line: "%", block: ("%{", "%}"), quotes: ["'", "\""], runner: "octave", template: "name = 'MangoIDE';\ndisp(['Hello from ', name, '!']);\n"),
        L("cobol", "COBOL", ["cob", "cbl", "cpy"], kw: ["IDENTIFICATION", "DIVISION", "PROGRAM-ID", "PROCEDURE", "DATA", "WORKING-STORAGE", "SECTION", "DISPLAY", "STOP", "RUN", "MOVE", "TO", "PIC", "IF", "END-IF", "PERFORM"],
          line: "*>", quotes: ["\"", "'"], runner: "cobol", template: "       IDENTIFICATION DIVISION.\n       PROGRAM-ID. HELLO.\n       PROCEDURE DIVISION.\n           DISPLAY 'Hello from MangoIDE!'.\n           STOP RUN.\n", ci: true),
        L("ada", "Ada", ["adb", "ads", "ada"], kw: ["procedure", "is", "begin", "end", "with", "use", "if", "then", "else", "loop", "for", "while", "function", "return", "package", "body"],
          lit: ["True", "False", "null"], line: "--", quotes: ["\""], runner: "ada", template: "with Ada.Text_IO; use Ada.Text_IO;\n\nprocedure Main is\nbegin\n   Put_Line (\"Hello from MangoIDE!\");\nend Main;\n", ci: true),
        L("basic", "BASIC / VB", ["bas", "vb", "vbs"], kw: ["Dim", "As", "If", "Then", "Else", "End", "For", "Next", "While", "Wend", "Sub", "Function", "Print", "Return", "Module", "Console"],
          lit: ["True", "False", "Nothing"], line: "'", quotes: ["\""], runner: "basic", ci: true),

        // Web & config
        L("vue", "Vue", ["vue"], block: ("<!--", "-->"), quotes: ["\"", "'", "`"], markup: true),
        L("svelte", "Svelte", ["svelte"], block: ("<!--", "-->"), quotes: ["\"", "'", "`"], markup: true),
        L("astro", "Astro", ["astro"], block: ("<!--", "-->"), quotes: ["\"", "'", "`"], markup: true),
        L("php-blade", "Templates", ["hbs", "handlebars", "mustache", "ejs", "erb", "twig", "liquid", "njk", "jinja", "j2"], block: ("<!--", "-->"), markup: true),
        L("graphql", "GraphQL", ["graphql", "gql"], kw: ["query", "mutation", "subscription", "fragment", "on", "type", "input", "enum", "interface", "schema", "extend", "scalar", "union", "implements"],
          types: ["String", "Int", "Float", "Boolean", "ID"], lit: ["true", "false", "null"], line: "#", quotes: ["\"\"\"", "\""]),
        L("protobuf", "Protocol Buffers", ["proto"], kw: ["syntax", "package", "import", "message", "enum", "service", "rpc", "returns", "repeated", "optional", "oneof", "map", "option"],
          types: ["string", "int32", "int64", "bool", "bytes", "double", "float", "uint32", "uint64"], lit: ["true", "false"], line: "//", block: ("/*", "*/")),
        L("solidity", "Solidity", ["sol"], kw: ["pragma", "contract", "function", "public", "private", "external", "internal", "view", "pure", "payable", "returns", "return", "mapping", "struct", "event", "emit", "require", "modifier", "memory", "storage"],
          types: ["uint", "uint256", "int", "address", "bool", "string", "bytes32"], lit: ["true", "false"], line: "//", block: ("/*", "*/")),
        L("dockerfile", "Dockerfile", ["dockerfile"], kw: ["FROM", "RUN", "CMD", "COPY", "ADD", "WORKDIR", "ENV", "ARG", "EXPOSE", "ENTRYPOINT", "USER", "VOLUME", "LABEL", "HEALTHCHECK", "AS"], line: "#", ci: true),
        L("makefile", "Makefile", ["mk", "mak", "make"], kw: ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define", "endef", "export", ".PHONY"], line: "#"),
        L("cmake", "CMake", ["cmake"], kw: ["cmake_minimum_required", "project", "add_executable", "add_library", "target_link_libraries", "set", "if", "else", "endif", "find_package", "include_directories", "message"], line: "#", ci: true),
        L("nix", "Nix", ["nix"], kw: ["let", "in", "with", "rec", "inherit", "import", "if", "then", "else", "assert"], lit: ["true", "false", "null"], line: "#", block: ("/*", "*/"), quotes: ["''", "\""]),
        L("hcl", "Terraform / HCL", ["tf", "tfvars", "hcl"], kw: ["resource", "variable", "output", "provider", "module", "data", "locals", "terraform", "for_each", "count"], lit: ["true", "false", "null"], line: "#", block: ("/*", "*/"), quotes: ["\""]),
        L("dotenv", ".env", ["env"], line: "#", quotes: ["\"", "'"]),
        L("ignore", "Ignore File", ["gitignore", "dockerignore", "npmignore", "gitattributes", "editorconfig"], line: "#", quotes: []),
        L("properties", "Properties", ["properties", "prefs"], line: "#", quotes: []),
        L("csv", "CSV / TSV", ["csv", "tsv"], quotes: ["\""], runner: "csv"),
        L("diff", "Diff / Patch", ["diff", "patch"], quotes: []),
        L("log", "Log", ["log", "out"], kw: ["ERROR", "WARN", "WARNING", "INFO", "DEBUG", "TRACE", "FATAL"], quotes: ["\""]),

        // Docs & data
        L("latex", "LaTeX", ["tex", "sty", "cls", "bib"], kw: ["\\documentclass", "\\begin", "\\end", "\\section", "\\subsection", "\\usepackage", "\\title", "\\author", "\\maketitle", "\\textbf", "\\textit", "\\item", "\\label", "\\ref", "\\cite"],
          line: "%", quotes: []),
        L("rst", "reStructuredText", ["rst"], quotes: ["``"]),
        L("asciidoc", "AsciiDoc", ["adoc", "asciidoc"], quotes: ["`"]),
        L("org", "Org", ["org"], line: "#", quotes: []),
        L("sql-more", "SQL Dialects", ["psql", "pgsql", "mysql", "plsql"], kw: ["select", "from", "where", "insert", "update", "delete", "create", "table", "join", "group", "order", "by", "begin", "end", "function", "returns"],
          line: "--", block: ("/*", "*/"), ci: true),

        // Minecraft
        L("mcfunction", "Minecraft Function", ["mcfunction"], kw: ["say", "give", "tp", "teleport", "execute", "as", "at", "run", "if", "unless", "summon", "setblock", "fill", "clone", "effect", "scoreboard", "objectives", "players", "add", "remove", "set", "tellraw", "titleraw", "title", "gamemode", "kill", "function", "tag", "particle", "playsound", "clear", "enchant", "weather", "time", "difficulty", "gamerule", "structure", "camera", "dialogue", "event", "entity", "positioned", "rotated", "facing", "anchored", "align", "in", "matches", "block", "blocks", "score"],
          types: ["@p", "@a", "@e", "@s", "@r", "@initiator"], lit: ["true", "false"], line: "#", quotes: ["\""]),
        L("mclang", "Minecraft Lang", ["lang"], line: "##", quotes: []),

        // Graphics & hardware
        L("glsl", "GLSL / HLSL / Metal", ["glsl", "vert", "frag", "comp", "geom", "hlsl", "fx", "metal", "wgsl", "shader"], kw: ["uniform", "in", "out", "inout", "layout", "void", "return", "if", "else", "for", "while", "struct", "const", "kernel", "fragment", "vertex", "fn", "let", "var"],
          types: ["float", "vec2", "vec3", "vec4", "mat3", "mat4", "int", "bool", "sampler2D", "float2", "float3", "float4", "half", "texture2d", "f32", "vec4f"], line: "//", block: ("/*", "*/"), pre: true),
        L("verilog", "Verilog / SystemVerilog", ["sv", "svh", "vh"], kw: ["module", "endmodule", "input", "output", "inout", "wire", "reg", "logic", "always", "assign", "begin", "end", "if", "else", "case", "endcase", "posedge", "negedge", "parameter"],
          line: "//", block: ("/*", "*/"), quotes: ["\""]),
        L("vhdl", "VHDL", ["vhd", "vhdl"], kw: ["entity", "architecture", "is", "begin", "end", "port", "signal", "process", "if", "then", "else", "elsif", "library", "use", "in", "out", "of"],
          line: "--", quotes: ["\""], ci: true),
        L("arduino", "Arduino", ["ino", "pde"], kw: ["void", "setup", "loop", "if", "else", "for", "while", "return", "const", "int", "float", "bool", "pinMode", "digitalWrite", "digitalRead", "analogRead", "delay", "Serial"],
          lit: ["HIGH", "LOW", "INPUT", "OUTPUT", "true", "false"], line: "//", block: ("/*", "*/"), pre: true),
    ]

    /// Files known by their whole name rather than an extension.
    static let specialFileNames: [String: String] = [
        "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "makefile": "makefile", "gnumakefile": "makefile", "control": "yaml",
        "cmakelists.txt": "cmake",
        "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby", "fastfile": "ruby", "brewfile": "ruby",
        "jenkinsfile": "groovy", "vagrantfile": "ruby",
        ".env": "dotenv", ".gitignore": "ignore", ".dockerignore": "ignore", ".gitattributes": "ignore", ".editorconfig": "ignore",
        ".bashrc": "shell", ".zshrc": "shell", ".profile": "shell", ".bash_profile": "shell",
        "procfile": "yaml", "package.swift": "swift", "license": "plaintext", "readme": "markdown"
    ]
}
