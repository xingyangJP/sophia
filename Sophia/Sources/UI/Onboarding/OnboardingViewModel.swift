import Foundation
import Observation

// =============================================================================
//  訊いて、保存する（DESIGN.md 14.7節・14.8節・14.9節 / FR-24・26・28・29）
// -----------------------------------------------------------------------------
//  # この型が引き受ける範囲は「保存する」までで終わる
//
//  > **既定は `stored`（＝どこにも送らない）。毎ターンの費用は 0。**
//  > 採れた知見が即座に効かないのは、欠陥ではなく設計である。 ── 14.7節
//
//  保存された像がこの後どうなるか（翻訳層 / 学習 / 重み）は**まだ誰も作っていない。**
//  **それでよい。** 14.13節の梯子の段0（貯めるだけ）は「常に成立する」段であり、
//  **費用0で、1件も失われない。** 回るようになった日に、貯めたものがそのまま教師データになる。
//
//  # 保存は1問ごとに確定する。まとめてコミットしない
//
//  **これが「いつでも抜けられる」の実体である**（FR-24）。
//  最後に「保存」ボタンを置く形だと、**途中でやめた人の答えは全部消える** ──
//  訊いた時間だけを取って何も残さないのは、利用者のエネルギーの純損である。
//
//  # `Store` を変えていない
//
//  この型は `Sources/Store/` の API を**呼ぶだけ**である。
//  `recordTrait` / `reinforceTrait` / `reviseTrait` / `deleteTrait` /
//  `eraseAllUserTraits` / `allTraits` / `storedTraitCount` / `traitsForTraining`。
//  **確信度の既定値も、関門の閾値も、こちらでは決めていない。**
// =============================================================================

/// 初回の質問と、あとから見る画面の両方を駆動する（FR-24 / FR-26 / FR-28 / FR-29）。
@MainActor @Observable
final class OnboardingViewModel {

    // MARK: - 依存

    /// 保存先。**nil でも画面は壊れない**（NFR-11 と同じ形）。
    /// 開けていないときは、訊かずに「保存先を開けていません」とだけ出す ──
    /// **保存できないのに訊くのは、利用者のエネルギーを捨てるだけである。**
    @ObservationIgnored private let store: Store?

    init(store: Store?) {
        self.store = store
    }

    // MARK: - いま画面に出ているもの

    /// いま出している1問。nil なら質問は出ていない（未開始・打ち切り・尽きた）。
    private(set) var current: OnboardingQuestion?

    /// この回で**見せた**問数。**飛ばした問も数える。**
    ///
    /// > **訊くこと自体が利用者のエネルギーである**（14.9節）
    ///
    /// 費用は答えたときではなく**見せた時点で**発生している。
    /// 飛ばした問を数えないと、「飛ばし続ければ何問でも出る」形になり、予算表が空文になる。
    private(set) var askedInThisRun = 0

    /// この回の上限。既定は 3（`OnboardingBudget.initialQuestionLimit`）。
    private(set) var limitForThisRun = OnboardingBudget.initialQuestionLimit

    /// この回で**保存できた**件数。飛ばしたぶんは入らない。
    private(set) var savedInThisRun = 0

    /// 質問が出せる状態ではなくなった（尽きた・上限・打ち切り）。
    private(set) var isFinished = false

    /// 保存に失敗したときだけ立つ。**会話も設定画面も、これが立っても動く。**
    private(set) var failure: String?

    // MARK: - 全体の状態（14.15節 / FR-28・29）

    /// いま持っている利用者像すべて。
    private(set) var traits: [UserTraitRecord] = []

    /// **`stored` のまま待っている件数**（14.7節 / 14.15節）。
    ///
    /// > 利用者には「◯件が次の反映を待っています」と見せる。
    /// > **待っていることが見えれば、待たされていることに文句を言える。**
    private(set) var storedCount = 0

    /// **学習の関門（確信度 0.7）を越えている件数**（14.14節）。
    ///
    /// ## この数がしばらく 0 のままであることは、欠陥ではない
    ///
    /// `TraitSource.onboarding.defaultConfidence` は **0.5** で、
    /// 関門は **0.7** である（どちらも `Sources/Store/` が決めている。ここでは変えない）。
    /// **つまり質問に答えただけでは、その像は学習データに入らない。**
    ///
    /// 14.8節がその理由を先に書いている ──
    ///
    /// > **暗黙知は質問では取れない。** 質問がショートカットするのは言語化できる半分だけで、
    /// > **残り半分は観察でしか取れない。質問は、ログが貯まるまでを快適にするためのものである。**
    ///
    /// 関門を越える道は2つあり、**どちらも二度目の観測を要求する:**
    /// 同じ答えをもう一度選ぶ（`reinforceTrait` で +0.1）か、訂正されるか。
    private(set) var trainingReadyCount = 0

    /// **利用者像が毎ターン消費しているトークン数**（FR-29 / 14.15節）。
    ///
    /// > **「毎ターン 0」を出すことが、この設計の主張そのものである。**
    /// > 初版のまま作れば、ここには数百という数字が出て、**会話が続く限り出続けた。**
    ///
    /// **定数である。** 計算していないのではなく、**送る経路がどこにも無い。**
    /// `stored` の像は誰にも送られず、`translating` の像は重みの中にいる（入力に載らない）。
    /// **ここが 0 でなくなる日は、`ChatOptions` に載せる経路を誰かが足した日である。**
    let perTurnTokenCost = 0

    /// 答え済みの軸。木の traversal に使う。
    private var answeredCategories: Set<String> {
        Set(traits.filter { $0.kind == .style }.map(\.category))
    }

    /// この回で飛ばした軸。**保存はしていないので `answeredCategories` には入らない。**
    /// 次にこの画面を開けば、また出る。
    private var skippedInThisRun: Set<String> = []

    /// いま出してはいけない軸（答え済み ∪ この回で飛ばした）。
    private var excluded: Set<String> { answeredCategories.union(skippedInThisRun) }

    /// 木に残っている未回答の軸の数。**「あと何問訊けるか」ではない**（上限が別にある）。
    var remainingCategoryCount: Int {
        OnboardingQuestionnaire.all.count - answeredCategories.count
    }

    /// 何問答えたか（14.15節「質問に何問答えたか（予算表）」）。
    var answeredQuestionCount: Int { answeredCategories.count }

    var questionUpperBound: Int { OnboardingBudget.hardQuestionLimit }

    // MARK: - 読む

    /// DB から読み直す。**画面を開くたびに呼ぶ。**
    func reload() async {
        guard let store else {
            failure = "保存先（sophia.db）を開けていません。この画面は表示だけで、記録はできません"
            return
        }
        do {
            traits = try await store.allTraits()
            storedCount = try await store.storedTraitCount()
            trainingReadyCount = try await store.traitsForTraining().count
            failure = nil
        } catch {
            failure = "読み出しに失敗しました: \(error)"
        }
    }

    // MARK: - 訊く（FR-24 / FR-26）

    /// 初回。**上限は 3 問**（`OnboardingBudget.initialQuestionLimit`）。
    ///
    /// 14.9節の「3〜5問」の**下限**を採ってある。理由は `OnboardingBudget` に書いた
    /// ── 的中率が未測定である以上、**外して高くつく側（訊きすぎ）を避ける。**
    func start() async {
        await reload()
        beginRun(limit: min(OnboardingBudget.initialQuestionLimit, remainingBudget))
    }

    /// **上限は「この回」ではなく「通算」で効く**（FR-24「質問の回数に上限を持つ」）。
    ///
    /// 回ごとの上限にすると、閉じて開き直すだけで何度でも訊ける形になり、
    /// **予算表が空文になる。** 通算の問数は DB に入っている軸の数で数える
    /// ── 回をまたいでも、アプリを落としても、数え直しが要らない。
    private var remainingBudget: Int {
        max(0, OnboardingBudget.hardQuestionLimit - answeredQuestionCount)
    }

    /// 「もう少し続ける」。**通算 5 問の残りぶんだけ訊く。**
    ///
    /// > 設定画面から任意に | **上限なし** | 効果を実感した人だけが深める ── 14.9節
    ///
    /// **「上限なし」を問数の無制限とは読んでいない。** 訊く価値のある軸を
    /// 7つしか用意できていないのに問い続けると、利得の低い問いが混ざる（14.9節）。
    /// **上限なしに当たるのは `startReview`（再確認）のほうである** ── あちらは
    /// 新しい軸を増やさないので、何度でも深められる。
    func continueAsking() async {
        await reload()
        beginRun(limit: remainingBudget)
    }

    /// **答え済みの軸をもう一度訊く。**
    ///
    /// ## これが確信度を上げる唯一の入口である
    ///
    /// 14.14節は様式の更新を「**追記して確信度を上げる**」と決めている。
    /// 同じ二択にもう一度同じ答えが返れば、それは**二度目の顕示選好**であり、
    /// `reinforceTrait`（+0.1）が正しい経路である。
    /// **0.5 → 0.6 → 0.7 と、二度の再確認で関門に届く。**
    ///
    /// **数字は1つも発明していない** ── 初期値も刻み幅も閾値も `Sources/Store/` が持っている。
    ///
    /// ## 通算の問数を消費しない
    ///
    /// 新しい軸を1つも増やさないからである（`answeredQuestionCount` は
    /// DB にある軸の数で、再確認では変わらない）。
    /// **14.9節の「設定画面から任意に ─ 上限なし」に当たるのはこちらである。**
    func startReview(category: String) async {
        await reload()
        beginRun(limit: 1, startingAt: OnboardingQuestionnaire.question(category))
    }

    private func beginRun(limit: Int, startingAt question: OnboardingQuestion? = nil) {
        skippedInThisRun = []
        askedInThisRun = 0
        savedInThisRun = 0
        limitForThisRun = max(0, limit)
        isFinished = false

        // **保存できないなら訊かない。**
        // 答えさせて捨てるのは、利用者のエネルギーを取るだけで何も返さない ──
        // この機能で最も避けたい形である（14.9節「訊くこと自体が利用者のエネルギー」）。
        guard store != nil, limitForThisRun > 0 else {
            current = nil
            isFinished = true
            return
        }

        current = question ?? OnboardingQuestionnaire.first(answered: excluded)
        if current == nil { isFinished = true }
    }

    /// **選ぶ**（FR-26）。1問ぶんが即座に確定する。
    func choose(_ side: OnboardingChoice.Side) async {
        guard let question = current, let choice = question.choice(side) else { return }

        askedInThisRun += 1
        await persist(question: question, choice: choice)
        advance(from: question, choosing: side)
    }

    /// **この質問は飛ばす**（FR-24「中断・スキップでき、後から再開できる」）。
    ///
    /// **何も書かない。** 無回答は像ではない ──
    /// **適当な答えは誤った利用者像になり、無いより悪い**（14.16節①）。
    /// 「分からない」を保存する形にしないのはそのためである。
    func skipCurrentQuestion() {
        guard let question = current else { return }
        skippedInThisRun.insert(question.category)
        askedInThisRun += 1
        // **飛ばした問には答えが無いので、枝を選べない。** 宣言順の未回答へ落とす。
        guard askedInThisRun < limitForThisRun else {
            current = nil
            isFinished = true
            return
        }
        current = OnboardingQuestionnaire.first(answered: excluded)
        if current == nil { isFinished = true }
    }

    /// **ここでやめる。** 選んだぶんは既に保存されている（1問ごとに確定しているため）。
    func stop() {
        current = nil
        isFinished = true
    }

    private func advance(from question: OnboardingQuestion, choosing side: OnboardingChoice.Side) {
        guard askedInThisRun < limitForThisRun else {
            current = nil
            isFinished = true
            return
        }
        current = OnboardingQuestionnaire.next(
            after: question, choosing: side, answered: excluded
        )
        if current == nil { isFinished = true }
    }

    // MARK: - 保存（14.14節。**更新経路は kind ごとに分ける**）

    private func persist(question: OnboardingQuestion, choice: OnboardingChoice) async {
        guard let store else {
            failure = "保存先を開けていません。この答えは記録されませんでした"
            return
        }
        do {
            let existing = traits.first {
                $0.kind == .style && $0.category == question.category
            }
            switch existing {
            case .none:
                // **新規。** `placement` は既定の `.stored` ＝ どこにも送らない（14.7節）。
                // 確信度も渡さない ── `TraitSource.onboarding.defaultConfidence` に従う。
                try await store.recordTrait(
                    kind: .style,
                    category: question.category,
                    statement: choice.statement,
                    source: .onboarding
                )

            case .some(let trait) where trait.statement == choice.statement:
                // **同じ答えが二度目。** 様式は追記して確信度を上げる（14.14節）。
                try await store.reinforceTrait(id: trait.id, source: .onboarding)

            case .some(let trait):
                // **答えが変わった。** 二択で選び直したのは顕示選好であって
                // 自分で書いた文（`.manual`）ではないので、出所は `.correction` にする。
                // **前の文は `user_trait_revisions` に残る。消えない**（第8.4節 / NFR-12）。
                try await store.reviseTrait(
                    id: trait.id, statement: choice.statement, source: .correction
                )
            }
            savedInThisRun += 1
            await reload()
        } catch {
            failure = "保存に失敗しました: \(error)"
        }
    }

    // MARK: - あとから直す・消す（FR-28）

    /// **利用者が自分で文を書き直す。**出所は `.manual`。
    ///
    /// 二択で採った文がそのまま正しいとは限らない ── 例文は7通りしか無く、
    /// **その人の様式がその7通りのどれとも違うことは普通にある**（14.16節⑫）。
    /// **書き直せることは、例文の粗さに対する唯一の逃げ道である。**
    func edit(_ trait: UserTraitRecord, to statement: String) async {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !trimmed.isEmpty, trimmed != trait.statement else { return }
        do {
            try await store.reviseTrait(id: trait.id, statement: trimmed, source: .manual)
            await reload()
        } catch {
            failure = "書き換えに失敗しました: \(error)"
        }
    }

    /// **消す**（FR-28「削除したものは完全に消える」）。
    ///
    /// ⚠ **DB から消えても、既に焼いてあるアダプタの重みからは消えない。**
    /// `TraitErasureOutcome` がそれを名指すので、**戻り値を捨てない。**
    /// いまは焼く経路そのものが無いので必ず空になるが、
    /// **黙って捨てると、焼く経路ができた日に静かに嘘をつく画面になる。**
    func delete(_ trait: UserTraitRecord) async {
        guard let store else { return }
        do {
            let outcome = try await store.deleteTrait(id: trait.id)
            // **読み直してから報告する。** 逆にすると `reload()` が
            // 「まだアダプタに残っている」という知らせを消してしまう。
            await reload()
            report(outcome)
        } catch {
            failure = "削除に失敗しました: \(error)"
        }
    }

    /// **全部消す**（FR-28 / NFR-01）。
    func eraseAll() async {
        guard let store else { return }
        do {
            let outcome = try await store.eraseAllUserTraits()
            await reload()
            report(outcome)
        } catch {
            failure = "削除に失敗しました: \(error)"
        }
    }

    private func report(_ outcome: TraitErasureOutcome) {
        guard !outcome.isFullyErased else { return }
        let generations = outcome.generationsStillCarryingErasedTraits.count
        failure = """
            DB からは消えましたが、消した像を焼き込んだアダプタが \(generations) 世代\
            ディスクに残っています。外すまで、まだ効いている可能性があります
            """
    }
}
