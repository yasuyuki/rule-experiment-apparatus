# Terms

| Term | Meaning |
|---|---|
| experiment | 証拠から採否・現行維持・適用条件の判断を進めるために調べる1つの問い |
| cycle | 宣言した固定入力条件から作る1回の control / treatment 比較。被検体の同一挙動を保証しない |
| arm | 比較の1条件。control 1件と treatment 1件 |
| base | 両 arm が共有する workload repository commit |
| material | workload が base の外に読む必要のある tree。cycle に1度宣言し commit で固定する |
| baseline | 記録された課題・条件・確認範囲で検証され、所定の状態遷移を経た stable rule-source tree。全条件での成功保証ではない |
| variant | baseline 候補となる完全な managed rule-source bytes |
| declaration | base、workload、evaluation、subject、variant identity を固定する JSON |
| subject | 注入済み variant と workload を与えられる被験主体。実際の行動は観測対象であり、指示への完全な遵守を前提にしない |
| adapter | subject 固有の環境と証拠を core protocol へ変換する versioned program |
| profile | adapter だけが解釈する environment 固有の opaque reference |
| review | declaration、adapter 応答、evaluation、verdict を固定する1 cycleの正規計測記録。後続の分析・再評価は元記録を参照し、上書きしない |
| `materialize` | base から2 arm を作り、各 adapter の `prepare` を呼ぶ |
| `review` | 各 adapter の `collect` と固定 evaluation を実行し、review record を作る |
| `promote` | 評価済み treatment bytes を baseline へ反映する |
| `terminate` | 未 review cycle を abandoned または failed として immutable record に終端する |
| `rollback` | 最新 promotion commit を revert し、直前の managed digest を復元する |
