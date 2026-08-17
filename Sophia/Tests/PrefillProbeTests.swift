import Foundation
import XCTest
@testable import Sophia

// =============================================================================
//  プリフィル崩れの切り分け ── 「どれだけ待つと、どれだけ落ちるか」を測る
// -----------------------------------------------------------------------------
//  ## このファイルは何を切り分けるためのものか
//
//  実測ログ（docs/BENCH_RESULTS.md 2026-08-17）で、連続2往復のうち
//  **プリフィルだけが9.2倍に崩れ、デコードは無傷**という現象が出た。
//
//  |              | 1往復目 | 2往復目 |
//  |--------------|--------:|--------:|
//  | 入力トークン  |     104 |     156 |
//  | プリフィル    | 0.84秒 / 123.26 tok/s | **11.65秒 / 13.39 tok/s** |
//  | デコード      | 19.46 tok/s | 19.21 tok/s（**無傷**） |
//
//  原因はほぼ確定している。**アイドル中に重みがスワップへ退避され、
//  次のプリフィルが読み戻しの代金を全額払っている。**
//  1時間38分アイドルした実プロセスの RSS は 20.1MB で、
//  書き込み可能領域の95%が `swapped_out` だった（同ドキュメント「ページアウト説の直接観測」）。
//
//  **残っているのは「どれだけ待つと、どれだけ落ちるか」＝退避の時定数だけである。**
//  このファイルはそれ専用の計測ハーネスであって、**合否を判定するテストではない。**
//  失敗するのは「計測そのものが取れなかったとき」だけにしてある（下の「なぜ劣化を assert しないか」）。
//
//  ## なぜ XCTest なのか（他に手段が無い）
//
//  素の `swift script` では `.metallib` が生成されず MLX 推論が動かない。
//  一方このテストターゲットは `TEST_HOST` が `Sophia.app` で、テストバンドル内に
//  `default.metallib` が実在する。**モデル重みもアプリと同じサンドボックス
//  コンテナにあるので再ダウンロードも要らない。**
//  タイムアウトも無効なので、900秒の待ちを入れても打ち切られない。
//
//  ## 起動ゲート ── 通常の `make app-test` では絶対に走らない
//
//  **`SOPHIA_PROBE=1` のときだけ実行する。** 4.6GB を読み込んで数分かかるので、
//  全80件・1秒未満の通常テストに混ざると開発が止まる。
//  ゲートは `setUpWithError()` に置いてあり（＝このクラスに後からテストメソッドを
//  足しても書き忘れようがない）、テストの先頭にも**意図的に重ねて**置いてある。
//
//  ## 環境変数
//
//  | 変数 | 既定 | 意味 |
//  |---|---|---|
//  | `SOPHIA_PROBE`             | （無し） | **`1` のときだけ実行**。それ以外はスキップ |
//  | `SOPHIA_PROBE_TURNS`       | 3   | 何往復するか |
//  | `SOPHIA_PROBE_GAP_S`       | 0   | 往復と往復の間に何秒待つか。**カンマ区切りで掃引できる**（下記） |
//  | `SOPHIA_PROBE_PROMPT`      | 固定の日本語文 | 送る内容 |
//  | `SOPHIA_PROBE_SAME_PROMPT` | 1   | `1`＝毎回同じ入力（**トークン数を固定して交絡を消す**）。`0`＝会話を積む |
//  | `SOPHIA_PROBE_LABEL`       | 空  | ログに付ける自由記述（空白は `_` に潰す） |
//
//  以下は上の表に無いが、**この実験を現実的な時間で回すために足したもの。**
//
//  | 変数 | 既定 | 足した理由 |
//  |---|---|---|
//  | `SOPHIA_PROBE_MODEL`         | `SophiaDefaults.modelID` | 0.6B に落として配管の動作確認だけ先に済ませられる |
//  | `SOPHIA_PROBE_MAX_TOKENS`    | 64  | 既定の1024だと1往復に約53秒かかる。**測りたいのはプリフィルで、デコードの長さは競う対象ではない** |
//  | `SOPHIA_PROBE_THINKING`      | 0   | ON にすると `applyingThinkingBudget()` が maxTokens を4096へ引き上げ、1往復が数分になる |
//  | `SOPHIA_PROBE_SEED`          | 42  | 固定すると出力が毎回同じになり、**出力トークン数まで定数になる**。デコード側の変動も消える |
//  | `SOPHIA_PROBE_IDLE_INTERVAL_S` | 15 | 待機中のサンプリング間隔 |
//  | `SOPHIA_PROBE_CLEAR_CACHE`   | 0（`SOPHIA_MEM_CLEAR_CACHE` があればそちら） | **各往復の後に `MLX.Memory.clearCache()` を呼ぶ。** 下記 |
//
//  > **`SOPHIA_PROBE_CLEAR_CACHE=1` を既定にしないこと。**
//  > キャッシュを捨てると次の生成が確保し直しの代金を払い、**`prefill_s` が伸びる。**
//  > 退避の時定数を測っている最中にこれを入れると、測定行為が現象を作ってしまう。
//  > 使うのは「MLX の `cache_mb` が本当にキャッシュか」を1回だけ確かめるときである。
//  >
//  > `make probe` は環境変数を固定の一覧で `.xctestrun` へ書き込むので、
//  > **この変数はそのままでは届かない。** 渡すなら Makefile の一覧へ足すか、
//  > 下の「ビルドを計測に混ぜたくないとき」の手順で `.xctestrun` を自分で作ること。
//
//  `SOPHIA_SYSTEM_PROMPT` はアプリと同じ意味で効く（`0` で自己認識を送らない）。
//  **アプリの `[STATS]` 行と条件を揃えるため、独自の切り替えは作っていない。**
//
//  ### `SOPHIA_PROBE_GAP_S` のカンマ区切り（時定数を1セッションで取るため）
//
//  `SOPHIA_PROBE_GAP_S=0,30,60,300,900` と書くと、2往復目の前に0秒、3往復目の前に30秒…
//  と待つ。**待ち時間ごとに別プロセスで測ると、ロードのタイミングも機体の状態も揃わない。**
//  1回のロードで掃引できることに意味がある（BENCH_RESULTS.md の E3）。
//  値が1つだけなら全往復に同じ待ちが入る（＝表どおりの素直な挙動）。
//  リストが往復数に足りなければ最後の値を使い回し、往復数はリスト長+1まで自動で伸びる。
//
//  ## 出力（すべて **stderr** へ1行1レコード）
//
//  | プレフィックス | 何の行か |
//  |---|---|
//  | `[PROBE-BEGIN]`   | 条件の記録。**この行が無いログは条件不明として捨てること** |
//  | `[PROBE-LOAD]`    | モデル読み込みの実測 |
//  | `[PROBE-IDLE]`    | 待機中のサンプル。**退避が進む様子そのもの** |
//  | `[PROBE]`         | **1行1往復。本丸。** 生成の実測 ＋ 往復開始時点の絶対値 ＋ プリフィル区間の差分 |
//  | `[PROBE-MEM]`     | 同じ往復の補足（終了時点の絶対値 ＋ 往復全体の差分） |
//  | `[PROBE-MLX]`     | **MLX 側の会計。1行1計測点。** 下記 |
//  | `[PROBE-VERDICT]` | 読み手向けの要約。判定の材料であって判定そのものではない |
//  | `[PROBE-END]`     | 終了 |
//
//  ### `[PROBE-MLX]` ── OS 側の会計では答えられない問いのための行
//
//  上の `[PROBE]` / `[PROBE-MEM]` / `[PROBE-IDLE]` が答えるのは
//  **「確保したものが物理RAMにあるか」**（＝ residency）である。
//  `[PROBE-MLX]` が答えるのは別の問いで、**「MLX が何をどれだけ確保しているか」**である。
//
//  この行が要る理由は、**モデルが 4.62GB なのに生成中のフットプリントが約9GB あり
//  （`IOAccelerator (graphics)` が 8,952MB）、余分な約4.4GB の正体が分かっていない**ため。
//  RSS は `IOAccelerator` を数えないので、**OS 側の会計だけでは原理的に答えが出ない。**
//
//  値は `MLXEngine.drainMemoryTrace()` から取り出したものをそのまま載せている
//  （キー名も `MLXMemoryReading.logFields` / `deltaFields(since:)` の丸写し ＝
//  **キー名の出所は1つ**。`ProcessMetrics` のときと同じ方針）。
//  段階（`stage=`）と意味は `MLXMemoryReading.Stage` を読むこと。
//
//  | キー | 意味 |
//  |---|---|
//  | `active_mb`  | 生きている `MLXArray` が握っている量 |
//  | `cache_mb`   | 解放済みだが MLX がプールに抱えている量。**`cacheLimit` は20MB** |
//  | `total_mb`   | `active + cache` ＝ MLX が確保した総量。**4.62GB と直接並べる値** |
//  | `peak_mb`    | `[PROBE]` 行の同名キーと同じ意味（MLX の `peakMemory`） |
//
//  **読み方（これがこの行の存在理由）:**
//
//  - `load_end` の `total_mb` が約4.6GB、その後どの段階でも大きく増えない
//    → **余分な約4.4GB は MLX のアロケーションではない。** MLX の外（Metal のドライバ側など）を見る
//  - `prefill_end` / `first_token` の `d_total_mb` が GB 単位で正
//    → **フォワードで確保している。** KVキャッシュか中間バッファ。`kvBits` の出番
//  - `cache_mb` が20MBを大きく超えている → **`cacheLimit` の前提が間違っている**
//  - `after_clear_cache` で `total_mb` が大きく減る → 減った分はキャッシュだった（同上）
//  - `after_clear_cache` で減らない → live なアロケーション。重みか KV
//
//  > **`[PROBE-MLX]` を residency の証拠に使わないこと。**
//  > MLX が数えているのはアロケータの帳簿であって、そのページが物理RAMにあるかを知らない。
//  > 4.62GB 全部がスワップへ落ちていても `active_mb` は1バイトも動かない。
//  > この取り違えは既に一度誤診を生んでいる（BENCH_RESULTS.md 2026-08-16 は後に撤回された）。
//  > **`rss_mb` と併読するものであって、代替ではない。**
//
//  ### メモリ側のキー名は `ProcessMetrics` が持っている
//
//  `rss_mb` / `footprint_mb` / `compressed_mb` / `resident_pct` / `pageins` と、
//  差分側の `d_rss_mb` / `d_footprint_mb` / `d_compressed_mb` / `d_pageins` / `d_pagein_mb` は
//  **すべて `ProcessMetrics.logFields` と `ProcessMetricsDelta.logFields` の出力をそのまま載せている。**
//  こちらで組み直さないのは、MB 換算と符号の付け方を2か所に持つと必ず食い違うからである
//  （あちらは `[STATS]` 行にも混ぜる前提で作られている ＝ **キー名の出所は1つ**）。
//  絶対値のキーと差分のキーは重ならないので、同じ行に並べても曖昧にならない。
//  ただし**絶対値を1行に2組は置けない**（`rss_mb` が衝突する）── `[PROBE-MEM]` を分けたのはそのため。
//
//  時刻キー `t=HH:MM:SS` と `rss_mb` は `scripts/probe-watch.sh` の `[SYS]` 行にも合わせてある。
//  **プロセス内の計測と系全体の計測を、同じキーで突き合わせられることが狙い。**
//
//  ## 判定基準（半年後に読む人へ）
//
//  1. **`prefill_s` が `gap_s` と単調増加し、`decode_s` が動かない** → 退避説と整合
//  2. **`[PROBE]` の `d_rss_mb` が大きく正**（プリフィル区間で常駐が跳ね上がる）
//     → 読み戻しの最も直接的な痕跡。**これが本命。**
//  3. **`[PROBE-IDLE]` の `d_rss_mb` が待つほど大きく負** → 退避が進む曲線そのもの。
//     この曲線の時定数が、このプローブが取りに行っている値である
//  4. `d_pageins` が大きい → 同上の傍証
//
//  > **`d_pageins` が動かなくても退避は否定されない。** 理由は2つある。
//  > - macOS のスワップは**まず圧縮**して compressor に載せる。そこからの伸長は
//  >   ディスクI/Oを伴わず、`pageins` に計上されないことがある（`compressed_mb` を併読すること）
//  > - `pageins` は**ページ数ではなく操作の回数**である（`ProcessMetrics.pageins` の但し書き）。
//  >   1回の操作が複数ページをまとめて読むので、回数は素直にスケールしない
//  >
//  > 逆に `d_rss_mb` も `d_pageins` も動かないのに `prefill_s` だけ伸びるなら、
//  > **退避説はこの条件では成り立っていない**（他プロセスとの争奪など別の線を見る）。
//
//  ## なぜ劣化を assert しないか
//
//  閾値を書いた瞬間、これは16GB機の機嫌に左右される flaky なゲートになる。
//  **測るための道具を、壊れやすい門番に格下げしない。**
//  落ちるのは「`.done` が来なかった」「`prefill_s` が nil だった」「`ProcessMetrics` が
//  取れなかった」＝**計測そのものが成立しなかったとき**だけである。
//
//  ## 実行例
//
//  正規の入口は `make probe`（Makefile）である。**まず別窓で系全体の記録を始めること。**
//
//  ```
//  # 別窓。プロセス内の計測と独立した経路を持たないと、測り方の癖を現象と取り違える
//  make probe-watch
//
//  # E1: 待ち0秒で5連続（初回コスト説の検証）
//  make probe PROBE_TURNS=5 PROBE_GAP_S=0 PROBE_LABEL=E1-back-to-back
//
//  # E3: 待ち時間の掃引（退避の時定数。**1回のロードで** 0/30/60/300/900 秒）
//  make probe PROBE_GAP_S=0,30,60,300,900 PROBE_LABEL=E3-sweep
//
//  # 読む
//  grep '^\[PROBE' logs/prefill-probe.log
//  ```
//
//  `make probe` が環境変数に付けている `TEST_RUNNER_` 接頭辞は、xcodebuild が
//  **テストホストのプロセスへ渡すときに剥がす**ためのもの。上の表に無い変数を足したいときは
//  同じ形で書く（例 `TEST_RUNNER_SOPHIA_PROBE_MAX_TOKENS=128`）。
//
//  **ビルドを計測に混ぜたくないとき**は `make probe` を使わず、
//  `build-for-testing` を1回だけ回してから `test-without-building` を条件ごとに叩く
//  （`app-stats` をビルドに依存させていないのと同じ理由）。
//
//  ```
//  xcodebuild -project Sophia/Sophia.xcodeproj -scheme Sophia \
//      -destination 'platform=macOS,arch=arm64' -derivedDataPath Sophia/DerivedData \
//      -skipPackagePluginValidation -skipMacroValidation build-for-testing
//
//  xcodebuild ... test-without-building \
//      -only-testing:SophiaTests/PrefillProbeTests \
//      TEST_RUNNER_SOPHIA_PROBE=1 TEST_RUNNER_SOPHIA_PROBE_GAP_S=900 \
//      2> logs/probe-900.log
//  ```
//
//  > **計測前に起動中の `Sophia` を落とすこと**（`pkill -x Sophia`）。
//  > 4.6GB を持つプロセスが2つ居ると、測っているのは退避の時定数ではなく単なるメモリ争奪になる。
//  > 同じ理由で Ollama も止めておくこと。
// =============================================================================

final class PrefillProbeTests: XCTestCase {

    // MARK: - 起動ゲート

    /// **ここが「通常の `make app-test` では絶対に走らない」の実体。**
    ///
    /// テストメソッド側ではなく `setUpWithError()` に置いたのは、
    /// このクラスに後からメソッドを足した人がゲートを書き忘れても、
    /// **構造的に走りようが無い**ようにするため。
    override func setUpWithError() throws {
        try super.setUpWithError()
        try Self.requireProbeEnabled()
        // 1往復失敗したまま残りを回しても、条件が崩れた後の数字が並ぶだけで読めない。
        continueAfterFailure = false
    }

    private static func requireProbeEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SOPHIA_PROBE"] == "1",
            "計測用のプローブです。`SOPHIA_PROBE=1` を付けたときだけ走ります"
                + "（4.6GB を読み込み数分かかるため、通常のテストからは外してあります）")
    }

    // MARK: - 本丸: 待ち時間とプリフィルの関係を測る

    /// N往復を1セッションで回し、**往復ごとにプリフィル区間の前後で `ProcessMetrics` を
    /// 取って差分を出す。**
    ///
    /// 責務はこれだけである。条件（往復数・待ち時間・入力）はすべて環境変数から来る。
    /// 判定はログを人間が読んで行う（このメソッドは判定しない）。
    func testPrefillAcrossIdleGaps() async throws {
        // setUpWithError と重複しているが**意図的**。
        // 「絶対に走らない」は二重に掛けておく価値がある。
        try Self.requireProbeEnabled()

        let config = ProbeConfiguration.fromEnvironment()
        let log = ProbeLog(label: config.label)

        // --- モデルの実体が無ければ測らずに降りる -----------------------------
        //
        // ここで 4.62GB を取りに行かせない。**取得そのものがディスクキャッシュと
        // メモリ圧を動かし、これから測ろうとしている対象を壊す。**
        // 先にアプリを普通に起動して落としておくこと。
        try XCTSkipUnless(
            MLXModelCatalog.isDownloaded(config.modelID),
            "\(config.modelID) がローカルに無い。"
                + "先にアプリを起動して取得してから測ること"
                + "（4.6GB の取得を計測セッションに混ぜると条件が壊れる）")

        // メモリ側が取れないなら、このプローブは存在意義の半分を失う。**先に落とす。**
        // 4.6GB を読み込んでから「実は測れませんでした」は数分の無駄になる。
        XCTAssertNotNil(
            ProcessMetrics.sample(),
            "`ProcessMetrics.sample()` が nil。OS 側のメモリ会計が読めないので、"
                + "プリフィル区間の差分は取れない")

        let engine = MLXEngine()

        // MLX 側の会計を切り替える。**既定では呼ばない**（理由は `ProbeConfiguration`）。
        await engine.setClearsCacheAfterGeneration(config.clearCache)

        log.write("[PROBE-BEGIN", [
            "engine=\(engine.identifier.rawValue)",
            "model=\(config.modelID)",
            "turns=\(config.turnCount)",
            "gaps_s=\(config.gapSeconds.map { "\($0)" }.joined(separator: ","))",
            "same_prompt=\(config.samePrompt ? 1 : 0)",
            "thinking=\(config.thinking ? 1 : 0)",
            "max_tokens=\(config.maxTokens)",
            "seed=\(config.seed.map { "\($0)" } ?? "-")",
            "system_prompt=\(SophiaDefaults.systemPromptEnabled ? 1 : 0)",
            "idle_interval_s=\(config.idleIntervalSeconds)",
            "prompt_chars=\(config.prompt.count)",
            // MLX 側の計測が生きているか。**`0` なら `[PROBE-MLX]` は1行も出ない。**
            // `SOPHIA_PROBE=1` が立っていれば `MLXEngine` 側が自動で記録を有効にするので、
            // ここが `0` になるのは配管が壊れているときだけである。
            "mlx_probe=\(MLXEngine.isMemoryProbeEnabled ? 1 : 0)",
            "clear_cache=\(config.clearCache ? 1 : 0)",
        ])

        // --- 読み込み ---------------------------------------------------------
        let loadBefore = ProcessMetrics.sample()
        let loadStartedAt = ContinuousClock().now
        for try await _ in engine.load(config.modelID) {}
        let loadSeconds = loadStartedAt.duration(to: ContinuousClock().now).milliseconds / 1000
        let loadAfter = ProcessMetrics.sample()

        log.write("[PROBE-LOAD", [
            "model=\(config.modelID)",
            "load_s=\(fixed(loadSeconds))",
            "at=load_end",
        ] + absoluteFields(loadAfter) + ["window=load"] + deltaFields(loadAfter, since: loadBefore))

        // --- MLX 側の会計を取り出す -------------------------------------------
        //
        // `[PROBE-LOAD]`（OS 側）と対になる行である。
        // **「重み 4.62GB がそのまま MLX のアロケーションとして現れるか」がここで分かる。**
        //
        // 取り出しは `drainMemoryTrace()` で、呼ぶたびに空になる。
        // 往復ごとに呼べば「その往復で増えたぶん」だけが並ぶ。
        // `seq` が飛んでいたら取りこぼしがある（上限256点を超えて捨てられた場合）。
        var lastMLXReading: MLXMemoryReading?
        var mlxByTurn: [[MLXMemoryReading]] = []

        let loadTrace = await engine.drainMemoryTrace()
        writeMLXReadings(
            loadTrace, scope: ["phase=load"], previous: &lastMLXReading, log: log)

        let loadedModel = await engine.loadedModel()
        XCTAssertNotNil(loadedModel, "モデルが載っていない。以降の計測に意味が無い")

        // --- 往復 -------------------------------------------------------------
        //
        // `history` はエンジンへ送る会話の蓄積。`SOPHIA_PROBE_SAME_PROMPT=1`（既定）では
        // **一度も伸びない。** 入力トークン数が全往復で一定になり、
        // 「トークン数が増えたから遅い」という交絡が消える。
        var history: [SophiaMessage] = []
        var records: [TurnRecord] = []

        for turn in 1...config.turnCount {
            // 2往復目以降は、送信の前に待つ。**待っている間も記録し続ける。**
            let gap = config.gap(beforeTurn: turn)
            if gap > 0 {
                try await watchWhileIdle(
                    seconds: gap,
                    interval: config.idleIntervalSeconds,
                    turnAhead: turn,
                    baseline: records.last?.after ?? loadAfter,
                    log: log)
            }

            let systemMessages: [SophiaMessage] = SophiaDefaults.systemPromptEnabled
                ? [.system(SophiaDefaults.systemPrompt)] : []
            let sent = systemMessages + history + [.user(config.prompt)]

            let record = try await runTurn(
                index: turn,
                gapSeconds: gap,
                engine: engine,
                messages: sent,
                options: config.chatOptions)
            records.append(record)

            log.write("[PROBE", record.headlineFields(of: config.turnCount))
            log.write("[PROBE-MEM", record.supplementFields(of: config.turnCount))

            // この往復ぶんの MLX 側の計測点。
            //
            // **`runTurn` が戻った時点で必ず出揃っている。** `MLXEngine.performChat` は
            // `continuation.finish()` のあと `defer` で `generate_end` を記録するが、
            // その区間に `await` が無いので actor は中断しない ── したがって
            // 次に actor へ入るこの `drainMemoryTrace()` は、必ずそのあとに走る。
            let turnTrace = await engine.drainMemoryTrace()
            mlxByTurn.append(turnTrace)
            writeMLXReadings(
                turnTrace,
                scope: ["phase=turn", "turn=\(turn)/\(config.turnCount)"],
                previous: &lastMLXReading,
                log: log)

            // **計測が取れなかったときだけ落とす。** 遅いことでは落とさない。
            let stats = try XCTUnwrap(
                record.stats,
                "\(turn)往復目で `.done` が届かなかった。この往復の計測値は失われている")
            XCTAssertNotNil(
                stats.prefillSeconds,
                "\(turn)往復目の prefill_s が nil。"
                    + "MLX が `promptTime` を返していない ＝ このプローブは何も測れていない")

            if !config.samePrompt {
                history.append(.user(config.prompt))
                history.append(.assistant(record.replyText))
            }
        }

        writeVerdict(records, mlxLoad: loadTrace, mlxByTurn: mlxByTurn, log: log)

        // 4.6GB を握ったまま次のテストへ渡さない。
        await engine.unload()

        // **`unload()` の直後こそ見どころ**なので、降りる前に最後の1点を吐く。
        // ここでもなお `active_mb` が大きいなら、MLX がまだ握っている ＝ 参照が残っている。
        //
        // `await` を引数の中に置かず先に受けているのは、同じ呼び出しに
        // `inout`（`previous:`）が混ざるのを避けるため。読みやすさの問題でもある。
        let unloadTrace = await engine.drainMemoryTrace()
        writeMLXReadings(
            unloadTrace, scope: ["phase=unload"], previous: &lastMLXReading, log: log)

        log.write("[PROBE-END", ["turns=\(records.count)"])
    }

    // MARK: - 1往復

    /// 1往復を駆動して、プリフィル区間の前後を挟んだサンプルごと返す。
    ///
    /// ## どこを「プリフィル区間」と見なしているか
    ///
    /// - 始点 ─ `chat` を呼ぶ直前
    /// - 終点 ─ **最初の `.thinking` / `.content` が届いた瞬間**
    ///
    /// MLX のプリフィルは `TokenIterator.init` の中、つまり `generate` 呼び出しの
    /// **内側で同期的に**走る（`MLXEngine.performChat` のコメント）。
    /// 最初の出力断片が出た時点でプリフィルは確実に終わっているので、
    /// この窓は「プリフィル＋最初の1デコードステップ」の上限になる。
    /// 1ステップぶんの上振れは、11.65秒対0.84秒という差の前では誤差である。
    ///
    /// `.prefill` の進捗が来た時点を終点に使わないのは、**最後の進捗が総数に達した保証が
    /// 無い**ため。上限として確実な側（最初の出力）を取る。
    ///
    /// **`prefill_s` そのものはこの壁時計から作らない。** MLX が報告した値
    /// （`GenerationStats.prefillSeconds` ← `GenerateCompletionInfo.promptTime`）を
    /// そのまま載せる。アプリ側で測り直すと既存の `[STATS]` 行と比較できなくなる。
    private func runTurn(
        index: Int,
        gapSeconds: Int,
        engine: MLXEngine,
        messages: [SophiaMessage],
        options: ChatOptions
    ) async throws -> TurnRecord {
        let before = ProcessMetrics.sample()
        var atFirstToken: ProcessMetrics?
        var sawFirstToken = false
        var stats: GenerationStats?
        var prefillEvents = 0
        var reply = ""

        for try await chunk in engine.chat(messages, options: options) {
            switch chunk {
            case .prefill:
                prefillEvents += 1

            case .thinking:
                // `atFirstToken` そのものを nil 判定に使えない
                // （`ProcessMetrics.sample()` は欠測時に nil を返すので、
                //  「まだ来ていない」と「取れなかった」が区別できなくなる）。
                if !sawFirstToken {
                    sawFirstToken = true
                    atFirstToken = ProcessMetrics.sample()
                }

            case .content(let text):
                if !sawFirstToken {
                    sawFirstToken = true
                    atFirstToken = ProcessMetrics.sample()
                }
                reply += text

            case .done(let received):
                stats = received

            @unknown default:
                // `Chunk` は将来ケースが増える（Chunk.swift の約束）。
                // 素の `default:` だと「到達しない」警告が出るので `@unknown` にしてある
                // （`ChatViewModel.apply(_:)` と同じ判断）。
                break
            }
        }

        return TurnRecord(
            index: index,
            gapSeconds: gapSeconds,
            stats: stats,
            before: before,
            atFirstToken: atFirstToken,
            after: ProcessMetrics.sample(),
            prefillEvents: prefillEvents,
            replyText: reply)
    }

    // MARK: - 待機

    /// 待っている間、一定間隔でサンプルを吐く。
    ///
    /// **退避が進む様子そのものを見たいので、待つだけにしない。**
    /// 「900秒待ったら遅かった」では、いつ落ちたのか分からない。
    /// `rss_mb` が時間とともに減っていく曲線が、退避の時定数そのものである。
    ///
    /// `d_*` は「直前の往復が終わった時点（＝重みが最も常駐しているはずの瞬間）」からの差。
    /// **`d_rss_mb` が負の方向へ伸びていくのが、このプローブが取りに来た曲線である。**
    private func watchWhileIdle(
        seconds: Int,
        interval: Int,
        turnAhead: Int,
        baseline: ProcessMetrics?,
        log: ProbeLog
    ) async throws {
        func emit(waited: Int) {
            let sample = ProcessMetrics.sample()
            log.write("[PROBE-IDLE", [
                "turn_ahead=\(turnAhead)",
                "waited_s=\(waited)",
                "remain_s=\(seconds - waited)",
            ] + absoluteFields(sample)
              + ["since=last_turn_end"]
              + deltaFields(sample, since: baseline))
        }

        // 曲線の原点。これが無いと最初の1点までの落ち幅が読めない。
        emit(waited: 0)

        var waited = 0
        while waited < seconds {
            let step = min(max(interval, 1), seconds - waited)
            try await Task.sleep(for: .seconds(step))
            waited += step
            emit(waited: waited)
        }
    }

    // MARK: - MLX 側の計測点

    /// `MLXEngine` から取り出した計測点を **1点1行**で吐く。
    ///
    /// ## なぜ `[PROBE]` 行へ混ぜないのか
    ///
    /// 1往復に複数の計測点（`generate_begin` / `prefill_end` / `first_token` /
    /// `generate_end`）があり、**1行には収まらない。**
    /// `ProcessMetrics` の絶対値を1行に2組置けなかったのと同じ事情である
    /// （`active_mb` が衝突する）。既存の `[PROBE]` 行には**一切触っていない。**
    ///
    /// ## `previous` を跨がせている理由
    ///
    /// `d_*` は「直前の計測点から」の差である。往復をまたいでも繋げておくと、
    /// **`generate_begin` の `d_total_mb` が「前の往復の終わりから待っている間に動いた量」**
    /// になる。ここが負に大きければ、MLX 自身が手放している（＝退避ではなく解放）と分かる。
    /// 往復ごとに基準を切ると、この1点だけが読めなくなる。
    private func writeMLXReadings(
        _ readings: [MLXMemoryReading],
        scope: [String],
        previous: inout MLXMemoryReading?,
        log: ProbeLog
    ) {
        guard !readings.isEmpty else {
            // **欠測は `-` で埋めない。** 0 で埋めると「測ったら0だった」と区別が付かなくなる
            // （`absoluteFields` の `mem=unavailable` と同じ約束）。
            log.write("[PROBE-MLX", scope + ["mlx=unavailable"])
            return
        }

        for reading in readings {
            var fields = scope + [
                "stage=\(reading.stage.rawValue)",
                "seq=\(reading.sequence)",
                reading.logFields,
            ]
            if let earlier = previous {
                fields.append("since=\(earlier.stage.rawValue)")
                fields.append(reading.deltaFields(since: earlier))
            }
            log.write("[PROBE-MLX", fields)
            previous = reading
        }
    }

    // MARK: - 読み手向けの要約

    /// **判定ではなく、判定の材料**を1行にまとめる。
    ///
    /// 閾値はここに書いた2つだけで、しかも assert していない。
    /// 「この1回の走行で見えたこと」しか言えないのが正しい ──
    /// 時定数は `SOPHIA_PROBE_GAP_S` を変えた複数の走行を**並べて**初めて出る。
    private func writeVerdict(
        _ records: [TurnRecord],
        mlxLoad: [MLXMemoryReading],
        mlxByTurn: [[MLXMemoryReading]],
        log: ProbeLog
    ) {
        guard let first = records.first else { return }

        // 1往復目は「初回に触る」側なので、退避の話からは外して比べる。
        let later = records.dropFirst()
        let prefills = records.compactMap { $0.stats?.prefillSeconds }
        let rssGrowth = later.compactMap { $0.prefillDelta?.residentSize }.max()
        let pageinMax = later.compactMap { $0.prefillDelta?.pageins }.max()

        // どちらも**目安であって較正値ではない。**
        //   - 200MB … 4.6GB の一部でも読み戻していれば軽く超える桁
        //   - 10,000 … `pageins` はページ数ではなく操作の回数なので、
        //              288Kページ相当が何回の操作になるかは決まらない。桁を見るための線
        let residentGrowthFloor: Int64 = 200 * 1_048_576
        let pageinFloor: Int64 = 10_000

        let judgment: String
        if records.count < 2 {
            judgment = "往復が1回しかないので比較できない"
        } else if let rssGrowth, rssGrowth >= residentGrowthFloor {
            judgment = "プリフィル区間で常駐が急増（読み戻しの痕跡あり・退避説と整合）"
        } else if let pageinMax, pageinMax >= pageinFloor {
            judgment = "ページインは増えたが常駐の増加は小さい（要精査）"
        } else if rssGrowth == nil {
            judgment = "メモリ側が欠測（判定不能）"
        } else {
            judgment = "痕跡なし（この待ち時間では退避が進んでいない可能性）"
        }

        log.write("[PROBE-VERDICT", [
            "turns=\(records.count)",
            "prefill_s_min=\(fixed(prefills.min()))",
            "prefill_s_max=\(fixed(prefills.max()))",
            "prefill_tps_first=\(fixed(first.stats?.prefillTokensPerSecond))",
            "prefill_tps_last=\(fixed(records.last?.stats?.prefillTokensPerSecond))",
            "d_rss_prefill_max_mb=\(fixed(rssGrowth.map { Double($0) / 1_048_576 }, digits: 1))",
            "d_pageins_prefill_max=\(pageinMax.map { "\($0)" } ?? "-")",
            "judgment=\(judgment)",
            // --- MLX 側（別の問いへの答え。判定文とは独立に読むこと）-----------
            //
            // **これが「余分な約4.4GB」に効く3つの数字である。**
            //   - `mlx_total_after_load_mb` が約4,600 → 重みはそのまま MLX の帳簿に出ている
            //   - `mlx_total_max_mb` もその近辺で頭打ち → **9GB のうち約4.4GB は MLX の外**
            //   - `d_mlx_total_prefill_max_mb` が GB 単位 → フォワードで確保している（KV か中間バッファ）
            //
            // 上の `judgment` には混ぜていない。あちらは退避（residency）の話で、
            // **こちらは「誰が確保したか」の話**である。1つの判定文に混ぜると必ず取り違える。
            "mlx_total_after_load_mb=\(fixed(Self.megabytes(mlxLoad.last(where: { $0.stage == .loadEnd })?.totalMemory), digits: 1))",
            "mlx_total_max_mb=\(fixed(Self.megabytes(mlxByTurn.joined().map(\.totalMemory).max()), digits: 1))",
            "d_mlx_total_prefill_max_mb=\(fixed(Self.megabytes(Self.maximumPrefillGrowth(mlxByTurn)), digits: 1))",
            "mlx_cache_max_mb=\(fixed(Self.megabytes(mlxByTurn.joined().map(\.cacheMemory).max()), digits: 1))",
            // 単発の走行で時定数は出ない。読み手が次に何をすべきかを行の中に置いておく。
            // **値に半角空白を入れないこと。** key=value の grep が壊れる。
            "next=GAP_Sを変えて複数回走らせ行を並べること",
        ])
    }

    /// バイト → MiB。**欠測は nil のまま通す**（`fixed` が `-` にする）。
    /// 0 で埋めると「測ったら0だった」と区別が付かなくなる。
    private static func megabytes(_ bytes: Int?) -> Double? {
        bytes.map { Double($0) / 1_048_576 }
    }

    /// 往復ごとの「`generate_begin` → `prefill_end` で MLX が増やした量」の最大値。
    ///
    /// **プリフィルのフォワードが何を確保しているか**に直接効く数字である。
    /// 両端が揃わない往復（`prefill_end` が届かなかった `.logits` 経路など）は
    /// **黙って 0 にせず捨てる。** 片端だけの差は差ではない。
    private static func maximumPrefillGrowth(_ mlxByTurn: [[MLXMemoryReading]]) -> Int? {
        mlxByTurn.compactMap { readings -> Int? in
            guard
                let begin = readings.first(where: { $0.stage == .generateBegin }),
                let end = readings.first(where: { $0.stage == .prefillEnd })
            else { return nil }
            return end.totalMemory - begin.totalMemory
        }.max()
    }
}

// MARK: - 計測条件

/// 環境変数から読む計測条件。**既定値の根拠はこの型のコメントに集める。**
private struct ProbeConfiguration {

    let modelID: String
    let turnCount: Int
    /// 往復と往復の間の待ち秒数。`SOPHIA_PROBE_GAP_S` のカンマ区切りをそのまま持つ。
    let gapSeconds: [Int]
    let prompt: String
    let samePrompt: Bool
    let label: String
    let maxTokens: Int
    let thinking: Bool
    let seed: UInt64?
    let idleIntervalSeconds: Int

    /// 各往復の後に `MLX.Memory.clearCache()` を呼ぶか。**既定は呼ばない。**
    ///
    /// 呼ぶと `cache_mb` が本当にキャッシュだったのかを切り分けられる
    /// （`cacheLimit` は20MBなので、理屈では大きく減りようが無い。
    ///  **それでも減るなら前提のほうが間違っている**）。
    ///
    /// **既定にしてはいけない。** 捨てたバッファは次の生成で確保し直しになり、
    /// その代金がプリフィル時間に乗る ── このプローブが測ろうとしている当のものが動く。
    /// 切り分けを1回だけ取りに行くとき以外は 0 のまま走らせること。
    let clearCache: Bool

    /// 既定のプロンプト。**内容に意味は無いが、長さには意味がある。**
    ///
    /// 実測ログの1往復目が入力104トークン（自己認識71トークン込み）だったので、
    /// 同じ桁に収まる長さにしてある。比較対象と入力長を揃えるため、
    /// **理由なく差し替えないこと**（差し替えるなら `SOPHIA_PROBE_LABEL` に残す）。
    static let defaultPrompt =
        "日本の四季について、春夏秋冬それぞれの特徴を一文ずつ、合計四文で説明してください。"

    static func fromEnvironment() -> ProbeConfiguration {
        let gaps = intList("SOPHIA_PROBE_GAP_S", default: [0])
        // リストで掃引するときは、往復数が足りないと後ろの条件が測れないまま終わる。
        // 黙って測り損ねるより、往復数のほうを伸ばす。
        let turns = max(intEnv("SOPHIA_PROBE_TURNS", default: 3), gaps.count + 1)

        return ProbeConfiguration(
            modelID: stringEnv("SOPHIA_PROBE_MODEL", default: SophiaDefaults.modelID),
            turnCount: max(turns, 1),
            gapSeconds: gaps,
            prompt: stringEnv("SOPHIA_PROBE_PROMPT", default: defaultPrompt),
            samePrompt: boolEnv("SOPHIA_PROBE_SAME_PROMPT", default: true),
            // 空白があると key=value の grep が壊れる。潰してから載せる。
            label: stringEnv("SOPHIA_PROBE_LABEL", default: "")
                .split(whereSeparator: \.isWhitespace).joined(separator: "_"),
            maxTokens: max(intEnv("SOPHIA_PROBE_MAX_TOKENS", default: 64), 1),
            thinking: boolEnv("SOPHIA_PROBE_THINKING", default: false),
            seed: UInt64(exactly: max(intEnv("SOPHIA_PROBE_SEED", default: 42), 0)),
            idleIntervalSeconds: max(intEnv("SOPHIA_PROBE_IDLE_INTERVAL_S", default: 15), 1),
            // アプリ側と同じ変数（`SOPHIA_MEM_CLEAR_CACHE`）を既定に敷いておく。
            // **プローブ専用の変数を先に見る**のは、アプリの計測条件を持ち込んだまま
            // プローブだけ切りたい場合があるため。どちらも無ければ無効。
            clearCache: boolEnv(
                "SOPHIA_PROBE_CLEAR_CACHE",
                default: boolEnv("SOPHIA_MEM_CLEAR_CACHE", default: false)))
    }

    /// `turn` 往復目の**直前**に入れる待ち秒数。1往復目の前は待たない。
    /// リストが足りなければ最後の値を使い回す。
    func gap(beforeTurn turn: Int) -> Int {
        guard turn > 1, !gapSeconds.isEmpty else { return 0 }
        return gapSeconds[min(turn - 2, gapSeconds.count - 1)]
    }

    /// エンジンへ渡す生成パラメータ。
    ///
    /// 温度・topP・topK は `SophiaDefaults` のまま（＝アプリと同じ条件）。
    /// **`seed` を固定しているのがここの肝で**、同じ入力・同じ種なら出力も同じになり、
    /// 出力トークン数まで定数になる。プリフィル以外の変動要因をもう一段消せる。
    var chatOptions: ChatOptions {
        ChatOptions(
            contextLength: SophiaDefaults.contextLength,
            maxTokens: maxTokens,
            thinking: thinking,
            seed: seed)
    }
}

// MARK: - 1往復の記録

private struct TurnRecord {
    let index: Int
    let gapSeconds: Int
    /// `.done` で届いた実測値。**中断していないのに nil なら計測が失われている。**
    let stats: GenerationStats?
    /// `chat` を呼ぶ直前。
    let before: ProcessMetrics?
    /// 最初の出力断片が届いた瞬間 ＝ プリフィル区間の終わり。
    let atFirstToken: ProcessMetrics?
    /// `.done` まで含めた往復の終わり。
    let after: ProcessMetrics?
    /// `.prefill` が何回来たか。1回しか来ないならチャンク分割が効いていない。
    let prefillEvents: Int
    let replyText: String

    /// **プリフィル区間の差分。本丸。** `d_rss_mb` が大きく正なら読み戻している。
    var prefillDelta: ProcessMetricsDelta? {
        guard let atFirstToken, let before else { return nil }
        return atFirstToken.delta(since: before)
    }

    /// 往復全体の差分。プリフィル区間との差が、デコード中に起きたぶんになる。
    var turnDelta: ProcessMetricsDelta? {
        guard let after, let before else { return nil }
        return after.delta(since: before)
    }

    /// `[PROBE]` 行。**1行1往復。** 生成の実測値と、往復開始時点の絶対値と、
    /// プリフィル区間の差分を1本に並べる。
    func headlineFields(of totalTurns: Int) -> [String] {
        let s = stats
        let generation = [
            "turn=\(index)/\(totalTurns)",
            "gap_s=\(gapSeconds)",
            "model=\(s?.modelID ?? "-")",
            "thinking=\(s?.thinkingEnabled.map { "\($0)" } ?? "-")",
            "stop=\(s?.stopReason.rawValue ?? "-")",
            "in=\(s.map { "\($0.inputTokens)" } ?? "-")",
            "out=\(s.map { "\($0.outputTokens)" } ?? "-")",
            "ttft_s=\(fixed(s.map { $0.ttftMs / 1000 }))",
            "ttfr_s=\(fixed(s?.ttfrMs.map { $0 / 1000 }))",
            // **MLX が報告した値をそのまま載せる。** 壁時計で測り直さない。
            "prefill_s=\(fixed(s?.prefillSeconds))",
            "prefill_tps=\(fixed(s?.prefillTokensPerSecond))",
            "decode_s=\(fixed(s?.decodeSeconds))",
            "decode_tps=\(fixed(s.map { $0.tokensPerSecond }))",
            "total_s=\(fixed(s?.totalMs.map { $0 / 1000 }))",
            // MLX の会計（アロケーション量）。**residency は映さない**ので、
            // 下の rss_mb / d_rss_mb と**併読するもの**であって代替ではない。
            "peak_mb=\(fixed(s?.peakMemoryBytes.map { Double($0) / 1_048_576 }))",
            "prefill_events=\(prefillEvents)",
            "reply_chars=\(replyText.count)",
        ]
        return generation
            + ["at=turn_start"] + absoluteFields(before)
            + ["window=prefill"] + deltaFields(prefillDelta)
    }

    /// `[PROBE-MEM]` 行。終了時点の絶対値と、往復全体の差分。
    ///
    /// `[PROBE]` と分けたのは、**絶対値のキー（`rss_mb` 等）を1行に2組置けない**ため。
    /// 往復全体とプリフィル区間の差が、デコード中に動いたぶんになる。
    func supplementFields(of totalTurns: Int) -> [String] {
        ["turn=\(index)/\(totalTurns)", "at=turn_end"]
            + absoluteFields(after)
            + ["window=turn"] + deltaFields(turnDelta)
    }
}

// MARK: - メモリ指標の載せ方

/// 絶対値の `key=value` 列。**キー名は `ProcessMetrics.logFields` の丸写しである。**
///
/// 欠測は `-` で埋めず `mem=unavailable` にする。
/// `ProcessMetrics.sample()` が nil を返すのは「取れなかった」であって「0だった」ではない
/// ── 0 で埋めると、いま探している**フットプリントの崩壊と見分けが付かない偽陽性**になる
/// （`ProcessMetrics.sample()` の但し書き）。
private func absoluteFields(_ sample: ProcessMetrics?) -> [String] {
    guard let sample else { return ["mem=unavailable"] }
    return [sample.logFields]
}

/// 差分の `key=value` 列。**キー名は `ProcessMetricsDelta.logFields` の丸写しである。**
private func deltaFields(_ delta: ProcessMetricsDelta?) -> [String] {
    guard let delta else { return ["mem_delta=unavailable"] }
    return [delta.logFields]
}

/// 2点から差分を取って載せる。片側でも欠測していれば差は取れない。
private func deltaFields(_ now: ProcessMetrics?, since earlier: ProcessMetrics?) -> [String] {
    guard let now, let earlier else { return ["mem_delta=unavailable"] }
    return deltaFields(now.delta(since: earlier))
}

// MARK: - ログ

/// stderr へ1行1レコードで吐く。
///
/// **`print` を使わない。** アプリの `[STATS]` 行と同じ経路（生の `write(2)`）に
/// 揃えてあり、`2> logs/probe.log` でそのまま拾える。
/// XCTest の標準出力にはテストランナーの雑音が混ざるので、機械可読な行は stderr に置く。
private struct ProbeLog {
    let label: String
    let startedAt: ContinuousClock.Instant = ContinuousClock().now

    init(label: String) {
        self.label = label
    }

    /// `prefix` は閉じ括弧なしで渡す（`"[PROBE"` など）。ここで `]` を足す。
    func write(_ prefix: String, _ fields: [String]) {
        var all: [String] = []
        if !label.isEmpty { all.append("label=\(label)") }
        all.append("t=\(Self.wallClock())")
        all.append("elapsed_s=\(fixed(startedAt.duration(to: ContinuousClock().now).milliseconds / 1000, digits: 1))")
        all.append(contentsOf: fields)
        FileHandle.standardError.write(Data("\(prefix)] \(all.joined(separator: " "))\n".utf8))
    }

    /// 壁時計。系全体を記録する `scripts/probe-watch.sh` の `[SYS] t=HH:MM:SS` と
    /// 突き合わせるために要る（プロセス内の計測だけでは測り方の癖に気づけない）。
    ///
    /// `DateFormatter` を `static let` に持たないのは、`Sendable` でないため
    /// Swift 6 の strict concurrency で弾かれるから。呼ぶのは1分に数回なので毎回作る。
    private static func wallClock() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

/// 小数の整形。**欠測は `0` ではなく `-` にする**（`[STATS]` と同じ約束）。
/// 0 で埋めると「測ったら0だった」と区別が付かなくなる。
private func fixed(_ value: Double?, digits: Int = 2) -> String {
    value.map { String(format: "%.\(digits)f", $0) } ?? "-"
}

// MARK: - 環境変数

private func stringEnv(_ key: String, default fallback: String) -> String {
    let raw = ProcessInfo.processInfo.environment[key]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw, !raw.isEmpty else { return fallback }
    return raw
}

private func intEnv(_ key: String, default fallback: Int) -> Int {
    Int(stringEnv(key, default: "")) ?? fallback
}

/// `"0,30,60,300,900"` を `[0, 30, 60, 300, 900]` に割る。
/// 数として読めない要素は捨てる（全部捨てたら既定へ戻す）。
private func intList(_ key: String, default fallback: [Int]) -> [Int] {
    let parsed = stringEnv(key, default: "")
        .split(separator: ",")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        .map { max($0, 0) }
    return parsed.isEmpty ? fallback : parsed
}

/// `1` / `true` / `yes` を真、`0` / `false` / `no` を偽と読む。
/// **それ以外は既定に倒す。** 打ち間違いで条件が黙って変わるより、既定のほうがまだ読める。
private func boolEnv(_ key: String, default fallback: Bool) -> Bool {
    switch stringEnv(key, default: "").lowercased() {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return fallback
    }
}
