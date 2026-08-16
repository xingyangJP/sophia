.PHONY: help up down restart status logs models bench bench-save pull clean-models icons \
        app app-release app-run app-test app-clean app-setup

SHELL := /bin/bash
NOTE ?=
CTX  ?= 8192

# --- macOS アプリ（フェーズA1） -------------------------------------------
# xcodebuild の引数を1か所に集約する。GUI を持たない環境ではここが唯一の入口。
XC_PROJECT   := Sophia/Sophia.xcodeproj
XC_SCHEME    := Sophia
XC_DEST      := platform=macOS,arch=arm64
XC_DERIVED   := Sophia/DerivedData
# -skipPackagePluginValidation: mlx-swift の CudaBuild プラグインの信頼確認を省く。
# -skipMacroValidation:         MLXHuggingFace のマクロの信頼確認を省く。
# どちらも Xcode GUI では初回に手動で「信頼」を押す部分で、CLI では止まってしまう。
XC_FLAGS     := -skipPackagePluginValidation -skipMacroValidation
XCODEBUILD    = xcodebuild -project $(XC_PROJECT) -scheme $(XC_SCHEME) \
                -destination '$(XC_DEST)' -derivedDataPath $(XC_DERIVED) $(XC_FLAGS)
APP_DEBUG    := $(XC_DERIVED)/Build/Products/Debug/Sophia.app

help:
	@echo "Sophia ローカルAI環境"
	@echo ""
	@echo "  make app         macOS アプリをビルド (Debug)"
	@echo "  make app-run     ビルドして起動"
	@echo "  make app-release Release 構成でビルド"
	@echo "  make app-clean   ビルド成果物を削除（再ビルドに5分半かかる。慎重に）"
	@echo "  make app-setup   初回だけ必要な Metal ツールチェーンを導入"
	@echo "  make app-test    永続化層(DB)の単体テスト。GPUもモデルも使わない"
	@echo "  make test-inference  思考タグ分離（FR-17）の単体テスト。推論は走らない"
	@echo ""
	@echo "  make up          Ollama と Open WebUI を起動 (http://localhost:8081)"
	@echo "  make down        両方を停止"
	@echo "  make restart     .env を変更したあとの再起動"
	@echo "  make status      稼働状況と、いまメモリに載っているモデル"
	@echo "  make logs        ログを追尾"
	@echo ""
	@echo "  make pull        ベースモデルを取得"
	@echo "  make models      modelfiles/ から専用モデルを作り直す"
	@echo "  make icons       assets/logo.png から macOS アイコン一式を生成"
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

# assets/logo.png を差し替えたら実行する。
# macOS はアイコンを自動で角丸にしないため、形状と余白を焼き込む必要がある。
icons:
	@uv run --quiet --with pillow python scripts/make-icons.py

clean-models:
	@echo "削除候補:"; ollama list
	@echo "個別に 'ollama rm <名前>' で消してください（誤削除防止のため一括削除はしません）"

# --- macOS アプリ ----------------------------------------------------------
# ソースを追加するのに project.pbxproj を編集する必要は無い。
# Sophia/Sources/ 配下に .swift を置けば、同期グループが自動で拾う。

app:
	@$(XCODEBUILD) -configuration Debug build

app-release:
	@$(XCODEBUILD) -configuration Release build

app-run: app
	@open "$(APP_DEBUG)"

# Xcode のテストターゲット（SophiaTests）。永続化層 = DB のテストがここに入る。
# **GPU もモデルも使わない**ので、他の作業と並行して回して安全（全体で1秒未満）。
# ホストアプリを一瞬起動して、その中でテストバンドルを走らせる仕組みなので、
# 画面に Sophia のウィンドウが出て消える。異常ではない。
app-test:
	@$(XCODEBUILD) -configuration Debug test

# 依存（MLX の C++ と Metal シェーダ）まで消える。復旧に約5分半かかる。
app-clean:
	@rm -rf $(XC_DERIVED)

# 初回のみ。Xcode 26 では Metal シェーダのコンパイラが別ダウンロード（約688MB）に
# なっており、これが無いと mlx-swift のビルドが
# 「cannot execute tool 'metal' due to missing Metal Toolchain」で失敗する。
# 取り消すときは: xcodebuild -deleteComponent MetalToolchain
app-setup:
	@xcodebuild -showComponent MetalToolchain
	@xcodebuild -downloadComponent MetalToolchain

# --- 推論層のテスト --------------------------------------------------------
# **モデルは読まないし、推論も走らせない。** 文字列を流し込むだけなので
# 16GB機で他の作業と並行して回しても安全（数秒で終わる）。
#
# Xcode のテストターゲットを使っていないのは、思考タグ分離器を
# MLX 非依存に保ってあるため。素の swift で回るほうが速く、依存も要らない。
.PHONY: test-inference

test-inference:
	@swift scripts/test-thinking-splitter.swift
	@echo ""
	@swift scripts/test-splitter-vs-official.swift
