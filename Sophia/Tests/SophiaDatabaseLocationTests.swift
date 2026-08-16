import XCTest
@testable import Sophia

/// 保存先の経路（VISION「人の識別」）と、時刻の単位を確かめる。
final class SophiaDatabaseLocationTests: StoreTestCase {

    /// `Application Support/Sophia/sophia.db` であること。
    ///
    /// **ディレクトリを作らせずに**経路だけを見ている。
    /// テストはホストアプリのプロセスで走るので、`createDirectory: true` にすると
    /// 利用者の実データ領域を触ることになる。
    func testDefaultPathIsApplicationSupportSophiaSophiaDB() throws {
        let url = try SophiaDatabase.fileURL(createDirectory: false)

        XCTAssertEqual(url.lastPathComponent, "sophia.db")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Sophia")
        XCTAssertEqual(
            url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "Application Support"
        )
    }

    /// **これが「人 = OSユーザーアカウント」の中身である**（VISION）。
    /// パスがそのユーザーのホーム配下に収まっていること。
    /// ログイン機能を作らずに利用者が分かれるのは、この1点による。
    func testDefaultPathIsInsideTheCurrentUserHome() throws {
        let url = try SophiaDatabase.fileURL(createDirectory: false)

        XCTAssertTrue(
            url.path.hasPrefix(NSHomeDirectory()),
            "ホーム(\(NSHomeDirectory())) の外を指している: \(url.path)"
        )
    }

    /// サンドボックス下では実体がコンテナ内に落ちる（DESIGN.md 第7.1節）。
    /// テストホストは `Sophia.app` そのものなので、ここで実際の姿を記録しておく。
    /// **サンドボックスを外すとこのテストが落ちる** ─ 気づけるようにしてある。
    func testSandboxRedirectsIntoTheAppContainer() throws {
        let url = try SophiaDatabase.fileURL(createDirectory: false)

        XCTAssertTrue(
            url.path.contains("/Containers/jp.co.xerographix.sophia/"),
            "app-sandbox が効いていないか、bundle identifier が変わった: \(url.path)"
        )
    }

    func testInMemoryStoreDoesNotTouchTheFileSystem() async throws {
        let store = try makeInMemoryStore()

        let path = await store.databasePath

        XCTAssertEqual(path, ":memory:")
    }

    // MARK: - 時刻の単位

    func testTimestampsRoundTripThroughMilliseconds() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)

        let milliseconds = SophiaTimestamp.milliseconds(from: date)

        XCTAssertEqual(milliseconds, 1_700_000_000_123)
        XCTAssertEqual(
            SophiaTimestamp.date(fromMilliseconds: milliseconds).timeIntervalSince1970,
            1_700_000_000.123,
            accuracy: 0.0005
        )
    }

    func testTruncationMatchesWhatTheDatabaseKeeps() async throws {
        let store = try makeInMemoryStore()
        // ミリ秒未満を持つ時刻。DB は保持できない
        let noisy = Date(timeIntervalSince1970: 1_700_000_000.1234567)

        let conversation = try await store.createConversation(
            title: "題", modelID: "m", now: noisy)
        let fetched = try await store.conversation(id: conversation.id)

        XCTAssertEqual(fetched?.createdAt, SophiaTimestamp.truncated(noisy))
        XCTAssertNotEqual(SophiaTimestamp.truncated(noisy), noisy, "丸めが起きていない")
    }
}
