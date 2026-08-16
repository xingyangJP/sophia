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

    // ## ここから下は A3 で足す。順番に追記すること（挿入しない）
    //
    // case v2FullTextSearch = "v2.fts5"
    //     FR-13。messages の外部コンテンツ FTS5 仮想テーブル（第8.1節）
    //
    // case v3ExtendedStats = "v3.stats"
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
}
