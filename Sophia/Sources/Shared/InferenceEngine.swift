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
///
/// ## 9. ツールの往復は**エンジンの中で閉じる**（FR-19 / DESIGN.md 第16章）
///
/// **2026-08-18 追加。** モデルがツールを呼んだら、実行して結果を会話へ足し、
/// 生成を再開するところまでが `chat(_:options:)` **1回の中**で起きる。
/// 呼び出し側（UI）は `.toolCall` / `.toolResult` を**見なくても正しく動く** ──
/// 本文は今までどおり `.content` として流れ、終端は今までどおり `.done` である。
///
/// | 誰が | 何をするか |
/// |---|---|
/// | 呼び出し側 | `options.tools` を入れる（＝門を開ける）。実行役を注入する |
/// | エンジン | 呼ばれたら実行役へ渡し、結果を会話へ足して**もう一度生成する** |
/// | 実行役（`ToolExecuting`） | 1回ぶん実行して返す。**往復の回数もここが数える** |
///
/// ### `SophiaMessage` に tool 役を足さないこと（決定済み）
///
/// 生の往復は**エンジンの中だけに存在し、外へは出ない。**
///
/// > **【事実の訂正 / 2026-08-19】ここには「履歴に残るのは栞1行である」と書いてあった。嘘だった。**
/// > **ターンの中では**生の戻り値が栞1行へ落ちる（`MLXEngine.compacted` / 2026-08-19 配線）。
/// > **ターンをまたぐと、往復は痕跡ごと消える** ── 栞も残らない。
/// > `engineMessages()` が `turns` から毎回組み直すためである。
/// >
/// > **栞をターンまたぎで残すかは決めていない。** 残すなら
/// > **永久に毎ターン払う項を1つ作る**ことになる（`fit` は栞を落とせない）。
/// > `armed` の会話で利用者に残るのは 33トークンしかない（`SophiaDefaults.InputBudget`）。
/// `MessageRole` を増やすと `messages.role` の CHECK 制約
/// （`SophiaMigrations.swift`）と `StoreSchemaTests` に波及する ──
/// **得るものが無いのに移行を1つ増やすことになる。**
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

// =============================================================================
//  ツールを実行する役（FR-19 / DESIGN.md 第16章 / NFR-09）
// -----------------------------------------------------------------------------
//  ## なぜ `ChatOptions` ではなくここなのか
//
//  `ChatOptions` は `Equatable` / `Codable` である。**クロージャは持てない。**
//  持たせれば両方失われ、`EngineToolWiringTests.testChatOptionsSurvivesEncodingWithTools`
//  がその場で落ちる（落ちてよい試験である ── 型の性質を守るために置いてある）。
//
//  ## なぜ推論層が `Sources/Files/` を知ってはいけないのか
//
//  **エンジンは差し替えられる（NFR-09）。** `MLXEngine` が `FolderToolRunner` を
//  直接呼ぶ形にすると、次のエンジンは**同じ実行役を使えない** ── ツールの実行が
//  推論の実装に癒着する。ここに protocol を1枚置くと、
//  「読む権限を持つ層」と「モデルを回す層」がお互いを知らないまま繋がる。
//
//  | 層 | 知っているもの |
//  |---|---|
//  | `Sources/Inference/` | **`ToolExecuting` と `ModelToolCall` だけ** |
//  | `Sources/Tools/` | フォルダ・封じ込め・文脈の上限。**推論を知らない** |
//  | アプリ（組み立てる側） | **両方。** ここだけが `FolderToolRunner` を差し込む |
//
//  実際の差し込みは `MLXEngine.init(toolExecutor:)` か
//  `MLXEngine.setToolExecutor(_:)`（会話ごとに付け替える）である。
// =============================================================================

/// **モデルが呼んだツールを1回ぶん実行して、モデルへ返せる形にする役**（16.8節）。
///
/// ## 実装が守ること
///
/// | 約束 | なぜ |
/// |---|---|
/// | **throw しない。失敗も戻り値** | 16.8節「往復を1回で打ち切らない」。読めなかった旨をモデルへ返す |
/// | **往復の回数はここが数える** | 数える場所を呼び出し側に置くと、中断・再試行・別ターンで必ず数え漏れる |
/// | **戻り値でアプリの状態を変えない** | 16.6節 約束2。読めるフォルダはモデルの出力では増えない |
/// | 主スレッドで I/O をしない | NFR-02。`actor` にすれば `await` するだけで降りる |
///
/// ## エンジンが守ること（この protocol の裏側の約束）
///
/// **`options.tools` が空の会話では、この役に一度も触らない。**
/// 実行役が刺さっているかどうかで注入の状態が変わってはいけない（16.6節 約束3）──
/// 引き金は利用者の操作（＝`tools` を入れたこと）だけである。
protocol ToolExecuting: Sendable {

    /// **新しい利用者の発言から往復を始める合図。** 回数の数えはここで戻す。
    ///
    /// 上限は「1つの問いに答えるまで」に効かせたいものであって、
    /// 「会話を通じて一度しか読めない」ではない（`FolderToolRunner.resetCallCount`）。
    /// **エンジンが生成の入口で1回だけ呼ぶ。** 呼び出し側に任せない ──
    /// 任せた瞬間、呼び忘れた会話だけが2回目から読めなくなる。
    func beginRoundTrip() async

    /// 1回ぶん実行する。**throw しない。**
    ///
    /// 引数の `ModelToolCall` は**モデルが書いた文字列そのまま**である。
    /// 名前が3つのどれでもないことも、パスが `../../etc/passwd` のこともある。
    /// **検証はこの役の内側で行うこと**（16.5節の封じ込め）。
    func execute(_ call: ModelToolCall) async -> ToolExecutionOutcome
}

/// ツール1回の結果を、**推論層が扱える形**にしたもの。
///
/// `Sources/Tools/ToolResult` とは別の型である ── あちらは `ReadOutcome` や
/// `FolderAccessError` を抱えており、**推論層に持ち込むと `Sources/Files/` が
/// 芋づるで付いてくる**（NFR-09 が静かに壊れる）。ここに詰め替えるのは実行役の仕事。
///
/// ## 文字列は「囲い済み・1行済み」で来ること
///
/// `responseText` は `<tool_response>` の中へ**そのまま**入る。
/// 囲い（16.6節 約束5）も長さの上限（16.3節）も**実行側で済んでいる**前提であり、
/// 推論層は1文字も足さない ── 足す口を作ると、囲いを忘れる経路がそこにできる。
struct ToolExecutionOutcome: Sendable, Equatable {

    /// モデルが呼んだ名前（**直さないこと**）。
    var toolName: String

    /// 呼び出しの識別子。`<tool_call>` と `<tool_response>` を対応づけるために返す。
    /// モデルが出さないことがあるので Optional（`ModelToolCall.callID` と同じ）。
    var callID: String?

    /// **そのまま `<tool_response>` に入る文字列**（＝`ToolResult.contextText`）。
    var responseText: String

    /// 画面に出す1行（＝`ToolResult.bookmarkLine`）。
    ///
    /// **「履歴に残る」とは書かないこと。** ターンをまたぐと往復は痕跡ごと消える
    /// （上の型コメントの訂正を読むこと）。**同じ文字列であることは真だが、
    /// 残っているのは画面のほうだけである。**
    var summaryLine: String

    /// 読めなかった／呼び出しが成立しなかった。**往復は続く。**
    var isFailure: Bool

    /// **これ以上ツールを渡してはいけない。**
    ///
    /// 往復の上限に達したときに `true` になる（`ToolRejection.callLimitReached`）。
    /// エンジンはこれを見て**次の1回でツールの定義ごと外す** ──
    /// 外せばテンプレートの門が閉じ、モデルは呼びようがなくなる（16.2節 / FR-21）。
    ///
    /// **上限そのものはここでは決めない。** 数えているのは実行役だけであり、
    /// 推論層が別に数えると真実の出所が2つになる。
    var stopsRoundTrips: Bool

    init(
        toolName: String,
        callID: String? = nil,
        responseText: String,
        summaryLine: String,
        isFailure: Bool,
        stopsRoundTrips: Bool = false
    ) {
        self.toolName = toolName
        self.callID = callID
        self.responseText = responseText
        self.summaryLine = summaryLine
        self.isFailure = isFailure
        self.stopsRoundTrips = stopsRoundTrips
    }

    /// 画面へ流す形（`Chunk.toolResult`）。**同じ値から作る**ので文が食い違わない。
    func activity(round: Int) -> ToolActivity {
        ToolActivity(
            toolName: toolName, summary: summaryLine, isFailure: isFailure, round: round)
    }
}
