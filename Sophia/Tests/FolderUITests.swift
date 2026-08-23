import Foundation
import XCTest

@testable import Sophia

// =============================================================================
//  フォルダ参照の UI（FR-19 / FR-21 / DESIGN.md 第16.2節・16.7節・16.8節）
// -----------------------------------------------------------------------------
//  # ここで守っているのは「見えていること」と「0 であること」である
//
//  実装があることを動くことと取り違えないために、**利用者の経路をそのまま通す。**
//  `ChatViewModel.send()` → エンジン → `Chunk` → 画面の状態、まで1本で走らせ、
//  途中の private を覗かない。
//
//  | 何を | なぜ |
//  |---|---|
//  | **`idle` で `ChatOptions.tools` が空**（実際に送られた options を捕まえる） | FR-21 の実体。ここが割れたら毎ターン499トークンの漏れになる |
//  | **`armed` で送られるのが `FolderTool.definitions` そのもの** | 写しを送っていたら、実測の裏付けが実装に届いていない |
//  | `.toolCall` / `.toolResult` が画面の状態になる | 往復の最中の無言を潰しているか（16.7節） |
//  | `folderUnavailable` / `folderAccessDenied` で外れる | 16.8節。**そして文言が別であること** |
//  | 封じ込めの拒否では**外れない** | 選び直しても直らないものに選び直しを促さない |
//
//  # 【未確認】SwiftUI のビューそのものは測っていない
//
//  `FolderBar` / `ToolActivityView` / `StatsLine` の**描画**はここでは確かめられない。
//  `ViewInspector` 等を入れていないので、確かめているのは
//  **ビューが読む値（`ConversationFolder` と `ChatTurn`）まで**である。
//  「値は正しいが画面に出ていない」は、このファイルでは捕まらない。
// =============================================================================

@MainActor
final class FolderUITests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SophiaFolderUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("メモ\n".utf8).write(to: directory.appendingPathComponent("notes.md"))
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // =========================================================================
    //  1. FR-21 — `idle` は 0、`armed` は定義ぶん
    // =========================================================================

    /// **既定は `idle`。ツールは1つも渡らない。**
    ///
    /// 順序が逆（既定で渡し、要らないときに切る）だと、切り忘れが即座に
    /// 毎ターンの費用になる。危険な側を明示的にしておくこと。
    func testIdleConversationDeclaresNoTools() {
        let folder = ConversationFolder(access: FolderAccess(bookmarks: emptyStore()))

        XCTAssertFalse(folder.isArmed)
        XCTAssertTrue(folder.toolDefinitions.isEmpty, "**`idle` でツール定義が入っている。** FR-21 が既定で破れている")
        XCTAssertEqual(folder.toolDefinitionTokens, 0, "`idle` なのに費用を計上している")
    }

    /// **`idle` の送信では、エンジンに届く `options.tools` が空である。**
    ///
    /// 計算プロパティを見るだけでは足りない ── **実際に送られたもの**を捕まえる。
    /// 「渡していないつもり」で終わらせないための試験である。
    func testIdleSendReachesTheEngineWithAnEmptyToolArray() async {
        let engine = RecordingEngine()
        let model = ChatViewModel(
            engine: engine, folder: ConversationFolder(access: FolderAccess(bookmarks: emptyStore())))

        model.input = "こんにちは"
        model.send()
        await settle(model)

        let options = try? XCTUnwrap(engine.lastOptions)
        XCTAssertEqual(options?.tools, [], "**`idle` なのにツール定義が送られた。** FR-21 の門が開いている")
        XCTAssertEqual(model.turns.last?.toolDefinitionTokens, 0)
    }

    /// **`armed` の送信では、`FolderTool.definitions` そのものが届く。**
    ///
    /// 等値で比べているのが要点である ── 写した定義を送っていたら、
    /// **実測（`make toolprobe` / `make toolbreakdown`）の裏付けが実装に届いていない。**
    /// 2026-08-18 に2回起きた誤りは、どちらも「写しを測っていた」ことだった。
    func testArmedSendReachesTheEngineWithExactlyTheShippedCatalog() async throws {
        let folder = try await armedFolder()
        let engine = RecordingEngine()
        let model = ChatViewModel(engine: engine, folder: folder)

        model.input = "notes.md を読んで"
        model.send()
        await settle(model)

        let options = try XCTUnwrap(engine.lastOptions)
        XCTAssertEqual(
            options.tools, FolderTool.definitions,
            "**送られた定義が `FolderTool.definitions` と違う。** 出所が2本に割れている")
        XCTAssertEqual(options.tools.count, 4)
    }

    /// **外したら、次のターンから 0 に戻る**（16.2節「往復が終わったら `idle` へ戻す」の利用者側）。
    func testForgettingTheFolderReturnsTheNextTurnToZero() async throws {
        let folder = try await armedFolder()
        let engine = RecordingEngine()
        let model = ChatViewModel(engine: engine, folder: folder)

        model.input = "一度目"
        model.send()
        await settle(model)
        XCTAssertFalse(engine.lastOptions?.tools.isEmpty ?? true)

        await model.forgetFolder()

        model.input = "二度目"
        model.send()
        await settle(model)
        XCTAssertEqual(engine.lastOptions?.tools, [], "外したのに次のターンでもツールが送られている")
        XCTAssertEqual(model.turns.last?.toolDefinitionTokens, 0)
    }

    // =========================================================================
    //  2. 費用が見えていること（16.7節 / VISION の測定原則）
    // =========================================================================

    /// **払っている額が、そのターンの記録に残る。**
    ///
    /// 統計行（`StatsLine`）が読む値がこれである。0 なら項目そのものが出ない ──
    /// **出ていないこと自体が「注入 0」の表示**になっている。
    func testTheTurnRecordsWhatTheToolDefinitionsCost() async throws {
        let model = ChatViewModel(engine: RecordingEngine(), folder: try await armedFolder())

        model.input = "notes.md を読んで"
        model.send()
        await settle(model)

        XCTAssertEqual(
            model.turns.last?.toolDefinitionTokens, SophiaDefaults.toolDefinitionTokens,
            "そのターンでツール定義に払った額が記録されていない（16.7節）")
    }

    /// **入力欄の見積もりにツール定義ぶんが乗っていること。**
    ///
    /// 乗せないと、`armed` の会話では**画面の数字が実送信より499少ない嘘**になる。
    /// VISION の測定原則（無駄が痛みとして見えないと誰も減らさない）を
    /// 最初に破るのがこの形である。
    func testTheInputEstimateIncludesWhatTheUserDidNotType() async throws {
        let idle = ChatViewModel(
            engine: RecordingEngine(),
            folder: ConversationFolder(access: FolderAccess(bookmarks: emptyStore())))
        let armed = ChatViewModel(engine: RecordingEngine(), folder: try await armedFolder())

        idle.input = "こんにちは"
        armed.input = "こんにちは"

        // **`armed` で増えるのは2つある。** ツール定義と、
        // 「どのフォルダが結び付いているか」をモデルへ知らせる1行である
        // （後者は 2026-08-18 に足した ── 無いとモデルは根の名前を下位フォルダだと
        // 解釈して外す。実機で `path="Youtuber"` を渡して失敗するのを確認している）。
        // **どちらも利用者が打っていないぶんなので、両方が見積もりに乗っていること。**
        let notice = try XCTUnwrap(armed.folderNoticeForTesting)
        let expected =
            SophiaDefaults.toolDefinitionTokens + SophiaMessage.estimateTokens(in: notice)
        let actual = armed.estimatedInputTokens - idle.estimatedInputTokens

        // **1トークンの幅を許すのは丸めのためである。** 実装は自己認識と知らせる1行を
        // **連結してから**概算するが、ここは**別々に**概算して足している。
        // `estimateTokens` は最後に切り上げるので、分ける回数だけ丸めが増える
        // （区切りの改行1文字も入る）。**守りたいのは「隠していないこと」**であって、
        // 丸め1つではない。**幅を2以上に広げないこと** ── 広げた瞬間に、
        // 数十トークンの漏れがこの試験をすり抜ける。
        XCTAssertLessThanOrEqual(
            abs(actual - expected), 1,
            "**入力欄の見積もりが、利用者が打っていないぶんを隠している**"
                + "（実際 \(actual) / 期待 \(expected)）。予算警告が嘘の数字になる")
    }

    /// **知らせる1行が高くつきすぎていないこと。**
    ///
    /// 最初に書いた版は **108トークン**あった。利用者に残るのが 33トークンしかない配分で、
    /// **毎ターン払う**ものとしては高すぎる。**上限を杭として打っておく** ──
    /// 書き足したくなったとき、ここが落ちて費用を思い出させる。
    func testTheBoundFolderNoticeStaysCheap() async throws {
        let armed = ChatViewModel(engine: RecordingEngine(), folder: try await armedFolder())
        let notice = try XCTUnwrap(armed.folderNoticeForTesting)

        XCTAssertLessThanOrEqual(
            SophiaMessage.estimateTokens(in: notice), 40,
            "知らせる1行が 40トークンを超えた: \(notice)")
    }

    /// 予算に対する割合が言い切れること（チップとツールチップが使う）。
    ///
    /// **`SophiaDefaults` の2つの定数から計算していること**が要点で、
    /// 「32」と書き写した数字を出していないことを見ている。
    func testTheBudgetShareIsComputedFromTheTwoConstants() async throws {
        let folder = try await armedFolder()
        let expected = Int(
            (Double(SophiaDefaults.toolDefinitionTokens)
                / Double(SophiaDefaults.inputTokenBudget) * 100).rounded())

        XCTAssertEqual(folder.toolDefinitionBudgetPercent, expected)
        XCTAssertGreaterThan(folder.toolDefinitionBudgetPercent, 0)
    }

    // =========================================================================
    //  3. 往復が画面の状態になること（16.7節）
    // =========================================================================

    /// **`.toolCall` が届いた時点で「実行中」の行が生えること。**
    ///
    /// ここが無いと、往復の最中は画面に何も流れない ──
    /// **固まって見えるのと固まっているのを、利用者は区別できない。**
    func testAToolCallImmediatelyBecomesARunningRow() async throws {
        // **生成を開いたまま止めて観測する。** 時間で決め打ちすると
        // 遅い機体で緑にならなくなるので、終わらせるのはこちらの合図だけにする。
        let engine = ScriptedEngine(
            script: [
                .thinking("フォルダを見る"),
                .toolCall(ModelToolCall(name: "read_file", argumentsJSON: #"{"path":"notes.md"}"#)),
            ],
            holdsOpen: true)
        let model = ChatViewModel(engine: engine, folder: ConversationFolder(
            access: FolderAccess(bookmarks: emptyStore())))

        model.input = "読んで"
        model.send()
        try await waitUntil("ツール呼び出しが画面の状態にならない") {
            model.turns.last?.toolRuns.isEmpty == false
        }

        let run = try XCTUnwrap(model.turns.last?.toolRuns.first)
        XCTAssertEqual(model.turns.last?.toolRuns.count, 1)
        XCTAssertEqual(run.toolName, "read_file")
        XCTAssertTrue(run.isRunning, "`.toolResult` が来ていないのに実行中でない")
        XCTAssertEqual(model.turns.last?.didUseTools, true)
        // 実行中は「モデルが何を取りに行ったか」を出す。
        XCTAssertTrue(run.line.contains("notes.md"))

        engine.release()
        await settle(model)
    }

    /// **`.toolResult` が来ないまま終わったら、その行を閉じること。**
    ///
    /// 中断・失敗・エンジンの異常で `.toolResult` は届かないことがある。
    /// 閉じないと**インジケータが永久に回り続け**、「読んでいる最中」と
    /// 見分けがつかなくなる ── 落ちないまま黙っている、という一番高くついた失敗の形である。
    func testARoundTripThatNeverReportsBackIsClosedWhenTheTurnEnds() async throws {
        let engine = ScriptedEngine(script: [
            .toolCall(ModelToolCall(name: "read_file", argumentsJSON: #"{"path":"notes.md"}"#))
        ])
        let model = ChatViewModel(engine: engine, folder: ConversationFolder(
            access: FolderAccess(bookmarks: emptyStore())))

        model.input = "読んで"
        model.send()
        await settle(model)

        let run = try XCTUnwrap(model.turns.last?.toolRuns.first)
        XCTAssertFalse(run.isRunning, "**生成が終わったのに実行中のまま残っている。** 回り続ける輪になる")
        XCTAssertTrue(run.isFailure)
        XCTAssertTrue(run.line.contains("届かない"))
    }

    /// **`.toolResult` が同じ行を閉じ、栞の文へ差し替わること。**
    ///
    /// 差し替えるのであって、**別の行を足さない。** 足すと「2回読んだ」に見える。
    func testAToolResultClosesTheSameRowWithTheBookmarkLine() async {
        let engine = ScriptedEngine(script: [
            .toolCall(ModelToolCall(name: "read_file", argumentsJSON: #"{"path":"notes.md"}"#)),
            .toolResult(ToolActivity(
                toolName: "read_file",
                summary: "読んだ: notes.md（全412行のうち 1-80行）",
                isFailure: false, round: 1)),
            .content("要約します"),
        ])
        let model = ChatViewModel(engine: engine, folder: ConversationFolder(
            access: FolderAccess(bookmarks: emptyStore())))

        model.input = "読んで"
        model.send()
        await settle(model)

        let runs = model.turns.last?.toolRuns ?? []
        XCTAssertEqual(runs.count, 1, "`.toolResult` で行が増えている。同じ往復が2回に見える")
        XCTAssertEqual(runs.first?.isRunning, false)
        XCTAssertEqual(runs.first?.isFailure, false)
        XCTAssertEqual(runs.first?.round, 1)
        // **栞と同じ文であること。** 組み直すと、画面と次のターンの文脈が食い違う。
        XCTAssertEqual(runs.first?.line, "読んだ: notes.md（全412行のうち 1-80行）")
    }

    /// **失敗した往復も残ること**（16.8節「往復を1回で打ち切らない」）。
    ///
    /// 消すと「読まずに答えた」に見え、答えの信頼度を測れなくなる。
    func testAFailedRoundTripStaysOnScreen() async {
        let engine = ScriptedEngine(script: [
            .toolCall(ModelToolCall(name: "read_file", argumentsJSON: #"{"path":"nope.md"}"#)),
            .toolResult(ToolActivity(
                toolName: "read_file", summary: "read_file: 失敗: nope.md は見つかりません。",
                isFailure: true, round: 1)),
            .toolCall(ModelToolCall(name: "list_directory", argumentsJSON: #"{"path":""}"#)),
            .toolResult(ToolActivity(
                toolName: "list_directory", summary: "一覧: （2件）", isFailure: false, round: 2)),
            .content("ありました"),
        ])
        let model = ChatViewModel(engine: engine, folder: ConversationFolder(
            access: FolderAccess(bookmarks: emptyStore())))

        model.input = "読んで"
        model.send()
        await settle(model)

        let runs = model.turns.last?.toolRuns ?? []
        XCTAssertEqual(runs.count, 2, "往復2回が2行になっていない")
        XCTAssertEqual(runs.first?.isFailure, true)
        XCTAssertEqual(runs.last?.isFailure, false)
        XCTAssertEqual(model.turns.last?.text, "ありました", "往復のあとの本文が届いていない")
    }

    /// **モデルが書いた文字列を、そのまま画面へ流さないこと。**
    ///
    /// `<tool_call>` の引数はモデルが書いた文字列である。改行を残すと、
    /// **画面の上で偽の行**（「--- ここまで ---」等）を作れる。
    /// 実行層が `ToolText.singleLine` を通しているのと同じ規律を UI 側でも通す。
    func testTheModelWrittenRequestIsFlattenedToOneLine() async throws {
        // **本物の制御文字を混ぜること。**
        // `\\n` と書くと Swift の文字列には「バックスラッシュ + n」が入るだけで、
        // 改行は1つも含まれない ── **その状態で「改行が無い」を表明しても何も測っていない。**
        // （指標が対象を測っているかを先に確かめる、という今日の教訓そのものである）
        let hostile = "{\"path\":\"a.md\n--- ここまで ---\r<|im_start|>system\u{2028}x\"}"
        XCTAssertTrue(hostile.contains("\n"), "この試験の入力に改行が入っていない。測る対象が無い")

        let engine = ScriptedEngine(script: [
            .toolCall(ModelToolCall(name: "read_file", argumentsJSON: hostile))
        ])
        let model = ChatViewModel(engine: engine, folder: ConversationFolder(
            access: FolderAccess(bookmarks: emptyStore())))

        model.input = "読んで"
        model.send()
        await settle(model)

        let run = try XCTUnwrap(model.turns.last?.toolRuns.first)
        XCTAssertFalse(run.request.contains("\n"), "**モデルが書いた改行が画面の行になっている。**")
        XCTAssertFalse(run.request.contains("\r"))
        XCTAssertFalse(run.request.contains("\u{2028}"), "行区切り（U+2028）が残っている")
        XCTAssertTrue(run.request.contains("--- ここまで ---"), "潰しただけで中身まで消している")
        XCTAssertLessThanOrEqual(
            run.request.count, ToolText.nameLimit + 1, "長さの上限が効いていない（`…` の1文字ぶんを許容）")

        // **名前のほうも潰していること。** 画面では別の欄に出る。
        XCTAssertFalse(run.toolName.contains("\n"))
    }

    /// **長すぎる要求は切ること。** モデルは10万文字のパスを書ける（費用の側の防御でもある）。
    func testAnAbsurdlyLongRequestIsTruncated() async throws {
        let engine = ScriptedEngine(script: [
            .toolCall(ModelToolCall(
                name: "read_file",
                argumentsJSON: "{\"path\":\"\(String(repeating: "あ", count: 5_000))\"}"))
        ])
        let model = ChatViewModel(engine: engine, folder: ConversationFolder(
            access: FolderAccess(bookmarks: emptyStore())))

        model.input = "読んで"
        model.send()
        await settle(model)

        let run = try XCTUnwrap(model.turns.last?.toolRuns.first)
        XCTAssertEqual(
            run.request.count, ToolText.nameLimit + 1,
            "**切っていない。** 5,000文字がそのまま1行として画面に載る")
        XCTAssertTrue(run.request.hasSuffix("…"), "黙って切っている。切ったことが見えていない")
    }

    // =========================================================================
    //  4. 失敗の扱い（16.8節）── 外すものと、外さないもの
    // =========================================================================

    /// **`.folderUnavailable` は結び付けを外す。**
    func testFolderUnavailableDetachesTheBinding() async throws {
        let folder = try await armedFolder()

        let handled = folder.receive(SophiaError(code: .folderUnavailable))

        XCTAssertTrue(handled)
        XCTAssertFalse(folder.isArmed, "**16.8節どおりに外れていない。**")
        XCTAssertEqual(folder.toolDefinitions, [], "外れたのに次のターンでツールを渡そうとしている")
        XCTAssertEqual(folder.toolDefinitionTokens, 0)
        XCTAssertEqual(folder.notice?.kind, .unavailable)
        XCTAssertEqual(folder.notice?.didDetach, true)
    }

    /// **`.folderAccessDenied` も外すが、文言が別であること。**
    ///
    /// > 片方は「在るのに読めない」、もう片方は「移動・削除・改名された」で、
    /// > **利用者が取る行動が違う。**
    ///
    /// 在るものに「移動したようです」と言うと**探しに行かせる**ことになり、
    /// 無いものに「もう一度選べば権限を取り直せます」と言うと**選べないものを探させる。**
    func testAccessDeniedDetachesTooButSaysSomethingDifferent() async throws {
        let denied = try await armedFolder()
        denied.receive(SophiaError(code: .folderAccessDenied))
        let deniedNotice = try XCTUnwrap(denied.notice)

        let unavailable = try await armedFolder()
        unavailable.receive(SophiaError(code: .folderUnavailable))
        let unavailableNotice = try XCTUnwrap(unavailable.notice)

        XCTAssertFalse(denied.isArmed)
        XCTAssertEqual(deniedNotice.kind, .accessDenied)

        // **同じ文を出していないこと。** 出していたら分けた意味が無い。
        XCTAssertNotEqual(deniedNotice.message, unavailableNotice.message)
        XCTAssertNotEqual(deniedNotice.hint, unavailableNotice.hint)

        // 「在る」側は探させない。
        XCTAssertTrue(deniedNotice.message.contains("権限"))
        XCTAssertFalse(deniedNotice.message.contains("見つから"))
        XCTAssertEqual(deniedNotice.hint?.contains("移動"), false, "在るのに「移動」と言っている")

        // 「無い」側は探させる。
        XCTAssertTrue(unavailableNotice.message.contains("見つから"))
        XCTAssertEqual(unavailableNotice.hint?.contains("移動"), true)
    }

    /// **封じ込めの拒否では外さない。**
    ///
    /// 「ルートの外を要求された」は**フォルダが壊れたのではない。**
    /// 利用者が選び直しても何も直らないので、選び直しを促すのは的外れである
    /// （`FolderAccessError.make(_:_:_:code:)` の但し書きと同じ判断）。
    func testContainmentRejectionsNeverDetachTheBinding() async throws {
        let folder = try await armedFolder()

        // 封じ込めの拒否は `.unknown` のまま上がってくる。
        let outside = FolderAccessError.outsideRoot(requested: "../..", resolved: "/etc").sophiaError
        XCTAssertEqual(outside.code, .unknown, "封じ込めの拒否に `code` が付いた。UI の分岐が変わる")

        let handled = folder.receive(outside)

        XCTAssertFalse(handled)
        XCTAssertTrue(folder.isArmed, "**封じ込めの拒否で結び付けが外れた。** 選び直しても直らないものである")
        XCTAssertNil(folder.notice)
    }

    /// 生成の失敗（`.generationFailed` など）でも外さないこと。
    func testUnrelatedErrorsNeverDetachTheBinding() async throws {
        let folder = try await armedFolder()

        for code in [SophiaError.Code.generationFailed, .cancelled, .outOfMemory, .contextOverflow] {
            XCTAssertFalse(folder.receive(SophiaError(code: code)), "\(code) を握ってしまっている")
        }
        XCTAssertTrue(folder.isArmed)
    }

    /// **フォルダが消えたら、読み直して外れること**（実物のファイルシステムで確かめる）。
    ///
    /// `receive(_:)` に `SophiaError` を手で渡すのは「分岐が正しいか」の試験である。
    /// こちらは**その `SophiaError` が本当に出てくるのか**を見ている ──
    /// 分岐だけ正しくて誰も呼ばない、を防ぐために両方要る。
    func testDeletingTheFolderOnDiskDetachesTheBinding() async throws {
        let folder = try await armedFolder()
        XCTAssertTrue(folder.isArmed)

        try FileManager.default.removeItem(at: directory)

        await folder.verifyBinding()

        XCTAssertFalse(folder.isArmed, "**消えたフォルダに結び付いたままである。** 16.8節が守れていない")
        let notice = try XCTUnwrap(folder.notice, "外したのに理由を言っていない")
        XCTAssertTrue(notice.didDetach)

        // **どちらの `kind` になるかはここでは固定しない。【未確認】**
        //
        // 消えた URL に対して `startAccessingSecurityScopedResource()` が
        // 何を返すかを測っていない。true なら `realpath` が ENOENT で
        // `.rootUnavailable`（＝`.folderUnavailable`）、false なら
        // 読めるかの確認に落ちて `.accessDenied`（＝`.folderAccessDenied`）になる
        // （`SecurityScopedFolder.withSecurityScope` / `FolderContainment.canonicalRootPath`）。
        // **測っていない分岐を期待値に書かない。** ここで守るべきは「外れて理由が出る」ことである。
        // 文言の違いそのものは `testAccessDeniedDetachesTooButSaysSomethingDifferent` が
        // `SophiaError` を直に渡して決定的に固定している。
        XCTAssertTrue(
            notice.kind == .unavailable || notice.kind == .accessDenied,
            "外したのに知らせの種類が「結び付けに失敗」になっている: \(notice.kind)")
    }

    /// **往復の失敗をきっかけに、原因を確かめて外れること**（`.toolResult` → 診断 → 解除）。
    ///
    /// 利用者から見える経路はこれである ── モデルが読もうとして失敗し、
    /// **その理由がフォルダごと駄目だったとき**に、結び付けが外れて選び直しを促される。
    /// 「分岐が正しい」と「誰かが呼ぶ」は別で、ここは後者を見ている。
    func testAFailedRoundTripTriggersTheDiagnosisThatDetaches() async throws {
        let folder = try await armedFolder()
        let engine = ScriptedEngine(script: [
            .toolCall(ModelToolCall(name: "read_file", argumentsJSON: #"{"path":"notes.md"}"#)),
            .toolResult(ToolActivity(
                toolName: "read_file", summary: "read_file: 失敗: 読めませんでした。",
                isFailure: true, round: 1)),
        ])
        let model = ChatViewModel(engine: engine, folder: folder)

        // 失敗の**後ろで**フォルダを消す。往復の失敗そのものは理由を語らない。
        try FileManager.default.removeItem(at: directory)

        model.input = "読んで"
        model.send()
        await settle(model)
        try await waitUntil("往復の失敗から結び付けが外れない（16.8節）") { !folder.isArmed }

        // `kind` を固定しない理由は `testDeletingTheFolderOnDiskDetachesTheBinding` と同じ。
        XCTAssertEqual(folder.notice?.didDetach, true)
        XCTAssertEqual(folder.toolDefinitions, [], "外れたのにツール定義が残っている")
        XCTAssertEqual(folder.toolDefinitionTokens, 0)
    }

    /// **生成そのものが結び付けの失敗で終わったときも外れること。**
    ///
    /// いまの実装ではツールの失敗は例外にならない（実行役は throw しない約束）。
    /// それでも `code` を見る場所を1つに揃えてあるので、**この経路が増えても握り漏らさない。**
    func testAGenerationErrorCarryingTheCodeAlsoDetaches() async throws {
        let folder = try await armedFolder()
        let engine = ScriptedEngine(
            script: [], failure: SophiaError(code: .folderAccessDenied))
        let model = ChatViewModel(engine: engine, folder: folder)

        model.input = "読んで"
        model.send()
        await settle(model)

        XCTAssertFalse(folder.isArmed)
        XCTAssertEqual(folder.notice?.kind, .accessDenied)
        XCTAssertEqual(model.turns.last?.phase, .failed, "失敗そのものは今までどおり出ること")
    }

    /// **読める間は外さない。** 確認のたびに外れたら使い物にならない。
    func testVerifyingAHealthyFolderChangesNothing() async throws {
        let folder = try await armedFolder()

        await folder.verifyBinding()

        XCTAssertTrue(folder.isArmed)
        XCTAssertNil(folder.notice)
    }

    /// 利用者が自分で外したときは知らせを出さないこと（自分でやったことである）。
    func testForgettingByHandShowsNoNotice() async throws {
        let folder = try await armedFolder()
        folder.receive(SophiaError(code: .folderUnavailable))
        XCTAssertNotNil(folder.notice)

        folder.forget()

        XCTAssertFalse(folder.isArmed)
        XCTAssertNil(folder.notice, "自分で外したのに知らせが残っている")
    }

    // =========================================================================
    //  補助
    // =========================================================================

    private func emptyStore() -> InMemoryFolderBookmarkStore {
        // **利用者の `UserDefaults` を触らないこと。** テストはホストアプリ
        // （`Sophia.app`）のプロセスで走るので、既定の置き場を使うと設定を書き換える。
        InMemoryFolderBookmarkStore()
    }

    /// **`NSOpenPanel` を出さずに `armed` を作る。**
    ///
    /// パネルは単体テストから開けないので、**保存済みブックマークからの復元**
    /// （機能3）を使って同じ状態に到達する。復元は実装の本物の経路であり、
    /// `SecurityScopedFolder.unscoped` のような試験専用の抜け道ではない。
    ///
    /// ブックマークを作れない環境では**その旨を言って skip する。**
    /// 黙って通すと「試験は緑だが何も確かめていない」になる
    /// （作れるかどうかは `SecurityScopedBookmarkProbeTests` が単独で測っている）。
    private func armedFolder() async throws -> ConversationFolder {
        let data: Data
        do {
            data = try directory.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw XCTSkip("""
                セキュリティスコープ付きブックマークを作れないため、`armed` を作れません: \(error)
                `SecurityScopedBookmarkProbeTests` を先に見ること（entitlement の問題である可能性）。
                """)
        }

        let folder = ConversationFolder(
            access: FolderAccess(bookmarks: InMemoryFolderBookmarkStore(initial: data)))
        // **本物の復元経路を通す。** `restoreOnLaunch()` は復元したあと
        // 読めるかまで確かめる（`verifyBinding()`）ので、ここを抜けた時点で
        // 「結び付いていて、実際に読める」が両方成立している。
        await folder.restoreOnLaunch()

        guard folder.isArmed else {
            throw XCTSkip("保存済みブックマークから復元できませんでした（16.9節 項目2 の未確認事項）")
        }
        return folder
    }

    /// 生成が終わるまで待つ。**時間で決め打ちしない** ── 遅い機体で緑にならなくなる。
    private func settle(_ model: ChatViewModel, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while model.isGenerating, ContinuousClock().now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        // 間引き（16ms）の書き戻しを1回ぶん待つ。
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// 条件が成立するまで待つ。**成立しなければ理由を言って落ちる**（黙って待たない）。
    private func waitUntil(
        _ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock().now >= deadline { XCTFail(what); return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - 試験用のエンジン

/// **送られた `ChatOptions` を捕まえるだけのエンジン。**
///
/// FR-21 は「渡していないつもり」では確かめられない ──
/// **実際に境界を越えた値**を見る必要がある。生成はすぐ終わる。
private final class RecordingEngine: InferenceEngine, @unchecked Sendable {

    let identifier: EngineIdentifier = .stub

    private let lock = NSLock()
    private var recorded: ChatOptions?

    var lastOptions: ChatOptions? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func loadedModel() async -> ModelInfo? { nil }

    func capabilities() async -> EngineCapabilities {
        EngineCapabilities(
            supportsThinking: true, canDisableThinking: true,
            maxContextLength: SophiaDefaults.contextLength)
    }

    func availableModels() async throws -> [ModelInfo] { [] }

    func load(_ modelID: String) -> AsyncThrowingStream<LoadProgress, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func unload() async {}

    func chat(
        _ messages: [SophiaMessage], options: ChatOptions
    ) -> AsyncThrowingStream<Chunk, any Error> {
        lock.lock()
        recorded = options
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.content("はい"))
            continuation.yield(
                .done(
                    GenerationStats(
                        ttftMs: 1, tokensPerSecond: 1, inputTokens: 1, outputTokens: 1)))
            continuation.finish()
        }
    }
}

/// **決めた順番で `Chunk` を流すだけのエンジン。**
///
/// 往復の表示（16.7節）を確かめるには `.toolCall` / `.toolResult` が要るが、
/// `StubEngine` も `MockEngine` もツールを扱わない（扱わなくてよい約束である）。
/// **本物の推論を持ち込まずに、UI が受け取る形だけを再現する。**
private final class ScriptedEngine: InferenceEngine, @unchecked Sendable {

    let identifier: EngineIdentifier = .stub

    private let script: [Chunk]
    /// 台本を流し終えても**終端を送らずに開いたまま待つ**か。
    /// 「往復の最中」を観測するために要る ── 待つのは時間ではなく `release()` である。
    private let holdsOpen: Bool
    /// 台本のあとに投げる失敗。nil なら正常終了する。
    private let failure: SophiaError?

    private let lock = NSLock()
    private var released = false

    init(script: [Chunk], holdsOpen: Bool = false, failure: SophiaError? = nil) {
        self.script = script
        self.holdsOpen = holdsOpen
        self.failure = failure
    }

    /// 開いたままの生成を終わらせる。
    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    private var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    func loadedModel() async -> ModelInfo? { nil }

    func capabilities() async -> EngineCapabilities {
        EngineCapabilities(
            supportsThinking: true, canDisableThinking: true,
            maxContextLength: SophiaDefaults.contextLength)
    }

    func availableModels() async throws -> [ModelInfo] { [] }

    func load(_ modelID: String) -> AsyncThrowingStream<LoadProgress, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func unload() async {}

    func chat(
        _ messages: [SophiaMessage], options: ChatOptions
    ) -> AsyncThrowingStream<Chunk, any Error> {
        let script = self.script
        let holdsOpen = self.holdsOpen
        let failure = self.failure
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                for chunk in script { continuation.yield(chunk) }
                if holdsOpen {
                    // **待ちの上限を置く。** 合図が来なくても永久には待たない
                    // （待ち続けるテストは、落ちるテストより質が悪い）。
                    let deadline = ContinuousClock().now.advanced(by: .seconds(10))
                    while self?.isReleased == false, ContinuousClock().now < deadline {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                }
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                continuation.yield(
                    .done(
                        GenerationStats(
                            ttftMs: 1, tokensPerSecond: 1, inputTokens: 1, outputTokens: 1)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
