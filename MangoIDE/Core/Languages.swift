import Foundation

/// A language the editor understands. Everything but id/name/extensions is optional so
/// extensions can ship small JSON definitions.
struct LanguageDef: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var extensions: [String]
    var keywords: [String]?
    var types: [String]?
    var literals: [String]?
    var lineComment: String?
    var blockCommentStart: String?
    var blockCommentEnd: String?
    var quotes: [String]?
    /// "js" = run on the phone, "html" = live preview, anything else = language name on the runner server.
    var runner: String?
    var template: String?
    var markup: Bool?
    var decorators: Bool?
    var preprocessor: Bool?
    var caseInsensitive: Bool?

    var allQuotes: [String] { (quotes ?? ["\"", "'"]).sorted { $0.count > $1.count } }
    var mainFileName: String { "main." + (extensions.first ?? "txt") }

    static let plain = LanguageDef(id: "plaintext", name: "Plain Text", extensions: ["txt"])
}

enum LanguageLibrary {
    private static let cKeywords = ["auto","break","case","char","const","continue","default","do","double","else","enum","extern","float","for","goto","if","inline","int","long","register","restrict","return","short","signed","sizeof","static","struct","switch","typedef","union","unsigned","void","volatile","while","_Bool","bool"]

    static var builtIn: [LanguageDef] { all }
    private static let all: [LanguageDef] = core.filter { $0.id != "plaintext" } + more + extra + [LanguageDef.plain]

    /// Built-in languages by file extension (first one wins), so opening a file doesn't scan the whole list.
    static let byExtension: [String: LanguageDef] = {
        var map: [String: LanguageDef] = [:]
        for lang in all { for e in lang.extensions where map[e] == nil { map[e] = lang } }
        return map
    }()

    static let core: [LanguageDef] = [
        LanguageDef(id: "swift", name: "Swift", extensions: ["swift"],
                    keywords: ["associatedtype","class","deinit","enum","extension","fileprivate","func","import","init","inout","internal","let","open","operator","private","protocol","public","rethrows","static","struct","subscript","typealias","var","break","case","continue","default","defer","do","else","fallthrough","for","guard","if","in","repeat","return","switch","where","while","as","catch","is","super","self","Self","throw","throws","try","async","await","some","any","mutating","override","final","lazy","weak","unowned","convenience","required","indirect","actor","nonisolated","get","set","willSet","didSet"],
                    types: ["Int","Double","Float","String","Bool","Character","Array","Dictionary","Set","Optional","Void","Any","AnyObject","Error","Result"],
                    literals: ["true","false","nil"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"\"\"", "\""], runner: "swift",
                    template: "import Foundation\n\nlet name = \"MangoIDE\"\nprint(\"Hello from \\(name)!\")\n", decorators: true),
        LanguageDef(id: "python", name: "Python", extensions: ["py", "pyw", "pyi", "pyx", "pxd", "xsh", "gyp", "gypi"],
                    keywords: ["and","as","assert","async","await","break","class","continue","def","del","elif","else","except","finally","for","from","global","if","import","in","is","lambda","nonlocal","not","or","pass","raise","return","try","while","with","yield","match","case","self"],
                    types: ["int","float","str","bool","list","dict","set","tuple","bytes","object","range","len","print","input","open","type","isinstance","enumerate","zip","map","filter","sorted","sum","min","max","abs","round"],
                    literals: ["True","False","None"], lineComment: "#",
                    quotes: ["\"\"\"", "'''", "\"", "'"], runner: "python",
                    template: "def main():\n    name = \"MangoIDE\"\n    print(f\"Hello from {name}!\")\n\n\nif __name__ == \"__main__\":\n    main()\n", decorators: true),
        LanguageDef(id: "javascript", name: "JavaScript", extensions: ["js", "mjs", "cjs", "jsx"],
                    keywords: ["break","case","catch","class","const","continue","debugger","default","delete","do","else","export","extends","finally","for","function","if","import","in","instanceof","let","new","return","super","switch","this","throw","try","typeof","var","void","while","with","yield","async","await","of","static","get","set","from"],
                    types: ["Array","Object","String","Number","Boolean","Promise","Map","Set","Math","JSON","Date","RegExp","Error","console","Symbol"],
                    literals: ["true","false","null","undefined","NaN","Infinity"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"", "'", "`"], runner: "js",
                    template: "const name = \"MangoIDE\";\nconsole.log(`Hello from ${name}!`);\n"),
        LanguageDef(id: "typescript", name: "TypeScript", extensions: ["ts", "tsx", "mts", "cts"],
                    keywords: ["break","case","catch","class","const","continue","debugger","default","delete","do","else","export","extends","finally","for","function","if","import","in","instanceof","let","new","return","super","switch","this","throw","try","typeof","var","void","while","with","yield","async","await","of","static","get","set","from","interface","type","enum","implements","namespace","declare","readonly","private","public","protected","abstract","as","keyof","infer","is","satisfies"],
                    types: ["string","number","boolean","any","unknown","never","object","void","Array","Promise","Record","Partial","Map","Set","console"],
                    literals: ["true","false","null","undefined"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"", "'", "`"], runner: "typescript",
                    template: "const name: string = \"MangoIDE\";\nconsole.log(`Hello from ${name}!`);\n", decorators: true),
        LanguageDef(id: "java", name: "Java", extensions: ["java", "jav", "jsh"],
                    keywords: ["abstract","assert","break","case","catch","class","const","continue","default","do","else","enum","extends","final","finally","for","goto","if","implements","import","instanceof","interface","native","new","package","private","protected","public","return","static","strictfp","super","switch","synchronized","this","throw","throws","transient","try","volatile","while","var","record","yield"],
                    types: ["int","long","short","byte","double","float","char","boolean","void","String","Integer","Object","List","Map","ArrayList","HashMap","System"],
                    literals: ["true","false","null"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"\"\"", "\"", "'"], runner: "java",
                    template: "public class Main {\n    public static void main(String[] args) {\n        String name = \"MangoIDE\";\n        System.out.println(\"Hello from \" + name + \"!\");\n    }\n}\n", decorators: true),
        LanguageDef(id: "kotlin", name: "Kotlin", extensions: ["kt", "kts"],
                    keywords: ["as","break","class","continue","do","else","for","fun","if","in","interface","is","object","package","return","super","this","throw","try","typealias","val","var","when","while","by","catch","constructor","finally","get","import","init","set","where","abstract","data","enum","open","override","private","protected","public","internal","sealed","suspend","companion","lateinit","inline"],
                    types: ["Int","Long","Double","Float","String","Boolean","Char","Unit","Any","List","Map","Array"],
                    literals: ["true","false","null"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"\"\"", "\"", "'"], runner: "kotlin",
                    template: "fun main() {\n    val name = \"MangoIDE\"\n    println(\"Hello from $name!\")\n}\n", decorators: true),
        LanguageDef(id: "c", name: "C", extensions: ["c", "h"],
                    keywords: cKeywords, types: ["size_t","FILE","int8_t","int16_t","int32_t","int64_t","uint8_t","uint32_t","uint64_t"],
                    literals: ["NULL","true","false"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"", "'"], runner: "c",
                    template: "#include <stdio.h>\n\nint main(void) {\n    const char *name = \"MangoIDE\";\n    printf(\"Hello from %s!\\n\", name);\n    return 0;\n}\n", preprocessor: true),
        LanguageDef(id: "cpp", name: "C++", extensions: ["cpp", "cc", "cxx", "hpp", "hh", "hxx", "c++", "h++", "ipp", "tpp", "inl", "ixx", "cppm", "cu", "cuh"],
                    keywords: cKeywords + ["class","namespace","template","typename","public","private","protected","virtual","override","new","delete","this","using","try","catch","throw","operator","friend","constexpr","nullptr","auto","explicit","noexcept","decltype","mutable","static_cast","dynamic_cast","reinterpret_cast","const_cast"],
                    types: ["std","string","vector","map","set","unordered_map","cout","cin","endl","size_t"],
                    literals: ["true","false","nullptr","NULL"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"", "'"], runner: "c++",
                    template: "#include <iostream>\n#include <string>\n\nint main() {\n    std::string name = \"MangoIDE\";\n    std::cout << \"Hello from \" << name << \"!\" << std::endl;\n    return 0;\n}\n", preprocessor: true),
        LanguageDef(id: "csharp", name: "C#", extensions: ["cs"],
                    keywords: ["abstract","as","base","break","case","catch","checked","class","const","continue","default","delegate","do","else","enum","event","explicit","extern","finally","fixed","for","foreach","goto","if","implicit","in","interface","internal","is","lock","namespace","new","operator","out","override","params","private","protected","public","readonly","ref","return","sealed","sizeof","static","struct","switch","this","throw","try","typeof","unchecked","unsafe","using","virtual","void","volatile","while","var","async","await","record","get","set"],
                    types: ["int","long","double","float","decimal","string","bool","char","object","byte","Console","List","Dictionary","Task"],
                    literals: ["true","false","null"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"", "'"], runner: "csharp",
                    template: "using System;\n\nclass Program {\n    static void Main() {\n        var name = \"MangoIDE\";\n        Console.WriteLine($\"Hello from {name}!\");\n    }\n}\n"),
        LanguageDef(id: "go", name: "Go", extensions: ["go"],
                    keywords: ["break","case","chan","const","continue","default","defer","else","fallthrough","for","func","go","goto","if","import","interface","map","package","range","return","select","struct","switch","type","var"],
                    types: ["int","int64","int32","uint","float64","float32","string","bool","byte","rune","error","any","fmt","make","len","append"],
                    literals: ["true","false","nil","iota"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"", "'", "`"], runner: "go",
                    template: "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tname := \"MangoIDE\"\n\tfmt.Printf(\"Hello from %s!\\n\", name)\n}\n"),
        LanguageDef(id: "rust", name: "Rust", extensions: ["rs"],
                    keywords: ["as","async","await","break","const","continue","crate","dyn","else","enum","extern","fn","for","if","impl","in","let","loop","match","mod","move","mut","pub","ref","return","self","Self","static","struct","super","trait","type","unsafe","use","where","while"],
                    types: ["i8","i16","i32","i64","i128","isize","u8","u16","u32","u64","u128","usize","f32","f64","bool","char","str","String","Vec","Option","Result","Box","HashMap"],
                    literals: ["true","false","None","Some","Ok","Err"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\""], runner: "rust",
                    template: "fn main() {\n    let name = \"MangoIDE\";\n    println!(\"Hello from {}!\", name);\n}\n", decorators: false),
        LanguageDef(id: "ruby", name: "Ruby", extensions: ["rb", "rake", "gemspec", "ru", "podspec", "jbuilder", "thor"],
                    keywords: ["alias","and","begin","break","case","class","def","defined?","do","else","elsif","end","ensure","for","if","in","module","next","not","or","redo","rescue","retry","return","self","super","then","undef","unless","until","when","while","yield","puts","require","attr_accessor","attr_reader"],
                    literals: ["true","false","nil"], lineComment: "#", blockCommentStart: "=begin", blockCommentEnd: "=end",
                    quotes: ["\"", "'"], runner: "ruby",
                    template: "name = \"MangoIDE\"\nputs \"Hello from #{name}!\"\n"),
        LanguageDef(id: "php", name: "PHP", extensions: ["php", "phtml", "php8", "phps"],
                    keywords: ["abstract","and","array","as","break","callable","case","catch","class","clone","const","continue","declare","default","do","echo","else","elseif","empty","enddeclare","endfor","endforeach","endif","endswitch","endwhile","extends","final","finally","fn","for","foreach","function","global","goto","if","implements","include","instanceof","insteadof","interface","isset","list","match","namespace","new","or","print","private","protected","public","require","return","static","switch","throw","trait","try","unset","use","var","while","yield"],
                    literals: ["true","false","null","TRUE","FALSE","NULL"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"", "'"], runner: "php",
                    template: "<?php\n$name = \"MangoIDE\";\necho \"Hello from $name!\\n\";\n"),
        LanguageDef(id: "lua", name: "Lua", extensions: ["lua", "luau", "rockspec", "nse", "wlua"],
                    keywords: ["and","break","do","else","elseif","end","for","function","goto","if","in","local","not","or","repeat","return","then","until","while","print","require"],
                    literals: ["true","false","nil"], lineComment: "--", blockCommentStart: "--[[", blockCommentEnd: "]]",
                    quotes: ["\"", "'"], runner: "lua",
                    template: "local name = \"MangoIDE\"\nprint(\"Hello from \" .. name .. \"!\")\n"),
        LanguageDef(id: "shell", name: "Shell", extensions: ["sh", "bash", "zsh", "command", "ksh", "csh", "tcsh", "ash", "dash", "bats"],
                    keywords: ["if","then","else","elif","fi","case","esac","for","while","until","do","done","in","function","return","local","export","echo","exit","source","set","unset","shift","read","printf","cd","test"],
                    literals: ["true","false"], lineComment: "#", quotes: ["\"", "'"], runner: "bash",
                    template: "#!/bin/bash\nname=\"MangoIDE\"\necho \"Hello from $name!\"\n"),
        LanguageDef(id: "dart", name: "Dart", extensions: ["dart"],
                    keywords: ["abstract","as","assert","async","await","break","case","catch","class","const","continue","default","do","else","enum","export","extends","extension","external","factory","final","finally","for","get","if","implements","import","in","is","late","library","mixin","new","on","part","required","rethrow","return","set","static","super","switch","this","throw","try","typedef","var","void","while","with","yield"],
                    types: ["int","double","num","String","bool","List","Map","Set","dynamic","Future","Stream"],
                    literals: ["true","false","null"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"\"\"", "'''", "\"", "'"], runner: "dart",
                    template: "void main() {\n  final name = 'MangoIDE';\n  print('Hello from $name!');\n}\n", decorators: true),
        LanguageDef(id: "r", name: "R", extensions: ["r", "R"],
                    keywords: ["if","else","repeat","while","function","for","in","next","break","return","library","print","cat","paste"],
                    literals: ["TRUE","FALSE","NULL","NA","Inf","NaN"], lineComment: "#", quotes: ["\"", "'"], runner: "rscript",
                    template: "name <- \"MangoIDE\"\ncat(\"Hello from\", name, \"!\\n\")\n"),
        LanguageDef(id: "perl", name: "Perl", extensions: ["pl", "pm", "t", "psgi", "pod"],
                    keywords: ["my","our","local","sub","if","elsif","else","unless","while","until","for","foreach","last","next","redo","return","use","package","require","print","say","die"],
                    literals: ["undef"], lineComment: "#", quotes: ["\"", "'"], runner: "perl",
                    template: "use strict;\nuse warnings;\n\nmy $name = \"MangoIDE\";\nprint \"Hello from $name!\\n\";\n"),
        LanguageDef(id: "scala", name: "Scala", extensions: ["scala", "sc", "sbt"],
                    keywords: ["abstract","case","catch","class","def","do","else","extends","final","finally","for","forSome","if","implicit","import","lazy","match","new","object","override","package","private","protected","return","sealed","super","this","throw","trait","try","type","val","var","while","with","yield","given","using","then","enum"],
                    types: ["Int","Long","Double","String","Boolean","Unit","Any","List","Map","Option"],
                    literals: ["true","false","null","None","Some"], lineComment: "//", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["\"\"\"", "\"", "'"], runner: "scala",
                    template: "object Main extends App {\n  val name = \"MangoIDE\"\n  println(s\"Hello from $name!\")\n}\n", decorators: true),
        LanguageDef(id: "haskell", name: "Haskell", extensions: ["hs", "lhs", "hsc"],
                    keywords: ["case","class","data","default","deriving","do","else","if","import","in","infix","infixl","infixr","instance","let","module","newtype","of","then","type","where","main","putStrLn","show"],
                    types: ["Int","Integer","Double","String","Bool","Char","IO","Maybe","Either"],
                    literals: ["True","False","Nothing","Just"], lineComment: "--", blockCommentStart: "{-", blockCommentEnd: "-}",
                    quotes: ["\""], runner: "haskell",
                    template: "main :: IO ()\nmain = do\n  let name = \"MangoIDE\"\n  putStrLn (\"Hello from \" ++ name ++ \"!\")\n"),
        LanguageDef(id: "elixir", name: "Elixir", extensions: ["ex", "exs", "heex", "eex", "leex"],
                    keywords: ["def","defp","defmodule","do","end","if","else","unless","case","cond","fn","when","with","for","import","alias","require","use","receive","try","rescue","catch","after","raise","IO"],
                    literals: ["true","false","nil"], lineComment: "#", quotes: ["\"\"\"", "\"", "'"], runner: "elixir",
                    template: "name = \"MangoIDE\"\nIO.puts(\"Hello from #{name}!\")\n"),
        LanguageDef(id: "julia", name: "Julia", extensions: ["jl"],
                    keywords: ["function","end","if","elseif","else","for","while","return","break","continue","let","local","global","const","module","using","import","struct","mutable","begin","do","try","catch","finally","println","print"],
                    literals: ["true","false","nothing"], lineComment: "#", blockCommentStart: "#=", blockCommentEnd: "=#",
                    quotes: ["\"\"\"", "\""], runner: "julia",
                    template: "name = \"MangoIDE\"\nprintln(\"Hello from $name!\")\n"),
        LanguageDef(id: "zig", name: "Zig", extensions: ["zig"],
                    keywords: ["const","var","fn","pub","return","if","else","while","for","switch","break","continue","struct","enum","union","try","catch","defer","errdefer","comptime","import","test","and","or"],
                    types: ["u8","i32","i64","u32","u64","usize","f32","f64","bool","void","anyerror","std"],
                    literals: ["true","false","null","undefined"], lineComment: "//", quotes: ["\"", "'"], runner: "zig",
                    template: "const std = @import(\"std\");\n\npub fn main() void {\n    const name = \"MangoIDE\";\n    std.debug.print(\"Hello from {s}!\\n\", .{name});\n}\n"),
        LanguageDef(id: "nim", name: "Nim", extensions: ["nim"],
                    keywords: ["proc","func","let","var","const","if","elif","else","for","while","in","return","import","type","object","case","of","echo","discard","when","template","macro"],
                    literals: ["true","false","nil"], lineComment: "#", quotes: ["\"\"\"", "\"", "'"], runner: "nim",
                    template: "let name = \"MangoIDE\"\necho \"Hello from \", name, \"!\"\n"),
        LanguageDef(id: "pascal", name: "Pascal", extensions: ["pas", "pp"],
                    keywords: ["program","begin","end","var","const","type","procedure","function","if","then","else","for","to","downto","do","while","repeat","until","case","of","writeln","write","readln","uses"],
                    types: ["integer","real","string","boolean","char"], literals: ["true","false","nil"],
                    lineComment: "//", blockCommentStart: "{", blockCommentEnd: "}", quotes: ["'"], runner: "pascal",
                    template: "program Hello;\nvar name: string;\nbegin\n  name := 'MangoIDE';\n  writeln('Hello from ', name, '!');\nend.\n", caseInsensitive: true),
        LanguageDef(id: "fortran", name: "Fortran", extensions: ["f90", "f95", "f", "f03", "f08", "for", "f77"],
                    keywords: ["program","end","implicit","none","integer","real","character","logical","print","write","read","if","then","else","do","call","subroutine","function","module","use","contains"],
                    literals: [".true.", ".false."], lineComment: "!", quotes: ["\"", "'"], runner: "fortran",
                    template: "program hello\n  implicit none\n  character(len=8) :: name = 'MangoIDE'\n  print *, 'Hello from ', name, '!'\nend program hello\n", caseInsensitive: true),
        LanguageDef(id: "sql", name: "SQL", extensions: ["sql", "ddl", "dml", "hql"],
                    keywords: ["select","from","where","insert","into","values","update","set","delete","create","table","drop","alter","add","join","left","right","inner","outer","on","group","by","order","having","limit","as","and","or","not","null","is","in","primary","key","foreign","references","distinct","count","sum","avg","min","max","union","index","view","integer","text","real","varchar"],
                    literals: ["true","false"], lineComment: "--", blockCommentStart: "/*", blockCommentEnd: "*/",
                    quotes: ["'", "\""], runner: "sqlite3",
                    template: "CREATE TABLE fruits (name TEXT, sweetness INTEGER);\nINSERT INTO fruits VALUES ('Mango', 10), ('Lemon', 2);\nSELECT name, sweetness FROM fruits ORDER BY sweetness DESC;\n", caseInsensitive: true),
        LanguageDef(id: "html", name: "HTML", extensions: ["html", "htm", "xhtml", "shtml", "xht", "hta"],
                    blockCommentStart: "<!--", blockCommentEnd: "-->", quotes: ["\"", "'"], runner: "html",
                    template: "<!DOCTYPE html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n  <title>MangoIDE</title>\n  <style>\n    body { font-family: -apple-system, sans-serif; padding: 24px; }\n    h1 { color: #ff9a1a; }\n  </style>\n</head>\n<body>\n  <h1>Hello from MangoIDE!</h1>\n  <script>\n    console.log(\"Page loaded\");\n  </script>\n</body>\n</html>\n", markup: true),
        LanguageDef(id: "xml", name: "XML", extensions: ["xml", "plist", "svg", "xib", "storyboard", "entitlements", "mobileconfig", "xaml", "xsl", "xslt", "xsd", "dtd", "wsdl", "rss", "atom", "csproj", "vcxproj", "fsproj", "vbproj", "props", "targets", "nuspec", "resx", "kml", "gpx", "iml", "xcscheme", "xcworkspacedata", "ui", "glade", "qrc", "opml", "xliff", "xlf", "dae", "manifest", "appxmanifest", "wxs", "stringsdict", "xcprivacy", "musicxml", "fxml", "jrxml"],
                    blockCommentStart: "<!--", blockCommentEnd: "-->", quotes: ["\"", "'"], markup: true),
        LanguageDef(id: "css", name: "CSS", extensions: ["css", "scss", "less", "sass", "styl", "pcss", "postcss"],
                    keywords: ["important","media","import","keyframes","from","to","root","hover","before","after","active","focus"],
                    lineComment: nil, blockCommentStart: "/*", blockCommentEnd: "*/", quotes: ["\"", "'"]),
        LanguageDef(id: "json", name: "JSON", extensions: ["json", "jsonc", "geojson", "json5", "jsonl", "ndjson", "webmanifest", "xcstrings", "ipynb", "map", "har", "topojson", "avsc", "tfstate", "code-workspace", "sarif", "gltf", "lottie", "mcmeta"],
                    literals: ["true","false","null"], lineComment: "//", quotes: ["\""]),
        LanguageDef(id: "yaml", name: "YAML", extensions: ["yml", "yaml", "tbd", "sls", "cff"],
                    literals: ["true","false","null","yes","no","on","off"], lineComment: "#", quotes: ["\"", "'"]),
        LanguageDef(id: "toml", name: "TOML", extensions: ["toml", "ini", "cfg", "conf", "cnf", "gitconfig", "url", "pylintrc", "flake8"],
                    literals: ["true","false"], lineComment: "#", quotes: ["\"\"\"", "\"", "'"]),
        LanguageDef(id: "markdown", name: "Markdown", extensions: ["md", "markdown", "mdown", "mdx", "mkd", "qmd", "rmd"],
                    quotes: ["```", "`"], runner: "markdown"),
        LanguageDef.plain
    ]
}
