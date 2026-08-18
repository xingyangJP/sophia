import Foundation

/// **1つの会話のあいだ、ツールの実行を引き受ける**（DESIGN.md 第16.8節）。
///
/// ---
///
/// # なぜ回数を数える側が実行も持つのか
///
/// > **往復には回数の上限を置くこと。** 上限が無いと、モデルがフォルダを延々と辿って
/// > 文脈と時間を食い潰す（16.8節）
///
/// 上限を「呼び出し側が気をつけて数える」形にすると、**数え忘れが必ずどこかで起きる。**
/// 生成の中断、失敗の再試行、別のターンからの呼び出し ── 数える場所が増えるほど漏れる。
/// **実行の口を1つにして、その口が数える。** 迂回するには実行層を直接呼ぶしかなく、
/// それは（テスト以外では）書く理由が無い形にしてある。
///
/// # なぜ actor なのか
///
/// ファイルの読み取りは同期の I/O である。**主スレッドで走らせないこと**（NFR-02）。
/// `@MainActor` の呼び出し元から `await` するだけで、実行は主スレッドから降りる。
/// 数（`callCount`）も同時に守られる ── 生成タスクとUIが同じ数を触っても壊れない。
///
/// # この型が持たないもの
///
/// | 持たないもの | どこの仕事か |
/// |---|---|
/// | `idle` / `armed` / `resolving`（FR-21） | 会話の状態。**引き金は利用者の操作だけ**（16.2節 / 16.6節 約束3） |
/// | フォルダを選ぶ・保存する・復元する | `FolderAccess`（`Sources/Files/`） |
/// | モデルとの往復そのもの | 推論側。ここは1回ぶんを実行して返すだけ |
///
/// **モデルの出力でここに新しい権限が生えることはない。**
/// 根は `init` で渡された1つだけで、差し替える口を持たない（16.6節 約束1・約束3）。
actor FolderToolRunner {

    /// この会話が読んでよいフォルダ。**差し替えられない**（`let`）。
    let folder: SecurityScopedFolder

    let limits: FolderToolExecution.Limits
    let budget: ContextBudget
    let counter: TokenCounter

    /// 1つの会話で許す呼び出し回数。
    ///
    /// > **【未確認 / 16.9節 項目8】この数字は測っていない。**
    /// > 「一覧 → 読む → もう1つ読む → 検索」で 4〜5回という見立てで 6 に置いただけである。
    /// > 足りなければモデルは途中で答えることになり、多すぎれば時間と文脈を食う。
    /// > **実使用で何回目に足りなくなるかを見てから動かすこと。**
    let callLimit: Int

    private(set) var callCount = 0

    init(
        folder: SecurityScopedFolder,
        limits: FolderToolExecution.Limits = .standard,
        budget: ContextBudget = .singleRead,
        counter: TokenCounter = .estimate,
        callLimit: Int = 6
    ) {
        self.folder = folder
        self.limits = limits
        self.budget = budget
        self.counter = counter
        self.callLimit = callLimit
    }

    /// 残り回数。16.7節の表示に使える。
    var remainingCalls: Int { max(callLimit - callCount, 0) }

    /// ツール1回を実行する。**上限を超えていたら実行しない。**
    ///
    /// ## 失敗した呼び出しも数える
    ///
    /// 名前を間違えた・パスが無かった呼び出しを数えないと、
    /// **同じ誤りを繰り返すモデルに対して上限が効かなくなる。**
    /// 「読めた回数」ではなく「往復した回数」を数えるのが 16.8節の意図である。
    func run(_ call: ToolCallRequest) -> ToolResult {
        guard callCount < callLimit else {
            return .rejected(.callLimitReached(callLimit), tool: call.name, counter: counter)
        }
        callCount += 1
        return FolderToolExecution.perform(
            call, in: folder, limits: limits, budget: budget, counter: counter)
    }

    /// 数を戻す。**新しい会話・新しい利用者の発言から往復を始めるときに呼ぶ。**
    ///
    /// 上限は「1回の質問に答えるまで」に効かせたいものであって、
    /// 会話を通じて一度しか読めない、という意味ではない。
    func resetCallCount() {
        callCount = 0
    }
}
