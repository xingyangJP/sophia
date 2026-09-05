import Foundation
import XCTest

@testable import Sophia

// =============================================================================
//  パーソナライズの初期化（DESIGN.md 14.8節・14.9節 / FR-24・26・28・29）
// -----------------------------------------------------------------------------
//  # ここで守っているのは「訊きすぎないこと」と「捨てないこと」である
//
//  | 何を | なぜ |
//  |---|---|
//  | **二択の2つが、違う `statement` を生む** | **答えが変わっても出力が変わらない質問は無価値**（14.8節） |
//  | **内容を1問も訊いていない**（全部 `.style`） | 「様式を聞く。内容を聞かない」（VISION / 14.8節） |
//  | **通算12問で必ず止まる** | FR-24「質問の回数に上限を持つ」。**訊くこと自体が利用者のエネルギー** |
//  | **飛ばした問も予算を食う** | 費用は答えたときではなく**見せた時点で**発生している |
//  | **1問ごとに確定する** | 途中でやめても消えない。まとめてコミットすると**訊いた時間だけ取って何も残さない** |
//  | **飛ばした問は1件も書かない** | 適当な答えは誤った利用者像になり、**無いより悪い**（14.16節①） |
//  | **`placement` が `stored` のまま** | 14.7節 / FR-29。**毎ターン 0 であることがこの設計の主張そのもの** |
//  | **質問だけでは学習の関門を越えない** | 下の「関門」節を読むこと。**これは仕様であって、直すべき不具合ではない** |
//
//  # 【未確認】SwiftUI のビューそのものは測っていない
//
//  `FolderUITests` の冒頭が書いている限界がそのまま当てはまる。
//  `ViewInspector` 等を入れていないので、ここで確かめているのは
//  **ビューが読む値**（`OnboardingQuestionnaire` と `OnboardingViewModel`）**までである。**
//
//  したがって次の3つは、このファイルでは**1つも捕まらない:**
//
//  1. 二択のカードが**画面に2枚出ているか**（値としては2つある、までしか言えない）
//  2. 「飛ばす」「やめる」のボタンが**押せる場所にあるか**
//  3. 毎ターン `0` の表示が**利用者の目に入る場所にあるか**（FR-29 は
//     14.15節で「既存の統計行」を指定しているが、**そこへ出す作業は未着手である**）
//
//  **「値は正しいが画面に出ていない」は、実機で目視するまで【未確認】である。**
// =============================================================================

final class OnboardingQuestionsTests: StoreTestCase {

    // =========================================================================
    //  1. 例文 ── 14.8節「例文の質がそのまま採取精度になる」
    // =========================================================================

    /// **二択である。** 3択にすると「真ん中」が逃げ道になり、様式が採れない。
    func testEveryQuestionOffersExactlyTwoChoices() {
        for question in OnboardingQuestionnaire.all {
            XCTAssertEqual(
                question.choices.map(\.side), [.a, .b],
                "\(question.category) が二択になっていない（FR-26）"
            )
        }
    }

    /// **答えが変わったとき、出力が変わること**（14.8節 判定基準1）。
    ///
    /// > **2つの答えが同じ出力を生むなら、その質問は無価値である。**
    ///
    /// `statement` が同じなら、どちらを選んでも DB に入る文が同じ ＝
    /// **どちらを選んでも挙動が変わらない。** その質問は捨てなければならない。
    func testTheTwoChoicesNeverProduceTheSameStatement() {
        for question in OnboardingQuestionnaire.all {
            let statements = Set(question.choices.map(\.statement))
            XCTAssertEqual(
                statements.count, 2,
                "\(question.category): 2つの答えが同じ文になる。**この質問は無価値である**（14.8節）"
            )
        }
    }

    /// **回答例そのものも違うこと。** 様式を変えずに文だけ変えた二択は、
    /// 利用者から見て「同じ答えが2つ」であり、選ばせる意味が無い。
    func testTheTwoSamplesAreActuallyDifferentAnswers() {
        for question in OnboardingQuestionnaire.all {
            let samples = Set(question.choices.map(\.sample))
            XCTAssertEqual(samples.count, 2, "\(question.category): 回答例が同じ")
        }
    }

    /// **`statement` は例文の写しではない。**
    ///
    /// 画面に出るのは**成果物の見本**、DB に入るのは**そこから導いた規則**である。
    /// 例文をそのまま保存すると、利用者像が「1回の答えの丸写し」になり、
    /// **別の題材へ効かない**（14.10節「話題まで一緒に学んでしまう危険」の質問版）。
    func testStatementIsARuleNotACopyOfTheSample() {
        for question in OnboardingQuestionnaire.all {
            for choice in question.choices {
                XCTAssertNotEqual(
                    choice.statement, choice.sample,
                    "\(question.category).\(choice.side): 例文をそのまま保存している"
                )
            }
        }
    }

    /// **短いこと**（14.10節 / 14.13b節）。
    ///
    /// 様式1つを毎ターン指示文で言うと **29トークン**（2026-08-19 実測）で、
    /// `armed` の会話で利用者に残るのは **33トークン**（14.0節）である。
    /// **重みへ移すまでの間、長い規則には置き場所が無い。**
    ///
    /// 60字という数字そのものに測定の裏付けは無い【未確認】。
    /// **効いているのは「実測の 29トークン と同じ桁に留めること」のほうである。**
    func testStatementsStayShortEnoughToHaveSomewhereToLive() {
        for question in OnboardingQuestionnaire.all {
            for choice in question.choices {
                XCTAssertLessThanOrEqual(
                    choice.statement.count, 60,
                    "\(question.category).\(choice.side) の文が長すぎる（\(choice.statement.count) 字）"
                )
                XCTAssertFalse(choice.statement.isEmpty)
                XCTAssertFalse(choice.sample.isEmpty)
                XCTAssertFalse(question.prompt.isEmpty)
                XCTAssertFalse(question.axis.isEmpty)
            }
        }
    }

    /// **1つの軸に1問しかない。** 同じ軸を二度訊くのは利用者のエネルギーの純損である。
    func testEachAxisIsAskedAtMostOnce() {
        let categories = OnboardingQuestionnaire.all.map(\.category)
        XCTAssertEqual(Set(categories).count, categories.count, "category が重複している")
    }

    // =========================================================================
    //  2. 木 ── 14.9節「質問セットは一覧ではなく木として設計する」
    // =========================================================================

    /// **1問目は、誤りのカテゴリをまるごと消した1件である**（14.8節）。
    ///
    /// > | 「非力なマシンは制約ではなく手段である」 | 開発機の強化・買い替えの提案すべて |
    ///
    /// 仕事上の判断で情報利得が高いので、1問目はこれである。
    func testTheRootQuestionIsTheOneThatKilledAWholeCategoryOfErrors() throws {
        XCTAssertEqual(OnboardingQuestionnaire.rootCategory, "machine")

        let root = try XCTUnwrap(OnboardingQuestionnaire.first(answered: []))
        XCTAssertEqual(root.category, "machine")

        let statements = root.choices.map(\.statement).joined()
        XCTAssertTrue(
            statements.contains("非力なマシンは制約ではなく手段である"),
            "14.8節が名指ししている事実が、根の質問から消えている"
        )
    }

    /// **枝が実在すること。** これが木にする唯一の理由である ──
    /// 1問目の答えで2問目が変わらないなら、一覧で足りる。
    func testTheSecondQuestionDependsOnTheFirstAnswer() throws {
        let root = try XCTUnwrap(OnboardingQuestionnaire.question("machine"))

        let afterA = OnboardingQuestionnaire.next(after: root, choosing: .a, answered: ["machine"])
        let afterB = OnboardingQuestionnaire.next(after: root, choosing: .b, answered: ["machine"])

        XCTAssertEqual(afterA?.category, "verification")
        XCTAssertEqual(afterB?.category, "certainty")
        XCTAssertNotEqual(
            afterA?.category, afterB?.category,
            "**答えによって次が変わっていない。** 木にする意味が無い（14.9節）"
        )
    }

    /// 粒度の答えでも枝が変わる。
    ///
    /// 短く返す人には**反論の時機**を、長く返す人には**コードの出し方**を訊く
    /// ── どちらも、その答えからは予測できない軸である
    /// （14.9節「答えが予測できるものは利得が低い」）。
    func testTheGranularityAnswerChangesWhatIsAskedNext() throws {
        let granularity = try XCTUnwrap(OnboardingQuestionnaire.question("granularity"))
        let answered: Set<String> = ["machine", "certainty", "granularity"]

        XCTAssertEqual(
            OnboardingQuestionnaire.next(after: granularity, choosing: .a, answered: answered)?
                .category,
            "pushback"
        )
        XCTAssertEqual(
            OnboardingQuestionnaire.next(after: granularity, choosing: .b, answered: answered)?
                .category,
            "code"
        )
    }

    /// **孤児が無い。** 例文を書いたのに、どの経路からも出ない質問は
    /// 「作ったが動かない」ものであり、今日の教訓に真正面から当たる。
    func testEveryQuestionIsReachableFromTheRoot() throws {
        var seen: Set<String> = [OnboardingQuestionnaire.rootCategory]
        var frontier = [OnboardingQuestionnaire.rootCategory]

        while let category = frontier.popLast() {
            guard let question = OnboardingQuestionnaire.question(category) else { continue }
            for side in OnboardingChoice.Side.allCases {
                guard let next = question.next[side], !seen.contains(next) else { continue }
                seen.insert(next)
                frontier.append(next)
            }
        }

        XCTAssertEqual(
            seen, Set(OnboardingQuestionnaire.all.map(\.category)),
            "根から到達できない質問がある（書いたが出ない）"
        )
    }

    /// 仕事の設定だけで終わらず、一人の認知・感情・関係・価値判断まで通る。
    func testEveryAdaptivePathIncludesTheDeepPersonalAxes() throws {
        let required: Set<String> = [
            "attunement", "challenge", "conflict", "values",
            "setback", "archetypes", "completion",
        ]

        func paths(from category: String, visited: Set<String>) -> [Set<String>] {
            guard let question = OnboardingQuestionnaire.question(category),
                  !visited.contains(category) else { return [visited] }
            let nextVisited = visited.union([category])
            let branches = Set(OnboardingChoice.Side.allCases.compactMap { question.next[$0] })
            guard !branches.isEmpty else { return [nextVisited] }
            return branches.flatMap { paths(from: $0, visited: nextVisited) }
        }

        let allPaths = paths(from: OnboardingQuestionnaire.rootCategory, visited: [])
        XCTAssertFalse(allPaths.isEmpty)
        for path in allPaths {
            XCTAssertTrue(required.isSubset(of: path), "深く知るための軸が経路から欠けている: \(path)")
            XCTAssertEqual(path.count, OnboardingBudget.hardQuestionLimit)
        }
    }

    /// **どの経路も上限の中で終わる。**
    ///
    /// 経路が上限より長いと、**木の末尾は一度も出ない** ──
    /// それは「上限が効いている」ではなく「書いた例文が死んでいる」である。
    func testNoPathThroughTheTreeIsLongerThanTheBudget() throws {
        func depth(from category: String, visited: Set<String>) -> Int {
            guard let question = OnboardingQuestionnaire.question(category),
                  !visited.contains(category) else { return 0 }
            let next = visited.union([category])
            let branches = OnboardingChoice.Side.allCases.compactMap { question.next[$0] }
            guard !branches.isEmpty else { return 1 }
            return 1 + (branches.map { depth(from: $0, visited: next) }.max() ?? 0)
        }

        XCTAssertEqual(
            depth(from: OnboardingQuestionnaire.rootCategory, visited: []),
            OnboardingBudget.hardQuestionLimit,
            "木の最長経路と上限が食い違っている（\(OnboardingBudget.hardQuestionLimit) 問）"
        )
    }

    /// **答え済みの軸は二度と出ない。**
    func testAlreadyAnsweredAxesAreNeverOfferedAgain() throws {
        let answered: Set<String> = ["machine", "certainty"]

        let first = try XCTUnwrap(OnboardingQuestionnaire.first(answered: answered))
        XCTAssertFalse(answered.contains(first.category))

        let root = try XCTUnwrap(OnboardingQuestionnaire.question("machine"))
        let next = OnboardingQuestionnaire.next(after: root, choosing: .b, answered: answered)
        XCTAssertNotEqual(next?.category, "certainty", "答え済みの軸をもう一度出している")
    }

    /// 中断後も、根の回答から選ばれなかった兄弟枝へ迷い込まない。
    @MainActor
    func testReopeningContinuesAlongThePreviouslySelectedBranch() async throws {
        let store = try makeInMemoryStore()
        let first = OnboardingViewModel(store: store)

        await first.start()
        await first.choose(.b) // machine -> certainty
        await first.choose(.a) // certainty -> granularity
        first.stop()

        let reopened = OnboardingViewModel(store: store)
        await reopened.start()

        XCTAssertEqual(reopened.current?.category, "granularity")
        XCTAssertNotEqual(reopened.current?.category, "verification")
    }

    /// 全部答えていれば、出す質問は無い。
    func testNothingIsOfferedOnceEveryAxisIsAnswered() {
        let all = Set(OnboardingQuestionnaire.all.map(\.category))
        XCTAssertNil(OnboardingQuestionnaire.first(answered: all))
    }

    // =========================================================================
    //  3. 予算 ── 14.9節「質問にも予算を置く」/ FR-24
    // =========================================================================

    /// **初回の適応経路は12問で止まる。**
    /// いつでも中断できるため、12問は強制数ではなく一度に進められる上限である。
    @MainActor
    func testTheFirstRunStopsAfterTwelveQuestions() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()

        var asked = 0
        while model.current != nil {
            await model.choose(.a)
            asked += 1
            XCTAssertLessThanOrEqual(asked, 20, "止まらない（無限に訊いている）")
        }

        XCTAssertEqual(asked, OnboardingBudget.initialQuestionLimit)
        XCTAssertTrue(model.isFinished)
        let traits = try await store.allTraits()
        XCTAssertEqual(traits.count, OnboardingBudget.initialQuestionLimit)
    }

    /// **通算で12問。** 続けても、閉じて開き直しても、そこで尽きる。
    ///
    /// 回ごとの上限にすると、**閉じて開き直すだけで何度でも訊ける**形になり、
    /// 予算表が空文になる。通算は DB にある軸の数で数えている。
    @MainActor
    func testContinuingIsCappedByTheTotalBudgetNotPerRun() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        while model.current != nil { await model.choose(.a) }

        await model.continueAsking()
        while model.current != nil { await model.choose(.a) }

        // ここで打ち止め。**さらに続けようとしても1問も出ない。**
        await model.continueAsking()
        XCTAssertNil(model.current)
        XCTAssertTrue(model.isFinished)

        let traits = try await store.allTraits()
        XCTAssertEqual(
            traits.count, OnboardingBudget.hardQuestionLimit,
            "通算の上限（\(OnboardingBudget.hardQuestionLimit) 問）を越えて訊いている（FR-24）"
        )

        // 新しい画面を作っても（＝アプリを開き直しても）増えない。
        let reopened = OnboardingViewModel(store: store)
        await reopened.start()
        XCTAssertNil(reopened.current, "開き直すと予算が復活している")
    }

    /// **飛ばした問も予算を食う。**
    ///
    /// > **訊くこと自体が利用者のエネルギーである**（14.9節）
    ///
    /// 費用は答えたときではなく**見せた時点で**発生している。
    /// 数えないと「飛ばし続ければ何問でも出る」形になる。
    @MainActor
    func testSkippingStillSpendsTheQuestionBudget() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        var shown = 0
        while model.current != nil {
            model.skipCurrentQuestion()
            shown += 1
            XCTAssertLessThanOrEqual(shown, 20, "飛ばし続けると止まらない")
        }

        XCTAssertEqual(shown, OnboardingBudget.initialQuestionLimit)
        XCTAssertTrue(model.isFinished)
    }

    // =========================================================================
    //  4. 保存 ── 14.7節「貯めるが、送らない」/ 14.14節
    // =========================================================================

    /// **1問ごとに確定している。** 途中でやめても、選んだぶんは残る。
    ///
    /// これが FR-24「中断でき、後から再開できる」の実体である。
    /// 最後に「保存」を置く形だと、**訊いた時間だけ取って何も残さない。**
    @MainActor
    func testEachAnswerIsCommittedImmediatelySoQuittingKeepsIt() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        await model.choose(.b)
        let afterFirst = try await store.allTraits()
        XCTAssertEqual(afterFirst.count, 1, "1問目が保存されていない")

        await model.choose(.b)
        model.stop()

        let traits = try await store.allTraits()
        XCTAssertEqual(traits.count, 2, "途中でやめたら答えが消えた")
        XCTAssertTrue(model.isFinished)
        XCTAssertNil(model.current)
    }

    /// **飛ばした問は1件も書かない。**
    ///
    /// 「分からない」を保存する形にしていないのは、
    /// **適当な答えが誤った利用者像になり、無いより悪い**からである（14.16節①）。
    @MainActor
    func testSkippingWritesNothingAtAll() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        model.skipCurrentQuestion()
        model.skipCurrentQuestion()
        model.skipCurrentQuestion()

        let stored = try await store.allTraits()
        XCTAssertTrue(stored.isEmpty, "飛ばした問が保存されている")
        XCTAssertEqual(model.savedInThisRun, 0)
    }

    /// **飛ばした問は、次に開いたときまた出る。** 消えたのではなく、答えなかっただけである。
    @MainActor
    func testASkippedQuestionComesBackNextTime() async throws {
        let store = try makeInMemoryStore()

        let first = OnboardingViewModel(store: store)
        await first.start()
        let skipped = try XCTUnwrap(first.current?.category)
        first.skipCurrentQuestion()

        let second = OnboardingViewModel(store: store)
        await second.start()
        XCTAssertEqual(second.current?.category, skipped, "飛ばした問が二度と出てこない")
    }

    /// **採るのは様式だけ。内容は1問も無い**（VISION / 14.8節）。
    ///
    /// 内容（`.content`）は自己申告で正確に取れるが**陳腐化する**ので、
    /// 初回に集める価値が低い。しかも使っていれば会話に自然に出てくる。
    @MainActor
    func testEveryAnswerIsRecordedAsStyleNeverAsContent() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        while model.current != nil { await model.choose(.b) }

        let traits = try await store.allTraits()
        XCTAssertFalse(traits.isEmpty)
        for trait in traits {
            XCTAssertEqual(trait.kind, .style, "内容（content）を訊いている（14.8節に反する）")
            XCTAssertEqual(trait.source, .onboarding)
            XCTAssertNil(trait.expiresAt, "様式は期限を持たない（14.14節）")
        }
    }

    /// **既定は「貯めるが、送らない」。毎ターンの費用は 0**（14.7節 / FR-29）。
    ///
    /// > **「毎ターン 0」を出すことが、この設計の主張そのものである。**
    /// > 初版のまま作れば、ここには数百という数字が出て、**会話が続く限り出続けた。**
    @MainActor
    func testStoredAnswersAreNotSentAnywhere() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        while model.current != nil { await model.choose(.a) }

        for trait in try await store.allTraits() {
            XCTAssertEqual(trait.placement, .stored, "採った時点で送る先が付いている（14.7節に反する）")
            XCTAssertNil(trait.adapterGen)
        }
        XCTAssertEqual(model.perTurnTokenCost, 0)
        XCTAssertEqual(model.storedCount, OnboardingBudget.initialQuestionLimit)
    }

    // =========================================================================
    //  5. 関門 ── 14.14節「確信度は飾りではない。重みへ移す関門である」
    // =========================================================================

    /// **質問に1度答えただけでは、学習データに入らない。**
    ///
    /// ## これは不具合ではない。**そう決まっている**
    ///
    /// `TraitSource.onboarding.defaultConfidence` は **0.5**、
    /// 関門（`UserTraitDefaults.trainingConfidenceThreshold`）は **0.7** である。
    /// どちらも `Sources/Store/` が持っており、**この作業では1つも変えていない。**
    ///
    /// 14.8節が理由を先に書いている ──
    ///
    /// > **暗黙知は質問では取れない。**
    /// > **質問は、ログが貯まるまでを快適にするためのものである。**
    ///
    /// ## ⚠ ただし 14.13b節の書き方とは緊張がある【要確認・設計担当へ】
    ///
    /// 14.13b節は「**質問だけでパーソナライズする設計は成立する**」と書いているが、
    /// あれは**件数**（20件で立ち上がる）の話であって、**確信度の関門**の話ではない。
    /// **関門をそのまま適用すると、質問由来の像は1件も学習に入らない。**
    /// 数字を発明して回避しないこと ── **どちらを動かすかは測ってから決める。**
    @MainActor
    func testAnsweringQuestionsDoesNotByItselfCrossTheTrainingGate() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        while model.current != nil { await model.choose(.b) }

        let traits = try await store.allTraits()
        let trainable = try await store.traitsForTraining()
        XCTAssertFalse(traits.isEmpty)
        XCTAssertEqual(
            trainable.count, 0,
            "質問に1度答えただけで関門を通っている。**確信度の既定値が動かされていないか確認すること**"
        )
        XCTAssertEqual(model.trainingReadyCount, 0)
    }

    /// **同じ答えが二度目なら、確信度が上がる**（14.14節「様式は追記して確信度を上げる」）。
    ///
    /// これが関門へ届く唯一の入口である。**0.5 → 0.6 → 0.7。**
    /// 二度目・三度目の顕示選好であって、数字を1つも発明していない。
    @MainActor
    func testConfirmingTheSameAnswerTwiceReachesTheGate() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        let category = try XCTUnwrap(model.current?.category)
        await model.choose(.b)

        let recorded = try await store.allTraits()
        let initial = try XCTUnwrap(recorded.first { $0.category == category })
        XCTAssertFalse(initial.qualifiesForTraining())

        await model.startReview(category: category)
        await model.choose(.b)
        await model.startReview(category: category)
        await model.choose(.b)

        let afterReview = try await store.allTraits()
        let reinforced = try XCTUnwrap(afterReview.first { $0.category == category })
        XCTAssertEqual(reinforced.statement, initial.statement, "文が書き換わっている（強化ではない）")
        XCTAssertTrue(
            reinforced.qualifiesForTraining(),
            "二度の裏づけでも関門に届かない（確信度 \(reinforced.confidence)）"
        )

        // **像は増えない。** 同じ軸を強化しただけである。
        XCTAssertEqual(afterReview.filter { $0.category == category }.count, 1)
    }

    /// **再確認は通算の問数を消費しない。** 新しい軸を1つも増やさないからである。
    @MainActor
    func testReviewDoesNotSpendTheQuestionBudget() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        await model.choose(.a)
        model.stop()
        let answeredBefore = model.answeredQuestionCount

        let saved = try await store.allTraits()
        let category = try XCTUnwrap(saved.first?.category)
        await model.startReview(category: category)
        await model.choose(.a)

        XCTAssertEqual(model.answeredQuestionCount, answeredBefore)

        // 予算は減っていないので、残りの軸はまだ訊ける。
        await model.continueAsking()
        XCTAssertNotNil(model.current, "再確認しただけで、残りの質問が出なくなっている")
    }

    /// **選び直したら書き換わる。ただし前の文は残る**（第8.4節 / NFR-12）。
    @MainActor
    func testChangingTheAnswerRevisesButKeepsTheOldWording() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        let category = try XCTUnwrap(model.current?.category)
        let question = try XCTUnwrap(OnboardingQuestionnaire.question(category))
        await model.choose(.a)

        await model.startReview(category: category)
        await model.choose(.b)

        let revised = try await store.allTraits()
        let trait = try XCTUnwrap(revised.first { $0.category == category })
        XCTAssertEqual(trait.statement, question.choice(.b)?.statement)
        XCTAssertEqual(trait.source, .correction, "二択の選び直しは顕示選好であって手書きではない")

        let history = try await store.traitRevisions(of: trait.id)
        XCTAssertEqual(
            history.map(\.statement),
            [question.choice(.a)?.statement, question.choice(.b)?.statement].compactMap { $0 },
            "**前の答えが消えている。** 何を根拠にしたか辿れない（NFR-12）"
        )
    }

    // =========================================================================
    //  6. あとから見る・直す・消す（FR-28）
    // =========================================================================

    /// **書き直せる。** 例文は7通りしか無く、その人の様式がどれとも違うことは普通にある
    /// （14.16節⑫「選択肢の例文の質」）。**書き直せることが唯一の逃げ道である。**
    @MainActor
    func testEditingKeepsTheOriginalWordingInHistory() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        await model.choose(.b)
        let original = try XCTUnwrap(model.traits.first)

        await model.edit(original, to: "  結論だけ。前置きも謝罪も要らない  ")

        let fetched = try await store.trait(id: original.id)
        let updated = try XCTUnwrap(fetched)
        XCTAssertEqual(updated.statement, "結論だけ。前置きも謝罪も要らない", "前後の空白が落ちていない")
        XCTAssertEqual(updated.source, .manual)

        let history = try await store.traitRevisions(of: original.id)
        XCTAssertEqual(history.first?.statement, original.statement, "元の文が履歴から消えている")
        XCTAssertEqual(history.count, 2)
    }

    /// 空文字や無変更では書き換えない。**空の像は像ではない。**
    @MainActor
    func testEditingRejectsEmptyAndUnchangedText() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        await model.choose(.a)
        let trait = try XCTUnwrap(model.traits.first)

        await model.edit(trait, to: "   ")
        await model.edit(trait, to: trait.statement)

        let history = try await store.traitRevisions(of: trait.id)
        let unchanged = try await store.trait(id: trait.id)
        XCTAssertEqual(history.count, 1, "無意味な版が積まれた")
        XCTAssertEqual(unchanged?.statement, trait.statement)
    }

    /// **消したものは完全に消える**（FR-28 / NFR-01）。履歴ごと消える。
    @MainActor
    func testDeletingRemovesTheTraitAndItsHistory() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        await model.choose(.a)
        await model.choose(.a)
        let victim = try XCTUnwrap(model.traits.first)

        await model.delete(victim)

        let gone = try await store.trait(id: victim.id)
        let history = try await store.traitRevisions(of: victim.id)
        XCTAssertNil(gone)
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(model.traits.count, 1, "画面の一覧が古いまま")
        XCTAssertNil(model.failure, "焼く経路が無いのに「まだ効いている」と言っている")
    }

    @MainActor
    func testEraseAllEmptiesEverything() async throws {
        let store = try makeInMemoryStore()
        let model = OnboardingViewModel(store: store)

        await model.start()
        while model.current != nil { await model.choose(.b) }

        await model.eraseAll()

        let remaining = try await store.allTraits()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(model.traits.isEmpty)
        XCTAssertEqual(model.storedCount, 0)

        // **消したあとは、また訊ける。** 予算は「いま覚えている軸の数」で数えているため。
        await model.start()
        XCTAssertNotNil(model.current)
    }

    // =========================================================================
    //  7. 縮退（NFR-11）── 保存先が無くても壊れない
    // =========================================================================

    /// **保存できないなら訊かない。**
    ///
    /// 答えさせて捨てるのは、利用者のエネルギーを取るだけで何も返さない ──
    /// この機能で最も避けたい形である。
    /// **画面は開く。開いたうえで「記録できない」とだけ言う。**
    @MainActor
    func testWithoutAStoreItRefusesToAskRatherThanThrowingAnswersAway() async {
        let model = OnboardingViewModel(store: nil)

        await model.start()

        XCTAssertNil(model.current, "保存できないのに質問を出している")
        XCTAssertTrue(model.isFinished)
        XCTAssertNotNil(model.failure, "保存できないことが利用者に伝わらない")
        XCTAssertTrue(model.traits.isEmpty)
        XCTAssertEqual(model.perTurnTokenCost, 0)
    }
}
