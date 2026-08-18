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
//  LoRA が16GB機で回るか ── 「動く／動かない」ではなく「いくら要るか」を測る
// -----------------------------------------------------------------------------
//  ## この計測は何の判断のためにあるか
//
//  **パーソナライズ（FR-24〜29 / DESIGN 第14章）を「毎ターン注入」から
//  「重みに書く」へ変えられるかどうか。** それだけである。
//
//  | 形 | 毎ターンの費用 |
//  |---|--:|
//  | プロンプト注入（現設計） | **N トークン × 会話が続く限り永久** |
//  | LoRA（重みに書く）       | **0** |
//
//  そして注入する余地は既に無い。`SophiaDefaults.InputBudget` の配分は
//  総額 1,000 に対し 前置き 105 ＋ ツール定義 322 ＋ 読み取り 360 ＋ 栞 180 で、
//  **利用者に残るのは 33 トークンである。**
//  つまり「LoRA が回るか」は好みの問題ではなく、第14章が成立するかどうかである。
//
//  ## 測るもの（4つ。すべて「量」であって合否ではない）
//
//  | | 何を | どう |
//  |---|---|---|
//  | 1 | 学習中の最大確保量 | `MLX.Memory.snapshot()`。`MLXEngine` の `[MEM]` 計装と同じキー名 |
//  | 2 | 1イテレーションの単価 | 進捗コールバック間の壁時計。**外挿の材料** |
//  | 3 | `numLayers` / `rank` / `batch` / トークン長を振ったときの上記 | 掃引 |
//  | 4 | 学習後のアダプタの実寸 | 保存したファイルのバイト数 |
//
//  **判定はしない。** このファイルが落ちるのは「計測そのものが成立しなかったとき」
//  だけである（下の「器が対象を測っているかの確認」）。
//  遅い・大きいでは落とさない ── それは読み手が決めることである。
//
//  ## 器が対象を測っているかの確認（本日9件の誤りを繰り返さないために）
//
//  2026-08-18、同種の誤りが9件出た。極端な例は「プローブがテスト内の見本を測っており
//  12/12 だから使える、が実装の値ではなかった」である。
//  **LoRA の計測は、これと同じ壊れ方をしやすい。**
//  `LoRAContainer.from` は対象の層が1つも見つからなくても**例外を投げない** ──
//  `replaceLayers` は該当が無ければ黙って何もしないからである。
//  その状態で `LoRATrain.train` を回すと、
//  **勾配の当たる重みが1つも無いまま「学習」が最後まで通る。**
//  速く、軽く、損失も動かない。そして「16GBで余裕で回りました」という嘘が出る。
//
//  そこで各条件の測定の前に、次の3つを実測して `[LORA-APPLY]` に出し、
//  **0 なら以降を測らずに落とす**（`LoRAProbeError.instrumentBroken`）:
//
//  | 値 | 出所 | 0 だったら |
//  |---|---|---|
//  | `adapted_modules`  | `model.namedModules()` のうち `LoRALayer` の数 | 差し替えが1つも起きていない |
//  | `trainable_tensors`| `model.trainableParameters().flattened().count` | 勾配の当たる重みが無い |
//  | `trainable_params` | 同上の `size` の総和 | 同上 |
//
//  さらに `loss_first` / `loss_last` を必ず出す。**完全に同じなら更新が起きていない。**
//  そして 1イテレーションの秒数は**2系統**出す ──
//  こちらの壁時計（`s=`）と、ライブラリ自身の申告（`lib_it_s=`）。
//  **食い違ったら、どちらかの測り方が壊れている。**
//
//  ## 前提と落とし穴
//
//  - **`SOPHIA_ENGINE=stub` を必ず入れること。** 入れないとホストアプリ（`Sophia.app`）が
//    自前でモデルを読み、**同一プロセスに 4.4GB が2つ載って測定値がちょうど倍になる。**
//    2026-08-18 に実際に踏んだ。`make lora` は入れてある。
//    入っているかは `[LORA-PRE]` の `engine=` と `active_mb=` で確認できる ──
//    **ロード前に `active_mb` が GB 級なら、既に誰かが載せている。**
//  - **`MLX.Memory.cacheLimit` を明示的に揃える。** `MLXEngine.init` はこれを 20MB に
//    落としているが、このテストは `MLXEngine` を1行も通らないので**既定のまま
//    （＝ほぼ無制限）になる。** 揃えないと `cache_mb` が数GB出て、
//    アプリの条件と比較できない数字になる。
//  - **`peak_mb` / RSS / pageins は GPU メモリの residency を測らない**（2026-08-17 実測）。
//    ここが答えるのは「**MLX が何をどれだけ確保したか**」だけである。
//    「それが物理RAMに載っているか」は系全体の数字でしか分からない ──
//    **必ず別窓で `make probe-watch` を先に回すこと。**
//  - **4.6GB の取得を計測に混ぜない。** ローカルに実体が無ければ測らずに降りる。
//
//  ## 起動ゲート
//
//  **`SOPHIA_LORA=1` のときだけ走る。** 通常の `make app-test`（全80件・1秒未満）に
//  混ざると 4.4GB を読み込んで開発が止まる。
//  ゲートは `setUpWithError()` に置いてある（＝後からメソッドを足しても書き忘れようがない）。
//
//  ## 環境変数
//
//  | 変数 | 既定 | 意味 |
//  |---|---|---|
//  | `SOPHIA_LORA`          | （無し） | **`1` のときだけ実行** |
//  | `SOPHIA_LORA_LAYERS`   | `2,4,8,16` | `numLayers`。**カンマ区切りで掃引**（下記） |
//  | `SOPHIA_LORA_RANK`     | `8`      | `rank`。カンマ区切り可 |
//  | `SOPHIA_LORA_BATCH`    | `1`      | `batchSize`。カンマ区切り可 |
//  | `SOPHIA_LORA_TOKENS`   | `256`    | 1件あたりの**目標**トークン長。カンマ区切り可 |
//  | `SOPHIA_LORA_ITERS`    | `8`      | 1条件あたりのイテレーション数。**単価を測るためだけの数** |
//  | `SOPHIA_LORA_EXAMPLES` | `16`     | 学習データの件数 |
//  | `SOPHIA_LORA_LR`       | `1e-5`   | 学習率（`training.md` の例と同じ）。資源には効かない |
//  | `SOPHIA_LORA_KEYS`     | （無し） | 対象の射影を明示（例 `self_attn.q_proj,self_attn.v_proj`）。**無指定＝ライブラリ既定** |
//  | `SOPHIA_LORA_CACHE_LIMIT_MB` | `SophiaDefaults.mlxCacheLimitBytes` | MLX のキャッシュ上限。**既定はアプリと同条件** |
//  | `SOPHIA_LORA_KEEP`     | `0`      | `1` で保存したアダプタを消さずに残す |
//  | `SOPHIA_LORA_MODEL`    | `SophiaDefaults.modelID` | 0.6B に落として配管だけ先に通せる |
//  | `SOPHIA_LORA_LABEL`    | 空       | ログに付ける自由記述 |
//
//  ### 掃引の順序 ── **必ず安いほうから回す**
//
//  条件は `layers × rank × batch × tokens` の直積を作り、
//  **費用の目安（`layers × rank × batch × tokens`）の昇順に並べ替えてから回す。**
//  16GB機で高い条件を先に踏むと、系ごと落ちて**安い条件の結果まで失われる。**
//  結果は1条件ぶん出るたびに stderr へ生の `write(2)` で吐くので、
//  **途中で殺されても、そこまでの行はログに残る。**
//  何が回らなかったかは冒頭の `[LORA-PLAN]` と突き合わせれば分かる。
//
//  ### なぜこの4つを振るのか（`numLayers` と `rank` は効き方が違う）
//
//  | 変数 | 何に効くか |
//  |---|---|
//  | `numLayers` | **メモリの主因。** 逆伝播が何層ぶん遡るかが決まり、その間の活性値が生き続ける |
//  | `rank`      | **ほぼ寸法の話。** 追加パラメータは層あたり `2 × r × 次元` で、メモリにはほとんど効かない。**アダプタの実寸と容量に効く** |
//  | `batchSize` | 活性値に線形に効く。16GB では 1 から動かせない可能性がある |
//  | トークン長  | 同上。**注意: `LoRABatchIterator` はバッチ内の最長に合わせて詰める** |
//
//  つまり「16GBで回らなければ減らす」の**減らす先はまず `numLayers`** であって
//  `rank` ではない。既定の掃引を `layers=2,4,8,16 / rank=8` にしてあるのはそのためである。
//  `rank` を振りたくなるのは、層数が決まったあとの**アダプタ実寸の設計**の局面である。
//
//  ## 出力（すべて **stderr** へ1行1レコード）
//
//  | プレフィックス | 何の行か |
//  |---|---|
//  | `[LORA-BEGIN]`  | 条件の記録。**この行が無いログは条件不明として捨てること** |
//  | `[LORA-PLAN]`   | これから回す条件の一覧（安い順）。**何が回らなかったかはこれと比べて分かる** |
//  | `[LORA-PRE]`    | ロード**前**の MLX の会計。二重ロードの検出点 |
//  | `[LORA-LOAD]`   | ロードの実測。以降の `peak_mb` はここからの増分で読む |
//  | `[LORA-CORPUS]` | 学習データの実測（**目標ではなく実際のトークン長**） |
//  | `[LORA-CORPUS-BEGIN/END]` | その**現物**。挟まれた行が実際に学習へ渡る1件そのもの |
//  | `[LORA-APPLY]`  | 差し替えの実測。**器が対象を測っているかの確認はここ** |
//  | `[LORA-ITER]`   | 1行1イテレーション。**メモリが増え続けていないか**を見る行 |
//  | `[LORA-VAL]`    | 検証（0イテレーション目に必ず1回入る。ライブラリの仕様） |
//  | `[LORA-CFG]`    | **1行1条件。本丸。** |
//  | `[LORA-UNLOAD]` | 片付けの実測。`residual_lora_layers=0` でなければ次条件が汚れている |
//  | `[LORA-EST]`    | **外挿。** `extrapolated=1` を必ず付ける。実測ではない |
//  | `[LORA-VERDICT]`| 読み手向けの材料。**判定そのものではない** |
//  | `[LORA-END]`    | 終了。**この行が無ければ途中で殺されている** |
//
//  ### `[LORA-CFG]` の読み方（この計測の結論はこの行にある）
//
//  ```
//  [LORA-CFG] idx=3/4 layers=8 rank=8 batch=1 tokens=256 iters=8 ok=1 \
//    iter1_s=… steady_s_med=… steady_s_mean=… steady_s_min=… steady_s_max=… \
//    lib_it_s_med=… lib_tok_s_med=… \
//    base_total_mb=… peak_mb=… peak_over_base_mb=… end_total_mb=… \
//    mem_grow_mb=… mem_growing=0 \
//    trainable_params=… trainable_mb=… adapted_modules=… \
//    adapter_bytes=… adapter_mb=… config_bytes=… save_s=… \
//    loss_first=… loss_last=…
//  ```
//
//  | 見るところ | 意味 |
//  |---|---|
//  | `peak_over_base_mb` | **学習が上乗せする量。** モデル 4.4GB に対していくら足りるかがこれ |
//  | `mem_growing=1`     | **イテレーションを重ねるとメモリが増え続けている。** この条件の外挿は無効。長い学習は落ちる |
//  | `iter1_s` ≫ `steady_s_med` | 正常（初回は Metal のカーネル生成を含む）。**外挿には `steady_s_med` を使う** |
//  | `s=` と `lib_it_s=` が食い違う | どちらかの測り方が壊れている。**数字を採用する前にここを見る** |
//  | `loss_first == loss_last` | **更新が起きていない。** 資源の数字も信用できない |
//
//  ## 使い方
//
//  ```
//  make probe-build              # 1回だけ（計測のたびにビルドしない）
//  （別窓で） make probe-watch    # 系全体の数字。**これ無しで結論を出さない**
//  make lora
//  ```
//
//  **計測前に起動中の `Sophia` を落とすこと**（`pkill -x Sophia`）。
//  4.4GB を持つプロセスが2つ居れば、測っているのは学習の費用ではなくメモリ争奪である。
//  同じ理由で Ollama も止めておくこと。
// =============================================================================

final class LoRAFeasibilityTests: XCTestCase {

    // MARK: - 起動ゲート

    /// **ここが「通常の `make app-test` では絶対に走らない」の実体。**
    ///
    /// `PrefillProbeTests` と同じく `setUpWithError()` に置く。
    /// このクラスに後からメソッドを足した人がゲートを書き忘れても、
    /// **構造的に走りようが無い**ようにするため。
    override func setUpWithError() throws {
        try super.setUpWithError()
        try Self.requireProbeEnabled()
        // 1条件失敗したまま残りを回しても、条件が崩れた後の数字が並ぶだけで読めない。
        continueAfterFailure = false
    }

    private static func requireProbeEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SOPHIA_LORA"] == "1",
            "LoRA の資源計測です。`SOPHIA_LORA=1` を付けたときだけ走ります"
                + "（4.4GB を読み込み、条件によっては数十分かかるため）")
    }

    // MARK: - 本丸

    func testLoRATrainingCost() async throws {
        // setUpWithError と重複しているが**意図的**。二重に掛けておく価値がある。
        try Self.requireProbeEnabled()

        let config = LoRAProbeConfiguration.fromEnvironment()
        let log = LoRAProbeLog(label: config.label)

        // --- モデルの実体が無ければ測らずに降りる -----------------------------
        //
        // ここで 4.4GB を取りに行かせない。**取得そのものがディスクキャッシュと
        // メモリ圧を動かし、これから測ろうとしている対象を壊す。**
        try XCTSkipUnless(
            MLXModelCatalog.isDownloaded(config.modelID),
            "\(config.modelID) がローカルに無い。"
                + "先にアプリを起動して取得してから測ること"
                + "（4.4GB の取得を計測セッションに混ぜると条件が壊れる）")

        // **MLX の会計をアプリと同じ条件へ揃える。**
        // このテストは `MLXEngine` を1行も通らないので、揃えないと
        // `cacheLimit` が既定（ほぼ無制限）のままになり `cache_mb` が数GB出る。
        MLX.Memory.cacheLimit = config.cacheLimitBytes

        // --- ロード「前」の会計 ------------------------------------------------
        //
        // **二重ロードの検出点。** ここで `active_mb` が GB 級なら、
        // このプロセスに既に別のモデルが載っている（＝`SOPHIA_ENGINE=stub` が効いていない）。
        // 以降の数字はすべて倍になる。
        let pre = MLX.Memory.snapshot()

        log.write("[LORA-BEGIN", [
            "model=\(config.modelID)",
            "conditions=\(config.grid.count)",
            "iters=\(config.iterations)",
            "examples=\(config.exampleCount)",
            "lr=\(config.learningRate)",
            "keys=\(config.keys?.joined(separator: "|") ?? "library-default")",
            "cache_limit_mb=\(loraFixed(Double(config.cacheLimitBytes) / 1_048_576, digits: 1))",
            "system_prompt=\(SophiaDefaults.systemPromptEnabled ? 1 : 0)",
            "physical_ram_mb=\(ProcessInfo.processInfo.physicalMemory / 1_048_576)",
        ])

        // **回す順序を先に全部出す。** 途中で系ごと落ちたとき、
        // 「何が回らなかったか」はこの行と `[LORA-CFG]` の差分でしか分からない。
        for (index, unit) in config.grid.enumerated() {
            log.write("[LORA-PLAN", [
                "idx=\(index + 1)/\(config.grid.count)",
                "layers=\(unit.layers)", "rank=\(unit.rank)",
                "batch=\(unit.batch)", "tokens_target=\(unit.targetTokens)",
                "cost_proxy=\(unit.costProxy)",
            ])
        }

        log.write("[LORA-PRE", [
            "engine=\(ProcessInfo.processInfo.environment["SOPHIA_ENGINE"] ?? "-")",
        ] + loraMemoryFields(pre) + [
            // **ここが 1 なら二重ロードを疑うこと。** ロード前に MLX が
            // 1GB 以上握っているのは、このプロセスに別のモデルが載っている場合だけである。
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

        log.write("[LORA-LOAD", [
            "model=\(config.modelID)",
            "load_s=\(loraFixed(loadSeconds))",
        ] + loraMemoryFields(base))

        // --- 学習データ --------------------------------------------------------
        //
        // **題材は小さくてよいが、形式は本番と同じにする。**
        // `Lora+Data.swift` が読むのは「1行1件の素の文字列」であって、
        // それを `LoRABatchIterator` が `tokenizer.encode(text:)` に掛ける。
        // つまり学習が実際に見るのは**チャットテンプレートを適用し終えた文**である。
        // だからここでも `processor.prepare` を通した実物を作る（自前で組み立てない）。
        var corpora: [Int: LoRACorpus] = [:]
        for tokens in Set(config.grid.map(\.targetTokens)).sorted() {
            let corpus = try await LoRACorpus.make(
                container: container,
                targetTokens: tokens,
                exampleCount: config.exampleCount)
            corpora[tokens] = corpus
            log.write("[LORA-CORPUS", corpus.fields)

            // **現物を丸ごと出す。** 「形式は本番と同じ」は主張であって証拠ではない。
            // 再構成の説明で差を埋めないため、実際に学習へ渡る1件をそのまま挟んで出す
            // （`ToolCostBreakdownTests` の `RENDERED_BEGIN` / `RENDERED_END` と同じ形）。
            log.write("[LORA-CORPUS-BEGIN", ["target_tokens=\(tokens)"])
            FileHandle.standardError.write(Data("\(corpus.sample)\n".utf8))
            log.write("[LORA-CORPUS-END", ["target_tokens=\(tokens)"])
        }

        // --- 掃引（安い順） ----------------------------------------------------
        var results: [LoRAUnitResult] = []
        var failed = 0

        for (index, unit) in config.grid.enumerated() {
            guard let corpus = corpora[unit.targetTokens] else { continue }
            let position = "\(index + 1)/\(config.grid.count)"

            do {
                let result = try await container.perform { context -> LoRAUnitResult in
                    try loraMeasureOne(
                        context: context,
                        unit: unit,
                        position: position,
                        corpus: corpus,
                        config: config,
                        base: base,
                        log: log)
                }
                results.append(result)
                log.write("[LORA-EST", result.extrapolationFields)
            } catch let error as LoRAProbeError {
                // **器が壊れている。** 以降を測っても数字が出るだけで意味が無い。
                log.write("[LORA-ABORT", ["idx=\(position)", "reason=\(error.summary)"])
                throw error
            } catch {
                // この条件は落ちたが、**他の条件は測れる。**
                // 16GB機では「落ちた」こと自体が結果である。
                failed += 1
                log.write("[LORA-CFG", [
                    "idx=\(position)",
                    "layers=\(unit.layers)", "rank=\(unit.rank)",
                    "batch=\(unit.batch)", "tokens_target=\(unit.targetTokens)",
                    "iters=\(config.iterations)",
                    "ok=0",
                    // **1行1レコードを崩さない。** 例外の文言には改行が入りうる。
                    "error=\(loraSafeValue(String(describing: error)))",
                ])
            }
        }

        // --- 読み手向けの材料（判定そのものではない）---------------------------
        let peaks = results.map(\.peakOverBaseMB)
        log.write("[LORA-VERDICT", [
            "measured=\(results.count)/\(config.grid.count)",
            "failed=\(failed)",
            "cheapest=\(results.first?.label ?? "-")",
            "dearest_ok=\(results.last?.label ?? "-")",
            "peak_over_base_mb_min=\(loraFixed(peaks.min()))",
            "peak_over_base_mb_max=\(loraFixed(peaks.max()))",
            "base_total_mb=\(loraFixed(Double(base.activeMemory + base.cacheMemory) / 1_048_576))",
            // **これは MLX の帳簿であって、物理RAMに載っているかではない。**
            // 16GB に収まるかの判定は `make probe-watch` の系全体の数字と
            // 突き合わせて初めて言える。
            "note=MLX_accounting_only__residency_needs_vm_stat",
        ])

        log.write("[LORA-END", ["conditions_done=\(results.count)/\(config.grid.count)"])

        // **計測が1本も取れなかったときだけ落とす。** 遅い・大きいでは落とさない。
        XCTAssertFalse(
            results.isEmpty,
            "1条件も測れていない。ログに `[LORA-CFG] ok=1` の行が1つも無い")
    }
}

// MARK: - 1条件の計測

/// 1つの条件（layers × rank × batch × tokens）を測る。
///
/// **`ModelContext` を受け取るので、必ず `container.perform` の中から呼ぶこと。**
/// `LanguageModel` も `Tokenizer` も `Sendable` ではない。
///
/// 戻り値は `Sendable` な数値の束だけである（`MLXArray` を1つも外に出さない）。
/// ログは**この関数の中から**出す ── そうしないと
/// `APPLY → ITER → CFG → UNLOAD` の順序が崩れ、途中で殺されたときに読めなくなる。
private func loraMeasureOne(
    context: ModelContext,
    unit: LoRAGridUnit,
    position: String,
    corpus: LoRACorpus,
    config: LoRAProbeConfiguration,
    base: MLX.Memory.Snapshot,
    log: LoRAProbeLog
) throws -> LoRAUnitResult {
    let model = context.model
    let tokenizer = context.tokenizer

    let beforeApply = MLX.Memory.snapshot()

    // `scale` は既定のまま（`LoRAConfiguration.LoRAParameters` の既定＝10.0）。
    // **数字を書き写さない** ── 書き写した瞬間、ライブラリの既定が変わっても気づけない。
    let loraConfiguration = LoRAConfiguration(
        numLayers: unit.layers,
        fineTuneType: .lora,
        loraParameters: .init(rank: unit.rank, keys: config.keys))

    let adapter = try LoRAContainer.from(model: model, configuration: loraConfiguration)

    // **必ず剥がす。** 途中で失敗しても剥がす ── 剥がし忘れると
    // 次の条件がこの条件の上に積み上がり、そこから先の数字が全部嘘になる。
    defer {
        adapter.unload(from: model)
        MLX.Memory.clearCache()
        let afterUnload = MLX.Memory.snapshot()
        let residual = model.namedModules().filter { $0.1 is LoRALayer }.count
        log.write("[LORA-UNLOAD", [
            "idx=\(position)",
            // **0 でなければ次の条件は汚れている。** 読み飛ばさないこと。
            "residual_lora_layers=\(residual)",
        ] + loraMemoryFields(afterUnload)
            + ["d_active_mb=\(loraFixed(loraDeltaMB(afterUnload.activeMemory, beforeApply.activeMemory)))"])
    }

    // --- 器が対象を測っているかの確認 --------------------------------------
    //
    // **`LoRAContainer.from` は対象が1つも無くても例外を投げない。**
    // `replaceLayers` は該当が無ければ黙って何もしない。
    // その状態でも `LoRATrain.train` は最後まで通り、速く・軽く・それらしい数字を出す。
    // だから「差し替えが起きたこと」を実測してから測る。
    let adaptedModules = model.namedModules().filter { $0.1 is LoRALayer }.count
    let trainables = model.trainableParameters().flattened()
    let trainableTensors = trainables.count
    let trainableParams = trainables.reduce(0) { $0 + $1.1.size }
    let trainableBytes = trainables.reduce(0) { $0 + $1.1.nbytes }
    let loraLayerTotal = (model as? LoRAModel)?.loraLayers.count ?? -1
    let resolvedKeys = config.keys ?? (model as? LoRAModel)?.loraDefaultKeys ?? []

    let afterApply = MLX.Memory.snapshot()
    log.write("[LORA-APPLY", [
        "idx=\(position)",
        "layers=\(unit.layers)/\(loraLayerTotal)",
        "rank=\(unit.rank)",
        "scale=\(loraConfiguration.loraParameters.scale)",
        "keys=\(resolvedKeys.count)",
        "keys_list=\(resolvedKeys.sorted().joined(separator: "|"))",
        "adapted_modules=\(adaptedModules)",
        "trainable_tensors=\(trainableTensors)",
        "trainable_params=\(trainableParams)",
        "trainable_mb=\(loraFixed(Double(trainableBytes) / 1_048_576))",
    ] + loraMemoryFields(afterApply)
        + ["d_active_mb=\(loraFixed(loraDeltaMB(afterApply.activeMemory, beforeApply.activeMemory)))"])

    guard adaptedModules > 0, trainableTensors > 0, trainableParams > 0 else {
        throw LoRAProbeError.instrumentBroken(
            "差し替えが1つも起きていない"
                + "（adapted_modules=\(adaptedModules) trainable_tensors=\(trainableTensors)）。"
                + "この状態で学習を回すと、勾配の当たる重みが無いまま最後まで通り、"
                + "「軽くて速い」という嘘の結果が出る")
    }

    // --- 学習 ---------------------------------------------------------------
    //
    // **既定のハイパーパラメータ（iterations: 1000）では回さない。** 何時間もかかる。
    // 少ない回数で単価を測り、外挿する（外挿は `[LORA-EST]` に隔離してある）。
    //
    // `stepsPerReport: 1` ─ 毎イテレーション報告させる。**単価を測るのが目的**なので、
    // 既定の10回まとめだと8回では2点しか取れない。
    // `stepsPerEval` / `saveEvery` ─ 事実上無効化する。
    // ただし**0イテレーション目の検証だけはライブラリが無条件で走らせる**
    // （`iteration == 0 ||` の項）。これは外せないので、区間から差し引いて測る。
    let optimizer = Adam(learningRate: config.learningRate)
    let parameters = LoRATrain.Parameters(
        batchSize: unit.batch,
        iterations: config.iterations,
        stepsPerReport: 1,
        stepsPerEval: config.iterations + 1_000_000,
        validationBatches: 1,
        saveEvery: config.iterations + 1_000_000,
        adapterURL: nil)

    // **`peakMemory` はプログラム開始からの最大値なので、条件ごとに必ず落とす。**
    // 落とさないと、前の条件の山がそのまま次の条件の `peak_mb` になる
    // （`MLXEngine` が生成のたびに同じことをしているのと同じ理由）。
    // なお setter は値を無視して単にリセットする（MLX の API がそうなっている）。
    MLX.Memory.peakMemory = 0

    var iterationSeconds: [Double] = []
    var iterationLosses: [Float] = []
    var libIterationsPerSecond: [Double] = []
    var libTokensPerSecond: [Double] = []
    var validationSeconds: [Double] = []
    var iterationPeaks: [Int] = []

    // **区間の起点は「直前にコールバックが鳴った時刻」である。**
    // 単に前回の `.train` からの差を取ると、0イテレーション目の後に入る検証の時間が
    // 1イテレーション目の単価に乗ってしまう（＝単価が数倍に見える）。
    // 種類を問わず「直前の事象」からの差を取れば、その混入が構造的に起きない。
    var previousEventAt = ContinuousClock().now
    let trainStartedAt = previousEventAt

    try LoRATrain.train(
        model: model,
        train: corpus.train,
        validate: corpus.validate,
        optimizer: optimizer,
        tokenizer: tokenizer,
        parameters: parameters
    ) { progress in
        let now = ContinuousClock().now
        let seconds = previousEventAt.duration(to: now).milliseconds / 1000
        previousEventAt = now

        switch progress {
        case .train(let iteration, let loss, let iterationsPerSecond, let tokensPerSecond):
            let snapshot = MLX.Memory.snapshot()
            iterationSeconds.append(seconds)
            iterationLosses.append(loss)
            libIterationsPerSecond.append(iterationsPerSecond)
            libTokensPerSecond.append(tokensPerSecond)
            iterationPeaks.append(snapshot.peakMemory)

            let libraryIterationSeconds: Double? =
                iterationsPerSecond > 0 ? 1 / iterationsPerSecond : nil

            log.write("[LORA-ITER", [
                "idx=\(position)",
                "iter=\(iteration + 1)/\(parameters.iterations)",
                "loss=\(loraFixed(Double(loss), digits: 4))",
                // こちらの壁時計。**外挿にはこれを使う。**
                "s=\(loraFixed(seconds, digits: 3))",
                // ライブラリ自身の申告。**上と食い違ったら測り方が壊れている。**
                "lib_it_s=\(loraFixed(libraryIterationSeconds, digits: 3))",
                "lib_tok_s=\(loraFixed(tokensPerSecond, digits: 1))",
            ] + loraMemoryFields(snapshot))

        case .validation(let iteration, let validationLoss, let validationTime):
            validationSeconds.append(validationTime)
            log.write("[LORA-VAL", [
                "idx=\(position)",
                "at_iter=\(iteration + 1)",
                "val_loss=\(loraFixed(Double(validationLoss), digits: 4))",
                "val_s=\(loraFixed(validationTime, digits: 3))",
            ])

        case .save(let iteration, let url):
            log.write("[LORA-SAVE", [
                "idx=\(position)",
                "at_iter=\(iteration + 1)",
                "url=\(url.lastPathComponent)",
            ])
        }

        return .more
    }

    let trainSeconds = trainStartedAt.duration(to: ContinuousClock().now).milliseconds / 1000
    let afterTrain = MLX.Memory.snapshot()

    // --- アダプタの実寸（配布・保存の設計に効く）----------------------------
    //
    // **計算値ではなく実ファイルのバイト数を出す。**
    // `trainable_params × 4` と食い違ったら、どちらかの前提が間違っている
    // （dtype が float32 でない／保存が一部を落としている、など）。
    // 保存の形は `LoRAContainer.from(directory:)` が読む形に揃える
    // ─ `adapters.safetensors` ＋ `adapter_config.json`。
    // **名前を変えると「配布物の実寸」ではなくなる。**
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "sophia-lora-\(unit.label)", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let weightsURL = directory.appending(component: "adapters.safetensors")
    let configURL = directory.appending(component: "adapter_config.json")

    let saveStartedAt = ContinuousClock().now
    try LoRATrain.saveLoRAWeights(model: model, url: weightsURL)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(loraConfiguration).write(to: configURL)
    let saveSeconds = saveStartedAt.duration(to: ContinuousClock().now).milliseconds / 1000

    let weightsBytes = loraFileSize(weightsURL)
    let configBytes = loraFileSize(configURL)

    if !config.keepAdapters {
        try? FileManager.default.removeItem(at: directory)
    }

    // --- 集計 ---------------------------------------------------------------
    //
    // **1回目は捨てる。** 初回は Metal のカーネル生成と遅延確保を含み、
    // 定常の単価ではない。捨てたことが分かるよう `iter1_s` は別に出す。
    let steady = Array(iterationSeconds.dropFirst())
    let steadyLibIterations = Array(libIterationsPerSecond.dropFirst())
    let steadyLibTokens = Array(libTokensPerSecond.dropFirst())

    // メモリが**増え続けていないか**。増え続けているなら長い学習は落ちる ＝ 外挿は無効。
    let peakAtSecond = iterationPeaks.count >= 2 ? iterationPeaks[1] : (iterationPeaks.first ?? 0)
    let peakAtLast = iterationPeaks.last ?? 0
    let memoryGrowthMB = loraDeltaMB(peakAtLast, peakAtSecond)

    let result = LoRAUnitResult(
        position: position,
        unit: unit,
        iterations: config.iterations,
        measuredIterations: iterationSeconds.count,
        firstIterationSeconds: iterationSeconds.first,
        steadyMedianSeconds: loraMedian(steady),
        steadyMeanSeconds: steady.isEmpty ? nil : steady.reduce(0, +) / Double(steady.count),
        steadyMinSeconds: steady.min(),
        steadyMaxSeconds: steady.max(),
        // 0 で埋めずに落とす。**0 を混ぜると中央値ごと嘘になる**（欠測は `-` の約束と同じ）。
        libraryMedianIterationSeconds: loraMedian(
            steadyLibIterations.compactMap { rate -> Double? in
                rate > 0 ? 1 / rate : nil
            }),
        libraryMedianTokensPerSecond: loraMedian(steadyLibTokens),
        totalTrainSeconds: trainSeconds,
        validationSeconds: validationSeconds.first,
        saveSeconds: saveSeconds,
        baseTotalMB: Double(base.activeMemory + base.cacheMemory) / 1_048_576,
        peakMB: Double(afterTrain.peakMemory) / 1_048_576,
        peakOverBaseMB: loraDeltaMB(afterTrain.peakMemory, base.activeMemory + base.cacheMemory),
        endTotalMB: Double(afterTrain.activeMemory + afterTrain.cacheMemory) / 1_048_576,
        memoryGrowthMB: memoryGrowthMB,
        trainableParameters: trainableParams,
        trainableMB: Double(trainableBytes) / 1_048_576,
        adaptedModules: adaptedModules,
        adapterBytes: weightsBytes,
        adapterConfigBytes: configBytes,
        firstLoss: iterationLosses.first,
        lastLoss: iterationLosses.last,
        corpusMedianTokens: corpus.medianTokens)

    log.write("[LORA-CFG", result.fields)
    return result
}

// MARK: - 条件

/// 1つの条件。**直積で作り、費用の目安の昇順に並べ替えてから回す。**
private struct LoRAGridUnit: Sendable {
    let layers: Int
    let rank: Int
    let batch: Int
    let targetTokens: Int

    /// 並べ替えの鍵。**厳密な費用ではない ── 順序さえ付けば目的を果たす。**
    /// 高い条件を先に踏んで系ごと落ちると、安い条件の結果まで失われる。それを避けるためだけの数。
    var costProxy: Int { layers * rank * batch * targetTokens }

    var label: String { "L\(layers)-R\(rank)-B\(batch)-T\(targetTokens)" }
}

private struct LoRAProbeConfiguration: Sendable {
    let modelID: String
    let grid: [LoRAGridUnit]
    let iterations: Int
    let exampleCount: Int
    let learningRate: Float
    let keys: [String]?
    let cacheLimitBytes: Int
    let keepAdapters: Bool
    let label: String

    static func fromEnvironment() -> LoRAProbeConfiguration {
        let layers = loraIntList("SOPHIA_LORA_LAYERS", default: [2, 4, 8, 16])
        let ranks = loraIntList("SOPHIA_LORA_RANK", default: [8])
        let batches = loraIntList("SOPHIA_LORA_BATCH", default: [1])
        let tokens = loraIntList("SOPHIA_LORA_TOKENS", default: [256])

        var grid: [LoRAGridUnit] = []
        for layer in layers where layer > 0 {
            for rank in ranks where rank > 0 {
                for batch in batches where batch > 0 {
                    for token in tokens where token > 0 {
                        grid.append(
                            LoRAGridUnit(
                                layers: layer, rank: rank, batch: batch, targetTokens: token))
                    }
                }
            }
        }
        // **安い順。** 16GB機では、この並べ替えが結果を守る唯一の手段である。
        grid.sort { ($0.costProxy, $0.layers, $0.rank) < ($1.costProxy, $1.layers, $1.rank) }

        let rawKeys = loraStringEnv("SOPHIA_LORA_KEYS", default: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return LoRAProbeConfiguration(
            modelID: loraStringEnv("SOPHIA_LORA_MODEL", default: SophiaDefaults.modelID),
            grid: grid,
            iterations: max(2, loraIntEnv("SOPHIA_LORA_ITERS", default: 8)),
            exampleCount: max(4, loraIntEnv("SOPHIA_LORA_EXAMPLES", default: 16)),
            learningRate: Float(loraStringEnv("SOPHIA_LORA_LR", default: "1e-5")) ?? 1e-5,
            keys: rawKeys.isEmpty ? nil : rawKeys,
            cacheLimitBytes: loraIntEnv(
                "SOPHIA_LORA_CACHE_LIMIT_MB",
                default: SophiaDefaults.mlxCacheLimitBytes / 1_048_576) * 1_048_576,
            keepAdapters: loraBoolEnv("SOPHIA_LORA_KEEP", default: false),
            label: loraStringEnv("SOPHIA_LORA_LABEL", default: "")
                .replacingOccurrences(of: " ", with: "_"))
    }
}

// MARK: - 学習データ

/// 学習データ。**題材は小さくてよいが、形式は本番と同じにする。**
///
/// `Lora+Data.swift`（`loadLoRAData`）が返すのは `[String]` で、
/// それを `LoRABatchIterator` が `tokenizer.encode(text:)` に掛ける。
/// つまり**学習が見るのはチャットテンプレート適用後の文**である。
/// だからここでも `processor.prepare` を通した実物から作る（自前で `<|im_start|>` を書かない）。
///
/// **改行は保持する。** 本番の置き場は `.jsonl`（`{"text": "…\n…"}`）で、
/// あれは改行を保持する。`.txt` のほうは行で割るので改行を持てないが、
/// **どちらにせよここは `loadLoRAData` を通らない** ── `[String]` を直接
/// `LoRATrain.train` へ渡すので、ディスク上の表現の制約は掛からない。
/// 逆に潰すと `<|im_start|>system\n` の区切りが別のトークンに化け、
/// **本番の形ではない文字列を測ることになる。**
///
/// > **【未確認】** 末尾の扱い。`prepare` は生成用に組むので、
/// > 最後は「アシスタントがこれから話す」ところで終わる。
/// > 本番の学習データはそこにアシスタントの返答と終端が続く形になるはずだが、
/// > **その終端トークンの綴りをここで決め打ちしていない**（決め打ちは嘘の元）。
/// > 返答本文は連結してあるので**トークン数と形はほぼ本番どおり**であり、
/// > 資源の計測（活性値の量とバッチの形）には影響しない。
/// > 学習の**質**を論じるときは、この点を先に確定させること。
private struct LoRACorpus: Sendable {
    let targetTokens: Int
    let train: [String]
    let validate: [String]
    /// **実測**のトークン長（目標ではない）。
    let tokenCounts: [Int]
    /// 学習に渡る1件目の**現物**。`key=value` には載せず、`BEGIN`/`END` で挟んで出す。
    let sample: String

    var medianTokens: Int { loraMedian(tokenCounts.map { Double($0) }).map { Int($0) } ?? 0 }

    var fields: [String] {
        [
            "target_tokens=\(targetTokens)",
            "examples=\(train.count)",
            "validate=\(validate.count)",
            "tok_min=\(tokenCounts.min() ?? 0)",
            "tok_med=\(medianTokens)",
            "tok_max=\(tokenCounts.max() ?? 0)",
            // **2048 を超えると `LoRABatchIterator` が警告を出し、メモリも跳ねる。**
            "over_2048=\(tokenCounts.filter { $0 > 2048 }.count)",
            "sample_chars=\(sample.count)",
        ]
    }

    /// **`UserInput` はここで作る。呼び出し側で組み立てないこと。**
    ///
    /// `UserInput` も `Chat.Message` も **`Sendable` ではない**（MLX_SWIFT.md 4.4節）のに、
    /// `ModelContainer.prepare(input:)` は `consuming sending UserInput` で受け取る。
    /// **呼び出し地点に書くと、外側のローカル変数と同じ領域に居ると判定され**、
    /// `sending value of non-Sendable type 'UserInput' risks causing data races` で落ちる。
    ///
    /// **関数から返せば新鮮な領域として扱われる。**
    /// `MLXEngine` が `nonisolated static func chatMessages(for:)` を持っているのと同じ理由で、
    /// **同じ罠を2026-08-18 にここでも踏んだ**（インライン化では直らなかった）。
    ///
    /// 引数は `Sendable` なものだけにすること ── 非 `Sendable` を渡した時点で領域が繋がる。
    private static func userInput(index: Int, sentence: String) -> UserInput {
        let messages: [Chat.Message] =
            SophiaDefaults.systemPromptEnabled
            ? [
                .system(SophiaDefaults.systemPrompt),
                .user("\(index + 1)件目。\(sentence)"),
            ]
            : [.user("\(index + 1)件目。\(sentence)")]
        return UserInput(
            chat: messages,
            additionalContext: ["enable_thinking": false] as [String: any Sendable])
    }

    static func make(
        container: ModelContainer,
        targetTokens: Int,
        exampleCount: Int
    ) async throws -> LoRACorpus {
        // 1件ぶんの伸ばし単位。**日本語で作る** ── 本番の題材が日本語なので、
        // 1トークンあたりの文字数（＝同じ文字数でも token 数が違う）を本番と揃える。
        let sentence = "この端末の中だけで動く前提で、手元の資料を読んで短くまとめてください。"

        var examples: [String] = []
        var counts: [Int] = []

        for index in 0 ..< (exampleCount + 2) {
            // 本番と同じ組み方（`ChatViewModel` が送る形）。自己認識も本番と同じものを使う。
            let prepared = try await container.prepare(
                input: Self.userInput(index: index, sentence: sentence))
            let promptTokens = prepared.text.tokens.asArray(Int.self)
            let promptText = await container.perform { context in
                context.tokenizer.decode(tokenIds: promptTokens)
            }

            // 返答ぶんを、目標トークン長に届くまで伸ばす。
            // **足し算で見積もらず、毎回数え直す** ── BPE は境界でくっつくので、
            // 「単位のトークン数 × 回数」は実際の値とずれる。
            //
            // 数える前に `let` へ写しているのは Swift 6 の要請である。
            // `container.perform` のクロージャは `@Sendable` で、
            // **可変のローカル変数はそのまま捕まえられない。**
            var text = promptText
            var count = promptTokens.count
            var guardCounter = 0
            while count < targetTokens && guardCounter < 400 {
                guardCounter += 1
                text += sentence
                let probe = text
                count = await container.perform { context in
                    context.tokenizer.encode(text: probe).count
                }
            }

            // **改行を潰さない。**
            //
            // > 一度ここで `\n` を空白に置換していた。理由は「`loadLoRAData` は
            // > 行単位で読むから」── **その理由がこの経路には当てはまらない。**
            // > `loadLoRAData` を通っていない（`[String]` を直接 `train` に渡している）し、
            // > 本番の置き場は `.jsonl` で、あちらは改行を `\n` として**保持する**。
            // > そして潰すと**チャットテンプレートの区切りが別のトークンに化ける** ──
            // > `<|im_start|>system\n` の `\n` は区切りであって飾りではない。
            // > 潰した状態で測れば、それは**本番の形ではない文字列**を測ったことになる。
            examples.append(text)
            counts.append(count)
        }

        // 検証は2件。**空にしないこと** ── `LoRATrain.evaluate` は
        // 0件だと合計を件数0で割ることになり、値が NaN になる。
        return LoRACorpus(
            targetTokens: targetTokens,
            train: Array(examples.dropLast(2)),
            validate: Array(examples.suffix(2)),
            tokenCounts: Array(counts.dropLast(2)),
            // **「本番と同じ形式」は主張ではなく現物で示す。**
            // 再構成した説明ではなく、実際に学習へ渡る文そのものを出す
            // （`[BREAKDOWN] RENDERED_*` が `tojson` の `\uXXXX` 展開を見つけたのと同じ理由）。
            sample: examples.first ?? "")
    }
}

// MARK: - 結果

private struct LoRAUnitResult: Sendable {
    let position: String
    let unit: LoRAGridUnit
    let iterations: Int
    let measuredIterations: Int
    let firstIterationSeconds: Double?
    let steadyMedianSeconds: Double?
    let steadyMeanSeconds: Double?
    let steadyMinSeconds: Double?
    let steadyMaxSeconds: Double?
    let libraryMedianIterationSeconds: Double?
    let libraryMedianTokensPerSecond: Double?
    let totalTrainSeconds: Double
    let validationSeconds: Double?
    let saveSeconds: Double
    let baseTotalMB: Double
    let peakMB: Double
    let peakOverBaseMB: Double
    let endTotalMB: Double
    let memoryGrowthMB: Double
    let trainableParameters: Int
    let trainableMB: Double
    let adaptedModules: Int
    let adapterBytes: Int?
    let adapterConfigBytes: Int?
    let firstLoss: Float?
    let lastLoss: Float?
    let corpusMedianTokens: Int

    var label: String { unit.label }

    var fields: [String] {
        [
            "idx=\(position)",
            "layers=\(unit.layers)", "rank=\(unit.rank)",
            "batch=\(unit.batch)",
            "tokens_target=\(unit.targetTokens)",
            // **実測。** `tokens_target` と食い違うのは正常（BPE は目標ちょうどには乗らない）。
            "tokens_med=\(corpusMedianTokens)",
            "iters=\(iterations)", "measured_iters=\(measuredIterations)",
            "ok=1",
            "iter1_s=\(loraFixed(firstIterationSeconds, digits: 3))",
            "steady_s_med=\(loraFixed(steadyMedianSeconds, digits: 3))",
            "steady_s_mean=\(loraFixed(steadyMeanSeconds, digits: 3))",
            "steady_s_min=\(loraFixed(steadyMinSeconds, digits: 3))",
            "steady_s_max=\(loraFixed(steadyMaxSeconds, digits: 3))",
            // **こちらの壁時計とライブラリの申告。食い違ったら測り方が壊れている。**
            "lib_it_s_med=\(loraFixed(libraryMedianIterationSeconds, digits: 3))",
            "lib_tok_s_med=\(loraFixed(libraryMedianTokensPerSecond, digits: 1))",
            "train_total_s=\(loraFixed(totalTrainSeconds))",
            "val_s=\(loraFixed(validationSeconds, digits: 3))",
            "save_s=\(loraFixed(saveSeconds, digits: 3))",
            "base_total_mb=\(loraFixed(baseTotalMB))",
            "peak_mb=\(loraFixed(peakMB))",
            // **学習が上乗せする量。** モデル 4.4GB に対していくら足りるか。
            "peak_over_base_mb=\(loraFixed(peakOverBaseMB))",
            "end_total_mb=\(loraFixed(endTotalMB))",
            "mem_grow_mb=\(loraFixed(memoryGrowthMB))",
            // **1 なら外挿は無効。** 回数を重ねるとメモリが増え続けている。
            "mem_growing=\(memoryGrowthMB > 64 ? 1 : 0)",
            "trainable_params=\(trainableParameters)",
            "trainable_mb=\(loraFixed(trainableMB))",
            "adapted_modules=\(adaptedModules)",
            "adapter_bytes=\(adapterBytes.map { String($0) } ?? "-")",
            "adapter_mb=\(loraFixed(adapterBytes.map { Double($0) / 1_048_576 }))",
            "config_bytes=\(adapterConfigBytes.map { String($0) } ?? "-")",
            // **アダプタ実寸は3つ並べて突き合わせる。**
            //
            // | 値 | 出所 |
            // |---|---|
            // | `trainable_mb`            | `MLXArray.nbytes` の総和（**実際に確保されている量**） |
            // | `adapter_mb_expected_f32` | `trainable_params × 4`（**float32 だと仮定した場合**） |
            // | `adapter_mb`              | **保存した実ファイル**のバイト数 |
            //
            // 上2つが食い違えば dtype の前提が違う（bf16 なら半分になる）。
            // 3つ目だけ少し大きいのは safetensors のヘッダぶんで正常。
            // **大きく食い違ったら、保存が一部を落としている。**
            "adapter_mb_expected_f32=\(loraFixed(Double(trainableParameters * 4) / 1_048_576))",
            "loss_first=\(loraFixed(firstLoss.map { Double($0) }, digits: 4))",
            "loss_last=\(loraFixed(lastLoss.map { Double($0) }, digits: 4))",
            // **同じなら更新が起きていない。** 資源の数字も信用できない。
            "loss_moved=\(firstLoss != lastLoss ? 1 : 0)",
        ]
    }

    /// **外挿。実測ではない。** `extrapolated=1` を必ず付けること。
    ///
    /// 元にするのは `steady_s_med`（初回を捨てた中央値）である。
    /// 平均でも最小でもないのは、外れ値（他プロセスの割り込み・熱）に引きずられないため。
    ///
    /// **`mem_growing=1` のときこの行は読んではいけない。**
    /// メモリが増え続けている条件では、長い学習は時間の前に落ちる。
    var extrapolationFields: [String] {
        let unitSeconds = steadyMedianSeconds
        func estimate(_ count: Int) -> String {
            guard let unitSeconds else { return "-" }
            let seconds = unitSeconds * Double(count)
            return "\(loraFixed(seconds, digits: 0))s(\(loraFixed(seconds / 60, digits: 1))min)"
        }
        return [
            "idx=\(position)",
            "layers=\(unit.layers)", "rank=\(unit.rank)",
            "batch=\(unit.batch)", "tokens_med=\(corpusMedianTokens)",
            "extrapolated=1",
            "basis=steady_s_med",
            "basis_s=\(loraFixed(unitSeconds, digits: 3))",
            "measured_iters=\(measuredIterations)",
            "iters_50=\(estimate(50))",
            "iters_100=\(estimate(100))",
            "iters_200=\(estimate(200))",
            "iters_500=\(estimate(500))",
            "iters_1000=\(estimate(1000))",
            "valid_if=mem_growing=0",
        ]
    }
}

private enum LoRAProbeError: Error {
    /// **計測の器が壊れている。** 数字は出るが対象を測っていない。
    case instrumentBroken(String)

    var summary: String {
        switch self {
        case .instrumentBroken(let detail):
            loraSafeValue(detail)
        }
    }
}

// MARK: - ログ

/// **`print` を使わない。** アプリの `[STATS]` / `[MEM]` と同じ経路（生の `write(2)`）に
/// 揃えてあり、`2> logs/lora.log` でそのまま拾える。
/// XCTest の標準出力にはランナーの雑音が混ざるので、機械可読な行は stderr に置く。
///
/// **`Sendable` にしておくこと。** `container.perform` のクロージャは `@Sendable` で、
/// この値はその中まで運ばれる。
private struct LoRAProbeLog: Sendable {
    let label: String
    let startedAt: ContinuousClock.Instant = ContinuousClock().now

    init(label: String) {
        self.label = label
    }

    /// `prefix` は閉じ括弧なしで渡す（`"[LORA"` など）。ここで `]` を足す。
    func write(_ prefix: String, _ fields: [String]) {
        var all: [String] = []
        if !label.isEmpty { all.append("label=\(label)") }
        all.append("t=\(Self.wallClock())")
        all.append(
            "elapsed_s=\(loraFixed(startedAt.duration(to: ContinuousClock().now).milliseconds / 1000, digits: 1))")
        all.append(contentsOf: fields)
        FileHandle.standardError.write(Data("\(prefix)] \(all.joined(separator: " "))\n".utf8))
    }

    /// 壁時計。系全体を記録する `scripts/probe-watch.sh` の `[SYS] t=HH:MM:SS` と
    /// 突き合わせるために要る。**プロセス内の計測だけでは測り方の癖に気づけない。**
    private static func wallClock() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

/// `MLXMemoryReading.logFields` と**同じキー名**に揃える（`[MEM]` / `[PROBE-MLX]` と並べて読むため）。
/// キー名の出所を増やさない。
private func loraMemoryFields(_ snapshot: MLX.Memory.Snapshot) -> [String] {
    [
        "active_mb=\(loraFixed(Double(snapshot.activeMemory) / 1_048_576))",
        "cache_mb=\(loraFixed(Double(snapshot.cacheMemory) / 1_048_576))",
        "total_mb=\(loraFixed(Double(snapshot.activeMemory + snapshot.cacheMemory) / 1_048_576))",
        "peak_mb=\(loraFixed(Double(snapshot.peakMemory) / 1_048_576))",
    ]
}

private func loraDeltaMB(_ now: Int, _ earlier: Int) -> Double {
    Double(now - earlier) / 1_048_576
}

/// **潰しは自前で書かない。** `ToolLogValue.sanitized` を使う。
///
/// あれが「stderr の1行に出してよい形」の判断を1か所に持っている
/// （Cc / Cf / Zl / Zp / Zs を落とし、`key=value` の区切りを壊さない）。
/// ここで別の潰しを書けば判断が2か所になり、片方だけ直る日が来る。
/// 64スカラーで切られるので、**全文が要る値は `key=value` に載せずに
/// `BEGIN` / `END` で挟んで別行に出すこと**（`[BREAKDOWN] RENDERED_*` と同じやり方）。
private func loraSafeValue(_ text: String) -> String {
    ToolLogValue.sanitized(text)
}

private func loraFileSize(_ url: URL) -> Int? {
    guard let attributes = try? FileManager.default
        .attributesOfItem(atPath: url.path(percentEncoded: false)) else { return nil }
    return (attributes[.size] as? NSNumber)?.intValue
}

/// 中央値。**平均ではなく中央値を外挿の基準にする** ── 他プロセスの割り込みや
/// 熱による1点の跳ねに、外挿全体を引きずられないため。
private func loraMedian(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count % 2 == 1 { return sorted[middle] }
    return (sorted[middle - 1] + sorted[middle]) / 2
}

/// 小数の整形。**欠測は `0` ではなく `-` にする**（`[STATS]` と同じ約束）。
/// 0 で埋めると「測ったら0だった」と区別が付かなくなる。
private func loraFixed(_ value: Double?, digits: Int = 2) -> String {
    value.map { String(format: "%.\(digits)f", $0) } ?? "-"
}

// MARK: - 環境変数

private func loraStringEnv(_ key: String, default fallback: String) -> String {
    let raw = ProcessInfo.processInfo.environment[key]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw, !raw.isEmpty else { return fallback }
    return raw
}

private func loraIntEnv(_ key: String, default fallback: Int) -> Int {
    Int(loraStringEnv(key, default: "")) ?? fallback
}

/// `"2,4,8,16"` を `[2, 4, 8, 16]` に割る。数として読めない要素は捨てる
/// （全部捨てたら既定へ戻す）。`SOPHIA_PROBE_GAP_S` と同じ約束。
private func loraIntList(_ key: String, default fallback: [Int]) -> [Int] {
    let parsed = loraStringEnv(key, default: "")
        .split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    return parsed.isEmpty ? fallback : parsed
}

/// `1` / `true` / `yes` を真、`0` / `false` / `no` を偽と読む。
/// **それ以外は既定に倒す。** 打ち間違いで条件が黙って変わるより、既定のほうがまだ読める。
private func loraBoolEnv(_ key: String, default fallback: Bool) -> Bool {
    switch loraStringEnv(key, default: "").lowercased() {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return fallback
    }
}
