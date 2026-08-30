# Rule experiment apparatus

Agent rule の変更だけを control / treatment 間で変え、行動差を計測する最小の装置です。
評価した treatment bytes と同じ bytes だけを stable baseline へ反映できます。

公開操作は `materialize`、`review`、`promote`、`rollback` の4つです。CLI 固有の設定、
認証、起動、rule 配置、実行証拠の収集は versioned subject adapter が所有し、core は
adapter の JSON protocol と digest だけを扱います。

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
