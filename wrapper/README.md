# Cursor instance wrappers

These wrappers select the Windows Cursor namespace, WSL distro/user, and project
target as one physical instance. Runtime state fixes `baseline` to `stable` and
`run` to `candidate`; transitions never swap those physical roles.

This file is for people changing the wrappers. Operator documentation lives
elsewhere:

- [`../docs/SETUP-GUIDE.md`](../docs/SETUP-GUIDE.md): prepare a new machine.
- [`../docs/USER-GUIDE.md`](../docs/USER-GUIDE.md): day-to-day operation.
- [`../docs/COMMANDS.md`](../docs/COMMANDS.md): every command, argument, and
  output field.
- [`config/README.md`](config/README.md): file ownership between this
  implementation repository and the control-plane repository.
- [`../CONSTITUTION.md`](../CONSTITUTION.md): purpose, non-goals, and invariants.
- [`../TERMS.md`](../TERMS.md): canonical terminology.

## Layout

| Path | Responsibility |
| --- | --- |
| `Invoke-FoundationRelease.ps1` | The only operator entry point for release transitions. |
| `cursor-*.ps1` | Launchers. `cursor-instance.ps1` holds the shared logic. |
| `Get-CursorHandoffInventory.ps1` | Read-only Cursor root/window/Remote WSL snapshot used by verified handoff. |
| `Get-SubjectRuntimeFingerprint.ps1` | Read-only subject runtime fingerprint used to prepare ignored `runtime.lock`. |
| `Get-Foundation*.ps1` | Read-only reporting. |
| `Test-*.ps1` | Verification, from portable fixtures to live acceptance. |
| `lib/Configuration.ps1` | Config/state path resolution and environment schema. `storage.localDataRoot` is the Windows path of the shared store. |
| `lib/LocalData.ps1` | `Get-LocalDataStatus`: live-channel inspection that feeds `local-data-drift` / `local-data-unavailable`. |
| `lib/ReleaseState.ps1` | Release state contract, locking, atomic replace. |
| `lib/RepositoryDiscovery.ps1` | Workspace snapshots and repository discovery. |
| `lib/Presentation.ps1` | Blockers, remediation text, and text formatting. |
| `lib/Result.ps1` | Success/failure envelope and sub-script composition. |
| `lib/ReleaseReview.ps1` | Change-area classification for release diff paths. |
| `schemas/` | JSON Schema for the environment config and release state. |
| `config/*.example.json` | Public templates. The live files belong elsewhere. |

## Conventions

**Failure reporting.** Entry points (`Invoke-FoundationRelease.ps1`,
`Get-Foundation*.ps1`) install a `trap` that emits
`{"ok": false, "command", "message"}` and exits 1. Library code and composed
sub-scripts keep throwing under `$ErrorActionPreference = 'Stop'`: fail-fast is
what stops a release transition half way through.

**Exit codes.** A PowerShell script that never calls `exit` leaves
`$LASTEXITCODE` set by whatever native command it last ran. `pgrep` exiting 1
because an instance is idle is a healthy result, not a failure. Entry points
therefore end with an explicit `exit 0`, and `Invoke-FoundationJsonScript`
deliberately does not inspect `$LASTEXITCODE` of composed PowerShell scripts.

**Talking to WSL.** `wsl.exe` rebuilds its argument list into a command string
for the login shell, so neither argv nor a nested `bash -c '...'` preserves
quoting — `bash -c 'echo $0' NAME` reports the login shell, not `NAME`. Send
scripts on stdin instead (`Invoke-WslRepositoryBatch` does this), remembering
that PowerShell appends CRLF to a piped string; the batch script ends with a
comment line to absorb the stray carriage return. Interpolate paths only through
`ConvertTo-PosixSingleQuoted`. Do not capture native stderr with PowerShell
`2>&1` under `$ErrorActionPreference='Stop'`: Windows PowerShell 5.1 turns it
into `NativeCommandError` and aborts (pwsh 7 does not). Merge stderr inside WSL
instead (`Get-LocalDataStatus` and seed's `local-data.sh pull`).

**Local data.** The store's physical copy is `storage.localDataRoot` (a literal
Windows absolute path; do not use `%USERPROFILE%`). Each WSL home's
`~/local-data` is a symlink to that store, so stable and candidate see the same
bytes. Seed restores gitignored files with `local-data.sh pull` on the target
instance. `status` / `doctor` check baseline and run only: missing or
differing MANIFEST entries are `local-data-drift`, an unreadable store is
`local-data-unavailable`. Manual pull is recovery, not the promote path.

**One workspace inspector.** `Get-ReleaseWorkspaceSnapshot` is the single
implementation of "what does this release contain". Acceptance, status,
version, and inventory all call it, so they cannot disagree. A single
`wsl.exe` launch costs roughly 0.25s, so it batches all repositories of a
workspace into one shell.

**Isolation contract.**

- Stable inherits the real Windows `USERPROFILE` and default Cursor user-data.
- Candidate gets its dedicated process-local `USERPROFILE` and `--user-data-dir`.
  Its `USERPROFILE` must contain `AppData\Roaming` or Cursor exits immediately.
- Isolation-owned Windows paths are relative to `environment.json`; they never
  expand process-local `USERPROFILE`, so every Cursor profile resolves the same
  user-data, extensions, backup, verification, and Windows project locations.
- WSL targets are validated against the distro's default Linux user before launch.
- Every WSL launch passes `--classic`; Cursor 3 Agents/Glass windows do not
  reliably activate Remote WSL.
- Versioned foundation rules must be project/worktree scoped. Do not store them
  in cloud User Rules, which synchronize across Cursor instances on one account.
- The wrapper never changes a global Windows environment variable, the WSL
  default distro, or stable Cursor files.

## Test boundary

Run suites through one entry point. Individual `Test-*.ps1` scripts remain
callable. Scripts resolve via `$PSScriptRoot`, so the working directory does
not have to be `wrapper/`. `-Suite all` skips `Test-Wrappers.ps1` and
`Test-FoundationTransitions.ps1` because `Test-FoundationSystem.ps1` already
runs them.

```powershell
.\Invoke-FoundationTests.ps1
.\Invoke-FoundationTests.ps1 -Suite live -ConfigPath <env.json> -StatePath <state.json>
.\Invoke-FoundationTests.ps1 -Suite all -ArchiveRoot <private-archives> -ConfigPath <env.json> -StatePath <state.json>
.\Invoke-FoundationTests.ps1 -Suite all -Quick -ArchiveRoot <private-archives> -ConfigPath <env.json> -StatePath <state.json>
```

`portable` (default) uses temporary fixtures and does not launch Cursor, invoke
WSL, read live state, or write backups. `live` needs a configured environment and
WSL, but does not mutate live state. `all` adds full system acceptance, which
hash-checks every backup and restores the live baseline/run snapshot plus
`previousBaseline`. `-Quick` skips those restores and the transition fixture.
Incident B-D fail-closed coverage is in `portable` plus the live handoff DryRun.
Incident A is the role-gate, not a wrapper test.
`Test-VerifiedHandoffLive.ps1 -Execute` is the explicit GUI smoke and is not in
any suite; it refuses to launch when the subject profile or Remote WSL is occupied.

`Test-WorkspaceRelease.ps1`、`Test-FoundationReleaseUx.ps1`、`Test-LocalDataStore.ps1` は live
configuration を読み、live config／state の hash が変わらないことを確認します。

## Changing the release state contract

`lib/ReleaseState.ps1` and `schemas/release-state.schema.json` describe the same
contract and must be changed together; `Test-Configuration.ps1` covers the
rejection cases. Each transition action carries a different payload on purpose:

| action | required fields |
| --- | --- |
| `bootstrap`, `promote`, `rollback`, `migrate-runtime-model` | `from`, `to`, `commit` |
| `seed` | `release`, `commit` |

## Changing the release review contract

`lib/ReleaseReview.ps1` (`Assert-FoundationReviewRecordShape`) and
`schemas/release-review.schema.json` describe the same review record shape and
must be changed together. Judgment semantics live in
[`../docs/REVIEW-CRITERIA.md`](../docs/REVIEW-CRITERIA.md);
`Test-ReleaseReview.ps1` covers the rejection cases and the
`Test-FoundationReviewGate` truth table. `config/release-review.example.json`
must keep passing `Assert-FoundationReviewRecordShape -RequireIntentComplete`
and must not contain real user names, distro names, or absolute paths. Review
records live outside this repository, in
`private-control/reviews/<release>.json` (`Resolve-ReviewRoot` resolves
the directory); `Test-FoundationReview.ps1` reads whatever that resolves to
and reports each record's shape without writing anything, and is safe to run
even when `reviews/` does not exist yet.

A record moves through three states as it is filled in, and
`Assert-FoundationReviewRecordShape` validates it at two levels depending on
which state it claims to be in:

| state | `late` | `intent.goal`/`successCriteria` | `review` | intent completeness required? |
| --- | --- | --- | --- | --- |
| draft | `true` | empty or partial | `null` | no (default) |
| intent-recorded | `false` | fully populated | `null` | yes (because `late:false`) |
| reviewed | any | fully populated | non-null | yes (because `review` is set) |

Concretely, `Assert-FoundationReviewRecordShape -Record $r -Context '...'`
accepts a draft record by default; pass `-RequireIntentComplete` to demand a
complete intent regardless of state, or rely on the record itself demanding
it (`review` non-null, or `late:false`). `Read-FoundationReviewRecord` takes
the same `-RequireIntentComplete` switch and forwards it. `late` has one
fixed meaning: **it is `false` only when `review-init` recorded the intent
itself (`-Goal`/`-SuccessCriteria` both supplied) at the moment the run root
HEAD equaled `baseCommit` and every declared nested repository HEAD
still equaled that child's `baseCommit`.** Any argument omitted at `review-init` time, or
any HEAD that has already moved past `baseCommit`, produces `late:true` — and
filling in `goal`/`successCriteria` by hand afterwards does not change that;
`late` records how the intent was recorded, not whether it currently looks
complete. `Get-FoundationReviewInitPlan` and `Test-FoundationReviewGate`
(`intentComplete` field) are the two pure functions that encode this; both
are unit-tested without a live release.
