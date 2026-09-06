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
    static func logLine(directory: URL, adaptedModules: Int) -> String {
        "[ADAPTER] event=loaded modules=\(adaptedModules) "
            + "path=\(ToolLogValue.sanitized(directory.lastPathComponent))"
    }
}
