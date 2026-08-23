import CryptoKit
import Darwin
import Foundation

enum WorkspaceFileSystemError: Error, Sendable, Equatable, LocalizedError {
    case invalidRelativePath(String)
    case gitMetadataRejected(String)
    case notFound(String)
    case alreadyExists(String)
    case notRegularFile(String)
    case notDirectory(String)
    case unsupportedFileType(String)
    case hardLinkRejected(String)
    case nonEmptyDirectory(String)
    case invalidUTF8(String)
    case fileTooLarge(path: String, byteCount: Int64, limit: Int64)
    case replacementMustOccurExactlyOnce(path: String, occurrences: Int)
    case changedSincePreparation(String)
    case planBelongsToAnotherWorkspace
    case planAlreadyExecuted
    case systemCall(operation: String, path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path):
            return "相対パスとして扱えません: \(path)"
        case .gitMetadataRejected(let path):
            return "一般ファイル操作では .git を変更できません: \(path)"
        case .notFound(let path):
            return "対象が見つかりません: \(path)"
        case .alreadyExists(let path):
            return "対象は既に存在します: \(path)"
        case .notRegularFile(let path):
            return "通常ファイルではありません: \(path)"
        case .notDirectory(let path):
            return "ディレクトリではありません: \(path)"
        case .unsupportedFileType(let path):
            return "シンボリックリンクなどの特殊ファイルは操作できません: \(path)"
        case .hardLinkRejected(let path):
            return "複数リンクを持つファイルは操作できません: \(path)"
        case .nonEmptyDirectory(let path):
            return "空でないディレクトリは削除できません: \(path)"
        case .invalidUTF8(let path):
            return "UTF-8 テキストではありません: \(path)"
        case .fileTooLarge(let path, let byteCount, let limit):
            return "変更できるファイルサイズの上限を超えています（\(byteCount) / \(limit) bytes）: \(path)"
        case .replacementMustOccurExactlyOnce(let path, let occurrences):
            return "置換対象は1回だけ現れる必要があります（検出: \(occurrences)回）: \(path)"
        case .changedSincePreparation(let path):
            return "承認待ちの間に対象が変化しました。再承認が必要です: \(path)"
        case .planBelongsToAnotherWorkspace:
            return "別のワークスペースで準備した操作です"
        case .planAlreadyExecuted:
            return "この操作計画は既に使用されています"
        case .systemCall(let operation, let path, let code):
            return "\(operation) に失敗しました (errno=\(code)): \(path)"
        }
    }
}

enum WorkspaceChange: Sendable, Equatable {
    case createFile(path: String, contents: String)
    case replaceText(path: String, oldText: String, newText: String)
    case copyFile(source: String, destination: String)
    case movePath(source: String, destination: String)
    case deletePath(path: String)
    case createDirectory(path: String)
}

struct WorkspaceFileFingerprint: Sendable, Equatable {
    enum Kind: String, Sendable {
        case missing
        case regularFile
        case directory
    }

    let path: String
    let kind: Kind
    let device: UInt64?
    let inode: UInt64?
    let byteCount: Int64?
    let modificationSeconds: Int64?
    let modificationNanoseconds: Int64?
    let changeSeconds: Int64?
    let changeNanoseconds: Int64?
    let sha256: String?
}

struct WorkspaceChangePlan: Sendable {
    let id: UUID
    let change: WorkspaceChange
    let resolvedPaths: [String]
    let summary: String
    let fingerprints: [WorkspaceFileFingerprint]

    fileprivate let ownerID: UUID
    fileprivate let prepared: PreparedWorkspaceChange
}

struct WorkspaceChangeResult: Sendable, Equatable {
    let operationID: UUID
    let summary: String
    let affectedPaths: [String]
}

/// A capability scoped to one user-selected folder.
///
/// Mutation never uses a path resolved by `realpath`. Every syscall starts at an
/// open root descriptor, and every intermediate component is opened with
/// `O_DIRECTORY | O_NOFOLLOW`. A prepared plan is single-use and all snapshots
/// are checked again immediately before the mutation.
final class WorkspaceFileSystem: @unchecked Sendable {
    static let maximumFileBytes = Int64(FolderReadLimits.maximumFileBytes)

    private let folder: SecurityScopedFolder
    private let ownerID = UUID()
    private let stateLock = NSLock()
    private var consumedPlanIDs: Set<UUID> = []

    init(folder: SecurityScopedFolder) {
        self.folder = folder
    }

    func prepare(_ change: WorkspaceChange) throws -> WorkspaceChangePlan {
        try folder.withAccess { _ in
            let root = try openRoot()
            defer { root.close() }
            return try prepare(change, root: root)
        }
    }

    func execute(_ plan: WorkspaceChangePlan) throws -> WorkspaceChangeResult {
        guard plan.ownerID == ownerID else {
            throw WorkspaceFileSystemError.planBelongsToAnotherWorkspace
        }
        try consume(plan.id)

        return try folder.withAccess { _ in
            let root = try openRoot()
            defer { root.close() }
            return try execute(plan, root: root)
        }
    }

    private func consume(_ id: UUID) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard consumedPlanIDs.insert(id).inserted else {
            throw WorkspaceFileSystemError.planAlreadyExecuted
        }
    }
}

// MARK: - Prepared state

private struct RelativeWorkspacePath: Sendable, Equatable {
    let original: String
    let components: [String]
    let absolutePath: String
}

private struct EntrySnapshot: Sendable, Equatable {
    let parent: WorkspaceFileFingerprint
    let entry: WorkspaceFileFingerprint
}

private enum PreparedWorkspaceChange: Sendable {
    case createFile(path: RelativeWorkspacePath, contents: Data, destination: EntrySnapshot)
    case replaceText(
        path: RelativeWorkspacePath,
        oldText: String,
        newText: String,
        result: Data,
        source: EntrySnapshot
    )
    case copyFile(
        source: RelativeWorkspacePath,
        destination: RelativeWorkspacePath,
        sourceSnapshot: EntrySnapshot,
        destinationSnapshot: EntrySnapshot
    )
    case movePath(
        source: RelativeWorkspacePath,
        destination: RelativeWorkspacePath,
        sourceSnapshot: EntrySnapshot,
        destinationSnapshot: EntrySnapshot
    )
    case deletePath(path: RelativeWorkspacePath, snapshot: EntrySnapshot)
    case createDirectory(path: RelativeWorkspacePath, destination: EntrySnapshot)
}

private final class OwnedFileDescriptor {
    let rawValue: Int32
    private var isOpen = true

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        Darwin.close(rawValue)
    }

    deinit { close() }
}

// MARK: - Preparation

private extension WorkspaceFileSystem {
    func prepare(_ change: WorkspaceChange, root: OwnedFileDescriptor) throws -> WorkspaceChangePlan {
        let planID = UUID()

        switch change {
        case .createFile(let rawPath, let contents):
            let path = try parse(rawPath)
            let snapshot = try snapshot(path, root: root, allowMissing: true)
            guard snapshot.entry.kind == .missing else {
                throw WorkspaceFileSystemError.alreadyExists(path.absolutePath)
            }
            let data = Data(contents.utf8)
            try requireSizeWithinLimit(Int64(data.count), path: path.absolutePath)
            return makePlan(
                id: planID,
                change: change,
                paths: [path],
                summary: "新規UTF-8ファイル、\(data.count) bytes、SHA-256 \(sha256(data).prefix(12))",
                snapshots: [snapshot],
                prepared: .createFile(path: path, contents: data, destination: snapshot)
            )

        case .replaceText(let rawPath, let oldText, let newText):
            let path = try parse(rawPath)
            guard !oldText.isEmpty else {
                throw WorkspaceFileSystemError.replacementMustOccurExactlyOnce(
                    path: path.absolutePath,
                    occurrences: 0
                )
            }
            let (snapshot, data) = try regularFileSnapshotAndData(path, root: root)
            guard let text = String(data: data, encoding: .utf8) else {
                throw WorkspaceFileSystemError.invalidUTF8(path.absolutePath)
            }
            let occurrences = text.nonOverlappingOccurrenceCount(of: oldText)
            guard occurrences == 1 else {
                throw WorkspaceFileSystemError.replacementMustOccurExactlyOnce(
                    path: path.absolutePath,
                    occurrences: occurrences
                )
            }
            let resultText = text.replacingOccurrences(of: oldText, with: newText)
            let result = Data(resultText.utf8)
            try requireSizeWithinLimit(Int64(result.count), path: path.absolutePath)
            let preview = "1箇所を置換: \(preview(oldText)) -> \(preview(newText)); 結果 \(result.count) bytes"
            return makePlan(
                id: planID,
                change: change,
                paths: [path],
                summary: preview,
                snapshots: [snapshot],
                prepared: .replaceText(
                    path: path,
                    oldText: oldText,
                    newText: newText,
                    result: result,
                    source: snapshot
                )
            )

        case .copyFile(let rawSource, let rawDestination):
            let source = try parse(rawSource)
            let destination = try parse(rawDestination)
            let (sourceSnapshot, _) = try regularFileSnapshotAndData(source, root: root)
            let destinationSnapshot = try snapshot(destination, root: root, allowMissing: true)
            guard destinationSnapshot.entry.kind == .missing else {
                throw WorkspaceFileSystemError.alreadyExists(destination.absolutePath)
            }
            return makePlan(
                id: planID,
                change: change,
                paths: [source, destination],
                summary: "通常ファイルを新規コピー（上書きなし）",
                snapshots: [sourceSnapshot, destinationSnapshot],
                prepared: .copyFile(
                    source: source,
                    destination: destination,
                    sourceSnapshot: sourceSnapshot,
                    destinationSnapshot: destinationSnapshot
                )
            )

        case .movePath(let rawSource, let rawDestination):
            let source = try parse(rawSource)
            let destination = try parse(rawDestination)
            let sourceSnapshot = try snapshot(source, root: root, allowMissing: false)
            try requireSupportedEntry(sourceSnapshot.entry, path: source.absolutePath)
            if sourceSnapshot.entry.kind == .directory,
               destination.components.starts(with: source.components) {
                throw WorkspaceFileSystemError.invalidRelativePath(rawDestination)
            }
            let destinationSnapshot = try snapshot(destination, root: root, allowMissing: true)
            guard destinationSnapshot.entry.kind == .missing else {
                throw WorkspaceFileSystemError.alreadyExists(destination.absolutePath)
            }
            return makePlan(
                id: planID,
                change: change,
                paths: [source, destination],
                summary: "ファイルまたはディレクトリを移動（上書きなし）",
                snapshots: [sourceSnapshot, destinationSnapshot],
                prepared: .movePath(
                    source: source,
                    destination: destination,
                    sourceSnapshot: sourceSnapshot,
                    destinationSnapshot: destinationSnapshot
                )
            )

        case .deletePath(let rawPath):
            let path = try parse(rawPath)
            let snapshot = try snapshot(path, root: root, allowMissing: false)
            try requireSupportedEntry(snapshot.entry, path: path.absolutePath)
            if snapshot.entry.kind == .directory {
                try requireEmptyDirectory(path, root: root)
            }
            return makePlan(
                id: planID,
                change: change,
                paths: [path],
                summary: snapshot.entry.kind == .directory
                    ? "空ディレクトリを削除"
                    : "通常ファイルを削除",
                snapshots: [snapshot],
                prepared: .deletePath(path: path, snapshot: snapshot)
            )

        case .createDirectory(let rawPath):
            let path = try parse(rawPath)
            let snapshot = try snapshot(path, root: root, allowMissing: true)
            guard snapshot.entry.kind == .missing else {
                throw WorkspaceFileSystemError.alreadyExists(path.absolutePath)
            }
            return makePlan(
                id: planID,
                change: change,
                paths: [path],
                summary: "空ディレクトリを新規作成（中間ディレクトリは作成しない）",
                snapshots: [snapshot],
                prepared: .createDirectory(path: path, destination: snapshot)
            )
        }
    }

    func makePlan(
        id: UUID,
        change: WorkspaceChange,
        paths: [RelativeWorkspacePath],
        summary: String,
        snapshots: [EntrySnapshot],
        prepared: PreparedWorkspaceChange
    ) -> WorkspaceChangePlan {
        WorkspaceChangePlan(
            id: id,
            change: change,
            resolvedPaths: paths.map(\.absolutePath),
            summary: summary,
            fingerprints: snapshots.flatMap { [$0.parent, $0.entry] },
            ownerID: ownerID,
            prepared: prepared
        )
    }
}

// MARK: - Execution

private extension WorkspaceFileSystem {
    func execute(
        _ plan: WorkspaceChangePlan,
        root: OwnedFileDescriptor
    ) throws -> WorkspaceChangeResult {
        switch plan.prepared {
        case .createFile(let path, let contents, let destination):
            try verify(destination, path: path, root: root)
            try createFile(path, contents: contents, root: root)

        case .replaceText(let path, let oldText, let newText, let result, let source):
            let (_, currentData) = try regularFileSnapshotAndData(path, root: root)
            try verify(source, path: path, root: root)
            guard let currentText = String(data: currentData, encoding: .utf8) else {
                throw WorkspaceFileSystemError.invalidUTF8(path.absolutePath)
            }
            guard currentText.nonOverlappingOccurrenceCount(of: oldText) == 1,
                  Data(currentText.replacingOccurrences(of: oldText, with: newText).utf8) == result else {
                throw WorkspaceFileSystemError.changedSincePreparation(path.absolutePath)
            }
            try replaceFileAtomically(path, contents: result, expected: source.entry, root: root)

        case .copyFile(let source, let destination, let sourceSnapshot, let destinationSnapshot):
            try verify(sourceSnapshot, path: source, root: root)
            try verify(destinationSnapshot, path: destination, root: root)
            try copyFile(source, destination: destination, expected: sourceSnapshot.entry, root: root)

        case .movePath(let source, let destination, let sourceSnapshot, let destinationSnapshot):
            try verify(sourceSnapshot, path: source, root: root)
            try verify(destinationSnapshot, path: destination, root: root)
            try movePath(
                source,
                destination: destination,
                expected: sourceSnapshot.entry,
                root: root
            )

        case .deletePath(let path, let snapshot):
            try verify(snapshot, path: path, root: root)
            if snapshot.entry.kind == .directory {
                try requireEmptyDirectory(path, root: root)
            }
            try deletePath(path, expected: snapshot.entry, root: root)

        case .createDirectory(let path, let destination):
            try verify(destination, path: path, root: root)
            try createDirectory(path, root: root)
        }

        return WorkspaceChangeResult(
            operationID: plan.id,
            summary: plan.summary,
            affectedPaths: plan.resolvedPaths
        )
    }
}

// MARK: - Safe path traversal and snapshots

private extension WorkspaceFileSystem {
    func parse(_ rawPath: String) throws -> RelativeWorkspacePath {
        guard !rawPath.isEmpty,
              !rawPath.hasPrefix("/"),
              !rawPath.hasPrefix("~"),
              !rawPath.contains("\0") else {
            throw WorkspaceFileSystemError.invalidRelativePath(rawPath)
        }

        let components = rawPath.components(separatedBy: "/")
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != "~" }) else {
            throw WorkspaceFileSystemError.invalidRelativePath(rawPath)
        }
        if components[0].caseInsensitiveCompare(".git") == .orderedSame {
            throw WorkspaceFileSystemError.gitMetadataRejected(rawPath)
        }

        var url = URL(fileURLWithPath: folder.canonicalRootPath, isDirectory: true)
        for component in components {
            url.appendPathComponent(component)
        }
        return RelativeWorkspacePath(
            original: rawPath,
            components: components,
            absolutePath: url.path
        )
    }

    func openRoot() throws -> OwnedFileDescriptor {
        let fd = Darwin.open(
            folder.canonicalRootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fd >= 0 else {
            throw syscallError("open root", folder.canonicalRootPath)
        }
        let owned = OwnedFileDescriptor(fd)
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = syscallError("fstat root", folder.canonicalRootPath)
            owned.close()
            throw error
        }
        guard isDirectory(info.st_mode) else {
            owned.close()
            throw WorkspaceFileSystemError.notDirectory(folder.canonicalRootPath)
        }
        return owned
    }

    func openParent(
        of path: RelativeWorkspacePath,
        root: OwnedFileDescriptor
    ) throws -> OwnedFileDescriptor {
        let rootCopy = fcntl(root.rawValue, F_DUPFD_CLOEXEC, 0)
        guard rootCopy >= 0 else { throw syscallError("dup root", path.absolutePath) }
        var current = OwnedFileDescriptor(rootCopy)

        for component in path.components.dropLast() {
            let nextFD = component.withCString {
                openat(
                    current.rawValue,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextFD >= 0 else {
                let code = errno
                current.close()
                if code == ENOENT { throw WorkspaceFileSystemError.notFound(path.absolutePath) }
                if code == ELOOP { throw WorkspaceFileSystemError.unsupportedFileType(path.absolutePath) }
                if code == ENOTDIR { throw WorkspaceFileSystemError.notDirectory(path.absolutePath) }
                throw WorkspaceFileSystemError.systemCall(
                    operation: "openat parent",
                    path: path.absolutePath,
                    code: code
                )
            }
            current.close()
            current = OwnedFileDescriptor(nextFD)
        }
        return current
    }

    func snapshot(
        _ path: RelativeWorkspacePath,
        root: OwnedFileDescriptor,
        allowMissing: Bool
    ) throws -> EntrySnapshot {
        let parent = try openParent(of: path, root: root)
        defer { parent.close() }
        let parentFingerprint = try fingerprint(
            fd: parent.rawValue,
            path: parentAbsolutePath(of: path)
        )
        guard parentFingerprint.kind == .directory else {
            throw WorkspaceFileSystemError.notDirectory(parentAbsolutePath(of: path))
        }

        do {
            let entry = try fingerprintEntry(
                name: path.components.last!,
                parentFD: parent.rawValue,
                path: path.absolutePath
            )
            return EntrySnapshot(parent: parentFingerprint, entry: entry)
        } catch WorkspaceFileSystemError.notFound where allowMissing {
            return EntrySnapshot(
                parent: parentFingerprint,
                entry: missingFingerprint(path.absolutePath)
            )
        }
    }

    func regularFileSnapshotAndData(
        _ path: RelativeWorkspacePath,
        root: OwnedFileDescriptor
    ) throws -> (EntrySnapshot, Data) {
        let parent = try openParent(of: path, root: root)
        defer { parent.close() }
        let parentFingerprint = try fingerprint(
            fd: parent.rawValue,
            path: parentAbsolutePath(of: path)
        )
        let file = try openRegularFile(
            name: path.components.last!,
            parentFD: parent.rawValue,
            path: path.absolutePath
        )
        defer { file.close() }
        let data = try readAll(file.rawValue, path: path.absolutePath)
        let entry = try fingerprint(fd: file.rawValue, path: path.absolutePath, data: data)
        try requireRegularEntry(entry, path: path.absolutePath)
        return (EntrySnapshot(parent: parentFingerprint, entry: entry), data)
    }

    func verify(
        _ expected: EntrySnapshot,
        path: RelativeWorkspacePath,
        root: OwnedFileDescriptor
    ) throws {
        let actual: EntrySnapshot
        if expected.entry.kind == .missing {
            actual = try snapshot(path, root: root, allowMissing: true)
        } else if expected.entry.kind == .regularFile {
            actual = try regularFileSnapshotAndData(path, root: root).0
        } else {
            actual = try snapshot(path, root: root, allowMissing: false)
        }
        guard actual == expected else {
            throw WorkspaceFileSystemError.changedSincePreparation(path.absolutePath)
        }
    }

    func fingerprintEntry(name: String, parentFD: Int32, path: String) throws -> WorkspaceFileFingerprint {
        var info = stat()
        let result = name.withCString { fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else {
            if errno == ENOENT { throw WorkspaceFileSystemError.notFound(path) }
            throw syscallError("fstatat", path)
        }
        if isSymbolicLink(info.st_mode) {
            throw WorkspaceFileSystemError.unsupportedFileType(path)
        }
        if isRegular(info.st_mode) {
            let file = try openRegularFile(name: name, parentFD: parentFD, path: path)
            defer { file.close() }
            let data = try readAll(file.rawValue, path: path)
            return try fingerprint(fd: file.rawValue, path: path, data: data)
        }
        if isDirectory(info.st_mode) {
            let fd = name.withCString {
                openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard fd >= 0 else { throw syscallError("openat directory", path) }
            let directory = OwnedFileDescriptor(fd)
            defer { directory.close() }
            return try fingerprint(fd: fd, path: path)
        }
        throw WorkspaceFileSystemError.unsupportedFileType(path)
    }

    func fingerprint(
        fd: Int32,
        path: String,
        data: Data? = nil
    ) throws -> WorkspaceFileFingerprint {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw syscallError("fstat", path) }
        let kind: WorkspaceFileFingerprint.Kind
        if isRegular(info.st_mode) {
            guard info.st_nlink == 1 else {
                throw WorkspaceFileSystemError.hardLinkRejected(path)
            }
            kind = .regularFile
        } else if isDirectory(info.st_mode) {
            kind = .directory
        } else {
            throw WorkspaceFileSystemError.unsupportedFileType(path)
        }
        return WorkspaceFileFingerprint(
            path: path,
            kind: kind,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            byteCount: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec),
            sha256: data.map(sha256)
        )
    }

    func missingFingerprint(_ path: String) -> WorkspaceFileFingerprint {
        WorkspaceFileFingerprint(
            path: path,
            kind: .missing,
            device: nil,
            inode: nil,
            byteCount: nil,
            modificationSeconds: nil,
            modificationNanoseconds: nil,
            changeSeconds: nil,
            changeNanoseconds: nil,
            sha256: nil
        )
    }

    /// `rename(2)` legitimately changes ctime even though the directory entry
    /// still refers to the exact inode that was approved. Post-rename checks
    /// therefore bind identity and file contents, while pre-mutation checks keep
    /// using the complete fingerprint above.
    func hasSameIdentityAndContents(
        _ actual: WorkspaceFileFingerprint,
        as expected: WorkspaceFileFingerprint
    ) -> Bool {
        guard actual.kind == expected.kind,
              actual.device == expected.device,
              actual.inode == expected.inode
        else { return false }

        switch expected.kind {
        case .regularFile:
            return actual.byteCount == expected.byteCount
                && actual.sha256 == expected.sha256
        case .directory:
            return true
        case .missing:
            return false
        }
    }
}

// MARK: - Mutations

private extension WorkspaceFileSystem {
    func createFile(
        _ path: RelativeWorkspacePath,
        contents: Data,
        root: OwnedFileDescriptor
    ) throws {
        let parent = try openParent(of: path, root: root)
        defer { parent.close() }
        let name = path.components.last!
        let fd = name.withCString {
            openat(
                parent.rawValue,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard fd >= 0 else {
            if errno == EEXIST { throw WorkspaceFileSystemError.alreadyExists(path.absolutePath) }
            throw syscallError("openat create", path.absolutePath)
        }
        let file = OwnedFileDescriptor(fd)
        do {
            try writeAll(contents, fd: fd, path: path.absolutePath)
            guard fsync(fd) == 0 else { throw syscallError("fsync", path.absolutePath) }
            file.close()
        } catch {
            file.close()
            _ = name.withCString { unlinkat(parent.rawValue, $0, 0) }
            throw error
        }
    }

    func replaceFileAtomically(
        _ path: RelativeWorkspacePath,
        contents: Data,
        expected: WorkspaceFileFingerprint,
        root: OwnedFileDescriptor
    ) throws {
        let parent = try openParent(of: path, root: root)
        defer { parent.close() }
        let target = path.components.last!
        let sourceFile = try openRegularFile(
            name: target,
            parentFD: parent.rawValue,
            path: path.absolutePath
        )
        defer { sourceFile.close() }
        let sourceData = try readAll(sourceFile.rawValue, path: path.absolutePath)
        let sourceFingerprint = try fingerprint(
            fd: sourceFile.rawValue,
            path: path.absolutePath,
            data: sourceData
        )
        guard sourceFingerprint == expected else {
            throw WorkspaceFileSystemError.changedSincePreparation(path.absolutePath)
        }
        let temporary = ".sophia-write-\(UUID().uuidString)"
        let temporaryPath = parentAbsolutePath(of: path) + "/" + temporary
        let fd = temporary.withCString {
            openat(
                parent.rawValue,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard fd >= 0 else { throw syscallError("openat temporary", temporaryPath) }
        let temporaryFile = OwnedFileDescriptor(fd)
        do {
            try writeAll(contents, fd: fd, path: temporaryPath)
            guard fcopyfile(sourceFile.rawValue, fd, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw syscallError("fcopyfile metadata", temporaryPath)
            }
            guard futimens(fd, nil) == 0 else {
                throw syscallError("futimens", temporaryPath)
            }
            guard fsync(fd) == 0 else { throw syscallError("fsync", temporaryPath) }
            temporaryFile.close()

            let current = try fingerprintEntry(
                name: target,
                parentFD: parent.rawValue,
                path: path.absolutePath
            )
            guard current == expected else {
                throw WorkspaceFileSystemError.changedSincePreparation(path.absolutePath)
            }

            let swapped = temporary.withCString { temporaryCString in
                target.withCString { targetCString in
                    renameatx_np(
                        parent.rawValue,
                        temporaryCString,
                        parent.rawValue,
                        targetCString,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard swapped == 0 else { throw syscallError("renameatx_np swap", path.absolutePath) }

            let oldEntry = try fingerprintEntry(
                name: temporary,
                parentFD: parent.rawValue,
                path: temporaryPath
            )
            guard hasSameIdentityAndContents(oldEntry, as: expected) else {
                _ = temporary.withCString { temporaryCString in
                    target.withCString { targetCString in
                        renameatx_np(
                            parent.rawValue,
                            temporaryCString,
                            parent.rawValue,
                            targetCString,
                            UInt32(RENAME_SWAP)
                        )
                    }
                }
                throw WorkspaceFileSystemError.changedSincePreparation(path.absolutePath)
            }
            guard temporary.withCString({ unlinkat(parent.rawValue, $0, 0) }) == 0 else {
                throw syscallError("unlinkat replaced file", temporaryPath)
            }
            _ = fsync(parent.rawValue)
        } catch {
            temporaryFile.close()
            _ = temporary.withCString { unlinkat(parent.rawValue, $0, 0) }
            throw error
        }
    }

    func copyFile(
        _ source: RelativeWorkspacePath,
        destination: RelativeWorkspacePath,
        expected: WorkspaceFileFingerprint,
        root: OwnedFileDescriptor
    ) throws {
        let sourceParent = try openParent(of: source, root: root)
        defer { sourceParent.close() }
        let sourceFile = try openRegularFile(
            name: source.components.last!,
            parentFD: sourceParent.rawValue,
            path: source.absolutePath
        )
        defer { sourceFile.close() }
        let sourceData = try readAll(sourceFile.rawValue, path: source.absolutePath)
        let current = try fingerprint(fd: sourceFile.rawValue, path: source.absolutePath, data: sourceData)
        guard current == expected else {
            throw WorkspaceFileSystemError.changedSincePreparation(source.absolutePath)
        }
        try createFile(destination, contents: sourceData, root: root)
    }

    func movePath(
        _ source: RelativeWorkspacePath,
        destination: RelativeWorkspacePath,
        expected: WorkspaceFileFingerprint,
        root: OwnedFileDescriptor
    ) throws {
        let sourceParent = try openParent(of: source, root: root)
        defer { sourceParent.close() }
        let destinationParent = try openParent(of: destination, root: root)
        defer { destinationParent.close() }
        let sourceName = source.components.last!
        let destinationName = destination.components.last!

        let current = try fingerprintEntry(
            name: sourceName,
            parentFD: sourceParent.rawValue,
            path: source.absolutePath
        )
        guard current == expected else {
            throw WorkspaceFileSystemError.changedSincePreparation(source.absolutePath)
        }

        let result = sourceName.withCString { sourceCString in
            destinationName.withCString { destinationCString in
                renameatx_np(
                    sourceParent.rawValue,
                    sourceCString,
                    destinationParent.rawValue,
                    destinationCString,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw WorkspaceFileSystemError.alreadyExists(destination.absolutePath) }
            throw syscallError("renameatx_np move", destination.absolutePath)
        }

        do {
            let moved = try fingerprintEntry(
                name: destinationName,
                parentFD: destinationParent.rawValue,
                path: destination.absolutePath
            )
            guard hasSameIdentityAndContents(moved, as: expected) else {
                throw WorkspaceFileSystemError.changedSincePreparation(source.absolutePath)
            }
        } catch {
            _ = destinationName.withCString { destinationCString in
                sourceName.withCString { sourceCString in
                    renameatx_np(
                        destinationParent.rawValue,
                        destinationCString,
                        sourceParent.rawValue,
                        sourceCString,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            throw error
        }
    }

    func deletePath(
        _ path: RelativeWorkspacePath,
        expected: WorkspaceFileFingerprint,
        root: OwnedFileDescriptor
    ) throws {
        let parent = try openParent(of: path, root: root)
        defer { parent.close() }
        let target = path.components.last!
        let quarantine = ".sophia-delete-\(UUID().uuidString)"
        let quarantinePath = parentAbsolutePath(of: path) + "/" + quarantine

        let moved = target.withCString { targetCString in
            quarantine.withCString { quarantineCString in
                renameatx_np(
                    parent.rawValue,
                    targetCString,
                    parent.rawValue,
                    quarantineCString,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard moved == 0 else { throw syscallError("renameatx_np quarantine", path.absolutePath) }

        do {
            let quarantined = try fingerprintEntry(
                name: quarantine,
                parentFD: parent.rawValue,
                path: quarantinePath
            )
            guard hasSameIdentityAndContents(quarantined, as: expected) else {
                throw WorkspaceFileSystemError.changedSincePreparation(path.absolutePath)
            }
            let flags = expected.kind == .directory ? AT_REMOVEDIR : 0
            let result = quarantine.withCString { unlinkat(parent.rawValue, $0, flags) }
            guard result == 0 else {
                if errno == ENOTEMPTY {
                    throw WorkspaceFileSystemError.nonEmptyDirectory(path.absolutePath)
                }
                throw syscallError("unlinkat", path.absolutePath)
            }
            _ = fsync(parent.rawValue)
        } catch {
            _ = quarantine.withCString { quarantineCString in
                target.withCString { targetCString in
                    renameatx_np(
                        parent.rawValue,
                        quarantineCString,
                        parent.rawValue,
                        targetCString,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            throw error
        }
    }

    func createDirectory(_ path: RelativeWorkspacePath, root: OwnedFileDescriptor) throws {
        let parent = try openParent(of: path, root: root)
        defer { parent.close() }
        let result = path.components.last!.withCString {
            mkdirat(parent.rawValue, $0, mode_t(S_IRWXU))
        }
        guard result == 0 else {
            if errno == EEXIST { throw WorkspaceFileSystemError.alreadyExists(path.absolutePath) }
            throw syscallError("mkdirat", path.absolutePath)
        }
        _ = fsync(parent.rawValue)
    }
}

// MARK: - Low-level helpers

private extension WorkspaceFileSystem {
    func openRegularFile(name: String, parentFD: Int32, path: String) throws -> OwnedFileDescriptor {
        let fd = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            if errno == ENOENT { throw WorkspaceFileSystemError.notFound(path) }
            if errno == ELOOP { throw WorkspaceFileSystemError.unsupportedFileType(path) }
            throw syscallError("openat file", path)
        }
        let file = OwnedFileDescriptor(fd)
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = syscallError("fstat file", path)
            file.close()
            throw error
        }
        guard isRegular(info.st_mode) else {
            file.close()
            throw WorkspaceFileSystemError.notRegularFile(path)
        }
        guard info.st_nlink == 1 else {
            file.close()
            throw WorkspaceFileSystemError.hardLinkRejected(path)
        }
        return file
    }

    func requireRegularEntry(_ fingerprint: WorkspaceFileFingerprint, path: String) throws {
        guard fingerprint.kind == .regularFile else {
            throw WorkspaceFileSystemError.notRegularFile(path)
        }
    }

    func requireSupportedEntry(_ fingerprint: WorkspaceFileFingerprint, path: String) throws {
        guard fingerprint.kind == .regularFile || fingerprint.kind == .directory else {
            throw WorkspaceFileSystemError.unsupportedFileType(path)
        }
    }

    func requireEmptyDirectory(
        _ path: RelativeWorkspacePath,
        root: OwnedFileDescriptor
    ) throws {
        let parent = try openParent(of: path, root: root)
        defer { parent.close() }
        let fd = path.components.last!.withCString {
            openat(parent.rawValue, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            if errno == ELOOP { throw WorkspaceFileSystemError.unsupportedFileType(path.absolutePath) }
            throw syscallError("openat directory", path.absolutePath)
        }
        guard let stream = fdopendir(fd) else {
            Darwin.close(fd)
            throw syscallError("fdopendir", path.absolutePath)
        }
        defer { closedir(stream) }

        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                throw WorkspaceFileSystemError.nonEmptyDirectory(path.absolutePath)
            }
            errno = 0
        }
        if errno != 0 { throw syscallError("readdir", path.absolutePath) }
    }

    func readAll(_ fd: Int32, path: String) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw syscallError("fstat", path) }
        try requireSizeWithinLimit(Int64(info.st_size), path: path)
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw syscallError("lseek", path) }
        var output = Data()
        output.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, $0.count)
            }
            if count == 0 { return output }
            if count < 0 {
                if errno == EINTR { continue }
                throw syscallError("read", path)
            }
            let nextCount = Int64(output.count) + Int64(count)
            try requireSizeWithinLimit(nextCount, path: path)
            output.append(buffer, count: count)
        }
    }

    func requireSizeWithinLimit(_ byteCount: Int64, path: String) throws {
        guard byteCount <= Self.maximumFileBytes else {
            throw WorkspaceFileSystemError.fileTooLarge(
                path: path,
                byteCount: byteCount,
                limit: Self.maximumFileBytes
            )
        }
    }

    func writeAll(_ data: Data, fd: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fd,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw syscallError("write", path)
                }
                if written == 0 {
                    throw WorkspaceFileSystemError.systemCall(
                        operation: "write returned zero",
                        path: path,
                        code: EIO
                    )
                }
                offset += written
            }
        }
    }

    func parentAbsolutePath(of path: RelativeWorkspacePath) -> String {
        URL(fileURLWithPath: path.absolutePath).deletingLastPathComponent().path
    }

    func syscallError(_ operation: String, _ path: String) -> WorkspaceFileSystemError {
        WorkspaceFileSystemError.systemCall(operation: operation, path: path, code: errno)
    }

    func preview(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: "\\n")
        if singleLine.count <= 80 { return "\"\(singleLine)\"" }
        return "\"\(singleLine.prefix(77))...\""
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isRegular(_ mode: mode_t) -> Bool { (mode & S_IFMT) == S_IFREG }
    func isDirectory(_ mode: mode_t) -> Bool { (mode & S_IFMT) == S_IFDIR }
    func isSymbolicLink(_ mode: mode_t) -> Bool { (mode & S_IFMT) == S_IFLNK }
}

private extension String {
    func nonOverlappingOccurrenceCount(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var cursor = startIndex
        while let range = range(of: needle, range: cursor..<endIndex) {
            count += 1
            cursor = range.upperBound
        }
        return count
    }
}
