# Operator guide

Version control 下の experiment source に workload、evaluation、control / treatment variant source を
置きます。Private control repository の `cycles/<cycle>.json` に exact Git tree と SHA-256 を固定します。
必要なら declaration の非空 `note` に、この測り直しの目的を残します。

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
その後に baseline が進んでいる cycle を promote すると、測定した rule 以外の placement と
他 rule も古い snapshot で上書きします。現行 stable の bytes と宣言時 treatment が一致して
いる cycle だけを promote してください。
