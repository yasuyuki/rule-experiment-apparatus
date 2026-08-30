# Protocol and records

## Declaration

`apparatus/schemas/cycle.schema.json` は measurement cycle だけを許します。宣言は control と
treatment の2 arm、同じ base、workload、evaluation、subject list と、arm ごとの variant Git
tree / managed SHA-256 を持ちます。`cycle.py` は source の current bytes と宣言を照合します。

任意の `materials` は、workload が base の外に読む必要のある tree を name / repository /
commit で宣言します。arm ごとではなく cycle に1度宣言するので、両 arm が同じ bytes を
見ることは構造上成立し、Invariant 1 を弱めません。`materialize` は pinned commit を
`<release>/materials/<name>` へ clone します。arm workspace の外側なので arm の diff には
入らず、workload からは `../materials/<name>` で届きます。`review` は収集前に各 material が
pinned commit のまま clean であることを再検査し、fingerprint を review record へ固定します。

この field が必要なのは、次の cycle の計画作成のように、過去の control record や apparatus
の docs を読まなければ成立しない workload があるからです。base の1 repository だけでは
その workload を宣言できません。

## Subject descriptor

`apparatus/schemas/subject.schema.json` は protocol version、adapter entrypoint / SHA-256、opaque
profile reference だけを持ちます。CLI 固有 field を core schema に追加しません。新しい CLI は
descriptor、adapter、adapter 固有 test を追加し、`cycle.py` を変更せず導入します。

Adapter は JSON を stdin で受け、JSON だけを stdout へ返します。

### `prepare`

入力は cycle / arm、workspace、config root、variant path / digest、workload path / digest、
宣言された material の name / path、opaque profile です。応答は adapter identity、subject version、config identity、配置先と配置後 digest、
launch 情報、`collect` に返す opaque token です。応答形式は
`apparatus/schemas/adapter-prepare.schema.json` が定めます。

### `collect`

入力は cycle / arm、workspace、opaque profile、`prepare` token です。応答は実行成否、rule
読み込み成否、sanitized evidence reference です。応答形式は
`apparatus/schemas/adapter-collect.schema.json` が定めます。

Core は adapter 応答の内容を公開記録に複製しません。`prepare` と `collect` の canonical JSON
digest、adapter identity だけを review に取り込み、一時 state を削除します。

## Evaluation and review

固定 evaluation program は `evaluate` 引数と JSON stdin を受け、arm ごとの同一 criteria を
返します。各 criterion は number、逐語 text、`met` / `not-met` / `unknown`、sanitized evidence
reference を持ちます。Treatment の改善が1件以上あり、regression と unknown が無い場合だけ
review verdict は `promote` です。

`apparatus/schemas/review.schema.json` は declaration digest、base commit、workload / evaluation
digest、両 arm の variant identity、adapter identity / response digest、criteria、verdict、採用対象
treatment digest を1件に固定します。

## Baseline transition

`promote` は review digest、declaration digest、variant Git tree、現在の treatment managed digest、
stable branch / clean state を mutation 前に照合します。成功時は detached worktree で renderer と
stable test を通し、fast-forward します。`rollback` は最新 promotion commit が stable HEAD の
場合だけその commit を revert し、直前の managed digest を照合します。
