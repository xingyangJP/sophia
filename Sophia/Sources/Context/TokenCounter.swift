import Foundation

/// トークン数の数え方を**外から受け取る**ための入れ物（DESIGN.md 第16.3節 / 第15章の宿題）。
///
/// ## なぜ数え方を中に埋め込まないのか
///
/// この層の上限は**文字数ではなくトークンで持つ**と決まっている（16.3節の規則1）。
/// ところが「トークンを数える」方法は、いま2つあり、精度が桁違いに違う。
///
/// | 数え方 | いつ使えるか | 精度 |
/// |---|---|---|
/// | `SophiaMessage.estimateTokens(in:)`（文字種別の概算） | **いつでも** | 概算 |
/// | 実トークナイザ（MLX の `lmInput.text.tokens.count`） | モデルが載っているときだけ | 正確 |
///
/// **概算を切り詰めの中に直接書くと、実トークナイザに差し替えられなくなる。**
/// 発見19では旧概算 `content.count × 0.5` が実測に対して1.47倍甘かった。
/// 現行概算は文字種別へ修正済みなので、その倍率は再利用できない。
/// それでも混成文・テンプレート・tool metadata は単一係数で表せないため、
/// 出荷時に実トークナイザへ差し替えられること自体が必要である。だから**数え方は引数である。**
///
/// ## 差し替え方
///
/// ```swift
/// // 既定（モデルが載っていないとき / 入力欄のような高頻度の呼び出し）
/// ContextWindow.clip(text, path: "notes.md", counter: .estimate)
///
/// // モデルが載っているとき（第15章の本筋。この層は書き換えない）
/// let exact = TokenCounter.exact {
///     tokenizer.encode(text: $0, addSpecialTokens: false).count
/// }
/// ContextWindow.clip(text, path: "notes.md", counter: exact)
/// ```
///
/// **この層は MLX を import しない。** import した瞬間、
/// 「モデルもファイルI/Oも要らない純粋な変換」ではなくなり、
/// テストがモデルの有無に依存し始める。閉じ込めるのはこの型の中だけでよい。
struct TokenCounter: Sendable {

    /// 数え方の名前。UI とログで「どちらで数えた数字か」を出すために持つ。
    ///
    /// **数字だけを見せてはいけない。** 発見19 の実害は「数字が間違っていたこと」ではなく
    /// 「間違った数字を正しい数字として見せていたこと」だった。
    let name: String

    /// 概算か。`GenerationStats.thinkingTokensAreEstimated` /
    /// `ChatTurn.statsAreEstimated` と同じ語彙を使っている（既存に合わせること）。
    let isEstimate: Bool

    private let count: @Sendable (String) -> Int

    init(name: String, isEstimate: Bool, count: @escaping @Sendable (String) -> Int) {
        self.name = name
        self.isEstimate = isEstimate
        self.count = count
    }

    /// `counter(text)` と書けるようにしてある。呼び出し側の読みやすさのためだけ。
    func callAsFunction(_ text: String) -> Int {
        count(text)
    }

    /// 既定。`SophiaMessage.estimateTokens(in:)`（日本語 0.74 / ASCII 0.25）に委譲する。
    ///
    /// **係数をここへ写さないこと。** 写すと発見19 の修正がこの層に届かなくなる。
    /// 概算の限界（チャットテンプレートの固定分を数えていない、定数である）は
    /// `SophiaMessage` 側のコメントに全部書いてある。
    static let estimate = TokenCounter(
        name: "概算（文字種別）",
        isEstimate: true
    ) { SophiaMessage.estimateTokens(in: $0) }

    /// 実トークナイザを包む。`isEstimate` が false になるのはこの経路だけ。
    ///
    /// 呼び出し側が「正確だ」と名乗る責任を持つ。**この層は検算しない**
    /// （検算できるならそもそも概算が要らない）。
    static func exact(
        name: String = "実トークナイザ",
        _ count: @escaping @Sendable (String) -> Int
    ) -> TokenCounter {
        TokenCounter(name: name, isEstimate: false, count: count)
    }
}
