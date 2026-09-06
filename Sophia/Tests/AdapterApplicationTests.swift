import Foundation
import XCTest

@testable import Sophia

/// 焼いた重みが**本当に載ったか**の検算（ADAPTER_01）。
///
/// ## ここが守っているのは「仮説そのものが偽装されないこと」である
///
/// `LoRAContainer.from` は**対象層が0でも例外を投げない**（PROGRESS の R8 の実例）。
/// そのまま学習が通り「軽くて速い」という嘘の数字が出た、という記録がある。
/// **推論側で `load(adapter:)` を使っても同じ器を通るので、同じ穴が開く。**
///
/// 0層で通してしまうと、**アダプタを載せたつもりで素のモデルが答え、
/// それを「重みに焼けた」と読む。** 速度も品質も「載せた」条件として記録される。
/// **測定の誤りではなく、仮説の実演そのものが偽物になる。**
final class AdapterApplicationTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/tmp/sophia-adapter-01", isDirectory: true)

    /// **0層は失敗である。** 例外が上がらないことを「成功」と読まない。
    func testZeroAdaptedModulesIsAFailure() {
        XCTAssertThrowsError(
            try AdapterApplication.verify(adaptedModules: 0, directory: directory)
        ) { error in
            guard let failure = error as? SophiaError else {
                return XCTFail("SophiaError ではない: \(error)")
            }
            XCTAssertEqual(failure.code, .modelLoadFailed)
            // **どのアダプタが空振りしたかを文に残すこと。**
            // 複数を試している最中に、どれが載らなかったか分からなくなる。
            XCTAssertTrue(
                (failure.detail ?? "").contains("sophia-adapter-01"),
                "失敗の文にアダプタの場所が入っていない: \(failure.detail ?? "-")")
            XCTAssertTrue(
                (failure.detail ?? "").contains("adapted_modules=0"),
                "何層載ったのかが文に残っていない")
        }
    }

    /// 1層でも載っていれば通す。**「多いほど良い」を判定に混ぜない** ──
    /// 何層が適切かはアダプタの設計次第で、この層が決めることではない。
    func testASingleAdaptedModuleIsEnoughToPass() {
        XCTAssertNoThrow(
            try AdapterApplication.verify(adaptedModules: 1, directory: directory))
        XCTAssertNoThrow(
            try AdapterApplication.verify(adaptedModules: 224, directory: directory))
    }

    /// **載った層の数がログに出ること。**
    ///
    /// ここが 0 でないことが「重みが効いている」と言える唯一の根拠なので、
    /// **数がログに出ていなければ、後から根拠を示せない**
    /// （取得の見張りで「どちらの信号が死んでいたか追えなかった」のと同じ形）。
    func testTheLogLineCarriesTheNumberOfAdaptedModules() {
        let line = AdapterApplication.logLine(directory: directory, adaptedModules: 224)

        XCTAssertTrue(line.hasPrefix("[ADAPTER] "), "他のログ行と同じ経路・同じ形にすること")
        XCTAssertTrue(line.contains("modules=224"), "載った層の数が出ていない")
        XCTAssertTrue(line.contains("sophia-adapter-01"), "どのアダプタか分からない")
    }

    /// ログ行に**空白を持ち込まないこと。** `key=value` の区切りが壊れる。
    ///
    /// アダプタの置き場所は利用者が決めるので、**名前に空白も制御文字も入りうる。**
    func testAHostileAdapterNameCannotBreakTheLogLine() {
        let hostile = URL(
            fileURLWithPath: "/tmp/adapter name\u{001B}[2K\u{202E}evil", isDirectory: true)
        let line = AdapterApplication.logLine(directory: hostile, adaptedModules: 8)

        let fields = line.dropFirst("[ADAPTER] ".count).split(separator: " ")
        XCTAssertEqual(fields.count, 3, "空白が混ざって key=value が割れている: \(line)")
        for scalar in line.unicodeScalars {
            let category = scalar.properties.generalCategory
            XCTAssertNotEqual(category, .control, "制御文字が残った")
            XCTAssertNotEqual(category, .format, "書式文字が残った（行の見た目を反転できる）")
        }
    }
}
