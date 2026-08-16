import SwiftUI

/// Markdown を描く。**外部ライブラリを使わない**（NFR-01: オフライン）。
///
/// ブロックの分解は自前（`MarkdownParser`）、行内の装飾は Foundation の
/// `AttributedString(markdown:)` に任せる。後者は OS 同梱で通信もしない。
struct MarkdownText: View {

    let text: String
    /// 生成中に末尾へ出すキャレット。テラコッタを**面積ゼロで**使える数少ない場所
    /// （DESIGN.md 第9.2章 / UI_SPEC.md 10.3）。
    var showsCaret = false

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block, isLast: index == blocks.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, isLast: Bool) -> some View {
        switch block {
        case .paragraph(let content):
            paragraph(content, isLast: isLast)

        case .heading(let level, let content):
            InlineMarkdown.text(content)
                .font(headingFont(level))
                .foregroundStyle(SophiaColor.ink)
                .padding(.top, SophiaMetrics.space2)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: SophiaMetrics.space1) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "・", content: item)
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: SophiaMetrics.space1) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listRow(marker: "\(index + 1).", content: item)
                }
            }

        case .quote(let content):
            HStack(alignment: .top, spacing: SophiaMetrics.space3) {
                Rectangle()
                    .fill(SophiaColor.separator)
                    .frame(width: SophiaLayout.quoteRuleWidth)
                InlineMarkdown.text(content)
                    .font(SophiaFont.message)
                    .foregroundStyle(SophiaColor.ink2)
                    .lineSpacing(SophiaLayout.messageLineSpacing)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let code, let isClosed):
            CodeBlockView(language: language, code: code, isClosed: isClosed)
                .padding(.vertical, SophiaMetrics.space1)

        case .rule:
            Rectangle()
                .fill(SophiaColor.separator)
                .frame(height: SophiaMetrics.hairline)
                .padding(.vertical, SophiaMetrics.space1)
        }
    }

    private func paragraph(_ content: String, isLast: Bool) -> some View {
        // キャレットは Text の連結で入れる。別ビューにすると行末で折り返しから外れる。
        Group {
            if showsCaret && isLast {
                InlineMarkdown.text(content) + Text("▍").foregroundStyle(SophiaColor.accentVivid)
            } else {
                InlineMarkdown.text(content)
            }
        }
        .font(SophiaFont.message)
        .foregroundStyle(SophiaColor.ink)
        .lineSpacing(SophiaLayout.messageLineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func listRow(marker: String, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SophiaMetrics.space2) {
            Text(marker)
                .font(SophiaFont.message)
                .foregroundStyle(SophiaColor.ink3)
                .frame(minWidth: 16, alignment: .trailing)
            InlineMarkdown.text(content)
                .font(SophiaFont.message)
                .foregroundStyle(SophiaColor.ink)
                .lineSpacing(SophiaLayout.messageLineSpacing)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: SophiaFont.title1
        case 2: SophiaFont.title2
        default: Font.system(size: 15, weight: .semibold)
        }
    }
}

/// 行内の装飾（`**強調**` / `*斜体*` / `` `コード` `` / リンク）。
enum InlineMarkdown {

    static func text(_ source: String) -> Text {
        Text(attributed(source))
    }

    /// `AttributedString(markdown:)` は OS 同梱で外部通信をしない。
    /// 壊れた記法でも落ちないよう、失敗時は素のテキストへ落とす。
    static func attributed(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }

        // インラインコードだけ色を変える。太字・斜体は SwiftUI が
        // `inlinePresentationIntent` を見て自分で反映するので触らない。
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            attributed[run.range][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] =
                SophiaColor.accent
        }
        return attributed
    }
}
