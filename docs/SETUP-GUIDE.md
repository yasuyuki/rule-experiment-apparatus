# Setup guide

Install Python 3.10+, Git, Bash, and dependencies from `apparatus/requirements.txt`. For a Windows
controller, install a WSL distro and use the WSL executor. On POSIX, use the local executor.

Copy `apparatus/schemas/environment.example.json` to a private control repository and set:

- `executor` to WSL or local POSIX;
- `variantSourceRoot` to the private, versioned experiment source repository;
- `stableRules.root` and `stableRules.branch` to the stable rule-source repository;
- `subjects.<id>.configTemplate` to an authenticated private template readable by the executor.

Do not commit credentials or config templates to this public repository. Verify setup with:

```console
python3 apparatus/cycle.py --environment <environment.json> --selfcheck
python3 apparatus/docs_check.py
python3 apparatus/tests/test_cycle.py
```
