import Foundation

/// **利用者が選び、権限を保持している1つのフォルダ。**（DESIGN.md 第16.5節）
///
/// ---
///
/// # サンドボックスの中で、なぜフォルダを読めるのか
///
/// `Sophia.entitlements` は `com.apple.security.files.user-selected.read-only` を持つ。
/// **「利用者が選んだもの」だけが読める**という許可で、入口は既に開いている（16.5節）。
///
/// そして `read-only` であることが **FR-20（書き込み・コマンド実行）を OS のレベルで
/// 止めている**（16.0節）。**この層に書き込みの口を作らないこと。**
/// 設計の約束ではなく OS の制約が境界を守っている、という状態を壊してはいけない。
///
/// # 3つの段階（16.5節の表）
///
/// | 段階 | 呼ぶもの | ここでの実装 |
/// |---|---|---|
/// | 取得 | `bookmarkData(options: .withSecurityScope, ...)` | `bind(to:)` |
/// | 復元 | `URL(resolvingBookmarkData:options: .withSecurityScope, ...)` | `restore(bookmark:)` |
/// | 使用 | `startAccessing...` / `stopAccessing...` を**必ず対で** | `withAccess(_:)` |
///
/// # 対を崩さないための形
///
/// **開始と終了を呼び手に任せない。** `withAccess(_:)` の中でしか使えない形にしてある。
/// 「途中で return した」「throw した」で終了を飛ばす事故は、
/// 気をつけて書けば防げる種類のものだが、**気をつけ続けることはできない。**
/// `defer` を1か所に閉じ込め、そこ以外に開始の呼び出しを置かない。
struct SecurityScopedFolder: Sendable, Equatable {

    /// **ブックマーク（または `NSOpenPanel`）が返した URL そのもの。**
    ///
    /// `startAccessingSecurityScopedResource()` は**この URL に対して**呼ぶこと。
    /// 正準化した別の URL を作って呼んでも、権限はそちらには付いていない。
    let url: URL

    /// 保存用のブックマーク。**次回起動時の復元はこれ1つに懸かっている**（機能3）。
    ///
    /// nil になるのはテスト・プレビュー用の `unscoped(directoryURL:)` だけで、
    /// **nil のものを保存してはいけない**（`FolderAccess` が弾いている）。
    let bookmark: Data?

    /// **手順4: 解決済みの根。**封じ込めの比較はこの値とだけ行う。
    /// 生成は `FolderContainment.canonicalRootPath(of:)` の1か所のみ。
    let canonicalRootPath: String

    /// ブックマークが古くなっていた（OS が作り直しを求めている）。
    /// **true なら呼び手は `bookmark` を保存し直すこと。**
    let isStale: Bool

    /// UI のチップに出す名前（16.7節）。
    var displayName: String { url.lastPathComponent }

    /// 利用者に見せる絶対パス。**解決後の値を出す** ── 16.6節の但し書きと同じ理由で、
    /// 選んだつもりの場所と実際に読む場所が違うなら、見えているべきは後者である。
    var displayPath: String { canonicalRootPath }

    private init(url: URL, bookmark: Data?, canonicalRootPath: String, isStale: Bool) {
        self.url = url
        self.bookmark = bookmark
        self.canonicalRootPath = canonicalRootPath
        self.isStale = isStale
    }

    // MARK: - 取得（機能1・2）

    /// 利用者が選んだ URL を、保存できる形に固める。
    ///
    /// `NSOpenPanel` が返した URL は**そのプロセスの間しか有効でない。**
    /// ブックマークにして初めて次回起動へ持ち越せる（機能3）。
    static func bind(to pickedURL: URL) throws -> SecurityScopedFolder {
        try withSecurityScope(on: pickedURL) {
            let canonical = try FolderContainment.canonicalRootPath(of: pickedURL)
            let data = try makeBookmark(for: pickedURL)
            return SecurityScopedFolder(
                url: pickedURL,
                bookmark: data,
                canonicalRootPath: canonical,
                isStale: false
            )
        }
    }

    // MARK: - 復元（機能3）

    /// 保存しておいたブックマークから復元する。**起動時に1回だけ呼ぶ想定。**
    ///
    /// ## 失効したら作り直す
    ///
    /// `bookmarkDataIsStale` が true になるのは、フォルダが動いた・OS が更新された等で
    /// **ブックマークの中身が古くなった**とき。解決自体は成功しているので、
    /// **その場で作り直して呼び手に返す**（呼び手が保存し直す）。
    /// 作り直さずに使い続けると、次のどこかで静かに解決できなくなる。
    ///
    /// > **【未確認 / 16.9節 項目2】起動をまたいで復元するには
    /// > `com.apple.security.files.bookmarks.app-scope` が要る、というのが一般的な理解だが、
    /// > 現在の `Sophia.entitlements` には無い。**
    /// > 同一起動中は動くはずだが、次回起動での復元はここが分かれ目になる。
    /// > **実機で確かめること。** 失敗するなら `.bookmarkUnreadable` が上がるので、
    /// > 16.8節どおり「選び直しを促す」に落ちる ── 黙って読めなくなることはない。
    static func restore(bookmark data: Data) throws -> SecurityScopedFolder {
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw FolderAccessError.bookmarkUnreadable(detail: "\(type(of: error)): \(error)")
        }

        return try withSecurityScope(on: resolvedURL) {
            let canonical = try FolderContainment.canonicalRootPath(of: resolvedURL)
            var carried = data
            if isStale, let refreshed = try? makeBookmark(for: resolvedURL) {
                carried = refreshed
            }
            return SecurityScopedFolder(
                url: resolvedURL,
                bookmark: carried,
                canonicalRootPath: canonical,
                isStale: isStale
            )
        }
    }

    /// **テストとプレビュー専用。**ブックマークを持たない。
    ///
    /// `NSOpenPanel` を出せない場所（単体テスト）で封じ込めを検証するための口である。
    /// `bookmark` が nil なので保存経路には乗らない。
    /// `Sources/Store/StoreTestSupport.swift` と同じ扱いのもの。
    static func unscoped(directoryURL: URL) throws -> SecurityScopedFolder {
        let canonical = try FolderContainment.canonicalRootPath(of: directoryURL)
        return SecurityScopedFolder(
            url: directoryURL,
            bookmark: nil,
            canonicalRootPath: canonical,
            isStale: false
        )
    }

    // MARK: - 使用（機能4）

    /// **アクセススコープの内側でだけ、読み取りができる形。**
    ///
    /// ## ⚠️ 閉包の外へ持ち出したものを、この型は追いかけられない【実測 2026-08-18】
    ///
    /// **以前ここには「持ち出しても `resolve` は失敗するだけ」と書いてあった。誤りである。**
    /// 実測（`AdversarialFileAccessTests`
    /// `testAContainedPathOutlivesTheScopeAndTheRootCheckThatIssuedIt`）はこうだった ──
    ///
    /// 1. スコープの中で `sub/inner.txt` を検証し、`ContainedPath` を得る（正しく内側）
    /// 2. スコープを抜ける
    /// 3. `sub` を**根の外へのシンボリックリンクに差し替える**
    /// 4. 持ち出した `ContainedPath` で `FolderReader.readText` → **根の外の中身が返った**
    ///
    /// `ContainedPath` はただの値であり、**有効期限も発行元への紐付けも持っていない。**
    /// 下の根の確認は**閉包の中でしか走らない**ので、返した後の読み取りは1回も通らない。
    /// `O_NOFOLLOW` が守るのは**最後の成分だけ**なので、途中の成分の差し替えは素通りする。
    ///
    /// **塞げていない。** 16.5節が「残る穴 / TOCTOU」として認めている範囲ではあるが、
    /// 節が想定した窓が「検証と開く瞬間の間」なのに対し、**実際の窓には上限が無い** ──
    /// `ContainedPath` を持ち続ければ、何分後でも同じ穴が開いたままである。
    ///
    /// 塞ぐには次のどれかが要る。**どれも本章の範囲を超えるので、いまは塞いでいない** ──
    ///
    /// - 成分ごとに `openat(2)` + `O_NOFOLLOW` を積む（16.5節が「割に合わない」とした案）
    /// - 開いた `fd` の実体を `F_GETPATH` で見て、根の内側かを確かめ直す
    /// - `ContainedPath` を閉包から出せない型にする（`~Escapable`）。
    ///   **ただしツール層は検索の frontier で配列に貯めるので、そのままでは載らない**
    ///
    /// 読み取り専用のいまは、最悪でも「別のファイルを読む」で済む。
    /// **FR-20（書き込み）を足すときは、上の4行がそのまま「別のファイルを壊す」になる。**
    ///
    /// なお、**渡される `AccessedFolder` も持ち出さないこと。**
    /// 持ち出したときに `resolve` が失敗するかは**測っていない**
    /// （単体テストはサンドボックスの外で走るので、ここでは確かめられない）。
    /// 仮に実機で落ちるとしても、止めているのは OS であってこの型ではない。
    ///
    /// ## 毎回ここで根を確かめ直している理由
    ///
    /// 結び付けた時に解決した絶対パスと、いま解決した絶対パスを突き合わせる。
    /// 食い違ったら `.rootMoved` で止める。
    ///
    /// **これが無いと封じ込めに穴が開く。** 封じ込めの比較は「結び付けた時の正準パス」に対して
    /// 行うが、実際の I/O は `url`（利用者が選んだ URL）に相対で行う。
    /// 結び付けた後に `url` の実体がシンボリックリンクへ差し替えられると、
    /// **比較は古い実体に対して通り、I/O は新しい実体へ行く。** 突き合わせがその橋を落とす。
    ///
    /// ついでに 16.8節の「フォルダを移動・削除・改名された」の検出にもなっている。
    func withAccess<T>(_ body: (AccessedFolder) throws -> T) throws -> T {
        try Self.withSecurityScope(on: url) {
            let current = try FolderContainment.canonicalRootPath(of: url)
            guard current == canonicalRootPath else {
                throw FolderAccessError.rootMoved(expected: canonicalRootPath, actual: current)
            }
            return try body(AccessedFolder(folder: self))
        }
    }

    // MARK: - 開始と終了の対（機能4の実体）

    /// **`start` / `stop` を対にする唯一の場所。**
    ///
    /// テストから対の成立を確かめられるよう、URL ではなく閉包を受け取る形にしてある
    /// （`FileAccessTests` の「対になっているか」の節）。実物は `withSecurityScope(on:)`。
    ///
    /// ## `start` が false でも即断しない理由
    ///
    /// `startAccessingSecurityScopedResource()` は
    /// **「そもそもスコープ付きでない URL」に対しても false を返す。**
    /// `NSOpenPanel` が返したばかりの URL や、自分のコンテナ内のパスがそれに当たる ──
    /// **権限が無いのではなく、要らない**状態である。
    /// ここで一律に throw すると、選んだ直後のフォルダが読めない実装になりかねない。
    ///
    /// そこで **false のときだけ、実際に読めるかを確かめる。**
    /// 読めるなら続行、読めないなら `.accessDenied`。
    /// 「戻り値を信じる」のではなく「事実を確かめる」ほうへ倒してある。
    /// これは 16.8節の「**黙って読めないまま進まないこと**」を満たしている ──
    /// 読めないときは必ず止まる。
    ///
    /// そして **`stop` を呼ぶのは `start` が true を返したときだけ。**
    /// 対応しない `stop` は他所の参照計数を落としうる。
    static func withSecurityScope<T>(
        start: () -> Bool,
        stop: () -> Void,
        verifyReadable: () -> Bool,
        body: () throws -> T
    ) throws -> T {
        let started = start()
        defer { if started { stop() } }

        if !started, !verifyReadable() {
            throw FolderAccessError.accessDenied("start=false かつ読み取り不可")
        }
        return try body()
    }

    private static func withSecurityScope<T>(on url: URL, _ body: () throws -> T) throws -> T {
        try withSecurityScope(
            start: { url.startAccessingSecurityScopedResource() },
            stop: { url.stopAccessingSecurityScopedResource() },
            verifyReadable: { FileManager.default.isReadableFile(atPath: url.path) },
            body: body
        )
    }

    private static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw FolderAccessError.bookmarkCreationFailed(detail: "\(type(of: error)): \(error)")
        }
    }
}

/// **アクセススコープが開いている間だけ存在する、根への入口。**
///
/// `SecurityScopedFolder.withAccess(_:)` の閉包にだけ渡る。
/// パスの検証（16.5節の4手順）はここを通す以外に無い。
struct AccessedFolder: Sendable {

    let folder: SecurityScopedFolder

    /// モデルが書いた相対パスを検証する。**通らなければ throw する。**
    ///
    /// 16.8節「ルート外のパスを要求された → **実行せず**、その旨をツールの戻り値として
    /// モデルに返す」の「実行せず」がここ。`FolderReader` は `ContainedPath` しか
    /// 受け取らないので、検証を通さない読み取りは書けない。
    func resolve(_ relativePath: String) throws -> ContainedPath {
        try FolderContainment.resolve(
            relativePath: relativePath,
            rootURL: folder.url,
            canonicalRootPath: folder.canonicalRootPath
        )
    }
}
