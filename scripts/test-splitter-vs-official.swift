#!/usr/bin/env swift
//
//  自作 ThinkingSplitter が、公式 ReasoningEventEmitter と同じ振る舞いをするか
//
//  実行:
//      swift scripts/test-splitter-vs-official.swift
//
//  ## なぜこれが要るか
//
//  A1 の思考分離（FR-17）は**既定で公式実装**を使う。自作の `ThinkingSplitter` は
//  「モデルが ReasoningConfig を宣言していない場合の受け皿」だが、
//  受け皿の振る舞いが本番と違うと、切り分けの道具にならない。
//
//  ## どうやって比べるか
//
//  公式の `ReasoningEventEmitter.swift` は **import が1行も無い純 Swift** である。
//  だからソースをそのまま取り込んで、自作実装と並べて同じ入力を流せる。
//  （`ReasoningConfig` は MLX を引くので、emitter が実際に読む3フィールドだけの
//   最小の代役を置く。emitter 本体には一切手を入れない。）
//
//  SPM のチェックアウトが無い場合はスキップする（依存解決前でも壊れないように）。
//

import Foundation

let scriptURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
let repositoryRoot = scriptURL
    .deletingLastPathComponent()  // scripts/
    .deletingLastPathComponent()  // リポジトリ直下

let splitterURL = repositoryRoot
    .appendingPathComponent("Sophia/Sources/Inference/ThinkingSplitter.swift")
let officialURL = repositoryRoot
    .appendingPathComponent(
        "Sophia/DerivedData/SourcePackages/checkouts/mlx-swift-lm"
            + "/Libraries/MLXLMCommon/ReasoningEventEmitter.swift")

guard let splitterSource = try? String(contentsOf: splitterURL, encoding: .utf8) else {
    FileHandle.standardError.write(Data("見つかりません: \(splitterURL.path)\n".utf8))
    exit(1)
}
guard let officialSource = try? String(contentsOf: officialURL, encoding: .utf8) else {
    print("公式ソースが見つからないためスキップします（先に make app で依存を解決してください）")
    print("  期待した場所: \(officialURL.path)")
    exit(0)
}

// 公式 emitter が読むのは startDelimiter / endDelimiter / implicitEndDelimiters の3つだけ。
// 最小の代役を置く（emitter 本体は1文字も変えない）。
// public にしておくこと。emitter の public API がこの型を引数に取るため、
// internal だと "cannot be declared public because its parameter uses an internal type"。
let shim = #"""
public struct ReasoningConfig {
    public var startDelimiter: String
    public var endDelimiter: String
    public var implicitEndDelimiters: [String] = []
}
"""#

let comparison = #"""

// ---------------------------------------------------------------------------
//  比較本体
// ---------------------------------------------------------------------------

/// 公式実装を流して (思考, 本文) の並びに直す。
func runOfficial(
    _ chunks: [String], primedInside: Bool, implicit: [String]
) -> [ThinkingSegment] {
    let config = ReasoningConfig(
        startDelimiter: "<think>", endDelimiter: "</think>", implicitEndDelimiters: implicit)
    var emitter = ReasoningEventEmitter(config: config, primedInside: primedInside)
    var output: [ThinkingSegment] = []
    for chunk in chunks {
        output += emitter.process(chunk).map {
            switch $0 {
            case .reasoning(let t): ThinkingSegment.thinking(t)
            case .response(let t): ThinkingSegment.content(t)
            }
        }
    }
    output += emitter.finalize().map {
        switch $0 {
        case .reasoning(let t): ThinkingSegment.thinking(t)
        case .response(let t): ThinkingSegment.content(t)
        }
    }
    return output
}

/// 自作実装を流す。
func runOwn(
    _ chunks: [String], primedInside: Bool, implicit: [String]
) -> [ThinkingSegment] {
    var splitter = ThinkingSplitter(
        implicitEndDelimiters: implicit, primedInside: primedInside)
    var output: [ThinkingSegment] = []
    for chunk in chunks {
        output += splitter.process(chunk)
    }
    output += splitter.finalize()
    return output
}

/// 実運用で意味があるのは「連結した結果」なので、そちらも別に見る。
func joined(_ segments: [ThinkingSegment]) -> (String, String) {
    var thinking = ""
    var content = ""
    for segment in segments {
        switch segment {
        case .thinking(let t): thinking += t
        case .content(let t): content += t
        }
    }
    return (thinking, content)
}

let corpus: [String] = [
    "<think>考えた</think>本文",
    "<think>\n考えた\n</think>\n\n本文",
    "タグの無い普通の応答",
    "<think></think>本文",
    "<think>閉じないまま終わる",
    "前置き<think>思考</think>後書き",
    "<think>1つ目</think>間<think>2つ目</think>後",
    "考えた</think>本文",
    "<think>まず整理する。次に答えの形を決める。</think>短く答えます。",
    "<think>a</think>b</think>c",
    "コードに < と > が出てくる場合: a < b && c > d",
    "<think>\n\n</think>\n\n本文だけ",
    "<thi",
    "</think>",
    "<think>思考<tool_call>{\"name\":\"x\"}",
    "",
]

var failures = 0
var comparisons = 0
var mismatchExamples: [String] = []

/// 1本の文字列を、あらゆる位置で1〜2箇所に割って両実装に流し、結果を突き合わせる。
func compareAllSplits(_ whole: String, primedInside: Bool, implicit: [String]) {
    let characters = Array(whole)

    func compare(_ chunks: [String], _ label: String) {
        comparisons += 1
        let official = runOfficial(chunks, primedInside: primedInside, implicit: implicit)
        let own = runOwn(chunks, primedInside: primedInside, implicit: implicit)
        guard official != own else { return }
        failures += 1
        if mismatchExamples.count < 8 {
            mismatchExamples.append(
                """
                    入力: \(chunks)  (\(label), primedInside: \(primedInside))
                      公式: \(official)
                      自作: \(own)
                """)
        }
    }

    compare([whole], "分割なし")
    guard characters.count >= 2 else { return }
    for cut in 1 ..< characters.count {
        compare([String(characters[0 ..< cut]), String(characters[cut...])], "2分割@\(cut)")
    }
    for first in 1 ..< characters.count {
        for second in (first + 1) ..< characters.count {
            compare(
                [
                    String(characters[0 ..< first]),
                    String(characters[first ..< second]),
                    String(characters[second...]),
                ], "3分割@\(first),\(second)")
        }
    }
}

print("自作 ThinkingSplitter と 公式 ReasoningEventEmitter の突き合わせ")
print("")

for text in corpus {
    for primed in [false, true] {
        compareAllSplits(text, primedInside: primed, implicit: [])
    }
}
// 暗黙の終了境界がある場合も比べる。
for text in corpus {
    for primed in [false, true] {
        compareAllSplits(text, primedInside: primed, implicit: ["<tool_call>"])
    }
}

// 1文字ずつ流す極端な場合も確かめる。
for text in corpus {
    for primed in [false, true] {
        comparisons += 1
        let chunks = text.map(String.init)
        let official = runOfficial(chunks, primedInside: primed, implicit: [])
        let own = runOwn(chunks, primedInside: primed, implicit: [])
        if official != own {
            failures += 1
            if mismatchExamples.count < 8 {
                mismatchExamples.append(
                    """
                        入力（1文字ずつ）: \(text)  (primedInside: \(primed))
                          公式: \(official)
                          自作: \(own)
                    """)
            }
        }
    }
}

print("比較した組み合わせ: \(comparisons) 通り")
print("")

if failures == 0 {
    print("すべて一致。自作実装は公式実装と同じ振る舞いをする。")
    exit(0)
} else {
    print("不一致 \(failures) 件")
    for example in mismatchExamples {
        print(example)
    }
    exit(1)
}
"""#

let temporaryURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("sophia-splitter-diff-\(UUID().uuidString).swift")
try (shim + "\n" + officialSource + "\n" + splitterSource + comparison)
    .write(to: temporaryURL, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: temporaryURL) }

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", temporaryURL.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
