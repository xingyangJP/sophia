import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import XCTest

@testable import Sophia

// =============================================================================
//  推論エンジンとツール呼び出しの結線（FR-19 / FR-21 / DESIGN.md 第16章）
// -----------------------------------------------------------------------------
//  **`ToolCallProbeTests` が測ったのはモデルの能力であって、この結線ではない。**
//  あちらは `MLXLMCommon` を直接叩いており、`MLXEngine` を1行も通っていない。
//  「モデルが呼べる」と「アプリが呼べる」は別である ── その差を埋めたのがこの結線で、
//  本ファイルはその**形**を固定する。
//
//  ## このファイルの大半はモデルを読み込まない
//
//  `MLXEngine` からツール関係の判断を `static` 関数に切り出してあるので、
//  4.6GB を読まずに実行できる（`make app-test` に混ざってよい速度である）。
//  固定しているのは3つ。
//
//  | 何を | どこで |
//  |---|---|
//  | **`idle` では tools を渡さない**（FR-21。テンプレートの門が開かない） | `testIdle…` |
//  | **`.toolCall` は思考分離器を通らない**（FR-17 を壊していない） | `testToolCall…` |
//  | ツール定義の JSON が、実測で通った形と一致する | `testToolSpec…` |
//
//  ## 実トークン数の測定だけは別（重い）
//
//  末尾の `testToolDefinitionTokenCost` は**モデルを読み込む。**
//  `SOPHIA_TOOLTOKENS=1` のときだけ走る（`PrefillProbeTests` /
//  `ToolCallProbeTests` と同じ作法）。
//
//  ```
//  # 先に make probe-build。あとは toolprobe と同じ要領で
//  #   環境変数 SOPHIA_TOOLTOKENS=1
//  #   -only-testing:SophiaTests/EngineToolWiringTests/testToolDefinitionTokenCost
//  ```
//
//  **これが 16.2節「費用は測ること」と 16.9節の項目4 への答えになる。**
//  概算では駄目である ── 発見19 で概算が実測に対し 1.47倍 ずれることが確定している。
// =============================================================================

final class EngineToolWiringTests: XCTestCase {

    // MARK: - 試験用のツール定義（16.4節の3つ）

    /// **本番の定義ではない。** 実物は `Sources/Tools/` の担当が持つ。
    /// ここに置いてあるのは、結線の形を固定するための見本である。
    ///
    /// 文面は `ToolCallProbeTests` が実測に使ったものと**同一**にしてある。
    /// 形が変わったことに気づけるようにするためで、揃えておく意味はそこにしかない。
    private static let folderTools: [ToolDefinition] = [
        ToolDefinition(
            name: "list_directory",
            description: "指定したディレクトリの中身を一覧する",
            parameters: [
                ToolDefinition.Parameter(
                    name: "path", type: .string, description: "ディレクトリのパス",
                    isRequired: true)
            ]),
        ToolDefinition(
            name: "read_file",
            description: "ファイルの中身を読む。長い場合は範囲を指定する",
            parameters: [
                ToolDefinition.Parameter(
                    name: "path", type: .string, description: "ファイルのパス", isRequired: true),
                ToolDefinition.Parameter(
                    name: "offset", type: .integer, description: "開始行（1始まり）",
                    isRequired: false),
                ToolDefinition.Parameter(
                    name: "limit", type: .integer, description: "読む行数", isRequired: false),
            ]),
        ToolDefinition(
            name: "search_files",
            description: "ディレクトリ配下から文字列を含むファイルを探す",
            parameters: [
                ToolDefinition.Parameter(
                    name: "path", type: .string, description: "探索の起点", isRequired: true),
                ToolDefinition.Parameter(
                    name: "query", type: .string, description: "探す文字列", isRequired: true),
            ]),
    ]

    // MARK: - FR-21: 注入は会話の状態で切る（16.2節）

    /// **既定は `idle` である。** 何も指定しなければツールは1つも渡らない。
    ///
    /// 順序が逆（既定で渡し、要らないときに切る）だと、切り忘れが即座に
    /// 毎ターンの費用になる。**危険な側を明示的にしておくこと。**
    func testDefaultOptionsAreIdle() {
        XCTAssertTrue(ChatOptions().tools.isEmpty, "既定でツールを渡している。FR-21 の既定が逆になっている")
    }

    /// **FR-21 の本体。** 空なら `nil` になり、テンプレートの `{%- if tools %}` が開かない。
    ///
    /// `[]` を渡しても Jinja では偽なので結果は同じだが、**依存先の真偽値の扱いに
    /// 頼らない。** ここで nil にしておけば、テンプレートが変わっても 0 が保たれる。
    func testIdleSendsNoToolsSoTheTemplateGateStaysShut() {
        XCTAssertNil(MLXEngine.toolSpecs(for: []), "空のときに nil を返していない。FR-21 の門が開く")

        // 実際に組み上がる `UserInput` まで見る。**「渡していないつもり」で終わらせない。**
        let input = UserInput(
            chat: [.user("こんにちは")],
            tools: MLXEngine.toolSpecs(for: ChatOptions().tools),
            additionalContext: ["enable_thinking": false])

        XCTAssertNil(input.tools, "既定の ChatOptions から UserInput.tools が非 nil になっている")
    }

    /// `armed` のときは、宣言したぶんだけが渡る。**多くも少なくもならないこと。**
    func testArmedSendsExactlyTheDeclaredTools() throws {
        let specs = try XCTUnwrap(MLXEngine.toolSpecs(for: Self.folderTools))

        XCTAssertEqual(specs.count, Self.folderTools.count)

        let names = specs.compactMap { spec in
            (spec["function"] as? [String: any Sendable])?["name"] as? String
        }
        XCTAssertEqual(names, ["list_directory", "read_file", "search_files"])
    }

    /// **実測で通った形と同じ JSON が出ること。**
    ///
    /// 2026-08-18 の `make toolprobe` は、この形で 選択12/12・スキーマ適合12/12・誤爆0/6 だった。
    /// **通ったのは「ツール呼び出し一般」ではなく、この形である。**
    /// だから形を1文字単位で固定する ── 変えたら測り直すこと。
    ///
    /// > `JSONSerialization` に掛けているのは**比較のためだけではない。**
    /// > 掛かること自体が「テンプレートへ渡せる値だけで組めている」ことの検査になる。
    /// > （`[String: JSONValue]` に `isValidJSONObject` を掛けて嘘の結論を出した
    /// >  16.9節の失敗とは別物である。あちらは MLX の型付き値、こちらは素の辞書）
    func testToolSpecMatchesTheShapeMeasuredOnTheModel() throws {
        let spec = MLXEngine.toolSpec(for: Self.folderTools[2])  // search_files

        let data = try JSONSerialization.data(
            withJSONObject: spec, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(
            json,
            #"{"function":{"description":"ディレクトリ配下から文字列を含むファイルを探す","#
                + #""name":"search_files","parameters":{"properties":{"#
                + #""path":{"description":"探索の起点","type":"string"},"#
                + #""query":{"description":"探す文字列","type":"string"}},"#
                + #""required":["path","query"],"type":"object"}},"type":"function"}"#)
    }

    /// 必須でない引数は `required` に入らない（`read_file` の `offset` / `limit`）。
    ///
    /// **ここを間違えると往復が増える。** 全部必須にすると、モデルは窓を指定できない
    /// ときにも値を捏造するか、呼ぶのをやめる。
    func testOptionalParametersStayOutOfRequired() throws {
        let spec = MLXEngine.toolSpec(for: Self.folderTools[1])  // read_file
        let function = try XCTUnwrap(spec["function"] as? [String: any Sendable])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: any Sendable])

        XCTAssertEqual(parameters["required"] as? [String], ["path"])

        let properties = try XCTUnwrap(parameters["properties"] as? [String: any Sendable])
        XCTAssertEqual(Set(properties.keys), ["path", "offset", "limit"])
    }

    /// `ChatOptions` が `Equatable` / `Codable` のままであること。
    ///
    /// **ツール定義を `[ToolSpec]`（`[String: any Sendable]`）で持たなかった理由がこれ。**
    /// あの型を入れた瞬間に両方失われ、`Shared/` が MLX を知ることにもなる（NFR-09）。
    func testChatOptionsSurvivesEncodingWithTools() throws {
        let original = ChatOptions(tools: Self.folderTools)
        let restored = try JSONDecoder().decode(
            ChatOptions.self, from: JSONEncoder().encode(original))

        XCTAssertEqual(original, restored)
        XCTAssertNotEqual(original, ChatOptions(), "tools が等値比較に効いていない")
    }

    /// **出荷する定義が、実測で通った JSON の形になることを縛る。**
    ///
    /// > **2026-08-18 に書き直した。記録を残す。**
    /// > 以前ここは `FolderTool.jsonSchemas`（生の辞書）と
    /// > `ToolDefinition` 経由の再構成が一致することを見ていた。
    /// > **同じ定義を2つの形で持っていたからで、その割れ自体が今日2回、嘘の値を生んだ**
    /// > （このファイルの `folderTools` が生んだ「716トークン」／実費は 1,182）。
    /// > **`jsonSchemas` を消して出所を1本にしたので、比べる相手はもう無い。**
    /// > 代わりに、**出荷する定義がテンプレートへ渡る形そのもの**をここで固定する。
    ///
    /// 固定するのは形だけで、**文言は固定しない** ── 文言の錠は
    /// `ToolExecutionTests.testTheDescriptionsAreExactlyWhatWasMeasured` にある。
    /// 分けてあるのは、落ちたときに「形が変わった」のか
    /// 「文言が変わった（＝測り直しが要る）」のかを取り違えないためである。
    ///
    /// **落ちるとしたら意味がある** ── 例えばツール層が `array` 型の引数を足すと、
    /// `ToolDefinition.Parameter.ValueType` が表せず宣言の側で止まる（16.4節が入れ子を避けている理由）。
    func testTheShippedCatalogRendersTheSchemaShapeThatWasMeasured() throws {
        let specs = FolderTool.definitions.map(MLXEngine.toolSpec(for:))
        XCTAssertEqual(specs.count, 5)  // 2026-09-06: search_web を出荷（FR-30）

        for (definition, spec) in zip(FolderTool.definitions, specs) {
            XCTAssertEqual(spec["type"] as? String, "function")

            let function = try XCTUnwrap(spec["function"] as? [String: any Sendable])
            XCTAssertEqual(function["name"] as? String, definition.name)
            XCTAssertEqual(function["description"] as? String, definition.description)

            let parameters = try XCTUnwrap(function["parameters"] as? [String: any Sendable])
            XCTAssertEqual(parameters["type"] as? String, "object")
            // **`required` は宣言の並び順**（`ToolDefinition` が辞書ではなく配列で
            // 引数を持っている理由がこれ。並びが揺れると比較も実測の再現もできない）。
            XCTAssertEqual(
                parameters["required"] as? [String], definition.requiredParameterNames)

            let properties = try XCTUnwrap(parameters["properties"] as? [String: any Sendable])
            XCTAssertEqual(
                Set(properties.keys), Set(definition.parameters.map(\.name)),
                "宣言した引数がスキーマに出ていない: \(definition.name)")
            for parameter in definition.parameters {
                let property = try XCTUnwrap(properties[parameter.name] as? [String: any Sendable])
                XCTAssertEqual(property["type"] as? String, parameter.type.rawValue)
                XCTAssertEqual(property["description"] as? String, parameter.description)
            }

            // `UserInput(chat:tools:)` は `tool | tojson` を通す。**JSON にできること**が要る。
            XCTAssertNoThrow(try Self.json(spec), "JSON にできない定義: \(definition.name)")
        }
    }

    /// 辞書を比較可能な1本の文字列にする（キー順を固定するのが目的）。
    private static func json(_ object: [String: any Sendable]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    // MARK: - FR-17 を壊していないこと（16.1節「生成ストリームの側」）

    /// **`.toolCall` は思考分離器を通らない。**
    ///
    /// 通してしまうと `<tool_call>` の JSON が本文か思考のどちらかに現れ、
    /// FR-17 の分離が UI 側で崩れる。振り分けを `static` に切り出してあるのは、
    /// この1点をモデル無しで固定するためである。
    func testToolCallGoesAroundTheThinkingSeparator() {
        let call = ToolCall(
            function: .init(name: "list_directory", arguments: ["path": .string("docs")]),
            id: "call-1")

        XCTAssertEqual(
            MLXEngine.route(.toolCall(call), toolsWereSent: true),
            .passThrough(
                .toolCall(
                    ModelToolCall(
                        name: "list_directory", argumentsJSON: #"{"path":"docs"}"#,
                        callID: "call-1"))))

        // 本文は従来どおり分離器へ行く（こちらを壊していないことも同時に見る）。
        XCTAssertEqual(MLXEngine.route(.chunk("本文"), toolsWereSent: true), .separatorText("本文"))
    }

    /// **エンジンの受け取りループを、そのままの順序で再現する。**
    ///
    /// 個々の振り分けが正しくても、繋いだときに分離器へ入っていたら意味が無い。
    /// ここでは `MLXEngine.performChat` と同じ手順（`route` → 分離器 or 素通し →
    /// 最後に `finalize`）を踏み、**思考にも本文にもツールの痕跡が無い**ことを見る。
    func testThinkingSeparatorNeverSeesToolCallText() {
        let call = ToolCall(
            function: .init(
                name: "search_files",
                arguments: ["path": .string("docs"), "query": .string("請求書")]),
            id: nil)

        // 実際に流れてくる順序（思考 → ツール呼び出し → 本文）。
        let stream: [Generation] = [
            .chunk("<think>フォルダを"),
            .chunk("探す</think>"),
            .toolCall(call),
            .chunk("見つけました"),
        ]

        var separator: any ThinkingSeparating = ThinkingSplitter()
        var chunks: [Chunk] = []

        for item in stream {
            switch MLXEngine.route(item, toolsWereSent: true) {
            case .separatorText(let text):
                for segment in separator.process(text) { chunks.append(chunk(for: segment)) }
            case .passThrough(let chunk):
                chunks.append(chunk)
            default:
                break
            }
        }
        for segment in separator.finalize() { chunks.append(chunk(for: segment)) }

        let thinking = chunks.compactMap { chunk -> String? in
            if case .thinking(let text) = chunk { return text }
            return nil
        }.joined()
        let content = chunks.compactMap { chunk -> String? in
            if case .content(let text) = chunk { return text }
            return nil
        }.joined()
        let toolCalls = chunks.compactMap { chunk -> ModelToolCall? in
            if case .toolCall(let request) = chunk { return request }
            return nil
        }

        XCTAssertEqual(thinking, "フォルダを探す")
        XCTAssertEqual(content, "見つけました")
        XCTAssertEqual(toolCalls.count, 1)

        // **本題。** 引数の中身が思考にも本文にも1文字も混ざっていないこと。
        for text in [thinking, content] {
            XCTAssertFalse(text.contains("請求書"), "ツールの引数が分離器を通って漏れている: \(text)")
            XCTAssertFalse(text.contains("tool_call"), "ツール呼び出しの記法が本文へ漏れている: \(text)")
            XCTAssertFalse(text.contains("search_files"), "ツール名が本文へ漏れている: \(text)")
        }
    }

    /// 思考分離そのものが、ツール結線の前後で変わっていないこと（FR-17 の回帰止め）。
    func testThinkingSplitterBehaviourIsUnchanged() {
        var splitter = ThinkingSplitter()
        var segments = splitter.process("<think>考えた</think>答え")
        segments += splitter.finalize()

        XCTAssertEqual(segments, [.thinking("考えた"), .content("答え")])
    }

    // MARK: - 16.6節の約束3: 注入の状態をモデルの出力で変えない

    /// **ツールを渡していない会話で呼ばれても流さない。**
    ///
    /// 流すと「モデルが呼んだからツールが使える」という経路ができる。
    /// 16.6節の約束3 は `idle` → `armed` を**利用者の操作だけ**に限っており、
    /// ここはその最後の関門である。**ただし黙って捨てない**（`[TOOL]` 行に残る）。
    func testToolCallIsDroppedWhenNoToolsWereSent() {
        let call = ToolCall(
            function: .init(name: "read_file", arguments: ["path": .string("/etc/passwd")]))

        XCTAssertEqual(
            MLXEngine.route(.toolCall(call), toolsWereSent: false),
            .unexpectedToolCall(name: "read_file"))
    }

    /// 拒否された呼び出しは、**理由と名前だけ**を運ぶ。
    ///
    /// `rawTextPreview` には利用者のファイル名や検索語が入る。
    /// MLX 側も「ライブラリが自動でログや永続化に載せてはならない」と明記している。
    /// NFR-01（会話を端末の外に出さない）はログ経由の流出も含む。
    func testRejectedToolCallDoesNotCarryTheRawOutput() {
        let rejection = RejectedToolCall(
            reason: .undeclaredTool,
            format: .json,
            toolName: "delete_everything",
            rawText: #"{"name":"delete_everything","arguments":{"path":"社外秘.md"}}"#)

        let route = MLXEngine.route(.rejectedToolCall(rejection), toolsWereSent: true)

        XCTAssertEqual(
            route, .rejected(reason: "undeclared_tool", toolName: "delete_everything"))
        XCTAssertFalse("\(route)".contains("社外秘"), "拒否された原文がログ経路へ流れている")
    }

    /// `.info` は行き先だけを返し、中身は運ばない
    /// （`GenerateCompletionInfo` が `Equatable` でないため。運ぶと固定できなくなる）。
    func testCompletionRouteCarriesNoPayload() {
        let info = GenerateCompletionInfo(
            promptTokenCount: 10, generationTokenCount: 20, promptTime: 1, generationTime: 2)

        XCTAssertEqual(MLXEngine.route(.info(info), toolsWereSent: false), .completion)
    }

    // MARK: - 引数の受け取り（`ModelToolCall` → `Tools/ToolCallRequest`）

    /// 日本語の引数がそのまま届き、キー順が固定されること。
    ///
    /// 順が動くと**同じ呼び出しが別物に見える** ── 等値比較もログの突き合わせも壊れる。
    func testArgumentsKeepJapaneseAndSortKeys() {
        let call = ToolCall(
            function: .init(
                name: "search_files",
                arguments: ["query": .string("請求書"), "path": .string("~/Documents")]))

        let emitted = MLXEngine.modelToolCall(from: call)

        XCTAssertEqual(emitted.argumentsJSON, #"{"path":"~/Documents","query":"請求書"}"#)
        XCTAssertEqual(emitted.name, "search_files")
        XCTAssertNil(emitted.callID)
    }

    /// **推論層とツール層が実際に繋がること。**
    ///
    /// ここが「実装がある」と「動く」の境目である。`ModelToolCall` は運ぶだけの型で、
    /// 解釈は `Tools/ToolCallRequest`（`init(name:jsonArguments:)`）が持っている。
    /// **その受け渡しを1回でも通しておかないと、両側が独立に正しいまま繋がらない。**
    ///
    /// > このテストだけは `Sources/Tools/` の API に依存している。
    /// > 向こうが形を変えたらここで落ちる ── **落ちてよい。それが橋の役目である。**
    func testEmittedCallCrossesIntoTheToolLayer() {
        let call = ToolCall(
            function: .init(
                name: "read_file",
                arguments: [
                    "path": .string("notes.md"), "offset": .int(1), "limit": .string("80"),
                ]))

        let emitted = MLXEngine.modelToolCall(from: call)
        let request = ToolCallRequest(name: emitted.name, jsonArguments: emitted.argumentsData)

        XCTAssertEqual(request.name, "read_file")
        XCTAssertEqual(request.arguments.string("path"), "notes.md")
        XCTAssertEqual(request.arguments.integer("offset"), 1)
        // 引用符付きの数値。**緩く読むのはツール層の判断**であり、
        // 推論層は原文を変えずに渡すだけでよい（同じ判断を2か所に置かない）。
        XCTAssertEqual(request.arguments.integer("limit"), 80)
    }

    /// 引数が壊れていても落ちない。**空として扱い、呼び出しは残す。**
    /// 呼び出しごと消すと、モデルには「無視された」としか見えず同じ手を繰り返す。
    func testBrokenArgumentsDegradeToEmpty() {
        let emitted = ModelToolCall(name: "read_file", argumentsJSON: "これはJSONではない")
        let request = ToolCallRequest(name: emitted.name, jsonArguments: emitted.argumentsData)

        XCTAssertTrue(request.arguments.values.isEmpty)
        XCTAssertNil(request.arguments.string("path"))
    }

    // MARK: - SophiaError（16.8節）

    /// 足した2つのケースが、そのまま画面に出せる日本語を持つこと（FR-11）。
    func testFolderErrorCodesCarryJapaneseGuidance() {
        for code in [SophiaError.Code.folderAccessDenied, .folderUnavailable] {
            let error = SophiaError(code: code)

            XCTAssertFalse(error.message.isEmpty, "message が空: \(code)")
            XCTAssertFalse(error.hint?.isEmpty ?? true, "FR-11: 対処が無い: \(code)")
            XCTAssertFalse(error.isCancellation)
            // rawValue は永続化と突き合わせに使う。綴りを勝手に変えないこと。
            XCTAssertEqual(SophiaError.Code(rawValue: code.rawValue), code)
        }
    }

    // MARK: - 実トークン数の測定（重い。`SOPHIA_TOOLTOKENS=1` のときだけ走る）

    /// **FR-21 が「本当に 0 か」を実トークナイザで確かめる**（16.2節 / 16.9節の項目4）。
    ///
    /// 見ているのは2つ。
    ///
    /// 1. **`idle` の入力が、ツールという概念が無かった頃と1トークンも変わらないこと。**
    ///    `MLXEngine.toolSpecs(for: [])` を通した入力と、`tools` 引数そのものを
    ///    書かなかった入力を比べる。**差が 0 でなければ FR-21 は守れていない。**
    /// 2. **`armed` のとき、定義がいくら掛かるのか。**
    ///    `SophiaDefaults.inputTokenBudget = 1000` に対する割合まで出す。
    ///    **概算は使わない** ── 発見19 で 1.47倍 ずれることが確定している。
    func testToolDefinitionTokenCost() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SOPHIA_TOOLTOKENS"] == "1",
            "実トークナイザでツール定義の費用を測ります。`SOPHIA_TOOLTOKENS=1` のときだけ走ります")

        let modelID = SophiaDefaults.modelID
        let container = try await loadModelContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: MLXModelCatalog.configuration(for: modelID))
        log("LOADED model=\(modelID)")

        // 実使用に一番近い最小の会話。**自己認識（FR-23）も入れる** ──
        // 「こんにちは」1往復の実費を知りたいのであって、素の性能ではない。
        func chat() -> [Chat.Message] {
            [.system(SophiaDefaults.systemPrompt), .user("こんにちは")]
        }
        let context: [String: any Sendable] = ["enable_thinking": false]

        // `fixedPreamble = 105` を、**同じ prepare の差分**で分解する。
        // 生の本文だけを別に encode して引くと、テンプレート境界で BPE の切れ方が変わりうる。
        // 空の本文から1要素ずつ足せば、単位も描画経路も揃ったまま差を取れる。
        let userEmpty = try await container.prepare(
            input: UserInput(chat: [.user("")], additionalContext: context))
        let userShort = try await container.prepare(
            input: UserInput(chat: [.user("こんにちは")], additionalContext: context))
        let systemEmptyUserEmpty = try await container.prepare(
            input: UserInput(chat: [.system(""), .user("")], additionalContext: context))
        let systemFullUserEmpty = try await container.prepare(
            input: UserInput(
                chat: [.system(SophiaDefaults.systemPrompt), .user("")],
                additionalContext: context))

        let userEmptyCount = userEmpty.text.tokens.asArray(Int.self).count
        let userShortCount = userShort.text.tokens.asArray(Int.self).count
        let systemEmptyUserEmptyCount = systemEmptyUserEmpty.text.tokens.asArray(Int.self).count
        let systemFullUserEmptyCount = systemFullUserEmpty.text.tokens.asArray(Int.self).count

        // ① tools 引数を書かなかった場合（ツールという概念が無かった頃）
        let baseline = try await container.prepare(
            input: UserInput(chat: chat(), additionalContext: context))
        let baselineTokens = baseline.text.tokens.asArray(Int.self)

        let userBodyWithoutSystem = userShortCount - userEmptyCount
        let emptySystemMessage = systemEmptyUserEmptyCount - userEmptyCount
        let systemBody = systemFullUserEmptyCount - systemEmptyUserEmptyCount
        let userBodyAfterSystem = baselineTokens.count - systemFullUserEmptyCount
        let tokenizer = await container.tokenizer
        let encodedSystemBody = tokenizer.encode(
            text: SophiaDefaults.systemPrompt, addSpecialTokens: false
        ).count
        let encodedUserBody = tokenizer.encode(
            text: "こんにちは", addSpecialTokens: false
        ).count
        log("""
            PREAMBLE user_empty=\(userEmptyCount) user_short=\(userShortCount) \
            system_empty_user_empty=\(systemEmptyUserEmptyCount) \
            system_full_user_empty=\(systemFullUserEmptyCount) \
            system_full_user_short=\(baselineTokens.count)
            """)
        log("""
            PREAMBLE_DELTA user_body_without_system=\(userBodyWithoutSystem) \
            empty_system_message=\(emptySystemMessage) system_body=\(systemBody) \
            user_body_after_system=\(userBodyAfterSystem) \
            encoded_system_body=\(encodedSystemBody) encoded_user_body=\(encodedUserBody)
            """)

        // ② `idle` を我々の API で通した場合。**①と1トークンも違ってはいけない**
        let idle = try await container.prepare(
            input: UserInput(
                chat: chat(), tools: MLXEngine.toolSpecs(for: []), additionalContext: context))
        let idleTokens = idle.text.tokens.asArray(Int.self)

        // ③ `armed`（16.4節の3つ）
        //
        // **`Self.folderTools`（このファイルの見本）を渡さないこと。**
        // 2026-08-18、ここが見本を測って**「716トークン」という嘘の実費**を出した
        // （実費は 1,182）。出所は `FolderTool.definitions` の1本だけである。
        let armed = try await container.prepare(
            input: UserInput(
                chat: chat(), tools: MLXEngine.toolSpecs(for: FolderTool.definitions),
                additionalContext: context))
        let armedTokens = armed.text.tokens.asArray(Int.self)

        let delta = armedTokens.count - baselineTokens.count
        let percent = Double(delta) / Double(SophiaDefaults.inputTokenBudget) * 100

        log("""
            COST baseline=\(baselineTokens.count) idle=\(idleTokens.count) \
            armed=\(armedTokens.count) delta=\(delta) \
            budget=\(SophiaDefaults.inputTokenBudget) pct=\(String(format: "%.1f", percent))
            """)

        // **描画された文字列でも見る。** 数字だけだと「なぜ 0 なのか」が残らない。
        let idleText = await container.decode(tokenIds: idleTokens)
        let armedText = await container.decode(tokenIds: armedTokens)
        log("IDLE_HAS_TOOLS_BLOCK=\(idleText.contains("<tools>")) "
            + "ARMED_HAS_TOOLS_BLOCK=\(armedText.contains("<tools>"))")

        XCTAssertEqual(
            idleTokens.count, baselineTokens.count,
            "**FR-21 が守れていない。** idle なのにツール経由で入力が増えている")
        XCTAssertFalse(
            idleText.contains("<tools>"), "**FR-21 が守れていない。** idle で <tools> が描画されている")
        XCTAssertTrue(
            armedText.contains("<tools>"), "armed なのに <tools> が描画されていない（渡せていない）")
        XCTAssertGreaterThan(delta, 0, "armed で入力が増えていない。tools が届いていない疑い")

        XCTAssertEqual(
            baselineTokens.count, SophiaDefaults.InputBudget.fixedPreamble,
            "`fixedPreamble` が実トークナイザの baseline と食い違っている")
        XCTAssertGreaterThan(userEmptyCount, 0, "空の user でもテンプレート固定分は存在する")
        XCTAssertGreaterThan(emptySystemMessage, 0, "system 発言のテンプレート固定分が取れていない")
        XCTAssertGreaterThan(systemBody, 0, "自己認識本文の差分が取れていない")
        XCTAssertGreaterThan(userBodyAfterSystem, 0, "短い user 本文の差分が取れていない")
        XCTAssertEqual(
            emptySystemMessage, SophiaDefaults.InputBudget.perMessageTemplateOverhead,
            "1発言ぶんのテンプレート固定値が実測と食い違っている")
        XCTAssertEqual(
            userEmptyCount - emptySystemMessage,
            SophiaDefaults.InputBudget.generationPromptOverhead,
            "assistant 生成開始ぶんの固定値が実測と食い違っている")
        XCTAssertEqual(
            encodedSystemBody, systemBody,
            "本文だけの encode と、テンプレート内で本文を足した差分が一致しない")
        XCTAssertEqual(
            encodedUserBody, userBodyAfterSystem,
            "短い user 本文の encode と、テンプレート内で本文を足した差分が一致しない")
        XCTAssertEqual(
            userEmptyCount + emptySystemMessage + systemBody + userBodyAfterSystem,
            baselineTokens.count,
            "分解した差分の合計が baseline に戻らない")

        // #286 の本体も、同じ実トークナイザで測る。
        // 候補ごとに tools / role / tool_calls / tool_response / 生成開始まで丸ごと描画し、
        // 最後の `prepare` と同じ単位で予算判定できていることを固定する。
        var sixReadTranscript: [RoundTripMessage] = [
            .system(SophiaDefaults.systemPrompt),
            .user("log の6つを見て、どれに NEEDLE があるか教えて"),
        ]
        for index in 1...6 {
            let contents = (["NEEDLE-\(index)"]
                + (2...400).map { "line \($0): padding padding padding" })
                .joined(separator: "\n") + "\n"
            let read = ContextWindow.clip(
                contents, path: "log/\(index).log", budget: .singleRead)
            let outcome = ToolResult
                .content(read, tool: "read_file", isListing: false)
                .executionOutcome(callID: "measure-\(index)")
            let call = ToolCall(
                function: .init(name: "read_file", arguments: [:]), id: outcome.callID)
            sixReadTranscript.append(.assistant("", toolCalls: [call]))
            sixReadTranscript.append(MLXEngine.transcriptEntry(for: outcome))
        }
        let sixReadCompaction = MLXEngine.compacted(
            sixReadTranscript,
            budget: SophiaDefaults.InputBudget.total,
            tokenizer: tokenizer,
            tools: MLXEngine.toolSpecs(for: FolderTool.definitions),
            additionalContext: context)
        let preparedSixRead = try await container.prepare(input: UserInput(
            chat: MLXEngine.chatMessages(for: sixReadCompaction.messages),
            tools: MLXEngine.toolSpecs(for: FolderTool.definitions),
            additionalContext: context))
        let preparedSixReadCount = preparedSixRead.text.tokens.asArray(Int.self).count
        log("""
            COMPACTION6 counted=\(sixReadCompaction.fit.tokens) \
            budget=\(sixReadCompaction.fit.budget) fits=\(sixReadCompaction.fit.fits ? 1 : 0) \
            demoted=\(sixReadCompaction.fit.demotedReads) \
            prepared=\(preparedSixReadCount) \
            total_budget=\(SophiaDefaults.InputBudget.total)
            """)

        XCTAssertFalse(sixReadCompaction.fit.tokensAreEstimated)
        XCTAssertEqual(sixReadCompaction.fit.demotedReads, 5)
        XCTAssertEqual(
            sixReadCompaction.fit.tokens, preparedSixReadCount,
            "縮約判定と最終 prepare が、同じ完全プロンプトを数えていない")
        XCTAssertEqual(
            sixReadCompaction.fit.fits,
            preparedSixReadCount <= SophiaDefaults.InputBudget.total,
            "fit 判定が最終 prepare の実トークン数と食い違っている")

        // thinking の切り替えもテンプレート入力である。出荷経路から全体計数へ
        // `additionalContext` を渡し忘れると、OFF の試験だけ通って ON がずれる。
        let thinkingContext: [String: any Sendable] = ["enable_thinking": true]
        let thinkingCompaction = MLXEngine.compacted(
            sixReadTranscript,
            budget: SophiaDefaults.InputBudget.total,
            tokenizer: tokenizer,
            tools: MLXEngine.toolSpecs(for: FolderTool.definitions),
            additionalContext: thinkingContext)
        let preparedThinking = try await container.prepare(input: UserInput(
            chat: MLXEngine.chatMessages(for: thinkingCompaction.messages),
            tools: MLXEngine.toolSpecs(for: FolderTool.definitions),
            additionalContext: thinkingContext))
        let preparedThinkingCount = preparedThinking.text.tokens.asArray(Int.self).count
        log("""
            COMPACTION6_THINKING counted=\(thinkingCompaction.fit.tokens) \
            prepared=\(preparedThinkingCount) fits=\(thinkingCompaction.fit.fits ? 1 : 0)
            """)
        XCTAssertEqual(
            thinkingCompaction.fit.tokens, preparedThinkingCount,
            "thinking ON の縮約判定と最終 prepare が同じ完全プロンプトを数えていない")
        XCTAssertEqual(
            thinkingCompaction.fit.fits,
            preparedThinkingCount <= SophiaDefaults.InputBudget.total)

        // **画面に出している数字が、実測と一致していること**（16.7節 / VISION の測定原則）。
        //
        // `SophiaDefaults.toolDefinitionTokens` は UI が「毎ターンいくら払っているか」を
        // 出すために持っている定数である（`FolderBar` / `StatsLine` / 入力欄の予算行）。
        // **定数と実測がずれたら、利用者に見せている痛みのほうが嘘になる。**
        // ここが落ちたら、直すのは定数のほうであって、この表明ではない。
        XCTAssertEqual(
            delta, SophiaDefaults.toolDefinitionTokens,
            "**画面に出している「ツール定義 \(SophiaDefaults.toolDefinitionTokens) トークン」が実測と違う。**"
            + " 実測は \(delta)。`SophiaDefaults.toolDefinitionTokens` を実測値へ直すこと")
    }

    // MARK: - 補助

    private func chunk(for segment: ThinkingSegment) -> Chunk {
        switch segment {
        case .thinking(let text): .thinking(text)
        case .content(let text): .content(text)
        }
    }

    /// `[TOOLTOKENS]` 行として stderr へ。**目視の前に機械で集計できる形にする。**
    private func log(_ line: String) {
        FileHandle.standardError.write(Data("[TOOLTOKENS] \(line)\n".utf8))
    }
}
