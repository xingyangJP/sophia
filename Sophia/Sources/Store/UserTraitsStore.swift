import Foundation
import GRDB

/// **いま重みに入っている1件**（14.15節「いま重みに入っている像の一覧」/ FR-28）。
///
/// ## 2つの文を並べて持っているのが要点である
///
/// | | 何の文か |
/// |---|---|
/// | `trait.statement` | **いまの文。** 訂正されていれば新しいほう |
/// | `baked.statement` | **重みの中にある文。** 焼いた時点の版 |
///
/// **この2つは食い違いうる** ── 焼いた後に訂正すれば必ずずれる。
/// **「なぜそう振る舞うのか」に答えるのは `baked` のほうである**（NFR-12）。
/// `trait.statement` を根拠として表示すると、**訂正済みの文を根拠だと言ってしまう。**
struct BakedStatement: Sendable, Equatable {

    /// 利用者像の現在の状態。
    var trait: UserTraitRecord

    /// **重みに焼かれた時点の版。**
    var baked: UserTraitRevisionRecord

    /// 焼いた後に訂正されているか。**true なら、重みは古い文で動いている。**
    ///
    /// 14.11節④の回復手順（世代を戻す / 外す / 翻訳層ごと切る）を
    /// 利用者へ勧める判断材料になる。
    var hasDivergedSinceBaking: Bool { trait.statement != baked.statement }
}

/// 利用者像の永続化（DESIGN.md 第14章 / FR-24〜29 / NFR-11・12）。
///
/// ## この層が引き受けるのは「貯める」ところまでである
///
/// 14.7節が既定を **`stored` ＝ 貯めるが、送らない**と決めている。
///
/// > 採れた知見が即座に効かないのは、欠陥ではなく設計である。
///
/// **貯めるだけなら費用は 0 で、1件も失われない**（14.13節の梯子の段0 ──
/// 「常に成立する」段）。**この層は、その段0を完成させるものである。**
/// 学習が 16GB で回るかにも、必要件数が数十件か数千件か（14.16節⑦）にも依存しない。
///
/// ## NFR-11（縮退）はこの既定で自明に満たされる
///
/// 何も反映していない状態が既定なので、**利用者像が無くても・壊れていても
/// 会話はいまと同じに成立する。**
///
/// ## 費用の勘定（14.15節 / FR-29）
///
/// **この層が毎ターン消費するトークンは 0 である。**
/// `stored` の像は誰にも送られず、`translating` の像は重みの中にいる（入力に載らない）。
/// **「毎ターン 0」と出すことがこの設計の主張そのものである**（14.15節）。
extension Store {

    // MARK: - 貯める（14.7節）

    /// 利用者像を1件記録する。**この時点ではどこにも送られない**（`placement = .stored`）。
    ///
    /// 併せて `user_trait_revisions` に第1版を積む。**同じトランザクションで行う。**
    /// 2文に分けると、本体だけあって履歴の無い像ができうる ──
    /// `appendMessage` が会話の `updated_at` を同じトランザクションで進めているのと同じ理由。
    ///
    /// - Parameters:
    ///   - confidence: 省略すると `source.defaultConfidence`。
    ///     **出所によって確からしさが違う**（14.5節 / 14.8節 / 14.14節）。
    ///   - expiresAt: **内容にだけ入れられる。** 様式に入れると CHECK 制約で落ちる。
    /// - Throws: 文に NUL が入っていれば `StoreFailure.textContainsNUL`（下記 `rejectNUL`）。
    @discardableResult
    func recordTrait(
        kind: TraitKind,
        category: String,
        statement: String,
        source: TraitSource,
        confidence: Double? = nil,
        expiresAt: Date? = nil,
        id: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> UserTraitRecord {
        try Self.rejectNUL(statement, field: "statement")
        try Self.rejectNUL(category, field: "category")
        let record = UserTraitRecord(
            id: id,
            kind: kind,
            category: category,
            statement: statement,
            source: source,
            confidence: confidence,
            expiresAt: expiresAt.map(SophiaTimestamp.truncated),
            createdAt: SophiaTimestamp.truncated(now)
        )
        let revision = UserTraitRevisionRecord(
            traitID: record.id,
            revision: 1,
            statement: record.statement,
            confidence: record.confidence,
            source: record.source,
            createdAt: record.createdAt
        )
        try write { db in
            try record.insert(db)
            try revision.insert(db)
        }
        return record
    }

    // MARK: - 更新経路は kind ごとに分ける（14.14節）
    //
    // > **`kind` で内容と様式を分ける。** 同じ領域に混ぜると
    // > 陳腐化した内容が様式まで汚す。**列を分けるだけでは足りず、更新経路も分けること** ──
    // > 内容は上書き、様式は追記して確信度を上げる。
    //
    // したがって下は2つの別々の関数である。**片方に統合しないこと。**

    /// **内容を上書きする**（14.14節「内容は上書き」）。訂正されたときの経路。
    ///
    /// ## 上書きするのは `user_traits` の1行だけである
    ///
    /// **前の文は `user_trait_revisions` に残る。消えない。**
    /// 第8.4節が `messages.content` について定めた約束
    /// （**原ログを要約で上書きしない。要約は別テーブルに持つ**）を、
    /// そのまま利用者像に適用している。
    ///
    /// **とくに焼いた後の訂正で効く。** 重みの中にあるのは訂正**前**の文であり、
    /// `user_trait_bakes.revision` がどの版かを指している。
    /// 履歴が無いと、その版の文を二度と表示できない（NFR-12 が破れる）。
    ///
    /// - Parameter confidence: 省略すると**確信度は据え置き**。
    ///   訂正されたことをもって上げたいなら `reinforceTrait` を続けて呼ぶこと
    ///   （2つの操作を1つにまとめない ── 「訂正 ＝ 確信が上がる」は自明ではない）。
    /// **会話中の訂正を1件記録する**（FR-27 / FR-31 / 2026-09-06）。
    ///
    /// ## これが無いと、学習は永久に始まらない
    ///
    /// `891c15e` が自分でこう書いている ──
    /// **「使用中の訂正を採る経路がまだ無く、無いと学習は永久に始まらない。」**
    /// 質問（0.5）は関門（0.7）に届かないと決めたので（14.13c）、
    /// **関門を越える材料はここからしか出てこない。**
    ///
    /// ## 同じ軸を二度訂正されたら、強化する
    ///
    /// **新しい行を増やさない。** 増やすと「同じことを2回言われた」が
    /// **「別々の弱い像が2つある」**になり、確信度が上がらない。
    ///
    /// | 回 | 確信度 | 関門(0.7) |
    /// |---|--:|---|
    /// | 1回目（新規） | **0.65** | 届かない |
    /// | **2回目（強化 +0.1）** | **0.75** | **越える** |
    ///
    /// > **一度訂正しただけでは焼かれない。二度目で焼かれる。**
    /// > **これは意図した設計である** ── 気まぐれの1回で重みが変わると、
    /// > **その人ではなく、その日の気分を焼くことになる。**
    ///
    /// - Parameter direction: **ずれの向き**（FR-31）。`nil` は向きの無い訂正。
    ///   **後から埋めないこと** ── 本文からは復元できない。
    @discardableResult
    func recordCorrection(
        kind: TraitKind = .style,
        category: String,
        statement: String,
        direction: TraitDirection?,
        now: Date = Date()
    ) throws -> UserTraitRecord {
        try Self.rejectNUL(statement, field: "statement")
        try Self.rejectNUL(category, field: "category")
        let stamp = SophiaTimestamp.truncated(now)

        // **探すのと書くのを1つのトランザクションに入れる。**
        // 分けると、探した直後に別の経路が同じ軸を作った場合、
        // **同じ軸の像が2行できて確信度が上がらない**（＝永久に関門へ届かない）。
        return try write { db in
            let existing = try UserTraitRecord.fetchOne(
                db, sql: "SELECT * FROM user_traits WHERE category = ? LIMIT 1",
                arguments: [category])

            guard let current = existing else {
                // 初回。**確信度は `source.defaultConfidence`（0.65）。まだ関門に届かない。**
                let record = UserTraitRecord(
                    kind: kind, category: category, statement: statement,
                    source: .correction, direction: direction,
                    createdAt: stamp)
                try record.insert(db)
                return record
            }

            // 2回目以降。**本文を差し替え、確信度を上げ、向きを書く。**
            // 旧版は `user_trait_revisions` へ追記されるので消えない（NFR-12）。
            let raised = UserTraitDefaults.reinforced(
                current.confidence, by: UserTraitDefaults.reinforcementStep)
            try Self.appendRevision(
                db, traitID: current.id, statement: statement,
                confidence: raised, source: .correction, at: stamp)
            try db.execute(
                sql: """
                    UPDATE user_traits
                       SET statement = ?, source = ?, confidence = ?,
                           direction = ?, updated_at = ?
                     WHERE id = ?
                    """,
                arguments: [
                    statement, TraitSource.correction.rawValue, raised,
                    direction?.rawValue, SophiaTimestamp.milliseconds(from: stamp),
                    current.id,
                ])
            guard let updated = try UserTraitRecord.fetchOne(
                db, sql: "SELECT * FROM user_traits WHERE id = ?", arguments: [current.id]
            ) else {
                throw StoreFailure.traitNotFound(id: current.id)
            }
            return updated
        }
    }

    func reviseTrait(
        id: String,
        statement: String,
        source: TraitSource,
        confidence: Double? = nil,
        now: Date = Date()
    ) throws {
        try Self.rejectNUL(statement, field: "statement")
        let stamp = SophiaTimestamp.truncated(now)
        try write { db in
            guard let current = try UserTraitRecord.fetchOne(
                db, sql: "SELECT * FROM user_traits WHERE id = ?", arguments: [id]
            ) else {
                throw StoreFailure.traitNotFound(id: id)
            }
            let newConfidence = confidence ?? current.confidence
            try Self.appendRevision(
                db,
                traitID: id,
                statement: statement,
                confidence: newConfidence,
                source: source,
                at: stamp
            )
            try db.execute(
                sql: """
                    UPDATE user_traits
                       SET statement = ?, source = ?, confidence = ?, updated_at = ?
                     WHERE id = ?
                    """,
                arguments: [
                    statement, source.rawValue, newConfidence,
                    SophiaTimestamp.milliseconds(from: stamp), id,
                ]
            )
        }
    }

    /// **様式を強化する**（14.14節「様式は追記して確信度を上げる」）。文は変えない。
    ///
    /// 同じ様式が別の場面でもう一度観測されたときに呼ぶ。
    /// **確信度が `UserTraitDefaults.trainingConfidenceThreshold` を超えると、
    /// この像は学習データに入る資格を得る**（14.14節の関門）。
    ///
    /// 文が変わらなくても `user_trait_revisions` に1行積む。
    /// **「なぜこの像の確信度が 0.9 なのか」を後から辿れるのは、この履歴だけである**（NFR-12）。
    ///
    /// - Parameter step: **有限でない歩幅（NaN / ±∞）は歩幅として扱わない。**
    ///   確信度は1ミリも動かない（`UserTraitDefaults.reinforced(_:by:)`）。
    ///   歩幅は既定値つきの引数であって定数ではなく、**計算で決めた瞬間に NaN が来る**
    ///   （0除算・空集合の平均）。関門（14.14節）を素通りさせないため、ここで落とす。
    /// - Returns: 強化後の確信度。**0.0…1.0 に収まる。** 1.0 で頭打ちになる。
    @discardableResult
    func reinforceTrait(
        id: String,
        source: TraitSource,
        step: Double = UserTraitDefaults.reinforcementStep,
        now: Date = Date()
    ) throws -> Double {
        let stamp = SophiaTimestamp.truncated(now)
        return try write { db in
            guard let current = try UserTraitRecord.fetchOne(
                db, sql: "SELECT * FROM user_traits WHERE id = ?", arguments: [id]
            ) else {
                throw StoreFailure.traitNotFound(id: id)
            }
            // CHECK (confidence BETWEEN 0 AND 1) があるので、頭打ちはここで行う。
            // 制約で落として例外にすると、**強化のたびに落ちうる関数**になる。
            //
            // ⚠ `min(1.0, current.confidence + step)` と書いてはいけない。
            // Swift の `min` は `y < x ? y : x` であり、**NaN との比較は必ず false** なので
            // `x`（＝1.0）が返る。**頭打ちのつもりの min が、NaN を最大値へ昇格させる。**
            // 1.0 は関門（0.7）の上なので、その像はそのまま学習データに入り、
            // 履歴にも「確信度 1.0」の版が残って NFR-12 が嘘をつく。
            let raised = UserTraitDefaults.reinforced(current.confidence, by: step)
            try Self.appendRevision(
                db,
                traitID: id,
                statement: current.statement,
                confidence: raised,
                source: source,
                at: stamp
            )
            try db.execute(
                sql: "UPDATE user_traits SET confidence = ?, updated_at = ? WHERE id = ?",
                arguments: [raised, SophiaTimestamp.milliseconds(from: stamp), id]
            )
            return raised
        }
    }

    /// 置き場所を手で変える。**`translating` は書けない。消すこともできない。**
    ///
    /// `stored` ⇄ `retrieved` の出し入れだけを許す。
    /// `translating` は焼いた事実からの導出値であり、手で書くと
    /// 14.15節の「いま重みに入っている像の一覧」が嘘になる（`StoreFailure.placementIsDerived`）。
    ///
    /// ## 禁じているのは「導出値を手で書くこと」であって、値の向きではない
    ///
    /// 以前はここが **`translating` を書くことだけ**を拒んでいた。
    /// **落とすほうは通っていた** ── 焼き込み済みの像を手で `stored` にできた。
    /// そうすると DB が2つの矛盾したことを同時に言う:
    ///
    /// | 訊き方 | 答え |
    /// |---|---|
    /// | `statementsInActiveAdapter()` | **重みに入っている**（焼き込み記録が根拠） |
    /// | `trait.placement` | **貯めているだけ**（手で書いた値） |
    ///
    /// **重みは剥がせない。** 剥がせないものを「貯めているだけ」と表示するのは
    /// NFR-12（なぜそう振る舞うのかを説明できる）を壊すし、
    /// 14.15節の「◯件が反映を待っています」に**待っていない像が混ざる。**
    ///
    /// **したがって、有効な世代に焼かれている像の置き場所は動かない。**
    /// 要求は捨てられ、**戻り値には実際にそうなった置き場所が返る**
    /// （`.translating` が返ったなら、それは要求が通らなかったということである）。
    /// 例外にしていないのは、これが呼び出し側の誤りではなく
    /// **「重みが勝つ」という設計そのもの**だからである。
    ///
    /// > **【14.3節】引く層は初版では空でよい。**
    /// > 内容は初回に訊かないので、引く対象がほとんど存在しない。
    /// > **枠だけ用意して、引き金の規則（決定論的であること）だけ決めておく。**
    ///
    /// **`retrieved` はその「枠」である。** 引き金そのものは推論側の仕事（別担当）。
    ///
    /// ⚠ `retrieved` の像がのちに焼かれると `translating` が勝ち、
    /// **世代を外したあとは `retrieved` ではなく `stored` に戻る**（`retrieved` の指定は残らない）。
    /// **両方に同時に置く設計はまだ無い**【未確認】。
    ///
    /// - Returns: **保存された行の置き場所。** 要求した値とは限らない。
    /// - Throws: 像が無ければ `StoreFailure.traitNotFound`
    ///   （`reviseTrait` / `reinforceTrait` と揃えてある。**0行に当たっただけを成功と呼ばない**）。
    @discardableResult
    func setTraitPlacement(
        id: String,
        to placement: TraitPlacement,
        now: Date = Date()
    ) throws -> TraitPlacement {
        guard placement != .translating else {
            throw StoreFailure.placementIsDerived(id: id)
        }
        let stamp = SophiaTimestamp.truncated(now)
        return try write { db in
            guard try UserTraitRecord.fetchOne(
                db, sql: "SELECT * FROM user_traits WHERE id = ?", arguments: [id]
            ) != nil else {
                throw StoreFailure.traitNotFound(id: id)
            }
            // **焼かれている行には当たらない。** 条件は `recalculateTraitPlacements` と同じ形
            // （翻訳役の有効な世代に焼かれているか）にしてある ── 別々に書くと、いつか食い違う。
            try db.execute(
                sql: """
                    UPDATE user_traits
                       SET placement = :placement, updated_at = :now
                     WHERE id = :id
                       AND NOT EXISTS (\(Self.activeBakeExistsSQL))
                    """,
                arguments: [
                    "placement": placement.rawValue,
                    "now": SophiaTimestamp.milliseconds(from: stamp),
                    "id": id,
                    "adapter": AdapterKind.translator.rawValue,
                ]
            )
            // 手で書いた値と焼いた事実がずれていれば、ここで必ず直る（自己修復）。
            try Self.recalculateTraitPlacements(db, at: stamp)

            let saved = try UserTraitRecord.fetchOne(
                db, sql: "SELECT * FROM user_traits WHERE id = ?", arguments: [id]
            )
            // **読み直した行を返す。** 「要求した値」を返すと、通らなかったことが呼び出し側から消える。
            return saved?.placement ?? placement
        }
    }

    // MARK: - 読む

    func trait(id: String) async throws -> UserTraitRecord? {
        try await read { db in
            try UserTraitRecord.fetchOne(
                db, sql: "SELECT * FROM user_traits WHERE id = ?", arguments: [id]
            )
        }
    }

    /// すべての利用者像。**FR-28（利用者が閲覧・編集・削除できる）の設定画面はこれを使う。**
    ///
    /// 並びは新しい順。**上限を置いていない** ── 14.16節⑦のとおり
    /// 必要件数が数十件か数千件かは決着しておらず、
    /// **どちらでも壊れない形にするには、件数に天井を作らないのが最も安全である。**
    func allTraits() async throws -> [UserTraitRecord] {
        try await read { db in
            try UserTraitRecord.fetchAll(
                db, sql: "SELECT * FROM user_traits ORDER BY created_at DESC, id DESC"
            )
        }
    }

    /// 内容だけ / 様式だけ。`idx_user_traits_kind` に乗る。
    func traits(kind: TraitKind) async throws -> [UserTraitRecord] {
        try await read { db in
            try UserTraitRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM user_traits
                     WHERE kind = ?
                     ORDER BY category, created_at DESC, id DESC
                    """,
                arguments: [kind.rawValue]
            )
        }
    }

    /// **言語化された文の履歴。古い順。** 第1版が最初に来る。
    ///
    /// 訂正で消えないことの実体はこれである（第8.4節 / NFR-12）。
    func traitRevisions(of traitID: String) async throws -> [UserTraitRevisionRecord] {
        try await read { db in
            try UserTraitRevisionRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM user_trait_revisions
                     WHERE trait_id = ?
                     ORDER BY revision
                    """,
                arguments: [traitID]
            )
        }
    }

    /// **`stored` のまま待っている件数**（14.7節 / 14.15節）。
    ///
    /// > 利用者には「◯件が次の反映を待っています」と見せる。
    /// > **待っていることが見えれば、待たされていることに文句を言える。**
    /// > 見えないまま黙って貯めるのが最も悪い。
    func storedTraitCount() async throws -> Int {
        try await read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM user_traits WHERE placement = 'stored'"
            ) ?? 0
        }
    }

    /// **学習データに入れてよい像**（14.14節の関門）。
    ///
    /// ## 関門は2つある
    ///
    /// 1. **確信度が閾値以上。** 再学習は評価を伴う（14.11節③）ので、
    ///    **評価1回に見合うだけ確からしいものしか通さない**
    /// 2. **期限切れでない。** 陳腐化した内容を焼くと、消せない誤りになる
    ///
    /// ## `placement` では絞っていない
    ///
    /// **既に焼いた像も返る。** 絞ると、v2 を学習するたびに v1 が覚えたことを忘れ、
    /// 14.11節③（世代を並べ、勝ったときだけ採用する）が成立しない。
    ///
    /// ## 件数に上限を置いていない
    ///
    /// 必要件数は**未決**である ── 10.5節は「数千件」、第14章の前提は「数十〜数百件」
    /// で食い違っている（14.16節⑦）。**どちらでも壊れないように、
    /// LIMIT も最低件数の検査も置いていない。1件でも成立し、何万件でも全件返る。**
    func traitsForTraining(
        minimumConfidence: Double = UserTraitDefaults.trainingConfidenceThreshold,
        now: Date = Date()
    ) async throws -> [UserTraitRecord] {
        let cutoff = SophiaTimestamp.milliseconds(from: now)
        return try await read { db in
            try UserTraitRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM user_traits
                     WHERE confidence >= ?
                       AND (expires_at IS NULL OR expires_at > ?)
                     ORDER BY confidence DESC, created_at, id
                    """,
                arguments: [minimumConfidence, cutoff]
            )
        }
    }

    // MARK: - 重みへ焼く（14.11節）

    /// 学習が1回終わったことを記録する。**重みそのものは書かない**（ファイルは呼び出し側）。
    ///
    /// 1トランザクションで4つを行う:
    ///
    /// 1. `adapter_generations` に世代を1行
    /// 2. 焼いた像ぶんの `user_trait_bakes`（**その時点の版番号つき**）
    /// 3. `activate` なら同じアダプタの他の世代を無効化して、この世代を有効化
    /// 4. `user_traits.placement` / `adapter_gen` を焼いた事実から再計算
    ///
    /// **分けないのは、途中まで成功した状態が
    /// 「重みには入っているが、DB は入っていないと言う」形になるからである。**
    ///
    /// - Parameters:
    ///   - generation: 省略すると、そのアダプタの最大世代 + 1。
    ///   - traitIDs: 学習に渡した像。**空でもよい**（素の状態を世代として記録する場合）。
    ///   - durationMs: **中断されたなら nil のまま**にすること（14.11節②）。
    ///   - activate: 14.11節③は「**前の世代に対比較で勝ったときだけ既定にする**」と
    ///     決めている。**したがって既定は `false`** ── 焼いただけでは既定にならない。
    @discardableResult
    func recordAdapterGeneration(
        adapter: AdapterKind = .translator,
        generation: Int? = nil,
        modelID: String,
        directory: String,
        traitIDs: [String],
        durationMs: Int? = nil,
        activate: Bool = false,
        id: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> AdapterGenerationRecord {
        // **同じ NUL の罠が、こちらでは外すべきファイルの取り違えになる。**
        // `directory` が途中で切れると、名指した先と実在するアダプタがずれる
        // （`TraitErasureOutcome` が名指すのはこの文字列である）。
        try Self.rejectNUL(modelID, field: "model_id")
        try Self.rejectNUL(directory, field: "directory")
        let stamp = SophiaTimestamp.truncated(now)
        return try write { db in
            let next: Int
            if let generation {
                next = generation
            } else {
                let highest = try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(generation) FROM adapter_generations WHERE adapter = ?",
                    arguments: [adapter.rawValue]
                ) ?? 0
                next = highest + 1
            }

            let record = AdapterGenerationRecord(
                id: id,
                adapter: adapter,
                generation: next,
                modelID: modelID,
                directory: directory,
                sampleCount: traitIDs.count,
                trainedAt: stamp,
                durationMs: durationMs,
                isActive: false          // 有効化は下でまとめて行う（部分UNIQUE索引の順序があるため）
            )
            try record.insert(db)

            for traitID in traitIDs {
                // **焼いた時点の版**を記録する。あとで訂正されても、
                // 重みの中にあるのがどの文かを言えるようにするため（NFR-12）。
                let revision = try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(revision) FROM user_trait_revisions WHERE trait_id = ?",
                    arguments: [traitID]
                ) ?? 1
                try UserTraitBakeRecord(
                    traitID: traitID,
                    adapterGenerationID: record.id,
                    revision: revision,
                    bakedAt: stamp
                ).insert(db)
            }

            if activate {
                try Self.activate(db, adapter: adapter, generationID: record.id)
            }
            try Self.recalculateTraitPlacements(db, at: stamp)

            var saved = record
            saved.isActive = activate
            return saved
        }
    }

    /// 世代を切り替える。**14.11節④の回復手順の第1段（前の世代のアダプタに戻す）。**
    ///
    /// 切り替えると `user_traits.placement` が再計算される ──
    /// 新しい世代に入っていない像は `stored` に戻る（＝もう効いていない）。
    /// **`user_trait_bakes` は消えない**ので、「v2 には入っていた」という事実は残る。
    func activateAdapterGeneration(
        adapter: AdapterKind = .translator,
        generation: Int,
        now: Date = Date()
    ) throws {
        let stamp = SophiaTimestamp.truncated(now)
        try write { db in
            guard let target = try AdapterGenerationRecord.fetchOne(
                db,
                sql: "SELECT * FROM adapter_generations WHERE adapter = ? AND generation = ?",
                arguments: [adapter.rawValue, generation]
            ) else {
                throw StoreFailure.traitNotFound(id: "\(adapter.rawValue)/v\(generation)")
            }
            try Self.activate(db, adapter: adapter, generationID: target.id)
            try Self.recalculateTraitPlacements(db, at: stamp)
        }
    }

    /// アダプタを外す。**14.11節④の第2段（`unload`。素の翻訳役に戻る）に対応する記録。**
    ///
    /// 全部の像が `stored` に戻り、**毎ターンの費用は 0 のまま、効きだけが消える。**
    /// ファイルは消さない ── **戻せることが NFR-11（縮退）の実体だから**である。
    func deactivateAdapter(_ adapter: AdapterKind = .translator, now: Date = Date()) throws {
        let stamp = SophiaTimestamp.truncated(now)
        try write { db in
            try db.execute(
                sql: "UPDATE adapter_generations SET is_active = 0 WHERE adapter = ?",
                arguments: [adapter.rawValue]
            )
            try Self.recalculateTraitPlacements(db, at: stamp)
        }
    }

    /// いま適用されている世代（14.15節「どの世代を使っているか」）。無ければ nil。
    func activeAdapterGeneration(
        _ adapter: AdapterKind = .translator
    ) async throws -> AdapterGenerationRecord? {
        try await read { db in
            try AdapterGenerationRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM adapter_generations
                     WHERE adapter = ? AND is_active = 1
                    """,
                arguments: [adapter.rawValue]
            )
        }
    }

    /// 世代の一覧。**新しい順。** 14.15節が設定画面へ出すと決めているもの
    /// （いつ / 何件で / どれだけかかったか / どれを使っているか / 戻す操作）はすべてこの行にある。
    func adapterGenerations(
        _ adapter: AdapterKind = .translator
    ) async throws -> [AdapterGenerationRecord] {
        try await read { db in
            try AdapterGenerationRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM adapter_generations
                     WHERE adapter = ?
                     ORDER BY generation DESC
                    """,
                arguments: [adapter.rawValue]
            )
        }
    }

    /// その世代に焼き込まれた像（**焼いた時点の版番号つき**）。
    func bakes(inGenerationID generationID: String) async throws -> [UserTraitBakeRecord] {
        try await read { db in
            try UserTraitBakeRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM user_trait_bakes
                     WHERE adapter_generation_id = ?
                     ORDER BY trait_id
                    """,
                arguments: [generationID]
            )
        }
    }

    /// その像が過去に入ったすべての世代。**`user_traits.adapter_gen` が持てない履歴。**
    func bakes(ofTrait traitID: String) async throws -> [UserTraitBakeRecord] {
        try await read { db in
            try UserTraitBakeRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM user_trait_bakes
                     WHERE trait_id = ?
                     ORDER BY baked_at, adapter_generation_id
                    """,
                arguments: [traitID]
            )
        }
    }

    /// **いま重みに入っている文**（14.15節「いま重みに入っている像の一覧」）。
    ///
    /// ⚠ **`user_traits.statement`（最新の文）ではなく、焼いた時点の文を返す。**
    /// 焼いた後に訂正された像は、重みの中身と最新の文がずれている。
    /// **最新の文を「根拠」として見せると嘘になる。**
    ///
    /// - Returns: 像と、**焼いた時点の版**の組。有効な世代が無ければ空。
    func statementsInActiveAdapter(
        _ adapter: AdapterKind = .translator
    ) async throws -> [BakedStatement] {
        let name = adapter.rawValue
        // **1回の read にまとめてある。** 2つに分けると、
        // 間に世代の切り替えが挟まったときに「像はあるが焼いた版が無い」組ができうる。
        return try await read { db in
            let traits = try UserTraitRecord.fetchAll(
                db,
                sql: """
                    SELECT t.* FROM user_traits t
                      JOIN user_trait_bakes b ON b.trait_id = t.id
                      JOIN adapter_generations g ON g.id = b.adapter_generation_id
                     WHERE g.adapter = ? AND g.is_active = 1
                     ORDER BY t.created_at, t.id
                    """,
                arguments: [name]
            )
            let revisions = try UserTraitRevisionRecord.fetchAll(
                db,
                sql: """
                    SELECT r.* FROM user_trait_revisions r
                      JOIN user_trait_bakes b
                        ON b.trait_id = r.trait_id AND b.revision = r.revision
                      JOIN adapter_generations g ON g.id = b.adapter_generation_id
                     WHERE g.adapter = ? AND g.is_active = 1
                    """,
                arguments: [name]
            )
            let byTrait = Dictionary(revisions.map { ($0.traitID, $0) }) { first, _ in first }
            return traits.compactMap { trait in
                byTrait[trait.id].map { BakedStatement(trait: trait, baked: $0) }
            }
        }
    }

    // MARK: - 消す（FR-28 / NFR-01）

    /// 利用者像を1件消す。履歴と焼き込み記録も `ON DELETE CASCADE` で消える。
    ///
    /// **戻り値を捨てないこと。** DB から消えても、
    /// **既に焼いてあるアダプタの重みからは消えない**（`TraitErasureOutcome` の型コメント）。
    @discardableResult
    func deleteTrait(id: String) throws -> TraitErasureOutcome {
        try eraseTraits(matching: "id = ?", arguments: [id])
    }

    /// **利用者像を全部消す**（FR-28「削除したものは完全に消える」/ NFR-01 の精神）。
    ///
    /// `user_traits` を空にすると、履歴（`user_trait_revisions`）と
    /// 焼き込み記録（`user_trait_bakes`）も CASCADE で消える。
    ///
    /// ## アダプタのファイルは消さない。**消せないからではなく、消してはならないから**
    ///
    /// 世代の記録（`adapter_generations`）を一緒に消すと、
    /// **消した像を含む重みがディスクに残ったまま、それを名指す手段だけが失われる。**
    /// 外すことも、どのファイルが汚染されているかを言うこともできなくなる ──
    /// **14.11節④が `fuse` を禁じている理由（外から見る手段と外す手段を同時に失う）と同じ形**
    /// を、こちらの手で作ることになる。
    ///
    /// **したがって記録は残し、「まだ効いている世代」を戻り値で名指す。**
    /// ファイルを実際に消すのは呼び出し側の仕事である（この層は FileManager を触らない）。
    @discardableResult
    func eraseAllUserTraits() throws -> TraitErasureOutcome {
        try eraseTraits(matching: "1 = 1", arguments: [])
    }

    // MARK: - 内部

    private func eraseTraits(
        matching predicate: String,
        arguments: StatementArguments
    ) throws -> TraitErasureOutcome {
        try write { db in
            // **消す前に**調べる。CASCADE が走った後では、
            // どの世代がその像を含んでいたかを知る手段が無くなる。
            let affected = try AdapterGenerationRecord.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT g.* FROM adapter_generations g
                      JOIN user_trait_bakes b ON b.adapter_generation_id = g.id
                     WHERE b.trait_id IN (SELECT id FROM user_traits WHERE \(predicate))
                     ORDER BY g.adapter, g.generation
                    """,
                arguments: arguments
            )
            let deleted = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM user_traits WHERE \(predicate)",
                arguments: arguments
            ) ?? 0

            try db.execute(
                sql: "DELETE FROM user_traits WHERE \(predicate)",
                arguments: arguments
            )
            return TraitErasureOutcome(
                deletedTraitCount: deleted,
                generationsStillCarryingErasedTraits: affected
            )
        }
    }

    /// 次の版番号を採って1行積む。**既存の版は触らない。**
    private static func appendRevision(
        _ db: Database,
        traitID: String,
        statement: String,
        confidence: Double,
        source: TraitSource,
        at date: Date
    ) throws {
        let next = (try Int.fetchOne(
            db,
            sql: "SELECT MAX(revision) FROM user_trait_revisions WHERE trait_id = ?",
            arguments: [traitID]
        ) ?? 0) + 1
        try UserTraitRevisionRecord(
            traitID: traitID,
            revision: next,
            statement: statement,
            confidence: confidence,
            source: source,
            createdAt: date
        ).insert(db)
    }

    /// 同じアダプタの他の世代を無効化してから、1つを有効化する。
    ///
    /// **順序が要る。** 部分UNIQUE索引（`adapter WHERE is_active = 1`）は
    /// 文ごとに検査されるので、先に有効化すると一瞬2つ有効になって落ちる。
    private static func activate(
        _ db: Database,
        adapter: AdapterKind,
        generationID: String
    ) throws {
        try db.execute(
            sql: "UPDATE adapter_generations SET is_active = 0 WHERE adapter = ?",
            arguments: [adapter.rawValue]
        )
        try db.execute(
            sql: "UPDATE adapter_generations SET is_active = 1 WHERE id = ?",
            arguments: [generationID]
        )
    }

    /// **その像が、いま有効な翻訳役の世代に焼かれているか。**
    ///
    /// `:adapter` を束縛して使う相関副問い合わせ。`user_traits` を更新する文の中でだけ意味を持つ。
    /// **`setTraitPlacement` と `recalculateTraitPlacements` が同じものを見るためにここに1つ置いてある。**
    private static let activeBakeExistsSQL = """
        SELECT 1
          FROM user_trait_bakes b
          JOIN adapter_generations g ON g.id = b.adapter_generation_id
         WHERE b.trait_id = user_traits.id
           AND g.adapter = :adapter
           AND g.is_active = 1
        """

    /// **`placement` と `adapter_gen` を、焼いた事実から計算し直す。**
    ///
    /// この2列を書くのは**ここだけである**（`setTraitPlacement` も最後にこれを通す）。
    /// 焼く・世代を切り替える・外す、のどの経路からも最後にこれを通す。
    /// 書く場所が散ると、**重みの中身と DB の言い分がずれる**（14.15節が嘘になる）。
    ///
    /// 規則:
    ///
    /// | 状態 | `placement` | `adapter_gen` |
    /// |---|---|---|
    /// | **有効な翻訳役の**世代に焼かれている | `translating` | その世代番号（複数なら最大） |
    /// | 焼かれていない／世代が無効 | `stored` | NULL |
    /// | `retrieved` で、焼かれていない | **`retrieved` のまま** | NULL |
    ///
    /// ## アダプタで絞ること（**`translating` は「翻訳役の重みに入った」という意味である**）
    ///
    /// `AdapterKind` には `base`（本体 8B）もある（14.13a節で 16GB でも回ることは実測済み）。
    /// 絞らないと2つ壊れる:
    ///
    /// 1. **本体アダプタにしか入っていない像が `translating` を名乗る。**
    ///    アダプタで絞っている `statementsInActiveAdapter(.translator)` は空なので、
    ///    14.15節の画面が「翻訳役には何も入っていないが、待っている像も0件」と言う
    /// 2. **`adapter_gen` が両アダプタを混ぜた `MAX(generation)` になる。**
    ///    翻訳役 v1 の像が本体 v7 を指し、存在しない世代を画面に出す
    ///
    /// ## `WHERE` は「導出値と食い違っている行」を全部拾う
    ///
    /// 以前はここが `adapter_gen` の変化と「`translating` なのに焼かれていない行」しか
    /// 見ていなかったので、**手で `stored` に落とされた焼き込み済みの像が素通りした**
    /// ── 矛盾が一時的な状態ではなく、その世代が有効なあいだ残り続けた。
    /// **いまは `placement` を導出値そのものと突き合わせるので、どちら向きのずれも直る。**
    ///
    /// それでも `WHERE` が「実際に変わる行」だけに絞られていることは変わらないので、
    /// **何も変わらないときは `updated_at` も動かない。**
    /// 動くと、変わっていない像が設定画面の先頭に来てしまう。
    private static func recalculateTraitPlacements(_ db: Database, at date: Date) throws {
        let activeGeneration = """
            SELECT MAX(g.generation)
              FROM user_trait_bakes b
              JOIN adapter_generations g ON g.id = b.adapter_generation_id
             WHERE b.trait_id = user_traits.id
               AND g.adapter = :adapter
               AND g.is_active = 1
            """
        // **導出値の定義そのもの。** SET と WHERE の両方がこれを使う ──
        // 2か所に書き分けると、片方だけ直したときに「直らない行」がまた生まれる。
        let derivedPlacement = """
            CASE
              WHEN EXISTS (\(activeBakeExistsSQL)) THEN 'translating'
              WHEN placement = 'translating'       THEN 'stored'
              ELSE placement
            END
            """
        try db.execute(
            sql: """
                UPDATE user_traits
                   SET adapter_gen = (\(activeGeneration)),
                       placement   = \(derivedPlacement),
                       updated_at  = :now
                 WHERE adapter_gen IS NOT (\(activeGeneration))
                    OR placement   IS NOT (\(derivedPlacement))
                """,
            arguments: [
                "adapter": AdapterKind.translator.rawValue,
                "now": SophiaTimestamp.milliseconds(from: date),
            ]
        )
    }

    /// **NUL を含む文字列を DB へ書かせない。**
    ///
    /// GRDB は文字列を `sqlite3_bind_text(…, -1, …)` で束縛する（`StandardLibrary.swift`）。
    /// **長さを渡していないので、SQLite は最初の NUL までしか保存しない。**
    /// 読むほうも `String(cString: sqlite3_column_text(…))` なので、**同じ場所で切れる。**
    /// つまり黙って通すと:
    ///
    /// 1. **`recordTrait` が返した記録と、保存された行が食い違う。** 呼び出し側は成功したと見る
    /// 2. 学習データを DB から作れば切れた文が、返り値から作れば全文が入る ──
    ///    **どちらが重みに入ったのかを後から言えない**（NFR-12）
    /// 3. 消したことの確認（全表走査）も、切れた文しか探せない
    ///
    /// **黙って変えるより、書かせないほうがよい。**
    /// 切って保存すると「言語化された文」（14.14節）が**利用者の知らないところで別物になり、
    /// しかもそれが重みへ焼かれると消せない**（14.11節④で戻せるのは世代であって1件ではない）。
    /// 拒めば、上流（モデルの出力・貼り付けたファイル片）に NUL が混ざったことが
    /// **その場で見える。**
    ///
    /// > **【未確認】上流で NUL を落としているかは見ていない。**
    /// > ここが表明しているのは「**この層は黙って受け取らない**」ことだけである。
    private static func rejectNUL(_ text: String, field: String) throws {
        guard text.utf8.contains(0) else { return }
        throw StoreFailure.textContainsNUL(field: field)
    }
}
