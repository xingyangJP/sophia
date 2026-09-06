import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers
import Tokenizers
import XCTest

@testable import Sophia

// =============================================================================
//  第一号のアダプタを焼く（`docs/ADAPTER_01.md` 手順5）
//
//  **焼くのは「system プロンプト無しで Sophia と名乗る」である。**
//  実測で確定している（`777e991`）── プロンプト無しだと 0/9、有りだと 9/9。
//  **名前は毎ターンの約97トークンが作っていて、重みの中には無い。**
//
//  ## ⚠ system プロンプトを混ぜないこと
//
//  **ここでは `.system(...)` を1度も足さない。** 足すと学習するのは
//  「プロンプトがあるときに名乗る」であって、**それはいま既にできていることである。**
//  `StyleTrainingCorpus` を使わず自前で会話を組んでいるのは、あちらが
//  `SophiaDefaults.systemPromptEnabled` を見て system を足すからである。
//
//  ## 保存形式
//
//  **MLX native（`adapters.safetensors` + `adapter_config.json`）で書く。**
//  `LoRAContainer.from(directory:)` が読む形である。**PEFT ではない** ──
//  そちらは外から持ってきたアダプタ用（`bf66aec` で判別が入っている）。
// =============================================================================

final class IdentityTrainingTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SOPHIA_IDENTITYTRAIN"] == "1",
            "第一号のアダプタを焼きます。`SOPHIA_IDENTITYTRAIN=1` のときだけ走ります")
    }

    private var iterations: Int {
        Int(ProcessInfo.processInfo.environment["SOPHIA_IDENTITYTRAIN_ITERS"] ?? "") ?? 80
    }
    private var layers: Int {
        Int(ProcessInfo.processInfo.environment["SOPHIA_IDENTITYTRAIN_LAYERS"] ?? "") ?? 16
    }
    /// **LoRA の倍率。** ライブラリの既定は 10.0 で、**8層に対しては強い疑いがある**
    /// （2026-09-06、既定のまま20ステップ焼いたら、名乗るようにはなったが
    /// 応答が崩れた ── 「使っているモデルの名前は Claude です」等）。
    /// **弱めて焼き直せるように、外から変えられる形にしてある。**
    private var scale: Float {
        Float(ProcessInfo.processInfo.environment["SOPHIA_IDENTITYTRAIN_SCALE"] ?? "") ?? 10.0
    }

    private var outputDirectory: URL {
        let path =
            ProcessInfo.processInfo.environment["SOPHIA_ADAPTER_OUT"]
            ?? FileManager.default.temporaryDirectory
                .appending(path: "sophia-identity-adapter").path
        return URL(fileURLWithPath: path)
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data("[IDTRAIN] \(line)\n".utf8))
    }

    func testBakeTheIdentityAdapter() async throws {
        let modelID = SophiaDefaults.modelID
        log(
            "BEGIN model=\(modelID) pairs=\(IdentityCorpus.pairs.count) "
                + "iters=\(iterations) layers=\(layers) scale=\(scale)")

        let container = try await loadModelContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: MLXModelCatalog.configuration(for: modelID))
        log("LOADED model=\(modelID)")

        // --- 学習に食わせる文を作る（**system を足さない**）-------------------
        var texts: [String] = []
        var tokenCounts: [Int] = []
        for pair in IdentityCorpus.pairs {
            let prepared = try await container.prepare(input: Self.input(pair: pair))
            let ids = prepared.text.tokens.asArray(Int.self)
            tokenCounts.append(ids.count)
            texts.append(try await container.perform { $0.tokenizer.decode(tokenIds: ids) })
        }
        log(
            "CORPUS n=\(texts.count) tok_min=\(tokenCounts.min() ?? 0) "
                + "tok_med=\(tokenCounts.sorted()[tokenCounts.count / 2]) "
                + "tok_max=\(tokenCounts.max() ?? 0)")

        // **学習に使う文へ、名乗りが本当に入っているか。**
        // 入っていなければ、何を焼いても名乗るようにはならない（R6: 値で表明する）。
        let withName = texts.filter { $0.contains("Sophia") }.count
        log("CORPUS_SANITY sophia_in_text=\(withName)/\(texts.count)")
        XCTAssertEqual(
            withName, texts.count,
            "**学習データの文に名乗りが入っていない。** 会話テンプレートの適用で落ちた可能性がある")

        // 検証用に2件だけ取り分ける（ライブラリが 0 イテレーション目に必ず1回使う）。
        let validate = Array(texts.suffix(2))
        let train = Array(texts.dropLast(2))

        let outDirectory = outputDirectory
        let iters = iterations
        let layerCount = layers
        let loraScale = scale

        let report = try await container.perform { context -> String in
            let model = context.model
            let tokenizer = context.tokenizer

            let configuration = LoRAConfiguration(
                numLayers: layerCount,
                fineTuneType: .lora,
                loraParameters: .init(rank: 8, scale: loraScale))
            _ = try LoRAContainer.from(model: model, configuration: configuration)

            // **差し替えが起きたことを数で確かめてから学習する（R8）。**
            // `LoRAContainer.from` は対象が0でも例外を投げない ──
            // その状態でも学習は最後まで通り、**「軽くて速い」という嘘が出る。**
            let adapted = model.namedModules().filter { $0.1 is LoRALayer }.count
            let trainables = model.trainableParameters().flattened()
            guard adapted > 0, !trainables.isEmpty else {
                throw NSError(
                    domain: "IdentityTraining", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "差し替えが1つも起きていない（adapted_modules=\(adapted)）"
                    ])
            }

            let optimizer = Adam(learningRate: 1e-4)
            let parameters = LoRATrain.Parameters(
                batchSize: 1,
                iterations: iters,
                stepsPerReport: 10,
                stepsPerEval: iters + 1_000_000,
                validationBatches: 1,
                saveEvery: iters + 1_000_000,
                adapterURL: nil)

            var losses: [Float] = []
            try LoRATrain.train(
                model: model, train: train, validate: validate,
                optimizer: optimizer, tokenizer: tokenizer, parameters: parameters
            ) { progress in
                if case .train(let iteration, let loss, _, _) = progress {
                    losses.append(loss)
                    FileHandle.standardError.write(
                        Data("[IDTRAIN] ITER \(iteration + 1)/\(iters) loss=\(loss)\n".utf8))
                }
                return .more
            }

            // --- 保存（native 形式）------------------------------------------
            try FileManager.default.createDirectory(
                at: outDirectory, withIntermediateDirectories: true)
            try LoRATrain.saveLoRAWeights(
                model: model, url: outDirectory.appending(component: "adapters.safetensors"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(configuration).write(
                to: outDirectory.appending(component: "adapter_config.json"))

            let first = losses.first.map { String(format: "%.4f", $0) } ?? "-"
            let last = losses.last.map { String(format: "%.4f", $0) } ?? "-"
            return "adapted_modules=\(adapted) trainable_tensors=\(trainables.count) "
                + "loss_first=\(first) loss_last=\(last)"
        }

        log("TRAINED \(report)")
        log("SAVED dir=\(outDirectory.path)")

        // **書けたことを、書けたと言う前に確かめる。**
        for name in ["adapters.safetensors", "adapter_config.json"] {
            let url = outDirectory.appending(component: name)
            let size =
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            log("ARTIFACT name=\(name) bytes=\(size ?? 0)")
            XCTAssertGreaterThan(size ?? 0, 0, "\(name) が空、または書けていない")
        }
        log("END")
    }

    /// **`UserInput` は関数から返す**（`StyleTrainingCorpus` に同じ記録がある）。
    /// 呼び出し地点で組むと `sending value of non-Sendable type` で落ちる。
    ///
    /// **`.system` を足さない。** ここが本作業の要点である。
    private static func input(pair: IdentityCorpus.Pair) -> UserInput {
        UserInput(
            chat: [.user(pair.question), .assistant(pair.answer)],
            additionalContext: ["enable_thinking": false] as [String: any Sendable])
    }
}
