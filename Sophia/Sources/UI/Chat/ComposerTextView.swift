import AppKit
import SwiftUI

/// 入力欄の中身。**`TextEditor` ではなく `NSTextView` を直接使う。**
///
/// 理由は日本語入力である。Enter で送信させたいが、`TextEditor` では
/// **変換確定の Enter と送信の Enter を区別できない。**
/// 「にほんご」を変換中に Enter を押したら未確定の文字が送信される、という
/// 日本語話者が必ず踏む不具合になる。
///
/// `NSTextView` なら `hasMarkedText()` で変換中かどうかを見られる。
/// これは AppKit にしかない情報で、SwiftUI 側からは取れない。
struct ComposerTextView: NSViewRepresentable {

    @Binding var text: String
    /// 内容に応じて伸びた高さ。呼び出し側が器の大きさに反映する。
    @Binding var contentHeight: CGFloat
    /// **見た目の上で**空かどうか。プレースホルダの表示判定はこちらを使うこと。
    ///
    /// `text.isEmpty` で判定してはいけない理由: IME 変換中の未確定文字は
    /// `textDidChange` を発火させないため `text` が更新されず、
    /// 画面には「今」と見えているのにプレースホルダが重なって表示される。
    /// 変換中でも発火する `textViewDidChangeSelection` からこの値だけを同期する
    /// （`text` へ未確定文字を書き戻すと変換を壊しうるので、そちらは触らない）。
    @Binding var isVisuallyEmpty: Bool
    /// Enter（Shift なし・変換中でない）が押された。
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        makeScrollView(coordinator: context.coordinator)
    }

    /// `Context` を受け取らない本体。**テストから呼べるようにするために分けてある。**
    /// `NSViewRepresentableContext` は自前で組み立てられないため、
    /// `makeNSView` のままだと入力欄の実物を単体テストで触れない。
    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // TextKit 1 を明示する。macOS 14+ の既定（TextKit 2）だと
        // `layoutManager` が nil になり、高さの実測ができない。
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.delegate = coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = NSColor(SophiaColor.ink)
        textView.insertionPointColor = NSColor(SophiaColor.accentVivid)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        coordinator.textView = textView

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        apply(to: scrollView, coordinator: context.coordinator)
    }

    /// SwiftUI 側の再描画を AppKit へ反映する本体。`makeScrollView` と同じ理由で分けてある。
    func apply(to scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 送信後に空へ戻す場合など、外から変わったときだけ差し替える。
        //
        // **変換中（マークドテキストがある）は絶対に代入しない。**
        // `textView.string = ...` は入力セッションを畳んでしまうため、
        // 未確定の「にほん」が消えて日本語が1文字も打てなくなる。
        // ここへは変換中でも来る: `textViewDidChangeSelection` が
        // `isVisuallyEmpty` を変え、その再描画が `updateNSView` を呼ぶため。
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
        coordinator.reportHeight(of: textView)
        // 送信後のクリア等、delegate を経由しない変更もここで拾う。
        coordinator.syncVisualEmptiness(of: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            reportHeight(of: textView)
            syncVisualEmptiness(of: textView)
        }

        /// IME 変換中は `textDidChange` が来ない（マークドテキストは確定編集ではないため）。
        /// 選択位置の変化は変換中でも発火するので、ここで見た目の空/非空と高さを追従させる。
        /// 「未確定の1文字目でプレースホルダが消えない」問題の修正点。
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            syncVisualEmptiness(of: textView)
            reportHeight(of: textView) // 変換候補で行数が変わるケースにも追従する
        }

        /// マークドテキストも textStorage に載るため、`string.isEmpty` で見た目の空を判定できる。
        func syncVisualEmptiness(of textView: NSTextView) {
            let empty = textView.string.isEmpty
            guard parent.isVisuallyEmpty != empty else { return }
            let binding = parent.$isVisuallyEmpty
            DispatchQueue.main.async { binding.wrappedValue = empty }
        }

        /// Enter の意味を決める唯一の場所。
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }

            // 1. 変換中の Enter は「確定」。**ここを外すと日本語が使えない。**
            if textView.hasMarkedText() { return false }

            // 2. Shift+Enter は改行（AppKit も同じ selector を送ってくるので修飾キーを見る）
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }

            // 3. それ以外は送信
            parent.onSubmit()
            return true
        }

        /// 実測した必要高を親へ返す。
        func reportHeight(of textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let height = max(
                SophiaLayout.composerMinTextHeight,
                used + textView.textContainerInset.height * 2
            )
            guard abs(height - parent.contentHeight) > 0.5 else { return }
            // ビュー更新中の状態変更を避けるため、次のループへ回す。
            let binding = parent.$contentHeight
            DispatchQueue.main.async { binding.wrappedValue = height }
        }
    }
}
