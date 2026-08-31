import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile


if os.name != "posix":
    raise SystemExit("test_cycle.py requires a POSIX host; it drives the local-posix executor")

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("cycle", ROOT / "apparatus" / "cycle.py")
cycle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cycle)

for key, value in {
    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
}.items():
    os.environ.setdefault(key, value)


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


def git_commit(path, message):
    run("git", "add", "-A", cwd=path)
    run("git", "commit", "-m", message, cwd=path)


def git_value(path, *args):
    return subprocess.check_output(["git", *args], cwd=path, text=True).strip()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def assert_schema(payload, name):
    cycle.validate_against_schema(payload, name, "valid fixture")
    invalid = dict(payload, unexpected=True)
    try:
        cycle.validate_against_schema(invalid, name, "invalid fixture")
    except SystemExit:
        pass
    else:
        raise AssertionError("%s accepted an unknown property" % name)


RENDERER = '''import os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
target = os.path.join(os.path.abspath(sys.argv[2]), ".rules", "demo.txt")
expected = open(os.path.join(root, "rules", "demo.rule.md"), encoding="utf-8").read()
if sys.argv[1] == "render":
    os.makedirs(os.path.dirname(target), exist_ok=True)
    open(target, "w", encoding="utf-8", newline="\\n").write(expected)
elif sys.argv[1] == "verify":
    raise SystemExit(0 if os.path.isfile(target) and open(target, encoding="utf-8").read() == expected else 1)
else:
    raise SystemExit(2)
'''

ADAPTER = '''import hashlib, json, os, subprocess, sys
payload = json.load(sys.stdin)
identity = hashlib.sha256(open(__file__, "rb").read()).hexdigest()
if sys.argv[1] == "prepare":
    renderer = os.path.join(payload["variant"]["path"], "bin", "rules.py")
    subprocess.run(["python3", renderer, "render", payload["workspace"]], check=True)
    placed = os.path.join(payload["workspace"], ".rules", "demo.txt")
    digest = hashlib.sha256(open(placed, "rb").read()).hexdigest()
    result = {
        "protocolVersion": 1, "adapterIdentity": identity, "subjectVersion": "fake-1",
        "configIdentity": "c" * 64, "variantDigest": payload["variant"]["digest"],
        "placements": [{"path": ".rules/demo.txt", "sha256": digest}],
        "launch": "fake " + payload["workspace"], "token": {"workspace": payload["workspace"]},
    }
elif sys.argv[1] == "collect":
    workspace = payload["token"]["workspace"]
    result = {
        "protocolVersion": 1, "adapterIdentity": identity,
        "success": os.path.isfile(os.path.join(workspace, "result.txt")),
        "ruleLoaded": os.path.isfile(os.path.join(workspace, ".rules", "demo.txt")),
        "evidence": ["result.txt"],
    }
else:
    raise SystemExit(2)
print(json.dumps(result))
'''

EVALUATION = '''import json, os, sys
assert sys.argv[1] == "evaluate"
payload = json.load(sys.stdin)
arms = []
for arm in payload["arms"]:
    assert os.path.isfile(os.path.join(arm["workspace"], "result.txt"))
    arms.append({"id": arm["id"], "criteria": [{
        "criterion": 1, "text": "variant changes behavior",
        "result": "met" if arm["role"] == "treatment" else "not-met",
        "evidence": arm["id"] + "/result.txt",
    }]})
print(json.dumps({"arms": arms}))
'''


with tempfile.TemporaryDirectory(prefix="cycle-fixture-") as raw:
    temp = Path(raw)
    control, source, stable, base = (temp / name for name in ("control", "source", "stable", "base"))
    subjects, cycles, runs = temp / "subjects", control / "cycles", temp / "runs"
    for path in (control, subjects, cycles, runs):
        path.mkdir(parents=True)

    git_init(base)
    write(base / "README.md", "fixture\n")
    git_commit(base, "base")
    base_commit = git_value(base, "rev-parse", "HEAD")

    git_init(source)
    experiment = source / "experiments" / "demo"
    write(experiment / "workload.md", "Do the fixture work.\n")
    write(experiment / "evaluate.py", EVALUATION)
    placement = {"tools": {"demo": {"path": ".rules/{id}.txt"}}}
    for variant, body in (("v1", "old\n"), ("v2", "new\n")):
        variant_root = experiment / "variants" / variant / "source"
        write(variant_root / "bin" / "rules.py", RENDERER)
        write(variant_root / "placement.json", json.dumps(placement))
        write(variant_root / "rules" / "demo.rule.md", body)
    git_commit(source, "experiment")

    git_init(stable)
    write(stable / "bin" / "rules.py", RENDERER)
    write(stable / "placement.json", json.dumps(placement))
    write(stable / "rules" / "demo.rule.md", "stable\n")
    git_commit(stable, "stable")

    adapter = subjects / "fake_adapter.py"
    write(adapter, ADAPTER)
    descriptor = {
        "id": "fake", "protocolVersion": 1,
        "adapter": {"entrypoint": "fake_adapter.py", "sha256": sha(adapter)},
        "profileRef": "fake",
    }
    write(subjects / "fake.json", json.dumps(descriptor))
    environment = {
        "executor": {"kind": "local-posix"}, "variantSourceRoot": str(source),
        "stableRules": {"root": str(stable), "branch": "main"},
        "runsRoot": str(runs), "profiles": {"fake": "fixture-profile"},
    }
    environment_path = control / "environment.json"
    write(environment_path, json.dumps(environment))

    trees = {
        variant: git_value(source, "rev-parse", "HEAD:experiments/demo/variants/%s/source" % variant)
        for variant in ("v1", "v2")
    }
    digests = {
        variant: cycle.managed_digest(str(experiment / "variants" / variant / "source"))
        for variant in ("v1", "v2")
    }

    def declaration(name):
        return {
            "schemaVersion": 1, "cycle": name, "experiment": "demo", "subjects": ["fake"],
            "workload": {
                "path": "experiments/demo/workload.md", "sha256": sha(experiment / "workload.md"),
            },
            "evaluation": {
                "path": "experiments/demo/evaluate.py", "sha256": sha(experiment / "evaluate.py"),
            },
            "base": {"repo": str(base), "commit": base_commit},
            "arms": [
                {
                    "id": "control", "role": "control", "variant": "v1",
                    "variantTree": trees["v1"], "variantDigest": digests["v1"],
                },
                {
                    "id": "treatment", "role": "treatment", "variant": "v2",
                    "variantTree": trees["v2"], "variantDigest": digests["v2"],
                },
            ],
        }

    write(cycles / "fixture.json", json.dumps(declaration("fixture")))
    old_dirs = cycle.CYCLES_DIR, cycle.SUBJECTS_DIR
    cycle.configure_environment(str(environment_path))
    assert Path(cycle.CYCLES_DIR) == cycles
    cycle.SUBJECTS_DIR = str(subjects)
    try:
        assert_schema(environment, "environment.schema.json")
        assert_schema(descriptor, "subject.schema.json")
        assert_schema(declaration("fixture"), "cycle.schema.json")

        bad_descriptor = json.loads(json.dumps(descriptor))
        bad_descriptor["adapter"]["sha256"] = "0" * 64
        write(subjects / "fake.json", json.dumps(bad_descriptor))
        cycle._subject_cache.clear()
        try:
            cycle.load_subject("fake")
        except SystemExit as error:
            assert "digest mismatch" in str(error)
        else:
            raise AssertionError("subject accepted an unversioned adapter")
        write(subjects / "fake.json", json.dumps(descriptor))
        cycle._subject_cache.clear()

        fingerprint = cycle.validate_comparison(declaration("fixture"))
        assert fingerprint["baseCommit"] == base_commit
        assert len(fingerprint["adapters"]) == 1

        cycle.materialize("fixture")
        assert (runs / "fixture" / "control" / ".rules" / "demo.txt").read_text() == "old\n"
        assert (runs / "fixture" / "treatment" / ".rules" / "demo.txt").read_text() == "new\n"
        assert Path(cycle.state_path("fixture")).is_file()
        for arm in ("control", "treatment"):
            workspace = runs / "fixture" / arm
            write(workspace / "result.txt", arm + "\n")
            git_commit(workspace, "result")
        cycle.review("fixture")
        assert not Path(cycle.state_path("fixture")).exists()
        review = json.loads((control / "reviews" / "fixture.json").read_text(encoding="utf-8"))
        assert_schema(review, "review.schema.json")
        assert review["verdict"] == "promote"
        assert review["treatmentDigest"] == digests["v2"]
        identities = {
            subject["adapterIdentity"] for arm in review["arms"] for subject in arm["subjects"]
        }
        assert identities == {descriptor["adapter"]["sha256"]}
        versions = {
            subject["subjectVersion"] for arm in review["arms"] for subject in arm["subjects"]
        }
        assert versions == {"fake-1"}

        cycle.promote("fixture")
        promotion = json.loads((control / "promotions" / "fixture.json").read_text(encoding="utf-8"))
        assert_schema(promotion, "promotion.schema.json")
        assert promotion["status"] == "promoted"
        assert (stable / "rules" / "demo.rule.md").read_text() == "new\n"
        cycle.rollback("fixture")
        rollback = json.loads((control / "rollbacks" / "fixture.json").read_text(encoding="utf-8"))
        assert_schema(rollback, "rollback.schema.json")
        assert rollback["status"] == "rolled-back"
        assert (stable / "rules" / "demo.rule.md").read_text() == "stable\n"

        write(cycles / "drift.json", json.dumps(declaration("drift")))
        cycle.materialize("drift")
        for arm in ("control", "treatment"):
            workspace = runs / "drift" / arm
            write(workspace / "result.txt", arm + "\n")
            git_commit(workspace, "result")
        cycle.review("drift")
        write(experiment / "variants" / "v2" / "source" / "rules" / "demo.rule.md", "drifted\n")
        cycle.promote("drift")
        rejected = json.loads((control / "promotions" / "drift.json").read_text(encoding="utf-8"))
        assert rejected["status"] == "not-promoted"
        assert any("reviewed bytes" in reason or "digest mismatch" in reason for reason in rejected["reasons"])
        assert (stable / "rules" / "demo.rule.md").read_text() == "stable\n"
    finally:
        cycle.CYCLES_DIR, cycle.SUBJECTS_DIR = old_dirs

print("cycle fixture: ok")
