import XCTest

@testable import Sophia

/// **使用中の訂正を採る経路**（FR-27 / FR-31）。
///
/// ## ここが無いと、学習は永久に始まらない
///
/// `891c15e` が自分でこう書いている ──
/// **「使用中の訂正を採る経路がまだ無く、無いと学習は永久に始まらない。」**
///
/// 質問（0.5）は関門（0.7）に届かないと決めた（14.13c）。
/// **したがって関門を越える材料は、ここからしか出てこない。**
final class CorrectionCaptureTests: StoreTestCase {

    // MARK: - 関門（ここが本丸）

    /// **1回目は届かない。** 0.65 < 0.7。
    ///
    /// > **気まぐれの1回で重みが変わってはいけない。**
    /// > 変わるなら、焼いているのは**その人ではなく、その日の気分**である。
    func testASingleCorrectionDoesNotReachTheGate() async throws {
        let store = try makeInMemoryStore()
        let trait = try await store.recordCorrection(
            category: "granularity", statement: "結論だけでよい", direction: .hedging)

        XCTAssertEqual(trait.confidence, TraitSource.correction.defaultConfidence, accuracy: 1e-9)
        XCTAssertFalse(
            trait.qualifiesForTraining(),
            "1回の訂正で焼かれる状態になっている（その日の気分を焼くことになる）")
    }

    /// **2回目で越える。** 0.65 + 0.1 = 0.75 > 0.7。
    ///
    /// **陽性対照である。** 塞ぐ側だけを試験すると、
    /// **何を言っても焼かれない実装でも緑になる。**
    func testTheSecondCorrectionCrossesTheGate() async throws {
        let store = try makeInMemoryStore()
        _ = try await store.recordCorrection(
            category: "granularity", statement: "結論だけでよい", direction: .hedging)
        let again = try await store.recordCorrection(
            category: "granularity", statement: "結論を先に、理由は1行で", direction: .hedging)

        XCTAssertGreaterThan(again.confidence, UserTraitDefaults.trainingConfidenceThreshold)
        XCTAssertTrue(
            again.qualifiesForTraining(),
            "**二度訂正されても焼かれない。** それでは学習が始まらない")
    }

    // MARK: - 向き（FR-31）

    /// **正反対の向きが、同じ「訂正1件」に潰れないこと。**
    ///
    /// > 「そんな断言できないだろ」（踏み込みすぎ）と
    /// > 「で、結局どっちなの」（逃げすぎ）は**正反対**である。
    /// > **向きを持たせずに焼けば、打ち消し合って何も学ばない。**
    func testOppositeDirectionsAreNotCollapsedIntoOne() async throws {
        let store = try makeInMemoryStore()
        let bold = try await store.recordCorrection(
            category: "certainty", statement: "断定しすぎ", direction: .overreach)
        let vague = try await store.recordCorrection(
            category: "granularity", statement: "曖昧すぎ", direction: .hedging)

        XCTAssertEqual(bold.direction, .overreach)
        XCTAssertEqual(vague.direction, .hedging)
        XCTAssertNotEqual(bold.direction, vague.direction, "向きが区別できていない")
    }

    /// **向きの無い訂正も記録できること。**
    ///
    /// **無理に二択へ倒さない。** 倒すと、向きの無いものが**偽の向き**を持つ。
    func testACorrectionWithoutADirectionIsStillRecorded() async throws {
        let store = try makeInMemoryStore()
        let trait = try await store.recordCorrection(
            category: "tone", statement: "その言い方はきつい", direction: nil)

        XCTAssertNil(trait.direction)
        XCTAssertEqual(trait.source, .correction)
    }

    /// **向きは上書きされること。** 前回と逆を言われたら、**新しいほうが現在の状態である。**
    func testTheLatestDirectionWins() async throws {
        let store = try makeInMemoryStore()
        _ = try await store.recordCorrection(
            category: "certainty", statement: "断定しすぎ", direction: .overreach)
        let flipped = try await store.recordCorrection(
            category: "certainty", statement: "今度は曖昧すぎる", direction: .hedging)

        XCTAssertEqual(
            flipped.direction, .hedging,
            "**向きが古いまま残っている。** 前回の逆を言われたのに気づいていない")
    }

    // MARK: - 同じ軸を増やさない

    /// **同じ軸で行が増えないこと。**
    ///
    /// 増えると「同じことを2回言われた」が
    /// **「別々の弱い像が2つある」**になり、**確信度が永久に上がらない。**
    func testTheSameAxisIsReinforcedNotDuplicated() async throws {
        let store = try makeInMemoryStore()
        for _ in 0..<3 {
            _ = try await store.recordCorrection(
                category: "granularity", statement: "短く", direction: .hedging)
        }
        let all = try await store.allTraits().filter { $0.category == "granularity" }
        XCTAssertEqual(all.count, 1, "同じ軸の像が増えている。確信度が上がらなくなる")
    }

    /// **前の文も前の確信度も消えないこと**（NFR-12）。
    ///
    /// **重みは記録ではなく複製である。原本は DB に残す。**
    func testTheEarlierVersionsSurvive() async throws {
        let store = try makeInMemoryStore()
        let first = try await store.recordCorrection(
            category: "granularity", statement: "最初の言い方", direction: .hedging)
        _ = try await store.recordCorrection(
            category: "granularity", statement: "二度目の言い方", direction: .hedging)

        let revisions = try await store.traitRevisions(of: first.id)
        XCTAssertFalse(revisions.isEmpty, "**訂正の履歴が残っていない。** 何を根拠に焼いたか辿れない")
        XCTAssertTrue(
            revisions.contains { $0.statement == "二度目の言い方" },
            "追記されているのが新しい文でない")
    }

    // MARK: - 質問との線引き（14.13c）

    /// **質問だけでは、いくら答えても関門に届かないこと。**
    ///
    /// 訂正の経路を作ったからといって、**質問の重みが上がってはいけない。**
    func testQuestionsStillDoNotReachTheGateEvenNowThatCorrectionsExist() async throws {
        let store = try makeInMemoryStore()
        let fromQuestion = try await store.recordTrait(
            kind: .style, category: "machine", statement: "足りない前提で測る",
            source: .onboarding)

        XCTAssertFalse(
            fromQuestion.qualifiesForTraining(),
            "質問だけで焼かれる状態になっている（14.13c 違反）")
    }
}
