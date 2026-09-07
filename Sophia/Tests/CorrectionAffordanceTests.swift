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

        model.recordCorrection(.tone)
        await model.waitForPendingWrites()

        let traits = try await store.allTraits()
        XCTAssertNil(traits.first?.direction)
        XCTAssertEqual(traits.first?.category, "tone")
    }

    // MARK: - 押した結果を返す（2026-09-07）

    /// **押したら受領が返ること。**
    ///
    /// > **押しても何も変わらないと、利用者は押せたか分からず、もう一度押す。**
    /// > 実際にそうなった ── 2回押されて確信度が 0.5 → 0.7 まで動いた。
    /// > **たまたま関門へ届いたが、逆に5回押されていたら
    /// > 「押した回数」という信号そのものが壊れていた。**
    func testPressingReturnsAReceipt() async throws {
        let store = try makeInMemoryStore()
        let model = makeModel(store)
        let turnID = UUID()

        model.recordCorrection(.hedging, turnID: turnID)
        await model.waitForPendingWrites()

        let receipt = try XCTUnwrap(model.lastCorrection, "**押したのに受領が返らない**")
        XCTAssertEqual(receipt.turnID, turnID, "別の発言の受領が混ざっている")
        XCTAssertEqual(receipt.direction, .hedging)
        XCTAssertFalse(receipt.qualifies, "1回目で関門を越えている")
        XCTAssertTrue(receipt.line.contains("もう一度"), "あと何回で効くのかが伝わらない")
    }

    /// **関門を越えた瞬間は、言い方が変わること。**
    ///
    /// **「記録しました」だけだと、越えたことが分からない。**
    /// 越えた回だけは、**そう言う。**
    func testCrossingTheGateIsAnnounced() async throws {
        let store = try makeInMemoryStore()
        let model = makeModel(store)
        let turnID = UUID()

        model.recordCorrection(.hedging, turnID: turnID)
        model.recordCorrection(.hedging, turnID: turnID)
        await model.waitForPendingWrites()

        let receipt = try XCTUnwrap(model.lastCorrection)
        XCTAssertTrue(receipt.qualifies)
        XCTAssertTrue(
            receipt.line.contains("学習に使えるようになりました"),
            "関門を越えたのに、越えたと言っていない: \(receipt.line)")
    }

    // MARK: - 軸が質問側と揃っていること（2026-09-07）

    /// **訂正の軸の綴りが、質問側と一致していること。**
    ///
    /// > 揃っていないと、**同じことについて像が2つでき、どちらも関門に届かない。**
    /// > 「質問では granularity、訂正では granularity2」のような取り違えは、
    /// > **動くし、緑になるし、永久に学習されない。**
    func testEveryCorrectionAxisExistsOnTheQuestionSide() {
        let questionCategories = Set(OnboardingQuestionnaire.all.map(\.category))
        for kind in ChatViewModel.CorrectionKind.allCases {
            // `tone` は質問側に無い軸である（会話の中でしか出ない）。
            if kind.category == "tone" { continue }
            XCTAssertTrue(
                questionCategories.contains(kind.category),
                "訂正の軸 `\(kind.category)`（\(kind.label)）が質問側に無い。"
                    + "**綴りがずれると像が2つできる**")
        }
    }

    /// **押せる軸が2つだけ、という状態に戻らないこと。**
    ///
    /// 2026-09-07、最初は `certainty` と `tone` の2軸しか無かった。
    /// **質問では12軸を訊いているのに、訂正で触れるのは2軸だけ**という状態で、
    /// **口が無い軸は永久に学習されない。**
    func testTheCorrectionMenuCoversMoreThanTwoAxes() {
        let axes = Set(ChatViewModel.CorrectionKind.allCases.map(\.category))
        XCTAssertGreaterThanOrEqual(
            axes.count, 5,
            "訂正で触れる軸が \(axes.count) 個しかない。**口が無い軸は学習されない**")
    }

    /// **向きの割り当てが揃っていること。**
    ///
    /// 「勝手に進めた」は踏み込みすぎ側、「訊きすぎ」は逃げすぎ側 ──
    /// **同じ軸の正反対が、同じ向きに倒れていないこと。**
    func testOppositeKindsOnTheSameAxisCarryOppositeDirections() {
        XCTAssertEqual(ChatViewModel.CorrectionKind.actedWithoutAsking.direction, .overreach)
        XCTAssertEqual(ChatViewModel.CorrectionKind.askedTooMuch.direction, .hedging)
        XCTAssertEqual(
            ChatViewModel.CorrectionKind.actedWithoutAsking.category,
            ChatViewModel.CorrectionKind.askedTooMuch.category,
            "同じ軸のはずが別の軸になっている")
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
