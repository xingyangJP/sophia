import Foundation

// =============================================================================
//  焼いた重みをアプリへ載せる（ADAPTER_01 / PHILOSOPHY の仮説の第一号）
// -----------------------------------------------------------------------------
//  **いま Sophia が「私はソフィアです」と言えるのは、毎ターン system プロンプトを
//  送っているからである**（`SophiaDefaults.systemPrompt` / FR-23）。
//  名前が外付けであり、これが「モデル名が先行している」状態そのものである。
//
//  重みへ移すと3つ同時に起きる ── 自分の重みを持つ／毎ターンの約97トークンが消える／
//  「その人のことは重みに焼く。毎ターン0」が最小の形で1回通る。
//
//  この層が持つのは**判断だけ**で、MLX の型を知らない。
//  実際に載せるのは `MLXEngine`（あちらだけが `LanguageModel` を触れる）。
// =============================================================================

/// アダプタの形式。**推測しない。ディレクトリの中身で決める。**
///
/// ## なぜ判別が要るのか ── **焼いた重みが読み込みの1行目で落ちる**
///
/// MLX には入口が2つあり、**期待するファイル名が違う。**
///
/// | | 重みのファイル名 | `adapter_config.json` のスキーマ | 鍵の名前 |
/// |---|---|---|---|
/// | `LoRAContainer.from(directory:)` | **`adapters.safetensors`** | `LoRAConfiguration`（MLX 自身） | MLX 名のまま |
/// | `LoRAContainer.fromPEFT(directory:)` | **`adapter_model.safetensors`** | PEFT（`peft_type` / `r` / `lora_alpha`） | PEFT 名 → 変換 |
///
/// **`LoRATrain.saveLoRAWeights` が出すのは MLX 名の鍵**なので、
/// **我々が焼いたものは `fromPEFT` では読めない。**
/// 最初の実装は `fromPEFT` を主経路にしていた ──
/// **70分かけて焼いた重みが、読み込みの1行目で落ちるところだった**（監督の指摘 / 2026-09-06）。
///
/// ## 設定ファイルの有無では判別できない
///
/// **両方とも `adapter_config.json` という同じ名前を使う。** 中のスキーマだけが違う。
/// だから**重みのファイル名で判別する。** 名前が違うのは、ここだけである。
///
/// > **「分からないので PEFT を試す」はやらない。** 失敗したとき、
/// > 「形式が違う」のか「中身が壊れている」のかが分からなくなる。
enum AdapterFormat: String, Sendable, Equatable, CaseIterable {

    /// 我々の学習が吐く形式（`LoRATrain.saveLoRAWeights` + `LoRAConfiguration`）。
    case native

    /// 外から持ってきたもの。**HuggingFace にある LoRA はほぼこれ。**
    case peft

    var weightsFileName: String {
        switch self {
        case .native: "adapters.safetensors"
        case .peft: "adapter_model.safetensors"
        }
    }

    static let configurationFileName = "adapter_config.json"

    /// ディレクトリの中身から決める。**どちらでもなければ nil。**
    static func detect(in names: Set<String>) -> AdapterFormat? {
        if names.contains(AdapterFormat.native.weightsFileName) { return .native }
        if names.contains(AdapterFormat.peft.weightsFileName) { return .peft }
        return nil
    }
}

/// アダプタを載せたあとの検算。
///
/// ## なぜ数えるのか ── **0層でも例外が上がらない経路がある**
///
/// `LoRAContainer.from` は**対象層が0でも例外を投げない。**
/// そのまま学習が通り、**「軽くて速い」という嘘の数字が出る**（PROGRESS の R8 の実例）。
/// 推論側で `load(adapter:)` を使っても**同じ器を通るので、同じ穴が開く。**
///
/// **`adapted_modules = 0` を「成功」として通す経路を1本も残さないこと。**
/// 0 で通すと、**アダプタを載せたつもりで素のモデルが答え、
/// それを「重みに焼けた」と読む**ことになる ── 仮説そのものを偽装する形の嘘になる。
enum AdapterApplication {

    /// 載った層の数を検算する。**0 なら失敗として投げる。**
    ///
    /// - Parameters:
    ///   - adaptedModules: `LoRALayer` に置き換わったモジュールの数。
    ///   - directory: どのアダプタを載せようとしたか。**失敗の文に必ず入れる** ──
    ///     入れないと、複数のアダプタを試している最中にどれが空振りしたか分からない。
    static func verify(adaptedModules: Int, directory: URL) throws {
        guard adaptedModules > 0 else {
            throw SophiaError(
                code: .modelLoadFailed,
                message: "アダプタを読み込みましたが、1つの層にも適用されませんでした。",
                hint: "アダプタの層の指定（adapter_config.json の target_modules / num_layers）が"
                    + "モデルの構造と合っているか確認してください。",
                detail: "adapter=\(directory.path) adapted_modules=0")
        }
    }

    /// `[ADAPTER]` の1行。**`[LOAD]` / `[MEM]` / `[STATS]` と同じ経路・同じ `key=value`。**
    ///
    /// **載った層の数を必ず出す。** ここが 0 でないことが、
    /// 「重みが効いている」と言える唯一の根拠である。
    static func logLine(
        directory: URL, adaptedModules: Int, format: AdapterFormat = .native
    ) -> String {
        // **形式も出す。** 同じディレクトリ名で形式だけ違うものを試すことがあり、
        // どちらの経路で読んだかが後から分からないと、失敗の切り分けができない。
        "[ADAPTER] event=loaded format=\(format.rawValue) modules=\(adaptedModules) "
            + "path=\(ToolLogValue.sanitized(directory.lastPathComponent))"
    }

    /// 形式が分からないときの失敗。**中身を丸ごと文に入れる。**
    ///
    /// 「どちらの形式でもない」とだけ言われても、次に何をすればいいか分からない。
    /// **実際に何が入っていたかを見せる**（R7 ── 合わないときは推測で埋めず実物を出す）。
    static func unknownFormat(directory: URL, names: Set<String>) -> SophiaError {
        let listing = names.sorted().prefix(12).joined(separator: ", ")
        return SophiaError(
            code: .modelLoadFailed,
            message: "アダプタの形式が分かりません。",
            hint: "MLX 形式なら \(AdapterFormat.native.weightsFileName)、"
                + "PEFT 形式なら \(AdapterFormat.peft.weightsFileName) が要ります。",
            detail: "adapter=\(directory.path) contents=[\(listing)]")
    }
}
