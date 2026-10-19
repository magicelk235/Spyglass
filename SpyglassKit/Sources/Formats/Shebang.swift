import Foundation

/// The language of a script, from its `#!` line.
public enum Shebang {

    /// The highlight.js language for `text`, a file's opening bytes; nil
    /// when the first line isn't a `#!` line or names an interpreter
    /// without a grammar.
    public static func language(for text: String) -> String? {
        guard text.hasPrefix("#!") else { return nil }
        let line = text.dropFirst(2).prefix { !$0.isNewline }
        var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return nil }
        var command = words.removeFirst()
        if (command as NSString).lastPathComponent == "env" {
            // env's own options and VAR=value settings come before the
            // command; -u, -P and -C take an argument.
            while let word = words.first, word.hasPrefix("-") || word.contains("=") {
                words.removeFirst()
                if ["-u", "-P", "-C"].contains(word), !words.isEmpty { words.removeFirst() }
            }
            guard let named = words.first else { return nil }
            command = named
        }
        return language(forInterpreter: (command as NSString).lastPathComponent)
    }

    /// "python3.12" and "python" both name Python.
    static func language(forInterpreter name: String) -> String? {
        var base = Substring(name.lowercased())
        while let last = base.last, last.isNumber || last == "." || last == "-" { base.removeLast() }
        return interpreters[String(base)]
    }

    /// Interpreter names without version suffixes, to highlight.js ids.
    static let interpreters: [String: String] = [
        "python": "python", "pypy": "python",
        "sh": "bash", "bash": "bash", "zsh": "bash", "dash": "bash", "ksh": "bash", "mksh": "bash",
        "ash": "bash", "fish": "bash",
        "node": "javascript", "nodejs": "javascript",
        "ruby": "ruby", "perl": "perl", "php": "php",
        "lua": "lua", "luajit": "lua",
        "tclsh": "tcl", "wish": "tcl",
        "awk": "awk", "gawk": "awk", "mawk": "awk", "nawk": "awk",
        "osascript": "applescript",
        "swift": "swift",
        "rscript": "r",
    ]
}
