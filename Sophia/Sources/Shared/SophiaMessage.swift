import Foundation

/// 会話の役割。DESIGN.md 第8章の `messages.role` CHECK 制約と綴りを一致させてある
/// （A3 で GRDB に落とすとき、この rawValue がそのまま列の値になる）。
enum MessageRole: String, Sendable, Codable, CaseIterable, Equatable {
    case system
    case user
    case assistant
}

/// 推論エンジンへ渡す1発言。
///
/// ## なぜ独自型が要るのか（消してはいけない理由）
///
/// MLX の `Chat.Message` と `UserInput` は **`Sendable` ではない**
/// （MLX_SWIFT.md 第4.4節。実際にコンパイルエラーを踏んだことが記録されている）。
/// Swift 6 の strict concurrency 下でこれらを `Task` 境界を越えて渡すと
/// `sending 'input' risks causing data races` で落ちる。
///
/// **したがって層をまたぐ会話は必ずこの `SophiaMessage` で運び、
/// `Chat.Message` への変換は生成タスクの内部で行うこと。**
///
/// ## thinking を持たないのは意図的である
///
/// 過去の思考テキストをモデルへ送り返すとプリフィルが無駄に膨らむ
/// （VISION 第1因子「そもそも無駄を送らない」/ DESIGN.md 第2.2章）。
/// 「送らないこと」をコメントの注意書きではなく**型の形で保証する**ため、
/// エンジン入力用のこの型には thinking フィールドを置いていない。
///
/// 思考テキストは UI と永続化層が自分の型で保持する。
/// **ここに thinking を足さないこと。** 足した瞬間に誰かが送ってしまう。
struct SophiaMessage: Sendable, Equatable, Codable {
    var role: MessageRole
    var content: String

    init(role: MessageRole, content: String) {
        self.role = role
        self.content = content
    }

    static func system(_ content: String) -> SophiaMessage {
        SophiaMessage(role: .system, content: content)
    }

    static func user(_ content: String) -> SophiaMessage {
        SophiaMessage(role: .user, content: content)
    }

    static func assistant(_ content: String) -> SophiaMessage {
        SophiaMessage(role: .assistant, content: content)
    }
}

extension SophiaMessage {
    /// 日本語の文字数からトークン数を概算する。
    ///
    /// 校正値は BENCH_RESULTS.md / DESIGN.md 第2.2章の実測「1文字 ≒ 0.5トークン」。
    /// **正確なトークナイザではない。** 送信前に予算超過を警告するための目安であり、
    /// `GenerationStats.inputTokens` には必ずエンジンが返した実測値を入れること。
    var estimatedTokenCount: Int {
        Int(ceil(Double(content.count) * 0.5))
    }
}

extension Array where Element == SophiaMessage {
    /// 会話全体の概算トークン数。`SophiaBudget.inputTokenBudget` との比較に使う。
    var estimatedTokenCount: Int {
        reduce(0) { $0 + $1.estimatedTokenCount }
    }
}
