import Foundation
import MLXLMCommon
import XCTest

@testable import Sophia

// =============================================================================
//  二段目の縮約を、**破ることを目的に**当てる（FR-19 / DESIGN.md 第16.3節）
// -----------------------------------------------------------------------------
//  **このファイルは1バイトもモデルを読み込まない。**
//
//  | 印 | 意味 |
//  |---|---|
//  | `XCTExpectFailure` を含む | **いま実際に破れている。** 直すと「失敗しなかった」で落ちるので、直した人が必ず気づく |
//  | `options:` に非厳格を渡してあるもの | **破れているはずだが、実測の余裕が小さい。** 直っていても落ちない（本文にその旨を書いてある） |
//  | 印が無いもの | **破ろうとして破れなかった** ＝ 防御が効いていることの確認 |
//
//  # `TranscriptCompactionTests`（12件）との住み分け
//
//  あちらは「規則どおりに動くか」を固定している。**こちらは規則そのものを疑う。**
//  重複を避けるため、あちらが既に見ているもの（落とす順・栞の文言・`role=tool` の維持・
//  失敗の文を落とさないこと・空のターン・`perMessageOverhead` の口）は書いていない。
//
//  こちらが足しているのは4つである。
//
//  | | あちらが見ていないもの |
//  |---|---|
//  | 1 | **落として得になるか**を、誰も見ていない（`fitRoundTrip` にも `demotable` にも検査が無い） |
//  | 2 | **同じ周で呼ばれた複数の結果**（`<tool_call>` が1周に2つ以上あるとき） |
//  | 3 | **落とし切ったあと、本当に予算に収まっているか**（あちらは `fits` を1度も見ていない） |
//  | 4 | ターンをまたぐ側（`ContextTranscript.fit`）と往復の側で、**判断が割れていないか** |
//
//  # 何を確かめられないか（**誤魔化さない**）
//
//  1. **`performChat` の `rounds:` ループは走らせていない**（`ModelContainer` が要る）。
//     叩いているのはループが呼ぶ当の関数（`MLXEngine.compacted` /
//     `transcriptEntry(for:)`）だが、**ループがそれを呼んでいること**は実装を読むしかない。
//  2. **数え方は概算である。** ここで「収まった／収まらない」と言っているのは
//     すべて概算での話で、実トークナイザでの値ではない。
//     3章はその差そのものを表明の対象にしている。
// =============================================================================

final class AdversarialCompactionTests: XCTestCase {

    private typealias Budget = SophiaDefaults.InputBudget

    /// 実ファイルを置く場所。**本物の実行役に読ませる試験（1章・3章）が使う。**
    private var base: URL!
    private var root: URL!
    private var folder: SecurityScopedFolder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let manager = FileManager.default
        base = manager.temporaryDirectory
            .appendingPathComponent("SophiaAdvCompaction-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("docs", isDirectory: true)
        try manager.createDirectory(
            at: root.appendingPathComponent("log", isDirectory: true),
            withIntermediateDirectories: true)

        // 1件で読み取りの上限（`InputBudget.singleRead` = 360）を埋めきる大きさにする。
        // 400行 × 約31文字の ASCII ＝ 概算で 3,000トークン相当あり、
        // 行数上限（200）でもトークン上限でも必ず切られる。
        for index in 1...6 {
            let text = (["NEEDLE-\(index)"]
                + (2...400).map { "line \($0): padding padding padding" })
                .joined(separator: "\n") + "\n"
            try Data(text.utf8).write(
                to: root.appendingPathComponent("log/\(index).log"))
        }
        // **空のファイル。** 1章が使う ── これは架空の入力ではない
        // （`touch` したもの、置いただけの `__init__.py`、まだ何も書かれていないログ）。
        for index in 1...3 {
            try Data().write(to: root.appendingPathComponent("empty-\(index).md"))
        }

        folder = try SecurityScopedFolder.unscoped(directoryURL: root)
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
        try super.tearDownWithError()
    }

    // =========================================================================
    //  1. **落として、得になっているか** ── 誰も見ていない
    // -------------------------------------------------------------------------
    //  縮約の目的は費用を下げることである。ところが実装のどこにも
    //  「落とした姿のほうが安いか」を見る行が無い ──
    //  `RoundTripItem.demotable(raw:bookmark:)` は無条件に2つ目の姿を作り、
    //  `fitRoundTrip` は上限を超えていれば無条件に落とす。
    //
    //  **空のファイルを読むと、これが逆に働く。**
    // =========================================================================

    /// **空のファイルの読み取りは、落とすと高くつく。**
    ///
    /// | | 文字列 | 文字数 | 概算 |
    /// |---|---|--:|--:|
    /// | 生 | `[ファイル placeholder.md / 空のファイル（0行 / 0バイト）]` | 41 | **19** |
    /// | 栞＋断り書き | `読んだ: placeholder.md（空のファイル）` ＋ 断り書き | 43 | **24** |
    ///
    /// 差は路の長さによらない ── パスは両方に1度ずつ出るので、
    /// **どんな名前でも「落とすと 2文字ぶん増える」形になっている。**
    ///
    /// **数字は写していない。** 下は実物どうしを比べている ──
    /// `ContextWindow.clip("")` → `ToolResult.content` → `executionOutcome` と、
    /// 実行役が空のファイルを読んだときに通るのと同じ道で作った値である。
    ///
    /// 空のファイルは珍しくない（`touch` したもの、置いただけの `__init__.py`、
    /// 書き出す前のログ）。**モデルは中身が空だと知るために一度読む。**
    func testDemotingTheReadOfAnEmptyFileCostsMoreThanKeepingItsContent() throws {
        let outcome = Self.read(path: "placeholder.md", contents: "")
        let item = ContextTranscript.RoundTripItem.demotable(
            raw: outcome.responseText, bookmark: outcome.summaryLine)
        let demoted = try XCTUnwrap(item.demotedText)
        let counter = TokenCounter.estimate

        // **前提: これは空のファイルを読んだ結果である。**
        // 崩れていたら、この試験は別のものを測っている。
        XCTAssertTrue(
            outcome.responseText.contains("空のファイル"),
            "前提が崩れている: 空のファイルの読み取りになっていない（\(outcome.responseText)）")
        XCTAssertFalse(outcome.isFailure, "前提が崩れている: 空のファイルは失敗ではない")

        // **2026-08-19 に直した（印を外した）。**
        // `RoundTripItem.demotable(raw:bookmark:counter:)` が、落とした姿のほうが高い項目では
        // **落とした姿を生の姿へ潰す**（`demotedText == rawText`）。
        XCTAssertLessThanOrEqual(
            counter(demoted), counter(item.rawText),
            """
            落とした姿のほうが高い ── 生 \(counter(item.rawText)) / 落とした後 \(counter(demoted))。
            縮約が費用を増やしている。
            """)
    }

    /// **同じことが、出荷される道でそのまま起きる。**
    ///
    /// 上は文字列1つの比較だが、こちらは**実ファイルを本物の実行役に読ませて**
    /// 往復1ターンぶんを通している ── 縮約を通した結果が、通す前より**高い**。
    /// しかも `demotedReads` は「2件落とした」と申告するので、
    /// `[TOOL] compacted demoted=2` の行だけを見ていると成功したように見える。
    func testCompactingATurnOfEmptyFilesMakesItMoreExpensiveThanNotCompacting() async throws {
        let runner = FolderToolRunner(folder: folder)
        var transcript: [RoundTripMessage] = [.user("この3つは空かどうか見て")]
        for index in 1...3 {
            let outcome = await runner.execute(ModelToolCall(
                name: "read_file",
                argumentsJSON: #"{"path":"empty-\#(index).md"}"#,
                callID: "call-\(index)"))
            // **前提: 実行役が「空のファイル」として読めていること。**
            XCTAssertFalse(outcome.isFailure, "前提が崩れている: 読めていない（\(outcome.responseText)）")
            XCTAssertTrue(
                outcome.responseText.contains("空のファイル"),
                "前提が崩れている: 空のファイルとして読めていない（\(outcome.responseText)）")
            transcript.append(.assistant("", toolCalls: [Self.call(id: outcome.callID)]))
            transcript.append(MLXEngine.transcriptEntry(for: outcome))
        }

        // 上限を外して組んだものが「落とす前」である。
        let before = MLXEngine.compacted(transcript, budget: .max)
        XCTAssertEqual(before.fit.demotedReads, 0, "前提が崩れている: 上限が無いのに落としている")

        let after = MLXEngine.compacted(transcript, budget: 1)
        XCTAssertEqual(
            after.fit.demotedReads, 2, "前提が崩れている: 一番新しい1件を除いて落ちるはずである")

        // **2026-08-19 に直した（印を外した）。**
        // 落とした姿が生と同じになるので、**件数は出るが費用は1トークンも動かない** ──
        // 「増えないこと」がここの表明である（減ったかどうかは `tokens` を見ること）。
        XCTAssertLessThanOrEqual(
            after.fit.tokens, before.fit.tokens,
            """
            縮約が費用を増やしている ── 通す前 \(before.fit.tokens) / 通した後 \(after.fit.tokens)。
            `demotedReads` は \(after.fit.demotedReads) を申告している。
            """)
    }

    // =========================================================================
    //  2. **同じ周で呼ばれた結果** ── 一番新しい「1件」しか守られない
    // -------------------------------------------------------------------------
    //  `fitRoundTrip` が守るのは `demotable.last`（**1件**）である。
    //  ところが `performChat` は1周で複数の呼び出しを実行して並べる
    //  （`for call in calls { transcript.append(...) }`）。
    //  Qwen3 のテンプレートは `<tool_call>` を1周に何個でも描くので、
    //  **モデルが3つ同時に頼んだ周では、次の周の頭で2つが落ちる。**
    //
    //  実装の但し書きは一番新しい1件を残す理由を
    //  「**いま答えさせようとしている材料**だから」と書いている。
    //  同じ周の残り2件も、同じ理由でまだ材料である ── **答えはまだ出ていない。**
    // =========================================================================

    /// **1周で3つ読ませると、モデルが一度も見ないまま2つが栞に落ちる。**
    ///
    /// 落ちるのは「古い往復の材料」ではない。**この周の材料である。**
    /// モデルから見えるのは
    /// `読んだ: a.log（…）` ＋ `（内容は文脈の上限のため省略）` だけで、
    /// 中身は一度も文脈に入らない。
    ///
    /// **もう一度読みに行くこともできない** ── 往復の上限（`callLimit` = 6）は
    /// 呼んだ回数で数えているので、この3回は既に消費済みである。
    func testTheOtherReadsOfTheSameRoundVanishBeforeTheModelEverSawThem() {
        let budget = Budget.transcript(armed: true)
        let a = Self.read(path: "a.log", contents: Self.haystack(needle: "NEEDLE-A"))
        let b = Self.read(path: "b.log", contents: Self.haystack(needle: "NEEDLE-B"))
        let c = Self.read(path: "c.log", contents: Self.haystack(needle: "NEEDLE-C"))

        // **1周で3つ。** assistant の発言は1つで、`tool_calls` が3つ入る。
        let transcript: [RoundTripMessage] = [
            .user("a.log と b.log と c.log を見比べて、NEEDLE がどれにあるか教えて"),
            .assistant("", toolCalls: [a, b, c].map { Self.call(id: $0.callID) }),
            MLXEngine.transcriptEntry(for: a),
            MLXEngine.transcriptEntry(for: b),
            MLXEngine.transcriptEntry(for: c),
        ]

        // **前提を先に測る。** 3件が本当に予算を超えていること。
        // 超えていないなら、この試験は縮約について何も言っていない。
        let raw = MLXEngine.compacted(transcript, budget: .max)
        XCTAssertGreaterThan(
            raw.fit.tokens, budget,
            "前提が崩れている ── 1周3件（\(raw.fit.tokens)）が予算（\(budget)）を超えていない")

        let compacted = MLXEngine.compacted(transcript, budget: budget)
        let joined = compacted.messages.map(Self.text(of:)).joined(separator: "\n")

        XCTAssertTrue(joined.contains("NEEDLE-C"), "前提が崩れている: 一番新しい1件は残るはずである")

        // **2026-08-19 に直した（印を外した）。**
        // 守る単位が「一番新しい1件」から**周**になった
        // （`RoundTripItem.startsRound` → `ContextTranscript.currentRoundIndices`）。
        XCTAssertTrue(
            joined.contains("NEEDLE-A"),
            """
            この周に読んだばかりの a.log の中身が、答える前に消えている
            （落ちた件数: \(compacted.fit.demotedReads)）。
            """)
    }

    // =========================================================================
    //  3. **落とし切ったあと、本当に収まっているのか**
    // -------------------------------------------------------------------------
    //  `TranscriptCompactionTests` の本命（6件読んだターン）は
    //  「5件落ちた」「半分以下になった」を見ているが、**`fits` を一度も見ていない。**
    //  縮約の目的は件数を減らすことではなく**収めること**なので、そこが要点である。
    //
    //  ここでは器を出荷される条件に寄せてある ──
    //  **実ファイル・本物の実行役（`FolderToolRunner`）・本物の予算。**
    // =========================================================================

    /// **実ファイルを6件読んだターンは、落とせるだけ落としても予算に収まらない。**
    ///
    /// 通っているのは `FolderToolRunner.execute` → `transcriptEntry(for:)` →
    /// `compacted` で、`performChat` が通るのと同じ道である（ループ本体だけが無い）。
    ///
    /// > **この印は非厳格にしてある。** 概算での余裕が数十トークンしかなく、
    /// > 実ファイルの中身や `systemPrompt` の文言が1行変われば向きが変わる。
    /// > **収まるようになったらこの試験は黙って通る** ── 数字は下の失敗文に出る。
    func testSixRealFileReadsStillOverrunTheBudgetAfterCompaction() async throws {
        let runner = FolderToolRunner(folder: folder)
        let budget = Budget.transcript(armed: true)

        var transcript: [RoundTripMessage] = [
            .system(SophiaDefaults.systemPrompt),
            .user("log の6つを見て、どれに NEEDLE があるか教えて"),
        ]
        for index in 1...runner.callLimit {
            let outcome = await runner.execute(ModelToolCall(
                name: "read_file",
                argumentsJSON: #"{"path":"log/\#(index).log"}"#,
                callID: "call-\(index)"))
            // **前提: 実行役が本当に読めていること。** 読めていなければ失敗の文になり、
            // 失敗の文は落とせない ＝ 縮約について何も測らないまま緑になる。
            XCTAssertFalse(
                outcome.isFailure, "前提が崩れている: 読めていない（\(outcome.responseText)）")
            transcript.append(.assistant("", toolCalls: [Self.call(id: outcome.callID)]))
            transcript.append(MLXEngine.transcriptEntry(for: outcome))
        }

        let compacted = MLXEngine.compacted(transcript, budget: budget)
        XCTAssertEqual(
            compacted.fit.demotedReads, runner.callLimit - 1,
            "前提が崩れている: 一番新しい1件を除いて落ちるはずである")

        XCTExpectFailure(
            """
            既知の欠陥（余裕が小さいため非厳格）: 落とせるものを落とし切っても、
            送信列の取り分に収まらない。栞（1件あたり概算25前後）× 5 と
            自己認識（同97）が、一番新しい読み取り（同360）と同居できない。
            """,
            options: Self.nonStrict
        ) {
            XCTAssertTrue(
                compacted.fit.fits,
                """
                縮約後も予算を超えている ── \(compacted.fit.tokens) / \(compacted.fit.budget)。
                この層はこれ以上減らせないので、超過は `contextLength`（8,192）まで素通りする。
                """)
        }
    }

    /// **「収まった」は、収まったことを意味しない。**
    ///
    /// 数えているのは `TokenCounter.estimate`（文字種別の概算）で、
    /// **発見19 の実測では実トークナイザに対して 1.47倍 甘い**（概算 8,296 / 実測 12,234）。
    /// さらに `compacted` はチャットテンプレートの固定分も `tool_calls` の JSON も
    /// 数えていない（`perMessageOverhead` を渡す口すら開いていない）。**すべて過少側。**
    ///
    /// ここでは**概算では確かに収まっている**ターンを作り、
    /// 同じ数字に実測相当の係数を掛けると収まらないことを見る。
    /// 直す道は分かっている ── `container.prepare` の `lmInput.text.tokens.count` を
    /// `TokenCounter.exact` で包んで挿すこと（第15章の宿題）。
    func testWhatTheCompactionCallsFittingIsUnverifiedByAFactorOfOneAndAHalf() {
        // 発見19 の実測比（PROGRESS.md）。**概算はこれだけ甘い。**
        let measuredEstimateGap = 1.47

        // **2件にしてあるのは、概算がちょうど予算の内側に収まる大きさだからである。**
        // 収まらない量にすると「収まっていないものが収まっていない」を言うだけになる。
        var transcript: [RoundTripMessage] = [
            .system(SophiaDefaults.systemPrompt),
            .user("2つ見て"),
        ]
        for index in 1...2 {
            let outcome = Self.read(
                path: "log/\(index).log", contents: Self.haystack(needle: "NEEDLE-\(index)"))
            transcript.append(.assistant("", toolCalls: [Self.call(id: outcome.callID)]))
            transcript.append(MLXEngine.transcriptEntry(for: outcome))
        }

        let compacted = MLXEngine.compacted(
            transcript, budget: Budget.transcript(armed: true))

        // **前提: 概算では収まっている。** ここが崩れていたら、下は
        // 「収まっていないものが収まっていない」と言っているだけで、何も表明していない。
        XCTAssertTrue(
            compacted.fit.fits,
            "前提が崩れている: 概算でも収まっていない（\(compacted.fit.tokens) / \(compacted.fit.budget)）")
        XCTAssertTrue(compacted.fit.tokensAreEstimated, "前提が崩れている: 概算で数えていない")

        let corrected = Int((Double(compacted.fit.tokens) * measuredEstimateGap).rounded())

        XCTExpectFailure(
            """
            既知の欠陥: `fits == true` は概算での話である。実測相当（発見19 の 1.47倍）に
            直すと超える。テンプレートの固定分と `tool_calls` の JSON はそもそも数えていないので、
            実際の差はこれより大きい。**「予算に収まった」は【未確認】のままである。**
            """
        ) {
            XCTAssertLessThanOrEqual(
                corrected, compacted.fit.budget,
                """
                概算 \(compacted.fit.tokens) は収まっているが、
                実測相当 \(corrected) は予算 \(compacted.fit.budget) を超える。
                """)
        }
    }

    // =========================================================================
    //  4. ターンをまたぐ側（`ContextTranscript.fit`）と、往復の側で判断が割れている
    // -------------------------------------------------------------------------
    //  **どちらも 16.3節 第2段である。** 落とすものも、落とす順も同じ。
    //  違うのは「落としたと言うかどうか」だけで、そこに理由が書かれていない。
    // =========================================================================

    /// **ターンをまたぐ側は、中身を落としたことを1文字も言わない。**
    ///
    /// 往復の側（`RoundTripItem.demotable`）は栞のあとに必ず
    /// `demotionNotice` を足しており、その型コメントはこう書いている ──
    ///
    /// > 栞は `<tool_response>` の中に入るので、**モデルから見れば
    /// > 「read_file がこれだけ返してきた」ようにしか見えない。**
    /// > 中身が「無かった」のか「取り下げた」のかを、数字ではなく文として書く。
    ///
    /// **`engineMessages` は同じ栞を、断り書きなしで置く。**
    /// 事情は同じなのに判断が違う ── どちらかが誤りである。
    ///
    /// > **いまは未配線である**（`fit` の呼び手は `Sources/` に1つも無い）。
    /// > だから実害はまだ出ていない。**配線した日に出る。**
    func testTheCrossTurnStageDropsTheContentWithoutSayingSo() throws {
        let old = Self.readOutcome(path: "a.md", contents: Self.haystack(needle: "NEEDLE-A"))
        let new = Self.readOutcome(path: "b.md", contents: Self.haystack(needle: "NEEDLE-B"))
        let entries: [ContextEntry] = [.message(.user("2つ読んで")), .read(old), .read(new)]

        let fit = ContextTranscript.fit(entries, budget: 1)
        let joined = fit.messages.map(\.content).joined(separator: "\n")

        // 前提: 実際に落ちていて、栞に置き換わっている。
        XCTAssertEqual(fit.demotedReads, 2, "前提が崩れている: 落とし切っていない")
        XCTAssertTrue(joined.contains(old.bookmarkLine), "前提が崩れている: 栞になっていない")
        XCTAssertFalse(joined.contains("NEEDLE-A"), "前提が崩れている: 中身が残っている")

        XCTExpectFailure(
            """
            既知の欠陥: 同じ第2段なのに、往復の側は断り書きを必ず足し、
            ターンをまたぐ側は足さない（`engineMessages` は `bookmarkLine` をそのまま置く）。
            16.3節「切ったら必ず言う」に対して、経路によって答えが違う。
            """
        ) {
            XCTAssertTrue(
                joined.contains(ContextTranscript.demotionNotice),
                "中身を落としたのに、落としたと言っていない")
        }
    }

    // =========================================================================
    //  5. 破ろうとして**破れなかった**もの（防御が効いていることの確認）
    // =========================================================================

    /// **モデルが `id` を出さなかった往復でも、落として対応づけが壊れないこと。**
    ///
    /// `ModelToolCall.callID` は Optional である ── モデルは出さないことがある。
    /// 既存の試験はどれも `"call-x"` を渡しており、**nil の側を1件も通していない。**
    /// 落とすときに `id` を持ち回る実装（`compacted` の `guard case`）が
    /// nil で崩れると、`role=tool` そのものが消えて往復が壊れる。
    func testDemotionKeepsTheRoleAndNameEvenWhenTheModelOmittedTheCallID() {
        let old = Self.read(path: "a.log", contents: Self.haystack(needle: "A"), callID: nil)
        let new = Self.read(path: "b.log", contents: Self.haystack(needle: "B"), callID: nil)

        let transcript: [RoundTripMessage] = [
            .user("2つ見て"),
            .assistant("", toolCalls: [Self.call(id: nil)]),
            MLXEngine.transcriptEntry(for: old),
            .assistant("", toolCalls: [Self.call(id: nil)]),
            MLXEngine.transcriptEntry(for: new),
        ]

        let compacted = MLXEngine.compacted(transcript, budget: 1)
        XCTAssertEqual(compacted.fit.demotedReads, 1, "前提が崩れている: 古い1件が落ちるはずである")

        let rendered = DefaultMessageGenerator()
            .generate(messages: MLXEngine.chatMessages(for: compacted.messages))

        XCTAssertEqual(
            rendered.map { $0["role"] as? String },
            ["user", "assistant", "tool", "assistant", "tool"],
            "`id` が nil だと役の並びが変わる")
        XCTAssertEqual(rendered[2]["name"] as? String, "read_file", "落とした側の name が消えている")
        XCTAssertEqual(rendered[4]["name"] as? String, "read_file")
        XCTAssertEqual(
            rendered[2]["content"] as? String,
            old.summaryLine + "\n" + ContextTranscript.demotionNotice)
        XCTAssertEqual(rendered[4]["content"] as? String, new.responseText)
    }

    /// **件数が桁違いでも、終わること・一番新しい1件が残ること。**
    ///
    /// `fitRoundTrip` は落とすたびに全項目の文字列を組み直して数え直す（O(n²)）。
    /// いまの上限（6回）では問題にならないが、**この関数は上限を知らない** ──
    /// ターンをまたいで往復の記録を残す日（`ToolResult.contextEntry` の申し送り）に、
    /// 何百件を渡されても止まらなくなっていないことを見ておく。
    func testEverythingCollapsesToTheNewestOneAndTheLoopStillTerminatesAtScale() {
        let items = (0..<300).map { index in
            ContextTranscript.RoundTripItem.demotable(
                raw: "本文\(index) " + String(repeating: "x", count: 40),
                bookmark: "読んだ: \(index).md（全1行すべて）")
        }

        let fit = ContextTranscript.fitRoundTrip(items, budget: 1, counter: .estimate)

        XCTAssertEqual(fit.demotedReads, 299, "落とし切れていない、あるいは落としすぎている")
        XCTAssertFalse(fit.demotedIndices.contains(299), "一番新しい1件まで落としている")
        XCTAssertEqual(fit.texts[299], items[299].rawText, "一番新しい1件が生のまま残っていない")
        XCTAssertEqual(fit.texts.count, items.count, "件数が変わっている")
        XCTAssertFalse(fit.fits, "収まっていないのに収まったと言っている")
    }

    /// **落とせないものしか無いターンでは、1件も落とさず `fits == false` を返すこと。**
    ///
    /// 失敗の文ばかりが並ぶ周は実際に起きる（モデルが存在しないパスを繰り返す。16.8節）。
    /// ここで無限に回る・落とせないものを落とす・収まったと偽る、のどれもしないこと。
    func testATurnMadeOnlyOfFailuresIsLeftAloneAndReportedAsNotFitting() {
        let failures = (1...6).map { index in
            ToolResult
                .rejected(.unknownTool("read_fil\(index)"), tool: "read_fil\(index)", counter: .estimate)
                .executionOutcome(callID: "call-\(index)")
        }
        var transcript: [RoundTripMessage] = [.user("読んで")]
        for failure in failures {
            transcript.append(.assistant("", toolCalls: [Self.call(id: failure.callID)]))
            transcript.append(MLXEngine.transcriptEntry(for: failure))
        }

        let compacted = MLXEngine.compacted(transcript, budget: 1)

        XCTAssertEqual(compacted.fit.demotedReads, 0, "落とせないものを落としている")
        XCTAssertFalse(compacted.fit.fits, "落とせるものが無い状態を『収まった』と偽っている")
        XCTAssertEqual(compacted.messages, transcript, "1件も変えないこと")
    }

    // MARK: - 道具

    /// **本物の道で作った読み取り1回ぶん**（`ContextWindow` → `ToolResult` → 実行役の戻り値）。
    private static func read(path: String, contents: String) -> ToolExecutionOutcome {
        read(path: path, contents: contents, callID: "call-\(path)")
    }

    /// `callID` を明示する版。**nil を渡せることが要点**である
    /// （既定つきの引数にすると `nil` が既定値に化けて、nil の側を1度も通さないまま緑になる）。
    private static func read(
        path: String, contents: String, callID: String?
    ) -> ToolExecutionOutcome {
        ToolResult
            .content(readOutcome(path: path, contents: contents), tool: "read_file", isListing: false)
            .executionOutcome(callID: callID)
    }

    private static func readOutcome(path: String, contents: String) -> ReadOutcome {
        ContextWindow.clip(contents, path: path, budget: .singleRead)
    }

    /// 読み取りの上限を必ず埋めきる本文。`needle` は**1行目**に置く ──
    /// 生のまま送られていれば必ず含まれ、栞には含まれない。
    private static func haystack(needle: String) -> String {
        ([needle] + (2...2_000).map { "line \($0): padding padding padding" })
            .joined(separator: "\n")
    }

    private static func call(id: String?) -> ToolCall {
        ToolCall(function: .init(name: "read_file", arguments: [String: JSONValue]()), id: id)
    }

    /// 記録1件の本文（網羅 switch。ケースが増えたら必ず1度考えることになる）。
    private static func text(of message: RoundTripMessage) -> String {
        switch message {
        case .system(let text), .user(let text):
            return text
        case .assistant(let text, _):
            return text
        case .toolResult(let text, _, _):
            return text
        case .demotableToolResult(let text, _, _, _):
            return text
        }
    }

    /// **印を非厳格にする**（`isStrict = false`）。
    ///
    /// 使うのは「破れているはずだが、実測の余裕が小さくて言い切れない」ものだけである。
    /// 厳格な印は、直った日に「失敗しなかった」で落ちて気づかせる仕掛けだが、
    /// **言い切れないものに厳格な印を付けると、直っていないのに落ちる**（逆の嘘になる）。
    private static var nonStrict: XCTExpectedFailure.Options {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        return options
    }
}
