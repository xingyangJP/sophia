import Foundation

/// 送信列を組むための1項目。**発言か、読み取りの結果か。**
///
/// ## なぜ `SophiaMessage` の配列そのままではないのか
///
/// 読み取りの結果は、**そのターンでは中身のまま送り、次のターンからは栞1行に変わる。**
/// 同じ項目が2つの姿を持つので、既に文字列になってしまった `SophiaMessage` では表せない。
/// `ReadOutcome` を最後まで値として持ったまま運び、
/// **送信列に落とす瞬間に、どちらの姿にするかを決める。**
///
/// ## `MessageRole` に `tool` を足していない
///
/// 現在 `MessageRole` は system / user / assistant の3つで、
/// tool 役を足すかは **DESIGN.md 第16.9節 項目6 の未決事項**である
/// （第8章の `messages.role` の CHECK 制約にも波及するため、この層だけでは決められない）。
///
/// 決まるまでのあいだ、読み取りの結果は `.user` として送信列に入れる。
/// **これは妥協ではなく、Qwen3 のテンプレートの実際の挙動に一致している** ─
/// `role == "tool"` は `<|im_start|>user` の中に `<tool_response>` として展開される（16.1節）。
/// **モデルから見て、ファイルの中身は元から user ターンの中にある。**
/// 16.6節（中身は指示ではない）の前提もこれである。
///
/// tool 役が入ったときに直す場所は `ContextTranscript.engineMessages` の1か所だけになる。
enum ContextEntry: Sendable, Equatable {
    /// 普通の発言。そのまま送る。
    case message(SophiaMessage)
    /// 読み取りの結果。往復が終わったら栞へ落ちる。
    case read(ReadOutcome)
}

/// 送信列を組み直した結果と、その費用。
struct ContextFit: Sendable, Equatable {

    /// エンジンへ渡す列。
    var messages: [SophiaMessage]

    /// `messages` の概算/実測トークン数（`perMessageOverhead` を含む）。
    var tokens: Int

    /// 収めようとした上限。
    var budget: Int

    /// 上限に収めるために、生の読み取り結果を栞へ落とした件数。
    var demotedReads: Int

    var tokensAreEstimated: Bool

    /// 収まったか。**false のときは、これ以上この層では減らせない** ─
    /// 呼び出し側が窓を狭めて読み直すしかない（16.3節「送信前に見ること」）。
    var fits: Bool { tokens <= budget }
}

/// **第2段（履歴）: 往復が終わったら、生の戻り値を送信列から落とす**（DESIGN.md 第16.3節）。
///
/// ## 何を落とし、何を落とさないのか
///
/// > 落とすのは**エンジンへ送る列**であって、保存された原ログではない。
/// > VISION の言い方をそのまま借りれば ── **保存は可逆・完全に、文脈は不可逆・意味だけに。**
///
/// **第8.4節（原ログを要約で上書きしない）と矛盾しない。**
/// この層は保存に触らない。触れないように、そもそも入力も出力も値だけにしてある ─
/// `Store` も `ChatViewModel` も見えないので、**原ログを壊す経路が存在しない。**
///
/// ## なぜ純粋な関数なのか
///
/// `engineMessages()` が毎ターン先頭から組み直しているからこの縮約が成立する（16.2節）。
/// KVキャッシュを持ち越していないことが、ここでは利点になっている ──
/// **前置きが変わってもキャッシュを捨てる損が無い。**
/// つまり必要なのは「組み直す関数」だけであって、状態を持つ必要がまったく無い。
enum ContextTranscript {

    /// 生のまま送る読み取りの位置。
    ///
    /// ## 判定の規則: **その読み取りより後に assistant の発言があるか**
    ///
    /// > `<tool_response>` が必要なのは**その往復のあいだだけ**である。
    /// > 答えが出たあとは、**モデル自身が書いた答え**が履歴に残っていれば足りる。（16.3節）
    ///
    /// 「往復が終わった」をターン番号や状態フラグで表さず、
    /// **列そのものの形（後ろに assistant の発言があるか）から読み取っている。**
    /// 状態を別に持つと、必ずどこかで実際の列とずれる ─
    /// そしてずれた側に倒れると、**生の戻り値を毎ターン送り続ける**という
    /// 一番払いたくない失敗になる（Open WebUI が 4,550トークンを毎ターン注入していた形。16.2節）。
    static func rawReadIndices(in entries: [ContextEntry]) -> Set<Int> {
        let lastAssistant = entries.lastIndex { entry in
            if case .message(let message) = entry { return message.role == .assistant }
            return false
        }
        var indices: Set<Int> = []
        for (index, entry) in entries.enumerated() {
            guard case .read = entry else { continue }
            if let lastAssistant, index < lastAssistant { continue }
            indices.insert(index)
        }
        return indices
    }

    /// 既定の規則で送信列を組む。
    static func engineMessages(from entries: [ContextEntry]) -> [SophiaMessage] {
        engineMessages(from: entries, keepingRaw: rawReadIndices(in: entries))
    }

    /// 生のまま残す位置を明示して送信列を組む。
    ///
    /// `keepingRaw` を外から渡せるのは `fit(_:budget:counter:perMessageOverhead:)` のためで、
    /// **上限に収まらないときは、古い読み取りから順に栞へ落として作り直す。**
    static func engineMessages(
        from entries: [ContextEntry],
        keepingRaw rawReads: Set<Int>
    ) -> [SophiaMessage] {

        var messages: [SophiaMessage] = []
        var pending: [String] = []
        var pendingIsRaw = false

        // 連続する読み取りは1つの発言にまとめる。
        // 分けると、チャットテンプレートの `<|im_start|>user ... <|im_end|>` を
        // **件数ぶん払う**ことになる。中身は変わらないのに費用だけ増える。
        func flush() {
            guard !pending.isEmpty else { return }
            messages.append(.user(pending.joined(separator: pendingIsRaw ? "\n\n" : "\n")))
            pending.removeAll()
        }

        for (index, entry) in entries.enumerated() {
            switch entry {
            case .message(let message):
                flush()
                messages.append(message)
            case .read(let outcome):
                let isRaw = rawReads.contains(index)
                if !pending.isEmpty, isRaw != pendingIsRaw { flush() }
                pendingIsRaw = isRaw
                pending.append(isRaw ? outcome.contextText : outcome.bookmarkLine)
            }
        }
        flush()
        return messages
    }

    /// 送信直前に量を見て、上限に収まるところまで落とす（DESIGN.md 第16.3節「送信前に見ること」）。
    ///
    /// ## 落とす順番は「古いものから」
    ///
    /// 一番新しい生の読み取りは、**いままさに答えさせようとしている往復の材料**である。
    /// これを落とすと、モデルは中身を見ないまま答えることになる。
    /// 古いものは既に一度答えが出ており、その答えが履歴に残っている（16.3節）。
    /// **失って害が小さいほうから落とす。**
    ///
    /// ## 収まらなかったときに「入力を短くしてください」と言わないこと
    ///
    /// > 発見19 ③ が指摘した「入力を短くしてください」は、この経路では出してはいけない。
    /// > 短いのは利用者が打った一文で、長いのはアプリが入れたファイルの中身である。
    /// > **利用者に実行不可能な助言を返すことになる。**（16.3節）
    ///
    /// だから `fits == false` を**エラーにしていない。** 事実として返すだけである。
    /// ここから先（窓を狭めて読み直す）はファイルを開ける層の仕事で、この層にはできない。
    ///
    /// - Parameters:
    ///   - perMessageOverhead: 1発言あたりの、チャットテンプレートの固定分。
    ///     **既定 0 は「まだ測っていない」という意味である。**
    ///     `<|im_start|>user\n` … `<|im_end|>\n` のぶんが実際には毎回かかる。
    ///     `lmInput.text.tokens.count` を発言数を変えて2回取れば差から出せる（16.2節の測り方）。
    ///     **測ったらここへ入れること。** 入れるまで、この関数の数字は必ず過少である。
    static func fit(
        _ entries: [ContextEntry],
        budget: Int,
        counter: TokenCounter = .estimate,
        perMessageOverhead: Int = 0
    ) -> ContextFit {

        var rawReads = rawReadIndices(in: entries)
        var demoted = 0

        while true {
            let messages = engineMessages(from: entries, keepingRaw: rawReads)
            let tokens = messages.reduce(0) { $0 + counter($1.content) + perMessageOverhead }

            // 収まった、あるいはもう落とせるものが無い。
            // **落とせるものが無い状態を「収まった」と偽らない。**
            if tokens <= budget || rawReads.isEmpty {
                return ContextFit(
                    messages: messages,
                    tokens: tokens,
                    budget: budget,
                    demotedReads: demoted,
                    tokensAreEstimated: counter.isEstimate
                )
            }

            guard let oldest = rawReads.min() else { break }
            rawReads.remove(oldest)
            demoted += 1
        }

        // `rawReads.min()` が nil になるのは `rawReads.isEmpty` のときだけで、
        // それは上の分岐で既に返している。到達しないが、型のために書いてある。
        let messages = engineMessages(from: entries, keepingRaw: [])
        return ContextFit(
            messages: messages,
            tokens: messages.reduce(0) { $0 + counter($1.content) + perMessageOverhead },
            budget: budget,
            demotedReads: demoted,
            tokensAreEstimated: counter.isEstimate
        )
    }
}

// =============================================================================
//  同じ第2段を、**1つのターンの中**で効かせる（FR-19 / DESIGN.md 第16.3節・第16.8節）
// -----------------------------------------------------------------------------
//  # なぜ `fit(_:budget:…)` をそのまま呼べないのか
//
//  上の `fit` は**ターンとターンのあいだ**の縮約である。入口は `ContextEntry.read`
//  ＝ `ReadOutcome` を値として持っている層（`ChatViewModel`）からしか作れない。
//
//  ところが**費用が実際に積み上がるのは1つのターンの中**である ──
//  `FolderToolRunner.callLimit` は 6、1回の読み取りは `InputBudget.singleRead`（360）まで。
//  **6回で 2,160トークンが、入力予算 1,000 の中に積み上がる。**
//  しかも往復のたびに全部プリフィルし直す（KV再利用なし）。
//  つまり**積み上がった生の戻り値を、周回のたびに払い直している。**
//
//  その積み上がりが起きる場所（`MLXEngine.performChat` の `rounds:` ループ）には
//  `ReadOutcome` が無い。あるのは実行役が返した2つの文字列
//  （`ToolExecutionOutcome.responseText` と `.summaryLine`）だけである ──
//  推論層に `ReadOutcome` を持ち込まないのは NFR-09 の決定であって、迂回ではない
//  （`ToolExecutionOutcome` の型コメント）。
//
//  # だから規則ではなく入口を増やしてある
//
//  | | `fit(_ entries:)` | `fitRoundTrip(_ items:)` |
//  |---|---|---|
//  | いつ | ターンをまたぐとき | **1つのターンの中（往復の最中）** |
//  | 生のまま始める範囲 | 最後の assistant より後だけ | **全部**（往復はまだ終わっていない） |
//  | 落とす順 | 古いものから | 古いものから（**同じ**） |
//  | 落とし切るか | **落とし切る** | **この周ぶんは残す**（1件ではない。下の②） |
//
//  下2行が違う理由は同じ1つである ── **往復の最中は、まだ答えが出ていない。**
//  ターンをまたぐ側では「モデル自身が書いた答えが履歴に残っている」ことが
//  生の戻り値を落としてよい根拠だが（16.3節）、ループの中にはその答えがまだ無い。
//  各周の assistant 発言は**ツールの呼び出し**であって答えではないので、
//  「後ろに assistant があるか」では往復の終わりを判定できない。
//
//  # 2026-08-19: 検証役が破って見せた2つを直した（`AdversarialCompactionTests`）
//
//  | | 何が壊れていたか | どこで直したか |
//  |---|---|---|
//  | ① | **落として費用が増える経路があった。** 空のファイルの読み取りは、生（概算19）より栞＋断り書き（同24）のほうが高い。誰も「落として得になるか」を見ていなかったので、`demotedReads` が「2件落とした」と申告しながら合計が増えた | `RoundTripItem.demotable(raw:bookmark:counter:)` と `fitRoundTrip` の**2か所**。落として高くなる項目は候補から外れる |
//  | ② | **同じ周で呼ばれた戻り値が、モデルに一度も見られないまま落ちた。** 守っていたのは `demotable.last` の**1件**だけで、1周に3つ呼ばれた周では残り2件が次の周の頭で栞になった（往復の回数は消費済みなので読み直せない） | 守る単位を**周**にした（`RoundTripItem.startsRound` / `currentRoundIndices`） |
// =============================================================================

extension ContextTranscript {

    /// 落とした読み取りの跡に、栞のあとへ添える1行。
    ///
    /// ## なぜ栞だけでは足りないのか
    ///
    /// 第1段（`ReadOutcome.clipNotice`）が既に同じ判断をしている ──
    ///
    /// > 見出しには既に `1-80行` と範囲が出ているので、読めば一部だと分かる ──
    /// > **分かるはずだ、では足りない。** 範囲の表記は数字であって主張ではない。
    ///
    /// 第2段でも事情は同じである。栞は `<tool_response>` の中に入るので、
    /// **モデルから見れば「read_file がこれだけ返してきた」ようにしか見えない。**
    /// 中身が「無かった」のか「取り下げた」のかを、数字ではなく文として書く。
    ///
    /// **【承知の上の費用】この1行は配分表の外にある。**
    /// 概算で12トークン、`FolderToolRunner.callLimit`（6）ぶんで 72。
    /// `InputBudget.bookmarks`（180）は栞だけを見て置かれた枠であり、
    /// 一覧の栞（28）＋この1行 ＝ 40 × 6 ＝ 240 で**超える。**
    /// 枠は `Shared/ChatOptions.swift` にあり、超過の事実は申し送りにしてある
    /// （同じ枠は「件数上限で切れた一覧の栞は 51、6件で 306」という穴を既に抱えている）。
    ///
    /// > **この12トークンは、栞そのもの（概算13）とほぼ同額である。**
    /// > 断り書きを付けると栞1件の費用が倍になる ── だから
    /// > **中身が小さい読み取りでは、落とすほうが高くつく**（①の正体）。
    /// > 高くつく項目を落とさないのが `RoundTripItem.demotable(raw:bookmark:counter:)` の仕事で、
    /// > **文言を短くすれば落とせる項目が増える**（費用と表明の交換なので、
    /// > 変えるなら 16.3節「切ったら必ず言う」の側の判断が要る）。
    ///
    /// ## ターンをまたぐ側（`engineMessages`）は、いまこの1行を置いていない
    ///
    /// **判断が割れているのは事実で、正しいのは「置く」側である**（2026-08-19 の判定）──
    /// 栞は `<tool_response>` の中に入るので、事情はどちらの段でも同じである。
    /// **ただし、まだ直していない。** 直すと `ContextWindowTests` の3件
    /// （`testOlderReadsBecomeBookmarksOnceTheAnswerExists` /
    ///   `testBookmarkKeepsTheRangeSoThePartialitySurvives` /
    ///   `testConsecutiveReadsAreMergedIntoOneMessage`）が
    /// 「栞1行そのもの」を等値で固定しており、同時に直す必要がある。
    /// **`fit` の呼び手は `Sources/` に1つも無いので、実害は配線した日に出る。**
    /// そのとき①の検査もあちら側に要る（断り書きを足した瞬間、同じ「落とすと高くつく」が生まれる）。
    static let demotionNotice = "（内容は文脈の上限のため省略）"

    /// 往復の最中の送信列の1項目。**2つの姿を持つものと、1つしか持たないものがある。**
    ///
    /// `ContextEntry` と役割は同じで、持ち方だけが違う ──
    /// あちらは `ReadOutcome` を最後まで値で持ち、こちらは**既に文字列になった2つの姿**を持つ。
    /// ループの中に届くのが文字列だけだからで、ここで `ReadOutcome` を要求すると
    /// 推論層が `Sources/Context/` の値型ごと抱えることになる（NFR-09）。
    struct RoundTripItem: Sendable, Equatable {

        /// 生のまま送るときの文字列。
        var rawText: String

        /// 栞へ落としたときの文字列。**nil は「落とせない」という意味である。**
        ///
        /// > **`rawText` と同じ文字列が入っていることがある。**
        /// > 落とした姿のほうが高くつく項目（空のファイルの読み取りなど）では、
        /// > `demotable(raw:bookmark:counter:)` が**生の姿へ潰してある** ──
        /// > 落としても1トークンも減らないが、**増えることも絶対に無い。**
        /// > `demotedText == rawText` は「落とす価値が無い」の表現である。
        var demotedText: String?

        var isDemotable: Bool { demotedText != nil }

        /// **この項目から新しい周が始まる**（＝モデルが `<tool_call>` を書いた発言である）。
        ///
        /// ## なぜ周の境目を項目が持つのか（②）
        ///
        /// `fitRoundTrip` が守るのは「**モデルがまだ一度も見ていない戻り値**」である。
        /// 見ていないものは「一番新しい1件」ではなく、**この周に実行したぶん全部**である ──
        /// `performChat` は1周の `assistant` 発言に `tool_calls` を何個でも載せ、
        /// その後ろに戻り値を並べる（`for call in calls { transcript.append(…) }`）。
        /// 1周で3つ頼まれた周に1件しか守らないと、**残り2件は次の周の頭で栞になり、
        /// モデルは中身を一度も見ないまま答える。** 往復の回数（`callLimit` = 6）は
        /// 呼んだ時点で消費済みなので、**読み直すこともできない。**
        ///
        /// **引数で渡さずに項目へ持たせたのは、出荷経路が必ず埋めるようにするためである。**
        /// 「渡さなければ既定の規則になる」引数にすると、
        /// **出荷経路が一度も使わない引数**（`perMessageOverhead` が実際にそうなっていた）が
        /// もう1つ増える。ここは `MLXEngine.compacted` が `.assistant` を写す時点で必ず決まる。
        ///
        /// 目印が1つも無い列（規則そのものを試す試験など）では、
        /// **従来どおり「一番新しい1件」だけを守る**（`currentRoundIndices`）。
        var startsRound: Bool = false

        /// 落とせない項目 ── 利用者の発言・アシスタントの発言・失敗の文。
        ///
        /// **失敗の文を落とさないのは 16.8節のためである。**
        /// あれは1行しかなく、しかも「そのパスは無い」を忘れたモデルは
        /// 次の周で同じパスをまた書く（`ToolResult.contextEntry` と同じ判断）。
        static func fixed(_ text: String, startsRound: Bool = false) -> Self {
            RoundTripItem(rawText: text, demotedText: nil, startsRound: startsRound)
        }

        /// 落とせる項目（読み取り・一覧の結果）。
        ///
        /// **断り書き（`demotionNotice`）はここで足す。**
        /// 呼び出し側に足させると、足し忘れた経路が「黙って中身を消す」実装になる ──
        /// `ToolResult` が `contextText` を自前で組ませないのと同じ規律である。
        ///
        /// ## **落として安くならないなら、落とした姿は生のままである**（①）
        ///
        /// 縮約の目的は費用を下げることである。ところが 2026-08-19 まで、
        /// ここは**無条件に2つ目の姿を作っていた。** 空のファイルの読み取りで逆転する ──
        ///
        /// | | 文字列 | 概算 |
        /// |---|---|--:|
        /// | 生 | `[ファイル x.md / 空のファイル（0行 / 0バイト）]` | **19** |
        /// | 栞＋断り書き | `読んだ: x.md（空のファイル）` ＋ 断り書き | **24** |
        ///
        /// 差はパスの長さによらない（パスは両方に1度ずつ出る）。空のファイルは珍しくない ──
        /// `touch` したもの、置いただけの `__init__.py`、書き出す前のログ。
        /// **モデルは中身が空だと知るために一度読む。**
        ///
        /// 高いほうを2つ目の姿として持たせると、`fitRoundTrip` が
        /// **「2件落とした」と申告しながら合計を増やす** ──
        /// 「落とした」と言いながら高くなるのは、静かに嘘をつく形の一種である。
        ///
        /// **同値でも生を残す。** 同じ費用なら、中身がある側のほうが役に立つ。
        ///
        /// - Parameter counter: **費用の見方。既定は概算。**
        ///   `fitRoundTrip` へ渡すものと**同じ数え方を渡すこと** ──
        ///   別の数え方で作ると、「得になる」と判断した数え方と
        ///   予算を測る数え方が食い違う（`fitRoundTrip` 側にも同じ検査を置いてある）。
        static func demotable(
            raw: String, bookmark: String, counter: TokenCounter = .estimate
        ) -> Self {
            let demoted = bookmark + "\n" + ContextTranscript.demotionNotice
            return RoundTripItem(
                rawText: raw,
                demotedText: counter(demoted) < counter(raw) ? demoted : raw)
        }
    }

    /// 往復の最中に組み直した結果と、その費用。
    ///
    /// **`texts` を返しているのが要点である。** 落とす位置（`demotedIndices`）だけを返すと、
    /// 呼び出し側が文字列を組み直すことになり、**測った文字列と送る文字列が別物になる。**
    /// この食い違いは、`ReadOutcome.contextText` が型コメントで名指しして禁じているものと同じ形。
    struct RoundTripFit: Sendable, Equatable {

        /// 各項目の、**この周に実際に送る姿**。`items` と同じ並び・同じ数。
        var texts: [String]

        /// 栞へ落とした位置。
        var demotedIndices: Set<Int>

        /// `texts` の概算/実測トークン数（`perMessageOverhead` を含む）。
        var tokens: Int

        var budget: Int

        var tokensAreEstimated: Bool

        /// 落とした件数。上の `ContextFit.demotedReads` と同じ語を使ってある。
        ///
        /// > **件数は「安くなった件数」ではない。**
        /// > 落とした姿が生と同じ項目（`RoundTripItem.demotedText` の但し書き）を
        /// > 落とすと、ここは1つ増えるのに `tokens` は1つも動かない。
        /// > **増えないことは保証されている**（それが①の修正である）が、
        /// > **減ったかどうかは `tokens` を見ること。** 件数だけを見て成功と読まない。
        var demotedReads: Int { demotedIndices.count }

        /// 収まったか。**false でもエラーにしない**（`fit` と同じ理由。16.3節）。
        /// ここから先（窓を狭めて読み直す）は、この層にはできない。
        ///
        /// > **落とし切っても false になる周が実在する**（③）──
        /// > 実ファイルを6件読んだターンは概算 597 で、送信列の取り分は 573 である。
        /// > **この層はこれ以上減らせない。** 超過は `contextLength`（8,192）まで素通りする。
        var fits: Bool { tokens <= budget }
    }

    /// 往復の1周ぶんを、上限に収まるところまで落とす（DESIGN.md 第16.3節 第2段）。
    ///
    /// ## **この周ぶんは落とさない**（1件ではない。②）
    ///
    /// `fit` は落とせるものを**落とし切る**（収まるまで、最後の1件も含めて）。
    /// こちらは残す。**いま読んだばかりの中身を落とすと、モデルは中身を見ないまま答える** ──
    /// それは「読みに行った」という往復そのものを無意味にする。
    ///
    /// 守る範囲は**この周に実行したぶん全部**である（`RoundTripItem.startsRound` の但し書き）。
    /// 1周に3つ頼まれることは普通にあり、そのとき守るのが1件だけだと
    /// **残り2件はモデルが一度も見ないまま栞になる。**
    /// 前の周までの戻り値は違う ── **あれは既に一度プロンプトに載り、
    /// モデルはそれを見たうえで次の呼び出しを書いた。**
    ///
    /// ## **落として高くなるなら落とさない**（①）
    ///
    /// 縮約の目的は費用を下げることであって、件数を減らすことではない。
    /// 落とした姿のほうが高い項目（空のファイルの読み取りなど）を落とすと、
    /// **「落とした」と言いながら合計が増える。** 候補に入れる前に見る。
    ///
    /// > **`RoundTripItem.demotable(raw:bookmark:counter:)` にも同じ検査がある。**
    /// > 二重に見えるが役割が違う ── あちらは**作るとき**の数え方で潰し、
    /// > ここは**測るときの数え方**で見る。2つが違う数え方で呼ばれたときに、
    /// > 費用が増えないことを最後に保証しているのはこちらである。
    ///
    /// ## 収まらなかったとき（③）
    ///
    /// > 落とし切らないので、**この関数だけでは予算を守り切れないことがある。**
    /// > 守り切れなかったことは `fits` に出る。**「落とせるものが無い」を「収まった」と偽らない。**
    ///
    /// **超過を握り潰さず、エラーにもしない。** ここから先にできる手は2つとも
    /// この層の外にある ── (1) 次の読み取りの窓を狭める（16.3節 第1段・道具の層）、
    /// (2) 配分表を見直す（`SophiaDefaults.InputBudget`）。
    /// **この層で「この周ぶんも落とす」に倒すと、②で直したばかりの欠陥が戻る。**
    ///
    /// - Parameters:
    ///   - perMessageOverhead: 1発言あたりのチャットテンプレートの固定分。
    ///     **既定 0 は「まだ測っていない」という意味である**（`fit` と同じ）。
    ///     さらにここでは `tool_calls` の JSON も数えていない ── どちらも**過少**に出る。
    static func fitRoundTrip(
        _ items: [RoundTripItem],
        budget: Int,
        counter: TokenCounter = .estimate,
        perMessageOverhead: Int = 0
    ) -> RoundTripFit {

        // 落とせる位置を、**古い順**に並べたもの。
        // **「落として高くならない」ものだけが候補である**（①）。
        let demotable = items.indices.filter { index in
            guard let demoted = items[index].demotedText else { return false }
            return counter(demoted) <= counter(items[index].rawText)
        }

        // **この周の材料**（＝モデルがまだ一度も見ていない戻り値）。落とさない（②）。
        let currentRound = currentRoundIndices(in: items, demotable: demotable)

        var demoted: Set<Int> = []

        while true {
            let texts = items.indices.map { index -> String in
                guard demoted.contains(index), let text = items[index].demotedText else {
                    return items[index].rawText
                }
                return text
            }
            let tokens = texts.reduce(0) { $0 + counter($1) + perMessageOverhead }

            // 収まった、あるいはこれ以上落とせない。
            // **落とせるものが無い状態を「収まった」と偽らない**（`fit` と同じ）。
            guard
                tokens > budget,
                let next = demotable.first(where: {
                    !currentRound.contains($0) && !demoted.contains($0)
                })
            else {
                return RoundTripFit(
                    texts: texts,
                    demotedIndices: demoted,
                    tokens: tokens,
                    budget: budget,
                    tokensAreEstimated: counter.isEstimate
                )
            }

            // 古いものから落とす。**失って害が小さいほうから**（`fit` と同じ順序）。
            demoted.insert(next)
        }
    }

    /// **この周に実行した戻り値の位置**（＝モデルがまだ一度も見ていないもの。②）。
    ///
    /// 周の頭は「ツールを呼んだ assistant の発言」である（`RoundTripItem.startsRound`）。
    /// その後ろに並ぶ落とせる項目が、いま答えさせようとしている材料そのものになる。
    ///
    /// **目印が1つも無い列では、従来どおり「一番新しい1件」だけを守る。**
    /// 規則そのものを試す試験は周を組み立てずに項目だけを並べるので、
    /// ここで空集合を返すと**答えさせる材料まで落ちる**ことになる。
    private static func currentRoundIndices(
        in items: [RoundTripItem], demotable: [Int]
    ) -> Set<Int> {
        guard let start = items.lastIndex(where: { $0.startsRound }) else {
            return Set(demotable.suffix(1))
        }
        return Set(demotable.filter { $0 > start })
    }
}
