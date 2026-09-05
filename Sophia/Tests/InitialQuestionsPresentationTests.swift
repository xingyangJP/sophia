import Foundation
import XCTest

@testable import Sophia

final class InitialQuestionsPresentationTests: StoreTestCase {

    @MainActor
    func testNewUserIsPromptedOnlyOnce() async throws {
        let defaults = try makeDefaults()
        let presentation = InitialQuestionsPresentationStore(defaults: defaults)
        let store = try makeInMemoryStore()

        let firstPresentation = await InitialQuestionsPresentationPolicy.shouldPresent(
            store: store,
            presentationStore: presentation
        )
        let secondPresentation = await InitialQuestionsPresentationPolicy.shouldPresent(
            store: store,
            presentationStore: presentation
        )
        XCTAssertTrue(firstPresentation)
        XCTAssertFalse(secondPresentation)
        XCTAssertTrue(presentation.hasPresented)
    }

    @MainActor
    func testExistingUserIsNotInterruptedAndIsMarkedPresented() async throws {
        let defaults = try makeDefaults()
        let presentation = InitialQuestionsPresentationStore(defaults: defaults)
        let store = try makeInMemoryStore()
        try await store.recordTrait(
            kind: .style,
            category: "existing",
            statement: "既に利用者像がある",
            source: .manual
        )

        let shouldPresent = await InitialQuestionsPresentationPolicy.shouldPresent(
            store: store,
            presentationStore: presentation
        )
        XCTAssertFalse(shouldPresent)
        XCTAssertTrue(presentation.hasPresented)
    }

    @MainActor
    func testUnavailableStoreDoesNotConsumeTheOnlyPrompt() async throws {
        let defaults = try makeDefaults()
        let presentation = InitialQuestionsPresentationStore(defaults: defaults)

        let shouldPresent = await InitialQuestionsPresentationPolicy.shouldPresent(
            store: nil,
            presentationStore: presentation
        )
        XCTAssertFalse(shouldPresent)
        XCTAssertFalse(presentation.hasPresented)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "InitialQuestionsPresentationTests.\(UUID().uuidString)"
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }
}
