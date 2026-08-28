import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "apparatus" / "subjects" / "claude_code.py"
SPEC = importlib.util.spec_from_file_location("claude_code", ADAPTER)
claude_code = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(claude_code)


def run(*args, cwd=None, stdin=None):
    return subprocess.run(args, cwd=cwd, input=stdin, check=True, capture_output=True,
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

    template, store = temp / "template", temp / "store"
    write(template / "settings.json", "{}\n")
    for name in claude_code.CREDENTIALS:
        write(store / name, "credential\n")
    binary = temp / "claude"
    write(binary, "#!/bin/sh\necho 'fixture Claude'\n")
    binary.chmod(0o755)
    profile = json.dumps({
        "binary": str(binary), "configTemplate": str(template),
        "credentialStore": str(store), "launchPrefix": "launcher",
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

    def prepare(name):
        root, config = workspace(name), temp / (name + "-config")
        payload = {
            "protocolVersion": 1, "cycle": "fixture", "arm": name,
            "workspace": str(root), "configRoot": str(config),
            "variant": {"path": str(variant), "digest": digest},
            "workload": {"path": str(temp / "workload.md"), "digest": "0" * 64},
            "profile": profile,
        }
        result = json.loads(run(sys.executable, str(ADAPTER), "prepare",
                                stdin=json.dumps(payload)).stdout)
        return root, config, result

    workspace_a, config_a, prepared_a = prepare("arm-a")
    workspace_b, config_b, prepared_b = prepare("arm-b")
    assert prepared_a["configIdentity"] == prepared_b["configIdentity"]
    assert prepared_a["variantDigest"] == digest
    assert "launcher" in prepared_a["launch"]
    for config in (config_a, config_b):
        for name in claude_code.CREDENTIALS:
            path = config / name
            assert path.is_symlink()
            assert path.read_text(encoding="utf-8") == "credential\n"

    commit(workspace_a, "variant injection")
    write(workspace_a / "result.txt", "done\n")
    commit(workspace_a, "workload")
    marker = prepared_a["token"]["marker"]
    phase = workspace_a / ".claude" / "plan-phases" / "fixture" / "phase-01.md"
    transcript = config_a / "projects" / "fixture" / "session.jsonl"
    write(transcript, json.dumps({
        "type": "assistant",
        "message": {"content": [
            {"type": "text", "text": marker},
            {"type": "tool_use", "name": "Write", "input": {
                "file_path": str(phase), "content": "```console\nsh scripts/check.sh\n```\n"
            }},
        ]},
    }) + "\n")
    collected = json.loads(run(sys.executable, str(ADAPTER), "collect", stdin=json.dumps({
        "protocolVersion": 1, "cycle": "fixture", "arm": "arm-a",
        "workspace": str(workspace_a), "profile": profile, "token": prepared_a["token"],
    })).stdout)
    assert collected["success"] is True
    assert collected["ruleLoaded"] is True
    evidence = json.loads(collected["evidence"][0])
    assert evidence["phaseDocuments"][".claude/plan-phases/fixture/phase-01.md"].startswith("```console")
    assert not any(str(store) in item for item in collected["evidence"])

print("claude adapter fixture: ok")
