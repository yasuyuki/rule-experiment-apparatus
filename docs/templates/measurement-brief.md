# 計測仕様ブリーフ（LLM へ渡す定型）

ルール変種の本文から `MEASUREMENT.md` を埋めるときに使う。
装置の選び方は [`docs/RULE-EXPERIMENT.md`](../RULE-EXPERIMENT.md)。
記入規約は [`docs/REVIEW-CRITERIA.md`](../REVIEW-CRITERIA.md) §6。

このブリーフの出力は **7項目すべて必須**である。
**1つでも欠けたら不合格として差し戻す。** 欠けた項目を推測で埋めない。
差し戻し後、欠けた項目だけを再提出させる。

計測手段を1つに決めつけて書かない。stamp・transcript 解析・特定ログ形式などは
候補になり得る**例**であり、このブリーフが既定として指定するものではない。

---

## 入力（渡す側が埋める）

- experiment:
- variant:
- 変種本文のパス: `rule-experiments/<experiment>/variants/<variant>.mdc`
- 変種本文（全文、または上記パスを読ませた旨）:
- 正本 SHA（未コミットなら `git hash-object` の値、または「未記録」）:
- 対象 repo / 作業の種類（分かる範囲）:

---

## 守ること（出力側）

- 3軸を混ぜない。`loaded` / `obeyed` / `attributable` を1つの判定文にしない
- `loaded` は装置が固定提供する marker `[<experiment>:<variant>]` の出現だけ。
  別の `loaded` 判定を発明しない
- `obeyed` の判定文と `successCriteria` の全件は、**review 記入時点で判定可能**であること。
  promote 後の事象（「promote が完走する」等）を入れない
- 証拠の取得元は具体パスまたは具体コマンド出力名。「ログ」「transcript」だけでは不合格
- クラス (a) の取得に対象 repo の変更が要るなら、その変更を当サイクルに混ぜないと書く。
  測定器と被測定物を同時に変えない
- ルール型が複合なら分解する
- `successCriteria` 案は `review-init -SuccessCriteria` へそのまま渡せる文字列の列。
  `criteriaResults[].criterion` と逐語1:1になる

---

## 出力必須項目（7。欠けたら差し戻し）

次の見出しで出力する。見出し名を変えない。

### 1. 対象変種

- experiment:
- variant:
- 正本 SHA:
- 正本パス:

### 2. ルール型

義務型 / 禁止型 / 経路型 / 様式型 のいずれか。複合なら分解して型ごとに行を分ける。

### 3. `obeyed` の判定文

review 記入時点で yes/no（または `met`/`unmet`/`unknown`）が付く文。
`loaded` をここに書かない。

### 4. 証拠の取得元

具体名。例が必要なら「どのパスのどのファイルを見るか」まで書く。
クラス (a)/(b)/(c)/(d) のどれを選んだかと、その選択規則上の理由を1行で添える。

### 5. 対照アームの要否と理由

要 / 否。ルール型からの論証。当サイクルで対照を回さないなら、
`attributable` を測らない旨を理由に含める。

### 6. `successCriteria` 案（逐語）

番号付きの文字列列。1件目は `loaded`（marker 出現）にする。
`obeyed` は別件。review 記入時点で判定できない行は置かない。

### 7. 不採用にした計測案とその理由

最低1件。なぜ選ばなかったか（判定不能、測定器の混入、対照不足、軸の混同、など）。

---

## 差し戻し

次のいずれかがあれば不合格として差し戻す。

- 上記 1〜7 のいずれかが無い、空、または「後で決める」
- `successCriteria` に promote 後の事象がある
- `loaded` と `obeyed` が同一 criterion に混ざっている
- 証拠の取得元がパス・コマンド・ファイル名まで落ちていない
- 特定の計測手段を、この変種以外の既定として指定している
