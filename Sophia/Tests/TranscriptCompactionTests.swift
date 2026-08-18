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

    /// **落としたことを、栞のあとに文として書くこと**（16.3節「切ったら必ず言う」）。
    ///
    /// 栞は `<tool_response>` の中に入る ── モデルから見れば
    /// 「`read_file` がこれだけ返してきた」ようにしか見えない。
    /// 第1段（`ReadOutcome.clipNotice`）が同じ判断を先にしている:
    /// **範囲の表記は数字であって主張ではない。**
    func testTheDemotedTextSaysThatTheContentWasDropped() {
        let bookmark = "読んだ: notes.md（全412行のうち 1-80行）"
        let items: [ContextTranscript.RoundTripItem] = [
            .demotable(raw: "本文がここにある", bookmark: bookmark),
            .demotable(raw: "新しいほう", bookmark: "読んだ: b.md（全1行すべて）"),
        ]

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
    func testPerMessageOverheadIsAccountedWhenProvided() {
        let items: [ContextTranscript.RoundTripItem] = [.fixed("abc"), .fixed("de")]

        let bare = ContextTranscript.fitRoundTrip(
            items, budget: 1_000, counter: .oneCharacterOneToken)
        let withOverhead = ContextTranscript.fitRoundTrip(
            items, budget: 1_000, counter: .oneCharacterOneToken, perMessageOverhead: 5)

        XCTAssertEqual(bare.tokens, 5)
        XCTAssertEqual(withOverhead.tokens, 5 + 5 * 2)
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
    private static func read(path: String, needle: String) -> ToolExecutionOutcome {
        let source = ([needle] + (2...2_000).map { "line \($0): padding padding padding" })
            .joined(separator: "\n")
        let outcome = ContextWindow.clip(source, path: path, budget: .singleRead)
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
