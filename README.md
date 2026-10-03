# Rule experiment apparatus

Agent に与える rule・skill の変更が実際の行動と成果へ及ぼす違いを調べ、
利用可能な証拠と資源から採否・現行維持・適用条件の判断を進めるための装置です。
条件を揃えた control / treatment 比較と検証はその手段であり、被検体の行動の決定性や
実験の形式的完全性自体を目的にしません。採用できない試行の観測も、言える範囲を
限定して利用します。baseline へ反映できるのは、評価した treatment と同一の bytes です。

公開操作は `materialize`、`review`、`promote`、`terminate`、`rollback` の5つです。CLI 固有の設定、
認証、起動、rule 配置、実行証拠の収集は versioned subject adapter が所有し、core は
adapter の JSON protocol と digest だけを扱います。

Claude adapter の profile は任意の `inventory` binding を受け付けます。
`agentRulesRoot`、`declaration`、`rules`（path 配列）、`site` を明示し、
宣言の `INVENTORY` が同じ controller 索引を参照します。prepare は通常 user のまま
公開 lifecycle の construction 検査を呼び、欠落時は arm 準備前に拒否します。
確認済みの home 配置から管理 skill と読込 binding だけを両 arm の config root へ
共通配置し、configIdentity に含めます。variant、baseline、既存 evidence は変更しません。
設定を持たない独立した利用者の profile は従来どおりです。

## 課金なしで最初に試す

POSIX host で依存を隔離した Python 環境を用意し、次の検査を実行します。
`test_cycle.py` は一時ディレクトリの fake subject で materialize、review、promote、
rollback、失敗時の拒否を試し、実際の agent CLI は起動しません。

```console
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r apparatus/requirements.txt
python apparatus/docs_check.py
python apparatus/cycle.py --selfcheck
python apparatus/tests/test_cycle.py
```

Windows controller では POSIX 検査を WSL 内で実行します。実際の二腕実験に必要な
private 設定と費用の確認は [Setup guide](docs/SETUP-GUIDE.md) と
[Operator guide](docs/USER-GUIDE.md) を参照してください。

## Documents

- [Constitution](CONSTITUTION.md)
- [Improvement policy](docs/IMPROVEMENT-POLICY.md)
- [Terms](TERMS.md)
- [Protocol and records](docs/RULE-EXPERIMENT.md)
- [Setup guide](docs/SETUP-GUIDE.md)
- [Operator guide](docs/USER-GUIDE.md)
- [Codex subject adapter](docs/CODEX.md)

### Historical

現行 tree に履歴文書は置きません。完了した変更の記録は Git history が持ちます。

## Checks

検査ごとに走らせる host が違います。最初の2つはどちらの host でも走ります。

```console
python3 apparatus/docs_check.py
python3 apparatus/cycle.py --selfcheck
```

次の2つは local-posix executor と実行ビット付きの fixture を使うので POSIX host が要ります。

```console
python3 apparatus/tests/test_cycle.py
python3 apparatus/tests/test_claude_code_adapter.py
python3 apparatus/tests/test_codex_adapter.py
```

`apparatus/tests/test_wsl_materialize.py` は逆に Windows controller でだけ走ります。Windows
workstation から POSIX 側の2つを走らせるときは、WSL を経由します。

```console
wsl.exe -d <distro> -u <user> --cd <repo> -e python3 apparatus/tests/test_cycle.py
```
