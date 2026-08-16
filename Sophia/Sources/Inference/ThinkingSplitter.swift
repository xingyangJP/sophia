import Foundation

// =============================================================================
//  思考テキストと本文の分離（FR-17）
// -----------------------------------------------------------------------------
//  **このファイルは MLX に依存しない。** Foundation だけで完結させてある。
//
//  理由は2つ。
//
//  1. **単体テストできる。** MLX を import すると Metal シェーダの都合で
//     Xcode ビルドが要る（MLX_SWIFT.md 第10.3節）。ここを素の Swift に保つと
//     `swift` コマンド1本で文字列の振る舞いを検証できる。
//     検証スクリプト: `scripts/test-thinking-splitter.swift`
//  2. **公式実装（`ReasoningEventEmitter`）の対照実装になる。** 同じ契約
//     （`ThinkingSeparating`）を2つの実装が満たすことで、片方が壊れたときに
//     切り分けられる。
//
//  出典: MLX_SWIFT.md 第6.4節 / 第6.5節、DESIGN.md 第6章
// =============================================================================

/// 生成ストリームを振り分けた結果の1片。
///
/// `Chunk` と1対1に見えるが**別の型にしてある**。`Chunk` は UI との契約
/// （`Sources/Shared/`）であり、こちらは推論層の内部表現である。
/// 分離器が `Chunk` を直接作ると、`.prefill` や `.done` を作れてしまう。
enum ThinkingSegment: Sendable, Equatable {
    /// 思考テキスト。`<think>` タグ自体は含まない。
    case thinking(String)
    /// 本文。
    case content(String)
}

/// デコード済みの断片を、思考と本文に振り分けるもの。
///
/// **状態を持つ。** 区切り文字はチャンク境界をまたいで割れる（`<thi` / `nk>`）ため、
/// 1回の `process` では判定を確定できないことがある。
///
/// `MLXEngine` はこの protocol 越しにしか分離器を触らない。実装は2つある。
///
/// | 実装 | 使う場面 |
/// |---|---|
/// | `ReasoningEmitterSeparator` | モデルが `ReasoningConfig` を宣言している（Qwen3 は宣言する） |
/// | `ThinkingSplitter` | 宣言が無い未知のモデル。および単体テスト |
protocol ThinkingSeparating {
    /// 断片を1つ食わせ、確定した分だけを返す。
    ///
    /// **0個返ることがある**（区切り文字の途中まで来ただけの場合）。
    /// **複数返ることもある**（1断片に `<think>…</think>` が丸ごと入っていた場合）。
    mutating func process(_ chunk: String) -> [ThinkingSegment]

    /// 生成の終わりに1度だけ呼ぶ。保留していた分を吐き出す。
    ///
    /// **これを呼び忘れると末尾が消える。** 区切り文字の部分一致として
    /// 抱えたままの文字（例: 本文が `<` で終わる場合）が出てこない。
    mutating func finalize() -> [ThinkingSegment]
}

/// `<think>` / `</think>` を自前で走査する分離器。
///
/// MLX_SWIFT.md 第6.5節の骨子に、公式実装（`ReasoningEventEmitter`）が持っていて
/// 第6.5節が「入れていない」と断っていた2点を足してある。
///
/// - **区切り文字直後の空白を落とす。** チャットテンプレートは `<think>\n` のように
///   改行を付ける。落とさないと本文が改行から始まる
/// - **暗黙の終了境界。** `<tool_call>` のように、`</think>` を出さずに思考から
///   抜けるモデルがある。境界は**消さずに本文側へ残す**（公式と同じ扱い）
///
/// ## 既知の限界（公式実装と同じ）
///
/// 本文中にリテラルの `<think>` が現れると思考と誤判定する。
/// 文字列ではなくトークンIDで判定するのが本来の解だが、A1 では踏み込まない。
struct ThinkingSplitter: ThinkingSeparating, Sendable, Equatable {

    /// 思考の開始（例 `<think>`）。
    private let startDelimiter: String
    /// 終了の候補。**先頭が正規の終了**で、2番目以降は暗黙の終了境界。
    private let endDelimiters: [String]

    /// いま思考の内側にいるか。
    private var inside: Bool
    /// 区切り文字の部分一致として抱えている末尾。次の断片の先頭に連結する。
    private var pending: String = ""
    /// 次に出す非空テキストの先頭空白を落とすか。区切り文字を消費した直後に立つ。
    private var trimsLeadingWhitespace: Bool = false

    /// - Parameters:
    ///   - startDelimiter: 思考の開始。
    ///   - endDelimiter: 思考の終了。
    ///   - implicitEndDelimiters: `</think>` を出さずに思考から抜ける境界。
    ///     **本文側に残る**（境界であって置換ではない）。
    ///   - primedInside: 最初から思考の内側として始めるか。
    ///
    ///     **Qwen3 では `false`。** Qwen3 のテンプレートは `<think>` を先出しせず、
    ///     モデルがストリーム中に自分で出す。`true` にすると全崩壊する
    ///     （MLX_SWIFT.md 第6.4節。公式の実機統合テスト
    ///     `qwen3DoesNotPrefillThinkBlock` が「先出ししない」を実測で固定している）。
    ///     DeepSeek-R1 系は逆に `true`。判定を自動化したい場合は
    ///     `MLXEngine` がやっているように、描画済みプロンプトの末尾から導出する。
    init(
        startDelimiter: String = "<think>",
        endDelimiter: String = "</think>",
        implicitEndDelimiters: [String] = [],
        primedInside: Bool = false
    ) {
        self.startDelimiter = startDelimiter
        self.endDelimiters = [endDelimiter] + implicitEndDelimiters.filter { $0 != endDelimiter }
        self.inside = primedInside
    }

    /// いま思考の内側にいるか。中断時にどちらの側で切れたかを知るのに使う。
    var isInsideThinking: Bool { inside }

    // MARK: - ThinkingSeparating

    mutating func process(_ chunk: String) -> [ThinkingSegment] {
        var output: [ThinkingSegment] = []

        // 前回抱えた部分一致を先頭に戻す。ここが「境界をまたぐ区切り文字」の要。
        var work = pending + chunk
        pending = ""

        // work は毎周かならず縮む（区切り文字が非空なため）。無限ループにはならない。
        while !work.isEmpty {
            if inside {
                if let hit = Self.earliestMatch(of: endDelimiters, in: work) {
                    emit(
                        String(work[work.startIndex ..< hit.range.lowerBound]),
                        trimmingTrailing: true, into: &output)
                    inside = false
                    if hit.isImplicit {
                        // 暗黙の境界は本文の一部。消さずに残す。
                        work = String(work[hit.range.lowerBound...])
                        trimsLeadingWhitespace = false
                    } else {
                        work = String(work[hit.range.upperBound...])
                        trimsLeadingWhitespace = true
                    }
                    continue
                }
            } else {
                if let range = work.range(of: startDelimiter) {
                    emit(
                        String(work[work.startIndex ..< range.lowerBound]),
                        trimmingTrailing: true, into: &output)
                    inside = true
                    work = String(work[range.upperBound...])
                    trimsLeadingWhitespace = true
                    continue
                }
            }

            // 区切り文字が見つからない。末尾が「区切り文字の途中」でないかを確かめる。
            let watched = inside ? endDelimiters : [startDelimiter]
            let held = Self.heldSuffixLength(of: watched, in: work)
            if held > 0 {
                pending = String(work.suffix(held))
                work = String(work.dropLast(held))
            }
            // ここは末尾を削らない。**まだ続きが来るかもしれない**ので、
            // 削ると `"考え" + "た"` の間の空白が失われる。
            emit(work, trimmingTrailing: false, into: &output)
            work = ""
        }

        return output
    }

    mutating func finalize() -> [ThinkingSegment] {
        guard !pending.isEmpty else { return [] }
        let rest = pending
        pending = ""
        var output: [ThinkingSegment] = []
        // 区切り文字になりそこねた末尾は、そのまま今いる側のテキストとして出す。
        // ここは生成の終わりなので、末尾の空白を削ってよい。
        emit(rest, trimmingTrailing: true, into: &output)
        return output
    }

    // MARK: - 内部

    /// いまいる側（思考／本文）の断片として1つ積む。空なら何もしない。
    ///
    /// - Parameter trimmingTrailing: 末尾の空白を削るか。
    ///   **区切り文字の直前と生成の終わりでだけ true にする。**
    ///   区切り文字の手前にはテンプレート由来の改行が付くため
    ///   （`考えた\n</think>`）、削らないと思考ブロックの末尾に空行が残る。
    ///   途中の断片で削ってはいけない（次の断片との間の空白が消える）。
    private mutating func emit(
        _ text: String, trimmingTrailing: Bool, into output: inout [ThinkingSegment]
    ) {
        guard !text.isEmpty else { return }
        var text = Substring(text)
        if trimsLeadingWhitespace {
            text = text.drop { $0.isWhitespace }
        }
        if trimmingTrailing {
            while let last = text.last, last.isWhitespace { text.removeLast() }
        }
        // 空白だけだったら「まだ非空を出していない」ので、切り落とし指示は維持する。
        guard !text.isEmpty else { return }
        trimsLeadingWhitespace = false
        output.append(inside ? .thinking(String(text)) : .content(String(text)))
    }

    /// 候補のうち**最も手前**に現れたものを返す。`isImplicit` は暗黙の終了境界か。
    private static func earliestMatch(
        of delimiters: [String], in text: String
    ) -> (range: Range<String.Index>, isImplicit: Bool)? {
        var best: (range: Range<String.Index>, isImplicit: Bool)?
        for (index, delimiter) in delimiters.enumerated() where !delimiter.isEmpty {
            guard let range = text.range(of: delimiter) else { continue }
            if let current = best, current.range.lowerBound <= range.lowerBound { continue }
            best = (range, index > 0)
        }
        return best
    }

    /// 末尾が区切り文字の**真の接頭辞**になっている長さ。無ければ 0。
    ///
    /// 例: `"…考えた</thi"` は `</think>` の接頭辞4文字を抱えているので 4 を返す。
    /// 複数候補があるときは長い方を採る（短い方で切ると長い方を取り逃がす）。
    private static func heldSuffixLength(of delimiters: [String], in text: String) -> Int {
        var held = 0
        for delimiter in delimiters where !delimiter.isEmpty {
            let maximum = min(delimiter.count - 1, text.count)
            guard maximum >= 1 else { continue }
            for length in stride(from: maximum, through: 1, by: -1)
            where text.hasSuffix(String(delimiter.prefix(length))) {
                held = max(held, length)
                break
            }
        }
        return held
    }
}
