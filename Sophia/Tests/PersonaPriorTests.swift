import XCTest

@testable import Sophia

/// **事前分布が「占い」にならないことを固定する。**
///
/// 利用者の思想（2026-09-06）:
/// > **「心理学 IQ EQ 統計学（四柱推命 血液型） この思想だよ」**
///
/// 統計学として使うということは、**事前分布と証拠を混ぜない**ということである。
/// **事前分布だけで断定するのが占いであり、事前分布を持たないのが毎回ゼロから訊くこと。**
/// ここで守るのは前者の側である。
final class PersonaPriorTests: XCTestCase {

    // MARK: - 出発点

    /// **何も知らない状態は「中央」ではなく「確信度0」である。**
    ///
    /// 中央に置くのは情報が無いからであって、中央だと分かったからではない。
    /// **取り違えると、何も知らない相手を「平均的な人」として扱い始める。**
    func testKnowingNothingIsZeroConfidenceNotAverageness() {
        for domain in PersonaPrior.domains {
            XCTAssertEqual(PersonaPrior.population[domain].value, 0.5)
            XCTAssertEqual(
                PersonaPrior.population[domain].confidence, 0.0,
                "\(domain) が「分からない」ではなく「平均的」になっている")
            XCTAssertFalse(
                PersonaPrior.population.isActionable(domain),
                "何も知らないのに振る舞いを変えてよいことになっている")
        }
    }

    // MARK: - **占いにしない**（これが本丸）

    /// **血液型だけでは、決して関門に届かない。**
    ///
    /// 届いてしまえば、**「B型だから開放的」という断定が振る舞いを変える。**
    /// それは利用者が `archetypes` の回答案で明示的に否定した形である
    /// （「属性から性格を推定せず、実際の言動を根拠にする」）。
    func testBloodTypeAloneNeverReachesTheThreshold() {
        for type in ["A", "B", "O", "AB"] {
            let prior = PersonaPrior.population.shifted(byBloodType: type)
            for domain in PersonaPrior.domains {
                XCTAssertFalse(
                    prior.isActionable(domain),
                    "血液型 \(type) だけで \(domain) が使ってよい状態になっている")
            }
        }
    }

    /// **血液型を何回重ねても届かない。**
    ///
    /// 同じ弱い材料を積み増して強い結論を作る経路は、**塞いでおく。**
    func testStackingTheSameWeakSignalStillDoesNotReachTheThreshold() {
        var prior = PersonaPrior.population
        for _ in 0..<20 { prior = prior.shifted(byBloodType: "B") }
        XCTAssertFalse(
            prior.isActionable("O"),
            "弱い材料を20回積んだら関門を越えた。**積み増しで断定できてしまう**")
    }

    /// **年齢と血液型を全部足しても、まだ届かない。**
    ///
    /// 事前分布は事前分布のままであること。**証拠は別に要る。**
    func testEveryPriorTogetherIsStillNotEvidence() {
        let prior = PersonaPrior.population
            .shifted(byAge: 45)
            .shifted(byBloodType: "A")
        for domain in PersonaPrior.domains {
            XCTAssertFalse(
                prior.isActionable(domain),
                "\(domain) が事前分布だけで使ってよい状態になっている")
        }
    }

    /// **確信度の桁が違うこと。** 血液型は関門の 1/10 未満である。
    func testTheBloodTypeSignalIsAnOrderOfMagnitudeBelowTheGate() {
        XCTAssertLessThan(
            PersonaPrior.bloodTypeConfidence, PersonaPrior.trainingThreshold / 10,
            "血液型の重みが、関門と同じ桁に近づいている")
    }

    // MARK: - 混ぜ方

    /// **弱い材料が強い材料を薄めないこと。**
    ///
    /// 単純平均だと、血液型（0.02）が訂正（0.75）を同じ重さで引っぱる。
    func testAWeakSignalBarelyMovesAStrongOne() {
        let strong = PersonaBelief(value: 0.9, confidence: 0.75)
        let weak = PersonaBelief(value: 0.1, confidence: 0.02)
        let mixed = strong.blended(with: weak)
        XCTAssertGreaterThan(mixed.value, 0.85, "弱い材料に引っぱられすぎている")
        XCTAssertLessThan(mixed.value, 0.9)
    }

    /// **確信度は 1 を超えない。**
    func testConfidenceIsCapped() {
        var belief = PersonaBelief(value: 0.6, confidence: 0.9)
        belief = belief.blended(with: PersonaBelief(value: 0.6, confidence: 0.9))
        XCTAssertLessThanOrEqual(belief.confidence, 1.0)
    }

    // MARK: - 年齢

    /// **年齢は向きだけを与える。** C と A は上がり、N は下がる（再現性のある知見）。
    func testAgeMovesTheDirectionsThatReplicate() {
        let young = PersonaPrior.population.shifted(byAge: 20)
        let older = PersonaPrior.population.shifted(byAge: 60)
        XCTAssertGreaterThan(older["C"].value, young["C"].value)
        XCTAssertGreaterThan(older["A"].value, young["A"].value)
        XCTAssertLessThan(older["N"].value, young["N"].value)
    }

    /// **外挿しない。** 範囲外の年齢は何も動かさない。
    func testAnImpossibleAgeChangesNothing() {
        XCTAssertEqual(PersonaPrior.population.shifted(byAge: -1), PersonaPrior.population)
        XCTAssertEqual(PersonaPrior.population.shifted(byAge: 200), PersonaPrior.population)
    }

    // MARK: - 見せ方

    /// **確信度を添えずに数字を出さない。**
    ///
    /// 「開放性 0.72」は、根拠が血液型1つでも同じ顔をする。
    func testTheDisplayAlwaysCarriesTheConfidence() {
        let line = PersonaPrior.population.shifted(byBloodType: "B").describe("O")
        XCTAssertTrue(line.contains("確信度"), "確信度が添えられていない: \(line)")
        XCTAssertTrue(
            line.contains("ほとんど分かっていない"),
            "弱い根拠なのに、そう見えない: \(line)")
    }

    /// **強い証拠なら使ってよい状態になること**（陽性対照）。
    ///
    /// 塞ぐ側だけを試験すると、**何も通らない実装でも緑になる。**
    func testStrongEvidenceDoesReachTheThreshold() {
        let prior = PersonaPrior.population
            .updated(domain: "A", toward: 0.8, confidence: 0.75)
        XCTAssertTrue(prior.isActionable("A"), "強い証拠でも関門を越えない")
        XCTAssertTrue(prior.describe("A").contains("使ってよい"))
    }

    // MARK: - 質問からの流れ込み（14.13c）

    /// **12問すべてに答えても、関門には届かない。**
    ///
    /// > 14.13c: **質問は事前分布であって証拠ではない。**
    /// > 届いてしまえば、**一度も一緒に働いていない相手について、
    /// > 質問だけで振る舞いを変える**ことになる。
    /// > 焼かれるのは使用中の訂正だけである、という決定がここで守られる。
    func testAnsweringEveryQuestionStillDoesNotReachTheThreshold() {
        let answers = OnboardingQuestionnaire.all.map { ($0, OnboardingChoice.Side.a) }
        let prior = PersonaPrior.from(answers: answers)
        for domain in PersonaPrior.domains {
            XCTAssertFalse(
                prior.isActionable(domain),
                "\(domain) が質問だけで使ってよい状態になっている（14.13c 違反）")
        }
    }

    /// **それでも、答えは向きを作ること**（陰性対照の裏）。
    ///
    /// 何も動かないなら、質問に答える意味が無い。
    func testAnswersDoMoveTheDirection() {
        let a = PersonaPrior.from(
            answers: OnboardingQuestionnaire.all.map { ($0, OnboardingChoice.Side.a) })
        let b = PersonaPrior.from(
            answers: OnboardingQuestionnaire.all.map { ($0, OnboardingChoice.Side.b) })
        XCTAssertNotEqual(a, b, "どちらを選んでも同じ像になっている")
        XCTAssertNotEqual(a["C"].value, PersonaPrior.population["C"].value)
    }

    /// **`archetypes` は事前分布を動かさない。** あれは性格の軸ではなく方針である。
    func testTheTypologyPolicyQuestionIsNotAPersonalityAxis() {
        let archetypes = OnboardingQuestionnaire.all.first { $0.category == "archetypes" }
        let prior = PersonaPrior.from(answers: [(archetypes!, .a)])
        XCTAssertEqual(prior, PersonaPrior.population, "方針の質問が性格の像を動かしている")
    }

    /// **確信度の出所は1か所であること。**
    ///
    /// ここで独自の数字を置くと、`user_traits` に入る値と分かれて、片方だけ古くなる。
    func testTheConfidenceComesFromTheSingleSourceOfTruth() {
        let one = OnboardingQuestionnaire.all.first { $0.facet.hasPrefix("C") }!
        let prior = PersonaPrior.from(answers: [(one, .a)])
        XCTAssertEqual(
            prior["C"].confidence, TraitSource.onboarding.defaultConfidence, accuracy: 1e-9)
    }

}
