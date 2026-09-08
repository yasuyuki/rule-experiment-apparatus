import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "apparatus" / "subjects" / "codex.py"
spec = importlib.util.spec_from_file_location("codex_adapter", ADAPTER)
codex = importlib.util.module_from_spec(spec)
spec.loader.exec_module(codex)

descriptor = json.loads((ROOT / "apparatus" / "subjects" / "codex.json").read_text())
assert descriptor["adapter"]["sha256"] == hashlib.sha256(ADAPTER.read_bytes()).hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


with tempfile.TemporaryDirectory(prefix="codex-adapter-") as raw:
    temp = Path(raw)
    workspace = temp / "arm"
    workspace.mkdir()
    config = temp / "config"
    session = config / "sessions" / "2026" / "01" / "01" / "rollout.jsonl"
    marker = "[rule-experiment-loaded:fixture:control]"
    write(session, json.dumps({"type": "session_meta", "payload": {
        "id": "fresh.session", "cwd": str(workspace), "source": None}}) + "\n")
    with session.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": marker}]}}) + "\n")
        handle.write(json.dumps({"type": "event_msg", "payload": {"type": "task_started"}}) + "\n")
        handle.write(json.dumps({"type": "event_msg", "payload": {"type": "task_complete"}}) + "\n")
    selected, error = codex.native_session({"configRoot": str(config), "workspace": str(workspace)})
    assert error is None and selected[1] == "fresh.session"
    assert codex.native_observation(selected[0], marker) == (1, 1, 1)

    # A second eligible file is never guessed from timestamps or file order.
    write(config / "sessions" / "other.jsonl", json.dumps({"type": "session_meta", "payload": {
        "id": "other", "cwd": str(workspace), "source": None}}) + "\n")
    assert codex.native_session({"configRoot": str(config), "workspace": str(workspace)})[1] == "ambiguous"

    # Subagents and resumes are excluded even when their workspace agrees.
    (config / "sessions" / "other.jsonl").unlink()
    write(config / "sessions" / "child.jsonl", json.dumps({"type": "session_meta", "payload": {
        "id": "child", "cwd": str(workspace), "source": {"subagent": {}}}}) + "\n")
    assert codex.native_session({"configRoot": str(config), "workspace": str(workspace)})[1] == "unsupported-child"

    mismatch = temp / "mismatch"
    write(mismatch / "sessions" / "one.jsonl", json.dumps({"type": "session_meta", "payload": {
        "id": "wrong-workspace", "cwd": str(temp / "elsewhere"), "source": "cli"}}) + "\n")
    assert codex.native_session({"configRoot": str(mismatch), "workspace": str(workspace)})[1] == "missing"
    malformed = temp / "malformed"
    write(malformed / "sessions" / "bad.jsonl", "not-json\n[]\n")
    assert codex.native_session({"configRoot": str(malformed), "workspace": str(workspace)})[1] is not None
    user_only = temp / "user-only.jsonl"
    write(user_only, json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user",
        "content": [{"type": "output_text", "text": marker}]}}) + "\n")
    assert codex.native_observation(str(user_only), marker)[0] == 0

    # Body strings never enter telemetry evidence: only fixed Record columns do.
    db = temp / "events.sqlite3"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE records (id INTEGER PRIMARY KEY, schema_version INTEGER NOT NULL, platform TEXT NOT NULL, event_name TEXT NOT NULL, occurred_at_ns INTEGER, received_at_ns INTEGER NOT NULL, session_id TEXT, model TEXT, cli_version TEXT, tool_name TEXT, success INTEGER, duration_ms REAL, input_tokens INTEGER, output_tokens INTEGER, cached_input_tokens INTEGER, cache_write_tokens INTEGER, reasoning_output_tokens INTEGER, total_tokens INTEGER)")
    con.execute("CREATE INDEX records_session_time ON records(session_id, occurred_at_ns)")
    con.execute("CREATE INDEX records_time ON records(occurred_at_ns)")
    con.execute("PRAGMA user_version=1")
    con.execute("INSERT INTO records (schema_version,platform,event_name,received_at_ns,session_id,input_tokens) VALUES (1,'codex','codex.tool_result',1,'fresh.session',0)")
    con.commit(); con.close()
    profile = {"telemetryPython": sys.executable,
               "telemetrySource": str(temp / "missing-collector"), "telemetryDb": str(db)}
    # Python package metadata may be absent in an isolated test runner, but DB failures
    # remain auxiliary and are represented without exception bodies.
    observed = codex.telemetry(profile, "fresh.session")
    assert observed["status"] in ("available", "unavailable")
    if observed["status"] == "available":
        assert observed["records"][0]["input_tokens"] == 0
        assert "body" not in json.dumps(observed)

    # Exercise the adapter boundary end-to-end: prepare creates the isolated arm
    # home, then collect reads the native session and collector DB it named.
    variant = temp / "variant"
    write(variant / "rules" / "demo.rule.md", "# demo\n")
    write(variant / "placement.json", "{}\n")
    write(variant / "bin" / "rules.py", '''import os, sys
workspace = sys.argv[2]
target = os.path.join(workspace, "AGENTS.md")
if sys.argv[1] == "render":
    open(target, "w", encoding="utf-8").write("# rules\\n")
elif sys.argv[1] == "verify":
    raise SystemExit(0 if os.path.isfile(target) else 1)
else: raise SystemExit(2)
''')
    binary = temp / "codex"
    write(binary, "#!/bin/sh\necho fixture-codex\n")
    binary.chmod(0o755)
    template, auth, trial = temp / "template", temp / "auth.json", temp / "trial"
    template.mkdir(); trial.mkdir(); write(template / "config.toml", "")
    write(auth, "fixture")
    launch_profile = json.dumps({"binary": str(binary), "configTemplate": str(template),
        "authSource": str(auth), "telemetryPython": sys.executable,
        "telemetrySource": str(temp / "missing-collector"), "telemetryDb": str(db),
        "endpoint": "http://127.0.0.1:4318/v1/logs", "launchArgv": ["true"]})
    prepared = codex.prepare({"protocolVersion": 1, "cycle": "whole", "arm": "control",
        "workspace": str(trial), "configRoot": str(temp / "homes"),
        "variant": {"path": str(variant), "digest": codex.tree_digest(str(variant), codex.MANAGED)},
        "workload": {"path": "unused", "digest": "0" * 64}, "materials": [],
        "profile": launch_profile}, "identity")
    session_path = Path(prepared["token"]["configRoot"]) / "sessions" / "whole.jsonl"
    write(session_path, "\n".join(json.dumps(item) for item in (
        {"type": "session_meta", "payload": {"id": "whole.session", "cwd": str(trial), "source": "cli"}},
        {"type": "event_msg", "payload": {"type": "task_started"}},
        {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": prepared["token"]["marker"]}]}},
        {"type": "event_msg", "payload": {"type": "task_complete"}},
    )) + "\n")
    collected = codex.collect({"protocolVersion": 1, "workspace": str(trial),
                               "profile": launch_profile, "token": prepared["token"]}, "identity")
    assert collected["success"] and collected["ruleLoaded"]
    with session_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps({"type": "event_msg", "payload": {"type": "task_started"}}) + "\n")
    resumed = codex.collect({"protocolVersion": 1, "workspace": str(trial),
                             "profile": launch_profile, "token": prepared["token"]}, "identity")
    assert not resumed["success"] and resumed["evidence"]["nativeSession"]["status"] == "resumed"

    configured_python = os.environ.get("AGENT_TELEMETRY_PYTHON")
    configured_source = os.environ.get("AGENT_TELEMETRY_SOURCE")
    if configured_python and configured_source:
        con = sqlite3.connect(db)
        con.execute("INSERT INTO records (schema_version,platform,event_name,received_at_ns,session_id,input_tokens,success) VALUES (1,'codex','codex.api_request',2,'fresh.session',0,NULL)")
        con.execute("INSERT INTO records (schema_version,platform,event_name,received_at_ns,session_id) VALUES (1,'codex','unknown.event',3,'fresh.session')")
        con.execute("INSERT INTO records (schema_version,platform,event_name,received_at_ns,session_id) VALUES (1,'other','codex.tool_result',4,'fresh.session')")
        con.execute("INSERT INTO records (schema_version,platform,event_name,received_at_ns,session_id) VALUES (1,'codex','codex.tool_result',5,'other.session')")
        con.commit(); con.close()
        configured = codex.telemetry({"telemetryPython": configured_python,
            "telemetrySource": configured_source, "telemetryDb": str(db)}, "fresh.session")
        assert configured["status"] == "available", configured
        assert len(configured["records"]) == 2
        assert {item["event_name"] for item in configured["records"]} == {"codex.tool_result", "codex.api_request"}
        assert all(item["session_id"] == "fresh.session" for item in configured["records"])
        assert any(item["input_tokens"] == 0 and item["success"] is None for item in configured["records"])
        assert codex.telemetry({"telemetryPython": configured_python, "telemetrySource": configured_source,
                                "telemetryDb": str(db)}, "absent.session")["status"] == "empty"
        snapshot = json.dumps(collected, sort_keys=True)
        con = sqlite3.connect(db); con.execute("DELETE FROM records"); con.commit(); con.close()
        assert json.dumps(collected, sort_keys=True) == snapshot
        missing = temp / "missing.sqlite3"
        assert codex.telemetry({"telemetryPython": configured_python, "telemetrySource": configured_source,
                                "telemetryDb": str(missing)}, "fresh.session")["status"] == "unavailable"
        assert not missing.exists()
        corrupt = temp / "corrupt.sqlite3"; corrupt.write_text("not sqlite", encoding="utf-8")
        assert codex.telemetry({"telemetryPython": configured_python, "telemetrySource": configured_source,
                                "telemetryDb": str(corrupt)}, "fresh.session")["status"] == "unavailable"
    else:
        print("SKIP: configured collector checks require AGENT_TELEMETRY_PYTHON and AGENT_TELEMETRY_SOURCE")

print("codex adapter synthetic checks passed")
