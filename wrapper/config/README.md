# Environment configuration

`environment.example.json` and `release-state.example.json` are public templates
for the implementation repository. The completed `environment.json` and its
matching `release-state.json` belong in a separate, independent Git repository
such as `private-control`; they are not tracked in this directory.

## environment.json

Environment configs require `schemaVersion` 2 and `workspace.repositories`:
explicit project repos under each release workspace root (`relativePath` +
expected `origin`). Schema 1 and schemaVersion-less `instances.json` shapes are
rejected.

`relativePath` values are POSIX paths relative to the workspace root. Absolute
paths, `.`, `..`, empty segments, duplicates, and empty origins are rejected.
Do not list `.` for the root foundation repo; release state already names it.

Two entries may share an `origin`. In the template, `example-app` and
`example-app-ui` are separate checkouts of the same repository, so both
declare the same expected origin. Acceptance compares each checkout against the
origin declared for it, not against the other entries.

Optional per-instance `releasesRoot` (absolute POSIX path) sets the default parent
for `Initialize-NextFoundation.ps1` when `-Path` is omitted. Prefer
`<wslHome>/releases` so new workspaces are not nested under legacy `projectsRoot`
and do not inherit its `CLAUDE.md` / `.cursor` rules. When unset, the default
remains `<wslHome>/Projects/<name>`. `projectsRoot` stays required for
legacy-source inventory.

`storage.localDataRoot` is the Windows absolute path of the shared gitignored-file
store (literal path; do not use `%USERPROFILE%`). Each WSL home's `~/local-data`
is a symlink to that directory. Seed restores from it; `status` / `doctor` emit
`local-data-drift` / `local-data-unavailable` when a live channel is missing files
or the store cannot be inspected.

## release-state.json

`release-state.example.json` is the starting point for a new machine. It uses
`generation` 0 and a single `bootstrap` transition. `instance` must be `stable`
or `candidate`; any other value is rejected when the state is read, because an
unknown instance would silently disable the runtime guards that depend on it.

Do not hand-edit release generations or history. Use
`Invoke-FoundationRelease.ps1`.

## runtime.lock

`runtime.lock` is an ignored, controller-owned expectation next to
`environment.json`. Verified handoff compares the candidate profile, WSL
identity, Cursor executable, settings, extensions, and skills against it.
The model is a declared value and is reported as `observed:false`.

Create or deliberately refresh it only between experiments, with the subject
profile closed, then review the JSON before using it:

```powershell
.\wrapper\Get-SubjectRuntimeFingerprint.ps1 -Model '<declared-model>' |
  Set-Content -LiteralPath '<control-repo>\runtime.lock' -Encoding utf8
```

Do not commit `runtime.lock`; it contains machine-local absolute paths and
pins one host's runtime.

## Path resolution

Paths owned by the isolation setup are relative to the directory containing
`environment.json`, independent of cwd and process-local `USERPROFILE`. This
applies to instance `userProfile` / `userDataDir` / `extensionsDir`, storage
`backupRoot` / `verificationRoot`, and Windows project targets. These fields
reject absolute paths and `%...%` expansion; use `..\sibling-directory` when the
target is next to the control repository. `cursor.executable` remains a host
lookup and may use environment variables. `storage.localDataRoot` remains the
explicit literal absolute path of the shared store.

Resolution order for config/state/backup paths:

1. explicit parameter (`-ConfigPath` / `-StatePath` / `-BackupRoot`)
2. process environment variable (`FOUNDATION_CONTROL_*`)
3. `environment.local.json` (`configPath` / `statePath` / `backupRoot`)
4. backup only: `environment.json` `storage.backupRoot`

There is no in-repository fallback for release state. A stale state file next to
the implementation would silently route commands at retired releases, so
resolution fails with an explicit error instead.

`environment.local.json` is gitignored machine-local state. The local
`environment.json` and `release-state.json` names under this directory remain
ignored so the two repositories cannot be accidentally merged. Keep Cursor
homes, user data, extension caches, logs, projects, and verification roots
outside the control repository as well.

## Local installation

1. Create or clone a separate Git repository, such as
   a dedicated control repository, and copy `environment.example.json`
   there as `environment.json`.
2. Replace every `<...>` placeholder and verify that candidate
   `userProfile`, `userDataDir`, and `extensionsDir` are dedicated paths.
3. Copy `release-state.example.json` as `release-state.json` and fill in the
   releases that actually exist on this machine.
4. Generate machine-local path pointers with `New-FoundationLocalConfig.ps1`.

The templates are checked by `Test-Configuration.ps1`. The live environment is
checked by `Test-ControlPlaneConfiguration.ps1` and `Test-FoundationSystem.ps1`,
which require WSL, Git repositories, and the configured backup/release state.
