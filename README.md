# Rule Experiment Apparatus

Public alpha source for a two-arm agent-rule experiment apparatus and its
transactional workspace wrappers. Runtime state, credentials, experiment
results, archives, and private environment descriptors are intentionally kept
outside this repository.

OpenCode is an optional reproducible development tool. It is not a subject,
plugin, or runtime dependency of the apparatus.

## Quick start

Create a private environment descriptor from
[`apparatus/schemas/environment.example.json`](apparatus/schemas/environment.example.json),
then keep it outside the checkout. Its parent is the private control root;
`agentRulesRoot` may be absolute or relative to that descriptor.

```console
python3 -m pip install -r apparatus/requirements.txt
python3 apparatus/cycle.py --environment <private-control>/apparatus-environment.json --selfcheck
```

PowerShell wrapper checks:

```powershell
.\wrapper\Invoke-FoundationTests.ps1 -Suite portable
```

OpenCode static policy check:

```powershell
.\tools\opencode-policy\Test-OpenCodePolicy.ps1
```

Use `-Live` only after `npm ci --prefix .\tools\opencode-policy`; it checks the
configured provider and the exact model without displaying credentials or
falling back to another model.

## Documentation

| Document | Purpose |
|---|---|
| [`CONSTITUTION.md`](CONSTITUTION.md) | Normative invariants |
| [`TERMS.md`](TERMS.md) | Shared vocabulary |
| [`apparatus/README.md`](apparatus/README.md) | Cycle apparatus commands and data model |
| [`docs/RULE-EXPERIMENT.md`](docs/RULE-EXPERIMENT.md) | Current experiment specification |
| [`docs/ARM-SCOPE.md`](docs/ARM-SCOPE.md) | Workload scope gate |
| [`docs/CYCLE-RECORD-CRITERIA.md`](docs/CYCLE-RECORD-CRITERIA.md) | Record acceptance criteria |
| [`docs/EXECUTION-UNIT.md`](docs/EXECUTION-UNIT.md) | Execution-unit identity |
| [`docs/REVIEW-CRITERIA.md`](docs/REVIEW-CRITERIA.md) | Review criteria |
| [`docs/COMMANDS.md`](docs/COMMANDS.md) | Command reference |
| [`docs/SETUP-GUIDE.md`](docs/SETUP-GUIDE.md) | Setup guide |
| [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md) | Operator guide |
| [`docs/templates/measurement-brief.md`](docs/templates/measurement-brief.md) | Neutral measurement template |
| [`wrapper/README.md`](wrapper/README.md) | Transactional wrapper reference |
| [`wrapper/config/README.md`](wrapper/config/README.md) | Private configuration boundary |
| [`tools/codex-policy/README.md`](tools/codex-policy/README.md) | Credential-free Codex policy tooling |
| [`tools/opencode-policy/README.md`](tools/opencode-policy/README.md) | Credential-free OpenCode tool policy |

### Historical

Historical experiment records and incident reports are not published in this
repository.

## License

MIT. See [`LICENSE`](LICENSE).
