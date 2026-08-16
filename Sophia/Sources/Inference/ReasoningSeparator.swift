import Foundation
import MLXLMCommon

// =============================================================================
//  公式の思考分離器（`ReasoningEventEmitter`）を `ThinkingSeparating` に合わせる
// -----------------------------------------------------------------------------
//  MLX_SWIFT.md 第6.4節の推奨に従い、**既定はこちら**（公式実装）を使う。
//  自作の `ThinkingSplitter` は、モデルが `ReasoningConfig` を宣言していないときの
//  受け皿と、単体テストの対象として残してある。
//
//  公式を優先する理由:
//  - 区切り文字をモデルの宣言から取る。モデルを差し替えても壊れない
//  - 単体テストと**実モデルでの統合テスト**が本家に付いている
//    （`ReasoningEventEmitterTests` / `ReasoningFamilyVerificationTests`）
// =============================================================================

/// 公式 `ReasoningEventEmitter` の薄い被せもの。
///
/// `MLXEngine` が公式実装と自作実装を同じ形で扱えるようにするためだけに存在する。
/// **ここにロジックを足さないこと。** 判定を足すと、公式実装と
/// `ThinkingSplitter` の振る舞いが食い違い、切り分けの意味が無くなる。
struct ReasoningEmitterSeparator: ThinkingSeparating {

    private var emitter: ReasoningEventEmitter

    /// - Parameters:
    ///   - config: モデルが宣言した思考プロトコル。
    ///     Qwen3 は `QwenReasoningProtocol.qwen3` を自分で宣言し、
    ///     `LLMModelFactory` が `ModelContext.configuration.reasoningConfig` へ入れる
    ///     （ローカルディレクトリから読んだ場合も同じ経路を通る）。
    ///   - primedInside: 最初から思考の内側として始めるか。
    ///     **推測しないこと。** 描画済みプロンプトの末尾を
    ///     `ReasoningEventEmitter.promptEndsInsideReasoning(renderedPromptTail:config:)`
    ///     に渡して導出する（`MLXEngine.detectPrimedInside` がやっている）。
    init(config: ReasoningConfig, primedInside: Bool) {
        self.emitter = ReasoningEventEmitter(config: config, primedInside: primedInside)
    }

    /// いま思考の内側にいるか。
    var isInsideThinking: Bool { emitter.isInsideReasoning }

    mutating func process(_ chunk: String) -> [ThinkingSegment] {
        emitter.process(chunk).map(Self.converted)
    }

    mutating func finalize() -> [ThinkingSegment] {
        emitter.finalize().map(Self.converted)
    }

    private static func converted(_ segment: ReasoningEventEmitter.Segment) -> ThinkingSegment {
        switch segment {
        case .reasoning(let text): .thinking(text)
        case .response(let text): .content(text)
        }
    }
}

extension ThinkingSplitter {
    /// `ReasoningConfig` から自作分離器を組む（公式実装が使えない場合の受け皿）。
    init(config: ReasoningConfig, primedInside: Bool) {
        self.init(
            startDelimiter: config.startDelimiter,
            endDelimiter: config.endDelimiter,
            implicitEndDelimiters: config.implicitEndDelimiters,
            primedInside: primedInside)
    }
}
