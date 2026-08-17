import Foundation
import Observation

/// 会話画面の状態。**UI 層で唯一エンジンを保持する場所（composition root）。**
///
/// `InferenceEngine` の型だけに依存し、MLX も Ollama も知らない（NFR-09）。
///
/// ---
///
/// # 契約で決まっている、外してはいけない4点
///
/// | # | 約束 | ここでの実装 |
/// |---|---|---|
/// | 1 | 中断は `Task.cancel()` に載せる | `stop()` |
/// | 2 | **蓄積先をキャンセルする Task の内側に置かない** | `Stream` が VM 側にある |
/// | 3 | 中断時に `.done` は届かないことがある | 届かなければ `GenerationClock` で組み立てる |
/// | 4 | `Chunk` の switch には必ず `default:` | `apply(_:)` |
///
/// # 描画の間引き（NFR-02）
///
/// エンジンは**間引かずに全件流す**約束なので、間引くのはここの責務である
/// （DESIGN.md 第5.2章）。届いた断片はまず観測対象外のバッファへ溜め、
/// 16ms に1回だけ `ChatTurn` へ書き戻す。
/// 実測 13 tok/s なら間引かなくても耐えるが、**モデルが速くなった時に破綻する。**
@MainActor @Observable
final class ChatViewModel {

    // MARK: - 画面が読む状態

    private(set) var turns: [ChatTurn] = []

    /// 入力欄の中身。
    var input: String = ""

    /// 思考モード（FR-18）。会話ごとの切替。
    var thinkingEnabled: Bool = true

    /// 自己認識（FR-23）を送るか。既定は `SOPHIA_SYSTEM_PROMPT` から取る。
    ///
    /// `@Observable` なので、切り替えるとその場で `estimatedInputTokens` が計算し直され、
    /// **払っている額が画面のトークン計に増減として出る。** これが「測ってから足す」の実装形。
    var systemPromptEnabled: Bool = SophiaDefaults.systemPromptEnabled

    private(set) var isGenerating = false

    /// 描画へ反映するたびに増える。**自動追従スクロールの合図としてだけ使う。**
    ///
    /// 本文の文字列そのものを監視させると、監視した側（会話リスト）が
    /// 毎フレーム再評価されて、過去の発言まで作り直しになる。
    /// Int を1つ挟むことで、追従の判断を小さなビュー1個に閉じ込められる。
    private(set) var streamTick = 0

    /// エンジンが読み込んでいるモデル。表示のみ（モデル管理UIは A2 以降）。
    private(set) var model: ModelInfo?
    private(set) var capabilities: EngineCapabilities?
    /// モデル読み込みの進捗。nil なら準備済みか未開始。
    private(set) var loading: LoadProgress?
    /// 起動時などの、会話に紐づかないエラー（FR-11）。
    private(set) var globalError: SophiaError?

    let engine: any InferenceEngine

    var engineIsStub: Bool { engine.identifier == .stub }

    /// 思考モードのトグルを出してよいか。
    /// OFF にできないモデル（DeepSeek-R1 系）で OFF を出すと、押しても効かないトグルになる。
    var canToggleThinking: Bool { capabilities?.canDisableThinking ?? true }

    /// 送信予定の入力が予算（DESIGN.md 第2.2章）を超えているか。
    /// **超過は隠さず見せる**（VISION の測定原則）。
    var estimatedInputTokens: Int {
        var messages = engineMessages()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { messages.append(.user(trimmed)) }
        return messages.estimatedTokenCount
    }

    var inputBudgetExceeded: Bool { estimatedInputTokens > SophiaDefaults.inputTokenBudget }

    var canSend: Bool {
        !isGenerating && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 観測対象外（ここが「Task の外の蓄積先」）

    /// 生成1回ぶんの作業領域。**`ChatViewModel` が持つ = キャンセルされる Task の外にある。**
    /// これを `Task` のローカル変数にすると、中断した瞬間に既出力が消える（FR-02 違反）。
    @ObservationIgnored private var stream: Stream?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// 利用者が停止ボタンを押したか。`.done` が来ない場合の終了理由の判定に使う。
    @ObservationIgnored private var stopRequested = false

    @MainActor
    private final class Stream {
        let turn: ChatTurn
        var clock = GenerationClock()
        /// まだ画面へ反映していない差分。**ここに溜まっていても消えない**（VM の寿命）。
        var pendingThinking = ""
        var pendingContent = ""
        var thinkingStartedAt: ContinuousClock.Instant?
        var stats: GenerationStats?
        let inputTokens: Int
        let thinkingEnabled: Bool
        /// 生成中の assistant 行の主キー。DB を使っていなければ nil。
        var recordID: String?
        /// 最後に DB へ書いた時刻。1秒に1回へ間引くために持つ（Store.swift の但し書き）。
        var lastPersistedAt: ContinuousClock.Instant?

        init(turn: ChatTurn, inputTokens: Int, thinkingEnabled: Bool) {
            self.turn = turn
            self.inputTokens = inputTokens
            self.thinkingEnabled = thinkingEnabled
        }
    }

    // MARK: - 永続化（DESIGN.md 第3.1節「生成中も逐次DBへ書く」）

    /// 会話履歴の保存先。開けなかった場合は nil のまま**会話は続行する。**
    /// 保存できないことは不便だが、話せないことより軽い。
    @ObservationIgnored private var store: Store?
    /// いま書き込んでいる会話。最初の送信で作る。
    @ObservationIgnored private var conversationID: String?

    /// 保存処理を**呼んだ順に**直列化する鎖。
    ///
    /// ここが `Task {}`（**非構造化**）なのは意図的である。非構造化タスクは
    /// 親のキャンセルを継承しないので、`stop()` で生成タスクを畳んでも
    /// 保存は最後まで走る。FR-02「既出力は消えない」を DB 側でも守るのがこの1本。
    /// （`Store` の書き込みが同期 API なのも同じ理由。Store.swift の型コメント参照）
    ///
    /// actor へ投げっぱなしにしないのは、Swift の actor が到着順の実行を
    /// 保証していないため。begin → update → finish の順序が崩れると、
    /// 空文字の update が finish を上書きしうる。
    @ObservationIgnored private var persistTail: Task<Void, Never>?

    private func persist(_ body: @escaping @Sendable (Store) async -> Void) {
        guard let store else { return }
        let previous = persistTail
        persistTail = Task { @MainActor in
            await previous?.value
            await body(store)
        }
    }

    // MARK: - 生成

    init(engine: any InferenceEngine) {
        self.engine = engine
    }

    /// 起動時にモデルを用意する。
    ///
    /// **DB を先に開く。** テーブルが5枚できるだけなので数ミリ秒で、
    /// これを待ってもウィンドウの表示は遅れない（DESIGN.md 第3.3節）。
    /// 逆にモデル読み込み（数秒〜数分）の後ろに置くと、
    /// その間の送信が保存されない窓ができる。
    func prepare() async {
        guard model == nil else { return }

        if store == nil {
            do {
                store = try await Store.open()
            } catch {
                // 会話は続行する。保存できないことだけを伝える。
                globalError = SophiaError.wrap(error, fallback: .unknown)
            }
        }

        do {
            for try await progress in engine.load(SophiaDefaults.modelID) {
                loading = progress.stage == .ready ? nil : progress
            }
            model = await engine.loadedModel()
            capabilities = await engine.capabilities()
            if capabilities?.canDisableThinking == false { thinkingEnabled = true }
        } catch {
            loading = nil
            let wrapped = SophiaError.wrap(error, fallback: .modelLoadFailed)
            if !wrapped.isCancellation { globalError = wrapped }
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }

        globalError = nil
        input = ""

        let history = engineMessages() + [.user(text)]
        let options = ChatOptions(thinking: thinkingEnabled)

        turns.append(ChatTurn(author: .user, text: text))

        let assistant = ChatTurn(author: .assistant, phase: .waiting)
        // FR-17。**生成開始と同時に思考領域を開く。** 無言の待機を作らない。
        assistant.thinkingExpanded = thinkingEnabled
        turns.append(assistant)

        let stream = Stream(
            turn: assistant,
            inputTokens: history.estimatedTokenCount,
            thinkingEnabled: thinkingEnabled
        )
        self.stream = stream
        isGenerating = true
        stopRequested = false

        // --- 保存（生成の開始前に、行だけ先に作っておく）------------------------
        // ここで assistant の空行まで作るのが第3.1節の要点。
        // MLX / Metal が落ちてアプリごと道連れになっても、行が在れば
        // 途中まで書けた本文が残る。
        if store != nil {
            let conversation = conversationID ?? UUID().uuidString
            let isNew = conversationID == nil
            conversationID = conversation
            let recordID = UUID().uuidString
            stream.recordID = recordID
            let title = String(text.prefix(40))
            let modelID = model?.id ?? SophiaDefaults.modelID

            persist { store in
                do {
                    if isNew {
                        try await store.createConversation(
                            title: title, modelID: modelID, id: conversation)
                    }
                    try await store.appendMessage(
                        conversationID: conversation, role: .user, content: text)
                    try await store.beginAssistantMessage(
                        conversationID: conversation, id: recordID)
                } catch {
                    // 保存の失敗で会話は止めない。原因は標準エラーへ。
                    FileHandle.standardError.write(
                        Data("[Sophia] 会話の保存に失敗: \(error)\n".utf8))
                }
            }
        }

        // このタスクをキャンセルするのが FR-02 の中断。
        // 蓄積先（stream）は VM 側にあるので、キャンセルしても既出力は消えない。
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await chunk in self.engine.chat(history, options: options) {
                    self.apply(chunk)
                }
                self.finish(error: nil)
            } catch {
                self.finish(error: SophiaError.wrap(error, fallback: .generationFailed))
            }
        }
    }

    /// 中断（FR-02）。**既に出た文字は消さない。**
    func stop() {
        guard isGenerating else { return }
        stopRequested = true
        generationTask?.cancel()
    }

    /// 会話をやり直す。生成中は使わせない。
    ///
    /// **DB の行は消さない。** 画面から消えるだけで、次の送信で新しい会話が立つ。
    /// 一覧・検索は A2 以降だが、行はその時のために残しておく。
    func newConversation() {
        guard !isGenerating else { return }
        turns.removeAll()
        globalError = nil
        conversationID = nil
    }

    // MARK: - 断片の受け取り

    private func apply(_ chunk: Chunk) {
        guard let stream else { return }
        stream.clock.record(chunk)
        stream.turn.chunkCount += 1

        switch chunk {
        case .prefill(let progress):
            // 低頻度なので直接反映してよい。ここが「送信直後の無言」を潰す唯一の材料。
            stream.turn.phase = .prefilling(progress)

        case .thinking(let text):
            if stream.turn.phase != .thinking {
                stream.turn.phase = .thinking
                stream.thinkingStartedAt = ContinuousClock().now
            }
            stream.pendingThinking += text
            scheduleFlush()

        case .content(let text):
            if stream.turn.phase != .responding {
                // 本文が始まった → 思考の秒数を確定し、自動的に畳む（FR-17）。
                closeThinking(collapse: true)
                stream.turn.phase = .responding
            }
            stream.pendingContent += text
            scheduleFlush()

        case .done(let stats):
            stream.stats = stats

        @unknown default:
            // `Chunk` は将来ケースが増える。網羅 switch を書かない約束（Chunk.swift）。
            //
            // 素の `default:` ではなく `@unknown default:` にしてある。挙動の違いは実測した。
            //   いま      … 素の default は「到達しない」と警告が出る。@unknown は無警告
            //   ケース追加後 … どちらもコンパイルは通り、新ケースはここで捨てられる（契約どおり）。
            //                 加えて @unknown だけが「add missing case」と教えてくれる
            // つまり契約の目的（増えても壊れない）を保ったまま、気づける側に倒せる。
            break
        }
    }

    // MARK: - 間引き

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        // 生成タスクの子ではない独立した Task。
        // 中断されても、溜まっていた差分を書き戻す経路が死なないようにするため。
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: SophiaDefaults.renderFlushInterval)
            guard let self else { return }
            self.flushTask = nil
            self.flush()
        }
    }

    /// 溜まった差分を `ChatTurn` へ書き戻す。**ここだけが観測対象を変更する。**
    private func flush() {
        guard let stream else { return }
        var changed = false
        if !stream.pendingThinking.isEmpty {
            stream.turn.thinking += stream.pendingThinking
            stream.pendingThinking = ""
            changed = true
        }
        if !stream.pendingContent.isEmpty {
            stream.turn.text += stream.pendingContent
            stream.pendingContent = ""
            changed = true
        }
        if changed {
            stream.turn.flushCount += 1
            streamTick &+= 1
            persistProgress(stream)
        }
    }

    /// 途中経過を DB へ落とす。**1秒に1回まで。**
    ///
    /// 描画の 16ms に合わせて毎回書くと、秒間60回の UPDATE になって
    /// 計測（FR-14）に乗る雑音になる。守りたいのは
    /// 「落ちても直近1秒ぶんしか失わない」ことであって、1トークンの粒度ではない
    /// （Store.swift `updateAssistantMessage` の但し書き）。
    private func persistProgress(_ stream: Stream) {
        guard let recordID = stream.recordID else { return }
        let now = ContinuousClock().now
        if let last = stream.lastPersistedAt, last.duration(to: now) < .seconds(1) { return }
        stream.lastPersistedAt = now

        let content = stream.turn.text
        let thinking = stream.turn.thinking
        persist { store in
            try? await store.updateAssistantMessage(
                id: recordID, content: content, thinking: thinking.isEmpty ? nil : thinking)
        }
    }

    // MARK: - 終端

    private func finish(error: SophiaError?) {
        flushTask?.cancel()
        flushTask = nil
        flush()   // 取りこぼしを残さない。**この1行が FR-02 の「既出力は消えない」を支えている。**

        guard let stream else { return }
        self.stream = nil

        let turn = stream.turn
        let cancelled = stopRequested || (error?.isCancellation ?? false)

        // 思考中に止めた場合も秒数を残す（UI_SPEC.md 10.2-#13）。
        // 本文が1文字も出ていないなら畳まない。空の応答に見えてしまうため。
        closeThinking(stream: stream, collapse: !turn.text.isEmpty)
        turn.wasInterrupted = cancelled

        if let stats = stream.stats {
            turn.stats = stats
            turn.statsAreEstimated = false
        } else {
            // `.done` は届かないことがある。UI 側で確定させる（契約の約束事3・4）。
            // **思考（英語寄り）と本文（日本語寄り）が混ざるので、単一の係数では合わない。**
            // ここは文字数しか無く内訳を復元できないため、中間の 0.5 を残す。
            // `.done` が届かなかった回だけの退避経路であり、届いた回は実測値が入る
            // （`statsAreEstimated` で区別できる）。
            // **本筋は実トークナイザ**（DESIGN.md 第15章）。
            let characters = stream.clock.thinkingCharacterCount + stream.clock.contentCharacterCount
            turn.stats = stream.clock.finish(
                inputTokens: stream.inputTokens,
                outputTokens: Int(ceil(Double(characters) * 0.5)),
                stopReason: cancelled ? .cancelled : (error == nil ? .completed : .failed),
                modelID: model?.id,
                thinkingEnabled: stream.thinkingEnabled
            )
            turn.statsAreEstimated = true
        }

        if let error, !error.isCancellation {
            turn.error = error
            turn.phase = .failed
        } else {
            turn.phase = .finished
        }

        // 本文・思考・実測値を確定させる。**中断された経路でもここへ来る**
        // （`finish` は生成タスクの `catch` からも呼ばれ、保存の鎖は
        //  非構造化タスクなのでキャンセルを継承しない）。
        if let recordID = stream.recordID {
            let content = turn.text
            let thinking = turn.thinking
            let stats = turn.stats
            persist { store in
                try? await store.finishAssistantMessage(
                    id: recordID,
                    content: content,
                    thinking: thinking.isEmpty ? nil : thinking,
                    stats: stats)
            }
        }

        logMeasurement(turn)

        isGenerating = false
        stopRequested = false
        generationTask = nil
    }

    /// 1回の生成の実測値を、標準エラーへ1行で吐く。**`SOPHIA_LOG_STATS=1` のときだけ。**
    ///
    /// v1 スキーマは4列しか持たないので、`prefillTokensPerSecond`（＝
    /// BENCH_RESULTS.md の Ollama「入力処理 148 tok/s」と直接並べられる唯一の値）や
    /// `ttfrMs`（思考モードのコストそのもの）は DB に残らない。
    /// A3 で列が増えるまでの間、**実測を取り落とさないための逃がし口**である
    /// （VISION「測ることを続ける」／永続化担当の申し送り4）。
    ///
    /// 既定は無効。常時吐くと会話のたびにログが増え、
    /// 「会話は端末の外に出ない」の外側に別の記録が育ってしまう。
    private func logMeasurement(_ turn: ChatTurn) {
        guard ProcessInfo.processInfo.environment["SOPHIA_LOG_STATS"] == "1",
              let s = turn.stats else { return }
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
        let line = [
            "engine=\(engine.identifier.rawValue)",
            "model=\(s.modelID ?? "-")",
            "thinking=\(s.thinkingEnabled.map(String.init) ?? "-")",
            "stop=\(s.stopReason.rawValue)",
            "estimated=\(turn.statsAreEstimated)",
            "in=\(s.inputTokens)", "out=\(s.outputTokens)",
            "ttft_s=\(f(s.ttftMs / 1000))", "ttfr_s=\(f(s.ttfrMs.map { $0 / 1000 }))",
            "prefill_s=\(f(s.prefillSeconds))", "prefill_tps=\(f(s.prefillTokensPerSecond))",
            "decode_s=\(f(s.decodeSeconds))", "decode_tps=\(f(s.tokensPerSecond))",
            "total_s=\(f(s.totalMs.map { $0 / 1000 }))",
            "think_tok=\(s.thinkingTokens.map(String.init) ?? "-")",
            "peak_mb=\(f(s.peakMemoryBytes.map { Double($0) / 1_048_576 }))",
            "chunks=\(turn.chunkCount)", "draws=\(turn.flushCount)",
        ].joined(separator: " ")
        FileHandle.standardError.write(Data("[STATS] \(line)\n".utf8))
    }

    private func closeThinking(collapse: Bool) {
        guard let stream else { return }
        closeThinking(stream: stream, collapse: collapse)
    }

    private func closeThinking(stream: Stream, collapse: Bool) {
        let turn = stream.turn
        if let startedAt = stream.thinkingStartedAt, turn.thinkingSeconds == nil {
            turn.thinkingSeconds = startedAt.duration(to: ContinuousClock().now).milliseconds / 1000
        }
        if collapse, !turn.didAutoCollapseThinking, !turn.thinking.isEmpty {
            turn.didAutoCollapseThinking = true
            turn.thinkingExpanded = false   // 以後は利用者の開閉を尊重する
        }
    }

    // MARK: - エンジンへ渡す会話

    /// 確定済みの発言だけを `SophiaMessage` に落とす。
    ///
    /// **思考テキストは入れない。** 過去の思考を送り返すとプリフィルが無駄に膨らむ
    /// （VISION 第1因子）。`SophiaMessage` に thinking が無いのはそのため。
    ///
    /// ## システムプロンプト（自己認識 / FR-23）を先頭に置く
    ///
    /// かつてここには「付けない。入れた瞬間、毎ターンその分のトークンを払い続ける。
    /// 必要になったら何トークン増えるか測ってから足すこと」と書いてあった。
    /// **測った上で、自己認識3行ぶんだけ払うと決めた。**
    /// Modelfile の SYSTEM 全文（概算+219トークン）は持ち込んでいない
    /// ─ 内訳と判断は `SophiaDefaults.systemPrompt` のコメント、実測は BENCH_RESULTS.md。
    ///
    /// **足すならここ以外にない。** `estimatedInputTokens` と `send()` が
    /// どちらもこの関数を通っているので、ここに入れれば
    /// 「画面に出るトークン数」と「実際に送る量」が構造的に一致する。
    /// `send()` 側だけに足すと、入力欄の予算警告が実送信より少ない嘘の数字になる
    /// ─ VISION の測定原則（無駄が痛みとして見えないと誰も減らさない）を最初に破るのがこの形。
    ///
    /// 次の担当者へ: ③書き方の原則・④やりとりの原則を**ここへ足さないこと。**
    /// 足すと 331 トークンへ戻る。役割の切替は A2 の `ProfileRecord.systemPrompt`（FR-05）へ。
    private func engineMessages() -> [SophiaMessage] {
        let system: [SophiaMessage] =
            systemPromptEnabled ? [.system(SophiaDefaults.systemPrompt)] : []
        return system + turns.compactMap { turn in
            guard !turn.text.isEmpty else { return nil }
            switch turn.author {
            case .user: return .user(turn.text)
            case .assistant:
                guard turn.phase == .finished else { return nil }
                return .assistant(turn.text)
            }
        }
    }
}
