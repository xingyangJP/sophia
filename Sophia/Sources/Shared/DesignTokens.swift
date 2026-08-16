import AppKit
import SwiftUI

/// ウィンドウと部品の寸法。**すべて UI_NATIVE.md 第5章の AppKit 実測値**である。
///
/// > macOS のコントロール標準高は 24px。Web の癖で 36〜40px にすると、
/// > それだけで「Mac のアプリではない」印象になる（UI_NATIVE.md 第5.1章）
///
/// 数値を各画面へ散らさないこと。ここが単一の出所。
enum SophiaMetrics {

    // MARK: - ウィンドウ（UI_NATIVE.md 第2.4章）

    static let windowDefaultWidth: CGFloat = 1000
    static let windowDefaultHeight: CGFloat = 700
    /// サイドバー240 + 本文の最小400。
    static let windowMinWidth: CGFloat = 640
    static let windowMinHeight: CGFloat = 480

    // MARK: - サイドバー（第5.2章 / NSSplitViewItem の実測既定）

    static let sidebarDefaultWidth: CGFloat = 240
    static let sidebarMinWidth: CGFloat = 140
    static let sidebarMaxWidth: CGFloat = 320
    static let sidebarRowHeight: CGFloat = 24

    // MARK: - コントロール（第5.1章 / intrinsicContentSize の実測）

    /// macOS の標準コントロール高。
    static let controlHeight: CGFloat = 24
    /// 送信ボタンなど主要動作（large 相当）。
    static let primaryControlHeight: CGFloat = 28

    // MARK: - タイトルバー（第5.3章）

    /// ツールバー付き（unified）の高さ。
    static let titleBarHeight: CGFloat = 52

    // MARK: - 余白のリズム（第5.4章。4の倍数が基調）

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    /// サイドバー行の左右パディング、階層インデント。
    static let space3: CGFloat = 12
    /// ペイン内側の標準パディング。
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24

    // MARK: - 角丸（第5.5章）

    /// 【推測値】AppKit は部品の角丸を公開していない。純正アプリと並べて調整すること。
    static let controlRadius: CGFloat = 6
    static let cardRadius: CGFloat = 10
    static let sidebarRowRadius: CGFloat = 6
    /// ウィンドウの角丸は **触らない**（OS 任せ）。

    // MARK: - 罫線（第5.6章）

    /// macOS では 1pt が標準。`0.5` にすると Retina で macOS より細くなる。
    static let hairline: CGFloat = 1
}

/// 配色トークン。**UI_NATIVE.md 第4.3章の計算値をそのまま写したもの。**
///
/// ## ライトとダークで同じアルファを使い回さないこと
///
/// これが最も踏まれる罠である。UI_NATIVE.md の計算によれば、
/// ライトの二次テキストをダークと同じ 0.62 にすると **3.27:1 で AA を割る**。
/// 各トークンのアルファはライト／ダークで別々に検算済みの値が入っている。
///
/// ## テラコッタは文字色として使えない場面がある
///
/// `accentVivid`（`#D08256`）はクリーム地で **2.78:1**。**文字に使わないこと。**
/// 線・アイコン・インジケータ専用。文字に使えるのは `accent` だけ。
///
/// UI 担当はここへトークンを**足してよい**。ただし既存の値は変えないこと
/// （コントラスト比が計算済みのため）。
enum SophiaColor {

    // MARK: - 原色（DESIGN.md 第9.2章）。ここは絶対に書き換えない

    static let cream = rgb(0xFE, 0xF5, 0xEB)
    static let charcoal = rgb(0x43, 0x45, 0x48)
    static let terracotta = rgb(0xD0, 0x82, 0x56)

    // MARK: - 地と面

    /// 地（広い面）。ライトはクリーム、ダークは**チャコールの色相を保った暗色**。
    static var background: Color { dynamic(light: cream, dark: rgb(0x1C, 0x1D, 0x1F)) }
    /// カード・入力欄。
    static var surface: Color { dynamic(light: .white, dark: rgb(0x26, 0x28, 0x2B)) }
    /// 最も持ち上がった面。**ダークではチャコール原色がここへ再登場する。**
    static var surfaceRaised: Color { dynamic(light: .white, dark: charcoal) }

    // MARK: - 墨（文字）。原色 + アルファで定義する

    static var ink: Color { dynamic(light: charcoal.alpha(1.00), dark: cream.alpha(0.92)) }
    /// 二次テキスト。**アルファがライト0.78 / ダーク0.62 と違う点に注意。**
    static var ink2: Color { dynamic(light: charcoal.alpha(0.78), dark: cream.alpha(0.62)) }
    /// 三次テキスト。ライトでは大きい文字・アイコンのみ（3.14:1）。
    static var ink3: Color { dynamic(light: charcoal.alpha(0.60), dark: cream.alpha(0.50)) }
    /// 装飾のみ。本文に使わない。
    static var ink4: Color { dynamic(light: charcoal.alpha(0.30), dark: cream.alpha(0.35)) }

    /// 罫線。
    static var separator: Color { dynamic(light: charcoal.alpha(0.12), dark: cream.alpha(0.14)) }

    // MARK: - アクセント

    /// **文字・リンクに使える唯一のテラコッタ。** ライトは濃色版に置き換わる。
    static var accent: Color { dynamic(light: rgb(0xA8, 0x54, 0x26), dark: terracotta) }
    /// 線・アイコン・インジケータ専用。**文字に使わないこと。**
    static var accentVivid: Color { dynamic(light: terracotta, dark: rgb(0xE0, 0x9A, 0x70)) }

    // MARK: - 実装

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// OS の外観に追従する色を作る。
    ///
    /// SwiftUI の `Color` 単体では外観ごとの値を持てないため、AppKit の
    /// dynamic provider を経由する。`@Environment(\.colorScheme)` で分岐する必要はない
    /// （分岐すると、ビューが再評価されない場面で色が取り残される）。
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

private extension NSColor {
    /// UI_NATIVE.md 第4.3章の `rgba(原色, α)` をそのまま書けるようにするための短縮形。
    /// 半透明のまま置く（不透明色に潰さない）のが要点で、こうしないと
    /// vibrancy の上で色が浮く（UI_NATIVE.md 第4.5章）。
    func alpha(_ value: CGFloat) -> NSColor { withAlphaComponent(value) }
}
