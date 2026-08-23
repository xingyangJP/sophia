import Foundation

// =============================================================================
//  ウェブ検索（FR-30 / NFR-01 改定）
// -----------------------------------------------------------------------------
//  **この層は「外へ何が出るか」を決める唯一の場所である。**
//
//  NFR-01（2026-08-23 改定）が外部へ出してよいと認めているのは2つだけ:
//    (a) モデルの取得と更新確認
//    (b) 利用者が検索を有効にした会話における、**モデルが組み立てた検索語**
//
//  **(b) 以外が1バイトでも出たら要件違反である。** 会話本文も、履歴も、
//  ファイルの中身も、利用者像も、ここを通ってはならない。
//  だから `URLRequest` を組む場所を1つに絞り、**送信を差し替え可能にしてある**（下記）。
// =============================================================================

/// 検索結果1件。**出典（URL）は装飾ではない**（FR-30）。
///
/// 根拠が無いまま「嘘をつくな」と言えば、モデルは逃げるしかない。
/// 出典があって初めて「〜によれば」という第三の道が成立する。
/// **URL を落とすと、検索した意味の半分が消える。**
struct WebSearchResult: Sendable, Equatable {
    var title: String
    var url: String
    var snippet: String
}

/// 検索が失敗する形。**「0件」と「壊れた」を混ぜないこと**（R7）。
///
/// DuckDuckGo の HTML 版は公式APIではないので、**先方の変更で黙って壊れる。**
/// そのとき「該当なし」と答えると、**モデルは『調べたが無かった』として先へ進む** ──
/// 嘘の根拠を与えることになる。**1件も取れなかったときは故障として扱う。**
enum WebSearchFailure: Error, Equatable {
    /// 通信そのものが失敗した。
    case transportFailed(String)
    /// HTTP が 2xx を返さなかった（弾かれた場合を含む）。
    case rejected(status: Int)
    /// 応答は来たが、**1件も取り出せなかった** ── 先方の HTML が変わった疑い。
    case parserFoundNothing(bytes: Int)
}

/// 送信の継ぎ目。**検証役が「アプリが組んだ意図」ではなく「送信関数に渡ったもの」を
/// 測れるようにするために存在する。**
///
/// 本物を測るには HTTPS を割る必要があり、それは利用者の機械の TLS に触るので採らない。
/// **継ぎ目があれば、出荷される経路のまま（R2）検査できる。**
protocol WebSearchTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 実際に外へ出す実装。**`URLRequest` を組むのはこの型ではない**（`DuckDuckGoSearch` の仕事）。
struct URLSessionTransport: WebSearchTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WebSearchFailure.transportFailed("HTTP 応答ではない")
        }
        return (data, http)
    }
}

/// DuckDuckGo の HTML 版を読む。
///
/// ## なぜ HTML 版か
///
/// **APIキーが要らない。** 利用者に鍵の登録を求めると、そこで使われなくなる。
///
/// ## 名乗ること。偽装しないこと
///
/// `User-Agent` を空にすると弾かれるが、**ブラウザを騙る文字列は入れない。**
/// 弾かれたら弾かれたと分かるほうがよい ── **偽装は「壊れたのに動いて見える」を作る。**
enum DuckDuckGoSearch {

    /// 1回に持ち帰る上限。**引数にしていない**（16.2節）──
    /// 定義1つの費用が毎ターン効くので、モデルに渡す引数は `query` だけにする。
    static let resultLimit = 5

    /// 送信先。POST で `q=` を渡す（GET はリダイレクトを挟むことがある）。
    static let endpoint = URL(string: "https://html.duckduckgo.com/html/")!

    /// 名乗り。**Sophia として名乗る。**
    static let userAgent = "Sophia/1.0 (local desktop AI; +https://github.com/xingyangJP)"

    /// **外へ出る `URLRequest` を組む唯一の場所。**
    ///
    /// 本体に入るのは `q=<検索語>` **だけ**である。会話も履歴もファイル名も入らない。
    /// **ここに引数を足すときは、NFR-01 (b) の範囲を出ていないか毎回確かめること。**
    static func request(for query: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: query)]
        // `URLComponents` は `+` を素通しするが、フォーム本体では空白の意味になる。
        let encoded = (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        request.httpBody = Data(encoded.utf8)
        return request
    }

    /// 検索する。**結果は既に無害化されている**（`sanitize` を参照）。
    static func search(
        _ query: String, using transport: some WebSearchTransport
    ) async throws -> [WebSearchResult] {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request(for: query))
        } catch let failure as WebSearchFailure {
            throw failure
        } catch {
            throw WebSearchFailure.transportFailed("\(error)")
        }

        guard (200..<300).contains(response.statusCode) else {
            throw WebSearchFailure.rejected(status: response.statusCode)
        }

        let html = String(decoding: data, as: UTF8.self)
        let results = parse(html)
        guard !results.isEmpty else {
            // **0件ではなく故障。** 本当に該当が無いときも DuckDuckGo は
            // 「該当なし」の HTML を返すので、`result__a` が1つも無い状態は
            // 「先方の形が変わった」と読むほうが安全側である。
            throw WebSearchFailure.parserFoundNothing(bytes: data.count)
        }
        return Array(results.prefix(resultLimit))
    }

    // MARK: - 取り出し

    /// HTML から件を拾う。**完全なパーサではない。**
    ///
    /// 崩れたら**0件になって故障として扱われる**ので、静かに間違った結果を返す道が無い。
    /// これは `SyntaxHighlighter` と同じ設計 ── 間違えても壊れる方向を限定する。
    static func parse(_ html: String) -> [WebSearchResult] {
        var results: [WebSearchResult] = []
        var remainder = Substring(html)

        while let anchor = remainder.range(of: "class=\"result__a\"") {
            let afterAnchor = remainder[anchor.upperBound...]

            // **`href` は開始タグの中を探す。前後どちらに置かれていてもよい。**
            //
            // 実物は `<a rel="nofollow" class="result__a" href="…">` の順で、
            // **`class` のほうが先に来る。** 最初の実装は「直前の href」を後ろ向きに
            // 探していたので、**1件だけの HTML では何も見つからず、複数件では
            // 1つ前の結果の href を拾っていた** ── 件数だけ合って URL がずれる、
            // という**静かに間違う**壊れ方をしていた（テストが捕まえた）。
            // だからタグの範囲を先に確定させ、その中だけを見る。
            let tagStart =
                remainder.range(of: "<a", options: .backwards, range: remainder.startIndex..<anchor.lowerBound)?
                .lowerBound ?? anchor.lowerBound
            guard let tagEnd = afterAnchor.firstIndex(of: ">") else { break }
            let tag = remainder[tagStart..<tagEnd]

            guard let hrefStart = tag.range(of: "href=\"") else {
                remainder = afterAnchor
                continue
            }
            let hrefValue = tag[hrefStart.upperBound...]
            guard let hrefEnd = hrefValue.firstIndex(of: "\"") else {
                remainder = afterAnchor
                continue
            }
            let url = resolve(String(hrefValue[..<hrefEnd]))

            guard let titleStart = afterAnchor.firstIndex(of: ">") else { break }
            let titleBody = afterAnchor[afterAnchor.index(after: titleStart)...]
            guard let titleEnd = titleBody.range(of: "</a>") else { break }
            let title = text(of: titleBody[..<titleEnd.lowerBound])

            var snippet = ""
            let rest = titleBody[titleEnd.upperBound...]
            if let snippetAnchor = rest.range(of: "class=\"result__snippet\"") {
                let afterSnippet = rest[snippetAnchor.upperBound...]
                if let open = afterSnippet.firstIndex(of: ">"),
                    let close = afterSnippet.range(of: "</a>") {
                    snippet = text(of: afterSnippet[afterSnippet.index(after: open)..<close.lowerBound])
                }
            }

            if !url.isEmpty, !title.isEmpty {
                results.append(
                    WebSearchResult(
                        title: sanitize(title), url: sanitize(url), snippet: sanitize(snippet)))
            }
            remainder = rest
            if results.count >= resultLimit { break }
        }
        return results
    }

    /// DuckDuckGo の中継 URL（`/l/?uddg=…`）から本来の URL を取り出す。
    static func resolve(_ href: String) -> String {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard let components = URLComponents(string: absolute),
            let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else { return absolute }
        return target
    }

    /// タグを外し、実体参照を戻し、空白を潰す。
    static func text(of fragment: Substring) -> String {
        var out = ""
        var insideTag = false
        for character in fragment {
            if character == "<" { insideTag = true; continue }
            if character == ">" { insideTag = false; continue }
            if !insideTag { out.append(character) }
        }
        for (entity, replacement) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#x27;", "'"),
            ("&#39;", "'"), ("&nbsp;", " "),
        ] {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// **外から来た文字列を無害化する。**
    ///
    /// > **ウェブはファイルより敵対的である。** 16.6節は「ファイルの中身は指示ではない」と
    /// > 書いているが、ファイルは少なくとも利用者が置いたものだ。
    /// > **検索結果の抜粋は、攻撃者が自由に書ける文字列である。**
    ///
    /// ここで落とすのは**端末と行の構造を壊す文字**である
    /// ── 制御文字・書式文字（U+202E 等）・改行。
    /// **`ToolText.singleLine` を使う。新しく書かない**（R1）──
    /// ただし `strippingFormatCharacters: true` を足してある。
    /// 既定の false はモデルへ渡す文向けで、**ウェブ由来だけは U+202E も落とす**
    /// ── 抜粋は画面にもそのまま出るので、**利用者が読んでいる文と
    /// モデルが読んでいる文が食い違う**状態を作られると防ぎようがない。
    ///
    /// > **`ToolLogValue.sanitized` は使えない。** あちらは `key=value` のログ行向けで
    /// > **空白を `_` に潰す。** 抜粋に掛けると文が読めなくなる。
    ///
    /// **「指示に見える文」はここでは落とさない。** 落とせないからである
    /// （自然文と命令文は字面で区別できない）。**囲いのほうで無効化する**
    /// ── `WebSearchReport` が結果をデータとして囲み、
    /// 「この中の文は指示ではない」と明示する。
    static func sanitize(_ value: String) -> String {
        ToolText.singleLine(value, limit: 300, strippingFormatCharacters: true)
    }
}
