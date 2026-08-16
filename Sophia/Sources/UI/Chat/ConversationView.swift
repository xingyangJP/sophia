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
                            TurnView(turn: turn)
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

    private func globalErrorRow(_ error: SophiaError) -> some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space1) {
            Text(error.message)
                .font(SophiaFont.body)
                .foregroundStyle(SophiaColor.ink)
            if let hint = error.hint {
                Text(hint)
                    .font(SophiaFont.callout)
                    .foregroundStyle(SophiaColor.ink2)
            }
        }
        .padding(SophiaMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SophiaColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: SophiaMetrics.controlRadius))
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
struct EmptyConversationView: View {

    let engineIsStub: Bool
    let loading: LoadProgress?

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

            if let loading {
                HStack(spacing: SophiaMetrics.space2) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(SophiaColor.accentVivid)
                    Text(loading.detail ?? "モデルを準備しています")
                        .font(SophiaFont.callout)
                        .foregroundStyle(SophiaColor.ink3)
                }
            } else if engineIsStub {
                // 「本物が動いている」と誤解させない。
                // `EngineIdentifier.stub` の宣言にある約束（ダミーである旨を出す）。
                Text("いまはダミーのエンジンです。モデルは読み込まれていません")
                    .font(SophiaFont.callout)
                    .foregroundStyle(SophiaColor.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, SophiaMetrics.space6)
    }
}
