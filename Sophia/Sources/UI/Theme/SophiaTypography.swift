import SwiftUI

// =============================================================================
//  UI 層のデザイントークン
// -----------------------------------------------------------------------------
//  Sources/Shared/DesignTokens.swift は **読み取り専用**として扱う約束なので、
//  UI 層だけが使う値はここに置く。寸法の出所は UI_NATIVE.md 第3.5章／第5章の
//  AppKit 実測値で、Shared の `SophiaMetrics` と重複する値は定義しない。
// =============================================================================

/// 文字の寸法（UI_NATIVE.md 第3.5章 / `NSFont.preferredFont(forTextStyle:)` の実測）。
///
/// **UI の既定は 13pt。** Web の癖で 14〜16pt にすると、それだけで
/// 「Mac のアプリではない」印象になる（UI_NATIVE.md 第7.6章）。
/// 例外は会話本文だけで、長文を読ませるため 15pt を使う。
enum SophiaFont {
    /// UI 全般の既定（body 13 / 行16）。
    static let body = Font.system(size: 13)
    /// サイドバーの選択行・ラベル（headline 13 semibold）。
    static let headline = Font.system(size: 13, weight: .semibold)
    /// 補助テキスト（callout 12）。
    static let callout = Font.system(size: 12)
    /// 日付・メタ情報（subheadline 11）。
    static let subhead = Font.system(size: 11)
    /// 統計表示（footnote 10）。FR-14 の1行はこれ。
    static let footnote = Font.system(size: 10).monospacedDigit()
    /// 会話タイトル（title3 15）。
    static let title3 = Font.system(size: 15)
    /// 節見出し（title2 17）。
    static let title2 = Font.system(size: 17)
    /// 空状態の見出し（title1 22）。
    static let title1 = Font.system(size: 22, weight: .regular)

    /// 会話本文（15 / 行24）。**AppKit 実測値ではなく設計判断**（UI_NATIVE.md 第3.5章）。
    static let message = Font.system(size: 15)
    /// 思考テキスト。本文と同じ大きさでイタリック（UI_SPEC.md 7.2）。
    static let thinking = Font.system(size: 15).italic()

    /// コードブロック（FR-06）。`SF Mono` は名前で呼べないので `.monospaced` に任せる。
    static let code = Font.system(size: 13, design: .monospaced)
    /// コードブロックのヘッダ。
    static let codeHeader = Font.system(size: 11)
    /// 行番号。
    static let codeGutter = Font.system(size: 11, design: .monospaced)
}

/// 行間と、UI_NATIVE.md に無い UI 層固有の寸法。
enum SophiaLayout {
    /// 本文 15pt を行高 24pt に近づけるための追加行間。
    /// SwiftUI は行高を直接指定できないため差分で与える（**目測ではなく 24 − 実測行高 ≒ 18 の差**）。
    static let messageLineSpacing: CGFloat = 6
    /// コードの行間。14pt 相当の詰まった行送り。
    static let codeLineSpacing: CGFloat = 3

    /// メッセージ列と入力欄が共有する最大幅（UI_SPEC.md 10.1-#3）。
    ///
    /// Open WebUI の実測は 900px だが、あれは Latin 15px の値である。
    /// 日本語 15pt では1行45〜50字が 720pt 前後になるためこちらを採る。
    static let columnMaxWidth: CGFloat = 720

    /// ユーザー発言バブルの最大幅（列幅に対する比。UI_SPEC.md 3.1）。
    static let userBubbleMaxWidthRatio: CGFloat = 0.9

    /// 入力欄のテキスト領域の最小／最大高。上限を超えたら内部スクロール（UI_SPEC.md 4.2）。
    static let composerMinTextHeight: CGFloat = 22
    static let composerMaxTextHeight: CGFloat = 240

    /// コードブロックの行番号の溝（UI_SPEC.md 10.1-#13）。
    static let codeGutterWidth: CGFloat = 30
    /// 思考ブロックの左罫。
    static let quoteRuleWidth: CGFloat = 3
}

/// コードのシンタックスハイライト色（FR-06）。
///
/// **`SophiaColor` と同じ「原色＋アルファ」方式ではなく不透明色**にしてある。
/// コードは `surface`（ライト白 / ダーク `#26282B`）の上にしか置かないため、
/// 地が確定していて合成の必要がない。
///
/// 括弧内は `surface` に対する WCAG 2.1 のコントラスト比（計算値。目視ではない）。
enum SophiaCodeColor {
    /// 記号・演算子など。
    static var plain: Color { SophiaColor.ink }
    static var punctuation: Color { SophiaColor.ink2 }
    /// コメント（ライト 4.65:1 / ダーク 4.05:1）。
    static var comment: Color { dynamic(light: 0x7C736A, dark: 0x8B857E) }
    /// キーワード（ライト 6.37:1 / ダーク 6.86:1）。
    static var keyword: Color { dynamic(light: 0x8C3E9E, dark: 0xCFA0DE) }
    /// 文字列（ライト 6.07:1 / ダーク 7.66:1）。
    static var string: Color { dynamic(light: 0x2E6E4E, dark: 0x8FC7A6) }
    /// 数値（ライト 5.32:1 / ダーク 7.07:1）。テラコッタと同じ暖色系に寄せてある。
    static var number: Color { dynamic(light: 0xA8541A, dark: 0xE0A878) }
    /// 型名（ライト 6.21:1 / ダーク AA以上）。
    static var type: Color { dynamic(light: 0x2A6EA6, dark: 0x8FBCE0) }
    /// 関数名（ライト 6.94:1 / ダーク AA以上）。
    static var function: Color { dynamic(light: 0x3D5A8A, dark: 0x9BB4DA) }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? nsColor(dark) : nsColor(light)
        })
    }

    private static func nsColor(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
