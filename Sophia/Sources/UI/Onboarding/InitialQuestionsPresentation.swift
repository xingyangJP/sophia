import Foundation

/// 初回の質問を自動表示したかだけを持つ。回答内容は `user_traits` が原本であり、
/// ここへ複製しない。
struct InitialQuestionsPresentationStore {

    static let defaultKey = "jp.co.xerographix.sophia.initialQuestions.v2.presented"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults? = nil, key: String = Self.defaultKey) {
        self.defaults = defaults ?? Self.applicationDefaults
        self.key = key
    }

    /// ホストアプリを起動する単体テストが、実利用者の表示済みフラグを汚さない。
    private static var applicationDefaults: UserDefaults {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return .standard
        }
        let suite = "jp.co.xerographix.sophia.tests.\(ProcessInfo.processInfo.processIdentifier)"
        return UserDefaults(suiteName: suite) ?? .standard
    }

    var hasPresented: Bool {
        defaults.bool(forKey: key)
    }

    func markPresented() {
        defaults.set(true, forKey: key)
    }
}

/// DB が使える新規利用者にだけ、質問シートの自動表示を一度要求する。
/// 表示済みを先に確定するので、無回答で閉じても次回起動時に強制しない。
@MainActor
enum InitialQuestionsPresentationPolicy {

    static func shouldPresent(
        store: Store?,
        presentationStore: InitialQuestionsPresentationStore
    ) async -> Bool {
        guard !presentationStore.hasPresented, let store else { return false }

        do {
            let hasKnownTraits = !(try await store.allTraits()).isEmpty
            presentationStore.markPresented()
            return !hasKnownTraits
        } catch {
            // DB の一時障害では表示済みにしない。次回起動で再試行する。
            return false
        }
    }
}
