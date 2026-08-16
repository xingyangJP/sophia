import Foundation
import XCTest
@testable import Sophia

/// 自己認識（FR-21）が**本当にエンジンまで届いているか**。
///
/// システムプロンプトは「入れたつもりで入っていない」が起きやすい。
/// `engineMessages()` は送信経路と表示経路の両方から呼ばれるので、
/// 片方だけに効いている状態を目視で見つけるのは難しい。
/// ここではエンジンに実際に渡った配列を捕まえて確かめる。
@MainActor
final class SystemPromptTests: XCTestCase {

    /// 渡された会話を記録するだけのエンジン。生成はすぐ終わる。
    ///
    /// `chat` は `nonisolated` なので actor には入れられない。
    /// テスト内でしか使わず、記録は錠で守る。
    final class RecordingEngine: InferenceEngine, @unchecked Sendable {

        nonisolated let identifier: EngineIdentifier = .stub

        private let lock = NSLock()
        private var _received: [[SophiaMessage]] = []

        /// エンジンが受け取った会話の履歴（送信1回につき1件）。
        var received: [[SophiaMessage]] {
            lock.lock(); defer { lock.unlock() }
            return _received
        }

        func loadedModel() async -> ModelInfo? { nil }

        func capabilities() async -> EngineCapabilities {
            EngineCapabilities(
                supportsThinking: true,
                canDisableThinking: true,
                maxContextLength: SophiaDefaults.contextLength,
                reportsPrefillProgress: false,
                reportsExactTokenCounts: false
            )
        }

        func availableModels() async throws -> [ModelInfo] { [] }

        nonisolated func load(_ modelID: String)
            -> AsyncThrowingStream<LoadProgress, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func unload() async {}

        nonisolated func chat(
            _ messages: [SophiaMessage],
            options: ChatOptions
        ) -> AsyncThrowingStream<Chunk, any Error> {
            lock.lock()
            _received.append(messages)
            lock.unlock()
            return AsyncThrowingStream { continuation in
                continuation.yield(.content("ok"))
                continuation.finish()
            }
        }
    }

    private func makeModel() -> (ChatViewModel, RecordingEngine) {
        let engine = RecordingEngine()
        return (ChatViewModel(engine: engine), engine)
    }

    /// 送信すると、**会話の先頭に** system が1件だけ乗ってエンジンへ届くこと。
    func testSystemPromptReachesTheEngineAtTheHead() async {
        let (model, engine) = makeModel()
        model.systemPromptEnabled = true
        model.input = "こんにちは"
        model.send()

        await settle()

        let sent = try! XCTUnwrap(engine.received.first)
        XCTAssertEqual(sent.first?.role, .system, "先頭が system ではない")
        XCTAssertEqual(sent.first?.content, SophiaDefaults.systemPrompt)
        XCTAssertEqual(sent.filter { $0.role == .system }.count, 1, "system が重複している")
        XCTAssertEqual(sent.last, .user("こんにちは"))
    }

    /// 切れること。**切れないと素の性能を測り続けられない**（NFR-03 / VISION の適応度関数）。
    func testSystemPromptCanBeTurnedOff() async {
        let (model, engine) = makeModel()
        model.systemPromptEnabled = false
        model.input = "こんにちは"
        model.send()

        await settle()

        let sent = try! XCTUnwrap(engine.received.first)
        XCTAssertFalse(sent.contains { $0.role == .system }, "OFF なのに system が送られている")
        XCTAssertEqual(sent.first, .user("こんにちは"))
    }

    /// **画面に出るトークン数が、実際に送る量と一致すること。**
    ///
    /// `send()` 側だけに system を足すと、入力欄の予算警告が実送信より少ない嘘になる。
    /// VISION の測定原則（無駄が痛みとして見えないと誰も減らさない）を最初に破るのがこの形なので、
    /// 「トグルするとトークン計がその場で動く」ことをテストで縛っておく。
    func testCostIsVisibleInTheTokenEstimate() {
        let (model, _) = makeModel()

        model.systemPromptEnabled = false
        let withoutSystem = model.estimatedInputTokens

        model.systemPromptEnabled = true
        let withSystem = model.estimatedInputTokens

        let expected = [SophiaMessage.system(SophiaDefaults.systemPrompt)].estimatedTokenCount
        XCTAssertEqual(withSystem - withoutSystem, expected,
                       "自己認識のコストが入力トークンの見積りに出ていない")
        XCTAssertGreaterThan(expected, 0)
    }

    /// 自己認識の中身が Modelfile と食い違っていないこと。
    ///
    /// **Ollama 側とアプリ側は別系統で `make models` では同期されない。**
    /// 片方だけ直して食い違うのがこの機能の唯一の壊れ方なので、そこを見張る。
    func testSelfRecognitionMatchesTheModelfile() throws {
        let prompt = SophiaDefaults.systemPrompt

        XCTAssertTrue(prompt.contains("Sophia"), "名前が入っていない")
        XCTAssertTrue(prompt.contains("常に「Sophia」と名乗"), "名乗る指示が入っていない")
        XCTAssertTrue(prompt.contains("偽らない"), "偽らないという但し書きは削らないこと")

        // 出力スタイルの指示は**持ち込まない**と決めた（毎ターン+130トークン）。
        XCTAssertFalse(prompt.contains("書き方の原則"), "スタイル指示が紛れ込んでいる")
        XCTAssertFalse(prompt.contains("やりとりの原則"), "スタイル指示が紛れ込んでいる")

        // 毎ターン払う額。増えたら気づけるように上限で縛る。
        let tokens = [SophiaMessage.system(prompt)].estimatedTokenCount
        XCTAssertLessThanOrEqual(
            tokens, 80,
            "自己認識が概算80トークンを超えた。増やすなら BENCH_RESULTS に実測を残してから")
    }

    /// 生成タスクとエンジンの往復が終わるのを待つ。
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
