import Foundation
import Observation

/// 画面に出ている1発言。**`SophiaMessage` とは別物である。**
///
/// `SophiaMessage` はエンジンへ送る型で、思考テキストを持たない（型で「送らない」を保証している）。
/// 一方、画面と永続化層は思考テキストを持つ必要がある。その差を吸収するのがこの型。
/// **`SophiaMessage` に thinking を足して1つにまとめないこと。**
///
/// ## class にしてある理由
///
/// `@Observable` の class なので、**変わったプロパティを読んでいるビューだけが再評価される。**
/// struct の配列にすると、末尾1件の更新で配列全体が変わったことになり、
/// 生成中は過去の全メッセージが毎フレーム再描画される。
@MainActor @Observable
final class ChatTurn: Identifiable {

    enum Author {
        case user
        case assistant
    }

    /// 生成の進み具合。**無言の待機を作らないために、どの段階かを必ず画面に出す**
    /// （DESIGN.md 第6章 / UI_SPEC.md 10.2-#1）。
    enum Phase: Equatable {
        /// 送信直後。まだ何も届いていない。
        case waiting
        /// 入力処理中（`Chunk.prefill`）。思考が始まる前のここが最も長く無言になりやすい。
        case prefilling(PrefillProgress)
        /// 思考テキストが流れている（FR-17）。
        case thinking
        /// 本文が流れている。
        case responding
        /// 終わった（正常・中断のどちらも含む）。
        case finished
        /// 失敗した。`error` に理由が入る。
        case failed

        var isStreaming: Bool {
            switch self {
            case .waiting, .prefilling, .thinking, .responding: true
            case .finished, .failed: false
            }
        }
    }

    let id = UUID()
    let author: Author
    let createdAt = Date()

    /// 本文。生成中は伸びていく。
    var text: String
    /// 思考テキスト（FR-17）。**エンジンへは送り返さない。**
    var thinking: String = ""

    var phase: Phase

    /// 思考に要した秒数。**中断されても残す**（UI_SPEC.md 10.2-#13）。
    var thinkingSeconds: Double?
    /// 中断で終わったか。ラベルを「N秒間の思考（中断）」にするために使う。
    var wasInterrupted = false

    /// 思考領域を開いているか（FR-17）。
    /// 生成開始時は開いた状態で始め、本文が始まったら自動的に畳む。
    var thinkingExpanded = false
    /// 自動で畳む処理を既に1度行ったか。2度目以降は利用者の開閉を尊重する。
    var didAutoCollapseThinking = false

    /// FR-14 の計測値。**`.done` が届かないまま終わることがある**ので Optional。
    var stats: GenerationStats?
    /// `stats` を UI 側が概算で組み立てたか（エンジンの `.done` が来なかった場合）。
    var statsAreEstimated = false

    /// 失敗の理由（FR-11）。**中断（`.cancelled`）はここに入れない。** 異常ではないため。
    var error: SophiaError?

    // MARK: - フォルダ参照（FR-19 / DESIGN.md 第16.7節）

    /// このターンで起きたファイル参照の往復。**呼ばれた順**に積む。
    ///
    /// 16.7節「何を読んだか（パスと範囲）を、そのターンに添える」の実体。
    /// **空でないこと自体が情報である** ── 「1回で答えた」と「4回読んで答えた」は
    /// 利用者にとって別の出来事で、遅さの原因が読み取りにあることは
    /// 回数が見えないと分からない。
    var toolRuns: [ToolRun] = []

    /// **このターンでツール定義に払ったトークン数**（16.7節 / FR-21）。
    ///
    /// 送信の時点で確定する（`armed` なら `SophiaDefaults.toolDefinitionTokens`、
    /// `idle` なら 0）。**`ChatOptions.tools` を組んだのと同じ値から入れること** ──
    /// 別々に決めると、画面に出る額と実際に払った額が食い違う。
    var toolDefinitionTokens: Int = 0

    /// ファイル参照が1回でも起きたか。
    var didUseTools: Bool { !toolRuns.isEmpty }

    /// 受け取った断片の数と、実際に描画へ反映した回数。
    /// VISION の測定原則に従い、**間引きが効いているかを推測せず数える**ための値。
    var chunkCount = 0
    var flushCount = 0

    init(author: Author, text: String = "", phase: Phase = .finished) {
        self.author = author
        self.text = text
        self.phase = phase
    }

    /// 本文も思考も空か。空のまま中断された応答を「空欄」に見せないための判定に使う。
    var isEmpty: Bool { text.isEmpty && thinking.isEmpty }

    /// 思考ラベル（UI_SPEC.md 7.1 の3種類に対応する）。
    var thinkingLabel: String {
        switch phase {
        case .thinking:
            return "思考中…"
        default:
            guard let seconds = thinkingSeconds else { return "思考" }
            let base = String(format: "%.0f秒間の思考", seconds)
            return wasInterrupted ? "\(base)（中断）" : base
        }
    }
}

/// ファイル参照1回ぶんの表示（`Chunk.toolCall` → `Chunk.toolResult`）。
///
/// ---
///
/// # 無言の区間を潰すためにある（`Chunk.toolResult` の型コメント）
///
/// 往復の最中、画面には**何も流れない。** 実測の TTFR は最大 40.91秒あり、
/// そこへ「読む → もう一度プリフィル → もう一度生成」が積み増さる。
/// **固まって見えるのと固まっているのを、利用者は区別できない。**
///
/// | いつ | 何が届くか | ここでの状態 |
/// |---|---|---|
/// | モデルが呼んだ | `.toolCall` | `summary == nil`（＝実行中） |
/// | 読み終えた | `.toolResult` | `summary` が入る（＝栞と同じ1行） |
///
/// # 中身（ファイルの本文）は持たない
///
/// 持つのは**要求の1行**と**結果の1行**だけである。
/// 型として持たせていないので、**うっかり画面へ出す経路が作れない**（NFR-01）。
///
/// # 文字列はすべて他所から来ている
///
/// `request` はモデルが書いた文字列、`summary` はディスクの中身が混ざった文字列である。
/// **どちらも `ToolText.singleLine(_:limit:)` を通してから入れること**
/// （改行で偽の行を作られると、画面の上でも囲いの偽装ができる）。
/// 通す責任は作る側（`ChatViewModel`／実行層）にある ── この型は保証しない。
@MainActor @Observable
final class ToolRun: Identifiable {

    let id = UUID()

    /// モデルが呼んだ名前。**直していない**（`ModelToolCall.name` と同じ規律）。
    let toolName: String

    /// モデルが書いた要求の1行（名前＋引数）。**実行中に出す文。**
    let request: String

    /// 始まった時刻。経過秒数を出すために持つ。
    let startedAt = Date()

    /// 結果の1行（＝栞と同じ文字列）。**nil の間は実行中**である。
    ///
    /// **「履歴に残る」とは書かないこと** ── ターンをまたぐと往復は痕跡ごと消える
    /// （`Shared/Chunk.swift` の `ToolActivity` の訂正を読むこと）。
    var summary: String?

    /// 読めなかった／呼び出しが成立しなかった。**往復は続いている**ので終了ではない。
    var isFailure = false

    /// 何回目の往復か（1始まり）。`.toolResult` が来るまで nil。
    var round: Int?

    init(toolName: String, request: String) {
        self.toolName = toolName
        self.request = request
    }

    /// 実行中か。
    var isRunning: Bool { summary == nil }

    /// 画面に出す1行。実行中は要求、終わったら結果。
    var line: String { summary ?? request }
}
