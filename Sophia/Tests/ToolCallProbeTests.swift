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
    /// **思考モードで測るか。** 既定は OFF（プローブはずっとこれで測ってきた）。
    ///
    /// > **2026-08-18、実機で呼ばれない事象が出て足した。**
    /// > アプリは既定で思考ONだが、**プローブはずっとOFFで測っていた。**
    /// > つまり「12/12 だから使える」は**思考OFFの条件でしか確かめていない。**
    /// > DESIGN 16.9節 項目3 が未確認として立てていたのはこれである。
    /// > `SOPHIA_TOOLPROBE_THINK=1` で ON。
    static var thinkingEnabled: Bool {
        ProcessInfo.processInfo.environment["SOPHIA_TOOLPROBE_THINK"] == "1"
    }

    private var temperature: Double {
        Double(ProcessInfo.processInfo.environment["SOPHIA_TOOLPROBE_TEMP"] ?? "") ?? 0.7
    }

    // MARK: - ツール定義（DESIGN 16.4節の3つ）

    /// **出荷する定義そのものを測る。** ここに定義を書き写さないこと。
    ///
    /// > **2026-08-18 に差し替えた。記録を残す。**
    /// > 以前はこの関数が**自前の定義を持っていた**（「ディレクトリのパス」等）。
    /// > その状態で 12/12 という結果を出し、**それを「実装の成功率」として設計書に書いた。**
    /// > **測っていたのは出荷される経路ではない。**
    /// > 同じ罠が `EngineToolWiringTests` の費用計測にもあり、
    /// > **716トークンという嘘の実費**を生んだ（実費は 1,182）。
    /// >
    /// > **定義を写した瞬間、このプローブは「プローブ自身」を測る道具になる。**
    private static func toolSpecs() -> [ToolSpec] {
        FolderTool.definitions.map(MLXEngine.toolSpec(for:))
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

    /// **実機と同じ会話を組む。**
    ///
    /// > **2026-08-18、実機で初めて動かして分かった。記録を残す。**
    /// > **プローブは system メッセージを1つも送っていなかった** ── `[.user(prompt)]` だけ。
    /// > 実機は自己認識（FR-23）と「どのフォルダが結び付いているか」を必ず送る。
    /// > **つまり測っていたのは、出荷される会話の形ではなかった。**
    /// > 本日3件目の「器が対象を測っていない」である
    /// > （1件目はプローブが仮の定義を測っていた件、2件目は費用計測の同種）。
    ///
    /// `SOPHIA_TOOLPROBE_SYSTEM=0` で外せる（外した状態が従来の測り方）。
    static func chat(for prompt: String) -> [Chat.Message] {
        guard ProcessInfo.processInfo.environment["SOPHIA_TOOLPROBE_SYSTEM"] != "0" else {
            return [.user(prompt)]
        }
        // 知らせる1行は `ConversationFolder.boundFolderNotice` と同じ形にする。
        // **文言を写しているので、あちらを変えたらここも変わる** ── 実機と揃っていることが要点で、
        // 揃っていなければ測る意味が無い（`ProbeSystemMessageTests` が食い違いを落とす）。
        let notice = #"参照先のフォルダ「Documents」。このフォルダ自身は path="" で指します。"#
        return [.system(SophiaDefaults.systemPrompt + "\n" + notice), .user(prompt)]
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
                chat: Self.chat(for: prompt),
                tools: specs,
                additionalContext: ["enable_thinking": Self.thinkingEnabled]
            )
            let lmInput = try await context.processor.prepare(input: userInput)

            // **上限はアプリと同じ規則で決めること。**
            //
            // > **2026-08-18、ここが嘘の結果を出した。記録を残す。**
            // > 以前は `maxTokens: 256` 固定だった。**思考OFFなら足りるが、ONでは足りない** ──
            // > 実機のログでは思考だけで **429〜901トークン**使っている。
            // > 256 で打ち切られると**思考の途中で生成が終わり、
            // > ツール呼び出しに到達しない。**
            // >
            // > その状態で「思考ONだと 1/12。呼べない」という結果を出した。
            // > **測っていたのは「思考」ではなく「思考＋256の上限」だった。**
            // > 実機は同じ条件で呼べており、矛盾から気づいた。
            // > **本日4件目の「器が対象を測っていない」である。**
            //
            // `ChatOptions.applyingThinkingBudget()` と**同じ規則**を使う
            // （あちらを変えたらここも変わるよう、定数を参照して書き写さない）。
            let cap =
                Self.thinkingEnabled
                ? SophiaDefaults.thinkingMinMaxTokens
                : 256
            let parameters = GenerateParameters(
                maxTokens: cap, temperature: temp, seed: seed)

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
