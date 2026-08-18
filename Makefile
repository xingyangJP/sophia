.PHONY: help up down restart status logs models bench bench-save pull clean-models icons \
        app app-release app-run app-test app-clean app-setup app-stats app-watch stats-tail

SHELL := /bin/bash
NOTE ?=
CTX  ?= 8192
STATS_LOG ?= logs/mlx-stats.log

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
	@echo "  make app-stats   実測ログ付きで起動（[STATS] を logs/mlx-stats.log へ）"
	@echo "  make app-watch   普段使いしながら遅い往復を捕まえる（[STATS] + [MEM]）"
	@echo "  make stats-tail  その実測ログを追尾"
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

# 実測を取りながら起動する（FR-14）。
#
# **`make app-run` では [STATS] 行は1バイトも残らない。**
# `open` は LaunchServices 経由なので fd 0/1/2 がすべて /dev/null に繋がる
# （稼働中の GUI プロセスを lsof で見て確認した）。
# `ChatViewModel.logMeasurement` は生の write(2) なので `log stream` にも出ない。
# したがって計測時は --stderr で fd 2 を付け替える必要がある。
#
# --stderr は追記（O_APPEND）。--env は launchd 経由でもプロセスに届く。
# -n を付けるのは、既に起動していると open が既存プロセスを前面に出すだけで
# **新しい条件で起動し直してくれない**ため（古いプロセスを測る事故を防ぐ）。
#
# ビルドには依存させない。DerivedData を共有しているので、
# 計測のたびにビルドが走ると条件（熱・メモリ）が揃わなくなる。
app-stats:
	@mkdir -p logs
	@printf '=== %s note=%s ===\n' "$$(date '+%F %T')" "$(NOTE)" >> $(STATS_LOG)
	@sysctl -n vm.swapusage >> $(STATS_LOG)
	@open -n --env SOPHIA_LOG_STATS=1 $(if $(SYSTEM_PROMPT),--env SOPHIA_SYSTEM_PROMPT=$(SYSTEM_PROMPT),) \
		$(if $(LOG_MEM),--env SOPHIA_LOG_MEM=$(LOG_MEM),) \
		--stderr "$(CURDIR)/$(STATS_LOG)" "$(APP_DEBUG)"
	@echo "計測ログ: $(STATS_LOG)（別窓で make stats-tail）"

# 普段どおり使いながら、遅い往復を捕まえるための起動。
#
# **`LOG_MEM=1` で `[MEM]` 行が付く** ─ ロード・プリフィル・生成の各時点で
# MLX が何を確保しているかが残る。遅い往復が出たとき、
# 「確保量が増えたのか、系に追い出されたのか」を後から切り分けられる。
#
#   make app-watch
#   （別窓で） make stats-tail
app-watch:
	@$(MAKE) --no-print-directory app-stats LOG_MEM=1 NOTE="$(NOTE)"

stats-tail:
	@tail -f $(STATS_LOG) | grep --line-buffered '^\[STATS\]'

# Xcode のテストターゲット（SophiaTests）。永続化層 = DB のテストがここに入る。
# **GPU もモデルも使わない**ので、他の作業と並行して回して安全（全体で1秒未満）。
# ホストアプリを一瞬起動して、その中でテストバンドルを走らせる仕組みなので、
# 画面に Sophia のウィンドウが出て消える。異常ではない。
app-test:
	@$(XCODEBUILD) -configuration Debug test

# --- プリフィル崩れの切り分け計測 ------------------------------------------
# **これは重い。** 4.6GB のモデルを読み込んで実際に推論を回すので、
# `app-test`（全80件・1秒未満）とはまったく性格が違う。
#
# 切り分けたいのは「アイドル中に重みが compressor へ退避され、
# 次のプリフィルが伸長とページフォルトの代金を払う」という現象
# （BENCH_RESULTS.md 2026-08-17 10:24 の節で退避そのものは確認済み）。
# 残っているのは**退避の時定数** ─ どれだけ待つとどれだけ落ちるか。
#
# `SOPHIA_PROBE=1` が無いとテスト側で自らスキップする。
# 通常の `make app-test` に混ざらないのはそのため。
#
# **必ず別窓で `make probe-watch` を先に回すこと。** プロセス内の計測だけだと
# 測り方の癖を現象と取り違える。系全体の数字と突き合わせて初めて判定できる。
PROBE_TURNS       ?= 3
PROBE_GAP_S       ?= 0
PROBE_SAME_PROMPT ?= 1
PROBE_LABEL       ?=
PROBE_LOG         ?= logs/prefill-probe.log
# 生成のたびに MLX のキャッシュを解放するか（1で有効）。
# **既定は 0。** 有効にすると次の生成に再確保の代金が乗り、
# いま測っている prefill_s そのものが動く（測定行為が現象を作る）。
# 「9GB のうち何がキャッシュ由来か」を切り分けるときだけ 1 にすること。
PROBE_CLEAR_CACHE ?= 0

.PHONY: probe probe-build probe-watch

# **ビルドと計測を分ける。** `app-stats` をビルドに依存させなかったのと同じ理由で、
# 計測のたびにビルドが走ると熱とメモリの条件が揃わなくなる。
# 条件を変えて何度も回すので、ビルドは最初の1回だけにすること。
probe-build:
	@$(XCODEBUILD) -configuration Debug build-for-testing

# **条件は `.xctestrun` を書き換えて渡す。**
#
# `TEST_RUNNER_<VAR>=値` を xcodebuild の引数で渡す方法は**この構成では効かなかった**
# （2026-08-17 実測。テストは環境変数を受け取れず自らスキップして終わる）。
# あの接頭辞は UI テストのランナー向けで、ホストアプリ内のユニットテストには届かない。
#
# そこで `build-for-testing` が出した `.xctestrun` を logs/ へ複製し、
# `EnvironmentVariables` に直接足してから `-xctestrun` で実行する。
# **複製するのは、元を書き換えると条件を変えるたびに汚れるため。**
# ただし置き場所は元と同じディレクトリにする ─ `.xctestrun` の `__TESTROOT__` は
# **ファイル自身の位置を基準に解決される**ので、logs/ へ移すとテスト本体を見失う（実測）。
probe:
	@mkdir -p logs
	@SRC=$$(find $(XC_DERIVED)/Build/Products -name '*.xctestrun' ! -name 'probe.xctestrun' | head -1); \
	if [ -z "$$SRC" ]; then \
		echo "先に make probe-build を実行すること（.xctestrun が無い）"; exit 1; \
	fi; \
	RUN=$$(dirname "$$SRC")/probe.xctestrun; cp "$$SRC" "$$RUN"; \
	ENV_PATH=:TestConfigurations:0:TestTargets:0:EnvironmentVariables; \
	for kv in SOPHIA_PROBE=1 \
	          SOPHIA_ENGINE=stub \
	          SOPHIA_PROBE_TURNS=$(PROBE_TURNS) \
	          SOPHIA_PROBE_GAP_S=$(PROBE_GAP_S) \
	          SOPHIA_PROBE_SAME_PROMPT=$(PROBE_SAME_PROMPT) \
	          SOPHIA_PROBE_CLEAR_CACHE=$(PROBE_CLEAR_CACHE) \
	          SOPHIA_PROBE_LABEL=$(PROBE_LABEL); do \
		k=$${kv%%=*}; v=$${kv#*=}; \
		/usr/libexec/PlistBuddy -c "Add $$ENV_PATH:$$k string $$v" "$$RUN" >/dev/null 2>&1 \
			|| /usr/libexec/PlistBuddy -c "Set $$ENV_PATH:$$k $$v" "$$RUN"; \
	done; \
	printf '=== %s turns=%s gap=%ss same_prompt=%s label=%s ===\n' \
		"$$(date '+%F %T')" "$(PROBE_TURNS)" "$(PROBE_GAP_S)" "$(PROBE_SAME_PROMPT)" "$(PROBE_LABEL)" \
		>> $(PROBE_LOG); \
	sysctl -n vm.swapusage >> $(PROBE_LOG); \
	vm_stat | grep -E 'Pages free|occupied by compressor' >> $(PROBE_LOG); \
	xcodebuild test-without-building -xctestrun "$$RUN" -destination '$(XC_DEST)' \
		-only-testing:SophiaTests/PrefillProbeTests \
		2>&1 | tee -a $(PROBE_LOG) | grep -E '^\[PROBE|Executed|error:|\*\* TEST' || true
	@echo "計測ログ: $(PROBE_LOG)"

# --- ツール呼び出しが成立するかを測る（DESIGN 第16章の関門）------------------
# **第16章（FR-19 フォルダ参照）はこの1点に懸かっている。**
# テンプレートが対応していることと、4bit量子化された8Bが日本語の指示で
# 正しい形式を守れることは別である。**呼べなければ設計ごと変わる。**
#
# `probe` と同じく `.xctestrun` 経由で環境変数を渡す（TEST_RUNNER_ は効かない）。
# ホストアプリにモデルを読ませないため SOPHIA_ENGINE=stub も入れる。
TOOLPROBE_N    ?= 3
TOOLPROBE_TEMP ?= 0.7
TOOLPROBE_LOG  ?= logs/toolcall-probe.log

.PHONY: toolprobe

toolprobe:
	@mkdir -p logs
	@SRC=$$(find $(XC_DERIVED)/Build/Products -name '*.xctestrun' ! -name '*probe.xctestrun' | head -1); \
	if [ -z "$$SRC" ]; then echo "先に make probe-build を実行すること"; exit 1; fi; \
	RUN=$$(dirname "$$SRC")/toolprobe.xctestrun; cp "$$SRC" "$$RUN"; \
	ENV_PATH=:TestConfigurations:0:TestTargets:0:EnvironmentVariables; \
	for kv in SOPHIA_TOOLPROBE=1 SOPHIA_ENGINE=stub \
	          SOPHIA_TOOLPROBE_N=$(TOOLPROBE_N) \
	          SOPHIA_TOOLPROBE_TEMP=$(TOOLPROBE_TEMP); do \
		k=$${kv%%=*}; v=$${kv#*=}; \
		/usr/libexec/PlistBuddy -c "Add $$ENV_PATH:$$k string $$v" "$$RUN" >/dev/null 2>&1 \
			|| /usr/libexec/PlistBuddy -c "Set $$ENV_PATH:$$k $$v" "$$RUN"; \
	done; \
	printf '=== %s n=%s temp=%s ===\n' "$$(date '+%F %T')" "$(TOOLPROBE_N)" "$(TOOLPROBE_TEMP)" \
		>> $(TOOLPROBE_LOG); \
	xcodebuild test-without-building -xctestrun "$$RUN" -destination '$(XC_DEST)' \
		-only-testing:SophiaTests/ToolCallProbeTests \
		2>&1 | tee -a $(TOOLPROBE_LOG) | grep -E '^\[TOOLPROBE\]|error:|\*\* TEST' || true
	@echo "計測ログ: $(TOOLPROBE_LOG)"

# 系全体のページング状況を別経路で記録する。**計測の前に別窓で起動しておくこと。**
probe-watch:
	@./scripts/probe-watch.sh 2 logs/probe-system.log

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

# --- ツール定義の実費用を測る（DESIGN 16.9節 項目4）------------------------
# **FR-21 は「注入は必要時だけ」と決めているが、その「必要時」がいくらかを
# 測っていなかった。** 概算では駄目である ─ 概算は本日 32% 過少だった実績がある。
#
# 実トークナイザで3本を prepare して比べる:
#   ① tools 引数を書かない  ② idle（API 経由で空配列）  ③ armed（定義3つ）
# **②==① を厳密比較する。** 「渡していないつもり」を潰すのはこの1本だけである。
#
# `probe` と同じく `.xctestrun` 経由で環境変数を渡す（TEST_RUNNER_ は効かない）。
# **モデルを読むので重い。** ホストアプリ側は SOPHIA_ENGINE=stub で黙らせる。
TOOLTOKENS_LOG ?= logs/tool-token-cost.log

.PHONY: tooltokens

tooltokens:
	@mkdir -p logs
	@SRC=$$(find $(XC_DERIVED)/Build/Products -name '*.xctestrun' ! -name '*probe.xctestrun' ! -name 'tooltokens.xctestrun' | head -1); \
	if [ -z "$$SRC" ]; then echo "先に make probe-build を実行すること"; exit 1; fi; \
	RUN=$$(dirname "$$SRC")/tooltokens.xctestrun; cp "$$SRC" "$$RUN"; \
	ENV_PATH=:TestConfigurations:0:TestTargets:0:EnvironmentVariables; \
	for kv in SOPHIA_TOOLTOKENS=1 SOPHIA_ENGINE=stub; do \
		k=$${kv%%=*}; v=$${kv#*=}; \
		/usr/libexec/PlistBuddy -c "Add $$ENV_PATH:$$k string $$v" "$$RUN" >/dev/null 2>&1 \
			|| /usr/libexec/PlistBuddy -c "Set $$ENV_PATH:$$k $$v" "$$RUN"; \
	done; \
	printf '=== %s ===\n' "$$(date '+%F %T')" >> $(TOOLTOKENS_LOG); \
	xcodebuild test-without-building -xctestrun "$$RUN" -destination '$(XC_DEST)' \
		-only-testing:SophiaTests/EngineToolWiringTests/testToolDefinitionTokenCost \
		2>&1 | tee -a $(TOOLTOKENS_LOG) | grep -E '^\[TOOLTOKENS|Executed|error:|\*\* TEST' || true
	@echo "計測ログ: $(TOOLTOKENS_LOG)"

# --- ツール定義の費用の「内訳」を測る（16.9節 項目4 の但し書き）------------
# **総額だけでは打ち手が選べない。** テンプレートの固定文なのか、JSON の構造なのか、
# 説明文なのかで、効く手がまったく違う。
#
# **実際に描画された文を丸ごと出す。** 再構成の合計が実測と合わなかったとき、
# 推測で差を埋めないため ── 2026-08-18、これで `tojson` の `\uXXXX` 展開が見つかった。
TOOLBREAKDOWN_LOG ?= logs/tool-cost-breakdown.log

.PHONY: toolbreakdown

toolbreakdown:
	@mkdir -p logs
	@SRC=$$(find $(XC_DERIVED)/Build/Products -name '*.xctestrun' ! -name '*probe.xctestrun' ! -name 'tooltokens.xctestrun' ! -name 'breakdown.xctestrun' | head -1); \
	if [ -z "$$SRC" ]; then echo "先に make probe-build を実行すること"; exit 1; fi; \
	RUN=$$(dirname "$$SRC")/breakdown.xctestrun; cp "$$SRC" "$$RUN"; \
	ENV_PATH=:TestConfigurations:0:TestTargets:0:EnvironmentVariables; \
	for kv in SOPHIA_TOOLTOKENS=1 SOPHIA_ENGINE=stub; do \
		k=$${kv%%=*}; v=$${kv#*=}; \
		/usr/libexec/PlistBuddy -c "Add $$ENV_PATH:$$k string $$v" "$$RUN" >/dev/null 2>&1 \
			|| /usr/libexec/PlistBuddy -c "Set $$ENV_PATH:$$k $$v" "$$RUN"; \
	done; \
	printf '=== %s ===\n' "$$(date '+%F %T')" >> $(TOOLBREAKDOWN_LOG); \
	xcodebuild test-without-building -xctestrun "$$RUN" -destination '$(XC_DEST)' \
		-only-testing:SophiaTests/ToolCostBreakdownTests \
		2>&1 | tee -a $(TOOLBREAKDOWN_LOG) | grep -E '^\[BREAKDOWN|Executed|error:|\*\* TEST' || true
	@echo "計測ログ: $(TOOLBREAKDOWN_LOG)"
