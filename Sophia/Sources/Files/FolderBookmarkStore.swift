import Foundation

/// ブックマークの置き場所（機能2・3 / DESIGN.md 第16.9節 項目7）。
///
/// ## なぜ protocol にしてあるのか
///
/// **16.9節 項目7 は「どこに置くか」を未決のままにしている。**
///
/// > **ブックマークをどこに置くか。** 会話に属させる（`Store` / GRDB）か、
/// > アプリに属させるか。**会話をまたいで同じフォルダを使い回すなら、会話には属さない**
///
/// 決めきれないものを実装で固めないために、**置き場所を差し替えられる形**にしてある。
/// いまの既定は `UserDefaults`（＝アプリに属する）。理由は2つ:
///
/// 1. **16.9節 項目7 の但し書きが、そちらへ倒れている。**
///    利用者が会話ごとに同じフォルダを選び直すのは、痛みを取るどころか増やす。
/// 2. **DB のスキーマを触らずに済む。** 会話に属させると `messages` / `conversations` の
///    移行が要る（第8章）。決まっていないことのために移行を積むのは順序が逆である。
///
/// 会話に属させると決まったら、`Store` を包んだ実装をもう1つ書いて差し替える。
/// **呼び手（`FolderAccess`）は1行も変わらない。**
protocol FolderBookmarkStoring: Sendable {
    func loadBookmark() -> Data?
    func saveBookmark(_ data: Data)
    func clearBookmark()
}

/// `UserDefaults` に置く実装。**既定。**
///
/// サンドボックス下の `UserDefaults.standard` の実体は
/// `~/Library/Containers/jp.co.xerographix.sophia/Data/Library/Preferences/` の中で、
/// `SophiaDatabase.directoryURL` と同じく **OS のユーザーアカウントごとに分かれる**
/// （VISION「人の識別」）。共用機で家族が使っても混ざらない。
///
/// **ここに入るのはブックマークだけ。** パスの文字列を別に持たないこと ──
/// 2つ持つと必ずずれ、「表示は前のフォルダ、実際に読むのは新しいフォルダ」が起きる。
/// 表示に要る値は復元した URL から作る（`SecurityScopedFolder.displayName`）。
struct UserDefaultsFolderBookmarkStore: FolderBookmarkStoring, @unchecked Sendable {

    /// 逆ドメインで始める。`UserDefaults.standard` は他のフレームワークとも同居する。
    static let defaultKey = "jp.co.xerographix.sophia.files.folderBookmark"

    private let defaults: UserDefaults
    private let key: String

    /// - Note: `@unchecked Sendable` にしてあるのは `UserDefaults` がクラスだからである。
    ///   `UserDefaults` 自体はスレッド安全だと Apple が明記しているので、
    ///   ここで守るべき不変条件は無い。**「検査していない」ではなく「検査する対象が無い」。**
    init(defaults: UserDefaults = .standard, key: String = UserDefaultsFolderBookmarkStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func loadBookmark() -> Data? {
        defaults.data(forKey: key)
    }

    func saveBookmark(_ data: Data) {
        defaults.set(data, forKey: key)
    }

    func clearBookmark() {
        defaults.removeObject(forKey: key)
    }
}

/// テストとプレビュー用。**利用者の `UserDefaults` を汚さない。**
///
/// `StoreTestCase` がメモリ上の DB を既定にしているのと同じ理由である ──
/// テストはホストアプリ（`Sophia.app`）のプロセスで走るので、
/// `UserDefaults.standard` を触ると**利用者の設定を書き換える。**
final class InMemoryFolderBookmarkStore: FolderBookmarkStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: Data?

    init(initial: Data? = nil) {
        self.stored = initial
    }

    func loadBookmark() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func saveBookmark(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stored = data
    }

    func clearBookmark() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}
