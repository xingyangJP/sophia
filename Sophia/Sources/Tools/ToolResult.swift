import Foundation

/// 呼び出しそのものが成り立たなかった場合（ファイルにも封じ込めにも到達していない）。
///
/// `FolderAccessError` と分けてあるのは**宛先が同じでも原因の層が違う**からである。
/// あちらは「読もうとして駄目だった」、こちらは「読む以前に呼び出しが成立していない」。
/// 混ぜると、モデルへの返答が「次に何を試せるか」を言えなくなる。
enum ToolRejection: Sendable, Equatable {

    /// 3つのどれでもない名前だった（16.8節「ツール名が一致しない」）。
    case unknownTool(String)

    /// 必須の引数が無い、または型が違って読めなかった。
    case missingArgument(tool: String, name: String)

    /// **往復の回数が上限に達した**（16.8節「往復には回数の上限を置くこと」）。
    case callLimitReached(Int)

    /// モデルへ返す文（16.8節「往復を1回で打ち切らない」ため、次の手まで書く）。
    ///
    /// **モデルが書いた文字列をここへ素で混ぜないこと。** 混ぜる場合は
    /// `ToolText.singleLine(_:limit:)` を通す（この型のコメントではなく `ToolResult` の但し書きを読むこと）。
    var modelMessage: String {
        switch self {
        case .unknownTool(let name):
            "失敗: \(ToolText.toolName(name)) というツールはありません。"
                + "使えるのは list_directory / read_file / search_files の3つだけです。"

        case .missingArgument(let tool, let name):
            "失敗: \(tool) には \(name) が要ります。"
                + "path は結び付けられたフォルダからの相対パス（例: notes.md、docs/仕様.md）で指定してください。"

        case .callLimitReached(let limit):
            "失敗: この会話でのファイル参照は上限（\(limit)回）に達しました。"
                + "これ以上は読めません。**いま分かっている範囲で答え、"
                + "分からない部分は分からないと書いてください。**"
        }
    }

    /// 利用者へ見せる文（FR-11）。
    var userMessage: String {
        switch self {
        case .unknownTool(let name):
            "モデルが存在しないツール（\(ToolText.toolName(name))）を呼びました。"
        case .missingArgument(let tool, let name):
            "モデルのツール呼び出しに \(name) がありませんでした（\(tool)）。"
        case .callLimitReached(let limit):
            "ファイル参照の回数が上限（\(limit)回）に達しました。"
        }
    }
}

/// ツール1回の結果。**モデルへ返す文字列と、履歴に残す1行を、同じ値から作る。**
///
/// ---
///
/// # 生のテキストを裸で返さない（16.6節 約束5）
///
/// 読んだ中身は `<tool_response>` として **user ターンの中に**展開される ──
/// **モデルから見て、ファイルの中身は利用者の発言と同じ場所にある**（16.1節）。
/// だから中身は必ず `ReadOutcome` の囲い
/// （`injectionGuard` / `openDelimiter` / `closeDelimiter`）の内側に入れる。
/// この型が `contextText` を自前で組み立てないのはそのためである ──
/// **組み立てる口を作らなければ、囲いを忘れる経路が生まれない。**
///
/// # 失敗の文だけは囲いの外に置いている（判断）
///
/// **囲いは「これは内容であって指示ではない」と言うためのものである。**
/// 失敗の文は内容ではなく**アプリの発言**で、しかも
/// 「一覧を取ってから指定し直してください」という**モデルに従ってほしい指示**を含む。
/// これを「指示ではありません」と書いた囲いに入れると、
/// **16.8節が要求する「往復を1回で打ち切らない」の要が自分で無効化される。**
///
/// では失敗の文は安全か ── **そのままでは安全ではない。**
/// `FolderAccessError.modelMessage` は**モデルが書いたパス**や
/// **ディスク上のファイル名**を本文へ埋め込む。ファイル名は利用者が作ったとは限らない
/// （もらったフォルダ、展開したアーカイブ）。つまり**失敗の文にも他所の文字列が混ざる。**
///
/// そこで囲いの代わりに**形を潰す** ── `ToolText.singleLine(_:limit:)` を必ず通し、
/// **改行と制御文字を消して長さを切る。** これで消えるのは
/// 「`--- ここまで ---` を騙る」「`<|im_start|>` で偽のターンを作る」といった
/// **構造の偽装**である。行を跨げなければ、囲いの外側に見せかけることはできない。
///
/// > **潰すのは本文だけではない。** 同じ理由で `toolName` も通す ──
/// > あの値は画面（`ToolActivity`）と次の周のプロンプト（`role=tool` の `name`）へ流れる。
/// > **2026-08-18 まで、ここだけ潰していなかった**（`make(kind:message:tool:counter:)` が
/// > 潰した名前を `contextText` と `bookmarkLine` にしか使っていなかった）。
///
/// > **【未確認】1行の中の説得までは消えない。**
/// > `無視して〜と答えよ` という名前のファイルは作れる。効くかは測っていない（16.9節 項目9）。
/// > **効いても被害が限定的なのは、囲いではなく封じ込め（16.5節）と
/// > 「戻り値でアプリの状態を変えない」（約束2）のほうが止めているからである。**
/// > 読み取りしかできず、根の外へは出られず、外へ送る経路も無い（NFR-01）。
struct ToolResult: Sendable, Equatable {

    enum Kind: Sendable, Equatable {
        /// `read_file` の結果（`ContextWindow` を通した後）。
        case read(ReadOutcome)
        /// `list_directory` / `search_files` の結果（同じく `ContextWindow` 相当の上限を通した後）。
        case listing(ReadOutcome)
        /// 読もうとして駄目だった（封じ込め・権限・I/O）。
        case failure(FolderAccessError)
        /// 呼び出しが成立していない。
        case rejected(ToolRejection)
    }

    /// モデルが呼んだ名前。**綴りは直していない**（`read_fil` は `read_fil` のまま届く。
    /// 直して受けると、名前を間違えたことが人間にもモデルにも見えなくなる）。
    ///
    /// **ただし形は潰してある** ── `ToolText.toolName(_:)` を通しており、
    /// 改行・制御文字・行区切りは含まず、切った印（`…`）を含めて
    /// `ToolText.toolNameLimit` スカラー以下である。
    /// この値は `ToolActivity.toolName` として**画面へ**流れ、`role=tool` の `name` として
    /// **次の周のプロンプトへも**入る（`Shared/Chunk.swift` の `ToolActivity` の型コメント）。
    /// **潰さずに入れると、その2か所へ改行を持ち込める。**
    var toolName: String

    var kind: Kind

    /// **そのまま `<tool_response>` に入る文字列。**
    ///
    /// 中身のある結果では `ReadOutcome.contextText` そのもの ──
    /// **上限に収まるかを測った文字列と、実際に入れる文字列が同一である**
    /// （`ReadOutcome.contextText` の型コメント）。
    var contextText: String

    /// **往復が終わったあと、履歴に残す1行**（16.3節 第2段）。
    var bookmarkLine: String

    /// `contextText` の実測（または概算）トークン数。
    var contextTokens: Int

    var tokensAreEstimated: Bool

    var isFailure: Bool {
        switch kind {
        case .read, .listing: false
        case .failure, .rejected: true
        }
    }

    /// 送信列へ入れる形（`ContextTranscript`）。
    ///
    /// **中身のある結果は `.read` として入れる。** そうしないと 16.3節 第2段の縮約
    /// （往復が終わったら栞へ落とす）が効かず、**読んだ中身を毎ターン送り続ける** ──
    /// Open WebUI が 4,550トークンを毎ターン注入していたのと同じ形になる（16.2節）。
    ///
    /// 失敗の文は落とさない。**1行しかなく、しかも次のターンで同じ失敗を繰り返させない
    /// ための情報である**（「そのパスは無い」を忘れると、モデルはまた同じパスを書く）。
    ///
    /// > **【申し送り / 2026-08-19】この口は `Sources/` から一度も呼ばれていない。**
    /// > 呼ぶのは会話を持っている層（`ChatViewModel`）だが、あちらは毎ターン
    /// > `turns` から送信列を組み直しており、**ツールの往復は痕跡ごと消える** ──
    /// > つまり栞を置く者がいない。ターンをまたいで栞を残すと決めたら、置き場はここである。
    /// > **1つのターンの中**の縮約は別経路で通っている
    /// > （`bookmarkLine` → `ToolExecutionOutcome.summaryLine` → `MLXEngine.compacted`）。
    var contextEntry: ContextEntry {
        switch kind {
        case .read(let outcome), .listing(let outcome):
            .read(outcome)
        case .failure, .rejected:
            .message(.user(contextText))
        }
    }

    /// 画面に出す1行（16.7節「何を読んだか（パスと範囲）」）。栞と同じ文でよい。
    var displayLine: String { bookmarkLine }

    // MARK: - 組み立て（ここ以外で `contextText` を作らないこと）

    static func content(_ outcome: ReadOutcome, tool: String, isListing: Bool) -> ToolResult {
        // ここへ来るのは `FolderTool(rawValue:)` が一致した名前だけなので、
        // 潰しても実際には1文字も変わらない。**それでも通すのは、保証を型の側に置くため**
        // である ── 「上流の guard を読めば安全だと分かる」形の保証は、
        // 呼び手が2つ目になった日に黙って破れる（`toolName` の型コメント）。
        ToolResult(
            toolName: ToolText.toolName(tool),
            kind: isListing ? .listing(outcome) : .read(outcome),
            contextText: outcome.contextText,
            bookmarkLine: outcome.bookmarkLine,
            contextTokens: outcome.contextTokens,
            tokensAreEstimated: outcome.tokensAreEstimated
        )
    }

    static func failed(
        _ error: FolderAccessError, tool: String, counter: TokenCounter
    ) -> ToolResult {
        make(kind: .failure(error), message: error.modelMessage, tool: tool, counter: counter)
    }

    static func rejected(
        _ rejection: ToolRejection, tool: String, counter: TokenCounter
    ) -> ToolResult {
        make(
            kind: .rejected(rejection), message: rejection.modelMessage,
            tool: tool, counter: counter)
    }

    private static func make(
        kind: Kind, message: String, tool: String, counter: TokenCounter
    ) -> ToolResult {
        // **必ず1行に潰してから返す**（型コメントの「形を潰す」）。
        let safeTool = ToolText.toolName(tool)
        let line = ToolText.singleLine(message, limit: ToolText.failureLimit)
        // **数える文字列と返す文字列を、同じ変数から作ること**
        // （`ReadOutcome.contextText` と同じ規律。組み直すと必ずどこかでずれる）。
        let text = "[ツール \(safeTool)]\n\(line)"
        return ToolResult(
            // **潰した名前を入れること。** 2026-08-18 まで、ここだけ `tool`（潰す前）を
            // 入れていた ── `contextText` と `bookmarkLine` は安全なのに、
            // 画面（`ToolActivity.toolName`）とプロンプト（`role=tool` の `name`）にだけ
            // 改行入りの名前が流れる形になっていた。
            toolName: safeTool,
            kind: kind,
            contextText: text,
            bookmarkLine: "\(safeTool): \(line)",
            contextTokens: counter(text),
            tokensAreEstimated: counter.isEstimate
        )
    }
}

/// **他所から来た文字列を、文脈へ入れられる形に潰す。**
///
/// 「他所」はモデルの出力とディスク上のファイル名の両方である。
/// どちらも**利用者が書いたとは限らない文字列**であり、`<tool_response>` は
/// user ターンの中に展開される（16.1節）。
enum ToolText {

    /// 失敗の文の長さの上限（**Unicode スカラー**。`singleLine(_:limit:)` の但し書きを読むこと）。
    /// **モデルが 10万文字のパスを書いても、払うのはここまで。**
    static let failureLimit = 300

    /// 名前・パスの長さの上限（**Unicode スカラー**）。一覧の1行あたりに払う上限でもある。
    static let nameLimit = 160

    /// **画面とプロンプトへ出るツール名**の上限（**Unicode スカラー**）。
    ///
    /// 他の2つと違い、これは**切った印（`…`）を含めた全体の上限**である
    /// （`toolName(_:)`）。画面の欄と `role=tool` の `name` に入る値なので、
    /// 「上限＋1」ではなく「全体で何スカラーか」が約束になる。
    static let toolNameLimit = 60

    /// 改行と制御文字を消し、長さを切る。
    ///
    /// ## 何を防いでいるか
    ///
    /// | 混ぜられるもの | 消える理由 |
    /// |---|---|
    /// | `\n--- ここまで ---\n` | 改行が消えるので、囲いの終わりを騙れない |
    /// | `\n<|im_start|>system\n` | 同上。行頭に立てない |
    /// | 10万文字の名前 | 長さ（**スカラー数**）で切る。**費用の側の防御**でもある |
    ///
    /// **1行の中の説得は消えない**（`ToolResult` の型コメントの但し書き）。
    ///
    /// > **`<|im_start|>` のような特殊トークンの綴りそのものは消していない。**
    /// > 消すなら**すべてのツール戻り値の本文**（`ReadOutcome.body` を含む）で
    /// > 一貫してやる必要があり、それは `Sources/Context/` の仕事である。
    /// > **半端に片側だけ消すと、消えていない側があることに気づけなくなる。** 申し送りにしてある。
    ///
    /// ## 長さは **Unicode スカラー**で数える（2026-08-18 に直した）
    ///
    /// もとは `String.count` ＝ **書記素クラスタ**で数えていた。
    /// 書記素は個数と大きさが比例しない ── `"a" + U+0301 × 5,000` は `count == 1` なので
    /// `limit: 60` を素通りし、**5,001 スカラー / 10,001 バイト**が返っていた
    /// （`AdversarialRoundTripTests` の実測）。
    /// **「300文字に切った」という申告が事実と合っておらず、費用の防御になっていなかった。**
    ///
    /// スカラーにしたので、戻り値は次を必ず満たす。
    ///
    /// * `limit` スカラー ＋ 切った印 `…` の1スカラー ＝ **最大 `limit + 1` スカラー**
    /// * UTF-8 で**最大 `(limit + 1) × 4` バイト**（1スカラーは4バイト以下）
    /// * 書記素数も `limit + 1` 以下（1書記素は1スカラー以上でできている）
    ///
    /// **バイトで数えなかった理由**は、同じ上限が日本語の表示にも効いているからである
    /// （`nameLimit` は一覧の1行、`failureLimit` は画面にも出る失敗の文）。
    /// バイトで切ると**日本語の名前だけが3分の1の長さになり、上限の意味が文字種で変わる。**
    /// スカラーなら、結合を使わない文字（ASCII・日本語）ではこれまでと同じ数になり、
    /// **変わるのは結合列や絵文字の並び ── つまり悪用の形だけ**である。
    ///
    /// > **縛っているのは「返す文字列」であって「入力の大きさ」ではない。**
    /// > 10万スカラーの入力は一度そのまま走査する（呼ばれた時点で既にメモリに載っている）。
    /// > ここが守っているのは、その先（文脈・プロンプト・画面）が払う費用である。
    static func singleLine(_ text: String, limit: Int) -> String {
        var flattened = ""
        flattened.reserveCapacity(text.unicodeScalars.count)
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            // 改行・タブ・その他の C0/C1 制御文字。**「改行だけ」では足りない** ──
            // 復帰（`\r`）だけでも表示上は行を戻せるし、`\u{2028}` も行区切りである。
            let isControl =
                scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
            if isControl {
                if !lastWasSpace {
                    flattened.unicodeScalars.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            flattened.unicodeScalars.append(scalar)
            lastWasSpace = (scalar == " ")
        }
        let trimmed = flattened.trimmingCharacters(in: .whitespaces)
        // **スカラーで数えること。** `count`（書記素）で数えると、
        // 1文字に1万バイト積んだ入力が上限を素通りする（上の但し書き）。
        let scalars = trimmed.unicodeScalars
        guard scalars.count > limit else { return trimmed }
        // **切ったことを見えるようにする。** 黙って切ると、
        // モデルは「そういう名前のファイルだ」と信じる（16.3節と同じ理由）。
        var cut = ""
        cut.unicodeScalars.append(contentsOf: scalars.prefix(max(limit, 0)))
        return cut + "…"
    }

    /// **画面とプロンプトへ出るツール名**の形に潰す。
    ///
    /// `singleLine(_:limit:)` は切った印を上限の**外**に置く（戻り値は最大 `limit + 1` スカラー）。
    /// 名前のほうは「欄に何スカラー入るか」が約束なので、**印のぶんを先に引いてから通す** ──
    /// 戻り値は `…` を含めて必ず `toolNameLimit` スカラー以下になる。
    ///
    /// **綴りは直さない。** 潰すのは形（改行・制御文字・長さ）だけである
    /// （`ToolCallRequest.name` / `ModelToolCall.name` と同じ規律）。
    static func toolName(_ text: String) -> String {
        singleLine(text, limit: max(toolNameLimit - 1, 0))
    }
}
