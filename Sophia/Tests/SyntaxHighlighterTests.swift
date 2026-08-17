import XCTest
@testable import Sophia

/// コードブロックの色分け（FR-06 / A1 完成条件7）。
///
/// ## ここで守っているのは「色」ではなく「文字」である
///
/// `SyntaxHighlighter` は完全なパーサではなく、字句を上から舐めるだけの走査器で、
/// 自身のコメントが「判定を間違えても崩れるのは色だけで、コードの文字は必ずそのまま出る」
/// と約束している。**この約束が破れると、画面に出るコードが原文と違う**という、
/// コーディング支援を名乗るアプリで最も許されない壊れ方になる。
/// 色の正しさより先に、まずロスレスであることを縛る。
final class SyntaxHighlighterTests: XCTestCase {

    /// 色分け結果を元のコードへ戻す。行は改行で繋ぐ（`splitIntoLines` の逆）。
    private func reassemble(_ highlighted: HighlightedCode) -> String {
        highlighted.lines
            .map { line in line.map(\.text).joined() }
            .joined(separator: "\n")
    }

    /// 言語と中身の組み合わせ。**壊れやすい所を意図的に集めてある。**
    private var samples: [(name: String, language: String?, code: String)] {
        [
            ("Swift", "swift", """
            // 会話を1件保存する
            func save(_ message: String) throws -> Int {
                let count = message.count   /* 書記素で数える */
                guard count > 0 else { throw StoreFailure.empty }
                return count * 2
            }
            """),
            ("Python", "py", """
            def greet(name: str = "世界") -> None:
                # 日本語のコメント
                print(f"こんにちは、{name}")  # 末尾コメント
            """),
            ("TypeScript", "ts", """
            const url = `https://example.com/${id}`;
            export async function load(): Promise<number> {
              return 0x1F + 1_000; // 16進と区切り
            }
            """),
            ("JSON", "json", #"{"model": "Qwen3-8B-4bit", "tokens": 104, "ok": true}"#),
            ("シェル", "bash", """
            make app-stats NOTE="実測" && grep '^\\[STATS\\]' logs/mlx-stats.log
            """),
            ("未知の言語", "brainfuck", "++[->+<]  # 文法を持たない言語"),
            ("言語指定なし", nil, "just some text with \"quotes\" and 42"),
            ("空文字列", "swift", ""),
            ("改行のみ", "swift", "\n\n\n"),
            ("末尾に改行", "swift", "let x = 1\n"),
            ("閉じていない文字列", "swift", #"let broken = "開いたまま"#),
            ("閉じていないコメント", "swift", "/* 閉じ忘れ\nlet x = 1"),
            ("絵文字と日本語", "swift", """
            // 🎌 日本語の識別子も壊さない
            let 名前 = "ソフィア🌸"
            """),
            ("タブとインデント", "python", "def f():\n\tif True:\n\t\treturn 1"),
        ]
    }

    /// **1文字も失わない・増やさない。** 完成条件7の本体。
    func testHighlightingIsLossless() {
        for sample in samples {
            let highlighted = SyntaxHighlighter.highlight(sample.code, language: sample.language)
            XCTAssertEqual(
                reassemble(highlighted), sample.code,
                "「\(sample.name)」で原文が変わった。色分けがコードを書き換えている")
        }
    }

    /// 行数が原文と一致すること。行番号の溝とコードがずれないための条件。
    func testLineCountMatchesTheSource() {
        for sample in samples {
            let highlighted = SyntaxHighlighter.highlight(sample.code, language: sample.language)
            XCTAssertEqual(
                highlighted.lines.count,
                sample.code.components(separatedBy: "\n").count,
                "「\(sample.name)」で行数がずれた。行番号と中身が食い違う")
        }
    }

    /// 中断された生成の途中経過も壊さないこと。
    ///
    /// 生成中のコードブロックは**必ず尻切れで届く**（1文字ずつ伸びる）。
    /// 途中の状態で走査器が例外的な振る舞いをすると、生成中だけ表示が壊れる。
    func testEveryPrefixOfAGrowingCodeBlockIsLossless() {
        let code = """
        func fetch(_ id: String) async throws -> Data {
            // 途中で切れても壊れないこと
            let url = URL(string: "https://example.com/\\(id)")!
            return try await URLSession.shared.data(from: url).0
        }
        """
        for length in 0...code.count {
            let prefix = String(code.prefix(length))
            let highlighted = SyntaxHighlighter.highlight(prefix, language: "swift")
            XCTAssertEqual(
                reassemble(highlighted), prefix,
                "\(length)文字目までの途中経過で原文が変わった")
        }
    }

    // MARK: - 止まらないこと

    /// **走査が必ず前へ進むこと。** 色ではなくフリーズを防ぐためのテスト。
    ///
    /// `#` と `@` は識別子の**先頭**にはなれるが `isIdentifierPart` ではない。
    /// 識別子ブランチを `end = i` から始めると、この2文字では while が1度も回らず
    /// `i = end`（＝ `i`）へ戻って**無限ループする**。
    /// 走査器は MainActor 上で動くので、症状は「色が崩れる」ではなく
    /// **アプリが固まる**（NFR-02 違反）。`@State` を含む Swift のコードブロック1個で再現した。
    ///
    /// 別スレッドで走らせて時間切れで落とすのは、**回帰したときにテスト自体が
    /// 固まってしまうと気づけない**ため。落ちるなら止まらずに落ちること。
    func testScannerAlwaysMakesProgress() {
        let inputs = [
            "@MainActor\nfinal class A {}",   // SwiftUI のコードで必ず出る
            "@Observable final class B {}",
            "# 見出しのような行",
            "#", "@", "# ", "@ ", "#!", "@@",
            "let x = 1 @ 2 # 3",
        ]
        let finished = expectation(description: "走査が返ってくる")
        finished.expectedFulfillmentCount = inputs.count * 2

        for input in inputs {
            for language in ["swift", nil] as [String?] {
                DispatchQueue.global().async {
                    let result = SyntaxHighlighter.highlight(input, language: language)
                    let back = result.lines
                        .map { line in line.map(\.text).joined() }
                        .joined(separator: "\n")
                    XCTAssertEqual(back, input, "「\(input)」で原文が変わった")
                    finished.fulfill()
                }
            }
        }

        wait(for: [finished], timeout: 5)
    }

    // MARK: - 色が実際に付くこと

    /// 走査器が「全部 plain」で逃げていないこと。**ロスレスなだけなら何もしなくても通る。**
    func testKeywordsCommentsAndStringsAreActuallyColoured() {
        let highlighted = SyntaxHighlighter.highlight("""
        // 説明
        let name = "Sophia"
        """, language: "swift")
        let kinds = Set(highlighted.lines.flatMap { $0 }.map(\.kind))

        XCTAssertTrue(kinds.contains(.comment), "コメントに色が付いていない")
        XCTAssertTrue(kinds.contains(.keyword), "キーワード（let）に色が付いていない")
        XCTAssertTrue(kinds.contains(.string), "文字列リテラルに色が付いていない")
    }

    /// 文字列の中のキーワードを色分けしないこと（走査器として最低限の正しさ）。
    func testKeywordsInsideStringsAreNotColoured() {
        let highlighted = SyntaxHighlighter.highlight(
            #"let s = "let func class""#, language: "swift")
        let spans = highlighted.lines.flatMap { $0 }

        let insideString = spans.filter { $0.kind == .string }.map(\.text).joined()
        XCTAssertTrue(insideString.contains("let func class"),
                      "文字列リテラルが途中で分断されている")
    }

    /// 言語を知らなくても落ちないこと。**未知の言語は plain へ倒す**のが約束。
    func testUnknownLanguageStillReturnsTheCodeIntact() {
        let code = "SELECT * FROM 会話 WHERE tokens > 100;"
        for language in ["brainfuck", "", "COBOL", "日本語"] {
            let highlighted = SyntaxHighlighter.highlight(code, language: language)
            XCTAssertEqual(reassemble(highlighted), code, "言語「\(language)」で原文が変わった")
        }
    }
}
