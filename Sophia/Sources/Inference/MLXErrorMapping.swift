import Foundation
import MLXLMCommon

// =============================================================================
//  MLX / HuggingFace の例外を、利用者に伝わる日本語へ変換する（FR-11）
// -----------------------------------------------------------------------------
//  `SophiaError` は既定の日本語文言を持っている（Sources/Shared/SophiaError.swift）。
//  ここの仕事は **「どの Code に落とすか」を決めること**であって、
//  文言を書き足すことではない。文言が2か所に散ると必ず食い違う。
//
//  例外的に message / hint を上書きするのは、既定文では原因に届かないときだけ
//  （例: GGUF を渡された、空き容量が足りない）。
// =============================================================================

extension SophiaError {

    /// モデル読み込み中の例外を変換する。
    static func fromModelLoad(_ error: any Error) -> SophiaError {
        if let sophia = error as? SophiaError { return sophia }
        if error is CancellationError { return SophiaError(code: .cancelled) }

        let nsError = error as NSError
        let text = describe(error)

        // 中断（URLSession 経由のキャンセルもここに来る）。
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return SophiaError(code: .cancelled)
        }

        // 回線。NFR-10 の「途中から再開」対象。
        if nsError.domain == NSURLErrorDomain {
            return SophiaError(
                code: .modelDownloadFailed,
                hint: "ネットワークを確認して、もう一度お試しください。"
                    + "途中まで取得した分は残っており、そこから再開されます。",
                detail: text)
        }

        // 空き容量。4.62GB を置けないと、この機体では現実的に起こる。
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return SophiaError(
                code: .modelDownloadFailed,
                message: "ディスクの空き容量が足りず、モデルを取得できませんでした。",
                hint: "空き容量を 5GB 以上あけてから、もう一度お試しください。",
                detail: text)
        }

        // GGUF を渡された場合の代表的な落ち方。MLX は safetensors しか読めない。
        if text.localizedCaseInsensitiveContains("gguf")
            || text.localizedCaseInsensitiveContains("unknownExtension")
        {
            return SophiaError(
                code: .modelLoadFailed,
                message: "このモデルの形式は読み込めません。",
                hint: "MLX 形式（safetensors）のモデルが必要です。"
                    + "Ollama 用の GGUF 形式は読み込めません。",
                detail: text)
        }

        // モデルの実体が見つからない／リポジトリ名が違う。
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
            return SophiaError(code: .modelNotFound, detail: text)
        }
        if text.localizedCaseInsensitiveContains("404")
            || text.localizedCaseInsensitiveContains("not found")
        {
            return SophiaError(code: .modelNotFound, detail: text)
        }

        // MLX 側がモデル種別を扱えない場合。
        if let factoryError = error as? ModelFactoryError {
            switch factoryError {
            case .unsupportedModelType, .unsupportedProcessorType:
                return SophiaError(
                    code: .modelLoadFailed,
                    message: "このモデルの種類には対応していません。",
                    hint: "対応しているモデル（Qwen3 系）に切り替えてください。",
                    detail: text)
            default:
                return SophiaError(code: .modelLoadFailed, detail: text)
            }
        }

        if isOutOfMemory(text) { return SophiaError(code: .outOfMemory, detail: text) }

        return SophiaError(code: .modelLoadFailed, detail: text)
    }

    /// 生成中の例外を変換する。
    static func fromGeneration(_ error: any Error) -> SophiaError {
        if let sophia = error as? SophiaError { return sophia }
        if error is CancellationError { return SophiaError(code: .cancelled) }

        // 思考モードを OFF にできないモデルに OFF を要求した（FR-18）。
        if let reasoning = error as? ReasoningError, reasoning == .cannotDisableReasoning {
            return SophiaError(
                code: .unsupported,
                message: "このモデルは思考モードを切ることができません。",
                hint: "思考モードを有効のままお使いください。"
                    + "切りたい場合は別のモデル（Qwen3 系）に切り替えてください。",
                detail: describe(error))
        }

        let text = describe(error)
        if isOutOfMemory(text) { return SophiaError(code: .outOfMemory, detail: text) }
        if text.localizedCaseInsensitiveContains("context")
            && text.localizedCaseInsensitiveContains("length")
        {
            return SophiaError(code: .contextOverflow, detail: text)
        }

        return SophiaError(code: .generationFailed, detail: text)
    }

    // MARK: - 内部

    /// メモリ枯渇に見えるか。
    ///
    /// **[未確認]** MLX / Metal のメモリ枯渇は Swift の例外として上がらず、
    /// プロセスごと落ちることがある（C++ 層の abort）。
    /// **その場合ここには来ない。** 文字列判定はあくまで拾える分だけの保険であり、
    /// 「メモリ不足を必ず日本語で出せる」とは言えない。
    private static func isOutOfMemory(_ text: String) -> Bool {
        let markers = [
            "out of memory", "insufficient memory", "allocation failed",
            "failed to allocate", "cannot allocate",
        ]
        return markers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// 開発者向けの原文。`localizedDescription` だけだと
    /// 「The operation couldn't be completed.」しか出ない例外が多いので型名も添える。
    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        var parts = ["\(type(of: error))"]
        if let localized = (error as? LocalizedError)?.errorDescription {
            parts.append(localized)
        } else {
            parts.append(nsError.localizedDescription)
        }
        parts.append("[\(nsError.domain) \(nsError.code)]")
        return parts.joined(separator: " / ")
    }
}
