import Foundation

/// 生成が終わった理由。MLX の `GenerateStopReason` と対応させてある。
enum StopReason: String, Sendable, Codable, Equatable, CaseIterable {
    /// モデルが自然に終わった（MLX: `.stop`）。
    case completed
    /// `ChatOptions.maxTokens` に達して打ち切られた（MLX: `.length`）。
    case maxTokens
    /// 利用者が中断した（FR-02 / MLX: `.cancelled`）。
    case cancelled
    /// 失敗して終わった。
    case failed
}

/// FR-14 用の実測値。**VISION の測定原則における一次資料。**
///
/// > 「1/1000」は主張ではなく測定対象である（VISION「当面の指針」1）
///
/// ## フィールドの増やし方
///
/// 先頭の4つは DESIGN.md 第4章が定めた必須項目で、**名前も型も変えない**。
/// それ以降はすべて省略可能で、既定値を持つ。
/// **struct なので、後からフィールドを足しても既存のコードは壊れない**
/// （enum のケースを足すのと違い、網羅 switch が無いため）。
/// 将来の計測点はここに足すこと。
struct GenerationStats: Sendable, Equatable, Codable {

    // MARK: - 必須（DESIGN.md 第4章）

    /// **最初の出力**が届くまでのミリ秒。思考モードONなら「思考の1文字目」まで。
    ///
    /// NFR-03 の判定に使う値がこれである
    /// （「思考モード有効時は思考テキストの表示開始をもって満たす」）。
    var ttftMs: Double

    /// 生成（デコード）の速度。NFR-03b の判定に使う。
    /// MLX の `GenerateCompletionInfo.tokensPerSecond` をそのまま入れるのが基本。
    var tokensPerSecond: Double

    /// 入力トークン数。**エンジンが返した実測値を入れること。** 概算値を入れない。
    var inputTokens: Int

    /// 生成トークン数（思考を含む）。
    var outputTokens: Int

    // MARK: - 将来の計測点（VISION）

    /// **本文の1文字目**が届くまでのミリ秒（Time To First Response）。
    ///
    /// `ttftMs` との差が**思考モードのコストそのもの**である。
    /// Ollama 実測では本文到達まで15〜29秒かかっていた（DESIGN.md 第2.1章）。
    /// VISION の適応度関数「品質 ÷ 消費エネルギー」の材料になる中心的な値。
    /// 思考モードOFFなら `ttftMs` と等しくなる。
    var ttfrMs: Double?

    /// プリフィル（入力処理）に要した秒数。MLX: `GenerateCompletionInfo.promptTime`。
    var prefillSeconds: Double?

    /// プリフィルの速度。MLX: `promptTokensPerSecond`。
    /// BENCH_RESULTS.md の Ollama 実測「入力処理 148 tok/s」と直接比較できる。
    var prefillTokensPerSecond: Double?

    /// デコードに要した秒数。MLX: `generateTime`。
    var decodeSeconds: Double?

    /// 送信から終端までの実時間。壁時計。
    var totalMs: Double?

    /// 思考が消費したトークン数。
    ///
    /// VISION / TUNING.md が記録した「思考が予算の約9割を食う」を継続監視するための値。
    /// トークン単位で数えられない場合は、思考テキストの文字数から概算してよい
    /// （その場合 `thinkingTokensAreEstimated` を true にする）。
    var thinkingTokens: Int?

    /// `thinkingTokens` が概算か。既定は false（＝実測）。
    var thinkingTokensAreEstimated: Bool

    /// 終了理由。
    var stopReason: StopReason

    /// この生成に使ったモデル。BENCH への記録で必須になる。
    var modelID: String?

    /// 思考モードが有効だったか。
    var thinkingEnabled: Bool?

    /// 生成中のピークメモリ（バイト）。MLX: `Memory.snapshot()`。
    ///
    /// この機体では空き0.5〜2.8GB・スワップ6〜7GBで、ページングにより
    /// 最大4.9倍のばらつきが出る（VISION）。**速度の外れ値を説明できる唯一の値**なので、
    /// 取れるなら必ず入れること。
    /// MLX_SWIFT.md 第8.4節の注意: `peakMemory` は過少報告する報告がある。鵜呑みにしない。
    var peakMemoryBytes: Int?

    init(
        ttftMs: Double,
        tokensPerSecond: Double,
        inputTokens: Int,
        outputTokens: Int,
        ttfrMs: Double? = nil,
        prefillSeconds: Double? = nil,
        prefillTokensPerSecond: Double? = nil,
        decodeSeconds: Double? = nil,
        totalMs: Double? = nil,
        thinkingTokens: Int? = nil,
        thinkingTokensAreEstimated: Bool = false,
        stopReason: StopReason = .completed,
        modelID: String? = nil,
        thinkingEnabled: Bool? = nil,
        peakMemoryBytes: Int? = nil
    ) {
        self.ttftMs = ttftMs
        self.tokensPerSecond = tokensPerSecond
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.ttfrMs = ttfrMs
        self.prefillSeconds = prefillSeconds
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.decodeSeconds = decodeSeconds
        self.totalMs = totalMs
        self.thinkingTokens = thinkingTokens
        self.thinkingTokensAreEstimated = thinkingTokensAreEstimated
        self.stopReason = stopReason
        self.modelID = modelID
        self.thinkingEnabled = thinkingEnabled
        self.peakMemoryBytes = peakMemoryBytes
    }
}

extension GenerationStats {
    /// UI にそのまま出せる1行（FR-14）。例: `TTFT 0.42s ・ 12.8 tok/s ・ 入力 312 / 出力 480`
    var summaryLine: String {
        var parts: [String] = [
            String(format: "TTFT %.2fs", ttftMs / 1000),
            String(format: "%.1f tok/s", tokensPerSecond),
            "入力 \(inputTokens) / 出力 \(outputTokens)",
        ]
        if let ttfrMs, ttfrMs > ttftMs {
            parts.insert(String(format: "本文まで %.1fs", ttfrMs / 1000), at: 1)
        }
        if stopReason == .cancelled { parts.append("中断") }
        if stopReason == .maxTokens { parts.append("上限で打ち切り") }
        return parts.joined(separator: " ・ ")
    }
}

// MARK: - 計測

/// **TTFT の定義をここ1か所に固定するための時計。**
///
/// エンジン実装はこの型を使って `GenerationStats` を組み立てること。
/// 各自が `Date()` を挟むと、TTFT の起点（送信時刻かプリフィル開始か）が
/// 実装ごとにずれ、BENCH_RESULTS.md の数字が比較不能になる。
///
/// 起点は **`init` した瞬間 = 利用者の送信を受理した瞬間**とする。
/// モデルのロード時間は含めない（ロードは `InferenceEngine.load` の担当）。
///
/// 単調増加する `ContinuousClock` を使う。`Date` は時刻同期で巻き戻ることがあり、
/// 秒単位の計測には使えない。
struct GenerationClock: Sendable {
    let startedAt: ContinuousClock.Instant

    private var firstOutputAt: ContinuousClock.Instant?
    private var firstContentAt: ContinuousClock.Instant?

    private(set) var thinkingCharacterCount: Int = 0
    private(set) var contentCharacterCount: Int = 0

    init(startedAt: ContinuousClock.Instant = ContinuousClock().now) {
        self.startedAt = startedAt
    }

    /// 送出する `Chunk` をそのまま渡す。`.thinking` / `.content` だけを見る。
    mutating func record(_ chunk: Chunk) {
        let now = ContinuousClock().now
        switch chunk {
        case .thinking(let text):
            if firstOutputAt == nil { firstOutputAt = now }
            thinkingCharacterCount += text.count
        case .content(let text):
            if firstOutputAt == nil { firstOutputAt = now }
            if firstContentAt == nil { firstContentAt = now }
            contentCharacterCount += text.count
        case .prefill, .done:
            break
        }
    }

    /// 思考の1文字目まで（ミリ秒）。まだ何も出ていなければ nil。
    var ttftMs: Double? {
        firstOutputAt.map { (startedAt.duration(to: $0)).milliseconds }
    }

    /// 本文の1文字目まで（ミリ秒）。本文がまだなら nil。
    var ttfrMs: Double? {
        firstContentAt.map { (startedAt.duration(to: $0)).milliseconds }
    }

    /// 起点からの経過（ミリ秒）。
    var elapsedMs: Double {
        startedAt.duration(to: ContinuousClock().now).milliseconds
    }

    /// 計測値を確定させる。
    ///
    /// - Parameters:
    ///   - decodeSeconds: MLX の `GenerateCompletionInfo.generateTime`。
    ///     渡さない場合は「初出力から現在まで」を壁時計で代用する。
    func finish(
        inputTokens: Int,
        outputTokens: Int,
        stopReason: StopReason,
        prefillSeconds: Double? = nil,
        prefillTokensPerSecond: Double? = nil,
        decodeSeconds: Double? = nil,
        thinkingTokens: Int? = nil,
        modelID: String? = nil,
        thinkingEnabled: Bool? = nil,
        peakMemoryBytes: Int? = nil
    ) -> GenerationStats {
        let totalMs = elapsedMs
        let decode: Double = decodeSeconds
            ?? max((totalMs - (ttftMs ?? totalMs)) / 1000, 0)

        // 思考トークンを実測できないエンジン向けの概算。
        //
        // **一律 0.5 を掛けていたのを 2026-08-17 に直した。**
        // 思考は英語で出ることが多く、0.5 では約2倍に膨らむ ─
        // 実際に `think_tok=296` に対し `out=166` という
        // **出力全体より思考が多い**という原理的にありえない値が出ていた。
        //
        // **ただしここには文字数しか無いので、文字種の内訳が分からない。**
        // `SophiaMessage.estimateTokens(in:)` は本文を受け取れるが、
        // `GenerationClock` は文字数しか数えていない。
        // **英語寄りに倒して 0.3 とする。過大に出すより過少のほうが害が小さい**
        // （思考量を過大に見せると、思考OFFの判断を誤らせる）。
        // **本筋は実トークナイザで数えること**（DESIGN.md 第15章）。
        let estimatedThinking = thinkingCharacterCount > 0
            ? Int(ceil(Double(thinkingCharacterCount) * 0.3))
            : nil

        return GenerationStats(
            ttftMs: ttftMs ?? totalMs,
            tokensPerSecond: decode > 0 ? Double(outputTokens) / decode : 0,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            ttfrMs: ttfrMs,
            prefillSeconds: prefillSeconds,
            prefillTokensPerSecond: prefillTokensPerSecond,
            decodeSeconds: decode,
            totalMs: totalMs,
            thinkingTokens: thinkingTokens ?? estimatedThinking,
            thinkingTokensAreEstimated: thinkingTokens == nil && estimatedThinking != nil,
            stopReason: stopReason,
            modelID: modelID,
            thinkingEnabled: thinkingEnabled,
            peakMemoryBytes: peakMemoryBytes
        )
    }
}

extension Duration {
    /// ミリ秒。`components` は (秒, アト秒) なので 1as = 1e-15ms で足す。
    var milliseconds: Double {
        let c = components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) * 1e-15
    }
}
