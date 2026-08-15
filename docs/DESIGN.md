# Sophia 設計書

| 項目 | 内容 |
|---|---|
| 文書名 | Sophia 設計書 |
| 版 | 1.0 |
| 作成日 | 2026-08-15 |
| 対象 | [REQUIREMENTS.md](REQUIREMENTS.md) v1.0 の全要件 |
| 関連文書 | [TUNING.md](TUNING.md) / [MODELS.md](MODELS.md) / [BENCH_RESULTS.md](BENCH_RESULTS.md) |

---

## 1. 設計方針

本設計を貫く3つの原則。個別の判断はすべてここから導いている。

1. **推論エンジンを差し替え可能にする**
   開発時は Ollama（導入済み・検証が速い）、配布時は同梱ランタイム（Ollama依存を外す）と
   実行方法が変わる。UIがエンジンの都合を知らない構造にしておかないと、後で作り直しになる。

2. **UIを止めない**
   ローカル推論は秒単位で待たされる。待ち時間そのものは短縮できないので、
   **待っている間に何が起きているかを見せる**設計にする。無言の待機を作らない。

3. **モデルはアプリと別の資産として扱う**
   最終的に独自モデルへ載せ替える計画があるため、モデルを本体に埋め込まない。
   モデルは差し替え可能なファイルであり、アプリはその読み手に徹する。

---

## 2. 実測値（設計の前提）

2026-08-15 に開発機（M3/16GB）で計測。条件と履歴は [BENCH_RESULTS.md](BENCH_RESULTS.md)。

| モデル | TTFT | 生成 tok/s（冷間） | 生成 tok/s（連続使用時） | 常駐メモリ |
|---|--:|--:|--:|--:|
| `sophia-chat`（qwen3:8b） | **15.4〜28.9 s** | 13.4 | **7.0** | 5.6 GB |
| `sophia-coder`（qwen2.5-coder:7b） | 0.21〜0.36 s | 14.1 | **9.0** | 4.8 GB |

この数値が第3章以降の設計判断の根拠になっている。

### 2.0 熱制限（実測で確認）

開発機はファンレスのため、**同一条件でも実行順で結果が最大2倍変わる**。

| 実行順 | sophia-coder | sophia-chat |
|---|--:|--:|
| chat先行 | 9.0 tok/s（2番目） | 13.4 tok/s（1番目） |
| coder先行 | 14.1 tok/s（1番目） | 7.0 tok/s（2番目） |

**先に走った方が速い。** これはモデルの性能差ではなく熱制限である。
`sophia-chat` の TTFT も冷間 15.4s に対し高温時 28.9s へ悪化した。

設計上の帰結:

- **連続使用時の実力値は 7〜9 tok/s** と見なす。冷間の値を性能指標にしてはならない
- 速度に関する比較は、本体が冷えた状態に揃えて計測する
- 利用者の体感は使用時間とともに悪化する。UIは「遅くなった＝故障」と誤解させない表示にする

### 2.1 思考モードの実測（重要）

`qwen3` は応答前に思考テキストを出力する。同一プロンプトでの比較:

| 条件 | 思考 | 本文 | 消費トークン |
|---|--:|--:|--:|
| 思考モード有効（既定） | 1,075文字 | 112文字 | 300（上限到達） |
| 思考モード無効 | 0文字 | 56文字 | 32 |

**トークン予算の約9割が思考に消える。** これが TTFT 15〜19秒の正体であり、
生成上限が小さいと**本文に到達しないまま打ち切られる**（実測で発生）。

→ 第6章で専用の設計を行う。UIで扱わない限り、**利用者には15秒間フリーズに見える**。

---

## 3. システム全体構成

```
┌──────────────────────────────────────────────┐
│ Electron main process                        │
│  ├─ IPC Router        renderer との窓口       │
│  ├─ ModelManager      取得・検証・切替        │
│  └─ Store (SQLite)    会話履歴・設定          │
│         │ MessagePort（トークン専用の直通経路）│
│  ┌──────┴───────────────────────────────┐    │
│  │ utilityProcess: Inference Worker      │    │
│  │  └─ InferenceEngine 実装               │    │
│  │      ├─ OllamaEngine    (開発時)       │    │
│  │      └─ LlamaCppEngine  (配布時)       │    │
│  └───────────────────────────────────────┘    │
└──────────────────────────────────────────────┘
                    ▲
                    │ preload (contextBridge)
┌───────────────────┴──────────────────────────┐
│ Renderer : React + TypeScript                │
│  会話画面 / モデル管理 / 設定                 │
└──────────────────────────────────────────────┘
```

### 3.1 推論を別プロセスに置く理由

**NFR-02（推論中もUIが操作可能）を満たすため。**
推論は数十秒CPU/GPUを占有する。main プロセスで直接実行すると
イベントループが詰まり、ウィンドウ操作も中断ボタンも効かなくなる。

Electron の `utilityProcess` を使う。ワーカースレッドではなく別プロセスにするのは、
ネイティブモジュール（`.node`）のクラッシュがアプリ全体を巻き込まないようにするため。
**推論エンジンの異常終了は、会話履歴を失わずに復帰できなければならない。**

---

## 4. 推論エンジンの抽象化

要件 **NFR-09**。開発時と配布時で実装が変わる唯一の層。

```ts
// src/main/engine/types.ts
export interface ChatOptions {
  temperature: number
  topP: number
  numCtx: number
  maxTokens: number
  /** 思考モード。対応モデルのみ有効（第6章） */
  thinking: boolean
  signal: AbortSignal        // FR-02 中断
}

/** 生成中に流れてくる断片。思考と本文を型で区別する */
export type Chunk =
  | { kind: 'thinking'; text: string }
  | { kind: 'content';  text: string }
  | { kind: 'done';     stats: GenerationStats }

export interface GenerationStats {
  ttftMs: number
  tokensPerSecond: number
  inputTokens: number
  outputTokens: number
}

export interface InferenceEngine {
  listModels(): Promise<ModelInfo[]>
  load(modelId: string): Promise<void>
  chat(messages: Message[], opts: ChatOptions): AsyncIterable<Chunk>
  unload(): Promise<void>
  capabilities(): { thinking: boolean; maxCtx: number }
}
```

| 実装 | 使用時期 | 中身 |
|---|---|---|
| `OllamaEngine` | フェーズ1〜（開発） | `http://localhost:11434` へHTTP。`thinking` は API の `think` で制御 |
| `LlamaCppEngine` | フェーズ2〜（配布） | `node-llama-cpp` で GGUF を直接読む。常駐プロセスなし |

**`Chunk` で思考と本文を型レベルで分けているのが設計の要点。**
実測どおり思考は本文の10倍量が流れるため、混ぜて扱うと UI もトークン計算も破綻する。

---

## 5. ストリーミングとIPC

### 5.1 経路

トークンは1つずつ、秒間10個以上流れる。`ipcRenderer` の往復で1トークンずつ送ると
オーバーヘッドが無視できないため、**`MessagePort` を utilityProcess ↔ renderer に直結**する。
main プロセスは接続を仲介するだけで、トークン自体は通さない。

```
[renderer] --- chat:start (通常IPC) ---> [main] --- fork/port ---> [worker]
[renderer] <========= MessagePort（トークン直通） ==========> [worker]
[renderer] --- chat:abort (通常IPC) --> [main] --- AbortSignal -> [worker]
```

### 5.2 描画の間引き

トークンごとに React を再描画すると、生成中ずっと再レンダリングが走る。
**16ms（1フレーム）単位でバッファして flush する**。体感は変わらず負荷だけ下がる。

### 5.3 中断（FR-02）

`chat:abort` を受けたら worker 側の `AbortSignal` を発火し、
**すでに生成された分は破棄せず保存する**。利用者が中断するのは
「もう十分」か「方向が違う」のどちらかで、前者では出力が要る。

---

## 6. 思考モードの扱い（第2.1章の実測に基づく）

**設計判断: 思考を隠さず、専用の表示領域を与える。**

| 案 | 判断 |
|---|---|
| 思考モードを常に無効化 | ❌ 難しい問いでの品質が落ちる。モデルの能力を捨てることになる |
| 思考も本文と同じ流れに混ぜて表示 | ❌ 本文が1割しかないため、読み手が答えを見つけられない |
| **思考を折りたたみ領域に分けて表示** | ✅ **採用**。15秒が「無反応」ではなく「思考中」に変わる |

実装:

- 生成開始と同時に**思考領域を表示し、思考テキストを流す**。無言の待機時間をゼロにする
- 本文が始まったら思考領域を自動的に折りたたむ。再展開は可能
- 会話ごとに**思考モードのON/OFFを切替可能**にする（FR-10）。
  短い質問では無効の方が体感が圧倒的に速い（実測 TTFT 15.4s → 0.2s 相当）
- **思考モード有効時は `maxTokens` を自動的に引き上げる**。
  実測どおり予算の9割を思考が使うため、既定値のままでは本文に到達せず打ち切られる
- 思考テキストは `messages.thinking` に本文と分けて保存する（第8章）

---

## 7. モデル管理

### 7.1 配置

| 対象 | 場所 | 理由 |
|---|---|---|
| モデル本体（GGUF） | `app.getPath('userData')/models/` | アプリ更新で消えない。アンインストール時に一緒に消せる |
| 会話履歴DB | `app.getPath('userData')/sophia.db` | 同上 |

**アプリ本体にモデルを同梱しない**（NFR-06）。5GBを `.app` に入れると
配布サイズ・公証時間・更新コストがいずれも現実的でなくなるため、初回起動時に取得する（FR-07）。

### 7.2 取得

- HTTP Range リクエストによる**レジューム対応**（NFR-10）。中断・回線断から再開できる
- ダウンロード先は一時ファイル。**完了・sha256検証後に本来の名前へ改名**する（NFR-08）。
  検証前のファイルが正規のモデルとして読まれる事故を防ぐ
- 空き容量を事前に確認し、不足時は必要量を明示して中止する

### 7.3 推奨モデルの判定（FR-08）

`os.totalmem()` から判定する。閾値の根拠は [TUNING.md](TUNING.md) の予算表。

| 搭載メモリ | 推奨 | 備考 |
|---|---|---|
| 8GB以下 | 3〜4B | 動作優先 |
| 16GB | **7〜8B** | 開発機と同条件。実測値がそのまま目安になる |
| 32GB以上 | 14B以上 | |

推奨外のモデルも選択可能にするが、**選択時に速度低下の可能性を明示**する。

---

## 8. データモデル（SQLite）

```sql
CREATE TABLE conversations (
  id          TEXT PRIMARY KEY,
  title       TEXT    NOT NULL,
  model_id    TEXT    NOT NULL,
  profile_id  TEXT    REFERENCES profiles(id),
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);

CREATE TABLE messages (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role            TEXT NOT NULL CHECK (role IN ('system','user','assistant')),
  content         TEXT NOT NULL,
  thinking        TEXT,              -- 思考モードの出力。本文と分けて保持（第6章）
  created_at      INTEGER NOT NULL,
  -- FR-14 用の実測値。会話ごとの体感差を後から検証できるようにする
  input_tokens    INTEGER,
  output_tokens   INTEGER,
  ttft_ms         INTEGER,
  tokens_per_sec  REAL
);
CREATE INDEX idx_messages_conv ON messages(conversation_id, created_at);

-- modelfiles/*.Modelfile に相当。役割の切替（FR-05）
CREATE TABLE profiles (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  system_prompt TEXT NOT NULL,
  params_json   TEXT NOT NULL
);

CREATE TABLE models (
  id               TEXT PRIMARY KEY,
  filename         TEXT NOT NULL,
  sha256           TEXT NOT NULL,
  size_bytes       INTEGER NOT NULL,
  downloaded_bytes INTEGER NOT NULL DEFAULT 0,
  state            TEXT NOT NULL
                   CHECK (state IN ('pending','downloading','ready','corrupt'))
);
```

`messages` に実測値を持たせているのは、**設定変更の効果を実利用のログから確認できるようにする**ため。
ベンチは合成プロンプトなので、実作業での傾向とはずれる。

FR-13（全文検索）は後から FTS5 の仮想テーブルを追加して対応する。

---

## 9. ディレクトリ構成とアセット

```
Sophia/
├── app/                        # Electron アプリ本体（フェーズ1で作成）
│   ├── src/
│   │   ├── main/
│   │   │   ├── index.ts
│   │   │   ├── ipc.ts
│   │   │   ├── engine/
│   │   │   │   ├── types.ts        # InferenceEngine 定義
│   │   │   │   ├── ollama.ts       # 開発用
│   │   │   │   ├── llamacpp.ts     # 配布用
│   │   │   │   └── worker.ts       # utilityProcess エントリ
│   │   │   ├── models/             # ModelManager
│   │   │   └── db/                 # SQLite
│   │   ├── preload/
│   │   └── renderer/               # React + TypeScript
│   └── electron-builder.yml
├── modelfiles/                 # 開発用（Ollama）のプロファイル定義
├── scripts/
│   ├── serve.sh
│   └── bench.py
└── docs/
```

`app/` を切っているのは、**フェーズ0の検証環境（Ollama + 計測）を
アプリ本体と混ぜないため**。検証環境は配布物に含めない。

### 9.1 アイコン

```
assets/
├── logo.png     元画像（1254x1254、正方形フルブリード）
├── icon.png     1024x1024。角が透明。electron-builder が参照する
└── icon.icns    macOS ネイティブ形式。iconutil で生成
```

**macOS は iOS と違い、アプリアイコンを自動で角丸にマスクしない。**
開発者がスクワークル形状と余白を画像に焼き込む必要がある。
これを怠ると Dock で他アプリより大きく角張って見える。

Apple の macOS アイコングリッドに従い、**1024px キャンバスの中央に 824px の
スクワークル**（各辺100pxの余白）を配置している。角の丸みは超楕円
（`|x|^5 + |y|^5 = 1`）で近似。

生成は再現可能にしてある。ロゴを差し替えたら実行し直す。

```bash
make icons
```

16px（メニューバー・Finder）から1024px（Retinaの情報ウィンドウ）まで
検証済み。明背景・暗背景の双方でクリーム地がコントラストを担保している。

### 9.2 配色

アプリUIの基準色。ロゴから抽出した実測値。

| 役割 | 色 | 用途 |
|---|---|---|
| 背景（クリーム） | `#FEF5EB` | ライトテーマの地。アイコン背景 |
| 前景（チャコール） | `#434548` | 本文テキスト、ダークテーマの地 |
| 強調（テラコッタ） | `#D08256` | アクセント、リンク、生成中インジケータ |

テラコッタは彩度が高いため**面積を持たせない**。文字と細い要素に限定し、
広い面はクリームとチャコールで構成する。

---

## 10. 独自モデル開発（並行トラック）

最終目標である「自分だけのモデル」に向けた設計。**アプリ開発とは独立して進められる。**
成果物は GGUF ファイル1つであり、アプリ側はそれを読むだけなので、
どちらかの完成を待つ必要がない。

### 10.1 段階と実行場所

**ローカルは出発点であり、上限に達した時点でクラウドへ移行する。**
段階の全体像と移行条件は [ROADMAP.md](ROADMAP.md) を正とする。

| 手法 | 新しい重みができるか | 実行場所 | コスト |
|---|:--:|---|---|
| **モデルマージ** | ✅ | ローカル | 0円。学習不要で重みを合成する |
| **LoRA → fuse** | ✅ | ローカル | 0円。MLX の QLoRA。fuse でベースに融合し単一モデル化 |
| 大規模SFT / DPO | ✅ | クラウド | 数万〜数十万円 |
| 継続事前学習 | ✅ | クラウド | 数十万〜数百万円 |
| スクラッチ事前学習 | ✅ | クラウド | 8B級で数千万円〜。組織規模の投資 |

まずローカルの2手法（マージ・LoRA-fuse）で「世界に存在しなかった重み」を作り、
評価基盤を回しながら段階を上げる。

**クラウドへ移行しても推論と配布はローカルのまま。** 学習だけをクラウドへ出す構成のため、
利用者データが外部へ出ることはなく、NFR-01 と本設計は影響を受けない。

### 10.2 パイプライン

```
ベースモデル(Qwen系, Apache 2.0)
   ├─ [マージ]  mergekit で複数モデルの重みを合成
   └─ [LoRA]    MLX で微調整 → mlx_lm.fuse でベースへ融合
                          ↓
                    GGUF へ変換・量子化
                          ↓
              make bench / 実作業で品質評価
                          ↓
                 アプリへ載せる（第7章の経路）
```

### 10.3 ベースを Qwen 系とする理由

- **Apache 2.0**。再配布・商用利用が可能で、「単体配布アプリ」の要件と矛盾しない
  （※ 配布前にモデルカードで最終確認すること。REQUIREMENTS 未決事項#4）
- MLX / mergekit / GGUF変換の各段階で情報と実績が揃っている
- 8B帯で日本語・コードともに競争力がある（[MODELS.md](MODELS.md)）

### 10.4 想定される最大の障害

**計算資源ではなくデータ。** LoRA で意味のある差を出すには、
質の揃った訓練データが数千件必要になる。ここが作業量の大半を占める。
着手時は「何のデータを、どう集め、どう整形するか」から設計する。

---

## 11. 配布（フェーズ4）

| 項目 | 内容 |
|---|---|
| パッケージャ | electron-builder |
| 対象 | macOS arm64（初版）。`.dmg` |
| 署名 | Developer ID Application。**Apple Developer Program 加入が前提** |
| 公証 | notarytool。`hardenedRuntime: true` + entitlements |

ネイティブモジュール（`node-llama-cpp` の `.node`）を含むため、
`hardenedRuntime` 下では以下の entitlement が必要になる見込み。実機で要検証。

- `com.apple.security.cs.allow-unsigned-executable-memory`
- `com.apple.security.cs.disable-library-validation`

---

## 12. 技術的リスク

| # | リスク | 影響 | 対策 |
|---|---|---|---|
| 1 | ネイティブモジュールの署名・公証が通らない | 配布不能 | **フェーズ2の時点で空アプリを1度公証まで通す**。フェーズ4で初めて試すと手戻りが大きい |
| 2 | Apple Developer 未加入 | 受入条件1を満たせない | 加入要否をフェーズ4着手前に確定（未決事項#1） |
| 3 | 思考モードで本文に到達しない | 応答が空に見える | 第6章。`maxTokens` 自動調整と思考領域の表示 |
| 4 | 開発機16GBでアプリ+モデルが逼迫 | 開発が進まない | 開発中は Open WebUI を落とす。`OLLAMA_MAX_LOADED_MODELS=1` |
| 5 | ファンレスによる熱制限 | 計測値が再現しない | 比較計測は本体が冷えた状態に揃える（TUNING.md 9章） |
| 6 | モデルのライセンスが再配布不可 | 配布方式の変更 | 初回ダウンロード方式（FR-07）で再配布に当たらない設計。未決事項#4 |
| 7 | アイコン形式が `.icns` から `.icon` へ移行中 | 新OSでアイコンが古く見える | macOS 26 の Icon Composer は、レイヤーを渡せばシステムが形状・ライト/ダーク/着色を生成する方式。**electron-builder の対応状況は未確認**。フェーズA4着手時に最新ドキュメントを確認する。`.icns` は当面有効なので現状の生成物は無駄にならない |

---

## 13. 実装フェーズ

| フェーズ | 内容 | 完了条件 |
|---|---|---|
| 0 | ローカルモデル環境と計測基盤 | **完了**（実測値取得済み） |
| 1 | Electron骨格 + `OllamaEngine` + 思考モード表示 | 会話が逐次表示され、中断が効く |
| 2 | `LlamaCppEngine` へ差し替え + **公証の疎通確認** | Ollama を停止しても動作する |
| 3 | モデル管理・履歴永続化 | 受入条件2〜7を満たす |
| 4 | パッケージング・署名・公証 | 受入条件1を満たす |
| 並行 | 独自モデル開発（第10章） | アプリの進行と独立 |

フェーズ2で公証を先に通しておくのがリスク1への対策であり、
この順序が本設計における最大の予防措置になっている。
