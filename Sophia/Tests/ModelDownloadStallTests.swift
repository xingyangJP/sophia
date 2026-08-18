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
}
