import XCTest
@testable import Sophia

/// **`com.apple.security.files.bookmarks.app-scope` が要るかを実測で決める**
/// （DESIGN.md 16.9節 項目2 / 16.5節の【未確認】）。
///
/// # なぜここで測れるのか
///
/// このテストの実行ホストは **`Sophia.app` 自身**である（`TEST_HOST`）。
/// つまり `Sophia.entitlements` がそのまま効いた状態で走る ──
/// **サンドボックスの制約を、本番と同じ条件で踏める。**
///
/// entitlement が要るのに無いなら、`bookmarkData(options: .withSecurityScope)` は
/// **URL が何であれ失敗する**。要らない（または既に足りている）なら成功する。
/// **`NSOpenPanel` を出さずに答えが出るのはそのためである。**
///
/// # このテストが答えないこと
///
/// **「起動をまたいで復元できるか」は、ここでは分からない。**
/// 1回のプロセスの中でしか走らないので、確かめているのは
/// **「作れるか」と「同じプロセス内で解決できるか」**までである。
/// 起動をまたぐ復元は実機で確かめること（16.9節 項目2 は半分だけ閉じる）。
///
/// # 落ちたときに何をするか
///
/// **テストを消さないこと。** 落ちたということは
/// `Sophia.entitlements` に1行足す必要があるということで、
/// **entitlement の変更は再署名・公証に触る**（16.5節）。
/// A2 の公証確認（13.1節 項目1）と一緒に見ること。
final class SecurityScopedBookmarkProbeTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SophiaBookmarkProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    /// **セキュリティスコープ付きブックマークを作れるか。**
    ///
    /// 失敗したら、その `error` を丸ごと表示する ── **何が足りないかは
    /// エラーが言うのであって、こちらが推測することではない。**
    func testSecurityScopedBookmarksCanBeCreatedUnderTheCurrentEntitlements() throws {
        do {
            let data = try directory.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil)

            XCTAssertFalse(data.isEmpty, "空のブックマークが返った")
        } catch {
            XCTFail("""
                セキュリティスコープ付きブックマークを作れなかった。
                `com.apple.security.files.bookmarks.app-scope` が要る可能性が高い
                （DESIGN.md 16.5節 / 16.9節 項目2）。
                足すなら再署名・公証に触る点に注意すること。
                エラー: \(error)
                """)
        }
    }

    /// **作ったブックマークを、同じプロセスの中で解決できるか。**
    ///
    /// `SecurityScopedFolder.restore(bookmark:)` の実物を通す ──
    /// `URL(resolvingBookmarkData:)` を直接叩くと、
    /// **`startAccessing` の対や根の再検証という本番の手順を飛ばしてしまう。**
    func testABookmarkResolvesBackToTheSameFolderWithinOneLaunch() throws {
        let data = try directory.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)

        let restored = try SecurityScopedFolder.restore(bookmark: data)

        XCTAssertEqual(
            restored.url.resolvingSymlinksInPath().standardizedFileURL,
            directory.resolvingSymlinksInPath().standardizedFileURL)
    }
}
