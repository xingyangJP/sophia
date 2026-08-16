import Foundation

/// Markdown の1ブロック。**外部ライブラリを使わない**（NFR-01: オフラインで動くこと）。
///
/// A1 で扱う範囲は「モデルが実際に出すもの」に絞ってある。
/// 表・脚注・リンク参照などは出てきてから足す。
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullets([String])
    case ordered([String])
    case quote(String)
    /// コードブロック（FR-06）。
    /// `isClosed` が false なら**まだ閉じていない** = 生成中のコードである。
    case code(language: String?, code: String, isClosed: Bool)
    case rule
}

enum MarkdownParser {

    /// 行単位の素朴なブロック分割。**入力長に対して線形。**
    ///
    /// 生成中は flush のたび（最大62回/秒）に全文を再解析する。
    /// A1 の長さ（数KB）ではこれで足りる。
    /// **足りなくなったら「確定した前半」と「末尾の未確定部分」を分ける**
    /// （DESIGN.md 第5.2章の案(a)）が、まず測ってから決めること。
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets.removeAll() }
            if !ordered.isEmpty { blocks.append(.ordered(ordered)); ordered.removeAll() }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote.removeAll() }
        }
        func flushAll() { flushParagraph(); flushLists() }

        var lines = text.components(separatedBy: "\n")[...]

        while let line = lines.first {
            lines = lines.dropFirst()
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // --- コードフェンス ---------------------------------------------
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var closed = false
                while let inner = lines.first {
                    lines = lines.dropFirst()
                    if inner.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        closed = true
                        break
                    }
                    body.append(inner)
                }
                blocks.append(.code(
                    language: language.isEmpty ? nil : language.lowercased(),
                    code: body.joined(separator: "\n"),
                    isClosed: closed
                ))
                continue
            }

            // --- 空行 ---------------------------------------------------------
            if trimmed.isEmpty {
                flushAll()
                continue
            }

            // --- 水平線 -------------------------------------------------------
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }

            // --- 見出し -------------------------------------------------------
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.dropFirst(level).hasPrefix(" ") {
                    flushAll()
                    blocks.append(.heading(
                        level: level,
                        text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    ))
                    continue
                }
            }

            // --- 引用 ---------------------------------------------------------
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                if !bullets.isEmpty || !ordered.isEmpty { flushLists() }
                quote.append(String(trimmed.dropFirst(trimmed == ">" ? 1 : 2)))
                continue
            }

            // --- 箇条書き -----------------------------------------------------
            if let item = bulletItem(trimmed) {
                flushParagraph()
                if !ordered.isEmpty || !quote.isEmpty { flushLists() }
                bullets.append(item)
                continue
            }
            if let item = orderedItem(trimmed) {
                flushParagraph()
                if !bullets.isEmpty || !quote.isEmpty { flushLists() }
                ordered.append(item)
                continue
            }

            // --- ふつうの段落 ---------------------------------------------------
            flushLists()
            paragraph.append(line)
        }

        flushAll()
        return blocks
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }
}
