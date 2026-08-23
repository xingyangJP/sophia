#!/usr/bin/env python3
"""**宣言されたテストが、本当に実行されたか**を数と名前で突き合わせる（R9）。

## なぜ要るのか

2026-08-23、`AdversarialRoundTripTests.swift` の末尾にあった2本が
`private actor ScriptedExecutor` の内側に入っており、**XCTest が永久に拾わない**状態で
出荷されていた。守っていたのは `[TOOL]` 行の防御 ── **モデルが書いた文字列で
開発者の端末を制御できないこと**。定義はあるのに1度も走らず、緑のままだった。

**人が読んで見つけた。次も見つかる保証は無い。保証が無いなら規則ではなく幸運である。**
だから数で突き合わせる。

## 何を捕まえ、何を捕まえないか（範囲を広げないこと）

捕まえる: **宣言されているのに実行時に現れない**もの。理由は問わない ──
`private` の型の中／`XCTestCase` を継承していない／命名規則違反、どれでも同じ形で出る。

捕まえない: **現れたが中身が走っていない**もの（`XCTSkip`）。
`totalTestCount` は skip を「走った」に数えるので、数の突き合わせでは見えない。
**だから skip は必ず実名で列挙する** ── 「6件」では誰も気づかないが、
`testToolDefinitionTokenCost` という名前が毎回目に入れば、
**322 の裏取りが走っていない**ことが見える。意味論の判断は人がする。

## この器自身が嘘をつく口（3つとも実際に踏んだ）

1. **コメント内の `func test` を数える** ── 素の grep は18件出て実体は6件だった。
2. **文字列リテラルで同期を失う** ── 初版は Swift の字句を追う実装で、
   `SyntaxHighlighterTests.swift` の敵対的な文字列（`#"..."#`・閉じていない `"`・
   文字列の中の `/*`）に当たり、**そのファイルの残り7本を丸ごと飲み込んだ。**
   「走っていないテストを捕まえる器」が、自分で7本を静かに落としていた。
   → **行頭に錨を打つ**方式へ変更。宣言は必ず行頭から始まり、
   文字列の中身が行頭から `func test` で始まることはまず無い。
   加えて素の grep と突き合わせ、**差の1行ごとに実物を出す。**
3. **空を「全部が異常」と読む** ── `xcresulttool` の出力は整形済み JSON で
   `"nodeType"` と `"name"` が別の行にあるため、**行単位の grep は黙って0件を返す。**
   それを差分に食わせて「静的494 対 実行時0 ＝ 差分494件」という嘘が出た。
   → **1件も取れなければ器の欠陥として落とす。** 0件は答えではなく故障である。
"""
import json
import re
import subprocess
import sys
from pathlib import Path

# 行頭 → 属性（@MainActor 等）→ 修飾子 → func testXxx(
DECLARATION = re.compile(
    r"^[ \t]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?[ \t]+)*"
    r"(?:(?:public|internal|fileprivate|private|final|override|static|class|nonisolated)[ \t]+)*"
    r"func[ \t]+(test[A-Za-z0-9_]*)[ \t]*\("
)
ANYWHERE = re.compile(r"\bfunc[ \t]+(test[A-Za-z0-9_]*)[ \t]*\(")
COMMENT_LIKE = re.compile(r"^[ \t]*(///|//|\*|/\*)")
# 型の宣言。持ち主を決めるために字下げごと拾う。
TYPE_DECLARATION = re.compile(
    r"^[ \t]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?[ \t]+)*"
    r"(?:(?:public|internal|fileprivate|private|final|open)[ \t]+)*"
    r"(?:class|actor|struct|extension|enum)[ \t]+([A-Za-z_][A-Za-z0-9_]*)"
)


def declared(tests_directory: Path) -> tuple[dict[str, str], list[str]]:
    """宣言されているテスト `クラス.メソッド` → 出所。第2要素は器の欠陥。

    **キーにクラス名を含めるのは必須である。** メソッド名だけを鍵にすると、
    別クラスの同名テストが1件に潰れる。2026-08-23、実際に2組が潰れて
    xcresult の 545 に対し器は 543 と数え、しかも**両側が同じように潰れるので
    「一致」と報告していた。**

    潰れると、この器が存在する理由そのものが消える ──
    同名の片方が `XCTestCase` の外へ出て走らなくなっても、
    もう一方が名前を残すので差分は空のままになる。
    **`private actor` の中の2本を救うために作った器が、同名衝突しているテストについては
    まさにその失敗を検出できない。**

    クラスは**字下げ**で決める。`func test` の字下げが N なら、
    それより浅い直近の型宣言が持ち主である ── 入れ子の型（テスト内の補助クラス）を
    正しく飛ばせる唯一の軽い規則で、波括弧を数えずに済む
    （波括弧を数える道は、文字列リテラルで同期を失う。初版がそれで7本を落とした）。
    """
    found: dict[str, str] = {}
    unexplained: list[str] = []
    for path in sorted(tests_directory.rglob("*.swift")):
        # (字下げ, 型名) の積み上げ。浅いものから深いものへ。
        scopes: list[tuple[int, str]] = []
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            indent = len(line) - len(line.lstrip(" \t"))

            type_declaration = TYPE_DECLARATION.match(line)
            if type_declaration:
                while scopes and scopes[-1][0] >= indent:
                    scopes.pop()
                scopes.append((indent, type_declaration.group(1)))
                continue

            anchored = DECLARATION.match(line)
            if anchored:
                owner = next(
                    (name for depth, name in reversed(scopes) if depth < indent), "?")
                found[f"{owner}.{anchored.group(1)}"] = f"{path.name}:{number}"
            elif ANYWHERE.search(line) and not COMMENT_LIKE.match(line):
                unexplained.append(f"{path.name}:{number}: {line.strip()}")
    return found, unexplained


def executed(xcresult: Path) -> list[tuple[str, str]]:
    """xcresult に現れたテスト（`クラス.メソッド`, 結果）。

    **クラス名は親の Test Suite から取る。** 名前だけを集めると同名テストが潰れ、
    静的側と同じように潰れるので**差が出ないまま「一致」になる**。

    **grep で拾おうとしないこと。** 出力は整形済み JSON で `"nodeType"` と `"name"` が
    別の行にあるため、行単位の grep は**黙って0件を返す。**
    """
    raw = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(xcresult)],
        capture_output=True, text=True, check=True).stdout
    cases: list[tuple[str, str]] = []

    def walk(node, suite: str) -> None:
        if isinstance(node, dict):
            if node.get("nodeType") == "Test Suite":
                suite = node.get("name", suite)
            if node.get("nodeType") == "Test Case":
                cases.append(
                    (f"{suite}.{node.get('name', '').split('(')[0]}",
                     node.get("result", "?")))
            for value in node.values():
                walk(value, suite)
        elif isinstance(node, list):
            for value in node:
                walk(value, suite)

    walk(json.loads(raw), "?")
    return cases


def total_test_count(xcresult: Path) -> int | None:
    """xcresult 自身が申告する総数。**器の検算に使う**（R8）。

    宣言と実行が一致していても、この数と食い違えば
    **器がどこかで潰している**という合図になる。
    2026-08-23、同名衝突で 545 を 543 と数えたとき、この1行があれば即座に出ていた。
    """
    raw = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(xcresult)],
        capture_output=True, text=True, check=True).stdout
    return json.loads(raw).get("totalTestCount")


def newest_xcresult(root: Path) -> Path | None:
    results = sorted(root.glob("*.xcresult"), key=lambda p: p.stat().st_mtime, reverse=True)
    return results[0] if results else None


def main() -> int:
    tests_directory = Path("Sophia/Tests")
    logs = Path("Sophia/DerivedData/Logs/Test")

    xcresult = newest_xcresult(logs)
    if xcresult is None:
        print(f"⚠ {logs} に xcresult がない。先に `make app-test` を回すこと。", file=sys.stderr)
        return 2

    # **その xcresult が、いまのソースを実行した結果か。**
    #
    # ここを確かめないと、**ソースを直した直後に `make test-audit` だけを叩いたとき、
    # 古い実行結果と新しい宣言を突き合わせて嘘の差分を出す。**
    # 実際 2026-08-23、コミットより前の xcresult を掴んだまま 543/543 と報告した
    # （たまたま一致していたのは、利用者がコミット前にテストを回していたからで、
    #  器が保証したものではない）。**器が自分で選んだ入力を、器が検算する。**
    measured_at = xcresult.stat().st_mtime
    newer = [
        path for path in tests_directory.rglob("*.swift")
        if path.stat().st_mtime > measured_at
    ]
    if newer:
        print("⚠ 器の欠陥: xcresult がソースより古い。この比較は意味を持たない。"
              "`make app-test` を回し直すこと。", file=sys.stderr)
        print(f"    xcresult: {xcresult.name}", file=sys.stderr)
        for path in sorted(newer)[:10]:
            print(f"    より新しい: {path.name}", file=sys.stderr)
        return 2

    declarations, unexplained = declared(tests_directory)
    if unexplained:
        print("⚠ 器の欠陥: 行頭で拾えず、コメントでも説明できない行がある。"
              "数える前にここを解決すること:", file=sys.stderr)
        for line in unexplained:
            print(f"    {line}", file=sys.stderr)
        return 2

    cases = executed(xcresult)
    if not cases:
        # **0件は答えではなく故障である。** ここを返り値として通すと、
        # 「宣言の全部が走っていない」という最大級の嘘がそのまま下流へ流れる。
        print("⚠ 器の欠陥: xcresult から1件も取れなかった。JSON の形が変わった可能性がある。"
              "0件を『全部が異常』と読まないこと。", file=sys.stderr)
        return 2

    ran = {name for name, _ in cases}
    skipped = sorted({name for name, result in cases if result == "Skipped"})

    missing = sorted(set(declarations) - ran)
    unknown = sorted(ran - set(declarations))

    print(f"宣言 {len(declarations)} / 実行 {len(ran)} / skip {len(skipped)}"
          f"  （{xcresult.name}）")

    # **器の検算（R8）。** 潰していないことを、xcresult 自身の申告と突き合わせる。
    reported = total_test_count(xcresult)
    if reported is not None and reported != len(cases):
        print(f"\n⚠ 器の欠陥: xcresult は {reported} 件と申告しているのに "
              f"{len(cases)} 件しか取れていない。どこかで潰している。", file=sys.stderr)
        return 2
    if reported is not None and reported != len(declarations):
        print(f"\n⚠ 宣言 {len(declarations)} と xcresult の申告 {reported} が食い違う。"
              "下の差分を見ること。", file=sys.stderr)

    # skip は落とさない。**ただし毎回、実名で出す。**
    # 「6件」では誰も気づかないが、名前が目に入れば
    # 「その計測が通常実行の外にある」ことに気づける。
    if skipped:
        print("skip（走っていない。数の上では『走った』に入っている）:")
        for name in skipped:
            print(f"    {name}")

    if missing:
        print("\n❌ 宣言されているのに実行時に現れなかった:", file=sys.stderr)
        for name in missing:
            print(f"    {name}\t{declarations[name]}", file=sys.stderr)
        print("\n`XCTestCase` のサブクラスの外に置かれていないか確認すること"
              "（`private actor` の中にあった実例が 2026-08-23）。", file=sys.stderr)
    if unknown:
        print("\n❌ 実行時にあるのに宣言を見つけられなかった（器の取りこぼし）:", file=sys.stderr)
        for name in unknown:
            print(f"    {name}", file=sys.stderr)

    return 1 if (missing or unknown) else 0


if __name__ == "__main__":
    sys.exit(main())
