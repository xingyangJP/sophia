# Sophia UI ネイティブ質感仕様

| 項目 | 内容 |
|---|---|
| 文書名 | Electron で macOS ネイティブの質感を出すための仕様 |
| 版 | 1.0 |
| 作成日 | 2026-08-16 |
| 位置づけ | [DESIGN.md](DESIGN.md) 第9.2章「配色」の実装仕様。**設計の変更ではなく詳細化** |
| 対象フェーズ | A1（ウィンドウ・タイポグラフィ・配色）。ネイティブ部品の一部は A3 |

> **Electron は Chromium で描画するため AppKit / SwiftUI は使えない。**
> しかし Electron が公開している macOS ネイティブ機能（`NSVisualEffectView` / トラフィックライト /
> `NSFont` のシステムフォント / `nativeTheme`）を使えば、ネイティブに感じられるアプリになる。
> **CSS で AppKit の絵を描き直すのではなく、OS に描かせるのが本書の方針である。**

---

## 0. 記法 — 確認できた事実と未確認の推測を分ける

本書の記述には必ず次のいずれかの印を付ける。**印のない断定は書かない。**

| 印 | 意味 |
|---|---|
| **【実測】** | 2026-08-16 に開発機（MacBook Air M3 / macOS 26.5.2 / Build 25F84）で実行して得た値。再現方法を併記する |
| **【出典】** | Electron 公式ドキュメントまたは Electron / Chromium のソースコードに記載がある。参照先を併記する |
| **【計算】** | 実測値から数式で導いた値。コントラスト比は WCAG 2.1 の sRGB 相対輝度の定義に従う。**目視の印象ではない** |
| **【推測】** | 根拠はあるが本環境で確認していない。**実装時に検証すること** |
| **【未確認】** | 調べたが確定できなかった。作業項目として残す |

### 0.1 検証環境

| 項目 | 値 |
|---|---|
| OS | macOS 26.5.2（Build 25F84）/ MacBook Air M3 16GB |
| Electron | **42.9.1**（Chromium 148.0.7778.280 / Node 24.18.1）【実測】 |
| 比較用ブラウザ | Google Chrome 151.0.0.0 |
| 表示 | Retina（`devicePixelRatio = 2`）【実測】 |
| システム外観 | ライト（`AppleInterfaceStyle` 未設定）【実測】 |

Electron のバージョン系列と Chromium の対応【実測: `https://releases.electronjs.org/releases.json`】:

| Electron | Chromium | 備考 |
|---|---|---|
| 43.4.0 | 150 | |
| **42.9.1** | **148** | **本書の検証対象** |
| 41.10.5 | 146 | |

**Electron のメジャーを上げたら本書の【実測】は取り直すこと。**
特に第3章（フォント解決）は Chromium のバージョンで挙動が変わることを実際に観測している（3.4節）。

### 0.2 検証方法

- AppKit の値: Swift スクリプト（`NSFont` / `NSWindow` / `NSColor` / `NSSplitViewItem` を直接読む）
- Electron の値: Electron 42.9.1 を実行し、main プロセスの API 返り値と
  renderer の `CSS.getPlatformFontsForNode`（Chrome DevTools Protocol）を記録
- Electron の内部実装: `electron/main` ブランチの `shell/browser/native_window_mac.mm` 他

**視覚的な確認（vibrancy が実際にどう見えるか）は行えていない。**
本環境ではスクリーンキャプチャの権限がなく、画面を撮れなかった。
第2章の vibrancy に関する「見え方」の記述はすべて【推測】である。

---

## 1. 全体方針 — 何を OS に任せ、何を自分で描くか

| 要素 | 担当 | 理由 |
|---|---|---|
| ウィンドウの角丸・影 | **OS** | 半径は OS バージョンで変わる。macOS 26 の実測値は 16pt（2.6節）。CSS で固定すると次の OS で古く見える |
| 背景の透過・ブラー | **OS**（`vibrancy`） | `backdrop-filter` はウィンドウの背後（他アプリ・壁紙）をぼかせない |
| トラフィックライト | **OS** | 描画・ホバー・無効状態・フルスクリーン遷移すべて OS が持っている |
| アプリケーションメニュー | **OS**（`Menu`） | メニューバーは Web では描けない |
| ダイアログ | **OS**（`dialog`） | シート表示・ボタン配置・キーボード操作が無料で付いてくる |
| フォント | **OS**（`system-ui`） | SF は非公開フォントで、CSS から名前で指定できない（3.1節） |
| 余白・行の高さ・角丸（部品） | **自分** | ただし AppKit の実測値に合わせる（第5章） |
| 配色 | **自分**（Sophia の色） | ここが個性。ただし明暗の反転規則は macOS に合わせる（第4章） |

---

## 2. ウィンドウの質感

### 2.1 `vibrancy` — 指定できる値

【出典: `electron/docs/api/structures/base-window-options.md`、`shell/browser/native_window_mac.mm`】

コンストラクタオプション `vibrancy` に渡せる文字列と、対応する `NSVisualEffectView.Material`:

| Electron の値 | AppKit の Material | rawValue【実測】 | 想定用途（Apple の定義） |
|---|---|--:|---|
| `titlebar` | `.titlebar` | 3 | タイトルバー |
| `selection` | `.selection` | 4 | 選択範囲 |
| `menu` | `.menu` | 5 | メニュー |
| `popover` | `.popover` | 6 | ポップオーバー |
| **`sidebar`** | `.sidebar` | 7 | **サイドバー** |
| `header` | `.headerView` | 10 | ヘッダ領域 |
| `sheet` | `.sheet` | 11 | シート |
| `window` | `.windowBackground` | 12 | ウィンドウ背景 |
| `hud` | `.hudWindow` | 13 | HUD |
| `fullscreen-ui` | `.fullScreenUI` | 15 | フルスクリーンのUI |
| `tooltip` | `.toolTip` | 17 | ツールチップ |
| `content` | `.contentBackground` | 18 | コンテンツ背景 |
| **`under-window`** | `.underWindowBackground` | 21 | **ウィンドウの下（壁紙が透ける）** |
| `under-page` | `.underPageBackground` | 22 | ページの下 |

`appearance-based` / `light` / `dark` / `medium-light` / `ultra-dark` は
**Electron 27 で削除済み**【出典: `docs/breaking-changes.md`「Planned Breaking API Changes (27.0)」。
Apple が macOS 10.15 で削除したため】。
`base-window-options.md` には `appearance-based` がまだ列挙されているが、
`setVibrancy` の受理リストと `native_window_mac.mm` の分岐には存在しない。**ドキュメント側の記載漏れである。**

> **落とし穴:【実測】`setVibrancy()` は不正な値を渡しても例外を投げない。**
> `setVibrancy('appearance-based')` も `setVibrancy('bogus-value')` も
> 例外なしで返り、内部では**何も起きない**（`native_window_mac.mm` の
> `if (vibrancyType)` を通らない）。**綴りを間違えると無言で効かない。**

#### Sophia が使うべき値

**`sidebar` を推奨する。**理由:

1. Sophia の画面構造（左にサイドバー、右に会話）は Notes / Mail と同型で、
   Apple 自身がその左ペインに `.sidebar` を使っている
2. `under-window` は壁紙が強く透けるため、クリーム地（`#FEF5EB`）の色が
   壁紙に引きずられて Sophia の個性が消える
3. `sidebar` はコンテンツ側を不透明に塗る前提の材質で、
   後述する「サイドバーだけ透け、本文は不透明」という構成に合う（4.5節）

**ただし Electron は 1 ウィンドウに 1 つの材質しか設定できない。**
`native_window_mac.mm` の `SetVibrancy` は `[[window_ contentView] bounds]` 全面に
`NSVisualEffectView` を 1 枚だけ挿入し、`AutoresizingMask` で追従させる実装である【出典: ソース】。
サイドバーと本文で材質を変える（ネイティブアプリの標準的な作り）ことは、
**ネイティブコードを書かない限りできない。**
→ 対処は 4.5 節「本文ペインを CSS で不透明に塗る」。

### 2.2 `visualEffectState`

【出典: `base-window-options.md`】`vibrancy` と併用する。ウィンドウが非アクティブなときに
材質を灰色に落とすかどうかを決める。

| 値 | 挙動 |
|---|---|
| `followWindow` | **既定。** ウィンドウがアクティブなら材質もアクティブ、非アクティブなら灰色に落ちる |
| `active` | 常にアクティブ表示 |
| `inactive` | 常に非アクティブ表示 |

**Sophia は `'active'` を指定する。**
理由は Sophia 固有の事情である。ローカル推論は 15〜30 秒かかる（[TUNING.md](TUNING.md)）。
利用者はその間に別アプリへ切り替える。`followWindow` だと生成中のウィンドウが
灰色に沈み、**「止まっている」ように見える**。DESIGN.md 第1章「無言の待機を作らない」に反する。

### 2.3 `titleBarStyle` と `trafficLightPosition`

#### 値の一覧【出典: `base-window-options.md`】

| 値 | 挙動 |
|---|---|
| `default` | 標準のタイトルバー |
| `hidden` | タイトルバーを消し、コンテンツを全面に。**トラフィックライトは残る**（macOS） |
| `hiddenInset` | `hidden` に加え、トラフィックライトをウィンドウ端から少し内側へ寄せる |
| `customButtonsOnHover` | ボタンをホバー時のみ表示。**実験的** |

#### 重要: `titleBarStyle` を既定以外にすると内部的に「フレームなし」になる

```cpp
// shell/browser/native_window.cc
has_frame_{options.ValueOrDefault(options::kFrame, true) &&
           title_bar_style_ == TitleBarStyle::kNormal},
```

【出典: ソース】`frame: true`（既定）のままでも、`titleBarStyle` が `default` 以外なら
`has_frame()` は **false** を返す。その結果 `native_window_mac.mm` で
`titlebarAppearsTransparent = YES` / `titleVisibility = Hidden` / `setOpaque:NO` が適用される。
**「フレームレスにした場合」と「hiddenInset にした場合」は、Electron の内部では同じ扱いである。**
2.5 節のドラッグ領域の話は `hiddenInset` にも等しく当てはまる。

#### トラフィックライトの位置 — macOS 実測とのずれ

Electron の `hiddenInset` は余白を `(12, 11)` に設定する。
ソースには次のコメントが付いている【出典: `native_window_mac.mm`】:

> For macOS >= 11, while this value does not match official macOS apps like Safari or Notes,
> it matches titleBarStyle's old implementation before Electron <= 12.

**つまり Electron の `hiddenInset` は、macOS 純正アプリと位置が合っていないと Electron 自身が認めている。**

macOS 26.5.2 の純正ウィンドウを AppKit で実測した値【実測: Swift / `standardWindowButton`】:

| ウィンドウの型 | ボタン領域の高さ | 左からの x | 上からの y | ボタンの大きさ |
|---|--:|--:|--:|---|
| 標準タイトルバー（`.titled`） | 32pt | 9 | 9 | 14×14 |
| ツールバー `unified`（Notes / Mail 型） | **52pt** | **19** | **19** | 14×14 |
| ツールバー `unifiedCompact` | 40pt | 12 | 13 | 14×14 |
| ツールバー `expanded` | 48pt | 9 | 9 | 14×14 |
| Electron `hiddenInset` の既定 | 36pt 相当 | 12 | 11 | 14×14 |

ボタンの原点間隔は **23pt**（=14 + 隙間9）【実測】。3個ぶんの幅は 14×3 + 9×2 = **60pt**。

**Electron の `trafficLightPosition` は「左上からの余白」であり、コンテナ高さも決める。**
`window_buttons_proxy.mm` の `redraw` は
`コンテナ高さ = ボタン高14 + 2 × margin.y` を計算する【出典: ソース】。したがって:

- `{x: 9,  y: 9}` → コンテナ 32pt = **標準タイトルバーと同じ**
- `{x: 19, y: 19}` → コンテナ 52pt = **Notes / Mail と同じ**

**Sophia は `{x: 19, y: 19}` を採る。**ヘッダを 52px 取り、純正アプリと同じリズムにする。

#### `titleBarOverlay` で「安全域」を CSS から取る

トラフィックライトを避けるための `padding-left` を数値でベタ書きすると、
将来 OS がボタンの大きさを変えたときに破綻する。
`titleBarOverlay` を有効にすると CSS の `env(titlebar-area-*)` が使えるようになる。

**macOS でも動く。ただし `titleBarOverlay` を明示しないと env は未設定のままである。**
【実測: Electron 42.9.1 / ウィンドウ幅 900px】

| ウィンドウ設定 | `env(titlebar-area-x)` | `y` | `width` | `height` | `navigator.windowControlsOverlay.visible` |
|---|--:|--:|--:|--:|:--:|
| `hidden` + `titleBarOverlay:{height:52}` | 78px | 0px | 822px | 52px | true |
| `hidden` + `tlp{19,19}` + `titleBarOverlay:{height:52}` | **98px** | 0px | 802px | 52px | true |
| `hiddenInset` + `titleBarOverlay:{height:52}` | 84px | 0px | 816px | 52px | true |
| `hidden` + `tlp{19,19}`（overlay なし） | **未設定** | — | — | — | false |
| `hiddenInset` のみ（overlay なし） | **未設定** | — | — | — | false |

`98px = 19（左余白） + 60（ボタン3個） + 19（右余白）`。計算どおりである。

> `titleBarOverlay` の `color` / `symbolColor` は Windows / Linux 専用【出典: `base-window-options.md`】。
> macOS では `height` だけが効く。

### 2.4 Sophia の推奨ウィンドウ設定

```ts
// src/main/window.ts
import { BrowserWindow, nativeTheme } from 'electron'

/** ヘッダの高さ。macOS の unified ツールバー実測値 52pt に合わせる */
const HEADER_HEIGHT = 52
/** トラフィックライトの余白。{19,19} で Notes / Mail と同じ位置になる */
const TRAFFIC_LIGHT = { x: 19, y: 19 }

export function createMainWindow () {
  const win = new BrowserWindow({
    width: 1000,
    height: 700,
    minWidth: 640,        // サイドバー240 + 本文の最小400
    minHeight: 480,

    // --- タイトルバー ---
    titleBarStyle: 'hidden',          // hiddenInset ではなく hidden + 明示座標
    trafficLightPosition: TRAFFIC_LIGHT,
    titleBarOverlay: { height: HEADER_HEIGHT },  // env(titlebar-area-*) を有効化

    // --- 質感 ---
    vibrancy: 'sidebar',
    visualEffectState: 'active',      // 生成中に別アプリへ移っても沈ませない
    // vibrancy を見せるには web コンテンツ側を透過させる必要がある。
    // これを忘れると不透明な白で塗りつぶされ、vibrancy が一切見えない
    backgroundColor: '#00000000',

    show: false,                      // 初回描画前のちらつきを避ける
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  })

  // 描画が整ってから見せる（白い箱が一瞬出るのを防ぐ）
  win.once('ready-to-show', () => win.show())
  return win
}
```

`titleBarStyle: 'hiddenInset'` ではなく **`'hidden'` + `trafficLightPosition` を明示**するのは、
`hiddenInset` の既定値 `(12, 11)` が純正アプリと合っていないため（2.3節）。
座標を自分で持てば、Electron 側の既定値が変わっても Sophia の見た目は動かない。

> **【実測】`win.getBackgroundColor()` は `backgroundColor: '#00000000'` を設定しても `#000000` を返す。**
> アルファが落ちる。ゲッタの値で透過の有無を判定しないこと。

対応する CSS 側:

```css
/* 地は OS（vibrancy）に描かせる。html/body は透明でなければならない */
html, body {
  margin: 0;
  height: 100%;
  background: transparent;
}

#app {
  display: grid;
  /* サイドバー幅は AppKit の実測既定に合わせる（第5章） */
  grid-template-columns: 240px minmax(0, 1fr);
  grid-template-rows: 52px minmax(0, 1fr);
  height: 100%;
}

/* ヘッダ左端。トラフィックライトの安全域を env から取る。
   env が未設定の環境でも壊れないよう第2引数に既定値を置く */
.header-left {
  padding-left: env(titlebar-area-x, 98px);
}
```

### 2.5 ドラッグ領域 — 作り方と落とし穴

#### プロパティ名

【出典: `docs/tutorial/custom-window-interactions.md`】現行のドキュメントは
**接頭辞なしの `app-region`** で書かれている。
【実測: Electron 42.9.1 / Chromium 148】`CSS.supports()` は `app-region` / `-webkit-app-region`
**どちらも true** を返した。`-webkit-app-region` は別名として残っている。

→ **`app-region` を使う。** 既存記事のコピーで `-webkit-app-region` を書いても動くが、混在させない。

#### 基本形

```css
/* ヘッダ全体をドラッグ可能にする */
.header {
  app-region: drag;
  user-select: none;   /* ドラッグ中に文字が選択されるのを防ぐ */
}

/* ドラッグ領域は「ポインタイベントを一切通さない」。
   中に置くボタン・入力欄はすべて no-drag に戻さないとクリックできない */
.header button,
.header input,
.header [role='button'] {
  app-region: no-drag;
}
```

#### 落とし穴（重要度順）

1. **ドラッグ領域は矩形として扱われ、その矩形内のポインタイベントを全部食う。**
   【出典: 公式ドキュメント】「draggable areas ignore all pointer events」。
   ヘッダ全面に `drag` を敷いた場合、上に載せた要素は**すべて** `no-drag` にする必要がある。
   後から要素を1つ足したときに「なぜかクリックできない」で必ず一度は詰まる。
   → **`drag` は「何も置かない余白の帯」にだけ付ける**方が事故が少ない。
   Sophia のヘッダは `[トラフィックライト安全域][タイトル][余白 = drag][操作ボタン群]` の構成にし、
   ボタンを含む要素には `drag` を付けない。

2. **ダブルクリックでの最大化/最小化が自動では正しく動かない。**
   macOS には「タイトルバーをダブルクリックしたときの動作」というシステム設定がある。
   【実測】本機の値は `systemPreferences.getUserDefault('AppleActionOnDoubleClick', 'string')` → `"Maximize"`。
   Electron の `app-region: drag` はこれを完全には再現しない（既知の未解決 issue が複数ある）。
   必要なら自前で実装する:

   ```ts
   // main プロセス。renderer からヘッダのダブルクリックを受け取る
   ipcMain.on('titlebar:double-click', (event) => {
     const win = BrowserWindow.fromWebContents(event.sender)
     if (!win) return
     // OS の設定に従う。'Maximize' | 'Minimize' | 'None'
     const action = systemPreferences.getUserDefault('AppleActionOnDoubleClick', 'string')
     if (action === 'Minimize') win.minimize()
     else if (action === 'Maximize') win.isMaximized() ? win.unmaximize() : win.maximize()
   })
   ```
   【推測】上記コードは公式ドキュメントとソースから組み立てたもので、**動作は未確認**。A1 で実機確認すること。

3. **ドラッグ領域では独自のコンテキストメニューを出さない。**
   【出典: 公式ドキュメント】ドラッグ領域は非クライアント領域として扱われ、
   右クリックでシステムメニューが出る場合がある。
   なお Electron 側には、右クリック時に一時的にドラッグ領域を無効化する処理が入っている
   （`electron_ns_window.mm` の `shouldDisableDraggable`）【出典: ソース】。

4. **スクロールする領域に `drag` を付けない。** 会話リストや本文には絶対に付けないこと。

5. **`app-region` を JS で動的に切り替えても即座に反映されないことがある。**
   【未確認】広く報告されている挙動だが本環境では再現確認していない。
   切り替えが必要な設計（例: 全画面ドラッグの ON/OFF）は避け、静的な帯で組む。

### 2.6 角丸と影 — 自分で描かない

**【実測】macOS 26.5.2 のウィンドウ角丸半径は 16pt。**
（`NSWindow` の非公開プロパティ `_cornerRadius` を KVC で読み取った値。**非公開 API なので保証はない**）

一方、**Electron は vibrancy 用のマスクを半径 9.0 で固定している**【出典: `native_window_mac.mm`】:

```cpp
CGFloat radius = fullscreen ? 0.0f : 9.0f;
```

このマスクが適用されるのは `should_round_nonmodal = !no_rounded_corner && !is_modal() && !has_frame()`
のときで、2.3 節のとおり `titleBarStyle` を既定以外にすると `has_frame()` は false なので、
**Sophia の構成では 9pt のマスクが当たる。**
OS の 16pt とは一致しない。

【推測】ウィンドウ自体は OS が 16pt でクリップするため、9pt のマスク（より角ばっている）は
その内側に隠れて実害は出ない可能性が高い。**ただし視覚確認していない。**
A1 の実機確認で、四隅に色の食い違いや縁が出ていないかを必ず目視すること。

**やること・やらないこと:**

- ❌ ルート要素に `border-radius: 10px` などを書いて角丸を「作る」
  → OS の半径と二重になり、四隅に隙間や段差が出る。しかも OS 更新で値が変わる
- ❌ `box-shadow` でウィンドウの影を描く → OS の影と二重になる
- ✅ `roundedCorners`（既定 `true`）のまま触らない【出典: `base-window-options.md`】
- ✅ 影も OS 任せ（`hasShadow` 既定 `true`）

### 2.7 `transparent: true` は使わない

【出典: `docs/tutorial/custom-window-styles.md`】`transparent: true` には次の制約がある。

- macOS では**ウィンドウの影が出なくなる**
- **リサイズできなくなる**（`resizable: true` にすると不安定になる）
- DevTools を開くと透過が消える

Sophia は `titleBarStyle: 'hidden'` + `backgroundColor: '#00000000'` で
vibrancy を見せられる（2.4節の構成）。**`transparent: true` は不要であり、使うと損しかしない。**

---

## 3. タイポグラフィ

### 3.1 最重要 — `-apple-system` は Electron では効かない

**多くの記事が書いている `font-family: -apple-system, BlinkMacSystemFont, ...` のうち、
Electron で実際に効いているのは `BlinkMacSystemFont` の方である。**

【実測: Electron 42.9.1 / Chromium 148 / macOS 26.5.2。
`CSS.getPlatformFontsForNode` で「実際に使われたフォント」を取得】

| CSS の指定 | Latin に使われたフォント | 日本語に使われたフォント |
|---|---|---|
| `-apple-system` | **HiraKakuProN-W3**（＝解決に失敗し既定フォントへ） | HiraKakuProN-W3 |
| `BlinkMacSystemFont` | **.SFNS-Regular**（システムフォント） | HiraKakuProN-W3 |
| `system-ui` | **.SFNS-Regular** | HiraKakuProN-W3 |
| `BlinkMacSystemFont, 'Hiragino Sans'` | .SFNS-Regular | HiraginoSans-W4 |
| `ui-monospace, SFMono-Regular, Menlo, monospace` | Menlo-Regular | — |
| `Menlo, monospace` | Menlo-Regular | — |

`-apple-system` の行だけ Latin にもシステムフォントが使われていない。
これは「未知のファミリー名として無視され、既定フォント（本機はロケールが日本語なので Hiragino）へ落ちた」
ことを意味する。

**裏付け【出典: Chromium ソース
`third_party/blink/renderer/platform/fonts/font_family_names.json5`】**
Blink が特別扱いするファミリー名の一覧に `system-ui` と `BlinkMacSystemFont` はあるが、
**`-apple-system` は含まれていない。** `-apple-system` は WebKit（Safari）専用である。

同様に **`ui-sans-serif` / `ui-monospace` / `ui-rounded` も Chromium では解決しない**【実測】。
Safari 向けの指定であり、Electron では効かない。

> **結論: `-apple-system` は書いても害はないが、頼ってはいけない。
> Electron で実効性があるのは `BlinkMacSystemFont` と `system-ui` の2つだけ。**

### 3.2 SF Pro Text と SF Pro Display は CSS から指定できない

**【実測】`NSFontManager.availableFontFamilies` に `SF Pro` / `SF Pro Text` / `SF Pro Display` は存在しない。**
CSS で `'SF Pro Text'` と書いても解決しない【実測: Electron / Chrome とも】。
システムフォントの実体は非公開フォント `.AppleSystemUIFont`（PostScript 名 `.SFNS-*`）で、
先頭のドットは「アプリから名前で使ってはいけない」という Apple の慣習の印である。

**Text / Display の使い分けは、そもそも手動で行うものではなくなっている。**
【実測】8pt から 40pt まで 1pt 刻みでシステムフォントを解決させたが、
実体は全域で `.SFNS-Regular` の1つだった。Chromium が報告する内部名も
`.SFNS-Regular_wdth_opsz110000_GRAD_wght` で、**光学サイズ（opsz）を軸に持つ可変フォント**であることがわかる。
サイズに応じた字形の切り替えはフォント内部で自動的に行われる。

→ **CSS 側でやるべきことは `font-size` を正しく設定することだけ。**
`'SF Pro Display'` を大見出しに、といった指定は不要かつ無効。

ウェイトは `.SFNS-Ultralight` 〜 `.SFNS-Black` まで揃っている【実測】ので、
CSS の `font-weight: 100〜900` は素直に効く。

### 3.3 日本語（ヒラギノ）へのフォールバック

**放置すると、macOS 純正アプリより日本語がわずかに細く見える。**

【実測】AppKit がシステムフォントの日本語部分に使う実体は
`.HiraKakuInterface-W4`（ファミリー `.Hiragino Kaku Gothic Interface`）。**W4** である。
一方、CSS で `system-ui` / `BlinkMacSystemFont` だけを指定したときに
Chromium が日本語に使うのは `HiraKakuProN-W3`。**W3** である。

つまり **Chromium の自動フォールバックは、macOS 本体より 1 段細い**。
日本語が主言語の Sophia では無視できない差になる。

#### 対処: 日本語だけ明示的に W4 を当てる

`@font-face` の `local()` と `unicode-range` を使い、**Latin はシステムフォント、
日本語だけ Hiragino Sans W4** に固定する。

【実測: Electron 42.9.1 で下記が意図どおり解決することを確認】
`w400 → HiraginoSans-W4` / `w600 → HiraginoSans-W6`。

```css
/* 日本語の範囲だけを Hiragino Sans の指定ウェイトへ固定する。
   Latin はシステムフォント（.SFNS）のまま残る */
@font-face {
  font-family: 'SophiaJP';
  src: local('HiraginoSans-W4');
  font-weight: 400;
  unicode-range:
    U+3000-303F,   /* 句読点・記号 */
    U+3040-309F,   /* ひらがな */
    U+30A0-30FF,   /* カタカナ */
    U+4E00-9FFF,   /* 漢字 */
    U+FF00-FFEF;   /* 全角英数・半角カナ */
}
@font-face {
  font-family: 'SophiaJP';
  src: local('HiraginoSans-W6');
  font-weight: 600 700;
  unicode-range: U+3000-303F, U+3040-309F, U+30A0-30FF, U+4E00-9FFF, U+FF00-FFEF;
}
```

#### 参考: 明示指定した場合のウェイト対応【実測】

`font-family: 'Hiragino Sans'` に `font-weight` を与えたときの解決先:

| font-weight | Chrome 151 | Electron 42.9.1 (Chromium 148) |
|--:|---|---|
| 300 | HiraginoSans-W2 | — |
| 400 | HiraginoSans-**W3** | HiraginoSans-**W4** |
| 500 | HiraginoSans-W4 | HiraginoSans-W5 |
| 600 | HiraginoSans-W5 | HiraginoSans-W6 |
| 700 | HiraginoSans-W6 | — |

**Chromium のバージョンで 1 段ずれた。**
だから「`'Hiragino Sans'` を並べて `font-weight` で調整する」やり方は当てにならない。
上記の `@font-face` + `local('HiraginoSans-W4')` のように **PostScript 名で直に指定する**のが唯一安定する方法である。

#### 名前で指定できる日本語フォント【実測】

| 指定 | 解決 |
|---|---|
| `'Hiragino Sans'` | ○ HiraginoSans-W3 / W4（版により差あり） |
| `'Hiragino Kaku Gothic ProN'` | ○ HiraKakuProN-W3 |
| `'Hiragino Maru Gothic ProN'` | ○ HiraMaruProN-W4 |
| `'Hiragino Mincho ProN'` | ○ HiraMinProN-W3 |
| `YuGothic`（空白なし） | ○ YuGo-Medium |
| `'Yu Gothic'`（空白あり） | **× 解決しない** |
| `'Noto Sans JP'` | × 未インストール |
| `'SF Mono'` / `SFMono-Regular` | **× 解決しない**（非公開フォント） |
| `Menlo` / `Monaco` | ○ |

### 3.4 Sophia のフォントスタック

```css
:root {
  /* 本文。-apple-system は Chromium で無効だが、将来 WebKit 系で
     プレビューする可能性を考えて先頭に残す（害はない） */
  --font-ui:
    -apple-system,
    BlinkMacSystemFont,
    'SophiaJP',                  /* 上の @font-face。日本語だけ W4 に固定 */
    'Hiragino Sans',             /* SophiaJP が効かない環境の保険 */
    sans-serif;

  /* コードブロック（FR-06）。SF Mono は CSS から呼べないので Menlo が実質の第一候補。
     日本語混じりのコードのために SophiaJP を後ろに置く */
  --font-mono:
    ui-monospace,                /* Chromium では無効。Safari 系への配慮 */
    SFMono-Regular,              /* 同上 */
    Menlo,                       /* ← Electron ではこれが実際に効く */
    Monaco,
    'SophiaJP',
    monospace;
}
```

> `monospace` の総称だけに頼ると、日本語部分に **Osaka-Mono** が使われる【実測】。
> 等幅の日本語は読みづらいので、`--font-mono` の末尾に `'SophiaJP'` を置いて回避する。

### 3.5 サイズ — AppKit の実測値に合わせる

macOS のテキストスタイルを AppKit から実測した値【実測: `NSFont.preferredFont(forTextStyle:)` と
`NSLayoutManager.defaultLineHeight`】。**pt = CSS の px と 1:1 で対応する**（Retina でも同じ）。

| テキストスタイル | サイズ | 行の高さ | ウェイト | Sophia での用途 |
|---|--:|--:|--:|---|
| largeTitle | 26 | 32 | regular | 使わない |
| title1 | 22 | 26 | regular | 空状態の見出し |
| title2 | 17 | 22 | regular | 設定画面の節見出し |
| title3 | 15 | 20 | regular | 会話タイトル |
| **headline** | **13** | **16** | **semibold (+0.40)** | サイドバーの選択行、ラベル |
| **body** | **13** | **16** | regular | **UI 全般の既定** |
| callout | 12 | 15 | regular | 補助テキスト |
| subheadline | 11 | 14 | regular | 日付、メタ情報 |
| footnote | 10 | 13 | regular | 統計表示（FR-14） |
| caption1 / caption2 | 10 | 13 | regular | 最小の注記 |

基準サイズ【実測】: `NSFont.systemFontSize = 13.0` / `smallSystemFontSize = 11.0` / `labelFontSize = 10.0`。

**UI の既定は 13px / 行の高さ 16px。** Web の癖で 14px や 16px にすると、
それだけで「Mac のアプリではない」という印象になる。

ただし**会話の本文だけは例外**とする。13px は密度の高い UI 向けの値で、
長文を読ませる領域には小さい。Sophia の本文は **15px / 行の高さ 24px** を採る。
【推測】この値は AppKit の実測値ではなく、13px の UI に対して読みやすさを優先した設計判断である。
実機で読んで調整すること。

```css
:root {
  /* macOS 実測値（第5章の表）。UI 部品はここから外れない */
  --text-body:      13px;  --lh-body:      16px;
  --text-headline:  13px;  --lh-headline:  16px;  --weight-headline: 600;
  --text-callout:   12px;  --lh-callout:   15px;
  --text-subhead:   11px;  --lh-subhead:   14px;
  --text-footnote:  10px;  --lh-footnote:  13px;
  --text-title3:    15px;  --lh-title3:    20px;
  --text-title2:    17px;  --lh-title2:    22px;

  /* 会話本文のみ独自値（長文を読ませるため） */
  --text-message:   15px;  --lh-message:   24px;
}
```

### 3.6 フォント描画で触ってはいけないもの

- ❌ **`-webkit-font-smoothing: antialiased`**
  macOS 10.14 以降、OS はサブピクセルアンチエイリアスを行っていない。
  この指定を足すと**純正アプリより文字が細くなり**、かえって Mac らしさが失われる。
  【推測】理屈は確立しているが、本環境で並べて比較していない。既定（無指定）のままにすること。
- ❌ **`letter-spacing` の追加**
  SF はサイズごとのトラッキングを内部に持っている。CSS で足すと二重にかかる。
- ❌ **`font-weight` を 100 や 200 にする**
  ウェイトは存在するが【実測】、macOS の UI で本文に極細を使う場面はない。

---

## 4. 配色とダークモード

### 4.1 `nativeTheme` — OS の外観に追従する

【出典: `docs/api/native-theme.md`。以下の【実測】は Electron 42.9.1】

| API | 型 | 本機の値【実測】 |
|---|---|---|
| `nativeTheme.shouldUseDarkColors` | boolean（読み取り専用） | `false` |
| `nativeTheme.themeSource` | `'system' \| 'light' \| 'dark'` | `'system'`（既定） |
| `nativeTheme.shouldUseHighContrastColors` | boolean | `false` |
| `nativeTheme.prefersReducedTransparency` | boolean | `false` |
| `nativeTheme.shouldDifferentiateWithoutColor` | boolean | `false` |
| `nativeTheme.on('updated')` | イベント | OS 側の変化で発火 |

#### 【実測】renderer への伝達に IPC は不要

`nativeTheme.themeSource = 'dark'` を main で設定した直後、renderer の
`matchMedia('(prefers-color-scheme: dark)').matches` が **`true` になることを確認した。**

→ **CSS だけでテーマを切り替えられる。** main から renderer へ色を送る IPC を書く必要はない。

```ts
// main。設定画面の3択（FR-10）はこれ1行に落ちる
nativeTheme.themeSource = 'system' | 'light' | 'dark'
```

```css
/* renderer。OS 追従もアプリ内切替も、この1つの分岐で両方まかなえる */
:root { /* ライトのトークン */ }
@media (prefers-color-scheme: dark) {
  :root { /* ダークのトークン */ }
}
```

#### 【実測】使えるメディア特性（Electron 42.9.1 / Chromium 148）

`matchMedia(...).media` が `'not all'` にならないことで対応を判定した。**すべて対応していた。**

| メディア特性 | 対応 | 用途 |
|---|:--:|---|
| `prefers-color-scheme` | ○ | ライト / ダーク |
| `prefers-reduced-transparency` | ○ | **「透明度を下げる」設定。vibrancy を切る判断に使う** |
| `prefers-contrast` | ○ | 「コントラストを上げる」設定 |
| `prefers-reduced-motion` | ○ | アニメーションの抑制 |
| `forced-colors` | ○ | （macOS では通常 `none`） |
| `dynamic-range` | ○ | |

### 4.2 `systemPreferences` — OS の色を読む

【実測: Electron 42.9.1 / macOS 26.5.2 ライト外観】

| 呼び出し | 返り値 |
|---|---|
| `systemPreferences.getAccentColor()` | **`"007AFFFF"`** ← **`#` が付かない。RGBA 順** |
| `systemPreferences.getEffectiveAppearance()` | `"light"` |
| `getColor('window-background')` | `#FFFFFFFF` |
| `getColor('under-page-background')` | `#969696E5` |
| `getColor('label')` | `#000000D8`（黒 84.7%） |
| `getColor('secondary-label')` | `#0000007F` |
| `getColor('separator')` | `#00000019`（黒 9.8%） |
| `getColor('selected-content-background')` | `#0064E1FF` |
| `getColor('link')` | `#0068DAFF` |
| `getColor('keyboard-focus-indicator')` | `#0067F47F` |
| `getSystemColor('orange')` | `#FF8D28FF` |
| **`getColor('control-accent')`** | **例外 `Unknown color: control-accent`** |

> **落とし穴（2つ）:**
> 1. `getAccentColor()` は `#` を付けずに返す。CSS へ渡すには `'#' + color` が要る。
>    一方 `getColor()` は `#RRGGBBAA` で返す。**2つの API で書式が違う。**
> 2. macOS の `getColor()` に `control-accent` は**ない**。アクセントカラーは `getAccentColor()` で取る。

参考として、AppKit から直接読んだ macOS 26.5.2 のシステム色【実測: Swift / `NSAppearance` を切り替えて取得】:

| 色 | ライト（aqua） | ダーク（darkAqua） |
|---|---|---|
| `windowBackgroundColor` | `#FFFFFF` | `#1E1E1E` |
| `underPageBackgroundColor` | `#969696` α0.898 | `#282828` |
| `labelColor` | 黒 α0.847 | 白 α0.847 |
| `secondaryLabelColor` | 黒 α0.498 | 白 α0.549 |
| `tertiaryLabelColor` | 黒 α0.259 | 白 α0.247 |
| `separatorColor` | 黒 α0.098 | 白 α0.098 |
| `controlAccentColor` | `#007AFF` | `#007AFF` |
| `selectedContentBackgroundColor` | `#0064E1` | `#0059D1` |
| `linkColor` | `#0068DA` | `#419CFF` |

**macOS のライトの地は白（`#FFFFFF`）である。** かつての `#ECECEC` ではない。
Sophia のクリーム `#FEF5EB` は白よりわずかに暗く暖かい。**これが Sophia の個性になる。**

**設計上の重要な観察: macOS は文字色を「不透明な色」ではなく「アルファ付きの墨」で定義している。**
ライトは黒 84.7%、ダークは白 84.7%。この方式なら、下に何が来ても（vibrancy でも）文字が地に馴染む。
**Sophia もこの方式を踏襲する**（4.3節）。

#### システムアクセントカラーを使うべきか

**使わない。** Sophia のアクセントはテラコッタ `#D08256` であり、
`getAccentColor()`（本機では青 `#007AFF`）を混ぜると配色が2系統になって濁る。

ただし例外が2つある:

- **本文中のテキスト選択（`::selection`）** は OS の選択色に合わせた方がよい。
  利用者は他アプリと同じ挙動を期待する。
- **キーボードフォーカスリング** も同様。

【推測】この2点は慣習に基づく判断で、実機比較はしていない。A1 で両方試して決めること。

### 4.3 Sophia のカラートークン設計（本書の中心）

#### 設計の骨子 — 役割の入れ替え

DESIGN.md 第9.2章の3色を、ライトとダークで次のように入れ替える。

| 役割 | ライト | ダーク |
|---|---|---|
| **地（広い面）** | クリーム `#FEF5EB` | **チャコールの色相を保った暗色** `#1C1D1F` |
| **墨（文字）** | チャコール `#434548` | **クリーム `#FEF5EB`** |
| **アクセント（細い要素）** | テラコッタ**の濃色版** `#A85426` | テラコッタ **そのまま** `#D08256` |

**入れ替えの要点は3つある。**

1. **クリームとチャコールは、地と墨として役割を丸ごと交換する。**
   ダークでクリームを地にはできない（明るすぎる）が、**墨としてなら使える**。
   クリーム `#FEF5EB` を `#1C1D1F` に載せたときのコントラスト比は **15.64:1**【計算】で、
   純白より柔らかく、暖かさが残る。

2. **チャコール `#434548` をそのままダークの地にはできない。**
   `#434548` の上にクリームを置くと 8.92:1 で読めはするが、
   macOS のダーク地は `#1E1E1E`【実測】であり、`#434548` は明るすぎて
   「浮いたパネル」に見える。**色相（青みのある無彩色、H≒220°）だけを継承した `#1C1D1F` を地にする。**
   ただしチャコールが消えるわけではない。**ダークでは「最も持ち上がった面」として再登場する**
   （`--surface-raised`）。地 `#1C1D1F` に対する面差は 1.75:1、
   その上に `--ink` を載せると 7.86:1 で読める【計算】。
   つまり**チャコールは「墨 → 面」へ、クリームは「地 → 墨」へ役割が移る。**

3. **テラコッタは役割を変えず、明度だけを地と逆方向へ動かす。**
   これが最も見落とされやすい。**テラコッタ `#D08256` はクリームの上ではコントラスト
   2.78:1 しかなく、文字色として使えない**【計算】。
   ライトでは濃色版 `#A85426`（4.92:1）に置き換える必要がある。
   逆にダークの `#1C1D1F` 上では `#D08256` が 5.63:1 で**そのまま文字に使える**。

#### コントラスト比の実算出

以下はすべて WCAG 2.1 の定義（sRGB 相対輝度）で計算した値である。
アルファ付きの色は地に合成した実効色で計算している。**目視の印象ではなく計算値。**

**ライト（地 = `#FEF5EB`）**

| トークン | 値 | 実効色 | 対 地 | 判定 |
|---|---|---|--:|---|
| `--ink` | `rgba(67,69,72,1.00)` | `#434548` | **8.92:1** | AA / AAA |
| `--ink-2` | `rgba(67,69,72,0.78)` | `#6C6C6C` | **4.87:1** | AA |
| `--ink-3` | `rgba(67,69,72,0.60)` | `#8E8B89` | 3.14:1 | 大きい文字・アイコンのみ |
| `--ink-4` | `rgba(67,69,72,0.30)` | `#C6C0BA` | 1.67:1 | 装飾のみ |
| `--separator` | `rgba(67,69,72,0.12)` | `#E8E0D7` | 1.21:1 | 罫線 |
| `--accent` | `#A85426` | — | **4.92:1** | AA。**文字・リンクに使える唯一のテラコッタ** |
| `--accent-vivid` | `#D08256` | — | 2.78:1 | **文字禁止。**線・アイコン・インジケータのみ |
| `--surface` | `#FFFFFF` | — | 面差 1.08:1 | カード・入力欄 |

`--ink` を `#FFFFFF` の面に載せた場合は 9.62:1【計算】。

**ダーク（地 = `#1C1D1F` / 面 = `#26282B`）**

| トークン | 値 | 実効色 | 対 地 | 対 面 | 判定 |
|---|---|---|--:|--:|---|
| `--ink` | `rgba(254,245,235,0.92)` | `#ECE4DB` | **13.40:1** | 11.85:1 | AA / AAA |
| `--ink-2` | `rgba(254,245,235,0.62)` | `#A8A39D` | **6.74:1** | 6.20:1 | AA |
| `--ink-3` | `rgba(254,245,235,0.50)` | `#8D8985` | **4.86:1** | 4.55:1 | AA |
| `--ink-4` | `rgba(254,245,235,0.35)` | `#6B6966` | 3.08:1 | 3.00:1 | 大きい文字・アイコンのみ |
| `--separator` | `rgba(254,245,235,0.14)` | `#3C3B3C` | 1.51:1 | — | 罫線 |
| `--accent` | `#D08256` | — | **5.63:1** | 4.93:1 | AA。**ダークでは原色のまま使える** |
| `--accent-vivid` | `#E09A70` | — | 7.25:1 | 6.35:1 | 強調 |
| `--surface-raised` | `#434548`（チャコール原色） | — | 面差 1.75:1 | — | 最上位の面。上に `--ink` で 7.86:1 |

> **`--surface-raised` の上ではアクセントが弱る。**
> `#D08256` を `#434548` に載せると 3.21:1、`#E09A70` でも 4.13:1【計算】。
> 持ち上がった面の上でアクセント文字を使うなら `--accent-vivid`（4.13:1）を選び、
> それでも本文サイズでは AA に届かないことを承知しておく。

**AA（4.5:1）を満たす最小アルファ**【計算】。トークンを増やすときの上限として使う。

| 組み合わせ | 4.5:1 に必要なα | 3:1 に必要なα |
|---|--:|--:|
| ライト: チャコール on クリーム | **0.75** | 0.58 |
| ダーク: クリーム on `#1C1D1F` | **0.47** | 0.34 |
| ダーク: クリーム on `#26282B` | **0.50** | 0.35 |

**ダークの方が薄いアルファで基準を満たす。**
ライトの二次テキストをダークと同じ 0.62 にすると **3.27:1 で AA を割る**【計算】。
ライトとダークで同じアルファ値を使い回してはいけない。

#### テラコッタを「塗り」に使う場合【計算】

| 文字色 | 地 `#D08256` | 地 `#A85426` |
|---|--:|--:|
| `#FFFFFF` | 3.00:1 ❌ | **5.30:1** ✅ |
| `#FEF5EB` | 2.78:1 ❌ | **4.92:1** ✅ |
| `#2A1B12` | **5.55:1** ✅ | 3.13:1 ❌ |

**`#D08256` を塗りにして白文字を載せる、という一番やりたくなる組み合わせが失敗する。**
塗りが必要なら `#A85426` + クリーム文字にする。
ただし DESIGN.md 第9.2章の「テラコッタは面積を持たせない」に従い、**塗りの使用は最小限にすること。**

#### CSS 変数の実装

```css
/* ------------------------------------------------------------------
   Sophia カラートークン
   原色（DESIGN.md 9.2）:
     クリーム   #FEF5EB
     チャコール #434548
     テラコッタ #D08256
   墨と罫線は macOS 流に「原色 + アルファ」で定義する。
   こうしないと vibrancy の上で色が浮く（4.5節）。
   ------------------------------------------------------------------ */
:root {
  /* 原色。ここは絶対に書き換えない */
  --sophia-cream:    254, 245, 235;   /* #FEF5EB */
  --sophia-charcoal:  67,  69,  72;   /* #434548 */
  --sophia-terra:    208, 130,  86;   /* #D08256 */

  /* ---- ライト（既定）---- */
  --bg:              #FEF5EB;                        /* 地。本文ペインに敷く */
  --surface:         #FFFFFF;                        /* カード・入力欄 */
  --surface-raised:  #FFFFFF;                        /* ライトでは surface と同じ（白が上限）*/
  --surface-sunken:  rgba(var(--sophia-charcoal), 0.05);

  --ink:             rgba(var(--sophia-charcoal), 1.00);   /*  8.92:1 */
  --ink-2:           rgba(var(--sophia-charcoal), 0.78);   /*  4.87:1 */
  --ink-3:           rgba(var(--sophia-charcoal), 0.60);   /*  3.14:1 大きい文字のみ */
  --ink-4:           rgba(var(--sophia-charcoal), 0.30);   /*  装飾のみ */
  --separator:       rgba(var(--sophia-charcoal), 0.12);

  --accent:          #A85426;                        /*  4.92:1 文字に使えるテラコッタ */
  --accent-vivid:    #D08256;                        /*  2.78:1 線・アイコン専用 */
  --accent-wash:     rgba(var(--sophia-terra), 0.12); /* 選択行の下地 */

  /* 状態色。生成中インジケータは accent-vivid（DESIGN.md 9.2）*/
  --danger:          #B3261E;
}

@media (prefers-color-scheme: dark) {
  :root {
    /* ---- ダーク: クリームとチャコールが役割を交換する ---- */
    --bg:              #1C1D1F;                      /* チャコールの色相を保った暗色 */
    --surface:         #26282B;
    --surface-raised:  #434548;                      /* チャコール原色。ここで再登場する */
    --surface-sunken:  rgba(0, 0, 0, 0.24);

    --ink:             rgba(var(--sophia-cream), 0.92);  /* 13.40:1 */
    --ink-2:           rgba(var(--sophia-cream), 0.62);  /*  6.74:1 */
    --ink-3:           rgba(var(--sophia-cream), 0.50);  /*  4.86:1 */
    --ink-4:           rgba(var(--sophia-cream), 0.35);  /*  3.08:1 大きい文字のみ */
    --separator:       rgba(var(--sophia-cream), 0.14);

    --accent:          #D08256;                      /*  5.63:1 ダークでは原色が使える */
    --accent-vivid:    #E09A70;                      /*  7.25:1 */
    --accent-wash:     rgba(var(--sophia-terra), 0.18);

    --danger:          #F2685E;
  }
}
```

> **`rgb()` の数値だけを変数に持ち、`rgba(var(--x), α)` で組み立てている**のは、
> 同じ原色から任意のアルファを作るため。色を16進で複製すると、
> テラコッタを微調整したときに置換漏れが必ず出る。

### 4.4 「透明度を下げる」設定への対応

macOS には「システム設定 > アクセシビリティ > ディスプレイ > 透明度を下げる」がある。
**これが ON のとき vibrancy を出し続けるのはアクセシビリティ上の後退である。**

```css
/* 透明度を下げる設定が ON なら、地を不透明に塗り直す */
@media (prefers-reduced-transparency: reduce) {
  .sidebar { background: var(--surface-sunken); }
  #app     { background: var(--bg); }
}
```

main プロセス側でも `nativeTheme.prefersReducedTransparency` を見て
`win.setVibrancy(null)` を呼ぶ選択肢がある【出典: `setVibrancy` は `null` で解除できる】。
**【推測】どちらが自然かは実機で比較すること。** CSS だけで足りる可能性が高い。

### 4.5 vibrancy の上で配色を成立させる

vibrancy は「地が固定の色ではなくなる」ことを意味する。**背後の壁紙によって明るさが変わる。**
そのままでは 4.3 節で計算したコントラスト比が保証されない。

**解決策は、ネイティブアプリと同じ構造を CSS で作ること。**
Notes も Mail も、**サイドバーだけが透け、本文ペインは不透明**である。

```css
/* ウィンドウ全体には vibrancy: 'sidebar' が当たっている（2.4節）。
   透けさせたい部分だけを transparent にし、
   文字を載せる本文ペインは不透明に塗り直す */

.sidebar {
  background: transparent;               /* ← ここだけ OS の材質が見える */
}

.content {
  /* 本文は不透明。ここで 4.3 節のコントラスト比が保証される */
  background: var(--bg);
}
```

これで **Electron の「1ウィンドウ1材質」という制約を回避しつつ、可読性を守れる。**

**副次的な利点として性能上も有利である。** 開発機はファンレスで、
生成中は GPU が推論に取られる（[TUNING.md](TUNING.md)）。
ぼかしの面積が小さいほどコンポジットの負荷は下がる。
【推測】具体的なフレーム時間の差は計測していない。

サイドバー上の文字は地が変動するため、**`--ink` / `--ink-2` までに留め、`--ink-3` 以下を使わない。**

---

## 5. Apple HIG の数値（AppKit からの実測）

Apple の Human Interface Guidelines のページは JavaScript で描画されており、
自動取得しても本文が得られなかった。**そのため HIG の文章を引用するのではなく、
AppKit の実際の値を macOS 26.5.2 上で計測した。** 以下はすべて【実測】である。

### 5.1 コントロールの高さ

【実測: `intrinsicContentSize`】

| 部品 | large | regular | small | mini |
|---|--:|--:|--:|--:|
| `NSButton`（角丸ボタン） | 28 | **24** | 20 | 16 |
| `NSTextField` | — | **24** | 22 | 19 |
| `NSPopUpButton` | — | **24** | — | — |
| `NSSearchField` | — | **24** | — | — |
| `NSButton`（チェックボックス） | — | 16 | — | — |

**macOS のコントロール標準高は 24px。** Web の癖で 36〜40px にすると、
それだけで「Mac のアプリではない」印象になる。
ただし Sophia の**送信ボタンなど主要動作は 28px**（large 相当）でよい。

### 5.2 サイドバー

【実測: `NSSplitViewItem(sidebarWithViewController:)` の既定値】

| 項目 | 値 |
|---|--:|
| `minimumThickness`（最小幅） | **140** |
| `automaticMaximumThickness`（自動時の最大幅） | **250** |
| `canCollapse` | `true` |
| `holdingPriority` | 260（本文は 250。**サイドバーが幅を保持する**） |
| サイドバー行の高さ（`NSOutlineView` sourceList） | **24** |
| 階層のインデント幅 | **12** |

→ **Sophia のサイドバーは既定 240px、最小 140px、最大 320px 程度。**
240px は AppKit の自動最大値 250 の内側に収まり、日本語の会話タイトルも収まる幅である。
【推測】240 という具体値は 140〜250 の範囲から選んだ設計判断で、実測値そのものではない。

### 5.3 タイトルバー・トラフィックライト

2.3 節の表を参照。要点だけ再掲【実測】:

| 項目 | 値 |
|---|--:|
| 標準タイトルバーの高さ | 32 |
| ツールバー付き（unified）の高さ | **52** |
| トラフィックライトの大きさ | 14 × 14 |
| ボタン原点の間隔 | 23（隙間 9） |
| 3個ぶんの幅 | 60 |

### 5.4 余白のリズム

**macOS の公式なグリッド数値は公開されていない。**
ただし 5.1〜5.3 の実測値のうち、面と面の関係を決める値
（コントロール高 16 / 20 / 24 / 28、タイトルバー 32 / 52、インデント 12、行高 24）は
**すべて 4 の倍数**である。一方でトラフィックライトの 14 / 9 / 23 や
`NSTextField` の small = 22、サイドバー最大 250 のように、4 の倍数でない実測値も存在する。
**「4 の倍数がリズムの基調」であって「全部が 4 の倍数」ではない。**

| 段 | 値 | 用途 |
|--:|--:|---|
| 1 | 4px | アイコンと文字の隙間 |
| 2 | 8px | 関連する要素の間 |
| 3 | 12px | サイドバー行の左右パディング、階層インデント |
| 4 | 16px | ペイン内側の標準パディング |
| 5 | 20px | 段落・ブロックの間 |
| 6 | 24px | 大きな区切り |

```css
:root {
  --sp-1: 4px;  --sp-2: 8px;  --sp-3: 12px;
  --sp-4: 16px; --sp-5: 20px; --sp-6: 24px;
}
```

**【推測】この 6 段は 5.1〜5.3 の実測値（12・16・24・52）から逆算した整理であり、
Apple が公開している数値ではない。**

### 5.5 角丸

**部品の角丸半径について、AppKit は値を公開していない**（`NSBox.cornerRadius` の既定は 0）【実測】。
ウィンドウの角丸だけは非公開 API から **16pt** が読めた（2.6節）。

【推測】以下は macOS 26 の見た目に合わせた提案値であり、**実測に基づかない**。
A1 で純正アプリと並べて調整すること。

| 対象 | 提案 |
|---|--:|
| ボタン・入力欄（高さ 24〜28） | 6px |
| カード・吹き出し | 10px |
| サイドバーの選択行 | 6px |
| ポップオーバー | 10px |
| ウィンドウ | **触らない**（OS 任せ） |

### 5.6 罫線

`separatorColor` は黒 9.8%（ライト）/ 白 9.8%（ダーク）【実測】。

太さについては AppKit に数値を返す API がなく、**測れていない**。
【推測】macOS の罫線は 1pt が標準である。CSS でも `1px` と書く（macOS では CSS px = pt）。
`0.5px` にすると Retina で 1 デバイスピクセルの髪の毛線になり、macOS より細くなる。

---

## 6. ネイティブ部品

### 6.1 アプリケーションメニュー

【出典: `docs/api/menu.md` / `menu-item.md`】

**macOS ではメニューバーを Web で描くことはできない。** `Menu` API を使う。
これを設定しないと、Electron の既定メニュー（英語、アプリ名が "Electron"）が出る。

`role` を使うと**ラベルの多言語化・キーボードショートカット・有効/無効の管理を OS に任せられる。**
【出典: `menu-item.md` の `role` 一覧】主なもの:

`appMenu` / `fileMenu` / `editMenu` / `viewMenu` / `windowMenu` /
`undo` `redo` `cut` `copy` `paste` `pasteAndMatchStyle` `selectAll` `delete` /
`toggleSpellChecker` `showSubstitutions` `toggleSmartQuotes` /
`startSpeaking` `stopSpeaking` / `minimize` `close` `zoom` `front` /
`togglefullscreen` `resetZoom` `zoomIn` `zoomOut` `toggleDevTools` /
`about` `services` `hide` `hideOthers` `unhide` `quit`

```ts
// src/main/menu.ts
import { app, Menu, shell } from 'electron'
import type { MenuItemConstructorOptions } from 'electron'

export function installApplicationMenu (onNewChat: () => void, onStop: () => void) {
  const template: MenuItemConstructorOptions[] = [
    // macOS では先頭が必ずアプリメニューになる。role: 'appMenu' で標準構成が入る
    { role: 'appMenu' },
    {
      label: 'ファイル',
      submenu: [
        { label: '新しい会話', accelerator: 'CmdOrCtrl+N', click: onNewChat },
        { type: 'separator' },
        { role: 'close', label: 'ウィンドウを閉じる' },
      ],
    },
    // 編集メニューは role 任せにする。
    // これを省くと Cmd+C / Cmd+V が効かなくなる（macOS の編集操作はメニュー経由のため）
    { role: 'editMenu', label: '編集' },
    {
      label: '生成',
      submenu: [
        // FR-02 中断。ショートカットからも止められるようにする
        { label: '生成を中断', accelerator: 'CmdOrCtrl+.', click: onStop },
      ],
    },
    { role: 'viewMenu', label: '表示' },
    { role: 'windowMenu', label: 'ウィンドウ' },
  ]
  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}
```

> **`{ role: 'editMenu' }` を省略してはいけない。**
> macOS ではコピー・ペーストがメニュー項目に紐づいており、
> メニューを自作して編集メニューを落とすと **Cmd+C / Cmd+V が効かなくなる。**
> 【推測】この因果は macOS の標準的な仕組みだが、本環境で再現確認はしていない。

**バージョン表示（A1 完成条件8）について。**
UI 内にも `ver 0.1.0` を出すが、**同時に About パネルも整えるべきである**。
`app.setAboutPanelOptions({ applicationName, applicationVersion, version, credits })`
で `role: 'about'` の内容を差し替えられる【出典: `docs/api/app.md`】。【推測】未検証。

### 6.2 コンテキストメニュー

【出典: `docs/tutorial/context-menu.md`】`webContents` の `context-menu` イベントで
`params` を受け取り、`Menu.popup()` で出す。

```ts
// src/main/context-menu.ts
import { Menu, BrowserWindow } from 'electron'

export function installContextMenu (win: BrowserWindow) {
  win.webContents.on('context-menu', (_event, params) => {
    const items: Electron.MenuItemConstructorOptions[] = []

    // スペルチェックの候補（params.dictionarySuggestions）
    for (const s of params.dictionarySuggestions) {
      items.push({ label: s, click: () => win.webContents.replaceMisspelling(s) })
    }
    if (items.length) items.push({ type: 'separator' })

    if (params.selectionText) {
      items.push({ role: 'copy', label: 'コピー' })
    }
    if (params.isEditable) {
      items.push({ role: 'cut', label: '切り取り' }, { role: 'paste', label: 'ペースト' })
    }
    if (items.length === 0) return
    Menu.buildFromTemplate(items).popup({ window: win })
  })
}
```

`params` から取れる主なもの【出典: `docs/api/web-contents.md`】:
`selectionText` / `isEditable` / `misspelledWord` / `dictionarySuggestions` / `editFlags` / `linkURL`。

**2.5 節のとおり、ドラッグ領域の上では独自のコンテキストメニューを出さない。**

### 6.3 ダイアログ

【出典: `docs/api/dialog.md`】

**`browserWindow` を渡すと macOS ではシート（ウィンドウ上端から降りてくる帯）になる。**
渡さないと独立したウィンドウとして出る。**シートの方が圧倒的にネイティブに見える。**

FR-04（会話の削除は取り消せない旨を提示する）の実装例:

```ts
import { dialog, BrowserWindow } from 'electron'

async function confirmDeleteConversation (win: BrowserWindow, title: string) {
  const { response } = await dialog.showMessageBox(win, {   // ← win を渡すとシートになる
    type: 'warning',
    // macOS ではボタンは右から左に並ぶ。defaultId / cancelId は必ず指定する
    buttons: ['削除', 'キャンセル'],
    defaultId: 0,
    cancelId: 1,
    message: `「${title}」を削除しますか？`,
    detail: 'この操作は取り消せません。会話の内容は完全に削除されます。',
  })
  return response === 0
}
```

| API | 用途 |
|---|---|
| `dialog.showMessageBox(win, opts)` | 確認・警告。`type`: `none`/`info`/`error`/`question`/`warning` |
| `dialog.showSaveDialog(win, opts)` | FR-12（Markdown 書き出し） |
| `dialog.showOpenDialog(win, opts)` | FR-15（将来の RAG） |
| `dialog.showErrorBox(title, content)` | **`app.whenReady()` の前でも使える。**起動時エラー用 |

**FR-11（失敗の原因と対処を日本語で提示）は `showErrorBox` ではなく、
`showMessageBox` の `message` + `detail` で書く。**
`showErrorBox` はスタイルが素っ気なく、対処法を書く場所がない。

### 6.4 その他のネイティブ機能

| 機能 | API | Sophia での用途 |
|---|---|---|
| Dock バッジ | `app.dock.setBadge()` | 【推測】生成完了の通知に使えるが、A1 では不要 |
| 通知 | `new Notification()` | 【推測】バックグラウンド時の生成完了。A3 以降 |
| プログレスバー | `win.setProgressBar()` | FR-07（モデル取得の進捗）。Dock アイコンに出る。**A3** |
| スペルチェック | `webPreferences.spellcheck` | 6.2 と連動 |

---

## 7. やってはいけないこと

**AppKit の見た目を CSS で再現しようとすると、必ず不気味の谷に落ちる。**
以下は「それらしく見えるが、純正アプリと並べた瞬間に偽物とわかる」典型例である。

### 7.1 AppKit 風の CSS ライブラリを入れる

DESIGN.md および CLAUDE.md で明示的に禁止されている。
理由は「似ているが違う」が最も悪い結果になるため。
ライブラリは OS の更新に追随できず、**新しい macOS が出た瞬間に全体が古びる。**
Sophia は「OS が描くものは OS に描かせ、それ以外は Sophia 自身の顔を出す」方針を採る。

### 7.2 トラフィックライトを HTML で描く

`titleBarStyle: 'customButtonsOnHover'` を使えば独自のボタンを描けるが、
【出典: 公式ドキュメント】このオプションは **experimental** と明記されている。
自前で描いた3つの丸は、次のいずれかで必ず破綻する:

- ホバー時の記号（×・−・+）の描画
- ウィンドウ非アクティブ時の灰色化
- フルスクリーン遷移時の消失とアニメーション
- 「フルスクリーンにする / ウィンドウを画面いっぱいにする」のメニュー
- macOS 26 の Liquid Glass のようなシステム全体の意匠変更

**OS のボタンを使い、位置だけ `trafficLightPosition` で合わせる。**

### 7.3 `backdrop-filter` で vibrancy を代替する

`backdrop-filter: blur()` がぼかせるのは**ウィンドウ内部の要素だけ**である。
【出典: `docs/tutorial/custom-window-styles.md`】
「The CSS `blur()` filter only applies to the window's web contents, so there is
no way to apply blur effect to the content below the window」。
**壁紙や他アプリはぼけない。** vibrancy とは別物であり、代わりにならない。

サイドバーに `backdrop-filter` を掛けると、**本文がサイドバーの裏に透けてぼやける**という
macOS にはない見え方になる。これは典型的な「Electron っぽさ」の原因である。

### 7.4 ウィンドウの角丸・影を CSS で描く

2.6 節のとおり。macOS 26 の半径は 16pt【実測】だが、これは OS のバージョンで変わる。
実際、Electron 自身が macOS 26 でのアプリごとの角丸の不一致を issue として抱えている
【出典: electron/electron#47514。ビルドに使った Xcode SDK により角丸が変わる】。
**固定値を書いた時点で、次の OS で古く見えることが確定する。**

### 7.5 フォントを「それらしく」指定する

- `'SF Pro Text'` / `'SF Pro Display'` / `'SF Mono'` → **すべて解決しない**【実測】(3.2節)
- `-apple-system` 単独 → **Chromium では解決しない**【実測】(3.1節)
- `-webkit-font-smoothing: antialiased` → 純正より細くなる (3.6節)
- 日本語を指定せずに放置 → 純正より 1 段細い W3 になる【実測】(3.3節)

### 7.6 Web の寸法感を持ち込む

| Web の癖 | macOS の実測値 |
|---|---|
| 本文 16px | UI は **13px**【実測】 |
| ボタン高 40px | **24px**（主要動作でも 28px）【実測】 |
| 行の高さ 1.5em | body は 13px に対し **16px**（≒1.23）【実測】 |
| 角丸 4px または 8px 一律 | 部品の大きさに応じて変える（5.5節） |
| 影で階層を作る | macOS は**面の明度差と罫線**で階層を作る。影はウィンドウとポップオーバーだけ |

### 7.7 ドラッグ領域を body 全体に敷く

公式ドキュメントに `body { app-region: drag }` の例があるが、
【出典: 同ドキュメントの注意書き】「you must also mark buttons as non-draggable,
otherwise it would be impossible for users to click on them」。
会話アプリでこれをやると、**本文のテキスト選択もスクロールも死ぬ。**
2.5 節の落とし穴1のとおり、`drag` は「何も置かない帯」に限定する。

### 7.8 アニメーションを足す

macOS のアプリは驚くほどアニメーションが少ない。
ホバーでの色変化は 0.1s 前後、それ以外は基本的に即座に切り替わる。
Web 的なイージング（0.3s の `ease-in-out` など）を全体に掛けると、**動きが重く感じる。**
`prefers-reduced-motion` にも対応すること（4.1節の表で対応を確認済み【実測】）。

---

## 8. 現状コードとの差分（2026-08-16 時点の `app/` に対する申し送り）

`app/src/main/window.ts` に「`docs/UI_NATIVE.md` ができたら実測に合わせて詰める」という
申し送りコメントが置かれていたので、**その回答をここに書く。**
本節は 2026-08-16 時点の `app/` を読んで書いた。**着手前に現物を再確認すること。**

### 8.1 `app/src/main/window.ts`

| 現状 | 本書の結論 | 根拠 |
|---|---|---|
| `vibrancy: 'under-window'` | **`'sidebar'` へ** | 壁紙が強く透けてクリームの色が消える。Notes / Mail と同型の画面なら `sidebar`（2.1節） |
| `visualEffectState: 'followWindow'` | **`'active'` へ** | 生成に15〜30秒かかる間に別アプリへ移ると、ウィンドウが灰色に沈み「止まった」ように見える（2.2節） |
| `trafficLightPosition: { x: 16, y: 18 }` | **`{ x: 19, y: 19 }` へ** | 52pt のヘッダに対する macOS 純正の実測値は x=19 / y=19。y=18 だとコンテナが 50pt になりヘッダの 52px と 2px ずれる（2.3節） |
| `titleBarStyle: 'hiddenInset'` | **`'hidden'` へ** | `hiddenInset` の既定 `(12,11)` は純正と合っておらず、Electron 自身がソースのコメントで認めている。座標を明示するなら `hidden` の方が意図が明確（2.3節） |
| `titleBarOverlay` なし | **`{ height: 52 }` を追加** | これがないと `env(titlebar-area-x)` が使えず、ヘッダ左余白をベタ書きすることになる（2.3節） |
| macOS では `backgroundColor` を指定していない | **`backgroundColor: '#00000000'` を追加** | **既定は `#FFF`。contentView のレイヤが白で塗られ、vibrancy が一切見えない**（2.4節） |
| `transparent: false` | **そのままでよい** | `transparent: true` は影が消えリサイズが不安定になる（2.7節） |

### 8.2 `app/src/renderer/src/index.css`

| 現状 | 本書の結論 | 根拠 |
|---|---|---|
| `body { background: var(--sophia-bg) }` | **`html, body` は `background: transparent`。地は本文ペイン側で塗る** | 不透明な body は vibrancy を完全に隠す（2.4・4.5節） |
| `font-size: 14px` | **UI は 13px / 行 16px。会話本文のみ 15px / 行 24px** | `NSFont.systemFontSize = 13.0`【実測】（3.5節） |
| `line-height: 1.7` | **数値ではなく px で指定**（body 16px、本文 24px） | AppKit の行高は絶対値で決まっている（3.5節） |
| `-webkit-font-smoothing: antialiased` | **削除** | 純正アプリより文字が細くなる（3.6節） |
| `-apple-system, BlinkMacSystemFont, 'Hiragino Sans', ...` | 実効は `BlinkMacSystemFont` のみ。**日本語は `@font-face` + `local('HiraginoSans-W4')` で固定** | `-apple-system` は Chromium で解決しない【実測】。自動フォールバックは純正より1段細い W3 になる【実測】（3.1・3.3節） |
| `ui-monospace, 'SF Mono', SFMono-Regular, Menlo, monospace` | 実効は **Menlo** のみ。末尾に `'SophiaJP'` を足す | `ui-monospace` / `'SF Mono'` / `SFMono-Regular` はいずれも解決しない【実測】。日本語が Osaka-Mono になるのを防ぐ（3.1・3.4節） |
| `-webkit-app-region: drag` | `app-region: drag` に統一 | 現行ドキュメントは接頭辞なし。両方効くが混在させない（2.5節） |
| 色が `--sophia-charcoal` などの単色定数 | **第4.3節のアルファ方式トークンへ置き換え** | vibrancy の上で単色を敷くと地が浮く。macOS 自身がアルファで墨を定義している（4.2・4.3節） |
| ダークモードの分岐 | **`@media (prefers-color-scheme: dark)` を追加。ライトとアルファ値を共用しない** | ライトで 0.62 は 3.27:1 で AA を割る【計算】（4.3節） |

> **`--sophia-titlebar-height: 52px`（CSS）と `trafficLightPosition.y`（main）は連動している。**
> 片方だけ変えると信号機とヘッダの中心がずれる。
> **52px を保つなら y は 19。** 関係式は `コンテナ高 = 14 + 2 × y`（2.3節）。

---

## 9. A1 実装チェックリスト

本書の内容のうち、A1（[REQUIREMENTS.md](REQUIREMENTS.md) 第8章）で実装・確認するもの。

**実装**

- [ ] `titleBarStyle: 'hidden'` + `trafficLightPosition: {x:19, y:19}` + `titleBarOverlay: {height:52}`（2.4節）
- [ ] `vibrancy: 'sidebar'` + `visualEffectState: 'active'` + `backgroundColor: '#00000000'`（2.4節）
- [ ] `html, body { background: transparent }`、本文ペインのみ不透明（4.5節）
- [ ] ヘッダの左パディングを `env(titlebar-area-x, 98px)` で取る（2.3節）
- [ ] ドラッグ領域はヘッダの「空き帯」だけ。ボタンは `app-region: no-drag`（2.5節）
- [ ] フォントスタックは `BlinkMacSystemFont` を先頭側に。`@font-face` + `local('HiraginoSans-W4')` で日本語を固定（3.3〜3.4節）
- [ ] 第4.3節のカラートークンをそのまま導入。ライトとダークでアルファ値を共用しない
- [ ] `@media (prefers-color-scheme: dark)` / `(prefers-reduced-transparency: reduce)` の分岐（4.1・4.4節）
- [ ] `Menu.setApplicationMenu`。`{ role: 'editMenu' }` を必ず含める（6.1節）
- [ ] UI に `ver 0.1.0` を表示（完成条件8）。`--text-footnote` (10px) / `--ink-3`
- [ ] 第8章の差分表を上から順に潰す

**実機で目視確認（本書で確認できなかったもの）**

- [ ] vibrancy が実際に見えているか（サイドバーに壁紙が透けるか）
- [ ] ウィンドウ四隅に段差・隙間・色の食い違いがないか（2.6節。Electron のマスク 9pt vs OS の 16pt）
- [ ] トラフィックライトの位置が Notes / Mail と揃っているか（並べて確認）
- [ ] 日本語の太さが純正アプリと揃っているか（Notes と並べて確認）
- [ ] ヘッダをドラッグしてウィンドウが動くか。ボタンがクリックできるか
- [ ] ヘッダのダブルクリック挙動（2.5節の落とし穴2）
- [ ] システム設定でダークに切り替えて即座に追従するか
- [ ] 「透明度を下げる」を ON にしたときの見え方（4.4節）

---

## 10. 未確認事項

| # | 内容 | 影響 | 対応時期 |
|---|---|---|---|
| 1 | **vibrancy の実際の見え方を確認していない。** 本環境は画面キャプチャの権限がなく撮影できなかった | 第2章の「見え方」の記述は全て推測 | A1 の目視確認 |
| 2 | **macOS 26 の角丸 16pt と Electron のマスク 9pt の食い違い**（2.6節）。視覚的な破綻の有無 | 四隅の見た目 | A1 の目視確認 |
| 3 | **macOS 26 の Liquid Glass に Electron がどこまで追随するか。** Electron のビルド SDK により角丸などが変わる（electron/electron#47514、未解決） | 新 OS で古く見える可能性 | A4（パッケージング）時に再調査 |
| 4 | **ヘッダのダブルクリック挙動**（2.5節の落とし穴2）。提示したコードは未実行 | 些細だが「らしさ」に効く | A1 |
| 5 | **`app-region` の動的切替**が反映されない問題の再現有無（2.5節の落とし穴5） | 静的な帯で組めば無関係 | 必要になったら |
| 6 | **`-webkit-font-smoothing` を外した場合の見た目差**を並べて比較していない（3.6節） | 文字の太さ | A1 の目視確認 |
| 7 | **会話本文 15px / 行 24px** は AppKit 実測値ではなく設計判断（3.5節） | 読みやすさ | A1 で調整 |
| 8 | **部品の角丸半径**（5.5節）は AppKit が値を公開しておらず、提案値はすべて推測 | 見た目 | A1 で純正と並べて調整 |
| 9 | **`::selection` とフォーカスリングにシステムアクセント（青）を使うか**（4.2節） | 配色の一貫性 vs 慣習 | A1 で両方試す |
| 10 | **`app.setAboutPanelOptions`** の動作（6.1節）| About パネルの内容 | A1 |
| 11 | **Electron のメジャー更新時**、第3章のフォント解決を取り直す必要がある（Chromium 148 と 151 で挙動差を実測済み） | 日本語の太さが変わる | 依存更新のたび |

---

## 付録: 参照した一次情報

| 種別 | 参照先 |
|---|---|
| Electron ドキュメント | `docs/api/structures/base-window-options.md` / `docs/api/browser-window.md` / `docs/api/base-window.md` / `docs/api/native-theme.md` / `docs/api/system-preferences.md` / `docs/api/menu-item.md` / `docs/api/dialog.md` / `docs/tutorial/custom-title-bar.md` / `docs/tutorial/custom-window-interactions.md` / `docs/tutorial/custom-window-styles.md` / `docs/tutorial/context-menu.md` / `docs/breaking-changes.md` |
| Electron ソース | `shell/browser/native_window.cc` / `shell/browser/native_window_mac.mm` / `shell/browser/ui/cocoa/window_buttons_proxy.mm` / `shell/browser/ui/cocoa/electron_ns_window.mm` |
| Chromium ソース | `third_party/blink/renderer/platform/fonts/font_family_names.json5` |
| Electron の既知の問題 | electron/electron#47514（macOS 26 の角丸と Xcode SDK） |
| 実測 | AppKit（Swift）/ Electron 42.9.1 / Chrome DevTools Protocol の `CSS.getPlatformFontsForNode` / WCAG 2.1 相対輝度の計算 |
