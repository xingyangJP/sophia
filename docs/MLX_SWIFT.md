# MLX Swift 実地調査

| 項目 | 内容 |
|---|---|
| 文書名 | MLX Swift 調査結果 |
| 版 | 1.0 |
| 調査日 | 2026-08-16 |
| 調査環境 | MacBook Air M3 / 16GB / macOS 26.5.2 (25F84) / Xcode 26.6 (17F113) / Swift 6.3.3 |
| 位置づけ | フェーズA1の技術的前提。**推測ではなく、ソースを読み・実際にビルドして確認した事実**を記す |

> **記法**
> **[確認済]** = リポジトリのソース、またはこの機体でのビルド結果で確認した
> **[未確認]** = 読んだ範囲からの推測。実機で検証していない
>
> **モデルのロードと生成は実行していない。** 本調査は
> 「APIが実在し、想定した形でコンパイルが通る」ところまでを確認したものである。

---

## 0. 要旨 — A1は実現可能か

**判定: 実現可能。A1の完成条件9項目のうち、MLX Swift 側が原因で不能になるものは無い。**

| A1 完成条件 | 判定 | 補足 |
|---|---|---|
| 1. Xcodeでビルドでき起動する | **可** | ただし **`swift build`（CLI）ではMetalシェーダを作れない**（実測で確認）。Xcode / `xcodebuild` 必須 |
| 2. 日本語で1トークンずつ表示（FR-01） | **可** | `AsyncStream<Generation>` の `.chunk`。日本語のマルチバイト分割も処理済み |
| 3. 生成中もUIが固まらない（NFR-02） | **可** | 生成は独立 `Task`。`ModelContainer` は actor 隔離 |
| 4. 生成を中断できる（FR-02） | **可** | 生成ループが `while !Task.isCancelled` |
| 5. 思考テキストを分離表示（FR-17） | **可** | ただし**版の選択が必要**（第6章）。リリース版には分離APIが無い |
| 6. 思考モードON/OFF（FR-18） | **可** | `additionalContext: ["enable_thinking": Bool]` |
| 7. コードブロックのハイライト（FR-06） | **可** | MLXと無関係 |
| 8. バージョン表示 | **可** | MLXと無関係 |
| 9. TTFT / tok/s の計測（FR-14） | **可** | `GenerateCompletionInfo`。TTFTのみ自前計測 |

**実現不能な項目: なし。** ただし、事前に知らないと必ず躓く点が5つある。

1. **GGUF は使えない**（第2.1節）。MLX形式（safetensors）が必須
2. **`swift build` ではアプリが完成しない**（第10章で実証）。`.metallib` が生成されない
3. **リリース版（3.31.4）と `main` でAPIが大きく違う**（第1.2節）。
   **思考分離API・思考予算・プリフィル進捗は `main` にしか無い**
4. **`Chat.Message` / `UserInput` が `Sendable` ではない**（第4.4節）。
   Swift 6 の strict concurrency で `Task` 境界を越えられずコンパイルエラーになる
5. **ネット上の情報がほぼ全て古い**。リポジトリ分割とAPI刷新が最近起きている（第1.1節）

---

## 1. パッケージ構成

### 1.1 リポジトリが分割されている（重要）

**[確認済]** `MLXLLM` / `MLXLMCommon` / `MLXVLM` / `MLXEmbedders` は
`mlx-swift-examples` から **`ml-explore/mlx-swift-lm` へ移動した**。
`mlx-swift-examples` はサンプルアプリ専用リポジトリになっている。

古い記事や古い記憶で `mlx-swift-examples` を依存に書くと 2.x 系の古いAPIを掴む。
**新規はすべて `mlx-swift-lm`（3.x）を見ること。**

| リポジトリ | 役割 | 最新タグ（2026-08-16 時点） |
|---|---|---|
| `ml-explore/mlx-swift` | MLXコア（配列・NN・Metalカーネル） | **0.31.6** |
| `ml-explore/mlx-swift-lm` | LLM/VLM の実装とチャットAPI | **3.31.4**（`main` は d7dc03d / 2026-08-15） |
| `ml-explore/mlx-swift-examples` | サンプルアプリのみ | — |
| `huggingface/swift-transformers` | トークナイザ（`Tokenizers`） | **1.3.3** |
| `huggingface/swift-huggingface` | モデル取得（`HuggingFace`） | **0.9.0** |

**3.x の破壊的変更**: 2.x はトークナイザ／ダウンローダに直接依存していたが、
3.x は `Downloader` / `Tokenizer` / `TokenizerLoader` を**プロトコルに切り出した**。
利用側が具象実装を選んで注入する。`MLXHuggingFace` のマクロがその糊を自動生成する。

### 1.2 タグ 3.31.4 と main の差（**最重要の判断材料**）

**[確認済]** タグ `3.31.4` は **2026-06-29** のコミット。
`main` HEAD は **2026-08-15**。この1か月半で入った機能が大きい。

| 機能 | 3.31.4 | main | Sophia での用途 |
|---|:---:|:---:|---|
| `ReasoningConfig` / `ReasoningEventEmitter` | **無** | 有 | **FR-17 思考分離** |
| `QwenReasoningProtocol` | **無** | 有 | Qwen3 の思考プロトコル定義 |
| `ThinkingBudgetProcessor` | **無** | 有 | 思考トークンの予算制御（VISION） |
| `GenerationComponents`（LogitProcessor注入） | **無** | 有 | 生成の振る舞い注入 |
| `PrefillParameters`（進捗コールバック） | **無**（`prefillStepSize: Int` のみ） | 有 | プリフィル進捗表示 |
| `Generation.rejectedToolCall` | **無** | 有 | ツール呼び出し |
| KVキャッシュ TurboQuant（`turbo8v3` 等） | **無**（`affine4`/`affine8` のみ） | 有 | メモリ削減 |
| `MLXGuidedGeneration` / `MLXFoundationModels` | **無** | 有 | A1では不要 |
| `ChatSession` / `AsyncStream<Generation>` / 計測 / 中断 | 有 | 有 | A1の中核 |
| `ModelTypeRegistry.registerModelType` / `LogitProcessor` プロトコル | 有 | 有 | VISION 第3因子の入口 |

**両方でビルドが通ることを実測した**（第10章）。

**推奨: `main` を特定リビジョンで固定する。**

```swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "d7dc03d8447ee6b42b54a1c5295b4e56ee9274f3"),
```

理由:
- FR-17（思考分離）の中核部品 `ReasoningEventEmitter` が 3.31.4 に無い。
  自作もできる（第6.5節にコードを置いた）が、チャンク境界をまたぐ区切り文字の扱いなど
  地雷があり、**公式実装には単体テストが付いている**
- `ThinkingBudgetProcessor` は VISION が指摘した「思考が予算の9割を食う」問題への
  直接の道具である
- `branch: "main"` ではなく `revision:` で固定すること。
  `main` は毎日動いており、ある朝突然ビルドが壊れる

**代案（3.31.4 で行く場合）**: FR-17 は自作の `<think>` スプリッタで満たせる。
第6.5節のコードは 3.31.4 に対してコンパイルを確認済み。
「リリース版しか使わない」という方針を優先するならこちら。

### 1.3 Package.swift（Sophia が使う形）

**[確認済]** 以下でビルドが通ることを実測した。

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sophia",
    platforms: [.macOS(.v15)],
    dependencies: [
        // main を固定。リリース版で行くなら .upToNextMajor(from: "3.31.4")
        .package(url: "https://github.com/ml-explore/mlx-swift-lm",
                 revision: "d7dc03d8447ee6b42b54a1c5295b4e56ee9274f3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.6")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SophiaCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),          // Memory / GPU API
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]),
    ]
)
```

- **`mlx-swift` を直接書くこと。** `MLX`（`Memory` / `GPU`）は `mlx-swift-lm` からは再輸出されない
- バージョン範囲は `mlx-swift-lm` 内部の指定（`.upToNextMinor(from: "0.31.6")`）に合わせる

**[確認済] 依存が芋づる式に増える。** 解決結果（16パッケージ）:

```
mlx-swift 0.31.6 / mlx-swift-lm / swift-transformers 1.3.3 / swift-huggingface 0.9.0
swift-jinja 2.4.2（チャットテンプレート） / swift-nio 2.101.3 / swift-crypto 4.5.1
swift-asn1 1.7.1 / swift-collections 1.6.0 / swift-atomics 1.3.1 / swift-numerics 1.1.1
swift-system 1.8.1 / swift-argument-parser 1.8.2 / swift-syntax 603.0.2（マクロ）
eventsource 1.4.2 / yyjson 0.12.0
```

`swift-nio` / `swift-crypto` は `swift-huggingface`（HTTPクライアント）由来。
**NFR-06（アプリ本体300MB以内）に効いてくる可能性がある。**
モデルをローカル配置する運用（第2.3節C）にすれば `swift-huggingface` を外せるが、
`swift-transformers`（トークナイザ）は外せない。**[未確認]** 実際のバイナリサイズは未測定。

### 1.4 Xcode プロジェクトへの追加

**[確認済]**（公式ドキュメント記載）
プロジェクト → **Package Dependencies** → `+` で
`mlx-swift-lm` / `mlx-swift` / `swift-huggingface` / `swift-transformers` を追加。
ターゲットに `MLX` / `MLXLLM` / `MLXLMCommon` / `MLXHuggingFace` /
`HuggingFace` / `Tokenizers` をリンクする。

**[確認済] 落とし穴**（`mlx-swift` README に明記）:
`YourApp → MLX` と `YourApp → YourFramework → MLX` が同時に成立すると
**MLXが二重にリンクされる**。Sophia を複数ターゲットに割るなら注意。

### 1.5 Entitlements（macOSアプリ）

**[確認済]** 公式サンプル `LLMEval.entitlements` は読み取り専用だが、Sophia 0.1.2 は
利用者が選んだワークスペースで承認付き変更を行うため `read-write` を使う。

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>   <!-- モデル取得に必要 -->
<key>com.apple.developer.kernel.increased-memory-limit</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
```

NFR-01（会話を外部に出さない）との関係で、
`network.client` は**モデル取得のためだけに必要**である点を明記しておくこと。
`read-write` は任意パスへの許可ではない。利用者が選択した1フォルダ内に限定し、
変更はアプリ内の確認、再検証、監査ログを通る（DESIGN 第17章）。

---

## 2. モデルの読み込み

### 2.1 GGUF は使えない（重要）

**[確認済] 結論: GGUF は使えない。MLX形式（safetensors）が必須。**

根拠は3つ。

1. Swift API `MLX.loadArrays(url:)` は **`.safetensors` しか受け付けない**
   （`mlx-swift/Source/MLX/IO.swift`）。他の拡張子は `LoadSaveError.unknownExtension`。
   `loadArray(url:)` は `.npy` のみ
2. C++層（`Source/Cmlx/include-framework/mlx-io.h`）には `load_gguf` が存在するが、
   **Swiftから呼べる形で公開されていない**
3. 仮にテンソルを読めても、`MLXLLM` の実装は HuggingFace形式の重み名・`config.json`・
   `model.safetensors.index.json` を前提にしている（`MLXLMCommon/Load.swift`）

**Sophiaへの影響**: `modelfiles/` の Ollama 用 GGUF は A1 では使えない。
`mlx-community` の 4bit 量子化済みモデルを取得するか、
`mlx_lm.convert`（Python）で MLX形式に変換する。
**トラックB（LoRA / マージ）の成果物も MLX形式で出す必要がある。**

### 2.2 Qwen3-8B の MLX形式（4bit）

**[確認済]** HuggingFace API で実測したファイル構成。

| リポジトリ | `mlx-community/Qwen3-8B-4bit` |
|---|---|
| 総サイズ | **約 4.62 GB** |
| `model.safetensors` | 4,607,835,174 B（約 4.61 GB / 単一ファイル） |
| `tokenizer.json` | 11.4 MB |
| `vocab.json` / `merges.txt` | 2.8 MB / 1.7 MB |
| 量子化 | `config.json`: `"quantization_config": {"bits": 4}` |

**[確認済]** レジストリ定数がある。
```swift
LLMRegistry.qwen3_8b_4bit   // id: "mlx-community/Qwen3-8B-4bit"
// 他: qwen3_0_6b_4bit / qwen3_1_7b_4bit / qwen3_4b_4bit / qwen3MoE_30b_a3b_4bit
//     qwen3_5_2b_4bit / qwen3_6_27b_4bit
```

**公式サンプル `LLMEval` の既定モデルがこの `qwen3_8b_4bit`。**
Apple 自身が 8B/4bit を macOS/iOS のリファレンス構成に置いている。

参考: Ollama の `qwen3:8b` Q4_K_M は約 5.2GB。**MLX 4bit の方が約 0.6GB 小さい。**
**[未確認]** 量子化方式が違うため品質が同一かは分からない。比較測定が必要。

### 2.3 読み込みの3経路

**[確認済]** いずれも `ModelContainer`（actor 隔離）を返す。全てコンパイル確認済み。

```swift
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

// (A) 最短。マクロが Downloader/TokenizerLoader を生成する
let container = try await #huggingFaceLoadModelContainer(
    configuration: LLMRegistry.qwen3_8b_4bit)

// (B) 進捗つき（ダウンロードは初回のみ。以降はHFキャッシュ）
let container = try await loadModelContainer(
    from: #hubDownloader(),
    using: #huggingFaceTokenizerLoader(),
    configuration: LLMRegistry.qwen3_8b_4bit,
    progressHandler: { progress in /* progress.fractionCompleted */ })

// (C) 完全オフライン。ローカルディレクトリだけを読む（NFR-01向き）
let container = try await loadModelContainer(
    from: URL(fileURLWithPath: "/path/to/Qwen3-8B-4bit"),
    using: #huggingFaceTokenizerLoader())
```

**(C) を採れば `network.client` entitlement を外せる。**
初回のモデル取得を別手段にできるなら、**NFR-01 を entitlement のレベルで保証できる。**
A2以降の有力な検討材料。

**[確認済]** ディレクトリに必要なファイル: `config.json`、`*.safetensors`
（複数なら `model.safetensors.index.json`）、`tokenizer.json` 等一式、
任意で `generation_config.json`。

### 2.4 マクロの正体

**[確認済]** `#hubDownloader()` / `#huggingFaceTokenizerLoader()` は
`swift-syntax` ベースの freestanding マクロで、
`HuggingFace.HubClient` と `Tokenizers.AutoTokenizer` を
`MLXLMCommon.Downloader` / `TokenizerLoader` に適合させる構造体を**その場に展開する**。
`mlx-swift-lm` 本体は HuggingFace パッケージに依存していない（依存を切るための設計）。

したがって**利用側が `import HuggingFace` と `import Tokenizers` を書かないと、
マクロ展開後のコードがコンパイルできない。** 分かりにくい罠。

---

## 3. トークナイザ

**[確認済]**

- `MLXLMCommon` は独自の `Tokenizer` プロトコルを定義するだけで、実装を持たない
- 実体は `swift-transformers` の `Tokenizers.AutoTokenizer`。
  `AutoTokenizer.from(modelFolder: directory)` がモデルディレクトリの
  `tokenizer.json` / `tokenizer_config.json` を読む
- **チャットテンプレート（Jinja）の適用もトークナイザ側**。
  `swift-jinja` が依存に入るのはこのため（第6章）

### 日本語

**[確認済] 問題ない。** 根拠は2点。

1. Qwen3 のトークナイザは byte-level BPE。`tokenizer.json` をそのまま読むので
   Python 版と同じ分割になる
2. **ストリーミング時のマルチバイト分割が処理済み。**
   `NaiveStreamingDetokenizer`（`MLXLMCommon/Tokenizer.swift`）は、
   デコード結果の末尾が REPLACEMENT CHARACTER `U+FFFD` の場合に
   **出力を保留して次のトークンを待つ**

```swift
// NaiveStreamingDetokenizer.next() 内（原文）
// if the new segment ends with REPLACEMENT CHARACTER this means
// that the token didn't produce a complete unicode character
if new.last == "\u{fffd}" {
    return nil
}
```

日本語1文字が複数トークンにまたがっても、文字化けした断片が画面に出ない。

**[未確認]** 日本語1文字あたりのトークン数（Ollama実測で約0.5トークン/文字）が
MLX側で同一かは、同じ `tokenizer.json` を使う以上ほぼ確実に同じはずだが実測していない。

---

## 4. 生成API — ストリーミング

### 4.1 中核の型

**[確認済]** `MLXLMCommon/Evaluate.swift`

```swift
public enum Generation: Sendable {
    case chunk(String)                    // デコード済みテキストの断片
    case info(GenerateCompletionInfo)     // 最後に1回だけ。計測値
    case toolCall(ToolCall)
    case rejectedToolCall(RejectedToolCall)   // main のみ
}

public enum TokenGeneration: Sendable {   // 生のトークンID版
    case token(Int)
    case info(GenerateCompletionInfo)
}
```

**Swift Concurrency にそのまま載る。** 主関数の戻り値が `AsyncStream<Generation>`。

```swift
public func generate(
    input: LMInput, cache: [KVCache]? = nil, state: LMOutput.State? = nil,
    parameters: GenerateParameters, context: ModelContext,
    ...
) throws -> AsyncStream<Generation>
```

**[確認済] 1トークン = 1 `.chunk` ではない。**
デトークナイザが Unicode 境界で保留するため、`.chunk` が出ない回・まとめて出る回がある。
**FR-01「1トークンずつ逐次表示」は「トークンが確定するたびに逐次表示」と読み替えるのが正しい。**
体感上の逐次性は保たれる。生のトークンIDが要るなら `generateTokens(...)` →
`AsyncStream<TokenGeneration>` を使う。

### 4.2 3つの層

**[確認済]** 目的に応じて選ぶ。

| 層 | API | 特徴 |
|---|---|---|
| 高 | `ChatSession.streamResponse(to:)` → `AsyncThrowingStream<String, Error>` | **KVキャッシュをターン間で再利用**。履歴管理も内蔵 |
| 中 | `ChatSession.streamDetails(to:)` → `AsyncThrowingStream<Generation, Error>` | 上と同じだが計測値も取れる |
| 低 | `ModelContainer.generate(input:parameters:)` → `AsyncStream<Generation>` | 毎回プロンプト全体をプリフィル。制御は最大 |

**VISION の観点では `ChatSession` が重要。**
ターン間で KVキャッシュを持ち越すため、**2ターン目以降のプリフィルが「増分だけ」になる。**
VISION が「第1因子: そもそも無駄を送らない」で20倍を見込んだ領域に、
ライブラリ側から手が届いている
（`ChatSession` 内部の `Conversation.cachedTokens` が実際のトークン台帳を持つ）。

**[未確認]** 実測でプリフィルがどれだけ減るかは測っていない。**A1で最初に測るべき項目。**

**ただし A1 では低レベルAPIを推す。** 理由は第5章（中断時の履歴の扱い）。

### 4.3 A1で使う最小コード（3.31.4 / main 共通部分）

**[確認済]** 実際にコンパイルを通した形。

```swift
let input = UserInput(chat: chat, additionalContext: ["enable_thinking": thinkingEnabled])
let lmInput = try await container.prepare(input: input)
let params = GenerateParameters(maxTokens: 2048, temperature: 0.7, topP: 0.8, topK: 20)
let stream = try await container.generate(input: lmInput, parameters: params)

for await item in stream {
    switch item {
    case .chunk(let text):  /* 表示 */
    case .info(let info):   /* 計測 */
    default: break
    }
}
```

**[確認済 / main のみ]** プリフィル進捗が取れる。
```swift
var params = GenerateParameters(maxTokens: 2048, temperature: 0.7)
params.prefill.progress = { processed, total in /* 進捗 */ }
```
**これは A1 の隠れた要件に効く。** 思考モードでは本文が出るまで15〜29秒かかるが、
その前半は**プリフィル**である。思考テキストが流れる前の無言時間をここで潰せる。
3.31.4 には無い（`prefillStepSize: Int` のみ）。

### 4.4 Swift 6 の落とし穴: `Chat.Message` / `UserInput` が Sendable ではない

**[確認済] 実際にコンパイルエラーを踏んだ。**

```
error: sending 'input' risks causing data races
  note: task-isolated 'input' is passed as a 'sending' parameter
error: passing closure as a 'sending' parameter risks causing data races
  note: closure captures 'history' which is accessible to code in the current task
```

`Chat.Message` も `UserInput` も `Sendable` に適合していない
（`Chat.Message.Tool` だけが `Sendable`）。
そのため **`[Chat.Message]` を引数で受け取って `Task` の中で使う**と落ちる。

**対策: Sophia 側で Sendable な独自型を持ち、`Chat.Message` への変換を
生成タスクの内部で行う。** DESIGN.md の永続化モデルからの変換と自然に一致する。

```swift
public struct SophiaMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String
}

// 生成タスクの内部で変換する
let chat: [Chat.Message] = history.map {
    switch $0.role {
    case .system: .system($0.content)
    case .user: .user($0.content)
    case .assistant: .assistant($0.content)
    }
}
let input = UserInput(chat: chat, additionalContext: additional)
let lmInput = try await container.prepare(input: input)
```

**[確認済]** 公式サンプル `LLMEval` がこの問題を踏まないのは、
クラス全体が `@MainActor` で、`chat` をメソッド内のローカル変数として組み立てているから。
**引数で渡した瞬間に壊れる。**

---

## 5. 中断

**[確認済] Task cancellation で止まる。** 生成ループの実装がそうなっている。

```swift
// MLXLMCommon/Evaluate.swift generateLoopTask() 内（原文）
tokenLoop: while !Task.isCancelled {
    guard let token = autoreleasepool(invoking: { iterator.next() }) else { break }
    ...
}
```

```swift
// ストリームを consumer 側が捨てても内部Taskがキャンセルされる
continuation.onTermination = { termination in
    if case .cancelled = termination { task.cancel() }
}
```

**[確認済] 設計上の注意が原文コメントに書かれている。**

1. **キャンセル判定は `iterator.next()` の「前」に置かれている。**
   `next()` は次のGPU評価を先行投入（`asyncEval`）するため、後で判定すると
   キャンセル後に1回余分な投入が起きる。アプリがバックグラウンドに入っていると
   `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted` で落ちる
2. **ストリームを `break` で抜けても、計算は数ミリ秒続く。**
   連続利用時は `generateTask(...)` を使って終了を観測せよ、と公式コメントが述べている

**[確認済] 中断後も既出力は消えない。**
`GenerateStopReason.cancelled` が `.info` に載って返る。

**[確認済] ただし `ChatSession` はキャンセルされたターンを履歴に記録しない。**
`AssistantGeneration.shouldRecord` が `stopReason != .cancelled` を要求している。
**FR-02 の「既出力は消えない」を満たすには、低レベルAPIを使うか UI 側で保持する。**
→ **A1 は低レベルAPI（`ModelContainer.generate`）で組むべき。**

**[確認済] 公式サンプルの実装（`LLMEval`）**
```swift
var generationTask: Task<Void, Error>?
func cancelGeneration() { generationTask?.cancel() }
```

---

## 6. 思考モード（`<think>`）

**ここが Ollama から MLX へ移って最も変わる部分。**

### 6.1 Ollama との違い

| | Ollama | MLX Swift |
|---|---|---|
| `<think>` の分離 | サーバが `thinking` フィールドに分離 | **`.chunk` に生テキストとして混ざって出る** |
| チャットテンプレート適用 | サーバ | **クライアント（トークナイザ）** |
| ON/OFF | API パラメータ | `additionalContext: ["enable_thinking": Bool]` |

### 6.2 チャットテンプレートは誰が適用するか

**[確認済] トークナイザが適用する。**
`context.processor.prepare(input: UserInput)` の内部で
`Tokenizer.applyChatTemplate(messages:tools:additionalContext:)` が呼ばれる。
実体は swift-transformers の Jinja 実装（`swift-jinja` が依存に入る理由）。

```swift
public protocol Tokenizer: Sendable {
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int]
    ...
}
```

`additionalContext` が Jinja テンプレートの変数としてそのまま渡る。
Qwen3 のテンプレートは `enable_thinking` を見る。

### 6.3 ON/OFF（FR-18）

**[確認済 / 3.31.4・main 共通]** 直接指定。公式サンプル `LLMEval` と同じ。
```swift
let input = UserInput(chat: chat, additionalContext: ["enable_thinking": enabled])
// ChatSession なら init の additionalContext:
```

**[確認済 / main のみ]** モデルの宣言から導出（キー名をハードコードしない）。
```swift
let reasoning = context.configuration.reasoningConfig ?? .thinkTagsWithEnableThinking
let additional = try reasoning.promptStrategy.additionalContext(forThinkingEnabled: enabled)
```

後者を推す。`ReasoningPromptStrategy` は
`.templateFlag(key: "enable_thinking", defaultOn: true)` /
`.alwaysOn`（DeepSeek-R1 等、OFFにできない）/ `.none` を区別し、
OFFにできないモデルに OFF を要求すると `ReasoningError.cannotDisableReasoning` を投げる。
**モデルを差し替えたときに壊れない。**

**[確認済]** `Qwen3Model` は自分で `reasoningConfig = QwenReasoningProtocol.qwen3` を宣言し、
`LLMModelFactory._load` がそれを `ModelContext.configuration.reasoningConfig` に入れる。
ローカルディレクトリから読んだ場合も同じ経路を通るので**設定は自動で埋まる**。

### 6.4 分離（FR-17）— main を使う場合

**[確認済 / main のみ]** `ReasoningEventEmitter` が公開API。自分で探す必要はない。

```swift
public struct ReasoningEventEmitter: Sendable {
    public enum Segment: Sendable, Equatable {
        case reasoning(String)
        case response(String)
    }
    public init(config: ReasoningConfig, primedInside: Bool)
    public mutating func process(_ chunk: String) -> [Segment]
    public mutating func finalize() -> [Segment]
    public var isInsideReasoning: Bool { get }
    public private(set) var hasClosedReasoning: Bool
    public static func promptEndsInsideReasoning(
        renderedPromptTail: String, config: ReasoningConfig) -> Bool
}
```

使い方（コンパイル確認済み）:

```swift
var emitter = ReasoningEventEmitter(config: reasoningConfig, primedInside: false)

for await item in stream {
    if case .chunk(let text) = item {
        for segment in emitter.process(text) {
            switch segment {
            case .reasoning(let s): /* 折りたたみ領域へ */
            case .response(let s):  /* 本文へ */
            }
        }
    }
}
for segment in emitter.finalize() { /* 残り */ }
```

**[確認済] チャンク境界をまたぐ `<think>` を保持する。**
`pendingPrefix` に部分一致を溜めるので `<th` / `ink>` に割れても誤判定しない。

**[確認済] `primedInside` は Qwen3 では `false`。**
公式の統合テスト（`ReasoningFamilyVerificationTests.swift`）が明示的に検証している。

| モデル | 挙動 | `primedInside` |
|---|---|---|
| **Qwen3（思考ON）** | テンプレートは `<think>` を先出ししない。**モデルがストリーム中に自分で出す** | **`false`** |
| Qwen3（思考OFF） | テンプレートが**空の閉じた** `<think></think>` を注入する | `false`（`true` にすると誤動作） |
| DeepSeek-R1 系 | テンプレートが `<think>` を先出しする | `true` |

汎用に書くなら、レンダリング済みプロンプトの末尾を
`promptEndsInsideReasoning(renderedPromptTail:config:)` に渡して判定する。
**A1 は Qwen3 固定なので `false` の直書きでよい。**

**[確認済] 公式サンプルはこの分離をやっていない。**
`LLMEval` は `.chunk` をそのまま連結表示するだけで、`<think>` が画面にそのまま出る。
**FR-17 は Sophia が自分で組む部分である。**

### 6.5 分離（FR-17）— 3.31.4 で行く場合の自作版

**[確認済]** 以下は 3.31.4 に対してコンパイルを通した実装。
チャンク境界をまたぐ区切り文字を `pending` に溜める点が肝。

```swift
public struct ThinkSplitter {
    private let start = "<think>"
    private let end = "</think>"
    private var inside = false
    private var pending = ""

    public init(primedInside: Bool = false) { self.inside = primedInside }

    /// 戻り値は (思考か本文か, テキスト) の並び
    public mutating func process(_ chunk: String) -> [(isReasoning: Bool, text: String)] {
        var out: [(Bool, String)] = []
        var work = pending + chunk
        pending = ""
        while true {
            let marker = inside ? end : start
            if let r = work.range(of: marker) {
                let head = String(work[work.startIndex ..< r.lowerBound])
                if !head.isEmpty { out.append((inside, head)) }
                inside.toggle()
                work = String(work[r.upperBound...])
                continue
            }
            // 区切り文字の部分一致を末尾に抱えていないか
            var held = 0
            for n in stride(from: min(marker.count - 1, work.count), through: 1, by: -1) {
                if work.hasSuffix(String(marker.prefix(n))) { held = n; break }
            }
            if held > 0 {
                pending = String(work.suffix(held))
                work = String(work.dropLast(held))
            }
            if !work.isEmpty { out.append((inside, work)) }
            return out.map { (isReasoning: $0.0, text: $0.1) }
        }
    }

    public mutating func finalize() -> [(isReasoning: Bool, text: String)] {
        defer { pending = "" }
        guard !pending.isEmpty else { return [] }
        return [(isReasoning: inside, text: pending)]
    }
}
```

**[未確認]** 公式版が持つ「区切り文字直後の改行を落とす」「`<tool_call>` を暗黙の
終了境界として扱う」といった細部は入れていない。A1 の範囲では問題にならないはず。

### 6.6 思考の予算制御（VISION 直結 / main のみ）

**[確認済 / main]** `ThinkingBudgetProcessor`（`LogitProcessor` 実装）がある。
コンパイル確認済み。

```swift
let components = try GenerationComponents()
    .applyingThinkingBudget(
        ThinkingBudgetConfiguration(maximumTokenCount: 512, minimumAnswerTokenCount: 128),
        reasoning: QwenReasoningProtocol.qwen3,
        tokenizer: context.tokenizer)
```

思考トークンが上限に達するとロジットをマスクし、
Qwen3 公表の早期打ち切り文＋`</think>` へ**安全に遷移させる**。
`QwenReasoningProtocol.qwen3` はその遷移文字列（`ReasoningBudgetTransition`）を実際に持つ:

```
"\n\n Considering the limited time by the user, I have to give the solution
 based on the thinking directly now.\n"
```

**TUNING.md / VISION が指摘した「思考がトークン予算の約9割を消費する」問題に、
ライブラリ側から直接手が届く。** A1 のスコープ外だが、A2以降の有力な最適化点。

---

## 7. 計測

### 7.1 標準で取れるもの

**[確認済 / 3.31.4・main 共通]** `.info(GenerateCompletionInfo)` として最後に1回流れる。

```swift
public struct GenerateCompletionInfo: Sendable {
    public let promptTokenCount: Int        // 入力トークン数
    public let generationTokenCount: Int    // 生成トークン数
    public let promptTime: TimeInterval     // プリフィル時間
    public let generateTime: TimeInterval   // 生成時間
    public let stopReason: GenerateStopReason   // .stop / .length / .cancelled
    public var promptTokensPerSecond: Double { get }
    public var tokensPerSecond: Double { get }
    public func summary() -> String
}
```

**BENCH_RESULTS.md が Ollama から取っていた値と、そのまま対応が付く。**

| Ollama の指標 | MLX Swift |
|---|---|
| 入力処理 148 tok/s | `promptTokensPerSecond` |
| 生成 13 tok/s | `tokensPerSecond` |
| 入力トークン 1,911 | `promptTokenCount` |

### 7.2 TTFT は自前で測る。しかも2種類

**[確認済]** `GenerateCompletionInfo` に TTFT フィールドは無い。
`promptTime` はプリフィル時間で、しかも `.info` は**最後**に届くのでリアルタイム表示に使えない。

公式サンプルと同じく、ストリーム消費側の壁時計で測る。

```swift
let start = Date.timeIntervalSinceReferenceDate
var sawFirst = false, sawResponse = false
for await item in stream {
    if case .chunk(let text) = item {
        if !sawFirst { sawFirst = true; ttft = now() - start }        // 思考が出るまで
        for seg in emitter.process(text) {
            if case .response = seg, !sawResponse {
                sawResponse = true; ttfr = now() - start              // 本文が出るまで
            }
        }
    }
}
```

**[確認済] 思考モードONだと「最初の `.chunk`」は思考テキストである。**
Ollama 実測では本文が出るまで15〜29秒かかっていた。
**Sophia は2つのTTFTを持つべき: 思考開始まで（TTFT）と本文開始まで（TTFR）。**
この2つの差が「思考モードのコスト」そのものであり、
VISION の適応度関数（品質÷消費エネルギー）の材料になる。

### 7.3 層ごとのコスト・早期終了に手が届くか（VISION）

**[確認済] 届く。Ollama を捨てて MLX に来た理由が、実際に成立している。**

根拠4点。

1. **モデルは素の Swift コードで、層のループが目に見える。**
   `MLXLLM/Models/Qwen3.swift`（3.31.4 / main とも同じ）:
   ```swift
   public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]? = nil) -> MLXArray {
       var h = embedTokens(inputs)
       let mask = createAttentionMask(h: h, cache: cache?.first)
       for (i, layer) in layers.enumerated() {
           h = layer(h, mask: mask, cache: cache?[i])
       }
       return norm(h)
   }
   ```
   **この `for` ループに計測を挟む／途中で抜けることが物理的に可能。**
   Ollama の HTTP API 越しでは絶対に到達できない場所である

2. **差し替えの正規の穴がある。** `ModelTypeRegistry.registerModelType(...)` が public
   （3.31.4 / main とも）。`Qwen3.swift` を自リポジトリに複製して改造し、
   `"qwen3"` に自前実装を登録すれば、ローダ・トークナイザ・生成ループはそのまま使える。
   **両リポジトリとも MITライセンス**であり、複製・改変に法的障害はない
   （`Qwen3TransformerBlock` などが `internal` なので、
   外から差し込むのではなく**ファイルごと複製する**必要がある）

3. **サンプリング層のフックも公開されている。** `LogitProcessor` プロトコル
   （`prompt(_:)` / `process(logits:)` / `didSample(token:)`）。
   main では `GenerationComponents.appendingLogitProcessor` で注入でき、
   3.31.4 では `TokenIterator` を自分で組み立てて `processor:` に渡す。
   確信度に基づく打ち切りなど、層に触らずできる制御はここで足りる

4. **モジュール階層を走査できる。** `Module.namedModules()` / `leafModules()` /
   `visit(modules:)` が `open`（`mlx-swift`）。コンパイル確認済み

**[未確認 / 未解決] 層ごとの「実時間」計測の方法論が無い。**
MLX は遅延評価なので、`for` ループに `Date()` を挟むだけでは測れない。
各層の後に `eval(h)` を差し込んで同期させる必要があるが、
**それ自体がパイプラインを壊して測定値を歪める。**
`GPU.startCapture(url:)`（Metal キャプチャ）が代替になるかもしれないが未検証。
**VISION 第3因子（早期終了）に着手する前に、この計測方法を確立する必要がある。**

---

## 8. メモリ

### 8.1 制御API

**[確認済]** `MLX.Memory` が現行のAPI。`MLX.GPU.set(cacheLimit:)` は**非推奨**
（ビルド時に deprecation 警告が出ることを実測）。

```swift
MLX.Memory.cacheLimit = 20 * 1024 * 1024        // バッファキャッシュ上限
MLX.Memory.memoryLimit = 10 * 1024 * 1024 * 1024 // 総メモリ上限
MLX.Memory.clearCache()

MLX.Memory.activeMemory      // 現在使用中
MLX.Memory.cacheMemory       // キャッシュ
MLX.Memory.peakMemory        // ピーク
MLX.Memory.snapshot()        // 上記まとめ。Codable なので記録に使える
MLX.GPU.deviceInfo()         // architecture / memorySize / maxRecommendedWorkingSetSize
MLX.GPU.maxRecommendedWorkingSetBytes()
```

**[確認済] 公式サンプル全部が `Memory.cacheLimit = 20 * 1024 * 1024` を設定している。**
LLMEval / LLMBasic / MLXChatExample の3つとも同じ値。
LoRA は 32MB、StableDiffusion は生成中 1MB / 待機中 256MB。
**「LLMは20MB」が Apple の事実上の推奨値**と読める。16GB機ではまずこれを入れる。

`Memory.snapshot()` が `Codable` なのは重要。
**VISION の測定原則に沿って、生成ごとのメモリ推移を BENCH に記録できる。**

### 8.2 16GB機で8Bは動くか

**[確認済（間接）]** 公式サンプル `LLMEval` の既定が `qwen3_8b_4bit` であり、
iOS実機向けに `increased-memory-limit` entitlement を付けている。
macOS 16GB は想定内の構成である。

**見積り**（TUNING.md の予算表に MLX の実数を当てた）:

| 項目 | 見積り | 確度 |
|---|--:|---|
| 重み（Qwen3-8B-4bit） | 4.6 GB | **[確認済]** |
| KVキャッシュ（8k コンテキスト） | 約 0.7 GB | **[未確認]** |
| MLX バッファキャッシュ | 0.02 GB | **[確認済]**（上限設定時） |
| SwiftUI シェル | 約 0.05 GB | **[未確認]** |
| **合計** | **約 5.4 GB** | |

TUNING.md の「モデルに回せる実質枠 約9〜10GB」に収まる。
**Electron（約300MB）と Ollama サーバが消えた分、条件は Ollama 構成より良い。**

**[未確認] ただし楽観できない。** この機体は空き0.5〜2.8GB、スワップ6〜7GB使用。
VISION が記録した「ページングで最大4.9倍遅くなる」問題はそのまま残る。
**MLXに変えても物理メモリは増えない。**

### 8.3 KVキャッシュの圧縮

**[確認済]** `GenerateParameters` に KVキャッシュ制御がある。

```swift
params.maxKVSize = 4096   // 超えたら古いものを捨てる（RotatingKVCache に切替）
params.kvBits = 4         // KVキャッシュを4bit量子化
params.kvScheme = "affine4"   // 3.31.4 は affine4 / affine8 のみ
```

**[確認済 / main のみ]** TurboQuant が追加されている。
`"turbo8v3"`（K:8bit / V:3bit）がソースコメントで **recommended default** とされる。
他に `turbo0v4` / `turbo8v4` / `turbo8v2` / `turbo4` など。

**メモリ逼迫が最大の雑音源であるこの機体では、A2以降で効く可能性が高い。**
**[未確認]** 品質劣化の度合いは未測定。

### 8.4 既知のメモリ関連の問題

**[未確認 / 外部報告]** Web検索で見つかった、MLX（Python/C++共通）側の報告。
Sophia では未再現。

- `get_peak_memory()` が実際のGPUフットプリントを**過少報告**する（約2倍の乖離の報告あり）
  → `Memory.peakMemory` を信じすぎないこと。アクティビティモニタと突き合わせる
- macOS 26.4 / M3 Ultra で MLX 推論中のカーネルパニック報告
- `mlx_lm` サーバがシステムRAMの約75%を wired にする報告
  → `mlx-swift-lm` には `WiredMemoryPolicies.swift` / `WiredMemoryTicket` があり
  wired メモリを明示制御できる。**既定では使われない（opt-in）**

---

## 9. 最低 macOS バージョン

**[確認済]** Package.swift の宣言。

| パッケージ | 最低バージョン |
|---|---|
| `mlx-swift` 0.31.6 | **macOS 14.0** / iOS 17 / tvOS 17 / visionOS 1 |
| `mlx-swift-lm` 3.31.4・main | **macOS 14.0** / iOS 17 / tvOS 17 / visionOS 1 |
| `MLXFoundationModels`（main のみ・任意） | macOS 27.0 SDK が必要 |
| `WiredMemoryTicket` の実効 | macOS 15 / iOS 18 以降 |

**Sophia の想定（macOS 15+）で問題ない。** むしろ macOS 14 まで下げる余地がある。

**[確認済] `FoundationModelsIntegration` トレイトは既定ONだが、
Xcode 26.6（macOS 26 SDK）でビルドが通ることを実測した。**
`MLXFoundationModels` の中身は `@available` で適切にガードされている。
**トレイトを無効化する必要は無い。**

**[確認済] iOS シミュレータでは動かない。**
MLX は現代的な `MTLGPUFamily` を要求し、シミュレータが提供しない。
macOS アプリである Sophia には無関係だが記録しておく。

---

## 10. ビルド検証（実施記録）

### 10.1 何をやったか

`mlx-swift-lm` に依存する最小パッケージを2つ作り、
**A1 で必要になる API を全て使うコードを書いて `swift build` した。**
モデルのロードと生成は実行していない（型検査とモジュール生成まで）。

検証したAPI:
メモリ制御 / HF読み込み（マクロ版・進捗版）/ ローカルディレクトリ読み込み /
低レベル生成ストリーム / 思考テキスト分離 / `enable_thinking` の受け渡し /
`GenerateCompletionInfo` の計測値取得 / `ChatSession` / `Task` キャンセル /
`Module.namedModules()` による層の走査 / `ThinkingBudget`（main のみ）

### 10.2 結果

| # | 構成 | 結果 |
|---|---|---|
| 1 | **タグ 3.31.4** + 自作 `ThinkSplitter` | **`Build complete!` 警告0・エラー0** |
| 2 | **main (d7dc03d)** + `ReasoningEventEmitter` + `ThinkingBudget` | **`Build complete!` 警告0・エラー0** |

**両方通った。** 途中で踏んだエラーは第1.2節（3.31.4 に思考APIが無い）と
第4.4節（`Chat.Message` が Sendable でない）に記載した通り。

**実測値**:

| 項目 | 実測 |
|---|--:|
| 初回ビルド（依存解決 + Cmlx C++ の全ビルド） | **5分34秒**（user 661s / 222% CPU） |
| `.build` ディレクトリのサイズ | **1.4〜1.5 GB** |
| ソース1ファイル変更時の再ビルド | 約 1 秒 |
| ビルドされる MLX 系モジュール数 | 17（`MLXVLM` / `MLXEmbedders` / `MLXCXGrammar` 等も含む） |

**このビルド時間は「開発機を強化しない」原則に直接ぶつかる。**
初回とクリーンビルドは5分半かかる。CIに載せるならキャッシュ戦略が必須。

### 10.3 `swift build` では Metal シェーダが作れない（実証）

**[確認済] ビルド成果物に `.metallib` が1つも存在しないことを確認した。**

```
$ find .build -name "*.metallib" -o -name "*Cmlx.bundle"
（何も出ない）
```

`mlx-swift` の README / `troubleshooting.md` の記述と一致する。

> SwiftPM (command line) cannot build the Metal shaders so the ultimate build has to be done via Xcode.

- Metal シェーダは `mlx-swift_Cmlx.bundle` に入る。SwiftPM CLI はこれを作れない
- `xcodebuild` は作れる: `xcodebuild build -scheme Sophia -destination 'platform=OS X'`
- コマンドラインツールをシェルから直接起動する場合は `DYLD_FRAMEWORK_PATH` が必要。
  **アプリ（.app）としてビルドする分にはリソースとして自動で入るので不要**

**Sophia への指示: ビルドは Xcode / `xcodebuild` に統一すること。**
`swift build` は**型検査の高速確認としてのみ**使う（それでも1秒で回るので有用）。

---

## 11. 成熟度の評価

### 11.1 実用に耐えるか

**[確認済] 耐える。** 判断材料:

- Apple 自身（ml-explore）が開発し、**調査日の前日（2026-08-15）にもコミットが入っている**
- `mlx-swift-lm` に **60以上のモデルアーキテクチャ**が実装されている
  （Qwen3系だけで7ファイル、Gemma4、GPT-OSS、Mamba2、Jamba、NemotronH 等）
- 公式サンプルアプリが6本あり、**既定モデルが Qwen3-8B-4bit**（Sophia と同じ）
- 投機デコード、MTPドラフト、TurboQuant KVキャッシュ、文法制約生成、
  FoundationModels ブリッジなど、**研究段階でなく製品段階の機能**が入っている
- **思考モードの扱いに専用の型・テスト・統合テストがある**
  （`ReasoningEventEmitter` に単体テスト、`ReasoningFamilyVerificationTests` に実モデル検証）

**「MLX Swift は未成熟な可能性がある」という事前の懸念は、
2026年8月時点では当たらない。** 本調査で最も認識が変わった点である。

### 11.2 それでも注意すべきこと

1. **APIが速い速度で変わる。** 3.x はごく最近の破壊的変更で、
   トークナイザ／ダウンローダの依存構造が丸ごと変わった。
   `Evaluate.swift` には既に `@available(*, deprecated)` の `generate()` が5つある。
   → **`revision:` で固定し、`Package.resolved` を commit すること**
2. **リリースタグが遅れている。** 3.31.4 は6月末で、main との差が大きい（第1.2節）。
   「最新タグを使えば安全」が成立していない
3. **ネット上の情報のほぼ全てが古い。** `mlx-swift-examples` を依存に書く記事、
   2.x のAPI（`LLMModelFactory.shared.loadContainer(hub:configuration:)` 等）を
   使う記事が大量にある。**参照はリポジトリのソースのみとすること**
4. **ドキュメントよりコードが先に進んでいる。**
   `Libraries/*/Documentation.docc/*.md` を直接読むのが確実
5. **ビルドが重い**（第10章）
6. **`mlx-swift` はサブモジュール構成。** 自分でクローンするなら
   `git clone --recurse-submodules`。SPM経由なら不要

### 11.3 落とし穴（まとめ）

| # | 落とし穴 | 対策 |
|---|---|---|
| 1 | GGUF が使えない | MLX形式（safetensors）に変換／`mlx-community` から取得 |
| 2 | `swift build` で `.metallib` が作られない | Xcode / `xcodebuild` を使う |
| 3 | 思考分離APIがリリース版（3.31.4）に無い | `main` を `revision:` 固定、または自作（第6.5節） |
| 4 | `Chat.Message` / `UserInput` が Sendable でない | Sendable な独自型で持ち、変換はタスク内部で |
| 5 | マクロ使用時に `import HuggingFace` / `import Tokenizers` が要る | 忘れると意味不明なコンパイルエラー |
| 6 | `MLX` は `mlx-swift` から。`mlx-swift-lm` は再輸出しない | 両方を依存に書く |
| 7 | `<think>` は `.chunk` に生で混ざる | `ReasoningEventEmitter` か自作スプリッタ |
| 8 | Qwen3 の `primedInside` は `false`（`true` にすると全崩壊） | Qwen3 は `<think>` を先出ししない |
| 9 | `.info` は最後にしか来ない | TTFT はストリーム消費側の壁時計で測る |
| 10 | ストリームを `break` しても計算は数ms続く | 連続利用時は `generateTask()` で終了を観測 |
| 11 | `ChatSession` はキャンセルしたターンを履歴に残さない | A1 は低レベルAPIで組む |
| 12 | `GPU.set(cacheLimit:)` は非推奨 | `Memory.cacheLimit = ...` を使う |
| 13 | MLXの二重リンク（App→MLX と App→Framework→MLX） | ターゲット構成に注意 |
| 14 | iOSシミュレータで動かない | 実機のみ（macOSには無関係） |
| 15 | デバッガ下だと遅い | 計測は cmd-opt-r で "Debug Executable" を外して実行 |

---

## 12. 次のエージェントへの申し送り

### 12.1 決めるべきこと（最初に）

**`main` を revision 固定で使うか、タグ 3.31.4 を使うか。**
第1.2節の表を見て決める。**本調査の推奨は `main` の revision 固定。**
FR-17 の中核部品と、VISION に効く `ThinkingBudget` が `main` にしか無いため。

### 12.2 実装の順序

1. **Xcodeプロジェクトを作り、依存4つを追加してビルドを通す**（第1.3節）
2. 起動時に **`MLX.Memory.cacheLimit = 20 * 1024 * 1024`**（公式サンプル全部がそうしている）
3. **`LLMRegistry.qwen3_8b_4bit` を `#huggingFaceLoadModelContainer` で取得**（4.6GB、進捗表示つき）
4. **低レベルAPI（`ModelContainer.generate`）で FR-01 / FR-02 を実装。**
   `ChatSession` は魅力的だが、**キャンセルしたターンを履歴に残さない**ので A1 では避ける
5. **Sendable な独自メッセージ型を作る**（第4.4節）。`Chat.Message` を引数で渡さない
6. **`ReasoningEventEmitter`（または第6.5節の自作版）で FR-17**
7. **TTFT を2つ測る**（思考開始まで / 本文開始まで）。
   `.info` から `tokensPerSecond` / `promptTokensPerSecond` /
   `promptTokenCount` を記録し、`docs/BENCH_RESULTS.md` に Ollama 実測と並べる
8. **計測時はデバッガを外す**（cmd-opt-r → "Debug Executable" のチェックを外す）

### 12.3 A1 では触らないが、A2以降で効くもの

| 機能 | 効果 | 版 |
|---|---|---|
| `ChatSession` の KVキャッシュ持ち越し | 2ターン目以降のプリフィルが増分だけになる。**VISION 第1因子** | 両方 |
| `ThinkingBudgetProcessor` | 思考トークンの上限制御。**「予算の9割」問題** | main |
| `kvScheme = "turbo8v3"` | KVキャッシュ圧縮。16GB機のメモリ逼迫に直接効く | main |
| 投機デコード（`SpeculativeDecodingConfig`） | 小モデルで下書き、8Bで検証。**VISION 第2因子の一形態** | 両方 |
| `Qwen3.swift` の複製・改造 + `registerModelType` | 層ごとの計測・早期終了。**VISION 第3因子の入口** | 両方 |
| `LogitProcessor` | 確信度による打ち切りなど、層に触らない制御 | 両方 |
| ローカルディレクトリ読み込み（第2.3節C） | `network.client` entitlement を外せる。**NFR-01 を構造で保証** | 両方 |

### 12.4 未解決の課題

- **層ごとの実時間計測の方法論が無い**（第7.3節）。MLX は遅延評価のため、
  素朴に時刻を挟んでも測れず、`eval()` を挟むと測定行為が対象を壊す。
  **VISION 第3因子に着手する前に確立が必要**
- **MLX 4bit と Ollama Q4_K_M の品質差が不明。** 同一プロンプトでの比較が必要
- **KVキャッシュ圧縮の品質影響が不明**
- **アプリのバイナリサイズが不明。** 依存が16パッケージに膨らんでおり、
  NFR-06（本体300MB以内）に対する余裕が読めていない
