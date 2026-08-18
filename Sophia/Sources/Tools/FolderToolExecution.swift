import Foundation

/// **モデルが呼んだツールを、実際に実行する**（DESIGN.md 第16章 / FR-19）。
///
/// ---
///
/// # この層が持っている唯一の権限は「読むこと」である
///
/// | やること | どこがやるか |
/// |---|---|
/// | パスの検証（16.5節の4手順） | **`FolderContainment`。この層は代わりにやらない** |
/// | ファイルを開く・数える | `FolderReader` |
/// | 文脈へ入る量に切る（16.3節 第1段） | **`ContextWindow`。この層は代わりにやらない** |
/// | 囲いと但し書き（16.6節 約束5） | `ReadOutcome` |
/// | どれをいつ呼ぶか | **ここ** |
///
/// **繋ぐだけの層である。** 判断を持たせないこと ──
/// ここに「このパスなら大丈夫」「この程度なら切らなくてよい」が1つでも入ると、
/// 検証と切り詰めが**2か所**になり、どちらが本物か誰にも分からなくなる。
///
/// # モデルが書いたパスは、型の壁を越えられない
///
/// `FolderReader` は `String` を受け取らない。**`ContainedPath` しか受けない。**
/// そして `ContainedPath` を作れるのは `FolderContainment` だけである（`init` が `fileprivate`）。
/// この層が持てるのは `AccessedFolder.resolve(_:)` の戻り値だけで、
/// **モデルの文字列から読み取りに至る経路が、型のレベルで1本しかない。**
///
/// > **迂回を書かないこと。** `FileManager` を直接呼ぶ、`URL(fileURLWithPath:)` を組む、
/// > `ContainedPath` の `init` を internal に開ける ── どれも 16.5節の4手順を丸ごと飛ばす。
/// > **この層に `import Darwin` も `FileManager` も出てこないのは、そういう意図である。**
enum FolderToolExecution {

    /// アプリ側が無条件に掛ける上限。**モデルの要求では動かない**（16.6節 約束1・約束3）。
    struct Limits: Sendable, Equatable {

        /// 一覧1回で見る件数（`FolderReader` の上限をそのまま使う）。
        var entryLimit: Int = FolderReadLimits.entryLimit

        /// 読み取り1回の行数（16.4節の窓）。
        var lineLimit: Int = FolderReadLimits.lineLimit

        /// 隠しファイルを見せるか。**既定は見せない**（`.env` や `.ssh` をモデルの前に置かない）。
        var includesHidden: Bool = false

        /// 検索が返す最大件数。
        var searchMatchLimit: Int = 50

        /// 検索が開くディレクトリ数の上限。
        ///
        /// **これが無いと `node_modules` 1つで数万回の一覧が走る。**
        /// 16.8節は往復の上限しか求めていないが、**1回の呼び出しの中でも上限が要る** ──
        /// 上限の無い探索は、モデルが待っている間ずっと機械を占有する。
        var searchDirectoryLimit: Int = 200

        /// 検索が潜る深さの上限（根が 0）。
        var searchDepthLimit: Int = 8

        static let standard = Limits()
    }

    // MARK: - 入口

    /// ツール1回を実行して、**モデルへ返せる形**にして返す。
    ///
    /// **throw しない。** 16.8節が「ルート外のパスを要求された →
    /// 実行せず、**その旨をツールの戻り値としてモデルに返す。往復を1回で打ち切らない**」
    /// と決めているので、失敗も戻り値である。
    static func perform(
        _ call: ToolCallRequest,
        in folder: SecurityScopedFolder,
        limits: Limits = .standard,
        budget: ContextBudget = .singleRead,
        counter: TokenCounter = .estimate
    ) -> ToolResult {

        guard let tool = FolderTool(rawValue: call.name) else {
            // 16.8節「ツール名が一致しない」。**握って、名前が違う旨をモデルに返す。**
            return .rejected(.unknownTool(call.name), tool: call.name, counter: counter)
        }

        switch tool {
        case .listDirectory:
            // path は省略を許す（**空文字＝結び付けたフォルダ自身**）。
            // 一覧の起点が無いと言って往復を落とすより、根を見せるほうが意図に近い。
            let requested = call.arguments.string(FolderTool.Argument.path) ?? ""
            return attempt(call, in: folder, requested: requested, counter: counter) { accessed in
                try list(
                    requested, accessed: accessed, call: call,
                    limits: limits, budget: budget, counter: counter)
            }

        case .readFile:
            guard let requested = call.arguments.string(FolderTool.Argument.path),
                  !requested.isEmpty
            else {
                return .rejected(
                    .missingArgument(tool: tool.rawValue, name: FolderTool.Argument.path),
                    tool: call.name, counter: counter)
            }
            return attempt(call, in: folder, requested: requested, counter: counter) { accessed in
                try read(
                    requested, accessed: accessed, call: call,
                    limits: limits, budget: budget, counter: counter)
            }

        case .searchFiles:
            let raw = call.arguments.string(anyOf: FolderTool.Argument.queryAliases) ?? ""
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                return .rejected(
                    .missingArgument(tool: tool.rawValue, name: FolderTool.Argument.query),
                    tool: call.name, counter: counter)
            }
            let requested = call.arguments.string(FolderTool.Argument.path) ?? ""
            return attempt(call, in: folder, requested: requested, counter: counter) { accessed in
                try search(
                    query, from: requested, accessed: accessed, call: call,
                    limits: limits, budget: budget, counter: counter)
            }
        }
    }

    /// **アクセススコープの内側で実行し、失敗はモデルへの返答に変える。**
    ///
    /// `withAccess` は毎回ここで根を確かめ直す（`SecurityScopedFolder` の型コメント）。
    /// フォルダが移動・改名・削除されていれば `.rootMoved` / `.rootUnavailable` が上がり、
    /// **「黙って読めないまま進む」ことはない**（16.8節）。
    private static func attempt(
        _ call: ToolCallRequest,
        in folder: SecurityScopedFolder,
        requested: String,
        counter: TokenCounter,
        _ body: (AccessedFolder) throws -> ToolResult
    ) -> ToolResult {
        do {
            return try folder.withAccess(body)
        } catch let error as FolderAccessError {
            return .failed(error, tool: call.name, counter: counter)
        } catch {
            // ここへ来る経路は現状無い（この層が呼ぶものは全部 `FolderAccessError` を投げる）。
            // **それでも握る。** 握らないと、想定外の1件で会話ごと落ちる。
            return .failed(
                .ioFailed(path: requested, detail: "\(type(of: error))"),
                tool: call.name, counter: counter)
        }
    }

    // MARK: - list_directory（16.4節）

    private static func list(
        _ requested: String,
        accessed: AccessedFolder,
        call: ToolCallRequest,
        limits: Limits,
        budget: ContextBudget,
        counter: TokenCounter
    ) throws -> ToolResult {

        // **ここが封じ込めの入口である。** 通らなければ throw され、
        // `attempt` がモデルへの「拒否」に変える。
        let contained = try accessed.resolve(requested)
        let listing = try FolderReader.list(
            contained, limit: limits.entryLimit, includingHidden: limits.includesHidden)

        let where_ = display(of: contained)
        let rendered = listing.entries.map { entry(for: $0, showingFullPath: false, withDate: true) }

        // **「方針で伏せた」と「上限で切った」を分ける**（2026-08-18）。
        //
        // 隠しファイルが `totalCount` に入るようになったのは正しい修正だが、
        // **`.DS_Store` はどの macOS フォルダにもある。**
        // 総数と表示数の差だけで言うと、**普通のフォルダが毎回「全11件のうち 10件」**になる。
        // モデルはそれを「続きがある」と読み、`list_directory` にページ送りの引数は無い
        // （16.4節は `path` だけ）ので**取りに行けない。行き止まりを毎ターン伝えることになる。**
        //
        // `FolderReader` は既に区別する材料を持っている（`DirectoryListing` の型コメント）:
        //
        // | 値 | 意味 | 続きは |
        // |---|---|---|
        // | `omittedHiddenCount` | 隠しファイルとして方針で伏せた | **取れない**（方針を変えるまで） |
        // | `listable - shown` | 件数上限とトークン上限で載せきれなかった | この一覧では取れないが、**絞れば取れる** |
        //
        // **「切ったことを黙る」に倒していない。** 伏せた件数も切った件数も必ず言う ──
        // 黙る実装は静かに嘘をつく（16.3節 / `ReadOutcome` の型コメント）。
        // 分けたのは**言うか黙るか**ではなく、**次の手を示唆してよいかどうか**である。
        let hidden = listing.omittedHiddenCount
        // 方針の側で伏せた分を除いた「本来なら載せられた件数」。
        // **これがモデルにとっての母数である** ── 伏せた分は母数に混ぜると
        // 「あと1件どこかにある」という取りに行けない期待を作る。
        let listable = max(listing.totalCount - hidden, 0)

        let outcome = fitted(
            // **空の理由を取り違えないこと。** 隠しファイルしか無いフォルダは「空」ではない。
            lines: rendered.isEmpty
                ? [hidden > 0 ? "（表示できるものはありません）" : "（このフォルダは空です）"]
                : rendered,
            budget: budget,
            counter: counter,
            label: { shown in
                listingLabel(
                    where_,
                    // 中身が無いときに渡ってくる `shown` は差し込んだ1行ぶんであって、
                    // **件数ではない。** 件数として使うと「0件のうち 1件」になる。
                    shown: rendered.isEmpty ? 0 : shown,
                    listable: listable,
                    hidden: hidden)
            })

        return .content(outcome, tool: call.name, isListing: true)
    }

    /// 一覧の見出し。**行き止まり（取りに行けない差）と、次の手がある差を、同じ文で言わない。**
    ///
    /// ## ページ送りは示唆していない。**引数が無いからである**
    ///
    /// 件数上限で切れた側は「続きが取れる」性質のものだが、
    /// **`list_directory` は `path` しか受け取らない**（16.4節）。
    /// ここで「続きは…から読めます」と書くと、モデルはそのとおり呼び、呼べずに戻る ──
    /// **連続する2ターンで矛盾した指示を出す**ことになる
    /// （`ContextWindow.windowLines(of:)` の但し書きが記録している失敗と同じ形）。
    ///
    /// **だから示唆するのは、実際に効く次の手だけにしてある** ──
    /// 下位のフォルダを個別に一覧する、`search_files` で名前を絞る。どちらも今日呼べる。
    ///
    /// ## 伏せた側には次の手を書かない
    ///
    /// 隠しファイルは `FolderToolExecution.Limits.includesHidden` が false である限り、
    /// **どう呼んでも返らない。** 次の手を書けば、それは必ず無駄な往復になる。
    /// 「取得できません」で終えるのが、この場合の正直な文である。
    private static func listingLabel(
        _ where_: String, shown: Int, listable: Int, hidden: Int
    ) -> String {

        var text: String
        if listable == 0 {
            text = "\(where_) の一覧（0件）"
        } else if shown < listable {
            text = "\(where_) の一覧（\(listable)件のうち \(shown)件）"
        } else if hidden > 0 {
            // **「全」と書かないこと。** 直後に「隠し N件」と続くので、
            // 「全10件」は「では11件目は？」を誘う。全部見えているときだけ「全」を使う。
            text = "\(where_) の一覧（\(listable)件）"
        } else {
            text = "\(where_) の一覧（全\(listable)件）"
        }

        if shown < listable {
            text += "／残り \(listable - shown)件はこの一覧では取れません。"
                + "下位フォルダを指定するか search_files で絞ってください"
        }
        if hidden > 0 {
            text += "／隠し \(hidden)件は非表示（取得できません）"
        }
        return text
    }

    // MARK: - read_file（16.4節 / 16.3節の橋）

    private static func read(
        _ requested: String,
        accessed: AccessedFolder,
        call: ToolCallRequest,
        limits: Limits,
        budget: ContextBudget,
        counter: TokenCounter
    ) throws -> ToolResult {

        let contained = try accessed.resolve(requested)

        // モデルの数はそのまま使わない。**上限はアプリが決める**（16.6節 約束1）。
        let offset = max(call.arguments.integer(FolderTool.Argument.offset) ?? 1, 1)
        let requestedLimit = call.arguments.integer(FolderTool.Argument.limit) ?? limits.lineLimit
        let limit = min(max(requestedLimit, 1), limits.lineLimit)

        let window = try FolderReader.readText(contained, offset: offset, limit: limit)

        // **ここを通さずにモデルへ渡さないこと。**
        // 2026-08-18、利用者は短い一文を打っただけで 12,234トークンの壁に当たった（発見19）。
        // ファイルを読ませれば即座に同じ壁である。窓（`FolderReader` の行数）だけでは足りない ──
        // **1行が10万文字のファイルは、200行の窓に収まっていても壁を作る。**
        //
        // 総数は数え直させない。`FileWindow` が**ファイル全体**の行数とバイト数を持っており、
        // 窓の中だけを数えると「全80行すべて」という嘘の見出しになる（`clip(windowed:)` の但し書き）。
        let outcome = ContextWindow.clip(
            windowed: window.text,
            path: ToolText.singleLine(window.path, limit: ToolText.nameLimit),
            firstLine: window.firstLine ?? offset,
            totalLines: window.totalLines,
            totalBytes: window.totalBytes,
            budget: budget,
            counter: counter)

        return .content(outcome, tool: call.name, isListing: false)
    }

    // MARK: - search_files（16.4節）

    /// **名前で探す。中身は見ない。**
    ///
    /// DESIGN 16.4節の3つ目は「**名前のパターン**で探す」である。
    /// プローブで測ったときの説明文は「文字列を含むファイルを探す」（＝中身の検索）だったが、
    /// **中身の検索は配下の全ファイルを開いて読むことを意味する。**
    /// 16GB の機械で、モデルが待っている間にそれをやる判断は、
    /// **測ってからにするべきである**（VISION 第1因子。費用は往復ではなく I/O で出る）。
    /// 名前の検索で足りなかった実例が出てから足すこと（16.9節に載せる種類の宿題）。
    ///
    /// ## リンクは辿らない
    ///
    /// `.symbolicLink` の中へは入らない。**外を指すリンクは封じ込めが落とすが、
    /// 内側を指すリンクは環（ループ）を作れる。** 落とされないものでも、
    /// 同じ場所を何度も一覧すれば時間と件数を食う。
    /// 一覧には**リンクとして出る**ので、モデルは実体のパスを自分で指定できる。
    private static func search(
        _ query: String,
        from requested: String,
        accessed: AccessedFolder,
        call: ToolCallRequest,
        limits: Limits,
        budget: ContextBudget,
        counter: TokenCounter
    ) throws -> ToolResult {

        let origin = try accessed.resolve(requested)

        var matches: [DirectoryEntry] = []
        var frontier: [(path: ContainedPath, depth: Int)] = [(origin, 0)]
        var visitedDirectories = 0
        var skipped = 0
        var truncated = false
        /// 隠しファイルとして**探索の対象にすらならなかった**件数（一覧と同じ区別）。
        var hiddenSkipped = 0

        search: while !frontier.isEmpty {
            guard matches.count < limits.searchMatchLimit,
                  visitedDirectories < limits.searchDirectoryLimit
            else {
                truncated = true
                break
            }
            let current = frontier.removeFirst()
            visitedDirectories += 1

            let listing: DirectoryListing
            do {
                listing = try FolderReader.list(
                    current.path, limit: limits.entryLimit, includingHidden: limits.includesHidden)
            } catch {
                // **起点の失敗だけは投げる。** モデルが指定した場所そのものが読めないなら、
                // それは 16.8節の「見つからない／フォルダではない」であって、返答が変わる。
                // 途中のフォルダが読めないのは探索の途中経過なので、**数えて先へ進む。**
                if visitedDirectories == 1 { throw error }
                skipped += 1
                continue
            }
            // **`isTruncated` をそのまま使わないこと。**
            // あれは「見せていないものがあるか」で、**隠しファイル1件でも真になる**
            // （`DirectoryListing` の型コメント）。`.DS_Store` はどこにでもあるので、
            // 使うと**どんな検索でも毎回「打ち切った」と言う**ことになり、
            // 本当に打ち切ったときの警告が意味を失う。
            // ここで見たいのは**件数上限で落ちたか**だけである。
            hiddenSkipped += listing.omittedHiddenCount
            if listing.entries.count + listing.omittedHiddenCount < listing.totalCount {
                truncated = true
            }

            for item in listing.entries {
                // 大文字小文字・全角半角・濁点の揺れを吸収する。
                // **封じ込めの比較（厳密）とは別物である** ── あちらは安全、こちらは使い勝手。
                if item.name.localizedStandardContains(query) {
                    matches.append(item)
                    if matches.count >= limits.searchMatchLimit {
                        truncated = true
                        break search
                    }
                }
                guard item.kind == .directory, current.depth < limits.searchDepthLimit else {
                    continue
                }
                // **子も必ず封じ込めを通す。** 一覧が返した相対パスだからといって
                // 検証を省かない（省いた瞬間、`FolderReader` の出力が信用の起点になる）。
                if let child = try? accessed.resolve(item.relativePath) {
                    frontier.append((child, current.depth + 1))
                } else {
                    skipped += 1
                }
            }
        }
        if !frontier.isEmpty { truncated = true }

        let safeQuery = ToolText.singleLine(query, limit: 40)
        let where_ = display(of: origin)
        let found = matches.count
        let rendered = matches.map { entry(for: $0, showingFullPath: true, withDate: false) }

        let outcome = fitted(
            lines: rendered.isEmpty ? ["（一致するものはありません）"] : rendered,
            budget: budget,
            counter: counter,
            label: { shown in
                var text = "検索「\(safeQuery)」起点 \(where_) / "
                if found == 0 {
                    text += "0件"
                } else {
                    text += shown == found ? "\(found)件" : "\(found)件のうち \(shown)件"
                }
                // **打ち切ったことを黙らない。** 黙ると「このフォルダには無い」と断定される。
                // ただし**打ち切りと、方針で対象外にしたものは別の文で言う**（`listingLabel` と同じ理由）
                // ── 前者は範囲を絞れば届き、後者はどう呼んでも届かない。
                if truncated { text += "（探索を打ち切ったので、これで全部とは限りません）" }
                if skipped > 0 { text += "（読めなかったフォルダ \(skipped)件を飛ばしました）" }
                if hiddenSkipped > 0 {
                    text += "（隠し \(hiddenSkipped)件は探索の対象外。取得できません）"
                }
                return text
            })

        return .content(outcome, tool: call.name, isListing: true)
    }

    // MARK: - 一覧・検索を文脈へ入る形にする

    /// 一覧の結果を `ReadOutcome` に載せる。
    ///
    /// ## なぜ一覧まで `ReadOutcome` なのか
    ///
    /// 16.3節の縮約は**二段**である。第1段（上限で切る）だけでなく、
    /// **第2段（往復が終わったら生の戻り値を送信列から落とす）が要る。**
    /// 落とす仕組みは `ContextTranscript` にあり、入口は**どちらも `ReadOutcome` から出ている** ──
    /// ターンをまたぐ側が `ContextEntry.read(ReadOutcome)`、
    /// 往復の最中（`MLXEngine` の周回）が `ToolResult.bookmarkLine`（＝ `ReadOutcome.bookmarkLine`）である。
    /// **一覧を別の型で返すと、栞が作れない ＝ 一覧だけが落ちずに残り続ける。**
    /// 200件の一覧が毎ターン残るのは、まさに Open WebUI の形である（16.2節）。
    ///
    /// ## 上限の測り方は `ContextWindow` と同じ規律にしてある
    ///
    /// **入れる文字列そのものを組んで測り、収まるまで件数を減らす。**
    /// 「見出しはだいたい何トークン」と見積もって足すやり方にはしていない ──
    /// 見積もりと実物がずれた瞬間、「上限に収めた」という約束が静かに破れる
    /// （`ReadOutcome.contextText` の型コメント）。
    ///
    /// > **【既知の粗さ】見出しの語が「ファイル」になる。**
    /// > `ReadOutcome.headerLine` は `[ファイル …]` と書く。一覧・検索では
    /// > フォルダや検索結果なので語が合わない（**行数・バイト数は
    /// > 「組み上げた一覧の行数・バイト数」なので嘘ではない**）。
    /// > 直すには `ReadOutcome` に種別を持たせる必要があり、それは `Sources/Context/` の仕事。申し送り。
    private static func fitted(
        lines: [String],
        budget: ContextBudget,
        counter: TokenCounter,
        label: (Int) -> String
    ) -> ReadOutcome {

        func outcome(showing count: Int) -> ReadOutcome {
            let shown = lines.prefix(count)
            let body = shown.joined(separator: "\n")
            var result = ReadOutcome(
                path: label(count),
                totalLines: shown.count,
                totalBytes: body.utf8.count,
                firstLine: shown.isEmpty ? nil : 1,
                lastLine: shown.isEmpty ? nil : shown.count,
                partialLine: nil,
                body: body,
                // 何件表示したかは見出し（`label`）が持つ。行の側は
                // 「組み上げた分は全部入っている」ので `.none`。
                // 1件も入らなかったときだけ「入らなかった」と言う。
                reason: shown.isEmpty ? .budgetTooSmall : .none,
                tokenBudget: budget.tokens,
                contextTokens: 0,
                tokensAreEstimated: counter.isEstimate,
                includesInjectionGuard: budget.includesInjectionGuard)
            result.contextTokens = counter(result.contextText)
            return result
        }

        func fits(_ count: Int) -> Bool {
            outcome(showing: count).contextTokens <= budget.tokens
        }

        guard !lines.isEmpty else { return outcome(showing: 0) }
        if fits(lines.count) { return outcome(showing: lines.count) }

        // 件数を増やせば必ず大きくなる（1行は必ず1文字以上）。挟み込みでよい。
        var low = 0
        var high = lines.count
        while low + 1 < high {
            let middle = low + (high - low) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        // 見出しの数字の桁が変わると単調性が1トークンだけ崩れうる。**実物で確かめる。**
        while low > 0, !fits(low) { low -= 1 }
        return outcome(showing: low)
    }

    // MARK: - 1行にする

    /// 一覧の1行。**名前は必ず1行に潰す**（`ToolText.singleLine`）。
    ///
    /// macOS のファイル名には改行を入れられる。潰さないと
    /// **1件が複数行に化けて、`--- ここまで ---` を騙れる**（`ToolResult` の型コメント）。
    /// ついでに行数の申告（`totalLines`）と実際の行数も食い違わなくなる。
    private static func entry(
        for item: DirectoryEntry, showingFullPath: Bool, withDate: Bool
    ) -> String {
        var parts: [String] = [kindLabel(item.kind)]
        var name = showingFullPath ? item.relativePath : item.name
        // 末尾の `/` は飾りではない。**次の呼び出しでパスを組み立てるのはモデルである。**
        if item.kind == .directory { name += "/" }
        parts.append(ToolText.singleLine(name, limit: ToolText.nameLimit))
        if let size = item.byteSize { parts.append("\(size)B") }
        if withDate, let date = item.modifiedAt { parts.append(timestamp(date)) }
        return parts.joined(separator: " ")
    }

    /// 種別。**リンクはリンクとして出す**（`DirectoryEntry.Kind` の型コメント）。
    private static func kindLabel(_ kind: DirectoryEntry.Kind) -> String {
        switch kind {
        case .file: "file"
        case .directory: "dir"
        case .symbolicLink: "link"
        case .other: "other"
        }
    }

    /// `2026-08-18 10:12`。**`DateFormatter` を使わない** ──
    /// あれは `Sendable` ではないので `static let` に置けず、毎回作ると一覧1件ごとに費用がかかる。
    /// ここで欲しいのは並び替えでも地域化でもなく、**モデルが読める固定の綴り**である。
    private static func timestamp(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func pad(_ value: Int?) -> String {
            let number = value ?? 0
            return number < 10 ? "0\(number)" : "\(number)"
        }
        return "\(parts.year ?? 0)-\(pad(parts.month))-\(pad(parts.day))"
            + " \(pad(parts.hour)):\(pad(parts.minute))"
    }

    /// 見出しに出す場所の名前。根そのものは `.`。
    ///
    /// **ディスク上の名前も他所から来た文字列である**（もらったフォルダ、展開したアーカイブ）。
    /// 見出しは囲いの**外**に出るので、ここも1行に潰す。
    private static func display(of path: ContainedPath) -> String {
        path.isRoot ? "." : ToolText.singleLine(path.relativePath, limit: ToolText.nameLimit)
    }
}
