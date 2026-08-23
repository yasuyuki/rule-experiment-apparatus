# アームの可視範囲（workload 適格性の正本）

サイクルの workload がアームの中で完結するかを判定する正本。**機械的に照合できる
事実だけを置く。** 設計の経緯・却下した候補・その理由は置かない。

対象は subject が触る filesystem である。セッションの所属は
[`EXECUTION-UNIT.md`](EXECUTION-UNIT.md)、実験の規範は
[`../CONSTITUTION.md`](../CONSTITUTION.md)、プロトコルは
[`RULE-EXPERIMENT.md`](RULE-EXPERIMENT.md) が持つ。

## 1. アームの実体

アームは**この装置リポジトリの clone 単体**である。`apparatus/cycle.py` の
`materialize` が作る構造は次のとおり。

```text
<release>/base        実リポジトリの clone。宣言の commit で detached checkout
<release>/<armId>     base からの clone（アーム1つにつき1つ）
```

`base.repo` は装置親ディレクトリの basename と一致しなければ `materialize` が拒否する
（`apparatus/cycle.py` の `resolve_materialize_base`）。**別リポジトリをアームに
することはできない。**

変種の常時適用ファイルはアーム内へ注入され、`git add -A -f` で commit される。
**注入されたファイルは測定対象の変種で
あって、workload の編集対象ではない**（subject は variant 正本を変更しない）。

## 2. 書き込みと commit ができる範囲

public source は通常の `.gitignore` を使い、local declaration、runtime data、archive を
除外する。workload の成果物は追跡対象の source path に出す。

| 経路 | 追跡 |
|---|---|
| `docs/**` | 追跡される |
| `apparatus/*.py`, `apparatus/README.md`, `apparatus/requirements.txt` | 追跡される |
| `apparatus/schemas/*.json`, `apparatus/subjects/*.json` | 追跡される |
| `apparatus/cycles/*.json` | operator-local input。ignore され、commit しない |
| `CONSTITUTION.md`, `TERMS.md`, `README.md` | 追跡される |
| `wrapper/` 配下 | 追跡されるが**着手対象外**（§3） |

新しい source path を追加するときは `.gitignore` と repository boundary test の両方で
公開対象か local data かを明示する。

## 3. アームの中で完結しないもの

次を必要とする作業は、そのサイクルの受け入れ条件に含めない。

- **`wrapper/` 配下の改修** — 着手しない
- **`agent-rules` リポジトリ** — アームの外。workspace に存在しない
- **`private-control` リポジトリとライブ release** — アームの外
- **実機でのツール起動確認**（実際に codex / cursor-agent を立ち上げて見る類）—
  アームの外。成果物を本体へ戻したあとに別途行い、**サイクルの合否には含めない**
- **scratch plan** — 追跡対象外。ここへ書いた判断は次のセッションから読めない

## 4. workload 候補を落とす順序

サイクルの workload を選ぶときは、**先に §3 で落としてから**大きさを見る。順序を
逆にすると「実行不能な案を、大きさを理由に縮めようとする」ことになる。

1. §3 のどれかを必要とするか → 必要とするなら落とす
2. 成果物が §2 の allowlist の中に出るか → 出ないなら落とす
3. 受け入れ条件をアーム内で実行できるコマンドで書けるか → 書けないなら落とす
4. ここまで残ったものについてだけ、大きさと分割を検討する

## 5. 計測との接続

装置の `judge` は参加セッションがちょうど1件のアームだけを受け付ける。複数セッションに
分かれる見込みの workload は、計測ではなく推定の候補になりうる。**推定設計そのものは
この文書の範囲外**で、[`RULE-EXPERIMENT.md`](RULE-EXPERIMENT.md) §7 が持つ。
この文書は適格性の先フィルタだけを持つ。
