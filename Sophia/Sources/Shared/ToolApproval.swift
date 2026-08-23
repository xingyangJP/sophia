import Foundation

struct ToolApprovalRequest: Identifiable, Sendable, Equatable, Codable {
    enum Risk: String, Sendable, Equatable, Codable {
        case changesFile
        case deletesItem
        case changesGitBranch
    }

    let id: UUID
    let toolName: String
    let operation: String
    let resolvedPaths: [String]
    let summary: String
    let preview: String?
    let planHash: String
    let risk: Risk

    init(
        id: UUID = UUID(),
        toolName: String,
        operation: String,
        resolvedPaths: [String],
        summary: String,
        preview: String? = nil,
        planHash: String,
        risk: Risk
    ) {
        self.id = id
        self.toolName = toolName
        self.operation = operation
        self.resolvedPaths = resolvedPaths
        self.summary = summary
        self.preview = preview
        self.planHash = planHash
        self.risk = risk
    }
}

enum ToolApprovalDecision: String, Sendable, Equatable, Codable {
    case approved
    case rejected
}

/// The model can request a change, but only the UI can resolve this protocol.
@MainActor
protocol ToolApprovalRequesting: AnyObject, Sendable {
    func requestApproval(for request: ToolApprovalRequest) async -> ToolApprovalDecision
}
