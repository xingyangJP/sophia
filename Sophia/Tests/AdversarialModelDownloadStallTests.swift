import Foundation
import XCTest
@testable import Sophia

// =============================================================================
//  取得の見張りを、破る側から見る（2026-09-05 / ディスク信号の追加に対して）
// -----------------------------------------------------------------------------
//  ## このファイルは `ModelDownloadStallTests` の反対側である
//
//  あちらは「止まったら検知する」「止まっていなければ検知しない」を守る。
//  **こちらは、直したことで生まれた逆向きの欠陥を探す。**
//
//  | 印 | 意味 |
//  |---|---|
//  | `XCTExpectFailure` を含む | **いま実際に破れている。** 直すと「失敗しなかった」で落ちるので、直した人が必ず気づく |
//  | 含まない | いまは守られている。**壊れたらここが落ちる** |
//
//  ## 背景 ── 2026-09-05 の事故と、その直し
//
//  UI が 14,275,517 / 4,620,000,691 バイトで65秒停止し、watchdog が打ち切った。
//  ところが OS のログでは**同じ HTTP 200 の通信が 376,081,675 バイトを受信していた**（約26倍）。
//  原因は swift-huggingface 0.9.0 が大容量ファイルの最中に `Progress` を更新しないこと
//  （GitHub Issue #48）── **回線断ではなく、`Progress` だけを見た誤検知である。**
//
//  直しは「ディスク上の実サイズを第2の信号にし、**両方が止まったときだけ**打ち切る」。
//  **ここで問うのは、その直しが何を壊したかである。**
//
//  ## 実ダウンロードは走らせない
//
//  観測はクロージャで注入できる（`ModelDownloadStallWatch.DiskObserver`）ので、
//  **ファイルシステムにも 4.62GB にも触らずに判定ロジックだけを測れる。**
//  触ると、測っているのが判定なのかファイルシステムなのか分からなくなる（15.7節 R1）。
// =============================================================================

final class AdversarialModelDownloadStallTests: XCTestCase {

    /// **製品の既定値（90秒 / 60秒）とは別の数**にしてある。
    /// 同じにすると、既定値を変えたときにテストが道連れで壊れて、
    /// 「閾値を変えた」のか「判定が壊れた」のかを切り分けられなくなる。
    private let firstByteGrace: Duration = .seconds(30)
    private let stallTimeout: Duration = .seconds(10)

    // =========================================================================
    //  1. 対照 ── これが崩れたら、以下は何も表明していない
    // =========================================================================

    /// **陰性対照。** どちらの信号も動いていれば、いつまでも健全であること。
    func testNeitherSignalIdleStaysHealthy() {
        let start = SuspendingClock.now
        let disk = Counter(0)
        let watch = ModelDownloadStallWatch(
            startedAt: start, observingDiskBytes: { disk.value })

        var now = start
        for step in 1...20 {
            now = now.advanced(by: .seconds(5))
            disk.add(1_000_000)
            watch.note(
                completedBytes: Int64(step) * 1_000_000, totalBytes: 4_620_000_000, at: now)
            guard case .healthy = watch.evaluate(
                at: now, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout) else {
                return XCTFail("両方動いているのに健全でない（step=\(step)）")
            }
        }
    }

    /// **陽性対照。** 本当に両方死んでいるなら、打ち切れること。
    ///
    /// **これが落ちたら「今度は打ち切れない」という逆向きの欠陥である。**
    /// 古い一時ファイル約 7.34GB を握らせてあるのは、**残骸に騙されないこと**の確認でもある
    /// ── 残骸は動かないので、判定は「動いたか」だけを見る限り影響を受けないはずである。
    func testBothSignalsDeadStillStalls() {
        let start = SuspendingClock.now
        let watch = ModelDownloadStallWatch(
            startedAt: start, observingDiskBytes: { 7_340_000_000 })

        watch.note(completedBytes: 14_275_517, totalBytes: 4_620_000_000, at: start)
        let later = start.advanced(by: stallTimeout * 3)

        guard case .stalled(let report) = watch.evaluate(
            at: later, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout) else {
            return XCTFail("両方止まっているのに打ち切らない")
        }
        // **Report に入っていない情報は画面にも出せない**（`Report` の型コメント）。
        XCTAssertNotNil(report.diskBytes, "ディスク側の観測値が Report に入っていない")
        XCTAssertNotNil(report.diskIdleSeconds, "ディスク側の無風秒数が Report に入っていない")
    }

    /// **観測できない（nil）ことを「進んでいる」と読み替えないこと。**
    func testAnUnobservableDiskDoesNotRescueAStalledDownload() {
        let start = SuspendingClock.now
        let watch = ModelDownloadStallWatch(
            startedAt: start, observingDiskBytes: { nil })

        watch.note(completedBytes: 14_275_517, totalBytes: 4_620_000_000, at: start)
        let later = start.advanced(by: stallTimeout * 3)

        guard case .stalled(let report) = watch.evaluate(
            at: later, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout) else {
            return XCTFail("観測できないことを『進んでいる』と読み替えている")
        }
        XCTAssertNil(report.diskBytes)
        XCTAssertNil(report.diskIdleSeconds, "観測していないのに無風秒数が入っている")
    }

    // =========================================================================
    //  2. 直したことで生まれた欠陥
    // =========================================================================

    /// **⚠ 待ちに上限が無い。** ディスクが動き続ける限り、永久に打ち切られない。
    ///
    /// 以前は `Progress` だけを見ていたので、無風が閾値を超えれば**必ず**打ち切れた。
    /// いまは**ディスク側が1バイトでも動けば `.idle` に落ちる**ので、
    /// 観測対象で無関係な何かが動いているだけで、待ちが無限になる。
    ///
    /// **ここで動かしているのは1バイトずつである。** 監督は「1.2MB 以上動いたときだけ
    /// 時計を戻す」形で塞ぐと裁定した（`downloadStallTimeout` の型コメントが
    /// 「20KB/s まで落ちた回線でも 60秒で 1.2MB 増える」と既に持っている数字）。
    /// **その形になれば、この1バイトの揺れでは時計が戻らず、打ち切りに到達する。**
    func testTheWaitHasNoCeilingWhileDiskKeepsTwitching() {
        let start = SuspendingClock.now
        let disk = Counter(0)
        let watch = ModelDownloadStallWatch(
            startedAt: start, observingDiskBytes: { disk.value })

        // **取得は1バイトも進まない。** 動くのはディスクの観測値だけ。
        watch.note(completedBytes: 14_275_517, totalBytes: 4_620_000_000, at: start)

        var now = start
        for _ in 1...120 {                       // 閾値の 360 倍まで進めても…
            now = now.advanced(by: stallTimeout * 3)
            disk.add(1)                          // …1バイトでは基準点を超えない（直した後）
            _ = watch.evaluate(
                at: now, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout)
        }

        // **印は外した（2026-09-05、実装役）。** 検証役が書いた時点では破れていたが、
        // 「変化したか」ではなく「判定に使う閾値ぶんの量だけ動いたか」で時計を戻す形に
        // 直したので塞がっている ── 1バイトの微動では基準点を超えない。
        //
        // **時間の絶対上限は入れていない。** 1ファイルが巨大なとき `Progress` が
        // 長時間沈黙するのは正常なので、時間で切ると Issue #48 の下で
        // **正常な取得を今度は時間で殺す。**
        //
        // > ⚠ **「天井が要らなくなる」は 2026-09-05 に取り下げられた**（`285ad32`）。
        // > 1.2MB は**雑音を落とすフィルタ**であって天井ではない ──
        // > 同じ観測対象で 1.2MB 超の増減が繰り返し起きれば時計は戻り続ける。
        // > **天井が要る条件が十分に狭まっただけで、閉じてはいない。**
        guard case .stalled = watch.evaluate(
            at: now, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout) else {
            return XCTFail("上限が無い ── ディスクの微動だけで永久に待つ")
        }
    }

    /// **⚠ `finished` が、壊れていると分かっている信号にぶら下がっている。**
    ///
    /// `finished` が立つのは `note` の中の `completedBytes >= totalBytes` だけである。
    /// ところが **swift-huggingface 0.9.0 は大容量ファイルの最中に `Progress` を
    /// 更新しない**（Issue #48）── **それが今回の事故の原因そのものである。**
    ///
    /// つまり取得が本当に終わっても `finished` は立たないことがある。
    /// そのとき一時ファイルは片付くのでディスクも動かなくなり、
    /// **重みの展開（16GB機で数十秒〜）の最中に「両方無風」が成立する。**
    ///
    /// > **事故が消えたのではなく、起きる場所が「取得中」から「展開中」へ移っただけではないか。**
    /// > **`Progress` の故障は、`Progress` に依存しない信号でしか救えない。**
    func testAFinishedDownloadIsNotCancelledWhenProgressNeverReachedTheTotal() {
        let start = SuspendingClock.now
        let disk = Counter(3_000_000_000)
        let complete = Flag(false)

        // **出荷される構成で組む**（15.7節 R2 / 監督の指摘 2026-09-05）。
        //
        // 初版は `observingCompletion` を渡していなかった。**それは出荷経路に
        // 1つも存在しない構成である**（`MLXEngine.swift:445` が唯一の構成site で、
        // 両方を渡す）。渡さない見張りが打ち切るのは**仕様どおりの挙動**であって、
        // 欠陥ではない ── 初版の印は「欠陥2が在る」ではなく
        // 「完了の合図が無ければ打ち切る」と言っていた。**器の条件が出荷と違った。**
        let watch = ModelDownloadStallWatch(
            startedAt: start,
            observingDiskBytes: { disk.value },
            observingCompletion: { complete.value })

        // `Progress` は 14MB で止まったまま総量に届かない（Issue #48 の再現）。
        // **総量に届かない以上、`note` 側の `finished` は永久に立たない。**
        watch.note(completedBytes: 14_275_517, totalBytes: 4_620_000_000, at: start)

        // 取得は実際には完了した。一時ファイルが片付き、ディスクは動かなくなる。
        // **そして完了の合図だけが真になる**（`snapshotIsComplete` が見るのはディスクの実体）。
        var now = start.advanced(by: .seconds(1))
        disk.set(0)
        complete.set(true)
        _ = watch.evaluate(at: now, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout)

        // ここから重みの展開。バイトは増えず、ディスクも動かない。
        // **`Progress` 由来の信号だけを見ていたら、ここで打ち切られる。**
        now = now.advanced(by: stallTimeout * 3)

        guard case .healthy = watch.evaluate(
            at: now, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout) else {
            return XCTFail(
                "完了した取得を、重みの展開中に打ち切っている ── "
                    + "`Progress` に依存しない完了の合図が効いていない")
        }
    }

    /// **⚠ 武装した瞬間に、古い時計を渡している。**
    ///
    /// 観測できた最初の瞬間に基準点は置かれるようになった（`0132030`）が、
    /// **その枝は `lastDiskChangeAt` を更新していない。**
    /// `init` で `startedAt` に置かれたままなので、
    /// **武装した回の `diskIdle` は「見張り開始からの経過時間」になる。**
    ///
    /// | 時刻 | 何が起きるか |
    /// |---|---|
    /// | T0 | 見張り開始。一時ファイルはまだ無い（観測 nil）。`lastDiskChangeAt = T0` |
    /// | T0 | `Progress` が 14MB へ。**ここが最後の前進**（Issue #48） |
    /// | T0+limit超 | 一時ファイルがようやく現れ、`evaluate` が**武装する** |
    /// | **同じ回** | `idle ≥ limit` かつ **`diskIdle = T0 からの経過 ≥ limit`** → **`.stalled`** |
    ///
    /// > **「いま見えるようになった」は「開始から何も動いていない」ではない。**
    /// > 見えていなかった区間について、この時計は**何も知らない**はずである。
    ///
    /// 救い方は武装の枝でも `lastDiskChangeAt = now` を置くこと。
    /// **打ち切りを1周期ぶん遅らせるだけなので、逆向きの欠陥にはならない**
    /// ── 本当に死んでいれば次の回で打ち切れる。
    /// > **⚠ 到達性【2026-09-05 実測で否定】。** この筋書きは
    /// > **観測が最初に nil を返すこと**を前提にしている。**出荷の観測関数はそうならない** ──
    /// > `observeDownloadTemporaryBytes` が nil を返すのは `contentsOfDirectory` が
    /// > 失敗したときだけで、**該当ファイルがまだ1つも無い状態では 0 を返す。**
    /// > サンドボックス内の tmp は常に読めるので、**`init` の一発目の観測が 0 で成功し、
    /// > そこで武装が済む。** よって出荷経路ではこの欠陥は発火しない。
    /// >
    /// > **それでもこの試験は残す。** 「該当ファイルが無い＝観測できない＝nil」は
    /// > **自然な書き換え**であり、その日にこの欠陥は実在に変わる。
    /// > **0 と nil を撃ち分けているのは観測関数の側の判断で、呼び手は何も強制していない。**
    func testArmingTheDiskSignalDoesNotInheritTheClockFromBeforeItCouldSee() {
        let start = SuspendingClock.now
        let disk = Counter(500_000_000)
        let visible = Flag(false)                 // 一時ファイルはまだ観測できない
        let watch = ModelDownloadStallWatch(
            startedAt: start,
            observingDiskBytes: { visible.value ? disk.value : nil })

        // `Progress` が 14MB まで進む。**ここが最後の前進**（Issue #48）。
        watch.note(completedBytes: 14_275_517, totalBytes: 4_620_000_000, at: start)

        // 閾値を超えて経ってから、ようやく一時ファイルが観測できるようになる。
        let now = start.advanced(by: stallTimeout * 2)
        visible.set(true)

        // **印は外した（2026-09-05、実装役）。指摘どおり武装の枝で `lastDiskChangeAt` を置く。**
        // 逆向きには倒れない ── 打ち切りを1周期ぶん遅らせるだけで、
        // 本当に死んでいれば次の poll で打ち切る
        // （`ModelDownloadStallTests.testArmingLateOnlyDelaysTheVerdictByOnePoll` が縛っている）。
        if case .stalled = watch.evaluate(
            at: now, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout) {
            XCTFail("武装したその回で打ち切っている")
        }
    }

    // =========================================================================
    //  3. 直す側への申し送り ── **1.2MB を「1回の観測ごと」に当てないこと**
    // =========================================================================

    /// **遅いが生きている回線を、閾値の入れ方で殺さないこと。**
    ///
    /// `downloadStallTimeout` の型コメントの 1.2MB は
    /// **「60秒あれば増える量」**であって、**1回の観測ごとの量ではない。**
    ///
    /// | 当て方 | 20KB/s の回線を5秒ごとに観測すると |
    /// |---|---|
    /// | **直前の観測との差**に当てる | 1回あたり 100KB。**永久に 1.2MB に届かず、健全な取得を殺す** |
    /// | **最後に時計を戻した時点との差**に当てる | 60秒で 1.2MB に到達。**正しく生き延びる** |
    ///
    /// **1.2MB という数字は、後者の当て方を前提に導かれている。**
    /// いまの実装は「直前の観測と違えば戻す」なので**この試験は通る**。
    /// **通り続けることが、閾値を入れる人への条件である。**
    func testASlowButLiveConnectionSurvives() {
        let start = SuspendingClock.now
        let disk = Counter(0)
        let watch = ModelDownloadStallWatch(
            startedAt: start, observingDiskBytes: { disk.value })

        watch.note(completedBytes: 1, totalBytes: 4_620_000_000, at: start)

        // 20KB/s 相当を5秒ごとに観測する（1回 100KB）。`Progress` は沈黙したまま。
        var now = start
        for _ in 1...24 {                        // 120秒ぶん ＝ 閾値の12倍
            now = now.advanced(by: .seconds(5))
            disk.add(100_000)
            if case .stalled = watch.evaluate(
                at: now, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout) {
                return XCTFail(
                    "遅いが生きている回線を打ち切った ── "
                        + "1.2MB を『1回の観測ごと』に当てていないか")
            }
        }
    }

    /// **⚠ ディスク信号が、一度も有効にならない経路がある。**
    ///
    /// `diskBytesAtLastAdvance`（変化量の基準点）が置かれるのは2か所しかない ──
    /// **`init` の一発目の観測**と、**`note` で `Progress` が進んだとき**である。
    ///
    /// ところが見張りを作る時点では、まだ一時ファイルが存在しない
    /// （取得が始まっていないのだから当然である）。**`init` の観測は nil を返す。**
    /// すると基準点は nil のまま残り、`evaluate` の
    /// `if hasObservedDisk, let baseline = diskBytesAtLastAdvance` は**永久に通らない。**
    ///
    /// 基準点を nil から救い出せるのは `note` の中の `Progress` の前進だけである。
    /// **しかし `Progress` が前進しないことこそが Issue #48 であり、直しの目的だった。**
    ///
    /// > **直しが、直そうとした当の状況で不活性になる。**
    /// > ディスクがいくら伸びても時計は戻らず、`Progress` だけで打ち切られる ──
    /// > **つまり事故の前と同じ挙動に戻る。**
    ///
    /// 救い方は1行で、`evaluate` の中で **`hasObservedDisk` が false → true になる瞬間に
    /// 基準点も置く**こと。`init` にも `note` にも依存しなくなる。
    /// > **⚠ 到達性【2026-09-05 実測で否定】。** この筋書きは
    /// > **観測が最初に nil を返すこと**を前提にしている。**出荷の観測関数はそうならない** ──
    /// > `observeDownloadTemporaryBytes` が nil を返すのは `contentsOfDirectory` が
    /// > 失敗したときだけで、**該当ファイルがまだ1つも無い状態では 0 を返す。**
    /// > サンドボックス内の tmp は常に読めるので、**`init` の一発目の観測が 0 で成功し、
    /// > そこで武装が済む。** よって出荷経路ではこの欠陥は発火しない。
    /// >
    /// > **それでもこの試験は残す。** 「該当ファイルが無い＝観測できない＝nil」は
    /// > **自然な書き換え**であり、その日にこの欠陥は実在に変わる。
    /// > **0 と nil を撃ち分けているのは観測関数の側の判断で、呼び手は何も強制していない。**
    func testTheDiskSignalNeverArmsWhenTheTempFileAppearsAfterTheLastProgressAdvance() {
        let start = SuspendingClock.now
        let disk = Counter(0)
        // **`var` を @Sendable クロージャで捕まえられない**（Swift 6）ので、
        // このファイルが既に持っている `Counter` を旗として使う。
        // 0 = 一時ファイルはまだ存在しない（＝観測できない）。
        // ── 実装役がビルドを通すためだけに直した。判定は1文字も変えていない。
        let visible = Counter(0)
        let watch = ModelDownloadStallWatch(
            startedAt: start,
            observingDiskBytes: { visible.value > 0 ? disk.value : nil })

        // `Progress` が 14MB まで進む。**ここが最後の前進である**（Issue #48）。
        // この時点でも一時ファイルはまだ観測できない。
        watch.note(completedBytes: 14_275_517, totalBytes: 4_620_000_000, at: start)

        // 少し遅れて一時ファイルが現れ、以後ディスクは健全に伸び続ける。
        visible.add(1)
        var now = start
        for _ in 1...30 {
            now = now.advanced(by: .seconds(5))
            disk.add(50_000_000)                  // 10MB/s 相当。**明らかに生きている**
            _ = watch.evaluate(
                at: now, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout)
        }

        // **印は外した（2026-09-05、実装役）。指摘どおりに直した。**
        // `evaluate` の中で `hasObservedDisk` が false → true になる瞬間に基準点を置く。
        // `init` にも `note` にも依存させない ── 取得の途中で初めて観測できるようになる
        // 経路が実在する以上、**武装は観測側の出来事である。**
        if case .stalled = watch.evaluate(
            at: now, firstByteGrace: firstByteGrace, stallTimeout: stallTimeout) {
            XCTFail("ディスクが 10MB/s で伸びているのに打ち切っている")
        }
    }

    // MARK: - 補助

    /// 真偽をクロージャへ渡すための小さな箱。
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Bool
        init(_ initial: Bool) { storage = initial }
        var value: Bool {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func set(_ newValue: Bool) {
            lock.lock(); defer { lock.unlock() }
            storage = newValue
        }
    }

    /// クロージャから読み書きするための小さな箱。
    /// **`@Sendable` なクロージャが捕まえるので、`var` を直接掴ませない。**
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Int64
        init(_ initial: Int64) { storage = initial }
        var value: Int64 {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func add(_ delta: Int64) {
            lock.lock(); defer { lock.unlock() }
            storage += delta
        }
        func set(_ newValue: Int64) {
            lock.lock(); defer { lock.unlock() }
            storage = newValue
        }
    }
}
