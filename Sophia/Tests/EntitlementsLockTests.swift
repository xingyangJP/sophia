import Foundation
import XCTest
@testable import Sophia

// =============================================================================
//  entitlements の実物と、文書の記述を結び付ける錠（R10 / R12）
// -----------------------------------------------------------------------------
//  ## なぜ要るか ── 2026-08-23 に【確認済】の印が付いた嘘が見つかった
//
//  `5acbb9c` が `Sophia.entitlements` を `files.user-selected.read-only` から
//  **`read-write`** へ変えた。ところが DESIGN.md は3か所で `read-only` と書いたまま
//  残り、そのうち1か所には **【確認済 / `Sophia/Sophia.entitlements`】の印**が付いていた。
//
//  | 場所 | 何と書いてあったか |
//  |---|---|
//  | DESIGN:1736 | 「**Sophia の現物**は3つ」として `read-only` を引用 |
//  | DESIGN:3121-3123 | 「**OS の制約が境界を守っている。事故で書き込みが通る経路が存在しない**」 |
//  | DESIGN:3337 / :3340 | **【確認済】の印つきの表**に `read-only` = true |
//
//  **安全の論拠がクラスごと変わっていた。**
//  以前は OS（破るには再署名・公証が要る）、いまはアプリ内の承認フロー
//  （破るにはコードの欠陥1つで足りる）。**文書だけが古い状態を守っていた。**
//
//  ## なぜ DESIGN.md をパースしないか
//
//  **markdown を読む試験は、対象より先に器が壊れる。**
//  同じ日に、字句解析で `func test` を数える器がテスト7本を飲み込み、
//  同名テスト2組を潰して「一致」と報告している（`scripts/audit-tests.py` の履歴）。
//  **文書の側を読みにいくと、書き換えのたびに器が誤爆する。**
//
//  **だから実物だけを固定し、文書の場所は失敗文で名指しする。**
//  entitlement を変えた人は必ず赤を見て、**直すべき場所を渡される。**
//
//  ## この錠が守っているのは値ではなく「結び付き」である
//
//  鍵が増減しても減っても落ちる（等値で固定してある）。
//  **緑に戻す正しい手順は、下の一覧を直すと同時に、失敗文が挙げる文書を直すことである。**
//  **一覧だけを書き換えて緑にした瞬間、文書はまた古くなる。**
final class EntitlementsLockTests: XCTestCase {

    /// リポジトリ内の `Sophia/Sophia.entitlements`。
    ///
    /// **`#filePath` から辿るのは、テストバンドルの中に entitlements が入らないからである。**
    /// （入るのは署名済みバイナリの側で、plist そのものは製品に含まれない。）
    private var entitlementsURL: URL {
        URL(fileURLWithPath: #filePath)      // …/Sophia/Tests/EntitlementsLockTests.swift
            .deletingLastPathComponent()     // …/Sophia/Tests
            .deletingLastPathComponent()     // …/Sophia
            .appendingPathComponent("Sophia.entitlements")
    }

    /// **実物の鍵の集合を等値で固定する。**
    func testTheEntitlementKeysAreExactlyWhatTheDocumentsDescribe() throws {
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            "entitlements が辞書として読めない。**0件を『鍵が無い』と読まないこと** ── これは故障である")

        // **前提: 空でないこと。** 読めなかった場合に「鍵が0個で一致」と言わせない。
        XCTAssertFalse(plist.isEmpty, "器の欠陥: 鍵が1つも取れていない（読み取り経路を疑うこと）")

        XCTAssertEqual(
            Set(plist.keys),
            [
                "com.apple.security.app-sandbox",
                "com.apple.security.network.client",
                "com.apple.security.files.user-selected.read-write",
            ],
            """
            **entitlements が変わった。文書のほうも古くなっている可能性が高い。**
            次の場所が entitlement の値を直接引用しているので、**同時に直すこと**:

                docs/DESIGN.md:1736        「Sophia の現物は3つ」の引用
                docs/DESIGN.md:3121-3123   「OS の制約が境界を守っている」
                docs/DESIGN.md:3337 / 3340 【確認済】の印が付いた表
                README.md                  会話が端末の外に出るかの記述

            **この一覧だけを書き換えて緑に戻さないこと**（R12）──
            印は読む人から「確かめる動機」を奪う。奪った以上、
            **印を付けた側が代わりに確かめ続ける義務を負う。**
            """)
    }

    /// **`read-write` であること自体を、名指しで表明しておく。**
    ///
    /// 上の等値表明があれば集合としては捕まるが、
    /// **「いま書き込みを止めているのは OS ではない」という事実は、
    /// 名指しで1本置いておかないと読み落とされる。**
    func testWritingIsNoLongerBlockedByTheOperatingSystem() throws {
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        XCTAssertNil(
            plist["com.apple.security.files.user-selected.read-only"],
            "read-only へ戻ったなら、DESIGN の記述が正しくなったということ。この試験ごと見直すこと")
        XCTAssertEqual(
            plist["com.apple.security.files.user-selected.read-write"] as? Bool, true,
            """
            **書き込みを止めているのは OS ではなくアプリ内の承認フローである。**
            `FolderToolRunner+Executing` / `WorkspaceGit` の承認と TOCTOU 検査が唯一の砦であり、
            **コードの欠陥1つで破れる。** DESIGN:3123 の「事故で書き込みが通る経路が存在しない」は
            この entitlement を前提にした記述で、いまは成り立たない。
            """)
    }
}
