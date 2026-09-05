import Foundation
import XCTest
@testable import Sophia

// =============================================================================
//  取得の無進捗の検知（FR-07 / NFR-10 / FR-11）
// -----------------------------------------------------------------------------
//  ## このファイルが守っているもの
//
//  2026-08-18、キャッシュを消したあとにアプリが
//  **「モデルを取得しています（0%）」から永久に進まなくなった。**
//  エラーもログも TCP接続も書き込みも無く、**落ちないまま黙っていた。**
//
//  `ModelDownloadStallWatch` はそれを検知するための見張りである。
//  ここで確かめるのは2つで、**後者のほうが重い。**
//
//  | 確かめること | 落ちたときに起こること |
//  |---|---|
//  | 止まったら検知する | また黙って固まる（元に戻る） |
//  | **止まっていなければ検知しない** | **正常な取得を殺す。今より悪くなる** |
//
//  ## 実ダウンロードは走らせない（走らせられない）
//
//  重みは 4.62GB ある。**それを落とさないと確かめられない見張りは、結局誰も確かめない。**
//  だから判定に使う「いま」を引数で受ける設計にしてある
//  （`ModelDownloadStallWatch.evaluate(at:firstByteGrace:stallTimeout:)`）。
//  `SuspendingClock.Instant.advanced(by:)` で「90秒後」をその場で作れるので、
//  **1秒も待たずに、閾値のちょうど手前と直後を突ける。**
//
//  ネットワークにも触れない。触れたらこのファイルは CI で不安定になり、
//  「たまに落ちるテスト」として無視されるようになる。
// =============================================================================

final class ModelDownloadStallTests: XCTestCase {

    /// 試験用の閾値。**製品の既定値（90秒 / 60秒）とは意図的に別の数**にしてある。
    /// 同じ数にすると、既定値を変えたときにテストが道連れで壊れて、
    /// 「閾値を変えた」のか「判定が壊れた」のかを切り分けられなくなる。
    private let firstByteGrace: Duration = .seconds(30)
    private let stallTimeout: Duration = .seconds(10)

    private func makeWatch(
        at start: SuspendingClock.Instant
    ) -> ModelDownloadStallWatch {
        ModelDownloadStallWatch(startedAt: start)
    }

    private func verdict(
        _ watch: ModelDownloadStallWatch, after seconds: Int, from start: SuspendingClock.Instant
    ) -> ModelDownloadStallWatch.Verdict {
        watch.evaluate(
            at: start.advanced(by: .seconds(seconds)),
            firstByteGrace: firstByteGrace,
            stallTimeout: stallTimeout)
    }

    /// ディスク観測つきの見張り。**観測値は試験が完全に決める**（監督の縛り①／R1）。
    ///
    /// 実ファイルを作らないのは、**判定そのものを測るため**である。
    /// ファイルシステムに依存させると、測っているのが判定なのか環境なのか分からなくなる。
    private final class FakeDisk: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64?
        init(_ initial: Int64?) { value = initial }
        func set(_ next: Int64?) { lock.withLock { value = next } }
        var observer: ModelDownloadStallWatch.DiskObserver {
            { [self] in lock.withLock { value } }
        }
    }

    // MARK: - 検知する側

    /// **今回の事故そのもの。** コールバックが1回も鳴らず、1バイトも来ない。
    func testNoBytesAtAllIsStalledAfterFirstByteGrace() {
        let start = SuspendingClock().now
        let watch = makeWatch(at: start)

        // 猶予の直前は、まだ打ち切らない。
        guard case .idle = verdict(watch, after: 29, from: start) else {
            return XCTFail("猶予の直前で打ち切ってはいけない（29秒 < 30秒）")
        }

        guard case .stalled(let report) = verdict(watch, after: 31, from: start) else {
            return XCTFail("1バイトも来ないまま猶予を過ぎたら打ち切ること")
        }
        XCTAssertEqual(report.completedBytes, 0)
        XCTAssertEqual(report.callbackCount, 0, "コールバックが1度も鳴っていない事実を残すこと")
        XCTAssertFalse(report.sawAnyBytes, "「始まらない」と「途中で止まった」を取り違えないこと")
    }

    /// コールバックは鳴っているが、バイトが1つも増えない。
    ///
    /// **「鳴っている」と「進んでいる」は別である。** 進捗ハンドラは
    /// swift-huggingface のサンプリングタスクが 100ms 間隔で機械的に鳴らすので、
    /// 回数だけを見ていると「動いている」と誤読する。
    func testCallbacksWithoutBytesAreStillStalled() {
        let start = SuspendingClock().now
        let watch = makeWatch(at: start)

        // 0 バイトのまま 100ms 間隔で 200 回鳴った、という状況を作る。
        for tick in 0 ..< 200 {
            watch.note(
                completedBytes: 0, totalBytes: 4_620_000_000,
                at: start.advanced(by: .milliseconds(tick * 100)))
        }

        guard case .stalled(let report) = verdict(watch, after: 31, from: start) else {
            return XCTFail("コールバックが鳴っていてもバイトが増えていなければ打ち切ること")
        }
        XCTAssertEqual(report.callbackCount, 200)
        XCTAssertEqual(report.completedBytes, 0)
    }

    /// 途中まで落ちてから止まった。**猶予は短いほう（`stallTimeout`）が使われる。**
    func testStallAfterSomeBytesUsesShorterTimeout() {
        let start = SuspendingClock().now
        let watch = makeWatch(at: start)

        watch.note(
            completedBytes: 1_200_000_000, totalBytes: 4_620_000_000,
            at: start.advanced(by: .seconds(5)))

        // 最後に増えたのは 5 秒地点。そこから 9 秒（< 10秒）はまだ打ち切らない。
        guard case .idle = verdict(watch, after: 14, from: start) else {
            return XCTFail("短いほうの閾値の直前で打ち切ってはいけない")
        }
        // 11 秒経過（> 10秒）で打ち切る。**30秒の猶予を待たないこと。**
        guard case .stalled(let report) = verdict(watch, after: 16, from: start) else {
            return XCTFail("一度バイトが来たあとは短いほうの閾値で判定すること")
        }
        XCTAssertTrue(report.sawAnyBytes)
        XCTAssertEqual(report.completedBytes, 1_200_000_000)
        XCTAssertEqual(report.idleSeconds, 11, accuracy: 0.1)
    }

    // MARK: - 検知しない側（**こちらのほうが重い。誤検知は正常な取得を殺す**）

    /// 1バイトでも増えれば時計は戻る。
    ///
    /// 実測 20MB/s の **1/1000（20KB/s）**まで落ちた回線を想定した。
    /// 9秒に1回しか進捗が動かなくても、**永久に打ち切られない**こと。
    func testSlowButAliveDownloadIsNeverStalled() {
        let start = SuspendingClock().now
        let watch = makeWatch(at: start)

        var bytes: Int64 = 0
        for step in 1 ... 50 {
            let at = start.advanced(by: .seconds(step * 9))
            bytes += 180_000   // 20KB/s × 9秒
            watch.note(completedBytes: bytes, totalBytes: 4_620_000_000, at: at)

            guard case .stalled = watch.evaluate(
                at: at, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout)
            else { continue }
            XCTFail("遅いだけの取得を打ち切ってはいけない（\(step * 9)秒地点）")
            return
        }
    }

    /// **取得が終わったら見張りは黙る。**
    ///
    /// ここが正常系を守っている一点である。取得100%のあとには
    /// 4.62GB の重みをメモリへ展開する時間が続き、その間バイトは1つも増えない。
    /// 16GB機ではスワップを噛んで閾値を超えることが普通にある。
    /// **黙らせないと、正常に読み込んでいる最中に「進んでいません」と出す。**
    func testWeightExpansionAfterCompletionIsNotStalled() {
        let start = SuspendingClock().now
        let watch = makeWatch(at: start)

        watch.note(
            completedBytes: 4_620_000_000, totalBytes: 4_620_000_000,
            at: start.advanced(by: .seconds(1)))

        // 展開に10分かかっても打ち切らない。
        guard case .healthy = verdict(watch, after: 600, from: start) else {
            return XCTFail("取得完了後の重み展開を無進捗と判定してはいけない")
        }
    }

    /// 進んでいる間は `.idle` にすらならない（＝画面に警告を出さない）。
    func testActiveDownloadStaysHealthy() {
        let start = SuspendingClock().now
        let watch = makeWatch(at: start)

        watch.note(
            completedBytes: 500_000_000, totalBytes: 4_620_000_000,
            at: start.advanced(by: .seconds(20)))

        guard case .healthy(let report) = verdict(watch, after: 22, from: start) else {
            return XCTFail("直前にバイトが増えているなら何も出さないこと")
        }
        XCTAssertEqual(report.fraction ?? 0, 0.108, accuracy: 0.001)
    }

    /// 進捗が巻き戻る報告が来ても、時計を戻さない。
    ///
    /// `Progress` は再開時に一度 0 へ落ちることがある
    /// （`HubClient+Files.swift` に `completedUnitCount = 0` を書く経路が実在する）。
    /// **減った報告で「進んだ」と誤認しない**ことを固定しておく。
    func testDecreasingProgressDoesNotResetTheClock() {
        let start = SuspendingClock().now
        let watch = makeWatch(at: start)

        watch.note(
            completedBytes: 900_000_000, totalBytes: 4_620_000_000,
            at: start.advanced(by: .seconds(1)))
        watch.note(
            completedBytes: 0, totalBytes: 4_620_000_000,
            at: start.advanced(by: .seconds(9)))

        // 最後に「増えた」のは 1 秒地点なので、12 秒地点では 11 秒 無風。
        guard case .stalled(let report) = verdict(watch, after: 12, from: start) else {
            return XCTFail("値が減った報告で時計を戻してはいけない")
        }
        XCTAssertEqual(report.completedBytes, 900_000_000, "到達済みの最大値を保つこと")
    }

    // MARK: - 打ち切る前に見せるもの（要件2）

    /// 閾値の半分を過ぎたら `.idle` になり、**打ち切る前に画面へ出す材料**が揃う。
    func testIdleVerdictCarriesUserFacingText() {
        let start = SuspendingClock().now
        let watch = makeWatch(at: start)
        watch.note(completedBytes: 0, totalBytes: 4_620_000_000, at: start)

        guard case .idle(let report) = verdict(watch, after: 20, from: start) else {
            return XCTFail("猶予の半分を過ぎたら、打ち切る前に利用者へ出すこと")
        }
        XCTAssertTrue(
            report.waitingDetail.contains("1バイトも届いていません"),
            "何が起きているかを日本語で言い切ること: \(report.waitingDetail)")
        XCTAssertTrue(
            report.waitingDetail.contains("0.00 GB / 4.62 GB"),
            "落ちたバイト数を必ず添えること: \(report.waitingDetail)")
    }

    // MARK: - 表示の書式（FR-11）

    /// 「0 MB / 4.6 GB」なら異常だと分かる、が要件だった。**0 を 0 と出せること。**
    ///
    /// `ByteCountFormatter` を使わない理由がここにある
    /// ── あれは 0 を「ゼロバイト」と訳し、**いちばん見せたい値がいちばん読みにくくなる。**
    func testByteTextShowsZeroAsZero() {
        XCTAssertEqual(
            formatDownloadedBytes(completed: 0, total: 4_620_000_000),
            "0.00 GB / 4.62 GB")
        XCTAssertEqual(
            formatDownloadedBytes(completed: 2_000_000_000, total: 4_620_000_000),
            "2.00 GB / 4.62 GB")
        // 1GB 未満のモデル（0.6B など）は MB で出す。
        XCTAssertEqual(
            formatDownloadedBytes(completed: 0, total: 400_000_000),
            "0 MB / 400 MB")
        // 総量が取れていない ＝ ファイル一覧すら返っていない。**その事実を隠さない。**
        XCTAssertEqual(
            formatDownloadedBytes(completed: 0, total: 0),
            "受信 0 バイト・総量は未取得")
    }

    // MARK: - 日本語（FR-11: 原因と対処をセットで）

    /// 「始まらなかった」と「途中で止まった」で**文言と対処が変わる**こと。
    func testJapaneseTextSeparatesNeverStartedFromInterrupted() {
        let neverStarted = SophiaError.modelDownloadStalled(
            ModelDownloadStallWatch.Report(
                completedBytes: 0, totalBytes: 4_620_000_000,
                callbackCount: 0, idleSeconds: 90),
            modelID: SophiaDefaults.modelID)

        XCTAssertEqual(neverStarted.code, .modelDownloadStalled)
        XCTAssertTrue(neverStarted.message.contains("始まりませんでした"))
        XCTAssertTrue(neverStarted.message.contains("90秒"), "何秒待ったのかを出すこと")
        XCTAssertTrue(neverStarted.message.contains("0.00 GB / 4.62 GB"))
        // 接続そのものが成立していない側にだけ出す対処。
        XCTAssertEqual(neverStarted.hint?.contains("ファイアウォール"), true)

        let interrupted = SophiaError.modelDownloadStalled(
            ModelDownloadStallWatch.Report(
                completedBytes: 2_000_000_000, totalBytes: 4_620_000_000,
                callbackCount: 4_000, idleSeconds: 60),
            modelID: SophiaDefaults.modelID)

        XCTAssertTrue(interrupted.message.contains("途中で止まりました"))
        XCTAssertEqual(interrupted.hint?.contains("再開されます"), true, "再開できることを伝えること")
    }

    /// FR-11 は「原因と対処をセットで」。**`hint` が空のまま出荷しないこと。**
    func testStalledErrorAlwaysCarriesBothCauseAndRemedy() {
        for bytes in [Int64(0), 1, 4_620_000_000] {
            let error = SophiaError.modelDownloadStalled(
                ModelDownloadStallWatch.Report(
                    completedBytes: bytes, totalBytes: 4_620_000_000,
                    callbackCount: 1, idleSeconds: 60),
                modelID: SophiaDefaults.modelID)
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertFalse(error.hint?.isEmpty ?? true, "対処のない失敗表示を作らないこと")
            XCTAssertTrue(
                error.hint?.contains("再試行") ?? false,
                "画面のボタン名（再試行）と文言を一致させること")
        }
    }

    /// 既定の閾値が**根拠の書いてある範囲から外れていない**ことを固定する。
    ///
    /// 数字そのものを試験しているのではなく、
    /// **「最初の1バイト」のほうが長い**という関係が壊れていないかを見ている。
    /// 逆転すると、一覧APIの往復ぶんで正常な取得を殺す。
    func testDefaultThresholdsKeepTheirRelationship() throws {
        // 環境変数で上書きされている環境では既定値を見ていないので飛ばす
        // （`SOPHIA_DOWNLOAD_STALL_S=0` は見張りを止める緊急避難であり、失敗ではない）。
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["SOPHIA_DOWNLOAD_STALL_S"] == nil
                && environment["SOPHIA_DOWNLOAD_FIRST_BYTE_S"] == nil,
            "閾値が環境変数で上書きされている")

        XCTAssertGreaterThan(
            MLXEngine.downloadFirstByteGrace, MLXEngine.downloadStallTimeout,
            "最初の1バイトまでの猶予は、途中の無風より長く取ること")
        XCTAssertGreaterThan(
            MLXEngine.downloadStallTimeout, MLXEngine.downloadWatchdogInterval,
            "見張りの間隔が閾値以上だと、判定の粒度が閾値より粗くなる")
    }

    // =========================================================================
    //  2026-09-05 の事故 —— **`Progress` が凍り、ディスクだけが増えていた**
    // =========================================================================
    //
    //  UI は 14,275,517 / 4,622,110,691 バイトで65秒止まって見えていたが、
    //  OS のログでは**同じ HTTP 200 の通信が 376,081,675 バイトを受信していた**（約26倍）。
    //  直後の -999 は Sophia 自身の見張りがキャンセルした結果である。
    //
    //  原因は回線ではなく **swift-huggingface 0.9.0 が大容量ファイルの最中に
    //  `Progress` を更新しないこと**（GitHub Issue #48）。
    //  **見張りが `Progress` しか見ていなかったので、「停止」としか判定しようがなかった。**

    /// **これが本体。** 進捗が閾値を超えて凍っていても、ディスクが増えていれば打ち切らない。
    func testAFrozenProgressIsNotStalledWhileTheDiskKeepsGrowing() {
        let start = SuspendingClock().now
        let disk = FakeDisk(14_275_517)
        let watch = ModelDownloadStallWatch(startedAt: start, observingDiskBytes: disk.observer)
        watch.note(completedBytes: 14_275_517, totalBytes: 4_622_110_691, at: start)

        // 事故と同じ形: `Progress` はこれ以上動かないが、実体は届き続けている。
        disk.set(376_081_675)
        let verdict = verdict(watch, after: 65, from: start)

        guard case .idle(let report) = verdict else {
            return XCTFail("ディスクが増えているのに打ち切った: \(verdict)")
        }
        XCTAssertEqual(report.completedBytes, 14_275_517, "進捗側の値は事実のまま残すこと")
        XCTAssertEqual(report.diskBytes, 376_081_675, "ディスク側の値が Report に無い")
        XCTAssertEqual(report.diskIdleSeconds, 0, "動いた直後なのに無風秒数が付いている")
    }

    /// **両方止まったときだけ打ち切る。** 検知そのものは殺していない。
    func testBothSignalsSilentIsStillStalled() {
        let start = SuspendingClock().now
        let disk = FakeDisk(376_081_675)
        let watch = ModelDownloadStallWatch(startedAt: start, observingDiskBytes: disk.observer)
        watch.note(completedBytes: 14_275_517, totalBytes: 4_622_110_691, at: start)

        // ディスクも動かない。
        guard case .stalled(let report) = verdict(watch, after: 65, from: start) else {
            return XCTFail("両方止まっているのに打ち切らなかった")
        }
        XCTAssertEqual(report.diskBytes, 376_081_675)
        XCTAssertGreaterThanOrEqual(report.diskIdleSeconds ?? 0, 60)
    }

    /// **減るのは進んだ証拠である。**
    ///
    /// 1ファイルの取得が終わって次へ移ると一時ファイルは消え、合計は減る。
    /// 素朴に「増えていない」を見ると、**完了を停止と誤判定する** ──
    /// 前回と同じ形の誤検知を、別の入口から作らないための表明。
    func testAShrinkingTemporaryFileCountsAsProgressNotAsAStall() {
        let start = SuspendingClock().now
        let disk = FakeDisk(3_000_000_000)
        let watch = ModelDownloadStallWatch(startedAt: start, observingDiskBytes: disk.observer)
        watch.note(completedBytes: 14_275_517, totalBytes: 4_622_110_691, at: start)

        disk.set(12_000_000)  // 1本書き終えて次のファイルへ移った
        guard case .idle = verdict(watch, after: 65, from: start) else {
            return XCTFail("減ったことを停止と読んだ")
        }
    }

    /// **観測できないときは、従来どおり `Progress` だけで判定する。**
    ///
    /// 観測手段が無いことを「進んでいる」と読み替えない ──
    /// 読み替えると、**見張りを足したことで見張りが効かなくなる。**
    func testWithoutADiskObserverTheOldJudgementIsUnchanged() {
        let start = SuspendingClock().now
        let silent = FakeDisk(nil)
        let watch = ModelDownloadStallWatch(startedAt: start, observingDiskBytes: silent.observer)
        watch.note(completedBytes: 14_275_517, totalBytes: 4_622_110_691, at: start)

        guard case .stalled(let report) = verdict(watch, after: 65, from: start) else {
            return XCTFail("観測できないのに打ち切らなかった")
        }
        XCTAssertNil(report.diskBytes, "観測できていないのに数字が入っている")
        XCTAssertNil(report.diskIdleSeconds)
    }

    // =========================================================================
    //  一時ファイルの観測そのもの（**開発機には約7.34GB の残骸がある**）
    // =========================================================================

    /// **開始時刻より前の残骸を数えないこと。**
    ///
    /// 残骸は増えないので、全部を合計すると「動いていない」が常に成立し、
    /// **見張りは常に停止側へ倒れる。**
    func testStaleLeftoversFromEarlierDownloadsAreNotCounted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SophiaStallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let old = directory.appendingPathComponent("CFNetworkDownload_old.tmp")
        try Data(repeating: 0, count: 4_096).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: old.path)

        let startedAt = Date()
        let fresh = directory.appendingPathComponent("CFNetworkDownload_fresh.tmp")
        try Data(repeating: 0, count: 1_024).write(to: fresh)

        let observed = observeDownloadTemporaryBytes(startedAt: startedAt, in: directory)
        XCTAssertEqual(observed, 1_024, "古い残骸まで数えている（常に停止側へ倒れる）")
    }

    /// 取得中のファイルが1つも無いことは、**0 として返す**（観測はできている）。
    func testNoDownloadInFlightIsZeroNotUnknown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SophiaStallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(observeDownloadTemporaryBytes(startedAt: Date(), in: directory), 0)
    }

    /// **一覧が取れないことは nil。** 0 と混ぜない ──
    /// 混ぜると「観測できない」が「取得中のファイルが無い」に化ける。
    func testAnUnreadableDirectoryIsUnknownNotZero() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("SophiaStallTests-\(UUID().uuidString)-missing", isDirectory: true)
        XCTAssertNil(observeDownloadTemporaryBytes(startedAt: Date(), in: missing))
    }

    // =========================================================================
    //  検証役が見つけた逆向きの欠陥2件（2026-09-05）
    // =========================================================================

    /// **雑音では時計を戻さない。** これが待ちの天井の代わりである。
    ///
    /// 「変化したか」で戻していた最初の実装は、**観測対象で無関係な何かが
    /// 数バイト増減するだけで永久に `.idle` になった。**
    /// 時間で切る案は採っていない ── 1ファイルが巨大なとき `Progress` が
    /// 長時間沈黙するのは正常なので、**時間で切ると正常な取得を今度は時間で殺す。**
    func testTinyDiskNoiseDoesNotKeepTheWaitAlive() {
        let start = SuspendingClock().now
        let disk = FakeDisk(376_081_675)
        let watch = ModelDownloadStallWatch(startedAt: start, observingDiskBytes: disk.observer)
        watch.note(completedBytes: 14_275_517, totalBytes: 4_622_110_691, at: start)

        // 1.2MB に届かない増減（雑音）。
        disk.set(376_081_675 + 4_096)

        guard case .stalled = verdict(watch, after: 65, from: start) else {
            return XCTFail("数KBの雑音で待ちが延びている（天井が無い）")
        }
    }

    /// 境界のすぐ上は本物として扱うこと。**雑音を落とす側に寄せすぎない。**
    func testAChangeAtTheThresholdCountsAsRealProgress() {
        let start = SuspendingClock().now
        let base: Int64 = 376_081_675
        let disk = FakeDisk(base)
        let watch = ModelDownloadStallWatch(startedAt: start, observingDiskBytes: disk.observer)
        watch.note(completedBytes: 14_275_517, totalBytes: 4_622_110_691, at: start)

        disk.set(base + ModelDownloadStallWatch.meaningfulDiskChange(within: stallTimeout))

        guard case .idle = verdict(watch, after: 65, from: start) else {
            return XCTFail("境界ちょうどの変化を雑音として捨てている")
        }
    }

    /// **完了の合図は `Progress` 以外から来ること。**
    ///
    /// 壊れているのが `Progress` なので、`Progress` で「終わった」を判定できない。
    /// 取得が本当に終わったあとは重みの展開が続き（16GB機で数十秒〜）、
    /// **その間はディスクも `Progress` も動かない。**
    /// ここで打ち切ると、**事故が消えるのではなく「取得中」から「展開中」へ移るだけ**になる。
    func testCompletionFromOutsideProgressSilencesTheWatch() {
        let start = SuspendingClock().now
        let disk = FakeDisk(0)  // 一時ファイルは片付いた
        let completed = FakeDisk(nil)  // 使わない
        _ = completed

        let watch = ModelDownloadStallWatch(
            startedAt: start,
            observingDiskBytes: disk.observer,
            // ディスク上にモデルが揃った、という `Progress` に依らない合図。
            observingCompletion: { true })
        // `Progress` は総量に届いていない（Issue #48 の状態のまま）。
        watch.note(completedBytes: 14_275_517, totalBytes: 4_622_110_691, at: start)

        guard case .healthy = verdict(watch, after: 300, from: start) else {
            return XCTFail("取得が終わっているのに展開中を打ち切った")
        }
    }

    /// **完了していなければ、従来どおり打ち切る。** 黙らせる側へ倒れていないこと。
    func testAnIncompleteDownloadIsStillStalledEvenWithTheCompletionObserver() {
        let start = SuspendingClock().now
        let disk = FakeDisk(376_081_675)
        let watch = ModelDownloadStallWatch(
            startedAt: start,
            observingDiskBytes: disk.observer,
            observingCompletion: { false })
        watch.note(completedBytes: 14_275_517, totalBytes: 4_622_110_691, at: start)

        guard case .stalled = verdict(watch, after: 65, from: start) else {
            return XCTFail("未完了なのに打ち切らなかった")
        }
    }

    // =========================================================================
    //  完了の判定（**`isDownloaded` を流用しない**）
    // =========================================================================

    private func makeSnapshot(_ files: [String: String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SophiaSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, contents) in files {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    /// 分割されていなければ、1枚あれば揃っている。
    func testASingleFileSnapshotIsComplete() throws {
        let directory = try makeSnapshot([
            "config.json": "{}", "model.safetensors": "w",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(MLXModelCatalog.snapshotIsComplete(in: directory))
    }

    /// **分割されているとき、1枚目だけでは完了ではない。**
    ///
    /// `isDownloaded` は `.safetensors` が1枚でもあれば真を返すので、
    /// あれを見張りの完了判定に流用すると**残りを落としている間ずっと黙る。**
    /// 「もう在るか」という起動前の問いの器を、「いま終わったか」へ流用した形になる。
    ///
    /// > **いまのカタログは4モデルとも単一ファイルなので、この経路は通らない**
    /// > （2026-09-05 に監督が HuggingFace の API で確認）。
    /// > **分割された重みを足した日に実在に変わるので、判定のほうを先に正しくしてある。**
    func testAShardedSnapshotIsIncompleteUntilEveryShardArrives() throws {
        let index = """
            {"weight_map": {"a": "model-00001-of-00002.safetensors",
                            "b": "model-00002-of-00002.safetensors"}}
            """
        let partial = try makeSnapshot([
            "config.json": "{}",
            "model.safetensors.index.json": index,
            "model-00001-of-00002.safetensors": "w",
        ])
        defer { try? FileManager.default.removeItem(at: partial) }
        XCTAssertFalse(
            MLXModelCatalog.snapshotIsComplete(in: partial),
            "1枚目だけで完了と判定している（見張りが残りの取得中ずっと黙る）")

        try Data("w".utf8).write(
            to: partial.appendingPathComponent("model-00002-of-00002.safetensors"))
        XCTAssertTrue(MLXModelCatalog.snapshotIsComplete(in: partial), "全部揃っても完了と言わない")
    }

    /// `config.json` が無ければ完了ではない（途中で失敗した取得を完了と誤認しない）。
    func testASnapshotWithoutConfigIsNotComplete() throws {
        let directory = try makeSnapshot(["model.safetensors": "w"])
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(MLXModelCatalog.snapshotIsComplete(in: directory))
    }
}
