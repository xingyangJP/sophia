import Foundation

/// **UI の描画を確かめるためだけのエンジン。** 推論は一切行わない。
///
/// `StubEngine`（`Sources/Engine/`）とは役割が違う。
///
/// | | StubEngine | MockEngine |
/// |---|---|---|
/// | 目的 | 契約が実装可能であることの証明・実測に近い速度の再現 | **描画の限界を突く** |
/// | 速度 | 実測どおり 約26文字/秒 | **1文字を4msごと（約250/秒）** = 間引きが効かないと破綻する |
/// | 本文 | 短い定型文 | 見出し・箇条書き・引用・複数言語のコードブロック |
/// | 失敗 | 起きない | `.failure` で FR-11 の表示を確認できる |
///
/// `StubEngine` は書き換えない約束なので、描画確認用の材料はこちらへ足す。
/// **本番の経路には入らない**（`EngineFactory` が DEBUG かつ環境変数付きのときだけ使う）。
actor MockEngine: InferenceEngine {

    enum Scenario: String, Sendable, CaseIterable {
        /// Markdown を一通り含む長文。**1文字4ms で流す**（間引きの検証用）。
        case rich
        /// 思考が長く本文が短い。FR-17 の自動折りたたみと秒数表示の検証用。
        case thinkingHeavy
        /// 途中で失敗する。FR-11 の表示と、既出力が残ることの検証用。
        case failure
    }

    nonisolated let identifier: EngineIdentifier = .stub
    private let scenario: Scenario
    private var current: ModelInfo?

    init(scenario: Scenario = .rich) {
        self.scenario = scenario
    }

    // MARK: - InferenceEngine

    func loadedModel() -> ModelInfo? { current }

    func capabilities() -> EngineCapabilities {
        EngineCapabilities(
            supportsThinking: true,
            canDisableThinking: true,
            maxContextLength: SophiaDefaults.contextLength,
            reportsPrefillProgress: true,
            reportsExactTokenCounts: false
        )
    }

    func availableModels() -> [ModelInfo] {
        [ModelInfo(
            id: SophiaDefaults.modelID,
            parameterSize: "8.2B",
            quantization: "4bit",
            supportsThinking: true,
            maxContextLength: 32_768,
            isDownloaded: true
        )]
    }

    nonisolated func load(_ modelID: String) -> AsyncThrowingStream<LoadProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.setCurrent(self.availableModels().first)
                continuation.yield(LoadProgress(stage: .ready, fraction: 1, detail: "描画確認用のダミーです"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unload() { current = nil }

    nonisolated func chat(
        _ messages: [SophiaMessage],
        options: ChatOptions
    ) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.generate(messages, options: options, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 内部

    private func setCurrent(_ model: ModelInfo?) { current = model }

    private func generate(
        _ messages: [SophiaMessage],
        options: ChatOptions,
        into continuation: AsyncThrowingStream<Chunk, any Error>.Continuation
    ) async {
        var clock = GenerationClock()
        let options = options.applyingThinkingBudget()
        let inputTokens = messages.estimatedTokenCount

        // 1文字ずつ 4ms 間隔。実測の約10倍の速さで流し、UI 側の間引きを試す。
        let interval = Duration.milliseconds(4)

        do {
            for step in 1...6 {
                try Task.checkCancellation()
                continuation.yield(.prefill(PrefillProgress(
                    processedTokens: inputTokens * step / 6,
                    totalTokens: inputTokens
                )))
                try await Task.sleep(for: .milliseconds(90))
            }

            if options.thinking {
                let thinking = scenario == .thinkingHeavy ? Self.longThinking : Self.thinking
                try await emit(thinking, interval: interval, into: continuation, clock: &clock) { .thinking($0) }
            }

            if scenario == .failure {
                try await emit(Self.partialBody, interval: interval, into: continuation, clock: &clock) { .content($0) }
                continuation.finish(throwing: SophiaError(
                    code: .outOfMemory,
                    detail: "MockEngine(.failure) が意図的に投げた検証用の失敗"
                ))
                return
            }

            let body = scenario == .thinkingHeavy ? Self.shortBody : Self.richBody
            try await emit(body, interval: interval, into: continuation, clock: &clock) { .content($0) }

            let characters = clock.thinkingCharacterCount + clock.contentCharacterCount
            continuation.yield(.done(clock.finish(
                inputTokens: inputTokens,
                outputTokens: Int(ceil(Double(characters) * 0.5)),
                stopReason: .completed,
                modelID: SophiaDefaults.modelID,
                thinkingEnabled: options.thinking
            )))
            continuation.finish()

        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: SophiaError.wrap(error, fallback: .generationFailed))
        }
    }

    private func emit(
        _ text: String,
        interval: Duration,
        into continuation: AsyncThrowingStream<Chunk, any Error>.Continuation,
        clock: inout GenerationClock,
        as makeChunk: (String) -> Chunk
    ) async throws {
        for character in text {
            try Task.checkCancellation()
            let chunk = makeChunk(String(character))
            clock.record(chunk)
            continuation.yield(chunk)
            try await Task.sleep(for: interval)
        }
    }

    // MARK: - 描画確認用の文面

    private static let thinking = """
    まず問いの形を確かめる。表面の質問と、その裏にある目的が一致しているとは限らない。
    次に、答えを短くまとめられるかを見る。まとめられるなら、そちらを先に出したほうがよい。
    最後に、断定してよい部分と、確認が要る部分を分けておく。
    """

    private static let longThinking = String(repeating: """
    ここは思考テキストである。実測では思考が生成トークンの約9割を消費し、\
    本文が出るまで15〜29秒かかる。その間ずっと無言だと、利用者にはフリーズと区別がつかない。\
    だからこの領域は生成開始と同時に開き、文字が流れている状態にしておく必要がある。

    """, count: 6)

    private static let shortBody = "短い答えです。思考のほうが本文よりずっと長いことが分かります。"

    private static let partialBody = """
    ここまでは正常に生成されました。この直後に失敗させます。
    **中断や失敗のあとも、ここまでの文字は消えないはずです。**
    """

    private static let richBody = """
    # 描画確認

    これは **MockEngine** の応答です。`InferenceEngine` の型しか使っていないため、
    MLX 実装に差し替えても UI 側は1行も変わりません。

    ## 確認したい項目

    - 見出し・箇条書き・強調が出るか
    - `インラインコード` が本文と区別できるか
    - コードブロックに色が付き、コピーできるか（FR-06）
    - 生成中に画面が固まらないか（NFR-02）

    1. 送信すると即座に思考領域が開く
    2. 本文が始まると思考は自動的に畳まれる
    3. 畳んだあとも再展開できる

    > 思考テキストは本文より薄い色で描く。主従を逆転させない。

    ## コード（Swift）

    ```swift
    // 中断は Task のキャンセルに載せる。蓄積先は Task の外に置く。
    func stop() {
        stopRequested = true
        generationTask?.cancel()
    }

    private func apply(_ chunk: Chunk) {
        switch chunk {
        case .thinking(let text): pendingThinking += text
        case .content(let text):  pendingContent += text
        case .done(let stats):    self.stats = stats
        default: break            // ケースは今後増える
        }
    }
    ```

    ## コード（Python）

    ```python
    def budget(tokens: int, rate: float = 148.0) -> float:
        \"\"\"プリフィルの秒数を概算する。148 tok/s は実測値。\"\"\"
        if tokens <= 0:
            return 0.0
        return tokens / rate   # 1,550 トークンで約10秒
    ```

    ## コード（シェル）

    ```bash
    # 生成物のシンボルを確認する
    make app && nm -gU Sophia/DerivedData/Build/Products/Debug/Sophia.app/Contents/MacOS/Sophia | wc -l
    ```

    以上です。中断（FR-02）を試すには、生成中に停止ボタンを押してください。
    """
}
