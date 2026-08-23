# Rule experiment apparatus 構築手順

rule experiment apparatus を新しい Windows／WSL 環境へ準備するための手順です。
構築後の日常利用は [`USER-GUIDE.md`](USER-GUIDE.md)、各コマンドの詳細は
[`COMMANDS.md`](COMMANDS.md) を参照してください。

この PoC では、実装リポジトリと machine-local の control-plane リポジトリを分けます。
実際の Windows パス、WSL のユーザー名、Cursor profile、release のパスは、以下の
`<...>` を利用環境の値に置き換えてください。この文書には特定のマシンの値を記載しません。

## 1. 前提条件

次を準備します。

- Windows PowerShell 7 以降
- Cursor の実行ファイル
- WSL と、stable／candidate で使うディストリビューション・ユーザー
- Windows 側の Git
- 両 WSL ユーザーに、release repository を取得・検証するための Git と必要な
  開発ツールチェーン
- この実装リポジトリ

`seed` は repository を複製しますが、candidate の Linux ユーザーへ CLI、compiler、
runtime、認証をインストールしません。stable の credential file をコピーせず、candidate
側で独立して準備・認証します。

WSL の候補は次で確認できます。

```powershell
wsl.exe --list --quiet
```

以降では、次の変数を使います。

```powershell
$pocRoot = '<path-to-rule-experiment-apparatus>'
$wrapperRoot = Join-Path $pocRoot 'wrapper'
$controlRoot = '<path-to-control-plane-repository>'
New-Item -ItemType Directory -Force $controlRoot | Out-Null
```

control-plane リポジトリを新規作成する場合だけ、次を実行します。既存の clone を使う
場合は実行しません。

```powershell
git init -b main $controlRoot
```

## 2. environment.json を作る

公開テンプレートを control-plane リポジトリへコピーします。

```powershell
$configPath = Join-Path $controlRoot 'environment.json'
Copy-Item (Join-Path $wrapperRoot 'config\environment.example.json') $configPath
```

`environment.json` の `<...>` をすべて実値に置き換えます。値の意味は次のとおりです。

| 項目 | 設定する内容 |
| --- | --- |
| `cursor.executable` | Windows の Cursor 実行ファイル。`%LOCALAPPDATA%` などの環境変数を使える |
| `instances.stable` | 既存環境の WSL distro、ユーザー、home、projectsRoot。profile／userData／extensions は `null` のままなら既定値 |
| `instances.candidate` | 隔離環境の WSL distro、ユーザー、home、projectsRoot と専用の Windows `userProfile`／`userDataDir`／`extensionsDir` |
| `instances.*.releasesRoot` | 新しい release workspace の親（例 `<wslHome>/releases`）。`Projects` 配下を避けるために推奨 |
| `controlPlane.gitInstance` | control-plane の Git 操作に使う instance 名。`stable` または `candidate` |
| `repositoryDiscovery.namePatterns` | inventory 対象にする repository 名のパターン |
| `repositoryDiscovery.origins` | inventory 対象にする Git origin。不要なら空配列 |
| `storage.backupRoot` | control-plane や release bundle のバックアップ先 |
| `storage.verificationRoot` | 一時 restore 検証先。バックアップ先とは別の専用パスにする |
| `storage.localDataRoot` | 両 WSL から共有する gitignored-file store の Windows 絶対パス。`%USERPROFILE%` は使わない |
| `workspace.repositories` | release workspace 直下に置く project repo の相対パスと期待 origin |
| `projects` | 利用者が指定するプロジェクトキーごとの `kind`（`windows`／`wsl`）と path |

### candidate の隔離パスに関する注意

candidate の `userProfile`、`userDataDir`、`extensionsDir` は stable と共有しません。

**`userProfile` 配下に `AppData\Roaming` が存在しないと、Cursor は起動直後に
終了します。** wrapper はプロセスの `USERPROFILE` を差し替えるため、そこに
Roaming が無いと Cursor が自身の設定ディレクトリを作れません。先に作成します。

```powershell
New-Item -ItemType Directory -Force '<candidate-userProfile>\AppData\Roaming' | Out-Null
```

この `USERPROFILE` 差し替えは candidate Cursor のプロセスツリーにも継承されます。
その中から Windows native tool を起動すると、`%USERPROFILE%\.<tool>` の設定や
toolchain も隔離 profile 側を参照します。WSL workload は WSL 側の native toolchain を
使い、stable profile の設定を前提にしません。

### local data store

`storage.localDataRoot` には controller 管理の `local-data.sh` と `MANIFEST` が必要です。
stable / candidate の各 WSL home にある `~/local-data` を、同じ store の WSL mount path へ
symlink します。既存の `~/local-data` を無断で置き換えず、作成後に両 instance で確認します。
apparatus 自体は store 内容を生成しないため、この2ファイルが無ければ構築を止めます。

```powershell
wsl.exe -d '<stable-distro>' -u '<stable-user>' -- `
  ln -s '<store-wsl-mount-path>' '/home/<stable-user>/local-data'
wsl.exe -d '<candidate-distro>' -u '<candidate-user>' -- `
  ln -s '<store-wsl-mount-path>' '/home/<candidate-user>/local-data'

wsl.exe -d '<stable-distro>' -u '<stable-user>' -- `
  readlink -f '/home/<stable-user>/local-data'
wsl.exe -d '<candidate-distro>' -u '<candidate-user>' -- `
  readlink -f '/home/<candidate-user>/local-data'
```

両方が同じ store を返し、その場所に `local-data.sh` と `MANIFEST` が見えることを確認します。

実プロジェクトを開く場合は、Windows path または WSL path がそのユーザーから
見えることを確認します。

設定ファイルを保存したら、テンプレートと schema の検証を実行します。

```powershell
& "$wrapperRoot\Test-Configuration.ps1"
```

これは公開テンプレート、schema、パス解決の確認です。この検証を通ったテンプレートを
そのまま実行環境に使うのではなく、control-plane 側の `environment.json` を完成させます。

## 3. release-state.json を作る

`release-state.json` は、実際に存在する release repository の routing 状態です。
別マシンの完成済み state をコピーしないでください。

まず各 release の情報を WSL で確認します。

```powershell
wsl.exe -d '<distro>' -u '<user>' -- id -un
wsl.exe -d '<distro>' -u '<user>' -- git -C '<absolute-wsl-repository-path>' rev-parse HEAD
wsl.exe -d '<distro>' -u '<user>' -- git -C '<absolute-wsl-repository-path>' branch --show-current
wsl.exe -d '<distro>' -u '<user>' -- git -C '<absolute-wsl-repository-path>' remote get-url origin
```

次の条件を満たす値を使います。

- `instance` は `stable` または `candidate` のいずれか。他の値は拒否される。
- `path` はその distro から見える絶対 POSIX path で、repository が実在する。
- `gitRef` は同じ repository で解決でき、HEAD と一致する。
- `baseline.instance` は `stable` 固定。`run.instance` は `candidate` 固定。
- `commit` は `git rev-parse HEAD` で得た値を使う。

テンプレートをコピーして実値に置き換えます。

```powershell
$statePath = Join-Path $controlRoot 'release-state.json'
Copy-Item (Join-Path $wrapperRoot 'config\release-state.example.json') $statePath
notepad $statePath
```

`generation` は 0、`run` と `previousBaseline` は `null` にします。
`lastTransition` と `transitionHistory` の唯一の要素は同じ `bootstrap` 内容にし、
`at` は RFC3339 時刻、`from` は `none`、`to` は baseline 名、`commit` は baseline の
HEAD にします。

以後 state を手で編集せず、変更は `Invoke-FoundationRelease.ps1` の stage で行います。
`seed` が candidate に run を作り、`promote` が受理済み run を stable baseline へ反映し、
`discard` が run slot だけを空け、`rollback` が `previousBaseline` の verified backup を
stable へ戻します。物理 instance はどの遷移でも入れ替わりません。

## 4. local config を生成して検証する

control-plane のパスは、毎回の環境変数ではなく machine-local の
`wrapper/config/environment.local.json` に保存します。このファイルは実装リポジトリに
コミットしません。

```powershell
& "$wrapperRoot\New-FoundationLocalConfig.ps1" `
  -ConfigPath $configPath `
  -StatePath $statePath `
  -BackupRoot '<path-to-backup-root>'
```

`-BackupRoot` を省略すると `environment.json` の `storage.backupRoot` を使います。
既存の local config を上書きするときだけ `-Force` を付けます。

以後のコマンドはこの local config を自動で読みます。**state にリポジトリ内の
フォールバックはありません。** local config も環境変数も引数も無い場合、コマンドは
古い state を読むのではなく明示的に失敗します。

`FOUNDATION_CONTROL_CONFIG` などの環境変数を設定している場合、それが local config
より優先されます。意図しない環境を指していないか確認してください。

subject profile を閉じた状態で、handoff が比較する runtime expectation を作ります。
model は宣言値であり、自動検出値ではありません。生成した JSON を確認し、commit しません。

```powershell
& "$wrapperRoot\Get-SubjectRuntimeFingerprint.ps1" -Model '<declared-model>' |
  Set-Content -LiteralPath (Join-Path $controlRoot 'runtime.lock') -Encoding utf8
```

続いて設定を使う検証を実行します。`all` は live（WSL の非破壊チェック）に
system acceptance（backup restore）を足します。`live` だけを先に走らせる必要は
ありません。

```powershell
& "$wrapperRoot\Invoke-FoundationTests.ps1" -Suite all -ArchiveRoot <private-archives>
```

## 5. 最初の起動を確認する

設定したプロジェクトキーを選び、stable／candidate の両方を DryRun します。

```powershell
$projectName = '<project-key-from-environment.json>'
& "$wrapperRoot\cursor-stable.ps1" $projectName -DryRun
& "$wrapperRoot\cursor-candidate.ps1" $projectName -DryRun
```

candidate の profile／user data／extensions が専用パスになっていることを確認します。
stable / candidate は物理 instance 名で、baseline / run の評価 role ではありません。

candidate に初めてサインインするときだけ `-AllowUnauthenticated` を使います。
サインイン状態を stable からコピーしないでください。

WSL 対象で空のウィンドウが開く場合は、その専用 extensions ディレクトリに Remote WSL
拡張が `extensions.json` ごと登録されているかを確認します。フォルダだけでは不足です。

最後に全体を確認します。

```powershell
& "$wrapperRoot\Invoke-FoundationRelease.ps1" -Stage status -Format text
```

## 6. 保管と変更のルール

- `environment.json` と `release-state.json` は control-plane リポジトリだけで管理する。
- `wrapper/config/environment.local.json` は machine-local のポインタであり、
  実装リポジトリにも control-plane リポジトリにも入れない。
- Cursor profile、user-data、extension cache、credential、ログ、project data は
  control-plane リポジトリに入れない。
- state を直接編集せず、`Invoke-FoundationRelease.ps1` の stage で変更する。
- control-plane リポジトリを backup／remote に置く場合は、machine path と
  release metadata の公開範囲を確認する。

構築が終わったら、次回からは [`USER-GUIDE.md`](USER-GUIDE.md) に従って利用します。
