import Darwin
import Foundation

/// アプリ側が無条件に掛ける上限（DESIGN.md 第16.3節「切り捨てはアプリの仕事である」）。
///
/// > モデルに渡してから「長いので要約して」と言うのでは、
/// > **渡した時点でプリフィルを払い終えている**（16.3節）
///
/// ここにあるのは**バイトと件数の上限だけ**である。
/// **トークンの上限はここに置かない** ── 実トークナイザが要る話で、
/// `Sources/Context/` の担当である（16.3節の第1段）。この層は
/// 「文脈に入る前の生の材料」を、**桁で暴走しない大きさに**して渡すところまでを持つ。
enum FolderReadLimits {

    /// 一覧の既定の件数上限（16.4節「件数上限。超えたら切って総数を添える」）。
    static let entryLimit = 200

    /// 読み取りの既定の行数上限（16.4節の窓）。
    static let lineLimit = 200

    /// 1回の read で読むバイト数。
    static let chunkBytes = 64 * 1024

    /// **これを超えるファイルは開かない。**
    ///
    /// 行の総数を正しく数えるには最後まで走査する必要がある
    /// （`ReadOutcome.totalLines` は「必ず本当の総数」を要求している）。
    /// 走査自体は安いが、青天井にすると `read_file` 1回でアプリが数秒固まる。
    /// 64MB は「ログやソースなら確実に入り、動画やアーカイブは弾く」線として置いた。
    /// **根拠のある値ではない。実際に困ってから動かすこと。**
    static let maximumFileBytes = 64 * 1024 * 1024
}

/// 一覧の1件（16.4節 `list_directory`: 名前・種別・サイズ・更新日時）。
struct DirectoryEntry: Sendable, Equatable {

    /// **シンボリックリンクを「リンク」として見せる。**
    ///
    /// 実体を追った種別（リンク先がフォルダなら `.directory`）で見せると、
    /// **開こうとして封じ込めに落とされる理由が利用者にもモデルにも分からない。**
    /// 追える／追えないは 16.5節が決めることなので、一覧は事実だけを出す。
    enum Kind: String, Sendable, Equatable, CaseIterable {
        case file
        case directory
        case symbolicLink
        case other
    }

    /// 名前だけ（`notes.md`）。
    var name: String
    /// 根からの相対パス（`docs/notes.md`）。**そのまま次の呼び出しに渡せる形。**
    var relativePath: String
    var kind: Kind
    /// 通常ファイルのときだけ入る。
    var byteSize: Int?
    var modifiedAt: Date?
}

/// ディレクトリ1つの一覧。
struct DirectoryListing: Sendable, Equatable {

    /// 根からの相対パス。根そのものなら空文字。
    var path: String

    /// 返した分。**上限で切られていることがある。**
    var entries: [DirectoryEntry]

    /// **切る前の総数**（16.4節「超えたら切って総数を添える」）。
    ///
    /// 切ったことを黙っていると、モデルは「このフォルダには N 件しかない」と**断定する。**
    /// 切り捨てそのものより、切り捨てを隠すほうが害が大きい。
    var totalCount: Int

    var isTruncated: Bool { entries.count < totalCount }
}

/// ファイル1つを窓で読んだ結果（16.4節 `read_file`）。
///
/// **これは「文脈に入れる形」ではない。** トークン上限での切り詰めと見出しの付与は
/// `Sources/Context/` の `ReadOutcome` が持つ。ここが渡すのは
/// **正しい総数を添えた生の材料**である。
struct FileWindow: Sendable, Equatable {

    var path: String

    /// 窓に入った本文。行は `\n` で連結してある（`\r\n` の `\r` は落としてある）。
    var text: String

    /// 実際に入った最初の行（1始まり）。1行も入らなければ nil。
    var firstLine: Int?

    /// 実際に入った最後の行（1始まり・この行を含む）。1行も入らなければ nil。
    var lastLine: Int?

    /// **ファイル全体の行数。窓の大きさに関わらず本当の総数。**
    ///
    /// 走査を途中で打ち切って nil にする実装も考えたが、やめた ──
    /// **総数が無いと「全部読んだのか」を誰も判定できない。**
    /// それは 16.3節が「一番危ない」と名指ししている状態そのものである。
    var totalLines: Int

    /// ファイル全体のバイト数。
    var totalBytes: Int

    /// 窓がファイル全体を覆っているか。
    var isComplete: Bool {
        guard totalLines > 0 else { return true }
        return firstLine == 1 && lastLine == totalLines
    }
}

/// **読み取りだけを行う。**（DESIGN.md 第16章 / FR-19）
///
/// ---
///
/// # 書き込みの口をここに作らないこと
///
/// entitlement が `com.apple.security.files.user-selected.read-only` である以上、
/// 書き込みを実装しても OS が落とす（16.0節）。
/// **「動かないコードが残る」ではなく「境界が曖昧になる」のが問題である。**
/// FR-20 は承認フロー（16.6節の但し書き）を伴う別の章として起こすこと。
///
/// # 入口は `ContainedPath` 1つだけ
///
/// この型のどの関数も `String` のパスを受け取らない。**受け取れない。**
/// `ContainedPath` を作れるのは `FolderContainment` だけなので、
/// **検証を飛ばした読み取りは、書こうとしても書けない。**
enum FolderReader {

    // MARK: - 一覧（16.4節 list_directory）

    /// ディレクトリの直下を列挙する。**再帰しない。**
    ///
    /// - Parameter includingHidden: 既定では隠しファイルを出さない。
    ///   `.DS_Store` のような無意味な行に毎回トークンを払わないためであり、
    ///   同時に `.env` や `.ssh` を**モデルの目の前に置かない**ことでもある
    ///   （16.6節の被害を小さく保つ側の判断。**利用者が望むなら true にできる**）。
    static func list(
        _ path: ContainedPath,
        limit: Int = FolderReadLimits.entryLimit,
        includingHidden: Bool = false
    ) throws -> DirectoryListing {
        var isDirectory: ObjCBool = false
        let manager = FileManager.default
        guard manager.fileExists(atPath: path.url.path, isDirectory: &isDirectory) else {
            throw FolderAccessError.notFound(path.relativePath)
        }
        guard isDirectory.boolValue else {
            throw FolderAccessError.notADirectory(path.relativePath)
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
            .fileSizeKey, .contentModificationDateKey,
        ]
        var options: FileManager.DirectoryEnumerationOptions = []
        if !includingHidden { options.insert(.skipsHiddenFiles) }

        let urls: [URL]
        do {
            urls = try manager.contentsOfDirectory(
                at: path.url,
                includingPropertiesForKeys: keys,
                options: options
            )
        } catch {
            throw mapCocoaError(error, path: path.relativePath)
        }

        var entries = urls.map { url in entry(for: url, under: path, keys: Set(keys)) }

        // **順序を決めておくこと。** 上限で切る以上、順序が不定だと
        // 「同じフォルダを2回一覧して違う結果が返る」ことになり、
        // モデルは前の一覧を根拠に間違った断定をする。
        entries.sort { left, right in
            if (left.kind == .directory) != (right.kind == .directory) {
                return left.kind == .directory
            }
            let order = left.name.compare(right.name, options: [.caseInsensitive, .numeric])
            if order != .orderedSame { return order == .orderedAscending }
            // 大文字小文字だけが違う2件でも順序が決まるようにする。
            return left.name < right.name
        }

        let total = entries.count
        let kept = limit > 0 ? Array(entries.prefix(limit)) : entries
        return DirectoryListing(path: path.relativePath, entries: kept, totalCount: total)
    }

    private static func entry(
        for url: URL,
        under path: ContainedPath,
        keys: Set<URLResourceKey>
    ) -> DirectoryEntry {
        let values = try? url.resourceValues(forKeys: keys)
        let name = url.lastPathComponent

        let kind: DirectoryEntry.Kind
        if values?.isSymbolicLink == true {
            // **リンク判定を先に置くこと。** `isDirectory` はリンクを追った先を答えるので、
            // 順番を入れ替えると「フォルダ」に見えるリンクが出来る。
            kind = .symbolicLink
        } else if values?.isDirectory == true {
            kind = .directory
        } else if values?.isRegularFile == true {
            kind = .file
        } else {
            kind = .other
        }

        let relative = path.relativePath.isEmpty ? name : path.relativePath + "/" + name
        return DirectoryEntry(
            name: name,
            relativePath: relative,
            kind: kind,
            byteSize: kind == .file ? values?.fileSize : nil,
            modifiedAt: values?.contentModificationDate
        )
    }

    // MARK: - 読み取り（16.4節 read_file）

    /// テキストを**窓で**読む。全文は返さない（16.3節）。
    ///
    /// - Parameters:
    ///   - offset: 何行目から（**1始まり**）。
    ///   - limit: 何行ぶん。
    ///
    /// ## 走査は最後まで行く（窓が埋まっても止めない）
    ///
    /// 窓が埋まった時点で読むのをやめれば速いが、**総行数が分からなくなる。**
    /// 総数の無い戻り値は「全部読んだ」と見分けが付かず、16.3節が
    /// 「一番危ない」と名指しした状態を作る。**速さより、嘘をつかないことを取る。**
    /// 代わりに `FolderReadLimits.maximumFileBytes` で上端を抑えてある。
    static func readText(
        _ path: ContainedPath,
        offset: Int = 1,
        limit: Int = FolderReadLimits.lineLimit
    ) throws -> FileWindow {
        let descriptor = try openRegularFile(at: path)
        defer { close(descriptor) }

        // **開いた後の fd で種別と大きさを確かめる。**
        // 開く前に `resourceValues` で見ても、開くまでの間に差し替えられる余地が残る。
        // fd に対する fstat なら、いま実際に開いているものを見ている。
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw FolderAccessError.ioFailed(
                path: path.relativePath, detail: describeErrno(errno))
        }
        guard (UInt16(status.st_mode) & UInt16(S_IFMT)) == UInt16(S_IFREG) else {
            throw FolderAccessError.notAFile(path.relativePath)
        }
        let totalBytes = Int(status.st_size)
        guard totalBytes <= FolderReadLimits.maximumFileBytes else {
            throw FolderAccessError.fileTooLarge(path: path.relativePath, totalBytes: totalBytes)
        }

        let firstWanted = max(1, offset)
        let wantedCount = limit > 0 ? limit : FolderReadLimits.lineLimit

        var buffer = [UInt8](repeating: 0, count: FolderReadLimits.chunkBytes)
        var pending: [UInt8] = []
        var collected: [[UInt8]] = []
        var completedLines = 0
        var sawNulByte = false

        reading: while true {
            let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
                read(descriptor, raw.baseAddress, FolderReadLimits.chunkBytes)
            }
            if readCount < 0 {
                // EINTR は失敗ではない（シグナルで割り込まれただけ）。**握って読み直す。**
                // ここで throw すると、無関係なシグナル1つで読み取りが落ちる。
                if errno == EINTR { continue }
                throw FolderAccessError.ioFailed(
                    path: path.relativePath, detail: describeErrno(errno))
            }
            if readCount == 0 { break }

            for index in 0..<readCount {
                let byte = buffer[index]
                if byte == 0 {
                    // **NUL を含むものはテキストではない**（16.8節）。
                    // 中身を1バイトも返さずに打ち切る。
                    sawNulByte = true
                    break reading
                }
                if byte == 0x0A {
                    completedLines += 1
                    if completedLines >= firstWanted, collected.count < wantedCount {
                        collected.append(pending)
                    }
                    pending.removeAll(keepingCapacity: true)
                } else {
                    // 行の区切りはバイトで見てよい。UTF-8 は多バイト文字の途中に
                    // 0x0A / 0x00 を置かないので、**復号する前に切っても壊れない。**
                    pending.append(byte)
                }
            }
        }

        if sawNulByte {
            throw FolderAccessError.binaryFile(path: path.relativePath, totalBytes: totalBytes)
        }

        // 最終行に改行が無い場合も1行として数える。
        if !pending.isEmpty {
            completedLines += 1
            if completedLines >= firstWanted, collected.count < wantedCount {
                collected.append(pending)
            }
        }

        var bytes: [UInt8] = []
        for (index, line) in collected.enumerated() {
            if index > 0 { bytes.append(0x0A) }
            // CRLF の `\r` は落とす。残すとモデルの文脈に見えないゴミが1行ごとに増える。
            if line.last == 0x0D {
                bytes.append(contentsOf: line.dropLast())
            } else {
                bytes.append(contentsOf: line)
            }
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw FolderAccessError.notUTF8(path.relativePath)
        }

        return FileWindow(
            path: path.relativePath,
            text: text,
            firstLine: collected.isEmpty ? nil : firstWanted,
            lastLine: collected.isEmpty ? nil : firstWanted + collected.count - 1,
            totalLines: completedLines,
            totalBytes: totalBytes
        )
    }

    // MARK: - 低レベル

    /// **`O_NOFOLLOW` で開く。**
    ///
    /// `ContainedPath` は正準化を通っているので、**最後の成分はリンクではない**はずである。
    /// にもかかわらずリンクだったなら、それは
    /// **検証してから開くまでの間に差し替えられた**ということ（TOCTOU）。
    /// カーネルが ELOOP で落としてくれるので、そのまま `.pathChangedDuringAccess` にする。
    ///
    /// `O_NONBLOCK` も付ける。通常ファイルには影響しないが、
    /// 万一 FIFO に差し替えられていたときに**書き手が現れるまで永久に待つ**のを防ぐ。
    /// 16.8節に「アプリが固まる」という失敗は書かれていないが、
    /// **書かれていない失敗を作らないのがこの層の仕事である。**
    private static func openRegularFile(at path: ContainedPath) throws -> Int32 {
        var failure: Int32 = 0
        let descriptor = path.url.withUnsafeFileSystemRepresentation { representation -> Int32 in
            guard let representation else { return -1 }
            let result = open(representation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            if result < 0 { failure = errno }
            return result
        }
        guard descriptor >= 0 else {
            throw mapErrno(failure, path: path.relativePath)
        }
        return descriptor
    }

    private static func mapErrno(_ code: Int32, path: String) -> FolderAccessError {
        switch code {
        case ENOENT, ENOTDIR:
            .notFound(path)
        case EACCES, EPERM:
            .accessDenied(path)
        case ELOOP:
            .pathChangedDuringAccess(path)
        case EISDIR:
            .notAFile(path)
        default:
            .ioFailed(path: path, detail: describeErrno(code))
        }
    }

    private static func describeErrno(_ code: Int32) -> String {
        "errno \(code): \(String(cString: strerror(code)))"
    }

    private static func mapCocoaError(_ error: any Error, path: String) -> FolderAccessError {
        let nsError = error as NSError
        switch nsError.code {
        case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
            return .notFound(path)
        case NSFileReadNoPermissionError:
            return .accessDenied(path)
        default:
            // `localizedDescription` を使わないこと（`StoreFailure.describe` と同じ理由）。
            // 中身の無い「操作を完了できませんでした」になる。
            return .ioFailed(path: path, detail: "\(nsError.domain) \(nsError.code)")
        }
    }
}
