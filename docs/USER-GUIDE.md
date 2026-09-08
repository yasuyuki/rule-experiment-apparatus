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
```

## 結果を吟味し、次の方針を決める

review の直後は **差分保存・可視化 → 結果の吟味 → 方針決定 → 次の行動 → 実施確認** と進めます。
差分保存と可視化には controller 環境の既存手順を使います。公開apparatusは可視化ツールに依存しません。
review の `verdict: promote` は機械上の採用可能判定です。採用する意思や通常環境への適用完了を意味しません。

agent は比較の成立、観測された効果、回帰、不確実性、過去の同条件試験との関係、通常運用での
適用可能性の順に吟味し、根拠付きの推奨案を作ります。試験回数や成功率だけで判断しません。

| 方針 (`policy`) | 必要な内容 | 確定できる人 |
|---|---|---|
| 見送り・終了 (`discard`) | 比較を終了して取り込まない理由。証拠を保存する | 本人 |
| 改善再試験 (`revise`) | `revision.changes`: 何を変えるか、`question`: 何を確かめるか | agent。迷う場合は本人 |
| 同条件継続 (`continue`) | `continuation.unresolved`: 未確定事項、`updateWhen`: 追加観測で判断を更新する条件 | agent。迷う場合は本人 |
| 保留 (`hold`) | `resumptionCondition`: 再開に必要な情報・条件 | agent。迷う場合は本人 |
| 採用 (`adopt`) | `adoption.targetDigest`: 対象指示digest、`scope`: 適用範囲 | 本人 |

本人の判断が必要なら `status: recommended` で推奨案を記録し、推奨・理由・選択後の具体的行動を
本人へ提示して待ちます。本人の明示回答を得た後だけ `actor: owner`, `status: confirmed` として
`ownerResponse.text` に回答、`reference` にその会話等の参照を記録します。controller が記録に責任を持ち、
本人の意思を推測してはなりません。署名や新しい本人認証の仕組みはありません。
agent が確定できる方針でも、迷った場合は推奨のままにします。

### 決定の入力と保存

入力JSONファイルを用意し、開発版の公開入口から記録します。

```console
python3 apparatus/cycle.py --environment <environment.json> decide --cycle <cycle> --input <decision.json>
```

入力の完全な形式は [decision-input.schema.json](../apparatus/schemas/decision-input.schema.json) です。
たとえば agent による保留確定は次の形です。山括弧内を今回の実際の証拠・判断で置き換えます。
`reviewSha256` は対象 `reviews/<cycle>.json` ファイルの SHA-256 です。

```json
{
  "reviewSha256": "<reviewファイルの64桁SHA-256>",
  "previousDecision": null,
  "status": "confirmed",
  "policy": "hold",
  "actor": "agent",
  "reason": "<今回結論を出せない理由>",
  "nextAction": "<再開条件を満たすための具体的操作>",
  "assessment": {
    "comparisonValidity": "<比較が成立するかと根拠>",
    "effects": "<観測された効果と根拠>",
    "regressions": "<回帰と根拠>",
    "uncertainty": "<不確実性>",
    "priorTrials": "<過去の同条件試験との関係。なければその旨>",
    "applicability": "<通常運用への適用可能性>"
  },
  "references": [],
  "resumptionCondition": "<再開に必要な情報・条件>"
}
```

参照した他試験があれば `references` に `{"cycle": "<id>", "reviewSha256": "<SHA-256>"}` を追加します。
方針ごとの専用fieldは表のものだけを付け、他方針のfieldを混ぜません。採用の推奨にもdigestとscopeが必要です。

記録は private control の `decisions/<cycle>/` に追記され、reviewを変更しません。入口が返す `id` を
次の入力の `previousDecision` に指定します。初回だけ `null` です。推奨から確定への移行も、判断変更も
新しい入力として追記します。同一入力の再実行は元の記録を返し、古い判断を最新に戻しません。
同時操作はcycle共通lockで拒否されるので、最新記録を読み直してから再実行します。
過去の決定が存在しない試験は「方針未記録」であり、過去のpromotionから意思を補完しません。

### 次の行動と実施確認

改善再試験・同条件継続では新しいcycleを宣言し、次を追加します。

```json
"originDecision": {"cycle": "<元cycle>", "decisionId": "<確定した再試験・継続の決定id>"}
```

元のcycle・reviewは編集しません。同条件継続は、cycle id・説明note・originDecision以外の宣言内容と
reviewed adapter identityを維持します。比較条件を変える必要があれば `revise` を確定して参照します。
保留なら記録した再開条件を満たすまで止めます。見送りなら証拠を残してこの比較を終了します。

採用は次の3段階です。

1. 本人の採用決定を上の入口で確定記録する。
2. 指示の正本へ反映する。最新決定が本人の確定採用で、reviewと対象digestが一致するときだけ進める。
3. 既存の公開配置入口と検証で、決定した範囲の通常環境への適用を確認する。

段階2の入口は次です。既存のreview評価・宣言・source同一性検査も必要です。本人決定があっても
機械の採用条件を満たさない試験は取り込みません。判断待ちの拒否はpromotion記録を作らないので、
正しい決定を記録して再実行できます。準備済みpromotionの再開にも最新決定が必要です。

```console
python3 apparatus/cycle.py --environment <environment.json> promote --cycle <cycle>
```

段階3では本人判断を作り直さず、最新の採用入力を引き継ぎ、`previousDecision` を更新して次を添えて
`decide` へ渡します。scopeとdigestは採用時と一致させます。`checkedAt` はtimezone付きISO日時、
`verificationReference` は実行した公開配置入口と検証結果を保存した参照です。未確認の結果は記録しません。

```json
"application": {
  "decisionId": "<元の本人確定採用id>",
  "targetDigest": "<採用時のdigest>",
  "scope": "<採用時の適用範囲>",
  "checkedAt": "<実際の検証日時>",
  "verificationReference": "<配置検証の証拠参照>"
}
```

この追記は既存の本人決定をそのまま参照する実施確認であり、新しい本人回答を要求しません。
完了済みの対応promotionが必要です。promotionだけでは通常環境への適用完了とせず、過去の確認は
その時点の証拠として表示し、現在の配置一致とは表示しません。

## 取り消しと未完了試験の終端

最新 promotion を取り消す場合だけ次を使います。

```console
python3 apparatus/cycle.py --environment <environment.json> rollback --cycle <cycle>
```

workload を続けない未 review cycle は、理由を付けて終端します。同一 status・reason・declaration
digest での再実行だけが成功し、record は変更されません。終端した cycle は materialize、review、
promote できません。既に review のある cycle は terminate できません。`terminate` は runtime
`.adapter-state` を削除しないため、必要な調査はその state と arm を読み取りで行えます。
同じ cycle の materialize、review、terminate、decide、promote が既に進行中なら、待機せず明示的に拒否されます。

```console
python3 apparatus/cycle.py --environment <environment.json> terminate --cycle <cycle> --status abandoned --reason "operator stopped the run"
```

失敗した cycle の declaration、arm、review は編集しません。修正後は新しい cycle id で再実行します。

`promote` は treatment variant の、cycle 宣言時に凍結した bytes を stable へ載せます。
その後に baseline が進んでいる cycle を promote すると、測定した rule 以外の placement と
他 rule も古い snapshot で上書きします。採用判断の前に現行stableとの差分全体を確認し、
反映されるmanaged bytes全体が本人の採用範囲に含まれることを確認してください。
