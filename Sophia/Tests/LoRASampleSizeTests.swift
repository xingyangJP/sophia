import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers
import Tokenizers
import XCTest

@testable import Sophia

// =============================================================================
//  LoRA に何件の学習データが要るか ── 「自明な様式」を的にして立ち上がりを測る
// -----------------------------------------------------------------------------
//  ## この計測は何の判断のためにあるか
//
//  **設計の中に食い違いが1つ残っている。**
//
//  | どこ | 何と書いてあるか |
//  |---|---|
//  | `docs/DESIGN.md` 第14章（パーソナライズ） | **数十〜数百件**を前提にしている |
//  | `docs/DESIGN.md` 10.5節 | **数千件** |
//
//  **どちらが正しいかで、第14章が成立するかどうかが変わる。**
//  初回の質問（14.9節）で集められるのは**せいぜい数十件**である。
//  **数千件が要るなら、質問だけでは足りない**（14.16節 ⑦）。
//
//  資源の側は既に決着している（14.13a節 / `make lora`）── **16GB で 8B 本体でも回る。**
//  16層で 山 7,069 MB / 1周 8.2s / 損失 1.896 → 1.027。
//  **残っているのは「何件で様式が乗るか」だけである。**
//
//  ## 測り方（14.10節に K が書いた手順そのもの）
//
//  > **本番の様式で測らないこと。**「効いたかどうかが一目で分かる的」を先に立てる。
//  > 20件 / 50件 / 100件で学習し、15.2節の層①（自動チェック）で成功率を見る。
//  > **どの件数で立ち上がるかが分かれば、本番の様式の見積りが立つ。**
//
//  本番の様式でいきなり測ると、**効かなかったのがデータ量のせいか、
//  様式が曖昧だったせいか、判定がぶれただけかを切り分けられない。**
//
//  ### 的に選んだ様式 ── **「答えの全行を `- ` で始める」**
//
//  | なぜこれか | |
//  |---|---|
//  | **見れば分かる** | 人がログを読んでも1秒で判定できる。**判定規則が間違っていても気づける** |
//  | **数えられる** | 「非空行のうち `- ` で始まる割合」。意味を読まずに済む＝判定がぶれない |
//  | **素の出力とは形が違う** | Qwen3 の素の答えは「前置き1文 → 箇条書き → まとめ1文」である。**先頭行が箇条書きになることは稀**で、割合も 0.5〜0.7 に落ち着く（＝下の閾値で落ちる） |
//  | **題材と独立** | 様式だけを学ばせられる。話題まで覚えてしまう危険（14.10節）を避けられる |
//
//  **敬体（です・ます）は採らなかった。** Qwen3 は日本語では既定でほぼ敬体であり、
//  **学習前から通ってしまう＝何も測れない。**
//  「結論を最初に置く」も採らなかった ── **機械で判定できない**（意味を読む必要がある）。
//
//  ## 判定規則（`StyleRule`）
//
//  思考ブロックを `ThinkingSplitter`（出荷物）で落としてから、本文だけを見る。
//
//  | 条件 | なぜ要るか |
//  |---|---|
//  | 先頭の非空行が `- ` で始まる | **素の出力を落とす主力。** 前置き1文があれば落ちる |
//  | 非空行のうち `- ` 始まりが **8割以上** | まとめ1文が付くだけの「半分箇条書き」を落とす |
//  | `- ` 行が **2行以上** | 1行だけの答えを「様式が乗った」と数えない |
//  | **異なる** `- ` 行が2行以上 | **崩壊の検出。** 学習が壊れると `- あ` を繰り返す。それは合格ではない |
//  | 本文が **30文字以上** | 同上。空応答・極端な短文を合格にしない |
//
//  ## 器が対象を測っているかの確認 ── **本日の教訓。同種の誤りが4件出ている**
//
//  極端な例: プローブが**テスト内の仮の定義**を測っており「12/12 だから使える」が
//  実装の値ではなかった。**判定規則も器である。**
//  **学習前でも通ってしまう規則なら、何も測れていない。**
//  そこでこの計測は、**測る前と測る途中に4つの関門**を置き、通らなければ落ちる。
//
//  | # | 関門 | 落ちたら何が壊れている | いつ |
//  |---|---|---|---|
//  | **1** | **規則の自己検査。** 学習データの答えが全件合格し、かつ**散文の見本が全件不合格** | 規則が的と食い違っている／何でも合格になっている | **モデルを読む前**（数ミリ秒） |
//  | **2** | **陰性対照。** 学習前（LoRA 無し）の合格率が `baseline_max`（既定 0.34）以下 | **学習前に通る規則＝何も測れない** | 掃引の前 |
//  | **3** | **陽性対照。** 同じ問いに**指示文を足した**ときの合格率が `instructed_min`（既定 0.50）以上 | **規則が厳しすぎて誰も通れない**（＝天井が無い） | 掃引の前 |
//  | **4** | `adapted_modules=0` / `loss_moved=0` | 差し替えが起きていない／更新が起きていない | 各条件 |
//
//  **関門2と3は「掃引の前」に置いてある。** 40分学習してから
//  「規則が壊れていました」では、時間と熱を捨てることになる。
//
//  > **陽性対照には、それ自体に価値がある。**
//  > 指示文で同じ様式を出させたときの**入力トークンの増分**を `[LORASIZE-CONTROL]` に出す。
//  > **それが「重みに書かなかった場合に毎ターン払う額」である**（FR-29 / 14.15節）。
//
//  ### `LoRAContainer.from` は対象層0でも例外を投げない
//
//  `replaceLayers` は該当が無ければ黙って何もしないので、
//  **勾配の当たる重みが1つも無いまま学習が最後まで通る。**
//  速く、軽く、そして**様式は乗らない** ── つまり
//  **「100件でも足りない」という嘘の結論**が出る。`LoRAFeasibilityTests` と同じ関門を置く。
//
//  ## 交絡（**読む前に必ず知っておくこと**）
//
//  **`LoRABatchIterator` は学習データを無限に周回する。**
//  つまり**イテレーション数はデータ件数と独立に決まる。**
//  20件と100件を「同じ周回数」で回せば、**総ステップ数が5倍違う。**
//  「同じステップ数」で回せば、20件側は5倍の周回＝過学習寄りになる。
//  **どちらか一方だけでは、件数の効果とステップ数の効果を分けられない。**
//
//  | | | |
//  |---|---|---|
//  | **既定** | `epochs` 固定（`SOPHIA_LORASIZE_EPOCHS`、既定 4） | 実際に人がやる形。件数が増えれば学習も長くなる |
//  | **対照** | `SOPHIA_LORASIZE_ITERS=<数>` で**ステップ数を固定** | 件数の効果だけを見る。**2周目に必ず回すこと** |
//
//  **`[LORASIZE-COND]` と `[LORASIZE-CURVE]` には `n=` と `iters=` を必ず並べて出す。**
//  片方だけ見て結論を書けないようにするためである。
//
//  ## 前提と落とし穴（`LoRAFeasibilityTests` と同じ）
//
//  - **`SOPHIA_ENGINE=stub` を必ず入れること。** 入れないとホストアプリが
//    モデルをもう1つ読み、**測定値がちょうど倍になる。**
//    効いているかは `[LORASIZE-PRE] suspect_double_load=` で見る。
//  - **`MLX.Memory.cacheLimit` をアプリと揃える**（このテストは `MLXEngine` を通らない）。
//  - **モデルが手元に無ければ測らずに降りる。** 4.6GB の取得はメモリ圧を動かし、
//    測ろうとしている対象そのものを壊す。
//  - **重い。** 既定で1時間前後かかる。見積りは `[LORASIZE-PLAN]`（事前・仮定値）と
//    `[LORASIZE-ETA]`（実測に基づく残り時間）の2本を出す。
//  - **別窓で `make probe-watch` を先に回すこと。** `peak_mb` は MLX の帳簿であって
//    物理RAMに載っているかではない（2026-08-17 実測）。
//
//  ## 起動ゲート
//
//  **`SOPHIA_LORASIZE=1` のときだけ走る。** `setUpWithError()` に置いてあるので、
//  後からメソッドを足しても構造的に走りようが無い。
//
//  ## 環境変数
//
//  | 変数 | 既定 | 意味 |
//  |---|---|---|
//  | `SOPHIA_LORASIZE`         | （無し） | **`1` のときだけ実行** |
//  | `SOPHIA_LORASIZE_N`       | `20,50,100` | 掃く件数。**入れ子**（50件は20件を含む） |
//  | `SOPHIA_LORASIZE_EPOCHS`  | `4`      | 1件を何回見せるか。`ITERS` 未指定のとき使う |
//  | `SOPHIA_LORASIZE_ITERS`   | `0`      | **0 以外ならステップ数を固定**（交絡の切り分け） |
//  | `SOPHIA_LORASIZE_LAYERS`  | `16`     | 14.13a節で最も損失が動いた層数 |
//  | `SOPHIA_LORASIZE_RANK`    | `8`      | 同上 |
//  | `SOPHIA_LORASIZE_BATCH`   | `1`      | 16GB では 1 から動かさない（batch>1 は【未確認】） |
//  | `SOPHIA_LORASIZE_LR`      | `1e-5`   | mlx-lm の既定と同じ |
//  | `SOPHIA_LORASIZE_KEYS`    | （無し） | 射影を明示。無指定＝ライブラリ既定 |
//  | `SOPHIA_LORASIZE_SEEDS`   | `2`      | 1問あたりの試行回数。**n=1 で判定しない**（第15章） |
//  | `SOPHIA_LORASIZE_MAXTOK`  | `220`    | 生成の上限。切れたら `truncated` に出る |
//  | `SOPHIA_LORASIZE_TEMP`    | `0.7`    | 実使用と同じ。**揺らいでも守れるか**を測る |
//  | `SOPHIA_LORASIZE_THINK`   | `0`      | 思考モード。ONにすると1往復が数十秒になる |
//  | `SOPHIA_LORASIZE_REPORT`  | `10`     | 何ステップごとに損失を報告させるか |
//  | `SOPHIA_LORASIZE_BASELINE_MAX`   | `0.34` | **関門2**の閾値 |
//  | `SOPHIA_LORASIZE_INSTRUCTED_MIN` | `0.50` | **関門3**の閾値 |
//  | `SOPHIA_LORASIZE_PRIOR_ITER_S`   | `6.0`  | 事前見積り用の1ステップ秒（14.13a節から） |
//  | `SOPHIA_LORASIZE_PRIOR_GEN_S`    | `18.0` | 事前見積り用の1生成秒 |
//  | `SOPHIA_LORASIZE_CACHE_LIMIT_MB` | `SophiaDefaults.mlxCacheLimitBytes` | アプリと同条件 |
//  | `SOPHIA_LORASIZE_MODEL`   | `SophiaDefaults.modelID` | 0.6B に落として配管だけ先に通せる |
//  | `SOPHIA_LORASIZE_LABEL`   | 空       | ログに付ける自由記述 |
//
//  ## 出力（すべて **stderr** へ1行1レコード）
//
//  | プレフィックス | 何の行か |
//  |---|---|
//  | `[LORASIZE-BEGIN]`   | 条件の記録。**この行が無いログは条件不明として捨てること** |
//  | `[LORASIZE-RULE]`    | **関門1。** 判定規則の自己検査。モデルを読む前に出る |
//  | `[LORASIZE-PLAN]`    | 回す順序と**事前の時間見積り**（`estimated=1 basis=prior`） |
//  | `[LORASIZE-PRE]`     | ロード前の MLX の会計。二重ロードの検出点 |
//  | `[LORASIZE-LOAD]`    | ロードの実測 |
//  | `[LORASIZE-CORPUS]`  | 学習データの実測（トークン長・往復の健全性） |
//  | `[LORASIZE-CORPUS-BEGIN/END]` | **その現物を全件。** 学習へ渡る文字列そのもの |
//  | `[LORASIZE-PROMPTS-BEGIN/END]`| **評価に使う問いの現物。** 学習データとは別の題材であること |
//  | `[LORASIZE-CONTROL]` | 陽性対照。**指示文で払う入力トークンの増分**（FR-29 の比較対象） |
//  | `[LORASIZE-APPLY]`   | 差し替えの実測。**関門4はここ** |
//  | `[LORASIZE-ITER]`    | 学習の進み（損失） |
//  | `[LORASIZE-GEN]`     | **1行1生成。** 判定の内訳（割合・行数・落ちた理由） |
//  | `[LORASIZE-OUT-BEGIN/END]` | **その出力の全文。判定規則が間違っていても人が読めば分かる** |
//  | `[LORASIZE-UNLOAD]`  | 剥がした確認。`residual_lora_layers=0` でなければ次条件が汚れている |
//  | `[LORASIZE-COND]`    | **1行1条件。本丸。** |
//  | `[LORASIZE-ETA]`     | 実測に基づく**残り時間** |
//  | `[LORASIZE-CURVE]`   | **立ち上がり。件数 → 合格率を1行に並べたもの** |
//  | `[LORASIZE-VERDICT]` | 読み手向けの材料 |
//  | `[LORASIZE-END]`     | 終了。**この行が無ければ途中で殺されている** |
//
//  ### `[LORASIZE-CURVE]` の読み方（この計測の結論はこの行にある）
//
//  ```
//  [LORASIZE-CURVE] baseline=0.08 instructed=0.92 n20=0.17/iters=80 \
//    n50=0.58/iters=200 n100=0.83/iters=400 rise_threshold=0.50 rises_at=50 \
//    iters_mode=epochs confounded=1
//  ```
//
//  | 見るところ | 意味 |
//  |---|---|
//  | `baseline`   | **学習前。** ここが低いことが、この計測が成立する条件である |
//  | `instructed` | **天井。** 毎ターン指示文を払えば届く高さ。LoRA はここを目指す |
//  | `rises_at`   | **陰性対照から明確に離れた最初の件数。** これが答えである |
//  | `n…=…/iters=…` | **必ず両方見ること。** 件数の効果とステップ数の効果は分けられていない |
//  | `confounded=1` | **既定の回し方では分けられていない**という表明。0 は `ITERS` 固定で回した回 |
//
//  ## 使い方
//
//  ```
//  make probe-build              # 1回だけ
//  （別窓で） make probe-watch    # 系全体の数字。**これ無しで結論を出さない**
//  make lorasize
//  ```
//
//  **計測前に起動中の `Sophia` を落とすこと**（`pkill -x Sophia`）。Ollama も止めること。
// =============================================================================

final class LoRASampleSizeTests: XCTestCase {

    // MARK: - 起動ゲート

    /// **ここが「通常の `make app-test` では絶対に走らない」の実体。**
    /// `LoRAFeasibilityTests` / `PrefillProbeTests` と同じ作法で `setUpWithError()` に置く。
    override func setUpWithError() throws {
        try super.setUpWithError()
        try Self.requireProbeEnabled()
        // 1条件が崩れたまま残りを回しても、崩れた後の数字が並ぶだけで読めない。
        continueAfterFailure = false
    }

    private static func requireProbeEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SOPHIA_LORASIZE"] == "1",
            "LoRA の必要データ件数の計測です。`SOPHIA_LORASIZE=1` を付けたときだけ走ります"
                + "（4.4GB を読み込み、既定で1時間前後かかるため）")
    }

    // MARK: - 本丸

    func testStyleAdoptionBySampleSize() async throws {
        // setUpWithError と重複しているが**意図的**。二重に掛けておく価値がある。
        try Self.requireProbeEnabled()

        let config = SampleSizeConfiguration.fromEnvironment()
        let log = SampleSizeLog(label: config.label)

        log.write("[LORASIZE-BEGIN", [
            "model=\(config.modelID)",
            "n_list=\(config.sampleSizes.map(String.init).joined(separator: "|"))",
            "iters_mode=\(config.iterationsAreFixed ? "fixed" : "epochs")",
            "epochs=\(config.epochs)",
            "fixed_iters=\(config.fixedIterations)",
            "layers=\(config.layers)", "rank=\(config.rank)", "batch=\(config.batch)",
            "lr=\(config.learningRate)",
            "keys=\(config.keys?.joined(separator: "|") ?? "library-default")",
            "seeds=\(config.seeds)", "max_tokens=\(config.maxTokens)",
            "temp=\(config.temperature)", "thinking=\(config.thinkingEnabled ? 1 : 0)",
            "eval_prompts=\(StyleCorpus.evaluationPrompts.count)",
            "gens_per_cond=\(config.generationsPerCondition)",
            "baseline_max=\(sizeFixed(config.baselineMax))",
            "instructed_min=\(sizeFixed(config.instructedMin))",
            "cache_limit_mb=\(sizeFixed(Double(config.cacheLimitBytes) / 1_048_576, digits: 1))",
            "system_prompt=\(SophiaDefaults.systemPromptEnabled ? 1 : 0)",
            "physical_ram_mb=\(ProcessInfo.processInfo.physicalMemory / 1_048_576)",
        ])

        // =====================================================================
        //  関門1 ── 判定規則そのものを、モデルを読む前に検査する
        // =====================================================================
        //
        // **ここを通らないうちは 4.4GB を読まない。** 数ミリ秒で終わる。
        //
        // 見るのは2つ。
        //   ① 学習データの答えが**全件合格する**  ─ 規則と的が食い違っていない
        //   ② 散文の見本が**全件不合格になる**    ─ 何でも合格になっていない
        //
        // ②が無いと「常に true を返す規則」が素通りする。
        // **本日の4件はすべて、この形の見落としだった。**
        let pairs = StyleCorpus.pairs(count: config.maxSampleSize + StyleCorpus.validationCount)
        let positives = pairs.map { StyleRule.judge($0.answer) }
        let positivesPassed = positives.filter(\.passed).count
        let negatives = StyleRule.rejectionFixtures.map { ($0.name, StyleRule.judge($0.text)) }
        let negativesRejected = negatives.filter { !$0.1.passed }.count
        let ruleIsSound =
            positivesPassed == positives.count && negativesRejected == negatives.count

        log.write("[LORASIZE-RULE", [
            // **空白を含めない形にしてある**ので、潰さずにそのまま出す
            // （`sizeSafeValue` は64スカラーで切るため、規則が途中で切れてしまう）。
            "rule=\(StyleRule.description)",
            "positives_pass=\(positivesPassed)/\(positives.count)",
            "negatives_reject=\(negativesRejected)/\(negatives.count)",
            "ok=\(ruleIsSound ? 1 : 0)",
        ])
        for (name, verdict) in negatives where verdict.passed {
            // **通ってはいけない見本が通った。** 何が通ったかを名指しで出す。
            log.write("[LORASIZE-RULE", ["leak=\(name)", "why=\(verdict.summary)"])
        }
        guard ruleIsSound else {
            throw SampleSizeProbeError.instrumentBroken(
                "判定規則が対象を測っていない"
                    + "（学習データの合格 \(positivesPassed)/\(positives.count)、"
                    + "散文の不合格 \(negativesRejected)/\(negatives.count)）")
        }

        // --- モデルの実体が無ければ測らずに降りる -----------------------------
        //
        // ここで 4.6GB を取りに行かせない。**取得そのものがディスクキャッシュと
        // メモリ圧を動かし、これから測ろうとしている対象を壊す。**
        try XCTSkipUnless(
            MLXModelCatalog.isDownloaded(config.modelID),
            "\(config.modelID) がローカルに無い。"
                + "先にアプリを起動して取得してから測ること")

        // **MLX の会計をアプリと同じ条件へ揃える。**
        // このテストは `MLXEngine` を1行も通らないので、揃えないと
        // `cacheLimit` が既定（ほぼ無制限）のままになり `cache_mb` が数GB出る。
        MLX.Memory.cacheLimit = config.cacheLimitBytes

        // --- 回す順序と、事前の見積り ----------------------------------------
        //
        // **事前の見積りは仮定値である。** 14.13a節の実測と生成の経験値から置いた数であって、
        // この機体のこの日の値ではない。実測は `[LORASIZE-ETA]` のほうを読むこと。
        let conditions = config.conditions
        for (index, condition) in conditions.enumerated() {
            log.write("[LORASIZE-PLAN", [
                "idx=\(index + 1)/\(conditions.count)",
                "id=\(condition.id)",
                "n=\(condition.trainExamples)",
                "instructed=\(condition.instructed ? 1 : 0)",
                "iters=\(config.iterations(for: condition.trainExamples))",
                "gens=\(config.generationsPerCondition)",
                "est_s=\(sizeFixed(config.priorSeconds(for: condition), digits: 0))",
            ])
        }
        let priorTotal = conditions.reduce(0.0) { $0 + config.priorSeconds(for: $1) }
        log.write("[LORASIZE-PLAN", [
            "total=1",
            "conditions=\(conditions.count)",
            "estimated=1", "basis=prior",
            "prior_iter_s=\(sizeFixed(config.priorIterationSeconds))",
            "prior_gen_s=\(sizeFixed(config.priorGenerationSeconds))",
            "est_total_s=\(sizeFixed(priorTotal, digits: 0))",
            "est_total_min=\(sizeFixed(priorTotal / 60, digits: 1))",
        ])

        // --- ロード「前」の会計（二重ロードの検出点）--------------------------
        //
        // ここで `active_mb` が GB 級なら、このプロセスに既に別のモデルが載っている
        // （＝`SOPHIA_ENGINE=stub` が効いていない）。以降の数字はすべて倍になる。
        let pre = MLX.Memory.snapshot()
        log.write("[LORASIZE-PRE", [
            "engine=\(ProcessInfo.processInfo.environment["SOPHIA_ENGINE"] ?? "-")",
        ] + sizeMemoryFields(pre) + [
            "suspect_double_load=\(pre.activeMemory > 1_073_741_824 ? 1 : 0)",
        ])

        // --- ロード -----------------------------------------------------------
        let loadStartedAt = ContinuousClock().now
        let container = try await loadModelContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: MLXModelCatalog.configuration(for: config.modelID))
        let loadSeconds = loadStartedAt.duration(to: ContinuousClock().now).milliseconds / 1000
        let base = MLX.Memory.snapshot()
        let baseTotalMB = Double(base.activeMemory + base.cacheMemory) / 1_048_576

        log.write("[LORASIZE-LOAD", [
            "model=\(config.modelID)",
            "load_s=\(sizeFixed(loadSeconds))",
        ] + sizeMemoryFields(base))

        // =====================================================================
        //  学習データ ── **形式は本番と同じにする**
        // =====================================================================
        //
        // `LoRABatchIterator` は渡された `[String]` を `tokenizer.encode(text:)` に掛ける。
        // つまり**学習が実際に見るのはチャットテンプレートを適用し終えた文**である。
        // だからここでも `container.prepare` を通した実物から作る（自前で組み立てない）。
        let corpus = try await StyleTrainingCorpus.make(
            container: container,
            pairs: pairs,
            thinkingEnabled: config.thinkingEnabled)

        log.write("[LORASIZE-CORPUS", corpus.fields)

        // **現物を全件出す。**「形式は本番と同じ」は主張であって証拠ではない
        // （`[LORA-CORPUS-BEGIN/END]` / `[BREAKDOWN] RENDERED_*` と同じやり方）。
        log.write("[LORASIZE-CORPUS-BEGIN", ["examples=\(corpus.train.count)"])
        for (index, text) in corpus.train.enumerated() {
            FileHandle.standardError.write(Data("--- train[\(index)] ---\n\(text)\n".utf8))
        }
        for (index, text) in corpus.validate.enumerated() {
            FileHandle.standardError.write(Data("--- valid[\(index)] ---\n\(text)\n".utf8))
        }
        log.write("[LORASIZE-CORPUS-END", ["examples=\(corpus.train.count)"])

        // **往復が壊れていないか。** `prepare` が出したトークン列を decode → encode し直して
        // 数が変わるなら、学習が見る文は `prepare` が出した文と同じではない。
        guard corpus.roundTripMismatches == 0 else {
            throw SampleSizeProbeError.instrumentBroken(
                "decode→encode の往復でトークン数が変わった"
                    + "（\(corpus.roundTripMismatches)/\(corpus.train.count) 件）。"
                    + "学習が見る文は prepare が出した文と同じではない")
        }

        // =====================================================================
        //  評価に使う問い ── **学習データとは別の題材にする**
        // =====================================================================
        //
        // **同じ題材で評価したら、測っているのは暗記である。**
        // 問いには様式の指示を1文字も入れない ── 様式は**重みに入っていること**が要件
        // （FR-24〜29 / 14.15節「毎ターン 0 と出ることが本章の成果物である」）。
        let plainPrompts = try await StylePromptSet.make(
            container: container,
            prompts: StyleCorpus.evaluationPrompts,
            instruction: nil,
            thinkingEnabled: config.thinkingEnabled)
        let instructedPrompts = try await StylePromptSet.make(
            container: container,
            prompts: StyleCorpus.evaluationPrompts,
            instruction: StyleCorpus.styleInstruction,
            thinkingEnabled: config.thinkingEnabled)

        log.write("[LORASIZE-PROMPTS-BEGIN", ["count=\(StyleCorpus.evaluationPrompts.count)"])
        for (index, text) in StyleCorpus.evaluationPrompts.enumerated() {
            FileHandle.standardError.write(Data("--- eval[\(index)] ---\n\(text)\n".utf8))
        }
        FileHandle.standardError.write(
            Data("--- instruction ---\n\(StyleCorpus.styleInstruction)\n".utf8))
        log.write("[LORASIZE-PROMPTS-END", ["count=\(StyleCorpus.evaluationPrompts.count)"])

        // **指示文が毎ターン払わせる額。** これが FR-29 の比較対象そのものである。
        log.write("[LORASIZE-CONTROL", [
            "plain_tokens_med=\(plainPrompts.medianTokens)",
            "instructed_tokens_med=\(instructedPrompts.medianTokens)",
            // **重みに書かなかった場合、この分を会話が続く限り毎ターン払う。**
            "instruction_tokens=\(instructedPrompts.medianTokens - plainPrompts.medianTokens)",
            "input_budget_total=\(SophiaDefaults.InputBudget.total)",
        ])

        // =====================================================================
        //  掃引（**対照を先に、学習を安い順に**）
        // =====================================================================
        var results: [SizeConditionResult] = []
        var failed = 0
        // 実測に基づく単価。1条件ぶん取れた時点で `[LORASIZE-ETA]` を出せるようになる。
        var measuredIterationSeconds: Double?
        var measuredGenerationSeconds: Double?

        for (index, condition) in conditions.enumerated() {
            let position = "\(index + 1)/\(conditions.count)"
            let iterations = config.iterations(for: condition.trainExamples)
            let prompts = condition.instructed ? instructedPrompts.tokens : plainPrompts.tokens

            // **山は条件ごとに必ず落とす。** 落とさないと前の条件の山が次の `peak_mb` になる。
            // なお setter は値を無視して単にリセットする（MLX の API がそうなっている）。
            MLX.Memory.peakMemory = 0

            var training: TrainOutcome?
            // **「まだ載っているか」を別に持つ。** `training` は結果の記録にも使うので、
            // 剥がしたかどうかを `nil` で表せない。**二重に剥がすのを防ぐのはこの旗である。**
            var adapterIsLoaded = false
            do {
                // --- 学習 -------------------------------------------------------
                if condition.trainExamples > 0 {
                    // **件数は入れ子にする。** 50件は20件を含む ── そうしないと、
                    // 差が「件数」ではなく「たまたま選ばれた題材」の差になりうる。
                    let slice = Array(corpus.train.prefix(condition.trainExamples))
                    let outcome = try await container.perform { context -> TrainOutcome in
                        try applyAndTrain(
                            context: context,
                            slice: slice,
                            validate: corpus.validate,
                            iterations: iterations,
                            config: config,
                            conditionID: condition.id,
                            position: position,
                            log: log)
                    }
                    training = outcome
                    adapterIsLoaded = true
                }

                // --- 生成して判定する -------------------------------------------
                //
                // **問いも種も、全条件で同じものを使う。** 対にして比べるためであり、
                // 揃っていなければ差は件数の効果ではない。
                let tally = try await generateAndJudge(
                    container: container,
                    promptTokens: prompts,
                    config: config,
                    conditionID: condition.id,
                    position: position,
                    trainExamples: condition.trainExamples,
                    log: log)

                // --- 剥がす -----------------------------------------------------
                //
                // **剥がし忘れると次の条件がこの条件の上に積み上がり、
                // そこから先の数字が全部嘘になる。** 失敗経路でも剥がす（下の catch）。
                if adapterIsLoaded, let training {
                    await unloadAdapter(
                        container: container, training: training,
                        conditionID: condition.id, position: position, log: log)
                    adapterIsLoaded = false
                }

                let after = MLX.Memory.snapshot()
                let result = SizeConditionResult(
                    id: condition.id,
                    position: position,
                    trainExamples: condition.trainExamples,
                    instructed: condition.instructed,
                    iterations: condition.trainExamples > 0 ? iterations : 0,
                    tally: tally,
                    training: training,
                    baseTotalMB: baseTotalMB,
                    peakMB: Double(after.peakMemory) / 1_048_576,
                    peakOverBaseMB: (Double(after.peakMemory) / 1_048_576) - baseTotalMB)
                log.write("[LORASIZE-COND", result.fields)
                results.append(result)

                if let seconds = result.secondsPerIteration { measuredIterationSeconds = seconds }
                if let seconds = tally.medianSeconds { measuredGenerationSeconds = seconds }

                // --- 残り時間（**実測に基づく**）---------------------------------
                let remaining = conditions.dropFirst(index + 1)
                if !remaining.isEmpty {
                    let perIteration = measuredIterationSeconds ?? config.priorIterationSeconds
                    let perGeneration = measuredGenerationSeconds ?? config.priorGenerationSeconds
                    let estimate = remaining.reduce(0.0) { total, next in
                        total
                            + Double(config.iterations(for: next.trainExamples)) * perIteration
                            + Double(config.generationsPerCondition) * perGeneration
                    }
                    log.write("[LORASIZE-ETA", [
                        "after=\(position)",
                        "remaining_conditions=\(remaining.count)",
                        "measured_iter_s=\(sizeFixed(measuredIterationSeconds, digits: 3))",
                        "measured_gen_s=\(sizeFixed(measuredGenerationSeconds))",
                        "est_remaining_s=\(sizeFixed(estimate, digits: 0))",
                        "est_remaining_min=\(sizeFixed(estimate / 60, digits: 1))",
                    ])
                }

                // =============================================================
                //  関門2 / 関門3 ── **掃引の前に判定規則を検算する**
                // =============================================================
                //
                // 40分学習したあとで「規則が壊れていました」では時間を捨てることになる。
                // 対照は条件の先頭2つに並べてあるので、ここで見れば掃引の前に落とせる。
                if condition.id == SizeCondition.baselineID {
                    guard result.meanChars >= 20 else {
                        throw SampleSizeProbeError.instrumentBroken(
                            "学習前の出力がほとんど空である"
                                + "（平均 \(sizeFixed(result.meanChars)) 文字）。"
                                + "測っているのは様式ではなく、生成が成立していないことである")
                    }
                    guard result.passRate <= config.baselineMax else {
                        throw SampleSizeProbeError.instrumentBroken(
                            "学習前に通ってしまう規則である"
                                + "（合格率 \(sizeFixed(result.passRate)) > "
                                + "\(sizeFixed(config.baselineMax))）。"
                                + "この規則では何件あっても差が出ない。的か閾値を締め直すこと")
                    }
                }
                if condition.id == SizeCondition.instructedID {
                    guard result.passRate >= config.instructedMin else {
                        throw SampleSizeProbeError.instrumentBroken(
                            "指示しても通らない規則である"
                                + "（合格率 \(sizeFixed(result.passRate)) < "
                                + "\(sizeFixed(config.instructedMin))）。"
                                + "天井が無い＝LoRA が届くべき高さが存在しない。規則が厳しすぎる")
                    }
                }
            } catch let error as SampleSizeProbeError {
                // **器が壊れている。** 以降を測っても数字が出るだけで意味が無い。
                if adapterIsLoaded, let training {
                    await unloadAdapter(
                        container: container, training: training,
                        conditionID: condition.id, position: position, log: log)
                }
                log.write("[LORASIZE-ABORT", ["idx=\(position)", "reason=\(error.summary)"])
                throw error
            } catch {
                // この条件は落ちたが、**他の条件は測れる。**
                if adapterIsLoaded, let training {
                    await unloadAdapter(
                        container: container, training: training,
                        conditionID: condition.id, position: position, log: log)
                }
                failed += 1
                log.write("[LORASIZE-COND", [
                    "idx=\(position)", "id=\(condition.id)",
                    "n=\(condition.trainExamples)", "iters=\(iterations)",
                    "ok=0",
                    // **1行1レコードを崩さない。** 例外の文言には改行が入りうる。
                    "error=\(sizeSafeValue(String(describing: error)))",
                ])
            }
        }

        // =====================================================================
        //  立ち上がり ── **この行が結論である**
        // =====================================================================
        let baseline = results.first { $0.id == SizeCondition.baselineID }
        let instructed = results.first { $0.id == SizeCondition.instructedID }
        let trained = results
            .filter { $0.trainExamples > 0 }
            .sorted { $0.trainExamples < $1.trainExamples }

        // **「立ち上がった」の定義を先に決めておく。**
        // 陰性対照より 0.25 以上高く、かつ 0.5 を超えた最初の件数とする。
        // 数字そのものより、**規則を先に決めて後から動かさないこと**が要点である。
        let riseThreshold = max((baseline?.passRate ?? 0) + 0.25, 0.5)
        let risesAt = trained.first { $0.passRate >= riseThreshold }?.trainExamples

        log.write("[LORASIZE-CURVE", [
            "baseline=\(sizeFixed(baseline?.passRate))",
            "instructed=\(sizeFixed(instructed?.passRate))",
        ] + trained.map { "n\($0.trainExamples)=\(sizeFixed($0.passRate))/iters=\($0.iterations)" }
            + [
                "rise_threshold=\(sizeFixed(riseThreshold))",
                "rises_at=\(risesAt.map(String.init) ?? "-")",
                // **交絡を隠さない。** 件数とステップ数は既定では一緒に動いている。
                "iters_mode=\(config.iterationsAreFixed ? "fixed" : "epochs")",
                "confounded=\(config.iterationsAreFixed ? 0 : 1)",
            ])

        log.write("[LORASIZE-VERDICT", [
            "measured=\(results.count)/\(conditions.count)",
            "failed=\(failed)",
            "untrusted=\(results.filter { !$0.trusted }.count)",
            "reading=\(verdictText(baseline: baseline, instructed: instructed, risesAt: risesAt))",
            // **これは MLX の帳簿であって、物理RAMに載っているかではない。**
            "note=MLX_accounting_only__residency_needs_vm_stat",
        ])

        log.write("[LORASIZE-END", ["conditions_done=\(results.count)/\(conditions.count)"])

        // --- 落とす条件（**数字が出たことと、測れたことは別である**）------------
        //
        // `loss_moved=0` の条件を黙って通すと、**「100件でも足りない」という
        // 平らな曲線**が出る。それは件数の結論ではなく、学習が起きなかった記録である。
        let untrusted = results.filter { !$0.trusted }
        XCTAssertTrue(
            untrusted.isEmpty,
            "学習が起きていない条件がある（\(untrusted.map(\.id).joined(separator: ","))）。"
                + "`[LORASIZE-COND] loss_moved=0` / `adapted_modules=0` を見ること。"
                + "この状態の曲線は「件数が足りない」ではなく「学習していない」である")
        XCTAssertFalse(
            trained.isEmpty,
            "1件も学習条件を測れていない。ログに `[LORASIZE-COND] ok=1 n>0` の行が無い")
    }
}

// MARK: - 学習（**同期**。`container.perform` の中から呼ぶ）

/// LoRA を差し替えて学習する。
///
/// **`ModelContext` を受け取るので、必ず `container.perform` の中から呼ぶこと。**
/// `LanguageModel` も `Tokenizer` も `Sendable` ではない。
/// **同期関数にしてあるのは意図的である** ── `ModelContext` を非同期関数へ渡すと
/// 領域の判定が絡む。`LoRAFeasibilityTests` の `loraMeasureOne` と同じ形に揃えてある。
///
/// ログは**この関数の中から**出す ── そうしないと `APPLY → ITER` の順序が崩れ、
/// 途中で殺されたときに読めなくなる。
private func applyAndTrain(
    context: ModelContext,
    slice: [String],
    validate: [String],
    iterations: Int,
    config: SampleSizeConfiguration,
    conditionID: String,
    position: String,
    log: SampleSizeLog
) throws -> TrainOutcome {
    let model = context.model

    // `scale` は既定のまま（`LoRAConfiguration.LoRAParameters` の既定）。
    // **数字を書き写さない** ── 書き写した瞬間、ライブラリの既定が変わっても気づけない。
    let loraConfiguration = LoRAConfiguration(
        numLayers: config.layers,
        fineTuneType: .lora,
        loraParameters: .init(rank: config.rank, keys: config.keys))

    let adapter = try LoRAContainer.from(model: model, configuration: loraConfiguration)

    // --- 関門4: 差し替えが起きたことを実測してから測る ------------------------
    //
    // **`LoRAContainer.from` は対象が1つも無くても例外を投げない。**
    // `replaceLayers` は該当が無ければ黙って何もしない。
    // その状態でも `LoRATrain.train` は最後まで通り、速く・軽く・
    // **様式が乗らない** ── つまり「100件でも足りない」という嘘の結論が出る。
    let trainables = model.trainableParameters().flattened()
    let adaptedModules = model.namedModules().filter { $0.1 is LoRALayer }.count
    let trainableTensors = trainables.count
    let trainableParameters = trainables.reduce(0) { $0 + $1.1.size }
    let loraLayerTotal = (model as? LoRAModel)?.loraLayers.count ?? -1
    let resolvedKeys = config.keys ?? (model as? LoRAModel)?.loraDefaultKeys ?? []

    log.write("[LORASIZE-APPLY", [
        "idx=\(position)", "id=\(conditionID)",
        "examples=\(slice.count)",
        "layers=\(config.layers)/\(loraLayerTotal)",
        "rank=\(config.rank)",
        "scale=\(loraConfiguration.loraParameters.scale)",
        "keys=\(resolvedKeys.count)",
        "keys_list=\(resolvedKeys.sorted().joined(separator: "|"))",
        "adapted_modules=\(adaptedModules)",
        "trainable_tensors=\(trainableTensors)",
        "trainable_params=\(trainableParameters)",
    ] + sizeMemoryFields(MLX.Memory.snapshot()))

    guard adaptedModules > 0, trainableTensors > 0, trainableParameters > 0 else {
        // **剥がしてから投げる。** 差し替えが半端に残ると次の条件が汚れる。
        adapter.unload(from: model)
        throw SampleSizeProbeError.instrumentBroken(
            "差し替えが1つも起きていない"
                + "（adapted_modules=\(adaptedModules) "
                + "trainable_tensors=\(trainableTensors)）。"
                + "この状態で学習を回すと、勾配の当たる重みが無いまま最後まで通り、"
                + "「様式が乗らなかった」という嘘の結果が出る")
    }

    // **報告の間隔を、回数に合わせて詰める。**
    // `stepsPerReport` が `iterations` より大きいと進捗が1度も鳴らず、
    // `loss_first` / `loss_last` が空になって `loss_moved=0` の誤報になる。
    let stepsPerReport = max(1, min(config.stepsPerReport, max(1, iterations / 8)))

    let optimizer = Adam(learningRate: config.learningRate)
    let parameters = LoRATrain.Parameters(
        batchSize: config.batch,
        iterations: iterations,
        stepsPerReport: stepsPerReport,
        // 検証は事実上無効化する。ただし**0イテレーション目の検証だけは
        // ライブラリが無条件で走らせる**（`iteration == 0 ||` の項）。これは外せない。
        stepsPerEval: iterations + 1_000_000,
        validationBatches: 1,
        saveEvery: iterations + 1_000_000,
        adapterURL: nil)

    var losses: [Float] = []
    var reportSeconds: [Double] = []

    // **区間の起点は「直前にコールバックが鳴った時刻」である。**
    // 単に前回の `.train` からの差を取ると、0イテレーション目の後に入る検証の時間が
    // 次の区間に乗ってしまう（＝単価が数倍に見える）。
    var previousEventAt = ContinuousClock().now
    let startedAt = previousEventAt

    // **落ちたら剥がしてから投げる。**
    // 学習が途中で失敗したまま層を残すと、**次の条件がこの条件の上に積み上がる。**
    // そこから先の数字は全部、前の条件との合成である。
    do {
        try LoRATrain.train(
            model: model,
            train: slice,
            validate: validate,
            optimizer: optimizer,
            tokenizer: context.tokenizer,
            parameters: parameters
        ) { progress in
            let now = ContinuousClock().now
            let seconds = previousEventAt.duration(to: now).milliseconds / 1000
            previousEventAt = now

            switch progress {
            case .train(let iteration, let loss, _, let tokensPerSecond):
                losses.append(loss)
                reportSeconds.append(seconds)
                log.write("[LORASIZE-ITER", [
                    "idx=\(position)", "id=\(conditionID)",
                    "iter=\(iteration + 1)/\(iterations)",
                    "loss=\(sizeFixed(Double(loss), digits: 4))",
                    "report_s=\(sizeFixed(seconds, digits: 3))",
                    "per_iter_s=\(sizeFixed(seconds / Double(stepsPerReport), digits: 3))",
                    "lib_tok_s=\(sizeFixed(tokensPerSecond, digits: 1))",
                    "active_mb=\(sizeFixed(Double(MLX.Memory.snapshot().activeMemory) / 1_048_576))",
                ])
            case .validation(let iteration, let validationLoss, let validationTime):
                log.write("[LORASIZE-VAL", [
                    "idx=\(position)", "id=\(conditionID)",
                    "at_iter=\(iteration + 1)",
                    "val_loss=\(sizeFixed(Double(validationLoss), digits: 4))",
                    "val_s=\(sizeFixed(validationTime, digits: 3))",
                ])
            case .save:
                break
            }
            return .more
        }
    } catch {
        adapter.unload(from: model)
        MLX.Memory.clearCache()
        log.write("[LORASIZE-UNLOAD", [
            "idx=\(position)", "id=\(conditionID)",
            "on=train_failure",
            "residual_lora_layers=\(model.namedModules().filter { $0.1 is LoRALayer }.count)",
        ])
        throw error
    }

    let trainSeconds = startedAt.duration(to: ContinuousClock().now).milliseconds / 1000

    // 学習の作業領域を返してから生成へ入る。
    // **返さないと、生成の `peak_mb` に学習の山が混ざる。**
    MLX.Memory.clearCache()

    return TrainOutcome(
        adapter: adapter,
        adaptedModules: adaptedModules,
        trainableParameters: trainableParameters,
        lossFirst: losses.first,
        lossLast: losses.last,
        trainSeconds: trainSeconds,
        reportSeconds: reportSeconds,
        stepsPerReport: stepsPerReport)
}

/// 剥がす。**必ず呼ぶこと**（成功経路でも失敗経路でも）。
///
/// `residual_lora_layers` が 0 でなければ、次の条件はこの条件の上に積み上がっている。
private func unloadAdapter(
    container: ModelContainer,
    training: TrainOutcome,
    conditionID: String,
    position: String,
    log: SampleSizeLog
) async {
    let residual = await container.perform { context -> Int in
        training.adapter.unload(from: context.model)
        MLX.Memory.clearCache()
        return context.model.namedModules().filter { $0.1 is LoRALayer }.count
    }
    log.write("[LORASIZE-UNLOAD", [
        "idx=\(position)", "id=\(conditionID)",
        // **0 でなければ次の条件は汚れている。** 読み飛ばさないこと。
        "residual_lora_layers=\(residual)",
    ] + sizeMemoryFields(MLX.Memory.snapshot()))
}

// MARK: - 生成と判定

/// 同じ問い・同じ種で生成し、様式が乗ったかを機械で判定する。
///
/// **引数はすべて `Sendable` である。** `ModelContext` を関数の境界へ出さないため、
/// ストリームは `container.perform` の**同期**クロージャの中で開いて外へ返す
/// （`MLXEngine.performChat` が出荷経路でやっているのと同じ形）。
private func generateAndJudge(
    container: ModelContainer,
    promptTokens: [[Int]],
    config: SampleSizeConfiguration,
    conditionID: String,
    position: String,
    trainExamples: Int,
    log: SampleSizeLog
) async throws -> GenerationTally {
    var verdicts: [StyleVerdict] = []
    var seconds: [Double] = []
    var truncated = 0

    for (promptIndex, tokens) in promptTokens.enumerated() {
        for seedIndex in 0 ..< config.seeds {
            let seed = UInt64(SampleSizeConfiguration.seedBase + seedIndex)
            let startedAt = ContinuousClock().now
            let parameters = GenerateParameters(
                maxTokens: config.maxTokens,
                temperature: config.temperature,
                seed: seed)

            // `[Int]` から直に組む。テンプレートの適用は問いを作った時点で
            // 一度だけ済ませてある ── **条件ごとに作り直さない**（同じ入力であることの担保）。
            let stream = try await container.perform { context -> AsyncStream<Generation> in
                try MLXLMCommon.generate(
                    input: LMInput(tokens: MLXArray(tokens)),
                    parameters: parameters,
                    context: context)
            }

            var raw = ""
            var stopReason = "-"
            var generatedTokens = 0
            for await item in stream {
                switch item {
                case .chunk(let text):
                    raw += text
                case .info(let info):
                    stopReason = String(describing: info.stopReason)
                    generatedTokens = info.generationTokenCount
                default:
                    break
                }
            }

            let elapsed = startedAt.duration(to: ContinuousClock().now).milliseconds / 1000
            seconds.append(elapsed)

            // **思考は出荷物で落とす。** 判定用に自前の切り出しを書かない
            // （書けば「出荷物とは別の何か」を測ることになる）。
            let split = StyleRule.separateThinking(raw)
            let verdict = StyleRule.judge(split.content)
            verdicts.append(verdict)
            if generatedTokens >= config.maxTokens { truncated += 1 }

            log.write("[LORASIZE-GEN", [
                "idx=\(position)", "id=\(conditionID)",
                "n=\(trainExamples)",
                "prompt=\(promptIndex)", "seed=\(seed)",
                "pass=\(verdict.passed ? 1 : 0)",
                "bullet_ratio=\(sizeFixed(verdict.bulletRatio))",
                "first_bullet=\(verdict.firstLineIsBullet ? 1 : 0)",
                "lines=\(verdict.lines)", "bullets=\(verdict.bulletLines)",
                "distinct_bullets=\(verdict.distinctBulletLines)",
                "chars=\(verdict.characters)",
                "thinking_chars=\(split.thinking.count)",
                "gen_tokens=\(generatedTokens)",
                "stop=\(sizeSafeValue(stopReason))",
                "s=\(sizeFixed(elapsed))",
                "why=\(verdict.summary)",
            ])

            // **全文を出す。判定規則が間違っていても、人が読めば分かるように。**
            // これが無いと「合格率 0.17」が正しいのかを後から誰も確かめられない。
            log.write("[LORASIZE-OUT-BEGIN", [
                "idx=\(position)", "id=\(conditionID)",
                "prompt=\(promptIndex)", "seed=\(seed)",
            ])
            FileHandle.standardError.write(Data("\(raw)\n".utf8))
            log.write("[LORASIZE-OUT-END", [
                "idx=\(position)", "id=\(conditionID)",
                "prompt=\(promptIndex)", "seed=\(seed)",
            ])
        }
    }

    return GenerationTally(
        generations: verdicts.count,
        passed: verdicts.filter(\.passed).count,
        meanBulletRatio: sizeMean(verdicts.map(\.bulletRatio)),
        firstLineBulletRate: sizeMean(verdicts.map { $0.firstLineIsBullet ? 1.0 : 0.0 }),
        meanChars: sizeMean(verdicts.map { Double($0.characters) }),
        degenerate: verdicts.filter(\.degenerate).count,
        truncated: truncated,
        medianSeconds: sizeMedian(seconds))
}

// MARK: - 判定規則（**器そのもの**）

/// 「答えの全行を `- ` で始める」という様式が乗ったかを、意味を読まずに判定する。
///
/// **規則を先に決めて、後から動かさないこと。** 結果を見てから閾値を動かせば、
/// それは測定ではなく作文である。
private enum StyleRule {

    /// 合格に要る `- ` 行の割合。
    static let minimumBulletRatio = 0.8
    /// 合格に要る `- ` 行の数。
    static let minimumBulletLines = 2
    /// 合格に要る本文の長さ。**崩壊した出力を合格にしないための下限。**
    static let minimumCharacters = 30

    static let description =
        "first_line_bullet_AND_ratio>=\(minimumBulletRatio)"
        + "_AND_bullets>=\(minimumBulletLines)_AND_distinct>=2"
        + "_AND_chars>=\(minimumCharacters)"

    struct Fixture: Sendable {
        let name: String
        let text: String
    }

    /// **通ってはいけない見本。** 規則が「何でも合格」になっていないことの検査に使う。
    ///
    /// 2つ目は**素の Qwen3 の典型**である（前置き1文 → 箇条書き → まとめ1文）。
    /// **これを落とせない規則は、学習前から通ってしまう。**
    static let rejectionFixtures: [Fixture] = [
        Fixture(
            name: "prose",
            text: "バックアップとは、大切なデータの複製を別の場所に保つことです。"
                + "定期的に取ることと、別の媒体に置くことが大切です。"),
        Fixture(
            name: "intro-bullets-outro",
            text: """
                以下のポイントが重要です。

                - 定期的に取る
                - 別の場所に置く

                以上を守れば安心です。
                """),
        Fixture(
            name: "numbered",
            text: """
                1. 定期的に取る
                2. 別の場所に置く
                3. 復元を試す
                """),
        Fixture(name: "single-short-bullet", text: "- はい"),
        Fixture(
            name: "collapsed-repeat",
            text: """
                - あ
                - あ
                - あ
                - あ
                """),
    ]

    /// 思考テキストと本文に分ける。**出荷物（`ThinkingSplitter`）を使う。**
    /// ここで自前の切り出しを書けば、測るのは出荷される経路ではなくなる。
    static func separateThinking(_ raw: String) -> (thinking: String, content: String) {
        var splitter = ThinkingSplitter()
        var thinking = ""
        var content = ""
        for segment in splitter.process(raw) + splitter.finalize() {
            switch segment {
            case .thinking(let text): thinking += text
            case .content(let text): content += text
            }
        }
        return (thinking, content)
    }

    static func judge(_ content: String) -> StyleVerdict {
        // 行頭の空白だけ落とす（入れ子の箇条書きも `- ` として数える）。
        // **行そのものは削らない** ── 空行を数から外すだけである。
        let lines =
            content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                String(line.drop { character in character == " " || character == "\t" })
            }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        let bullets = lines.filter { $0.hasPrefix("- ") }
        let distinct = Set(bullets).count
        let firstIsBullet = lines.first?.hasPrefix("- ") ?? false
        let characters = content.trimmingCharacters(in: .whitespacesAndNewlines).count
        let ratio = lines.isEmpty ? 0 : Double(bullets.count) / Double(lines.count)

        // **崩壊の検出。** 学習を掛けすぎると `- あ` を並べるだけの出力になる。
        // 割合だけ見ていると、それが満点で通る。
        let degenerate = characters < minimumCharacters || distinct < 2

        var reason = "ok"
        if lines.isEmpty {
            reason = "empty"
        } else if !firstIsBullet {
            reason = "first_line_not_bullet"
        } else if ratio < minimumBulletRatio {
            reason = "ratio_low"
        } else if bullets.count < minimumBulletLines {
            reason = "too_few_bullets"
        } else if distinct < 2 {
            reason = "repeated_bullets"
        } else if characters < minimumCharacters {
            reason = "too_short"
        }

        return StyleVerdict(
            lines: lines.count,
            bulletLines: bullets.count,
            distinctBulletLines: distinct,
            firstLineIsBullet: firstIsBullet,
            bulletRatio: ratio,
            characters: characters,
            degenerate: degenerate,
            passed: reason == "ok",
            summary: reason)
    }
}

private struct StyleVerdict: Sendable {
    let lines: Int
    let bulletLines: Int
    let distinctBulletLines: Int
    let firstLineIsBullet: Bool
    let bulletRatio: Double
    let characters: Int
    let degenerate: Bool
    let passed: Bool
    let summary: String
}

// MARK: - 題材

/// 学習データと評価用の問い。
///
/// **学習の題材と評価の題材は重ねない。** 重ねれば測っているのは暗記である。
/// 答えの中身は**内容を持たない**（どの話題にも当てはまる一般論）にしてある ──
/// **様式だけを学ばせるため**であり、話題まで覚えてしまう危険を避けるためである（14.10節）。
/// 同時に、**嘘を学習させないため**でもある。
private enum StyleCorpus {

    static let validationCount = 2

    /// 学習に使う題材。**評価の題材と1つも重ねないこと。**
    /// 意図的に生活まわりの雑多な語にしてある ── 専門的な話題だと、
    /// 様式ではなく「その分野の答え方」を学んでしまう。
    static let trainingTopics: [String] = [
        "献立の決め方", "洗濯物の干し方", "名刺の整理", "傘の選び方", "掃除の順番",
        "靴の手入れ", "冷蔵庫の中身の管理", "部屋の照明", "観葉植物の置き場", "郵便物の仕分け",
        "買い物メモの作り方", "家具の配置", "鍋の選び方", "包丁の研ぎ方", "弁当の詰め方",
        "ゴミ出しの管理", "布団の手入れ", "タオルの替え時", "食器の収納", "調味料の補充",
        "電池の備え", "工具箱の中身", "駐輪場の使い方", "傘立ての置き場", "玄関の整理",
        "窓の結露", "換気の習慣", "加湿器の掃除", "米の保存", "味噌の使い切り",
        "冷凍庫の整理", "まな板の衛生", "鍵の予備", "印鑑の保管", "保証書の保管",
        "領収書の整理", "名前シールの貼り方", "衣替えの手順", "靴下の組み合わせ", "帽子の収納",
        "マフラーの洗い方", "手袋の紛失対策", "傘の修理", "メガネの拭き方", "時計の電池交換",
        "充電の習慣", "イヤホンの絡み対策", "ケーブルの管理", "リモコンの置き場", "電球の交換",
        "スリッパの替え時", "ペン立ての整理",
    ]

    /// 問いの言い回し。`{topic}` を題材で置き換える。
    ///
    /// **「箇条書きで」と書かないこと** ── 書いた瞬間、学習データが
    /// 「指示に従う例」になり、様式を重みに入れる話ではなくなる。
    static let questionForms: [String] = [
        "{topic}について教えて。",
        "{topic}、どう考えればいい？",
        "{topic}の要点を知りたい。",
        "{topic}について、短くまとめて。",
        "{topic}はどう進めるのがいい？",
        "{topic}で気をつけることは？",
    ]

    /// 箇条書きの頭。
    static let leads: [String] = ["結論", "理由", "手順", "注意", "前提", "確認", "次の一手", "例"]

    /// 箇条書きの中身。**題材に依存しない一般論だけ**にしてある。
    static let bodies: [String] = [
        "目的と制約を先に決めると判断しやすい。",
        "小さく試して、結果を記録するのが安い。",
        "費用と手間の兼ね合いで選択肢が変わる。",
        "分からない点を1つに絞ると前へ進む。",
        "既にあるものを数えてから足すのが順序である。",
        "先に測って、それから直すこと。",
        "戻せる状態を保ったまま変えること。",
        "決めた理由を1行だけ残しておくこと。",
    ]

    /// 評価に使う問い。**学習の題材と重ねない。**
    /// どれも**散文で答えたくなる**言い回しにしてある ──
    /// 学習前の合格率を低く保つことが、この計測が成立する条件だからである。
    static let evaluationPrompts: [String] = [
        "バックアップとは何か、短く説明して。",
        "朝の集中力を上げるにはどうすればいい？",
        "読書の記録を続けるコツを教えて。",
        "引っ越しの準備で最初にやることは何？",
        "自転車の選び方について教えて。",
        "休日の過ごし方について、あなたの考えを聞かせて。",
    ]

    /// 陽性対照で足す指示文。**これが「重みに書かなかった場合に毎ターン払う額」である。**
    static let styleInstruction =
        "答えはすべて「- 」で始まる箇条書きにしてください。前置きもまとめの文も書かないでください。"

    struct Pair: Sendable {
        let question: String
        let answer: String
    }

    /// 決定的に組む。**乱数を使わない** ── 同じ件数なら毎回同じデータになること。
    ///
    /// 題材（52）と言い回し（6）は別の周期で回るので、
    /// **先頭 100 件の中に同じ「題材 × 言い回し」は現れない**（最小公倍数は 156）。
    /// 箇条書きの数は 2〜4 で変える ── 行数まで固定すると、
    /// 様式ではなく「3行で答える型」を覚える。
    static func pairs(count: Int) -> [Pair] {
        (0 ..< count).map { index in
            let topic = trainingTopics[index % trainingTopics.count]
            let form = questionForms[index % questionForms.count]
            let bulletCount = 2 + (index % 3)
            let answer = (0 ..< bulletCount)
                .map { position -> String in
                    let lead = leads[(index + position * 3) % leads.count]
                    let body = bodies[(index * 3 + position * 5) % bodies.count]
                    return "- \(lead)：\(topic)は\(body)"
                }
                .joined(separator: "\n")
            return Pair(
                question: form.replacingOccurrences(of: "{topic}", with: topic),
                answer: answer)
        }
    }
}

// MARK: - 学習データ（本番と同じ形式で作る）

/// 学習へ渡る文字列そのもの。
///
/// `Lora+Data.swift`（`loadLoRAData`）が返すのは `[String]` で、
/// それを `LoRABatchIterator` が `tokenizer.encode(text:)` に掛ける。
/// つまり**学習が見るのはチャットテンプレート適用後の文**である。
/// だからここでも `container.prepare` を通した実物から作る（自前で `<|im_start|>` を書かない）。
///
/// > **【未確認】末尾に生成用の頭が1つ余分に付く。**
/// > `prepare` は生成用に組むので、`[user, assistant]` を渡すと
/// > 「答え → 終端 → **次にアシスタントが話す頭**」で終わる。
/// > **終端が入るほうが重要**なので、この形をそのまま使っている
/// > （終端を落とすと、答えの止め方を学ばせられない）。
/// > 余分な頭は**全条件・全件で同一**なので、件数どうしの比較は歪まない。
/// > 実際の形は `[LORASIZE-CORPUS-BEGIN/END]` の現物で確認すること。
private struct StyleTrainingCorpus: Sendable {
    let train: [String]
    let validate: [String]
    /// **実測**のトークン長。
    let tokenCounts: [Int]
    /// decode → encode で数が変わった件数。**0 でなければ、学習が見る文は prepare の文と違う。**
    let roundTripMismatches: Int

    var medianTokens: Int {
        sizeMedian(tokenCounts.map { Double($0) }).map { Int($0) } ?? 0
    }

    var fields: [String] {
        [
            "examples=\(train.count)",
            "validate=\(validate.count)",
            "tok_min=\(tokenCounts.min() ?? 0)",
            "tok_med=\(medianTokens)",
            "tok_max=\(tokenCounts.max() ?? 0)",
            // **2048 を超えると `LoRABatchIterator` が警告を出し、メモリも跳ねる。**
            "over_2048=\(tokenCounts.filter { $0 > 2048 }.count)",
            "roundtrip_mismatch=\(roundTripMismatches)",
        ]
    }

    /// **`UserInput` はここで作る。呼び出し側で組み立てないこと。**
    ///
    /// `UserInput` も `Chat.Message` も `Sendable` ではないのに、
    /// `ModelContainer.prepare(input:)` は `consuming sending UserInput` で受け取る。
    /// **呼び出し地点に書くと、外側のローカル変数と同じ領域に居ると判定され**、
    /// `sending value of non-Sendable type 'UserInput' risks causing data races` で落ちる。
    /// **関数から返せば新鮮な領域として扱われる**（`LoRAFeasibilityTests` に同じ記録がある）。
    private static func input(
        question: String, answer: String, thinkingEnabled: Bool
    ) -> UserInput {
        var messages: [Chat.Message] = []
        if SophiaDefaults.systemPromptEnabled {
            messages.append(.system(SophiaDefaults.systemPrompt))
        }
        messages.append(.user(question))
        messages.append(.assistant(answer))
        return UserInput(
            chat: messages,
            additionalContext: ["enable_thinking": thinkingEnabled] as [String: any Sendable])
    }

    static func make(
        container: ModelContainer,
        pairs: [StyleCorpus.Pair],
        thinkingEnabled: Bool
    ) async throws -> StyleTrainingCorpus {
        var texts: [String] = []
        var counts: [Int] = []
        var mismatches = 0

        for pair in pairs {
            let prepared = try await container.prepare(
                input: Self.input(
                    question: pair.question, answer: pair.answer,
                    thinkingEnabled: thinkingEnabled))
            let tokens = prepared.text.tokens.asArray(Int.self)

            // 数える前に `let` へ写しているのは Swift 6 の要請である
            // （`container.perform` のクロージャは `@Sendable` で、可変のローカル変数を
            // そのまま捕まえられない）。
            let ids = tokens
            let text = await container.perform { context in
                context.tokenizer.decode(tokenIds: ids)
            }
            let probe = text
            let reencoded = await container.perform { context in
                context.tokenizer.encode(text: probe).count
            }

            // **改行を潰さない。** `<|im_start|>system\n` の `\n` は区切りであって飾りではない。
            // 潰した状態で測れば、それは本番の形ではない文字列を測ったことになる。
            texts.append(text)
            counts.append(tokens.count)
            if reencoded != tokens.count { mismatches += 1 }
        }

        // 検証は末尾から取る。**空にしないこと** ── `LoRATrain.evaluate` は
        // 0件だと合計を件数0で割ることになり、値が NaN になる。
        let validationCount = StyleCorpus.validationCount
        return StyleTrainingCorpus(
            train: Array(texts.dropLast(validationCount)),
            validate: Array(texts.suffix(validationCount)),
            tokenCounts: Array(counts.dropLast(validationCount)),
            roundTripMismatches: mismatches)
    }
}

/// 評価に使う問いを、**トークン列にしてから**持ち回るもの。
///
/// `LMInput` も `UserInput` も `Sendable` ではないので、条件をまたいで持てない。
/// `[Int]` にしておけば `container.perform` のクロージャへそのまま渡せるし、
/// **条件ごとにテンプレートを適用し直さずに済む**（同じ入力であることの担保）。
private struct StylePromptSet: Sendable {
    let tokens: [[Int]]

    var medianTokens: Int {
        sizeMedian(tokens.map { Double($0.count) }).map { Int($0) } ?? 0
    }

    private static func input(
        prompt: String, instruction: String?, thinkingEnabled: Bool
    ) -> UserInput {
        let body = instruction.map { "\(prompt)\n\($0)" } ?? prompt
        var messages: [Chat.Message] = []
        if SophiaDefaults.systemPromptEnabled {
            messages.append(.system(SophiaDefaults.systemPrompt))
        }
        messages.append(.user(body))
        return UserInput(
            chat: messages,
            additionalContext: ["enable_thinking": thinkingEnabled] as [String: any Sendable])
    }

    static func make(
        container: ModelContainer,
        prompts: [String],
        instruction: String?,
        thinkingEnabled: Bool
    ) async throws -> StylePromptSet {
        var all: [[Int]] = []
        for prompt in prompts {
            let prepared = try await container.prepare(
                input: Self.input(
                    prompt: prompt, instruction: instruction,
                    thinkingEnabled: thinkingEnabled))
            all.append(prepared.text.tokens.asArray(Int.self))
        }
        return StylePromptSet(tokens: all)
    }
}

// MARK: - 条件と結果

private struct SizeCondition: Sendable {
    static let baselineID = "n0-plain"
    static let instructedID = "n0-instructed"

    let id: String
    /// 0 なら学習しない（対照）。
    let trainExamples: Int
    /// 問いに様式の指示文を足すか（陽性対照）。
    let instructed: Bool
}

/// 学習1回ぶんの記録。`LoRAContainer` は `@unchecked Sendable` なので持ち回せる。
private struct TrainOutcome: Sendable {
    let adapter: LoRAContainer
    let adaptedModules: Int
    let trainableParameters: Int
    let lossFirst: Float?
    let lossLast: Float?
    let trainSeconds: Double
    let reportSeconds: [Double]
    let stepsPerReport: Int
}

/// 生成1条件ぶんの集計。
private struct GenerationTally: Sendable {
    let generations: Int
    let passed: Int
    let meanBulletRatio: Double
    let firstLineBulletRate: Double
    let meanChars: Double
    let degenerate: Int
    let truncated: Int
    let medianSeconds: Double?
}

private struct SizeConditionResult: Sendable {
    let id: String
    let position: String
    let trainExamples: Int
    let instructed: Bool
    let iterations: Int
    let tally: GenerationTally
    let training: TrainOutcome?
    let baseTotalMB: Double
    let peakMB: Double
    let peakOverBaseMB: Double

    var passRate: Double {
        tally.generations > 0 ? Double(tally.passed) / Double(tally.generations) : 0
    }

    var meanChars: Double { tally.meanChars }

    /// 1ステップの秒。**初回の報告は捨てる**（Metal のカーネル生成を含む）。
    var secondsPerIteration: Double? {
        guard let training,
            let median = sizeMedian(Array(training.reportSeconds.dropFirst()))
        else { return nil }
        return median / Double(training.stepsPerReport)
    }

    /// **同じなら更新が起きていない。**
    var lossMoved: Bool {
        guard let training, let first = training.lossFirst, let last = training.lossLast
        else { return false }
        return first != last
    }

    /// 学習条件なのに更新が起きていなければ、**この行の合格率は件数の結論ではない。**
    var trusted: Bool {
        guard trainExamples > 0 else { return true }
        guard let training else { return false }
        return training.adaptedModules > 0 && lossMoved
    }

    var fields: [String] {
        [
            "idx=\(position)", "id=\(id)",
            "n=\(trainExamples)",
            "instructed=\(instructed ? 1 : 0)",
            // **件数とステップ数は必ず並べて出す。** 片方だけで結論を書けないように。
            "iters=\(iterations)",
            "ok=1",
            // --- 本丸 ---
            "pass=\(tally.passed)/\(tally.generations)",
            "pass_rate=\(sizeFixed(passRate))",
            "bullet_ratio_mean=\(sizeFixed(tally.meanBulletRatio))",
            "first_bullet_rate=\(sizeFixed(tally.firstLineBulletRate))",
            "chars_mean=\(sizeFixed(tally.meanChars, digits: 1))",
            // **崩壊。** 合格率が上がっていても、ここが増えていれば学習が壊している。
            "degenerate=\(tally.degenerate)",
            "truncated=\(tally.truncated)",
            // --- 器の確認 ---
            "adapted_modules=\(training.map { String($0.adaptedModules) } ?? "-")",
            "trainable_params=\(training.map { String($0.trainableParameters) } ?? "-")",
            "loss_first=\(sizeFixed(training?.lossFirst.map { Double($0) }, digits: 4))",
            "loss_last=\(sizeFixed(training?.lossLast.map { Double($0) }, digits: 4))",
            // **0 なら結果を信用しない。**
            "loss_moved=\(lossMoved ? 1 : 0)",
            "trusted=\(trusted ? 1 : 0)",
            // --- 費用 ---
            "train_s=\(sizeFixed(training?.trainSeconds))",
            "per_iter_s=\(sizeFixed(secondsPerIteration, digits: 3))",
            "gen_s_med=\(sizeFixed(tally.medianSeconds))",
            "base_total_mb=\(sizeFixed(baseTotalMB))",
            "peak_mb=\(sizeFixed(peakMB))",
            "peak_over_base_mb=\(sizeFixed(peakOverBaseMB))",
        ]
    }
}

private enum SampleSizeProbeError: Error {
    /// **計測の器が壊れている。** 数字は出るが対象を測っていない。
    case instrumentBroken(String)

    var summary: String {
        switch self {
        case .instrumentBroken(let detail):
            sizeSafeValue(detail)
        }
    }
}

/// 読み手向けの1行。**判定そのものではない。**
/// `key=value` に載せるので**空白を含めない**（`ToolLogValue` の約束）。
private func verdictText(
    baseline: SizeConditionResult?,
    instructed: SizeConditionResult?,
    risesAt: Int?
) -> String {
    guard baseline != nil, instructed != nil else { return "対照が取れていない" }
    guard let risesAt else {
        return "掃いた件数では立ち上がらなかった__10.5節側（数千件）を否定できない"
    }
    return "\(risesAt)件で立ち上がった__第14章側（数十〜数百件）と整合"
}

// MARK: - 設定

private struct SampleSizeConfiguration: Sendable {
    /// 生成の種の起点。**全条件で同じ種を使う**（対にして比べるため）。
    static let seedBase = 9_000

    let modelID: String
    let sampleSizes: [Int]
    let epochs: Int
    let fixedIterations: Int
    let layers: Int
    let rank: Int
    let batch: Int
    let learningRate: Float
    let keys: [String]?
    let seeds: Int
    let maxTokens: Int
    let temperature: Float
    let thinkingEnabled: Bool
    let stepsPerReport: Int
    let baselineMax: Double
    let instructedMin: Double
    let priorIterationSeconds: Double
    let priorGenerationSeconds: Double
    let cacheLimitBytes: Int
    let label: String

    var maxSampleSize: Int { sampleSizes.max() ?? 0 }
    var iterationsAreFixed: Bool { fixedIterations > 0 }

    var generationsPerCondition: Int {
        StyleCorpus.evaluationPrompts.count * seeds
    }

    /// **対照を先に、学習を安い順に。**
    /// 対照が先なのは、判定規則が壊れていたときに**学習を1回も回さずに落とせる**からである。
    var conditions: [SizeCondition] {
        var all: [SizeCondition] = [
            SizeCondition(id: SizeCondition.baselineID, trainExamples: 0, instructed: false),
            SizeCondition(id: SizeCondition.instructedID, trainExamples: 0, instructed: true),
        ]
        all.append(
            contentsOf: sampleSizes.map {
                SizeCondition(id: "n\($0)", trainExamples: $0, instructed: false)
            })
        return all
    }

    func iterations(for examples: Int) -> Int {
        guard examples > 0 else { return 0 }
        if iterationsAreFixed { return fixedIterations }
        return max(1, Int(ceil(Double(examples * epochs) / Double(batch))))
    }

    func priorSeconds(for condition: SizeCondition) -> Double {
        Double(iterations(for: condition.trainExamples)) * priorIterationSeconds
            + Double(generationsPerCondition) * priorGenerationSeconds
    }

    static func fromEnvironment() -> SampleSizeConfiguration {
        // **入れ子にするため昇順に並べ、重複を落とす。**
        let sizes = Array(Set(sizeIntList("SOPHIA_LORASIZE_N", default: [20, 50, 100])))
            .filter { $0 > 0 }
            .sorted()

        let rawKeys = sizeStringEnv("SOPHIA_LORASIZE_KEYS", default: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return SampleSizeConfiguration(
            modelID: sizeStringEnv("SOPHIA_LORASIZE_MODEL", default: SophiaDefaults.modelID),
            sampleSizes: sizes.isEmpty ? [20] : sizes,
            epochs: max(1, sizeIntEnv("SOPHIA_LORASIZE_EPOCHS", default: 4)),
            fixedIterations: max(0, sizeIntEnv("SOPHIA_LORASIZE_ITERS", default: 0)),
            // 14.13a節の実測で最も損失が動いた条件（16層 / rank 8 / batch 1）。
            layers: max(1, sizeIntEnv("SOPHIA_LORASIZE_LAYERS", default: 16)),
            rank: max(1, sizeIntEnv("SOPHIA_LORASIZE_RANK", default: 8)),
            batch: max(1, sizeIntEnv("SOPHIA_LORASIZE_BATCH", default: 1)),
            learningRate: Float(sizeStringEnv("SOPHIA_LORASIZE_LR", default: "1e-5")) ?? 1e-5,
            keys: rawKeys.isEmpty ? nil : rawKeys,
            // **n=1 で判定しない**（第15章）。
            seeds: max(1, sizeIntEnv("SOPHIA_LORASIZE_SEEDS", default: 2)),
            maxTokens: max(32, sizeIntEnv("SOPHIA_LORASIZE_MAXTOK", default: 220)),
            temperature: Float(sizeStringEnv("SOPHIA_LORASIZE_TEMP", default: "0.7")) ?? 0.7,
            thinkingEnabled: sizeBoolEnv("SOPHIA_LORASIZE_THINK", default: false),
            stepsPerReport: max(1, sizeIntEnv("SOPHIA_LORASIZE_REPORT", default: 10)),
            baselineMax: Double(sizeStringEnv("SOPHIA_LORASIZE_BASELINE_MAX", default: "0.34"))
                ?? 0.34,
            instructedMin: Double(
                sizeStringEnv("SOPHIA_LORASIZE_INSTRUCTED_MIN", default: "0.50")) ?? 0.50,
            priorIterationSeconds: Double(
                sizeStringEnv("SOPHIA_LORASIZE_PRIOR_ITER_S", default: "6.0")) ?? 6.0,
            priorGenerationSeconds: Double(
                sizeStringEnv("SOPHIA_LORASIZE_PRIOR_GEN_S", default: "18.0")) ?? 18.0,
            cacheLimitBytes: sizeIntEnv(
                "SOPHIA_LORASIZE_CACHE_LIMIT_MB",
                default: SophiaDefaults.mlxCacheLimitBytes / 1_048_576) * 1_048_576,
            label: sizeStringEnv("SOPHIA_LORASIZE_LABEL", default: "")
                .replacingOccurrences(of: " ", with: "_"))
    }
}

// MARK: - ログ

/// **`print` を使わない。** アプリの `[STATS]` / `[MEM]` と同じ経路（生の `write(2)`）に
/// 揃えてあり、`2> logs/lora-sample-size.log` でそのまま拾える。
///
/// **`Sendable` にしておくこと。** `container.perform` のクロージャは `@Sendable` で、
/// この値はその中まで運ばれる。
private struct SampleSizeLog: Sendable {
    let label: String
    let startedAt: ContinuousClock.Instant = ContinuousClock().now

    init(label: String) {
        self.label = label
    }

    /// `prefix` は閉じ括弧なしで渡す（`"[LORASIZE"` など）。ここで `]` を足す。
    func write(_ prefix: String, _ fields: [String]) {
        var all: [String] = []
        if !label.isEmpty { all.append("label=\(label)") }
        all.append("t=\(Self.wallClock())")
        all.append(
            "elapsed_s=\(sizeFixed(startedAt.duration(to: ContinuousClock().now).milliseconds / 1000, digits: 1))"
        )
        all.append(contentsOf: fields)
        FileHandle.standardError.write(Data("\(prefix)] \(all.joined(separator: " "))\n".utf8))
    }

    /// 壁時計。`scripts/probe-watch.sh` の `[SYS] t=HH:MM:SS` と突き合わせるために要る。
    private static func wallClock() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

/// `MLXMemoryReading.logFields` と**同じキー名**に揃える（`[MEM]` と並べて読むため）。
private func sizeMemoryFields(_ snapshot: MLX.Memory.Snapshot) -> [String] {
    [
        "active_mb=\(sizeFixed(Double(snapshot.activeMemory) / 1_048_576))",
        "cache_mb=\(sizeFixed(Double(snapshot.cacheMemory) / 1_048_576))",
        "total_mb=\(sizeFixed(Double(snapshot.activeMemory + snapshot.cacheMemory) / 1_048_576))",
        "peak_mb=\(sizeFixed(Double(snapshot.peakMemory) / 1_048_576))",
    ]
}

/// **潰しは自前で書かない。** `ToolLogValue.sanitized` を使う。
/// あれが「stderr の1行に出してよい形」の判断を1か所に持っている。
/// 64スカラーで切られるので、**全文が要る値は `key=value` に載せずに
/// `BEGIN` / `END` で挟んで別行に出すこと。**
private func sizeSafeValue(_ text: String) -> String {
    ToolLogValue.sanitized(text)
}

/// 中央値。**平均ではなく中央値を単価の基準にする** ── 他プロセスの割り込みや
/// 熱による1点の跳ねに、見積り全体を引きずられないため。
private func sizeMedian(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count % 2 == 1 { return sorted[middle] }
    return (sorted[middle - 1] + sorted[middle]) / 2
}

private func sizeMean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

/// 小数の整形。**欠測は `0` ではなく `-` にする**（`[STATS]` と同じ約束）。
/// 0 で埋めると「測ったら0だった」と区別が付かなくなる。
private func sizeFixed(_ value: Double?, digits: Int = 2) -> String {
    value.map { String(format: "%.\(digits)f", $0) } ?? "-"
}

// MARK: - 環境変数

private func sizeStringEnv(_ key: String, default fallback: String) -> String {
    let raw = ProcessInfo.processInfo.environment[key]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw, !raw.isEmpty else { return fallback }
    return raw
}

private func sizeIntEnv(_ key: String, default fallback: Int) -> Int {
    Int(sizeStringEnv(key, default: "")) ?? fallback
}

/// `"20,50,100"` を `[20, 50, 100]` に割る。数として読めない要素は捨てる
/// （全部捨てたら既定へ戻す）。`SOPHIA_LORA_LAYERS` と同じ約束。
private func sizeIntList(_ key: String, default fallback: [Int]) -> [Int] {
    let parsed = sizeStringEnv(key, default: "")
        .split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    return parsed.isEmpty ? fallback : parsed
}

/// `1` / `true` / `yes` を真、`0` / `false` / `no` を偽と読む。
/// **それ以外は既定に倒す。** 打ち間違いで条件が黙って変わるより、既定のほうがまだ読める。
private func sizeBoolEnv(_ key: String, default fallback: Bool) -> Bool {
    switch sizeStringEnv(key, default: "").lowercased() {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return fallback
    }
}
