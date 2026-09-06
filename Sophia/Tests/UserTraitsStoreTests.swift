import XCTest
@testable import Sophia

/// 利用者像の永続化（DESIGN.md 第14章 14.14節 / FR-24〜29 / NFR-11・12）。
///
/// ## このテストが本当に見張っているもの
///
/// 第14章の設計は**2つの相反する約束**の上に立っている。
///
/// | 約束 | 出所 |
/// |---|---|
/// | **消えないこと。** 訂正されても、重みへ焼いても、言語化された文は残る | 第8.4節 / 14.11節④ / NFR-12 |
/// | **消せること。** 利用者が消したものは完全に消える | FR-28 / NFR-01 |
///
/// **どちらか片方だけを確かめると、もう片方を壊しても緑のままになる。**
/// だから両方向を対で書いてある（「MARK: 消えないこと」と「MARK: 消せること」）。
///
/// ## 緑であることは、測れていることを意味しない
///
/// 数字を数字と突き合わせるだけのテストを避け、**性質が壊れたときに落ちる形**にしてある。
/// たとえば確信度の既定値は、値そのものではなく
/// **「関門を一度で通るのはどの出所か」という結果**で固定している。
final class UserTraitsStoreTests: StoreTestCase {

    // MARK: - 土台

    /// 「非力なマシンは制約ではなく手段である」── 14.8節が本プロジェクトで
    /// 最も効いた1件として挙げているもの。**1つの事実が誤りのカテゴリをまるごと消した。**
    private static let machineTrait = "非力なマシンは制約ではなく手段である"

    @discardableResult
    private func makeStyleTrait(
        in store: Store,
        statement: String = machineTrait,
        category: String = "machine",
        source: TraitSource = .onboarding,
        confidence: Double? = nil,
        at now: Date = Date(timeIntervalSince1970: 1_000)
    ) async throws -> UserTraitRecord {
        try await store.recordTrait(
            kind: .style,
            category: category,
            statement: statement,
            source: source,
            confidence: confidence,
            now: now
        )
    }

    // MARK: - マイグレーション（既存の移行を1つも変えていないこと）

    /// 識別子は `grdb_migrations` に文字列で焼かれる。**v1 は1文字も変えていない。**
    func testMigrationIdentifiersAreFrozenAndUserTraitsIsAppendedLast() {
        XCTAssertEqual(SophiaMigration.v1Initial.rawValue, "v1.initial")
        XCTAssertEqual(SophiaMigration.v2UserTraits.rawValue, "v2.userTraits")
        XCTAssertEqual(
            SophiaMigration.allCases.map(\.rawValue),
            ["v1.initial", "v2.userTraits", "v3.traitDirection"],
            "利用者像の移行は**末尾に**足すこと。間に挿すと既存DBで順序が食い違う"
        )
    }

    /// **これが「既存の移行を変えていない」ことの実測である。**
    ///
    /// v1 だけが当たった（＝出荷済みに相当する）DBを作り、会話を入れてから開く。
    /// v2 だけが追加で走り、**会話が1文字も失われないこと**を確かめる。
    /// VISION「原ログを完全に保持する」。
    func testUserTraitsMigrationLandsOnAnExistingDatabaseWithoutLosingConversations() async throws {
        let url = makeTemporaryDatabaseURL()
        let conversationID = try SophiaMigrations.createV1OnlyDatabaseForTesting(
            at: url,
            conversationTitle: "利用者像より前からある会話",
            messageContent: "ここにいる"
        )

        let store = try Store(.file(url))

        let applied = try await store.rawAppliedMigrationIdentifiers()
        XCTAssertEqual(Set(applied), ["v1.initial", "v2.userTraits", "v3.traitDirection"], "追加分だけが当たること")

        let messages = try await store.messages(in: conversationID)
        XCTAssertEqual(messages.map(\.content), ["ここにいる"], "移行で会話が消えている")

        let conversation = try await store.conversation(id: conversationID)
        XCTAssertEqual(conversation?.title, "利用者像より前からある会話")

        // 新しい表はできているが、**空である。**
        // 「既定は貯めるが送らない」以前に、移行そのものが何も発明しない。
        let traits = try await store.allTraits()
        XCTAssertTrue(traits.isEmpty)
    }

    // MARK: - スキーマ（14.14節との一致の見張り）

    func testCreatesTheFourUserTraitTablesOnTopOfChapter8() async throws {
        let store = try makeInMemoryStore()

        let tables = try await store.userTableNames()

        XCTAssertEqual(
            tables,
            [
                "adapter_generations",
                // 第8章の5枚。**1枚も減っていないこと**
                "conversations", "messages", "model_files", "models", "profiles",
                "user_trait_bakes", "user_trait_revisions", "user_traits",
            ]
        )
    }

    func testUserTraitsHasTheColumnsFromSection14_14() async throws {
        let store = try makeInMemoryStore()

        let columns = try await store.columnNames(of: "user_traits")

        XCTAssertEqual(
            columns,
            [
                "id", "kind", "category", "statement", "source",
                // 重みへ移す関門（14.14節）
                "confidence",
                // **本章の中心にある列。既定が stored であることが設計の主張**（14.7節）
                "placement", "adapter_gen",
                "expires_at", "created_at", "updated_at",
                // **v3（FR-31）で末尾に足した。** `ALTER TABLE` は末尾にしか足せない。
                "direction",
            ],
            "14.14節の生SQL と列の並びまで一致していること"
        )
    }

    func testUserTraitsIndexesMatchSection14_14() async throws {
        let store = try makeInMemoryStore()

        let indexes = try await store.explicitIndexes(on: "user_traits")

        XCTAssertEqual(
            indexes,
            [
                "idx_user_traits_kind": ["kind", "category"],
                "idx_user_traits_placement": ["placement", "confidence"],
            ]
        )
    }

    /// **14.14節からの意図的な逸脱を、逸脱したまま固定する。**
    ///
    /// 14.14節の生SQL は時刻列を `TEXT` と書いているが、INTEGER（ミリ秒）にしてある。
    /// `SophiaTimestamp` が第8章の時刻を「以後この1か所だけを参照する」と決めており、
    /// **同じDBに2つの綴りの時刻が混ざるほうが高くつく**と判断した。
    ///
    /// 宣言型だけでなく**実際に書き込まれた値の型**まで見ているのは、
    /// SQLite の型親和性では宣言が INTEGER でも文字列が入ってしまうからである
    /// （`StoreSchemaTests.testTimestampsAreActuallyStoredAsIntegers` と同じ理由）。
    func testUserTraitTimestampsAreActuallyStoredAsIntegers() async throws {
        let store = try makeInMemoryStore()
        try await store.recordTrait(
            kind: .content,
            category: "stack",
            statement: "いまは Swift の案件",
            source: .manual,
            expiresAt: Date(timeIntervalSince1970: 9_999)
        )

        let created = try await store.rawString(sql: "SELECT typeof(created_at) FROM user_traits")
        let updated = try await store.rawString(sql: "SELECT typeof(updated_at) FROM user_traits")
        let expires = try await store.rawString(sql: "SELECT typeof(expires_at) FROM user_traits")
        let revision = try await store.rawString(
            sql: "SELECT typeof(created_at) FROM user_trait_revisions"
        )

        XCTAssertEqual(created, "integer")
        XCTAssertEqual(updated, "integer")
        XCTAssertEqual(expires, "integer")
        XCTAssertEqual(revision, "integer")
    }

    /// **14.7節の主張そのものである。**
    ///
    /// 列の既定値が `'stored'` であるということは、
    /// **何も指定しなければどこにも送られない**ということである。
    /// 生SQL で（＝Swift の既定値を通さずに）確かめている。
    func testPlacementDefaultsToStoredInTheSchemaItself() async throws {
        let store = try makeInMemoryStore()

        try await store.executeRawForTesting(
            sql: """
                INSERT INTO user_traits (id, kind, category, statement, source, created_at, updated_at)
                VALUES ('t', 'style', 'tone', '結論から書く', 'correction', 0, 0)
                """
        )

        let placement = try await store.rawString(sql: "SELECT placement FROM user_traits")
        let confidence = try await store.rawString(sql: "SELECT confidence FROM user_traits")
        let adapterGen = try await store.rawString(sql: "SELECT typeof(adapter_gen) FROM user_traits")

        XCTAssertEqual(placement, "stored", "既定が stored でなくなると 14.7節が崩れる")
        XCTAssertEqual(confidence, "0.5", "14.14節の DEFAULT 0.5")
        XCTAssertEqual(adapterGen, "null", "未反映であること")
    }

    // MARK: - 型と DB の綴りが一致していること（第8章 messages.role と同じ約束）

    func testKindCheckRejectsAValueTheTypeDoesNotHave() async throws {
        let store = try makeInMemoryStore()

        await assertConstraintViolation {
            try await store.executeRawForTesting(
                sql: """
                    INSERT INTO user_traits (id, kind, category, statement, source, created_at, updated_at)
                    VALUES ('x', 'preference', 'tone', 's', 'manual', 0, 0)
                    """
            )
        }
    }

    func testKindCheckAcceptsEveryDeclaredCase() async throws {
        let store = try makeInMemoryStore()

        for kind in TraitKind.allCases {
            try await store.recordTrait(
                kind: kind, category: "c", statement: "\(kind.rawValue) の像", source: .manual
            )
        }

        let count = try await store.allTraits().count
        XCTAssertEqual(count, TraitKind.allCases.count)
    }

    func testSourceCheckRejectsAValueTheTypeDoesNotHave() async throws {
        let store = try makeInMemoryStore()

        await assertConstraintViolation {
            try await store.executeRawForTesting(
                sql: """
                    INSERT INTO user_traits (id, kind, category, statement, source, created_at, updated_at)
                    VALUES ('x', 'style', 'tone', 's', 'guessed_from_logs', 0, 0)
                    """
            )
        }
    }

    func testSourceCheckAcceptsEveryDeclaredCase() async throws {
        let store = try makeInMemoryStore()

        for source in TraitSource.allCases {
            try await store.recordTrait(
                kind: .style, category: "c", statement: "\(source.rawValue) 由来", source: source
            )
        }

        let count = try await store.allTraits().count
        XCTAssertEqual(count, TraitSource.allCases.count)
    }

    func testPlacementCheckRejectsAValueTheTypeDoesNotHave() async throws {
        let store = try makeInMemoryStore()

        await assertConstraintViolation {
            try await store.executeRawForTesting(
                sql: """
                    INSERT INTO user_traits
                      (id, kind, category, statement, source, placement, created_at, updated_at)
                    VALUES ('x', 'style', 'tone', 's', 'manual', 'injected', 0, 0)
                    """
            )
        }
    }

    func testPlacementCheckAcceptsEveryDeclaredCase() async throws {
        let store = try makeInMemoryStore()

        for placement in TraitPlacement.allCases {
            try await store.executeRawForTesting(
                sql: """
                    INSERT INTO user_traits
                      (id, kind, category, statement, source, placement, created_at, updated_at)
                    VALUES (?, 'style', 'tone', 's', 'manual', ?, 0, 0)
                    """,
                arguments: [placement.rawValue, placement.rawValue]
            )
        }

        let count = try await store.rawInt(sql: "SELECT COUNT(*) FROM user_traits")
        XCTAssertEqual(count, TraitPlacement.allCases.count)
    }

    func testAdapterCheckRejectsAValueTheTypeDoesNotHave() async throws {
        let store = try makeInMemoryStore()

        await assertConstraintViolation {
            try await store.executeRawForTesting(
                sql: """
                    INSERT INTO adapter_generations
                      (id, adapter, generation, model_id, directory, sample_count, trained_at)
                    VALUES ('x', 'summarizer', 1, 'm', 'd', 0, 0)
                    """
            )
        }
    }

    func testAdapterCheckAcceptsEveryDeclaredCase() async throws {
        let store = try makeInMemoryStore()

        for adapter in AdapterKind.allCases {
            try await store.recordAdapterGeneration(
                adapter: adapter,
                modelID: "mlx-community/Qwen3-8B-4bit",
                directory: "adapters/\(adapter.rawValue)/v1",
                traitIDs: []
            )
        }

        let count = try await store.rawInt(sql: "SELECT COUNT(*) FROM adapter_generations")
        XCTAssertEqual(count, AdapterKind.allCases.count)
    }

    /// 14.14節「**内容にだけ入れる。様式は期限を持たない**」を DB が守っていること。
    ///
    /// 注意書きではなく制約にしてあるのは、**陳腐化した内容が様式まで汚す**のを防ぐことが
    /// 14.14節の設計判断そのものだからである。
    func testStyleTraitCannotCarryAnExpiry() async throws {
        let store = try makeInMemoryStore()

        await assertConstraintViolation {
            _ = try await store.recordTrait(
                kind: .style,
                category: "tone",
                statement: "結論から書く",
                source: .correction,
                expiresAt: Date(timeIntervalSince1970: 9_999)
            )
        }
    }

    func testContentTraitCanCarryAnExpiry() async throws {
        let store = try makeInMemoryStore()

        let trait = try await store.recordTrait(
            kind: .content,
            category: "stack",
            statement: "いまは Swift の案件",
            source: .manual,
            expiresAt: Date(timeIntervalSince1970: 9_999)
        )

        XCTAssertNotNil(trait.expiresAt)
    }

    /// 確信度は**関門**である（14.14節）。範囲外の値を許すと閾値を素通りできてしまう。
    func testConfidenceOutsideZeroToOneIsRejected() async throws {
        let store = try makeInMemoryStore()

        await assertConstraintViolation {
            try await store.executeRawForTesting(
                sql: """
                    INSERT INTO user_traits
                      (id, kind, category, statement, source, confidence, created_at, updated_at)
                    VALUES ('x', 'style', 'tone', 's', 'manual', 5.0, 0, 0)
                    """
            )
        }
    }

    // MARK: - 既定は「貯めるが、送らない」（14.7節 / FR-29）

    /// **採った瞬間に、毎ターンの費用は 0 である。**
    ///
    /// > 採れた知見が即座に効かないのは、欠陥ではなく設計である（14.7節）。
    ///
    /// NFR-11（利用者像が無くても会話は成立する）は、この既定でこそ自明に満たされる。
    func testANewlyRecordedTraitIsStoredAndReachesNothing() async throws {
        let store = try makeInMemoryStore()

        let trait = try await makeStyleTrait(in: store)

        XCTAssertEqual(trait.placement, .stored)
        XCTAssertNil(trait.adapterGen, "採っただけで重みに入っていてはいけない")

        let active = try await store.statementsInActiveAdapter()
        XCTAssertTrue(active.isEmpty, "有効なアダプタが無いのだから、効いている像も無い")

        let waiting = try await store.storedTraitCount()
        XCTAssertEqual(waiting, 1, "14.15節『◯件が次の反映を待っています』の分子")
    }

    /// **NUL を含む文は、黙って切らずに拒む。**
    ///
    /// GRDB は文字列を `sqlite3_bind_text(…, -1, …)` で束縛し、読むほうも
    /// `String(cString:)` である。**長さを渡していないので、NUL 以降が消える。**
    /// 黙って通すと `recordTrait` が返した記録と保存された行が食い違い、
    /// **どちらが重みに焼かれたのかを後から言えなくなる**（NFR-12）。
    ///
    /// **拒む側に倒したのは、切られた文が重みへ入ると消せないからである**
    /// （14.11節④で戻せるのは世代であって1件ではない）。
    /// NUL は手では打てない ── **モデルの出力か、貼り付けたファイル片から来る。**
    ///
    /// > **【未確認】上流で落としているかは見ていない。**
    /// > ここが表明しているのは「この層は黙って受け取らない」ことだけである。
    func testAStatementContainingNULIsRefusedInsteadOfSilentlyTruncated() async throws {
        let store = try makeInMemoryStore()
        let withNUL = "前半\u{0000}後半"

        await assertThrows({
            _ = try await store.recordTrait(
                kind: .style, category: "tone", statement: withNUL, source: .manual
            )
        }, "NUL を含む文が黙って保存されている（NUL 以降が消えたまま成功と返る）")

        let rows = try await store.rawInt(sql: "SELECT COUNT(*) FROM user_traits")
        XCTAssertEqual(rows, 0, "拒んだのに行が残っている")

        // **入口は2つある。訂正の経路にも同じ関門があること。**
        let trait = try await makeStyleTrait(in: store)
        await assertThrows({
            try await store.reviseTrait(id: trait.id, statement: withNUL, source: .correction)
        }, "訂正では NUL が通ってしまっている")

        let after = try await store.trait(id: trait.id)
        let history = try await store.traitRevisions(of: trait.id)
        XCTAssertEqual(after?.statement, Self.machineTrait, "拒んだのに文が変わっている")
        XCTAssertEqual(history.count, 1, "拒んだのに版が積まれている")

        // **拒むのは NUL だけである。** 他の制御文字も絵文字も1文字も変えずに通ること。
        let fine = try await store.recordTrait(
            kind: .style, category: "tone",
            statement: "改行\nとタブ\tと絵文字 👩🏽‍🚀 と結合文字 é",
            source: .manual
        )
        let stored = try await store.trait(id: fine.id)
        XCTAssertEqual(stored?.statement, fine.statement, "NUL 以外まで拒んでいる／変えている")
    }

    // MARK: - 消えないこと（第8.4節 / 14.11節④ / NFR-12）

    /// **訂正しても、訂正前の文は残る。**
    ///
    /// 第8.4節が `messages.content` について定めた約束
    /// （原ログを要約で上書きしない。要約は別テーブルに持つ）を、利用者像へ適用したもの。
    func testRevisingATraitKeepsTheOldStatementWordForWord() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store, statement: "非力なマシンは制約である")

        try await store.reviseTrait(
            id: trait.id,
            statement: Self.machineTrait,
            source: .correction,
            now: Date(timeIntervalSince1970: 2_000)
        )

        let current = try await store.trait(id: trait.id)
        XCTAssertEqual(current?.statement, Self.machineTrait, "いまの文は新しいほう")

        let history = try await store.traitRevisions(of: trait.id)
        XCTAssertEqual(
            history.map(\.statement),
            ["非力なマシンは制約である", Self.machineTrait],
            "**訂正前の文が消えている。** 8.4節と NFR-12 が破れている"
        )
        XCTAssertEqual(history.map(\.revision), [1, 2])
        XCTAssertEqual(
            history.map(\.source),
            [.onboarding, .correction],
            "『いつ、どこから得た情報か』は版ごとに違う"
        )
    }

    /// 何度訂正しても、**1つも落ちない。**
    func testEveryCorrectionIsKeptNoMatterHowManyTimes() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store, statement: "第0版")

        for index in 1...5 {
            try await store.reviseTrait(
                id: trait.id,
                statement: "第\(index)版",
                source: .correction,
                now: Date(timeIntervalSince1970: 2_000 + Double(index))
            )
        }

        let history = try await store.traitRevisions(of: trait.id)
        XCTAssertEqual(
            history.map(\.statement),
            ["第0版", "第1版", "第2版", "第3版", "第4版", "第5版"]
        )
    }

    /// 確信度の変化にも足跡が残る。**「なぜ 0.9 なのか」に答えられること**（NFR-12）。
    func testReinforcementLeavesAConfidenceTrail() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store, source: .onboarding)

        try await store.reinforceTrait(id: trait.id, source: .correction)
        try await store.reinforceTrait(id: trait.id, source: .correction)

        let history = try await store.traitRevisions(of: trait.id)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(
            history.map(\.statement),
            Array(repeating: Self.machineTrait, count: 3),
            "強化は文を変えない（14.14節『様式は追記して確信度を上げる』）"
        )
        XCTAssertTrue(
            zip(history, history.dropFirst()).allSatisfy { $0.confidence < $1.confidence },
            "確信度が単調に上がっていない: \(history.map(\.confidence))"
        )
    }

    func testConfidenceIsCappedAtOne() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store, confidence: 0.95)

        let raised = try await store.reinforceTrait(id: trait.id, source: .translationEdit)

        XCTAssertEqual(raised, 1.0, "CHECK 制約で落とさず、頭打ちにすること")
    }

    /// **有限でない歩幅では、確信度は1ミリも動かない。**
    ///
    /// `min(1.0, confidence + .nan)` は Swift では `y < x ? y : x` なので **`x`（＝1.0）を返す。**
    /// 頭打ちのつもりの `min` が、NaN を**最大値へ昇格させる装置**になっていた ──
    /// 1.0 は関門（0.7）の上なので、**質問由来の像（0.5）が一撃で学習データに入った。**
    /// **14.13c節の決定（質問は事前分布であって証拠ではない）が、歩幅の異常値1つで壊れる形だった。**
    ///
    /// 歩幅は既定値つきの引数であって定数ではない ──
    /// **計算（0除算・空集合の平均）で決めた瞬間に NaN は来る。**
    func testANonFiniteStepDoesNotMoveTheConfidenceAtAll() async throws {
        let store = try makeInMemoryStore()
        let initial = TraitSource.onboarding.defaultConfidence

        for step in [Double.nan, .infinity, -.infinity] {
            let trait = try await makeStyleTrait(in: store, source: .onboarding)
            let raised = try await store.reinforceTrait(id: trait.id, source: .manual, step: step)
            let after = try await store.trait(id: trait.id)
            let history = try await store.traitRevisions(of: trait.id)

            XCTAssertEqual(raised, initial, "歩幅 \(step) で確信度が動いた")
            XCTAssertEqual(after?.confidence, initial, "歩幅 \(step) で保存された確信度が動いた")
            XCTAssertEqual(
                history.map(\.confidence).max(), initial,
                "履歴に嘘の確信度が残っている（NFR-12 で辿ると『なぜこの値か』に嘘が返る）"
            )
        }

        // **関門を越えていないこと。** 14.13c節: 質問だけでは何も焼かれない。
        let ready = try await store.traitsForTraining()
        XCTAssertTrue(ready.isEmpty, "有限でない歩幅で関門を越えている（学習データに \(ready.count) 件）")
    }

    /// 歩幅が負でも 0 を下回らない。**`CHECK (confidence >= 0.0)` で落とさない**
    /// （頭打ちと同じ理由 ── 強化のたびに落ちうる関数にしない）。
    func testConfidenceIsFlooredAtZero() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store, confidence: 0.5)

        let lowered = try await store.reinforceTrait(id: trait.id, source: .manual, step: -10)

        XCTAssertEqual(lowered, 0.0)
        let after = try await store.trait(id: trait.id)
        XCTAssertEqual(after?.confidence, 0.0)
    }

    /// **本命。焼いた後に訂正されても、重みの中の文を言える。**
    ///
    /// > **重みは記録ではなく、複製である。原本は DB に残す**（14.11節④）。
    /// > NFR-12 を満たしているのは重みではなく DB のほうである。
    ///
    /// このテストが落ちるということは、
    /// **「なぜそう振る舞うのか」を利用者に説明したときに嘘をつく**ということである。
    func testTheStatementBurnedIntoTheWeightsSurvivesLaterCorrections() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store, statement: "焼いたときの文")
        try await store.recordAdapterGeneration(
            modelID: "mlx-community/Qwen3-0.6B-4bit",
            directory: "adapters/translator/v1",
            traitIDs: [trait.id],
            activate: true,
            now: Date(timeIntervalSince1970: 2_000)
        )

        // 焼いた**後**に訂正する。重みの中身は変わっていない。
        try await store.reviseTrait(
            id: trait.id,
            statement: "訂正した後の文",
            source: .correction,
            now: Date(timeIntervalSince1970: 3_000)
        )

        let active = try await store.statementsInActiveAdapter()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(
            active.first?.baked.statement,
            "焼いたときの文",
            "**重みの中にあるのは訂正前の文である。** 最新の文を根拠として見せると嘘になる"
        )
        XCTAssertEqual(active.first?.trait.statement, "訂正した後の文")
        XCTAssertEqual(
            active.first?.hasDivergedSinceBaking,
            true,
            "ずれていることが呼び出し側から見えること（14.11節④の回復を勧める材料）"
        )
    }

    // MARK: - 消せること（FR-28 / NFR-01）

    /// 消した像の履歴と焼き込み記録は道連れになる。**そして、それ以外は1行も減らない。**
    ///
    /// ## 像が1件しか無いと、このテストは何も測っていない
    ///
    /// `eraseTraits(matching:)` は述語を**文字列で組み立てて** `DELETE` へ埋めている
    /// （`"id = ?"` / `"1 = 1"`）。**像が1件だけなら、述語が `1 = 1` に化けても結果は同じ**で、
    /// 全部消す誤りが緑のまま通る。**だから必ずもう1件、残るべき像を置く。**
    func testDeletingATraitTakesItsOwnHistoryAndNobodyElsesWithIt() async throws {
        let store = try makeInMemoryStore()
        let doomed = try await makeStyleTrait(in: store, statement: "消す像")
        let survivor = try await makeStyleTrait(in: store, statement: "残す像")
        try await store.reviseTrait(id: doomed.id, statement: "消す像 第2版", source: .correction)
        try await store.reviseTrait(id: survivor.id, statement: "残す像 第2版", source: .correction)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [doomed.id, survivor.id], activate: true
        )

        let outcome = try await store.deleteTrait(id: doomed.id)

        XCTAssertEqual(outcome.deletedTraitCount, 1)

        // 消した側 ── 3つの表すべてから消える（FR-28）。
        let deleted = try await store.trait(id: doomed.id)
        let deletedRevisions = try await store.traitRevisions(of: doomed.id)
        let deletedBakes = try await store.bakes(ofTrait: doomed.id)
        XCTAssertNil(deleted)
        XCTAssertEqual(deletedRevisions.count, 0, "履歴が残っては FR-28『完全に消える』が破れる")
        XCTAssertEqual(deletedBakes.count, 0, "焼き込み記録が残っては FR-28 が破れる")

        // 残す側 ── **1行も欠けない。** 述語が `1 = 1` に化けたらここで落ちる。
        let kept = try await store.trait(id: survivor.id)
        let keptRevisions = try await store.traitRevisions(of: survivor.id)
        let keptBakes = try await store.bakes(ofTrait: survivor.id)
        XCTAssertEqual(kept?.statement, "残す像 第2版", "消していない像まで消えている")
        XCTAssertEqual(
            keptRevisions.map(\.statement), ["残す像", "残す像 第2版"],
            "消していない像の履歴まで消えている"
        )
        XCTAssertEqual(keptBakes.count, 1, "消していない像の焼き込み記録まで消えている")

        let revisions = try await store.rawInt(sql: "SELECT COUNT(*) FROM user_trait_revisions")
        let bakes = try await store.rawInt(sql: "SELECT COUNT(*) FROM user_trait_bakes")
        XCTAssertEqual(revisions, 2, "残した像の履歴2版だけが残ること")
        XCTAssertEqual(bakes, 1, "残した像の焼き込み1件だけが残ること")

        // 消した像は、まだ v1 の重みの中にいる（DB から消えても剥がせない）。
        XCTAssertEqual(
            outcome.generationsStillCarryingErasedTraits.map(\.directory),
            ["adapters/translator/v1"],
            "外すべきファイルを名指せること"
        )
    }

    /// **利用者が消したら、どの表のどの列にも残らない。**
    ///
    /// 「訂正では消えない」ことと矛盾しない ──
    /// **前者はシステムの都合による上書き、後者は利用者の明示的な意思**であり、別の操作である。
    ///
    /// ## "Anywhere" を3表の件数で確かめてはいけない
    ///
    /// 以前はここが `user_traits` / `user_trait_revisions` / `user_trait_bakes` の
    /// **件数だけ**を見ていた。**表が増えた日に、緑のまま破れる形である** ──
    /// 増える表（要約・埋め込み・学習データの控え）こそが危ない。
    /// 14.16節⑤（消したはずの像で読み続ける）は、**記録が1か所残っていれば成立する。**
    ///
    /// **したがって表も列も `sqlite_master` から引いて全部走査する。**
    /// 表を足した人が何もしなくても、このテストが先に落ちる。
    ///
    /// > **【未確認】これで捕まるのは「文字列がそのまま残っている」場合だけである。**
    /// > 像を加工して持つ表（要約・ベクトル）が増えたら、この走査では見つからない。
    func testErasingEverythingLeavesNoUserTraitRowsAnywhere() async throws {
        let store = try makeInMemoryStore()
        let a = try await makeStyleTrait(in: store, statement: "像A")
        let b = try await makeStyleTrait(in: store, statement: "像B")
        try await store.reviseTrait(id: a.id, statement: "像A 第2版", source: .correction)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [a.id, b.id], activate: true
        )

        // **消す前に、確かにどこかに在ること。** 在らないものが消えても何も測っていない。
        let needles = [a.id, b.id, "像A", "像B"]
        let before = try await Self.placesMentioning(needles, in: store)
        XCTAssertFalse(before.isEmpty, "前提が崩れている: 消す前から見つからない")

        let outcome = try await store.eraseAllUserTraits()

        XCTAssertEqual(outcome.deletedTraitCount, 2)
        let after = try await Self.placesMentioning(needles, in: store)
        XCTAssertEqual(
            after, [],
            """
            消したはずの像が残っている: \(after.joined(separator: " / "))
            （消す前に在った場所: \(before.joined(separator: " / "))）
            """
        )

        // **アダプタの記録は消えない。** 消すと、汚染されたファイルを名指す手段が失われる
        // （14.11節④が `fuse` を禁じている理由と同じ形を、こちらの手で作ることになる）。
        let generations = try await store.rawInt(sql: "SELECT COUNT(*) FROM adapter_generations")
        XCTAssertEqual(generations, 1)
    }

    /// その文字列を含む行が在る場所を `表.列` で返す。**表も列も `sqlite_master` から引く。**
    ///
    /// 列挙を書き写さないための形である ── **表を1つ足すだけで走査範囲が広がる。**
    private static func placesMentioning(
        _ needles: [String],
        in store: Store
    ) async throws -> [String] {
        var found: [String] = []
        for table in try await store.userTableNames() {
            for column in try await store.columnNames(of: table) {
                for needle in needles {
                    let count = try await store.rawInt(
                        sql: """
                            SELECT COUNT(*) FROM "\(table)"
                             WHERE CAST("\(column)" AS TEXT) LIKE ?
                            """,
                        arguments: ["%\(needle)%"]
                    ) ?? 0
                    if count > 0 { found.append("\(table).\(column) ← \(needle)（\(count)件）") }
                }
            }
        }
        return found.sorted()
    }

    /// **消しても、重みからは消えない。それが見えること。**
    ///
    /// FR-28 は「削除したものは**完全に**消える」と書いている。
    /// DB だけ消して黙っていると、**アプリは「消えました」と言い、
    /// 翻訳役は消したはずの像で読み続ける**（14.16節⑤が最も悪い形で出る経路）。
    ///
    /// **アダプタの記録を一緒に消してしまうと、このテストは書けなくなる** ──
    /// 汚染されたファイルを名指す手段が消えるからである。
    func testErasureNamesTheAdaptersThatStillCarryTheDeletedTraits() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store)
        try await store.recordAdapterGeneration(
            adapter: .translator,
            modelID: "mlx-community/Qwen3-0.6B-4bit",
            directory: "adapters/translator/v1",
            traitIDs: [trait.id],
            activate: true
        )

        let outcome = try await store.eraseAllUserTraits()

        XCTAssertFalse(
            outcome.isFullyErased,
            "**DB から消えただけで『完全に消えた』と言ってはいけない。** 重みは複製である"
        )
        XCTAssertEqual(
            outcome.generationsStillCarryingErasedTraits.map(\.directory),
            ["adapters/translator/v1"],
            "外すべきファイルを名指せること"
        )
        XCTAssertEqual(
            outcome.activeGenerationsStillCarryingErasedTraits.count, 1,
            "いま適用中のものが分かること（最も緊急に外すべき対象）"
        )
    }

    /// 無効にした世代も名指すこと。**「もう使っていないから安全」ではない** ──
    /// ファイルは残っており、14.11節④の第1段（前の世代へ戻す）でいつでも復活する。
    func testErasureAlsoNamesInactiveGenerations() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true
        )
        try await store.deactivateAdapter()

        let outcome = try await store.eraseAllUserTraits()

        XCTAssertFalse(outcome.isFullyErased)
        XCTAssertEqual(outcome.generationsStillCarryingErasedTraits.count, 1)
        XCTAssertTrue(outcome.activeGenerationsStillCarryingErasedTraits.isEmpty)
    }

    /// **逆側。** 一度も焼いていなければ、消して本当に終わりである。
    /// これが無いと `isFullyErased` が常に false でも上のテストは緑になる。
    func testErasureIsCompleteWhenNothingWasEverBurned() async throws {
        let store = try makeInMemoryStore()
        try await makeStyleTrait(in: store)

        let outcome = try await store.eraseAllUserTraits()

        XCTAssertEqual(outcome.deletedTraitCount, 1)
        XCTAssertTrue(outcome.isFullyErased)
        XCTAssertTrue(outcome.generationsStillCarryingErasedTraits.isEmpty)
    }

    // MARK: - 重みへ焼いた印（14.11節 / 判断3）

    /// **どのアダプタに・いつ・何件で・どれだけかかったか。**
    /// 14.15節が設定画面へ出すと決めているものが、すべてこの1行から出ること。
    func testAGenerationRecordsWhichAdapterAndWhen() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store)
        let burnedAt = Date(timeIntervalSince1970: 5_000)

        let generation = try await store.recordAdapterGeneration(
            adapter: .translator,
            modelID: "mlx-community/Qwen3-0.6B-4bit",
            directory: "adapters/translator/v1",
            traitIDs: [trait.id],
            durationMs: 822_000,
            activate: true,
            now: burnedAt
        )

        XCTAssertEqual(generation.adapter, .translator)
        XCTAssertEqual(generation.generation, 1)
        XCTAssertEqual(generation.sampleCount, 1)
        XCTAssertEqual(generation.trainedAt, SophiaTimestamp.truncated(burnedAt))
        XCTAssertEqual(generation.durationMs, 822_000)
        XCTAssertTrue(generation.isActive)

        let bakes = try await store.bakes(inGenerationID: generation.id)
        XCTAssertEqual(bakes.map(\.traitID), [trait.id])
        XCTAssertEqual(bakes.map(\.revision), [1], "焼いた時点の版が記録されること")
    }

    /// **中断された学習では所要時間を測れない**（14.11節②）。0 で埋めないこと。
    func testDurationStaysNilWhenTrainingWasInterrupted() async throws {
        let store = try makeInMemoryStore()

        let generation = try await store.recordAdapterGeneration(
            modelID: "m", directory: "d", traitIDs: []
        )

        XCTAssertNil(
            generation.durationMs,
            "測っていない値が、測った値の顔をして出てきてはいけない"
        )
    }

    /// 世代番号は自動で繰り上がる。
    func testGenerationNumbersAdvanceAutomatically() async throws {
        let store = try makeInMemoryStore()

        let first = try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1", traitIDs: []
        )
        let second = try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v2", traitIDs: []
        )

        XCTAssertEqual([first.generation, second.generation], [1, 2])
    }

    /// **焼いただけでは既定にならない**（14.11節③「勝ったときだけ既定にする」）。
    func testBurningDoesNotActivateByDefault() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store)

        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1", traitIDs: [trait.id]
        )

        let after = try await store.trait(id: trait.id)
        XCTAssertEqual(after?.placement, .stored, "有効化していない世代は効いていない")
        XCTAssertNil(after?.adapterGen)
        let active = try await store.activeAdapterGeneration()
        XCTAssertNil(active)
    }

    func testActivatingAGenerationMovesItsTraitsToTranslating() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1", traitIDs: [trait.id]
        )

        try await store.activateAdapterGeneration(generation: 1)

        let after = try await store.trait(id: trait.id)
        XCTAssertEqual(after?.placement, .translating)
        XCTAssertEqual(after?.adapterGen, 1)
        let waiting = try await store.storedTraitCount()
        XCTAssertEqual(waiting, 0, "反映を待っている件数が減ること（14.15節）")
    }

    /// **14.11節④ 第1段の回復。前の世代へ戻すと、新しい世代でしか焼いていない像は効かなくなる。**
    ///
    /// ここが `adapter_gen`（整数1本）では表せない領域である ──
    /// 戻した先に何が入っていたかを、別の表が覚えている必要がある。
    func testRollingBackToAnOlderGenerationStopsTheNewerTraits() async throws {
        let store = try makeInMemoryStore()
        let old = try await makeStyleTrait(in: store, statement: "v1 から居る像")
        let new = try await makeStyleTrait(in: store, statement: "v2 で入った像")
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [old.id], activate: true
        )
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v2",
            traitIDs: [old.id, new.id], activate: true
        )

        try await store.activateAdapterGeneration(generation: 1)

        let oldAfter = try await store.trait(id: old.id)
        let newAfter = try await store.trait(id: new.id)
        XCTAssertEqual(oldAfter?.placement, .translating)
        XCTAssertEqual(oldAfter?.adapterGen, 1, "戻した先の世代を指していること")
        XCTAssertEqual(
            newAfter?.placement, .stored,
            "**v2 でしか焼いていない像が、v1 に戻したのに効いたままになっている**"
        )
        XCTAssertNil(newAfter?.adapterGen)
    }

    /// 戻しても**焼いた事実は消えない。** 「v2 には入っていた」と言えること。
    func testRollingBackKeepsTheBakeHistory() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true
        )
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v2",
            traitIDs: [trait.id], activate: true
        )

        try await store.activateAdapterGeneration(generation: 1)

        let history = try await store.bakes(ofTrait: trait.id)
        XCTAssertEqual(history.count, 2, "世代を戻したら履歴が消えた")
    }

    /// **14.11節④ 第2段（`unload`）。全部 `stored` に戻る。**
    /// これが NFR-11（縮退）の実体である。
    func testDeactivatingTheAdapterReturnsEveryTraitToStored() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true
        )

        try await store.deactivateAdapter()

        let after = try await store.trait(id: trait.id)
        XCTAssertEqual(after?.placement, .stored)
        XCTAssertNil(after?.adapterGen)
        let active = try await store.statementsInActiveAdapter()
        XCTAssertTrue(active.isEmpty, "外したのに『いま重みに入っている』が空でない")
    }

    /// **同じアダプタで2つの世代が同時に有効になれない**（14.11節③）。
    /// アプリ側の書き忘れでは破れないよう、部分UNIQUE索引で DB が守っている。
    func testOnlyOneGenerationCanBeActivePerAdapter() async throws {
        let store = try makeInMemoryStore()
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "d1", traitIDs: [], activate: true
        )
        let second = try await store.recordAdapterGeneration(
            modelID: "m", directory: "d2", traitIDs: []
        )

        await assertConstraintViolation {
            try await store.executeRawForTesting(
                sql: "UPDATE adapter_generations SET is_active = 1 WHERE id = ?",
                arguments: [second.id]
            )
        }
    }

    /// 別のアダプタなら同時に有効でよい（翻訳役と本体は別物）。
    func testDifferentAdaptersCanBothBeActive() async throws {
        let store = try makeInMemoryStore()

        try await store.recordAdapterGeneration(
            adapter: .translator, modelID: "m", directory: "d1", traitIDs: [], activate: true
        )
        try await store.recordAdapterGeneration(
            adapter: .base, modelID: "m", directory: "d2", traitIDs: [], activate: true
        )

        let translator = try await store.activeAdapterGeneration(.translator)
        let base = try await store.activeAdapterGeneration(.base)
        XCTAssertNotNil(translator)
        XCTAssertNotNil(base)
    }

    /// **`translating` は「翻訳役の重みに入った」という意味である**（`TraitPlacement` の型コメント）。
    ///
    /// 本体（`base`）にだけ焼いた像は、翻訳役には1件も入っていない。
    /// 導出をアダプタで絞らないと、その像が `translating` を名乗り、
    /// **アダプタで絞っている `statementsInActiveAdapter(.translator)` と食い違う** ──
    /// 14.15節の画面が「翻訳役には何も入っていないが、待っている像も0件」と言うことになる。
    ///
    /// `adapter_gen` も同じで、両アダプタを混ぜた `MAX(generation)` を入れると
    /// **翻訳役 v1 の像が本体 v7 を指す**（翻訳役に v7 は存在しない）。
    func testBakingIntoTheBaseAdapterDoesNotTouchTheTranslatorSideDerivation() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store)

        try await store.recordAdapterGeneration(
            adapter: .base, generation: 7, modelID: "mlx-community/Qwen3-8B-4bit",
            directory: "adapters/base/v7", traitIDs: [trait.id], activate: true
        )

        let afterBase = try await store.trait(id: trait.id)
        let inTranslator = try await store.statementsInActiveAdapter(.translator)
        let waiting = try await store.storedTraitCount()
        XCTAssertEqual(afterBase?.placement, .stored, "翻訳役に入っていない像が translating を名乗っている")
        XCTAssertNil(afterBase?.adapterGen, "本体の世代番号が翻訳役の列に漏れている")
        XCTAssertTrue(inTranslator.isEmpty)
        XCTAssertEqual(waiting, 1, "翻訳役から見れば、この像はまだ反映を待っている")

        // 翻訳役へ焼くと、こちらは v1 を指す（本体の v7 に引きずられない）。
        try await store.recordAdapterGeneration(
            adapter: .translator, modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true
        )
        let afterTranslator = try await store.trait(id: trait.id)
        XCTAssertEqual(afterTranslator?.placement, .translating)
        XCTAssertEqual(afterTranslator?.adapterGen, 1, "本体 v7 の番号が翻訳役の列に入っている")
    }

    /// `translating` は**事実であって意思ではない。** 手で書けないこと。
    ///
    /// 書けてしまうと、14.15節の「いま重みに入っている像の一覧」が嘘になる。
    /// しかも**嘘をつく方向が最悪である** ── 消したはずの像が残っているのを見逃す側に倒れる。
    func testTranslatingPlacementCannotBeSetByHand() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store)

        await assertThrows({
            _ = try await store.setTraitPlacement(id: trait.id, to: .translating)
        }, "導出値を手で書けてしまっている")

        let after = try await store.trait(id: trait.id)
        XCTAssertEqual(after?.placement, .stored)
    }

    /// `retrieved` は 14.3節が「枠だけ用意しておく」と決めている引く層である。
    ///
    /// ## 気になるのは「無関係な焼き直し」ではなく、**その像自身が焼かれたとき**である
    ///
    /// 以前はここが**一度も焼かれない無関係な像**しか見ておらず、
    /// `retrieved` が本当に危ない経路を1度も通っていなかった。**通す。**
    ///
    /// | 段 | 置き場所 | |
    /// |---|--:|---|
    /// | 1. 手で `retrieved` にする | `retrieved` | 引く層の枠（14.3節） |
    /// | 2. **無関係な像を焼く** | `retrieved` のまま | 再計算が巻き添えにしないこと |
    /// | 3. **その像自身を焼く** | **`translating`** | **重みが勝つ** |
    /// | 4. 手で `stored` に落とそうとする | `translating` のまま | 導出値は手で書けない |
    /// | 5. **世代を外す**（14.11節④第2段） | **`stored`** | ⚠ `retrieved` は戻ってこない |
    ///
    /// **5段目は既知の割り切りである。** `placement` は1本の列なので、
    /// 「引く層に置く」という利用者の指定と「重みに入っている」という事実を同時には持てない
    /// （**【未確認】両方に同時に置く設計はまだ無い**）。
    /// **ここで固定しておかないと、割り切りが黙って変わる。**
    func testRetrievedSurvivesAnUnrelatedBakeButIsLostOnceItIsBakedItself() async throws {
        let store = try makeInMemoryStore()
        let retrieved = try await store.recordTrait(
            kind: .content, category: "stack", statement: "引く層の枠", source: .manual
        )
        let unrelated = try await makeStyleTrait(in: store)

        // 1. 焼かれていない像なら、指定はそのまま通る。
        let requested = try await store.setTraitPlacement(id: retrieved.id, to: .retrieved)
        XCTAssertEqual(requested, .retrieved, "焼かれていない像の置き場所が指定どおりにならない")

        // 2. 無関係な像を焼いても、引く層の枠は潰れない。
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [unrelated.id], activate: true
        )
        var after = try await store.trait(id: retrieved.id)
        XCTAssertEqual(after?.placement, .retrieved, "焼き直しが無関係な像の置き場所を潰している")
        XCTAssertNil(after?.adapterGen)

        // 3. その像自身を焼くと、重みが勝つ。
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v2",
            traitIDs: [retrieved.id], activate: true
        )
        after = try await store.trait(id: retrieved.id)
        XCTAssertEqual(
            after?.placement, .translating,
            "焼いたのに retrieved のままである（14.15節の『いま重みに入っている像』と食い違う）"
        )
        XCTAssertEqual(after?.adapterGen, 2)

        // 4. 焼かれている像は手で落とせない。**戻り値が実際の置き場所を言う。**
        let effective = try await store.setTraitPlacement(id: retrieved.id, to: .stored)
        XCTAssertEqual(effective, .translating, "重みに入っている像を手で『貯めているだけ』にできている")
        after = try await store.trait(id: retrieved.id)
        XCTAssertEqual(after?.placement, .translating)

        // 5. 外すと `stored` に戻る。**`retrieved` の指定は残らない**（既知の割り切り）。
        try await store.deactivateAdapter()
        after = try await store.trait(id: retrieved.id)
        XCTAssertEqual(
            after?.placement, .stored,
            """
            ⚠ `.retrieved` が返ったなら、割り切りのほうが変わっている。
            そのときはこのテストではなく `Store.setTraitPlacement` の型コメントを直すこと。
            """
        )
        XCTAssertNil(after?.adapterGen)
    }

    /// 何も変わらない再計算では `updated_at` が動かないこと。
    /// 動くと、変わっていない像が設定画面の先頭に来てしまう。
    func testRecalculationDoesNotTouchUnaffectedTraits() async throws {
        let store = try makeInMemoryStore()
        let untouched = try await makeStyleTrait(
            in: store, statement: "無関係な像", at: Date(timeIntervalSince1970: 1_000)
        )
        let burned = try await makeStyleTrait(
            in: store, statement: "焼く像", at: Date(timeIntervalSince1970: 1_000)
        )

        try await store.recordAdapterGeneration(
            modelID: "m", directory: "d", traitIDs: [burned.id], activate: true,
            now: Date(timeIntervalSince1970: 9_000)
        )

        let after = try await store.trait(id: untouched.id)
        XCTAssertEqual(after?.updatedAt, SophiaTimestamp.truncated(Date(timeIntervalSince1970: 1_000)))
    }

    /// **背後で壊された導出値が、次の再計算で直ること**（自己修復）。
    ///
    /// `setTraitPlacement` が塞いだので、**いまアプリの経路からはこの状態を作れない。**
    /// 作れるのは生SQL ── 別の版のアプリ、手作業の DB 編集、これから足す誰かの UPDATE である。
    /// 直せないと、矛盾は一時的な状態ではなく**その世代が有効なあいだ残り続ける。**
    ///
    /// ⚠ 壊し方が要点である。**`placement` だけを落とし、`adapter_gen` は正しいまま残す** ──
    /// 以前の `WHERE`（`adapter_gen` の変化 / `translating` なのに焼かれていない行）は、
    /// **この形をどちらの条件でも拾えなかった。**
    func testRecalculationRepairsAPlacementThatWasCorruptedBehindItsBack() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true
        )

        try await store.executeRawForTesting(
            sql: "UPDATE user_traits SET placement = 'stored' WHERE id = ?",
            arguments: [trait.id]
        )
        let corrupted = try await store.trait(id: trait.id)
        XCTAssertEqual(corrupted?.placement, .stored, "前提が崩れている: 生SQL で壊せていない")
        XCTAssertEqual(corrupted?.adapterGen, 1, "前提が崩れている: 世代まで消えている")

        // 有効な世代を変えない形で再計算を通す（焼く経路はどれも最後にこれを通る）。
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v2", traitIDs: []
        )

        let after = try await store.trait(id: trait.id)
        let waiting = try await store.storedTraitCount()
        XCTAssertEqual(
            after?.placement, .translating,
            "重みに入っている像が『貯めているだけ』のまま残っている（NFR-12）"
        )
        XCTAssertEqual(after?.adapterGen, 1)
        XCTAssertEqual(waiting, 0, "14.15節の『反映を待っている件数』に、待っていない像が混ざっている")
    }

    // MARK: - 重みへ移す関門（14.14節 / 判断2）

    /// **出所によって確信度が違うこと。**
    ///
    /// 値そのものではなく**順序**を固定してある ── 絶対値は【未確認】であり、
    /// 意味を持つのは 14.14節（`translation_edit` が最も密度が高い）と
    /// 14.8節（自己申告は様式について当てにならない）が定めた大小関係のほうである。
    func testConfidenceDefaultsRankSourcesTheWayChapter14Does() {
        XCTAssertGreaterThan(
            TraitSource.translationEdit.defaultConfidence,
            TraitSource.correction.defaultConfidence,
            "14.14節は translation_edit を『最も密度の高い出所』と名指ししている"
        )
        XCTAssertGreaterThan(
            TraitSource.correction.defaultConfidence,
            TraitSource.onboarding.defaultConfidence,
            "訂正は顕示選好、初回質問は自己申告（14.8節）"
        )
        XCTAssertEqual(
            TraitSource.onboarding.defaultConfidence,
            TraitSource.manual.defaultConfidence,
            "正しい差は kind との組で決まる。**測っていないので数字を発明していない**"
        )
    }

    /// **関門が結果として何を分けているか。** 数字合わせではなく振る舞いで固定する。
    ///
    /// 一度で通るのは `translation_edit` だけである（14.14節がそう位置づけている）。
    func testOnlyTranslationEditsClearTheGateWithoutReinforcement() async throws {
        let store = try makeInMemoryStore()
        for source in TraitSource.allCases {
            try await store.recordTrait(
                kind: .style, category: "tone", statement: source.rawValue, source: source
            )
        }

        let ready = try await store.traitsForTraining()

        XCTAssertEqual(
            ready.map(\.statement),
            [TraitSource.translationEdit.rawValue],
            "関門を通る出所が変わっている: \(ready.map { "\($0.statement)=\($0.confidence)" })"
        )
    }

    /// 訂正が積み重なると関門を越える（14.14節「訂正で強化される」）。
    ///
    /// ⚠ **何回で越えるかは主張していない。**
    /// 既定値も刻み幅も【未確認】であり、測れば動く数字である。
    /// 回数を書き込むと、**定数を測って直したときに、無関係な理由でここが落ちる。**
    /// 主張は「強化を重ねれば越えられる」と「1件では越えない」の2つだけである。
    func testReinforcementCarriesAnOnboardingTraitThroughTheGate() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store, source: .onboarding)

        var attempts = 0
        var ready = try await store.traitsForTraining()
        XCTAssertTrue(ready.isEmpty, "初回質問1件だけで学習に入ってはいけない（14.9節 / 14.16節①）")

        while ready.isEmpty, attempts < 20 {
            try await store.reinforceTrait(id: trait.id, source: .correction)
            ready = try await store.traitsForTraining()
            attempts += 1
        }

        XCTAssertEqual(ready.map(\.id), [trait.id], "強化を20回重ねても関門を越えない")
        XCTAssertGreaterThan(attempts, 0)
    }

    /// 陳腐化した内容は焼かない。**消せない誤りになる。**
    func testExpiredContentNeverEntersTheTrainingSet() async throws {
        let store = try makeInMemoryStore()
        try await store.recordTrait(
            kind: .content,
            category: "stack",
            statement: "去年の案件",
            source: .manual,
            confidence: 1.0,
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )

        let ready = try await store.traitsForTraining(now: Date(timeIntervalSince1970: 2_000))

        XCTAssertTrue(ready.isEmpty)
    }

    /// **既に焼いた像も、次の世代の学習データに残る。**
    ///
    /// 絞ってしまうと、v2 を学習するたびに v1 が覚えたことを忘れ、
    /// 14.11節③（世代を並べ、勝ったときだけ採用する）が成立しない。
    func testAlreadyBurnedTraitsStayInTheTrainingSet() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store, source: .translationEdit)
        try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true
        )

        let ready = try await store.traitsForTraining()

        XCTAssertEqual(
            ready.map(\.id), [trait.id],
            "**v2 の学習データから v1 の像が落ちている。** 世代を重ねるたびに忘れることになる"
        )
    }

    /// **関門が2か所に書かれていることの見張り。**
    ///
    /// 判定は SQL（`traitsForTraining`）と Swift（`UserTraitRecord.qualifiesForTraining`）の
    /// 両方にある。**同じ規則を2か所に書いたら、いつか食い違う。**
    ///
    /// ## 「両者が一致すること」だけを見てはいけない
    ///
    /// 以前はここが**2つの集合が等しいこと**しか見ていなかった。それでは
    /// **両方が同時に `>=` から `>` へ変わっても緑のまま**で、
    /// 2か所が仲良く間違っている状態を検出できない。
    /// **したがって、期待する集合を先に書き下ろし、両者をそれぞれ突き合わせる。**
    ///
    /// | 値 | 期待 | なぜ |
    /// |---|---|---|
    /// | 確信度 = 閾値ちょうど | **通る** | 閾値は「以上」（`confidence >= ?`） |
    /// | 確信度 = 閾値の1つ下 | 落ちる | |
    /// | 期限 = いまちょうど | **落ちる** | 期限は「より後」（`expires_at > ?`）＝ その瞬間に切れる |
    /// | 期限 = 1ミリ秒あと | 通る | |
    ///
    /// **閾値そのものは書かない。** 0.7 は【未確認】の仮置きであり（14.13c節）、
    /// 意味を持つのは値ではなく**境界がどちら側にあるか**である。
    func testTheSwiftGateAndTheSQLGateAgreeOnTheDocumentedBoundary() async throws {
        let store = try makeInMemoryStore()
        let now = Date(timeIntervalSince1970: 5_000)
        let threshold = UserTraitDefaults.trainingConfidenceThreshold

        // 確信度の境界（様式。期限を持てない）
        let onTheLine = try await store.recordTrait(
            kind: .style, category: "tone", statement: "閾値ちょうど",
            source: .manual, confidence: threshold
        )
        let justUnder = try await store.recordTrait(
            kind: .style, category: "tone", statement: "閾値の1つ下",
            source: .manual, confidence: threshold.nextDown
        )
        let justOver = try await store.recordTrait(
            kind: .style, category: "tone", statement: "閾値の1つ上",
            source: .manual, confidence: threshold.nextUp
        )
        let farUnder = try await store.recordTrait(
            kind: .style, category: "tone", statement: "関門から遠い下",
            source: .manual, confidence: 0.0
        )
        // 期限の境界（内容。確信度は全部 1.0 にして、落ちる理由を期限だけにする）
        let expiredAlready = try await store.recordTrait(
            kind: .content, category: "stack", statement: "1ミリ秒前に切れた",
            source: .manual, confidence: 1.0, expiresAt: now.addingTimeInterval(-0.001)
        )
        let expiringNow = try await store.recordTrait(
            kind: .content, category: "stack", statement: "いま切れる",
            source: .manual, confidence: 1.0, expiresAt: now
        )
        let expiringLater = try await store.recordTrait(
            kind: .content, category: "stack", statement: "1ミリ秒あとに切れる",
            source: .manual, confidence: 1.0, expiresAt: now.addingTimeInterval(0.001)
        )

        // **期待する集合を先に書き下ろす。** 両者の一致だけでは、揃って間違ったことに気づけない。
        let expected = [onTheLine.id, justOver.id, expiringLater.id].sorted()
        let fromSQL = try await store.traitsForTraining(now: now).map(\.id).sorted()
        let fromSwift = try await store.allTraits()
            .filter { $0.qualifiesForTraining(now: now) }
            .map(\.id).sorted()

        XCTAssertEqual(
            fromSQL, expected,
            "SQL 側の関門が境界からずれている（閾値は『以上』、期限は『より後』）"
        )
        XCTAssertEqual(fromSwift, expected, "Swift 側の関門が境界からずれている")
        XCTAssertEqual(fromSQL, fromSwift, "SQL 側と Swift 側で関門の判定がずれている")

        // 落ちた側も名指しておく（`expected` を作り間違えたときに、これが先に落ちる）。
        for excluded in [justUnder, farUnder, expiredAlready, expiringNow] {
            XCTAssertFalse(
                fromSQL.contains(excluded.id),
                "関門を通ってはいけない像が通っている: \(excluded.statement)"
            )
        }
    }

    // MARK: - 件数に上限を置かないこと（14.16節⑦ の未決に対する備え）

    /// **10.5節は「数千件」、第14章は「数十〜数百件」で食い違っている。**
    /// どちらが正しくても壊れないよう、この層は件数を制限しない。

    /// 少数側。**1件でも成立する。**
    func testASingleTraitIsEnoughToRecordAGeneration() async throws {
        let store = try makeInMemoryStore()
        let trait = try await makeStyleTrait(in: store, source: .translationEdit)

        let generation = try await store.recordAdapterGeneration(
            modelID: "m", directory: "adapters/translator/v1",
            traitIDs: [trait.id], activate: true
        )

        XCTAssertEqual(generation.sampleCount, 1)
        let ready = try await store.traitsForTraining()
        XCTAssertEqual(ready.count, 1)
    }

    /// 0件でも記録できる（素の状態を世代として残す場合）。
    func testAGenerationWithNoTraitsIsAllowed() async throws {
        let store = try makeInMemoryStore()

        let generation = try await store.recordAdapterGeneration(
            modelID: "m", directory: "d", traitIDs: [], activate: true
        )

        XCTAssertEqual(generation.sampleCount, 0)
    }

    /// 多数側。**天井が無いこと。**
    ///
    /// ⚠ 300 は「300件までは大丈夫」を測っているのではない。
    /// **`LIMIT` や暗黙の上限がどこにも入っていない**ことを確かめている。
    /// 上限があるなら、それは 300 より小さい値として現れる。
    func testTheTrainingSetHasNoUpperBound() async throws {
        let store = try makeInMemoryStore()
        for index in 0..<300 {
            try await store.recordTrait(
                kind: .style,
                category: "tone",
                statement: "様式 \(index)",
                source: .translationEdit
            )
        }

        let ready = try await store.traitsForTraining()
        let all = try await store.allTraits()

        XCTAssertEqual(ready.count, 300)
        XCTAssertEqual(all.count, 300)
    }

    // MARK: - 存在しない像への操作

    func testRevisingAMissingTraitFails() async throws {
        let store = try makeInMemoryStore()

        await assertThrows {
            try await store.reviseTrait(id: "そんな像は無い", statement: "x", source: .manual)
        }
    }

    func testReinforcingAMissingTraitFails() async throws {
        let store = try makeInMemoryStore()

        await assertThrows {
            _ = try await store.reinforceTrait(id: "そんな像は無い", source: .correction)
        }
    }
}
