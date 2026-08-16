import Foundation
import GRDB

/// `conversations` テーブルの1行（DESIGN.md 第8章）。
///
/// 列名は Swift 側の命名（`modelID`）と違うので `CodingKeys` で明示的に対応させる。
/// GRDB の `convertToSnakeCase` に任せていない理由は、**生SQLが一次情報**だからである
/// （第8.1節）。自動変換は規則を覚えていないと列名が読めなくなる。
struct ConversationRecord: Codable, Sendable, Equatable, Identifiable,
                           FetchableRecord, PersistableRecord {

    static let databaseTableName = "conversations"

    /// UUID 文字列。呼び出し側が決める（`Store.createConversation` が既定で振る）。
    var id: String

    /// 一覧に出す題名（FR-12）。A1 では最初の発言から作る想定。
    var title: String

    /// この会話で使ったモデル。例 `mlx-community/Qwen3-8B-4bit`。
    ///
    /// **`models` テーブルへの外部キーにはなっていない**（第8章の生SQLどおり）。
    /// モデルを削除しても過去の会話の記録が消えないほうが、VISION の
    /// 「原ログを完全に保持する」に沿う。
    var modelID: String

    /// 役割プロファイル（FR-05）。`profiles(id)` を参照する。未指定なら nil。
    var profileID: String?

    var createdAt: Date

    /// 最終更新。一覧の並び順に使う。**メッセージを足したら必ず更新する。**
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case modelID = "model_id"
        case profileID = "profile_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // 第8章の `created_at INTEGER` を守る。詳細は SophiaTimestamp を読むこと。
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .millisecondsSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .millisecondsSince1970
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        modelID: String,
        profileID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.modelID = modelID
        self.profileID = profileID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}
