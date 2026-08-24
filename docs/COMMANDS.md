# Commands

All stateful commands require `--environment <path>`.

| Command | Result |
|---|---|
| `materialize --cycle C` | Clone the declared base and render each arm from its pinned source tree |
| `handoff --cycle C` | Verify comparison inputs; create arm/subject configs and handoff record |
| `transcripts --cycle C` | Report session ownership and commit-span checks without writing review |
| `judge --cycle C [--replace]` | Write execution manifest and schemaVersion 3 review |
| `promote --cycle C` | Write not-promoted, or prepare/test/fast-forward the stable managed source |
| `rollback --cycle C` | Revert the latest recorded promotion if stable HEAD still matches |
| `freeze --cycle C --arm A` | Create a content-addressed frozen input |
| `estimate --frozen H --estimator E --input P` | Record calibrated triage-only estimation |
| `calibrate --cycle C --arm A --estimator E ...` | Establish estimator calibration |
| `--selfcheck` | Run pure schema and invariant checks; environment is optional |

Judges implement `judge --arm ... --workload ... --variant ... --execution <manifest.json>
--baseline ...`. They aggregate any number of subjects and sessions from that manifest.
