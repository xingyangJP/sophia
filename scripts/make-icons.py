#!/usr/bin/env python3
"""assets/logo.png から macOS アプリアイコン一式を生成する。

macOS は iOS と違い、アイコンを自動で角丸にマスクしない。
開発者が「スクワークル形状 + 周囲の余白」を画像に焼き込む必要がある。
これを怠ると Dock で他アプリより大きく角張って見える。

Apple の macOS アイコングリッド:
  キャンバス 1024x1024 の中央に、824x824 のスクワークルを置く（各辺100pxの余白）。

生成物:
  assets/icon.png            1024x1024。electron-builder が参照する
  assets/icon.icns           macOS ネイティブのアイコン形式
  assets/icon.iconset/       中間ファイル（.gitignore 済み）

実行:
  uv run --with pillow python scripts/make-icons.py
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "assets" / "logo.png"
OUT = REPO / "assets"

CANVAS = 1024
# Apple の macOS アイコングリッド。1024キャンバスに対し 824 の角丸正方形。
SHAPE = 824
MARGIN = (CANVAS - SHAPE) // 2
# 角の丸み。Apple のスクワークルは連続曲率だが、超楕円で十分近似できる。
SUPERELLIPSE_N = 5.0
# アンチエイリアス用の拡大率。マスクを大きく作って縮小する。
SS = 4

# .icns に必要なサイズ一覧（名前は Apple 指定）
ICONSET = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]


def squircle_mask(size: int) -> Image.Image:
    """超楕円 |x|^n + |y|^n = 1 でスクワークルのマスクを作る。
    n が大きいほど正方形に近づく。n=5 前後が Apple の形状に近い。"""
    big = size * SS
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    r = big / 2.0

    # 各行について、超楕円の内側に入る x の範囲を塗る。
    for py in range(big):
        y = (py + 0.5 - r) / r
        ay = abs(y) ** SUPERELLIPSE_N
        if ay >= 1.0:
            continue
        x_half = (1.0 - ay) ** (1.0 / SUPERELLIPSE_N) * r
        draw.line([(r - x_half, py), (r + x_half, py)], fill=255)

    return mask.resize((size, size), Image.LANCZOS)


def main() -> int:
    if not SRC.exists():
        print(f"元画像が見つかりません: {SRC}", file=sys.stderr)
        return 1

    logo = Image.open(SRC).convert("RGB")
    print(f"元画像: {logo.size[0]}x{logo.size[1]}")

    # ロゴを形状サイズへ。元が正方形でない場合は中央を正方形に切り出す。
    w, h = logo.size
    if w != h:
        side = min(w, h)
        logo = logo.crop(
            ((w - side) // 2, (h - side) // 2, (w + side) // 2, (h + side) // 2)
        )
        print(f"  正方形に切り出し: {side}x{side}")
    logo = logo.resize((SHAPE, SHAPE), Image.LANCZOS)

    # 透明キャンバスの中央に、スクワークルでマスクしたロゴを置く。
    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    icon.paste(logo, (MARGIN, MARGIN), squircle_mask(SHAPE))

    OUT.mkdir(parents=True, exist_ok=True)
    icon.save(OUT / "icon.png")
    print(f"生成: assets/icon.png ({CANVAS}x{CANVAS}, 角は透明)")

    # .iconset を作って iconutil で .icns へ変換する（macOS 標準ツール）
    iconset = OUT / "icon.iconset"
    iconset.mkdir(exist_ok=True)
    for size, name in ICONSET:
        icon.resize((size, size), Image.LANCZOS).save(iconset / name)
    print(f"生成: assets/icon.iconset/ ({len(ICONSET)}サイズ)")

    result = subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "icon.icns")],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"iconutil に失敗: {result.stderr}", file=sys.stderr)
        return 1
    size_kb = (OUT / "icon.icns").stat().st_size // 1024
    print(f"生成: assets/icon.icns ({size_kb} KB)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
