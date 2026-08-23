# レビュー記録の判定基準

**この文書は `schemaVersion: 1` のレリーズ review 用です。`schemaVersion: 2` のサイクル記録の記入基準は [`CYCLE-RECORD-CRITERIA.md`](CYCLE-RECORD-CRITERIA.md) です。**

`private-control/reviews/<release>.json` の `review` ブロックを controller が
記入するときの判断規則です。構造・enum・必須性・criterion の1:1対応は
`wrapper/lib/ReleaseReview.ps1` と `wrapper/schemas/release-review.schema.json` が正本です。
操作順は [`USER-GUIDE.md`](USER-GUIDE.md)、測定の設計は
[`RULE-EXPERIMENT.md`](RULE-EXPERIMENT.md) を参照してください。

## 1. 判定対象を混ぜない

| フィールド | 判定対象 | 含めないもの |
| --- | --- | --- |
| `correctness` | intent で宣言した効果が得られたか | 手順や装置への不満 |
| `procedure` | このサイクルの進め方 | 成果の良し悪し |
| `procedureChecks` | 4つの具体的事実 | 主観的な満足度 |
| `verdict` | run を baseline に固定してよいか | 上記フィールドの機械的な要約 |

装置や基準の改善案は `betterProcedure` に書き、未解決なら `ISSUES.md` に移します。
run の内容と無関係な理由で `verdict` を下げません。

## 2. `correctness`

- `pass`: `criteriaResults` がすべて `met`。
- `partial`: `unmet` / `unknown` があるが、goal の中核は達成している。
- `fail`: 中核 criterion が `unmet`、または成果が intent と別物。

`unknown` は必要な証拠を取得できない場合だけです。「まだ確認していない」は該当しません。
中核 criterion と、環境制約時に代替証拠を認めるかは `review-init` 前に決めます。
決めていなければ controller が判断し、根拠を `evidence` に明記します。

## 3. `procedure`

- `good`: `procedureChecks` がすべて `yes` / `na` で、stage のやり直し、state の
  手当て、回避フラグがない。
- `acceptable`: `procedureChecks` は満たしたが、実害のない手戻りがあった。
- `needs-improvement`: `no` がある、または次回も再発しうる手順欠陥がある。

複数に該当するときは、再発性のある `needs-improvement` を優先します。

## 4. `procedureChecks`

| キー | `yes` の条件 | `na` |
| --- | --- | --- |
| `minimalChange` | intent 外の変更がない。混入分は独立 commit に分離済み | サイクルに変更がない |
| `verifiedBeforeProceeding` | 各 stage の出力を読んでから次へ進んだ | その stage が不要なサイクル |
| `rollbackPreserved` | review 前に `protect` が backup と restore を検証し、state を手編集していない | なし |
| `stableIsolationUsed` | baseline の設定・認証・worktree を subject が変更していない | なし |

`stableIsolationUsed` の名前は review schema v1 との互換のため残っています。判定対象は
物理 instance 名ではなく、constitution の baseline 隔離です。

## 5. `verdict`

- `accepted`: `correctness=pass`。`partial` の場合は、測定仕様の `loaded` と中核の
  `obeyed`（対照が必要な実験では `attributable` も）が確認済みで、比較不変条件を
  満たし、残る未達が効果の結論や baseline の安全性を変えず、残課題が `ISSUES.md`
  か `HANDOFF.md` に移されている場合だけ。
- `needs-work`: 修正または追加検証後に固定できる。run を直し、review を再作成する。
- `rejected`: 方向が誤っている。promote しない。

`correctness=fail` を `accepted` にしません。`procedure=needs-improvement` だけを理由に
成果を reject せず、改善内容を `betterProcedure` へ残します。

## 6. 記入規約

- `criteriaResults[].criterion` は `intent.successCriteria` と逐語一致させる。
- 全 criterion は review 時点で判定可能にする。promote 後の事象を含めない。
- `evidence` は観測した出力、commit、ファイルを記し、推測を書かない。
- `betterProcedure` は改善が無ければ `none`。空文字は使わない。
- enum と commit hash は小文字で記す。
- `-Stage review` が示す review block を埋め、`-ReviewBlockPath` で渡す。
  wrapper が現在の root / nested repository の commit を記録するため、SHA を手で
  review block に書かない。

## 7. 較正ログ

各サイクルで、基準が答えられなかった点だけを1ブロック追記します。判断に迷わなかった
項目やコマンド出力は review record に残し、ここへ複製しません。文言へ反映済み、または
再発しないと確定したブロックは削除し、履歴は Git に任せます。

```markdown
### <release> (YYYY-MM-DD)
- 迷った項目: <field> — <理由 / none>
- 基準が答えなかった項目: <field> — <状況 / none>
- 文言の変更提案: <提案 / none>
- 機構側の改善点: <不足 / none>
```

### release-18 (2026-08-16)
- 迷った項目: criteriaResults[0] — successCriteria 1 は candidate userProfile だけを指定する。実体の jsonl は run instance `~/.cursor/projects/` にあり、MEASUREMENT.md §4 の fallback で met とした
- 基準が答えなかった項目: procedure — subject が controller の review-block を書いた。procedureChecks の 4 キーには載らない
- 文言の変更提案: loaded の successCriteria に MEASUREMENT §4 の fallback（run instance `~/.cursor/projects/`）を含める
- 機構側の改善点: Remote WSL の transcript が Windows userProfile ではなく Linux home に置かれる。handoff 資料に「subject は review を書くな」が無い
