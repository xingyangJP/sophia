import XCTest

@testable import Sophia

// =============================================================================
//  利用者像の永続化を、**破ることを目的に**当てる（第14章 / FR-24〜29 / NFR-11・12）
// -----------------------------------------------------------------------------
//  | 印 | 意味 |
//  |---|---|
//  | `XCTExpectFailure` を含む | **いま実際に破れている。** 直すと「失敗しなかった」で落ちるので、直した人が必ず気づく |
//  | 印が無いもの | **破ろうとして破れなかった** ＝ 防御が効いていることの確認 |
//
//  # `UserTraitsStoreTests`（53件）との住み分け
//
//  あちらは「設計どおりに動くか」を固定している。**こちらは設計の隙間を突く。**
//  重複を避けるため、あちらが見ているもの（CHECK 制約の一致・訂正で消えないこと・
//  世代の巻き戻し・関門の出所別の既定・件数の上限が無いこと）は書いていない。
//
//  こちらが狙っているのは4つである。
//
//  | | 狙い |
//  |---|---|
//  | 1 | **導出値（`placement` / `adapter_gen`）を、手で壊せないか** |
//  | 2 | **アダプタが2種類ある**ことを、導出の側が見落としていないか |
//  | 3 | **確信度の関門**を、境界・NaN・空文字ですり抜けられないか |
//  | 4 | **「消せる」と「消えない」**が、貯める側の入口で既に破れていないか |
//
//  # 何を確かめられないか（**誤魔化さない**）
//
//  1. **重みそのものには触れていない。** この層は DB だけを見ており、
//     「アダプタのファイルに何が焼かれているか」は**この層からは永久に分からない**
//     （`TraitErasureOutcome` が名指しできるのは記録であって中身ではない）。
//  2. **並行実行は見ていない。** `Store` は `DatabaseQueue` 1本なので書き込みは
//     直列化されるが、**2つのウインドウから同時に操作する経路**は測っていない。
//  3. **学習データの生成は別担当**である。ここで通した文字列が
//     実際に学習ファイルへどう書き出されるかは見ていない。
// =============================================================================

final class AdversarialTraitsStoreTests: StoreTestCase {

    /// 検索で見つけやすい印。**利用者の文そのもののつもりで扱う。**
    private static let needle = "非力なマシンは制約ではなく手段である"

    @discardableResult
    private func makeTrait(
        in store: Store,
        statement: String = needle,
        kind: TraitKind = .style,
        category: String = "machine",
        source: TraitSource = .onboarding,
        confidence: Double? = nil
    ) async throws -> UserTraitRecord {
        try await store.recordTrait(
            kind: kind, category: category, statement: statement,
            source: source, confidence: confidence,
            now: Date(timeIntervalSince1970: 1_000))
    }

    // =========================================================================
    //  1. 導出値を手で壊せないか（`placement` / `adapter_gen`）
    // -------------------------------------------------------------------------
    //  `setTraitPlacement` は `translating` を**書く**ことを禁じている。
    //  ところが `translating` を**消す**ことは禁じていない ──
    //  焼き込み済みの像を手で `stored` へ落とせる。
    //
    //  実装の但し書きはこう言っている:
    //
    //  > `translating` は焼いた事実からの導出値であり、手で書くと
    //  > 14.15節の「いま重みに入っている像の一覧」が嘘になる。
    //
    //  **嘘になるのは、書いたときだけではない。**
    // =========================================================================

    /// **焼き込み済みの像を、手で `stored` へ落とせる。**
    ///
    /// 落としたあと、DB は2つの矛盾したことを同時に言う ──
    ///
    /// | 訊き方 | 答え |
    /// |---|---|
    /// | `statementsInActiveAdapter()` | **重みに入っている**（焼き込み記録が根拠） |
    /// | `trait.placement` | **貯めているだけ**（手で書いた値） |
    /// | `trait.adapterGen` | **1**（＝反映済みを指したまま） |
    ///
    /// 嘘をつく向きが最悪である ── 14.15節の画面は
    /// **「消したはずの像がまだ効いている」のを見逃す側**へ倒れる。
    func testABakedTraitCanBeDemotedByHandUntilTheDatabaseContradictsItself() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeTrait(in: store)
        try await store.recordAdapterGeneration(
            modelID: "mlx-community/Qwen3-0.6B-4bit",
            directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true)

        // 前提: いま本当に重みに入っている。
        let baked = try await store.trait(id: trait.id)
        XCTAssertEqual(baked?.placement, .translating, "前提が崩れている: 焼いても translating になっていない")

        // **手で落とす。** `translating` を書いていないので、guard は通る。
        try await store.setTraitPlacement(id: trait.id, to: .stored)

        let after = try await store.trait(id: trait.id)
        let inWeights = try await store.statementsInActiveAdapter()

        // 焼き込み記録は変わらない ── **こちらが事実である。**
        XCTAssertEqual(
            inWeights.map(\.trait.id), [trait.id],
            "前提が崩れている: 焼き込み記録まで消えている")
        XCTAssertEqual(
            after?.adapterGen, 1,
            "前提が崩れている: 手で置き場所を書いたら世代まで消えた")

        XCTExpectFailure(
            """
            既知の欠陥: `setTraitPlacement` は `translating` を**書く**ことしか禁じていない。
            焼き込み済みの像を手で `stored` に落とすと、
            `statementsInActiveAdapter`（重みに入っている）と `placement`（貯めているだけ）が
            食い違ったまま残る。禁じるべきは「導出値を手で書くこと」であって、値の向きではない。
            """
        ) {
            XCTAssertEqual(
                after?.placement, .translating,
                """
                重みに入っている像の置き場所が \(after?.placement.rawValue ?? "nil") になっている。
                `adapter_gen` は \(String(describing: after?.adapterGen)) のままである。
                """)
        }
    }

    /// **しかも、次の再計算では直らない。**
    ///
    /// `recalculateTraitPlacements` の `WHERE` は
    /// 「`adapter_gen` が変わる行」か「`translating` なのに焼かれていない行」しか見ない。
    /// 手で落とした行は**どちらでもない**（`adapter_gen` は正しく 1 のまま、
    /// `placement` は `translating` ではない）ので、**素通りする。**
    ///
    /// つまり矛盾は一時的な状態ではなく、**その世代が有効なあいだ残り続ける。**
    func testTheContradictionIsNotRepairedByTheNextRecalculation() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeTrait(in: store)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true)
        try await store.setTraitPlacement(id: trait.id, to: .stored)

        // **再計算を通す。** 焼く経路のどれもが最後にこれを呼ぶ ──
        // ここでは有効な世代を変えない形（`activate: false`）で通す。
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v2", traitIDs: [])

        let after = try await store.trait(id: trait.id)
        let inWeights = try await store.statementsInActiveAdapter()
        XCTAssertEqual(inWeights.count, 1, "前提が崩れている: v1 が有効なままであること")

        XCTExpectFailure(
            """
            既知の欠陥: 導出値の再計算が、手で壊された行を直せない。
            `WHERE adapter_gen IS NOT (…) OR (placement = 'translating' AND NOT EXISTS (…))` の
            どちらにも当たらないため、矛盾した行だけが素通りする。
            """
        ) {
            XCTAssertEqual(
                after?.placement, .translating,
                "再計算を通しても \(after?.placement.rawValue ?? "nil") のままである")
        }
    }

    /// **「次の反映を待っている件数」が、既に反映済みの像を数える。**
    ///
    /// 14.15節はこの数字をそのまま画面に出すと決めている ──
    ///
    /// > 利用者には「◯件が次の反映を待っています」と見せる。
    /// > **待っていることが見えれば、待たされていることに文句を言える。**
    ///
    /// 上の矛盾がそのままこの数字に出る。**待っていない像を待っていると言う。**
    func testTheWaitingCountIncludesATraitThatIsAlreadyInTheWeights() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeTrait(in: store)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true)
        let waitingAfterBaking = try await store.storedTraitCount()
        XCTAssertEqual(waitingAfterBaking, 0, "前提が崩れている: 焼いた直後に待ち件数が残っている")

        try await store.setTraitPlacement(id: trait.id, to: .stored)

        let waiting = try await store.storedTraitCount()
        let inWeights = try await store.statementsInActiveAdapter().count
        XCTAssertEqual(inWeights, 1, "前提が崩れている: 重みには入ったままであること")

        XCTExpectFailure("既知の欠陥: 重みに入っている像が『反映を待っている』件数に数えられる（同じ像が両方に1件ずつ立つ）。") {
            XCTAssertEqual(
                waiting, 0,
                "重みに入っている1件を『待っている』と数えている（待ち \(waiting) / 重み \(inWeights)）")
        }
    }

    /// **存在しない像の置き場所を書いても、成功したように見える。**
    ///
    /// 同じ「存在しない像への操作」でも、`reviseTrait` と `reinforceTrait` は
    /// `StoreFailure.traitNotFound` を投げる（`UserTraitsStoreTests` が固定している）。
    /// `setTraitPlacement` だけが黙って成功する ── UPDATE が0行に当たっただけである。
    ///
    /// FR-28 の設定画面は**別の窓で消された像**に対してこれを呼びうる。
    /// 「消えているので何も起きなかった」を「変えました」と見せることになる。
    func testSettingThePlacementOfATraitThatIsNotThereReportsSuccess() async throws {
        let store = try makeInMemoryStore()

        // **先に結果だけ取る。** `XCTExpectFailure` のブロックは同期なので、
        // 中で `await` はできない（表明だけをブロックへ入れる）。
        var refused = false
        do {
            try await store.setTraitPlacement(id: "居ない像", to: .retrieved)
        } catch {
            refused = true
        }

        XCTExpectFailure(
            "既知の欠陥: 存在しない id への `setTraitPlacement` が成功する（`reviseTrait` / `reinforceTrait` は `traitNotFound` を投げる）。"
        ) {
            XCTAssertTrue(refused, "存在しない像の置き場所を書けてしまっている（UPDATE が0行に当たっただけ）")
        }

        // **消す側も同じ形をしている**（こちらは印を付けていない ──
        // 「0件消えた」は答えとして成立しており、戻り値で見分けがつく）。
        let outcome = try await store.deleteTrait(id: "居ない像")
        XCTAssertEqual(outcome.deletedTraitCount, 0)
        XCTAssertTrue(outcome.isFullyErased, "何も消していないのに『まだ重みに残っている』と言っている")
    }

    // =========================================================================
    //  2. アダプタは2種類ある（`translator` / `base`）
    // -------------------------------------------------------------------------
    //  14.13a節が「8B 本体でも LoRA が回る」ことを実測しており、
    //  `AdapterKind` には最初から `base` がある。**導出の側がそれを見ていない。**
    //
    //  `recalculateTraitPlacements` の2本の副問い合わせには
    //  **`g.adapter = ?` が無い。** アダプタを問わず「有効な世代に焼かれているか」だけを見る。
    // =========================================================================

    /// **本体アダプタにしか入っていない像が、`translating`（＝翻訳役の重みに入った）になる。**
    ///
    /// `TraitPlacement.translating` の綴りは
    /// 「`'translating'`（翻訳役の重みに入った）」と型に書いてある。
    /// 翻訳役の世代は1つも無いのに、この像はそう名乗る ──
    /// しかも `statementsInActiveAdapter(.translator)`（アダプタで絞っている側）は**空**なので、
    /// 14.15節の画面は「翻訳役には何も入っていない。でも待っている像は0件」と言うことになる。
    func testATraitBakedOnlyIntoTheBaseAdapterClaimsToBeInTheTranslator() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeTrait(in: store)

        try await store.recordAdapterGeneration(
            adapter: .base, modelID: "mlx-community/Qwen3-8B-4bit",
            directory: "adapters/base/v1", traitIDs: [trait.id], activate: true)

        let after = try await store.trait(id: trait.id)
        let inTranslator = try await store.statementsInActiveAdapter(.translator)
        XCTAssertTrue(
            inTranslator.isEmpty, "前提が崩れている: 翻訳役には1件も焼いていない")

        XCTExpectFailure(
            """
            既知の欠陥: `recalculateTraitPlacements` の副問い合わせに `g.adapter` の条件が無い。
            本体アダプタに焼いただけの像が `translating`（翻訳役の重みに入った）になり、
            アダプタで絞っている `statementsInActiveAdapter(.translator)` と食い違う。
            """
        ) {
            XCTAssertNotEqual(
                after?.placement, .translating,
                "翻訳役には入っていない像が translating を名乗っている")
        }
    }

    /// **世代番号が、もう一方のアダプタの番号に化ける。**
    ///
    /// `adapter_gen` は「どの世代のアダプタに入ったか」を持つ1本の列である。
    /// 再計算は**アダプタを問わず**有効な世代の `MAX(generation)` を入れるので、
    /// 翻訳役 v1 と本体 v7 の両方に入っている像は **7** を指す。
    /// 画面に「翻訳役 v7 に入っています」と出るが、翻訳役に v7 は存在しない。
    func testTheGenerationNumberOfOneAdapterLeaksIntoTheOther() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeTrait(in: store)

        try await store.recordAdapterGeneration(
            adapter: .translator, modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true)
        try await store.recordAdapterGeneration(
            adapter: .base, generation: 7, modelID: "m", directory: "adapters/base/v7",
            traitIDs: [trait.id], activate: true)

        let after = try await store.trait(id: trait.id)
        // 前提: 両方が有効である（別のアダプタなので同時に有効でよい）。
        let activeTranslator = try await store.activeAdapterGeneration(.translator)
        let activeBase = try await store.activeAdapterGeneration(.base)
        XCTAssertEqual(activeTranslator?.generation, 1, "前提が崩れている: 翻訳役 v1 が有効でない")
        XCTAssertEqual(activeBase?.generation, 7, "前提が崩れている: 本体 v7 が有効でない")

        XCTExpectFailure(
            """
            既知の欠陥: `adapter_gen` はアダプタを持たない1本の列で、再計算は
            両アダプタを混ぜた `MAX(generation)` を入れる。翻訳役 v1 の像が v7 を指す。
            列を1本のままにするなら、少なくとも翻訳役だけを見るべきである。
            """
        ) {
            XCTAssertEqual(
                after?.adapterGen, 1,
                "翻訳役 v1 に入っている像が v\(String(describing: after?.adapterGen)) を指している")
        }
    }

    // =========================================================================
    //  3. 関門（確信度）をすり抜けられないか
    // =========================================================================

    /// **NaN の歩幅で強化すると、確信度が黙って最大（1.0）になる。**
    ///
    /// `min(1.0, current.confidence + step)` は Swift では `y < x ? y : x` である。
    /// `y` が NaN なら比較が false になり、**`x`（＝1.0）がそのまま返る。**
    /// 頭打ちのつもりの `min` が、NaN を**最大値へ昇格させる**装置になっている。
    ///
    /// 1.0 は関門（0.7）の上なので、**この像はそのまま学習データに入る。**
    /// しかも `user_trait_revisions` には「確信度 1.0」の版が積まれるため、
    /// NFR-12 で辿っても「なぜ 1.0 なのか」に嘘の答えが残る。
    ///
    /// NaN は手打ちでは来ないが、**歩幅を計算で決めた瞬間に来る**
    /// （0除算・空集合の平均）。`step` は既定値つきの引数であって定数ではない。
    func testReinforcingWithANaNStepSilentlyMaximisesTheConfidence() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeTrait(in: store, source: .onboarding)
        XCTAssertEqual(trait.confidence, TraitSource.onboarding.defaultConfidence)

        let raised = try await store.reinforceTrait(id: trait.id, source: .manual, step: .nan)
        let after = try await store.trait(id: trait.id)
        let ready = try await store.traitsForTraining()

        XCTExpectFailure(
            """
            既知の欠陥: NaN の歩幅が `min(1.0, …)` を素通りして 1.0 になる
            （Swift の `min` は `y < x ? y : x` で、NaN との比較は必ず false）。
            確信度は関門を一撃で越え、履歴にも 1.0 の版が残る。
            NaN は拒むか、`isFinite` を確かめてから足すこと。
            """
        ) {
            XCTAssertNotEqual(
                raised, 1.0,
                """
                NaN の歩幅で確信度が最大になった（戻り値 \(raised) / 保存後 \(after?.confidence ?? -1)）。
                学習データに入った件数: \(ready.count)
                """)
        }
    }

    /// **関門の境界そのものを固定する。**
    ///
    /// 既存の `testTheSwiftGateAndTheSQLGateAgree` は
    /// 「SQL 側と Swift 側が同じ集合を返すこと」しか見ていない ──
    /// **両方が `>` に変わっても、両方が `>=` のままでも、あのテストは緑である。**
    /// 境界がどちら側にあるかは、ここで別に押さえる。
    ///
    /// | 値 | 期待 | なぜ |
    /// |---|---|---|
    /// | 確信度 = 閾値ちょうど | **通る** | 閾値は「以上」（`confidence >= ?`） |
    /// | 期限 = いまちょうど | **落ちる** | 期限は「より後」（`expires_at > ?`）＝ その瞬間に切れる |
    func testTheGateSitsExactlyOnTheThresholdAndTheExpiryIsExclusive() async throws {
        let store = try makeInMemoryStore()
        let now = Date(timeIntervalSince1970: 5_000)
        let threshold = UserTraitDefaults.trainingConfidenceThreshold

        let onTheLine = try await store.recordTrait(
            kind: .style, category: "tone", statement: "閾値ちょうど",
            source: .manual, confidence: threshold)
        let justUnder = try await store.recordTrait(
            kind: .style, category: "tone", statement: "閾値のすぐ下",
            source: .manual, confidence: threshold.nextDown)
        let expiringNow = try await store.recordTrait(
            kind: .content, category: "stack", statement: "いま切れる",
            source: .manual, confidence: 1.0, expiresAt: now)
        let expiringLater = try await store.recordTrait(
            kind: .content, category: "stack", statement: "1ミリ秒あとに切れる",
            source: .manual, confidence: 1.0, expiresAt: now.addingTimeInterval(0.001))

        let ready = try await store.traitsForTraining(now: now).map(\.id)

        XCTAssertTrue(ready.contains(onTheLine.id), "閾値ちょうどが関門で落ちている（以上ではなく超過になっている）")
        XCTAssertFalse(ready.contains(justUnder.id), "閾値より下が通っている")
        XCTAssertFalse(ready.contains(expiringNow.id), "期限が切れた瞬間の像が通っている")
        XCTAssertTrue(ready.contains(expiringLater.id), "まだ切れていない像が落ちている")
    }

    /// **空白しかない文が、貯まり、強化され、学習データに入る。**
    ///
    /// この層に文の検査は1つも無い（`statement TEXT NOT NULL` だけで、空文字は通る）。
    /// 14.14節が言う `statement` は「**言語化された文**」であり、
    /// 空白は言語化の失敗である ── 失敗が関門を越えて重みに入ると、**消せない誤りになる**
    /// （14.11節④で戻せるのは世代であって、1件ではない）。
    ///
    /// > **上流が防いでいるかは【未確認】である。** ここで表明しているのは
    /// > 「**この層は防いでいない**」ことだけで、上流に検査があるなら
    /// > この印を外すのではなく、上流の検査を試験にすること。
    func testAStatementMadeOfNothingButWhitespaceReachesTheTrainingSet() async throws {
        let store = try makeInMemoryStore()

        let blank = try await store.recordTrait(
            kind: .style, category: "tone", statement: "   \n\t  ",
            source: .translationEdit, confidence: 1.0)
        let ready = try await store.traitsForTraining()

        XCTExpectFailure(
            "既知の欠陥: 空白しかない文が貯まり、関門も通る。この層に文の検査が無い（14.14節「言語化された文」）。"
        ) {
            XCTAssertFalse(
                ready.map(\.id).contains(blank.id),
                "空白だけの文が学習データに入っている（\(ready.count)件中）")
        }
    }

    // =========================================================================
    //  4. 文字列は、貯めたとおりに戻るか
    // =========================================================================

    /// **NUL を含む文は、黙って途中で切られて保存される。**
    ///
    /// GRDB は文字列を `sqlite3_bind_text(…, -1, …)` で束縛する ──
    /// **長さを渡していないので、SQLite は最初の NUL までを保存する。**
    ///
    /// 害は3つある。
    ///
    /// 1. **`recordTrait` が返す値と、保存された値が違う。** 呼び出し側は成功したと見る
    /// 2. 学習データを DB から作れば切れた文が入り、返り値から作れば全文が入る ──
    ///    **どちらが重みに入ったのかを、あとから言えなくなる**（NFR-12）
    /// 3. 消したことの確認（下の全表走査）も、切れた文しか探せない
    ///
    /// **拒むか、そのまま保存するかのどちらかであるべきで、黙って変えてはいけない。**
    /// NUL は手では打てないが、モデルの出力・貼り付けたファイル片から来る。
    func testAStatementContainingNULIsSilentlyTruncatedWhenStored() async throws {
        let store = try makeInMemoryStore()
        let statement = "前半\u{0000}後半"

        let returned = try await store.recordTrait(
            kind: .style, category: "tone", statement: statement, source: .manual)
        let stored = try await store.trait(id: returned.id)

        XCTAssertEqual(returned.statement, statement, "前提が崩れている: 戻り値は渡した文そのままである")

        XCTExpectFailure(
            """
            既知の欠陥: NUL 以降が保存されない（GRDB は `sqlite3_bind_text(…, -1, …)` を使う）。
            返ってきた記録と保存された行が食い違う。拒むか、長さを渡して保存すること。
            """
        ) {
            XCTAssertEqual(
                stored?.statement, statement,
                "保存された文が切られている: \(stored?.statement ?? "nil")")
        }
    }

    /// **NUL 以外は、そのまま戻る。**
    ///
    /// 破ろうとして破れなかった側である ── 改行・絵文字・結合文字・
    /// 書記素1個で2万スカラーの文字列を通しても、**1文字も変わらずに戻る。**
    /// 長さの上限が無いことも同時に表明している（第14章は件数の上限を置かないと
    /// 決めているが、**1件の長さについては何も決めていない**）。
    func testEverythingExceptNULSurvivesTheRoundTripUnchanged() async throws {
        let store = try makeInMemoryStore()
        let statements = [
            "",
            "改行を\n含む\r\n文",
            "絵文字 👩🏽‍🚀🇯🇵 と結合文字 é (e+U+0301)",
            "a" + String(repeating: "\u{0301}", count: 20_000),
            String(repeating: "長", count: 50_000),
        ]

        for statement in statements {
            let record = try await store.recordTrait(
                kind: .style, category: "tone", statement: statement, source: .manual)
            let stored = try await store.trait(id: record.id)
            let revisions = try await store.traitRevisions(of: record.id)

            XCTAssertEqual(stored?.statement, statement, "保存で変わっている")
            XCTAssertEqual(revisions.map(\.statement), [statement], "履歴の側で変わっている")
        }
    }

    // =========================================================================
    //  5. 「消せる」（FR-28 / NFR-01）── 消し残しと、消しすぎ
    // =========================================================================

    /// **消したあと、その文がどの表のどの列にも残っていないこと。**
    ///
    /// 既存の試験は3つの表の**件数**を見ている。それでは
    /// **新しい表が増えた日に緑のまま破れる** ── 増える表こそが危ない
    /// （14.16節⑤「消したはずの像で読み続ける」は、記録が1か所残っていれば成立する）。
    ///
    /// ここでは `sqlite_master` から表と列を引いて**全部走査する。**
    /// 表を足した人が何もしなくても、この試験が先に落ちる。
    func testAfterErasureTheStatementIsGoneFromEveryColumnOfEveryTable() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeTrait(in: store, statement: Self.needle)
        try await store.reviseTrait(
            id: trait.id, statement: Self.needle + "（訂正後）", source: .correction)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true)

        // 前提: 消す前は、確かにどこかに在る。
        let before = try await Self.rowsContaining(Self.needle, in: store)
        XCTAssertFalse(before.isEmpty, "前提が崩れている: 消す前から見つからない")

        let outcome = try await store.eraseAllUserTraits()
        XCTAssertEqual(outcome.deletedTraitCount, 1)

        let after = try await Self.rowsContaining(Self.needle, in: store)
        XCTAssertEqual(
            after, [],
            """
            消したはずの文が残っている: \(after.joined(separator: " / "))
            （消す前に在った場所: \(before.joined(separator: " / "))）
            """)
    }

    /// **消しすぎないこと。** 第8章の会話は1行も減らないこと。
    ///
    /// `eraseTraits(matching:)` は述語を**文字列で組み立てて** `DELETE` に埋めている
    /// （`"1 = 1"` / `"id = ?"`）。いまは正しいが、**壊れ方が静かである** ──
    /// 述語を書き間違えても、利用者像の側の試験は全部緑のままになる。
    func testErasingUserTraitsLeavesTheConversationsFromChapterEightAlone() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)
        try await store.appendMessage(
            conversationID: conversationID, role: .user, content: "会話は消えないこと")
        try await makeTrait(in: store)

        try await store.eraseAllUserTraits()

        let messages = try await store.messages(in: conversationID)
        let conversations = try await store.rawInt(sql: "SELECT COUNT(*) FROM conversations")
        XCTAssertEqual(messages.map(\.content), ["会話は消えないこと"], "利用者像を消したら会話まで消えた")
        XCTAssertEqual(conversations, 1, "利用者像を消したら会話まで消えた")
    }

    /// **焼き込みの記録が途中まで残らないこと。**
    ///
    /// `recordAdapterGeneration` は1トランザクションで世代と焼き込みを書く。
    /// 実装の但し書きが避けたいと言っているのは
    /// 「**重みには入っているが、DB は入っていないと言う**」形だが、
    /// その裏返し（**DB は世代があると言うが、中身が1件も無い**）も同じ害である ──
    /// 14.15節の画面に「0件で焼いた世代」が並び、外すべきファイルを取り違える。
    ///
    /// 存在しない像の id を混ぜて、外部キーで落としたときに**世代の行が残らない**ことを見る。
    func testAGenerationThatNamesAMissingTraitLeavesNothingBehind() async throws {
        let store = try makeInMemoryStore()
        let real = try await makeTrait(in: store)

        await assertThrows({
            _ = try await store.recordAdapterGeneration(
                modelID: "m", directory: "adapters/translator/v1",
                traitIDs: [real.id, "居ない像"], activate: true)
        }, "存在しない像を焼き込めてしまっている")

        let generations = try await store.rawInt(sql: "SELECT COUNT(*) FROM adapter_generations")
        let bakes = try await store.rawInt(sql: "SELECT COUNT(*) FROM user_trait_bakes")
        XCTAssertEqual(generations, 0, "落ちたのに世代の行が残っている（中身の無い世代が画面に並ぶ）")
        XCTAssertEqual(bakes, 0, "落ちたのに焼き込みの行が残っている")
        let after = try await store.trait(id: real.id)
        XCTAssertEqual(after?.placement, .stored, "落ちたのに置き場所だけ動いている")
    }

    /// **版番号は飛ばない・戻らない・重ならない。**
    ///
    /// 訂正と強化を交互に混ぜても、`user_trait_revisions.revision` は 1 から連番であること。
    /// ここが崩れると `user_trait_bakes.revision`（焼いた時点の版）が指す先を失い、
    /// **`statementsInActiveAdapter` が「重みの中の文」を返せなくなる**（NFR-12）。
    func testRevisionNumbersStayDenseWhenCorrectionsAndReinforcementsInterleave() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeTrait(in: store)

        for round in 1...5 {
            try await store.reviseTrait(
                id: trait.id, statement: "第\(round)訂正", source: .correction)
            try await store.reinforceTrait(id: trait.id, source: .translationEdit, step: 0.01)
        }

        let revisions = try await store.traitRevisions(of: trait.id)
        XCTAssertEqual(
            revisions.map(\.revision), Array(1...11),
            "版番号が飛んでいる・重なっている: \(revisions.map(\.revision))")
        let latest = try await store.trait(id: trait.id)
        XCTAssertEqual(
            revisions.last?.statement, latest?.statement,
            "最新の版と本体の文が食い違っている")
        XCTAssertEqual(
            revisions.last?.confidence, latest?.confidence,
            "最新の版と本体の確信度が食い違っている")
    }

    /// **焼いたあとに何度訂正しても、根拠は焼いた時点の文のままであること。**
    ///
    /// 既存の試験は訂正1回で見ている。ここは
    /// **訂正 → 元の文へ戻す → また訂正**まで通して、`hasDivergedSinceBaking` が
    /// 「いま重みの中にある文と、いまの文が違うか」を素直に答えることを見る
    /// （版番号ではなく**文**で判定していることの表明でもある）。
    func testTheEvidenceStaysOnTheBakedRevisionThroughARoundTripOfCorrections() async throws {
        let store = try makeInMemoryStore()
        let original = "焼いたときの文"
        let trait = try await makeTrait(in: store, statement: original)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true)

        try await store.reviseTrait(id: trait.id, statement: "訂正1", source: .correction)
        var inWeights = try await store.statementsInActiveAdapter()
        var baked = try XCTUnwrap(inWeights.first)
        XCTAssertEqual(baked.baked.statement, original)
        XCTAssertTrue(baked.hasDivergedSinceBaking)

        // **元の文へ戻す。** 版は進むが、重みの中身とは一致する。
        try await store.reviseTrait(id: trait.id, statement: original, source: .correction)
        inWeights = try await store.statementsInActiveAdapter()
        baked = try XCTUnwrap(inWeights.first)
        XCTAssertEqual(baked.baked.statement, original)
        XCTAssertFalse(
            baked.hasDivergedSinceBaking,
            "文が一致しているのに『ずれている』と言っている（版番号で判定してしまっている）")

        try await store.reviseTrait(id: trait.id, statement: "訂正2", source: .correction)
        inWeights = try await store.statementsInActiveAdapter()
        baked = try XCTUnwrap(inWeights.first)
        XCTAssertEqual(baked.baked.statement, original, "根拠が最新の文に置き換わっている")
        XCTAssertTrue(baked.hasDivergedSinceBaking)
    }

    // MARK: - 道具

    /// その文字列を含む行が在る場所を `表.列` で返す。**表も列も `sqlite_master` から引く。**
    ///
    /// 表を1つ足しただけで走査範囲が広がる ── **列挙を書き写さないための形である。**
    private static func rowsContaining(_ needle: String, in store: Store) async throws -> [String] {
        var found: [String] = []
        for table in try await store.userTableNames() {
            for column in try await store.columnNames(of: table) {
                let count = try await store.rawInt(
                    sql: "SELECT COUNT(*) FROM \"\(table)\" WHERE CAST(\"\(column)\" AS TEXT) LIKE ?",
                    arguments: ["%\(needle)%"]) ?? 0
                if count > 0 { found.append("\(table).\(column)(\(count)件)") }
            }
        }
        return found.sorted()
    }
}
