import XCTest

@testable import Sophia

/// **2つの予算が別々に決められていないことを表明する**（DESIGN.md 第2.2章 / 第16.2節 / 第16.3節）。
///
/// ---
///
/// # このファイルが防いでいる失敗
///
/// 2026-08-18 の時点で、入力の予算はこう決まっていた ──
///
/// | 値 | 決めた節 |
/// |---|---|
/// | `SophiaDefaults.inputTokenBudget = 1,000` | 2.2章 |
/// | ツール定義 322（`armed` の間・毎ターン） | 16.4節（実測） |
/// | 固定の前置き 105（毎ターン） | 4.8節（実測） |
/// | `ContextBudget.singleRead = 600` | 16.3節 |
///
/// **322 + 105 + 600 = 1,027 > 1,000。ファイルを1つ読ませた時点で超える。**
/// 英語化前は 1,887（189%）で、英語化で 103% まで下がったが、
/// **下がったのは額であって構造ではない。**
///
/// # 表明の置き方（**本日の教訓2つに直接対応させてある**）
///
/// | 教訓 | ここでの形 |
/// |---|---|
/// | **「落ちないこと」ではなく「正しい値か」に置く** | 合計が総額に**一致する**ことを見る。「超えない」ではない |
/// | **緑は「測れている」を意味しない** | 数字を突き合わせるだけの表明を置かない。**実物の文字列を組んで数える** |
///
/// 特に2つ目である。`singleRead` を引き算で導出していれば
/// 「合計 ≤ 総額」は**永久に緑**になり、何も測っていないのに測った気になれる。
/// だから `SophiaDefaults.InputBudget` は6項目とも明示してあり、
/// **1つでも動かせばここが落ちる。**
///
/// # ⚠️ 単位が混ざっていることを、緑で覆い隠さないこと
///
/// | 行 | 何で数えた値か |
/// |---|---|
/// | `fixedPreamble` / `toolDefinitions` | **実トークナイザ**（`make tooltokens`） |
/// | `singleRead` / `bookmarks` を守る側 | **`TokenCounter`。既定は概算** |
///
/// 発見19の1.47倍は旧概算に対する値で、現行概算の補正には使えない。
/// 出荷時の縮約は実トークナイザを使うが、配分表の `singleRead` / `bookmarks` は概算由来である。
/// **したがって本ファイルが全部緑でも、armed の実入力が1,000に収まる証明にはならない。**
/// ここが表明できるのは
/// 「**同じ単位どうしの比較が破れていないこと**」と「**配分表が閉じていること**」の2つだけで、
/// 実機の確定は `make tooltokens` の最終 `prepare` で行う。
final class BudgetReconciliationTests: XCTestCase {

    private typealias Budget = SophiaDefaults.InputBudget

    // =========================================================================
    //  1. 配分表が閉じていること
    // =========================================================================

    /// **配分の合計が総額と一致すること。** 「超えない」ではなく「一致する」を見る。
    ///
    /// 不等号で置くと、余りを黙って抱えたまま「収まっている」と言える。
    /// **余りがあるなら、それは誰にも配られていないという事実であり、見えるべきである。**
    func testTheAllocationAddsUpToTheTotalExactly() {
        let sum =
            Budget.fixedPreamble + Budget.toolDefinitions + Budget.singleRead
            + Budget.bookmarks + Budget.userText

        XCTAssertEqual(
            sum, Budget.total,
            """
            配分表が閉じていない（合計 \(sum) / 総額 \(Budget.total)）。
            **数字を1つ足したなら、どこから取るかを同じ表の中で決めること。**
            これを直さずに済ませた結果が 322 + 105 + 600 = 1,027 だった。
            """)
        XCTAssertEqual(Budget.unallocated, 0, "配り残しは 0 であること")
    }

    /// **どの項も 0 より大きいこと。** 0 の項は「配ったふり」である。
    func testEveryLineOfTheAllocationIsPositive() {
        for (name, value) in [
            ("total", Budget.total),
            ("fixedPreamble", Budget.fixedPreamble),
            ("toolDefinitions", Budget.toolDefinitions),
            ("singleRead", Budget.singleRead),
            ("bookmarks", Budget.bookmarks),
            ("userText", Budget.userText),
        ] {
            XCTAssertGreaterThan(value, 0, "\(name) が 0 以下")
        }
    }

    /// **同じ数字が2か所に無いこと。**
    ///
    /// 別々に決まった原因はこれである ── 総額はここ、読み取りの上限はあちら、
    /// 定義の費用はさらに別、と**写した数字が3か所にあった。**
    /// 写しがある限り、片方だけを直す事故は必ず起きる。
    func testNoNumberHasASecondSource() {
        XCTAssertEqual(
            ContextBudget.singleRead.tokens, Budget.singleRead,
            "`ContextBudget.singleRead` が配分表と別の数字を持っている")
        XCTAssertEqual(
            SophiaDefaults.inputTokenBudget, Budget.total,
            "`inputTokenBudget` が配分表と別の総額を持っている")
        // **この1本だけは「形の錠」であって計測ではない。**
        // `toolDefinitions` は `toolDefinitionTokens` を参照しているので、いまは自明に通る。
        // 落ちるのは**誰かがここへ数字を写し戻したとき**だけであり、それが防ぎたい事故である。
        // 値そのものの正しさを見ているのは `EngineToolWiringTests`（`SOPHIA_TOOLTOKENS=1`）の
        // 実トークナイザ計測のほうで、**こちらは代わりにならない。**
        XCTAssertEqual(
            Budget.toolDefinitions, SophiaDefaults.toolDefinitionTokens,
            "ツール定義の費用が配分表と実測定数で食い違っている")
    }

    /// `armed` かどうかで固定費が変わること。**`idle` は定義に1トークンも払わない**（FR-21 / 16.2節）。
    func testTheFixedCostIsZeroForToolsWhileIdle() {
        XCTAssertEqual(Budget.fixedCost(armed: false), Budget.fixedPreamble)
        XCTAssertEqual(
            Budget.fixedCost(armed: true), Budget.fixedPreamble + Budget.toolDefinitions)
        XCTAssertEqual(
            Budget.transcript(armed: true) - Budget.transcript(armed: false),
            -Budget.toolDefinitions,
            "armed にすると、送信列に使える分がちょうど定義ぶん減ること")
    }

    /// 縮約側で数える system 本文と発言枠を、上限から先に二重で引かないこと。
    func testTranscriptBudgetOnlyPreSubtractsWhatCompactionCannotCount() {
        XCTAssertEqual(
            Budget.transcript(armed: false), Budget.total - Budget.generationPromptOverhead)
        XCTAssertEqual(
            Budget.transcript(armed: true),
            Budget.total - Budget.generationPromptOverhead - Budget.toolDefinitions)
        XCTAssertGreaterThan(
            Budget.transcript(armed: true), Budget.total - Budget.fixedCost(armed: true),
            "system本文と発言枠を送信列でも数えるため、その分は上限へ戻っていること")
    }

    // =========================================================================
    //  2. 実物を組んで数える（**数字の突き合わせで終わらせない**）
    // =========================================================================

    /// **`singleRead` は、実際に組み上がった文字列に対して守られていること。**
    ///
    /// 上限を宣言しただけでは何も保証していない。**入れる文字列そのものを数える。**
    func testAFullSizedReadActuallyStaysInsideItsShareOfTheBudget() {
        let source = (1...5_000)
            .map { "line \($0): the quick brown fox jumps over the lazy dog" }
            .joined(separator: "\n")

        let outcome = ContextWindow.clip(source, path: "big.log", budget: .singleRead)

        XCTAssertTrue(outcome.isClipped, "前提: 上限に当たるだけの大きさがあること")
        XCTAssertGreaterThan(outcome.includedLineCount, 0, "1行も入らないなら上限が小さすぎる")
        XCTAssertLessThanOrEqual(
            outcome.contextTokens, Budget.singleRead,
            "読み取り1回が、配分表で自分に配られた分を超えている")
    }

    /// **日本語のファイルでも、配られた分に収まること。**
    /// 日本語は概算で 0.74 tok/字 ── ASCII の3倍近い。**片方だけで確かめない。**
    func testAJapaneseReadAlsoStaysInsideItsShare() {
        let source = (1...2_000)
            .map { "\($0)行目。ここに日本語の本文が入っている。" }
            .joined(separator: "\n")

        let outcome = ContextWindow.clip(source, path: "日本語.md", budget: .singleRead)

        XCTAssertTrue(outcome.isClipped)
        XCTAssertGreaterThan(outcome.includedLineCount, 0)
        XCTAssertLessThanOrEqual(outcome.contextTokens, Budget.singleRead)
    }

    /// **栞の取り置きが、往復の上限ぶんの栞を実際に賄えること。**
    ///
    /// 栞は `ContextTranscript` が落とせない ── 落とせるのは生の読み取りだけである。
    /// **落とせないものは、必ず先に場所を取っておかなければならない。**
    ///
    /// 数えるのは**実物の栞**である。「1行だからだいたい何トークン」で見積もらない ──
    /// 見積もりと実物がずれた瞬間、取り置きは足りなくなる。
    func testTheBookmarkReserveCoversTheRoundTripLimit() throws {
        let callLimit = try Self.defaultCallLimit()
        XCTAssertGreaterThan(callLimit, 0)
        let counter = TokenCounter.estimate

        // 読み取りの栞（一番多い形）。
        let read = ContextWindow.clip(
            (1...400).map { "line \($0)" }.joined(separator: "\n"),
            path: "docs/notes.md", window: ReadWindow(offset: 1, limit: 80),
            budget: .singleRead)
        let readBookmark = counter(read.bookmarkLine)

        // 一覧の栞。**隠しファイルの断りが付く形が「普通のフォルダ」である**
        // （`.DS_Store` はどこにでもある）。断りを含めて数えること。
        let listing = ReadOutcome(
            path: "docs の一覧（10件）／隠し 1件は非表示（取得できません）",
            totalLines: 10, totalBytes: 400,
            firstLine: 1, lastLine: 10, partialLine: nil, body: "",
            reason: .none, tokenBudget: Budget.singleRead, contextTokens: 0,
            tokensAreEstimated: true, includesInjectionGuard: true)
        let listingBookmark = counter(listing.bookmarkLine)

        let worst = max(readBookmark, listingBookmark)
        XCTAssertLessThanOrEqual(
            worst * callLimit, Budget.bookmarks,
            """
            栞 \(callLimit)件（\(worst)トークン × \(callLimit)）が取り置き \(Budget.bookmarks) を超えた。
            **栞は落とせない。** 文言を伸ばしたなら取り置きも動かすこと ──
            動かせば配分表が閉じなくなり、testTheAllocationAddsUpToTheTotalExactly が落ちる。
            そこで初めて「どこから取るか」を決めることになる。
            """)
    }

    // =========================================================================
    //  3. 超えたときに、会話が止まらないこと
    // =========================================================================

    /// **予算を超えても例外にならないこと。**
    ///
    /// `armed` にした瞬間に会話が続かなくなるのが一番まずい失敗である。
    /// 止める場所は2つありえて、**どちらも止めない**のが正しい ──
    ///
    /// | | 何が起きるか |
    /// |---|---|
    /// | `inputTokenBudget`（1,000） | **投げない。**UI の警告だけ（`ChatViewModel.inputBudgetExceeded`） |
    /// | `contextLength`（8,192） | ここだけが `.contextOverflow` を投げる（`MLXEngine`） |
    ///
    /// **配分表の総額は `contextLength` よりずっと小さい。**
    /// つまり配分表を超えても、投げる側の壁にはまだ遠い。
    func testExceedingTheInputBudgetIsNotTheWallThatThrows() {
        XCTAssertLessThan(
            Budget.total, SophiaDefaults.contextLength,
            "予算が上限に届いていると、予算超過がそのまま送信不能になる")

        // armed の1ターンで、アプリ自身が入れる分の最大。
        let appSide = Budget.fixedCost(armed: true) + Budget.singleRead + Budget.bookmarks
        XCTAssertLessThan(
            appSide, SophiaDefaults.contextLength,
            "armed にしただけで `.contextOverflow` に届くなら、会話が始まらない")
    }

    /// **収まらないときは、古い読み取りが栞へ落ちて会話が続くこと**（16.3節 第2段）。
    ///
    /// 「収まらない」を例外にしていないこと自体が設計判断である
    /// （`ContextTranscript.fit` の但し書き。**利用者に実行不可能な助言を返さない**ため）。
    func testWhenTheTurnDoesNotFitTheOldestReadIsDemotedAndTheTurnStillHasContent() {
        func read(_ path: String) -> ReadOutcome {
            ContextWindow.clip(
                (1...2_000).map { "line \($0): padding padding padding" }.joined(separator: "\n"),
                path: path, budget: .singleRead)
        }

        let entries: [ContextEntry] = [
            .message(.system(SophiaDefaults.systemPrompt)),
            .message(.user("この3つを見て")),
            .read(read("a.log")), .read(read("b.log")), .read(read("c.log")),
        ]

        let fit = ContextTranscript.fit(entries, budget: Budget.transcript(armed: true))

        XCTAssertGreaterThan(fit.demotedReads, 0, "落とさずに済むなら、この前提が壊れている")
        XCTAssertFalse(fit.messages.isEmpty, "空の送信列を返してはいけない")
        XCTAssertTrue(
            fit.messages.contains { $0.content.contains("この3つを見て") },
            "利用者の発言まで落としていないこと")

        // **一番新しい読み取りは生のまま残ること。** 落とすのは古いほうからである
        // （新しいほうは、いままさに答えさせようとしている往復の材料）。
        let joined = fit.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(joined.contains(ReadOutcome.openDelimiter), "生の読み取りが1つも残っていない")
        XCTAssertTrue(joined.contains("読んだ: a.log"), "落とした側は栞になって残ること")
    }

    /// **落とせるものが尽きても、値で返ること**（`fits == false` は例外ではない）。
    func testAnImpossiblyTightTurnReturnsAValueInsteadOfFailing() {
        let entries: [ContextEntry] = [
            .message(.system(SophiaDefaults.systemPrompt)),
            .message(.user("短い一文")),
        ]
        let fit = ContextTranscript.fit(entries, budget: 1)

        XCTAssertFalse(fit.fits, "収まっていないなら、収まったと言わないこと")
        XCTAssertFalse(fit.messages.isEmpty)
    }

    // =========================================================================
    //  4. 配分表が「見える」ことそのもの
    // =========================================================================

    /// **`armed` の間、利用者に残る分がいくらなのかを、表が言えること。**
    ///
    /// この表明は「小さすぎないこと」を求めていない ── **求めれば数字をいじって緑にできる。**
    /// 求めているのは「**言えること**」だけである。
    /// いまの答えは 33トークン（日本語で約45字）で、それは
    /// `SophiaDefaults.InputBudget` の型コメントが「表の結論」として名指ししている。
    func testTheTableCanStateWhatIsLeftForTheUser() {
        let appSide =
            Budget.fixedCost(armed: true) + Budget.singleRead + Budget.bookmarks
        XCTAssertEqual(
            Budget.total - appSide, Budget.userText,
            "利用者に残る分が、表の `userText` と一致しないなら、表はもう内訳を説明していない")
    }

    // MARK: - 道具

    /// `FolderToolRunner` の既定の往復上限（16.8節）。**literal を書かない** ──
    /// 書いた瞬間、あちらを変えてもここが追随しなくなる。
    private static func defaultCallLimit() throws -> Int {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SophiaBudget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = try SecurityScopedFolder.unscoped(directoryURL: directory)
        return FolderToolRunner(folder: folder).callLimit
    }
}
