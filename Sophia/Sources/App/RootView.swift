import SwiftUI

/// 最上位ビュー。**中身は `Sources/UI/` にある `ChatScreen` が持つ。**
///
/// ここに残しているのは、雛形が申し送っていた**ネイティブの作法**のほう。
/// Electron 版で必要だった調整のほとんどは、SwiftUI では OS の担当になる。
///
/// | Electron でやっていたこと | SwiftUI での対応 |
/// |---|---|
/// | `vibrancy: 'sidebar'` | `NavigationSplitView` のサイドバーが自前で持つ。指定不要 |
/// | `backgroundColor: '#00000000'` で透過させる | 逆。**塗らなければ透ける**。不要な `.background` を置かない |
/// | `titleBarStyle: 'hidden'` + `trafficLightPosition` | `.windowToolbarStyle(.unified)`。座標指定は不要 |
/// | `titleBarOverlay` / `env(titlebar-area-x)` | 不要。ツールバーへ入れれば OS が避ける |
/// | `app-region: drag` / `no-drag` | 不要。ツールバー領域は最初からドラッグできる |
///
/// **トラフィックライトの座標を自分で計算しないこと。** UI_NATIVE.md 第2.3章が
/// Electron で必要だと書いていた調整は、ネイティブでは OS の担当である。
///
/// ## エンジンを作る場所
///
/// 実体を作ってよいのは `EngineFactory` だけで、保持するのは `ChatViewModel` だけ。
/// ここは受け渡しをするだけで、`StubEngine` や MLX 実装の名前を知らない。
struct RootView: View {
    /// アプリの生存期間中ずっと同じエンジンを使う。
    /// `body` の中で作るとビューが再評価されるたびにモデルを読み直すことになる。
    @State private var engine: any InferenceEngine = EngineFactory.makeDefault()

    var body: some View {
        ChatScreen(engine: engine)
    }
}

#Preview {
    RootView()
        .frame(width: SophiaMetrics.windowDefaultWidth, height: SophiaMetrics.windowDefaultHeight)
}
