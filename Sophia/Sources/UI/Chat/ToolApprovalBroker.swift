import Foundation
import Observation

@MainActor
@Observable
final class ToolApprovalBroker: ToolApprovalRequesting {
    private(set) var pendingRequest: ToolApprovalRequest?

    @ObservationIgnored
    private var continuation: CheckedContinuation<ToolApprovalDecision, Never>?

    func requestApproval(for request: ToolApprovalRequest) async -> ToolApprovalDecision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let previous = self.continuation {
                    previous.resume(returning: .rejected)
                }
                self.pendingRequest = request
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(requestID: request.id, decision: .rejected)
            }
        }
    }

    func approve(requestID: UUID) {
        resolve(requestID: requestID, decision: .approved)
    }

    func reject(requestID: UUID) {
        resolve(requestID: requestID, decision: .rejected)
    }

    func rejectPending() {
        guard let id = pendingRequest?.id else { return }
        resolve(requestID: id, decision: .rejected)
    }

    private func resolve(requestID: UUID, decision: ToolApprovalDecision) {
        guard pendingRequest?.id == requestID, let continuation else { return }
        self.continuation = nil
        pendingRequest = nil
        continuation.resume(returning: decision)
    }
}
