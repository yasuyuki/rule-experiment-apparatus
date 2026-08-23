# apparatus

## これは何であって何でないか

`cycle.py materialize` は、比較キーだけを持つサイクル宣言1本を読み、candidate
（環境記述子の `host` / `distro` / `user`。実値はリポジトリ外）上に**同一 base
の2アーム**（`arm-v1` 対照・`arm-v2` 実験）を立てる。これだけをやる。

これは**汎用の環境 primitive 層でも subject plugin 機構でもない。** `read` /
`write` / `digest` / `processes` / `kill` / `launch` は実装していない
（下記「実装していない primitive」参照）。`wrapper/` の置き換えでもない。
`wrapper/` はそのまま動いており、`materialize` は宣言された base と変種だけを
材料化する。
subject product の実体化と判定器の実行（`judge.py judge`）は範囲外。marker 配置と
baseline manifest の取得は `cycle.py handoff` が担う（下記「`handoff` は何を
するか」参照）。

## 記述子（subject / environment）

subject 固有の値（隔離 env・binary・config root の置き方・transcript glob 等）は
`subjects/<id>.json` のデータ表から読む。コードに subject id の if 分岐を足さない。
subject を追加するときは JSON を1ファイル追加し、経路を実証してから値を埋める。

`transcripts.participation` は単一 predicate（`{jsonlField, equals}`、`jsonlField`
はドット区切りで入れ子を辿れる）、複数 predicate の AND（`{"all": [predicate, ...]}`）、
または `null` を取る。`transcripts.searchRoot` は列挙の起点ディレクトリを選ぶ
（既定 `config-root` はアームの cfg-<variant> 配下、`home-cursor` は cursor-agent
のように transcript が cfg 配下の外、distro の `$HOME/.cursor` 配下に置かれる
subject 用）。

環境記述子は repo 内に schema と example（`schemas/environment.schema.json` /
`schemas/environment.example.json`）だけを置く。実値は private control root の
`apparatus-environment.json`（本リポジトリの版管理外）。`--environment <path>` を
指定すると、その記述子の親が control root になり、`agentRulesRoot` は記述子からの
相対パスまたは絶対パスとして解決される。したがって apparatus と agent-rules は
sibling でなくてよい。オプションを省く旧来の sibling 配置は移行用にだけ維持する。
WSL の `<distro>` / `<wsl-user>` はコード定数ではない。

実行の単位（参加・所属・span の和）の正本は `docs/EXECUTION-UNIT.md` であり、
宣言はその raw bytes の sha256 を `executionUnitHash` として pin する。照合は
`collect_execution_mismatches`（A′/B′）が行い、件数上限は無い。

宣言の `subject` は文字列または配列。

## 宣言の読み方

`cycles/<cycle>.json` は比較キーだけを持つ。operator はこの ignored local path に
private declaration を作る。宣言は public tree へ commit しない。

| キー | 意味 |
|---|---|
| `cycle` | サイクル識別子。`~/releases/<cycle>` の実体化先を兼ねる |
| `experiment` | 変種正本のあるディレクトリ（`agent-rules/experiments/<experiment>`） |
| `subject` | この実験で走らせる subject（文字列または id 配列） |
| `workloadHash` | `workload.md` の sha256 |
| `measurementHash` | `MEASUREMENT.md` の sha256 |
| `judgeHash` | `judge/judge.py` の sha256 |
| `arms[].id` / `role` / `variant` / `variantTree` | アームの識別子、control/treatment、変種名、正本 tree hash |
| `base` | 任意。`{repo, commit}`。`materialize` では必須。`repo` は装置親ディレクトリの basename |
| `readableMeta` / `metaReadabilityHash` | 任意。不変条件 8(3) の可読性宣言。キーが無い宣言は照合をスキップ |

`name` / `instance` / `path` / `gitRef` / `generation` / `transitionHistory`
は宣言に**入れない**。これらは「今どこに何が置かれているか」という状態で
あって、比較キーではない。宣言に混ぜると、実体化のたびに宣言ファイルへ
書き戻す必要が生まれ、サイクル宣言が状態管理を兼ねてしまう。`path` は
`cycle.py` 側の定数（`~/releases/{cycle}`）として持ち、宣言からは導出しない。
`instance` を持たないのは、両アームを同一の物理 candidate 上に置くという
制約（instance を増やさない）を宣言の語彙からも外すため。

`materialize` の base は空リポジトリではなく、宣言の `base.commit` で
detach checkout した実リポジトリ clone である。注入先に既存ファイルがあり
内容の sha256 が違う場合は上書きせず mismatch で止まる。

## `workloadHash` / `measurementHash` / `judgeHash` / `subject` をサイクル直下に置く理由

これらは**1サイクルにつき1つ**の値である。1サイクルは「同じワークロードを
同じ判定器で測る」ことの単位であり、アームごとに workload や判定器が
違えば、それはもう同じサイクルではない。アーム直下に重複して持たせると
「アーム間で値が食い違う」という本来あってはならない状態が構造上
表現できてしまう。サイクル直下に1回だけ置くことで、その不正な状態を
構造で禁じている。

## v2 アームへ `reconciliation.md` / `controller.md` を入れない理由

`materialize` は各アームを `decl["arms"]` 順に処理する。変種ディレクトリに
`manifest.json` があればそこから注入し、無ければ正本の
`bin` / `rules` / `placement.json` / `README.md` をコピーする（`VARIANT_COPY_ITEMS`）。
後者で `bin/rules.py` があれば `render` する。
`README.md` は構造と使い方だけを書き、測定に言及しない。`reconciliation.md` と
`controller.md` は差分と測定への影響を書くのでアームへ入れない。
これを入れると、subject がアーム内のファイルを読むだけで測定の存在自体を
推測できてしまい、憲法の不変条件 3 に反する。

## `handoff` は何をするか

`cycle.py handoff` は `materialize` 済みのサイクルに対し、subject を起動する
**手前**までを装置が構成し、比較条件の検証だけを行う。subject の起動と
workload の実行は行わない。人が起動コマンドをコピーして実行する。

処理順は次のとおりで、比較キーの照合に1つでも落ちたら以降を行わず exit
非0にする（食い違いは1件で止めず全件集めて出力する）:

1. 宣言の比較キー（`variantTree` / `workloadHash` / `measurementHash` /
   `judgeHash`）と実物が一致すること、base commit が base/両アームの3つで
   揃っていること、両アームの作業ツリーが汚れておらず、base の上の commit が
   variant 注入の1つだけであること、config root に transcript がまだ無い
   ことを照合する
2. subject 記述子の `versionCommand` を candidate 内で実測し、宣言 JSON の
   `subject` の隣へ `subjectVersion` として書き戻す（版は pin しない。宣言と
   違っても止めない）
3. `~/releases/<cycle>/cfg-<variant>/` をアームごとに作り直す
   （常時適用ファイル・空 rules ディレクトリ・資格情報のコピー先は subject
   記述子の `configRoot`。session contract 本文は marker 文字列だけが違う
   1つのテンプレート）
4. `judge.py baseline` を両アームへ適用し、`~/releases/<cycle>/baseline-<arm>.json`
   （アームの外）へ manifest を出力する
5. 2アーム分の起動コマンド（記述子の isolation env と binary、環境記述子の
   `<distro>` / `<wsl-user>`）を表示して終了する

## `judge` は何をするか

`cycle.py judge` は `handoff` 後、subject が両アームで workload を実行して
返ったサイクルに対し、判定器（`judge/judge.py`）を**両アームへ同一の引数形で
適用し**、記録を `private-control/reviews/<cycle>.json` へ書く。アームの
中身は一切変更しない。

処理順は次のとおりで、1つでも照合に落ちたら記録を書かず exit 非0にする
（食い違いは1件で止めず全件集めて出力する）:

1. 正本 `judge/judge.py` / `workload.md` / `MEASUREMENT.md` の sha256 が
   宣言の `judgeHash` / `workloadHash` / `measurementHash` と一致することを
   照合する
2. アームごとに `~/releases/<cycle>/cfg-<variant>/` 配下を subjects/ 全記述子の
   `transcripts.glob` で列挙し、照合A′/B′（`docs/EXECUTION-UNIT.md`）を適用する。
   現行の `judge.py` は transcript 1件なので、所属する参加セッションが1件のとき
   だけそれを渡す（複数 transcript の集約は未実装）
3. `judge.py judge --arm <アーム> --workload <workload.md> --variant <v1|v2>
   --transcript <2で特定した jsonl> --baseline <handoff で撮った baseline
   manifest>` を両アームへ同一の形で（`--variant` だけ違う）適用する。判定が
   全 met でなければ判定器は exit 1 を返すが、これは正当な計測結果であって
   infra 失敗ではない。exit code が 0/1 以外の場合だけ infra 失敗として
   即座に exit 非0にする
4. 両アームが報告した `judgeSha256` どうし、および宣言の `judgeHash` が一致
   すること（`workloadSha256` も同様）を照合する。`criteria` が 1..N 過不足なく
   1回ずつであることは `validate_record()` が持つ

すべて通れば `schemaVersion: 2` の記録を書く。既存の `schemaVersion: 1` の
記録（単一 release 向け）は2アーム分を載せられないため、`judge` はこの新しい
schemaVersion 専用で、既存の記録には触れない。記録は判定器の出力
（`criteria` / `workloadSha256` / `judgeSha256`）をそのまま保持する。
`not-met` を丸めない、`unknown` を `met` にしない。

判定器はアームの外（`../../../agent-rules/experiments/<experiment>/judge/`）
から適用する。**v2 同梱の `bin/rules.py verify` を判定に使わない** — それは
subject が使うための道具であり、判定器として使うと2アームが異なる手段で
測られることになる。

## `freeze` は何をするか

`cycle.py freeze --cycle <name> --arm <arm-id>` はサイクル実行後、指定アームの
凍結入力を束ねて content-addressed で識別する。凍結入力は宣言、workload、変種注入 diff、
実行 diff、参加 transcript を含む。同じ内容なら同じ hash を再利用し、書き込み後は
読み取り専用にする。凍結は推定の再現性を担保する前提条件である。

## `estimate` は何をするか

`cycle.py estimate --frozen <hash> --estimator <id> --input <path>` は較正済みの
推定器の出力を `private-control/estimations/<cycle>.json` へ記録する。
推定記録は計測記録（`reviews/<cycle>.json`）と別置し、推定器の identity と
凍結入力の hash を保持する。推定値は triage 専用であり、固定の根拠にしない。

## `calibrate` は何をするか

`cycle.py calibrate --cycle <name> --arm <arm-id> --estimator <id> (--prepare|--input <path>)` は
計測済みサイクルの片アームから較正記録を作る。`--prepare` フラグは凍結と正解データ
導出可否を確認するだけで計測結果は出力しない。較正は実験サイクル中に行わず、
推定器の使用可否を確立する前提条件である。

## 実装していない primitive

`read` / `write` / `digest` / `processes` / `kill` / `launch` は実装して
いない。環境操作は `exec_()` 1つに閉じており、アーム内のファイル操作は
すべて `exec_()` 経由で distro 内から行っている。これらの primitive は、
`materialize` 以外の操作（アームの中身を個別に読む、プロセスを見る・
落とす、subject を起動する等）が要るようになった時点で、そのときの
必要に合わせて追加する。

## 実行例

記録の検証に `jsonschema` を使う。初回だけ `python -m pip install -r requirements.txt` を実行する（版は `requirements.txt` にピン留めしてある）。

```
python cycle.py --environment <private-control>/apparatus-environment.json materialize --cycle <cycle>
python cycle.py --environment <private-control>/apparatus-environment.json handoff --cycle <cycle>
python cycle.py --environment <private-control>/apparatus-environment.json judge --cycle <cycle>
```

サイクル宣言と変種資産は operator が private control と rule source に用意する。
この public tree は実環境の宣言や過去サイクルを同梱しない。`materialize` の2回目の実行は
`~/releases/<cycle>` が既に存在する
ため拒否され、既存のアームを上書きしない（exit 非0）。

**`handoff` の再実行は subject を起動する前に限る。** 再実行のたびに config root
を `rm -rf` して作り直し、baseline manifest も撮り直す。アームに variant 注入
以外の commit があると（workload 実行後に subject が commit した状態）、
baseline の撮り直しを拒否する。`$CFG/projects/` に transcript があると
config root の作り直しを拒否する（`loaded` の唯一の証拠を消さない）。

## 固定は cycle.py の操作ではない

固定のサブコマンドは無い。判定規則と記録の形は `docs/RULE-EXPERIMENT.md`
§5.3.2〜§5.3.4。判定の入力は `reviews/<cycle>.json` だけである。
`release-state.json` を書かない。`base` を動かさない。判断は
`private-control/promotions/<cycle>.json` に残す（`not-promoted` でも書く）。
