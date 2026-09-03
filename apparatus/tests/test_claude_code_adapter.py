import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


if os.name != "posix":
    raise SystemExit("test_claude_code_adapter.py requires a POSIX host; its fixtures are executable shell scripts")

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "apparatus" / "subjects" / "claude_code.py"
SPEC = importlib.util.spec_from_file_location("claude_code", ADAPTER)
claude_code = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(claude_code)


def run(*args, cwd=None, stdin=None, check=True):
    return subprocess.run(args, cwd=cwd, input=stdin, check=check, capture_output=True,
                          text=True, encoding="utf-8")


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="")


def commit(root, message):
    run("git", "add", "-A", cwd=root)
    run("git", "commit", "-m", message, cwd=root)


RENDERER = '''import os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
target = os.path.join(os.path.abspath(sys.argv[2]), ".claude", "rules", "agent-rules--demo.md")
expected = open(os.path.join(root, "rules", "demo.rule.md"), encoding="utf-8").read()
if sys.argv[1] == "render":
    os.makedirs(os.path.dirname(target), exist_ok=True)
    open(target, "w", encoding="utf-8", newline="\\n").write(expected)
elif sys.argv[1] == "verify":
    raise SystemExit(0 if os.path.isfile(target) and open(target, encoding="utf-8").read() == expected else 1)
else:
    raise SystemExit(2)
'''


with tempfile.TemporaryDirectory(prefix="claude-adapter-") as raw:
    temp = Path(raw)
    variant = temp / "variant"
    write(variant / "bin" / "rules.py", RENDERER)
    write(variant / "rules" / "demo.rule.md", "# demo\n")
    write(variant / "placement.json", json.dumps({
        "tools": {"claude": {"path": ".claude/rules/agent-rules--{id}.md"}}
    }))

    template = temp / "template"
    write(template / "settings.json", "{}\n")
    bridge = temp / "credential-sources"
    bridge.mkdir()
    credential_sources, native_sources = {}, {}
    for name in claude_code.CREDENTIALS:
        source = temp / ("source-" + name.lstrip("."))
        write(source, "credential\n")
        link = bridge / name
        link.symlink_to(source)
        credential_sources[name] = str(link)
        native_sources[name] = str(source)
    auth_status = temp / "auth-status.json"
    write(auth_status, json.dumps({
        "loggedIn": True, "authMethod": "claude.ai", "subscriptionType": "fixture",
    }))
    os.environ["FIXTURE_AUTH_STATUS"] = str(auth_status)
    binary = temp / "claude"
    write(binary, '''#!/bin/sh
if [ "$1" = "--version" ]; then
    echo 'fixture Claude'
elif [ "$1 $2 $3" = "auth status --json" ]; then
    cat "$FIXTURE_AUTH_STATUS"
else
    exit 2
fi
''')
    binary.chmod(0o755)
    profile = json.dumps({
        "binary": str(binary), "configTemplate": str(template),
        "credentialSources": credential_sources, "launchPrefix": "launcher",
    })
    digest = claude_code.managed_digest(str(variant))

    def workspace(name):
        root = temp / name
        root.mkdir()
        run("git", "init", "-b", "main", cwd=root)
        run("git", "config", "user.name", "Fixture", cwd=root)
        run("git", "config", "user.email", "fixture@example.invalid", cwd=root)
        write(root / "README.md", "fixture\n")
        commit(root, "base")
        return root

    def prepare(name, materials=(), config=None, check=True):
        root = workspace(name)
        config = config or temp / (name + "-config")
        payload = {
            "protocolVersion": 1, "cycle": "fixture", "arm": name,
            "workspace": str(root), "configRoot": str(config),
            "variant": {"path": str(variant), "digest": digest},
            "workload": {"path": str(temp / "workload.md"), "digest": "0" * 64},
            "materials": list(materials),
            "profile": profile,
        }
        completed = run(sys.executable, str(ADAPTER), "prepare", check=check,
                        stdin=json.dumps(payload))
        result = json.loads(completed.stdout) if check else completed
        return root, config, result

    shortstat_workspace = workspace("shortstat-empty")
    assert claude_code.git_shortstat(str(shortstat_workspace),
                                     claude_code.git(str(shortstat_workspace), "rev-parse", "HEAD").stdout.strip()) == {
        "files": 0, "insertions": 0, "deletions": 0,
    }

    workspace_a, config_a, prepared_a = prepare("arm-a")
    workspace_b, config_b, prepared_b = prepare("arm-b", config=config_a)
    assert config_a == config_b
    assert prepared_a["configIdentity"] == prepared_b["configIdentity"]
    _, _, collision = prepare("arm_a", config=config_a, check=False)
    assert collision.returncode != 0
    assert "Claude project directory collision between workspaces" in collision.stderr
    assert prepared_a["variantDigest"] == digest
    assert "launcher" in prepared_a["launch"]
    assert "--add-dir" not in prepared_a["launch"]
    # A declared material has to be named at launch or the subject cannot read it.
    _, _, prepared_m = prepare("arm-m", [{"name": "records", "path": str(temp / "records")}])
    assert "--add-dir %s" % str(temp / "records") in prepared_m["launch"]
    for config in (config_a, config_b):
        for name in claude_code.CREDENTIALS:
            path = config / name
            assert path.is_symlink()
            assert path.resolve() == Path(native_sources[name]).resolve()
            assert os.readlink(path) == native_sources[name]
            assert path.read_text(encoding="utf-8") == "credential\n"

    commit(workspace_a, "variant injection")
    write(workspace_a / "result.txt", "done\n")
    commit(workspace_a, "workload")
    marker = prepared_a["token"]["marker"]
    phase = workspace_a / ".claude" / "plan-phases" / "fixture" / "phase-01.md"
    transcript = Path(claude_code.project_directory(str(config_a), str(workspace_a))) / "session.jsonl"
    write(transcript, json.dumps({
        "timestamp": "2026-01-02T03:04:05.000Z",
        "type": "assistant",
        "message": {"content": [
            {"type": "text", "text": marker},
            {"type": "tool_use", "name": "Write", "input": {
                "file_path": str(phase), "content": "```console\nsh scripts/check.sh\n%s\n%s\n```\n" % (
                    config_a, native_sources[".credentials.json"],
                )
            }},
            {"type": "tool_use", "name": "Skill", "input": {"skill": "demo-skill"}},
            {"type": "tool_use", "name": "Skill", "input": {"skill": "demo-skill", "args": "full"}},
            {"type": "tool_use", "name": "Skill", "input": {"skill": "/etc/passwd"}},
            {"type": "tool_use", "name": "Skill", "input": {"skill": 7}},
        ], "usage": {
            "input_tokens": 3,
            "output_tokens": 5,
            "server_tool_use": {"web_search_requests": 2},
            "ignored": "not-a-number",
            "boolean": True,
        }},
    }) + "\n" + json.dumps({
        "timestamp": "2026-01-02T03:05:06.000Z",
        "type": "assistant",
        "message": {"content": "second assistant", "usage": {
            "input_tokens": 7,
            "output_tokens": "not-a-number",
            "server_tool_use": {"web_search_requests": 1, "ignored": []},
        }},
    }) + "\n" + json.dumps({
        "timestamp": "2026-01-02T03:06:07.000Z",
        "type": "user",
        "message": {"content": "ignored"},
    }) + "\n")
    commit(workspace_b, "variant injection")
    write(workspace_b / "result.txt", "done\n")
    commit(workspace_b, "workload")
    transcript_b = Path(claude_code.project_directory(
        str(config_b), str(workspace_b)
    )) / "session.jsonl"
    write(transcript_b, json.dumps({
        "timestamp": "2026-01-02T04:00:00.000Z",
        "type": "assistant",
        "message": {"content": prepared_b["token"]["marker"], "usage": {"input_tokens": 99}},
    }) + "\n")
    collected = json.loads(run(sys.executable, str(ADAPTER), "collect", stdin=json.dumps({
        "protocolVersion": 1, "cycle": "fixture", "arm": "arm-a",
        "workspace": str(workspace_a), "profile": profile, "token": prepared_a["token"],
    })).stdout)
    assert collected["success"] is True
    assert collected["ruleLoaded"] is True
    evidence = collected["evidence"]
    phase_evidence = evidence["phaseDocuments"][".claude/plan-phases/fixture/phase-01.md"]
    assert phase_evidence.startswith("```console")
    assert "[redacted-path]" in phase_evidence
    assert evidence["sessions"] == [{
        "path": claude_code.session_path(str(config_a), str(transcript)),
        "firstTimestamp": "2026-01-02T03:04:05.000Z",
        "lastTimestamp": "2026-01-02T03:06:07.000Z",
    }]
    assert evidence["assistantCount"] == 2
    assert evidence["toolUseCount"] == 5
    assert evidence["usage"] == {
        "input_tokens": 10,
        "output_tokens": 5,
        "server_tool_use": {"web_search_requests": 3},
    }
    assert evidence["shortstat"] == {"files": 3, "insertions": 5, "deletions": 0}
    assert evidence["commitsAfterBase"] == 2
    assert evidence["clean"] is True
    # A skill only reaches the subject when the subject invokes it, so the count
    # separates "the skill changed nothing" from "the skill never ran". The name is
    # subject-supplied, so anything but a bare identifier is dropped.
    assert evidence["skillInvocations"] == {"demo-skill": 2}
    collected_b = json.loads(run(sys.executable, str(ADAPTER), "collect", stdin=json.dumps({
        "protocolVersion": 1, "cycle": "fixture", "arm": "arm-b",
        "workspace": str(workspace_b), "profile": profile, "token": prepared_b["token"],
    })).stdout)
    assert collected_b["evidence"]["sessions"] == [{
        "path": claude_code.session_path(str(config_b), str(transcript_b)),
        "firstTimestamp": "2026-01-02T04:00:00.000Z",
        "lastTimestamp": "2026-01-02T04:00:00.000Z",
    }]
    assert collected_b["evidence"]["assistantCount"] == 1
    assert collected_b["evidence"]["usage"] == {"input_tokens": 99}
    assert str(temp) not in json.dumps(collected["evidence"])
    assert str(config_a) not in json.dumps(collected["evidence"])
    assert not any(source in json.dumps(collected["evidence"]) for source in native_sources.values())

    settings = claude_code.profile(profile)
    for invalid in (
        {"loggedIn": False, "authMethod": "claude.ai", "subscriptionType": "fixture"},
        {"loggedIn": True, "authMethod": "apiKey", "subscriptionType": None},
        "not-json",
    ):
        write(auth_status, invalid if isinstance(invalid, str) else json.dumps(invalid))
        try:
            claude_code.verify_subscription(settings, str(config_b))
        except SystemExit as error:
            assert str(error) == "Claude subscription authentication is unavailable"
        else:
            raise AssertionError("invalid authentication passed")

    replaced = config_a / ".credentials.json"
    replaced.unlink()
    write(replaced, "refreshed\n")
    restored = json.loads(run(sys.executable, str(ADAPTER), "collect", stdin=json.dumps({
        "protocolVersion": 1, "cycle": "fixture", "arm": "arm-a",
        "workspace": str(workspace_a), "profile": profile, "token": prepared_a["token"],
    })).stdout)
    assert restored["success"] is True
    assert replaced.is_symlink()
    assert os.readlink(replaced) == native_sources[".credentials.json"]
    assert Path(native_sources[".credentials.json"]).read_text(encoding="utf-8") == "refreshed\n"

    diverted = config_a / ".claude.json"
    diverted.unlink()
    other = temp / "other-claude.json"
    write(other, "other\n")
    diverted.symlink_to(other)
    failed = run(sys.executable, str(ADAPTER), "collect", check=False, stdin=json.dumps({
        "protocolVersion": 1, "cycle": "fixture", "arm": "arm-a",
        "workspace": str(workspace_a), "profile": profile, "token": prepared_a["token"],
    }))
    assert failed.returncode != 0
    assert "Claude credential link changed: .claude.json" in failed.stderr
    assert not any(source in failed.stderr for source in native_sources.values())

print("claude adapter fixture: ok")
