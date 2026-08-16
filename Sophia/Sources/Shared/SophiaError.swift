import Foundation

/// 利用者に見せられる形のエラー（FR-11「原因と対処を日本語で提示する」）。
///
/// Swift の enum ではなく struct にしてあるのは、
/// **UI が `code` で分岐しつつ、文言はそのまま表示できる**ようにするため。
/// `message` と `hint` は必ず日本語で、UI にそのまま出せる文にすること。
struct SophiaError: Error, Sendable, Equatable, LocalizedError {

    /// エラー種別。**増やすときは UI 担当へ知らせること**（分岐の網羅性が壊れる）。
    enum Code: String, Sendable, Equatable, CaseIterable, Codable {
        /// 推論エンジンを初期化できない（Metal 非対応機など）。
        case engineUnavailable
        /// 指定されたモデルが見つからない。
        case modelNotFound
        /// モデルの取得に失敗した（回線断・容量不足）。NFR-10 の復帰対象。
        case modelDownloadFailed
        /// モデルの読み込みに失敗した（破損・形式違い）。
        /// **GGUF を渡すとここに来る**（MLX_SWIFT.md 第2.1節）。
        case modelLoadFailed
        /// モデルが未ロードのまま生成を要求された。実装の誤り。
        case modelNotLoaded
        /// メモリが足りない。16GB機では現実的に起こる。
        case outOfMemory
        /// 入力がコンテキスト長を超えた。
        case contextOverflow
        /// 生成中に失敗した。
        case generationFailed
        /// 中断された（FR-02）。**異常ではない。** UI はエラー表示をしないこと。
        case cancelled
        /// このモデル／エンジンでは要求された機能が使えない
        /// （例: 思考モードを OFF にできないモデルに OFF を要求した）。
        case unsupported
        /// 想定外。`detail` に原文を入れる。
        case unknown
    }

    let code: Code
    /// 何が起きたか。**日本語**。UI にそのまま出す。
    let message: String
    /// どうすれば直るか。**日本語**。UI にそのまま出す。
    let hint: String?
    /// 開発者向けの原文。**UI には出さない**（ログとデバッグ表示のみ）。
    let detail: String?

    init(code: Code, message: String? = nil, hint: String? = nil, detail: String? = nil) {
        let fallback = SophiaError.defaultText(for: code)
        self.code = code
        self.message = message ?? fallback.message
        self.hint = hint ?? fallback.hint
        self.detail = detail
    }

    var errorDescription: String? { message }
    var recoverySuggestion: String? { hint }

    /// 中断は「失敗」ではない。UI の分岐で使う。
    var isCancellation: Bool { code == .cancelled }

    // MARK: - 既定の文言（FR-11）

    private static func defaultText(for code: Code) -> (message: String, hint: String?) {
        switch code {
        case .engineUnavailable:
            ("推論エンジンを開始できませんでした。",
             "Apple Silicon 搭載の Mac で、macOS 14 以降が必要です。")
        case .modelNotFound:
            ("指定されたモデルが見つかりませんでした。",
             "モデル名を確認するか、モデルを取得し直してください。")
        case .modelDownloadFailed:
            ("モデルの取得に失敗しました。",
             "ネットワークと空き容量を確認して、もう一度お試しください。途中まで取得した分から再開できます。")
        case .modelLoadFailed:
            ("モデルを読み込めませんでした。",
             "MLX 形式（safetensors）のモデルが必要です。GGUF 形式は読み込めません。")
        case .modelNotLoaded:
            ("モデルがまだ読み込まれていません。",
             "モデルの読み込みが終わってから送信してください。")
        case .outOfMemory:
            ("メモリが足りず、生成を続けられませんでした。",
             "ほかのアプリを終了するか、より小さいモデルに切り替えてください。")
        case .contextOverflow:
            ("入力が長すぎて、モデルが扱える範囲を超えました。",
             "入力を短くするか、会話を新しく始めてください。")
        case .generationFailed:
            ("応答の生成に失敗しました。",
             "もう一度送信してください。繰り返す場合は入力を短くしてお試しください。")
        case .cancelled:
            ("生成を中断しました。", nil)
        case .unsupported:
            ("この操作は、いま使っているモデルでは行えません。",
             "別のモデルに切り替えるか、設定を戻してください。")
        case .unknown:
            ("予期しないエラーが発生しました。",
             "もう一度お試しください。繰り返す場合はアプリを再起動してください。")
        }
    }

    // MARK: - 変換

    /// 任意の例外を `SophiaError` に変換する。**境界で必ず通すこと。**
    ///
    /// `CancellationError` は自動的に `.cancelled` になる。FR-02 の中断を
    /// 「エラー」として赤字表示してしまう事故を、この1か所で防いでいる。
    static func wrap(_ error: any Error, fallback: Code = .unknown) -> SophiaError {
        if let sophia = error as? SophiaError { return sophia }
        if error is CancellationError { return SophiaError(code: .cancelled) }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorCancelled { return SophiaError(code: .cancelled) }
            return SophiaError(
                code: .modelDownloadFailed,
                detail: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
            )
        }
        return SophiaError(
            code: fallback,
            detail: "\(type(of: error)): \(error.localizedDescription)"
        )
    }
}
