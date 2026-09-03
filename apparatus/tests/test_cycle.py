import copy
import hashlib
import importlib.util
import json
import multiprocessing
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


def assert_rejected(action, expected):
    try:
        action()
    except SystemExit as error:
        assert expected in str(error), str(error)
    else:
        raise AssertionError("operation unexpectedly succeeded")


def held_write_worker(environment, operation, cycle_name, status, reason, ready, release, result):
    cycle.configure_environment(environment)
    original = cycle.atomic_write_json

    def delayed_write(path, payload):
        ready.set()
        if not release.wait(10):
            raise AssertionError("test did not release held operation")
        original(path, payload)

    cycle.atomic_write_json = delayed_write
    try:
        if operation == "terminate":
            cycle.terminate(cycle_name, status, reason)
        else:
            cycle.review(cycle_name)
    except BaseException as error:
        result.put(str(error))
    else:
        result.put(None)


def terminate_worker(environment, cycle_name, status, reason, result):
    cycle.configure_environment(environment)
    try:
        cycle.terminate(cycle_name, status, reason)
    except SystemExit as error:
        result.put(str(error))
    else:
        result.put(None)


def worker_result(process, result):
    process.join(10)
    if process.is_alive():
        process.terminate()
        process.join()
        raise AssertionError("concurrent worker did not finish")
    assert process.exitcode == 0, process.exitcode
    return result.get(timeout=1)


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
        "evidence": {"result": "result.txt"},
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
        "value": 1.0 if arm["role"] == "treatment" else 0.0,
    }]})
print(json.dumps({"arms": arms}))
'''


with tempfile.TemporaryDirectory(prefix="cycle-fixture-") as raw:
    temp = Path(raw)
    control, source, stable, base, material = (
        temp / name for name in ("control", "source", "stable", "base", "material")
    )
    subjects, cycles, runs = temp / "subjects", control / "cycles", temp / "runs"
    for path in (control, subjects, cycles, runs):
        path.mkdir(parents=True)

    # The pinned base sits between a revision carrying rule bytes it no longer holds and
    # a later one it excludes: an arm must be able to read neither out of the history.
    git_init(base)
    write(base / "policy.template", "stray rule bytes\n")
    git_commit(base, "policy")
    write(base / "README.md", "fixture\n")
    (base / "policy.template").unlink()
    git_commit(base, "base")
    base_commit = git_value(base, "rev-parse", "HEAD")
    write(base / "LATER.md", "past the pin\n")
    git_commit(base, "later")

    # An earlier revision holding rule bytes the pinned commit no longer carries: the
    # arm must not be able to read it back out of the material's history.
    git_init(material)
    write(material / "policy.template", "stray rule bytes\n")
    git_commit(material, "policy")
    write(material / "reference.md", "material\n")
    (material / "policy.template").unlink()
    git_commit(material, "drop policy")
    material_commit = git_value(material, "rev-parse", "HEAD")

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
    measurements = {
        variant: cycle.managed_digest(str(experiment / "variants" / variant / "source"))
        for variant in ("v1", "v2")
    }
    digests = {variant: measurement[0] for variant, measurement in measurements.items()}
    variant_bytes = {variant: measurement[1] for variant, measurement in measurements.items()}

    def declaration(name):
        return {
            "schemaVersion": 1, "cycle": name, "experiment": "demo",
            "note": "fixture measurement", "subjects": ["fake"],
            "workload": {
                "path": "experiments/demo/workload.md", "sha256": sha(experiment / "workload.md"),
            },
            "evaluation": {
                "path": "experiments/demo/evaluate.py", "sha256": sha(experiment / "evaluate.py"),
            },
            "base": {"repo": str(base), "commit": base_commit},
            "materials": [
                {"name": "reference", "repo": str(material), "commit": material_commit}
            ],
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
        assert_rejected(
            lambda: cycle.validate_against_schema(
                dict(declaration("fixture"), note=""), "cycle.schema.json", "empty note"
            ),
            "should be non-empty",
        )
        accepted_values = cycle._validate_evaluation_output({"arms": [
            {"id": "control", "criteria": [{
                "criterion": 1, "text": "numeric", "result": "not-met",
                "evidence": "control", "value": 0,
            }]},
            {"id": "treatment", "criteria": [{
                "criterion": 1, "text": "numeric", "result": "met",
                "evidence": "treatment", "value": 1.5,
            }]},
        ]}, declaration("fixture"))
        assert accepted_values["treatment"][0]["value"] == 1.5
        assert_rejected(
            lambda: cycle._validate_evaluation_output({"arms": [
                {"id": "control", "criteria": [{
                    "criterion": 1, "text": "boolean", "result": "not-met",
                    "evidence": "control", "value": True,
                }]},
                {"id": "treatment", "criteria": [{
                    "criterion": 1, "text": "boolean", "result": "met",
                    "evidence": "treatment", "value": 1,
                }]},
            ]}, declaration("fixture")),
            "invalid evaluation criterion",
        )
        assert_rejected(
            lambda: cycle._validate_evaluation_output({"arms": [
                {"id": "control", "criteria": [{
                    "criterion": 1, "text": "non-finite", "result": "not-met",
                    "evidence": "control", "value": float("nan"),
                }]},
                {"id": "treatment", "criteria": [{
                    "criterion": 1, "text": "non-finite", "result": "met",
                    "evidence": "treatment", "value": 1,
                }]},
            ]}, declaration("fixture")),
            "invalid evaluation criterion",
        )
        termination = {
            "schemaVersion": 1, "cycle": "halted",
            "recordedAt": "2026-09-03T00:00:00+00:00", "status": "abandoned",
            "reason": "fixture operator stopped the run", "declarationSha256": "a" * 64,
        }
        assert_schema(termination, "termination.schema.json")

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

        write(cycles / "halted.json", json.dumps(declaration("halted")))
        cycle.materialize("halted")
        state = Path(cycle.state_path("halted"))
        assert state.is_file()
        cycle.terminate("halted", "abandoned", "fixture operator stopped the run")
        termination_path = control / "terminations" / "halted.json"
        terminated = json.loads(termination_path.read_text(encoding="utf-8"))
        assert_schema(terminated, "termination.schema.json")
        original_termination = termination_path.read_bytes()
        cycle.terminate("halted", "abandoned", "fixture operator stopped the run")
        assert termination_path.read_bytes() == original_termination
        assert state.is_file()
        assert_rejected(
            lambda: cycle.terminate("halted", "failed", "fixture operator stopped the run"),
            "differs from requested payload",
        )
        assert_rejected(lambda: cycle.terminate("halted", "abandoned", "  "), "must not be empty")
        assert_rejected(lambda: cycle.terminate("unknown", "failed", "no declaration"), "not found")
        for operation in (cycle.materialize, cycle.review, cycle.promote):
            assert_rejected(lambda operation=operation: operation("halted"), "cycle is terminated")

        context = multiprocessing.get_context("fork")
        write(cycles / "concurrent-terminate.json", json.dumps(declaration("concurrent-terminate")))
        ready, release, held_result = context.Event(), context.Event(), context.Queue()
        holder = context.Process(
            target=held_write_worker,
            args=(
                str(environment_path), "terminate", "concurrent-terminate", "abandoned",
                "operator stopped first", ready, release, held_result,
            ),
        )
        holder.start()
        assert ready.wait(10), "terminate did not reach its atomic write"
        contender_result = context.Queue()
        contender = context.Process(
            target=terminate_worker,
            args=(
                str(environment_path), "concurrent-terminate", "failed", "operator stopped second",
                contender_result,
            ),
        )
        contender.start()
        assert "operation already in progress" in worker_result(contender, contender_result)
        release.set()
        assert worker_result(holder, held_result) is None
        concurrent_record = json.loads(
            (control / "terminations" / "concurrent-terminate.json").read_text(encoding="utf-8")
        )
        assert concurrent_record["status"] == "abandoned"
        assert concurrent_record["reason"] == "operator stopped first"

        write(cycles / "concurrent-review.json", json.dumps(declaration("concurrent-review")))
        cycle.materialize("concurrent-review")
        for arm in ("control", "treatment"):
            workspace = runs / "concurrent-review" / arm
            write(workspace / "result.txt", arm + "\n")
            git_commit(workspace, "result")
        ready, release, held_result = context.Event(), context.Event(), context.Queue()
        holder = context.Process(
            target=held_write_worker,
            args=(
                str(environment_path), "review", "concurrent-review", None, None,
                ready, release, held_result,
            ),
        )
        holder.start()
        assert ready.wait(10), "review did not reach its atomic write"
        contender_result = context.Queue()
        contender = context.Process(
            target=terminate_worker,
            args=(
                str(environment_path), "concurrent-review", "failed", "late termination",
                contender_result,
            ),
        )
        contender.start()
        assert "operation already in progress" in worker_result(contender, contender_result)
        release.set()
        assert worker_result(holder, held_result) is None
        assert_rejected(
            lambda: cycle.terminate("concurrent-review", "failed", "late termination"),
            "review already exists",
        )

        cycle.materialize("fixture")
        assert (runs / "fixture" / "control" / ".rules" / "demo.txt").read_text() == "old\n"
        assert (runs / "fixture" / "treatment" / ".rules" / "demo.txt").read_text() == "new\n"
        assert Path(cycle.state_path("fixture")).is_file()
        state_before_review = json.loads(Path(cycle.state_path("fixture")).read_text(encoding="utf-8"))
        materialized = runs / "fixture" / "materials" / "reference"
        assert (materialized / "reference.md").read_text() == "material\n"
        assert git_value(materialized, "rev-parse", "HEAD") == material_commit
        revisions = git_value(materialized, "rev-list", "--all").split()
        assert revisions == [material_commit], revisions
        stray = subprocess.run(
            ["git", "grep", "-l", "stray", *revisions],
            cwd=materialized, capture_output=True, text=True,
        )
        assert stray.returncode == 1 and not stray.stdout, stray
        for arm in ("control", "treatment"):
            workspace = runs / "fixture" / arm
            assert not (workspace / "LATER.md").exists()
            assert git_value(workspace, "rev-list", "--max-parents=0", "HEAD") == base_commit
            arm_revisions = git_value(workspace, "rev-list", "--all").split()
            stray = subprocess.run(
                ["git", "grep", "-l", "stray", *arm_revisions],
                cwd=workspace, capture_output=True, text=True,
            )
            assert stray.returncode == 1 and not stray.stdout, stray
            write(workspace / "result.txt", arm + "\n")
            git_commit(workspace, "result")
        cycle.review("fixture")
        assert not Path(cycle.state_path("fixture")).exists()
        review = json.loads((control / "reviews" / "fixture.json").read_text(encoding="utf-8"))
        assert_schema(review, "review.schema.json")
        assert review["verdict"] == "promote"
        assert review["experiment"] == "demo"
        assert review["note"] == "fixture measurement"
        assert review["treatmentDigest"] == digests["v2"]
        for arm in review["arms"]:
            assert arm["variantBytes"] == variant_bytes[arm["variant"]]
            assert arm["criteria"][0]["value"] in (0.0, 1.0)
            state_arm = next(item for item in state_before_review["arms"] if item["id"] == arm["id"])
            prepared = state_arm["subjects"][0]["prepare"]
            subject = arm["subjects"][0]
            assert subject["prepare"] == prepared
            assert subject["collect"] == {
                "protocolVersion": 1, "adapterIdentity": descriptor["adapter"]["sha256"],
                "success": True, "ruleLoaded": True, "evidence": {"result": "result.txt"},
            }
        identities = {
            subject["adapterIdentity"] for arm in review["arms"] for subject in arm["subjects"]
        }
        assert identities == {descriptor["adapter"]["sha256"]}
        versions = {
            subject["subjectVersion"] for arm in review["arms"] for subject in arm["subjects"]
        }
        assert versions == {"fake-1"}
        legacy_review = copy.deepcopy(review)
        legacy_review.pop("experiment")
        legacy_review.pop("note")
        for arm in legacy_review["arms"]:
            arm.pop("variantBytes")
            for subject in arm["subjects"]:
                subject.pop("prepare")
                subject.pop("collect")
                subject["adapterResponseDigest"] = "a" * 64
        assert cycle.promotion_reasons("fixture", declaration("fixture"), legacy_review) == []
        assert_rejected(
            lambda: cycle.terminate("fixture", "failed", "review now exists"),
            "review already exists",
        )

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
