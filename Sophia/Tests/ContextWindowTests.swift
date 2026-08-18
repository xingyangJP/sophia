import Foundation
import XCTest
@testable import Sophia

/// 読んだ内容を文脈へ入れる前に切り詰める層（DESIGN.md 第16.3節）の境界。
///
/// ## ここで固定したいのは「切ったこと」であって「切ったこと」ではない
///
/// 切る処理そのものは、間違えても目に見える。**危ないのは、切ったのに切っていないように
/// 見えることのほうである。** モデルは 80行を見て 412行のファイルについて断定する ─
/// 見ていない 332行の存在を知らないので、保留しない。**静かに嘘をつく実装になる。**
///
/// したがって、このファイルで一番落としてはいけないのは
/// `testClipAlwaysAnnouncesThatItIsPartialAndTheTotal` である。
/// 見出しの文言を「トークンがもったいないから」と削る変更が入ったとき、
/// 落ちるべきテストがそれにあたる。
///
/// ## モデルもファイルも要らない
///
/// この層は純粋な値の変換なので、実ファイルも実モデルも置かずに境界を踏める。
/// 空ファイル・改行の無い20万文字・上限ちょうど ── どれも実ファイルで作るのは面倒で、
/// 作ったところで再現性が落ちる。**そのために副作用を持たせていない。**
final class ContextWindowTests: XCTestCase {

    // MARK: - 境界1: 空ファイル

    /// 空のファイルは「切った」ではない。**0行 の理由が2つあることを取り違えないこと。**
    func testEmptyFileIsNotClippedAndSaysItIsEmpty() {
        let outcome = ContextWindow.clip("", path: "empty.md", counter: .characters)

        XCTAssertEqual(outcome.totalLines, 0)
        XCTAssertEqual(outcome.totalBytes, 0)
        XCTAssertEqual(outcome.reason, .none)
        XCTAssertFalse(outcome.isClipped, "空のファイルを『切った』と言わないこと")
        XCTAssertEqual(outcome.body, "")
        XCTAssertEqual(outcome.includedLineCount, 0)
        XCTAssertNil(outcome.clipNotice)
        XCTAssertNil(outcome.nextOffset)

        XCTAssertEqual(outcome.headerLine, "[ファイル empty.md / 空のファイル（0行 / 0バイト）]")
        XCTAssertEqual(outcome.bookmarkLine, "読んだ: empty.md（空のファイル）")

        // 中身が無いときに区切りだけ置くとトークンの無駄になる。
        XCTAssertFalse(outcome.contextText.contains(ReadOutcome.openDelimiter))
        XCTAssertFalse(outcome.contextText.contains(ReadOutcome.closeDelimiter))
    }

    // MARK: - 境界2: 1行

    func testSingleLineFileIsReturnedWhole() {
        let outcome = ContextWindow.clip("たった1行", path: "one.md", counter: .characters)

        XCTAssertEqual(outcome.totalLines, 1)
        XCTAssertFalse(outcome.isClipped)
        XCTAssertEqual(outcome.body, "たった1行")
        XCTAssertEqual(outcome.firstLine, 1)
        XCTAssertEqual(outcome.lastLine, 1)
        XCTAssertEqual(outcome.includedLineCount, 1)
        XCTAssertNil(outcome.nextOffset, "続きが無いのに『続きは』と言わないこと")

        XCTAssertTrue(outcome.headerLine.contains("全1行すべて"))
        XCTAssertEqual(outcome.bookmarkLine, "読んだ: one.md（全1行すべて）")
        XCTAssertTrue(outcome.contextText.contains(ReadOutcome.openDelimiter))
        XCTAssertTrue(outcome.contextText.contains(ReadOutcome.closeDelimiter))
    }

    /// 末尾の改行で行が1つ増えないこと。**増えると総行数の申告が常に1多くなる。**
    ///
    /// ## CRLF は「途中」ではなく「末尾」で踏むこと
    ///
    /// **2026-08-18 追加。** ここは `"a\r\nb"`（CRLF が**途中**にある形）しか踏んでいなかった。
    /// ところが穴はちょうど**末尾**にあり、`"a\r\n"` は 2行 と数えられていた ──
    /// `hasSuffix("\n")` が `Character` 単位で、Swift の `Character` は
    /// **CRLF を1文字として扱う**ので、末尾の空要素が落ちなかった。
    /// 途中の CRLF だけを踏んでいるかぎり、この行はいつまでも緑のままである。
    func testLineSplittingBoundaries() {
        func split(_ text: String) -> [String] {
            ContextWindow.lines(of: text).map(String.init)
        }
        XCTAssertEqual(split(""), [], "空のファイルは 0行。『1行の空行』ではない")
        XCTAssertEqual(split("a"), ["a"])
        XCTAssertEqual(split("a\n"), ["a"], "末尾の改行で空行が増えないこと")
        XCTAssertEqual(split("a\nb"), ["a", "b"])
        XCTAssertEqual(split("a\n\n"), ["a", ""], "途中の空行は行である")
        XCTAssertEqual(split("\n"), [""])
        // CRLF は行の中身として残す。落とすと「原文の部分列」と言えなくなる。
        XCTAssertEqual(split("a\r\nb"), ["a\r", "b"])
        // **末尾の CRLF でも行が増えないこと**（`Character` 単位で末尾を見ると増える）。
        XCTAssertEqual(split("a\r\n"), ["a\r"], "CRLF で終わるファイルが1行多く数えられている")
        XCTAssertEqual(split("a\r\nb\r\n"), ["a\r", "b\r"])
        XCTAssertEqual(split("\r\n"), ["\r"])
        XCTAssertEqual(split("a\r\n\r\n"), ["a\r", "\r"], "CRLF の空行は行である")

        // **窓の本文は数え方が違う。** 読み手は行を `\n` で**連結して**返すので、
        // そこでの末尾の `\n` は終端ではなく区切りである（`windowLines(of:)` の但し書き）。
        // 同じ文字列を同じ関数で数えると、末尾の空行が受け渡しで消える。
        func windowSplit(_ text: String) -> [String] {
            ContextWindow.windowLines(of: text).map(String.init)
        }
        XCTAssertEqual(windowSplit(""), [], "1行も読めなかった窓は 0行")
        XCTAssertEqual(windowSplit("a"), ["a"])
        XCTAssertEqual(windowSplit("a\n"), ["a", ""], "窓では末尾の改行は区切り（2行目は空行）")
        XCTAssertEqual(windowSplit("a\nb"), ["a", "b"])
        XCTAssertEqual(windowSplit("\n"), ["", ""])
    }

    func testSingleLineFileThatIsTooLongForTheBudgetStillReportsOneLine() {
        let source = String(repeating: "あ", count: 400)
        // 見出しは入るが本文 400文字 は入らない上限。行を諦めて文字で切る経路に落ちる。
        let outcome = ContextWindow.clip(
            source, path: "one.md", budget: ContextBudget(tokens: 300), counter: .characters)

        XCTAssertEqual(outcome.totalLines, 1)
        XCTAssertTrue(outcome.isClipped)
        XCTAssertEqual(outcome.reason, .withinLine)
    }

    // MARK: - 境界3/4: ちょうど上限 / 上限+1

    /// 上限**ちょうど**は収まる（`<` ではなく `<=` で判定していること）。
    ///
    /// 実測してから上限をその値に置くことで、境界をぴたりと踏んでいる。
    /// 定数を書くと、見出しの文言を1文字変えただけでテストの意図が崩れる。
    ///
    /// ## `offset` を掃くこと（2026-08-18）
    ///
    /// ここは `offset=1` しか踏んでいなかった。**それは切り詰めの近道が覆っていた唯一の場合**で、
    /// 「窓が終端に届くと丸ごと入るのに切られる」という欠陥は、ちょうどこの隙間から漏れていた
    /// （終端に届くと断り書きから「続きは offset=N から」が消えて全体が**縮み**、
    /// 挟み込み探索がその1点を飛び越える）。
    /// **`offset=1` は、この層でいちばん通る道ではない** ── モデルが続きを読むときは必ず `offset>1` である。
    func testExactlyAtTheBudgetIsNotClipped() {
        let source = (1...20).map { "line \($0)" }.joined(separator: "\n")

        for offset in [1, 2, 3, 7, 20] {
            let window = ReadWindow(offset: offset)
            let whole = ContextWindow.clip(
                source, path: "b.txt", window: window,
                budget: ContextBudget(tokens: 100_000), counter: .characters)

            let exact = ContextWindow.clip(
                source, path: "b.txt", window: window,
                budget: ContextBudget(tokens: whole.contextTokens), counter: .characters)

            // **「切られていない」を `isClipped` で測れるのは offset=1 のときだけである。**
            // 窓が狭ければ `.lineWindow` で「一部です」と言うのが正しい ─ 測りたいのは
            // 「上限ちょうどでも、**その窓の中身は1行も落ちない**」ことのほうである。
            XCTAssertEqual(
                exact.includedLineCount, whole.includedLineCount,
                "上限ちょうどで窓が切られた（offset=\(offset) / \(exact.reason.rawValue)）")
            XCTAssertEqual(exact.body, whole.body, "offset=\(offset)")
            XCTAssertEqual(exact.reason, whole.reason, "offset=\(offset)")
            XCTAssertEqual(exact.contextTokens, whole.contextTokens, "offset=\(offset)")
            if offset == 1 {
                XCTAssertFalse(whole.isClipped, "前提: 上限が十分なら切られない")
                XCTAssertFalse(exact.isClipped, "上限ちょうどは収まる")
            }
        }
    }

    /// 上限を1つ下げたら切れる。**上限が効いていることの対偶側。**
    func testOneTokenOverTheBudgetIsClipped() {
        let source = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let whole = ContextWindow.clip(
            source, path: "b.txt", budget: ContextBudget(tokens: 100_000), counter: .characters)

        let over = ContextWindow.clip(
            source, path: "b.txt",
            budget: ContextBudget(tokens: whole.contextTokens - 1), counter: .characters)

        XCTAssertTrue(over.isClipped)
        XCTAssertEqual(over.reason, .tokenBudget)
        XCTAssertLessThanOrEqual(over.contextTokens, whole.contextTokens - 1)
        XCTAssertLessThan(over.includedLineCount, whole.includedLineCount)
        XCTAssertNotNil(over.nextOffset)
        XCTAssertEqual(over.nextOffset, (over.lastLine ?? 0) + 1)
    }

    /// 上限を1ずつ動かしても、入る行数が飛んだり戻ったりしないこと。
    ///
    /// ## 「減らない」だけでは足りない（2026-08-18）
    ///
    /// 単調性だけを見ていると、**丸ごと入るのに切っている**状態を素通りする ──
    /// 少なく入れ続けても「減ってはいない」からである。
    /// 実際、`offset=7`（窓は 34行）で上限を 380 に置くと **31行**しか入っていなかった。
    /// 34行ぜんぶで 380 に収まるのに、である。
    /// **入るなら入れる**ことを、実測した「丸ごとの大きさ」と突き合わせて測る。
    func testIncludedLinesGrowMonotonicallyWithTheBudget() {
        let source = (1...40).map { "line \($0)" }.joined(separator: "\n")

        for offset in [1, 2, 3, 7, 11] {
            let window = ReadWindow(offset: offset)
            let whole = ContextWindow.clip(
                source, path: "m.txt", window: window,
                budget: ContextBudget(tokens: 100_000), counter: .characters)

            var previous = 0
            for budget in stride(from: 40, through: 500, by: 1) {
                let outcome = ContextWindow.clip(
                    source, path: "m.txt", window: window,
                    budget: ContextBudget(tokens: budget), counter: .characters)
                XCTAssertGreaterThanOrEqual(
                    outcome.includedLineCount, previous,
                    "上限を増やしたのに入る行が減った（budget=\(budget) / offset=\(offset)）")
                if budget >= whole.contextTokens {
                    XCTAssertEqual(
                        outcome.includedLineCount, whole.includedLineCount,
                        "丸ごと入る上限なのに切っている（budget=\(budget) / offset=\(offset)）")
                }
                previous = outcome.includedLineCount
            }
            XCTAssertEqual(previous, 40 - offset + 1, "十分な上限では窓の全部が入る（offset=\(offset)）")
        }
    }

    // MARK: - 境界5: 巨大ファイル

    func testHugeFileIsClippedAndStillReportsTheRealTotal() {
        let lineCount = 20_000
        let source = (1...lineCount)
            .map { "line \($0): the quick brown fox jumps over the lazy dog" }
            .joined(separator: "\n")

        let outcome = ContextWindow.clip(source, path: "huge.log", budget: .singleRead)

        XCTAssertTrue(outcome.isClipped)
        XCTAssertEqual(outcome.reason, .tokenBudget)
        XCTAssertEqual(outcome.totalLines, lineCount, "**総行数は必ず本当の値**")
        XCTAssertEqual(outcome.totalBytes, source.utf8.count)
        XCTAssertGreaterThan(outcome.includedLineCount, 0, "1行も返さないのは読めなかったのと同じ")
        XCTAssertLessThan(outcome.includedLineCount, lineCount)
        XCTAssertLessThanOrEqual(outcome.contextTokens, ContextBudget.singleRead.tokens)

        XCTAssertTrue(outcome.contextText.contains("全\(lineCount)行"))
        XCTAssertTrue(outcome.contextText.contains("これは一部です"))
        XCTAssertEqual(outcome.nextOffset, outcome.includedLineCount + 1)
        XCTAssertTrue(source.contains(outcome.body), "本文は原文の連続した一部であること")
    }

    // MARK: - 境界6: 日本語とASCIIの混在

    /// **上限がトークンであってバイトでも文字数でもないこと。**
    ///
    /// ASCII の行は日本語の行より**文字数では長い**（43文字 対 18文字）のに、
    /// **トークンでは短い**（0.25/文字 対 0.74/文字）。
    /// したがって同じ上限なら ASCII のほうが**多くの行**が入る。
    /// 文字数で切っていたら、この不等号は必ず逆になる。
    func testBudgetIsCountedInTokensNotCharacters() {
        let japaneseLine = "日本語の行です。あいうえおかきくけこ"
        let asciiLine = "the quick brown fox jumps over the lazy dog"
        XCTAssertGreaterThan(
            asciiLine.count, japaneseLine.count, "前提: ASCII の行のほうが文字数では長い")

        let budget = ContextBudget(tokens: 600)
        let japanese = ContextWindow.clip(
            Array(repeating: japaneseLine, count: 200).joined(separator: "\n"),
            path: "japanese.txt", budget: budget)
        let ascii = ContextWindow.clip(
            Array(repeating: asciiLine, count: 200).joined(separator: "\n"),
            path: "ascii.txt", budget: budget)

        XCTAssertTrue(japanese.isClipped)
        XCTAssertTrue(ascii.isClipped)
        XCTAssertGreaterThan(
            ascii.includedLineCount, japanese.includedLineCount,
            "文字数で切っていればこの不等号は逆になる（PROGRESS.md 発見19）")
        XCTAssertLessThanOrEqual(japanese.contextTokens, budget.tokens)
        XCTAssertLessThanOrEqual(ascii.contextTokens, budget.tokens)
    }

    /// 1つのファイルの中で混ざっていても壊れないこと（コードとコメントの実際の姿）。
    func testMixedJapaneseAndAsciiInOneFile() {
        let source = (1...200).map { index in
            index.isMultiple(of: 2)
                ? "    // ここでトークン数を数えている（第\(index)行）"
                : "    let tokens = counter(outcome.contextText)  // line \(index)"
        }.joined(separator: "\n")

        let outcome = ContextWindow.clip(source, path: "Mixed.swift", budget: .singleRead)

        XCTAssertTrue(outcome.isClipped)
        XCTAssertLessThanOrEqual(outcome.contextTokens, ContextBudget.singleRead.tokens)
        XCTAssertTrue(source.contains(outcome.body))
        XCTAssertTrue(outcome.contextText.contains("全200行"))
    }

    // MARK: - 境界7: 改行が無い1行だけの巨大ファイル

    /// **行単位のままでは 0行 しか返せない場合。**
    ///
    /// 1行の JSON、minify 済みのコード、ログの1行 ── どれも普通に存在する。
    /// ここで 0行 を返すと「読めなかった」と同じで、モデルは中身を知らないまま答える。
    /// 行を諦めて**文字で切る**が、**そのとき `nextOffset` を出してはいけない** ─
    /// 行単位の `offset` ではその行の残りへ戻れないので、
    /// 「続きは offset=2 から」と言うと**読み飛ばした文字を読んだつもりにさせる。**
    func testGiantSingleLineWithoutNewlinesIsTruncatedWithinTheLine() throws {
        let source = String(repeating: "{\"key\":\"value\"},", count: 12_500)  // 20万文字・改行なし
        XCTAssertFalse(source.contains("\n"), "前提: 改行が1つも無い")

        let outcome = ContextWindow.clip(source, path: "one-line.json", budget: .singleRead)

        XCTAssertEqual(outcome.totalLines, 1)
        XCTAssertEqual(outcome.reason, .withinLine)
        XCTAssertTrue(outcome.isClipped)
        XCTAssertNil(outcome.nextOffset, "行の途中で切ったのに『続きは offset=』と言わないこと")

        let partial = try XCTUnwrap(outcome.partialLine)
        XCTAssertEqual(partial.line, 1)
        XCTAssertEqual(partial.totalCharacters, source.count)
        XCTAssertGreaterThan(partial.includedCharacters, 0, "1文字も返さないのは無意味")
        XCTAssertLessThan(partial.includedCharacters, source.count)

        XCTAssertEqual(outcome.body, String(source.prefix(partial.includedCharacters)))
        XCTAssertLessThanOrEqual(outcome.contextTokens, ContextBudget.singleRead.tokens)

        XCTAssertTrue(outcome.contextText.contains("これは一部です"))
        XCTAssertTrue(outcome.contextText.contains("この行の残りは offset では読めません"))
        XCTAssertTrue(outcome.bookmarkLine.contains("1行目の先頭"))
    }

    /// 日本語の巨大な1行でも、文字の途中（結合文字の内側）で割らないこと。
    func testGiantSingleLineOfJapaneseIsTruncatedOnCharacterBoundaries() {
        let source = String(repeating: "日本語の長い1行です。", count: 20_000)
        let outcome = ContextWindow.clip(source, path: "long.txt", budget: .singleRead)

        XCTAssertEqual(outcome.reason, .withinLine)
        XCTAssertTrue(source.hasPrefix(outcome.body))
        XCTAssertLessThanOrEqual(outcome.contextTokens, ContextBudget.singleRead.tokens)
    }

    // MARK: - 切ったことを必ず言う（この層の存在理由）

    /// **上限をどう動かしても、切ったなら切ったと書いてあること。**
    ///
    /// このテストが落ちる変更は、たいてい「見出しがトークンを食うので削った」である。
    /// 削ってよいかは、削ったうえでモデルが正しく保留できるかを測ってから決めること
    /// （DESIGN.md 第16.9節 項目9）。**測る前に削ると、静かに嘘をつく実装になる。**
    func testClipAlwaysAnnouncesThatItIsPartialAndTheTotal() {
        let source = (1...60).map { "行 \($0): 内容の本体がここにある" }.joined(separator: "\n")

        for budget in stride(from: 40, through: 900, by: 7) {
            let outcome = ContextWindow.clip(
                source, path: "notes.md", budget: ContextBudget(tokens: budget))
            let text = outcome.contextText

            // 総量は、切っていてもいなくても必ず出る。
            XCTAssertTrue(
                text.contains("全60行"),
                "総行数が出ていない（budget=\(budget) / reason=\(outcome.reason.rawValue)）")

            if outcome.isClipped {
                guard let notice = outcome.clipNotice else {
                    XCTFail("切ったのに断り書きが無い（budget=\(budget)）")
                    continue
                }
                XCTAssertTrue(
                    text.contains(notice),
                    "断り書きが本文に入っていない（budget=\(budget)）")
                if outcome.reason == .tokenBudget || outcome.reason == .lineWindow
                    || outcome.reason == .withinLine {
                    XCTAssertTrue(
                        text.contains("これは一部です"),
                        "『一部である』と文で書いていない（budget=\(budget)）")
                }
            } else {
                XCTAssertNil(outcome.clipNotice)
                XCTAssertFalse(
                    text.contains("これは一部です"),
                    "全部入っているのに一部だと言っている（budget=\(budget)）")
                XCTAssertTrue(text.contains("全60行すべて"))
            }
        }
    }

    /// 上限を守れていること。**`.budgetTooSmall` だけが例外**で、
    /// そのときは見出しだけで超えている（黙って空を返すより、超えたと言うほうがまし）。
    func testContextTokensNeverExceedTheBudget() {
        let source = (1...60).map { "行 \($0): 内容の本体がここにある" }.joined(separator: "\n")

        for budget in stride(from: 5, through: 900, by: 3) {
            let outcome = ContextWindow.clip(
                source, path: "notes.md", budget: ContextBudget(tokens: budget))
            guard outcome.reason != .budgetTooSmall else { continue }
            XCTAssertLessThanOrEqual(
                outcome.contextTokens, budget,
                "上限 \(budget) に対して \(outcome.contextTokens) を入れようとしている")
        }
    }

    /// 本文を作らない・省略記号を混ぜない。**要約は第3段であって、本章では入れない。**
    ///
    /// ## 計器を `String.contains` から**バイト列**へ替えてある（2026-08-18）
    ///
    /// 測りたいのは「**原文のバイトをそのまま切り出したか**」であって、
    /// 「`Character` として部分列か」ではない。この2つは CRLF でずれる ──
    /// Swift の `Character` は **CRLF を1文字として扱う**ので、
    /// 原文 `"a\r\nb"` の中に `"\r"` 単体は存在しない。1行目だけを取った本文 `"a\r"` は
    /// **バイト列としては原文の先頭2バイトそのもの**なのに、`source.contains(body)` は
    /// **false を返す** ── つまり**実装が正しいままテストが落ちる。**
    ///
    /// 元の本文（LF だけ）に CRLF を1つ足せなかったのはそのためであり、
    /// **計器がずれているせいで、踏むべき入力を足せない状態になっていた。**
    /// 計器を替えたので CRLF の本文をここへ足せる。
    /// （同じ話の詳細は `AdversarialContextTests` の
    /// `testBodyIsAContiguousRunOfSourceBytesEvenWhereGraphemesDisagree`）
    func testBodyIsAlwaysAContiguousPieceOfTheSource() {
        let sources = [
            (1...60).map { "行 \($0): 内容の本体がここにある" }.joined(separator: "\n"),
            // **CRLF の本文。** `String.contains` で測っていたころは足せなかった入力である。
            (1...60).map { "行 \($0): 内容の本体がここにある" }.joined(separator: "\r\n") + "\r\n",
        ]

        for source in sources {
            for budget in stride(from: 20, through: 900, by: 11) {
                let outcome = ContextWindow.clip(
                    source, path: "notes.md", budget: ContextBudget(tokens: budget))
                guard !outcome.body.isEmpty else { continue }
                XCTAssertTrue(
                    Self.bytesContain(outcome.body, in: source),
                    "本文が原文のバイト列の連続部分になっていない（budget=\(budget)）: "
                    + outcome.body.debugDescription)
            }
        }
    }

    // MARK: - 窓（offset / limit）

    func testWindowSelectsTheRequestedLines() {
        let source = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let outcome = ContextWindow.clip(
            source, path: "w.txt",
            window: ReadWindow(offset: 5, limit: 3),
            budget: ContextBudget(tokens: 10_000), counter: .characters)

        XCTAssertEqual(outcome.firstLine, 5)
        XCTAssertEqual(outcome.lastLine, 7)
        XCTAssertEqual(outcome.includedLineCount, 3)
        XCTAssertEqual(outcome.body, "line 5\nline 6\nline 7")
        XCTAssertEqual(outcome.reason, .lineWindow, "上限ではなく窓で切れたこと")
        XCTAssertEqual(outcome.nextOffset, 8)
        XCTAssertEqual(outcome.bookmarkLine, "読んだ: w.txt（全10行のうち 5-7行）")
    }

    func testWindowThatReachesTheEndHasNoContinuation() {
        let source = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let outcome = ContextWindow.clip(
            source, path: "w.txt",
            window: ReadWindow(offset: 8, limit: 50),
            budget: ContextBudget(tokens: 10_000), counter: .characters)

        XCTAssertEqual(outcome.firstLine, 8)
        XCTAssertEqual(outcome.lastLine, 10)
        XCTAssertTrue(outcome.isClipped, "1-7行 が入っていないので『全部』ではない")
        XCTAssertNil(outcome.nextOffset)
        XCTAssertFalse(
            outcome.contextText.contains("続きは"), "続きが無いのに続きを案内しないこと")
        XCTAssertTrue(outcome.contextText.contains("これは一部です"))
    }

    /// `limit` に 0 や負が来ても「0行」と解釈しない。**何も返さない戻り値は役に立たない。**
    func testNonPositiveLimitMeansNoLineLimit() {
        let source = (1...10).map { "line \($0)" }.joined(separator: "\n")
        for limit in [0, -1] {
            let outcome = ContextWindow.clip(
                source, path: "w.txt",
                window: ReadWindow(offset: 1, limit: limit),
                budget: ContextBudget(tokens: 10_000), counter: .characters)
            XCTAssertEqual(outcome.includedLineCount, 10, "limit=\(limit)")
            XCTAssertFalse(outcome.isClipped, "limit=\(limit)")
        }
    }

    func testOffsetBelowOneIsClampedToTheFirstLine() {
        let source = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let outcome = ContextWindow.clip(
            source, path: "w.txt",
            window: ReadWindow(offset: 0, limit: 2),
            budget: ContextBudget(tokens: 10_000), counter: .characters)
        XCTAssertEqual(outcome.firstLine, 1)
        XCTAssertEqual(outcome.lastLine, 2)
    }

    /// 範囲外は「空のファイル」と同じ扱いにしない。**読めていないことを言う。**
    func testOffsetBeyondTheEndOfTheFileSaysSo() {
        let source = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let outcome = ContextWindow.clip(
            source, path: "w.txt",
            window: ReadWindow(offset: 500),
            budget: ContextBudget(tokens: 10_000), counter: .characters)

        XCTAssertEqual(outcome.reason, .outOfRange)
        XCTAssertTrue(outcome.isClipped)
        XCTAssertEqual(outcome.body, "")
        XCTAssertEqual(outcome.includedLineCount, 0)
        XCTAssertTrue(outcome.contextText.contains("全10行"))
        XCTAssertTrue(outcome.contextText.contains("1〜10"), "有効な範囲を教えて往復を続けさせる")
        XCTAssertTrue(outcome.bookmarkLine.contains("読めた範囲なし"))
    }

    // MARK: - 上限が小さすぎる場合

    /// 見出しすら入らない上限でも、**止まらず・黙らず**に返すこと。
    func testBudgetTooSmallSaysSoInsteadOfReturningSilentlyEmpty() {
        let source = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let outcome = ContextWindow.clip(
            source, path: "w.txt", budget: ContextBudget(tokens: 3), counter: .characters)

        XCTAssertEqual(outcome.reason, .budgetTooSmall)
        XCTAssertTrue(outcome.isClipped)
        XCTAssertEqual(outcome.body, "")
        XCTAssertTrue(outcome.contextText.contains("小さすぎて"))
        XCTAssertTrue(outcome.contextText.contains("全10行"), "総量だけは必ず言う")
    }

    // MARK: - トークンの数え方は外から差し替えられる

    /// **既定は概算。`isEstimate` が結果まで運ばれること**（発見19: 概算は 1.47倍 甘い）。
    func testDefaultCounterIsTheEstimateAndSaysSo() {
        let outcome = ContextWindow.clip("行1\n行2", path: "a.txt")
        XCTAssertTrue(
            outcome.tokensAreEstimated,
            "概算で切ったのに正確に切ったように見せないこと")
        XCTAssertEqual(TokenCounter.estimate.name, "概算（文字種別）")
    }

    /// 数え方を差し替えると、切れ方がその数え方に従うこと。
    /// **概算が層の中に埋め込まれていたら、この2本はどちらも通らない。**
    func testTokenCounterIsInjectable() {
        let source = (1...100).map { "line \($0)" }.joined(separator: "\n")

        // 何を渡しても 0 と数える器 → 上限が 1 でも切られない。
        let free = TokenCounter.exact(name: "テスト用（常に0）") { _ in 0 }
        let notClipped = ContextWindow.clip(
            source, path: "a.txt", budget: ContextBudget(tokens: 1), counter: free)
        XCTAssertFalse(notClipped.isClipped)
        XCTAssertEqual(notClipped.includedLineCount, 100)
        XCTAssertFalse(notClipped.tokensAreEstimated, "実測として渡した器の素性が残ること")

        // 何を渡しても巨大と数える器 → 上限が大きくても入らない。
        let expensive = TokenCounter.exact(name: "テスト用（常に巨大）") { _ in 1_000_000 }
        let alwaysTooBig = ContextWindow.clip(
            source, path: "a.txt", budget: ContextBudget(tokens: 100_000), counter: expensive)
        XCTAssertEqual(alwaysTooBig.reason, .budgetTooSmall)
    }

    /// 実トークナイザを挿す想定の経路。**この層は MLX を知らないまま差し替わる。**
    func testExactCounterReplacesTheEstimateWithoutTouchingThisLayer() {
        let source = (1...50).map { "line \($0)" }.joined(separator: "\n")

        // 実トークナイザの代わり（1トークン=4文字、という別の数え方）。
        let pretendTokenizer = TokenCounter.exact { text in
            Int(ceil(Double(text.count) / 4.0))
        }
        let outcome = ContextWindow.clip(
            source, path: "a.txt", budget: ContextBudget(tokens: 60), counter: pretendTokenizer)

        XCTAssertFalse(outcome.tokensAreEstimated)
        XCTAssertLessThanOrEqual(outcome.contextTokens, 60)
        XCTAssertEqual(outcome.contextTokens, Int(ceil(Double(outcome.contextText.count) / 4.0)))
    }

    // MARK: - 囲い文（16.6節 約束5）

    /// 効果が【未確認】なので、**あり/なしで走らせられること自体を固定する**（16.9節 項目9）。
    func testInjectionGuardCanBeTurnedOffForMeasurement() {
        let source = "秘密ではない普通の内容"
        let withGuard = ContextWindow.clip(
            source, path: "a.txt",
            budget: ContextBudget(tokens: 500, includesInjectionGuard: true), counter: .characters)
        let without = ContextWindow.clip(
            source, path: "a.txt",
            budget: ContextBudget(tokens: 500, includesInjectionGuard: false), counter: .characters)

        XCTAssertTrue(withGuard.contextText.contains(ReadOutcome.injectionGuard))
        XCTAssertFalse(without.contextText.contains(ReadOutcome.injectionGuard))
        XCTAssertLessThan(without.contextTokens, withGuard.contextTokens, "費用が測れること")

        // 区切りは囲い文を切っても残る。どこまでが中身かが分からなくなるため。
        XCTAssertTrue(without.contextText.contains(ReadOutcome.openDelimiter))
        XCTAssertTrue(without.contextText.contains(ReadOutcome.closeDelimiter))
        XCTAssertEqual(withGuard.body, without.body)
    }

    // MARK: - 第2段: 履歴を栞に置き換える

    /// 往復の最中は生のまま送る。**答えを書かせている材料を落とさないこと。**
    func testRawReadStaysUntilTheAssistantHasAnswered() {
        let read = Self.sampleRead(path: "notes.md", body: "NEEDLE-本文")
        let entries: [ContextEntry] = [.message(.user("notes.md を読んで")), .read(read)]

        let messages = ContextTranscript.engineMessages(from: entries)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1].role, .user, "ツールの戻り値は user ターンの中に入る（16.1節）")
        XCTAssertEqual(messages[1].content, read.contextText)
        XCTAssertTrue(messages[1].content.contains("NEEDLE-本文"))
    }

    /// 答えが出たら生の戻り値は落ちて、**栞1行**が残る。
    func testOlderReadsBecomeBookmarksOnceTheAnswerExists() {
        let read = Self.sampleRead(path: "notes.md", body: "NEEDLE-本文")
        let entries: [ContextEntry] = [
            .message(.user("notes.md を読んで")),
            .read(read),
            .message(.assistant("読みました。要点は…")),
            .message(.user("では次の質問")),
        ]

        let messages = ContextTranscript.engineMessages(from: entries)

        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[1].content, read.bookmarkLine)
        XCTAssertFalse(
            messages.contains { $0.content.contains("NEEDLE-本文") },
            "往復が終わった生の戻り値を送信列に残さないこと")
        XCTAssertFalse(
            messages.contains { $0.content.contains(ReadOutcome.openDelimiter) })
    }

    /// **栞は範囲を残す。** 落とすのは中身であって、読んだ事実と範囲ではない ─
    /// 範囲が消えると、次のターンのモデルは前の答えを全体についての結論として扱う。
    func testBookmarkKeepsTheRangeSoThePartialitySurvives() {
        let source = (1...412).map { "line \($0)" }.joined(separator: "\n")
        let read = ContextWindow.clip(
            source, path: "notes.md",
            window: ReadWindow(offset: 1, limit: 80),
            budget: ContextBudget(tokens: 10_000), counter: .characters)

        // DESIGN.md 第16.3節が例として示している文字列そのもの。
        XCTAssertEqual(read.bookmarkLine, "読んだ: notes.md（全412行のうち 1-80行）")

        let messages = ContextTranscript.engineMessages(from: [
            .read(read), .message(.assistant("答え")),
        ])
        XCTAssertEqual(messages.first?.content, "読んだ: notes.md（全412行のうち 1-80行）")
    }

    /// 連続する読み取りは1発言にまとめる（テンプレートの固定分を件数ぶん払わないため）。
    func testConsecutiveReadsAreMergedIntoOneMessage() {
        let a = Self.sampleRead(path: "a.md", body: "AAA")
        let b = Self.sampleRead(path: "b.md", body: "BBB")

        let raw = ContextTranscript.engineMessages(from: [.read(a), .read(b)])
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw[0].content, a.contextText + "\n\n" + b.contextText)

        let bookmarked = ContextTranscript.engineMessages(from: [
            .read(a), .read(b), .message(.assistant("答え")),
        ])
        XCTAssertEqual(bookmarked.count, 2)
        XCTAssertEqual(bookmarked[0].content, a.bookmarkLine + "\n" + b.bookmarkLine)
    }

    func testRawReadIndicesAreOnlyThoseAfterTheLastAssistantMessage() {
        let entries: [ContextEntry] = [
            .read(Self.sampleRead(path: "old.md", body: "旧")),
            .message(.assistant("答え1")),
            .read(Self.sampleRead(path: "new.md", body: "新")),
        ]
        XCTAssertEqual(ContextTranscript.rawReadIndices(in: entries), [2])
    }

    // MARK: - 送信前に量を見る（16.3節「送信前に見ること」）

    /// 収まらないときは**古い生の読み取りから**落とす。
    /// 新しいほうは、いままさに答えさせようとしている材料である。
    func testFitDemotesTheOldestRawReadFirst() {
        let a = Self.sampleRead(path: "a.md", body: String(repeating: "A", count: 300))
        let b = Self.sampleRead(path: "b.md", body: String(repeating: "B", count: 300))
        let entries: [ContextEntry] = [.read(a), .read(b)]

        func size(_ messages: [SophiaMessage]) -> Int {
            messages.reduce(0) { $0 + $1.content.count }
        }
        let bothRaw = size(ContextTranscript.engineMessages(from: entries, keepingRaw: [0, 1]))
        let oldestDropped = size(ContextTranscript.engineMessages(from: entries, keepingRaw: [1]))
        XCTAssertGreaterThan(bothRaw, oldestDropped, "前提: 落とせば減る")

        let fit = ContextTranscript.fit(entries, budget: oldestDropped, counter: .characters)

        XCTAssertTrue(fit.fits)
        XCTAssertEqual(fit.demotedReads, 1, "必要なぶんだけ落とすこと")
        XCTAssertEqual(fit.tokens, oldestDropped)
        XCTAssertTrue(
            fit.messages.contains { $0.content.contains(b.contextText) },
            "一番新しい読み取りは生のまま残ること")
        XCTAssertTrue(fit.messages.contains { $0.content.contains(a.bookmarkLine) })
    }

    /// これ以上落とせないときに「収まった」と偽らないこと。
    /// **`fits == false` はエラーではない** ─ 窓を狭めて読み直すのは上の層の仕事で、
    /// 利用者に「入力を短くしてください」と言う場面ではない（発見19 ③）。
    func testFitReportsFailureInsteadOfPretendingToFit() {
        let entries: [ContextEntry] = [
            .read(Self.sampleRead(path: "a.md", body: String(repeating: "A", count: 300))),
            .read(Self.sampleRead(path: "b.md", body: String(repeating: "B", count: 300))),
        ]

        let fit = ContextTranscript.fit(entries, budget: 1, counter: .characters)

        XCTAssertFalse(fit.fits)
        XCTAssertEqual(fit.demotedReads, 2, "落とせるものは全部落としたうえで報告すること")
        XCTAssertGreaterThan(fit.tokens, fit.budget)
        XCTAssertFalse(
            fit.messages.contains { $0.content.contains(ReadOutcome.openDelimiter) })
    }

    func testFitLeavesEverythingAloneWhenItAlreadyFits() {
        let entries: [ContextEntry] = [
            .message(.system("system")),
            .message(.user("読んで")),
            .read(Self.sampleRead(path: "a.md", body: "短い")),
        ]
        let fit = ContextTranscript.fit(entries, budget: 100_000, counter: .characters)

        XCTAssertTrue(fit.fits)
        XCTAssertEqual(fit.demotedReads, 0)
        XCTAssertEqual(fit.messages, ContextTranscript.engineMessages(from: entries))
    }

    /// テンプレートの固定分は**まだ測っていない**ので既定 0。
    /// 入れられる口があること自体を固定しておく（16.2節の測り方）。
    func testPerMessageOverheadIsAccountedWhenProvided() {
        let entries: [ContextEntry] = [.message(.user("abc")), .message(.assistant("de"))]

        let bare = ContextTranscript.fit(entries, budget: 1_000, counter: .characters)
        let withOverhead = ContextTranscript.fit(
            entries, budget: 1_000, counter: .characters, perMessageOverhead: 5)

        XCTAssertEqual(bare.tokens, 5)
        XCTAssertEqual(withOverhead.tokens, 5 + 5 * 2)
    }

    func testEmptyTranscriptProducesNoMessages() {
        XCTAssertEqual(ContextTranscript.engineMessages(from: []), [])
        let fit = ContextTranscript.fit([], budget: 10, counter: .characters)
        XCTAssertEqual(fit.messages, [])
        XCTAssertEqual(fit.tokens, 0)
        XCTAssertTrue(fit.fits)
    }

    // MARK: - 道具

    private static func sampleRead(path: String, body: String) -> ReadOutcome {
        ContextWindow.clip(
            body, path: path, budget: ContextBudget(tokens: 100_000), counter: .characters)
    }

    /// **バイト列としての連続部分列か。**
    ///
    /// `String.contains` は `Character` 単位なので、この用途には使えない ──
    /// CRLF をまたぐ本文で**実装が正しいまま false になる**
    /// （`testBodyIsAlwaysAContiguousPieceOfTheSource` の説明）。
    private static func bytesContain(_ needle: String, in haystack: String) -> Bool {
        let needleBytes = Array(needle.utf8)
        let haystackBytes = Array(haystack.utf8)
        guard !needleBytes.isEmpty else { return true }
        guard needleBytes.count <= haystackBytes.count else { return false }
        for start in 0...(haystackBytes.count - needleBytes.count)
        where Array(haystackBytes[start..<(start + needleBytes.count)]) == needleBytes {
            return true
        }
        return false
    }
}

private extension TokenCounter {
    /// **1文字=1トークン。境界をぴたりと踏むためのテスト用の器。**
    ///
    /// 概算（文字種別）で境界を書くと、係数を直したときにテストの意図まで動く。
    /// 「上限ちょうど」「上限+1」を確かめたいのであって、係数を確かめたいのではない。
    static let characters = TokenCounter(
        name: "テスト用（1文字=1トークン）",
        isEstimate: false
    ) { $0.count }
}
