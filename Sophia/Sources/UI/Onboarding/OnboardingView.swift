import SwiftUI

// =============================================================================
//  二択の画面（DESIGN.md 14.8節 / FR-26）
// -----------------------------------------------------------------------------
//  # 記入欄を1つも置いていない
//
//  > **実装上の含意**: オンボーディングの主画面は**記入欄ではなく、回答例の二択**になる。
//
//  利用者がここでしていることは、**自分について申告すること**ではなく
//  **目の前の2つの答えを評価すること**である。
//  「説明はどのくらい詳しいのが良いですか」と訊けば理想の自分が返るが、
//  **2つの答えを並べて「どちらが良いか」と訊けば、返るのは行動である。**
//
//  # 【未確認】この画面の描画は測っていない
//
//  `FolderUITests` の冒頭が同じ限界を書いている。真似る。
//  `ViewInspector` 等を入れていないので、`OnboardingQuestionsTests` が
//  確かめているのは**ビューが読む値**（`OnboardingViewModel` と
//  `OnboardingQuestionnaire`）**まで**である。
//  **「値は正しいが画面に出ていない」は、いまのテストでは捕まらない。**
//  ここに書いてある `Text` / `Button` の配置は、**実機で目視するまで【未確認】である。**
// =============================================================================

/// 利用者像の画面。**質問**と**記録**の2面を持つ。
///
/// 入口を1つにしてあるのは、**訊かれた内容がどこに入ったのかを、
/// 訊かれた場所からそのまま辿れるようにする**ためである（FR-28 / NFR-12）。
/// 別画面に分けると、「さっき答えたあれは何になったのか」を探す手間が増える。
struct UserTraitsSheet: View {

    enum Face {
        /// 二択を出している。
        case asking
        /// 記録の一覧（FR-28）。
        case records
    }

    @State private var model: OnboardingViewModel
    @State private var face: Face
    @Environment(\.dismiss) private var dismiss

    /// - Parameter store: nil でも開く。**保存できないことだけを出して、質問はしない。**
    init(store: Store?, face: Face = .asking) {
        _model = State(initialValue: OnboardingViewModel(store: store))
        _face = State(initialValue: face)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            Group {
                switch face {
                case .asking:
                    if let question = model.current {
                        OnboardingQuestionView(model: model, question: question)
                    } else {
                        intermission
                    }
                case .records:
                    UserTraitsPanel(model: model, face: $face)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let failure = model.failure {
                failureRow(failure)
            }
        }
        .frame(width: 640, height: 560)
        .background(SophiaColor.background)
        .task {
            if face == .asking {
                await model.start()
            } else {
                await model.reload()
            }
        }
    }

    // MARK: - 見出し

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: SophiaMetrics.space3) {
            Text(face == .asking ? "進め方を教える" : "覚えていること")
                .font(SophiaFont.title2)
                .foregroundStyle(SophiaColor.ink)

            if face == .asking, model.current != nil {
                // **何問中の何問目かを必ず出す。** 終わりが見えない質問は離脱を生む（14.9節）。
                Text("\(min(model.askedInThisRun + 1, model.limitForThisRun)) / \(model.limitForThisRun)")
                    .font(SophiaFont.footnote)
                    .foregroundStyle(SophiaColor.ink3)
            }

            Spacer(minLength: SophiaMetrics.space2)

            Picker("", selection: $face) {
                Text("質問").tag(Face.asking)
                Text("記録").tag(Face.records)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)

            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, SophiaMetrics.space5)
        .padding(.vertical, SophiaMetrics.space3)
    }

    // MARK: - 訊き終わったあと

    /// **ここで「何が起きたか」と「何が起きていないか」を両方書く。**
    ///
    /// 14.7節が既定を「貯めるが、送らない」と決めているので、
    /// **答えたのに何も変わらない。** それを書かないと、
    /// 「答えたのに賢くならない」という不信だけが残る ──
    /// **見えないまま黙って貯めるのが最も悪い**（14.7節）。
    private var intermission: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SophiaMetrics.space4) {
                Text(headline)
                    .font(SophiaFont.title3)
                    .foregroundStyle(SophiaColor.ink)

                VStack(alignment: .leading, spacing: SophiaMetrics.space2) {
                    costRow(
                        "いま毎ターン払っているトークン",
                        value: "\(model.perTurnTokenCost)",
                        note: "答えた内容は、どこにも送っていません。会話の速さも中身も変わりません"
                    )
                    costRow(
                        "次の反映を待っている件数",
                        value: "\(model.storedCount)",
                        note: "反映（学習）はまだ作られていません。貯めているだけです"
                    )
                    costRow(
                        "覚えたことを使う準備ができた件数",
                        value: "\(model.trainingReadyCount)",
                        note: "質問に1度答えただけでは、ここには入りません。"
                            + "同じ答えをもう一度選ぶか、会話の中で直されたときに上がります"
                    )
                }

                if remainingAskable > 0 {
                    Button(model.askedInThisRun == 0
                           ? "質問に答える（\(min(remainingAskable, OnboardingBudget.initialQuestionLimit)) 問）"
                           : "もう少し続ける（あと \(remainingAskable) 問）") {
                        Task {
                            if model.askedInThisRun == 0 {
                                await model.start()
                            } else {
                                await model.continueAsking()
                            }
                        }
                    }
                    .controlSize(.large)
                }

                Text(liftoffNote)
                    .font(SophiaFont.footnote)
                    .foregroundStyle(SophiaColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SophiaMetrics.space5)
        }
    }

    /// **まだ訊いていない軸**と**予算の残り**の、小さいほう。
    /// 予算（5問）を超えて訊かないことが FR-24 の「回数に上限を持つ」の実体である。
    private var remainingAskable: Int {
        min(model.remainingCategoryCount,
            max(0, model.questionUpperBound - model.answeredQuestionCount))
    }

    /// **まだ1問も見せていない回**と**訊き終わった回**で、言うことが違う。
    /// 訊く前に「記録したものはありません」と出すのは、事実ではあるが報告ではない。
    private var headline: String {
        if model.askedInThisRun == 0 {
            return remainingAskable > 0
                ? "いくつか選んでもらえれば、次からの説明の仕方が決まります。"
                : "訊けることは全部訊きました。"
        }
        return model.savedInThisRun > 0
            ? "\(model.savedInThisRun) 件を記録しました。"
            : "記録したものはありません。"
    }

    /// **実測を出すときは、その実測の限界も一緒に出す。**
    /// 14.13b節が自分で「件数とステップ数が交絡している」と警告しているので、
    /// **数字だけを引き写さない。**
    private var liftoffNote: String {
        """
        目安として、様式が1つ立ち上がったのは学習データ \
        \(OnboardingBudget.observedSamplesForLiftoff) 件のときでした\
        （2026-08-19 実測）。ただし件数と学習の回数が分けて測れていないため、\
        この数字は【未確認】です。質問だけでその数に届くとは考えていません ── \
        残りは会話の中で直された記録から集まります。
        """
    }

    private func costRow(_ title: String, value: String, note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SophiaMetrics.space3) {
            Text(value)
                .font(.system(size: 20).monospacedDigit())
                .foregroundStyle(SophiaColor.ink)
                .frame(minWidth: 34, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(SophiaFont.body)
                    .foregroundStyle(SophiaColor.ink)
                Text(note)
                    .font(SophiaFont.footnote)
                    .foregroundStyle(SophiaColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func failureRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SophiaMetrics.space2) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(SophiaColor.accentVivid)
            Text(message)
                .font(SophiaFont.footnote)
                .foregroundStyle(SophiaColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SophiaMetrics.space5)
        .padding(.vertical, SophiaMetrics.space2)
        .background(SophiaColor.surface)
    }
}

// MARK: - 二択1問

/// 1問ぶん。**この画面が持っている判断は「どちらを押されたか」だけである。**
/// 文言はすべて `OnboardingQuestionnaire`、保存はすべて `OnboardingViewModel` にある。
struct OnboardingQuestionView: View {

    @Bindable var model: OnboardingViewModel
    let question: OnboardingQuestion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SophiaMetrics.space4) {

                // ── 依頼（利用者の側の文）
                VStack(alignment: .leading, spacing: SophiaMetrics.space2) {
                    Text("あなたがこう頼んだとして")
                        .font(SophiaFont.subhead)
                        .foregroundStyle(SophiaColor.ink3)

                    Text(question.prompt)
                        .font(SophiaFont.message)
                        .foregroundStyle(SophiaColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(SophiaMetrics.space3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SophiaColor.surface)
                        .clipShape(RoundedRectangle(cornerRadius: SophiaMetrics.cardRadius))
                }

                Text("どちらの答えが良いですか")
                    .font(SophiaFont.headline)
                    .foregroundStyle(SophiaColor.ink)

                // ── 回答案2つ。**上下に並べる。**
                // 横に並べるとどちらも読み切れず、**長いほうが不利になる。**
                // 測っている軸は長さではないので、読みやすさを優先する。
                ForEach(question.choices) { choice in
                    choiceCard(choice)
                }

                HStack(spacing: SophiaMetrics.space4) {
                    Button("この質問は飛ばす") {
                        model.skipCurrentQuestion()
                    }
                    .buttonStyle(.plain)
                    .font(SophiaFont.subhead)
                    .foregroundStyle(SophiaColor.ink3)
                    .help("何も記録しません。次に開いたとき、また出ます")

                    Button("ここでやめる") {
                        model.stop()
                    }
                    .buttonStyle(.plain)
                    .font(SophiaFont.subhead)
                    .foregroundStyle(SophiaColor.ink3)
                    .help("ここまでに選んだぶんは、すでに記録されています")

                    Spacer(minLength: 0)

                    Text(question.axis)
                        .font(SophiaFont.footnote)
                        .foregroundStyle(SophiaColor.ink4)
                }
            }
            .padding(SophiaMetrics.space5)
        }
    }

    /// **どちらも良い答えとして見せる。**
    /// 片方を推奨の見た目にすると、選択ではなく正解当てになる（FR-26 が空振りする）。
    private func choiceCard(_ choice: OnboardingChoice) -> some View {
        Button {
            Task { await model.choose(choice.side) }
        } label: {
            Text(choice.sample)
                .font(choice.isCode ? SophiaFont.code : SophiaFont.message)
                .foregroundStyle(SophiaColor.ink)
                .multilineTextAlignment(.leading)
                .lineSpacing(choice.isCode
                             ? SophiaLayout.codeLineSpacing
                             : SophiaLayout.messageLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SophiaMetrics.space4)
                .background(SophiaColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: SophiaMetrics.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: SophiaMetrics.cardRadius)
                        .stroke(SophiaColor.separator, lineWidth: SophiaMetrics.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("二択") {
    UserTraitsSheet(store: nil)
}
