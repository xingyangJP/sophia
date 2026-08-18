import Foundation

/// モデルが要求した「窓」（DESIGN.md 第16.4節の `read_file` の `offset` / `limit`）。
///
/// **`read_file` は全文を返さない。** 窓で返し、モデルは続きを要求できる。
/// これはケチではなく、返せないからである ─ 8,192トークンの上限に対して、
/// 数百行のファイルは単独で壁を作る（16.3節 / 発見19）。
struct ReadWindow: Sendable, Equatable, Codable {

    /// 何行目から読むか（**1始まり**。モデルにも人間にも 1始まりのほうが伝わる）。
    var offset: Int

    /// 何行ぶん読むか。nil なら「トークン上限に収まるだけ」。
    ///
    /// **0 以下は「窓の指定なし」として扱う。** 素直に 0行 と解釈することもできるが、
    /// **何も返さない戻り値は利用者の役に立たない。** モデルが 0 を渡してくるのは
    /// 指定を省いたつもりのときで、上限に任せるのが意図に近い。
    var limit: Int?

    init(offset: Int = 1, limit: Int? = nil) {
        self.offset = offset
        self.limit = limit
    }
}

/// アプリ側が決める上限（DESIGN.md 第16.3節）。**モデルの要求とは別物なので型を分けてある。**
///
/// `ReadWindow` は「モデルが何を欲しがったか」、`ContextBudget` は「アプリが何を許すか」である。
/// 混ぜると、モデルの要求で上限が動く実装に容易になってしまう ─
/// 16.6節 約束1・約束3 が禁じているのはまさにその形である。
struct ContextBudget: Sendable, Equatable, Codable {

    /// この読み取り1回が文脈に置いてよいトークン数。**文字数ではない**（16.3節の規則1）。
    ///
    /// 見出し・囲い・区切りを**含めた**全体に効く。含めないと、
    /// 「上限に収めた」と言いながら毎回それを超える量を入れることになる。
    var tokens: Int

    /// 16.6節 約束5 の囲い文を入れるか。**既定は入れる。**
    ///
    /// 切れるようにしてあるのは、**効果が【未確認】だからである**（16.9節の項目9）。
    /// 効かないなら毎回の費用だけを払っていることになる。
    /// あり/なしで走らせられなければ、その判定ができない
    /// （`SophiaDefaults.systemPromptEnabled` を残してあるのと同じ理由）。
    var includesInjectionGuard: Bool

    init(tokens: Int, includesInjectionGuard: Bool = true) {
        self.tokens = tokens
        self.includesInjectionGuard = includesInjectionGuard
    }

    /// 読み取り1回ぶんの既定。
    ///
    /// **これは測っていない初期値である。** 根拠は次の2つの既知の数字からの割り付けにすぎない。
    ///
    /// | 値 | 出所 |
    /// |---|--:|
    /// | `SophiaDefaults.inputTokenBudget`（プリフィルが10秒に収まる入力の上限） | 1,000 |
    /// | `SophiaDefaults.contextLength` | 8,192 |
    ///
    /// 1回の読み取りが 1,000 を丸ごと使うと、**自己認識も会話の履歴も入る場所が無くなる。**
    /// 6割強を読み取りに充て、残りを履歴と system に残す、という置き方をしている。
    ///
    /// **16.9節の項目5（窓＋栞で足りるか）を測るときは、まずこの数字を疑うこと。**
    /// 足りないなら要約（第3段）へ進む前に、ここを動かして足りるかを先に見る。
    static let singleRead = ContextBudget(tokens: 600)
}

/// **第1段（入口）: ツールが返す量を、モデルへ渡す前にアプリが切る**（DESIGN.md 第16.3節）。
///
/// ## なぜ入口で切るのか
///
/// > 切り捨てはアプリの仕事である。モデルに渡してから「長いので要約して」と言うのでは、
/// > **渡した時点でプリフィルを払い終えている。**（16.3節）
///
/// 2026-08-18、利用者は短い一文を打っただけで 12,234トークンの壁に当たった（発見19）。
/// 長かったのは入力ではなく、**アプリが積み上げた履歴**である。
/// ファイルを読ませれば同じことが即座に起きる。**「ファイル全文を文脈に入れる」は成立しない。**
///
/// ## この型はモデルもファイルI/Oも持たない
///
/// 受け取るのは既に読み終えた文字列で、返すのは値だけである。副作用が無い。
/// **そうしてあるのはテストのためである** ─ 境界（空 / ちょうど上限 / 上限+1 /
/// 改行の無い巨大ファイル）は、実ファイルを置いて確かめる種類のものではない。
/// ファイルを開くのも封じ込め（16.5節）も `Sophia/Sources/Files/` の仕事。
enum ContextWindow {

    /// 読んだ内容を、上限に収まる窓へ切り詰める。
    ///
    /// - Parameters:
    ///   - text: 既に読み終えたファイルの中身。
    ///   - path: 結び付いたフォルダからの相対パス（16.4節）。見出しと栞に出る。
    ///   - window: モデルが要求した窓。
    ///   - budget: アプリが許す上限。
    ///   - counter: **トークンの数え方。既定は概算、実トークナイザに差し替えられる**
    ///     （`TokenCounter` のコメント / 第15章の宿題）。
    static func clip(
        _ text: String,
        path: String,
        window: ReadWindow = ReadWindow(),
        budget: ContextBudget = .singleRead,
        counter: TokenCounter = .estimate
    ) -> ReadOutcome {

        let allLines = lines(of: text)
        let totalLines = allLines.count
        let totalBytes = text.utf8.count

        // モデルが要求した窓を、ファイルの実際の範囲へ収める。
        // **ここで落とすのは範囲の話だけで、封じ込め（16.5節）ではない。**
        // パスの解決は `Sophia/Sources/Files/` の責務であり、この層は中身しか見ていない。
        let start = max(window.offset, 1) - 1
        let requestedEnd: Int
        if let limit = window.limit, limit > 0 {
            requestedEnd = min(start + limit, totalLines)
        } else {
            requestedEnd = totalLines
        }
        let candidateCount = max(requestedEnd - start, 0)

        /// 途中経過から `ReadOutcome` を組む。
        ///
        /// **上限の判定に使う文字列を、この関数の外で別に組み立てないこと。**
        /// 判定した文字列と実際に入れる文字列が別々に作られると、
        /// 「上限に収めた」という約束が、気づきにくい形で破れる。
        func draft(
            lineCount: Int,
            partialCharacters: Int? = nil,
            budgetTooSmall: Bool = false
        ) -> ReadOutcome {

            let body: String
            let partial: PartialLine?

            if let characters = partialCharacters, candidateCount > 0 {
                let line = allLines[start]
                body = String(line.prefix(characters))
                partial = PartialLine(
                    line: start + 1,
                    includedCharacters: min(characters, line.count),
                    totalCharacters: line.count
                )
            } else if lineCount > 0 {
                body = allLines[start..<(start + lineCount)].joined(separator: "\n")
                partial = nil
            } else {
                body = ""
                partial = nil
            }

            let hasContent = partial != nil || lineCount > 0
            let firstLine: Int? = hasContent ? start + 1 : nil
            let lastLine: Int?
            if partial != nil {
                lastLine = start + 1          // 行の途中で切ったときは、その1行だけ
            } else if lineCount > 0 {
                lastLine = start + lineCount
            } else {
                lastLine = nil
            }

            let reason: ClipReason
            if budgetTooSmall {
                reason = .budgetTooSmall
            } else if candidateCount == 0 {
                // 空のファイルは「切っていない」。範囲外は「切った」。
                // **同じ「0行」でも意味が違う** ─ 前者は全部読んだ、後者は何も読めていない。
                reason = totalLines == 0 ? .none : .outOfRange
            } else if partial != nil {
                reason = .withinLine
            } else if lineCount < candidateCount {
                reason = .tokenBudget
            } else if candidateCount < totalLines {
                reason = .lineWindow
            } else {
                reason = .none
            }

            var outcome = ReadOutcome(
                path: path,
                totalLines: totalLines,
                totalBytes: totalBytes,
                firstLine: firstLine,
                lastLine: lastLine,
                partialLine: partial,
                body: body,
                reason: reason,
                tokenBudget: budget.tokens,
                contextTokens: 0,
                tokensAreEstimated: counter.isEstimate,
                includesInjectionGuard: budget.includesInjectionGuard
            )
            outcome.contextTokens = counter(outcome.contextText)
            return outcome
        }

        func fits(lineCount: Int, partialCharacters: Int? = nil) -> Bool {
            draft(lineCount: lineCount, partialCharacters: partialCharacters)
                .contextTokens <= budget.tokens
        }

        // 見出しだけで上限を超える場合。**空を黙って返さない。**
        // 収まらなかったと言えば、呼び出し側は上限を上げるか窓を変えるか決められる。
        guard fits(lineCount: 0) else {
            return draft(lineCount: 0, budgetTooSmall: true)
        }

        // 空のファイル、または `offset` が終端を越えている。
        guard candidateCount > 0 else {
            return draft(lineCount: 0)
        }

        // **全部入る場合だけは、先に直接確かめる。**
        //
        // 「行を増やせばトークンも増える」は、1点だけ成り立たない ─
        // **全部入った瞬間に断り書きが消える**ので、そこでサイズが逆に減る。
        // 20行のファイル（1文字=1トークン）で実際にこうなる:
        //
        // | 入れる行数 | 全体の大きさ |
        // |--:|--:|
        // | 16 | 251 |
        // | 19 | 275 |
        // | **20（全部）** | **234** |
        //
        // 挟み込みは単調性を前提にしているので、**この1点を飛び越える。**
        // 上限を 234 に置くと「13行しか入らない」と答えてしまい、
        // **丸ごと入るファイルを切ってしまう。** 探索に任せず、ここだけ直接見る。
        //
        // 巨大なファイルで無駄に巨大な文字列を組まないよう、バイト数で足切りする。
        // 1トークンあたり8バイトを超えて入ることは、どの数え方でもまず無い ─
        // 試さずに飛ばしても答えは変わらない（どのみち入らない）。
        if candidateCount == totalLines,
           totalBytes / 8 <= budget.tokens,
           fits(lineCount: candidateCount) {
            return draft(lineCount: candidateCount)
        }

        // 先頭の1行だけで明らかに入らないなら、行単位の探索そのものを省く。
        // **バイト数だけで判定できるので、巨大な1行を文字列として組まずに済む** ─
        // 改行の無い20万文字のファイルで、無駄な20万文字の組み立てが1回消える。
        var lineCount = 0
        if allLines[start].utf8.count / 8 <= budget.tokens {
            lineCount = largestFitting(upTo: candidateCount) { fits(lineCount: $0) }
            // 見出しの数字の桁が変わると、理屈の上では1トークンだけ単調性が崩れうる。
            // **最後に実物で確かめる。** 減る一方なので必ず止まる。
            while lineCount > 0, !fits(lineCount: lineCount) { lineCount -= 1 }
        }

        if lineCount > 0 {
            return draft(lineCount: lineCount)
        }

        // ここへ来たのは、**先頭の1行だけで上限を超えている**場合である。
        // 改行の無い巨大ファイル（1行の JSON、minify 済みのコード、ログの1行）で普通に起きる。
        //
        // **行単位のままだと 0行 しか返せない。** それは「読めなかった」と同じで、
        // モデルは同じ要求を繰り返すか、諦めて中身を知らないまま答える。
        // 行を諦めて**文字で切る。** ただし範囲の言い方が変わる（`nextOffset` が nil になる）ので、
        // `ClipReason.withinLine` として区別して伝える。
        let lineLength = allLines[start].count
        var characters = largestFitting(upTo: lineLength) { fits(lineCount: 0, partialCharacters: $0) }
        while characters > 0, !fits(lineCount: 0, partialCharacters: characters) { characters -= 1 }

        // 1文字も入らないほど上限が小さい。見出しは入るが中身が入らない、という状態。
        guard characters > 0 else {
            return draft(lineCount: 0, budgetTooSmall: true)
        }
        return draft(lineCount: 0, partialCharacters: characters)
    }

    // MARK: - 行に分ける

    /// 行に分ける。**改行文字そのものは持たない**（`joined(separator: "\n")` で戻る）。
    ///
    /// - `""` → 0行（空のファイルは「1行の空行」ではない）
    /// - `"a\n"` → 1行（末尾の改行で空行が増えない）
    /// - `"a\n\n"` → 2行（途中の空行は行である）
    ///
    /// **CRLF は `\r` を行の中身として残す。** `\r` を落とすと、
    /// 戻したときに原文と1バイトずつ違うものを「原文の部分列」と称することになる。
    /// バイト数の申告（`totalBytes`）と食い違わせないためにも、内容には手を入れない。
    /// **`String` を `\n` で split してはいけない。**
    /// Swift の `Character` は **CRLF を1文字として扱う**ので、`"a\r\nb"` の中に
    /// `Character("\n")` は存在せず、**行が割れない**（実測で1件落ちた）。
    /// Python へ移植した検証では再現しない ─ **言語固有の罠である。**
    /// したがって `Character` より下（Unicode スカラー）で境界を取る。
    static func lines(of text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        let scalars = text.unicodeScalars
        var parts: [Substring] = []
        var start = scalars.startIndex
        var index = scalars.startIndex
        while index < scalars.endIndex {
            if scalars[index] == "\n" {
                parts.append(Substring(scalars[start..<index]))
                start = scalars.index(after: index)
            }
            index = scalars.index(after: index)
        }
        parts.append(Substring(scalars[start...]))
        if text.hasSuffix("\n"), !parts.isEmpty { parts.removeLast() }
        return parts
    }

    // MARK: - 収まる最大値を探す

    /// `fits(n)` が真になる最大の `n` を `0...upperBound` から返す。
    ///
    /// ## 上から二分探索しない理由
    ///
    /// 素直に `0...upperBound` を二分探索すると、**最初の一手で上半分の文字列を組む。**
    /// 20万行のファイルなら、収まるのは高々数KBだと分かっているのに、
    /// 判定のために10万行ぶんの文字列を作って数えることになる。
    /// **実トークナイザを挿したときに、これは秒で効いてくる。**
    ///
    /// **下から倍々に伸ばして挟み込む。** 触る文字列は最終的な答えの高々2倍で済み、
    /// 呼び出し回数は答えの対数になる。ファイルがどれだけ巨大でも、
    /// 費用は「上限に収まる量」だけで決まる。
    private static func largestFitting(upTo upperBound: Int, fits: (Int) -> Bool) -> Int {
        guard upperBound > 0, fits(1) else { return 0 }

        var lo = 1                  // fits(lo) == true
        var hi = upperBound + 1     // 番兵。fits(hi) == false として扱う
        var probe = 2
        while probe <= upperBound {
            if fits(probe) {
                lo = probe
                probe *= 2
            } else {
                hi = probe
                break
            }
        }

        // 倍々が上限を飛び越えた場合、上限そのものはまだ試していない。
        if hi == upperBound + 1, lo < upperBound {
            if fits(upperBound) { return upperBound }
            hi = upperBound
        }

        while lo + 1 < hi {
            let mid = lo + (hi - lo) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }
}
