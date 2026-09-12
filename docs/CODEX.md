# Codex subject adapter

The `codex` descriptor uses the public `agent-rules` `place.py start` entry point
for its emitted launch command.  Its opaque environment profile has these exact
keys; all paths are supplied by the private environment descriptor. The emitted
launch and runtime token contain workspace/config paths, so reviews belong in
the private control repository. The authentication source path is not returned.

```json
{
  "binary": "/absolute/path/to/codex",
  "configTemplate": "/absolute/path/to/codex-template",
  "authSource": "/absolute/path/to/auth.json",
  "telemetryPython": "/absolute/path/to/telemetry-python",
  "telemetrySource": "/absolute/path/to/agent-telemetry",
  "telemetryDb": "/absolute/path/outside-git/events.sqlite3",
  "endpoint": "http://127.0.0.1:4318/v1/logs",
  "launchArgv": ["python3", "/absolute/path/to/agent-rules/bin/place.py", "start", "--declaration", "/absolute/path/to/PLACEMENT.md", "--rules", "/absolute/path/to/rules", "W1", "codex", "--"]
}
```

`prepare` copies the template to an arm-specific `CODEX_HOME`, links the private
`auth.json`, applies and checks the variant placement, and returns a launch command
with the same loopback OTLP settings for every arm.  Start `agent-telemetry serve`
manually with the profile DB before either arm.  The DB must be outside the Git
workspace.  No service or wrapper is installed by the adapter.

Run each arm as a fresh top-level Codex session.  `collect` selects exactly one
native `sessions/**/*.jsonl` whose `session_meta` has the arm workspace and is
neither resumed nor a subagent.  It records only that session ID, the marker count,
and `task_complete` count.  It never copies native transcript bodies.

The telemetry query runs with the configured collector Python, reads SQLite
read-only, and stores the allowlisted Record rows with event counts and missing
field counts.  Zeros stay zero.  Token values are event values and are not summed.
An unavailable DB or query is recorded as auxiliary telemetry status; native task
completion and rule marker observation remain separate observations.

The collector identity records the installed package version and SHA-256 of every
Python source file, checked against `telemetrySource`. Keep the external profile
and installed collector unchanged from receiver startup through both collections.
The adapter does not lock those external resources or authenticate the receiver.

Run the synthetic adapter checks from this repository on POSIX. Set
`AGENT_TELEMETRY_PYTHON` to the installed collector's Python and
`AGENT_TELEMETRY_SOURCE` to its source checkout, then run
`python3 apparatus/tests/test_codex_adapter.py`. Without both variables the test
explicitly skips real collector integration; that run alone does not prove the
telemetry contract. The collector repository's own tests remain required.

Use `python3 apparatus/tests/test_codex_adapter.py --require-collector` for the
required integration path; missing either variable fails before the checks run.
CI keeps the dependency-free adapter checks in the apparatus job and installs a
pinned public collector in a separate job, runs its tests, then requires the real
collector checks (including installed source identity). This does not prove a
live Codex session or a rule effect.

## Verified connectivity (2026-09-08)

Linux, Python 3.14.4, Codex CLI 0.153.4 and agent-telemetry 0.1.0 were used for
two sequential fresh sessions. Both used the same config identity and adapter
identity; treatment differed only by an inert rule comment. Each ran the same
harmless `printf` task, produced and committed the expected result, emitted its
rule marker, and completed once. The adapter's exact native workspace/session
selection agreed with the CLI thread IDs.

| Observation | Control | Treatment |
| --- | ---: | ---: |
| Received records | 13 | 15 |
| Tool result events (all successful, with duration) | 3 | 4 |
| Token events | 3 | 3 |
| Missing upstream total-token values | 13 | 15 |

The commit shell commands were grouped differently, explaining the different
tool-event counts; counts are not operation counts or a rule-effect finding.
Tokens were retained per event, without a usage sum. Installed collector source
hashes agreed between arms. Both task criteria were met, so the existing core
recorded `reject` with only `no attributable effect`; no promotion was attempted.
The initial identical-byte declaration was terminated before execution because
the core requires different variant digests.

After the receiver stopped, a separate collector process reread both sessions
and matched the saved review records exactly. The review remained unchanged and
the core removed its temporary adapter state. Native message bodies were not
copied into collection evidence. Profiles, raw native logs, SQLite data, and
private session IDs are not distributed with this repository.

The README POSIX checks, the configured Codex adapter tests, and the collector's
22 existing tests passed. Resume, subagents, Windows, long-running collection,
real receiver failure, and nonzero reasoning/cache-write tokens are not live
validated. Missing/corrupt DB, missing/zero values, mixed sessions and platforms,
unknown events, malformed native data, user-only markers, resumed turns, and
snapshot rereads are covered synthetically. This proves connectivity for the
observed configuration, not rule effectiveness or billing reconstruction.
