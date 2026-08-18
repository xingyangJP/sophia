import XCTest
@testable import Sophia

/// **封じ込め（DESIGN.md 第16.5節）が、実際に破られ方を1つずつ止めているかを固定する。**
///
/// ---
///
/// # なぜここに厚くテストを書くのか
///
/// 16.5節の4手順は、**どれか1つ消えても普段の動作は何も変わらない。**
/// `notes.md` は読めるし、一覧も出る。壊れたことに気づけるのは、
/// **誰かが意図的に外を指したとき**だけである。
///
/// つまりこの層は「動くこと」を確かめても意味が薄く、
/// **「動かないこと」を確かめないと守れない。** 以下は全部その形をしている。
///
/// | 破られ方 | 止めるもの | テスト |
/// |---|---|---|
/// | 絶対パス | 手順1 | `testAbsolutePathIsRejected` |
/// | `~` | 手順1 | `testHomeRelativePathIsRejected` |
/// | `..` | 手順1（多層防御） | `testParentTraversalIsRejected` |
/// | NUL でパスを切る | 手順1 | `testNulByteInPathIsRejected` |
/// | **`..` を使わない symlink 脱出** | **手順2＋3** | `testSymlinkOutOfRootIsRejectedWithoutAnyDotDot` |
/// | `link -> /etc` | 手順2＋3 | `testSymlinkToSystemDirectoryIsRejected` |
/// | **接頭辞一致の罠**（`docs` → `docs-secret`） | **手順3** | `testPrefixMatchTrapIsRejected` |
/// | 大文字小文字 | 手順3 | `testContainmentComparisonIsCaseSensitive` |
/// | 根そのものが symlink | 手順4 | `testRootThatIsItselfASymlinkIsResolved` |
/// | 存在しない先へ逃げる | 手順2 の遡り制限 | `testMissingPathBehindAnEscapingSymlinkIsStillOutside` |
///
/// # 実物のファイルシステムを使っている
///
/// symlink の解決を模擬に置き換えると、**確かめたいものが全部消える。**
/// 一時ディレクトリに本物のリンクを張って、本物の `realpath` に通している。
final class FileAccessTests: XCTestCase {

    /// 一時領域。`base/docs` を「許可した根」として使う。
    ///
    /// ```
    /// base/
    ///   docs/                ← 許可する根
    ///     notes.md           全5行
    ///     empty.txt          0バイト
    ///     crlf.txt           CRLF
    ///     binary.bin         NUL を含む
    ///     ver..old.txt       名前に ".." を含む正当なファイル
    ///     .hidden            隠しファイル
    ///     sub/inner.txt
    ///     inside      -> base/docs/sub        （内側。**許可されるべき**）
    ///     to-etc      -> /etc                 （外）
    ///     to-outside  -> base/outside         （外）
    ///     to-secret   -> base/docs-secret     （**接頭辞一致の罠**）
    ///   docs-secret/secret.txt                （`docs` の接頭辞を共有する別物）
    ///   outside/secret.txt
    ///   docs-link   -> base/docs              （**根そのものがリンク**）
    /// ```
    private var base: URL!
    private var root: URL!
    private var folder: SecurityScopedFolder!

    private static let notes = "一行目\n二行目\n三行目\n四行目\n五行目\n"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let manager = FileManager.default

        base = manager.temporaryDirectory
            .appendingPathComponent("SophiaFileAccessTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("docs", isDirectory: true)

        try manager.createDirectory(
            at: root.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        let secret = base.appendingPathComponent("docs-secret", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: secret, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)

        try write(Self.notes, to: root.appendingPathComponent("notes.md"))
        try write("", to: root.appendingPathComponent("empty.txt"))
        try write("a\r\nb\r\n", to: root.appendingPathComponent("crlf.txt"))
        try write("ふるい", to: root.appendingPathComponent("ver..old.txt"))
        try write("隠し", to: root.appendingPathComponent(".hidden"))
        try write(
            "内側",
            to: root.appendingPathComponent("sub", isDirectory: true)
                .appendingPathComponent("inner.txt"))
        try write("見せない", to: secret.appendingPathComponent("secret.txt"))
        try write("見せない", to: outside.appendingPathComponent("secret.txt"))
        try Data([0x41, 0x00, 0x42]).write(to: root.appendingPathComponent("binary.bin"))

        try manager.createSymbolicLink(
            at: root.appendingPathComponent("inside"),
            withDestinationURL: root.appendingPathComponent("sub", isDirectory: true))
        try manager.createSymbolicLink(
            at: root.appendingPathComponent("to-etc"),
            withDestinationURL: URL(fileURLWithPath: "/etc", isDirectory: true))
        try manager.createSymbolicLink(
            at: root.appendingPathComponent("to-outside"), withDestinationURL: outside)
        try manager.createSymbolicLink(
            at: root.appendingPathComponent("to-secret"), withDestinationURL: secret)
        try manager.createSymbolicLink(
            at: base.appendingPathComponent("docs-link"), withDestinationURL: root)

        folder = try SecurityScopedFolder.unscoped(directoryURL: root)
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
        try super.tearDownWithError()
    }

    // MARK: - 手順1: 根を必ず前置する

    /// 絶対パスは受け取らない（16.4節）。**受け取らないことで入口が1本に絞れる。**
    func testAbsolutePathIsRejected() {
        for path in ["/etc/passwd", "/", "/Users"] {
            let error = expectFailure { try self.resolve(path) }
            XCTAssertEqual(error, FolderAccessError.absolutePathRejected(path))
        }
    }

    /// `~` は誰かが展開すればホーム直下になる。**展開しないことと拒否することは別。**
    func testHomeRelativePathIsRejected() {
        let error = expectFailure { try self.resolve("~/.ssh/id_rsa") }
        XCTAssertEqual(error, FolderAccessError.homeRelativePathRejected("~/.ssh/id_rsa"))
    }

    /// `..` は手順1でも落とす（手順2・3だけでも落ちるが、多層にしてある）。
    func testParentTraversalIsRejected() {
        for path in ["../docs-secret/secret.txt", "sub/../../outside/secret.txt", ".."] {
            let error = expectFailure { try self.resolve(path) }
            XCTAssertEqual(error, FolderAccessError.parentTraversalRejected(path))
        }
    }

    /// **成分がちょうど `..` のときだけ**落とすこと。
    /// 部分文字列で判定すると `ver..old.txt` のような正当な名前まで巻き添えになる。
    func testFileNameContainingDotDotIsNotRejected() throws {
        let window = try read("ver..old.txt")

        XCTAssertEqual(window.text, "ふるい")
    }

    /// C の API は NUL でパスを切る。
    /// **Swift 側で見ている文字列とカーネルが見る文字列が食い違う**ので、その前に落とす。
    func testNulByteInPathIsRejected() {
        let path = "notes.md\u{0}/../../etc/passwd"

        let error = expectFailure { try self.resolve(path) }

        XCTAssertEqual(error, FolderAccessError.invalidPath(path))
    }

    // MARK: - 手順2: シンボリックリンクを解決してから比べる

    /// **本作業の核心。** `..` を1つも含まない相対パスで外へ出られてはいけない。
    ///
    /// 字句の正規化だけの実装は、ここで必ず破られる ──
    /// `to-etc/hosts` に `..` は無いので、正規化しても何も検出できない。
    func testSymlinkOutOfRootIsRejectedWithoutAnyDotDot() {
        for path in ["to-outside/secret.txt", "to-secret/secret.txt"] {
            XCTAssertFalse(path.contains(".."), "前提: このテストは `..` を使わない")

            let error = expectFailure { try self.resolve(path) }

            guard case .outsideRoot(let requested, _)? = error else {
                return XCTFail("ルート外として拒否されなかった: \(path) → \(String(describing: error))")
            }
            XCTAssertEqual(requested, path)
        }
    }

    /// 課題文が挙げている `許可した場所/link -> /etc` そのもの。
    ///
    /// `.accessDenied` も合格にしてあるのは、**サンドボックスが先に落とす可能性**があるため
    /// （`/etc` を辿れないと `realpath` が EACCES で失敗する）。
    /// どちらにせよ**読めていない**ことが要件であって、
    /// 誰が止めたかは問わない。**「確かめられなかった」を「内側」に化けさせない**のが
    /// `FolderContainment.canonicalPath` の遡り制限であり、それはここでも効いている。
    func testSymlinkToSystemDirectoryIsRejected() {
        guard let error = expectFailure({ try self.resolve("to-etc/hosts") }) else { return }

        switch error {
        case .outsideRoot(_, let resolved):
            XCTAssertTrue(
                resolved.hasSuffix("/etc/hosts"),
                "リンクが解決されていない（字句のままになっている）: \(resolved)")
        case .accessDenied:
            break
        default:
            XCTFail("ルート外として拒否されなかった: \(error)")
        }
    }

    /// **内側を指すリンクは通る。** 拒否の理由が「リンクだから」ではなく
    /// 「解決した先が外だから」であることの確認。ここを取り違えると、
    /// 正当な使い方（フォルダ内の整理用リンク）まで塞ぐ。
    func testSymlinkPointingInsideIsAllowed() throws {
        let window = try read("inside/inner.txt")

        XCTAssertEqual(window.text, "内側")
        // 解決後の相対パスは**実体の側**になる。表示にも栞にもこちらが出るべきである。
        XCTAssertEqual(window.path, "sub/inner.txt")
    }

    /// 存在しないパスは「見つからない」であって「外」ではない（16.8節で扱いが違う）。
    ///
    /// **層が違うことに注意。** 封じ込め（`resolve`）の仕事は「根の内側か」だけで、
    /// **存在しないパスも内側であることに変わりはない**（だからこそ、
    /// 存在しない末尾を ENOENT/ENOTDIR のときだけ許す正準化が成立する）。
    /// 「無い」と言うのは読み取り側の仕事である。
    func testMissingFileIsReportedAsNotFound() throws {
        // 封じ込めは通る ─ 内側だから。
        XCTAssertNoThrow(try self.resolve("nope.txt"), "存在しないだけで『外』ではない")

        // 読もうとして初めて「無い」と分かる。
        let error = expectFailure { _ = try self.read("nope.txt") }
        XCTAssertEqual(error, FolderAccessError.notFound("nope.txt"))
    }

    /// **存在しない末尾を許す正準化が、脱出の抜け道になっていないこと。**
    ///
    /// `to-outside/nope` は実在しない。祖先（`to-outside`）まで遡って解決すると
    /// `base/outside` になり、そこに `nope` を足したものは**根の外**である。
    /// 遡りが根の側で止まってしまう実装だと、ここが素通りする。
    func testMissingPathBehindAnEscapingSymlinkIsStillOutside() {
        let error = expectFailure { try self.resolve("to-outside/nope") }

        guard case .outsideRoot(_, let resolved)? = error else {
            return XCTFail("ルート外として拒否されなかった: \(String(describing: error))")
        }
        XCTAssertFalse(
            resolved.hasPrefix(folder.canonicalRootPath),
            "祖先まで遡らずに根の内側の文字列を組み立ててしまっている: \(resolved)")
    }

    // MARK: - 手順3: パスの境界で区切って比べる

    /// **接頭辞一致の罠。** 根が `.../docs` のとき `.../docs-secret` は
    /// 文字列としては本当に接頭辞なので、`hasPrefix` の実装は通してしまう。
    func testPrefixMatchTrapIsRejected() {
        let error = expectFailure { try self.resolve("to-secret/secret.txt") }

        guard case .outsideRoot(_, let resolved)? = error else {
            return XCTFail("ルート外として拒否されなかった: \(String(describing: error))")
        }
        // **この2行が罠の存在そのものの証明である。**
        // 素朴な接頭辞一致なら通っていた、という事実を固定しておく。
        XCTAssertTrue(
            resolved.hasPrefix(folder.canonicalRootPath),
            "前提が崩れた: 罠を再現できていない（解決後が根の接頭辞になっていない）")
        XCTAssertFalse(resolved.hasPrefix(folder.canonicalRootPath + "/"))
    }

    /// 比較は**成分単位**であること。
    func testContainmentComparisonSplitsAtPathBoundaries() {
        let root = ["Users", "x", "docs"]

        XCTAssertTrue(FolderContainment.isContained(root, within: root), "根そのものは内側")
        XCTAssertTrue(FolderContainment.isContained(root + ["a", "b.txt"], within: root))
        XCTAssertFalse(FolderContainment.isContained(["Users", "x", "docs-secret"], within: root))
        XCTAssertFalse(FolderContainment.isContained(["Users", "x", "docsomething", "a"], within: root))
        XCTAssertFalse(FolderContainment.isContained(["Users", "x"], within: root), "根の上位は外側")

        // 文字列比較なら通っていたことを、ここでも明示しておく。
        XCTAssertTrue("/Users/x/docs-secret".hasPrefix("/Users/x/docs"))
    }

    /// **大文字小文字を同一視しないこと。**
    ///
    /// macOS の既定ボリュームは case-insensitive だが、**比較の前提にしない。**
    /// 緩く比べると case-sensitive なボリュームで「別のディレクトリなのに許可」が起きる。
    /// 厳密に比べれば、最悪でも「同じ場所なのに拒否」＝安全側に倒れる。
    func testContainmentComparisonIsCaseSensitive() {
        let root = ["Users", "x", "docs"]

        XCTAssertFalse(FolderContainment.isContained(["Users", "x", "DOCS", "a"], within: root))
        XCTAssertFalse(FolderContainment.isContained(["Users", "X", "docs", "a"], within: root))
        XCTAssertFalse(FolderContainment.isContained(["users", "x", "docs"], within: root))
    }

    /// 綴りが違っても**外へは出ない**こと（ボリュームの case 感度に依存しない形で確かめる）。
    ///
    /// case-insensitive なボリュームでは `realpath` が綴りをディスク上の名前へ正規化するため
    /// 読めてしまう。それは同じファイルなので**正しい**。
    /// case-sensitive なら単に存在しない。**どちらでも根の外には出ない**ことだけを固定する。
    func testCaseVariantEitherResolvesToTheRealNameOrIsMissing() {
        do {
            let path = try resolve("SUB/INNER.TXT")
            XCTAssertEqual(path.relativePath, "sub/inner.txt", "綴りが正規化されていない")
        } catch let error as FolderAccessError {
            XCTAssertEqual(error, FolderAccessError.notFound("SUB/INNER.TXT"))
        } catch {
            XCTFail("想定外: \(error)")
        }
    }

    // MARK: - 手順4: 根も解決後の値で持つ

    /// 根そのものがシンボリックリンクでも、封じ込めが成立すること。
    ///
    /// 根を未解決のまま持つと、候補（解決済み）との比較が**全部食い違う** ──
    /// 正しいパスまで「外」になるか、比較が空振りして全部通るかのどちらかになる。
    func testRootThatIsItselfASymlinkIsResolved() throws {
        let linked = try SecurityScopedFolder.unscoped(
            directoryURL: base.appendingPathComponent("docs-link"))

        // 手順4: 保持している根は解決後の値である。
        XCTAssertEqual(linked.canonicalRootPath, folder.canonicalRootPath)

        // 中は普通に読める。
        let window = try linked.withAccess { try FolderReader.readText($0.resolve("notes.md")) }
        XCTAssertEqual(window.totalLines, 5)

        // そして外へは出られないままである。
        let error = expectFailure {
            try linked.withAccess { try $0.resolve("to-etc/hosts") }
        }
        guard case .outsideRoot? = error else {
            return XCTFail("根がリンクのときに封じ込めが外れた: \(String(describing: error))")
        }
    }

    // MARK: - 正常系（拒否が過剰でないこと）

    func testPlainRelativePathIsAllowed() throws {
        XCTAssertEqual(try read("sub/inner.txt").text, "内側")
    }

    /// `.` と `//` は無害に落ちる。ここまで拒否すると、モデルの素直な出力が通らなくなる。
    func testDotSegmentsAndDoubleSlashesAreHarmless() throws {
        let path = try resolve("./sub//inner.txt")

        XCTAssertEqual(path.relativePath, "sub/inner.txt")
        XCTAssertEqual(path.components, ["sub", "inner.txt"])
    }

    func testEmptyPathMeansTheRootItself() throws {
        let path = try resolve("")

        XCTAssertTrue(path.isRoot)
        XCTAssertEqual(path.relativePath, "")
    }

    // MARK: - 開始と終了を対にする（機能4）

    /// **本体が throw しても終了が呼ばれること。**
    func testAccessScopeStopsEvenWhenTheBodyThrows() {
        var started = 0
        var stopped = 0

        XCTAssertThrowsError(
            try SecurityScopedFolder.withSecurityScope(
                start: { started += 1; return true },
                stop: { stopped += 1 },
                verifyReadable: { true },
                body: { () throws -> Void in throw FolderAccessError.notFound("x") }
            )
        )

        XCTAssertEqual(started, 1)
        XCTAssertEqual(stopped, 1, "throw の経路で stop が漏れている")
    }

    func testAccessScopeStopsExactlyOnceOnSuccess() throws {
        var stopped = 0

        let value = try SecurityScopedFolder.withSecurityScope(
            start: { true }, stop: { stopped += 1 }, verifyReadable: { true }, body: { 7 })

        XCTAssertEqual(value, 7)
        XCTAssertEqual(stopped, 1)
    }

    /// **開始が false のときに終了を呼ばないこと。**
    /// 対応しない `stop` は他所の参照計数を落としうる。
    func testAccessScopeDoesNotStopWhenStartFailed() throws {
        var stopped = 0

        let value = try SecurityScopedFolder.withSecurityScope(
            start: { false }, stop: { stopped += 1 }, verifyReadable: { true }, body: { 7 })

        XCTAssertEqual(value, 7, "スコープ不要の URL でも本体は走ること")
        XCTAssertEqual(stopped, 0)
    }

    /// 16.8節「**黙って読めないまま進まないこと**」。
    /// 開始が false で、しかも実際に読めないなら、本体を走らせずに止める。
    func testAccessIsDeniedWhenStartFailedAndTheRootIsUnreadable() {
        var bodyRan = false

        let error = expectFailure {
            try SecurityScopedFolder.withSecurityScope(
                start: { false },
                stop: {},
                verifyReadable: { false },
                body: { () throws -> Void in bodyRan = true }
            )
        }

        guard case .accessDenied? = error else {
            return XCTFail("権限切れを検出できていない: \(String(describing: error))")
        }
        XCTAssertFalse(bodyRan, "読めないのに本体が走っている")
    }

    /// 根が動いたら止める。
    /// 封じ込めの比較は「結び付けた時の正準パス」に対して行うので、
    /// **実体が入れ替わったまま I/O を続けると、比較と実行の対象がずれる。**
    func testAccessFailsAfterTheRootIsReplaced() throws {
        let manager = FileManager.default
        let moved = base.appendingPathComponent("moved", isDirectory: true)
        try manager.moveItem(at: root, to: moved)
        // 同じ名前で、外を指すリンクに差し替える。
        try manager.createSymbolicLink(at: root, withDestinationURL: moved)

        let error = expectFailure { try self.resolve("notes.md") }

        guard case .rootMoved? = error else {
            return XCTFail("根の差し替えを検出できていない: \(String(describing: error))")
        }
    }

    // MARK: - 一覧（機能6）

    func testListingReportsNameKindSizeAndDate() throws {
        let listing = try list("")

        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["sub"]?.kind, .directory)
        XCTAssertEqual(byName["notes.md"]?.kind, .file)
        XCTAssertEqual(byName["notes.md"]?.byteSize, Self.notes.utf8.count)
        XCTAssertNotNil(byName["notes.md"]?.modifiedAt)
        XCTAssertEqual(byName["notes.md"]?.relativePath, "notes.md")

        // **リンクはリンクとして見せる。**
        // 実体を追った種別で見せると、開けない理由が誰にも分からなくなる。
        XCTAssertEqual(byName["to-etc"]?.kind, .symbolicLink)
        XCTAssertEqual(byName["inside"]?.kind, .symbolicLink)

        XCTAssertEqual(listing.entries.first?.kind, .directory, "ディレクトリが先")
        XCTAssertFalse(listing.isTruncated)
        XCTAssertEqual(listing.totalCount, listing.entries.count)
    }

    /// 既定では隠しファイルを出さない（費用と、`.env` 類を目の前に置かない判断）。
    func testHiddenEntriesAreSkippedByDefaultAndAvailableOnRequest() throws {
        XCTAssertFalse(try list("").entries.contains { $0.name == ".hidden" })
        XCTAssertTrue(try list("", includingHidden: true).entries.contains { $0.name == ".hidden" })
    }

    /// 切ったら**切る前の総数**を添える（16.4節）。
    func testListingTruncatesAndKeepsTheTotalCount() throws {
        let full = try list("")

        let cut = try list("", limit: 2)

        XCTAssertEqual(cut.entries.count, 2)
        XCTAssertEqual(cut.totalCount, full.entries.count)
        XCTAssertTrue(cut.isTruncated)
        // 順序が決まっていないと、切った結果が呼ぶたびに変わる。
        XCTAssertEqual(cut.entries.map(\.name), Array(full.entries.map(\.name).prefix(2)))
    }

    func testListingAFileFails() {
        let error = expectFailure { try self.list("notes.md") }

        XCTAssertEqual(error, FolderAccessError.notADirectory("notes.md"))
    }

    // MARK: - 読み取り（機能6）

    /// 窓で切っても、**総行数は本当の総数**であること（16.3節）。
    func testWindowedReadReportsTheTrueTotal() throws {
        let window = try read("notes.md", offset: 2, limit: 2)

        XCTAssertEqual(window.text, "二行目\n三行目")
        XCTAssertEqual(window.firstLine, 2)
        XCTAssertEqual(window.lastLine, 3)
        XCTAssertEqual(window.totalLines, 5, "窓の外の行が数えられていない")
        XCTAssertEqual(window.totalBytes, Self.notes.utf8.count)
        XCTAssertFalse(window.isComplete, "切ったのに「全部読んだ」に見えている")
    }

    func testReadingTheWholeFileIsMarkedComplete() throws {
        let window = try read("notes.md")

        XCTAssertEqual(window.totalLines, 5)
        XCTAssertTrue(window.isComplete)
    }

    /// 窓が末尾より後ろでも、失敗にはしない。**総数は返るので、モデルは自分で気づける。**
    func testWindowBeyondTheEndReturnsNothingButStillReportsTheTotal() throws {
        let window = try read("notes.md", offset: 99)

        XCTAssertEqual(window.text, "")
        XCTAssertNil(window.firstLine)
        XCTAssertNil(window.lastLine)
        XCTAssertEqual(window.totalLines, 5)
    }

    func testEmptyFileReadsCleanly() throws {
        let window = try read("empty.txt")

        XCTAssertEqual(window.text, "")
        XCTAssertEqual(window.totalLines, 0)
        XCTAssertEqual(window.totalBytes, 0)
    }

    /// CRLF の `\r` は落とす。残すとモデルの文脈に見えないゴミが1行ごとに増える。
    func testCarriageReturnsAreStripped() throws {
        let window = try read("crlf.txt")

        XCTAssertEqual(window.text, "a\nb")
        XCTAssertEqual(window.totalLines, 2)
    }

    /// 16.8節「テキストでない（バイナリ）→ 読まない。種別とサイズだけ返す」。
    func testBinaryFileIsNotRead() {
        let error = expectFailure { try self.read("binary.bin") }

        XCTAssertEqual(error, FolderAccessError.binaryFile(path: "binary.bin", totalBytes: 3))
    }

    func testReadingADirectoryFails() {
        let error = expectFailure { try self.read("sub") }

        XCTAssertEqual(error, FolderAccessError.notAFile("sub"))
    }

    // MARK: - 権限の保存と復元（機能2・3）

    func testInMemoryBookmarkStoreRoundTrips() {
        let store = InMemoryFolderBookmarkStore()
        XCTAssertNil(store.loadBookmark())

        store.saveBookmark(Data([1, 2, 3]))
        XCTAssertEqual(store.loadBookmark(), Data([1, 2, 3]))

        store.clearBookmark()
        XCTAssertNil(store.loadBookmark())
    }

    /// 利用者の `UserDefaults` を汚さないよう、専用の suite で確かめる。
    func testUserDefaultsBookmarkStoreRoundTrips() throws {
        let suiteName = "jp.co.xerographix.sophia.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsFolderBookmarkStore(defaults: defaults, key: "test.bookmark")
        store.saveBookmark(Data([9]))

        XCTAssertEqual(store.loadBookmark(), Data([9]))
        store.clearBookmark()
        XCTAssertNil(store.loadBookmark())

        // 既定のキーは逆ドメインで始めること（`UserDefaults.standard` は他とも同居する）。
        XCTAssertTrue(
            UserDefaultsFolderBookmarkStore.defaultKey.hasPrefix("jp.co.xerographix.sophia."))
    }

    @MainActor
    func testFolderAccessStartsUnbound() async {
        let access = FolderAccess(bookmarks: InMemoryFolderBookmarkStore())

        XCTAssertNil(access.folder)
        XCTAssertFalse(access.restoreSavedFolder())

        do {
            _ = try await access.list()
            XCTFail("未結合なのに一覧できた")
        } catch let error as FolderAccessError {
            XCTAssertEqual(error, FolderAccessError.noFolderBound)
        } catch {
            XCTFail("想定外: \(error)")
        }
    }

    /// 16.8節「ブックマークが失効した → 結び付けを外し、選び直しを促す。**会話は続行する**」。
    /// 起動時に throw して止めないこと。そして**壊れたブックマークは捨てる**こと
    /// （残すと次回起動で同じ失敗を繰り返す）。
    @MainActor
    func testFolderAccessDropsAnUnusableBookmarkInsteadOfFailing() {
        let store = InMemoryFolderBookmarkStore(initial: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        let access = FolderAccess(bookmarks: store)

        XCTAssertFalse(access.restoreSavedFolder())

        XCTAssertNil(access.folder)
        XCTAssertNil(store.loadBookmark(), "失効したブックマークが残っている")
    }

    // MARK: - 文言（FR-11）

    /// **原因と対処を必ず対で持つこと。** 片方だけでは利用者が次に何をすればよいか分からない。
    func testEveryErrorCarriesAJapaneseCauseAndRemedy() {
        let errors: [FolderAccessError] = [
            .absolutePathRejected("/etc/passwd"),
            .homeRelativePathRejected("~/x"),
            .parentTraversalRejected("../x"),
            .invalidPath("x"),
            .outsideRoot(requested: "link/x", resolved: "/private/etc/x"),
            .noFolderBound,
            .rootUnavailable("/nope"),
            .rootNotADirectory("/nope"),
            .rootMoved(expected: "/a", actual: "/b"),
            .bookmarkUnreadable(detail: "d"),
            .bookmarkCreationFailed(detail: "d"),
            .accessDenied("/nope"),
            .notFound("a.txt"),
            .notADirectory("a.txt"),
            .notAFile("a.txt"),
            .binaryFile(path: "a.bin", totalBytes: 10),
            .fileTooLarge(path: "big.log", totalBytes: 99),
            .notUTF8("a.txt"),
            .pathChangedDuringAccess("a.txt"),
            .ioFailed(path: "a.txt", detail: "d"),
        ]

        for error in errors {
            let sophia = error.sophiaError
            XCTAssertFalse(sophia.message.isEmpty, "message が空: \(error)")
            XCTAssertFalse(sophia.hint?.isEmpty ?? true, "FR-11: 対処が無い: \(error)")
            XCTAssertNotNil(sophia.detail, "detail が無い: \(error)")
            XCTAssertFalse(error.modelMessage.isEmpty, "モデルへの返答が空: \(error)")
        }
    }

    /// 16.6節: **利用者には解決後の絶対パスを見せる**（引数のままだと逃げた先が隠れる）。
    /// **モデルには見せない**（約束1。根の外に何があるかを教える必要が無い）。
    func testOutsideRootTellsTheUserWhereItWentButNotTheModel() {
        let error = FolderAccessError.outsideRoot(
            requested: "link/passwd", resolved: "/private/etc/passwd")

        XCTAssertTrue(error.sophiaError.message.contains("/private/etc/passwd"))
        XCTAssertFalse(error.modelMessage.contains("/private/etc/passwd"))
    }

    /// **これは「まだ足りていないもの」を固定するテストである。**
    ///
    /// `SophiaError.Code` にファイル参照のケースが無いので、いまは全部 `.unknown` に落ちている。
    /// **UI は「フォルダの失効」だけを特別扱いする分岐が書けない**（16.8節の自動化ができない）。
    /// ケースが足されたら**このテストが落ちる。** 落ちたら
    /// `FolderAccessError.sophiaError` の `code:` を差し替えて、ここを直すこと。
    func testFileAccessErrorsStillFallBackToUnknownCode() {
        XCTAssertEqual(FolderAccessError.accessDenied("x").sophiaError.code, .unknown)
        XCTAssertFalse(
            SophiaError.Code.allCases.contains { "\($0)".lowercased().contains("folder") },
            "SophiaError.Code にフォルダ用のケースが入った。FolderAccessError.sophiaError を直すこと")
    }

    // MARK: - 補助

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func resolve(_ path: String) throws -> ContainedPath {
        try folder.withAccess { try $0.resolve(path) }
    }

    private func list(
        _ path: String, limit: Int = FolderReadLimits.entryLimit, includingHidden: Bool = false
    ) throws -> DirectoryListing {
        try folder.withAccess {
            try FolderReader.list($0.resolve(path), limit: limit, includingHidden: includingHidden)
        }
    }

    private func read(
        _ path: String, offset: Int = 1, limit: Int = FolderReadLimits.lineLimit
    ) throws -> FileWindow {
        try folder.withAccess {
            try FolderReader.readText($0.resolve(path), offset: offset, limit: limit)
        }
    }

    /// 拒否されることを確かめ、その理由を返す。
    /// **「失敗した」だけでは足りない** ── 16.8節は理由ごとに扱いを変えているので、
    /// 理由まで固定しないとテストの意味が半分になる。
    @discardableResult
    private func expectFailure<T>(
        _ expression: () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> FolderAccessError? {
        do {
            _ = try expression()
            XCTFail("拒否されるはずだった", file: file, line: line)
            return nil
        } catch let error as FolderAccessError {
            return error
        } catch {
            XCTFail("FolderAccessError ではない: \(error)", file: file, line: line)
            return nil
        }
    }
}
