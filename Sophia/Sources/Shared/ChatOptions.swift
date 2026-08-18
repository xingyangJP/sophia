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

    // MARK: - ツール定義（FR-19 / FR-21 / DESIGN.md 第16.2節）

    /// **このターンでモデルに見せるツールの定義。既定は空 ＝ 1文字も注入しない。**
    ///
    /// ## FR-21 はこの1つの配列に還元されている
    ///
    /// Qwen3 のチャットテンプレートは `{%- if tools %}` を門にしている
    /// （16.1節。開発機に落ちている `tokenizer_config.json` で確認済み）。
    /// **`tools` を渡さなければ、ツールの system ブロックは1文字も描画されない。**
    /// つまり FR-21 は「気をつけて実装する」種類の約束ではなく、
    /// **この配列を空のままにするかどうか**である。
    ///
    /// | 会話の状態（16.2節） | ここに入るもの | 毎ターンの費用 |
    /// |---|---|--:|
    /// | `idle`（**既定**） | `[]` | **0** |
    /// | `armed`（利用者がフォルダを結び付けた） | 3つの定義 | 定義ぶん |
    /// | `resolving`（往復の最中） | 3つの定義 | 定義ぶん |
    /// | 往復が終わったら | **`[]` に戻す** | **0** |
    ///
    /// ## 状態そのものはここに持たない（**重要**）
    ///
    /// `idle` / `armed` / `resolving` の enum をこの型に足さないこと。
    /// **真実の出所が2つになり、必ず食い違う**（`.armed` なのに配列が空、など）。
    /// 状態は会話を持っている層が持ち、**この層に届く時点では
    /// 「配列が空かどうか」に潰れている**のが正しい。
    ///
    /// ## 引き金は利用者の操作だけである
    ///
    /// **利用者の文からツールの要否を推定する分類器を置かないこと**（16.2節）。
    /// それ自体が推論であり、判定のために毎ターン計算を払う ──
    /// VISION 第1因子（そもそも無駄を送らない）に真正面から反する。
    /// **モデルの出力でここを埋める経路も作らないこと**（16.6節の約束3）。
    ///
    /// ## なぜ `[ToolSpec]` をそのまま持たないのか
    ///
    /// MLX の `ToolSpec` は `[String: any Sendable]` である。あれを持つと
    /// (1) `ChatOptions` が `Equatable` / `Codable` を失い、
    /// (2) `Shared/` が MLX を知ることになって NFR-09（エンジン差し替え）が壊れる。
    /// **JSON への変換は MLX を知っている `MLXEngine` の側に閉じてある**
    /// （`MLXEngine.toolSpecs(for:)`）。
    ///
    /// > **永続化していない。** `ChatOptions` は `Store` に落ちていない（A1 現在）。
    /// > 落とすことになったら、このキーを持たない古い JSON は
    /// > synthesized の `init(from:)` で失敗する点に注意すること。
    var tools: [ToolDefinition]

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
        // **既定は空。** FR-21 の既定値がここにある（16.2節の `idle`）。
        // 呼び手が何も言わなければ 0 トークンになる、という順序にしておくこと。
        tools: [ToolDefinition] = [],
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
        self.tools = tools
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

// =============================================================================
//  ツールの定義（FR-19 / DESIGN.md 第16.4節）
// =============================================================================

/// モデルに見せるツール1つの定義。**MLX を知らない形で持つ。**
///
/// ## 何になるのか
///
/// `MLXEngine.toolSpec(for:)` が、これを OpenAI 互換の JSON Schema
/// （`{"type":"function","function":{"name":…,"description":…,"parameters":…}}`）へ
/// 変換して `UserInput(chat:tools:)` に渡す。テンプレートはそれを
/// `<tools>` ブロックに `tool | tojson` で流し込む（16.1節）。
///
/// **この形は 2026-08-18 に実測で通っている** ── 日本語3条件×3回＋英語×3回で
/// 選択 12/12・スキーマ適合 12/12・雑談での誤爆 0/6（`ToolCallProbeTests`）。
/// **形を変えるなら測り直すこと。** 通ったのは「ツール呼び出し一般」ではなく、この形である。
///
/// ## 説明文は短く書くこと
///
/// **定義1つが、そのまま `armed` の間の毎ターンの費用になる**（16.2節）。
/// Open WebUI は32個・約4,550トークンを毎ターン注入して「こんにちは」への応答を
/// 34秒にしていた（TUNING.md 第2章）。**同じ構造を自分で作らないための型である。**
/// 定義は3つまで（16.4節）。4つ目を足したくなったら、まず3つで足りなかった実例を出すこと。
struct ToolDefinition: Sendable, Equatable, Codable {

    /// 関数名。モデルはこの綴りで呼んでくる。`ToolCallRequest.name` と突き合わせる。
    var name: String

    /// 何をするか。**モデルが読む唯一の手掛かり**であり、同時に毎ターンの費用でもある。
    var description: String

    /// 引数。**順序を保つため配列で持つ**（辞書にすると JSON の並びが安定せず、
    /// テストで形を固定できなくなる）。
    var parameters: [Parameter]

    init(name: String, description: String, parameters: [Parameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// 必須引数の名前。**戻り値の検証ではなく、スキーマの `required` を組むために使う。**
    var requiredParameterNames: [String] {
        parameters.filter(\.isRequired).map(\.name)
    }
}

extension ToolDefinition {

    /// ツールの引数1つ。
    ///
    /// **`ToolDefinition` の入れ子にしてあるのは名前の衝突を避けるためである。**
    /// MLXLMCommon が `public struct ToolParameter` を持っており、
    /// 素の `ToolParameter` は **両方が見える文脈で `is ambiguous for type lookup`
    /// になる**（2026-08-18、実際に `EngineToolWiringTests` のコンパイルが止まった）。
    /// `Shared/` は MLX を import できない（NFR-09 / エンジンの差し替え可能性）ので
    /// **向こうの型を使う選択肢は無く**、こちらが名前空間へ引っ込むのが筋である。
    struct Parameter: Sendable, Equatable, Codable {

    /// JSON Schema の型。**16.4節の3つのツールは string と integer しか使わない。**
    /// `array` / `object` を意図的に置いていない ── 入れ子は説明文が伸びて費用が増え、
    /// 受け取り側（`ToolCallRequest`）の取り出しも複雑になる。要るなら実例と一緒に足すこと。
    enum ValueType: String, Sendable, Equatable, Codable, CaseIterable {
        case string
        case integer
        case number
        case boolean
    }

    var name: String
    var type: ValueType
    var description: String
    /// スキーマの `required` に入れるか。
    var isRequired: Bool

    init(name: String, type: ValueType, description: String, isRequired: Bool) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
    }
    }
}

/// 既定値と設計上の予算。**3者が別々の数字を持たないための単一の出所。**
enum SophiaDefaults {
    /// A1 で使うモデル。MLX_SWIFT.md 第2.2節 / `LLMRegistry.qwen3_8b_4bit` と同一。
    ///
    /// Ollama 用の GGUF（`modelfiles/`）は **MLX では読めない**（MLX_SWIFT.md 第2.1節）。
    /// 必ず MLX形式（safetensors）のリポジトリIDを指すこと。
    static let modelID = "mlx-community/Qwen3-8B-4bit"

    /// モデルの自己認識（FR-23）。**毎ターン払うトークンなので、入れる文はここまで。**
    ///
    /// 出所は `modelfiles/sophia-chat.Modelfile` の SYSTEM の**冒頭3行だけ**である。
    /// 同 Modelfile にはこの後に「書き方の原則」「やりとりの原則」が続くが、
    /// **それらは持ち込んでいない。** 自己認識ではなく出力スタイルの調整であり、
    /// 概算で+130トークン／毎ターン かかる一方、モデルは指示が無くても大きくは外さない。
    /// 役割の切替は A2 の `ProfileRecord.systemPrompt`（FR-05）が本来の置き場。
    ///
    /// **Ollama 側とアプリ側は別系統で、`make models` では同期されない。**
    /// アプリが読むのは上の `modelID`（MLX形式）であって Modelfile ではない。
    /// 文言を変えるときは両方を手で合わせること。ここが唯一の食い違いリスク点。
    static let systemPrompt = """
        あなたの名前は Sophia（ソフィア）。この端末の中だけで動くローカルAIアシスタントです。
        名乗るとき・自己紹介するときは常に「Sophia」と名乗ってください。
        基盤技術を直接尋ねられたときだけ、ローカルで動くオープンなモデルの上に構築されていると答えてよい（偽らないこと）。
        """

    /// 自己認識を送るか。**切れることが要件**（既定は送る）。
    ///
    /// `SOPHIA_SYSTEM_PROMPT=0` で切れる。UI のトグルにしていないのは A1 の scope 判断だが、
    /// 切る手段そのものは無くせない。理由は3つあり、どれも測定に効く。
    ///   1. NFR-03（1秒以内に何かが出る）の達成条件は「入力が約170トークン以内」
    ///      （DESIGN.md 第2.4章）。常時ONだと**素の性能を測り続けられなくなる**
    ///   2. VISION の適応度関数（品質÷消費エネルギー）は、同じ問いを
    ///      あり/なしで走らせないと評価できない。切れないと比較実験が成立しない
    ///   3. BENCH_RESULTS で Ollama と並べるとき、片方だけ system を持つと比較が壊れる
    static var systemPromptEnabled: Bool {
        ProcessInfo.processInfo.environment["SOPHIA_SYSTEM_PROMPT"] != "0"
    }

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
