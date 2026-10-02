# Setup guide

Python 3.10+、Git、Bash と `apparatus/requirements.txt` の依存を用意します。Windows controller
では WSL executor、POSIX では local executor を使います。

まず README の課金なしの検査を POSIX host で実行します。Windows では WSL 内の
checkout と Python 環境から実行します。この検査は fake subject の一時 repository
だけを使います。agent CLI の認証、rule 効果、実際の所要時間や請求額は検証しません。

実際の cycle には、以下の独立した入力を用意します。

- 変更前後の managed rule bytes と Git tree を持つ versioned experiment source
- 両 arm に共通の base commit、workload、evaluation program
- 安定版の rule-source repository と、利用する subject の adapter profile
- private control repository と、arm を実行する隔離済みの `runsRoot`

実験前に [Operator guide](USER-GUIDE.md) の費用と成果物の確認を行います。

`apparatus/schemas/environment.example.json` を private control repository へコピーし、次を設定します。

- `variantSourceRoot`: versioned experiment source repository
- `stableRules.root` / `stableRules.branch`: stable rule-source repository と branch
- `runsRoot`: executor が書き込める arm root。WSL では absolute path または `~/...`
- `profiles`: subject descriptor の `profileRef` から adapter 固有の opaque value への map

Subject descriptor と同じ directory に adapter entrypoint を置き、その SHA-256 を descriptor に
固定します。Adapter profile の内容、credential、実 user data は public repository に置きません。
Core は profile value を解釈しません。

Codex の `launchArgv` は固定 `agent-runtime --config <runtime.json> codex` を指定します。
Claude profile は vendor の `binary` を version/auth 確認用に保持し、実行用の絶対 path
`runtimeBinary` と `runtimeConfig` を別に指定します。`launchPrefix` は Windows から
WSL への輸送だけを担います。両 subject の runtime config は新規 run の root と固定
workspace-lifecycle entry/pins を宣言し、vendor の認証 source や arm ごとの config root は
従来の adapter profile に残します。

この repository は `agent-runtime` と `workspace-lifecycle` の組合せを一律の最新版へ
固定しません。private 設定の所有者が両 entry と source pin を記録し、その組合せで
`resolve-run` 接続と adapter の非 LLM 検査を通してから利用先を切り替えます。
adapter の検査だけでは実 CLI の認証や新規 run の受入を証明しません。

完成した cycle declaration は environment descriptor と同じ private control repository の
`cycles/<cycle>.json` で version 管理します。Runtime state、credential、transcript は追跡しません。

```console
python3 apparatus/cycle.py --environment <environment.json> --selfcheck
python3 apparatus/docs_check.py
python3 apparatus/tests/test_cycle.py
python3 apparatus/tests/test_claude_code_adapter.py
```

後半の2つは POSIX host でだけ走ります。Windows controller では WSL 経由で実行してください。
`local-posix` executor を Windows で読み込むと、`cycle.py` はその場で拒みます。
