import Foundation

/// 生成パラメータ（DESIGN.md 第4章）。
///
/// ## `signal: AbortSignal` が無いのは意図的である
///
/// Electron 版はここに `AbortSignal` を持っていた。**Swift では持たない。**
/// 中断は `Task` のキャンセルに載せる（`InferenceEngine` の約束事を参照）。
/// 中断の手段を options に混ぜると、キャンセル経路が2つになって必ず食い違う。
struct ChatOptions: Sendable, Equatable, Codable {
    var temperature: Double
    var topP: Double
    var topK: Int
    /// コンテキスト長（Ollama の `num_ctx` に相当）。
    var contextLength: Int
    /// 生成トークンの上限。**思考モードでは自動的に引き上げる**（`applyingThinkingBudget()`）。
    var maxTokens: Int
    /// 思考モード（FR-18）。対応モデルでのみ有効。
    var thinking: Bool
    /// 再現性が要る計測で使う。nil なら毎回変わる。
    var seed: UInt64?
    /// 繰り返し抑制。nil ならモデルの既定。
    var repetitionPenalty: Double?

    // MARK: - ツール定義（FR-19 / FR-21 / DESIGN.md 第16.2節）

    /// **このターンでモデルに見せるツールの定義。既定は空 ＝ 1文字も注入しない。**
    ///
    /// ## FR-21 はこの1つの配列に還元されている
    ///
    /// Qwen3 のチャットテンプレートは `{%- if tools %}` を門にしている
    /// （16.1節。開発機に落ちている `tokenizer_config.json` で確認済み）。
    /// **`tools` を渡さなければ、ツールの system ブロックは1文字も描画されない。**
    /// つまり FR-21 は「気をつけて実装する」種類の約束ではなく、
    /// **この配列を空のままにするかどうか**である。
    ///
    /// | 会話の状態（16.2節） | ここに入るもの | 毎ターンの費用 |
    /// |---|---|--:|
    /// | `idle`（**既定**） | `[]` | **0** |
    /// | `armed`（利用者がフォルダを結び付けた） | 4つの定義 | 定義ぶん |
    /// | `resolving`（往復の最中） | 4つの定義 | 定義ぶん |
    /// | 往復が終わったら | **`[]` に戻す** | **0** |
    ///
    /// ## 状態そのものはここに持たない（**重要**）
    ///
    /// `idle` / `armed` / `resolving` の enum をこの型に足さないこと。
    /// **真実の出所が2つになり、必ず食い違う**（`.armed` なのに配列が空、など）。
    /// 状態は会話を持っている層が持ち、**この層に届く時点では
    /// 「配列が空かどうか」に潰れている**のが正しい。
    ///
    /// ## 引き金は利用者の操作だけである
    ///
    /// **利用者の文からツールの要否を推定する分類器を置かないこと**（16.2節）。
    /// それ自体が推論であり、判定のために毎ターン計算を払う ──
    /// VISION 第1因子（そもそも無駄を送らない）に真正面から反する。
    /// **モデルの出力でここを埋める経路も作らないこと**（16.6節の約束3）。
    ///
    /// ## なぜ `[ToolSpec]` をそのまま持たないのか
    ///
    /// MLX の `ToolSpec` は `[String: any Sendable]` である。あれを持つと
    /// (1) `ChatOptions` が `Equatable` / `Codable` を失い、
    /// (2) `Shared/` が MLX を知ることになって NFR-09（エンジン差し替え）が壊れる。
    /// **JSON への変換は MLX を知っている `MLXEngine` の側に閉じてある**
    /// （`MLXEngine.toolSpecs(for:)`）。
    ///
    /// > **永続化していない。** `ChatOptions` は `Store` に落ちていない（A1 現在）。
    /// > 落とすことになったら、このキーを持たない古い JSON は
    /// > synthesized の `init(from:)` で失敗する点に注意すること。
    var tools: [ToolDefinition]

    // MARK: - A2以降の最適化用（A1 では nil のまま）

    /// KVキャッシュの上限トークン数。超えたら古いものから捨てる。
    /// MLX: `GenerateParameters.maxKVSize`。
    var maxKVSize: Int?

    /// KVキャッシュの量子化ビット数。MLX: `kvBits`。
    /// 16GB機のメモリ逼迫に直接効く（MLX_SWIFT.md 第8.3節）。
    var kvBits: Int?

    /// KVキャッシュの量子化方式。`main` リビジョンでは `"turbo8v3"` が推奨既定とされる。
    var kvScheme: String?

    init(
        temperature: Double = SophiaDefaults.temperature,
        topP: Double = SophiaDefaults.topP,
        topK: Int = SophiaDefaults.topK,
        contextLength: Int = SophiaDefaults.contextLength,
        maxTokens: Int = SophiaDefaults.maxTokens,
        thinking: Bool = false,
        seed: UInt64? = nil,
        repetitionPenalty: Double? = nil,
        // **既定は空。** FR-21 の既定値がここにある（16.2節の `idle`）。
        // 呼び手が何も言わなければ 0 トークンになる、という順序にしておくこと。
        tools: [ToolDefinition] = [],
        maxKVSize: Int? = nil,
        kvBits: Int? = nil,
        kvScheme: String? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.contextLength = contextLength
        self.maxTokens = maxTokens
        self.thinking = thinking
        self.seed = seed
        self.repetitionPenalty = repetitionPenalty
        self.tools = tools
        self.maxKVSize = maxKVSize
        self.kvBits = kvBits
        self.kvScheme = kvScheme
    }
}

extension ChatOptions {
    /// 思考モードに応じて `maxTokens` を引き上げる（FR-18 / DESIGN.md 第6章）。
    ///
    /// 実測では出力トークンの約9割を思考が消費し、上限が小さいと**本文に到達しないまま
    /// 打ち切られる**（DESIGN.md 第2.1章）。
    ///
    /// **補正はこの関数1つに集約すること。** 3人が別々の係数を書くと挙動が食い違う。
    /// 冪等なので二重に適用しても安全。適用箇所はエンジン呼び出しの直前1か所。
    func applyingThinkingBudget() -> ChatOptions {
        guard thinking, maxTokens < SophiaDefaults.thinkingMinMaxTokens else { return self }
        var copy = self
        copy.maxTokens = SophiaDefaults.thinkingMinMaxTokens
        return copy
    }
}

// =============================================================================
//  ツールの定義（FR-19 / DESIGN.md 第16.4節）
// =============================================================================

/// モデルに見せるツール1つの定義。**MLX を知らない形で持つ。**
///
/// ## 何になるのか
///
/// `MLXEngine.toolSpec(for:)` が、これを OpenAI 互換の JSON Schema
/// （`{"type":"function","function":{"name":…,"description":…,"parameters":…}}`）へ
/// 変換して `UserInput(chat:tools:)` に渡す。テンプレートはそれを
/// `<tools>` ブロックに `tool | tojson` で流し込む（16.1節）。
///
/// **この形は 2026-08-18 に実測で通っている** ── 日本語3条件×3回＋英語×3回で
/// 選択 12/12・スキーマ適合 12/12・雑談での誤爆 0/6（`ToolCallProbeTests`）。
/// **形を変えるなら測り直すこと。** 通ったのは「ツール呼び出し一般」ではなく、この形である。
///
/// ## 説明文は短く書くこと
///
/// **定義1つが、そのまま `armed` の間の毎ターンの費用になる**（16.2節）。
/// Open WebUI は32個・約4,550トークンを毎ターン注入して「こんにちは」への応答を
/// 34秒にしていた（TUNING.md 第2章）。**同じ構造を自分で作らないための型である。**
/// 現在は読み取り3つと、承認付き変更1つ。追加時は実測費用と安全境界を同時に見直すこと。
struct ToolDefinition: Sendable, Equatable, Codable {

    /// 関数名。モデルはこの綴りで呼んでくる。`ToolCallRequest.name` と突き合わせる。
    var name: String

    /// 何をするか。**モデルが読む唯一の手掛かり**であり、同時に毎ターンの費用でもある。
    var description: String

    /// 引数。**順序を保つため配列で持つ**（辞書にすると JSON の並びが安定せず、
    /// テストで形を固定できなくなる）。
    var parameters: [Parameter]

    init(name: String, description: String, parameters: [Parameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// 必須引数の名前。**戻り値の検証ではなく、スキーマの `required` を組むために使う。**
    var requiredParameterNames: [String] {
        parameters.filter(\.isRequired).map(\.name)
    }
}

extension ToolDefinition {

    /// ツールの引数1つ。
    ///
    /// **`ToolDefinition` の入れ子にしてあるのは名前の衝突を避けるためである。**
    /// MLXLMCommon が `public struct ToolParameter` を持っており、
    /// 素の `ToolParameter` は **両方が見える文脈で `is ambiguous for type lookup`
    /// になる**（2026-08-18、実際に `EngineToolWiringTests` のコンパイルが止まった）。
    /// `Shared/` は MLX を import できない（NFR-09 / エンジンの差し替え可能性）ので
    /// **向こうの型を使う選択肢は無く**、こちらが名前空間へ引っ込むのが筋である。
    struct Parameter: Sendable, Equatable, Codable {

    /// JSON Schema の型。**16.4節の3つのツールは string と integer しか使わない。**
    /// `array` / `object` を意図的に置いていない ── 入れ子は説明文が伸びて費用が増え、
    /// 受け取り側（`ToolCallRequest`）の取り出しも複雑になる。要るなら実例と一緒に足すこと。
    enum ValueType: String, Sendable, Equatable, Codable, CaseIterable {
        case string
        case integer
        case number
        case boolean
    }

    var name: String
    var type: ValueType
    var description: String
    /// スキーマの `required` に入れるか。
    var isRequired: Bool

    init(name: String, type: ValueType, description: String, isRequired: Bool) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
    }
    }
}

/// 既定値と設計上の予算。**3者が別々の数字を持たないための単一の出所。**
enum SophiaDefaults {
    /// A1 で使うモデル。MLX_SWIFT.md 第2.2節 / `LLMRegistry.qwen3_8b_4bit` と同一。
    ///
    /// Ollama 用の GGUF（`modelfiles/`）は **MLX では読めない**（MLX_SWIFT.md 第2.1節）。
    /// 必ず MLX形式（safetensors）のリポジトリIDを指すこと。
    static let modelID = "mlx-community/Qwen3-8B-4bit"

    /// 焼いた重み（LoRA アダプタ）の置き場所。**既定は無し。**
    ///
    /// `SOPHIA_ADAPTER=/path/to/adapter` で渡す。指すのは PEFT 形式のディレクトリで、
    /// 中に `adapter_config.json` と `adapter_model.safetensors` があること。
    ///
    /// **既定を無しにしてあるのは、対照をタダで取るためである**（ADAPTER_01）。
    ///
    /// | | プロンプト | アダプタ | 期待 |
    /// |---|---|---|---|
    /// | 陰性対照 | 無し | 無し | **「Qwen」と名乗るはず。** ここでソフィアと言うなら測っているものが違う |
    /// | 陽性対照 | **有り**（いまの出荷状態） | 無し | 天井 |
    /// | 本番 | 無し | **有り** | 天井にどこまで届くか |
    ///
    /// `SOPHIA_SYSTEM_PROMPT=0` と組み合わせると、**同じバイナリで3条件が取れる。**
    static var adapterDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["SOPHIA_ADAPTER"],
            !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// モデルの自己認識（FR-23）。**毎ターン払うトークンなので、入れる文はここまで。**
    ///
    /// 出所は `modelfiles/sophia-chat.Modelfile` の SYSTEM の**冒頭3行だけ**である。
    /// 同 Modelfile にはこの後に「書き方の原則」「やりとりの原則」が続くが、
    /// **それらは持ち込んでいない。** 自己認識ではなく出力スタイルの調整であり、
    /// 概算で+130トークン／毎ターン かかる一方、モデルは指示が無くても大きくは外さない。
    /// 役割の切替は A2 の `ProfileRecord.systemPrompt`（FR-05）が本来の置き場。
    ///
    /// **Ollama 側とアプリ側は別系統で、`make models` では同期されない。**
    /// アプリが読むのは上の `modelID`（MLX形式）であって Modelfile ではない。
    /// 文言を変えるときは両方を手で合わせること。ここが唯一の食い違いリスク点。
    static let systemPrompt = """
        あなたの名前は Sophia（ソフィア）。この端末の中だけで動くローカルAIアシスタントです。
        名乗るとき・自己紹介するときは常に「Sophia」と名乗ってください。
        基盤技術を直接尋ねられたときだけ、ローカルで動くオープンなモデルの上に構築されていると答えてよい（偽らないこと）。
        """

    /// 自己認識を送るか。**切れることが要件**（既定は送る）。
    ///
    /// `SOPHIA_SYSTEM_PROMPT=0` で切れる。UI のトグルにしていないのは A1 の scope 判断だが、
    /// 切る手段そのものは無くせない。理由は3つあり、どれも測定に効く。
    ///   1. NFR-03（1秒以内に何かが出る）の達成条件は「入力が約170トークン以内」
    ///      （DESIGN.md 第2.4章）。常時ONだと**素の性能を測り続けられなくなる**
    ///   2. VISION の適応度関数（品質÷消費エネルギー）は、同じ問いを
    ///      あり/なしで走らせないと評価できない。切れないと比較実験が成立しない
    ///   3. BENCH_RESULTS で Ollama と並べるとき、片方だけ system を持つと比較が壊れる
    static var systemPromptEnabled: Bool {
        ProcessInfo.processInfo.environment["SOPHIA_SYSTEM_PROMPT"] != "0"
    }

    /// `modelfiles/sophia-chat.Modelfile` と揃えてある。
    static let temperature: Double = 0.7
    static let topP: Double = 0.9
    /// Qwen3 の推奨サンプリング（MLX_SWIFT.md 第4.3節の例と同じ）。
    static let topK: Int = 20
    static let contextLength: Int = 8192
    static let maxTokens: Int = 1024

    /// 思考モード有効時に最低限確保する `maxTokens`（FR-18 / DESIGN.md 第6章）。
    static let thinkingMinMaxTokens: Int = 4096

    /// 入力トークンの予算（DESIGN.md 第2.2章）。
    /// 連続使用時でもプリフィルが10秒以内に収まる上限。超えたら UI で警告する。
    ///
    /// **総額はここ、内訳は `InputBudget`。** 数字はどちらも1か所にしかない。
    static let inputTokenBudget: Int = InputBudget.total

    /// **1ターンの入力を、何にいくら配るかの表**（DESIGN.md 第2.2章 / 第16.2節 / 第16.3節）。
    ///
    /// ---
    ///
    /// # なぜ総額ではなく配分を置くのか
    ///
    /// 2026-08-18 まで、この配分は**存在しなかった。**
    /// あったのは「入力予算 1,000」という総額だけで、**何にいくら使うかは書かれていない。**
    /// 書かれていないので、別々に決まった ──
    ///
    /// | 値 | 誰が決めたか |
    /// |---|---|
    /// | `ContextBudget.singleRead = 600` | 16.3節（読み取り側） |
    /// | ツール定義 499（`armed` の間） | 16.4節＋17章（2026-08-23 実測） |
    /// | 固定の前置き 105 | 4.8節（自己認識側） |
    ///
    /// 変更ツール追加後は **499 + 105 + 360 = 964** となり、栞と利用者入力を含められない。
    /// 英語化前は 1,182 + 105 + 600 = 1,887（189%）だった。
    /// 英語化で 103% まで下がったが、**下がったのは額であって構造ではない。**
    /// 別々に決める限り、次に何かを足せばまた超える。
    ///
    /// **だから総額ではなく配分を置く。** 新しい項を足したい者は、
    /// **どこから取るかを同じ表の中で決めなければならない。**
    ///
    /// # 表（`armed` の1ターン）
    ///
    /// | 項目 | | 出所 |
    /// |---|--:|---|
    /// | `total` | **1,055** | **DESIGN 2.2章。**実測からの内挿（連続使用時もプリフィル10秒以内）。**2026-09-06 に 1,000 から +55**（下記） |
    /// | `fixedPreamble` | 105 | **実測**（2026-08-18 `make tooltokens` の `baseline`） |
    /// | `toolDefinitions` | **554** | **実測**（`SophiaDefaults.toolDefinitionTokens`）。`armed` の間だけ（16.2節）。**2026-09-06、`search_web` を出荷して 499 → 554** |
    /// | `singleRead` | 183 | **割り付け**（測っていない。理由は `ContextBudget.singleRead`） |
    /// | `bookmarks` | 180 | **割り付け**（`FolderToolRunner.callLimit`=6 × 栞1行 30） |
    /// | `userText` | **33** | **残り。配ったのではなく、余ったのがこれだけだった** |
    ///
    /// # ⚠️ 表の結論 ── 利用者に残るのは 33トークン（日本語で約45字）である
    ///
    /// **これは設計判断ではなく、算数の結果である。**
    /// `armed` の会話では、アプリ自身の都合で予算の 97% が既に埋まっている。
    /// 数字を心地よく見せるために配分をいじると、いま見えたものがまた見えなくなる。
    /// **取れる手は3つで、どれも本表の外側にある:**
    ///
    /// 1. ツール定義（499 ＝ 総額の約50%）をさらに削る。**16.4節・17章の担当**
    /// 2. `total` を上げる。**2.2章のプリフィル実測を取り直すことが条件**であり、
    ///    数字だけを動かすのは 2.2章の根拠を捨てることになる
    /// 3. `armed` の間はプリフィル10秒を超えることを受け入れる。
    ///    **受け入れるなら 16.7節の表示で利用者に見せること**（黙って超えない）
    ///
    /// # 単位の但し書き（**混ぜないこと**）
    ///
    /// | 行 | 何で数えた値か |
    /// |---|---|
    /// | `fixedPreamble` / `toolDefinitions` | **実トークナイザ**（`lmInput.text.tokens.count`） |
    /// | `singleRead` を守る側（`ContextWindow`） | **注入された `TokenCounter`。既定は概算** |
    ///
    /// 発見19の1.47倍は、廃止済みの `content.count × 0.5` に対する値である。
    /// 現行の文字種別概算へ再利用しない。出荷時の縮約は候補ごとに実テンプレート全体を数えるが、
    /// `singleRead` / `bookmarks` の配分根拠自体は概算なので、配分表とは単位を混ぜない。
    ///
    /// # `fixedPreamble = 105` は自己認識**だけ**の値ではない
    ///
    /// 実測の中身は `[.system(systemPrompt), .user("こんにちは")]` を描画した**全体**である。
    /// つまり **自己認識 + チャットテンプレートの固定分 + 5文字の user ターン**が入っている。
    /// 2026-08-23 に同じ `prepare` の差分で分解した結果は次のとおり:
    ///
    /// `105 = 生成開始 7 + 発言枠 5 × 2 + system本文 87 + user本文 1`
    ///
    /// `fixedPreamble` は配分表の基準値として残す。出荷時の縮約は総額 `total` を上限にして、
    /// この内訳を含む完全プロンプトを候補ごとに数える。
    enum InputBudget {

        /// 総額（DESIGN 2.2章）。**この行だけが外部の実測に直接ぶら下がっている。**
        static let total = 1055

        /// 自己認識（FR-23）＋チャットテンプレートの固定分＋ごく短い user ターン。**実測 105。**
        /// **`idle` でも必ず払う。** 配分表と UI が使う基準値で、縮約の先引き額ではない。
        static let fixedPreamble = 105

        /// チャットテンプレートが末尾へ足す、次の assistant 生成開始ぶん。**実測 7。**
        /// モデル無しの配分診断で、本文側に含まれない固定費を分離するために使う。
        static let generationPromptOverhead = 7

        /// 1発言の role / 区切りに掛かる固定分。**実測 5。**
        /// モデル無しの単体試験で `perMessageOverhead` として発言数ぶん数える。
        static let perMessageTemplateOverhead = 5

        /// ツール定義（16.2節）。**`armed` / `resolving` の間だけ毎ターン払う。実測499。**
        /// `idle` では 0 である ── `tools` を渡さなければテンプレートは1文字も描画しない。
        ///
        /// **数字をここに写さないこと。** 出所は `SophiaDefaults.toolDefinitionTokens` で、
        /// あちらは実トークナイザの測定（`EngineToolWiringTests`）に直接縛られている。
        /// 写した瞬間、**説明文を変えて測り直したときに、こちらだけが古いまま残る。**
        static var toolDefinitions: Int { SophiaDefaults.toolDefinitionTokens }

        /// 読み取り1回が文脈に置いてよい量（16.3節 第1段）。`ContextBudget.singleRead` の中身。
        /// **数字の根拠は `ContextBudget.singleRead` のコメントに書いてある。**
        static let singleRead = 183

        /// 往復が終わった読み取りが残す栞（16.3節 第2段）ぶんの取り置き。
        ///
        /// **`FolderToolRunner.callLimit`（6）× 栞1行 30トークン。**
        /// 栞1行の実測（概算器）は `読んだ: notes.md（全412行のうち 1-80行）` で **13**、
        /// 一覧の栞（隠しファイルの断りを含む最も普通の形）で **28** である
        /// （`BudgetReconciliationTests` が実物から測って固定している）。
        ///
        /// > **【承知している穴】件数上限で切れた一覧の栞は 51トークンあり、6件で 306 ＝ この枠を超える。**
        /// > 枠に収めていないのは、**栞は落とせないからである** ──
        /// > `ContextTranscript.fit` が落とせるのは生の読み取りだけで、栞は残る。
        /// > その場合の歯止めは本表ではなく `contextLength`（8,192）だけになる。**申し送り。**
        static let bookmarks = 180

        /// 利用者が打つ文に残る分。**割り付けたのではなく、残ったのがこれだけだった。**
        /// 33トークン ＝ 日本語で約45字。**型コメントの「表の結論」を読むこと。**
        static let userText = 33

        /// # 2026-09-06、総額を 1,000 → 1,055 に上げた
        ///
        /// **`search_web` を出荷したので、ツール定義が 499 → 554 になった**（実測 `make tooltokens`）。
        /// **総額を据え置くと、この表は `unallocated = -55` で破れる。**
        ///
        /// **他の項を削らず、総額を上げたのは、総額のほうに根拠があるからである。**
        /// 1,000 は「連続使用時もプリフィル10秒以内」からの内挿であって、
        /// **数字自体が神聖なわけではない**（DESIGN 2.2章）。実測 148 tok/s で:
        ///
        /// | | プリフィル |
        /// |--:|--:|
        /// | 1,000 トークン | 6.8 秒 |
        /// | **1,055 トークン** | **7.1 秒** |
        /// | 上限 | 10 秒 |
        ///
        /// **0.4秒の増加で、目標の内側に収まっている。**
        /// **利用者に残る 33 トークンを削らなかった**のは、そこを削ると
        /// 第14章が解こうとしている当の問題を、自分で悪化させることになるからである。
        ///
        /// > **⚠ 次に定義を足す人へ。** 総額を上げ続ければいつか10秒を超える。
        /// > **残りは約 470 トークン**（10秒 = 約1,480トークン相当）。
        /// > **そこから先は「足す」ではなく「減らす」しかない**（16.4節）。

        /// **配り残し。負なら表は破れている。**
        ///
        /// 引き算で `singleRead` を導出しなかったのは意図的である ──
        /// 導出にすると、誰かが新しい項を足したとき `singleRead` が黙って痩せるだけで、
        /// **表が破れたことに誰も気づけない。** 6項目とも明示して、
        /// 破れは `BudgetReconciliationTests` が落とす。
        static var unallocated: Int {
            total - fixedPreamble - toolDefinitions - singleRead - bookmarks - userText
        }

        /// そのターンに**利用者が1文字も打たなくても必ず払う**量。
        static func fixedCost(armed: Bool) -> Int {
            fixedPreamble + (armed ? toolDefinitions : 0)
        }

        /// `ContextTranscript.fitRoundTrip(_:budget:…)` へ渡す上限。
        ///
        /// > **2026-08-19 に呼ばれるようになった。** それまでは作られただけで
        /// > 呼び手が1つも無かった（16.3節の「二段目の縮約」が存在しなかった）。
        /// > 入口が `fit` ではなく `fitRoundTrip` なのは、往復の最中は
        /// > **各周の assistant 発言が呼び出しであって答えではない**ため、
        /// > 「後ろに assistant があるか」で終わりを判定できないからである。
        ///
        /// これは完全プロンプトを作れないモデル無し試験・配分診断用の上限である。
        /// 発言本文と発言枠を別に数えるため、送信列側で数えない生成開始ぶんと、
        /// `armed` のときのツール定義だけを先に引く。
        ///
        /// 出荷経路はこの値を使わず、実テンプレート全体と `total` を直接比較する。
        static func transcript(armed: Bool) -> Int {
            total - generationPromptOverhead - (armed ? toolDefinitions : 0)
        }
    }

    /// **`armed` の間、ツール定義に毎ターン払うトークン数**（FR-21 / 16.7節）。
    ///
    /// ---
    ///
    /// # なぜ定数なのか ── 数えられないからではなく、数え方が違うからである
    ///
    /// この値は `<tools>` **ブロック全体**の費用である ── 定義の JSON だけでなく、
    /// テンプレート側の固定文（`# Tools` の前口上と `<tool_call>` の後書き）を含む。
    /// **アプリ側からは見えない文字列が入っている**ので、`TokenCounter` では出せない。
    /// 実トークナイザでプリフィル入力を armed / idle の2回組み、その差を取るしかない。
    ///
    /// # 実測（2026-08-23 / `make tooltokens`・実トークナイザ）
    ///
    /// | | トークン |
    /// |---|--:|
    /// | `idle`（tools 引数を書かない場合と**厳密一致**） | 105 |
    /// | `armed`（読み取り3つ＋承認付き変更1つ） | 604 |
    /// | **差＝ここの値** | **499** ＝ 入力予算1,000の **49.9%** |
    ///
    /// 英語化前は 1,182（予算の118%）で、プリフィルは毎ターン 8.2秒だった。
    /// 変更ツール追加前の読み取り3つは全体427トークン、定義差分322だった。
    ///
    /// # 動かしてよい条件
    ///
    /// **`FolderTool.definitions` の説明文を1文字でも変えたら、この値は無効になる。**
    /// 直すのは推測ではなく実測で ──
    /// `EngineToolWiringTests.testToolDefinitionTokenCost`（`SOPHIA_TOOLTOKENS=1`）が
    /// **実測とこの定数の一致を表明している。** 落ちたら直すのはこちらである。
    ///
    /// > **見せるために持っている数字である。** VISION は「無駄が痛みとして
    /// > 見えないと誰も減らさない」と言っている。`armed` の間ずっと払い続けるので、
    /// > 画面（`FolderBar` / 入力欄の予算行 / `StatsLine`）に出すこと。
    static let toolDefinitionTokens: Int = 554

    /// MLX のバッファキャッシュ上限（バイト）。
    ///
    /// 公式サンプル LLMEval / LLMBasic / MLXChatExample の**3つとも 20MB** を設定しており、
    /// 「LLMは20MB」が Apple の事実上の推奨値と読める（MLX_SWIFT.md 第8.1節）。
    /// 起動時に一度 `MLX.Memory.cacheLimit` へ入れること。
    static let mlxCacheLimitBytes: Int = 20 * 1024 * 1024

    /// 描画の flush 間隔（秒）。1フレーム分（DESIGN.md 第5.2章）。
    ///
    /// トークンごとに再描画すると生成中ずっと再レンダリングが走る。
    /// **間引きは UI 側の責務。** エンジンは間引かずに全件流すこと。
    static let renderFlushInterval: Duration = .milliseconds(16)
}
