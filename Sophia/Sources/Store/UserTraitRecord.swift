import Foundation
import GRDB

// MARK: - 綴りを型と DB で一致させる（第8章 `messages.role` と同じ約束）
//
// `messages.role` は CHECK 制約と `MessageRole` の rawValue が一致していて、
// `StoreSchemaTests` が `MessageRole.allCases` で両方向を検査している
// （知らない値は入らない / 宣言した値は全部入る）。
// **利用者像の3つの列にも同じ約束を適用する。**
//
// ⚠ 14.14節の生SQL には CHECK 制約が**書かれていない。**
// 節の本文が許される値を列挙している（`'content'` or `'style'` など）ので、
// **その列挙を DB 側の制約として書き下ろした。** 14.14節からの意図的な逸脱であり、
// 設計書の担当者に反映してもらうこと。

/// `user_traits.kind`（14.14節 / FR-25）。
///
/// **この2つを混ぜないことが 14.14節の設計判断そのものである** ──
/// 「同じ領域に混ぜると、陳腐化した内容が様式まで汚す」。
/// 列を分けるだけでは足りず、**更新経路も分けてある**
/// （`reviseTrait` = 内容は上書き / `reinforceTrait` = 様式は確信度を上げる）。
enum TraitKind: String, Sendable, Codable, Equatable, CaseIterable,
                DatabaseValueConvertible {

    /// **内容。** 職種・技術スタック・いまの案件（14.8節）。
    /// 自己申告で正確に取れるが**陳腐化する。** `expiresAt` を持てるのはこちらだけ。
    case content

    /// **様式。** 説明の粒度・断定への態度・何に苛立つか（14.8節）。
    /// 自己申告では取れないので選択で採る（FR-26）。**蓄積し、強化される。期限を持たない。**
    case style
}

/// `user_traits.source`（14.14節）。**NFR-12（何を根拠にしたか辿れる）の実現手段である。**
///
/// ## 出所によって確からしさが違う
///
/// 14.14節が `'translation_edit'` を「**最も密度の高い出所**」と名指ししている
/// （14.5節: 利用者が翻訳文を直すたび、対になった学習データが1件できる）。
/// 一方 14.8節は、自己申告が様式について当てにならないことを繰り返し書いている
/// （宣言選好と顕示選好の乖離。正直さではなく内省の限界）。
///
/// **したがって `defaultConfidence` は出所ごとに違う。**
enum TraitSource: String, Sendable, Codable, Equatable, CaseIterable,
                  DatabaseValueConvertible {

    /// 初回の質問（FR-24 / FR-26）。二択で選ばせたもの。
    case onboarding

    /// 会話中に利用者が訂正した（FR-27 / 14.9節）。**顕示選好である。**
    case correction

    /// **利用者が翻訳文を直した**（14.5節）。原文と直した文が対で取れる。
    ///
    /// 14.14節が「最も密度の高い出所になる」と書いているのはこれである。
    /// **翻訳層そのものは未実装（別担当）なので、いまこの値を書き込む経路は無い。**
    /// 先に置いてあるのは、出所の綴りを後から足すと DB の制約を打ち直すことになるため。
    case translationEdit = "translation_edit"

    /// 設定画面で利用者が自分で書いた（FR-28）。
    case manual

    /// 新しく採ったときの確信度の初期値。
    ///
    /// ## ⚠ 【未確認】この4つの数字に測定の裏付けは無い
    ///
    /// **測ってあるのは順序の根拠だけである** ── 14.14節が `translation_edit` を
    /// 最も密度が高いとし、14.8節が自己申告（`onboarding` / `manual`）を疑っている。
    /// **絶対値は仮置きであって、意味を持つのは
    /// `UserTraitDefaults.trainingConfidenceThreshold` との大小関係だけである。**
    ///
    /// | 出所 | 初期値 | 閾値 0.7 に一度で届くか |
    /// |---|--:|---|
    /// | `translationEdit` | 0.75 | **届く** |
    /// | `correction` | 0.65 | 強化1回で届く |
    /// | `onboarding` / `manual` | 0.5（14.14節の DEFAULT と同値） | 強化2回で届く |
    ///
    /// ## `onboarding` と `manual` に差を付けなかった理由
    ///
    /// 14.8節を素直に読むと、**二択で採った `onboarding` のほうが
    /// 自分で打ち込んだ `manual` より様式については確からしい**（行動は様式を漏らす）。
    /// 逆に**内容については `manual` のほうが正確**（事実は自己申告で取れる）。
    /// **つまり正しい既定値は `kind` と `source` の組で決まる。**
    /// **その差は測っていないので、数字を発明せず同値にしてある。**
    var defaultConfidence: Double {
        switch self {
        case .translationEdit: 0.75
        case .correction: 0.65
        case .onboarding, .manual: 0.5
        }
    }
}

/// `user_traits.placement`（14.14節）。**本章の中心にある列である。**
///
/// > 既定が `stored`（＝どこにも送らない）であることを、型で表明する（14.7節）。
/// > 16.2節が `idle` / `armed` を型で守ったのと同じ手である。
///
/// **「機能があること」と「いま費用を払っていること」を分ける**ための型であり、
/// 既定で毎ターンの費用が 0 であることが、この設計の主張そのものである（14.15節 / FR-29）。
/// **訂正の向き**（FR-31 / 2026-09-06）。
///
/// ## なぜ向きが要るのか
///
/// 利用者の思想（`docs/PHILOSOPHY.md`）:
///
/// > **人は信じたい事を信じる。かといって嘘を言ったらダメ。
/// > その匙加減がバカと思われるか思われないかのバランス。**
///
/// **「バカに見える」には2種類あり、原因が正反対である。**
///
/// | 訂正 | 何がずれていたか |
/// |---|---|
/// | 「そんな断言できないだろ」 | **踏み込みすぎ**（`overreach`） |
/// | 「で、結局どっちなの」 | **逃げすぎ**（`hedging`） |
///
/// > **⚠ 向きを持たせずに記録すると、この2つが同じ「訂正1件」になる。**
/// > **焼き込めば打ち消し合って、何も学ばない。**
/// > **向きは記録する時点でしか付けられない** ── 後から本文を読み返しても復元できない。
///
/// `nil` は「向きの無い訂正」である（言い方だけを直した場合など）。
/// **無理に二択へ倒さないこと** ── 倒すと、向きの無いものが偽の向きを持つ。
enum TraitDirection: String, Sendable, Codable, Equatable, CaseIterable,
                     DatabaseValueConvertible {

    /// 踏み込みすぎた。**根拠より強く言った。**
    case overreach

    /// 逃げすぎた。**正しいが使えない答えを返した。**
    case hedging

    /// 画面に出す1行（FR-28）。
    var label: String {
        switch self {
        case .overreach: "踏み込みすぎ"
        case .hedging: "逃げすぎ"
        }
    }
}

enum TraitPlacement: String, Sendable, Codable, Equatable, CaseIterable,
                     DatabaseValueConvertible {

    /// **既定。毎ターンの費用は 0。** 採れたが、まだ何にも反映していない（14.7節）。
    ///
    /// **効かないのは欠陥ではなく設計である。** 効かせるには学習が要り、
    /// 学習には評価が要る。評価していない知見を効かせると誤読を強化する（14.16節⑤）。
    case stored

    /// 翻訳役の重みに入っている（14.11節）。**毎ターンの費用は 0 のまま**である
    /// ── 重みは入力トークンを消費しない。ここが 14.0節で毎ターン注入を撤回した理由。
    ///
    /// **手で書かないこと。** 焼いた事実（`user_trait_bakes`）と
    /// アダプタが有効かどうかから導出される（`Store.recalculateTraitPlacements`）。
    case translating

    /// 必要時に引く（14.3節）。内容向けの枠。
    ///
    /// **初版では空でよい**（14.3節: 「枠だけ用意して、引き金の規則だけ決めておく」）。
    /// 空の枠を先に置くのは、後から足すと引き金が推論になりがちだからである。
    case retrieved
}

/// 利用者像の永続化にかかわる定数。
///
/// **`SophiaDefaults.InputBudget`（`Sources/Shared/ChatOptions.swift`）と
/// 同じ場所に置けていない。** 14.4節は閾値を `InputBudget` と同じ場所に置けと書いているが、
/// あれは Shared 層（別担当の持ち物）である。**ここの数字が予算表と衝突したら、
/// 別々に決めた数字が衝突した 2026-08-18 の教訓の再演になる。**
enum UserTraitDefaults {

    /// **重みへ移す関門**（14.14節）。これを下回る像は学習データに入らない。
    ///
    /// > 再学習は評価を伴う（14.11節③）ので、**評価1回に見合うだけ
    /// > 確からしいものしか通さない。**
    ///
    /// **【未確認】0.7 に測定の裏付けは無い。** 14.14節が定めているのは
    /// 「閾値がある」ことだけで、値は書かれていない。
    /// **0.5（列の DEFAULT）にすると既定値が全部通ってしまい、関門が関門でなくなる**
    /// ので、既定より上に置いてある。
    static let trainingConfidenceThreshold: Double = 0.7

    /// 強化1回で上がる確信度（14.14節「様式は追記して確信度を上げる」）。
    ///
    /// **【未確認】0.1 にも裏付けは無い。** 意味を持つのは
    /// 「`onboarding` の 0.5 が閾値 0.7 に届くまでに2回かかる」という回数のほうである。
    static let reinforcementStep: Double = 0.1

    /// 確信度を歩幅ぶん上げて、**0.0…1.0 に収める。**
    ///
    /// ## `min(1.0, confidence + step)` と書いてはいけない
    ///
    /// Swift の `min(_:_:)` は **`y < x ? y : x`** である。
    /// `y` が NaN なら比較が必ず false になり、**`x`（＝1.0）がそのまま返る。**
    /// 頭打ちのつもりの `min` が、**NaN を最大値へ昇格させる装置**になる ──
    /// 1.0 は関門（`trainingConfidenceThreshold` = 0.7）の上なので、
    /// **その像は一撃で学習データに入り、履歴にも「確信度 1.0」の版が残る**（NFR-12 が嘘をつく）。
    ///
    /// **したがって NaN / ±∞ は `min` / `max` へ渡す前に落とす。**
    /// 有限でない歩幅は歩幅ではないので、**確信度を1ミリも動かさない。**
    /// 例外にしていないのは、`reinforceTrait` が
    /// **強化のたびに落ちうる関数**になるのを避けるためである（頭打ちを制約で受けないのと同じ理由）。
    ///
    /// > **14.13c節（2026-08-19 の決定）を壊さないこと。**
    /// > 意味を持つのは閾値との**大小**だけであり、`onboarding`（0.5）が
    /// > 関門（0.7）に届かないという順序がここで崩れてはならない。
    /// > 歩幅の異常値を「上へ」丸めると、質問だけで焼かれる像ができてしまう。
    static func reinforced(_ confidence: Double, by step: Double) -> Double {
        // 現在値そのものが有限でないことは DB の CHECK と NOT NULL が防いでいるが、
        // **防いでいる側を当てにして NaN を min へ渡さない。**
        guard confidence.isFinite else { return 0.0 }
        let floored = Swift.min(1.0, Swift.max(0.0, confidence))
        guard step.isFinite else { return floored }
        return Swift.min(1.0, Swift.max(0.0, floored + step))
    }
}

// MARK: - user_traits

/// `user_traits` テーブルの1行（DESIGN.md 14.14節）。
///
/// ## `profiles`（第8章）とは別物である
///
/// | | `profiles`（FR-05） | **`user_traits`**（FR-24〜29） |
/// |---|---|---|
/// | 誰の情報か | **アシスタント側**の役割 | **利用者側**の像 |
/// | 例 | 「相談相手」「コード書き」 | 「非力なマシンは制約でなく手段と考える人」 |
/// | 切り替わるか | 利用者が明示的に切り替える | **切り替えない。常に同じ人** |
///
/// **本書と要件は後者を一貫して「利用者像」と呼ぶ。**「プロファイル」は前者に予約されている。
///
/// ## この行は「いまの状態」であって、原本ではない
///
/// `statement` と `confidence` は訂正のたびに書き換わる。
/// **書き換える前の値は `user_trait_revisions` に必ず追記されており、消えない**
/// （第8.4節「原ログを要約で上書きしない」と同じ規則）。
/// `placement` と `adapterGen` も `user_trait_bakes` から導出される派生値である。
///
/// **したがって「なぜそう振る舞うのか」を答えるときは、この行ではなく
/// `user_trait_revisions` と `user_trait_bakes` を読むこと。**
struct UserTraitRecord: Codable, Sendable, Equatable, Identifiable,
                        FetchableRecord, PersistableRecord {

    static let databaseTableName = "user_traits"

    var id: String

    /// 内容 / 様式。CHECK 制約つき。
    var kind: TraitKind

    /// 分類。`'machine'` / `'stack'` / `'granularity'` / `'tone'` など（14.14節）。
    ///
    /// **CHECK 制約を付けていない唯一の分類列である。** 14.14節が挙げているのは
    /// 例示（「など」）であって閉じた列挙ではなく、**閉じていないものを
    /// CHECK で閉じると、分類を1つ増やすたびにマイグレーションが要る。**
    /// `profiles.params_json` を列に展開しなかったのと同じ判断（第8章）。
    var category: String

    /// **言語化された文。本体である。**
    ///
    /// > **重みへ焼き込んだ後も消さない**（14.11節④ / NFR-12）。
    /// > **重みは記録ではなく、複製である。原本は DB に残す。**
    /// > NFR-12（何を根拠にしたか辿れる）を満たしているのは重みではなく DB のほうである。
    var statement: String

    /// どこから来たか。NFR-12 の実現手段。
    var source: TraitSource

    /// 確信度。**飾りではない。重みへ移す関門である**（14.14節）。
    /// `0.0...1.0` に CHECK 制約がある ── 範囲外の値は閾値を素通りしてしまう。
    var confidence: Double

    /// いまどこに置かれているか。**既定は `stored`（＝どこにも送らない）。**
    ///
    /// **導出値である。** 直接書き換えてよいのは `retrieved` への出し入れだけで、
    /// `translating` は焼いた事実から計算される（`Store.setTraitPlacement` が拒否する）。
    var placement: TraitPlacement

    /// **ずれの向き**（FR-31）。`nil` は向きの無い訂正。
    ///
    /// **`source` が `.correction` / `.translationEdit` のときにだけ意味がある。**
    /// 質問（`onboarding`）に向きは無い ── **あれは事前分布であって、
    /// 「ずれた」という事象ではない**（14.13c）。
    var direction: TraitDirection?

    /// いま効いているアダプタの世代。**NULL なら未反映**（14.14節）。
    ///
    /// ⚠ **これも導出値であり、履歴ではない。**
    /// 14.14節の `adapter_gen` は整数1本なので、
    /// **どのアダプタ（翻訳役か本体か）に入ったのかも、
    /// 過去にどの世代へ入ったのかも表せない。**
    /// その2つは `user_trait_bakes` が持っている。
    /// **世代を戻したとき（14.11節④）に必要なのは後者のほうである。**
    var adapterGen: Int?

    /// 期限。**内容にだけ入れる。様式は期限を持たない**（14.14節）。
    ///
    /// この約束は CHECK 制約になっている（`kind <> 'style' OR expires_at IS NULL`）。
    /// コメントではなく DB で守っているのは、**陳腐化した内容が様式まで汚す**のを
    /// 防ぐことが 14.14節の設計判断そのものだからである。
    var expiresAt: Date?

    var createdAt: Date

    /// この行が最後に変わった時刻。**文・確信度・置き場所のどれが変わっても進む。**
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case category
        case statement
        case source
        case confidence
        case placement
        case direction
        case adapterGen = "adapter_gen"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // ⚠ 14.14節の生SQL は時刻列を **TEXT** と書いているが、**INTEGER にしてある。**
    // 理由は `SophiaTimestamp` の型コメントに書かれた約束である ──
    // 第8章が単位を書いていなかったのを「Unixエポックからのミリ秒」で確定させ、
    // 「以後この1か所だけを参照する」と決めてある。
    // **同じDBの中に TEXT の時刻と INTEGER の時刻が混在すると、
    // 表をまたぐ比較・並び替えのたびにどちらの綴りかを覚えていないと書けなくなる。**
    // `StoreSchemaTests.testTimestampsAreActuallyStoredAsIntegers` が
    // 既存の表について同じことを見張っている。**設計書の担当者に反映してもらうこと。**
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .millisecondsSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .millisecondsSince1970
    }

    init(
        id: String = UUID().uuidString,
        kind: TraitKind,
        category: String,
        statement: String,
        source: TraitSource,
        confidence: Double? = nil,
        placement: TraitPlacement = .stored,
        direction: TraitDirection? = nil,
        adapterGen: Int? = nil,
        expiresAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.category = category
        self.statement = statement
        self.source = source
        self.confidence = confidence ?? source.defaultConfidence
        self.placement = placement
        self.direction = direction
        self.adapterGen = adapterGen
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// 学習データに入れてよいか（14.14節の関門）。
    ///
    /// **`placement` を見ていないのは意図的である。**
    /// 既に v1 に焼いた像も v2 の学習データに入らなければ、
    /// **世代を重ねるたびに前の世代が覚えたことを忘れる。**
    /// 14.11節③（世代を並べて残し、勝ったときだけ採用する）はそれでは成立しない。
    func qualifiesForTraining(
        minimumConfidence: Double = UserTraitDefaults.trainingConfidenceThreshold,
        now: Date = Date()
    ) -> Bool {
        guard confidence >= minimumConfidence else { return false }
        if let expiresAt, expiresAt <= now { return false }
        return true
    }
}

// MARK: - user_trait_revisions

/// `user_trait_revisions` テーブルの1行。**追記専用。書き換えない。**
///
/// ## 14.14節には無い表である。足した理由
///
/// 14.14節は更新方針を「**内容は上書き**、様式は追記して確信度を上げる」と書いている。
/// **`statement` を上書きすると、上書きされた文はどこにも残らない。** これは
///
/// - **第8.4節**「`messages` の `content` / `thinking` を、要約で置き換えない。
///   文脈圧縮を実装するときは、要約を**別テーブル**に持つ」
/// - **NFR-12**「利用者像を根拠に応答したときは、何を根拠にしたか利用者が辿れる」
///
/// の両方に反する。**同じ規則を利用者像にも適用し、上書きの前に必ずここへ1行積む。**
///
/// ## とくに効くのは、焼いた後に訂正されたときである
///
/// v1 のアダプタに焼いた文が、あとから訂正されたとする。
/// **重みの中にあるのは訂正前の文である。**
/// `user_traits.statement` だけを見て「これが根拠です」と説明すると**嘘になる。**
/// `user_trait_bakes.revision` がどの版を焼いたかを持っており、
/// その版の文がここから引ける。
///
/// ## 消えるのは、利用者が消したときだけ
///
/// `ON DELETE CASCADE` が付いている。**FR-28「削除したものは完全に消える」は
/// 履歴にも及ぶ。** 訂正で消えないことと、利用者が消せることは両立する ──
/// **前者はシステムの都合による上書き、後者は利用者の明示的な意思**であり、別の操作である。
struct UserTraitRevisionRecord: Codable, Sendable, Equatable, Identifiable,
                                FetchableRecord, PersistableRecord {

    static let databaseTableName = "user_trait_revisions"

    var id: String

    var traitID: String

    /// 1 から始まる連番。**1 が最初に言語化された文である。**
    /// `(trait_id, revision)` に UNIQUE 制約があり、同じ版が二重に積まれない。
    var revision: Int

    /// **その時点の文。二度と書き換えない。**
    var statement: String

    /// その時点の確信度。
    var confidence: Double

    /// **その版を作った出所。** `user_traits.source` とは違いうる ──
    /// 初回は `onboarding` でも、訂正した版は `correction` である。
    /// **「いつ、どこから得た情報か」に答えるのはこの列である**（NFR-12）。
    var source: TraitSource

    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case traitID = "trait_id"
        case revision
        case statement
        case confidence
        case source
        case createdAt = "created_at"
    }

    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .millisecondsSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .millisecondsSince1970
    }

    init(
        id: String = UUID().uuidString,
        traitID: String,
        revision: Int,
        statement: String,
        confidence: Double,
        source: TraitSource,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.traitID = traitID
        self.revision = revision
        self.statement = statement
        self.confidence = confidence
        self.source = source
        self.createdAt = createdAt
    }
}
