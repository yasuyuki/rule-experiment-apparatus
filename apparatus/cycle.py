#!/usr/bin/env python3
"""Materialize, review, promote, terminate, and roll back rule experiments."""

import argparse
import contextlib
import datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


APPARATUS_DIR = os.path.dirname(os.path.abspath(__file__))
CYCLES_DIR = os.path.join(APPARATUS_DIR, "cycles")
SUBJECTS_DIR = os.path.join(APPARATUS_DIR, "subjects")
SCHEMAS_DIR = os.path.join(APPARATUS_DIR, "schemas")
MANAGED_ITEMS = ("rules", "placement.json", "bin/rules.py")
PROTOCOL_VERSION = 1
IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9._-]+$")

ENVIRONMENT_PATH = None
CONTROL_DIR = None
_environment_cache = None
_subject_cache = {}


def configure_environment(path):
    global ENVIRONMENT_PATH, CONTROL_DIR, CYCLES_DIR, _environment_cache
    if not path:
        raise SystemExit("--environment is required")
    ENVIRONMENT_PATH = os.path.abspath(path)
    CONTROL_DIR = os.path.dirname(ENVIRONMENT_PATH)
    CYCLES_DIR = os.path.join(CONTROL_DIR, "cycles")
    _environment_cache = None
    _subject_cache.clear()


def _jsonschema_mod():
    try:
        import jsonschema
    except ImportError:
        raise SystemExit(
            "jsonschema is required; install with: pip install -r %s"
            % os.path.join(APPARATUS_DIR, "requirements.txt")
        )
    return jsonschema


def validate_against_schema(instance, schema_filename, label):
    with open(os.path.join(SCHEMAS_DIR, schema_filename), encoding="utf-8") as handle:
        schema = json.load(handle)
    validator = _jsonschema_mod().validators.validator_for(schema)(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.absolute_path))
    if errors:
        raise SystemExit("\n".join(
            "%s schema: %s: %s"
            % (label, "/".join(str(part) for part in error.absolute_path) or "(root)", error.message)
            for error in errors
        ))


def validate_identifier(kind, value):
    if not isinstance(value, str) or not IDENTIFIER_RE.fullmatch(value) or value in (".", ".."):
        raise SystemExit("invalid %s: %r" % (kind, value))


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def content_hash(value):
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def atomic_write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".%s." % os.path.basename(path), dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def resolve_control_path(value):
    return os.path.normpath(value if os.path.isabs(value) else os.path.join(CONTROL_DIR, value))


def load_environment():
    global _environment_cache
    if _environment_cache is not None:
        return _environment_cache
    if not ENVIRONMENT_PATH or not os.path.isfile(ENVIRONMENT_PATH):
        raise SystemExit("environment descriptor not found: %s" % ENVIRONMENT_PATH)
    with open(ENVIRONMENT_PATH, encoding="utf-8") as handle:
        environment = json.load(handle)
    validate_against_schema(environment, "environment.schema.json", "environment")
    if environment["executor"]["kind"] == "local-posix" and os.name != "posix":
        raise SystemExit(
            "executor local-posix needs a POSIX host; on a Windows controller declare the wsl executor"
        )
    _environment_cache = environment
    return environment


def variant_source_root():
    return resolve_control_path(load_environment()["variantSourceRoot"])


def stable_rules_root():
    return resolve_control_path(load_environment()["stableRules"]["root"])


def to_mnt(path):
    drive, rest = os.path.splitdrive(path)
    return "/mnt/%s%s" % (drive[0].lower(), rest.replace("\\", "/")) if drive else path


def to_executor_path(path):
    return to_mnt(path) if load_environment()["executor"]["kind"] == "wsl" else path.replace("\\", "/")


def runs_root():
    value = load_environment()["runsRoot"]
    if load_environment()["executor"]["kind"] == "wsl":
        if value.startswith("~/"):
            home = run_executor(["bash", "-lc", 'printf "%s" "$HOME"']).stdout.strip()
            value = home + value[1:]
        if not value.startswith("/"):
            raise SystemExit("runsRoot must be an absolute or home-relative executor path for WSL")
        return value.rstrip("/")
    return resolve_control_path(value).replace("\\", "/").rstrip("/")


def release_path(cycle_name):
    return "%s/%s" % (runs_root(), cycle_name)


def run_host(argv, cwd=None, check=True):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, encoding="utf-8")
    if check and result.returncode != 0:
        raise SystemExit("%s failed (%d): %s" % (" ".join(argv), result.returncode, result.stderr.strip()))
    return result


def git_host(root, *args, check=True):
    return run_host(["git", "-C", root, *args], check=check)


def _executor_argv(argv):
    executor = load_environment()["executor"]
    if executor["kind"] == "wsl":
        return ["wsl.exe", "-d", executor["distro"], "-u", executor["user"], "-e", *argv]
    return argv


def run_executor(argv, stdin=None, check=True):
    result = subprocess.run(
        _executor_argv(argv), input=stdin, capture_output=True, text=True, encoding="utf-8"
    )
    if check and result.returncode != 0:
        raise SystemExit("%s failed (%d): %s" % (" ".join(argv), result.returncode, result.stderr.strip()))
    return result


def exec_(command, check=True):
    result = run_executor(["bash", "-lc", command], check=check)
    return result.stdout if check else (result.stdout, result.stderr, result.returncode)


def cycle_path(name):
    validate_identifier("cycle", name)
    return os.path.join(CYCLES_DIR, "%s.json" % name)


def termination_path(cycle_name):
    validate_identifier("cycle", cycle_name)
    return os.path.join(CONTROL_DIR, "terminations", "%s.json" % cycle_name)


@contextlib.contextmanager
def cycle_lock(cycle_name):
    """Hold a non-blocking, OS-released lock for one cycle transition."""
    validate_identifier("cycle", cycle_name)
    path = os.path.join(CONTROL_DIR, ".cycle-locks", "%s.lock" % cycle_name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a+", encoding="utf-8") as handle:
        if os.name == "posix":
            import fcntl
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise SystemExit("cycle operation already in progress: %s" % cycle_name)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            return
        import msvcrt
        handle.seek(0)
        if not handle.read(1):
            handle.seek(0)
            handle.write("0")
            handle.flush()
        handle.seek(0)
        try:
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            raise SystemExit("cycle operation already in progress: %s" % cycle_name)
        try:
            yield
        finally:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)


def load_cycle(name):
    path = cycle_path(name)
    if not os.path.isfile(path):
        raise SystemExit("cycle declaration not found: %s" % path)
    with open(path, encoding="utf-8") as handle:
        declaration = json.load(handle)
    validate_against_schema(declaration, "cycle.schema.json", "cycle %s" % name)
    if declaration["cycle"] != name:
        raise SystemExit("cycle id does not match filename: %s" % path)
    ids = [arm["id"] for arm in declaration["arms"]]
    if len(ids) != len(set(ids)):
        raise SystemExit("cycle has duplicate arm ids: %s" % name)
    return declaration


def termination_record(cycle_name):
    """Return the immutable termination record when this cycle has one."""
    path = termination_path(cycle_name)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as handle:
        record = json.load(handle)
    validate_against_schema(record, "termination.schema.json", "termination %s" % cycle_name)
    if record["cycle"] != cycle_name:
        raise SystemExit("termination cycle does not match filename: %s" % path)
    return record


def reject_terminated(cycle_name):
    record = termination_record(cycle_name)
    if record is not None:
        raise SystemExit("cycle is terminated: %s (%s)" % (cycle_name, record["status"]))


def terminate(cycle_name, status, reason):
    load_cycle(cycle_name)
    with cycle_lock(cycle_name):
        review_file = os.path.join(CONTROL_DIR, "reviews", "%s.json" % cycle_name)
        if os.path.exists(review_file):
            raise SystemExit("review already exists; cannot terminate cycle: %s" % cycle_name)
        if not reason.strip():
            raise SystemExit("termination reason must not be empty")
        path = termination_path(cycle_name)
        requested = {
            "schemaVersion": 1,
            "cycle": cycle_name,
            "status": status,
            "reason": reason,
            "declarationSha256": sha256_file(cycle_path(cycle_name)),
        }
        existing = termination_record(cycle_name)
        if existing is not None:
            if any(existing[key] != requested[key] for key in requested):
                raise SystemExit("termination record differs from requested payload: %s" % path)
            print("already terminated: %s (%s)" % (cycle_name, status))
            return
        record = dict(requested, recordedAt=datetime.datetime.now().astimezone().isoformat())
        validate_against_schema(record, "termination.schema.json", "termination %s" % cycle_name)
        atomic_write_json(path, record)
        print("terminated: %s (%s)" % (cycle_name, status))


def _safe_relative_path(value, label):
    if os.path.isabs(value) or value.startswith("~") or "\\" in value:
        raise SystemExit("%s must be a portable relative path: %r" % (label, value))
    if any(part in ("", ".", "..") for part in value.split("/")):
        raise SystemExit("%s contains an invalid path segment: %r" % (label, value))
    return value


def load_subject(subject_id):
    if subject_id in _subject_cache:
        return _subject_cache[subject_id]
    validate_identifier("subject", subject_id)
    path = os.path.join(SUBJECTS_DIR, "%s.json" % subject_id)
    if not os.path.isfile(path):
        raise SystemExit("subject descriptor not found: %s" % path)
    with open(path, encoding="utf-8") as handle:
        descriptor = json.load(handle)
    validate_against_schema(descriptor, "subject.schema.json", "subject %s" % subject_id)
    if descriptor["id"] != subject_id:
        raise SystemExit("subject id does not match filename: %s" % path)
    entrypoint = _safe_relative_path(descriptor["adapter"]["entrypoint"], "adapter entrypoint")
    adapter_path = os.path.normpath(os.path.join(os.path.dirname(path), entrypoint))
    if os.path.commonpath((os.path.dirname(path), adapter_path)) != os.path.dirname(path):
        raise SystemExit("adapter entrypoint escapes its subject directory: %s" % entrypoint)
    if not os.path.isfile(adapter_path):
        raise SystemExit("adapter not found: %s" % adapter_path)
    if sha256_file(adapter_path) != descriptor["adapter"]["sha256"]:
        raise SystemExit("adapter digest mismatch: %s" % adapter_path)
    loaded = dict(descriptor, _path=path, _adapterPath=adapter_path)
    _subject_cache[subject_id] = loaded
    return loaded


def subject_profile(descriptor):
    profiles = load_environment()["profiles"]
    profile_ref = descriptor["profileRef"]
    if profile_ref not in profiles:
        raise SystemExit("environment has no profile for %s" % profile_ref)
    return profiles[profile_ref]


def variant_dir(declaration, arm):
    return os.path.join(
        variant_source_root(), "experiments", declaration["experiment"],
        "variants", arm["variant"], "source",
    )


def managed_digest(root):
    digest = hashlib.sha256()
    for relative in MANAGED_ITEMS:
        path = os.path.join(root, relative.replace("/", os.sep))
        if not os.path.exists(path):
            raise SystemExit("managed source is missing: %s" % path)
        files = []
        if os.path.isdir(path):
            for current, dirs, names in os.walk(path):
                dirs.sort()
                files.extend(os.path.join(current, name) for name in sorted(names))
        else:
            files.append(path)
        for filename in files:
            relative_file = os.path.relpath(filename, root).replace(os.sep, "/")
            digest.update(relative_file.encode("utf-8") + b"\0")
            with open(filename, "rb") as handle:
                for chunk in iter(lambda: handle.read(65536), b""):
                    digest.update(chunk)
            digest.update(b"\0")
    return digest.hexdigest()


def git_source(*args):
    return git_host(variant_source_root(), *args).stdout


def verify_canonical(declaration, arm):
    relative = "experiments/%s/variants/%s/source" % (declaration["experiment"], arm["variant"])
    problems = []
    if git_source("rev-parse", "HEAD:%s" % relative).strip() != arm["variantTree"]:
        problems.append("variant tree mismatch for %s" % arm["id"])
    if git_source("status", "--porcelain", "--", relative).strip():
        problems.append("canonical variant is dirty for %s" % arm["id"])
    if managed_digest(variant_dir(declaration, arm)) != arm["variantDigest"]:
        problems.append("variant digest mismatch for %s" % arm["id"])
    return problems


def artifact_path(declaration, name):
    artifact = declaration[name]
    relative = _safe_relative_path(artifact["path"], "%s.path" % name)
    root = variant_source_root()
    path = os.path.normpath(os.path.join(root, relative.replace("/", os.sep)))
    if os.path.commonpath((root, path)) != root:
        raise SystemExit("%s path escapes variant source" % name)
    if not os.path.isfile(path) or sha256_file(path) != artifact["sha256"]:
        raise SystemExit("%s bytes do not match declaration: %s" % (name, path))
    return path


def adapter_identities(declaration):
    return [
        {"id": subject_id, "identity": load_subject(subject_id)["adapter"]["sha256"]}
        for subject_id in declaration["subjects"]
    ]


def materials_declared(declaration):
    return declaration.get("materials", [])


def materials_fingerprint(declaration):
    """Materials are declared once for the cycle, not per arm, so both arms read the
    same bytes by construction. The fingerprint pins them into the review record."""
    return [
        {"name": material["name"], "commit": material["commit"]}
        for material in sorted(materials_declared(declaration), key=lambda item: item["name"])
    ]


def comparison_fingerprint(declaration):
    return {
        "baseCommit": declaration["base"]["commit"],
        "workloadSha256": declaration["workload"]["sha256"],
        "evaluationSha256": declaration["evaluation"]["sha256"],
        "materials": materials_fingerprint(declaration),
        "adapters": adapter_identities(declaration),
    }


def comparison_mismatches(arms):
    """Return comparison-key drift; arm identity and variant are the only exclusions."""
    keys = ("baseCommit", "workloadSha256", "evaluationSha256", "materials", "adapters")
    expected = {key: arms[0][key] for key in keys}
    problems = []
    for arm in arms[1:]:
        for key in keys:
            if arm[key] != expected[key]:
                problems.append("%s differs across arms" % key)
    if len({arm["variantDigest"] for arm in arms}) != len(arms):
        problems.append("variant bytes are identical across arms")
    return problems


def validate_comparison(declaration):
    control = next(arm for arm in declaration["arms"] if arm["role"] == "control")
    treatment = next(arm for arm in declaration["arms"] if arm["role"] == "treatment")
    fingerprint = comparison_fingerprint(declaration)
    arms = [dict(fingerprint, variantDigest=arm["variantDigest"]) for arm in (control, treatment)]
    problems = comparison_mismatches(arms)
    if problems:
        raise SystemExit("\n".join(problems))
    return fingerprint


def resolve_base(declaration):
    root = resolve_control_path(declaration["base"]["repo"])
    if not os.path.isdir(os.path.join(root, ".git")):
        raise SystemExit("base repository not found: %s" % root)
    commit = declaration["base"]["commit"]
    if git_host(root, "cat-file", "-e", "%s^{commit}" % commit, check=False).returncode != 0:
        raise SystemExit("base commit not found: %s" % commit)
    return root


def material_root(cycle_name, name):
    return "%s/materials/%s" % (release_path(cycle_name), name)


def resolve_materials(declaration):
    """Read-only trees a workload needs beyond its base repository, each pinned to a
    commit so a rerun and both arms see the same bytes."""
    resolved, seen = [], set()
    for material in materials_declared(declaration):
        name = material["name"]
        if name in seen:
            raise SystemExit("duplicate material name: %s" % name)
        seen.add(name)
        root = resolve_control_path(material["repo"])
        if not os.path.isdir(os.path.join(root, ".git")):
            raise SystemExit("material repository not found: %s" % root)
        commit = material["commit"]
        if git_host(root, "cat-file", "-e", "%s^{commit}" % commit, check=False).returncode != 0:
            raise SystemExit("material commit not found: %s (%s)" % (commit, name))
        resolved.append({"name": name, "root": root, "commit": commit})
    return resolved


def verify_materials(declaration):
    """Materials are shared by both arms, so a subject that edited one would move the
    comparison under the other. Re-check the pin instead of trusting file modes."""
    for material in materials_declared(declaration):
        target = material_root(declaration["cycle"], material["name"])
        head = exec_("git -C %s rev-parse HEAD" % shlex.quote(target)).strip()
        if head != material["commit"]:
            raise SystemExit("material %s left its pinned commit" % material["name"])
        if exec_("git -C %s status --porcelain" % shlex.quote(target)).strip():
            raise SystemExit("material %s was modified during the cycle" % material["name"])


def state_path(cycle_name):
    return os.path.join(CONTROL_DIR, ".adapter-state", "%s.json" % cycle_name)


def _run_json_program(path, operation, payload):
    result = run_executor(
        ["python3", to_executor_path(path), operation],
        stdin=json.dumps(payload, ensure_ascii=False), check=False,
    )
    if result.returncode != 0:
        raise SystemExit("%s %s failed (%d): %s" % (path, operation, result.returncode, result.stderr.strip()))
    try:
        return json.loads(result.stdout)
    except ValueError as error:
        raise SystemExit("%s %s returned invalid JSON: %s" % (path, operation, error))


def run_adapter(descriptor, operation, payload):
    response = _run_json_program(descriptor["_adapterPath"], operation, payload)
    validate_against_schema(
        response, "adapter-%s.schema.json" % operation,
        "%s adapter %s" % (descriptor["id"], operation),
    )
    if response["adapterIdentity"] != descriptor["adapter"]["sha256"]:
        raise SystemExit("adapter identity mismatch for %s" % descriptor["id"])
    return response


def _clone_arms(declaration, base):
    """Only the pinned commit is fetched. A clone carries every earlier revision too,
    and one `git log` inside the arm reaches them: bytes a declaration removed from the
    base working tree stay readable in the history of the commit it pinned, which is the
    confound Invariant 1 forbids. Measurement never looks behind the pin --
    `merge-base --is-ancestor`, `rev-list <base>..HEAD`, `log --diff-filter=A
    <base>..HEAD` and `ls-tree <base>` all start there -- so the ancestors this drops
    are ones nothing reads."""
    release = release_path(declaration["cycle"])
    lines = [
        "set -eu", "test ! -e %s" % shlex.quote(release),
        "mkdir -p %s" % shlex.quote(release),
    ]
    for arm in declaration["arms"]:
        workspace = "%s/%s" % (release, arm["id"])
        lines.extend([
            "git init -q %s" % shlex.quote(workspace),
            "git -C %s fetch -q --depth 1 %s %s" % (
                shlex.quote(workspace), shlex.quote(to_executor_path(base)),
                shlex.quote(declaration["base"]["commit"]),
            ),
            "git -C %s checkout -q --detach FETCH_HEAD" % shlex.quote(workspace),
        ])
    exec_("\n".join(lines))


def _clone_materials(declaration, materials):
    """Sibling of the arm workspaces, never inside one: materialize commits whatever
    it finds in an arm, and material bytes are not part of the arm's diff.

    Only the pinned commit is fetched. A clone carries every earlier revision too, and
    one `git log` inside the arm reaches them: rule bytes that the declaration left
    behind stay readable, which is the confound Invariant 1 forbids. Pinning the commit
    is not enough when the stray bytes are the rule under measurement."""
    if not materials:
        return
    release = release_path(declaration["cycle"])
    lines = ["set -eu", "mkdir -p %s/materials" % shlex.quote(release)]
    for material in materials:
        target = material_root(declaration["cycle"], material["name"])
        lines.extend([
            "git init -q %s" % shlex.quote(target),
            "git -C %s fetch -q --depth 1 %s %s" % (
                shlex.quote(target), shlex.quote(to_executor_path(material["root"])),
                shlex.quote(material["commit"]),
            ),
            "git -C %s checkout -q --detach FETCH_HEAD" % shlex.quote(target),
            "find %s -type f -exec chmod a-w {} +" % shlex.quote(target),
        ])
    exec_("\n".join(lines))


def materialize(cycle_name):
    declaration = load_cycle(cycle_name)
    with cycle_lock(cycle_name):
        reject_terminated(cycle_name)
        validate_comparison(declaration)
        base = resolve_base(declaration)
        materials = resolve_materials(declaration)
        workload = artifact_path(declaration, "workload")
        artifact_path(declaration, "evaluation")
        problems = [problem for arm in declaration["arms"] for problem in verify_canonical(declaration, arm)]
        if problems:
            raise SystemExit("\n".join(problems))
        output = state_path(cycle_name)
        if os.path.exists(output):
            raise SystemExit("adapter state already exists: %s" % output)
        _clone_arms(declaration, base)
        _clone_materials(declaration, materials)
        release = release_path(cycle_name)
        state_arms = []
        for arm in declaration["arms"]:
            workspace = "%s/%s" % (release, arm["id"])
            subjects = []
            for subject_id in declaration["subjects"]:
                descriptor = load_subject(subject_id)
                prepare = run_adapter(descriptor, "prepare", {
                "protocolVersion": PROTOCOL_VERSION,
                "cycle": cycle_name, "arm": arm["id"], "workspace": workspace,
                "configRoot": "%s/configs/%s/%s" % (release, arm["id"], subject_id),
                "variant": {
                    "path": to_executor_path(variant_dir(declaration, arm)),
                    "digest": arm["variantDigest"],
                },
                "workload": {
                    "path": to_executor_path(workload),
                    "digest": declaration["workload"]["sha256"],
                },
                "materials": [
                    {"name": material["name"], "path": material_root(cycle_name, material["name"])}
                    for material in materials
                ],
                "profile": subject_profile(descriptor),
                })
                if prepare["variantDigest"] != arm["variantDigest"]:
                    raise SystemExit("adapter placed unexpected variant bytes for %s/%s" % (arm["id"], subject_id))
                subjects.append({"id": subject_id, "prepare": prepare})
                print("%s/%s: %s" % (arm["id"], subject_id, prepare["launch"]))
            exec_(
            "set -eu\n"
            "git -C %(workspace)s add -A -f\n"
            "if git -C %(workspace)s diff --cached --quiet; then echo 'adapter placed no rule bytes' >&2; exit 1; fi\n"
            "git -C %(workspace)s commit -q -m %(message)s"
            % {"workspace": shlex.quote(workspace), "message": shlex.quote("variant %s" % arm["variant"])}
            )
            injection = exec_("git -C %s rev-parse HEAD" % shlex.quote(workspace)).strip()
            state_arms.append({
                "id": arm["id"], "workspace": workspace,
                "injectionCommit": injection, "subjects": subjects,
            })
        atomic_write_json(output, {
            "schemaVersion": 1, "cycle": cycle_name,
            "declarationSha256": sha256_file(cycle_path(cycle_name)), "arms": state_arms,
        })
        print("materialized: %s" % release)


def _validate_evaluation_output(payload, declaration):
    if not isinstance(payload, dict) or set(payload) != {"arms"} or not isinstance(payload["arms"], list):
        raise SystemExit("evaluation output must contain only arms")
    expected = {arm["id"] for arm in declaration["arms"]}
    actual = {arm.get("id") for arm in payload["arms"] if isinstance(arm, dict)}
    if actual != expected or len(payload["arms"]) != 2:
        raise SystemExit("evaluation output arm ids do not match declaration")
    allowed = {"criterion", "text", "result", "evidence"}
    for arm in payload["arms"]:
        if set(arm) != {"id", "criteria"} or not isinstance(arm["criteria"], list) or not arm["criteria"]:
            raise SystemExit("evaluation arm must contain id and non-empty criteria")
        for criterion in arm["criteria"]:
            if (
                not isinstance(criterion, dict) or set(criterion) != allowed
                or not isinstance(criterion["criterion"], int) or criterion["criterion"] < 1
                or not all(isinstance(criterion[key], str) and criterion[key] for key in ("text", "evidence"))
                or criterion["result"] not in ("met", "not-met", "unknown")
            ):
                raise SystemExit("invalid evaluation criterion: %r" % criterion)
    return {arm["id"]: arm["criteria"] for arm in payload["arms"]}


def criteria_reasons(criteria_by_arm, declaration):
    control_id = next(arm["id"] for arm in declaration["arms"] if arm["role"] == "control")
    treatment_id = next(arm["id"] for arm in declaration["arms"] if arm["role"] == "treatment")
    keyed = {}
    for arm_id in (control_id, treatment_id):
        keyed[arm_id] = {
            (item["criterion"], item["text"]): item["result"] for item in criteria_by_arm[arm_id]
        }
        if len(keyed[arm_id]) != len(criteria_by_arm[arm_id]):
            return ["evaluation contains duplicate criteria"]
    control, treatment = keyed[control_id], keyed[treatment_id]
    if set(control) != set(treatment):
        return ["evaluation criteria differ across arms"]
    reasons = []
    if any(value == "unknown" for value in [*control.values(), *treatment.values()]):
        reasons.append("review contains unknown criteria")
    if not any(treatment[key] == "met" and control[key] != "met" for key in control):
        reasons.append("no attributable effect")
    if any(control[key] == "met" and treatment[key] != "met" for key in control):
        reasons.append("review contains regression")
    return reasons


def review(cycle_name):
    declaration = load_cycle(cycle_name)
    with cycle_lock(cycle_name):
        return _review(cycle_name, declaration)


def _review(cycle_name, declaration):
    reject_terminated(cycle_name)
    validate_comparison(declaration)
    artifact_path(declaration, "workload")
    evaluation_path = artifact_path(declaration, "evaluation")
    output = os.path.join(CONTROL_DIR, "reviews", "%s.json" % cycle_name)
    if os.path.exists(output):
        raise SystemExit("review already exists: %s" % output)
    temporary = state_path(cycle_name)
    if not os.path.isfile(temporary):
        raise SystemExit("adapter state not found: %s" % temporary)
    with open(temporary, encoding="utf-8") as handle:
        state = json.load(handle)
    declaration_sha = sha256_file(cycle_path(cycle_name))
    if state.get("cycle") != cycle_name or state.get("declarationSha256") != declaration_sha:
        raise SystemExit("declaration changed after materialize")
    verify_materials(declaration)
    state_by_arm = {arm["id"]: arm for arm in state.get("arms", [])}
    evaluation_arms, review_subjects, adapter_reasons = [], {}, []
    for arm in declaration["arms"]:
        runtime = state_by_arm.get(arm["id"])
        if runtime is None:
            raise SystemExit("adapter state is missing arm %s" % arm["id"])
        if exec_(
            "git -C %s merge-base --is-ancestor %s HEAD"
            % (shlex.quote(runtime["workspace"]), shlex.quote(runtime["injectionCommit"])),
            check=False,
        )[2] != 0:
            raise SystemExit("variant injection is not an ancestor of %s" % arm["id"])
        prepared = {item["id"]: item["prepare"] for item in runtime["subjects"]}
        evaluation_subjects, public_subjects = [], []
        for subject_id in declaration["subjects"]:
            descriptor = load_subject(subject_id)
            prepare = prepared[subject_id]
            collect = run_adapter(descriptor, "collect", {
                "protocolVersion": PROTOCOL_VERSION,
                "cycle": cycle_name, "arm": arm["id"], "workspace": runtime["workspace"],
                "profile": subject_profile(descriptor), "token": prepare["token"],
            })
            if not collect["success"]:
                adapter_reasons.append("%s/%s execution failed" % (arm["id"], subject_id))
            if not collect["ruleLoaded"]:
                adapter_reasons.append("%s/%s did not prove rule loading" % (arm["id"], subject_id))
            response_digest = content_hash({"prepare": prepare, "collect": collect})
            public_subjects.append({
                "id": subject_id, "adapterIdentity": descriptor["adapter"]["sha256"],
                "adapterResponseDigest": response_digest,
                "subjectVersion": prepare["subjectVersion"],
            })
            evaluation_subjects.append({
                "id": subject_id, "adapterIdentity": descriptor["adapter"]["sha256"],
                "success": collect["success"], "ruleLoaded": collect["ruleLoaded"],
                "evidence": collect["evidence"],
            })
        review_subjects[arm["id"]] = public_subjects
        evaluation_arms.append({
            "id": arm["id"], "role": arm["role"], "workspace": runtime["workspace"],
            "variantDigest": arm["variantDigest"], "subjects": evaluation_subjects,
        })
    evaluation = _run_json_program(evaluation_path, "evaluate", {
        "protocolVersion": PROTOCOL_VERSION, "cycle": cycle_name,
        "baseCommit": declaration["base"]["commit"],
        "workloadSha256": declaration["workload"]["sha256"],
        "evaluationSha256": declaration["evaluation"]["sha256"],
        "arms": evaluation_arms,
    })
    criteria = _validate_evaluation_output(evaluation, declaration)
    comparison_arms = [
        {
            "baseCommit": declaration["base"]["commit"],
            "workloadSha256": declaration["workload"]["sha256"],
            "evaluationSha256": declaration["evaluation"]["sha256"],
            "materials": materials_fingerprint(declaration),
            "adapters": [
                {"id": item["id"], "identity": item["adapterIdentity"]}
                for item in review_subjects[arm["id"]]
            ],
            "variantDigest": arm["variantDigest"],
        }
        for arm in declaration["arms"]
    ]
    comparison_problems = comparison_mismatches(comparison_arms)
    if comparison_problems:
        raise SystemExit("\n".join(comparison_problems))
    reasons = adapter_reasons + criteria_reasons(criteria, declaration)
    treatment = next(arm for arm in declaration["arms"] if arm["role"] == "treatment")
    record = {
        "schemaVersion": 1, "cycle": cycle_name,
        "recordedAt": datetime.datetime.now().astimezone().isoformat(),
        "declarationSha256": declaration_sha, "baseCommit": declaration["base"]["commit"],
        "workloadSha256": declaration["workload"]["sha256"],
        "evaluationSha256": declaration["evaluation"]["sha256"],
        "arms": [
            {
                "id": arm["id"], "role": arm["role"], "variant": arm["variant"],
                "variantTree": arm["variantTree"], "variantDigest": arm["variantDigest"],
                "subjects": review_subjects[arm["id"]], "criteria": criteria[arm["id"]],
            }
            for arm in declaration["arms"]
        ],
        "verdict": "promote" if not reasons else "reject", "reasons": reasons,
        "treatmentDigest": treatment["variantDigest"],
    }
    if materials_declared(declaration):
        record["materials"] = materials_fingerprint(declaration)
    validate_against_schema(record, "review.schema.json", "review %s" % cycle_name)
    atomic_write_json(output, record)
    os.unlink(temporary)
    print("reviewed: %s (%s)" % (output, record["verdict"]))


def sync_managed(source, destination):
    for relative in MANAGED_ITEMS:
        source_path = os.path.join(source, relative.replace("/", os.sep))
        destination_path = os.path.join(destination, relative.replace("/", os.sep))
        if os.path.isdir(destination_path):
            shutil.rmtree(destination_path)
        elif os.path.exists(destination_path):
            os.unlink(destination_path)
        os.makedirs(os.path.dirname(destination_path), exist_ok=True)
        shutil.copytree(source_path, destination_path) if os.path.isdir(source_path) else shutil.copy2(source_path, destination_path)


def renderer_and_stable_tests(root):
    renderer = os.path.join(root, "bin", "rules.py")
    with tempfile.TemporaryDirectory(prefix="renderer-smoke-", dir=CONTROL_DIR) as workspace:
        run_host([sys.executable, renderer, "render", workspace], cwd=root)
        run_host([sys.executable, renderer, "verify", workspace], cwd=root)
    tests = os.path.join(root, "tests", "test_rules.py")
    if os.path.isfile(tests):
        run_host([sys.executable, tests], cwd=root)


def promotion_path(cycle_name):
    return os.path.join(CONTROL_DIR, "promotions", "%s.json" % cycle_name)


def rollback_path(cycle_name):
    return os.path.join(CONTROL_DIR, "rollbacks", "%s.json" % cycle_name)


def promotion_reasons(cycle_name, declaration, record):
    reasons = []
    try:
        validate_against_schema(record, "review.schema.json", "review %s" % cycle_name)
    except SystemExit as error:
        return [str(error)]
    if record["cycle"] != cycle_name:
        reasons.append("review cycle differs from declaration")
    if record["declarationSha256"] != sha256_file(cycle_path(cycle_name)):
        reasons.append("declaration changed after review")
    if record["baseCommit"] != declaration["base"]["commit"]:
        reasons.append("base differs between declaration and review")
    if record["workloadSha256"] != declaration["workload"]["sha256"]:
        reasons.append("workload differs between declaration and review")
    if record["evaluationSha256"] != declaration["evaluation"]["sha256"]:
        reasons.append("evaluation differs between declaration and review")
    if record.get("materials", []) != materials_fingerprint(declaration):
        reasons.append("materials differ between declaration and review")
    treatment = next(arm for arm in declaration["arms"] if arm["role"] == "treatment")
    reviewed = next(arm for arm in record["arms"] if arm["role"] == "treatment")
    if reviewed["variantTree"] != treatment["variantTree"]:
        reasons.append("treatment tree differs between declaration and review")
    if reviewed["variantDigest"] != treatment["variantDigest"] or record["treatmentDigest"] != treatment["variantDigest"]:
        reasons.append("treatment digest differs between declaration and review")
    if record["verdict"] != "promote" or record["reasons"]:
        reasons.append("review does not approve promotion")
    return reasons


def promote(cycle_name):
    declaration = load_cycle(cycle_name)
    reject_terminated(cycle_name)
    treatment = next(arm for arm in declaration["arms"] if arm["role"] == "treatment")
    review_file = os.path.join(CONTROL_DIR, "reviews", "%s.json" % cycle_name)
    if not os.path.isfile(review_file):
        raise SystemExit("review not found: %s" % review_file)
    with open(review_file, encoding="utf-8") as handle:
        review_record = json.load(handle)
    review_sha = sha256_file(review_file)
    source = variant_dir(declaration, treatment)
    target_digest = managed_digest(source)
    stable = stable_rules_root()
    branch = load_environment()["stableRules"]["branch"]
    old_head = git_host(stable, "rev-parse", "HEAD").stdout.strip()
    old_digest = managed_digest(stable)
    output = promotion_path(cycle_name)
    if os.path.exists(output):
        with open(output, encoding="utf-8") as handle:
            record = json.load(handle)
        validate_against_schema(record, "promotion.schema.json", "promotion %s" % cycle_name)
        if record["reviewSha256"] != review_sha or record["treatmentDigest"] != review_record.get("treatmentDigest"):
            raise SystemExit("prepared promotion inputs drifted")
        if record["status"] == "promoted":
            if old_head != record["newStableCommit"]:
                raise SystemExit("stable HEAD moved after promotion")
            print("already promoted: %s" % record["newStableCommit"])
            return
        if record["status"] == "not-promoted":
            print("not promoted: %s" % "; ".join(record["reasons"]))
            return
        if old_head == record["oldStableCommit"]:
            git_host(stable, "merge", "--ff-only", record["newStableCommit"])
        elif old_head != record["newStableCommit"]:
            raise SystemExit("stable HEAD does not match prepared promotion")
        if managed_digest(stable) != record["treatmentDigest"]:
            raise SystemExit("stable bytes differ from prepared promotion")
        record["status"] = "promoted"
        record["recordedAt"] = datetime.datetime.now().astimezone().isoformat()
        atomic_write_json(output, record)
        print("promoted: %s" % record["newStableCommit"])
        return
    reasons = promotion_reasons(cycle_name, declaration, review_record)
    reasons.extend(verify_canonical(declaration, treatment))
    if target_digest != review_record.get("treatmentDigest"):
        reasons.append("current treatment source bytes differ from reviewed bytes")
    if git_host(stable, "status", "--porcelain").stdout.strip():
        reasons.append("stable worktree is dirty")
    if git_host(stable, "branch", "--show-current").stdout.strip() != branch:
        reasons.append("stable branch is not %s" % branch)
    record = {
        "schemaVersion": 2, "cycle": cycle_name,
        "recordedAt": datetime.datetime.now().astimezone().isoformat(),
        "status": "not-promoted", "reviewSha256": review_sha,
        "treatmentDigest": target_digest, "oldManagedDigest": old_digest,
        "oldStableCommit": old_head, "newStableCommit": None, "reasons": reasons,
    }
    if reasons:
        validate_against_schema(record, "promotion.schema.json", "promotion %s" % cycle_name)
        atomic_write_json(output, record)
        print("not promoted: %s" % "; ".join(reasons))
        return
    temporary = tempfile.mkdtemp(prefix="promotion-", dir=CONTROL_DIR)
    try:
        git_host(stable, "worktree", "add", "--detach", temporary, branch)
        try:
            sync_managed(source, temporary)
            if managed_digest(temporary) != target_digest:
                raise SystemExit("managed source digest mismatch after sync")
            renderer_and_stable_tests(temporary)
        except SystemExit as error:
            record.update(status="not-promoted", reasons=[str(error)])
            validate_against_schema(record, "promotion.schema.json", "promotion %s" % cycle_name)
            atomic_write_json(output, record)
            print("not promoted: %s" % error)
            return
        git_host(temporary, "add", "--", *MANAGED_ITEMS)
        if git_host(temporary, "diff", "--cached", "--quiet", check=False).returncode == 0:
            raise SystemExit("treatment source is already stable")
        git_host(temporary, "commit", "-m", "promote rule experiment %s" % cycle_name)
        new_head = git_host(temporary, "rev-parse", "HEAD").stdout.strip()
        record.update(status="prepared", newStableCommit=new_head)
        validate_against_schema(record, "promotion.schema.json", "promotion %s" % cycle_name)
        atomic_write_json(output, record)
        git_host(stable, "merge", "--ff-only", new_head)
        if managed_digest(stable) != target_digest:
            raise SystemExit("stable bytes differ after promotion")
        record["status"] = "promoted"
        record["recordedAt"] = datetime.datetime.now().astimezone().isoformat()
        atomic_write_json(output, record)
        print("promoted: %s" % new_head)
    finally:
        git_host(stable, "worktree", "remove", "--force", temporary, check=False)
        if os.path.isdir(temporary):
            shutil.rmtree(temporary)


def rollback(cycle_name):
    promotion_file = promotion_path(cycle_name)
    if not os.path.isfile(promotion_file):
        raise SystemExit("promotion record not found: %s" % promotion_file)
    with open(promotion_file, encoding="utf-8") as handle:
        promotion = json.load(handle)
    validate_against_schema(promotion, "promotion.schema.json", "promotion %s" % cycle_name)
    if promotion["status"] != "promoted":
        raise SystemExit("cycle is not promoted: %s" % cycle_name)
    stable = stable_rules_root()
    head = git_host(stable, "rev-parse", "HEAD").stdout.strip()
    output = rollback_path(cycle_name)
    if os.path.exists(output):
        with open(output, encoding="utf-8") as handle:
            record = json.load(handle)
        validate_against_schema(record, "rollback.schema.json", "rollback %s" % cycle_name)
        if record["status"] == "rolled-back":
            if head != record["newStableCommit"]:
                raise SystemExit("stable HEAD moved after rollback")
            print("already rolled back: %s" % record["newStableCommit"])
            return
        if head == record["oldStableCommit"]:
            git_host(stable, "merge", "--ff-only", record["newStableCommit"])
        elif head != record["newStableCommit"]:
            raise SystemExit("stable HEAD does not match prepared rollback")
        if managed_digest(stable) != record["restoredManagedDigest"]:
            raise SystemExit("stable bytes differ from prepared rollback")
        record["status"] = "rolled-back"
        record["recordedAt"] = datetime.datetime.now().astimezone().isoformat()
        atomic_write_json(output, record)
        print("rolled back: %s" % record["newStableCommit"])
        return
    if head != promotion["newStableCommit"]:
        raise SystemExit("stable HEAD is not the recorded promotion commit")
    if git_host(stable, "status", "--porcelain").stdout.strip():
        raise SystemExit("stable worktree is dirty")
    temporary = tempfile.mkdtemp(prefix="rollback-", dir=CONTROL_DIR)
    try:
        git_host(stable, "worktree", "add", "--detach", temporary, head)
        git_host(temporary, "revert", "--no-edit", promotion["newStableCommit"])
        if managed_digest(temporary) != promotion["oldManagedDigest"]:
            raise SystemExit("rollback did not restore prior bytes")
        renderer_and_stable_tests(temporary)
        new_head = git_host(temporary, "rev-parse", "HEAD").stdout.strip()
        record = {
            "schemaVersion": 2, "cycle": cycle_name,
            "recordedAt": datetime.datetime.now().astimezone().isoformat(),
            "status": "prepared", "reviewSha256": promotion["reviewSha256"],
            "treatmentDigest": promotion["treatmentDigest"],
            "promotionCommit": promotion["newStableCommit"],
            "oldStableCommit": head, "newStableCommit": new_head,
            "promotedManagedDigest": promotion["treatmentDigest"],
            "restoredManagedDigest": promotion["oldManagedDigest"],
        }
        validate_against_schema(record, "rollback.schema.json", "rollback %s" % cycle_name)
        atomic_write_json(output, record)
        git_host(stable, "merge", "--ff-only", new_head)
        record["status"] = "rolled-back"
        record["recordedAt"] = datetime.datetime.now().astimezone().isoformat()
        atomic_write_json(output, record)
        print("rolled back: %s" % new_head)
    finally:
        git_host(stable, "worktree", "remove", "--force", temporary, check=False)
        if os.path.isdir(temporary):
            shutil.rmtree(temporary)


def core_selfcheck(check_active_environment=False):
    if check_active_environment:
        load_environment()
    sha_a, sha_b = "a" * 64, "b" * 64
    tree_a, tree_b = "a" * 40, "b" * 40
    declaration = {
        "schemaVersion": 1, "cycle": "check", "experiment": "check",
        "subjects": ["fake"],
        "workload": {"path": "experiments/check/workload.md", "sha256": sha_a},
        "evaluation": {"path": "experiments/check/evaluate.py", "sha256": sha_b},
        "base": {"repo": ".", "commit": tree_a},
        "arms": [
            {"id": "control", "role": "control", "variant": "v1", "variantTree": tree_a, "variantDigest": sha_a},
            {"id": "treatment", "role": "treatment", "variant": "v2", "variantTree": tree_b, "variantDigest": sha_b},
        ],
    }
    validate_against_schema(declaration, "cycle.schema.json", "selfcheck cycle")
    common = {
        "baseCommit": tree_a, "workloadSha256": sha_a, "evaluationSha256": sha_b,
        "materials": [], "adapters": [{"id": "fake", "identity": sha_a}],
    }
    arms = [dict(common, variantDigest=sha_a), dict(common, variantDigest=sha_b)]
    assert comparison_mismatches(arms) == []
    arms[1] = dict(arms[1], adapters=[{"id": "fake", "identity": sha_b}])
    assert comparison_mismatches(arms) == ["adapters differs across arms"]
    assert materials_fingerprint(declaration) == []
    with_materials = dict(
        declaration,
        materials=[
            {"name": "records", "repo": "../control", "commit": tree_b},
            {"name": "docs", "repo": "../apparatus", "commit": tree_a},
        ],
    )
    validate_against_schema(with_materials, "cycle.schema.json", "selfcheck materials")
    assert materials_fingerprint(with_materials) == [
        {"name": "docs", "commit": tree_a}, {"name": "records", "commit": tree_b}
    ]
    material_arms = [
        dict(common, variantDigest=sha_a),
        dict(common, variantDigest=sha_b, materials=[{"name": "records", "commit": tree_b}]),
    ]
    assert comparison_mismatches(material_arms) == ["materials differs across arms"]
    criteria = {
        "control": [{"criterion": 1, "text": "effect", "result": "not-met", "evidence": "control"}],
        "treatment": [{"criterion": 1, "text": "effect", "result": "met", "evidence": "treatment"}],
    }
    assert criteria_reasons(criteria, declaration) == []
    criteria["control"][0]["result"] = "met"
    assert "no attributable effect" in criteria_reasons(criteria, declaration)
    print("selfcheck: ok")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--environment")
    parser.add_argument("--selfcheck", action="store_true")
    commands = parser.add_subparsers(dest="command")
    for name in ("materialize", "review", "promote", "rollback"):
        command = commands.add_parser(name)
        command.add_argument("--cycle", required=True)
    command = commands.add_parser("terminate")
    command.add_argument("--cycle", required=True)
    command.add_argument("--status", required=True, choices=("abandoned", "failed"))
    command.add_argument("--reason", required=True)
    args = parser.parse_args()
    if args.selfcheck:
        if args.command:
            parser.error("--selfcheck cannot be combined with a command")
        if args.environment:
            configure_environment(args.environment)
        return core_selfcheck(check_active_environment=bool(args.environment))
    if not args.command:
        parser.error("a command is required unless --selfcheck is used")
    if not args.environment:
        parser.error("--environment is required for commands")
    configure_environment(args.environment)
    if args.command == "terminate":
        return terminate(args.cycle, args.status, args.reason)
    return globals()[args.command](args.cycle)


if __name__ == "__main__":
    sys.exit(main() or 0)
