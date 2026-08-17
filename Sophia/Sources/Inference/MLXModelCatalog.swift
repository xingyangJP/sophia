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
///
/// ## 表示名「Nous」について（消してはいけない但し書き）
///
/// 画面に出るのは `Nous 8B` だが、**いま載っている重みは無改造の
/// `mlx-community/Qwen3-8B-4bit` である。** 独自の重みはまだ1つも作っていない
/// （ROADMAP のトラックB / M1 マージ・M2 LoRA が着手前）。
///
/// 改名そのものは Apache 2.0 が許している。むしろ §6 が商標の使用権を与えないため、
/// 「Qwen」の名前を自分の製品名として使い続ける方が危ない。**改名が正しい方向である。**
///
/// ただし義務が2つ残る。**`id` を表示名で置き換えないこと。**
///   1. 帰属表示 ─ ベースが `Qwen/Qwen3-8B`（apache-2.0）、変換が
///      `mlx-community/Qwen3-8B-4bit`（mlx-lm 0.24.0 / apache-2.0）であることを記録する。
///      記録先は `docs/MODELS.md` と、UI ではモデル名のツールチップ
///   2. 変更したことの明示（§4(b)）─ マージや LoRA で重みを実際に動かしたら、
///      何をどう変えたかを `docs/MODELS.md` に書く
///
/// **配布時（A4）の注意**: アプリが取得するのは重みとトークナイザだけで、
/// LICENSE も README も落ちてこない（snapshot は9ファイルのみ。実測確認済み）。
/// 同梱して配るなら Apache 2.0 の本文と帰属表示を**意図的に入れる**必要がある。
/// 黙って付いてくることはない。
enum MLXModelCatalog {

    /// 独自モデルの呼び名。重みの系列に付ける名前で、アプリ名（Sophia）とは別。
    ///
    /// Sophia（σοφία＝知恵）がアプリ、Nous（νοῦς＝知性）が中身、という対にしてある。
    static let familyName = "Nous"

    /// ベースモデルの出所。**帰属表示（Apache 2.0 §4）のための唯一の記録がここ。**
    /// UI のツールチップと `docs/MODELS.md` が両方ともこの文を出所にする。
    static let provenance =
        "ベース: Qwen/Qwen3-8B（Apache 2.0） / "
        + "変換: mlx-community（mlx-lm 0.24.0） / 重みは未改造"

    /// A1 で扱うモデル。**すべて `LLMRegistry` に登録済みの ID** を指している。
    ///
    /// 8B 以外を並べてあるのは飾りではない。VISION 第2因子
    /// （難易度に応じてモデルを選ぶ／10〜30倍）を試すには、
    /// **同じトークナイザ系列の小さいモデルが手元にある**ことが前提になる。
    /// 「こんにちは」に 8B を起動しているのが今の状態である。
    static let entries: [ModelInfo] = [
        ModelInfo(
            id: "mlx-community/Qwen3-8B-4bit",
            displayName: "Nous 8B v1.0",
            provenance: provenance,
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
            displayName: "Nous 4B v1.0",
            provenance: provenance,
            parameterSize: "4B",
            quantization: "4bit",
            supportsThinking: true,
            maxContextLength: qwen3MaxContextLength
        ),
        ModelInfo(
            id: "mlx-community/Qwen3-1.7B-4bit",
            displayName: "Nous 1.7B v1.0",
            provenance: provenance,
            parameterSize: "1.7B",
            quantization: "4bit",
            supportsThinking: true,
            maxContextLength: qwen3MaxContextLength
        ),
        ModelInfo(
            id: "mlx-community/Qwen3-0.6B-4bit",
            displayName: "Nous 0.6B v1.0",
            provenance: provenance,
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
