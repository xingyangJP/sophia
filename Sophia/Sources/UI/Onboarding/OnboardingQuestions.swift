import Foundation

// =============================================================================
//  パーソナライズの初期化 ── **何を訊くか**（DESIGN.md 14.8節）と
//                            **何回訊くか**（14.9節）
// -----------------------------------------------------------------------------
//  # このファイルは「例文」である。実装ではない
//
//  > **実装上の含意**: オンボーディングの主画面は**記入欄ではなく、回答例の二択**になる。
//  > **「例文を用意する」ことが実装の主要な作業**であり、例文の質がそのまま採取精度になる。
//  >                                                              ── 14.8節
//
//  したがって**このファイルの本体は文字列である。** 画面（`OnboardingView`）は
//  ここに書かれた文字列を並べるだけで、判断を1つも持っていない。
//  **例文を直すときはここだけを直す。**
//
//  # 訊いてよいのは様式だけである
//
//  | | 自己申告で正確に取れるか | 持続する価値があるか |
//  |---|---|---|
//  | **内容**（職種・技術スタック・いまの案件） | ○ 取れる | **× 陳腐化する** |
//  | **様式**（説明の粒度・断定への態度・何に苛立つか） | **× 取れない** | ○ 蓄積する |
//
//  **訊きやすいものと訊く価値があるものが逆を向いている**（14.8節）ので、
//  **内容は1問も置いていない。** ここにある14問はすべて `TraitKind.style` である。
//  内容は「使っていれば会話に自然に出てくる」ので、問診票にする必要がない。
//
//  # 自己申告では取れないので、質問ではなく選択で採る（FR-26）
//
//  「説明はどのくらい詳しいのが良いですか」と訊くと、実際の好みではなく**理想の自分**が返る
//  （宣言選好と顕示選好の乖離）。**正直さの問題ではなく、内省の限界である。**
//
//  **だから同じ問いへの回答案を2通り見せ、どちらが良いかを選ばせる。**
//  利用者は自分について申告しているのではなく、**目の前の2つの成果物を評価している。**
//  **行動は様式を漏らすが、内省は漏らさない。**
//
//  # 【本ファイルが引き受けていないこと】
//
//  - 学習の実行（`LoRATrain`）── 別作業
//  - 翻訳層（14.4節）── 別作業
//  - 重みへ焼く経路 ── 別作業
//
//  **ここは「訊いて、保存する」までである。** 保存された像は `placement = .stored`
//  ＝ **どこにも送られない。毎ターンの費用は 0**（14.7節 / FR-29）。
//  貯めるだけなら費用0で、1件も失われない（14.13節の梯子の段0）。
// =============================================================================

// MARK: - 二択の片方

/// 回答案1つ。**画面に出るのは `sample` であって `statement` ではない。**
///
/// この2つを分けてあることが FR-26 の実体である ──
/// 利用者が読むのは**成果物の見本**（`sample`）で、
/// DB に入るのは**そこから導いた規則**（`statement`）である。
/// **利用者に規則を読ませて選ばせると、それは自己申告に戻ってしまう。**
struct OnboardingChoice: Identifiable, Sendable, Equatable, Hashable {

    /// どちら側か。**A / B に意味は無い。** 並び順を固定するためだけの識別子で、
    /// 「A が推奨」ではない ── 推奨があるなら、それは質問ではなく設定である。
    enum Side: String, Sendable, Equatable, Hashable, CaseIterable {
        case a
        case b
    }

    var side: Side

    var id: String { side.rawValue }

    /// **画面に出る回答例。** Sophia が返しうる答えを、様式だけ変えて書いたもの。
    ///
    /// **中身（題材）は2つとも同じでなければならない。** 片方だけが正しいことを
    /// 言っていたら、利用者は様式ではなく正しさを選ぶ ── 測っている軸がずれる。
    var sample: String

    /// 等幅で出すか。コードの二択だけ true。
    var isCode: Bool = false

    /// **選ばれたときに `user_traits.statement` へ入る文**（14.14節）。
    ///
    /// ## 文の形の条件（14.8節の判定基準5）
    ///
    /// > **翻訳役が使える形か。** 答えが「短い依頼をどう具体化するか」に効かないなら、
    /// > 採れても置き場所が無い。
    ///
    /// したがって**好みの表明ではなく、出力を決める規則**として書いてある。
    /// 「詳しい説明が好き」ではなく「なぜそうなるかまで書く」。
    ///
    /// ## 短く保つこと（14.10節）
    ///
    /// 学習サンプルは 2,048トークンを超えると警告が出る。
    /// それ以前に、**様式1つを毎ターン指示文で言うと 29トークン**（14.13b節の実測）で、
    /// **`armed` の会話で利用者に残るのは 33トークン**（14.0節）である。
    /// **長い規則は、重みへ移すまでの間、置き場所が無い。**
    var statement: String
}

// MARK: - 質問1つ

/// 二択1組。**`category` がそのまま `user_traits.category` になる**（14.14節）。
struct OnboardingQuestion: Identifiable, Sendable, Equatable {

    /// `user_traits.category` と同じ値。**1つの軸に1問しか置かない**ので、
    /// これが質問の識別子を兼ねる（同じ軸を二度訊かないことが、型で保証される）。
    var id: String { category }

    var category: String

    /// 何を分けている軸か。**設定画面に出す**（FR-28。あとから見て意味が分かること）。
    var axis: String

    /// **利用者の依頼。** 「あなたがこう頼んだとして」の部分。
    ///
    /// **その場で答えられること**（14.8節 判定基準3）。
    /// 考え込ませる問いは離脱を生み、離脱しなくても**適当な答えは
    /// 誤った利用者像になり、無いより悪い**（14.16節①）。
    var prompt: String

    /// 回答案2つ。**必ず2つである**（`OnboardingQuestionnaire` の検査が固定している）。
    var choices: [OnboardingChoice]

    /// **次に訊く質問。答えによって変わる**（14.9節「質問セットは一覧ではなく木」）。
    ///
    /// > **適応的にするには、質問が互いに独立していてはいけない。**
    /// > 「非力なマシンは手段である」と答えた人に、その前提から導ける質問を
    /// > 続けて訊く意味は薄い ── **答えが予測できるものは利得が低い。**
    ///
    /// nil（未登録）なら、そこで木は終わる。
    var next: [OnboardingChoice.Side: String]

    func choice(_ side: OnboardingChoice.Side) -> OnboardingChoice? {
        choices.first { $0.side == side }
    }
}

// MARK: - 予算（14.9節 / FR-24）

/// **質問にも予算を置く。訊くこと自体が利用者のエネルギーだからである**（14.9節）。
///
/// 2026-09-05 の利用者判断で、初回は「短い設定」ではなく、
/// **一人を深く知るための校正セッション**になった。全問を強制するのではなく、
/// いつでも中断・スキップでき、選んだ答えはその場で保存する。
///
/// 12 は診断項目数ではない。仕事の進め方5軸と、認知・感情・関係・価値観を扱う7軸を、
/// 1本の適応経路で一度ずつ観察する上限である。点数や性格型は作らない。
enum OnboardingBudget {

    /// **初回に自動で出す上限。** 中断した残りは人物アイコンから再開できる。
    static let initialQuestionLimit = 12

    /// **通算の上限。** 回ごとではない ──
    /// 閉じて開き直しても、続けても、**新しく訊ける軸はここで尽きる**（FR-24）。
    /// 木が持ちうる最長経路の長さと一致させてある
    /// （`OnboardingQuestionsTests.testNoPathThroughTheTreeIsLongerThanTheBudget` が固定）。
    ///
    /// 「上限なし」（14.9節の設定画面の行）を**問数の無制限とは読んでいない。**
    /// 訊く価値のある軸が7つしか用意できていないのに問い続けると、
    /// **利得の低い問いが混ざる**（14.9節「上限を決めているのは情報利得ではない。離脱と誤答である」）。
    /// **「上限なし」に当たるのは再確認**（`OnboardingViewModel.startReview`）**のほうである** ──
    /// あちらは新しい軸を増やさないので、何度でも深められる。
    ///
    /// **例文を足せばこの数は増える。数を増やすことが目的ではない。**
    static let hardQuestionLimit = 12

    /// **学習が立ち上がった件数**（14.13b節 / `make lorasize` 2026-08-19 実測）。
    ///
    /// 20件で 0.92 / 50件で 1.00。**利用者に「あと何件か」を出すためだけに持っている。**
    ///
    /// ## ⚠ 【未確認】件数とステップ数が交絡している
    ///
    /// 14.13b節が自分で警告している ── `LoRABatchIterator` はデータを無限に周回するので
    /// **ステップ数は件数と独立**であり、既定（4周）では両方が一緒に動いていた。
    /// **「20件で立ち上がった」は「80ステップで立ち上がった」かもしれない。**
    ///
    /// **画面に出すときは必ず【未確認】と併記すること**（`UserTraitsPanel`）。
    static let observedSamplesForLiftoff = 20
}

// MARK: - 木（14.9節）

/// 質問の木。**一覧ではない。**
///
/// ```
/// machine ─┬─ (a: 資源を足す) → verification ─┐
///          └─ (b: まず測る)   → certainty    ─┤
///                                             ├→ granularity ─┬─ (a: 結論だけ) → pushback ─┐
///                                             ┘               └─ (b: 手順つき) → code     ─┤
///                                                                                          ├→ autonomy
///                                                                                          ┘
/// autonomy → attunement → challenge → conflict → values → setback → archetypes → completion
/// ```
///
/// **枝が実在することがこの型の唯一の主張である** ──
/// 1問目の答えで2問目が変わらないなら、木にする意味は無い。
///
/// ## 分岐の根拠
///
/// | 分岐 | なぜその2つに分かれるか |
/// |---|---|
/// | `machine` で「まず測る」→ `certainty` | 測る人にとっての分かれ目は**測っていないことをどう書くか**である。「根拠なく断定するな」は既に答えが出ているので訊かない |
/// | `machine` で「資源を足す」→ `verification` | 逆に**根拠なしの断定を許すか**がまだ分からない。ここが利得の高い問い |
/// | `granularity` で「結論だけ」→ `pushback` | 短く返す人ほど、**反論を挟むかどうか**で出力が大きく変わる |
/// | `granularity` で「手順つき」→ `code` | 長く返す人ほど、**コードを全文出すか差分だけか**の差が大きい（出力トークンは入力の約9倍高い ── 14.2節） |
enum OnboardingQuestionnaire {

    /// 最初の1問。
    ///
    /// **`machine` を根に置いた理由は、14.8節が名指ししている実例だからである。**
    ///
    /// > | 得られた事実 | 消えた誤りの一群 |
    /// > |---|---|
    /// > | **「非力なマシンは制約ではなく手段である」** | 開発機の強化・買い替えの提案すべて |
    /// >
    /// > **1つの事実で、誤りのカテゴリがまるごと消えている。狙うべきはこの形である。**
    ///
    /// **本プロジェクトで最も効いた1件が、好みではなく判断の前提だった。**
    /// 3問しか訊かないなら、1問目はこれである。
    static let rootCategory = "machine"

    /// # 並べ方 —— **仕事と人を交互にする**（2026-09-06 / 利用者の指摘）
    ///
    /// **かつて木は、1〜5問目が全部「仕事の進め方」だった**
    /// （資源の制約 → 確信/検証 → 説明の粒度 → 反論/コード → 手を動かす前に訊くか）。
    /// **人の側（感情・関係・価値判断）は6問目以降に固まっていた。**
    ///
    /// **FR-24 は「仕事の進め方だけでなく、認知・感情・関係・価値判断を扱う」と書いている。**
    /// 軸は揃っていたが、**並び順が要件を裏切っていた。**
    ///
    /// > **14.9節: 上限を決めているのは情報利得ではない。離脱と誤答である。**
    /// > **途中で閉じられる前提なら、順序は要件の一部である。**
    /// > 2問目で閉じられたとき、「あなたを深く知る」と題した画面が採ったものが
    /// > **コードの書式の好みだけ**では、題と中身が食い違う。
    ///
    /// **したがって3問目を人の側（`attunement`）に置き、以後は交互にする。**
    /// **どこで閉じても、両方の半分が採れている状態にする。**
    ///
    /// > **⚠ 並べ替えるとき、枝を潰さないこと。** 最初の試みで
    /// > `granularity` の a/b を同じ行き先にしてしまい、
    /// > **`testTheGranularityAnswerChangesWhatIsAskedNext` が落ちて気づいた。**
    /// > **順序を直すつもりで、適応性（14.9節「質問セットは一覧ではなく木」）を殺していた。**
    /// > **枝が意味を持つのは `machine` と `granularity` の2か所である。** そこは触らない。

    /// **宣言順は、枝が尽きたときの落ち先でもある**（`next(after:choosing:answered:)`）。
    static let all: [OnboardingQuestion] = [
        machine, certainty, verification, granularity, pushback, code, autonomy,
        attunement, challenge, conflict, values, setback, archetypes, completion,
    ]

    static func question(_ category: String) -> OnboardingQuestion? {
        all.first { $0.category == category }
    }

    /// これから訊く1問目。`answered` は**既に `user_traits` に入っている category** である。
    ///
    /// **答え済みの軸は二度と出ない。** 設定画面から再開したとき、
    /// 同じ問いをもう一度見せるのは利用者のエネルギーの純損である
    /// （再確認したいときは `OnboardingViewModel.startReview()` の側が明示的に呼ぶ）。
    static func first(
        answered: Set<String>,
        selectedSides: [String: OnboardingChoice.Side] = [:]
    ) -> OnboardingQuestion? {
        var category = rootCategory
        var visited: Set<String> = []

        while let current = question(category), !visited.contains(category) {
            visited.insert(category)
            guard answered.contains(category) else { return current }
            guard let side = selectedSides[category],
                  let nextCategory = current.next[side] else { break }
            category = nextCategory
        }

        // 手動編集などで選択肢を復元できない場合だけ、宣言順へ退避する。
        return all.first { !answered.contains($0.category) }
    }

    /// 次の1問。**引き金は決定論的である**（16.2節 / 14.4節と同じ規則）。
    ///
    /// > ~~入力の内容を見て判定する~~ ── **推論1回。置かない。**
    ///
    /// **ここに推論を置かないことは、質問の側でも守る。**
    /// 「次に何を訊くべきか」をモデルに決めさせると、**質問1問ごとに推論を1回払う。**
    /// 枝は表として書いてあり、費用は 0 である。
    ///
    /// - Parameter answered: 既に採ってある category。**いま答えたぶんも含めて渡すこと。**
    static func next(
        after question: OnboardingQuestion,
        choosing side: OnboardingChoice.Side,
        answered: Set<String>,
        selectedSides: [String: OnboardingChoice.Side] = [:]
    ) -> OnboardingQuestion? {
        if let nextCategory = question.next[side],
           !answered.contains(nextCategory),
           let next = self.question(nextCategory) {
            return next
        }
        // **枝の行き先が答え済みなら、宣言順で最初の未回答へ落とす。**
        // 木を諦めているのではなく、**同じ問いを二度出さないほうを優先している。**
        // 落ちた先が「予測できる問い」になりうるのは承知のうえで、
        // それでも重複よりは安い（14.9節「答えが予測できるものは利得が低い」＝ 0 ではない）。
        return first(answered: answered, selectedSides: selectedSides)
    }

    // =========================================================================
    //  例文（**ここが実装の主要な作業である** ── 14.8節）
    // -------------------------------------------------------------------------
    //  # 書くときの規則
    //
    //  1. **2つの回答案は、同じことを言っていること。** 片方だけが正しいと、
    //     利用者は様式ではなく正しさを選ぶ。**測っている軸がずれる**
    //  2. **どちらも良い答えであること。** 明らかな駄目な例を並べると、
    //     選択ではなく正解当てになる ── 顕示選好が取れない（FR-26 が空振りする）
    //  3. **題材はこのプロジェクトの実話から採ること。** 抽象的な例文は
    //     「どちらでもいい」を生む。**答えが変わっても出力が変わらない質問は無価値**（14.8節）
    // =========================================================================

    /// **前提: 制約に当たったとき、外しにいくか、回りにいくか。**
    ///
    /// 14.8節が「本プロジェクトで最も効いた1件」として挙げている軸そのもの。
    /// **1つの答えが、誤りのカテゴリをまるごと消す形になっている。**
    static let machine = OnboardingQuestion(
        category: "machine",
        axis: "資源が足りないと分かったとき",
        prompt: "やりたいことが2つあります。いまの予算と時間では、両方は入りません。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: """
                    足せる資源から考えます。予算を上げるか、期限を延ばすか、\
                    人を増やすか。どれが一番動かしやすいですか。
                    """,
                statement: "行き詰まったら資源を足す案を出してよい。増やす・延ばす・人を足すを選択肢として示す"
            ),
            OnboardingChoice(
                side: .b,
                sample: """
                    足りないほうを前提にします。まず2つのどちらが先かを決めて、\
                    小さいほうを実際にやってみて、かかった量を測ります。
                    """,
                statement: "足りないことは制約ではなく手段である。資源を足す提案をせず、まず測る"
            ),
        ],
        next: [.a: "verification", .b: "certainty"]
    )

    /// **断定への態度: 測っていないことを、どう書くか。**
    ///
    /// 「まず測る」と答えた人に訊く。**測る人ほど、測る前の言い方で分かれる。**
    static let certainty = OnboardingQuestion(
        category: "certainty",
        axis: "まだ試していないことの言い方",
        prompt: "このやり方に変えたら、早く終わりますか。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: """
                    なります。手戻りが減るぶん、いまより短くなります。
                    """,
                statement: "見込みでよいので言い切る。留保を並べない"
            ),
            OnboardingChoice(
                side: .b,
                sample: """
                    短くなるはずですが、この条件では試していません【未確認】。\
                    確かめるなら、同じ作業を新旧のやり方で1回ずつやって時間を比べるのが最短です。
                    """,
                statement: "試していないことは【未確認】と明記する。断定と推測を書き分ける"
            ),
        ],
        next: [.a: "attunement", .b: "attunement"]
    )

    /// **根拠への態度: 「実装がある」を「動く」と言うか。**
    ///
    /// 「資源を足す」と答えた人に訊く。**そちらの人には、この軸がまだ分かっていない。**
    static let verification = OnboardingQuestion(
        category: "verification",
        axis: "「終わった」と言ってよい条件",
        prompt: "さっき頼んだこと、もう終わっていますか。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: """
                    終わっています。
                    """,
                statement: "まず結論を返す。留保は求められたときに足す"
            ),
            OnboardingChoice(
                side: .b,
                sample: """
                    手は入れ終わっていますが、通しで確かめたのは1回だけです。\
                    いつもの手順で使えるところまでは見ましたが、\
                    例外的な使い方はまだ試していません。
                    """,
                statement: "「やった」を「できている」と言わない。確かめた範囲と確かめていない範囲を分けて書く"
            ),
        ],
        next: [.a: "attunement", .b: "attunement"]
    )

    /// **説明の粒度。** 14.14節が `category` の例として挙げている軸。
    static let granularity = OnboardingQuestion(
        category: "granularity",
        axis: "説明の粒度",
        prompt: "同じ申請が3回はねられました。窓口では『日付が違う』とだけ言われています。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: """
                    記入日ではなく、発行日を書く欄です。そこを直して出し直してください。
                    """,
                statement: "結論を先に置き、根拠は1行に留める。手順は求められたときだけ書く"
            ),
            OnboardingChoice(
                side: .b,
                sample: """
                    どの日付かを順に見ます。書類には日付欄が2つあり、\
                    上が発行日、下が記入日です。窓口が照合しているのは発行日のほうで、\
                    こちらには記入日が入っています。3回とも同じ欄なので、\
                    そこを発行日に直せば通ります。
                    """,
                statement: "なぜそうなるかまで書く。結論だけでは判断できない"
            ),
        ],
        next: [.a: "pushback", .b: "code"]
    )

    /// **反論するか、従うか。**
    ///
    /// 「結論だけ」と答えた人に訊く。**短く返す人ほど、反論を挟むかで出力が大きく変わる。**
    static let pushback = OnboardingQuestion(
        category: "pushback",
        axis: "反対意見を言う時機",
        prompt: "この案でいきます。そのまま進めてください。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: """
                    進めます。気になる点は、やってみて出てきたら伝えます。
                    """,
                statement: "議論より先に手を動かす。異論は結果を見てから言う"
            ),
            OnboardingChoice(
                side: .b,
                sample: """
                    進める前に1つだけ。この案だと後戻りしにくい所が1か所あります。\
                    そこを承知のうえなら、このまま進めます。
                    """,
                statement: "反対意見があるなら着手前に言う。従う前に1度止める"
            ),
        ],
        next: [.a: "conflict", .b: "conflict"]
    )

    /// **コードの出し方。** 出力トークンは入力の約9倍高い（14.2節）ので、
    /// **この軸は様式であると同時に費用そのものである。**
    static let code = OnboardingQuestion(
        category: "code",
        axis: "直したものの渡し方",
        prompt: "送る文面を1か所だけ直してください。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: """
                    直した全文です。このまま送れます。
                    （書き出しから結びまで、直した1か所を含めて丸ごと）
                    """,
                statement: "そのまま使える完全な形で出す"
            ),
            OnboardingChoice(
                side: .b,
                sample: """
                    3行目だけ直しました。
                    「ご確認ください」→「ご確認いただけますでしょうか」
                    ほかは触っていません。
                    """,
                statement: "変えた所だけ出す。全文は出さない"
            ),
        ],
        next: [.a: "conflict", .b: "conflict"]
    )

    /// **先回りするか、訊いてから動くか。**
    ///
    /// 14.11節② が学習について「勝手に走らせない」と決めているのと同じ軸を、
    /// **編集そのものについて訊いている。**
    static let autonomy = OnboardingQuestion(
        category: "autonomy",
        axis: "手を動かす前に訊くか",
        prompt: "頼まれた資料を作っている途中で、元の数字が1つ間違っていることに気づきました。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: """
                    直しておきました。合計が合っていなかったので、\
                    元の数字のほうを正しい値に置き換えています。
                    """,
                statement: "見つけた問題は直してよい。報告は事後でよい"
            ),
            OnboardingChoice(
                side: .b,
                sample: """
                    数字が1つ合いません。直すか、そのまま出すかを決めてください。\
                    直す場合、合計も変わります。
                    """,
                statement: "手を動かす前に選択肢を出して選ばせる。勝手に直さない"
            ),
        ],
        next: [.a: "values", .b: "values"]
    )

    /// **EQ: 感情と解決のどちらを先に扱うか。**
    /// 共感の有無ではなく、同じ共感と改善をどの順序で届けるかを採る。
    static let attunement = OnboardingQuestion(
        category: "attunement",
        axis: "つらい報告を受けた最初の一言",
        prompt: "大切な発表の直後に『うまくいかなかった』とだけ伝えました。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: "それはきつかったですね。まず、いま一番引っかかっている場面を聞かせてください。整理と次の手は、そのあと一緒に考えます。",
                statement: "つらい報告には感情を先に受け止め、解決はそのあとに置く"
            ),
            OnboardingChoice(
                side: .b,
                sample: "次に変えられる点を一つだけ見つけましょう。その前に、いまは振り返れる状態ですか。それとも少し間を置きますか。",
                statement: "つらい報告には次の一手を示し、感情を扱える状態か確かめる"
            ),
        ],
        next: [.a: "granularity", .b: "granularity"]
    )

    /// **IQ / メタ認知: 同意より思考の更新を優先するか。**
    /// 反対すること自体ではなく、前提を揺らす時機を採る。
    static let challenge = OnboardingQuestion(
        category: "challenge",
        axis: "考えを深めるための反論",
        prompt: "もう十分考えました。この案で決めたいです。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: "決めましょう。ただ、結論を壊しうる前提が一つあります。そこだけ反対側から検査して、耐えたらこの案で進めます。",
                statement: "決定前に結論を壊しうる前提を一度反対側から検査する"
            ),
            OnboardingChoice(
                side: .b,
                sample: "この案で決めます。前提の弱い箇所は実行後に観測できるよう印を付け、結果が外れたらすぐ戻せる形にします。",
                statement: "決断を尊重し、反論より観測と撤回可能性で判断を支える"
            ),
        ],
        next: [.a: "autonomy", .b: "autonomy"]
    )

    /// **関係修復: 強い否定を受けたとき、どう理解を戻すか。**
    static let conflict = OnboardingQuestion(
        category: "conflict",
        axis: "『全然違う』と言われたあとの戻り方",
        prompt: "Sophia の提案に『全然違う』と返しました。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: "分かりました。私の説明は置きます。どの前提を取り違えたか、一番大きいものを一つ教えてください。そこから組み直します。",
                statement: "強く否定されたら弁明せず、誤った前提を一つ聞いて組み直す"
            ),
            OnboardingChoice(
                side: .b,
                sample: "私は『速さを優先したい』と受け取りました。違うのは、優先順位、手段、それとも目指す結果のどこですか。",
                statement: "強く否定されたら自分の解釈を開示し、ずれた層を特定する"
            ),
        ],
        next: [.a: "challenge", .b: "challenge"]
    )

    /// **価値観: 二つの正しさが衝突したとき、何を守るか。**
    static let values = OnboardingQuestion(
        category: "values",
        axis: "納期と品質が同時に守れないとき",
        prompt: "期限を守るには、品質を一段落とす必要があります。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: "期限を守ります。落とす品質を明示し、あとで戻す項目と期限を同時に決めて、見えない借金にはしません。",
                statement: "価値が衝突したら期限を守り、落とす品質と回収期限を明示する"
            ),
            OnboardingChoice(
                side: .b,
                sample: "品質を守ります。その代わり範囲を削り、何を今回は出さないかを合意して、期限内に小さく完成させます。",
                statement: "価値が衝突したら品質を守り、範囲を削って期限と両立させる"
            ),
        ],
        next: [.a: "setback", .b: "setback"]
    )

    /// **心理的回復: 失敗を、前進と理解のどちらへ先に変換するか。**
    static let setback = OnboardingQuestion(
        category: "setback",
        axis: "失敗のあとに意味を作る順序",
        prompt: "三日かけた案が使えないと分かりました。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: "三日を回収できるものに分けます。残せる判断を一つ拾い、今日中に試せる次の案へつなげましょう。原因分析はそのあとです。",
                statement: "失敗のあとは残せるものを拾い、次の小さな前進を先に作る"
            ),
            OnboardingChoice(
                side: .b,
                sample: "次へ行く前に、どの前提がいつ崩れたかを一度だけ辿ります。同じ三日をもう一度失わない規則を作ってから再開します。",
                statement: "失敗のあとは原因と崩れた前提を言語化してから次へ進む"
            ),
        ],
        next: [.a: "archetypes", .b: "archetypes"]
    )

    /// **類型への態度: 属性を真実ではなく、自己理解の鏡として使うか。**
    /// 血液型や生年月日から性格を断定しない。本人がその物語をどう受け取るかを採る。
    static let archetypes = OnboardingQuestion(
        category: "archetypes",
        axis: "生年月日や血液型などの類型情報",
        prompt: "生年月日や血液型も、私を理解する材料にしてほしい。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: "使います。ただし性格の答えにはせず、仮説の入口にします。類型の説明をあなたがどう受け止めるかを聞き、会話の事実と照合します。",
                statement: "類型情報は仮説の入口に使い、本人の受け止め方と観察で確かめる"
            ),
            OnboardingChoice(
                side: .b,
                sample: "属性から性格は決めません。必要なら年齢や生活段階だけを文脈に使い、あなたが実際に選んだ言葉と行動を根拠にします。",
                statement: "属性から性格を推定せず、生活文脈と実際の言動だけを根拠にする"
            ),
        ],
        next: [.a: "completion", .b: "completion"]
    )

    /// **完了観: 作った時点か、届いて確かめた時点か。**
    static let completion = OnboardingQuestion(
        category: "completion",
        axis: "『終わった』と言ってよい地点",
        prompt: "頼んだ変更は、もう終わりましたか。",
        choices: [
            OnboardingChoice(
                side: .a,
                sample: "実装は終わりました。テストと公開確認は次の工程として分けて報告します。",
                statement: "実装完了と検証完了を分け、作り終えた時点を完了として報告する"
            ),
            OnboardingChoice(
                side: .b,
                sample: "まだです。実装は終わりましたが、テストと実際に届いた画面の確認まで通してから『終わった』と報告します。",
                statement: "実装・テスト・利用地点での確認まで通してから完了と報告する"
            ),
        ],
        next: [:]
    )
}
