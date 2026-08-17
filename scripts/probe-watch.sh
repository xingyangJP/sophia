#!/bin/bash
# プリフィル計測中に、系全体のページング状況を記録する。
#
# **プロセス内の ProcessMetrics とは独立した経路**であることに意味がある。
# 片方だけを見て結論を出すと、測り方の癖を現象と取り違える。
#
#   使い方: scripts/probe-watch.sh [間隔秒] [出力先]
#   止め方: Ctrl-C か kill
set -uo pipefail
INTERVAL="${1:-2}"
OUT="${2:-logs/probe-system.log}"
mkdir -p "$(dirname "$OUT")"

printf '=== %s 系全体の監視を開始（間隔 %ss）===\n' "$(date '+%F %T')" "$INTERVAL" >> "$OUT"
# ページサイズは決め打ちしない。この機体は 16384 バイト。
PAGE=$(vm_stat | sed -n '1s/.*page size of \([0-9]*\) bytes.*/\1/p')
printf 'page_size=%s\n' "$PAGE" >> "$OUT"

while true; do
  # vm_stat の必要な行だけを1行にまとめる。
  eval "$(vm_stat | awk -F: '
    /Pages free/            {gsub(/[ .]/,"",$2); print "free="$2}
    /Pages active/          {gsub(/[ .]/,"",$2); print "active="$2}
    /occupied by compressor/{gsub(/[ .]/,"",$2); print "comp="$2}
    /Pageins/               {gsub(/[ .]/,"",$2); print "pagein="$2}
    /Pageouts/              {gsub(/[ .]/,"",$2); print "pageout="$2}
    /Swapins/               {gsub(/[ .]/,"",$2); print "swapin="$2}
    /Swapouts/              {gsub(/[ .]/,"",$2); print "swapout="$2}')"
  SWAP=$(sysctl -n vm.swapusage | sed 's/  */ /g')
  # **Sophia は「1つとは限らない」。**
  #
  # 2026-08-17、`head -1` で最初の1つしか記録しない作りにしていたため、
  # 利用者がデスクトップアプリを起動したまま計測を回していたことに気づけず、
  # **掃引を1本まるごと無効にした。**（BENCH_RESULTS.md 参照）
  # アプリのワーキングセットは約9GBあり、2つ動けば16GB機では必ず破綻する。
  # **全部のプロセスを数え、合計と本数を必ず出すこと。**
  PIDS=$(pgrep -x Sophia | tr '\n' ' ')
  if [ -n "${PIDS// /}" ]; then
    N=0; SUM=0; LIST=""
    for p in $PIDS; do
      KB=$(ps -o rss= -p "$p" 2>/dev/null | tr -d ' ')
      SUM=$(( SUM + ${KB:-0} )); N=$(( N + 1 )); LIST="$LIST$p,"
    done
    RSS="sophia_n=$N rss_sum_mb=$(( SUM / 1024 )) pids=${LIST%,}"
  else
    RSS="sophia_n=0 rss_sum_mb=0 pids=-"
  fi
  printf '[SYS] t=%s free=%s active=%s comp=%s pagein=%s swapin=%s swapout=%s %s | %s\n' \
    "$(date '+%H:%M:%S')" "${free:-}" "${active:-}" "${comp:-}" \
    "${pagein:-}" "${swapin:-}" "${swapout:-}" "$RSS" "$SWAP" >> "$OUT"
  sleep "$INTERVAL"
done
