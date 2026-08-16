import XCTest
@testable import Sophia

/// **DESIGN.md 第8章の生SQLと、実際にできたスキーマが一致していること**を確かめる。
///
/// 設計書が一次情報である以上（第8.1節）、このテストは
/// 「実装が設計から離れていないか」の見張りである。
/// 列を1つ足したら、設計書とここの両方が同時に変わるはずである。
/// **片方だけ変えられるなら、この見張りは働いていない。**
final class StoreSchemaTests: StoreTestCase {

    // MARK: - テーブル

    func testCreatesExactlyTheTablesFromDesignChapter8() async throws {
        let store = try makeInMemoryStore()

        let tables = try await store.userTableNames()

        XCTAssertEqual(
            tables,
            ["conversations", "messages", "model_files", "models", "profiles"],
            "第8章（+8.2節）が定めた5枚以外のテーブルができている、または足りない"
        )
    }

    // MARK: - conversations

    func testConversationsHasTheDesignedColumns() async throws {
        let store = try makeInMemoryStore()

        let columns = try await store.columnNames(of: "conversations")

        XCTAssertEqual(
            columns,
            ["id", "title", "model_id", "profile_id", "created_at", "updated_at"]
        )
    }

    func testConversationsNotNullMatchesTheDesign() async throws {
        let store = try makeInMemoryStore()

        let notNull = try await store.notNullColumnNames(of: "conversations")

        // profile_id だけが NULL 可（プロファイル未指定の会話がありうる）。
        // id は PRIMARY KEY だが SQLite の TEXT PRIMARY KEY は NOT NULL にならない。
        XCTAssertEqual(notNull, ["title", "model_id", "created_at", "updated_at"])
    }

    func testConversationsReferencesProfiles() async throws {
        let store = try makeInMemoryStore()

        let destinations = try await store.foreignKeyDestinations(of: "conversations")

        XCTAssertEqual(destinations, ["profiles"])
    }

    // MARK: - messages

    func testMessagesHasTheDesignedColumns() async throws {
        let store = try makeInMemoryStore()

        let columns = try await store.columnNames(of: "messages")

        XCTAssertEqual(
            columns,
            [
                "id", "conversation_id", "role", "content",
                // 思考は本文と**別の列**（第6章 / FR-17）。ここが1列に戻ったら設計が壊れている
                "thinking",
                "created_at",
                // FR-14 の実測値4列。VISION の測定原則における一次資料
                "input_tokens", "output_tokens", "ttft_ms", "tokens_per_sec",
            ]
        )
    }

    func testMessagesThinkingIsNullable() async throws {
        let store = try makeInMemoryStore()

        let notNull = try await store.notNullColumnNames(of: "messages")

        XCTAssertEqual(notNull, ["conversation_id", "role", "content", "created_at"])
        XCTAssertFalse(notNull.contains("thinking"), "思考モードOFFの応答が保存できなくなる")
    }

    func testMeasurementColumnsHaveTheDesignedTypes() async throws {
        let store = try makeInMemoryStore()

        let input = try await store.columnType(of: "messages", column: "input_tokens")
        let output = try await store.columnType(of: "messages", column: "output_tokens")
        let ttft = try await store.columnType(of: "messages", column: "ttft_ms")
        let rate = try await store.columnType(of: "messages", column: "tokens_per_sec")

        XCTAssertEqual(input?.uppercased(), "INTEGER")
        XCTAssertEqual(output?.uppercased(), "INTEGER")
        XCTAssertEqual(ttft?.uppercased(), "INTEGER")
        // tok/s だけが REAL。第8章のとおり
        XCTAssertEqual(rate?.uppercased(), "REAL")
    }

    func testTimestampColumnsAreIntegers() async throws {
        let store = try makeInMemoryStore()

        let messageCreatedAt = try await store.columnType(of: "messages", column: "created_at")
        let conversationCreatedAt = try await store.columnType(of: "conversations", column: "created_at")
        let conversationUpdatedAt = try await store.columnType(of: "conversations", column: "updated_at")

        XCTAssertEqual(messageCreatedAt?.uppercased(), "INTEGER")
        XCTAssertEqual(conversationCreatedAt?.uppercased(), "INTEGER")
        XCTAssertEqual(conversationUpdatedAt?.uppercased(), "INTEGER")
    }

    /// 宣言型が INTEGER でも、SQLite は文字列を平気で入れてしまう（型親和性）。
    /// **実際に書き込んだ値が整数として入っているか**を別に確かめる。
    ///
    /// GRDB の既定は `Date` を `"YYYY-MM-DD HH:MM:SS.SSS"` の文字列で書くので、
    /// `databaseDateEncodingStrategy` を外すとここが `text` に変わって落ちる。
    func testTimestampsAreActuallyStoredAsIntegers() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)
        try await store.appendMessage(conversationID: conversationID, role: .user, content: "こんにちは")

        let messageType = try await store.rawString(sql: "SELECT typeof(created_at) FROM messages")
        let conversationType = try await store.rawString(
            sql: "SELECT typeof(created_at) FROM conversations"
        )

        XCTAssertEqual(messageType, "integer")
        XCTAssertEqual(conversationType, "integer")
    }

    func testMessagesIndexCoversConversationAndCreatedAt() async throws {
        let store = try makeInMemoryStore()

        let indexes = try await store.explicitIndexes(on: "messages")

        XCTAssertEqual(
            indexes,
            ["idx_messages_conv": ["conversation_id", "created_at"]],
            "会話ごとの取得と並び順がこの索引に乗っている。名前も列順も設計どおりであること"
        )
    }

    func testMessagesReferencesConversations() async throws {
        let store = try makeInMemoryStore()

        let destinations = try await store.foreignKeyDestinations(of: "messages")

        XCTAssertEqual(destinations, ["conversations"])
    }

    // MARK: - CHECK 制約

    func testRoleCheckConstraintRejectsUnknownRole() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)

        // `MessageRole` には存在しない値なので、Swift の API 経由では作れない。
        // 制約が**DB側**に効いていることを確かめたいので生SQLで叩く。
        await assertConstraintViolation {
            try await store.executeRawForTesting(
                sql: """
                    INSERT INTO messages (id, conversation_id, role, content, created_at)
                    VALUES ('x', ?, 'tool', 'ツールの出力', 0)
                    """,
                arguments: [conversationID]
            )
        }
    }

    func testRoleCheckConstraintAcceptsAllThreeRoles() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)

        for role in MessageRole.allCases {
            try await store.appendMessage(
                conversationID: conversationID,
                role: role,
                content: "\(role.rawValue) の発言"
            )
        }

        let count = try await store.messageCount(in: conversationID)
        XCTAssertEqual(count, MessageRole.allCases.count)
    }

    func testModelStateCheckConstraintRejectsUnknownState() async throws {
        let store = try makeInMemoryStore()

        await assertConstraintViolation {
            try await store.executeRawForTesting(
                sql: """
                    INSERT INTO models (id, directory, total_bytes, state)
                    VALUES ('m', 'Models/m', 1, 'paused')
                    """
            )
        }
    }

    func testModelStateCheckConstraintAcceptsAllDeclaredStates() async throws {
        let store = try makeInMemoryStore()

        for state in ModelState.allCases {
            try await store.executeRawForTesting(
                sql: """
                    INSERT INTO models (id, directory, total_bytes, state)
                    VALUES (?, ?, 1, ?)
                    """,
                arguments: [state.rawValue, "Models/\(state.rawValue)", state.rawValue]
            )
        }

        let count = try await store.rawInt(sql: "SELECT COUNT(*) FROM models")
        XCTAssertEqual(count, ModelState.allCases.count)
    }

    // MARK: - 外部キーが本当に効いているか

    /// `Configuration.foreignKeysEnabled` を落とすと、`ON DELETE CASCADE` も
    /// この参照制約も**静かに無効になる。** 明示的に確かめる。
    func testForeignKeysAreEnforced() async throws {
        let store = try makeInMemoryStore()

        await assertConstraintViolation {
            try await store.executeRawForTesting(
                sql: """
                    INSERT INTO conversations (id, title, model_id, profile_id, created_at, updated_at)
                    VALUES ('c', '題', 'model', 'そんなプロファイルは無い', 0, 0)
                    """
            )
        }
    }

    // MARK: - 第8.2節の models 改訂

    func testModelsUsesTheRevisedDirectoryShape() async throws {
        let store = try makeInMemoryStore()

        let columns = try await store.columnNames(of: "models")

        XCTAssertEqual(
            columns,
            ["id", "directory", "total_bytes", "downloaded_bytes", "state"]
        )
        // v1.1 の GGUF 単一ファイル前提が残っていないこと（第8.2節）
        XCTAssertFalse(columns.contains("filename"))
        XCTAssertFalse(columns.contains("sha256"))
    }

    func testModelsDownloadedBytesDefaultsToZero() async throws {
        let store = try makeInMemoryStore()

        try await store.executeRawForTesting(
            sql: "INSERT INTO models (id, directory, total_bytes, state) VALUES ('m', 'd', 100, 'pending')"
        )

        let downloaded = try await store.rawInt(sql: "SELECT downloaded_bytes FROM models WHERE id = 'm'")
        XCTAssertEqual(downloaded, 0)
    }

    func testModelFilesHasCompositePrimaryKey() async throws {
        let store = try makeInMemoryStore()

        let key = try await store.primaryKeyColumns(of: "model_files")

        XCTAssertEqual(key, ["model_id", "path"])
    }

    func testModelFilesCascadeFromModels() async throws {
        let store = try makeInMemoryStore()
        try await store.executeRawForTesting(
            sql: "INSERT INTO models (id, directory, total_bytes, state) VALUES ('m', 'd', 1, 'ready')"
        )
        try await store.executeRawForTesting(
            sql: """
                INSERT INTO model_files (model_id, path, sha256, size_bytes)
                VALUES ('m', 'model.safetensors', 'abc', 1)
                """
        )

        try await store.executeRawForTesting(sql: "DELETE FROM models WHERE id = 'm'")

        let remaining = try await store.rawInt(sql: "SELECT COUNT(*) FROM model_files")
        XCTAssertEqual(remaining, 0)
    }

    // MARK: - profiles

    func testProfilesHasTheDesignedColumns() async throws {
        let store = try makeInMemoryStore()

        let columns = try await store.columnNames(of: "profiles")

        XCTAssertEqual(columns, ["id", "name", "system_prompt", "params_json"])
    }
}
