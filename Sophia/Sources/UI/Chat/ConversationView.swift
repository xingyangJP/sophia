import SwiftUI

/// メッセージ列。**ここだけがスクロールする**（UI_SPEC.md 1.1）。
///
/// # 自動追従について（実測で作り直した部分）
///
/// 最初は `.defaultScrollAnchor(.bottom)` 1行で済ませていたが、
/// **実機で確認したところ macOS 14 では伸びていく内容に追従しなかった。**
/// 初回の位置決めには効くが、生成が進んでも表示は動かず、
/// answer の後半が画面の下に隠れたまま最後まで出てこない。
/// 逐次表示（FR-01）の意味が無くなるので、明示的な追従に置き換えてある。
///
/// 追従は「利用者が最下部にいるときだけ」行う。
/// 上へスクロールして読んでいる最中に引き戻すのは、NFR-02 の
/// 「生成中もスクロールが効く」に反する。
struct ConversationView: View {

    @Bindable var model: ChatViewModel
    /// **`@State` に置くが、このビューの `body` からは読まない。**
    /// 読むと距離が変わるたびに会話全体が再評価される。読むのは追従係だけ。
    @State private var scroll = ScrollFollowState()

    private static let bottomAnchor = "sophia.conversation.bottom"
    private static let scrollSpace = "sophia.conversation.space"

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SophiaMetrics.space5) {
                        ForEach(model.turns) { turn in
                            TurnView(turn: turn, model: model)
                        }
                        if let error = model.globalError {
                            globalErrorRow(error)
                        }
                        // 追従の目標。最後の発言が入力欄に貼り付かないよう余白も兼ねる。
                        Color.clear
                            .frame(height: SophiaMetrics.space4)
                            .id(Self.bottomAnchor)
                    }
                    .frame(maxWidth: SophiaLayout.columnMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, SophiaMetrics.space5)
                    .padding(.top, SophiaMetrics.space5)
                    .background(
                        // 内容の下端とビューポート下端の距離を測る。
                        // 0 に近ければ「最下部にいる」= 追従してよい。
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: BottomDistanceKey.self,
                                value: inner.frame(in: .named(Self.scrollSpace)).maxY
                                    - outer.size.height
                            )
                        }
                    )
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(BottomDistanceKey.self) { distance in
                    // プリファレンスの配信はメインスレッド。
                    MainActor.assumeIsolated { scroll.distanceFromBottom = max(0, distance) }
                }
                .overlay(alignment: .bottom) {
                    ScrollFollower(
                        model: model,
                        scroll: scroll,
                        proxy: proxy,
                        anchor: Self.bottomAnchor
                    )
                }
            }
        }
    }

    /// 会話に紐づかないエラー（FR-11）。
    ///
    /// **空の画面（`EmptyConversationView`）と同じ部品を使う。**
    /// 以前はここだけに独自の表示があり、しかも起動直後は `turns` が空で
    /// このビュー自体が出ないため、**読み込みの失敗がどこにも出なかった。**
    private func globalErrorRow(_ error: SophiaError) -> some View {
        LoadErrorCard(model: model, error: error)
    }
}

/// スクロール位置。会話リストとは別のオブジェクトに分けてある（`ConversationView` の説明を参照）。
@MainActor @Observable
final class ScrollFollowState {
    var distanceFromBottom: CGFloat = 0
    /// この距離までは「最下部にいる」とみなす。1行ぶんの余裕。
    var isNearBottom: Bool { distanceFromBottom < 48 }
}

private struct BottomDistanceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// **追従とジャンプだけを担当する小さなビュー。**
///
/// 生成中に変わる値（`streamTick` / 距離）をここでしか読まないので、
/// 毎フレーム再評価されるのはこのビューだけで済む。
/// 会話リスト本体は、伸びている1件の `TurnView` 以外は作り直されない。
private struct ScrollFollower: View {

    @Bindable var model: ChatViewModel
    let scroll: ScrollFollowState
    let proxy: ScrollViewProxy
    let anchor: String

    var body: some View {
        Group {
            if !scroll.isNearBottom {
                jumpToBottomButton
            } else {
                Color.clear.frame(height: 0)
            }
        }
        // 生成で内容が伸びた
        .onChange(of: model.streamTick) { _, _ in
            guard scroll.isNearBottom else { return }
            proxy.scrollTo(anchor, anchor: .bottom)
        }
        // 送信して発言が増えた。**このときは位置に関わらず必ず下へ送る**
        .onChange(of: model.turns.count) { _, _ in
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }

    /// 「最下部へスクロール」（UI_SPEC.md 10.1-#12）。
    /// 生成中に上へ読み返しても、1クリックで追従へ戻れる。
    private var jumpToBottomButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(anchor, anchor: .bottom)
            }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SophiaColor.ink2)
                .frame(width: 28, height: 28)
                .background(Circle().fill(SophiaColor.surface))
                .overlay(Circle().stroke(SophiaColor.separator, lineWidth: SophiaMetrics.hairline))
        }
        .buttonStyle(.plain)
        .padding(.bottom, SophiaMetrics.space2)
        .help("最新の位置へ戻ります")
    }
}

/// 空の状態（UI_SPEC.md 第2章）。
///
/// 見出しは**モデルIDではなく Sophia の名前**を出す（10.2-#9）。
/// 提案カードは A1 のスコープ外。
///
/// ## ここが起動時の失敗の唯一の出口である（2026-08-18 に判明）
///
/// `globalError` を描いていたのは `ConversationView` の中だけだった。
/// ところが `ChatScreen` は **`turns.isEmpty` のときこのビューへ分岐する**ので、
/// **起動時の読み込み失敗は画面のどこにも出ていなかった。**
/// 「モデルを取得しています（0%）」だけが残り、失敗しても表示が変わらない
/// ── 今回いちばんの問題（落ちないまま黙っていた）の、UI 側の半分がこれである。
/// **エラーと再試行をここから外さないこと。**
///
/// 引数で受け取らず `ChatViewModel` をそのまま受けているのは、
/// 出すものが4つ（進捗・経過時間・エラー・再試行）に増えて、
/// 引数で配ると `ChatScreen` 側が中継役になるだけだから。
struct EmptyConversationView: View {

    @Bindable var model: ChatViewModel

    var body: some View {
        VStack(spacing: SophiaMetrics.space4) {
            Image(systemName: "circle.hexagonpath")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(SophiaColor.accentVivid)

            Text(AppInfo.name)
                .font(SophiaFont.title1)
                .foregroundStyle(SophiaColor.ink)

            Text("会話は、この端末の外に出ません。")
                .font(SophiaFont.body)
                .foregroundStyle(SophiaColor.ink2)

            if let loading = model.loading {
                loadingRow(loading)
            }

            if let error = model.globalError {
                LoadErrorCard(model: model, error: error)
            } else if model.loading == nil, model.engineIsStub {
                // 「本物が動いている」と誤解させない。
                // `EngineIdentifier.stub` の宣言にある約束（ダミーである旨を出す）。
                Text("いまはダミーのエンジンです。モデルは読み込まれていません")
                    .font(SophiaFont.callout)
                    .foregroundStyle(SophiaColor.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, SophiaMetrics.space5)
        .padding(.bottom, SophiaMetrics.space6)
    }

    /// 読み込み中の表示。**進捗率だけを出さない。**
    ///
    /// 出すのは3つで、どれが欠けても「待つ／やり直す」を判断できない。
    ///   1. 何をしているか（`detail`。エンジン側が**バイト数込み**の日本語を入れている）
    ///   2. **どれだけ経ったか**（0% が10秒目なのか10分目なのかで意味が正反対になる）
    ///   3. どこまで進んだか（バー）
    private func loadingRow(_ loading: LoadProgress) -> some View {
        VStack(spacing: SophiaMetrics.space2) {
            HStack(spacing: SophiaMetrics.space2) {
                ProgressView()
                    .controlSize(.small)
                    .tint(SophiaColor.accentVivid)
                Text(loading.detail ?? "モデルを準備しています")
                    .font(SophiaFont.callout)
                    .foregroundStyle(SophiaColor.ink3)
                    .multilineTextAlignment(.center)
            }

            if let startedAt = model.modelLoadStartedAt {
                HStack(spacing: SophiaMetrics.space1) {
                    Text("経過")
                    // 毎秒更新されるのはこの1行だけ（`LiveElapsedText` の説明を参照）。
                    LiveElapsedText(since: startedAt)
                }
                .font(SophiaFont.footnote)
                .foregroundStyle(SophiaColor.ink4)
            }

            // 取得中だけバーを出す。展開中は総量が分からないので不定形のままにする。
            if loading.stage == .downloading, let fraction = loading.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(SophiaColor.accentVivid)
                    .frame(maxWidth: 280)
            }
        }
    }
}

/// 読み込みの失敗（FR-11）と、そこからの復帰手段（NFR-10）。
///
/// 見た目は `TurnView.errorRow` に揃えてある。**同じ「失敗」が画面の場所によって
/// 違う顔をしないこと**が目的で、違うのは再試行ボタンが付く点だけ。
struct LoadErrorCard: View {

    @Bindable var model: ChatViewModel
    let error: SophiaError

    var body: some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: SophiaMetrics.space2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(SophiaColor.accent)
                Text(error.message)
                    .font(SophiaFont.body)
                    .foregroundStyle(SophiaColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let hint = error.hint {
                Text(hint)
                    .font(SophiaFont.callout)
                    .foregroundStyle(SophiaColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SophiaMetrics.space5)
            }

            #if DEBUG
            // `detail` は開発者向けなので**製品ビルドには出さない**（SophiaError の約束）。
            // ここに置いてあるのは、画面とログ（`[LOAD] event=stalled`）を
            // 同じキーで突き合わせられるようにするため。
            if let detail = error.detail {
                Text(detail)
                    .font(SophiaFont.footnote)
                    .foregroundStyle(SophiaColor.ink4)
                    .textSelection(.enabled)
                    .padding(.leading, SophiaMetrics.space5)
            }
            #endif

            if model.canRetryModelLoad {
                Button("再試行") {
                    Task { await model.retryModelLoad() }
                }
                .controlSize(.small)
                .padding(.leading, SophiaMetrics.space5)
                .help("モデルの取得をやり直します。取得済みの分はそのまま使われ、続きから再開されます")
            }
        }
        .padding(SophiaMetrics.space3)
        .frame(maxWidth: SophiaLayout.columnMaxWidth, alignment: .leading)
        .background(SophiaColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: SophiaMetrics.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: SophiaMetrics.controlRadius)
                .stroke(SophiaColor.accentVivid.opacity(0.5), lineWidth: SophiaMetrics.hairline)
        )
    }
}
