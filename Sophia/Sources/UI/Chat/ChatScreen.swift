import SwiftUI

/// 会話画面の全体。UI_SPEC.md 第1章の三領域構成を借りる
/// ─ サイドバー / メッセージ列 / 下端固定の入力欄（10.1-#1）。
///
/// **借りるのは骨格だけで、機能構成は真似ない。**
/// A1 は会話のみ。履歴の一覧・検索もモデル管理も作らない（A2以降）。
struct ChatScreen: View {

    @State private var model: ChatViewModel
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    /// 利用者像の質問（第14章 / FR-24）。**起動時に自動では開かない。**
    ///
    /// > 初回起動 | **3〜5問。**スキップ可（FR-24） |
    /// > **信頼が最も薄い瞬間に手間を要求しない** ── 14.9節
    ///
    /// 割り込むかどうかは、この1つの `false` で決まっている。
    /// **押されなければ費用は 0 である**（訊くこと自体が利用者のエネルギー ── 14.9節）。
    @State private var showingTraits = false

    init(engine: any InferenceEngine) {
        _model = State(initialValue: ChatViewModel(engine: engine))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(
                    min: SophiaMetrics.sidebarMinWidth,
                    ideal: SophiaMetrics.sidebarDefaultWidth,
                    max: SophiaMetrics.sidebarMaxWidth
                )
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(model.isGenerating)
                .keyboardShortcut("n", modifiers: .command)
                .help("新しい会話を始めます（⌘N）")
            }

            // **主張しない**（`FolderBar` の `idleButton` と同じ扱い）。
            // 何も出さないと機能があること自体に気づけないが、
            // 割り込むと「信頼が最も薄い瞬間に手間を要求する」ことになる（14.9節）。
            ToolbarItem(placement: .automatic) {
                Button {
                    showingTraits = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                }
                .help("いくつかの二択に答えると、Sophia の説明の仕方が決まります。"
                      + "答えた内容は端末の中だけに置かれ、毎ターンの送信には載りません（0 トークン）")
            }
        }
        .sheet(isPresented: $showingTraits) {
            // **開くときに `Store` を読む。** `prepare()` が済んでいれば入っている。
            UserTraitsSheet(store: model.traitStore)
        }
        .task { await model.prepare() }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            // 結び付いたフォルダ（FR-19 / 16.7節「会話の上部にチップ1つ」）。
            // **スクロール領域の外に置く。** 入力欄と同じ理由で、
            // `armed` かどうかは会話を遡っても常に見えていなければならない。
            FolderBar(model: model)

            if model.turns.isEmpty {
                EmptyConversationView(model: model)
            } else {
                ConversationView(model: model)
            }
            // 入力欄はスクロール領域の外（UI_SPEC.md 10.1-#6）
            ComposerView(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 本文ペインだけ不透明に塗る。サイドバーは OS の材質を透かす（UI_NATIVE.md 4.5）
        .background(SophiaColor.background)
    }
}

/// サイドバー。
///
/// **地を塗らない。** SwiftUI では塗らなければ OS の材質が見える。
/// Electron のように `vibrancy` を指定する必要はない（RootView の対応表を参照）。
struct SidebarView: View {

    @Bindable var model: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("会話") {
                    Label {
                        Text(title)
                            .font(SophiaFont.body)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "bubble.left")
                            .foregroundStyle(SophiaColor.ink3)
                    }
                    .frame(height: SophiaMetrics.sidebarRowHeight)
                }
            }
            .listStyle(.sidebar)

            Rectangle()
                .fill(SophiaColor.separator)
                .frame(height: SophiaMetrics.hairline)

            footer
        }
    }

    private var title: String {
        model.turns.first(where: { $0.author == .user })?.text.prefix(40).description
            ?? "新しい会話"
    }

    /// サイドバー最下部。**版番号の常設場所**（完成条件8 / UI_SPEC.md 10.3）。
    ///
    /// 地が透けるため `--ink-3` 以下を使わない、という UI_NATIVE.md 4.5 の但し書きに従い
    /// エンジン名までは `ink2` で出す。
    private var footer: some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space1) {
            HStack(spacing: SophiaMetrics.space1) {
                Text("エンジン")
                    .foregroundStyle(SophiaColor.ink3)
                Text(model.engine.identifier.displayName)
                    .foregroundStyle(model.engineIsStub ? SophiaColor.accent : SophiaColor.ink2)
            }
            .font(SophiaFont.subhead)

            if let info = model.model {
                Text(info.displayName)
                    .font(SophiaFont.subhead)
                    .foregroundStyle(SophiaColor.ink2)
                    .lineLimit(1)
                    // 独自名を出す以上、ベースがどれかを画面から辿れるようにしておく。
                    // Apache 2.0 の帰属表示であり、「重みを作ったのか名前を変えただけか」を
                    // 自分で見失わないための歯止めでもある。
                    .help(info.provenance ?? info.id)
            }

            HStack(spacing: SophiaMetrics.space1) {
                Text(AppInfo.versionLabel)
                if AppInfo.isDebugBuild {
                    Text("DEBUG")
                        .padding(.horizontal, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(SophiaColor.ink4, lineWidth: SophiaMetrics.hairline)
                        )
                }
            }
            .font(SophiaFont.footnote)
            .foregroundStyle(SophiaColor.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SophiaMetrics.space3)
        .padding(.vertical, SophiaMetrics.space2)
    }
}

#Preview("会話") {
    ChatScreen(engine: MockEngine(scenario: .rich))
        .frame(width: SophiaMetrics.windowDefaultWidth, height: SophiaMetrics.windowDefaultHeight)
}
