import Foundation
import Observation

/// **この層の入口。**選ぶ・保存する・復元する・読む、を1つにまとめたもの
/// （DESIGN.md 第16.5節の実装部分 / FR-19）。
///
/// ---
///
/// # まだ UI には結線していない
///
/// 16.7節が求める表示（会話上部のチップ、読んだ範囲の折りたたみ、
/// ツール定義に払ったトークン数）は**まだ無い。**
/// この型は `@Observable` にしてあるので、`folder` を見ればチップは作れる。
///
/// # この型が持たないもの
///
/// | 持たないもの | どこの仕事か |
/// |---|---|
/// | `idle` / `armed` / `resolving` の状態（FR-21） | 会話の状態なので `ChatViewModel` 側。**16.2節: 引き金は利用者の明示的な操作に限る** |
/// | ツールの定義と往復（`list_directory` 等） | ツール層（16.4節） |
/// | トークン上限での切り詰め・見出し・栞 | `Sources/Context/`（16.3節 第1段） |
/// | 監査ログ | **作らない。** 16.0節が「読み取りには記録する意味が無い」と決めている |
///
/// **モデルもツール呼び出しも、この型からは見えない。**
/// 見えないことがそのまま 16.6節の約束2（戻り値でアプリの状態を変えない）になっている ──
/// 変える先がここには無い。
@MainActor @Observable
final class FolderAccess {

    /// いま結び付いているフォルダ。nil なら未結合（16.2節の `idle` の前提）。
    private(set) var folder: SecurityScopedFolder?

    // `let` なので `@Observable` の追跡対象にならない。差し替えられるのは init のときだけ。
    private let bookmarks: any FolderBookmarkStoring

    init(bookmarks: any FolderBookmarkStoring = UserDefaultsFolderBookmarkStore()) {
        self.bookmarks = bookmarks
    }

    // MARK: - 選ぶ・保存する（機能1・2）

    /// 利用者にフォルダを選ばせ、権限を保存する。
    ///
    /// - Returns: 選ばれたフォルダ。**キャンセルなら nil（異常ではない）。**
    @discardableResult
    func chooseFolder() throws -> SecurityScopedFolder? {
        guard let picked = FolderPicker.chooseFolder(startingAt: folder?.url) else {
            return nil
        }
        let bound = try SecurityScopedFolder.bind(to: picked)
        folder = bound
        if let data = bound.bookmark {
            bookmarks.saveBookmark(data)
        }
        return bound
    }

    /// 結び付けを外す。**保存したブックマークも消す。**
    ///
    /// 16.8節「ブックマークが失効した → 会話から結び付けを外し、選び直しを促す」の外す側。
    /// 消さずに残すと、次回起動で同じ失敗を繰り返す。
    func forgetFolder() {
        folder = nil
        bookmarks.clearBookmark()
    }

    // MARK: - 復元（機能3）

    /// 保存しておいたフォルダを復元する。**起動時に1回。**
    ///
    /// ## 失敗しても throw しない
    ///
    /// 起動時に「前回のフォルダが見つかりません」で止めても、利用者にできることは無い。
    /// 16.8節は「**会話は続行する**」と決めている。
    /// そこで**失効したブックマークは黙って捨てて**、未結合の状態から始める。
    /// 利用者が改めて選べば済む ── そのほうが痛みが小さい。
    ///
    /// - Returns: 復元できたか。false なら未結合のまま。
    @discardableResult
    func restoreSavedFolder() -> Bool {
        guard let data = bookmarks.loadBookmark() else { return false }
        do {
            let restored = try SecurityScopedFolder.restore(bookmark: data)
            folder = restored
            // 失効していたら作り直された新しいブックマークが入っている。**保存し直す。**
            if restored.isStale, let refreshed = restored.bookmark {
                bookmarks.saveBookmark(refreshed)
            }
            return true
        } catch {
            bookmarks.clearBookmark()
            return false
        }
    }

    // MARK: - 読む（機能6）

    /// ディレクトリを一覧する。
    func list(
        _ relativePath: String = "",
        limit: Int = FolderReadLimits.entryLimit,
        includingHidden: Bool = false
    ) async throws -> DirectoryListing {
        guard let folder else { throw FolderAccessError.noFolderBound }
        return try await Self.listing(
            folder: folder,
            relativePath: relativePath,
            limit: limit,
            includingHidden: includingHidden
        )
    }

    /// ファイルを窓で読む。
    func read(
        _ relativePath: String,
        offset: Int = 1,
        limit: Int = FolderReadLimits.lineLimit
    ) async throws -> FileWindow {
        guard let folder else { throw FolderAccessError.noFolderBound }
        return try await Self.window(
            folder: folder,
            relativePath: relativePath,
            offset: offset,
            limit: limit
        )
    }

    // MARK: - 主スレッドから降りる

    // ファイルの読み取りは同期の I/O である。**主スレッドで走らせないこと。**
    // NFR-02（UI を止めない）に効くのは間引きだけではない ─
    // 数千件のディレクトリや数MBのファイルは、それだけで1フレームを軽く超える。
    //
    // `nonisolated` な async 関数は、呼び手のアクターを引き継がない（SE-0338）。
    // つまり `@MainActor` のメソッドから `await` するだけで、実行は主スレッドから降りる。
    // `Task.detached` を書く必要は無い ── 書くとキャンセルの伝播が切れる。

    private nonisolated static func listing(
        folder: SecurityScopedFolder,
        relativePath: String,
        limit: Int,
        includingHidden: Bool
    ) async throws -> DirectoryListing {
        try folder.withAccess { accessed in
            try FolderReader.list(
                accessed.resolve(relativePath),
                limit: limit,
                includingHidden: includingHidden
            )
        }
    }

    private nonisolated static func window(
        folder: SecurityScopedFolder,
        relativePath: String,
        offset: Int,
        limit: Int
    ) async throws -> FileWindow {
        try folder.withAccess { accessed in
            try FolderReader.readText(accessed.resolve(relativePath), offset: offset, limit: limit)
        }
    }
}
