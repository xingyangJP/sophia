import Foundation
import GRDB

/// データベースの**置き場所**と**接続の作法**だけを担当する。
///
/// スキーマは `SophiaMigrations`、問い合わせは `Store` にある。
/// ここに SQL を書かないこと。
enum SophiaDatabase {

    /// `Application Support` 直下に掘るディレクトリ名。
    static let directoryName = "Sophia"

    /// ファイル名。DESIGN.md 第3章の図に書かれている名前と一致させてある。
    static let fileName = "sophia.db"

    // MARK: - 置き場所

    /// `~/Library/Application Support/Sophia/`
    ///
    /// ## なぜここなのか（VISION「人の識別」）
    ///
    /// `.userDomainMask` は **macOS のユーザーアカウントごとに別のパスを返す。**
    /// つまり「人 = OSユーザーアカウント」の分離が、こちらが1行も書かずに成立する。
    /// 共用機で家族が使っても会話が混ざらない。**ログイン機能は要らない。**
    ///
    /// ## サンドボックス下での実体
    ///
    /// `Sophia.entitlements` で app-sandbox が有効なので、実際に返るのは
    /// `~/Library/Containers/<bundle id>/Data/Library/Application Support/Sophia/` である。
    /// **これは狙い通り。** OS がアクセス範囲を強制してくれるぶん NFR-01 が強くなる。
    /// パスを直書きして container の外を指さないこと。
    ///
    /// - Parameter createIfNeeded: true なら途中のディレクトリを作る。
    ///   **テストから経路だけを確かめたいときは false にすること**（実アプリの領域を汚さない）。
    static func directoryURL(
        createIfNeeded: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createIfNeeded
        )
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)

        if createIfNeeded, !fileManager.fileExists(atPath: directory.path) {
            // 0o700。同一機の他ユーザーから読めないようにする（NFR-01 の補強）。
            // Application Support 自体も既定でユーザー専用だが、明示しておく。
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return directory
    }

    /// `~/Library/Application Support/Sophia/sophia.db`
    static func fileURL(
        createDirectory: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        try directoryURL(createIfNeeded: createDirectory, fileManager: fileManager)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - 接続

    /// 接続設定。
    ///
    /// - Parameter walEnabled: WAL を使うか。**メモリ上のDBでは必ず false にすること。**
    ///   `PRAGMA journal_mode = WAL` が `memory` を返し、GRDB がその場で throw する
    ///   （GRDB 7.11.1 `Database.setUpWALMode()` で確認済み）。
    static func configuration(walEnabled: Bool) -> Configuration {
        var config = Configuration()

        // 既定でも true だが、**明示する。**
        // messages の `ON DELETE CASCADE` と profiles への参照制約が、
        // この1行に丸ごとぶら下がっている。false にすると静かに壊れる。
        config.foreignKeysEnabled = true

        if walEnabled {
            // ## なぜ DatabaseQueue のまま WAL にするのか
            //
            // DESIGN.md 第3.1節が「生成中も逐次 DB へ書く」を、
            // プロセス分離を失った代償の対策に据えている。つまり書き込みは
            // **1応答あたり数十回**走る前提である。
            //
            // 既定の journal（delete）では毎回 fsync が2回入る。
            // WAL にすると GRDB が併せて `synchronous = NORMAL` も設定するため
            // （`setUpWALMode()`）、コミットのたびの fsync が消える。
            //
            // 代償は「電源断で直近のトランザクションを失いうる」こと。
            // ただし第3.1節が守りたいのは **プロセスの異常終了**（MLX/Metal のクラッシュ）で、
            // WAL + NORMAL はそちらは完全に守る。狙いと代償が噛み合っている。
            //
            // 並行読み取りのために DatabasePool へ移る話とは別。第8.1節の
            // 「A1 の負荷では DatabasePool は要らない」はそのまま有効である。
            config.journalMode = .wal
        }

        // 同じDBを掴んだ別プロセス（デバッガ、テスト実行中のアプリ本体）と
        // かち合ったときに即エラーで落とさない。既定は .immediateError。
        config.busyMode = .timeout(5)

        config.label = fileName

        // ⚠ `config.publicStatementArguments = true` を**入れないこと。**
        // 有効にすると SQL の引数、すなわち **会話本文と思考テキストがログに出る。**
        // NFR-01（会話は端末の外に出さない）はログ経由の流出も含む。
        // DEBUG でも入れない。

        return config
    }

    /// ファイル上のDBを開く。マイグレーションは行わない（`Store` の仕事）。
    static func openQueue(at url: URL) throws -> DatabaseQueue {
        try DatabaseQueue(path: url.path, configuration: configuration(walEnabled: true))
    }

    /// メモリ上のDBを開く。テストとプレビュー用。
    ///
    /// - Parameter name: nil なら他から一切見えない独立したDB。
    ///   名前を付けると同名の接続どうしで共有される。
    static func openInMemoryQueue(named name: String?) throws -> DatabaseQueue {
        try DatabaseQueue(named: name, configuration: configuration(walEnabled: false))
    }
}
