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
    /// **数字はここに書かない。** 出所は `SophiaDefaults.InputBudget` の配分表1か所だけである。
    ///
    /// ---
    ///
    /// # 2026-08-18: 600 → 360 に下げた。**元の根拠のどこが成り立たなかったか**
    ///
    /// 元のコメントはこう書いていた ──
    ///
    /// > 1回の読み取りが 1,000 を丸ごと使うと、**自己認識も会話の履歴も入る場所が無くなる。**
    /// > 6割強を読み取りに充て、残りを履歴と system に残す
    ///
    /// **規則そのものは正しい。壊れているのは分母である。**
    /// この割り付けには **ツール定義が1トークンも入っていない。**
    /// 入っていないのは見落としではなく、**600 を決めた時点でその項が存在しなかった**からで、
    /// 読み取り3ツールの費用が実測されたのは 2026-08-18（322トークン／英語版）である。
    /// つまり 600 は「1,000 のうちの6割強」であって、
    /// **「読み取りに使える分のうちの6割強」ではなかった。**
    ///
    /// 同じ規則を、正しい分母に当て直す:
    ///
    /// | | |
    /// |---|--:|
    /// | 総額（DESIGN 2.2章） | 1,000 |
    /// | − 固定の前置き（**実測**） | 105 |
    /// | − ツール定義（**2026-08-23 実測** / `armed` の間） | 499 |
    /// | − 栞 | 180 |
    /// | − 利用者入力 | 33 |
    /// | **読み取りに残る分** | **183** |
    ///
    /// **測って決めた数字ではない。** 元の 600 と同じく割り付けである ──
    /// 変わったのは根拠の質ではなく、**足しても総額を超えなくなったこと**だけである。
    /// 「600 は測っていない初期値だった」という元のコメントの但し書きは、そのまま生きている。
    ///
    /// # 狭くなったことの副作用は、往復の増加として出る
    ///
    /// > **16.9節の項目5（窓＋栞で足りるか）を測るときは、まずこの数字を疑うこと。**
    ///
    /// 183は以前の360より狭い。**足りなければモデルは `offset` で続きを取りに行く**
    /// （`read_file` は窓で返すと決めてある。16.4節）。増えた往復が
    /// `FolderToolRunner.callLimit`（6）を先に使い切るなら、**それが要約（第3段）へ進む合図**である。
    /// **上げるなら、配分表のどこから取るかを同時に決めること** ──
    /// ここだけを上げるのが、本日直したばかりの誤りである。
    static let singleRead = ContextBudget(tokens: SophiaDefaults.InputBudget.singleRead)
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

        // モデルが要求した窓を、ファイルの実際の範囲へ収める。
        // **ここで落とすのは範囲の話だけで、封じ込め（16.5節）ではない。**
        // パスの解決は `Sophia/Sources/Files/` の責務であり、この層は中身しか見ていない。
        //
        // 足し算の前に `min` を取っているのは桁あふれ避けである。
        // `offset` / `limit` は**モデルが書いてくる数**なので `Int.max` が来うる。
        // `start + limit` を先に計算すると、それだけでプロセスが落ちる。
        let start = min(max(window.offset, 1) - 1, totalLines)
        let remaining = totalLines - start
        let take: Int
        if let limit = window.limit, limit > 0 {
            take = min(limit, remaining)
        } else {
            take = remaining
        }

        return clip(
            candidate: allLines[start..<(start + take)],
            startingAtLineIndex: start,
            path: path,
            totalLines: totalLines,
            totalBytes: text.utf8.count,
            budget: budget,
            counter: counter
        )
    }

    /// **既に窓で読み終えたものを受ける入口**（DESIGN.md 第16.3節 第1段の橋）。
    ///
    /// ## なぜ入口が2つ要るのか
    ///
    /// `clip(_:path:window:budget:counter:)` は**ファイル全文**を受け取り、
    /// 総行数も総バイト数も自分で数える。ところが実際に読むのは
    /// `FolderReader.readText`（`Sophia/Sources/Files/`）で、**あれは既に窓で切った
    /// `FileWindow` を返す。** 全文はどこにも無い ── 8,192トークンの上限に対して
    /// 数百行のファイルは単独で壁を作るので、**全文を持つこと自体を避けている**（16.3節 / 発見19）。
    ///
    /// 全文が無いまま前者に渡すと、**窓の中だけを「ファイル全体」として数えることになる。**
    /// 見出しは「全80行すべて」と言い、412行のファイルを読んだモデルは
    /// **全部読んだと信じる。** 16.3節が「一番危ない」と名指しした状態そのものである。
    ///
    /// だから**総数は数えず、読み手から受け取る。** 受け取った総数を使って、
    /// 行番号も「切ったかどうか」も**ファイル全体を基準に**組み立てる。
    ///
    /// - Parameters:
    ///   - text: 窓に入った本文だけ。**ファイル全文ではない。**
    ///   - firstLine: `text` の1行目が、ファイル全体では何行目か（**1始まり**）。
    ///   - totalLines: **ファイル全体**の行数（`FileWindow.totalLines`）。
    ///   - totalBytes: **ファイル全体**のバイト数（`FileWindow.totalBytes`）。
    ///
    /// ## 申告が窓と食い違ったら、総数のほうを信じない
    ///
    /// `totalLines` が「窓の右端」より小さいことは、事実としてありえない。
    /// それでも渡されたら**窓の右端まで引き上げる。** 過大に言う害（「まだ先がある」）は
    /// 保留を1回増やすだけだが、**過少に言う害は「全部読んだ」という断定を作る。**
    /// 対称ではないので、安全な側へ倒す。
    ///
    /// ## CRLF について（`FileWindow` との既知の差）
    ///
    /// `FolderReader.readText` は CRLF の `\r` を落として返し、こちらの `lines(of:)` は残す。
    /// **この入口には既に `\r` の落ちた本文が来る**ので、両者が食い違うことはない。
    /// ただし `totalBytes` は**落とす前のファイルの実バイト数**なので、
    /// CRLF のファイルでは `body` のバイト数より必ず大きくなる。
    /// **これは誤差ではなく、そう決めた**（判断の理由は `FolderToolExecution` の CRLF の節）。
    static func clip(
        windowed text: String,
        path: String,
        firstLine: Int,
        totalLines: Int,
        totalBytes: Int,
        budget: ContextBudget = .singleRead,
        counter: TokenCounter = .estimate
    ) -> ReadOutcome {

        // **`lines(of:)` ではなく `windowLines(of:)` で数えること。**
        // 来るのは読み手が `\n` で**連結した**本文なので、末尾の `\n` は行の終端ではなく
        // 区切りである ─ 終端として読むと**末尾の空行が受け渡しで消える**（あちらの但し書き）。
        let windowLines = windowLines(of: text)

        // **`firstLine` が暴走しない上限を、引数そのもので与える。**
        //
        // `firstLine` は `FolderToolExecution` の `window.firstLine ?? offset` から来る。
        // **窓が空でない限り読み手由来**（実ファイルを数えた値）だが、
        // 空のときだけモデルの `offset` がそのまま入る ── `Int.max` が来る。
        //
        // **2026-08-18: ここは3度書き直している。記録を残す。**
        //
        // | 版 | 式 | 何が起きたか |
        // |---|---|---|
        // | 1 | 上限なし | `start + count` が桁あふれして **SIGTRAP でプロセスごと死亡** |
        // | 2 | `Int.max - count - 1` | 落ちなくなったが **2行のファイルが 922京行** と申告された |
        // | 3 | `totalLines - count` | 暴走は止まったが、**下の「過少申告を持ち上げる」保証を壊した** |
        //
        // 2版目の教訓が本題である ── **「落ちないこと」だけを確かめて
        // 「正しい値か」を確かめていなかった。** 表明を生存ではなく値に置いて初めて出た。
        //
        // 3版目で分かったのは、`totalLines` を絶対の真としてはいけないことである。
        // **過少申告は「全部読んだ」という嘘の断定を作る**（下の `reportedTotal` の理由）。
        // したがって持ち上げは残し、**上限だけを引数に縛る。**
        // 現実の入力では `start` は必ず `totalLines - count` 以下なので、
        // この上限が実際に効くのは**あり得ない入力のとき**だけである。
        let start = min(max(firstLine, 1) - 1, max(totalLines, 0) + windowLines.count)

        // **1行も入っていないときは、`firstLine` を総数の根拠にしないこと。**
        // 窓が空なら「その行が在る」ことを何も示していない ── 終端を越えた `offset`
        // （モデルは平気で 999 と書く）を総数に化けさせると、
        // **「offset は 1〜998 で指定してください」という嘘の案内**になる。
        // 実測で1件落ちた（`ToolExecutionTests` の範囲外の節）。
        let reportedTotal = windowLines.isEmpty
            ? totalLines
            : max(totalLines, start + windowLines.count)

        return clip(
            candidate: windowLines[windowLines.startIndex...],
            startingAtLineIndex: start,
            path: path,
            totalLines: reportedTotal,
            totalBytes: max(totalBytes, text.utf8.count),
            budget: budget,
            counter: counter
        )
    }

    /// 2つの入口が共有する本体。**切り詰めの規則をここ1か所にしか置かない。**
    ///
    /// 入口ごとに書くと、全文の側と窓の側で「切ったと言う条件」が少しずつずれる。
    /// ずれた側が「切っていない」に倒れた瞬間、**静かに嘘をつく実装**になる（`ReadOutcome` の型コメント）。
    ///
    /// - Parameters:
    ///   - candidate: 窓に入りうる行（**ファイル全体ではない**）。
    ///   - startingAtLineIndex: `candidate` の先頭が、ファイル全体では何行目か（**0始まり**）。
    private static func clip(
        candidate: ArraySlice<Substring>,
        startingAtLineIndex start: Int,
        path: String,
        totalLines: Int,
        totalBytes: Int,
        budget: ContextBudget,
        counter: TokenCounter
    ) -> ReadOutcome {

        let candidateCount = candidate.count
        let base = candidate.startIndex

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
                let line = candidate[base]
                body = String(line.prefix(characters))
                partial = PartialLine(
                    line: start + 1,
                    includedCharacters: min(characters, line.count),
                    totalCharacters: line.count
                )
            } else if lineCount > 0 {
                body = candidate[base..<(base + lineCount)].joined(separator: "\n")
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

        // **候補が丸ごと入る場合だけは、探索に任せず先に直接確かめる。**
        //
        // 「行を増やせばトークンも増える」は、**候補の右端の1歩でだけ**成り立たない。
        // 縮む理由は2つあり、どちらも同じ1点（＝右端）に出る:
        //
        // | 何が消えるか | いつ |
        // |---|---|
        // | 断り書きが丸ごと（`.none` になる） | 候補がファイル全体を覆ったとき |
        // | 「続きは offset=N から読めます。」の一文だけ | 窓の右端がファイルの**終端に届いた**とき |
        //
        // 20行のファイル（1文字=1トークン / `offset=2`）で実測するとこうなる ─
        //
        // | 入れる行数 | 全体の大きさ |
        // |--:|--:|
        // | 17 | 260 |
        // | 18 | 268 |
        // | **19（終端に届く）** | **255** |
        //
        // 挟み込みは単調性を前提にしているので、**この1点を飛び越える。**
        // 上限を 255 に置くと「丸ごと入るのに切った」と答え、実測では**行数が 0 まで落ちて
        // 「上限が小さすぎて、内容を入れられませんでした」**が返る組み合わせがあった。
        // 丸ごと入っていたのだから、**その文は嘘である。**
        //
        // **2026-08-18: ここの条件を一般化した。記録を残す。**
        // 元は `start == 0 && candidateCount == totalLines`、つまり
        // 「`offset=1` でファイル全部」しか見ていなかった。**表の2行目が抜けている。**
        // 窓で読んだ結果を受ける入口（`clip(windowed:)`／実運用の経路）では
        // `start != 0` が普通なので、**近道は一度も効かなかった。**
        // 単調性が崩れるのは「ファイルの先頭から全部」ではなく**候補の右端**なので、
        // 右端そのものを直接見る。**「全部入った」と言うかどうかは変わらない** ─
        // 理由を付けるのは `draft` で、全体を覆っていなければ `.lineWindow` のままである。
        //
        // 巨大なファイルで無駄に巨大な文字列を組まないよう、バイト数で足切りする。
        // **足切りは「候補の」バイト数で行うこと。** 元は `totalBytes`（＝ファイル全体）で見ており、
        // 窓の入口では「窓は小さいのにファイルが大きい」だけで近道が落ちていた。
        if utf8Count(of: candidate, notExceedingTokens: budget.tokens) != nil,
           fits(lineCount: candidateCount) {
            return draft(lineCount: candidateCount)
        }

        // 先頭の1行だけで明らかに入らないなら、行単位の探索そのものを省く。
        // **バイト数だけで判定できるので、巨大な1行を文字列として組まずに済む** ─
        // 改行の無い20万文字のファイルで、無駄な20万文字の組み立てが1回消える。
        var lineCount = 0
        if candidate[base].utf8.count / 8 <= budget.tokens {
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
        let lineLength = candidate[base].count
        var characters = largestFitting(upTo: lineLength) { fits(lineCount: 0, partialCharacters: $0) }
        while characters > 0, !fits(lineCount: 0, partialCharacters: characters) { characters -= 1 }

        // 1文字も入らないほど上限が小さい。見出しは入るが中身が入らない、という状態。
        guard characters > 0 else {
            return draft(lineCount: 0, budgetTooSmall: true)
        }
        return draft(lineCount: 0, partialCharacters: characters)
    }

    // MARK: - 行に分ける

    /// **ファイル全文**を行に分ける。**改行文字そのものは持たない**（`joined(separator: "\n")` で戻る）。
    ///
    /// - `""` → 0行（空のファイルは「1行の空行」ではない）
    /// - `"a\n"` → 1行（末尾の改行で空行が増えない）
    /// - `"a\n\n"` → 2行（途中の空行は行である）
    ///
    /// **ここで `\n` は行の「終端」である。** 窓の本文（読み手が `\n` で**連結して**返したもの）
    /// では同じ文字が「区切り」になり、数え方が1行ずれる ─ そちらは `windowLines(of:)`。
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
        var parts = splitOnNewlines(text)
        // **末尾判定も `Character` より下で行うこと。**
        //
        // ここは `text.hasSuffix("\n")` だった。分割のほうは上の但し書きどおり
        // スカラーまで降ろしてあったのに、**4行下のこの1行だけが `Character` 単位で残っていた** ─
        // `"a\r\n"` の最後の `Character` は `"\r\n"` であって `"\n"` ではないので
        // `hasSuffix("\n")` は **false** を返し、末尾の空要素が落ちない。
        // 結果、**CRLF で終わるファイルだけが必ず1行多く数えられ**、
        // 読み手（バイトで数える `FolderReader`）と総数が食い違い、
        // 存在しない最終行が「全4行のうち 4-4行」として**読めた形で返っていた。**
        // **同じ関数に、同じ罠が2つあった。**
        if text.unicodeScalars.last == "\n", !parts.isEmpty { parts.removeLast() }
        return parts
    }

    /// **窓の本文**を行に分ける（`FolderReader.readText` が返す `FileWindow.text`）。
    ///
    /// `lines(of:)` との違いは**末尾の改行の意味だけ**である。
    /// 読み手は読めた行を `joined(separator: "\n")` で連結して返すので、
    /// そこでの `\n` は行の**終端ではなく区切り**である ─
    /// `["a", ""]`（2行目が空行）は `"a\n"` になる。
    ///
    /// これを終端として読むと**末尾の空行が受け渡しで消える。**
    /// 消えた結果どうなるかというと、「全2行のうち 1-1行」と申告して
    /// **「続きは offset=2 から読めます」と案内し、モデルがそのとおり読むと
    /// 「offset は 1〜2 で指定してください」と返る** ─
    /// 連続する2ターンで矛盾した指示を出すことになる。
    ///
    /// - `""` → **0行。** 読み手は1行も読めなかったときに `""` を返す。
    ///   ここを「1行の空行」と読むと、範囲外が「空行を1行読めた」に化ける。
    /// - `"a\n"` → 2行（`["a", ""]`）
    /// - `"a"` → 1行
    ///
    /// > **【承知している残り】** 読み手が「空行を1行だけ」読めたときも本文は `""` になる。
    /// > 引数からはそれと「1行も読めなかった」を区別できないので、`.outOfRange` に倒れる。
    /// > 区別するには読み手が行数を別に渡す必要があり、それは入口の契約の変更になる。
    static func windowLines(of text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        return splitOnNewlines(text)
    }

    /// スカラー単位で `\n` を境に割る。**末尾の空要素も落とさずに返す**（落とすかは呼び手が決める）。
    private static func splitOnNewlines(_ text: String) -> [Substring] {
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
        return parts
    }

    // MARK: - 明らかに入らないものを、組む前に落とす

    /// 候補を丸ごと入れたときの**本文の**バイト数。**上限を超えた時点で数えるのをやめて nil を返す。**
    ///
    /// 「1トークンあたり8バイトを超えて入ることは、どの数え方でもまず無い」という前提の足切りである。
    /// 目的は費用だけ ── 20万行のファイルで「丸ごと入るか」を確かめるために
    /// 20万行ぶんの文字列を1回組むのを避ける。途中で打ち切るので、
    /// **触るのは高々「上限8倍のバイト数」だけ**で、ファイルの大きさに依存しない。
    ///
    /// **前提が破れても答えは間違わない**（足切りされた側は探索へ回る）。
    /// ただし探索は単調性の崩れた点を飛び越えうるので、**この前提は費用の話でありながら
    /// 正しさに片足を掛けている。型では何も強制していない** ─
    /// `AdversarialContextTests.testTheByteShortcutDependsOnAnAssumptionAboutTheCounterThatNothingEnforces`
    /// が、10文字=1トークンの器を挿して実際に前提を破って見せている。
    private static func utf8Count(
        of lines: ArraySlice<Substring>,
        notExceedingTokens tokens: Int
    ) -> Int? {
        var total = 0
        for line in lines {
            total += line.utf8.count + 1        // 連結に使う改行のぶん
            if total / 8 > tokens { return nil }
        }
        return total
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
