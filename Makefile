.PHONY: help up down restart status logs models bench bench-save pull clean-models icons \
        app app-release app-run app-test test-audit app-clean app-setup app-stats app-watch stats-tail

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
	@echo "  make app-test    全テスト＋実行漏れの監査。GPUもモデルも使わない"
	@echo "  make test-audit  宣言したテストが実際に実行されたかを名前で突き合わせる"
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
		$(if $(LOG_LOAD),--env SOPHIA_LOG_LOAD=$(LOG_LOAD),) \
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
# **`LOG_LOAD=1` で `[LOAD]` 行が付く** ── 取得の見張り（`ModelDownloadStallWatch`）が
# 5秒ごとに `progress` と `disk_bytes` を並べて出す。
#
# **既定で入れてあるのは、正常系が何も記録を残さないからである。**
# `event=stalled` の1行だけは無条件に出るが、**それは打ち切ったときにしか出ない** ──
# **「打ち切らなかったとき、なぜ打ち切らなかったのか」はログに残らない。**
#
# 2026-09-05 の実機検証でこれに気づいた。448秒間 打ち切られずに取得が続いたが、
# **`disk_bytes` が1行も残っていないため「ディスク信号が打ち切りを止めた」ことを示せなかった**
# （`Progress` が正常に更新されていただけ、という可能性を否定できない）。
# **判定の根拠がログに無いと、合格を主張できない**（docs/DOWNLOAD_VERIFY.md の A3）。
app-watch:
	@$(MAKE) --no-print-directory app-stats LOG_MEM=1 LOG_LOAD=1 NOTE="$(NOTE)"

stats-tail:
	@tail -f $(STATS_LOG) | grep --line-buffered '^\[STATS\]'

# Xcode のテストターゲット（SophiaTests）。永続化層 = DB のテストがここに入る。
# **GPU もモデルも使わない**ので、他の作業と並行して回して安全（496件・約5秒）。
# ホストアプリを一瞬起動して、その中でテストバンドルを走らせる仕組みなので、
# 画面に Sophia のウィンドウが出て消える。異常ではない。
app-test:
	@$(XCODEBUILD) -configuration Debug test
	@$(MAKE) --no-print-directory test-audit

# 宣言されたテストが本当に実行されたかを、名前で突き合わせる（R9 / DESIGN 15.8節）。
#
# **`app-test` の後ろに繋いであるのは意図的である。** 別targetにすると
# 「打った人にしか走らない検査」になり、まさにこの器が防ごうとしている形
# （既定で走らない仕掛けが、正しさを守る唯一の守りになっている）を自分で作ることになる。
#
# 落ちる条件は「宣言されているのに実行時に現れない」だけ。
# skip は落とさないが**毎回実名で出す** ── `totalTestCount` は skip を
# 「走った」に数えるので、数の突き合わせでは中身が走っていないことを見抜けない。
# 名前が目に入れば人が気づける（例: `testToolDefinitionTokenCost` = 499 の唯一の裏取り）。
test-audit:
	@python3 scripts/audit-tests.py

# --- プリフィル崩れの切り分け計測 ------------------------------------------
# **これは重い。** 4.6GB のモデルを読み込んで実際に推論を回すので、
# `app-test`（496件・約5秒。モデルもGPUも使わない）とはまったく性格が違う。
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
# **思考モードで測るか。** 既定 0（OFF）。アプリの既定は ON なので、
# **1 で測るほうが実使用に近い**（2026-08-18、実機で呼ばれない事象が出て追加）。
TOOLPROBE_THINK ?= 0
# **system メッセージを送るか。** 既定 1（＝実機と同じ）。
# 0 にすると従来の測り方（system 無し）に戻る。2026-08-18 追加。
TOOLPROBE_SYSTEM ?= 1
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
	          SOPHIA_TOOLPROBE_TEMP=$(TOOLPROBE_TEMP) \
	          SOPHIA_TOOLPROBE_THINK=$(TOOLPROBE_THINK) \
	          SOPHIA_TOOLPROBE_SYSTEM=$(TOOLPROBE_SYSTEM); do \
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
# --- ウェブ検索を実地で確かめる（FR-30）------------------------------------
# **固定HTMLの試験は「書いたときの形」しか守らない。**
# DuckDuckGo は公式APIではないので、**先方が HTML を変えたら緑のまま0件になる。**
# だから本物に当てる1本を、env で隔離して置いてある。
#
# **既定で走らせないのは外部へ出るからであって、重いからではない**（NFR-01）。
# 出るのは検索語1つだけである。
# --- 自己認識はどこから来ているか（docs/ADAPTER_01.md 手順4）------------------
# **「ソフィアってすでに名乗るよ？」への答えを、口ではなく実測で出す。**
# system プロンプトを外して訊く。陰性対照が「Qwen」なら、名前は毎ターンの
# 97トークンが作っていることになる ── そこが第一号のアダプタの前提である。
# --- 第一号のアダプタを焼く（docs/ADAPTER_01.md 手順5）----------------------
# **system プロンプトを混ぜないこと。** 混ぜると「プロンプトがあるときに名乗る」を
# 学ぶだけで、それはいま既にできていることである。学習側は .system を1度も足さない。
IDTRAIN_LOG ?= logs/identity-train.log
# **アプリのコンテナの中へ書くこと。** 試験はサンドボックスの中で走るので、
# ~/.sophia のような外の場所へは書けない（Operation not permitted で落ちる）。
# 読む側（アプリ）も同じコンテナなので、ここなら両方から触れる。
# **空白を含まない場所にすること。** `Application Support` に置いたら、
# 環境変数を渡す途中で空白で切れ、`Data/Library/Application/` に落ちた
# （`SAVED dir=` のログも同じ位置で切れていて、それで気づいた）。
ADAPTER_OUT ?= $(HOME)/Library/Containers/jp.co.xerographix.sophia/Data/Library/SophiaAdapters/identity-01

.PHONY: identitytrain

identitytrain:
	@mkdir -p logs
	@if [ -n "$$(pgrep -x Sophia)" ]; then \
		echo "Sophia が起動している。**先に落とすこと**: pkill -x Sophia"; \
		exit 1; \
	fi
	@SRC=$$(find $(XC_DERIVED)/Build/Products -name '*.xctestrun' ! -name '*probe.xctestrun' ! -name 'tooltokens.xctestrun' ! -name 'websearch.xctestrun' ! -name 'identity.xctestrun' ! -name 'idtrain.xctestrun' | head -1); \
	if [ -z "$$SRC" ]; then echo "先に make probe-build を実行すること"; exit 1; fi; \
	RUN=$$(dirname "$$SRC")/idtrain.xctestrun; cp "$$SRC" "$$RUN"; \
	ENV_PATH=:TestConfigurations:0:TestTargets:0:EnvironmentVariables; \
	for kv in SOPHIA_IDENTITYTRAIN=1 SOPHIA_ENGINE=stub SOPHIA_ADAPTER_OUT=$(ADAPTER_OUT) \
	          SOPHIA_IDENTITYTRAIN_ITERS=$${IDTRAIN_ITERS:-80} \
	          SOPHIA_IDENTITYTRAIN_LAYERS=$${IDTRAIN_LAYERS:-16}; do \
		k=$${kv%%=*}; v=$${kv#*=}; \
		/usr/libexec/PlistBuddy -c "Add $$ENV_PATH:$$k string $$v" "$$RUN" >/dev/null 2>&1 \
			|| /usr/libexec/PlistBuddy -c "Set $$ENV_PATH:$$k $$v" "$$RUN"; \
	done; \
	caffeinate -dimsu xcodebuild test-without-building -xctestrun "$$RUN" \
		-destination '$(XC_DEST)' \
		-only-testing:SophiaTests/IdentityTrainingTests \
		2>&1 | tee $(IDTRAIN_LOG) | grep -E 'IDTRAIN|error:|Executed'

IDENTITY_LOG ?= logs/identity-probe.log

.PHONY: identityprobe

identityprobe:
	@mkdir -p logs
	@if [ -n "$$(pgrep -x Sophia)" ]; then \
		echo "Sophia が起動している。**先に落とすこと**: pkill -x Sophia"; \
		echo "（4.4GB を持つプロセスが2つ居ると、測るのは推論ではなくメモリ争奪になる）"; \
		exit 1; \
	fi
	@SRC=$$(find $(XC_DERIVED)/Build/Products -name '*.xctestrun' ! -name '*probe.xctestrun' ! -name 'tooltokens.xctestrun' ! -name 'websearch.xctestrun' ! -name 'identity.xctestrun' | head -1); \
	if [ -z "$$SRC" ]; then echo "先に make probe-build を実行すること"; exit 1; fi; \
	RUN=$$(dirname "$$SRC")/identity.xctestrun; cp "$$SRC" "$$RUN"; \
	ENV_PATH=:TestConfigurations:0:TestTargets:0:EnvironmentVariables; \
	for kv in SOPHIA_IDENTITYPROBE=1 SOPHIA_ENGINE=stub SOPHIA_IDENTITY_ADAPTER="$${IDENTITY_ADAPTER:-}"; do \
		k=$${kv%%=*}; v=$${kv#*=}; \
		/usr/libexec/PlistBuddy -c "Add $$ENV_PATH:$$k string $$v" "$$RUN" >/dev/null 2>&1 \
			|| /usr/libexec/PlistBuddy -c "Set $$ENV_PATH:$$k $$v" "$$RUN"; \
	done; \
	xcodebuild test-without-building -xctestrun "$$RUN" \
		-destination '$(XC_DEST)' \
		-only-testing:SophiaTests/IdentityProbeTests \
		2>&1 | tee $(IDENTITY_LOG) | grep -E 'IDENTITY|error:|Executed'

WEBSEARCH_LOG ?= logs/websearch-probe.log

.PHONY: websearch

websearch:
	@mkdir -p logs
	@SRC=$$(find $(XC_DERIVED)/Build/Products -name '*.xctestrun' ! -name '*probe.xctestrun' ! -name 'tooltokens.xctestrun' ! -name 'websearch.xctestrun' | head -1); \
	if [ -z "$$SRC" ]; then echo "先に make probe-build を実行すること"; exit 1; fi; \
	RUN=$$(dirname "$$SRC")/websearch.xctestrun; cp "$$SRC" "$$RUN"; \
	ENV_PATH=:TestConfigurations:0:TestTargets:0:EnvironmentVariables; \
	for kv in SOPHIA_WEBSEARCH_PROBE=1 SOPHIA_ENGINE=stub; do \
		k=$${kv%%=*}; v=$${kv#*=}; \
		/usr/libexec/PlistBuddy -c "Add $$ENV_PATH:$$k string $$v" "$$RUN" >/dev/null 2>&1 \
			|| /usr/libexec/PlistBuddy -c "Set $$ENV_PATH:$$k $$v" "$$RUN"; \
	done; \
	xcodebuild test-without-building -xctestrun "$$RUN" \
		-destination '$(XC_DEST)' \
		-only-testing:SophiaTests/WebSearchTests/testTheRealDuckDuckGoStillParses \
		2>&1 | tee $(WEBSEARCH_LOG) | grep -E 'WEBSEARCH_PROBE|error:|Executed'

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
	set -o pipefail; \
	xcodebuild test-without-building -xctestrun "$$RUN" -destination '$(XC_DEST)' \
		-only-testing:SophiaTests/EngineToolWiringTests/testToolDefinitionTokenCost \
		2>&1 | tee -a $(TOOLTOKENS_LOG) | { grep -E '^\[TOOLTOKENS|Executed|error:|\*\* TEST' || true; }
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
	set -o pipefail; \
	xcodebuild test-without-building -xctestrun "$$RUN" -destination '$(XC_DEST)' \
		-only-testing:SophiaTests/ToolCostBreakdownTests \
		2>&1 | tee -a $(TOOLBREAKDOWN_LOG) | { grep -E '^\[BREAKDOWN|Executed|error:|\*\* TEST' || true; }
	@echo "計測ログ: $(TOOLBREAKDOWN_LOG)"

# --- LoRA が16GB機で回るか、「いくら要るか」を測る（FR-24〜29 / DESIGN 第14章）--
# **第14章の設計はこの計測1つに懸かっている。**
#
# パーソナライズを「毎ターン注入」から「重みに書く」へ変えられるかどうか。
# 注入の費用は **N トークン × 会話が続く限り永久**、LoRA の費用は **0**。
# そして注入する余地はもう無い ── `SophiaDefaults.InputBudget` の配分で
# **利用者に残っているのは 33 トークンである**（1,000 − 105 − 499 − 183 − 180）。
#
# **測るのは「動いた／動かない」ではなく「いくら要るか」である。**
# メモリ・1イテレーションの単価・アダプタの実寸を、条件を振りながら取る。
# **既定のハイパーパラメータ（iterations: 1000）では回さない** ──
# 少ない回数で単価を測り、外挿する（外挿は `[LORA-EST]` 行に隔離してある）。
#
# `probe` / `toolprobe` と同じく `.xctestrun` 経由で環境変数を渡す
# （`TEST_RUNNER_` はこの構成では効かない。2026-08-17 実測）。
#
# **`SOPHIA_ENGINE=stub` を必ず入れる。** 入れないとホストアプリが
# モデルをもう1つ読み込み、**測定値がちょうど2倍になる**（2026-08-18 に実際に踏んだ）。
# 効いているかは `[LORA-PRE] suspect_double_load=` で確認できる（1 なら疑うこと）。
#
# ## 打つ順序
#
#   make probe-build              # 1回だけ。計測のたびにビルドしない（条件が揃わなくなる）
#   （別窓で） make probe-watch    # 系全体の数字。**これ無しで結論を出さない**
#   make lora
#
# **`peak_mb` は MLX の帳簿であって、物理RAMに載っているかではない**（2026-08-17 実測）。
# 16GB に収まるかの判定は `probe-watch` 側の `vm_stat` と突き合わせて初めて言える。
#
# ## 何を掃くか ── **既定は層数だけを振る**
#
# **層数がメモリの主因**である ─ 逆伝播が何層ぶん遡るかで、生かしておく活性値の量が決まる。
# `rank` はほぼ寸法の話で、メモリにはあまり効かない（効くのは**アダプタの実寸と容量**）。
# だから既定は `LORA_LAYERS=2,4,8,16 / LORA_RANK=8`（16 と 8 はライブラリの既定値）。
# 回る層数が分かってから、2周目でこう振る:
#
#   make lora LORA_LAYERS=<回った層数> LORA_RANK=4,8,16,32   # アダプタ実寸の設計
#   make lora LORA_LAYERS=<回った層数> LORA_BATCH=1,2,4      # バッチを増やす余地
#   make lora LORA_LAYERS=<回った層数> LORA_TOKENS=256,512   # 系列長の余地
#   make lora LORA_KEYS=self_attn.q_proj,self_attn.v_proj    # 射影を絞る（mlx-lm の既定）
#
# 条件は直積を作り、**必ず安い順に回す。** 高い条件で系ごと落ちても、
# 安い条件の結果は既にログに出ている（1行ずつ生の write(2) で吐いている）。
# 何が回らなかったかは冒頭の `[LORA-PLAN]` と `[LORA-CFG]` の差で分かる。
#
# ## 先に配管だけ通したいとき（**4.4GB を読む前に**）
#
#   make lora LORA_MODEL=mlx-community/Qwen3-0.6B-4bit LORA_LAYERS=2 LORA_ITERS=3
#
# 数分で終わり、`[LORA-APPLY] adapted_modules=` が 0 でないこと・
# `[LORA-CFG] ok=1` が出ることまで確かめられる。**そこが通ってから本番の8Bを回す。**
# （そのモデルがローカルに無ければテストは測らずにスキップする。取得は計測に混ぜない）
LORA_LAYERS ?= 2,4,8,16
LORA_RANK   ?= 8
LORA_BATCH  ?= 1
LORA_TOKENS ?= 256
LORA_ITERS  ?= 8
LORA_KEYS   ?=
LORA_KEEP   ?= 0
LORA_MODEL  ?=
LORA_LABEL  ?=
LORA_LOG    ?= logs/lora-feasibility.log

.PHONY: lora

lora:
	@mkdir -p logs
	@if [ -n "$$(pgrep -x Sophia)" ]; then \
		echo "Sophia が起動している。**先に落とすこと**: pkill -x Sophia"; \
		echo "（4.4GB を持つプロセスが2つ居ると、測るのは学習の費用ではなくメモリ争奪になる）"; \
		exit 1; \
	fi
	@SRC=$$(find $(XC_DERIVED)/Build/Products -name '*.xctestrun' ! -name '*probe.xctestrun' ! -name 'tooltokens.xctestrun' ! -name 'breakdown.xctestrun' | head -1); \
	if [ -z "$$SRC" ]; then echo "先に make probe-build を実行すること"; exit 1; fi; \
	RUN=$$(dirname "$$SRC")/loraprobe.xctestrun; cp "$$SRC" "$$RUN"; \
	ENV_PATH=:TestConfigurations:0:TestTargets:0:EnvironmentVariables; \
	for kv in SOPHIA_LORA=1 SOPHIA_ENGINE=stub \
	          SOPHIA_LORA_LAYERS=$(LORA_LAYERS) \
	          SOPHIA_LORA_RANK=$(LORA_RANK) \
	          SOPHIA_LORA_BATCH=$(LORA_BATCH) \
	          SOPHIA_LORA_TOKENS=$(LORA_TOKENS) \
	          SOPHIA_LORA_ITERS=$(LORA_ITERS) \
	          SOPHIA_LORA_KEYS=$(LORA_KEYS) \
	          SOPHIA_LORA_KEEP=$(LORA_KEEP) \
	          SOPHIA_LORA_MODEL=$(LORA_MODEL) \
	          SOPHIA_LORA_LABEL=$(LORA_LABEL); do \
		k=$${kv%%=*}; v=$${kv#*=}; \
		/usr/libexec/PlistBuddy -c "Add $$ENV_PATH:$$k string $$v" "$$RUN" >/dev/null 2>&1 \
			|| /usr/libexec/PlistBuddy -c "Set $$ENV_PATH:$$k $$v" "$$RUN"; \
	done; \
	printf '=== %s layers=%s rank=%s batch=%s tokens=%s iters=%s keys=%s label=%s ===\n' \
		"$$(date '+%F %T')" "$(LORA_LAYERS)" "$(LORA_RANK)" "$(LORA_BATCH)" \
		"$(LORA_TOKENS)" "$(LORA_ITERS)" "$(LORA_KEYS)" "$(LORA_LABEL)" >> $(LORA_LOG); \
	sysctl -n vm.swapusage >> $(LORA_LOG); \
	vm_stat | grep -E 'Pages free|occupied by compressor' >> $(LORA_LOG); \
	xcodebuild test-without-building -xctestrun "$$RUN" -destination '$(XC_DEST)' \
		-only-testing:SophiaTests/LoRAFeasibilityTests \
		2>&1 | tee -a $(LORA_LOG) | grep -E '^\[LORA|Executed|error:|\*\* TEST' || true; \
	sysctl -n vm.swapusage >> $(LORA_LOG); \
	vm_stat | grep -E 'Pages free|occupied by compressor' >> $(LORA_LOG); \
	rm -f "$$RUN"
	@echo "計測ログ: $(LORA_LOG)"
	@echo "読む順: [LORA-PLAN] → [LORA-APPLY]（adapted_modules が 0 でないこと）→ [LORA-CFG] → [LORA-EST]"

# --- 何件の学習データで様式が乗るかを測る（DESIGN 14.10節 / 14.16節 ⑦）------
# **設計の中に残った食い違いを1つ潰すための計測である。**
#
#   | 出所 | 主張 |
#   |---|---|
#   | 10.5節   | LoRA で意味のある差を出すには **数千件** |
#   | 第14章   | 質問30問と訂正の蓄積 ＝ **数十〜数百件** |
#
# **どちらが正しいかで第14章が成立するかどうかが変わる。**
# 初回の質問で集められるのはせいぜい数十件であり、**数千件が要るなら質問だけでは足りない。**
# 資源の側は 14.13a節で決着済み（16GB で 8B 本体でも回る）。残るのは件数だけである。
#
# ## 何をするか
#
# **「自明な様式」を的にして、20 / 50 / 100 件で立ち上がりを見る。**
# 的は「答えの全行を `- ` で始める」── 見れば分かり、機械で数えられ、素の出力とは形が違う。
# **学習前（陰性対照）と、指示文を足した場合（陽性対照）を必ず先に測る。**
# 学習前に通ってしまう規則なら何も測れていないので、**掃引に入る前に落とす。**
#
# `lora` と同じく `.xctestrun` 経由で環境変数を渡す（`TEST_RUNNER_` はこの構成では効かない）。
# **`SOPHIA_ENGINE=stub` を必ず入れる。** 入れないとホストアプリがモデルをもう1つ読み、
# 測定値がちょうど2倍になる。効いているかは `[LORASIZE-PRE] suspect_double_load=` で見る。
#
# `.xctestrun` の名前を `lorasizeprobe.xctestrun` にしてあるのは、
# **既存の各ターゲットの `find ... ! -name '*probe.xctestrun'` に自動で引っかかるため**である
# （途中で殺されて残っても、`lora` / `toolprobe` / `tooltokens` / `toolbreakdown` が
# これを SRC として拾わない）。名前を変えるときはこの点を確かめること。
#
# ## 打つ順序
#
#   make probe-build              # 1回だけ。計測のたびにビルドしない（条件が揃わなくなる）
#   （別窓で） make probe-watch    # 系全体の数字。**これ無しで結論を出さない**
#   make lorasize
#
# ## まず配管だけ通したいとき（**1時間を賭ける前に**）
#
#   make lorasize LORASIZE_N=20 LORASIZE_EPOCHS=1 LORASIZE_SEEDS=1 LORASIZE_MAXTOK=120
#
# 数分で終わり、`[LORASIZE-RULE] ok=1` →`[LORASIZE-APPLY] adapted_modules≠0` →
# `[LORASIZE-COND] ok=1` まで通ることを確かめられる。**そこが通ってから本番を回す。**
# 0.6B で更に軽くしたいなら `LORASIZE_MODEL=mlx-community/Qwen3-0.6B-4bit` を足す
# （ローカルに無ければ測らずにスキップする。取得は計測に混ぜない）。
#
# ## 2周目に必ず回すこと ── **交絡の切り分け**
#
# `LoRABatchIterator` はデータを無限に周回するので、**ステップ数は件数と独立に決まる。**
# 既定（周回数を固定）では、件数が増えるとステップ数も増える ＝ **2つの効果が混ざっている。**
#
#   make lorasize LORASIZE_ITERS=200      # ステップ数を固定して、件数の効果だけを見る
#
# `[LORASIZE-CURVE] confounded=` が 1 なら混ざったまま、0 なら分けて測った回である。
LORASIZE_N          ?= 20,50,100
LORASIZE_EPOCHS     ?= 4
LORASIZE_ITERS      ?= 0
LORASIZE_LAYERS     ?= 16
LORASIZE_RANK       ?= 8
LORASIZE_BATCH      ?= 1
LORASIZE_LR         ?= 1e-5
LORASIZE_KEYS       ?=
LORASIZE_SEEDS      ?= 2
LORASIZE_MAXTOK     ?= 220
LORASIZE_TEMP       ?= 0.7
LORASIZE_THINK      ?= 0
LORASIZE_REPORT     ?= 10
LORASIZE_MODEL      ?=
LORASIZE_LABEL      ?=
LORASIZE_LOG        ?= logs/lora-sample-size.log

.PHONY: lorasize

lorasize:
	@mkdir -p logs
	@if [ -n "$$(pgrep -x Sophia)" ]; then \
		echo "Sophia が起動している。**先に落とすこと**: pkill -x Sophia"; \
		echo "（4.4GB を持つプロセスが2つ居ると、測るのは学習の費用ではなくメモリ争奪になる）"; \
		exit 1; \
	fi
	@echo "**重い。** 既定（20/50/100 × 4周）で1時間前後かかる見込み。"
	@echo "実測に基づく残り時間は [LORASIZE-ETA] 行に出る。まず配管だけ通すなら:"
	@echo "  make lorasize LORASIZE_N=20 LORASIZE_EPOCHS=1 LORASIZE_SEEDS=1 LORASIZE_MAXTOK=120"
	@SRC=$$(find $(XC_DERIVED)/Build/Products -name '*.xctestrun' ! -name '*probe.xctestrun' ! -name 'tooltokens.xctestrun' ! -name 'breakdown.xctestrun' | head -1); \
	if [ -z "$$SRC" ]; then echo "先に make probe-build を実行すること"; exit 1; fi; \
	RUN=$$(dirname "$$SRC")/lorasizeprobe.xctestrun; rm -f "$$RUN"; cp "$$SRC" "$$RUN"; \
	ENV_PATH=:TestConfigurations:0:TestTargets:0:EnvironmentVariables; \
	for kv in SOPHIA_LORASIZE=1 SOPHIA_ENGINE=stub \
	          SOPHIA_LORASIZE_N=$(LORASIZE_N) \
	          SOPHIA_LORASIZE_EPOCHS=$(LORASIZE_EPOCHS) \
	          SOPHIA_LORASIZE_ITERS=$(LORASIZE_ITERS) \
	          SOPHIA_LORASIZE_LAYERS=$(LORASIZE_LAYERS) \
	          SOPHIA_LORASIZE_RANK=$(LORASIZE_RANK) \
	          SOPHIA_LORASIZE_BATCH=$(LORASIZE_BATCH) \
	          SOPHIA_LORASIZE_LR=$(LORASIZE_LR) \
	          SOPHIA_LORASIZE_KEYS=$(LORASIZE_KEYS) \
	          SOPHIA_LORASIZE_SEEDS=$(LORASIZE_SEEDS) \
	          SOPHIA_LORASIZE_MAXTOK=$(LORASIZE_MAXTOK) \
	          SOPHIA_LORASIZE_TEMP=$(LORASIZE_TEMP) \
	          SOPHIA_LORASIZE_THINK=$(LORASIZE_THINK) \
	          SOPHIA_LORASIZE_REPORT=$(LORASIZE_REPORT) \
	          SOPHIA_LORASIZE_MODEL=$(LORASIZE_MODEL) \
	          SOPHIA_LORASIZE_LABEL=$(LORASIZE_LABEL); do \
		k=$${kv%%=*}; v=$${kv#*=}; \
		/usr/libexec/PlistBuddy -c "Add $$ENV_PATH:$$k string $$v" "$$RUN" >/dev/null 2>&1 \
			|| /usr/libexec/PlistBuddy -c "Set $$ENV_PATH:$$k $$v" "$$RUN"; \
	done; \
	printf '=== %s n=%s epochs=%s iters=%s layers=%s rank=%s seeds=%s maxtok=%s label=%s ===\n' \
		"$$(date '+%F %T')" "$(LORASIZE_N)" "$(LORASIZE_EPOCHS)" "$(LORASIZE_ITERS)" \
		"$(LORASIZE_LAYERS)" "$(LORASIZE_RANK)" "$(LORASIZE_SEEDS)" "$(LORASIZE_MAXTOK)" \
		"$(LORASIZE_LABEL)" >> $(LORASIZE_LOG); \
	sysctl -n vm.swapusage >> $(LORASIZE_LOG); \
	vm_stat | grep -E 'Pages free|occupied by compressor' >> $(LORASIZE_LOG); \
	xcodebuild test-without-building -xctestrun "$$RUN" -destination '$(XC_DEST)' \
		-only-testing:SophiaTests/LoRASampleSizeTests \
		2>&1 | tee -a $(LORASIZE_LOG) | grep -E '^\[LORASIZE|Executed|error:|\*\* TEST' || true; \
	sysctl -n vm.swapusage >> $(LORASIZE_LOG); \
	vm_stat | grep -E 'Pages free|occupied by compressor' >> $(LORASIZE_LOG); \
	rm -f "$$RUN"
	@echo "計測ログ: $(LORASIZE_LOG)"
	@echo "  （学習データと出力の全文はログにだけ入る。端末には [LORASIZE...] 行しか出ない）"
	@echo "読む順:"
	@echo "  1. [LORASIZE-RULE]  ok=1 か（判定規則が対象を測っているか）"
	@echo "  2. [LORASIZE-COND]  id=n0-plain の pass_rate（学習前。低いほど計測が成立している）"
	@echo "  3. [LORASIZE-COND]  id=n0-instructed の pass_rate（天井）"
	@echo "  4. [LORASIZE-COND]  各 n の loss_moved=1 / trusted=1 を確認してから pass_rate を読む"
	@echo "  5. [LORASIZE-CURVE] **結論。** rises_at が答え。confounded= も必ず見ること"
	@echo "  疑わしいときは [LORASIZE-OUT-BEGIN]〜[LORASIZE-OUT-END] の全文を読むこと"

# --- プリフィルの再利用を測る（往復のたびに全部払い直していた件）-------------
# **測るのが先。効果を断定しない。**
#
# 2026-08-18 21:50 の実測では、1周目に 459 トークン払ったあと、
# 2周目でそれを含む 1271 トークンを**丸ごと払い直していた**
# （[STATS] in=1730 ttfr_s=57.58 prefill_s=21.50）。
#
# エンジン側は、キャッシュへ払い済みのトークン列を台帳に持ち、
# 次の周のプロンプトとの**最長共通接頭辞**だけを持ち越す。
# 綴りがずれれば共通接頭辞がそこで止まり、その先は捨てる ＝ 従来経路に落ちる。
# **既定は無効**（MLXEngine.swift 末尾「プリフィルの再利用」を読むこと）。
#
# 使い方 ── **同じ問いを2回**して並べる:
#
#   make prefill-off NOTE="基準"     ← 従来どおり全部払う
#   （アプリで往復する問いを1つ投げて、終わったら閉じる）
#   make prefill-on  NOTE="再利用"   ← 再利用する
#   （**同じ問いを投げる。** 答えが正気かどうかを目で読むこと）
#   make prefill-report              ← 2つを並べて数字にする
#
# **読む順は prefill-report の出力の下に書いてある。**
PREFILL_REUSE ?= 1

.PHONY: prefill-on prefill-off prefill-run prefill-report prefill-tail

# 再利用を有効にして起動する。
prefill-on:
	@$(MAKE) --no-print-directory prefill-run PREFILL_REUSE=1 NOTE="$(NOTE)"

# 再利用を無効にして起動する。**これが基準**（入れる前とまったく同じ経路）。
prefill-off:
	@$(MAKE) --no-print-directory prefill-run PREFILL_REUSE=0 NOTE="$(NOTE)"

# app-stats と同じ経路。違いは SOPHIA_PREFILL_REUSE を渡すことだけ。
# LOG_MEM を必ず立てるのは、[MEM] の prefill_end に round= が付くようになったため
# ── どの周の点なのかがログから復元できる。
prefill-run:
	@mkdir -p logs
	@printf '=== %s note=%s reuse=%s ===\n' "$$(date '+%F %T')" "$(NOTE)" "$(PREFILL_REUSE)" \
		>> $(STATS_LOG)
	@sysctl -n vm.swapusage >> $(STATS_LOG)
	@open -n --env SOPHIA_LOG_STATS=1 --env SOPHIA_LOG_MEM=1 \
		--env SOPHIA_PREFILL_REUSE=$(PREFILL_REUSE) \
		$(if $(SYSTEM_PROMPT),--env SOPHIA_SYSTEM_PROMPT=$(SYSTEM_PROMPT),) \
		--stderr "$(CURDIR)/$(STATS_LOG)" "$(APP_DEBUG)"
	@echo "reuse=$(PREFILL_REUSE) で起動した。計測ログ: $(STATS_LOG)"
	@echo "  別窓で make prefill-tail、終わったら make prefill-report"

# 走らせながら周ごとの実測を眺める。
prefill-tail:
	@tail -f $(STATS_LOG) | grep --line-buffered -E '^\[PREFILL\]|^\[STATS\]'

# 記録された [PREFILL] 行を起動ごとにまとめる。**これが答えを出すコマンド。**
prefill-report:
	@if [ ! -f $(STATS_LOG) ]; then \
		echo "$(STATS_LOG) が無い。先に make prefill-off / make prefill-on"; exit 1; \
	fi
	@awk '/^=== / { if (n > 0) summarize(); hdr = $$0; n = 0; prompt = 0; fed = 0; secs = 0; delete kinds; printf "\n%s\n", hdr; next } \
	     /^\[PREFILL\]/ { delete f; for (i = 2; i <= NF; i++) { split($$i, kv, "="); f[kv[1]] = kv[2] } \
	       n++; prompt += f["prompt"]; fed += f["fed"]; if (f["s"] != "-") secs += f["s"]; \
	       label = f["decision"]; if (f["reason"] != "-") label = label "(" f["reason"] ")"; kinds[label]++; \
	       printf "  round=%-3s prompt=%-6s fed=%-6s reused=%-6s trimmed=%-5s s=%-7s %s\n", f["round"], f["prompt"], f["fed"], f["reused"], f["trimmed"], f["s"], label; next } \
	     /^\[STATS\]/ { stats = $$0 } \
	     END { if (n > 0) summarize(); if (rounds == 0) { print "  [PREFILL] 行が1行も無い。古いバイナリで測っていないか確認すること（make app のあとに測る）"; exit 1 } } \
	     function summarize(   k, saved) { saved = prompt - fed; rounds += n; \
	       printf "  --------------------------------------------------------\n"; \
	       printf "  周の数          %d\n", n; \
	       printf "  描画 合計       %d トークン  <- [STATS] in= と一致するはず\n", prompt; \
	       printf "  実払い 合計     %d トークン  <- 実際に払った量\n", fed; \
	       printf "  払わずに済んだ  %d トークン (%.1f%%)\n", saved, (prompt ? saved * 100 / prompt : 0); \
	       printf "  プリフィル秒    %.2f  <- [STATS] prefill_s= と一致するはず\n", secs; \
	       printf "  判断の内訳:\n"; for (k in kinds) printf "    %-26s %d\n", k, kinds[k]; \
	       if (stats != "") printf "  %s\n", stats; stats = "" }' $(STATS_LOG)
	@echo ""
	@echo "読む順:"
	@echo "  1. **器が対象を測っているか。** 各ブロックの「描画 合計」が [STATS] in= と、"
	@echo "     「プリフィル秒」が prefill_s= と一致していること。**ずれていたら以降は読まない**"
	@echo "  2. reuse=0 のブロックで『払わずに済んだ』が 0 であること（基準になっている）"
	@echo "  3. reuse=1 のブロックの『払わずに済んだ』と『プリフィル秒』を 2 と比べる"
	@echo "  4. 判断の内訳。**rebuild(short_prefix) ばかりなら効いていない** ──"
	@echo "     テンプレートの再描画が先頭近くから食い違っている（壊れてはいない）"
	@echo "  5. rebuild(trim_failed) が出ていたら報告すること。前提が違う"
	@echo ""
	@echo "**答えの中身も必ず読むこと。** 速くなっても内容が壊れていたら意味が無い"
	@echo "（SOPHIA_PREFILL_REUSE=0 に戻すだけで元に戻る）"
