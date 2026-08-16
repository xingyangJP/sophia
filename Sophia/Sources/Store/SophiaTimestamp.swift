import Foundation

/// DESIGN.md 第8章が `created_at` / `updated_at` を `INTEGER` とだけ決めていて、
/// **単位を書いていない。** ここで確定させ、以後この1か所だけを参照する。
///
/// ## 単位は「Unixエポックからのミリ秒」
///
/// 秒にしなかった理由は並び順である。`idx_messages_conv` は
/// `(conversation_id, created_at)` で、メッセージの表示順そのものに使われる。
/// 1往復の user と assistant は**同じ秒に入りうる**ため、秒精度だと並びが不定になる。
///
/// ミリ秒でも理論上は衝突しうるので、取得側は `ORDER BY created_at, rowid` と書き、
/// 挿入順を最後の保険にしている（`Store.messages(in:)`）。
///
/// ## Date を直に入れないこと
///
/// GRDB の既定は `Date` を `"YYYY-MM-DD HH:MM:SS.SSS"` の**文字列**で書く。
/// そのまま使うと第8章の `INTEGER` に文字列が入り、スキーマと実装がずれる。
/// レコード型が `databaseDateEncodingStrategy(for:)` で
/// `.millisecondsSince1970` を返しているのはこのためである。
enum SophiaTimestamp {

    static func milliseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(fromMilliseconds milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// DB に入れたときと同じ精度まで丸めた `Date`。
    ///
    /// 保存して読み戻すとミリ秒未満が落ちるので、`Date()` をそのまま比較すると
    /// 一致しない。**期待値を作るときはこれを通すこと。**
    static func truncated(_ date: Date) -> Date {
        // `Self.` が要る。素の `date(...)` は引数名 `date` に隠れて型 `Date` に解決される。
        Self.date(fromMilliseconds: Self.milliseconds(from: date))
    }
}
