import XCTest

@testable import Sophia

/// **重みの再開取得。** ネットワークを触らない部分だけを測る。
///
/// ここが守っているのは 2026-09-05 の事故である ──
/// **取得が 99.2%（4,571,486,285 / 4,607,835,174 bytes）で落ち、4.57GB が孤児になった。**
/// swift-huggingface 0.9.0 に再開が無く、**やり直すたびに 4.5GB を捨てていた**
/// （一時ディレクトリに 57件・16GB）。
///
/// **実測の値をそのまま使う。** 丸めた数字で試験すると、
/// 「実際に起きた形」を測っていないものになる（R2）。
final class WeightPrefetchTests: XCTestCase {

    /// 2026-09-05 に実際に起きた値。
    private let orphanedBytes: Int64 = 4_571_486_285
    private let realSize: Int64 = 4_607_835_174

    // MARK: - 再開位置の判断

    /// **あの日の続きから継げること。** 36,348,889 バイトだけ取れば済む。
    func testTheOrphanedPartialResumesInsteadOfStartingOver() {
        let offset = WeightPrefetch.resumeOffset(
            existingBytes: orphanedBytes, expectedSize: realSize)
        XCTAssertEqual(offset, orphanedBytes, "途中から継げていない")
        XCTAssertEqual(realSize - (offset ?? 0), 36_348_889, "残りの量が実測と違う")
    }

    /// **揃っていれば取りに行かない。** `nil` が「もう完成している」の合図。
    func testACompleteFileIsNotFetchedAgain() {
        XCTAssertNil(
            WeightPrefetch.resumeOffset(existingBytes: realSize, expectedSize: realSize))
    }

    /// **何も無ければ最初から。**
    func testNothingOnDiskStartsFromZero() {
        XCTAssertEqual(WeightPrefetch.resumeOffset(existingBytes: 0, expectedSize: realSize), 0)
    }

    /// **期待より大きいものは捨てて取り直す。**
    ///
    /// 別のファイルの残骸が同じ名前で残っている場合がある。
    /// **継ぐと壊れたものが出来上がり、sha256 で落ちるまで気づけない。**
    func testAnOversizedLeftoverIsDiscardedRatherThanResumed() {
        XCTAssertEqual(
            WeightPrefetch.resumeOffset(existingBytes: realSize + 1, expectedSize: realSize), 0)
    }

    // MARK: - ヘッダの解釈

    private func response(_ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://huggingface.co/x/y/resolve/main/model.safetensors")!,
            statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    /// **実際に返ってきたヘッダで測る**（2026-09-06 に `curl -I` で取得したもの）。
    func testTheRealHeadersAreReadTheWayTheyActuallyArrive() throws {
        let file = try WeightPrefetch.remoteFile(
            from: response([
                "x-repo-commit": "545dc4251c05440727734bcd94334791f6ab0192",
                "x-linked-etag":
                    "\"f2d29621aab300336ad645567ff38c42aac755513006ef4e8a579cf7ef5256d8\"",
                "x-linked-size": "4607835174",
                // **本物の応答にはこれが入っている。** LFS のポインタの長さであって、
                // 重みの大きさではない。**ここを総量だと読むと「1バイトも落ちていないのに完了」になる。**
                "content-length": "982",
            ]))
        XCTAssertEqual(file.revision, "545dc4251c05440727734bcd94334791f6ab0192")
        XCTAssertEqual(
            file.etag, "f2d29621aab300336ad645567ff38c42aac755513006ef4e8a579cf7ef5256d8",
            "引用符が外れていない")
        XCTAssertEqual(file.size, realSize, "content-length の 982 を拾っていないか")
    }

    /// **足りないヘッダは推測で埋めない**（R7）。
    func testAMissingSizeIsRefusedInsteadOfGuessed() {
        XCTAssertThrowsError(
            try WeightPrefetch.remoteFile(
                from: response([
                    "x-repo-commit": "abc", "x-linked-etag": "def",
                    "content-length": "982",
                ]))
        ) { error in
            XCTAssertEqual(
                error as? WeightPrefetch.Failure, .missingHeaders("x-linked-size"),
                "content-length で代用していないか")
        }
    }

    func testAMissingRevisionIsRefused() {
        XCTAssertThrowsError(
            try WeightPrefetch.remoteFile(
                from: response(["x-linked-etag": "def", "x-linked-size": "1"]))
        ) { error in
            XCTAssertEqual(
                error as? WeightPrefetch.Failure, .missingHeaders("x-repo-commit"))
        }
    }

    // MARK: - 切れ方

    /// **1切れが大きすぎないこと。** 落ちたときに捨てる量が、これで決まる。
    ///
    /// 64MB なら 4.6GB を 72 往復で取り、**失うのは最大 64MB**である。
    /// **今回直している欠陥は「4.5GB を捨てていた」ことなので、ここが大きいと直っていない。**
    func testASingleSliceIsSmallEnoughThatLosingItDoesNotMatter() {
        XCTAssertLessThanOrEqual(WeightPrefetch.sliceBytes, 128 * 1024 * 1024)
        let slices = (realSize + WeightPrefetch.sliceBytes - 1) / WeightPrefetch.sliceBytes
        XCTAssertLessThanOrEqual(slices, 200, "往復が多すぎる")
        XCTAssertGreaterThanOrEqual(slices, 10, "1切れが大きすぎる")
    }
}
