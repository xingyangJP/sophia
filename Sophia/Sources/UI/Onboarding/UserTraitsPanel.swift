import SwiftUI

// =============================================================================
//  覚えていることを見る・直す・消す（FR-28 / 14.15節）
// -----------------------------------------------------------------------------
//  # 出すものは 14.15節の表から採ってある
//
//  | 出すもの | ここに出しているか |
//  |---|---|
//  | **利用者像が毎ターン払っているトークン数。既定は `0`** | **出す**（※ 統計行にも出すのは別作業） |
//  | いま重みに入っている像の一覧 | 枠だけ。**焼く経路がまだ無いので常に空である** |
//  | **`stored` のまま待っている件数** | **出す** |
//  | 質問に何問答えたか（予算表） | **出す** |
//  | 直近の学習: いつ / 何件で / どれだけかかったか | **出していない。学習が未実装だから**（別作業） |
//  | 翻訳文 / 翻訳を切る操作 / 翻訳役の秒数 | **出していない。翻訳層が未実装だから**（別作業） |
//
//  **出していないものを「あとで」と書かずに空欄で置かないこと。**
//  空欄は「0 である」と読めてしまい、**未実装と 0 が区別できなくなる。**
//
//  # 消せることと、消えないことは両立する（`UserTraitsStoreTests` と同じ約束）
//
//  | 約束 | 出所 |
//  |---|---|
//  | **消えないこと。** 訂正されても、言語化された文の履歴は残る | 第8.4節 / NFR-12 |
//  | **消せること。** 利用者が消したものは完全に消える | FR-28 / NFR-01 |
//
//  **前者はシステムの都合による上書き、後者は利用者の明示的な意思**であり、別の操作である。
//
//  # 【未確認】この画面の描画は測っていない（`OnboardingView` の但し書きと同じ）
// =============================================================================

/// 記録の一覧（FR-28「閲覧・編集・削除」）。
struct UserTraitsPanel: View {

    @Bindable var model: OnboardingViewModel

    /// 「もう一度訊く」で質問面へ戻すために持つ。
    @Binding var face: UserTraitsSheet.Face

    /// いま編集中の像の id。nil なら誰も編集していない。
    @State private var editingID: String? = nil
    @State private var draft = ""
    @State private var confirmingErase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary

            Divider()

            if model.traits.isEmpty {
                empty
            } else {
                list
            }
        }
    }

    // MARK: - 数字（14.15節）

    private var summary: some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space2) {
            HStack(spacing: SophiaMetrics.space6) {
                number("\(model.perTurnTokenCost)", "毎ターンのトークン")
                number("\(model.storedCount)", "反映を待っている")
                number("\(model.trainingReadyCount)", "使う準備ができた")
                number("\(model.answeredQuestionCount) / \(model.questionUpperBound)", "答えた質問")
            }

            // **「0」が何を意味するかを書く。** 数字だけだと
            // 「まだ動いていない」と「費用が無い」の区別がつかない。
            Text("答えた内容はこの端末の中だけに置いてあり、毎ターンの送信には1文字も載っていません。"
                 + "重みへ反映する仕組みはまだありません（貯めているだけです）。")
                .font(SophiaFont.footnote)
                .foregroundStyle(SophiaColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SophiaMetrics.space5)
    }

    private func number(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 20).monospacedDigit())
                .foregroundStyle(SophiaColor.ink)
            Text(label)
                .font(SophiaFont.footnote)
                .foregroundStyle(SophiaColor.ink3)
        }
    }

    // MARK: - 空

    private var empty: some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space3) {
            Text("まだ何も覚えていません。")
                .font(SophiaFont.body)
                .foregroundStyle(SophiaColor.ink2)
            Text("覚えていなくても会話はいまと同じに動きます。ここが空であることは不具合ではありません。")
                .font(SophiaFont.footnote)
                .foregroundStyle(SophiaColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Button("質問に答える") {
                face = .asking
                Task { await model.start() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SophiaMetrics.space5)
    }

    // MARK: - 一覧

    private var list: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.traits) { trait in
                        row(trait)
                        Divider().padding(.leading, SophiaMetrics.space5)
                    }
                }
            }

            HStack {
                Spacer()
                Button("全部消す", role: .destructive) { confirmingErase = true }
                    .font(SophiaFont.subhead)
            }
            .padding(.horizontal, SophiaMetrics.space5)
            .padding(.vertical, SophiaMetrics.space2)
            .confirmationDialog(
                "覚えていることを全部消しますか",
                isPresented: $confirmingErase,
                titleVisibility: .visible
            ) {
                Button("全部消す", role: .destructive) {
                    Task { await model.eraseAll() }
                }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("文も、その履歴も消えます。取り消せません。")
            }
        }
    }

    private func row(_ trait: UserTraitRecord) -> some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space2) {
            if editingID == trait.id {
                // **書き直せること**は、例文が7通りしか無いことへの唯一の逃げ道である（14.16節⑫）。
                TextField("覚えていてほしいこと", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(SophiaFont.body)
                    .lineLimit(2...6)

                HStack(spacing: SophiaMetrics.space3) {
                    Button("保存") {
                        let text = draft
                        editingID = nil
                        Task { await model.edit(trait, to: text) }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("やめる") { editingID = nil }
                }
                .font(SophiaFont.subhead)
            } else {
                Text(trait.statement)
                    .font(SophiaFont.body)
                    .foregroundStyle(SophiaColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: SophiaMetrics.space2) {
                Text(axisLabel(trait))
                    .foregroundStyle(SophiaColor.ink3)
                dot
                Text(sourceLabel(trait.source))
                    .foregroundStyle(SophiaColor.ink3)
                dot
                Text(confidenceLabel(trait))
                    .foregroundStyle(trait.qualifiesForTraining()
                                     ? SophiaColor.accent : SophiaColor.ink3)
                dot
                Text(placementLabel(trait.placement))
                    .foregroundStyle(SophiaColor.ink3)

                Spacer(minLength: SophiaMetrics.space2)

                if editingID != trait.id {
                    Button("直す") {
                        draft = trait.statement
                        editingID = trait.id
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SophiaColor.accent)

                    if OnboardingQuestionnaire.question(trait.category) != nil {
                        Button("もう一度訊く") {
                            face = .asking
                            Task { await model.startReview(category: trait.category) }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(SophiaColor.accent)
                        .help("同じ二択をもう一度出します。同じ答えなら確からしさが上がり、"
                              + "違う答えなら書き換わります（前の文は履歴に残ります）")
                    }

                    Button("消す") {
                        Task { await model.delete(trait) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SophiaColor.ink3)
                }
            }
            .font(SophiaFont.footnote)
        }
        .padding(.horizontal, SophiaMetrics.space5)
        .padding(.vertical, SophiaMetrics.space3)
    }

    private var dot: some View {
        Text("·").foregroundStyle(SophiaColor.ink4)
    }

    // MARK: - 綴りを日本語にするだけ（意味は `Sources/Store/` が持っている）

    private func axisLabel(_ trait: UserTraitRecord) -> String {
        OnboardingQuestionnaire.question(trait.category)?.axis ?? trait.category
    }

    private func sourceLabel(_ source: TraitSource) -> String {
        switch source {
        case .onboarding: "質問で選んだ"
        case .correction: "会話で直された"
        case .translationEdit: "言い換えを直した"
        case .manual: "自分で書いた"
        }
    }

    private func placementLabel(_ placement: TraitPlacement) -> String {
        switch placement {
        case .stored: "送っていない"
        case .translating: "重みに入っている"
        case .retrieved: "必要なとき引く"
        }
    }

    /// **閾値との大小だけを見せる。** 0.5 や 0.7 という数字そのものには
    /// 測定の裏付けが無い（`UserTraitDefaults` の型コメント）ので、
    /// **「届いている / あと何回」を出す。**
    private func confidenceLabel(_ trait: UserTraitRecord) -> String {
        if trait.qualifiesForTraining() { return "使う準備ができた" }
        let gap = UserTraitDefaults.trainingConfidenceThreshold - trait.confidence
        let times = max(1, Int((gap / UserTraitDefaults.reinforcementStep).rounded(.up)))
        return "あと \(times) 回の裏づけが要る"
    }
}
