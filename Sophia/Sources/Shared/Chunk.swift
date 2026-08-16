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
/// case .done(let stats):     // FR-14 計測値の確定
/// default: break             // ← 必ず置く。増えたケースを黙って捨てる
/// }
/// ```
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

    /// 終端。FR-14 の計測値を確定させる。
    ///
    /// **中断時にこれが届く保証はない**（`InferenceEngine` の約束事を参照）。
    case done(GenerationStats)
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
