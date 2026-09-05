import XCTest

@testable import Sophia

// =============================================================================
//  取得・展開の最中は送れない ── そして**打った文が消えないこと**
//
//  **事故の形**（2026-09-05 / docs/DOWNLOAD_VERIFY.md）:
//  モデルの取得中、`send()` は `input` を先に空にしてから履歴を組んでいた。
//  **モデルが無い状態で送ると、文だけが消えた。**
//
//  > **打てないことより、打った文が消えることのほうが害が大きい。**
//
//  ここで固定するのは3つ ── **送れないこと**、**残ること**、
//  そして**送れる側を壊していないこと**（陰性対照）。
// =============================================================================
@MainActor
final class ChatSendGateTests: XCTestCase {

    /// **陰性対照。** 読み込みが走っていなければ、これまでどおり送れる。
    ///
    /// **この試験がいちばん重要である。** 2026-09-05、判定を `model != nil` と書いた
    /// ところ、**`FolderUITests` の5件が即座に落ちた** ── `model` を載せずに送る経路が
    /// 実在するからである。**「モデルが載っていない」と「いま取得中」は別の状態。**
    func testSendingStillWorksWhenNoLoadIsRunning() {
        let model = ChatViewModel(engine: IdleEngine())
        model.input = "こんにちは"

        XCTAssertTrue(model.isModelReady, "読み込みが走っていない = 送ってよい")
        XCTAssertTrue(model.canSend)
        XCTAssertNil(model.sendBlockedReason, "送れるときに理由を出さない")

        model.send()
        XCTAssertEqual(model.input, "", "送れたなら消費される")
    }

    /// **本題。** 取得の最中は送れず、**打った文はそのまま残る。**
    func testTheDraftSurvivesWhileTheModelIsStillLoading() async {
        let model = await loadingViewModel()
        model.input = "これは消えてはいけない"

        XCTAssertFalse(model.isModelReady)
        XCTAssertFalse(model.canSend, "取得中は送れない")

        model.send()

        XCTAssertEqual(
            model.input, "これは消えてはいけない",
            "**送れなかった文が消えている。** これが事故のときの体験だった")
    }

    /// **`canSend` を無効にするだけでは足りない。**
    /// `send()` は Return キーからも呼ばれるので、**ボタンを塞いでも口は残る。**
    func testSendIsGuardedAtTheModelNotOnlyAtTheButton() async {
        let model = await loadingViewModel()
        model.input = "Return から直接呼ぶ"

        model.send()   // UI を経由せず、出荷の `send()` をそのまま叩く

        XCTAssertEqual(model.input, "Return から直接呼ぶ")
        XCTAssertFalse(model.isGenerating, "生成が始まってはいけない")
    }

    /// **黙って無効にしない。** 理由が出ること。
    ///
    /// 事故のとき画面は「0% のまま固まっている」ように見えており、
    /// **待つべきか壊れているかを利用者が判断できなかった。**
    func testABlockedComposerSaysWhy() async {
        let model = await loadingViewModel()
        model.input = "なにか"

        let reason = model.sendBlockedReason
        XCTAssertNotNil(reason, "無効なのに理由が無いと、待つべきか壊れているか分からない")
        XCTAssertFalse(reason?.isEmpty ?? true)
    }

    // MARK: - 補助

    /// **取得が走っている最中**の `ChatViewModel` を作る。
    /// `NeverFinishingEngine` は進捗を1つ流したまま終わらないので、
    /// **`isLoadingModel` が立った状態で観測できる。**
    private func loadingViewModel() async -> ChatViewModel {
        let model = ChatViewModel(engine: NeverFinishingEngine())
        Task { @MainActor in await model.prepare() }
        // 進捗が1つ届くまで待つ。**固定の sleep にしない**（遅い機械で崩れる）。
        for _ in 0..<200 where !model.isLoadingModel {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isLoadingModel, "前提: 取得が走っている")
        return model
    }
}

// MARK: - 試験用の実行役

/// 何もしない。**`load` を呼ばれない**ので、読み込みは走らない。
private final class IdleEngine: InferenceEngine, @unchecked Sendable {
    nonisolated var identifier: EngineIdentifier { .mlx }
    func loadedModel() async -> ModelInfo? { nil }
    func capabilities() async -> EngineCapabilities {
        EngineCapabilities(
            supportsThinking: false, canDisableThinking: true, maxContextLength: 4096)
    }
    func availableModels() async throws -> [ModelInfo] { [] }
    nonisolated func load(_ modelID: String) -> AsyncThrowingStream<LoadProgress, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func unload() async {}
    nonisolated func chat(
        _ messages: [SophiaMessage], options: ChatOptions
    ) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// **取得中で止まったまま**の実行役。進捗を1つ流して、そのあと終わらない。
private final class NeverFinishingEngine: InferenceEngine, @unchecked Sendable {
    nonisolated var identifier: EngineIdentifier { .mlx }
    func loadedModel() async -> ModelInfo? { nil }
    func capabilities() async -> EngineCapabilities {
        EngineCapabilities(
            supportsThinking: false, canDisableThinking: true, maxContextLength: 4096)
    }
    func availableModels() async throws -> [ModelInfo] { [] }
    nonisolated func load(_ modelID: String) -> AsyncThrowingStream<LoadProgress, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(LoadProgress(
                stage: .downloading,
                completedBytes: 14_275_517,
                totalBytes: 4_622_110_691,
                fraction: 0.003,
                detail: "モデルを取得しています"))
            // **finish しない。** 取得中のまま止まる。
        }
    }
    func unload() async {}
    nonisolated func chat(
        _ messages: [SophiaMessage], options: ChatOptions
    ) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
