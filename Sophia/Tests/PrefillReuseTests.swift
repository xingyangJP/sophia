import Foundation
import MLXLMCommon  // `PrefillCacheLedger` が持つ `[KVCache]` の型に触るため
import XCTest

@testable import Sophia

// =============================================================================
//  プリフィルの再利用の判断（`MLXEngine.prefillReuseDecision`）
// -----------------------------------------------------------------------------
//  **このファイルは1バイトもモデルを読み込まない。**
//
//  ## 何を確かめているのか
//
//  前任者はこう書いて再利用を見送っていた:
//
//  > 書き戻した `<tool_call>` の綴りがモデルの出力と1文字でも違えば接頭辞が一致せず、
//  > **黙って壊れた再利用になるほうが怖い**
//
//  **懸念そのものは正しい。** このファイルが固定しているのは
//  「**綴りがずれたときに、ずれた先を使わないこと**」である。
//  ずれた瞬間に共通接頭辞が止まり、その先はキャッシュから捨てられる。
//
//  | 何を固定するか | どの章 |
//  |---|---|
//  | 一致した長さぶんだけ持ち越す（**値まで見る**） | 2章 |
//  | **綴りがずれたらそこで止まる**（前任者の懸念そのもの） | 3章 |
//  | 信用できないキャッシュは必ず作り直す | 4章 |
//  | 切ってあるときは何があっても作り直す | 1章 |
//  | 台帳が嘘をつかない（触る前に空にする） | 5章 |
//
//  ## 器が対象を測っているか（**先に確かめること**）
//
//  **テストの中に仮の定義を置いていない。** 呼んでいるのは
//  `MLXEngine.prefillReuseDecision` そのもの ── `MLXEngine.startPrefillRound` が
//  実行時に呼ぶのと**同じ関数**である。
//  本日、プローブが**テスト内の仮の定義**を測っていて「12/12 だから使える」が
//  実装の値ではなかった、という誤りが出ている。0章がその再発を潰す。
//
//  ## 何を確かめられないか（**ここを誤魔化さない**）
//
//  1. **KVキャッシュを実際に巻き戻していない。** `KVCache.trim(_:)` はモデルを
//     読み込まないと作れない。ここが見ているのは「何トークン巻き戻せと言うか」までで、
//     **言われたとおりに巻き戻るか**は実機の仕事である
//     （`MLXEngine.swift` 末尾「実機で確かめること」24〜28）。
//     実装側は戻り値と着地オフセットの**両方**を見て、合わなければ作り直しへ落ちる。
//  2. **巻き戻したキャッシュに継ぎ足した出力が正気かは見ていない。** これも実機。
//     だから既定は無効（`prefillReuseEnabledByDefault == false`）にしてある ── 0章で固定する。
// =============================================================================

final class PrefillReuseTests: XCTestCase {

    /// Qwen3 の描画を模した、意味のあるトークン列を作るための道具。
    /// 値そのものに意味は無いが、**列として区別が付くこと**が要る。
    private func tokens(_ range: ClosedRange<Int>) -> [Int] { Array(range) }

    // MARK: - 0章 既定と、器が対象を測っているか

    /// **既定は無効。** 実機で確かめるまで従来経路のままであること。
    ///
    /// ここが `true` に変わっているなら、それは**意図した変更**であるはずである
    /// （`MLXEngine.swift` 末尾 24〜28 を通したということ）。
    /// 黙って変わっていたら、この行が落ちて気付ける。
    func testDefaultIsDisabledUntilVerifiedOnDevice() {
        XCTAssertFalse(
            MLXEngine.prefillReuseEnabledByDefault,
            "実機で 24〜28 を通す前に既定を有効にしないこと")
    }

    /// **最小の再利用量が実装の値と一致していること。**
    /// テスト側で勝手な定数を使うと、実装が変わっても気付けない。
    func testMinimumReuseIsTakenFromTheImplementation() {
        XCTAssertEqual(MLXEngine.prefillReuseMinimumTokens, 128)
    }

    /// 共通接頭辞そのものの計算。**端の扱いを固定する。**
    func testCommonPrefixLength() {
        XCTAssertEqual(MLXEngine.commonPrefixLength([], []), 0)
        XCTAssertEqual(MLXEngine.commonPrefixLength([1, 2, 3], []), 0)
        XCTAssertEqual(MLXEngine.commonPrefixLength([], [1, 2, 3]), 0)
        XCTAssertEqual(MLXEngine.commonPrefixLength([1, 2, 3], [1, 2, 3]), 3)
        XCTAssertEqual(MLXEngine.commonPrefixLength([1, 2, 3], [1, 2, 3, 4, 5]), 3)
        XCTAssertEqual(MLXEngine.commonPrefixLength([1, 2, 3, 4], [1, 2, 9, 4]), 2)
        // **先頭で外れる。** ここを 1 と数える実装だと、丸ごと別物を再利用してしまう。
        XCTAssertEqual(MLXEngine.commonPrefixLength([9, 2, 3], [1, 2, 3]), 0)
    }

    // MARK: - 1章 切ってあるときは何があっても作り直す

    /// `enabled: false` なら、**どれだけ都合よく一致していても**作り直す。
    /// `SOPHIA_PREFILL_REUSE=0` が本当に従来経路へ戻ることの担保である。
    func testDisabledAlwaysRebuilds() {
        let cached = tokens(1...500)
        let decision = MLXEngine.prefillReuseDecision(
            enabled: false,
            cachedTokens: cached,
            promptTokens: cached + tokens(501...800),
            cacheOffset: 500,
            cacheIsTrimmable: true)

        XCTAssertEqual(decision, .rebuild("off"))
        XCTAssertEqual(decision.reusedTokens, 0)
        XCTAssertEqual(decision.trimmedTokens, 0)
    }

    // MARK: - 2章 一致した長さぶんだけ持ち越す

    /// **実測どおりの形。** 1周目 459 トークンを払い、そのままの接頭辞に
    /// ツールの往復ぶんが足されて 1271 になる。
    ///
    /// 生成が乗っているぶん（ここでは 40）はキャッシュのオフセットが先へ進んでいるので、
    /// **巻き戻し量にそれが含まれること**まで見る。
    func testExtendedPromptReusesThePrefixAndTrimsTheGeneratedTail() {
        let firstRound = tokens(1...459)
        let secondRound = firstRound + tokens(1000...1811)  // 459 + 812 = 1271

        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: firstRound,
            promptTokens: secondRound,
            cacheOffset: 459 + 40,  // 1周目の生成が 40 トークン乗っている
            cacheIsTrimmable: true)

        // 生成ぶんの 40 だけ巻き戻して、459 を丸ごと持ち越す。
        XCTAssertEqual(decision, .trimThenAppend(reuse: 459, trim: 40))
        XCTAssertEqual(decision.reusedTokens, 459)
        XCTAssertEqual(decision.trimmedTokens, 40)
        XCTAssertEqual(decision.logName, "trim_append")

        // **払う量が実測どおり減っていること。** ここが直した目的そのものである。
        XCTAssertEqual(secondRound.count - decision.reusedTokens, 812)
    }

    /// 生成が1トークンも乗っていない（オフセットが台帳ちょうど）なら巻き戻しは要らない。
    func testExactOffsetAppendsWithoutTrimming() {
        let cached = tokens(1...459)
        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: cached,
            promptTokens: cached + tokens(1000...1200),
            cacheOffset: 459,
            cacheIsTrimmable: true)

        XCTAssertEqual(decision, .append(reuse: 459))
        XCTAssertEqual(decision.trimmedTokens, 0)
        XCTAssertEqual(decision.logName, "append")
    }

    // MARK: - 3章 綴りがずれたらそこで止まる（**前任者の懸念そのもの**）

    /// **書き戻した `<tool_call>` の綴りがモデルの出力と違った場合。**
    ///
    /// 1周目の末尾（`assistant\n` の直後）でトークン化の境目が動き、
    /// 描画し直したプロンプトが**末尾5トークンだけ食い違う**状況を作る。
    ///
    /// 期待するのは「食い違った 5 は使わない」であり、
    /// **食い違いを跨いで 459 まで持ち越さないこと**である。
    func testDivergentTailIsNeverReusedPastTheDivergence() {
        let shared = tokens(1...454)
        let cached = shared + [9001, 9002, 9003, 9004, 9005]  // モデルが実際に出した綴り
        let reRendered = shared + [7001, 7002, 7003, 7004, 7005]  // テンプレートの描き直し
        let prompt = reRendered + tokens(2000...2400)

        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: cached,
            promptTokens: prompt,
            cacheOffset: 459 + 30,
            cacheIsTrimmable: true)

        // 一致しているのは 454 まで。**455 以降は1トークンも使わない。**
        XCTAssertEqual(decision.reusedTokens, 454)
        // 巻き戻すのは「食い違った 5」＋「生成が乗った 30」＝ 35。
        XCTAssertEqual(decision, .trimThenAppend(reuse: 454, trim: 35))

        // 持ち越した長さが、両者が本当に一致している範囲を超えていないこと。
        XCTAssertEqual(
            Array(cached.prefix(decision.reusedTokens)),
            Array(prompt.prefix(decision.reusedTokens)),
            "持ち越した接頭辞が一致していない ＝ 黙って壊れた再利用")
    }

    /// **食い違いが先頭近くで起きた場合**（system プロンプトが変わった、
    /// 第2段の縮約が古い読み取りを栞へ落とした、など）。
    /// 端数を持ち越しても得が無いので作り直す。
    func testDivergenceNearTheHeadRebuilds() {
        let cached = [1, 2, 3] + tokens(100...500)
        let prompt = [1, 2, 9] + tokens(600...1000)

        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: cached,
            promptTokens: prompt,
            cacheOffset: cached.count,
            cacheIsTrimmable: true)

        XCTAssertEqual(decision, .rebuild("short_prefix"))
        XCTAssertEqual(decision.reusedTokens, 0)
    }

    /// 一致がちょうど下限に届いたら使う。届かなければ使わない。**境目を固定する。**
    func testMinimumReuseBoundary() {
        let shared = tokens(1...MLXEngine.prefillReuseMinimumTokens)

        let atLimit = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: shared,
            promptTokens: shared + tokens(9000...9100),
            cacheOffset: shared.count,
            cacheIsTrimmable: true)
        XCTAssertEqual(atLimit, .append(reuse: MLXEngine.prefillReuseMinimumTokens))

        let belowLimit = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: Array(shared.dropLast()),
            promptTokens: Array(shared.dropLast()) + tokens(9000...9100),
            cacheOffset: shared.count - 1,
            cacheIsTrimmable: true)
        XCTAssertEqual(belowLimit, .rebuild("short_prefix"))
    }

    // MARK: - 4章 信用できないキャッシュは必ず作り直す

    /// 冷えている（台帳が空）。1周目は必ずここを通る。
    func testColdCacheRebuilds() {
        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: [],
            promptTokens: tokens(1...459),
            cacheOffset: 0,
            cacheIsTrimmable: true)

        XCTAssertEqual(decision, .rebuild("cold"))
    }

    /// **中断や失敗で払い切れなかったキャッシュ。**
    /// オフセットが台帳より手前にある ＝ 台帳の後半が本当に載っているか言えない。
    func testCacheShorterThanTheLedgerRebuilds() {
        let cached = tokens(1...1271)
        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: cached,
            promptTokens: cached + tokens(2000...2100),
            cacheOffset: 512,  // プリフィルの刻み目で中断された
            cacheIsTrimmable: true)

        XCTAssertEqual(decision, .rebuild("short_cache"))
    }

    /// 層ごとにオフセットが揃っていない（`nil` で届く）。どこまで正しいか言えない。
    func testMisalignedOffsetRebuilds() {
        let cached = tokens(1...459)
        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: cached,
            promptTokens: cached + tokens(2000...2100),
            cacheOffset: nil,
            cacheIsTrimmable: true)

        XCTAssertEqual(decision, .rebuild("no_offset"))
    }

    /// 巻き戻せないキャッシュ（`RotatingKVCache` が窓を越えている等）で、
    /// **巻き戻しが要る**状況。使えないので作り直す。
    func testNonTrimmableCacheRebuildsWhenTrimmingIsRequired() {
        let cached = tokens(1...459)
        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: cached,
            promptTokens: cached + tokens(2000...2100),
            cacheOffset: 459 + 40,  // 生成が乗っている ＝ 巻き戻しが要る
            cacheIsTrimmable: false)

        XCTAssertEqual(decision, .rebuild("not_trimmable"))
    }

    /// 巻き戻しが**要らない**なら、巻き戻せなくても継ぎ足せる。
    func testNonTrimmableCacheStillAppendsWhenNoTrimIsNeeded() {
        let cached = tokens(1...459)
        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: cached,
            promptTokens: cached + tokens(2000...2100),
            cacheOffset: 459,
            cacheIsTrimmable: false)

        XCTAssertEqual(decision, .append(reuse: 459))
    }

    /// **プロンプトがキャッシュに丸ごと含まれてしまった。**
    /// 払うトークンが1つも残らず、最初のフォワードが打てない。
    func testPromptFullyContainedInCacheRebuilds() {
        let cached = tokens(1...800)
        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: cached,
            promptTokens: Array(cached.prefix(500)),
            cacheOffset: 800,
            cacheIsTrimmable: true)

        XCTAssertEqual(decision, .rebuild("no_new_tokens"))
    }

    /// 台帳とプロンプトが完全一致（同じ問いを2度）。これも払うぶんが残らない。
    func testIdenticalPromptRebuilds() {
        let cached = tokens(1...459)
        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: cached,
            promptTokens: cached,
            cacheOffset: 459,
            cacheIsTrimmable: true)

        XCTAssertEqual(decision, .rebuild("no_new_tokens"))
    }

    /// 空のプロンプト。**そもそも描画に失敗している**ので触らない。
    func testEmptyPromptRebuilds() {
        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: tokens(1...459),
            promptTokens: [],
            cacheOffset: 459,
            cacheIsTrimmable: true)

        XCTAssertEqual(decision, .rebuild("empty_prompt"))
    }

    // MARK: - 5章 台帳が嘘をつかない

    /// 書いたものがそのまま読めること。**当たり前を固定する**
    /// （台帳が読めなければ、接頭辞の比較そのものが成立しない）。
    func testLedgerStoresAndReadsTokens() {
        let ledger = PrefillCacheLedger()
        XCTAssertTrue(ledger.read().tokens.isEmpty)
        XCTAssertTrue(ledger.read().cache.isEmpty)

        ledger.store(cache: [], tokens: tokens(1...459))
        XCTAssertEqual(ledger.read().tokens, tokens(1...459))
    }

    /// **空にしたら冷えた扱いになること。**
    ///
    /// これが `startPrefillRound` の安全弁である ── キャッシュに触る前に
    /// `clear()` を呼んでおけば、途中で throw しても残るのは
    /// 「中身の分からないキャッシュ」ではなく「台帳の無いキャッシュ」になる。
    /// 次の周は必ず `cold` で作り直しに落ちる。
    func testClearedLedgerForcesRebuild() {
        let ledger = PrefillCacheLedger()
        ledger.store(cache: [], tokens: tokens(1...459))
        ledger.clear()

        XCTAssertTrue(ledger.read().tokens.isEmpty)

        let decision = MLXEngine.prefillReuseDecision(
            enabled: true,
            cachedTokens: ledger.read().tokens,
            promptTokens: tokens(1...1271),
            cacheOffset: 459,
            cacheIsTrimmable: true)
        XCTAssertEqual(decision, .rebuild("cold"))
    }

    // MARK: - 6章 ログに出る形

    /// `[PREFILL] decision=` に出る名前と理由。**意味を変えないこと**
    /// （過去のログが読めなくなる）。
    func testLogNamesAndReasons() {
        XCTAssertEqual(PrefillReuseDecision.rebuild("off").logName, "rebuild")
        XCTAssertEqual(PrefillReuseDecision.rebuild("off").logReason, "off")
        XCTAssertEqual(PrefillReuseDecision.append(reuse: 10).logName, "append")
        XCTAssertEqual(PrefillReuseDecision.append(reuse: 10).logReason, "-")
        XCTAssertEqual(
            PrefillReuseDecision.trimThenAppend(reuse: 10, trim: 2).logName, "trim_append")
        XCTAssertEqual(
            PrefillReuseDecision.trimThenAppend(reuse: 10, trim: 2).logReason, "-")
    }

    /// **`fed` と `reused` の和が `prompt` になること。**
    /// `[PREFILL]` 行の3つの数が閉じていなければ、読み手は差を信用できない。
    func testFedPlusReusedEqualsPromptForEveryDecision() {
        let cached = tokens(1...459)
        let prompt = cached + tokens(2000...2400)

        for offset in [459, 459 + 40] {
            let decision = MLXEngine.prefillReuseDecision(
                enabled: true,
                cachedTokens: cached,
                promptTokens: prompt,
                cacheOffset: offset,
                cacheIsTrimmable: true)

            let fed = prompt.count - decision.reusedTokens
            XCTAssertEqual(fed + decision.reusedTokens, prompt.count)
            XCTAssertGreaterThan(fed, 0, "払うトークンが0だと最初のフォワードが打てない")
        }
    }
}
