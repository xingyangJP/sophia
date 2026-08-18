import Foundation
import GRDB

/// 永続化の失敗を `SophiaError`（FR-11「原因と対処を日本語で提示する」）へ変換する。
///
/// ## `code` が `.unknown` になっている件
///
/// `SophiaError.Code`（`Sources/Shared/SophiaError.swift`）に**保存失敗に当たる
/// ケースが無い。** あそこは基盤担当の持ち物で、こちらから列挙子を足せない。
/// いまは `message` / `hint` に日本語を入れて `.unknown` を使っているため、
/// **UI は「保存の失敗」だけを特別扱いする分岐が書けない。**
///
/// A2 までに `SophiaError.Code` へ `.storageFailed` を足してもらうこと。
/// 足りたらこのファイルの `code:` を差し替えるだけで済む（文言はここに揃えてある）。
///
/// ## detail に会話本文は入らない
///
/// GRDB の `DatabaseError.description` は、`publicStatementArguments` が false の間
/// **SQL の引数を出さない**（7.11.1 で確認）。既定は false で、
/// `SophiaDatabase.configuration` でも有効化していない。
/// したがって `detail` にログの中身（本文・思考テキスト）は混ざらない。NFR-01。
enum StoreFailure {

    static func open(_ error: any Error) -> SophiaError {
        SophiaError(
            code: .unknown,
            message: "会話の保存先を開けませんでした。",
            hint: "ディスクの空き容量を確認して、アプリを再起動してください。",
            detail: describe(error)
        )
    }

    static func migrate(_ error: any Error) -> SophiaError {
        SophiaError(
            code: .unknown,
            message: "会話履歴の形式を更新できませんでした。",
            hint: "アプリを再起動してください。繰り返す場合は、"
                + "このバージョンより新しいアプリで作られた履歴の可能性があります。",
            detail: describe(error)
        )
    }

    static func read(_ error: any Error) -> SophiaError {
        // 読み取りは非同期で、Task のキャンセルで `CancellationError` が飛ぶ。
        // これは異常ではないので、赤字のエラー表示にしない（FR-02 と同じ扱い）。
        if error is CancellationError { return SophiaError(code: .cancelled) }
        if let sophia = error as? SophiaError { return sophia }

        return SophiaError(
            code: .unknown,
            message: "会話履歴を読み込めませんでした。",
            hint: "アプリを再起動してください。",
            detail: describe(error)
        )
    }

    static func write(_ error: any Error) -> SophiaError {
        // **すでに利用者向けの文言になっているものを包み直さない。**
        // `Store.write` はトランザクションの本体から出た例外を一律ここへ通すので、
        // 包み直すと `traitNotFound` / `placementIsDerived` が
        // 「会話を保存できませんでした」に化けて、**原因が消える。**
        if let sophia = error as? SophiaError { return sophia }

        return SophiaError(
            code: .unknown,
            message: "会話を保存できませんでした。",
            hint: "ディスクの空き容量を確認してください。"
                + "表示されている内容はこのウィンドウを閉じるまで残ります。",
            detail: describe(error)
        )
    }

    // MARK: - 利用者像（14.14節）

    /// 存在しない利用者像を訂正・強化しようとした。**実装の誤りである。**
    ///
    /// 利用者から見える形にはならないはずなので、文言は最小限にしてある。
    static func traitNotFound(id: String) -> SophiaError {
        SophiaError(
            code: .unknown,
            message: "その情報は見つかりませんでした。",
            hint: "すでに削除されている可能性があります。設定画面を開き直してください。",
            detail: "user_traits に id=\(id) が無い"
        )
    }

    /// `placement` を `translating` に**手で**書こうとした。
    ///
    /// ## なぜ弾くのか
    ///
    /// `translating`（＝翻訳役の重みに入っている）は**事実であって、意思ではない。**
    /// `user_trait_bakes` と、そのアダプタ世代が有効かどうかから導出される。
    /// 手で書けるようにすると、**重みに入っていない像が「入っている」と表示されうる。**
    /// 14.15節が設定画面へ出すと決めている「いま重みに入っている像の一覧」が嘘になり、
    /// **嘘をつく方向が最悪である** ── 消したはずの像が残っているのを見逃す側に倒れる。
    static func placementIsDerived(id: String) -> SophiaError {
        SophiaError(
            code: .unknown,
            message: "この状態は直接変更できません。",
            hint: "重みに反映されているかどうかは、学習の記録から自動的に決まります。",
            detail: "user_traits.placement = 'translating' は user_trait_bakes からの導出値である"
                + "（id=\(id)）。recordAdapterGeneration / activateAdapterGeneration を使うこと"
        )
    }

    /// `localizedDescription` を使わないこと。
    /// `DatabaseError` は `LocalizedError` ではないため、
    /// 「The operation couldn't be completed.」という中身の無い文字列になる。
    /// `String(describing:)` なら SQLite のエラーコードと SQL 文が残る。
    private static func describe(_ error: any Error) -> String {
        "\(type(of: error)): \(String(describing: error))"
    }
}
