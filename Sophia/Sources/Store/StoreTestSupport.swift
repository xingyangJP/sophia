#if DEBUG
import Foundation
import GRDB

/// 単体テストがスキーマを覗くための窓。**Release ビルドには一切入らない。**
///
/// ## なぜテスト側で `import GRDB` しないのか
///
/// `SophiaTests` はホストアプリ（`Sophia.app`）に注入される unit-test bundle で、
/// GRDB はホスト側にリンクされている。テストバンドルにも GRDB を
/// リンクすると **同じ型が2つ存在する**状態になり、
/// `Database` 同士が別の型として扱われて実行時に壊れる。
/// DESIGN.md 第9.0節が MLX について警告している「二重リンク」と同じ問題である。
///
/// したがってテストは `@testable import Sophia` だけを行い、
/// GRDB の型はこのファイルで Swift の素の型へ畳んでから渡す。
extension Store {

    /// `sqlite_master` にあるテーブル名（GRDB 自身のものと SQLite 内部のものは除く）。
    func userTableNames() async throws -> [String] {
        try await rawStrings(sql: """
            SELECT name FROM sqlite_master
             WHERE type = 'table'
               AND name NOT LIKE 'sqlite_%'
               AND name <> 'grdb_migrations'
             ORDER BY name
            """)
    }

    /// 列名を、テーブル定義に書かれた順で。
    func columnNames(of table: String) async throws -> [String] {
        try await readForTesting { db in try db.columns(in: table).map(\.name) }
    }

    /// 列の宣言型（`TEXT` / `INTEGER` / `REAL`）。
    /// SQLite の版によって大文字小文字が変わりうるので、比較は大文字化してから行うこと。
    func columnType(of table: String, column: String) async throws -> String? {
        try await readForTesting { db in
            try db.columns(in: table).first { $0.name == column }?.type
        }
    }

    /// NOT NULL が付いている列名。
    func notNullColumnNames(of table: String) async throws -> [String] {
        try await readForTesting { db in
            try db.columns(in: table).filter(\.isNotNull).map(\.name)
        }
    }

    /// 主キーを構成する列名。
    func primaryKeyColumns(of table: String) async throws -> [String] {
        try await readForTesting { db in try db.primaryKey(table).columns }
    }

    /// `CREATE INDEX` で作った索引の (名前, 列) の一覧。
    /// 主キーや UNIQUE 由来の暗黙の索引は含めない。
    func explicitIndexes(on table: String) async throws -> [String: [String]] {
        try await readForTesting { db in
            var result: [String: [String]] = [:]
            for index in try db.indexes(on: table) where index.origin == .createIndex {
                result[index.name] = index.columns
            }
            return result
        }
    }

    /// 外部キーの参照先テーブル名。
    func foreignKeyDestinations(of table: String) async throws -> [String] {
        try await readForTesting { db in
            try db.foreignKeys(on: table).map(\.destinationTable).sorted()
        }
    }

    /// `sqlite_master` に残っている `CREATE TABLE` の原文。
    /// CHECK 制約が本当に付いているかを見るために使う。
    func createTableSQL(for table: String) async throws -> String? {
        try await readForTesting { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [table]
            )
        }
    }

    // MARK: - 生SQL

    /// 生SQLをそのまま流す。**エラーを `SophiaError` に包まない。**
    ///
    /// CHECK 制約や外部キー制約が効いていることを確かめるには、
    /// SQLite が返した文言そのものが要る。包むと消えてしまう。
    func executeRawForTesting(sql: String, arguments: [StoreSQLValue?] = []) throws {
        try dbQueueForTesting.write { db in
            try db.execute(sql: sql, arguments: arguments.statementArguments)
        }
    }

    func rawInt(sql: String, arguments: [StoreSQLValue?] = []) async throws -> Int? {
        try await readForTesting { db in
            try Int.fetchOne(db, sql: sql, arguments: arguments.statementArguments)
        }
    }

    func rawString(sql: String, arguments: [StoreSQLValue?] = []) async throws -> String? {
        try await readForTesting { db in
            try String.fetchOne(db, sql: sql, arguments: arguments.statementArguments)
        }
    }

    func rawStrings(sql: String, arguments: [StoreSQLValue?] = []) async throws -> [String] {
        try await readForTesting { db in
            try String.fetchAll(db, sql: sql, arguments: arguments.statementArguments)
        }
    }

    // MARK: - マイグレーションの検証

    /// 既存の（＝すでに v1 が当たっている）DBへ、**あとから足した体の
    /// マイグレーションを1本だけ**適用する。
    ///
    /// これは A3 の予行演習である。FTS5 の仮想テーブルを足すとき、
    /// 「既存の会話を失わずに、新しい移行だけが走る」ことがそこで初めて要る。
    /// **そのときに初めて確かめるのでは遅い**ので、いま同じ経路を通しておく。
    ///
    /// 中で組み立てている migrator は、本番の `SophiaMigrations.migrator` に
    /// 1本足したものと同じ形をしている。v1 は適用済みなので飛ばされる。
    func applyAdditionalMigrationForTesting(identifier: String, sql: String) throws {
        var migrator = SophiaMigrations.migrator
        migrator.registerMigration(identifier) { db in
            try db.execute(sql: sql)
        }
        try migrator.migrate(dbQueueForTesting)
    }

    /// `grdb_migrations` に入っている識別子（登録順を問わない生の集合）。
    func rawAppliedMigrationIdentifiers() async throws -> [String] {
        try await rawStrings(sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
}

/// **v1 だけが当たった状態のDB** をテストのために作る。
///
/// `Store` は開くたびに migrator を丸ごと走らせるので、`Store` 経由では
/// 「v1 までしか当たっていないDB」を作れない。**そこが検証したい状態である** ──
/// 利用者像（v2）が**既に会話の入っているDBへ後から当たる**のが、
/// 出荷後に実際に起きることだからである。
///
/// GRDB の型はここで閉じてある（テスト側は `import GRDB` しない。理由は上の型コメント）。
extension SophiaMigrations {

    /// v1 だけを当てたDBをファイルに作り、会話とメッセージを1件ずつ入れておく。
    ///
    /// - Returns: 入れた会話の id。
    static func createV1OnlyDatabaseForTesting(
        at url: URL,
        conversationTitle: String,
        messageContent: String
    ) throws -> String {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let queue = try SophiaDatabase.openQueue(at: url)

        // **本番の migrator を使わない。** v1 だけを登録した別の migrator を組む。
        var v1Only = DatabaseMigrator()
        v1Only.registerMigration(SophiaMigration.v1Initial.rawValue) { db in
            try db.execute(sql: SophiaMigrations.v1InitialSQL)
        }
        try v1Only.migrate(queue)

        let conversationID = UUID().uuidString
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations (id, title, model_id, created_at, updated_at)
                    VALUES (?, ?, 'mlx-community/Qwen3-8B-4bit', 1, 1)
                    """,
                arguments: [conversationID, conversationTitle]
            )
            try db.execute(
                sql: """
                    INSERT INTO messages (id, conversation_id, role, content, created_at)
                    VALUES (?, ?, 'user', ?, 1)
                    """,
                arguments: [UUID().uuidString, conversationID, messageContent]
            )
        }
        return conversationID
    }
}

/// テストから生SQLへ渡せる値。
///
/// `(any DatabaseValueConvertible)?` をそのまま受け取ると、GRDB の非同期 API が要求する
/// `@Sendable` クロージャに入れられない（存在型が Sendable でないため）。
/// `& Sendable` を足した別名にしておくと、`String` / `Int` / `Double` はそのまま渡せる。
typealias StoreSQLValue = any DatabaseValueConvertible & Sendable

extension Array where Element == StoreSQLValue? {
    var statementArguments: StatementArguments {
        StatementArguments(map { $0 as (any DatabaseValueConvertible)? })
    }
}
#endif
