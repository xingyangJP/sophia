import Foundation

/// コードの色分けの種類（FR-06）。色そのものは `SophiaCodeColor` が持つ。
///
/// **種類と色を分けてある**のは、ハイライト結果をライト／ダークで共用するため。
/// ここに `Color` を入れると外観の切替でキャッシュが全部無効になる。
enum CodeTokenKind: Equatable {
    case plain
    case comment
    case string
    case number
    case keyword
    case type
    case function
    case punctuation
}

struct CodeSpan: Equatable {
    let text: String
    let kind: CodeTokenKind
}

/// 行ごとに分割済みのハイライト結果。行番号の溝と行を揃えるため行単位で持つ。
struct HighlightedCode: Equatable {
    let lines: [[CodeSpan]]
}

/// **外部ライブラリもネットワークも使わないシンタックスハイライタ**（FR-06 / NFR-01）。
///
/// 完全なパーサではない。字句を上から順に舐めるだけの走査器で、
/// 「読むための色分け」に必要な精度に絞ってある。
/// 判定を間違えても崩れるのは色だけで、コードの文字は必ずそのまま出る。
enum SyntaxHighlighter {

    static func highlight(_ code: String, language: String?) -> HighlightedCode {
        let grammar = Grammar.forLanguage(language)
        let spans = scan(Array(code), grammar: grammar)
        return HighlightedCode(lines: splitIntoLines(spans))
    }

    // MARK: - 走査

    private static func scan(_ characters: [Character], grammar: Grammar) -> [CodeSpan] {
        var spans: [CodeSpan] = []
        var plain = ""
        var i = 0

        func flushPlain() {
            guard !plain.isEmpty else { return }
            spans.append(CodeSpan(text: plain, kind: .plain))
            plain = ""
        }
        func emit(_ text: String, _ kind: CodeTokenKind) {
            flushPlain()
            spans.append(CodeSpan(text: text, kind: kind))
        }

        while i < characters.count {
            let character = characters[i]

            // --- 行コメント -------------------------------------------------
            if grammar.lineComments.contains(where: { matches($0, characters, i) }) {
                var end = i
                while end < characters.count, characters[end] != "\n" { end += 1 }
                emit(String(characters[i..<end]), .comment)
                i = end
                continue
            }

            // --- ブロックコメント ---------------------------------------------
            if let block = grammar.blockComment, matches(block.open, characters, i) {
                var end = i + block.open.count
                while end < characters.count, !matches(block.close, characters, end) { end += 1 }
                end = min(end + block.close.count, characters.count)
                emit(String(characters[i..<end]), .comment)
                i = end
                continue
            }

            // --- 文字列 ---------------------------------------------------------
            if let delimiter = grammar.stringDelimiters.first(where: { matches($0, characters, i) }) {
                var end = i + delimiter.count
                while end < characters.count {
                    if let escape = grammar.escape, characters[end] == escape {
                        end += 2
                        continue
                    }
                    if matches(delimiter, characters, end) {
                        end += delimiter.count
                        break
                    }
                    // 1文字の区切りは行をまたがない（閉じ忘れで残り全部が文字列になるのを防ぐ）
                    if delimiter.count == 1, characters[end] == "\n" { break }
                    end += 1
                }
                emit(String(characters[i..<min(end, characters.count)]), .string)
                i = min(end, characters.count)
                continue
            }

            // --- 数値 -------------------------------------------------------------
            if character.isNumber, !isIdentifierPart(previous(characters, i)) {
                var end = i
                while end < characters.count,
                      characters[end].isHexDigit || "._xXbBoOeE+-".contains(characters[end]) {
                    // 指数以外の +/- は数値に含めない
                    if characters[end] == "+" || characters[end] == "-" {
                        let prev = characters[end - 1]
                        guard prev == "e" || prev == "E" else { break }
                    }
                    end += 1
                }
                emit(String(characters[i..<end]), .number)
                i = end
                continue
            }

            // --- 識別子 -------------------------------------------------------------
            if isIdentifierStart(character) {
                // **先頭の1文字は無条件に取り込む。** `end = i` から始めてはいけない。
                //
                // `#` と `@` は識別子の**先頭**にはなれるが `isIdentifierPart` ではない。
                // `end = i` から始めると、この2文字では while が1度も回らず
                // `word` が空のまま `i = end`（＝ `i`）へ戻り、**無限ループする。**
                // 走査器は MainActor 上で動くので、これは色が崩れるのではなく
                // **アプリが固まる**（`@State` を含む Swift のコードブロックで必ず再現した）。
                //
                // ここから始めれば、どの文字で入っても必ず1文字は進む。
                var end = i + 1
                while end < characters.count, isIdentifierPart(characters[end]) { end += 1 }
                let word = String(characters[i..<end])
                let kind: CodeTokenKind
                if grammar.keywords.contains(word) {
                    kind = .keyword
                } else if grammar.types.contains(word) {
                    kind = .type
                } else if nextNonSpace(characters, from: end) == "(" {
                    kind = .function
                } else if grammar.capitalizedAreTypes, let first = word.first, first.isUppercase {
                    kind = .type
                } else {
                    kind = .plain
                }
                if kind == .plain { plain += word } else { emit(word, kind) }
                i = end
                continue
            }

            // --- 記号 -------------------------------------------------------------
            if "{}()[]<>=+-*/%!&|^~?:;,.".contains(character) {
                emit(String(character), .punctuation)
                i += 1
                continue
            }

            plain.append(character)
            i += 1
        }

        flushPlain()
        return spans
    }

    private static func splitIntoLines(_ spans: [CodeSpan]) -> [[CodeSpan]] {
        var lines: [[CodeSpan]] = [[]]
        for span in spans {
            let pieces = span.text.components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                if index > 0 { lines.append([]) }
                if !piece.isEmpty {
                    lines[lines.count - 1].append(CodeSpan(text: piece, kind: span.kind))
                }
            }
        }
        return lines
    }

    // MARK: - 補助

    private static func matches(_ needle: String, _ characters: [Character], _ index: Int) -> Bool {
        let needleCharacters = Array(needle)
        guard index + needleCharacters.count <= characters.count else { return false }
        for (offset, character) in needleCharacters.enumerated()
        where characters[index + offset] != character {
            return false
        }
        return true
    }

    private static func previous(_ characters: [Character], _ index: Int) -> Character {
        index > 0 ? characters[index - 1] : " "
    }

    private static func nextNonSpace(_ characters: [Character], from index: Int) -> Character? {
        var i = index
        while i < characters.count, characters[i] == " " { i += 1 }
        return i < characters.count ? characters[i] : nil
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$" || character == "@" || character == "#"
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }
}

// MARK: - 言語定義

extension SyntaxHighlighter {

    /// 言語ごとの字句の決まり。**網羅よりも、間違っても壊れないことを優先している。**
    struct Grammar {
        var lineComments: [String] = ["//"]
        var blockComment: (open: String, close: String)? = ("/*", "*/")
        /// 長い区切りを先に置くこと（`"""` が `"` に食われるため）。
        var stringDelimiters: [String] = ["\"\"\"", "\"", "'"]
        var escape: Character? = "\\"
        var keywords: Set<String> = []
        var types: Set<String> = []
        var capitalizedAreTypes = false

        static func forLanguage(_ name: String?) -> Grammar {
            switch (name ?? "").lowercased() {
            case "swift": swift
            case "python", "py": python
            case "javascript", "js", "typescript", "ts", "tsx", "jsx": javascript
            case "rust", "rs": rust
            case "go", "golang": go
            case "c", "cpp", "c++", "objc", "objective-c", "m": clike
            case "sh", "bash", "zsh", "shell", "console": shell
            case "json": json
            case "yaml", "yml": yaml
            case "sql": sql
            default: plain
            }
        }

        static let swift = Grammar(
            keywords: [
                "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
                "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
                "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in",
                "indirect", "init", "inout", "internal", "is", "let", "mutating", "nil", "nonisolated",
                "open", "operator", "private", "protocol", "public", "repeat", "return", "self",
                "Self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
                "true", "try", "typealias", "var", "where", "while", "willSet", "didSet", "get", "set",
                "lazy", "weak", "unowned", "final", "override", "convenience", "required", "package",
            ],
            capitalizedAreTypes: true
        )

        static let python = Grammar(
            lineComments: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"\"\"", "'''", "\"", "'"],
            keywords: [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
                "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
                "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return",
                "True", "try", "while", "with", "yield", "match", "case", "self",
            ],
            types: ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "None"],
            capitalizedAreTypes: true
        )

        static let javascript = Grammar(
            stringDelimiters: ["\"", "'", "`"],
            keywords: [
                "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
                "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
                "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return",
                "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined",
                "var", "void", "while", "yield", "interface", "type", "enum", "implements", "readonly",
            ],
            types: ["string", "number", "boolean", "any", "unknown", "never", "void", "object"],
            capitalizedAreTypes: true
        )

        static let rust = Grammar(
            keywords: [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
                "trait", "true", "type", "unsafe", "use", "where", "while",
            ],
            types: ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "usize", "isize", "f32",
                    "f64", "bool", "char", "str", "String", "Vec", "Option", "Result"],
            capitalizedAreTypes: true
        )

        static let go = Grammar(
            stringDelimiters: ["\"", "`", "'"],
            keywords: [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
                "return", "select", "struct", "switch", "type", "var", "nil", "true", "false",
            ],
            types: ["string", "int", "int8", "int16", "int32", "int64", "uint", "byte", "rune",
                    "float32", "float64", "bool", "error", "any"],
            capitalizedAreTypes: true
        )

        static let clike = Grammar(
            keywords: [
                "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
                "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
                "register", "return", "short", "signed", "sizeof", "static", "struct", "switch",
                "typedef", "union", "unsigned", "void", "volatile", "while", "class", "namespace",
                "template", "public", "private", "protected", "virtual", "nullptr", "true", "false",
                "using", "new", "delete", "this",
            ],
            capitalizedAreTypes: true
        )

        static let shell = Grammar(
            lineComments: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"", "'"],
            keywords: [
                "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
                "case", "esac", "function", "return", "exit", "export", "local", "set", "source",
                "echo", "cd", "make", "sudo",
            ]
        )

        static let json = Grammar(
            lineComments: [],
            blockComment: nil,
            stringDelimiters: ["\""],
            keywords: ["true", "false", "null"]
        )

        static let yaml = Grammar(
            lineComments: ["#"],
            blockComment: nil,
            stringDelimiters: ["\"", "'"],
            keywords: ["true", "false", "null", "yes", "no"]
        )

        static let sql = Grammar(
            lineComments: ["--"],
            stringDelimiters: ["'", "\""],
            keywords: [
                "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
                "CREATE", "TABLE", "INDEX", "VIEW", "DROP", "ALTER", "JOIN", "LEFT", "RIGHT", "INNER",
                "OUTER", "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "AND", "OR",
                "NOT", "NULL", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK", "AS",
            ]
        )

        /// 言語が分からないとき。**推測で色を付けない。**
        /// 誤った色分けは、色が無いことより読み手を惑わせる。
        static let plain = Grammar(
            lineComments: [],
            blockComment: nil,
            stringDelimiters: [],
            escape: nil
        )
    }
}
