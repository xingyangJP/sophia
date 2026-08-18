import Darwin
import Foundation

/// **検証を通ったパスだけが持てる型。**（DESIGN.md 第16.5節「封じ込め」）
///
/// ## なぜ `String` や `URL` をそのまま渡さないのか
///
/// 読み取りを行う `FolderReader` は、この型しか受け取らない。
/// そして**この型を作れるのは `FolderContainment` だけ**である（`init` が `fileprivate`）。
///
/// つまり「検証を忘れて読んでしまう」経路が、型のレベルで存在しない。
/// 検証は**規律ではなく構造**で担保する ── 規律は必ずいつか破れる。
///
/// > **この `fileprivate` を internal に開けないこと。**
/// > 開けた瞬間、モデルが書いた文字列から直接この型を作れるようになり、
/// > 16.5節の4手順を丸ごと迂回できる。
///
/// ## ⚠️ この型が保証しているのは「作られた時点で内側だった」ことだけである
///
/// **有効期限を持っていない。** 発行したアクセススコープが閉じても値は生き続け、
/// `FolderReader` はそれを疑わずに読む。**作られた後に途中の成分をリンクへ差し替えると、
/// この値のまま根の外が読める**（`SecurityScopedFolder.withAccess` の ⚠️ に実測がある）。
///
/// 「検証を通った証拠」ではあるが、**「いまも通る証拠」ではない。**
/// 長く持ち回るほど嘘に近づくので、**必要になったら取り直すこと。**
struct ContainedPath: Sendable, Equatable {

    /// **実際に I/O に使う URL。**
    ///
    /// 「解決済みの絶対パス」ではなく、**結び付けた根の URL に、
    /// 解決済みの相対成分を足し直したもの**である。理由は
    /// `FolderContainment.resolve(relativePath:rootURL:canonicalRootPath:)` の
    /// 「なぜ正準パスで I/O しないのか」を読むこと。
    let url: URL

    /// 根からの相対パス。**表示・ログ・モデルへの戻り値はこれを使う。**
    ///
    /// 正準化を通した後の値なので、大文字小文字がディスク上の綴りに揃っている
    /// （macOS の `realpath` の実測挙動。`canonicalPath(of:)` の但し書き）。
    let relativePath: String

    /// 相対パスの成分列。根そのものを指すときは空。
    let components: [String]

    /// 根そのものを指しているか。
    var isRoot: Bool { components.isEmpty }

    fileprivate init(url: URL, relativePath: String, components: [String]) {
        self.url = url
        self.relativePath = relativePath
        self.components = components
    }
}

/// **モデルが書いた相対パスを、許可した根の内側に閉じ込める。**（DESIGN.md 第16.5節）
///
/// ---
///
/// # この型が防いでいるもの
///
/// 16.5節が定めた4手順をそのまま実装している。**各手順が何を防ぐかを消さないこと** ──
/// 「これ要る？」で1手順消えると、下の表の行が1つ穴になる。
///
/// | 手順 | 実装 | これが無いと通ってしまうもの |
/// |---|---|---|
/// | 1 | 相対成分に分解し、**必ず根を前置**して候補を作る | `/etc/passwd`、`~/.ssh/id_rsa` |
/// | 2 | `realpath(3)` で**シンボリックリンクを解決** | `許可した場所/link` → `/etc` |
/// | 3 | 解決後を**成分単位で**比較し、外れていたら実行しない | `/Users/x/docs-secret`（接頭辞一致の罠） |
/// | 4 | **根も解決後の値で保持**する | 根自身がリンクだったときに、手順3が丸ごと空振りする |
///
/// ## `..` を除くだけでは足りない（16.5節の但し書き）
///
/// **文字列として正規化しただけのパスは通ってしまう。**
/// `許可した場所/link` が `/etc` へのシンボリックリンクなら、
/// `link/passwd` に `..` は1つも出てこない。字句の正規化は何も検出しない。
/// **解決してから比較すること。** それが手順2と3である。
///
/// なお本実装は `..` を**手順1の時点でも拒否する**（多層防御）。
/// 手順2・3だけで正しく落ちるので**これは主防御ではない** ──
/// 主防御が壊れたときに気づける層として置いてある。
/// `..` を許すと、モデルの意図が「外へ出たい」なのか「打ち間違い」なのかも区別できない。
///
/// ## 大文字小文字を比較の前提にしない
///
/// macOS の既定のボリュームは case-insensitive だが、**それを前提にしない。**
/// 比較は**厳密（case-sensitive）に行う。** 向きが逆だと穴になるからである ──
///
/// - 厳密に比べる → case-insensitive なボリュームで「同じ場所なのに拒否」が起きうる。**安全側。**
/// - 緩く比べる → case-**sensitive** なボリュームで「別のディレクトリなのに許可」が起きる。**穴。**
///
/// 実測（2026-08-18、この開発機の APFS）では `realpath` が
/// `.../DOCS/NOTES.MD` を `.../docs/notes.md` へ**綴りごと正規化して返した。**
/// つまり case-insensitive なボリュームでは手順2が先に綴りを揃えるので、
/// 厳密比較でも実害のある偽陰性は出ない。**ただしこれに寄りかからないこと** ──
/// 外付けの case-sensitive ボリュームでは正規化は起きず、そのときこそ厳密比較が要る。
enum FolderContainment {

    // MARK: - 手順1: 相対パスの分解

    /// モデルが書いた相対パスを成分列にする。**根の外を指しうる形は、ここで全部落とす。**
    ///
    /// 16.4節が「`path` は結び付いたフォルダからの相対パスとする。**絶対パスを受け取らない**」
    /// と決めている。受け取らないことで、封じ込めの入口が1本に絞れる。
    static func relativeComponents(of rawPath: String) throws -> [String] {
        // NUL を弾く。C の API は NUL でパスを切るので、
        // **Swift 側で見えている文字列と、カーネルが見る文字列が食い違う。**
        // 「`notes.md\0/../../etc`」のような細工を、比較のあとで別物にされないため。
        guard !rawPath.utf8.contains(0) else {
            throw FolderAccessError.invalidPath(rawPath)
        }
        guard !rawPath.hasPrefix("/") else {
            throw FolderAccessError.absolutePathRejected(rawPath)
        }
        // `~` は誰かが展開すればホーム直下になる。ここで展開しないことと、
        // 拒否することは別である ── 展開しないまま根に足すと
        // 「`~` という名前のフォルダ」を探しに行き、失敗の理由が伝わらない。
        guard !rawPath.hasPrefix("~") else {
            throw FolderAccessError.homeRelativePathRejected(rawPath)
        }

        var components: [String] = []
        for piece in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(piece)
            // `.` は無害なので落とすだけ。`//` も `omittingEmptySubsequences` で消える。
            if component == "." { continue }
            // **成分がちょうど `..` のときだけ**落とすこと。
            // 部分文字列で見ると `..` を含む正当な名前（`ver..old.txt`）まで巻き添えになる。
            if component == ".." {
                throw FolderAccessError.parentTraversalRejected(rawPath)
            }
            components.append(component)
        }
        return components
    }

    // MARK: - 手順2: シンボリックリンクの解決

    /// 存在するパスを正準化する。`realpath(3)` そのもの。
    ///
    /// ## なぜ `URL.resolvingSymlinksInPath()` を使わないのか
    ///
    /// 16.5節は `resolvingSymlinksInPath()` を挙げているが、**この用途には向かない。**
    /// Apple の文書がこう明記している ──
    /// 「パスが `/private` で始まる場合、**結果が実在するファイルであれば**
    /// `/private` を取り除く」。
    ///
    /// **「実在すれば」という条件が付いているのが致命的である。**
    /// 根と候補で正準化の結果が食い違いうる（片方だけ `/private` が落ちる）。
    /// 手順3は**同じ土俵に載った2つのパスを比べる**ことで成立しているので、
    /// 土俵がずれると比較そのものが無意味になる。
    ///
    /// `realpath(3)` にはこの分岐が無い。実測（2026-08-18、この開発機）でも
    /// `/tmp` → `/private/tmp`、`/etc` → `/private/etc` と**常に**解決側へ倒れた。
    /// **根にも候補にも同じ規則が効く**ので、比較が成立する。
    /// 同じ実測で、case-insensitive なボリュームでは
    /// `.../DOCS/NOTES.MD` を `.../docs/notes.md` へ**綴りごと正規化**して返すことも確認した。
    ///
    /// - Returns: 解決できた絶対パスと、失敗したときの errno。
    ///   **失敗の理由を捨てないこと。** 呼び手はそれで分岐する（`canonicalPath` の但し書き）。
    private static func resolveExistingPath(_ path: String) -> (resolved: String?, failure: Int32) {
        guard !path.isEmpty else { return (nil, ENOENT) }
        // `withUnsafeFileSystemRepresentation` を通すこと。
        // String をそのまま C 文字列にすると、日本語ファイル名の正規化形（NFC/NFD）が
        // ファイルシステムの期待と食い違いうる。変換は Foundation に任せる。
        var resolvedPath: String?
        var failure: Int32 = 0
        URL(fileURLWithPath: path).withUnsafeFileSystemRepresentation { representation in
            guard let representation else {
                failure = EINVAL
                return
            }
            // 第2引数に nil を渡すと realpath 側が malloc する（PATH_MAX の決め打ちを避ける）。
            guard let resolved = realpath(representation, nil) else {
                failure = errno
                return
            }
            defer { free(resolved) }
            resolvedPath = String(cString: resolved)
        }
        return (resolvedPath, failure)
    }

    /// **存在しない末尾を許す**正準化。
    ///
    /// `realpath` は成分が1つでも欠けると ENOENT で失敗する（実測確認済み）。
    /// しかしモデルは実在しないパスを平気で書いてくる。そこで
    ///
    /// 1. **実在する最深の祖先**まで遡って `realpath` に掛け、
    /// 2. 残りの成分を字句的に足す。
    ///
    /// **これが安全なのは「実在しない成分はシンボリックリンクでもありえない」からである。**
    /// リンクは実体であり、無いものは何も指さない。つまり字句的に足した部分に
    /// 手順2の取りこぼしは生じない。実在する部分は全部カーネルが解決している ──
    /// **祖先の側にリンクがあれば、そこで解決されて外へ出る**ので、手順3が捕まえる。
    ///
    /// これをやらないと「存在しないファイル」が全部
    /// 「ルートの外」として報告され、**16.8節の「見つからない」と
    /// 「外を指した」の区別が消える**（モデルへの返答も利用者への文言も変わる）。
    ///
    /// ## ⚠️ 遡ってよいのは ENOENT / ENOTDIR のときだけである
    ///
    /// **ここを緩めると封じ込めに穴が開く。** 例で示す ──
    /// 根の中に `to-etc -> /etc` があり、`to-etc/hosts` を要求されたとする。
    /// 正しくは `realpath` が `/private/etc/hosts` を返し、手順3が落とす。
    ///
    /// ところが `/etc` を辿れない状況（サンドボックスの拒否 = EACCES）だと `realpath` は失敗する。
    /// **失敗の理由を見ずに祖先へ遡ると**、根まで戻って
    /// 「`<根>/to-etc/hosts`」という**根の内側に見える文字列**を組み立ててしまう。
    /// 手順3は素通りする。**「解決できなかった」が「解決した結果ここにある」に化ける。**
    ///
    /// ENOENT（無い）と ENOTDIR（途中がディレクトリでない）は
    /// 「そのパスは実在しえない」という**事実の報告**なので遡ってよい。
    /// それ以外は「**確かめられなかった**」であり、**確かめられないものは通さない。**
    ///
    /// - Parameter displayPath: エラーに載せるパス。**絶対パスをモデルへ返さない**ため、
    ///   呼び手が持っている相対パスを渡す（16.6節 約束1）。
    static func canonicalPath(of path: String, reportedAs displayPath: String) throws -> String {
        let direct = resolveExistingPath(path)
        if let resolved = direct.resolved { return resolved }
        guard isAbsence(direct.failure) else {
            throw resolutionFailure(direct.failure, path: displayPath)
        }

        var components = absoluteComponents(of: path)
        var missing: [String] = []
        while let last = components.popLast() {
            missing.insert(last, at: 0)
            // 成分が尽きたら "/" になる。"/" は必ず存在するのでループは必ず終わる。
            let parentPath = "/" + components.joined(separator: "/")
            let attempt = resolveExistingPath(parentPath)
            if let resolvedParent = attempt.resolved {
                return joined(resolvedParent, missing)
            }
            guard isAbsence(attempt.failure) else {
                throw resolutionFailure(attempt.failure, path: displayPath)
            }
        }
        throw FolderAccessError.notFound(displayPath)
    }

    /// 「そのパスは実在しえない」と言い切れる errno か。
    private static func isAbsence(_ code: Int32) -> Bool {
        code == ENOENT || code == ENOTDIR
    }

    private static func resolutionFailure(_ code: Int32, path: String) -> FolderAccessError {
        switch code {
        case EACCES, EPERM:
            .accessDenied(path)
        case ELOOP:
            // リンクの環（または段数が多すぎる）。**追い切れないものは通さない。**
            //
            // **ここは永続的な失敗である。** `realpath` はパス全体を辿るので、
            // ELOOP は「辿り方が閉じている」という構造の話であり、時間が経っても直らない。
            // 一時的な差し替え（TOCTOU）で ELOOP になるのは
            // `FolderReader` の `open(O_NOFOLLOW)` のほうで、あちらは
            // `.pathChangedDuringAccess` のまま ── **文言が正反対になるので混ぜないこと。**
            .symbolicLinkCycle(path)
        case ENAMETOOLONG, EINVAL:
            .invalidPath(path)
        default:
            .ioFailed(path: path, detail: "realpath errno \(code)")
        }
    }

    /// 根の正準化（**手順4**）。
    ///
    /// 根そのものがシンボリックリンクだった場合に備える。
    /// 利用者が `~/Desktop/仕事` を選び、それが `/Volumes/外付け/仕事` へのリンクだったとき、
    /// **解決前の値で比較すると、手順3は候補（解決済み）と根（未解決）を比べることになり、
    /// ほぼ全部が「外」と判定される。** 逆に候補側だけ未解決にすれば全部通る。
    /// どちらも壊れているので、**根も候補も同じ関数で解決してから比べる。**
    ///
    /// 候補と違い、根は**存在しなければ即失敗**にする（緩い正準化を使わない）。
    /// 存在しない根は 16.8節の「ブックマークが失効した」であって、
    /// 中を読める状態ではない。**ここを緩めると、消えたフォルダの
    /// 「あるはずの場所」を根として動き続ける。**
    static func canonicalRootPath(of url: URL) throws -> String {
        let attempt = resolveExistingPath(url.path)
        guard let resolved = attempt.resolved else {
            if attempt.failure == EACCES || attempt.failure == EPERM {
                throw FolderAccessError.accessDenied(url.path)
            }
            throw FolderAccessError.rootUnavailable(url.path)
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw FolderAccessError.rootNotADirectory(resolved)
        }
        return resolved
    }

    // MARK: - 手順3: 比較

    /// **成分単位で**前置を判定する。`hasPrefix` を使わないこと。
    ///
    /// ## 接頭辞一致の罠
    ///
    /// 根が `/Users/x/docs` のとき、`"/Users/x/docs-secret".hasPrefix("/Users/x/docs")` は
    /// **true になる。** 文字列としては本当に接頭辞だからである。
    /// `/Users/x/docsomething`、`/Users/x/docs.bak` も同様に通る。
    ///
    /// リンク経由で簡単に作れる ── 許可したフォルダの中に
    /// `near -> /Users/x/docs-secret` を置くだけでよい。
    /// 手順2は正しくリンクを解くが、**手順3が文字列比較だと、
    /// 解いた結果がそのまま素通りする。**
    ///
    /// 成分列 `["Users","x","docs-secret"]` と `["Users","x","docs"]` を
    /// 3番目の成分で比べれば `docs-secret != docs` で落ちる。**境界で区切ることが本質である。**
    ///
    /// 末尾に `/` を足して比べる書き方でも同じ結果になるが、
    /// 空文字・重複スラッシュ・根が `/` の場合の扱いが増える。成分で持つほうが誤りにくい。
    static func isContained(_ candidate: [String], within root: [String]) -> Bool {
        // 根そのもの（成分数が同じ）は「内側」として許す。一覧の起点になる。
        guard candidate.count >= root.count else { return false }
        for index in root.indices {
            // **厳密比較。** 大文字小文字を同一視しないこと（型コメントの但し書き）。
            if candidate[index] != root[index] { return false }
        }
        return true
    }

    // MARK: - 4手順をまとめた入口

    /// モデルが書いた相対パスを検証し、**通ったものだけ** `ContainedPath` にして返す。
    ///
    /// **必ずアクセススコープの内側で呼ぶこと**（`SecurityScopedFolder.withAccess`）。
    /// `realpath` はディレクトリの検索権限を要求するので、
    /// スコープの外で呼ぶと ENOENT と区別の付かない失敗になる。
    ///
    /// ## なぜ正準パスで I/O しないのか
    ///
    /// 手順2が返す正準パスは、シンボリックリンクを解いた**別の場所**を指しうる
    /// （`/tmp/...` が `/private/tmp/...` になる、など）。
    /// **サンドボックスの拡張が発行されたのは、利用者が選んだ URL に対してである。**
    /// 正準パスがその表記と食い違ったとき、拡張が効くかどうかを確かめていない。
    ///
    /// そこで最後にもう一度だけ組み替える ──
    /// **正準化した候補から、正準化した根の分を取り除いた「安全な相対成分」を、
    /// 元の根の URL に足し直す。**
    ///
    /// - 相対成分の側は正準化済みなので、**リンクは1つも残っていない**（手順2の成果を失わない）。
    /// - 根の側は利用者が選んだ URL そのものなので、**拡張の範囲から出ない**。
    ///
    /// > **【残る穴 / TOCTOU】検証のあと、成分が差し替えられる余地がある。**
    /// > 完全に塞ぐには `openat(2)` で成分ごとに `O_NOFOLLOW` を積む必要があり、
    /// > 本章の範囲（単一利用者・**読み取りのみ**・ローカル）に対して割に合わない。
    /// > 最後の成分だけは `FolderReader` が `O_NOFOLLOW` で開いて塞いである。
    /// >
    /// > **窓の広さを書き違えないこと【実測 2026-08-18】。**
    /// > 「検証と実際に開く瞬間の間」と書いてあったが、**実際には上限が無い。**
    /// > 戻り値の `ContainedPath` は有効期限を持たない値なので、
    /// > 呼び手が持ち続ければ、アクセススコープを抜けた何分後でも同じ穴が開いている
    /// > （実演: `AdversarialFileAccessTests`
    /// > `testAContainedPathOutlivesTheScopeAndTheRootCheckThatIssuedIt`。
    /// > 途中の成分を根の外へのリンクに差し替えると、根の外の中身が読める）。
    /// > **狭い窓だと思って設計を足さないこと。**
    /// >
    /// > **FR-20（書き込み・コマンド実行）を足すときは、ここを必ず見直すこと。**
    /// > 読み取りなら最悪でも「別のファイルを読む」だが、書き込みは実害になる。
    static func resolve(
        relativePath rawPath: String,
        rootURL: URL,
        canonicalRootPath: String
    ) throws -> ContainedPath {
        // 手順1: 分解して、根を必ず前置する。
        // **モデルが書いた文字列だけからパスが出来る経路は、この関数の中に存在しない。**
        let requested = try relativeComponents(of: rawPath)
        let candidatePath = joined(canonicalRootPath, requested)

        // 手順2: シンボリックリンクを解く。
        // **失敗の理由がどう扱われるかは `canonicalPath` の但し書きを読むこと。**
        // 「確かめられなかった」を「内側にある」に化けさせないのが、あそこの仕事である。
        let canonicalCandidate = try canonicalPath(of: candidatePath, reportedAs: rawPath)

        // 手順3: 成分単位で比較する。
        let rootComponents = absoluteComponents(of: canonicalRootPath)
        let candidateComponents = absoluteComponents(of: canonicalCandidate)
        guard isContained(candidateComponents, within: rootComponents) else {
            throw FolderAccessError.outsideRoot(requested: rawPath, resolved: canonicalCandidate)
        }

        let safeComponents = Array(candidateComponents.dropFirst(rootComponents.count))
        let ioURL = safeComponents.reduce(rootURL) { partial, component in
            partial.appendingPathComponent(component)
        }
        return ContainedPath(
            url: ioURL,
            relativePath: safeComponents.joined(separator: "/"),
            components: safeComponents
        )
    }

    // MARK: - パスの小道具

    /// 絶対パスを成分列にする。空成分（`//` や末尾の `/`）は落ちる。
    static func absoluteComponents(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func joined(_ base: String, _ components: [String]) -> String {
        var result = base
        for component in components {
            if result.hasSuffix("/") {
                result += component
            } else {
                result += "/" + component
            }
        }
        return result
    }
}
