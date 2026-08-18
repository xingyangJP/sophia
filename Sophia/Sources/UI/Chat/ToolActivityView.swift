import SwiftUI

/// **このターンで何を読んだか**（FR-19 / DESIGN.md 第16.7節）。
///
/// > | 出すもの | 場所 | 根拠 |
/// > |---|---|---|
/// > | 何を読んだか（パスと範囲） | そのターンに添える。折りたたみ可 | **16.6節の約束4** |
/// > | 切り捨てが起きたこと | 同上 | 「全部読んだ」と誤解すると答えの信頼度を測れない |
///
/// ---
///
/// # 2つのことを同時にやっている
///
/// **1. 無言の時間を消す。** 往復の最中、生成は止まっていて画面には何も流れない。
/// 実測の TTFR は最大 40.91秒あり、そこへ「読む → もう一度プリフィル → もう一度生成」が
/// 積み増さる。**固まって見えるのと固まっているのを、利用者は区別できない。**
/// `.toolCall` が来た瞬間にここへ行が生え、経過秒数が動き続ける。
///
/// **2. 見張れるようにする。**
///
/// > 被害は「気づけないこと」で大きくなる。**何を読んだかが見えていれば異常に気づける**（16.6節 約束4）
///
/// 読み取りしかできず、根の外へは出られず、外へ送る経路も無い（NFR-01）。
/// それでも**読んだ事実そのもの**は見えている必要がある ── FR-20（書き込み・
/// コマンド実行）が入った瞬間、同じ経路が実害に変わるからである。
///
/// # 既定で開いている
///
/// 16.7節は「折りたたみ可」と書いてあるが、**畳んだ状態を既定にしない。**
/// 思考（FR-17）で Open WebUI と逆にしたのと同じ判断である ──
///
/// > データは来ているのに隠している（UI_SPEC.md 6.1-3）
///
/// 行は往復の上限（`FolderToolRunner.callLimit` ＝ 既定6）で頭打ちになる。
/// 6行までなら畳む理由が無い。
struct ToolActivityView: View {

    @Bindable var turn: ChatTurn

    var body: some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space1) {
            ForEach(turn.toolRuns) { run in
                ToolRunRow(run: run)
            }
        }
        .padding(.leading, SophiaMetrics.space1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ファイル参照1回ぶんの1行。
///
/// **実行中と終わった後で、出す文が入れ替わる。**
///
/// | 状態 | 出す文 | なぜ |
/// |---|---|---|
/// | 実行中 | モデルが書いた**要求**（名前＋引数） | まだ結果が無い。何を取りに行ったかは言える |
/// | 終わった | 実行層が作った**栞**（`ToolResult.bookmarkLine`） | **ターンの中で文脈に残る文と同一。** 画面と文脈が食い違わない |
///
/// 終わった後も要求はツールチップに残す ── **モデルが書いたパスと、
/// 実際に読まれたパスを突き合わせられる**ようにするためで、
/// これが 16.6節 約束4 の「異常に気づける」の実体である。
private struct ToolRunRow: View {

    @Bindable var run: ToolRun

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SophiaMetrics.space2) {
            icon

            Text(run.line)
                .font(SophiaFont.callout)
                .foregroundStyle(run.isFailure ? SophiaColor.accent : SophiaColor.ink2)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            // **実行中は経過秒数を出し続ける。** 待ち時間を隠さない（VISION の測定原則）。
            if run.isRunning {
                LiveElapsedText(since: run.startedAt)
                    .font(SophiaFont.footnote)
                    .foregroundStyle(SophiaColor.ink4)
            }

            Spacer(minLength: 0)
        }
        .help(helpText)
    }

    @ViewBuilder
    private var icon: some View {
        if run.isRunning {
            // テラコッタを使ってよい数少ない場所（線・インジケータ限定）。
            ProgressView()
                .controlSize(.small)
                .tint(SophiaColor.accentVivid)
                .frame(width: 12, height: 12)
        } else {
            Image(systemName: run.isFailure ? "exclamationmark.circle" : "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(run.isFailure ? SophiaColor.accentVivid : SophiaColor.ink3)
                .frame(width: 12)
        }
    }

    /// **モデルが書いた要求そのもの。** 結果と突き合わせるための一次資料である。
    private var helpText: String {
        var parts = ["モデルの要求: \(run.request)"]
        if let round = run.round { parts.append("\(round)回目のファイル参照") }
        if run.isFailure {
            // **失敗は終了ではない**（16.8節「往復を1回で打ち切らない」）。
            parts.append("読めませんでしたが、会話は続いています")
        }
        return parts.joined(separator: " ・ ")
    }
}
