import Foundation
import GRDB

/// 会話履歴の永続化（DESIGN.md 第8章）。
///
/// ## なぜ actor か（第3章 / 第8.1節）
///
/// SQLite の書き込みは単一直列である。`@MainActor` から直接触ると
/// I/O のたびに UI が止まる（NFR-02）。`actor` に包むことで、
/// 呼び出し側は `await` するだけで済み、直列化はこちらが引き受ける。
///
/// ## 書き込みは同期、読み取りは非同期（**意図的な非対称**）
///
/// GRDB 7 の `await dbQueue.write {}` は **Task がキャンセルされると
/// `CancellationError` を投げて書き込みを取り消す**
/// （`SerializedDatabase.execute` の `withTaskCancellationHandler`。7.11.1 で確認）。
///
/// **実測（2026-08-16）**: キャンセル済み Task から非同期 write で1行 INSERT すると、
/// `CancellationError` が投げられ、**行は0件のまま**だった。
/// 同期 write に替えた同じ手順では行が残る
/// （`StoreRepositoryTests.testWritesSucceedEvenInsideACancelledTask`）。
///
/// これは FR-02 と正面から衝突する。
/// 中断ボタンで生成 Task を畳んだ瞬間に、**それまでに出た本文の保存が巻き戻る。**
/// 「既出力は消えない」が破れる。
///
/// 同期版 `dbQueue.write {}` はキャンセルを一切見ない。したがって
///
/// | 操作 | 使う API | 理由 |
/// |---|---|---|
/// | 書き込み | **同期** `write` | 中断されても保存を完遂する（FR-02 / 第3.1節） |
/// | 読み取り | 非同期 `read` | 取り消されて困らない。スレッドを塞がない |
///
/// 同期書き込みは協調スレッドを数十マイクロ秒ふさぐ。WAL + `synchronous = NORMAL`
/// （`SophiaDatabase.configuration`）で commit ごとの fsync が消えているため、
/// この長さで収まっている。**設定を戻すとこの前提も崩れる。**
actor Store {

    /// DBの置き場所。
    enum Location: Sendable, Equatable {
        /// `~/Library/Application Support/Sophia/sophia.db`。**製品の既定。**
        case applicationSupport
        /// 任意のファイル。テストと診断用。
        case file(URL)
        /// メモリ上。テストとプレビュー用。プロセスが終われば消える。
        case inMemory(name: String?)
    }

    nonisolated let location: Location
    private let dbQueue: DatabaseQueue

    // MARK: - 生成

    /// 開いて、必要なマイグレーションを適用する。
    ///
    /// **同期。** 呼び出し元が `@MainActor` なら `Store.open(_:)` を使うこと。
    init(_ location: Location = .applicationSupport) throws {
        self.location = location
        self.dbQueue = try Self.makeQueue(for: location)

        do {
            try SophiaMigrations.migrator.migrate(dbQueue)
        } catch {
            throw StoreFailure.migrate(error)
        }
    }

    /// `@MainActor` から呼ぶための入口。ファイルを開く I/O を主スレッドの外へ出す。
    ///
    /// 起動時にこれを `await` しても、DESIGN.md 第3.3節の「ウィンドウを出す前に
    /// 待たない」に反しない ─ ここで待つのはモデル（秒単位）ではなく、
    /// テーブルが5枚できるだけの時間である。
    static func open(_ location: Location = .applicationSupport) async throws -> Store {
        try await Task.detached(priority: .userInitiated) {
            try Store(location)
        }.value
    }

    private static func makeQueue(for location: Location) throws -> DatabaseQueue {
        do {
            switch location {
            case .applicationSupport:
                let url = try SophiaDatabase.fileURL(createDirectory: true)
                return try SophiaDatabase.openQueue(at: url)

            case .file(let url):
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                return try SophiaDatabase.openQueue(at: url)

            case .inMemory(let name):
                return try SophiaDatabase.openInMemoryQueue(named: name)
            }
        } catch {
            throw StoreFailure.open(error)
        }
    }

    // MARK: - 診断

    /// 実際に開いているファイルのパス。メモリ上のDBでは `:memory:` などが返る。
    var databasePath: String { dbQueue.path }

    /// 適用済みのマイグレーション識別子（登録順）。
    ///
    /// 起動ログに出す想定。**利用者のDBがどの版のスキーマなのかを、
    /// 推測ではなく事実として確認できるようにしておく。**
    ///
    /// ⚠ **`SophiaMigrations` に登録されているものしか返らない。**
    /// このアプリが知らない移行（＝より新しい版が当てたもの）は現れない。
    /// そちらを知りたいときは `hasBeenSupersededByNewerSchema()` を使うこと。
    func appliedMigrationIdentifiers() async throws -> [String] {
        try await read { db in try SophiaMigrations.migrator.appliedMigrations(db) }
    }

    /// **このアプリより新しい版が、同じDBを先に書き換えていないか。**
    ///
    /// 起こりうる筋書きは版の下げ戻しである。新しい版で A3 の FTS5 を当てたあと、
    /// 古い版のアプリで開くと、こちらが知らない列やテーブルの上に書き込むことになる。
    /// 黙って動くと**壊れ方が分かりにくい**ので、起動時にここを見て
    /// 読み取り専用にするか警告を出すこと。
    ///
    /// A1 では移行が1本しかないため常に false になる。**A3 以降で意味を持つ。**
    func hasBeenSupersededByNewerSchema() async throws -> Bool {
        try await read { db in try SophiaMigrations.migrator.hasBeenSuperseded(db) }
    }

    // MARK: - 会話

    /// 会話を1件作る。
    @discardableResult
    func createConversation(
        title: String,
        modelID: String,
        profileID: String? = nil,
        id: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> ConversationRecord {
        let record = ConversationRecord(
            id: id,
            title: title,
            modelID: modelID,
            profileID: profileID,
            createdAt: SophiaTimestamp.truncated(now)
        )
        try write { db in try record.insert(db) }
        return record
    }

    func conversation(id: String) async throws -> ConversationRecord? {
        try await read { db in
            try ConversationRecord.fetchOne(
                db,
                sql: "SELECT * FROM conversations WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// 一覧（FR-12）。**最近使った順。**
    ///
    /// 同じミリ秒に更新された会話が並んだときのために `id` を第2キーにしてある。
    /// 順序が実行のたびに変わると、UI の差分更新がちらつく。
    func conversations(limit: Int? = nil) async throws -> [ConversationRecord] {
        let sql = """
            SELECT * FROM conversations
            ORDER BY updated_at DESC, id DESC
            \(limit == nil ? "" : "LIMIT \(limit!)")
            """
        return try await read { db in try ConversationRecord.fetchAll(db, sql: sql) }
    }

    func conversationCount() async throws -> Int {
        try await read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0
        }
    }

    func renameConversation(id: String, title: String, now: Date = Date()) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE conversations SET title = ?, updated_at = ? WHERE id = ?",
                arguments: [title, SophiaTimestamp.milliseconds(from: now), id]
            )
        }
    }

    /// 会話とそのメッセージを消す。
    ///
    /// メッセージ側は `ON DELETE CASCADE` に任せている。**手で消さないこと。**
    /// 手続きを二重に持つと、片方だけ直したときに孤児行が残る。
    func deleteConversation(id: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - メッセージ

    /// 発言を1件足し、会話の `updated_at` を同じトランザクションで進める。
    ///
    /// 2文に分けないのは、**片方だけ成功した状態を作らない**ため。
    /// 一覧の並び順（`updated_at`）と中身がずれると、利用者からは
    /// 「保存されていない」ように見える。
    @discardableResult
    func appendMessage(
        conversationID: String,
        role: MessageRole,
        content: String,
        thinking: String? = nil,
        stats: GenerationStats? = nil,
        id: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> MessageRecord {
        var record = MessageRecord(
            id: id,
            conversationID: conversationID,
            role: role,
            content: content,
            thinking: thinking,
            createdAt: SophiaTimestamp.truncated(now)
        )
        if let stats { record.apply(stats) }

        let touched = record
        try write { db in
            try touched.insert(db)
            try Self.touchConversation(db, id: conversationID, at: touched.createdAt)
        }
        return record
    }

    /// 会話のメッセージを**表示順**で返す。
    ///
    /// `ORDER BY created_at, rowid` の `rowid` は保険である。
    /// ミリ秒が同着になったとき（1往復の user と assistant は起こりうる）に
    /// 挿入順へ落とす。これが無いと並びが不定になり、再描画のたびに入れ替わる。
    func messages(in conversationID: String) async throws -> [MessageRecord] {
        try await read { db in
            try MessageRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages
                    WHERE conversation_id = ?
                    ORDER BY created_at, rowid
                    """,
                arguments: [conversationID]
            )
        }
    }

    func message(id: String) async throws -> MessageRecord? {
        try await read { db in
            try MessageRecord.fetchOne(
                db,
                sql: "SELECT * FROM messages WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func messageCount(in conversationID: String) async throws -> Int {
        try await read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages WHERE conversation_id = ?",
                arguments: [conversationID]
            ) ?? 0
        }
    }

    /// 推論エンジンへ渡す履歴。
    ///
    /// ## ここが「思考を送り返さない」ことの担保である
    ///
    /// 戻り値は `SophiaMessage` の配列で、この型には thinking のフィールドが無い。
    /// つまり **DB に残っている思考テキストは、この関数を通った時点で必ず落ちる。**
    /// VISION 第1因子「そもそも無駄を送らない」を型で守っている
    /// （思考は本文の約10倍流れるので、送り返すとプリフィルが跳ね上がる）。
    ///
    /// **エンジンへ渡す履歴は必ずここから取ること。**
    /// `messages(in:)` の結果を自前で変換しないこと。
    func history(in conversationID: String, includingSystem: Bool = true) async throws -> [SophiaMessage] {
        let records = try await messages(in: conversationID)
        return records
            .filter { includingSystem || $0.role != .system }
            .map(\.asSophiaMessage)
    }

    // MARK: - 生成中の逐次書き込み（第3.1節 / 第12章リスク13 / FR-02）

    /// 空の assistant 行を先に作る。
    ///
    /// DESIGN.md 第3.1節が、推論を別プロセスに置かなくなった代償として
    /// 「会話は生成中も逐次 DB へ書く」を対策に据えている。
    /// **MLX / Metal が落ちてアプリごと道連れになっても、
    /// ここまで書けたぶんは残る**というのがその意味である。
    ///
    /// 併せて FR-02（中断しても既出力は消えない）も同じ仕組みで満たす。
    @discardableResult
    func beginAssistantMessage(
        conversationID: String,
        id: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> MessageRecord {
        try appendMessage(
            conversationID: conversationID,
            role: .assistant,
            content: "",
            id: id,
            now: now
        )
    }

    /// 生成中の途中経過を上書きする。
    ///
    /// ## 呼ぶ間隔について
    ///
    /// **1トークンごとに呼ばないこと。** 実測 7〜13 tok/s なので毎回でも
    /// 秒間十数回だが、それでも計測（FR-14）に乗る雑音になる。
    /// UI 側が 16ms でまとめているのと同様に、**0.5〜1秒に1回**で足りる。
    /// 守りたいのは「クラッシュしても直近だけしか失わない」ことであって、
    /// 1トークンの粒度ではない。
    func updateAssistantMessage(id: String, content: String, thinking: String?) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE messages SET content = ?, thinking = ? WHERE id = ?",
                arguments: [content, thinking, id]
            )
        }
    }

    /// 生成の終わりに、本文・思考・実測値を確定させる。
    ///
    /// **`stats` は nil を許す。** 中断（FR-02）ではストリームが `.done` を
    /// 出さずに終端しうるからである（既出の申し送り事項4）。
    /// そのとき実測値は入らないが、**本文と思考は必ず残る。**
    func finishAssistantMessage(
        id: String,
        content: String,
        thinking: String?,
        stats: GenerationStats?,
        now: Date = Date()
    ) throws {
        let ttft = stats.map { Int($0.ttftMs.rounded()) }
        try write { db in
            try db.execute(
                sql: """
                    UPDATE messages
                       SET content = ?, thinking = ?,
                           input_tokens = ?, output_tokens = ?,
                           ttft_ms = ?, tokens_per_sec = ?
                     WHERE id = ?
                    """,
                arguments: [
                    content, thinking,
                    stats?.inputTokens, stats?.outputTokens,
                    ttft, stats?.tokensPerSecond,
                    id,
                ]
            )
            // 会話の並び順を、応答が終わった時刻へ進める。
            if let conversationID = try String.fetchOne(
                db,
                sql: "SELECT conversation_id FROM messages WHERE id = ?",
                arguments: [id]
            ) {
                try Self.touchConversation(db, id: conversationID, at: now)
            }
        }
    }

    // MARK: - 内部

    private static func touchConversation(_ db: Database, id: String, at date: Date) throws {
        try db.execute(
            sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
            arguments: [SophiaTimestamp.milliseconds(from: date), id]
        )
    }

    // ⚠ `write` / `read` は `private` を外してある（`internal`）。
    //
    // 利用者像の API（14.14節）は `UserTraitsStore.swift` にあり、
    // `extension Store` として別ファイルに置いた。Swift の `private` はファイル単位なので、
    // そのままでは下の2つが見えない。**`dbQueue` 自体は private のまま**であり、
    // トランザクション境界と `StoreFailure` への変換はこの2つに集まったままである。
    // **`dbQueue` を直接触る道は（DEBUG の窓を除いて）開けていない。**

    /// 書き込み。**同期。キャンセルを見ない**（型の説明を参照）。
    func write<T>(_ body: (Database) throws -> T) throws -> T {
        do {
            return try dbQueue.write(body)
        } catch {
            throw StoreFailure.write(error)
        }
    }

    /// 読み取り。非同期。取り消されうる。
    func read<T: Sendable>(
        _ body: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        do {
            return try await dbQueue.read(body)
        } catch {
            throw StoreFailure.read(error)
        }
    }

    // MARK: - テスト用の窓
    //
    // `dbQueue` は private のままにしたいが、`StoreTestSupport.swift` は別ファイルなので
    // 見えない。ここに DEBUG 限定の口だけを開ける。**Release には残らない。**
    #if DEBUG
    var dbQueueForTesting: DatabaseQueue { dbQueue }

    /// エラーを `SophiaError` に包まずにそのまま投げる読み取り。
    /// 制約違反の文言を検証するのに要る。
    func readForTesting<T: Sendable>(
        _ body: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        try await dbQueue.read(body)
    }
    #endif
}
