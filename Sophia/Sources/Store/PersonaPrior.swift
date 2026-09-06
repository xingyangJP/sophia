import Foundation

// =============================================================================
//  人物像の事前分布
//
//  ## なぜ「事前分布」という言い方をするのか
//
//  **14.13c が既に決めている ── 「質問は事前分布であって証拠ではない」。**
//  利用者の指示（2026-09-06）は、**四柱推命と血液型も同じ扱いにする**ことだった:
//
//  > **「心理学 IQ EQ 統計学（四柱推命 血液型） この思想だよ」**
//
//  **統計学として正しく言うと、順序はこうなる:**
//
//  | | 何か | 強さ |
//  |---|---|---|
//  | 人口の分布 | **事前分布**（何も知らない相手の初期値） | — |
//  | 生年月日・血液型 | 事前分布を**ずらす**もの | **極めて弱い** |
//  | 初回質問 | 弱い尤度 | 弱い |
//  | **使用中の訂正**（FR-31） | **強い尤度。ここだけが結論を動かす** | **強い** |
//
//  > **事前分布だけで断定するのが「占い」であり、事前分布を持たないのが
//  > 「毎回ゼロから訊く」である。本設計はどちらも避ける。**
//
//  座標は IPIP-NEO の5領域（`docs/PERSONA_MODEL.md`）。
// =============================================================================

/// 1つの領域についての、いまの見込み。
struct PersonaBelief: Sendable, Equatable, Codable {

    /// 0.0〜1.0。**0.5 は「分からない」であって「真ん中の性格」ではない。**
    var value: Double

    /// 0.0〜1.0。**この見込みをどれだけ信じてよいか。**
    ///
    /// **`value` だけを見て振る舞いを変えないこと。** 確信度の低い 0.9 は、
    /// 「その人は極端だ」ではなく「まだ何も分かっていない」である。
    var confidence: Double

    static let unknown = PersonaBelief(value: 0.5, confidence: 0.0)

    /// **精度（確信度）で重みを付けて混ぜる。**
    ///
    /// 単純平均にしないのは、**弱い材料が強い材料を同じ重みで薄めてしまう**からである。
    /// 血液型（確信度 0.02）が、使用中の訂正（0.75）と同じ重さで混ざってはいけない。
    func blended(with other: PersonaBelief) -> PersonaBelief {
        let total = confidence + other.confidence
        guard total > 0 else { return .unknown }
        return PersonaBelief(
            value: (value * confidence + other.value * other.confidence) / total,
            // **確信度は足すが、1 を超えない。**
            // 弱い材料をいくつ積んでも、強い材料1つには届かない設計である。
            confidence: min(1.0, total))
    }
}

/// 5領域ぶんの見込み。
struct PersonaPrior: Sendable, Equatable, Codable {

    /// IPIP-NEO の5領域。**この5つ以外を持たない**（`docs/PERSONA_MODEL.md`）。
    static let domains = ["N", "E", "O", "A", "C"]

    var beliefs: [String: PersonaBelief]

    init(beliefs: [String: PersonaBelief] = [:]) {
        var filled: [String: PersonaBelief] = [:]
        for domain in Self.domains { filled[domain] = beliefs[domain] ?? .unknown }
        self.beliefs = filled
    }

    subscript(domain: String) -> PersonaBelief {
        beliefs[domain] ?? .unknown
    }

    // MARK: - 事前分布の出発点

    /// **人口の分布。何も知らない相手の初期値。**
    ///
    /// 全領域が中央（0.5）で、**確信度は 0 である。**
    ///
    /// > **「中央値だから確信度も中くらい」ではない。**
    /// > 中央に置くのは**情報が無いから**であって、**中央だと分かったからではない。**
    /// > ここを取り違えると、何も知らない相手を「平均的な人」として扱い始める。
    ///
    /// **【未実装】** [automoto/big-five-data](https://github.com/automoto/big-five-data) の
    /// 307,313人ぶんの分布を入れれば、**領域ごとの散らばりと領域間の相関**が使える。
    /// 相関が入ると、**12問で30ファセットを推す**ことができる（いまは推していない）。
    /// **入れていないものを入れたふりをしないため、ここは中央のままにしてある。**
    static let population = PersonaPrior()

    // MARK: - ずらすもの

    /// 生年月日から**生活段階**だけを取り出してずらす。
    ///
    /// **性格を年齢から決めているのではない。** 加齢に伴う変化は
    /// **Big Five の中で最も再現性のある知見の1つ**で、成人期を通じて
    /// **C（誠実性）と A（協調性）が上がり、N（情動安定性の低さ）が下がる**傾向がある。
    /// それでも**個人差のほうが大きい**ので、確信度は低く置く。
    ///
    /// > **`archetypes` の回答案 B が言っているのがこれである** ──
    /// > 「必要なら年齢や生活段階だけを文脈に使い、実際の言動を根拠にする」。
    func shifted(byAge age: Int) -> PersonaPrior {
        guard age >= 0, age < 130 else { return self }
        // 20歳を 0、60歳を 1 とした位置。**外挿しない。**
        let t = min(1.0, max(0.0, Double(age - 20) / 40.0))
        var next = self
        next.merge("C", PersonaBelief(value: 0.5 + 0.2 * t, confidence: 0.10))
        next.merge("A", PersonaBelief(value: 0.5 + 0.15 * t, confidence: 0.08))
        next.merge("N", PersonaBelief(value: 0.5 - 0.15 * t, confidence: 0.08))
        return next
    }

    /// 血液型でずらす。**確信度は意図的に極小である。**
    ///
    /// > **⚠ 経験的な裏付けは、実質的に無い。**
    /// > 大規模調査は血液型と性格の関連を繰り返し否定している。
    /// > **それでも 0 にしないのは、利用者が「事前分布として使う」と決めたからである**
    /// > （`archetypes` の回答案 A）。**0 にすると使わないのと同じで、
    /// > 「使うが、ほとんど動かない」を表現できない。**
    ///
    /// **`bloodTypeConfidence` が `trainingThreshold` より桁で小さいことは、
    /// 試験が固定している** ── **血液型だけで結論が動く経路を作らないため。**
    static let bloodTypeConfidence = 0.02

    func shifted(byBloodType type: String) -> PersonaPrior {
        var next = self
        let c = Self.bloodTypeConfidence
        switch type.uppercased() {
        case "A": next.merge("C", PersonaBelief(value: 0.65, confidence: c))
        case "B": next.merge("O", PersonaBelief(value: 0.65, confidence: c))
        case "O": next.merge("E", PersonaBelief(value: 0.65, confidence: c))
        case "AB": next.merge("O", PersonaBelief(value: 0.60, confidence: c))
        default: break
        }
        return next
    }

    /// 初回質問の答えでずらす。**弱い尤度。**
    ///
    /// 14.13c: **質問（0.5）は関門（0.7）に届かない。** 焼かれるのは使用中の訂正だけである。
    func updated(domain: String, toward value: Double, confidence: Double) -> PersonaPrior {
        var next = self
        next.merge(domain, PersonaBelief(value: value, confidence: confidence))
        return next
    }

    private mutating func merge(_ domain: String, _ belief: PersonaBelief) {
        guard Self.domains.contains(domain) else { return }
        beliefs[domain] = self[domain].blended(with: belief)
    }

    // MARK: - 使ってよいか

    /// **重みへ焼いてよい確信度**（14.13c の関門）。
    static let trainingThreshold = 0.7

    /// この領域について、**振る舞いを変えてよいか。**
    ///
    /// **`value` が極端でも、確信度が足りなければ false である。**
    func isActionable(_ domain: String) -> Bool {
        self[domain].confidence >= Self.trainingThreshold
    }

    /// 画面に出す1行。**確信度を必ず添える**（FR-28 / FR-29）。
    ///
    /// **数字だけを出さない** ── 「開放性 0.72」は、根拠が血液型1つでも同じ顔をする。
    func describe(_ domain: String) -> String {
        let b = self[domain]
        let strength: String
        switch b.confidence {
        case ..<0.2: strength = "ほとんど分かっていない"
        case ..<0.5: strength = "手がかりがある程度"
        case ..<Self.trainingThreshold: strength = "見込みはあるが、まだ足りない"
        default: strength = "使ってよい"
        }
        return "\(domain) \(String(format: "%.2f", b.value))（確信度 "
            + "\(String(format: "%.2f", b.confidence))・\(strength)）"
    }
}
