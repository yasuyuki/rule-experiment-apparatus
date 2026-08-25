import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("cycle", ROOT / "apparatus" / "cycle.py")
cycle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cycle)


def run(*args, cwd, env=None):
    merged = os.environ.copy()
    if env:
        merged.update(env)
    subprocess.run(args, cwd=cwd, env=merged, check=True, capture_output=True, text=True)


def git_init(path):
    path.mkdir(parents=True)
    run("git", "init", "-b", "main", cwd=path)
    run("git", "config", "user.name", "Fixture", cwd=path)
    run("git", "config", "user.email", "fixture@example.invalid", cwd=path)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def assert_schema_contract(payload, schema):
    cycle.validate_against_schema(payload, schema, "valid fixture")
    invalid = dict(payload)
    invalid["unexpected"] = True
    try:
        cycle.validate_against_schema(invalid, schema, "invalid fixture")
    except SystemExit:
        pass
    else:
        raise AssertionError("%s accepted an unknown property" % schema)


RENDERER = '''#!/usr/bin/env python3
import os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
target = os.path.abspath(sys.argv[2])
out = os.path.join(target, ".rules", "demo.txt")
expected = open(os.path.join(root, "rules", "demo.rule.md"), encoding="utf-8").read()
if sys.argv[1] == "render":
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w", encoding="utf-8", newline="\\n").write(expected)
    print("rendered")
elif sys.argv[1] == "verify":
    raise SystemExit(0 if os.path.isfile(out) and open(out, encoding="utf-8").read() == expected else 1)
else:
    raise SystemExit(2)
'''


JUDGE = '''#!/usr/bin/env python3
import argparse, hashlib, json, os
p = argparse.ArgumentParser(); sub = p.add_subparsers(dest="command", required=True)
b = sub.add_parser("baseline"); b.add_argument("--arm"); b.add_argument("-o")
j = sub.add_parser("judge"); j.add_argument("--arm"); j.add_argument("--workload"); j.add_argument("--variant")
j.add_argument("--execution"); j.add_argument("--baseline")
a = p.parse_args()
if a.command == "baseline":
    open(a.o, "w", encoding="utf-8").write(json.dumps({"arm": a.arm}) + "\\n")
else:
    data = json.load(open(a.execution, encoding="utf-8"))
    assert any(arm["id"] == os.path.basename(a.arm) for arm in data["arms"])
    digest = lambda path: hashlib.sha256(open(path, "rb").read()).hexdigest()
    print(json.dumps({"judgeSha256": digest(__file__), "workloadSha256": digest(a.workload), "criteria": [
        {"criterion": 1, "text": "variant changes behavior", "result": "met" if a.variant == "v2" else "not-met", "evidence": "fixture"}
    ]}))
    raise SystemExit(0 if a.variant == "v2" else 1)
'''


with tempfile.TemporaryDirectory(prefix="cycle-fixture-") as raw:
    temp = Path(raw)
    control = temp / "control"
    source = temp / "source"
    stable = temp / "stable"
    base = temp / "base"
    subjects = temp / "subjects"
    cycles = temp / "cycles"
    template = temp / "template"
    authstore = temp / "authstore"
    for path in (control, subjects, cycles, template):
        path.mkdir(parents=True)
    # store と別内容にして、複製ではなく store の内容が使われることを検証できるようにする。
    write(template / "auth.json", "fixture-template-auth\n")
    write(template / "settings.json", "fixture-settings\n")
    write(template / "sessions" / "foreign.jsonl", '{"type":"assistant"}\n')
    write(authstore / "auth.json", "fixture-store-auth\n")

    git_init(base)
    write(base / "README.md", "fixture\n")
    run("git", "add", "README.md", cwd=base)
    run("git", "commit", "-m", "base", cwd=base)
    base_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=base, text=True).strip()

    git_init(source)
    experiment = source / "experiments" / "demo"
    write(experiment / "workload.md", "Do the fixture work.\n")
    write(experiment / "MEASUREMENT.md", "Fixture measurement.\n")
    write(experiment / "session-contract.md", "[%s:%s]\n")
    write(experiment / "judge" / "judge.py", JUDGE)
    placement = {"tools": {"demo": {"path": ".rules/{id}.txt"}}, "mustStayEmpty": ["UNUSED.md"]}
    for variant, body in (("v1", "old\n"), ("v2", "new\n"), ("vbad", "bad\n")):
        variant_root = experiment / "variants" / variant / "source"
        write(variant_root / "bin" / "rules.py", RENDERER)
        write(variant_root / "placement.json", json.dumps(placement))
        write(variant_root / "rules" / "demo.rule.md", body)
    write(
        experiment / "variants" / "vbad" / "source" / "bin" / "rules.py",
        "raise SystemExit('renderer failure')\n",
    )
    run("git", "add", ".", cwd=source)
    run("git", "commit", "-m", "variants", cwd=source)

    git_init(stable)
    write(stable / "bin" / "rules.py", RENDERER)
    write(stable / "placement.json", json.dumps(placement))
    write(stable / "rules" / "demo.rule.md", "stable\n")
    run("git", "add", ".", cwd=stable)
    run("git", "commit", "-m", "stable", cwd=stable)
    stable_before = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=stable, text=True).strip()

    descriptor = {
        "id": "demo", "tool": "demo", "isolationEnv": "DEMO_HOME",
        "versionCommand": "printf demo-1", "binary": "true", "markerFile": "MARKER.md",
        "credentialPaths": ["auth.json"],
        "workspacePlacement": [{"path": ".rules/*.txt", "proven": True}],
        "keepEmpty": ["SUBJECT-UNUSED.md"],
        "transcripts": {
            "glob": "sessions/*.jsonl", "armBinding": "session-meta-cwd",
            "participation": {"jsonlField": "type", "equals": "assistant"},
        },
    }
    write(subjects / "demo.json", json.dumps(descriptor))
    descriptor2 = dict(descriptor)
    descriptor2["id"] = "demo2"
    write(subjects / "demo2.json", json.dumps(descriptor2))
    environment = {
        "executor": {"kind": "local-posix"}, "variantSourceRoot": str(source),
        "stableRules": {"root": str(stable), "branch": "main"},
        "subjects": {
            "demo": {"configTemplate": str(template), "credentialStore": str(authstore)},
            "demo2": {"configTemplate": str(template), "credentialStore": str(authstore)},
        },
    }
    environment_path = control / "environment.json"
    write(environment_path, json.dumps(environment))

    sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    trees = {
        variant: subprocess.check_output(
            ["git", "rev-parse", f"HEAD:experiments/demo/variants/{variant}/source"],
            cwd=source, text=True,
        ).strip() for variant in ("v1", "v2", "vbad")
    }
    declaration = {
        "cycle": "fixture-core", "experiment": "demo", "kind": "measurement",
        "subjects": ["demo", "demo2"], "workloadHash": sha(experiment / "workload.md"),
        "measurementHash": sha(experiment / "MEASUREMENT.md"),
        "judgeHash": sha(experiment / "judge" / "judge.py"),
        "sessionContractHash": sha(experiment / "session-contract.md"),
        "executionUnitHash": sha(ROOT / "docs" / "EXECUTION-UNIT.md"),
        "base": {"repo": str(base), "commit": base_commit},
        "arms": [
            {"id": "control", "role": "control", "variant": "v1", "variantTree": trees["v1"]},
            {"id": "treatment", "role": "treatment", "variant": "v2", "variantTree": trees["v2"]},
        ],
    }
    write(cycles / "fixture-core.json", json.dumps(declaration))

    old = (cycle.CYCLES_DIR, cycle.SUBJECTS_DIR)
    cycle.CYCLES_DIR, cycle.SUBJECTS_DIR = str(cycles), str(subjects)
    cycle._subject_cache.clear()
    cycle.configure_environment(str(environment_path))
    assert_schema_contract(environment, "environment.schema.json")
    assert_schema_contract(descriptor, "subject.schema.json")
    assert_schema_contract(declaration, "cycle.schema.json")
    release = Path.home() / "releases" / "fixture-core"
    if release.exists():
        shutil.rmtree(release)
    extra_releases = []
    try:
        unproven = dict(descriptor)
        unproven["workspacePlacement"] = [{"path": ".rules/*.txt", "proven": False}]
        write(subjects / "demo.json", json.dumps(unproven))
        cycle._subject_cache.clear()
        try:
            cycle.selected_output_patterns(declaration, declaration["arms"][0])
        except SystemExit as exc:
            assert "not on a proven placement" in str(exc)
        else:
            raise AssertionError("unproven placement was accepted")
        write(subjects / "demo.json", json.dumps(descriptor))
        cycle._subject_cache.clear()
        _patterns, empty_paths = cycle.selected_output_patterns(
            declaration, declaration["arms"][0]
        )
        assert empty_paths == ["SUBJECT-UNUSED.md", "UNUSED.md"]
        empty_check = temp / "empty-check"
        (empty_check / "control" / "SUBJECT-UNUSED.md").mkdir(parents=True)
        checks = cycle.build_arm_inject_lines(declaration["arms"][0], declaration)[-2:]
        run("bash", "-lc", "\n".join(checks), cwd=empty_check)
        write(empty_check / "control" / "SUBJECT-UNUSED.md" / "content", "not empty\n")
        rejected = subprocess.run(
            ["bash", "-lc", "\n".join(checks)], cwd=empty_check,
            capture_output=True, text=True,
        )
        assert rejected.returncode != 0
        cycle.materialize("fixture-core")
        cycle.handoff("fixture-core")
        handoff_record = json.loads(
            (control / "handoffs" / "fixture-core.json").read_text(encoding="utf-8")
        )
        assert_schema_contract(handoff_record, "handoff.schema.json")

        # --- credential handling (Constitution 不変条件 (9)) ---
        auth_targets = [
            release / "configs" / arm["id"] / "demo" / "auth.json"
            for arm in declaration["arms"]
        ]
        for target in auth_targets:  # A1: credential is a symlink, not a copy
            assert target.is_symlink(), "expected symlink: %s" % target
        for target in auth_targets:  # A2: symlink resolves to the store's content
            assert target.read_text(encoding="utf-8") == "fixture-store-auth\n"
        for arm in declaration["arms"]:  # A3: transcript root is excluded from the clone
            foreign = release / "configs" / arm["id"] / "demo" / "sessions" / "foreign.jsonl"
            assert not foreign.exists(), "transcript root was not excluded: %s" % foreign

        recorded_identities = {
            subject["configIdentity"]
            for arm in handoff_record["arms"] for subject in arm["subjects"]
        }
        assert len(recorded_identities) == 1, recorded_identities  # A4
        config_identity = next(iter(recorded_identities))

        def independent_config_identity(template_dir, credential_paths, transcript_root):
            files = []
            for root, _dirs, names in os.walk(template_dir):
                for name in names:
                    full = Path(root) / name
                    rel = full.relative_to(template_dir).as_posix()
                    if rel in credential_paths:
                        continue
                    if transcript_root is not None and (
                        rel == transcript_root or rel.startswith(transcript_root + "/")
                    ):
                        continue
                    files.append(rel)
            files.sort()
            lines = []
            for rel in files:
                digest = hashlib.sha256((template_dir / rel).read_bytes()).hexdigest()
                lines.append("%s  ./%s\n" % (digest, rel))
            return hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()

        expected_identity = independent_config_identity(template, {"auth.json"}, "sessions")
        assert config_identity == expected_identity  # A5

        def run_cycle_with_store(name, credential_store):
            """独立した cycle を materialize + handoff する。credential_store が
            None なら credentialStore を持たない環境で実行する。"""
            subjects_env = {
                "demo": {"configTemplate": str(template)},
                "demo2": {"configTemplate": str(template)},
            }
            if credential_store is not None:
                for entry in subjects_env.values():
                    entry["credentialStore"] = credential_store
            alt_environment = dict(environment)
            alt_environment["subjects"] = subjects_env
            alt_environment_path = control / ("environment-%s.json" % name)
            write(alt_environment_path, json.dumps(alt_environment))
            candidate = json.loads(json.dumps(declaration))
            candidate["cycle"] = name
            write(cycles / (name + ".json"), json.dumps(candidate))
            cycle.configure_environment(str(alt_environment_path))
            cycle._subject_cache.clear()
            try:
                cycle.materialize(name)
                cycle.handoff(name)
            finally:
                cycle.configure_environment(str(environment_path))
                cycle._subject_cache.clear()
            return Path.home() / "releases" / name

        # A6: rotating the store's credential must not move configIdentity.
        write(authstore / "auth.json", "fixture-store-auth-rotated\n")
        rotated_release = run_cycle_with_store("fixture-core-rotate", str(authstore))
        extra_releases.append(rotated_release)
        rotated_record = json.loads(
            (control / "handoffs" / "fixture-core-rotate.json").read_text(encoding="utf-8")
        )
        rotated_identities = {
            subject["configIdentity"]
            for arm in rotated_record["arms"] for subject in arm["subjects"]
        }
        assert rotated_identities == {expected_identity}

        # A7: a real file where a credential symlink belongs must fail freeze().
        control_auth = release / "configs" / "control" / "demo" / "auth.json"
        control_auth.unlink()
        write(control_auth, "not a symlink\n")
        try:
            cycle.freeze_arm("fixture-core", "control")
        except SystemExit as exc:
            assert "credential file in release" in str(exc)
        else:
            raise AssertionError("credential file placement mismatch was accepted")
        finally:
            control_auth.unlink()
            control_auth.symlink_to(authstore / "auth.json")

        # A8: a subject descriptor without credentialPaths (the old-format shape,
        # pre-credentialPaths) fails schema validation (required violation).
        legacy = dict(descriptor)
        del legacy["credentialPaths"]
        legacy["id"] = "legacy"
        write(subjects / "legacy.json", json.dumps(legacy))
        cycle._subject_cache.clear()
        try:
            cycle.load_subject("legacy")
        except SystemExit:
            pass
        else:
            raise AssertionError("subject without credentialPaths was accepted")

        # A9: a credentialPaths entry containing '..' is rejected.
        traversal = dict(descriptor)
        traversal["id"] = "traversal"
        traversal["credentialPaths"] = ["../escape"]
        write(subjects / "traversal.json", json.dumps(traversal))
        cycle._subject_cache.clear()
        try:
            cycle.load_subject("traversal")
        except SystemExit as exc:
            assert "credentialPaths" in str(exc)
        else:
            raise AssertionError("credentialPaths traversal entry was accepted")
        cycle._subject_cache.clear()

        # A10: a credentialStore under $HOME/releases must fail handoff.
        bad_store = str(Path.home() / "releases" / "fixture-core-bad-store-target")
        try:
            run_cycle_with_store("fixture-core-badstore", bad_store)
        except SystemExit:
            pass
        else:
            raise AssertionError("credentialStore under $HOME/releases was accepted")
        finally:
            bad_release = Path.home() / "releases" / "fixture-core-badstore"
            if bad_release.exists():
                shutil.rmtree(bad_release)

        # A11: an omitted credentialStore leaves the config root without the credential.
        no_store_release = run_cycle_with_store("fixture-core-nostore", None)
        extra_releases.append(no_store_release)
        assert not (no_store_release / "configs" / "control" / "demo" / "auth.json").exists()

        # A12: a credentialStore starting with '~' must fail before touching the filesystem.
        env_tilde = dict(environment)
        env_tilde["subjects"] = {
            "demo": {"configTemplate": str(template), "credentialStore": "~/store"},
            "demo2": {"configTemplate": str(template)},
        }
        env_tilde_path = control / "environment-tilde.json"
        write(env_tilde_path, json.dumps(env_tilde))
        cycle.configure_environment(str(env_tilde_path))
        try:
            cycle.executor_store_path("demo")
        except SystemExit as exc:
            assert "must not start with '~'" in str(exc)
        else:
            raise AssertionError("credentialStore starting with '~' was accepted")
        finally:
            cycle.configure_environment(str(environment_path))
            cycle._subject_cache.clear()

        start = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
        for index, arm in enumerate(declaration["arms"]):
            arm_root = release / arm["id"]
            for offset, subject in enumerate(("demo", "demo2")):
                for session_index in range(2):
                    session = release / "configs" / arm["id"] / subject / "sessions" / ("run-%d.jsonl" % session_index)
                    rows = [
                        {"type": "session_meta", "payload": {"cwd": str(arm_root)}, "timestamp": (start + datetime.timedelta(seconds=offset + session_index)).isoformat()},
                        {"type": "assistant", "timestamp": (start + datetime.timedelta(minutes=2, seconds=offset + session_index)).isoformat()},
                    ]
                    write(session, "".join(json.dumps(row) + "\n" for row in rows))
            write(arm_root / "result.txt", arm["id"] + "\n")
            run("git", "add", "result.txt", cwd=arm_root)
            stamp = (start + datetime.timedelta(minutes=1)).isoformat()
            run("git", "commit", "-m", "result", cwd=arm_root,
                env={"GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp})
        cycle.judge("fixture-core")
        execution = json.loads((control / "executions" / "fixture-core.json").read_text(encoding="utf-8"))
        assert_schema_contract(execution, "execution.schema.json")
        assert all(len(arm["subjects"]) == 2 for arm in execution["arms"])
        assert all(
            len(subject["sessions"]) == 2
            for arm in execution["arms"] for subject in arm["subjects"]
        )
        cycle.promote("fixture-core")
        promotion = json.loads(
            (control / "promotions" / "fixture-core.json").read_text(encoding="utf-8")
        )
        assert_schema_contract(promotion, "promotion.schema.json")
        assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=stable, text=True).strip() != stable_before
        cycle.rollback("fixture-core")
        rollback = json.loads(
            (control / "rollbacks" / "fixture-core.json").read_text(encoding="utf-8")
        )
        assert_schema_contract(rollback, "rollback.schema.json")
        assert (stable / "rules" / "demo.rule.md").read_text(encoding="utf-8") == "stable\n"

        def promotion_inputs(name, result_control="not-met", result_treatment="met",
                             variant="v2", tree=None):
            selected_tree = tree or trees[variant]
            candidate = json.loads(json.dumps(declaration))
            candidate["cycle"] = name
            candidate["arms"][1]["variant"] = variant
            candidate["arms"][1]["variantTree"] = selected_tree
            write(cycles / (name + ".json"), json.dumps(candidate))
            review = {
                "schemaVersion": 3, "cycle": name,
                "arms": [
                    {"id": "control", "role": "control", "variantTree": trees["v1"],
                     "criteria": [{"criterion": 1, "text": "effect", "result": result_control}]},
                    {"id": "treatment", "role": "treatment", "variantTree": selected_tree,
                     "criteria": [{"criterion": 1, "text": "effect", "result": result_treatment}]},
                ],
            }
            write(control / "reviews" / (name + ".json"), json.dumps(review))
            return candidate, review

        def expect_not_promoted(name, reason, **kwargs):
            promotion_inputs(name, **kwargs)
            cycle.promote(name)
            record = json.loads(
                (control / "promotions" / (name + ".json")).read_text(encoding="utf-8")
            )
            assert record["status"] == "not-promoted"
            assert any(reason in item for item in record["reasons"]), record["reasons"]

        expect_not_promoted("no-effect", "no attributable effect", result_control="met")
        expect_not_promoted(
            "regression", "review contains regression",
            result_control="met", result_treatment="not-met",
        )
        expect_not_promoted("unknown", "unknown", result_treatment="unknown")
        write(stable / "dirty.tmp", "dirty\n")
        expect_not_promoted("dirty-stable", "dirty")
        (stable / "dirty.tmp").unlink()
        expect_not_promoted("tree-drift", "variantTree", tree="f" * 40)
        expect_not_promoted("test-failure", "renderer failure", variant="vbad")

        prepared_decl, _review = promotion_inputs("prepared-resume")
        prepared_source = experiment / "variants" / "v2" / "source"
        old_head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=stable, text=True
        ).strip()
        old_digest = cycle.managed_digest(str(stable))
        target_digest = cycle.managed_digest(str(prepared_source))
        prepared_worktree = temp / "prepared-worktree"
        run("git", "worktree", "add", "--detach", str(prepared_worktree), old_head, cwd=stable)
        cycle.sync_managed(str(prepared_source), str(prepared_worktree))
        run("git", "add", "--", *cycle.MANAGED_ITEMS, cwd=prepared_worktree)
        run("git", "commit", "-m", "prepared fixture", cwd=prepared_worktree)
        prepared_head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=prepared_worktree, text=True
        ).strip()
        run("git", "worktree", "remove", "--force", str(prepared_worktree), cwd=stable)
        review_file = control / "reviews" / "prepared-resume.json"
        prepared_record = {
            "schemaVersion": 1, "cycle": "prepared-resume",
            "recordedAt": datetime.datetime.now().astimezone().isoformat(),
            "status": "prepared", "reviewSha256": sha(review_file),
            "variantTree": prepared_decl["arms"][1]["variantTree"],
            "oldManagedDigest": old_digest, "managedDigest": target_digest,
            "oldStableCommit": old_head, "newStableCommit": prepared_head, "reasons": [],
        }
        write(
            control / "promotions" / "prepared-resume.json",
            json.dumps(prepared_record),
        )
        cycle.promote("prepared-resume")
        resumed = json.loads(
            (control / "promotions" / "prepared-resume.json").read_text(encoding="utf-8")
        )
        assert resumed["status"] == "promoted"
        assert subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=stable, text=True
        ).strip() == prepared_head

        write(stable / "later.txt", "later\n")
        run("git", "add", "later.txt", cwd=stable)
        run("git", "commit", "-m", "later fixture", cwd=stable)
        try:
            cycle.rollback("prepared-resume")
        except SystemExit as exc:
            assert "not the recorded promotion commit" in str(exc)
        else:
            raise AssertionError("rollback accepted a later stable commit")
    finally:
        cycle.CYCLES_DIR, cycle.SUBJECTS_DIR = old
        if release.exists():
            shutil.rmtree(release)
        for extra in extra_releases:
            if extra.exists():
                shutil.rmtree(extra)

print("cycle fixture: ok")
