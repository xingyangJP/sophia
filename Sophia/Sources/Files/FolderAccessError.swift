import Foundation

/// フォルダ参照（FR-19 / DESIGN.md 第16章）で起こりうる失敗。
///
/// ## なぜ `SophiaError` を直接投げないのか
///
/// **この層の失敗には、宛先が2つある。**
///
/// | 宛先 | 何を出すか | 根拠 |
/// |---|---|---|
/// | 利用者（UI） | `sophiaError` ── 日本語で原因と対処 | FR-11 |
/// | **モデル**（ツールの戻り値） | `modelMessage` ── 何が駄目で、次に何を試せるか | **16.8節** |
///
/// 16.8節は「ルート外のパスを要求された → **実行せず、その旨をツールの戻り値としてモデルに返す。
/// 往復を1回で打ち切らない**」と決めている。つまり**失敗のいくつかは、
/// 利用者に見せる「エラー」ではなく、モデルへの返答である。**
/// `SophiaError` だけを投げると、この区別が呼び手の側で消える。
///
/// だから**種別を保った enum をこの層の内部通貨にし**、境界で
/// `sophiaError` / `modelMessage` のどちらかへ変換する。
///
/// ## `sophiaError` の `code` が `.unknown` になっている件
///
/// `SophiaError.Code`（`Sources/Shared/SophiaError.swift`）に
/// **ファイル参照に当たるケースが1つも無い。** `StoreFailure` が
/// `.storageFailed` を待っているのと同じ事情である。
///
/// **A2 までに `.folderAccessDenied` と `.folderUnavailable` を足してもらうこと。**
/// 足りたらここの `code:` を差し替えるだけで済むよう、文言はこのファイルに集めてある。
/// いまは `.unknown` なので、**UI は「フォルダの失効」だけを特別扱いする分岐が書けない**
/// （16.8節が求める「結び付けを外して選び直しを促す」を、UI 側で自動化できない）。
///
/// ## `detail` に読んだ中身は入れない
///
/// この enum の payload はパス・バイト数・errno だけである。
/// **ファイルの中身は1バイトも入れないこと。** ログへ出る値であり、
/// NFR-01（会話を端末の外に出さない）はログ経由の流出も含む
/// （`SophiaDatabase.configuration` の `publicStatementArguments` と同じ考え方）。
enum FolderAccessError: Error, Sendable, Equatable {

    // MARK: - 封じ込め（16.5節）

    /// 絶対パスを渡された。**16.4節「絶対パスを受け取らない」。**
    case absolutePathRejected(String)

    /// `~` 始まりを渡された。展開すれば必ずルート外を指す。
    case homeRelativePathRejected(String)

    /// `..` を含んでいた。**16.5節の手順1〜3は `..` があっても正しく落とすが、
    /// その手前でも落とす**（多層防御。理由は `FolderContainment` を読むこと）。
    case parentTraversalRejected(String)

    /// パスとして扱えない文字列（NUL を含む等）。
    case invalidPath(String)

    /// **解決した結果がルートの外だった。この層の存在理由。**
    ///
    /// - Parameters:
    ///   - requested: モデルが書いてきた相対パス（原文）
    ///   - resolved: シンボリックリンクを解いた後の絶対パス。
    ///     **利用者に見せるならこちら**（16.6節の但し書き ── 引数のまま見せると、
    ///     リンクで逃げた先を承認させることになる）。
    case outsideRoot(requested: String, resolved: String)

    // MARK: - 根の状態（16.8節）

    /// 結び付いたフォルダが無い。`idle`（16.2節）のまま呼ばれた。実装の誤り。
    case noFolderBound

    /// ルートが見つからない（移動・削除・改名された）。
    case rootUnavailable(String)

    /// ルートがディレクトリではない。
    case rootNotADirectory(String)

    /// **アクセス中にルートの実体が入れ替わった。**
    /// 結び付けた時に解決した絶対パスと、いま解決した絶対パスが食い違う。
    case rootMoved(expected: String, actual: String)

    /// ブックマークを解決できない（形式違い・別の機体で作られた等）。
    case bookmarkUnreadable(detail: String)

    /// ブックマークを作れない。
    case bookmarkCreationFailed(detail: String)

    /// `startAccessingSecurityScopedResource()` が false を返し、
    /// **実際に読めもしなかった。** 16.8節「黙って読めないまま進まないこと」。
    case accessDenied(String)

    // MARK: - 読み取り（16.8節）

    case notFound(String)
    case notADirectory(String)
    case notAFile(String)

    /// テキストではない。16.8節「読まない。種別とサイズだけ返す」。
    case binaryFile(path: String, totalBytes: Int)

    /// **大きすぎるので開かない。**
    ///
    /// 総行数を正しく数えるには最後まで走査する必要がある（`FileWindow.totalLines`）。
    /// 青天井にすると `read_file` 1回でアプリが数秒固まるので、上端を切ってある
    /// （`FolderReadLimits.maximumFileBytes`）。
    case fileTooLarge(path: String, totalBytes: Int)

    /// UTF-8 として読めない（Shift_JIS など）。
    case notUTF8(String)

    /// **検証の後、開くまでの間にパスが差し替わった疑い**（`O_NOFOLLOW` が ELOOP を返した）。
    case pathChangedDuringAccess(String)

    case ioFailed(path: String, detail: String)

    // MARK: - 利用者へ（FR-11）

    /// UI にそのまま出せる形。**message / hint は必ず日本語で、原因と対処を対にする。**
    var sophiaError: SophiaError {
        switch self {
        case .absolutePathRejected(let path):
            make("許可されたフォルダの外を指すパスが要求されました。",
                 "この会話に結び付けたフォルダの中だけを参照できます。",
                 "absolute path rejected: \(path)")

        case .homeRelativePathRejected(let path):
            make("許可されたフォルダの外を指すパスが要求されました。",
                 "この会話に結び付けたフォルダの中だけを参照できます。",
                 "home-relative path rejected: \(path)")

        case .parentTraversalRejected(let path):
            make("許可されたフォルダの外を指すパスが要求されました。",
                 "この会話に結び付けたフォルダの中だけを参照できます。",
                 "parent traversal rejected: \(path)")

        case .invalidPath(let path):
            make("パスとして扱えない文字が含まれていました。",
                 "ファイル名を確認してください。",
                 "invalid path: \(path)")

        case .outsideRoot(let requested, let resolved):
            // **解決後のパスを message に出す。** 16.6節の但し書きのとおり、
            // 引数のまま見せるとリンクで逃げた先が隠れる。
            make("許可したフォルダの外（\(resolved)）を読もうとしたため、中止しました。",
                 "参照できるのは結び付けたフォルダの中だけです。"
                 + "外のフォルダを読ませたい場合は、そのフォルダを選び直してください。",
                 "outside root: requested=\(requested) resolved=\(resolved)")

        case .noFolderBound:
            make("参照するフォルダがまだ選ばれていません。",
                 "この会話にフォルダを結び付けてから、もう一度お試しください。",
                 "no folder bound")

        case .rootUnavailable(let path):
            make("結び付けたフォルダが見つかりませんでした。",
                 "移動・削除・改名されたようです。フォルダを選び直してください。",
                 "root unavailable: \(path)")

        case .rootNotADirectory(let path):
            make("結び付けたものがフォルダではありませんでした。",
                 "フォルダを選び直してください。",
                 "root is not a directory: \(path)")

        case .rootMoved(let expected, let actual):
            make("結び付けたフォルダの場所が変わりました。",
                 "安全のため参照を中止しました。フォルダを選び直してください。",
                 "root moved: expected=\(expected) actual=\(actual)")

        case .bookmarkUnreadable(let detail):
            make("前回選んだフォルダへのアクセス権を復元できませんでした。",
                 "フォルダを選び直してください。会話はそのまま続けられます。",
                 "bookmark unreadable: \(detail)")

        case .bookmarkCreationFailed(let detail):
            make("選んだフォルダへのアクセス権を保存できませんでした。",
                 "この会話の間は参照できますが、次回起動時に選び直しが必要です。",
                 "bookmark creation failed: \(detail)")

        case .accessDenied(let path):
            make("フォルダを読む権限がありませんでした。",
                 "フォルダを選び直してください。会話はそのまま続けられます。",
                 "access denied: \(path)")

        case .notFound(let path):
            make("ファイルが見つかりませんでした（\(path)）。",
                 "フォルダの中身を一覧してから、もう一度指定してください。",
                 "not found: \(path)")

        case .notADirectory(let path):
            make("フォルダではありません（\(path)）。",
                 "一覧できるのはフォルダだけです。",
                 "not a directory: \(path)")

        case .notAFile(let path):
            make("読み取れるファイルではありません（\(path)）。",
                 "通常のテキストファイルを指定してください。",
                 "not a regular file: \(path)")

        case .binaryFile(let path, let totalBytes):
            make("テキストではないファイルのため、内容を読みませんでした（\(path)）。",
                 "サイズは \(totalBytes) バイトです。テキストファイルを指定してください。",
                 "binary file: \(path) bytes=\(totalBytes)")

        case .fileTooLarge(let path, let totalBytes):
            make("ファイルが大きすぎるため、内容を読みませんでした（\(path)）。",
                 "サイズは \(totalBytes) バイトです。"
                 + "小さいファイルを指定するか、必要な部分だけを別ファイルに切り出してください。",
                 "file too large: \(path) bytes=\(totalBytes)")

        case .notUTF8(let path):
            make("UTF-8 として読めないファイルでした（\(path)）。",
                 "文字コードを UTF-8 に変換してからお試しください。",
                 "not utf-8: \(path)")

        case .pathChangedDuringAccess(let path):
            make("読み取りの直前にファイルの実体が変わったため、中止しました（\(path)）。",
                 "もう一度お試しください。",
                 "path changed during access (ELOOP): \(path)")

        case .ioFailed(let path, let detail):
            make("ファイルを読めませんでした（\(path)）。",
                 "ファイルが使用中でないかを確認して、もう一度お試しください。",
                 "io failed: \(path) \(detail)")
        }
    }

    private func make(_ message: String, _ hint: String, _ detail: String) -> SophiaError {
        // `code` は `.unknown` 固定。型コメントの但し書きを読むこと。
        SophiaError(code: .unknown, message: message, hint: hint, detail: detail)
    }

    // MARK: - モデルへ（16.8節）

    /// **ツールの戻り値としてモデルに返す文。**
    ///
    /// 16.8節「往復を1回で打ち切らない」ため、**次に何を試せるかまで書く。**
    /// 「駄目でした」だけを返すと、モデルは同じ呼び出しを繰り返すか、
    /// 読めていないのに読んだ体で答えを書く。
    ///
    /// > **解決後の絶対パスをここに書かないこと。**
    /// > 16.6節の約束1（アクセス範囲をファイルの中身で広げない）と同じ理由で、
    /// > **ルートの外に何があるかをモデルに教える必要が無い。**
    /// > 利用者向けの `sophiaError` には出す ── 見張るのは人間の仕事だからである。
    var modelMessage: String {
        switch self {
        case .absolutePathRejected, .homeRelativePathRejected, .parentTraversalRejected:
            "拒否: 参照できるのは結び付けられたフォルダの中だけです。"
            + "そのフォルダを起点とする相対パス（例: notes.md、docs/仕様.md）で指定してください。"

        case .invalidPath:
            "拒否: パスとして扱えない文字が含まれています。ファイル名を確認してください。"

        case .outsideRoot:
            "拒否: 指定されたパスは、結び付けられたフォルダの外を指しています（リンクの追跡結果を含む）。"
            + "フォルダの中のパスを指定してください。"

        case .noFolderBound:
            "拒否: いまこの会話にフォルダは結び付けられていません。"

        case .rootUnavailable, .rootNotADirectory, .rootMoved, .bookmarkUnreadable, .accessDenied:
            "失敗: 結び付けられたフォルダにアクセスできなくなりました。"
            + "利用者がフォルダを選び直すまで、ファイルは読めません。"
            + "推測で内容を補わず、その旨を伝えてください。"

        case .bookmarkCreationFailed:
            "失敗: フォルダへのアクセス権を保存できませんでした。"

        case .notFound(let path):
            "失敗: \(path) は見つかりません。フォルダの一覧を取ってから指定し直してください。"

        case .notADirectory(let path):
            "失敗: \(path) はフォルダではありません。一覧できるのはフォルダだけです。"

        case .notAFile(let path):
            "失敗: \(path) は通常のファイルではありません。"

        case .binaryFile(let path, let totalBytes):
            "失敗: \(path) はテキストではないため読みませんでした（\(totalBytes) バイト）。"
            + "内容は不明として扱ってください。"

        case .fileTooLarge(let path, let totalBytes):
            "失敗: \(path) は大きすぎるため読みませんでした（\(totalBytes) バイト）。"
            + "内容は不明として扱ってください。"

        case .notUTF8(let path):
            "失敗: \(path) は UTF-8 として読めませんでした。内容は不明として扱ってください。"

        case .pathChangedDuringAccess(let path):
            "失敗: \(path) を開く直前に実体が変わりました。もう一度試すことはできます。"

        case .ioFailed(let path, _):
            "失敗: \(path) を読めませんでした。内容は不明として扱ってください。"
        }
    }
}
