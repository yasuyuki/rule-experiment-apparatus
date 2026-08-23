# Local OpenCode CLI

This directory pins the local OpenCode CLI only. It does not contain
credentials, OpenCode configuration, authentication state, sessions, or logs.

Install the locked dependency from the repository root:

```powershell
npm ci --prefix .\tools\opencode-policy
```

Connect OpenRouter interactively if it is not already connected. Enter the key
only in OpenCode's user-local prompt; never put it in this repository:

```powershell
.\tools\opencode-policy\node_modules\.bin\opencode.cmd
```

Run OpenCode with the model explicit for every invocation:

```powershell
.\tools\opencode-policy\node_modules\.bin\opencode.cmd --model openrouter/stealth/ox-alpha
```

Run the credential-free static policy check (the portable CI contract):

```powershell
.\tools\opencode-policy\Test-OpenCodePolicy.ps1
```

After `npm ci`, run the optional live preflight to verify the local CLI,
authenticated provider name, and model availability. It never falls back to a
different model:

```powershell
.\tools\opencode-policy\Test-OpenCodePolicy.ps1 -Live
```

`node_modules` and all OpenCode user data remain untracked. The verifier never
prints or stores credential values, authentication files, sessions, or logs.
