import SwiftUI

/// 入力欄（FR-02 / FR-18）。
///
/// **スクロール領域の外に置く**（UI_SPEC.md 10.1-#6）。
/// 生成中にスクロールしても入力欄が動かない ─ NFR-02 の体感に直接効く。
struct ComposerView: View {

    @Bindable var model: ChatViewModel
    @State private var textHeight = SophiaLayout.composerMinTextHeight
    /// プレースホルダ判定専用。`model.input.isEmpty` を使わないのは、
    /// IME 変換中の未確定文字が `model.input` に反映されないため
    /// （詳細は ComposerTextView.isVisuallyEmpty のコメント）。
    @State private var isVisuallyEmpty = true

    var body: some View {
        VStack(spacing: SophiaMetrics.space1) {
            if model.inputBudgetExceeded { budgetWarning }

            VStack(spacing: SophiaMetrics.space2) {
                textArea
                toolbar
            }
            .padding(.horizontal, SophiaMetrics.space3)
            .padding(.vertical, SophiaMetrics.space2)
            .background(SophiaColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: SophiaMetrics.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: SophiaMetrics.cardRadius)
                    .stroke(SophiaColor.separator, lineWidth: SophiaMetrics.hairline)
            )
        }
        .frame(maxWidth: SophiaLayout.columnMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SophiaMetrics.space5)
        .padding(.top, SophiaMetrics.space2)
        .padding(.bottom, SophiaMetrics.space4)
    }

    // MARK: - テキスト

    private var textArea: some View {
        ComposerTextView(
            text: $model.input,
            contentHeight: $textHeight,
            isVisuallyEmpty: $isVisuallyEmpty,
            onSubmit: { model.send() }
        )
        .frame(height: min(textHeight, SophiaLayout.composerMaxTextHeight))
        .overlay(alignment: .topLeading) {
            if isVisuallyEmpty {
                Text("Sophia に相談する")
                    .font(SophiaFont.message)
                    .foregroundStyle(SophiaColor.ink4)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - ツールバー行

    private var toolbar: some View {
        HStack(spacing: SophiaMetrics.space3) {
            thinkingToggle

            Spacer(minLength: SophiaMetrics.space2)

            // モデル名は表示のみ。切替は A2 以降（モデル管理UIは A1 のスコープ外）。
            if let model = model.model {
                Text(model.displayName)
                    .font(SophiaFont.subhead)
                    .foregroundStyle(SophiaColor.ink3)
                    .lineLimit(1)
            }

            primaryAction
        }
    }

    /// FR-18。**会話ごとの1タップ切替**として入力欄に置く。
    /// Open WebUI のように15項目のパラメータ引き出しへ埋めない（UI_SPEC.md 10.2-#3）。
    private var thinkingToggle: some View {
        Toggle(isOn: $model.thinkingEnabled) {
            Text("思考")
                .font(SophiaFont.body)
                .foregroundStyle(SophiaColor.ink2)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(SophiaColor.accentVivid)
        .disabled(!model.canToggleThinking || model.isGenerating)
        .help(
            model.canToggleThinking
                ? "思考モード。有効にすると答える前に考えますが、生成にかかる時間は大きく増えます"
                : "このモデルは思考モードを無効にできません"
        )
    }

    /// 送信と中断は**同じ位置・同じ大きさ**で、塗りだけが反転する（UI_SPEC.md 10.1-#7）。
    /// 位置が動かないので、目で追わずに押せる。
    private var primaryAction: some View {
        Group {
            if model.isGenerating {
                Button(action: model.stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SophiaColor.ink)
                        .frame(width: SophiaMetrics.primaryControlHeight,
                               height: SophiaMetrics.primaryControlHeight)
                        .background(Circle().fill(SophiaColor.background))
                        .overlay(Circle().stroke(SophiaColor.separator,
                                                 lineWidth: SophiaMetrics.hairline))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .help("生成を中断します（⌘.）。ここまでの出力は消えません")
            } else {
                Button(action: model.send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SophiaColor.background)
                        .frame(width: SophiaMetrics.primaryControlHeight,
                               height: SophiaMetrics.primaryControlHeight)
                        .background(Circle().fill(
                            model.canSend ? SophiaColor.ink : SophiaColor.ink4
                        ))
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .help("送信します（Enter）。改行は Shift+Enter")
            }
        }
    }

    // MARK: - 予算の警告

    /// DESIGN.md 第2.2章の入力トークン予算。
    /// **無駄な入力が「痛み」として見えないと、誰も減らさない**（VISION 第1因子）。
    private var budgetWarning: some View {
        HStack(spacing: SophiaMetrics.space2) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 10))
            Text("入力が約 \(model.estimatedInputTokens) トークン（目安 \(SophiaDefaults.inputTokenBudget)）。"
                 + "入力処理だけで10秒以上かかる見込みです")
        }
        .font(SophiaFont.footnote)
        .foregroundStyle(SophiaColor.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SophiaMetrics.space1)
    }
}
