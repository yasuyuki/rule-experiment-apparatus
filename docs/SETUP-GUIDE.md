# Setup guide

Python 3.10+、Git、Bash と `apparatus/requirements.txt` の依存を用意します。Windows controller
では WSL executor、POSIX では local executor を使います。

`apparatus/schemas/environment.example.json` を private control repository へコピーし、次を設定します。

- `variantSourceRoot`: versioned experiment source repository
- `stableRules.root` / `stableRules.branch`: stable rule-source repository と branch
- `runsRoot`: executor が書き込める arm root
- `profiles`: subject descriptor の `profileRef` から adapter 固有の opaque value への map

Subject descriptor と同じ directory に adapter entrypoint を置き、その SHA-256 を descriptor に
固定します。Adapter profile の内容、credential、実 user data は public repository に置きません。
Core は profile value を解釈しません。

完成した cycle declaration は environment descriptor と同じ private control repository の
`cycles/<cycle>.json` で version 管理します。Runtime state、credential、transcript は追跡しません。

```console
python3 apparatus/cycle.py --environment <environment.json> --selfcheck
python3 apparatus/docs_check.py
python3 apparatus/tests/test_cycle.py
python3 apparatus/tests/test_claude_code_adapter.py
```
