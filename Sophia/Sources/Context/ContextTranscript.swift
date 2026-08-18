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
