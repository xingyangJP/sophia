import SwiftUI

/// 1発言の描画。
///
/// 発言者の区別は**器だけ**でつける（UI_SPEC.md 10.1-#4, #5）。
/// 文字サイズも色も同じで、ユーザーは右寄せのバブル、AI は左寄せ・全幅・背景なし。
/// アバターもラベルも要らない。
struct TurnView: View {
    @Bindable var turn: ChatTurn

    var body: some View {
        switch turn.author {
        case .user: userBubble
        case .assistant: assistantBlock
        }
    }

    // MARK: - ユーザー発言

    private var userBubble: some View {
        HStack {
            Spacer(minLength: SophiaMetrics.space6)
            Text(turn.text)
                .font(SophiaFont.message)
                .foregroundStyle(SophiaColor.ink)
                .lineSpacing(SophiaLayout.messageLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SophiaMetrics.space4)
                .padding(.vertical, SophiaMetrics.space2)
                .background(SophiaColor.surface)
                // 入力欄と同じ角丸にする。「利用者が書くもの」の形を揃える（UI_SPEC.md 10.1-#15）
                .clipShape(RoundedRectangle(cornerRadius: SophiaMetrics.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: SophiaMetrics.cardRadius)
                        .stroke(SophiaColor.separator, lineWidth: SophiaMetrics.hairline)
                )
        }
    }

    // MARK: - AI 応答

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space2) {
            // 1. 送信直後の無言を潰す（DESIGN.md 第6章）
            if case .waiting = turn.phase { waitingRow }
            if case .prefilling(let progress) = turn.phase { prefillRow(progress) }

            // 2. 思考（FR-17）。生成開始と同時に出る
            if !turn.thinking.isEmpty || turn.phase == .thinking {
                ThinkingDisclosure(turn: turn)
            }

            // 3. 本文
            if !turn.text.isEmpty {
                MarkdownText(text: turn.text, showsCaret: turn.phase == .responding)
            }

            // 4. 失敗（FR-11）。**中断はここに来ない。** 異常ではないため
            if let error = turn.error { errorRow(error) }

            // 5. 中断された旨。既出力が残っていることを明示する（FR-02）
            if turn.wasInterrupted, turn.phase == .finished {
                Text(turn.isEmpty ? "生成を中断しました。" : "生成を中断しました。ここまでの出力は残しています。")
                    .font(SophiaFont.callout)
                    .foregroundStyle(SophiaColor.ink3)
            }

            // 6. 計測値（FR-14）
            StatsLine(turn: turn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 送信直後。**「考えています」ではなく、何をしているかを出す。**
    private var waitingRow: some View {
        HStack(spacing: SophiaMetrics.space2) {
            ProgressView()
                .controlSize(.small)
                .tint(SophiaColor.accentVivid)
                .frame(width: 12, height: 12)
            Text("入力を読み込んでいます")
                .font(SophiaFont.body)
                .foregroundStyle(SophiaColor.ink3)
            LiveElapsedText(since: turn.createdAt)
                .font(SophiaFont.footnote)
                .foregroundStyle(SophiaColor.ink4)
        }
    }

    /// プリフィルの進捗。
    ///
    /// 実測ではここが 12.9 秒かかる（VISION）。**この帯があるかどうかで
    /// 「壊れている」と「動いている」の印象が変わる。**
    private func prefillRow(_ progress: PrefillProgress) -> some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space1) {
            HStack(spacing: SophiaMetrics.space2) {
                Text("入力を処理しています")
                    .font(SophiaFont.body)
                    .foregroundStyle(SophiaColor.ink3)
                Text("\(progress.processedTokens) / \(progress.totalTokens) トークン")
                    .font(SophiaFont.footnote)
                    .foregroundStyle(SophiaColor.ink4)
                LiveElapsedText(since: turn.createdAt)
                    .font(SophiaFont.footnote)
                    .foregroundStyle(SophiaColor.ink4)
            }
            ProgressView(value: progress.fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(SophiaColor.accentVivid)
                .frame(maxWidth: 240)
        }
    }

    /// FR-11: 原因と対処を日本語で出す。`message` と `hint` はそのまま表示してよい文になっている。
    private func errorRow(_ error: SophiaError) -> some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space1) {
            HStack(alignment: .firstTextBaseline, spacing: SophiaMetrics.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(SophiaColor.accent)
                Text(error.message)
                    .font(SophiaFont.body)
                    .foregroundStyle(SophiaColor.ink)
            }
            if let hint = error.hint {
                Text(hint)
                    .font(SophiaFont.callout)
                    .foregroundStyle(SophiaColor.ink2)
                    .padding(.leading, SophiaMetrics.space5)
            }
        }
        .padding(SophiaMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SophiaColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: SophiaMetrics.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: SophiaMetrics.controlRadius)
                .stroke(SophiaColor.accentVivid.opacity(0.5), lineWidth: SophiaMetrics.hairline)
        )
    }
}

/// 速度の表示（FR-14）。
///
/// > 「1/1000」は主張ではなく測定対象である（VISION）
///
/// **遅さを隠さない。** 生成中は経過時間を出し続け、終わったら実測値を残す。
/// Open WebUI は入力トークン数をどこにも出しておらず、
/// それが 4,786 トークンの無駄な注入が長く見過ごされた一因だった（UI_SPEC.md 10.2-#6）。
struct StatsLine: View {
    @Bindable var turn: ChatTurn

    var body: some View {
        if turn.phase == .responding {
            HStack(spacing: SophiaMetrics.space2) {
                Text("生成中")
                LiveElapsedText(since: turn.createdAt)
            }
            .font(SophiaFont.footnote)
            .foregroundStyle(SophiaColor.ink4)
        } else if let stats = turn.stats {
            HStack(spacing: SophiaMetrics.space2) {
                Text(stats.summaryLine)
                if turn.statsAreEstimated {
                    // `.done` が届かないまま終わった。BENCH に載せてはいけない値である。
                    Text("（概算）")
                }
                #if DEBUG
                // 間引きが効いているかを推測せず数える。断片 ≫ 描画 になっていれば効いている。
                if turn.chunkCount > 0 {
                    Text("｜断片 \(turn.chunkCount) → 描画 \(turn.flushCount)")
                }
                #endif
            }
            .font(SophiaFont.footnote)
            .foregroundStyle(SophiaColor.ink4)
            .textSelection(.enabled)
        }
    }
}
