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


def promote_worker(environment, cycle_name, result):
    cycle.configure_environment(environment)
    try:
        cycle.promote(cycle_name)
    except SystemExit as error:
        result.put(str(error))
    else:
        result.put(None)


def held_decide_worker(environment, cycle_name, payload, ready, release, result):
    cycle.configure_environment(environment)
    original = cycle.atomic_write_json

    def delayed_write(path, record):
        ready.set()
        if not release.wait(10):
            raise AssertionError("test did not release decision")
        original(path, record)

    cycle.atomic_write_json = delayed_write
    try:
        cycle.decide(cycle_name, payload)
    except BaseException as error:
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
        "launch": "fake " + payload["workspace"], "token": {
            "workspace": payload["workspace"], "configRoot": payload["configRoot"],
        },
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
            "note": (
                "設定読み込みの失敗を減らす task と、control / treatment の instructions を比較する。"
                "\n\n"
                "共通 workload は `mode=<x>` を含む入力を読み、修正方針を答えること。"
                "\n\n"
                "control は現行 instructions、treatment は「原因を一行で説明する」指示を追加する。"
                "\n\n"
                "期待する挙動は原因と修正方針が分かれて読めること。観察は review に記録する。"
                "\n\n"
                "前回から treatment の追加文だけを変更し、control と `α/β`、引用符 \"quoted\" を再確認する。"
            ), "subjects": ["fake"],
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
        config_roots = {
            subject["prepare"]["token"]["configRoot"]
            for arm in state_before_review["arms"] for subject in arm["subjects"]
        }
        assert config_roots == {str(runs / "fixture" / "configs" / "fake")}
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
        assert review["note"] == declaration("fixture")["note"]
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

        def decision_payload(name, policy, *, status="recommended", actor="agent", previous=None):
            payload = {
                "reviewSha256": sha(control / "reviews" / (name + ".json")),
                "previousDecision": previous,
                "status": status,
                "policy": policy,
                "actor": actor,
                "reason": "fixture records the %s policy" % policy,
                "nextAction": "fixture follows the recorded policy",
                "assessment": {
                    "comparisonValidity": "the paired fixture ran from pinned inputs",
                    "effects": "treatment met the fixture criterion",
                    "regressions": "none observed in the fixture",
                    "uncertainty": "the fixture is synthetic",
                    "priorTrials": "no prior fixture trial changes this result",
                    "applicability": "the fake subject only",
                },
                "references": [],
            }
            if actor == "owner":
                payload["ownerResponse"] = {
                    "text": "owner explicitly selected %s" % policy,
                    "reference": "fixture-owner-response",
                }
            if policy == "adopt":
                payload["adoption"] = {"targetDigest": digests["v2"], "scope": "fixture fake rules"}
            elif policy == "revise":
                payload["revision"] = {"changes": "change the fixture question", "question": "what changed?"}
            elif policy == "continue":
                payload["continuation"] = {"unresolved": "repeat the fixture", "updateWhen": "next run"}
            elif policy == "hold":
                payload["resumptionCondition"] = "owner records a new decision"
            return payload

        def decision_cycle(name):
            write(cycles / (name + ".json"), json.dumps(declaration(name)))
            record = copy.deepcopy(review)
            record["cycle"] = name
            record["declarationSha256"] = sha(cycles / (name + ".json"))
            write(control / "reviews" / (name + ".json"), json.dumps(record))

        # Decisions are an append-only, review-bound history.  Every policy accepts both
        # a recommendation and an explicit owner confirmation.
        for policy in ("discard", "revise", "continue", "hold", "adopt"):
            name = "policy-%s" % policy
            decision_cycle(name)
            recommended = cycle.decide(name, decision_payload(name, policy))
            confirmed = cycle.decide(
                name, decision_payload(name, policy, status="confirmed", actor="owner",
                                       previous=recommended["id"]),
            )
            assert confirmed["sequence"] == 2

        # An agent can confirm the non-dispositive policies, but each policy's
        # required evidence remains mandatory.
        for policy in ("revise", "continue", "hold"):
            name = "agent-confirmed-%s" % policy
            decision_cycle(name)
            assert cycle.decide(name, decision_payload(name, policy, status="confirmed"))["actor"] == "agent"
        for policy, field in (("adopt", "adoption"), ("revise", "revision"),
                              ("continue", "continuation"), ("hold", "resumptionCondition")):
            name = "missing-%s" % policy
            decision_cycle(name)
            incomplete = decision_payload(name, policy)
            incomplete.pop(field)
            assert_rejected(lambda name=name, incomplete=incomplete: cycle.decide(name, incomplete), field)

        decision_cycle("idempotent")
        first_input = decision_payload("idempotent", "revise")
        first = cycle.decide("idempotent", first_input)
        later = cycle.decide(
            "idempotent", decision_payload("idempotent", "continue", previous=first["id"]),
        )
        assert cycle.decide("idempotent", first_input)["id"] == first["id"]
        assert cycle.decision_history("idempotent")[-1]["id"] == later["id"]

        assert_rejected(
            lambda: cycle.decide("fixture", decision_payload(
                "fixture", "adopt", status="confirmed", actor="agent"
            )),
            "only owner may confirm adopt or discard",
        )
        assert_rejected(
            lambda: cycle.decide("fixture", decision_payload(
                "fixture", "discard", status="confirmed", actor="agent"
            )),
            "only owner may confirm adopt or discard",
        )
        missing_evidence = decision_payload("fixture", "adopt", status="confirmed", actor="owner")
        missing_evidence.pop("ownerResponse")
        assert_rejected(lambda: cycle.decide("fixture", missing_evidence), "requires explicit ownerResponse")
        stale = decision_payload("fixture", "hold", previous="0" * 64)
        assert_rejected(lambda: cycle.decide("fixture", stale), "latest decision")
        bad_review = decision_payload("fixture", "adopt", status="confirmed", actor="owner")
        bad_review["reviewSha256"] = "0" * 64
        assert_rejected(lambda: cycle.decide("fixture", bad_review), "review digest mismatch")
        assert not (control / "promotions" / "fixture.json").exists()
        stable_before_decision = git_value(stable, "rev-parse", "HEAD")
        assert_rejected(lambda: cycle.promote("fixture"), "requires latest confirmed owner adoption")
        assert git_value(stable, "rev-parse", "HEAD") == stable_before_decision
        assert not (control / "promotions" / "fixture.json").exists()

        # Recommendations and non-adopt confirmations are useful history, never a
        # promotion authorization.
        promotion_candidates = [("adopt", "recommended"), ("discard", "recommended")]
        promotion_candidates.extend((policy, "confirmed") for policy in ("discard", "revise", "continue", "hold"))
        for index, (policy, status) in enumerate(promotion_candidates):
            name = "no-promote-%d" % index
            decision_cycle(name)
            cycle.decide(name, decision_payload(
                name, policy, status=status, actor="owner" if status == "confirmed" else "agent",
            ))
            assert_rejected(lambda name=name: cycle.promote(name), "requires latest confirmed owner adoption")
            assert not (control / "promotions" / (name + ".json")).exists()

        # A digest-bound adoption cannot silently change target bytes, and a valid
        # review that declines promotion records that refusal without touching stable.
        decision_cycle("bad-adoption")
        wrong_target = decision_payload("bad-adoption", "adopt", status="confirmed", actor="owner")
        wrong_target["adoption"]["targetDigest"] = "0" * 64
        assert_rejected(lambda: cycle.decide("bad-adoption", wrong_target), "target digest differs")
        decision_cycle("ineligible")
        ineligible_review = json.loads((control / "reviews" / "ineligible.json").read_text(encoding="utf-8"))
        ineligible_review["verdict"] = "reject"
        ineligible_review["reasons"] = ["fixture review declines promotion"]
        write(control / "reviews" / "ineligible.json", json.dumps(ineligible_review))
        cycle.decide("ineligible", decision_payload("ineligible", "adopt", status="confirmed", actor="owner"))
        stable_before_ineligible = git_value(stable, "rev-parse", "HEAD")
        cycle.promote("ineligible")
        ineligible_promotion = json.loads((control / "promotions" / "ineligible.json").read_text(encoding="utf-8"))
        assert ineligible_promotion["status"] == "not-promoted"
        assert git_value(stable, "rev-parse", "HEAD") == stable_before_ineligible

        decision_cycle("review-mutated")
        cycle.decide("review-mutated", decision_payload(
            "review-mutated", "adopt", status="confirmed", actor="owner",
        ))
        mutated_review = json.loads((control / "reviews" / "review-mutated.json").read_text(encoding="utf-8"))
        mutated_review["note"] = "valid schema, different reviewed observation"
        write(control / "reviews" / "review-mutated.json", json.dumps(mutated_review))
        assert_rejected(lambda: cycle.promote("review-mutated"), "promotion decision review or target digest mismatch")
        assert not (control / "promotions" / "review-mutated.json").exists()

        # A real process holding decide's cycle lock keeps promotion out until the
        # decision write completes.
        decision_cycle("concurrent-decide")
        context = multiprocessing.get_context("fork")
        ready, release, held_result = context.Event(), context.Event(), context.Queue()
        holder = context.Process(
            target=held_decide_worker,
            args=(str(environment_path), "concurrent-decide",
                  decision_payload("concurrent-decide", "hold"), ready, release, held_result),
        )
        holder.start()
        assert ready.wait(10), "decision did not reach its atomic write"
        contender_result = context.Queue()
        # Promotion, whose decision visibility matters, sees the same non-blocking lock.
        contender = context.Process(
            target=promote_worker,
            args=(str(environment_path), "concurrent-decide", contender_result),
        )
        contender.start()
        assert "operation already in progress" in worker_result(contender, contender_result)
        release.set()
        assert worker_result(holder, held_result) is None

        # A confirmed adoption is required at the instant promotion runs; a later hold
        # supersedes it until the owner records another adoption.
        adoption = cycle.decide(
            "fixture", decision_payload("fixture", "adopt", status="confirmed", actor="owner"),
        )
        hold = cycle.decide(
            "fixture", decision_payload("fixture", "hold", status="confirmed", actor="owner",
                                         previous=adoption["id"]),
        )
        assert_rejected(lambda: cycle.promote("fixture"), "requires latest confirmed owner adoption")
        adoption = cycle.decide(
            "fixture", decision_payload("fixture", "adopt", status="confirmed", actor="owner",
                                         previous=hold["id"]),
        )
        cycle.promote("fixture")
        promotion = json.loads((control / "promotions" / "fixture.json").read_text(encoding="utf-8"))
        assert_schema(promotion, "promotion.schema.json")
        assert promotion["status"] == "promoted"
        assert (stable / "rules" / "demo.rule.md").read_text() == "new\n"

        # Applying an adoption is a separate, verified record.  It cannot be written
        # before promotion, and it names the original owner adoption plus its scope.
        decision_cycle("application-before")
        before_adoption = cycle.decide(
            "application-before", decision_payload(
                "application-before", "adopt", status="confirmed", actor="owner"
            ),
        )
        before_application = decision_payload(
            "application-before", "adopt", status="confirmed", actor="owner",
            previous=before_adoption["id"],
        )
        before_application["application"] = {
            "decisionId": before_adoption["id"], "targetDigest": digests["v2"],
            "scope": "fixture fake rules", "checkedAt": "2026-09-08T00:00:00+00:00",
            "verificationReference": "fixture verification",
        }
        assert_rejected(lambda: cycle.decide("application-before", before_application), "completed promotion")
        assert len(cycle.decision_history("application-before")) == 1
        application = decision_payload(
            "fixture", "adopt", status="confirmed", actor="owner", previous=adoption["id"]
        )
        application["application"] = {
            "decisionId": adoption["id"], "targetDigest": digests["v2"],
            "scope": "fixture fake rules", "checkedAt": "2026-09-08T00:00:00+00:00",
            "verificationReference": "fixture verification",
        }
        applied = cycle.decide("fixture", application)
        assert applied["application"]["decisionId"] == adoption["id"]
        second_application = copy.deepcopy(application)
        second_application["previousDecision"] = applied["id"]
        second_application["application"]["checkedAt"] = "2026-09-08T00:01:00+00:00"
        applied_again = cycle.decide("fixture", second_application)
        assert applied_again["application"]["decisionId"] == adoption["id"]

        # Prepared promotion resumes still re-check the latest decision before touching stable.
        adoption = cycle.decide(
            "fixture", decision_payload("fixture", "adopt", status="confirmed", actor="owner",
                                         previous=applied_again["id"]),
        )
        prepared = copy.deepcopy(promotion)
        prepared["status"] = "prepared"
        write(control / "promotions" / "fixture.json", json.dumps(prepared))
        dirty_marker = stable / "fixture-dirty.txt"
        write(dirty_marker, "dirty\n")
        assert_rejected(lambda: cycle.promote("fixture"), "stable worktree is dirty")
        dirty_marker.unlink()
        run("git", "checkout", "-b", "fixture-wrong-branch", cwd=stable)
        assert_rejected(lambda: cycle.promote("fixture"), "stable branch is not main")
        run("git", "checkout", "main", cwd=stable)
        hold = cycle.decide(
            "fixture", decision_payload("fixture", "hold", status="confirmed", actor="owner",
                                         previous=adoption["id"]),
        )
        assert_rejected(lambda: cycle.promote("fixture"), "requires latest confirmed owner adoption")
        assert git_value(stable, "rev-parse", "HEAD") == promotion["newStableCommit"]
        write(control / "promotions" / "fixture.json", json.dumps(promotion))
        cycle.rollback("fixture")
        rollback = json.loads((control / "rollbacks" / "fixture.json").read_text(encoding="utf-8"))
        assert_schema(rollback, "rollback.schema.json")
        assert rollback["status"] == "rolled-back"
        assert (stable / "rules" / "demo.rule.md").read_text() == "stable\n"

        post_rollback_adoption = cycle.decide(
            "fixture", decision_payload("fixture", "adopt", status="confirmed", actor="owner",
                                         previous=hold["id"]),
        )
        after_rollback = decision_payload(
            "fixture", "adopt", status="confirmed", actor="owner", previous=post_rollback_adoption["id"]
        )
        after_rollback["application"] = dict(application["application"], decisionId=post_rollback_adoption["id"])
        assert_rejected(lambda: cycle.decide("fixture", after_rollback), "non-rolled-back promotion")

        # Follow-up cycles cite a confirmed revision or continuation.  Continuations
        # retain every comparison condition; revisions may deliberately change one.
        decision_cycle("continue-origin")
        continued = cycle.decide(
            "continue-origin", decision_payload("continue-origin", "continue", status="confirmed", actor="owner"),
        )
        followup = declaration("continued-cycle")
        followup["originDecision"] = {"cycle": "continue-origin", "decisionId": continued["id"]}
        write(cycles / "continued-cycle.json", json.dumps(followup))
        cycle.validate_origin_decision(followup)
        cycle.materialize("continued-cycle")
        assert Path(cycle.state_path("continued-cycle")).is_file()
        changed_followup = copy.deepcopy(followup)
        changed_followup["workload"] = dict(changed_followup["workload"], sha256="f" * 64)
        assert_rejected(lambda: cycle.validate_origin_decision(changed_followup), "conditions changed")
        same_cycle = declaration("same-origin")
        same_cycle["originDecision"] = {"cycle": "same-origin", "decisionId": continued["id"]}
        write(cycles / "same-origin.json", json.dumps(same_cycle))
        assert_rejected(lambda: cycle.materialize("same-origin"), "requires a new cycle")
        assert not Path(cycle.state_path("same-origin")).exists()
        original_adapter = adapter.read_text(encoding="utf-8")
        original_descriptor = (subjects / "fake.json").read_text(encoding="utf-8")
        write(adapter, original_adapter + "\n# changed identity\n")
        changed_descriptor = copy.deepcopy(descriptor)
        changed_descriptor["adapter"]["sha256"] = sha(adapter)
        write(subjects / "fake.json", json.dumps(changed_descriptor))
        cycle._subject_cache.clear()
        assert_rejected(lambda: cycle.validate_origin_decision(followup), "adapter conditions changed")
        write(adapter, original_adapter)
        write(subjects / "fake.json", original_descriptor)
        cycle._subject_cache.clear()
        decision_cycle("revise-origin")
        revised = cycle.decide(
            "revise-origin", decision_payload("revise-origin", "revise", status="confirmed", actor="owner"),
        )
        revised_followup = copy.deepcopy(changed_followup)
        revised_followup["cycle"] = "revised-cycle"
        revised_followup["originDecision"] = {"cycle": "revise-origin", "decisionId": revised["id"]}
        cycle.validate_origin_decision(revised_followup)

        write(cycles / "drift.json", json.dumps(declaration("drift")))
        cycle.materialize("drift")
        for arm in ("control", "treatment"):
            workspace = runs / "drift" / arm
            write(workspace / "result.txt", arm + "\n")
            git_commit(workspace, "result")
        cycle.review("drift")
        cycle.decide(
            "drift", decision_payload("drift", "adopt", status="confirmed", actor="owner"),
        )
        write(experiment / "variants" / "v2" / "source" / "rules" / "demo.rule.md", "drifted\n")
        assert_rejected(lambda: cycle.promote("drift"), "decision review or target digest mismatch")
        assert not (control / "promotions" / "drift.json").exists()
        assert (stable / "rules" / "demo.rule.md").read_text() == "stable\n"
    finally:
        cycle.CYCLES_DIR, cycle.SUBJECTS_DIR = old_dirs

print("cycle fixture: ok")
