import Darwin
import Foundation

/// **OS 側のメモリ会計**を1点サンプルしたもの。ページング実績を測るための一次資料。
///
/// ## なぜ `MLX.Memory` ではなく OS の会計を読むのか — **ここを読まずに書き換えないこと**
///
/// `MLX.Memory.snapshot()` / `MLX.Memory.peakMemory` が数えているのは
/// **アロケーション量**であって、**そのページが物理RAMにあるかスワップにあるかを一切知らない。**
/// 4.6GB の重み全部がスワップへ落ちていても、MLX の値は1バイトも動かない。
///
/// この違いは机上の話ではなく、実際に一度誤診を生んでいる
/// （[BENCH_RESULTS.md](../../../docs/BENCH_RESULTS.md) 2026-08-16 の節は
/// 「ピークメモリが+40MBしか動いていないのでメモリ不足では説明がつかない」と書き、
/// **後に撤回した**）。`peak_mb` が動かないことは
/// **KVの膨張は否定できるが、ページアウトは否定できない。**
///
/// 2026-08-17 10:24 に直接観測で確定した現象はこうである
/// ── 1時間38分アイドルした実プロセスで、
///
/// | 指標 | 値 |
/// |---|--:|
/// | `phys_footprint`（圧縮・スワップを算入する） | 4,506 MB |
/// | **RSS（物理RAMにある量のみ）** | **20.1 MB** |
/// | `vmmap` 書き込み可能領域のうち `swapped_out` | 4.4 GB（**95%**） |
///
/// **重みはアイドルしているだけで95%がスワップへ落ち、次のプリフィルが読み戻しの代金を払う。**
/// residency を測れるのは OS 側の会計だけである。
///
/// > **`MLX.Memory.snapshot()` へ置き換えないこと。** 置き換えた瞬間、この型の測定は無意味になる。
/// > MLX 側の値が要るなら `GenerationStats.peakMemoryBytes` が既に持っている。**併用するもので、
/// > 代替ではない。**
///
/// ## `residentSize` と `physFootprint` の違い — **この2つの差こそが測りたいもの**
///
/// - `residentSize` は **いま物理RAMに載っているバイト数**。退避されれば減る。**これが本命の指標。**
/// - `physFootprint` は OS がプロセスに**課金**しているバイト数で、
///   **圧縮された分・スワップへ出た分を算入したまま**である。退避されても**ほとんど減らない。**
///
/// したがって **`physFootprint` が高いまま `residentSize` だけが落ちている状態＝退避が進んだ状態**
/// であり、上表の 4,506MB / 20.1MB はまさにそれである。
/// 片方だけを見ても何も分からない。**必ず対で読むこと。**
///
/// ## 使い方は「差分」である
///
/// `pageins` は**プロセス開始からの累積**なので、絶対値には意味がない。
/// プリフィルの直前・直後で `sample()` し、`delta(since:)` を取る。
/// 1往復で白黒がつく（BENCH_RESULTS.md「手順3」）。
///
/// ## 権限
///
/// `task_info(mach_task_self_, ...)` は**自プロセス限定・sudo 不要**である。
/// 他プロセスを覗くには task port が要り、そちらは署名と権限の話になる。**ここでは踏み込まない。**
/// また `footprint(1)` / `vmmap(1)` / Instruments と違い**外部プロセスを起動しない** ──
/// この機体では観測行為自体が対象を壊すため、これは要件である
/// （BENCH_RESULTS.md「Instruments は使わないこと」）。
struct ProcessMetrics: Sendable, Equatable {

    // MARK: - 生の値（すべてサンプル時点の絶対値）

    /// 累積ページイン回数（`TASK_EVENTS_INFO.pageins`）。**差分を取って使う。**
    ///
    /// カーネルは「実際に発生したページイン」を数える。**ページ数ではなく操作の回数**であり、
    /// 1回のページインが複数ページをまとめて読むことがある。
    /// したがって `pageins × pageSize` は**上限ではなく下限側の目安**にしかならない
    /// （`approximatePageinBytes` の但し書きを読むこと）。
    var pageins: UInt64

    /// 物理フットプリント（`TASK_VM_INFO.phys_footprint`）バイト。**圧縮・退避分を含む。**
    ///
    /// `footprint -p <pid>` が出す値と同じ会計。**退避されても落ちない**のが要点で、
    /// だからこそ `residentSize` との差が意味を持つ。
    var physFootprint: UInt64

    /// 圧縮されているバイト数（`TASK_VM_INFO.compressed`）。
    ///
    /// macOS のスワップは**まず圧縮**して compressor に載せ、それでも足りなければディスクへ出す。
    /// つまりこの値は**退避の第一段階**を映す。観測時の系全体では
    /// compressor が 406,004ページ ≒ 6.35GB を占有していた。
    var compressed: UInt64

    /// 常駐サイズ（`TASK_VM_INFO.resident_size`）バイト。**これが本命の指標。**
    ///
    /// `ps` の RSS と同じ量である。実測20.1MB を叩き出したのはこの値。
    ///
    /// > **解放してもすぐには下がらない。** 512MB を確保・接触してから解放しても
    /// > RSS が1バイトも戻らないことを実測で確認している（アロケータが free list に抱えたまま
    /// > OS へ返さないため）。**この値が下がるのはアロケータが解放したときではなく、
    /// > OS が回収・退避したとき**である。つまり「MLX が確保をやめたか」ではなく
    /// > 「OS がページを取り上げたか」を映す ── それがまさに測りたいものである。
    var residentSize: UInt64

    /// このサンプル時点のページサイズ（バイト）。**この機体では 16,384。**
    ///
    /// **4096 を決め打ちしないこと。** Apple Silicon のカーネルページは16KBで、
    /// 4KB で割ると「4.6GB ÷ 4KB ≈ 1.15Mページ」と、実際の288Kページに対して**4倍ずれる。**
    /// 判定基準の桁がそのまま狂う（BENCH_RESULTS.md「手順2」は両方の桁を併記している）。
    ///
    /// 出所は `TASK_VM_INFO.page_size` である。理由は `sample()` の実装コメントを読むこと。
    var pageSize: UInt64

    init(
        pageins: UInt64,
        physFootprint: UInt64,
        compressed: UInt64,
        residentSize: UInt64,
        pageSize: UInt64
    ) {
        self.pageins = pageins
        self.physFootprint = physFootprint
        self.compressed = compressed
        self.residentSize = residentSize
        self.pageSize = pageSize
    }

    // MARK: - 取得

    /// いまのプロセスの値を1点取る。取れなければ nil。
    ///
    /// ## 呼んでよい場所
    ///
    /// `task_info` は自タスクへの MIG 呼び出しで、実測でマイクロ秒台・確保も伴わない。
    /// **プリフィルの直前・直後に挟んでも計測窓を汚さない。**
    /// ただしループの内側で毎トークン呼ぶような使い方は想定していない。
    ///
    /// ## nil を返すとき
    ///
    /// `task_info` が失敗したとき、または `phys_footprint` が埋まらなかったとき。
    /// **「取れなかった」を 0 で埋めて返さない**のが要点である ──
    /// `physFootprint` が 0 に見える状態は、**まさにいま探している「フットプリントの崩壊」と
    /// 見分けがつかない偽陽性**になる。欠測は欠測として nil で返す。
    static func sample() -> ProcessMetrics? {
        guard let vm = readTaskVMInfo(), let pageins = readPageins() else { return nil }

        return ProcessMetrics(
            pageins: pageins,
            physFootprint: vm.phys_footprint,
            compressed: vm.compressed,
            residentSize: vm.resident_size,
            // ページサイズは **同じスナップショットの中から**取る。
            // グローバルの `vm_kernel_page_size` でも同じ値になるが、こちらには2つ利点がある:
            //   1. `vm_page_size`（末尾に kernel が付かない方）と取り違える事故が起きない。
            //      Rosetta 下では `vm_page_size` は 4096、`vm_kernel_page_size` は 16384 と
            //      **食い違う。** 取り違えると換算が4倍ずれる。
            //   2. C の可変グローバル変数を読まずに済む。`mach_task_self_` と違い
            //      `vm_kernel_page_size` は `__swift_nonisolated_unsafe` が付いておらず、
            //      strict concurrency 下で扱いが面倒になる。
            // 0 が返ることは無いはずだが、来たら換算側で弾く（`approximatePageinBytes`）。
            pageSize: UInt64(UInt32(bitPattern: vm.page_size))
        )
    }

    // MARK: - 差分

    /// `since` から現在までの動き。**この型の主用途。**
    ///
    /// 戻り値が `ProcessMetrics` ではなく専用の型なのには理由がある。
    /// **サイズ系の差分は平気で負になる**（アイドル中に `residentSize` が 4.4GB 減るのが、
    /// まさに観測したい事象である）。`UInt64` のまま引くと Swift は**オーバーフローで停止する**ので、
    /// 差分は符号付きで持つ。
    func delta(since earlier: ProcessMetrics) -> ProcessMetricsDelta {
        ProcessMetricsDelta(
            pageins: Self.difference(self.pageins, earlier.pageins),
            physFootprint: Self.difference(self.physFootprint, earlier.physFootprint),
            compressed: Self.difference(self.compressed, earlier.compressed),
            residentSize: Self.difference(self.residentSize, earlier.residentSize),
            pageSize: pageSize
        )
    }

    /// `UInt64` 同士の引き算を、オーバーフローせずに `Int64` で返す。
    ///
    /// 素直に `Int64(a) - Int64(b)` と書くと、片方が `Int64.max` を超えていたときに
    /// 変換で停止する。`subtractingReportingOverflow` を通せば、
    /// **2の補数のビット列がそのまま正しい符号付き差分になる**（差が `Int64` に収まる限り）。
    private static func difference(_ now: UInt64, _ before: UInt64) -> Int64 {
        Int64(bitPattern: now.subtractingReportingOverflow(before).partialValue)
    }

    // MARK: - 導出値

    /// 課金されている量のうち、**実際に物理RAMに載っている割合**。
    ///
    /// **この1つの数字が見出しである。** 実測の 20.1MB / 4,506MB は **0.0045（0.45%）**。
    /// 0 に近いほど退避済み。`physFootprint` が 0 のときは nil。
    ///
    /// > **⚠️ 1.0 を超えることがある。割合とあるが 0〜1 に収まらない。**
    /// > 実測（重みを載せていない小さなプロセス）で **394%** や **101%** を確認している。
    /// > 2つの会計の範囲が違うためである ──
    /// > - RSS は**クリーンなファイル由来のページ（ライブラリの実行部分など）も数える**が、
    /// >   `phys_footprint` はそれを**プロセスに課金しない**ので分母から抜けている。
    /// > - 逆に `phys_footprint` は**圧縮・退避されたページを課金し続ける**ので、
    /// >   分子から抜けたぶんが分母には残る。
    /// >
    /// > **この値が意味を持つのは、フットプリントが重みで支配されている領域だけ**である
    /// > （4.6GB を載せた状態なら、ライブラリのクリーンページは誤差に沈む）。
    /// > **モデル未ロードの値を「常駐率」として読まないこと。**
    var residencyRatio: Double? {
        guard physFootprint > 0 else { return nil }
        return Double(residentSize) / Double(physFootprint)
    }

    /// 課金されているのに物理RAMに無いバイト数。**符号付きである（負になりうる）。**
    ///
    /// > **これを「スワップに出た量」と言い切らないこと。**
    /// > `phys_footprint` と RSS は**別の会計**であり、この引き算は圧縮分・退避分・
    /// > 会計方式の差をまとめて含む。`residencyRatio` の但し書きのとおり範囲が食い違うので、
    /// > **重みを載せていない状態では平気で負になる**（実測で −4.2MB を確認した）。
    /// > 実際 `vmmap` の `resident` 列も `swapped_out` と足すと100%を超え、
    /// > **この列が何を指すのか未だ説明できていない**（BENCH_RESULTS.md 2026-08-17 の但し書き）。
    /// > **説明できないものを説明できたことにしない**のがこのリポジトリの規範なので、
    /// > 名前も「非常駐」までに留めてある。傾向を見る値であって、証拠として使う値ではない。
    var nonResidentBytes: Int64 {
        Self.difference(physFootprint, residentSize)
    }
}

// MARK: - 差分

/// 2点間の動き。`ProcessMetrics.delta(since:)` が作る。
///
/// **サイズ系は符号付きである。** 負の値は「減った」＝退避が進んだことを意味し、
/// それを潰さずに見せるのがこの型の存在理由である。
struct ProcessMetricsDelta: Sendable, Equatable {

    /// 区間中に発生したページイン回数。**負にはならない**（累積カウンタのため）。
    ///
    /// > **判定基準**（BENCH_RESULTS.md「手順2」）: 4.6GB ÷ 16KB ≈ **288Kページ**。
    /// > プリフィル区間でこの桁が乗るならページアウト説は**確定**、
    /// > ほとんど増えないのに11秒かかるなら**反証**である。
    var pageins: Int64

    /// `phys_footprint` の増減（バイト）。
    ///
    /// **アイドルを挟んでもここはあまり動かない**のが正常。ここが動くのは
    /// 確保／解放が起きたときであって、退避ではない。
    var physFootprint: Int64

    /// 圧縮バイト数の増減。**アイドル中に増え、読み戻しで減る**のが退避の署名。
    var compressed: Int64

    /// 常駐バイト数の増減。**この型の主役。**
    ///
    /// アイドル区間で**大きく負**、その直後のプリフィル区間で**大きく正**になれば、
    /// 「落ちて、読み戻した」が1往復で見える。
    var residentSize: Int64

    /// 換算に使うページサイズ（バイト）。後方のサンプルの値を引き継ぐ。
    var pageSize: UInt64

    /// ページイン回数をバイトに換算した**目安**。
    ///
    /// > **下限側の目安でしかない。** `pageins` は「ページイン**操作**の回数」であって
    /// > ページ数ではなく、1回の操作が複数ページをクラスタで読むことがある。
    /// > **実際に読み戻したバイト数はこれ以上になりうる。**
    /// > 桁を確かめるために使う値であって、精密な量として扱わないこと。
    var approximatePageinBytes: Int64? {
        guard pageSize > 0, pageins >= 0 else { return nil }
        let (product, overflow) = pageins.multipliedReportingOverflow(by: Int64(pageSize))
        return overflow ? nil : product
    }
}

// MARK: - ログ

extension ProcessMetrics {
    /// `ChatViewModel.logMeasurement` の `[STATS]` 行に混ぜられる `key=value` 列。
    ///
    /// 単位を MB に揃えてあるのは、BENCH_RESULTS.md の表がすべて MB 表記だからである
    /// （4,506MB / 20.1MB）。**桁を揃えないと突き合わせのたびに換算ミスが出る。**
    var logFields: String {
        [
            "rss_mb=\(Self.megabytes(Int64(bitPattern: residentSize)))",
            "footprint_mb=\(Self.megabytes(Int64(bitPattern: physFootprint)))",
            "compressed_mb=\(Self.megabytes(Int64(bitPattern: compressed)))",
            "resident_pct=\(residencyRatio.map { String(format: "%.2f", $0 * 100) } ?? "-")",
            "pageins=\(pageins)",
        ].joined(separator: " ")
    }

    /// MiB 表記。1_048_576 で割る（BENCH_RESULTS.md と `logMeasurement` の `peak_mb` に揃える）。
    fileprivate static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

extension ProcessMetricsDelta {
    /// 差分の1行。**符号を必ず付ける** ── `-4400.0` の先頭の `-` が結論そのものだからである。
    var logFields: String {
        func signed(_ bytes: Int64) -> String {
            String(format: "%+.1f", Double(bytes) / 1_048_576)
        }
        return [
            "d_rss_mb=\(signed(residentSize))",
            "d_footprint_mb=\(signed(physFootprint))",
            "d_compressed_mb=\(signed(compressed))",
            "d_pageins=\(pageins)",
            "d_pagein_mb=\(approximatePageinBytes.map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "-")",
        ].joined(separator: " ")
    }
}

// MARK: - Mach の呼び出し

/// `TASK_VM_INFO` を読む。
///
/// ## count の扱い — ここが唯一やっかいな箇所
///
/// `task_info` の第4引数 `count` は **in-out** である。
/// 呼ぶ側が「この語数まで受け取れる」と申告し、**カーネルが「実際に埋めた語数」を書き戻す。**
/// 単位は `natural_t`（4バイト）語であって、バイトでもフィールド数でもない。
///
/// `task_vm_info` は rev0 → rev7 と**継ぎ足しで拡張されてきた**構造体で、
/// `phys_footprint` は **rev1 で足された**（rev0 には無い）。
/// 古いカーネルは rev0 までしか埋めずに返し、**残りは呼び側のバッファの中身のまま**になる。
/// つまり **`count` を見ずに `phys_footprint` を読むと、未初期化の値を「実測」として掴む。**
///
/// C には `TASK_VM_INFO_REV1_COUNT` という専用マクロが用意されている。
/// **ところがこれは `sizeof` を含むマクロなので Swift へは import されない**
/// （`TASK_VM_INFO_COUNT` も同様）。そこで同じ値を Swift 側で組み立てる ── それが
/// `taskVMInfoRev1Count` である。
///
/// なお **macOS 14 以上（このアプリの下限）で rev0 しか埋まらないカーネルは存在しない。**
/// `phys_footprint` は macOS 10.11 からある。この判定は事実上到達しない安全弁であり、
/// **通らなかったら 0 を返すのではなく nil を返す**（`sample()` の但し書きを読むこと）。
private func readTaskVMInfo() -> task_vm_info_data_t? {
    var info = task_vm_info_data_t()
    var count = taskVMInfoCount

    let result = withUnsafeMutablePointer(to: &info) { pointer in
        // `task_info_t` は `UnsafeMutablePointer<integer_t>` である。
        // `natural_t` と `integer_t` はどちらも4バイトなので、`count` がそのまま capacity になる。
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }

    guard result == KERN_SUCCESS else { return nil }
    // カーネルが書き戻した語数が `phys_footprint` の終端に届いているか。
    guard count >= taskVMInfoRev1Count else { return nil }
    return info
}

/// `TASK_EVENTS_INFO.pageins` を読む。
///
/// こちらの構造体は拡張されたことがないので、count の版判定は要らない。
private func readPageins() -> UInt64? {
    var info = task_events_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_events_info_data_t>.size / MemoryLayout<natural_t>.size
    )

    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), rebound, &count)
        }
    }

    guard result == KERN_SUCCESS else { return nil }

    // `pageins` は `integer_t`（符号付き32ビット）だが、実体は**単調増加のカウンタ**である。
    // 21億回を超えると符号ビットへ食い込んで負に見えるので、
    // `Int64(_:)` で素直に広げず、**ビット列を符号なしとして読み直す。**
    // （4.6GB の読み戻し1回が約288Kページなので7000回強の全ロードで到達しうる。
    //   実際に踏むかは怪しいが、正しく書く方が安い。）
    return UInt64(UInt32(bitPattern: info.pageins))
}

/// `TASK_VM_INFO` を要求するときの語数（C の `TASK_VM_INFO_COUNT` 相当）。
///
/// `task_vm_info` は 64ビット整数で終わるため `size` は4の倍数で、`stride` と一致する。
/// C の `sizeof` に対応するのは `size` の方なのでそちらを使う。
private let taskVMInfoCount = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
)

/// `phys_footprint` まで埋まったと言える最小の語数（C の `TASK_VM_INFO_REV1_COUNT` 相当）。
///
/// C 側は「rev7 から順に引き算する」形で定義しているが、あちらは構造体の末尾が伸びるたびに
/// 全段を書き換える前提の定義である。**こちらは `phys_footprint` の位置を直接引く。**
/// 構造体に rev8 が足されても、この式は勝手に正しいままである。
///
/// `offset(of:)` が nil を返した場合（stored property として引けなかった場合）は
/// `.max` を返し、**判定を必ず落とす。** 安全側とはそういう意味である。
private let taskVMInfoRev1Count: mach_msg_type_number_t = {
    guard let offset = MemoryLayout<task_vm_info_data_t>
        .offset(of: \task_vm_info_data_t.phys_footprint) else { return .max }
    let end = offset + MemoryLayout<mach_vm_size_t>.size
    return mach_msg_type_number_t(end / MemoryLayout<natural_t>.size)
}()
