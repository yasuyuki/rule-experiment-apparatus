# Codex partial policy

`Sync-CodexPolicy.ps1` owns only `[agents]`, selected
`[projects.'<path>'].trust_level`, and the four files in `agents/`. It preserves
all other `config.toml` keys and does not read or write `auth.json`.

Check before changing anything:

```powershell
.\tools\codex-policy\Sync-CodexPolicy.ps1 -CodexHome $env:CODEX_HOME -Project (Get-Location).Path
```

Apply the declared keys and profiles only after reviewing drift:

```powershell
.\tools\codex-policy\Sync-CodexPolicy.ps1 -CodexHome $env:CODEX_HOME -Project (Get-Location).Path -Apply
```

For WSL, call the same script with PowerShell 7 and the Linux `CODEX_HOME` and
workspace path. Do not put credentials, plugins, MCP servers, UI preferences,
sandbox settings, notification settings, or machine-specific paths in
`policy.psd1`.
