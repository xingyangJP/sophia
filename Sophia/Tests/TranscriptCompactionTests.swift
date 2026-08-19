import Foundation
import MLXLMCommon
import XCTest

@testable import Sophia

// =============================================================================
//  第2段の縮約が、**1つのターンの中で実際に効くこと**（FR-19 / DESIGN.md 第16.3節）
// -----------------------------------------------------------------------------
//  **このファイルは1バイトもモデルを読み込まない。**
//
//  # このファイルが防いでいる失敗
//
//  2026-08-19 まで、16.3節の第2段は**設計にしか無かった。**
//  `ContextTranscript` は書かれていたが、`Sources/` から `fit` を呼ぶ行が1つも無く、
//  2か所のコメントが「履歴に残るのは栞1行である」と書いていた。**置く者がいなかった。**
//
//  費用は算数で出る ──
//
//  | | |
//  |---|--:|
//  | 1回の読み取り（`InputBudget.singleRead`） | 360 |
//  | 1ターンの往復（`FolderToolRunner.callLimit`） | × 6 |
//  | **積み上がりうる量** | **2,160** |
//  | 送信列に配られた分（`InputBudget.transcript(armed:)`） | **573** |
//
//  しかも往復のたびに全部プリフィルし直す（KV再利用なし・実測21秒）。
//  **積み上がった生の戻り値を、周回のたびに払い直していた。**
//
//  # 本日の教訓を、この試験の形に写してある
//
//  | 教訓 | ここでの形 |
//  |---|---|
//  | **「落ちないこと」ではなく「正しい値か」** | 落ちた件数・残った文字列を**等値で**見る。「例外が出ない」は1つも書いていない |
//  | **緑は「測れている」を意味しない** | 落とす前が**本当に予算を超えていること**を先に表明する（`raw.fit.tokens > budget`）。前提が崩れたら、そこで落ちる |
//  | **既存の往復を壊さないこと** | 落としたあとの列を `DefaultMessageGenerator` まで通し、`role` / `tool_call_id` / `name` を見る（`ToolRoundTripTests` と同じ道具） |
//
//  # 何を確かめられないか（**誤魔化さない**）
//
//  1. **`performChat` のループそのものは走らせていない**（`ModelContainer` が要る）。
//     ループが使う判断は `static` に出してあり（`compacted(_:budget:counter:)` /
//     `transcriptEntry(for:)`）、ここが叩いているのは**その本物**である。
//     ただし「ループがそれを呼んでいること」自体は、実装を読んで確かめるしかない。
//  2. **数え方は概算である。** 実トークナイザとの比は 1.47倍（発見19）。
//     「予算に収まった」は、ここが全部緑でも【未確認】のままである。
//     確かめる道は `TokenCounter.exact` を挿すこと（第15章の宿題）。
//
//  # 2026-08-19: **緑だったが測れていなかった3点を直した**
//
//  検証役（`AdversarialCompactionTests`）の指摘である。
//
//  | 何が測れていなかったか | どう直したか |
//  |---|---|
//  | 本命（6件読んだターン）が **`fits` を一度も見ていなかった。** 前書きは「2,160 対 573」を根拠に縮約の必要を説いているのに、表明は件数と半減しか見ていない | `fits` を見るようにした。**実際には収まっていない**（③）ので、そこも数字で残してある |
//  | `perMessageOverhead` の口を `fitRoundTrip` に直接当てていた。**出荷経路（`MLXEngine.compacted`）にはその口が無く**、渡されない引数の振る舞いを固定していた | `compacted` に口を開け、そちらから叩くようにした（`performChat` はまだ渡していない ── 【未確認】） |
//  | 道具の `read(path:needle:)` が「実行役が通るのと同じ道」と書きながら `clip(_:path:)`（全文の入口）を通っていた。**実行役が通るのは `clip(windowed:)`** で、1手ずれていた | 読み手が返す窓の形を写して `clip(windowed:)` を通すようにした |
//
//  **「落ちないこと」ではなく「正しい値か」。緑は、測れていることを意味しない。**
// =============================================================================

final class TranscriptCompactionTests: XCTestCase {

    private typealias Budget = SophiaDefaults.InputBudget

    // =========================================================================
    //  1. 規則そのもの（`ContextTranscript.fitRoundTrip`）
    // =========================================================================

    /// **収まっているうちは1件も落とさないこと。**
    ///
    /// この表明が本命である ── 縮約を「必ず落とす」実装にすると、
    /// 小さいファイルを1つ読んだだけの会話でも中身が消え、
    /// **モデルは自分が読んだはずのものを見ないまま答えることになる。**
    /// 落とすのは費用のためであって、費用が出ていないなら落とす理由が無い。
    func testNothingIsDemotedWhileTheTurnStillFits() {
        let items: [ContextTranscript.RoundTripItem] = [
            .fixed("利用者の質問"),
            .demotable(raw: "AAAA", bookmark: "読んだ: a.md（全4行すべて）"),
            .demotable(raw: "BBBB", bookmark: "読んだ: b.md（全4行すべて）"),
        ]

        let fit = ContextTranscript.fitRoundTrip(
            items, budget: 1_000, counter: .oneCharacterOneToken)

        XCTAssertEqual(fit.demotedReads, 0, "収まっているのに落としている")
        XCTAssertEqual(fit.texts, ["利用者の質問", "AAAA", "BBBB"])
        XCTAssertTrue(fit.fits)
        XCTAssertEqual(fit.tokens, 6 + 4 + 4)
    }

    /// **古いものから、必要なぶんだけ落とすこと。**
    ///
    /// 上限を「古いほうだけ落とせばちょうど収まる大きさ」に置いて、
    /// **1件で止まること**を見る（2件落ちるなら、落とさなくてよいものまで落としている）。
    func testTheOldestReadIsDemotedFirstAndOnlyAsFarAsNeeded() throws {
        let oldRaw = String(repeating: "A", count: 100)
        let newRaw = String(repeating: "B", count: 100)
        let old = ContextTranscript.RoundTripItem.demotable(
            raw: oldRaw, bookmark: "読んだ: a.md（全400行のうち 1-80行）")
        let new = ContextTranscript.RoundTripItem.demotable(
            raw: newRaw, bookmark: "読んだ: b.md（全400行のうち 1-80行）")
        let items: [ContextTranscript.RoundTripItem] = [.fixed("質問"), old, new]

        let demotedOld = try XCTUnwrap(old.demotedText)
        let target = 2 + demotedOld.count + newRaw.count

        // **前提: 落とさなければ収まらない。** ここが崩れていれば、この試験は
        // 何も測っていない（「31件のフォルダで200件の天井を測ろうとした」失敗と同じ形）。
        XCTAssertGreaterThan(
            2 + oldRaw.count + newRaw.count, target, "前提が崩れている: 落とさなくても収まる")

        let fit = ContextTranscript.fitRoundTrip(
            items, budget: target, counter: .oneCharacterOneToken)

        XCTAssertEqual(fit.demotedIndices, [1], "古いほうから1件だけ落ちること")
        XCTAssertEqual(fit.tokens, target, "測った値が、送る文字列と一致していること")
        XCTAssertTrue(fit.fits)
        XCTAssertEqual(fit.texts[2], newRaw, "一番新しい読み取りは生のまま残ること")
    }

    /// **一番新しい読み取りは、収まらなくても落とさないこと。**
    ///
    /// ターンをまたぐ側（`ContextTranscript.fit`）は落とし切るが、こちらは残す。
    /// 違いの理由は1つ ── **往復の最中は、まだ答えが出ていない。**
    /// いま読んだ中身を落とせば、モデルは中身を見ないまま答える。
    ///
    /// 収まらなかったことは `fits` に出る。**「落とせるものが無い」を「収まった」と偽らない。**
    func testTheNewestReadSurvivesEvenWhenNothingCanFit() {
        let newRaw = String(repeating: "B", count: 100)
        let items: [ContextTranscript.RoundTripItem] = [
            .fixed("質問"),
            .demotable(raw: String(repeating: "A", count: 100), bookmark: "読んだ: a.md"),
            .demotable(raw: newRaw, bookmark: "読んだ: b.md"),
        ]

        let fit = ContextTranscript.fitRoundTrip(items, budget: 1, counter: .oneCharacterOneToken)

        XCTAssertEqual(fit.demotedIndices, [1], "落とせるのは古い1件だけである")
        XCTAssertEqual(fit.texts[2], newRaw, "答えさせようとしている材料まで落としている")
        XCTAssertEqual(fit.texts[0], "質問", "利用者の発言は落とさないこと")
        XCTAssertFalse(fit.fits, "収まっていないなら、収まったと言わないこと")
        XCTAssertGreaterThan(fit.tokens, fit.budget)
    }

    /// **落として高くつく項目は、落とさないこと**（①。縮約の目的は費用であって件数ではない）。
    ///
    /// 空のファイルの読み取りがその形である ──
    ///
    /// | | 概算 |
    /// |---|--:|
    /// | 生 `[ファイル placeholder.md / 空のファイル（0行 / 0バイト）]` | **19** |
    /// | 栞＋断り書き | **24** |
    ///
    /// 落とせば**縮約が費用を増やす。** しかも `demotedReads` は件数を申告するので、
    /// `[TOOL] compacted demoted=2` の行だけを見ていると成功したように見える。
    ///
    /// **数字は写していない** ── 実物どうしを比べている
    /// （`ContextWindow.clip(windowed:)` → `ToolResult` → 実行役の戻り値）。
    func testAnItemThatWouldCostMoreWhenDemotedKeepsItsContent() {
        let outcome = Self.emptyRead(path: "placeholder.md")
        let item = ContextTranscript.RoundTripItem.demotable(
            raw: outcome.responseText, bookmark: outcome.summaryLine)
        let counter = TokenCounter.estimate

        // **前提: これは「落とすと高くつく」材料である。**
        // 崩れていたら、この試験は別のものを測っている。
        XCTAssertTrue(outcome.responseText.contains("空のファイル"), "前提が崩れている: 空の読み取りでない")
        XCTAssertGreaterThan(
            counter(outcome.summaryLine + "\n" + ContextTranscript.demotionNotice),
            counter(outcome.responseText),
            "前提が崩れている: 栞＋断り書きのほうが安い材料になっている")

        XCTAssertEqual(
            item.demotedText, item.rawText,
            "落とす価値が無い項目は、落とした姿を生の姿へ潰すこと")

        let items: [ContextTranscript.RoundTripItem] = [.fixed("2つとも空か見て"), item, item]
        let untouched = ContextTranscript.fitRoundTrip(items, budget: .max)
        let squeezed = ContextTranscript.fitRoundTrip(items, budget: 1)

        XCTAssertEqual(untouched.demotedReads, 0, "前提が崩れている: 上限が無いのに落としている")
        XCTAssertLessThanOrEqual(
            squeezed.tokens, untouched.tokens,
            """
            縮約が費用を増やしている ── 通す前 \(untouched.tokens) / 通した後 \(squeezed.tokens)。
            落とした件数は \(squeezed.demotedReads)。
            """)
        XCTAssertEqual(squeezed.texts, untouched.texts, "1トークンも減らないのに中身だけ消えている")
    }

    /// **落としたことを、栞のあとに文として書くこと**（16.3節「切ったら必ず言う」）。
    ///
    /// 栞は `<tool_response>` の中に入る ── モデルから見れば
    /// 「`read_file` がこれだけ返してきた」ようにしか見えない。
    /// 第1段（`ReadOutcome.clipNotice`）が同じ判断を先にしている:
    /// **範囲の表記は数字であって主張ではない。**
    ///
    /// > **本文を大きくしてある**（2026-08-19）。元は `本文がここにある`（8文字）で、
    /// > 栞＋断り書き（45文字・概算24）のほうが**3倍以上高かった** ──
    /// > つまり元の材料は「落とすと費用が増える」当のもの（①）だった。
    /// > いまは落として安くなるものだけが落ちるので、そのままでは1件も落ちない。
    /// > **数え方も明示して渡す** ── 作るときと測るときで数え方が違うと、
    /// > 「得になる」の判定と予算の判定が別々の物差しになる。
    func testTheDemotedTextSaysThatTheContentWasDropped() {
        let bookmark = "読んだ: notes.md（全412行のうち 1-80行）"
        let body = String(repeating: "本文がここにある。", count: 10)
        let items: [ContextTranscript.RoundTripItem] = [
            .demotable(raw: body, bookmark: bookmark, counter: .oneCharacterOneToken),
            .demotable(
                raw: "新しいほう", bookmark: "読んだ: b.md（全1行すべて）",
                counter: .oneCharacterOneToken),
        ]

        // **前提: 落とせば安くなる材料であること。**
        // 崩れていれば①の規則で1件も落ちず、下の表明は何も見ないまま緑になる。
        XCTAssertGreaterThan(
            body.count, (bookmark + "\n" + ContextTranscript.demotionNotice).count,
            "前提が崩れている: 落としても安くならない材料である")

        let fit = ContextTranscript.fitRoundTrip(items, budget: 1, counter: .oneCharacterOneToken)

        XCTAssertEqual(
            fit.texts[0], bookmark + "\n" + ContextTranscript.demotionNotice,
            "栞と断り書きの組み立ては1か所（`RoundTripItem.demotable`）でしか作らないこと")
        // **範囲は残る。** 落とすのは中身であって、読んだ事実と範囲ではない。
        XCTAssertTrue(fit.texts[0].contains("1-80行"))
        XCTAssertFalse(fit.texts[0].contains("本文がここにある"))
    }

    /// 空のターンで壊れないこと。**値で返る**（例外にしない）。
    func testAnEmptyTurnIsNotAnError() {
        let fit = ContextTranscript.fitRoundTrip([], budget: 0, counter: .oneCharacterOneToken)

        XCTAssertEqual(fit.texts, [])
        XCTAssertEqual(fit.tokens, 0)
        XCTAssertEqual(fit.demotedReads, 0)
        XCTAssertTrue(fit.fits)
    }

    /// テンプレートの固定分は**まだ測っていない**ので既定 0。
    /// 入れられる口があること自体を固定しておく（`fit` と同じ規律）。
    ///
    /// ## **叩く先を出荷経路へ移した**（2026-08-19。ここは何も測れていなかった）
    ///
    /// 元は `ContextTranscript.fitRoundTrip` を直接呼んでいた。ところが
    /// **`MLXEngine.compacted` にはこの引数を渡す口が無く**、往復のループが通るのは
    /// あくまで `compacted` である ── つまりこの試験は
    /// **出荷経路が決して使わない引数の振る舞いを固定していた。**
    /// 口を `compacted` にも開け、こちらから叩くようにした。
    ///
    /// > **【未確認】まだ届いていない一手。** `performChat` は `compacted` に
    /// > `perMessageOverhead` を渡していない（既定 0 のまま）。
    /// > 渡す値が無いからである ── テンプレートの固定分は
    /// > 実トークナイザでしか測れない（第15章の宿題 / `TokenCounter.exact`）。
    /// > **口が開いたことと、実際に払っている分を数えていることは、まだ別である。**
    func testPerMessageOverheadIsAccountedThroughTheShippingEntryPoint() {
        let transcript: [RoundTripMessage] = [.user("abc"), .assistant("de", toolCalls: [])]

        let bare = MLXEngine.compacted(
            transcript, budget: 1_000, counter: .oneCharacterOneToken)
        let withOverhead = MLXEngine.compacted(
            transcript, budget: 1_000, counter: .oneCharacterOneToken, perMessageOverhead: 5)

        XCTAssertEqual(bare.fit.tokens, 5)
        XCTAssertEqual(withOverhead.fit.tokens, 5 + 5 * 2, "1発言あたり5を、発言の数だけ足すこと")
    }

    // =========================================================================
    //  2. 往復のループに当てる（`MLXEngine.compacted`）
    // =========================================================================

    /// **1ターンで6回読んだ会話が、栞＋一番新しい1件まで縮むこと。**
    ///
    /// 文字列は全部本物である ── `ContextWindow.clip` → `ToolResult.content` →
    /// `executionOutcome(callID:)` と、実行役が通るのと同じ道で作っている。
    func testSixRealReadsInOneTurnCollapseToBookmarksPlusTheNewestRead() throws {
        let budget = Budget.transcript(armed: true)

        var transcript: [RoundTripMessage] = [
            .system(SophiaDefaults.systemPrompt),
            .user("この6つを見て、どれに NEEDLE があるか教えて"),
        ]
        var outcomes: [ToolExecutionOutcome] = []
        for index in 1...6 {
            let outcome = Self.read(path: "log/\(index).log", needle: "NEEDLE-\(index)")
            outcomes.append(outcome)
            transcript.append(.assistant("", toolCalls: [Self.call(id: outcome.callID)]))
            transcript.append(MLXEngine.transcriptEntry(for: outcome))
        }

        // **前提を先に測る。** 上限を外して組み、それが本当に予算を超えていることを見る。
        // 超えていない状況で「落ちた」を見ても、天井を測ったことにはならない。
        let raw = MLXEngine.compacted(transcript, budget: .max)
        XCTAssertEqual(raw.fit.demotedReads, 0, "上限が無いのに落としている")
        XCTAssertGreaterThan(
            raw.fit.tokens, budget,
            """
            前提が崩れている ── 6回の読み取りが送信列の予算（\(budget)）を超えていない。
            超えていないなら、この試験は縮約が効いたことを何も表明していない。
            """)

        let compacted = MLXEngine.compacted(transcript, budget: budget)

        XCTAssertEqual(
            compacted.fit.demotedReads, 5,
            "古い5件が落ち、一番新しい1件だけが生で残ること（落ちた件数: \(compacted.fit.demotedReads)）")
        XCTAssertLessThan(compacted.fit.tokens, raw.fit.tokens / 2, "落としたのに量が減っていない")
        XCTAssertEqual(
            compacted.messages.count, transcript.count,
            "件数を変えないこと ── 減らすと `<tool_call>` と `<tool_response>` の対が崩れる")

        // --- **収まったのか**（2026-08-19 に足した。ここを一度も見ていなかった）-------
        //
        // 章の前書きは「2,160 対 573」を根拠に縮約の必要を説いているのに、
        // 表明は件数と半減しか見ていなかった。**件数は手段であって目的ではない。**
        // 目的は予算に収めることで、それは `fits` にしか出ない。
        //
        // そして**いまは収まらない**（③ / 申し送り）。欠陥ではなく配分表の算数である ──
        // 一番新しい読み取り（`InputBudget.singleRead` = 360・概算実測 353）と
        // 自己認識（同 97）と栞5件（同 25 × 5）が、取り分 573 に同居できない。
        // **この層はこれ以上減らせない** ── 超過は `contextLength`（8,192）まで素通りする。
        XCTAssertGreaterThan(
            compacted.fit.tokens, compacted.fit.budget,
            "落とし切っても超えることが、この試験の測っている事実である")
        XCTAssertFalse(
            compacted.fit.fits,
            """
            収まるようになった（\(compacted.fit.tokens) / \(compacted.fit.budget)）。
            配分表か断り書きの費用が動いたということである。
            **③の申し送りを閉じ、この2行を「収まること」の表明へ反転させること。**
            """)
        // 収まらないと言っている以上、**どれだけ超えたかを数字で残す。**
        // 「収まらない」だけでは、次に見る者が近いのか遠いのかを判断できない。
        XCTAssertLessThan(
            compacted.fit.tokens - compacted.fit.budget, Budget.singleRead,
            """
            超過が読み取り1回分（\(Budget.singleRead)）を超えている
            ── \(compacted.fit.tokens) / \(compacted.fit.budget)。
            これは「あと少し」ではなく、配分表そのものが破れている状態である。
            """)

        let joined = compacted.messages.map(Self.text(of:)).joined(separator: "\n")
        XCTAssertTrue(joined.contains("NEEDLE-6"), "一番新しい読み取りの中身が消えている")
        for index in 1...5 {
            XCTAssertFalse(
                joined.contains("NEEDLE-\(index)"), "古い読み取りの中身が残っている（\(index)）")
            XCTAssertTrue(
                joined.contains(outcomes[index - 1].summaryLine), "栞が残っていない（\(index)）")
        }
        XCTAssertTrue(joined.contains("この6つを見て"), "利用者の発言まで落としている")
        XCTAssertTrue(
            joined.contains(SophiaDefaults.systemPrompt), "自己認識まで落としている")

        // **一番新しい戻り値は1文字も変わっていないこと。**
        XCTAssertEqual(
            Self.text(of: compacted.messages[compacted.messages.count - 1]),
            outcomes[5].responseText)
    }

    /// **同じ周で頼まれた戻り値は、1件も落とさないこと**（②）。
    ///
    /// `performChat` は1周の呼び出しを**全部並べる**（`assistant` の `tool_calls` は
    /// 何個でも入り、その後ろに戻り値が並ぶ）。守るのが「一番新しい1件」だけだと、
    /// **残りはモデルが一度も見ないまま次の周の頭で栞になる。**
    /// 往復の回数（`FolderToolRunner.callLimit`）は呼んだ時点で消費済みなので、
    /// **読み直すこともできない。**
    func testEveryReadOfTheCurrentRoundSurvivesWhenThreeWereCalledInOneRound() {
        let budget = Budget.transcript(armed: true)
        let a = Self.read(path: "a.log", needle: "NEEDLE-A")
        let b = Self.read(path: "b.log", needle: "NEEDLE-B")
        let c = Self.read(path: "c.log", needle: "NEEDLE-C")

        // **1周で3つ。** assistant の発言は1つで、`tool_calls` が3つ入る。
        let transcript: [RoundTripMessage] = [
            .user("a.log と b.log と c.log を見比べて"),
            .assistant("", toolCalls: [a, b, c].map { Self.call(id: $0.callID) }),
            MLXEngine.transcriptEntry(for: a),
            MLXEngine.transcriptEntry(for: b),
            MLXEngine.transcriptEntry(for: c),
        ]

        // **前提: 3件は予算を超えている。** 超えていなければ縮約は何も試されない。
        let raw = MLXEngine.compacted(transcript, budget: .max)
        XCTAssertGreaterThan(
            raw.fit.tokens, budget,
            "前提が崩れている ── 1周3件（\(raw.fit.tokens)）が予算（\(budget)）に収まっている")

        let compacted = MLXEngine.compacted(transcript, budget: budget)
        let joined = compacted.messages.map(Self.text(of:)).joined(separator: "\n")

        XCTAssertEqual(compacted.fit.demotedReads, 0, "この周の材料を落としている")
        for needle in ["NEEDLE-A", "NEEDLE-B", "NEEDLE-C"] {
            XCTAssertTrue(joined.contains(needle), "\(needle) が答える前に消えている")
        }
        // **守った結果、収まらない。** それは事実として返す（③）── 隠さない。
        XCTAssertFalse(compacted.fit.fits, "収まっていないのに収まったと言っている")
    }

    /// **前の周の戻り値は落ちること。**
    ///
    /// 守るのは「まだ見ていないもの」であって「ツールの戻り値すべて」ではない ──
    /// 前の周のぶんは既に一度プロンプトに載っており、
    /// **モデルはそれを見たうえで次の呼び出しを書いている。**
    /// ここが崩れると②の修正は「何も落とさない縮約」に化ける。
    func testReadsFromEarlierRoundsStillFallWhileTheCurrentRoundIsKept() {
        let old = Self.read(path: "old.log", needle: "NEEDLE-OLD")
        let newA = Self.read(path: "a.log", needle: "NEEDLE-A")
        let newB = Self.read(path: "b.log", needle: "NEEDLE-B")

        let transcript: [RoundTripMessage] = [
            .user("見て"),
            .assistant("", toolCalls: [Self.call(id: old.callID)]),
            MLXEngine.transcriptEntry(for: old),
            .assistant("", toolCalls: [newA, newB].map { Self.call(id: $0.callID) }),
            MLXEngine.transcriptEntry(for: newA),
            MLXEngine.transcriptEntry(for: newB),
        ]

        let compacted = MLXEngine.compacted(transcript, budget: Budget.transcript(armed: true))
        let joined = compacted.messages.map(Self.text(of:)).joined(separator: "\n")

        XCTAssertEqual(compacted.fit.demotedReads, 1, "落ちるのは前の周の1件だけである")
        XCTAssertFalse(joined.contains("NEEDLE-OLD"), "前の周の中身が残っている")
        XCTAssertTrue(joined.contains(old.summaryLine), "栞が残っていない")
        XCTAssertTrue(joined.contains("NEEDLE-A"), "この周の材料が消えている")
        XCTAssertTrue(joined.contains("NEEDLE-B"), "この周の材料が消えている")
    }

    /// **失敗の文は落とさないこと**（16.8節）。
    ///
    /// 1行しかないので落としても得が無く、**忘れると同じ誤りが繰り返される** ──
    /// 「そのパスは無い」を落とせば、モデルは次の周で同じパスをまた書く。
    func testFailuresAreNeverDemotedBecauseTheyStopTheModelRepeatingItself() {
        let failure = ToolResult
            .rejected(.unknownTool("read_fil"), tool: "read_fil", counter: .estimate)
            .executionOutcome(callID: "call-x")
        XCTAssertTrue(failure.isFailure, "前提: これは失敗である")

        // 実装が「失敗をどちらへ入れるか」を決めている当の関数を通すこと。
        let entry = MLXEngine.transcriptEntry(for: failure)
        guard case .toolResult = entry else {
            return XCTFail("失敗の文が落とせる側に入っている: \(entry)")
        }

        let compacted = MLXEngine.compacted(
            [.user("読んで"), .assistant("", toolCalls: [Self.call(id: "call-x")]), entry],
            budget: 1)

        XCTAssertEqual(compacted.fit.demotedReads, 0, "落とせないものを落としている")
        XCTAssertEqual(Self.text(of: compacted.messages[2]), failure.responseText)
    }

    /// **中身のある結果は落とせる側へ入ること**（`transcriptEntry(for:)` の対の表明）。
    func testAContentfulResultGoesIntoTheDemotableCase() {
        let outcome = Self.read(path: "notes.md", needle: "NEEDLE-1")

        guard case .demotableToolResult(let text, let bookmark, let id, let name) =
            MLXEngine.transcriptEntry(for: outcome)
        else {
            return XCTFail("中身のある結果が落とせない側に入っている")
        }
        // **文字列を組み直していないこと。** 実行役が渡してきた値そのままである。
        XCTAssertEqual(text, outcome.responseText)
        XCTAssertEqual(bookmark, outcome.summaryLine)
        XCTAssertEqual(id, outcome.callID)
        XCTAssertEqual(name, outcome.toolName)
    }

    // =========================================================================
    //  3. 落としても往復が壊れないこと（テンプレートへ渡る辞書まで）
    // =========================================================================

    /// **落とした戻り値も `role=tool` のまま、`tool_call_id` と `name` を保つこと。**
    ///
    /// 落とすのは中身だけである。対応づけまで切ると、`<tool_response>` が
    /// **対応する `<tool_call>` なしで現れ**、モデルから見て
    /// 「誰が何を訊いたのか分からない返事」になる（16.1節 / `ToolRoundTripTests` の1章）。
    func testDemotionKeepsTheToolCallAndToolResponsePaired() throws {
        let old = Self.read(path: "a.log", needle: "NEEDLE-A")
        let new = Self.read(path: "b.log", needle: "NEEDLE-B")

        let transcript: [RoundTripMessage] = [
            .user("2つ見て"),
            .assistant("", toolCalls: [Self.call(id: old.callID)]),
            MLXEngine.transcriptEntry(for: old),
            .assistant("", toolCalls: [Self.call(id: new.callID)]),
            MLXEngine.transcriptEntry(for: new),
        ]

        // 1件は必ず落ちる上限（`InputBudget.transcript` より厳しく置く）。
        let compacted = MLXEngine.compacted(transcript, budget: 1)
        XCTAssertEqual(compacted.fit.demotedReads, 1)

        let rendered = DefaultMessageGenerator()
            .generate(messages: MLXEngine.chatMessages(for: compacted.messages))

        XCTAssertEqual(
            rendered.map { $0["role"] as? String },
            ["user", "assistant", "tool", "assistant", "tool"],
            "落としたことで役の並びが変わっている")

        // 落とした側 ── 中身は栞＋断り書きだが、対応づけは生きている。
        XCTAssertEqual(rendered[2]["tool_call_id"] as? String, old.callID)
        XCTAssertEqual(rendered[2]["name"] as? String, "read_file")
        XCTAssertEqual(
            rendered[2]["content"] as? String,
            old.summaryLine + "\n" + ContextTranscript.demotionNotice)

        // 落としていない側 ── 1文字も変わっていない。
        XCTAssertEqual(rendered[4]["content"] as? String, new.responseText)
        XCTAssertEqual(rendered[4]["tool_call_id"] as? String, new.callID)
    }

    // =========================================================================
    //  4. なぜこの層が要るのか（配分表との接続）
    // =========================================================================

    /// **1ターンぶんの読み取りは、送信列に配られた分を超えうる。**
    ///
    /// 超えないなら、この層は要らない。**要ることを数字で表明しておく。**
    /// 数字は写さず、両方とも出所から取っている（`callLimit` は `FolderToolRunner` から）。
    func testOneTurnOfReadingCanOverrunTheShareGivenToTheTranscript() throws {
        let callLimit = try Self.defaultCallLimit()

        XCTAssertGreaterThan(
            Budget.singleRead * callLimit, Budget.transcript(armed: true),
            """
            1ターンぶんの読み取り（\(Budget.singleRead) × \(callLimit)）が
            送信列の取り分（\(Budget.transcript(armed: true))）に収まっている。
            収まるなら第2段の縮約は要らない ── どちらかの数字が動いたということである。
            """)
    }

    /// **門が閉じた周は、ツール定義ぶんが上限へ戻ること。**
    ///
    /// `MLXEngine` は `armed:` に `roundTools != nil` を渡している。
    /// 定義を送らない周にも定義ぶんを引くと、その周だけ不当に厳しくなる。
    func testTheTranscriptShareGrowsBackWhenToolDefinitionsAreNotSent() {
        XCTAssertEqual(
            Budget.transcript(armed: false) - Budget.transcript(armed: true),
            Budget.toolDefinitions)
    }

    // MARK: - 道具

    /// 本物の道で作った読み取り1回ぶん（`ContextWindow` → `ToolResult` → 実行役の戻り値）。
    ///
    /// `needle` は**1行目**に置く。窓は先頭から取られるので、
    /// 生のまま送られていれば必ず本文に含まれ、栞には含まれない。
    ///
    /// ## **入口は `clip(windowed:)` である**（2026-08-19 に直した。1手ずれていた）
    ///
    /// ここは `clip(_:path:)`（**ファイル全文**を受ける入口）を呼んでいた。
    /// **実行役が通るのはそちらではない** ── `FolderToolExecution.read` は
    /// `FolderReader.readText` が返した**窓**を `clip(windowed:)` へ渡す。
    /// 2つは総行数の出所が違い（数え直す／読み手から受け取る）、
    /// 近道の効き方も違う（`clip(windowed:)` の但し書き「近道は一度も効かなかった」）。
    /// **「実行役が通るのと同じ道」と書いてある試験が、実際には別の入口を通っていた。**
    ///
    /// 下では読み手の振る舞いを写してある ──
    /// 行数の窓は `FolderReadLimits.lineLimit`、本文は読めた行を `\n` で**連結**したもの、
    /// 総行数と総バイト数は**ファイル全体**の値。
    ///
    /// > **【未確認】ここが通していないもの:** 封じ込め（16.5節）・実際のファイルI/O・
    /// > CRLF の落とし方。それらを通すのは `AdversarialCompactionTests` の1章と3章
    /// > （本物の `FolderToolRunner` に実ファイルを読ませている）。
    private static func read(path: String, needle: String) -> ToolExecutionOutcome {
        let lines = [needle] + (2...2_000).map { "line \($0): padding padding padding" }
        let source = lines.joined(separator: "\n")
        let window = lines.prefix(FolderReadLimits.lineLimit).joined(separator: "\n")

        let outcome = ContextWindow.clip(
            windowed: window,
            path: path,
            firstLine: 1,
            totalLines: lines.count,
            totalBytes: source.utf8.count,
            budget: .singleRead)
        return ToolResult
            .content(outcome, tool: "read_file", isListing: false)
            .executionOutcome(callID: "call-\(path)")
    }

    /// **空のファイルを読んだ1回ぶん**（①が使う）。
    ///
    /// 架空の入力ではない ── `touch` したもの、置いただけの `__init__.py`、
    /// まだ何も書かれていないログ。**モデルは中身が空だと知るために一度読む。**
    /// 読み手（`FolderReader`）は本文 `""`・総行数 0・総バイト数 0 を返す。
    private static func emptyRead(path: String) -> ToolExecutionOutcome {
        let outcome = ContextWindow.clip(
            windowed: "", path: path, firstLine: 1, totalLines: 0, totalBytes: 0,
            budget: .singleRead)
        return ToolResult
            .content(outcome, tool: "read_file", isListing: false)
            .executionOutcome(callID: "call-\(path)")
    }

    private static func call(id: String?) -> ToolCall {
        ToolCall(function: .init(name: "read_file", arguments: [String: JSONValue]()), id: id)
    }

    /// 記録1件の本文。**新しいケースが増えたら、ここで必ず1度考えることになる**（網羅 switch）。
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

    /// `FolderToolRunner` の既定の往復上限（16.8節）。**literal を書かない。**
    private static func defaultCallLimit() throws -> Int {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SophiaCompaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = try SecurityScopedFolder.unscoped(directoryURL: directory)
        return FolderToolRunner(folder: folder).callLimit
    }
}

private extension TokenCounter {
    /// **1文字=1トークン。境界をぴたりと踏むための器。**
    ///
    /// 概算（文字種別）で境界を書くと、係数を直したときにテストの意図まで動く。
    /// 確かめたいのは「上限ちょうど」「上限+1」であって、係数ではない。
    /// （`ContextWindowTests` / `AdversarialContextTests` にも同じ器がある。
    ///   どれも `private` で互いに見えないので、各ファイルが持っている）
    static let oneCharacterOneToken = TokenCounter(
        name: "テスト用（1文字=1トークン）",
        isEstimate: false
    ) { $0.count }
}
