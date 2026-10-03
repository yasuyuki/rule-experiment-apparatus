# Operator guide

Version control 下の experiment source に workload、evaluation、control / treatment variant source を
置きます。Private control repository の `cycles/<cycle>.json` に exact Git tree と SHA-256 を固定します。
必要なら declaration の非空 `note` に、この測り直しの目的を残します。

実行前に、変更したい行動と判断基準を workload と evaluation に固定します。両 arm へ同じ
課題と入力を渡し、rule 以外の差と観測できない結果を記録します。`review` の `promote`
verdict は、評価 program が返す基準に改善があり、悪化と `unknown` がない場合だけです。
rule の効果や本番適用の安全性を自動で証明するものではありません。
calibration や stable に載せない内容を含む variant は、verdict が `promote` でも
`promote` を実行しません。

core 自身は LLM を呼びません。adapter や evaluation program に外部呼び出しを実装した
場合は、その時間と token も装置側の増分として測ります。
`materialize` は base の arm workspace を2つ、任意の materials を1組 `runsRoot` に
作り、subject ごとの `prepare` を各 arm で呼びます。
`review` は各 arm の `collect`、evaluation program、record 作成を行います。処理時間と
容量は base、managed rule、materials、adapter の作業量に依存します。実験本体の
agent 実行はこの増分に含めません。実行前後に `runsRoot` と private control の容量を測り、
`materialize` と `review` の経過時間を記録すると、装置固有の負担を比較できます。
実行後は review record と必要な証拠を保全してから撤去範囲を判断します。

```console
python3 apparatus/cycle.py --environment <environment.json> materialize --cycle <cycle>
```

表示された launch 情報で各 subject を起動し、両 arm へ同じ workload を逐語で渡します。完了後、
各 arm の workload 変更を commit して review を作ります。review は declaration の experiment / note、
各 managed variant の合計 bytes、adapter の sanitized `prepare` / `collect` 応答を逐語で固定し、
成功後に runtime `.adapter-state` を削除します。adapter が返す token に credential path を含む key を
置かないでください。

```console
python3 apparatus/cycle.py --environment <environment.json> review --cycle <cycle>
python3 apparatus/cycle.py --environment <environment.json> promote --cycle <cycle>
```

最新 promotion を取り消す場合だけ次を使います。

```console
python3 apparatus/cycle.py --environment <environment.json> rollback --cycle <cycle>
```

workload を続けない未 review cycle は、理由を付けて終端します。同一 status・reason・declaration
digest での再実行だけが成功し、record は変更されません。終端した cycle は materialize、review、
promote できません。既に review のある cycle は terminate できません。`terminate` は runtime
`.adapter-state` を削除しないため、必要な調査はその state と arm を読み取りで行えます。
同じ cycle の materialize、review、terminate が既に進行中なら、待機せず明示的に拒否されます。

`materialize` が途中で失敗すると、`runsRoot/<cycle>` に部分的な arm が残る場合があり、
同じ cycle id の再実行は拒否されます。残った arm と `.adapter-state` を調べ、続行しない
cycle は `terminate` で記録します。再試行は原因を直して新しい cycle id で行います。
`review` が失敗した場合は、宣言と variant bytes を変えずに原因を直せるか確認してから
再実行します。`terminate` は arm や state を消しません。証拠を保全した後、所有者が
`runsRoot`、CLI の config と transcript、private control の記録を別々に確認して撤去します。

```console
python3 apparatus/cycle.py --environment <environment.json> terminate --cycle <cycle> --status abandoned --reason "operator stopped the run"
```

元の declaration、保存済み arm の成果、review、termination は編集しません。保存済み成果物や
証拠の再検査・再解釈で判断できる場合は、被検体を再実行せず、その結果と元記録・評価条件の
違いを既存の記録先へ残します。再検査に変更を伴う場合は元資料を保持して作業用の複製を使い、
旧 verdict や品質到達時刻を置き換えません。新たに被検体を実行する場合は新しい cycle id を
使います。評価器の修正だけを理由に、被検体の再実行を自動で要求しません。

これは既存 cycle の review／promote を再開する操作ではありません。terminated cycle の禁止と
baseline の正規の状態遷移は維持します。再評価の扱いと現行実装上の制約は
[Protocol and records](RULE-EXPERIMENT.md)を参照してください。

`promote` は treatment variant の、cycle 宣言時に凍結した bytes を stable へ載せます。
昇格前に現行 stable の managed digest と宣言済み control の digest を照合します。
一致しなければ `not-promoted` と記録し、stable は変更しません。baseline が進んだ場合は
現行 stable を control にした新しい cycle で評価します。
