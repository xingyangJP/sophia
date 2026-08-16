import XCTest
@testable import Sophia

/// A1 スコープのリポジトリ API（会話の作成・メッセージ追加・取得）。
final class StoreRepositoryTests: StoreTestCase {

    // MARK: - 会話

    func testCreateAndFetchConversation() async throws {
        let store = try makeInMemoryStore()

        let created = try await store.createConversation(
            title: "はじめての会話",
            modelID: "mlx-community/Qwen3-8B-4bit"
        )
        let fetched = try await store.conversation(id: created.id)

        XCTAssertEqual(fetched?.id, created.id)
        XCTAssertEqual(fetched?.title, "はじめての会話")
        XCTAssertEqual(fetched?.modelID, "mlx-community/Qwen3-8B-4bit")
        XCTAssertNil(fetched?.profileID)
        // ミリ秒に丸めたうえで往復すること
        XCTAssertEqual(fetched?.createdAt, created.createdAt)
        XCTAssertEqual(fetched?.updatedAt, created.createdAt, "作成直後は updated_at = created_at")
    }

    func testFetchingUnknownConversationReturnsNil() async throws {
        let store = try makeInMemoryStore()

        let fetched = try await store.conversation(id: "そんなIDは無い")

        XCTAssertNil(fetched)
    }

    func testConversationsAreOrderedByMostRecentlyUpdated() async throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let old = try await store.createConversation(
            title: "古い", modelID: "m", now: base)
        let new = try await store.createConversation(
            title: "新しい", modelID: "m", now: base.addingTimeInterval(60))

        var titles = try await store.conversations().map(\.title)
        XCTAssertEqual(titles, ["新しい", "古い"])

        // 古いほうに発言を足すと、並びが入れ替わる
        try await store.appendMessage(
            conversationID: old.id, role: .user, content: "掘り起こし",
            now: base.addingTimeInterval(120)
        )

        titles = try await store.conversations().map(\.title)
        XCTAssertEqual(titles, ["古い", "新しい"])
        XCTAssertEqual(new.title, "新しい")
    }

    func testConversationsRespectsLimit() async throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<5 {
            try await store.createConversation(
                title: "会話\(index)", modelID: "m",
                now: base.addingTimeInterval(Double(index))
            )
        }

        let limited = try await store.conversations(limit: 2)

        XCTAssertEqual(limited.map(\.title), ["会話4", "会話3"])
    }

    func testRenameConversationUpdatesTitleAndTimestamp() async throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let conversation = try await store.createConversation(
            title: "無題", modelID: "m", now: base)

        try await store.renameConversation(
            id: conversation.id, title: "MLX の話", now: base.addingTimeInterval(30))

        let fetched = try await store.conversation(id: conversation.id)
        XCTAssertEqual(fetched?.title, "MLX の話")
        XCTAssertEqual(fetched?.updatedAt, SophiaTimestamp.truncated(base.addingTimeInterval(30)))
    }

    func testDeleteConversationCascadesToItsMessages() async throws {
        let store = try makeInMemoryStore()
        let keptID = try await makeConversation(in: store, title: "残すほう")
        let doomedID = try await makeConversation(in: store, title: "消すほう")
        try await store.appendMessage(conversationID: keptID, role: .user, content: "残る")
        try await store.appendMessage(conversationID: doomedID, role: .user, content: "消える")
        try await store.appendMessage(conversationID: doomedID, role: .assistant, content: "これも消える")

        try await store.deleteConversation(id: doomedID)

        let conversations = try await store.conversationCount()
        let doomedMessages = try await store.messageCount(in: doomedID)
        let keptMessages = try await store.messageCount(in: keptID)
        XCTAssertEqual(conversations, 1)
        XCTAssertEqual(doomedMessages, 0, "ON DELETE CASCADE が効いていない")
        XCTAssertEqual(keptMessages, 1, "無関係の会話を巻き込んでいる")
    }

    // MARK: - メッセージ

    func testAppendAndFetchMessagesInOrder() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try await store.appendMessage(
            conversationID: conversationID, role: .system, content: "あなたは助手です",
            now: base)
        try await store.appendMessage(
            conversationID: conversationID, role: .user, content: "こんにちは",
            now: base.addingTimeInterval(1))
        try await store.appendMessage(
            conversationID: conversationID, role: .assistant, content: "こんにちは。",
            now: base.addingTimeInterval(2))

        let messages = try await store.messages(in: conversationID)

        XCTAssertEqual(messages.map(\.role), [.system, .user, .assistant])
        XCTAssertEqual(messages.map(\.content), ["あなたは助手です", "こんにちは", "こんにちは。"])
    }

    /// 同じミリ秒に入った発言でも、並びが挿入順で安定すること。
    /// `ORDER BY created_at, rowid` の `rowid` が効いているかを見ている。
    func testMessagesWithTheSameTimestampKeepInsertionOrder() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)
        let sameInstant = Date(timeIntervalSince1970: 1_700_000_000)

        try await store.appendMessage(
            conversationID: conversationID, role: .user, content: "先", now: sameInstant)
        try await store.appendMessage(
            conversationID: conversationID, role: .assistant, content: "後", now: sameInstant)

        let messages = try await store.messages(in: conversationID)

        XCTAssertEqual(messages.map(\.content), ["先", "後"])
    }

    func testMessagesOfOtherConversationsAreNotReturned() async throws {
        let store = try makeInMemoryStore()
        let a = try await makeConversation(in: store, title: "A")
        let b = try await makeConversation(in: store, title: "B")
        try await store.appendMessage(conversationID: a, role: .user, content: "Aの発言")
        try await store.appendMessage(conversationID: b, role: .user, content: "Bの発言")

        let messages = try await store.messages(in: a)

        XCTAssertEqual(messages.map(\.content), ["Aの発言"])
    }

    func testAppendingAMessageBumpsTheConversationTimestamp() async throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let conversation = try await store.createConversation(
            title: "題", modelID: "m", now: base)

        try await store.appendMessage(
            conversationID: conversation.id, role: .user, content: "あとから",
            now: base.addingTimeInterval(90))

        let fetched = try await store.conversation(id: conversation.id)
        XCTAssertEqual(fetched?.createdAt, SophiaTimestamp.truncated(base), "created_at は動かないこと")
        XCTAssertEqual(fetched?.updatedAt, SophiaTimestamp.truncated(base.addingTimeInterval(90)))
    }

    func testAppendingToAnUnknownConversationFails() async throws {
        let store = try makeInMemoryStore()

        do {
            try await store.appendMessage(
                conversationID: "存在しない会話", role: .user, content: "宛先なし")
            XCTFail("外部キー制約で失敗するはず")
        } catch let error as SophiaError {
            XCTAssertEqual(error.message, "会話を保存できませんでした。")
            XCTAssertNotNil(error.detail)
        }
    }

    // MARK: - 思考テキストの分離（FR-17 / VISION 第1因子）

    func testThinkingIsStoredInItsOwnColumn() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)

        try await store.appendMessage(
            conversationID: conversationID,
            role: .assistant,
            content: "答えは42です。",
            thinking: "まず前提を整理する。次に……"
        )

        let messages = try await store.messages(in: conversationID)
        XCTAssertEqual(messages.first?.content, "答えは42です。")
        XCTAssertEqual(messages.first?.thinking, "まず前提を整理する。次に……")
        // 混ざっていないこと。content 側に思考が漏れていたらここで落ちる
        XCTAssertFalse(messages.first?.content.contains("前提を整理") ?? true)
    }

    func testUserMessagesHaveNoThinking() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)

        try await store.appendMessage(conversationID: conversationID, role: .user, content: "問い")

        let messages = try await store.messages(in: conversationID)
        XCTAssertNil(messages.first?.thinking)
    }

    /// **このテストが VISION 第1因子の防波堤である。**
    ///
    /// 保存した思考テキストが、次のターンでモデルへ送り返されないこと。
    /// 思考は本文の約10倍流れるので、送り返すとプリフィルが跳ね上がる。
    func testHistoryNeverCarriesThinkingBackToTheEngine() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)
        try await store.appendMessage(conversationID: conversationID, role: .user, content: "問い")
        try await store.appendMessage(
            conversationID: conversationID,
            role: .assistant,
            content: "答え",
            thinking: "長い長い思考テキスト。これがプリフィルを膨らませる。"
        )

        let history = try await store.history(in: conversationID)

        XCTAssertEqual(history, [.user("問い"), .assistant("答え")])
        XCTAssertFalse(
            history.contains { $0.content.contains("長い長い思考") },
            "思考テキストがエンジンへの入力に混ざっている"
        )
    }

    func testHistoryCanExcludeTheSystemPrompt() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.appendMessage(
            conversationID: conversationID, role: .system, content: "役割", now: base)
        try await store.appendMessage(
            conversationID: conversationID, role: .user, content: "問い",
            now: base.addingTimeInterval(1))

        let withSystem = try await store.history(in: conversationID)
        let withoutSystem = try await store.history(in: conversationID, includingSystem: false)

        XCTAssertEqual(withSystem.map(\.role), [.system, .user])
        XCTAssertEqual(withoutSystem.map(\.role), [.user])
    }

    // MARK: - 実測値（FR-14）

    func testMeasurementsRoundTrip() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)
        let stats = sampleStats(ttftMs: 412.7, tokensPerSecond: 12.8, inputTokens: 312, outputTokens: 480)

        try await store.appendMessage(
            conversationID: conversationID, role: .assistant, content: "答え", stats: stats)

        let recorded = try await store.messages(in: conversationID).first?.recordedStats
        XCTAssertEqual(recorded?.inputTokens, 312)
        XCTAssertEqual(recorded?.outputTokens, 480)
        XCTAssertEqual(recorded?.ttftMs, 413, "第8章の ttft_ms は INTEGER。四捨五入して入る")
        XCTAssertEqual(recorded?.tokensPerSecond ?? 0, 12.8, accuracy: 0.0001)
    }

    /// v1 スキーマは `GenerationStats` の4項目しか持たない（第8.3節が A3 と決めている）。
    /// **捨てていることを、テストとして明示しておく。**
    /// A3 で列を足したらこのテストが「落ちるべき」テストになる。
    func testMeasurementsBeyondTheFourColumnsAreNotPersistedYet() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)
        try await store.appendMessage(
            conversationID: conversationID, role: .assistant, content: "答え", stats: sampleStats())

        let columns = try await store.columnNames(of: "messages")

        for missing in ["ttfr_ms", "prompt_tokens_per_sec", "thinking_chars",
                        "stop_reason", "thinking_enabled", "peak_memory_bytes"] {
            XCTAssertFalse(
                columns.contains(missing),
                "\(missing) の列ができている。A3 に入ったなら SophiaMigration とこのテストを更新すること"
            )
        }
    }

    func testMeasurementsAreAbsentWhenNotProvided() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)

        try await store.appendMessage(conversationID: conversationID, role: .user, content: "問い")

        let message = try await store.messages(in: conversationID).first
        XCTAssertNil(message?.recordedStats)
        XCTAssertNil(message?.ttftMs)
        XCTAssertNil(message?.tokensPerSec)
    }

    // MARK: - 生成中の逐次書き込み（第3.1節 / FR-02）

    func testStreamingWriteKeepsPartialOutput() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)

        let placeholder = try await store.beginAssistantMessage(conversationID: conversationID)
        let empty = try await store.message(id: placeholder.id)?.content
        XCTAssertEqual(empty, "")

        try await store.updateAssistantMessage(
            id: placeholder.id, content: "途中まで", thinking: "考えている途中")

        let midway = try await store.message(id: placeholder.id)
        XCTAssertEqual(midway?.content, "途中まで")
        XCTAssertEqual(midway?.thinking, "考えている途中")
    }

    /// **FR-02「中断しても既出力は消えない」の永続化側。**
    ///
    /// 中断ではストリームが `.done` を出さずに終端しうるので、`stats` は nil で来る。
    /// そのとき実測値は入らないが、**本文と思考は必ず残る。**
    func testFinishWithoutStatsStillKeepsTheText() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)
        let placeholder = try await store.beginAssistantMessage(conversationID: conversationID)
        try await store.updateAssistantMessage(
            id: placeholder.id, content: "ここまで出た", thinking: "ここまで考えた")

        try await store.finishAssistantMessage(
            id: placeholder.id, content: "ここまで出た", thinking: "ここまで考えた", stats: nil)

        let saved = try await store.message(id: placeholder.id)
        XCTAssertEqual(saved?.content, "ここまで出た")
        XCTAssertEqual(saved?.thinking, "ここまで考えた")
        XCTAssertNil(saved?.recordedStats, "計測できていない値を捏造しないこと")
    }

    func testFinishWithStatsRecordsMeasurementsAndTouchesConversation() async throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let conversation = try await store.createConversation(title: "題", modelID: "m", now: base)
        let placeholder = try await store.beginAssistantMessage(
            conversationID: conversation.id, now: base.addingTimeInterval(1))

        try await store.finishAssistantMessage(
            id: placeholder.id,
            content: "完成した本文",
            thinking: nil,
            stats: sampleStats(ttftMs: 999.4, tokensPerSecond: 9.1, inputTokens: 100, outputTokens: 200),
            now: base.addingTimeInterval(40)
        )

        let saved = try await store.message(id: placeholder.id)
        XCTAssertEqual(saved?.content, "完成した本文")
        XCTAssertEqual(saved?.recordedStats,
                       RecordedStats(inputTokens: 100, outputTokens: 200,
                                     ttftMs: 999, tokensPerSecond: 9.1))

        let refreshed = try await store.conversation(id: conversation.id)
        XCTAssertEqual(refreshed?.updatedAt, SophiaTimestamp.truncated(base.addingTimeInterval(40)))
    }

    /// 生成 Task がキャンセルされた状態でも保存が完遂すること。
    ///
    /// GRDB の**非同期** write は Task のキャンセルで `CancellationError` を投げて
    /// 書き込みを取り消す。`Store` が同期 write を使っているのはそのためで、
    /// このテストはその選択が効いていることを確かめている。
    /// ここが落ちたら FR-02「既出力は消えない」が破れている。
    func testWritesSucceedEvenInsideACancelledTask() async throws {
        let store = try makeInMemoryStore()
        let conversationID = try await makeConversation(in: store)

        let task = Task {
            // 自分自身をキャンセルしてから書く
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertTrue(Task.isCancelled)
            try await store.appendMessage(
                conversationID: conversationID, role: .assistant, content: "中断されたが残る本文")
        }
        _ = try await task.value

        // 読み取り側はキャンセルされていない別の文脈から確認する
        let messages = try await store.messages(in: conversationID)
        XCTAssertEqual(messages.map(\.content), ["中断されたが残る本文"])
    }

    // MARK: - 永続性

    func testDataSurvivesReopeningTheDatabaseFile() async throws {
        let url = makeTemporaryDatabaseURL()
        let conversationID: String
        do {
            let store = try Store(.file(url))
            conversationID = try await makeConversation(in: store, title: "閉じても残る")
            try await store.appendMessage(
                conversationID: conversationID,
                role: .assistant,
                content: "本文",
                thinking: "思考",
                stats: sampleStats()
            )
        }

        let reopened = try Store(.file(url))

        let count = try await reopened.conversationCount()
        XCTAssertEqual(count, 1)
        let messages = try await reopened.messages(in: conversationID)
        XCTAssertEqual(messages.first?.content, "本文")
        XCTAssertEqual(messages.first?.thinking, "思考")
        XCTAssertEqual(messages.first?.recordedStats?.inputTokens, 312)
    }

    func testFileDatabaseIsCreatedAtTheGivenPath() async throws {
        let url = makeTemporaryDatabaseURL()

        let store = try Store(.file(url))
        try await makeConversation(in: store)

        let path = await store.databasePath
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(path, url.path)
    }
}
