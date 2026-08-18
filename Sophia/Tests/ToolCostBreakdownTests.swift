import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
import XCTest

@testable import Sophia

/// **716トークンの内訳を測る**（DESIGN.md 16.9節 項目4 の但し書き）。
///
/// 費用の総額は測れたが、**どこに掛かっているかは測っていなかった。**
/// 内訳が分からないと打ち手が選べない ──
///
/// | 内訳がここなら | 効く手 |
/// |---|---|
/// | テンプレートの固定文 | **こちらには何もできない**（定義を減らす以外） |
/// | JSON の構造（鍵・括弧・引用符） | 引数を減らす |
/// | 説明文（日本語） | 短くする・英語にする |
///
/// **推測で英語化して外すと、呼び出し成功率の測り直しだけが残る。**
final class ToolCostBreakdownTests: XCTestCase {

    private static let gate = "SOPHIA_TOOLTOKENS"

    func testWhereTheToolDefinitionTokensActuallyGo() async throws {
        guard ProcessInfo.processInfo.environment[Self.gate] == "1" else {
            throw XCTSkip("\(Self.gate)=1 のときだけ走る（実トークナイザを読む）")
        }

        let container = try await loadModelContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: MLXModelCatalog.configuration(for: SophiaDefaults.modelID))
        let count: @Sendable (String) async -> Int = { text in
            await container.perform { context in
                context.tokenizer.encode(text: text).count
            }
        }

        // 実際に注入される JSON そのもの（`tool | tojson` に相当）。
        let specs = FolderTool.jsonSchemas
        var perTool: [(String, Int, Int, Int)] = []   // 名前 / 全体 / 説明文だけ / 構造
        for spec in specs {
            let json = String(
                data: try JSONSerialization.data(
                    withJSONObject: spec, options: [.sortedKeys, .withoutEscapingSlashes]),
                encoding: .utf8)!
            let whole = await count(json)

            // 説明文だけを抜き出して足す（`description` の値すべて）。
            let descriptions = Self.descriptions(in: spec)
            var descTokens = 0
            for d in descriptions { descTokens += await count(d) }

            let name = ((spec["function"] as? [String: Any])?["name"] as? String) ?? "?"
            perTool.append((name, whole, descTokens, whole - descTokens))
            print("[BREAKDOWN] TOOL name=\(name) whole=\(whole) descriptions=\(descTokens) structure=\(whole - descTokens)")
            print("[BREAKDOWN] JSON \(name) = \(json)")
        }

        // テンプレートの固定文（Qwen3 の chat template から実物を写したもの）。
        let preamble = """
            # Tools

            You may call one or more functions to assist with the user query.

            You are provided with function signatures within <tools></tools> XML tags:
            <tools>
            """
        let epilogue = """

            </tools>

            For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
            <tool_call>
            {"name": <function-name>, "arguments": <args-json-object>}
            </tool_call>
            """
        let preambleTokens = await count(preamble)
        let epilogueTokens = await count(epilogue)
        let fixed = preambleTokens + epilogueTokens

        let toolsTotal = perTool.reduce(0) { $0 + $1.1 }
        let descTotal = perTool.reduce(0) { $0 + $1.2 }
        let structureTotal = toolsTotal - descTotal

        print("""
            [BREAKDOWN] SUM fixed_template=\(fixed) json_structure=\(structureTotal) \
            descriptions=\(descTotal) tools_json_total=\(toolsTotal) \
            grand_total=\(fixed + toolsTotal)
            """)

        // **ここまでは再構成である。合計が実測と合わない場合、再構成が間違っている。**
        // だから**実際に描画された文そのもの**を出す。推測で差を埋めない。
        func chat() -> [Chat.Message] {
            [.system(SophiaDefaults.systemPrompt), .user("こんにちは")]
        }
        let extra: [String: any Sendable] = ["enable_thinking": false]
        let armed = try await container.prepare(
            input: UserInput(
                chat: chat(), tools: specs.map { $0 as [String: any Sendable] },
                additionalContext: extra))
        let armedTokens = armed.text.tokens.asArray(Int.self)
        let rendered = await container.perform { context in
            context.tokenizer.decode(tokenIds: armedTokens)
        }
        print("[BREAKDOWN] RENDERED_TOKENS=\(armedTokens.count)")
        print("[BREAKDOWN] RENDERED_BEGIN")
        print(rendered)
        print("[BREAKDOWN] RENDERED_END")

        // **英語で書いたらいくらになるか。**
        //
        // 上の RENDERED を見れば分かるとおり、テンプレートの `tojson` は
        // **非ASCIIを \uXXXX へ展開する。日本語1文字が ASCII 6文字になる。**
        // 「日本語は 0.74 tok/字」という話ではなく、**日本語であること自体が課金対象**である。
        //
        // **出荷する定義はまだ変えていない。** 変えるとモデルの挙動が変わり、
        // 呼び出し成功率の測り直しになる（16.4節）。ここで測るのは差額だけである。
        let english = Self.englishSchemas
        let armedEnglish = try await container.prepare(
            input: UserInput(
                chat: chat(), tools: english.map { $0 as [String: any Sendable] },
                additionalContext: extra))
        let englishCount = armedEnglish.text.tokens.asArray(Int.self).count
        print("[BREAKDOWN] LANGUAGE japanese=\(armedTokens.count) english=\(englishCount) saved=\(armedTokens.count - englishCount)")

        XCTAssertGreaterThan(fixed, 0)
        XCTAssertGreaterThan(descTotal, 0)
    }

    /// **測るためだけの英語版。出荷する定義ではない。**
    ///
    /// 意味は `FolderTool.jsonSchemas` と同じにしてある ──
    /// 短くして得をしたのか、英語にして得をしたのかが混ざらないように。
    private static var englishSchemas: [[String: any Sendable]] {
        func property(_ type: String, _ description: String) -> [String: any Sendable] {
            ["type": type, "description": description]
        }
        func schema(
            _ name: String, _ description: String,
            _ properties: [String: any Sendable], _ required: [String]
        ) -> [String: any Sendable] {
            [
                "type": "function",
                "function": [
                    "name": name, "description": description,
                    "parameters": [
                        "type": "object", "properties": properties, "required": required,
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
            ]
        }
        return [
            schema(
                "list_directory", "List the direct children of a folder",
                [
                    "path": property(
                        "string",
                        "Path relative to the bound folder. Empty string for the folder itself. "
                            + "Absolute paths and ~ are not allowed")
                ], ["path"]),
            schema(
                "read_file",
                "Read a text file by line range. Long files are clipped; continue with offset",
                [
                    "path": property(
                        "string",
                        "Path relative to the bound folder. Absolute paths and ~ are not allowed"),
                    "offset": property("integer", "Line to start from (1-based)"),
                    "limit": property("integer", "How many lines to read (max 200)"),
                ], ["path"]),
            schema(
                "search_files", "Find files and folders whose name contains the given word",
                [
                    "path": property(
                        "string", "Where to start. Empty string for the whole bound folder"),
                    "query": property("string", "Word contained in the file name"),
                ], ["path", "query"]),
        ]
    }

    /// `description` の値を再帰で全部集める。
    private static func descriptions(in object: Any) -> [String] {
        guard let dictionary = object as? [String: Any] else { return [] }
        var found: [String] = []
        for (key, value) in dictionary {
            if key == "description", let text = value as? String {
                found.append(text)
            } else {
                found += descriptions(in: value)
            }
        }
        return found
    }
}
