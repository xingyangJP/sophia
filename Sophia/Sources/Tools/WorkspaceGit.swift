import Foundation

/// The only Git mutations Sophia may prepare. Deliberately keep destructive and
/// remote operations out of this type rather than relying on callers to avoid them.
enum WorkspaceGitMutation: String, Sendable, Equatable {
    case createBranch
    case switchBranch
}

struct WorkspaceGitStatus: Sendable, Equatable {
    let repositoryPath: String
    let headOID: String
    let currentBranch: String?
    let porcelain: String
}

struct WorkspaceGitBranch: Sendable, Equatable {
    let name: String
    let oid: String
    let isCurrent: Bool
}

/// A one-shot capability describing exactly what a person is being asked to approve.
/// Instances can only be created by `WorkspaceGit` and are consumed on execution.
struct WorkspaceGitMutationPlan: Sendable, Equatable {
    let id: UUID
    let operation: WorkspaceGitMutation
    let repositoryPath: String
    let headOID: String
    let branchName: String
    let currentBranch: String
    let targetBranchOID: String?
    let repositoryState: String

    fileprivate init(
        id: UUID,
        operation: WorkspaceGitMutation,
        repositoryPath: String,
        headOID: String,
        branchName: String,
        currentBranch: String,
        targetBranchOID: String?,
        repositoryState: String
    ) {
        self.id = id
        self.operation = operation
        self.repositoryPath = repositoryPath
        self.headOID = headOID
        self.branchName = branchName
        self.currentBranch = currentBranch
        self.targetBranchOID = targetBranchOID
        self.repositoryState = repositoryState
    }
}

struct WorkspaceGitExecutionResult: Sendable, Equatable {
    let operation: WorkspaceGitMutation
    let repositoryPath: String
    let headOIDBefore: String
    let headOIDAfter: String
    let branchName: String
    let currentBranchAfter: String
}

enum WorkspaceGitError: Error, Sendable, Equatable, LocalizedError {
    case workspaceIsNotDirectory(String)
    case notRepositoryRoot(String)
    case separateGitDirectory(String)
    case repositoryIdentityChanged
    case repositoryHasNoCommit
    case detachedHead
    case invalidBranchName(String)
    case branchAlreadyExists(String)
    case branchNotFound(String)
    case branchNameCollision(String)
    case alreadyOnBranch(String)
    case stateChangedSinceApproval
    case invalidOrConsumedPlan
    case unsafeRepositoryConfiguration(String)
    case gitFailed(operation: String, status: Int32, detail: String)
    case invalidGitOutput(String)

    var errorDescription: String? {
        switch self {
        case .workspaceIsNotDirectory:
            "選択したワークスペースはディレクトリではありません。"
        case .notRepositoryRoot:
            "選択したワークスペース自身が Git worktree のルートではありません。"
        case .separateGitDirectory:
            "外部または共有の Git ディレクトリを使うワークスペースは操作できません。"
        case .repositoryIdentityChanged:
            "承認後にリポジトリの実体が変わったため、操作を中止しました。"
        case .repositoryHasNoCommit:
            "HEAD コミットが無いリポジトリではブランチ操作できません。"
        case .detachedHead:
            "detached HEAD の状態ではブランチ操作できません。"
        case .invalidBranchName(let name):
            "安全に扱えないブランチ名です: \(name)"
        case .branchAlreadyExists(let name):
            "ブランチは既に存在します: \(name)"
        case .branchNotFound(let name):
            "ローカルブランチが見つかりません: \(name)"
        case .branchNameCollision(let name):
            "大文字小文字だけが異なるブランチが存在します: \(name)"
        case .alreadyOnBranch(let name):
            "既にそのブランチにいます: \(name)"
        case .stateChangedSinceApproval:
            "承認後に HEAD または作業ツリーの状態が変わったため、操作を中止しました。"
        case .invalidOrConsumedPlan:
            "承認プランが無効か、既に使用されています。"
        case .unsafeRepositoryConfiguration(let key):
            "外部プロセスを起動しうる Git 設定があるため操作できません: \(key)"
        case .gitFailed(let operation, let status, let detail):
            "Git 操作に失敗しました (\(operation), status=\(status)): \(detail)"
        case .invalidGitOutput(let operation):
            "Git の応答を安全に解釈できませんでした: \(operation)"
        }
    }
}

/// A narrow, serialized Git boundary for one user-selected workspace.
///
/// There is no arbitrary command entry point. Every Git invocation below uses the
/// absolute executable path and a source-defined argument array.
actor WorkspaceGit {
    /// `/usr/bin/git` is an `xcrun` shim and cannot resolve a developer tool
    /// from an App Sandbox. Prefer the real binaries installed by Command Line
    /// Tools or Xcode. A bundled helper can be added later without changing the
    /// command boundary.
    nonisolated static var gitExecutableURL: URL? {
        let candidates = [
            Bundle.main.url(forAuxiliaryExecutable: "git"),
            URL(fileURLWithPath: "/Library/Developer/CommandLineTools/usr/bin/git"),
            URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private struct FileIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct RepositorySnapshot: Sendable, Equatable {
        let headOID: String
        let currentBranch: String?
        let porcelain: String
    }

    private struct PreparedMutation: Sendable, Equatable {
        let plan: WorkspaceGitMutationPlan
        let rootIdentity: FileIdentity
        let gitDirectoryIdentity: FileIdentity
    }

    private struct GitResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private let repositoryURL: URL
    private let repositoryPath: String
    private let rootIdentity: FileIdentity
    private let gitDirectoryIdentity: FileIdentity
    private var prepared: [UUID: PreparedMutation] = [:]

    init(workspaceURL: URL) throws {
        let repositoryURL = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        guard repositoryURL.isFileURL,
              try Self.isPlainDirectory(repositoryURL)
        else {
            throw WorkspaceGitError.workspaceIsNotDirectory(workspaceURL.path)
        }

        let verified = try Self.verifyRepositoryRoot(repositoryURL)
        self.repositoryURL = repositoryURL
        repositoryPath = repositoryURL.path
        rootIdentity = verified.rootIdentity
        gitDirectoryIdentity = verified.gitDirectoryIdentity
    }

    func status() throws -> WorkspaceGitStatus {
        let snapshot = try inspectRepository()
        return WorkspaceGitStatus(
            repositoryPath: repositoryPath,
            headOID: snapshot.headOID,
            currentBranch: snapshot.currentBranch,
            porcelain: snapshot.porcelain
        )
    }

    func branches() throws -> [WorkspaceGitBranch] {
        _ = try inspectRepository()
        let output = try requireSuccess(
            Self.runGit(
                in: repositoryURL,
                arguments: [
                    "for-each-ref",
                    "--format=%(refname:short)%00%(objectname)%00%(HEAD)",
                    "refs/heads/"
                ]
            ),
            operation: "list branches"
        )

        if output.isEmpty { return [] }
        return try output.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  !fields[0].isEmpty,
                  Self.isFullOID(String(fields[1]))
            else {
                throw WorkspaceGitError.invalidGitOutput("list branches")
            }
            return WorkspaceGitBranch(
                name: String(fields[0]),
                oid: String(fields[1]),
                isCurrent: fields[2].trimmingCharacters(in: .whitespaces) == "*"
            )
        }
    }

    func prepareCreateBranch(named branchName: String) throws -> WorkspaceGitMutationPlan {
        try validateBranchName(branchName)
        let snapshot = try inspectRepository()
        let currentBranch = try requireCurrentBranch(snapshot)
        try requireBranchAbsent(branchName)

        return storePlan(
            operation: .createBranch,
            snapshot: snapshot,
            branchName: branchName,
            currentBranch: currentBranch,
            targetBranchOID: nil
        )
    }

    func prepareSwitchBranch(to branchName: String) throws -> WorkspaceGitMutationPlan {
        try validateBranchName(branchName)
        let snapshot = try inspectRepository()
        let currentBranch = try requireCurrentBranch(snapshot)
        guard currentBranch != branchName else {
            throw WorkspaceGitError.alreadyOnBranch(branchName)
        }
        let targetOID = try requireBranch(branchName)

        return storePlan(
            operation: .switchBranch,
            snapshot: snapshot,
            branchName: branchName,
            currentBranch: currentBranch,
            targetBranchOID: targetOID
        )
    }

    func execute(_ plan: WorkspaceGitMutationPlan) throws -> WorkspaceGitExecutionResult {
        guard let authorized = prepared.removeValue(forKey: plan.id),
              authorized.plan == plan
        else {
            throw WorkspaceGitError.invalidOrConsumedPlan
        }

        let snapshot = try inspectRepository()
        guard rootIdentity == authorized.rootIdentity,
              gitDirectoryIdentity == authorized.gitDirectoryIdentity,
              snapshot.headOID == plan.headOID,
              snapshot.currentBranch == plan.currentBranch,
              snapshot.porcelain == plan.repositoryState
        else {
            throw WorkspaceGitError.stateChangedSinceApproval
        }

        switch plan.operation {
        case .createBranch:
            try requireBranchAbsent(plan.branchName)
            _ = try requireSuccess(
                Self.runGit(
                    in: repositoryURL,
                    arguments: ["branch", "--no-track", "--", plan.branchName, plan.headOID]
                ),
                operation: "create branch"
            )
            let createdOID = try requireBranch(plan.branchName)
            guard createdOID == plan.headOID else {
                throw WorkspaceGitError.invalidGitOutput("verify created branch")
            }

        case .switchBranch:
            guard let approvedTargetOID = plan.targetBranchOID,
                  try requireBranch(plan.branchName) == approvedTargetOID
            else {
                throw WorkspaceGitError.stateChangedSinceApproval
            }
            try requireNoExternalCommandConfiguration()
            _ = try requireSuccess(
                Self.runGit(
                    in: repositoryURL,
                    arguments: ["switch", "--no-guess", "--", plan.branchName]
                ),
                operation: "switch branch"
            )
        }

        let after = try inspectRepository()
        let currentBranchAfter = try requireCurrentBranch(after)
        switch plan.operation {
        case .createBranch:
            guard after.headOID == plan.headOID,
                  currentBranchAfter == plan.currentBranch
            else {
                throw WorkspaceGitError.invalidGitOutput("verify branch creation")
            }
        case .switchBranch:
            guard after.headOID == plan.targetBranchOID,
                  currentBranchAfter == plan.branchName
            else {
                throw WorkspaceGitError.invalidGitOutput("verify branch switch")
            }
        }

        return WorkspaceGitExecutionResult(
            operation: plan.operation,
            repositoryPath: repositoryPath,
            headOIDBefore: plan.headOID,
            headOIDAfter: after.headOID,
            branchName: plan.branchName,
            currentBranchAfter: currentBranchAfter
        )
    }

    private func storePlan(
        operation: WorkspaceGitMutation,
        snapshot: RepositorySnapshot,
        branchName: String,
        currentBranch: String,
        targetBranchOID: String?
    ) -> WorkspaceGitMutationPlan {
        let plan = WorkspaceGitMutationPlan(
            id: UUID(),
            operation: operation,
            repositoryPath: repositoryPath,
            headOID: snapshot.headOID,
            branchName: branchName,
            currentBranch: currentBranch,
            targetBranchOID: targetBranchOID,
            repositoryState: snapshot.porcelain
        )
        prepared[plan.id] = PreparedMutation(
            plan: plan,
            rootIdentity: rootIdentity,
            gitDirectoryIdentity: gitDirectoryIdentity
        )
        return plan
    }

    private func inspectRepository() throws -> RepositorySnapshot {
        let verified = try Self.verifyRepositoryRoot(repositoryURL)
        guard verified.rootIdentity == rootIdentity,
              verified.gitDirectoryIdentity == gitDirectoryIdentity
        else {
            throw WorkspaceGitError.repositoryIdentityChanged
        }
        try requireNoExternalCommandConfiguration()

        let head = try requireSuccess(
            Self.runGit(in: repositoryURL, arguments: ["rev-parse", "--verify", "HEAD^{commit}"]),
            operation: "read HEAD"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isFullOID(head) else {
            throw WorkspaceGitError.repositoryHasNoCommit
        }

        let branchResult = try Self.runGit(
            in: repositoryURL,
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"]
        )
        let currentBranch: String?
        switch branchResult.status {
        case 0:
            let branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else {
                throw WorkspaceGitError.invalidGitOutput("read current branch")
            }
            currentBranch = branch
        case 1:
            currentBranch = nil
        default:
            throw Self.commandError(branchResult, operation: "read current branch")
        }

        let porcelain = try requireSuccess(
            Self.runGit(
                in: repositoryURL,
                arguments: ["status", "--porcelain=v1", "--branch", "--untracked-files=normal"]
            ),
            operation: "read status"
        )
        return RepositorySnapshot(headOID: head, currentBranch: currentBranch, porcelain: porcelain)
    }

    /// Repository-local config is untrusted input. These keys can make otherwise
    /// fixed Git commands launch executables or import more executable settings.
    private func requireNoExternalCommandConfiguration() throws {
        for scope in ["--local", "--worktree"] {
            let result = try Self.runGit(
                in: repositoryURL,
                arguments: ["config", scope, "--no-includes", "--name-only", "--list"]
            )
            let output = try requireSuccess(result, operation: "inspect \(scope) Git config")
            for key in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
                let normalized = key.lowercased()
                let isFilterCommand = normalized.hasPrefix("filter.")
                    && [".clean", ".smudge", ".process", ".required"].contains {
                        normalized.hasSuffix($0)
                    }
                let isInclude = normalized == "include.path"
                    || (normalized.hasPrefix("includeif.") && normalized.hasSuffix(".path"))
                if normalized == "core.fsmonitor" || isFilterCommand || isInclude {
                    throw WorkspaceGitError.unsafeRepositoryConfiguration(key)
                }
            }
        }
    }

    private func requireCurrentBranch(_ snapshot: RepositorySnapshot) throws -> String {
        guard let branch = snapshot.currentBranch else {
            throw WorkspaceGitError.detachedHead
        }
        return branch
    }

    private func validateBranchName(_ branchName: String) throws {
        guard !branchName.isEmpty,
              branchName.utf8.count <= 255,
              branchName.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil
        else {
            throw WorkspaceGitError.invalidBranchName(branchName)
        }
        let result = try Self.runGit(
            in: repositoryURL,
            arguments: ["check-ref-format", "--branch", branchName]
        )
        guard result.status == 0 else {
            throw WorkspaceGitError.invalidBranchName(branchName)
        }
    }

    private func requireBranchAbsent(_ branchName: String) throws {
        let localBranches = try branches()
        if localBranches.contains(where: { $0.name == branchName }) {
            throw WorkspaceGitError.branchAlreadyExists(branchName)
        }
        if localBranches.contains(where: {
            $0.name.caseInsensitiveCompare(branchName) == .orderedSame
        }) {
            throw WorkspaceGitError.branchNameCollision(branchName)
        }
    }

    private func requireBranch(_ branchName: String) throws -> String {
        guard let oid = try branchOID(branchName) else {
            throw WorkspaceGitError.branchNotFound(branchName)
        }
        return oid
    }

    private func branchOID(_ branchName: String) throws -> String? {
        let result = try Self.runGit(
            in: repositoryURL,
            arguments: ["show-ref", "--verify", "--quiet", "--", "refs/heads/\(branchName)"]
        )
        switch result.status {
        case 0:
            let oid = try requireSuccess(
                Self.runGit(
                    in: repositoryURL,
                    arguments: ["rev-parse", "--verify", "refs/heads/\(branchName)^{commit}"]
                ),
                operation: "read branch"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isFullOID(oid) else {
                throw WorkspaceGitError.invalidGitOutput("read branch")
            }
            return oid
        case 1:
            return nil
        default:
            throw Self.commandError(result, operation: "find branch")
        }
    }

    private func requireSuccess(_ result: GitResult, operation: String) throws -> String {
        guard result.status == 0 else {
            throw Self.commandError(result, operation: operation)
        }
        return result.stdout
    }

    private static func verifyRepositoryRoot(
        _ repositoryURL: URL
    ) throws -> (rootIdentity: FileIdentity, gitDirectoryIdentity: FileIdentity) {
        guard try isPlainDirectory(repositoryURL) else {
            throw WorkspaceGitError.workspaceIsNotDirectory(repositoryURL.path)
        }

        let topLevelResult = try runGit(
            in: repositoryURL,
            arguments: ["rev-parse", "--show-toplevel"]
        )
        guard topLevelResult.status == 0 else {
            throw WorkspaceGitError.notRepositoryRoot(repositoryURL.path)
        }
        let reportedRoot = URL(
            fileURLWithPath: topLevelResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        ).resolvingSymlinksInPath().standardizedFileURL
        guard reportedRoot.path == repositoryURL.path else {
            throw WorkspaceGitError.notRepositoryRoot(repositoryURL.path)
        }

        let localGitDirectory = repositoryURL.appendingPathComponent(".git", isDirectory: true)
        guard try isPlainDirectory(localGitDirectory) else {
            throw WorkspaceGitError.separateGitDirectory(repositoryURL.path)
        }
        let gitDirectoryResult = try runGit(
            in: repositoryURL,
            arguments: ["rev-parse", "--absolute-git-dir"]
        )
        guard gitDirectoryResult.status == 0 else {
            throw commandError(gitDirectoryResult, operation: "locate Git directory")
        }
        let reportedGitDirectory = URL(
            fileURLWithPath: gitDirectoryResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        ).resolvingSymlinksInPath().standardizedFileURL
        guard reportedGitDirectory.path == localGitDirectory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw WorkspaceGitError.separateGitDirectory(repositoryURL.path)
        }

        return (
            try fileIdentity(repositoryURL),
            try fileIdentity(localGitDirectory)
        )
    }

    private static func isPlainDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func fileIdentity(_ url: URL) throws -> FileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber
        else {
            throw WorkspaceGitError.repositoryIdentityChanged
        }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    private static func isFullOID(_ value: String) -> Bool {
        guard value.count == 40 || value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private static func runGit(in directory: URL, arguments: [String]) throws -> GitResult {
        guard let executableURL = gitExecutableURL else {
            throw WorkspaceGitError.gitFailed(
                operation: arguments.first ?? "git",
                status: -1,
                detail: "Git executable was not found. Install Xcode Command Line Tools."
            )
        }
        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = directory
        process.arguments = ["--no-optional-locks"] + arguments
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/var/empty",
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_COUNT": "4",
            "GIT_CONFIG_KEY_0": "core.hooksPath",
            "GIT_CONFIG_VALUE_0": "/dev/null",
            "GIT_CONFIG_KEY_1": "core.pager",
            "GIT_CONFIG_VALUE_1": "cat",
            "GIT_CONFIG_KEY_2": "credential.interactive",
            "GIT_CONFIG_VALUE_2": "false",
            "GIT_CONFIG_KEY_3": "core.fsmonitor",
            "GIT_CONFIG_VALUE_3": "false",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "PAGER": "cat",
            "GIT_EDITOR": "/usr/bin/false",
            "GIT_SEQUENCE_EDITOR": "/usr/bin/false",
            "EDITOR": "/usr/bin/false",
            "VISUAL": "/usr/bin/false"
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw WorkspaceGitError.gitFailed(
                operation: arguments.first ?? "git",
                status: -1,
                detail: boundedDetail(String(describing: error))
            )
        }

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }

    private static func commandError(_ result: GitResult, operation: String) -> WorkspaceGitError {
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        return .gitFailed(
            operation: operation,
            status: result.status,
            detail: boundedDetail(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    private static func boundedDetail(_ detail: String) -> String {
        String(detail.prefix(2_048))
    }
}
