#!/usr/bin/env python3
"""Codex subject adapter.  It keeps native transcripts local and projects telemetry."""

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from urllib.parse import urlsplit


MANAGED = ("rules", "placement.json", "bin/rules.py")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_digest(root, items):
    digest = hashlib.sha256()
    for item in items:
        path = os.path.join(root, item)
        if os.path.isdir(path):
            files = []
            for current, dirs, names in os.walk(path):
                dirs.sort()
                files.extend(os.path.join(current, name) for name in sorted(names))
        elif os.path.isfile(path):
            files = [path]
        else:
            raise SystemExit("managed source is missing: %s" % path)
        for filename in files:
            relative = os.path.relpath(filename, root).replace(os.sep, "/")
            digest.update(relative.encode() + b"\0")
            with open(filename, "rb") as handle:
                for chunk in iter(lambda: handle.read(65536), b""):
                    digest.update(chunk)
            digest.update(b"\0")
    return digest.hexdigest()


def config_digest(root):
    return tree_digest(root, tuple(name for name in sorted(os.listdir(root))
                                   if name not in ("sessions", "auth.json")))


def absolute(value, name):
    if not isinstance(value, str) or not value or not os.path.isabs(value):
        raise SystemExit("Codex profile %s must be an absolute path" % name)
    return value


def profile(raw):
    try:
        value = json.loads(raw)
    except (TypeError, ValueError) as exc:
        raise SystemExit("invalid Codex adapter profile: %s" % exc)
    required = {"binary", "configTemplate", "authSource", "telemetryPython", "telemetrySource",
                "telemetryDb", "endpoint", "launchArgv"}
    if not isinstance(value, dict) or set(value) != required:
        raise SystemExit("Codex adapter profile must contain only %s" % ", ".join(sorted(required)))
    for name in required - {"endpoint", "launchArgv"}:
        value[name] = absolute(value[name], name)
    try:
        endpoint = urlsplit(value["endpoint"])
        valid = (endpoint.scheme == "http" and endpoint.hostname in ("127.0.0.1", "::1")
                 and endpoint.port is not None and endpoint.path == "/v1/logs"
                 and not endpoint.username and not endpoint.password
                 and not endpoint.query and not endpoint.fragment)
    except (TypeError, ValueError):
        valid = False
    if not valid:
        raise SystemExit("Codex telemetry endpoint must be a loopback HTTP /v1/logs URL")
    for name in ("launchArgv",):
        if (not isinstance(value[name], list) or not value[name]
                or not all(isinstance(arg, str) and arg for arg in value[name])):
            raise SystemExit("Codex %s must be a non-empty argv array" % name)
    return value


def run(argv, **kwargs):
    return subprocess.run(argv, text=True, capture_output=True, encoding="utf-8", errors="replace", **kwargs)


def renderer(variant, operation, workspace):
    result = run([sys.executable, os.path.join(variant, "bin", "rules.py"), operation, workspace])
    if result.returncode:
        raise SystemExit("variant renderer failed")


def placement(workspace):
    path = os.path.join(workspace, "AGENTS.md")
    if not os.path.isfile(path):
        raise SystemExit("Codex adapter placed no AGENTS.md")
    return [{"path": "AGENTS.md", "sha256": sha256_file(path)}]


def prepare(payload, identity):
    settings = profile(payload["profile"])
    variant, workspace = payload["variant"]["path"], payload["workspace"]
    # Core supplies one subject root.  A child per arm makes native session discovery
    # fresh and prevents config/session state from crossing arms.
    config_root = os.path.join(payload["configRoot"], payload["arm"])
    digest = tree_digest(variant, MANAGED)
    if digest != payload["variant"]["digest"]:
        raise SystemExit("variant digest mismatch")
    if os.path.lexists(config_root):
        raise SystemExit("Codex config root already exists: %s" % config_root)
    shutil.copytree(settings["configTemplate"], config_root, ignore=shutil.ignore_patterns("sessions"))
    if not os.path.isfile(settings["authSource"]):
        raise SystemExit("Codex auth source is missing")
    os.symlink(settings["authSource"], os.path.join(config_root, "auth.json"))
    renderer(variant, "render", workspace)
    marker = "[rule-experiment-loaded:%s:%s]" % (payload["cycle"], payload["arm"])
    with open(os.path.join(workspace, "AGENTS.md"), "a", encoding="utf-8", newline="\n") as handle:
        handle.write("\n<!-- apparatus probe: reply with %s once -->\n" % marker)
    renderer(variant, "verify", workspace)
    version = run([settings["binary"], "--version"])
    subject_version = (version.stdout or version.stderr).strip().splitlines() or ["unknown"]
    config_id = config_digest(config_root)
    otel = '{otlp-http={endpoint="%s",protocol="json"}}' % settings["endpoint"]
    command = ["env", "CODEX_HOME=" + config_root, *settings["launchArgv"], "exec", "--json",
               "-C", workspace, "-c", "otel.log_user_prompt=false", "-c", 'otel.trace_exporter="none"',
               "-c", "otel.metrics_exporter=\"none\"", "-c", "otel.exporter=" + otel]
    return {"protocolVersion": 1, "adapterIdentity": identity, "subjectVersion": subject_version[0],
            "configIdentity": config_id, "variantDigest": digest, "placements": placement(workspace),
            "launch": " ".join(shlex.quote(arg) for arg in command),
            "token": {"workspace": workspace, "configRoot": config_root, "variantPath": variant,
                      "marker": marker, "configIdentity": config_id}}


def native_session(token):
    candidates = []
    sessions = os.path.join(token["configRoot"], "sessions")
    for current, dirs, names in os.walk(sessions):
        dirs.sort()
        for name in sorted(names):
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(current, name)
            try:
                with open(path, encoding="utf-8") as handle:
                    first = json.loads(next(handle))
            except (OSError, StopIteration, ValueError):
                return None, "malformed"
            if not isinstance(first, dict):
                return None, "malformed"
            meta = first.get("payload") if first.get("type") == "session_meta" else None
            if not isinstance(meta, dict) or meta.get("cwd") != token["workspace"]:
                continue
            source = meta.get("source")
            if (meta.get("parent_thread_id") or meta.get("forked_from_id")
                    or meta.get("thread_source") == "subagent"
                    or isinstance(source, dict) and "subagent" in source):
                candidates.append((None, "unsupported-child")); continue
            session_id = meta.get("id") or meta.get("session_id")
            if isinstance(session_id, str) and re.fullmatch(r"[A-Za-z0-9_.:/+\-]+", session_id):
                candidates.append((path, session_id))
            else:
                return None, "invalid-session-id"
    if any(path is None for path, _ in candidates):
        return None, "unsupported-child"
    if len(candidates) != 1:
        return None, "missing" if not candidates else "ambiguous"
    return candidates[0], None


def native_observation(path, marker):
    marker_count = complete = started = 0
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                item = json.loads(line)
            except ValueError:
                return 0, 0, -1
            if not isinstance(item, dict):
                return 0, 0, -1
            payload = item.get("payload")
            if item.get("type") == "event_msg" and isinstance(payload, dict) and payload.get("type") == "task_complete":
                complete += 1
            if item.get("type") == "event_msg" and isinstance(payload, dict) and payload.get("type") == "task_started":
                started += 1
            if item.get("type") == "response_item" and isinstance(payload, dict):
                if payload.get("type") == "message" and payload.get("role") == "assistant":
                    for block in payload.get("content", []):
                        if isinstance(block, dict) and block.get("type") == "output_text":
                            marker_count += str(block.get("text", "")).count(marker)
    return marker_count, complete, started


# Execute inside the configured installed collector, whose bytes are checked against
# its declared source. The adapter descriptor pins this query code too.
COLLECTOR_QUERY = r"""
import dataclasses, hashlib, importlib.metadata, json, pathlib, sys
import agent_telemetry
from agent_telemetry.model import Record
from agent_telemetry.storage import Storage
from agent_telemetry.codex import EVENTS
root = pathlib.Path(agent_telemetry.__file__).parent
source = pathlib.Path(sys.argv[2]) / "src" / "agent_telemetry"
def identity(directory):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(directory.rglob("*.py"))}
installed = identity(root)
if not installed or installed != identity(source):
    raise ValueError("collector source differs from installed package")
records = []
for item in Storage(sys.argv[1], readonly=True).query(session=sys.argv[3]):
    if item.get("platform") != "codex" or item.get("session_id") != sys.argv[3] or item.get("event_name") not in EVENTS:
        continue
    records.append(dataclasses.asdict(Record(**item)))
print(json.dumps({"records": records, "collector": {
    "version": importlib.metadata.version("agent-telemetry"), "filesSha256": installed}}))
"""


def telemetry(settings, session_id):
    try:
        query = run([settings["telemetryPython"], "-I", "-c", COLLECTOR_QUERY,
                     settings["telemetryDb"], settings["telemetrySource"], session_id])
        if query.returncode:
            return {"status": "unavailable", "reason": "collector-query-or-identity-failed"}
        result = json.loads(query.stdout)
        records = result["records"]
        counts = {}
        fields = ("occurred_at_ns", "success", "duration_ms", "input_tokens", "output_tokens",
                  "cached_input_tokens", "cache_write_tokens", "reasoning_output_tokens", "total_tokens")
        missing = {key: sum(record[key] is None for record in records) for key in fields}
        for record in records:
            counts[record["event_name"]] = counts.get(record["event_name"], 0) + 1
        return {"status": "available" if records else "empty", "sessionId": session_id,
                "records": records, "eventCounts": counts, "missing": missing,
                "collector": result["collector"]}
    except (OSError, ValueError, KeyError, TypeError):
        return {"status": "unavailable", "reason": "collector-query-failed"}


def collect(payload, identity):
    token, settings = payload["token"], profile(payload["profile"])
    if payload["workspace"] != token.get("workspace"):
        raise SystemExit("workspace differs from prepare token")
    selected, error = native_session(token)
    evidence = {"nativeSession": {"status": error or "selected"}}
    markers = completed = 0
    if selected:
        path, session_id = selected
        markers, completed, started = native_observation(path, token["marker"])
        if started != 1 or completed > 1:
            selected, error = None, "resumed" if started > 1 or completed > 1 else "incomplete-native-record"
            evidence["nativeSession"] = {"status": error, "taskStartedCount": started}
            evidence["telemetry"] = {"status": "unavailable", "reason": "native-session-" + error}
            return {"protocolVersion": 1, "adapterIdentity": identity, "success": False,
                    "ruleLoaded": False, "evidence": evidence}
        evidence["nativeSession"].update({"id": session_id, "markerCount": markers,
                                           "taskCompleteCount": completed, "taskStartedCount": started})
        evidence["telemetry"] = telemetry(settings, session_id)
    else:
        evidence["telemetry"] = {"status": "unavailable", "reason": "native-session-" + error}
    try:
        renderer(token["variantPath"], "verify", payload["workspace"])
        verified = True
    except SystemExit:
        verified = False
    return {"protocolVersion": 1, "adapterIdentity": identity,
            "success": bool(selected and completed), "ruleLoaded": bool(verified and markers), "evidence": evidence}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("prepare", "collect"):
        raise SystemExit("usage: codex.py prepare|collect")
    payload = json.load(sys.stdin)
    if payload.get("protocolVersion") != 1:
        raise SystemExit("unsupported protocol version")
    identity = sha256_file(os.path.abspath(__file__))
    print(json.dumps(prepare(payload, identity) if sys.argv[1] == "prepare" else collect(payload, identity)))


if __name__ == "__main__":
    main()
