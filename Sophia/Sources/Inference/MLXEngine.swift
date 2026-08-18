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

    init() {
        // 起動時の1度きり。`static let` なので何度 init しても1回しか走らない。
        _ = Self.runtimeConfigured
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

        // 中断された場合でも計測値を組み立てられるよう、`do` の外に置く。
        // 送信前の概算で初期化し、`prepare` が済んだら実測値で上書きする。
        var inputTokens = messages.estimatedTokenCount

        do {
            // --- 入力を組む -----------------------------------------------------
            // `Chat.Message` は Sendable ではない。**このタスクの内側で組み立てる。**
            // 引数で受け取ろうとすると `sending 'input' risks causing data races`。
            let chat: [Chat.Message] = messages.map { message in
                switch message.role {
                case .system: .system(message.content)
                case .user: .user(message.content)
                case .assistant: .assistant(message.content)
                }
            }

            // 思考モードの ON/OFF（FR-18）。**キー名をハードコードしない。**
            // Qwen3 は `enable_thinking`、DeepSeek-R1 系は OFF にできず throw する。
            let strategy = reasoning?.promptStrategy
                ?? .templateFlag(key: "enable_thinking", defaultOn: true)
            let additionalContext = try strategy.additionalContext(
                forThinkingEnabled: options.thinking)

            // チャットテンプレート（Jinja）はこの `prepare` の内側で
            // トークナイザが適用する。Ollama ではサーバの仕事だった部分。
            let userInput = UserInput(chat: chat, additionalContext: additionalContext)
            let lmInput = try await container.prepare(input: userInput)

            let promptTokens = lmInput.text.tokens.asArray(Int.self)
            inputTokens = promptTokens.count

            guard inputTokens < options.contextLength else {
                throw SophiaError(
                    code: .contextOverflow,
                    hint: "入力が \(inputTokens) トークンで、上限 \(options.contextLength) を超えています。"
                        + "会話を新しく始めるか、入力を短くしてください。")
            }

            // --- 思考分離器を用意する（FR-17）------------------------------------
            var separator = await makeSeparator(
                container: container, promptTokens: promptTokens)

            // --- 生成パラメータ ---------------------------------------------------
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

            // --- 生成ストリームを開く ---------------------------------------------
            //
            // 注意: プリフィルは `TokenIterator.init` の中、つまり
            // **この `generate` 呼び出しの内側で同期的に走る。**
            // 上の progress コールバックはストリームが返る前に発火する。
            // `continuation` は既に存在しているので取りこぼさない。
            let stream = try await container.perform(nonSendable: lmInput) { context, input in
                try MLXLMCommon.generate(
                    input: input,
                    parameters: parameters,
                    context: context,
                    components: components)
            }

            // --- プリフィル完了の1点を回収する -------------------------------------
            //
            // **ここで拾えるのは、プリフィルが `perform` の内側で終わっているから。**
            // `MLXLMCommon.generate` は `TokenIterator` を**先に**組み立ててから
            // ストリームを返す（Evaluate.swift の `generate(input:cache:...)`）。
            // プリフィルはその `init` の中で同期的に走るので、この行に来た時点で完了している。
            //
            // ただし箱に入っているのは「最後に届いた進捗の時点」であって、
            // **必ずしも `processed == total` ではない。**
            //   - `.tokens` 経路 … 最終フォワードのあとに `progress(total, total)` が鳴る
            //     （Evaluate.swift:876）。ただしその直前は `asyncEval` なので、
            //     **計算が発行済み・完了前**の可能性がある ＝ 確保が出揃っていないことがある
            //   - `.logits` 経路 … 終端の通知が無く、最後のチャンク時点で止まる
            // だから `prefill_processed` / `prefill_total` を行に載せてある。
            // **どこまで進んだ時点の値なのかを読み手が判断できないと、この数字は使えない。**
            // 出揃った側が要るなら次の `first_token` を見ること。
            if let reading = prefillProbe.take() { appendMemory(reading) }

            // --- 断片を流す -------------------------------------------------------
            //
            // **間引かない。** 受け取った断片をそのまま全件流す。
            // 16ms のバッファリングは UI 側の責務（エンジンが間引くと計測が汚れる）。
            //
            // 1トークン = 1 `.chunk` ではない。デトークナイザは日本語のように
            // 1文字が複数トークンにまたがる場合、Unicode 境界が揃うまで出力を保留する
            // （`NaiveStreamingDetokenizer`）。文字化けした断片が画面に出ないのはこのため。
            var info: GenerateCompletionInfo?
            var sawFirstChunk = false

            for await item in stream {
                switch item {
                case .chunk(let text):
                    // **確保が出揃った側の計測点。** 断片が復号されて届いた ＝
                    // プリフィルの最終フォワードも最初のデコードも `eval` が済んでいる。
                    // `prefill_end` が下限側（発行済み・完了前を含む）なのに対して、
                    // こちらは上限側（デコード1ステップぶんを余分に含む）である。
                    // **2点で挟むのが目的**で、どちらか片方は必ず外れる。
                    if !sawFirstChunk {
                        sawFirstChunk = true
                        recordMemory(.firstToken)
                    }
                    for segment in separator.process(text) {
                        emit(segment, clock: &clock, into: continuation)
                    }
                case .info(let received):
                    info = received
                default:
                    // `.toolCall` / `.rejectedToolCall` は A1 では使わない。
                    // ツール定義を送らない以上、来ないはず（VISION 第1因子）。
                    break
                }
            }

            // 保留していた末尾を吐き出す。**呼び忘れると末尾が消える。**
            for segment in separator.finalize() {
                emit(segment, clock: &clock, into: continuation)
            }

            // --- 終端と計測（FR-14）------------------------------------------------
            //
            // ここに来る経路は3つある。
            //   1. 正常終了 → `.info` が届いている
            //   2. 中断 → `AsyncStream` は nil を返して抜ける。`.info` は届かないことがある
            //   3. 上限打ち切り → `.info` の `stopReason` が `.length`
            let cancelled = Task.isCancelled
            let stopReason = Self.stopReason(from: info, cancelled: cancelled)

            // 中断時に `.info` が来なかった場合だけ、文字数から概算する。
            // 概算であることは `EngineCapabilities.reportsExactTokenCounts` では
            // 表現できないので、BENCH に載せるときは `stopReason == .cancelled` を見ること。
            let estimatedOutput = Int(ceil(
                Double(clock.thinkingCharacterCount + clock.contentCharacterCount) * 0.5))

            continuation.yield(.done(clock.finish(
                inputTokens: info?.promptTokenCount ?? inputTokens,
                outputTokens: info?.generationTokenCount ?? estimatedOutput,
                stopReason: stopReason,
                prefillSeconds: info?.promptTime,
                prefillTokensPerSecond: info?.promptTokensPerSecond,
                decodeSeconds: info?.generateTime,
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
            //
            // 生成ループまで進んでいた場合はここへ来ず、上の正常経路で `.done` を出す
            // （`AsyncStream` はキャンセル時に例外ではなく終端で抜けるため）。
            // **どちらの経路でも `.done` の出し方を揃えておく。**
            // 消費側が既に離脱していればこの yield は捨てられる。それで正しい。
            continuation.yield(.done(clock.finish(
                inputTokens: inputTokens,
                outputTokens: Int(ceil(
                    Double(clock.thinkingCharacterCount + clock.contentCharacterCount) * 0.5)),
                stopReason: .cancelled,
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
        prefill: (processed: Int, total: Int)? = nil
    ) -> MLXMemoryReading? {
        guard Self.memoryProbeRecords else { return nil }
        return appendMemory(captureMLXMemory(stage: stage, prefill: prefill))
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
    /// 同上、入力トークンの総数。`prefillProcessed == prefillTotal` でなければ途中の値である。
    var prefillTotal: Int? = nil

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
    prefill: (processed: Int, total: Int)? = nil
) -> MLXMemoryReading {
    let snapshot = MLX.Memory.snapshot()
    return MLXMemoryReading(
        stage: stage,
        activeMemory: snapshot.activeMemory,
        cacheMemory: snapshot.cacheMemory,
        peakMemory: snapshot.peakMemory,
        prefillProcessed: prefill?.processed,
        prefillTotal: prefill?.total)
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

    init(enabled: Bool) {
        self.enabled = enabled
    }

    /// 進捗コールバックから呼ぶ。**無効なら `snapshot()` すら呼ばない。**
    /// 既定で無効なのはログを出さないためだけでなく、
    /// 計測用の処理がプリフィルの実測時間に混ざらないようにするためでもある。
    func record(processed: Int, total: Int) {
        guard enabled else { return }
        let reading = captureMLXMemory(
            stage: .prefillEnd, prefill: (processed: processed, total: total))
        lock.lock()
        defer { lock.unlock() }
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
// =============================================================================
