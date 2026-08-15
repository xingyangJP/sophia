#!/usr/bin/env python3
"""Sophia ローカルLLMベンチマーク

Ollama の /api/generate をストリーミングで叩き、体感速度を左右する指標を計測する。

  TTFT      最初の1文字が出るまでの秒数。体感の「反応の速さ」はほぼこれで決まる
  gen tok/s 生成速度。長文を書かせたときの待ち時間を決める
  pp tok/s  プロンプト処理速度。長いコンテキストを渡したときの初速に効く
  load      モデルをメモリに載せる時間。常駐していれば 0 に近い

追加パッケージ不要（標準ライブラリのみ）。

使い方:
    python3 scripts/bench.py --models qwen3:8b qwen2.5-coder:7b
    python3 scripts/bench.py --models qwen3:8b --ctx 16384 --runs 5
    python3 scripts/bench.py --models qwen3:8b --save    # 結果を docs/BENCH_RESULTS.md に追記
"""

from __future__ import annotations

import argparse
import json
import platform
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

HOST = "http://localhost:11434"
REPO = Path(__file__).resolve().parent.parent
RESULTS = REPO / "docs" / "BENCH_RESULTS.md"

# 用途ごとに性格の違う3種類。速度はプロンプトの長さと生成量で変わるので、
# 実際の使い方に近い負荷でないと比較の意味がない。
PROMPTS: dict[str, str] = {
    "chat_ja": "日本語で、リモートワークの利点と欠点を3つずつ挙げて簡潔に説明してください。",
    "write_ja": (
        "あなたは技術系の編集者です。以下のテーマで、社内向けアナウンス文を"
        "600字程度の日本語で書いてください。読み手は非エンジニアの管理職です。\n\n"
        "テーマ: 社内文書の検索に、外部サービスを使わないローカルAIを導入する"
    ),
    "code": (
        "Write a Python function that parses an ISO-8601 duration string "
        "(e.g. 'P3DT4H5M6S') into a datetime.timedelta. Handle weeks, and raise "
        "ValueError on malformed input. Include docstring and type hints."
    ),
}


def post_stream(model: str, prompt: str, options: dict) -> dict:
    """1回生成して計測値を返す。TTFT を取るためストリーミングで受ける。"""
    body = json.dumps(
        {"model": model, "prompt": prompt, "stream": True, "options": options}
    ).encode()
    req = urllib.request.Request(
        f"{HOST}/api/generate", data=body, headers={"Content-Type": "application/json"}
    )

    started = time.perf_counter()
    ttft: float | None = None
    final: dict = {}

    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw in resp:
            if not raw.strip():
                continue
            chunk = json.loads(raw)
            # 最初に実際のテキストが乗ったチャンクが来た時刻を TTFT とする
            if ttft is None and chunk.get("response"):
                ttft = time.perf_counter() - started
            if chunk.get("done"):
                final = chunk

    ns = 1_000_000_000
    eval_count = final.get("eval_count") or 0
    eval_dur = final.get("eval_duration") or 0
    pp_count = final.get("prompt_eval_count") or 0
    pp_dur = final.get("prompt_eval_duration") or 0

    return {
        "ttft": ttft if ttft is not None else float("nan"),
        "gen_tps": (eval_count / (eval_dur / ns)) if eval_dur else float("nan"),
        "pp_tps": (pp_count / (pp_dur / ns)) if pp_dur else float("nan"),
        "load": (final.get("load_duration") or 0) / ns,
        "total": (final.get("total_duration") or 0) / ns,
        "out_tokens": eval_count,
        "in_tokens": pp_count,
    }


def resident_size(model: str) -> str:
    """`ollama ps` から実際にメモリへ載っているサイズを拾う。予算管理の実測値。"""
    try:
        out = subprocess.run(
            ["ollama", "ps"], capture_output=True, text=True, timeout=15
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return "-"
    for line in out.splitlines()[1:]:
        if line.startswith(model.split(":")[0]):
            cols = line.split()
            # NAME ID SIZE(数値 + 単位) PROCESSOR ... の並び
            for i, c in enumerate(cols):
                if c.upper() in {"GB", "MB"} and i > 0:
                    return f"{cols[i - 1]} {c.upper()}"
    return "-"


def med(values: list[float]) -> float:
    clean = [v for v in values if v == v]  # NaN を除外
    return statistics.median(clean) if clean else float("nan")


def cooldown(seconds: int, label: str) -> None:
    """本体を冷ます。ファンレス機では実行順で結果が最大2倍変わるため、
    条件を揃えたい比較では必須。"""
    if seconds <= 0:
        return
    print(f"  冷却待ち {seconds}s ({label})", end="", flush=True)
    for _ in range(seconds // 10 or 1):
        time.sleep(min(10, seconds))
        print(".", end="", flush=True)
    print(" 再開")


def bench_model(
    model: str, presets: list[str], runs: int, options: dict, cool: int = 0
) -> list[dict]:
    rows = []
    for name in presets:
        prompt = PROMPTS[name]
        cooldown(cool, f"{model}/{name} の前")
        print(f"  [{model}] {name} ", end="", flush=True)

        # ウォームアップ。1回目はモデルのロード時間が混ざり、比較を歪めるので捨てる。
        try:
            post_stream(model, prompt, {**options, "num_predict": 8})
        except urllib.error.URLError as e:
            print(f"\n  ! {model} を実行できません: {e}")
            return rows

        samples = []
        for _ in range(runs):
            samples.append(post_stream(model, prompt, options))
            print(".", end="", flush=True)
        print(" ok")

        rows.append(
            {
                "model": model,
                "preset": name,
                "ttft": med([s["ttft"] for s in samples]),
                "gen_tps": med([s["gen_tps"] for s in samples]),
                "pp_tps": med([s["pp_tps"] for s in samples]),
                "in_tokens": samples[0]["in_tokens"],
                "out_tokens": int(med([float(s["out_tokens"]) for s in samples])),
                "size": resident_size(model),
            }
        )
    return rows


def to_markdown(rows: list[dict]) -> str:
    head = (
        "| モデル | プリセット | TTFT(s) | 生成 tok/s | 入力処理 tok/s | "
        "入力tok | 出力tok | 常駐 |\n"
        "|---|---|--:|--:|--:|--:|--:|--:|\n"
    )
    body = "".join(
        f"| `{r['model']}` | {r['preset']} | {r['ttft']:.2f} | {r['gen_tps']:.1f} | "
        f"{r['pp_tps']:.0f} | {r['in_tokens']} | {r['out_tokens']} | {r['size']} |\n"
        for r in rows
    )
    return head + body


def main() -> int:
    ap = argparse.ArgumentParser(description="ローカルLLMの速度を計測する")
    ap.add_argument("--models", nargs="+", required=True, help="計測するモデル名")
    ap.add_argument("--ctx", type=int, default=8192, help="num_ctx (既定: 8192)")
    ap.add_argument("--predict", type=int, default=256, help="生成トークン上限")
    ap.add_argument("--runs", type=int, default=3, help="各条件の試行回数（中央値を採用）")
    ap.add_argument(
        "--preset", nargs="+", default=list(PROMPTS), choices=list(PROMPTS)
    )
    ap.add_argument(
        "--cooldown",
        type=int,
        default=0,
        help="各計測の前に待つ秒数。ファンレス機では実行順で結果が最大2倍変わるため、"
        "設定変更の前後を比較するときは 120 以上を推奨",
    )
    ap.add_argument("--save", action="store_true", help="docs/BENCH_RESULTS.md に追記")
    ap.add_argument("--note", default="", help="結果に添える条件メモ")
    args = ap.parse_args()

    options = {
        "num_ctx": args.ctx,
        "num_predict": args.predict,
        "temperature": 0.7,
        "seed": 42,  # 生成量を揃えて比較可能にする
    }

    try:
        urllib.request.urlopen(f"{HOST}/api/tags", timeout=5)
    except urllib.error.URLError:
        print(f"Ollama に接続できません ({HOST})。`make serve` で起動してください。")
        return 1

    print(
        f"num_ctx={args.ctx} / num_predict={args.predict} / runs={args.runs}"
        f" / cooldown={args.cooldown}s"
    )
    if args.cooldown == 0 and len(args.models) > 1:
        print(
            "  ※ 冷却なしで複数モデルを測ると、後のモデルが熱制限で最大2倍遅く出ます。\n"
            "     設定変更の前後を比較する目的なら --cooldown 120 を付けてください。"
        )
    rows: list[dict] = []
    for m in args.models:
        rows += bench_model(m, args.preset, args.runs, options, args.cooldown)

    if not rows:
        print("計測できた結果がありません。")
        return 1

    table = to_markdown(rows)
    print("\n" + table)

    if args.save:
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
        chip = platform.processor() or platform.machine()
        header = (
            f"\n## {stamp}\n\n"
            f"- 条件: `num_ctx={args.ctx}` / `num_predict={args.predict}` / "
            f"runs={args.runs} / cooldown={args.cooldown}s / {chip}\n"
            f"- 実行順: {' → '.join(args.models)}"
            f"{'（冷却なし。後のモデルほど熱制限を受ける）' if args.cooldown == 0 else ''}\n"
        )
        if args.note:
            header += f"- メモ: {args.note}\n"
        RESULTS.parent.mkdir(parents=True, exist_ok=True)
        if not RESULTS.exists():
            RESULTS.write_text(
                "# ベンチマーク履歴\n\n"
                "`make bench` の結果を時系列で残す。設定を変えたときに"
                "「本当に速くなったか」を後から確認するための記録。\n",
                encoding="utf-8",
            )
        with RESULTS.open("a", encoding="utf-8") as f:
            f.write(header + "\n" + table)
        print(f"追記しました: {RESULTS.relative_to(REPO)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
