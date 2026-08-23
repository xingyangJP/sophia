import Darwin
import XCTest
@testable import Sophia

final class WorkspaceFileSystemTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var outside: URL!
    private var fileSystem: WorkspaceFileSystem!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceFileSystemTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("workspace", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write("let value = 1\n", to: root.appendingPathComponent("Sources/App.swift"))
        try write("outside unchanged", to: outside.appendingPathComponent("victim.txt"))
        fileSystem = WorkspaceFileSystem(
            folder: try SecurityScopedFolder.unscoped(directoryURL: root)
        )
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
        try super.tearDownWithError()
    }

    func testCreateReplaceCopyMoveDeleteAndDirectoryLifecycle() throws {
        let createDirectory = try fileSystem.prepare(.createDirectory(path: "Generated"))
        XCTAssertEqual(createDirectory.resolvedPaths, [root.appendingPathComponent("Generated").path])
        _ = try fileSystem.execute(createDirectory)

        let create = try fileSystem.prepare(
            .createFile(path: "Generated/New.swift", contents: "let answer = 42\n")
        )
        XCTAssertTrue(create.summary.contains("SHA-256"))
        _ = try fileSystem.execute(create)
        XCTAssertEqual(try read(root.appendingPathComponent("Generated/New.swift")), "let answer = 42\n")

        let replace = try fileSystem.prepare(
            .replaceText(path: "Generated/New.swift", oldText: "42", newText: "43")
        )
        XCTAssertTrue(replace.summary.contains("1箇所"))
        _ = try fileSystem.execute(replace)
        XCTAssertEqual(try read(root.appendingPathComponent("Generated/New.swift")), "let answer = 43\n")

        _ = try fileSystem.execute(
            fileSystem.prepare(
                .copyFile(source: "Generated/New.swift", destination: "Generated/Copy.swift")
            )
        )
        XCTAssertEqual(try read(root.appendingPathComponent("Generated/Copy.swift")), "let answer = 43\n")

        _ = try fileSystem.execute(
            fileSystem.prepare(
                .movePath(source: "Generated/Copy.swift", destination: "Sources/Moved.swift")
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Generated/Copy.swift").path))
        XCTAssertEqual(try read(root.appendingPathComponent("Sources/Moved.swift")), "let answer = 43\n")

        _ = try fileSystem.execute(fileSystem.prepare(.deletePath(path: "Sources/Moved.swift")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Moved.swift").path))

        _ = try fileSystem.execute(fileSystem.prepare(.deletePath(path: "Generated/New.swift")))
        _ = try fileSystem.execute(fileSystem.prepare(.deletePath(path: "Generated")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Generated").path))
    }

    func testPrepareDoesNotMutateWorkspace() throws {
        _ = try fileSystem.prepare(.createFile(path: "prepared.txt", contents: "not yet"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("prepared.txt").path))
    }

    func testPlanIsSingleUse() throws {
        let plan = try fileSystem.prepare(.createFile(path: "once.txt", contents: "one"))
        _ = try fileSystem.execute(plan)

        XCTAssertThrowsError(try fileSystem.execute(plan)) { error in
            XCTAssertEqual(error as? WorkspaceFileSystemError, .planAlreadyExecuted)
        }
        XCTAssertEqual(try read(root.appendingPathComponent("once.txt")), "one")
    }

    func testInvalidPathsAndGitMetadataAreRejected() throws {
        let invalid = ["", "/tmp/x", "~/x", "a//b", "a/./b", "a/../b", "a/", "a\0/b"]
        for path in invalid {
            XCTAssertThrowsError(try fileSystem.prepare(.createFile(path: path, contents: "x")), path)
        }
        for path in [".git/config", ".GIT/HEAD"] {
            XCTAssertThrowsError(try fileSystem.prepare(.createFile(path: path, contents: "x"))) { error in
                guard case .gitMetadataRejected? = error as? WorkspaceFileSystemError else {
                    return XCTFail("expected .git rejection for \(path), got \(error)")
                }
            }
        }
    }

    func testExistingDestinationsAreNeverOverwritten() throws {
        try write("keep", to: root.appendingPathComponent("existing.txt"))

        for change in [
            WorkspaceChange.createFile(path: "existing.txt", contents: "replace"),
            .copyFile(source: "Sources/App.swift", destination: "existing.txt"),
            .movePath(source: "Sources/App.swift", destination: "existing.txt"),
            .createDirectory(path: "Sources")
        ] {
            XCTAssertThrowsError(try fileSystem.prepare(change))
        }
        XCTAssertEqual(try read(root.appendingPathComponent("existing.txt")), "keep")
        XCTAssertEqual(try read(root.appendingPathComponent("Sources/App.swift")), "let value = 1\n")
    }

    func testReplaceRequiresExactlyOneExactOccurrence() throws {
        try write("same same", to: root.appendingPathComponent("twice.txt"))

        XCTAssertThrowsError(
            try fileSystem.prepare(.replaceText(path: "twice.txt", oldText: "same", newText: "new"))
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceFileSystemError,
                .replacementMustOccurExactlyOnce(
                    path: self.root.appendingPathComponent("twice.txt").path,
                    occurrences: 2
                )
            )
        }
    }

    func testReplacePreservesPermissionsAndExtendedAttributes() throws {
        let file = root.appendingPathComponent("Sources/App.swift")
        let oldModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755, .modificationDate: oldModificationDate],
            ofItemAtPath: file.path
        )
        let attributeName = "com.xerographix.sophia-test"
        let attributeValue = Data("kept".utf8)
        let setResult = attributeValue.withUnsafeBytes { bytes in
            setxattr(file.path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
        }
        XCTAssertEqual(setResult, 0)

        let plan = try fileSystem.prepare(
            .replaceText(path: "Sources/App.swift", oldText: "1", newText: "2")
        )
        _ = try fileSystem.execute(plan)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertGreaterThan(
            try XCTUnwrap(attributes[.modificationDate] as? Date),
            oldModificationDate
        )
        let attributeSize = getxattr(file.path, attributeName, nil, 0, 0, 0)
        XCTAssertEqual(attributeSize, attributeValue.count)
        var copiedAttribute = Data(count: max(0, attributeSize))
        let copiedSize = copiedAttribute.withUnsafeMutableBytes { bytes in
            getxattr(file.path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
        }
        XCTAssertEqual(copiedSize, attributeValue.count)
        XCTAssertEqual(copiedAttribute, attributeValue)
        XCTAssertEqual(try read(file), "let value = 2\n")
    }

    func testOversizedSparseFileIsRejectedBeforeReading() throws {
        let file = root.appendingPathComponent("oversized.txt")
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(WorkspaceFileSystem.maximumFileBytes + 1)), 0)
        XCTAssertEqual(close(fd), 0)

        XCTAssertThrowsError(
            try fileSystem.prepare(.replaceText(path: "oversized.txt", oldText: "x", newText: "y"))
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceFileSystemError,
                .fileTooLarge(
                    path: file.path,
                    byteCount: WorkspaceFileSystem.maximumFileBytes + 1,
                    limit: WorkspaceFileSystem.maximumFileBytes
                )
            )
        }
    }

    func testChangedFileAndAppearingDestinationFailClosed() throws {
        let replace = try fileSystem.prepare(
            .replaceText(path: "Sources/App.swift", oldText: "1", newText: "2")
        )
        try write("changed externally\n", to: root.appendingPathComponent("Sources/App.swift"))
        XCTAssertThrowsError(try fileSystem.execute(replace)) { error in
            guard case .changedSincePreparation? = error as? WorkspaceFileSystemError else {
                return XCTFail("expected changed snapshot, got \(error)")
            }
        }
        XCTAssertEqual(try read(root.appendingPathComponent("Sources/App.swift")), "changed externally\n")

        let create = try fileSystem.prepare(.createFile(path: "race.txt", contents: "planned"))
        try write("appeared", to: root.appendingPathComponent("race.txt"))
        XCTAssertThrowsError(try fileSystem.execute(create))
        XCTAssertEqual(try read(root.appendingPathComponent("race.txt")), "appeared")
    }

    func testSymlinkFIFOAndHardLinkAreRejected() throws {
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"),
            withDestinationURL: outside.appendingPathComponent("victim.txt")
        )
        let fifoPath = root.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifoPath, mode_t(S_IRUSR | S_IWUSR)), 0)
        let hardLink = root.appendingPathComponent("hard.swift").path
        XCTAssertEqual(link(root.appendingPathComponent("Sources/App.swift").path, hardLink), 0)

        for path in ["link.txt", "pipe", "hard.swift", "Sources/App.swift"] {
            XCTAssertThrowsError(try fileSystem.prepare(.deletePath(path: path)), path)
        }
        XCTAssertEqual(try read(outside.appendingPathComponent("victim.txt")), "outside unchanged")
    }

    func testNonEmptyDirectoryDeletionIsRejectedWithoutMutation() throws {
        XCTAssertThrowsError(try fileSystem.prepare(.deletePath(path: "Sources"))) { error in
            guard case .nonEmptyDirectory? = error as? WorkspaceFileSystemError else {
                return XCTFail("expected non-empty rejection, got \(error)")
            }
        }
        XCTAssertEqual(try read(root.appendingPathComponent("Sources/App.swift")), "let value = 1\n")
    }

    func testReplacingIntermediateDirectoryWithSymlinkCannotEscapeRoot() throws {
        let plan = try fileSystem.prepare(
            .replaceText(path: "Sources/App.swift", oldText: "1", newText: "9")
        )
        let originalSources = root.appendingPathComponent("Sources-original", isDirectory: true)
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("Sources", isDirectory: true),
            to: originalSources
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Sources"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try fileSystem.execute(plan))
        XCTAssertEqual(try read(outside.appendingPathComponent("victim.txt")), "outside unchanged")
        XCTAssertEqual(try read(originalSources.appendingPathComponent("App.swift")), "let value = 1\n")
    }

    func testMovingDirectoryKeepsItsContents() throws {
        _ = try fileSystem.execute(
            fileSystem.prepare(.movePath(source: "Sources", destination: "RenamedSources"))
        )

        XCTAssertEqual(try read(root.appendingPathComponent("RenamedSources/App.swift")), "let value = 1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path))
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
