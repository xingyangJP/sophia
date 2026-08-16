# Sophia 設計書

| 項目 | 内容 |
|---|---|
| 文書名 | Sophia 設計書 |
| 版 | **2.0** |
| 作成日 | 2026-08-15 |
| 更新日 | 2026-08-16（**Electron から SwiftUI + MLX へ全面改訂**。第3・4・5・7・9・11・12章を書き換え、第1・6・8・10・13章に追記。第2章の実測値は変更なし） |
| 対象 | [REQUIREMENTS.md](REQUIREMENTS.md) v1.0 の全要件 |
| 上位文書 | **[VISION.md](VISION.md)**（本書はこの下位にある） |
| 関連文書 | [MLX_SWIFT.md](MLX_SWIFT.md) / [TUNING.md](TUNING.md) / [UI_SPEC.md](UI_SPEC.md) / [UI_NATIVE.md](UI_NATIVE.md) / [MODELS.md](MODELS.md) / [BENCH_RESULTS.md](BENCH_RESULTS.md) |

> **記法 — 確認できた事実と、まだ確認していない設計案を分ける**
>
> | 印 | 意味 |
> |---|---|
> | **【実測】** | 開発機で計測した値。条件は [BENCH_RESULTS.md](BENCH_RESULTS.md) / [TUNING.md](TUNING.md) |
> | **【確認済】** | [MLX_SWIFT.md](MLX_SWIFT.md) でソースを読み、またはビルドを通して確認した |
> | **【未確認】** | 設計上の判断であり、実機で検証していない。**A1 で検証すること** |
>
> **本書に載る Swift コードは、特記がない限り「設計案」であってコンパイルを通していない。**
> MLX 側の API が実在しコンパイルが通ることは [MLX_SWIFT.md](MLX_SWIFT.md) 第10章で確認済みだが、
> **Sophia 側の型定義とその組み合わせは未確認である。**
>
> **2026-08-16 の転換について**
>
> 本書 v1.1 は Electron を前提に書かれていた。[VISION.md](VISION.md)（1/1000のエネルギー）
> を北極星に据えた結果、**推論エンジンを Ollama の HTTP API 越しに使う構成では
> 目標に到達できない**ことが判明し、macOS ネイティブ（SwiftUI + MLX Swift）へ転換した。
>
> **Electron 固有の記述だけを置き換えている。実測値と、実測から導いた判断は捨てていない。**

---

## 1. 設計方針

本設計を貫く原則。個別の判断はすべてここから導いている。
**原則1〜3は v1.1 から変わらない。理由の書き方だけがネイティブ構成に合わせて変わった。**

### 原則1: 推論エンジンを差し替え可能にする

v1.1 での理由は「開発時は Ollama、配布時は同梱ランタイム」だった。
**この理由は消滅した。** MLX は開発時も配布時も同じ実装であり、常駐サーバも外部依存も無い。

**それでも抽象化は残す。理由が3つに置き換わった。**

| 差し替える対象 | 何のために |
|---|---|
| **トラックBの成果物** | 独自モデルへ載せ替える（第10章）。モデルが変わればトークナイザ・思考プロトコル・推奨パラメータが変わる |
| **モデルの規模** | 「こんにちは」に8Bを使わない（VISION 第2因子）。0.6B と 8B を同じ入口から呼べる必要がある |
| **解剖版のエンジン** | 層ごとの計測・早期終了を入れた実装を、素の実装と**並べて比較する**（4.5節）。差し替えられないと A/B が取れない |

### 原則2: UIを止めない

ローカル推論は秒単位で待たされる。待ち時間そのものは短縮できないので、
**待っている間に何が起きているかを見せる**設計にする。無言の待機を作らない。

ネイティブ化で手段が変わった。`utilityProcess` による別プロセス化ではなく、
**Swift Concurrency の Task と actor 隔離**で実現する（第3章）。

### 原則3: モデルはアプリと別の資産として扱う

最終的に独自モデルへ載せ替える計画があるため、モデルを本体に埋め込まない。
モデルは差し替え可能なファイルであり、アプリはその読み手に徹する。

**MLX 化で形式が変わった。GGUF 単一ファイルではなく、MLX形式（safetensors）のディレクトリになる**（第7章）。

### 原則4: 推論を解剖可能に保つ（**2026-08-16 追加**）

**[VISION.md](VISION.md) から降りてきた新しい原則である。**

現在のAIは、問いの難易度に関わらず同じ計算量を払う。手を抜く仕組みが存在しない。
1/1000 を目指す以上、**どこで何を計算しているかが見えて、途中でやめられる**必要がある。

Ollama を捨てて MLX を選んだ最大の理由がここにある。
**HTTP API の向こう側では、層ごとのコストも早期終了も、APIが公開していない限り触れない。**
MLX では計算グラフが Sophia のコード内にある【確認済 / MLX_SWIFT 7.3】。

> **A1 で実装しなくてよい。ただし、構造として塞いではならない。**
> 何をもって「塞がない」とするかを 4.4〜4.7節に具体化した。

---

## 2. 実測値（設計の前提）

2026-08-15 および 2026-08-16 に開発機（M3/16GB）で計測。
条件と履歴は [BENCH_RESULTS.md](BENCH_RESULTS.md)。

> **本章の数値はすべて Ollama + GGUF（Q4_K_M）での実測である。**
> **MLX + safetensors（4bit）での再計測は A1 完了後に 2.6節へ追記する。**
> 2.6節に「何が変わり、何が変わらないか」の見込みを書いたが、**数値は現時点で Ollama のものが唯一の根拠**である。

### 生成（デコード）側

| モデル | TTFT | 生成 tok/s（冷間） | 生成 tok/s（連続使用時） | 常駐メモリ |
|---|--:|--:|--:|--:|
| `sophia-chat`（qwen3:8b） | **15.4〜28.9 s** | 13.4 | **7.0** | 5.6 GB |
| `sophia-coder`（qwen2.5-coder:7b） | 0.21〜0.36 s | 14.1 | **9.0** | 4.8 GB |

### 入力処理（プリフィル）側 — 2026-08-16 追加

**生成とは別の指標として扱う。** 応答までの待ち時間は
「プリフィル時間 ＋ 生成時間」であり、長い入力ではプリフィルが支配的になる。

`sophia-chat` / `num_ctx=8192` / KV `q8_0` / `num_batch=512` / 計測前に90秒冷却。

| 入力トークン | 実計算トークン | プリフィル時間 | tok/s |
|--:|--:|--:|--:|
| 273 | 273 | **1.6 s** | 167 |
| 1,022 | 789 | **4.8 s** | 163 |
| 4,792 | 4,561 | **34.3 s** | 133 |
| 7,688 | 7,457 | **65.2 s** | 114 |

`tok/s` の分母は入力トークンではなく**実計算トークン**である。チャットテンプレート冒頭の
約231トークンが KV に残って計算されていないため、入力トークンで割っても表の値にならない
（詳細は [TUNING.md](TUNING.md) 第1章）。新規チャットではこの約231トークンも計算されるので、
同じ入力長でも**約1.4〜1.8秒ぶん遅くなる。**

**入力処理速度は約114〜167 tok/s。長いほど1トークンあたりが高くつく**
（アテンションが既存文脈全体に働くため、総時間は超線形に伸びる）。
連続使用時はさらに**中央値1.55倍**遅くなる。

以前ベースラインに記録していた 3,610 tok/s は**計測アーティファクト（偽値）**だった。
同一プロンプトの再送でプレフィックスキャッシュに全命中していたもので、
2 × 8.19e9 × 3,610 = 59 TFLOP/s は M3 8コアGPU の FP16 理論ピーク（約6.6 TFLOP/s）の9倍にあたり
物理的に成立しない。**114〜167 tok/s がこの機体の素の実力値。**

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

**この制約はランタイムを替えても消えない。** MLX に変えても筐体は同じである。

### 2.1 思考モードの実測（重要）

`qwen3` は応答前に思考テキストを出力する。同一プロンプトでの比較:

| 条件 | 思考 | 本文 | 消費トークン |
|---|--:|--:|--:|
| 思考モード有効（既定） | 1,075文字 | 112文字 | 300（上限到達） |
| 思考モード無効 | 0文字 | 56文字 | 32 |

**トークン予算の約9割が思考に消える。** これが TTFT 15〜19秒の正体であり、
生成上限が小さいと**本文に到達しないまま打ち切られる**（実測で発生）。

> **文字数とトークン数が整合していない（未解決）。** 上段は合計1,187文字を
> 300トークンで出したことになり、1トークン約4文字にあたる。日本語の校正値
> （1文字≒0.5トークン＝1トークン約2文字）と合わない。思考部分が英語で出力されていれば
> 説明がつくが、**出力言語を記録していないため確認できない**。
> 確実なのは「上限300トークンに到達した」という計測事実の方なので、
> 本書でトークン数を要する箇所（2.3 の条件1）はそちらを基準にしている。
> 再計測時は思考部分の言語と `eval_count` を必ず記録すること。
>
> **【2026-08-16 追記】この未解決は A1 で解ける。**
> 第4.6節の `GenerationStats` は `thinkingChars` と `outputTokens` を
> **同じ1回の生成について同時に記録する**。思考テキストは Sophia 自身が分離するため
> （第6章）、文字数はアプリ側で確実に数えられる。**A1 の最初の計測課題とする。**

→ 第6章で専用の設計を行う。UIで扱わない限り、**利用者には15秒間フリーズに見える**。

### 2.2 プロンプト肥大はクライアントが作る（2026-08-16 判明）

Open WebUI 経由で「こんにちは」の一言を送ったときの実際の入力長は **4,786トークン**だった。
素の Ollama API へ同じ入力を送ると245トークン。
**差の約4,550トークン（95%）は Open WebUI が自動注入したビルトインツールのJSONスキーマ**で、
利用者が書いた文字でもシステムプロンプトでもない。
（ツールの個数とカテゴリ別の内訳は計算値で、合計が実測と数百トークンずれている。
[TUNING.md](TUNING.md) 第2章の注記を参照。設計上の判断は「約4,550トークンがクライアント由来」
という実測差のみに依っており、内訳の精度には依存しない。）

これは Sophia 本体の速度問題ではなく**クライアント設計の問題**である。
サーバ側のつまみ（KV型・num_batch・量子化）をどう回しても、
入力4,786トークンのプリフィル32〜35秒は縮まない。

**設計上の帰結: 自作アプリはこの構造を持ち込まない。**

| 原則 | 内容 |
|---|---|
| **送信トークンを常に把握する** | 送信直前に入力トークン数を数え、`GenerationStats.inputTokens` として記録する（第4章）。「気づいたら5,000トークン送っていた」を構造的に起こさない |
| **機能はプロンプトに常駐させない** | ツール定義・RAG文脈・メモリなどは、**その会話で実際に必要なときだけ**入れる。全機能ぶんを毎回前置きしない |
| **予算を上限として持つ** | 入力トークンの予算（下記）を超えたら、UIで警告するか自動で切り詰める。黙って超えない |
| **UIに入力トークン数を出す** | FR-14 の対象を「TTFT / tok/s」から**「入力トークン数」を含めた3点**へ広げる。利用者が「遅い理由」を自分で理解できる唯一の手段 |

第2章の実測から逆算した入力の予算（内挿による見積り）:

| 目標 | 入力トークンの上限 |
|---|--:|
| プリフィル 5秒以内（冷間） | 約 800 |
| プリフィル 10秒以内（冷間） | 約 1,550 |
| プリフィル 10秒以内（連続使用時も守る） | **約 1,000** |

**設計値は 1,000トークン**を採る。冷間の数字で設計すると実利用で破綻するため。
日本語は概ね1文字≒0.5トークンなので、**利用者の入力＋システムプロンプト＋文脈で約2,000字**が目安。

> **【2026-08-16 追記】この節が VISION 第1因子（20倍）そのものである。**
> 「アーキテクチャを1行も変えずに20倍」の対象は、まさにここで禁じた自動注入だった。
> **MLX 化で新しい味方が1つ増える。** `ChatSession` はターン間で KVキャッシュを持ち越すため、
> 2ターン目以降のプリフィルが「増分だけ」になる【確認済 / MLX_SWIFT 4.2】。
> ただし A1 では別の理由で使わない（第5.3節）。**A2 以降の最有力の最適化点。**

### 2.3 「10秒以内に応答」は達成可能か

**定義**: 送信してから**本文の1文字目**が表示されるまで10秒以内。

**結論: 達成可能。ただし以下の3条件をすべて満たしたときに限る。**

| # | 条件 | 満たさない場合 |
|---|---|---|
| 1 | **思考モードが OFF** | 本文の1文字目の前に思考1,075文字が流れる。2.1 の計測では出力が上限300トークンで打ち切られており、思考はその大半（概ね250〜300トークン）を占める。生成7〜13.4 tok/s では本文の1文字目まで**20〜40秒**。入力を0にしても届かない |
| 2 | **入力が約1,000トークン以内** | 4,786トークンならプリフィルだけで冷間32〜35秒、連続使用時40〜155秒 |
| 3 | **クライアントが余計な注入をしない** | 条件2を利用者が守っても、クライアントが4,550トークン足せば無意味になる |

**現状の Open WebUI 構成では達成不能。** サーバ設定では解決しない。
`Builtin Tools` を off にして入力を約231トークンにすれば、プリフィルは約1.5秒となり
条件1・2が満たされて達成できる（未実測。要検証）。

補足として、**「完全な回答が10秒以内」は別問題**であり、こちらは達成できない。
生成7〜13.4 tok/s で10秒間に出せるのは70〜134トークン。
日本語は1文字≒0.5トークン（2.2 の校正値）なので**140〜270文字程度**にあたる。
プリフィルの時間を引けば実際はこれより短い。短い一問一答なら収まるが、
まとまった説明には届かない。
→ UIは「全部出るまで待たせる」のではなく、逐次表示で読み始められるようにする（FR-01）。

> **【2026-08-16 追記】この節が「TTFT を2つ持つ」根拠である。**
> 定義が「本文の1文字目まで」である以上、思考の1文字目までの時間とは別に測らなければ
> 達成/未達の判定ができない。第4.6節の `ttftMs` / `ttfrMs` はこの節への回答である。

### 2.4 NFR-03（1秒以内に何かが表示される）は入力長に依存する

**未解決の問題として記録しておく。** プリフィルは最短の実測点でも
273トークンで1.6秒かかっている。`sophia-chat` は Modelfile の SYSTEM だけで
223トークンを消費するため、**利用者が1文字打っただけでもプリフィルは約1.5秒**になる。

つまり NFR-03 の「1秒以内」は、システムプロンプトを含めて
**入力が約170トークン以内のときしか満たせない**。
現状の要件は入力長の条件を書いていないため、達成条件が定義できていない。
→ REQUIREMENTS の NFR-03 に入力長の前提を追記するか、閾値を見直す必要がある（未決）。

なお、この1.5秒は「無反応」にしてよい時間ではない。
UIは送信直後に受付表示を出し、**プリフィル中であることを示す**（第6章の思考領域と同じ考え方）。

> **【2026-08-16 追記】MLX には「プリフィルの進捗」を出す道がある。**
> `main` 系の `GenerateParameters.prefill.progress` が
> `(processed, total)` を返す【確認済 / MLX_SWIFT 4.3】。
> **無反応の1.5秒を「進捗バー」に変えられる。** リリース版 3.31.4 には無い（1.2節の版選択に影響する）。

### 2.5 MLX へ移ると何が変わり、何が変わらないか【未確認】

**本節は見込みであって実測ではない。** A1 完了後に 2.6節へ実測を置き、本節と突き合わせる。

| 項目 | 見込み | 根拠 |
|---|---|---|
| **熱制限（2.0）** | **変わらない** | 筐体が同じ。ファンレスであることはランタイムと無関係 |
| **メモリ逼迫とページング** | **変わらない** | 物理メモリは増えない。VISION が記録した「最大4.9倍」はそのまま残る |
| **日本語 1文字≒0.5トークン** | **ほぼ確実に変わらない** | 同じ `tokenizer.json` を読む【確認済 / MLX_SWIFT 第3章】 |
| **思考が予算の9割を食う（2.1）** | **変わらない** | モデルの振る舞いであってランタイムの問題ではない |
| プリフィル / 生成の tok/s | **不明** | 別ランタイム・別量子化方式。**測るまで何も言えない** |
| 常駐メモリ | **下がる見込み** | Electron 約300MB と Ollama サーバが消える。SwiftUI シェルは約50MB |
| モデルのディスク量 | **約0.6GB 減る** | Qwen3-8B-4bit（MLX）4.62GB【確認済】vs Q4_K_M 約5.2GB |
| 出力品質 | **不明** | 量子化方式が違う。**比較測定が必要**（MLX_SWIFT 12.4 の未解決課題） |

### 2.6 MLX での実測（A1 完了後に記入）

**未計測。** A1 の完了時に、Ollama 実測と並べられる形で
[BENCH_RESULTS.md](BENCH_RESULTS.md) と本節に記録する。最低限そろえる項目:

`promptTokenCount` / `promptTokensPerSecond` / `tokensPerSecond` /
TTFT（思考の1文字目まで）/ TTFR（本文の1文字目まで）/ `thinkingChars` /
`MLX.Memory.snapshot()` / 冷間と連続使用時の別 / **計測時はデバッガを外す**【MLX_SWIFT 落とし穴15】。

---

## 3. システム全体構成

**単一プロセス。** Electron の3プロセス構成（main / utilityProcess / renderer）は消えた。

```
Sophia.app ── 単一プロセス ───────────────────────────────────────

  [ @MainActor ]
      SwiftUI View
          Sidebar / ChatView / ThinkingPanel / Composer
              ▲ 描画                  │ 送信・中断
              │                       ▼
      @Observable ChatViewModel
          generationTask: Task<Void, Never>?          ← FR-02 中断
              ▲                       │
              │ AsyncStream<Chunk>     │ [SophiaMessage]
              │       （第5章）        │  Sendable な独自型
  ────────────┼───────────────────────┼───── Sendable 境界（3.2節）
              │                       ▼
  [ 非 MainActor / Task ]
      actor MLXEngine : InferenceEngine                     第4章
          ├─ ReasoningSplitter   <think> の分離             第6章
          ├─ StatsCollector      TTFT / TTFR / tok/s        4.6節
          └─ MLXLMCommon.ModelContainer（MLX 側の actor）
                  └─ Qwen3 モデル本体 ──▶ Metal / GPU

      actor Store（GRDB / SQLite）                          第8章
          conversations / messages / profiles / models

──────────────────────────────────────────────────────────────────

  ~/Library/Application Support/Sophia/     ← 第7.1節
      ├─ Models/      MLX形式（safetensors）のディレクトリ
      └─ sophia.db    会話履歴
      （サンドボックス下では実体が Containers 配下になる。7.1節）
```

### 3.1 推論を別プロセスに置かない理由（Electron からの最大の変更点）

v1.1 は `utilityProcess` に推論を追い出していた。理由は2つあった。

| v1.1 の理由 | ネイティブ版での扱い |
|---|---|
| (a) main のイベントループが詰まり、中断ボタンも効かなくなる | **解決した。** 生成は独立した `Task` で走り、`ModelContainer` は actor 隔離されている【確認済 / MLX_SWIFT 0章・4章】。MainActor を占有しない |
| (b) ネイティブモジュール（`.node`）のクラッシュがアプリ全体を巻き込む | **解決していない。トレードオフとして受け入れる**（下記） |

**さらに、単一プロセスにする積極的な理由が2つある。**

1. **メモリ。** 16GB機で2プロセスに分けると、UI側とモデル側の両方が常駐する。
   モデルの重み 4.6GB を持つプロセスを分離しても物理メモリは増えない。
   ページングが最大の雑音源であるこの機体（VISION）では、常駐を減らすこと自体が設計目標になる
2. **VISION 第1因子。** プロセス境界があると、トークンごとにシリアライズが挟まる。
   境界を消せばそのコストが丸ごと消える。**「そもそも無駄を送らない」に沿う**

#### (b) の代償を明示する

**MLX / Metal が異常終了すると、アプリごと落ちる。**
Electron の `utilityProcess` が持っていた隔離を失った。これは劣化である。

**対策: 会話は生成中も逐次 DB へ書く（第8章）。**
「推論エンジンの異常終了は、会話履歴を失わずに復帰できなければならない」という
v1.1 の要求そのものは維持する。**達成手段がプロセス分離から永続化に変わった。**

FR-02（中断しても既出力は消えない）と要求が一致しているため、実装は共通化できる。

### 3.2 Sendable 境界 — ここが唯一の型の境界である

**【確認済 / MLX_SWIFT 4.4】`Chat.Message` と `UserInput` は `Sendable` ではない。**
Swift 6 の strict concurrency で `Task` 境界を越えられず、実際にコンパイルエラーになることが確認されている。

```
error: sending 'input' risks causing data races
  note: task-isolated 'input' is passed as a 'sending' parameter
```

**したがって Sophia は自前の Sendable な型で境界を越える。**

```
[View / ViewModel]  ---- [SophiaMessage]（Sendable）---->  [MLXEngine actor]
                                                             │ ここで初めて
                                                             ▼ Chat.Message へ変換
                                                          UserInput / LMInput
```

| 層 | 使う型 |
|---|---|
| SwiftUI / ViewModel | `SophiaMessage`（4.1節）。`Chunk`。`GenerationStats` |
| エンジンの内部だけ | `Chat.Message` / `UserInput` / `LMInput` / `Generation` |
| 永続化（第8章） | `SophiaMessage` + 実測値のレコード型 |

**`Chat.Message` をエンジンの外へ出さない。引数でも戻り値でも渡さない。**
公式サンプル `LLMEval` がこの問題を踏まないのは、クラス全体が `@MainActor` で
`chat` をメソッド内のローカル変数として組み立てているからにすぎない【確認済】。
**Sophia のように層を分ける構成では、引数で渡した瞬間に壊れる。**

この境界は第8章の永続化モデルからの変換と自然に一致する。**変換コードは1か所に集約する。**

### 3.3 起動時の初期化

| 順 | やること | 根拠 |
|---|---|---|
| 1 | `MLX.Memory.cacheLimit = 20 * 1024 * 1024` | **公式サンプル LLMEval / LLMBasic / MLXChatExample の3つとも同じ値**【確認済 / MLX_SWIFT 8.1】。「LLMは20MB」が事実上の推奨 |
| 2 | ウィンドウを出す。**モデルのロードを待たない** | ロードは秒単位かかる。第1章の原則2 |
| 3 | モデルのロードを別 Task で開始し、進捗を出す | 初回はダウンロード 4.62GB（第7章） |
| 4 | `MLX.GPU.deviceInfo()` / `maxRecommendedWorkingSetBytes()` を記録 | FR-08 の推奨判定（7.3節）と、ベンチの環境記録 |

**`GPU.set(cacheLimit:)` は非推奨。`Memory.cacheLimit` を使う**【確認済 / MLX_SWIFT 8.1。ビルド時に deprecation 警告が出ることを実測】。

### 3.4 ビルド経路 — `swift build` ではアプリが完成しない

**【確認済 / MLX_SWIFT 10.3】`swift build`（SwiftPM CLI）では `.metallib` が1つも生成されない。**
実際にビルド成果物を検索して不在を確認している。`mlx-swift` の README にも明記がある。

| コマンド | 用途 |
|---|---|
| `xcodebuild build -scheme Sophia -destination 'platform=OS X'` | **これが正。** Metal シェーダが `mlx-swift_Cmlx.bundle` に入る |
| Xcode の GUI ビルド | 同上 |
| `swift build` | **型検査の高速確認としてのみ。** 差分再ビルド約1秒【実測 / MLX_SWIFT 10.2】は有用 |

**【実測 / MLX_SWIFT 10.2】初回ビルド 5分34秒 / `.build` 1.4〜1.5GB。**
「開発機を強化しない」原則（VISION）に直接ぶつかる。クリーンビルドを避けること。

---

## 4. 推論エンジンの抽象化

要件 **NFR-09**。そして**第1章の原則1と原則4が同居する層**である。

### 4.1 protocol と共通型【設計案 / 未確認】

```swift
// Sophia/Core/Inference/InferenceEngine.swift

/// 会話1発言。**Sendable であることがこの型の存在理由**（3.2節）。
public struct SophiaMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public var role: Role
    public var content: String
    /// 思考モードの出力（第6章）。**エンジンへ送り返さない。**
    /// 過去の思考を再送するとプリフィルが無駄に膨らむ（第2.2章）。
    public var thinking: String?
}

/// 生成中に流れてくる断片。思考と本文を型で区別する。
public enum Chunk: Sendable {
    case thinking(String)
    case content(String)
    case done(GenerationStats)
}

/// **1回の生成の「力加減」をここに集約する**（4.5節①）。
/// View から個別のグローバル設定を読ませない。切替点を1か所に固定するための型。
public struct ChatOptions: Sendable {
    public var temperature: Float = 0.7
    public var topP: Float = 0.8
    public var topK: Int = 20
    public var maxTokens: Int = 2048

    /// 思考モード（FR-18 / 第6章）。true のとき maxTokens を自動的に引き上げる
    public var thinking: Bool = true

    // --- 以下は A1 では既定値のまま。**フィールドだけ先に開けておく**（4.7節） ---

    /// 思考トークンの予算。VISION「予算の9割」への直接の道具【MLX_SWIFT 6.6 / main のみ】
    public var thinkingBudget: Int? = nil
    /// KVキャッシュ制御【MLX_SWIFT 8.3】。16GB機のメモリ逼迫に効く見込み
    public var maxKVSize: Int? = nil
    public var kvBits: Int? = nil
    /// 層ごとの計測を有効にするか（4.5節③）。素の MLXEngine は無視する
    public var instrument: Bool = false
}

public struct EngineCapabilities: Sendable {
    public var thinking: Bool
    public var maxContext: Int
    /// 思考モードを OFF にできるか。DeepSeek-R1 系は不可【確認済 / MLX_SWIFT 6.3】
    public var canDisableThinking: Bool
    /// 層ごとの計測に対応しているか（4.5節③）。MLXEngine は false
    public var instrumented: Bool
}

public protocol InferenceEngine: Actor {
    func listModels() async throws -> [ModelInfo]
    func load(_ modelId: String,
              onProgress: @Sendable @escaping (Double) -> Void) async throws
    /// 生成。**中断は返された Stream を消費する Task の cancel で行う**（5.3節）
    func chat(_ messages: [SophiaMessage],
              options: ChatOptions) async throws -> AsyncStream<Chunk>
    func unload() async
    var capabilities: EngineCapabilities { get }
}
```

#### v1.1 の TypeScript から変わった点

| v1.1（TypeScript） | v2.0（Swift） | 理由 |
|---|---|---|
| `signal: AbortSignal` を `ChatOptions` に持つ | **消した** | Swift の Task cancellation は構造化されており、呼び出し側の `Task` を cancel すれば伝播する。**型に持たせる必要が無い**【確認済 / MLX_SWIFT 第5章: 生成ループが `while !Task.isCancelled`】 |
| `Chunk` が `{ kind, text }` のタグ付きユニオン | `enum Chunk` | Swift の enum が同じ役割を果たす。**思考と本文を型で分ける設計判断は変わらない** |
| `numCtx: number` | `maxKVSize` / `maxContext` | Ollama の `num_ctx` に相当する単一のつまみが MLX には無い。KVキャッシュ側の制御に置き換わる |
| `interface InferenceEngine` | `protocol InferenceEngine: Actor` | 実装を actor に限定し、モデルの状態（ロード済みか、生成中か）への同時アクセスをコンパイラに守らせる |

**`Chunk` で思考と本文を型レベルで分けているのが設計の要点。**（v1.1 から変わらない）
実測どおり思考は本文の10倍量が流れるため、混ぜて扱うと UI もトークン計算も破綻する。
**MLX では分離をアプリ側が行う**点が Ollama と決定的に違う（第6章）。

### 4.2 実装の一覧

| 実装 | 使用時期 | 中身 |
|---|---|---|
| `MockEngine` | A1 の初日〜 | モデルをロードせず、記録した応答を等間隔で流す。**UI とストリーミングを推論の都合から切り離す**（REQUIREMENTS 第8章の意図をそのまま引き継ぐ） |
| **`MLXEngine`** | **A1〜配布まで** | `mlx-swift-lm` の**低レベルAPI**（`ModelContainer.generate`）。5.3節の理由で `ChatSession` を使わない |
| `InstrumentedMLXEngine` | A2以降 | `Qwen3.swift` を複製・改造し `ModelTypeRegistry.registerModelType` で登録。層ごとの計測・早期終了（4.5節③） |

**`OllamaEngine` と `LlamaCppEngine` は廃止。**
v1.1 の「開発時 Ollama / 配布時 llama.cpp」という二段構えは、
**MLX が開発時も配布時も同じであるため不要になった。**
配布時に初めて別実装へ差し替える、という v1.1 最大のリスク（第12章 #1）もここで消える。

> **Ollama は A0 の計測基盤としては残る。** `scripts/bench.py` / `make bench` と
> `modelfiles/` は第2章の実測値の出所であり、MLX との比較対象として価値がある。
> **アプリからは呼ばない。**

### 4.3 A1 で使う生成コード【MLX 側 API は確認済 / 組み合わせは未確認】

```swift
// MLXEngine 内部。ここが唯一 Chat.Message に触れる場所（3.2節）
let chat: [Chat.Message] = messages.map {
    switch $0.role {
    case .system:    .system($0.content)
    case .user:      .user($0.content)
    case .assistant: .assistant($0.content)   // thinking は送り返さない（第2.2章）
    }
}
let input  = UserInput(chat: chat, additionalContext: ["enable_thinking": options.thinking])
let lmInput = try await container.prepare(input: input)
let params = GenerateParameters(maxTokens: options.maxTokens,
                                temperature: options.temperature,
                                topP: options.topP, topK: options.topK)
let stream = try await container.generate(input: lmInput, parameters: params)
```

**【確認済 / MLX_SWIFT 4.3】上記の MLX 側 API はコンパイルを通している。**

### 4.4 解剖可能性 — なぜ推論層に組み込むのか（第1章 原則4）

**Ollama を捨てて MLX を選んだ理由が、この節に集約される。**

[VISION.md](VISION.md) は 1/1000 を4つの因子に分解している。そのうち
**第2因子（難易度に応じたモデル選択）と第3因子（全部を起動しない）は、
推論の内側に手が入らないと着手すらできない。**

| | Ollama（HTTP API） | MLX Swift |
|---|---|---|
| 層のループ | **見えない** | **素の Swift `for` ループ**【確認済 / MLX_SWIFT 7.3】 |
| サンプリングへの介入 | API が公開する範囲のみ | `LogitProcessor` プロトコル【確認済】 |
| モデル実装の差し替え | 不可 | `ModelTypeRegistry.registerModelType` が public。両リポジトリとも MIT【確認済】 |
| 生成ごとのメモリ推移 | 取れない | `MLX.Memory.snapshot()`（`Codable`）【確認済】 |

**A1 でこれらを実装する必要はない。**
本節の要件は **「A1 の作りが、後から手を入れる道を塞がないこと」** である。

#### 何が「塞ぐ」ことになるのか

| 塞いでしまう作り | なぜ塞がるか |
|---|---|
| 生成を `ChatSession` に全面依存させる | 履歴管理・KVキャッシュ・トークンイテレータがライブラリの内側に入る。**プロンプトの組み立てにもサンプリングにも手が届かなくなる** |
| `ModelContainer` を ViewModel が直接持つ | 実装を差し替える穴が無くなる。素の実装と解剖版を並べて A/B できない |
| 計測を「UIに出す4つの数値」として定義する | 層ごとの値・メモリ推移・停止理由を持つ場所が型に無い。**後から全層を書き換えることになる** |
| 力加減のつまみを View や設定画面に散らす | 「この生成にどれだけ払ったか」が1か所で決まらない。適応度関数（VISION）の入力を再構成できない |

### 4.5 3つの解剖点 — どこに何を置くか

```
  ChatOptions ─────────────┐  ① 力加減の切替（VISION 第2因子）
                           │     思考ON/OFF・モデル規模・生成上限・KV量子化
                           ▼
  MLXEngine.chat(...)  ──▶ GenerateParameters
                           │
                           ├─ LogitProcessor ──── ② サンプリング層のフック
                           │                        確信度による打ち切り・思考予算
                           │                        （VISION 第3因子の浅い側）
                           ▼
                    TokenIterator
                           │
                           ▼
                    Qwen3Model.callAsFunction
                      for (i, layer) in layers.enumerated() {   ③ 層ループの内側
                          h = layer(h, mask: mask, cache: cache?[i])   （第3因子の本丸）
                      }                                          層ごとの計測・早期終了
```

| # | 解剖点 | VISION の因子 | 置き場所 | A1 での扱い |
|---|---|---|---|---|
| ① | **力加減の切替** | 第2因子 | `ChatOptions`（4.1節）と `ModelSelection`（7.3節） | **思考ON/OFF と `maxTokens` のみ実装。**他はフィールドを用意して既定値のまま |
| ② | **サンプリング層のフック** | 第3因子（浅い側） | `LogitProcessor`【確認済】。`main` なら `GenerationComponents.appendingLogitProcessor`、3.31.4 なら `TokenIterator` を自前で組む | **実装しない。**低レベルAPIを使うことで穴だけ残す |
| ③ | **層ループの内側** | 第3因子（本丸） | `Qwen3.swift` を複製・改造し `registerModelType("qwen3", ...)` | **実装しない。**`InferenceEngine` protocol を挟むことで、後から `InstrumentedMLXEngine` を並べられるようにする |

**③ には未解決の課題がある。【未確認 / MLX_SWIFT 7.3】**
MLX は遅延評価のため、`for` ループに時刻を挟むだけでは層ごとの実時間を測れない。
各層の後に `eval(h)` を差し込めば同期できるが、**それ自体がパイプラインを壊して測定値を歪める。**
`GPU.startCapture(url:)` が代替になる可能性があるが未検証。

> **VISION 第3因子に着手する前に、この計測方法の確立が必要である。**
> 第12章のリスク表に独立した項目として立てた。**A1 で解決しようとしないこと。**

### 4.6 計測をどう持つか

**`GenerationStats` は「UIに出す値」ではなく「1回の生成の観測記録」として定義する。**
FR-14（利用者への表示）はその一部を使うにすぎない。

```swift
public struct GenerationStats: Sendable, Codable {
    // --- 待ち時間。2つ持つ（第2.3章 / MLX_SWIFT 7.2）---
    public var ttftMs: Int            // 最初の出力まで。思考ONなら思考の1文字目
    public var ttfrMs: Int?           // 本文の1文字目まで。思考OFFなら ttftMs と一致
    // --- 速度 ---
    public var promptTokensPerSecond: Double
    public var tokensPerSecond: Double
    // --- 量 ---
    public var inputTokens: Int
    public var outputTokens: Int
    public var thinkingChars: Int     // 第2.1章の未解決（文字数 vs トークン数）を解くための列
    // --- 終わり方 ---
    public var stopReason: StopReason // .stop / .length / .cancelled / .error
    // --- 条件 ---
    public var modelId: String
    public var thinkingEnabled: Bool
    // --- 環境 ---
    public var peakMemoryBytes: Int?  // MLX.Memory.snapshot()【確認済 / MLX_SWIFT 8.1】
    /// 層ごとのコスト。**A1 では常に nil。**
    /// 値の定義そのものが未解決（4.5節③）だが、**型を先に開けておく**
    public var layerTimings: [LayerTiming]? = nil
}
```

| 判断 | 理由 |
|---|---|
| **TTFT を2つ持つ** | 第2.3章の達成判定が「本文の1文字目」で定義されている。**2つの差が思考モードのコストそのもの**であり、VISION の適応度関数（品質÷消費エネルギー）の材料になる |
| **`Codable` にする** | 同じ値を DB（第8章）と [BENCH_RESULTS.md](BENCH_RESULTS.md) の両方へ流す。**ベンチと実利用の数値が同じ型であることに意味がある**（合成プロンプトと実作業のずれを後から検証できる） |
| **中断時・失敗時も必ず記録する** | 「測ることを続ける」（VISION 当面の指針1）。`stopReason` があるのはそのため |
| **`layerTimings` の型を先に置く** | 埋めるのは A2 以降。**型が無いと、後から全層を書き換えることになる**（4.4節） |

**`.info(GenerateCompletionInfo)` は最後に1回しか来ない**【確認済 / MLX_SWIFT 7.2】。
TTFT / TTFR はストリームを消費する側の壁時計で測る。`.info` からは
`promptTokenCount` / `promptTokensPerSecond` / `tokensPerSecond` / `stopReason` を取る。

### 4.7 A1 で守る4つの約束

**これだけ守れば、A2 以降で解剖に着手できる。逆に、どれか1つでも破ると構造の作り直しになる。**

1. **`ChatSession` を使わない。** 低レベルの `ModelContainer.generate` で組む
   （5.3節の中断要件とも一致する）
2. **エンジンは `InferenceEngine` protocol の背後に置く。** View / ViewModel から
   `ModelContainer` や `MLXLLM` の型を直接触らない
3. **`ChatOptions` に1回の生成の力加減を全部集める。** View が個別のグローバル設定を
   直接読んで生成を呼ばない
4. **`GenerationStats` を全生成で必ず記録する。** 中断時も、エラー時も

---

## 5. ストリーミング

### 5.1 経路 — IPC が消えた

```
[SwiftUI View]
   │ 送信ボタン
   ▼
[ChatViewModel @MainActor]
   │ generationTask = Task { ... }
   ▼
[MLXEngine actor]  ──> AsyncStream<Chunk>
   │
   └─> for await chunk in stream { }   ← @MainActor に戻して View の状態を更新
```

**v1.1 の `MessagePort` / `preload` / `contextBridge` / `ipcRenderer` はすべて不要になった。**
プロセス境界が無いため、`Chunk` は同一プロセス内の値渡しである。

| v1.1 の制約 | v2.0 |
|---|---|
| 構造化複製（structured clone）可能な型しか渡せない | **消えた。**関数もクロージャも渡せる |
| トークン1つごとに IPC 往復のオーバーヘッド | **消えた** |
| — | **代わりに `Sendable` の制約が来る**（3.2節） |

### 5.2 描画の間引き — 前提が変わった

v1.1 は「トークンごとに React を再描画すると重い」ので 16ms バッファを設計していた。

**この前提を再検討する必要がある。**

- 生成は 7〜13.4 tok/s【実測 / 第2章】。**チャンクは概ね 75〜140ms に1回**しか来ない。
  60fps（16.7ms）を大きく下回る頻度であり、**コアレスの必要性は薄い**
- **【確認済 / MLX_SWIFT 4.1】1トークン = 1 `.chunk` ではない。**
  デトークナイザが Unicode 境界で出力を保留するため、`.chunk` が出ない回・まとめて出る回がある。
  日本語のマルチバイト分割は処理済みで、文字化けした断片は画面に出ない
  → **FR-01「1トークンずつ逐次表示」は「トークンが確定するたびに逐次表示」と読み替える。**
    体感上の逐次性は保たれる

**代わりに SwiftUI 固有の別問題がある。【未確認】**
本文を1つの `String` に append し続けると、`Text` は更新のたびに全文を再レイアウトする。
**生成が進むほど1回の更新が重くなる**（長さに対して超線形になりうる）。

対策の候補（**A1 では最初から入れない**）:

| 案 | 内容 |
|---|---|
| (a) | 確定した段落と、末尾の未確定部分を分けて持ち、末尾だけを更新する |
| (b) | `NSTextView` を `NSViewRepresentable` で使い、末尾に追記する |

**まず素朴に実装し、生成の後半で `tokensPerSecond` が落ちるかを見る。**
落ちるなら描画が推論を食っている。**第2章の測定原則で判定できる問題であり、
推測で先回りしない。**

### 5.3 中断（FR-02）

```swift
// ChatViewModel
func stop() { generationTask?.cancel() }
```

**【確認済 / MLX_SWIFT 第5章】Task cancellation で止まる。**
生成ループが `while !Task.isCancelled` であり、ストリームを consumer が捨てた場合も
`continuation.onTermination` から内部 Task がキャンセルされる。

**既に生成された分は破棄せず保存する。**（v1.1 から変わらない設計判断）
利用者が中断するのは「もう十分」か「方向が違う」のどちらかで、前者では出力が要る。

**【確認済 / MLX_SWIFT 第5章】これが `ChatSession` を使わない理由である。**
`ChatSession` は `AssistantGeneration.shouldRecord` が `stopReason != .cancelled` を要求しており、
**キャンセルされたターンを履歴に記録しない。** FR-02 と真正面から衝突する。
→ **A1 は低レベルAPI（`ModelContainer.generate`）で組む。**（4.7節の約束1）

#### 実装上の注意【確認済 / MLX_SWIFT 第5章の原文コメントより】

1. **ストリームを `break` で抜けても、計算は数ミリ秒続く。**
   連続利用時は `generateTask(...)` を使って終了を観測する
2. キャンセル判定は `iterator.next()` の**前**に置かれている。
   `next()` が次のGPU評価を先行投入（`asyncEval`）するため。
   アプリがバックグラウンドにあると
   `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted` で落ちる経路がある
3. **中断時も `GenerationStats` を記録する。** `stopReason = .cancelled`（4.6節）。
   UI にも経過秒数を残す（[UI_SPEC.md](UI_SPEC.md) 10.2-#13）

### 5.4 バックプレッシャ【未確認】

`AsyncStream` は MLX 側が生成する。消費側（`@MainActor`）が詰まるとチャンクが溜まり、
**表示が実際の生成より遅れる**可能性がある。バッファリング方針を Sophia 側で指定できるかは
確認していない。5.2節の計測と合わせて A1 で観察する。

---

## 6. 思考モードの扱い（第2.1章の実測に基づく）

**設計判断: 思考を隠さず、専用の表示領域を与える。**（v1.1 から変わらない）

| 案 | 判断 |
|---|---|
| 思考モードを常に無効化 | ❌ 難しい問いでの品質が落ちる。モデルの能力を捨てることになる |
| 思考も本文と同じ流れに混ぜて表示 | ❌ 本文が1割しかないため、読み手が答えを見つけられない |
| **思考を折りたたみ領域に分けて表示** | ✅ **採用**。15秒が「無反応」ではなく「思考中」に変わる |

実装:

- 生成開始と同時に**思考領域を表示し、思考テキストを流す**。無言の待機時間をゼロにする
- 本文が始まったら思考領域を自動的に折りたたむ。再展開は可能
- 会話ごとに**思考モードのON/OFFを切替可能**にする（FR-18）。
  短い質問では無効の方が体感が圧倒的に速い（実測 TTFT 15.4s → 0.2s 相当）
- **思考モード有効時は `maxTokens` を自動的に引き上げる**。
  実測どおり予算の9割を思考が使うため、既定値のままでは本文に到達せず打ち切られる
- 思考テキストは `messages.thinking` に本文と分けて保存する（第8章）
- **完了後のラベルに所要時間を出す**（「49秒間の思考」）。中断時も経過秒数を残す
  （[UI_SPEC.md](UI_SPEC.md) 10.1-#9 / 10.2-#13）

### 6.1 Ollama と MLX で何が変わるか（**この章の追記の中心**）

| | Ollama | MLX Swift |
|---|---|---|
| `<think>` の分離 | **サーバが `thinking` フィールドへ分離してくれた** | **`.chunk` に生テキストとして混ざって出る**【確認済】 |
| チャットテンプレートの適用 | サーバ | **クライアント（トークナイザ）**【確認済 / MLX_SWIFT 6.2】 |
| ON/OFF | API パラメータ | `additionalContext: ["enable_thinking": Bool]`【確認済】 |

**FR-17 の分離は、Sophia 自身の責務になった。**
【確認済】公式サンプル `LLMEval` はこの分離をしておらず、`<think>` が画面にそのまま出る。

### 6.2 分離の実装 — 2つの道がある

**【確認済 / MLX_SWIFT 1.2】版の選択が要る。どちらでも FR-17 は満たせる。**

| 道 | 使うもの | 長所 | 短所 |
|---|---|---|---|
| **A（推奨）** | `main` を revision 固定し、`ReasoningEventEmitter` を使う | 公式実装。**単体テストと実モデル統合テストが付いている**。`ThinkingBudgetProcessor` とプリフィル進捗も同時に手に入る | `main` は毎日動く。`branch:` ではなく `revision:` で固定し `Package.resolved` を commit すること |
| B | タグ 3.31.4 + 自作 `ThinkSplitter` | リリース版のみを使う方針を保てる | チャンク境界をまたぐ区切り文字など地雷がある。**コード自体は MLX_SWIFT 6.5 にコンパイル確認済みのものがある** |

**本書の推奨は A。** 理由は FR-17 の中核部品に加え、
VISION に直接効く `ThinkingBudgetProcessor`（6.4節）と、
第2.4章の「無反応の1.5秒」を潰すプリフィル進捗が `main` にしか無いため。

いずれの場合も、Sophia 側は `ReasoningSplitter` という自前の入口を1つ持ち、
**内部で公式 API か自作かを切り替える。** 版を替えても呼び出し側が壊れないようにする。

```swift
// エンジン内部。分離してから Chunk に載せ替える
for await item in stream {
    guard case .chunk(let text) = item else { continue }
    for segment in splitter.process(text) {
        switch segment {
        case .reasoning(let s): continuation.yield(.thinking(s))
        case .response(let s):  continuation.yield(.content(s))
        }
    }
}
for segment in splitter.finalize() { /* 残り */ }
```

**【確認済 / MLX_SWIFT 6.4】Qwen3 の `primedInside` は `false`。**
Qwen3 のテンプレートは `<think>` を先出しせず、モデルがストリーム中に自分で出す。
**`true` にすると全崩壊する。** DeepSeek-R1 系は逆に `true`。
汎用に書くなら `promptEndsInsideReasoning(renderedPromptTail:config:)` で判定する。

### 6.3 ON/OFF（FR-18）

```swift
// 直接指定（3.31.4 / main 共通）【確認済】
UserInput(chat: chat, additionalContext: ["enable_thinking": enabled])
```

**`main` を使うならモデルの宣言から導出する方が壊れにくい**【確認済 / MLX_SWIFT 6.3】。
`ReasoningPromptStrategy` が `.templateFlag(key:defaultOn:)` / `.alwaysOn` / `.none` を区別し、
OFF にできないモデルへ OFF を要求すると `ReasoningError.cannotDisableReasoning` を投げる。
**モデルを差し替えたときに壊れない**（第1章の原則1）。
`EngineCapabilities.canDisableThinking`（4.1節）はこの値を UI へ渡すための列である。

### 6.4 思考の予算制御（A2以降 / VISION 直結）

**【確認済 / MLX_SWIFT 6.6 / main のみ】`ThinkingBudgetProcessor`（`LogitProcessor` 実装）がある。**
思考トークンが上限に達するとロジットをマスクし、
Qwen3 公表の早期打ち切り文＋`</think>` へ安全に遷移させる。

v1.1 の「思考ONなら `maxTokens` を引き上げる」は**予算を増やす**方向の対策だった。
これは**予算に上限を設ける**逆方向の道具である。**両方要る。**

- 引き上げ … 本文に到達しないまま打ち切られる事故を防ぐ（第2.1章）
- 上限 … 「予算の9割が思考」を許容しない（VISION）

**A1 のスコープ外。** `ChatOptions.thinkingBudget`（4.1節）にフィールドだけ用意する。

---

## 7. モデル管理

### 7.1 配置

| 対象 | 場所 | 理由 |
|---|---|---|
| モデル本体（**MLX形式のディレクトリ**） | `Application Support/Sophia/Models/<repo-id>/` | アプリ更新で消えない。アンインストール時に一緒に消せる |
| 会話履歴DB | `Application Support/Sophia/sophia.db` | 同上 |

Swift では `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, ...)`
で取る。Electron の `app.getPath('userData')` の置き換えにあたる。

> **サンドボックス下では実体が変わる。**【未確認】
> `com.apple.security.app-sandbox` を有効にすると（第11章）、実体は
> `~/Library/Containers/<bundle-id>/Data/Library/Application Support/Sophia/` になる。
> **`#hubDownloader()` の既定キャッシュ（`~/.cache/huggingface`）もコンテナ内に落ちるはずだが、確認していない。**
> A1 で実際のパスを確認し、本節に追記すること。

**アプリ本体にモデルを同梱しない**（NFR-06）。4.62GB を `.app` に入れると
配布サイズ・公証時間・更新コストがいずれも現実的でなくなるため、初回起動時に取得する（FR-07）。

#### GGUF から MLX形式へ — 何が変わるか

**【確認済 / MLX_SWIFT 2.1】GGUF は使えない。**
`MLX.loadArrays(url:)` は `.safetensors` しか受け付けず、C++層の `load_gguf` は Swift に露出していない。

| | v1.1（GGUF） | v2.0（MLX形式） |
|---|---|---|
| 実体 | 単一ファイル | **ディレクトリ**。`config.json` / `*.safetensors` /（複数なら `model.safetensors.index.json`）/ `tokenizer.json` 一式 |
| Qwen3-8B の 4bit | 約 5.2GB（Q4_K_M） | **4.62GB**【確認済】 |
| sha256 検証（NFR-08） | ファイル1つ | **ファイルごと。マニフェストが要る**（8.2節） |
| `modelfiles/` の資産 | そのまま使えた | **A1 では使わない。** Ollama 用に残す |
| トラックBの成果物 | GGUF へ変換していた | **MLX形式で出す**（第10章） |

### 7.2 取得

**【確認済 / MLX_SWIFT 2.3】3つの経路がある。すべてコンパイル確認済み。**

| 経路 | 使いどころ |
|---|---|
| (A) `#huggingFaceLoadModelContainer(configuration:)` | 最短。進捗が要らない場面 |
| **(B) `loadModelContainer(from:using:configuration:progressHandler:)`** | **A1 はこれ。** FR-07 の進捗表示 |
| (C) `loadModelContainer(from: URL, using:)` | **完全オフライン。ローカルディレクトリのみを読む** |

> **(C) は NFR-01 に対する構造的な保証になる。【確認済】**
> ローカル読み込みだけにすれば `com.apple.security.network.client` entitlement を外せる。
> **「会話を外部に出さない」を、実装の約束ではなく OS の権限として保証できる。**
> 初回のモデル取得を別手段にできるなら極めて強い。**A2 以降の有力な検討材料**（第11章）。

**マクロを使う場合、利用側に `import HuggingFace` と `import Tokenizers` が要る**【確認済 / MLX_SWIFT 2.4】。
忘れると意味不明なコンパイルエラーになる。

#### v1.1 から持ち越す要件と、未確認の穴

| v1.1 の要件 | v2.0 での扱い |
|---|---|
| HTTP Range によるレジューム（NFR-10） | **`swift-huggingface` の `HubClient` がレジューム対応かは【未確認】。** 対応していなければ自前で作る。A3 で判断 |
| 一時ファイルへ落とし、検証後に改名（NFR-08） | **ディレクトリ単位になる。**「検証前のものを正規のモデルとして読ませない」という要求は維持する |
| 空き容量の事前確認 | 維持。必要量 4.62GB を明示して中止する |

### 7.3 推奨モデルの判定（FR-08）

`ProcessInfo.processInfo.physicalMemory` から判定する（`os.totalmem()` の置き換え）。
閾値の根拠は [TUNING.md](TUNING.md) の予算表。

| 搭載メモリ | 推奨 | `LLMRegistry` の定数【確認済】 | 備考 |
|---|---|---|---|
| 8GB以下 | 3〜4B | `qwen3_1_7b_4bit` / `qwen3_4b_4bit` | 動作優先 |
| 16GB | **7〜8B** | **`qwen3_8b_4bit`** | 開発機と同条件。実測値がそのまま目安になる |
| 32GB以上 | 14B以上 | `qwen3MoE_30b_a3b_4bit` 等 | |

推奨外のモデルも選択可能にするが、**選択時に速度低下の可能性を明示**する。

> **MLX ではより正確な指標が取れる。【確認済 / MLX_SWIFT 8.1】**
> `MLX.GPU.maxRecommendedWorkingSetBytes()` は「GPU に載せてよい量」を OS が答える値であり、
> 搭載メモリ総量より実態に近い。**両方を記録し、A1 の実測で判定式を決める。**

#### 力加減としてのモデル規模（VISION 第2因子 / 4.5節①）

`LLMRegistry` には `qwen3_0_6b_4bit` から `qwen3_8b_4bit` まで7つの定数がある【確認済】。
**「こんにちは」に8Bを使わない**ための材料が既に揃っている。

**A1 では実装しない。** ただし FR-08 の推奨判定と第4章の `ModelSelection` を
**「起動時に1回決める設定」ではなく「1回の生成ごとに決まる値」として設計する。**
起動時固定にすると、後からルーティングを足すときに全経路を書き換えることになる（4.4節）。

### 7.4 メモリ見積り【一部確認済 / 合計は未確認】

| 項目 | 見積り | 確度 |
|---|--:|---|
| 重み（Qwen3-8B-4bit） | 4.6 GB | **【確認済】** |
| KVキャッシュ（8k コンテキスト） | 約 0.7 GB | 【未確認】 |
| MLX バッファキャッシュ | 0.02 GB | **【確認済】**（`cacheLimit` 設定時） |
| SwiftUI シェル | 約 0.05 GB | 【未確認】 |
| **合計** | **約 5.4 GB** | 【未確認】 |

[TUNING.md](TUNING.md) の「モデルに回せる実質枠 約9〜10GB」に収まる。
**Electron（約300MB）と Ollama サーバが消えた分、条件は Ollama 構成より良い。**

**楽観はできない。** この機体は空き0.5〜2.8GB・スワップ6〜7GB使用であり、
VISION が記録した「ページングで最大4.9倍」はそのまま残る。**MLX に変えても物理メモリは増えない。**

KVキャッシュの圧縮（`kvBits` / `kvScheme = "turbo8v3"`）は A2 以降の削減余地
【確認済 / MLX_SWIFT 8.3。品質への影響は未測定】。

---

## 8. データモデル（SQLite）

**スキーマは v1.1 から維持する。** 以下は生SQL であり、**これが一次情報である。**

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
```

`messages` に実測値を持たせているのは、**設定変更の効果を実利用のログから確認できるようにする**ため。
ベンチは合成プロンプトなので、実作業での傾向とはずれる。

FR-13（全文検索）は後から FTS5 の仮想テーブルを追加して対応する。

### 8.1 GRDB.swift での実装方針

| 判断 | 内容 |
|---|---|
| **生SQL を保つ** | `DatabaseMigrator` の各マイグレーションで上の SQL をそのまま `execute` する。**スキーマの一次情報が設計書であり続ける。** ORM の DSL に翻訳すると設計書と実装がずれ、どちらが正か分からなくなる |
| 接続 | `DatabaseQueue`（単一書き込み）。A1 の負荷では `DatabasePool` は要らない |
| 隔離 | `actor Store` で包む（第3章）。`@MainActor` から `await` で呼ぶ |
| レコード型 | `Codable` + `FetchableRecord` / `PersistableRecord`。`SophiaMessage`（4.1節）とは別の型にし、**変換を1か所に集める**（3.2節と同じ方針） |
| 全文検索（FR-13 / A3） | GRDB の FTS5 サポートで `messages` の外部コンテンツ仮想テーブルを足す |

### 8.2 第7章の MLX形式化に伴う `models` テーブルの改訂

**v1.1 の `models` テーブルは GGUF 単一ファイルを前提にしていたため、改訂が必要である。**

```sql
-- 改訂前（v1.1）: filename と sha256 が単数だった
-- 改訂後: MLX形式は複数ファイルのディレクトリ（第7.1節）
CREATE TABLE models (
  id               TEXT PRIMARY KEY,   -- 例 'mlx-community/Qwen3-8B-4bit'
  directory        TEXT NOT NULL,      -- Application Support 配下の相対パス
  total_bytes      INTEGER NOT NULL,
  downloaded_bytes INTEGER NOT NULL DEFAULT 0,
  state            TEXT NOT NULL
                   CHECK (state IN ('pending','downloading','ready','corrupt'))
);

-- NFR-08（sha256 検証）はファイル単位になる
CREATE TABLE model_files (
  model_id   TEXT    NOT NULL REFERENCES models(id) ON DELETE CASCADE,
  path       TEXT    NOT NULL,         -- ディレクトリ内の相対パス
  sha256     TEXT    NOT NULL,
  size_bytes INTEGER NOT NULL,
  PRIMARY KEY (model_id, path)
);
```

### 8.3 実測値の列を広げる（第4.6節と対応させる）

`GenerationStats`（4.6節）は v1.1 の4値より広い。**A3 の永続化で列を追加する。**

| 追加する列 | 何のため |
|---|---|
| `ttfr_ms` | 本文の1文字目まで。第2.3章の達成判定 |
| `prompt_tokens_per_sec` | プリフィル速度。第2章で「生成とは別の指標」と決めた |
| `thinking_chars` | **第2.1章の未解決（文字数 vs トークン数）を実利用のログから解く** |
| `stop_reason` | 中断・上限到達を後から数えられる。FR-02 の効き方の検証 |
| `thinking_enabled` | 思考ON/OFFの実際のコスト差を実ログから出す（VISION の適応度） |
| `peak_memory_bytes` | ページングとの相関。VISION が最大の雑音源とした問題 |

### 8.4 原ログを要約で上書きしない（VISION）

[VISION.md](VISION.md) は「完全なログを安く持てることが、大胆に要約する自由を支える」とし、
実用的な使用量で**年間およそ18MB**と見積もっている。

**設計上の約束: `messages` の `content` / `thinking` を、要約で置き換えない。**
文脈圧縮（A3以降）を実装するときは、要約を**別テーブル**に持つ。
理由は2つあり、どちらも VISION に書かれている。

1. 捨てたものが後で必要になったときに戻れる（要約の安全網）
2. **過去ログでのオフライン・リプレイ評価**が、遺伝的アルゴリズムの評価基盤になる

---

## 9. ディレクトリ構成とアセット

```
Sophia/
├── Sophia.xcodeproj/            # A1 で新規作成
├── Sophia/                      # アプリターゲット
│   ├── SophiaApp.swift          # @main。3.3節の初期化
│   ├── Sophia.entitlements      # 第11章
│   ├── Assets.xcassets/         # AppIcon（9.1節）
│   ├── Core/
│   │   ├── Inference/
│   │   │   ├── InferenceEngine.swift   # protocol と共通型（第4章）
│   │   │   ├── MLXEngine.swift         # MLX 実装（4.2節）
│   │   │   ├── MockEngine.swift        # UI 先行開発用（4.2節）
│   │   │   ├── ReasoningSplitter.swift # 思考の分離（6.2節）
│   │   │   └── Stats.swift             # GenerationStats（4.6節）
│   │   ├── Models/                     # モデル取得・配置・推奨判定（第7章）
│   │   └── Store/                      # GRDB（第8章）
│   ├── Features/
│   │   ├── Chat/                # ChatView / ChatViewModel / ThinkingPanel / Composer
│   │   └── Sidebar/
│   └── DesignSystem/            # 配色トークン・タイポグラフィ（9.2節）
├── SophiaTests/
├── assets/                      # ロゴ原画とアイコン生成物（9.1節）
├── modelfiles/                  # Ollama 用（A0 の資産。アプリからは使わない）
├── scripts/                     # bench.py / bench-prompt.py / make-icons.py / serve.sh
└── docs/
```

**`app/`（Electron 実装）は破棄予定。**
A1 でネイティブ側が起動するまでは参照用に残すが、**新しいコードを足さないこと。**

### 9.0 依存パッケージ

Xcode の **Package Dependencies** に4つ追加し、ターゲットへ
`MLX` / `MLXLLM` / `MLXLMCommon` / `MLXHuggingFace` / `HuggingFace` / `Tokenizers` をリンクする
【確認済 / MLX_SWIFT 1.3〜1.4】。

| パッケージ | 指定 |
|---|---|
| `ml-explore/mlx-swift-lm` | **`revision:` で固定**（6.2節の道Aなら `main` の特定コミット） |
| `ml-explore/mlx-swift` | `.upToNextMinor(from: "0.31.6")`。**`MLX`（`Memory` / `GPU`）は再輸出されないので直接書く** |
| `huggingface/swift-huggingface` | `from: "0.9.0"` |
| `huggingface/swift-transformers` | `from: "1.3.0"` |

- **`Package.resolved` を commit すること。**【確認済 / MLX_SWIFT 11.2】API が速い速度で変わっている
- **【確認済】MLX の二重リンクに注意。** `App → MLX` と `App → Framework → MLX` が
  同時に成立すると壊れる。ターゲットを分けるときに踏む
- 解決される依存は16パッケージ。**NFR-06（本体300MB以内）への影響は【未確認】**（第12章）

**最低 macOS バージョンは未決。**
`mlx-swift` / `mlx-swift-lm` はいずれも **macOS 14.0** で足りる【確認済 / MLX_SWIFT 第9章】。
REQUIREMENTS の NFR-07 も「macOS 14 以降」である。
一方 CLAUDE.md は macOS 15+ を想定と書いている。**SwiftUI 側で macOS 15 の API を使うかで決まる。
A1 で deployment target を確定し、本節に記録すること。**

### 9.1 アイコン

```
assets/
├── logo.png     元画像（1254x1254、正方形フルブリード）
├── icon.png     1024x1024。角が透明
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

**取り込み先が変わった。** electron-builder が `icon.icns` を参照する構成から、
**Xcode の `Assets.xcassets` の AppIcon へ入れる**構成になる。
`make icons` の生成物（`icon.iconset` / `icon.icns`）はそのまま使える。**【未確認】**
Xcode 26 の Icon Composer（`.icon` 形式）との関係は第12章のリスクとして残す。

### 9.2 配色

アプリUIの基準色。ロゴから抽出した実測値。**v1.1 から変わらない。**

| 役割 | 色 | 用途 |
|---|---|---|
| 背景（クリーム） | `#FEF5EB` | ライトテーマの地。アイコン背景 |
| 前景（チャコール） | `#434548` | 本文テキスト、ダークテーマの地 |
| 強調（テラコッタ） | `#D08256` | アクセント、リンク、生成中インジケータ |

テラコッタは彩度が高いため**面積を持たせない**。文字と細い要素に限定し、
広い面はクリームとチャコールで構成する。

**詳細は [UI_NATIVE.md](UI_NATIVE.md) 第4.3節が正。**
ライト／ダークで「クリームとチャコールが地と墨の役割を交換する」設計と、
WCAG 2.1 で算出したコントラスト比の表がそこにある。
**この計算値は CSS に依存しないため、SwiftUI でもそのまま有効である。**

- ライトのアクセントは `#A85426`（4.92:1）。**`#D08256` は 2.78:1 で文字に使えない**
- ダークの地は `#1C1D1F`、アクセントは `#D08256`（5.63:1）のまま使える
- 墨と罫線は「原色 + アルファ」で定義する（macOS 自身がその方式）

### 9.3 UI_NATIVE.md / UI_SPEC.md の有効範囲【重要】

**[UI_NATIVE.md](UI_NATIVE.md) は Electron 前提で書かれている。しかし全部が無効になったわけではない。**
節ごとに扱いを決めておく。

| UI_NATIVE.md の節 | ネイティブ版での扱い |
|---|---|
| **第4.3節 カラートークンとコントラスト比** | **そのまま有効。** WCAG の計算値であり実装技術に依存しない。CSS 変数を SwiftUI の `Color` 定義へ移す |
| **第5章 HIG の数値（AppKit 実測）** | **そのまま有効。** `NSFont` / `NSButton` / `NSSplitViewItem` を直接測った値であり、**むしろ SwiftUI の方が素直に使える**（コントロール高 24pt、サイドバー 240/140/250、余白 4の倍数、タイトルバー 32/52） |
| 第3.5節 フォントサイズ表 | **有効。** ただし `@font-face` は不要。SwiftUI は `.font(.system(size: 13))` で、日本語のフォールバックは AppKit が `.HiraKakuInterface-W4` を使う【UI_NATIVE 3.3 の実測】。**Chromium が W3 に落とす問題は起きない** |
| 第2章 vibrancy / トラフィックライト | **手段が変わる。** `NSVisualEffectView`（`NSViewRepresentable`）または SwiftUI の material。**「1ウィンドウ1材質」という Electron の制約は消える** |
| 第3.1〜3.4節 Chromium のフォント解決 | **無効。** `-apple-system` が効かない等は Chromium 固有の問題 |
| 第6章 Menu / dialog / contextMenu | **手段が変わる。** SwiftUI の `.commands` / `.confirmationDialog` / `.contextMenu`。**「role: editMenu を省くと Cmd+C が効かない」に相当する落とし穴が SwiftUI にもあるかは【未確認】** |
| 第7章 やってはいけないこと | **大半が有効。** 特に 7.6「Web の寸法感を持ち込む」は SwiftUI でも同じ罠 |
| 第8章 現状コードとの差分 | **無効。** `app/` に対する申し送りであり、破棄対象 |

**[UI_SPEC.md](UI_SPEC.md) は全体がそのまま有効。**
Open WebUI の DOM を観察した寸法・状態遷移の記録であり、実装技術と無関係である。
特に第10章（借りる／借りない）は A1 の UI 判断の一次情報として使う。

---

## 10. 独自モデル開発（並行トラック）

最終目標である「自分だけのモデル」に向けた設計。**アプリ開発とは独立して進められる。**

**成果物の形式が変わった。GGUF ではなく MLX形式（safetensors）である。**
アプリ側はそれを読むだけなので、どちらかの完成を待つ必要がないことは変わらない。

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

### 10.2 パイプライン — 変換工程が1つ消える

```
ベースモデル(Qwen系, Apache 2.0)
   ├─ [マージ]  mergekit で複数モデルの重みを合成 → HF形式(safetensors)
   └─ [LoRA]    MLX で微調整 → mlx_lm.fuse でベースへ融合
                          ↓
              mlx_lm.convert で MLX形式へ（量子化込み）
                          ↓
              make bench / 実作業で品質評価
                          ↓
              アプリへ載せる（第7章の経路C: ローカルディレクトリ読み込み）
```

**v1.1 との差: 「GGUF へ変換・量子化」の工程が無くなった。**
LoRA の学習を MLX で行う以上、出力は最初から MLX が読める形式である。
**推論と学習が同じフレームワーク上にある。**

- 経路C（ローカルディレクトリ読み込み）【確認済 / MLX_SWIFT 2.3】がそのまま
  「自作モデルを載せる口」になる。HuggingFace を経由する必要がない
- **【未確認】`mlx-swift-lm`（Swift 側）に学習 API があるかは調査していない。**
  公式サンプルに LoRA があること自体は MLX_SWIFT 8.1 の記述（LoRA サンプルの
  `cacheLimit` が 32MB）から分かるが、中身は読んでいない。
  **当面は Python の `mlx-lm` を使う想定。**
- **【未確認】MLX 4bit と Ollama Q4_K_M の品質差が不明。** 同一プロンプトでの比較が必要

### 10.3 ベースを Qwen 系とする理由

- **Apache 2.0**。再配布・商用利用が可能で、「単体配布アプリ」の要件と矛盾しない
  （※ 配布前にモデルカードで最終確認すること。REQUIREMENTS 未決事項#4）
- MLX / mergekit / 量子化の各段階で情報と実績が揃っている
- 8B帯で日本語・コードともに競争力がある（[MODELS.md](MODELS.md)）
- **【確認済 / MLX_SWIFT 2.2】MLX 公式サンプル `LLMEval` の既定モデルが `Qwen3-8B-4bit`。**
  Apple 自身が Sophia と同じ構成をリファレンスに置いている。
  `LLMRegistry` に Qwen3 系の定数が7つあり、0.6B〜30B-MoE まで揃っている

### 10.4 VISION との交点 — 蒸留とパーソナライズ

[VISION.md](VISION.md) は「マージ / LoRA / 継続事前学習は計算量を変えない」と指摘し、
2つの交点を挙げている。**MLX への転換はどちらにも追い風になる。**

| VISION の主張 | MLX でどうなるか |
|---|---|
| **「自分の用途に絞った小さなモデルへ蒸留する」が交点になりうる** | 教師（8B）と生徒（0.6B）を**同一フレームワーク・同一機体**で扱える。`LLMRegistry` に両方の定数がある【確認済】 |
| **LoRA は「毎回説明しなければならないトークン」を消せる**（一度払って二度と払わない） | 第2.2章の入力予算 1,000トークンに対して、システムプロンプトを重みへ移せば予算が空く。**第1因子と第2因子が同じ方向を向く** |

### 10.5 想定される最大の障害

**計算資源ではなくデータ。** LoRA で意味のある差を出すには、
質の揃った訓練データが数千件必要になる。ここが作業量の大半を占める。
着手時は「何のデータを、どう集め、どう整形するか」から設計する。

**【2026-08-16 追記】アプリの原ログがその供給源になりうる**（8.4節 / VISION）。
これも「まず作って使う」を優先する理由である。

---

## 11. 配布（フェーズ A4）

| 項目 | 内容 |
|---|---|
| パッケージャ | **Xcode archive → `xcodebuild -exportArchive`**（electron-builder は廃止） |
| 対象 | macOS arm64（初版）。`.dmg` |
| 署名 | Developer ID Application。**Apple Developer Program 加入済み** |
| 公証 | `notarytool`。`hardenedRuntime` + entitlements |

### 11.1 Entitlements

**【確認済 / MLX_SWIFT 1.5】公式サンプル `LLMEval.entitlements` の内容。**

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>   <!-- モデル取得のためだけに必要 -->
<key>com.apple.developer.kernel.increased-memory-limit</key><true/>
<key>com.apple.security.files.user-selected.read-only</key><true/>
```

> **`network.client` は「モデル取得のためだけ」である点を、コードのコメントと
> 利用者向けの説明の両方に明記すること。** NFR-01（会話を外部に出さない）との関係で
> 誤解を招く唯一の権限である。
> **第7.2節の経路C（ローカルディレクトリ読み込み）を採れば、この権限自体を外せる**【確認済】。
> A2 で検討する。

### 11.2 v1.1 から消えたもの・残るもの

| v1.1 の記述 | v2.0 |
|---|---|
| `com.apple.security.cs.allow-unsigned-executable-memory` | **不要になる見込み【未確認】。** `.node` ネイティブアドオンが無い |
| `com.apple.security.cs.disable-library-validation` | 同上【未確認】 |
| **「フェーズ2の時点で空アプリを1度公証まで通す」** | **維持する。**理由が変わっただけで、先に通す価値は変わらない（11.3節） |

### 11.3 公証で新しく確認すべきこと【未確認】

`.node` の署名問題は消えたが、**MLX には Metal シェーダのバンドルがある。**
`mlx-swift_Cmlx.bundle` は Xcode ビルドでのみ生成され【確認済 / MLX_SWIFT 10.3】、
署名・公証の対象に含まれる。**この経路を通した実績が無い。**

→ **A2 で、MLX にリンクした空アプリを1度公証まで通す。**
v1.1 のリスク1に対する予防措置は、対象を替えてそのまま残る。

### 11.4 NFR-06（本体300MB以内）【未確認】

依存が16パッケージに膨らんでいる【確認済 / MLX_SWIFT 1.3】。
`swift-nio` / `swift-crypto` は `swift-huggingface`（HTTPクライアント）由来であり、
**第7.2節の経路C にすれば `swift-huggingface` を外せる。**
`swift-transformers`（トークナイザ）は外せない。

**実際のバイナリサイズは未測定。A2 で測る。**

---

## 12. 技術的リスク

> **v1.1 のリスク1（ネイティブモジュールの署名・公証）は要因が消滅した。**
> ただし**「先に公証を通す」という対策自体は有効なので、#1 の枠に別の中身で残している**
> （[ROADMAP.md](ROADMAP.md) が「DESIGN 第12章 リスク1」を参照しているため、番号を維持した）。

| # | リスク | 影響 | 対策 |
|---|---|---|---|
| 1 | **配布経路（署名・公証）が通らない。** 要因が `.node` から **Metal シェーダバンドル（`mlx-swift_Cmlx.bundle`）** へ入れ替わった【未確認】 | 配布不能 | **A2 の時点で、MLX にリンクした空アプリを1度公証まで通す**（11.3節）。A4 で初めて試すと手戻りが大きい。**この対策は v1.1 から変わらない** |
| 2 | ~~Apple Developer 未加入~~ | — | **解消。加入済み**（REQUIREMENTS 未決事項#1 は閉じてよい） |
| 3 | 思考モードで本文に到達しない | 応答が空に見える | 第6章。`maxTokens` 自動調整と思考領域の表示。A2 以降は `ThinkingBudgetProcessor`（6.4節） |
| 4 | 開発機16GBでアプリ+モデルが逼迫 | 開発が進まない | 開発中は Open WebUI と Ollama を落とす。`MLX.Memory.cacheLimit = 20MB`（3.3節） |
| 5 | ファンレスによる熱制限 | 計測値が再現しない | 比較計測は本体が冷えた状態に揃える（TUNING.md 12章）。**計測時はデバッガを外す**【MLX_SWIFT 落とし穴15】 |
| 6 | モデルのライセンスが再配布不可 | 配布方式の変更 | 初回ダウンロード方式（FR-07）で再配布に当たらない設計。Qwen3 は Apache 2.0。未決事項#4 |
| 7 | アイコン形式が `.icns` から `.icon` へ移行中 | 新OSでアイコンが古く見える | macOS 26 の Icon Composer はレイヤーを渡せばシステムが形状・ライト/ダーク/着色を生成する方式。**Xcode 26 での扱いは【未確認】。** A4 着手時に最新ドキュメントを確認する。`.icns` は当面有効なので現状の生成物は無駄にならない |
| 8 | 機能追加のたびにプロンプトが肥大する | 入力4,786トークン＝プリフィル34秒。Open WebUI で実際に起きた | 送信トークン数を `GenerationStats.inputTokens` で常時記録し、UIに表示する。予算約1,000トークンを超えたら警告（第2.2章） |
| 9 | 開発機のメモリ逼迫で計測が壊れる | 同一条件で最大4.9倍のばらつき。設定のA/Bが判定不能になる | 計測前に他アプリを閉じる。`peak_memory_bytes` を毎回記録し、多い回は外れ値として扱う（TUNING.md 測り方の作法 / 8.3節） |
| **10** | **MLX Swift の API が速い速度で変わる。** 3.x で依存構造が丸ごと変わり、`Evaluate.swift` には既に deprecated が5つある【確認済】 | ある朝突然ビルドが壊れる | **`revision:` で固定し `Package.resolved` を commit する**（9.0節）。`branch: "main"` を使わない。依存更新は独立した作業として行い、更新のたびに MLX_SWIFT.md を取り直す |
| **11** | **思考分離API（`ReasoningEventEmitter`）がリリース版 3.31.4 に無い**【確認済】 | FR-17 | 道A（`main` を revision 固定）か道B（自作スプリッタ）。**どちらでも FR-17 は満たせる**。自作版は MLX_SWIFT 6.5 にコンパイル確認済みのコードがある（6.2節） |
| **12** | **Swift / SwiftUI / Swift Concurrency の習熟。** strict concurrency のエラーは初見で意味が読めない | 開発速度。設計を歪める形で回避しがち | **Sendable 境界を 3.2節の1か所に固定する**（`Chat.Message` を外へ出さない）。**詰まったら誤魔化さず「詰まった」と報告する**（CLAUDE.md） |
| **13** | **単一プロセスのため、推論のクラッシュがアプリを巻き込む。** Electron の `utilityProcess` 隔離を失った | 会話が失われる | 生成中も逐次 DB へ書く（3.1節 / 第8章）。FR-02 の「既出力を残す」と実装を共通化する |
| **14** | **GGUF 資産が使えない**【確認済】 | `modelfiles/` とトラックBの出力形式 | MLX形式（safetensors）へ。トラックBは最初から MLX で出す（第10章）。Ollama 側は計測基盤として残す |
| **15** | **層ごとの実時間計測の方法論が無い**【未確認 / 未解決】。MLX は遅延評価で、`eval()` を挟むと測定行為が対象を壊す | **VISION 第3因子（早期終了）に着手できない** | **A2 で独立した作業項目として方法論を確立する**（4.5節③）。`GPU.startCapture` が代替になるか未検証。**A1 で解こうとしないこと** |
| **16** | **ビルドが重い。** 初回5分34秒 / `.build` 1.4〜1.5GB【実測】 | 「開発機を強化しない」原則と衝突する | クリーンビルドを避ける。`swift build`（差分約1秒）を型検査に使い、`xcodebuild` は実行時のみ（3.4節） |
| **17** | **NFR-06（本体300MB以内）の余裕が読めない**【未確認】 | 配布サイズ | 依存16パッケージ。**A2 で測る。**超えるなら経路C で `swift-huggingface` を外す（11.4節） |

---

## 13. 実装フェーズ

| フェーズ | 内容 | 完了条件 | 状態 |
|---|---|---|---|
| A0 | ローカルモデル環境と計測基盤 | 実測値を取得し、制約を数値で把握 | **完了** |
| **A1** | **SwiftUI 骨格 + `MLXEngine` + 思考分離 + 計測** | **CLAUDE.md の完成条件9項目** | **着手中** |
| A2 | **公証の疎通確認** + 解剖可能性の基盤 + MLX 側の最適化 | 空アプリの公証が通る。層計測の方法論が決まる | 未着手 |
| A3 | モデル管理・履歴永続化・全文検索 | 受入条件2〜7を満たす | 未着手 |
| A4 | パッケージング・署名・公証 | 受入条件1を満たす | 未着手 |
| 並行 | 独自モデル開発（第10章） | アプリの進行と独立 | 未着手 |

### 13.1 A2 の中身が変わった

v1.1 の A2 は「`LlamaCppEngine` へ差し替え + 公証の疎通確認」だった。
**差し替えが不要になった**（4.2節）。MLX は A1 の時点で既に配布形態と同じである。

**空いた A2 に何を入れるか:**

| # | 内容 | 根拠 |
|---|---|---|
| 1 | **公証の疎通確認**（Metal シェーダバンドルを含む空アプリ） | リスク1。v1.1 から唯一残る A2 の項目 |
| 2 | **層ごとの計測方法論の確立** | リスク15。**VISION 第3因子の前提** |
| 3 | **`ChatSession` の KVキャッシュ持ち越しの実測** | VISION 第1因子。2ターン目以降のプリフィルがどれだけ減るか【未確認 / MLX_SWIFT 4.2】 |
| 4 | `ThinkingBudgetProcessor` / `kvScheme = "turbo8v3"` の効果測定 | 6.4節 / 7.4節。16GB機のメモリ逼迫に直接効く見込み |
| 5 | バイナリサイズの測定と、経路C（オフライン読み込み）の検討 | リスク17 / 11.4節。NFR-01 を entitlement で保証できる |

### 13.2 他文書への申し送り（**本書では変更していない**）

| 文書 | 更新が必要な箇所 |
|---|---|
| [REQUIREMENTS.md](REQUIREMENTS.md) | 第8章 A1 行の「Electron骨格。開発用エンジン（Ollama）」/ A2 行の「配布用エンジンへ差し替え」。第4.2節「ネイティブモジュール（`.node`）」。第3章 用語の「GGUF」。未決事項#1（加入済みで閉じられる） |
| [ROADMAP.md](ROADMAP.md) | 第1章 トラックAの A1 / A2 の内容。トラックBの成果物形式（GGUF → MLX形式） |
| [UI_NATIVE.md](UI_NATIVE.md) | Electron 前提の節。**削除ではなく、9.3節の有効範囲表を頭に置く形が望ましい**（実測値そのものは資産である） |
| [TUNING.md](TUNING.md) | 第11章「MLXバックエンド」が「効果：中 / Apple Silicon限定」の1項目として書かれている。**本命になったので位置づけを上げる** |

---

## 付録: 本書が依拠した一次情報

| 種別 | 参照先 |
|---|---|
| 目標 | [VISION.md](VISION.md)（1/1000 / 開発機を強化しない / 要約が中核操作 / 遺伝的アルゴリズム） |
| MLX の API とビルド | [MLX_SWIFT.md](MLX_SWIFT.md)（`mlx-swift` / `mlx-swift-lm` のソース読解と、最小パッケージ2つの `swift build` 実測） |
| 速度・メモリ・熱の実測 | [BENCH_RESULTS.md](BENCH_RESULTS.md) / [TUNING.md](TUNING.md)（Ollama + GGUF） |
| 対話UIの寸法と状態遷移 | [UI_SPEC.md](UI_SPEC.md)（Open WebUI v0.11.0 の DOM 実測） |
| 配色とHIGの数値 | [UI_NATIVE.md](UI_NATIVE.md) 第4.3節・第5章（WCAG 計算値と AppKit 実測値） |
