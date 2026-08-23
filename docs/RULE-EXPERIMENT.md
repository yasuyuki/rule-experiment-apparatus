# RULE-EXPERIMENT — ルール実験装置の設計

この文書は、ルール変種を「置いて・注入して・測って・比べる」ための**選び方**の正本である。
「これで測る」と計測手段を1つに決める文書ではない。

憲法（何であるか / 何ではないか / 不変条件）は [`CONSTITUTION.md`](../CONSTITUTION.md)。
正規用語は [`TERMS.md`](../TERMS.md)。計測ログの記入規約は
[`REVIEW-CRITERIA.md`](REVIEW-CRITERIA.md)。release 操作は [`USER-GUIDE.md`](USER-GUIDE.md)。
定型ブリーフは [`templates/measurement-brief.md`](templates/measurement-brief.md)。

**この文書は憲法の不変条件を成立させる具体的な方法の正本である。** 原則そのものは
憲法にあり、ここの記述で不変条件の意味は変わらない。ここに書いたやり方は、同じ
不変条件を満たす別のやり方へ差し替えてよい（差し替えても憲法は変わらない）。

実験の器は `rule-experiments/<experiment>/`（release 名への索引と実験ごとの資料）。
**変種の正本は `agent-rules` リポジトリの `experiments/<experiment>/variants/<variant>/`**
で、release worktree の外にある（§5.1。憲法 不変条件 5）。実効位置は run の
release root `.cursor/rules/`（実証済み経路のみ）。

---

## 0. role contract と phase metadata

| role | 責務 | 固定配置 |
|---|---|---|
| `controller` | variant / workload / measurement / review / state transition を扱う | Windows の装置 workspace |
| `subject` | 注入済み variant の下で逐語の `workload.md` だけを実行する | subject ごとの隔離された config root |
| `provisioner` | subject の追加・変更、分離状態の確立と復旧、装置自身の環境整備 | 実験サイクル中は動かない |
| `baseline` | 受理済み Git 状態。対照アーム | 物理 `stable` instance |
| `run` | 未評価の実験 workspace。実験アーム | 物理 `candidate` instance |

promote は検証済み run を baseline へ反映する操作であり、物理 instance を交換しない。
rollback を含むどの状態遷移でも baseline は `stable`、run は `candidate` 以外にならない。
release state schema v3 は live workspace を `baseline` / `run` の2 slot だけで表す。
promote は run の検証済み repository bundle を
`<stable releasesRoot>/<run name>` へ復元してから state を切り替える。
`previousBaseline` は rollback 用 manifest と commit metadata であり、live channel ではない。
通常 reader は schema v2 を別名へ投影せず、専用 migration stage だけが旧 state を読む。

**アームを増やすために instance は増やさない。** 同時に立てる複数のアームはいずれも
物理 `candidate` に置き、アームごとにパスと subject の隔離先（その subject の config
root）を分ける。隔離は instance ではなく config root が担う（憲法 前文）。

**アームの実体化先は環境記述子で宣言する。** Windows にも Unix-like にも焼き込まない。
実値はリポジトリ外に置き、リポジトリ内には schema と example だけを置く。実装は
Windows native 用と Unix-like 用の2つだけであり、先に汎用抽象層を作らない。

phase file は冒頭の YAML metadata で実行主体と handoff を明示する。

```yaml
executor: controller
handoff: none
```

- `executor` は phase 本体を実行する role（`controller` または `subject`）
- `handoff` は `none` または `workload`
- subject 作業を含む controller phase は `handoff: workload` と `workload: <path>` を持つ。
  phase 本体へ subject の実装指示を混ぜず、controller は handoff で停止する
- metadata が無い、対象範囲と矛盾する、または対象を OS / instance 名からしか判定できない
  phase は実行しない

subject に渡す実験資料は、release root へ注入済みの variant と逐語の `workload.md` だけである。
variant 正本、`MEASUREMENT.md`、constitution、review は controller に留める。
装置操作 skill `foundation-ops` は controller profile だけに置き、subject profile へ配布しない。

---

## 1. 3軸（混ぜてはならない）

計測は2値ではなく次の3軸で取る。1つの criterion に混ぜない。

| 軸 | 問い | 誰が決めるか |
|---|---|---|
| `loaded` | ルールが文脈に入ったか | **装置が固定で提供する。** 全変種に marker `[<experiment>:<variant>]` を1回出す指示を同梱する。実験ごとに設計しない |
| `obeyed` | 行動が変わったか | **実験ごとに導出する**（§2・§3） |
| `attributable` | ルールが無くても同じ行動をしなかったか | 対照アームの要否。ルール型から決める（§2） |

混ぜてはならない理由: 較正ログ既知の失敗型を区別できなくなる。
「載っていない」（`loaded` が否）と「文言はあるが強制がない」（`loaded` は是、`obeyed` が否）は
別の失敗であり、1つの合否に潰すと比較も改良もできない。
`loaded` が取れなかった回は、ルール本文ではなく**配置を疑う**。その回の `obeyed` は
測定不能として記録する（`REVIEW-CRITERIA.md` §2 の `unknown`）。

`loaded` の観測は marker 文字列の出現の有無だけである。出現場所（transcript、成果物、
ログ行など）は実験の `MEASUREMENT.md` が指名する。装置は「marker を出せ」以外の
`loaded` 判定を足さない。

---

## 2. ルール型 → 証拠クラス

`obeyed` の設計は、変種本文を次のどれかに分類してから始める。複合なら分解し、
型ごとに判定文と証拠を分ける。

| ルール型 | 典型 | `obeyed` の証拠の向き | 対照の要否 |
|---|---|---|---|
| **義務型**「X したら必ず Y」 | GUI 変更後の確認、必実行コマンド | Y が起きたという**正の証拠** | 低（Y が非日常行動なら、変種無しでも Y する先行確率は低い） |
| **禁止型**「X するな」 | ファイル参照フィルター | 違反の**不在**。違反を誘発する workload が別途要る | 高（変種無しでも X しないなら、禁止の効果ではない） |
| **経路型**「X は Z 経由で」 | サブエージェント協働 | Z の呼び出し痕跡 | 中（Z が既定経路なら対照が要る） |
| **様式型**「X はこの形式で」 | 報告形式 | 成果物の形 | 低（形式が変種固有なら） |

この表は証拠の**向き**を決める。具体的な取得手段（どのファイル、どのコマンド）は
実験ごとに指名する。表の「典型」は型を識別するための例であり、その手段を既定にしない。

---

## 3. 証拠クラスと選択規則

強い順。上から試し、取れる最初のクラスを使う。

| クラス | 何か | 強さ |
|---|---|---|
| (a) 成果物の痕跡 | ワークスペースに残ったファイル・行・成果物そのもの | 機械的。人が解釈しなくてよい |
| (b) 実行痕跡 | プロセス・終了コード・コマンド出力など、走った事実 | 半機械的。出力の切り出しは人が行うことがある |
| (c) transcript | セッション記録に書かれた記述 | 人が読む。逐語引用を evidence に残す |
| (d) 否定的観測 | 「起きなかった」 | 最弱。**対照必須** |

**選択規則**

1. (a) が取れるなら (a) を使う。
2. (a) を取るために**対象 repo の変更が要る**なら、その変更自体を別サイクルの実験対象へ
   分離する。同一サイクルで測定器と被測定物を同時に変えない（§4）。
   分離したうえで、当サイクルは取れる範囲のクラスで測る。
3. (a) が取れないなら (b)、それも無理なら (c)。
4. (d) だけで `obeyed` を主張しない。禁止型で (d) に落ちるなら対照アームを必須とし、
   対照でも同じ不在なら `attributable` は否である。

(a) の例として stamp ファイル、固定パスのログ、成果物のハッシュなどがあり得る。
**例であって既定ではない。** ある実験で stamp を選んでも、装置や次の実験の既定にはしない。
transcript 解析も同様で、クラス (c) を選んだ実験の取得元にすぎない。

---

## 4. 比較可能性の不変条件

再計測・改良再実行が意味を持つ条件。1つでも崩れたら**別実験**として扱う
（憲法 不変条件 1）。

比較キーの構成と「1サイクルで変えてよいのは1要素だけ」は憲法 不変条件 1 が定める。
本節はその各要素を、実務でどう固定し、宣言と実状態をどう照合するかを書く。

- **同一 base commit** — 同じ baseline から seed する
- **同一 workload** — `workload.md` の逐語。口頭で言い換えない
- **同一観測定義** — `MEASUREMENT.md` の版が同じ（判定文・取得元・`successCriteria` 案）
- **同一 subject** — アームを触る subject の集合（種別と、各種別の隔離先の中身の識別）が
  同じ。1アームを複数の subject が触ってよい。識別は内容のハッシュで表し、実行しただけで
  変わる値を含めない。**ツールの版はピン留めせず記録する**（憲法 不変条件 9）
- **同一のルール集合** — アームに載る常時適用ルールが宣言と一致する。宣言に無いものが
  載っていたらそのサイクルは比較に使えない（憲法 不変条件 1・8）
- **同一の実験メタ情報の可読性** — アームに存在する実験メタ情報の集合と内容が同じ
  （憲法 不変条件 8(3)。宣言と照合は §8.3）
- **変種1つだけ** — 変えるのは変種のみ。変種はルール本文でもルール群の構成でもよいが、
  配置経路・marker 形式・対象 repo の測定器を同時に変えない

**交絡は除去対象ではなく宣言対象である。** ただし測ろうとしている内容と同種の交絡は
宣言では足りず、除去が要る（対照が既に処置済みになるため）。

なお §2 のルール型の表は変種が**ルール本文**である場合の分類であり、変種がルール群の
**構成**である場合は当てはまらない。その場合の証拠の向きは実験の `MEASUREMENT.md` が
導出する。

**測定器と被測定物を同一サイクルで同時に変えない。**
クラス (a) の取得に対象 repo へのファイル追加や計装が要る場合、その追加は当サイクルの
変種ではない。先に測定器だけを入れるサイクルを回すか、当サイクルでは (b)/(c) で測る。
どちらにするかは実験の `MEASUREMENT.md` が書く。装置は片方を強制しない。

### 4.1 宣言と照合

比較キーは**サイクル宣言**に機械可読で書く。operator は ignored local path
`apparatus/cycles/<cycle>.json` に private declaration を作る。宣言は比較キーだけを持ち、`path` / `instance` /
`generation` のような「今どこに何があるか」の状態は持たない（構成と理由は
[`../apparatus/README.md`](../apparatus/README.md)）。

照合は宣言と実状態の機械突き合わせである。`handoff` はアームを人へ渡す手前で、
`judge` は記録を書く手前で照合し、**1件でも食い違えばその先へ進まず、食い違いを
全件出力して非0で終わる**。実証済みの照合対象は変種正本の tree hash、
`workload.md` / `MEASUREMENT.md` / 判定器の sha256、base commit の一致、
作業ツリーの清浄、config root の状態である。

実行の単位は所属基準で定まるセッションの集合である（`TERMS.md`）。所属基準の正本は
`docs/EXECUTION-UNIT.md`（実行単位規則。実験非依存）であり、宣言はその版を
`executionUnitHash` として持つ。セッションの一覧は宣言に書かない。列挙と所属の確定は
`judge` 時に行う。

**照合が落ちたサイクルを修復して比較へ戻さない。** そのサイクルを比較から外し、
修復はサイクル外の「前提条件を確立する操作」として行う（憲法 §1・不変条件 1）。

---

## 5. 操作の手順（固定 / 再計測 / 改良再実行）

前提: run slot を利用でき、rollback 予定が無いことを確認してから。
`review-init` は一度きり。intent に**変種投入が対象内**であることを書く
（書かないと `minimalChange` が「intent に無い変更」になる）。
判定は controller が行う。subject に判定させない。
公開機構は baseline を対象にした直接書き込みを拒否する。baseline の変更経路は
promote / rollback だけである。

### 5.1 変種の正本と注入

憲法 不変条件 5 は「変種の正本を release worktree の外に置き、毎サイクルそこから
注入する」ことだけを定める。現在の実現は次のとおりで、同じ不変条件を満たす別の
置き場・別の同一性の表し方へ差し替えてよい。

- **正本の位置**: `agent-rules` リポジトリの
  `experiments/<experiment>/variants/<variant>/`。`agent-rules` は
  `rule-experiment-apparatus` の外にあるので、正本は release worktree の外にある
- **正本の単位と同一性**: 正本はファイルではなく**ディレクトリ**であり、同一性は
  git tree hash で表す。宣言の `arms[].variantTree` がこの値を持つ
- **照合**: `apparatus/cycle.py` の `verify_canonical()` が正本と実物を突き合わせる
- **注入**: 毎サイクル、正本からコピーする。**手打ちしない**

### 5.2 共通（どの操作でも）

```
controller prepare: seed run → review-init（intent に変種投入と successCriteria）
  → 注入（正本から。手打ちしない）→ verified handoff → **停止**
human: `workload.md` を逐語で渡し、subject の結果が返るまで待つ
subject: `workload.md` だけを実行
controller post-run review: 観測 → accept → protect → review → promote-dry
```

注入は `Invoke-FoundationRelease.ps1 -Stage inject` だけである。設置先は run の
**release root** `.cursor/rules/` のみ。正本からコピーし、手打ちしない。

```powershell
.\wrapper\Invoke-FoundationRelease.ps1 -Stage inject `
  -Experiment <experiment> -Variant <variant>
```

`state.run` が無い、run が dirty、正本が無い / 正本ディレクトリの外、設置先が
release root `.cursor/rules/` でない場合は拒否する。成功時の commit メッセージは
`experiment-inject-<experiment>-<variant>-<sourceSha256>` で、設置先と正本の
sha256 は一致する。`release-state.json` は書かない。下位スクリプトを直接呼ばない。

`successCriteria` は `MEASUREMENT.md` の案を逐語で `review-init -SuccessCriteria` へ渡す。
全件が review 記入時点で判定可能であること（`REVIEW-CRITERIA.md` §6）。
promote 後の事象を criterion にしない。`criteriaResults[].criterion` は intent と
逐語1:1（`Assert-FoundationReviewRecordShape`）。

結果本体は `private-control/reviews/<release>.json`。
`rule-experiments/<experiment>/runs/` には release 名への索引だけを残す。

### 5.3 固定

固定は検証済みの効果を既定へ入れる操作である。経路は2つあり、互いに独立する。
1サイクルはどちらか一方だけを使う。置き換えない。判別は
`apparatus/cycles/<cycle>.json` の有無である（あれば cycle.py 駆動、無ければ
wrapper 駆動）。

#### 5.3.1 wrapper 駆動サイクル

効果が確認できたときだけ `promote -ConfirmPromote`。
変種が baseline に入り、以後の seed が運ぶ。確認できていなければ promote しない。

#### 5.3.2 cycle.py 駆動サイクル

3段を順に行う。段の順序を入れ替えない。装置に固定のサブコマンドは無い（明文化のみ）。

1. **判定** — `private-control/reviews/<cycle>.json` だけを入力に、§5.3.3 の
   A1–A7 を機械的に評価する。推定記録を入力にしない（不変条件 10）
2. **反映** — 判定が `promoted` のときだけ行う。勝った処置アームの変種正本が表す
   構成を controller の実運用の常時適用ルール集合へ反映し、反映後の実状態を
   次サイクルの対照変種として `agent-rules` へ記録し直す。反映先は変種の
   `placement.json`（無い変種では対照変種 `manifest.json` の `source`）が宣言する
   workspace 相対の常時適用経路である
3. **記録** — `private-control/promotions/<cycle>.json` を書く。
   `not-promoted` でも必ず書く

固定は `base` を動かさない。§5.3.2 は `release-state.json` を書かない。generation も
`transitionHistory` も baseline も物理 instance も触らない。変種は装置リポジトリへ
入らない（不変条件 5）。

「以後は自動的に載るようにする」（憲法 §1）に対応するのは段2である。

#### 5.3.3 受け入れ条件と拒否条件

記号は計測記録から機械的に定まる。`C` は `role == "control"`、`T` は
`role == "treatment"`。比較可能な criterion は両方に存在し `text` が逐語一致する
番号。比較不能はその他（marker の `loaded` はここに落ち、比較の材料にしない）。
効果集合 E は比較可能かつ `T=met` かつ `C≠met`。退行集合 R は比較可能かつ
`C=met` かつ `T≠met`。

A1–A7 を**すべて**満たすときだけ固定する。

| # | 条件 |
|---|---|
| A1 | 記録が存在し、`schemaVersion == 2` かつ `cycle` が対象名と一致する |
| A2 | `role: "control"` と `role: "treatment"` がそれぞれちょうど1つ |
| A3 | 比較不能な criterion が両アームともすべて `met` |
| A4 | 両アームの `criteria` に `unknown` が0件 |
| A5 | \|E\| ≥ 1 |
| A6 | \|R\| = 0 |
| A7 | 宣言 `apparatus/cycles/<cycle>.json` が存在し、両アームの `variantTree` が記録と一致する |

1つでも偽なら固定しない。

- \|E\| = 0 → 無効果。対照も同じ結果なので、結果は変種に帰属しない
- \|R\| ≥ 1 → 退行。効果があっても失ったものがあるなら固定しない
- `unknown` あり → 測定不能
- `treatment` が2つ以上 → A2 で落ちる。証拠から1件を選ばない
- 推定記録を判定の入力に持ち込むこと（不変条件 10）。固定記録の `basis` に
  `reviews/<cycle>.json` 以外を挙げない
- 記録が `--replace` で書き換わり、固定記録の `reviewSha256` と実ファイルが食い違う

#### 5.3.4 固定記録

`private-control/promotions/<cycle>.json`（1サイクル1ファイル）。既存の計測記録
スキーマ・推定記録スキーマは変更しない。固定の可否は計測記録に書かない。
形は17キーちょうどとする。JSON Schema ファイルは置かない。

### 5.4 再計測

promote しない。同じ変種、`workload.md`、`MEASUREMENT.md` で新しい run を seed して
再現性を見る。残っている run は `-Stage discard -ConfirmDiscard` で slot を空ける。
`-SkipReview` promote で空けない。discard は baseline を変えず、旧 workspace と review
記録は残す。再計測の seed は新しい `-Name` を明示する（同じ名前は残留 path で拒否される）。

### 5.5 改良再実行

次の変種を起こす。変種以外（base / workload / 観測定義）を動かしたなら別実験。
観測定義を変える必要がある場合は、それを明示して別実験にする。

---

## 6. 計測仕様の導出

内容が一貫しない任意のルール変更に対し、計測基準はその都度導出する。
導出の入力は変種本文と本節の規則、出力は `MEASUREMENT.md` である。
LLM へ渡す定型は `docs/templates/measurement-brief.md`。
必須項目が1つでも欠けた出力は不合格として差し戻す。

`MEASUREMENT.md` が必ず含むもの:

- 対象変種（experiment / variant / 正本 SHA）
- ルール型（複合なら分解）
- `obeyed` の判定文（review 記入時点で判定可能）
- 証拠の取得元（具体パス。「ログ」ではなくファイル名まで）
- 対照アームの要否と理由
- `successCriteria` 案（逐語。`review-init -SuccessCriteria` へそのまま渡せる形）
- 不採用にした計測案とその理由

`loaded` 用の criterion は装置が固定で足す（marker の出現）。`obeyed` と混ぜない。
`attributable` が対照を要求する型なら、対照の観測も `successCriteria` に含めるか、
当サイクルでは測らない旨を不採用理由に書く。

---

## 7. 推定の設計（再計測が非現実的なとき）

憲法 §1 の第4の操作「推定」の選び方。対象は、**逐語の `workload.md` は存在するが
再実行が非現実的な場合だけ**である。逐語 workload が無い一回性の
作業と、照合が落ちたサイクルの救済は対象外。

機構（凍結入力の束ね方・推定記録スキーマ・較正）は `apparatus/cycle.py` の
`freeze`・`estimate`・`calibrate` サブコマンドで実装済みである。形の正本は
`apparatus/schemas/frozen-input.schema.json`・`estimator.schema.json`・
`estimation-record.schema.json`・`calibration-record.schema.json` にある。

本節は**選び方**の文書である。特定の推定器（LLM・統計・ヒューリスティック）
を既定にしない（憲法 不変条件 2・10）。推定の結果は本計測（対照アームつきサイクル）
の対象選定（triage）にのみ使い、固定の根拠にしない。

### 7.1 推定が埋める軸

3軸のうち推定に頼るのは `attributable` だけである。観測できる軸を推定器へ
丸投げしない。

| 軸 | 巨大 workload の1実行では |
|---|---|
| `loaded` | marker の出現で従来どおり**観測**する。推定しない |
| `obeyed` | 1実行分の痕跡（§3 の証拠クラス）から従来どおり**観測**する。推定しない |
| `attributable` | 対照アームが無い。「変種が無くても同じ行動をしたか」の反事実を**推定**する |

再計測が担っていた再現性の主張（1実行の結果がどれだけ偶然か）も推定の対象になる。

### 7.2 凍結入力

推定器が読んでよいのは凍結入力だけである。凍結入力は次の束で、束全体を hash で
識別する。

- 参加セッションの transcript
- アームに残った成果物（対象の commit 範囲を明示する）
- 宣言（`apparatus/cycles/<cycle>.json`）
- 変種正本の tree hash と `workload.md` の sha256
- **計測仕様（`MEASUREMENT.md`）。** メンバー id は `measurement`。束の top-level に
  `measurementSha256` を置く。推定器が計測と同じ述語（結果水準の `attributable`）を
  答えるために必要である
- subject の種別と版

`/reviews/`（計測結果）・`/judge/`（判定器実装）・`baseline-` は凍結入力に入れない。
計測仕様として加えるのは `MEASUREMENT.md` だけである。

凍結後の追記・差し替えは**新しい凍結入力**である。推定のやり直しは、同じ凍結入力へ
別の推定器を当てることであって、入力を差し替えて同じ推定器を当てることではない。
workload の再現性が失われても、この凍結によって**推定の再現性**を担保する
（憲法 不変条件 10）。

### 7.3 推定器 interface

- **入力**: 凍結入力（§7.2）だけ。アームの現在状態、controller の記憶、他サイクルの
  痕跡を読ませない
- **出力**: 推定値（`attributable` の見立て）、確信度、根拠（凍結入力のどこを
  読んだか）、不採用にした解釈
- **推定記録に必ず残すもの**: 推定器の identity（sha256。LLM なら model と prompt の
  版）、凍結入力の hash、較正の参照（どの較正で使用可になったか）

推定記録は計測記録（`schemaVersion: 2` のサイクル記録）と別置する。計測記録の
スキーマへ推定のキーを足さない。

### 7.4 較正

推定器は較正してから使う（憲法 §1 の前提条件を確立する操作・不変条件 10）。

1. 正解データは過去の**計測済み**サイクル（対照アームがあり、記録が有効なもの）
2. 片アームの痕跡だけを凍結入力の形に束ね、計測結果を伏せて推定器へ渡す
3. 推定と計測結果を突き合わせ、一致・不一致を較正の記録として残す
4. 較正は実験サイクル中に行わない

**較正源の集合**は、凍結可能な計測済みアームである。`materialized.json` が無く凍結
できないサイクルは較正源にしない。

較正が1件も無い推定器は使えない。当該 identity の較正に mismatch が1件でもあれば
使えない。**合格条件は 0 mismatch** である。一致率の閾値は置かない。

較正が確立するのは **specificity（偽陽性を出さないこと）だけ**である。検出力は
未確立。`not-attributable` / `indeterminate` の推定は「効果が無い」ではなく「不明」
であり、**陰性は triage の根拠にしない**（変種を落とさない）。

未較正の推定器の null 推定は「効果が無かった」のか「推定器が見つけられなかった」
のか区別できない（不変条件 4 の `proven` と同じ構造）。

### 7.5 推定サイクルの宣言

対照アームを置かず推定だけを回すとき、宣言に `kind: "estimation"` を書く。
欠落は `measurement`（従来の計測サイクル）とみなす。

- arms はちょうど1件（対照が無い）
- `judgeHash` は不要（1アームでは判定器が構造的に走らない）
- `judge` は拒否される

推定の結果は triage の入力であり、本計測（対照アームつきサイクル）の代替ではない
（§7 冒頭・不変条件 10）。

---

## 8. 配置経路の実証と subject identity

憲法 不変条件 4 と 9、および 8(3) を成立させる具体的な方法。原則（未実証の配置経路に
置かない、identity は内容のハッシュで表す、版はピン留めせず記録する、可読性は宣言する）
は憲法にあり、本節はその実現である。

### 8.1 配置経路の実証

新しい subject は `proven: false` から始まる。実証は次の手順で行う。実験サイクル中に
行わない（憲法 §1 の「前提条件を確立する操作」）。

1. marker だけを載せた変種を、候補の配置経路へ置く
2. subject を通常どおり起動し、`workload.md` を実行させる
3. marker `[<experiment>:<variant>]` が実際に出たことを確認する。**subject 自身の
   申告（`status` 等）を根拠にしない**
4. 出た経路だけを実証済みとして記録し、出なかった経路は候補のまま残す

marker が出なかったときは、**ルール本文ではなく配置を疑う**（§1）。その回の
`obeyed` は測定不能として記録する（`REVIEW-CRITERIA.md` §2 の `unknown`）。

**実証済み配置経路の保持形式**: 憲法が要求するのは「装置が subject ごとに実証済みの
集合を持ち、その集合以外へ置かないこと」だけである。設計上の置き場は
`apparatus/subjects/<subject>.json`（1 subject 1 ファイル。版管理下）である。
記述子が持つのは隔離手段、実証済み配置経路、空に保つ経路、transcript の所在、
アーム束縛の導き方、参加判定の形式、`proven` である。実ユーザー名・実絶対パスは書かない。
記述子はデータの表であり、subject を足す作業は表への追加と経路実証である。
5つ目を足すときにコードの拡張点を作り始めない。未実証の欄は推測で埋めず、明示的に
未確認として残す。現時点の配置経路は変種正本 `placement.json` と判定器の定数に
分かれて置かれている。

有効な配置経路が複数ある subject では、使う1つを決め、残りを空に保つ。現在の実現は
`placement.json` の `mustStayEmpty` と、変種 manifest の `absentPaths`（記録時に
存在しなかった経路）である。

### 8.2 subject identity と handoff の照合

identity は内容のハッシュで表し、実行しただけで変わる値（mtime など）を含めない
（憲法 不変条件 9）。現在 subject を識別するのは、宣言の `subject`（種別と隔離先）と
`sessionContractHash`（config root へ置く `CLAUDE.md` の正本の sha256）である。

**ツールの版はピン留めせず、アーム開始時に記録する。** `handoff` は candidate 内で
版を実測し、宣言の `subject` の隣へ `subjectVersion` として書き戻す。**宣言と違っても
止めない**（版は比較キーの照合対象ではなく、再計測が一致しなかったときの候補を
残すための記録である）。

`handoff` は subject を起動する手前で止まり、比較条件の照合だけを行う。照合対象と
処理順は [`../apparatus/README.md`](../apparatus/README.md) の「`handoff` は何をするか」。
起動と workload の実行は人が行い、装置は workload や prompt を自動送信しない。

### 8.3 実験メタ情報の可読性宣言

憲法 不変条件 8(3) は、装置自身を被験体にするサイクルでは 8(2) を守れない場合に、
憲法可読を交絡として宣言し、比較キーに含め、同じ宣言を持つサイクル同士でのみ比較する
ことを定める。禁じているのはファイルの存在ではなく、**宣言されていない可読性**である
（憲法 不変条件 1・8）。

アームに存在する実験メタ情報の集合と内容を宣言し、`handoff` で照合する。対象は少なくとも
`CONSTITUTION.md` / `TERMS.md` / `docs/RULE-EXPERIMENT.md` /
`docs/CYCLE-RECORD-CRITERIA.md` / `apparatus/cycles/*.json` / `apparatus/schemas/*`
である。同一性は内容から決まる識別子で表し、実行しただけで変わる値を含めない。
宣言の版は `metaReadabilityHash` として持つ。
