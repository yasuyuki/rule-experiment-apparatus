# コマンドリファレンス

日常操作の入口は `wrapper/Invoke-FoundationRelease.ps1` です。状態を変更する操作を
個別スクリプトから直接呼ばず、stage を使います。操作順は
[`USER-GUIDE.md`](USER-GUIDE.md) を参照してください。

## 共通規約

- 作業ディレクトリは問わない。実装リポジトリのルートから
  `.\wrapper\<script>.ps1` を直接実行する。
- `-ConfigPath` / `-StatePath` の省略時は environment variable →
  `wrapper/config/environment.local.json` の順で解決します。
- 成功は `ok:true` の JSON と exit 0、失敗は `ok:false` と exit 1 です。
- state の runtime role は `baseline` / `run` / `previousBaseline` です。
  `baseline` は物理 `stable`、`run` は物理 `candidate` に固定されます。
  `previousBaseline` は rollback 用 backup metadata で、起動中 channel ではありません。
- destructive stage は対応する `-Execute` / `-Confirm*` が無い限り state を変更しません。
- `release-state.json` は手編集しません。

## `Invoke-FoundationRelease.ps1`

```powershell
.\wrapper\Invoke-FoundationRelease.ps1 -Stage <stage> [-Format json|text]
```

| stage | 主な追加引数 | state 変更 | 説明 |
| --- | --- | --- | --- |
| `status` | | なし | role、runtime、workspace、blocker、次の一手 |
| `doctor` | | なし | `healthy` と blocker の操作前ゲート |
| `seed` | `-Name` `-GitRef` | なし | stable baseline から candidate run を作る計画 |
| `seed` | `-Name` `-GitRef` `-Execute` | あり | 固定 candidate instance に run を作成 |
| `review-init` | `-Goal` `-SuccessCriteria` | なし | run の intent を一度だけ作成 |
| `inject` | `-Experiment` `-Variant` | なし（run の git のみ） | 正本変種を `state.run` の `.cursor/rules/` へコピーして commit |
| `handoff` | | なし | `state.run` の profile / target / window / Remote WSL を起動前検証 |
| `handoff` | `-Execute` | なし | 新しい subject window を起動し、identity を事後検証 |
| `accept` | `-SkipLeakScan` | なし | run workspace と identity leak を検査 |
| `protect` | | なし | run backup を作成し復元検証 |
| `review` | `-ReviewBlockPath` `-Force` | なし | controller が diff / evidence / verdict を記録 |
| `promote-dry` | | なし | run を baseline へ反映する計画と approval checklist |
| `promote` | `-ConfirmPromote` `-AllowSameCommit` `-SkipReview` | あり | accepted run を stable baseline path へ復元 |
| `discard` | | なし | run slot を空ける計画。baseline は変えない |
| `discard` | `-ConfirmDiscard` | あり | run を外す。workspace と review は残す |
| `rollback-dry` | | なし | `previousBaseline` を戻す計画 |
| `rollback` | `-ConfirmRollback` | あり | verified backup を stable baseline へ復元 |
| `verify` | | なし | system / live backup restore / transition verification |
| `migrate-runtime-model` | 下記 | dry-run / あり | legacy schema v2 を固定 runtime schema v3 へ1回だけ移行 |

`seed` の source は `state.baseline`、target は物理 `candidate` に固定です。任意 instance、
shared instance、任意 source path は公開 stage から指定できません。

`inject` は `state.run` 以外を受け取りません。`-Channel` / `-Path` / `-Instance` /
`-Role` は無く、baseline や任意 path は指定できません。正本
`rule-experiments/<experiment>/variants/<variant>.mdc` をバイト一致のまま
`<run.path>/.cursor/rules/<experiment>-<variant>.mdc` へコピーし、run 上で commit
します。`release-state.json` は書きません。run が無い・dirty・正本が無い / 正本
ディレクトリ外・設置先が release root `.cursor/rules/` でない場合は拒否します。

`handoff` は `state.run` 以外を受け取りません。`-Execute` 後も starter PID の生存だけでは
成功にせず、新しい root process、window、target、Remote WSL が一致したときだけ
`launchVerified:true` になります。prompt / workload は送信しません。

`discard` は `state.run` を外し、baseline と `previousBaseline` をそのまま残します。
candidate workspace は削除しません。次の `seed` は新しい `-Name` が必要です。同じ名前は
残留 path を上書きせず拒否します。`-Name` 省略時の既定名は generation 由来で、捨てた
release 番号の続きとは限りません。review 記録は残ります。`-ConfirmDiscard` が無い限り
state を変更しません。

## legacy state migration

schema v2 の `previous` がある場合は、内容を新 baseline に戻す `Rollback` か、現 active を
baseline として維持する `Discard` を選びます。どちらも旧 workspace を削除しません。
subject profile とその Remote WSL runtime を閉じてから実行します。

```powershell
# 1. path・generation・判断要否を確認
.\wrapper\Invoke-FoundationRelease.ps1 -Stage verify -ArchiveRoot <private-archives>

# 2. state を変えず backup / restore と計画を確認
.\wrapper\Invoke-FoundationRelease.ps1 -Stage migrate-runtime-model -PreviousDisposition Discard

# 3. dry-run が返した値をそのまま拘束して1回だけ実行
.\wrapper\Invoke-FoundationRelease.ps1 -Stage migrate-runtime-model `
  -PreviousDisposition Discard -ConfirmMigration `
  -ExpectedGeneration <generation> -ExpectedStateSha256 <sourceStateSha256>
```

execute は state lock を取り、期待 generation/hash が変わっていれば拒否します。結果の
`backupManifestSha256` と `resultStateSha256` を記録し、`status` で schema 3、
baseline=`stable`、run=`null` を確認します。

## status の主要フィールド

| フィールド | 意味 |
| --- | --- |
| `baseline` / `run` / `previousBaseline` | 固定 role の state |
| `baselineRuntime` / `runRuntime` | role に対応する process 状態 |
| `runtimes.stable` / `.candidate` | 物理 instance ごとの process 状態 |
| `canSeedRun` | run が空で seed 可能か |
| `workspaces.baseline` / `.run` | HEAD/ref、dirty、declared repository、local data |
| `blockers[]` | `code`、`role`、`detail`、`remediation[]` |
| `handoff.runtimeLockPresent` | expected runtime fingerprint の有無 |
| `nextAction` | blocker が無い場合の次 stage |

## inject の出力フィールド

| フィールド | 意味 |
| --- | --- |
| `release` | 注入先の run 名 |
| `experiment` / `variant` | 正本の実験名と変種名 |
| `source` | 正本の相対パス `rule-experiments/<experiment>/variants/<variant>.mdc` |
| `destination` | run 上の POSIX 設置先 |
| `sourceSha256` / `injectedSha256` | 正本と設置先の内容ハッシュ。成功時は一致 |
| `commit` | 注入後の run HEAD |
| `committed` | 新しい注入 commit を作ったか。同一内容の再実行は `false` |
| `next` | verified handoff の DryRun |

## read-only helpers

```powershell
.\wrapper\Get-FoundationStatus.ps1 [-Format json|text] [-SkipWorkspace]
.\wrapper\Get-FoundationVersion.ps1
.\wrapper\Get-FoundationReleaseDiff.ps1 -Role baseline|run
.\wrapper\Get-FoundationRepositoryInventory.ps1
.\wrapper\Get-FoundationRepositoryDeletionPlan.ps1 -ArchiveRoot <private-archives>
```

inventory の routed role は `baseline` / `run`、それ以外は
`retired-unreferenced` です。deletion plan は候補を返すだけで削除しません。

## 起動 helper

| コマンド | 用途 |
| --- | --- |
| `.\wrapper\Invoke-FoundationRelease.ps1 -Stage handoff` | subject run の唯一の公開 handoff |
| `.\wrapper\cursor-stable.ps1 <project>` | controller が物理 stable の登録 project を管理確認 |
| `.\wrapper\cursor-candidate.ps1 <project>` | controller が物理 candidate の登録 project を管理確認 |

`cursor-current.ps1` / `cursor-next.ps1` / `cursor-channel.ps1` は legacy channel wrapper
です。schema v3 では fail-closed し、subject handoff には使いません。

## backup と検証

```powershell
.\wrapper\New-FoundationReleaseBackup.ps1 -Role baseline|run `
  -ExpectedGeneration <n> -ExpectedCommit <sha> [-Execute]
.\wrapper\Test-FoundationRepositoryArchive.ps1 -ManifestPath <manifest.json> `
  -VerificationRoot <private-verification>
.\wrapper\Test-FoundationRootFilePatch.ps1 -Role baseline|run `
  -PatchPath <patch> -ExpectedBlob <blob>
```

必須 regression set:

```powershell
.\wrapper\Invoke-FoundationTests.ps1 -Suite all -ArchiveRoot <private-archives>
```

archive と restore 検証先は operator が repo 外の private path を明示する。
`portable`（既定）は fixture のみ。`live` は WSL を使う非破壊チェック。
`all` は portable + live + `Test-FoundationSystem.ps1`。運用の
`Invoke-FoundationRelease.ps1 -Stage verify` は system acceptance と同じ復元範囲で、
regression の重複実行ではない。

incident B〜D の fail-closed は portable fixture（`Test-Configuration` /
`Test-CursorConfiguration` / `Test-VerifiedHandoff`）と live `Test-Wrappers.ps1`
の handoff DryRun にある。incident A（controller が subject 作業を本体として始める）
は role-gate であり wrapper テストではない。
`seed` と `handoff -Execute` は run slot と GUI を変えるのでスイートに含めない。
明示する GUI smoke は subject profile と Remote WSL を閉じた状態で:

```powershell
.\wrapper\Test-VerifiedHandoffLive.ps1 -Execute
```

occupied のときは throw の直前の標準出力に `KILL_WHEN` と `KILL_COMMAND` が出る。
`runtime-fingerprint-mismatch` のときは DETAIL に `lock=` / `now=` と `RELOCK_COMMAND` が出る（KILL は出ない）。
RELOCK は Cursor を起動しない。次は `-Stage handoff`（DryRun）。`-Execute` は新しい窓が欲しいときだけ。
例外本文は1行だけ（pwsh ConciseView は改行を空白にする）。JSON では `killWhen` /
`killCommand` / `killConfirm`。エージェント無しで判断・実行する。

成功後に同じ handoff を DryRun し、`instance-occupied` / `remote-occupied` と
`launchStarted:false` を要求する。

fixture test は live config/state の hash を変えません。`Test-WorkspaceRelease.ps1` は
root + declared nested repository の backup/restore、migration CAS/execute、
promote/rollback を一時 workspace で検証します。

## 不変条件

- baseline を直接書き換える公開経路は作らず、promote / rollback だけで更新する。
- 遷移は state lock、期待 generation、原子的 state 書き込みを使う。
- subject は variant 正本、measurement、constitution、review を変更しない。
- 自動 kill、drain、seed、Cursor 起動、prompt 送信を行わない。
- stable / candidate は物理配置名であり、実験上の role 名ではない。
