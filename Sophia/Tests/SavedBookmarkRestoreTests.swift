import XCTest

@testable import Sophia

/// **起動をまたいでフォルダを復元できるか**を、実際に保存された値で確かめる
/// （DESIGN.md 16.9節 項目2 / 16.5節の【未確認】）。
///
/// # なぜこれで答えが出るのか
///
/// 実行ホストは **`Sophia.app` 自身**なので、**アプリと同じサンドボックス容器**で走る。
/// つまり `UserDefaults.standard` の実体も同じ ──
/// **利用者が実際に選んだフォルダのブックマークがそこにある。**
///
/// そして**これは別プロセスである。** アプリを終了したあとに走らせれば、
/// 「アプリを起動し直して復元できるか」と**同じ問い**を測っていることになる。
///
/// `SecurityScopedBookmarkProbeTests` は**その場で作った**ブックマークを
/// **同じプロセス内で**解決していた。**あれでは起動をまたぐ話に答えられない。**
///
/// # 保存が無いときは skip する
///
/// **黙って緑にしないこと。** 一度もフォルダを選んでいない環境では
/// 測るものが無いので、`XCTSkip` で「測っていない」と言う。
final class SavedBookmarkRestoreTests: XCTestCase {

    /// **実際に保存されたブックマークが、別プロセスから解決できるか。**
    ///
    /// 落ちたら `com.apple.security.files.bookmarks.app-scope` が要る、が第一の疑い。
    /// **entitlement の変更は再署名・公証に触る**（16.5節 / A2 の 13.1節 項目1）。
    func testTheBookmarkSavedByTheAppResolvesInAFreshProcess() throws {
        let store = UserDefaultsFolderBookmarkStore()
        guard let data = store.loadBookmark() else {
            throw XCTSkip("""
                保存されたブックマークが無いので測れない。
                アプリでフォルダを1つ選んでから、もう一度このテストを走らせること。
                （キー: \(UserDefaultsFolderBookmarkStore.defaultKey)）
                """)
        }

        do {
            let folder = try SecurityScopedFolder.restore(bookmark: data)

            // **解決できただけでは足りない。実際に読めることまで見る。**
            // `startAccessing` が false を返しても URL は返るので、
            // 「解決できた」を「使える」と取り違えない。
            let listing = try folder.withAccess {
                try FolderReader.list($0.resolve(""), limit: 1, includingHidden: false)
            }

            print("[BOOKMARK] RESTORED path=\(folder.displayName) total=\(listing.totalCount)")
        } catch {
            XCTFail("""
                **起動をまたいだ復元に失敗した。**
                `com.apple.security.files.bookmarks.app-scope` が要る可能性が高い
                （DESIGN.md 16.5節 / 16.9節 項目2）。
                足すなら再署名・公証に触る点に注意すること。
                エラー: \(error)
                """)
        }
    }
}
