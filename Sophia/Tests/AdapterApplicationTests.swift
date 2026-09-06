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
        // event / format / modules / path の4つ。**数を書いてあるのは意図的である** ──
        // 項目を足したときに、この表明が「足したこと」を必ず知らせる。
        XCTAssertEqual(fields.count, 4, "空白が混ざって key=value が割れている: \(line)")
        for scalar in line.unicodeScalars {
            let category = scalar.properties.generalCategory
            XCTAssertNotEqual(category, .control, "制御文字が残った")
            XCTAssertNotEqual(category, .format, "書式文字が残った（行の見た目を反転できる）")
        }
    }

    // =========================================================================
    //  形式の判別 —— **焼いた重みが読み込みの1行目で落ちるのを防ぐ**
    // =========================================================================
    //
    //  MLX には入口が2つあり、期待する重みのファイル名が違う。
    //  `LoRATrain.saveLoRAWeights` が出すのは MLX 名の鍵なので、
    //  **我々が焼いたものは `fromPEFT` では読めない。**
    //  最初の実装は `fromPEFT` を主経路にしていた（監督の指摘で判明）。

    /// **設定ファイルでは判別できない。** 両方とも `adapter_config.json` を使う。
    func testTheConfigurationFileNameIsTheSameForBothFormats() {
        XCTAssertEqual(AdapterFormat.configurationFileName, "adapter_config.json")
        // 判別に使えるのは重みの名前だけ、という事実をここで固定する。
        XCTAssertNotEqual(
            AdapterFormat.native.weightsFileName, AdapterFormat.peft.weightsFileName)
    }

    /// 我々の学習が吐く形式を native と読むこと。
    func testOurOwnTrainingOutputIsDetectedAsNative() {
        let names: Set<String> = ["adapters.safetensors", "adapter_config.json"]
        XCTAssertEqual(AdapterFormat.detect(in: names), .native)
    }

    /// 外から持ってきたものを PEFT と読むこと。
    func testAnExternalAdapterIsDetectedAsPEFT() {
        let names: Set<String> = ["adapter_model.safetensors", "adapter_config.json", "README.md"]
        XCTAssertEqual(AdapterFormat.detect(in: names), .peft)
    }

    /// **どちらでもなければ nil。** 「分からないので PEFT を試す」をしない ──
    /// 失敗したとき、形式が違うのか中身が壊れているのかが分からなくなる。
    func testAnUnknownLayoutIsNotGuessedAtAllPEFT() {
        XCTAssertNil(AdapterFormat.detect(in: ["adapter_config.json"]))
        XCTAssertNil(AdapterFormat.detect(in: []))
        XCTAssertNil(AdapterFormat.detect(in: ["model.safetensors"]))
    }

    /// **どちらも在るときは native を採る。** 我々が焼いたものを優先する
    /// （`fromPEFT` は鍵を変換するので、MLX 名の鍵には当たらない）。
    func testNativeWinsWhenBothArePresent() {
        let names: Set<String> = ["adapters.safetensors", "adapter_model.safetensors"]
        XCTAssertEqual(AdapterFormat.detect(in: names), .native)
    }

    /// **分からないときの失敗は、実際に何が入っていたかを見せること**（R7）。
    func testTheUnknownFormatFailureShowsWhatWasActuallyThere() {
        let error = AdapterApplication.unknownFormat(
            directory: directory, names: ["config.json", "weights.bin"])

        XCTAssertEqual(error.code, .modelLoadFailed)
        let detail = error.detail ?? ""
        XCTAssertTrue(detail.contains("weights.bin"), "中身が文に出ていない: \(detail)")
        XCTAssertTrue(detail.contains("sophia-adapter-01"), "どのディレクトリか分からない")
        XCTAssertTrue(
            (error.hint ?? "").contains("adapters.safetensors"),
            "何を用意すればいいかが書かれていない")
    }

    /// ログ行に**どちらの経路で読んだか**が出ること。
    func testTheLogLineCarriesWhichFormatWasUsed() {
        let native = AdapterApplication.logLine(
            directory: directory, adaptedModules: 224, format: .native)
        let peft = AdapterApplication.logLine(
            directory: directory, adaptedModules: 224, format: .peft)

        XCTAssertTrue(native.contains("format=native"))
        XCTAssertTrue(peft.contains("format=peft"))
    }
}
