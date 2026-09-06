# 人物像の座標系 —— 既存モデルを借りる

| 項目 | 内容 |
|---|---|
| 記録日 | 2026-09-06 |
| 位置づけ | **初回質問（FR-24〜26）が何を測っているのかを、標準語彙で書き直すための表** |
| 状態 | **写像は書いた。実装は未着手** |

---

## なぜ借りるのか

利用者の指示:

> **「心理学 IQ EQ 統計学（四柱推命 血液型） この思想だよ」**
> **「そういう基盤になる個人分析系のモデル GitHub にあるんじゃない？ 0から考えるんじゃなくて」**

**そのとおりで、在る。** そして**自分で作った14個の軸には名前が無かった** ──
「説明の粒度」「反対意見を言う時機」は、**このプロジェクトの中でしか通じない語彙**である。
標準語彙に載せれば、**他人の研究と、307,313人ぶんの実データに接続できる。**

### 借りる先: IPIP（パブリックドメイン）

| | |
|---|---|
| **IPIP-NEO-120 / 300** | Goldberg と Johnson による NEO-PI-R のパブリックドメイン版。**5領域 × 6ファセット = 30** |
| 実装 | [NeuroQuestAi/five-factor-e](https://github.com/NeuroQuestAi/five-factor-e)（MIT。項目は IPIP としてパブリックドメイン） |
| データ | [automoto/big-five-data](https://github.com/automoto/big-five-data) — **307,313人**の各国スコア |
| 一次資料 | [ipip.ori.org](https://ipip.ori.org/30FacetNEO-PI-RItems.htm) |

### ⚠ 借りるのは**次元であって、項目文ではない**

**IPIP は自己申告の5段階リッカート**（「私はすぐに緊張する」に1〜5）。
**本設計はそれを2か所で明示的に否定している。**

- **FR-26**: **様式は直接質問しない。** 同じ問いへの複数の回答案から**選ばせて**採取する
- **14.13c**: **自己申告は様式に当てにならず、実際に直したときに出るものが証拠である**

> **したがって借り方は「次元を借り、採り方は選択のまま」である。**
> **項目文を貼ると、設計が捨てたはずの自己申告が裏口から戻る。**

---

## 30ファセット（IPIP-NEO / Johnson 2014）

| 領域 | ファセット |
|---|---|
| **N** 情動安定性の低さ | Anxiety / Anger / Depression / Self-Consciousness / Immoderation / Vulnerability |
| **E** 外向性 | Friendliness / Gregariousness / Assertiveness / Activity Level / Excitement-Seeking / Cheerfulness |
| **O** 開放性 | Imagination / Artistic Interests / Emotionality / Adventurousness / Intellect / Liberalism |
| **A** 協調性 | Trust / Morality / Altruism / Cooperation / Modesty / Sympathy |
| **C** 誠実性 | Self-Efficacy / Orderliness / Dutifulness / Achievement Striving / Self-Discipline / Cautiousness |

---

## いまの14軸を写像する

**確度は正直に書く。** 無理に当てると、**当てた先の研究知見を根拠として使えなくなる。**

| 軸 | 主ファセット | 確度 | 備考 |
|---|---|:--:|---|
| `machine` 資源が足りないと分かったとき | **C: Cautiousness** | 中 | 足すか、足りない前提で測るか |
| `certainty` まだ試していないことの言い方 | **C: Dutifulness** | **高** | 断定と推測を書き分けるか。副: E: Assertiveness |
| `verification` 「終わった」と言ってよい条件 | **C: Self-Discipline** | 中 | やり切る基準の位置 |
| `granularity` 説明の粒度 | **O: Intellect** | 中 | 過程まで欲しいか、結論だけか |
| `pushback` 反対意見を言う時機 | **A: Cooperation** | **高** | 従うか、着手前に止めるか |
| `code` 直したものの渡し方 | **C: Orderliness** | 低 | 全文か差分か。**様式の色が濃く、性格の次元としては弱い** |
| `autonomy` 手を動かす前に訊くか | **E: Assertiveness** | 中 | 副: A: Cooperation |
| `attunement` つらい報告への最初の一言 | **A: Sympathy** | **高** | **EQ の中核** |
| `challenge` 考えを深めるための反論 | **O: Liberalism** | 中 | 既存の枠を疑うか |
| `conflict` 『全然違う』のあとの戻り方 | **A: Trust** | 中 | 関係の修復の仕方 |
| `values` 納期と品質が守れないとき | **C: Achievement Striving** | 中 | 価値判断。副: C: Dutifulness |
| `setback` 失敗のあとに意味を作る順序 | **N: Vulnerability**（逆） | **高** | 打たれたあとの立ち直り方 |
| `archetypes` 類型情報の扱い | — | — | **これは性格の軸ではなく、下記「事前分布」の方針** |
| `completion` 『終わった』と言ってよい地点 | **C: Self-Discipline** | 低 | `verification` と重複している |

### 【欠けている次元】—— これが「エンジニアの好み調査」に見えた正体

| 領域 | 覆えている | 空 |
|---|--:|---|
| **C** 誠実性 | **6/6 のうち5** | Self-Efficacy |
| **A** 協調性 | 4/6 | Morality / Altruism / Modesty |
| **O** 開放性 | 3/6 | Imagination / Artistic Interests / Adventurousness |
| **N** 情動安定性 | **1/6** | **Anxiety / Anger / Depression / Self-Consciousness / Immoderation** |
| **E** 外向性 | **1/6** | **Friendliness / Gregariousness / Activity Level / Excitement-Seeking / Cheerfulness** |

> **C に5本、N と E に1本ずつ。**
> **「仕事をどう扱ってほしいか」だけが密で、「その人がどういう人か」が空だった。**
> 場面を全方向にしても（`ecd333f`）、**測っている次元は偏ったままである。**

---

## 統計学の側 —— **四柱推命・血液型は「事前分布」である**

**14.13c が既に同じ言葉で書いている: 「質問は事前分布であって証拠ではない」。**
**四柱推命と血液型も、まったく同じ扱いにする。**

| | 何に使うか | 何に使わないか |
|---|---|---|
| **人口の分布**（307,313人） | **既定値。** 何も知らない相手の初期値 | 個人の断定 |
| **生年月日 / 血液型** | **事前分布をずらす**（$P(\\theta)$ の初期値） | **性格の答えにしない** |
| **質問の答え** | 事前分布をさらにずらす | 同上 |
| **使用中の訂正**（FR-31） | **証拠。** ここだけが事後分布を動かす | — |

**この並びが本設計の骨である。**
**類型は入口であって結論ではない** ── `archetypes` の回答案が既にその形になっている
（「仮説の入口に使い、本人の受け止め方と観察で確かめる」／「属性から性格を推定しない」）。

> **統計学として正しい言い方をすると:**
> **類型情報は事前分布、質問は弱い尤度、訂正は強い尤度である。**
> **事前分布だけで断定するのが「占い」で、事前分布を持たないのが「毎回ゼロから訊く」である。**
> **どちらも避ける。**

---

## IQ / EQ をどう置くか

| | 置き方 |
|---|---|
| **EQ** | **Big Five に写る。** A: Sympathy / N: 各ファセット / O: Emotionality。**別体系を持ち込まない** |
| **IQ** | **測らない。** 12問の選択で知能は測れない。**測れないものを測ったふりをしない**（R6） |
| IQ の代わりに測るもの | **認知スタイル** ── O: Intellect（抽象度の好み）、C: Cautiousness（曖昧さへの耐性）、O: Imagination |

---

## 次にやること

1. **`OnboardingQuestion` にファセットの欄を足す**（`facet: "C:Dutifulness"` 等）。**軸の名前は日本語のまま残す** ── 利用者に見せるのはそちら（FR-28）
2. **空いている N と E を埋める質問を足す。** 特に **N: Anxiety / E: Friendliness** は、
   **どう接してほしいかに直結する**（急かすか待つか、雑談を挟むか用件だけか）
3. **`completion` は `verification` と重複している。** どちらかを畳んで枠を空ける
4. **人口の事前分布を入れる**（`big-five-data` の分布を初期値に）
5. **`archetypes` を入口として設計し直す** ── 生年月日を訊くのは、**そこから性格を決めるためではなく、事前分布をずらすため**である、と画面に書く

---

## 関連

- [PHILOSOPHY.md](PHILOSOPHY.md) —— 一人でいい／嘘と逃げの匙加減
- [DESIGN.md](DESIGN.md) 第14章 —— 14.8（効く質問）/ 14.9（質問の予算）/ 14.13c（**質問は事前分布**）
- [REQUIREMENTS.md](REQUIREMENTS.md) —— FR-24〜26 / FR-31（訂正の向き＝強い尤度）
