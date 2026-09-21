import Foundation
import XCTest

@testable import Sophia

// =============================================================================
//  サンドボックスの中から、何が走るのか（FR-32 の前提を測る）
//
//  **的はコーディングエージェントである**（2026-09-21）── 読んで、書いて、**走らせる**。
//  アプリは App Sandbox の中にあり、子プロセスはそのサンドボックスを継ぐ。
//
//  > **「サンドボックスがあるからコマンドは走らない」も、
//  > 「`WorkspaceGit` が git を走らせているから何でも走る」も、どちらも推測である。**
//  > **設計を決める前に、走らせて見る。**
//
//  **試験ホストはアプリ本体なので、ここで走るものは出荷物と同じサンドボックスの中で走る。**
//  （`sandboxed=` の行で毎回確かめる。偽なら、この器は何も測っていない）
// =============================================================================

final class SandboxExecutionProbeTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SOPHIA_SANDBOXPROBE"] == "1",
            "サンドボックス内の実行プローブです。`make sandboxprobe` で走ります")
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data("[SANDBOXPROBE] \(line)\n".utf8))
    }

    private struct Outcome {
        var status: Int32
        var seconds: Double
        var tail: String
    }

    private func run(
        _ executable: String, _ arguments: [String], in directory: URL, timeout: TimeInterval = 240,
        extraEnvironment: [String: String] = [:]
    ) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // **`WorkspaceGit` と同じく環境を作り直す。** 試験ランナーの環境を継がせると、
        // 測っているのが「サンドボックスで走るか」ではなく「xcodebuild の環境なら走るか」になる。
        let home = NSHomeDirectory()
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "LANG": "C",
            "TMPDIR": NSTemporaryDirectory(),
        ].merging(extraEnvironment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let started = Date()
        do { try process.run() } catch {
            return Outcome(status: -1, seconds: 0, tail: "launch_failed: \(error)")
        }
        let deadline = DispatchTime.now() + timeout
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return Outcome(status: -2, seconds: timeout, tail: "timeout")
        }
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        // **警告に埋もれるので、`error` を含む行を優先して残す**（3回目の走行で、
        // SwiftPM の警告4行に本当の理由が押し出された）。
        let lines = text.split(separator: "\n")
        let errors = lines.filter { $0.localizedCaseInsensitiveContains("error") }
        let tail = (errors.isEmpty ? Array(lines.suffix(4)) : Array(errors.suffix(3)))
            .joined(separator: " ⏎ ")
        return Outcome(
            status: process.terminationStatus, seconds: Date().timeIntervalSince(started),
            tail: String(tail.prefix(600)))
    }

    func testWhatActuallyRunsInsideTheSandbox() throws {
        let env = ProcessInfo.processInfo.environment
        let sandboxed = env["APP_SANDBOX_CONTAINER_ID"] != nil
        log("BEGIN sandboxed=\(sandboxed) home=\(NSHomeDirectory())")
        XCTAssertTrue(sandboxed, "**サンドボックスの外で走っている。** この器は出荷物と同じ条件を測っていない")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sandboxprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // --- 1. 道具が起動するか --------------------------------------------
        // **`/usr/bin/git` などは xcrun の入口で、サンドボックスの中では即死する**
        // （`xcrun: error: cannot be used within an App Sandbox.` / 1回目の走行で実測）。
        // `WorkspaceGit` と同じく、**実体のパスを直接叩く。** 入口も1つ残して対照にする。
        let clt = "/Library/Developer/CommandLineTools/usr/bin"
        let xcode = "/Applications/Xcode.app/Contents/Developer/usr/bin"
        let tools: [(String, [String])] = [
            ("/bin/sh", ["-c", "echo ok"]),
            ("/usr/bin/git", ["--version"]),  // 入口（対照。落ちるはず）
            ("\(clt)/git", ["--version"]),
            ("\(clt)/python3", ["--version"]),
            ("\(clt)/make", ["--version"]),
            ("\(clt)/swift", ["--version"]),
            ("\(xcode)/xcodebuild", ["-version"]),
        ]
        for (tool, arguments) in tools {
            let o = run(tool, arguments, in: root, timeout: 60)
            log("TOOL \(tool) status=\(o.status) sec=\(String(format: "%.1f", o.seconds)) tail=\(o.tail)")
        }

        // --- 2. 外へ書けないこと（陰性対照。サンドボックスが効いている証拠）-----
        let outside = "/Users/\(NSUserName())/sandboxprobe-should-not-exist.txt"
        let escape = run("/bin/sh", ["-c", "echo x > \(outside)"], in: root, timeout: 30)
        let escaped = FileManager.default.fileExists(atPath: outside)
        log("ESCAPE status=\(escape.status) file_created=\(escaped) tail=\(escape.tail)")
        XCTAssertFalse(escaped, "**子プロセスがサンドボックスの外へ書けた。**")

        // --- 3. 本丸: 小さな Swift パッケージを作り、テストを走らせる -----------
        let sources = root.appendingPathComponent("Sources/Probe")
        let tests = root.appendingPathComponent("Tests/ProbeTests")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(
                name: "Probe",
                targets: [
                    .target(name: "Probe"),
                    .testTarget(name: "ProbeTests", dependencies: ["Probe"]),
                ])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public func add(_ a: Int, _ b: Int) -> Int { a + b }\n"
            .write(to: sources.appendingPathComponent("Probe.swift"), atomically: true, encoding: .utf8)
        try """
            import XCTest
            @testable import Probe
            final class ProbeTests: XCTestCase {
                func testAdd() { XCTAssertEqual(add(17, 23), 40) }
            }
            """.write(to: tests.appendingPathComponent("ProbeTests.swift"), atomically: true, encoding: .utf8)

        // **`--disable-sandbox`**: SwiftPM は自分でも sandbox-exec を掛ける。
        // App Sandbox の中で二重に掛けると、それだけで落ちることが知られている。両方測る。
        for (label, extra) in [("nested", [String]()), ("disable_inner", ["--disable-sandbox"])] {
            let o = run("\(clt)/swift", ["test"] + extra, in: root, timeout: 240)
            log("SWIFT_TEST mode=\(label) status=\(o.status) sec=\(String(format: "%.1f", o.seconds)) tail=\(o.tail)")
        }

        // **2回目の走行で分かったこと: SwiftPM は内部で `/usr/bin/xcrun --show-sdk-path` を呼び、
        // そこで落ちる。** `SDKROOT` を渡せば xcrun を経由しないはずである。渡して測る。
        let developer = "/Applications/Xcode.app/Contents/Developer"
        let sdk = "\(developer)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        let toolchainSwift = "\(developer)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        let pinned = ["SDKROOT": sdk, "DEVELOPER_DIR": developer]
        for (label, arguments) in [
            ("build_sdkroot", ["build", "--disable-sandbox"]),
            ("test_sdkroot", ["test", "--disable-sandbox"]),
        ] {
            let o = run(toolchainSwift, arguments, in: root, timeout: 300, extraEnvironment: pinned)
            log("SWIFT_PINNED mode=\(label) status=\(o.status) sec=\(String(format: "%.1f", o.seconds)) tail=\(o.tail)")
        }

        // --- 4. python のテスト（依存なし）------------------------------------
        try "import unittest\nclass T(unittest.TestCase):\n    def test_mul(self):\n        self.assertEqual(17*23, 391)\nunittest.main()\n"
            .write(to: root.appendingPathComponent("t.py"), atomically: true, encoding: .utf8)
        let py = run("\(clt)/python3", ["t.py"], in: root, timeout: 60)
        log("PY_TEST status=\(py.status) sec=\(String(format: "%.1f", py.seconds)) tail=\(py.tail)")

        log("END")
    }
}
