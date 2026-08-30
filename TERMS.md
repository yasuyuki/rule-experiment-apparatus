# Terms

| Term | Meaning |
|---|---|
| experiment | 測りたい1つの問い |
| cycle | 同じ固定入力から作る1回の control / treatment 比較 |
| arm | 比較の1条件。control 1件と treatment 1件 |
| base | 両 arm が共有する workload repository commit |
| material | workload が base の外に読む必要のある tree。cycle に1度宣言し commit で固定する |
| baseline | 検証済みの stable rule-source tree |
| variant | baseline 候補となる完全な managed rule-source bytes |
| declaration | base、workload、evaluation、subject、variant identity を固定する JSON |
| subject | 注入済み variant の下で workload を実行する被験主体 |
| adapter | subject 固有の環境と証拠を core protocol へ変換する versioned program |
| profile | adapter だけが解釈する environment 固有の opaque reference |
| review | declaration、adapter 応答 digest、evaluation、verdict を統合した唯一の計測記録 |
| `materialize` | base から2 arm を作り、各 adapter の `prepare` を呼ぶ |
| `review` | 各 adapter の `collect` と固定 evaluation を実行し、review record を作る |
| `promote` | 評価済み treatment bytes を baseline へ反映する |
| `rollback` | 最新 promotion commit を revert し、直前の managed digest を復元する |
