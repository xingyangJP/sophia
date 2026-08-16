import SwiftUI

/// Sophia のエントリポイント。
///
/// ウィンドウの寸法・質感は UI_NATIVE.md 第2.4章と第5章の**実測値**に合わせてある。
/// Electron 版と数値は同じだが、指定方法はまったく違う（vibrancy は SwiftUI では
/// `NavigationSplitView` と `Material` が担当する。BrowserWindow のような一括指定は無い）。
@main
struct SophiaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // サイドバー240 + 本文の最小400（UI_NATIVE.md 第2.4章）
                .frame(minWidth: SophiaMetrics.windowMinWidth,
                       minHeight: SophiaMetrics.windowMinHeight)
        }
        .defaultSize(width: SophiaMetrics.windowDefaultWidth,
                     height: SophiaMetrics.windowDefaultHeight)
        // 中身の最小寸法をウィンドウの最小寸法として尊重させる。
        // これを付けないと .frame(minWidth:) が効かず、内容が潰れる。
        .windowResizability(.contentMinSize)
        // ツールバーとタイトルバーを一体化した macOS 標準の見た目（実測 52pt）。
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // 「Sophia について」に表示される版番号も Info.plist から取る（完成条件8）。
            CommandGroup(replacing: .appInfo) {
                Button("Sophia について") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationVersion: AppInfo.version,
                            .version: AppInfo.build,
                        ]
                    )
                }
            }
        }
    }
}
