.PHONY: help up down restart status logs models bench bench-save pull clean-models

SHELL := /bin/bash
NOTE ?=
CTX  ?= 8192

help:
	@echo "Sophia ローカルAI環境"
	@echo ""
	@echo "  make up          Ollama と Open WebUI を起動 (http://localhost:8081)"
	@echo "  make down        両方を停止"
	@echo "  make restart     .env を変更したあとの再起動"
	@echo "  make status      稼働状況と、いまメモリに載っているモデル"
	@echo "  make logs        ログを追尾"
	@echo ""
	@echo "  make pull        ベースモデルを取得"
	@echo "  make models      modelfiles/ から専用モデルを作り直す"
	@echo ""
	@echo "  make bench       速度を計測して表示"
	@echo "  make bench-save NOTE=\"変更内容\"   計測して docs/BENCH_RESULTS.md に追記"
	@echo "  make bench CTX=16384              コンテキスト長を変えて計測"

up:
	@bash scripts/serve.sh up

down:
	@bash scripts/serve.sh down

restart:
	@bash scripts/serve.sh restart

status:
	@bash scripts/serve.sh status

logs:
	@tail -f logs/*.log

pull:
	ollama pull qwen3:8b
	ollama pull qwen2.5-coder:7b

# Modelfile を編集したら必ずこれを実行する。編集しただけでは反映されない。
models:
	@for f in modelfiles/*.Modelfile; do \
		name=$$(basename $$f .Modelfile); \
		echo "--- $$name ---"; \
		ollama create $$name -f $$f; \
	done
	@ollama list

bench:
	@python3 scripts/bench.py --models sophia-chat sophia-coder --ctx $(CTX)

bench-save:
	@python3 scripts/bench.py --models sophia-chat sophia-coder --ctx $(CTX) --save --note "$(NOTE)"

clean-models:
	@echo "削除候補:"; ollama list
	@echo "個別に 'ollama rm <名前>' で消してください（誤削除防止のため一括削除はしません）"
