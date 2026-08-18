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
//  ツール呼び出しが実際に成立するかを測る（DESIGN 第16章の関門）
// -----------------------------------------------------------------------------
//  **第16章（FR-19 フォルダ参照）はこの1点に懸かっている。**
//
//  そこまでに確認できているのは「器がある」ことだけである ──
//  実モデルの `tokenizer_config.json` に `{%- if tools %}` / `<tool_call>` /
//  `<tool_response>` が実在し、MLX 側にも `Tool` / `ToolCall` の型が揃っている。
//
//  **しかし「テンプレートが対応していること」と、
//  「4bit 量子化された 8B が、日本語の指示で正しい形式を守れること」は別である。**
//
//  2026-08-18、量子化が壊すのは細部の正確さだと実測した
//  （`eval/verdicts/2026-08-18.jsonl`）── 日本語としては完璧なまま、
//  存在しない API を捏造した。**JSON 形式の遵守は、まさにその「細部」である。**
//
//  **呼べなければ第16章は成立しない。だから実装の前に測る。**
//
//  ## 本番と経路が違う点（重要）
//
//  `MLXEngine.swift:648` の `UserInput(chat:additionalContext:)` は **tools を渡していない。**
//  本プローブは `MLXLMCommon` を直接叩いて `UserInput(chat:tools:additionalContext:)` を組む。
//  **したがって「プローブで呼べた」は「本番で呼べる」を意味しない** ──
//  本番で使うには `MLXEngine` 側に tools を渡す口を足す必要がある（未実装）。
//  ここで測っているのは**モデルの能力**であって、アプリの結線ではない。
// =============================================================================

final class ToolCallProbeTests: XCTestCase {

    /// **`SOPHIA_TOOLPROBE=1` が無ければ走らない。**
    /// 4.6GB を読み込んで実推論するので、通常の `make app-test`（全93件・1秒未満）に
    /// 混ざると開発が止まる。`PrefillProbeTests` と同じ作法。
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SOPHIA_TOOLPROBE"] == "1",
            "ツール呼び出しの実測プローブです。`SOPHIA_TOOLPROBE=1` のときだけ走ります"
        )
    }

    // MARK: - 測る条件

    /// 1条件あたりの試行回数。
    ///
    /// **n=1 で判定しないこと。** 2026-08-18、n=1 の相関で2回結論を書いて
    /// 2回とも撤回した（「アイドル時間の関数」「compressor 占有量」）。
    /// **分散のある系で1点から機構を語ってはいけない。**
    private var attempts: Int {
        Int(ProcessInfo.processInfo.environment["SOPHIA_TOOLPROBE_N"] ?? "") ?? 3
    }

    /// 温度。**実使用と同じ 0.7 を既定にする。**
    /// 0 に固定すれば再現性は上がるが、**実使用とは別の性質を測ることになる。**
    /// 形式の遵守は「揺らいでも守れるか」が問題なので、実使用側に寄せた。
    private var temperature: Double {
        Double(ProcessInfo.processInfo.environment["SOPHIA_TOOLPROBE_TEMP"] ?? "") ?? 0.7
    }

    // MARK: - ツール定義（DESIGN 16.4節の3つ）

    /// JSON Schema 形式のツール定義。`ToolSpec = [String: any Sendable]`。
    private static func toolSpecs() -> [ToolSpec] {
        [
            [
                "type": "function",
                "function": [
                    "name": "list_directory",
                    "description": "指定したディレクトリの中身を一覧する",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string", "description": "ディレクトリのパス"]
                        ],
                        "required": ["path"],
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
            ],
            [
                "type": "function",
                "function": [
                    "name": "read_file",
                    "description": "ファイルの中身を読む。長い場合は範囲を指定する",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string", "description": "ファイルのパス"],
                            "offset": ["type": "integer", "description": "開始行（1始まり）"],
                            "limit": ["type": "integer", "description": "読む行数"],
                        ] as [String: any Sendable],
                        "required": ["path"],
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
            ],
            [
                "type": "function",
                "function": [
                    "name": "search_files",
                    "description": "ディレクトリ配下から文字列を含むファイルを探す",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string", "description": "探索の起点"],
                            "query": ["type": "string", "description": "探す文字列"],
                        ] as [String: any Sendable],
                        "required": ["path", "query"],
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
            ],
        ]
    }

    /// スキーマ上の必須キー。**引数の妥当性はここで判定する**（JSON の妥当性ではない）。
    private static func requiredKeys(for tool: String) -> [String] {
        switch tool {
        case "list_directory": ["path"]
        case "read_file": ["path"]
        case "search_files": ["path", "query"]
        default: []
        }
    }

    /// 条件。**⑤の「呼ばないほうが正解」を必ず混ぜること** ── 誤爆のほうが害が大きい。
    private struct Condition {
        let id: String
        let prompt: String
        /// 期待するツール名。`nil` なら「呼ばないのが正解」。
        let expected: String?
        let note: String
    }

    private static let conditions: [Condition] = [
        .init(id: "ja-list", prompt: "~/Documents の中に何があるか見せて",
              expected: "list_directory", note: "日本語・一覧"),
        .init(id: "ja-read", prompt: "~/Documents/notes.md の中身を読んで要約して",
              expected: "read_file", note: "日本語・読み取り"),
        .init(id: "ja-search", prompt: "~/Documents から「請求書」という語を含むファイルを探して",
              expected: "search_files", note: "日本語・検索"),
        .init(id: "en-list", prompt: "List what's in ~/Documents",
              expected: "list_directory", note: "英語・対照（日本語で落ちるなら言語の問題と分かる）"),
        .init(id: "no-tool-chat", prompt: "量子化とは何か、3行で説明して",
              expected: nil, note: "**呼ばないのが正解。** 誤爆の検出"),
        .init(id: "no-tool-greet", prompt: "こんにちは",
              expected: nil, note: "**呼ばないのが正解。** 誤爆の検出"),
    ]

    // MARK: - 本体

    func testToolCallingAcrossConditions() async throws {
        let modelID = SophiaDefaults.modelID
        log("BEGIN model=\(modelID) attempts=\(attempts) temp=\(temperature) conditions=\(Self.conditions.count)")

        let configuration = MLXModelCatalog.configuration(for: modelID)
        let container = try await loadModelContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration
        )
        log("LOADED model=\(modelID)")

        var tally: [String: (called: Int, correct: Int, validJSON: Int, total: Int)] = [:]

        for condition in Self.conditions {
            for attempt in 0..<attempts {
                let seed = UInt64(1000 + attempt)
                let outcome = try await run(
                    container: container, prompt: condition.prompt, seed: seed)

                let called = outcome.toolName != nil
                let correct = outcome.toolName == condition.expected
                var t = tally[condition.id] ?? (0, 0, 0, 0)
                t.total += 1
                if called { t.called += 1 }
                if correct { t.correct += 1 }
                if outcome.argumentsAreValidJSON { t.validJSON += 1 }
                tally[condition.id] = t

                log("""
                    TRY id=\(condition.id) attempt=\(attempt + 1)/\(attempts) seed=\(seed) \
                    expected=\(condition.expected ?? "-") got=\(outcome.toolName ?? "-") \
                    correct=\(correct) schema_ok=\(outcome.argumentsAreValidJSON) \
                    args=\(outcome.argumentsSummary) text_chars=\(outcome.textCharacters)
                    """)
            }
        }

        // --- 集計（目視の前に機械で読めること）---------------------------------
        for condition in Self.conditions {
            let t = tally[condition.id] ?? (0, 0, 0, 0)
            log("""
                SUM id=\(condition.id) expected=\(condition.expected ?? "-") \
                called=\(t.called)/\(t.total) correct=\(t.correct)/\(t.total) \
                schema_ok=\(t.validJSON)/\(t.total) note=\(condition.note)
                """)
        }

        let needsTool = Self.conditions.filter { $0.expected != nil }
        let avoidsTool = Self.conditions.filter { $0.expected == nil }
        let correctTotal = needsTool.reduce(0) { $0 + (tally[$1.id]?.correct ?? 0) }
        let needsTotal = needsTool.reduce(0) { $0 + (tally[$1.id]?.total ?? 0) }
        let falseFires = avoidsTool.reduce(0) { $0 + (tally[$1.id]?.called ?? 0) }
        let avoidTotal = avoidsTool.reduce(0) { $0 + (tally[$1.id]?.total ?? 0) }

        log("""
            VERDICT correct=\(correctTotal)/\(needsTotal) false_fire=\(falseFires)/\(avoidTotal) \
            judgment=\(judgment(correct: correctTotal, of: needsTotal, falseFires: falseFires))
            """)

        await container.perform { _ in }  // 明示的に触れて解放順を安定させる
        log("END")

        // **ここでは失敗させない。** 測定であって合否判定ではない ──
        // 「呼べない」も価値のある結果であり、テストの赤は判断を急がせる。
        // 判定は `VERDICT` 行を人が読んで行う。
    }

    private func judgment(correct: Int, of total: Int, falseFires: Int) -> String {
        guard total > 0 else { return "判定不能" }
        let rate = Double(correct) / Double(total)
        if falseFires > 0 { return "誤爆あり（第16章は注入条件の見直しが要る）" }
        if rate >= 0.9 { return "使える" }
        if rate >= 0.5 { return "不安定（第16章は成立しない可能性）" }
        return "呼べない（第16章は設計変更が要る）"
    }

    // MARK: - 1回の試行

    /// **`Sendable` にしておくこと。** `container.perform` のクロージャは `@Sendable` で、
    /// 戻り値として actor 境界を越える。
    private struct Outcome: Sendable {
        var toolName: String?
        var argumentsAreValidJSON: Bool
        var argumentsSummary: String
        var textCharacters: Int
    }

    private func run(
        container: ModelContainer, prompt: String, seed: UInt64
    ) async throws -> Outcome {
        // **クロージャの外で値にしておく。**
        // `temperature` は `self` の計算プロパティなので、
        // そのまま参照すると `@Sendable` クロージャが `self`（非 Sendable な XCTestCase）を
        // 捕まえてしまう。同じ理由で `outcome` も captured var にはできないので、
        // **クロージャの戻り値として受け取る。**
        let temp = Float(temperature)
        let specs = Self.toolSpecs()

        return try await container.perform { context -> Outcome in
            var outcome = Outcome(
                toolName: nil, argumentsAreValidJSON: false,
                argumentsSummary: "-", textCharacters: 0)

            // 思考は切る。**測っているのは形式の遵守であって推論の質ではない。**
            // 思考ONだと1往復が数十秒になり、条件×試行回数で現実的な時間に収まらない。
            let userInput = UserInput(
                chat: [.user(prompt)],
                tools: specs,
                additionalContext: ["enable_thinking": false]
            )
            let lmInput = try await context.processor.prepare(input: userInput)

            let parameters = GenerateParameters(
                maxTokens: 256, temperature: temp, seed: seed)

            let stream = try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context)

            for await item in stream {
                switch item {
                case .chunk(let text):
                    outcome.textCharacters += text.count
                case .toolCall(let call):
                    outcome.toolName = call.function.name

                    // **`JSONSerialization.isValidJSONObject` を使ってはいけない。**
                    // `arguments` の型は `[String: JSONValue]` ─ **ライブラリが既に
                    // パースし終えた型付きの値**であって、Foundation の辞書ではない。
                    // あれに掛けると必ず false が返り、**「引数が全部不正」という
                    // 嘘の結論が出る**（2026-08-18 に実際に出した）。
                    //
                    // **そして意味は逆である。** `ToolCall` が出てきた時点で
                    // JSON のパースは成功している。だからここで見るべきは
                    // 「JSONとして妥当か」ではなく、**「スキーマに合っているか」**。
                    let args = call.function.arguments
                    let required = Self.requiredKeys(for: call.function.name)
                    let missing = required.filter { args[$0] == nil }
                    outcome.argumentsAreValidJSON = missing.isEmpty && !args.isEmpty
                    if let data = try? JSONEncoder().encode(args),
                       let text = String(data: data, encoding: .utf8) {
                        outcome.argumentsSummary = String(text.prefix(140))
                    } else {
                        outcome.argumentsSummary = "符号化できない"
                    }
                    if !missing.isEmpty {
                        outcome.argumentsSummary += " 欠落=\(missing.joined(separator: ","))"
                    }
                default:
                    break
                }
            }
            return outcome
        }
    }

    // MARK: - ログ

    /// `[TOOLPROBE]` 行として stderr へ。**目視の前に機械で集計できる形にする。**
    private func log(_ line: String) {
        FileHandle.standardError.write(Data("[TOOLPROBE] \(line)\n".utf8))
    }
}
