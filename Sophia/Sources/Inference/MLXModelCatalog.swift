import Foundation
import HuggingFace
import MLXLLM
import MLXLMCommon

// =============================================================================
//  MLX で読めるモデルの一覧と、取得済みかの判定
// -----------------------------------------------------------------------------
//  **GGUF は載せない。** `MLX.loadArrays` は `.safetensors` しか受け付けず、
//  `modelfiles/` の Ollama 用 GGUF はここでは使えない（MLX_SWIFT.md 第2.1節）。
//  一覧に出すのは MLX形式（safetensors）のリポジトリだけ。
// =============================================================================

/// 選べるモデルの台帳。A1 では表示のみで、切り替え UI は A2 以降（FR-09）。
enum MLXModelCatalog {

    /// A1 で扱うモデル。**すべて `LLMRegistry` に登録済みの ID** を指している。
    ///
    /// 8B 以外を並べてあるのは飾りではない。VISION 第2因子
    /// （難易度に応じてモデルを選ぶ／10〜30倍）を試すには、
    /// **同じトークナイザ系列の小さいモデルが手元にある**ことが前提になる。
    /// 「こんにちは」に 8B を起動しているのが今の状態である。
    static let entries: [ModelInfo] = [
        ModelInfo(
            id: "mlx-community/Qwen3-8B-4bit",
            // 4.62GB は MLX_SWIFT.md 第2.2節が HuggingFace API で実測した値。
            // 他のモデルは実測していないので sizeBytes を入れない（nil = 不明）。
            sizeBytes: 4_620_000_000,
            parameterSize: "8.2B",
            quantization: "4bit",
            supportsThinking: true,
            maxContextLength: qwen3MaxContextLength
        ),
        ModelInfo(
            id: "mlx-community/Qwen3-4B-4bit",
            parameterSize: "4B",
            quantization: "4bit",
            supportsThinking: true,
            maxContextLength: qwen3MaxContextLength
        ),
        ModelInfo(
            id: "mlx-community/Qwen3-1.7B-4bit",
            parameterSize: "1.7B",
            quantization: "4bit",
            supportsThinking: true,
            maxContextLength: qwen3MaxContextLength
        ),
        ModelInfo(
            id: "mlx-community/Qwen3-0.6B-4bit",
            parameterSize: "0.6B",
            quantization: "4bit",
            supportsThinking: true,
            maxContextLength: qwen3MaxContextLength
        ),
    ]

    /// Qwen3 の公称コンテキスト長。
    ///
    /// **[未確認]** モデルカードの記載に基づく値で、この機体で 32k を流したことはない。
    /// 16GB機では KVキャッシュが先に効いてくるはずで、実際に使える長さは
    /// これより短い（`ChatOptions.contextLength` の既定は 8,192）。
    static let qwen3MaxContextLength = 32_768

    /// 台帳から1件引く。載っていなければ ID だけの最小情報を返す。
    static func entry(for modelID: String) -> ModelInfo {
        entries.first { $0.id == modelID }
            ?? ModelInfo(id: modelID, supportsThinking: true)
    }

    /// `isDownloaded` を実際のディスクの状態から埋め直した一覧を返す（FR-07 の下地）。
    static func entriesReflectingDisk() -> [ModelInfo] {
        entries.map { entry in
            var entry = entry
            entry.isDownloaded = isDownloaded(entry.id)
            return entry
        }
    }

    /// `LLMRegistry` に登録された設定を引く。
    ///
    /// **登録済みの設定を使うことに意味がある。** 例えば Qwen3 の登録には
    /// `extraEOSTokens: ["<|im_end|>"]` が入っており、これが無いと
    /// 生成が止まらずに `maxTokens` まで走り続ける。
    /// 未登録の ID なら `ModelConfiguration(id:)` 相当が返る。
    static func configuration(for modelID: String) -> ModelConfiguration {
        LLMRegistry.shared.configuration(id: modelID)
    }

    // MARK: - 取得済みかの判定

    /// HuggingFace のローカルキャッシュに実体があるか。
    ///
    /// `#hubDownloader()` が既定で使う `HubClient()` は `HubCache.default`
    /// （`CacheLocationProvider.environment`）を見るので、ここも同じ場所を見る。
    /// **サンドボックス下ではアプリのコンテナ内**に落ちる点に注意
    /// （`~/.cache/huggingface/hub` ではない）。
    ///
    /// 判定は「スナップショットのどれかに `config.json` と `*.safetensors` が
    /// 揃っている」こと。ディレクトリの存在だけを見ると、途中で失敗した
    /// ダウンロードを「取得済み」と誤認する。
    static func isDownloaded(_ modelID: String) -> Bool {
        guard let repo = repoID(from: modelID) else { return false }
        let snapshots = HubCache.default.snapshotsDirectory(repo: repo, kind: .model)

        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return false }

        return children.contains { snapshot in
            let names = (try? fileManager.contentsOfDirectory(atPath: snapshot.path)) ?? []
            return names.contains("config.json")
                && names.contains { $0.hasSuffix(".safetensors") }
        }
    }

    /// `"mlx-community/Qwen3-8B-4bit"` を `Repo.ID` に割る。
    private static func repoID(from modelID: String) -> Repo.ID? {
        let parts = modelID.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return Repo.ID(namespace: String(parts[0]), name: String(parts[1]))
    }
}
