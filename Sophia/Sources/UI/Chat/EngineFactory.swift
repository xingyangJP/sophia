import Foundation

/// **エンジンを誰が作るかを1か所に決める（composition root）。**
///
/// 3人が別々に `StubEngine()` や `MLXEngine()` を書き始めると、
/// 同じモデルが2回メモリに載る。16GB機ではそれだけで壊れる。
/// エンジンの実体を作ってよいのはここだけで、保持するのは `ChatViewModel` だけ。
///
/// ## MLX 実装を足すときにやること
///
/// この関数の `return` を差し替えるだけでよい。**UI 側のコードは1行も変わらない**
/// （UI は `InferenceEngine` の型しか知らないため。NFR-09）。
enum EngineFactory {

    /// 本番で使うエンジン。**既定は MLX（本物の推論）。**
    ///
    /// 差し替えは環境変数で行う。既定を偽物にしておくと
    /// 「動いているように見えて実は Stub だった」が起きるので、既定は本物にする。
    ///
    /// | 環境変数 | 効果 |
    /// |---|---|
    /// | `SOPHIA_ENGINE=stub` | `StubEngine`。モデルもGPUも使わない |
    /// | `SOPHIA_UI_MOCK=rich` 等 | `MockEngine`。描画確認用（DEBUG のみ） |
    ///
    /// 例) `SOPHIA_ENGINE=stub /path/to/Sophia.app/Contents/MacOS/Sophia`
    static func makeDefault() -> any InferenceEngine {
        let environment = ProcessInfo.processInfo.environment

        #if DEBUG
        // 描画確認用。`SOPHIA_UI_MOCK=rich` などを付けて起動すると差し替わる。
        // 例) SOPHIA_UI_MOCK=rich Sophia.app/Contents/MacOS/Sophia
        if let name = environment["SOPHIA_UI_MOCK"],
           let scenario = MockEngine.Scenario(rawValue: name) {
            return MockEngine(scenario: scenario)
        }
        #endif

        // 不具合が UI 側か推論側かを切り分けるための退避口（MLXEngine.swift 冒頭）。
        if environment["SOPHIA_ENGINE"] == "stub" {
            return StubEngine()
        }

        return MLXEngine()
    }

    /// **ツールの実行役を差し込む**（FR-19 / DESIGN.md 第16章 / NFR-09）。
    ///
    /// ---
    ///
    /// # なぜ差し込みがここに居るのか
    ///
    /// `InferenceEngine` に `setToolExecutor` は**無い。意図的に無い。**
    ///
    /// | 層 | 知ってよいもの |
    /// |---|---|
    /// | `Sources/Inference/` | `ToolExecuting` と `ModelToolCall` だけ |
    /// | `Sources/Tools/` | フォルダ・封じ込め・文脈の上限。推論を知らない |
    /// | **組み立てる側（ここ）** | **両方。ここだけが `FolderToolRunner` を差し込む** |
    ///
    /// 実行役を持てるかどうかは**実装ごとの性質**である ── `StubEngine` も
    /// `MockEngine` もツールを扱わず、`options.tools` を無視してよい約束になっている
    /// （`InferenceEngine` の約束事8）。protocol に載せると
    /// **扱えない実装に空実装を書かせる**ことになり、「実装がある」が
    /// 「動く」に見える面を1つ増やす。
    ///
    /// だから**組み立てる側が、受け取れるエンジンにだけ渡す。**
    /// `ChatViewModel` から `as? MLXEngine` を書かせないための関数でもある ──
    /// UI が推論の実装名を書き始めたら、NFR-09 は静かに終わる。
    ///
    /// > **受け取れないエンジンでは何も起きない。** それで正しい ──
    /// > 渡す先が無いだけで、`options.tools` の門（FR-21）とは無関係である。
    static func installToolExecutor(
        _ executor: (any ToolExecuting)?, into engine: any InferenceEngine
    ) async {
        guard let mlx = engine as? MLXEngine else { return }
        await mlx.setToolExecutor(executor)
    }
}
