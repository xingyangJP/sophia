import Foundation

// =============================================================================
//  ツール層と推論層の継ぎ目（FR-19 / DESIGN.md 第16章 / NFR-09）
// -----------------------------------------------------------------------------
//  **この1ファイルだけが、両方の型を見る。**
//
//  | 層 | このファイルが橋渡ししているもの |
//  |---|---|
//  | 推論側（`Shared/`） | `ToolExecuting` / `ModelToolCall` / `ToolExecutionOutcome` |
//  | ツール側（ここ） | `FolderToolRunner` / `ToolCallRequest` / `ToolResult` |
//
//  `MLXEngine` は `FolderToolRunner` も `SecurityScopedFolder` も `ToolResult` も
//  **1文字も書かない。** 逆にツール層は `MLXLMCommon` を import しない。
//  癒着させると、エンジンを差し替えた瞬間に実行役ごと作り直しになる（NFR-09）。
//
//  ## 詰め替えているだけで、判断はしていない
//
//  ここに `if` を足したくなったら、まず**どちらの層の判断なのか**を決めること。
//  往復の上限は `FolderToolRunner`、封じ込めは `FolderContainment`、
//  文脈の上限は `ContextWindow` が既に持っている。
//  **この層に判断が生えた時点で、それは2か所目の判断である。**
// =============================================================================

/// `FolderToolRunner` を、推論層から見える形にする（`Shared/InferenceEngine.swift`）。
///
/// ## `actor` のまま conform できる
///
/// protocol 側の要求が `async` なので、actor 隔離のメソッドがそのまま witness になる。
/// **`nonisolated` にしないこと** ── 外したら `callCount` が隔離の外に出て、
/// 「数える場所を1つにする」という `FolderToolRunner` の唯一の仕事が壊れる。
extension FolderToolRunner: ToolExecuting {

    /// 新しい利用者の発言。**回数を戻す**（`resetCallCount` の型コメント）。
    func beginRoundTrip() async {
        resetCallCount()
    }

    /// 1回ぶん実行する。**throw しない**（16.8節）。
    ///
    /// `ModelToolCall` → `ToolCallRequest` の変換は `Tools` 側が用意した口
    /// （`init(name:jsonArguments:)`）をそのまま使う。**引数の解釈をここに書かないこと** ──
    /// `ToolArguments` が「`{"path": 5}` を `"5"` と読まない」等の判断を既に持っている。
    func execute(_ call: ModelToolCall) async -> ToolExecutionOutcome {
        let request = ToolCallRequest(name: call.name, jsonArguments: call.argumentsData)
        return run(request).executionOutcome(callID: call.callID)
    }
}

extension ToolResult {

    /// **これ以上ツールを渡してはいけないか。**
    ///
    /// `true` になるのは往復の上限に達したときだけである。
    /// 読めなかった（`.failure`）・名前が違った（`.unknownTool`）は**続けてよい** ──
    /// 16.8節は「往復を1回で打ち切らない」と決めており、
    /// モデルは戻り値を読んで次の手（一覧を取る、綴りを直す）を打てる。
    ///
    /// **網羅 switch で書いてある。** ケースが増えたときに
    /// 「続けてよいのか止めるのか」を必ず1度考えさせるためで、
    /// `default:` を置くと新しい失敗が黙って「続けてよい」側に落ちる。
    var stopsRoundTrips: Bool {
        switch kind {
        case .read, .listing, .failure:
            return false
        case .rejected(let rejection):
            switch rejection {
            case .callLimitReached:
                return true
            case .unknownTool, .missingArgument:
                return false
            }
        }
    }

    /// 推論層へ渡す形へ詰め替える。
    ///
    /// **文字列を組み直さない。** `contextText` も `bookmarkLine` も
    /// 「上限に収まるかを測った当の文字列」であり（`ReadOutcome.contextText`）、
    /// ここで1文字でも足したら、測った値と入れる値が別物になる。
    func executionOutcome(callID: String?) -> ToolExecutionOutcome {
        ToolExecutionOutcome(
            toolName: toolName,
            callID: callID,
            responseText: contextText,
            summaryLine: bookmarkLine,
            isFailure: isFailure,
            stopsRoundTrips: stopsRoundTrips)
    }
}
