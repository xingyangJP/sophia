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
//  自己認識は、どこから来ているのか（`docs/ADAPTER_01.md` 手順4）
//
//  **利用者の問い（2026-09-06）: 「ソフィアってすでに名乗るよ？？」**
//
//  名乗る。**ただし名乗らせているのは毎ターン送っている system プロンプトである。**
//  それを口で言っても仕方がないので、**外して訊く。**
//
//  | 条件 | プロンプト | アダプタ | 期待 |
//  |---|---|---|---|
//  | **陰性対照（R4）** | 無し | 無し | **「Qwen」と名乗るはず** |
//  | **陽性対照（R5）** | **有り**（出荷状態） | 無し | **天井** |
//  | 本番（未実装） | 無し | **有り** | 天井にどこまで届くか |
//
//  > **ここで既にソフィアと名乗るなら、測っているものが違う** ──
//  > 名前が重みの中に既に在ることになり、第一号のアダプタの前提が崩れる。
//  > **崩れたなら、それはそれで重要な発見である。**
// =============================================================================

final class IdentityProbeTests: XCTestCase {

    /// **`SOPHIA_IDENTITYPROBE=1` が無ければ走らない。** 4.6GB を読んで実推論する。
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SOPHIA_IDENTITYPROBE"] == "1",
            "自己認識の実測プローブです。`SOPHIA_IDENTITYPROBE=1` のときだけ走ります")
    }

    private var attempts: Int {
        Int(ProcessInfo.processInfo.environment["SOPHIA_IDENTITYPROBE_N"] ?? "") ?? 3
    }

    /// **言い換えを複数置く。** 1つの訊き方だけだと、
    /// 「その文にどう答えるか」を測って「名乗るか」を測ったことにしてしまう。
    private static let prompts = [
        "あなたは誰ですか。",
        "名前を教えてください。",
        "あなたは何というモデルですか。",
    ]

    private func log(_ line: String) {
        FileHandle.standardError.write(Data("[IDENTITY] \(line)\n".utf8))
    }

    func testWhereTheNameActuallyComesFrom() async throws {
        let modelID = SophiaDefaults.modelID
        log("BEGIN model=\(modelID) attempts=\(attempts)")

        let configuration = MLXModelCatalog.configuration(for: modelID)
        let container = try await loadModelContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration)
        log("LOADED model=\(modelID)")

        // (ラベル, system を付けるか)
        let conditions: [(String, Bool)] = [
            ("negative_no_system", false),  // 陰性対照
            ("positive_shipped", true),  // 陽性対照 ＝ いまの出荷状態
        ]

        var tally: [String: (sophia: Int, qwen: Int, total: Int)] = [:]

        for (label, withSystem) in conditions {
            for prompt in Self.prompts {
                for attempt in 0..<attempts {
                    let text = try await answer(
                        container: container, prompt: prompt,
                        withSystem: withSystem, seed: UInt64(2000 + attempt))

                    let saysSophia =
                        text.contains("ソフィア") || text.lowercased().contains("sophia")
                    let saysQwen =
                        text.contains("Qwen") || text.lowercased().contains("qwen")
                    var t = tally[label] ?? (0, 0, 0)
                    t.sophia += saysSophia ? 1 : 0
                    t.qwen += saysQwen ? 1 : 0
                    t.total += 1
                    tally[label] = t

                    log(
                        "TRY cond=\(label) prompt=\(prompt) sophia=\(saysSophia) "
                            + "qwen=\(saysQwen) chars=\(text.count) "
                            + "text=\(text.replacingOccurrences(of: "\n", with: " ").prefix(120))")
                }
            }
        }

        for (label, t) in tally.sorted(by: { $0.key < $1.key }) {
            log("SUM cond=\(label) sophia=\(t.sophia)/\(t.total) qwen=\(t.qwen)/\(t.total)")
        }

        // **表明は「落ちないこと」ではなく「値が期待どおりか」に置く**（R6）。
        let negative = tally["negative_no_system"] ?? (0, 0, 0)
        let positive = tally["positive_shipped"] ?? (0, 0, 0)

        XCTAssertEqual(
            positive.sophia, positive.total,
            "**出荷状態で名乗れていない。** 天井が無いので、以降の比較に意味が無くなる")
        XCTAssertEqual(
            negative.sophia, 0,
            "**プロンプト無しでソフィアと名乗った。** 名前が既に重みの中に在ることになり、"
                + "`docs/ADAPTER_01.md` の前提が崩れる。**崩れたこと自体が発見である**")

        log("VERDICT name_comes_from=\(negative.sophia == 0 ? "prompt" : "weights")")
        log("END")
    }

    private func answer(
        container: ModelContainer, prompt: String, withSystem: Bool, seed: UInt64
    ) async throws -> String {
        return try await container.perform { context -> String in
            // **出荷と同じ文を使う。** 写さない（R1）。
            let chat: [Chat.Message] =
                withSystem
                ? [.system(SophiaDefaults.systemPrompt), .user(prompt)]
                : [.user(prompt)]

            let userInput = UserInput(
                chat: chat, tools: nil, additionalContext: ["enable_thinking": false])
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(maxTokens: 160, temperature: 0.7, seed: seed)

            var text = ""
            let stream = try MLXLMCommon.generate(
                input: lmInput, parameters: parameters, context: context)
            for await item in stream {
                if let chunk = item.chunk { text += chunk }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
