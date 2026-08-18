import Foundation
import GRDB

/// マイグレーションの識別子。
///
/// GRDB は適用済みの識別子を `grdb_migrations` テーブルに文字列で残す。
/// **一度出荷した文字列は永久に変えられない**（変えると既存DBに再適用されて壊れる）。
/// enum にしてあるのは、その「変えてはいけない文字列」を1か所に閉じ込めるためである。
enum SophiaMigration: String, CaseIterable, Sendable {

    /// DESIGN.md 第8章の初版スキーマ一式。
    case v1Initial = "v1.initial"

    /// DESIGN.md 14.14節。利用者像（FR-24〜29）の永続化。
    ///
    /// **第8章の `profiles`（アシスタント側の役割）とは別の表である。**
    /// 増えるのは4枚 ── `user_traits` / `user_trait_revisions` /
    /// `adapter_generations` / `user_trait_bakes`。
    case v2UserTraits = "v2.userTraits"

    // ## ここから下は A3 で足す。順番に追記すること（挿入しない）
    //
    // ⚠ 番号は**登録順**である。上に v2 が入ったので、下の予約は v3 / v4 へ繰り下げた。
    // **どちらもまだ1度も登録されていない（コメントのままである）ので、
    // 既存DBに焼かれた識別子は1つも変わっていない。**
    //
    // case v3FullTextSearch = "v3.fts5"
    //     FR-13。messages の外部コンテンツ FTS5 仮想テーブル（第8.1節）
    //
    // case v4ExtendedStats = "v4.stats"
    //     第8.3節。ttfr_ms / prompt_tokens_per_sec / thinking_chars /
    //     stop_reason / thinking_enabled / peak_memory_bytes を messages に追加
}

/// DESIGN.md 第8章のスキーマを、**生SQLのまま**適用する。
///
/// ## 生SQLを保つ理由（第8.1節）
///
/// > スキーマの一次情報が設計書であり続ける。ORM の DSL に翻訳すると
/// > 設計書と実装がずれ、どちらが正か分からなくなる
///
/// したがって下の SQL は **DESIGN.md 第8章からの逐語コピー**である。
/// 整形も変えていない。**設計書を直さずにここだけ直さないこと。**
///
/// ## 足し方
///
/// 既存の `registerMigration` を書き換えてはいけない。出荷済みのDBには
/// 適用済みとして記録が残っており、二度と走らないからである。
/// **必ず新しい識別子を末尾に足す。**
enum SophiaMigrations {

    /// この migrator を `Store` が開くたびに走らせる。適用済みのものは飛ばされる。
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // ⚠ 開発中にスキーマを変えたら消して作り直す、という設定がGRDBにはあるが
        // （`eraseDatabaseOnSchemaChange`）、**入れない。**
        // VISION が「原ログを完全に保持する」を要約の安全網かつ
        // 遺伝的アルゴリズムの評価基盤に据えている以上、
        // 会話が黙って消える経路をコードに置くべきではない。

        migrator.registerMigration(SophiaMigration.v1Initial.rawValue) { db in
            try db.execute(sql: Self.v1InitialSQL)
        }

        // ⚠ **上の1行に触れないこと。** 出荷済みのDBには適用済みとして記録が残っており、
        // 中身を変えても二度と走らない。**足すのは必ず下である。**
        migrator.registerMigration(SophiaMigration.v2UserTraits.rawValue) { db in
            try db.execute(sql: Self.v2UserTraitsSQL)
        }

        return migrator
    }

    /// DESIGN.md 第8章（+ 第8.2節の `models` 改訂）の逐語コピー。
    ///
    /// `profiles` を先に作るのは `conversations.profile_id` がそこを参照しているため。
    /// SQLite は前方参照でも作成自体は通るが、読む人のために依存順に並べてある。
    static let v1InitialSQL = """
        -- modelfiles/*.Modelfile に相当。役割の切替（FR-05）
        CREATE TABLE profiles (
          id            TEXT PRIMARY KEY,
          name          TEXT NOT NULL,
          system_prompt TEXT NOT NULL,
          params_json   TEXT NOT NULL
        );

        CREATE TABLE conversations (
          id          TEXT PRIMARY KEY,
          title       TEXT    NOT NULL,
          model_id    TEXT    NOT NULL,
          profile_id  TEXT    REFERENCES profiles(id),
          created_at  INTEGER NOT NULL,
          updated_at  INTEGER NOT NULL
        );

        CREATE TABLE messages (
          id              TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
          role            TEXT NOT NULL CHECK (role IN ('system','user','assistant')),
          content         TEXT NOT NULL,
          thinking        TEXT,              -- 思考モードの出力。本文と分けて保持（第6章）
          created_at      INTEGER NOT NULL,
          -- FR-14 用の実測値。会話ごとの体感差を後から検証できるようにする
          input_tokens    INTEGER,
          output_tokens   INTEGER,
          ttft_ms         INTEGER,
          tokens_per_sec  REAL
        );
        CREATE INDEX idx_messages_conv ON messages(conversation_id, created_at);

        -- 第8.2節: MLX形式は複数ファイルのディレクトリなので、
        -- v1.1 の「filename と sha256 が単数」から改訂されている
        CREATE TABLE models (
          id               TEXT PRIMARY KEY,   -- 例 'mlx-community/Qwen3-8B-4bit'
          directory        TEXT NOT NULL,      -- Application Support 配下の相対パス
          total_bytes      INTEGER NOT NULL,
          downloaded_bytes INTEGER NOT NULL DEFAULT 0,
          state            TEXT NOT NULL
                           CHECK (state IN ('pending','downloading','ready','corrupt'))
        );

        -- NFR-08（sha256 検証）はファイル単位になる
        CREATE TABLE model_files (
          model_id   TEXT    NOT NULL REFERENCES models(id) ON DELETE CASCADE,
          path       TEXT    NOT NULL,         -- ディレクトリ内の相対パス
          sha256     TEXT    NOT NULL,
          size_bytes INTEGER NOT NULL,
          PRIMARY KEY (model_id, path)
        );
        """

    /// DESIGN.md 14.14節（利用者像 / FR-24〜29）。
    ///
    /// ## 14.14節の生SQL からの逸脱（4点。**設計書の担当者に反映してもらうこと**）
    ///
    /// 第8.1節の「生SQL を保つ／設計書が一次情報」の方針は守っているが、
    /// **14.14節の SQL をそのまま書き写すと、既存の約束と衝突する箇所が4つある。**
    /// 逐語コピーではないので、変えたところを全部ここに書き出す。
    ///
    /// | # | 14.14節 | ここ | 理由 |
    /// |---|---|---|---|
    /// | 1 | `created_at TEXT` ほか時刻列が **TEXT** | **INTEGER**（ミリ秒） | `SophiaTimestamp` が第8章の時刻を「Unixエポックからのミリ秒」に確定させ、「以後この1か所だけを参照する」と決めている。**同じDBで TEXT と INTEGER の時刻が混ざると、表をまたぐ比較のたびに綴りを覚えていないと書けない** |
    /// | 2 | CHECK 制約が**無い** | `kind` / `source` / `placement` に CHECK | 第8章 `messages.role` と `models.state` の約束（**型と DB の綴りを一致させる**）を新しい表にも適用した。14.14節の本文は許される値を列挙しているので、**列挙を制約として書き下ろしただけ**である |
    /// | 3 | ─ | `CHECK (kind <> 'style' OR expires_at IS NULL)` | 14.14節の「**内容にだけ入れる。様式は期限を持たない**」を注意書きではなく DB で守る。**陳腐化した内容が様式まで汚す**のを防ぐことが 14.14節の判断そのものだから |
    /// | 4 | ─ | `CHECK (confidence BETWEEN 0 AND 1)` | `confidence` は**重みへ移す関門**である（14.14節）。範囲外の値は閾値を素通りする |
    ///
    /// ## 14.14節に**無い表を3枚足している**
    ///
    /// 足した理由は各レコード型の型コメントに書いた。要約すると:
    ///
    /// | 表 | 何が足りなかったか |
    /// |---|---|
    /// | `user_trait_revisions` | 14.14節は「**内容は上書き**」と書いているが、上書きすると前の文が消える。**第8.4節（原ログを要約で上書きしない）と NFR-12 に反する** |
    /// | `adapter_generations` | `adapter_gen`（整数1本）では「**どのアダプタに、いつ**」に答えられない。14.15節が設定画面に出すと決めている「いつ / 何件で / どれだけかかったか」も出せない |
    /// | `user_trait_bakes` | 整数1本は**最新の1件しか覚えていない。** 14.11節④の「前の世代へ戻す」をした後、その世代に何が入っていたかを言えない |
    static let v2UserTraitsSQL = """
        -- 利用者像。**profiles（役割）とは別物。**
        CREATE TABLE user_traits (
          id          TEXT PRIMARY KEY,
          -- 'content'（内容 / 陳腐化する） or 'style'（様式 / 蓄積する）
          kind        TEXT NOT NULL CHECK (kind IN ('content','style')),
          -- 分類。'machine' / 'stack' / 'granularity' / 'tone' など。
          -- **閉じた列挙ではないので CHECK を付けない**（増えるたびに移行が要る）
          category    TEXT NOT NULL,
          -- 本体。**言語化された文。焼き込んだ後も消さない**（14.11節④ / NFR-12）
          statement   TEXT NOT NULL,
          -- どこから来たか。NFR-12 の実現手段
          source      TEXT NOT NULL
                      CHECK (source IN ('onboarding','correction','translation_edit','manual')),
          -- 確信度。訂正で強化される。**重みへ移す関門**
          confidence  REAL NOT NULL DEFAULT 0.5
                      CHECK (confidence >= 0.0 AND confidence <= 1.0),
          -- 'stored'（既定・送らない） / 'translating'（翻訳役の重みに入った） /
          -- 'retrieved'（必要時に引く）。**既定が stored であることが 14.7節の主張である**
          placement   TEXT NOT NULL DEFAULT 'stored'
                      CHECK (placement IN ('stored','translating','retrieved')),
          -- どの世代のアダプタに入ったか。NULL なら未反映。
          -- **導出値である**（原本は user_trait_bakes）
          adapter_gen INTEGER,
          -- 内容にだけ入れる。様式は期限を持たない（下の CHECK で守る）
          expires_at  INTEGER,
          created_at  INTEGER NOT NULL,
          updated_at  INTEGER NOT NULL,
          CHECK (kind <> 'style' OR expires_at IS NULL)
        );
        CREATE INDEX idx_user_traits_kind ON user_traits(kind, category);
        CREATE INDEX idx_user_traits_placement ON user_traits(placement, confidence);

        -- **言語化された文の履歴。追記専用。**
        -- 第8.4節「原ログを要約で上書きしない」を利用者像へ適用したもの。
        -- 消えるのは利用者が消したときだけ（CASCADE / FR-28）
        CREATE TABLE user_trait_revisions (
          id         TEXT PRIMARY KEY,
          trait_id   TEXT NOT NULL REFERENCES user_traits(id) ON DELETE CASCADE,
          revision   INTEGER NOT NULL,   -- 1 から。1 が最初に言語化された文
          statement  TEXT NOT NULL,      -- **その時点の文。二度と書き換えない**
          confidence REAL NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
          source     TEXT NOT NULL
                     CHECK (source IN ('onboarding','correction','translation_edit','manual')),
          created_at INTEGER NOT NULL,
          UNIQUE (trait_id, revision)
        );

        -- アダプタの世代（14.11節③）。**重みそのものはファイルで持つ。DB には入れない**
        CREATE TABLE adapter_generations (
          id           TEXT PRIMARY KEY,
          adapter      TEXT NOT NULL CHECK (adapter IN ('translator','base')),
          generation   INTEGER NOT NULL CHECK (generation >= 1),
          -- どのモデル用のアダプタか。8B 用を 0.6B へ読ませる取り違えを防ぐ
          model_id     TEXT NOT NULL,
          -- Application Support 配下の**相対**パス。例 'adapters/translator/v1'
          directory    TEXT NOT NULL,
          -- 何件で焼いたか。**上限も下限も置かない**（必要件数は未決 / 14.16節⑦）
          sample_count INTEGER NOT NULL CHECK (sample_count >= 0),
          trained_at   INTEGER NOT NULL,
          -- 中断された学習では測れない（14.11節②）。**0 で埋めないこと**
          duration_ms  INTEGER,
          is_active    INTEGER NOT NULL DEFAULT 0 CHECK (is_active IN (0, 1)),
          UNIQUE (adapter, generation)
        );
        -- **同じアダプタで同時に有効な世代は1つだけ。** 部分UNIQUE索引で DB が守る
        CREATE UNIQUE INDEX idx_adapter_generations_active
          ON adapter_generations(adapter) WHERE is_active = 1;

        -- どの像がどの世代に入ったか。追記専用。
        -- **revision があるので「重みの中にあるのはどの版の文か」が言える**（NFR-12）
        CREATE TABLE user_trait_bakes (
          trait_id              TEXT NOT NULL
                                REFERENCES user_traits(id) ON DELETE CASCADE,
          adapter_generation_id TEXT NOT NULL
                                REFERENCES adapter_generations(id) ON DELETE CASCADE,
          revision              INTEGER NOT NULL,   -- **焼いた時点の版**
          baked_at              INTEGER NOT NULL,
          PRIMARY KEY (trait_id, adapter_generation_id)
        );
        CREATE INDEX idx_user_trait_bakes_generation
          ON user_trait_bakes(adapter_generation_id);
        """
}
