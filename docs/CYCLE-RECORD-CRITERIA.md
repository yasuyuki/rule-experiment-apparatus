# サイクル記録の記入基準（`schemaVersion: 2`）

この文書が定めるのは、`schemaVersion: 2` のサイクル記録
（`private-control/reviews/<cycle>.json`）だけです。書き手は `apparatus/cycle.py judge`
であり、記入する主体は controller です。

`schemaVersion: 1` のレリーズ review は別種の記録です。その記入基準は
[`REVIEW-CRITERIA.md`](REVIEW-CRITERIA.md) にあり、この文書は置き換えません。用語は
[`TERMS.md`](../TERMS.md)（正規用語の正本）に従います。判定文の正本は
実験ごとの計測仕様（`MEASUREMENT.md` §6）であって、この文書ではありません。

## 1. 形の正本はスキーマである

**形（必須キー・型・enum・値域）の唯一の正本は
`apparatus/schemas/cycle-record.schema.json` です。** この文書は意味と記入規約を持ちます。
形の規則をこの文書へ書き写しません。書き写した時点で二重実装になり、黙って乖離します。

**JSON Schema で書けない条件は `cycle.py` の `validate_record()` が持ちます。**
分担は重複ではなく排他です。ここに現行の記録の項目に効く条件を示します。

| 条件 | 持ち主 |
| --- | --- |
| 必須キー・型・`schemaVersion == 2` | スキーマ |
| `subject` / `subjectVersion` が非空 | スキーマ |
| `criteria[].criterion` が 1..N に過不足なく1回ずつ | `validate_record()`（件数 N は実験ごと。スキーマは 1 件以上の配列だけを縛る） |
| `result` の3値 | スキーマ |
| `arms[].id` の一意性 | `validate_record()` |
| `judgeSha256` が全アームで一致 | `validate_record()` |
| `workloadSha256` が全アームで一致 | `validate_record()` |
| `criterion` 2–6 の `text` が全アームで逐語一致 | `validate_record()` |
| `baselineRecordedAt` が `recordedAt` より前 | `validate_record()` |
| `transcript` が `transcriptsDiscovered` に含まれる | `validate_record()` |
| 記録の sha256 が宣言（`apparatus/cycles/<cycle>.json`）の hash と一致 | `validate_record()` |

記録に項目を増やすときは、**増やすフェーズが同じフェーズでスキーマも更新します。**
スキーマを変更してよいフェーズが限られているという規則ではありません。不変なのは
「形の規則はスキーマにしか書かない」ことです。

## 2. 記録の同一性と上書き

- **同一性キーは `cycle` です。1サイクル1記録を維持します。** 版は `private-control` の
  git 履歴が持ちます。判定器を直して再判定するたびに記録が増えることはありません。
- **既存記録の上書きは `--replace` の明示を要求します。** 指定が無ければ書かずに落ちます。
- **`schemaVersion` が 2 でない既存記録は、`--replace` を付けても上書きしません。**
  1サイクル1記録は `schemaVersion: 2` の記録の中での規則です。同名の `schemaVersion: 1` の
  レリーズ review は別種の記録が名前で衝突しただけであり、取り違えて潰すと復旧が
  git 履歴頼みになります。

## 3. トップレベルの項目

すべて必須です。

| キー | 意味 |
| --- | --- |
| `schemaVersion` | 記録の形の版。この文書が扱うのは `2` です |
| `cycle` | サイクル識別子。記録の同一性キー（§2）で、宣言 `apparatus/cycles/<cycle>.json` と同じ値です |
| `experiment` | 実験識別子。変種正本と計測仕様の置き場を決めます |
| `recordedAt` | 記録を書いた時刻。オフセット付きの ISO 8601 |
| `subject` | この実験で走らせた subject の種別 |
| `subjectVersion` | その subject の版。空にしません（憲法の不変条件 9 が版の記録を要求しています） |
| `baseCommit` | 全アームの共有 base の commit。アーム間の差が変種だけであることの起点です |
| `measurementSha256` | 判定時点の計測仕様（`MEASUREMENT.md`）の sha256 |
| `arms` | アームの配列。2件以上 |

## 4. `arms[]` の項目

すべて必須です。

| キー | 意味 |
| --- | --- |
| `id` | アーム識別子。宣言の `arms[].id` と同じ値で、記録の中で一意です |
| `role` | `control` は対照アーム。それ以外の比較条件は `treatment` |
| `variant` | このアームへ注入した変種の名前 |
| `variantTree` | その変種正本の tree hash |
| `variantInjectionCommit` | `materialize` が `<release>/materialized.json` に書いた `injectionCommit`。handoff / judge が宣言の `variantTree` とアーム HEAD の祖先関係を照合した証拠として、judge が記録へ写す |
| `armCommit` | 判定時点のアームの commit |
| `transcript` | 現行の判定器へ渡した参加セッション1件の絶対パス。参加が1件のときだけ埋まます。`transcriptsDiscovered` に含まれます |
| `transcriptsDiscovered` | config root で発見した全 transcript の絶対パス。1件以上。選ばなかったものも残します |
| `sessions` | 任意。発見した各セッションの tool / path / span / assistantCount / 所属。既存記録（001/002）には無い |
| `baselinePath` | `judge` が判定器の `--baseline` へ実際に渡した baseline manifest の絶対パス（distro 内） |
| `baselineSha256` | その baseline manifest の sha256。distro 内で採取します |
| `baselineRecordedAt` | その baseline manifest の mtime（distro 内）。オフセット付き ISO 8601 で、`recordedAt` より前です |
| `workloadSha256` | 判定器が読んだ `workload.md` の sha256 |
| `judgeSha256` | 判定を行った判定器自身の sha256 |
| `judgeExitCode` | 判定器の終了コード。`0` は全 `criterion` が `met`、`1` は `met` でないものがあることを表します |
| `criteria` | 計測結果。6件（§5） |

## 5. `criteria[]` の項目

`criterion` 1..6 が過不足なく1回ずつ、この順で並びます。各要素はすべて必須です。

| キー | 意味 |
| --- | --- |
| `criterion` | 計測定義の番号。計測仕様 `MEASUREMENT.md` §6 の行番号と 1:1 で対応します |
| `text` | その番号の判定文。判定器が出力した文字列そのままです |
| `result` | `met` / `not-met` / `unknown` の3値 |
| `evidence` | その `result` の根拠 |

## 6. 記入規約

- **判定結果を丸めません。** `not-met` を `met` にせず、`unknown` を潰しません。
  `unknown` は必要な証拠を取得できなかったことを表します。「まだ確認していない」は
  該当しません。
- **`evidence` には、判定器が実際に読んだ出力・ファイル・数値だけを書きます。**
  推測、見込み、次にやることを書きません。
- **`criteria[].text` は判定器の出力そのままです。controller が書き換えません。**
  判定文の正本は計測仕様 `MEASUREMENT.md` §6 であり、この記録でも、この文書でも
  ありません。判定文を変えるときは正本を変えて再判定します。
- **記録は判定器が出した結果の写しです。** controller が独自に足す判断を書きません。

## 7. 比較の不変条件

次が1つでも崩れた記録は、**比較として無効**です。結果の良し悪し以前に、
アーム間で何が同一だったかが言えなくなります。

- `judgeSha256` は全アームで一致し、宣言の `judgeHash` とも一致します
- `workloadSha256` は全アームで一致し、宣言の `workloadHash` とも一致します
- `measurementSha256` は宣言の `measurementHash` と一致します
- `criterion` 2–6 の `text` は全アームで逐語一致します
- `criterion` 1 の `text` だけはアーム間で異なります。marker `[<experiment>:<variant>]` が
  変種を識別する以上避けられず、計測仕様 `MEASUREMENT.md` §6 がそう定めています
- 記録を書く前に、装置は実行の単位を照合します（次節）

このうちアーム間の一致とフィールド間の比較はスキーマで書けません。§1 のとおり
`validate_record()` が持ちます。

## 8. 実行の単位の照合

装置は transcript を選びません。記録を書く前に次を照合し、収まらなければ記録を
書かずに拒否します。丸めて1件にしません。正本は [`EXECUTION-UNIT.md`](EXECUTION-UNIT.md)
です。宣言はその版を `executionUnitHash` として持ちます。

**参加セッション**は、subject が実際に何かを実行したセッションです。起動しただけの
ものは含みません。判定形式は subject 記述子が持ちます。marker の数え方は判定器の
仕事であり、装置は持ちません。

**照合A′（実行の単位）** — 発見した各セッションを所属／非所属へ確定します。
所属を確定できないセッション、このアームの config root にあるのにこのアームへ
束縛されないセッション、参加セッション 0 件は拒否します。件数の上限は設けません。

**照合B′（観測されていない主体）** — 注入 commit 以降のアームの全 commit の
author time が、所属する参加セッション集合の span の和（最早から最遅、境界は閉じる）
に内包されます。外れた commit があれば拒否します。参加セッションに `timestamp`
を持つ行が1つも無い場合は span を作れないので拒否します。

記録の `transcriptsDiscovered` は発見した全件、`sessions[]` は各セッションの
所属確定結果です。選ばなかったものを記録から消しません。`transcript`（単数）は
現行の判定器が1件を取るためのスロットであり、参加セッションが1件のときだけ埋めます。

## 9. この記録が答えない問い

サイクル記録は**計測ログ**です。次はこの記録の対象外であり、キーも存在しません。

- **`verdict`** — アームを baseline へ反映してよいかの判断
- **promote の可否** — 状態遷移の判断。この記録とは無関係です。所在は経路で分かれる。
  wrapper 駆動サイクル（`apparatus/cycles/<cycle>.json` が無い）は
  `private-control/release-state.json`。cycle.py 駆動サイクル（同宣言がある）は
  `private-control/promotions/<cycle>.json`
- **`procedure`** — サイクルの進め方の良し悪し

この記録が答えるのは「宣言どおりの2アームに、同一の workload と同一の判定器を当てた結果は
何だったか」だけです。装置や基準の改善案は operator の issue tracker へ書きます。
