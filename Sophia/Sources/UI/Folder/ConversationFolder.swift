import Foundation
import Observation

/// **この会話にフォルダが結び付いているか**（FR-19 / FR-21 / DESIGN.md 第16.2節・16.7節・16.8節）。
///
/// ---
///
/// # ここが `idle` / `armed` の唯一の出所である
///
/// 16.2節は状態を3つ（`idle` / `armed` / `resolving`）で説明しているが、
/// **enum は置いていない。** `ChatOptions` の型コメントが理由を書いている ──
///
/// > `idle` / `armed` / `resolving` の enum をこの型に足さないこと。
/// > **真実の出所が2つになり、必ず食い違う**（`.armed` なのに配列が空、など）
///
/// 同じ理屈がここにも効く。**状態は「フォルダが結び付いているか」1つに潰してある** ──
/// `FolderAccess.folder` が nil かどうかがそのまま `idle` / `armed` である。
/// 派生する値（`toolDefinitions` / `toolDefinitionTokens`）は
/// **すべてそこから計算する。** 別に持たない。
///
/// `resolving`（往復の最中）を持っていないのは、**往復がエンジンの中で閉じている**
/// からである（`InferenceEngine` の約束事9）。UI から見ると `armed` のまま1ターンが終わる。
///
/// # 引き金は利用者の操作だけ（16.6節 約束3）
///
/// 上がる（`idle` → `armed`）のは `choose()` と `restoreOnLaunch()` だけ、
/// 下がるのは `forget()` と `detach(...)` だけである。
/// **モデルの出力から呼ばれる経路はどこにも無い** ── `Chunk` を受けるのは
/// `ChatViewModel` で、そこから届くのは「失敗した」という事実だけであり、
/// 失敗の原因を決めるのは**ディスクを実際に読み直した結果**（`verifyBinding()`）である。
///
/// # この型が持たないもの
///
/// | 持たないもの | どこの仕事か |
/// |---|---|
/// | フォルダを選ぶ・保存する・復元する・読む | `FolderAccess`（`Sources/Files/`）。**読むだけにして、そのまま使う** |
/// | ツールの定義そのもの | `FolderTool.definitions`（`Sources/Tools/`）。**写さないこと** |
/// | 往復の実行と回数 | `FolderToolRunner`。差し込みは `ChatViewModel` |
@MainActor @Observable
final class ConversationFolder {

    /// 選ぶ・保存する・復元する・読む。**この型は入口を1つも増やさない。**
    /// `private let` なので `@Observable` の追跡対象にはならないが、
    /// `folder` を読んだ時点で `FolderAccess` 側の追跡に乗る（透過する）。
    private let access: FolderAccess

    /// 自動で外したときの知らせ（16.8節）。**利用者が次に何をすればよいかまで書く。**
    private(set) var notice: Notice?

    /// フォルダを選ぶ操作が走っている間 true。パネルは modal なので実際には一瞬だが、
    /// **二重に開かせない**ためだけに持つ。
    private(set) var isChoosing = false

    init(access: FolderAccess = FolderAccess()) {
        self.access = access
    }

    // MARK: - 見せるもの（16.7節）

    /// いま結び付いているフォルダ。nil なら `idle`。
    var folder: SecurityScopedFolder? { access.folder }

    /// **`armed` か。** 16.2節の状態はこの1つの真偽値に潰してある。
    var isArmed: Bool { access.folder != nil }

    /// チップに出す名前。
    var displayName: String? { access.folder?.displayName }

    /// チップの補足に出す絶対パス。**解決後の値**（16.6節の但し書き）。
    var displayPath: String? { access.folder?.displayPath }

    // MARK: - FR-21 の実体

    /// **このターンでモデルに見せるツールの定義。**
    ///
    /// > **`ChatOptions.tools` を埋めてよいのはここだけである。**
    ///
    /// `idle` では**必ず空配列**を返す ── テンプレートの `{%- if tools %}` が開かず、
    /// ツールの system ブロックは1文字も描画されない（16.1節 / 16.2節）。
    /// つまり FR-21 は「気をつけて実装する」種類の約束ではなく、
    /// **この計算プロパティが空を返すかどうか**である。
    ///
    /// **定義をここに書き写さないこと。** 出所は `FolderTool.definitions` 1本である
    /// （写した瞬間、実測は実装ではなく写しを測る ── 2026-08-18 に2回起きている）。
    var toolDefinitions: [ToolDefinition] {
        isArmed ? FolderTool.definitions : []
    }

    /// **いま毎ターン払っている額**（16.7節「見えないと FR-21 は形骸化する」）。
    /// `idle` では 0 である ── そしてそれは推定ではなく、実測で 0 と確認されている
    /// （`EngineToolWiringTests.testToolDefinitionTokenCost`: `idle == baseline`）。
    var toolDefinitionTokens: Int {
        isArmed ? SophiaDefaults.toolDefinitionTokens : 0
    }

    /// 入力予算に対する割合（%）。**32% という数字を画面で言い切るための計算。**
    var toolDefinitionBudgetPercent: Int {
        guard SophiaDefaults.inputTokenBudget > 0 else { return 0 }
        return Int(
            (Double(SophiaDefaults.toolDefinitionTokens)
                / Double(SophiaDefaults.inputTokenBudget) * 100).rounded())
    }

    // MARK: - 利用者の操作（引き金はここだけ）

    /// フォルダを選ばせて結び付ける。**キャンセルは異常ではない。**
    func choose() {
        guard !isChoosing else { return }
        isChoosing = true
        defer { isChoosing = false }

        notice = nil
        do {
            // **戻り値の nil はキャンセルである。異常ではない**（`FolderAccess` の約束）。
            // 何も起きなかったことにする ── 「選ばなかった」に知らせを出さない。
            _ = try access.chooseFolder()
        } catch let error as FolderAccessError {
            // 選んだ直後に失敗するのは、権限かブックマークの取得に失敗した場合である。
            // **結び付いていないので外すものは無い。** 理由だけを出す。
            notice = Notice(from: error.sophiaError, kind: .failedToBind)
        } catch {
            notice = Notice(from: SophiaError.wrap(error), kind: .failedToBind)
        }
    }

    /// 利用者が自分で外した。**知らせは出さない**（自分でやったことなので）。
    func forget() {
        access.forgetFolder()
        notice = nil
    }

    /// 知らせを閉じる。
    func dismissNotice() {
        notice = nil
    }

    // MARK: - 起動時の復元（機能3）

    /// 前回のフォルダを復元し、**いまも読めるかを確かめる。**
    ///
    /// 復元だけでは足りない。`FolderAccess.restoreSavedFolder()` は
    /// ブックマークが解けたかどうかしか見ておらず、**解けたのに読めない**
    /// （権限が外れた・中身が入れ替わった）場合は true を返す。
    /// そのまま `armed` にすると、**チップは出ているのに読めない**会話になり、
    /// 利用者は毎ターン 322トークン払いながら「なぜか答えられない」を見ることになる。
    func restoreOnLaunch() async {
        guard access.restoreSavedFolder() else { return }
        await verifyBinding()
    }

    // MARK: - 失敗の扱い（16.8節）

    /// **結び付いたフォルダがいまも読めるかを、実際に読んで確かめる。**
    ///
    /// 読むのは 1件だけ（`limit: 1`）である ── 中身が要るのではなく、
    /// **根に手が届くか**だけを見ている。読めなければ 16.8節どおり結び付けを外す。
    ///
    /// ## なぜ「モデルが失敗した」だけでは外さないのか
    ///
    /// 往復の失敗には**外してはいけないもの**が混ざっている。
    /// 「そのファイルは無い」「ルートの外を要求した」は**フォルダが壊れたのではなく、
    /// モデルが外した**のであって、利用者が選び直しても何も直らない
    /// （`FolderAccessError.make(_:_:_:code:)` の但し書きが同じことを言っている）。
    ///
    /// **だから原因はここで判定する。** モデルの失敗は引き金にすぎず、
    /// 外すかどうかを決めるのは**ディスクを読み直した結果の `SophiaError.Code`** である。
    func verifyBinding() async {
        guard isArmed else { return }
        do {
            _ = try await access.list("", limit: 1)
        } catch let error as FolderAccessError {
            receive(error.sophiaError)
        } catch {
            // 種別が分からないものでは外さない。**分からないときに壊すほうを選ばない。**
        }
    }

    /// **`SophiaError` を受けて、結び付けに関わるものだけを処理する**（16.8節）。
    ///
    /// | `code` | どうするか | 利用者が次にすること |
    /// |---|---|---|
    /// | `.folderUnavailable` | **外す** | 移動先を**探して**選び直す |
    /// | `.folderAccessDenied` | **外す** | **同じフォルダ**をもう一度選ぶ（権限を取り直す） |
    /// | それ以外（封じ込めの拒否を含む） | **何もしない** | ─ |
    ///
    /// 上2つは 16.8節がどちらも「結び付けを外し、選び直しを促す。会話は続行する」と
    /// 決めている。**分けてあるのは文言である** ── 「在るのに読めない」と
    /// 「移動・削除・改名された」では、利用者が取る行動が違う。
    /// 前者に「移動したようです」と言うと、**在るものを探しに行かせる**ことになる。
    ///
    /// - Returns: 結び付けに関わる失敗だったか。false ならこの型は何もしていない。
    @discardableResult
    func receive(_ error: SophiaError) -> Bool {
        switch error.code {
        case .folderUnavailable:
            detach(kind: .unavailable, error: error)
            return true
        case .folderAccessDenied:
            detach(kind: .accessDenied, error: error)
            return true
        default:
            // **封じ込めの拒否（`.unknown`）をここへ落とさないこと。**
            // あれは「フォルダが壊れた」ではなく「モデルが範囲外を要求したので
            // アプリが止めた」であり、選び直しても何も直らない。
            return false
        }
    }

    private func detach(kind: Notice.Kind, error: SophiaError) {
        // **外す前に名前を控える。** 外した後では「どのフォルダの話か」が言えなくなる。
        let name = access.folder?.displayName
        let path = access.folder?.displayPath
        access.forgetFolder()
        notice = Notice(from: error, kind: kind, folderName: name, folderPath: path)
    }

    // MARK: - 知らせ

    /// 自動で外したこと、または結び付けに失敗したことの知らせ（FR-11 / 16.8節）。
    ///
    /// **`SophiaError` をそのまま抱えない。** 抱えると、外した理由の文言が
    /// エンジン由来のエラー表示（`TurnView.errorRow`）と同じ見た目になり、
    /// 「生成が失敗した」と読めてしまう。ここは失敗の報告ではなく**状態の変化の報告**である。
    struct Notice: Identifiable, Equatable {

        enum Kind: Equatable {
            /// 移動・削除・改名された（`.folderUnavailable`）。
            case unavailable
            /// 在るのに読めない（`.folderAccessDenied`）。
            case accessDenied
            /// 選んだが結び付けられなかった。**外すものは無い。**
            case failedToBind
        }

        let id = UUID()
        let kind: Kind
        /// 何が起きたか。**日本語**。
        let message: String
        /// 次に何をすればよいか。**日本語**。
        let hint: String?
        /// 開発者向けの原文（`SophiaError.detail`）。画面には出さない。
        let detail: String?

        /// 結び付けが外れたことによる知らせか。ボタンの文言を変えるために使う。
        var didDetach: Bool { kind != .failedToBind }

        init(
            from error: SophiaError, kind: Kind,
            folderName: String? = nil, folderPath: String? = nil
        ) {
            self.kind = kind
            self.detail = error.detail

            let target = folderName.map { "「\($0)」" } ?? "フォルダ"
            switch kind {
            case .unavailable:
                // **「在る」と言わないこと。** 探しに行くのが正しい行動である。
                self.message = "\(target)が見つからないため、結び付けを外しました。"
                self.hint =
                    "移動・削除・改名されたようです。"
                    + (folderPath.map { "元の場所は \($0) でした。" } ?? "")
                    + "移動先のフォルダを選び直してください。会話はそのまま続けられます。"
            case .accessDenied:
                // **「探してください」と言わないこと。** フォルダは在る。
                self.message = "\(target)を読む権限が失われたため、結び付けを外しました。"
                self.hint =
                    "フォルダはありますが、いまは読めません。"
                    + (folderPath.map { "\($0) を" } ?? "同じフォルダを")
                    + "もう一度選ぶと、権限を取り直せます。会話はそのまま続けられます。"
            case .failedToBind:
                self.message = error.message
                self.hint = error.hint
            }
        }
    }
}
