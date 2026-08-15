#!/usr/bin/env bash
# Ollama / Open WebUI の起動・停止・状態確認
#
# 常駐サービス（brew services）ではなくスクリプト起動にしている理由:
# docs/TUNING.md のつまみを回すたびに再起動が必要になるため、
# 設定が .env に見える形で置かれ、明示的に再起動できる方が扱いやすい。

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
mkdir -p logs

# uv tool でインストールしたコマンド（open-webui）の置き場。
# ~/.zshenv 経由でも通るが、シェル設定の読み込み状況に依存させたくないので明示する。
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"

# .env をエクスポート付きで読み込む（# コメントと空行は無視される）
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
WEBUI_PORT="${WEBUI_PORT:-8081}"
OLLAMA_URL="http://${OLLAMA_HOST}"

ollama_up() { curl -sf "${OLLAMA_URL}/api/tags" >/dev/null 2>&1; }
webui_up()  { curl -sf "http://localhost:${WEBUI_PORT}/health" >/dev/null 2>&1 \
              || lsof -nP -iTCP:"${WEBUI_PORT}" -sTCP:LISTEN >/dev/null 2>&1; }

start_ollama() {
  if ollama_up; then
    echo "ollama : 起動済み (${OLLAMA_URL})"
    return
  fi
  echo "ollama : 起動中..."
  nohup ollama serve > logs/ollama.log 2>&1 &
  disown
  for _ in $(seq 1 30); do
    ollama_up && { echo "ollama : OK (${OLLAMA_URL})"; return; }
    sleep 1
  done
  echo "ollama : 起動に失敗しました。logs/ollama.log を確認してください。" >&2
  return 1
}

start_webui() {
  if webui_up; then
    echo "webui  : 起動済み (http://localhost:${WEBUI_PORT})"
    return
  fi
  if ! command -v open-webui >/dev/null 2>&1; then
    echo "webui  : 未インストール。'uv tool install open-webui --python 3.11' を実行してください。" >&2
    return 1
  fi
  echo "webui  : 起動中... (初回はDB初期化で1分ほどかかります)"
  # Ollama の場所を明示。既定を拾えず接続できない事故を防ぐ。
  # --host 127.0.0.1 は必須。WEBUI_AUTH=False（ログイン不要）で全インターフェースに
  # 待ち受けると、同一ネットワーク上の他人が認証なしでアクセスできてしまう。
  OLLAMA_BASE_URL="${OLLAMA_URL}" \
  WEBUI_AUTH=False \
  nohup open-webui serve --host 127.0.0.1 --port "${WEBUI_PORT}" > logs/webui.log 2>&1 &
  disown
  for _ in $(seq 1 120); do
    webui_up && { echo "webui  : OK (http://localhost:${WEBUI_PORT})"; return; }
    sleep 1
  done
  echo "webui  : 起動に失敗しました。logs/webui.log を確認してください。" >&2
  return 1
}

stop_all() {
  pkill -f "ollama serve"  2>/dev/null && echo "ollama : 停止しました" || echo "ollama : 起動していません"
  pkill -f "open-webui"    2>/dev/null && echo "webui  : 停止しました" || echo "webui  : 起動していません"
}

status() {
  ollama_up && echo "ollama : 稼働中 (${OLLAMA_URL})" || echo "ollama : 停止"
  webui_up  && echo "webui  : 稼働中 (http://localhost:${WEBUI_PORT})" || echo "webui  : 停止"
  if ollama_up; then
    echo
    echo "--- 現在メモリに載っているモデル ---"
    ollama ps
  fi
}

case "${1:-up}" in
  ollama)  start_ollama ;;
  webui)   start_webui ;;
  up)      start_ollama; start_webui ;;
  down)    stop_all ;;
  restart) stop_all; sleep 2; start_ollama; start_webui ;;
  status)  status ;;
  *) echo "使い方: $0 {up|down|restart|status|ollama|webui}" >&2; exit 1 ;;
esac
