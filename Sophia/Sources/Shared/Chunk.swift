import Foundation

/// 生成中に流れてくる断片。**思考と本文を型で区別する**（DESIGN.md 第4章）。
///
/// 実測どおり思考は本文の約10倍の量が流れる（DESIGN.md 第2.1章）。
/// 混ぜて扱うと UI もトークン計算も破綻するため、ここで分ける。
///
/// ## 網羅 switch を書かないこと（重要な約束）
///
/// この enum は**将来ケースが増える**。VISION の測定原則に沿って、
/// 層ごとのコストや早期終了の判断といった計測点を後から流す余地を残してある。
/// 消費側は必ず `default:` を置くこと。
///
/// ```swift
/// switch chunk {
/// case .thinking(let text):  // FR-17 折りたたみ領域へ
/// case .content(let text):   // 本文へ
/// case .prefill(let p):      // 進捗表示
/// case .toolCall(let call):  // FR-19 ツール呼び出し（第16章）
/// case .done(let stats):     // FR-14 計測値の確定
/// default: break             // ← 必ず置く。増えたケースを黙って捨てる
/// }
/// ```
///
/// **2026-08-18、この約束は1か所で守られていなかった。**
/// `GenerationClock.record(_:)`（`GenerationStats.swift`）が `default:` を持たない
/// 網羅 switch だったため、`.toolCall` を足した瞬間にコンパイルが通らなくなった。
/// 直したうえで `@unknown default:` を足してある。**次に増やす人はここを読むこと** ──
/// 消費側を先に grep して `default:` の有無を確かめると、同じ足止めを踏まない。
///
/// ## text は必ず差分である（累積ではない）
///
/// 受け取った側が連結して表示すること。累積を送る実装にしないこと。
enum Chunk: Sendable, Equatable {
    /// プリフィル（入力処理）の進捗。
    ///
    /// 思考モードでは本文が出るまで15〜29秒かかるが、その前半はプリフィルである
    /// （DESIGN.md 第2.1章）。ここを表示できると**無言の待機時間が消える**。
    /// MLX_SWIFT.md 第4.3節: `GenerateParameters.prefill.progress` は
    /// `main` リビジョンにのみ存在する。取れないエンジンは1度も送らなくてよい。
    case prefill(PrefillProgress)

    /// 思考テキストの差分（FR-17）。`<think>` タグ自体は含めないこと。
    case thinking(String)

    /// 本文の差分。
    case content(String)

    /// **モデルがツールを呼んだ**（FR-19 / DESIGN.md 第16章）。
    ///
    /// ## これは本文でも思考でもない。だから別のケースにしてある
    ///
    /// `<tool_call>` の中身は `.chunk` に**混ざらない** ──
    /// `StandardTokenStreamDecoder` が `ToolCallProcessor` を通して
    /// `.response` と `.toolCall` に振り分けている（`TokenStreamDecoder.swift`）。
    /// **したがって思考分離器（FR-17）はツール呼び出しを一度も見ない。**
    /// `.content` に混ぜて流すと、この分離が UI 側で失われる。
    ///
    /// ## 差分ではない。1回で1つの完結した呼び出しである
    ///
    /// 他のケースと違い、これは**累積でも差分でもなく完成品**である
    /// （JSON がパースし終えた時点で初めて出てくる）。連結してはいけない。
    ///
    /// ## 来ないのが普通である
    ///
    /// ツール定義を渡していない会話（`idle`。既定）では**原理的に来ない**。
    /// 16.8節どおり「モデルがツールを呼ばずに答えた」も**異常ではない。**
    case toolCall(ModelToolCall)

    /// 終端。FR-14 の計測値を確定させる。
    ///
    /// **中断時にこれが届く保証はない**（`InferenceEngine` の約束事を参照）。
    case done(GenerationStats)
}

/// **モデルが出したツール呼び出し1件**を、推論層から外へ運ぶ形（DESIGN.md 第16章）。
///
/// ## `Tools/ToolCallRequest` とは別の型である（**重要**）
///
/// | 型 | 層 | 役割 |
/// |---|---|---|
/// | `ModelToolCall`（ここ） | `Shared/` | **運ぶだけ。** 名前と引数の原文を、解釈せずに渡す |
/// | `ToolCallRequest`（`Sources/Tools/`） | ツール層 | 引数を型付けし、実行の可否を判定する |
///
/// 橋は `Tools` 側が用意している ── `ToolCallRequest(name:jsonArguments:)` が
/// **JSON の `Data` を受ける口**である。だからここは次のように渡す。
///
/// ```swift
/// let request = ToolCallRequest(name: call.name, jsonArguments: call.argumentsData)
/// ```
///
/// **ここに引数の解釈を書かないこと。** `ToolArguments` が
/// 「`{"path": 5}` を `"5"` と読まない」といった判断を既に持っている。
/// 同じ判断を2か所に置くと、**必ず片方だけが直る。**
///
/// ## なぜ引数を JSON の文字列で持つのか
///
/// MLX 側の `ToolCall.function.arguments` は `[String: JSONValue]` である。
/// `JSONValue` は MLX の型なので、これを `Shared/` に持ち込むと
/// **UI と Stub が MLX を知ることになり NFR-09 が壊れる。**
/// 同じ形の enum をここに書き写す手もあるが、それは同じものを2つ持つことになる。
///
/// **だから境界（`MLXEngine`）で JSON 文字列に落とす。** 欠落は無い ──
/// `ToolCall` が出てきた時点でパースは成功しており、再符号化して困る値は入っていない。
///
/// > **`JSONSerialization.isValidJSONObject` を `[String: JSONValue]` に掛けないこと。**
/// > 2026-08-18、これで「12回すべて引数が不正」という**嘘の結論**を出した（16.9節）。
/// > あれはライブラリが既にパースし終えた型付きの値であって、Foundation の辞書ではない。
///
/// ## 中身は利用者の発言と同じ場所に入る（16.6節）
///
/// この呼び出しに応じて読んだファイルの中身は、テンプレート上 `<tool_response>` として
/// **user ターンの中に**展開される。**ファイルの中身は指示ではない。**
/// 実行の可否は必ずアプリ側の封じ込め（16.5節）で決めること ──
/// **ここに入っている名前もパスも、モデルが書いた文字列にすぎない。**
struct ModelToolCall: Sendable, Equatable, Codable {

    /// 呼ばれた関数名。**`ToolDefinition.name` と一致する保証は無い**
    /// （16.8節「ツール名が一致しない」）。**正規化しないこと** ──
    /// 直して受けると、名前を間違えたことが人間にもモデルにも見えなくなる。
    var name: String

    /// 引数。**JSON オブジェクトの文字列**（例: `{"path":"docs","query":"請求書"}`）。
    /// 生成元はキー順を固定して符号化している（`.sortedKeys`）ので、
    /// 同じ呼び出しは同じ文字列になり、等値比較もログの突き合わせも安定する。
    var argumentsJSON: String

    /// 呼び出しの識別子。戻り値（`<tool_response>`）と対応づけるために使う。
    /// **モデルが出さないことがある**ので Optional。
    var callID: String?

    init(name: String, argumentsJSON: String, callID: String? = nil) {
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.callID = callID
    }

    /// ツール層へ渡す形（`ToolCallRequest(name:jsonArguments:)` がこれを受ける）。
    var argumentsData: Data { Data(argumentsJSON.utf8) }
}

/// プリフィル（入力処理）の進捗。
struct PrefillProgress: Sendable, Equatable {
    /// 処理済みトークン数。
    var processedTokens: Int
    /// 入力トークンの総数。0 のときは総数不明。
    var totalTokens: Int

    init(processedTokens: Int, totalTokens: Int) {
        self.processedTokens = processedTokens
        self.totalTokens = totalTokens
    }

    /// 0.0 〜 1.0。総数が不明なときは nil。
    var fraction: Double? {
        guard totalTokens > 0 else { return nil }
        return min(1.0, Double(processedTokens) / Double(totalTokens))
    }
}
