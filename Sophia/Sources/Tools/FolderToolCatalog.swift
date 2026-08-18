import Foundation

/// **モデルへ渡す3つのツール**（DESIGN.md 第16.4節）。
///
/// ---
///
/// # 4つ目を足さないこと
///
/// > 4つ目を足したくなったら、まず3つで足りなかった実例を出すこと。
/// > **定義1つが、そのまま `armed` の間の毎ターンの費用になる**（16.4節 / 16.2節）
///
/// Open WebUI は32個・約4,550トークンを毎ターン注入し、「こんにちは」への応答を34秒にしていた
/// （2.2節）。**同じ構造を自分で作れば、VISION 第1因子を自分で潰す。**
/// だから定義は3つに固定し、説明文も短く書いてある ── 読みやすさのために1文足すと、
/// **その1文を会話のターン数だけ払う。**
///
/// # 説明文を英語で書く理由（**2026-08-18 実測。日本語へ戻す前に読むこと**）
///
/// **テンプレートの `tool | tojson` は非ASCIIを `\uXXXX` へ展開する。**
/// 日本語1文字が ASCII 6文字になり、**素の158トークンが約1,100トークンに膨らむ**（約7倍）。
/// 出荷する定義を日本語で書くと **1,182トークン ＝ 入力予算1,000 の 118%** で、
/// **利用者が1文字も打つ前に予算を超える。** プリフィルは毎ターン約8.2秒。
///
/// **英語なら 324トークン（-73%）、プリフィル 2.7秒。**
/// 他の案（引数を削る・ツールを減らす）はどれも100トークン台で、桁が違う。
///
/// **これは「日本語が高い」という一般則ではない。** `tojson` を通る場所だけの話で、
/// **system プロンプトも会話本文も展開されない**（`make toolbreakdown` が実物を出す）。
/// 利用者に見せる文言（`FolderAccessError` / `ReadOutcome`）は日本語のままでよい。
///
/// **戻すなら `make toolbreakdown` と `make toolprobe` を両方流すこと。**
///
/// # 名前は実測に合わせてある（`find_files` ではない）
///
/// DESIGN 16.4節の表は3つ目を `find_files`（`pattern` / `path`）と書いているが、
/// **2026-08-18 に実機で測ったのは `search_files`（`path` / `query`）のほう**である
/// （`ToolCallProbeTests.swift`。日本語9/9・誤爆0/6）。
/// **測っていない名前を実装に選ぶ理由が無い**ので、測ったほうを採る。
/// 引数側は `query` を主とし、`pattern` / `name` も受ける（`FolderToolExecution`）。
///
/// # 【未確認】説明文は測ったものと違う
///
/// プローブの説明文は「ディレクトリのパス」だった。**それだと `~/Documents` が返ってくる** ──
/// 実際に返ってきた（16.9節の実測記録）。16.4節は「`path` は結び付いたフォルダからの
/// **相対パス**とする。絶対パスを受け取らない」と決めているので、説明文を書き直してある。
///
/// **書き直した説明文での呼び出し成功率は測っていない。**
/// 説明文はモデルの挙動を変える入力である ── `make toolprobe` を**この定義で**流し直すこと。
/// なお相対パスで書かせ損ねても封じ込めが落とすだけで、事故にはならない（16.5節）。
enum FolderTool: String, Sendable, Equatable, CaseIterable {

    /// 配下の一覧（16.4節）。
    case listDirectory = "list_directory"

    /// テキストを**窓で**読む（16.4節）。
    case readFile = "read_file"

    /// 名前で探す（16.4節の3つ目。名前は実測に合わせてある）。
    case searchFiles = "search_files"

    // MARK: - 引数の名前

    /// **モデルが書いてくる鍵の綴り。** 実装側で散らさないこと ──
    /// 散らすと、綴りを1か所直したときに受け取り側だけが古いままになる。
    enum Argument {
        static let path = "path"
        static let offset = "offset"
        static let limit = "limit"
        static let query = "query"
        /// `query` の別名。**モデルは同じ意味を別の名前で書いてくることがある。**
        /// 受ける側が緩いぶんには害が無い（封じ込めは名前ではなく値に効く）。
        static let queryAliases = ["query", "pattern", "name", "keyword"]
    }

    // MARK: - モデルへ渡す形

    /// **出所はここ1本だけである**（2026-08-18 に統合）。
    ///
    /// ---
    ///
    /// # 生の JSON 辞書はもう持たない
    ///
    /// **以前ここには `jsonSchemas: [[String: any Sendable]]` があり、出所が2つに割れていた。**
    ///
    /// | かつての出所 | 誰が読んでいたか |
    /// |---|---|
    /// | `jsonSchemas`（英語。実測で決めた文言） | **テストだけ** |
    /// | `ChatOptions.tools`（`[ToolDefinition]`） | **実行時はこちら。誰も populate していなかった** |
    ///
    /// **この割れが同じ日に2回、嘘の測定値を生んでいる**（16.9節 項目4 の但し書き）──
    /// `ToolCallProbeTests` の「12/12」も `EngineToolWiringTests` の「716トークン」も、
    /// **テストが自前に持っていた定義**に対する値で、実装の値ではなかった（実費は 1,182）。
    /// **定義を写した瞬間、計測は計測自身を測る道具になる。**
    ///
    /// だから**アプリが実際に送る型そのもの**（`ToolDefinition`）で宣言する。
    /// JSON Schema へ落とすのは `MLXEngine.toolSpec(for:)` の仕事であり、
    /// **この層は MLX を import しない**（import した瞬間、ツールの定義と実行が
    /// モデルの有無に依存し始め、テストが実推論を要求するようになる ──
    /// `TokenCounter` が MLX を避けているのと同じ理由）。
    ///
    /// # 説明文は1文字も変えないこと（**実測で決まっている**）
    ///
    /// `ja-read` は**語順を変えただけで 3/3 → 0/3 に崩れた**
    /// （`Read a text file by line range` と手段を先頭に置いたため）。
    /// `Read the contents of a text file` に戻して **32/32**。
    /// **変えたら `make toolprobe` と `make toolbreakdown` の測り直しになる。**
    ///
    /// # 引数の並びが `required` の並びになる
    ///
    /// `ToolDefinition.requiredParameterNames` は**この配列の順**を保つ
    /// （辞書ではないのはそのため）。`search_files` が `path` → `query` の順に
    /// 並んでいるのは、実測した `required: ["path", "query"]` と一致させるためである。
    /// **並べ替えないこと。**
    static var definitions: [ToolDefinition] {
        [
            ToolDefinition(
                name: FolderTool.listDirectory.rawValue,
                description: "List the direct children of a folder",
                parameters: [
                    required(
                        Argument.path, .string,
                        "Path relative to the bound folder. Empty string for the folder "
                            + "itself. Absolute paths and ~ are rejected")
                ]
            ),
            ToolDefinition(
                name: FolderTool.readFile.rawValue,
                description:
                    "Read the contents of a text file. Long files are clipped; "
                    + "continue with offset",
                parameters: [
                    required(
                        Argument.path, .string,
                        "Path relative to the bound folder. Absolute paths and ~ are rejected"),
                    optional(Argument.offset, .integer, "Line to start from (1-based)"),
                    optional(
                        Argument.limit, .integer,
                        "How many lines to read (max \(FolderReadLimits.lineLimit))"),
                ]
            ),
            ToolDefinition(
                name: FolderTool.searchFiles.rawValue,
                description: "Find files and folders whose name contains the given word",
                parameters: [
                    required(
                        Argument.path, .string,
                        "Where to start. Empty string for the whole bound folder"),
                    required(Argument.query, .string, "Word contained in the file name"),
                ]
            ),
        ]
    }

    private static func required(
        _ name: String, _ type: ToolDefinition.Parameter.ValueType, _ description: String
    ) -> ToolDefinition.Parameter {
        ToolDefinition.Parameter(
            name: name, type: type, description: description, isRequired: true)
    }

    private static func optional(
        _ name: String, _ type: ToolDefinition.Parameter.ValueType, _ description: String
    ) -> ToolDefinition.Parameter {
        ToolDefinition.Parameter(
            name: name, type: type, description: description, isRequired: false)
    }
}
