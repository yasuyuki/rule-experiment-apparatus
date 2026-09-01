# Operator guide

Version control 下の experiment source に workload、evaluation、control / treatment variant source を
置きます。Private control repository の `cycles/<cycle>.json` に exact Git tree と SHA-256 を固定します。

```console
python3 apparatus/cycle.py --environment <environment.json> materialize --cycle <cycle>
```

表示された launch 情報で各 subject を起動し、両 arm へ同じ workload を逐語で渡します。完了後、
各 arm の workload 変更を commit して review を作ります。

```console
python3 apparatus/cycle.py --environment <environment.json> review --cycle <cycle>
python3 apparatus/cycle.py --environment <environment.json> promote --cycle <cycle>
```

最新 promotion を取り消す場合だけ次を使います。

```console
python3 apparatus/cycle.py --environment <environment.json> rollback --cycle <cycle>
```

失敗した cycle の declaration、arm、review は編集しません。修正後は新しい cycle id で再実行します。

`promote` は treatment variant の、cycle 宣言時に凍結した bytes を stable へ載せます。
その後に baseline が進んでいる cycle を promote すると、測定した rule 以外の placement と
他 rule も古い snapshot で上書きします。現行 stable の bytes と宣言時 treatment が一致して
いる cycle だけを promote してください。
