# Setup guide

Install Python 3.10+, Git, Bash, and dependencies from `apparatus/requirements.txt`. For a Windows
controller, install a WSL distro and use the WSL executor. On POSIX, use the local executor.

Copy `apparatus/schemas/environment.example.json` to a private control repository and set:

- `executor` to WSL or local POSIX;
- `variantSourceRoot` to the private, versioned experiment source repository;
- `stableRules.root` and `stableRules.branch` to the stable rule-source repository;
- `subjects.<id>.configTemplate` to an authenticated private template readable by the executor;
- `subjects.<id>.credentialStore` (optional) to an absolute path outside `$HOME/releases` holding
  the subject's rotating credential files, one per entry in the subject descriptor's
  `credentialPaths`. If omitted, no credential is placed in the config root (suitable only for
  subjects authenticated by a non-rotating credential such as an API key).

The config template must be a complete config that can start non-interactively; it does not need
to include the rotating credential listed in `credentialPaths` (that credential is symlinked in
from `credentialStore` at handoff time instead). Do not point the template at a live config root
that the subject, or any other process, still writes to.

Every entry in `credentialPaths` must resolve inside the isolated config root (e.g.
`$CLAUDE_CONFIG_DIR/.claude.json`, not `$HOME/.claude.json`), because some subjects keep account
state outside the isolation-env-scoped directory tree by default and ignore a copy left at the
real `$HOME`. Verified for claude-code 2026-08-25: with `CLAUDE_CONFIG_DIR` set, the CLI reads
account state from `<configTemplate>/.claude.json`, not `$HOME/.claude.json`; a config template
missing that file starts every session at the login screen regardless of credential validity. Make
it reachable at `<configTemplate>/.claude.json` (for example, a symlink to the real `$HOME/.claude.json`)
before pointing `configTemplate` there.

Verified for cursor-agent 2026-08-25: `isolationEnv` for this subject is `XDG_CONFIG_HOME`, but the CLI
reads its config from `$XDG_CONFIG_HOME/cursor/...`, not from `$XDG_CONFIG_HOME` directly. The config root
`cycle.py` builds is a flat directory (no `cursor/` prefix), so `credentialPaths` must include that prefix
(`cursor/auth.json`, not `auth.json`) and `configTemplate`/`credentialStore` must be set accordingly
(`credentialStore` pointed at the parent of the real `~/.config/cursor`, not at that directory itself, so
the store path plus the `credentialPaths` entry lands on the real credential file). A flat `credentialPaths`
entry silently resolves to a path cursor-agent never reads, which reports "Not logged in" despite a valid
symlinked credential.

Do not commit credentials or config templates to this public repository. Verify setup with:

```console
python3 apparatus/cycle.py --environment <environment.json> --selfcheck
python3 apparatus/docs_check.py
python3 apparatus/tests/test_cycle.py
```
