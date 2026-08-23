import XCTest
@testable import Sophia

@MainActor
final class ToolApprovalBrokerTests: XCTestCase {
    private func request(id: UUID = UUID()) -> ToolApprovalRequest {
        ToolApprovalRequest(
            id: id,
            toolName: "workspace_change",
            operation: "create_file",
            resolvedPaths: ["/tmp/workspace/new.swift"],
            summary: "new.swift を作成",
            preview: "print(\"hello\")",
            planHash: "abc123",
            risk: .changesFile
        )
    }

    func testApprovalResumesOnlyTheMatchingRequest() async {
        let broker = ToolApprovalBroker()
        let approval = request()
        let task = Task { await broker.requestApproval(for: approval) }
        await Task.yield()

        XCTAssertEqual(broker.pendingRequest, approval)
        broker.approve(requestID: UUID())
        XCTAssertEqual(broker.pendingRequest, approval)

        broker.approve(requestID: approval.id)
        let decision = await task.value
        XCTAssertEqual(decision, .approved)
        XCTAssertNil(broker.pendingRequest)
    }

    func testRejectPendingReturnsRejected() async {
        let broker = ToolApprovalBroker()
        let approval = request()
        let task = Task { await broker.requestApproval(for: approval) }
        await Task.yield()

        broker.rejectPending()

        let decision = await task.value
        XCTAssertEqual(decision, .rejected)
        XCTAssertNil(broker.pendingRequest)
    }

    func testCancellationRejectsWithoutLeavingARequest() async {
        let broker = ToolApprovalBroker()
        let approval = request()
        let task = Task { await broker.requestApproval(for: approval) }
        await Task.yield()

        task.cancel()

        let decision = await task.value
        XCTAssertEqual(decision, .rejected)
        XCTAssertNil(broker.pendingRequest)
    }
}
