import Foundation
import MLXLMCommon
import XCTest

@testable import Sophia

// =============================================================================
//  ツール呼び出しの往復が閉じること（FR-19 / DESIGN.md 第16章）
// -----------------------------------------------------------------------------
//  **このファイルは1バイトもモデルを読み込まない。**
//
//  「実装がある」を「動く」と取り違えないための試験である。前日、A1の9項目・FR-07・
//  トークン概算が**すべて「実装はあるが動かしたことがなかった」ために壊れていた。**
//  だから往復の部品は、4.6GB を読まずに実際に走らせて値を見る形にしてある。
//
//  | 何を固定するか | どこで | モデルが要るか |
//  |---|---|---|
//  | **自分の呼び出しを書き戻している**（テンプレートの `tool_calls` の枝） | 1章 | 不要 |
//  | 戻り値が **`role=tool`** として入る（`<tool_response>` の枝） | 1章 | 不要 |
//  | `ModelToolCall` ↔ `ToolCall` が欠落なく往復する | 2章 | 不要 |
//  | **実行役が本物のファイルを読む**（値まで見る） | 3章 | 不要 |
//  | **上限に達したら門を閉じる**（16.8節） | 4章 | 不要 |
//  | 門が閉じている会話では実行役に触らない（FR-21 / 約束3） | 5章 | 不要 |
//  | 1往復を通しで組み立てる | 6章 | 不要 |
//
//  ## 何を確かめられないか（**ここを誤魔化さない**）
//
//  1. **Jinja が実際に描いた文字列は見ていない。** 見ているのは
//     テンプレートへ渡る**辞書**（`DefaultMessageGenerator` の出力）までである。
//     Qwen3 のテンプレートは `message.tool_calls` の有無と `message.role == "tool"`
//     で枝を選ぶので、辞書が正しければ枝は正しい ── **が、描画そのものは実機の仕事。**
//     `MLXEngine.swift` 末尾の「実機で確かめること」19〜23 がその宿題である。
//     （`DefaultMessageGenerator` で確かめてよい根拠: `LLMModel.messageGenerator` の
//       既定がそれで、Qwen3 は上書きしていない ＝ 実行時に使われるのと同じ実装である）
//  2. **`performChat` のループそのものは走らせていない。** あれは `ModelContainer` を
//     要求する。代わりに、ループが使っている判断を全部 `static` に出してある
//     （`chatMessages(for:)` / `toolCall(from:)` / `activeToolExecutor(_:toolsWereSent:)` /
//     `route(_:toolsWereSent:)`）。**6章はその部品を、ループと同じ順序で繋いでいる。**
// =============================================================================

final class ToolRoundTripTests: XCTestCase {

    /// ```
    /// base/
    ///   docs/            ← 結び付ける根
    ///     notes.md       全12行（日本語）
    ///     sub/inner.txt
    ///   outside/secret.txt
    /// ```
    private var base: URL!
    private var root: URL!
    private var folder: SecurityScopedFolder!

    /// **行の中身まで見るための材料。** 「落ちなかった」ではなく
    /// 「**正しい値か**」を見る（前日、2行のファイルが922京行と申告されるのを
    /// 「直った」と誤認した。生存だけを見ていたため）。
    private static let notes =
        (1...12).map { "\($0)行目の内容" }.joined(separator: "\n") + "\n"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let manager = FileManager.default

        base = manager.temporaryDirectory
            .appendingPathComponent("SophiaRoundTrip-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("docs", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)

        try manager.createDirectory(
            at: root.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)

        try Data(Self.notes.utf8).write(to: root.appendingPathComponent("notes.md"))
        try Data("内側の中身".utf8).write(to: root.appendingPathComponent("sub/inner.txt"))
        try Data("外の秘密".utf8).write(to: outside.appendingPathComponent("secret.txt"))

        folder = try SecurityScopedFolder.unscoped(directoryURL: root)
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
        try super.tearDownWithError()
    }

    // =========================================================================
    //  1. 書き戻し ── テンプレートのどの枝へ行くか（16.1節）
    // =========================================================================

    /// **アシスタントの呼び出しを会話へ書き戻していること。**
    ///
    /// 書き戻さないと `<tool_response>` が**対応する `<tool_call>` なしで**現れる。
    /// モデルから見て「誰が何を訊いたのか分からない返事」になり、往復が壊れる。
    ///
    /// テンプレートの枝は `{%- if message.tool_calls %}` ── **辞書にこの鍵があるか**が
    /// そのまま分岐条件である。だからここでは鍵の有無と中身を見る。
    func testTheAssistantsOwnCallIsWrittenBackWithAToolCallsKey() throws {
        let call = ModelToolCall(
            name: "read_file", argumentsJSON: #"{"path":"notes.md"}"#, callID: "call-1")

        let rendered = Self.render([
            .user("notes.md には何が書いてある？"),
            .assistant("", toolCalls: [MLXEngine.toolCall(from: call)]),
        ])

        XCTAssertEqual(rendered[1]["role"] as? String, "assistant")

        let toolCalls = try XCTUnwrap(
            rendered[1]["tool_calls"] as? [[String: any Sendable]],
            "**assistant に tool_calls が付いていない。** テンプレートの `{%- if message.tool_calls %}` の枝に届かない")
        XCTAssertEqual(toolCalls.count, 1)

        let function = try XCTUnwrap(toolCalls[0]["function"] as? [String: any Sendable])
        XCTAssertEqual(function["name"] as? String, "read_file")
        XCTAssertEqual(toolCalls[0]["id"] as? String, "call-1")

        // 引数は**辞書として**載ること（文字列に潰さない）。
        // テンプレートは `tool_call.arguments | tojson` で書き出すので、
        // 文字列にすると `"{\"path\":\"notes.md\"}"` という二重の引用符が描かれる。
        let arguments = try XCTUnwrap(function["arguments"] as? [String: any Sendable])
        XCTAssertEqual(arguments["path"] as? String, "notes.md")
    }

    /// **ツールの戻り値は `role=tool` として入る**（`{%- elif message.role == "tool" %}`）。
    ///
    /// この枝は戻り値を **user ターンの `<tool_response>`** として描く。
    /// つまり**ファイルの中身は利用者の発言と同じ場所に入る**（16.6節）──
    /// 囲いと但し書きが実行側で済んでいることが前提である（3章で見る）。
    func testTheToolResultBecomesAToolRoleMessage() {
        let rendered = Self.render([
            .assistant("", toolCalls: [ToolCall(function: .init(name: "read_file", arguments: [String: JSONValue]()))]),
            .toolResult(text: "[ファイル notes.md / 全12行]", id: "call-1", name: "read_file"),
        ])

        XCTAssertEqual(rendered[1]["role"] as? String, "tool")
        XCTAssertEqual(rendered[1]["content"] as? String, "[ファイル notes.md / 全12行]")
        // 対応づけの鍵。Qwen3 は使わないが、使うテンプレートのために欠かさない（NFR-09）。
        XCTAssertEqual(rendered[1]["tool_call_id"] as? String, "call-1")
        XCTAssertEqual(rendered[1]["name"] as? String, "read_file")
    }

    /// **連続する戻り値は、両方とも `role=tool` で並ぶ。**
    ///
    /// テンプレートはそれを**1つの user ターンにまとめて**描く
    /// （`loop.first or (messages[loop.index0 - 1].role != "tool")` の枝）。
    /// 途中に別の役を挟むと、`<|im_start|>user` が2回描かれて往復が割れる。
    func testConsecutiveToolResultsStayAdjacentSoTheTemplateCanMergeThem() {
        let rendered = Self.render([
            .assistant("", toolCalls: [
                ToolCall(function: .init(name: "read_file", arguments: [String: JSONValue]()), id: "a"),
                ToolCall(function: .init(name: "list_directory", arguments: [String: JSONValue]()), id: "b"),
            ]),
            .toolResult(text: "1つ目", id: "a", name: "read_file"),
            .toolResult(text: "2つ目", id: "b", name: "list_directory"),
        ])

        XCTAssertEqual(rendered.map { $0["role"] as? String }, ["assistant", "tool", "tool"])
    }

    /// ツールを呼んでいない発言に `tool_calls` を**生やさない**こと。
    ///
    /// 空配列を載せると、テンプレートの `{%- if message.tool_calls %}` は
    /// Jinja では偽になるので実害は出ない ── **が、依存先の真偽値の扱いに頼らない**
    /// （FR-21 で空配列を `nil` に潰しているのと同じ規律）。
    func testAnOrdinaryAssistantMessageCarriesNoToolCallsKey() {
        let rendered = Self.render([.assistant("こんにちは", toolCalls: [])])

        XCTAssertEqual(rendered[0]["content"] as? String, "こんにちは")
        XCTAssertNil(rendered[0]["tool_calls"], "呼んでいないのに tool_calls が載っている")
    }

    /// **思考は書き戻さない**（`InferenceEngine` の約束6）。
    ///
    /// 書き戻すのは分離器が**本文**として出したぶんだけである。
    /// エンジン側は `.content` の断片しか `visibleText` に足していないので、
    /// ここで確かめるのは「その約束が型のうえで守れる形になっているか」──
    /// `RoundTripMessage.assistant` に思考を入れる口が無いこと。
    func testOnlyTheVisibleTextIsWrittenBack() {
        // 分離器が出した本文だけを渡した場合（エンジンがやっていること）。
        let rendered = Self.render([
            .assistant("読みます", toolCalls: [
                ToolCall(function: .init(name: "read_file", arguments: [String: JSONValue]()))
            ])
        ])

        let content = rendered[0]["content"] as? String
        XCTAssertEqual(content, "読みます")
        XCTAssertFalse(content?.contains("<think>") ?? true, "思考の記法が書き戻されている")
    }

    // =========================================================================
    //  2. `ModelToolCall` ↔ `ToolCall`（欠落しないこと）
    // =========================================================================

    /// **書き戻しは「戻す」形なので、往復して等しくなることが前提である。**
    ///
    /// 型（`Int` か `String` か）が変わると、テンプレートが `tojson` で描く
    /// 引数の綴りが変わる ── モデルが自分で書いた `<tool_call>` と、
    /// 書き戻された `<tool_call>` が**別物になる。**
    func testTheCallSurvivesTheRoundTripBackIntoMLX() {
        let original = ToolCall(
            function: .init(
                name: "read_file",
                arguments: [
                    "path": .string("docs/請求書2026.md"),
                    "offset": .int(1),
                    "limit": .int(80),
                ]),
            id: "call-7")

        let carried = MLXEngine.modelToolCall(from: original)
        let restored = MLXEngine.toolCall(from: carried)

        XCTAssertEqual(restored, original, "往復で値が変わっている（型か順序か id）")
        // 日本語がそのまま残ること（`・` 等へ逃がされていない）。
        XCTAssertTrue(carried.argumentsJSON.contains("請求書2026.md"), carried.argumentsJSON)
    }

    /// 引数が壊れていても**呼び出しごと消さない。**
    ///
    /// 消すとモデルには「無視された」としか見えず、同じ手を繰り返す（16.8節）。
    /// 空の引数として書き戻し、実行役に「path が要る」と答えさせるのが正しい。
    func testBrokenArgumentsBecomeAnEmptyObjectAndTheCallSurvives() {
        let broken = ModelToolCall(name: "read_file", argumentsJSON: "これはJSONではない")
        let restored = MLXEngine.toolCall(from: broken)

        XCTAssertEqual(restored.function.name, "read_file")
        XCTAssertTrue(restored.function.arguments.isEmpty)
    }

    // =========================================================================
    //  3. 実行役 ── 本物のファイルを読む（値まで見る）
    // =========================================================================

    /// **`ToolExecuting` 越しに、本物のファイルが読めること。**
    ///
    /// ここが「実装がある」と「動く」の境目である。推論層は `ToolExecuting` しか
    /// 知らないので、**この protocol 越しに中身が返ってこなければ往復は成立しない。**
    func testExecutingAReadReturnsTheRealFileContents() async {
        let executor: any ToolExecuting = FolderToolRunner(folder: folder)

        let outcome = await executor.execute(ModelToolCall(
            name: "read_file", argumentsJSON: #"{"path":"notes.md"}"#, callID: "call-1"))

        XCTAssertFalse(outcome.isFailure)
        XCTAssertFalse(outcome.stopsRoundTrips)
        XCTAssertEqual(outcome.toolName, "read_file")
        XCTAssertEqual(outcome.callID, "call-1", "戻り値を呼び出しへ対応づけられなくなる")

        // **中身が本当に入っていること。**
        XCTAssertTrue(outcome.responseText.contains("1行目の内容"), outcome.responseText)
        XCTAssertTrue(outcome.responseText.contains("12行目の内容"), outcome.responseText)
        // **囲いの内側に入っていること**（16.6節 約束5）。推論層は1文字も足さない。
        XCTAssertTrue(
            outcome.responseText.contains(ReadOutcome.openDelimiter),
            "囲いが無い。実行側で閉じているはずのもの: \(outcome.responseText)")

        // **申告している行数が実物と合っていること。**
        // 「落ちない」ではなく「正しい値か」を見る（922京行の教訓）。
        XCTAssertTrue(outcome.summaryLine.hasPrefix("読んだ: notes.md"), outcome.summaryLine)
        XCTAssertTrue(outcome.summaryLine.contains("全12行"), outcome.summaryLine)
    }

    /// **読めなかったことは「答え」であって「終わり」ではない**（16.8節）。
    ///
    /// 封じ込めが落とした呼び出しでも往復は続く ── モデルは戻り値を読んで
    /// 次の手（一覧を取る、綴りを直す）を打てる。ここで止めると、
    /// **一度の書き間違いで会話が終わる。**
    func testAContainmentFailureIsAnAnswerNotAStop() async {
        let executor: any ToolExecuting = FolderToolRunner(folder: folder)

        let outcome = await executor.execute(ModelToolCall(
            name: "read_file", argumentsJSON: #"{"path":"../outside/secret.txt"}"#))

        XCTAssertTrue(outcome.isFailure)
        XCTAssertFalse(outcome.stopsRoundTrips, "**失敗で往復を打ち切っている**（16.8節）")
        XCTAssertFalse(outcome.responseText.contains("外の秘密"), "中身が漏れている")
        // 失敗の文は1行に潰されていること（囲いの外に出るため。`ToolResult` の型コメント）。
        XCTAssertFalse(outcome.summaryLine.contains("\n"), outcome.summaryLine)
    }

    /// 名前を間違えた呼び出しも往復を続ける（`unknownTool`）。
    func testAnUnknownToolNameKeepsTheRoundTripAlive() async {
        let executor: any ToolExecuting = FolderToolRunner(folder: folder)

        let outcome = await executor.execute(ModelToolCall(
            name: "delete_everything", argumentsJSON: "{}"))

        XCTAssertTrue(outcome.isFailure)
        XCTAssertFalse(outcome.stopsRoundTrips)
        XCTAssertTrue(outcome.responseText.contains("list_directory"), "使える名前を教えていない")
    }

    // =========================================================================
    //  4. 上限（16.8節「往復には回数の上限を置くこと」）
    // =========================================================================

    /// **上限に達したことが、推論層まで伝わること。**
    ///
    /// 数えているのは実行役だけである（`FolderToolRunner.callLimit`）。
    /// エンジンは数えない ── 数える場所が2つになると、必ず食い違う。
    /// 伝わる手段は `stopsRoundTrips` の1つだけなので、ここが切れたら
    /// **上限は「あるのに効かない」状態になる。**
    func testTheCallLimitReachesTheInferenceLayerAsStopsRoundTrips() async {
        let executor: any ToolExecuting = FolderToolRunner(folder: folder, callLimit: 2)

        let first = await executor.execute(Self.read("notes.md"))
        let second = await executor.execute(Self.read("sub/inner.txt"))
        let third = await executor.execute(Self.read("notes.md"))

        XCTAssertFalse(first.stopsRoundTrips)
        XCTAssertFalse(second.stopsRoundTrips)

        XCTAssertTrue(third.stopsRoundTrips, "**上限に達したのに往復が止まらない**")
        XCTAssertTrue(third.isFailure)
        // **モデルへ「いま分かっている範囲で答えろ」と伝えていること。**
        // ここが無いと、門を閉じた最後の1周でモデルが黙るか、また呼ぼうとする。
        XCTAssertTrue(third.responseText.contains("上限"), third.responseText)
        XCTAssertTrue(third.responseText.contains("答え"), third.responseText)
    }

    /// **失敗した呼び出しも数に入る。**
    /// 数えないと、同じ誤りを繰り返すモデルに対して上限が効かない。
    func testFailedCallsCountTowardTheLimitToo() async {
        let executor: any ToolExecuting = FolderToolRunner(folder: folder, callLimit: 2)

        _ = await executor.execute(Self.read("../outside/secret.txt"))
        _ = await executor.execute(ModelToolCall(name: "nope", argumentsJSON: "{}"))
        let third = await executor.execute(Self.read("notes.md"))

        XCTAssertTrue(third.stopsRoundTrips)
    }

    /// **新しい発言では上限が戻ること**（`beginRoundTrip`）。
    ///
    /// 上限は「1つの問いに答えるまで」に効かせたいものであって、
    /// 「会話を通じて一度しか読めない」ではない。
    /// **戻すのはエンジンの入口1か所だけ**（呼び出し側に任せると必ず忘れる）。
    func testBeginRoundTripResetsTheLimitForTheNextQuestion() async {
        let executor: any ToolExecuting = FolderToolRunner(folder: folder, callLimit: 1)

        _ = await executor.execute(Self.read("notes.md"))
        let overLimit = await executor.execute(Self.read("notes.md"))
        XCTAssertTrue(overLimit.stopsRoundTrips)

        await executor.beginRoundTrip()

        let afterReset = await executor.execute(Self.read("notes.md"))
        XCTAssertFalse(afterReset.stopsRoundTrips, "新しい発言でも上限が戻っていない")
        XCTAssertFalse(afterReset.isFailure)
        XCTAssertTrue(afterReset.responseText.contains("1行目の内容"))
    }

    /// **上限に達したあとの筋道**（エンジンがやること）。
    ///
    /// `stopsRoundTrips` を受けたエンジンは**ツール定義ごと外して、あと1周だけ回す。**
    /// 門を閉じれば `<tools>` は描かれず、`route` が呼び出しを1件も通さない ＝
    /// **その周で必ずループが終わる。** ここで見ているのは、
    /// その2段（`toolSpecs(for:)` → `route`）が実際に噛み合っているかである。
    ///
    /// 打ち切らずに1周回すのは 16.8節のため ── 打ち切ると利用者には
    /// **読んだきり黙って終わった**ように見える。
    func testClosingTheGateMakesFurtherCallsUnexecutable() {
        // 上限に達した ＝ 次の周は定義を外す。
        let closed = MLXEngine.toolSpecs(for: [])
        XCTAssertNil(closed, "門が閉じていない。テンプレートに <tools> が描かれてしまう")

        // その周でモデルがなお呼んできても、素通ししない（実行役へ届かない）。
        let call = ToolCall(function: .init(name: "read_file", arguments: ["path": .string("notes.md")]))
        XCTAssertEqual(
            MLXEngine.route(.toolCall(call), toolsWereSent: closed != nil),
            .unexpectedToolCall(name: "read_file"),
            "門を閉じたのに呼び出しが通っている。**ループが終わらない**")
    }

    // =========================================================================
    //  5. 門が閉じている会話では、実行役に触らない（FR-21 / 16.6節 約束3）
    // =========================================================================

    /// **実行役が刺さっていても、`options.tools` が空なら何も起きないこと。**
    ///
    /// 実行役はアプリの寿命に近い長さで刺さりうる（会話ごとに付け替える）。
    /// もし「刺さっているから使える」経路があると、
    /// **利用者の操作以外で `idle` が `armed` に変わる**（約束3が破れる）。
    func testTheExecutorIsNotEvenLookedAtWhenTheGateIsShut() async {
        let spy = SpyExecutor()

        XCTAssertNil(
            MLXEngine.activeToolExecutor(spy, toolsWereSent: false),
            "**門が閉じているのに実行役を取り出している**（16.6節 約束3）")
        XCTAssertNotNil(MLXEngine.activeToolExecutor(spy, toolsWereSent: true))

        // 既定の `ChatOptions` は `idle` である ── そこから門は開かない。
        XCTAssertTrue(ChatOptions().tools.isEmpty)
        XCTAssertNil(MLXEngine.toolSpecs(for: ChatOptions().tools))

        let touched = await spy.beginCount
        XCTAssertEqual(touched, 0, "門が閉じている会話で実行役に触っている")
    }

    /// **差し込みの口が在ること**（`init(toolExecutor:)` と `setToolExecutor(_:)`）。
    ///
    /// `ChatOptions` は `Equatable` / `Codable` なので**クロージャを持てない**。
    /// だから注入はエンジン側にある。**`init` だけでは足りない** ──
    /// 会話の途中で利用者がフォルダを結び付ける（＝実行役が入れ替わる）。
    ///
    /// ## これは意図的に「コンパイル時の保証」である
    ///
    /// **ここでエンジンを作らない。** `MLXEngine.init` は MLX のアロケータを
    /// 初期化する（`Memory.cacheLimit`）。それは実機の話であって、この試験の主題ではない ──
    /// **軽い試験の中に重い初期化を紛れ込ませない。**
    /// 口が消えれば、この関数はコンパイルできなくなる。それで目的は足りている。
    func testTheEngineKeepsAPlaceToInstallTheExecutor() async {
        let build: (any ToolExecuting) -> MLXEngine = { MLXEngine(toolExecutor: $0) }
        let install: (MLXEngine, (any ToolExecuting)?) async -> Void = {
            await $0.setToolExecutor($1)
        }

        // **呼ばない。在ることだけを縛る。**
        _ = build
        _ = install

        // 差し込まれる側が、**protocol 越しに**本当に動くこと。
        let executor: any ToolExecuting = FolderToolRunner(folder: folder)
        let outcome = await executor.execute(Self.read("notes.md"))
        XCTAssertFalse(outcome.isFailure, "差し込む対象そのものが動いていない")
    }

    // =========================================================================
    //  6. 1往復を通しで組み立てる（ループと同じ順序）
    // =========================================================================

    /// **`performChat` の往復1周ぶんを、同じ部品・同じ順序で再現する。**
    ///
    /// 個々の部品が正しくても、繋いだときに順序が入れ替わっていれば往復は壊れる。
    /// ここでは「モデルが `read_file` を呼んだ」ところから、
    /// 次の周へ渡る辞書までを通しで作り、**役の並びと中身**を見る。
    ///
    /// 本物の `FolderToolRunner` を通しているので、`content` に入るのは
    /// **実際にディスクから読んだ文字列**である。
    func testOneWholeRoundTripAssemblesIntoThePromptForTheNextRound() async throws {
        let executor: any ToolExecuting = FolderToolRunner(folder: folder)
        await executor.beginRoundTrip()

        // 1周目に渡した会話。
        var transcript: [RoundTripMessage] = [
            .system("あなたの名前は Sophia（ソフィア）。"),
            .user("notes.md には何が書いてある？"),
        ]

        // モデルが呼んできた（`Chunk.toolCall` として届く形）。
        let call = ModelToolCall(
            name: "read_file", argumentsJSON: #"{"path":"notes.md"}"#, callID: "call-1")

        // エンジンがやること ── ①自分の呼び出しを書き戻す ②実行する ③戻り値を足す。
        transcript.append(.assistant("", toolCalls: [MLXEngine.toolCall(from: call)]))
        let outcome = await executor.execute(call)
        transcript.append(.toolResult(
            text: outcome.responseText, id: outcome.callID, name: outcome.toolName))

        let rendered = Self.render(transcript)

        // **役の並び。** `<tool_call>` と `<tool_response>` が対になる唯一の形である。
        XCTAssertEqual(
            rendered.map { $0["role"] as? String },
            ["system", "user", "assistant", "tool"])

        // ②の書き戻しが3通目に入っていること。
        let toolCalls = try XCTUnwrap(rendered[2]["tool_calls"] as? [[String: any Sendable]])
        let function = try XCTUnwrap(toolCalls[0]["function"] as? [String: any Sendable])
        XCTAssertEqual(function["name"] as? String, "read_file")

        // ③の戻り値に**本物の中身**が入っていること。
        let response = try XCTUnwrap(rendered[3]["content"] as? String)
        XCTAssertTrue(response.contains("1行目の内容"), response)
        XCTAssertEqual(rendered[3]["tool_call_id"] as? String, "call-1")

        // **画面に出す1行と、履歴に残る栞が同じ文であること**（16.7節 / 16.3節）。
        // 別々に組み立てると必ずどこかでずれる。
        let activity = outcome.activity(round: 1)
        XCTAssertEqual(activity.summary, outcome.summaryLine)
        XCTAssertEqual(activity.toolName, "read_file")
        XCTAssertFalse(activity.isFailure)
        XCTAssertEqual(activity.round, 1)
    }

    /// **`Chunk` に増えたケースが、既存の消費側を壊していないこと。**
    ///
    /// `Chunk.swift` は「網羅 switch を書かないこと」を約束にしている。
    /// 計測（`GenerationClock`）は `.toolResult` を**文字数に数えない** ──
    /// 数えると TTFT の起点と出力トークンの概算が両方ずれる（`.toolCall` と同じ理由）。
    func testTheNewChunkCaseIsNotCountedAsOutput() {
        var clock = GenerationClock()
        clock.record(.toolResult(ToolActivity(
            toolName: "read_file", summary: "読んだ: notes.md（全12行すべて）",
            isFailure: false, round: 1)))

        XCTAssertEqual(clock.thinkingCharacterCount, 0)
        XCTAssertEqual(clock.contentCharacterCount, 0)
        XCTAssertNil(clock.ttftMs, "ツールの報せで TTFT の起点が動いている")
    }

    // MARK: - 補助

    /// **テンプレートが実際に受け取る辞書**まで落とす。
    ///
    /// `DefaultMessageGenerator` を使うのは、`LLMModel.messageGenerator` の既定が
    /// それであり、Qwen3 が上書きしていないからである ＝ 実行時と同じ実装である。
    private static func render(_ transcript: [RoundTripMessage]) -> [[String: any Sendable]] {
        DefaultMessageGenerator().generate(messages: MLXEngine.chatMessages(for: transcript))
    }

    /// `read_file` の呼び出し1件（テストの見通しのため）。
    private static func read(_ path: String) -> ModelToolCall {
        ModelToolCall(name: "read_file", argumentsJSON: #"{"path":"\#(path)"}"#)
    }
}

// =============================================================================
//  試験用の実行役
// -----------------------------------------------------------------------------
//  **触られたかどうかだけを見る。** 実行の中身は `FolderToolRunner` が本物を持っており、
//  それは3章・4章で本物のファイル越しに確かめてある。
//  ここで模擬に置き換えたいのは「呼ばれたか／呼ばれていないか」だけである。
// =============================================================================

private actor SpyExecutor: ToolExecuting {

    private(set) var beginCount = 0
    private(set) var calls: [ModelToolCall] = []

    func beginRoundTrip() async {
        beginCount += 1
    }

    func execute(_ call: ModelToolCall) async -> ToolExecutionOutcome {
        calls.append(call)
        return ToolExecutionOutcome(
            toolName: call.name,
            callID: call.callID,
            responseText: "[ツール \(call.name)] 模擬",
            summaryLine: "\(call.name): 模擬",
            isFailure: false,
            stopsRoundTrips: false)
    }
}
