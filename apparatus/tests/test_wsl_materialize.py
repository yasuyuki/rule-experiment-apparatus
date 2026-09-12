"""Windows controller to WSL adapter parity fixture."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
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
    path.write_text(text, encoding="utf-8", newline="")


def git_init(path):
    path.mkdir(parents=True)
    run("git", "init", "-b", "main", cwd=path)
    run("git", "config", "user.name", "Fixture", cwd=path)
    run("git", "config", "user.email", "fixture@example.invalid", cwd=path)


def commit(path, message):
    run("git", "add", "-A", cwd=path)
    run("git", "commit", "-m", message, cwd=path)


def git_value(path, *args):
    return subprocess.check_output(["git", *args], cwd=path, text=True).strip()


RENDERER = '''import os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
target = os.path.join(os.path.abspath(sys.argv[2]), ".rules", "demo.txt")
os.makedirs(os.path.dirname(target), exist_ok=True)
open(target, "wb").write(open(os.path.join(root, "rules", "demo.rule.md"), "rb").read())
'''

ADAPTER = '''import hashlib, json, os, subprocess, sys
payload = json.load(sys.stdin)
identity = hashlib.sha256(open(__file__, "rb").read()).hexdigest()
subprocess.run(["python3", os.path.join(payload["variant"]["path"], "bin", "rules.py"),
                "render", payload["workspace"]], check=True)
placed = os.path.join(payload["workspace"], ".rules", "demo.txt")
print(json.dumps({
    "protocolVersion": 1, "adapterIdentity": identity, "subjectVersion": "fake-wsl-1",
    "configIdentity": "c" * 64, "variantDigest": payload["variant"]["digest"],
    "placements": [{"path": ".rules/demo.txt", "sha256": hashlib.sha256(open(placed, "rb").read()).hexdigest()}],
    "launch": "fake " + payload["workspace"], "token": payload["workspace"],
}))
'''


with tempfile.TemporaryDirectory(prefix="cycle-wsl-") as raw:
    temp = Path(raw)
    control, source, base, subjects, material = (temp / name for name in (
        "control", "source", "base", "subjects", "material"
    ))
    # 宣言は control repository の中にある。configure_environment が CYCLES_DIR を
    # そこへ向けるので、外に置いた directory を指しても上書きされる。
    cycles = control / "cycles"
    for path in (control, subjects, cycles):
        path.mkdir(parents=True)

    git_init(base)
    write(base / "README.md", "fixture\n")
    commit(base, "base")
    base_commit = git_value(base, "rev-parse", "HEAD")

    git_init(material)
    write(material / "NOTE.md", "declared material\n")
    commit(material, "material")
    material_commit = git_value(material, "rev-parse", "HEAD")

    git_init(source)
    experiment = source / "experiments" / "demo"
    write(experiment / "workload.md", "fixture\n")
    write(experiment / "evaluate.py", "raise SystemExit('not used')\n")
    placement = {"tools": {"demo": {"path": ".rules/{id}.txt"}}}
    for variant, body in (("v1", "old\n"), ("v2", "new\n")):
        variant_root = experiment / "variants" / variant / "source"
        write(variant_root / "bin" / "rules.py", RENDERER)
        write(variant_root / "placement.json", json.dumps(placement))
        write(variant_root / "rules" / "demo.rule.md", body)
    commit(source, "variants")

    adapter = subjects / "fake_adapter.py"
    write(adapter, ADAPTER)
    adapter_sha = hashlib.sha256(adapter.read_bytes()).hexdigest()
    write(subjects / "fake.json", json.dumps({
        "id": "fake", "protocolVersion": 1,
        "adapter": {"entrypoint": "fake_adapter.py", "sha256": adapter_sha},
        "profileRef": "fake",
    }))
    runs_root = "/tmp/rule-experiment-wsl-materialize"
    environment = {
        "executor": {
            "kind": "wsl", "distro": os.environ.get("APPARATUS_WSL_DISTRO", "Ubuntu-24.04"),
            "user": os.environ.get("APPARATUS_WSL_USER", "root"),
        },
        "variantSourceRoot": str(source),
        "stableRules": {"root": str(base), "branch": "main"},
        "runsRoot": runs_root, "profiles": {"fake": "fixture-profile"},
    }
    environment_path = control / "environment.json"
    write(environment_path, json.dumps(environment))
    trees = {
        variant: git_value(source, "rev-parse", "HEAD:experiments/demo/variants/%s/source" % variant)
        for variant in ("v1", "v2")
    }
    declaration = {
        "schemaVersion": 1, "cycle": "wsl-materialize", "experiment": "demo",
        "subjects": ["fake"],
        "workload": {
            "path": "experiments/demo/workload.md",
            "sha256": hashlib.sha256((experiment / "workload.md").read_bytes()).hexdigest(),
        },
        "evaluation": {
            "path": "experiments/demo/evaluate.py",
            "sha256": hashlib.sha256((experiment / "evaluate.py").read_bytes()).hexdigest(),
        },
        "base": {"repo": str(base), "commit": base_commit},
        "materials": [{"name": "records", "repo": str(material), "commit": material_commit}],
        "arms": [
            {
                "id": "control", "role": "control", "variant": "v1",
                "variantTree": trees["v1"],
                "variantDigest": cycle.managed_digest(str(experiment / "variants" / "v1" / "source"))[0],
            },
            {
                "id": "treatment", "role": "treatment", "variant": "v2",
                "variantTree": trees["v2"],
                "variantDigest": cycle.managed_digest(str(experiment / "variants" / "v2" / "source"))[0],
            },
        ],
    }
    write(cycles / "wsl-materialize.json", json.dumps(declaration))

    old_dirs = cycle.CYCLES_DIR, cycle.SUBJECTS_DIR
    cycle.configure_environment(str(environment_path))
    assert Path(cycle.CYCLES_DIR) == cycles
    cycle.SUBJECTS_DIR = str(subjects)
    cycle.exec_("rm -rf -- %s" % runs_root)
    try:
        cycle.materialize("wsl-materialize")
        output = cycle.exec_("sha256sum %s/wsl-materialize/{control,treatment}/.rules/demo.txt" % runs_root)
        expected = [hashlib.sha256(body).hexdigest() for body in (b"old\n", b"new\n")]
        assert [line.split()[0] for line in output.splitlines()] == expected
        # The material lands beside the arms, pinned and not writable, and review
        # re-checks the pin rather than trusting the file mode.
        note = "%s/wsl-materialize/materials/records/NOTE.md" % runs_root
        assert cycle.exec_("cat %s" % note) == "declared material\n"
        assert cycle.exec_(
            "git -C %s/wsl-materialize/materials/records rev-parse HEAD" % runs_root
        ).strip() == material_commit
        # root ignores the mode, so check the bits rather than test -w.
        mode = cycle.exec_("stat -c '%a' " + note).strip()
        assert int(mode, 8) & 0o222 == 0, mode
        cycle.verify_materials(declaration)
        cycle.exec_("chmod u+w %s && printf edited >> %s" % (note, note))
        try:
            cycle.verify_materials(declaration)
        except SystemExit as error:
            assert "was modified during the cycle" in str(error), error
        else:
            raise AssertionError("a modified material was accepted")
    finally:
        cycle.exec_("rm -rf -- %s" % runs_root)
        cycle.CYCLES_DIR, cycle.SUBJECTS_DIR = old_dirs

print("WSL materialization fixture: ok")
