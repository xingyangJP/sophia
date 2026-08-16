import Foundation
import HuggingFace  // #hubDownloader() の展開結果が要求する（MLX_SWIFT.md 第2.4節）
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers  // #huggingFaceTokenizerLoader() の展開結果が要求する

// =============================================================================
//  MLX Swift による推論エンジン（A1 本番実装）
// -----------------------------------------------------------------------------
//  `StubEngine` は書き換えていない。両方を残すと、不具合が UI 側か推論側かを
//  切り分けられる（`EngineIdentifier` を切り替えるだけで比較できる）。
//
//  ## 設計上の選択と、その理由
//
//  | 選択 | 理由 |
//  |---|---|
//  | 低レベル API（`ModelContainer.generate`）を使う | `ChatSession` は**中断したターンを履歴に残さない**（`AssistantGeneration.shouldRecord` が `stopReason != .cancelled` を要求）。FR-02「既出力は消えない」と正面から衝突する（MLX_SWIFT.md 第5章） |
//  | `actor` にする | `ModelContainer` が隔離されている。推論を MainActor で走らせない（NFR-02） |
//  | `[Chat.Message]` を引数で渡さない | `Chat.Message` / `UserInput` が `Sendable` ではない。Task 境界を越えるとコンパイルエラー（MLX_SWIFT.md 第4.4節） |
//  | 思考分離は公式 `ReasoningEventEmitter` | 区切り文字をモデルの宣言から取るので、モデルを差し替えても壊れない |
//  | `primedInside` を推測しない | 描画済みプロンプトの末尾から導出する。Qwen3 で `true` にすると全崩壊する |
//
//  ## 未確認（このファイルについて）
//
//  **モデルのロードも生成も一度も実行していない。**（並列作業中の16GB機で
//  推論を走らせるとスワップで共倒れになるため、指示により禁止されている）
//  確認したのはビルドが通ること、および `ThinkingSplitter` の文字列単体テストのみ。
//  実機で最初に確かめるべき点は本ファイル末尾の「実機で確かめること」に列挙した。
// =============================================================================

/// MLX Swift 実装（NFR-09 の差し替え対象）。
actor MLXEngine: InferenceEngine {

    nonisolated let identifier: EngineIdentifier = .mlx

    /// 読み込み済みのモデル。未ロードなら nil。
    private var container: ModelContainer?
    private var current: ModelInfo?

    /// モデルが宣言した思考プロトコル。ロード時に `ModelContext` から取る。
    /// nil のモデルは思考モードを持たない。
    private var reasoning: ReasoningConfig?

    /// 生成が同時に2本走らないようにする。16GB機では致命的なので直列化する。
    private var isGenerating = false

    /// 読み込みが同時に2本走らないようにする。
    /// **重みは 4.62GB ある。** 二重に走らせると 9GB を掴んで確実に落ちる。
    private var isLoading = false

    init() {
        // 起動時の1度きり。`static let` なので何度 init しても1回しか走らない。
        _ = Self.runtimeConfigured
    }

    // MARK: - 起動時の設定

    /// MLX のバッファキャッシュ上限を入れる。
    ///
    /// 公式サンプル LLMEval / LLMBasic / MLXChatExample の**3つとも 20MB**
    /// で、「LLMは20MB」が事実上の推奨値（MLX_SWIFT.md 第8.1節）。
    /// 16GB・スワップ6〜7GBのこの機体では、まずこれを入れないと話が始まらない。
    ///
    /// `MLX.GPU.set(cacheLimit:)` は**非推奨**。`Memory.cacheLimit` を使う。
    private static let runtimeConfigured: Bool = {
        MLX.Memory.cacheLimit = SophiaDefaults.mlxCacheLimitBytes
        return true
    }()

    // MARK: - InferenceEngine（問い合わせ）

    func loadedModel() -> ModelInfo? { current }

    func capabilities() -> EngineCapabilities {
        // 思考モードの可否は**モデルの宣言から導く**。キー名をハードコードしない。
        //
        // `ReasoningPromptStrategy.none` は `Optional.none` と綴りが衝突するので、
        // Optional のまま switch せず、先に開いてから分岐する。
        let supportsThinking: Bool
        let canDisable: Bool
        switch reasoning?.promptStrategy {
        case .some(.templateFlag):
            // Qwen3。`enable_thinking` で ON/OFF できる。
            (supportsThinking, canDisable) = (true, true)
        case .some(.alwaysOn):
            // DeepSeek-R1 系。思考はするが OFF にできない。
            // ここで false を返さないと、押しても効かないトグルが UI に出る。
            (supportsThinking, canDisable) = (true, false)
        case .some(.none), nil:
            // 思考モードを持たないモデル、または未ロード。
            (supportsThinking, canDisable) = (false, false)
        }

        return EngineCapabilities(
            supportsThinking: supportsThinking,
            canDisableThinking: canDisable,
            maxContextLength: current?.maxContextLength ?? SophiaDefaults.contextLength,
            // `GenerateParameters.prefill.progress` は main リビジョンにのみ存在する。
            // いま固定しているのは main（d7dc03d）なので送れる。
            reportsPrefillProgress: true,
            // `GenerateCompletionInfo` が実測のトークン数を返す。
            // ただし**中断時は `.info` が届かないことがあり**、その場合だけ概算になる。
            reportsExactTokenCounts: true
        )
    }

    func availableModels() -> [ModelInfo] {
        MLXModelCatalog.entriesReflectingDisk()
    }

    // MARK: - InferenceEngine（読み込み）

    nonisolated func load(_ modelID: String) -> AsyncThrowingStream<LoadProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.performLoad(modelID, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unload() {
        container = nil
        current = nil
        reasoning = nil
        // 重みを手放したあとにキャッシュを返す。16GB機では効く。
        MLX.Memory.clearCache()
    }

    // MARK: - InferenceEngine（生成）

    nonisolated func chat(
        _ messages: [SophiaMessage],
        options: ChatOptions
    ) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.performChat(messages, options: options, into: continuation) }
            // 消費側が Task をキャンセルすると、ここが発火して生成が止まる（FR-02）。
            // MLX の生成ループは `while !Task.isCancelled` なので実際に止まる。
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 読み込みの中身

    private func performLoad(
        _ modelID: String,
        into continuation: AsyncThrowingStream<LoadProgress, any Error>.Continuation
    ) async {
        // 二重読み込みの防止。ここは 4.62GB を掴む処理なので、
        // 「たぶん大丈夫」で通してはいけない。
        guard !isLoading else {
            continuation.finish(throwing: SophiaError(
                code: .modelLoadFailed,
                message: "モデルの読み込みがすでに進行中です。",
                hint: "読み込みが終わるまでお待ちください。"))
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            continuation.yield(LoadProgress(
                stage: .resolving, detail: "モデルを確認しています"))

            // すでに同じモデルが載っている。**4.62GB を読み直さない。**
            if container != nil, current?.id == modelID {
                continuation.yield(LoadProgress(
                    stage: .ready, fraction: 1, detail: "準備できました"))
                continuation.finish()
                return
            }

            // 別のモデルへ切り替える場合は、先に手放す。
            // 16GB機で 4.62GB を2つ載せる余地は無い。
            if container != nil {
                unload()
            }

            let configuration = MLXModelCatalog.configuration(for: modelID)
            let alreadyOnDisk = MLXModelCatalog.isDownloaded(modelID)
            let entry = MLXModelCatalog.entry(for: modelID)

            if !alreadyOnDisk {
                let size = entry.sizeBytes.map(Self.formatBytes) ?? "数GB"
                continuation.yield(LoadProgress(
                    stage: .downloading, fraction: 0,
                    detail: "モデルを取得しています（初回のみ・約\(size)）"))
            }

            try Task.checkCancellation()

            // ダウンロードは初回のみ。2回目以降は HuggingFace のキャッシュから読む。
            //
            // 進捗コールバックは**別スレッドから呼ばれる**が、
            // `AsyncThrowingStream.Continuation` はスレッド安全なのでそのまま yield できる。
            //
            // NFR-01 との関係: ここが `network.client` entitlement を要求する唯一の場所。
            // 会話は一切外に出ない。A2 以降、ローカルディレクトリ読み込み
            // （MLX_SWIFT.md 第2.3節C）に切り替えれば entitlement ごと落とせる。
            let loaded = try await loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { progress in
                    // `Progress` の単位は**バイト**（swift-huggingface の
                    // `snapshotWeight(for:)` が各ファイルのサイズを重みにしている）。
                    // ただしサイズ不明のファイルには既定の重みが入るので、
                    // 総量はおおよその値である。進捗表示には十分。
                    let fraction = progress.fractionCompleted
                    let completed = progress.completedUnitCount
                    let total = progress.totalUnitCount
                    continuation.yield(LoadProgress(
                        stage: fraction >= 1.0 ? .loadingWeights : .downloading,
                        completedBytes: completed > 0 ? completed : nil,
                        totalBytes: total > 0 ? total : nil,
                        fraction: fraction,
                        detail: fraction >= 1.0
                            ? "重みをメモリへ展開しています"
                            : "モデルを取得しています（\(Int(fraction * 100))%）"))
                }
            )

            try Task.checkCancellation()

            continuation.yield(LoadProgress(
                stage: .loadingWeights, fraction: 1, detail: "重みをメモリへ展開しています"))

            // モデルが宣言した思考プロトコルを受け取る。
            // Qwen3 は `QwenReasoningProtocol.qwen3` を自分で宣言し、
            // `LLMModelFactory._load` が `ModelContext.configuration` に載せる。
            let declaredReasoning = await loaded.configuration.reasoningConfig

            container = loaded
            reasoning = declaredReasoning

            var info = entry
            info.isDownloaded = true
            info.supportsThinking = declaredReasoning != nil
            current = info

            continuation.yield(LoadProgress(
                stage: .ready, fraction: 1, detail: "準備できました"))
            continuation.finish()

        } catch {
            continuation.finish(throwing: SophiaError.fromModelLoad(error))
        }
    }

    // MARK: - 生成の中身

    private func performChat(
        _ messages: [SophiaMessage],
        options rawOptions: ChatOptions,
        into continuation: AsyncThrowingStream<Chunk, any Error>.Continuation
    ) async {
        // 計測の起点。**必ずこの時計を使う。** `Date()` を各自が挟むと
        // TTFT の起点がずれ、BENCH_RESULTS.md の数字が比較不能になる。
        var clock = GenerationClock()

        // 思考モードの maxTokens 補正は「エンジン呼び出しの直前で1回だけ」。
        // 実測では出力の約9割を思考が食い、上限が小さいと本文に到達しない。
        let options = rawOptions.applyingThinkingBudget()

        guard let container else {
            continuation.finish(throwing: SophiaError(code: .modelNotLoaded))
            return
        }
        guard !isGenerating else {
            continuation.finish(throwing: SophiaError(
                code: .generationFailed,
                message: "前の応答がまだ生成中です。",
                hint: "生成が終わるか、停止してから送信してください。"))
            return
        }
        isGenerating = true
        defer { isGenerating = false }

        // ピークメモリの計測窓をこの生成に絞る。
        //
        // `Memory.peakMemory` は**プログラム開始からの最大値**なので、
        // 何もしないと「アプリ起動以来のピーク」が毎回同じ値で返り、
        // 生成ごとの比較ができない。setter は newValue を無視して
        // `mlx_reset_peak_memory()` を呼ぶ（MLX 0.31.6 の実装）。
        //
        // プロセス全体で1つの値なので、**生成を直列化していることが前提**になる
        // （上の `isGenerating` がそれを担保している）。
        // ロードと生成が重なると汚れるが、A1 の使い方では重ならない。
        MLX.Memory.peakMemory = 0

        // 中断された場合でも計測値を組み立てられるよう、`do` の外に置く。
        // 送信前の概算で初期化し、`prepare` が済んだら実測値で上書きする。
        var inputTokens = messages.estimatedTokenCount

        do {
            // --- 入力を組む -----------------------------------------------------
            // `Chat.Message` は Sendable ではない。**このタスクの内側で組み立てる。**
            // 引数で受け取ろうとすると `sending 'input' risks causing data races`。
            let chat: [Chat.Message] = messages.map { message in
                switch message.role {
                case .system: .system(message.content)
                case .user: .user(message.content)
                case .assistant: .assistant(message.content)
                }
            }

            // 思考モードの ON/OFF（FR-18）。**キー名をハードコードしない。**
            // Qwen3 は `enable_thinking`、DeepSeek-R1 系は OFF にできず throw する。
            let strategy = reasoning?.promptStrategy
                ?? .templateFlag(key: "enable_thinking", defaultOn: true)
            let additionalContext = try strategy.additionalContext(
                forThinkingEnabled: options.thinking)

            // チャットテンプレート（Jinja）はこの `prepare` の内側で
            // トークナイザが適用する。Ollama ではサーバの仕事だった部分。
            let userInput = UserInput(chat: chat, additionalContext: additionalContext)
            let lmInput = try await container.prepare(input: userInput)

            let promptTokens = lmInput.text.tokens.asArray(Int.self)
            inputTokens = promptTokens.count

            guard inputTokens < options.contextLength else {
                throw SophiaError(
                    code: .contextOverflow,
                    hint: "入力が \(inputTokens) トークンで、上限 \(options.contextLength) を超えています。"
                        + "会話を新しく始めるか、入力を短くしてください。")
            }

            // --- 思考分離器を用意する（FR-17）------------------------------------
            var separator = await makeSeparator(
                container: container, promptTokens: promptTokens)

            // --- 生成パラメータ ---------------------------------------------------
            var configured = GenerateParameters(
                maxTokens: options.maxTokens,
                maxKVSize: options.maxKVSize,
                kvBits: options.kvBits,
                kvScheme: options.kvScheme,
                temperature: Float(options.temperature),
                topP: Float(options.topP),
                topK: options.topK,
                repetitionPenalty: options.repetitionPenalty.map(Float.init),
                seed: options.seed
            )

            // プリフィルの進捗（`main` リビジョンにのみ存在する）。
            //
            // **これが A1 の隠れた要件に効く。** 思考モードでは本文が出るまで
            // 15〜29秒かかるが、その前半はプリフィルである。ここを出せると
            // 「無言でフリーズしているように見える時間」が消える。
            configured.prefill.progress = { processed, total in
                continuation.yield(.prefill(PrefillProgress(
                    processedTokens: processed, totalTokens: total)))
            }

            // `var` のままだと `@Sendable` クロージャに捕まえられない
            // （"reference to captured var in concurrently-executing code"）。
            // 組み立てが終わったら不変にしてから渡す。
            let parameters = configured
            let components = makeGenerationComponents(options: options)

            // --- 生成ストリームを開く ---------------------------------------------
            //
            // 注意: プリフィルは `TokenIterator.init` の中、つまり
            // **この `generate` 呼び出しの内側で同期的に走る。**
            // 上の progress コールバックはストリームが返る前に発火する。
            // `continuation` は既に存在しているので取りこぼさない。
            let stream = try await container.perform(nonSendable: lmInput) { context, input in
                try MLXLMCommon.generate(
                    input: input,
                    parameters: parameters,
                    context: context,
                    components: components)
            }

            // --- 断片を流す -------------------------------------------------------
            //
            // **間引かない。** 受け取った断片をそのまま全件流す。
            // 16ms のバッファリングは UI 側の責務（エンジンが間引くと計測が汚れる）。
            //
            // 1トークン = 1 `.chunk` ではない。デトークナイザは日本語のように
            // 1文字が複数トークンにまたがる場合、Unicode 境界が揃うまで出力を保留する
            // （`NaiveStreamingDetokenizer`）。文字化けした断片が画面に出ないのはこのため。
            var info: GenerateCompletionInfo?

            for await item in stream {
                switch item {
                case .chunk(let text):
                    for segment in separator.process(text) {
                        emit(segment, clock: &clock, into: continuation)
                    }
                case .info(let received):
                    info = received
                default:
                    // `.toolCall` / `.rejectedToolCall` は A1 では使わない。
                    // ツール定義を送らない以上、来ないはず（VISION 第1因子）。
                    break
                }
            }

            // 保留していた末尾を吐き出す。**呼び忘れると末尾が消える。**
            for segment in separator.finalize() {
                emit(segment, clock: &clock, into: continuation)
            }

            // --- 終端と計測（FR-14）------------------------------------------------
            //
            // ここに来る経路は3つある。
            //   1. 正常終了 → `.info` が届いている
            //   2. 中断 → `AsyncStream` は nil を返して抜ける。`.info` は届かないことがある
            //   3. 上限打ち切り → `.info` の `stopReason` が `.length`
            let cancelled = Task.isCancelled
            let stopReason = Self.stopReason(from: info, cancelled: cancelled)

            // 中断時に `.info` が来なかった場合だけ、文字数から概算する。
            // 概算であることは `EngineCapabilities.reportsExactTokenCounts` では
            // 表現できないので、BENCH に載せるときは `stopReason == .cancelled` を見ること。
            let estimatedOutput = Int(ceil(
                Double(clock.thinkingCharacterCount + clock.contentCharacterCount) * 0.5))

            continuation.yield(.done(clock.finish(
                inputTokens: info?.promptTokenCount ?? inputTokens,
                outputTokens: info?.generationTokenCount ?? estimatedOutput,
                stopReason: stopReason,
                prefillSeconds: info?.promptTime,
                prefillTokensPerSecond: info?.promptTokensPerSecond,
                decodeSeconds: info?.generateTime,
                // 思考トークンは実測できない（分離器は復号後のテキストしか見ない）。
                // nil を渡すと `GenerationClock` が文字数から概算し、
                // `thinkingTokensAreEstimated` を立ててくれる。
                thinkingTokens: nil,
                modelID: current?.id,
                thinkingEnabled: options.thinking,
                // 生成開始時にリセットしてあるので、この生成でのピーク。
                // **[未確認]** `peakMemory` は実際のGPUフットプリントを過少報告する
                // という外部報告がある（MLX_SWIFT.md 第8.4節）。鵜呑みにせず、
                // 速度の外れ値を説明したいときはアクティビティモニタと突き合わせること。
                peakMemoryBytes: MLX.Memory.peakMemory
            )))
            continuation.finish()

        } catch is CancellationError {
            // **プリフィル中に中断された経路。** ここは「失敗」ではない（FR-02）。
            //
            // プリフィルは 512 トークン単位で刻まれ、その境目で
            // `Task.checkCancellation()` が入っている（`PrefillParameters.forEachChunk`）。
            // つまり長いプロンプトの処理中でも中断が効き、そのとき例外として上がる。
            //
            // 生成ループまで進んでいた場合はここへ来ず、上の正常経路で `.done` を出す
            // （`AsyncStream` はキャンセル時に例外ではなく終端で抜けるため）。
            // **どちらの経路でも `.done` の出し方を揃えておく。**
            // 消費側が既に離脱していればこの yield は捨てられる。それで正しい。
            continuation.yield(.done(clock.finish(
                inputTokens: inputTokens,
                outputTokens: Int(ceil(
                    Double(clock.thinkingCharacterCount + clock.contentCharacterCount) * 0.5)),
                stopReason: .cancelled,
                modelID: current?.id,
                thinkingEnabled: options.thinking,
                peakMemoryBytes: MLX.Memory.peakMemory
            )))
            continuation.finish()

        } catch {
            continuation.finish(throwing: SophiaError.fromGeneration(error))
        }
    }

    // MARK: - 断片の送出

    /// 分離結果を `Chunk` にして流し、同時に計測へ記録する。
    ///
    /// **計測と送出を必ずセットにするための関数。** 片方だけ書くと TTFT がずれる。
    private func emit(
        _ segment: ThinkingSegment,
        clock: inout GenerationClock,
        into continuation: AsyncThrowingStream<Chunk, any Error>.Continuation
    ) {
        let chunk: Chunk =
            switch segment {
            case .thinking(let text): .thinking(text)
            case .content(let text): .content(text)
            }
        clock.record(chunk)
        continuation.yield(chunk)
    }

    // MARK: - 思考分離器の組み立て

    /// モデルの宣言から分離器を作る。
    ///
    /// `primedInside` を**推測しない**のがここの要点。
    /// 描画済みプロンプトの末尾を実際に見て、思考ブロックが開いた状態で
    /// プロンプトが終わっているかを判定する。
    ///
    /// | モデル | プロンプトが `<think>` で終わるか | `primedInside` |
    /// |---|---|---|
    /// | Qwen3（思考ON） | **終わらない**（モデルが自分でストリームに出す） | false |
    /// | Qwen3（思考OFF） | 閉じた空ブロックが入る | false |
    /// | DeepSeek-R1 系 | 終わる | true |
    ///
    /// Qwen3 で `true` にすると全崩壊する。だから直書きしない。
    private func makeSeparator(
        container: ModelContainer,
        promptTokens: [Int]
    ) async -> any ThinkingSeparating {
        guard let reasoning else {
            // 思考プロトコルを宣言していないモデル。素通しでよいが、
            // 未知のモデルが `<think>` を出す場合に備えて自作分離器を噛ませる。
            return ThinkingSplitter()
        }

        // 末尾だけを復号する。全文を復号する必要はない（長いと無駄）。
        // `decode(tokenIds:)` は既定で特殊トークンを残すので `<think>` が消えない。
        let tail = promptTokens.suffix(64)
        let renderedTail = await container.decode(tokenIds: Array(tail))
        let primedInside = ReasoningEventEmitter.promptEndsInsideReasoning(
            renderedPromptTail: renderedTail, config: reasoning)

        return ReasoningEmitterSeparator(config: reasoning, primedInside: primedInside)
    }

    // MARK: - 解剖のための拡張点（VISION）

    /// 生成の振る舞いに差し込むもの。**A1 では空。**
    ///
    /// ここが VISION 第3因子（全部を起動しない）への正規の入口である。
    /// 生成ループを塞がずに後から差し込めるよう、呼び出し経路だけ先に通してある
    /// （`ModelContainer.generate` ではなく `perform` + 自由関数 `generate` を
    /// 使っているのは、この `components:` を渡せるのがそちらだけだから）。
    ///
    /// ## ここに足せるもの
    ///
    /// | 足すもの | 効果 | 参照 |
    /// |---|---|---|
    /// | `ThinkingBudgetProcessor` | 思考トークンの上限制御。**「予算の9割」問題への直接の道具** | 下記 |
    /// | 確信度による打ち切り | 早期終了のうち、層に触らずできる部分 | `LogitProcessor` |
    /// | ロジット分布の記録 | 「どこで迷ったか」の測定 | `LogitProcessor.process(logits:)` |
    ///
    /// 思考予算を入れる場合の形（コンパイル確認済みの呼び出し形。A1 では使わない）:
    ///
    /// ```swift
    /// components = try components.applyingThinkingBudget(
    ///     ThinkingBudgetConfiguration(maximumTokenCount: 512, minimumAnswerTokenCount: 128),
    ///     reasoning: reasoning,
    ///     tokenizer: tokenizer)
    /// ```
    ///
    /// ## ここでは足りないもの（層ごとの計測・早期終了）
    ///
    /// `LogitProcessor` はサンプリング層のフックなので、**層のループには届かない。**
    /// 層に手を入れるには `MLXLLM/Models/Qwen3.swift` をこのリポジトリへ複製して
    /// 改造し、`ModelTypeRegistry.registerModelType("qwen3", ...)` で登録し直す
    /// （`Qwen3TransformerBlock` が internal なので、外から差すのではなく
    /// ファイルごと複製する必要がある。両リポジトリとも MIT）。
    ///
    /// **その前に未解決の課題がある。** MLX は遅延評価なので、層のループに
    /// `Date()` を挟んでも実時間は測れない。各層の後に `eval()` を入れると
    /// 同期はできるが、**測定行為がパイプラインを壊して対象を変えてしまう。**
    /// 層ごとの計測方法論の確立が、早期終了に着手する前提になる
    /// （MLX_SWIFT.md 第7.3節 / 第12.4節）。
    private func makeGenerationComponents(options: ChatOptions) -> GenerationComponents {
        GenerationComponents()
    }

    // MARK: - 小物

    private static func stopReason(
        from info: GenerateCompletionInfo?, cancelled: Bool
    ) -> StopReason {
        if let info {
            switch info.stopReason {
            case .stop: return .completed
            case .length: return .maxTokens
            case .cancelled: return .cancelled
            @unknown default: return .completed
            }
        }
        // `.info` が届かなかった。中断が最有力（キャンセル時はストリームが先に終端する）。
        return cancelled ? .cancelled : .completed
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// =============================================================================
//  実機で確かめること（このファイルは実行していない）
// -----------------------------------------------------------------------------
//  1. **トークンが実際に流れるか。** `.chunk` が届き、日本語が化けないこと
//  2. **思考と本文が分かれるか（FR-17）。** `primedInside` の自動判定が
//     Qwen3 で `false` になること。`true` になっていたら思考が本文へ漏れる
//  3. **思考OFFが効くか（FR-18）。** `enable_thinking: false` で
//     `<think></think>` の空ブロックだけが来て、思考テキストが出ないこと
//  4. **中断が効くか（FR-02）。** `task.cancel()` から実際に生成が止まるまでの時間。
//     ストリームを抜けても計算は数ミリ秒続くと公式コメントにある
//  5. **プリフィル進捗が届くか。** `.prefill` が複数回来ること
//     （1回しか来ないなら chunking が働いていない）
//  6. **計測値が Ollama と比較できるか。** `promptTokensPerSecond` を
//     BENCH_RESULTS.md の「入力処理 148 tok/s」と並べる
//  7. **メモリが持つか。** 4.62GB の重み + KVキャッシュで、
//     この機体（空き0.5〜2.8GB / スワップ6〜7GB）が耐えるか
//  8. **計測時はデバッガを外す**（cmd-opt-r → "Debug Executable" のチェックを外す）
// =============================================================================
