import Foundation
import XCTest

@testable import Sophia

final class WorkspaceGitTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testStatusAndBranchListAreReadOnly() async throws {
        let repository = try makeRepository()
        try git(["branch", "topic"], in: repository)
        let before = try git(["status", "--porcelain=v1", "--branch"], in: repository)
        let index = repository.appendingPathComponent(".git/index")
        let oldIndexDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldIndexDate], ofItemAtPath: index.path)
        let indexDateBefore = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        )

        let workspaceGit = try WorkspaceGit(workspaceURL: repository)
        let status = try await workspaceGit.status()
        let branches = try await workspaceGit.branches()

        XCTAssertEqual(status.repositoryPath, repository.resolvingSymlinksInPath().path)
        XCTAssertEqual(status.currentBranch, "main")
        XCTAssertTrue(status.headOID.count == 40 || status.headOID.count == 64)
        XCTAssertEqual(branches.map(\.name), ["main", "topic"])
        XCTAssertEqual(branches.filter(\.isCurrent).map(\.name), ["main"])
        XCTAssertEqual(try git(["status", "--porcelain=v1", "--branch"], in: repository), before)
        let indexDateAfter = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(indexDateAfter, indexDateBefore)
    }

    func testCreatePlanContainsApprovalFactsAndCreatesWithoutSwitching() async throws {
        let repository = try makeRepository()
        let workspaceGit = try WorkspaceGit(workspaceURL: repository)
        let plan = try await workspaceGit.prepareCreateBranch(named: "feature/safe-create")

        XCTAssertEqual(plan.operation, .createBranch)
        XCTAssertEqual(plan.repositoryPath, repository.resolvingSymlinksInPath().path)
        XCTAssertEqual(plan.currentBranch, "main")
        XCTAssertEqual(plan.branchName, "feature/safe-create")
        XCTAssertNil(plan.targetBranchOID)

        let result = try await workspaceGit.execute(plan)
        XCTAssertEqual(result.currentBranchAfter, "main")
        XCTAssertEqual(result.headOIDBefore, result.headOIDAfter)
        XCTAssertEqual(
            try git(["rev-parse", "refs/heads/feature/safe-create"], in: repository),
            plan.headOID + "\n"
        )
        XCTAssertEqual(try git(["branch", "--show-current"], in: repository), "main\n")
    }

    func testSwitchPlanBindsTargetOIDAndHooksAreDisabled() async throws {
        let repository = try makeRepository()
        try git(["branch", "topic"], in: repository)
        let marker = repository.appendingPathComponent("hook-ran")
        let hook = repository.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let workspaceGit = try WorkspaceGit(workspaceURL: repository)
        let plan = try await workspaceGit.prepareSwitchBranch(to: "topic")
        XCTAssertEqual(plan.operation, .switchBranch)
        XCTAssertEqual(plan.currentBranch, "main")
        XCTAssertEqual(plan.targetBranchOID, plan.headOID)

        let result = try await workspaceGit.execute(plan)
        XCTAssertEqual(result.currentBranchAfter, "topic")
        XCTAssertEqual(try git(["branch", "--show-current"], in: repository), "topic\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testStatusRejectsRepositoryFsmonitorWithoutLaunchingIt() async throws {
        let repository = try makeRepository()
        let marker = repository.appendingPathComponent("fsmonitor-ran")
        let script = repository.appendingPathComponent("fsmonitor.sh")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\nexit 0\n".write(
            to: script,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try git(["config", "core.fsmonitor", script.path], in: repository)
        let workspaceGit = try WorkspaceGit(workspaceURL: repository)

        await assertWorkspaceGitError(.unsafeRepositoryConfiguration("core.fsmonitor")) {
            _ = try await workspaceGit.status()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSwitchRejectsRepositorySmudgeFilterWithoutLaunchingIt() async throws {
        let repository = try makeRepository()
        try git(["branch", "topic"], in: repository)
        let marker = repository.appendingPathComponent("smudge-ran")
        let script = repository.appendingPathComponent("smudge.sh")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\ncat\n".write(
            to: script,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try git(["config", "filter.hostile.smudge", script.path], in: repository)
        let workspaceGit = try WorkspaceGit(workspaceURL: repository)

        await assertWorkspaceGitError(.unsafeRepositoryConfiguration("filter.hostile.smudge")) {
            _ = try await workspaceGit.prepareSwitchBranch(to: "topic")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try git(["branch", "--show-current"], in: repository), "main\n")
    }

    func testSwitchRejectsWorktreeSmudgeFilterWithoutLaunchingIt() async throws {
        let repository = try makeRepository()
        try git(["branch", "topic"], in: repository)
        let marker = repository.appendingPathComponent("worktree-smudge-ran")
        let script = repository.appendingPathComponent("worktree-smudge.sh")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\ncat\n".write(
            to: script,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try git(["config", "extensions.worktreeConfig", "true"], in: repository)
        try git(["config", "--worktree", "filter.hostile.smudge", script.path], in: repository)
        let workspaceGit = try WorkspaceGit(workspaceURL: repository)

        await assertWorkspaceGitError(.unsafeRepositoryConfiguration("filter.hostile.smudge")) {
            _ = try await workspaceGit.prepareSwitchBranch(to: "topic")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try git(["branch", "--show-current"], in: repository), "main\n")
    }

    func testPlanIsOneShot() async throws {
        let repository = try makeRepository()
        let workspaceGit = try WorkspaceGit(workspaceURL: repository)
        let plan = try await workspaceGit.prepareCreateBranch(named: "feature/one-shot")
        _ = try await workspaceGit.execute(plan)

        await assertWorkspaceGitError(.invalidOrConsumedPlan) {
            _ = try await workspaceGit.execute(plan)
        }
    }

    func testNonRepositoryAndNestedDirectoryAreRejected() throws {
        let nonRepository = makeTemporaryDirectory(named: "not-repository")
        XCTAssertThrowsError(try WorkspaceGit(workspaceURL: nonRepository)) { error in
            XCTAssertEqual(error as? WorkspaceGitError, .notRepositoryRoot(nonRepository.path))
        }

        let repository = try makeRepository()
        let nested = repository.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertThrowsError(try WorkspaceGit(workspaceURL: nested)) { error in
            XCTAssertEqual(error as? WorkspaceGitError, .notRepositoryRoot(nested.path))
        }
    }

    func testSeparateGitDirectoryIsRejected() throws {
        let base = makeTemporaryDirectory(named: "separate-git")
        let repository = base.appendingPathComponent("workspace", isDirectory: true)
        let gitDirectory = base.appendingPathComponent("git-storage", isDirectory: true)
        try git(
            ["init", "--separate-git-dir", gitDirectory.path, repository.path],
            in: base
        )

        XCTAssertThrowsError(try WorkspaceGit(workspaceURL: repository)) { error in
            guard case .separateGitDirectory = error as? WorkspaceGitError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInvalidAndOptionLikeBranchNamesFailClosed() async throws {
        let repository = try makeRepository()
        let workspaceGit = try WorkspaceGit(workspaceURL: repository)
        let marker = repository.appendingPathComponent("argument-injection")
        let names = ["", "--help", "../outside", "topic;touch-argument-injection", "topic name"]

        for name in names {
            await assertWorkspaceGitError(.invalidBranchName(name)) {
                _ = try await workspaceGit.prepareCreateBranch(named: name)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try git(["branch", "--format=%(refname:short)"], in: repository), "main\n")
    }

    func testExistingAndCaseCollidingBranchesAreRejected() async throws {
        let repository = try makeRepository()
        try git(["branch", "Feature/One"], in: repository)
        let workspaceGit = try WorkspaceGit(workspaceURL: repository)

        await assertWorkspaceGitError(.branchAlreadyExists("Feature/One")) {
            _ = try await workspaceGit.prepareCreateBranch(named: "Feature/One")
        }
        await assertWorkspaceGitError(.branchNameCollision("feature/one")) {
            _ = try await workspaceGit.prepareCreateBranch(named: "feature/one")
        }
    }

    func testMissingSwitchTargetIsRejected() async throws {
        let repository = try makeRepository()
        let workspaceGit = try WorkspaceGit(workspaceURL: repository)
        await assertWorkspaceGitError(.branchNotFound("missing")) {
            _ = try await workspaceGit.prepareSwitchBranch(to: "missing")
        }
    }

    func testHeadChangeAfterApprovalPreventsCreate() async throws {
        let repository = try makeRepository()
        let workspaceGit = try WorkspaceGit(workspaceURL: repository)
        let plan = try await workspaceGit.prepareCreateBranch(named: "feature/stale-head")

        try commit("second", file: "second.txt", in: repository)

        await assertWorkspaceGitError(.stateChangedSinceApproval) {
            _ = try await workspaceGit.execute(plan)
        }
        XCTAssertNotEqual(try gitStatus(["show-ref", "--verify", "refs/heads/feature/stale-head"], in: repository), 0)
    }

    func testWorktreeChangeAfterApprovalPreventsSwitch() async throws {
        let repository = try makeRepository()
        try git(["branch", "topic"], in: repository)
        let workspaceGit = try WorkspaceGit(workspaceURL: repository)
        let plan = try await workspaceGit.prepareSwitchBranch(to: "topic")
        try "changed after approval".write(
            to: repository.appendingPathComponent("new-untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        await assertWorkspaceGitError(.stateChangedSinceApproval) {
            _ = try await workspaceGit.execute(plan)
        }
        XCTAssertEqual(try git(["branch", "--show-current"], in: repository), "main\n")
    }

    func testTargetBranchMoveAfterApprovalPreventsSwitch() async throws {
        let repository = try makeRepository()
        try git(["branch", "source"], in: repository)
        try git(["switch", "source"], in: repository)
        try commit("second", file: "second.txt", in: repository)
        let movedTargetOID = try git(["rev-parse", "HEAD"], in: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["switch", "main"], in: repository)
        try git(["branch", "topic"], in: repository)
        let workspaceGit = try WorkspaceGit(workspaceURL: repository)
        let plan = try await workspaceGit.prepareSwitchBranch(to: "topic")

        try git(["branch", "--force", "topic", movedTargetOID], in: repository)

        await assertWorkspaceGitError(.stateChangedSinceApproval) {
            _ = try await workspaceGit.execute(plan)
        }
        XCTAssertEqual(try git(["branch", "--show-current"], in: repository), "main\n")
    }

    private func makeRepository() throws -> URL {
        let repository = makeTemporaryDirectory(named: "repository")
        try git(["init", "--initial-branch=main"], in: repository)
        try commit("initial", file: "README.md", in: repository)
        return repository
    }

    private func makeTemporaryDirectory(named name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SophiaWorkspaceGitTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func commit(_ content: String, file: String, in repository: URL) throws {
        try content.write(
            to: repository.appendingPathComponent(file),
            atomically: true,
            encoding: .utf8
        )
        try git(["add", "--", file], in: repository)
        try git(
            [
                "-c", "user.name=Sophia Tests",
                "-c", "user.email=sophia-tests@example.invalid",
                "-c", "core.hooksPath=/dev/null",
                "commit", "--quiet", "--message", content
            ],
            in: repository
        )
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let result = try runGit(arguments, in: directory)
        guard result.status == 0 else {
            throw NSError(
                domain: "WorkspaceGitTests",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }
        return result.stdout
    }

    private func gitStatus(_ arguments: [String], in directory: URL) throws -> Int32 {
        try runGit(arguments, in: directory).status
    }

    private func runGit(
        _ arguments: [String],
        in directory: URL
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try XCTUnwrap(WorkspaceGit.gitExecutableURL)
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/var/empty",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "PAGER": "cat",
            "GIT_EDITOR": "/usr/bin/false",
            "GIT_SEQUENCE_EDITOR": "/usr/bin/false"
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout, as: UTF8.self),
            String(decoding: stderr, as: UTF8.self)
        )
    }

    private func assertWorkspaceGitError(
        _ expected: WorkspaceGitError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected error: \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? WorkspaceGitError, expected, file: file, line: line)
        }
    }
}
