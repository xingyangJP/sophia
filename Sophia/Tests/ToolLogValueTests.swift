import Foundation
import XCTest

@testable import Sophia

/// `[TOOL]` 行へ出す値の防御（`ToolLogValue`）。
///
/// ## この2本は 68d1b32 まで**1度も実行されていなかった**
///
/// 元は `AdversarialRoundTripTests.swift` の末尾にあったが、
/// **`private actor ScriptedExecutor` の内側に入っていた。**
/// XCTest が拾うのは `XCTestCase` のサブクラスのメソッドだけなので、
/// 定義はあるのに永久に走らない状態だった ── **緑のまま、1度も確かめられていない。**
///
/// 原因は書き手の不注意ではなく**置き場所が無かったこと**である。
/// 検証役が `MLXEngine` の中の `private func sanitize` を読んで穴を見つけ、
/// `ToolLogValue` へ切り出して試験可能にしたところまでは正しく、
/// **切り出した先の置き場所を作らずに、近くのファイルの末尾へ足した。**
/// だから同じことがまた起きないよう、専用のクラスをここに立ててある。
/// **`ToolLogValue` の試験はここへ足すこと。**
///
/// 見つけ方も残しておく。**人が読んで見つけたのであって、仕組みで捕まえたのではない。**
/// 静的に宣言されたテスト名の集合と、xcresult に現れたテスト名の集合を突き合わせると、
/// この2本だけが差として出た（移設前: 静的494 対 実行時492）。
/// その突き合わせを常時回す仕掛けが R9 である。
///
/// ## 何を守っているか
///
/// `[TOOL]` 行に出るのは**モデルが書いた文字列**で、行き先は stderr ──
/// **人が見ている端末**である。ANSI エスケープが素通りすれば画面の消去も色の変更も、
/// U+202E による**行の見た目の反転**もできる。
/// つまりこれは「ログの体裁」の話ではなく、**モデルが開発者の画面に書けるかどうか**の話である。
///
/// > **`ToolText.singleLine` は Cf（U+202E 等）をわざと残している。宛先が違うからである** ──
/// > あちらはモデルへ渡す文で、こちらは端末へ出す文。**同じ規則にしないこと。**
final class ToolLogValueTests: XCTestCase {

    /// **モデルが書いた文字列で開発者の端末を制御できないこと。**
    ///
    /// 以前の `sanitize` は `CharacterSet.whitespacesAndNewlines` しか見ておらず、
    /// **`\u{1B}` も `\u{7}` も U+202E も通していた。**
    func testTheToolLogValueStripsEscapesAndCountsScalars() {
        let hostile = "read\u{001B}[2Kfile\u{0007}\u{202E}evil\u{200B}"

        let safe = ToolLogValue.sanitized(hostile)

        for scalar in safe.unicodeScalars {
            let category = scalar.properties.generalCategory
            XCTAssertNotEqual(category, .control, "制御文字が残った: U+\(String(scalar.value, radix: 16))")
            XCTAssertNotEqual(category, .format, "書式文字が残った: U+\(String(scalar.value, radix: 16))")
            XCTAssertNotEqual(category, .spaceSeparator, "空白が残った")
        }
    }

    /// **長さの上限がスカラー単位であること**（書記素だと1文字で1万バイト運べた）。
    ///
    /// **バイト数まで見ているのが要点である。** 「64文字に切った」という申告が
    /// **バイトの側でも成り立つ**ことを確かめる ── UTF-8 は1スカラー最大4バイトなので、
    /// スカラーで抑えればバイトの上端も決まる。**片方だけ見ると、また同じ穴が開く。**
    func testTheToolLogValueCannotBeInflatedByCombiningMarks() {
        let combining = "a" + String(repeating: "\u{0301}", count: 5_000)
        XCTAssertEqual(combining.count, 1, "前提: 書記素では1文字に見える")

        let safe = ToolLogValue.sanitized(combining)

        XCTAssertLessThanOrEqual(safe.unicodeScalars.count, ToolLogValue.limit)
        XCTAssertLessThanOrEqual(
            safe.utf8.count, ToolLogValue.limit * 4,
            "スカラーで抑えてもバイトが溢れた")
    }
}
