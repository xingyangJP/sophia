import CryptoKit
import Foundation
import HuggingFace

// =============================================================================
//  重みファイルだけを、途中から再開できる形で取る
//
//  ## なぜ要るのか（2026-09-05 の事故）
//
//  `downloadSnapshot` は **99.2%（4,571,486,285 / 4,607,835,174 bytes）で落ちた。**
//  そして **4.57GB が孤児になった。**
//
//  swift-huggingface 0.9.0 には**再開が無い。** 失敗すれば次はゼロから始まる。
//  一時ディレクトリには **57件・16GB** の残骸が積み上がっていた ──
//  **やり直すたびに 4.5GB を捨てていた。**
//
//  16GB機・細い回線では、**成功確率が低いほど失敗が積み上がる。**
//  実際に3回試して3回とも終盤で落ちた。**FR-07（初回取得）が成立していない。**
//
//  ## 何をするか
//
//  **大きい重みファイルだけを、`Range` 付きで自分で取る。**
//  小さいファイル（config / tokenizer 類）は今までどおり `downloadSnapshot` に任せる ──
//  **落ちても失うものが小さいので、再開の仕組みを持つ価値が無い。**
//
//  置き場所は**ライブラリと同じ**にする（`HubCache` の公開 API をそのまま使う）。
//  **自分で経路を組み立てないこと（R1）** ── 組み立てると、ライブラリが場所を変えた日に
//  「取得済みなのに再取得が走る」という静かな二重取得になる。
//
//  ```
//  blobs/<x-linked-etag>                  ← 実体
//  snapshots/<x-repo-commit>/<file>       ← そこへの symlink
//  ```
//
//  **この手順は 2026-09-06 に手で実演して確認してある**（`docs/DOWNLOAD_VERIFY.md`）──
//  孤児になった 4.57GB に残り 36MB を継ぎ足したら sha256 が `x-linked-etag` と一致し、
//  そのままアプリが読み込めた。**部分ファイルは正しい前置である。**
// =============================================================================

enum WeightPrefetch {

    /// **500MB。** これより大きいものだけを自分で取る。
    ///
    /// 根拠は「落ちたときに失う量」である。config.json は 939 バイト、
    /// tokenizer.json でも 2.7MB で、**落ちても取り直せばいい。**
    /// 重みは 4.6GB あり、**取り直すと30分と回線を失う。**
    /// **境界の位置に精度は要らない** ── 重みとそれ以外の間に、3桁の差がある。
    static let largeFileThreshold: Int64 = 500 * 1024 * 1024

    /// 遠くにあるファイルの素性。**3つとも HEAD の応答ヘッダから取る。**
    struct RemoteFile: Sendable, Equatable {
        /// `x-repo-commit`。**スナップショットのディレクトリ名になる。**
        var revision: String
        /// `x-linked-etag`（LFS の sha256）。**blob のファイル名になり、検算の期待値にもなる。**
        var etag: String
        /// `x-linked-size`。**`content-length` ではない** ── あちらはリダイレクト前の
        /// ポインタファイル（982 バイト）を指すことがある。
        var size: Int64
    }

    /// 取得の進み具合。**バイトで持つ。** 割合は呼び手が総量と割って作る。
    struct Progress: Sendable, Equatable {
        var completedBytes: Int64
        var totalBytes: Int64
        /// **再開したか。** ログに出す ── 「今回は何バイト拾えたか」が
        /// この仕組みが効いているかどうかの唯一の証拠になる。
        var resumedFromBytes: Int64
    }

    enum Failure: Error, Equatable {
        /// HEAD が期待するヘッダを返さなかった。**推測で埋めない**（R7）。
        case missingHeaders(String)
        /// 落とし終えたのにサイズが合わない。
        case sizeMismatch(expected: Int64, actual: Int64)
        /// 落とし終えたのに sha256 が合わない。**部分ファイルが壊れていた場合。**
        case digestMismatch(expected: String, actual: String)
    }

    // MARK: - 素性を訊く

    /// HEAD で素性を取る。**本体は1バイトも落とさない。**
    ///
    /// - Note: `content-length` を見ないこと。LFS のファイルは
    ///   **ポインタの長さ（982 バイト）** が返ることがあり、それを総量だと思うと
    ///   「1バイトも落ちていないのに完了」になる。**`x-linked-size` を見る。**
    static func describe(
        modelID: String, file: String, session: URLSession = .shared
    ) async throws -> RemoteFile {
        var request = URLRequest(url: resolveURL(modelID: modelID, file: file))
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.missingHeaders("HTTP の応答ではない")
        }
        return try remoteFile(from: http)
    }

    /// ヘッダから素性を組み立てる。**HTTP を触らないので単体で試験できる。**
    static func remoteFile(from http: HTTPURLResponse) throws -> RemoteFile {
        func header(_ name: String) -> String? {
            (http.value(forHTTPHeaderField: name)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let revision = header("x-repo-commit") else {
            throw Failure.missingHeaders("x-repo-commit")
        }
        guard let etag = header("x-linked-etag") ?? header("etag") else {
            throw Failure.missingHeaders("x-linked-etag")
        }
        guard let sizeText = header("x-linked-size"), let size = Int64(sizeText) else {
            throw Failure.missingHeaders("x-linked-size")
        }
        return RemoteFile(revision: revision, etag: etag, size: size)
    }

    static func resolveURL(modelID: String, file: String) -> URL {
        URL(string: "https://huggingface.co/\(modelID)/resolve/main/\(file)")!
    }

    // MARK: - 再開の判断（**ここが本体。ネットワークを触らないので試験できる**）

    /// 何バイト目から再開するか。
    ///
    /// - `nil` を返したら**もう完成している**（取りに行かない）。
    /// - `0` を返したら**最初から**。
    /// - 正の数を返したら**そこから `Range` で継ぐ。**
    ///
    /// **部分ファイルが期待より大きいときは 0 から取り直す。**
    /// 前回と違うファイルの残骸が同じ名前で残っている場合があり、
    /// **継ぐと壊れたものが出来上がって、sha256 で落ちるまで気づけない。**
    static func resumeOffset(existingBytes: Int64, expectedSize: Int64) -> Int64? {
        if existingBytes == expectedSize { return nil }
        if existingBytes > expectedSize { return 0 }
        return max(0, existingBytes)
    }

    // MARK: - 置き場所

    /// blob の置き場。**`HubCache` の公開 API をそのまま使う。**
    static func blobURL(repo: Repo.ID, etag: String) throws -> URL {
        try HubCache.default.blobPath(repo: repo, kind: .model, etag: etag)
    }

    /// 途中まで落ちたものの置き場。**ライブラリの作法（`<etag>.incomplete`）に合わせる。**
    /// 自分で `.partial` を作らない ── **同じ目的の場所を2つ持つと、片方が孤児になる。**
    static func incompleteURL(repo: Repo.ID, etag: String) throws -> URL {
        try HubCache.default.incompleteBlobPath(repo: repo, kind: .model, etag: etag)
    }

    /// snapshot 側の名前（blob への symlink を張る先）。
    static func snapshotFileURL(repo: Repo.ID, revision: String, file: String) -> URL {
        HubCache.default
            .snapshotsDirectory(repo: repo, kind: .model)
            .appendingPathComponent(revision)
            .appendingPathComponent(file)
    }

    // MARK: - 取る

    /// **重みが揃っていなければ、途中から取って揃える。**
    ///
    /// 揃っていれば**1バイトも通信しない**（HEAD すら打たない経路は無いが、
    /// HEAD は本体を落とさないので実質ゼロである）。
    ///
    /// - Returns: 実際に取りに行ったなら `true`。既に揃っていたら `false`。
    @discardableResult
    static func ensure(
        modelID: String,
        file: String = "model.safetensors",
        session: URLSession = .shared,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Bool {
        guard let repo = repoID(from: modelID) else { return false }

        let remote = try await describe(modelID: modelID, file: file, session: session)
        let blob = try blobURL(repo: repo, etag: remote.etag)
        let link = snapshotFileURL(repo: repo, revision: remote.revision, file: file)
        let fm = FileManager.default

        // 既に揃っている。**サイズまで見る** ── 存在だけを見ると、
        // 途中で終わったものを「在る」と読んでしまう。
        if let size = fileSize(at: blob), size == remote.size {
            try linkIfNeeded(blob: blob, at: link)
            return false
        }

        let incomplete = try incompleteURL(repo: repo, etag: remote.etag)
        try fm.createDirectory(
            at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing = fileSize(at: incomplete) ?? 0
        guard let offset = resumeOffset(existingBytes: existing, expectedSize: remote.size) else {
            // 未完成ファイルのほうが完成していた（前回、名前を付け替える前に落ちた）。
            try? fm.removeItem(at: blob)
            try fm.moveItem(at: incomplete, to: blob)
            try linkIfNeeded(blob: blob, at: link)
            return true
        }
        if offset == 0 { try? fm.removeItem(at: incomplete) }

        try await append(
            from: resolveURL(modelID: modelID, file: file),
            to: incomplete, startingAt: offset, expecting: remote,
            session: session, onProgress: onProgress)

        // **サイズを見てから名前を付け替える。**
        let finalSize = fileSize(at: incomplete) ?? 0
        guard finalSize == remote.size else {
            throw Failure.sizeMismatch(expected: remote.size, actual: finalSize)
        }

        // **sha256 を必ず検算する。** 継いだ前置が壊れていた場合、
        // ここで捕まえないと「読み込みが謎に失敗する」形で後から出る。
        // **毎回は測らない** ── 完成済みなら上の分岐で戻っているので、
        // ここを通るのは**組み上げた瞬間の1回だけ**である。
        let digest = try sha256Hex(of: incomplete)
        guard digest.caseInsensitiveCompare(remote.etag) == .orderedSame else {
            try? fm.removeItem(at: incomplete)
            throw Failure.digestMismatch(expected: remote.etag, actual: digest)
        }

        try? fm.removeItem(at: blob)
        try fm.moveItem(at: incomplete, to: blob)
        try linkIfNeeded(blob: blob, at: link)
        return true
    }

    /// **64MB。** 1回の範囲要求で取る量。
    ///
    /// - 小さすぎると要求の往復が増える（4.6GB を 1MB ずつなら 4,600 往復）
    /// - 大きすぎると**失敗したときに捨てる量が増える**。これは今回直している欠陥そのもの
    /// - 64MB なら 4.6GB で 72 往復、落ちても失うのは最大 64MB
    ///
    /// **`bytes(for:)` を使わない理由**: あれは1バイトずつの非同期反復なので、
    /// **4.6GB では46億回の `await` になる。** 進捗を細かく出せる代わりに、取得そのものが終わらない。
    static let sliceBytes: Int64 = 64 * 1024 * 1024

    /// `Range` で続きだけを落として追記する。**64MB ずつ。**
    ///
    /// **1切れごとにディスクへ書いて閉じる。** 途中で落ちても、
    /// **そこまでは `.incomplete` に残り、次回そこから継げる。**
    private static func append(
        from url: URL, to destination: URL, startingAt offset: Int64,
        expecting remote: RemoteFile, session: URLSession,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }

        var written = offset
        while written < remote.size {
            try Task.checkCancellation()

            let upper = min(written + sliceBytes, remote.size) - 1
            var request = URLRequest(url: url)
            request.setValue("bytes=\(written)-\(upper)", forHTTPHeaderField: "Range")

            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 206,
                http.statusCode != 200 {
                throw Failure.missingHeaders("HTTP \(http.statusCode)（206 を期待）")
            }

            // **書いてから数える。** 逆にすると、落ちたときに
            // 「書けていないバイトを書けたことにした」記録が残る。
            let handle = try FileHandle(forWritingTo: destination)
            try handle.seek(toOffset: UInt64(written))
            try handle.write(contentsOf: data)
            try handle.close()

            written += Int64(data.count)
            onProgress?(Progress(
                completedBytes: written, totalBytes: remote.size, resumedFromBytes: offset))

            // **1バイトも返ってこなかったら止める。** 進まないまま回り続けると、
            // 「無限に取得している」という別の事故になる（2026-09-05 の逆向きの欠陥と同じ形）。
            if data.isEmpty { break }
        }
    }

    /// symlink を張る。**既に正しいものが在れば触らない。**
    private static func linkIfNeeded(blob: URL, at link: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path),
            URL(fileURLWithPath: existing, relativeTo: link.deletingLastPathComponent())
                .standardizedFileURL.path == blob.standardizedFileURL.path {
            return
        }
        try? fm.removeItem(at: link)
        // **相対で張る。** ライブラリが張るものと同じ形にしておく
        // （キャッシュごと移動されても壊れない）。
        let relative = "../../blobs/\(blob.lastPathComponent)"
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: relative)
    }

    /// ファイルの sha256。**丸ごとメモリに載せない。**
    /// 4.6GB を `Data(contentsOf:)` で読むと、16GB機ではそれだけでスワップする。
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    static func repoID(from modelID: String) -> Repo.ID? {
        let parts = modelID.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        return Repo.ID(namespace: String(parts[0]), name: String(parts[1]))
    }
}
