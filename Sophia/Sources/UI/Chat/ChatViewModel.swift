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

    /// モデルの読み込みが走っている間 true。
    /// **再試行ボタンの二重押しを止めるためだけに持つ。** 押せてしまうと
    /// エンジン側の「すでに進行中です」に化けて、利用者には理由が分からない。
    private(set) var isLoadingModel = false

    /// 読み込みを始めた時刻。nil なら走っていない。
    ///
    /// **画面に経過秒数を出すために持つ。** 「0% のまま止まっている」と
    /// 「まだ10秒しか経っていない」は、進捗率だけを見ていると区別できない。
    /// 利用者が「待つ／やり直す」を決められる唯一の材料がこれである。
    private(set) var modelLoadStartedAt: Date?

    /// 再試行ボタンを出してよいか。**モデルが載っていないときだけ。**
    ///
    /// 保存（`Store`）の失敗でも `globalError` は立つが、そちらは
    /// 読み込みをやり直しても直らない。押しても何も起きないボタンを出さないための条件。
    var canRetryModelLoad: Bool { model == nil && !isLoadingModel }

    let engine: any InferenceEngine

    /// **この会話にフォルダが結び付いているか**（FR-19 / FR-21 / 16.2節）。
    ///
    /// `idle` / `armed` の唯一の出所である。`ChatOptions.tools` を埋めるのは
    /// `send()` の1行だけで、その中身は必ずここから取る ──
    /// **定義をこのファイルへ書き写さないこと。**
    let folder: ConversationFolder

    /// Change authorization is owned by the UI, never by model output.
    let toolApprovalBroker = ToolApprovalBroker()

    var pendingToolApproval: ToolApprovalRequest? { toolApprovalBroker.pendingRequest }

    var engineIsStub: Bool { engine.identifier == .stub }

    /// 思考モードのトグルを出してよいか。
    /// OFF にできないモデル（DeepSeek-R1 系）で OFF を出すと、押しても効かないトグルになる。
    var canToggleThinking: Bool { capabilities?.canDisableThinking ?? true }

    /// 送信予定の入力が予算（DESIGN.md 第2.2章）を超えているか。
    /// **超過は隠さず見せる**（VISION の測定原則）。
    ///
    /// **ツール定義ぶんを足してある**（16.2節「費用は測ること」/ 16.7節）。
    /// 足さないと、`armed` の会話では**画面に出る数字が実送信より499少ない嘘**になる。
    /// `engineMessages()` に系統を寄せているのと同じ理由で、
    /// **予算警告と実送信は同じ材料から作らないと必ずずれる。**
    ///
    /// > 内訳の性質が違う点は隠さない ── 会話ぶんは概算（文字数）、
    /// > ツール定義ぶんは**実トークナイザの実測値**である
    /// > （`SophiaDefaults.toolDefinitionTokens`。テンプレートの固定文を含むため
    /// >  アプリ側からは数えられない）。
    var estimatedInputTokens: Int {
        var messages = engineMessages()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { messages.append(.user(trimmed)) }
        return messages.estimatedTokenCount + folder.toolDefinitionTokens
    }

    var inputBudgetExceeded: Bool { estimatedInputTokens > SophiaDefaults.inputTokenBudget }

    /// **いま取得・展開の最中か。** 最中でなければ送ってよい。
    ///
    /// > **⚠ `model != nil` で判定しないこと（2026-09-05 に一度そう書いて戻した）。**
    /// > `model` が入るのは読み込みが成功した後だけなので一見正しく見えるが、
    /// > **`model` を載せずに送る経路が実在する**（`FolderUITests` の5件が即座に落ちた）。
    /// > **「モデルが載っていない」と「いま取得中である」は別の状態である。**
    /// > 塞ぎたいのは後者だけで、前者まで塞ぐと**送信そのものを壊す。**
    ///
    /// **失敗した直後は「準備中ではない」ので送れる。** そこで送れば `globalError` が
    /// 出て理由が分かる ── **黙って塞ぐより、失敗を見せるほうが利用者は次の手を打てる。**
    var isModelReady: Bool { !isLoadingModel && loading == nil }

    /// 送れる条件。**モデルが未準備の間は送れない**（2026-09-05 追加）。
    ///
    /// **理由。** 未準備のまま送ると、利用者の文は `send()` の中で消費されるのに
    /// 応答は返らない。**取得が65秒で打ち切られていた事故のとき、利用者から見えたのは
    /// 「打った文が消えて何も起きない」だった。**
    /// **打てないことより、打った文が消えることのほうが害が大きい。**
    var canSend: Bool {
        !isGenerating
            && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isModelReady
    }

    /// **なぜ送れないかを言う。** ボタンを黙って無効にしない。
    ///
    /// 事故のとき、画面は「0% のまま固まっている」ように見えていた。
    /// **待つべきなのか壊れているのかを、利用者が判断できる形にする。**
    /// 送れるときは `nil`（**表示するものが無い**）。
    var sendBlockedReason: String? {
        if isGenerating { return nil }              // 生成中は停止ボタンが出るので言う必要が無い
        if isModelReady { return nil }
        if let loading {
            return loading.detail ?? "モデルを準備しています"
        }
        if isLoadingModel { return "モデルを準備しています" }
        if globalError != nil { return "モデルを読み込めていません。再試行してください" }
        return "モデルの準備を待っています"
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
        /// このターンで、フォルダが読めるかを既に確かめたか（16.8節）。
        /// **1ターンに1回まで。** モデルが同じ誤りを6回繰り返しても、
        /// ディスクを6回叩き直す理由は無い。
        var didVerifyFolder = false

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

    /// フォルダ・ツール・DB の軽い起動準備を済ませたか。
    @ObservationIgnored private var didPrepareLocalState = false

    /// 利用者像の画面（`UserTraitsSheet` / DESIGN.md 第14章）へ渡すためだけの窓。
    ///
    /// **同じ `Store` を使い回すために置いてある。** あちらで `Store.open()` を
    /// もう一度呼ぶと、**同じファイルに対する `DatabaseQueue` が2本**できる。
    /// 壊れはしないが、書き込みが互いを待つ形になり、**理由の分からない
    /// 引っかかりの出所を1つ増やす。**
    ///
    /// nil なのは `prepare()` の前か、DB を開けなかったときである。
    /// **どちらでも画面は開く**（保存できないことだけを出す）── NFR-11。
    var traitStore: Store? { store }

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

    /// **積んである書き込みが終わるまで待つ。**
    ///
    /// `persist` は順序を守るために直列の尾（`persistTail`）へ積むので、
    /// **呼んだ直後には DB へ届いていない。** 試験がここを待たずに読むと、
    /// **「書かれていない」と「まだ書かれていない」を取り違える。**
    func waitForPendingWrites() async {
        await persistTail?.value
    }

    private func persist(_ body: @escaping @Sendable (Store) async -> Void) {
        guard let store else { return }
        let previous = persistTail
        persistTail = Task { @MainActor in
            await previous?.value
            await body(store)
        }
    }

    // MARK: - 訂正を採る（FR-27 / FR-31）

    /// **利用者が「この返しは違う」と言ったことを、向き付きで記録する。**
    ///
    /// ## 引き金は決定論的である
    ///
    /// **利用者の次の発言を読んで「訂正かどうか」を判定しない。**
    /// 判定を置けば**推論を1回払う**うえ、外したときに
    /// **利用者が言っていないことを利用者像として焼く**ことになる
    /// （14.4節 / 16.2節と同じ規則）。**明示的に押されたときだけ記録する。**
    ///
    /// ## 文はこちらが書く
    ///
    /// 利用者に文章を書かせない。**書かせると、書くのが面倒で押されなくなる。**
    /// **押した事実（向き）だけを受け取り、言語化はこちらが持つ**
    /// ── これは FR-26（様式は直接質問せず、選ばせて採る）と同じ考え方である。
    ///
    /// **1回では焼かれない。2回目で関門を越える**（0.65 → 0.75）。
    func recordCorrection(_ direction: TraitDirection?) {
        let category: String
        let statement: String
        switch direction {
        case .overreach:
            category = "certainty"
            statement = "確かめていないことは断定せず、確かめた範囲と分けて書く"
        case .hedging:
            category = "certainty"
            statement = "留保を並べず、まず結論を出す。分からない部分だけを分けて書く"
        case nil:
            category = "tone"
            statement = "この言い回しは合わない。言い方を変える"
        }
        persist { store in
            do {
                _ = try await store.recordCorrection(
                    category: category, statement: statement, direction: direction)
            } catch {
                // **黙って落とさない。** 訂正が採れていないことに気づけないと、
                // 「使っているのに学ばない」という最も分かりにくい壊れ方になる。
                FileHandle.standardError.write(
                    Data("[TRAIT] event=correction_failed reason=\(error)\n".utf8))
            }
        }
    }

    // MARK: - 生成

    /// - Parameter store: **試験のための注入口。** `nil` なら `prepare()` が自分で開く。
    ///   **開く場所を2つ作らないため**、既定は `nil` のままにしてある ──
    ///   注入されているときだけ `prepare()` が開き直さない。
    ///
    ///   **口を開けた理由**: これが無いと「画面から訂正を押したら DB に書かれるか」を
    ///   試験できず、**書かれていないことに気づけない**（FR-27 / FR-31）。
    ///   使っているのに学ばない、という最も分かりにくい壊れ方になる。
    init(
        engine: any InferenceEngine,
        folder: ConversationFolder = ConversationFolder(),
        store: Store? = nil
    ) {
        self.engine = engine
        self.folder = folder
        self.store = store
    }

    /// 起動時に、ローカル状態とモデルを順に用意する。
    ///
    /// **DB を先に開く。** テーブルが5枚できるだけなので数ミリ秒で、
    /// これを待ってもウィンドウの表示は遅れない（DESIGN.md 第3.3節）。
    /// 逆にモデル読み込み（数秒〜数分）の後ろに置くと、
    /// その間の送信が保存されない窓ができる。
    func prepare() async {
        await prepareLocalState()
        await prepareModel()
    }

    /// 質問、履歴、フォルダがモデル取得を待たずに使えるところまで用意する。
    func prepareLocalState() async {
        guard !didPrepareLocalState else { return }
        didPrepareLocalState = true

        // **フォルダの復元を最初に済ませる**（FR-19 / 16.5節 機能3）。
        // 数ミリ秒しか掛からず、モデルの読み込み（数秒〜数分）の後ろに置くと
        // その間だけチップが出ない ── 起動直後に「結び付いていない」と誤解させる。
        await folder.restoreOnLaunch()
        await syncToolExecutor()

        if store == nil {
            do {
                // **注入されていれば開き直さない。** 開き直すと、
                // 試験が見ている DB と、実際に書かれる DB が別物になる。
                if store == nil { store = try await Store.open() }
            } catch {
                // 会話は続行する。保存できないことだけを伝える。
                globalError = SophiaError.wrap(error, fallback: .unknown)
            }
        }

    }

    /// ローカル状態とは独立して、推論モデルだけを用意する。
    func prepareModel() async {
        guard model == nil, !isLoadingModel else { return }
        await loadModel()
    }

    /// 失敗した読み込みをやり直す（FR-07 の「中断・再開」／ NFR-10 の復帰）。
    ///
    /// **DB は開き直さない。** `prepare()` と分けてあるのはそのためで、
    /// 保存の可否と読み込みの可否は別々に失敗する。
    /// 取得済みのバイトは HuggingFace のキャッシュに残るので、**続きから再開される。**
    func retryModelLoad() async {
        guard canRetryModelLoad else { return }
        // 前回の失敗を消してから始める。**残したままだと、進捗と一緒に
        // 古いエラーが並んで「いま失敗しているのか」が分からなくなる。**
        globalError = nil
        await loadModel()
    }

    /// 読み込み1回ぶん。`prepare()` と `retryModelLoad()` の共通部分。
    private func loadModel() async {
        isLoadingModel = true
        modelLoadStartedAt = Date()
        defer {
            isLoadingModel = false
            modelLoadStartedAt = nil
        }

        do {
            for try await progress in engine.load(SophiaDefaults.modelID) {
                loading = progress.stage == .ready ? nil : progress
            }
            loading = nil
            model = await engine.loadedModel()
            capabilities = await engine.capabilities()
            if capabilities?.canDisableThinking == false { thinkingEnabled = true }
        } catch {
            loading = nil
            let wrapped = SophiaError.wrap(error, fallback: .modelLoadFailed)
            // 中断（FR-02）は異常ではないので赤字にしない。
            // **無進捗の打ち切り（`.modelDownloadStalled`）はここを通って画面に出る。**
            if !wrapped.isCancellation { globalError = wrapped }
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // **`isModelReady` をここでも見る。** UI 側の `canSend` だけに頼らないこと ──
        // `send()` は Return キーからも呼ばれるので、**ボタンを無効にしても口は塞がらない。**
        //
        // **早く返ることが下書きの保持そのものである。** `input` を消すのは
        // この guard の後なので、**送れなかった文は打ったまま残る。**
        // 別の置き場所へ退避しないこと ── 退避する場所を作ると、戻す経路も要る。
        guard !text.isEmpty, !isGenerating, isModelReady else { return }

        globalError = nil
        input = ""

        let history = engineMessages() + [.user(text)]

        // =====================================================================
        //  **FR-21 の実体はこの1行である**（DESIGN.md 第16.2節）
        // ---------------------------------------------------------------------
        //  `ChatOptions.tools` を埋めてよいのはここだけ。
        //  `idle`（フォルダが結び付いていない）なら `toolDefinitions` は空配列で、
        //  テンプレートの `{%- if tools %}` が開かず**1文字も注入されない。**
        //
        //  **ここに条件を足さないこと。** 「利用者の文にファイルの話が出てきたら」
        //  のような分類器を挟んだ瞬間、判定のために毎ターン計算を払うことになり、
        //  VISION 第1因子（そもそも無駄を送らない）に真正面から反する（16.2節）。
        //  引き金は利用者の操作（結び付ける・外す）だけである。
        // =====================================================================
        let options = ChatOptions(thinking: thinkingEnabled, tools: folder.toolDefinitions)

        turns.append(ChatTurn(author: .user, text: text))

        let assistant = ChatTurn(author: .assistant, phase: .waiting)
        // FR-17。**生成開始と同時に思考領域を開く。** 無言の待機を作らない。
        assistant.thinkingExpanded = thinkingEnabled
        // 16.7節「そのターンでツール定義に払ったトークン数」。
        // **`options.tools` を組んだのと同じ状態から入れる** ── 別々に決めるとずれる。
        assistant.toolDefinitionTokens =
            options.tools.isEmpty ? 0 : folder.toolDefinitionTokens
        turns.append(assistant)

        let stream = Stream(
            turn: assistant,
            inputTokens: history.estimatedTokenCount + assistant.toolDefinitionTokens,
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
            // **送る直前に、実行役をいまの結び付きへ揃える。**
            // 門（`options.tools`）は上で閉じているので、揃え忘れても
            // 「古い実行役が残っているだけ」で無害だが、**無害に頼らない**
            // （`MLXEngine.activeToolExecutor` が同じことを二重に守っている）。
            await self.syncToolExecutor()
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

    // MARK: - フォルダ参照（FR-19 / DESIGN.md 第16章）

    /// フォルダを結び付ける。**`idle` → `armed` の引き金は、この操作だけである**（16.6節 約束3）。
    func chooseFolder() async {
        folder.choose()
        await syncToolExecutor()
    }

    /// 結び付けを外す。**`armed` → `idle`。** 次のターンから注入は 0 に戻る。
    func forgetFolder() async {
        folder.forget()
        await syncToolExecutor()
    }

    /// **実行役を、いま結び付いているフォルダへ揃える。**
    ///
    /// ## 実行役は権限そのものである
    ///
    /// `FolderToolRunner` は「この会話が読んでよいフォルダ」を `let` で握っており、
    /// **差し替える口を持たない**（16.6節 約束1）。だから結び付けが変わったら
    /// **作り直す**しかない ── 中身を書き換えられる設計にしないための代償であり、
    /// 作り直しは安い（数える変数が1つあるだけである）。
    ///
    /// ## 刺さっているだけでは何も起きない
    ///
    /// 実行役の有無で注入の状態は変わらない。門は `ChatOptions.tools` のほうで、
    /// エンジンは `activeToolExecutor(_:toolsWereSent:)` で両者を掛け算する。
    /// **だから外し忘れても `idle` の会話でツールが動くことはない。**
    /// それでも揃えるのは、**片方に頼らない**ためである。
    private func syncToolExecutor() async {
        // 型を明示してあるのは好みではない ── `FolderToolRunner?` のまま渡すと
        // 存在型への暗黙変換に頼ることになる。**境界の型は境界で決めておく。**
        let executor: (any ToolExecuting)? = folder.folder.map {
            FolderToolRunner(folder: $0, approvalRequester: toolApprovalBroker)
        }
        await EngineFactory.installToolExecutor(executor, into: engine)
    }

    /// 中断（FR-02）。**既に出た文字は消さない。**
    func stop() {
        guard isGenerating else { return }
        stopRequested = true
        toolApprovalBroker.rejectPending()
        generationTask?.cancel()
    }

    func approveToolChange(_ id: UUID) {
        toolApprovalBroker.approve(requestID: id)
    }

    func rejectToolChange(_ id: UUID) {
        toolApprovalBroker.reject(requestID: id)
    }

    func rejectPendingToolChange() {
        toolApprovalBroker.rejectPending()
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

        case .toolCall(let call):
            // **区間の始まり**（FR-19 / 16.7節）。ここから `.toolResult` までの間、
            // 生成は止まっていて画面には何も流れない。**その無言を埋めるのがこの1行である。**
            //
            // 間引き（`scheduleFlush`）は通さない。往復は上限6回しかなく、
            // 溜めても得が無いうえに、**遅れて出したら「いま読んでいる」の意味が消える。**
            //
            // `call.name` も `call.argumentsJSON` も**モデルが書いた文字列**である。
            // 改行を残すと画面の上で偽の行を作れるので、必ず1行へ潰す。
            stream.turn.toolRuns.append(
                ToolRun(
                    toolName: ToolText.singleLine(call.name, limit: 60),
                    request: ToolText.singleLine(
                        "\(call.name) \(call.argumentsJSON)", limit: ToolText.nameLimit)))
            streamTick &+= 1

        case .toolResult(let activity):
            // **区間の終わり。** 直前の実行中の1件に結果を書き戻す。
            //
            // `.toolCall` → `.toolResult` は往復1回ぶんで対になって流れてくる
            // （エンジンが実行してから次を送る）。それでも「対になっているはず」に
            // 頼らず、**実行中の最後の1件**を探す ── 見つからなければ足す。
            // 落とすと、読んだ事実が画面から消える（16.6節 約束4 が守れなくなる）。
            let run: ToolRun
            if let running = stream.turn.toolRuns.last(where: { $0.isRunning }) {
                run = running
            } else {
                run = ToolRun(toolName: activity.toolName, request: activity.summary)
                stream.turn.toolRuns.append(run)
            }
            // `summary` は実行層が `ToolText.singleLine` を通した1行である
            // （`ToolActivity` の型コメント）。**ここで組み立て直さないこと** ──
            // 画面に出る文と、次のターンの文脈に残る栞が食い違う。
            run.summary = activity.summary
            run.isFailure = activity.isFailure
            run.round = activity.round
            streamTick &+= 1

            // 16.8節。**読めなかったのが「フォルダごと駄目」なのかを確かめる。**
            // モデルの失敗は引き金にすぎない ── 「そのファイルは無い」で
            // 結び付けを外したら、利用者は理由の分からない解除を食らう。
            // 原因を決めるのは**ディスクを読み直した結果**である（`verifyBinding()`）。
            if activity.isFailure, !stream.didVerifyFolder {
                stream.didVerifyFolder = true
                // 生成タスクの子にしない。**中断されても診断は最後まで走る**
                // （保存の鎖を非構造化にしてあるのと同じ理由）。
                Task { @MainActor [weak self] in
                    await self?.folder.verifyBinding()
                }
            }

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

        // **実行中のまま終わった往復を閉じる**（FR-19 / 16.7節）。
        //
        // `.toolCall` は来たが `.toolResult` が来ないまま終わることがある ──
        // 利用者が中断した、生成が失敗した、エンジンが落ちた。
        // 閉じないと**インジケータが永久に回り続ける。**
        // それは「読んでいる最中」と見分けがつかず、
        // **落ちないまま黙っている**という、本日いちばん高くついた失敗の形そのものである。
        //
        // `toolName` は `.toolCall` の時点で1行に潰してある（他所から来た文字列である）。
        for run in turn.toolRuns where run.isRunning {
            run.isFailure = true
            run.summary = "\(run.toolName): 読み取りの結果が届かないまま終わりました。"
        }

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
            // **フォルダの結び付けに関わる失敗なら、ここでも外す**（16.8節）。
            //
            // いまの経路では、ツールの失敗は例外にならずに `.toolResult` として流れる
            // （実行役は throw しない約束である）。**それでもここに funnel を置く。**
            // `code` を見て分岐するのはこの1行と `verifyBinding()` だけ、という形にしておくと、
            // 将来この `code` を投げる経路が増えたときに**握り漏らす場所が生まれない。**
            // 関係しない `code` では何も起きない（`receive(_:)` が false を返して終わる）。
            folder.receive(error)
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
    /// テストから知らせる1行を読むための口。**費用の杭がこれを使う。**
    var folderNoticeForTesting: String? { folder.boundFolderNotice }

    private func engineMessages() -> [SophiaMessage] {
        // **結び付いたフォルダを知らせる1行は、ツール定義と同じ条件で出入りする。**
        // `idle` では nil なので**1トークンも足さない**（FR-21 と同じ考え方）。
        // 自己認識を切っていても出す ── あれは「私は誰か」で、こちらは「いま何が見えるか」であり、
        // **後者を落とすとツールが在るのに使えない**（2026-08-18 実機で確認）。
        let systemText = [
            systemPromptEnabled ? SophiaDefaults.systemPrompt : nil,
            folder.boundFolderNotice,
        ].compactMap { $0 }.joined(separator: "\n")
        let system: [SophiaMessage] = systemText.isEmpty ? [] : [.system(systemText)]
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
