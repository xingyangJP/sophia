import Foundation

/// アプリのメタ情報。**版番号の読み出しはここ1か所に集約する。**
///
/// 完成条件8「UI にバージョン表示（`ver 0.1.0`）」の実体。
/// 数字をソースへ直書きしないこと。出所は次の1本道になっている。
///
/// ```
/// project.pbxproj の MARKETING_VERSION = 0.1.2
///   → Info.plist の CFBundleShortVersionString = $(MARKETING_VERSION)
///     → AppInfo.version
///       → AppInfo.versionLabel（"ver 0.1.2"）
/// ```
///
/// 版を上げるときに触るのは `MARKETING_VERSION` **だけ**である。
enum AppInfo {
    private static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// `CFBundleName`。
    static let name: String = string("CFBundleName") ?? "Sophia"

    /// `CFBundleShortVersionString`（例 `0.1.0`）。
    static let version: String = string("CFBundleShortVersionString") ?? "0.0.0"

    /// `CFBundleVersion`（ビルド番号）。
    static let build: String = string("CFBundleVersion") ?? "0"

    static let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "jp.co.xerographix.sophia"

    /// UI に出す文字列（完成条件8）。例: `ver 0.1.0`
    static var versionLabel: String { "ver \(version)" }

    /// デバッグ表示の出し分けに使う。
    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
