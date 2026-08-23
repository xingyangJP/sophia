import XCTest
@testable import Sophia

final class ToolAuditStoreTests: XCTestCase {
    func testEventKindsCoverTheFR22Lifecycle() {
        XCTAssertEqual(
            Set(ToolAuditEventKind.allCases.map(\.rawValue)),
            Set([
                "requested", "approved", "rejected", "cancelled",
                "started", "succeeded", "failed",
            ])
        )
    }

    func testDefaultURLUsesApplicationSupportSophiaDirectory() throws {
        let url = try ToolAuditStore.defaultFileURL()

        XCTAssertEqual(url.lastPathComponent, "tool-audit.jsonl")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Sophia")
        XCTAssertEqual(
            url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "Application Support"
        )
    }

    func testAppendAndReadAllRoundTripEveryAuditField() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = try ToolAuditStore(fileURL: fixture.fileURL)
        let event = Self.makeEvent(index: 1)

        try await store.append(event)
        let events = try await store.readAll()

        XCTAssertEqual(events, [event])
    }

    func testSchemaHasNoContentOrRawArgumentsFields() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = try ToolAuditStore(fileURL: fixture.fileURL)

        try await store.append(Self.makeEvent(index: 1))
        let line = try XCTUnwrap(String(data: Data(contentsOf: fixture.fileURL), encoding: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )

        XCTAssertNil(object["content"])
        XCTAssertNil(object["arguments"])
        XCTAssertNil(object["rawArguments"])
        XCTAssertEqual(object["contentHash"] as? String, "content-hash-1")
    }

    func testControlCharactersAreEscapedAndCannotCreateExtraJSONLLines() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = try ToolAuditStore(fileURL: fixture.fileURL)
        let event = ToolAuditEvent(
            operationID: "operation\n1",
            callID: "call\u{0000}1",
            toolName: "workspace\tchange",
            operation: "write\rfile",
            relativePaths: ["folder\nfile.txt"],
            resolvedPaths: ["/tmp/folder\nfile.txt"],
            contentHash: "hash\u{007F}",
            planHash: "plan-1",
            event: .requested,
            resultSummary: "pending\napproval"
        )

        try await store.append(event)

        let raw = try Data(contentsOf: fixture.fileURL)
        XCTAssertEqual(raw.filter { $0 == 0x0A }.count, 1)
        XCTAssertEqual(raw.filter { $0 == 0x0D }.count, 0)
        XCTAssertFalse(raw.contains(0x00))

        let events = try await store.readAll()
        let decoded = try XCTUnwrap(events.first)
        XCTAssertEqual(decoded.operationID, "operation\\u{000A}1")
        XCTAssertEqual(decoded.callID, "call\\u{0000}1")
        XCTAssertEqual(decoded.toolName, "workspace\\u{0009}change")
        XCTAssertEqual(decoded.operation, "write\\u{000D}file")
        XCTAssertEqual(decoded.contentHash, "hash\\u{007F}")
        XCTAssertEqual(decoded.resultSummary, "pending\\u{000A}approval")
    }

    func testConcurrentAppendsAreSerializedAndReadable() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = try ToolAuditStore(fileURL: fixture.fileURL)
        let count = 100

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await store.append(Self.makeEvent(index: index))
                }
            }
            try await group.waitForAll()
        }

        let events = try await store.readAll()
        XCTAssertEqual(events.count, count)
        XCTAssertEqual(Set(events.map(\.operationID)).count, count)
        XCTAssertEqual(Set(events.map(\.callID)).count, count)
    }

    func testAppendFailureIsThrownSoCallerCanFailClosed() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let blockedParent = fixture.root.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: blockedParent)
        let store = try ToolAuditStore(
            fileURL: blockedParent.appendingPathComponent("tool-audit.jsonl")
        )

        do {
            try await store.append(Self.makeEvent(index: 1))
            XCTFail("append must throw when the audit path cannot be created")
        } catch {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: blockedParent.appendingPathComponent("tool-audit.jsonl").path
                )
            )
        }
    }

    func testAppendRejectsSymbolicLinkAuditFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let victim = fixture.root.appendingPathComponent("victim.txt")
        try Data("unchanged".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: fixture.fileURL, withDestinationURL: victim)
        let store = try ToolAuditStore(fileURL: fixture.fileURL)

        do {
            try await store.append(Self.makeEvent(index: 1))
            XCTFail("the audit writer must not follow a symbolic link")
        } catch {
            XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "unchanged")
        }
    }

    func testEmptyRequiredFieldIsRejectedWithoutCreatingAuditFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let store = try ToolAuditStore(fileURL: fixture.fileURL)
        let invalid = ToolAuditEvent(
            operationID: "",
            callID: "call-1",
            toolName: "workspace_change",
            operation: "write_file",
            planHash: "plan-1",
            event: .requested
        )

        do {
            try await store.append(invalid)
            XCTFail("an empty operation ID must be rejected")
        } catch let error as ToolAuditStoreError {
            XCTAssertEqual(error, .emptyRequiredField("operationID"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    func testMalformedRecordFailsReadInsteadOfHidingAuditCorruption() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try Data("{not-json}\n".utf8).write(to: fixture.fileURL)
        let store = try ToolAuditStore(fileURL: fixture.fileURL)

        do {
            _ = try await store.readAll()
            XCTFail("malformed audit data must not be silently skipped")
        } catch let error as ToolAuditStoreError {
            XCTAssertEqual(error, .malformedRecord(line: 1))
        }
    }

    private static func makeEvent(index: Int) -> ToolAuditEvent {
        ToolAuditEvent(
            operationID: "operation-\(index)",
            callID: "call-\(index)",
            toolName: "workspace_change",
            operation: "write_file",
            relativePaths: ["notes/\(index).txt"],
            resolvedPaths: ["/workspace/notes/\(index).txt"],
            contentHash: "content-hash-\(index)",
            planHash: "plan-hash-\(index)",
            event: .succeeded,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            resultSummary: "file written",
            beforeIdentity: "device:1-inode:\(index)",
            afterIdentity: "device:1-inode:\(index + 1)",
            beforeOID: "before-oid-\(index)",
            afterOID: "after-oid-\(index)"
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolAuditStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root)
    }
}

private struct Fixture {
    let root: URL
    var fileURL: URL { root.appendingPathComponent("tool-audit.jsonl") }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
