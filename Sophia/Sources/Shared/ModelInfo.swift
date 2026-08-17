import Foundation

/// 推論エンジンの実装識別子（NFR-09）。
enum EngineIdentifier: String, Sendable, Codable, Equatable, CaseIterable {
    /// A1 開発用のダミー。モデルを読まずにストリーミングだけを再現する。
    /// UI 担当は MLX 実装の完成を待たずにこれで作業できる。
    case stub
    /// A1 本番用。MLX Swift で MLX形式（safetensors）のモデルを直接読む。
    case mlx

    /// UI に出す表示名。
    var displayName: String {
        switch self {
        case .stub: "ダミー"
        case .mlx: "MLX"
        }
    }
}

/// エンジンが認識しているモデル1件。
///
/// **エンジン非依存に保つこと。** MLX 固有のフィールドをここへ足さない。
struct ModelInfo: Sendable, Equatable, Codable, Identifiable {
    /// エンジン内でモデルを一意に指す識別子。
    /// MLX では HuggingFace のリポジトリID（例 `mlx-community/Qwen3-8B-4bit`）。
    var id: String
    /// UI に出す表示名。既定は id の末尾。
    ///
    /// **`id` と違ってよい。** 独自の呼び名（例 `Nous 8B`）を出す一方で、
    /// `id` は実際に読んでいるリポジトリを指し続ける。表示名で `id` を置き換えないこと。
    var displayName: String

    /// 重みの出所。**Apache 2.0 の帰属表示（§4）を画面に出すための1行。**
    ///
    /// 表示名を独自のものにすると、画面からベースモデルが分からなくなる。
    /// ライセンス上の義務であると同時に、「重みを実際に作ったのか、
    /// 名前を変えただけなのか」を自分で見失わないための歯止めでもある。
    /// エンジン非依存にしてあるのは、UI が MLX を知らないまま出せるようにするため（NFR-09）。
    var provenance: String?
    /// モデルのサイズ（バイト）。分からなければ nil。
    var sizeBytes: Int64?
    /// パラメータ数の表記（例 `8.2B`）。
    var parameterSize: String?
    /// 量子化の表記（例 `4bit`）。
    var quantization: String?
    /// 思考モード（FR-17/18）に対応しているか。
    var supportsThinking: Bool
    /// コンテキスト長の上限。分からなければ nil。
    var maxContextLength: Int?
    /// ローカルに実体があるか。false なら初回に取得が要る（FR-07）。
    var isDownloaded: Bool

    init(
        id: String,
        displayName: String? = nil,
        provenance: String? = nil,
        sizeBytes: Int64? = nil,
        parameterSize: String? = nil,
        quantization: String? = nil,
        supportsThinking: Bool = false,
        maxContextLength: Int? = nil,
        isDownloaded: Bool = false
    ) {
        self.id = id
        self.displayName = displayName ?? (id.split(separator: "/").last.map(String.init) ?? id)
        self.provenance = provenance
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.supportsThinking = supportsThinking
        self.maxContextLength = maxContextLength
        self.isDownloaded = isDownloaded
    }
}

/// エンジンの能力。**モデルによって変わる**ので、ロード後に問い合わせること。
struct EngineCapabilities: Sendable, Equatable {
    /// 思考モードを出せるか（FR-17）。
    var supportsThinking: Bool

    /// 思考モードを **OFF にできる**か（FR-18）。
    ///
    /// DeepSeek-R1 系のように OFF にできないモデルがある
    /// （MLX_SWIFT.md 第6.3節 `ReasoningPromptStrategy.alwaysOn`）。
    /// false のときに UI が OFF を提供すると、押しても効かないトグルになる。
    var canDisableThinking: Bool

    /// コンテキスト長の上限。
    var maxContextLength: Int

    /// `Chunk.prefill` を送れるか。
    /// MLX_SWIFT.md 第4.3節: `main` リビジョンにしか進捗コールバックが無い。
    var reportsPrefillProgress: Bool

    /// `GenerationStats.inputTokens` / `outputTokens` に**実測値**を入れられるか。
    /// false なら概算が入っている可能性がある。BENCH に載せるときの判断材料。
    var reportsExactTokenCounts: Bool

    init(
        supportsThinking: Bool,
        canDisableThinking: Bool,
        maxContextLength: Int,
        reportsPrefillProgress: Bool = false,
        reportsExactTokenCounts: Bool = true
    ) {
        self.supportsThinking = supportsThinking
        self.canDisableThinking = canDisableThinking
        self.maxContextLength = maxContextLength
        self.reportsPrefillProgress = reportsPrefillProgress
        self.reportsExactTokenCounts = reportsExactTokenCounts
    }
}

/// モデル読み込みの進捗。
///
/// Qwen3-8B-4bit は **4.62GB**（MLX_SWIFT.md 第2.2節）。初回は必ず待たされる。
/// 進捗を出さないと利用者はフリーズと区別できない。
struct LoadProgress: Sendable, Equatable {
    enum Stage: String, Sendable, Equatable {
        /// モデルの所在を解決している。
        case resolving
        /// ダウンロード中（初回のみ）。
        case downloading
        /// 重みをメモリへ展開している。
        case loadingWeights
        /// 使える状態になった。ストリームはこの直後に終了する。
        case ready
    }

    var stage: Stage
    var completedBytes: Int64?
    var totalBytes: Int64?
    /// 0.0 〜 1.0。分からなければ nil（UI は不定形インジケータにする）。
    var fraction: Double?
    /// 利用者にそのまま見せられる**日本語**の1行。
    var detail: String?

    init(
        stage: Stage,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        fraction: Double? = nil,
        detail: String? = nil
    ) {
        self.stage = stage
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.fraction = fraction
        self.detail = detail
    }
}
