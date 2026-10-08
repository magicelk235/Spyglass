import Foundation

/// Maps a filename to a highlight.js language id. The ids must exist in the
/// vendored highlight.js build; anything unmapped is auto-detected.
///
/// Only names Quick Look can actually hand to Spyglass belong here. Most
/// extensionless files (Dockerfile, Gemfile, dotfiles) are typed
/// `public.data`, which Spyglass never claims, so they are not listed.
public enum CodeLanguage {

    public static func language(forFilename filename: String) -> String? {
        let name = filename.lowercased()
        if let lang = byFilename[name] { return lang }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return byExtension[ext]
    }

    /// Whole filenames (lowercased) that LaunchServices types as source.
    static let byFilename: [String: String] = [
        "makefile": "makefile", "gnumakefile": "makefile",
        "nginx.conf": "nginx",
    ]

    /// Lowercased extension → language id.
    static let byExtension: [String: String] = [
        // C family
        "c": "c", "h": "c", "cl": "c",
        "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "c++": "cpp", "hh": "cpp", "hpp": "cpp", "hxx": "cpp", "ino": "cpp",
        "m": "objectivec", "mm": "objectivec", "metal": "cpp",
        "cs": "csharp", "csx": "csharp",
        "java": "java", "kt": "kotlin", "kts": "kotlin",
        "scala": "scala", "groovy": "groovy", "gradle": "groovy",
        "swift": "swift", "go": "go", "rs": "rust", "zig": "plaintext",
        "d": "d", "dart": "dart", "v": "verilog", "sv": "verilog", "vhd": "vhdl", "vhdl": "vhdl",
        // Web
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "cts": "typescript", "tsx": "typescript",
        "css": "css", "scss": "scss", "sass": "scss", "less": "less", "styl": "stylus",
        "vue": "xml", "svelte": "xml",
        "php": "php", "phtml": "php", "erb": "erb", "haml": "haml",
        "hbs": "handlebars", "handlebars": "handlebars", "twig": "twig",
        "coffee": "coffeescript", "litcoffee": "coffeescript",
        "graphql": "graphql", "gql": "graphql", "wat": "wasm",
        // Scripting
        "py": "python", "pyw": "python", "pyi": "python", "rb": "ruby", "rake": "ruby", "gemspec": "ruby",
        "pl": "perl", "pm": "perl", "lua": "lua", "r": "r", "jl": "julia",
        "sh": "bash", "bash": "bash", "zsh": "bash", "ksh": "bash", "fish": "bash", "command": "bash",
        "ps1": "powershell", "psm1": "powershell", "psd1": "powershell",
        "bat": "dos", "cmd": "dos", "tcl": "tcl", "awk": "awk",
        "applescript": "applescript", "scpt": "applescript",
        "vim": "vim", "el": "lisp", "lisp": "lisp", "lsp": "lisp",
        "clj": "clojure", "cljs": "clojure", "cljc": "clojure",
        "scm": "scheme", "ss": "scheme", "rkt": "scheme",
        // Functional and others
        "hs": "haskell", "lhs": "haskell", "elm": "elm", "ml": "ocaml", "mli": "ocaml",
        "fs": "fsharp", "fsi": "fsharp", "fsx": "fsharp", "ex": "elixir", "exs": "elixir",
        "erl": "erlang", "hrl": "erlang", "nim": "nim", "nix": "nix", "cr": "crystal",
        "hx": "haxe", "pas": "delphi", "dpr": "delphi",
        "f": "fortran", "f90": "fortran", "f95": "fortran", "for": "fortran",
        "adb": "ada", "ads": "ada", "pro": "prolog", "sml": "sml",
        "coq": "coq", "matlab": "matlab", "sas": "sas",
        "asm": "x86asm", "s": "armasm", "nasm": "x86asm", "ll": "llvm",
        "glsl": "glsl", "vert": "glsl", "frag": "glsl", "hlsl": "glsl",
        "proto": "protobuf", "thrift": "thrift", "capnp": "capnproto",
        "sql": "sql", "pgsql": "pgsql", "mysql": "sql",
        "tex": "latex", "sty": "latex", "cls": "latex", "bib": "latex",
        "feature": "gherkin", "tf": "plaintext", "hcl": "plaintext",
        "cmake": "cmake", "mk": "makefile", "mak": "makefile",
        "dockerfile": "dockerfile", "nginxconf": "nginx",
        // Config-like text that has no structured parser
        "ini": "ini", "cfg": "ini", "conf": "ini", "properties": "properties", "env": "bash",
        "log": "accesslog",
        "xcconfig": "ini", "entitlements": "xml", "pbxproj": "plaintext",
        "strings": "plaintext", "storyboard": "xml", "xib": "xml", "rss": "xml",
        "rst": "plaintext", "adoc": "asciidoc", "asciidoc": "asciidoc", "org": "plaintext",
        "srt": "plaintext", "vtt": "plaintext", "nfo": "plaintext",
    ]
}
