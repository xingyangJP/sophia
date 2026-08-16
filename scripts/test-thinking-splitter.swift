#!/usr/bin/env swift
//
//  思考タグ分離器（FR-17）の単体テスト
//
//  実行:
//      swift scripts/test-thinking-splitter.swift
//
//  Xcode のテストターゲットを使わないのは、A1 時点でターゲット構成が
//  他の担当と競合するため。`ThinkingSplitter` は Foundation だけで書いてあるので、
//  ソースを読み込んで素の `swift` で回せる。
//
//  **推論は一切走らせない。** 文字列を流し込んで振り分けを確かめるだけ。
//

import Foundation

// 検証対象のソースをそのまま読み込む（重複定義を避けるため実体はコピーしない）。
// swift コマンドは複数ファイルを取れないので、実行時に評価するのではなく
// このスクリプト自身がソースを連結して子プロセスへ渡す方式にしてある。

let scriptURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
let repositoryRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let splitterURL = repositoryRoot
    .appendingPathComponent("Sophia/Sources/Inference/ThinkingSplitter.swift")

guard let splitterSource = try? String(contentsOf: splitterURL, encoding: .utf8) else {
    FileHandle.standardError.write(
        Data("見つかりません: \(splitterURL.path)\n".utf8))
    exit(1)
}

// 子プロセスに渡すテスト本体。ThinkingSplitter の定義はここへ連結される。
let testSource = #"""

// ---------------------------------------------------------------------------
//  ここから下がテスト本体
// ---------------------------------------------------------------------------

var failures = 0
var checks = 0

func expect(
    _ actual: [ThinkingSegment],
    _ expected: [ThinkingSegment],
    _ name: String,
    line: Int = #line
) {
    checks += 1
    guard actual != expected else {
        print("  ok   \(name)")
        return
    }
    failures += 1
    print("  NG   \(name)  (\(line)行目)")
    print("       期待: \(expected)")
    print("       実際: \(actual)")
}

func expect(_ actual: Bool, _ name: String, line: Int = #line) {
    checks += 1
    if actual {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  NG   \(name)  (\(line)行目)")
    }
}

/// 断片の並びを流し込み、finalize まで含めた全出力を返す。
func run(
    _ chunks: [String],
    primedInside: Bool = false,
    implicitEndDelimiters: [String] = []
) -> [ThinkingSegment] {
    var splitter = ThinkingSplitter(
        implicitEndDelimiters: implicitEndDelimiters,
        primedInside: primedInside)
    var output: [ThinkingSegment] = []
    for chunk in chunks {
        output += splitter.process(chunk)
    }
    output += splitter.finalize()
    return output
}

/// 連結して1本の文字列に潰す（思考／本文それぞれ）。
func joined(_ segments: [ThinkingSegment]) -> (thinking: String, content: String) {
    var thinking = ""
    var content = ""
    for segment in segments {
        switch segment {
        case .thinking(let text): thinking += text
        case .content(let text): content += text
        }
    }
    return (thinking, content)
}

print("思考タグ分離器 (ThinkingSplitter) の検証")
print("")

// --- 1. 基本形 -------------------------------------------------------------
print("1. 基本形")

expect(
    run(["<think>考えた</think>本文"]),
    [.thinking("考えた"), .content("本文")],
    "<think>…</think>本文 を分離する（課題文の指定どおり）")

expect(
    run(["タグが無い普通の応答"]),
    [.content("タグが無い普通の応答")],
    "タグが無ければ全部が本文")

expect(
    run([""]),
    [],
    "空文字列は何も出さない")

expect(
    run(["<think></think>本文"]),
    [.content("本文")],
    "空の思考ブロック（思考OFF時に Qwen3 が注入する形）")

// --- 2. チャンク境界をまたぐ区切り文字 -------------------------------------
print("")
print("2. チャンク境界をまたぐ区切り文字（最大の地雷）")

expect(
    run(["<th", "ink>考えた</th", "ink>本文"]),
    [.thinking("考えた"), .content("本文")],
    "開始も終了も2つに割れている")

expect(
    run(["<", "t", "h", "i", "n", "k", ">", "あ", "<", "/", "t", "h", "i", "n", "k", ">", "い"]),
    [.thinking("あ"), .content("い")],
    "1文字ずつ流しても壊れない")

// 末尾の '<' は「<think> の途中かもしれない」ので process では出せない。
// finalize で別断片として出てくる。**分かれて出るのが正しい。**
// 大事なのは「消えない」ことだけ（FR-02: 既出力は消えない）。
expect(
    run(["本文の途中に<"]),
    [.content("本文の途中に"), .content("<")],
    "区切り文字になりそこねた末尾は finalize で別断片として出る")

expect(
    joined(run(["本文の途中に<"])).content == "本文の途中に<",
    "分かれて出ても、連結すれば1文字も失われていない")

expect(
    run(["本文の途中に<", "続き"]),
    [.content("本文の途中に"), .content("<続き")],
    "保留した '<' は次の断片と連結されて出る")

expect(
    joined(run(["a<thi", "nk>b</thin", "k>c"])).thinking == "b",
    "割れた区切りでも思考だけを正しく抜き出す")

expect(
    joined(run(["a<thi", "nk>b</thin", "k>c"])).content == "ac",
    "割れた区切りでも本文だけを正しく抜き出す")

// --- 3. 日本語（マルチバイト） ---------------------------------------------
print("")
print("3. 日本語")

expect(
    run(["<think>まず何を聞かれているのかを整理する。</think>短く答えます。"]),
    [.thinking("まず何を聞かれているのかを整理する。"), .content("短く答えます。")],
    "日本語の思考と本文")

expect(
    joined(run(["<think>絵文字🍣と結合文字が\u{3099}混ざる</think>本文"])).thinking
        == "絵文字🍣と結合文字が\u{3099}混ざる",
    "絵文字・結合文字を壊さない")

// --- 4. 先頭空白の切り落とし（テンプレート由来の改行） ----------------------
print("")
print("4. 区切り文字直後の改行を落とす")

// テンプレートは <think>\n … \n</think>\n\n のように改行で挟む。
// 区切り文字に接する空白は前後とも落とす（公式 ReasoningEventEmitter と同じ扱い）。
// 落とさないと、折りたたみ領域の先頭と末尾に空行が残る。
expect(
    run(["<think>\n考えた\n</think>\n\n本文"]),
    [.thinking("考えた"), .content("本文")],
    "区切り文字に接する改行が前後とも落ちる")

expect(
    run(["<think>考え", "た ", "つづき</think>本文"]),
    [.thinking("考え"), .thinking("た "), .thinking("つづき"), .content("本文")],
    "途中の断片では末尾空白を削らない（語の区切りが消えないこと）")

expect(
    run(["<think>", "\n", "考えた"]),
    [.thinking("考えた")],
    "改行だけの断片をまたいでも切り落としが効く")

// --- 5. 中断・未終端 -------------------------------------------------------
print("")
print("5. 未終端（生成が途中で終わった場合）")

expect(
    run(["<think>考えている途中で止まった"]),
    [.thinking("考えている途中で止まった")],
    "</think> が来なくても思考として出す（FR-02 で既出力を残すため）")

expect(
    run(["<think>考えた</think>"]),
    [.thinking("考えた")],
    "本文が始まる前に終わっても思考は残る")

// --- 6. primedInside（DeepSeek-R1 系） -------------------------------------
print("")
print("6. primedInside")

expect(
    run(["考えた</think>本文"], primedInside: true),
    [.thinking("考えた"), .content("本文")],
    "true: 先出しされた <think> を前提に、いきなり思考から始まる")

// 逆向きの誤りも記録しておく。先出しするモデル（DeepSeek-R1 系）に
// primedInside: false を渡すと、思考が丸ごと本文へ流れ込み、
// **裸の </think> が画面に出る。** 公式実装も同じ壊れ方をする。
expect(
    run(["考えた</think>本文"], primedInside: false),
    [.content("考えた</think>本文")],
    "false: 先出しモデルに誤設定すると思考が本文に混ざり </think> が露出する")

// --- 7. 複数ブロック・暗黙の終了境界 ---------------------------------------
print("")
print("7. 複数ブロックと暗黙の終了境界")

expect(
    run(["<think>1つ目</think>間<think>2つ目</think>後"]),
    [.thinking("1つ目"), .content("間"), .thinking("2つ目"), .content("後")],
    "思考ブロックが2回来ても各々振り分ける")

expect(
    run(["<think>考えた<tool_call>{}"], implicitEndDelimiters: ["<tool_call>"]),
    [.thinking("考えた"), .content("<tool_call>{}")],
    "暗黙の終了境界で思考を抜け、境界そのものは本文に残る")

// --- 8. 状態の観測 ---------------------------------------------------------
print("")
print("8. 内部状態")

var splitter = ThinkingSplitter()
_ = splitter.process("<think>途中")
expect(splitter.isInsideThinking, "思考の内側にいることを観測できる")
_ = splitter.process("</think>本文")
expect(!splitter.isInsideThinking, "閉じたあとは外側に戻る")

// --- 9. 分割位置を総当たりして不変性を確かめる ------------------------------
print("")
print("9. 分割位置の総当たり（どこで割っても結果が同じか）")

let whole = "前置き<think>思考の中身</think>本文のつづき"
let reference = joined(run([whole]))
var mismatches: [Int] = []
let characters = Array(whole)
for cut in 1 ..< characters.count {
    let left = String(characters[0 ..< cut])
    let right = String(characters[cut...])
    let result = joined(run([left, right]))
    if result != reference { mismatches.append(cut) }
}
expect(
    mismatches.isEmpty,
    "\(characters.count - 1) 通りの分割すべてで結果が一致"
        + (mismatches.isEmpty ? "" : " / 不一致: \(mismatches)"))

// 3分割の総当たりも回す（区切り文字が3片に割れる場合を潰す）。
var mismatches3 = 0
for first in 1 ..< characters.count {
    for second in (first + 1) ..< characters.count {
        let a = String(characters[0 ..< first])
        let b = String(characters[first ..< second])
        let c = String(characters[second...])
        if joined(run([a, b, c])) != reference { mismatches3 += 1 }
    }
}
expect(mismatches3 == 0, "3分割の総当たりでも結果が一致（不一致 \(mismatches3) 件）")

// --- 結果 -------------------------------------------------------------------
print("")
if failures == 0 {
    print("すべて成功: \(checks) 件")
    exit(0)
} else {
    print("失敗 \(failures) 件 / 全 \(checks) 件")
    exit(1)
}
"""#

// ソースを連結して一時ファイルへ書き、swift で実行する。
let temporaryURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("sophia-thinking-splitter-\(UUID().uuidString).swift")
try (splitterSource + testSource).write(to: temporaryURL, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: temporaryURL) }

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", temporaryURL.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
