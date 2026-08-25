# Rule Experiment Apparatus

`apparatus/cycle.py` is the single public apparatus for materializing, handing off, judging,
promoting, rolling back, freezing, and estimating agent-rule experiments. Runtime records,
authenticated config templates, private paths, and credentials stay outside this repository.

```console
python3 -m pip install -r apparatus/requirements.txt
python3 apparatus/cycle.py --selfcheck
python3 apparatus/tests/test_cycle.py
```

Normal commands require `--environment <private-environment.json>`.

## Documentation

| Document | Purpose |
|---|---|
| [`CONSTITUTION.md`](CONSTITUTION.md) | Purpose and invariants |
| [`TERMS.md`](TERMS.md) | Canonical vocabulary |
| [`docs/IMPROVEMENT-POLICY.md`](docs/IMPROVEMENT-POLICY.md) | Core boundary and improvement rule |
| [`docs/RULE-EXPERIMENT.md`](docs/RULE-EXPERIMENT.md) | Experiment protocol |
| [`docs/EXECUTION-UNIT.md`](docs/EXECUTION-UNIT.md) | Session ownership and provenance |
| [`docs/ARM-SCOPE.md`](docs/ARM-SCOPE.md) | Workload scope |
| [`docs/REVIEW-CRITERIA.md`](docs/REVIEW-CRITERIA.md) | Review and promotion decision |
| [`docs/CYCLE-RECORD-CRITERIA.md`](docs/CYCLE-RECORD-CRITERIA.md) | Cycle record contract |
| [`docs/COMMANDS.md`](docs/COMMANDS.md) | Command reference |
| [`docs/SETUP-GUIDE.md`](docs/SETUP-GUIDE.md) | Private setup |
| [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md) | Operator workflow |
| [`docs/templates/measurement-brief.md`](docs/templates/measurement-brief.md) | Measurement brief template |
| [`apparatus/README.md`](apparatus/README.md) | Schemas and implementation boundary |

### Historical

Historical records remain in private control repositories and Git history; no legacy runtime is
shipped here.

## License

MIT. See `LICENSE`.
