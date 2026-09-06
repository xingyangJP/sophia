import XCTest

@testable import Sophia

/// **画面から訂正を押したら、本当に DB へ書かれるか**（FR-27 / FR-31）。
///
/// 経路は3段ある ── メニュー → `ChatViewModel.recordCorrection` → `Store`。
/// **`Store` の側は `CorrectionCaptureTests` が固めているが、
/// 途中で切れていたら「押しても何も起きない」ことに誰も気づけない。**
/// 使っているのに学ばない、という最も分かりにくい壊れ方になる。
@MainActor
final class CorrectionAffordanceTests: StoreTestCase {

    private func makeModel(_ store: Store) -> ChatViewModel {
        ChatViewModel(engine: SilentEngine(), store: store)
    }

    /// **押したら書かれること。** 向きも一緒に。
    func testPressingOverreachReachesTheDatabase() async throws {
        let store = try makeInMemoryStore()
        let model = makeModel(store)

        model.recordCorrection(.overreach)
        await model.waitForPendingWrites()

        let traits = try await store.allTraits()
        XCTAssertEqual(traits.count, 1, "**押したのに何も書かれていない。** 経路が切れている")
        XCTAssertEqual(traits[0].direction, .overreach)
        XCTAssertEqual(traits[0].source, .correction)
    }

    /// **逆の向きも、別の向きとして書かれること。**
    func testPressingHedgingRecordsTheOppositeDirection() async throws {
        let store = try makeInMemoryStore()
        let model = makeModel(store)

        model.recordCorrection(.hedging)
        await model.waitForPendingWrites()

        let traits = try await store.allTraits()
        XCTAssertEqual(traits.first?.direction, .hedging)
    }

    /// **2回押したら関門を越えること。** ここが「学習が始まる」地点である。
    func testPressingTwiceCrossesTheGate() async throws {
        let store = try makeInMemoryStore()
        let model = makeModel(store)

        model.recordCorrection(.hedging)
        model.recordCorrection(.hedging)
        await model.waitForPendingWrites()

        let traits = try await store.allTraits()
        XCTAssertEqual(traits.count, 1, "同じ軸で像が増えている。確信度が上がらない")
        XCTAssertTrue(
            traits[0].qualifiesForTraining(),
            "**二度押しても焼かれない。** それでは学習が始まらない")
    }

    /// **向きの無い訂正も通ること。**
    func testPressingToneRecordsWithoutADirection() async throws {
        let store = try makeInMemoryStore()
        let model = makeModel(store)

        model.recordCorrection(nil)
        await model.waitForPendingWrites()

        let traits = try await store.allTraits()
        XCTAssertNil(traits.first?.direction)
        XCTAssertEqual(traits.first?.category, "tone")
    }
}

/// 何も返さない実行役。**訂正の経路だけを測るので、生成は要らない。**
private final class SilentEngine: InferenceEngine, @unchecked Sendable {
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
