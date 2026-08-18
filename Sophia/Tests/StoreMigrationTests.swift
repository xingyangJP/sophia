import XCTest
@testable import Sophia

/// マイグレーションの仕組みそのものを確かめる。
///
/// A3 で FTS5（FR-13）と実測値の追加列（第8.3節）を足すことが**決まっている。**
/// そのときに「既存の会話を失わずに、新しい移行だけが当たる」ことが要る。
/// **その日に初めて試すのでは遅い**ので、同じ経路をいま通しておく。
final class StoreMigrationTests: StoreTestCase {

    func testFreshDatabaseAppliesEveryRegisteredMigration() async throws {
        let store = try makeInMemoryStore()

        let applied = try await store.appliedMigrationIdentifiers()

        XCTAssertEqual(applied, SophiaMigration.allCases.map(\.rawValue))
    }

    /// 識別子は `grdb_migrations` に文字列で焼かれる。
    /// **出荷後に変えると、既存DBで同じ移行がもう一度走って壊れる。**
    /// リテラルで固定して、うっかりの改名を落とす。
    func testMigrationIdentifiersAreFrozen() {
        XCTAssertEqual(SophiaMigration.v1Initial.rawValue, "v1.initial")
        XCTAssertEqual(SophiaMigration.allCases.map(\.rawValue), ["v1.initial", "v2.userTraits"])
    }

    func testReopeningTheSameFileDoesNotReapplyMigrations() async throws {
        let url = makeTemporaryDatabaseURL()

        let first = try Store(.file(url))
        let conversationID = try await makeConversation(in: first, title: "残るはずの会話")
        try await first.appendMessage(conversationID: conversationID, role: .user, content: "ここにいる")
        let firstApplied = try await first.appliedMigrationIdentifiers()

        // 2回目のオープン。migrator は毎回走るが、適用済みは飛ばされる。
        let second = try Store(.file(url))
        let secondApplied = try await second.appliedMigrationIdentifiers()

        XCTAssertEqual(secondApplied, firstApplied)
        let messages = try await second.messages(in: conversationID)
        XCTAssertEqual(messages.map(\.content), ["ここにいる"], "再オープンで会話が消えている")
    }

    /// **A3 の予行演習。**
    ///
    /// すでに会話が入っているDBに、あとから足したマイグレーション（ここでは
    /// FTS5 の代わりに列追加）を当てる。
    ///
    /// 確かめること:
    /// 1. 新しい移行だけが走る（v1 は再実行されない）
    /// 2. 既存の会話が1文字も失われない ← VISION「原ログを完全に保持する」
    func testAdditionalMigrationRunsOnExistingDatabaseWithoutLosingData() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store, title: "移行前からある会話")
        try await store.appendMessage(
            conversationID: conversationID,
            role: .assistant,
            content: "移行しても消えない本文",
            thinking: "移行しても消えない思考",
            stats: sampleStats()
        )

        // 第8.3節が A3 で足すと決めている列のうちの1本を、そのまま足してみる。
        try await store.applyAdditionalMigrationForTesting(
            identifier: "test.v2.ttfr",
            sql: "ALTER TABLE messages ADD COLUMN ttfr_ms INTEGER"
        )

        let recorded = try await store.rawAppliedMigrationIdentifiers()
        XCTAssertEqual(Set(recorded), ["v1.initial", "v2.userTraits", "test.v2.ttfr"], "追加分だけが当たること")

        let columns = try await store.columnNames(of: "messages")
        XCTAssertEqual(columns.last, "ttfr_ms")

        let messages = try await store.messages(in: conversationID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "移行しても消えない本文")
        XCTAssertEqual(messages.first?.thinking, "移行しても消えない思考")
        XCTAssertEqual(messages.first?.recordedStats?.outputTokens, 480)
    }

    /// 版を下げたときの検知。
    ///
    /// `appliedMigrationIdentifiers()` は**このアプリが登録している移行しか返さない。**
    /// より新しい版が当てた移行はそこに現れないので、下げ戻しに気づけない。
    /// `hasBeenSupersededByNewerSchema()` がその欠落をふさいでいる。
    /// A3 で FTS5 を足したあと、古い版で開かれる状況がこれである。
    func testDetectsADatabaseWrittenByANewerVersion() async throws {
        let store = try makeInMemoryStore()
        let beforeDowngrade = try await store.hasBeenSupersededByNewerSchema()
        XCTAssertFalse(beforeDowngrade)

        // 「このアプリが知らない移行」を当てる = 新しい版が先に書いた状態
        try await store.applyAdditionalMigrationForTesting(
            identifier: "v99.fromTheFuture",
            sql: "ALTER TABLE messages ADD COLUMN from_the_future INTEGER"
        )

        let known = try await store.appliedMigrationIdentifiers()
        let superseded = try await store.hasBeenSupersededByNewerSchema()
        XCTAssertEqual(known, ["v1.initial", "v2.userTraits"], "知らない移行は一覧に出ない（だから検知が別に要る）")
        XCTAssertTrue(superseded)
    }

    /// 同じ追加移行を二度呼んでも、二度目は何もしない。
    /// これが崩れると `ALTER TABLE` が「列が重複している」で落ちる。
    func testAdditionalMigrationIsIdempotent() async throws {
        let store = try makeInMemoryStore()

        try await store.applyAdditionalMigrationForTesting(
            identifier: "test.v2.ttfr",
            sql: "ALTER TABLE messages ADD COLUMN ttfr_ms INTEGER"
        )
        try await store.applyAdditionalMigrationForTesting(
            identifier: "test.v2.ttfr",
            sql: "ALTER TABLE messages ADD COLUMN ttfr_ms INTEGER"
        )

        let applied = try await store.rawAppliedMigrationIdentifiers()
        XCTAssertEqual(applied.filter { $0 == "test.v2.ttfr" }.count, 1)
    }

    /// A3 で足すのは FTS5 の**仮想テーブル**である。
    /// 素の CREATE TABLE と経路が違う（モジュールが要る）ので、
    /// **いま使っている SQLite で fts5 が使えること**だけ先に確かめておく。
    /// ここが落ちるなら FR-13 の実装方針から見直しになる。
    func testFTS5IsAvailableForPhaseA3() async throws {
        let store = try makeInMemoryStore()

        try await store.applyAdditionalMigrationForTesting(
            identifier: "test.v2.fts5probe",
            sql: """
                CREATE VIRTUAL TABLE messages_ft USING fts5(
                  content,
                  content = 'messages',
                  content_rowid = 'rowid'
                );
                """
        )

        let tables = try await store.userTableNames()
        XCTAssertTrue(tables.contains("messages_ft"), "システムの SQLite に FTS5 が無い")
    }
}
