import XCTest
@testable import Sophia

/// Store 系テストの共通の土台。
///
/// ## 既定はメモリ上のDB
///
/// 速いからではなく、**実アプリの `Application Support/Sophia/sophia.db` を
/// 絶対に触らないため**である。テスト実行はホストアプリ（`Sophia.app`）の
/// プロセスの中で走るので、`Store()` を引数なしで呼ぶと**利用者の会話履歴を
/// 開いてしまう。** テストからは必ず `.inMemory` か `.file(一時パス)` を渡すこと。
class StoreTestCase: XCTestCase {

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    /// 誰とも共有しないメモリ上の Store。
    func makeInMemoryStore() throws -> Store {
        try Store(.inMemory(name: nil))
    }

    /// 一時ディレクトリの中のファイルDB。再オープンの検証に使う。
    /// tearDown でディレクトリごと消える。
    func makeTemporaryDatabaseURL(file: StaticString = #filePath, line: UInt = #line) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SophiaStoreTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return directory.appendingPathComponent(SophiaDatabase.fileName, isDirectory: false)
    }

    /// 会話を1本作って、その id を返す。
    @discardableResult
    func makeConversation(
        in store: Store,
        title: String = "テスト会話",
        modelID: String = "mlx-community/Qwen3-8B-4bit"
    ) async throws -> String {
        try await store.createConversation(title: title, modelID: modelID).id
    }

    /// `XCTAssertThrowsError` の非同期版。
    ///
    /// `Store` は actor なので、その throwing メソッドはすべて `await` が要る。
    /// 標準の `XCTAssertThrowsError` は autoclosure が同期なので使えない。
    func assertThrows(
        _ expression: () async throws -> Void,
        _ message: String = "エラーが投げられるはずだった",
        file: StaticString = #filePath,
        line: UInt = #line,
        validate: (any Error) -> Void = { _ in }
    ) async {
        do {
            try await expression()
            XCTFail(message, file: file, line: line)
        } catch {
            validate(error)
        }
    }

    /// 制約違反であることの確認。SQLite の文言に "constraint" が入る。
    func assertConstraintViolation(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await assertThrows(expression, "制約違反で失敗するはずだった", file: file, line: line) { error in
            XCTAssertTrue(
                "\(error)".contains("constraint"),
                "制約違反ではない理由で落ちている: \(error)",
                file: file, line: line
            )
        }
    }

    /// 実測値のサンプル。**4値以外も埋めてある**（保存されずに落ちることの検証用）。
    func sampleStats(
        ttftMs: Double = 412.7,
        tokensPerSecond: Double = 12.8,
        inputTokens: Int = 312,
        outputTokens: Int = 480
    ) -> GenerationStats {
        GenerationStats(
            ttftMs: ttftMs,
            tokensPerSecond: tokensPerSecond,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            ttfrMs: 15_300,
            prefillSeconds: 2.1,
            prefillTokensPerSecond: 148,
            decodeSeconds: 37.5,
            totalMs: 39_600,
            thinkingTokens: 1_800,
            stopReason: .completed,
            modelID: "mlx-community/Qwen3-8B-4bit",
            thinkingEnabled: true,
            peakMemoryBytes: 5_400_000_000
        )
    }
}
