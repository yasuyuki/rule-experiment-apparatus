# Operator guide

Version control 下の experiment source に workload、evaluation、control / treatment variant source を
置きます。Private control repository の `cycles/<cycle>.json` に exact Git tree と SHA-256 を固定します。
試験を始める前に、declaration の `note` に比較の説明を書きます。通常の文章として扱う欄であり、
専用のマークアップや項目ごとの機械的な必須チェックはありません。次の順に空行で段落を分けると、
結果を読む人が比較の意図を確認できます。

- 先頭段落：どんな課題で、どの指示とどの指示を比較するか。
- 続く段落：共通の課題、基準となる指示（control）、変更した指示（treatment）、期待する行動差。
- 再試験の場合：前回から何を変え、何を確かめ直すか。

先頭段落だけでも比較を理解できるようにし、詳しい説明を後ろに続けます。期待する効果を実行前に
書き、実行後の観測結果と混ぜません。結果や評価は review に記録します。たとえば、再試験なら
次のように書けます。

```text
設定ファイルの無効な値を調べる課題で、現行の指示と「原因を一行で説明してから修正方針を示す」という指示を加えた条件を比較する。

両条件で同じ設定ファイルを読み、無効な値を見つけて修正方針を答える。基準側（control）には現行の指示を渡す。

比較側（treatment）では、無効な値の原因を一行で説明してから修正方針を示す指示を追加する。原因と修正方針が区別して読める回答を期待する。

前回は「原因を説明する」とだけ書いていたが、今回は説明の順序と長さを指定する。課題と評価方法は同じにして、この変更で原因を簡潔に示せるかを確かめ直す。
```

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

失敗した cycle の declaration、arm、review は編集しません。修正後は新しい cycle id で再実行します。

`promote` は treatment variant の、cycle 宣言時に凍結した bytes を stable へ載せます。
その後に baseline が進んでいる cycle を promote すると、測定した rule 以外の placement と
他 rule も古い snapshot で上書きします。現行 stable の bytes と宣言時 treatment が一致して
いる cycle だけを promote してください。
