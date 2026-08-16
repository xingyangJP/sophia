#!/usr/bin/env python3
"""Sophia 入力処理（プリフィル）速度の切り分け計測

`scripts/bench.py` は「体感速度」を測る道具で、同じプロンプトを繰り返し送る。
そのため2回目以降はプレフィックスキャッシュに全命中し、Ollama が返す
`prompt_eval_count / prompt_eval_duration` は **実際には計算していないトークンまで
分子に入れた値** になる（docs/BENCH_RESULTS.md 2026-08-15 11:50 の
「入力処理 3610 tok/s」はこれ。M3 8コアGPUの理論ピークを超えており物理的にありえない）。

このスクリプトは入力処理だけを、キャッシュに頼らずに測る:

  1. 毎回プロンプトの**先頭**に一意な nonce を差し込み、プレフィックス一致を強制的に壊す。
     （末尾に付けても意味がない。先頭で壊さないと後続が全部キャッシュに乗る）
  2. `num_predict=1` にして生成を排除する。測るのはプリフィルのみ。
  3. プロンプト長を 256 / 1024 / 4096 / 8000 トークン付近で振り、長さ依存を見る。
  4. `OLLAMA_KV_CACHE_TYPE` を切り替えて比較する。これはサーバの環境変数なので、
     条件ごとに ollama serve を停止・再起動する（このスクリプトが自分で行う）。
  5. 各計測の前に冷却待ちを入れる。ファンレス機では実行順で結果が最大2倍変わる
     （docs/BENCH_RESULTS.md 2026-08-15 12:10 の検証）。
  6. 条件の実行順をラウンドごとに反転し、順序効果を打ち消す。全行に実行順を記録する。

追加パッケージ不要（標準ライブラリのみ）。

注意: このスクリプトは計測のたびに `ollama serve` を停止・再起動する。
      実行中は Open WebUI からの会話ができなくなる。終了時に .env の設定へ戻す。

使い方:
    python3 scripts/bench-prompt.py --dry-run            # 実行計画と所要時間だけ表示
    python3 scripts/bench-prompt.py                      # 既定条件で計測
    python3 scripts/bench-prompt.py --kv q8_0 f16 --num-batch 512 2048
    python3 scripts/bench-prompt.py --save --note "KV型のA/B"
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import random
import re
import socket
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RESULTS = REPO / "docs" / "BENCH_RESULTS.md"
ENV_FILE = REPO / ".env"
# serve.sh は logs/ollama.log を `>` で上書きする。証拠を消さないよう別ファイルに追記する。
SERVER_LOG = REPO / "logs" / "bench-prompt-ollama.log"

DEFAULT_HOST = "127.0.0.1:11434"
DEFAULT_LENGTHS = [256, 1024, 4096, 8000]

# 所要時間の見積もりに使う仮の入力処理速度。
# 出典: ユーザ提供の ollama.log 実測行 "prompt processing, ... 145.32 tokens per second"。
# 見積もり専用の定数であり、計測結果には一切影響しない。
ASSUMED_PP_TPS = 145.0
RESTART_OVERHEAD_S = 25.0  # 停止 + 起動 + モデルロード（実測ベースの概算）
WARMUP_OVERHEAD_S = 8.0

# M3(8コアGPU) の FP16 理論ピーク。Apple 公表の M3 10コア = 4.1 TFLOPS(FP32) を
# 8コアへ按分し FP16 で倍。これを超える「入力処理速度」はキャッシュ命中の証拠。
PEAK_FLOPS = 6.6e12


# ---------------------------------------------------------------------------
# 計測用テキストの生成
#
# 同じ文字や同じ文の単純な繰り返しは使えない。トークナイザの挙動が実際の文書と
# 変わるうえ、KVキャッシュや量子化の効き方も変わって実態を反映しなくなる。
# そこで日本語と英語が混ざった業務文書ふうのテキストを、語彙を差し替えながら
# 組み立てる。テンプレート×語彙の組み合わせは数万通りあり、同じ文はまず並ばない。
# ---------------------------------------------------------------------------

JA_TOPICS = [
    "社内文書検索の要件整理", "推論サーバの運用方針", "計測プロトコルの見直し",
    "メモリ予算の配分", "モデル更新の手順", "障害時の切り戻し",
    "権限とログの扱い", "利用者からの要望", "コスト試算の前提",
    "外部サービスからの移行", "評価データの作り方", "リリース判定の基準",
    "バックアップの検証", "端末配布と初期設定", "問い合わせ対応の記録",
]

POOLS: dict[str, list[str]] = {
    "sys": [
        "推論サーバ", "文書取り込みバッチ", "ベクトル検索の索引", "要約パイプライン",
        "権限管理", "監査ログの収集", "モデル配信の仕組み", "キャッシュ層",
        "計測基盤", "夜間バックアップ", "通知の配信", "設定の同期処理",
    ],
    "sys2": [
        "推論サーバ", "文書取り込みバッチ", "ベクトル検索の索引", "要約パイプライン",
        "権限管理", "監査ログの収集", "モデル配信の仕組み", "キャッシュ層",
        "計測基盤", "夜間バックアップ", "通知の配信", "設定の同期処理",
    ],
    "metric": [
        "応答時間", "スループット", "メモリ使用量", "GPUの占有率",
        "キャッシュ命中率", "スワップ使用量", "最初の1文字までの秒数",
        "入力処理のトークン速度", "失敗率", "同時実行数",
    ],
    "trend": [
        "先月から悪化している", "ここ2週間は横ばいだ", "改善したが誤差の範囲だ",
        "利用者が増えた週だけ跳ねる", "夕方にだけ落ち込む", "再起動直後は良い",
    ],
    "cause": [
        "熱制限", "スワップの発生", "順番待ちの詰まり", "設定の取り違え",
        "キャッシュの取りこぼし", "入力が想定より長いこと", "並列度の不足",
        "モデルの再ロード", "ログ出力のコスト",
    ],
    "action": [
        "設定を1つだけ変えて測り直す", "上限値を引き下げる", "常駐時間を短くする",
        "手順書に注意書きを足す", "監視項目に追加する", "既定値へ戻す",
        "対象を絞って段階的に適用する", "計測を自動化する",
    ],
    "risk": [
        "品質のわずかな低下", "メモリ不足による強制終了", "再現性の悪化",
        "手戻りの発生", "利用者への周知漏れ", "ログの肥大化",
    ],
    "cond": [
        "連続して使ったとき", "他のアプリを開いたまま測ったとき",
        "冷えた状態から測ったとき", "入力が4000トークンを超えたとき",
        "会話が5往復を超えたとき", "同時に2件届いたとき",
    ],
    "who": [
        "運用担当", "利用部門", "レビュー担当", "自分自身の再現確認", "外部の報告例",
    ],
    "when": [
        "今週中", "来週の定例まで", "次のリリース前", "月末", "検証が終わり次第",
    ],
    "component": [
        "the inference server", "the retrieval index", "the ingestion job",
        "the metrics collector", "the cache layer", "the model loader",
    ],
    "metric_en": [
        "time to first token", "prefill throughput", "resident memory",
        "queue depth", "cache hit rate", "p95 latency",
    ],
    "cond_en": [
        "the machine has been busy for a few minutes",
        "the prompt grows past a few thousand tokens",
        "another process holds the GPU",
        "the model has just been reloaded",
        "swap is already in use",
    ],
    "cause_en": [
        "thermal throttling", "a cold cache", "an oversized system prompt",
        "serialized requests", "memory pressure",
    ],
    "action_en": [
        "revert the single setting we changed", "drop the batch size back",
        "restart the service and measure again", "shorten the injected preamble",
    ],
}

JA_TEMPLATES = [
    "{sys}については{metric}を基準に判断する。直近の値は{qty}で、{trend}。",
    "{who}の指摘で、{sys}の{metric}が{trend}ことが分かった。原因は{cause}と見ているが未確定である。",
    "{sys}を変更する場合は{risk}に注意が必要になる。特に{cond}に顕在化しやすい。",
    "設計上は{sys}が{metric}を律速する想定だったが、実測では{cause}のほうが支配的だった。",
    "{cond}は{metric}が{qty}まで悪化するため、{action}ことを前提に運用する。",
    "この方針は{who}と合意済みで、{when}までに{action}。",
    "計測は{cond}に行い、中央値だけでなく最小値と最大値も記録する。平均だけでは{cause}を見落とす。",
    "設定は1つだけ変えて測る。同時に複数変えると、何が効いたのか後から分からなくなる。",
    "現時点で確認できているのは{metric}が{qty}という事実だけで、{cause}かどうかは検証していない。",
    "{who}の環境では再現しなかった。{cond}という条件の違いが効いている可能性がある。",
    "優先度は中とする。{risk}はあるが{cond}に限られるため、実害は小さいと判断した。",
    "ログには{cause}を示す行が残っていた。ただし{when}より前の分はローテートで失われている。",
    "{sys}と{sys2}の依存関係を整理してからでないと、変更は危険だと考える。",
    "見積もりは{qty}だが、{cause}の分を含めていないため実際はこれを上回る。",
    "{metric}の目標値は据え置く。到達手段として{action}ことを先に試す。",
    "{sys}の既定値は小さめに設定されている。{cond}に静かに切り詰められるので、値を明示すること。",
    "報告された{qty}という数字は、条件が書かれていないため比較に使えない。測り直しを依頼した。",
    "{who}からは{when}までに結論が欲しいと言われているが、{cause}の切り分けが終わっていない。",
]

EN_TEMPLATES = [
    "{component} keeps {metric_en} under {qty} in the common case, but it degrades once {cond_en}.",
    "We measured {metric_en} three times and took the median; the spread was wider than the difference we were looking for.",
    "Do not compare a number taken while {cond_en} with one taken on a cold machine.",
    "{component} was not the bottleneck here. The profile points at {cause_en} instead.",
    "Rolling back is cheap: {action_en}, then restart the service and re-measure.",
    "The report claims a large speedup, but the baseline was taken with a warm cache, so {qty} is not comparable.",
    "Keep each change small enough that a single measurement can attribute it.",
    "If {cond_en}, the request queues behind the previous one and the wall clock roughly doubles.",
    "Record {metric_en} together with the machine state; a bare {qty} tells the next reader nothing.",
    "{cause_en} explains the direction of the change but not its size, so treat it as a hypothesis.",
]

QTY_UNITS = ["ms", "秒", "tok/s", "MB", "GB", "%", "件/分", "トークン"]


def _qty(rng: random.Random) -> str:
    """数値と単位の組。桁と表記をばらつかせてトークン列を単調にしない。"""
    style = rng.random()
    if style < 0.35:
        n = f"{rng.randint(1, 9)}.{rng.randint(0, 9)}"
    elif style < 0.75:
        n = f"{rng.randint(10, 999)}"
    else:
        n = f"{rng.randint(1000, 98000):,}"
    return f"{n} {rng.choice(QTY_UNITS)}"


def _fill(rng: random.Random, template: str) -> str:
    out = template
    for key in re.findall(r"\{(\w+)\}", template):
        val = _qty(rng) if key == "qty" else rng.choice(POOLS[key])
        out = out.replace("{" + key + "}", val, 1)
    return out


def _paragraph(rng: random.Random, idx: int) -> str:
    """見出し + 数文 + ときどき箇条書きやコマンド行。実際の社内文書に近い凹凸を作る。"""
    lines = [f"## {idx}. {rng.choice(JA_TOPICS)}"]
    for _ in range(rng.randint(2, 4)):
        pool = JA_TEMPLATES if rng.random() < 0.7 else EN_TEMPLATES
        lines.append(_fill(rng, rng.choice(pool)))
    if rng.random() < 0.35:
        for _ in range(rng.randint(2, 3)):
            lines.append(f"- {rng.choice(POOLS['metric'])}: {_qty(rng)}（{rng.choice(POOLS['cond'])}）")
    if rng.random() < 0.15:
        lines.append("```")
        lines.append(f"$ make bench CTX={rng.choice([4096, 8192, 16384])}  # {rng.choice(POOLS['action'])}")
        lines.append("```")
    return "\n".join(lines)


def build_text(seed: int, n_chars: int) -> str:
    """指定文字数のテキストを決定的に生成する。seed が同じなら常に同じ文章。"""
    rng = random.Random(seed)
    parts: list[str] = []
    total = 0
    idx = 1
    while total < n_chars:
        p = _paragraph(rng, idx)
        parts.append(p)
        total += len(p) + 2
        idx += 1
    return "\n\n".join(parts)[:n_chars]


# ---------------------------------------------------------------------------
# HTTP / Ollama
# ---------------------------------------------------------------------------


def http_json(url: str, payload: dict | None = None, timeout: float = 30.0) -> dict:
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def api_up(host: str, timeout: float = 3.0) -> bool:
    try:
        http_json(f"http://{host}/api/tags", timeout=timeout)
        return True
    except (urllib.error.URLError, OSError, TimeoutError, ValueError):
        return False


def wait_api(host: str, want_up: bool, limit: int = 90) -> bool:
    """/api/tags が応答する（しなくなる）まで待つ。再起動直後の取りこぼしを防ぐ。"""
    for _ in range(limit):
        if api_up(host) == want_up:
            return True
        time.sleep(1)
    return False


def read_dotenv(path: Path) -> dict[str, str]:
    """.env を読む。serve.sh と同じく # コメントと空行は無視する。"""
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        env[key] = val.strip().strip('"').strip("'")
    return env


def stop_ollama(host: str) -> None:
    """serve.sh down と同じ止め方。llama-server の子プロセスは親の終了に伴って落ちる。"""
    subprocess.run(["pkill", "-f", "ollama serve"], check=False, capture_output=True)
    if not wait_api(host, want_up=False, limit=30):
        raise RuntimeError(
            f"ollama を停止できませんでした（{host} がまだ応答します）。\n"
            "  brew services や Ollama.app で常駐している場合は、それを止めてから実行してください。"
        )
    time.sleep(1.5)  # ランナープロセスの後始末とポート解放の猶予


def start_ollama(host: str, base_env: dict[str, str], overrides: dict[str, str], label: str) -> int:
    """指定の環境変数で ollama serve を起動し、ログの読み出し開始位置を返す。"""
    env = os.environ.copy()
    # .env の OLLAMA_* だけを渡す。WEBUI_* はサーバに無関係なので混ぜない。
    env.update({k: v for k, v in base_env.items() if k.startswith("OLLAMA_")})
    env.update(overrides)
    env["OLLAMA_HOST"] = host

    SERVER_LOG.parent.mkdir(parents=True, exist_ok=True)
    logf = open(SERVER_LOG, "a", encoding="utf-8")
    logf.write(f"\n===== bench-prompt {datetime.now():%Y-%m-%d %H:%M:%S} {label} =====\n")
    logf.flush()
    offset = SERVER_LOG.stat().st_size

    subprocess.Popen(
        ["ollama", "serve"], stdout=logf, stderr=logf, env=env, start_new_session=True
    )
    logf.close()

    if not wait_api(host, want_up=True, limit=90):
        raise RuntimeError(f"ollama の起動に失敗しました。{SERVER_LOG} を確認してください。")
    return offset


def runner_flags(offset: int) -> dict[str, str]:
    """起動ログから llama-server に渡された実際のフラグを拾う。
    環境変数が効いていない（＝A/Bが成立していない）事故を検出するための確認。"""
    try:
        with SERVER_LOG.open("r", encoding="utf-8", errors="replace") as f:
            f.seek(offset)
            tail = f.read()
    except OSError:
        return {}
    found: dict[str, str] = {}
    # Ollama 0.32.13 の起動ログ実測（logs/bench-prompt-ollama.log 16行目）では
    #   --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn on -b 512 -ub 512
    # のように、バッチは長い名前ではなく -b / -ub で渡される。
    patterns = (
        (r"--cache-type-k[= ]+([\w.\-]+)", "kv_k"),
        (r"--cache-type-v[= ]+([\w.\-]+)", "kv_v"),
        (r"--flash-attn[= ]+([\w.\-]+)", "fa"),
        (r"(?<![\w\-])-b[= ]+(\d+)", "batch"),
        (r"(?<![\w\-])-ub[= ]+(\d+)", "ubatch"),
    )
    for pat, key in patterns:
        m = re.search(pat, tail)
        if m:
            found[key] = m.group(1)
    return found


def swap_used_mb() -> float:
    """スワップ使用量(MB)。メモリ逼迫が計測を汚していないかの記録用。"""
    try:
        out = subprocess.run(
            ["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True, timeout=10
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return float("nan")
    m = re.search(r"used\s*=\s*([\d.]+)M", out)
    return float(m.group(1)) if m else float("nan")


def llama_port() -> int | None:
    """Ollama が起動した llama-server の待ち受けポート。起動ログから拾う。

    Ollama 自身はトークナイザを公開していないが、その下で動く llama-server は
    `/tokenize` を持つ（実測: Ollama 0.32.13 の llama-server で応答することを確認）。
    プロンプト長を目標値ぴったりに合わせるために使う。GPU は使わない。
    """
    try:
        text = SERVER_LOG.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    ports = re.findall(r"starting llama-server.*?--port (\d+)", text)
    return int(ports[-1]) if ports else None


def tokenize_len(port: int, text: str) -> int | None:
    try:
        r = http_json(f"http://127.0.0.1:{port}/tokenize", {"content": text}, timeout=120)
    except (urllib.error.URLError, OSError, TimeoutError, ValueError):
        return None
    toks = r.get("tokens")
    return len(toks) if isinstance(toks, list) else None


def vm_snapshot() -> dict[str, float]:
    """vm_stat の生カウンタ。計測がメモリ逼迫で汚れていないかの物証を残す。

    ページアウト/スワップインの差分が出た計測は、GPU の速度ではなく
    ページングを測っていることになるので、後から切り分けられるようにする。
    """
    try:
        out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    page = 4096.0
    m = re.search(r"page size of (\d+) bytes", out)
    if m:
        page = float(m.group(1))
    vals: dict[str, float] = {}
    for line in out.splitlines():
        mm = re.match(r'"?([A-Za-z][A-Za-z \-_]*?)"?:\s+(\d+)', line)
        if mm:
            vals[mm.group(1).strip().lower()] = float(mm.group(2))
    mb = lambda k: vals.get(k, 0.0) * page / 1e6
    return {
        "free_mb": mb("pages free") + mb("pages inactive") + mb("pages speculative"),
        "wired_mb": mb("pages wired down"),
        "compressor_mb": mb("pages occupied by compressor"),
        "swapins": vals.get("swapins", 0.0),
        "swapouts": vals.get("swapouts", 0.0),
    }


def resident_size(host: str, model: str) -> str:
    """`ollama ps` の常駐サイズ。KV型を変えたときの実節約量を確認する。
    OLLAMA_HOST を明示するのは、シェルの設定ではなくこのスクリプトが起動した
    サーバを必ず見に行かせるため。"""
    try:
        out = subprocess.run(
            ["ollama", "ps"], capture_output=True, text=True, timeout=15,
            env={**os.environ, "OLLAMA_HOST": host},
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return "-"
    for line in out.splitlines()[1:]:
        if line.startswith(model.split(":")[0]):
            cols = line.split()
            for i, c in enumerate(cols):
                if c.upper() in {"GB", "MB"} and i > 0:
                    return f"{cols[i - 1]} {c.upper()}"
    return "-"


def param_count(host: str, model: str) -> float:
    """モデルのパラメータ数。理論ピーク超えを検出する健全性チェックに使う。"""
    try:
        info = http_json(f"http://{host}/api/show", {"model": model}, timeout=30)
    except (urllib.error.URLError, OSError, TimeoutError, ValueError):
        return float("nan")
    mi = info.get("model_info") or {}
    for k, v in mi.items():
        if k.endswith("parameter_count") and isinstance(v, (int, float)):
            return float(v)
    size = (info.get("details") or {}).get("parameter_size") or ""
    m = re.match(r"([\d.]+)\s*B", size)
    return float(m.group(1)) * 1e9 if m else float("nan")


def measure(host: str, model: str, prompt: str, options: dict) -> dict:
    """1回だけプリフィルを測る。num_predict=1 なので生成はほぼ含まれない。
    stream=False で十分（TTFT は測らない。ここで欲しいのは prompt_eval_* だけ）。"""
    body = {"model": model, "prompt": prompt, "stream": False, "options": options}
    vm0 = vm_snapshot()
    started = time.perf_counter()
    final = http_json(f"http://{host}/api/generate", body, timeout=1800)
    wall = time.perf_counter() - started
    vm1 = vm_snapshot()

    ns = 1_000_000_000
    count = final.get("prompt_eval_count") or 0
    dur = (final.get("prompt_eval_duration") or 0) / ns
    return {
        # メモリ逼迫の物証。この計測中に何ページ出入りしたか。
        "free_mb_before": vm0.get("free_mb", float("nan")),
        "free_mb_after": vm1.get("free_mb", float("nan")),
        "swapin_delta": vm1.get("swapins", 0.0) - vm0.get("swapins", 0.0),
        "swapout_delta": vm1.get("swapouts", 0.0) - vm0.get("swapouts", 0.0),
        "compressor_mb_after": vm1.get("compressor_mb", float("nan")),
        "count": count,
        "pp_s": dur,
        "pp_tps": (count / dur) if dur > 0 else float("inf"),
        "load_s": (final.get("load_duration") or 0) / ns,
        "total_s": (final.get("total_duration") or 0) / ns,
        "eval_count": final.get("eval_count") or 0,
        "wall_s": wall,
        "swap_mb": swap_used_mb(),
    }


# ---------------------------------------------------------------------------
# 進行の表示
# ---------------------------------------------------------------------------


def cooldown(seconds: int, label: str) -> None:
    """本体を冷ます。ファンレス機では実行順で結果が最大2倍変わるため
    （docs/BENCH_RESULTS.md 2026-08-15 12:10）、条件比較では必須。"""
    if seconds <= 0:
        return
    print(f"  冷却待ち {seconds}s ({label}) ", end="", flush=True)
    remaining = seconds
    while remaining > 0:
        step = min(15, remaining)
        time.sleep(step)
        remaining -= step
        print(f"{remaining}s ", end="", flush=True)
    print("再開")


def fmt_hms(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h}時間{m:02d}分" if h else f"{m}分{s:02d}秒"


# ---------------------------------------------------------------------------
# 集計と出力
# ---------------------------------------------------------------------------


def med(values: list[float]) -> float:
    clean = [v for v in values if v == v and v != float("inf")]
    return statistics.median(clean) if clean else float("nan")


def cond_label(kv: str, batch: int | None) -> str:
    return f"{kv} / batch={batch if batch else '既定'}"


def detail_table(rows: list[dict], runs: int) -> str:
    head = (
        "| 実行順 | R | KV | batch | 目標tok | 実測tok | 誤差 | 入力処理 tok/s | "
        "実効 tok/s | 幅(min–max) | 処理秒 | 空きMB | ページイン |\n"
        "|--:|--:|---|--:|--:|--:|--:|--:|--:|---|--:|--:|--:|\n"
    )
    body = ""
    for r in rows:
        err = (r["count"] - r["target"]) / r["target"] if r["target"] else float("nan")
        tps = "cache?" if r["pp_tps"] == float("inf") else f"{r['pp_tps']:.0f}"
        if r["suspect"]:
            tps += " ⚠"
        span = "-" if runs < 2 else f"{r['tps_min']:.0f}–{r['tps_max']:.0f}"
        body += (
            f"| {r['seq']} | {r['round']} | `{r['kv']}` | {r['batch'] or '既定'} | "
            f"{r['target']} | {r['count']} | {err:+.1%} | {tps} | {r['eff_tps']:.0f} | "
            f"{span} | {r['pp_s']:.1f} | {r['free_mb']:.0f} | {r['swapin']:.0f} |\n"
        )
    return head + body


def summary_table(rows: list[dict], kvs: list[str], batches: list[int | None], lengths: list[int]) -> str:
    """条件ごとの中央値を並べ、KV型の差だけを見えるようにする。"""
    conds = [(kv, b) for b in batches for kv in kvs]
    head = "| 目標tok | " + " | ".join(cond_label(kv, b) for kv, b in conds)
    if len(conds) > 1:
        head += " | 比(基準=先頭)"
    head += " |\n|--:|" + "--:|" * len(conds) + ("--:|" if len(conds) > 1 else "") + "\n"

    body = ""
    for t in lengths:
        vals = []
        for kv, b in conds:
            sel = [r["pp_tps"] for r in rows if r["target"] == t and r["kv"] == kv and r["batch"] == b]
            vals.append(med(sel))
        cells = " | ".join("-" if v != v else f"{v:.0f}" for v in vals)
        line = f"| {t} | {cells}"
        if len(conds) > 1:
            base = vals[0]
            ratios = [("-" if (v != v or base != base or base == 0) else f"{v / base:.2f}") for v in vals[1:]]
            line += " | " + " / ".join(ratios)
        body += line + " |\n"
    return head + body


def order_table(rows: list[dict], rounds: int) -> str:
    """ラウンド（実行順を反転した反復）ごとの中央値。順序効果＝熱の影響が見える。"""
    head = "| ラウンド | 実行順 | 入力処理 tok/s（全長の中央値） |\n|--:|---|--:|\n"
    body = ""
    for rd in range(1, rounds + 1):
        sel = [r for r in rows if r["round"] == rd]
        if not sel:
            continue
        order = " → ".join(dict.fromkeys(cond_label(r["kv"], r["batch"]) for r in sel))
        body += f"| {rd} | {order} | {med([r['pp_tps'] for r in sel]):.0f} |\n"
    return head + body


# ---------------------------------------------------------------------------
# 計画
# ---------------------------------------------------------------------------


def build_plan(kvs: list[str], batches: list[int | None], lengths: list[int], rounds: int) -> list[dict]:
    """ラウンドごとに条件と長さの順序を反転させた実行計画を作る。
    奇数ラウンドは正順、偶数ラウンドは逆順。先に走った条件が有利になる熱の偏りを相殺する。"""
    conds = [(kv, b) for b in batches for kv in kvs]
    plan = []
    for rd in range(1, rounds + 1):
        c = conds if rd % 2 == 1 else list(reversed(conds))
        l = lengths if rd % 2 == 1 else list(reversed(lengths))
        for kv, batch in c:
            plan.append({"round": rd, "kv": kv, "batch": batch, "lengths": list(l)})
    return plan


def estimate_seconds(plan: list[dict], runs: int, cool: int) -> float:
    total = RESTART_OVERHEAD_S + WARMUP_OVERHEAD_S + 40  # 準備フェーズ（校正を含む）
    for step in plan:
        total += RESTART_OVERHEAD_S + WARMUP_OVERHEAD_S
        for t in step["lengths"]:
            total += cool + runs * (t / ASSUMED_PP_TPS + 2.0)
    total += RESTART_OVERHEAD_S  # 後始末の復帰起動
    return total


# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(
        description="入力処理（プリフィル）速度を、プロンプト長とKVキャッシュ型で切り分けて計測する"
    )
    ap.add_argument("--model", default="sophia-chat", help="計測するモデル（既定: sophia-chat）")
    ap.add_argument(
        "--lengths", nargs="+", type=int, default=DEFAULT_LENGTHS,
        help="目標プロンプト長（トークン）。既定: 256 1024 4096 8000",
    )
    ap.add_argument(
        "--kv", nargs="+", default=["q8_0", "f16"], choices=["f16", "q8_0", "q4_0"],
        help="比較する OLLAMA_KV_CACHE_TYPE。条件ごとに ollama serve を再起動する",
    )
    ap.add_argument(
        "--num-batch", nargs="+", type=int, default=[],
        help="比較する num_batch。未指定ならモデル既定(512)のみ。例: --num-batch 512 2048",
    )
    ap.add_argument(
        "--ctx", type=int, default=0,
        help="num_ctx。既定は自動（8192。ただし最長プロンプトが確実に収まるよう必要なら引き上げる）",
    )
    ap.add_argument("--runs", type=int, default=2, help="各条件の試行回数（中央値を採用。既定: 2）")
    ap.add_argument(
        "--rounds", type=int, default=2,
        help="反復回数。偶数ラウンドは条件と長さの順序を反転して順序効果を打ち消す（既定: 2）",
    )
    ap.add_argument(
        "--cooldown", type=int, default=120,
        help="各計測の前に待つ秒数（既定: 120）。ファンレス機ではこれが無いと比較にならない",
    )
    ap.add_argument("--seed", type=int, default=42, help="テキスト生成のシード（既定: 42）")
    ap.add_argument("--host", default="", help="Ollama のホスト。既定は .env の OLLAMA_HOST")
    ap.add_argument("--save", action="store_true", help="docs/BENCH_RESULTS.md に追記")
    ap.add_argument("--json", dest="json_path", default="", help="生の計測値を JSON で保存するパス")
    ap.add_argument("--note", default="", help="結果に添える条件メモ")
    ap.add_argument("--dry-run", action="store_true", help="実行計画と所要時間だけ表示して終了")
    ap.add_argument("-y", "--yes", action="store_true", help="確認プロンプトを省略する")
    args = ap.parse_args()

    dotenv = read_dotenv(ENV_FILE)
    host = args.host or dotenv.get("OLLAMA_HOST") or DEFAULT_HOST
    batches: list[int | None] = list(args.num_batch) if args.num_batch else [None]
    lengths = sorted(set(args.lengths))
    if not lengths or args.rounds < 1 or args.runs < 1:
        print("--lengths / --rounds / --runs の指定が空です。")
        return 1

    # num_ctx はプロンプトが切り詰められない値でなければならない。
    # 8000トークンを狙って num_ctx=8192 にすると、校正誤差が数%出ただけで
    # 溢れて静かに切り詰められ、何を測ったのか分からなくなる。余裕を持たせる。
    if args.ctx <= 0:
        need_ctx = int(max(lengths) * 1.10) + 128
        args.ctx = max(8192, -(-need_ctx // 1024) * 1024)
        ctx_note = "（自動）"
    else:
        ctx_note = "（明示指定）"

    plan = build_plan(args.kv, batches, lengths, args.rounds)
    est = estimate_seconds(plan, args.runs, args.cooldown)

    n_measure = sum(len(s["lengths"]) for s in plan) * args.runs
    print("=" * 72)
    print("入力処理（プリフィル）速度の切り分け計測")
    print("=" * 72)
    print(f"  モデル      : {args.model}   host={host}")
    print(f"  目標長      : {' / '.join(str(t) for t in lengths)} トークン")
    print(f"  KVキャッシュ: {' / '.join(args.kv)}   num_batch: "
          f"{' / '.join(str(b) if b else '既定' for b in batches)}")
    print(f"  num_ctx     : {args.ctx}{ctx_note}   num_predict=1（生成は測らない）")
    print(f"  試行        : runs={args.runs} × rounds={args.rounds} → 計 {n_measure} 回")
    print(f"  冷却        : 各計測の前に {args.cooldown}s")
    print(f"  再起動      : {len(plan)} 回（KV型はサーバ環境変数のため条件ごとに必要）")
    print(f"  想定所要時間: 約 {fmt_hms(est)}")
    print()
    print("  実行計画（この順に走る）:")
    for step in plan:
        print(f"    R{step['round']}  {cond_label(step['kv'], step['batch'])}"
              f"  → 長さ {', '.join(str(t) for t in step['lengths'])}")
    print()

    if int(max(lengths) * 1.05) + 64 > args.ctx:
        print(f"  ! 目標長 {max(lengths)} は num_ctx={args.ctx} に対して余裕がありません。")
        print("    プロンプトが切り詰められると計測になりません。--ctx を上げてください。")
        if not args.dry_run:
            return 1

    if dotenv.get("OLLAMA_FLASH_ATTENTION") != "1" and any(k != "f16" for k in args.kv):
        print("  ! .env の OLLAMA_FLASH_ATTENTION が 1 ではありません。")
        print("    KVキャッシュ量子化は Flash Attention が前提です（docs/TUNING.md 3節）。")

    if args.dry_run:
        print("--dry-run のためここで終了します。Ollama には一切接続していません。")
        return 0

    # Open WebUI が動いていると裏で Ollama を叩き、計測に割り込む可能性がある。
    webui_port = int(dotenv.get("WEBUI_PORT") or 8081)
    try:
        with socket.create_connection(("127.0.0.1", webui_port), timeout=1):
            print(f"  ! Open WebUI がポート {webui_port} で動作中です。")
            print("    裏の呼び出しが計測に混ざるため、`make down` で止めてから実行することを推奨します。")
    except OSError:
        pass

    print(f"  ! この計測は ollama serve を {len(plan) + 2} 回停止・再起動します。")
    print("    実行中は Open WebUI から会話できません。終了時に .env の設定へ戻します。")
    if not args.yes and sys.stdin.isatty():
        if input("  続行しますか? [y/N] ").strip().lower() not in {"y", "yes"}:
            print("中止しました。")
            return 1
    print()

    started_at = time.time()
    rows: list[dict] = []
    raw: list[dict] = []
    seq = 0
    flag_log: list[str] = []
    # 校正結果。準備フェーズで上書きされる。途中で落ちても集計側が参照するので先に定義する。
    params = float("nan")
    tok_per_char = float("nan")
    overhead = float("nan")

    try:
        # ------------------------------------------------------------------
        # 準備フェーズ: トークン数の校正
        # 標準ライブラリだけではトークナイザを持てないので、実測から
        # 「文字数 → トークン数」の一次式を求める。2点で足りる（同じ語彙の
        # 文章なので文字あたりトークン数はほぼ一定）。切片はテンプレート
        # （SYSTEM ブロック等）の固定オーバーヘッドに相当する。
        # ------------------------------------------------------------------
        first = plan[0]
        print(f"[準備] ollama serve を起動 ({cond_label(first['kv'], first['batch'])})")
        start_ollama(host, dotenv, {"OLLAMA_KV_CACHE_TYPE": first["kv"]}, "prep")
        opts = {"num_ctx": args.ctx, "num_predict": 1, "temperature": 0, "seed": args.seed}
        if first["batch"]:
            opts["num_batch"] = first["batch"]

        print("[準備] モデルをロード中（ウォームアップ）...", end="", flush=True)
        warm_prompt = f"[warmup {uuid.uuid4().hex}] ping"
        warm = measure(host, args.model, warm_prompt, opts)
        print(f" ok (load {warm['load_s']:.1f}s)")

        params = param_count(host, args.model)
        print(f"[準備] パラメータ数: "
              f"{'不明' if params != params else f'{params / 1e9:.2f} B'}")

        # 第一選択: llama-server の /tokenize を直接叩いて実トークン数で合わせる。
        # GPU を使わないので冷却状態を乱さず、目標長との誤差もほぼゼロにできる。
        port = llama_port()
        n_warm = tokenize_len(port, warm_prompt) if port else None
        exact = n_warm is not None
        if exact:
            overhead = float(warm["count"] - n_warm)
            print(f"[準備] llama-server の /tokenize を使用（port={port}）。目標長は実測で合わせる。")
            print(f"[準備] テンプレート固定分 {overhead:.0f} トークン"
                  f"（ウォームアップの prompt_eval_count {warm['count']} − 本文 {n_warm}）")
        else:
            print("[準備] /tokenize が使えないため、2点プローブの一次式で近似します。")
            probes = []
            for chars in (500, 5000):
                text = build_text(args.seed + 900, chars)
                r = measure(host, args.model, f"[probe {uuid.uuid4().hex}]\n{text}", opts)
                probes.append((chars, r["count"]))
                print(f"[準備] 校正プローブ: {chars} 文字 → {r['count']} トークン")
            (c0, t0), (c1, t1) = probes
            tok_per_char = (t1 - t0) / (c1 - c0)
            if tok_per_char <= 0:
                raise RuntimeError(
                    f"校正に失敗しました（{c0}字→{t0}tok, {c1}字→{t1}tok）。"
                    "prompt_eval_count が返っていない可能性があります。"
                )
            overhead = t0 - tok_per_char * c0  # テンプレート由来の固定トークン数
            print(f"[準備] 1文字あたり {tok_per_char:.3f} トークン / 固定分 {overhead:.0f} トークン")
        print("       固定分は SYSTEM ブロック等。ウォームアップ後は KV に載ったままなので")
        print("       再計算されない。Ollama の prompt_eval_count はこれも数に入れるため、")
        print("       この分を引いた値を『実効 tok/s』として併記する。")

        # 目標長ごとにテキストを作る。seed を長さごとに変えているのは、
        # 短いテキストが長いテキストの先頭一致にならないようにするため
        # （同一サーバ内で長さをまたいだキャッシュ命中が起きると台無しになる）。
        # nonce は 8桁で足りる（4,294,967,296 通り）。32桁だと nonce だけで 30〜33 トークンを
        # 食い、短い目標長が作れなくなる。8桁なら実測 8〜12 トークン。
        nonce_sample = "[bench 2f7a9c1e]\n"
        texts: dict[int, str] = {}
        actual_tok: dict[int, int] = {}
        for t in lengths:
            body_target = t - overhead  # 本文（nonce 込み）が持つべきトークン数
            if body_target < 1:
                raise RuntimeError(f"目標 {t}tok は固定分 {overhead:.0f} より小さく、測れません。")
            guess = 0.5 if exact else tok_per_char  # 日本語混在の概算（後段で補正する）
            need = max(1, round(body_target / guess))
            if exact:
                best: tuple[int, int, str] | None = None
                for _ in range(12):
                    text = build_text(args.seed + t, need)
                    n = tokenize_len(port, nonce_sample + text)
                    if n is None:
                        break
                    if best is None or abs(n - body_target) < abs(best[1] - body_target):
                        best = (need, n, text)
                    if abs(n - body_target) <= max(2, body_target * 0.002):
                        break
                    nxt = max(1, int(round(need * body_target / max(1, n))))
                    need = nxt if nxt != need else need + (1 if n < body_target else -1)
                if best is not None:
                    texts[t] = best[2]
                    actual_tok[t] = int(round(best[1] + overhead))
                    continue
                print("       ! /tokenize が途中で失敗したため一次式に切り替えます。")
                exact = False
                tok_per_char = 0.5
            # フォールバック: 一次式から逆算
            need = max(1, round(body_target / tok_per_char))
            # 切り詰めが起きると何を測ったか分からなくなるので、num_ctx から見て
            # 溢れる長さは物理的に作らない（校正が外れていた場合の保険）。
            cap = max(1, round((args.ctx - 64 - overhead) / tok_per_char))
            if need > cap:
                print(f"       ! 目標 {t}tok は num_ctx={args.ctx} に収まりません。"
                      f"{cap} 文字に切り詰めます。")
                need = cap
            texts[t] = build_text(args.seed + t, need)
        if exact:
            longest = max(lengths)
            tok_per_char = (actual_tok[longest] - overhead) / max(1, len(texts[longest]))
        print("[準備] 計測用テキストを生成: "
              + " / ".join(
                  f"{t}tok←{len(texts[t])}字"
                  + (f"(実{actual_tok[t]}tok)" if t in actual_tok else "")
                  for t in lengths
              ))
        print()

        # ------------------------------------------------------------------
        # 本計測
        # ------------------------------------------------------------------
        for step in plan:
            kv, batch = step["kv"], step["batch"]
            label = cond_label(kv, batch)
            print(f"[R{step['round']}] {label} — サーバ再起動")
            stop_ollama(host)
            offset = start_ollama(
                host, dotenv, {"OLLAMA_KV_CACHE_TYPE": kv}, f"R{step['round']} {label}"
            )

            opts = {"num_ctx": args.ctx, "num_predict": 1, "temperature": 0, "seed": args.seed}
            if batch:
                opts["num_batch"] = batch

            # ウォームアップ。モデルのロード時間を計測から外し、
            # 固定プレフィックス（SYSTEM ブロック）を KV に載せた状態に揃える。
            measure(host, args.model, f"[warmup {uuid.uuid4().hex}] ping", opts)
            flags = runner_flags(offset)
            size = resident_size(host, args.model)
            got_kv = flags.get("kv_k", "?")
            print(f"       ランナー実引数: cache-type-k={got_kv} "
                  f"cache-type-v={flags.get('kv_v', '?')} flash-attn={flags.get('fa', '?')} "
                  f"-b={flags.get('batch', '?')} -ub={flags.get('ubatch', '?')} / 常駐 {size}")
            flag_log.append(f"R{step['round']} {label}: k={got_kv} v={flags.get('kv_v', '?')} "
                            f"fa={flags.get('fa', '?')} b={flags.get('batch', '?')} "
                            f"ub={flags.get('ubatch', '?')} 常駐={size}")
            if got_kv not in {"?", kv}:
                print(f"       ! 指定した {kv} が反映されていません（実際は {got_kv}）。"
                      "この条件の結果は比較に使えません。")

            for target in step["lengths"]:
                cooldown(args.cooldown, f"{label} / {target}tok の前")
                samples = []
                print(f"  [{label}] {target}tok ", end="", flush=True)
                for _ in range(args.runs):
                    # nonce は必ず先頭。ここで一致を壊さないと後続が全部キャッシュに乗る。
                    prompt = f"[bench {uuid.uuid4().hex[:8]}]\n{texts[target]}"
                    s = measure(host, args.model, prompt, opts)
                    seq += 1
                    s.update({"seq": seq, "round": step["round"], "kv": kv,
                              "batch": batch, "target": target})
                    samples.append(s)
                    raw.append(s)
                    paging = ""
                    if s["swapin_delta"] > 0 or s["swapout_delta"] > 0:
                        # ページングが起きた計測は GPU ではなくディスクを測っている
                        paging = f"(ページイン{s['swapin_delta']:.0f}/アウト{s['swapout_delta']:.0f})"
                    print(f"{s['pp_tps']:.0f}{paging} ", end="", flush=True)
                print("tok/s")

                tps_list = [s["pp_tps"] for s in samples]
                pp_s = med([s["pp_s"] for s in samples])
                count = int(statistics.median([s["count"] for s in samples]))
                pp_tps = med(tps_list)
                # 実効値: キャッシュに載ったままの固定プレフィックスを分子から除く
                eff = (count - overhead) / pp_s if pp_s > 0 else float("nan")
                flops = 2 * params * count / pp_s if (params == params and pp_s > 0) else float("nan")
                suspect = bool(flops == flops and flops > PEAK_FLOPS)
                if suspect:
                    print(f"       ! 換算 {flops / 1e12:.1f} TFLOP/s は M3 の理論ピーク "
                          f"{PEAK_FLOPS / 1e12:.1f} を超えます。キャッシュ命中を疑ってください。")
                if count >= args.ctx - 16:
                    print(f"       ! 実測 {count} トークンは num_ctx={args.ctx} の上限付近です。"
                          "切り詰められた可能性があるため、この行は信用しないでください。")

                rows.append({
                    "seq": samples[0]["seq"], "round": step["round"], "kv": kv, "batch": batch,
                    "target": target, "count": count, "pp_s": pp_s, "pp_tps": pp_tps,
                    "eff_tps": eff, "tps_min": min(tps_list), "tps_max": max(tps_list),
                    "swap_mb": med([s["swap_mb"] for s in samples]),
                    "free_mb": med([s["free_mb_before"] for s in samples]),
                    "swapin": max(s["swapin_delta"] for s in samples),
                    "flops": flops, "suspect": suspect,
                })

    except KeyboardInterrupt:
        print("\n中断されました。ここまでの結果を出力します。")
    except (RuntimeError, urllib.error.URLError, OSError, TimeoutError, ValueError) as e:
        # ValueError は Ollama が JSON 以外を返した場合（起動途中・モデル名の誤り等）。
        print(f"\n! 計測を中断しました: {type(e).__name__}: {e}")
    finally:
        # .env の設定でサーバを戻す。計測用の上書きを残さない。
        print("\n[後始末] .env の設定で ollama serve を起動し直します")
        try:
            stop_ollama(host)
            start_ollama(host, dotenv, {}, "restore (.env の設定)")
            print(f"[後始末] 復帰しました（KV={dotenv.get('OLLAMA_KV_CACHE_TYPE', '既定')}）。"
                  "Open WebUI を使う場合は `make up` を実行してください。")
        except (RuntimeError, OSError) as e:
            print(f"[後始末] ! 復帰に失敗しました: {e}")
            print("         手動で `make restart` を実行してください。")

    if not rows:
        print("計測できた結果がありません。")
        return 1

    elapsed = time.time() - started_at
    t_detail = detail_table(rows, args.runs)
    t_summary = summary_table(rows, args.kv, batches, lengths)
    t_order = order_table(rows, args.rounds)

    print("\n### 詳細（実行順つき）\n")
    print(t_detail)
    print("### 条件比較（中央値）\n")
    print(t_summary)
    print("### 順序効果の確認\n")
    print(t_order)
    print(f"実測所要時間: {fmt_hms(elapsed)}（見積もり {fmt_hms(est)}）")

    if args.json_path:
        Path(args.json_path).write_text(
            json.dumps(
                {"args": vars(args), "host": host, "params": params,
                 "tok_per_char": tok_per_char, "overhead": overhead,
                 "runner_flags": flag_log, "samples": raw},
                ensure_ascii=False, indent=2, default=str,
            ),
            encoding="utf-8",
        )
        print(f"生データを保存しました: {args.json_path}")

    if args.save:
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
        chip = platform.processor() or platform.machine()
        header = (
            f"\n## {stamp} — 入力処理（プリフィル）の切り分け計測\n\n"
            f"- 計測: `scripts/bench-prompt.py`（`bench.py` とは別物。"
            f"毎回プロンプト先頭に nonce を入れてプレフィックスキャッシュを壊し、"
            f"`num_predict=1` で生成を排除している）\n"
            f"- 条件: `{args.model}` / `num_ctx={args.ctx}` / runs={args.runs} × "
            f"rounds={args.rounds} / cooldown={args.cooldown}s / {chip}\n"
            f"- KV: {' / '.join(args.kv)}（条件ごとに ollama serve を再起動）"
            f" / num_batch: {' / '.join(str(b) if b else '既定' for b in batches)}\n"
            f"- 実行順: 奇数ラウンドは正順、偶数ラウンドは反転（順序効果の相殺）\n"
            f"- 校正: 1文字あたり {tok_per_char:.3f} トークン / テンプレート固定分 "
            f"{overhead:.0f} トークン\n"
        )
        if args.note:
            header += f"- メモ: {args.note}\n"
        header += (
            "\n**読み方**: 「入力処理 tok/s」は Ollama 報告値"
            "（`prompt_eval_count / prompt_eval_duration`）。分子には KV に載ったままの"
            "固定プレフィックスも含まれるため、それを引いたものを「実効 tok/s」として併記した。"
            "⚠ 付きの行は M3 の理論ピークを超えており、キャッシュ命中の疑いがある。\n"
        )
        body = (
            "\n### 詳細（実行順つき）\n\n" + t_detail
            + "\n### 条件比較（中央値）\n\n" + t_summary
            + "\n### 順序効果の確認\n\n" + t_order
            + "\n### ランナーに渡った実引数\n\n"
            + "".join(f"- {line}\n" for line in flag_log)
        )
        RESULTS.parent.mkdir(parents=True, exist_ok=True)
        if not RESULTS.exists():
            RESULTS.write_text(
                "# ベンチマーク履歴\n\n"
                "`make bench` の結果を時系列で残す。設定を変えたときに"
                "「本当に速くなったか」を後から確認するための記録。\n",
                encoding="utf-8",
            )
        with RESULTS.open("a", encoding="utf-8") as f:
            f.write(header + body)
        print(f"追記しました: {RESULTS.relative_to(REPO)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
