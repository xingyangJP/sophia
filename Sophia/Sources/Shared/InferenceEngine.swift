import Foundation

// =============================================================================
//  Sophia 推論エンジン契約 — 3人の実装者が並列で作業するための唯一の合意点
// -----------------------------------------------------------------------------
//  このファイルと Sources/Shared/ 配下は **読み取り専用として扱うこと。**
//  型が足りないと感じたら、勝手に書き換えず基盤担当へ相談すること。
//  各層のローカルな型（UIの表示状態など）は各層のファイルに置く。ここには置かない。
//
//  出典: DESIGN.md 第4章（推論エンジンの抽象化）/ 第5章（ストリーミング）/ 第6章（思考モード）
//        REQUIREMENTS.md 第5章（FR-xx）/ docs/MLX_SWIFT.md（実地調査）
// =============================================================================

/// 推論エンジン抽象（NFR-09 / DESIGN.md 第4章）。
///
/// 開発時と配布時で実装が変わる唯一の層。A1 では `StubEngine` と MLX 実装の2つが並ぶ。
/// **UI はこの protocol より下を知らないこと。** MLX の型を UI 層へ持ち込んだ時点で、
/// エンジンを差し替えられるという NFR-09 の前提が消える。
///
/// ---
///
/// # 守るべき約束事
///
/// ## 1. 中断は Task のキャンセルに載せる（FR-02）
///
/// `AbortSignal` に相当するものは**引数に無い**。呼び出し側はこう書く。
///
/// ```swift
/// // 生成を始める
/// let task = Task {
///     for try await chunk in engine.chat(messages, options: options) {
///         await model.apply(chunk)      // ← 蓄積先は Task の外に置くこと
///     }
/// }
///
/// // 中断する
/// task.cancel()
/// ```
///
/// `AsyncThrowingStream` の反復はキャンセルを検知して終端し、
/// `continuation.onTermination` が発火する。実装側はそこで内部の生成 `Task` を
/// キャンセルすること。MLX の生成ループは `while !Task.isCancelled` なので、
/// これで実際に止まる（MLX_SWIFT.md 第5章）。
///
/// ## 2. 中断しても既出力は消さない（FR-02 / DESIGN.md 第5.3章）
///
/// > 利用者が中断するのは「もう十分」か「方向が違う」のどちらかで、前者では出力が要る。
///
/// **`Chunk` の蓄積先を、キャンセルする `Task` の内側に置かないこと。**
/// 内側に置くと、キャンセル時にローカル変数ごと消える。
/// 蓄積は `@MainActor` の状態オブジェクトなど、Task の外の寿命を持つ場所へ行う。
///
/// ## 3. 中断時に `.done` が届く保証はない
///
/// キャンセルするとストリームはその場で終端するため、`.done(stats)` を
/// 受け取れないまま終わることがある。
/// **UI は `.done` を待たずに、受信済みテキストを確定できる状態を保つこと。**
/// 統計値は「`.done` が来たときだけ確定する」ものとして扱う。
///
/// ## 4. 例外を外へ投げない。`SophiaError` にして流す
///
/// ストリームが投げるエラーは `SophiaError` に統一する。
/// 実装側は境界で `SophiaError.wrap(_:)` を通すこと。`CancellationError` は
/// 自動的に `.cancelled` へ変換される（FR-02 の中断を赤字エラーにしないため）。
///
/// ## 5. 間引かない
///
/// エンジンは受け取った断片を**そのまま全件**流す。
/// 16ms 単位のバッファリング（DESIGN.md 第5.2章）は **UI 側の責務**である。
/// エンジンが間引くと、UI 側で正確な計測ができなくなる。
///
/// ## 6. thinking を送り返さない
///
/// `SophiaMessage` に thinking フィールドが無いのはそのため。型の説明を参照。
///
/// ## 7. 実装は actor にするのが自然
///
/// `ModelContainer`（MLX）は actor 隔離されている。エンジン実装も actor にして、
/// `chat` / `load` だけを `nonisolated` にすると素直に書ける。
/// **推論を MainActor で走らせないこと**（NFR-02: 生成中も UI が固まらない）。
///
/// ## 8. `options.tools` が空なら、ツールの定義を1文字も送らない（FR-21）
///
/// **2026-08-18 追加。** ツール呼び出しの結線に伴う約束（DESIGN.md 第16.2節）。
///
/// | `options.tools` | 実装がすべきこと |
/// |---|---|
/// | 空（**既定**） | **モデルへ渡す入力にツールの定義を一切含めない。追加の費用は 0** |
/// | 空でない | その定義だけを渡す。呼ばれたら `.toolCall` を流す |
///
/// **「空かどうか」以外の判断を実装側でしないこと。**
/// 利用者の文からツールの要否を推定する分類器は**禁止**である（16.2節）──
/// それ自体が推論であり、判定のために毎ターン計算を払う。
/// Open WebUI はツール定義32個・約4,550トークンを毎ターン注入して
/// 「こんにちは」への応答を34秒にしていた（TUNING.md 第2章）。**その再現を防ぐ約束である。**
///
/// ツールを扱わない実装（`StubEngine` / `MockEngine`）は `options.tools` を
/// **無視してよい。** 無視は「渡さない」と同じ意味になるので、この約束を破らない。
protocol InferenceEngine: Sendable {

    /// どの実装か。UI の表示に使う（`stub` のときはダミー動作である旨を出す）。
    nonisolated var identifier: EngineIdentifier { get }

    /// いま読み込まれているモデル。未ロードなら nil。
    func loadedModel() async -> ModelInfo?

    /// エンジンの能力。**モデルによって変わるのでロード後に問い合わせること。**
    func capabilities() async -> EngineCapabilities

    /// 選択できるモデルの一覧（FR-09 の下地。A1 では表示のみ）。
    func availableModels() async throws -> [ModelInfo]

    /// モデルを読み込む。進捗が流れ、**完了するとストリームが正常終了する**。
    ///
    /// 初回は 4.62GB の取得を含むため数分かかる（MLX_SWIFT.md 第2.2節）。
    /// 進捗が要らない場合は `for try await _ in engine.load(id) {}` と書く。
    /// この `Task` をキャンセルすると取得も中断される（NFR-10 の再開対象）。
    nonisolated func load(_ modelID: String) -> AsyncThrowingStream<LoadProgress, any Error>

    /// モデルを解放する。メモリを返すのが目的。16GB機では効く。
    func unload() async

    /// 応答を生成する（FR-01）。
    ///
    /// - Parameters:
    ///   - messages: エンジンへ送る会話。**thinking は含まれない**（型で保証済み）。
    ///   - options: 生成パラメータ。思考モードの `maxTokens` 補正は
    ///     実装側が `options.applyingThinkingBudget()` を1回だけ適用すること。
    /// - Returns: 断片のストリーム。終端は `.done` かエラーかキャンセル。
    ///
    /// この関数自体は `async` でも `throws` でもない。**呼んだ瞬間に返る。**
    /// 失敗はストリームの中で通知される（例: モデル未ロードなら
    /// 最初の要素の代わりに `SophiaError.modelNotLoaded` が投げられる）。
    nonisolated func chat(
        _ messages: [SophiaMessage],
        options: ChatOptions
    ) -> AsyncThrowingStream<Chunk, any Error>
}
