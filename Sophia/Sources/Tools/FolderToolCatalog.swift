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

    /// `MLXLMCommon.ToolSpec`（= `[String: any Sendable]`）と**同じ形**の JSON Schema。
    ///
    /// **この層は MLX を import しない。** import した瞬間、
    /// ツールの定義と実行がモデルの有無に依存し始め、テストが実推論を要求するようになる
    /// （`TokenCounter` が MLX を避けているのと同じ理由）。
    /// 受け渡しは構造だけで足りる ── `UserInput(chat:tools:)` へはこの配列をそのまま渡せる。
    static var jsonSchemas: [[String: any Sendable]] {
        [
            schema(
                name: FolderTool.listDirectory.rawValue,
                description: "指定したフォルダの直下を一覧する",
                properties: [
                    Argument.path: property(
                        "string", "結び付けたフォルダからの相対パス。フォルダ自身は空文字。絶対パスと ~ は使えない")
                ],
                required: [Argument.path]
            ),
            schema(
                name: FolderTool.readFile.rawValue,
                description: "テキストファイルを行の範囲で読む。長い場合は切られるので続きは offset で読む",
                properties: [
                    Argument.path: property(
                        "string", "結び付けたフォルダからの相対パス。絶対パスと ~ は使えない"),
                    Argument.offset: property("integer", "何行目から読むか（1始まり）"),
                    Argument.limit: property(
                        "integer", "何行読むか（上限 \(FolderReadLimits.lineLimit)）"),
                ],
                required: [Argument.path]
            ),
            schema(
                name: FolderTool.searchFiles.rawValue,
                description: "名前に指定の語を含むファイル・フォルダを配下から探す",
                properties: [
                    Argument.path: property(
                        "string", "探索の起点。結び付けたフォルダ全体なら空文字"),
                    Argument.query: property("string", "ファイル名に含まれる語"),
                ],
                required: [Argument.path, Argument.query]
            ),
        ]
    }

    private static func schema(
        name: String,
        description: String,
        properties: [String: any Sendable],
        required: [String]
    ) -> [String: any Sendable] {
        let function: [String: any Sendable] = [
            "name": name,
            "description": description,
            "parameters": [
                "type": "object",
                "properties": properties,
                "required": required,
            ] as [String: any Sendable],
        ]
        return ["type": "function", "function": function]
    }

    private static func property(_ type: String, _ description: String) -> [String: any Sendable] {
        ["type": type, "description": description]
    }
}
