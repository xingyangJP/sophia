import Foundation
import GRDB

/// `messages.role` の CHECK 制約（`'system','user','assistant'`）は
/// `MessageRole` の rawValue とそのまま一致する。
///
/// `RawValue` が `String`（= `DatabaseValueConvertible`）なので、GRDB が
/// 変換を丸ごと用意してくれる。**この空の宣言1行で足りる**
/// （GRDB 7.11.1 `DatabaseValueConvertible+RawRepresentable.swift`）。
///
/// `MessageRole` 自体は `Sources/Shared/` にあり、基盤担当の持ち物である。
/// ここで足しているのは Store 層の適合宣言だけで、向こうのファイルは触っていない。
extension MessageRole: DatabaseValueConvertible {}

/// `messages` テーブルの1行（DESIGN.md 第8章）。
///
/// ## 本文と思考を別の列に持つ理由
///
/// TUNING.md / VISION の実測で、**思考モードはトークン予算の約9割を食う。**
/// 同じ列に混ぜると、
///
/// 1. 表示のたびに `<think>` を切り出し直すことになる（FR-17 は分けて出すのが要件）
/// 2. 「思考が本文の何倍流れたか」を後から SQL で数えられなくなる
/// 3. 履歴をモデルへ送り返すときに、思考まで一緒に送ってしまう事故が起きる
///
/// 3 が最も高くつく。VISION 第1因子「そもそも無駄を送らない」に正面から反する。
/// **列で分けることが、その事故を構造的に防いでいる。**
struct MessageRecord: Codable, Sendable, Equatable, Identifiable,
                      FetchableRecord, PersistableRecord {

    static let databaseTableName = "messages"

    var id: String
    var conversationID: String

    /// CHECK 制約つき。`system` / `user` / `assistant` のみ。
    var role: MessageRole

    /// 応答本文。**要約で上書きしないこと**（第8.4節 / VISION）。
    var content: String

    /// 思考テキスト（FR-17）。`<think>` タグは**含めない**（剥がした中身だけ）。
    /// 思考モードOFF、または user / system の発言では nil。
    var thinking: String?

    var createdAt: Date

    // MARK: - FR-14 の実測値
    //
    // 第8章が定めた4列。**ベンチ（合成プロンプト）ではなく実利用の値**が入る。
    // VISION「当面の指針」1 の「測ることを続ける」の一次資料はこの4列である。
    // assistant 以外の行では nil。

    var inputTokens: Int?
    var outputTokens: Int?

    /// **整数ミリ秒。** `GenerationStats.ttftMs` は `Double` だが、
    /// 第8章の列が `INTEGER` なので四捨五入して入れる。
    /// 小数以下の精度を必要とする比較はここではなく BENCH の生ログでやること。
    var ttftMs: Int?

    var tokensPerSec: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case role
        case content
        case thinking
        case createdAt = "created_at"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case ttftMs = "ttft_ms"
        case tokensPerSec = "tokens_per_sec"
    }

    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .millisecondsSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .millisecondsSince1970
    }

    init(
        id: String = UUID().uuidString,
        conversationID: String,
        role: MessageRole,
        content: String,
        thinking: String? = nil,
        createdAt: Date = Date(),
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        ttftMs: Int? = nil,
        tokensPerSec: Double? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.thinking = thinking
        self.createdAt = createdAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.ttftMs = ttftMs
        self.tokensPerSec = tokensPerSec
    }
}

// MARK: - GenerationStats との変換（第8.1節「変換を1か所に集める」）

extension MessageRecord {

    /// `GenerationStats`（4.6節）から、v1 スキーマが持つ4列だけを取り出して埋める。
    ///
    /// ## ⚠ ここで11個の実測値が捨てられている
    ///
    /// `GenerationStats` は必須4項目のほかに、以下を持っている。
    /// **v1 のスキーマに列が無いため、保存されずに消える。**
    ///
    /// | 捨てている値 | 何が測れなくなるか |
    /// |---|---|
    /// | `ttfrMs` | 思考モードのコストそのもの（`ttftMs` との差） |
    /// | `prefillSeconds` / `prefillTokensPerSecond` | プリフィル速度。BENCH の 148 tok/s と比較する値 |
    /// | `decodeSeconds` / `totalMs` | 内訳 |
    /// | `thinkingTokens` | 「思考が予算の9割」の継続監視 |
    /// | `stopReason` | FR-02 の中断がどれだけ起きているか |
    /// | `thinkingEnabled` | 思考ON/OFFの実コスト差（VISION の適応度） |
    /// | `peakMemoryBytes` | ページングとの相関。速度の外れ値を説明する唯一の値 |
    /// | `modelID` | 会話単位でしか分からない（`conversations.model_id`） |
    ///
    /// これは**設計どおり**である。第8.3節が「A3 の永続化で列を追加する」と決めている。
    /// ただし VISION の測定原則からすると、**A3 まで実利用のログが取れない期間ができる。**
    /// A3 のマイグレーション（`SophiaMigration.v3ExtendedStats`）を早めるかは判断が要る。
    mutating func apply(_ stats: GenerationStats) {
        inputTokens = stats.inputTokens
        outputTokens = stats.outputTokens
        ttftMs = Int(stats.ttftMs.rounded())
        tokensPerSec = stats.tokensPerSecond
    }

    /// 保存されている実測値。4列すべてが埋まっているときだけ返る。
    ///
    /// ## なぜ `GenerationStats` を復元しないのか
    ///
    /// 復元すると、保存していない11項目が既定値（`stopReason: .completed` など）で
    /// 埋まる。**計測していない値が「計測した値」の顔をして出てくる**ことになり、
    /// VISION の測定原則に反する。**記録の欠落は型として見えているべき**なので、
    /// 4値だけを持つ別の型にしてある。
    var recordedStats: RecordedStats? {
        guard let inputTokens, let outputTokens, let ttftMs, let tokensPerSec else {
            return nil
        }
        return RecordedStats(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            ttftMs: ttftMs,
            tokensPerSecond: tokensPerSec
        )
    }
}

/// DB に実際に保存されている実測値（v1 スキーマの4列ぶん）。
struct RecordedStats: Sendable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    /// 整数ミリ秒。
    var ttftMs: Int
    var tokensPerSecond: Double
}

// MARK: - SophiaMessage との変換

extension MessageRecord {

    /// 推論エンジンへ渡す形（`SophiaMessage`）に落とす。
    ///
    /// ## thinking はここで確実に落ちる
    ///
    /// `SophiaMessage` には thinking のフィールドが**そもそも無い**（Shared 層の設計）。
    /// つまりこの変換を通した時点で、過去の思考テキストがモデルへ送られる経路は消える。
    /// VISION 第1因子「そもそも無駄を送らない」を、注意書きではなく型で守っている。
    ///
    /// **履歴をエンジンへ渡すときは必ずこの変換を通すこと。**
    /// `MessageRecord` を自前で読み替えて `content + thinking` を組み立てないこと。
    var asSophiaMessage: SophiaMessage {
        SophiaMessage(role: role, content: content)
    }
}
