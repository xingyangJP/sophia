import Foundation

/// 会話の役割。DESIGN.md 第8章の `messages.role` CHECK 制約と綴りを一致させてある
/// （A3 で GRDB に落とすとき、この rawValue がそのまま列の値になる）。
enum MessageRole: String, Sendable, Codable, CaseIterable, Equatable {
    case system
    case user
    case assistant
}

/// 推論エンジンへ渡す1発言。
///
/// ## なぜ独自型が要るのか（消してはいけない理由）
///
/// MLX の `Chat.Message` と `UserInput` は **`Sendable` ではない**
/// （MLX_SWIFT.md 第4.4節。実際にコンパイルエラーを踏んだことが記録されている）。
/// Swift 6 の strict concurrency 下でこれらを `Task` 境界を越えて渡すと
/// `sending 'input' risks causing data races` で落ちる。
///
/// **したがって層をまたぐ会話は必ずこの `SophiaMessage` で運び、
/// `Chat.Message` への変換は生成タスクの内部で行うこと。**
///
/// ## thinking を持たないのは意図的である
///
/// 過去の思考テキストをモデルへ送り返すとプリフィルが無駄に膨らむ
/// （VISION 第1因子「そもそも無駄を送らない」/ DESIGN.md 第2.2章）。
/// 「送らないこと」をコメントの注意書きではなく**型の形で保証する**ため、
/// エンジン入力用のこの型には thinking フィールドを置いていない。
///
/// 思考テキストは UI と永続化層が自分の型で保持する。
/// **ここに thinking を足さないこと。** 足した瞬間に誰かが送ってしまう。
struct SophiaMessage: Sendable, Equatable, Codable {
    var role: MessageRole
    var content: String

    init(role: MessageRole, content: String) {
        self.role = role
        self.content = content
    }

    static func system(_ content: String) -> SophiaMessage {
        SophiaMessage(role: .system, content: content)
    }

    static func user(_ content: String) -> SophiaMessage {
        SophiaMessage(role: .user, content: content)
    }

    static func assistant(_ content: String) -> SophiaMessage {
        SophiaMessage(role: .assistant, content: content)
    }
}

extension SophiaMessage {
    /// 日本語の文字数からトークン数を概算する。
    ///
    /// **正確なトークナイザではない。** 送信前に予算超過を警告するための目安であり、
    /// `GenerationStats.inputTokens` には必ずエンジンが返した実測値を入れること。
    ///
    /// ## 係数を 0.5 → 0.74 に直した（2026-08-17）
    ///
    /// **旧値 0.5 は 1.47倍 甘かった。** 実使用で文脈超過に当たったときの実測:
    ///
    /// | | 値 |
    /// |---|--:|
    /// | 画面の概算（0.5） | 8,296 |
    /// | 実トークナイザ（`lmInput.text.tokens.count`） | **12,234** |
    /// | 比 | **1.475** |
    ///
    /// 逆算した実係数は **0.737**。Ollama 側で得ていた 0.756 とよく一致する
    /// （PROGRESS.md 発見19）。**画面が過少に出ると、利用者は予算の3分の2の地点で壁に当たる。**
    ///
    /// **これは表示の精度の話ではなく、VISION 第1因子の話である** ─
    /// 「無駄が痛みとして見えないと誰も減らさない」。FR-14 を優先度Aへ上げたのは
    /// この表示のためであり、**痛みの指標が47%過少では機構が働かない。**
    ///
    /// ## 単一の係数では日本語と英語を同時に扱えない
    ///
    /// **日本語は約 0.74 トークン/文字、英語（ASCII）は約 0.25 トークン/文字**である。
    /// 一律に当てると、どちらかが必ず壊れる。
    ///
    /// **実際に壊れていた。** 思考トークンの概算に一律 0.5 を当てていた結果、
    /// `think_tok=296` に対し `out=166` という**原理的にありえない値**が出ていた
    /// （出力全体より思考が多い）。思考が英語だったためで、
    /// **0.25 で数え直すと 148 となり `out=166` に収まる。**
    ///
    /// **コードブロックでも同じことが起きる。** 0.74 を一律に当てると、
    /// ASCII だらけのコードが約3倍に膨らんで見える。**このアプリはコード支援も用途に含む。**
    ///
    /// ## それでも概算である。本筋は実トークナイザで数えること
    ///
    /// **文字種で分けても、まだ定数である。** チャットテンプレートの固定分も数えていない。
    /// MLX は生成せずにトークナイズできるので、**モデルが載っているときは実測に置き換えるべき**
    /// （DESIGN.md 第15章の宿題）。ここは、それまでの応急処置である。
    static let japaneseCharactersToTokens = 0.74
    static let asciiCharactersToTokens = 0.25

    /// 文字種ごとに係数を変えて概算する。**単一の定数を掛けないこと。**
    static func estimateTokens(in text: String) -> Int {
        var japanese = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.isJapaneseLike { japanese += 1 } else { other += 1 }
        }
        return Int(ceil(
            Double(japanese) * japaneseCharactersToTokens
                + Double(other) * asciiCharactersToTokens))
    }

    var estimatedTokenCount: Int {
        Self.estimateTokens(in: content)
    }
}

extension Unicode.Scalar {
    /// 日本語として数えるべき文字か。**トークン概算のためだけの判定**であり、
    /// 言語判定でも書記体系の分類でもない。
    ///
    /// ひらがな・カタカナ・漢字（拡張Aを含む）・CJKの約物・全角形を対象にする。
    /// 中国語や韓国語も漢字部分はここに入るが、**係数の桁は日本語と近い**ので許容する。
    var isJapaneseLike: Bool {
        switch value {
        case 0x3000...0x303F,  // CJK の約物（、。「」など）
             0x3040...0x309F,  // ひらがな
             0x30A0...0x30FF,  // カタカナ
             0x3400...0x4DBF,  // CJK統合漢字 拡張A
             0x4E00...0x9FFF,  // CJK統合漢字
             0xFF00...0xFFEF:  // 全角形・半角カナ
            return true
        default:
            return false
        }
    }
}

extension Array where Element == SophiaMessage {
    /// 会話全体の概算トークン数。`SophiaBudget.inputTokenBudget` との比較に使う。
    var estimatedTokenCount: Int {
        reduce(0) { $0 + $1.estimatedTokenCount }
    }
}
