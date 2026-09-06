import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
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

    /// **自己認識と無関係な問い。** 合格率だけを見ないための軸である（14.13b）。
    ///
    /// **前回の LoRA 実測では、様式と一緒に「短さ」が乗った**（283字 → 74〜90字）。
    /// 今回は**中身の崩れ**が疑わしいので、**長さと、名乗りの写り込み**を見る。
    /// **無関係な問いに「Sophia です」と枕を置き始めたら、それは汚染である。**
    private static let unrelatedPrompts = [
        "味噌汁の具は何がいいですか。",
        "雨の日に靴が濡れないようにするには。",
        "3と7の最小公倍数は。",
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

        // **アダプタを載せる前に、素の側の無関係な問いを測る。**
        let bareOffTopic = try await measureOffTopic(container: container, label: "bare")

        // --- 条件3: アダプタ有り・プロンプト無し -----------------------------
        //
        // **⚠ 条件1・2を回し終えてから載せる。** 先に載せると、
        // **アダプタが器全体に効いてしまい、陰性対照が陰性でなくなる。**
        // 2026-09-06、実際にそれをやって「陰性対照 9/9・name_comes_from=weights」
        // という嘘の結果を出した。**測っていたのは名乗りではなく、自分の順序の誤りだった。**
        //
        // **器は1本のまま着せ替える。2本目を読まない。**
        // この機械はスワップが常に埋まっており、4.6GB の器を2本読むと
        // **測っているのが名乗りではなくスワップになる**（実装役の指摘 / 2026-09-06）。
        //
        // **着せた直後に `adapted_modules` を数える。** 0本のまま回すと、
        // **素のモデルの答えを「アダプタ有り」として記録する** ──
        // それは天井との比較を丸ごと無意味にする。
        var adapterConditions: [(String, Bool)] = []
        var loadedAdapter: LoRAContainer?
        if let path = ProcessInfo.processInfo.environment["SOPHIA_IDENTITY_ADAPTER"],
            !path.isEmpty
        {
            let adapter = try LoRAContainer.from(directory: URL(fileURLWithPath: path))
            let adapted = try await container.perform { context -> Int in
                try context.model.load(adapter: adapter)
                return context.model.namedModules().filter { $0.1 is LoRALayer }.count
            }
            log("ADAPTER path=\(path) adapted_modules=\(adapted)")
            XCTAssertGreaterThan(
                adapted, 0,
                "**アダプタが1層も当たっていない。** 素のモデルの答えを"
                    + "「アダプタ有り」として記録するところだった")
            loadedAdapter = adapter
            adapterConditions = [("adapter_no_system", false)]
        } else {
            log("ADAPTER none（SOPHIA_IDENTITY_ADAPTER 未指定。条件3は測らない）")
        }

        if let adapter = loadedAdapter {
            for (label, withSystem) in adapterConditions {
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
            let adapterOffTopic = try await measureOffTopic(
                container: container, label: "adapter")
            log(
                "OFFTOPIC_DELTA bare_avg=\(bareOffTopic.avg) adapter_avg=\(adapterOffTopic.avg) "
                    + "bare_leak=\(bareOffTopic.leak) adapter_leak=\(adapterOffTopic.leak)")
            // **無関係な問いに名乗りが写り込んだら汚染である。**
            XCTAssertEqual(
                adapterOffTopic.leak, 0,
                "**無関係な問いに名乗りが写り込んでいる。** 自己認識以外の場所まで焼けている")
            _ = adapter
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
        if let adapter = loadedAdapter {
            let withAdapter = tally["adapter_no_system"] ?? (0, 0, 0)
            log(
                "VERDICT adapter sophia=\(withAdapter.sophia)/\(withAdapter.total) "
                    + "ceiling=\(positive.sophia)/\(positive.total) "
                    + "floor=\(negative.sophia)/\(negative.total)")
            // **剥がす。** 剥がさないと、同じプロセスで続く測定が全部汚れる。
            try await container.perform { context in
                context.model.unload(adapter: adapter)
            }
        }

        XCTAssertEqual(
            negative.sophia, 0,
            "**プロンプト無しでソフィアと名乗った。** 名前が既に重みの中に在ることになり、"
                + "`docs/ADAPTER_01.md` の前提が崩れる。**崩れたこと自体が発見である**")

        log("VERDICT name_comes_from=\(negative.sophia == 0 ? "prompt" : "weights")")
        log("END")
    }


    /// 無関係な問いで、長さと名乗りの写り込みを測る。**同じ走行の中で両方取ること。**
    ///
    /// **片方だけ取ると比較の相手が無い。** 2026-09-06、アダプタ側だけ測って
    /// 「213字で崩れていない」と書きかけた ── **素の側の長さを知らないのに。**
    @discardableResult
    private func measureOffTopic(
        container: ModelContainer, label: String
    ) async throws -> (avg: Int, leak: Int) {
        var lengths: [Int] = []
        var leaked = 0
        for prompt in Self.unrelatedPrompts {
            let text = try await answer(
                container: container, prompt: prompt, withSystem: false, seed: 4000)
            lengths.append(text.count)
            if text.contains("Sophia") || text.contains("ソフィア") { leaked += 1 }
            log(
                "OFFTOPIC cond=\(label) prompt=\(prompt) chars=\(text.count) "
                    + "text=\(text.replacingOccurrences(of: "\n", with: " ").prefix(100))")
        }
        let avg = lengths.isEmpty ? 0 : lengths.reduce(0, +) / lengths.count
        log("OFFTOPIC_SUM cond=\(label) avg_chars=\(avg) name_leak=\(leaked)/\(lengths.count)")
        return (avg, leaked)
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
