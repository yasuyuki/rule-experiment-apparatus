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
