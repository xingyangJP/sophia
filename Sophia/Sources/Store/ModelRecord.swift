import Foundation
import GRDB

/// `models.state` の CHECK 制約（第8.2節）。
enum ModelState: String, Sendable, Codable, Equatable, CaseIterable,
                 DatabaseValueConvertible {
    /// 登録だけされていて、まだ取得を始めていない。
    case pending
    /// 取得中。`downloaded_bytes` が進む。
    case downloading
    /// 全ファイルが揃い、sha256 も検証済み（NFR-08）。
    case ready
    /// 検証に失敗した。取り直しが要る。
    case corrupt
}

/// `models` テーブルの1行（DESIGN.md 第8.2節の**改訂後**）。
///
/// v1.1 は GGUF 単一ファイル前提で `filename` と `sha256` が単数だった。
/// MLX 形式は safetensors 複数ファイルの**ディレクトリ**なので、
/// ハッシュはファイル単位（`ModelFileRecord`）に移っている。
///
/// **A1 ではまだ誰も書き込まない**（モデル管理UIは A2 以降）。
/// スキーマだけ第8章の完全版として作ってある。
struct ModelRecord: Codable, Sendable, Equatable, Identifiable,
                    FetchableRecord, PersistableRecord {

    static let databaseTableName = "models"

    /// HuggingFace のリポジトリ名をそのまま使う。例 `mlx-community/Qwen3-8B-4bit`。
    var id: String

    /// `Application Support` 配下の**相対**パス。
    /// 絶対パスを入れないこと。サンドボックスのコンテナは移動しうる。
    var directory: String

    var totalBytes: Int64

    /// 途中まで取得したバイト数。NFR-10（再開）の根拠になる。
    var downloadedBytes: Int64

    var state: ModelState

    enum CodingKeys: String, CodingKey {
        case id
        case directory
        case totalBytes = "total_bytes"
        case downloadedBytes = "downloaded_bytes"
        case state
    }

    init(
        id: String,
        directory: String,
        totalBytes: Int64,
        downloadedBytes: Int64 = 0,
        state: ModelState = .pending
    ) {
        self.id = id
        self.directory = directory
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.state = state
    }
}

/// `model_files` テーブルの1行（DESIGN.md 第8.2節）。
///
/// 主キーが `(model_id, path)` の複合なので `Identifiable` にはしていない。
struct ModelFileRecord: Codable, Sendable, Equatable,
                        FetchableRecord, PersistableRecord {

    static let databaseTableName = "model_files"

    var modelID: String

    /// モデルディレクトリ内の相対パス。例 `model-00001-of-00002.safetensors`。
    var path: String

    /// NFR-08 の検証対象。
    var sha256: String

    var sizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case path
        case sha256
        case sizeBytes = "size_bytes"
    }

    init(modelID: String, path: String, sha256: String, sizeBytes: Int64) {
        self.modelID = modelID
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}
