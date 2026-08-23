# Cursor isolation PoC 日常利用手順

このガイドは schema v3 の固定 runtime model を使います。操作する Windows session は
`controller`、実験を実行する専用 Cursor / WSL は `subject` です。

**この文書は操作手順だけを扱います。** 規範の正本は
[`CONSTITUTION.md`](../CONSTITUTION.md)、用語の正本は [`TERMS.md`](../TERMS.md)、
不変条件を成立させる方法の正本は [`RULE-EXPERIMENT.md`](RULE-EXPERIMENT.md) です。
ここに手順として書いてあることが、それらの規範を上書きすることはありません。

## 0. 作業開始

公開入口は実装リポジトリの `wrapper\Invoke-FoundationRelease.ps1` です。
スクリプトは `$PSScriptRoot` で解決するため、作業ディレクトリを `wrapper` へ
移す必要はありません。以下は実装リポジトリのルートからの例です。

```powershell
.\wrapper\Invoke-FoundationRelease.ps1 -Stage status -Format text
```

実際の path は `environment.json` から解決されます。`release-state.json` を手編集せず、
表示された blocker を解消してから次へ進みます。seed / promote も blocker が残ると
拒否します。読み取り専用の健康確認だけなら `-Stage doctor` を使います。

## 1. role を読む

- `baseline`: 受理済み状態。物理 `stable` に固定。
- `run`: 未評価の実験 workspace。物理 `candidate` に固定。空なら `null`。
- `previousBaseline`: rollback 用の verified backup metadata。起動中 session ではない。
- `stable` / `candidate`: 物理 instance 名。実験の評価 role ではない。

`status` の正しい配置は baseline=`stable`、run があれば run=`candidate` です。
promote / rollback 後にもこの配置は入れ替わりません。

## 2. legacy schema v2 を移行する場合

通常は一度だけです。まず `verify` と dry-run を実行します。

```powershell
.\wrapper\Invoke-FoundationRelease.ps1 -Stage verify -ArchiveRoot <private-archives>
.\wrapper\Invoke-FoundationRelease.ps1 -Stage migrate-runtime-model `
  -PreviousDisposition <Rollback|Discard>
```

- `Rollback`: legacy `previous` の内容を新しい stable baseline にする。
- `Discard`: legacy `active` を baseline として維持する。

どちらも旧 workspace を削除しません。subject 用 Cursor profile と Remote WSL を閉じ、
dry-run の `configPath` / `statePath`、generation、source hash、backup/restore を確認します。
承認後、dry-run が返した値をそのまま使います。

```powershell
.\wrapper\Invoke-FoundationRelease.ps1 -Stage migrate-runtime-model `
  -PreviousDisposition <Rollback|Discard> -ConfirmMigration `
  -ExpectedGeneration <generation> -ExpectedStateSha256 <sourceStateSha256>
```

完了後は `status -Format text` で schema 3、baseline=`stable`、run=`null` を確認します。

## 3. 新しい run を準備する

controller で apparatus の該当 phase を実行し、計測仕様と variant を先に固定します。
seed は stable baseline から固定 candidate instance へだけ作成されます。

```powershell
.\wrapper\Invoke-FoundationRelease.ps1 -Stage seed -Name <release> -GitRef <branch>
.\wrapper\Invoke-FoundationRelease.ps1 -Stage seed -Name <release> -GitRef <branch> -Execute
.\wrapper\Invoke-FoundationRelease.ps1 -Stage review-init `
  -Goal '<goal>' -SuccessCriteria '<criterion-1>','<criterion-2>'
.\wrapper\Invoke-FoundationRelease.ps1 -Stage inject `
  -Experiment <experiment> -Variant <variant>
```

seed と review-init のあと、verified handoff の前に `inject` します。正本から
`state.run` の `.cursor/rules/` へコピーし、バイト一致を確認して commit します。
手打ちしません。

## 4. subject へ handoff する

```powershell
# process を起動しない preflight
.\wrapper\Invoke-FoundationRelease.ps1 -Stage handoff

# 人が確認した後だけ起動
.\wrapper\Invoke-FoundationRelease.ps1 -Stage handoff -Execute
```

`launchVerified:true`、target identity、runtime fingerprint が一致した場合だけ成功です。
controller はここで停止し、人が `workload.md` を verified subject window へそのまま貼ります。
wrapper は workload や prompt を自動送信しません。

subject が変更してよいのは handoff された workload の対象だけです。variant 正本、
MEASUREMENT、constitution、review は controller の所有物です
（憲法 不変条件 3。この段落は手順上の再掲であって正本ではありません）。

## 5. controller が観測・review する

subject workload が終わったら controller session に戻ります。

```powershell
.\wrapper\Invoke-FoundationRelease.ps1 -Stage accept
.\wrapper\Invoke-FoundationRelease.ps1 -Stage protect
.\wrapper\Invoke-FoundationRelease.ps1 -Stage review
.\wrapper\Invoke-FoundationRelease.ps1 -Stage review `
  -ReviewBlockPath <review-block.json>
.\wrapper\Invoke-FoundationRelease.ps1 -Stage promote-dry
```

review は subject に書かせません。`promote-dry` の blocker、diff、review gate、
approval checklist を確認し、受理する場合だけ実行します。

```powershell
.\wrapper\Invoke-FoundationRelease.ps1 -Stage promote -ConfirmPromote
```

promote は accepted run の verified backup を stable baseline path へ復元し、run を空にします。
物理 role は入れ替えません。

## 6. run を promote せずに捨てる

再計測は同一 baseline からやり直すので、rejected / 未固定の run は promote しません。
`-SkipReview` promote で slot を空けないでください。

```powershell
.\wrapper\Invoke-FoundationRelease.ps1 -Stage discard
.\wrapper\Invoke-FoundationRelease.ps1 -Stage discard -ConfirmDiscard
```

discard は run slot を空けるだけです。baseline は変わりません。candidate 上の旧
workspace は削除せず、review 記録も残します。同じ `-Name` での再 seed は残留 path で
拒否されるので、再計測では新しい `-Name` を明示します。省略時の既定名は generation
由来で、捨てた番号の続きではありません。

## 7. rollback

```powershell
.\wrapper\Invoke-FoundationRelease.ps1 -Stage rollback-dry
.\wrapper\Invoke-FoundationRelease.ps1 -Stage rollback -ConfirmRollback
```

rollback は `previousBaseline` の verified backup を stable に復元し、その metadata を
消費します。開いている session は自動で移動・終了しません。

## 8. 困ったとき

| 症状 | 確認 |
| --- | --- |
| 次へ進めない | `-Stage doctor` の `blockers[]` と `remediation[]` |
| handoff が拒否される | throw 直前の標準出力。occupied なら `KILL_WHEN` / `KILL_COMMAND`、fingerprint なら `RELOCK_COMMAND` |
| run が dirty | subject の変更を commit/stash し、`accept` を再実行 |
| local data drift | `workspaces.<role>.localData.problems` を確認し、方向を決めて pull/push |
| rollback できない | `previousBaseline` が存在するか `status` で確認 |
| 次の seed ができない | run が残っている。promote せず空けるなら `-Stage discard` |
| legacy wrapper が失敗する | 正常。subject は `-Stage handoff` を使う |

削除や process 終了は status/doctor が自動実行しません。retired workspace の処分は
repository inventory と deletion plan を確認し、別途明示承認を得て行います。

handoff が `instance-occupied` / `remote-occupied` のとき、throw の**直前の標準出力**に
`KILL_WHEN`（すべて満たすときだけ kill してよい）と `KILL_COMMAND`（コピーして実行）が
改行付きで出る。pwsh の ConciseView は例外メッセージの改行を空白にするため、判断材料は
例外本文ではなくその出力を使う。JSON には `killWhen` / `killCommand` / `killConfirm` もある。

- 列挙 PID は subject の `--user-data-dir` を持つ Cursor root、または candidate WSL の
  `.cursor-server` である
- controller Cursor（`--user-data-dir` 無し）の PID は含まれていない
- その subject session を破棄してよい

`runtime-fingerprint-mismatch` のときは KILL は出ない。DETAIL の `lock=` / `now=` と
`RELOCK_COMMAND` を使う。RELOCK は lock を書き換えるだけで Cursor は起動しない。
確認は `-Stage handoff`（`-Execute` なし）。`-Execute` は新しい subject 窓が欲しいときだけ。

実行後:

```powershell
.\wrapper\Get-CursorHandoffInventory.ps1 -Instance candidate
```

root の commandLine に subject user-data-dir が無く、`remote` が `[]` になってから、
新しい subject 窓が必要なときだけ `handoff -Execute` する。live smoke が既に通っていれば
再起動は不要。fingerprint のあとは RELOCK → DryRun で止める。
