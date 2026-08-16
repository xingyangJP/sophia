import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Sophia

/// 入力欄（`ComposerTextView`）のテスト。
///
/// **ここは「日本語が打てるか」を守るための場所である。**
/// 入力欄は AppKit と SwiftUI の境目にあり、両者が同じ文字列を
/// 別々に持っているため、片方の再描画がもう片方の入力途中を壊しうる。
/// 目で見て気づける不具合ではない（変換中の一瞬しか起きない）ので、
/// 実物の `NSTextView` を組み立てて機械的に確かめる。
@MainActor
final class ComposerTextViewTests: XCTestCase {

    /// SwiftUI 側の状態の代わり。`@Bindable` で本物と同じ形の `Binding` を作る。
    @Observable
    final class Harness {
        var text = ""
        var contentHeight: CGFloat = 0
        var isVisuallyEmpty = true
        var submitCount = 0
    }

    /// 入力欄の実物を1組み立てる。**SwiftUI のビュー階層は作らない。**
    /// `NSViewRepresentableContext` は自前で作れないため、
    /// `ComposerTextView` 側が `Context` 無しの入口を持っている。
    private func makeComposer(
        width: CGFloat = 480
    ) -> (Harness, ComposerTextView, ComposerTextView.Coordinator, NSScrollView, NSTextView) {
        let harness = Harness()
        @Bindable var bindable = harness
        let view = ComposerTextView(
            text: $bindable.text,
            contentHeight: $bindable.contentHeight,
            isVisuallyEmpty: $bindable.isVisuallyEmpty,
            onSubmit: { harness.submitCount += 1 }
        )
        let coordinator = view.makeCoordinator()
        let scrollView = view.makeScrollView(coordinator: coordinator)

        // SwiftUI が `.frame(height:)` で器の大きさを決めるのと同じことを手でやる。
        scrollView.frame = NSRect(
            x: 0, y: 0, width: width, height: SophiaLayout.composerMinTextHeight)
        scrollView.layoutSubtreeIfNeeded()

        let textView = try! XCTUnwrap(scrollView.documentView as? NSTextView)
        return (harness, view, coordinator, scrollView, textView)
    }

    // MARK: - 打てること

    /// 器に入れた時点で、文字を置ける幅と高さがあること。
    ///
    /// `NSTextView(usingTextLayoutManager:)` はフレーム0で生まれる。
    /// `minSize` / `maxSize` / `textContainer.size` を渡し忘れると、
    /// 高さ0のまま伸びない入力欄になり、**打っても何も見えない。**
    func testTextViewHasARealDrawingArea() {
        let (_, _, _, _, textView) = makeComposer()

        XCTAssertGreaterThan(textView.frame.width, 0, "入力欄の幅が0。文字を置く場所が無い")
        XCTAssertGreaterThanOrEqual(
            textView.frame.height, SophiaLayout.composerMinTextHeight,
            "入力欄の高さが1行ぶんに満たない")
        XCTAssertGreaterThan(
            textView.textContainer?.size.width ?? 0, 0,
            "テキストコンテナの幅が0。行が組めない")
        XCTAssertGreaterThan(
            textView.maxSize.height, SophiaLayout.composerMinTextHeight,
            "maxSize が小さいと、複数行に伸びられない")
    }

    /// 1文字打つと SwiftUI 側の `text` に届き、プレースホルダが消えること。
    func testTypingReachesTheBinding() {
        let (harness, _, _, _, textView) = makeComposer()

        textView.insertText("こんにちは", replacementRange: NSRange(location: 0, length: 0))

        XCTAssertEqual(harness.text, "こんにちは")
        XCTAssertFalse(textView.string.isEmpty)
    }

    /// 打った内容が実際に組版されること（幅0だと行が組めず高さも出ない）。
    func testTypedTextIsLaidOut() {
        let (_, _, coordinator, _, textView) = makeComposer()

        textView.insertText("こんにちは", replacementRange: NSRange(location: 0, length: 0))
        coordinator.reportHeight(of: textView)

        let layoutManager = try! XCTUnwrap(textView.layoutManager)
        let container = try! XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)

        XCTAssertGreaterThan(used.width, 0, "組版結果の幅が0。文字が描かれていない")
        XCTAssertLessThanOrEqual(
            used.height, SophiaLayout.composerMinTextHeight * 2,
            "5文字が2行以上になっている。コンテナの幅が足りていない")
    }

    // MARK: - IME（ここが本題）

    /// **変換中に SwiftUI の再描画が来ても、未確定の文字を消さないこと。**
    ///
    /// 「にほん」と打っている最中、`textViewDidChangeSelection` が
    /// `isVisuallyEmpty` を更新する → SwiftUI が再描画する → `updateNSView` が走る。
    /// このとき AppKit 側には "にほん" があり SwiftUI 側の `text` はまだ空なので、
    /// 素直に `textView.string = text` すると**変換セッションごと消える。**
    /// 日本語話者から見ると「1文字も打てない」になる。
    func testMarkedTextSurvivesSwiftUIUpdate() {
        let (harness, view, coordinator, scrollView, textView) = makeComposer()

        textView.setMarkedText(
            "にほん",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: 0, length: 0))

        XCTAssertTrue(textView.hasMarkedText(), "前提が崩れている: 変換中の状態を作れていない")
        XCTAssertEqual(harness.text, "", "前提が崩れている: 未確定文字は binding へ流れないはず")

        // SwiftUI 側の再描画。
        view.apply(to: scrollView, coordinator: coordinator)

        XCTAssertTrue(textView.hasMarkedText(), "変換セッションが壊された")
        XCTAssertEqual(textView.string, "にほん", "未確定の文字が消えた（日本語が打てない）")
    }

    /// **「こんにちは」を打ち切るまでを通しで再現する。**
    ///
    /// 単発の再描画で消えないことと、打鍵のたびに再描画が挟まっても消えないことは別物。
    /// 変換中は毎打鍵で `textViewDidChangeSelection` → `isVisuallyEmpty` の更新 →
    /// SwiftUI の再描画、が起きるので、実際には**1文字ごとに**上書きの機会がある。
    func testFullCompositionSequenceSurvivesRepeatedUpdates() {
        let (harness, view, coordinator, scrollView, textView) = makeComposer()

        // ローマ字入力で「こんにちは」を打ったときに IME が置いていく未確定文字列。
        let steps = ["k", "こ", "こん", "こんn", "こんに", "こんにc", "こんにち", "こんにちは"]
        for step in steps {
            textView.setMarkedText(
                step,
                selectedRange: NSRange(location: (step as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            // 打鍵ごとに SwiftUI 側の再描画が来る。
            view.apply(to: scrollView, coordinator: coordinator)
            XCTAssertEqual(textView.string, step, "変換中の「\(step)」が消えた")
            XCTAssertEqual(harness.text, "", "未確定の文字が binding へ漏れている")
        }

        // 変換確定（スペース→Enter、または無変換のまま Enter）。
        textView.insertText("こんにちは", replacementRange: textView.markedRange())

        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "こんにちは")
        XCTAssertEqual(harness.text, "こんにちは", "確定した文字が送信対象になっていない")
    }

    /// 変換の1文字目でプレースホルダが消えること。
    ///
    /// 変換中は `textDidChange` が来ないため、`isVisuallyEmpty` は
    /// `textViewDidChangeSelection` からしか更新されない。**この経路を壊すと
    /// 「今」と打っているのに『Sophia に相談する』が重なって見える。**
    /// 上の変換中ガードでこの経路を潰していないことを確かめる。
    func testPlaceholderHidesOnTheFirstComposedCharacter() {
        let (harness, _, _, _, textView) = makeComposer()
        XCTAssertTrue(harness.isVisuallyEmpty, "前提: 最初はプレースホルダが出ている")

        textView.setMarkedText(
            "こ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        // binding への書き戻しは次のループへ回されるので、実際に回す。
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(harness.isVisuallyEmpty, "変換中なのにプレースホルダが消えていない")
        XCTAssertEqual(harness.text, "", "未確定の文字を binding へ書いてはいけない")
    }

    /// 変換を確定すれば、通常どおり `text` へ届くこと。
    func testCommittingCompositionReachesTheBinding() {
        let (harness, view, coordinator, scrollView, textView) = makeComposer()

        textView.setMarkedText(
            "にほんご",
            selectedRange: NSRange(location: 4, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        view.apply(to: scrollView, coordinator: coordinator)
        // 変換候補を確定する（IME が最後にやること）。
        textView.insertText("日本語", replacementRange: textView.markedRange())

        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "日本語")
        XCTAssertEqual(harness.text, "日本語")
    }

    /// 送信後のクリアは従来どおり効くこと（変換中ガードで潰していないか）。
    func testExternalClearStillApplies() {
        let (harness, _, coordinator, scrollView, textView) = makeComposer()

        textView.insertText("送信する文", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(harness.text, "送信する文")

        // ChatViewModel.send() が input = "" にした後の再描画。
        harness.text = ""
        @Bindable var bindable = harness
        let updated = ComposerTextView(
            text: $bindable.text,
            contentHeight: $bindable.contentHeight,
            isVisuallyEmpty: $bindable.isVisuallyEmpty,
            onSubmit: { harness.submitCount += 1 }
        )
        coordinator.parent = updated
        updated.apply(to: scrollView, coordinator: coordinator)

        XCTAssertEqual(textView.string, "", "送信後に入力欄が空へ戻っていない")
    }

    // MARK: - Enter の意味（FR-02 の入口）

    /// 変換中の Enter は「確定」であって送信ではない。
    func testEnterDuringCompositionDoesNotSubmit() {
        let (harness, _, coordinator, _, textView) = makeComposer()

        textView.setMarkedText(
            "にほん",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        let handled = coordinator.textView(
            textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertFalse(handled, "変換中の Enter を横取りしている")
        XCTAssertEqual(harness.submitCount, 0, "未確定の文字が送信された")
    }

    /// 変換していないときの Enter は送信。
    func testEnterSubmits() {
        let (harness, _, coordinator, _, textView) = makeComposer()

        textView.insertText("送る", replacementRange: NSRange(location: 0, length: 0))
        let handled = coordinator.textView(
            textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))

        XCTAssertTrue(handled, "Enter が改行として素通りしている")
        XCTAssertEqual(harness.submitCount, 1)
    }
}
