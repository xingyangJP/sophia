import AppKit
import SwiftUI

/// コードブロック（FR-06）。**シンタックスハイライトとコピーだけ。**
///
/// UI_SPEC.md 10.2-#4 の判断に従い、Open WebUI の CodeMirror（編集可能・実行ボタン付き）は
/// 真似ない。コードブロック1個ごとにエディタを常駐させるのは 16GB 機で割に合わない。
///
/// 借りるのは 10.1-#13 の構造だけ ─ ヘッダに言語（左）と操作（右）、
/// コピーは**アイコンではなく文字ボタン**、行番号の溝 30pt。
struct CodeBlockView: View {

    let language: String?
    let code: String
    /// フェンスがまだ閉じていない = 生成中のコード。
    let isClosed: Bool

    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    private var highlighted: HighlightedCode {
        HighlightCache.shared.highlighted(code, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(SophiaColor.separator)
                .frame(height: SophiaMetrics.hairline)
            body(of: highlighted)
        }
        .background(SophiaColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: SophiaMetrics.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: SophiaMetrics.cardRadius)
                .stroke(SophiaColor.separator, lineWidth: SophiaMetrics.hairline)
        )
    }

    // MARK: - ヘッダ

    private var header: some View {
        HStack(spacing: SophiaMetrics.space2) {
            Text(language ?? "テキスト")
                .font(SophiaFont.codeHeader)
                .foregroundStyle(SophiaColor.ink3)
                .lineLimit(1)

            if !isClosed {
                // 生成中であることを隠さない。閉じていないコードは「まだ途中」である。
                Text("生成中")
                    .font(SophiaFont.codeHeader)
                    .foregroundStyle(SophiaColor.accent)
            }

            Spacer(minLength: SophiaMetrics.space2)

            Button(action: copy) {
                Text(copied ? "コピーしました" : "コピー")
                    .font(SophiaFont.codeHeader)
                    .foregroundStyle(copied ? SophiaColor.accent : SophiaColor.ink2)
                    .padding(.horizontal, SophiaMetrics.space2)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("コードをクリップボードへコピーします")
        }
        .padding(.horizontal, SophiaMetrics.space3)
        .frame(height: SophiaMetrics.space6 + SophiaMetrics.space1)   // 28pt
    }

    // MARK: - 本体

    private func body(of highlighted: HighlightedCode) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // 行番号の溝（UI_SPEC.md 10.1-#13）。横スクロールしても固定する。
            VStack(alignment: .trailing, spacing: SophiaLayout.codeLineSpacing) {
                ForEach(Array(highlighted.lines.indices), id: \.self) { index in
                    Text("\(index + 1)")
                        .font(SophiaFont.codeGutter)
                        .foregroundStyle(SophiaColor.ink4)
                }
            }
            .frame(width: SophiaLayout.codeGutterWidth, alignment: .trailing)
            .padding(.trailing, SophiaMetrics.space2)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: SophiaLayout.codeLineSpacing) {
                    ForEach(Array(highlighted.lines.indices), id: \.self) { index in
                        Text(attributed(highlighted.lines[index]))
                            .font(SophiaFont.code)
                            .textSelection(.enabled)
                            // 空行でも行の高さを保ち、行番号とずれないようにする
                            .frame(minHeight: 15, alignment: .leading)
                    }
                }
                .padding(.trailing, SophiaMetrics.space3)
            }
        }
        .padding(.vertical, SophiaMetrics.space2)
        .padding(.leading, SophiaMetrics.space2)
    }

    private func attributed(_ spans: [CodeSpan]) -> AttributedString {
        guard !spans.isEmpty else { return AttributedString(" ") }
        var result = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = color(for: span.kind)
            result.append(piece)
        }
        return result
    }

    private func color(for kind: CodeTokenKind) -> Color {
        switch kind {
        case .plain: SophiaCodeColor.plain
        case .comment: SophiaCodeColor.comment
        case .string: SophiaCodeColor.string
        case .number: SophiaCodeColor.number
        case .keyword: SophiaCodeColor.keyword
        case .type: SophiaCodeColor.type
        case .function: SophiaCodeColor.function
        case .punctuation: SophiaCodeColor.punctuation
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}

/// ハイライト結果のキャッシュ。
///
/// 生成中は flush のたびに末尾のコードブロックが伸びるため、
/// **伸びている1個は毎回計算し直しになる**（それは避けられない）。
/// 効くのは既に確定した過去のコードブロックのほうで、
/// これが無いと会話が長くなるほど1回の再描画が重くなる。
@MainActor
final class HighlightCache {
    static let shared = HighlightCache()

    private var storage: [Key: HighlightedCode] = [:]
    private var order: [Key] = []
    private let capacity = 64

    private struct Key: Hashable {
        let code: String
        let language: String?
    }

    func highlighted(_ code: String, language: String?) -> HighlightedCode {
        let key = Key(code: code, language: language)
        if let cached = storage[key] { return cached }

        let result = SyntaxHighlighter.highlight(code, language: language)
        storage[key] = result
        order.append(key)
        if order.count > capacity {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
        return result
    }
}
