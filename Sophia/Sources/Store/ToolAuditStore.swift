import Foundation
import Darwin

/// A lifecycle event for one tool operation recorded under FR-22.
enum ToolAuditEventKind: String, Codable, CaseIterable, Sendable {
    case requested
    case approved
    case rejected
    case cancelled
    case started
    case succeeded
    case failed
}

/// Metadata-only audit record for a tool operation.
///
/// File contents and raw model arguments intentionally have no field in this type. Callers should
/// put only a short outcome description in `resultSummary` and must persist a pre-I/O intent event
/// with `try await ToolAuditStore.append(_:)`. If that call throws, the operation must not start.
struct ToolAuditEvent: Codable, Equatable, Sendable {
    let operationID: String
    let callID: String
    let toolName: String
    let operation: String
    let relativePaths: [String]
    let resolvedPaths: [String]
    let contentHash: String?
    let planHash: String
    let event: ToolAuditEventKind
    let timestamp: Date
    let resultSummary: String?
    let beforeIdentity: String?
    let afterIdentity: String?
    let beforeOID: String?
    let afterOID: String?

    init(
        operationID: String,
        callID: String,
        toolName: String,
        operation: String,
        relativePaths: [String] = [],
        resolvedPaths: [String] = [],
        contentHash: String? = nil,
        planHash: String,
        event: ToolAuditEventKind,
        timestamp: Date = Date(),
        resultSummary: String? = nil,
        beforeIdentity: String? = nil,
        afterIdentity: String? = nil,
        beforeOID: String? = nil,
        afterOID: String? = nil
    ) {
        self.operationID = operationID
        self.callID = callID
        self.toolName = toolName
        self.operation = operation
        self.relativePaths = relativePaths
        self.resolvedPaths = resolvedPaths
        self.contentHash = contentHash
        self.planHash = planHash
        self.event = event
        self.timestamp = timestamp
        self.resultSummary = resultSummary
        self.beforeIdentity = beforeIdentity
        self.afterIdentity = afterIdentity
        self.beforeOID = beforeOID
        self.afterOID = afterOID
    }

    fileprivate func sanitized() -> Self {
        Self(
            operationID: Self.sanitize(operationID),
            callID: Self.sanitize(callID),
            toolName: Self.sanitize(toolName),
            operation: Self.sanitize(operation),
            relativePaths: relativePaths.map(Self.sanitize),
            resolvedPaths: resolvedPaths.map(Self.sanitize),
            contentHash: contentHash.map(Self.sanitize),
            planHash: Self.sanitize(planHash),
            event: event,
            timestamp: timestamp,
            resultSummary: resultSummary.map(Self.sanitize),
            beforeIdentity: beforeIdentity.map(Self.sanitize),
            afterIdentity: afterIdentity.map(Self.sanitize),
            beforeOID: beforeOID.map(Self.sanitize),
            afterOID: afterOID.map(Self.sanitize)
        )
    }

    private static func sanitize(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)

        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                result += String(format: "\\u{%04X}", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

enum ToolAuditStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case emptyRequiredField(String)
    case auditFileIsNotRegular
    case encodedRecordContainsLineBreak
    case malformedRecord(line: Int)
}

/// Append-only JSONL persistence for FR-22 tool audit events.
///
/// Actor isolation serializes all app-process writes. `append(_:)` does not swallow create, write,
/// flush, or close errors, so a caller can fail closed before performing a mutating tool operation.
actor ToolAuditStore {
    private static let directoryName = "Sophia"
    private static let fileName = "tool-audit.jsonl"

    let fileURL: URL

    init(fileURL: URL? = nil) throws {
        if let fileURL {
            self.fileURL = fileURL.standardizedFileURL
        } else {
            self.fileURL = try Self.defaultFileURL()
        }
    }

    nonisolated static func defaultFileURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ToolAuditStoreError.applicationSupportUnavailable
        }

        return applicationSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Persists one complete event and flushes it before returning.
    ///
    /// Mutating callers must await this method for their intent event and stop if it throws.
    func append(_ event: ToolAuditEvent) throws {
        let sanitized = event.sanitized()
        try Self.validateRequiredFields(in: sanitized)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let payload = try encoder.encode(sanitized)
        guard !payload.contains(0x0A), !payload.contains(0x0D) else {
            throw ToolAuditStoreError.encodedRecordContainsLineBreak
        }

        var record = payload
        record.append(0x0A)

        try ensureParentDirectoryExists()
        try appendRecord(record)
    }

    /// Reads every complete event in append order. A malformed line fails the whole read.
    func readAll() throws -> [ToolAuditEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        return try data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .enumerated()
            .map { index, line in
                do {
                    return try decoder.decode(ToolAuditEvent.self, from: Data(line)).sanitized()
                } catch {
                    throw ToolAuditStoreError.malformedRecord(line: index + 1)
                }
            }
    }

    private func ensureParentDirectoryExists() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func appendRecord(_ record: Data) throws {
        var descriptor = Darwin.open(
            fileURL.path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }
        defer {
            if descriptor >= 0 {
                Darwin.close(descriptor)
            }
        }

        var fileInfo = stat()
        guard Darwin.fstat(descriptor, &fileInfo) == 0 else {
            throw Self.currentPOSIXError()
        }
        guard fileInfo.st_mode & S_IFMT == S_IFREG else {
            throw ToolAuditStoreError.auditFileIsNotRegular
        }

        try record.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw Self.currentPOSIXError() }
                written += result
            }
        }

        guard Darwin.fsync(descriptor) == 0 else { throw Self.currentPOSIXError() }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw Self.currentPOSIXError()
        }
        descriptor = -1
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func validateRequiredFields(in event: ToolAuditEvent) throws {
        let fields = [
            ("operationID", event.operationID),
            ("callID", event.callID),
            ("toolName", event.toolName),
            ("operation", event.operation),
            ("planHash", event.planHash),
        ]

        if let empty = fields.first(where: { $0.1.isEmpty }) {
            throw ToolAuditStoreError.emptyRequiredField(empty.0)
        }
    }
}
