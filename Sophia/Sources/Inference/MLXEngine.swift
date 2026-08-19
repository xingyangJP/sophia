import Foundation
import HuggingFace  // #hubDownloader() の展開結果が要求する（MLX_SWIFT.md 第2.4節）
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers  // #huggingFaceTokenizerLoader() の展開結果が要求する

// =============================================================================
//  MLX Swift による推論エンジン（A1 本番実装）
// -----------------------------------------------------------------------------
//  `StubEngine` は書き換えていない。両方を残すと、不具合が UI 側か推論側かを
//  切り分けられる（`EngineIdentifier` を切り替えるだけで比較できる）。
//
//  ## 設計上の選択と、その理由
//
//  | 選択 | 理由 |
//  |---|---|
//  | 低レベル API（`ModelContainer.generate`）を使う | `ChatSession` は**中断したターンを履歴に残さない**（`AssistantGeneration.shouldRecord` が `stopReason != .cancelled` を要求）。FR-02「既出力は消えない」と正面から衝突する（MLX_SWIFT.md 第5章） |
//  | `actor` にする | `ModelContainer` が隔離されている。推論を MainActor で走らせない（NFR-02） |
//  | `[Chat.Message]` を引数で渡さない | `Chat.Message` / `UserInput` が `Sendable` ではない。Task 境界を越えるとコンパイルエラー（MLX_SWIFT.md 第4.4節） |
//  | 思考分離は公式 `ReasoningEventEmitter` | 区切り文字をモデルの宣言から取るので、モデルを差し替えても壊れない |
//  | `primedInside` を推測しない | 描画済みプロンプトの末尾から導出する。Qwen3 で `true` にすると全崩壊する |
//  | **ツールの往復を `performChat` の中で閉じる** | 呼び出し側は `.toolCall` を見なくても正しく動く。生の往復は外へ出さない（FR-19 / 16章。`RoundTripMessage` の解説を読むこと） |
//  | 実行役は `Shared/` の protocol 越しに受け取る | `Sources/Files/` を知った瞬間、エンジンを差し替えると実行役ごと作り直しになる（NFR-09） |
//
//  ## 未確認（このファイルについて）
//
//  **モデルのロードも生成も一度も実行していない。**（並列作業中の16GB機で
//  推論を走らせるとスワップで共倒れになるため、指示により禁止されている）
//  確認したのはビルドが通ること、および `ThinkingSplitter` の文字列単体テストのみ。
//  実機で最初に確かめるべき点は本ファイル末尾の「実機で確かめること」に列挙した。
// =============================================================================

/// MLX Swift 実装（NFR-09 の差し替え対象）。
actor MLXEngine: InferenceEngine {

    nonisolated let identifier: EngineIdentifier = .mlx

    /// 読み込み済みのモデル。未ロードなら nil。
    private var container: ModelContainer?
    private var current: ModelInfo?

    /// モデルが宣言した思考プロトコル。ロード時に `ModelContext` から取る。
    /// nil のモデルは思考モードを持たない。
    private var reasoning: ReasoningConfig?

    /// 生成が同時に2本走らないようにする。16GB機では致命的なので直列化する。
    private var isGenerating = false

    /// 読み込みが同時に2本走らないようにする。
    /// **重みは 4.62GB ある。** 二重に走らせると 9GB を掴んで確実に落ちる。
    private var isLoading = false

    // MARK: - ツールの実行役（FR-19 / DESIGN.md 第16章 / NFR-09）

    /// モデルがツールを呼んだときに、実際に実行する役。**未設定なら往復は起きない。**
    ///
    /// ## ここに `FolderToolRunner` と書かないこと（NFR-09）
    ///
    /// 型は `Shared/` の protocol（`ToolExecuting`）だけである。
    /// **このファイルは `Sources/Files/` も `Sources/Tools/` も1文字も知らない** ──
    /// 知った瞬間、エンジンを差し替えると実行役ごと作り直しになる。
    /// 差し込むのはアプリ側（`init(toolExecutor:)` か `setToolExecutor(_:)`）。
    ///
    /// ## 刺さっているだけでは何も起きない（**重要**）
    ///
    /// 実行役に触るのは `options.tools` が空でないときだけである（16.6節 約束3）。
    /// 引き金は**利用者の操作**（＝ツール定義を渡したこと）であって、
    /// 実行役の有無ではない。**古い実行役が残っていても、門が閉じていれば無害**である。
    private var toolExecutor: (any ToolExecuting)?

    /// 往復の回数の**安全弁**。上限そのものではない。
    ///
    /// > 上限は実行役（`FolderToolRunner.callLimit`、既定6）が数える。**そちらが本物である。**
    ///
    /// ここにあるのは「実行役が `stopsRoundTrips` を一度も返さない」場合に
    /// **生成が永久に回り続けるのを防ぐ**ためだけの数である。
    /// 16GB機で無限に回るということは、利用者が見ている前で機械を占有し続けるということで、
    /// 「落ちないまま黙っている」（取得の見張りと同じ症状）になる。
    ///
    /// **正常な往復でここに当たってはいけない。** 当たったら `[TOOL] event=round_limit`
    /// が出る ── 出たなら、それは実行役の上限が効いていないという報せである。
    static let maximumToolRounds = 16

    // MARK: - MLX 側のメモリ会計（`[MEM]` 計測点）

    /// 段階ごとの `MLX.Memory.snapshot()`。**古い順に積む。**
    ///
    /// 何を測っているか・なぜ `ProcessMetrics` の代わりにならないかは
    /// ファイル末尾の `MLXMemoryReading` の解説に集めてある。**先にそれを読むこと。**
    ///
    /// 溜め込む理由は1つで、**プリフィル完了の瞬間は actor の外（MLX の計算スレッド）で
    /// 起きる**ため、その場で読み手へ渡せないからである。いったんここへ積み、
    /// `drainMemoryTrace()` で取り出す。
    private var memoryTrace: [MLXMemoryReading] = []

    /// 次に振る通し番号。**取り出しても戻さない**ので、
    /// 読み手は `seq` の飛びを見れば「取りこぼした区間がある」と分かる。
    private var memoryReadingCount = 0

    /// 直前の1点。`[MEM]` 行の差分（`since=`）の基準に使う。
    /// `memoryTrace` を空にしても消さない ── 取り出しの前後で差分の基準が変わると読めなくなる。
    private var lastMemoryReading: MLXMemoryReading?

    /// 生成のあとに `MLX.Memory.clearCache()` を呼ぶか。**既定は無効。**
    ///
    /// 有効にすると `cache_mb` が本当にキャッシュだったのかを切り分けられる
    /// （`cacheLimit` は20MBなので、理屈では大きく減りようが無い。
    ///  **それでも減るなら前提のほうが間違っている**）。
    ///
    /// **既定を有効にしてはいけない。** 捨てたバッファは次の生成で確保し直しになり、
    /// その代金がプリフィル時間に乗る ── いま測ろうとしている当のものが動く。
    /// 初期値は `SOPHIA_MEM_CLEAR_CACHE=1`、実行中の切り替えは
    /// `setClearsCacheAfterGeneration(_:)`（プローブ用）。
    /// （`Self` ではなく型名で書いてある。ストアドプロパティの既定値式で `Self` を
    ///   参照すると Swift のバージョンによって弾かれるため。）
    private var clearsCacheAfterGeneration = MLXEngine.clearsCacheAfterGenerationByDefault

    /// - Parameter toolExecutor: ツールの実行役（FR-19）。**既定は nil＝往復しない。**
    ///   既存の呼び出し（`MLXEngine()`）はそのまま通る ── 危険な側（実行できる側）を
    ///   明示的にしておくための既定である（`ChatOptions.tools` が空既定なのと同じ順序）。
    init(toolExecutor: (any ToolExecuting)? = nil) {
        self.toolExecutor = toolExecutor
        // 起動時の1度きり。`static let` なので何度 init しても1回しか走らない。
        _ = Self.runtimeConfigured
    }

    /// 実行役を差し替える（**会話ごとに変わる**ので `init` だけでは足りない）。
    ///
    /// 実行役は「この会話が読んでよいフォルダ」を握っている。
    /// 利用者がフォルダを結び付けた／外したときに、アプリ側がここで入れ替える。
    /// **nil を入れれば往復は起きなくなる**（ただし門を閉じる本体は `ChatOptions.tools`）。
    func setToolExecutor(_ executor: (any ToolExecuting)?) {
        toolExecutor = executor
    }

    // MARK: - 起動時の設定

    /// MLX のバッファキャッシュ上限を入れる。
    ///
    /// 公式サンプル LLMEval / LLMBasic / MLXChatExample の**3つとも 20MB**
    /// で、「LLMは20MB」が事実上の推奨値（MLX_SWIFT.md 第8.1節）。
    /// 16GB・スワップ6〜7GBのこの機体では、まずこれを入れないと話が始まらない。
    ///
    /// `MLX.GPU.set(cacheLimit:)` は**非推奨**。`Memory.cacheLimit` を使う。
    private static let runtimeConfigured: Bool = {
        MLX.Memory.cacheLimit = SophiaDefaults.mlxCacheLimitBytes
        return true
    }()

    // MARK: - 計測の入切（環境変数）

    /// 段階ごとのスナップショットを**記録するか**。
    ///
    /// **既定は無効。** 通常利用でログが増えるのを避けるだけでなく、
    /// 記録そのものを走らせない（`snapshot()` は安いが、無料ではない）。
    ///
    /// | 条件 | 効果 |
    /// |---|---|
    /// | `SOPHIA_LOG_MEM=1` | 記録する ＋ `[MEM]` 行を stderr へ出す |
    /// | `SOPHIA_PROBE=1`   | 記録する（**行は出さない**） |
    ///
    /// `SOPHIA_PROBE=1` で記録だけ有効にしているのは、`PrefillProbeTests` が
    /// 取り出して `[PROBE-MLX]` 行として自分で出すからである。
    /// **両方が出すと同じ数字が2組ログに並び、grep の結果が二重になる。**
    /// プローブ側の行を正とするのは `make probe` が `^\[PROBE` しか端末へ映さないため
    /// （`[MEM]` 行はログファイルには入るが画面には出ない）。
    ///
    /// `let` にしてあるので**プロセス起動時の値で固定**される。
    /// 途中で環境変数が変わっても計測条件が動かない ── 計測の道具としてはそれが正しい。
    private static let memoryProbeRecords: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["SOPHIA_LOG_MEM"] == "1" || environment["SOPHIA_PROBE"] == "1"
    }()

    /// `[MEM]` 行を stderr へ出すか。**`SOPHIA_LOG_MEM=1` のときだけ。**
    private static let memoryProbeWritesLog: Bool = {
        ProcessInfo.processInfo.environment["SOPHIA_LOG_MEM"] == "1"
    }()

    /// `clearsCacheAfterGeneration` の初期値。**既定は無効**（理由は同プロパティ）。
    private static let clearsCacheAfterGenerationByDefault: Bool = {
        ProcessInfo.processInfo.environment["SOPHIA_MEM_CLEAR_CACHE"] == "1"
    }()

    // MARK: - 取得の見張り（FR-07 / NFR-10 / FR-11）
    //
    //  ## なぜ要るのか ── 2026-08-18 に実際に起きたこと
    //
    //  キャッシュを消したあと、「モデルを取得しています（0%）」から**永久に進まなくなった。**
    //
    //  | 観測 | 値 |
    //  |---|---|
    //  | 進捗 | 0% のまま |
    //  | エラー表示 | 無し |
    //  | ログ出力 | 無し |
    //  | TCP接続 | 0本 |
    //  | 書き込み | 1バイトも無し（`.incomplete` すら無い） |
    //  | CPU | 11〜14%（アイドルではない） |
    //
    //  原因（`swift-huggingface` の Xet トランスポートが無効）は**別の問題**である。
    //  ここで直すのは **「原因が何であれ、失敗したなら利用者に伝わる」** ほうだけ。
    //  いちばんの問題は落ちなかったことではなく、**落ちないまま黙っていたこと**だった。
    //
    //  例外は上がらない。だから**例外を待つのをやめて、バイトが増えているかを見る。**

    /// 最初の1バイトが届くまでに許す時間。**既定 90 秒。**
    ///
    /// ## この数字の根拠（数字だけ置くと、後で誰も動かせなくなる）
    ///
    /// 健全なときの実測は **`curl` で 1〜2秒で最初のバイト、以後 20MB/s**。
    /// つまり「最初の1バイトまで」は本来 **秒のオーダー**である。
    /// では何故その45〜90倍も待つのか ── **この区間だけは、待つべき正当な理由が複数ある**から。
    ///
    /// | 待たされる正当な理由 | かかりうる時間 |
    /// |---|---|
    /// | HuggingFace の**ファイル一覧 API**（`HubClient.listFiles`）。**これが返るまで進捗コールバックは1回も鳴らない** | 数百ms〜十数秒 |
    /// | DNS / TLS / リダイレクト | 数百ms〜数秒 |
    /// | HF 側のレート制限に伴うリトライ待ち | 十秒級 |
    /// | サンドボックス初回のネットワーク許可 | 数秒 |
    ///
    /// 全部足しても十数秒に収まる。**90秒はその5倍以上の余裕**で、
    /// 「遅い回線を殺さない」側へ大きく倒してある。
    /// 逆に90秒経って**1バイトも来ない**なら、それは遅いのではなく**始まっていない。**
    /// 今回の事故がまさにそれで、待っても永久に1バイトも来なかった。
    ///
    /// `SOPHIA_DOWNLOAD_FIRST_BYTE_S` で上書きできる。**`0` を渡すと見張りごと止まる**
    /// （極端に遅い回線での緊急避難。止めれば当然また黙って固まる）。
    static let downloadFirstByteGrace: Duration =
        MLXEngine.durationFromEnvironment("SOPHIA_DOWNLOAD_FIRST_BYTE_S", defaultSeconds: 90)

    /// 取得が始まったあと、**1バイトも増えないまま**許す時間。**既定 60 秒。**
    ///
    /// ## この数字の根拠
    ///
    /// 見張りが見るのは「増えたか／増えていないか」だけで、**増えたらその場で0に戻す。**
    /// だから判定に使われるのは「1バイトも増えなかった連続時間」だけである。
    ///
    /// - 実測 20MB/s の **1/1000（20KB/s）まで落ちた回線でも、60秒あれば 1.2MB は増える**。
    ///   増えれば時計は戻るので、**遅いだけの取得は永久に検知されない**（誤検知しない）
    /// - 進捗コールバックは swift-huggingface のサンプリングタスクが **100ms 間隔**で鳴らす
    ///   （`HubClient+Files.swift` の `makeSnapshotProgressSamplingTask`）。
    ///   60秒 ＝ **鳴るはずの600回ぶんが完全に無風**だったということ
    ///
    /// **短くするときは上の2点を計算し直すこと。** 20MB/s は「調子が良いとき」の値で、
    /// 混んだ回線や Wi-Fi の切り替わりで数十秒の空白が空くことはある。
    /// `SOPHIA_DOWNLOAD_STALL_S` で上書きできる（`0` で見張りを止める）。
    static let downloadStallTimeout: Duration =
        MLXEngine.durationFromEnvironment("SOPHIA_DOWNLOAD_STALL_S", defaultSeconds: 60)

    /// 見張りが起きる間隔。**検知の遅れは「閾値 ＋ この間隔」**になる（最悪 65 秒）。
    ///
    /// 5秒にしてあるのは、90秒／60秒に対して十分細かく、かつ
    /// 数分の取得で起きる回数が数十回に収まる ＝ 計測の雑音にならないため。
    static let downloadWatchdogInterval: Duration = .seconds(5)

    /// `[LOAD]` 行を stderr へ出すか。**`SOPHIA_LOG_LOAD=1` のときだけ。**
    ///
    /// 今回いちばん困ったのは「ログ出力 無し」で、**何が起きているか調べる材料が
    /// 1バイトも無かった**ことである。既定を無効のままにしてあるのは通常利用で
    /// ログを増やさないためだが、**打ち切りの1行（`event=stalled`）だけは
    /// この設定と無関係に必ず出す。** 異常時に黙るのが今回の問題そのものだから。
    static let logsModelLoad: Bool = {
        ProcessInfo.processInfo.environment["SOPHIA_LOG_LOAD"] == "1"
    }()

    /// 環境変数から秒数を読む。読めなければ既定値。負数は既定値に落とす。
    ///
    /// `let` で受けるので**プロセス起動時の値で固定**される
    /// （途中で変わると、同じ実行の中で判定条件が変わってしまう）。
    private static func durationFromEnvironment(
        _ key: String, defaultSeconds: Int
    ) -> Duration {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let value = Int(raw), value >= 0
        else { return .seconds(defaultSeconds) }
        return .seconds(value)
    }

    /// 記録が有効か。プローブ側が「取れないのに待つ」のを避けるために公開している。
    ///
    /// `actor` の static は元から隔離されていないので `nonisolated` は付けない
    /// （インスタンスの `identifier` と違い、ここでは冗長になる）。
    static var isMemoryProbeEnabled: Bool { memoryProbeRecords }

    // MARK: - InferenceEngine（問い合わせ）

    func loadedModel() -> ModelInfo? { current }

    func capabilities() -> EngineCapabilities {
        // 思考モードの可否は**モデルの宣言から導く**。キー名をハードコードしない。
        //
        // `ReasoningPromptStrategy.none` は `Optional.none` と綴りが衝突するので、
        // Optional のまま switch せず、先に開いてから分岐する。
        let supportsThinking: Bool
        let canDisable: Bool
        switch reasoning?.promptStrategy {
        case .some(.templateFlag):
            // Qwen3。`enable_thinking` で ON/OFF できる。
            (supportsThinking, canDisable) = (true, true)
        case .some(.alwaysOn):
            // DeepSeek-R1 系。思考はするが OFF にできない。
            // ここで false を返さないと、押しても効かないトグルが UI に出る。
            (supportsThinking, canDisable) = (true, false)
        case .some(.none), nil:
            // 思考モードを持たないモデル、または未ロード。
            (supportsThinking, canDisable) = (false, false)
        }

        return EngineCapabilities(
            supportsThinking: supportsThinking,
            canDisableThinking: canDisable,
            maxContextLength: current?.maxContextLength ?? SophiaDefaults.contextLength,
            // `GenerateParameters.prefill.progress` は main リビジョンにのみ存在する。
            // いま固定しているのは main（d7dc03d）なので送れる。
            reportsPrefillProgress: true,
            // `GenerateCompletionInfo` が実測のトークン数を返す。
            // ただし**中断時は `.info` が届かないことがあり**、その場合だけ概算になる。
            reportsExactTokenCounts: true
        )
    }

    func availableModels() -> [ModelInfo] {
        MLXModelCatalog.entriesReflectingDisk()
    }

    // MARK: - InferenceEngine（読み込み）

    nonisolated func load(_ modelID: String) -> AsyncThrowingStream<LoadProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.performLoad(modelID, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func unload() {
        container = nil
        current = nil
        reasoning = nil
        // 重みを手放したあとにキャッシュを返す。16GB機では効く。
        MLX.Memory.clearCache()
        // **「全部手放した状態」の基準点。** ここでもなお `active_mb` が大きいなら、
        // MLX がまだ握っているものがある ＝ 参照が残っている（＝ロード側のリークを疑う）。
        recordMemory(.unloadEnd)
    }

    // MARK: - InferenceEngine（生成）

    nonisolated func chat(
        _ messages: [SophiaMessage],
        options: ChatOptions
    ) -> AsyncThrowingStream<Chunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.performChat(messages, options: options, into: continuation) }
            // 消費側が Task をキャンセルすると、ここが発火して生成が止まる（FR-02）。
            // MLX の生成ループは `while !Task.isCancelled` なので実際に止まる。
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 読み込みの中身

    private func performLoad(
        _ modelID: String,
        into continuation: AsyncThrowingStream<LoadProgress, any Error>.Continuation
    ) async {
        // 二重読み込みの防止。ここは 4.62GB を掴む処理なので、
        // 「たぶん大丈夫」で通してはいけない。
        guard !isLoading else {
            // 「再試行」を押した先がここへ来ることがある。
            //
            // 見張りが打ち切りを通知したあと、`continuation.onTermination` 経由で
            // この `performLoad` の Task はキャンセルされる。取得側がキャンセルを
            // 見てくれれば `isLoading` は `defer` で戻るが、**見てくれない実装
            // （同期ループに入り込んでいる場合）だと戻らない。**
            // そのときに「お待ちください」とだけ言うのは嘘になるので、
            // **再起動という出口を必ず添える。**
            continuation.finish(throwing: SophiaError(
                code: .modelLoadFailed,
                message: "モデルの読み込みがすでに進行中です。",
                hint: "読み込みが終わるまでお待ちください。"
                    + "進捗が止まったまま戻らない場合は、Sophia を再起動してください。"))
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            continuation.yield(LoadProgress(
                stage: .resolving, detail: "モデルを確認しています"))

            // すでに同じモデルが載っている。**4.62GB を読み直さない。**
            if container != nil, current?.id == modelID {
                continuation.yield(LoadProgress(
                    stage: .ready, fraction: 1, detail: "準備できました"))
                continuation.finish()
                return
            }

            // 別のモデルへ切り替える場合は、先に手放す。
            // 16GB機で 4.62GB を2つ載せる余地は無い。
            if container != nil {
                unload()
            }

            // **ロードの基準点。** ここを「関数の入口」ではなく
            // 「本当に読み込む直前」に置いたのは、上の2つの早期経路
            // （同じモデルが既に載っている／別モデルを `unload()` した）を通ったあとの
            // 値でないと基準にならないため。`load_begin` と `load_end` は必ず対で出る。
            recordMemory(.loadBegin)

            let configuration = MLXModelCatalog.configuration(for: modelID)
            let alreadyOnDisk = MLXModelCatalog.isDownloaded(modelID)
            let entry = MLXModelCatalog.entry(for: modelID)

            if !alreadyOnDisk {
                let size = entry.sizeBytes.map(Self.formatBytes) ?? "数GB"
                continuation.yield(LoadProgress(
                    stage: .downloading,
                    // 総量を最初から入れておく。**進捗コールバックが1回も鳴らなくても
                    // 「0 / 4.62 GB」と出せる**ようにするため（今回はここが空だった）。
                    totalBytes: entry.sizeBytes,
                    fraction: 0,
                    detail: "モデルを取得しています（初回のみ・約\(size)）"))
            }

            try Task.checkCancellation()

            // --- 取得の見張りを立てる（FR-07 / NFR-10）------------------------------
            //
            // **ディスクに実体が無いとき＝ネットワークからバイトが来るはずのときだけ**立てる。
            //
            // 既に取得済みなら `loadModelContainer` はキャッシュを読んで重みを展開するだけで、
            // その間 **進捗コールバックは1度も鳴らない。** 4.62GB の展開は16GB機だと
            // スワップを噛んで90秒を超えることがあるので、ここで見張ると
            // **正常なロードを殺す。** 正常系を壊さないための線引きがこの `if` である。
            //
            // 代償として「取得済み判定だが一部のファイルが欠けていて再取得が走る」経路は
            // 見張れない。そちらは `MLXModelCatalog.isDownloaded` が
            // config.json と *.safetensors の両方を確認しているぶん、起こりにくい。
            let watch = ModelDownloadStallWatch(startedAt: SuspendingClock().now)
            let watchdog: Task<Void, Never>? = alreadyOnDisk
                ? nil
                : Self.startDownloadWatchdog(
                    watch: watch, modelID: modelID, into: continuation)
            // 正常終了・例外・キャンセルのどれで抜けても必ず畳む。
            defer { watchdog?.cancel() }

            // ダウンロードは初回のみ。2回目以降は HuggingFace のキャッシュから読む。
            //
            // 進捗コールバックは**別スレッドから呼ばれる**が、
            // `AsyncThrowingStream.Continuation` はスレッド安全なのでそのまま yield できる。
            //
            // NFR-01 との関係: ここが `network.client` entitlement を要求する唯一の場所。
            // 会話は一切外に出ない。A2 以降、ローカルディレクトリ読み込み
            // （MLX_SWIFT.md 第2.3節C）に切り替えれば entitlement ごと落とせる。
            let loaded = try await loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { progress in
                    // `Progress` の単位は**バイト**（swift-huggingface の
                    // `snapshotWeight(for:)` が各ファイルのサイズを重みにしている）。
                    // ただしサイズ不明のファイルには既定の重みが入るので、
                    // 総量はおおよその値である。進捗表示には十分。
                    let fraction = progress.fractionCompleted
                    let completed = progress.completedUnitCount
                    let total = progress.totalUnitCount

                    // 見張りへ「いま何バイトか」を渡す。**判定はここではしない。**
                    // このクロージャは swift-huggingface 側のスレッドから
                    // 100ms 間隔で呼ばれるので、重い処理を置くと取得そのものが遅くなる。
                    watch.note(
                        completedBytes: completed, totalBytes: total,
                        at: SuspendingClock().now)

                    continuation.yield(LoadProgress(
                        stage: fraction >= 1.0 ? .loadingWeights : .downloading,
                        completedBytes: completed > 0 ? completed : nil,
                        totalBytes: total > 0 ? total : nil,
                        fraction: fraction,
                        detail: fraction >= 1.0
                            ? "重みをメモリへ展開しています"
                            // **バイト数を必ず添える。** 「0%」だけだと、待てばいいのか
                            // 壊れているのかが判別できない。「0.00 GB / 4.62 GB」なら
                            // 一目で異常だと分かる（今回いちばん欠けていた情報）。
                            : "モデルを取得しています（\(Int(fraction * 100))%・"
                                + "\(formatDownloadedBytes(completed: completed, total: total))）"))
                }
            )

            try Task.checkCancellation()

            continuation.yield(LoadProgress(
                stage: .loadingWeights, fraction: 1, detail: "重みをメモリへ展開しています"))

            // モデルが宣言した思考プロトコルを受け取る。
            // Qwen3 は `QwenReasoningProtocol.qwen3` を自分で宣言し、
            // `LLMModelFactory._load` が `ModelContext.configuration` に載せる。
            let declaredReasoning = await loaded.configuration.reasoningConfig

            container = loaded
            reasoning = declaredReasoning

            var info = entry
            info.isDownloaded = true
            info.supportsThinking = declaredReasoning != nil
            current = info

            // **ロードで何が載ったか。** 重みは 4.62GB なので、
            // `d_active_mb` がその桁に届いていれば「重み＝MLXのアロケーション」と読める。
            // 逆にここが 4.62GB 程度で収まっているのに OS 側のフットプリントが 9GB あるなら、
            // **差の約4.4GB は MLX のアロケーションではない**（＝ここでは説明できない）。
            recordMemory(.loadEnd)

            continuation.yield(LoadProgress(
                stage: .ready, fraction: 1, detail: "準備できました"))
            continuation.finish()

        } catch {
            continuation.finish(throwing: SophiaError.fromModelLoad(error))
        }
    }

    // MARK: - 取得の見張り本体

    /// 取得が進んでいるかを一定間隔で見て、止まっていたら**利用者へ伝える。**
    ///
    /// ## `Task.detached` である理由 ── ここを `Task {}` にしてはいけない
    ///
    /// `Task {}` は囲っている actor（`MLXEngine`）の隔離を**継承する。**
    /// すると見張りは「`MLXEngine` の executor が空くのを待つ」ことになる。
    /// 取得側が `await` を挟まずに回り続けている場合
    /// （今回の事故は **CPU 11〜14% を食っていた** ＝ 何かが回っていた）、
    /// **見張りの番が永久に来ない。** 検知したい状況でだけ検知できない見張りになる。
    /// 独立した executor で回すために `detached` にしてある。
    ///
    /// ## 打ち切り方 ── 例外を投げずにストリームを終わらせる
    ///
    /// `continuation.finish(throwing:)` を呼ぶと、
    ///   1. 読み手（`ChatViewModel.loadModel`）の `for try await` がその場で throw する
    ///      ＝ **画面にエラーが出る。ここが本命**
    ///   2. `load(_:)` で仕込んだ `continuation.onTermination` が発火し、
    ///      `performLoad` の Task がキャンセルされる ＝ 取得側にも止まれと伝わる
    ///
    /// 2 が効くかは取得側の実装次第だが、**1 は取得側の協力なしに必ず成立する。**
    /// 「落ちないまま黙っている」を潰すのが目的なので、この順序で正しい。
    ///
    /// - Returns: 見張りの Task。閾値が `0`（＝無効）なら nil。
    private static func startDownloadWatchdog(
        watch: ModelDownloadStallWatch,
        modelID: String,
        into continuation: AsyncThrowingStream<LoadProgress, any Error>.Continuation
    ) -> Task<Void, Never>? {
        // 閾値を先に値として取り出す。**`Self` を detached クロージャの中で参照しない**
        // ため（静的プロパティは隔離されていないので参照自体は通るが、
        //  「何を見て判定したか」を起動時の値で固定しておきたい）。
        let firstByteGrace = downloadFirstByteGrace
        let stallTimeout = downloadStallTimeout
        let interval = downloadWatchdogInterval
        let logs = logsModelLoad

        // どちらかが 0 なら見張りごと止める（環境変数による緊急避難）。
        guard firstByteGrace > .zero, stallTimeout > .zero else { return nil }

        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                // キャンセルされると `Task.sleep` が throw する。`try?` で受けて
                // 直後にもう一度 `isCancelled` を見る（**畳むのを1周期遅らせない**）。
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }

                let verdict = watch.evaluate(
                    at: SuspendingClock().now,
                    firstByteGrace: firstByteGrace,
                    stallTimeout: stallTimeout)

                switch verdict {
                case .healthy(let report):
                    if logs { writeModelLoadLine("tick", model: modelID, report: report) }

                case .idle(let report):
                    // **まだ打ち切らない。が、黙っていない。**
                    // 閾値の半分を過ぎた時点で「変化がありません」と画面に出す。
                    // 打ち切りまで無言で待たせると、結局「0% のまま固まっている」
                    // という同じ体験になる。
                    //
                    // **[承知の上の限界]** 進捗ハンドラが 100ms 間隔で鳴り続けたまま
                    // バイトだけが増えない場合、この1行は直後のハンドラ側の yield に
                    // 上書きされて消える。**打ち切り（`finish`）は上書きされない**ので
                    // 最終的な通知は必ず届くし、バイト数と経過秒数は画面に出続ける。
                    // ここを勝ち残らせるには `LoadProgress` に警告の段階を足す必要があり、
                    // Shared の型を触ることになるので、今回はそこまでやっていない。
                    if logs { writeModelLoadLine("idle", model: modelID, report: report) }
                    continuation.yield(LoadProgress(
                        stage: .downloading,
                        completedBytes: report.completedBytes > 0 ? report.completedBytes : nil,
                        totalBytes: report.totalBytes > 0 ? report.totalBytes : nil,
                        fraction: report.fraction,
                        detail: report.waitingDetail))

                case .stalled(let report):
                    // **この1行は `SOPHIA_LOG_LOAD` と無関係に必ず出す。**
                    // 「ログ出力 無し」で原因が追えなかったのが今回の事故である。
                    writeModelLoadLine("stalled", model: modelID, report: report)
                    continuation.finish(
                        throwing: SophiaError.modelDownloadStalled(report, modelID: modelID))
                    return
                }
            }
        }
    }

    // MARK: - 生成の中身

    private func performChat(
        _ messages: [SophiaMessage],
        options rawOptions: ChatOptions,
        into continuation: AsyncThrowingStream<Chunk, any Error>.Continuation
    ) async {
        // 計測の起点。**必ずこの時計を使う。** `Date()` を各自が挟むと
        // TTFT の起点がずれ、BENCH_RESULTS.md の数字が比較不能になる。
        var clock = GenerationClock()

        // 思考モードの maxTokens 補正は「エンジン呼び出しの直前で1回だけ」。
        // 実測では出力の約9割を思考が食い、上限が小さいと本文に到達しない。
        let options = rawOptions.applyingThinkingBudget()

        guard let container else {
            continuation.finish(throwing: SophiaError(code: .modelNotLoaded))
            return
        }
        guard !isGenerating else {
            continuation.finish(throwing: SophiaError(
                code: .generationFailed,
                message: "前の応答がまだ生成中です。",
                hint: "生成が終わるか、停止してから送信してください。"))
            return
        }
        isGenerating = true
        defer { isGenerating = false }

        // `defer` は**逆順**に走るので、これは `isGenerating = false` より先に動く。
        // 生成中フラグが立っている間に測り終える ＝ 次の生成と窓が重ならない。
        defer { finishMemoryMeasurement() }

        // ピークメモリの計測窓をこの生成に絞る。
        //
        // `Memory.peakMemory` は**プログラム開始からの最大値**なので、
        // 何もしないと「アプリ起動以来のピーク」が毎回同じ値で返り、
        // 生成ごとの比較ができない。setter は newValue を無視して
        // `mlx_reset_peak_memory()` を呼ぶ（MLX 0.31.6 の実装）。
        //
        // プロセス全体で1つの値なので、**生成を直列化していることが前提**になる
        // （上の `isGenerating` がそれを担保している）。
        // ロードと生成が重なると汚れるが、A1 の使い方では重ならない。
        MLX.Memory.peakMemory = 0

        // **この生成の基準点。** ピークをリセットした**あと**に取るのが要点で、
        // ここでの `peak_mb` は「リセット直後の値」＝ほぼ `active_mb` になる。
        // 以降の段階の `d_peak_mb` が、この生成だけで押し上げた分になる。
        recordMemory(.generateBegin)

        // プリフィル完了の瞬間を拾うための箱（詳細はファイル末尾 `PrefillMemoryProbe`）。
        // **actor の外から書かれる**ので、ここでは受け皿を用意するだけ。
        let prefillProbe = PrefillMemoryProbe(enabled: Self.memoryProbeRecords)

        // 周をまたいで KVキャッシュと「そこへ払い済みのトークン列」を持ち回る箱
        // （詳細はファイル末尾「プリフィルの再利用」）。**このターンの中だけ生きる。**
        //
        // engine のプロパティにしていないのは、KVキャッシュを次のターンまで
        // 抱えたままにしないためである ── 16GB機で 100MB 台を黙って握るのは高い。
        // ターンをまたぐ再利用は、この中での効果を実測してから考えること。
        let prefillLedger = PrefillCacheLedger()
        let prefillReuseEnabled = Self.prefillReuseEnabled
        // 正常終了・中断・失敗のどれで抜けても KVキャッシュを手放す。
        //
        // **`defer` は逆順に走る**ので、これは上の `finishMemoryMeasurement()` より先に動く。
        // つまり `generate_end` の点は「キャッシュを手放したあと」で取られる ──
        // 再利用を入れる前と同じ状態を測っていることになり、A/B がそのまま並べられる。
        defer { prefillLedger.clear() }

        // --- 往復をまたいで足し合わせる計測値（FR-14 / 16章）---------------------
        //
        // **ツールの往復は「1回の生成」ではなく「複数回の生成」である。**
        // 最後の1回ぶんだけを `.done` に載せると、読みに行くために払った
        // プリフィルが数字から消える ── VISION の一次資料として、消えるのがいちばん困る。
        //
        // 往復が起きない会話（`idle`。既定）は1周で抜けるので、
        // **これらの値は往復を入れる前と1トークンも変わらない。**
        // （`prefillTokensPerSecond` も `promptTokenCount / promptTime` の定義どおり同値になる）
        //
        // `do` の外に置いてあるのは、中断（`CancellationError`）の経路でも
        // 同じ値から `.done` を組むためである。
        var promptTokenTotal = 0
        /// **時間の分かっている**プリフィルのトークン数だけを数える。
        /// 速度の分母（`prefillSecondsTotal`）と分子の出所を揃えるためで、
        /// 中断された周（時間が無い）を分子だけに足すと**速度が水増しされる。**
        var timedPromptTokens = 0
        var outputTokenTotal = 0
        var prefillSecondsTotal: Double = 0
        var decodeSecondsTotal: Double = 0
        var sawCompletionInfo = false

        // まだ `.info` で確定していない、**いまの周**のプリフィル。
        // 中断で `.info` が届かないまま抜けたとき、この周ぶんを落とさないために持つ。
        // `prepare` へ到達する前に落ちた場合は送信前の概算のまま（従来と同じ）。
        var pendingPromptTokens = messages.estimatedTokenCount

        do {
            // --- 入力を組む -----------------------------------------------------
            //
            // **`[Chat.Message]` を往復のあいだ持ち回らないこと。**
            // あれは `Sendable` ではなく、`ModelContainer.prepare(input:)` は
            // `consuming sending UserInput` で受け取る。持ち回ると領域解析（SE-0414）に
            // 「送ったあとに触っている」と言われる ── **Sendable な記録で持ち、
            // 毎周そこから組み直す**のが素直な形である（`RoundTripMessage`）。
            var transcript: [RoundTripMessage] = messages.map { message in
                switch message.role {
                case .system: .system(message.content)
                case .user: .user(message.content)
                case .assistant: .assistant(message.content, toolCalls: [])
                }
            }

            // 思考モードの ON/OFF（FR-18）。**キー名をハードコードしない。**
            // Qwen3 は `enable_thinking`、DeepSeek-R1 系は OFF にできず throw する。
            let strategy = reasoning?.promptStrategy
                ?? .templateFlag(key: "enable_thinking", defaultOn: true)
            let additionalContext = try strategy.additionalContext(
                forThinkingEnabled: options.thinking)

            // --- ツール定義（FR-19 / FR-21。DESIGN.md 第16.2節）--------------------
            //
            // **FR-21 はこの1行に還元されている。** テンプレートの `{%- if tools %}` が
            // 門なので、`nil` を渡せばツールの system ブロックは1文字も描画されない。
            // `toolSpecs(for:)` は空配列を **nil に潰す**（`[]` を渡さない）:
            // Jinja では `[]` も偽なので結果は同じだが、**保証をこちら側に置く**ためである。
            //
            // ここに「利用者の文を見てツールが要るか推定する」判定を書かないこと（16.2節）。
            // **引き金は利用者の操作だけ**であり、この関数に届く時点では
            // `options.tools` が空かどうかに潰れている。
            //
            // **`var` なのは往復の途中で門を閉じることがあるから**である
            // （上限に達したとき。下の往復ループの解説を読むこと）。
            var toolSpecs = Self.toolSpecs(for: options.tools)

            // --- ツールの実行役（FR-19 / 16.6節 約束3）-----------------------------
            //
            // **門が閉じている会話では、実行役に一度も触らない。**
            // 実行役が刺さっているかどうかで振る舞いが変わってはいけない ──
            // `idle` → `armed` の引き金は**利用者の操作だけ**である（約束3）。
            let executor = Self.activeToolExecutor(toolExecutor, toolsWereSent: toolSpecs != nil)
            if toolSpecs != nil, executor == nil {
                // **ツールを見せているのに、実行できる役がいない。**
                // モデルは呼ぶが誰も答えない ＝ 往復が成立しない。
                // 黙って捨てない（16.8節）ので、必ず1行残す。
                writeToolLine("no_executor", fields: [("tools", "\(options.tools.count)")])
            }
            // **新しい利用者の発言。** 往復の回数を戻すのはここ1か所だけ（16.8節）。
            // 呼び出し側に任せると、呼び忘れた会話だけが2回目から読めなくなる。
            await executor?.beginRoundTrip()

            // --- 生成パラメータ（往復しても変えない）-------------------------------
            var configured = GenerateParameters(
                maxTokens: options.maxTokens,
                maxKVSize: options.maxKVSize,
                kvBits: options.kvBits,
                kvScheme: options.kvScheme,
                temperature: Float(options.temperature),
                topP: Float(options.topP),
                topK: options.topK,
                repetitionPenalty: options.repetitionPenalty.map(Float.init),
                seed: options.seed
            )

            // プリフィルの進捗（`main` リビジョンにのみ存在する）。
            //
            // **これが A1 の隠れた要件に効く。** 思考モードでは本文が出るまで
            // 15〜29秒かかるが、その前半はプリフィルである。ここを出せると
            // 「無言でフリーズしているように見える時間」が消える。
            //
            // **往復の2周目以降もここが鳴る。** ツールを実行したあとの無言は、
            // 実際には次のプリフィルであり、既存の進捗表示がそのまま埋めてくれる。
            configured.prefill.progress = { processed, total in
                continuation.yield(.prefill(PrefillProgress(
                    processedTokens: processed, totalTokens: total)))
                // **本丸の計測点。** ここは actor の外（MLX の計算スレッド）なので、
                // 直接 `recordMemory` を呼べない（`@Sendable` クロージャから
                // actor 隔離の状態には触れない）。箱へ落として actor 側で拾う。
                prefillProbe.record(processed: processed, total: total)
            }

            // `var` のままだと `@Sendable` クロージャに捕まえられない
            // （"reference to captured var in concurrently-executing code"）。
            // 組み立てが終わったら不変にしてから渡す。
            let parameters = configured
            let components = makeGenerationComponents(options: options)

            var sawFirstChunk = false
            var round = 0
            var gateClosedByLimit = false
            /// 最後の周の `.info` から取った終了理由。**周ごとに上書きする**
            /// （前の周の値が残ると、中断した周を「正常終了」と申告してしまう）。
            var lastStopReason: StopReason?

            // =====================================================================
            //  往復のループ（FR-19 / DESIGN.md 第16章）
            // ---------------------------------------------------------------------
            //  **必ず終わる。** 終わり方は3つで、どれも「エンジンが回数を数えること」に
            //  頼っていない ── 上限を数える場所は実行役ただ1つである（16.8節）。
            //
            //  | 抜ける条件 | 決めたのは誰か |
            //  |---|---|
            //  | この周でツールを呼ばなかった | モデル。**普通はここで抜ける** |
            //  | 実行役が「もう渡すな」と言った → **門を閉じてあと1周** | 実行役（往復の上限） |
            //  | 実行役がいない | アプリ（差し込まれていない） |
            //  | 安全弁 `maximumToolRounds` | ここ。**正常時は当たらない** |
            //
            //  門を閉じた周は `toolSpecs == nil` なので、`route(_:toolsWereSent:)` が
            //  呼び出しを1件も通さない ＝ **その周で `calls` が必ず空になり、ループが終わる。**
            //  「あと1周だけ回す」のは、上限に達したことをモデルへ伝えて
            //  **いま分かっている範囲で答えさせる**ためである（16.8節）。
            //  ここで打ち切ると、利用者には**読んだきり黙って終わった**ように見える。
            //
            //  ## 周ごとのプリフィル ── いくら払っているかは `[PREFILL]` 行に出る
            //
            //  周ごとに `prepare` からやり直すので、**描画されるのは毎回会話全体**である。
            //  払う量をそこから減らすのが `startPrefillRound` の仕事で、
            //  台帳と突き合わせて一致した接頭辞ぶんだけキャッシュから持ち越す
            //  （**既定は無効。** 詳細はファイル末尾「プリフィルの再利用」）。
            //
            //  再利用が効かない周・効かせない設定では、**従来どおり全部払う。**
            //  どちらだったかは周ごとに1行残る:
            //
            //      [PREFILL] round=2 prompt=1271 fed=812 reused=459 ... decision=trim_append
            //      [PREFILL] round=2 prompt=1271 fed=1271 reused=0 ... decision=rebuild reason=off
            //
            //  費用は `.done` の `inputTokens`（周ごとの**描画量**の合計）に必ず載る。
            //  **実際に払った量は `[PREFILL] fed=` のほうである** ── 2つは別物なので
            //  混ぜないこと（再利用が無効なら常に同値になる）。
            //
            //  **周の頭で第2段の縮約を通している**のは変わらない（16.3節 / `compacted`）。
            //  再利用は「同じ接頭辞を2度払わない」だけで、**描画量そのものは減らさない。**
            //  古い読み取りを栞1行に落とすのは今でも縮約の仕事である。
            // =====================================================================
            rounds: while true {
                round += 1
                try Task.checkCancellation()

                // **`[MEM]` の点に周番号を載せる。** これが無いと `prefill_end` が
                // 2行並んだとき、どちらがどの周か後から復元できない（2026-08-18 に実際に困った）。
                prefillProbe.beginRound(round)

                // クロージャへ渡すので不変にする（`toolSpecs` は var である）。
                let roundTools = toolSpecs

                // --- 第2段の縮約（DESIGN.md 第16.3節）-----------------------------
                //
                // **ここが「生の戻り値を落として栞1行に置き換える」の実行点である。**
                // 1回の読み取りは 360トークンまで、往復は6回まで ＝ **1ターンで 2,160。**
                // 入力予算は 1,000 で、しかも**周ごとに会話全体をプリフィルし直す**
                // （上の但し書き）。落とさなければ、積み上がった中身を毎周払い直すことになる。
                //
                // 上限を `roundTools` から出しているのは、**門が閉じた周は
                // ツール定義を1文字も送らない**からである（FR-21）。
                // 送らない周にツール定義ぶん（322）を引くと、その周だけ不当に厳しくなる。
                //
                // **落とすのは送信列だけで、`transcript` は生のまま置いておく。**
                // 毎周ここから組み直すので、この層に状態は要らない（`ContextTranscript` の但し書き）。
                let compaction = Self.compacted(
                    transcript,
                    budget: SophiaDefaults.InputBudget.transcript(armed: roundTools != nil))

                // **落としたら必ず言う**（16.3節）。宛先は2つあり、両方へ出している ──
                //   モデルへ … 栞の次の行（`ContextTranscript.demotionNotice`）
                //   開発者へ … この1行。**収まらなかった周も出す**
                //             （落とさずに超えている、が一番見えなくてはいけない状態である）
                if compaction.fit.demotedReads > 0 || !compaction.fit.fits {
                    writeToolLine("compacted", fields: [
                        ("round", "\(round)"),
                        ("demoted", "\(compaction.fit.demotedReads)"),
                        ("tokens", "\(compaction.fit.tokens)"),
                        ("budget", "\(compaction.fit.budget)"),
                        ("fits", compaction.fit.fits ? "1" : "0"),
                        ("counter", compaction.fit.tokensAreEstimated ? "estimate" : "exact"),
                    ])
                }

                // **毎周ここで組み直す。** Sendable な記録から作るので、
                // 出来た配列は独立した領域に入り、そのまま `prepare` へ送れる。
                let chat = Self.chatMessages(for: compaction.messages)

                // チャットテンプレート（Jinja）はこの `prepare` の内側で
                // トークナイザが適用する。Ollama ではサーバの仕事だった部分。
                let lmInput = try await container.prepare(input: UserInput(
                    chat: chat, tools: roundTools, additionalContext: additionalContext))

                let promptTokens = lmInput.text.tokens.asArray(Int.self)
                pendingPromptTokens = promptTokens.count

                guard promptTokens.count < options.contextLength else {
                    // **2周目以降は文言を変える。** 「入力を短くしてください」と言われても、
                    // 利用者は短い一文しか打っていない ── 膨らませたのは読み込んだ中身である。
                    throw SophiaError(
                        code: .contextOverflow,
                        hint: round == 1
                            ? "入力が \(promptTokens.count) トークンで、"
                                + "上限 \(options.contextLength) を超えています。"
                                + "会話を新しく始めるか、入力を短くしてください。"
                            : "読み込んだ内容を足したところ \(promptTokens.count) トークンになり、"
                                + "上限 \(options.contextLength) を超えました。"
                                + "読む範囲を狭めるか、会話を新しく始めてください。")
                }

                // --- 思考分離器を用意する（FR-17）------------------------------
                // **周ごとに作り直す。** `primedInside` は描画済みプロンプトの末尾から
                // 導出するので、周が変われば判定もやり直しになる。
                var separator = await makeSeparator(
                    container: container, promptTokens: promptTokens)

                // --- 生成ストリームを開く ---------------------------------------
                //
                // 注意: プリフィルは `TokenIterator.init` の中、つまり
                // **この `generate` 呼び出しの内側で同期的に走る。**
                // 上の progress コールバックはストリームが返る前に発火する。
                // `continuation` は既に存在しているので取りこぼさない。
                //
                // **`tools:` をここでも渡すこと。`UserInput` に入れただけでは足りない。**
                // 別経路である ── `UserInput.tools` はテンプレートの描画にしか効かず、
                // `generate` の `tools:` は `ToolCallProcessor` の `allowedToolNames` になる
                // （`Evaluate.swift:1746-1763` → `ToolCallProcessor.init`）。
                // 渡さないと `allowedToolNames` が nil になり、**未宣言の名前でも
                // そのまま `.toolCall` として通る**（`?? true` に落ちる）。
                // 渡してあれば、モデルが名前を捏造したとき `.rejectedToolCall(.undeclaredTool)`
                // として弾かれる ── 16.8節「ツール名が一致しない」の第一の防壁である。
                //
                // **`generate` の呼び出しは `startPrefillRound` の中へ移してある。**
                // `[KVCache]` も `ModelContext` も `Sendable` ではないので、
                // 台帳との突き合わせも巻き戻しも `perform` の内側でやるしかない
                // （ファイル末尾「プリフィルの再利用」）。
                // **再利用が無効なら、あの中は `generate` を1回呼ぶだけに潰れる。**
                let started = try await container.perform(nonSendable: lmInput) { context, input in
                    try Self.startPrefillRound(
                        context: context,
                        preparedInput: input,
                        promptTokens: promptTokens,
                        ledger: prefillLedger,
                        reuseEnabled: prefillReuseEnabled,
                        parameters: parameters,
                        components: components,
                        tools: roundTools)
                }
                let stream = started.stream

                // --- プリフィル完了の1点を回収する -------------------------------
                //
                // **ここで拾えるのは、プリフィルが `perform` の内側で終わっているから。**
                // `MLXLMCommon.generate` は `TokenIterator` を**先に**組み立ててから
                // ストリームを返す（Evaluate.swift の `generate(input:cache:...)`）。
                // プリフィルはその `init` の中で同期的に走るので、この行に来た時点で完了している。
                //
                // ただし箱に入っているのは「最後に届いた進捗の時点」であって、
                // **必ずしも `processed == total` ではない**（`prefill_processed` を必ず見ること）。
                // 出揃った側が要るなら次の `first_token` を見ること。
                if let reading = prefillProbe.take() { appendMemory(reading) }

                // --- 断片を流す ---------------------------------------------------
                //
                // **間引かない。** 受け取った断片をそのまま全件流す。
                // 16ms のバッファリングは UI 側の責務（エンジンが間引くと計測が汚れる）。
                //
                // 振り分けの規則は `MLXEngine.route(_:toolsWereSent:)` に切り出してある。
                // **モデルを読み込まずにテストできるようにするため**であり、
                // `EngineToolWiringTests` が「`.toolCall` は分離器を通らない」を固定している。
                var info: GenerateCompletionInfo?
                /// この周でモデルが呼んだツール。**流し終えてからまとめて実行する。**
                var calls: [ModelToolCall] = []
                /// この周の**本文**（思考は入らない）。会話へ書き戻すのはこちらだけ。
                var visibleText = ""

                for await item in stream {
                    switch Self.route(item, toolsWereSent: roundTools != nil) {

                    case .separatorText(let text):
                        // **確保が出揃った側の計測点。** 断片が復号されて届いた ＝
                        // プリフィルの最終フォワードも最初のデコードも `eval` が済んでいる。
                        // 往復しても**1回だけ**取る（2周目は「最初の」ではない）。
                        if !sawFirstChunk {
                            sawFirstChunk = true
                            recordMemory(.firstToken, round: round)
                        }
                        for segment in separator.process(text) {
                            // **思考は溜めない。** 書き戻さないものを持たない
                            // （`InferenceEngine` の約束6）。
                            if case .content(let body) = segment { visibleText += body }
                            emit(segment, clock: &clock, into: continuation)
                        }

                    case .passThrough(let chunk):
                        // **分離器を通さずに流す。** ツール呼び出しは本文でも思考でもない。
                        clock.record(chunk)
                        continuation.yield(chunk)
                        // **ここでは溜めるだけ。** 途中で実行すると、まだ流れてくる断片と
                        // ファイルの I/O が重なる（同じ周に2つ目の呼び出しが来ることがある）。
                        if case .toolCall(let call) = chunk { calls.append(call) }

                    case .completion:
                        info = item.info

                    case .unexpectedToolCall(let name):
                        // **ツールを渡していないのに呼んできた。** 実行できるものが無いので流さない。
                        // 16.6節の約束3 ── 注入の状態をモデルの出力で変えない。
                        //
                        // ただし**2つの事情を同じ行にしない。**
                        //   `call_after_limit` … 上限で門を閉じた周。**正常な帰結**
                        //   `unexpected_call`  … そもそも渡していない会話。**前提が揺れる報せ**
                        writeToolLine(
                            gateClosedByLimit ? "call_after_limit" : "unexpected_call",
                            fields: [("tool", name)])

                    case .rejected(let reason, let name):
                        // 形式が壊れていた／宣言していない名前だった。
                        // **原文は絶対に出さない** ── `RejectedToolCall.rawTextPreview` は
                        // 「ライブラリが自動でログや永続化に載せてはならない」と明記されており、
                        // 引数には利用者のファイル名や検索語が入る（NFR-01）。
                        writeToolLine(
                            "rejected", fields: [("reason", reason), ("tool", name ?? "-")])

                    case .ignored:
                        break
                    }
                }

                // 保留していた末尾を吐き出す。**呼び忘れると末尾が消える。**
                for segment in separator.finalize() {
                    if case .content(let body) = segment { visibleText += body }
                    emit(segment, clock: &clock, into: continuation)
                }

                // --- この周の計測を足す -------------------------------------------
                //
                // **2つの数を混ぜないこと。**
                //   `promptTokenTotal` … その周に**描画した**プロンプト全体。
                //                        モデルが条件付けした量で、`.done` の `inputTokens`
                //                        ＝ `[STATS] in=` の意味はこちらである
                //   `timedPromptTokens` … その周に**実際に払った**量（`info.promptTokenCount`）。
                //                        速度の分子。**分母（`promptTime`）と出所を揃える**
                //
                // 再利用が無効なら2つは常に同値で、行の意味は入れる前と1トークンも変わらない。
                if let info {
                    sawCompletionInfo = true
                    promptTokenTotal += promptTokens.count
                    timedPromptTokens += info.promptTokenCount
                    outputTokenTotal += info.generationTokenCount
                    prefillSecondsTotal += info.promptTime
                    decodeSecondsTotal += info.generateTime
                } else {
                    // 中断などで `.info` が届かなかった周。**入力ぶんだけは実測値がある。**
                    promptTokenTotal += pendingPromptTokens
                }

                // --- この周のプリフィルを1行残す（**周ごとに必ず出る**）--------------
                //
                // これが「直す前・直したあと」を並べるための一次資料である。
                //   `prompt` … 描画したトークン数
                //   `fed`    … **実際に払った**トークン数。**prompt との差が効いた量**
                //   `s`      … その周のプリフィル秒（`.info` が来なかった周は `-`）
                writePrefillLine([
                    ("round", "\(round)"),
                    ("prompt", "\(promptTokens.count)"),
                    ("fed", "\(started.fedTokens)"),
                    ("reused", "\(started.decision.reusedTokens)"),
                    ("trimmed", "\(started.decision.trimmedTokens)"),
                    ("decision", started.decision.logName),
                    ("reason", started.decision.logReason),
                    ("s", info.map { String(format: "%.2f", $0.promptTime) } ?? "-"),
                    ("tools", roundTools == nil ? "0" : "\(roundTools?.count ?? 0)"),
                ])

                // **周ごとに上書きする**（nil も含めて）。前の周の値を残さない。
                lastStopReason = info.map { Self.stopReason(from: $0, cancelled: false) }
                pendingPromptTokens = 0

                // --- 往復するか ----------------------------------------------------
                //
                // 16.8節「モデルがツールを呼ばずに答えた」も**異常ではない。**
                // ここを抜けるのが普通の経路である。
                guard !calls.isEmpty else { break rounds }
                guard let executor else {
                    // 実行できる役がいない。呼び出しは画面へ流したが、往復はしない
                    // （`no_executor` の行は生成に入る前に出している）。
                    break rounds
                }
                // **中断されたなら読みに行かない。** 停止を押した直後にファイルを開かない。
                if Task.isCancelled { break rounds }

                // --- モデル自身の呼び出しを会話へ書き戻す（16.1節）--------------------
                //
                // **これを省くと往復が壊れる。** テンプレートの assistant の枝は
                // `{%- if message.tool_calls %}` で `<tool_call>` を描く。書き戻さないと
                // `<tool_response>` が**対応する `<tool_call>` なしで現れ**、
                // モデルから見て「誰が何を訊いたのか分からない返事」になる。
                //
                // 本文は `visibleText`（分離器が本文として出したぶん）だけ。
                // **思考は書き戻さない**（`InferenceEngine` の約束6）。
                transcript.append(
                    .assistant(visibleText, toolCalls: calls.map(Self.toolCall(from:))))

                for call in calls {
                    // **実行する。throw しない**（失敗も戻り値。16.8節）。
                    let outcome = await executor.execute(call)

                    // 連続する tool メッセージは、テンプレートが**1つの user ターンに
                    // まとめて**描画する（16.1節）。だから素直に並べてよい。
                    // 落とせる側に入れるかどうかは `transcriptEntry(for:)` が決める。
                    transcript.append(Self.transcriptEntry(for: outcome))

                    // **無言の時間を埋める。** 区間の始まりは `.toolCall` が既に伝えており、
                    // ここが終わりである（16.7節「何を読んだか」）。
                    continuation.yield(.toolResult(outcome.activity(round: round)))

                    if outcome.stopsRoundTrips, !gateClosedByLimit {
                        gateClosedByLimit = true
                        writeToolLine(
                            "limit_reached",
                            fields: [("round", "\(round)"), ("tool", outcome.toolName)])
                    }
                }

                if gateClosedByLimit {
                    // **あと1周だけ、道具無しで回す。** 門を閉じればテンプレートに
                    // `<tools>` が描かれず、モデルは呼びようがない（FR-21 と同じ仕掛け）。
                    // 上限に達した旨は、いま足した戻り値の文がモデルへ伝えている。
                    toolSpecs = nil
                } else if round >= Self.maximumToolRounds {
                    // **安全弁。** ここに当たるのは実行役の上限が効いていないときだけである。
                    writeToolLine("round_limit", fields: [("rounds", "\(round)")])
                    toolSpecs = nil
                }
            }

            // --- 終端と計測（FR-14）------------------------------------------------
            //
            // ここに来る経路は3つある。
            //   1. 正常終了 → `.info` が届いている
            //   2. 中断 → `AsyncStream` は nil を返して抜ける。`.info` は届かないことがある
            //   3. 上限打ち切り → `.info` の `stopReason` が `.length`
            let cancelled = Task.isCancelled
            let stopReason = lastStopReason ?? (cancelled ? .cancelled : .completed)

            // 中断時に `.info` が1周も来なかった場合だけ、文字数から概算する。
            // 概算であることは `EngineCapabilities.reportsExactTokenCounts` では
            // 表現できないので、BENCH に載せるときは `stopReason == .cancelled` を見ること。
            //
            // **[承知の上の粗さ]** 「前半の周は `.info` が来て、最後の周が中断された」
            // 場合、最後の周の出力トークンは数に入らない（**過少に出る**）。
            // 過大に出すより害が小さいほうへ倒してある。
            let estimatedOutput = Int(ceil(
                Double(clock.thinkingCharacterCount + clock.contentCharacterCount) * 0.5))

            continuation.yield(.done(clock.finish(
                inputTokens: promptTokenTotal,
                outputTokens: sawCompletionInfo ? outputTokenTotal : estimatedOutput,
                stopReason: stopReason,
                prefillSeconds: sawCompletionInfo ? prefillSecondsTotal : nil,
                // **率は足さずに、合計から割り直す。** 率の平均は率ではない。
                prefillTokensPerSecond: prefillSecondsTotal > 0
                    ? Double(timedPromptTokens) / prefillSecondsTotal
                    : nil,
                decodeSeconds: sawCompletionInfo ? decodeSecondsTotal : nil,
                // 思考トークンは実測できない（分離器は復号後のテキストしか見ない）。
                // nil を渡すと `GenerationClock` が文字数から概算し、
                // `thinkingTokensAreEstimated` を立ててくれる。
                thinkingTokens: nil,
                modelID: current?.id,
                thinkingEnabled: options.thinking,
                // 生成開始時にリセットしてあるので、この生成でのピーク。
                // **[未確認]** `peakMemory` は実際のGPUフットプリントを過少報告する
                // という外部報告がある（MLX_SWIFT.md 第8.4節）。鵜呑みにせず、
                // 速度の外れ値を説明したいときはアクティビティモニタと突き合わせること。
                peakMemoryBytes: MLX.Memory.peakMemory
            )))
            continuation.finish()

        } catch is CancellationError {
            // **プリフィル中に中断された経路。** ここは「失敗」ではない（FR-02）。
            //
            // プリフィルは 512 トークン単位で刻まれ、その境目で
            // `Task.checkCancellation()` が入っている（`PrefillParameters.forEachChunk`）。
            // つまり長いプロンプトの処理中でも中断が効き、そのとき例外として上がる。
            // 往復のループ先頭の `Task.checkCancellation()` もここへ来る。
            //
            // 生成ループまで進んでいた場合はここへ来ず、上の正常経路で `.done` を出す
            // （`AsyncStream` はキャンセル時に例外ではなく終端で抜けるため）。
            // **どちらの経路でも `.done` の出し方を揃えておく。**
            // 消費側が既に離脱していればこの yield は捨てられる。それで正しい。
            continuation.yield(.done(clock.finish(
                inputTokens: promptTokenTotal + pendingPromptTokens,
                outputTokens: sawCompletionInfo
                    ? outputTokenTotal
                    : Int(ceil(Double(
                        clock.thinkingCharacterCount + clock.contentCharacterCount) * 0.5)),
                stopReason: .cancelled,
                prefillSeconds: sawCompletionInfo ? prefillSecondsTotal : nil,
                decodeSeconds: sawCompletionInfo ? decodeSecondsTotal : nil,
                modelID: current?.id,
                thinkingEnabled: options.thinking,
                peakMemoryBytes: MLX.Memory.peakMemory
            )))
            continuation.finish()

        } catch {
            continuation.finish(throwing: SophiaError.fromGeneration(error))
        }
    }

    // MARK: - 断片の送出

    /// 分離結果を `Chunk` にして流し、同時に計測へ記録する。
    ///
    /// **計測と送出を必ずセットにするための関数。** 片方だけ書くと TTFT がずれる。
    private func emit(
        _ segment: ThinkingSegment,
        clock: inout GenerationClock,
        into continuation: AsyncThrowingStream<Chunk, any Error>.Continuation
    ) {
        let chunk: Chunk =
            switch segment {
            case .thinking(let text): .thinking(text)
            case .content(let text): .content(text)
            }
        clock.record(chunk)
        continuation.yield(chunk)
    }

    // MARK: - ツール（FR-19 / FR-21 / DESIGN.md 第16章）

    /// **FR-21 の門。** 空なら `nil` を返す ── テンプレートの `{%- if tools %}` が
    /// 開かず、ツールの system ブロックは**1文字も出ない**（16.1節・16.2節）。
    ///
    /// 空配列をそのまま渡しても Jinja では偽なので結果は同じだが、**それに頼らない。**
    /// 依存先の真偽値の扱いではなく、**自分のコードで 0 を保証する**ほうが、
    /// テンプレートを差し替えたときに壊れない。
    ///
    /// 呼び分けの判断はここでしない。**引き金は利用者の操作だけ**であり（16.2節）、
    /// この関数に届く時点では「配列が空かどうか」に潰れている。
    /// **利用者の文からツールの要否を推定する分類器をここに書かないこと。**
    nonisolated static func toolSpecs(for tools: [ToolDefinition]) -> [ToolSpec]? {
        guard !tools.isEmpty else { return nil }
        return tools.map(toolSpec(for:))
    }

    /// **門が閉じている会話では、実行役を取り出さない**（FR-21 / 16.6節 約束3）。
    ///
    /// 実行役はアプリの寿命に近い長さで刺さりうる（会話ごとに付け替える）。
    /// 一方でツールを見せるかどうかは**そのターンの `options.tools`** で決まる。
    /// **この2つを掛け算するのがここ**である ── 掛けずに実行役だけを見ると、
    /// 「刺さっているから使える」という経路ができ、
    /// **利用者の操作以外で `idle` が `armed` に変わる**（約束3が破れる）。
    ///
    /// `route(_:toolsWereSent:)` が「渡していないのに来た呼び出し」を落とすので
    /// 二重の守りになるが、**片方に頼らない。** あちらはモデルの出力に対する門、
    /// こちらは実行役に対する門で、守っているものが違う。
    ///
    /// **`static` にしてあるのはテストのため**（`ToolRoundTripTests`）。
    nonisolated static func activeToolExecutor(
        _ installed: (any ToolExecuting)?, toolsWereSent: Bool
    ) -> (any ToolExecuting)? {
        toolsWereSent ? installed : nil
    }

    /// `ToolDefinition` を OpenAI 互換の JSON Schema へ落とす。
    ///
    /// **この形は実測で通っている**（2026-08-18 `make toolprobe`: 選択 12/12・
    /// スキーマ適合 12/12・誤爆 0/6）。`ToolCallProbeTests.toolSpecs()` に直書きされている
    /// 形と同じものが出るよう組んであり、`EngineToolWiringTests` がそれを固定している。
    /// **形を変えるなら測り直すこと。**
    ///
    /// 型注釈を各段に明示してあるのは好みではない。`[String: any Sendable]` の
    /// 入れ子はリテラルのままだと型推論が `[String: String]` 等へ落ちて
    /// コンパイルが通らない（`ToolCallProbeTests` が `as [String: any Sendable]` を
    /// 各段に書いているのと同じ理由）。
    nonisolated static func toolSpec(for definition: ToolDefinition) -> ToolSpec {
        var properties: [String: any Sendable] = [:]
        for parameter in definition.parameters {
            let property: [String: any Sendable] = [
                "type": parameter.type.rawValue,
                "description": parameter.description,
            ]
            properties[parameter.name] = property
        }

        let parameters: [String: any Sendable] = [
            "type": "object",
            "properties": properties,
            "required": definition.requiredParameterNames,
        ]
        let function: [String: any Sendable] = [
            "name": definition.name,
            "description": definition.description,
            "parameters": parameters,
        ]
        return ["type": "function", "function": function]
    }

    /// MLX の `ToolCall` を、MLX を知らない `ModelToolCall` へ落とす（NFR-09）。
    ///
    /// **`Tools/ToolCallRequest` をここで作らないこと。** あちらは実行層の型で、
    /// 引数の解釈まで持っている。推論層が作ると、**エンジンがツールの意味を知る**
    /// ことになり、差し替え可能性（NFR-09）が静かに失われる。
    /// 橋渡しは `ToolCallRequest(name:jsonArguments:)` を呼ぶ側の仕事である。
    ///
    /// 引数は `[String: JSONValue]` ── **ライブラリが既にパースし終えた型付きの値**である。
    /// ここで JSON 文字列へ戻すのは、`Shared/` に MLX の型を持ち込まないためだけの理由。
    ///
    /// `.sortedKeys` を付けてあるのは**同じ呼び出しが同じ文字列になるようにする**ため。
    /// 付けないと辞書の並びが実行ごとに変わり、`Equatable` な比較もログの突き合わせも壊れる。
    nonisolated static func modelToolCall(from call: ToolCall) -> ModelToolCall {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        // 失敗経路は実際には無いはず（`JSONValue` は JSON で表せる値しか持てない）。
        // それでも握りつぶさず、**空の引数として渡す** ── 受け取った側が
        // 「必須の引数が無い」と判断してモデルへ返せる（16.8節: 往復を1回で打ち切らない）。
        let json =
            (try? encoder.encode(call.function.arguments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return ModelToolCall(
            name: call.function.name, argumentsJSON: json, callID: call.id)
    }

    /// **`modelToolCall(from:)` の逆。** 会話へ書き戻すために MLX の `ToolCall` へ戻す。
    ///
    /// ## なぜ「戻す」形なのか（元の値を持ち回らないのはなぜか）
    ///
    /// 生成ストリームから来た `ToolCall` をそのまま取っておく手もあるが、
    /// それには `GenerationRoute` に MLX の型を載せることになり、
    /// **`route` を固定している既存の試験（`EngineToolWiringTests`）が形ごと変わる。**
    /// 往復のために試験の形を崩すのは順序が逆である。
    ///
    /// ## 何が戻り、何が戻らないか（2026-08-18 に測り直した）
    ///
    /// ここには「`JSONValue` は `Codable` なので**同じ型付き値に戻る**」と書いてあった。
    /// **戻らない。** JSON の文へ書いた時点で Swift 側の札（`.int` / `.double`）は
    /// 「数」1種類に潰れ、読み戻すときに `JSONValue.init(from:)` が
    /// Bool → Int → Double の順で試すので、**整数として読めるものは `.int` になる。**
    /// 実測（`AdversarialRoundTripTests.testWholeNumberDoublesDoNotSurviveTheRoundTrip`）:
    ///
    /// | 入れた値 | 戻る値 |
    /// |---|---|
    /// | `.double(80.0)` | **`.int(80)`** |
    /// | `.double(-0.0)` | **`.int(0)`**（ゼロの符号は消える） |
    /// | `.array([.int(1), .double(2.0)])` | 中の `2.0` が `.int(2)` |
    /// | `.object(["k": .double(3.0)])` | `.object(["k": .int(3)])` |
    ///
    /// **戻るもの**（同じく実測）: `Int.max` / `Int.min`（`Double` に落ちて桁を失わない）・
    /// 小数部のある値・`1e300`・真偽・null・日本語・絵文字・入れ子の構造。
    /// つまり失われるのは**JSON では表せない区別**だけである。
    ///
    /// ## 保証できるのは同一性ではなく**冪等性**である
    ///
    /// 一度この境界を通った値は、何度往復しても同じ値・同じ文字列になる
    /// （`.sortedKeys` で並びも固定）。書き戻しと `Equatable` な比較・ログの突き合わせが
    /// 要求しているのはこちらの性質であり、`ToolRoundTripTests` が固定しているのも
    /// **一度通した値どうしの一致**である。
    ///
    /// ## 直さずに書き換えた理由（判断。**過大に言わない**）
    ///
    /// 1. **JSON に `80` と `80.0` の区別は無い。** 直すには整数値の `Double` を
    ///    `80.0` と書く**自前の符号化器**が要る（`JSONEncoder` は `80` と書く）。
    ///    文字列の逃がし方まで自分で書くことになり、**ライブラリと同じ判断が2か所**になる。
    /// 2. **上流で既に同じ正規化が起きている。** モデルの原文を `[String: JSONValue]` に
    ///    するのは MLX 側の parser であり、`{"limit": 80.0}` が `.int(80)` になることを
    ///    検証役が実測している。**この関数の入口に `.double(80.0)` が来ること自体がまれ**で、
    ///    仮に直しても、消えた区別は既にこの層の手前で消えている。
    /// 3. **下流は札を見ていない。** `argumentsJSON` を読むのは `ToolArguments` で、
    ///    あれは JSON の**文**を読み、`integer(_:)` が `10` も `10.0` も受ける
    ///    （`Tools/ToolCallRequest.swift`）。ここで戻した `ToolCall` の使い道は
    ///    会話への書き戻し（`chatMessages(for:)`）だけである。
    ///
    /// > **【未確認】小数を取るツールはまだ1つも無い**（`ToolDefinition.Parameter.ValueType`
    /// > には `.number` がある）。足す日に見るのは**この関数ではなく `ToolArguments` の側**である
    /// > ── 値が通る道はそちらで、`1.0` と `1` の区別が本当に要るなら、
    /// > 区別が消えているのは MLX の parser の入口のほうである。
    ///
    /// 読めなかったときは**空の引数として戻す。** 呼び出しごと消すと、
    /// モデルには「無視された」としか見えず、同じ手を繰り返す（16.8節）。
    nonisolated static func toolCall(from call: ModelToolCall) -> ToolCall {
        let arguments =
            (try? JSONDecoder().decode([String: JSONValue].self, from: call.argumentsData)) ?? [:]
        return ToolCall(
            function: .init(name: call.name, arguments: arguments), id: call.callID)
    }

    /// 往復の記録を、テンプレートへ渡す `[Chat.Message]` に組み直す。
    ///
    /// ## なぜ毎周組み直すのか
    ///
    /// `Chat.Message` は `Sendable` ではなく、`ModelContainer.prepare(input:)` は
    /// `consuming sending UserInput` で受け取る。**持ち回ると領域解析に引っかかる。**
    /// `RoundTripMessage`（Sendable）から作り直せば、出来た配列は独立した領域に入る。
    ///
    /// ## テンプレートのどの枝へ行くか（**ここが往復の要である**）
    ///
    /// | 記録 | 出来る辞書 | Qwen3 テンプレートの枝 |
    /// |---|---|---|
    /// | `.assistant(text, toolCalls: [])` | `role=assistant` | 通常の assistant |
    /// | `.assistant(text, toolCalls: [c])` | `role=assistant` ＋ **`tool_calls`** | `{%- if message.tool_calls %}` → `<tool_call>` を描く |
    /// | `.toolResult` | **`role=tool`** ＋ `tool_call_id` / `name` | `{%- elif message.role == "tool" %}` → `<tool_response>` |
    ///
    /// 辞書へ落とすのは `MessageGenerator.addToolMetadata(to:for:)`（MLX 側の既定実装）で、
    /// `Chat.Message.Tool` の中身を `tool_calls` / `tool_call_id` へ振り分けている。
    /// **`Chat.Message.assistant(_:toolCalls:)` を使わずに content へ `<tool_call>` を
    /// 自分で書かないこと** ── 綴りが1文字違えば、モデルには別物として見える。
    ///
    /// **`static` にしてあるのはテストのため。** モデルもトークナイザも要らないので、
    /// `ToolRoundTripTests` が 4.6GB を読まずに「どの枝へ行くか」を確かめられる。
    nonisolated static func chatMessages(for transcript: [RoundTripMessage]) -> [Chat.Message] {
        transcript.map { message in
            switch message {
            case .system(let text):
                return Chat.Message.system(text)
            case .user(let text):
                return Chat.Message.user(text)
            case .assistant(let text, let toolCalls):
                // 空配列を `[]` のまま渡すと `tool_calls: []` が辞書に載る。
                // **載せない** ── テンプレートは `{%- if message.tool_calls %}` で見るので
                // 空配列でも偽になるが、依存先の真偽値の扱いに頼らない（FR-21 と同じ規律）。
                return Chat.Message.assistant(text, toolCalls: toolCalls.isEmpty ? nil : toolCalls)
            case .toolResult(let text, let id, let name):
                return Chat.Message.tool(text, id: id, name: name)
            case .demotableToolResult(let text, _, let id, let name):
                // **生の姿で描く。** どちらの姿にするかは
                // `compacted(_:budget:counter:)` が周ごとに決めており、
                // `performChat` はその戻り値（`.toolResult` に潰れている）を渡してくる。
                // ここへ落ちてくるのは「縮約を通さずに描いた」場合だけなので、
                // **落としていない側**＝そのまま送る側を選ぶ。
                return Chat.Message.tool(text, id: id, name: name)
            }
        }
    }

    /// ツール1回の結果を、往復の記録へ入れる形にする。
    ///
    /// **決めているのは1つだけ ── 落とせる側に入れるかどうかである**（16.3節 第2段）。
    ///
    /// | | 入る先 | なぜ |
    /// |---|---|---|
    /// | 中身のある結果 | `.demotableToolResult` | 往復が進めば栞1行に落ちる |
    /// | **失敗の文** | `.toolResult`（落とせない） | 1行しかなく、**忘れると同じ誤りを繰り返す**（16.8節） |
    ///
    /// **文字列は組み直さない。** `responseText` と `summaryLine` は実行役が
    /// 同じ値から作って渡してきたものである（`ToolResult.executionOutcome`）──
    /// ここで1文字でも足したら、測った値と入れる値が別物になる。
    ///
    /// **`static` にしてあるのはテストのため**（この判断だけを外から確かめられるように）。
    nonisolated static func transcriptEntry(for outcome: ToolExecutionOutcome) -> RoundTripMessage {
        guard !outcome.isFailure else {
            return .toolResult(
                text: outcome.responseText, id: outcome.callID, name: outcome.toolName)
        }
        return .demotableToolResult(
            text: outcome.responseText, bookmark: outcome.summaryLine,
            id: outcome.callID, name: outcome.toolName)
    }

    /// **第2段の縮約を、往復の1周ぶんに当てる**（FR-19 / DESIGN.md 第16.3節）。
    ///
    /// ---
    ///
    /// # なぜ往復のループの中で要るのか
    ///
    /// | | |
    /// |---|--:|
    /// | 1回の読み取りの上限（`InputBudget.singleRead`） | 360 |
    /// | 1ターンの往復の上限（`FolderToolRunner.callLimit`） | × 6 |
    /// | **1ターンの中で積み上がりうる量** | **2,160** |
    /// | 入力予算（`InputBudget.total`） | **1,000** |
    ///
    /// しかも**周ごとに会話全体をプリフィルし直している**（KVキャッシュの再利用なし。
    /// このファイルの `rounds:` ループの但し書き）。**積み上がった生の戻り値を、
    /// 周回のたびに払い直している**ということである（実測でプリフィル21秒）。
    ///
    /// 落とせば、次の周に払うのは栞1行になる。
    ///
    /// # 何を落とし、何を落とさないか（判断は `ContextTranscript` に置いてある）
    ///
    /// | | |
    /// |---|---|
    /// | 落とす | `.demotableToolResult` の**古いものから**、収まるまで |
    /// | 落とさない | 利用者・system・assistant の発言、失敗の文（`.toolResult`）、**この周の読み取り** |
    /// | 落とさない | **落として高くつくもの**（空のファイルの読み取りなど。`RoundTripItem.demotable`） |
    ///
    /// **この周の読み取りを残すのは、それが「いま答えさせようとしている材料」だから**である
    /// （`ContextTranscript.fitRoundTrip` の但し書き）。
    /// **「一番新しい1件」ではない** ── `performChat` は1周の呼び出しを全部並べるので、
    /// 1件しか守らないと、同じ周で頼まれた残りが**モデルに一度も見られないまま**栞になる。
    /// 周の境目は `.assistant(_, toolCalls:)` が空でないことで決まり、
    /// それを `RoundTripItem.startsRound` に写しているのが下の `map` である。
    ///
    /// # 数え方は概算である（**過少に出る**）
    ///
    /// `counter` の既定は `TokenCounter.estimate` で、発見19 の実測では
    /// **概算は実測に対して 1.47倍 甘い。** さらにここは
    /// チャットテンプレートの固定分も `tool_calls` の JSON も数えていない。
    /// **したがって「収まった」は【未確認】であり、過少の側へ倒れている。**
    /// 実トークナイザは1行下（`container.prepare` の `lmInput.text.tokens.count`）で
    /// 手に入るので、差し替えるならそこを `TokenCounter.exact` に包むこと（第15章の宿題）。
    ///
    /// # 落とし切っても収まらない周がある（③・**未解決**）
    ///
    /// 実ファイルを6件読んだターンは、落とせるものを落とし切っても収まらない ──
    /// **概算 597 / 予算 573**（`TranscriptCompactionTests` の本命がその状況である）。
    /// 上の 1.47倍を掛ければ実測相当は 714 で、テンプレートの固定分と
    /// `tool_calls` の JSON は**そこにまだ入っていない。**
    ///
    /// **ここでは何もしない。** `fits == false` を事実として返し、`[TOOL] compacted` に出す。
    /// 握り潰さず、エラーにもしない ──
    /// 「入力を短くしてください」は利用者に実行不可能な助言であり（発見19 ③）、
    /// この周ぶんまで落とすのは②で直したばかりの欠陥に戻ることだからである。
    /// **収める手は2つとも外にある**（次の読み取りの窓を狭める／配分表を見直す）。
    ///
    /// **`static` にしてあるのはテストのため**である（`chatMessages(for:)` と同じ理由）。
    /// モデルもトークナイザも要らないので、`TranscriptCompactionTests` が
    /// 4.6GB を読まずに「何が落ちて何が残るか」を固定できる。
    ///
    /// - Parameter perMessageOverhead: 1発言あたりのチャットテンプレートの固定分。
    ///   **既定 0 は「まだ測っていない」という意味である。**
    ///   `<|im_start|>…<|im_end|>` のぶんが実際には毎回かかる。
    ///   **`performChat` はまだ渡していない**（実トークナイザを挿すまで測れない。第15章の宿題）──
    ///   口だけが先に開いている状態であることを承知しておくこと。
    nonisolated static func compacted(
        _ transcript: [RoundTripMessage],
        budget: Int,
        counter: TokenCounter = .estimate,
        perMessageOverhead: Int = 0
    ) -> (messages: [RoundTripMessage], fit: ContextTranscript.RoundTripFit) {

        let items = transcript.map { message -> ContextTranscript.RoundTripItem in
            switch message {
            case .system(let text), .user(let text):
                return .fixed(text)
            case .assistant(let text, let toolCalls):
                // **`tool_calls` の JSON は数えていない。** 数えるなら
                // テンプレートが描く綴りそのものを組む必要があり、それは実測の側の仕事である。
                //
                // **ただし「呼んだかどうか」は運ぶ。** ツールを呼んだ発言が周の頭であり、
                // その後ろに並ぶ戻り値が**この周の材料**＝モデルがまだ見ていないものである（②）。
                return .fixed(text, startsRound: !toolCalls.isEmpty)
            case .toolResult(let text, _, _):
                return .fixed(text)
            case .demotableToolResult(let text, let bookmark, _, _):
                // **数え方を渡すこと**（①）。落として得になるかを、
                // 予算を測るのと**同じ数え方**で見る。既定に任せると、
                // 実トークナイザを挿した日に「得の判定だけ概算のまま」が残る。
                return .demotable(raw: text, bookmark: bookmark, counter: counter)
            }
        }

        let fit = ContextTranscript.fitRoundTrip(
            items, budget: budget, counter: counter, perMessageOverhead: perMessageOverhead)

        // **送るのは、いま測った当の文字列である**（`fit.texts`）。
        // ここで栞を組み直すと、測った値と送る値が別物になる
        // （`ReadOutcome.contextText` が名指しで禁じている食い違い）。
        var messages = transcript
        for (index, text) in fit.texts.enumerated() where index < messages.count {
            guard case .demotableToolResult(_, _, let id, let name) = messages[index] else {
                continue
            }
            // **`role=tool` のまま、id と name も持ったまま**送る。
            // 落ちたのは中身だけで、`<tool_call>` との対応づけは切れていない。
            messages[index] = .toolResult(text: text, id: id, name: name)
        }
        return (messages, fit)
    }

    /// 生成ストリームの1項目の行き先を決める。**思考分離（FR-17）との交点である。**
    ///
    /// | 来たもの | 行き先 | なぜ |
    /// |---|---|---|
    /// | `.chunk` | 思考分離器 | 本文と思考はここでしか分けられない |
    /// | `.toolCall` | **分離器を通さず素通し** | `<tool_call>` は `.chunk` に混ざらない（16.1節） |
    /// | `.toolCall`（ツール未送信） | **流さない。ログのみ** | 実行できるものが無い。16.6節の約束3 |
    /// | `.rejectedToolCall` | ログのみ | 原文は出さない（NFR-01） |
    /// | `.info` | 呼び出し側が `item.info` から取る | `GenerateCompletionInfo` は Equatable でないので運ばない |
    ///
    /// **`static` にしてあるのはテストのため。** actor の状態にも MLX のモデルにも
    /// 触らないので、`EngineToolWiringTests` が 4.6GB を読み込まずに固定できる。
    nonisolated static func route(_ item: Generation, toolsWereSent: Bool) -> GenerationRoute {
        switch item {
        case .chunk(let text):
            return .separatorText(text)

        case .info:
            return .completion

        case .toolCall(let call):
            // **渡していないのに呼ばれたら流さない。** 実行できるツールが1つも無いのだから、
            // ここで通しても消費側は何もできない。16.6節の約束3（注入の状態を
            // モデルの出力で変えない）の、最後の関門でもある。
            guard toolsWereSent else {
                return .unexpectedToolCall(name: call.function.name)
            }
            return .passThrough(.toolCall(modelToolCall(from: call)))

        case .rejectedToolCall(let rejection):
            return .rejected(reason: rejection.reason.rawValue, toolName: rejection.toolName)

        @unknown default:
            // `Generation` は別モジュールの enum である。増えても止まらないこと。
            return .ignored
        }
    }

    // MARK: - 思考分離器の組み立て

    /// モデルの宣言から分離器を作る。
    ///
    /// `primedInside` を**推測しない**のがここの要点。
    /// 描画済みプロンプトの末尾を実際に見て、思考ブロックが開いた状態で
    /// プロンプトが終わっているかを判定する。
    ///
    /// | モデル | プロンプトが `<think>` で終わるか | `primedInside` |
    /// |---|---|---|
    /// | Qwen3（思考ON） | **終わらない**（モデルが自分でストリームに出す） | false |
    /// | Qwen3（思考OFF） | 閉じた空ブロックが入る | false |
    /// | DeepSeek-R1 系 | 終わる | true |
    ///
    /// Qwen3 で `true` にすると全崩壊する。だから直書きしない。
    private func makeSeparator(
        container: ModelContainer,
        promptTokens: [Int]
    ) async -> any ThinkingSeparating {
        guard let reasoning else {
            // 思考プロトコルを宣言していないモデル。素通しでよいが、
            // 未知のモデルが `<think>` を出す場合に備えて自作分離器を噛ませる。
            return ThinkingSplitter()
        }

        // 末尾だけを復号する。全文を復号する必要はない（長いと無駄）。
        // `decode(tokenIds:)` は既定で特殊トークンを残すので `<think>` が消えない。
        let tail = promptTokens.suffix(64)
        let renderedTail = await container.decode(tokenIds: Array(tail))
        let primedInside = ReasoningEventEmitter.promptEndsInsideReasoning(
            renderedPromptTail: renderedTail, config: reasoning)

        return ReasoningEmitterSeparator(config: reasoning, primedInside: primedInside)
    }

    // MARK: - 解剖のための拡張点（VISION）

    /// 生成の振る舞いに差し込むもの。**A1 では空。**
    ///
    /// ここが VISION 第3因子（全部を起動しない）への正規の入口である。
    /// 生成ループを塞がずに後から差し込めるよう、呼び出し経路だけ先に通してある
    /// （`ModelContainer.generate` ではなく `perform` + 自由関数 `generate` を
    /// 使っているのは、この `components:` を渡せるのがそちらだけだから）。
    ///
    /// ## ここに足せるもの
    ///
    /// | 足すもの | 効果 | 参照 |
    /// |---|---|---|
    /// | `ThinkingBudgetProcessor` | 思考トークンの上限制御。**「予算の9割」問題への直接の道具** | 下記 |
    /// | 確信度による打ち切り | 早期終了のうち、層に触らずできる部分 | `LogitProcessor` |
    /// | ロジット分布の記録 | 「どこで迷ったか」の測定 | `LogitProcessor.process(logits:)` |
    ///
    /// 思考予算を入れる場合の形（コンパイル確認済みの呼び出し形。A1 では使わない）:
    ///
    /// ```swift
    /// components = try components.applyingThinkingBudget(
    ///     ThinkingBudgetConfiguration(maximumTokenCount: 512, minimumAnswerTokenCount: 128),
    ///     reasoning: reasoning,
    ///     tokenizer: tokenizer)
    /// ```
    ///
    /// ## ここでは足りないもの（層ごとの計測・早期終了）
    ///
    /// `LogitProcessor` はサンプリング層のフックなので、**層のループには届かない。**
    /// 層に手を入れるには `MLXLLM/Models/Qwen3.swift` をこのリポジトリへ複製して
    /// 改造し、`ModelTypeRegistry.registerModelType("qwen3", ...)` で登録し直す
    /// （`Qwen3TransformerBlock` が internal なので、外から差すのではなく
    /// ファイルごと複製する必要がある。両リポジトリとも MIT）。
    ///
    /// **その前に未解決の課題がある。** MLX は遅延評価なので、層のループに
    /// `Date()` を挟んでも実時間は測れない。各層の後に `eval()` を入れると
    /// 同期はできるが、**測定行為がパイプラインを壊して対象を変えてしまう。**
    /// 層ごとの計測方法論の確立が、早期終了に着手する前提になる
    /// （MLX_SWIFT.md 第7.3節 / 第12.4節）。
    private func makeGenerationComponents(options: ChatOptions) -> GenerationComponents {
        GenerationComponents()
    }

    // MARK: - 計測点の記録と取り出し

    /// 溜まった計測点を**取り出して空にする。**
    ///
    /// 空にするのは、読み手（`PrefillProbeTests`）が「前回以降に増えたぶん」だけを
    /// 往復ごとに出せるようにするため。取りこぼしは `seq` の飛びで検出できる。
    ///
    /// 呼ばれないまま生成を繰り返しても `memoryTraceCapacity` で頭打ちになる
    /// ── **計測のための配列がメモリを食う**のは本末転倒なので上限を置いてある。
    func drainMemoryTrace() -> [MLXMemoryReading] {
        let drained = memoryTrace
        memoryTrace.removeAll(keepingCapacity: true)
        return drained
    }

    /// 生成のあとに `MLX.Memory.clearCache()` を呼ぶかを切り替える。**計測専用。**
    ///
    /// アプリの通常経路からは呼ばないこと。呼ぶと次の生成が再確保の代金を払い、
    /// `prefill_s` が伸びる ── 退避の時定数を測っている最中にこれをやると、
    /// **測定行為が現象を作ってしまう。**
    func setClearsCacheAfterGeneration(_ enabled: Bool) {
        clearsCacheAfterGeneration = enabled
    }

    /// 溜め込みの上限。超えたら古いほうから捨てる。
    private static let memoryTraceCapacity = 256

    /// いまの `MLX.Memory.snapshot()` を1点取って積む。記録が無効なら何もしない。
    @discardableResult
    private func recordMemory(
        _ stage: MLXMemoryReading.Stage,
        prefill: (processed: Int, total: Int)? = nil,
        round: Int? = nil
    ) -> MLXMemoryReading? {
        guard Self.memoryProbeRecords else { return nil }
        return appendMemory(captureMLXMemory(stage: stage, prefill: prefill, round: round))
    }

    /// 外（MLX の計算スレッド）で取った1点を積む。通し番号はここで振る。
    ///
    /// **番号を actor 側で振るのが要点。** 取った場所がどこであれ、
    /// 積まれた順＝観測順であることが番号で保証される。
    @discardableResult
    private func appendMemory(_ reading: MLXMemoryReading) -> MLXMemoryReading {
        var stamped = reading
        stamped.sequence = memoryReadingCount
        memoryReadingCount += 1

        memoryTrace.append(stamped)
        if memoryTrace.count > Self.memoryTraceCapacity {
            memoryTrace.removeFirst(memoryTrace.count - Self.memoryTraceCapacity)
        }

        if Self.memoryProbeWritesLog {
            writeMemoryLine(stamped, since: lastMemoryReading)
        }
        lastMemoryReading = stamped
        return stamped
    }

    /// `[MEM]` 行を stderr へ1行で吐く。
    ///
    /// **`print` を使わない。** `ChatViewModel.logMeasurement` の `[STATS]` 行と
    /// 同じ経路（生の `write(2)`）に揃えてあり、`2> ログ` でそのまま拾える。
    /// キーの並びも `key=value` を空白区切り ── **値に空白を入れないこと。**
    private func writeMemoryLine(_ reading: MLXMemoryReading, since earlier: MLXMemoryReading?) {
        var fields = [
            "stage=\(reading.stage.rawValue)",
            "seq=\(reading.sequence)",
            "model=\(current?.id ?? "-")",
            reading.logFields,
        ]
        if let earlier {
            fields.append("since=\(earlier.stage.rawValue)")
            fields.append(reading.deltaFields(since: earlier))
        }
        FileHandle.standardError.write(
            Data("[MEM] \(fields.joined(separator: " "))\n".utf8))
    }

    /// 生成の終わりで必ず1回だけ通る後始末。**`performChat` の `defer` から呼ぶ。**
    ///
    /// `defer` に置いたのは、正常終了・中断・失敗の**3経路すべて**で同じ点を測るため。
    /// 経路ごとに書くと、いちばん知りたい異常時にだけ計測が抜ける。
    private func finishMemoryMeasurement() {
        recordMemory(.generateEnd)

        // ここから先は**切り替えたときだけ。** 既定では素通りする。
        guard clearsCacheAfterGeneration else { return }
        MLX.Memory.clearCache()
        recordMemory(.afterClearCache)
    }

    // MARK: - 小物

    private static func stopReason(
        from info: GenerateCompletionInfo?, cancelled: Bool
    ) -> StopReason {
        if let info {
            switch info.stopReason {
            case .stop: return .completed
            case .length: return .maxTokens
            case .cancelled: return .cancelled
            @unknown default: return .completed
            }
        }
        // `.info` が届かなかった。中断が最有力（キャンセル時はストリームが先に終端する）。
        return cancelled ? .cancelled : .completed
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// =============================================================================
//  MLX 側のメモリ会計 ── 「MLX が何をどれだけ確保しているか」だけを測る
// -----------------------------------------------------------------------------
//  ## なぜ `ProcessMetrics`（RSS / footprint）ではなく `MLX.Memory` なのか
//
//  **問いが違うからである。** いま追っているのは次の食い違いで、
//
//  | | 値 |
//  |---|--:|
//  | モデルの重み | 4.62 GB |
//  | 生成中のフットプリント | 約 9 GB |
//  | うち `IOAccelerator (graphics)` ＝ Metal のバッファ | 8,952 MB |
//
//  **余分な約4.4GB が何なのか分かっていない。**
//  この問いは2つに割れる ── 「MLX が確保しているのか」と「物理RAMに載っているのか」。
//
//  | 知りたいこと | 読むべき指標 | このファイルの担当 |
//  |---|---|---|
//  | **何をどれだけ確保したか** | `MLX.Memory.snapshot()` | **これ** |
//  | 確保したものが物理RAMにあるか | `ProcessMetrics`（RSS / footprint） | 別ファイル |
//
//  これまで使ってきた3つの指標は、**3つとも前者の問いに答えていなかった。**
//
//  | 指標 | 何を外したか |
//  |---|---|
//  | `MLX.Memory.peakMemory` 単独 | プログラム開始以来の**アクティブの最大値**しか無く、内訳（active／cache）が無い |
//  | `RSS` | **`IOAccelerator` を数えない。** Metal のバッファが丸ごと視界の外 |
//  | `TASK_EVENTS_INFO.pageins` | compressor からの伸長と GPU フォルトを数えない |
//
//  ## なぜこれを residency の証拠に使ってはいけないのか ── **ここを取り違えると同じ誤診に戻る**
//
//  `MLX.Memory` が数えているのは**アロケータの帳簿**である。
//  **そのページが物理RAMにあるかスワップにあるかを一切知らない。**
//  4.62GB の重みが全部スワップへ落ちていても、`activeMemory` は1バイトも動かない。
//
//  この取り違えは既に一度、実際に誤診を生んでいる
//  （BENCH_RESULTS.md 2026-08-16 の「ピークメモリが+40MBしか動いていないので
//  メモリ不足では説明がつかない」は**後に撤回された**）。
//  **`ProcessMetrics` の解説と対で読むこと** ── あちらの冒頭には
//  「`MLX.Memory.snapshot()` へ置き換えないこと」と書いてある。逆もまた真である。
//
//  > **併読するものであって、代替ではない。**
//  > - `MLX.Memory` が小さいのに footprint が大きい → **MLX 以外**が確保している
//  >   （Metal のドライバ側、コンパイル済みシェーダ、Foundation Models など）
//  > - `MLX.Memory` も footprint も大きいのに RSS が小さい → 退避が進んでいる
//  > - `MLX.Memory` が大きい → MLX が確保している。**内訳を `active` と `cache` で割る**
//
//  ## `activeMemory` と `cacheMemory` の割り方が、今回の分岐そのもの
//
//  MLX の解説（`Memory.swift` 冒頭）はこう言っている ──
//  `activeMemory` ＋ `cacheMemory` ＝ MLX が確保した総量。
//  `activeMemory` は生きている `MLXArray` が握っている分、
//  `cacheMemory` は**解放済みだが OS へ返さずプールしてある分**である。
//
//  `SophiaDefaults.mlxCacheLimitBytes` は 20MB に設定してあるので、
//  **理屈の上では `cacheMemory` は20MBを大きく超えないはず**である。
//  だから切り分けはこうなる。
//
//  | 観測 | 読み |
//  |---|---|
//  | `cache_mb` が20MB程度 かつ `active_mb` が約4.6GB | MLX は重みしか持っていない。**余分な4.4GBは MLX の外** |
//  | `cache_mb` が数GB | `cacheLimit` が効いていない。**前提のほうが間違っている** |
//  | `after_clear_cache` で大きく減る | 同上。減った分はキャッシュだった |
//  | `after_clear_cache` で減らない | live なアロケーション。重みか KV キャッシュ |
//
//  **最後の2行のために `clearCache()` の切り替えを用意してある**
//  （`MLXEngine.setClearsCacheAfterGeneration(_:)` ／ `SOPHIA_MEM_CLEAR_CACHE=1`）。
// =============================================================================

/// `MLX.Memory.snapshot()` を1点取ったもの。**MLX の帳簿だけを映す**（residency は映さない）。
///
/// 何のためにあるかは直上の解説を読むこと。**この型を residency の証拠に使わないこと。**
struct MLXMemoryReading: Sendable, Equatable {

    /// どの時点の1点か。**stage の意味を勝手に変えないこと** ── 過去のログが読めなくなる。
    enum Stage: String, Sendable {
        /// ロードに入る直前（早期経路を抜けたあと）。ロードの基準。
        case loadBegin = "load_begin"
        /// 重みが載った直後。**ロードで何が載ったか。**
        case loadEnd = "load_end"
        /// 生成に入る直前。`peakMemory` をリセットした**あと**。生成の基準。
        case generateBegin = "generate_begin"
        /// プリフィルの最後の進捗が届いた時点。**本丸。ただし下限側**（`prefill_processed` を必ず見ること）。
        case prefillEnd = "prefill_end"
        /// 最初の断片が復号されて届いた時点。**上限側**（デコード1ステップを含む）。
        case firstToken = "first_token"
        /// 生成が終わった直後（正常・中断・失敗のいずれでも通る）。
        case generateEnd = "generate_end"
        /// `MLX.Memory.clearCache()` の直後。**切り替えたときだけ出る。**
        case afterClearCache = "after_clear_cache"
        /// `unload()` の直後。全部手放した状態の基準。
        case unloadEnd = "unload_end"
    }

    var stage: Stage
    /// 観測順の通し番号。**飛んでいたら取りこぼした区間がある。**
    var sequence: Int = 0
    /// 生きている `MLXArray` が握っているバイト数（`Memory.activeMemory`）。
    var activeMemory: Int
    /// 解放済みだがプールに残っているバイト数（`Memory.cacheMemory`）。
    var cacheMemory: Int
    /// プログラム開始（または直近のリセット）以来のアクティブの最大値（`Memory.peakMemory`）。
    var peakMemory: Int
    /// `prefillEnd` のときだけ入る。**どこまで進んだ時点の値なのか。**
    var prefillProcessed: Int? = nil
    /// 同上、**その周で実際に払うトークンの総数。**
    /// `prefillProcessed == prefillTotal` でなければ途中の値である。
    ///
    /// **描画したプロンプト全体とは限らない。** 再利用が効いた周は継ぎ足すぶんだけになる
    /// ── 描画量と実払い量を並べたいときは `[PREFILL]` 行の `prompt=` / `fed=` を見ること。
    var prefillTotal: Int? = nil
    /// **何周目の点か**（ツール往復の周番号。1 始まり）。
    ///
    /// これが無いと `prefill_end` が2行並んだとき、
    /// **どちらがどの周なのかログから復元できない**（2026-08-18 の実測で実際に困った。
    /// `seq=3` と `seq=5` の間隔から推測するしかなかった）。
    /// 往復しない会話では常に 1 で、周番号の意味は変わらない。
    var round: Int? = nil

    /// MLX が確保している総量。**MLX の解説どおり active + cache。**
    /// 4.62GB という重みのサイズと直接並べられるのはこの値である。
    var totalMemory: Int { activeMemory + cacheMemory }

    /// 絶対値の `key=value` 列。
    ///
    /// `peak_mb` は `[STATS]` / `[PROBE]` 行の同名キーと**同じ意味**（MLX の `peakMemory`）に
    /// 揃えてある。キー名の意味を行ごとに変えないための約束である。
    /// 単位を MiB にしてあるのも同じ理由（BENCH_RESULTS.md の表がすべて MB 表記）。
    var logFields: String {
        var fields = [
            "active_mb=\(Self.megabytes(activeMemory))",
            "cache_mb=\(Self.megabytes(cacheMemory))",
            "total_mb=\(Self.megabytes(totalMemory))",
            "peak_mb=\(Self.megabytes(peakMemory))",
        ]
        // **周番号は分かっているときだけ。** ロードや unload の点には周が無い。
        if let round { fields.append("round=\(round)") }
        // プリフィル以外の段階では出さない。**無意味なキーを毎行並べない。**
        if let prefillProcessed, let prefillTotal {
            fields.append("prefill_processed=\(prefillProcessed)")
            fields.append("prefill_total=\(prefillTotal)")
        }
        return fields.joined(separator: " ")
    }

    /// 差分の `key=value` 列。**符号を必ず付ける**（`ProcessMetricsDelta.logFields` と同じ約束）。
    /// 絶対値のキーとは重ならないので、同じ行に並べても曖昧にならない。
    func deltaFields(since earlier: MLXMemoryReading) -> String {
        func signed(_ now: Int, _ before: Int) -> String {
            String(format: "%+.1f", Double(now - before) / 1_048_576)
        }
        return [
            "d_active_mb=\(signed(activeMemory, earlier.activeMemory))",
            "d_cache_mb=\(signed(cacheMemory, earlier.cacheMemory))",
            "d_total_mb=\(signed(totalMemory, earlier.totalMemory))",
            "d_peak_mb=\(signed(peakMemory, earlier.peakMemory))",
        ].joined(separator: " ")
    }

    /// MiB 表記。`ProcessMetrics` の `megabytes` と同じ 1_048_576 で割る。
    /// **桁を揃えないと突き合わせのたびに換算ミスが出る。**
    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

/// いまの `MLX.Memory.snapshot()` を1点取る。
///
/// `activeMemory` / `cacheMemory` / `peakMemory` を個別に3回読まず `snapshot()` を使うのは、
/// **3つが同じ瞬間の値であることを保証するため。**
/// プリフィル中に個別に読むと、読んでいる間に確保が進んで内訳が食い違う。
private func captureMLXMemory(
    stage: MLXMemoryReading.Stage,
    prefill: (processed: Int, total: Int)? = nil,
    round: Int? = nil
) -> MLXMemoryReading {
    let snapshot = MLX.Memory.snapshot()
    return MLXMemoryReading(
        stage: stage,
        activeMemory: snapshot.activeMemory,
        cacheMemory: snapshot.cacheMemory,
        peakMemory: snapshot.peakMemory,
        prefillProcessed: prefill?.processed,
        prefillTotal: prefill?.total,
        round: round)
}

/// プリフィルの進捗コールバックから届いた**最後の1点**だけを持つ箱。
///
/// ## なぜ箱が要るのか（actor に直接書けない）
///
/// `GenerateParameters.prefill.progress` は `@Sendable (Int, Int) -> Void` で、
/// **MLX の計算スレッドから同期的に呼ばれる。** `MLXEngine` は actor なので、
/// そこから隔離された状態へは触れない（触ろうとすると Swift 6 の strict concurrency が弾く）。
/// `await` で入るわけにもいかない ── コールバックは同期であり、
/// **待たせた時間がそのままプリフィルの実測時間に乗ってしまう。**
///
/// そこで「取るのは外・積むのは actor」に割った。
/// 通し番号は積む側（`MLXEngine.appendMemory`）が振るので、観測順は保たれる。
///
/// ## なぜ最後の1点だけなのか
///
/// プリフィルは512トークン単位で刻まれ、その回数だけコールバックが鳴る。
/// 全部持つと長いプロンプトで配列が伸びるだけで、**知りたいのは「終わった時点」**である。
/// 途中経過は既存の `.prefill` チャンク（UI の進捗表示）が担当している。
///
/// ## `@unchecked Sendable` にしている理由
///
/// 中身は `NSLock` で完全に囲ってあるが、コンパイラにはそれが見えない。
/// `Mutex`（Synchronization）を使えば `@unchecked` を外せるが、**あちらは macOS 15 以上**で、
/// このアプリの下限は macOS 14 である（`MACOSX_DEPLOYMENT_TARGET = 14.0`）。
private final class PrefillMemoryProbe: @unchecked Sendable {

    private let enabled: Bool
    private let lock = NSLock()
    private var latest: MLXMemoryReading?
    /// いま何周目か。**周の頭で actor 側が入れる。**
    ///
    /// 進捗コールバックは MLX の計算スレッドから鳴るので、そちらからは周が分からない。
    /// 「入れるのは actor・読むのは外」で、`latest` とまったく同じ鍵の下に置く。
    private var round: Int?

    init(enabled: Bool) {
        self.enabled = enabled
    }

    /// 周の頭で actor 側から呼ぶ。**無効でも入れる**（安いし、入れ忘れの分岐を作らない）。
    func beginRound(_ round: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.round = round
    }

    /// 進捗コールバックから呼ぶ。**無効なら `snapshot()` すら呼ばない。**
    /// 既定で無効なのはログを出さないためだけでなく、
    /// 計測用の処理がプリフィルの実測時間に混ざらないようにするためでもある。
    func record(processed: Int, total: Int) {
        guard enabled else { return }
        // **`snapshot()` を鍵の外で取る。** 鍵の中で取ると、待たされた時間が
        // そのままプリフィルの実測時間に乗る（この箱を作った理由そのもの）。
        // 周番号だけは鍵の中で読み直して差し替える。
        var reading = captureMLXMemory(
            stage: .prefillEnd, prefill: (processed: processed, total: total))
        lock.lock()
        defer { lock.unlock() }
        reading.round = round
        latest = reading
    }

    /// actor 側から取り出す。取り出したら空にする（1回の生成で1点しか積まない）。
    func take() -> MLXMemoryReading? {
        lock.lock()
        defer { lock.unlock() }
        let value = latest
        latest = nil
        return value
    }
}

// =============================================================================
//  取得の無進捗を見張る箱 ── 「例外が来るか」ではなく「バイトが増えたか」を見る
// -----------------------------------------------------------------------------
//  ## なぜ箱が要るのか（actor に直接書けない）
//
//  進捗コールバックは `@Sendable` で、**swift-huggingface 側のスレッドから
//  100ms 間隔で呼ばれる**（`HubClient+Files.swift` の
//  `makeSnapshotProgressSamplingTask`）。`MLXEngine` は actor なので、
//  そこから隔離された状態へは触れない ── `PrefillMemoryProbe` とまったく同じ事情である。
//
//  `Mutex`（Synchronization）を使えば `@unchecked` を外せるが、
//  **あちらは macOS 15 以上**で、このアプリの下限は macOS 14
//  （`MACOSX_DEPLOYMENT_TARGET = 14.0`）。だから `NSLock` を使う。
//
//  ## なぜ `SuspendingClock` なのか ── **`Date` / `ContinuousClock` にしないこと**
//
//  **スリープしていた時間を数えないため。**
//  4.62GB の取得は数分かかる。その途中でノートの蓋が閉じられるのは普通に起こる。
//  `Date` や `ContinuousClock` はスリープ中も進むので、復帰した瞬間に
//  「8時間 無進捗」と判定してしまう ── **実際には正常に再開している取得を殺す。**
//  `SuspendingClock` はスリープ中に止まるので、数えるのは**起きていた時間だけ**になる。
//
//  ## 判定に使うのは「増えたか」だけ ── 速度を見ない
//
//  速度で判定すると閾値が回線に依存し、遅い回線を必ず殺す。
//  ここは **1バイトでも増えたら時計を0に戻す**方式にしてある。
//  20MB/s の1/1000（20KB/s）まで落ちた回線でも60秒で1.2MB増えるので誤検知しない。
//  逆に「まったく増えない」は速度の問題ではなく、**接続が存在しない**ことを意味する。
// =============================================================================

/// 取得の進みを「最後にバイトが増えた時刻」へ要約して持つ箱。**判定もここで行う。**
///
/// `MLXEngine` の外に出してあるのは、**ダウンロードを1バイトも走らせずに
/// 判定ロジックを試験できるようにするため**である（`ModelDownloadStallTests`）。
/// 4.62GB を落とさないと確かめられない見張りは、結局誰も確かめない。
final class ModelDownloadStallWatch: @unchecked Sendable {

    /// 見張りが出す所見1件。**ここに入っていない情報は画面にも出せない。**
    struct Report: Sendable, Equatable {
        /// これまでに落ちたバイト数。**0 なら1バイトも来ていない。**
        var completedBytes: Int64
        /// 総量。**0 なら不明**（＝ファイル一覧すら取れていない ＝ もっと手前で詰まっている）。
        var totalBytes: Int64
        /// 進捗コールバックが鳴った回数。**0 なら取得が始まってすらいない。**
        var callbackCount: Int
        /// 最後に増えてから何秒 無風だったか。**スリープ中は数えない。**
        var idleSeconds: Double

        /// 1バイトでも届いたか。**文言を「始まらない」と「途中で止まった」に割る唯一の材料。**
        var sawAnyBytes: Bool { completedBytes > 0 }

        /// 0.0〜1.0。総量が不明なら nil（UI は不定形インジケータにする）。
        var fraction: Double? {
            guard totalBytes > 0 else { return nil }
            return min(1.0, Double(completedBytes) / Double(totalBytes))
        }

        /// 「0.00 GB / 4.62 GB」。**利用者が異常だと判断するための数字。**
        var progressText: String {
            formatDownloadedBytes(completed: completedBytes, total: totalBytes)
        }

        /// 打ち切る前に画面へ出す1行。**待つべきか判断できる形にする。**
        var waitingDetail: String {
            let seconds = Int(idleSeconds.rounded())
            if sawAnyBytes {
                return "モデルを取得しています（\(progressText)）"
                    + "— \(seconds)秒間 変化がありません"
            }
            return "モデルの取得を待っています（\(progressText)）"
                + "— \(seconds)秒間 まだ1バイトも届いていません"
        }
    }

    /// 見張りの判断。**「進んでいる／黙っていられない／打ち切る」の3値。**
    enum Verdict: Sendable, Equatable {
        /// 進んでいる、または取得が終わっている。何もしない。
        case healthy(Report)
        /// 閾値の半分を超えた。**打ち切らないが、画面には出す。**
        case idle(Report)
        /// 閾値を超えた。打ち切る。
        case stalled(Report)
    }

    private let lock = NSLock()
    private var completedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var callbackCount = 0

    /// 最後に **`completedBytes` が増えた**時刻。まだ増えていなければ取得の開始時刻。
    private var lastAdvanceAt: SuspendingClock.Instant

    /// 取得しきったか。**ここが `true` になったら見張りは黙る。**
    ///
    /// **これが正常系を守っている一点である。** 取得のあとには重みの展開が続き、
    /// その間バイトは1つも増えない（16GB機では数十秒〜。スワップを噛めばもっと）。
    /// 黙らせないと、**正常に読み込んでいる最中に「進んでいません」と誤検知する。**
    private var finished = false

    init(startedAt: SuspendingClock.Instant) {
        lastAdvanceAt = startedAt
    }

    /// 進捗コールバックから呼ぶ。**増えたときだけ時計を戻す。**
    ///
    /// 100ms ごとに呼ばれる想定なので、ここは意図的に軽くしてある
    /// （ログも判定も行わない。取得そのものを遅くしないため）。
    func note(completedBytes: Int64, totalBytes: Int64, at now: SuspendingClock.Instant) {
        lock.lock()
        defer { lock.unlock() }

        callbackCount += 1
        if totalBytes > 0 { self.totalBytes = totalBytes }

        // **増えたときだけ。** 同じ値で何度呼ばれても時計は戻さない
        // ── 「コールバックが鳴っている」ことと「取得が進んでいる」ことは別である。
        // 今回の事故では前者だけが成立している可能性もあった。
        if completedBytes > self.completedBytes {
            self.completedBytes = completedBytes
            lastAdvanceAt = now
        }

        // 取得しきった。以降は重みの展開なので見張りを止める（`finished` の説明を参照）。
        if totalBytes > 0, completedBytes >= totalBytes { finished = true }
    }

    /// いま止まっているかを判定する。**時刻を引数で受けるのは試験のため**
    /// （実時間を待たずに「90秒後」を作れる）。
    ///
    /// - Parameters:
    ///   - firstByteGrace: **まだ1バイトも来ていない**ときに使う猶予。長いほう。
    ///   - stallTimeout: 一度でもバイトが来たあとに使う閾値。短いほう。
    func evaluate(
        at now: SuspendingClock.Instant,
        firstByteGrace: Duration,
        stallTimeout: Duration
    ) -> Verdict {
        lock.lock()
        defer { lock.unlock() }

        let idle = lastAdvanceAt.duration(to: now)
        let report = Report(
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            callbackCount: callbackCount,
            idleSeconds: max(0, idle.milliseconds / 1000))

        // 取得は終わっている。ここから先は展開の時間なので、何秒無風でも正常。
        if finished { return .healthy(report) }

        // **1バイトも来ていない間は長いほうの猶予を使う。**
        // 最初の1バイトまでには、一覧APIも DNS も TLS も含まれる（閾値の説明を参照）。
        let limit = completedBytes > 0 ? stallTimeout : firstByteGrace

        if idle >= limit { return .stalled(report) }
        // 半分を過ぎたら画面へ出す。**打ち切りまで無言で待たせない**のが要点で、
        // これが無いと「0% のまま固まっている」という体験自体は変わらない。
        if idle >= limit / 2 { return .idle(report) }
        return .healthy(report)
    }
}

/// 「0.00 GB / 4.62 GB」の形に整える。
///
/// **`ByteCountFormatter` を使わない。** 0 バイトを「ゼロバイト」と訳してしまい、
/// **いちばん見せたい異常値がいちばん読みにくくなる**（ロケール次第で表記も動く）。
/// 単位は 10 進（1 GB = 1e9）。`MLXModelCatalog` の `sizeBytes: 4_620_000_000` を
/// 「4.62 GB」と表示するためで、`[MEM]` 行の MiB とは**別の桁**である点に注意。
func formatDownloadedBytes(completed: Int64, total: Int64) -> String {
    func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }
    func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }
    guard total > 0 else {
        // 総量が取れていない ＝ ファイル一覧すら返っていない。**その事実自体が手がかり。**
        return "受信 \(completed) バイト・総量は未取得"
    }
    if total >= 1_000_000_000 {
        return "\(gigabytes(completed)) / \(gigabytes(total))"
    }
    return "\(megabytes(completed)) / \(megabytes(total))"
}

/// **往復の最中だけ存在する会話**（FR-19 / DESIGN.md 第16章）。
///
/// ---
///
/// # これは `SophiaMessage` ではない。そして `SophiaMessage` にしないと決めた
///
/// 生の往復（`<tool_call>` と `<tool_response>`）は**エンジンの中だけに存在し、
/// 外へは1つも出ない。** ターンが終われば、この配列ごと消える。
///
/// | 足さない理由 | 中身 |
/// |---|---|
/// | 残す必要が無い | **ターンの中では**生の戻り値が落ちて `読んだ: notes.md（…）` に置き換わる（`.demotableToolResult` / 16.3節 第2段） |
/// | 代金が高い | `MessageRole` を増やすと `messages.role` の CHECK 制約（`SophiaMigrations.swift`）と `StoreSchemaTests` に波及する。**移行を1つ増やすことになる** |
/// | 得るものが無い | `Chunk` の流れは途切れないので FR-17 と既存 UI はそのまま生きる |
///
/// > **【事実の訂正 / 2026-08-19】ここには「履歴に残るのは栞1行である」と書いてあった。
/// > 書いていたが、置く者がいなかった。**
/// > `ChatViewModel.engineMessages()` は毎ターン `turns`（UI の記録）から組み直すので、
/// > **ツールの往復はターンの終わりに痕跡ごと消える** ── 栞も残らない。
/// > いま栞へ落ちるのは**このループの中だけ**である（`MLXEngine.compacted(_:budget:counter:)`）。
/// > ターンをまたいで栞を残すかどうかは未決で、実装するなら置き場は
/// > `ChatViewModel`（`ContextEntry` / `ToolResult.contextEntry` が既にその形をしている）。
///
/// # なぜ `[Chat.Message]` を直接持ち回らないのか
///
/// あちらは `Sendable` ではない。`ModelContainer.prepare(input:)` は
/// `consuming sending UserInput` で受け取るので、**送ったあとに触ると
/// 領域解析（SE-0414）が弾く。** こちらは全部 `Sendable`（`ToolCall` も `Sendable`）なので、
/// 往復のあいだ持っていられる。`Chat.Message` へは毎周
/// `MLXEngine.chatMessages(for:)` で組み直す。
enum RoundTripMessage: Sendable, Equatable {

    case system(String)

    case user(String)

    /// アシスタントの発言。**`toolCalls` が空でなければ、自分の呼び出しを次ターンへ書き戻す。**
    ///
    /// 書き戻さないと `<tool_response>` が**対応する `<tool_call>` なしで**現れ、
    /// モデルから見て「誰が何を訊いたのか分からない返事」になる（16.1節）。
    ///
    /// `content` に入るのは**本文だけ**である ── 思考は入れない
    /// （`InferenceEngine` の約束6。テンプレート側も直前ターン以外の思考は捨てる）。
    case assistant(String, toolCalls: [ToolCall])

    /// ツールの戻り値。テンプレート上は **user ターンの中**に `<tool_response>` として出る。
    ///
    /// **つまりファイルの中身は、利用者の発言と同じ場所に入る**（16.6節）。
    /// 囲いと但し書きは実行側（`ToolResult` / `ReadOutcome`）で済んでいる前提であり、
    /// ここでは1文字も足さない。
    ///
    /// 連続する tool メッセージは、テンプレートが**1つの user ターンにまとめて**描く。
    /// だから1周で複数のツールを呼ばれても、素直に並べてよい。
    case toolResult(text: String, id: String?, name: String)

    /// **落とせるツールの戻り値**（DESIGN.md 第16.3節 第2段）。
    ///
    /// `.toolResult` と役は同じで、**姿を2つ持っている**点だけが違う ──
    /// 生の中身（`text`）と、中身を落としたあとに残す栞（`bookmark`）である。
    /// どちらを送るかは周ごとに `MLXEngine.compacted(_:budget:counter:)` が決める。
    ///
    /// | どちらが入るか | 何が来たか |
    /// |---|---|
    /// | `.demotableToolResult` | 中身のある結果（`read_file` / `list_directory` / `search_files`） |
    /// | `.toolResult` | **失敗の文**（読めなかった・名前が違う・上限に達した） |
    ///
    /// **失敗の文を落とせる側に入れないこと**（`ToolResult.contextEntry` と同じ判断）。
    /// あれは1行しかなく、しかも「そのパスは無い」を忘れたモデルは
    /// 次の周で同じパスをまた書く ── 16.8節「往復を1回で打ち切らない」の材料である。
    ///
    /// **`id` と `name` は落としても持ち続ける。** 落とすのは中身だけであって、
    /// `<tool_call>` と `<tool_response>` の対応づけではない ──
    /// 切ると、モデルから見て「誰が何を訊いたのか分からない返事」に戻る（16.1節）。
    case demotableToolResult(text: String, bookmark: String, id: String?, name: String)
}

/// 生成ストリームの1項目の行き先（`MLXEngine.route(_:toolsWereSent:)` の戻り値）。
///
/// **`GenerateCompletionInfo` を運んでいないのは意図的である。** あれは `Equatable` ではなく、
/// 載せた瞬間にこの enum の等値比較が書けなくなる ＝ **テストで固定できなくなる。**
/// `.completion` を受けた側が `item.info` から取ればよい（1行で済む）。
enum GenerationRoute: Sendable, Equatable {
    /// 思考分離器（FR-17）へ通すテキスト。
    case separatorText(String)
    /// **分離器を通さずにそのまま流す断片。** いまはツール呼び出しだけ。
    case passThrough(Chunk)
    /// `.info` が来た。中身は呼び出し側が `item.info` から取る。
    case completion
    /// ツール定義を渡していないのに呼び出しが来た。**流さない**（16.6節の約束3）。
    case unexpectedToolCall(name: String)
    /// ツール呼び出しの形をしていたが、解釈も認可もできなかった。
    /// **原文は運ばない** ── 引数には利用者のファイル名や検索語が入る（NFR-01）。
    case rejected(reason: String, toolName: String?)
    /// 将来ケース。黙って捨ててよい。
    case ignored
}

/// **`[TOOL]` の行に出してよい形へ潰す。行き先は開発者の端末である。**
///
/// ## `ToolText.singleLine(_:limit:)` とは別物である（**わざと別にしてある**）
///
/// | | `ToolText.singleLine` | ここ |
/// |---|---|---|
/// | 宛先 | モデルの文脈・画面 | **端末（stderr）** |
/// | 消すもの | Cc / Zl / Zp（行を割る構造） | **Cc / Cf / Zl / Zp / Zs** |
/// | ゼロ幅・双方向制御（Cf） | **わざと残す**（消すなら本文でも一貫してやる必要がある） | **消す** |
/// | 置き換え | 空白1つ | `_`（`key=value` を割らない） |
///
/// **端末では制御文字が命令として解釈される。** U+001B（ESC）で始まる並びは色を変え、
/// 画面を消し、カーソルを戻す。BEL（U+0007）は鳴る。U+202E は行の**見た目を反転**できる。
/// 2026-08-18 まで、ここは `CharacterSet.whitespacesAndNewlines` しか見ておらず、
/// **ESC も BEL もそのまま stderr に出ていた**（出所はモデルが書いたツール名である）。
///
/// > **長さも書記素ではなくスカラーで切る。** `prefix(64)` は書記素クラスタを64個数えるので、
/// > `"a" + U+0301 × 5,000` が1文字として通り、1万バイトの行が出る
/// > （`ToolText.singleLine` と同型の欠陥。同じ日に両方直した）。
///
/// **`internal` にしてあるのは試験から呼べるようにするため**である。
/// `writeToolLine` 自身は `private` のまま ── あれは呼べば stderr へ書く（副作用がある）が、
/// **判断はすべてこの型に寄せてあるので、判断だけを外から確かめられる。**
enum ToolLogValue {

    /// 1つの値に出してよい長さ（**Unicode スカラー**）。
    static let limit = 64

    /// 出せない文字の代わりに置くもの。**消さずに置き換える** ──
    /// 消すと「何文字あったか」が行から分からなくなる。
    static let replacement: Unicode.Scalar = "_"

    /// 潰す。**戻り値は `limit` スカラー以下で、Cc / Cf / Zl / Zp / Zs を1つも含まない。**
    static func sanitized(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(limit)
        var written = 0
        for scalar in value.unicodeScalars {
            guard written < limit else { break }
            let category = scalar.properties.generalCategory
            let unsafe =
                category == .control  // C0 / C1（ESC・BEL・タブ・改行・DEL）
                || category == .format  // ゼロ幅・双方向制御（端末の見た目を反転できる）
                || category == .lineSeparator
                || category == .paragraphSeparator
                || category == .spaceSeparator  // 空白は `key=value` の区切りである
            out.unicodeScalars.append(unsafe ? replacement : scalar)
            written += 1
        }
        return out
    }
}

/// ツールまわりの出来事を stderr へ1行で吐く。
///
/// **`[LOAD]` / `[MEM]` / `[STATS]` と同じ経路・同じ `key=value` 形式**に揃えてある。
/// 環境変数で切っていないのは、ここに出るのが**まれで、かつ必ず知りたいこと**
/// （呼べなかった／弾かれた）だけだからである。
///
/// > **原文を書かないこと。** `RejectedToolCall.rawTextPreview` には
/// > 「ライブラリが自動でログや永続化に載せてはならない」と明記されており、
/// > 実際に利用者のファイル名や検索語が入る。NFR-01（会話を端末の外に出さない）は
/// > ログ経由の流出も含む（`SophiaDatabase.configuration` と同じ考え方）。
/// > **値はモデルが書いた文字列である。** ツール名は捏造されうるので、
/// > `ToolLogValue.sanitized(_:)` を必ず通す ── **さもないと1行の `key=value` が
/// > 崩れ、最悪ログの行そのものをモデルに書かれる**（`[LOAD]` の値はアプリが作るので
/// > この心配が無かった。ここが初めての「外から来る値」である）。
private func writeToolLine(_ event: String, fields: [(key: String, value: String)]) {
    let line = (["event=\(event)"] + fields.map { "\($0.key)=\(ToolLogValue.sanitized($0.value))" })
        .joined(separator: " ")
    FileHandle.standardError.write(Data("[TOOL] \(line)\n".utf8))
}

/// 取得の状況を stderr へ1行で吐く。
///
/// **`print` を使わない。** `[MEM]` / `[STATS]` と同じ経路（生の `write(2)`）・
/// 同じ `key=value` 形式に揃えてあり、`2> ログ` でそのまま拾える。
/// **値に空白を入れないこと**（`model=` にリポジトリIDが入るが空白は含まない）。
///
/// バイト数を MB/GB へ丸めずに生で出しているのは、**丸めが桁の取り違えを生む**ため。
/// ログは人が読む前に grep されるので、単位の解釈は読み手に委ねるほうが安全である。
private func writeModelLoadLine(
    _ event: String, model: String, report: ModelDownloadStallWatch.Report
) {
    let fields = [
        "event=\(event)",
        "model=\(model)",
        "completed_bytes=\(report.completedBytes)",
        "total_bytes=\(report.totalBytes)",
        "callbacks=\(report.callbackCount)",
        "idle_s=\(String(format: "%.1f", report.idleSeconds))",
    ].joined(separator: " ")
    FileHandle.standardError.write(Data("[LOAD] \(fields)\n".utf8))
}

extension SophiaError {

    /// 無進捗の所見を、**原因と対処をセットにした日本語**へ変換する（FR-11）。
    ///
    /// 文言を2通りに割っているのは、**利用者が取るべき行動が違うから**である。
    ///
    /// | 観測 | 読み | 出す対処 |
    /// |---|---|---|
    /// | 1バイトも来ていない | 接続が**成立していない** | 回線の確認 ＋ VPN/プロキシ/ファイアウォール |
    /// | 途中で止まった | 接続が**切れた** | 回線の確認 ＋ 続きから再開できる旨 |
    ///
    /// 「失敗しました」だけにしないこと ── それは今回黙っていたのと大差ない。
    static func modelDownloadStalled(
        _ report: ModelDownloadStallWatch.Report, modelID: String
    ) -> SophiaError {
        let seconds = Int(report.idleSeconds.rounded())
        let message: String
        let hint: String

        if report.sawAnyBytes {
            message = "モデルの取得が途中で止まりました。"
                + "\(seconds)秒のあいだ、受信量が1バイトも増えていません（\(report.progressText)）。"
            hint = "ネットワークの接続を確認して「再試行」を押してください。"
                + "ここまで取得した分は残っており、その続きから再開されます。"
        } else {
            message = "モデルの取得が始まりませんでした。"
                + "\(seconds)秒待っても1バイトも届いていません（\(report.progressText)）。"
            hint = "ネットワークの接続を確認して「再試行」を押してください。"
                + "接続できているのに始まらない場合は、VPN・プロキシ・ファイアウォールが "
                + "huggingface.co への通信を止めていないかを確認してください。"
        }

        return SophiaError(
            code: .modelDownloadStalled,
            message: message,
            hint: hint,
            // 開発者向け。`[LOAD] event=stalled` の行と同じキーで揃えてある
            // ── 画面のスクリーンショットとログを突き合わせられるようにするため。
            detail: "completed_bytes=\(report.completedBytes) "
                + "total_bytes=\(report.totalBytes) "
                + "callbacks=\(report.callbackCount) "
                + "idle_s=\(String(format: "%.1f", report.idleSeconds)) "
                + "model=\(modelID)")
    }
}

// =============================================================================
//  プリフィルの再利用（往復のたびに全部払い直すのをやめる）
// -----------------------------------------------------------------------------
//  ## 何が起きていたか（2026-08-18 21:50 の実測）
//
//      [MEM] stage=prefill_end  prefill_total=459   ← 1周目
//      [MEM] stage=prefill_end  prefill_total=1271  ← 2周目。**459 を払い直している**
//      [STATS] in=1730 ttfr_s=57.58 prefill_s=21.50 total_s=79.67
//
//  往復が増えるほど二乗で効く。
//
//  ## 前任者が残した懸念と、それへの答え
//
//  > 書き戻した `<tool_call>` の綴りがモデルの出力と1文字でも違えば接頭辞が一致せず、
//  > **黙って壊れた再利用になるほうが怖い**
//
//  **懸念は正当である。** 綴りは実際にずれる ── テンプレートが描き直す
//  `<tool_call>` の空白や改行がモデルの出力と一致する保証はどこにも無いし、
//  トークン化の境目（`assistant\n` の直後）は文字が1つ変われば動く。
//
//  **だが「怖い」と「確かめようがない」は違う。**
//  ここは**トークン列そのものを比べている。**
//
//   1. キャッシュへ払ったトークン列を**そのまま台帳に持つ**（`PrefillCacheLedger`）
//   2. 次の周は、台帳と新しいプロンプトの**最長共通接頭辞**を取る
//   3. 一致した長さまでだけ再利用し、**その先はキャッシュを巻き戻して捨てる**
//
//  綴りがずれていれば共通接頭辞がそこで止まるだけで、**ずれた中身を使うことは無い。**
//  ずれが先頭近くまで来れば `short_prefix` で作り直す ＝ **従来と同じ経路**である。
//  「一致しなければ黙って全部やり直す」を、判断の既定にしてある。
//
//  ## 台帳が嘘をつかないための約束（**ここが要**）
//
//  キャッシュに1バイトでも触る前に `ledger.clear()` を呼ぶ。
//  途中で throw しても、残るのは「中身の分からないキャッシュ」ではなく
//  **「台帳の無いキャッシュ」＝ 次の周は必ず作り直し**になる。
//  逆順（触ってから消す）にすると、失敗した周のキャッシュが古い台帳と組み合わさり、
//  **まさに前任者が恐れた「黙って壊れた再利用」**が起きる。
//
//  ## 既定は無効（`SOPHIA_PREFILL_REUSE=1` で有効）
//
//  **この実装はまだ実機で1度も走っていない。** 往復は実機で動いており、
//  壊さないことが最優先である。同じバイナリで A/B が取れる形にしてあるので、
//  2周目の出力が正気であることを確かめてから
//  `prefillReuseEnabledByDefault` を `true` にすること。
// =============================================================================

/// 1周ぶんのプリフィルをどう払うか。**MLX を一切知らない純粋な判断。**
///
/// 型で持っているのは、`PrefillReuseTests` が**実装と同じ関数**を呼んで
/// 値まで確かめられるようにするためである（テストの中に仮の定義を置かない）。
enum PrefillReuseDecision: Equatable, Sendable {

    /// キャッシュを捨てて全部払い直す。**従来とまったく同じ経路。**
    /// 付いている文字列は「なぜ捨てたか」で、`[PREFILL]` 行にそのまま出る。
    case rebuild(String)

    /// 先頭 `reuse` トークンはキャッシュにある。`prompt[reuse...]` だけ払う。
    case append(reuse: Int)

    /// キャッシュを `trim` トークンだけ巻き戻してから `prompt[reuse...]` を払う。
    ///
    /// 巻き戻す中身は2つある ── **前の周が生成したトークン**と、
    /// **台帳のうち今回のプロンプトと食い違った末尾**である。
    case trimThenAppend(reuse: Int, trim: Int)

    /// キャッシュから持ち越した長さ。**払わずに済んだトークン数。**
    var reusedTokens: Int {
        switch self {
        case .rebuild: 0
        case .append(let reuse): reuse
        case .trimThenAppend(let reuse, _): reuse
        }
    }

    /// 巻き戻して捨てた長さ。
    var trimmedTokens: Int {
        switch self {
        case .rebuild, .append: 0
        case .trimThenAppend(_, let trim): trim
        }
    }

    /// `[PREFILL] decision=` に出る名前。**意味を変えないこと**（過去のログが読めなくなる）。
    var logName: String {
        switch self {
        case .rebuild: "rebuild"
        case .append: "append"
        case .trimThenAppend: "trim_append"
        }
    }

    /// `rebuild` のときだけ入る理由。それ以外は `-`。
    var logReason: String {
        switch self {
        case .rebuild(let reason): reason
        case .append, .trimThenAppend: "-"
        }
    }
}

extension MLXEngine {

    /// これ未満しか一致しなかったら再利用しない。
    ///
    /// **端数を持ち越しても得が無い**からである。巻き戻しと台帳の比較には
    /// それ自体の費用があり、数十トークンのために壊れる余地を開けるのは割に合わない。
    /// 実測の相手は「1周目の459トークン」のような塊であって、端数ではない。
    static let prefillReuseMinimumTokens = 128

    /// 再利用を有効にするか。**既定は無効**（このファイル冒頭の解説を読むこと）。
    ///
    /// | 環境変数 | 効果 |
    /// |---|---|
    /// | `SOPHIA_PREFILL_REUSE=1` | 再利用する |
    /// | 無指定 / `=0` | **従来どおり毎周全部払う** |
    ///
    /// `let` なのでプロセス起動時の値で固定される ── 途中で条件が動くと計測にならない。
    /// 実機で確かめたら、この既定を `true` にすること（変えるのはこの1語だけで済む）。
    static let prefillReuseEnabledByDefault = false

    /// （`Self` ではなく型名で書いてある。ストアドプロパティの既定値式で `Self` を
    ///   参照すると Swift のバージョンによって弾かれるため ──
    ///   `clearsCacheAfterGeneration` と同じ事情である）
    static let prefillReuseEnabled: Bool = {
        switch ProcessInfo.processInfo.environment["SOPHIA_PREFILL_REUSE"] {
        case "1": return true
        case "0": return false
        default: return MLXEngine.prefillReuseEnabledByDefault
        }
    }()

    /// **この周のプリフィルをどう払うか決める。** 副作用を持たない。
    ///
    /// - Parameters:
    ///   - cachedTokens: キャッシュへ払い済みのトークン列（台帳）。空 ＝ 冷えている
    ///   - promptTokens: この周に描画されたプロンプト全体
    ///   - cacheOffset: キャッシュが実際に進んでいる位置。
    ///     **nil はエントリ間でオフセットが揃っていない**（＝信用できない）
    ///   - cacheIsTrimmable: 全エントリが巻き戻せるか
    static func prefillReuseDecision(
        enabled: Bool,
        cachedTokens: [Int],
        promptTokens: [Int],
        cacheOffset: Int?,
        cacheIsTrimmable: Bool,
        minimumReuse: Int = MLXEngine.prefillReuseMinimumTokens
    ) -> PrefillReuseDecision {

        guard enabled else { return .rebuild("off") }
        guard !cachedTokens.isEmpty else { return .rebuild("cold") }
        guard !promptTokens.isEmpty else { return .rebuild("empty_prompt") }

        // オフセットが取れない／揃っていない。**層ごとに違う位置に居るキャッシュ**は
        // どこまで正しいか言えないので触らない。
        guard let cacheOffset else { return .rebuild("no_offset") }

        // **台帳より短いキャッシュ。** 中断や失敗で払い切れていない。
        // 台帳の後半が本当に載っているかを言えないので信用しない。
        guard cacheOffset >= cachedTokens.count else { return .rebuild("short_cache") }

        let common = Self.commonPrefixLength(cachedTokens, promptTokens)

        // **全部一致してしまった。** 払うトークンが1つも残らず、
        // 最初のフォワード（次トークンのロジット）が打てない。素直に作り直す。
        guard common < promptTokens.count else { return .rebuild("no_new_tokens") }

        // 端数しか一致しなかった。上の `prefillReuseMinimumTokens` の解説を読むこと。
        guard common >= minimumReuse else { return .rebuild("short_prefix") }

        // **ここまでで「先頭 common トークンはキャッシュに載っている」が確定している。**
        // キャッシュを common の位置まで戻せば、その先を継ぎ足せる。
        // 戻す量は台帳の食い違いぶん＋前の周が生成したぶんの合計になる。
        let trim = cacheOffset - common
        if trim == 0 { return .append(reuse: common) }

        guard cacheIsTrimmable else { return .rebuild("not_trimmable") }
        return .trimThenAppend(reuse: common, trim: trim)
    }

    /// 2つのトークン列が先頭から何個一致しているか。
    ///
    /// **文字列ではなくトークン ID を比べている。** これが「接頭辞が一致しているか」の
    /// 確かめ方そのものである ── 綴りの違いはトークン化の結果に必ず出る。
    static func commonPrefixLength(_ lhs: [Int], _ rhs: [Int]) -> Int {
        var index = 0
        let limit = min(lhs.count, rhs.count)
        while index < limit, lhs[index] == rhs[index] { index += 1 }
        return index
    }
}

/// キャッシュと、**そこへ払い済みのトークン列**を組にして持つ箱。
///
/// ## なぜ組で持つのか
///
/// キャッシュ単体は「何トークン載っているか」しか言えない（`offset`）。
/// **何が載っているか**は言えない。台帳が無ければ接頭辞の比較ができず、
/// 「一致しているはず」で使うことになる ── それが黙って壊れる再利用である。
///
/// ## `@unchecked Sendable` にしている理由
///
/// `PrefillMemoryProbe` とまったく同じ事情である（`NSLock` で囲ってあるが
/// コンパイラには見えない。`Mutex` は macOS 15 以上でこのアプリの下限は 14）。
/// 加えて `[KVCache]` は `Sendable` ではないので、`ModelContainer.perform` の
/// `@Sendable` クロージャへ渡すには箱に入れるしかない。
///
/// **中身に触るのは `perform` の内側だけ**である（`ModelContainer` は直列アクセスを
/// 保証する）。生成自体も `MLXEngine.isGenerating` で直列化されている。
final class PrefillCacheLedger: @unchecked Sendable {

    private let lock = NSLock()
    private var cache: [KVCache] = []
    private var tokens: [Int] = []

    init() {}

    func read() -> (cache: [KVCache], tokens: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        return (cache, tokens)
    }

    /// **払い終えてから**書く。書いた時点で「キャッシュはこの列を表す」が真になる。
    func store(cache: [KVCache], tokens: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        self.cache = cache
        self.tokens = tokens
    }

    /// **キャッシュに触る前に呼ぶ。** 空にした状態で throw すれば、
    /// 次の周は必ず `cold` で作り直しになる（壊れた再利用より遅いほうが遥かにまし）。
    ///
    /// ターンの終わりでも呼ぶ ── KVキャッシュを次のターンまで抱えたままにしない
    /// （16GB機では 1,000トークンで 100MB 台を握る。**そこは黙って払う額ではない**）。
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache = []
        tokens = []
    }
}

/// 1周ぶんの生成を始めた結果。`[PREFILL]` 行に出す材料も一緒に返す。
struct PrefillRound: Sendable {
    let stream: AsyncStream<Generation>
    let decision: PrefillReuseDecision
    /// **実際に払ったトークン数。** `promptTokens.count - decision.reusedTokens` と一致する。
    let fedTokens: Int
}

extension MLXEngine {

    /// 1周ぶんの生成を開始する。**`ModelContainer.perform` の内側でだけ呼ぶこと。**
    ///
    /// `context.model` も `[KVCache]` も `Sendable` ではないので、
    /// 触ってよいのは直列アクセスが保証されているこの内側だけである。
    /// 返すのは `Sendable` なものだけ（`AsyncStream<Generation>` と数値）。
    ///
    /// **プリフィルはこの関数が返る前に終わっている。**
    /// `MLXLMCommon.generate` は `TokenIterator` を先に組み立ててから
    /// ストリームを返し、プリフィルはその `init` の中で同期的に走る
    /// （`Evaluate.swift` の `TokenIterator.prepare(input:prefill:)`）。
    /// だから「払い終えてから台帳を書く」がこの並びで成立する。
    static func startPrefillRound(
        context: ModelContext,
        preparedInput: LMInput,
        promptTokens: [Int],
        ledger: PrefillCacheLedger,
        reuseEnabled: Bool,
        parameters: GenerateParameters,
        components: GenerationComponents,
        tools: [[String: any Sendable]]?
    ) throws -> PrefillRound {

        let stored = ledger.read()

        // **入力の形が想定と違ったら降りる。**
        // 画像・動画・音声・明示マスクが載った入力は、位置がキャッシュのオフセットだけでは
        // 決まらない（MLXLMCommon の `PromptCacheTurn` が `carriesPreparedMedia` /
        // `carriesAttentionMask` として同じ判断をしている）。
        // Sophia は文字だけを送っているので通常はここを通る ── **通らなくなったら
        // それは新しい機能が入った報せ**であり、再利用は自動的に止まる。
        let inputIsPlainText =
            preparedInput.image == nil
            && preparedInput.video == nil
            && preparedInput.audio == nil
            && preparedInput.text.mask == nil

        /// **この周でキャッシュを持ち回すか。**
        /// 偽なら台帳へ1バイトも残さない ── KVキャッシュの寿命が入れる前と変わらない。
        let reuseActive = reuseEnabled && inputIsPlainText

        // 層ごとのキャッシュのオフセットが揃っているか。揃っていなければ nil を渡す。
        // （`\.offset` ではなくクロージャで書いているのは、`any KVCache` の
        //   キーパスを避けるためだけである。意味は同じ）
        let offsets = stored.cache.map { $0.offset }
        let alignedOffset: Int? =
            offsets.isEmpty || !offsets.allSatisfy({ $0 == offsets[0] }) ? nil : offsets[0]
        let cacheIsTrimmable =
            !stored.cache.isEmpty && stored.cache.allSatisfy { $0.isTrimmable }

        var decision = Self.prefillReuseDecision(
            enabled: reuseActive,
            cachedTokens: stored.tokens,
            promptTokens: promptTokens,
            cacheOffset: alignedOffset,
            cacheIsTrimmable: cacheIsTrimmable)

        // 有効にしてあるのに入力の形で降りた。**理由を分けて残す**
        // ── 設定で切ったのとは別の事情であり、混ぜるとログから区別できない。
        if reuseEnabled, !inputIsPlainText { decision = .rebuild("input_shape") }

        // =====================================================================
        //  **ここから先はキャッシュに触る。だから先に台帳を空にする。**
        //  この1行を下へ動かさないこと（このファイルの解説「台帳が嘘をつかないための約束」）。
        // =====================================================================
        ledger.clear()

        var cache = stored.cache
        var fedTokens: [Int]

        switch decision {
        case .rebuild:
            // **切ってある周は空のままにする。** 下で `cache: nil` として渡り、
            // `TokenIterator.init` の `cache ?? (try model.newCache(...))` が
            // 自前で作る ── **入れる前とまったく同じ経路**である。
            // 持ち回る周だけ、次の周のためにここで作って握る。
            //
            // （三項演算子で書かないこと。`try` は式の先頭にしか置けない ──
            //   `cond ? try f() : x` は "'try' cannot appear to the right of a
            //   non-assignment operator" で弾かれる）
            if reuseActive {
                cache = try context.model.newCache(parameters: parameters)
            } else {
                cache = []
            }
            fedTokens = promptTokens

        case .append(let reuse):
            fedTokens = Array(promptTokens[reuse...])

        case .trimThenAppend(let reuse, let trim):
            // **巻き戻した結果を必ず見る。** 戻り値（何個戻せたか）と、
            // 戻したあとのオフセット（どこに着地したか）の両方である。
            // 片方でも合わなければキャッシュはもう説明できない ── 作り直して全部払う。
            let removed = cache.map { $0.trim(trim) }
            let landed = cache.map { $0.offset }
            if removed.allSatisfy({ $0 == trim }), landed.allSatisfy({ $0 == reuse }) {
                fedTokens = Array(promptTokens[reuse...])
            } else {
                decision = .rebuild("trim_failed")
                cache = try context.model.newCache(parameters: parameters)
                fedTokens = promptTokens
            }
        }

        // **再利用しない周は、用意済みの入力をそのまま渡す。**
        // 組み直すと、テンプレート側が付けたものを落とす危険がある。
        // 従来経路を1バイトも動かさないための分岐である
        // （`LLMUserInputProcessor` も `LMInput(tokens: MLXArray(promptTokens))` を
        //   作っているので、再利用する周の組み直しは形として同じものになる）。
        let input =
            decision.reusedTokens == 0 ? preparedInput : LMInput(tokens: MLXArray(fedTokens))

        let stream = try MLXLMCommon.generate(
            input: input,
            cache: cache.isEmpty ? nil : cache,
            parameters: parameters,
            context: context,
            components: components,
            tools: tools)

        // **払い終えた。** いまキャッシュが表しているのは描画したプロンプト全体である。
        // このあと生成が乗るとオフセットは先へ進むが、台帳は動かさない ──
        // 次の周は `cacheOffset - common` を巻き戻すので、生成ぶんも一緒に落ちる。
        //
        // **持ち回らない周は書かない。** 書くと KVキャッシュがターンの終わりまで
        // 生き残り、切ってあるはずの経路でメモリの挙動だけが変わる（A/B が濁る）。
        if reuseActive { ledger.store(cache: cache, tokens: promptTokens) }

        return PrefillRound(stream: stream, decision: decision, fedTokens: fedTokens.count)
    }
}

/// `[PREFILL]` 行を stderr へ1行で吐く。**周ごとに必ず1行出る。**
///
/// **`print` を使わない。** `[MEM]` / `[STATS]` / `[TOOL]` と同じ経路（生の `write(2)`）・
/// 同じ `key=value` 形式に揃えてあり、`2> ログ` でそのまま拾える。
///
/// この行だけで「何周目に、何トークン描画して、そのうち何トークン払ったか」が読める。
/// **`prompt` と `fed` の差が、再利用が実際に効いた量である。**
private func writePrefillLine(_ fields: [(key: String, value: String)]) {
    let line = fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    FileHandle.standardError.write(Data("[PREFILL] \(line)\n".utf8))
}

// =============================================================================
//  実機で確かめること（このファイルは実行していない）
// -----------------------------------------------------------------------------
//  1. **トークンが実際に流れるか。** `.chunk` が届き、日本語が化けないこと
//  2. **思考と本文が分かれるか（FR-17）。** `primedInside` の自動判定が
//     Qwen3 で `false` になること。`true` になっていたら思考が本文へ漏れる
//  3. **思考OFFが効くか（FR-18）。** `enable_thinking: false` で
//     `<think></think>` の空ブロックだけが来て、思考テキストが出ないこと
//  4. **中断が効くか（FR-02）。** `task.cancel()` から実際に生成が止まるまでの時間。
//     ストリームを抜けても計算は数ミリ秒続くと公式コメントにある
//  5. **プリフィル進捗が届くか。** `.prefill` が複数回来ること
//     （1回しか来ないなら chunking が働いていない）
//  6. **計測値が Ollama と比較できるか。** `promptTokensPerSecond` を
//     BENCH_RESULTS.md の「入力処理 148 tok/s」と並べる
//  7. **メモリが持つか。** 4.62GB の重み + KVキャッシュで、
//     この機体（空き0.5〜2.8GB / スワップ6〜7GB）が耐えるか
//  8. **計測時はデバッガを外す**（cmd-opt-r → "Debug Executable" のチェックを外す）
//
//  ## 取得の見張りについて確かめること（2026-08-18 に追加）
//
//  判定ロジックは `ModelDownloadStallTests` が実ダウンロード無しで確かめている。
//  **実機でしか確かめられないのは、配管が繋がっているかどうかだけ**である。
//
//  9. **誤検知しないこと（最優先）。** キャッシュを消してから普通に取得し、
//     **最後まで通ること。** 特に「取得100% → 重みの展開」の数十秒で
//     打ち切られないこと（`finished` が立っているか）
//  10. **検知できること。** 取得中に Wi-Fi を切り、**60〜65秒**で
//      「取得が途中で止まりました」が画面に出ること
//  11. **始まらない場合を検知できること。** 機内モードのまま起動し、
//      **90〜95秒**で「取得が始まりませんでした」が出ること
//  12. **再試行が効くこと。** 回線を戻して「再試行」を押し、
//      **途中から**再開されること（0 バイトからやり直しになっていないこと）
//  13. **`isLoading` が戻ること。** 打ち切りのあと「再試行」が
//      「すでに進行中です」にならないこと。**なる場合は取得側がキャンセルを
//      見ていない**ので、そのことをここに記録すること（別途の対処が要る）
//  14. **ログが出ること。** `SOPHIA_LOG_LOAD=1` で `[LOAD] event=tick` が
//      5秒ごとに出て、打ち切り時は設定に関係なく `event=stalled` が出ること
//
//  ## ツール呼び出しについて確かめること（2026-08-18 に追加 / FR-19・第16章）
//
//  **配線の形は `EngineToolWiringTests` がモデル無しで固定している。**
//  実機でしか分からないのは、モデルを通したときの振る舞いである。
//  （`ToolCallProbeTests` が測ったのは**モデルの能力**であって、この経路ではない）
//
//  15. **`idle` で 0 トークンであること（FR-21 の本丸）。**
//      `SOPHIA_TOOLTOKENS=1` で `EngineToolWiringTests` の計測を回し、
//      **同じ会話で「ツールあり」と「なし」の実トークン数の差**を見る。
//      `[TOOLTOKENS] with=… without=… delta=…` が出る。
//      **`delta` が `inputTokenBudget = 1000` の何割かが、16.2節の宿題の答えである**
//      （16.9節の項目4。「32個で4,550だから3個なら430」という割り算はしないこと）
//  16. **アプリからツールが呼べること。** `options.tools` を渡した往復で
//      `.toolCall` が届くこと。**プローブが通ったのは別経路である**（16.9節の但し書き）
//  17. **思考モードとの同時使用（16.9節の項目3。未確認のまま残っている）。**
//      思考ONでツールを渡し、`<tool_call>` が `.thinking` / `.content` に
//      **1文字も混ざらない**こと。混ざったら `ToolCallProcessor` の緩衝と
//      `<think>` の入れ子が干渉している ＝ 16.1節の前提が崩れる
//  18. **`[TOOL]` 行が出ないこと（普段は）。** `event=rejected` が出るなら
//      モデルが形式を守れていない。`event=unexpected_call` が出るなら
//      **ツールを渡していない会話で呼びに来ている** ── どちらも設計の前提が揺れる報せ
//
//  ## 往復について確かめること（2026-08-18 追加 / FR-19・16.8節）
//
//  **形は `ToolRoundTripTests` がモデル無しで固定している**（書き戻しの辞書・
//  実行役・上限・門の閉じ方）。実機でしか分からないのは、**モデルがその形を
//  受け取ってどう振る舞うか**である。
//
//  19. **1往復が閉じること（本丸）。** フォルダを結び付けて「notes.md に何が
//      書いてある？」と訊き、**読んだ内容に基づく答えが返ること。**
//      `.toolCall` → `.toolResult` → 本文、の順に届くこと
//  20. **書き戻しが効いていること。** 2周目のプリフィルで
//      `<tool_call>` と `<tool_response>` が**対で**描かれていること
//      （`SOPHIA_LOG_MEM=1` の `prefill_total` が1周目より増えていれば、
//       少なくとも足された分は入力に載っている）。
//      **モデルが「何を訊いたか分からない」旨を答え始めたら、ここを疑う**
//  21. **上限に達したときに黙って終わらないこと。** `callLimit` を 1〜2 に
//      下げて長い探索をさせ、`[TOOL] event=limit_reached` のあとに
//      **「いま分かっている範囲」の答えが出ること**（無言で終わったら、
//      門を閉じた最後の1周が回っていない）
//  22. **思考ONで往復すること（16.9節 項目3の続き）。** 思考が
//      `<tool_call>` を巻き込まないこと ── 巻き込むと `visibleText` が汚れ、
//      書き戻す assistant の本文に思考が混ざる
//  23. **往復の代金を測ること。** `.done` の `inputTokens` は**周ごとの描画量の合計**である。
//      実際に払った量は `[PREFILL] fed=` のほう。1往復で何トークン払ったのかを
//      BENCH に残すこと ── 往復のある会話ではここがいちばん高い
//
//  ## プリフィルの再利用について確かめること（2026-08-19 追加）
//
//  **判断は `PrefillReuseTests` がモデル無しで固定している**（接頭辞の突き合わせ・
//  巻き戻し量・作り直しへの落ち方）。実機でしか分からないのは、
//  **巻き戻したキャッシュに継ぎ足したとき、モデルの出力が正気かどうか**である。
//  これが確かめられるまで既定は無効（`prefillReuseEnabledByDefault = false`）。
//
//  24. **まず無効のまま1往復して基準を取る。** `make prefill-off`。
//      `[PREFILL]` が周ごとに出て、`fed` が `prompt` と**常に等しい**こと
//      （等しくなければ、無効にしたつもりが効いていない）
//  25. **有効にして同じ問いを繰り返す。** `make prefill-on`。
//      2周目の `[PREFILL]` で `fed < prompt` になり、`decision=append` か
//      `trim_append` が出ること。**`decision=rebuild reason=short_prefix` ばかりなら、
//      テンプレートの再描画が先頭近くから食い違っている** ── 効果は出ないが
//      壊れてもいない（従来経路である）
//  26. **本丸: 2周目の答えが正気であること。** ここだけは目で読むしかない。
//      読んだ内容に基づく答えが返り、**日本語が壊れていない**こと。
//      壊れていたら `SOPHIA_PREFILL_REUSE=0` に戻すこと ── それだけで元に戻る
//  27. **同じ問いに同じ答えが返ること。** 24 と 25 を `temperature=0` で並べ、
//      本文が一致するか見る。**一致しなければ再利用が計算を変えている**
//  28. **`decision=trim_failed` が出ないこと。** 出たら巻き戻しが効いていない
//      （そのとき既に作り直しへ落ちているので壊れてはいないが、前提が違う）
// =============================================================================
