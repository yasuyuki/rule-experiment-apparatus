"""Windows controller -> WSL materialization parity fixture."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


if os.name != "nt":
    raise SystemExit("test_wsl_materialize.py requires Windows")

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("cycle", ROOT / "apparatus" / "cycle.py")
cycle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cycle)


def run(*args, cwd):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def git_init(path):
    path.mkdir(parents=True)
    run("git", "init", "-b", "main", cwd=path)
    run("git", "config", "user.name", "Fixture", cwd=path)
    run("git", "config", "user.email", "fixture@example.invalid", cwd=path)


renderer = '''#!/usr/bin/env python3
import os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(os.path.abspath(sys.argv[2]), ".rules", "demo.txt")
os.makedirs(os.path.dirname(out), exist_ok=True)
open(out, "wb").write(open(os.path.join(root, "rules", "demo.rule.md"), "rb").read())
'''

with tempfile.TemporaryDirectory(prefix="cycle-wsl-") as raw:
    temp = Path(raw)
    control, source, base = temp / "control", temp / "source", temp / "base"
    subjects, cycles = temp / "subjects", temp / "cycles"
    for path in (control, subjects, cycles):
        path.mkdir(parents=True)

    git_init(base)
    write(base / "README.md", "fixture\n")
    run("git", "add", "README.md", cwd=base)
    run("git", "commit", "-m", "base", cwd=base)
    base_commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=base, text=True
    ).strip()

    git_init(source)
    experiment = source / "experiments" / "demo"
    placement = {"tools": {"demo": {"path": ".rules/{id}.txt"}}}
    trees = {}
    for variant in ("v1", "v2"):
        source_root = experiment / "variants" / variant / "source"
        write(source_root / "bin" / "rules.py", renderer)
        write(source_root / "placement.json", json.dumps(placement))
        write(source_root / "rules" / "demo.rule.md", "same-result\n")
    run("git", "add", ".", cwd=source)
    run("git", "commit", "-m", "variants", cwd=source)
    for variant in ("v1", "v2"):
        trees[variant] = subprocess.check_output(
            ["git", "rev-parse", "HEAD:experiments/demo/variants/%s/source" % variant],
            cwd=source, text=True,
        ).strip()

    descriptor = {
        "id": "demo", "tool": "demo", "isolationEnv": "DEMO_HOME",
        "versionCommand": "true", "binary": "true", "markerFile": None,
        "identityPaths": ["auth.json"],
        "workspacePlacement": [{"path": ".rules/*.txt", "proven": True}],
        "keepEmpty": [], "transcripts": None,
    }
    write(subjects / "demo.json", json.dumps(descriptor))
    environment = {
        "executor": {
            "kind": "wsl", "distro": os.environ.get("APPARATUS_WSL_DISTRO", "Ubuntu-24.04"),
            "user": os.environ.get("APPARATUS_WSL_USER", "root"),
        },
        "variantSourceRoot": str(source),
        "stableRules": {"root": str(base), "branch": "main"},
        "subjects": {"demo": {"configTemplate": str(control)}},
    }
    environment_path = control / "environment.json"
    write(environment_path, json.dumps(environment))
    sha = "a" * 64
    declaration = {
        "cycle": "wsl-materialize", "experiment": "demo", "kind": "measurement",
        "subjects": ["demo"], "workloadHash": sha, "measurementHash": sha,
        "judgeHash": sha, "sessionContractHash": sha, "executionUnitHash": sha,
        "base": {"repo": str(base), "commit": base_commit},
        "arms": [
            {"id": "control", "role": "control", "variant": "v1", "variantTree": trees["v1"]},
            {"id": "treatment", "role": "treatment", "variant": "v2", "variantTree": trees["v2"]},
        ],
    }
    write(cycles / "wsl-materialize.json", json.dumps(declaration))

    old = cycle.CYCLES_DIR, cycle.SUBJECTS_DIR
    cycle.CYCLES_DIR, cycle.SUBJECTS_DIR = str(cycles), str(subjects)
    cycle._subject_cache.clear()
    cycle.configure_environment(str(environment_path))
    release = cycle.exec_("realpath -m \"$HOME/releases/wsl-materialize\"").strip()
    if not release.startswith("/") or not release.endswith("/releases/wsl-materialize"):
        raise AssertionError("unexpected WSL fixture release path: %r" % release)
    cleanup = "rm -rf -- %s" % shlex.quote(release)
    cycle.exec_(cleanup)
    try:
        cycle.materialize("wsl-materialize")
        output = cycle.exec_(
            "sha256sum $HOME/releases/wsl-materialize/{control,treatment}/.rules/demo.txt"
        )
        expected = hashlib.sha256(b"same-result\n").hexdigest()
        assert [line.split()[0] for line in output.splitlines()] == [expected, expected]
    finally:
        cycle.exec_(cleanup)
        cycle.CYCLES_DIR, cycle.SUBJECTS_DIR = old

print("WSL materialization fixture: ok")
