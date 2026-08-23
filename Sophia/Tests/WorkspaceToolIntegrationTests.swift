import Foundation
import XCTest
@testable import Sophia

@MainActor
final class WorkspaceToolIntegrationTests: XCTestCase {
    private var root: URL!
    private var auditURL: URL!
    private var auditRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceToolIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        auditRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceToolAuditTests-\(UUID().uuidString)", isDirectory: true)
        auditURL = auditRoot.appendingPathComponent("tool-audit.jsonl")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        if let auditRoot { try? FileManager.default.removeItem(at: auditRoot) }
    }

    func testCreateFileWaitsForApprovalThenExecutesAndAudits() async throws {
        let broker = ToolApprovalBroker()
        let audit = try ToolAuditStore(fileURL: auditURL)
        let runner = FolderToolRunner(
            folder: try SecurityScopedFolder.unscoped(directoryURL: root),
            approvalRequester: broker,
            auditStore: audit
        )
        let target = root.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let call = ModelToolCall(
            name: "workspace_change",
            argumentsJSON: #"{"operation":"create_file","path":"Sources/App.swift","content":"let answer = 42\n"}"#,
            callID: "create-1"
        )

        let task = Task { await runner.execute(call) }
        try await waitForPendingApproval(in: broker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "承認前に変更してはいけない")
        let request = try XCTUnwrap(broker.pendingRequest)
        XCTAssertEqual(request.operation, "create_file")
        XCTAssertEqual(request.resolvedPaths, [target.path])
        XCTAssertTrue(request.preview?.contains("let answer = 42") == true)

        broker.approve(requestID: request.id)
        let outcome = await task.value

        XCTAssertFalse(outcome.isFailure)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "let answer = 42\n")
        let events = try await audit.readAll()
        XCTAssertEqual(events.map(\.event), [.requested, .approved, .started, .succeeded])
        XCTAssertTrue(events.allSatisfy { $0.contentHash != "let answer = 42\n" })
    }

    func testRejectLeavesWorkspaceUntouched() async throws {
        let broker = ToolApprovalBroker()
        let audit = try ToolAuditStore(fileURL: auditURL)
        let runner = FolderToolRunner(
            folder: try SecurityScopedFolder.unscoped(directoryURL: root),
            approvalRequester: broker,
            auditStore: audit
        )
        let target = root.appendingPathComponent("rejected.txt")
        let call = ModelToolCall(
            name: "workspace_change",
            argumentsJSON: #"{"operation":"create_file","path":"rejected.txt","content":"no"}"#,
            callID: "reject-1"
        )

        let task = Task { await runner.execute(call) }
        try await waitForPendingApproval(in: broker)
        broker.rejectPending()
        let outcome = await task.value

        XCTAssertTrue(outcome.isFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let auditEvents = try await audit.readAll().map(\.event)
        XCTAssertEqual(auditEvents, [.requested, .rejected])
    }

    func testMissingApprovalUIFailsClosed() async throws {
        let target = root.appendingPathComponent("no-approval.txt")
        let audit = try ToolAuditStore(fileURL: auditURL)
        let runner = FolderToolRunner(
            folder: try SecurityScopedFolder.unscoped(directoryURL: root),
            auditStore: audit
        )

        let outcome = await runner.execute(ModelToolCall(
            name: "workspace_change",
            argumentsJSON: #"{"operation":"create_file","path":"no-approval.txt","content":"no"}"#,
            callID: "no-approval"
        ))

        XCTAssertTrue(outcome.isFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let auditEvents = try await audit.readAll().map(\.event)
        XCTAssertEqual(auditEvents, [.requested])
    }

    func testAuditFailurePreventsMutation() async throws {
        let target = root.appendingPathComponent("no-audit.txt")
        let unusableAudit = try ToolAuditStore(fileURL: root)
        let runner = FolderToolRunner(
            folder: try SecurityScopedFolder.unscoped(directoryURL: root),
            approvalRequester: ImmediateApprover(),
            auditStore: unusableAudit
        )

        let outcome = await runner.execute(ModelToolCall(
            name: "workspace_change",
            argumentsJSON: #"{"operation":"create_file","path":"no-audit.txt","content":"no"}"#,
            callID: "no-audit"
        ))

        XCTAssertTrue(outcome.isFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCancellationWhileAwaitingApprovalLeavesWorkspaceUntouched() async throws {
        let broker = ToolApprovalBroker()
        let audit = try ToolAuditStore(fileURL: auditURL)
        let runner = FolderToolRunner(
            folder: try SecurityScopedFolder.unscoped(directoryURL: root),
            approvalRequester: broker,
            auditStore: audit
        )
        let target = root.appendingPathComponent("cancelled.txt")

        let task = Task { await runner.execute(ModelToolCall(
            name: "workspace_change",
            argumentsJSON: #"{"operation":"create_file","path":"cancelled.txt","content":"no"}"#,
            callID: "cancelled"
        )) }
        try await waitForPendingApproval(in: broker)
        task.cancel()
        let outcome = await task.value

        XCTAssertTrue(outcome.isFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let auditEvents = try await audit.readAll().map(\.event)
        XCTAssertEqual(auditEvents, [.requested, .rejected])
    }

    func testGeneralFileOperationCannotWriteGitMetadata() async throws {
        let gitDirectory = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        let target = gitDirectory.appendingPathComponent("sophia-owned")
        let approver = ImmediateApprover()
        let runner = FolderToolRunner(
            folder: try SecurityScopedFolder.unscoped(directoryURL: root),
            approvalRequester: approver,
            auditStore: try ToolAuditStore(fileURL: auditURL)
        )

        let outcome = await runner.execute(ModelToolCall(
            name: "workspace_change",
            argumentsJSON: #"{"operation":"create_file","path":".git/sophia-owned","content":"no"}"#,
            callID: "git-metadata"
        ))

        XCTAssertTrue(outcome.isFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(approver.requests.isEmpty)
    }

    func testGitBranchCreateAndSwitchUseApproval() async throws {
        try git(["init", "--initial-branch=main"])
        try "initial".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "README.md"])
        try git([
            "-c", "user.name=Sophia Tests", "-c", "user.email=test@example.invalid",
            "commit", "--quiet", "-m", "initial",
        ])

        let approver = ImmediateApprover()
        let runner = FolderToolRunner(
            folder: try SecurityScopedFolder.unscoped(directoryURL: root),
            approvalRequester: approver,
            auditStore: try ToolAuditStore(fileURL: auditURL)
        )
        let create = await runner.execute(ModelToolCall(
            name: "workspace_change",
            argumentsJSON: #"{"operation":"git_create_branch","branch":"codex/generated"}"#,
            callID: "git-create"
        ))
        XCTAssertFalse(create.isFailure, create.responseText)
        XCTAssertEqual(try gitOutput(["branch", "--show-current"]), "main\n")
        XCTAssertEqual(try gitOutput(["rev-parse", "codex/generated"]), try gitOutput(["rev-parse", "HEAD"]))

        let switchResult = await runner.execute(ModelToolCall(
            name: "workspace_change",
            argumentsJSON: #"{"operation":"git_switch_branch","branch":"codex/generated"}"#,
            callID: "git-switch"
        ))
        XCTAssertFalse(switchResult.isFailure, switchResult.responseText)
        XCTAssertEqual(try gitOutput(["branch", "--show-current"]), "codex/generated\n")
        XCTAssertEqual(approver.requests.map(\.operation), ["git_create_branch", "git_switch_branch"])
    }

    private func git(_ arguments: [String]) throws {
        _ = try gitOutput(arguments)
    }

    private func gitOutput(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = try XCTUnwrap(WorkspaceGit.gitExecutableURL)
        process.currentDirectoryURL = root
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr])
        }
        return stdout
    }

    private func waitForPendingApproval(in broker: ToolApprovalBroker) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while broker.pendingRequest == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(broker.pendingRequest, "承認要求が2秒以内に表示されなかった")
    }
}

@MainActor
private final class ImmediateApprover: ToolApprovalRequesting {
    private(set) var requests: [ToolApprovalRequest] = []

    func requestApproval(for request: ToolApprovalRequest) async -> ToolApprovalDecision {
        requests.append(request)
        return .approved
    }
}
