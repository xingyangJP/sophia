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
}
