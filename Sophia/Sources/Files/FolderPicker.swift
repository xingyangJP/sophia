import AppKit
import Foundation

/// **利用者にフォルダを選ばせる**（機能1 / DESIGN.md 第16.5節「選ばせ方」）。
///
/// ## ここが権限の唯一の入口である
///
/// サンドボックス下では任意のパスは読めない。
/// `com.apple.security.files.user-selected.read-write` の
/// **「user-selected」は文字どおりの意味**で、このpanelを通ったものだけが読み書きできる。
///
/// したがって **16.6節の約束1（アクセス範囲をファイルの中身で広げない）は、
/// ここに関数が1つしか無いことで担保される。** 権限を得る経路を増やさないこと。
/// モデルの出力から呼ばれる経路を作らないこと（約束3）。
///
/// ## 選ばせ方（16.5節）
///
/// `canChooseDirectories = true` / `canChooseFiles = false`。
/// **ファイルを1つだけ選ばせる形にしない。** 会話の途中で別のファイルを読みたくなるたびに
/// panel が出ることになり、16.2節の `armed`（会話にフォルダが結び付いている状態）が作れない。
@MainActor
enum FolderPicker {

    /// フォルダを1つ選ばせる。選ばれなければ nil（**キャンセルは異常ではない**）。
    ///
    /// - Parameter startingAt: 最初に開く場所。前回選んだフォルダを渡すと選び直しが楽になる。
    static func chooseFolder(startingAt: URL? = nil) -> URL? {
        let panel = NSOpenPanel()

        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        // **単一選択。** 複数の根を許すと、封じ込め（16.5節）が「どの根か」を
        // 判定する分岐を持つことになる。判定が増える場所は必ず穴が開く。
        panel.allowsMultipleSelection = false
        // 選択panel自体では作らせない。ディレクトリ作成は承認付きツールだけが担う。
        panel.canCreateDirectories = false
        // Finder のエイリアスは実体に解決させる。どのみち手順2で解決するので、
        // ここで解いておいたほうが利用者に見えるパスと実際に読む場所が揃う。
        panel.resolvesAliases = true

        panel.message = "Sophia に許可するフォルダを選んでください。この中だけを参照し、変更時は毎回確認します。"
        panel.prompt = "このフォルダを許可"
        panel.directoryURL = startingAt

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
