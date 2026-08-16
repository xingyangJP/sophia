import SwiftUI

/// 思考の折りたたみ表示（FR-17）。**A1 で最も重要な部品。**
///
/// # Open WebUI と逆にする2点（UI_SPEC.md 10.2-#1, #2）
///
/// | | Open WebUI 実測 | Sophia |
/// |---|---|---|
/// | 送信〜21秒 | 点滅するドットだけ | **プリフィルの進捗を出す** |
/// | 思考中の49秒 | 「思考中...」の1行のみ（既定で折りたたみ） | **既定で展開し、テキストを流す** |
///
/// > データは来ているのに隠している（UI_SPEC.md 6.1-3）
///
/// 本文が始まったら自動的に畳む。畳んだあとは利用者の開閉を尊重する。
struct ThinkingDisclosure: View {

    @Bindable var turn: ChatTurn

    var body: some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space1) {
            header
            if turn.thinkingExpanded, !turn.thinking.isEmpty {
                panel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - トグル行

    /// 枠も背景もないテキストボタン（UI_SPEC.md 7.1）。位置は本文の直上。
    private var header: some View {
        Button {
            turn.thinkingExpanded.toggle()
        } label: {
            HStack(spacing: SophiaMetrics.space2) {
                if turn.phase == .thinking {
                    // テラコッタを使ってよい数少ない場所（線・インジケータ限定）。
                    ProgressView()
                        .controlSize(.small)
                        .tint(SophiaColor.accentVivid)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: turn.thinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SophiaColor.ink3)
                        .frame(width: 12)
                }

                Text(turn.thinkingLabel)
                    .font(SophiaFont.body)
                    .foregroundStyle(SophiaColor.ink3)

                // 思考中は経過秒数を出し続ける。**待ち時間を隠さない**（VISION の測定原則）。
                if turn.phase == .thinking {
                    LiveElapsedText(since: turn.createdAt)
                        .font(SophiaFont.footnote)
                        .foregroundStyle(SophiaColor.ink4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(turn.thinking.isEmpty)
        .help(turn.thinkingExpanded ? "思考を隠します" : "思考を表示します")
    }

    // MARK: - 展開パネル

    /// 左罫 + 字下げ + イタリック（UI_SPEC.md 10.1-#10）。
    /// ただし色は本文より**薄く**する。Open WebUI は逆に濃くしており、主従が反転していた（10.2-#11）。
    private var panel: some View {
        HStack(alignment: .top, spacing: SophiaMetrics.space3) {
            Rectangle()
                .fill(SophiaColor.separator)
                .frame(width: SophiaLayout.quoteRuleWidth)

            Text(turn.thinking)
                .font(SophiaFont.thinking)
                .foregroundStyle(SophiaColor.ink3)
                .lineSpacing(SophiaLayout.messageLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, SophiaMetrics.space1)
        .padding(.bottom, SophiaMetrics.space1)
    }
}

/// 1秒ごとに経過時間だけを更新する。
///
/// `TimelineView` を使うのは、**ビューモデルを毎秒書き換えないため**。
/// 状態を触ると会話全体が再評価されるが、これなら再描画はこの1行に閉じる。
struct LiveElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(String(format: "%.0f秒", max(0, context.date.timeIntervalSince(since))))
                .monospacedDigit()
        }
    }
}
