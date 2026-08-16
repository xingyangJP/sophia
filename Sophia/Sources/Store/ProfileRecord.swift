import Foundation
import GRDB

/// `profiles` テーブルの1行（DESIGN.md 第8章）。
///
/// `modelfiles/*.Modelfile` に相当する。役割の切替（FR-05）。
///
/// **A1 ではまだ誰も書き込まない。** スキーマだけ先に作ってあるのは、
/// `conversations.profile_id` が参照制約でここにぶら下がっているためである。
/// 後からテーブルを足すと `conversations` の作り直しが要る。
struct ProfileRecord: Codable, Sendable, Equatable, Identifiable,
                      FetchableRecord, PersistableRecord {

    static let databaseTableName = "profiles"

    var id: String

    /// 利用者に見せる名前。例「相談相手」「コード書き」。
    var name: String

    /// このプロファイルで先頭に差し込む system 発言。
    var systemPrompt: String

    /// 温度・コンテキスト長などの JSON 文字列。
    ///
    /// **列として展開せず JSON のまま持つのは第8章の決定である。**
    /// 調整可能な項目は TUNING.md の実測で増減するため、
    /// 増えるたびにマイグレーションを打つ構造にしたくない。
    var paramsJSON: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case systemPrompt = "system_prompt"
        case paramsJSON = "params_json"
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        systemPrompt: String,
        paramsJSON: String = "{}"
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.paramsJSON = paramsJSON
    }
}
