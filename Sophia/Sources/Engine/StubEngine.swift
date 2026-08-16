import Foundation

/// A1 開発用のダミーエンジン。**モデルを一切読まない。**
///
/// 存在理由は3つ。
///
/// 1. **UI 担当が MLX 実装の完成を待たずに作業できる。** ストリーミング・思考分離・
///    中断・計測のすべてが本物と同じ経路で動く
/// 2. **`InferenceEngine` が実装可能な形になっていることの証明。** 契約だけ書いて
///    実装できないことが後から分かる事故を防ぐ
/// 3. **推論を走らせずに UI を検証できる。** 16GB機で別プロセスと推論が競合すると
///    スワップで両方壊れる。UI の作り込み中は本物を動かす必要がない
///
/// **MLX 実装はこのファイルを書き換えず、別ファイルに作ること。**
/// 両方を残しておくと、不具合が UI 側か推論側かを切り分けられる。
actor StubEngine: InferenceEngine {

    nonisolated let identifier: EngineIdentifier = .stub

    /// 1断片あたりの文字数と間隔。既定は BENCH_RESULTS.md の実測
    /// （生成13 tok/s、日本語 約0.5トークン/文字 ≒ 26文字/秒）に合わせてある。
    /// 速すぎるダミーで作った UI は、本物に差し替えた瞬間に破綻する。
    private let charactersPerChunk: Int
    private let chunkInterval: Duration

    private var current: ModelInfo?

    init(charactersPerChunk: Int = 2, chunkInterval: Duration = .milliseconds(77)) {
        self.charactersPerChunk = charactersPerChunk
        self.chunkInterval = chunkInterval
    }

    // MARK: - InferenceEngine

    func loadedModel() -> ModelInfo? { current }

    func capabilities() -> EngineCapabilities {
        EngineCapabilities(
            supportsThinking: true,
            canDisableThinking: true,
            maxContextLength: current?.maxContextLength ?? SophiaDefaults.contextLength,
            reportsPrefillProgress: true,
            reportsExactTokenCounts: false   // 概算しか出せない。BENCH には載せないこと
        )
    }

    func availableModels() -> [ModelInfo] {
        [
            ModelInfo(
                id: SophiaDefaults.modelID,
                sizeBytes: 4_620_000_000,
                parameterSize: "8.2B",
                quantization: "4bit",
                supportsThinking: true,
                maxContextLength: 32_768,
                isDownloaded: true
            )
        ]
    }

    nonisolated func load(_ modelID: String) -> AsyncThrowingStream<LoadProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(LoadProgress(stage: .resolving, detail: "モデルを確認しています"))
                    try await Task.sleep(for: .milliseconds(120))

                    for step in 1...5 {
                        try Task.checkCancellation()
                        let fraction = Double(step) / 5
                        continuation.yield(LoadProgress(
                            stage: .loadingWeights,
                            fraction: fraction,
                            detail: "重みを展開しています（ダミー）"
                        ))
                        try await Task.sleep(for: .milliseconds(80))
                    }

                    let model = await self.model(for: modelID)
                    await self.setCurrent(model)
                    continuation.yield(LoadProgress(stage: .ready, fraction: 1, detail: "準備できました"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: SophiaError.wrap(error, fallback: .modelLoadFailed))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unload() {
        current = nil
    }

    nonisolated func chat(
        _ messages: [SophiaMessage],
        options: ChatOptions
    ) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.generate(messages, options: options, into: continuation)
            }
            // 消費側が Task をキャンセルすると、ここが発火して生成が止まる（FR-02）。
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 内部

    private func setCurrent(_ model: ModelInfo?) { current = model }

    private func model(for modelID: String) -> ModelInfo {
        availableModels().first { $0.id == modelID }
            ?? ModelInfo(id: modelID, supportsThinking: true, isDownloaded: true)
    }

    private func generate(
        _ messages: [SophiaMessage],
        options: ChatOptions,
        into continuation: AsyncThrowingStream<Chunk, any Error>.Continuation
    ) async {
        // 計測の起点。TTFT の定義を実装ごとにぶらさないため、必ずこの時計を使う。
        var clock = GenerationClock()
        // 思考モードの maxTokens 補正は「エンジン呼び出しの直前で1回だけ」。
        let options = options.applyingThinkingBudget()

        let prompt = messages.last { $0.role == .user }?.content ?? ""
        let inputTokens = messages.estimatedTokenCount

        do {
            // --- プリフィル ---------------------------------------------------
            let prefillSteps = 4
            for step in 1...prefillSteps {
                try Task.checkCancellation()
                continuation.yield(.prefill(PrefillProgress(
                    processedTokens: inputTokens * step / prefillSteps,
                    totalTokens: inputTokens
                )))
                try await Task.sleep(for: .milliseconds(60))
            }
            let prefillSeconds = clock.elapsedMs / 1000

            // --- 思考（FR-17）-------------------------------------------------
            // 実測どおり思考は本文より長い。UI の折りたたみが機能するかを試せる量にしてある。
            if options.thinking {
                let thinking = Self.thinkingText(for: prompt)
                try await emit(thinking, into: continuation, clock: &clock) { .thinking($0) }
            }

            // --- 本文 -----------------------------------------------------------
            let body = Self.replyText(for: prompt, thinking: options.thinking)
            try await emit(body, into: continuation, clock: &clock) { .content($0) }

            // --- 終端 -----------------------------------------------------------
            let outputCharacters = clock.thinkingCharacterCount + clock.contentCharacterCount
            continuation.yield(.done(clock.finish(
                inputTokens: inputTokens,
                outputTokens: Int(ceil(Double(outputCharacters) * 0.5)),
                stopReason: .completed,
                prefillSeconds: prefillSeconds,
                modelID: SophiaDefaults.modelID,
                thinkingEnabled: options.thinking
            )))
            continuation.finish()

        } catch is CancellationError {
            // FR-02。中断は失敗ではない。
            // 消費側が既に離脱していればこの yield は捨てられる。それで正しい
            // （既出力は消費側が保持している）。
            let outputCharacters = clock.thinkingCharacterCount + clock.contentCharacterCount
            continuation.yield(.done(clock.finish(
                inputTokens: inputTokens,
                outputTokens: Int(ceil(Double(outputCharacters) * 0.5)),
                stopReason: .cancelled,
                modelID: SophiaDefaults.modelID,
                thinkingEnabled: options.thinking
            )))
            continuation.finish()
        } catch {
            continuation.finish(throwing: SophiaError.wrap(error, fallback: .generationFailed))
        }
    }

    /// 文字列を小さく割って流す。**間引かない**（間引きは UI 側の責務）。
    private func emit(
        _ text: String,
        into continuation: AsyncThrowingStream<Chunk, any Error>.Continuation,
        clock: inout GenerationClock,
        as makeChunk: (String) -> Chunk
    ) async throws {
        var buffer = ""
        for character in text {
            buffer.append(character)
            guard buffer.count >= charactersPerChunk else { continue }
            try Task.checkCancellation()
            let chunk = makeChunk(buffer)
            clock.record(chunk)
            continuation.yield(chunk)
            buffer = ""
            try await Task.sleep(for: chunkInterval)
        }
        if !buffer.isEmpty {
            let chunk = makeChunk(buffer)
            clock.record(chunk)
            continuation.yield(chunk)
        }
    }

    // MARK: - ダミー本文

    private static func thinkingText(for prompt: String) -> String {
        """
        利用者の入力を確認する。「\(prompt.prefix(30))」という内容だ。
        まず何を聞かれているのかを整理したい。表面的な問いと、その背後にある目的が
        一致しているとは限らないので、両方を見る必要がある。
        次に、答えの形を決める。長い説明が要るのか、一言で足りるのかで組み立てが変わる。
        ここでは短く答えたうえで、必要なら補足を添える形が良さそうだ。
        最後に、断定してよい部分と、確認が要る部分を分けておく。
        """
    }

    private static func replyText(for prompt: String, thinking: Bool) -> String {
        let mode = thinking ? "思考モード有効" : "思考モード無効"
        return """
        これは StubEngine（ダミー）の応答です。モデルは読み込まれていません。

        受け取った入力: 「\(prompt.prefix(40))」
        現在の設定: \(mode)

        コードブロックの表示確認（FR-06）:

        ```swift
        for try await chunk in engine.chat(messages, options: options) {
            switch chunk {
            case .thinking(let text): print("思考: \\(text)")
            case .content(let text): print(text, terminator: "")
            default: break
            }
        }
        ```

        中断（FR-02）を試すには、生成中に停止ボタンを押してください。
        ここまでに表示された文字は消えないはずです。
        """
    }
}
