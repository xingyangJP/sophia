import Foundation

/// 生成パラメータ（DESIGN.md 第4章）。
///
/// ## `signal: AbortSignal` が無いのは意図的である
///
/// Electron 版はここに `AbortSignal` を持っていた。**Swift では持たない。**
/// 中断は `Task` のキャンセルに載せる（`InferenceEngine` の約束事を参照）。
/// 中断の手段を options に混ぜると、キャンセル経路が2つになって必ず食い違う。
struct ChatOptions: Sendable, Equatable, Codable {
    var temperature: Double
    var topP: Double
    var topK: Int
    /// コンテキスト長（Ollama の `num_ctx` に相当）。
    var contextLength: Int
    /// 生成トークンの上限。**思考モードでは自動的に引き上げる**（`applyingThinkingBudget()`）。
    var maxTokens: Int
    /// 思考モード（FR-18）。対応モデルでのみ有効。
    var thinking: Bool
    /// 再現性が要る計測で使う。nil なら毎回変わる。
    var seed: UInt64?
    /// 繰り返し抑制。nil ならモデルの既定。
    var repetitionPenalty: Double?

    // MARK: - A2以降の最適化用（A1 では nil のまま）

    /// KVキャッシュの上限トークン数。超えたら古いものから捨てる。
    /// MLX: `GenerateParameters.maxKVSize`。
    var maxKVSize: Int?

    /// KVキャッシュの量子化ビット数。MLX: `kvBits`。
    /// 16GB機のメモリ逼迫に直接効く（MLX_SWIFT.md 第8.3節）。
    var kvBits: Int?

    /// KVキャッシュの量子化方式。`main` リビジョンでは `"turbo8v3"` が推奨既定とされる。
    var kvScheme: String?

    init(
        temperature: Double = SophiaDefaults.temperature,
        topP: Double = SophiaDefaults.topP,
        topK: Int = SophiaDefaults.topK,
        contextLength: Int = SophiaDefaults.contextLength,
        maxTokens: Int = SophiaDefaults.maxTokens,
        thinking: Bool = false,
        seed: UInt64? = nil,
        repetitionPenalty: Double? = nil,
        maxKVSize: Int? = nil,
        kvBits: Int? = nil,
        kvScheme: String? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.contextLength = contextLength
        self.maxTokens = maxTokens
        self.thinking = thinking
        self.seed = seed
        self.repetitionPenalty = repetitionPenalty
        self.maxKVSize = maxKVSize
        self.kvBits = kvBits
        self.kvScheme = kvScheme
    }
}

extension ChatOptions {
    /// 思考モードに応じて `maxTokens` を引き上げる（FR-18 / DESIGN.md 第6章）。
    ///
    /// 実測では出力トークンの約9割を思考が消費し、上限が小さいと**本文に到達しないまま
    /// 打ち切られる**（DESIGN.md 第2.1章）。
    ///
    /// **補正はこの関数1つに集約すること。** 3人が別々の係数を書くと挙動が食い違う。
    /// 冪等なので二重に適用しても安全。適用箇所はエンジン呼び出しの直前1か所。
    func applyingThinkingBudget() -> ChatOptions {
        guard thinking, maxTokens < SophiaDefaults.thinkingMinMaxTokens else { return self }
        var copy = self
        copy.maxTokens = SophiaDefaults.thinkingMinMaxTokens
        return copy
    }
}

/// 既定値と設計上の予算。**3者が別々の数字を持たないための単一の出所。**
enum SophiaDefaults {
    /// A1 で使うモデル。MLX_SWIFT.md 第2.2節 / `LLMRegistry.qwen3_8b_4bit` と同一。
    ///
    /// Ollama 用の GGUF（`modelfiles/`）は **MLX では読めない**（MLX_SWIFT.md 第2.1節）。
    /// 必ず MLX形式（safetensors）のリポジトリIDを指すこと。
    static let modelID = "mlx-community/Qwen3-8B-4bit"

    /// `modelfiles/sophia-chat.Modelfile` と揃えてある。
    static let temperature: Double = 0.7
    static let topP: Double = 0.9
    /// Qwen3 の推奨サンプリング（MLX_SWIFT.md 第4.3節の例と同じ）。
    static let topK: Int = 20
    static let contextLength: Int = 8192
    static let maxTokens: Int = 1024

    /// 思考モード有効時に最低限確保する `maxTokens`（FR-18 / DESIGN.md 第6章）。
    static let thinkingMinMaxTokens: Int = 4096

    /// 入力トークンの予算（DESIGN.md 第2.2章）。
    /// 連続使用時でもプリフィルが10秒以内に収まる上限。超えたら UI で警告する。
    static let inputTokenBudget: Int = 1000

    /// MLX のバッファキャッシュ上限（バイト）。
    ///
    /// 公式サンプル LLMEval / LLMBasic / MLXChatExample の**3つとも 20MB** を設定しており、
    /// 「LLMは20MB」が Apple の事実上の推奨値と読める（MLX_SWIFT.md 第8.1節）。
    /// 起動時に一度 `MLX.Memory.cacheLimit` へ入れること。
    static let mlxCacheLimitBytes: Int = 20 * 1024 * 1024

    /// 描画の flush 間隔（秒）。1フレーム分（DESIGN.md 第5.2章）。
    ///
    /// トークンごとに再描画すると生成中ずっと再レンダリングが走る。
    /// **間引きは UI 側の責務。** エンジンは間引かずに全件流すこと。
    static let renderFlushInterval: Duration = .milliseconds(16)
}
