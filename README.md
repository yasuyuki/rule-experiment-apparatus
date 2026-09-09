# Rule experiment apparatus

Agent rule の変更だけを control / treatment 間で変え、行動差を計測する最小の装置です。
評価した treatment bytes と同じ bytes だけを stable baseline へ反映できます。

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

## Documents

- [Constitution](CONSTITUTION.md)
- [Improvement policy](docs/IMPROVEMENT-POLICY.md)
- [Terms](TERMS.md)
- [Protocol and records](docs/RULE-EXPERIMENT.md)
- [Setup guide](docs/SETUP-GUIDE.md)
- [Operator guide](docs/USER-GUIDE.md)

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
```

`apparatus/tests/test_wsl_materialize.py` は逆に Windows controller でだけ走ります。Windows
workstation から POSIX 側の2つを走らせるときは、WSL を経由します。

```console
wsl.exe -d <distro> -u <user> --cd <repo> -e python3 apparatus/tests/test_cycle.py
```
